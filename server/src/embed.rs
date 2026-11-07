//! The text embedder on the server: bge-m3 (Q8_0) through cache_llama's `cl_embed`, loaded at run time by the `cache_embed` crate,
//! so a vector made here is the vector the phone makes (same library code, same settings: context 512, normalised, CLS pooling
//! read from the GGUF). Two callers:
//!   * the library builder, through [`EmbedService::embed_batch`] (blocking; one loaded context, reused for the whole batch);
//!   * the browser's query embedding, through `POST /api/embed {texts}` (at most [`MAX_TEXTS`] texts).
//!
//! The model file lives in `<data>/models/` and is downloaded on first need (or on `POST /api/models/embedder/download`) from the
//! pinned Hugging Face revision the app uses, with `.part` resume and a sha256 check. The loaded model (about 700 MB) is let go
//! after [`IDLE`] without a call and loaded again by the next one.

use crate::fetch;
use crate::library::{free_bytes, ApiErr};
use cache_embed::Embedder;
use ring::digest;
use serde::Serialize;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

/// The most texts one `/api/embed` call takes.
pub const MAX_TEXTS: usize = 64;
/// The longest text taken, in bytes (cl_embed cuts at 512 tokens anyway; this only bounds the work per call).
pub const MAX_TEXT_BYTES: usize = 64 * 1024;
/// How long a loaded model stays in memory without a call.
pub const IDLE: Duration = Duration::from_secs(120);

/// The model, pinned exactly as the app pins it (app/lib/models/search_model.dart, `kSearchModel`).
#[derive(Clone, Debug)]
pub struct ModelSpec {
    pub file_name: String,
    pub size: u64,
    pub sha256: String,
    pub url: String,
}

impl ModelSpec {
    /// bge-m3 Q8_0 from lm-kit/bge-m3-gguf at the revision the app uses.
    pub fn bge_m3() -> ModelSpec {
        let (repo, rev, path) = ("lm-kit/bge-m3-gguf", "9379ce497e8814b200f2dc0d18eb4045426dcb8c", "bge-m3-Q8_0.gguf");
        ModelSpec {
            file_name: cache_embed::DECIDED_MODEL_FILE.to_string(),
            size: 634_553_856,
            sha256: cache_embed::DECIDED_MODEL_SHA256.to_string(),
            url: format!("https://huggingface.co/{repo}/resolve/{rev}/{path}"),
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
enum Dl {
    Idle,
    Downloading { bytes: u64, total: u64 },
    Error(String),
}

struct Loaded {
    embedder: Embedder,
    last: Instant,
}

pub struct EmbedService {
    data: PathBuf,
    lib: PathBuf,
    threads: i32,
    spec: ModelSpec,
    dl: Mutex<Dl>,
    loaded: Mutex<Option<Loaded>>,
    /// The sha256 of the model file has been checked in this process.
    verified: AtomicBool,
}

fn err(status: u16, code: &'static str, message: impl Into<String>) -> ApiErr {
    ApiErr { status, code, message: message.into() }
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

impl EmbedService {
    /// `lib` is the path of libcache_llama (it need not exist: the state then says so).
    pub fn new(data: PathBuf, lib: PathBuf) -> Arc<EmbedService> {
        EmbedService::with_spec(data, lib, ModelSpec::bge_m3())
    }

    pub fn with_spec(data: PathBuf, lib: PathBuf, spec: ModelSpec) -> Arc<EmbedService> {
        Arc::new(EmbedService {
            data,
            lib,
            threads: cache_embed::EMBED_DEFAULT_THREADS,
            spec,
            dl: Mutex::new(Dl::Idle),
            loaded: Mutex::new(None),
            verified: AtomicBool::new(false),
        })
    }

    pub fn model_path(&self) -> PathBuf {
        self.data.join("models").join(&self.spec.file_name)
    }

    fn part_path(&self) -> PathBuf {
        self.data.join("models").join(format!("{}.part", self.spec.file_name))
    }

    fn model_present(&self) -> bool {
        std::fs::metadata(self.model_path()).map(|m| m.len() == self.spec.size).unwrap_or(false)
    }

    /// `{"state":"missing"|"downloading"|"ready"|"error", ...}` for `GET /api/models/embedder`.
    pub fn status(&self) -> Value {
        let mut v = if self.model_present() {
            json!({"state": "ready"})
        } else {
            match self.dl.lock().unwrap().clone() {
                Dl::Idle => json!({"state": "missing"}),
                Dl::Downloading { bytes, total } => json!({"state": "downloading", "bytes": bytes, "total": total}),
                Dl::Error(m) => json!({"state": "error", "error": m}),
            }
        };
        v["file"] = json!(self.spec.file_name);
        v["size"] = json!(self.spec.size);
        v["library_found"] = json!(self.lib.is_file());
        v
    }

    /// Start the download unless the model is there or a download is running. Returns the status.
    pub fn start_download(self: &Arc<Self>) -> Value {
        if !self.model_present() {
            let mut dl = self.dl.lock().unwrap();
            if !matches!(*dl, Dl::Downloading { .. }) {
                *dl = Dl::Downloading { bytes: std::fs::metadata(self.part_path()).map(|m| m.len()).unwrap_or(0), total: self.spec.size };
                let me = self.clone();
                std::thread::spawn(move || {
                    let r = me.download();
                    *me.dl.lock().unwrap() = match r {
                        Ok(()) => Dl::Idle,
                        Err(m) => Dl::Error(m),
                    };
                });
            }
        }
        self.status()
    }

    fn set_progress(&self, bytes: u64, total: u64) {
        *self.dl.lock().unwrap() = Dl::Downloading { bytes, total };
    }

    /// The blocking download: resume `<file>.part`, check size and sha256, then rename into place.
    fn download(&self) -> Result<(), String> {
        let dir = self.data.join("models");
        std::fs::create_dir_all(&dir).map_err(|e| format!("Could not make {}: {e}", dir.display()))?;
        let part = self.part_path();
        let agent = fetch::agent();
        let mut have = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
        if have > self.spec.size {
            let _ = std::fs::remove_file(&part);
            have = 0;
        }
        let mut restarted = false;
        let mut cur = self.spec.url.clone();
        let mut hops = 0;
        let (body, start) = loop {
            fetch::parse_url(&cur).filter(fetch::scheme_ok).ok_or("That is not an address the server can download from.")?;
            let mut req = agent.get(&cur);
            if have > 0 {
                req = req.set("Range", &format!("bytes={have}-"));
            }
            let resp = match req.call() {
                Ok(r) => r,
                Err(ureq::Error::Status(416, r)) => {
                    let whole = r.header("content-range").and_then(|c| c.strip_prefix("bytes */")).and_then(|t| t.trim().parse::<u64>().ok());
                    if have > 0 && whole == Some(have) {
                        break (None, have);
                    }
                    if have == 0 || restarted {
                        return Err("The download server would not continue the file.".into());
                    }
                    let _ = std::fs::remove_file(&part);
                    have = 0;
                    restarted = true;
                    continue;
                }
                Err(ureq::Error::Status(code, _)) => return Err(format!("The download server answered {code}.")),
                Err(e) => return Err(format!("The connection failed: {e}")),
            };
            let status = resp.status();
            if matches!(status, 301 | 302 | 303 | 307 | 308) {
                hops += 1;
                let loc = resp.header("location").filter(|_| hops <= 8).ok_or("The download server redirected too many times.")?;
                cur = fetch::resolve(&cur, loc).ok_or("The download server sent a bad redirect.")?;
                continue;
            }
            match status {
                206 => {
                    let cr = resp.header("content-range").unwrap_or("").to_string();
                    let from = cr.strip_prefix("bytes ").and_then(|r| r.split('-').next()).and_then(|s| s.trim().parse::<u64>().ok());
                    if from != Some(have) {
                        return Err("The download server continued from the wrong place. Try again.".into());
                    }
                    break (Some(resp.into_reader()), have);
                }
                200 => break (Some(resp.into_reader()), 0),
                other => return Err(format!("The download server answered {other}.")),
            }
        };
        let total = self.spec.size;
        let margin = (total / 20).max(64 << 20);
        let needed = (total - start.min(total)) + margin;
        if let Some(avail) = free_bytes(&dir) {
            if avail < needed {
                return Err(format!("Not enough free space on the server: {} MB needed, {} MB free.", needed >> 20, avail >> 20));
            }
        }
        if let Some(mut reader) = body {
            let mut f = if start == 0 { std::fs::File::create(&part) } else { std::fs::OpenOptions::new().append(true).open(&part) }
                .map_err(|e| format!("Could not write the file: {e}"))?;
            let mut buf = vec![0u8; 256 << 10];
            let mut done = start;
            let mut last = Instant::now();
            self.set_progress(done, total);
            loop {
                let n = reader.read(&mut buf).map_err(|e| format!("The connection failed: {e}"))?;
                if n == 0 {
                    break;
                }
                f.write_all(&buf[..n]).map_err(|e| format!("Could not write the file: {e}"))?;
                done += n as u64;
                if last.elapsed() >= Duration::from_millis(250) {
                    last = Instant::now();
                    self.set_progress(done, total);
                }
            }
            f.sync_all().map_err(|e| format!("Could not write the file: {e}"))?;
            self.set_progress(done, total);
        }
        let size = std::fs::metadata(&part).map_err(|e| e.to_string())?.len();
        if size != total {
            if size > total {
                let _ = std::fs::remove_file(&part);
            }
            return Err(format!("The download stopped early ({} of {} MB). Download it again to continue.", size >> 20, total >> 20));
        }
        let got = sha256_file(&part).map_err(|e| format!("Could not read the file: {e}"))?;
        if !got.eq_ignore_ascii_case(&self.spec.sha256) {
            let _ = std::fs::remove_file(&part);
            return Err("The file did not match its published checksum, so it was thrown away. Try again.".into());
        }
        std::fs::rename(&part, self.model_path()).map_err(|e| format!("Could not put the file in place: {e}"))?;
        self.verified.store(true, Ordering::Relaxed);
        Ok(())
    }

    /// Embed `texts` with one loaded context (loading the model first when it is not loaded). Blocking, and only one batch runs at
    /// a time. Errors: `model_missing` (503; the download is started), `embed_unavailable` (503), `bad_text` (400).
    pub fn embed_batch(self: &Arc<Self>, texts: &[String]) -> Result<Vec<Vec<f32>>, ApiErr> {
        let mut slot = self.loaded.lock().unwrap();
        if slot.is_none() {
            if !self.model_present() {
                let st = self.start_download();
                let how = if st["state"] == "downloading" { "downloading" } else { "not downloaded" };
                return Err(err(503, "model_missing", format!("The search model is not on the server yet (it is {how}); try again when it is ready.")));
            }
            #[cfg(target_arch = "x86_64")]
            if !(is_x86_feature_detected!("avx2") && is_x86_feature_detected!("fma") && is_x86_feature_detected!("f16c")) {
                return Err(err(503, "embed_unavailable", "This CPU has no AVX2, FMA and F16C, which the embedding library needs."));
            }
            if !self.lib.is_file() {
                return Err(err(503, "embed_unavailable", format!("The embedding library {} is not installed.", self.lib.display())));
            }
            let want = if self.verified.load(Ordering::Relaxed) { None } else { Some(self.spec.sha256.as_str()) };
            let e = Embedder::load(&self.lib.to_string_lossy(), &self.model_path().to_string_lossy(), None, want, self.threads)
                .map_err(|e| err(503, "embed_unavailable", format!("The embedding model could not be loaded: {e}")))?;
            self.verified.store(true, Ordering::Relaxed);
            *slot = Some(Loaded { embedder: e, last: Instant::now() });
        }
        let l = slot.as_mut().unwrap();
        let mut out = Vec::with_capacity(texts.len());
        for (i, t) in texts.iter().enumerate() {
            match l.embedder.embed(t) {
                Ok(v) => out.push(v),
                Err(e) if e.code == "bad_json" => return Err(err(400, "bad_text", format!("texts[{i}]: {}", e.message))),
                Err(e) => return Err(err(500, "embed_failed", format!("texts[{i}]: {e}"))),
            }
        }
        l.last = Instant::now();
        Ok(out)
    }

    /// Whether vectors can be made now: Ok, or why not (a missing model also starts its download). The library builder waits on this.
    pub fn ready_reason(self: &Arc<Self>) -> Result<(), String> {
        if !self.model_present() {
            self.start_download();
            return Err("waiting for the search model".to_string());
        }
        if !self.lib.is_file() {
            return Err("the search model's library is not installed on this device".to_string());
        }
        Ok(())
    }

    /// The model id a vector carries (equals a library's `embedding.model`).
    pub fn model_id(&self) -> &str {
        &self.spec.file_name
    }

    /// Let the loaded model go when it has been idle for `idle` (and no batch is running).
    pub fn reap_idle(&self, idle: Duration) {
        if let Ok(mut slot) = self.loaded.try_lock() {
            if slot.as_ref().is_some_and(|l| l.last.elapsed() >= idle) {
                *slot = None;
            }
        }
    }

    pub fn is_loaded(&self) -> bool {
        self.loaded.lock().map(|s| s.is_some()).unwrap_or(false)
    }
}

fn sha256_file(path: &Path) -> std::io::Result<String> {
    let mut f = std::fs::File::open(path)?;
    let mut ctx = digest::Context::new(&digest::SHA256);
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = f.read(&mut buf)?;
        if n == 0 {
            break;
        }
        ctx.update(&buf[..n]);
    }
    Ok(hex(ctx.finish().as_ref()))
}

#[derive(Serialize)]
struct Vectors<'a> {
    vectors: &'a [Vec<f32>],
    model: &'a str,
    dims: usize,
}

/// The `{"ok":true,"result":{"vectors","model","dims"}}` body (f32 values are written as f32, not widened).
pub fn vectors_json(vectors: &[Vec<f32>], model: &str) -> String {
    let dims = vectors.first().map_or(0, Vec::len);
    format!(r#"{{"ok":true,"result":{}}}"#, serde_json::to_string(&Vectors { vectors, model, dims }).unwrap_or_else(|_| "null".into()))
}

/// The texts of a `POST /api/embed` body, checked.
pub fn parse_texts(body: &[u8]) -> Result<Vec<String>, ApiErr> {
    let v: Value = serde_json::from_slice(body).map_err(|_| err(400, "bad_json", "the body is not JSON"))?;
    let arr = v["texts"].as_array().ok_or_else(|| err(400, "bad_json", "\"texts\" (an array of strings) is required"))?;
    if arr.is_empty() || arr.len() > MAX_TEXTS {
        return Err(err(400, "bad_json", format!("\"texts\" takes 1 to {MAX_TEXTS} texts")));
    }
    let mut out = Vec::with_capacity(arr.len());
    for (i, t) in arr.iter().enumerate() {
        let s = t.as_str().ok_or_else(|| err(400, "bad_json", format!("texts[{i}] is not a string")))?;
        if s.trim().is_empty() {
            return Err(err(400, "bad_text", format!("texts[{i}] is empty")));
        }
        if s.len() > MAX_TEXT_BYTES {
            return Err(err(400, "bad_text", format!("texts[{i}] is longer than {MAX_TEXT_BYTES} bytes")));
        }
        out.push(s.to_string());
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;
    use std::net::TcpListener;

    #[test]
    fn the_pinned_model_matches_the_app() {
        let s = ModelSpec::bge_m3();
        assert_eq!(s.file_name, "bge-m3-Q8_0.gguf");
        assert_eq!(s.size, 634_553_856);
        assert_eq!(s.sha256, "c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb");
        assert_eq!(s.url, "https://huggingface.co/lm-kit/bge-m3-gguf/resolve/9379ce497e8814b200f2dc0d18eb4045426dcb8c/bge-m3-Q8_0.gguf");
    }

    #[test]
    fn texts_are_checked() {
        assert_eq!(parse_texts(br#"{"texts":["a","b"]}"#).unwrap(), vec!["a", "b"]);
        for bad in [&br#"nope"#[..], br#"{}"#, br#"{"texts":[]}"#, br#"{"texts":[1]}"#, br#"{"texts":["  "]}"#] {
            assert_eq!(parse_texts(bad).unwrap_err().status, 400);
        }
        let many = json!({"texts": vec!["x"; MAX_TEXTS + 1]}).to_string();
        assert_eq!(parse_texts(many.as_bytes()).unwrap_err().status, 400);
        let max = json!({"texts": vec!["x"; MAX_TEXTS]}).to_string();
        assert_eq!(parse_texts(max.as_bytes()).unwrap().len(), MAX_TEXTS);
    }

    #[test]
    fn vectors_are_written_as_f32() {
        let s = vectors_json(&[vec![0.1f32, -0.25]], "m");
        assert_eq!(s, r#"{"ok":true,"result":{"vectors":[[0.1,-0.25]],"model":"m","dims":2}}"#);
    }

    #[test]
    fn a_missing_model_starts_the_download_and_says_so() {
        let d = TempDir::new("embed-missing");
        let svc = EmbedService::with_spec(d.0.clone(), d.0.join("none.so"), ModelSpec { url: "http://127.0.0.1:1/x".into(), ..ModelSpec::bge_m3() });
        assert_eq!(svc.status()["state"], "missing");
        assert_eq!(svc.status()["library_found"], false);
        let e = svc.embed_batch(&["hello".to_string()]).unwrap_err();
        assert_eq!((e.status, e.code), (503, "model_missing"));
    }

    /// A one-file origin on this machine that honours `Range`.
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

    fn wait_done(svc: &EmbedService) -> Value {
        for _ in 0..200 {
            let st = svc.status();
            if st["state"] != "downloading" && st["state"] != "missing" {
                return st;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        panic!("the download did not finish: {}", svc.status());
    }

    #[test]
    fn the_model_downloads_resumes_and_is_checked() {
        let body: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let url = origin(body.clone());
        let sha = hex(digest::digest(&digest::SHA256, &body).as_ref());
        let spec = ModelSpec { file_name: "m.gguf".into(), size: body.len() as u64, sha256: sha, url };
        let d = TempDir::new("embed-dl");
        // a part file from an interrupted download is continued, not started again
        std::fs::create_dir_all(d.0.join("models")).unwrap();
        std::fs::write(d.0.join("models").join("m.gguf.part"), &body[..100_000]).unwrap();
        let svc = EmbedService::with_spec(d.0.clone(), d.0.join("none.so"), spec.clone());
        let st = svc.start_download();
        assert!(st["state"] == "downloading" || st["state"] == "ready", "{st}");
        assert_eq!(wait_done(&svc)["state"], "ready");
        assert_eq!(std::fs::read(svc.model_path()).unwrap(), body);
        assert!(!svc.part_path().exists());
        // downloading again when the model is there changes nothing
        assert_eq!(svc.start_download()["state"], "ready");

        // a wrong checksum throws the file away and says so
        let d2 = TempDir::new("embed-dl-bad");
        let bad = EmbedService::with_spec(d2.0.clone(), d2.0.join("none.so"), ModelSpec { sha256: "0".repeat(64), ..spec });
        bad.start_download();
        let st = wait_done(&bad);
        assert_eq!(st["state"], "error");
        assert!(st["error"].as_str().unwrap().contains("checksum"));
        assert!(!bad.part_path().exists() && !bad.model_path().exists());
    }
}
