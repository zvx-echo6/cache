//! Chat-model files on the server, run for the browser build (audit item 9): downloads from the recommended list and Hugging Face,
//! uploads, and the host's memory for the fit check.
//!
//! The server runs the downloads, so they go on with no tab open and can be paused and resumed, as on the phone. One runs at a time
//! (first in, first out). A download is resumable (a part file in `<data>/models/.partial/` that continues with an HTTP Range),
//! checked against its SHA-256 when one is given, and put in `<data>/models/` by a rename. Redirects are followed here, one hop at
//! a time, and every hop must be on the short host list below. The search model (bge-m3) is the embedder's own download
//! (`embed`); it is listed beside these so the screen can show it, and it can follow a chat model.
//!
//! Routes (all behind the session; see `http.rs`): `GET|POST /api/models/downloads`, `POST /api/models/downloads/<name>/pause|resume`,
//! `DELETE /api/models/downloads/<name>`, `DELETE /api/models/files/<name>`, `POST /api/models/upload?name=`, `GET /api/system/memory`.

use crate::fetch;
use crate::library::{free_bytes, ApiErr};
use crate::llm::valid_model_id;
use http_body_util::BodyExt;
use hyper::body::{Body, Bytes};
use ring::digest;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::AsyncWriteExt;

/// Free space kept back beyond a model's size.
const HEADROOM: u64 = 1 << 30;

const RUN: u8 = 0;
const PAUSE: u8 = 1;
const DISCARD: u8 = 2;

fn err(status: u16, code: &'static str, message: impl Into<String>) -> ApiErr {
    ApiErr { status, code, message: message.into() }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum State {
    Queued,
    Running,
    Paused,
    Failed,
    Done,
}

impl State {
    fn word(self, verifying: bool) -> &'static str {
        match self {
            State::Queued => "queued",
            State::Running if verifying => "verifying",
            State::Running => "running",
            State::Paused => "paused",
            State::Failed => "failed",
            State::Done => "done",
        }
    }
}

struct Job {
    name: String,
    url: String,
    size: u64,
    sha256: Option<String>,
    search: bool,
    state: State,
    verifying: bool,
    done: u64,
    total: u64,
    error: Option<String>,
    ctl: Arc<AtomicU8>,
}

#[derive(Default)]
struct Inner {
    jobs: Vec<Job>,
    worker: bool,
}

type Hook = Arc<dyn Fn() + Send + Sync>;

pub struct ModelJobs {
    data: PathBuf,
    /// The embedder's file name: its download is `embed`'s, not a job here.
    embed_file: String,
    inner: Mutex<Inner>,
    /// Called when a download that asked for the search model has finished (starts the embedder's download when it is missing).
    after: Mutex<Option<Hook>>,
    /// Tests only: a download may come from this machine over plain http.
    allow_loopback: AtomicBool,
}

/// Parsed `POST /api/models/downloads` body.
struct Request {
    name: String,
    url: String,
    size: u64,
    sha256: Option<String>,
    search: bool,
}

fn pct(seg: &str) -> String {
    let mut o = String::new();
    for b in seg.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            o.push(b as char);
        } else {
            o.push_str(&format!("%{b:02X}"));
        }
    }
    o
}

fn plain(s: &str) -> bool {
    !s.is_empty() && s != "." && s != ".." && s.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_'))
}

impl ModelJobs {
    pub fn new(data: PathBuf, embed_file: String) -> Arc<ModelJobs> {
        Arc::new(ModelJobs { data, embed_file, inner: Mutex::new(Inner::default()), after: Mutex::new(None), allow_loopback: AtomicBool::new(false) })
    }

    /// What to do when a download that asked for the search model finishes.
    pub fn set_after(&self, f: Hook) {
        *self.after.lock().unwrap_or_else(|e| e.into_inner()) = Some(f);
    }

    pub fn models_dir(&self) -> PathBuf {
        self.data.join("models")
    }

    fn partial_dir(&self) -> PathBuf {
        self.models_dir().join(".partial")
    }

    fn part_path(&self, name: &str) -> PathBuf {
        self.partial_dir().join(format!("{name}.part"))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, Inner> {
        self.inner.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn host_ok(&self, url: &str) -> bool {
        let Some(p) = fetch::parse_url(url) else { return false };
        if self.allow_loopback.load(Ordering::Relaxed) && fetch::is_loopback(&p.host) {
            return true;
        }
        let h = p.host.as_str();
        p.https
            && matches!(p.port, None | Some(443))
            && (matches!(h, "huggingface.co" | "data.cached.info" | "cache.echo6.co") || h.ends_with(".huggingface.co") || h.ends_with(".hf.co"))
    }

    fn parse(&self, body: &[u8]) -> Result<Request, ApiErr> {
        let v: Value = serde_json::from_slice(body).map_err(|_| err(400, "bad_request", "the body is not JSON"))?;
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
        let name = s("name").ok_or_else(|| err(400, "bad_request", "a file name is needed"))?;
        if !valid_model_id(&name) || name == self.embed_file {
            return Err(err(400, "bad_model", "that is not a model file name"));
        }
        let size = v.get("size").and_then(Value::as_u64).unwrap_or(0);
        let sha256 = s("sha256").filter(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()));
        let url = if let Some(repo) = s("repo").filter(|r| !r.is_empty()) {
            let rev = s("revision").unwrap_or_else(|| "main".into());
            let path = s("path").unwrap_or_else(|| name.clone());
            let parts: Vec<&str> = repo.split('/').collect();
            if parts.len() != 2 || !parts.iter().all(|p| plain(p)) || !plain(&rev) {
                return Err(err(400, "bad_request", "that is not a Hugging Face repository"));
            }
            let segs: Vec<&str> = path.split('/').collect();
            if segs.iter().any(|g| g.is_empty() || *g == "." || *g == ".." || g.bytes().any(|b| b < 0x20 || b == b'\\')) {
                return Err(err(400, "bad_request", "that is not a file path"));
            }
            let enc: Vec<String> = segs.iter().map(|g| pct(g)).collect();
            format!("https://huggingface.co/{repo}/resolve/{rev}/{}", enc.join("/"))
        } else {
            s("url").ok_or_else(|| err(400, "bad_request", "a repository or an address is needed"))?
        };
        if !self.host_ok(&url) {
            return Err(err(403, "host_not_allowed", "The server downloads models only from Hugging Face and Cache's own address."));
        }
        Ok(Request { name, url, size, sha256: sha256.map(|h| h.to_ascii_lowercase()), search: v.get("search").and_then(Value::as_bool).unwrap_or(false) })
    }

    /// `POST /api/models/downloads`: queue a download (or continue a paused or stopped one) and start the worker.
    pub fn add(self: &Arc<Self>, body: &[u8]) -> Result<Value, ApiErr> {
        let r = self.parse(body)?;
        if std::fs::metadata(self.models_dir().join(&r.name)).map(|m| m.is_file() && (r.size == 0 || m.len() == r.size)).unwrap_or(false) {
            return Err(err(409, "already_there", "That model is already on the server."));
        }
        {
            let mut g = self.lock();
            g.jobs.retain(|j| j.state != State::Done);
            if let Some(j) = g.jobs.iter_mut().find(|j| j.name == r.name) {
                // asked again: a paused or failed one goes back in the queue; one that is queued or running stays as it is
                if matches!(j.state, State::Paused | State::Failed) {
                    j.state = State::Queued;
                    j.error = None;
                    j.ctl.store(RUN, Ordering::SeqCst);
                    j.search |= r.search;
                }
            } else {
                let done = std::fs::metadata(self.part_path(&r.name)).map(|m| m.len()).unwrap_or(0);
                g.jobs.push(Job {
                    name: r.name,
                    url: r.url,
                    size: r.size,
                    sha256: r.sha256,
                    search: r.search,
                    state: State::Queued,
                    verifying: false,
                    done,
                    total: r.size,
                    error: None,
                    ctl: Arc::new(AtomicU8::new(RUN)),
                });
            }
        }
        self.kick();
        Ok(self.list(None))
    }

    fn kick(self: &Arc<Self>) {
        {
            let mut g = self.lock();
            if g.worker || !g.jobs.iter().any(|j| j.state == State::Queued) {
                return;
            }
            g.worker = true;
        }
        let me = self.clone();
        std::thread::spawn(move || me.work());
    }

    fn work(self: Arc<Self>) {
        loop {
            let (name, url, size, sha, ctl) = {
                let mut g = self.lock();
                let Some(j) = g.jobs.iter_mut().find(|j| j.state == State::Queued) else {
                    g.worker = false;
                    return;
                };
                j.state = State::Running;
                j.error = None;
                j.verifying = false;
                (j.name.clone(), j.url.clone(), j.size, j.sha256.clone(), j.ctl.clone())
            };
            let res = self.download(&name, &url, size, sha.as_deref(), &ctl);
            let mut follow = false;
            {
                let mut g = self.lock();
                let at = g.jobs.iter().position(|j| j.name == name);
                if let Some(i) = at {
                    g.jobs[i].verifying = false;
                    match res {
                        Ok(()) => {
                            g.jobs[i].state = State::Done;
                            g.jobs[i].done = g.jobs[i].total;
                            follow = g.jobs[i].search;
                        }
                        Err(Stop::Paused) if ctl.load(Ordering::SeqCst) == DISCARD => {
                            g.jobs.remove(i);
                            let _ = std::fs::remove_file(self.part_path(&name));
                        }
                        Err(Stop::Paused) => g.jobs[i].state = State::Paused,
                        Err(Stop::Failed(m)) => {
                            g.jobs[i].state = State::Failed;
                            g.jobs[i].error = Some(m);
                        }
                    }
                }
            }
            if follow {
                let hook = self.after.lock().unwrap_or_else(|e| e.into_inner()).clone();
                if let Some(h) = hook {
                    h();
                }
            }
        }
    }

    fn progress(&self, name: &str, done: u64, total: u64, verifying: bool) {
        let mut g = self.lock();
        if let Some(j) = g.jobs.iter_mut().find(|j| j.name == name) {
            j.done = done;
            j.total = total;
            j.verifying = verifying;
        }
    }

    fn download(&self, name: &str, url: &str, expect: u64, sha: Option<&str>, ctl: &AtomicU8) -> Result<(), Stop> {
        let dir = self.partial_dir();
        std::fs::create_dir_all(&dir).map_err(|e| Stop::msg(format!("Could not make {}: {e}", dir.display())))?;
        let part = self.part_path(name);
        let agent = fetch::agent();
        let mut have = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
        if expect > 0 && have > expect {
            let _ = std::fs::remove_file(&part);
            have = 0;
        }
        let mut restarted = false;
        let mut cur = url.to_string();
        let mut hops = 0;
        let (body, start, total) = loop {
            if ctl.load(Ordering::SeqCst) != RUN {
                return Err(Stop::Paused);
            }
            if !self.host_ok(&cur) {
                return Err(Stop::msg("The download was sent to an address the server does not download from."));
            }
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
                        return Err(Stop::msg("The download server would not continue the file."));
                    }
                    let _ = std::fs::remove_file(&part);
                    have = 0;
                    restarted = true;
                    continue;
                }
                Err(ureq::Error::Status(code, _)) if code == 401 || code == 403 => {
                    return Err(Stop::msg("This model needs a Hugging Face account to download. Get it in a browser, then use \"Choose a file\"."));
                }
                Err(ureq::Error::Status(code, _)) => return Err(Stop::msg(format!("The download server answered {code}."))),
                Err(e) => return Err(Stop::msg(format!("The connection failed: {e}"))),
            };
            let status = resp.status();
            if matches!(status, 301 | 302 | 303 | 307 | 308) {
                hops += 1;
                let loc = resp.header("location").filter(|_| hops <= 8).ok_or_else(|| Stop::msg("The download server redirected too many times."))?;
                cur = fetch::resolve(&cur, loc).ok_or_else(|| Stop::msg("The download server sent a bad redirect."))?;
                continue;
            }
            match status {
                206 => {
                    let cr = resp.header("content-range").unwrap_or("").to_string();
                    let from = cr.strip_prefix("bytes ").and_then(|r| r.split('-').next()).and_then(|s| s.trim().parse::<u64>().ok());
                    if from != Some(have) {
                        return Err(Stop::msg("The download server continued from the wrong place. Try again."));
                    }
                    let total = cr.rsplit('/').next().and_then(|t| t.trim().parse::<u64>().ok()).unwrap_or(expect);
                    break (Some(resp.into_reader()), have, total);
                }
                200 => {
                    let total = resp.header("content-length").and_then(|t| t.parse::<u64>().ok()).unwrap_or(expect);
                    break (Some(resp.into_reader()), 0, total);
                }
                other => return Err(Stop::msg(format!("The download server answered {other}."))),
            }
        };
        if expect > 0 && total != expect {
            return Err(Stop::msg("The file on the server is not the size the list says."));
        }
        let margin = (total / 20).max(64 << 20);
        if let Some(avail) = free_bytes(&dir) {
            let needed = total.saturating_sub(start) + margin;
            if avail < needed {
                return Err(Stop::msg(format!("Not enough free space on the server: {} MB needed, {} MB free.", needed >> 20, avail >> 20)));
            }
        }
        if let Some(mut reader) = body {
            let mut f = if start == 0 { std::fs::File::create(&part) } else { std::fs::OpenOptions::new().append(true).open(&part) }
                .map_err(|e| Stop::msg(format!("Could not write the file: {e}")))?;
            let mut buf = vec![0u8; 256 << 10];
            let mut done = start;
            let mut last = Instant::now();
            self.progress(name, done, total, false);
            loop {
                if ctl.load(Ordering::SeqCst) != RUN {
                    let _ = f.sync_all();
                    return Err(Stop::Paused);
                }
                let n = reader.read(&mut buf).map_err(|e| Stop::msg(format!("The connection failed: {e}")))?;
                if n == 0 {
                    break;
                }
                f.write_all(&buf[..n]).map_err(|e| Stop::msg(format!("Could not write the file: {e}")))?;
                done += n as u64;
                if last.elapsed() >= Duration::from_millis(250) {
                    last = Instant::now();
                    self.progress(name, done, total, false);
                }
            }
            f.sync_all().map_err(|e| Stop::msg(format!("Could not write the file: {e}")))?;
            self.progress(name, done, total, false);
        }
        let size = std::fs::metadata(&part).map_err(|e| Stop::msg(e.to_string()))?.len();
        if size != total {
            if size > total {
                let _ = std::fs::remove_file(&part);
            }
            return Err(Stop::msg(format!("The download stopped early ({} of {} MB). Resume it to continue.", size >> 20, total >> 20)));
        }
        if let Some(want) = sha {
            self.progress(name, size, total, true);
            let got = sha256_file(&part, ctl)?;
            if !got.eq_ignore_ascii_case(want) {
                let _ = std::fs::remove_file(&part);
                return Err(Stop::msg("The file did not match its published checksum, so it was thrown away. Try again."));
            }
        }
        std::fs::rename(&part, self.models_dir().join(name)).map_err(|e| Stop::msg(format!("Could not put the file in place: {e}")))?;
        Ok(())
    }

    /// `POST /api/models/downloads/<name>/pause`.
    pub fn pause(self: &Arc<Self>, name: &str) -> Result<Value, ApiErr> {
        {
            let mut g = self.lock();
            let j = g.jobs.iter_mut().find(|j| j.name == name).ok_or_else(|| err(404, "not_found", "no such download"))?;
            match j.state {
                State::Queued => j.state = State::Paused,
                State::Running => j.ctl.store(PAUSE, Ordering::SeqCst),
                _ => {}
            }
        }
        Ok(self.list(None))
    }

    /// `POST /api/models/downloads/<name>/resume`: a paused or failed download goes back in the queue. A download that is only a
    /// part file (after a restart) needs the request again (`add`); the app sends it.
    pub fn resume(self: &Arc<Self>, name: &str) -> Result<Value, ApiErr> {
        {
            let mut g = self.lock();
            let j = g.jobs.iter_mut().find(|j| j.name == name).ok_or_else(|| err(404, "not_found", "no such download; ask for it again"))?;
            if matches!(j.state, State::Paused | State::Failed) {
                j.state = State::Queued;
                j.error = None;
                j.ctl.store(RUN, Ordering::SeqCst);
            }
        }
        self.kick();
        Ok(self.list(None))
    }

    /// `DELETE /api/models/downloads/<name>`: stops it and throws away what it saved.
    pub fn remove(self: &Arc<Self>, name: &str) -> Result<Value, ApiErr> {
        if !valid_model_id(name) {
            return Err(err(400, "bad_model", "that is not a model file name"));
        }
        {
            let mut g = self.lock();
            if let Some(i) = g.jobs.iter().position(|j| j.name == name) {
                if g.jobs[i].state == State::Running {
                    g.jobs[i].ctl.store(DISCARD, Ordering::SeqCst);
                    drop(g);
                    return Ok(self.list(None));
                }
                g.jobs.remove(i);
            }
        }
        let _ = std::fs::remove_file(self.part_path(name));
        Ok(self.list(None))
    }

    /// The downloads as `GET /api/models/downloads` answers: the jobs, the part files nobody is running, and (when given) the
    /// embedder's own download from `embed::status()`.
    pub fn list(&self, embedder: Option<&Value>) -> Value {
        let g = self.lock();
        let mut out: Vec<Value> = g
            .jobs
            .iter()
            .map(|j| {
                let mut v = json!({"name": j.name, "state": j.state.word(j.verifying), "done": j.done, "total": j.total});
                if let Some(e) = &j.error {
                    v["error"] = json!(e);
                }
                v
            })
            .collect();
        if let Ok(rd) = std::fs::read_dir(self.partial_dir()) {
            for e in rd.flatten() {
                let file = e.file_name().to_string_lossy().into_owned();
                let Some(name) = file.strip_suffix(".part") else { continue };
                if name.ends_with(".upload") || g.jobs.iter().any(|j| j.name == name) || !valid_model_id(name) {
                    continue;
                }
                if let Ok(m) = e.metadata() {
                    out.push(json!({"name": name, "state": "paused", "done": m.len(), "total": 0}));
                }
            }
        }
        if let Some(e) = embedder {
            let word = match e["state"].as_str() {
                Some("downloading") => Some("running"),
                Some("error") => Some("failed"),
                _ => None,
            };
            if let (Some(w), Some(f)) = (word, e["file"].as_str()) {
                let mut v = json!({"name": f, "state": w, "done": e["bytes"].as_u64().unwrap_or(0), "total": e["total"].as_u64().unwrap_or(0)});
                if let Some(m) = e["error"].as_str() {
                    v["error"] = json!(m);
                }
                out.push(v);
            }
        }
        json!({"downloads": out})
    }

    /// `POST /api/models/upload?name=<x.gguf>`: stream the body to a part file, then rename it into the models folder.
    pub async fn upload<B>(self: &Arc<Self>, query: &str, content_length: Option<u64>, mut body: B) -> Result<Value, ApiErr>
    where
        B: Body<Data = Bytes> + Unpin,
        B::Error: std::fmt::Display,
    {
        let name = fetch::query_param(query, "name").ok_or_else(|| err(400, "invalid_name", "A file name is needed."))?;
        if !valid_model_id(&name) || name == self.embed_file {
            return Err(err(400, "invalid_name", "A model file is a name ending in .gguf."));
        }
        if self.lock().jobs.iter().any(|j| j.name == name && matches!(j.state, State::Queued | State::Running)) {
            return Err(err(409, "busy", "That model is downloading now."));
        }
        let len = content_length.ok_or_else(|| err(411, "length_required", "The upload needs a Content-Length."))?;
        let dir = self.partial_dir();
        std::fs::create_dir_all(&dir).map_err(|e| err(500, "server_error", format!("could not make the upload folder: {e}")))?;
        if let Some(avail) = free_bytes(&dir) {
            if avail < len.saturating_add(HEADROOM) {
                return Err(err(507, "no_space", format!("Not enough free space on the server: {} MB needed (and 1 GB to spare), {} MB free.", len >> 20, avail >> 20)));
            }
        }
        let part = dir.join(format!("{name}.upload.part"));
        let mut guard = PartGuard(Some(part.clone()));
        let werr = |e: std::io::Error| {
            if matches!(e.raw_os_error(), Some(28) | Some(112)) {
                err(507, "no_space", "The server ran out of space during the upload.")
            } else {
                err(500, "server_error", format!("could not write the upload: {e}"))
            }
        };
        let mut f = tokio::fs::File::create(&part).await.map_err(werr)?;
        let mut got = 0u64;
        while let Some(frame) = body.frame().await {
            let frame = frame.map_err(|e| err(400, "upload_interrupted", format!("the upload was cut off: {e}")))?;
            if let Ok(data) = frame.into_data() {
                got += data.len() as u64;
                if got > len {
                    return Err(err(400, "invalid", "the body is longer than its Content-Length"));
                }
                f.write_all(&data).await.map_err(werr)?;
            }
        }
        if got != len {
            return Err(err(400, "upload_interrupted", "the upload ended before its Content-Length"));
        }
        f.flush().await.map_err(werr)?;
        f.sync_all().await.map_err(werr)?;
        drop(f);
        tokio::fs::rename(&part, self.models_dir().join(&name)).await.map_err(werr)?;
        guard.0 = None;
        Ok(json!({"name": name, "bytes": got}))
    }
}

struct PartGuard(Option<PathBuf>);

impl Drop for PartGuard {
    fn drop(&mut self) {
        if let Some(p) = self.0.take() {
            let _ = std::fs::remove_file(p);
        }
    }
}

enum Stop {
    Paused,
    Failed(String),
}

impl Stop {
    fn msg(m: impl Into<String>) -> Stop {
        Stop::Failed(m.into())
    }
}

fn sha256_file(path: &Path, ctl: &AtomicU8) -> Result<String, Stop> {
    let io = |e: std::io::Error| Stop::msg(format!("Could not read the file: {e}"));
    let mut f = std::fs::File::open(path).map_err(io)?;
    let mut ctx = digest::Context::new(&digest::SHA256);
    let mut buf = vec![0u8; 1 << 20];
    loop {
        if ctl.load(Ordering::SeqCst) == DISCARD {
            return Err(Stop::Paused);
        }
        let n = f.read(&mut buf).map_err(io)?;
        if n == 0 {
            break;
        }
        ctx.update(&buf[..n]);
    }
    Ok(ctx.finish().as_ref().iter().map(|b| format!("{b:02x}")).collect())
}

/// The host's memory as the phone's `MemoryReading` has it (bytes): `total` and `avail` (MemAvailable). `None` when `meminfo`
/// (the text of /proc/meminfo) has neither.
pub fn memory_from(meminfo: &str) -> Option<Value> {
    let kb = |key: &str| {
        meminfo.lines().find_map(|l| {
            let rest = l.strip_prefix(key)?.strip_prefix(':')?;
            rest.split_whitespace().next()?.parse::<u64>().ok()
        })
    };
    let total = kb("MemTotal")?.checked_mul(1024)?;
    let avail = kb("MemAvailable")?.checked_mul(1024)?;
    (total > 0).then(|| json!({"total": total, "avail": avail.min(total), "threshold": 0, "low": false}))
}

/// `GET /api/system/memory`.
pub fn memory() -> Result<Value, ApiErr> {
    let text = std::fs::read_to_string("/proc/meminfo").map_err(|_| err(503, "memory_unknown", "this server cannot read its memory"))?;
    memory_from(&text).ok_or_else(|| err(503, "memory_unknown", "this server cannot read its memory"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;
    use std::net::TcpListener;

    fn jobs(d: &TempDir) -> Arc<ModelJobs> {
        let j = ModelJobs::new(d.0.clone(), "bge-m3-Q8_0.gguf".into());
        j.allow_loopback.store(true, Ordering::Relaxed);
        std::fs::create_dir_all(d.0.join("models")).unwrap();
        j
    }

    fn sha(b: &[u8]) -> String {
        digest::digest(&digest::SHA256, b).as_ref().iter().map(|x| format!("{x:02x}")).collect()
    }

    /// A one-file origin on this machine that honors `Range`.
    fn origin(body: Vec<u8>) -> String {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        std::thread::spawn(move || {
            for s in l.incoming() {
                let Ok(mut s) = s else { continue };
                let mut req = vec![0u8; 4096];
                let n = s.read(&mut req).unwrap_or(0);
                let head = String::from_utf8_lossy(&req[..n]).to_string();
                let from = head
                    .lines()
                    .find_map(|l| l.to_ascii_lowercase().strip_prefix("range: bytes=").map(|r| r.trim_end_matches('-').parse::<usize>().unwrap_or(0)))
                    .unwrap_or(0);
                let rest = &body[from..];
                let resp = if from > 0 {
                    format!("HTTP/1.1 206 Partial Content\r\nContent-Range: bytes {from}-{}/{}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len() - 1, body.len(), rest.len())
                } else {
                    format!("HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", rest.len())
                };
                let _ = s.write_all(resp.as_bytes());
                let _ = s.write_all(rest);
            }
        });
        format!("http://127.0.0.1:{port}/model.gguf")
    }

    fn wait_for(j: &ModelJobs, name: &str, state: &str) -> Value {
        for _ in 0..200 {
            let l = j.list(None);
            if let Some(e) = l["downloads"].as_array().unwrap().iter().find(|e| e["name"] == name) {
                if e["state"] == state {
                    return e.clone();
                }
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        panic!("{name} never became {state}: {}", j.list(None));
    }

    fn req(name: &str, url: &str, size: usize, sha: &str) -> Vec<u8> {
        json!({"name": name, "url": url, "size": size, "sha256": sha}).to_string().into_bytes()
    }

    #[test]
    fn a_download_runs_resumes_and_is_checked() {
        let d = TempDir::new("models-dl");
        let j = jobs(&d);
        let body: Vec<u8> = (0..300_000u32).map(|i| (i * 31 % 251) as u8).collect();
        let url = origin(body.clone());
        // a part file from an earlier try continues
        std::fs::create_dir_all(d.0.join("models/.partial")).unwrap();
        std::fs::write(d.0.join("models/.partial/m.gguf.part"), &body[..100_000]).unwrap();
        let l = j.list(None);
        assert_eq!(l["downloads"][0]["state"], "paused");
        assert_eq!(l["downloads"][0]["done"], 100_000);
        j.add(&req("m.gguf", &url, body.len(), &sha(&body))).unwrap();
        wait_for(&j, "m.gguf", "done");
        assert_eq!(std::fs::read(d.0.join("models/m.gguf")).unwrap(), body);
        assert!(!d.0.join("models/.partial/m.gguf.part").exists());
        // asking again for what is there is refused
        assert_eq!(j.add(&req("m.gguf", &url, body.len(), &sha(&body))).unwrap_err().status, 409);
    }

    #[test]
    fn a_wrong_checksum_throws_the_file_away() {
        let d = TempDir::new("models-sha");
        let j = jobs(&d);
        let body = vec![7u8; 5000];
        let url = origin(body.clone());
        j.add(&req("bad.gguf", &url, body.len(), &"0".repeat(64))).unwrap();
        let e = wait_for(&j, "bad.gguf", "failed");
        assert!(e["error"].as_str().unwrap().contains("checksum"));
        assert!(!d.0.join("models/bad.gguf").exists());
        assert!(!d.0.join("models/.partial/bad.gguf.part").exists());
    }

    #[test]
    fn a_queued_download_pauses_resumes_and_is_removed() {
        let d = TempDir::new("models-queue");
        let j = jobs(&d);
        // a refused address never reaches the worker; a queued job is held by hand
        {
            let mut g = j.lock();
            g.worker = true; // no worker runs, so the job stays queued
            g.jobs.push(Job { name: "q.gguf".into(), url: "http://127.0.0.1:1/x".into(), size: 1, sha256: None, search: false, state: State::Queued, verifying: false, done: 0, total: 1, error: None, ctl: Arc::new(AtomicU8::new(RUN)) });
        }
        j.pause("q.gguf").unwrap();
        assert_eq!(j.list(None)["downloads"][0]["state"], "paused");
        j.resume("q.gguf").unwrap();
        assert_eq!(j.list(None)["downloads"][0]["state"], "queued");
        j.remove("q.gguf").unwrap();
        assert_eq!(j.list(None)["downloads"].as_array().unwrap().len(), 0);
        assert_eq!(j.pause("nope.gguf").unwrap_err().status, 404);
    }

    #[test]
    fn only_hugging_face_and_cache_addresses_are_downloaded() {
        let d = TempDir::new("models-hosts");
        let j = ModelJobs::new(d.0.clone(), "bge-m3-Q8_0.gguf".into());
        for url in ["https://evil.example/a.gguf", "http://huggingface.co/a.gguf", "https://huggingface.co.evil.example/a.gguf", "http://127.0.0.1:9/a.gguf", "https://huggingface.co:8443/a.gguf"] {
            let body = json!({"name": "a.gguf", "url": url, "size": 1}).to_string();
            assert_eq!(j.add(body.as_bytes()).unwrap_err().status, 403, "{url}");
        }
        assert!(j.host_ok("https://cdn-lfs.huggingface.co/x"));
        assert!(j.host_ok("https://cas-bridge.xethub.hf.co/x"));
        assert!(j.host_ok("https://data.cached.info/models/a.gguf"));
        assert!(!j.host_ok("https://hf.co.evil.example/x"));
        // names and repositories are checked
        for body in [
            json!({"name": "../a.gguf", "url": "https://data.cached.info/a"}),
            json!({"name": "a.bin", "url": "https://data.cached.info/a"}),
            json!({"name": "bge-m3-Q8_0.gguf", "url": "https://data.cached.info/a"}),
            json!({"name": "a.gguf", "repo": "one-part", "path": "a.gguf"}),
            json!({"name": "a.gguf", "repo": "a/b", "revision": "../x", "path": "a.gguf"}),
            json!({"name": "a.gguf", "repo": "a/b", "path": "../a.gguf"}),
            json!({"name": "a.gguf"}),
        ] {
            assert_eq!(j.add(body.to_string().as_bytes()).unwrap_err().status / 100, 4, "{body}");
        }
        assert_eq!(j.add(b"nope").unwrap_err().status, 400);
        // a Hugging Face file gets its address from repo, revision and path
        let r = j.parse(json!({"name": "a b.gguf", "repo": "o/n", "revision": "abc", "path": "dir/a b.gguf", "size": 3}).to_string().as_bytes()).unwrap();
        assert_eq!(r.url, "https://huggingface.co/o/n/resolve/abc/dir/a%20b.gguf");
    }

    #[test]
    fn the_embedder_is_listed_beside_the_downloads() {
        let d = TempDir::new("models-embed");
        let j = jobs(&d);
        let e = json!({"state": "downloading", "bytes": 5, "total": 10, "file": "bge-m3-Q8_0.gguf"});
        let l = j.list(Some(&e));
        assert_eq!(l["downloads"][0], json!({"name": "bge-m3-Q8_0.gguf", "state": "running", "done": 5, "total": 10}));
        assert_eq!(j.list(Some(&json!({"state": "ready", "file": "x.gguf"})))["downloads"].as_array().unwrap().len(), 0);
    }

    #[tokio::test]
    async fn an_upload_is_streamed_into_the_models_folder() {
        use http_body_util::Full;
        let d = TempDir::new("models-up");
        let j = jobs(&d);
        let body = vec![9u8; 70_000];
        let r = j.upload("name=up.gguf", Some(body.len() as u64), Full::new(Bytes::from(body.clone()))).await.unwrap();
        assert_eq!(r["bytes"], 70_000);
        assert_eq!(std::fs::read(d.0.join("models/up.gguf")).unwrap(), body);
        assert!(!d.0.join("models/.partial/up.gguf.upload.part").exists());
        let short = j.upload("name=s.gguf", Some(10), Full::new(Bytes::from(vec![1u8; 5]))).await.unwrap_err();
        assert_eq!(short.code, "upload_interrupted");
        assert!(!d.0.join("models/s.gguf").exists());
        assert!(!d.0.join("models/.partial/s.gguf.upload.part").exists());
        assert_eq!(j.upload("name=x.txt", Some(1), Full::new(Bytes::from(vec![1u8]))).await.unwrap_err().status, 400);
        assert_eq!(j.upload("name=bge-m3-Q8_0.gguf", Some(1), Full::new(Bytes::from(vec![1u8]))).await.unwrap_err().status, 400);
        assert_eq!(j.upload("name=y.gguf", None, Full::new(Bytes::new())).await.unwrap_err().status, 411);
    }

    #[test]
    fn memory_is_read_from_meminfo() {
        let m = memory_from("MemTotal:       16000000 kB\nMemFree: 100 kB\nMemAvailable:    8000000 kB\n").unwrap();
        assert_eq!(m, json!({"total": 16_384_000_000u64, "avail": 8_192_000_000u64, "threshold": 0, "low": false}));
        assert!(memory_from("MemTotal: 5 kB\n").is_none());
        assert!(memory_from("").is_none());
    }
}
