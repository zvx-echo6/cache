//! The Add PDF job in the core (packages/cache_ingest/INGEST-API.md): `cs_ingest_start`, `cs_ingest_step`, `cs_ingest_ocr` and
//! `cs_ingest_cancel`. The job itself is the `cache_ingest` crate; this module wires it to what the core owns:
//!
//! - the library store: the shard and the keyword index. A write takes the library through the same `updating` state an
//!   `update_library` job uses (`libreg`), works on a real copy beside the library (`<shard>.cs-stage`, `index.cs-stage`) and swaps
//!   it in with renames, so it is all or nothing, and reopens the library when it is done;
//! - PDFium and the embedding model, which the host ships and names in the optional `engines` object of the start call;
//! - no classifier: the core does not load `cache_classify` on a device, so a new book is placed nowhere and goes to Unsorted.

use crate::error::{Error, ErrorCode, Result};
use crate::libindex::{append_documents, Appended, IndexDoc};
use crate::libreg::{self, LibEntry, UpdateGuard};
use crate::libupdate::{self, copy_tree, hand_back_open, margin_for, retry_fs, sync_dir, sync_tree, tree_size};
use crate::library::{self, ensure_init, write_segments_manifest, LibrarySettings};
use cache_ingest::pdfium::PdfiumEngine;
use cache_ingest::{Code as IngestCode, Env, Error as IngestError, LibraryStore, Point, Service, Staged};
use edge::{EdgeShard, PointId, PointInsertOperations, PointOperations, PointStruct, UpdateOperation};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, OnceLock, PoisonError};

const INDEX_DIR: &str = "index";
const INDEX_STAGE: &str = "index.cs-stage";
const INDEX_OLD: &str = "index.cs-old";
const SETTINGS_FILE: &str = "cache-library.json";

fn to_core(e: IngestError) -> Error {
    let code = match e.code {
        IngestCode::BadJson => ErrorCode::BadJson,
        IngestCode::Io => ErrorCode::Io,
        IngestCode::NotFound => ErrorCode::NotFound,
        IngestCode::Busy => ErrorCode::Busy,
        IngestCode::Cancelled => ErrorCode::Cancelled,
        IngestCode::NotPdf => ErrorCode::NotPdf,
        IngestCode::Locked => ErrorCode::Locked,
        IngestCode::Damaged => ErrorCode::Damaged,
        IngestCode::NoSpace => ErrorCode::NoSpace,
        IngestCode::Embed => ErrorCode::Embed,
    };
    Error { code, message: e.message, space: e.space }
}

fn from_core(e: Error) -> IngestError {
    let code = match e.code {
        ErrorCode::BadJson => IngestCode::BadJson,
        ErrorCode::NotFound => IngestCode::NotFound,
        ErrorCode::Busy => IngestCode::Busy,
        ErrorCode::Cancelled => IngestCode::Cancelled,
        ErrorCode::NoSpace => IngestCode::NoSpace,
        ErrorCode::Damaged => IngestCode::Damaged,
        _ => IngestCode::Io,
    };
    IngestError { code, message: e.message, space: e.space }
}

fn io(what: &str, e: impl std::fmt::Display) -> Error {
    Error::io(format!("{what}: {e}"))
}

// ---------------------------------------------------------------------------------------------------------
// The library store

/// The shard and keyword index of a library, written through the core's own update mechanism.
pub struct CoreStore;

enum IndexAction {
    /// No device index, or none that can be extended.
    Nothing,
    /// The extended copy replaces the index.
    Swap(PathBuf),
    /// The index is unfinished: it is moved away and built again when needed.
    Remove,
}

struct CoreStaged {
    entry: Arc<LibEntry>,
    shard: PathBuf,
    stage: PathBuf,
    old: PathBuf,
    index: PathBuf,
    index_old: PathBuf,
    index_action: IndexAction,
    swapped_shard: bool,
    swapped_index: bool,
    // Dropping the guard ends the update: the library is no longer `updating` and handles look at it again. Declared last so it
    // goes after the clean-up in `Drop`.
    _guard: UpdateGuard,
}

fn upsert(shard_dir: &Path, points: &[Point]) -> Result<()> {
    let shard = EdgeShard::load(shard_dir, None).map_err(|e| io("opening the staged shard", e))?;
    let upd = |op: PointOperations| shard.update(UpdateOperation::PointOperation(op)).map_err(|e| io("adding points", e));
    let mut batch = Vec::new();
    for p in points {
        let id = PointId::Uuid(uuid::Uuid::parse_str(&p.id).map_err(|e| Error::internal(format!("point id {}: {e}", p.id)))?);
        batch.push(PointStruct::new(id, p.vector.clone(), p.payload.clone()).0);
        if batch.len() >= 256 {
            upd(PointOperations::UpsertPoints(PointInsertOperations::PointsList(std::mem::take(&mut batch))))?;
        }
    }
    if !batch.is_empty() {
        upd(PointOperations::UpsertPoints(PointInsertOperations::PointsList(batch)))?;
    }
    shard.flush().map_err(|e| io("flushing the staged shard", e))
}

fn index_docs(settings: &LibrarySettings, points: &[Point]) -> Vec<IndexDoc> {
    let empty = serde_json::Map::new();
    points
        .iter()
        .filter_map(|p| {
            let pl = p.payload.as_object().unwrap_or(&empty);
            if settings.left_out(pl) {
                return None;
            }
            Some(IndexDoc {
                point_id: p.id.clone(),
                title: settings.base_title(pl),
                body: settings.main_text(pl).unwrap_or_default(),
                source_type: settings.field_text(pl, &settings.fields.source_type).unwrap_or_default(),
            })
        })
        .collect()
}

fn remove_dir(p: &Path) {
    let _ = std::fs::remove_dir_all(p);
}

fn begin_write(library_dir: &Path, points: &[Point]) -> Result<CoreStaged> {
    ensure_init();
    let shard = library_dir.join("shard");
    if !shard.is_dir() {
        return Err(Error::not_found(format!("library shard {} not found", shard.display())));
    }
    let entry = libreg::entry_for(&shard);
    let guard = entry.begin_update()?;
    library::check_not_damaged(&shard, true)?;
    let index = library_dir.join(INDEX_DIR);
    let index_stage = library_dir.join(INDEX_STAGE);
    let index_old = library_dir.join(INDEX_OLD);
    // space: the copies of the shard and the index, the new points (vector and text) and the margin
    let shard_bytes = tree_size(&shard)?;
    let index_bytes = if index.is_dir() { tree_size(&index)? } else { 0 };
    let new_bytes: u64 = points.iter().map(|p| (p.vector.len() * 4 + p.payload.to_string().len()) as u64 * 2).sum();
    let needed = shard_bytes.saturating_add(index_bytes).saturating_add(new_bytes).saturating_add(margin_for(shard_bytes));
    let available = libupdate::available_bytes(library_dir)?;
    if needed > available {
        return Err(Error::no_space(
            format!("not enough free space to add the book to {}: {needed} bytes needed, {available} available", library_dir.display()),
            needed,
            available,
        ));
    }
    // close the library in every handle (search skips it meanwhile) and put right what a crash left beside it
    if !entry.close_all(&|| false)? {
        return Err(Error::new(ErrorCode::Cancelled, "cancelled"));
    }
    libupdate::recover_leftovers(&shard)?;
    if !index.exists() && index_old.is_dir() {
        let _ = std::fs::rename(&index_old, &index);
    }
    remove_dir(&index_old);
    remove_dir(&index_stage);
    let stage = libupdate::stage_path(&shard)?;
    let old = libupdate::old_path(&shard)?;
    let mut st = CoreStaged {
        entry,
        shard,
        stage,
        old,
        index,
        index_old,
        index_action: IndexAction::Nothing,
        swapped_shard: false,
        swapped_index: false,
        _guard: guard,
    };
    // from here `Drop` removes the copies on any failure
    remove_dir(&st.stage);
    copy_tree(&st.shard, &st.stage)?;
    upsert(&st.stage, points)?;
    write_segments_manifest(&st.stage)?;
    sync_tree(&st.stage)?;
    if st.index.is_dir() {
        let given: Option<Value> = std::fs::read_to_string(library_dir.join(SETTINGS_FILE)).ok().and_then(|t| serde_json::from_str(&t).ok());
        let ro = library::open_shard_for_scroll(&st.stage)?;
        let settings = library::resolve_settings(&ro, &st.stage, given.as_ref())?;
        drop(ro);
        copy_tree(&st.index, &index_stage)?;
        let _ = std::fs::remove_file(index_stage.join(crate::index::LOCK_FILE));
        st.index_action = match append_documents(&index_stage, &index_docs(&settings, points))? {
            Appended::Yes => {
                sync_tree(&index_stage)?;
                IndexAction::Swap(index_stage)
            }
            Appended::NoIndex => {
                remove_dir(&index_stage);
                IndexAction::Nothing
            }
            Appended::Unfinished => {
                remove_dir(&index_stage);
                IndexAction::Remove
            }
        };
    }
    Ok(st)
}

impl CoreStaged {
    fn swap_in(&mut self) -> Result<()> {
        retry_fs(|| std::fs::rename(&self.shard, &self.old)).map_err(|e| io("swapping: moving the library aside", e))?;
        if let Err(e) = retry_fs(|| std::fs::rename(&self.stage, &self.shard)) {
            let _ = std::fs::rename(&self.old, &self.shard);
            return Err(io("swapping: moving the copy into place (the library was restored)", e));
        }
        self.swapped_shard = true;
        match &self.index_action {
            IndexAction::Nothing => {}
            IndexAction::Swap(stage) => {
                if self.index.is_dir() {
                    retry_fs(|| std::fs::rename(&self.index, &self.index_old)).map_err(|e| io("swapping the keyword index", e))?;
                }
                retry_fs(|| std::fs::rename(stage, &self.index)).map_err(|e| io("swapping the keyword index", e))?;
                self.swapped_index = true;
            }
            IndexAction::Remove => {
                retry_fs(|| std::fs::rename(&self.index, &self.index_old)).map_err(|e| io("moving the unfinished keyword index aside", e))?;
                self.swapped_index = true;
            }
        }
        if let Some(parent) = self.shard.parent() {
            let _ = sync_dir(parent);
        }
        Ok(())
    }

    /// Puts the old files back (the handles must not hold the new shard: the caller closes them first).
    fn swap_back(&mut self) {
        if self.swapped_index {
            if let IndexAction::Swap(stage) = &self.index_action {
                let _ = std::fs::rename(&self.index, stage);
            } else {
                let _ = std::fs::remove_dir_all(&self.index);
            }
            let _ = std::fs::rename(&self.index_old, &self.index);
            self.swapped_index = false;
        }
        if self.swapped_shard {
            let _ = std::fs::rename(&self.shard, &self.stage);
            let _ = std::fs::rename(&self.old, &self.shard);
            self.swapped_shard = false;
        }
    }
}

impl Staged for CoreStaged {
    fn commit(&mut self) -> cache_ingest::Result<()> {
        let r = self.swap_in().and_then(|_| hand_back_open(&self.shard, &self.entry));
        if let Err(e) = r {
            let _ = self.entry.close_all(&|| false);
            self.swap_back();
            return Err(from_core(e));
        }
        Ok(())
    }

    fn undo(&mut self) {
        let _ = self.entry.close_all(&|| false);
        self.swap_back();
    }
}

impl Drop for CoreStaged {
    fn drop(&mut self) {
        // not swapped in (or put back): the copies go; swapped in: the old files go
        remove_dir(&self.stage);
        if let IndexAction::Swap(s) = &self.index_action {
            remove_dir(s);
        }
        remove_dir(&self.index_stage_path());
        if self.swapped_shard {
            remove_dir(&self.old);
        }
        if self.swapped_index {
            remove_dir(&self.index_old);
        }
    }
}

impl CoreStaged {
    fn index_stage_path(&self) -> PathBuf {
        self.index.with_file_name(INDEX_STAGE)
    }
}

impl LibraryStore for CoreStore {
    fn begin(&self, library_dir: &Path, points: &[Point]) -> cache_ingest::Result<Box<dyn Staged>> {
        begin_write(library_dir, points).map(|s| Box::new(s) as Box<dyn Staged>).map_err(from_core)
    }
}

// ---------------------------------------------------------------------------------------------------------
// The embedder

/// bge-m3 through `cache_embed`, with the settings of the queries. The model is loaded when the first passage is embedded and kept
/// for the next job; `engines.embed_lib` is the built `libcache_llama` and `engines.embed_model` the GGUF file.
struct CoreEmbedder {
    lib: Option<String>,
    model: Option<String>,
    sha256: Option<String>,
    loaded: Mutex<Option<(usize, cache_embed::Embedder)>>,
}

impl cache_ingest::Embedder for CoreEmbedder {
    fn name(&self) -> String {
        self.model
            .as_deref()
            .and_then(|m| Path::new(m).file_name())
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| cache_embed::DECIDED_MODEL_FILE.to_string())
    }

    fn embed(&self, texts: &[String], threads: usize) -> cache_ingest::Result<Vec<Vec<f32>>> {
        let embed_err = |m: String| IngestError::new(IngestCode::Embed, m);
        let (Some(lib), Some(model)) = (self.lib.as_deref(), self.model.as_deref()) else {
            return Err(embed_err("no embedding model is configured (engines.embed_lib and engines.embed_model)".to_string()));
        };
        let mut g = self.loaded.lock().unwrap_or_else(PoisonError::into_inner);
        if g.as_ref().is_none_or(|(t, _)| *t != threads) {
            *g = None;
            let e = cache_embed::Embedder::load(lib, model, None, self.sha256.as_deref(), threads as std::ffi::c_int).map_err(|e| embed_err(e.to_string()))?;
            *g = Some((threads, e));
        }
        let (_, e) = g.as_ref().ok_or_else(|| embed_err("the embedder is not loaded".to_string()))?;
        texts.iter().map(|t| e.embed(t).map_err(|er| embed_err(er.to_string()))).collect()
    }
}

fn text(engines: &Value, k: &str) -> Option<String> {
    engines.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

fn production_env(engines: &Value) -> cache_ingest::Result<Env> {
    let pdf = Arc::new(PdfiumEngine::new(text(engines, "pdfium_lib"), text(engines, "pdfium_version")));
    let embedder = Arc::new(CoreEmbedder {
        lib: text(engines, "embed_lib"),
        model: text(engines, "embed_model"),
        sha256: text(engines, "embed_sha256"),
        loaded: Mutex::new(None),
    });
    Ok(Env {
        pdf,
        embedder,
        store: Arc::new(CoreStore),
        // The core does not load cache_classify on a device (no classifier weights are shipped to it), so nothing is placed.
        classifier: None,
        clock: Arc::new(|| std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)),
    })
}

fn service() -> &'static Service {
    static S: OnceLock<Service> = OnceLock::new();
    S.get_or_init(|| Service::new(Box::new(production_env)))
}

/// `cs_ingest_start`.
pub fn start(args: &str) -> Result<String> {
    service().start(args).map_err(to_core)
}

/// `cs_ingest_step`.
pub fn step(args: &str) -> Result<String> {
    service().step(args).map_err(to_core)
}

/// `cs_ingest_ocr`.
pub fn ocr(args: &str) -> Result<String> {
    service().ocr(args).map_err(to_core)
}

/// `cs_ingest_cancel`.
pub fn cancel(args: &str) -> Result<String> {
    service().cancel(args).map_err(to_core)
}

/// A service on the core's store with the given engines, for the tests.
pub fn service_with(provider: cache_ingest::EnvProvider) -> Service {
    Service::new(provider)
}
