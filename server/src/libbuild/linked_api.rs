//! Authenticated local administration for linked-folder identity adoption and checks.
use super::{
    linked_checks::{self, CheckJob, Counts, JobFile, Scope},
    linked_registry::{BrowseMode, LinkedRegistry, ScanReport},
    BuildService,
};
use crate::library::ApiErr;
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::{HashMap, HashSet},
    io,
    path::{Component, Path, PathBuf},
    sync::{
        atomic::{AtomicU64, Ordering},
        mpsc::{self, Sender},
        Arc, Mutex, OnceLock,
    },
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

type CheckResult = Result<Value, String>;
type RuntimeMap = Mutex<HashMap<PathBuf, Arc<Mutex<JobFile>>>>;
type OperationMap = Mutex<HashMap<PathBuf, Arc<Mutex<()>>>>;

static RUNTIMES: OnceLock<RuntimeMap> = OnceLock::new();
static OPS: OnceLock<OperationMap> = OnceLock::new();
static JOB_SEQUENCE: AtomicU64 = AtomicU64::new(0);

fn error(status: u16, message: impl Into<String>) -> ApiErr {
    ApiErr { status, code: "linked_folder", message: message.into() }
}

fn issue_code(e: &io::Error) -> &'static str {
    match e.kind() {
        io::ErrorKind::NotFound => "not_found",
        io::ErrorKind::PermissionDenied => "permission_denied",
        io::ErrorKind::InvalidInput => "invalid_path",
        io::ErrorKind::InvalidData => "invalid_state",
        io::ErrorKind::WouldBlock => "busy",
        _ => "io_error",
    }
}

fn io_error(e: io::Error) -> ApiErr {
    let status = match e.kind() {
        io::ErrorKind::InvalidInput | io::ErrorKind::InvalidData => 400,
        io::ErrorKind::NotFound => 404,
        io::ErrorKind::PermissionDenied => 403,
        _ => 500,
    };
    error(status, format!("{}: {}", issue_code(&e), e))
}

fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 80
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn valid_rel(path: &Path) -> bool {
    !path.as_os_str().is_empty()
        && path.components().all(|component| matches!(component, Component::Normal(_)))
}

pub(super) fn library_path(data: &Path, id: &str) -> Result<PathBuf, ApiErr> {
    if !valid_id(id) {
        return Err(error(400, "invalid library id"));
    }
    let parent = data.join("app/docs/libraries").canonicalize().map_err(io_error)?;
    let path = parent.join(id);
    if std::fs::symlink_metadata(&path).map_err(io_error)?.file_type().is_symlink() {
        return Err(error(400, "linked-folder target cannot be a symbolic link"));
    }
    let path = path.canonicalize().map_err(io_error)?;
    if path.parent() != Some(parent.as_path()) || !path.join("cache-library.json").is_file() {
        return Err(error(404, "no installed library with that id"));
    }
    Ok(path)
}

fn now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_millis() as u64
}

pub(super) fn runtime(sidecar: &Path) -> Arc<Mutex<JobFile>> {
    let mut runtimes = RUNTIMES.get_or_init(|| Mutex::new(HashMap::new()))
        .lock().unwrap_or_else(|e| e.into_inner());
    runtimes.entry(sidecar.to_path_buf()).or_insert_with(|| {
        let path = sidecar.join("linked-check-jobs.json");
        let mut file = match linked_checks::load(&path) {
            Ok(file) => file,
            Err(e) => JobFile {
                state_error: Some(json!({"code": "invalid_state", "message": e.to_string()})),
                ..JobFile::default()
            },
        };
        if linked_checks::recover_interrupted(&mut file, now()) {
            if let Err(e) = linked_checks::save(&path, &file) {
                file.state_error = Some(json!({"code": "io_error", "message": e.to_string()}));
            }
        }
        Arc::new(Mutex::new(file))
    }).clone()
}

fn op_lock(path: &Path) -> Arc<Mutex<()>> {
    let mut operations = OPS.get_or_init(|| Mutex::new(HashMap::new()))
        .lock().unwrap_or_else(|e| e.into_inner());
    operations.entry(path.to_path_buf()).or_insert_with(|| Arc::new(Mutex::new(()))).clone()
}

fn healthy(file: &JobFile) -> Result<(), ApiErr> {
    if let Some(issue) = &file.state_error {
        return Err(error(500, issue["message"].as_str().unwrap_or("linked-folder job state is corrupt")));
    }
    Ok(())
}

fn persist(sidecar: &Path, file: &JobFile) -> io::Result<()> {
    if file.state_error.is_some() {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "linked check state is corrupt"));
    }
    linked_checks::save(&sidecar.join("linked-check-jobs.json"), file)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Register {
    id: String,
    label: String,
    #[serde(default)]
    mode: BrowseMode,
    root: PathBuf,
    #[serde(default)]
    exclusions: Vec<PathBuf>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Preview {
    root: PathBuf,
    #[serde(default)]
    exclusions: Vec<PathBuf>,
}

#[derive(Deserialize, Default)]
#[serde(deny_unknown_fields)]
struct Start {
    #[serde(default)]
    root_id: Option<String>,
}

pub(super) fn is_active(path: &Path) -> bool {
    runtime(&path.join(".local")).lock().unwrap_or_else(|e| e.into_inner()).active.is_some()
}

fn set_controls(path: &Path, id: &str, paused: bool) -> Result<(), ApiErr> {
    let sidecar = path.join(".local");
    let rt = runtime(&sidecar);
    let operation = op_lock(path);
    match operation.try_lock() {
        Ok(_guard) => {
            let mut registry = LinkedRegistry::open(&sidecar, path).map_err(io_error)?;
            let mut state = rt.lock().unwrap_or_else(|e| e.into_inner());
            healthy(&state)?;
            state.registered_roots = registry.local_config().roots.iter()
                .map(|root| root.id.clone()).collect();
            if !linked_checks::update_control(&mut state, id, paused) {
                return Err(error(404, "linked folder not found"));
            }
            persist(&sidecar, &state).map_err(io_error)?;
            // A queued worker owns a frozen registry snapshot. Save future controls
            // without changing that snapshot or canceling its check.
            if state.active.is_none() {
                registry.reconcile_controls(&state.controls).map_err(io_error)?;
            }
        }
        Err(_) => {
            let mut state = rt.lock().unwrap_or_else(|e| e.into_inner());
            healthy(&state)?;
            if state.active.is_none() {
                return Err(error(409, "linked-folder configuration is busy"));
            }
            if !linked_checks::update_control_during_active(&mut state, id, paused) {
                return Err(error(404, "linked folder not found"));
            }
            persist(&sidecar, &state).map_err(io_error)?;
        }
    }
    Ok(())
}

fn attached(file: &JobFile, scope: &Scope, synchronous: bool) -> Result<Option<CheckJob>, ApiErr> {
    healthy(file)?;
    match linked_checks::attach_or_conflict(file, scope) {
        Ok(Some(_)) if synchronous => Err(error(409, "linked-folder check active; use checks status")),
        Ok(job) => Ok(job),
        Err(_) => Err(error(409, "another linked-folder check is already active for this library")),
    }
}

fn start(
    service: &Arc<BuildService>,
    path: &Path,
    root_id: Option<String>,
    legacy: Option<Sender<CheckResult>>,
) -> Result<CheckJob, ApiErr> {
    start_with(service, path, root_id, legacy, None)
}

/// Start (or attach to) a check. `auto_settle_ms` is `Some` for an automatic check: the settle rule is
/// that delay, and the check never sleeps inside the job (the scheduler comes back after the delay).
pub(super) fn start_with(
    service: &Arc<BuildService>,
    path: &Path,
    root_id: Option<String>,
    legacy: Option<Sender<CheckResult>>,
    auto_settle_ms: Option<u64>,
) -> Result<CheckJob, ApiErr> {
    let sidecar = path.join(".local");
    let rt = runtime(&sidecar);
    let scope = Scope { root_id: root_id.clone() };
    if let Some(job) = attached(&rt.lock().unwrap_or_else(|e| e.into_inner()), &scope, legacy.is_some())? {
        return Ok(job);
    }
    let operation = op_lock(path);
    let guard = match operation.try_lock() {
        Ok(guard) => guard,
        Err(_) => {
            // Another request may have reserved the same scope after our first check.
            if let Some(job) = attached(&rt.lock().unwrap_or_else(|e| e.into_inner()), &scope, legacy.is_some())? {
                return Ok(job);
            }
            return Err(error(409, "linked-folder configuration is busy"));
        }
    };
    let mut state = rt.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(job) = attached(&state, &scope, legacy.is_some())? {
        return Ok(job);
    }
    let mut registry = LinkedRegistry::open(&sidecar, path).map_err(io_error)?;
    if registry.local_config().roots.is_empty() {
        return Err(error(409, "no linked folders are registered"));
    }
    if let Some(id) = &root_id {
        if !registry.local_config().roots.iter().any(|root| &root.id == id) {
            return Err(error(404, "linked folder not found"));
        }
    }
    state.registered_roots = registry.local_config().roots.iter().map(|root| root.id.clone()).collect();
    let registered = state.registered_roots.clone();
    state.controls.retain(|id, _| registered.contains(id));
    for root in &registry.local_config().roots {
        state.controls.entry(root.id.clone()).or_insert(root.paused);
    }
    registry.reconcile_controls(&state.controls).map_err(io_error)?;
    let timestamp = now();
    let job = CheckJob {
        job_id: format!("lf-{timestamp}-{}-{}", std::process::id(), JOB_SEQUENCE.fetch_add(1, Ordering::Relaxed)),
        state: "queued".into(),
        stage: Some("checking".into()),
        scope,
        started_at: timestamp,
        finished_at: None,
        last_attempt_at: timestamp,
        last_successful_at: state.latest.as_ref().and_then(|job| job.last_successful_at),
        paused_for_future: future_pause(&state, root_id.as_deref()),
        counts: Counts::default(),
        roots: vec![],
        error: None,
    };
    state.active = Some(job.clone());
    if let Err(e) = persist(&sidecar, &state) {
        state.active = None;
        return Err(io_error(e));
    }
    // Freeze this job's roots and pause settings before releasing the operation lock.
    // Controls written after reservation are durable, but must not cancel this job.
    drop(state);
    drop(guard);
    let worker_path = path.to_path_buf();
    let worker_rt = rt.clone();
    let worker_service = service.clone();
    if let Err(e) = thread::Builder::new().name("linked-folder-check".into())
        .spawn(move || run_check(worker_path, worker_rt, root_id, registry, legacy, auto_settle_ms, worker_service))
    {
        finish_error(&sidecar, &rt, &e);
        return Err(error(500, "could not start linked-folder check"));
    }
    Ok(job)
}

fn future_pause(state: &JobFile, root_id: Option<&str>) -> bool {
    root_id.map(|id| state.controls.get(id).copied().unwrap_or(false))
        .unwrap_or_else(|| state.controls.values().any(|paused| *paused))
}

#[derive(Default)]
struct ProgressState {
    last_checkpoint: u64,
    last_saved: u64,
    checkpoint_seen: HashMap<String, usize>,
    saved_seen: usize,
}

type ProgressBase = HashMap<String, (usize, usize, u64)>;

fn scan_pass(
    registry: &mut LinkedRegistry,
    root_id: Option<&str>,
    rt: &Arc<Mutex<JobFile>>,
    sidecar: &Path,
    progress: &mut ProgressState,
    bases: &ProgressBase,
    settle_ms: u64,
) -> io::Result<ScanReport> {
    let registry_file = sidecar.join("linked-registry.json");
    let mut checkpoint_error = None;
    let report = registry.scan_scoped_progress(root_id, settle_ms, |root, seen, hashed, bytes, settling, observed| {
        let clock = now();
        let (seen_base, hash_base, byte_base) = bases.get(root).copied().unwrap_or_default();
        let mut file = rt.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(job) = file.active.as_mut() {
            job.stage = Some("checking".into());
            let row = json!({
                "root_id": root,
                "files_seen": seen_base.max(seen),
                "files_hashed": hash_base.saturating_add(hashed),
                "bytes_hashed": byte_base.saturating_add(bytes),
                "settling_file_count": settling,
                "complete": false
            });
            if let Some(old) = job.roots.iter_mut().find(|row| row["root_id"].as_str() == Some(root)) {
                *old = row;
            } else {
                job.roots.push(row);
            }
            let seen_total: usize = job.roots.iter().map(|row| count(row, "files_seen")).sum();
            job.counts.files_seen = Some(seen_total);
            job.counts.files_hashed = Some(job.roots.iter().map(|row| count(row, "files_hashed")).sum());
            job.counts.bytes_hashed = Some(job.roots.iter().map(|row| row["bytes_hashed"].as_u64().unwrap_or(0)).sum());
            job.counts.settling_file_count = Some(job.roots.iter().map(|row| count(row, "settling_file_count")).sum());
            if seen_total.saturating_sub(progress.saved_seen) >= 32
                || clock.saturating_sub(progress.last_saved) >= 1_000
            {
                match persist(sidecar, &file) {
                    Ok(()) => {
                        progress.saved_seen = seen_total;
                        progress.last_saved = clock;
                    }
                    Err(e) => { checkpoint_error.get_or_insert(e); }
                }
            }
        }
        drop(file);
        let completed_files = observed.len();
        let last_seen = progress.checkpoint_seen.get(root).copied().unwrap_or(0);
        if completed_files.saturating_sub(last_seen) >= 32 || clock.saturating_sub(progress.last_checkpoint) >= 1_000 {
            match super::linked_registry::checkpoint_state(&registry_file, root, observed) {
                Ok(()) => {
                    progress.checkpoint_seen.insert(root.to_string(), completed_files);
                    progress.last_checkpoint = clock;
                }
                Err(e) => { checkpoint_error.get_or_insert(e); }
            }
        }
    });
    if let Some(e) = checkpoint_error {
        return Err(e);
    }
    report
}

fn count(row: &Value, key: &str) -> usize {
    row[key].as_u64().unwrap_or(0) as usize
}

fn progress_bases(job: &CheckJob) -> ProgressBase {
    job.roots.iter().filter_map(|row| Some((
        row["root_id"].as_str()?.to_string(),
        (count(row, "files_seen"), count(row, "files_hashed"), row["bytes_hashed"].as_u64()?),
    ))).collect()
}

fn make_root_reports(registry: &LinkedRegistry, report: &ScanReport, settle_ms: u64) -> Vec<Value> {
    report.roots.iter().map(|root| {
        let books: Vec<_> = report.books.iter().filter(|book| book.locations.iter()
            .any(|location| location.root_id == root.root_id && location.available)).collect();
        let unique: HashSet<_> = books.iter().filter_map(|book| book.doc_id.as_deref()).collect();
        let locations: usize = books.iter().filter(|book| book.doc_id.is_some()).map(|book|
            book.locations.iter().filter(|location| location.root_id == root.root_id && location.available).count()
        ).sum();
        let settling = registry.local_config().roots.iter().find(|config| config.id == root.root_id)
            .map(|config| config.state.values().filter(|state|
                state.blake3.is_none() && now().saturating_sub(state.first_observed_ms) < settle_ms
            ).count()).unwrap_or(0);
        json!({
            "root_id": root.root_id,
            "paused": root.paused,
            "unavailable": root.unavailable,
            "complete": root.complete,
            "candidates": root.candidates,
            "pending": root.pending,
            "matched_unique_ids": unique.len(),
            "matched_locations": locations,
            "unmatched_identity": books.iter().filter(|book| book.doc_id.is_none()).count(),
            "settling_file_count": settling,
            "errors": root.issues
        })
    }).collect()
}

fn run_check(
    path: PathBuf,
    rt: Arc<Mutex<JobFile>>,
    root_id: Option<String>,
    mut registry: LinkedRegistry,
    legacy: Option<Sender<CheckResult>>,
    auto_settle_ms: Option<u64>,
    service: Arc<BuildService>,
) {
    let sidecar = path.join(".local");
    let library = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let result = {
        let operation = op_lock(&path);
        let _guard = operation.lock().unwrap_or_else(|e| e.into_inner());
        let result = run_check_locked(&sidecar, &rt, root_id.as_deref(), &mut registry, auto_settle_ms, &service, &library);
        if let Err(e) = &result {
            finish_error(&sidecar, &rt, e);
        }
        result
    };
    // The sender belongs exclusively to this worker. Later checks cannot replace its
    // result, and receiving it also guarantees the operation lock has been released.
    if let Some(sender) = legacy {
        let _ = sender.send(result.map_err(|e| e.to_string()));
    }
}

fn run_check_locked(
    sidecar: &Path,
    rt: &Arc<Mutex<JobFile>>,
    root_id: Option<&str>,
    registry: &mut LinkedRegistry,
    auto_settle_ms: Option<u64>,
    service: &BuildService,
    library: &str,
) -> io::Result<Value> {
    let settle_ms = auto_settle_ms.unwrap_or(2_000);
    // A library Cache builds is matched against its own books (the builder keeps no `documents.tsv`), and files whose hash it
    // does not hold are queued below. An imported library keeps matching against its catalogue and queues nothing.
    let built = service.linked_catalog(library).is_some();
    let refresh_books = |registry: &mut LinkedRegistry| {
        if let Some(books) = service.linked_catalog(library) {
            registry.use_builder_books(books);
        }
    };
    refresh_books(&mut *registry);
    {
        let mut state = rt.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(job) = state.active.as_mut() {
            job.state = "running".into();
            job.stage = Some("checking".into());
        }
        persist(sidecar, &state)?;
    }
    let timestamp = now();
    let mut progress = ProgressState { last_checkpoint: timestamp, last_saved: timestamp, ..ProgressState::default() };
    let mut report = scan_pass(registry, root_id, rt, sidecar, &mut progress, &ProgressBase::new(), settle_ms)?;
    // Newly observed files need two unchanged seconds before they can be hashed. A manual check waits
    // here; an automatic check never holds the job for its (longer) settle delay, the scheduler comes back.
    if auto_settle_ms.is_none() && report.roots.iter().any(|root| root.complete && root.errors.is_empty() && root.pending > 0) {
        thread::sleep(Duration::from_millis(2_100));
        let bases = rt.lock().unwrap_or_else(|e| e.into_inner()).active.as_ref()
            .map(progress_bases).unwrap_or_default();
        progress.checkpoint_seen.clear();
        refresh_books(&mut *registry);
        report = scan_pass(registry, root_id, rt, sidecar, &mut progress, &bases, settle_ms)?;
    }
    let mut state = rt.lock().unwrap_or_else(|e| e.into_inner());
    // Apply every future control, including controls for roots outside this job's scope.
    registry.reconcile_controls(&state.controls)?;
    let roots = make_root_reports(registry, &report, settle_ms);
    let scanned: HashSet<_> = report.roots.iter().filter(|root| !root.paused)
        .map(|root| root.root_id.as_str()).collect();
    let books: Vec<_> = report.books.iter().filter(|book| book.locations.iter()
        .any(|location| location.available && scanned.contains(location.root_id.as_str()))).collect();
    if built {
        // Match first (a book the library holds is only relinked, above); only a hash the library does not hold is queued, once,
        // and built in place by the ordinary queue. The builder drops a file that is no longer the one that was checked.
        for book in books.iter().filter(|book| book.doc_id.is_none()) {
            let place = book.locations.iter().find(|l| l.available && scanned.contains(l.root_id.as_str()));
            let root = place.and_then(|l| registry.local_config().roots.iter().find(|r| r.id == l.root_id));
            if let (Some(l), Some(root)) = (place, root) {
                service.enqueue_linked(library, &root.path, &l.relative_path, &book.blake3);
            }
        }
    }
    let ids: HashSet<_> = books.iter().filter_map(|book| book.doc_id.as_deref()).collect();
    let locations = books.iter().filter(|book| book.doc_id.is_some()).map(|book|
        book.locations.iter().filter(|location| location.available && scanned.contains(location.root_id.as_str())).count()
    ).sum();
    let successful = !scanned.is_empty() && report.roots.iter().filter(|root| !root.paused)
        .all(|root| root.complete && !root.unavailable && root.issues.is_empty() && root.pending == 0);
    let mut completed = state.clone();
    if let Some(mut job) = completed.active.take() {
        job.state = "done".into();
        job.stage = None;
        job.finished_at = Some(now());
        if successful {
            job.last_successful_at = job.finished_at;
        }
        let covered: Vec<(String, bool)> = report.roots.iter().filter(|root| !root.paused).map(|root| (
            root.root_id.clone(),
            root.complete && !root.unavailable && root.issues.is_empty() && root.pending == 0,
        )).collect();
        linked_checks::record_folder_checks(&mut completed, &covered, job.finished_at.unwrap_or_else(now));
        job.counts.roots_seen = Some(report.roots.len());
        job.counts.files_seen = Some(job.counts.files_seen.unwrap_or(0));
        job.counts.files_hashed = Some(job.counts.files_hashed.unwrap_or(0));
        job.counts.bytes_hashed = Some(job.counts.bytes_hashed.unwrap_or(0));
        job.counts.matched_unique_ids = Some(ids.len());
        job.counts.matched_locations = Some(locations);
        job.counts.unmatched_identity = Some(books.iter().filter(|book| book.doc_id.is_none()).count());
        job.counts.settling_file_count = Some(roots.iter().map(|root| count(root, "settling_file_count")).sum());
        job.counts.errors = Some(report.roots.iter().map(|root| root.issues.len()).sum());
        job.paused_for_future = future_pause(&state, root_id);
        job.roots = roots;
        completed.latest = Some(job);
    }
    persist(sidecar, &completed)?;
    *state = completed;
    // Async checks retain only compact status. A synchronous caller owns its report.
    serde_json::to_value(report).map_err(io::Error::other)
}

fn finish_error(sidecar: &Path, rt: &Arc<Mutex<JobFile>>, failure: &io::Error) {
    let mut state = rt.lock().unwrap_or_else(|e| e.into_inner());
    if let Some(mut job) = state.active.take() {
        job.state = "failed".into();
        job.stage = None;
        job.finished_at = Some(now());
        // The operating system's own text goes to the log; the browser is given the reason code it already has words for.
        eprintln!("cache: linked-folder check failed: {failure}");
        job.error = Some(json!({"code": issue_code(failure), "message": issue_code(failure)}));
        state.latest = Some(job);
        if let Err(e) = persist(sidecar, &state) {
            state.state_error = Some(json!({"code": "io_error", "message": e.to_string()}));
        }
    }
}

fn job_status(sidecar: &Path) -> Result<Value, ApiErr> {
    let rt = runtime(sidecar);
    let state = rt.lock().unwrap_or_else(|e| e.into_inner());
    healthy(&state)?;
    Ok(json!({"active": state.active, "latest": state.latest, "folders": state.folders}))
}

fn validate_preview(data: &Path, input: Preview) -> Result<(PathBuf, Vec<PathBuf>), ApiErr> {
    if !input.root.is_absolute() {
        return Err(error(400, "root must be an absolute path"));
    }
    if input.exclusions.iter().any(|path| !valid_rel(path)) {
        return Err(error(400, "invalid exclusion path"));
    }
    let root = input.root.canonicalize().map_err(io_error)?;
    if !root.is_dir() {
        return Err(error(400, "source is not a directory"));
    }
    let _ = std::fs::read_dir(&root).map_err(io_error)?;
    let data = data.canonicalize().map_err(io_error)?;
    if root.starts_with(&data) || data.starts_with(&root) {
        return Err(error(400, "linked originals must not overlap Cache managed data"));
    }
    Ok((root, input.exclusions))
}

pub fn preview(service: &BuildService, body: &[u8]) -> Result<Value, ApiErr> {
    let input: Preview = serde_json::from_slice(body).map_err(|e| error(400, e.to_string()))?;
    let (root, exclusions) = validate_preview(&service.data, input)?;
    Ok(json!({"readable": true, "root": root, "exclusions": exclusions, "counts": null, "warnings": []}))
}

pub fn request(
    service: &Arc<BuildService>,
    method: &str,
    library: &str,
    rest: &[String],
    body: &[u8],
) -> Result<Value, ApiErr> {
    let target = library_path(&service.data, library)?;
    let sidecar = target.join(".local");
    match (method, rest) {
        ("GET", []) => {
            let rt = runtime(&sidecar);
            let state = rt.lock().unwrap_or_else(|e| e.into_inner());
            healthy(&state)?;
            let mut config = LinkedRegistry::open(&sidecar, &target).map_err(io_error)?.local_config().clone();
            for root in &mut config.roots {
                if let Some(paused) = state.controls.get(&root.id) {
                    root.paused = *paused;
                }
            }
            Ok(json!({
                "local_config": config,
                "capabilities": {
                    "reuse_existing": true, "index_new_pdfs": service.has_library(library),
                    "automatic_checks": true, "sync_locations": false, "open_original": false
                }
            }))
        }
        ("GET", [action]) if action == "checks" => job_status(&sidecar),
        ("POST", []) => {
            if is_active(&target) {
                return Err(error(409, "linked-folder check active; wait for it to finish"));
            }
            let operation = op_lock(&target);
            let _guard = operation.try_lock().map_err(|_| error(409, "linked-folder configuration is busy"))?;
            let rt = runtime(&sidecar);
            let mut state = rt.lock().unwrap_or_else(|e| e.into_inner());
            healthy(&state)?;
            if state.active.is_some() {
                return Err(error(409, "linked-folder check active; wait for it to finish"));
            }
            let input: Register = serde_json::from_slice(body).map_err(|e| error(400, e.to_string()))?;
            if input.label.trim().is_empty() || input.label.len() > 200 {
                return Err(error(400, "folder label must contain 1 to 200 bytes"));
            }
            let (source, exclusions) = validate_preview(&service.data, Preview { root: input.root, exclusions: input.exclusions })?;
            let mut registry = LinkedRegistry::open(&sidecar, &target).map_err(io_error)?;
            registry.register_root(&input.id, input.label, input.mode, &source, exclusions).map_err(io_error)?;
            state.registered_roots = registry.local_config().roots.iter().map(|root| root.id.clone()).collect();
            state.controls.remove(&input.id);
            persist(&sidecar, &state).map_err(io_error)?;
            Ok(json!({"registered": true, "local_config": registry.local_config()}))
        }
        ("POST", [action]) if action == "checks" => {
            let input: Start = serde_json::from_slice(body).map_err(|e| error(400, e.to_string()))?;
            let job = start(service, &target, input.root_id, None)?;
            Ok(json!({"job_id": job.job_id, "state": job.state, "scope": job.scope}))
        }
        ("POST", [action]) if action == "check" => {
            let (sender, receiver) = mpsc::channel();
            start(service, &target, None, Some(sender))?;
            let report = receive_report(receiver)?;
            Ok(json!({"report": report, "indexing_new_pdfs": service.has_library(library)}))
        }
        ("POST", [id, action]) if action == "pause" || action == "resume" => {
            let paused = action == "pause";
            set_controls(&target, id, paused)?;
            Ok(json!({"paused": paused, "paused_for_future": true, "current_check_finishes": is_active(&target)}))
        }
        ("DELETE", [id]) => {
            if is_active(&target) {
                return Err(error(409, "linked-folder check active; wait for it to finish"));
            }
            let operation = op_lock(&target);
            let _guard = operation.try_lock().map_err(|_| error(409, "linked-folder configuration is busy"))?;
            let rt = runtime(&sidecar);
            let mut state = rt.lock().unwrap_or_else(|e| e.into_inner());
            healthy(&state)?;
            if state.active.is_some() {
                return Err(error(409, "linked-folder check active; wait for it to finish"));
            }
            let mut registry = LinkedRegistry::open(&sidecar, &target).map_err(io_error)?;
            registry.unlink(id).map_err(io_error)?;
            linked_checks::unlink_controls(&mut state, id, registry.local_config().roots.is_empty());
            persist(&sidecar, &state).map_err(io_error)?;
            Ok(json!({"unlinked": true, "indexed_books_retained": true}))
        }
        _ => Err(error(404, "no such linked-folder operation")),
    }
}

fn receive_report(receiver: mpsc::Receiver<CheckResult>) -> Result<Value, ApiErr> {
    receiver.recv().map_err(|_| error(500, "linked-folder check worker stopped before returning its report"))?
        .map_err(|message| error(500, message))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn imported_library_target_needs_no_builder_metadata() {
        let data = crate::TempDir::new("linked-target");
        let library = data.0.join("app/docs/libraries/imported");
        std::fs::create_dir_all(&library).unwrap();
        std::fs::write(library.join("cache-library.json"), b"{}").unwrap();
        assert_eq!(library_path(&data.0, "imported").unwrap(), library.canonicalize().unwrap());
        assert!(library_path(&data.0, "../imported").is_err());
        assert!(!data.0.join("build").exists());
    }

    #[cfg(unix)]
    #[test]
    fn target_symlink_cannot_escape_installed_library() {
        let data = crate::TempDir::new("linked-target-symlink");
        let parent = data.0.join("app/docs/libraries");
        let outside = data.0.join("outside");
        std::fs::create_dir_all(&parent).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        std::fs::write(outside.join("cache-library.json"), b"{}").unwrap();
        std::os::unix::fs::symlink(&outside, parent.join("escape")).unwrap();
        assert!(library_path(&data.0, "escape").is_err());
    }

    #[test]
    fn actual_start_reserves_registered_root_and_unlink_clears_it() {
        let data = crate::TempDir::new("linked-start-roots");
        let config = super::super::BuildConfig {
            settle: Duration::from_millis(1),
            poll: Duration::from_secs(3600),
            publish_every: Duration::from_secs(3600),
            on_rescan: None,
        };
        let (service, _) = crate::libbuild::tests::rig_with(&data, config);
        let target = service.data.join("app/docs/libraries/example");
        std::fs::create_dir_all(&target).unwrap();
        std::fs::write(target.join("cache-library.json"), b"{}").unwrap();
        std::fs::write(target.join("documents.tsv"), "").unwrap();
        let source = data.0.join("source");
        std::fs::create_dir_all(&source).unwrap();
        let target = target.canonicalize().unwrap();
        let sidecar = target.join(".local");
        let mut registry = LinkedRegistry::open(&sidecar, &target).unwrap();
        registry.register_root("root-a", "Folder".into(), BrowseMode::Keep, &source, vec![]).unwrap();
        let (first_sender, first_receiver) = mpsc::channel();
        let first = start(&service, &target, Some("root-a".into()), Some(first_sender)).unwrap();
        assert!(runtime(&sidecar).lock().unwrap().registered_roots.contains("root-a"));
        // Let the first worker complete without consuming its synchronous response.
        let deadline = std::time::Instant::now() + Duration::from_secs(5);
        loop {
            let status = job_status(&sidecar).unwrap();
            if status["latest"]["job_id"].as_str() == Some(first.job_id.as_str()) {
                break;
            }
            assert!(std::time::Instant::now() < deadline, "first check did not finish");
            thread::sleep(Duration::from_millis(5));
        }
        // Status publication precedes the operation-lock release by a few instructions.
        let operation = op_lock(&target);
        drop(operation.lock().unwrap());
        std::fs::write(source.join("new.pdf"), b"second job's PDF").unwrap();
        let (second_sender, second_receiver) = mpsc::channel();
        let second = start(&service, &target, Some("root-a".into()), Some(second_sender)).unwrap();
        assert_ne!(first.job_id, second.job_id);
        let second_report = receive_report(second_receiver).unwrap();
        assert_eq!(second_report["books"].as_array().unwrap().len(), 1);
        let first_report = receive_report(first_receiver).unwrap();
        assert!(first_report["books"].as_array().unwrap().is_empty());
        let completed = job_status(&sidecar).unwrap();
        assert_eq!(completed["latest"]["counts"]["files_seen"], 1);
        assert_eq!(completed["latest"]["counts"]["files_hashed"], 1);
        assert_eq!(completed["latest"]["counts"]["bytes_hashed"], b"second job's PDF".len());
        let successful_at = completed["latest"]["last_successful_at"].clone();
        assert!(successful_at.is_u64());
        // An unavailable root is reported structurally without replacing prior success.
        std::fs::rename(&source, source.with_extension("offline")).unwrap();
        let (third_sender, third_receiver) = mpsc::channel();
        start(&service, &target, Some("root-a".into()), Some(third_sender)).unwrap();
        let offline = receive_report(third_receiver).unwrap();
        assert_eq!(offline["roots"][0]["unavailable"], true);
        let status = job_status(&sidecar).unwrap();
        assert_eq!(status["latest"]["last_successful_at"], successful_at);
        assert_eq!(status["latest"]["roots"][0]["errors"][0]["code"], "not_found");
        request(&service, "DELETE", "example", &["root-a".into()], b"").unwrap();
        let state = runtime(&sidecar);
        let state = state.lock().unwrap();
        assert!(!state.registered_roots.contains("root-a"));
        assert!(!state.controls.contains_key("root-a"));
        assert!(state.latest.is_none());
        let registry = LinkedRegistry::open(&sidecar, &target).unwrap();
        assert_eq!(registry.local_config().books.len(), 1);
        assert!(!registry.local_config().books[0].locations[0].available);
    }

    #[test]
    fn a_disconnected_worker_returns_an_error_instead_of_waiting_for_latest() {
        let (sender, receiver) = mpsc::channel::<CheckResult>();
        drop(sender);
        assert_eq!(receive_report(receiver).unwrap_err().status, 500);
    }

    #[test]
    fn corrupt_outer_job_state_is_an_error_response() {
        let data = crate::TempDir::new("linked-corrupt-jobs");
        std::fs::write(data.0.join("linked-check-jobs.json"), b"{").unwrap();
        assert_eq!(job_status(&data.0).unwrap_err().status, 500);
    }

    #[test]
    fn preview_is_read_only_and_does_not_create_registry_state() {
        let data = crate::TempDir::new("linked-preview");
        let managed = data.0.join("managed");
        std::fs::create_dir_all(&managed).unwrap();
        let root = data.0.join("source");
        std::fs::create_dir_all(&root).unwrap();
        let file = root.join("original.pdf");
        std::fs::write(&file, b"original bytes").unwrap();
        let before = std::fs::read(&file).unwrap();
        let (canonical, exclusions) = validate_preview(&managed, Preview { root: root.clone(), exclusions: vec![] }).unwrap();
        assert_eq!(canonical, root.canonicalize().unwrap());
        assert!(exclusions.is_empty());
        assert!(!root.join(".local").exists());
        assert_eq!(std::fs::read(file).unwrap(), before);
    }
}
