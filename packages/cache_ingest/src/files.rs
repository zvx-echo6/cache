//! The plain files of a library that a new book changes besides the shard and the keyword index: the pack in `packs/`, the line of
//! `copies.jsonl` and `SHA256SUMS`. Each is written under a temporary name first and renamed, so the job can put all of them in
//! place together or none.

use crate::error::{Error, Result};
use cache_shelves::library::{copies_path, PackFacts, COPIES_FILE};
use sha2::{Digest, Sha256};
use std::io::Write;
use std::path::{Path, PathBuf};

pub const PACKS_DIR: &str = "packs";
pub const SUMS_FILE: &str = "SHA256SUMS";
pub const DOCUMENTS_FILE: &str = "documents.tsv";

/// UTC milliseconds as `YYYY-MM-DDTHH:MM:SSZ`.
pub fn utc_text(ms: u64) -> String {
    let secs = ms / 1000;
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // days since 1970-01-01 to a civil date (Howard Hinnant's algorithm)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, (rem % 3600) / 60, rem % 60)
}

/// Writes `bytes` to a hidden temporary file beside `final_path` and flushes it to disk. Returns the temporary path.
pub fn write_tmp(final_path: &Path, bytes: &[u8]) -> Result<PathBuf> {
    let dir = final_path.parent().ok_or_else(|| Error::io("writing", "no folder"))?;
    std::fs::create_dir_all(dir).map_err(|e| Error::io(&format!("creating {}", dir.display()), e))?;
    let name = final_path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.ingest.tmp"));
    let write = || -> std::io::Result<()> {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()
    };
    write().map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        Error::io(&format!("writing {}", tmp.display()), e)
    })?;
    Ok(tmp)
}

/// Where `copies.jsonl` is written: where the library has one (the root, else `shard/`), else the root.
pub fn copies_file(library_dir: &Path) -> PathBuf {
    copies_path(library_dir).unwrap_or_else(|| library_dir.join(COPIES_FILE))
}

/// The copies file with the book's line added: a line of the same `doc_id` and version is replaced in place, else the new line
/// goes at the end. Other lines are kept exactly.
pub fn copies_with(existing: Option<&str>, facts: &PackFacts) -> String {
    let line = facts.to_copies_line();
    let mut out = String::new();
    let mut replaced = false;
    for l in existing.unwrap_or("").lines().filter(|l| !l.trim().is_empty()) {
        let same = PackFacts::from_copies_line(l).map(|f| f.doc_id == facts.doc_id && f.version == facts.version).unwrap_or(false);
        if same {
            if !replaced {
                out.push_str(&line);
                out.push('\n');
                replaced = true;
            }
        } else {
            out.push_str(l);
            out.push('\n');
        }
    }
    if !replaced {
        out.push_str(&line);
        out.push('\n');
    }
    out
}

/// Where `documents.tsv` is written: where the library has one (the root, else `shard/`), else the root.
pub fn documents_file(library_dir: &Path) -> PathBuf {
    [library_dir.join(DOCUMENTS_FILE), library_dir.join("shard").join(DOCUMENTS_FILE)].into_iter().find(|p| p.is_file()).unwrap_or_else(|| library_dir.join(DOCUMENTS_FILE))
}

fn tsv_field(s: &str) -> String {
    s.chars().map(|c| if matches!(c, '\t' | '\n' | '\r') { ' ' } else { c }).collect()
}

/// `documents.tsv` with the book's row added, in the format the library builder writes (a header row, then `doc_id`, `version`,
/// `title`, source BLAKE3, pieces, pages). A row of the same `doc_id` and version is replaced in place.
pub fn documents_with(existing: Option<&str>, doc_id: &str, version: u32, title: &str, source_blake3: &str, pieces: usize, pages: usize) -> String {
    let row = format!("{doc_id}\t{version}\t{}\t{source_blake3}\t{pieces}\t{pages}", tsv_field(title));
    let mut out = String::new();
    let mut replaced = false;
    let mut lines = existing.unwrap_or("").lines().filter(|l| !l.trim().is_empty()).peekable();
    if lines.peek().is_none() {
        out.push_str("doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages\n");
    }
    for l in lines {
        let mut f = l.split('\t');
        if f.next() == Some(doc_id) && f.next() == Some(&version.to_string()) {
            if !replaced {
                out.push_str(&row);
                out.push('\n');
                replaced = true;
            }
        } else {
            out.push_str(l);
            out.push('\n');
        }
    }
    if !replaced {
        out.push_str(&row);
        out.push('\n');
    }
    out
}

/// Whether the library already lists this copy (the same `doc_id` and version in its copies file).
pub fn lists_copy(library_dir: &Path, doc_id: &str, version: u32) -> bool {
    let Some(p) = copies_path(library_dir) else { return false };
    std::fs::read_to_string(p)
        .map(|t| t.lines().any(|l| PackFacts::from_copies_line(l).map(|f| f.doc_id == doc_id && f.version == version).unwrap_or(false)))
        .unwrap_or(false)
}

/// Names that are never listed: local files (a leading dot), and the copies and backups of a write (`*.cs-stage`, `*.cs-old`).
fn unlisted(name: &str) -> bool {
    name.starts_with('.') || name.ends_with(".cs-stage") || name.ends_with(".cs-old")
}

fn walk(base: &str, dir: &Path, mounts: &[(String, Option<PathBuf>)], walked: &mut Vec<String>, out: &mut Vec<(String, PathBuf)>) -> Result<()> {
    for e in std::fs::read_dir(dir).map_err(|e| Error::io(&format!("reading {}", dir.display()), e))? {
        let e = e.map_err(|e| Error::io("reading a folder", e))?;
        let name = e.file_name().to_string_lossy().into_owned();
        if unlisted(&name) {
            continue;
        }
        let rel = if base.is_empty() { name } else { format!("{base}/{name}") };
        let ft = e.file_type().map_err(|e| Error::io("reading a folder", e))?;
        if ft.is_dir() {
            if let Some((_, stage)) = mounts.iter().find(|(r, _)| *r == rel) {
                walked.push(rel.clone());
                if let Some(st) = stage {
                    walk(&rel, st, mounts, walked, out)?;
                }
            } else {
                walk(&rel, &e.path(), mounts, walked, out)?;
            }
        } else if ft.is_file() {
            out.push((rel, e.path()));
        }
    }
    Ok(())
}

/// The text of `SHA256SUMS` for the library `dir` as it will be once a commit has put its staged items in place: `<sha256 hex>
/// <relative path>` (two spaces) for every file (sorted by path, `/` separators), except itself, local files and the copies and
/// backups of a write. `mounts` are folders whose content comes from another folder (`shard` from `shard.cs-stage`; `None`: the
/// folder is gone); `overrides` are files whose content comes from a staged file (or that are new). The format the library builder
/// writes, checkable with `sha256sum -c`.
pub fn sha256sums_staged(dir: &Path, mounts: &[(String, Option<PathBuf>)], overrides: &[(String, PathBuf)]) -> Result<String> {
    let mut files: Vec<(String, PathBuf)> = Vec::new();
    let mut walked: Vec<String> = Vec::new();
    walk("", dir, mounts, &mut walked, &mut files)?;
    for (rel, stage) in mounts {
        if let (false, Some(st)) = (walked.contains(rel), stage) {
            walk(rel, st, mounts, &mut walked, &mut files)?;
        }
    }
    for (rel, path) in overrides {
        match files.iter_mut().find(|(r, _)| r == rel) {
            Some(f) => f.1 = path.clone(),
            None => files.push((rel.clone(), path.clone())),
        }
    }
    files.retain(|(r, _)| r != SUMS_FILE);
    files.sort_by(|a, b| a.0.cmp(&b.0));
    let mut text = String::new();
    for (rel, path) in &files {
        let mut f = std::fs::File::open(path).map_err(|e| Error::io(&format!("reading {rel}"), e))?;
        let mut h = Sha256::new();
        std::io::copy(&mut f, &mut h).map_err(|e| Error::io(&format!("reading {rel}"), e))?;
        let hex: String = h.finalize().iter().map(|b| format!("{b:02x}")).collect();
        text.push_str(&format!("{hex}  {rel}\n"));
    }
    Ok(text)
}

/// [`sha256sums_staged`] with nothing staged: the library as it is.
pub fn sha256sums_text(dir: &Path) -> Result<String> {
    sha256sums_staged(dir, &[], &[])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sums_skip_backups_and_copies_and_see_staged_items_as_if_swapped() {
        let d = tempfile::tempdir().unwrap();
        let w = |p: &str, c: &str| {
            let p = d.path().join(p);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, c).unwrap();
        };
        w("shard/a", "old");
        w("shard.cs-stage/a", "new");
        w("shard.cs-old/a", "older");
        w("index.cs-old/x", "x");
        w(".local/v", "v");
        w("copies.jsonl", "c");
        w("staged.tmp", "c2");
        let t = sha256sums_staged(d.path(), &[("shard".into(), Some(d.path().join("shard.cs-stage")))], &[("copies.jsonl".into(), d.path().join("staged.tmp")), ("packs/p.cdoc".into(), d.path().join("staged.tmp"))]).unwrap();
        let names: Vec<&str> = t.lines().map(|l| l.split("  ").nth(1).unwrap()).collect();
        assert_eq!(names, vec!["copies.jsonl", "packs/p.cdoc", "shard/a", "staged.tmp"]);
        let h = |s: &str| Sha256::digest(s.as_bytes()).iter().map(|b| format!("{b:02x}")).collect::<String>();
        assert!(t.contains(&format!("{}  shard/a", h("new"))));
        assert!(t.contains(&format!("{}  copies.jsonl", h("c2"))));
    }

    #[test]
    fn utc_text_is_iso() {
        assert_eq!(utc_text(0), "1970-01-01T00:00:00Z");
        assert_eq!(utc_text(1_700_000_000_000), "2023-11-14T22:13:20Z");
        assert_eq!(utc_text(951_782_400_000), "2000-02-29T00:00:00Z");
    }

    #[test]
    fn a_documents_row_is_added_with_the_header_and_replaced_in_place() {
        let t1 = documents_with(None, "a", 1, "A\tbook", "h1", 3, 10);
        assert_eq!(t1, "doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages\na\t1\tA book\th1\t3\t10\n");
        let t2 = documents_with(Some(&t1), "b", 1, "B", "h2", 4, 11);
        assert_eq!(t2.lines().count(), 3);
        let t3 = documents_with(Some(&t2), "a", 1, "A2", "h1", 5, 10);
        assert_eq!(t3.lines().nth(1), Some("a\t1\tA2\th1\t5\t10"));
        assert_eq!(t3.lines().count(), 3);
    }

    #[test]
    fn a_copies_line_is_added_once_and_replaced_in_place() {
        let mut f = PackFacts { copy: "b".into(), doc_id: "b".into(), version: 1, title: "B".into(), ..Default::default() };
        f.original_blake3 = Some("b".into());
        let a = PackFacts { copy: "a".into(), doc_id: "a".into(), version: 1, title: "A".into(), ..Default::default() };
        let t1 = copies_with(Some(&(a.to_copies_line() + "\n")), &f);
        assert_eq!(t1.lines().count(), 2);
        f.title = "B2".into();
        let t2 = copies_with(Some(&t1), &f);
        assert_eq!(t2.lines().count(), 2);
        assert!(t2.lines().nth(1).unwrap().contains("B2"));
        assert_eq!(t2.lines().next(), t1.lines().next());
    }
}
