//! The routes. `route` turns one request (method, path, cookie, body) into one reply and knows nothing about sockets, so the
//! tests call it directly; `serve_connection` is the thin layer that speaks HTTP over a stream.
//!
//! Paths:
//!   POST /auth/login    {"password"}        -> 204 and the session cookie; 401 (held back after repeated failures)
//!   POST /auth/logout                       -> 204
//!   GET  /auth/check                        -> 204 signed in, 401 not
//!   GET  /api/status                        -> Core::status
//!   POST /api/search    {query, options}    -> Core::search
//!   POST /api/read      {address, max_chars}-> Core::read
//!   GET  /api/tools                         -> Core::tool_schemas
//!   anything else                           -> a file from the web folder (no sign-in needed)
//!
//! `/api/` needs a valid session. Errors from the core are its own `{"code","message"}` with `ApiError::http_status`.
//! One line per request goes to stderr: method, path, status, milliseconds. Nothing from the request body or the headers is logged.

use crate::auth::{token_from_cookie, Auth};
use crate::webfiles::{self, Resolved};
use cache_search_cli::engine::{ApiError, Core};
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::{json, Value};
use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncWrite};

/// The largest request body taken, in bytes.
const MAX_BODY: usize = 1 << 20;

/// The core handle, which holds a raw pointer and so is not `Send` on its own.
pub struct CoreCell(pub Core);

// SAFETY: the C ABI wants a handle used by one call at a time, not by one thread. Every use goes through the Mutex in `App`,
// so calls never overlap, and moving the handle between threads between calls is allowed.
unsafe impl Send for CoreCell {}

pub struct App {
    pub auth: Arc<Auth>,
    /// `None` only in tests that never reach the core.
    pub core: Option<Arc<Mutex<CoreCell>>>,
    pub web: PathBuf,
}

pub struct Reply {
    pub status: u16,
    pub headers: Vec<(&'static str, String)>,
    pub body: Vec<u8>,
}

impl Reply {
    fn empty(status: u16) -> Reply {
        Reply { status, headers: vec![], body: vec![] }
    }

    fn json(status: u16, body: String) -> Reply {
        Reply { status, headers: vec![("Content-Type", "application/json".into())], body: body.into_bytes() }
    }

    fn api_error(e: &ApiError) -> Reply {
        Reply::json(e.http_status(), e.to_json())
    }

    fn with(mut self, k: &'static str, v: String) -> Reply {
        self.headers.push((k, v));
        self
    }
}

fn bad(msg: impl Into<String>) -> ApiError {
    ApiError::new("bad_json", msg)
}

fn body_json(body: &[u8]) -> Result<Value, ApiError> {
    if body.iter().all(u8::is_ascii_whitespace) {
        return Ok(json!({}));
    }
    serde_json::from_slice(body).map_err(|e| bad(format!("request body: {e}")))
}

fn need_str<'a>(v: &'a Value, key: &str) -> Result<&'a str, ApiError> {
    v[key].as_str().ok_or_else(|| bad(format!("\"{key}\" (string) is required")))
}

/// Run one core call on a blocking thread, holding the lock for the whole call.
async fn with_core<F>(app: &App, f: F) -> Result<String, ApiError>
where
    F: FnOnce(&mut Core) -> Result<String, ApiError> + Send + 'static,
{
    let Some(core) = app.core.clone() else { return Err(ApiError::new("internal", "the core is not open")) };
    tokio::task::spawn_blocking(move || {
        let mut g = core.lock().unwrap_or_else(|e| e.into_inner());
        f(&mut g.0)
    })
    .await
    .map_err(|e| ApiError::new("internal", format!("core call failed: {e}")))?
}

async fn api(app: &App, method: &str, path: &str, body: &[u8]) -> Result<String, ApiError> {
    match (method, path) {
        ("GET", "/api/status") => with_core(app, |c| c.status()).await,
        ("GET", "/api/tools") => with_core(app, |c| c.tool_schemas()).await,
        ("POST", "/api/search") => {
            let v = body_json(body)?;
            let query = need_str(&v, "query")?.to_string();
            let options = match &v["options"] {
                Value::Null => json!({}),
                o @ Value::Object(_) => o.clone(),
                _ => return Err(bad("\"options\" must be an object")),
            };
            // TODO: the query embedder (hybrid search) comes later; this is keyword search only.
            with_core(app, move |c| c.search(&query, &options.to_string())).await
        }
        ("POST", "/api/read") => {
            let v = body_json(body)?;
            let address = need_str(&v, "address")?.to_string();
            let max = match &v["max_chars"] {
                Value::Null => 6000,
                m => m.as_i64().filter(|n| i32::try_from(*n).is_ok()).ok_or_else(|| bad("\"max_chars\" must be an integer"))? as i32,
            };
            with_core(app, move |c| c.read(&address, max)).await
        }
        _ => Err(ApiError::new("not_found", format!("no such endpoint: {method} {path}"))),
    }
}

async fn login(app: &App, body: &[u8]) -> Reply {
    let password = match serde_json::from_slice::<Value>(body).ok().and_then(|v| v["password"].as_str().map(str::to_string)) {
        Some(p) => p,
        None => return Reply::empty(400),
    };
    let auth = app.auth.clone();
    let result = tokio::task::spawn_blocking(move || auth.login(&password)).await;
    match result {
        Ok(Ok(Some(token))) => Reply::empty(204).with("Set-Cookie", app.auth.cookie(&token, crate::auth::SESSION_SECS)),
        Ok(Ok(None)) => {
            let wait = app.auth.record_failure();
            if !wait.is_zero() {
                tokio::time::sleep(wait).await;
            }
            Reply::empty(401)
        }
        _ => Reply::empty(500),
    }
}

/// One request to one reply.
pub async fn route(app: &App, method: &str, path: &str, cookie: Option<&str>, body: &[u8]) -> Reply {
    let token = cookie.and_then(token_from_cookie);
    let signed_in = token.is_some_and(|t| app.auth.is_signed_in(t));
    match (method, path) {
        ("POST", "/auth/login") => login(app, body).await,
        ("POST", "/auth/logout") => {
            if let Some(t) = token {
                if app.auth.logout(t).is_err() {
                    return Reply::empty(500);
                }
            }
            Reply::empty(204).with("Set-Cookie", app.auth.cookie("", 0))
        }
        ("GET", "/auth/check") => Reply::empty(if signed_in { 204 } else { 401 }),
        _ if path == "/api" || path.starts_with("/api/") => {
            if !signed_in {
                return Reply::empty(401);
            }
            match api(app, method, path, body).await {
                Ok(s) => Reply::json(200, s),
                Err(e) => Reply::api_error(&e),
            }
        }
        ("GET" | "HEAD", _) => {
            let head = method == "HEAD";
            let (root, p) = (app.web.clone(), path.to_string());
            let found = tokio::task::spawn_blocking(move || match webfiles::resolve(&root, &p) {
                Resolved::File(f) => std::fs::read(&f).map(|b| (webfiles::content_type(&f), b)).map_err(|_| 404),
                Resolved::Missing => Err(404),
                Resolved::Refused => Err(400),
            })
            .await;
            match found {
                Ok(Ok((ct, bytes))) => {
                    Reply { status: 200, headers: vec![("Content-Type", ct.into())], body: if head { vec![] } else { bytes } }
                }
                Ok(Err(code)) => Reply::empty(code),
                Err(_) => Reply::empty(500),
            }
        }
        _ => Reply::empty(405),
    }
}

async fn handle(app: Arc<App>, req: Request<Incoming>) -> Response<Full<Bytes>> {
    let started = Instant::now();
    let method = req.method().as_str().to_string();
    let path = req.uri().path().to_string();
    let cookie = req.headers().get(hyper::header::COOKIE).and_then(|v| v.to_str().ok()).map(str::to_string);
    let reply = match Limited::new(req.into_body(), MAX_BODY).collect().await {
        Ok(b) => route(&app, &method, &path, cookie.as_deref(), &b.to_bytes()).await,
        Err(_) => Reply::empty(413),
    };
    eprintln!("{method} {path} {} {}ms", reply.status, started.elapsed().as_millis());
    let mut resp = Response::new(Full::new(Bytes::from(reply.body)));
    *resp.status_mut() = hyper::StatusCode::from_u16(reply.status).unwrap_or(hyper::StatusCode::INTERNAL_SERVER_ERROR);
    let h = resp.headers_mut();
    for (k, v) in reply.headers {
        if let (Ok(k), Ok(v)) = (hyper::header::HeaderName::from_bytes(k.as_bytes()), hyper::header::HeaderValue::from_str(&v)) {
            h.append(k, v);
        }
    }
    h.insert("X-Content-Type-Options", hyper::header::HeaderValue::from_static("nosniff"));
    if path.starts_with("/api") || path.starts_with("/auth") {
        h.insert("Cache-Control", hyper::header::HeaderValue::from_static("no-store"));
    }
    resp
}

/// Speak HTTP/1.1 over one connection (plain or TLS) until it closes.
pub async fn serve_connection<S>(app: Arc<App>, stream: S)
where
    S: AsyncRead + AsyncWrite + Unpin + Send + 'static,
{
    let svc = service_fn(move |req| {
        let app = app.clone();
        async move { Ok::<_, Infallible>(handle(app, req).await) }
    });
    let conn = hyper::server::conn::http1::Builder::new().timer(TokioTimer::new()).header_read_timeout(Duration::from_secs(30)).serve_connection(TokioIo::new(stream), svc);
    let _ = conn.await;
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::{Sessions, StoredPassword};
    use crate::TempDir;

    fn app(dir: &TempDir) -> App {
        let auth = Auth::new(None, Sessions::load(&dir.0.join("sessions.json")), true);
        App { auth: Arc::new(auth), core: None, web: dir.0.join("web") }
    }

    #[tokio::test]
    async fn api_needs_a_session() {
        let d = TempDir::new("http");
        let a = app(&d);
        for (m, p) in [("GET", "/api/status"), ("POST", "/api/search"), ("POST", "/api/read"), ("GET", "/api/tools"), ("GET", "/api/other")] {
            assert_eq!(route(&a, m, p, None, b"{}").await.status, 401, "{m} {p}");
        }
        let r = route(&a, "GET", "/api/status", Some("cache_session=forged"), b"").await;
        assert_eq!(r.status, 401);
        assert_eq!(route(&a, "GET", "/auth/check", None, b"").await.status, 401);
    }

    #[tokio::test]
    async fn login_sets_a_cookie_and_it_works() {
        let d = TempDir::new("http2");
        let mut a = app(&d);
        a.auth = Arc::new(Auth::new(Some(StoredPassword::new("pw").unwrap()), Sessions::load(&d.0.join("sessions.json")), true));
        let r = route(&a, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
        assert_eq!(r.status, 204);
        let cookie = r.headers.iter().find(|(k, _)| *k == "Set-Cookie").unwrap().1.clone();
        for part in ["HttpOnly", "Secure", "SameSite=Strict", "Path=/"] {
            assert!(cookie.contains(part), "{cookie}");
        }
        let pair = cookie.split(';').next().unwrap();
        assert_eq!(route(&a, "GET", "/auth/check", Some(pair), b"").await.status, 204);
        // signed in, but the core is not open in this test
        assert_eq!(route(&a, "GET", "/api/status", Some(pair), b"").await.status, 500);
        assert_eq!(route(&a, "POST", "/auth/logout", Some(pair), b"").await.status, 204);
        assert_eq!(route(&a, "GET", "/auth/check", Some(pair), b"").await.status, 401);
    }

    #[tokio::test]
    async fn static_files_need_no_sign_in_and_traversal_is_refused() {
        let d = TempDir::new("http3");
        std::fs::create_dir_all(d.0.join("web")).unwrap();
        std::fs::write(d.0.join("web/index.html"), b"hi").unwrap();
        std::fs::write(d.0.join("secret.txt"), b"no").unwrap();
        let a = app(&d);
        let r = route(&a, "GET", "/", None, b"").await;
        assert_eq!((r.status, r.body.as_slice()), (200, &b"hi"[..]));
        assert_eq!(route(&a, "GET", "/../secret.txt", None, b"").await.status, 400);
        assert_eq!(route(&a, "GET", "/%2e%2e/secret.txt", None, b"").await.status, 400);
        assert_eq!(route(&a, "GET", "/missing.js", None, b"").await.status, 404);
        assert_eq!(route(&a, "DELETE", "/", None, b"").await.status, 405);
        std::fs::remove_file(d.0.join("web/index.html")).unwrap();
        let r = route(&a, "GET", "/", None, b"").await;
        assert_eq!((r.status, r.body.len()), (404, 0));
    }
}
