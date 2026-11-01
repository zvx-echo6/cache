//! Changing a built library one document at a time. The library keeps its own read-write copy of the shard (the "work shard"),
//! which the core never opens; a document's pieces are upserted into it, or deleted from it by their point ids
//! (`UUIDv5(doc_id:doc_version:index)`, so a delete needs no filter and repeating either operation changes nothing).
//! [`publish_copy`] then makes a finished copy of the work shard for the caller to swap into the library the core reads.
//!
//! Nothing here touches a shard the core has open: the caller owns the swap (see the server's `build` module).

use crate::embed::DIMS;
use crate::error::{Error, Result};
use crate::library::{payload_of, point_uuid};
use crate::pack::Pack;
use edge::{Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, PointId, PointInsertOperations, PointOperations, PointStruct, UpdateOperation};
use std::path::Path;

/// The text of a library's `cache-library.json` (pretty JSON and a final newline).
pub fn library_settings_json(id: &str, title: &str, version: &str) -> String {
    serde_json::to_string_pretty(&crate::library::library_settings(id, title, version)).unwrap_or_default() + "\n"
}

/// A read-write shard for upserting and deleting pieces.
pub struct WorkShard {
    shard: EdgeShard,
}

impl WorkShard {
    /// Open the shard in `dir`, or make an empty one (one unnamed 1024-dimension Cosine vector, no write-ahead log) when there is
    /// none yet.
    pub fn open(dir: &Path) -> Result<WorkShard> {
        cache_search::library::ensure_init();
        let shard = if dir.join("segments").is_dir() {
            EdgeShard::load(dir, None).map_err(|e| Error::ctx("opening the work shard", e))?
        } else {
            std::fs::create_dir_all(dir).map_err(|e| Error::ctx(&format!("creating {}", dir.display()), e))?;
            let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).build()).wal_enabled(false).build();
            EdgeShard::new(dir, cfg).map_err(|e| Error::ctx("making the work shard", e))?
        };
        Ok(WorkShard { shard })
    }

    fn update(&self, op: PointOperations, what: &str) -> Result<()> {
        self.shard.update(UpdateOperation::PointOperation(op)).map_err(|e| Error::ctx(what, e))
    }

    /// Add (or overwrite) every piece of a pack.
    pub fn upsert_pack(&self, pack: &Pack) -> Result<usize> {
        let mut batch = Vec::new();
        let mut total = 0usize;
        for (i, p) in pack.pieces.iter().enumerate() {
            let id = PointId::Uuid(point_uuid(&pack.header.doc_id, pack.header.doc_version, p.index));
            batch.push(PointStruct::new(id, p.vector.clone(), payload_of(pack, i)).0);
            total += 1;
            if batch.len() >= 256 {
                self.update(PointOperations::UpsertPoints(PointInsertOperations::PointsList(std::mem::take(&mut batch))), "adding points")?;
            }
        }
        if !batch.is_empty() {
            self.update(PointOperations::UpsertPoints(PointInsertOperations::PointsList(batch)), "adding points")?;
        }
        Ok(total)
    }

    /// Delete the pieces `0..pieces` of one version of a document.
    pub fn delete_doc(&self, doc_id: &str, doc_version: u32, pieces: usize) -> Result<()> {
        let ids: Vec<PointId> = (0..pieces as u32).map(|i| PointId::Uuid(point_uuid(doc_id, doc_version, i))).collect();
        for chunk in ids.chunks(1024) {
            self.update(PointOperations::DeletePoints { ids: chunk.to_vec() }, "deleting points")?;
        }
        Ok(())
    }

    pub fn flush(&self) -> Result<()> {
        self.shard.flush().map_err(|e| Error::ctx("flushing the work shard", e))
    }
}

/// Copy the (closed) work shard `src` to `dst` (which must not exist) and finish it as a library shard: every file is synced and
/// `segments_manifest.json` is written. Returns the number of points in it. On any error `dst` is removed again.
pub fn publish_copy(src: &Path, dst: &Path) -> Result<usize> {
    let r = (|| {
        copy_dir_synced(src, dst)?;
        cache_search::library::write_segments_manifest(dst).map_err(|e| Error::ctx("writing the segments manifest", e.message))?;
        let c = cache_search::libadd::check_library(dst, None).map_err(|e| Error::ctx("checking the copy", e.message))?;
        Ok(c["docs"].as_u64().unwrap_or(0) as usize)
    })();
    if r.is_err() {
        let _ = std::fs::remove_dir_all(dst);
    }
    r
}

/// A folder copied with every file synced to disk.
pub fn copy_dir_synced(src: &Path, dst: &Path) -> Result<()> {
    let io = |what: &str, p: &Path, e: std::io::Error| Error::ctx(&format!("{what} {}", p.display()), e);
    std::fs::create_dir_all(dst).map_err(|e| io("creating", dst, e))?;
    for ent in std::fs::read_dir(src).map_err(|e| io("reading", src, e))? {
        let ent = ent.map_err(|e| io("reading", src, e))?;
        let to = dst.join(ent.file_name());
        let ty = ent.file_type().map_err(|e| io("reading", &ent.path(), e))?;
        if ty.is_dir() {
            copy_dir_synced(&ent.path(), &to)?;
        } else if ty.is_file() {
            std::fs::copy(ent.path(), &to).map_err(|e| io("copying", &ent.path(), e))?;
            std::fs::File::open(&to).and_then(|f| f.sync_all()).map_err(|e| io("syncing", &to, e))?;
        }
    }
    Ok(())
}

/// Make the work shard again from a folder's live packs (used when the work shard has been lost).
pub fn rebuild_from_packs(packs_dir: &Path, work: &Path) -> Result<usize> {
    let _ = std::fs::remove_dir_all(work);
    let packs = if packs_dir.is_dir() { crate::library::live_packs(packs_dir)? } else { vec![] };
    let w = WorkShard::open(work)?;
    let mut n = 0;
    for p in &packs {
        n += w.upsert_pack(p)?;
    }
    w.flush()?;
    Ok(n)
}
