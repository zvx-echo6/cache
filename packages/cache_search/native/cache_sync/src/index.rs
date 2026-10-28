//! What a device knows about the files of one shared folder, and how two devices' views merge.
//!
//! Every file has an entry: its content hash (BLAKE3, the same hash iroh-blobs moves it by), size, whether it was deleted, and a
//! version (`ver`, milliseconds, plus the device that made it). An edit or delete makes a new version that names the versions it
//! replaced (`hist`). When two devices compare, the newer version wins, unless the newer one never saw the other side's version
//! (it is not in its history): then both sides edited the same file without knowing, and nothing is lost. The local file is kept
//! as a conflict copy beside the incoming one, and a delete never removes a file someone else changed in the meantime.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

/// How many earlier versions an entry remembers (enough for a device that was away through many edits).
pub const HIST: usize = 64;

#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub struct Ver {
    pub at: u64,
    pub by: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entry {
    pub hash: String,
    pub size: u64,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub deleted: bool,
    pub ver: Ver,
    /// The versions this one replaced, oldest first.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hist: Vec<Ver>,
}

impl Entry {
    /// A new version of this entry made on `me` at `now` (never older than the version it replaces).
    pub fn next(&self, me: &str, now: u64, hash: String, size: u64, deleted: bool) -> Entry {
        let mut hist = self.hist.clone();
        hist.push(self.ver.clone());
        if hist.len() > HIST {
            hist.drain(..hist.len() - HIST);
        }
        Entry { hash, size, deleted, ver: Ver { at: now.max(self.ver.at + 1), by: me.to_string() }, hist }
    }

    /// True when this entry's history includes `v` (it was made by someone who had seen `v`).
    pub fn saw(&self, v: &Ver) -> bool {
        self.ver == *v || self.hist.iter().any(|h| h == v)
    }
}

/// What the device holds for one shared folder.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Index {
    pub files: BTreeMap<String, Entry>,
}

/// What to do with one path after comparing with a peer.
#[derive(Debug, Clone, PartialEq)]
pub enum Action {
    /// The peer's version is newer and has content: fetch it. `conflict` keeps the local file as a copy first.
    Fetch { path: String, entry: Entry, conflict: bool },
    /// The peer's version is newer and is a delete of what is here.
    Delete { path: String, entry: Entry },
    /// The peer's version is newer but the content is the same (or both deleted): take the version only.
    Adopt { path: String, entry: Entry },
    /// The peer deleted a file that was changed here meanwhile: keep it, as a new version so the peer gets it back.
    Keep { path: String },
}

/// Compares the local index with a peer's, path by path. Only newer peer versions produce actions; anything newer here is the
/// peer's to fetch from us.
pub fn merge(local: &Index, remote: &Index) -> Vec<Action> {
    let mut out = Vec::new();
    for (path, r) in &remote.files {
        let Some(l) = local.files.get(path) else {
            if r.deleted {
                out.push(Action::Adopt { path: path.clone(), entry: r.clone() });
            } else {
                out.push(Action::Fetch { path: path.clone(), entry: r.clone(), conflict: false });
            }
            continue;
        };
        if r.ver <= l.ver {
            continue;
        }
        let same = l.deleted == r.deleted && (r.deleted || l.hash == r.hash);
        if same {
            out.push(Action::Adopt { path: path.clone(), entry: r.clone() });
            continue;
        }
        // The peer's version was made without seeing ours: both changed it.
        let concurrent = !r.saw(&l.ver);
        match (r.deleted, l.deleted) {
            (true, false) if concurrent => out.push(Action::Keep { path: path.clone() }),
            (true, false) => out.push(Action::Delete { path: path.clone(), entry: r.clone() }),
            (false, _) => out.push(Action::Fetch { path: path.clone(), entry: r.clone(), conflict: concurrent && !l.deleted }),
            (true, true) => out.push(Action::Adopt { path: path.clone(), entry: r.clone() }),
        }
    }
    out
}

/// "notes.txt" -> "notes (conflict, Pixel, 2026-10-28 0412).txt": the name a local copy keeps when both sides changed a file.
pub fn conflict_name(path: &str, device: &str, stamp: &str) -> String {
    let (dir, file) = match path.rfind('/') {
        Some(i) => (&path[..=i], &path[i + 1..]),
        None => ("", path),
    };
    let (stem, ext) = match file.rfind('.') {
        Some(i) if i > 0 => (&file[..i], &file[i..]),
        _ => (file, ""),
    };
    let device: String = device.chars().filter(|c| !matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|')).collect();
    format!("{dir}{stem} (conflict, {device}, {stamp}){ext}")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn e(hash: &str, at: u64, by: &str) -> Entry {
        Entry { hash: hash.into(), size: 1, deleted: false, ver: Ver { at, by: by.into() }, hist: vec![] }
    }

    fn idx(entries: &[(&str, Entry)]) -> Index {
        Index { files: entries.iter().map(|(p, e)| (p.to_string(), e.clone())).collect() }
    }

    #[test]
    fn new_file_on_the_peer_is_fetched_and_older_ones_are_left() {
        let l = idx(&[("a", e("h1", 10, "A"))]);
        let r = idx(&[("a", e("h0", 5, "B")), ("b", e("h2", 7, "B"))]);
        assert_eq!(merge(&l, &r), vec![Action::Fetch { path: "b".into(), entry: e("h2", 7, "B"), conflict: false }]);
    }

    #[test]
    fn an_edit_made_after_seeing_ours_replaces_it_without_a_conflict() {
        let base = e("h1", 10, "A");
        let l = idx(&[("a", base.clone())]);
        let edit = base.next("B", 20, "h2".into(), 1, false).next("B", 30, "h3".into(), 1, false);
        let r = idx(&[("a", edit.clone())]);
        assert_eq!(merge(&l, &r), vec![Action::Fetch { path: "a".into(), entry: edit, conflict: false }]);
    }

    #[test]
    fn edits_on_both_sides_keep_a_conflict_copy() {
        let base = e("h1", 10, "A");
        let l = idx(&[("a", base.next("A", 15, "hA".into(), 1, false))]);
        let theirs = base.next("B", 20, "hB".into(), 1, false);
        let r = idx(&[("a", theirs.clone())]);
        assert_eq!(merge(&l, &r), vec![Action::Fetch { path: "a".into(), entry: theirs, conflict: true }]);
    }

    #[test]
    fn a_delete_removes_the_file_only_if_it_was_not_changed_here_meanwhile() {
        let base = e("h1", 10, "A");
        let del = base.next("B", 20, "h1".into(), 1, true);
        assert_eq!(merge(&idx(&[("a", base.clone())]), &idx(&[("a", del.clone())])), vec![Action::Delete { path: "a".into(), entry: del.clone() }]);
        let edited = idx(&[("a", base.next("A", 15, "hA".into(), 1, false))]);
        assert_eq!(merge(&edited, &idx(&[("a", del)])), vec![Action::Keep { path: "a".into() }]);
    }

    #[test]
    fn the_same_content_only_takes_the_version() {
        let l = idx(&[("a", e("h1", 10, "A"))]);
        let r = idx(&[("a", e("h1", 12, "B"))]);
        assert_eq!(merge(&l, &r), vec![Action::Adopt { path: "a".into(), entry: e("h1", 12, "B") }]);
    }

    #[test]
    fn conflict_names_keep_folder_and_extension() {
        assert_eq!(conflict_name("docs/notes.txt", "Pixel", "2026-10-28 0412"), "docs/notes (conflict, Pixel, 2026-10-28 0412).txt");
        assert_eq!(conflict_name(".env", "PC", "x"), ".env (conflict, PC, x)");
    }
}
