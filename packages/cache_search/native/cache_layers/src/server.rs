//! The local tile server: the one place the map reads tiles from. Bound to 127.0.0.1 on a random port.
//!
//!   GET /layers/{id}/{z}/{x}/{y}[.ext]   a tile (downloaded, then viewed before, then the source if online)
//!   GET /layers/{id}/tilejson.json       TileJSON (also /layers/{id}.json)
//!   GET /health                          {"ok":true}
//!
//! Answers: 200 with the tile; 204 where the source has no tile; 503 with `Retry-After` for a tile that may come later:
//! not on the device and no connection (`X-Cache-Status: miss`), or the source too slow or its queue full
//! (`X-Cache-Status: busy`); 503 `needs a connection` for an online-only layer with no connection
//! (`X-Cache-Status: needs-connection`); 400/404/502 with a JSON error otherwise (404: no such layer or path).
//!
//! A temporary miss is never a 404: MapLibre never asks for a 404 tile again, so the tile stayed blank until the style was
//! loaded again (build 46: 59 of 150 tiles of a fast pan). It retries a 5xx with a back-off.

use crate::core::{Inner, TileOut};
use crate::sched::{self, Outcome, Sched};
use crate::error::{Error, Result};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::JoinHandle;
use tiny_http::{Header, Method, Request, Response, Server as Tiny};

pub struct TileServer {
    pub port: u16,
    server: Arc<Tiny>,
    stop: Arc<AtomicBool>,
    threads: Vec<JoinHandle<()>>,
    /// A second handle on the listening socket, so a test can take the socket away as iOS does.
    #[cfg(test)]
    pub(crate) listener: std::net::TcpListener,
}

const WORKERS: usize = 8;

/// Seconds a map waits before asking again for a tile the source did not answer in time (or whose queue was full).
const RETRY_BUSY: &str = "1";
/// Seconds before asking again for a tile that needs the connection back (the map also reloads its sources when it returns).
const RETRY_OFFLINE: &str = "5";

impl TileServer {
    pub fn start(inner: Arc<Inner>) -> Result<TileServer> {
        let cannot = |e: &dyn std::fmt::Display| Error::io(format!("cannot start the tile server: {e}"));
        let listener = std::net::TcpListener::bind("127.0.0.1:0").map_err(|e| cannot(&e))?;
        #[cfg(test)]
        let kept = listener.try_clone().map_err(|e| cannot(&e))?;
        let server = Arc::new(Tiny::from_listener(listener, None).map_err(|e| cannot(&e))?);
        let port = server.server_addr().to_ip().map(|a| a.port()).ok_or_else(|| Error::internal("no port"))?;
        let stop = Arc::new(AtomicBool::new(false));
        let sched = Sched::new(inner.clone(), format!("http://127.0.0.1:{port}"));
        let mut threads = Vec::new();
        for i in 0..WORKERS {
            let (s, inner, stop, sched) = (server.clone(), inner.clone(), stop.clone(), sched.clone());
            threads.push(
                std::thread::Builder::new()
                    .name(format!("cs-tiles-{i}"))
                    .spawn(move || {
                        while !stop.load(Ordering::Relaxed) {
                            match s.recv_timeout(std::time::Duration::from_millis(250)) {
                                Ok(Some(req)) => {
                                    let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| handle(&inner, &sched, port, req)));
                                    let _ = r;
                                }
                                Ok(None) => {}
                                Err(_) => break,
                            }
                        }
                    })
                    .map_err(|e| Error::internal(format!("thread: {e}")))?,
            );
        }
        Ok(TileServer {
            port,
            server,
            stop,
            threads,
            #[cfg(test)]
            listener: kept,
        })
    }

    pub fn base_url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }
}

impl Drop for TileServer {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        self.server.unblock();
        for t in self.threads.drain(..) {
            let _ = t.join();
        }
    }
}

fn hdr(k: &str, v: &str) -> Header {
    Header::from_bytes(k.as_bytes(), v.as_bytes()).unwrap_or_else(|_| Header::from_bytes(&b"X-Bad"[..], &b"x"[..]).unwrap())
}

fn respond(req: Request, status: u16, body: Vec<u8>, headers: Vec<Header>) {
    let mut r = Response::from_data(body).with_status_code(status);
    r = r.with_header(hdr("Access-Control-Allow-Origin", "*"));
    for h in headers {
        r = r.with_header(h);
    }
    let _ = req.respond(r);
}

fn json_err(req: Request, status: u16, e: &Error) {
    let body = serde_json::json!({"code": e.code, "message": e.message}).to_string().into_bytes();
    respond(req, status, body, vec![hdr("Content-Type", "application/json")]);
}

/// The result of routing a path.
pub enum Route<'a> {
    Tile(&'a str, u8, u32, u32),
    TileJson(&'a str),
    Health,
    None,
}

pub fn route(path: &str) -> Route<'_> {
    let path = path.split('?').next().unwrap_or("");
    if path == "/health" {
        return Route::Health;
    }
    let Some(rest) = path.strip_prefix("/layers/") else { return Route::None };
    let parts: Vec<&str> = rest.split('/').collect();
    match parts.as_slice() {
        [id, "tilejson.json"] => Route::TileJson(id),
        [id] if id.ends_with(".json") => Route::TileJson(id.trim_end_matches(".json")),
        [id, z, x, y] => {
            let y = y.split('.').next().unwrap_or("");
            match (z.parse::<u8>(), x.parse::<u32>(), y.parse::<u32>()) {
                (Ok(z), Ok(x), Ok(y)) => Route::Tile(id, z, x, y),
                _ => Route::None,
            }
        }
        _ => Route::None,
    }
}

fn tile_response(req: Request, t: Result<TileOut>) {
    match t {
        Ok(TileOut::Tile { bytes, mime, from }) => respond(req, 200, bytes, vec![hdr("Content-Type", mime), hdr("X-Cache-Status", from)]),
        Ok(TileOut::Empty) => respond(req, 204, Vec::new(), vec![hdr("X-Cache-Status", "empty")]),
        Ok(TileOut::Miss) => respond(req, 503, b"not on this device and no connection".to_vec(), vec![hdr("X-Cache-Status", "miss"), hdr("Retry-After", RETRY_OFFLINE), hdr("Content-Type", "text/plain")]),
        Ok(TileOut::Busy) => respond(req, 503, b"busy, ask again".to_vec(), vec![hdr("X-Cache-Status", "busy"), hdr("Retry-After", RETRY_BUSY), hdr("Content-Type", "text/plain")]),
        Ok(TileOut::NeedsConnection) => respond(req, 503, b"needs a connection".to_vec(), vec![hdr("X-Cache-Status", "needs-connection"), hdr("Content-Type", "text/plain")]),
        Err(e) => json_err(req, e.http_status(), &e),
    }
}

fn json_response(req: Request, v: Result<serde_json::Value>) {
    match v {
        Ok(v) => respond(req, 200, v.to_string().into_bytes(), vec![hdr("Content-Type", "application/json")]),
        Err(e) => json_err(req, e.http_status(), &e),
    }
}

/// Answer what local storage can answer right here; hand anything that needs the source to the layer's lane, which
/// answers the request later from its own thread (this worker is free for the next request at once).
fn handle(inner: &Arc<Inner>, sched: &Arc<Sched>, port: u16, req: Request) {
    if *req.method() != Method::Get && *req.method() != Method::Head {
        return respond(req, 405, b"method not allowed".to_vec(), vec![]);
    }
    let url = req.url().to_string();
    match route(&url) {
        Route::Health => respond(req, 200, br#"{"ok":true}"#.to_vec(), vec![hdr("Content-Type", "application/json")]),
        Route::TileJson(id) => {
            if !inner.tilejson_needs_upstream(id) {
                return json_response(req, inner.tilejson(id, &format!("http://127.0.0.1:{port}")));
            }
            let cap = inner.def(id).map(|d| d.max_parallel()).unwrap_or(4);
            sched.submit(
                (id.to_string(), sched::TILEJSON, 0, 0),
                cap,
                Box::new(move |o| match o {
                    Outcome::Json(v) => json_response(req, Ok(v)),
                    Outcome::Err(e) => json_response(req, Err(e)),
                    Outcome::Tile(_) => json_response(req, Err(Error::internal("no TileJSON"))),
                }),
            );
        }
        Route::Tile(id, z, x, y) => match inner.tile_local(id, z, x, y) {
            Ok(Some(t)) => tile_response(req, Ok(t)),
            Err(e) => tile_response(req, Err(e)),
            Ok(None) => {
                let cap = inner.def(id).map(|d| d.max_parallel()).unwrap_or(4);
                sched.submit(
                    (id.to_string(), z, x, y),
                    cap,
                    Box::new(move |o| match o {
                        Outcome::Tile(t) => tile_response(req, Ok(t)),
                        Outcome::Err(e) => tile_response(req, Err(e)),
                        Outcome::Json(_) => tile_response(req, Err(Error::internal("no tile"))),
                    }),
                );
            }
        },
        Route::None => respond(req, 404, b"not found".to_vec(), vec![]),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn routes() {
        assert!(matches!(route("/layers/base/3/4/5"), Route::Tile("base", 3, 4, 5)));
        assert!(matches!(route("/layers/base/3/4/5.pbf?x=1"), Route::Tile("base", 3, 4, 5)));
        assert!(matches!(route("/layers/base/tilejson.json"), Route::TileJson("base")));
        assert!(matches!(route("/layers/base.json"), Route::TileJson("base")));
        assert!(matches!(route("/health"), Route::Health));
        assert!(matches!(route("/layers/base/a/b/c"), Route::None));
        assert!(matches!(route("/x"), Route::None));
    }
}
