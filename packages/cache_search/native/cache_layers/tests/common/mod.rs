#![allow(dead_code)]
//! Test helpers: a scratch folder, a fake tile host on 127.0.0.1 and an engine over a scratch folder.

use cache_layers::{Inner, LayersCfg};
use std::collections::HashMap;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use tiny_http::{Header, Response, Server};

pub struct Scratch(pub std::path::PathBuf);

impl Scratch {
    pub fn new(tag: &str) -> Scratch {
        let p = std::env::temp_dir().join(format!("cl-{tag}-{}-{}", std::process::id(), std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
        std::fs::create_dir_all(&p).unwrap();
        Scratch(p)
    }
    pub fn path(&self, s: &str) -> std::path::PathBuf {
        self.0.join(s)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

pub fn engine(dir: &Scratch) -> Inner {
    Inner::open(LayersCfg { dir: dir.path("layers").to_string_lossy().into_owned(), defs_dirs: vec![], catalogue_urls: vec![], cache_max_bytes: 64 * 1024 * 1024, online: true }).unwrap()
}

/// What a fake host got.
#[derive(Default)]
pub struct Stats {
    pub hits: AtomicUsize,
    pub per_url: Mutex<HashMap<String, usize>>,
    pub agents: Mutex<Vec<String>>,
    pub in_flight: AtomicUsize,
    pub max_in_flight: AtomicUsize,
}

pub struct Fake {
    pub port: u16,
    pub stats: Arc<Stats>,
}

impl Fake {
    pub fn url(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{}", self.port, path)
    }
}

/// `handler(url, range)` -> (status, body). A range is applied by the handler. `delay_ms` makes every answer slow.
pub fn fake_host(delay_ms: u64, handler: impl Fn(&str, Option<(u64, u64)>) -> (u16, Vec<u8>) + Send + Sync + 'static) -> Fake {
    fake_host_n(8, delay_ms, handler)
}

/// Like `fake_host` with `threads` serving threads (a handler that sleeps holds its thread).
pub fn fake_host_n(threads: usize, delay_ms: u64, handler: impl Fn(&str, Option<(u64, u64)>) -> (u16, Vec<u8>) + Send + Sync + 'static) -> Fake {
    let server = Arc::new(Server::http("127.0.0.1:0").unwrap());
    let port = server.server_addr().to_ip().unwrap().port();
    let stats = Arc::new(Stats::default());
    let handler = Arc::new(handler);
    for _ in 0..threads {
        let (s, st, h) = (server.clone(), stats.clone(), handler.clone());
        std::thread::spawn(move || {
            while let Ok(req) = s.recv() {
                let url = req.url().to_string();
                st.hits.fetch_add(1, Ordering::SeqCst);
                *st.per_url.lock().unwrap().entry(url.clone()).or_default() += 1;
                let ua = req.headers().iter().find(|h| h.field.equiv("User-Agent")).map(|h| h.value.to_string()).unwrap_or_default();
                st.agents.lock().unwrap().push(ua);
                let range = req.headers().iter().find(|h| h.field.equiv("Range")).and_then(|h| {
                    let v = h.value.to_string();
                    let r = v.strip_prefix("bytes=")?;
                    let (a, b) = r.split_once('-')?;
                    let (a, b): (u64, u64) = (a.parse().ok()?, b.parse().ok()?);
                    Some((a, b - a + 1))
                });
                let n = st.in_flight.fetch_add(1, Ordering::SeqCst) + 1;
                st.max_in_flight.fetch_max(n, Ordering::SeqCst);
                if delay_ms > 0 {
                    std::thread::sleep(std::time::Duration::from_millis(delay_ms));
                }
                let (status, body) = h(&url, range);
                st.in_flight.fetch_sub(1, Ordering::SeqCst);
                let mut r = Response::from_data(body).with_status_code(status);
                if range.is_some() && status == 200 {
                    r = r.with_status_code(206);
                }
                r = r.with_header(Header::from_bytes("Content-Type", "application/octet-stream").unwrap());
                let _ = req.respond(r);
            }
        });
    }
    Fake { port, stats }
}

/// `/z/x/y` -> (z, x, y)
pub fn parse_zxy(url: &str) -> Option<(u8, u32, u32)> {
    let p: Vec<&str> = url.trim_start_matches('/').split('?').next()?.split('/').collect();
    if p.len() != 3 {
        return None;
    }
    Some((p[0].parse().ok()?, p[1].parse().ok()?, p[2].split('.').next()?.parse().ok()?))
}

pub fn gunzip(b: &[u8]) -> Vec<u8> {
    use std::io::Read;
    let mut o = Vec::new();
    flate2::read::GzDecoder::new(b).read_to_end(&mut o).unwrap();
    o
}
