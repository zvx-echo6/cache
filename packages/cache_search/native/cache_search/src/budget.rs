//! Memory budget for the libzim searchers that are kept built (see DESIGN.md, "Searcher memory budget").
//!
//! Building a libzim `Searcher` (or `SuggestionSearcher`) opens the ZIM's Xapian database; keeping it makes the next
//! query fast but costs memory, and with many large ZIMs the total can be more than a phone has. The `SearcherBudget`
//! tracks every kept searcher with its estimated cost and keeps the total under a limit (`searcher_budget_mb` in the
//! config):
//!
//! - A searcher that is wanted and fits is kept; to make it fit, the least recently used kept searchers of *other*
//!   sources are dropped (their archives stay open; the next query on them rebuilds the searcher).
//! - A searcher whose cost alone is more than the whole budget is never kept: each query builds a temporary one and drops
//!   it when the query ends (slow, but correct). A budget of 0 therefore means every query builds its searcher.
//! - Prewarm (building searchers before the first query) never evicts: it keeps only what fits (see `prewarm_plan`).
//!
//! The budget changes latency only; the results of a query do not depend on which searchers happen to be kept.
//!
//! This module has no libzim in it (so it is built and tested on every target): the thing it can drop is a `dyn Evict`.

use std::sync::{Mutex, Weak};

pub const MIB: u64 = 1024 * 1024;

/// The budget when the config does not set `searcher_budget_mb`: 256 MiB on every target. See DESIGN.md for why it is
/// the same on the desktop.
pub const DEFAULT_BUDGET_MB: u64 = 256;

/// Which searcher of a ZIM.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// The full-text searcher (`X/fulltext/xapian`).
    Fulltext,
    /// The title-suggestion searcher (`X/title/xapian`).
    Titles,
}

/// Something that can release its kept searcher of a given kind.
pub trait Evict: Send + Sync {
    fn drop_searcher(&self, kind: Kind);
}

/// Estimated private memory of a kept searcher, from the size in bytes of the ZIM index it opens.
///
/// An estimate, because libzim does not report it and the process-wide private-bytes figure cannot be attributed to one
/// searcher while other threads allocate. The model is a fixed part plus a small share of the index size, fitted to the
/// measurements in DESIGN.md ("Searcher memory budget"): on the 19 real ZIMs a kept full-text searcher (Xapian database
/// open, one count-only search) added 0.6-2.1 MiB of private bytes and a title searcher 0-2.0 MiB, whatever the index size
/// (a 7.7 GiB full-text index cost 0.7 MiB: the database is memory-mapped). `index_bytes` 0 (unknown) costs the fixed part.
pub fn estimate_cost(kind: Kind, index_bytes: u64) -> u64 {
    let (fixed, div) = match kind {
        Kind::Fulltext => (FT_FIXED, FT_DIV),
        Kind::Titles => (TI_FIXED, TI_DIV),
    };
    fixed.saturating_add(index_bytes / div)
}

const FT_FIXED: u64 = 1536 * 1024;
const FT_DIV: u64 = 8192;
const TI_FIXED: u64 = 1024 * 1024;
const TI_DIV: u64 = 2048;

/// The ZIMs to prewarm, smallest cost first, as indexes into `costs`: the longest run of the cheapest ones whose total
/// fits in `limit`. Smallest-first keeps the most sources warm for the budget, and it is deterministic.
pub fn prewarm_plan(costs: &[u64], limit: u64) -> Vec<usize> {
    let mut order: Vec<usize> = (0..costs.len()).collect();
    order.sort_by_key(|&i| (costs[i], i));
    let mut total = 0u64;
    let mut out = Vec::new();
    for i in order {
        total = total.saturating_add(costs[i]);
        if total > limit {
            break;
        }
        out.push(i);
    }
    out
}

/// One kept searcher, as `snapshot` reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Kept {
    /// The id `register` gave the owner.
    pub id: u64,
    pub kind: Kind,
    pub cost: u64,
    /// Larger = used more recently.
    pub tick: u64,
}

/// The budget's state at one moment.
#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub limit: u64,
    pub total: u64,
    /// Least recently used first.
    pub kept: Vec<Kept>,
    /// Searchers dropped to make room, since the budget was made.
    pub evictions: u64,
    /// Queries that built a temporary searcher because the searcher was not kept.
    pub per_query: u64,
}

struct Entry {
    k: Kept,
    who: Weak<dyn Evict>,
}

struct State {
    limit: u64,
    total: u64,
    tick: u64,
    next_id: u64,
    entries: Vec<Entry>,
    evictions: u64,
    per_query: u64,
}

pub struct SearcherBudget {
    st: Mutex<State>,
}

impl SearcherBudget {
    pub fn new(limit_bytes: u64) -> SearcherBudget {
        SearcherBudget {
            st: Mutex::new(State { limit: limit_bytes, total: 0, tick: 0, next_id: 1, entries: Vec::new(), evictions: 0, per_query: 0 }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.st.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn limit(&self) -> u64 {
        self.lock().limit
    }

    /// Change the limit; kept searchers over the new limit are dropped, least recently used first.
    pub fn set_limit(&self, limit_bytes: u64) {
        let victims = {
            let mut s = self.lock();
            s.limit = limit_bytes;
            Self::make_room(&mut s, 0, None)
        };
        Self::drop_all(victims);
    }

    /// A new owner id (one per open libzim archive).
    pub fn register(&self) -> u64 {
        let mut s = self.lock();
        let id = s.next_id;
        s.next_id += 1;
        id
    }

    /// Remove least recently used entries (never `keep_id`'s) until `extra` more bytes fit. Returns what to drop.
    fn make_room(s: &mut State, extra: u64, keep_id: Option<u64>) -> Vec<(Weak<dyn Evict>, Kind)> {
        let mut out = Vec::new();
        while s.total.saturating_add(extra) > s.limit {
            let lru = s
                .entries
                .iter()
                .enumerate()
                .filter(|(_, e)| Some(e.k.id) != keep_id)
                .min_by_key(|(_, e)| e.k.tick)
                .map(|(i, _)| i);
            let Some(i) = lru else { break };
            let e = s.entries.remove(i);
            s.total -= e.k.cost;
            s.evictions += 1;
            out.push((e.who, e.k.kind));
        }
        out
    }

    fn drop_all(victims: Vec<(Weak<dyn Evict>, Kind)>) {
        for (w, kind) in victims {
            if let Some(a) = w.upgrade() {
                a.drop_searcher(kind);
            }
        }
    }

    /// A query is about to use the `kind` searcher of owner `id`, whose cost is `cost`. Returns true when it is (now)
    /// kept: it was already, or it fits after dropping least recently used searchers of other owners. Returns false when
    /// it cannot be kept (it alone is over the budget): the caller then uses a temporary searcher. Marks it used.
    pub fn admit(&self, id: u64, kind: Kind, cost: u64, who: Weak<dyn Evict>) -> bool {
        let cost = cost.max(1);
        let victims = {
            let mut s = self.lock();
            s.tick += 1;
            let tick = s.tick;
            if let Some(e) = s.entries.iter_mut().find(|e| e.k.id == id && e.k.kind == kind) {
                e.k.tick = tick;
                return true;
            }
            if cost > s.limit {
                s.per_query += 1;
                return false;
            }
            let victims = Self::make_room(&mut s, cost, Some(id));
            if s.total.saturating_add(cost) > s.limit {
                // only this owner's other searcher is in the way: it is not evicted by its own sibling
                s.per_query += 1;
                drop(s);
                Self::drop_all(victims);
                return false;
            }
            s.total += cost;
            s.entries.push(Entry { k: Kept { id, kind, cost, tick }, who });
            victims
        };
        Self::drop_all(victims);
        true
    }

    /// Like `admit` but never drops anything: used by prewarm. Returns true when the searcher is kept (it already was, or
    /// it fits in the room that is left).
    pub fn try_reserve(&self, id: u64, kind: Kind, cost: u64, who: Weak<dyn Evict>) -> bool {
        let cost = cost.max(1);
        let mut s = self.lock();
        s.tick += 1;
        let tick = s.tick;
        if let Some(e) = s.entries.iter_mut().find(|e| e.k.id == id && e.k.kind == kind) {
            e.k.tick = tick;
            return true;
        }
        if s.total.saturating_add(cost) > s.limit {
            return false;
        }
        s.total += cost;
        s.entries.push(Entry { k: Kept { id, kind, cost, tick }, who });
        true
    }

    pub fn is_kept(&self, id: u64, kind: Kind) -> bool {
        self.lock().entries.iter().any(|e| e.k.id == id && e.k.kind == kind)
    }

    /// The `kind` searcher of owner `id` was released by its owner: it no longer counts.
    pub fn release(&self, id: u64, kind: Kind) {
        let mut s = self.lock();
        let mut freed = 0;
        s.entries.retain(|e| {
            if e.k.id == id && e.k.kind == kind {
                freed += e.k.cost;
                false
            } else {
                true
            }
        });
        s.total -= freed;
    }

    /// Owner `id` is gone (its archive was closed): its searchers no longer count.
    pub fn forget(&self, id: u64) {
        let mut s = self.lock();
        let mut freed = 0;
        s.entries.retain(|e| {
            if e.k.id == id {
                freed += e.k.cost;
                false
            } else {
                true
            }
        });
        s.total -= freed;
    }

    pub fn snapshot(&self) -> Snapshot {
        let s = self.lock();
        let mut kept: Vec<Kept> = s.entries.iter().map(|e| e.k.clone()).collect();
        kept.sort_by_key(|k| k.tick);
        Snapshot { limit: s.limit, total: s.total, kept, evictions: s.evictions, per_query: s.per_query }
    }
}

/// The default of the config key `prewarm`: on, except on Android, where the searchers of many ZIMs built at start would
/// cost memory the phone may not have (the first search of a source then builds its own).
pub const fn prewarm_default(android: bool) -> bool {
    !android
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::sync::Arc;

    #[derive(Default)]
    struct Fake {
        dropped: Mutex<Vec<Kind>>,
        n: AtomicU64,
    }
    impl Evict for Fake {
        fn drop_searcher(&self, kind: Kind) {
            self.dropped.lock().unwrap().push(kind);
            self.n.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn weak(f: &Arc<Fake>) -> Weak<dyn Evict> {
        let a: Arc<dyn Evict> = f.clone();
        Arc::downgrade(&a)
    }

    #[test]
    fn evicts_the_least_recently_used() {
        let b = SearcherBudget::new(100);
        let (a, bb, c) = (Arc::new(Fake::default()), Arc::new(Fake::default()), Arc::new(Fake::default()));
        let (ia, ib, ic) = (b.register(), b.register(), b.register());
        assert!(b.admit(ia, Kind::Fulltext, 40, weak(&a)));
        assert!(b.admit(ib, Kind::Fulltext, 40, weak(&bb)));
        // use A again: B is now the least recently used
        assert!(b.admit(ia, Kind::Fulltext, 40, weak(&a)));
        assert!(b.admit(ic, Kind::Fulltext, 40, weak(&c)));
        assert_eq!(bb.n.load(Ordering::SeqCst), 1, "B was dropped");
        assert_eq!(a.n.load(Ordering::SeqCst), 0);
        let s = b.snapshot();
        assert_eq!(s.total, 80);
        assert_eq!(s.evictions, 1);
        assert_eq!(s.kept.iter().map(|k| k.id).collect::<Vec<_>>(), vec![ia, ic]);
        assert!(!b.is_kept(ib, Kind::Fulltext));
    }

    #[test]
    fn a_searcher_over_the_whole_budget_is_never_kept() {
        let b = SearcherBudget::new(100);
        let (a, big) = (Arc::new(Fake::default()), Arc::new(Fake::default()));
        let (ia, ibig) = (b.register(), b.register());
        assert!(b.admit(ia, Kind::Fulltext, 60, weak(&a)));
        assert!(!b.admit(ibig, Kind::Fulltext, 101, weak(&big)));
        assert_eq!(a.n.load(Ordering::SeqCst), 0, "a too-big searcher evicts nobody");
        assert_eq!(b.snapshot().per_query, 1);
        assert_eq!(b.snapshot().total, 60);
    }

    #[test]
    fn a_zero_budget_keeps_nothing() {
        let b = SearcherBudget::new(0);
        let a = Arc::new(Fake::default());
        let ia = b.register();
        assert!(!b.admit(ia, Kind::Fulltext, 1, weak(&a)));
        assert!(!b.admit(ia, Kind::Titles, 0, weak(&a)));
        assert!(!b.try_reserve(ia, Kind::Fulltext, 1, weak(&a)));
        assert_eq!(b.snapshot().kept.len(), 0);
    }

    #[test]
    fn shrinking_the_limit_drops_the_oldest() {
        let b = SearcherBudget::new(100);
        let (a, bb) = (Arc::new(Fake::default()), Arc::new(Fake::default()));
        let (ia, ib) = (b.register(), b.register());
        assert!(b.admit(ia, Kind::Fulltext, 50, weak(&a)));
        assert!(b.admit(ib, Kind::Fulltext, 50, weak(&bb)));
        b.set_limit(60);
        assert_eq!(a.n.load(Ordering::SeqCst), 1);
        assert_eq!(bb.n.load(Ordering::SeqCst), 0);
        assert_eq!(b.snapshot().total, 50);
        b.set_limit(0);
        assert_eq!(bb.n.load(Ordering::SeqCst), 1);
        assert_eq!(b.snapshot().total, 0);
    }

    #[test]
    fn try_reserve_never_evicts_and_forget_frees() {
        let b = SearcherBudget::new(100);
        let (a, bb) = (Arc::new(Fake::default()), Arc::new(Fake::default()));
        let (ia, ib) = (b.register(), b.register());
        assert!(b.try_reserve(ia, Kind::Fulltext, 70, weak(&a)));
        assert!(!b.try_reserve(ib, Kind::Fulltext, 40, weak(&bb)));
        assert_eq!(a.n.load(Ordering::SeqCst), 0);
        b.forget(ia);
        assert_eq!(b.snapshot().total, 0);
        assert!(b.try_reserve(ib, Kind::Fulltext, 40, weak(&bb)));
    }

    #[test]
    fn a_dead_owner_is_skipped_when_evicting() {
        let b = SearcherBudget::new(100);
        let a = Arc::new(Fake::default());
        let ia = b.register();
        assert!(b.admit(ia, Kind::Fulltext, 80, weak(&a)));
        drop(a);
        let c = Arc::new(Fake::default());
        assert!(b.admit(b.register(), Kind::Fulltext, 80, weak(&c)));
        assert_eq!(b.snapshot().total, 80);
    }

    #[test]
    fn prewarm_takes_the_cheapest_that_fit() {
        assert_eq!(prewarm_plan(&[50, 10, 30, 20], 60), vec![1, 3, 2]);
        assert_eq!(prewarm_plan(&[50, 10, 30, 20], 59), vec![1, 3]);
        assert_eq!(prewarm_plan(&[5, 5], 0), Vec::<usize>::new());
        assert_eq!(prewarm_plan(&[], 100), Vec::<usize>::new());
        // ties by position
        assert_eq!(prewarm_plan(&[7, 7, 7], 14), vec![0, 1]);
    }

    #[test]
    fn cost_grows_with_the_index() {
        assert!(estimate_cost(Kind::Fulltext, 0) > 0);
        assert!(estimate_cost(Kind::Fulltext, 10 * MIB) < estimate_cost(Kind::Fulltext, 1000 * MIB));
        assert_eq!(estimate_cost(Kind::Fulltext, u64::MAX) > 0, true);
    }

    #[test]
    fn prewarm_is_off_by_default_on_android_only() {
        assert!(!prewarm_default(true));
        assert!(prewarm_default(false));
    }

    /// The real target's default: off on Android builds, on everywhere else.
    #[test]
    fn prewarm_default_for_this_target() {
        if cfg!(target_os = "android") {
            assert!(!prewarm_default(cfg!(target_os = "android")));
        } else {
            assert!(prewarm_default(cfg!(target_os = "android")));
        }
    }
}
