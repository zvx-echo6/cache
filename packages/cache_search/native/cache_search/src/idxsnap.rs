//! The ZIM keyword index (kind `zim`) and the library device keyword index (kind `library`) as syncable snapshots, and the
//! migration of the old index folders into them. The generic rules (manifest, verification, the pick, publishing) are in
//! `snapshot.rs`; this file is what these two kinds add.
//!
//! ```text
//! <indexes_dir>/zim/<zim uuid>/                 source id: the ZIM's lowercase UUID
//! <indexes_dir>/library/<library_id@version>/   source id: as cs_status reports it ("@version" only when the settings have one)
//!     .build/                                   the working index (resumable, never synced); also publish-<id>/ while sealing
//!     snap/<build-id>/                          published: Tantivy files and manifest.json (written last); never written again
//! ```
//!
//! Three things happen here:
//! - **Building**: `index_zim` / `index_library` with an `indexes_dir` build in `.build/` exactly as before and publish
//!   (`run_zim`, `run_library`).
//! - **Searching**: [`SnapSlot`] verifies and opens the picked snapshot on a background thread. Until it is ready the old index
//!   (`index_dir`) is used as before.
//! - **Sealing** (`index_seal` job, [`seal`]): an index in the old location becomes a snapshot by HARD-LINKING its files, so
//!   nothing is copied and nothing is merged; the old names are removed only after the first successful open from the snapshot
//!   ([`finish_seal`]).

use crate::error::{Error, ErrorCode, Result};
use crate::index::{
    self, read_meta, stemmer_for_language, BuildParams, IndexMeta, IndexState, Lock, Outcome, ANALYZER, INDEX_FORMAT,
    LIB_INDEX_FORMAT, LOCK_FILE, META_FILE,
};
use crate::snapshot::{self, Compat, FileEntry, Manifest, Tokenizer, MANIFEST, META_LOCK, SNAP_DIR};
use crate::zimsrc::ZimSource;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const KIND_ZIM: &str = "zim";
pub const KIND_LIBRARY: &str = "library";
/// The Tantivy version the files are written by (the manifest's `tantivy`).
pub const TANTIVY: &str = "0.27";
/// Files of an index folder that are not part of a snapshot (bookkeeping and locks).
const NOT_IN_SNAPSHOT: [&str; 5] =
    [LOCK_FILE, META_FILE, "cache_search_index.json.tmp", ".tantivy-writer.lock", META_LOCK];
/// What `seal` writes in `.build/` so the old names can be removed after the first open from the snapshot.
const SEAL_MARK: &str = "sealed.json";
/// How soon a source whose snapshot did not verify (maybe still arriving) is looked at again.
const RETRY: Duration = Duration::from_secs(15);

fn kind_format(kind: &str) -> u32 {
    if kind == KIND_LIBRARY {
        LIB_INDEX_FORMAT
    } else {
        INDEX_FORMAT
    }
}

fn tokenizer_known(name: &str) -> bool {
    name.strip_suffix("_stem").is_some_and(|code| stemmer_for_language(Some(code)).is_some())
}

fn compat_with(m: &Manifest, format: u32, en_only: bool) -> std::result::Result<(), String> {
    if m.format != format || m.tantivy != TANTIVY {
        return Err(format!("format {} tantivy {} is not read by this core", m.format, m.tantivy));
    }
    match &m.tokenizer {
        Some(t) if t.analyzer == ANALYZER && tokenizer_known(&t.name) && (!en_only || t.name == "en_stem") => Ok(()),
        other => Err(format!("tokenizer {:?} is not known", other.as_ref().map(|t| &t.name))),
    }
}

/// The compatibility check of kind `zim`.
pub fn compat_zim(m: &Manifest) -> std::result::Result<(), String> {
    compat_with(m, INDEX_FORMAT, false)
}

/// The compatibility check of kind `library`.
pub fn compat_library(m: &Manifest) -> std::result::Result<(), String> {
    compat_with(m, LIB_INDEX_FORMAT, true)
}

pub fn compat_of(kind: &str) -> Compat {
    if kind == KIND_LIBRARY {
        compat_library
    } else {
        compat_zim
    }
}

/// `<indexes_dir>/<kind>/<encoded source id>`.
pub fn dir_for(indexes_dir: &Path, kind: &str, source_id: &str) -> PathBuf {
    snapshot::source_dir(indexes_dir, kind, source_id)
}

/// A library's source id as `cs_status` reports it: `library_id`, with `@version` when its settings give one.
pub fn library_source_id(library_id: &str, version: Option<&str>) -> String {
    match version {
        Some(v) => format!("{library_id}@{v}"),
        None => library_id.to_string(),
    }
}

// ---------------------------------------------------------------------------------------------------------
// Which index folders are open (a rename-seal is only allowed for one that is not)

static OPEN: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

fn canon(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

/// Held by an opened index (searching) for as long as it is open.
pub struct OpenGuard(PathBuf);

impl OpenGuard {
    pub fn new(dir: &Path) -> OpenGuard {
        let c = canon(dir);
        if let Ok(mut g) = OPEN.lock() {
            g.push(c.clone());
        }
        OpenGuard(c)
    }
}

impl Drop for OpenGuard {
    fn drop(&mut self) {
        if let Ok(mut g) = OPEN.lock() {
            if let Some(i) = g.iter().position(|p| *p == self.0) {
                g.remove(i);
            }
        }
    }
}

/// True when some handle in this process has an index in `dir` open.
pub fn is_open(dir: &Path) -> bool {
    let c = canon(dir);
    OPEN.lock().map(|g| g.contains(&c)).unwrap_or(false)
}

// ---------------------------------------------------------------------------------------------------------
// Where the old index of a source is (so `index_seal` needs only the source id)

static LEGACY: Mutex<Option<HashMap<(String, String), PathBuf>>> = Mutex::new(None);

/// Remember that the handle's source `(kind, source_id)` keeps its old index in `dir`.
pub fn note_legacy(kind: &str, source_id: &str, dir: &Path) {
    if let Ok(mut g) = LEGACY.lock() {
        g.get_or_insert_with(HashMap::new).insert((kind.to_string(), source_id.to_string()), dir.to_path_buf());
    }
}

fn legacy_of(kind: &str, source_id: &str) -> Option<PathBuf> {
    LEGACY.lock().ok()?.as_ref()?.get(&(kind.to_string(), source_id.to_string())).cloned()
}

// ---------------------------------------------------------------------------------------------------------
// Searching: the picked snapshot, opened in the background

/// An opened snapshot.
pub struct SnapOpen<T> {
    pub name: String,
    pub manifest: Manifest,
    pub dir: PathBuf,
    pub index: T,
}

type Cell<T> = Arc<Mutex<Option<Option<Box<SnapOpen<T>>>>>>;

/// The snapshot of one source: found, verified (hashed) and opened on a background thread, and chosen again when the folder's
/// listing changes. Reads only.
pub struct SnapSlot<T> {
    kind: &'static str,
    opener: fn(&Path, &Manifest) -> Result<T>,
    ready: Option<Box<SnapOpen<T>>>,
    pending: Option<Cell<T>>,
    key: Option<(PathBuf, Vec<String>)>,
    tried: Option<Instant>,
}

/// The folders under `snap/`, each marked when its manifest is there (so a snapshot whose manifest arrives later is looked at again).
fn listing_key(sd: &Path) -> Vec<String> {
    snapshot::list(sd)
        .into_iter()
        .map(|n| if sd.join(SNAP_DIR).join(&n).join(MANIFEST).is_file() { format!("{n}+") } else { n })
        .collect()
}

impl<T: Send + 'static> SnapSlot<T> {
    pub fn new(kind: &'static str, opener: fn(&Path, &Manifest) -> Result<T>) -> SnapSlot<T> {
        SnapSlot { kind, opener, ready: None, pending: None, key: None, tried: None }
    }

    pub fn ready(&self) -> Option<&SnapOpen<T>> {
        self.ready.as_deref()
    }

    /// A pick is running and nothing is ready yet.
    pub fn opening(&self) -> bool {
        self.ready.is_none() && self.pending.is_some()
    }

    /// Look at the folder again: collect a finished open, and start a new pick when the listing changed (or a snapshot that did
    /// not verify is due another look). Returns the name of a snapshot that became ready by this call.
    pub fn refresh(&mut self, indexes_dir: Option<&Path>, source_id: &str) -> Option<String> {
        let mut became = None;
        if let Some(cell) = &self.pending {
            let got = cell.lock().ok().and_then(|mut g| g.take());
            if let Some(r) = got {
                self.pending = None;
                match r {
                    Some(o) => {
                        if self.ready.as_ref().map(|c| c.name == o.name).unwrap_or(false) {
                            // the same one again: keep the open one
                        } else {
                            became = Some(o.name.clone());
                            self.ready = Some(o);
                        }
                    }
                    None => self.ready = None,
                }
            }
        }
        let Some(root) = indexes_dir else {
            self.ready = None;
            self.pending = None;
            self.key = None;
            return became;
        };
        let sd = dir_for(root, self.kind, source_id);
        let listing = listing_key(&sd);
        let key = (sd.clone(), listing.clone());
        let changed = self.key.as_ref() != Some(&key);
        if changed && self.key.as_ref().map(|k| k.0 != sd).unwrap_or(false) {
            self.ready = None;
        }
        let due = !changed
            && self.ready.is_none()
            && self.pending.is_none()
            && !listing.is_empty()
            && self.tried.map(|t| t.elapsed() >= RETRY).unwrap_or(true);
        if (changed || due) && self.pending.is_none() {
            self.key = Some(key);
            if listing.is_empty() {
                self.ready = None;
                self.tried = None;
            } else {
                self.tried = Some(Instant::now());
                self.start(sd, source_id.to_string());
            }
        } else if changed {
            // a pick is still running for the old listing: look again once it has finished
            self.key = None;
        }
        became
    }

    fn start(&mut self, sd: PathBuf, source_id: String) {
        let cell: Cell<T> = Arc::new(Mutex::new(None));
        let (c, kind, opener) = (cell.clone(), self.kind, self.opener);
        let spawned = std::thread::Builder::new().name("cs-open-snapshot".into()).spawn(move || {
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                snapshot::pick(&sd, kind, &source_id, compat_of(kind)).and_then(|pk| {
                    let index = opener(&pk.dir, &pk.manifest).ok()?;
                    // local clean-up: usable duplicates and older ones go, the one in use and a rollback stay
                    snapshot::gc(&sd, &pk);
                    Some(Box::new(SnapOpen { name: pk.name, manifest: pk.manifest, dir: pk.dir, index }))
                })
            }))
            .unwrap_or(None);
            if let Ok(mut g) = c.lock() {
                *g = Some(r);
            }
        });
        if spawned.is_ok() {
            self.pending = Some(cell);
        } else {
            self.ready = None;
        }
    }
}

/// A synthetic `IndexMeta` for a snapshot in use (so status code reads one shape).
pub fn meta_of(m: &Manifest, source_key: &str) -> IndexMeta {
    IndexMeta {
        index_format: m.format,
        tokenizer: m.tokenizer.as_ref().map(|t| t.name.clone()).unwrap_or_else(|| "en_stem".into()),
        zim_uuid: source_key.to_string(),
        state: "done".into(),
        next_entry: 0,
        total: 0,
    }
}

/// True while a job builds the source's index in `.build/`.
pub fn build_live(indexes_dir: &Path, kind: &str, source_id: &str) -> bool {
    index::lock_is_live(&snapshot::build_dir(&dir_for(indexes_dir, kind, source_id)))
}

// ---------------------------------------------------------------------------------------------------------
// Building and publishing

/// Remove what is left of a finished build: every file but the seal mark, then the folder when empty.
fn clear_build(build: &Path) {
    if let Ok(rd) = std::fs::read_dir(build) {
        for e in rd.flatten() {
            let n = e.file_name();
            if n == SEAL_MARK {
                continue;
            }
            let p = e.path();
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                let _ = std::fs::remove_dir_all(&p);
            } else {
                let _ = std::fs::remove_file(&p);
            }
        }
    }
    let _ = std::fs::remove_dir(build);
}

fn manifest_for(kind: &str, source_id: &str, tokenizer: &str, extra: Map<String, Value>) -> Manifest {
    Manifest {
        kind: kind.to_string(),
        source_id: source_id.to_string(),
        format: kind_format(kind),
        tantivy: TANTIVY.to_string(),
        tokenizer: Some(Tokenizer { name: tokenizer.to_string(), analyzer: ANALYZER.to_string(), remove_long: 40 }),
        chunker: None,
        core: env!("CARGO_PKG_VERSION").to_string(),
        created: snapshot::iso_now(),
        extra,
        files: Vec::new(),
    }
}

/// Stage the finished build, write the manifest last and publish by one rename. `None` when cancelled (the build is as it was).
fn publish_build(
    sd: &Path,
    kind: &str,
    source_id: &str,
    tokenizer: &str,
    extra: Map<String, Value>,
    phase: &dyn Fn(&str, u64, u64),
    cancelled: &dyn Fn() -> bool,
) -> Result<Option<(String, u64)>> {
    let build = snapshot::build_dir(sd);
    let manifest = manifest_for(kind, source_id, tokenizer, extra);
    compat_of(kind)(&manifest).map_err(Error::unsupported)?;
    let Some(stage) = snapshot::stage(&build, &NOT_IN_SNAPSHOT, true, &|d, t| phase("manifest", d, t + 1), cancelled)?
    else {
        return Ok(None);
    };
    let (id, bytes) = (stage.build_id.clone(), stage.bytes);
    if cancelled() {
        snapshot::abort(&stage);
        return Ok(None);
    }
    phase("publish", 0, 1);
    snapshot::publish(sd, stage, manifest)?;
    clear_build(&build);
    phase("publish", 1, 1);
    Ok(Some((id, bytes)))
}

/// A snapshot of the source that this device can already use (a peer's, or an earlier build's): the job adopts it.
fn adopted(sd: &Path, kind: &str, source_id: &str) -> Option<String> {
    if snapshot::list(sd).is_empty() {
        return None;
    }
    snapshot::pick(sd, kind, source_id, compat_of(kind)).map(|p| p.name)
}

/// A job's phase report: (phase, done, total).
pub type PhaseFn<'a> = dyn Fn(&str, u64, u64) + 'a;
/// One build loop: (working folder, progress, cancelled).
type BuildFn<'a> = dyn Fn(&Path, &dyn Fn(u64, u64), &dyn Fn() -> bool) -> Result<Outcome> + 'a;

/// What a snapshot build reports to its job.
pub struct Hooks<'a> {
    pub progress: Box<dyn Fn(u64, u64) + 'a>,
    pub phase: Box<PhaseFn<'a>>,
    pub cancelled: Box<dyn Fn() -> bool + 'a>,
    pub set_result: Box<dyn Fn(Value) + 'a>,
}

/// Build (or resume) the index in `.build/` and publish it, stopping early when a usable snapshot appears (synced from a peer).
fn run_build(
    sd: &Path,
    kind: &str,
    source_id: &str,
    default_tokenizer: &str,
    extra: Map<String, Value>,
    h: &Hooks,
    build_fn: &BuildFn,
) -> Result<Outcome> {
    let build = snapshot::build_dir(sd);
    if let Some(name) = adopted(sd, kind, source_id) {
        clear_build(&build);
        (h.set_result)(json!({"adopted": true, "snapshot": name}));
        return Ok(Outcome::Done);
    }
    let seen = listing_key(sd);
    let peer = std::cell::Cell::new(false);
    let cancelled = || {
        if (h.cancelled)() {
            return true;
        }
        let now = listing_key(sd);
        if now != seen && !now.is_empty() && adopted(sd, kind, source_id).is_some() {
            peer.set(true);
            return true;
        }
        false
    };
    let out = build_fn(&build, &*h.progress, &cancelled)?;
    if out == Outcome::Cancelled {
        if peer.get() {
            if let Some(name) = adopted(sd, kind, source_id) {
                clear_build(&build);
                (h.set_result)(json!({"adopted": true, "snapshot": name}));
                return Ok(Outcome::Done);
            }
        }
        return Ok(Outcome::Cancelled);
    }
    // the tokenizer the build used (a resumed build keeps the one in its record)
    let tok = read_meta(&build).map(|m| m.tokenizer).unwrap_or_else(|| default_tokenizer.to_string());
    match publish_build(sd, kind, source_id, &tok, extra, &*h.phase, &*h.cancelled)? {
        Some((id, bytes)) => {
            (h.set_result)(json!({"adopted": false, "snapshot": id, "bytes": bytes}));
            Ok(Outcome::Done)
        }
        None => Ok(Outcome::Cancelled),
    }
}

/// `index_zim` with an `indexes_dir`: the caller holds the `Lock` on `.build/`.
pub fn run_zim(zim: &ZimSource, sd: &Path, heap_mb: usize, checkpoint: usize, h: &Hooks) -> Result<Outcome> {
    let mut extra = Map::new();
    extra.insert("zim_uuid".into(), json!(zim.id));
    run_build(
        sd,
        KIND_ZIM,
        &zim.id,
        index::tokenizer_name_for(zim.language.as_deref()),
        extra,
        h,
        &|build, progress, cancelled| {
            index::build_zim_index(
                &BuildParams { zim, index_dir: build, heap_mb, checkpoint_articles: checkpoint },
                progress,
                cancelled,
            )
        },
    )
}

/// `index_library` with an `indexes_dir`: the caller holds the `Lock` on `.build/`.
pub fn run_library(
    p: &crate::libindex::LibBuildParams,
    sd: &Path,
    source_id: &str,
    library_id: &str,
    version: Option<&str>,
    h: &Hooks,
) -> Result<Outcome> {
    let mut extra = Map::new();
    extra.insert("library_id".into(), json!(library_id));
    if let Some(v) = version {
        extra.insert("version".into(), json!(v));
    }
    run_build(sd, KIND_LIBRARY, source_id, crate::libindex::TOKENIZER, extra, h, &|build, progress, cancelled| {
        crate::libindex::build_library_index(
            &crate::libindex::LibBuildParams {
                library_path: p.library_path,
                settings: p.settings,
                index_dir: build,
                heap_mb: p.heap_mb,
                checkpoint_docs: p.checkpoint_docs,
            },
            progress,
            cancelled,
        )
    })
}

// ---------------------------------------------------------------------------------------------------------
// Sealing

#[derive(Serialize, Deserialize)]
struct SealMark {
    snapshot: String,
    legacy_dir: String,
    names: Vec<String>,
}

/// After the first successful open from snapshot `opened`: remove the old names of an index that `seal` hard-linked into it. A
/// no-op for any other snapshot and for sources that were never sealed here. Returns true when something was removed.
pub fn finish_seal(sd: &Path, opened: &str) -> bool {
    let mark_path = snapshot::build_dir(sd).join(SEAL_MARK);
    let Ok(text) = std::fs::read_to_string(&mark_path) else { return false };
    let Ok(mark) = serde_json::from_str::<SealMark>(&text) else { return false };
    if mark.snapshot != opened {
        return false;
    }
    let legacy = PathBuf::from(&mark.legacy_dir);
    if index::lock_is_live(&legacy) {
        return false;
    }
    let mut ok = true;
    // the sidecar goes first: without it the old folder no longer reads as an index
    for n in std::iter::once(META_FILE.to_string()).chain(mark.names.iter().cloned()) {
        match std::fs::remove_file(legacy.join(&n)) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => ok = false,
        }
    }
    for n in NOT_IN_SNAPSHOT {
        let _ = std::fs::remove_file(legacy.join(n));
    }
    let _ = std::fs::remove_dir(&legacy);
    if ok {
        let _ = std::fs::remove_file(&mark_path);
        let _ = std::fs::remove_dir(snapshot::build_dir(sd));
    }
    ok
}

/// What `index_seal` was asked.
pub struct SealRequest {
    pub kind: &'static str,
    pub source_id: String,
    pub sd: PathBuf,
    pub legacy: PathBuf,
    /// Held for the job's lifetime: `.build/` of the source.
    pub lock: Option<Lock>,
}

/// Parse and check an `index_seal` request: `{"indexes_dir","kind","source_id","index_dir"?}`. `index_dir` names the old index
/// folder; without it the one a handle's source config gave is used. `busy` while the source is being built.
pub fn prepare_seal(params_json: &str) -> Result<SealRequest> {
    #[derive(Deserialize)]
    struct P {
        indexes_dir: String,
        kind: String,
        source_id: String,
        #[serde(default)]
        index_dir: Option<String>,
    }
    let p: P = serde_json::from_str(params_json)?;
    let kind = match p.kind.as_str() {
        KIND_ZIM => KIND_ZIM,
        KIND_LIBRARY => KIND_LIBRARY,
        other => return Err(Error::bad_json(format!("kind must be \"zim\" or \"library\", not {other:?}"))),
    };
    if p.indexes_dir.is_empty() || p.source_id.is_empty() {
        return Err(Error::bad_json("indexes_dir and source_id must not be empty"));
    }
    let source_id = if kind == KIND_ZIM { p.source_id.to_ascii_lowercase() } else { p.source_id };
    let legacy = p
        .index_dir
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .or_else(|| legacy_of(kind, &source_id))
        .ok_or_else(|| Error::not_found(format!("no old index is known for {kind} {source_id}")))?;
    let sd = dir_for(Path::new(&p.indexes_dir), kind, &source_id);
    let lock = Lock::acquire(&snapshot::build_dir(&sd))?;
    Ok(SealRequest { kind, source_id, sd, legacy, lock: Some(lock) })
}

enum Placed {
    Linked,
    Moved,
}

/// Seal the old index into a snapshot (see the module comment). `Done` with `{"adopted":true,"snapshot"}` when a usable snapshot
/// already exists; `{"adopted":false,"snapshot","files","bytes","method":"link"|"rename"}` after sealing.
pub fn seal(req: &SealRequest, h: &Hooks) -> Result<Outcome> {
    let (kind, sid, sd, legacy) = (req.kind, req.source_id.as_str(), req.sd.as_path(), req.legacy.as_path());
    if let Some(name) = adopted(sd, kind, sid) {
        (h.set_result)(json!({"adopted": true, "snapshot": name}));
        return Ok(Outcome::Done);
    }
    // the old index must be a finished one of this format and this source
    let format = kind_format(kind);
    if index::lock_is_live(legacy) {
        return Err(Error::busy(format!("{} is being indexed", legacy.display())));
    }
    let meta = read_meta(legacy)
        .ok_or_else(|| Error::new(ErrorCode::IndexMissing, format!("{} holds no index", legacy.display())))?;
    let belongs = if kind == KIND_ZIM {
        meta.zim_uuid.eq_ignore_ascii_case(sid)
    } else {
        meta.zim_uuid
            .strip_prefix("lib:")
            .is_some_and(|id| sid == id || sid.strip_prefix(id).is_some_and(|r| r.starts_with('@')))
    };
    if !belongs {
        return Err(Error::new(
            ErrorCode::IndexMissing,
            format!("{} is the index of another source", legacy.display()),
        ));
    }
    match index::index_state_for(Some(legacy), &meta.zim_uuid, format) {
        IndexState::Done(_) => {}
        IndexState::Building => return Err(Error::busy(format!("{} is being indexed", legacy.display()))),
        IndexState::Missing => {
            return Err(Error::new(ErrorCode::IndexMissing, format!("{} holds no index", legacy.display())))
        }
        IndexState::Stale | IndexState::Incomplete => {
            return Err(Error::new(
                ErrorCode::IndexStale,
                format!("the index in {} is not finished or is of another format; build it again", legacy.display()),
            ))
        }
    }
    if !legacy.join("meta.json").is_file() {
        return Err(Error::new(ErrorCode::IndexMissing, format!("{} holds no index files", legacy.display())));
    }
    let mut extra = Map::new();
    if kind == KIND_ZIM {
        extra.insert("zim_uuid".into(), json!(sid));
    } else if let Some(id) = meta.zim_uuid.strip_prefix("lib:") {
        extra.insert("library_id".into(), json!(id));
        if let Some(v) = sid.strip_prefix(id).and_then(|r| r.strip_prefix('@')) {
            extra.insert("version".into(), json!(v));
        }
    }
    extra.insert("sealed".into(), json!(true));
    let mut manifest = manifest_for(kind, sid, &meta.tokenizer, extra);
    compat_of(kind)(&manifest).map_err(|why| Error::new(ErrorCode::IndexStale, why))?;

    let mut names: Vec<String> = std::fs::read_dir(legacy)
        .map_err(|e| Error::io(format!("{}: {e}", legacy.display())))?
        .flatten()
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !NOT_IN_SNAPSHOT.contains(&n.as_str()) && n != MANIFEST)
        .collect();
    names.sort();

    let build = snapshot::build_dir(sd);
    let build_id = snapshot::new_build_id();
    let stage = build.join(format!("publish-{build_id}"));
    std::fs::create_dir_all(&stage).map_err(|e| Error::io(format!("{}: {e}", stage.display())))?;
    let mut placed: Vec<(String, Placed)> = Vec::new();
    let undo = |placed: &[(String, Placed)]| {
        for (n, how) in placed {
            match how {
                Placed::Linked => {
                    let _ = std::fs::remove_file(stage.join(n));
                }
                Placed::Moved => {
                    let _ = std::fs::rename(stage.join(n), legacy.join(n));
                }
            }
        }
        let _ = std::fs::remove_dir_all(&stage);
        let _ = std::fs::remove_file(build.join(SEAL_MARK));
        let _ = std::fs::remove_dir(&build);
    };

    // 1. link (or, when links are not possible and nobody has the index open, move)
    let total = names.len() as u64;
    (h.phase)("link", 0, total);
    for (k, n) in names.iter().enumerate() {
        if (h.cancelled)() {
            undo(&placed);
            return Ok(Outcome::Cancelled);
        }
        let to = stage.join(n);
        match std::fs::hard_link(legacy.join(n), &to) {
            Ok(()) => placed.push((n.clone(), Placed::Linked)),
            Err(link_err) => {
                if is_open(legacy) {
                    undo(&placed);
                    return Err(Error::busy(format!(
                        "{} is open and cannot be hard-linked ({link_err}); try again later",
                        legacy.display()
                    )));
                }
                match std::fs::rename(legacy.join(n), &to) {
                    Ok(()) => placed.push((n.clone(), Placed::Moved)),
                    Err(e) => {
                        undo(&placed);
                        return Err(Error::io(format!("{n}: {link_err}; {e}")));
                    }
                }
            }
        }
        (h.phase)("link", k as u64 + 1, total);
    }

    // 2. hash what the manifest lists
    let mut run = || -> Result<Option<(Vec<FileEntry>, u64)>> {
        (h.phase)("verify", 0, total);
        let (mut files, mut bytes) = (Vec::new(), 0u64);
        for (k, n) in names.iter().enumerate() {
            if (h.cancelled)() {
                return Ok(None);
            }
            let (sha256, size) = snapshot::hash_file(&stage.join(n))?;
            bytes += size;
            files.push(FileEntry { path: n.clone(), size, sha256 });
            (h.phase)("verify", k as u64 + 1, total);
        }
        std::fs::write(stage.join(META_LOCK), b"").map_err(|e| Error::io(format!("{}: {e}", stage.display())))?;
        // 3. the manifest, last
        (h.phase)("manifest", 0, 1);
        manifest.files = files.clone();
        let text = serde_json::to_string_pretty(&manifest).map_err(|e| Error::internal(e.to_string()))?;
        let tmp = stage.join(format!("{MANIFEST}.tmp"));
        std::fs::write(&tmp, text).map_err(|e| Error::io(format!("{}: {e}", tmp.display())))?;
        std::fs::rename(&tmp, stage.join(MANIFEST)).map_err(|e| Error::io(format!("{}: {e}", stage.display())))?;
        (h.phase)("manifest", 1, 1);
        Ok(Some((files, bytes)))
    };
    let (files, bytes) = match run() {
        Ok(Some(x)) => x,
        Ok(None) => {
            undo(&placed);
            return Ok(Outcome::Cancelled);
        }
        Err(e) => {
            undo(&placed);
            return Err(e);
        }
    };
    if (h.cancelled)() {
        undo(&placed);
        return Ok(Outcome::Cancelled);
    }

    // 4. publish: the mark first (so a crash right after still finds the old names), then one rename
    (h.phase)("publish", 0, 1);
    let moved = placed.iter().any(|(_, p)| matches!(p, Placed::Moved));
    if !moved {
        let mark = SealMark {
            snapshot: build_id.clone(),
            legacy_dir: legacy.to_string_lossy().into_owned(),
            names: names.clone(),
        };
        let text = serde_json::to_string(&mark).map_err(|e| Error::internal(e.to_string()))?;
        if let Err(e) = std::fs::write(build.join(SEAL_MARK), text) {
            undo(&placed);
            return Err(Error::io(format!("{}: {e}", build.display())));
        }
    }
    let target = sd.join(SNAP_DIR).join(&build_id);
    let renamed = std::fs::create_dir_all(sd.join(SNAP_DIR)).and_then(|_| std::fs::rename(&stage, &target));
    if let Err(e) = renamed {
        undo(&placed);
        return Err(Error::new(ErrorCode::Io, format!("publishing {}: {e}", target.display())));
    }
    if moved {
        // the old folder no longer holds the index: drop what is left of it now
        let _ = std::fs::remove_file(legacy.join(META_FILE));
        for n in NOT_IN_SNAPSHOT {
            let _ = std::fs::remove_file(legacy.join(n));
        }
        let _ = std::fs::remove_dir(legacy);
        clear_build(&build);
    } else {
        let _ = std::fs::remove_dir(&build);
    }
    (h.phase)("publish", 1, 1);
    (h.set_result)(json!({
        "adopted": false, "snapshot": build_id, "files": files.len(), "bytes": bytes,
        "method": if moved { "rename" } else { "link" },
    }));
    Ok(Outcome::Done)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn library_source_ids_follow_status() {
        assert_eq!(library_source_id("lib", Some("3")), "lib@3");
        assert_eq!(library_source_id("lib", None), "lib");
    }

    #[test]
    fn compat_checks_format_tantivy_and_tokenizer() {
        let mut m = manifest_for(KIND_ZIM, "u", "fr_stem", Map::new());
        assert!(compat_zim(&m).is_ok());
        assert!(compat_library(&m).is_err(), "a library index is English-only and has its own format");
        m.tantivy = "0.99".into();
        assert!(compat_zim(&m).is_err());
        let l = manifest_for(KIND_LIBRARY, "l@1", "en_stem", Map::new());
        assert!(compat_library(&l).is_ok() && compat_zim(&l).is_err());
    }

    #[test]
    fn open_guard_counts_opens() {
        let d = std::env::temp_dir().join(format!("cs-idxsnap-open-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        assert!(!is_open(&d));
        let g = OpenGuard::new(&d);
        assert!(is_open(&d));
        drop(g);
        assert!(!is_open(&d));
        let _ = std::fs::remove_dir_all(&d);
    }
}
