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
use std::sync::{Arc, Mutex};
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
            "unsupported" | "limit_exceeded" => 422,
            "offline" => 503,
            "no_space" => 507,
            "not_configured" => 409,
            "key_missing" => 400,
            "quota" => 429,
            "fetch_failed" | "bad_response" => 502,
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
    /// The `cs_open` config the handle was opened with (a layer download job needs its `layers` section).
    cfg: String,
}

impl Core {
    pub fn open(config_json: &str) -> Result<Core, ApiError> {
        let c = cstring(config_json, "config")?;
        let h = unsafe { cs_open(c.as_ptr()) };
        if h.is_null() {
            return Err(thread_error());
        }
        Ok(Core { h, cfg: config_json.to_string() })
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

    /// `cs_set_location`; `accuracy_m < 0` means unknown.
    pub fn set_location(&mut self, lat: f64, lon: f64, accuracy_m: f64, fixed_at: &str) -> Result<(), ApiError> {
        let at = cstring(fixed_at, "fixed_at")?;
        if unsafe { cs_set_location(self.h, lat, lon, accuracy_m, at.as_ptr()) } != 0 {
            return Err(ApiError::from_json(take(unsafe { cs_last_error(self.h) })));
        }
        Ok(())
    }

    pub fn clear_location(&mut self) -> Result<(), ApiError> {
        if unsafe { cs_clear_location(self.h) } != 0 {
            return Err(ApiError::from_json(take(unsafe { cs_last_error(self.h) })));
        }
        Ok(())
    }

    pub fn tool_schemas(&mut self) -> Result<String, ApiError> {
        let p = unsafe { cs_tool_schemas(self.h) };
        self.result(p)
    }

    /// `cs_tool`: `{"content","ids"}`.
    pub fn tool(&mut self, conv: &mut Conv, name: &str, args_json: &str, now: &str) -> Result<String, ApiError> {
        let (n, a, t) = (cstring(name, "name")?, cstring(args_json, "args")?, cstring(now, "now")?);
        let p = unsafe { cs_tool(self.h, conv.c, n.as_ptr(), a.as_ptr(), t.as_ptr()) };
        self.result(p)
    }

    /// Make built-in `search` embed its query with `embedder` (the core never links an embedder itself).
    pub fn set_query_embedder(&mut self, embedder: Arc<Mutex<Embedder>>) {
        // SAFETY: `self.h` is the live handle `cs_open` returned and `&mut self` is the only user of it.
        unsafe { &mut *self.h }.set_query_embedder(Box::new(move |q: &str| {
            let e = embedder.lock().ok()?;
            e.embed(q).ok().map(|v| (e.model_id.clone(), v))
        }));
    }

    pub fn layers_list(&mut self) -> Result<String, ApiError> {
        let p = unsafe { cs_layers_list(self.h) };
        self.result(p)
    }

    pub fn layers_refresh(&mut self) -> Result<String, ApiError> {
        let p = unsafe { cs_layers_refresh(self.h) };
        self.result(p)
    }

    pub fn layers_save(&mut self, def_json: &str) -> Result<String, ApiError> {
        let c = cstring(def_json, "definition")?;
        let p = unsafe { cs_layers_save(self.h, c.as_ptr()) };
        self.result(p)
    }

    pub fn layers_remove(&mut self, id: &str) -> Result<String, ApiError> {
        let c = cstring(id, "id")?;
        let p = unsafe { cs_layers_remove(self.h, c.as_ptr()) };
        self.result(p)
    }

    pub fn layers_server(&mut self, options_json: Option<&str>) -> Result<String, ApiError> {
        let c = options_json.map(|o| cstring(o, "options")).transpose()?;
        let p = unsafe { cs_layers_server(self.h, c.as_ref().map(|c| c.as_ptr()).unwrap_or(ptr::null())) };
        self.result(p)
    }

    pub fn layers_plan(&mut self, request_json: &str) -> Result<String, ApiError> {
        let c = cstring(request_json, "request")?;
        let p = unsafe { cs_layers_plan(self.h, c.as_ptr()) };
        self.result(p)
    }

    pub fn layers_delete(&mut self, request_json: &str) -> Result<String, ApiError> {
        let c = cstring(request_json, "request")?;
        let p = unsafe { cs_layers_delete(self.h, c.as_ptr()) };
        self.result(p)
    }

    pub fn layers_clear_cache(&mut self, layer: Option<&str>) -> Result<String, ApiError> {
        let c = layer.map(|l| cstring(l, "layer")).transpose()?;
        let p = unsafe { cs_layers_clear_cache(self.h, c.as_ref().map(|c| c.as_ptr()).unwrap_or(ptr::null())) };
        self.result(p)
    }

    /// One tile: `(mime, bytes)`; an empty tile has an empty MIME and no bytes.
    pub fn layers_tile(&mut self, layer: &str, z: i32, x: i32, y: i32) -> Result<(String, Vec<u8>), ApiError> {
        let c = cstring(layer, "layer")?;
        let (mut mime, mut len): (*mut c_char, i64) = (ptr::null_mut(), -1);
        let p = unsafe { cs_layers_tile(self.h, c.as_ptr(), z, x, y, &mut mime, &mut len) };
        if p.is_null() {
            return Err(ApiError::from_json(take(unsafe { cs_last_error(self.h) })));
        }
        let bytes = unsafe { std::slice::from_raw_parts(p, len as usize) }.to_vec();
        let m = take(mime).unwrap_or_default();
        unsafe { cs_free_bytes(p, len) };
        Ok((m, bytes))
    }

    /// A `layer_download` job for `request` (`{layer, area?, bbox|polygon, minzoom?, maxzoom?, update?}`) with this
    /// handle's `layers` config; `on_progress` gets the progress JSON whenever it changes. Returns the final progress JSON.
    pub fn layers_download(&mut self, request: &Value, on_progress: &mut dyn FnMut(&str)) -> Result<String, ApiError> {
        let cfg: Value = serde_json::from_str(&self.cfg).map_err(|e| ApiError::new("bad_json", e.to_string()))?;
        let mut params = request.clone();
        let layers = cfg.get("layers").cloned().ok_or_else(|| ApiError::new("not_configured", "the config has no \"layers\" section"))?;
        params.as_object_mut().ok_or_else(|| ApiError::new("bad_json", "the request must be an object"))?.insert("layers".into(), layers);
        let mut job = JobRun::start("layer_download", &params)?;
        let mut last = String::new();
        loop {
            let p = job.progress()?;
            let v: Value = serde_json::from_str(&p).map_err(|e| ApiError::new("internal", e.to_string()))?;
            if v["state"] != "running" {
                return match v["state"].as_str() {
                    Some("done") => Ok(p),
                    _ => Err(ApiError::new(v["error"]["code"].as_str().unwrap_or(if v["state"] == "cancelled" { "cancelled" } else { "internal" }), v["error"]["message"].as_str().unwrap_or("the download did not finish").to_string())),
                };
            }
            if p != last {
                on_progress(&p);
                last = p;
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    }

    pub fn places_list(&mut self) -> Result<String, ApiError> {
        let p = unsafe { cs_places_list(self.h) };
        self.result(p)
    }

    pub fn place_save(&mut self, place_json: &str) -> Result<String, ApiError> {
        let c = cstring(place_json, "place")?;
        let p = unsafe { cs_place_save(self.h, c.as_ptr()) };
        self.result(p)
    }

    pub fn place_delete(&mut self, key: &str) -> Result<String, ApiError> {
        let c = cstring(key, "key")?;
        let p = unsafe { cs_place_delete(self.h, c.as_ptr()) };
        self.result(p)
    }

    pub fn live_sources(&mut self) -> Result<String, ApiError> {
        let p = unsafe { cs_live_sources(self.h) };
        self.result(p)
    }

    pub fn live_fetch(&mut self, request_json: &str) -> Result<String, ApiError> {
        let c = cstring(request_json, "request")?;
        let p = unsafe { cs_live_fetch(self.h, c.as_ptr()) };
        self.result(p)
    }

    pub fn live_get(&mut self, request_json: &str) -> Result<String, ApiError> {
        let c = cstring(request_json, "request")?;
        let p = unsafe { cs_live_get(self.h, c.as_ptr()) };
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
    pub embedder: Option<Arc<Mutex<Embedder>>>,
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
                let emb = emb.lock().map_err(|_| ApiError::new("internal", "the embedder lock is poisoned"))?;
                let v = emb.embed(query)?;
                map.insert("query_vector".into(), json!({"model": emb.model_id, "vector": v}));
            }
        }
        self.core.search(query, &options.to_string())
    }
}
