//! Safe wrappers over the `cs_*` C ABI. Each method makes exactly one ABI call (plus the error lookup) and
//! returns the JSON string the core produced, untouched. The only logic added here is the query embedding
//! (see `Engine::search`).

use crate::embed::Embedder;
use cache_search::conv::Conversation;
use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::job::Job;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::time::{Duration, Instant};

/// An error as the core reports it: `{"code","message"}`.
#[derive(Debug, Clone)]
pub struct ApiError {
    pub code: String,
    pub message: String,
}

impl ApiError {
    pub fn new(code: &str, message: impl Into<String>) -> ApiError {
        ApiError { code: code.to_string(), message: message.into() }
    }

    pub fn to_json(&self) -> String {
        json!({"code": self.code, "message": self.message}).to_string()
    }

    /// HTTP status for the `cs serve` error responses.
    pub fn http_status(&self) -> u16 {
        match self.code.as_str() {
            "bad_json" => 400,
            "not_found" => 404,
            "busy" | "index_missing" | "index_stale" | "cancelled" => 409,
            "unsupported" => 422,
            _ => 500,
        }
    }

    fn from_json(s: Option<String>) -> ApiError {
        match s.and_then(|s| serde_json::from_str::<Value>(&s).ok()) {
            Some(v) => ApiError::new(v["code"].as_str().unwrap_or("internal"), v["message"].as_str().unwrap_or("")),
            None => ApiError::new("internal", "the core failed without an error"),
        }
    }
}

impl std::fmt::Display for ApiError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

/// Take ownership of a core string and free it.
fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn thread_error() -> ApiError {
    ApiError::from_json(take(unsafe { cs_last_error(ptr::null_mut()) }))
}

fn cstring(s: &str, what: &str) -> Result<CString, ApiError> {
    CString::new(s).map_err(|_| ApiError::new("bad_json", format!("{what} contains NUL")))
}

/// A `cs_handle`, opened from the `cs_open` config JSON.
pub struct Core {
    h: *mut Handle,
}

impl Core {
    pub fn open(config_json: &str) -> Result<Core, ApiError> {
        let c = cstring(config_json, "config")?;
        let h = unsafe { cs_open(c.as_ptr()) };
        if h.is_null() {
            return Err(thread_error());
        }
        Ok(Core { h })
    }

    fn result(&self, p: *mut c_char) -> Result<String, ApiError> {
        take(p).ok_or_else(|| ApiError::from_json(take(unsafe { cs_last_error(self.h) })))
    }

    pub fn status(&mut self) -> Result<String, ApiError> {
        let p = unsafe { cs_status(self.h) };
        self.result(p)
    }

    pub fn search(&mut self, query: &str, options_json: &str) -> Result<String, ApiError> {
        let (q, o) = (cstring(query, "query")?, cstring(options_json, "options")?);
        let p = unsafe { cs_search(self.h, q.as_ptr(), o.as_ptr()) };
        self.result(p)
    }

    pub fn read(&mut self, address: &str, max_chars: i32) -> Result<String, ApiError> {
        let a = cstring(address, "address")?;
        let p = unsafe { cs_read(self.h, a.as_ptr(), max_chars) };
        self.result(p)
    }

    pub fn suggest(&mut self, prefix: &str, options_json: &str) -> Result<String, ApiError> {
        let (q, o) = (cstring(prefix, "prefix")?, cstring(options_json, "options")?);
        let p = unsafe { cs_suggest(self.h, q.as_ptr(), o.as_ptr()) };
        self.result(p)
    }

    /// Poll `cs_status` until no source is `"opening"` (libraries open on background threads inside the core).
    pub fn wait_ready(&mut self, timeout: Duration) -> Result<(), ApiError> {
        let t0 = Instant::now();
        loop {
            let st: Value = serde_json::from_str(&self.status()?).map_err(|e| ApiError::new("internal", e.to_string()))?;
            let opening = st["sources"].as_array().map(|a| a.iter().any(|s| s["opening"] == true)).unwrap_or(false);
            if !opening {
                return Ok(());
            }
            if t0.elapsed() > timeout {
                return Err(ApiError::new("busy", format!("a library was still opening after {} s", timeout.as_secs())));
            }
            std::thread::sleep(Duration::from_millis(200));
        }
    }
}

impl Drop for Core {
    fn drop(&mut self) {
        unsafe { cs_close(self.h) };
    }
}

/// A `cs_conv`: the [n] numbering of one conversation.
pub struct Conv {
    c: *mut Conversation,
}

impl Conv {
    pub fn new() -> Result<Conv, ApiError> {
        let c = cs_conversation_new();
        if c.is_null() {
            return Err(thread_error());
        }
        Ok(Conv { c })
    }

    pub fn format(&mut self, results_json: &str) -> Result<String, ApiError> {
        let r = cstring(results_json, "results")?;
        take(unsafe { cs_format(self.c, r.as_ptr()) }).ok_or_else(thread_error)
    }

    pub fn ids(&mut self) -> Result<String, ApiError> {
        take(unsafe { cs_conversation_ids(self.c) }).ok_or_else(thread_error)
    }
}

impl Drop for Conv {
    fn drop(&mut self) {
        unsafe { cs_conversation_free(self.c) };
    }
}

/// A `cs_job`.
pub struct JobRun {
    j: *mut Job,
}

impl JobRun {
    pub fn start(kind: &str, params: &Value) -> Result<JobRun, ApiError> {
        let (k, p) = (cstring(kind, "kind")?, cstring(&params.to_string(), "params")?);
        let j = unsafe { cs_job_start(k.as_ptr(), p.as_ptr()) };
        if j.is_null() {
            return Err(thread_error());
        }
        Ok(JobRun { j })
    }

    pub fn progress(&mut self) -> Result<String, ApiError> {
        take(unsafe { cs_job_progress(self.j) }).ok_or_else(thread_error)
    }
}

impl Drop for JobRun {
    fn drop(&mut self) {
        unsafe { cs_job_free(self.j) };
    }
}

/// The core plus the optional query embedder: what `cs search` and `cs serve` share.
pub struct Engine {
    pub core: Core,
    pub embedder: Option<Embedder>,
}

impl Engine {
    /// `cs_search`. When an embedder is configured and `options` has no `query_vector`, the query is embedded and
    /// the vector is added as `{"model": <model id>, "vector": [...]}`. Everything else is passed through as given.
    pub fn search(&mut self, query: &str, mut options: Value) -> Result<String, ApiError> {
        let Some(map) = options.as_object_mut() else {
            return Err(ApiError::new("bad_json", "options must be a JSON object"));
        };
        if let Some(emb) = &self.embedder {
            if map.get("query_vector").map(Value::is_null).unwrap_or(true) {
                let v = emb.embed(query)?;
                map.insert("query_vector".into(), json!({"model": emb.model_id, "vector": v}));
            }
        }
        self.core.search(query, &options.to_string())
    }
}
