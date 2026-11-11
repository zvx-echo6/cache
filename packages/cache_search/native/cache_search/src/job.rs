//! Long jobs: `index_zim`, `index_library`, `update_library`, `library_manifest`, the library adding jobs
//! (`unpack_library`, `check_library`, `library_template`) and the downloads run on their own threads and are polled.

use crate::error::{Error, Result};
use crate::duty::{self, Duty, Throttle};
use crate::idxsnap;
use crate::index::{self, BuildParams, Lock, Outcome};
use crate::libadd;
use crate::libindex::{self, LibBuildParams};
use crate::libreg;
use crate::libupdate;
use crate::library::LibrarySettings;
use crate::zimsrc::ZimSource;
use serde::Deserialize;
use serde_json::{json, Value};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum State {
    Running,
    Done,
    Cancelled,
    Failed,
}

impl State {
    fn as_str(self) -> &'static str {
        match self {
            State::Running => "running",
            State::Done => "done",
            State::Cancelled => "cancelled",
            State::Failed => "failed",
        }
    }
}

struct Shared {
    cancel: AtomicBool,
    done: AtomicU64,
    total: AtomicU64,
    state: Mutex<(State, Option<Error>)>,
    /// Extra progress a kind reports (layer_download: bytes written); shown as "detail" when set.
    detail: Mutex<Option<Value>>,
    /// The step a multi-step job is in (`pdfindex_finish`: merge, manifest, publish); shown as "phase" when set.
    phase: Mutex<Option<String>>,
    /// Every phase the job has entered, in order (each once in a row): what a poller that missed a short phase can still see.
    phases: Mutex<Vec<String>>,
    /// What a finished job returns (`pdfindex_finish`); shown as "result" when set.
    result: Mutex<Option<Value>>,
    /// The job's pacing (duty.rs): work/idle, pause, writer threads, the self back-off.
    throttle: Throttle,
    /// Kinds without their own pace points (downloads, updates) pace at their progress reports.
    pace_on_progress: bool,
}

impl Shared {
    fn set_progress(&self, d: u64, t: u64) {
        self.done.store(d, Ordering::SeqCst);
        self.total.store(t, Ordering::SeqCst);
        if self.pace_on_progress {
            self.pace();
        }
    }

    fn set_phase(&self, phase: &str, d: u64, t: u64) {
        if let Ok(mut g) = self.phase.lock() {
            *g = Some(phase.to_string());
        }
        if let Ok(mut g) = self.phases.lock() {
            if g.last().map(String::as_str) != Some(phase) {
                g.push(phase.to_string());
            }
        }
        self.set_progress(d, t);
        // the index kinds pace at every item of a phase (a file hashed, linked or moved)
        if !self.pace_on_progress {
            self.pace();
        }
    }

    /// Called between items: idles, pauses or returns at once on cancel (see duty.rs).
    fn pace(&self) {
        self.throttle.tick(&|| self.cancel.load(Ordering::SeqCst));
    }
}

thread_local! {
    /// The duty `Job::start` worked out for the job it is starting (read by `spawn` on the same thread).
    static PENDING_DUTY: std::cell::Cell<(Duty, bool)> = const { std::cell::Cell::new((Duty::FULL, true)) };
}

/// The kinds that do background index work, which run gently unless asked otherwise.
fn gentle_kind(kind: &str) -> bool {
    matches!(kind, "index_zim" | "index_library" | "index_extend" | "index_seal" | "index_source" | "pdfindex_finish" | "test_pace")
}

/// Layer downloads running in this process, by layer and area: a second one for the same area is `busy`.
struct ActiveDownload(String);

static ACTIVE: Mutex<Vec<String>> = Mutex::new(Vec::new());

impl ActiveDownload {
    fn acquire(key: &str) -> Result<ActiveDownload> {
        let mut g = ACTIVE.lock().unwrap_or_else(|e| e.into_inner());
        if g.iter().any(|k| k == key) {
            return Err(Error::busy(format!("{key} is already being downloaded")));
        }
        g.push(key.to_string());
        Ok(ActiveDownload(key.to_string()))
    }
}

impl Drop for ActiveDownload {
    fn drop(&mut self) {
        let mut g = ACTIVE.lock().unwrap_or_else(|e| e.into_inner());
        g.retain(|k| *k != self.0);
    }
}

pub struct Job {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

#[derive(Deserialize)]
struct IndexZimParams {
    zim_path: String,
    /// The old index folder. Not needed (and not used) when `indexes_dir` is given.
    #[serde(default)]
    index_dir: String,
    /// The app's syncable indexes folder: the index is built in `<indexes_dir>/zim/<uuid>/.build/` and published as a snapshot.
    #[serde(default)]
    indexes_dir: Option<String>,
    #[serde(default = "default_heap")]
    heap_mb: usize,
    /// Not in the header: articles per checkpoint (default 2000). Tests use a small value.
    #[serde(default = "default_checkpoint")]
    checkpoint_articles: usize,
}

#[derive(Deserialize)]
struct IndexLibraryParams {
    library_path: String,
    /// The old index folder. Not needed (and not used) when `indexes_dir` is given.
    #[serde(default)]
    index_dir: String,
    /// The app's syncable indexes folder: the index is built in `<indexes_dir>/library/<library_id@version>/.build/` and published
    /// as a snapshot.
    #[serde(default)]
    indexes_dir: Option<String>,
    #[serde(default = "default_heap")]
    heap_mb: usize,
    /// The library's settings object, as in `cs_open`; guessed from the payload when absent. It must be the
    /// same settings the handle opens the library with (the index is tied to the settings' `library_id`).
    #[serde(default)]
    settings: Option<Value>,
    /// Not in the header: documents per checkpoint (default 200,000). Tests use a small value.
    #[serde(default = "default_lib_checkpoint")]
    checkpoint_docs: usize,
}

#[derive(Deserialize)]
struct UpdateLibraryParams {
    library_path: String,
    snapshot_path: String,
    snapshot_manifest_path: String,
    /// Not in the header: a test hook that pauses the job (cancellably) before the copy and apply steps.
    #[serde(default)]
    hold_ms: u64,
    /// Not in the header: a test hook. While this file exists the job waits (at most two minutes, not
    /// cancellably) after the staging copy is updated and before the swap.
    #[serde(default)]
    hold_swap_file: Option<String>,
    /// Not in the header: a test hook that replaces the free space statvfs reports, in bytes.
    #[serde(default)]
    fake_available_bytes: Option<u64>,
    /// Not in the header: a test hook that makes the job fail at a named point: "after_copy", "before_swap" or
    /// "after_swap".
    #[serde(default)]
    fail_at: Option<String>,
}

#[derive(Deserialize)]
struct LibraryManifestParams {
    library_path: String,
    out_path: String,
    /// Not in the header: a test hook that pauses the job (cancellably) before the read-write load.
    #[serde(default)]
    hold_ms: u64,
}

#[derive(Deserialize)]
struct UnpackLibraryParams {
    snapshot_path: String,
    dir: String,
    #[serde(default)]
    settings: Option<Value>,
    /// Not in the header: a test hook that replaces the free space the system reports, in bytes.
    #[serde(default)]
    fake_available_bytes: Option<u64>,
}

#[derive(Deserialize)]
struct CheckLibraryParams {
    library_path: String,
    #[serde(default)]
    settings: Option<Value>,
}

#[derive(Deserialize)]
struct LibraryTemplateParams {
    out_path: String,
}

fn default_lib_checkpoint() -> usize {
    libindex::DEFAULT_CHECKPOINT_DOCS
}

fn default_heap() -> usize {
    200
}
fn default_checkpoint() -> usize {
    index::DEFAULT_CHECKPOINT
}

impl Job {
    /// Start a job. Parameter errors, an unreadable ZIM and a busy `index_dir` are reported here (the call
    /// returns an error and no job exists); errors during the build make the job `failed`.
    pub fn start(kind: &str, params_json: &str) -> Result<Job> {
        let gentle = gentle_kind(kind);
        let duty = duty::from_params(params_json, if gentle { Duty::GENTLE } else { Duty::FULL })?;
        PENDING_DUTY.with(|c| c.set((duty, !gentle)));
        let r = Self::start_kind(kind, params_json);
        PENDING_DUTY.with(|c| c.set((Duty::FULL, true)));
        r
    }

    fn start_kind(kind: &str, params_json: &str) -> Result<Job> {
        match kind {
            "index_zim" => Self::start_index_zim(params_json),
            "index_library" => Self::start_index_library(params_json),
            "index_extend" => Self::start_index_extend(params_json),
            "update_library" => Self::start_update_library(params_json),
            "library_manifest" => Self::start_library_manifest(params_json),
            "unpack_library" => Self::start_unpack_library(params_json),
            "check_library" => Self::start_check_library(params_json),
            "library_template" => Self::start_library_template(params_json),
            "video_download" => Self::start_video_download(params_json),
            "layer_download" => Self::start_layer_download(params_json),
            "pdfindex_finish" => Self::start_pdfindex_finish(params_json),
            "index_seal" => Self::start_index_seal(params_json),
            "test_pace" => Self::start_test_pace(params_json),
            "zim_pdfs" => Self::start_zim_pdfs(params_json),
            "index_source" => Self::start_index_source(params_json),
            "index_pack" => Err(Error::unsupported("index_pack is not supported yet")),
            other => Err(Error::bad_json(format!("unknown job kind {other:?}"))),
        }
    }

    fn start_index_zim(params_json: &str) -> Result<Job> {
        let p: IndexZimParams = serde_json::from_str(params_json)?;
        let root = p.indexes_dir.as_deref().filter(|d| !d.is_empty()).map(PathBuf::from);
        if p.zim_path.is_empty() || (p.index_dir.is_empty() && root.is_none()) {
            return Err(Error::bad_json("zim_path and index_dir (or indexes_dir) must not be empty"));
        }
        let zim = ZimSource::open(std::path::Path::new(&p.zim_path))?;
        if let Some(root) = root {
            // a snapshot build: .build/ of the ZIM's folder, resumable; published when finished
            let sd = idxsnap::dir_for(&root, idxsnap::KIND_ZIM, &zim.id);
            let lock = Lock::acquire(&crate::snapshot::build_dir(&sd))?;
            let (heap_mb, checkpoint, total) = (p.heap_mb, p.checkpoint_articles, zim.entry_count());
            return Self::spawn("cs-index-zim", lock, total, move |sh| {
                idxsnap::run_zim(&zim, &sd, heap_mb, checkpoint, &Self::hooks(sh))
            });
        }
        let dir = PathBuf::from(&p.index_dir);
        let lock = Lock::acquire(&dir)?;
        let total = zim.entry_count();
        let heap_mb = p.heap_mb;
        let checkpoint = p.checkpoint_articles;
        Self::spawn("cs-index-zim", lock, total, move |sh| {
            index::build_zim_index(
                &BuildParams {
                    zim: &zim,
                    index_dir: &dir,
                    heap_mb,
                    checkpoint_articles: checkpoint,
                    threads: sh.throttle.threads(),
                    pace: Some(&|| sh.pace()),
                },
                &|d, t| sh.set_progress(d, t),
                &|| sh.cancel.load(Ordering::SeqCst),
            )
        })
    }

    /// Start a `pdfindex_finish` job: `{"zim_path"}`. Merges the ZIM's PDF index build to one segment, writes the snapshot with
    /// its manifest (last) into a temporary folder and publishes it by one rename to `snap/<build-id>/` (see pdfbuild.rs).
    /// `not_found` without a build, `busy` while a build session is open. Progress phases "merge", "manifest", "publish";
    /// cancel is honoured until "publish"; the result is in the progress JSON as "result" when done.
    fn start_pdfindex_finish(params_json: &str) -> Result<Job> {
        let mut req = crate::pdfbuild::prepare_finish(params_json)?;
        let lock = req.take_lock();
        Self::spawn("cs-pdfindex-finish", lock, 1, move |sh| {
            let (outcome, result) = crate::pdfbuild::finish(&req, &|ph, d, t| sh.set_phase(ph, d, t), &|| sh.cancel.load(Ordering::SeqCst))?;
            if let (Some(r), Ok(mut g)) = (result, sh.result.lock()) {
                *g = Some(r);
            }
            Ok(outcome)
        })
    }

    /// Start a `zim_pdfs` job: `{"zim_path"}`. Lists the ZIM's PDFs (what `cs_zim_pdfs` answers, see zimpdfs.rs) on a thread of
    /// its own, so the core's worker is free meanwhile; the list is in the progress JSON as "result" when done. Progress is
    /// directory entries looked at, of all. `bad_json` for bad parameters; an unreadable ZIM makes the job `failed`.
    fn start_zim_pdfs(params_json: &str) -> Result<Job> {
        #[derive(Deserialize)]
        struct P {
            zim_path: String,
        }
        let p: P = serde_json::from_str(params_json)?;
        if p.zim_path.is_empty() {
            return Err(Error::bad_json("zim_path must not be empty"));
        }
        let path = PathBuf::from(p.zim_path);
        Self::spawn("cs-zim-pdfs", (), 0, move |sh| {
            match crate::zimpdfs::list_path(&path, None, &|d, t| sh.set_progress(d, t), &|| sh.cancel.load(Ordering::SeqCst))? {
                Some(v) => {
                    if let Ok(mut g) = sh.result.lock() {
                        *g = Some(v);
                    }
                    Ok(Outcome::Done)
                }
                None => Ok(Outcome::Cancelled),
            }
        })
    }

    /// Run `work` on a thread of its own, reporting through a job: for the handle's own long calls (`cs_live_fetch_start`).
    /// The answer `work` gives is the progress JSON's "result".
    pub(crate) fn spawn_result(name: &str, work: impl FnOnce(&dyn Fn() -> bool) -> Result<Value> + Send + 'static) -> Result<Job> {
        Self::spawn(name, (), 1, move |sh| {
            let v = work(&|| sh.cancel.load(Ordering::SeqCst))?;
            if let Ok(mut g) = sh.result.lock() {
                *g = Some(v);
            }
            sh.set_progress(1, 1);
            Ok(Outcome::Done)
        })
    }

    /// Start an `index_seal` job: `{"indexes_dir","kind":"zim"|"library","source_id","index_dir"?}`. Seals the index in its old
    /// folder into a snapshot by hard links (see idxsnap.rs), or adopts a usable snapshot that is already there. Progress phases
    /// "link", "verify", "manifest", "publish"; cancel is honoured until "publish"; the result is in the progress JSON.
    fn start_index_seal(params_json: &str) -> Result<Job> {
        let mut req = idxsnap::prepare_seal(params_json)?;
        let lock = req.lock.take();
        Self::spawn("cs-index-seal", lock, 1, move |sh| idxsnap::seal(&req, &Self::hooks(sh)))
    }

    /// Start a `test_pace` job (not in the header): `{"items","item_ms"}`; each item busy-works `item_ms` and then calls the pace
    /// point, like an index loop. For the tests of duty.rs.
    fn start_test_pace(params_json: &str) -> Result<Job> {
        #[derive(Deserialize)]
        struct P {
            items: u64,
            #[serde(default)]
            item_ms: u64,
        }
        let p: P = serde_json::from_str(params_json)?;
        Self::spawn("cs-test-pace", (), p.items, move |sh| {
            for i in 0..p.items {
                if sh.cancel.load(Ordering::SeqCst) {
                    return Ok(Outcome::Cancelled);
                }
                let t0 = std::time::Instant::now();
                while t0.elapsed() < std::time::Duration::from_millis(p.item_ms) {
                    std::hint::spin_loop();
                }
                sh.set_progress(i + 1, p.items);
                sh.pace();
            }
            Ok(Outcome::Done)
        })
    }

    /// What a snapshot job reports to its poller.
    fn hooks(sh: &Shared) -> idxsnap::Hooks<'_> {
        idxsnap::Hooks {
            progress: Box::new(|d, t| sh.set_progress(d, t)),
            phase: Box::new(|ph, d, t| sh.set_phase(ph, d, t)),
            cancelled: Box::new(|| sh.cancel.load(Ordering::SeqCst)),
            pace: Box::new(|| sh.pace()),
            threads: sh.throttle.threads(),
            set_result: Box::new(|v| {
                if let Ok(mut g) = sh.result.lock() {
                    *g = Some(v);
                }
            }),
        }
    }

    /// Start an `index_source` job: `{"indexes_dir","kind","source_id"}` with kind `captions`, `zim-captions` or `zim-epub`
    /// (`zim-epub` also takes `"previous": {"zim_uuid"}`). Reads the source, builds the keyword index (resumable, in
    /// `.build/`) and publishes it as a snapshot (see kwbuild.rs). `bad_json` for bad parameters, `not_found` for a saved
    /// video or a ZIM the core does not know, `busy` while another job builds the same source. Progress phases "read"
    /// (done of total items), "index", "merge", "manifest", "publish"; cancel is honoured until "publish" and keeps the
    /// build for a resume; the result is in the progress JSON as "result" when done.
    fn start_index_source(params_json: &str) -> Result<Job> {
        let mut req = crate::kwbuild::prepare(params_json)?;
        let lock = req.take_lock();
        Self::spawn("cs-index-source", lock, 0, move |sh| {
            let (outcome, result) = crate::kwbuild::run(&mut req, &|ph, d, t| sh.set_phase(ph, d, t), &|| sh.cancel.load(Ordering::SeqCst))?;
            if let (Some(r), Ok(mut g)) = (result, sh.result.lock()) {
                *g = Some(r);
            }
            Ok(outcome)
        })
    }

    fn start_index_library(params_json: &str) -> Result<Job> {
        let p: IndexLibraryParams = serde_json::from_str(params_json)?;
        let root = p.indexes_dir.as_deref().filter(|d| !d.is_empty()).map(PathBuf::from);
        if p.library_path.is_empty() || (p.index_dir.is_empty() && root.is_none()) {
            return Err(Error::bad_json("library_path and index_dir (or indexes_dir) must not be empty"));
        }
        // a bad settings object and a missing folder are reported here; opening the (possibly huge) shard
        // happens on the job's thread
        if let Some(s) = &p.settings {
            LibrarySettings::parse(s)?;
        }
        let lib_path = PathBuf::from(&p.library_path);
        if !lib_path.is_dir() {
            return Err(Error::not_found(format!("library folder {} not found", lib_path.display())));
        }
        // an update owns the library while it runs: `busy`; and an update cannot start while this build runs
        let token = libreg::entry_for(&lib_path).begin_build()?;
        if let Some(root) = root {
            // a snapshot build: the library's source id is what cs_status reports ("library_id@version")
            let (library_id, version) = match p.settings.as_ref().map(LibrarySettings::parse).transpose()? {
                Some(st) => (st.library_id, st.version),
                None => (crate::library::dir_name(&lib_path), None),
            };
            let source_id = idxsnap::library_source_id(&library_id, version.as_deref());
            let sd = idxsnap::dir_for(&root, idxsnap::KIND_LIBRARY, &source_id);
            let lock = Lock::acquire(&crate::snapshot::build_dir(&sd))?;
            let (heap_mb, checkpoint, settings) = (p.heap_mb, p.checkpoint_docs, p.settings);
            return Self::spawn("cs-index-library", (lock, token), 0, move |sh| {
                idxsnap::run_library(
                    &LibBuildParams {
                        library_path: &lib_path,
                        settings: settings.as_ref(),
                        index_dir: &sd,
                        heap_mb,
                        checkpoint_docs: checkpoint,
                        threads: None,
                        pace: None,
                    },
                    &sd,
                    &source_id,
                    &library_id,
                    version.as_deref(),
                    &Self::hooks(sh),
                )
            });
        }
        let dir = PathBuf::from(&p.index_dir);
        let lock = Lock::acquire(&dir)?;
        let (heap_mb, checkpoint, settings) = (p.heap_mb, p.checkpoint_docs, p.settings);
        Self::spawn("cs-index-library", (lock, token), 0, move |sh| {
            libindex::build_library_index(
                &LibBuildParams {
                    library_path: &lib_path,
                    settings: settings.as_ref(),
                    index_dir: &dir,
                    heap_mb,
                    checkpoint_docs: checkpoint,
                    threads: sh.throttle.threads(),
                    pace: Some(&|| sh.pace()),
                },
                &|d, t| sh.set_progress(d, t),
                &|| sh.cancel.load(Ordering::SeqCst),
            )
        })
    }

    /// Start an `index_extend` job: `{"library_path","indexes_dir","index_dir"?,"settings"?,"heap_mb"?}` (as `index_library` with an
    /// indexes folder). Brings the library's newest keyword snapshot up to date with its shard as the next generation of the same
    /// source: the old files hard-linked plus one new segment of the missing points (idxsnap::extend_library). `busy` while another
    /// job builds the source or the library is being updated.
    fn start_index_extend(params_json: &str) -> Result<Job> {
        let p: IndexLibraryParams = serde_json::from_str(params_json)?;
        let Some(root) = p.indexes_dir.as_deref().filter(|d| !d.is_empty()).map(PathBuf::from) else {
            return Err(Error::bad_json("indexes_dir must not be empty"));
        };
        if p.library_path.is_empty() {
            return Err(Error::bad_json("library_path must not be empty"));
        }
        if let Some(s) = &p.settings {
            LibrarySettings::parse(s)?;
        }
        let lib_path = PathBuf::from(&p.library_path);
        if !lib_path.is_dir() {
            return Err(Error::not_found(format!("library folder {} not found", lib_path.display())));
        }
        let token = libreg::entry_for(&lib_path).begin_build()?;
        let (library_id, version) = match p.settings.as_ref().map(LibrarySettings::parse).transpose()? {
            Some(st) => (st.library_id, st.version),
            None => (crate::library::dir_name(&lib_path), None),
        };
        let source_id = idxsnap::library_source_id(&library_id, version.as_deref());
        let legacy = (!p.index_dir.is_empty()).then_some(PathBuf::from(&p.index_dir)).or_else(|| idxsnap::legacy_for(&root, &source_id));
        let root = idxsnap::snap_root(&root, idxsnap::KIND_LIBRARY, &source_id, legacy.as_deref());
        let sd = idxsnap::dir_for(&root, idxsnap::KIND_LIBRARY, &source_id);
        let lock = Lock::acquire(&crate::snapshot::build_dir(&sd))?;
        let (heap_mb, checkpoint, settings) = (p.heap_mb, p.checkpoint_docs, p.settings);
        Self::spawn("cs-index-extend", (lock, token), 0, move |sh| {
            idxsnap::extend_library(
                &idxsnap::ExtendRequest {
                    library_path: &lib_path,
                    settings: settings.as_ref(),
                    sd: &sd,
                    source_id: &source_id,
                    library_id: &library_id,
                    version: version.as_deref(),
                    heap_mb,
                    checkpoint_docs: checkpoint,
                },
                &Self::hooks(sh),
            )
        })
    }

    /// Start an `update_library` job. Parameter errors, a snapshot manifest that does not describe the library
    /// and a library that is busy (another update, or an index build) are reported here and no job exists. The
    /// library is marked as updating before this returns, so a search or `cs_status` right after sees it.
    fn start_update_library(params_json: &str) -> Result<Job> {
        let p: UpdateLibraryParams = serde_json::from_str(params_json)?;
        // a crash can have left a staging folder or the old library beside it: put that right first
        // (the library is marked as updating meanwhile, so nothing in this process opens it)
        libupdate::recover_if_leftovers(std::path::Path::new(&p.library_path))?;
        let hooks = libupdate::TestHooks {
            hold_ms: p.hold_ms,
            hold_swap_file: p.hold_swap_file,
            fake_available_bytes: p.fake_available_bytes,
            fail_at: p.fail_at,
        };
        let req = libupdate::prepare(&p.library_path, &p.snapshot_path, &p.snapshot_manifest_path, hooks)?;
        let entry = libreg::entry_for(&req.library);
        let guard = entry.begin_update()?;
        Self::spawn("cs-update-library", guard, libupdate::STEPS, move |sh| {
            libupdate::apply_update(
                &req,
                &entry,
                &|d, t| sh.set_progress(d, t),
                // cancelling is honoured only before the apply step; `apply_update` asks at the right places
                &|| sh.cancel.load(Ordering::SeqCst),
            )
        })
    }

    /// Start a `layer_download` job: parameters are `{"layers": <the cs_open layers config>, "layer", "area"?, "name"?,
    /// "bbox"|"polygon", "minzoom"?, "maxzoom"?, "update"?}`. A layer that does not exist, one that is online only
    /// and a bad area are reported here and no job exists; limits, free space and network errors make the job `failed`.
    fn start_layer_download(params_json: &str) -> Result<Job> {
        #[derive(Deserialize)]
        struct P {
            layers: cache_layers::LayersCfg,
            #[serde(flatten)]
            req: cache_layers::AreaReq,
        }
        let p: P = serde_json::from_str(params_json)?;
        let conv = |e: cache_layers::Error| {
            let mut r = Error::new(crate::ErrorCode::from_str_code(e.code), e.message);
            r.space = e.space;
            r
        };
        let inner = std::sync::Arc::new(cache_layers::Inner::open(p.layers).map_err(conv)?);
        let base = inner.base_of(&p.req.layer).map_err(conv)?;
        if !base.offline_allowed() {
            return Err(conv(cache_layers::Error::offline(format!("{} cannot be downloaded: it needs a connection", base.title))));
        }
        // An update (or a resume) names the area and no shape: the shape is the stored area's. Checked on the request as asked,
        // every update failed here with "a download needs bbox or polygon" (1.0.27: Update on a region).
        let req = inner.resolve_request(&p.req).map_err(conv)?;
        req.bounds().map_err(conv)?;
        let key = format!("{}/{}", base.id, req.area_id().map_err(conv)?);
        let guard = ActiveDownload::acquire(&key)?;
        Self::spawn("cs-layer-download", guard, 0, move |sh| {
            let r = inner.run_download(
                &req,
                &|d, t, detail| {
                    sh.set_progress(d, t);
                    if let Ok(mut g) = sh.detail.lock() {
                        *g = Some(detail);
                    }
                },
                &|| sh.cancel.load(Ordering::SeqCst),
            );
            match r {
                Ok(cache_layers::Done::Finished) => Ok(Outcome::Done),
                Ok(cache_layers::Done::Cancelled) => Ok(Outcome::Cancelled),
                Err(e) => Err(conv(e)),
            }
        })
    }

    /// Start a `library_manifest` job. Parameter errors and a library that is busy (an update, another manifest
    /// job, or an index build) are reported here and no job exists. The library is marked as updating before this
    /// returns, like `update_library`.
    fn start_library_manifest(params_json: &str) -> Result<Job> {
        let p: LibraryManifestParams = serde_json::from_str(params_json)?;
        let req = libupdate::prepare_manifest(&p.library_path, &p.out_path, p.hold_ms)?;
        let entry = libreg::entry_for(&req.library);
        let guard = entry.begin_update()?;
        Self::spawn("cs-library-manifest", guard, libupdate::MANIFEST_STEPS, move |sh| {
            libupdate::apply_manifest(
                &req,
                &entry,
                &|d, t| sh.set_progress(d, t),
                // cancelling is honoured only before the read-write load; `apply_manifest` asks at the right places
                &|| sh.cancel.load(Ordering::SeqCst),
            )
        })
    }

    /// Start an `unpack_library` job (libadd.rs). Parameter errors, a file that is not a tar archive and too little
    /// free space are reported here and no job exists.
    fn start_unpack_library(params_json: &str) -> Result<Job> {
        let p: UnpackLibraryParams = serde_json::from_str(params_json)?;
        let req = libadd::prepare_unpack(&p.snapshot_path, &p.dir, p.settings, p.fake_available_bytes)?;
        Self::spawn("cs-unpack-library", (), req.size, move |sh| {
            libadd::run_unpack(
                &req,
                &|d, t| sh.set_progress(d, t),
                &|v| {
                    if let Ok(mut g) = sh.detail.lock() {
                        *g = Some(v);
                    }
                },
                &|| sh.cancel.load(Ordering::SeqCst),
            )
        })
    }

    /// Start a `check_library` job: open the unpacked library once and report what `unpack_library` reports.
    fn start_check_library(params_json: &str) -> Result<Job> {
        let p: CheckLibraryParams = serde_json::from_str(params_json)?;
        if p.library_path.is_empty() {
            return Err(Error::bad_json("library_path must not be empty"));
        }
        if let Some(s) = &p.settings {
            LibrarySettings::parse(s)?;
        }
        let lib = PathBuf::from(&p.library_path);
        if !lib.is_dir() {
            return Err(Error::not_found(format!("library folder {} not found", lib.display())));
        }
        let settings = p.settings;
        Self::spawn("cs-check-library", (), 1, move |sh| {
            let d = libadd::check_library(&lib, settings.as_ref())?;
            if let Ok(mut g) = sh.detail.lock() {
                *g = Some(d);
            }
            sh.set_progress(1, 1);
            Ok(Outcome::Done)
        })
    }

    /// Start a `library_template` job: write the blank library template to `out_path`.
    fn start_library_template(params_json: &str) -> Result<Job> {
        let p: LibraryTemplateParams = serde_json::from_str(params_json)?;
        if p.out_path.is_empty() {
            return Err(Error::bad_json("out_path must not be empty"));
        }
        let out = PathBuf::from(&p.out_path);
        Self::spawn("cs-library-template", (), libadd::TEMPLATE_STEPS, move |sh| {
            libadd::write_template(&out, &|d, t| sh.set_progress(d, t))
        })
    }

    /// Start a `video_download` job. Parameter errors and an unknown instance are reported here and no job exists; the
    /// network work (details, free-space check, the file) runs on the job's thread. Progress is bytes of the video file.
    fn start_video_download(params_json: &str) -> Result<Job> {
        let prepared = cache_video::dl::prepare(params_json).map_err(crate::ext::video_err)?;
        Self::spawn("cs-video-download", (), 0, move |sh| {
            match prepared.run(&|d, t| sh.set_progress(d, t), &|| sh.cancel.load(Ordering::SeqCst)).map_err(crate::ext::video_err)? {
                cache_video::Outcome::Done => Ok(Outcome::Done),
                cache_video::Outcome::Cancelled => Ok(Outcome::Cancelled),
            }
        })
    }

    /// Run `work` on a new thread holding `guard` (a build lock, an update mark, ...); the job's state follows
    /// its result.
    fn spawn<G: Send + 'static>(
        name: &str,
        guard: G,
        total: u64,
        work: impl FnOnce(&Shared) -> Result<Outcome> + Send + 'static,
    ) -> Result<Job> {
        let pending = PENDING_DUTY.with(|c| c.get());
        let shared = Arc::new(Shared {
            cancel: AtomicBool::new(false),
            done: AtomicU64::new(0),
            total: AtomicU64::new(total),
            state: Mutex::new((State::Running, None)),
            detail: Mutex::new(None),
            phase: Mutex::new(None),
            phases: Mutex::new(Vec::new()),
            result: Mutex::new(None),
            throttle: Throttle::new(pending.0),
            pace_on_progress: pending.1,
        });
        let sh = shared.clone();
        let th = std::thread::Builder::new()
            .name(name.into())
            .spawn(move || {
                duty::lower_thread_priority();
                let guard = guard;
                let r = catch_unwind(AssertUnwindSafe(|| work(&sh)));
                let st = match r {
                    Ok(Ok(Outcome::Done)) => (State::Done, None),
                    Ok(Ok(Outcome::Cancelled)) => (State::Cancelled, None),
                    Ok(Err(e)) => (State::Failed, Some(e)),
                    Err(p) => {
                        let msg = p
                            .downcast_ref::<&str>()
                            .map(|s| s.to_string())
                            .or_else(|| p.downcast_ref::<String>().cloned())
                            .unwrap_or_else(|| "panic".into());
                        (State::Failed, Some(Error::internal(format!("panic: {msg}"))))
                    }
                };
                // release the build lock (or the update mark) before the state flips, so a poller that sees a
                // finished job also sees the source as no longer building or updating
                drop(guard);
                if let Ok(mut g) = sh.state.lock() {
                    *g = st;
                }
            })
            .map_err(|e| Error::internal(format!("cannot start thread: {e}")))?;
        Ok(Job { shared, thread: Some(th) })
    }

    pub fn progress_json(&self) -> String {
        let (st, err) = self.shared.state.lock().map(|g| g.clone()).unwrap_or((State::Failed, Some(Error::internal("poisoned"))));
        let err_v = match &err {
            Some(e) => e.to_value(),
            None => serde_json::Value::Null,
        };
        let mut v = json!({
            "state": st.as_str(),
            "done": self.shared.done.load(Ordering::SeqCst),
            "total": self.shared.total.load(Ordering::SeqCst),
            "error": err_v,
        });
        if let Some(d) = self.shared.detail.lock().ok().and_then(|g| g.clone()) {
            v["detail"] = d;
        }
        if let Some(p) = self.shared.phase.lock().ok().and_then(|g| g.clone()) {
            v["phase"] = json!(p);
        }
        if let Some(ps) = self.shared.phases.lock().ok().filter(|g| !g.is_empty()).map(|g| g.clone()) {
            v["phases"] = json!(ps);
        }
        if let Some(r) = self.shared.result.lock().ok().and_then(|g| g.clone()) {
            v["result"] = r;
        }
        let t = self.shared.throttle.state_json();
        v["duty"] = t["duty"].clone();
        v["effective"] = t["effective"].clone();
        v["auto"] = t["auto"].clone();
        v["paused"] = t["paused"].clone();
        v.to_string()
    }

    pub fn cancel(&self) {
        self.shared.cancel.store(true, Ordering::SeqCst);
        self.shared.throttle.wake();
    }

    /// `cs_job_set`: change the running job's duty, pause or resume it (see duty.rs); returns its state.
    pub fn set_duty(&self, json: &str) -> Result<String> {
        let v: Value = serde_json::from_str(json)?;
        Ok(self.shared.throttle.set(&v)?.to_string())
    }
}

impl Drop for Job {
    /// Freeing a running job cancels it and waits for its next checkpoint.
    fn drop(&mut self) {
        self.shared.cancel.store(true, Ordering::SeqCst);
        self.shared.throttle.wake();
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

