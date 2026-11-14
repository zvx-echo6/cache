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
    /// The peer's newer version of a file held here, which may not replace it ([`keep_mine`]): written beside it under
    /// [`beside_name`], the file here left as it is.
    Beside { path: String, entry: Entry },
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

/// What is left of `actions` (from [`merge`] with `local`) when the peer may not replace or remove copies here ("Don't replace
/// my copies from this device"). In a share of things the person made (`beside`): no delete, and a newer version of a file
/// held here comes beside it instead ([`Action::Beside`]); what is not held here (a new file, a rename's new path, a file
/// deleted here) still comes, versions are still taken, and a file changed here against the peer's delete is still kept.
/// In any other share (things that can be downloaded again, and whose files only make sense together, such as a database
/// and its log): nothing of the peer's is taken, only a file changed here is still kept against its delete.
pub fn keep_mine(local: &Index, actions: Vec<Action>, beside: bool) -> Vec<Action> {
    let held = |path: &str| local.files.get(path).map(|e| !e.deleted).unwrap_or(false);
    actions
        .into_iter()
        .filter_map(|a| match a {
            Action::Keep { .. } => Some(a),
            _ if !beside => None,
            Action::Delete { .. } => None,
            Action::Fetch { path, entry, .. } if held(&path) => Some(Action::Beside { path, entry }),
            a => Some(a),
        })
        .collect()
}

/// "notes.md" -> "notes (from Pixel).md", or with `stamp` "notes (from Pixel, 2026-11-14 1712).md": where a linked device's
/// newer version of a file held here is written beside it ([`Action::Beside`]).
pub fn beside_name(path: &str, device: &str, stamp: Option<&str>) -> String {
    let (dir, file) = match path.rfind('/') {
        Some(i) => (&path[..=i], &path[i + 1..]),
        None => ("", path),
    };
    let (stem, ext) = match file.rfind('.') {
        Some(i) if i > 0 => (&file[..i], &file[i..]),
        _ => (file, ""),
    };
    let device: String = device.chars().filter(|c| !matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|')).collect();
    match stamp {
        Some(t) => format!("{dir}{stem} (from {device}, {t}){ext}"),
        None => format!("{dir}{stem} (from {device}){ext}"),
    }
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

    fn kinds(actions: &[Action]) -> Vec<(String, &'static str)> {
        actions
            .iter()
            .map(|a| match a {
                Action::Fetch { path, .. } => (path.clone(), "fetch"),
                Action::Delete { path, .. } => (path.clone(), "delete"),
                Action::Adopt { path, .. } => (path.clone(), "adopt"),
                Action::Keep { path } => (path.clone(), "keep"),
                Action::Beside { path, .. } => (path.clone(), "beside"),
            })
            .collect()
    }

    #[test]
    fn keeping_mine_never_replaces_or_removes_a_file_here() {
        let base = e("h1", 10, "A");
        let l = idx(&[
            ("edit", base.clone()),
            ("del", base.clone()),
            ("both", base.next("A", 15, "hA".into(), 1, false)),
            ("gone-here", base.next("A", 12, "h1".into(), 1, true)),
            ("same", base.clone()),
            ("kept", base.next("A", 15, "hA".into(), 1, false)),
        ]);
        let r = idx(&[
            ("edit", base.next("B", 20, "h2".into(), 1, false)),
            ("del", base.next("B", 20, "h1".into(), 1, true)),
            ("both", base.next("B", 20, "hB".into(), 1, false)),
            ("gone-here", base.next("B", 20, "hB".into(), 1, false)),
            ("same", e("h1", 20, "B")),
            ("kept", base.next("B", 20, "h1".into(), 1, true)),
            ("new", e("hN", 20, "B")),
        ]);
        let all = merge(&l, &r);
        assert_eq!(all.len(), 7);
        let s = |v: &[(&str, &'static str)]| v.iter().map(|(p, k)| (p.to_string(), *k)).collect::<Vec<_>>();
        // Things the person made: newer versions of what is here come beside it; no delete; the rest as ever.
        assert_eq!(
            kinds(&keep_mine(&l, all.clone(), true)),
            s(&[("both", "beside"), ("edit", "beside"), ("gone-here", "fetch"), ("kept", "keep"), ("new", "fetch"), ("same", "adopt")])
        );
        // Anything else: nothing of the peer's, only our changed file kept against its delete.
        assert_eq!(kinds(&keep_mine(&l, all, false)), s(&[("kept", "keep")]));
    }

    #[test]
    fn beside_names_say_which_device_and_keep_folder_and_extension() {
        assert_eq!(beside_name("Journal/notes.md", "Pixel", None), "Journal/notes (from Pixel).md");
        assert_eq!(beside_name("Journal/notes.md", "Pixel", Some("2026-11-14 1712")), "Journal/notes (from Pixel, 2026-11-14 1712).md");
        assert_eq!(beside_name("photos/.x", "a/b:c", None), "photos/.x (from abc)");
    }

    #[test]
    fn conflict_names_keep_folder_and_extension() {
        assert_eq!(conflict_name("docs/notes.txt", "Pixel", "2026-10-28 0412"), "docs/notes (conflict, Pixel, 2026-10-28 0412).txt");
        assert_eq!(conflict_name(".env", "PC", "x"), ".env (conflict, PC, x)");
    }
}
