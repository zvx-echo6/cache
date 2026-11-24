//! Counters, summaries and differences (Reticulum step 3, part 1): what lets a device ask another "what changed since N" instead
//! of for its whole file list, and keep the answer as a mirror of that device's view.
//!
//! The sender stamps its saved index ([`stamp`]): every changed or added entry takes the folder's next counter; a removed
//! entry starts a new epoch (a removal cannot be told as "changed since N"). The receiver keeps, per linked device and folder,
//! a [`Mirror`]: that device's view as received, with the epoch, cursor and filter fingerprint it has caught up to, saved in
//! one write. The merge then runs against the mirror exactly as it ran against a full file list, so everything that depends on
//! the full comparison (a forgotten entry, a retried fetch, a changed fetch pattern, `providers`) is as it was.

use crate::index::{Entry, Index};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// The most one page of differences carries, in bytes of JSON (one entry larger than this goes alone).
pub const PAGE_BYTES: usize = 1024 * 1024;

/// A fresh epoch: random, so no two histories of a folder share one.
pub fn new_epoch() -> String {
    let n: [u8; 8] = rand::random();
    n.iter().map(|b| format!("{b:02x}")).collect()
}

/// `new` (about to be saved) stamped against `old` (what is saved now): the epoch and counter of `old`, the counter of an
/// unchanged entry kept, the next counter on every changed or added entry (one increment for the whole call), and a new epoch
/// when an entry of `old` is gone from `new` or `old` has no epoch yet. Whatever epoch, counter or entry counters the caller
/// loaded or took from a peer are not looked at.
pub fn stamp(old: &Index, new: &Index) -> Index {
    let removed = old.files.keys().any(|p| !new.files.contains_key(p));
    let mut out = Index { files: BTreeMap::new(), epoch: old.epoch.clone(), counter: old.counter };
    if removed || out.epoch.is_empty() {
        out.epoch = new_epoch();
    }
    let next = old.counter + 1;
    let mut used = false;
    for (p, e) in &new.files {
        let mut e = e.clone();
        match old.files.get(p) {
            Some(o) if *o == e => e.ctr = o.ctr,
            _ => {
                e.ctr = next;
                used = true;
            }
        }
        out.files.insert(p.clone(), e);
    }
    if used {
        out.counter = next;
    }
    out
}

/// One path that changed: its entry in the asking device's view, or `None` when it is not in that view now (it left the view
/// without leaving the index, for instance a delete that stays on this device), and the counter of the change.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Change {
    pub p: String,
    pub c: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub e: Option<Entry>,
}

/// The answer to a request for differences.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Page {
    /// The epoch could not be followed (it differs, or the cursor is ahead of the folder): ask for the whole list.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub full: bool,
    /// The folder's counter when this page was made.
    #[serde(default)]
    pub counter: u64,
    /// More follow this page.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub more: bool,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub changes: Vec<Change>,
}

/// What a device asks for differences with: its saved epoch, the filter fingerprint it was told, and the cursor (the counter and,
/// within it, the last path taken; no path: the whole counter was taken).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DiffAsk {
    pub share: String,
    pub epoch: String,
    pub fp: String,
    pub c: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub p: Option<String>,
}

/// The changes of `idx` after the cursor (`c`, `p`) in epoch `epoch`, as the asking device's view (`admits`) has them, ordered
/// by (counter, path), at most about `cap` bytes of them. `full` when `idx` has another epoch or is behind the cursor.
pub fn diff_page(idx: &Index, epoch: &str, c: u64, p: Option<&str>, admits: &dyn Fn(&str, &Entry) -> bool, cap: usize) -> Page {
    if idx.epoch.is_empty() || idx.epoch != epoch || c > idx.counter {
        return Page { full: true, ..Page::default() };
    }
    let mut items: Vec<(&String, &Entry)> = idx
        .files
        .iter()
        .filter(|(path, e)| e.ctr > c || (e.ctr == c && p.is_some_and(|cp| path.as_str() > cp)))
        .collect();
    // The files are in path order and the sort is stable: ordered by (counter, path).
    items.sort_by_key(|(_, e)| e.ctr);
    let mut page = Page { counter: idx.counter, ..Page::default() };
    let mut bytes = 0;
    for (n, (path, e)) in items.iter().enumerate() {
        let ch = Change { p: (*path).clone(), c: e.ctr, e: admits(path, e).then(|| (*e).clone()) };
        let len = serde_json::to_vec(&ch).map(|v| v.len()).unwrap_or(0);
        if n > 0 && bytes + len > cap {
            page.more = true;
            break;
        }
        bytes += len;
        page.changes.push(ch);
    }
    page
}

/// A linked device's view of one folder as received, and how far it has been followed. Saved in one write.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Mirror {
    /// The epoch, filter fingerprint and counter caught up to. Mid-paging, `after` is the last path taken within `ctr`.
    pub epoch: String,
    pub fp: String,
    pub ctr: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub after: Option<String>,
    pub files: BTreeMap<String, Entry>,
}

impl Mirror {
    /// A whole list taken as the mirror: caught up to its own counter.
    pub fn from_full(idx: &Index, fp: &str) -> Mirror {
        Mirror { epoch: idx.epoch.clone(), fp: fp.to_string(), ctr: idx.counter, after: None, files: idx.files.clone() }
    }

    /// The mirror is for the sender's epoch and filter, and not ahead of its counter.
    pub fn follows(&self, epoch: &str, fp: &str, counter: u64) -> bool {
        !epoch.is_empty() && self.epoch == epoch && self.fp == fp && self.ctr <= counter
    }

    /// Caught up to `counter` (or past it: the folder moved on while the pages were being taken).
    pub fn is_at(&self, counter: u64) -> bool {
        self.ctr >= counter && self.after.is_none()
    }

    /// Takes a page: the changes, then the cursor moves to the last one (more follow) or to the page's counter (caught up).
    /// Taking a page twice leaves the same mirror.
    pub fn take(&mut self, page: &Page) {
        for ch in &page.changes {
            match &ch.e {
                Some(e) => {
                    self.files.insert(ch.p.clone(), e.clone());
                }
                None => {
                    self.files.remove(&ch.p);
                }
            }
        }
        match (page.more, page.changes.last()) {
            (true, Some(last)) => {
                self.ctr = last.c;
                self.after = Some(last.p.clone());
            }
            _ => {
                self.ctr = page.counter;
                self.after = None;
            }
        }
    }

    pub fn index(&self) -> Index {
        Index { files: self.files.clone(), epoch: self.epoch.clone(), counter: self.ctr }
    }
}

/// A hash of what decides a device's view, from labelled parts the caller has put in sorted order.
pub fn fingerprint(parts: &[(&str, Vec<String>)]) -> String {
    let mut h = blake3::Hasher::new();
    h.update(b"cache view v1");
    for (label, items) in parts {
        h.update(&(label.len() as u64).to_le_bytes());
        h.update(label.as_bytes());
        h.update(&(items.len() as u64).to_le_bytes());
        for i in items {
            h.update(&(i.len() as u64).to_le_bytes());
            h.update(i.as_bytes());
        }
    }
    h.finalize().to_hex().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::{merge, Ver};

    fn e(hash: &str, at: u64) -> Entry {
        Entry { hash: hash.into(), size: 1, deleted: false, ver: Ver { at, by: "A".into() }, hist: vec![], ctr: 0 }
    }

    fn all(_: &str, _: &Entry) -> bool {
        true
    }

    /// A small deterministic generator.
    struct Rng(u64);
    impl Rng {
        fn next(&mut self, n: u64) -> u64 {
            self.0 ^= self.0 << 13;
            self.0 ^= self.0 >> 7;
            self.0 ^= self.0 << 17;
            self.0 % n
        }
    }

    fn put(idx: &mut Index, path: &str, hash: &str, at: u64, deleted: bool) {
        let ent = match idx.files.get(path) {
            Some(old) => old.next("A", at, hash.into(), 1, deleted),
            None => Entry { deleted, ..e(hash, at) },
        };
        idx.files.insert(path.into(), ent);
    }

    #[test]
    fn stamp_numbers_changes_once_and_keeps_unchanged_entries() {
        let mut a = Index::default();
        put(&mut a, "x", "h1", 10, false);
        put(&mut a, "y", "h2", 10, false);
        let s1 = stamp(&Index::default(), &a);
        assert_eq!(s1.counter, 1);
        assert!(!s1.epoch.is_empty());
        assert!(s1.files.values().all(|e| e.ctr == 1));
        // Nothing changed: nothing moves, whatever counters the caller carries.
        let mut again = s1.clone();
        again.counter = 77;
        again.files.get_mut("x").unwrap().ctr = 9;
        let s2 = stamp(&s1, &again);
        assert_eq!((s2.counter, &s2.epoch), (1, &s1.epoch));
        assert_eq!(s2.files["x"].ctr, 1);
        // One edit and one new file share the next counter.
        let mut b = s1.clone();
        put(&mut b, "x", "h3", 20, false);
        put(&mut b, "z", "h4", 20, false);
        let s3 = stamp(&s1, &b);
        assert_eq!(s3.counter, 2);
        assert_eq!((s3.files["x"].ctr, s3.files["y"].ctr, s3.files["z"].ctr), (2, 1, 2));
        assert_eq!(s3.epoch, s1.epoch);
        // A delete-version is a change; removing the entry outright is a new epoch.
        let mut c = s3.clone();
        put(&mut c, "y", "h2", 30, true);
        let s4 = stamp(&s3, &c);
        assert_eq!((s4.counter, s4.files["y"].ctr, &s4.epoch), (3, 3, &s3.epoch));
        let mut d = s4.clone();
        d.files.remove("z");
        let s5 = stamp(&s4, &d);
        assert_ne!(s5.epoch, s4.epoch);
    }

    #[test]
    fn a_legacy_index_gets_an_epoch_and_keeps_counter_zero_entries() {
        let mut a = Index::default();
        put(&mut a, "x", "h1", 10, false);
        let s = stamp(&a, &a);
        assert!(!s.epoch.is_empty());
        assert_eq!((s.counter, s.files["x"].ctr), (0, 0));
    }

    /// The correctness rule: after catching up from any point, the mirror is the sender's view, whatever the page size, and the
    /// merge against it is the merge against the full view.
    #[test]
    fn a_mirror_that_follows_in_pages_equals_the_view_and_merges_the_same() {
        for seed in 1..40u64 {
            let mut rng = Rng(seed * 7919);
            let mut sender = stamp(&Index::default(), &Index::default());
            let mut local = Index::default();
            for p in ["a", "b", "c", "d", "e", "f", "g", "h"] {
                if rng.next(2) == 0 {
                    put(&mut local, p, &format!("l{p}"), 5, false);
                }
            }
            // A path ending in "~" never reaches the asking device (its view leaves it out).
            let admits = |p: &str, _: &Entry| !p.ends_with('~');
            let view = |i: &Index| Index { files: i.files.iter().filter(|(p, e)| admits(p, e)).map(|(p, e)| (p.clone(), e.clone())).collect(), epoch: i.epoch.clone(), counter: i.counter };
            let mut mirror = Mirror::from_full(&view(&sender), "fp");
            let cap = [60, 200, 100_000][rng.next(3) as usize];
            for step in 0..30u64 {
                // The sender changes a few things (sometimes removing an entry outright), the receiver follows now and then.
                let mut next = sender.clone();
                for _ in 0..rng.next(4) {
                    let p = ["a", "b", "c", "d", "e", "f", "g", "h", "i~", "j~"][rng.next(10) as usize];
                    match rng.next(5) {
                        0 => put(&mut next, p, "gone", 100 + step, true),
                        1 if next.files.contains_key(p) && rng.next(8) == 0 => {
                            next.files.remove(p);
                        }
                        _ => put(&mut next, p, &format!("h{}", rng.next(5)), 100 + step, false),
                    }
                }
                sender = stamp(&sender, &next);
                if rng.next(3) != 0 {
                    continue;
                }
                // The receiver's round.
                loop {
                    if mirror.follows(&sender.epoch, "fp", sender.counter) {
                        if mirror.is_at(sender.counter) {
                            break;
                        }
                        let page = diff_page(&sender, &mirror.epoch, mirror.ctr, mirror.after.as_deref(), &admits, cap);
                        assert!(!page.full);
                        // Applying a page twice changes nothing.
                        let mut twice = mirror.clone();
                        twice.take(&page);
                        let once = twice.clone();
                        twice.take(&page);
                        assert_eq!(once, twice);
                        mirror = once;
                    } else {
                        mirror = Mirror::from_full(&view(&sender), "fp");
                        break;
                    }
                }
                let want = view(&sender);
                assert_eq!(mirror.files, want.files, "seed {seed} step {step}");
                assert_eq!(merge(&local, &mirror.index()), merge(&local, &want));
            }
        }
    }

    #[test]
    fn a_page_can_split_entries_that_share_a_counter() {
        let mut a = Index::default();
        for i in 0..10 {
            put(&mut a, &format!("f{i}"), "h", 10, false);
        }
        let s = stamp(&Index::default(), &a);
        assert!(s.files.values().all(|e| e.ctr == 1));
        let mut m = Mirror { epoch: s.epoch.clone(), fp: "fp".into(), ..Mirror::default() };
        let mut pages = 0;
        while !m.is_at(s.counter) {
            let page = diff_page(&s, &m.epoch, m.ctr, m.after.as_deref(), &all, 150);
            assert!(!page.changes.is_empty());
            m.take(&page);
            pages += 1;
            assert!(pages < 20);
        }
        assert!(pages > 2, "split over several pages: {pages}");
        assert_eq!(m.files, s.files);
    }

    #[test]
    fn a_mirror_that_took_a_page_made_after_the_summary_is_caught_up() {
        let mut m = Mirror { epoch: "e".into(), fp: "fp".into(), ctr: 3, ..Mirror::default() };
        m.take(&Page { counter: 5, ..Page::default() });
        assert!(m.is_at(4) && m.is_at(5) && !m.is_at(6));
        m.after = Some("x".into());
        assert!(!m.is_at(4), "mid-paging is not caught up");
    }

    #[test]
    fn another_epoch_or_a_cursor_ahead_is_answered_full() {
        let mut a = Index::default();
        put(&mut a, "x", "h", 10, false);
        let s = stamp(&Index::default(), &a);
        assert!(diff_page(&s, "other", 0, None, &all, PAGE_BYTES).full);
        assert!(diff_page(&s, &s.epoch, 5, None, &all, PAGE_BYTES).full);
        assert!(diff_page(&Index::default(), "", 0, None, &all, PAGE_BYTES).full);
        assert!(!diff_page(&s, &s.epoch, 0, None, &all, PAGE_BYTES).full);
    }

    #[test]
    fn the_fingerprint_follows_every_part() {
        let base = fingerprint(&[("skip", vec!["a".into()]), ("off", vec![])]);
        assert_eq!(base, fingerprint(&[("skip", vec!["a".into()]), ("off", vec![])]));
        assert_ne!(base, fingerprint(&[("skip", vec!["a".into(), "b".into()]), ("off", vec![])]));
        assert_ne!(base, fingerprint(&[("skip", vec![]), ("off", vec!["a".into()])]));
        // Moving an item from one part to the next is not the same input.
        assert_ne!(fingerprint(&[("a", vec!["x".into()]), ("b", vec![])]), fingerprint(&[("a", vec![]), ("b", vec!["x".into()])]));
    }

    #[test]
    fn an_old_reader_loads_a_file_this_build_wrote() {
        // The index structs as build 48 had them (copied here): no epoch, no counters, nothing denies unknown fields.
        #[derive(Debug, Deserialize, Serialize, PartialEq)]
        struct OldVer {
            at: u64,
            by: String,
        }
        #[derive(Debug, Deserialize, Serialize, PartialEq)]
        struct OldEntry {
            hash: String,
            size: u64,
            #[serde(default, skip_serializing_if = "std::ops::Not::not")]
            deleted: bool,
            ver: OldVer,
            #[serde(default, skip_serializing_if = "Vec::is_empty")]
            hist: Vec<OldVer>,
        }
        #[derive(Debug, Deserialize, Serialize)]
        struct OldIndex {
            files: BTreeMap<String, OldEntry>,
        }
        let mut a = Index::default();
        put(&mut a, "x", "h1", 10, false);
        put(&mut a, "x", "h2", 20, false);
        put(&mut a, "y", "h3", 10, true);
        let new = stamp(&Index::default(), &a);
        let bytes = serde_json::to_vec(&new).unwrap();
        assert!(String::from_utf8_lossy(&bytes).contains("\"epoch\""));
        let old: OldIndex = serde_json::from_slice(&bytes).expect("the old reader takes the new file");
        assert_eq!(old.files.len(), 2);
        assert_eq!(old.files["x"].hash, "h2");
        assert_eq!(old.files["x"].hist.len(), 1);
        assert!(old.files["y"].deleted);
        // And an old file is read by this build, with no epoch and no counters.
        let legacy = serde_json::to_vec(&old).unwrap();
        let back: Index = serde_json::from_slice(&legacy).unwrap();
        assert_eq!((back.epoch.as_str(), back.counter, back.files["x"].ctr), ("", 0, 0));
        // A Ver and its history survive the JSON form exactly.
        let again: Index = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(again.files["x"].hist, new.files["x"].hist);
        assert_eq!(again.files["x"].ver, new.files["x"].ver);
    }
}
