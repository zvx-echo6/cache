//! Libraries on the server: download jobs, uploads from the browser's computer, what is installed, and the catalogue fetch proxy.
//!
//! The server owns every transfer, so a download keeps going with the browser closed.
//!
//! - **Download jobs** (`POST /api/library/download`, `GET /api/library/jobs`, `DELETE /api/library/jobs/{id}`): one at a time, in
//!   the order they were asked for. Each writes `<data>/tmp/dl-<hash of the address>.part` and, after an interruption or a server
//!   restart, continues it with an HTTP Range request. The jobs are kept in `<data>/jobs.json` (written atomically). A finished
//!   file is checked against its SHA-256 when one was given (for a ZIM without one, against the `<address>.sha256` file Kiwix
//!   publishes next to it, as the phone does), then installed.
//! - **Installing a ZIM** is what the phone does (`SourcesState.installDownloaded`): the file goes to
//!   `<data>/app/docs/zims/<name>` under a hidden name first and is renamed over any earlier file of that name, with the same
//!   sidecars, `<name>.origin.json` and `<name>.icon.png`. Then the helper is told to rescan (`sources.rescan`).
//! - **Library packages** (`kind: "library"`) are not installed here: on the phone that is a Dart procedure (see
//!   `LibrariesState._install` in app/lib/sources/libraries_state.dart) around several core jobs, not one core call. The browser
//!   runs that procedure itself. The server only brings the file: a downloaded or uploaded package lands in
//!   `<data>/app/docs/incoming/<name>` (the docs root, where the helper's `fs.*` ops and the core's jobs can reach it), and the
//!   browser installs it from there and deletes it.
//! - **Uploads** (`POST /api/library/upload`) stream the request body to `<data>/tmp/up-<random>.part` without holding it in memory.
//! - **Items** (`GET /api/library/items`, `DELETE /api/library/items/{id}`) list and remove what is on the server.
//! - **Space** (`GET /api/library/space`): free and total bytes of the disk the data folder is on.
//! - **Rescan** (`POST /api/library/rescan`): tells the core to read the library folders again, for a browser that has put a
//!   library in place itself.
//! - **Fetch** (`GET /api/fetch?url=`) reads a catalogue through the server, from the allow-listed hosts only (`fetch`).
//!
//! Everything is inside `<data>`. An item is locked while it is installed or removed.

use crate::fetch::{self, FetchError};
use crate::helper::Helper;
use http_body_util::BodyExt;
use hyper::body::{Body, Bytes};
use ring::digest;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;

/// Free space kept back when an upload is accepted, beyond the file itself.
const UPLOAD_HEADROOM: u64 = 1 << 30;
/// Finished and failed jobs kept in the list.
const KEEP_FINISHED: usize = 50;
/// The largest origin sidecar taken from a request.
const MAX_ORIGIN_BYTES: usize = 64 * 1024;
/// The largest icon taken (the phone's limit).
const MAX_ICON_BYTES: u64 = 512 * 1024;

/// An error for the API: the HTTP status and the `{"error":{"code","message"}}` it becomes.
#[derive(Debug)]
pub struct ApiErr {
    pub status: u16,
    pub code: &'static str,
    pub message: String,
}

fn api_err(status: u16, code: &'static str, message: impl Into<String>) -> ApiErr {
    ApiErr { status, code, message: message.into() }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum State {
    Queued,
    Running,
    Done,
    Failed,
    Cancelled,
}

impl State {
    fn active(self) -> bool {
        matches!(self, State::Queued | State::Running)
    }
}

/// One download job, as it is kept in `jobs.json`.
#[derive(Clone, Serialize, Deserialize, Debug)]
struct Job {
    id: String,
    url: String,
    kind: String,
    name: String,
    bytes: u64,
    total: u64,
    state: State,
    error: Option<String>,
    sha256: Option<String>,
    origin: Option<Value>,
    icon_url: Option<String>,
    /// When the job was asked for, RFC 3339 UTC. Null in entries written before this was kept.
    #[serde(default)]
    created_at: Option<String>,
    /// When it finished, failed or was cancelled, RFC 3339 UTC; null until then.
    #[serde(default)]
    finished_at: Option<String>,
}

/// Now as RFC 3339 UTC, to the second (`2026-11-01T03:12:09Z`).
fn now_rfc3339() -> String {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    rfc3339_of(secs)
}

fn rfc3339_of(secs: u64) -> String {
    let days = (secs / 86_400) as i64;
    let rem = secs % 86_400;
    // civil-from-days (proleptic Gregorian)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1_460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3_600, rem % 3_600 / 60, rem % 60)
}

impl Job {
    /// What the API shows.
    fn view(&self) -> Value {
        json!({"id": self.id, "url": self.url, "kind": self.kind, "name": self.name, "bytes": self.bytes, "total": self.total,
               "state": self.state, "error": self.error, "created_at": self.created_at, "finished_at": self.finished_at})
    }
}

/// Why a job stopped: a code (`cancelled`, `network`, `checksum`, `no_space`, `failed`) and words for people.
struct JobErr {
    code: &'static str,
    message: String,
}

fn job_err(code: &'static str, message: impl Into<String>) -> JobErr {
    JobErr { code, message: message.into() }
}

fn io_job_err(e: std::io::Error) -> JobErr {
    if is_disk_full(&e) {
        job_err("no_space", "The server is out of space. Free some and try again.")
    } else {
        job_err("failed", format!("Could not write the file: {e}"))
    }
}

fn is_disk_full(e: &std::io::Error) -> bool {
    // ENOSPC is 28 on Unix and ERROR_DISK_FULL is 112 on Windows.
    matches!(e.raw_os_error(), Some(28) | Some(112))
}

/// Free bytes on the file system holding a path; None when it cannot be told.
pub type FreeFn = Arc<dyn Fn(&Path) -> Option<u64> + Send + Sync>;

/// Things a test may replace.
#[derive(Default)]
pub struct LibraryOptions {
    /// Free bytes on the file system holding a path; None when it cannot be told. Default: the real answer.
    pub free_bytes: Option<FreeFn>,
    /// Total bytes of the file system holding a path; None when it cannot be told. Default: the real answer.
    pub total_bytes: Option<FreeFn>,
    /// The hosts `/api/fetch` may read. Default: [`fetch::FETCH_HOSTS`].
    pub fetch_hosts: Option<Vec<String>>,
    /// The size cap of `/api/fetch`. Default: [`fetch::FETCH_MAX_BYTES`].
    pub fetch_max: Option<u64>,
}

pub struct Library {
    data: PathBuf,
    helper: Option<Arc<Helper>>,
    free: FreeFn,
    total: FreeFn,
    fetch_hosts: Vec<String>,
    fetch_max: u64,
    jobs: Mutex<Vec<Job>>,
    /// The cancel flag of the job that is running.
    running: Mutex<Option<(String, Arc<AtomicBool>)>>,
    locks: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    wake: tokio::sync::Notify,
    worker_started: AtomicBool,
}

/// The free bytes on the file system that holds `path`.
pub fn free_bytes(path: &Path) -> Option<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
        // SAFETY: `c` is a valid NUL-terminated path and `st` is a zeroed statvfs that the call fills in.
        unsafe {
            let mut st: libc::statvfs = std::mem::zeroed();
            if libc::statvfs(c.as_ptr(), &mut st) != 0 {
                return None;
            }
            Some((st.f_bavail as u64).saturating_mul(st.f_frsize as u64))
        }
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

/// The total size in bytes of the file system that holds `path`.
pub fn total_bytes(path: &Path) -> Option<u64> {
    #[cfg(unix)]
    {
        use std::os::unix::ffi::OsStrExt;
        let c = std::ffi::CString::new(path.as_os_str().as_bytes()).ok()?;
        // SAFETY: `c` is a valid NUL-terminated path and `st` is a zeroed statvfs that the call fills in.
        unsafe {
            let mut st: libc::statvfs = std::mem::zeroed();
            if libc::statvfs(c.as_ptr(), &mut st) != 0 {
                return None;
            }
            Some((st.f_blocks as u64).saturating_mul(st.f_frsize as u64))
        }
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        None
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The SHA-256 of a file, as lowercase hex. Stops with `cancelled` when the flag is set.
fn sha256_file(path: &Path, cancel: &AtomicBool) -> Result<String, JobErr> {
    let mut f = std::fs::File::open(path).map_err(io_job_err)?;
    let mut ctx = digest::Context::new(&digest::SHA256);
    let mut buf = vec![0u8; 1 << 20];
    loop {
        if cancel.load(Ordering::Relaxed) {
            return Err(job_err("cancelled", "Cancelled"));
        }
        let n = f.read(&mut buf).map_err(io_job_err)?;
        if n == 0 {
            break;
        }
        ctx.update(&buf[..n]);
    }
    Ok(hex(ctx.finish().as_ref()))
}

fn random_hex() -> String {
    let mut b = [0u8; 8];
    // The system random source does not fail on any platform this runs on.
    let _ = ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut b);
    hex(&b)
}

/// The part file of a download of `url`: the same address always continues the same file.
pub fn part_path(data: &Path, url: &str) -> PathBuf {
    let h = digest::digest(&digest::SHA256, url.as_bytes());
    data.join("tmp").join(format!("dl-{}.part", &hex(h.as_ref())[..16]))
}

/// A file name that is safe to create under a folder: no path separators, no `..`, nothing hidden or odd. For a ZIM the name ends in
/// `.zim` (added when it is missing).
pub fn sanitize_name(raw: &str, kind: &str) -> Result<String, String> {
    let n = raw.trim();
    if n.is_empty() {
        return Err("A file name is needed.".into());
    }
    if n.len() > 200 {
        return Err("That file name is too long.".into());
    }
    if n.contains("..") || n.chars().any(|c| c.is_control() || matches!(c, '/' | '\\' | ':' | '<' | '>' | '"' | '|' | '?' | '*')) {
        return Err("That file name has characters that are not allowed.".into());
    }
    if n.starts_with('.') || n.ends_with('.') || n.ends_with(' ') {
        return Err("That file name is not allowed.".into());
    }
    if kind == "zim" && !n.to_ascii_lowercase().ends_with(".zim") {
        return Ok(format!("{n}.zim"));
    }
    Ok(n.to_string())
}

/// Removes a file when dropped, unless it was kept.
struct PartGuard(Option<PathBuf>);

impl PartGuard {
    fn keep(&mut self) {
        self.0 = None;
    }
}

impl Drop for PartGuard {
    fn drop(&mut self) {
        if let Some(p) = self.0.take() {
            let _ = std::fs::remove_file(p);
        }
    }
}

/// Write `data` to `path` through a hidden sibling and rename it into place.
fn write_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tmp = path.with_file_name(format!(".{name}.tmp"));
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

/// What the library routes need to answer the fetch proxy: the type, and the body as it arrives. An error item ends the body
/// early (the connection is cut), which is what happens when the cap is passed.
pub struct FetchStream {
    pub content_type: Option<String>,
    pub rx: tokio::sync::mpsc::Receiver<std::io::Result<Bytes>>,
}

impl Library {
    pub fn new(data: PathBuf, helper: Option<Arc<Helper>>) -> Arc<Library> {
        Library::with_options(data, helper, LibraryOptions::default())
    }

    /// Open the library on `data`: read `jobs.json` (a job that was running when the server stopped goes back to the queue and
    /// continues its part file), clear the leftovers of interrupted uploads, and start the worker when there is a runtime.
    pub fn with_options(data: PathBuf, helper: Option<Arc<Helper>>, o: LibraryOptions) -> Arc<Library> {
        let mut jobs: Vec<Job> = std::fs::read_to_string(data.join("jobs.json"))
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        for j in &mut jobs {
            if j.state == State::Running {
                j.state = State::Queued;
            }
        }
        if let Ok(rd) = std::fs::read_dir(data.join("tmp")) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().to_string();
                if n.starts_with("up-") && n.ends_with(".part") {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
        let lib = Arc::new(Library {
            data,
            helper,
            free: o.free_bytes.unwrap_or_else(|| Arc::new(free_bytes)),
            total: o.total_bytes.unwrap_or_else(|| Arc::new(total_bytes)),
            fetch_hosts: o.fetch_hosts.unwrap_or_else(|| fetch::FETCH_HOSTS.iter().map(|h| h.to_string()).collect()),
            fetch_max: o.fetch_max.unwrap_or(fetch::FETCH_MAX_BYTES),
            jobs: Mutex::new(jobs),
            running: Mutex::new(None),
            locks: Mutex::new(HashMap::new()),
            wake: tokio::sync::Notify::new(),
            worker_started: AtomicBool::new(false),
        });
        lib.ensure_worker();
        lib
    }

    // ---- paths

    fn tmp_dir(&self) -> PathBuf {
        self.data.join("tmp")
    }

    fn zims_dir(&self) -> PathBuf {
        self.data.join("app").join("docs").join("zims")
    }

    /// Where a library package waits for the browser to install it.
    fn incoming_dir(&self) -> PathBuf {
        self.data.join("app").join("docs").join("incoming")
    }

    fn libs_dir(&self) -> PathBuf {
        self.data.join("app").join("docs").join("libraries")
    }

    fn index_dir_of_zim(&self, name: &str) -> PathBuf {
        self.data.join("app").join("support").join("indexes").join(format!("{name}.idx"))
    }

    /// Run `f` holding the exclusive lock of one item (`zim:<file name>`).
    fn with_item_lock<T>(&self, key: &str, f: impl FnOnce() -> T) -> T {
        let m = {
            let mut l = self.locks.lock().unwrap_or_else(|e| e.into_inner());
            l.entry(key.to_string()).or_default().clone()
        };
        let _g = m.lock().unwrap_or_else(|e| e.into_inner());
        f()
    }

    // ---- jobs

    fn save_jobs(&self, jobs: &[Job]) {
        let text = match serde_json::to_string_pretty(jobs) {
            Ok(t) => t,
            Err(e) => return eprintln!("cache-server: jobs.json: {e}"),
        };
        if let Err(e) = crate::write_private(&self.data.join("jobs.json"), text.as_bytes()) {
            eprintln!("cache-server: writing jobs.json: {e}");
        }
    }

    /// Change the jobs under the lock and write them out.
    fn update_jobs<T>(&self, f: impl FnOnce(&mut Vec<Job>) -> T) -> T {
        let mut jobs = self.jobs.lock().unwrap_or_else(|e| e.into_inner());
        let out = f(&mut jobs);
        // keep the most recent finished jobs only
        let finished = jobs.iter().filter(|j| !j.state.active()).count();
        if finished > KEEP_FINISHED {
            let mut drop_n = finished - KEEP_FINISHED;
            jobs.retain(|j| {
                if drop_n > 0 && !j.state.active() {
                    drop_n -= 1;
                    false
                } else {
                    true
                }
            });
        }
        self.save_jobs(&jobs);
        out
    }

    fn ensure_worker(self: &Arc<Self>) {
        if tokio::runtime::Handle::try_current().is_err() || self.worker_started.swap(true, Ordering::SeqCst) {
            return;
        }
        let me = self.clone();
        tokio::spawn(async move { me.worker().await });
    }

    /// The next queued job, marked running, with its cancel flag.
    fn next_job(&self) -> Option<(Job, Arc<AtomicBool>)> {
        let job = self.update_jobs(|jobs| {
            let j = jobs.iter_mut().find(|j| j.state == State::Queued)?;
            j.state = State::Running;
            j.error = None;
            Some(j.clone())
        })?;
        let flag = Arc::new(AtomicBool::new(false));
        *self.running.lock().unwrap_or_else(|e| e.into_inner()) = Some((job.id.clone(), flag.clone()));
        Some((job, flag))
    }

    async fn worker(self: Arc<Self>) {
        loop {
            let Some((job, cancel)) = self.next_job() else {
                self.wake.notified().await;
                continue;
            };
            let (me, j, c) = (self.clone(), job.clone(), cancel.clone());
            let res = tokio::task::spawn_blocking(move || me.run_job(&j, &c)).await.unwrap_or_else(|e| Err(job_err("failed", format!("internal error: {e}"))));
            let mut note = None;
            if res.is_ok() && job.kind == "zim" {
                if let Err(e) = self.rescan().await {
                    eprintln!("cache-server: rescan after installing {} failed: {e}", job.name);
                    note = Some(format!("Installed, but the search core was not told: {e}"));
                }
            }
            *self.running.lock().unwrap_or_else(|e| e.into_inner()) = None;
            self.update_jobs(|jobs| {
                let Some(j) = jobs.iter_mut().find(|j| j.id == job.id) else { return };
                if j.state == State::Cancelled && res.is_err() {
                    return;
                }
                j.finished_at = Some(now_rfc3339());
                match res {
                    Ok(()) => {
                        j.state = State::Done;
                        j.error = note;
                    }
                    Err(e) if e.code == "cancelled" => j.state = State::Cancelled,
                    Err(e) => {
                        j.state = State::Failed;
                        j.error = Some(e.message);
                    }
                }
            });
        }
    }

    fn progress(&self, id: &str, bytes: u64, total: u64) {
        let mut jobs = self.jobs.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(j) = jobs.iter_mut().find(|j| j.id == id) {
            j.bytes = bytes;
            j.total = total;
        }
    }

    /// One job from start to installed (blocking).
    fn run_job(&self, job: &Job, cancel: &AtomicBool) -> Result<(), JobErr> {
        let part = part_path(&self.data, &job.url);
        let result = self.download_and_install(job, &part, cancel);
        match &result {
            Err(e) if e.code == "cancelled" => {
                let _ = std::fs::remove_file(&part);
            }
            Err(e) if e.code == "checksum" => {
                let _ = std::fs::remove_file(&part);
            }
            _ => {}
        }
        result
    }

    fn download_and_install(&self, job: &Job, part: &Path, cancel: &AtomicBool) -> Result<(), JobErr> {
        let check_cancel = || if cancel.load(Ordering::Relaxed) { Err(job_err("cancelled", "Cancelled")) } else { Ok(()) };
        std::fs::create_dir_all(self.tmp_dir()).map_err(io_job_err)?;
        let agent = fetch::agent();
        let mut have = std::fs::metadata(part).map(|m| m.len()).unwrap_or(0);
        let mut restarted = false;
        let mut cur = job.url.clone();
        let mut hops = 0;

        // 1. The answer: where to start, how big the whole file is, and the body (None when the part is already whole).
        let (body, start, total) = loop {
            check_cancel()?;
            fetch::parse_url(&cur).filter(fetch::scheme_ok).ok_or_else(|| job_err("failed", "That is not an address the server can download from."))?;
            let mut req = agent.get(&cur);
            if have > 0 {
                req = req.set("Range", &format!("bytes={have}-"));
            }
            let resp = match req.call() {
                Ok(r) => r,
                Err(ureq::Error::Status(416, r)) => {
                    let whole = r.header("content-range").and_then(|c| c.strip_prefix("bytes */")).and_then(|t| t.trim().parse::<u64>().ok());
                    if have > 0 && whole == Some(have) {
                        break (None, have, have);
                    }
                    if have == 0 || restarted {
                        return Err(job_err("failed", "The download server would not continue the file."));
                    }
                    let _ = std::fs::remove_file(part);
                    have = 0;
                    restarted = true;
                    continue;
                }
                Err(ureq::Error::Status(404, _)) => return Err(job_err("failed", "That file is no longer on the download server.")),
                Err(ureq::Error::Status(code, _)) => return Err(job_err("failed", format!("The download server answered {code}."))),
                Err(e) => return Err(job_err("network", format!("The connection failed: {e}"))),
            };
            let status = resp.status();
            if matches!(status, 301 | 302 | 303 | 307 | 308) {
                hops += 1;
                let loc = resp.header("location").filter(|_| hops <= 8);
                let Some(loc) = loc else { return Err(job_err("failed", "The download server redirected too many times.")) };
                cur = fetch::resolve(&cur, loc).ok_or_else(|| job_err("failed", "The download server sent a bad redirect."))?;
                continue;
            }
            match status {
                206 => {
                    // "bytes START-END/TOTAL": the server must continue exactly where the file ends.
                    let cr = resp.header("content-range").unwrap_or("").to_string();
                    let rest = cr.strip_prefix("bytes ").unwrap_or("");
                    let (range, whole) = rest.split_once('/').unwrap_or(("", ""));
                    let from = range.split('-').next().and_then(|s| s.trim().parse::<u64>().ok());
                    if from != Some(have) {
                        return Err(job_err("network", "The download server continued from the wrong place. Try again."));
                    }
                    let total = whole.trim().parse::<u64>().ok().or_else(|| resp.header("content-length").and_then(|v| v.trim().parse::<u64>().ok()).map(|n| n + have)).unwrap_or(0);
                    break (Some(resp.into_reader()), have, total);
                }
                200 => {
                    let total = resp.header("content-length").and_then(|v| v.trim().parse::<u64>().ok()).unwrap_or(0);
                    break (Some(resp.into_reader()), 0, total);
                }
                other => return Err(job_err("failed", format!("The download server answered {other}."))),
            }
        };

        // 2. Room for the rest of the file and a margin (5%, at least 64 MB), as the phone's downloader asks.
        if total > 0 {
            let margin = (total / 20).max(64 << 20);
            let needed = (total - start.min(total)) + margin;
            if let Some(avail) = (self.free)(&self.tmp_dir()) {
                if avail < needed {
                    return Err(job_err("no_space", format!("Not enough free space on the server: {} MB needed, {} MB free.", needed >> 20, avail >> 20)));
                }
            }
        }

        // 3. The body, appended to the part file (or written from the start).
        if let Some(mut reader) = body {
            let mut f = if start == 0 {
                std::fs::File::create(part)
            } else {
                std::fs::OpenOptions::new().append(true).open(part)
            }
            .map_err(io_job_err)?;
            let mut buf = vec![0u8; 256 << 10];
            let mut done = start;
            let mut last = Instant::now();
            self.progress(&job.id, done, total);
            loop {
                check_cancel()?;
                let n = reader.read(&mut buf).map_err(|e| job_err("network", format!("The connection failed: {e}")))?;
                if n == 0 {
                    break;
                }
                f.write_all(&buf[..n]).map_err(io_job_err)?;
                done += n as u64;
                if last.elapsed() >= Duration::from_millis(250) {
                    last = Instant::now();
                    self.progress(&job.id, done, total);
                }
            }
            f.sync_all().map_err(io_job_err)?;
            self.progress(&job.id, done, total);
        }
        let size = std::fs::metadata(part).map_err(io_job_err)?.len();
        if total > 0 && size != total {
            return Err(job_err("network", format!("The download stopped early ({} of {} MB). Add it again to continue.", size >> 20, total >> 20)));
        }
        check_cancel()?;

        // 4. The checksum: the one given, else (for a ZIM) the one Kiwix publishes beside the file.
        let expected = match &job.sha256 {
            Some(h) => Some(h.to_ascii_lowercase()),
            None if job.kind == "zim" => published_sha256(&agent, &job.url),
            None => None,
        };
        if let Some(want) = expected {
            let got = sha256_file(part, cancel)?;
            if got != want {
                return Err(job_err("checksum", "The file did not match its published checksum, so it was thrown away. Try again."));
            }
        }
        check_cancel()?;

        // 5. Install. A library package is only put in the docs root: the browser installs it.
        if job.kind == "library" {
            return self.install_incoming(part, &job.name).map_err(io_job_err);
        }
        let icon = job.icon_url.as_deref().and_then(|u| fetch_icon(&agent, u));
        self.install_zim(part, &job.name, job.origin.as_ref(), icon.as_deref()).map_err(io_job_err)
    }

    /// Put a finished ZIM where the app would: `<data>/app/docs/zims/<name>`, first under a hidden name and then renamed over any
    /// earlier file of that name, so the real name always holds the old file or the whole new one. The sidecars follow.
    /// Holds the item's lock.
    pub fn install_zim(&self, finished: &Path, name: &str, origin: Option<&Value>, icon: Option<&[u8]>) -> std::io::Result<()> {
        let dir = self.zims_dir();
        std::fs::create_dir_all(&dir)?;
        let dest = dir.join(name);
        let hidden = dir.join(format!(".{name}.install.part"));
        self.with_item_lock(&format!("zim:{name}"), || {
            if std::fs::rename(finished, &hidden).is_err() {
                // another file system: copy, then drop the original
                if let Err(e) = std::fs::copy(finished, &hidden) {
                    let _ = std::fs::remove_file(&hidden);
                    return Err(e);
                }
                let _ = std::fs::remove_file(finished);
            }
            if let Err(e) = std::fs::rename(&hidden, &dest) {
                let _ = std::fs::remove_file(&hidden);
                return Err(e);
            }
            if let Some(o) = origin {
                write_atomic(&dir.join(format!("{name}.origin.json")), o.to_string().as_bytes())?;
            }
            if let Some(i) = icon.filter(|i| !i.is_empty()) {
                write_atomic(&dir.join(format!("{name}.icon.png")), i)?;
            }
            Ok(())
        })
    }

    /// Put a finished library package where the browser installs it from: `<data>/app/docs/incoming/<name>`, first under a hidden
    /// name and then renamed over any earlier file of that name. Holds the item's lock.
    pub fn install_incoming(&self, finished: &Path, name: &str) -> std::io::Result<()> {
        let dir = self.incoming_dir();
        std::fs::create_dir_all(&dir)?;
        let dest = dir.join(name);
        let hidden = dir.join(format!(".{name}.install.part"));
        self.with_item_lock(&format!("incoming:{name}"), || {
            if std::fs::rename(finished, &hidden).is_err() {
                if let Err(e) = std::fs::copy(finished, &hidden) {
                    let _ = std::fs::remove_file(&hidden);
                    return Err(e);
                }
                let _ = std::fs::remove_file(finished);
            }
            if let Err(e) = std::fs::rename(&hidden, &dest) {
                let _ = std::fs::remove_file(&hidden);
                return Err(e);
            }
            Ok(())
        })
    }

    /// Tell the helper to rescan the app folders (or `sources.json`, when there is one). The number of sources it now has.
    pub async fn rescan(&self) -> Result<u64, String> {
        let Some(h) = &self.helper else { return Ok(0) };
        let sources = crate::helper::read_sources(&self.data.join("sources.json"))?;
        let reply = h.call("sources.rescan", json!({"sources": sources})).await?;
        if reply["ok"] == json!(true) {
            Ok(reply["result"]["sources"].as_u64().unwrap_or(0))
        } else {
            Err(reply["error"]["message"].as_str().unwrap_or("the helper refused").to_string())
        }
    }

    // ---- the API

    /// `POST /api/library/download`.
    pub fn add_download(self: &Arc<Self>, body: &[u8]) -> Result<Value, ApiErr> {
        let v: Value = serde_json::from_slice(body).map_err(|_| api_err(400, "bad_json", "the body is not JSON"))?;
        let url = v["url"].as_str().ok_or_else(|| api_err(400, "invalid", "\"url\" is required"))?.trim().to_string();
        fetch::parse_url(&url).filter(fetch::scheme_ok).ok_or_else(|| api_err(400, "invalid", "Use a link that starts with https://"))?;
        let kind = v["kind"].as_str().unwrap_or("");
        if kind != "zim" && kind != "library" {
            return Err(api_err(400, "invalid", "\"kind\" is \"zim\" or \"library\""));
        }
        let name = match v["name"].as_str() {
            Some(n) => n.to_string(),
            None => {
                let path = url.split(['?', '#']).next().unwrap_or("");
                let last = path.rsplit('/').next().unwrap_or("");
                fetch::percent_decode(last).unwrap_or_default()
            }
        };
        let name = sanitize_name(&name, kind).map_err(|m| api_err(400, "invalid_name", m))?;
        let sha256 = match v["sha256"].as_str() {
            None => None,
            Some(h) if h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()) => Some(h.to_ascii_lowercase()),
            Some(_) => return Err(api_err(400, "invalid", "\"sha256\" is 64 hex digits")),
        };
        let origin = match &v["origin"] {
            Value::Null => None,
            o @ Value::Object(_) if o.to_string().len() <= MAX_ORIGIN_BYTES => Some(o.clone()),
            _ => return Err(api_err(400, "invalid", "\"origin\" is a small JSON object")),
        };
        let icon_url = match v["icon_url"].as_str() {
            None => None,
            Some(u) if fetch::parse_url(u).is_some_and(|p| fetch::scheme_ok(&p)) => Some(u.to_string()),
            Some(_) => return Err(api_err(400, "invalid", "\"icon_url\" is not an address the server can read")),
        };
        let view = self.update_jobs(|jobs| {
            if let Some(j) = jobs.iter().find(|j| j.state.active() && j.url == url) {
                return j.view();
            }
            let j = Job { id: random_hex(), url, kind: kind.to_string(), name, bytes: 0, total: 0, state: State::Queued, error: None, sha256, origin, icon_url, created_at: Some(now_rfc3339()), finished_at: None };
            let view = j.view();
            jobs.push(j);
            view
        });
        self.ensure_worker();
        self.wake.notify_one();
        Ok(view)
    }

    /// `GET /api/library/jobs`.
    pub fn list_jobs(&self) -> Value {
        let jobs = self.jobs.lock().unwrap_or_else(|e| e.into_inner());
        Value::Array(jobs.iter().map(Job::view).collect())
    }

    /// `DELETE /api/library/jobs/{id}`: a waiting or running job is cancelled (its part file is thrown away); a finished one is
    /// taken off the list.
    pub fn cancel_job(&self, id: &str) -> Result<Value, ApiErr> {
        let (view, was_active) = self.update_jobs(|jobs| {
            let i = jobs.iter().position(|j| j.id == id)?;
            if jobs[i].state.active() {
                jobs[i].state = State::Cancelled;
                jobs[i].error = None;
                jobs[i].finished_at = Some(now_rfc3339());
                Some((jobs[i].view(), true))
            } else {
                Some((jobs.remove(i).view(), false))
            }
        })
        .ok_or_else(|| api_err(404, "not_found", "no such job"))?;
        if was_active {
            let running_this = match self.running.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
                Some((rid, flag)) if rid == id => {
                    flag.store(true, Ordering::Relaxed);
                    true
                }
                _ => false,
            };
            // A job that never started has no worker to clean up after it.
            let url = view["url"].as_str().unwrap_or("");
            if !running_this {
                let still_wanted = self.jobs.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|j| j.url == url && j.state.active());
                if !still_wanted {
                    let _ = std::fs::remove_file(part_path(&self.data, url));
                }
            }
        }
        Ok(view)
    }

    /// `POST /api/library/upload?kind=zim&name=<file name>`: stream the body to a part file in `<data>/tmp`, then install it like a
    /// download. `content_length` is the request's Content-Length; the body is never held in memory.
    pub async fn upload<B>(self: &Arc<Self>, query: &str, content_length: Option<u64>, mut body: B) -> Result<Value, ApiErr>
    where
        B: Body<Data = Bytes> + Unpin,
        B::Error: std::fmt::Display,
    {
        let kind = fetch::query_param(query, "kind").unwrap_or_default();
        if kind != "zim" && kind != "library" {
            return Err(api_err(400, "invalid", "\"kind\" is \"zim\" or \"library\""));
        }
        let name = fetch::query_param(query, "name").ok_or_else(|| api_err(400, "invalid_name", "A file name is needed."))?;
        let name = sanitize_name(&name, &kind).map_err(|m| api_err(400, "invalid_name", m))?;
        let len = content_length.ok_or_else(|| api_err(411, "length_required", "The upload needs a Content-Length."))?;
        let tmp = self.tmp_dir();
        std::fs::create_dir_all(&tmp).map_err(|e| api_err(500, "server_error", format!("could not make the upload folder: {e}")))?;
        if let Some(avail) = (self.free)(&tmp) {
            if avail < len.saturating_add(UPLOAD_HEADROOM) {
                return Err(api_err(
                    507,
                    "no_space",
                    format!("Not enough free space on the server: {} MB needed (and 1 GB to spare), {} MB free.", len >> 20, avail >> 20),
                ));
            }
        }
        let part = tmp.join(format!("up-{}.part", random_hex()));
        let mut guard = PartGuard(Some(part.clone()));
        let write_err = |e: std::io::Error| {
            if is_disk_full(&e) {
                api_err(507, "no_space", "The server ran out of space during the upload.")
            } else {
                api_err(500, "server_error", format!("could not write the upload: {e}"))
            }
        };
        let mut f = tokio::fs::File::create(&part).await.map_err(write_err)?;
        let mut got: u64 = 0;
        while let Some(frame) = body.frame().await {
            let frame = frame.map_err(|e| api_err(400, "upload_interrupted", format!("the upload was cut off: {e}")))?;
            if let Ok(data) = frame.into_data() {
                got += data.len() as u64;
                if got > len {
                    return Err(api_err(400, "invalid", "the body is longer than its Content-Length"));
                }
                f.write_all(&data).await.map_err(write_err)?;
            }
        }
        if got != len {
            return Err(api_err(400, "upload_interrupted", "the upload ended before its Content-Length"));
        }
        f.flush().await.map_err(write_err)?;
        f.sync_all().await.map_err(write_err)?;
        drop(f);
        let (me, p, n, k) = (self.clone(), part.clone(), name.clone(), kind.clone());
        let installed = tokio::task::spawn_blocking(move || if k == "library" { me.install_incoming(&p, &n) } else { me.install_zim(&p, &n, None, None) }).await;
        match installed {
            Ok(Ok(())) => guard.keep(),
            Ok(Err(e)) => return Err(write_err(e)),
            Err(e) => return Err(api_err(500, "server_error", format!("internal error: {e}"))),
        }
        if kind == "library" {
            return Ok(json!({"name": name, "bytes": got, "path": format!("incoming/{name}")}));
        }
        let rescan = self.rescan().await;
        if let Err(e) = &rescan {
            eprintln!("cache-server: rescan after the upload of {name} failed: {e}");
        }
        let mut out = json!({"name": name, "bytes": got, "id": item_id("zim", &name)});
        if let Err(e) = rescan {
            out["note"] = json!(format!("Installed, but the search core was not told: {e}"));
        }
        Ok(out)
    }

    // ---- space

    /// `GET /api/library/space`: the free and total bytes of the disk the data folder is on (null when that cannot be told).
    pub fn space(&self) -> Value {
        json!({"free_bytes": (self.free)(&self.data), "total_bytes": (self.total)(&self.data)})
    }

    /// `POST /api/library/rescan`: the core reads the library folders again. The number of sources it now has.
    pub async fn rescan_api(&self) -> Result<Value, ApiErr> {
        self.rescan().await.map(|n| json!({"sources": n})).map_err(|e| api_err(502, "core_unavailable", e))
    }

    // ---- what is installed

    /// What is installed, with titles from the core's `status`.
    pub async fn items(&self) -> Vec<Value> {
        let mut titles: HashMap<String, String> = HashMap::new();
        if let Some(h) = &self.helper {
            if let Ok(reply) = h.call("status", json!({})).await {
                for s in reply["result"].as_array().into_iter().flatten() {
                    let (kind, path, title) = (s["kind"].as_str().unwrap_or(""), s["path"].as_str().unwrap_or(""), s["title"].as_str().unwrap_or(""));
                    let segs: Vec<&str> = path.split(['/', '\\']).filter(|p| !p.is_empty()).collect();
                    let name = if kind == "zim" { segs.last() } else { segs.len().checked_sub(2).and_then(|i| segs.get(i)) };
                    if let (Some(name), false) = (name, title.is_empty()) {
                        titles.insert(format!("{kind}:{name}"), title.to_string());
                    }
                }
            }
        }
        let data = self.data.clone();
        let (zims, libs) = (self.zims_dir(), self.libs_dir());
        let mut out = tokio::task::spawn_blocking(move || scan_items(&data, &zims, &libs)).await.unwrap_or_default();
        for it in &mut out {
            let key = format!("{}:{}", it["kind"].as_str().unwrap_or(""), it["name"].as_str().unwrap_or(""));
            if let Some(t) = titles.get(&key) {
                it["title"] = json!(t);
            }
        }
        out
    }

    /// `DELETE /api/library/items/{id}`: the files, the sidecars and the index folder, then a rescan.
    pub async fn remove_item(self: &Arc<Self>, id: &str) -> Result<Value, ApiErr> {
        let (data, zims, libs) = (self.data.clone(), self.zims_dir(), self.libs_dir());
        let items = tokio::task::spawn_blocking(move || scan_items(&data, &zims, &libs)).await.unwrap_or_default();
        let item = items.into_iter().find(|i| i["id"] == json!(id)).ok_or_else(|| api_err(404, "not_found", "no such item"))?;
        let (kind, name) = (item["kind"].as_str().unwrap_or("").to_string(), item["name"].as_str().unwrap_or("").to_string());
        let me = self.clone();
        let (k2, n2) = (kind.clone(), name.clone());
        tokio::task::spawn_blocking(move || me.remove_files(&k2, &n2)).await.unwrap_or_else(|e| Err(api_err(500, "server_error", e.to_string())))?;
        let mut out = json!({"removed": true, "id": id});
        if let Err(e) = self.rescan().await {
            eprintln!("cache-server: rescan after removing {name} failed: {e}");
            out["note"] = json!(format!("Removed, but the search core was not told: {e}"));
        }
        Ok(out)
    }

    fn remove_files(&self, kind: &str, name: &str) -> Result<(), ApiErr> {
        self.with_item_lock(&format!("{kind}:{name}"), || {
            let busy = self.jobs.lock().unwrap_or_else(|e| e.into_inner()).iter().any(|j| j.state.active() && j.kind == kind && j.name == name);
            if busy {
                return Err(api_err(409, "busy", "That item is being downloaded right now. Cancel the download first."));
            }
            let fail = |e: std::io::Error| api_err(500, "server_error", format!("could not remove {name}: {e}"));
            let gone = |r: std::io::Result<()>| match r {
                Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
                _ => Ok(()),
            };
            if kind == "zim" {
                let dir = self.zims_dir();
                gone(std::fs::remove_file(dir.join(name))).map_err(fail)?;
                gone(std::fs::remove_file(dir.join(format!("{name}.origin.json")))).map_err(fail)?;
                gone(std::fs::remove_file(dir.join(format!("{name}.icon.png")))).map_err(fail)?;
                gone(std::fs::remove_dir_all(self.index_dir_of_zim(name))).map_err(fail)?;
            } else {
                gone(std::fs::remove_dir_all(self.libs_dir().join(name))).map_err(fail)?;
            }
            Ok(())
        })
    }

    // ---- the catalogue fetch proxy

    /// `GET /api/fetch?url=`: check the address, connect, and hand back the body as a stream capped at the size limit.
    pub async fn fetch(self: &Arc<Self>, query: &str) -> Result<FetchStream, ApiErr> {
        let url = fetch::query_param(query, "url").ok_or_else(|| api_err(400, "invalid", "\"url\" is required"))?;
        let (hosts, max) = (self.fetch_hosts.clone(), self.fetch_max);
        let u2 = url.clone();
        let opened = tokio::task::spawn_blocking(move || fetch::open(&hosts, &u2, max)).await.map_err(|e| api_err(500, "server_error", e.to_string()))?;
        let opened = opened.map_err(|e| match e {
            FetchError::BadUrl => api_err(400, "invalid", "That is not an address the server will read."),
            FetchError::Denied(h) => api_err(403, "host_not_allowed", format!("{h} is not one of the catalogue hosts.")),
            FetchError::Upstream(c) => api_err(502, "upstream_status", format!("The catalogue answered {c}.")),
            FetchError::TooLarge => api_err(413, "too_large", "That answer is bigger than a catalogue."),
            FetchError::TooManyRedirects => api_err(502, "upstream_status", "The catalogue redirected too many times."),
            FetchError::Unreachable(m) => api_err(502, "unreachable", format!("Could not reach the catalogue: {m}")),
        })?;
        let (tx, rx) = tokio::sync::mpsc::channel::<std::io::Result<Bytes>>(4);
        let mut reader = opened.reader;
        tokio::task::spawn_blocking(move || {
            let mut buf = vec![0u8; 64 << 10];
            let mut sent: u64 = 0;
            loop {
                match reader.read(&mut buf) {
                    Ok(0) => return,
                    Ok(n) => {
                        sent += n as u64;
                        if sent > max {
                            let _ = tx.blocking_send(Err(std::io::Error::other("the answer is bigger than a catalogue")));
                            return;
                        }
                        if tx.blocking_send(Ok(Bytes::copy_from_slice(&buf[..n]))).is_err() {
                            return;
                        }
                    }
                    Err(e) => {
                        let _ = tx.blocking_send(Err(e));
                        return;
                    }
                }
            }
        });
        Ok(FetchStream { content_type: opened.content_type, rx })
    }
}

/// An item's id: its kind and a short hash of its name, so it is the same on every listing and safe in an address.
fn item_id(kind: &str, name: &str) -> String {
    let h = digest::digest(&digest::SHA256, format!("{kind}:{name}").as_bytes());
    format!("{kind}-{}", &hex(h.as_ref())[..16])
}

fn dir_bytes(p: &Path) -> u64 {
    let mut total = 0;
    if let Ok(rd) = std::fs::read_dir(p) {
        for e in rd.flatten() {
            match e.file_type() {
                Ok(t) if t.is_dir() => total += dir_bytes(&e.path()),
                Ok(_) => total += e.metadata().map(|m| m.len()).unwrap_or(0),
                Err(_) => {}
            }
        }
    }
    total
}

/// Every ZIM file in `zims` and every folder with a `shard` folder in `libs`, as the helper's scan sees them (hidden names are
/// skipped), ZIMs first, each group in name order.
fn scan_items(data: &Path, zims: &Path, libs: &Path) -> Vec<Value> {
    let rel = |p: &Path| p.strip_prefix(data).unwrap_or(p).to_string_lossy().replace('\\', "/");
    let mut out = Vec::new();
    let mut names: Vec<(String, PathBuf)> = vec![];
    if let Ok(rd) = std::fs::read_dir(zims) {
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if !n.starts_with('.') && n.to_ascii_lowercase().ends_with(".zim") && e.file_type().is_ok_and(|t| t.is_file()) {
                names.push((n, e.path()));
            }
        }
    }
    names.sort_by_key(|(n, _)| n.to_lowercase());
    for (n, p) in names {
        let bytes = std::fs::metadata(&p).map(|m| m.len()).unwrap_or(0);
        out.push(json!({"id": item_id("zim", &n), "kind": "zim", "name": n, "title": n, "bytes": bytes, "path": rel(&p)}));
    }
    let mut folders: Vec<(String, PathBuf)> = vec![];
    if let Ok(rd) = std::fs::read_dir(libs) {
        for e in rd.flatten() {
            let n = e.file_name().to_string_lossy().to_string();
            if !n.starts_with('.') && e.path().join("shard").is_dir() {
                folders.push((n, e.path()));
            }
        }
    }
    folders.sort_by_key(|(n, _)| n.to_lowercase());
    for (n, p) in folders {
        out.push(json!({"id": item_id("library", &n), "kind": "library", "name": n, "title": n, "bytes": dir_bytes(&p), "path": rel(&p)}));
    }
    out
}

/// The SHA-256 Kiwix publishes next to a ZIM (`<address>.sha256`), when there is one.
fn published_sha256(agent: &ureq::Agent, url: &str) -> Option<String> {
    let path = url.split(['?', '#']).next()?;
    if !path.to_ascii_lowercase().ends_with(".zim") {
        return None;
    }
    let mut cur = format!("{path}.sha256");
    for _ in 0..6 {
        fetch::parse_url(&cur).filter(fetch::scheme_ok)?;
        let resp = agent.get(&cur).timeout(Duration::from_secs(30)).call().ok()?;
        if matches!(resp.status(), 301 | 302 | 303 | 307 | 308) {
            cur = fetch::resolve(&cur, resp.header("location")?)?;
            continue;
        }
        if resp.status() != 200 {
            return None;
        }
        let mut text = String::new();
        resp.into_reader().take(4096).read_to_string(&mut text).ok()?;
        let first: String = text.trim_start().chars().take_while(char::is_ascii_hexdigit).collect();
        return (first.len() == 64).then(|| first.to_ascii_lowercase());
    }
    None
}

/// An icon (at most 512 KB), or None: an icon that cannot be fetched is not a reason to fail the download.
fn fetch_icon(agent: &ureq::Agent, url: &str) -> Option<Vec<u8>> {
    let mut cur = url.to_string();
    for _ in 0..6 {
        fetch::parse_url(&cur).filter(fetch::scheme_ok)?;
        let resp = agent.get(&cur).timeout(Duration::from_secs(30)).call().ok()?;
        if matches!(resp.status(), 301 | 302 | 303 | 307 | 308) {
            cur = fetch::resolve(&cur, resp.header("location")?)?;
            continue;
        }
        if resp.status() != 200 {
            return None;
        }
        let mut buf = Vec::new();
        resp.into_reader().take(MAX_ICON_BYTES + 1).read_to_end(&mut buf).ok()?;
        return (buf.len() as u64 <= MAX_ICON_BYTES).then_some(buf);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_are_made_safe() {
        for bad in ["", "  ", "../x.zim", "a/b.zim", "a\\b.zim", "x..zim", "..", ".hidden.zim", "a\0b.zim", "a:b.zim", "con?.zim", "x.", "dir/"] {
            assert!(sanitize_name(bad, "zim").is_err(), "{bad:?}");
        }
        assert!(sanitize_name(&"a".repeat(201), "zim").is_err());
        assert_eq!(sanitize_name("wikipedia_en_maxi_2026-09.zim", "zim").unwrap(), "wikipedia_en_maxi_2026-09.zim");
        assert_eq!(sanitize_name(" notes ", "zim").unwrap(), "notes.zim");
        assert_eq!(sanitize_name("Big.ZIM", "zim").unwrap(), "Big.ZIM");
        assert_eq!(sanitize_name("my pack.cache-library", "library").unwrap(), "my pack.cache-library");
    }

    #[test]
    fn item_ids_are_stable_and_safe() {
        let a = item_id("zim", "a b.zim");
        assert_eq!(a, item_id("zim", "a b.zim"));
        assert_ne!(a, item_id("library", "a b.zim"));
        assert!(a.chars().all(|c| c.is_ascii_alphanumeric() || c == '-'));
    }

    #[test]
    fn job_times_are_rfc3339_and_old_entries_load_with_null() {
        assert_eq!(rfc3339_of(0), "1970-01-01T00:00:00Z");
        assert_eq!(rfc3339_of(1_782_958_329), "2026-07-02T02:12:09Z");
        assert_eq!(rfc3339_of(951_782_400), "2000-02-29T00:00:00Z");
        let now = now_rfc3339();
        assert_eq!(now.len(), 20);
        assert!(now.ends_with('Z') && now.as_bytes()[10] == b'T', "{now}");
        // an entry written before the times were kept
        let old: Job = serde_json::from_str(
            r#"{"id":"a","url":"u","kind":"zim","name":"n.zim","bytes":1,"total":2,"state":"done","error":null,"sha256":null,"origin":null,"icon_url":null}"#,
        )
        .unwrap();
        let v = old.view();
        assert!(v["created_at"].is_null() && v["finished_at"].is_null());
        let j = Job { created_at: Some(now.clone()), finished_at: None, ..old };
        let back: Job = serde_json::from_str(&serde_json::to_string(&j).unwrap()).unwrap();
        assert_eq!(back.created_at.as_deref(), Some(now.as_str()));
        assert!(back.view()["finished_at"].is_null());
    }
}
