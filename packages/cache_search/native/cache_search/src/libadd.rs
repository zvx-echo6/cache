//! Adding a library on the device, and the blank library template (docs/LIBRARY-FORMAT.md).
//!
//! - `unpack_library` job: a Qdrant shard snapshot, or a `.cache-library` archive (the same snapshot with
//!   `cache-library.json` added at its root), unpacked into a new folder with progress, then checked: it opens
//!   read-only, its points are counted and its settings are worked out. The settings file found in the archive is
//!   taken out of the shard folder and handed back in the job's `detail`.
//! - `check_library` job: the same check on a folder that is already unpacked (with other settings).
//! - `library_template` job: a blank library to fill with your own tools: an empty shard made with the read-write
//!   `EdgeShard` (one unnamed 1024-dimension dense vector, Cosine, the bge-m3 shape), packed as a shard snapshot, a
//!   filled-in `cache-library.json` and a README, in one tar file.
//!
//! The snapshot of the template is the shard folder in a tar (`segments/<uuid>/...` with the files directly in the
//! segment folder, plus `edge_config.json`): Qdrant Edge cannot make snapshots (DESIGN.md, Libraries), and this is
//! the layout Qdrant's own `restore_unpacked_snapshot` reads (a segment folder whose files are not in a `files/`
//! sub-folder is taken as it is). `segments_manifest.json` is left out, as in a server snapshot; unpacking writes it.

use crate::error::{Error, Result};
use crate::index::Outcome;
use crate::library::{self, ensure_init, write_segments_manifest, LibrarySettings, MANIFEST_FILE};
use crate::libupdate;
use edge::{CountRequest, Distance, EdgeConfig, EdgeShard, EdgeShardRead, EdgeVectorParamsBuilder};
use serde_json::{json, Value};
use std::io::Read;
use std::path::{Path, PathBuf};

/// The settings file's name inside a `.cache-library` archive, and beside a library on the device.
pub const SETTINGS_FILE: &str = "cache-library.json";
/// The vector size of the template (bge-m3).
pub const TEMPLATE_DIMS: usize = 1024;
/// The snapshot's name inside the template file.
pub const TEMPLATE_SNAPSHOT: &str = "blank-library.snapshot";
/// The README of the template file.
pub const TEMPLATE_README: &str = include_str!("template_readme.md");

fn op(what: &str, e: impl std::fmt::Display) -> Error {
    Error::io(format!("{what}: {e}"))
}

// ---------------------------------------------------------------------------------------------------------
// The check

/// Open the library at `dir` read-only once (the cheap scroll profile), count its points and work out its settings
/// (`given`, or guessed). Writes nothing except a missing `segments_manifest.json`. The result is what the jobs put
/// in their `detail`: `{"segments","docs","settings","resolved","settings_error","whole_library_only","own_text_index"}`, where `settings` is `given`
/// (or null), `resolved` the settings in use (with `"guessed"`) and `settings_error` the core error when no settings
/// could be worked out (then `resolved` is null); `own_text_index` says the collection has its own BM25-scored text
/// index on the mapped text field (with `keyword_index` "auto" no device index is needed). A library that does not
/// open is an error.
pub fn check_library(dir: &Path, given: Option<&Value>) -> Result<Value> {
    if let Some(v) = given {
        LibrarySettings::parse(v)?;
    }
    let shard = library::open_shard_for_scroll(dir)?;
    let segments = shard.segments_count();
    let docs = EdgeShardRead::count(&shard, CountRequest::new()).map_err(|e| Error::internal(format!("counting points: {e}")))?;
    let whole = library::whole_library_only(&shard);
    let (resolved, error, own) = match library::resolve_settings(&shard, dir, given) {
        Ok(s) => (s.to_json(), Value::Null, library::detect_own_scoring(&shard, &s)),
        Err(e) => (Value::Null, json!({"code": e.code.as_str(), "message": e.message}), false),
    };
    Ok(json!({
        "segments": segments, "docs": docs, "settings": given.cloned().unwrap_or(Value::Null),
        "resolved": resolved, "settings_error": error, "whole_library_only": whole, "own_text_index": own,
    }))
}

// ---------------------------------------------------------------------------------------------------------
// Unpacking

/// A checked `unpack_library` request.
pub struct UnpackRequest {
    pub snapshot: PathBuf,
    pub dir: PathBuf,
    /// Settings chosen beside the snapshot; they win over a settings file in the archive.
    pub settings: Option<Value>,
    pub size: u64,
}

/// Check the parameters without creating anything: the snapshot is a file that starts with a tar header, `dir`
/// does not exist (or is an empty folder) and its parent does, `settings` (if given) parses, and the free space on
/// `dir`'s file system holds the unpacked library: snapshot size + max(5% of it, 256 MiB) (`no_space` otherwise).
pub fn prepare_unpack(snapshot_path: &str, dir: &str, settings: Option<Value>, fake_available: Option<u64>) -> Result<UnpackRequest> {
    if snapshot_path.is_empty() || dir.is_empty() {
        return Err(Error::bad_json("snapshot_path and dir must not be empty"));
    }
    if let Some(v) = &settings {
        LibrarySettings::parse(v)?;
    }
    let snapshot = PathBuf::from(snapshot_path);
    if !snapshot.is_file() {
        return Err(Error::not_found(format!("snapshot file {} not found", snapshot.display())));
    }
    let dir = PathBuf::from(dir);
    if dir.exists() {
        let empty = std::fs::read_dir(&dir).map(|mut r| r.next().is_none()).unwrap_or(false);
        if !dir.is_dir() || !empty {
            return Err(Error::bad_json(format!("{} already exists", dir.display())));
        }
    }
    let parent = dir.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    if !parent.is_dir() {
        return Err(Error::not_found(format!("the folder of {} does not exist", dir.display())));
    }
    libupdate::check_tar_header(&snapshot)?;
    let size = std::fs::metadata(&snapshot).map_err(|e| op(&format!("reading {}", snapshot.display()), e))?.len();
    let margin = libupdate::margin_for(size);
    let needed = size.saturating_add(margin);
    let available = match fake_available {
        Some(n) => n,
        None => libupdate::available_bytes(parent)?,
    };
    if needed > available {
        return Err(Error::no_space(
            format!("not enough free space to add the library: {needed} bytes needed (snapshot {size} + margin {margin}), {available} available"),
            needed,
            available,
        ));
    }
    Ok(UnpackRequest { snapshot, dir, settings, size })
}

/// Reads the snapshot, counting bytes for the progress and stopping (with an error the caller recognises) when
/// cancelled.
struct Counting<'a, R> {
    inner: R,
    done: u64,
    reported: u64,
    total: u64,
    progress: &'a dyn Fn(u64, u64),
    cancelled: &'a dyn Fn() -> bool,
    stopped: bool,
}

impl<R: Read> Read for Counting<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if (self.cancelled)() {
            self.stopped = true;
            return Err(std::io::Error::other("cancelled"));
        }
        let n = self.inner.read(buf)?;
        self.done += n as u64;
        if self.done - self.reported >= 1 << 20 {
            self.reported = self.done;
            (self.progress)(self.done.min(self.total), self.total);
        }
        Ok(n)
    }
}

/// Removes a folder when dropped, unless disarmed.
struct Undo(Option<PathBuf>);

impl Drop for Undo {
    fn drop(&mut self) {
        if let Some(p) = self.0.take() {
            let _ = std::fs::remove_dir_all(p);
        }
    }
}

/// Run an `unpack_library` job. Progress is bytes of the snapshot read (`done`/`total`). The archive is unpacked
/// into `dir` (Qdrant's own tar unpacking and segment restore, as `EdgeShard::unpack_snapshot` does), the segments
/// manifest is written, a `cache-library.json` at the archive's root is read and removed from the folder, and the
/// library is checked ([`check_library`], with the chosen settings, else the archive's). `detail` gets the check's
/// result plus `"settings_source"`: "given", "archive" or null. A failed or cancelled job removes `dir` again.
pub fn run_unpack(
    req: &UnpackRequest,
    progress: &dyn Fn(u64, u64),
    detail: &dyn Fn(Value),
    cancelled: &dyn Fn() -> bool,
) -> Result<Outcome> {
    ensure_init();
    progress(0, req.size);
    std::fs::create_dir_all(&req.dir).map_err(|e| op(&format!("creating {}", req.dir.display()), e))?;
    let mut undo = Undo(Some(req.dir.clone()));
    let file = std::fs::File::open(&req.snapshot).map_err(|e| op(&format!("opening {}", req.snapshot.display()), e))?;
    let mut reader = Counting {
        inner: std::io::BufReader::with_capacity(1 << 20, file),
        done: 0,
        reported: 0,
        total: req.size,
        progress,
        cancelled,
        stopped: false,
    };
    if let Err(e) = common::tar_unpack::tar_unpack_reader(&mut reader, &req.dir) {
        if reader.stopped {
            return Ok(Outcome::Cancelled);
        }
        return Err(op("unpacking the library", e));
    }
    progress(req.size, req.size);
    if cancelled() {
        return Ok(Outcome::Cancelled);
    }
    shard::snapshots::snapshot_utils::SnapshotUtils::restore_unpacked_snapshot(&req.dir)
        .map_err(|e| Error::unsupported(format!("not a library (a Qdrant shard snapshot): {e}")))?;
    let in_archive = req.dir.join(SETTINGS_FILE);
    let archive_settings = if in_archive.is_file() {
        let text = std::fs::read(&in_archive).map_err(|e| op(&format!("reading {SETTINGS_FILE}"), e))?;
        let v: Value = serde_json::from_slice(&text)
            .map_err(|e| Error::bad_json(format!("the {SETTINGS_FILE} in the archive is not valid JSON: {e}")))?;
        std::fs::remove_file(&in_archive).map_err(|e| op(&format!("removing {SETTINGS_FILE}"), e))?;
        Some(v)
    } else {
        None
    };
    write_segments_manifest(&req.dir)?;
    let (settings, source) = match (&req.settings, &archive_settings) {
        (Some(g), _) => (Some(g), json!("given")),
        (None, Some(a)) => (Some(a), json!("archive")),
        (None, None) => (None, Value::Null),
    };
    let mut d = check_library(&req.dir, settings)?;
    d["settings_source"] = source;
    detail(d);
    undo.0 = None;
    Ok(Outcome::Done)
}

// ---------------------------------------------------------------------------------------------------------
// The blank template

/// The template's `cache-library.json`: format 1, a placeholder `library_id`, version 1, the field map of the
/// template's payload fields and the embedding model (bge-m3 Q8_0 GGUF, pinned on Hugging Face).
pub fn template_settings() -> Value {
    json!({
        "format": 1,
        "library_id": "my-library",
        "version": "1",
        "title": "My library",
        "fields": {
            "title": "title", "text": "text", "page": "page", "source_type": "source", "link": "link",
            "document": "doc_id"
        },
        "leave_out": [],
        "embedding": {
            "vector": "",
            "model": "bge-m3-Q8_0.gguf",
            "sha256": "c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb",
            "dims": TEMPLATE_DIMS,
            "repo": "lm-kit/bge-m3-gguf",
            "revision": "9379ce497e8814b200f2dc0d18eb4045426dcb8c",
            "path": "bge-m3-Q8_0.gguf",
            "size": 634_553_856u64
        },
        "keyword_index": "auto"
    })
}

/// Make the empty shard in `dir` (which must not hold one): one unnamed dense vector of [`TEMPLATE_DIMS`], Cosine,
/// no write-ahead log (nothing is written to it), flushed and closed.
pub fn make_blank_shard(dir: &Path) -> Result<()> {
    ensure_init();
    let cfg = EdgeConfig::builder()
        .vector("", EdgeVectorParamsBuilder::new(TEMPLATE_DIMS, Distance::Cosine).build())
        .wal_enabled(false)
        .build();
    let shard = EdgeShard::new(dir, cfg).map_err(|e| op("making the blank library", e))?;
    shard.flush().map_err(|e| op("making the blank library", e))?;
    drop(shard);
    Ok(())
}

fn add_tree<W: std::io::Write>(tar: &mut tar::Builder<W>, root: &Path, rel: &Path) -> Result<()> {
    let here = root.join(rel);
    let mut names: Vec<_> = std::fs::read_dir(&here)
        .map_err(|e| op(&format!("reading {}", here.display()), e))?
        .filter_map(|e| e.ok())
        .collect();
    names.sort_by_key(|e| e.file_name());
    for ent in names {
        let name = ent.file_name();
        let r = rel.join(&name);
        if rel.as_os_str().is_empty() && name == MANIFEST_FILE {
            continue;
        }
        let ft = ent.file_type().map_err(|e| op("reading the blank library", e))?;
        if ft.is_dir() {
            tar.append_dir(&r, ent.path()).map_err(|e| op("packing the blank library", e))?;
            add_tree(tar, root, &r)?;
        } else if ft.is_file() {
            tar.append_path_with_name(ent.path(), &r).map_err(|e| op("packing the blank library", e))?;
        }
    }
    Ok(())
}

/// Pack the shard folder `dir` as a shard snapshot (a tar of its files, without `segments_manifest.json`).
pub fn pack_snapshot(dir: &Path, out: &Path) -> Result<()> {
    let f = std::fs::File::create(out).map_err(|e| op(&format!("creating {}", out.display()), e))?;
    let mut tar = tar::Builder::new(std::io::BufWriter::new(f));
    tar.mode(tar::HeaderMode::Deterministic);
    add_tree(&mut tar, dir, Path::new(""))?;
    let w = tar.into_inner().map_err(|e| op("packing the blank library", e))?;
    w.into_inner().map_err(|e| op("packing the blank library", e.error()))?.sync_all().map_err(|e| op("packing the blank library", e))?;
    Ok(())
}

fn append_bytes<W: std::io::Write>(tar: &mut tar::Builder<W>, name: &str, bytes: &[u8]) -> Result<()> {
    let mut h = tar::Header::new_gnu();
    h.set_size(bytes.len() as u64);
    h.set_mode(0o644);
    h.set_cksum();
    tar.append_data(&mut h, name, bytes).map_err(|e| op("writing the template", e))
}

/// Steps of a `library_template` job: blank library made, packed, template written.
pub const TEMPLATE_STEPS: u64 = 3;

/// Write the template file at `out` (a tar: `README.md`, `cache-library.json`, [`TEMPLATE_SNAPSHOT`]). Everything
/// is made in a hidden folder beside `out`, which is removed afterwards; the file is written under a hidden name
/// and renamed into place.
pub fn write_template(out: &Path, progress: &dyn Fn(u64, u64)) -> Result<Outcome> {
    let name = out.file_name().map(|n| n.to_string_lossy().into_owned()).filter(|n| !n.is_empty())
        .ok_or_else(|| Error::bad_json("out_path has no file name"))?;
    let parent = out.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    if !parent.is_dir() {
        return Err(Error::not_found(format!("the folder of {} does not exist", out.display())));
    }
    if out.is_dir() {
        return Err(Error::bad_json(format!("out_path {} is a folder", out.display())));
    }
    progress(0, TEMPLATE_STEPS);
    let work = parent.join(format!(".{name}.{}.work", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    let _undo = Undo(Some(work.clone()));
    let shard_dir = work.join("shard");
    make_blank_shard(&shard_dir)?;
    progress(1, TEMPLATE_STEPS);
    let snap = work.join(TEMPLATE_SNAPSHOT);
    pack_snapshot(&shard_dir, &snap)?;
    progress(2, TEMPLATE_STEPS);
    let tmp = parent.join(format!(".{name}.{}.tmp", std::process::id()));
    let r = (|| -> Result<()> {
        let f = std::fs::File::create(&tmp).map_err(|e| op(&format!("creating {}", tmp.display()), e))?;
        let mut tar = tar::Builder::new(std::io::BufWriter::new(f));
        tar.mode(tar::HeaderMode::Deterministic);
        append_bytes(&mut tar, "README.md", TEMPLATE_README.as_bytes())?;
        let settings = serde_json::to_string_pretty(&template_settings()).expect("json") + "\n";
        append_bytes(&mut tar, SETTINGS_FILE, settings.as_bytes())?;
        tar.append_path_with_name(&snap, TEMPLATE_SNAPSHOT).map_err(|e| op("writing the template", e))?;
        let w = tar.into_inner().map_err(|e| op("writing the template", e))?;
        w.into_inner().map_err(|e| op("writing the template", e.error()))?.sync_all().map_err(|e| op("writing the template", e))?;
        std::fs::rename(&tmp, out).map_err(|e| op(&format!("writing {}", out.display()), e))
    })();
    if r.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    r?;
    progress(3, TEMPLATE_STEPS);
    Ok(Outcome::Done)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn template_settings_parse() {
        let s = LibrarySettings::parse(&template_settings()).unwrap();
        assert_eq!(s.library_id, "my-library");
        assert_eq!(s.version.as_deref(), Some("1"));
        assert_eq!(s.fields.text, "text");
        assert_eq!(s.fields.source_type.as_deref(), Some("source"));
        assert_eq!(s.fields.document.as_deref(), Some("doc_id"));
        assert_eq!(s.embedding.model, "bge-m3-Q8_0.gguf");
        assert_eq!(s.embedding.dims, Some(TEMPLATE_DIMS));
        assert_eq!(s.keyword_index, "auto");
    }
}
