//! Memory budget for open libzim archives (see DESIGN.md, "Memory budget").
//!
//! Opening a ZIM with libzim costs memory (about 11 bytes per entry, Wikipedia 292 MiB, and a few MiB for the searchers) and
//! reading results fills libzim's cluster cache, and with many large ZIMs the total can be more than a phone has. The
//! `ZimBudget` tracks every open archive with an estimated cost (`archive_cost`: its measured profile plus the cap on its
//! dirent cache) and keeps the total under a limit (`zim_budget_mb` in the config), after setting aside what is not per
//! archive (`reserved_cost`: process set-up and the cluster cache):
//!
//! - An archive that is wanted and fits stays open together with its searchers; to make it fit, the least recently used
//!   archives of *other* sources are closed (their searchers go with them; the next query on them reopens the archive).
//! - An archive whose cost alone is more than the whole budget is never kept: the query opens it, uses it and closes it when
//!   the query ends (slow, but correct). A budget of 0 therefore opens and closes every archive per query.
//! - Prewarm (opening archives before the first query) never evicts: it keeps only what fits (see `prewarm_plan`).
//!
//! The budget changes latency only; the results of a query do not depend on which archives happen to be open.
//!
//! This module has no libzim in it (so it is built and tested on every target): what it can close is a `dyn Evict`.

use std::sync::{Mutex, Weak};

pub const MIB: u64 = 1024 * 1024;

/// The budget when the config does not set `zim_budget_mb`: 384 MiB on Android, 1024 MiB elsewhere. See DESIGN.md "Memory
/// budget" for why.
pub const fn default_budget_mb(android: bool) -> u64 {
    if android {
        384
    } else {
        1024
    }
}

/// What the cost estimate needs to know about a ZIM, all cheap to read without libzim.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Profile {
    /// Entries in the ZIM (the header's article count).
    pub entries: u64,
    /// Bytes of its `X/fulltext/xapian` entry (0 = none or unknown).
    pub fulltext_bytes: u64,
    /// Bytes of its `X/title/xapian` entry (0 = none or unknown).
    pub title_bytes: u64,
}

/// The caps put on libzim's caches (config keys `zim_dirent_cache` and `zim_cluster_cache_mb`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Caps {
    /// Dirents each archive's dirent cache may hold.
    pub dirent_cache: u64,
    /// Compressed bytes the process-wide cluster cache may hold; accounted once, not per archive.
    pub cluster_cache: u64,
}

pub const DEFAULT_DIRENT_CACHE: u64 = 512;
pub const DEFAULT_CLUSTER_CACHE_MB: u64 = 4;

impl Default for Caps {
    fn default() -> Caps {
        Caps { dirent_cache: DEFAULT_DIRENT_CACHE, cluster_cache: DEFAULT_CLUSTER_CACHE_MB * MIB }
    }
}

/// Which libzim searcher (their cost is part of the archive's, see `archive_cost`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    /// The full-text searcher (`X/fulltext/xapian`).
    Fulltext,
    /// The title-suggestion searcher (`X/title/xapian`).
    Titles,
}

/// Estimated private memory of a built searcher, from the size in bytes of the ZIM index it opens. See `archive_cost`.
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

/// Estimated private memory of one open archive with its searchers and its dirent cache, fitted to the measurements in
/// DESIGN.md "Memory budget": a small base, about 11 bytes per entry (libzim's per-entry tables; Wikipedia's 27.2M entries
/// cost 292 MiB at open), the searchers and their Xapian state, and the dirent cache at its cap.
pub fn archive_cost(p: &Profile, caps: &Caps) -> u64 {
    let mut c = ARCHIVE_BASE;
    c = c.saturating_add(p.entries.saturating_mul(PER_ENTRY_BYTES));
    if p.fulltext_bytes > 0 {
        c = c.saturating_add(estimate_cost(Kind::Fulltext, p.fulltext_bytes));
    }
    if p.title_bytes > 0 {
        c = c.saturating_add(estimate_cost(Kind::Titles, p.title_bytes));
    }
    c.saturating_add(caps.dirent_cache.saturating_mul(DIRENT_BYTES))
}

/// Estimated private memory of libzim's cluster cache when it is full, for a cap of `compressed_cap` bytes. libzim counts the
/// compressed size of what it caches, and the process holds the decompressed clusters (and what the heap keeps after
/// them): measured 7-9 times the cap (cap 4 MiB: 30 MiB; 8: 68; 16: 145).
pub fn cluster_cache_cost(compressed_cap: u64) -> u64 {
    compressed_cap.saturating_mul(CLUSTER_EXPANSION)
}

/// What is taken off the top of the budget before any archive: the first archive opened in a process costs about 9 MiB more
/// than the next ones (libzim, Xapian and ICU set-up and the heap growing), and the cluster cache when full.
pub fn reserved_cost(caps: &Caps) -> u64 {
    PROCESS_BASE.saturating_add(cluster_cache_cost(caps.cluster_cache))
}

const PROCESS_BASE: u64 = 9 * MIB;
const ARCHIVE_BASE: u64 = 2 * MIB;
const PER_ENTRY_BYTES: u64 = 11;
const DIRENT_BYTES: u64 = 256;
const CLUSTER_EXPANSION: u64 = 8;

/// The archives to prewarm, smallest cost first, as indexes into `costs`: the longest run of the cheapest ones whose total
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

/// Something that can close its open archive (the archive may stay alive until a query that already uses it ends).
pub trait Evict: Send + Sync {
    fn close(&self);
}

/// One open archive, as `snapshot` reports it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Kept {
    /// The id `register` gave the owner.
    pub id: u64,
    pub cost: u64,
    /// Larger = used more recently.
    pub tick: u64,
}

/// The budget's state at one moment.
#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    /// The configured limit.
    pub limit: u64,
    /// Part of the limit that is not for archives (`reserved_cost`: process set-up and the cluster cache).
    pub reserved: u64,
    /// Estimated cost of the archives kept open.
    pub total: u64,
    /// Open archives, least recently used first.
    pub kept: Vec<Kept>,
    /// Archives closed to make room, since the budget was made.
    pub evictions: u64,
    /// Queries that opened an archive for that query alone because it was over the whole budget.
    pub per_query: u64,
    /// Archive opens, counting every reopen and per-query open.
    pub opens: u64,
}

struct Entry {
    k: Kept,
    who: Weak<dyn Evict>,
}

struct State {
    limit: u64,
    reserved: u64,
    total: u64,
    tick: u64,
    next_id: u64,
    entries: Vec<Entry>,
    evictions: u64,
    per_query: u64,
    opens: u64,
}

impl State {
    fn avail(&self) -> u64 {
        self.limit.saturating_sub(self.reserved)
    }
}

pub struct ZimBudget {
    st: Mutex<State>,
}

impl ZimBudget {
    pub fn new(limit_bytes: u64) -> ZimBudget {
        ZimBudget {
            st: Mutex::new(State { limit: limit_bytes, reserved: 0, total: 0, tick: 0, next_id: 1, entries: Vec::new(), evictions: 0, per_query: 0, opens: 0 }),
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.st.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn limit(&self) -> u64 {
        self.lock().limit
    }

    /// What archives may use: the limit less the reserved part.
    pub fn available(&self) -> u64 {
        self.lock().avail()
    }

    /// Change the limit and the reserved part (the cluster cache); open archives over the new limit are closed, least
    /// recently used first.
    pub fn configure(&self, limit_bytes: u64, reserved_bytes: u64) {
        let victims = {
            let mut s = self.lock();
            s.limit = limit_bytes;
            s.reserved = reserved_bytes;
            Self::make_room(&mut s, 0, None)
        };
        Self::close_all(victims);
    }

    /// Change the limit; open archives over the new limit are closed, least recently used first.
    pub fn set_limit(&self, limit_bytes: u64) {
        let reserved = self.lock().reserved;
        self.configure(limit_bytes, reserved);
    }

    /// A new owner id (one per ZIM source).
    pub fn register(&self) -> u64 {
        let mut s = self.lock();
        let id = s.next_id;
        s.next_id += 1;
        id
    }

    /// Count one archive open (a first open, a reopen after an eviction, or a per-query open).
    pub fn note_open(&self) {
        self.lock().opens += 1;
    }

    /// Remove least recently used entries (never `keep_id`'s) until `extra` more bytes fit. Returns what to close.
    fn make_room(s: &mut State, extra: u64, keep_id: Option<u64>) -> Vec<Weak<dyn Evict>> {
        let mut out = Vec::new();
        while s.total.saturating_add(extra) > s.avail() {
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
            out.push(e.who);
        }
        out
    }

    fn close_all(victims: Vec<Weak<dyn Evict>>) {
        for w in victims {
            if let Some(a) = w.upgrade() {
                a.close();
            }
        }
    }

    /// A query is about to use the archive of owner `id`, whose cost is `cost`. Returns true when it is (now) kept open: it
    /// was already, or it fits after closing least recently used archives of other owners. Returns false when it cannot be
    /// kept (it alone is over the budget): the caller then opens it for this query alone. Marks it used.
    pub fn admit(&self, id: u64, cost: u64, who: Weak<dyn Evict>) -> bool {
        let cost = cost.max(1);
        let victims = {
            let mut s = self.lock();
            s.tick += 1;
            let tick = s.tick;
            if let Some(e) = s.entries.iter_mut().find(|e| e.k.id == id) {
                e.k.tick = tick;
                return true;
            }
            if cost > s.avail() {
                s.per_query += 1;
                return false;
            }
            let victims = Self::make_room(&mut s, cost, Some(id));
            s.total += cost;
            s.entries.push(Entry { k: Kept { id, cost, tick }, who });
            victims
        };
        Self::close_all(victims);
        true
    }

    /// Like `admit` but never closes anything: used by prewarm. Returns true when the archive is kept (it already was, or it
    /// fits in the room that is left).
    pub fn try_reserve(&self, id: u64, cost: u64, who: Weak<dyn Evict>) -> bool {
        let cost = cost.max(1);
        let mut s = self.lock();
        s.tick += 1;
        let tick = s.tick;
        if let Some(e) = s.entries.iter_mut().find(|e| e.k.id == id) {
            e.k.tick = tick;
            return true;
        }
        if s.total.saturating_add(cost) > s.avail() {
            return false;
        }
        s.total += cost;
        s.entries.push(Entry { k: Kept { id, cost, tick }, who });
        true
    }

    pub fn is_kept(&self, id: u64) -> bool {
        self.lock().entries.iter().any(|e| e.k.id == id)
    }

    /// Owner `id` is gone or its archive was closed by the owner: it no longer counts.
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
        Snapshot { limit: s.limit, reserved: s.reserved, total: s.total, kept, evictions: s.evictions, per_query: s.per_query, opens: s.opens }
    }
}

/// The default of the config key `prewarm`: on, except on Android, where the archives of many ZIMs opened at start would
/// cost memory the phone may not have (the first search of a source then opens its own).
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
        n: AtomicU64,
    }
    impl Evict for Fake {
        fn close(&self) {
            self.n.fetch_add(1, Ordering::SeqCst);
        }
    }

    fn weak(f: &Arc<Fake>) -> Weak<dyn Evict> {
        let a: Arc<dyn Evict> = f.clone();
        Arc::downgrade(&a)
    }

    #[test]
    fn closes_the_least_recently_used() {
        let b = ZimBudget::new(100);
        let (a, bb, c) = (Arc::new(Fake::default()), Arc::new(Fake::default()), Arc::new(Fake::default()));
        let (ia, ib, ic) = (b.register(), b.register(), b.register());
        assert!(b.admit(ia, 40, weak(&a)));
        assert!(b.admit(ib, 40, weak(&bb)));
        // use A again: B is now the least recently used
        assert!(b.admit(ia, 40, weak(&a)));
        assert!(b.admit(ic, 40, weak(&c)));
        assert_eq!(bb.n.load(Ordering::SeqCst), 1, "B was closed");
        assert_eq!(a.n.load(Ordering::SeqCst), 0);
        let s = b.snapshot();
        assert_eq!(s.total, 80);
        assert_eq!(s.evictions, 1);
        assert_eq!(s.kept.iter().map(|k| k.id).collect::<Vec<_>>(), vec![ia, ic]);
        assert!(!b.is_kept(ib));
    }

    #[test]
    fn the_most_recently_used_is_never_the_victim() {
        let b = ZimBudget::new(100);
        let fakes: Vec<Arc<Fake>> = (0..4).map(|_| Arc::new(Fake::default())).collect();
        let ids: Vec<u64> = fakes.iter().map(|_| b.register()).collect();
        for i in 0..3 {
            assert!(b.admit(ids[i], 40, weak(&fakes[i])));
        }
        // 0 was closed as 2 arrived; 1 and 2 are open, 2 the most recent
        assert!(b.admit(ids[3], 40, weak(&fakes[3])));
        let kept: Vec<u64> = b.snapshot().kept.iter().map(|k| k.id).collect();
        assert_eq!(kept, vec![ids[2], ids[3]]);
        assert_eq!(fakes.iter().map(|f| f.n.load(Ordering::SeqCst)).collect::<Vec<_>>(), vec![1, 1, 0, 0]);
    }

    #[test]
    fn an_archive_over_the_whole_budget_is_never_kept() {
        let b = ZimBudget::new(100);
        let (a, big) = (Arc::new(Fake::default()), Arc::new(Fake::default()));
        let (ia, ibig) = (b.register(), b.register());
        assert!(b.admit(ia, 60, weak(&a)));
        assert!(!b.admit(ibig, 101, weak(&big)));
        assert_eq!(a.n.load(Ordering::SeqCst), 0, "a too-big archive closes nobody");
        assert_eq!(b.snapshot().per_query, 1);
        assert_eq!(b.snapshot().total, 60);
    }

    #[test]
    fn the_reserved_part_is_not_for_archives() {
        let b = ZimBudget::new(100);
        b.configure(100, 30);
        assert_eq!(b.available(), 70);
        let a = Arc::new(Fake::default());
        assert!(!b.admit(b.register(), 71, weak(&a)));
        assert!(b.admit(b.register(), 70, weak(&a)));
        // a reserve over the limit leaves nothing for archives and closes what was open
        b.configure(10, 30);
        assert_eq!(b.available(), 0);
        assert_eq!(a.n.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn a_zero_budget_keeps_nothing() {
        let b = ZimBudget::new(0);
        let a = Arc::new(Fake::default());
        let ia = b.register();
        assert!(!b.admit(ia, 1, weak(&a)));
        assert!(!b.admit(ia, 0, weak(&a)));
        assert!(!b.try_reserve(ia, 1, weak(&a)));
        assert_eq!(b.snapshot().kept.len(), 0);
    }

    #[test]
    fn shrinking_the_limit_closes_the_oldest() {
        let b = ZimBudget::new(100);
        let (a, bb) = (Arc::new(Fake::default()), Arc::new(Fake::default()));
        let (ia, ib) = (b.register(), b.register());
        assert!(b.admit(ia, 50, weak(&a)));
        assert!(b.admit(ib, 50, weak(&bb)));
        b.set_limit(60);
        assert_eq!(a.n.load(Ordering::SeqCst), 1);
        assert_eq!(bb.n.load(Ordering::SeqCst), 0);
        assert_eq!(b.snapshot().total, 50);
        b.set_limit(0);
        assert_eq!(bb.n.load(Ordering::SeqCst), 1);
        assert_eq!(b.snapshot().total, 0);
    }

    #[test]
    fn try_reserve_never_closes_and_forget_frees() {
        let b = ZimBudget::new(100);
        let (a, bb) = (Arc::new(Fake::default()), Arc::new(Fake::default()));
        let (ia, ib) = (b.register(), b.register());
        assert!(b.try_reserve(ia, 70, weak(&a)));
        assert!(!b.try_reserve(ib, 40, weak(&bb)));
        assert_eq!(a.n.load(Ordering::SeqCst), 0);
        b.forget(ia);
        assert_eq!(b.snapshot().total, 0);
        assert!(b.try_reserve(ib, 40, weak(&bb)));
    }

    #[test]
    fn a_dead_owner_is_skipped_when_evicting() {
        let b = ZimBudget::new(100);
        let a = Arc::new(Fake::default());
        let ia = b.register();
        assert!(b.admit(ia, 80, weak(&a)));
        drop(a);
        let c = Arc::new(Fake::default());
        assert!(b.admit(b.register(), 80, weak(&c)));
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
    fn cost_grows_with_the_profile_and_the_caps() {
        let caps = Caps::default();
        assert_eq!(reserved_cost(&caps), PROCESS_BASE + 8 * 4 * MIB);
        assert!(reserved_cost(&Caps { cluster_cache: 0, ..caps }) < reserved_cost(&caps));
        // Wikipedia's profile: 27.2M entries, 7.7 GiB and 3.2 GiB indexes: measured 292 MiB open plus about 3 MiB
        let wiki = Profile { entries: 27_199_921, fulltext_bytes: 7900 * MIB, title_bytes: 3300 * MIB };
        let c = archive_cost(&wiki, &caps) / MIB;
        assert!((280..330).contains(&c), "{c}");
        let small = Profile { entries: 1000, fulltext_bytes: 10 * MIB, title_bytes: MIB };
        let big = Profile { entries: 27_000_000, fulltext_bytes: 8000 * MIB, title_bytes: 3000 * MIB };
        assert!(archive_cost(&Profile::default(), &caps) > 0);
        assert!(archive_cost(&small, &caps) < archive_cost(&big, &caps));
        let more = Caps { dirent_cache: caps.dirent_cache * 4, ..caps };
        assert!(archive_cost(&small, &caps) < archive_cost(&small, &more));
        assert!(archive_cost(&Profile { entries: u64::MAX, fulltext_bytes: u64::MAX, title_bytes: u64::MAX }, &caps) > 0);
    }

    #[test]
    fn the_defaults_per_target() {
        assert_eq!(default_budget_mb(true), 384);
        assert_eq!(default_budget_mb(false), 1024);
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
