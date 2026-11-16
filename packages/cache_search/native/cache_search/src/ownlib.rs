//! A person's own library (My books), kept by each device for itself (`own_library_sync` job).
//!
//! Every device of the person adds books to the same own library. Its packs (`packs/<doc_id>@<version>.cdoc`, immutable, written
//! once by the device that built the book) and its PDFs (`bookshelf/<BLAKE3>.pdf`, named by their content) sync between the
//! devices. What is made FROM the packs does not: the shard, `copies.jsonl`, `documents.tsv` and `SHA256SUMS` (the app leaves them
//! out of the `libraries` share, `kLibraryNotShared`). Before that, two devices that each added a book while apart both rewrote the
//! shard and the lists, and the sync kept one side per file: one book lost its search and its list row, or the shard was put
//! together from both devices' files (tools/books-proof).
//!
//! This job makes the library's own files match its packs on this device:
//! 1. **Conflict copies** that sync left in the library are removed ([`conflict_live_name`] says exactly what one is; see
//!    [`remove_conflict_copies`]). Those in `shard/` go with the old shard.
//! 2. **The packs** are read (the newest version of each `doc_id`; a pack that cannot be read is reported and left alone).
//! 3. **Up to date** when this device has rebuilt the library before (`.local/own-shard.json`, never synced), the lists name exactly
//!    the packs (by `doc_id` and version), and the shard holds exactly their pieces. Then nothing is written.
//! 4. Otherwise **the shard is rebuilt** from the packs' own vectors (no embedding): a new shard holding every piece of every pack,
//!    the lists made again from the packs, `SHA256SUMS` when the library has one, all swapped in by the same journaled commit an
//!    Add PDF uses (all or nothing, rolled forward after a kill). The device keyword index is removed and built again by
//!    `index_library`. So a book whose pack arrived (from another device, or left behind by the bug) is searchable again, and the
//!    first run on a device after the update always rebuilds (the marker is not there yet).
//!
//! Only a person's own library is touched: its `cache-library.json` says `"own": true` and its folder name starts with
//! `my-books` (how the app names them: My books is `my-books`, `my-books-2`, ...; an own library restored from an export is named
//! by its id, `my-books-<time>`). A downloaded or shared library is never changed by this job.
use crate::error::{Error, Result};
use crate::ingest::begin_write_with;
use cache_ingest::{commit, files, Point, Staged};
use cache_pack::pack::{read_pack_bytes, Pack};
use cache_pack::points::{payload_of, point_uuid};
use cache_shelves::library::PackFacts;
use edge::EdgeShardRead;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

/// The folder-name prefix of a person's own libraries (also in the app's `kOwnLibraryPrefix`).
pub const OWN_PREFIX: &str = "my-books";
/// This device's note that it has rebuilt the library from its packs (hidden: never synced).
pub const MARKER: &str = ".local/own-shard.json";
const SETTINGS_FILE: &str = "cache-library.json";

fn io(what: &str, e: impl std::fmt::Display) -> Error {
    Error::io(format!("{what}: {e}"))
}

/// Whether `dir` is a person's own library: `"own": true` in its settings and a folder name starting with [`OWN_PREFIX`].
pub fn is_own_library(dir: &Path) -> bool {
    let named = dir.file_name().map(|n| n.to_string_lossy().starts_with(OWN_PREFIX)).unwrap_or(false);
    if !named {
        return false;
    }
    std::fs::read_to_string(dir.join(SETTINGS_FILE))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .map(|v| v.get("own") == Some(&Value::Bool(true)))
        .unwrap_or(false)
}

/// The name of the live file a sync conflict copy was made beside, when `name` is one: cache_sync names the local copy of a file
/// both devices changed `<stem> (conflict, <device>, <YYYY-MM-DD HHMM>[ UTC])<ext>` (`cache_sync::index::conflict_name`), so
/// `copies (conflict, A, 2026-11-14 1929 UTC).jsonl` -> `copies.jsonl`. Anything else (a title that merely has brackets in it)
/// is not one: the device part may not hold "(" or ")", and the stamp must be exactly the date and time.
pub fn conflict_live_name(name: &str) -> Option<String> {
    let start = name.find(" (conflict, ")?;
    let rest = &name[start + " (conflict, ".len()..];
    let close = rest.find(')')?;
    let inner = &rest[..close];
    let after = &rest[close + 1..];
    let (device, stamp) = inner.rsplit_once(", ")?;
    if device.is_empty() || device.contains('(') {
        return None;
    }
    let stamp = stamp.strip_suffix(" UTC").unwrap_or(stamp);
    let b = stamp.as_bytes();
    let digits = |r: std::ops::Range<usize>| r.into_iter().all(|i| b[i].is_ascii_digit());
    let stamp_ok = b.len() == 15 && digits(0..4) && b[4] == b'-' && digits(5..7) && b[7] == b'-' && digits(8..10) && b[10] == b' ' && digits(11..15);
    if !stamp_ok || (!after.is_empty() && !after.starts_with('.')) || after.contains('/') {
        return None;
    }
    let stem = &name[..start];
    if stem.is_empty() {
        return None;
    }
    Some(format!("{stem}{after}"))
}

/// Removes the sync conflict copies in the library, outside `shard/` (replaced whole by a rebuild) and the hidden and staging
/// names. A file is removed only when its name is a conflict copy ([`conflict_live_name`]) and the live file it was made beside
/// is there: the live file itself is never touched. Returns the paths removed, relative to the library.
pub fn remove_conflict_copies(lib: &Path) -> Vec<String> {
    fn walk(lib: &Path, dir: &Path, out: &mut Vec<String>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name.ends_with(".cs-stage") || name.ends_with(".cs-old") {
                continue;
            }
            let Ok(ft) = e.file_type() else { continue };
            let path = e.path();
            if ft.is_dir() {
                if dir == lib && (name == "shard" || name == "index") {
                    continue;
                }
                walk(lib, &path, out);
            } else if ft.is_file() {
                if let Some(live) = conflict_live_name(&name) {
                    if dir.join(&live).is_file() && std::fs::remove_file(&path).is_ok() {
                        out.push(path.strip_prefix(lib).map(|r| r.to_string_lossy().replace('\\', "/")).unwrap_or(name));
                    }
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(lib, lib, &mut out);
    out.sort();
    out
}

/// One readable pack of the library.
struct Book {
    pack: Pack,
    facts: PackFacts,
}

/// The newest readable pack of each `doc_id` in `packs/`, by `doc_id`; and the packs that could not be read.
fn read_packs(lib: &Path) -> (BTreeMap<String, Book>, Vec<String>) {
    let mut books: BTreeMap<String, Book> = BTreeMap::new();
    let mut bad = Vec::new();
    let Ok(rd) = std::fs::read_dir(lib.join(files::PACKS_DIR)) else { return (books, bad) };
    let mut names: Vec<String> = rd.flatten().filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false)).map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    names.sort();
    for name in names {
        if name.starts_with('.') || !name.ends_with(".cdoc") || conflict_live_name(&name).is_some() {
            continue;
        }
        let read = std::fs::read(lib.join(files::PACKS_DIR).join(&name)).map_err(|e| e.to_string()).and_then(|b| read_pack_bytes(&b).map_err(|e| e.to_string()));
        let pack = match read {
            Ok(p) => p,
            Err(e) => {
                bad.push(format!("{name}: {e}"));
                continue;
            }
        };
        let header = match serde_json::to_string(&pack.header) {
            Ok(h) => h,
            Err(e) => {
                bad.push(format!("{name}: {e}"));
                continue;
            }
        };
        let facts = match PackFacts::from_header_line(&header) {
            Ok(f) => f,
            Err(e) => {
                bad.push(format!("{name}: {e}"));
                continue;
            }
        };
        let newer = books.get(&pack.header.doc_id).map(|b| pack.header.doc_version > b.pack.header.doc_version).unwrap_or(true);
        if newer {
            books.insert(pack.header.doc_id.clone(), Book { pack, facts });
        }
    }
    (books, bad)
}

/// The (`doc_id`, version) pairs a copies file names.
fn copies_rows(text: Option<&str>) -> BTreeSet<(String, u32)> {
    text.unwrap_or("").lines().filter_map(|l| PackFacts::from_copies_line(l).ok()).map(|f| (f.doc_id, f.version)).collect()
}

/// The (`doc_id`, version) pairs a `documents.tsv` names (its header row is not one).
fn document_rows(text: Option<&str>) -> BTreeSet<(String, u32)> {
    text.unwrap_or("")
        .lines()
        .filter_map(|l| {
            let mut f = l.split('\t');
            let id = f.next()?.to_string();
            let v = f.next()?.parse::<u32>().ok()?;
            Some((id, v))
        })
        .collect()
}

fn shard_points(shard: &Path) -> Option<u64> {
    if !shard.is_dir() {
        return None;
    }
    let s = crate::library::open_shard_for_scroll(shard).ok()?;
    EdgeShardRead::count(&s, edge::CountRequest::new()).ok().map(|n| n as u64)
}

/// The `own_library_sync` job's work. `{"library_dir"}` -> `{"own", "rebuilt", "reason", "books", "points", "conflicts_removed",
/// "unreadable"}`.
pub fn sync(library_dir: &Path, cancelled: &dyn Fn() -> bool) -> Result<Value> {
    if !library_dir.is_dir() {
        return Err(Error::not_found(format!("library folder {} not found", library_dir.display())));
    }
    if !is_own_library(library_dir) {
        return Ok(json!({"own": false, "rebuilt": false}));
    }
    let lib = library_dir;
    let removed = remove_conflict_copies(lib);
    let (books, bad) = read_packs(lib);
    let want: BTreeSet<(String, u32)> = books.values().map(|b| (b.pack.header.doc_id.clone(), b.pack.header.doc_version)).collect();
    let pieces: u64 = books.values().map(|b| b.pack.pieces.len() as u64).sum();
    let copies_text = std::fs::read_to_string(files::copies_file(lib)).ok();
    let docs_text = std::fs::read_to_string(files::documents_file(lib)).ok();
    let shard = lib.join("shard");
    let reason = if !lib.join(MARKER).is_file() {
        Some("first rebuild on this device")
    } else if commit::pending(lib) {
        Some("an interrupted write")
    } else if copies_rows(copies_text.as_deref()) != want {
        Some("the book list does not match the packs")
    } else if document_rows(docs_text.as_deref()) != want {
        Some("the documents list does not match the packs")
    } else if shard_points(&shard) != Some(pieces) {
        Some("the shard does not hold exactly the packs' pieces")
    } else {
        None
    };
    let mut out = json!({
        "own": true,
        "rebuilt": false,
        "reason": reason,
        "books": books.len(),
        "points": pieces,
        "conflicts_removed": removed,
        "unreadable": bad,
    });
    let Some(_) = reason else { return Ok(out) };
    if cancelled() {
        return Err(Error::new(crate::error::ErrorCode::Cancelled, "cancelled"));
    }
    rebuild(lib, &books)?;
    out["rebuilt"] = json!(true);
    Ok(out)
}

/// A new shard and lists from `books`, swapped in all or nothing; then the marker.
fn rebuild(lib: &Path, books: &BTreeMap<String, Book>) -> Result<()> {
    let mut points: Vec<Point> = Vec::new();
    let mut copies = String::new();
    let mut docs: Option<String> = None;
    for b in books.values() {
        let (doc_id, version) = (&b.pack.header.doc_id, b.pack.header.doc_version);
        for i in 0..b.pack.pieces.len() {
            points.push(Point { id: point_uuid(doc_id, version, b.pack.pieces[i].index).to_string(), vector: b.pack.pieces[i].vector.clone(), payload: payload_of(&b.pack, i) });
        }
        copies = files::copies_with(Some(&copies), &b.facts);
        docs = Some(files::documents_with(docs.as_deref(), doc_id, version, &b.pack.header.title, &b.pack.header.source.blake3, b.pack.pieces.len(), b.pack.header.page_count));
    }
    let docs = docs.unwrap_or_else(|| "doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages\n".to_string());
    // the store first: it finishes a commit a kill interrupted, and the files below are written after that
    let mut staged = begin_write_with(lib, &points, true)?;
    let mut staged_files: Vec<(String, PathBuf)> = Vec::new();
    let cleanup = |v: &[(String, PathBuf)]| {
        for (_, t) in v {
            let _ = std::fs::remove_file(t);
        }
    };
    // the lists at the library's root; copies left inside the old shard go with it
    for (rel, data) in [(cache_shelves::library::COPIES_FILE, copies.as_bytes()), (files::DOCUMENTS_FILE, docs.as_bytes())] {
        match files::write_tmp(&lib.join(rel), data) {
            Ok(t) => staged_files.push((rel.to_string(), t)),
            Err(e) => {
                cleanup(&staged_files);
                return Err(io("writing the book lists", e.message));
            }
        }
    }
    let swaps = staged.plan();
    if lib.join(files::SUMS_FILE).is_file() {
        let mounts: Vec<(String, Option<PathBuf>)> = swaps.iter().map(|s| (s.target.clone(), s.stage.as_ref().map(|st| lib.join(st)))).collect();
        match files::sha256sums_staged(lib, &mounts, &staged_files).and_then(|t| files::write_tmp(&lib.join(files::SUMS_FILE), t.as_bytes())) {
            Ok(t) => staged_files.push((files::SUMS_FILE.to_string(), t)),
            Err(e) => {
                cleanup(&staged_files);
                return Err(io("writing SHA256SUMS", e.message));
            }
        }
    }
    let rel_of = |p: &Path| p.strip_prefix(lib).map(|r| r.to_string_lossy().replace('\\', "/")).unwrap_or_default();
    let mut steps: Vec<commit::Step> = swaps.iter().map(|s| commit::Step { target: s.target.clone(), stage: s.stage.clone(), old: format!("{}.cs-old", s.target) }).collect();
    for (rel, tmp) in &staged_files {
        steps.push(commit::Step { target: rel.clone(), stage: Some(rel_of(tmp)), old: commit::old_name_of_file(rel) });
    }
    let r = commit::run(lib, &steps, &mut staged as &mut dyn Staged);
    if !commit::pending(lib) {
        cleanup(&staged_files);
    }
    drop(staged);
    r.map_err(|e| io("rebuilding the library", e.message))?;
    let marker = lib.join(MARKER);
    std::fs::create_dir_all(marker.parent().unwrap_or(lib)).map_err(|e| io("writing the rebuild note", e))?;
    let note = json!({"v": 1, "books": books.len(), "points": books.values().map(|b| b.pack.pieces.len()).sum::<usize>()});
    let tmp = files::write_tmp(&marker, note.to_string().as_bytes()).map_err(|e| io("writing the rebuild note", e.message))?;
    std::fs::rename(&tmp, &marker).map_err(|e| io("writing the rebuild note", e))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn conflict_copies_are_recognised_exactly() {
        assert_eq!(conflict_live_name("copies (conflict, A, 2026-11-14 1929 UTC).jsonl").as_deref(), Some("copies.jsonl"));
        assert_eq!(conflict_live_name("documents (conflict, Pixel 8, 2026-11-14 1929).tsv").as_deref(), Some("documents.tsv"));
        assert_eq!(conflict_live_name("mutable_id_tracker (conflict, A, 2026-11-14 1929 UTC).mappings").as_deref(), Some("mutable_id_tracker.mappings"));
        assert_eq!(conflict_live_name("status (conflict, A, 2026-11-14 1934 UTC).dat").as_deref(), Some("status.dat"));
        assert_eq!(conflict_live_name("notes (conflict, A, 2026-11-14 1929)").as_deref(), Some("notes"));
        // not conflict copies: the live files, titles with brackets, a wrong stamp
        assert_eq!(conflict_live_name("copies.jsonl"), None);
        assert_eq!(conflict_live_name("War (conflict, 1914).pdf"), None);
        assert_eq!(conflict_live_name("x (conflict, A, 2026-11-14).jsonl"), None);
        assert_eq!(conflict_live_name("x (conflict, A, 2026-11-14 19:29).jsonl"), None);
        assert_eq!(conflict_live_name(" (conflict, A, 2026-11-14 1929).jsonl"), None);
        assert_eq!(conflict_live_name("x (conflict, (A), 2026-11-14 1929).jsonl"), None);
    }

    #[test]
    fn only_conflict_copies_beside_their_live_file_are_removed() {
        let lib = std::env::temp_dir().join(format!("cs_ownlib_conflicts_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&lib);
        std::fs::create_dir_all(lib.join("packs")).unwrap();
        std::fs::create_dir_all(lib.join("shard/segments/s")).unwrap();
        for f in [
            "copies.jsonl",
            "copies (conflict, A, 2026-11-14 1929 UTC).jsonl",
            "documents (conflict, A, 2026-11-14 1929 UTC).tsv",
            "packs/d@1.cdoc",
            "packs/d@1 (conflict, B, 2026-11-14 1930).cdoc",
            "shard/segments/s/status.dat",
            "shard/segments/s/status (conflict, A, 2026-11-14 1934 UTC).dat",
            "War (conflict, 1914).pdf",
        ] {
            std::fs::write(lib.join(f), b"x").unwrap();
        }
        let removed = remove_conflict_copies(&lib);
        assert_eq!(removed, vec!["copies (conflict, A, 2026-11-14 1929 UTC).jsonl".to_string(), "packs/d@1 (conflict, B, 2026-11-14 1930).cdoc".to_string()]);
        // the live files stay; a conflict copy with no live file beside it stays; the shard is not walked (a rebuild replaces it)
        for f in ["copies.jsonl", "packs/d@1.cdoc", "documents (conflict, A, 2026-11-14 1929 UTC).tsv", "shard/segments/s/status (conflict, A, 2026-11-14 1934 UTC).dat", "War (conflict, 1914).pdf"] {
            assert!(lib.join(f).is_file(), "{f} must stay");
        }
        let _ = std::fs::remove_dir_all(&lib);
    }

    #[test]
    fn only_own_libraries_named_as_the_app_names_them_are_own() {
        let root = std::env::temp_dir().join(format!("cs_ownlib_own_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        for (name, settings) in [("my-books", r#"{"own": true}"#), ("my-books-2", r#"{"own": true, "own_default": true}"#), ("medicine", r#"{"own": true}"#), ("my-books-x", r#"{"library_id": "x"}"#)] {
            std::fs::create_dir_all(root.join(name)).unwrap();
            std::fs::write(root.join(name).join(SETTINGS_FILE), settings).unwrap();
        }
        std::fs::create_dir_all(root.join("my-books-none")).unwrap();
        assert!(is_own_library(&root.join("my-books")));
        assert!(is_own_library(&root.join("my-books-2")));
        assert!(!is_own_library(&root.join("medicine")));
        assert!(!is_own_library(&root.join("my-books-x")));
        assert!(!is_own_library(&root.join("my-books-none")));
        let _ = std::fs::remove_dir_all(&root);
    }
}
