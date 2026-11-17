//! Replacing a few documents of a finished library, in place, in a folder the caller has copied. Nothing is rebuilt: the old
//! points of each replaced document are deleted by their ids, the new pack's points are added to the shard's own open
//! segment (the vector index of the existing segments stays as it is, and no full `optimize` runs, so the memory stays
//! small), the document's rows in `documents.tsv`, `copies.jsonl` and `source-identities.json` are rewritten, and
//! `SHA256SUMS` is made again. Every other point and every other row is left byte for byte as it was.
//!
//! It only ever writes the folder it is given. It refuses a folder that looks installed or in use (see [`refuse_in_use`]).

use crate::error::{Error, Result};
use crate::incremental::WorkShard;
use crate::library::{
    copies_entry, write_sha256sums, LibDoc, COPIES_FILE, DOCUMENTS_FILE, SETTINGS_FILE,
};
use crate::pack::Pack;
use crate::source_identity::{read_source_identities, write_source_identities, SourceIdentity, SOURCE_IDENTITIES_FILE};
use crate::view::BookFacts;
use cache_shelves::library::{content_hash, PackFacts};
use std::collections::BTreeMap;
use std::path::Path;

/// The lock file made inside the folder while a patch runs (a second patch, or a crashed one, refuses until it is removed).
pub const LOCK_FILE: &str = ".library-patch.lock";

/// What a patch changed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PatchReport {
    /// The replaced documents: id, old version, new version, old pieces, new pieces.
    pub docs: Vec<(String, u32, u32, usize, usize)>,
    /// Points in the shard afterwards, as the core's own check counts them.
    pub points: usize,
}

/// Refuse a folder that is installed or in use: an app data folder, a library the core is updating, or one a patch holds.
pub fn refuse_in_use(dir: &Path) -> Result<()> {
    let canon = std::fs::canonicalize(dir).map_err(|e| Error::ctx(&format!("reading {}", dir.display()), e))?;
    let s = canon.to_string_lossy();
    if s.contains("/var/lib/cache-app/") || s.contains("/set-aside/") {
        return Err(Error::new(format!("{} looks like an installed library; patch a copy of it elsewhere", dir.display())));
    }
    for suffix in ["cs-stage", "cs-update-tmp"] {
        let mut sibling = canon.clone().into_os_string();
        sibling.push(format!(".{suffix}"));
        if Path::new(&sibling).exists() {
            return Err(Error::new(format!("{} is being updated ({} exists)", dir.display(), Path::new(&sibling).display())));
        }
    }
    Ok(())
}

struct Lock(std::path::PathBuf);
impl Lock {
    fn take(dir: &Path) -> Result<Lock> {
        let p = dir.join(LOCK_FILE);
        std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&p)
            .map_err(|e| Error::ctx(&format!("{} (a patch is running here, or one crashed: remove the file only if none is)", p.display()), e))?;
        Ok(Lock(p))
    }
}
impl Drop for Lock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.0);
    }
}

/// One row of `documents.tsv`: its columns.
fn tsv_cols(line: &str) -> Vec<&str> {
    line.split('\t').collect()
}

/// Replace the documents of the library folder `dir` by the given packs. `new_version` (when given) becomes the library's `version` in
/// `cache-library.json`, so a device that has the old version notices and builds its keyword index again. Each pack's `doc_id` must already be in the library,
/// its version must not be lower than the library's, and its original hash (when both have one) must be the same book's.
pub fn patch_library(dir: &Path, packs: &[Pack], new_version: Option<&str>) -> Result<PatchReport> {
    if packs.is_empty() {
        return Err(Error::new("no replacement packs given"));
    }
    let shard_dir = dir.join("shard");
    for need in [shard_dir.join("segments").as_path(), &dir.join(SETTINGS_FILE), &dir.join(DOCUMENTS_FILE), &dir.join(COPIES_FILE)] {
        if !need.exists() {
            return Err(Error::new(format!("{} is not a library folder: {} is missing", dir.display(), need.display())));
        }
    }
    refuse_in_use(dir)?;
    let _lock = Lock::take(dir)?;

    let tsv_path = dir.join(DOCUMENTS_FILE);
    let tsv = std::fs::read_to_string(&tsv_path).map_err(|e| Error::ctx(&format!("reading {}", tsv_path.display()), e))?;
    let mut old: BTreeMap<String, (u32, usize)> = BTreeMap::new();
    for line in tsv.lines().skip(1) {
        let c = tsv_cols(line);
        if c.len() >= 5 {
            old.insert(c[0].to_string(), (c[1].parse().unwrap_or(0), c[4].parse().unwrap_or(0)));
        }
    }
    let copies_path = dir.join(COPIES_FILE);
    let copies = std::fs::read_to_string(&copies_path).map_err(|e| Error::ctx(&format!("reading {}", copies_path.display()), e))?;

    // Everything is checked before anything is written.
    let mut by_doc: BTreeMap<&str, &Pack> = BTreeMap::new();
    for p in packs {
        let id = p.header.doc_id.as_str();
        let Some((ver, _)) = old.get(id) else {
            return Err(Error::new(format!("{id} is not in the library: a patch only replaces documents that are there")));
        };
        if p.header.doc_version < *ver {
            return Err(Error::new(format!("{id}: the pack is version {}, the library has version {ver}", p.header.doc_version)));
        }
        if by_doc.insert(id, p).is_some() {
            return Err(Error::new(format!("{id} is given twice")));
        }
    }
    let mut old_facts: BTreeMap<String, PackFacts> = BTreeMap::new();
    for line in copies.lines() {
        let v: serde_json::Value = serde_json::from_str(line).map_err(|e| Error::ctx("a copies line", e))?;
        if let Some(id) = v.get("doc_id").and_then(|d| d.as_str()) {
            if by_doc.contains_key(id) {
                old_facts.insert(id.to_string(), PackFacts::from_copies_line(line).map_err(|e| Error::new(format!("a line of {COPIES_FILE}: {e}")))?);
            }
        }
    }
    let mut new_facts: BTreeMap<String, PackFacts> = BTreeMap::new();
    for (id, p) in &by_doc {
        let of = old_facts.get(*id).ok_or_else(|| Error::new(format!("{id} has no line in {COPIES_FILE}")))?;
        let doc = LibDoc::from_pack(p);
        let fresh = copies_entry(&doc, &BookFacts::from_header(&p.header));
        if let (Some(a), Some(b)) = (&of.original_blake3, &fresh.original_blake3) {
            if a != b {
                return Err(Error::new(format!("{id}: the pack is a different file (original hash {b}, the library has {a})")));
            }
        }
        // Keep what the library's own build decided (title, suggested shelf, author, edition, year, copy key); take the version,
        // the stored file's hash and the text fingerprint from the new pack.
        let mut nf = of.clone();
        nf.version = p.header.doc_version;
        nf.source_blake3 = fresh.source_blake3.clone();
        nf.blake3 = content_hash(nf.original_blake3.as_deref(), nf.source_blake3.as_deref());
        nf.same = fresh.same.clone();
        new_facts.insert(id.to_string(), nf);
    }

    // The shard: delete each document's old points, add the new ones.
    let before = cache_search::libadd::check_library(&shard_dir, None).map_err(|e| Error::ctx("checking the library before", e.message))?["docs"].as_u64().unwrap_or(0) as usize;
    {
        let w = WorkShard::open(&shard_dir)?;
        for (id, p) in &by_doc {
            let (ver, pieces) = old[*id];
            w.delete_doc(id, ver, pieces)?;
            w.upsert_pack(p)?;
        }
        w.flush()?;
    }
    cache_search::library::write_segments_manifest(&shard_dir).map_err(|e| Error::ctx("writing the segments manifest", e.message))?;

    // The rows: only the replaced documents' lines change.
    let mut out_tsv = String::new();
    for (n, line) in tsv.lines().enumerate() {
        let c = tsv_cols(line);
        match (n, by_doc.get(c[0])) {
            (n, Some(p)) if n > 0 => {
                let h = &p.header;
                out_tsv.push_str(&format!("{}\t{}\t{}\t{}\t{}\t{}", c[0], h.doc_version, c.get(2).copied().unwrap_or(""), h.source.blake3, p.pieces.len(), h.page_count));
            }
            _ => out_tsv.push_str(line),
        }
        out_tsv.push('\n');
    }
    std::fs::write(&tsv_path, out_tsv).map_err(|e| Error::ctx(&format!("writing {}", tsv_path.display()), e))?;
    let mut out_copies = String::new();
    for line in copies.lines() {
        let id = serde_json::from_str::<serde_json::Value>(line).ok().and_then(|v| v.get("doc_id").and_then(|d| d.as_str()).map(str::to_string));
        match id.as_deref().and_then(|i| new_facts.get(i)) {
            Some(nf) => out_copies.push_str(&nf.to_copies_line()),
            None => out_copies.push_str(line),
        }
        out_copies.push('\n');
    }
    std::fs::write(&copies_path, out_copies).map_err(|e| Error::ctx(&format!("writing {}", copies_path.display()), e))?;
    if dir.join(SOURCE_IDENTITIES_FILE).exists() {
        let mut ids: Vec<SourceIdentity> = read_source_identities(dir).map_err(|e| Error::ctx("reading source identities", e))?;
        for (id, p) in &by_doc {
            let original = ids.iter().find(|e| e.doc_id == **id).map(|e| e.original_blake3.clone());
            ids.retain(|e| e.doc_id != **id);
            if let Some(original) = original.or_else(|| p.header.book.as_ref().map(|b| b.original_blake3.clone())) {
                ids.push(SourceIdentity { doc_id: id.to_string(), version: p.header.doc_version, source_blake3: p.header.source.blake3.clone(), original_blake3: original });
            }
        }
        write_source_identities(dir, ids).map_err(|e| Error::ctx("writing source identities", e))?;
    }
    if let Some(v) = new_version {
        let sp = dir.join(SETTINGS_FILE);
        let mut settings: serde_json::Value = serde_json::from_slice(&std::fs::read(&sp).map_err(|e| Error::ctx(&format!("reading {}", sp.display()), e))?).map_err(|e| Error::ctx(SETTINGS_FILE, e))?;
        settings["version"] = serde_json::Value::String(v.to_string());
        let text = serde_json::to_string_pretty(&settings).map_err(|e| Error::ctx(SETTINGS_FILE, e))? + "\n";
        std::fs::write(&sp, text).map_err(|e| Error::ctx(&format!("writing {}", sp.display()), e))?;
    }
    write_sha256sums(dir)?;

    let after = cache_search::libadd::check_library(&shard_dir, None).map_err(|e| Error::ctx("checking the library after", e.message))?["docs"].as_u64().unwrap_or(0) as usize;
    let old_total: usize = by_doc.keys().map(|i| old[*i].1).sum();
    let new_total: usize = by_doc.values().map(|p| p.pieces.len()).sum();
    if after + old_total != before + new_total {
        return Err(Error::new(format!("the shard holds {after} points after the patch; expected {} ({before} before, {old_total} removed, {new_total} added)", before + new_total - old_total)));
    }
    let docs = by_doc.iter().map(|(i, p)| (i.to_string(), old[*i].0, p.header.doc_version, old[*i].1, p.pieces.len())).collect();
    Ok(PatchReport { docs, points: after })
}
