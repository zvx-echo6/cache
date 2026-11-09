//! The chat model on the server, for the browser build of the app: `/api/llm/*`, protocol version 1 (written down in
//! server/docs/llm-protocol.md). The browser runs the whole Ask loop (prompt, tools, citations) itself; only the model runs here.
//!
//! The protocol mirrors the app's native session, packages/cache_llama/lib/llama_session_io.dart: `load` is `cl_load` + `cl_info`,
//! `generate` is `cl_start`, then `cl_next` until -1 with `cl_partial` after each token, then `cl_finish` (see [`run_generation`]),
//! with `max_tokens` counted by this layer (`cl_generated_tokens`) exactly as the app counts it, and `stop` is `cl_stop`.
//!
//! One model is loaded for the whole server and one generation runs at a time ([`GenQueue`]); the others wait their turn and are told
//! their place. Loading and generating are blocking (llama.cpp), so they run on worker threads, never on the async threads.

use crate::library::ApiErr;
use cache_embed::chat::{ChatModel, CHAT_DEFAULT_N_CTX};
use hyper::body::Bytes;
use serde_json::{json, Map, Value};
use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

/// The protocol version every request carries as `"v"`.
pub const PROTOCOL_VERSION: i64 = 1;
/// How many generations may wait behind the running one; more get 429.
pub const MAX_WAITING: usize = 8;
/// The largest `generate` body, in bytes (a long conversation with tool results).
pub const MAX_GENERATE_BODY: usize = 16 << 20;
/// How long one event may wait for a client that has stopped reading (but keeps the connection open) before it counts as gone.
pub const SEND_TIMEOUT: Duration = Duration::from_secs(30);
/// The range of `n_ctx` a client may ask for.
pub const N_CTX_RANGE: std::ops::RangeInclusive<i64> = 256..=262_144;
/// The message the app shows when `cl_next` fails (llama_session_io.dart).
const GENERATION_FAILED: &str = "The model stopped with an error while answering";
/// What the app uses when `cl_finish` fails (llama_session_io.dart `readJson`).
const EMPTY_MESSAGE: &str = r#"{"role":"assistant","content":""}"#;

fn err(status: u16, code: &'static str, message: impl Into<String>) -> ApiErr {
    ApiErr { status, code, message: message.into() }
}

// ---------------------------------------------------------------- the model, as the generation loop sees it

/// The native chat calls (`ChatModel` is the real one; the tests use a fake).
pub trait ChatBackend: Send + Sync {
    fn start(&self, request_json: &str) -> Result<(), String>;
    /// `cl_next`: byte count of the token, -1 finished, -2 error.
    fn next(&self) -> i32;
    fn partial(&self) -> Option<String>;
    fn finish(&self) -> Option<String>;
    fn prompt_tokens(&self) -> i32;
    fn generated_tokens(&self) -> i32;
    fn stop(&self);
}

impl ChatBackend for ChatModel {
    fn start(&self, r: &str) -> Result<(), String> {
        ChatModel::start(self, r)
    }
    fn next(&self) -> i32 {
        ChatModel::next(self)
    }
    fn partial(&self) -> Option<String> {
        ChatModel::partial(self)
    }
    fn finish(&self) -> Option<String> {
        ChatModel::finish(self)
    }
    fn prompt_tokens(&self) -> i32 {
        ChatModel::prompt_tokens(self)
    }
    fn generated_tokens(&self) -> i32 {
        ChatModel::generated_tokens(self)
    }
    fn stop(&self) {
        ChatModel::stop(self)
    }
}

/// Loads a model file: the backend and the `cl_info` JSON, or the reason.
pub type Loader = dyn Fn(&Path, i32) -> Result<(Arc<dyn ChatBackend>, String), String> + Send + Sync;

// ---------------------------------------------------------------- the queue

struct QState {
    running: bool,
    waiting: VecDeque<u64>,
}

/// One generation (or load) at a time, in arrival order.
pub struct GenQueue {
    st: Mutex<QState>,
    cv: Condvar,
    next_id: AtomicU64,
}

/// Why [`GenQueue::acquire`] gave no turn.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum Denied {
    /// The caller went away while waiting (or before it started).
    Cancelled,
    /// [`MAX_WAITING`] generations are already waiting.
    Busy,
}

/// The right to run; dropping it passes the turn on.
pub struct Turn<'a>(&'a GenQueue);

impl Drop for Turn<'_> {
    fn drop(&mut self) {
        let mut st = self.0.st.lock().unwrap_or_else(|e| e.into_inner());
        st.running = false;
        self.0.cv.notify_all();
    }
}

impl Default for GenQueue {
    fn default() -> Self {
        GenQueue { st: Mutex::new(QState { running: false, waiting: VecDeque::new() }), cv: Condvar::new(), next_id: AtomicU64::new(1) }
    }
}

impl GenQueue {
    /// How many are waiting (not counting the running one).
    pub fn waiting(&self) -> usize {
        self.st.lock().unwrap_or_else(|e| e.into_inner()).waiting.len()
    }

    /// Wait for the turn. `on_position(n)` is called when the caller has to wait, and again whenever its place changes; n is the
    /// number of generations ahead of it (the running one counts), so 1 means "next". `cancelled` is polled while waiting, and
    /// first of all on every pass (under the queue lock, right before a turn would be handed out): when it says true the caller
    /// leaves the queue and gets [`Denied::Cancelled`], even from the front. When [`MAX_WAITING`] are already waiting, a caller
    /// that would have to wait gets [`Denied::Busy`]; the check is made under the queue lock.
    pub fn acquire(&self, mut on_position: impl FnMut(usize), cancelled: impl Fn() -> bool) -> Result<Turn<'_>, Denied> {
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let mut st = self.st.lock().unwrap_or_else(|e| e.into_inner());
        if (st.running || !st.waiting.is_empty()) && st.waiting.len() >= MAX_WAITING {
            return Err(Denied::Busy);
        }
        st.waiting.push_back(id);
        let mut told: Option<usize> = None;
        loop {
            if cancelled() {
                st.waiting.retain(|w| *w != id);
                self.cv.notify_all();
                return Err(Denied::Cancelled);
            }
            if !st.running && st.waiting.front() == Some(&id) {
                st.waiting.pop_front();
                st.running = true;
                return Ok(Turn(self));
            }
            let ahead = st.waiting.iter().position(|w| *w == id).unwrap_or(0) + usize::from(st.running);
            if told != Some(ahead) {
                told = Some(ahead);
                // not under the lock: the callback may block on a slow client
                drop(st);
                on_position(ahead);
                st = self.st.lock().unwrap_or_else(|e| e.into_inner());
                continue;
            }
            st = self.cv.wait_timeout(st, Duration::from_millis(200)).unwrap_or_else(|e| e.into_inner()).0;
        }
    }
}

// ---------------------------------------------------------------- requests

/// `"v"` must be 1.
pub fn check_version(v: &Value) -> Result<(), ApiErr> {
    match v.get("v").and_then(Value::as_i64) {
        Some(PROTOCOL_VERSION) => Ok(()),
        Some(other) => Err(err(400, "unsupported_version", format!("protocol version {other} is not supported; this server speaks version {PROTOCOL_VERSION}"))),
        None => Err(err(400, "unsupported_version", format!("\"v\" is required; this server speaks protocol version {PROTOCOL_VERSION}"))),
    }
}

fn parse_body(body: &[u8]) -> Result<Value, ApiErr> {
    let v: Value = serde_json::from_slice(body).map_err(|_| err(400, "bad_json", "the body is not JSON"))?;
    if !v.is_object() {
        return Err(err(400, "bad_json", "the body must be a JSON object"));
    }
    check_version(&v)?;
    Ok(v)
}

/// A model id is a bare file name of a `.gguf` in the models folder: never a path.
pub fn valid_model_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= 255
        && !id.contains(['/', '\\', '\0'])
        && !id.contains("..")
        && !id.starts_with('.')
        && id.to_ascii_lowercase().ends_with(".gguf")
}

/// The body of `POST /api/llm/load` or `stop`: `{"v":1}`.
pub fn parse_version_only(body: &[u8]) -> Result<(), ApiErr> {
    parse_body(body).map(|_| ())
}

/// The body of `POST /api/llm/stop`: `{"v":1}`, with the `id` of one generation when only that one is to be stopped.
pub fn parse_stop(body: &[u8]) -> Result<Option<String>, ApiErr> {
    let v = parse_body(body)?;
    match v.get("id") {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => Ok(Some(s.clone())),
        Some(_) => Err(err(400, "bad_json", "id must be a string")),
    }
}

/// `POST /api/llm/load` body: the model id and `n_ctx` (default 8192, as `LlamaSession.load`).
pub fn parse_load(body: &[u8]) -> Result<(String, i32), ApiErr> {
    let v = parse_body(body)?;
    let id = v["model"].as_str().ok_or_else(|| err(400, "bad_json", "\"model\" (a model id from /api/llm/models) is required"))?;
    if !valid_model_id(id) {
        return Err(err(400, "bad_model", "that is not a model id"));
    }
    let n_ctx = match &v["n_ctx"] {
        Value::Null => CHAT_DEFAULT_N_CTX as i64,
        n => n.as_i64().filter(|n| N_CTX_RANGE.contains(n)).ok_or_else(|| err(400, "bad_json", format!("\"n_ctx\" must be a whole number from {} to {}", N_CTX_RANGE.start(), N_CTX_RANGE.end())))?,
    };
    Ok((id.to_string(), n_ctx as i32))
}

/// `POST /api/llm/generate` body: the request map exactly as `LlamaSession.generate` takes it, and the optional `model` id
/// (beside `v` and `request`) the client believes is loaded.
pub fn parse_generate(body: &[u8]) -> Result<(Option<String>, Value), ApiErr> {
    let v = parse_body(body)?;
    let model = match v.get("model") {
        None | Some(Value::Null) => None,
        Some(Value::String(m)) => Some(m.clone()),
        Some(_) => return Err(err(400, "bad_json", "\"model\" must be a model id")),
    };
    match v.get("request") {
        Some(r) if r.is_object() => Ok((model, r.clone())),
        _ => Err(err(400, "bad_json", "\"request\" (the generate request object) is required")),
    }
}

/// The token cap of a request: llama_session_io.dart takes `max_tokens` only when it is an int above 0.
pub fn max_tokens_of(request: &Value) -> Option<i64> {
    request.get("max_tokens").and_then(Value::as_i64).filter(|m| *m > 0)
}

// ---------------------------------------------------------------- events

/// One NDJSON line.
pub fn event_line(v: &Value) -> Bytes {
    let mut s = v.to_string();
    s.push('\n');
    Bytes::from(s)
}

pub fn queued_event(position: usize) -> Value {
    json!({"type": "queued", "position": position})
}

/// The first event of a generation that has its turn and has been started: the id that `POST /api/llm/stop` takes.
pub fn started_event(id: &str) -> Value {
    json!({"type": "started", "id": id})
}

pub fn error_event(code: &str, message: &str) -> Value {
    json!({"type": "error", "code": code, "message": message})
}

/// The message JSON from cl_partial / cl_finish with `"type"` put in front. `None` if it is not a JSON object.
fn typed(kind: &str, raw: &str) -> Option<Map<String, Value>> {
    let Value::Object(m) = serde_json::from_str::<Value>(raw).ok()? else { return None };
    let mut out = Map::new();
    out.insert("type".into(), json!(kind));
    out.extend(m);
    Some(out)
}

/// `{"type":"partial", ...cl_partial fields...}`
pub fn partial_event(raw: &str) -> Option<Value> {
    typed("partial", raw).map(Value::Object)
}

/// `{"type":"done", ...cl_finish fields..., "prompt_tokens", "generated_tokens"}`
pub fn done_event(raw: &str, prompt_tokens: i32, generated_tokens: i32) -> Value {
    let mut m = typed("done", raw).or_else(|| typed("done", EMPTY_MESSAGE)).unwrap_or_default();
    m.insert("prompt_tokens".into(), json!(prompt_tokens));
    m.insert("generated_tokens".into(), json!(generated_tokens));
    Value::Object(m)
}

// ---------------------------------------------------------------- the service

struct Loaded {
    id: String,
    n_ctx: i32,
    info: Value,
    backend: Arc<dyn ChatBackend>,
}

pub struct LlmService {
    data: PathBuf,
    /// The file name of the embedding model, which is not a chat model.
    embed_file: String,
    loader: Box<Loader>,
    queue: GenQueue,
    loaded: Mutex<Option<Loaded>>,
    /// Whether `loaded` holds a model; readable from async code without taking any lock a load may be holding.
    is_loaded: AtomicBool,
    /// How long one event may wait for a client that is not reading before the client is treated as gone (milliseconds).
    send_timeout_ms: AtomicU64,
    /// The id (sent to its client in the `started` event) and the model of the generation that is running now (what `stop` stops).
    running: Mutex<Option<(String, Arc<dyn ChatBackend>)>>,
    /// Downloads and uploads of model files (see `models`).
    jobs: Arc<crate::models::ModelJobs>,
}

impl LlmService {
    /// `lib` is the path of libcache_llama (it need not exist: a load then says so).
    pub fn new(data: PathBuf, lib: PathBuf, embed_file: String) -> Arc<LlmService> {
        let loader = move |path: &Path, n_ctx: i32| -> Result<(Arc<dyn ChatBackend>, String), String> {
            #[cfg(target_arch = "x86_64")]
            if !(is_x86_feature_detected!("avx2") && is_x86_feature_detected!("fma") && is_x86_feature_detected!("f16c")) {
                return Err("This CPU has no AVX2, FMA and F16C, which the model library needs.".into());
            }
            if !lib.is_file() {
                return Err(format!("The model library {} is not installed.", lib.display()));
            }
            let (m, info) = ChatModel::load(&lib.to_string_lossy(), &path.to_string_lossy(), n_ctx)?;
            Ok((Arc::new(m) as Arc<dyn ChatBackend>, info))
        };
        LlmService::with_loader(data, embed_file, Box::new(loader))
    }

    pub fn with_loader(data: PathBuf, embed_file: String, loader: Box<Loader>) -> Arc<LlmService> {
        let jobs = crate::models::ModelJobs::new(data.clone(), embed_file.clone());
        Arc::new(LlmService { data, embed_file, loader, queue: GenQueue::default(), jobs,
            loaded: Mutex::new(None),
            is_loaded: AtomicBool::new(false),
            send_timeout_ms: AtomicU64::new(SEND_TIMEOUT.as_millis() as u64),
            running: Mutex::new(None),
        })
    }

    fn models_dir(&self) -> PathBuf {
        self.data.join("models")
    }

    /// The model downloads and uploads.
    pub fn jobs(&self) -> &Arc<crate::models::ModelJobs> {
        &self.jobs
    }

    /// `DELETE /api/models/files/<id>`: removes a model file. The model loaded now is kept (409 `in_use`).
    pub fn delete_model(&self, id: &str) -> Result<Value, ApiErr> {
        if !valid_model_id(id) || id == self.embed_file {
            return Err(err(400, "bad_model", "that is not a model id"));
        }
        // the loaded slot is held across the removal, so a load cannot start between the check and the delete
        let slot = self.loaded.lock().unwrap_or_else(|e| e.into_inner());
        if slot.as_ref().is_some_and(|l| l.id == id) {
            return Err(err(409, "in_use", "That model is loaded. Unload it first."));
        }
        match std::fs::remove_file(self.models_dir().join(id)) {
            Ok(()) => Ok(json!({"deleted": id})),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Err(err(404, "model_not_found", "no such model on this server")),
            Err(e) => Err(err(500, "server_error", format!("could not delete the file: {e}"))),
        }
    }

    /// The `.gguf` files in `<data>/models/` other than the embedder, as (id, size), by name. Every other `.gguf` is taken to be a
    /// chat model: nothing here reads a file's metadata.
    pub fn list_models(&self) -> Vec<(String, u64)> {
        let mut out = Vec::new();
        if let Ok(rd) = std::fs::read_dir(self.models_dir()) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if name == self.embed_file || !valid_model_id(&name) {
                    continue;
                }
                if let Ok(m) = std::fs::metadata(e.path()) {
                    if m.is_file() {
                        out.push((name, m.len()));
                    }
                }
            }
        }
        out.sort();
        out
    }

    /// `GET /api/llm/models` result.
    pub fn models_json(&self) -> Value {
        let loaded = self.loaded.lock().unwrap_or_else(|e| e.into_inner());
        let models: Vec<Value> = self
            .list_models()
            .into_iter()
            .map(|(id, size)| {
                let mut m = json!({"id": id, "size": size, "loaded": false});
                if let Some(l) = loaded.as_ref().filter(|l| l.id == id) {
                    m["loaded"] = json!(true);
                    m["info"] = l.info.clone();
                    m["n_ctx"] = json!(l.n_ctx);
                }
                m
            })
            .collect();
        json!({"v": PROTOCOL_VERSION, "models": models})
    }

    pub fn queue_waiting(&self) -> usize {
        self.queue.waiting()
    }

    /// Whether a model is loaded. Never blocks (a load in progress counts as not loaded).
    pub fn is_loaded(&self) -> bool {
        self.is_loaded.load(Ordering::SeqCst)
    }

    #[cfg(test)]
    fn set_send_timeout(&self, d: Duration) {
        self.send_timeout_ms.store(d.as_millis() as u64, Ordering::SeqCst);
    }

    /// `POST /api/llm/load`: blocking. Waits for a running generation to end, then loads. The same model at the same `n_ctx` again is
    /// a no-op; anything else frees the loaded model first (as the app does) and loads the new one.
    pub fn load(&self, id: &str, n_ctx: i32) -> Result<Value, ApiErr> {
        if !valid_model_id(id) {
            return Err(err(400, "bad_model", "that is not a model id"));
        }
        if !self.list_models().iter().any(|(n, _)| n == id) {
            return Err(err(404, "model_not_found", "no such model on this server"));
        }
        // The turn serializes loads and generations; the `loaded` lock is only held for the swaps, never across the native load.
        let _turn = self.queue.acquire(|_| {}, || false).map_err(|_| err(429, "busy", "too many requests are waiting for the model; try again shortly"))?;
        let old = {
            let mut slot = self.loaded.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(l) = slot.as_ref().filter(|l| l.id == id && l.n_ctx == n_ctx) {
                return Ok(l.info.clone());
            }
            self.is_loaded.store(false, Ordering::SeqCst);
            slot.take()
        };
        drop(old); // cl_free the old one before the new one takes its memory
        let (backend, info) = (self.loader)(&self.models_dir().join(id), n_ctx).map_err(|m| err(503, "load_failed", m))?;
        let info: Value = serde_json::from_str(&info).unwrap_or_else(|_| json!({}));
        *self.loaded.lock().unwrap_or_else(|e| e.into_inner()) = Some(Loaded { id: id.to_string(), n_ctx, info: info.clone(), backend });
        self.is_loaded.store(true, Ordering::SeqCst);
        Ok(info)
    }

    /// `POST /api/llm/stop`: ends the running generation early (its `done` still arrives). With an `id` (from the `started` event) only
    /// that generation is stopped, and `false` comes back when it is not the running one. Without, the current generation is, whose
    /// ever it is. It returns whether one was stopped.
    pub fn stop(&self, id: Option<&str>) -> bool {
        match self.running.lock().unwrap_or_else(|e| e.into_inner()).as_ref() {
            Some((rid, b)) if id.is_none_or(|i| i == rid) => {
                b.stop();
                true
            }
            _ => false,
        }
    }

    /// `POST /api/llm/generate`: blocking, run on a worker thread. Writes the NDJSON events to `tx`; a failed write (or one that
    /// waits longer than the send timeout for a client that is not reading) means the client went away, which stops the generation.
    /// `model`, when given, must be the id loaded when the turn starts, or the answer is a `model_changed` error.
    pub fn run_generation(&self, model: Option<String>, request: Value, tx: tokio::sync::mpsc::Sender<std::io::Result<Bytes>>) {
        let timeout = Duration::from_millis(self.send_timeout_ms.load(Ordering::SeqCst));
        let send = |ev: Value| send_event(&tx, ev, timeout);
        let _turn = match self.queue.acquire(
            |pos| {
                let _ = send(queued_event(pos));
            },
            || tx.is_closed(),
        ) {
            Ok(t) => t,
            Err(Denied::Cancelled) => return,
            Err(Denied::Busy) => {
                send(error_event("busy", "too many answers are waiting for the model; try again shortly"));
                return;
            }
        };
        let (backend, id) = {
            let l = self.loaded.lock().unwrap_or_else(|e| e.into_inner());
            (l.as_ref().map(|l| l.backend.clone()), l.as_ref().map(|l| l.id.clone()))
        };
        let Some(backend) = backend else {
            send(error_event("no_model", "No model is loaded"));
            return;
        };
        if model.as_deref().is_some_and(|m| Some(m) != id.as_deref()) {
            send(error_event("model_changed", "The model on the server is not the one this answer was asked of; load it again"));
            return;
        }
        let gen_id = crate::auth::hex(&crate::auth::random_bytes::<16>().unwrap_or([0; 16]));
        *self.running.lock().unwrap_or_else(|e| e.into_inner()) = Some((gen_id.clone(), backend.clone()));
        let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| generate_loop(backend.as_ref(), &gen_id, &request, &send)));
        *self.running.lock().unwrap_or_else(|e| e.into_inner()) = None;
        if r.is_err() {
            send(error_event("internal", "The model engine crashed while answering"));
        }
    }
}

/// Queue one event for the client. False when the client is gone: the stream was dropped, or it has not made room for `timeout`.
fn send_event(tx: &tokio::sync::mpsc::Sender<std::io::Result<Bytes>>, ev: Value, timeout: Duration) -> bool {
    use tokio::sync::mpsc::error::TrySendError;
    let started = std::time::Instant::now();
    let mut item = Ok(event_line(&ev));
    loop {
        match tx.try_send(item) {
            Ok(()) => return true,
            Err(TrySendError::Closed(_)) => return false,
            Err(TrySendError::Full(back)) => {
                if started.elapsed() >= timeout {
                    return false;
                }
                item = back;
                std::thread::sleep(Duration::from_millis(5));
            }
        }
    }
}

/// The worker of llama_session_io.dart (`case 'generate'`), call for call. `send` returns false once the client is gone.
fn generate_loop(b: &dyn ChatBackend, gen_id: &str, request: &Value, send: &dyn Fn(Value) -> bool) {
    // jsonEncode(request): the whole map goes to the native layer ("max_tokens" is ignored there).
    if let Err(m) = b.start(&request.to_string()) {
        send(error_event("start_failed", &m));
        return;
    }
    let max_tokens = max_tokens_of(request);
    // cl_start has cleared the stop flag by now, so a stop that comes for this id from here on is not lost.
    let mut gone = false;
    if !send(started_event(gen_id)) {
        gone = true;
        b.stop();
    }
    let n = loop {
        let n = b.next();
        if n < 0 {
            break n;
        }
        // The cap: the answer is what was generated up to it (cl_finish parses it as after a stop).
        let capped = max_tokens.is_some_and(|m| i64::from(b.generated_tokens()) >= m);
        if n > 0 && !gone {
            if let Some(ev) = b.partial().as_deref().and_then(partial_event) {
                if !send(ev) {
                    // The client disconnected: end the generation (the loop drains to -1 and the model is left clean).
                    gone = true;
                    b.stop();
                }
            }
        }
        if capped {
            break n;
        }
    };
    if gone {
        let _ = b.finish();
        return;
    }
    if n == -2 {
        send(error_event("generation_failed", GENERATION_FAILED));
        return;
    }
    let fin = b.finish().unwrap_or_else(|| EMPTY_MESSAGE.to_string());
    send(done_event(&fin, b.prompt_tokens(), b.generated_tokens()));
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;
    use std::sync::atomic::{AtomicBool, AtomicI32};
    use std::sync::mpsc;

    /// A scripted model: `tokens` tokens of 1 byte each, then -1 (or -2 after `fail_after`).
    struct Fake {
        tokens: i32,
        fail_after: Option<i32>,
        fail_start: bool,
        made: AtomicI32,
        stopped: AtomicBool,
        stops: AtomicI32,
        starts: AtomicI32,
        last_request: Mutex<String>,
        /// start() waits for a message here when set (to hold a generation open)
        hold: Mutex<Option<mpsc::Receiver<()>>>,
    }

    impl Fake {
        fn new(tokens: i32) -> Arc<Fake> {
            Arc::new(Fake {
                tokens,
                fail_after: None,
                fail_start: false,
                made: AtomicI32::new(0),
                stopped: AtomicBool::new(false),
                stops: AtomicI32::new(0),
                starts: AtomicI32::new(0),
                last_request: Mutex::new(String::new()),
                hold: Mutex::new(None),
            })
        }
    }

    impl ChatBackend for Fake {
        fn start(&self, r: &str) -> Result<(), String> {
            self.starts.fetch_add(1, Ordering::SeqCst);
            *self.last_request.lock().unwrap() = r.to_string();
            // cl_start clears the stop flag first, then decodes the prompt (the hold stands in for that)
            self.made.store(0, Ordering::SeqCst);
            self.stopped.store(false, Ordering::SeqCst);
            if self.fail_start {
                return Err("bad template".into());
            }
            if let Some(rx) = self.hold.lock().unwrap().take() {
                let _ = rx.recv();
            }
            Ok(())
        }
        fn next(&self) -> i32 {
            if self.stopped.load(Ordering::SeqCst) {
                return -1;
            }
            let k = self.made.fetch_add(1, Ordering::SeqCst);
            if self.fail_after == Some(k) {
                return -2;
            }
            if k >= self.tokens {
                self.made.fetch_sub(1, Ordering::SeqCst);
                return -1;
            }
            1
        }
        fn partial(&self) -> Option<String> {
            Some(format!(r#"{{"role":"assistant","content":"t{}"}}"#, self.made.load(Ordering::SeqCst)))
        }
        fn finish(&self) -> Option<String> {
            Some(format!(r#"{{"role":"assistant","content":"all{}","tool_calls":[]}}"#, self.made.load(Ordering::SeqCst)))
        }
        fn prompt_tokens(&self) -> i32 {
            7
        }
        fn generated_tokens(&self) -> i32 {
            self.made.load(Ordering::SeqCst)
        }
        fn stop(&self) {
            self.stops.fetch_add(1, Ordering::SeqCst);
            self.stopped.store(true, Ordering::SeqCst);
        }
    }

    fn service(d: &TempDir, fake: Arc<Fake>) -> Arc<LlmService> {
        let models = d.0.join("models");
        std::fs::create_dir_all(&models).unwrap();
        std::fs::write(models.join("chat-a.gguf"), b"0123").unwrap();
        std::fs::write(models.join("bge-m3-Q8_0.gguf"), b"embed").unwrap();
        std::fs::write(models.join("chat-b.gguf.part"), b"x").unwrap();
        std::fs::write(models.join("notes.txt"), b"x").unwrap();
        LlmService::with_loader(
            d.0.clone(),
            "bge-m3-Q8_0.gguf".into(),
            Box::new(move |_p, _n| Ok((fake.clone() as Arc<dyn ChatBackend>, r#"{"description":"fake","n_ctx":8192,"chat_format":"x","supports_tools":true}"#.to_string()))),
        )
    }

    fn collect(mut rx: tokio::sync::mpsc::Receiver<std::io::Result<Bytes>>) -> Vec<Value> {
        let mut out = vec![];
        while let Some(Ok(b)) = rx.blocking_recv() {
            let s = String::from_utf8(b.to_vec()).unwrap();
            assert!(s.ends_with('\n') && s.matches('\n').count() == 1, "one object per line: {s:?}");
            out.push(serde_json::from_str(&s).unwrap());
        }
        out
    }

    fn types(evs: &[Value]) -> Vec<&str> {
        evs.iter().map(|e| e["type"].as_str().unwrap()).collect()
    }

    #[test]
    fn model_ids_are_names_not_paths() {
        for ok in ["a.gguf", "Qwen3-4B-Q4_K_M.gguf", "x.GGUF", "a.b.gguf"] {
            assert!(valid_model_id(ok), "{ok}");
        }
        for bad in ["", "a", "a.bin", "../a.gguf", "a/b.gguf", "/etc/passwd", "a\\b.gguf", "..", "a..b.gguf", ".hidden.gguf", "a\0.gguf", "a.gguf/"] {
            assert!(!valid_model_id(bad), "{bad:?}");
        }
        assert!(!valid_model_id(&format!("{}.gguf", "x".repeat(300))));
        for bad in [r#"{"v":1,"model":"../x.gguf"}"#, r#"{"v":1,"model":"/etc/passwd"}"#, r#"{"v":1,"model":3}"#, r#"{"v":1}"#] {
            assert_eq!(parse_load(bad.as_bytes()).unwrap_err().status, 400, "{bad}");
        }
        assert_eq!(parse_load(br#"{"v":1,"model":"a.gguf"}"#).unwrap(), ("a.gguf".to_string(), 8192));
        assert_eq!(parse_load(br#"{"v":1,"model":"a.gguf","n_ctx":4096}"#).unwrap().1, 4096);
        assert_eq!(parse_load(br#"{"v":1,"model":"a.gguf","n_ctx":5}"#).unwrap_err().status, 400);
    }

    #[test]
    fn the_version_is_checked() {
        assert!(check_version(&json!({"v": 1})).is_ok());
        for bad in [json!({}), json!({"v": 2}), json!({"v": "1"}), json!({"v": 0}), json!({"v": 1.5})] {
            let e = check_version(&bad).unwrap_err();
            assert_eq!((e.status, e.code), (400, "unsupported_version"), "{bad}");
        }
        assert_eq!(parse_generate(br#"{"v":2,"request":{}}"#).unwrap_err().code, "unsupported_version");
        assert_eq!(parse_generate(br#"{"v":1}"#).unwrap_err().status, 400);
        assert_eq!(parse_generate(br#"{"v":1,"request":[]}"#).unwrap_err().status, 400);
        assert_eq!(parse_generate(b"nope").unwrap_err().code, "bad_json");
        assert_eq!(parse_generate(br#"{"v":1,"request":{"messages":[]}}"#).unwrap(), (None, json!({"messages": []})));
        assert_eq!(parse_generate(br#"{"v":1,"model":"a.gguf","request":{}}"#).unwrap().0.as_deref(), Some("a.gguf"));
        assert_eq!(parse_generate(br#"{"v":1,"model":7,"request":{}}"#).unwrap_err().status, 400);
    }

    #[test]
    fn events_are_one_json_object_per_line() {
        let q = event_line(&queued_event(2));
        assert_eq!(serde_json::from_slice::<Value>(&q).unwrap(), json!({"type": "queued", "position": 2}));
        let p = partial_event(r#"{"role":"assistant","content":"hi","reasoning_content":"r","tool_calls":[{"id":"1","type":"function","function":{"name":"f","arguments":"{}"}}]}"#).unwrap();
        assert_eq!(p["type"], "partial");
        assert_eq!(p["content"], "hi");
        assert_eq!(p["reasoning_content"], "r");
        assert_eq!(p["tool_calls"][0]["function"]["name"], "f");
        assert!(partial_event("not json").is_none() && partial_event("[1]").is_none());
        let d = done_event(r#"{"role":"assistant","content":"x","parse_error":"bad"}"#, 11, 5);
        assert_eq!((d["type"].clone(), d["parse_error"].clone(), d["prompt_tokens"].clone(), d["generated_tokens"].clone()), (json!("done"), json!("bad"), json!(11), json!(5)));
        // an unreadable final message becomes the empty assistant message, as in the app
        let d = done_event("garbage", 1, 0);
        assert_eq!((d["type"].clone(), d["role"].clone(), d["content"].clone()), (json!("done"), json!("assistant"), json!("")));
        let e = error_event("no_model", "No model is loaded");
        assert_eq!(e, json!({"type": "error", "code": "no_model", "message": "No model is loaded"}));
        // newlines inside text are escaped, so a line is never split
        let line = event_line(&partial_event(r#"{"content":"a\nb"}"#).unwrap());
        assert_eq!(line.iter().filter(|b| **b == b'\n').count(), 1);
    }

    #[test]
    fn max_tokens_follows_the_app() {
        assert_eq!(max_tokens_of(&json!({"max_tokens": 5})), Some(5));
        for none in [json!({}), json!({"max_tokens": 0}), json!({"max_tokens": -3}), json!({"max_tokens": 2.5}), json!({"max_tokens": "9"}), json!({"max_tokens": null})] {
            assert_eq!(max_tokens_of(&none), None, "{none}");
        }
    }

    #[test]
    fn models_list_skips_the_embedder_and_non_models() {
        let d = TempDir::new("llm-list");
        let s = service(&d, Fake::new(1));
        assert_eq!(s.list_models(), vec![("chat-a.gguf".to_string(), 4)]);
        let v = s.models_json();
        assert_eq!(v["v"], 1);
        assert_eq!(v["models"][0], json!({"id": "chat-a.gguf", "size": 4, "loaded": false}));
    }

    #[test]
    fn a_model_is_deleted_by_name_and_the_loaded_one_is_kept() {
        let d = TempDir::new("llm-delete");
        let s = service(&d, Fake::new(1));
        std::fs::write(d.0.join("models").join("chat-b.gguf"), b"xy").unwrap();
        for bad in ["../chat-a.gguf", "chat-a.txt", "bge-m3-Q8_0.gguf"] {
            assert_eq!(s.delete_model(bad).unwrap_err().status, 400, "{bad}");
        }
        s.load("chat-a.gguf", 512).unwrap();
        assert_eq!(s.delete_model("chat-a.gguf").unwrap_err().code, "in_use");
        assert!(d.0.join("models").join("chat-a.gguf").exists());
        assert_eq!(s.delete_model("chat-b.gguf").unwrap()["deleted"], "chat-b.gguf");
        assert_eq!(s.delete_model("chat-b.gguf").unwrap_err().status, 404);
        assert_eq!(s.list_models(), vec![("chat-a.gguf".to_string(), 4)]);
    }

    #[test]
    fn load_takes_ids_only_and_a_second_load_is_a_no_op() {
        let d = TempDir::new("llm-load");
        let loads = Arc::new(AtomicI32::new(0));
        let l2 = loads.clone();
        let fake = Fake::new(1);
        std::fs::create_dir_all(d.0.join("models")).unwrap();
        std::fs::write(d.0.join("models").join("chat-a.gguf"), b"0123").unwrap();
        std::fs::write(d.0.join("models").join("bge-m3-Q8_0.gguf"), b"e").unwrap();
        let s = LlmService::with_loader(
            d.0.clone(),
            "bge-m3-Q8_0.gguf".into(),
            Box::new(move |p, n| {
                assert!(p.ends_with("models/chat-a.gguf") && n == 8192);
                l2.fetch_add(1, Ordering::SeqCst);
                Ok((fake.clone() as Arc<dyn ChatBackend>, r#"{"description":"d","n_ctx":8192,"chat_format":"c","supports_tools":false}"#.to_string()))
            }),
        );
        for bad in ["../chat-a.gguf", "/etc/passwd", "sub/chat-a.gguf", "chat-a.gguf/.."] {
            assert_eq!(s.load(bad, 8192).unwrap_err().status, 400, "{bad}");
        }
        assert_eq!(s.load("missing.gguf", 8192).unwrap_err().status, 404);
        // the embedder is not offered as a chat model, even by name
        assert_eq!(s.load("bge-m3-Q8_0.gguf", 8192).unwrap_err().status, 404);
        assert!(!s.is_loaded());
        let info = s.load("chat-a.gguf", 8192).unwrap();
        assert_eq!(info["chat_format"], "c");
        assert_eq!(s.load("chat-a.gguf", 8192).unwrap(), info);
        assert_eq!(loads.load(Ordering::SeqCst), 1);
        assert_eq!(s.models_json()["models"][0]["loaded"], true);
    }

    #[test]
    fn a_generation_streams_partials_then_done() {
        let d = TempDir::new("llm-gen");
        let fake = Fake::new(3);
        let s = service(&d, fake.clone());
        s.load("chat-a.gguf", 8192).unwrap();
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        let req = json!({"messages": [{"role": "user", "content": "hi"}], "enable_thinking": false});
        s.run_generation(None, req.clone(), tx);
        let evs = collect(rx);
        assert_eq!(types(&evs), ["started", "partial", "partial", "partial", "done"]);
        assert!(evs[0]["id"].as_str().is_some_and(|i| i.len() == 32 && i.bytes().all(|b| b.is_ascii_hexdigit())));
        assert_eq!(evs[1]["content"], "t1");
        assert_eq!((evs[4]["content"].clone(), evs[4]["prompt_tokens"].clone(), evs[4]["generated_tokens"].clone()), (json!("all3"), json!(7), json!(3)));
        // the native layer got the request whole
        let sent: Value = serde_json::from_str(&fake.last_request.lock().unwrap()).unwrap();
        assert_eq!(sent, req);
    }

    /// Replays recorded native outputs (cl_partial / cl_finish text) from the parity fixture.
    struct Replay {
        partials: Vec<String>,
        finish: Option<String>,
        prompt_tokens: i32,
        generated_tokens: i32,
        fail: bool,
        made: AtomicI32,
    }

    impl ChatBackend for Replay {
        fn start(&self, _r: &str) -> Result<(), String> {
            Ok(())
        }
        fn next(&self) -> i32 {
            let k = self.made.fetch_add(1, Ordering::SeqCst) as usize;
            if k < self.partials.len() {
                1
            } else if self.fail {
                -2
            } else {
                -1
            }
        }
        fn partial(&self) -> Option<String> {
            Some(self.partials[self.made.load(Ordering::SeqCst) as usize - 1].clone())
        }
        fn finish(&self) -> Option<String> {
            self.finish.clone()
        }
        fn prompt_tokens(&self) -> i32 {
            self.prompt_tokens
        }
        fn generated_tokens(&self) -> i32 {
            self.generated_tokens
        }
        fn stop(&self) {}
    }

    /// The same fixture the Dart test (app/test/llm_remote_parity_test.dart) reads: these native outputs must make exactly these
    /// events, and the Dart side must make from the events what llama_session_io.dart makes from the native outputs.
    #[test]
    fn native_outputs_make_the_events_of_the_parity_fixture() {
        let fx: Value = serde_json::from_str(include_str!("../../packages/cache_llama/test/fixtures/llm-remote-parity.json")).unwrap();
        let cases = fx["cases"].as_array().unwrap();
        assert!(!cases.is_empty());
        for case in cases {
            let n = &case["native"];
            let replay = Arc::new(Replay {
                partials: n["partials"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect(),
                finish: n["finish"].as_str().map(str::to_string),
                prompt_tokens: n["prompt_tokens"].as_i64().unwrap() as i32,
                generated_tokens: n["generated_tokens"].as_i64().unwrap() as i32,
                fail: n["fail_after_partials"].as_bool().unwrap(),
                made: AtomicI32::new(0),
            });
            let d = TempDir::new("llm-parity");
            let models = d.0.join("models");
            std::fs::create_dir_all(&models).unwrap();
            std::fs::write(models.join("chat-a.gguf"), b"0123").unwrap();
            let r = replay.clone();
            let s = LlmService::with_loader(
                d.0.clone(),
                "bge-m3-Q8_0.gguf".into(),
                Box::new(move |_p, _n| Ok((r.clone() as Arc<dyn ChatBackend>, r#"{"description":"fake","n_ctx":8192,"chat_format":"x","supports_tools":true}"#.to_string()))),
            );
            s.load("chat-a.gguf", 8192).unwrap();
            let (tx, rx) = tokio::sync::mpsc::channel(64);
            s.run_generation(None, json!({"messages": []}), tx);
            let mut got = collect(rx);
            // the generation id is random: it must be 32 hex digits, and the fixture holds the placeholder "ID"
            assert_eq!(got[0]["type"], "started");
            assert!(got[0]["id"].as_str().is_some_and(|i| i.len() == 32 && i.bytes().all(|b| b.is_ascii_hexdigit())));
            got[0]["id"] = json!("ID");
            let want: Vec<Value> = case["events"].as_array().unwrap().clone();
            assert_eq!(got, want, "case {}", case["name"]);
        }
    }

    #[test]
    fn max_tokens_ends_the_generation_like_the_app() {
        let d = TempDir::new("llm-cap");
        let fake = Fake::new(100);
        let s = service(&d, fake.clone());
        s.load("chat-a.gguf", 8192).unwrap();
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        s.run_generation(None, json!({"messages": [], "max_tokens": 2}), tx);
        let evs = collect(rx);
        // the app emits the partial of the token that reached the cap, then breaks and finishes
        assert_eq!(types(&evs), ["started", "partial", "partial", "done"]);
        assert_eq!(evs[3]["generated_tokens"], 2);
        // the cap is also in the request the native layer got (it ignores it)
        assert!(fake.last_request.lock().unwrap().contains("max_tokens"));
    }

    #[test]
    fn errors_become_error_events() {
        let d = TempDir::new("llm-err");
        let mut f = Fake::new(5);
        Arc::get_mut(&mut f).unwrap().fail_after = Some(2);
        let s = service(&d, f);
        // no model loaded yet
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        s.run_generation(None, json!({"messages": []}), tx);
        assert_eq!(collect(rx), vec![error_event("no_model", "No model is loaded")]);
        s.load("chat-a.gguf", 8192).unwrap();
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        s.run_generation(None, json!({"messages": []}), tx);
        let evs = collect(rx);
        assert_eq!(types(&evs), ["started", "partial", "partial", "error"]);
        assert_eq!((evs[3]["code"].clone(), evs[3]["message"].clone()), (json!("generation_failed"), json!(GENERATION_FAILED)));
        // cl_start refusing
        let d2 = TempDir::new("llm-err2");
        let mut f2 = Fake::new(5);
        Arc::get_mut(&mut f2).unwrap().fail_start = true;
        let s2 = service(&d2, f2);
        s2.load("chat-a.gguf", 8192).unwrap();
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        s2.run_generation(None, json!({"messages": []}), tx);
        assert_eq!(collect(rx), vec![error_event("start_failed", "bad template")]);
    }

    #[test]
    fn a_client_that_goes_away_stops_the_generation() {
        let d = TempDir::new("llm-gone");
        let fake = Fake::new(1000);
        let (hold_tx, hold_rx) = mpsc::channel();
        *fake.hold.lock().unwrap() = Some(hold_rx);
        let s = service(&d, fake.clone());
        s.load("chat-a.gguf", 8192).unwrap();
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        let s2 = s.clone();
        let t = std::thread::spawn(move || s2.run_generation(None, json!({"messages": []}), tx));
        while fake.starts.load(Ordering::SeqCst) == 0 {
            std::thread::sleep(Duration::from_millis(5));
        }
        // the generation is under way (the prompt is being read) when the client leaves
        drop(rx);
        hold_tx.send(()).unwrap();
        t.join().unwrap();
        assert_eq!(fake.stops.load(Ordering::SeqCst), 1);
        assert!(fake.made.load(Ordering::SeqCst) < 5, "it ran on after the client left");
        // the turn was given back: the next generation runs
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        s.run_generation(None, json!({"messages": [], "max_tokens": 1}), tx);
        assert_eq!(types(&collect(rx)).last(), Some(&"done"));
    }

    #[test]
    fn a_client_that_left_before_its_turn_never_runs() {
        let d = TempDir::new("llm-gone-early");
        let fake = Fake::new(1000);
        let s = service(&d, fake.clone());
        s.load("chat-a.gguf", 8192).unwrap();
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        drop(rx);
        s.run_generation(None, json!({"messages": []}), tx);
        assert_eq!(fake.starts.load(Ordering::SeqCst), 0);
    }

    #[test]
    fn stop_ends_the_running_generation_and_the_final_message_still_comes() {
        let d = TempDir::new("llm-stop");
        let fake = Fake::new(1_000_000);
        let (hold_tx, hold_rx) = mpsc::channel();
        *fake.hold.lock().unwrap() = Some(hold_rx);
        let s = service(&d, fake.clone());
        s.load("chat-a.gguf", 8192).unwrap();
        assert!(!s.stop(None), "nothing is running");
        let (tx, rx) = tokio::sync::mpsc::channel(1 << 20);
        let s2 = s.clone();
        let t = std::thread::spawn(move || s2.run_generation(None, json!({"messages": []}), tx));
        while fake.starts.load(Ordering::SeqCst) == 0 {
            std::thread::sleep(Duration::from_millis(5));
        }
        // start() is holding the generation open
        while !s.stop(None) {
            std::thread::sleep(Duration::from_millis(5));
        }
        hold_tx.send(()).unwrap();
        t.join().unwrap();
        let evs = collect(rx);
        assert_eq!(types(&evs).last(), Some(&"done"));
        assert!(!s.stop(None), "the generation is over");
    }

    #[test]
    fn stop_with_an_id_stops_only_that_generation() {
        let d = TempDir::new("llm-stop-id");
        let fake = Fake::new(1_000_000);
        let s = service(&d, fake.clone());
        s.load("chat-a.gguf", 8192).unwrap();
        let (tx, mut rx) = tokio::sync::mpsc::channel(1 << 20);
        let s2 = s.clone();
        let t = std::thread::spawn(move || s2.run_generation(None, json!({"messages": []}), tx));
        // the first event is `started`, with the id
        let first = rx.blocking_recv().unwrap().unwrap();
        let ev: Value = serde_json::from_slice(&first).unwrap();
        assert_eq!(ev["type"], "started");
        let id = ev["id"].as_str().unwrap().to_string();
        assert!(!s.stop(Some("0123456789abcdef0123456789abcdef")), "another id stops nothing");
        assert_eq!(fake.stops.load(Ordering::SeqCst), 0);
        assert!(s.stop(Some(&id)));
        t.join().unwrap();
        let mut evs = vec![];
        while let Ok(Ok(b)) = rx.try_recv() {
            evs.push(serde_json::from_slice::<Value>(&b).unwrap());
        }
        assert_eq!(evs.last().unwrap()["type"], "done", "the final message still comes");
        assert!(!s.stop(Some(&id)), "that generation is over");
    }

    #[test]
    fn the_stop_body_takes_an_optional_string_id() {
        assert_eq!(parse_stop(br#"{"v":1}"#).unwrap(), None);
        assert_eq!(parse_stop(br#"{"v":1,"id":"ab"}"#).unwrap(), Some("ab".to_string()));
        assert!(parse_stop(br#"{"v":1,"id":5}"#).is_err());
        assert!(parse_stop(br#"{"id":"ab"}"#).is_err());
    }

    #[test]
    fn a_second_generation_is_told_it_is_queued_and_then_runs() {
        let d = TempDir::new("llm-queue");
        let fake = Fake::new(2);
        let (hold_tx, hold_rx) = mpsc::channel();
        *fake.hold.lock().unwrap() = Some(hold_rx);
        let s = service(&d, fake.clone());
        s.load("chat-a.gguf", 8192).unwrap();
        let (tx1, rx1) = tokio::sync::mpsc::channel(64);
        let s1 = s.clone();
        let t1 = std::thread::spawn(move || s1.run_generation(None, json!({"messages": []}), tx1));
        while fake.starts.load(Ordering::SeqCst) == 0 {
            std::thread::sleep(Duration::from_millis(5));
        }
        let (tx2, mut rx2) = tokio::sync::mpsc::channel(64);
        let s2 = s.clone();
        let t2 = std::thread::spawn(move || s2.run_generation(None, json!({"messages": []}), tx2));
        // the second one sees queued, position 1 (the running one is ahead of it)
        let first = rx2.blocking_recv().unwrap().unwrap();
        assert_eq!(serde_json::from_slice::<Value>(&first).unwrap(), json!({"type": "queued", "position": 1}));
        assert_eq!(s.queue_waiting(), 1);
        hold_tx.send(()).unwrap();
        t1.join().unwrap();
        t2.join().unwrap();
        assert_eq!(types(&collect(rx1)), ["started", "partial", "partial", "done"]);
        assert_eq!(types(&collect(rx2)), ["started", "partial", "partial", "done"]);
        assert_eq!(s.queue_waiting(), 0);
    }

    #[test]
    fn a_waiting_client_that_leaves_gives_up_its_place() {
        let q = Arc::new(GenQueue::default());
        let t1 = q.acquire(|_| {}, || false).ok().unwrap();
        let gone = Arc::new(AtomicBool::new(false));
        let (q2, g2) = (q.clone(), gone.clone());
        let h = std::thread::spawn(move || q2.acquire(|_| {}, || g2.load(Ordering::SeqCst)).err());
        while q.waiting() == 0 {
            std::thread::sleep(Duration::from_millis(5));
        }
        gone.store(true, Ordering::SeqCst);
        assert_eq!(h.join().unwrap(), Some(Denied::Cancelled), "it left without a turn");
        assert_eq!(q.waiting(), 0);
        drop(t1);
        assert!(q.acquire(|_| {}, || false).is_ok());
    }

    #[test]
    fn a_cancelled_waiter_is_never_handed_the_turn() {
        // nobody is running and it would be first in line, but it has already gone
        let q = GenQueue::default();
        assert_eq!(q.acquire(|_| {}, || true).err(), Some(Denied::Cancelled));
        assert_eq!(q.waiting(), 0);
        // and the queue still works
        assert!(q.acquire(|_| {}, || false).is_ok());
    }

    #[test]
    fn the_waiting_cap_is_enforced_under_the_queue_lock() {
        let q = Arc::new(GenQueue::default());
        let _running = q.acquire(|_| {}, || false).ok().unwrap();
        let stay = Arc::new(AtomicBool::new(false));
        let mut hs = vec![];
        for _ in 0..MAX_WAITING {
            let (q2, s2) = (q.clone(), stay.clone());
            hs.push(std::thread::spawn(move || q2.acquire(|_| {}, || s2.load(Ordering::SeqCst)).err()));
        }
        while q.waiting() < MAX_WAITING {
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(q.acquire(|_| {}, || false).err(), Some(Denied::Busy));
        assert_eq!(q.waiting(), MAX_WAITING);
        stay.store(true, Ordering::SeqCst);
        for h in hs {
            assert_eq!(h.join().unwrap(), Some(Denied::Cancelled));
        }
    }

    #[test]
    fn a_client_that_stops_reading_is_treated_as_gone() {
        let d = TempDir::new("llm-stall");
        let fake = Fake::new(1000);
        let s = service(&d, fake.clone());
        s.load("chat-a.gguf", 8192).unwrap();
        s.set_send_timeout(Duration::from_millis(100));
        // room for one event and nobody reads: the connection is open, the client is not there
        let (tx, rx) = tokio::sync::mpsc::channel(1);
        let started = std::time::Instant::now();
        s.run_generation(None, json!({"messages": []}), tx);
        assert!(started.elapsed() < Duration::from_secs(10));
        assert_eq!(fake.stops.load(Ordering::SeqCst), 1);
        drop(rx);
        // the turn was given back
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        s.run_generation(None, json!({"messages": [], "max_tokens": 1}), tx);
        assert_eq!(types(&collect(rx)).last(), Some(&"done"));
    }

    #[test]
    fn a_generation_asked_of_another_model_is_refused() {
        let d = TempDir::new("llm-changed");
        let fake = Fake::new(2);
        let s = service(&d, fake.clone());
        s.load("chat-a.gguf", 8192).unwrap();
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        s.run_generation(Some("other.gguf".into()), json!({"messages": []}), tx);
        let evs = collect(rx);
        assert_eq!(types(&evs), ["error"]);
        assert_eq!(evs[0]["code"], "model_changed");
        assert_eq!(fake.starts.load(Ordering::SeqCst), 0, "the model was not run");
        // the right id runs
        let (tx, rx) = tokio::sync::mpsc::channel(64);
        s.run_generation(Some("chat-a.gguf".into()), json!({"messages": []}), tx);
        assert_eq!(types(&collect(rx)).last(), Some(&"done"));
    }

    #[test]
    fn a_load_in_progress_blocks_nothing_that_reads_the_state() {
        let d = TempDir::new("llm-slowload");
        std::fs::create_dir_all(d.0.join("models")).unwrap();
        std::fs::write(d.0.join("models").join("chat-a.gguf"), b"0123").unwrap();
        let (release_tx, release_rx) = mpsc::channel::<()>();
        let (entered_tx, entered_rx) = mpsc::channel::<()>();
        let release_rx = Mutex::new(release_rx);
        let fake = Fake::new(1);
        let s = LlmService::with_loader(
            d.0.clone(),
            "bge-m3-Q8_0.gguf".into(),
            Box::new(move |_, _| {
                entered_tx.send(()).unwrap();
                let _ = release_rx.lock().unwrap().recv();
                Ok((fake.clone() as Arc<dyn ChatBackend>, "{}".to_string()))
            }),
        );
        let s2 = s.clone();
        let t = std::thread::spawn(move || s2.load("chat-a.gguf", 8192).unwrap());
        entered_rx.recv().unwrap();
        // the native load is running: these must answer at once
        assert!(!s.is_loaded());
        assert_eq!(s.models_json()["models"][0]["loaded"], false);
        assert_eq!(s.queue_waiting(), 0);
        release_tx.send(()).unwrap();
        t.join().unwrap();
        assert!(s.is_loaded());
    }
}
