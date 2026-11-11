//! The Add PDF job in the core (packages/cache_ingest/INGEST-API.md): `cs_ingest_start`, `cs_ingest_step`, `cs_ingest_ocr` and
//! `cs_ingest_cancel`. The job itself is the `cache_ingest` crate; this module wires it to what the core owns:
//!
//! - the library store: the shard and the keyword index. A write takes the library through the same `updating` state an
//!   `update_library` job uses (`libreg`), works on a real copy beside the library (`<shard>.cs-stage`, `index.cs-stage`) and swaps
//!   it in with renames, so it is all or nothing, and reopens the library when it is done;
//! - PDFium and the embedding model, which the host ships and names in the optional `engines` object of the start call;
//! - the division sorter, from `engines.classifier`: the same code as the Linux builder (`cache_pack::sorter`).

use crate::error::{Error, ErrorCode, Result};
use crate::libindex::{append_documents, Appended, IndexDoc};
use crate::libreg::{self, LibEntry, UpdateGuard};
use crate::libupdate::{self, copy_tree, hand_back_open, margin_for, sync_tree, tree_size};
use crate::library::{self, ensure_init, write_segments_manifest, LibrarySettings};
use cache_ingest::pdfium::PdfiumEngine;
use cache_ingest::{Classifier, Code as IngestCode, Env, Error as IngestError, Filing, LibraryStore, Point, Service, Staged, Swap};
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
        IngestCode::NoText => ErrorCode::NoText,
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
    Swap,
    /// The index is unfinished: it is moved away and built again when needed.
    Remove,
}

struct CoreStaged {
    lib: PathBuf,
    entry: Arc<LibEntry>,
    shard: PathBuf,
    stage: PathBuf,
    index: PathBuf,
    index_stage: PathBuf,
    index_action: IndexAction,
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
    let entry = libreg::entry_for(&shard);
    let guard = entry.begin_update()?;
    // a commit a kill interrupted is finished first (the shard may be half swapped, so it is looked for after this)
    if cache_ingest::commit::pending(library_dir) {
        if !entry.close_all(&|| false)? {
            return Err(Error::new(ErrorCode::Cancelled, "cancelled"));
        }
        libupdate::recover_leftovers(&shard)?;
    }
    if !shard.is_dir() {
        return Err(Error::not_found(format!("library shard {} not found", shard.display())));
    }
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
    let mut st = CoreStaged {
        lib: library_dir.to_path_buf(),
        entry,
        shard,
        stage,
        index,
        index_stage: index_stage.clone(),
        index_action: IndexAction::Nothing,
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
                IndexAction::Swap
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

impl Staged for CoreStaged {
    fn plan(&self) -> Vec<Swap> {
        let name = |p: &Path| p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let mut v = vec![Swap { target: name(&self.shard), stage: Some(name(&self.stage)) }];
        match self.index_action {
            IndexAction::Nothing => {}
            IndexAction::Swap => v.push(Swap { target: name(&self.index), stage: Some(name(&self.index_stage)) }),
            IndexAction::Remove => v.push(Swap { target: name(&self.index), stage: None }),
        }
        v
    }

    fn verify(&mut self) -> cache_ingest::Result<()> {
        hand_back_open(&self.shard, &self.entry).map_err(from_core)
    }

    fn before_rollback(&mut self) {
        let _ = self.entry.close_all(&|| false);
    }
}

impl Drop for CoreStaged {
    fn drop(&mut self) {
        // a commit a kill (or a failed rollback) left half done needs its staged copies: they stay for the roll forward
        if cache_ingest::commit::pending(&self.lib) {
            return;
        }
        remove_dir(&self.stage);
        remove_dir(&self.index_stage);
    }
}

impl LibraryStore for CoreStore {
    fn begin(&self, library_dir: &Path, points: &[Point]) -> cache_ingest::Result<Box<dyn Staged>> {
        begin_write(library_dir, points).map(|s| Box::new(s) as Box<dyn Staged>).map_err(from_core)
    }
}

// ---------------------------------------------------------------------------------------------------------
// The embedder

/// bge-m3 through `cache_embed`, with the settings of the queries. The model is loaded when the first passage is embedded and freed
/// by `release` (the service calls it when the jobs using it end or have been idle for `opts.embed_idle_ms`); the next embed loads
/// it again. `engines.embed_lib` is the built `libcache_llama` and `engines.embed_model` the GGUF file.
///
/// It is not shared with the app's own query embedder: that one is a separate `cl_embed_load` handle owned by a Dart isolate, which
/// the core cannot see, and a llama context must not be used from two threads at once.
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

    fn identity(&self) -> String {
        format!("{}|{}|{}", cache_ingest::Embedder::name(self), self.model.as_deref().unwrap_or(""), self.sha256.as_deref().unwrap_or(""))
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

    fn release(&self) {
        // waits for an embed in progress (it holds the lock), then frees the model
        let taken = self.loaded.lock().unwrap_or_else(PoisonError::into_inner).take();
        drop(taken);
    }
}

/// The division sorter of the Linux builder (`cache_pack::sorter`: one implementation), reading the vectors the job already made.
struct CoreClassifier {
    model: cache_classify::Model,
}

impl Classifier for CoreClassifier {
    fn classify(&self, pieces: &[cache_pack::pack::PackPiece]) -> Option<Filing> {
        let v = cache_pack::sorter::classify(&self.model, pieces).ok()?;
        let best = v.top.first()?;
        let label_of = |div: &str| self.model.classes().iter().find(|c| cache_classify::division_code(c.division) == div).map(|c| c.label.clone()).unwrap_or_else(|| div.to_string());
        let label = label_of(&best.division);
        // the top three, best first: kept in the pack so Unsorted can offer them
        let suggestions = v.top.iter().map(|s| cache_pack::pack::ShelfSuggestion { div: s.division.clone(), label: label_of(&s.division), score: Some(s.score) }).collect();
        Some(Filing {
            suggested: cache_pack::pack::Suggested {
                div: best.division.clone(),
                label,
                score: Some(best.score),
                classifier_version: Some(v.version),
                source: "classifier".to_string(),
                second_div: v.top.get(1).map(|s| s.division.clone()),
                filed: Some(v.division.is_some()),
                suggestions,
            },
            filed: v.division.is_some(),
        })
    }
}

/// The embedding model a classifier must have been trained on: `engines.embed_sha256`, else the model Cache decided on.
fn expected_embedding_sha(engines: &Value) -> String {
    text(engines, "embed_sha256").unwrap_or_else(|| cache_embed::DECIDED_MODEL_SHA256.to_string())
}

/// Loads the classifier model at `path`; refused (with the reason) when it was trained on another embedding model than `expected_sha`.
pub fn load_classifier(path: &str, expected_sha: &str) -> std::result::Result<(Arc<dyn Classifier>, u32), String> {
    let bytes = std::fs::read(path).map_err(|e| format!("{path}: {e}"))?;
    let model = cache_pack::sorter::load_model(&bytes, expected_sha).map_err(|e| e.to_string())?;
    let version = model.version();
    Ok((Arc::new(CoreClassifier { model }), version))
}

fn classifier_for(engines: &Value) -> Option<Arc<dyn Classifier>> {
    let path = text(engines, "classifier")?;
    // a classifier that cannot be used (missing, damaged, trained on another embedding model) is no classifier: the book is not
    // placed, and the probe says why
    load_classifier(&path, &expected_embedding_sha(engines)).ok().map(|(c, _)| c)
}

fn text(engines: &Value, k: &str) -> Option<String> {
    engines.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string)
}

/// The embedder of the engines named, one per process for the same engines, so two jobs never hold two copies of the model. It
/// keeps the model only while jobs use it (see `CoreEmbedder`).
fn embedder_for(engines: &Value) -> Arc<CoreEmbedder> {
    static KEPT: Mutex<Vec<Arc<CoreEmbedder>>> = Mutex::new(Vec::new());
    let (lib, model, sha256) = (text(engines, "embed_lib"), text(engines, "embed_model"), text(engines, "embed_sha256"));
    let mut g = KEPT.lock().unwrap_or_else(PoisonError::into_inner);
    if let Some(e) = g.iter().find(|e| e.lib == lib && e.model == model && e.sha256 == sha256) {
        return e.clone();
    }
    let e = Arc::new(CoreEmbedder { lib, model, sha256, loaded: Mutex::new(None) });
    g.clear();
    g.push(e.clone());
    e
}

fn production_env(engines: &Value) -> cache_ingest::Result<Env> {
    let pdf = Arc::new(PdfiumEngine::new(text(engines, "pdfium_lib"), text(engines, "pdfium_version")));
    Ok(Env {
        pdf,
        embedder: embedder_for(engines),
        store: Arc::new(CoreStore),
        classifier: classifier_for(engines),
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

/// `cs_ingest_probe`: tries to load PDFium and the embedder with the paths of `engines` and reports; keeps nothing loaded and writes
/// nothing. `load_embedder` false skips the embedder's load (reported as `{"ok": null, "skipped": true}`); the model file's
/// presence and `hash_model` still apply. Only malformed JSON is an error.
pub fn probe(args: &str) -> Result<String> {
    use serde_json::json;
    let v: Value = serde_json::from_str(args).map_err(|e| Error::bad_json(format!("the request is not JSON: {e}")))?;
    let engines = v.get("engines").cloned().unwrap_or(Value::Null);
    let hash_model = v.get("hash_model").and_then(Value::as_bool).unwrap_or(true);
    let load_embedder = v.get("load_embedder").and_then(Value::as_bool).unwrap_or(true);
    let pdfium = match cache_ingest::pdfium::probe(text(&engines, "pdfium_lib").as_deref()) {
        Ok(from) => json!({"ok": true, "version": text(&engines, "pdfium_version"), "from": from}),
        Err(e) => json!({"ok": false, "version": null, "from": null, "error": e.message}),
    };
    let (lib, model, expected) = (text(&engines, "embed_lib"), text(&engines, "embed_model"), text(&engines, "embed_sha256"));
    let embedder = match (&lib, &model) {
        _ if !load_embedder => json!({"ok": null, "skipped": true}),
        (Some(l), Some(m)) => match cache_embed::Embedder::load(l, m, None, None, 1) {
            Ok(_) => json!({"ok": true}),
            Err(e) => json!({"ok": false, "error": e.to_string()}),
        },
        _ => json!({"ok": false, "error": "engines.embed_lib and engines.embed_model are not both given"}),
    };
    let model_report = match &model {
        None => json!({"ok": false, "sha256": null, "expected": expected, "matches": null, "error": "engines.embed_model is not given"}),
        Some(m) if !Path::new(m).is_file() => json!({"ok": false, "sha256": null, "expected": expected, "matches": null, "error": format!("{m} is not a file")}),
        Some(_) if !hash_model => json!({"ok": true, "sha256": null, "expected": expected, "matches": null}),
        Some(m) => match cache_embed::sha256_file(m) {
            Ok(h) => {
                let matches = expected.as_ref().map(|e| e.trim().eq_ignore_ascii_case(&h));
                json!({"ok": matches != Some(false), "sha256": h, "expected": expected, "matches": matches})
            }
            Err(e) => json!({"ok": false, "sha256": null, "expected": expected, "matches": null, "error": e.to_string()}),
        },
    };
    let classifier = match text(&engines, "classifier") {
        None => json!({"ok": false, "version": null, "error": "engines.classifier is not given"}),
        Some(p) => match load_classifier(&p, &expected_embedding_sha(&engines)) {
            Ok((_, version)) => json!({"ok": true, "version": version}),
            Err(e) => json!({"ok": false, "version": null, "error": e}),
        },
    };
    let mut out = json!({"pdfium": pdfium, "embedder": embedder, "model": model_report, "classifier": classifier});
    // `dump`: {"pdf": "<path>", "dpi": 72}: what the job reads from that PDF, page by page (see cache_ingest::pdfium::dump)
    if let Some(d) = v.get("dump") {
        let pdf = d.get("pdf").and_then(Value::as_str).ok_or_else(|| Error::bad_json("dump.pdf must be a path"))?;
        let dpi = d.get("dpi").and_then(Value::as_u64).unwrap_or(72) as u32;
        out["dump"] = cache_ingest::pdfium::dump(text(&engines, "pdfium_lib"), Path::new(pdf), dpi).map_err(to_core)?;
    }
    Ok(out.to_string())
}
