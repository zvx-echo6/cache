//! The routes. `route` turns one request (method, path, cookie, body) into one reply and knows nothing about sockets, so the
//! tests call it directly; `serve_connection` is the thin layer that speaks HTTP over a stream.
//!
//! Paths:
//!   GET  /auth/state                        -> {"mode","start_with_password","security_key_available","key_file_available"}, no sign-in needed
//!   POST /auth/login    {"password"}        -> 204 and the session cookie; 200 {"step":2} and the half cookie (mode "both");
//!                                              401 (held back after repeated failures); 403 when the setting takes no password
//!   POST /auth/webauthn/start               -> {"id","options"} for navigator.credentials.get
//!   POST /auth/webauthn/finish {"id","credential"} -> 204 and the session cookie; 401 wrong
//!   POST /auth/keyfile  <the file's bytes, at most 4 KB> -> 204 and the session cookie; 401 wrong; 413 too big
//!                                              (the three key endpoints: 403 when the setting takes no key, 409 in mode "both" without
//!                                              the half cookie, which is the only thing they take it for)
//!   POST /auth/logout                       -> 204
//!   GET  /auth/check                        -> 204 signed in, 401 not
//!   POST /api/core      {"op","args"}       -> the core helper's {"ok":true,"result"} or {"ok":false,"error"} (200 either way);
//!                                              "open" and "close" are answered here, not forwarded: the server owns the one engine
//!   GET  /api/status                        -> the same, for the "status" op
//!   /api/settings/...                       -> the sign-in setting and the keys (signed in): GET|PUT signin, POST security-keys/start|finish,
//!                                              DELETE security-keys/<id>, POST key-files (the file), DELETE key-files/<id>
//!   GET  /settings/keys                     -> the keys settings page (signed in)
//!   anything else (GET/HEAD)                -> signed in: a file from the web folder. Not signed in: the sign-in page (200) for a page
//!                                              request ("/", "*.html", a path with no extension), 401 for anything else (assets)
//!
//! `/api/` needs a valid session. An error from the server itself is `{"ok":false,"error":{"code","message"}}`: 401 not signed
//! in, 400 bad request, 404 no such endpoint, 409 a lock-out guard, 503 `core_unavailable` while the helper is down. One line
//! per request goes to stderr: method, path, status, milliseconds. Nothing from the request body or the headers is logged.

use crate::auth::{half_from_cookie, key_file_name, token_from_cookie, Auth, Gate, KeyLogin, Login, Mode, SettingsError, KEYFILE_MAX};
use crate::keys::KeyError;
use crate::pages;
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
    if let Some(r) = settings(app, method, path, body) {
        return r;
    }
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

/// A wrong answer: counted, held back after repeated failures, then the 401.
async fn denied(app: &App) -> Reply {
    let wait = app.auth.record_failure();
    if !wait.is_zero() {
        tokio::time::sleep(wait).await;
    }
    Reply::empty(401)
}

fn gate_reply(g: Gate) -> Reply {
    match g {
        Gate::NotAllowed => Reply::empty(403),
        Gate::NeedHalf => Reply::empty(409),
    }
}

/// The reply that ends a sign-in: the session cookie, and the half cookie cleared.
fn signed_in_reply(app: &App, token: &str) -> Reply {
    Reply::empty(204).with("Set-Cookie", app.auth.cookie(token, crate::auth::SESSION_SECS)).with("Set-Cookie", app.auth.half_cookie("", 0))
}

async fn login(app: &App, body: &[u8]) -> Reply {
    let password = match serde_json::from_slice::<Value>(body).ok().and_then(|v| v["password"].as_str().map(str::to_string)) {
        Some(p) => p,
        None => return Reply::empty(400),
    };
    let auth = app.auth.clone();
    let result = tokio::task::spawn_blocking(move || auth.password_login(&password)).await;
    match result {
        Ok(Ok(Login::Full(token))) => signed_in_reply(app, &token),
        Ok(Ok(Login::Half(token))) => {
            Reply::json(200, json!({"step": 2}).to_string()).with("Set-Cookie", app.auth.half_cookie(&token, app.auth.half_secs))
        }
        Ok(Ok(Login::Wrong)) => denied(app).await,
        Ok(Ok(Login::NotAllowed)) => Reply::empty(403),
        _ => Reply::empty(500),
    }
}

async fn keyfile(app: &App, half: Option<&str>, body: &[u8]) -> Reply {
    if body.len() > KEYFILE_MAX {
        return Reply::empty(413);
    }
    let (auth, bytes, half) = (app.auth.clone(), body.to_vec(), half.map(str::to_string));
    match tokio::task::spawn_blocking(move || auth.keyfile_login(&bytes, half.as_deref())).await {
        Ok(Ok(KeyLogin::Full(token))) => signed_in_reply(app, &token),
        Ok(Ok(KeyLogin::Wrong)) => denied(app).await,
        Ok(Ok(KeyLogin::Gate(g))) => gate_reply(g),
        _ => Reply::empty(500),
    }
}

async fn webauthn_start(app: &App, half: Option<&str>) -> Reply {
    match app.auth.webauthn_start(half) {
        Ok((id, options)) => Reply::json(200, json!({"id": id, "options": options}).to_string()),
        Err(e) => key_error(e),
    }
}

fn key_error(e: KeyError) -> Reply {
    match e {
        KeyError::Gate(g) => gate_reply(g),
        KeyError::Unavailable => Reply::empty(404),
        KeyError::Wrong => Reply::empty(401),
        KeyError::Busy => Reply::empty(429),
        KeyError::Io(_) => Reply::empty(500),
    }
}

async fn webauthn_finish(app: &App, half: Option<&str>, body: &[u8]) -> Reply {
    let Ok(v) = serde_json::from_slice::<Value>(body) else { return Reply::empty(400) };
    let Some(id) = v["id"].as_str().map(str::to_string) else { return Reply::empty(400) };
    let Ok(credential) = serde_json::from_value(v["credential"].clone()) else { return Reply::empty(400) };
    let (auth, half) = (app.auth.clone(), half.map(str::to_string));
    match tokio::task::spawn_blocking(move || auth.webauthn_finish(&id, &credential, half.as_deref())).await {
        Ok(Ok(token)) => signed_in_reply(app, &token),
        Ok(Err(KeyError::Wrong)) => denied(app).await,
        Ok(Err(e)) => key_error(e),
        Err(_) => Reply::empty(500),
    }
}

fn ok(result: Value) -> Reply {
    Reply::json(200, json!({"ok": true, "result": result}).to_string())
}

fn settings_error(e: SettingsError) -> Reply {
    match e {
        SettingsError::Locked(m) => Reply::error(409, "locked_out", m),
        SettingsError::Invalid(m) => Reply::error(400, "invalid", m),
        SettingsError::NotFound => Reply::error(404, "not_found", "no such key"),
        SettingsError::NoWebauthn => Reply::error(409, "needs_hostname", "Needs a hostname with a trusted certificate"),
        SettingsError::Io(_) => Reply::error(500, "server_error", "could not save"),
    }
}

/// `/api/settings/...` (the caller has checked the session). `None` when the path is not one of these.
fn settings(app: &App, method: &str, path: &str, body: &[u8]) -> Option<Reply> {
    let rest = path.strip_prefix("/api/settings/")?;
    let auth = &app.auth;
    let json_body = || serde_json::from_slice::<Value>(body).ok();
    let name_of = |v: &Option<Value>| v.as_ref().and_then(|v| v["name"].as_str().map(str::to_string));
    Some(match (method, rest) {
        ("GET", "signin") => ok(auth.settings_view()),
        ("PUT", "signin") => {
            let v = json_body();
            let mode = v.as_ref().and_then(|v| v["mode"].as_str()).and_then(Mode::parse);
            let swp = v.as_ref().and_then(|v| v["start_with_password"].as_bool()).unwrap_or(false);
            let Some(mode) = mode else { return Some(Reply::error(400, "invalid", "unknown sign-in setting")) };
            match auth.set_signin(mode, swp && mode == Mode::Either) {
                Ok(()) => ok(auth.settings_view()),
                Err(e) => settings_error(e),
            }
        }
        ("POST", "security-keys/start") => {
            let Some(name) = name_of(&json_body()) else { return Some(Reply::error(400, "invalid", "A name is needed.")) };
            match auth.register_start(&name) {
                Ok((id, options)) => ok(json!({"id": id, "options": options})),
                Err(e) => settings_error(e),
            }
        }
        ("POST", "security-keys/finish") => {
            let v = json_body();
            let id = v.as_ref().and_then(|v| v["id"].as_str().map(str::to_string));
            let cred = v.as_ref().and_then(|v| serde_json::from_value(v["credential"].clone()).ok());
            let (Some(id), Some(cred)) = (id, cred) else { return Some(Reply::error(400, "invalid", "The key was not accepted.")) };
            match auth.register_finish(&id, &cred) {
                Ok(()) => ok(auth.settings_view()),
                Err(e) => settings_error(e),
            }
        }
        ("POST", "key-files") => {
            let Some(name) = name_of(&json_body()) else { return Some(Reply::error(400, "invalid", "A name is needed.")) };
            match auth.add_key_file(&name) {
                Ok((_, bytes)) => Reply {
                    status: 200,
                    headers: vec![
                        ("Content-Type", "application/octet-stream".into()),
                        ("Content-Disposition", format!("attachment; filename=\"{}\"", key_file_name(&name))),
                    ],
                    body: bytes,
                },
                Err(e) => settings_error(e),
            }
        }
        ("DELETE", r) if r.starts_with("security-keys/") => match auth.remove_security_key(&r["security-keys/".len()..]) {
            Ok(()) => ok(auth.settings_view()),
            Err(e) => settings_error(e),
        },
        ("DELETE", r) if r.starts_with("key-files/") => match auth.remove_key_file(&r["key-files/".len()..]) {
            Ok(()) => ok(auth.settings_view()),
            Err(e) => settings_error(e),
        },
        _ => return None,
    })
}

/// A path a browser would navigate to (so it gets the sign-in page), as opposed to an asset it would load.
fn is_page_path(path: &str) -> bool {
    let last = path.rsplit('/').next().unwrap_or("");
    last.is_empty() || !last.contains('.') || last.ends_with(".html") || last.ends_with(".htm")
}

fn html(body: &'static str, head: bool) -> Reply {
    Reply {
        status: 200,
        headers: vec![
            ("Content-Type", "text/html; charset=utf-8".into()),
            ("Cache-Control", "no-store".into()),
            ("X-Frame-Options", "DENY".into()),
            ("Referrer-Policy", "no-referrer".into()),
        ],
        body: if head { vec![] } else { body.as_bytes().to_vec() },
    }
}

/// One request to one reply.
pub async fn route(app: &App, method: &str, path: &str, cookie: Option<&str>, body: &[u8]) -> Reply {
    let token = cookie.and_then(token_from_cookie);
    let half = cookie.and_then(half_from_cookie);
    let signed_in = token.is_some_and(|t| app.auth.is_signed_in(t));
    match (method, path) {
        ("GET", "/auth/state") => Reply::json(200, app.auth.public_state().to_string()),
        ("POST", "/auth/login") => login(app, body).await,
        ("POST", "/auth/webauthn/start") => webauthn_start(app, half).await,
        ("POST", "/auth/webauthn/finish") => webauthn_finish(app, half, body).await,
        ("POST", "/auth/keyfile") => keyfile(app, half, body).await,
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
        ("GET" | "HEAD", _) if !signed_in => {
            // Nobody gets a file without a session: a browser navigating gets the sign-in page, an asset gets a 401.
            if is_page_path(path) && !path.starts_with("/auth/") {
                html(pages::signin_html(), method == "HEAD")
            } else {
                Reply::empty(401)
            }
        }
        ("GET" | "HEAD", "/settings/keys") => html(pages::keys_html(), method == "HEAD"),
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
    let limit = if path == "/api/core" && signed_in {
        MAX_CORE_BODY
    } else if path == "/auth/keyfile" {
        KEYFILE_MAX
    } else {
        MAX_BODY
    };
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
    if path.starts_with("/api") || path.starts_with("/auth") || path.starts_with("/settings") {
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

    /// An app whose `auth.json` holds the password "pw" (cheap hash), with WebAuthn off, signed-in session not yet made.
    fn file_app(dir: &TempDir) -> App {
        let mut f = crate::auth::AuthFile::default();
        f.password = Some(StoredPassword::with_iterations("pw", 1000).unwrap());
        f.save(&dir.0.join("auth.json")).unwrap();
        std::fs::create_dir_all(dir.0.join("web")).unwrap();
        std::fs::write(dir.0.join("web/index.html"), b"the app").unwrap();
        std::fs::write(dir.0.join("web/main.dart.js"), b"js").unwrap();
        std::fs::write(dir.0.join("secret.txt"), b"no").unwrap();
        App { auth: Arc::new(Auth::load(&dir.0, true).unwrap()), helper: None, web: dir.0.join("web") }
    }

    fn set_cookies(r: &Reply) -> Vec<String> {
        r.headers.iter().filter(|(k, _)| *k == "Set-Cookie").map(|(_, v)| v.split(';').next().unwrap().to_string()).collect()
    }

    fn cookie_of(r: &Reply, name: &str) -> String {
        set_cookies(r).into_iter().find(|c| c.starts_with(&format!("{name}="))).unwrap()
    }

    async fn sign_in(a: &App) -> String {
        let r = route(a, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
        assert_eq!(r.status, 204);
        cookie_of(&r, "cache_session")
    }

    async fn json_call(a: &App, method: &str, path: &str, cookie: &str, body: &str) -> (u16, Value) {
        let r = route(a, method, path, Some(cookie), body.as_bytes()).await;
        let v = serde_json::from_slice(&r.body).unwrap_or(Value::Null);
        (r.status, v)
    }

    fn body_str(r: &Reply) -> String {
        String::from_utf8_lossy(&r.body).to_string()
    }

    #[tokio::test]
    async fn without_a_session_pages_get_the_sign_in_page_and_assets_a_401() {
        let d = TempDir::new("route1");
        let a = file_app(&d);
        for p in ["/", "/index.html", "/some/route", "/settings/keys", "/folder/"] {
            let r = route(&a, "GET", p, None, b"").await;
            assert_eq!(r.status, 200, "{p}");
            assert!(r.headers.iter().any(|(k, v)| *k == "Content-Type" && v.starts_with("text/html")), "{p}");
            let b = body_str(&r);
            assert!(b.contains("<title>Sign in</title>") && !b.contains("the app") && !b.contains("Sign-in and keys"), "{p}");
        }
        for p in ["/main.dart.js", "/assets/logo.png", "/flutter_service_worker.js", "/secret.txt", "/../secret.txt", "/auth/other"] {
            let r = route(&a, "GET", p, None, b"").await;
            assert_eq!((r.status, r.body.len()), (401, 0), "{p}");
        }
        // HEAD answers like GET without the body
        let r = route(&a, "HEAD", "/", None, b"").await;
        assert_eq!((r.status, r.body.len()), (200, 0));
        // the API keeps its 401 JSON
        let r = route(&a, "POST", "/api/core", None, b"{}").await;
        assert_eq!(r.status, 401);
        assert_eq!(serde_json::from_slice::<Value>(&r.body).unwrap()["error"]["code"], "unauthorized");
        // a forged session is no session
        assert_eq!(route(&a, "GET", "/main.dart.js", Some("cache_session=forged"), b"").await.status, 401);
        // the page itself comes with no-store, so a signed-in copy of / is never mixed up with it
        let r = route(&a, "GET", "/", None, b"").await;
        assert!(r.headers.iter().any(|(k, v)| *k == "Cache-Control" && v == "no-store"));
    }

    #[tokio::test]
    async fn with_a_session_the_app_and_the_keys_page_are_served() {
        let d = TempDir::new("route2");
        let a = file_app(&d);
        let c = sign_in(&a).await;
        let r = route(&a, "GET", "/", Some(&c), b"").await;
        assert_eq!((r.status, body_str(&r).as_str()), (200, "the app"));
        let r = route(&a, "GET", "/main.dart.js", Some(&c), b"").await;
        assert_eq!((r.status, body_str(&r).as_str()), (200, "js"));
        let r = route(&a, "GET", "/settings/keys", Some(&c), b"").await;
        assert_eq!(r.status, 200);
        assert!(body_str(&r).contains("<title>Sign-in and keys</title>"));
        assert_eq!(route(&a, "GET", "/missing.js", Some(&c), b"").await.status, 404);
        assert_eq!(route(&a, "GET", "/../secret.txt", Some(&c), b"").await.status, 400);
        assert_eq!(route(&a, "GET", "/%2e%2e/secret.txt", Some(&c), b"").await.status, 400);
        assert_eq!(route(&a, "DELETE", "/", Some(&c), b"").await.status, 405);
        std::fs::remove_file(d.0.join("web/index.html")).unwrap();
        let r = route(&a, "GET", "/", Some(&c), b"").await;
        assert_eq!((r.status, r.body.len()), (404, 0));
    }

    #[tokio::test]
    async fn auth_state_says_the_four_things_and_nothing_else() {
        let d = TempDir::new("state");
        let a = file_app(&d);
        let r = route(&a, "GET", "/auth/state", None, b"").await;
        assert_eq!(r.status, 200);
        assert_eq!(
            serde_json::from_slice::<Value>(&r.body).unwrap(),
            json!({"mode": "password", "start_with_password": false, "security_key_available": false, "key_file_available": false})
        );
        let c = sign_in(&a).await;
        let (s, _) = json_call(&a, "POST", "/api/settings/key-files", &c, r#"{"name":"usb"}"#).await;
        assert_eq!(s, 200);
        assert_eq!(json_call(&a, "PUT", "/api/settings/signin", &c, r#"{"mode":"either","start_with_password":true}"#).await.0, 200);
        let r = route(&a, "GET", "/auth/state", None, b"").await;
        assert_eq!(
            serde_json::from_slice::<Value>(&r.body).unwrap(),
            json!({"mode": "either", "start_with_password": true, "security_key_available": false, "key_file_available": true})
        );
    }

    /// Make a key file through the settings API and switch the setting.
    async fn with_key_file(a: &App, mode: &str) -> Vec<u8> {
        let c = sign_in(a).await;
        let r = route(a, "POST", "/api/settings/key-files", Some(&c), br#"{"name":"Blue USB stick"}"#).await;
        assert_eq!(r.status, 200);
        let cd = r.headers.iter().find(|(k, _)| *k == "Content-Disposition").unwrap().1.clone();
        assert_eq!(cd, "attachment; filename=\"cache-Blue-USB-stick.key\"");
        assert!(r.body.starts_with(b"cache-key-1\n"));
        let (s, v) = json_call(a, "PUT", "/api/settings/signin", &c, &json!({"mode": mode}).to_string()).await;
        assert_eq!((s, v["result"]["mode"].clone()), (200, json!(mode)));
        r.body
    }

    #[tokio::test]
    async fn mode_either_password_and_key_file_both_sign_in() {
        let d = TempDir::new("either");
        let a = file_app(&d);
        let file = with_key_file(&a, "either").await;
        let r = route(&a, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
        assert_eq!(r.status, 204);
        let c = cookie_of(&r, "cache_session");
        assert_eq!(route(&a, "GET", "/auth/check", Some(&c), b"").await.status, 204);
        let r = route(&a, "POST", "/auth/keyfile", None, &file).await;
        assert_eq!(r.status, 204);
        let c = cookie_of(&r, "cache_session");
        assert_eq!(route(&a, "GET", "/auth/check", Some(&c), b"").await.status, 204);
        let cookie = r.headers.iter().find(|(k, v)| *k == "Set-Cookie" && v.starts_with("cache_session=")).unwrap().1.clone();
        for part in ["HttpOnly", "Secure", "SameSite=Strict"] {
            assert!(cookie.contains(part), "{cookie}");
        }
    }

    #[tokio::test]
    async fn mode_both_password_gives_only_a_half_cookie_that_the_key_endpoints_take() {
        let d = TempDir::new("both");
        let a = file_app(&d);
        let file = with_key_file(&a, "both").await;
        let r = route(&a, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
        assert_eq!(r.status, 200);
        assert_eq!(serde_json::from_slice::<Value>(&r.body).unwrap(), json!({"step": 2}));
        let raw = r.headers.iter().find(|(k, _)| *k == "Set-Cookie").unwrap().1.clone();
        for part in ["cache_half=", "HttpOnly", "Secure", "SameSite=Strict", "Max-Age=300", "Path=/auth"] {
            assert!(raw.contains(part), "{raw}");
        }
        assert!(!set_cookies(&r).iter().any(|c| c.starts_with("cache_session=")), "no session yet");
        let half = cookie_of(&r, "cache_half");
        // the half cookie is no session anywhere
        let as_session = half.replacen("cache_half", "cache_session", 1);
        for c in [&half, &as_session] {
            assert_eq!(route(&a, "POST", "/api/core", Some(c), br#"{"op":"version"}"#).await.status, 401, "{c}");
            assert_eq!(route(&a, "GET", "/api/status", Some(c), b"").await.status, 401);
            assert_eq!(route(&a, "GET", "/auth/check", Some(c), b"").await.status, 401);
            assert_eq!(route(&a, "GET", "/", Some(c), b"").await.status, 200);
            assert!(body_str(&route(&a, "GET", "/", Some(c), b"").await).contains("<title>Sign in</title>"));
            assert_eq!(route(&a, "GET", "/main.dart.js", Some(c), b"").await.status, 401);
            assert_eq!(route(&a, "GET", "/api/settings/signin", Some(c), b"").await.status, 401);
            assert_eq!(route(&a, "GET", "/settings/keys", Some(c), b"").await.status, 200);
        }
        assert!(body_str(&route(&a, "GET", "/settings/keys", Some(&half), b"").await).contains("<title>Sign in</title>"));
        // the key endpoints without the half cookie: told to start with the password
        assert_eq!(route(&a, "POST", "/auth/keyfile", None, &file).await.status, 409);
        assert_eq!(route(&a, "POST", "/auth/webauthn/start", None, b"").await.status, 409);
        assert_eq!(route(&a, "POST", "/auth/keyfile", Some("cache_half=forged"), &file).await.status, 409);
        // with it, a key file completes the session, and the half is spent
        let r = route(&a, "POST", "/auth/keyfile", Some(&half), &file).await;
        assert_eq!(r.status, 204);
        let c = cookie_of(&r, "cache_session");
        assert_eq!(route(&a, "GET", "/auth/check", Some(&c), b"").await.status, 204);
        assert_eq!(route(&a, "POST", "/auth/keyfile", Some(&half), &file).await.status, 409, "one use");
        // a wrong key with a good half is a 401 and the half stays good
        let r = route(&a, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
        let half2 = cookie_of(&r, "cache_half");
        assert_eq!(route(&a, "POST", "/auth/keyfile", Some(&half2), b"nonsense").await.status, 401);
        assert_eq!(route(&a, "POST", "/auth/keyfile", Some(&half2), &file).await.status, 204);
    }

    #[tokio::test]
    async fn the_half_cookie_expires() {
        let d = TempDir::new("halfexp");
        let mut a = file_app(&d);
        let file = with_key_file(&a, "both").await;
        Arc::get_mut(&mut a.auth).unwrap().half_secs = 1;
        let r = route(&a, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
        let half = cookie_of(&r, "cache_half");
        assert!(set_cookies(&r).len() == 1 && r.headers.iter().any(|(k, v)| *k == "Set-Cookie" && v.contains("Max-Age=1")));
        tokio::time::sleep(Duration::from_millis(2100)).await;
        assert_eq!(route(&a, "POST", "/auth/keyfile", Some(&half), &file).await.status, 409);
    }

    #[tokio::test]
    async fn mode_key_refuses_the_password_and_password_refuses_keys() {
        let d = TempDir::new("keymode");
        let a = file_app(&d);
        let file = with_key_file(&a, "key").await;
        let r = route(&a, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
        assert_eq!(r.status, 403);
        assert!(set_cookies(&r).is_empty());
        assert_eq!(route(&a, "POST", "/auth/login", None, br#"{"password":"wrong"}"#).await.status, 403);
        assert_eq!(route(&a, "POST", "/auth/keyfile", None, &file).await.status, 204);
        // back to password only (a settings change applies at once, no restart)
        let c = cookie_of(&route(&a, "POST", "/auth/keyfile", None, &file).await, "cache_session");
        assert_eq!(json_call(&a, "PUT", "/api/settings/signin", &c, r#"{"mode":"password"}"#).await.0, 200);
        assert_eq!(route(&a, "POST", "/auth/keyfile", None, &file).await.status, 403);
        assert_eq!(route(&a, "POST", "/auth/webauthn/start", None, b"").await.status, 403);
        assert_eq!(route(&a, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await.status, 204);
    }

    #[tokio::test]
    async fn key_files_right_wrong_unknown_and_oversize() {
        let d = TempDir::new("kfroute");
        let a = file_app(&d);
        let file = with_key_file(&a, "key").await;
        assert_eq!(route(&a, "POST", "/auth/keyfile", None, &file).await.status, 204);
        let text = String::from_utf8(file.clone()).unwrap();
        let lines: Vec<&str> = text.lines().collect();
        let unknown = format!("{}\nffffffffffffffff\n{}\n", lines[0], lines[2]);
        let other_secret = format!("{}\n{}\n{}\n", lines[0], lines[1], "A".repeat(43));
        let mut big = file.clone();
        big.resize(crate::auth::KEYFILE_MAX + 1, b' ');
        let mut exactly = file.clone();
        exactly.resize(crate::auth::KEYFILE_MAX, b' ');
        // right (also when padded up to exactly 4 KB of trailing blanks), then the wrong ones
        assert_eq!(route(&a, "POST", "/auth/keyfile", None, &exactly).await.status, 204);
        assert_eq!(route(&a, "POST", "/auth/keyfile", None, &big).await.status, 413);
        assert_eq!(route(&a, "POST", "/auth/keyfile", None, unknown.as_bytes()).await.status, 401);
        assert_eq!(route(&a, "POST", "/auth/keyfile", None, other_secret.as_bytes()).await.status, 401);
        assert_eq!(route(&a, "POST", "/auth/keyfile", None, b"").await.status, 401);
        // a wrong file never sets a cookie
        let r = route(&a, "POST", "/auth/keyfile", None, b"nope").await;
        assert!(set_cookies(&r).is_empty());
    }

    #[tokio::test]
    async fn wrong_keys_are_throttled_together_with_wrong_passwords() {
        let d = TempDir::new("throttle");
        let a = file_app(&d);
        let file = with_key_file(&a, "either").await;
        let _ = file;
        // first failure: no wait; second (any kind of sign-in): about 2 seconds; a success starts the count again
        let t = Instant::now();
        assert_eq!(route(&a, "POST", "/auth/login", None, br#"{"password":"wrong"}"#).await.status, 401);
        assert!(t.elapsed() < Duration::from_millis(1500), "{:?}", t.elapsed());
        let t = Instant::now();
        assert_eq!(route(&a, "POST", "/auth/keyfile", None, b"cache-key-1\nabc\nAAAA\n").await.status, 401);
        assert!(t.elapsed() >= Duration::from_millis(1900), "the second failure waits: {:?}", t.elapsed());
        assert_eq!(route(&a, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await.status, 204);
        let t = Instant::now();
        assert_eq!(route(&a, "POST", "/auth/keyfile", None, b"x").await.status, 401);
        assert!(t.elapsed() < Duration::from_millis(1500), "the count started again: {:?}", t.elapsed());
    }

    #[tokio::test]
    async fn the_settings_api_needs_a_session_and_keeps_the_lock_out_guards() {
        let d = TempDir::new("guards");
        let a = file_app(&d);
        for (m, p) in [("GET", "/api/settings/signin"), ("PUT", "/api/settings/signin"), ("POST", "/api/settings/key-files"), ("DELETE", "/api/settings/key-files/x"), ("POST", "/api/settings/security-keys/start")] {
            let r = route(&a, m, p, None, b"{}").await;
            assert_eq!(r.status, 401, "{m} {p}");
            assert_eq!(serde_json::from_slice::<Value>(&r.body).unwrap()["error"]["code"], "unauthorized");
        }
        let c = sign_in(&a).await;
        // no key yet: Key only and Password and key are refused, with a plain reason
        for m in ["key", "both"] {
            let (s, v) = json_call(&a, "PUT", "/api/settings/signin", &c, &json!({"mode": m}).to_string()).await;
            assert_eq!((s, v["error"]["code"].clone(), v["error"]["message"].clone()), (409, json!("locked_out"), json!("Register a key first.")));
        }
        assert_eq!(json_call(&a, "PUT", "/api/settings/signin", &c, r#"{"mode":"nonsense"}"#).await.0, 400);
        assert_eq!(json_call(&a, "PUT", "/api/settings/signin", &c, r#"not json"#).await.0, 400);
        let (s, v) = json_call(&a, "GET", "/api/settings/signin", &c, "").await;
        assert_eq!((s, v["result"]["mode"].clone(), v["result"]["usable_keys"].clone()), (200, json!("password"), json!(0)));
        // make a key; Key only is now allowed; the one key cannot be removed
        let r = route(&a, "POST", "/api/settings/key-files", Some(&c), br#"{"name":"one"}"#).await;
        assert_eq!(r.status, 200);
        let (_, v) = json_call(&a, "GET", "/api/settings/signin", &c, "").await;
        let id = v["result"]["key_files"][0]["id"].as_str().unwrap().to_string();
        // the list shows names and dates, never the secret or the hash
        assert!(!v.to_string().contains("hash") && !v.to_string().contains("secret"));
        assert_eq!(json_call(&a, "PUT", "/api/settings/signin", &c, r#"{"mode":"key"}"#).await.0, 200);
        let (s, v) = json_call(&a, "DELETE", &format!("/api/settings/key-files/{id}"), &c, "").await;
        assert_eq!((s, v["error"]["code"].clone()), (409, json!("locked_out")));
        // with a second key, one can go; the last one cannot
        assert_eq!(route(&a, "POST", "/api/settings/key-files", Some(&c), br#"{"name":"two"}"#).await.status, 200);
        assert_eq!(json_call(&a, "DELETE", &format!("/api/settings/key-files/{id}"), &c, "").await.0, 200);
        let (_, v) = json_call(&a, "GET", "/api/settings/signin", &c, "").await;
        let id2 = v["result"]["key_files"][0]["id"].as_str().unwrap().to_string();
        assert_eq!(v["result"]["key_files"].as_array().unwrap().len(), 1);
        assert_eq!(json_call(&a, "DELETE", &format!("/api/settings/key-files/{id2}"), &c, "").await.0, 409);
        // the session that did this is a password session from before: still good in Key only mode
        assert_eq!(route(&a, "GET", "/auth/check", Some(&c), b"").await.status, 204);
        // Password or key does not need a key, so the last one goes
        assert_eq!(json_call(&a, "PUT", "/api/settings/signin", &c, r#"{"mode":"either","start_with_password":true}"#).await.0, 200);
        assert_eq!(json_call(&a, "DELETE", &format!("/api/settings/key-files/{id2}"), &c, "").await.0, 200);
        assert_eq!(json_call(&a, "DELETE", &format!("/api/settings/key-files/{id2}"), &c, "").await.0, 404);
        // names
        assert_eq!(route(&a, "POST", "/api/settings/key-files", Some(&c), br#"{"name":"  "}"#).await.status, 400);
        assert_eq!(route(&a, "POST", "/api/settings/key-files", Some(&c), br#"{}"#).await.status, 400);
        // security keys need a hostname
        let (s, v) = json_call(&a, "POST", "/api/settings/security-keys/start", &c, r#"{"name":"yk"}"#).await;
        assert_eq!((s, v["error"]["message"].clone()), (409, json!("Needs a hostname with a trusted certificate")));
        // "start with the password box" only means something in Password or key
        assert_eq!(json_call(&a, "PUT", "/api/settings/signin", &c, r#"{"mode":"password","start_with_password":true}"#).await.0, 200);
        let (_, v) = json_call(&a, "GET", "/api/settings/signin", &c, "").await;
        assert_eq!(v["result"]["start_with_password"], false);
    }

    #[tokio::test]
    async fn security_key_endpoints_are_off_without_webauthn() {
        let d = TempDir::new("nowa");
        let a = file_app(&d);
        let _ = with_key_file(&a, "either").await;
        assert_eq!(route(&a, "POST", "/auth/webauthn/start", None, b"").await.status, 404);
        assert_eq!(route(&a, "POST", "/auth/webauthn/finish", None, br#"{"id":"x","credential":{}}"#).await.status, 400);
        assert_eq!(route(&a, "POST", "/auth/webauthn/finish", None, b"junk").await.status, 400);
        assert_eq!(serde_json::from_slice::<Value>(&route(&a, "GET", "/auth/state", None, b"").await.body).unwrap()["security_key_available"], false);
    }
}
