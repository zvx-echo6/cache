//! Packs to a normal Cache library: a read-write Qdrant Edge shard (one unnamed 1024-dimension Cosine vector), points
//! with the ids and payload fields of docs/LIBRARY-FORMAT.md, and `cache-library.json`. The result is checked with the
//! core's own `check_library`.

use crate::embed::DIMS;
use crate::error::{Error, Result};
use crate::pack::{read_pack, Pack, PACK_EXT};
use edge::{Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, PointId, PointInsertOperations, PointOperations, PointStruct, UpdateOperation};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// UUIDv5(URL namespace, "https://github.com/zvx-echo6/cache/library-point"), docs/LIBRARY-FORMAT.md.
pub const POINT_NAMESPACE: &str = "c4b95b91-e641-5c16-91a0-13ba2f6f7970";
/// The settings file, beside the shard and at the root of a `.cache-library`.
pub const SETTINGS_FILE: &str = "cache-library.json";
/// The `source` payload value of every point (mapped as the library's source type).
pub const SOURCE_KIND: &str = "book";

/// The id of passage `index` of a document version.
pub fn point_uuid(doc_id: &str, doc_version: u32, index: u32) -> uuid::Uuid {
    let ns = uuid::Uuid::parse_str(POINT_NAMESPACE).expect("namespace");
    uuid::Uuid::new_v5(&ns, format!("{doc_id}:{doc_version}:{index}").as_bytes())
}

fn page_value(label: &str) -> Value {
    match label.parse::<u64>() {
        Ok(n) if label == n.to_string() => json!(n),
        _ => json!(label),
    }
}

/// The payload of one piece: the fields today's libraries use (title, text, page, source, link, doc_id, doc_version) plus
/// extras the settings file does not map, so the model never sees them (heading_path, page_end, pdf_page, source_blake3).
pub fn payload_of(pack: &Pack, i: usize) -> Value {
    let h = &pack.header;
    let p = &pack.pieces[i];
    let mut v = json!({
        "title": h.title,
        "text": p.text,
        "page": page_value(&p.page),
        "source": SOURCE_KIND,
        "link": h.source.https.clone().unwrap_or_default(),
        "doc_id": h.doc_id,
        "doc_version": h.doc_version,
        "heading_path": p.heading_path,
        "pdf_page": p.pdf_page,
        "source_blake3": h.source.blake3,
    });
    if let Some(pe) = &p.page_end {
        v["page_end"] = page_value(pe);
    }
    v
}

pub struct LibraryOptions {
    pub id: String,
    pub title: String,
    pub version: String,
    /// Also write `<out>.cache-library` (the shard as a snapshot tar with the settings file at its root).
    pub archive: bool,
}

#[derive(Debug, Clone)]
pub struct LibraryReport {
    pub points: usize,
    pub documents: usize,
    pub shard_dir: PathBuf,
    pub settings_path: PathBuf,
    pub archive: Option<PathBuf>,
}

/// The pack files in a folder, sorted by name.
pub fn list_packs(dir: &Path) -> Result<Vec<PathBuf>> {
    let rd = std::fs::read_dir(dir).map_err(|e| Error::ctx(&format!("reading {}", dir.display()), e))?;
    let mut v: Vec<PathBuf> = rd
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().is_some_and(|x| x == PACK_EXT) && !p.file_name().is_some_and(|n| n.to_string_lossy().starts_with('.')))
        .collect();
    v.sort();
    Ok(v)
}

/// Read the live packs of a folder: for each document id, the pack with the highest version.
pub fn live_packs(dir: &Path) -> Result<Vec<Pack>> {
    let mut best: std::collections::BTreeMap<String, Pack> = std::collections::BTreeMap::new();
    for p in list_packs(dir)? {
        let pack = read_pack(&p)?;
        let keep = best.get(&pack.header.doc_id).is_none_or(|b| b.header.doc_version < pack.header.doc_version);
        if keep {
            best.insert(pack.header.doc_id.clone(), pack);
        }
    }
    Ok(best.into_values().collect())
}

/// The settings file of a library: the template with this library's id, title and version.
pub fn library_settings(id: &str, title: &str, version: &str) -> Value {
    let mut s = cache_search::libadd::template_settings();
    s["library_id"] = json!(id);
    s["title"] = json!(title);
    s["version"] = json!(version);
    s
}

fn settings_json(o: &LibraryOptions) -> Value {
    library_settings(&o.id, &o.title, &o.version)
}

/// Build the library folder `out` (it must not exist, or be empty): `shard/` and `cache-library.json`.
pub fn build_library(packs_dir: &Path, out: &Path, opts: &LibraryOptions) -> Result<LibraryReport> {
    if opts.id.trim().is_empty() {
        return Err(Error::new("the library needs an id"));
    }
    let packs = live_packs(packs_dir)?;
    if packs.is_empty() {
        return Err(Error::new(format!("no packs (*.{PACK_EXT}) in {}", packs_dir.display())));
    }
    let embedder = packs[0].header.embedding.embedder.clone();
    for p in &packs {
        if p.header.embedding.dims != DIMS {
            return Err(Error::new(format!("{} has {}-dimension vectors; a Cache library has {DIMS}", p.header.doc_id, p.header.embedding.dims)));
        }
        if p.header.embedding.embedder != embedder {
            return Err(Error::new(format!(
                "the packs were embedded by different embedders ({embedder} and {}); they cannot share a library",
                p.header.embedding.embedder
            )));
        }
    }
    if out.exists() {
        let empty = std::fs::read_dir(out).map(|mut r| r.next().is_none()).unwrap_or(false);
        if !out.is_dir() || !empty {
            return Err(Error::new(format!("{} already exists", out.display())));
        }
    }
    let shard_dir = out.join("shard");
    std::fs::create_dir_all(&shard_dir).map_err(|e| Error::ctx(&format!("creating {}", shard_dir.display()), e))?;
    let r = fill_shard(&packs, &shard_dir);
    if let Err(e) = r {
        let _ = std::fs::remove_dir_all(out);
        return Err(e);
    }
    let points = r.unwrap_or(0);
    cache_search::library::write_segments_manifest(&shard_dir).map_err(|e| Error::ctx("writing the segments manifest", e.message))?;
    let settings = settings_json(opts);
    let settings_path = out.join(SETTINGS_FILE);
    let text = serde_json::to_string_pretty(&settings).map_err(|e| Error::ctx("settings", e))? + "\n";
    std::fs::write(&settings_path, &text).map_err(|e| Error::ctx(&format!("writing {}", settings_path.display()), e))?;
    let archive = if opts.archive {
        let name = out.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "library".into());
        let path = out.with_file_name(format!("{name}.cache-library"));
        write_archive(&shard_dir, &text, &path)?;
        Some(path)
    } else {
        None
    };
    Ok(LibraryReport { points, documents: packs.len(), shard_dir, settings_path, archive })
}

fn fill_shard(packs: &[Pack], shard_dir: &Path) -> Result<usize> {
    cache_search::library::ensure_init();
    // As libadd::make_blank_shard: one unnamed dense vector, Cosine, no write-ahead log; here it stays open to be written.
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).build()).wal_enabled(false).build();
    let shard = EdgeShard::new(shard_dir, cfg).map_err(|e| Error::ctx("making the library shard", e))?;
    let up = |pts: Vec<_>| -> Result<()> {
        shard
            .update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(pts))))
            .map_err(|e| Error::ctx("adding points", e))
    };
    let mut total = 0usize;
    let mut batch = Vec::new();
    for pack in packs {
        for (i, p) in pack.pieces.iter().enumerate() {
            let id = PointId::Uuid(point_uuid(&pack.header.doc_id, pack.header.doc_version, p.index));
            batch.push(PointStruct::new(id, p.vector.clone(), payload_of(pack, i)).0);
            total += 1;
            if batch.len() >= 256 {
                up(std::mem::take(&mut batch))?;
            }
        }
    }
    if !batch.is_empty() {
        up(batch)?;
    }
    shard.flush().map_err(|e| Error::ctx("flushing the library shard", e))?;
    drop(shard);
    Ok(total)
}

/// Pack the shard with the core's `pack_snapshot`, then add `cache-library.json` at the archive's root (the core's
/// snapshot packer writes only the shard; this appends one more tar entry before the end-of-archive marker).
fn write_archive(shard_dir: &Path, settings: &str, out: &Path) -> Result<()> {
    use std::io::{Read, Seek, SeekFrom};
    let tmp = out.with_file_name(format!(".{}.tmp", out.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()));
    cache_search::libadd::pack_snapshot(shard_dir, &tmp).map_err(|e| Error::ctx("packing the library", e.message))?;
    let mut f = std::fs::OpenOptions::new().read(true).write(true).open(&tmp).map_err(|e| Error::ctx("opening the snapshot", e))?;
    let len = f.metadata().map_err(|e| Error::ctx("snapshot size", e))?.len();
    if len < 1024 {
        return Err(Error::new("the snapshot is too short"));
    }
    f.seek(SeekFrom::Start(len - 1024)).map_err(|e| Error::ctx("snapshot", e))?;
    let mut tail = [0u8; 1024];
    f.read_exact(&mut tail).map_err(|e| Error::ctx("snapshot", e))?;
    if tail.iter().any(|b| *b != 0) {
        return Err(Error::new("the snapshot does not end with a tar end marker"));
    }
    f.seek(SeekFrom::Start(len - 1024)).map_err(|e| Error::ctx("snapshot", e))?;
    let mut b = tar::Builder::new(&mut f);
    let mut h = tar::Header::new_gnu();
    h.set_size(settings.len() as u64);
    h.set_mode(0o644);
    h.set_mtime(0);
    h.set_cksum();
    b.append_data(&mut h, SETTINGS_FILE, settings.as_bytes()).map_err(|e| Error::ctx("adding the settings file", e))?;
    b.finish().map_err(|e| Error::ctx("finishing the archive", e))?;
    drop(b);
    f.sync_all().map_err(|e| Error::ctx("snapshot", e))?;
    std::fs::rename(&tmp, out).map_err(|e| Error::ctx("snapshot", e))
}

/// Check a built library folder with the core's own check: opens the shard read-only, counts the points, resolves the
/// settings. The result is the core's JSON (`docs`, `whole_library_only`, `resolved`, ...).
pub fn check_library_dir(dir: &Path) -> Result<Value> {
    let settings: Value = serde_json::from_slice(&std::fs::read(dir.join(SETTINGS_FILE)).map_err(|e| Error::ctx("reading cache-library.json", e))?)
        .map_err(|e| Error::ctx("cache-library.json", e))?;
    cache_search::libadd::check_library(&dir.join("shard"), Some(&settings)).map_err(|e| Error::ctx("library check", e.message))
}
