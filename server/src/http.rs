//! The routes. `route` turns one request (method, path, cookie, body) into one reply and knows nothing about sockets, so the
//! tests call it directly; `serve_connection` is the thin layer that speaks HTTP over a stream.
//!
//! Paths:
//!   POST /auth/login    {"password"}        -> 204 and the session cookie; 401 (held back after repeated failures)
//!   POST /auth/logout                       -> 204
//!   GET  /auth/check                        -> 204 signed in, 401 not
//!   POST /api/core      {"op","args"}       -> the core helper's {"ok":true,"result"} or {"ok":false,"error"} (200 either way);
//!                                              "open" and "close" are answered here, not forwarded: the server owns the one engine
//!   GET  /api/status                        -> the same, for the "status" op
//!   anything else                           -> a file from the web folder (no sign-in needed)
//!
//! `/api/` needs a valid session. An error from the server itself is `{"ok":false,"error":{"code","message"}}`: 401 not signed
//! in, 400 bad request, 404 no such endpoint, 503 `core_unavailable` while the helper is down. One line per request goes to
//! stderr: method, path, status, milliseconds. Nothing from the request body or the headers is logged.

use crate::auth::{token_from_cookie, Auth};
use crate::helper::Helper;
use crate::webfiles::{self, Resolved};
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::{json, Value};
use std::convert::Infallible;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};
use tokio::io::{AsyncRead, AsyncWrite};

/// The largest request body taken, in bytes.
const MAX_BODY: usize = 1 << 20;
/// The largest body of a signed-in `/api/core` call (imports and uploads travel through it).
const MAX_CORE_BODY: usize = 64 << 20;

pub struct App {
    pub auth: Arc<Auth>,
    /// `None` only in tests that never reach the core.
    pub helper: Option<Arc<Helper>>,
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

    fn error(status: u16, code: &str, message: impl AsRef<str>) -> Reply {
        Reply::json(status, json!({"ok": false, "error": {"code": code, "message": message.as_ref()}}).to_string())
    }

    fn with(mut self, k: &'static str, v: String) -> Reply {
        self.headers.push((k, v));
        self
    }
}

/// Run one op on the helper and shape its reply for the browser.
async fn core_call(app: &App, op: &str, args: Value) -> Reply {
    let Some(helper) = app.helper.clone() else { return Reply::error(503, "core_unavailable", "the core is not available: no helper") };
    match helper.call(op, args).await {
        Ok(mut reply) => {
            let body = if reply["ok"] == json!(true) {
                json!({"ok": true, "result": reply["result"].take()})
            } else {
                json!({"ok": false, "error": reply["error"].take()})
            };
            Reply::json(200, body.to_string())
        }
        Err(message) => Reply::error(503, "core_unavailable", message),
    }
}

async fn api(app: &App, method: &str, path: &str, body: &[u8]) -> Reply {
    match (method, path) {
        ("GET", "/api/status") => core_call(app, "status", json!({})).await,
        ("POST", "/api/core") => {
            let parsed: Result<Value, _> = serde_json::from_slice(body);
            let Ok(req) = parsed else { return Reply::error(400, "bad_json", "the body is not JSON") };
            let Some(op) = req["op"].as_str() else { return Reply::error(400, "bad_json", "\"op\" (string) is required") };
            let args = match &req["args"] {
                Value::Null => json!({}),
                a @ Value::Object(_) => a.clone(),
                _ => return Reply::error(400, "bad_json", "\"args\" must be an object"),
            };
            // The server owns the one shared engine, so a tab can neither replace nor close it.
            if op == "open" || op == "close" {
                return Reply::json(200, json!({"ok": true, "result": null}).to_string());
            }
            core_call(app, op, args).await
        }
        _ => Reply::error(404, "not_found", format!("no such endpoint: {method} {path}")),
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
                return Reply::error(401, "unauthorized", "sign in first");
            }
            api(app, method, path, body).await
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
    // The big limit is for signed-in /api/core calls only; everyone else gets the small one before anything is read.
    let signed_in = cookie.as_deref().and_then(token_from_cookie).is_some_and(|t| app.auth.is_signed_in(t));
    let limit = if path == "/api/core" && signed_in { MAX_CORE_BODY } else { MAX_BODY };
    let reply = match Limited::new(req.into_body(), limit).collect().await {
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
        App { auth: Arc::new(auth), helper: None, web: dir.0.join("web") }
    }

    #[tokio::test]
    async fn api_needs_a_session() {
        let d = TempDir::new("http");
        let a = app(&d);
        for (m, p) in [("GET", "/api/status"), ("POST", "/api/core"), ("GET", "/api/other")] {
            let r = route(&a, m, p, None, b"{}").await;
            assert_eq!(r.status, 401, "{m} {p}");
            let v: Value = serde_json::from_slice(&r.body).unwrap();
            assert_eq!((v["ok"].clone(), v["error"]["code"].clone()), (json!(false), json!("unauthorized")));
        }
        let r = route(&a, "POST", "/api/core", Some("cache_session=forged"), b"{}").await;
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
        // signed in, but there is no helper in this test
        let r = route(&a, "POST", "/api/core", Some(pair), br#"{"op":"version","args":{}}"#).await;
        assert_eq!(r.status, 503);
        assert_eq!(serde_json::from_slice::<Value>(&r.body).unwrap()["error"]["code"], "core_unavailable");
        // malformed calls, unknown endpoints
        assert_eq!(route(&a, "POST", "/api/core", Some(pair), b"nope").await.status, 400);
        assert_eq!(route(&a, "POST", "/api/core", Some(pair), br#"{"args":{}}"#).await.status, 400);
        assert_eq!(route(&a, "POST", "/api/core", Some(pair), br#"{"op":"x","args":[1]}"#).await.status, 400);
        assert_eq!(route(&a, "GET", "/api/search", Some(pair), b"").await.status, 404);
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
