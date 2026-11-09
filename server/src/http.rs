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
//!                                              "open", "close" and "setSources" are answered here, not forwarded: the server owns the
//!                                              one engine and its source list; "sources.rescan" is refused (only the server calls it)
//!   GET  /api/status                        -> the same, for the "status" op
//!   /api/settings/...                       -> the sign-in setting and the keys (signed in): GET|PUT signin, POST security-keys/start|finish,
//!                                              DELETE security-keys/<id>, POST key-files (the file), DELETE key-files/<id>
//!   POST /api/library/download {url,kind:"zim"|"library",name?,sha256?,origin?,icon_url?} -> the job (queued; see `library`)
//!   GET  /api/library/jobs                  -> [{id,url,kind,name,bytes,total,state,error}]
//!   DELETE /api/library/jobs/<id>           -> cancels a waiting or running job, or takes a finished one off the list
//!   POST /api/library/upload?kind=zim&name=<file name>  <the file, streamed, any size> -> {name,bytes,id}; 507 when the disk is short
//!   GET  /api/library/space                 -> {free_bytes,total_bytes} of the disk the data is on (null when not known)
//!   POST /api/library/rescan                -> {sources}: the core reads the library folders again
//!   GET  /api/library/items                 -> [{id,kind,name,title,bytes,path}] what is installed on the server
//!   DELETE /api/library/items/<id>          -> removes it (files, sidecars, index), then rescans; 409 while it is being downloaded
//!   GET  /api/fetch?url=<encoded>[&scope=catalog|models|video|user][&plain=1]
//!                                            -> the answer of an address the scope allows (rules in `fetch_scope`), streamed. `catalog`
//!                                               (default): the catalog hosts, at most 50 MB. The other scopes read other servers: a
//!                                               public address only (never private, loopback or link-local, checked after DNS and on
//!                                               every redirect), text, JSON, XML or a picture, at most 8 MB; `models` Hugging Face's API,
//!                                               `video` a PeerTube site's /api/v1/ and caption and thumbnail files, `user` an address the
//!                                               person typed. `plain=1` also takes http on port 80 (video, user). Errors: 400 invalid,
//!                                               403 host_not_allowed | scope_off, 413 too_large, 415 unsupported_type, 429 busy, 502
//!                                               upstream_status | unreachable. (all of these answer {"ok":true,"result":...} except /api/fetch, which is the body)
//!   /api/build/...                          -> building libraries from PDFs and the drop folder; the whole list is in server/BUILD-API.md
//!                                              (libraries, books, upload, queue, drop folder)
//!   GET  /api/models/embedder               -> {state:"missing"|"downloading"|"ready"|"error", bytes?,total?,error?, file,size,library_found}
//!   POST /api/models/embedder/download      -> the same; starts (or continues) the model download, 202-style: answers at once
//!   POST /api/embed {texts:[...]}           -> {vectors:[[f32;1024]],model,dims}: 1 to 64 texts, in order; 503 model_missing while the
//!                                              model is not there (the download is started), 503 embed_unavailable if it cannot load
//!   GET  /api/llm/models                    -> {v,models:[{id,size,loaded,info?,n_ctx?}]}: the chat models (.gguf files) in <data>/models/, not the embedder
//!   POST /api/llm/load {v:1,model,n_ctx?}   -> the loaded model's ModelInfo {description,n_ctx,chat_format,supports_tools}; by id only, never a path
//!   POST /api/llm/generate {v:1,model?,request} -> application/x-ndjson, one event per line: queued {position}, started {id}, partial {...}, done {...}, error {code,message}
//!   POST /api/llm/stop {v:1,id?}            -> {stopped}: ends the running generation early (its `done` still arrives); with the id from `started`, only that one
//!                                              (the browser build of Ask runs its loop itself and uses the server only for the model;
//!                                              the protocol mirrors packages/cache_llama/lib/llama_session_io.dart: see server/docs/llm-protocol.md)
//!   POST /api/zim/token                     -> {"token","ttl"}: a token for /zim/ (12 h, tied to this session, gone when it signs out)
//!   GET  /zim/<token>/<zim id>/<entry path>[?query] -> the entry's bytes with its own mime type, redirects followed by the core.
//!                                              Third-party content: sent with `Content-Security-Policy: sandbox allow-scripts
//!                                              allow-popups` (no allow-same-origin), so a page in it has no origin and cannot use the
//!                                              session. The URL's token is the only credential here (the cookie is not read), and the
//!                                              token opens nothing under /api/. 401 for a missing, wrong or expired token.
//!   GET  /api/tiles/layers/<id>/<z>/<x>/<y>[.ext] and /api/tiles/layers/<id>/tilejson.json
//!                                           -> the core's local tile server's answer, unchanged (200 tile, 204 none, 503 + Retry-After for a
//!                                              tile that may come later); the session cookie is the credential. See `tiles`.
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
use crate::embed::{self, EmbedService};
use crate::libbuild::BuildService;
use crate::llm::{self, LlmService};
use crate::library::{ApiErr, Library};
use http_body_util::combinators::UnsyncBoxBody;
use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Body, Bytes, Frame, Incoming};
use hyper::service::service_fn;
use hyper::{Request, Response};
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::{json, Value};
use std::convert::Infallible;
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
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
    /// Library downloads, uploads, installed items and the catalog fetch.
    pub library: Arc<Library>,
    /// The bge-m3 embedder: the model download and the vectors (see `embed`).
    pub embed: Arc<EmbedService>,
    /// The chat model for the browser build of Ask (see `llm`).
    pub llm: Arc<LlmService>,
    /// Building libraries from PDFs, and the drop folder (see `build`).
    pub build: Arc<BuildService>,
}

pub struct Reply {
    pub status: u16,
    pub headers: Vec<(&'static str, String)>,
    pub body: Vec<u8>,
    /// A body that arrives in pieces (the catalog fetch); when set, `body` is empty and the pieces are sent as they come.
    pub stream: Option<tokio::sync::mpsc::Receiver<std::io::Result<Bytes>>>,
}

/// A response body fed from a channel.
struct ChannelBody(tokio::sync::mpsc::Receiver<std::io::Result<Bytes>>);

impl Body for ChannelBody {
    type Data = Bytes;
    type Error = std::io::Error;

    fn poll_frame(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Result<Frame<Bytes>, std::io::Error>>> {
        self.0.poll_recv(cx).map(|item| item.map(|r| r.map(Frame::data)))
    }
}

impl Reply {
    pub(crate) fn empty(status: u16) -> Reply {
        Reply { status, headers: vec![], body: vec![], stream: None }
    }

    fn json(status: u16, body: String) -> Reply {
        Reply { status, headers: vec![("Content-Type", "application/json".into())], body: body.into_bytes(), stream: None }
    }

    pub(crate) fn error(status: u16, code: &str, message: impl AsRef<str>) -> Reply {
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

/// An `ApiErr` from the library as the server's error reply.
fn api_error(e: ApiErr) -> Reply {
    Reply::error(e.status, e.code, e.message)
}

fn library_reply(r: Result<Value, ApiErr>) -> Reply {
    match r {
        Ok(v) => ok(v),
        Err(e) => api_error(e),
    }
}

/// `/api/library/...` and `/api/fetch` (the caller has checked the session). `None` when the path is not one of these.
async fn library(app: &App, method: &str, path: &str, query: &str, body: &[u8]) -> Option<Reply> {
    let lib = &app.library;
    Some(match (method, path) {
        ("POST", "/api/library/download") => library_reply(lib.add_download(body)),
        ("GET", "/api/library/jobs") => ok(lib.list_jobs()),
        ("DELETE", p) if p.starts_with("/api/library/jobs/") => library_reply(lib.cancel_job(&p["/api/library/jobs/".len()..])),
        ("GET", "/api/library/space") => ok(lib.space()),
        ("POST", "/api/library/rescan") => library_reply(lib.rescan_api().await),
        ("GET", "/api/library/items") => ok(Value::Array(lib.items().await)),
        ("DELETE", p) if p.starts_with("/api/library/items/") => library_reply(lib.remove_item(&p["/api/library/items/".len()..]).await),
        // A body that came whole (the real server streams it: see `handle`).
        ("POST", "/api/library/upload") => {
            let b = Full::new(Bytes::copy_from_slice(body));
            library_reply(lib.upload(query, Some(body.len() as u64), b).await)
        }
        ("GET", "/api/fetch") => match lib.fetch(query).await {
            Ok(s) => Reply {
                status: 200,
                headers: vec![
                    ("Content-Type", s.content_type.unwrap_or_else(|| "application/octet-stream".into())),
                    // whatever the catalog sends is data for the app to read, never a page of this origin
                    ("Content-Security-Policy", "default-src 'none'; sandbox".into()),
                    ("X-Content-Type-Options", "nosniff".into()),
                ],
                body: vec![],
                stream: Some(s.rx),
            },
            Err(e) => api_error(e),
        },
        _ => return None,
    })
}

/// Where a streamed build upload goes: `/api/build/upload` (the library is the `library_id` query parameter) or
/// `/api/build/libraries/{id}/books/{doc}/replace`. `None` for any other path.
fn build_upload_target(path: &str) -> Option<(String, Option<String>)> {
    if path == "/api/build/upload" {
        return Some((String::new(), None));
    }
    let rest = path.strip_prefix("/api/build/libraries/")?;
    let seg: Vec<&str> = rest.split('/').collect();
    match seg.as_slice() {
        [id, "books", doc, "replace"] => Some((id.to_string(), Some(doc.to_string()))),
        _ => None,
    }
}

/// Run blocking work (files, the core) off the async threads.
async fn blocking<F>(f: F) -> Reply
where
    F: FnOnce() -> Result<Value, ApiErr> + Send + 'static,
{
    match tokio::task::spawn_blocking(f).await {
        Ok(r) => library_reply(r),
        Err(_) => Reply::error(500, "server_error", "an internal error stopped the request"),
    }
}

/// `/api/build/...` (the caller has checked the session). `None` when the path is not one of these.
async fn build_api(app: &App, method: &str, path: &str, query: &str, body: &[u8]) -> Option<Reply> {
    let rest = path.strip_prefix("/api/build/")?;
    let b = app.build.clone();
    let seg: Vec<&str> = rest.split('/').collect();
    let body_owned = body.to_vec();
    Some(match (method, seg.as_slice()) {
        ("GET", ["libraries"]) => ok(b.libraries()),
        ("POST", ["libraries"]) => blocking(move || b.create_library(&body_owned)).await,
        ("PATCH", ["libraries", id]) => {
            let id = id.to_string();
            blocking(move || b.rename_library(&id, &body_owned)).await
        }
        ("DELETE", ["libraries", id]) => {
            let id = id.to_string();
            blocking(move || b.delete_library(&id)).await
        }
        ("GET", ["libraries", id, "books"]) => library_reply(b.books_q(id, query)),
        ("GET", ["libraries", id, "books", doc, "suggestions"]) => {
            let (id, doc) = (id.to_string(), doc.to_string());
            library_reply(b.suggestions(&id, &doc))
        }
        ("POST", ["libraries", id, "books", doc, "place"]) => {
            let (id, doc) = (id.to_string(), doc.to_string());
            blocking(move || b.place_book(&id, &doc, &body_owned)).await
        }
        // the Library in a browser: the person's shelves as this server holds them (server/BUILD-API.md "Bookshelves in the browser")
        ("GET", ["bookshelves"]) => blocking(move || b.bookshelves_view()).await,
        ("GET", ["bookshelves", "stamp"]) => blocking(move || Ok(b.bookshelves_stamp())).await,
        ("GET", ["bookshelves", "facts"]) => blocking(move || b.bookshelves_facts()).await,
        ("POST", ["bookshelves", "events"]) => blocking(move || b.bookshelves_events(&body_owned)).await,
        ("GET", ["classes"]) => {
            let lib = crate::fetch::query_param(query, "library_id");
            blocking(move || b.classes_view(lib.as_deref())).await
        }
        ("POST", ["classes", "reclassify"]) => blocking(move || b.reclassify(&body_owned)).await,
        ("POST", ["queue", id, "decide"]) => {
            let id = id.to_string();
            blocking(move || b.decide(&id, &body_owned)).await
        }
        ("GET", ["removed"]) => ok(b.removed_view()),
        ("POST", ["removed", id, "restore"]) => {
            let id = id.to_string();
            blocking(move || b.restore_removed(&id)).await
        }
        ("DELETE", ["removed", id]) => {
            let id = id.to_string();
            blocking(move || b.delete_removed(&id)).await
        }
        ("DELETE", ["removed"]) => blocking(move || b.delete_removed("")).await,
        ("PATCH", ["libraries", id, "books", doc]) => {
            let (id, doc) = (id.to_string(), doc.to_string());
            blocking(move || b.rename_book(&id, &doc, &body_owned)).await
        }
        ("DELETE", ["libraries", id, "books", doc]) => {
            let (id, doc) = (id.to_string(), doc.to_string());
            blocking(move || b.delete_book(&id, &doc)).await
        }
        // Uploads: the real server streams them (see `handle`); a body that came whole is handled the same way.
        ("POST", _) if build_upload_target(path).is_some() => {
            let (lib, replace) = build_upload_target(path)?;
            let full = Full::new(Bytes::copy_from_slice(body));
            library_reply(b.upload(&lib, replace.as_deref(), query, Some(body.len() as u64), full).await)
        }
        ("GET", ["queue"]) => ok(b.queue()),
        ("POST", ["queue", "pause"]) => ok(b.pause()),
        ("POST", ["queue", "resume"]) => ok(b.resume()),
        ("POST", ["queue", "stop"]) => {
            let b2 = b.clone();
            match tokio::task::spawn_blocking(move || b2.stop()).await {
                Ok(v) => ok(v),
                Err(_) => Reply::error(500, "server_error", "an internal error stopped the request"),
            }
        }
        ("POST", ["queue", id, "retry"]) => {
            let id = id.to_string();
            blocking(move || b.retry(&id)).await
        }
        ("DELETE", ["queue", id]) => {
            let id = id.to_string();
            blocking(move || b.dismiss(&id)).await
        }
        ("GET", ["drop"]) => blocking(move || Ok(b.drop_view())).await,
        ("GET", ["settings"]) => blocking(move || Ok(b.settings_view())).await,
        ("PUT", ["settings"]) => blocking(move || b.settings_put(&body_owned)).await,
        ("PUT", ["drop"]) => blocking(move || b.drop_put(&body_owned)).await,
        ("POST", ["drop", "check"]) => blocking(move || Ok(b.drop_check())).await,
        ("POST", ["drop", "retry"]) => blocking(move || b.drop_retry(&body_owned)).await,
        _ => return None,
    })
}

/// `/api/models/embedder...` and `/api/embed` (the caller has checked the session). `None` when the path is not one of these.
async fn embedder(app: &App, method: &str, path: &str, body: &[u8]) -> Option<Reply> {
    let svc = &app.embed;
    Some(match (method, path) {
        ("GET", "/api/models/embedder") => ok(svc.status()),
        ("POST", "/api/models/embedder/download") => ok(svc.start_download()),
        ("POST", "/api/embed") => {
            let texts = match embed::parse_texts(body) {
                Ok(t) => t,
                Err(e) => return Some(api_error(e)),
            };
            let s = svc.clone();
            // llama.cpp is blocking and busy for a while: keep it off the async threads.
            let r = tokio::task::spawn_blocking(move || s.embed_batch(&texts)).await;
            match r {
                Ok(Ok(v)) => Reply::json(200, embed::vectors_json(&v, svc.model_id())),
                Ok(Err(e)) => api_error(e),
                Err(_) => Reply::error(500, "embed_failed", "the embedder stopped unexpectedly"),
            }
        }
        _ => return None,
    })
}

/// `/api/llm/...` (the caller has checked the session). `None` when the path is not one of these.
async fn llm_api(app: &App, method: &str, path: &str, query: &str, body: &[u8]) -> Option<Reply> {
    let rest = path.strip_prefix("/api/llm/")?;
    let svc = app.llm.clone();
    Some(match (method, rest) {
        ("GET", "models") => {
            // a `v` in the query, when given, must be 1 (there is no body to carry it)
            if let Some(v) = crate::fetch::query_param(query, "v") {
                if let Err(e) = llm::check_version(&json!({"v": v.parse::<i64>().ok()})) {
                    return Some(api_error(e));
                }
            }
            blocking(move || Ok(svc.models_json())).await
        }
        ("POST", "load") => {
            let (id, n_ctx) = match llm::parse_load(body) {
                Ok(x) => x,
                Err(e) => return Some(api_error(e)),
            };
            blocking(move || svc.load(&id, n_ctx)).await
        }
        ("POST", "generate") => {
            let (model, request) = match llm::parse_generate(body) {
                Ok(r) => r,
                Err(e) => return Some(api_error(e)),
            };
            if !svc.is_loaded() {
                return Some(Reply::error(409, "no_model", "No model is loaded"));
            }
            // The events go out as they are made. If the client goes away the receiver is dropped, the write fails and the worker
            // stops the generation.
            let (tx, rx) = tokio::sync::mpsc::channel(64);
            tokio::task::spawn_blocking(move || svc.run_generation(model, request, tx));
            Reply {
                status: 200,
                headers: vec![("Content-Type", "application/x-ndjson".into()), ("X-Accel-Buffering", "no".into())],
                body: vec![],
                stream: Some(rx),
            }
        }
        ("POST", "stop") => {
            let id = match llm::parse_stop(body) {
                Ok(i) => i,
                Err(e) => return Some(api_error(e)),
            };
            ok(json!({"stopped": svc.stop(id.as_deref())}))
        }
        _ => return None,
    })
}

/// Linked roots are server-local; this route is reached only after the session gate.
async fn linked_folders(app: &App, method: &str, path: &str, body: &[u8]) -> Option<Reply> {
    let rest = path.strip_prefix("/api/linked-folders/")?;
    if method == "POST" && rest == "preview" {
        let service = app.build.clone();
        let bytes = body.to_vec();
        return Some(blocking(move || crate::libbuild::linked_api::preview(&service, &bytes)).await);
    }
    if method == "GET" && rest == "libraries" {
        let targets: Vec<Value> = app.library.items().await.into_iter()
            .filter(|item| item["kind"].as_str() == Some("library"))
            .map(|item| json!({"id": item["name"], "title": item["title"], "name": item["name"]}))
            .collect();
        return Some(ok(json!(targets)));
    }
    let mut parts = rest.split('/');
    let library = parts.next()?.to_string();
    let segments: Vec<String> = parts.map(str::to_string).collect();
    let (service, method, bytes) = (app.build.clone(), method.to_string(), body.to_vec());
    Some(blocking(move || crate::libbuild::linked_api::request(&service, &method, &library, &segments, &bytes)).await)
}

async fn api(app: &App, method: &str, path: &str, query: &str, body: &[u8]) -> Reply {
    if let Some(r) = linked_folders(app, method, path, body).await {
        return r;
    }
    if let Some(r) = settings(app, method, path, body) {
        return r;
    }
    if let Some(r) = embedder(app, method, path, body).await {
        return r;
    }
    if let Some(r) = llm_api(app, method, path, query, body).await {
        return r;
    }
    if let Some(r) = build_api(app, method, path, query, body).await {
        return r;
    }
    if let Some(r) = library(app, method, path, query, body).await {
        return r;
    }
    if let Some(rest) = path.strip_prefix("/api/tiles/") {
        return crate::tiles::tiles(app.helper.clone(), method, rest).await;
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
            // The server owns the one shared engine and its source list, so a tab can neither replace, close nor re-source it.
            if op == "open" || op == "close" || op == "setSources" {
                return Reply::json(200, json!({"ok": true, "result": null}).to_string());
            }
            // The rescan is the server's own call, after it changes the library folders; a tab may not make the engine re-read them.
            if op == "sources.rescan" {
                return Reply::error(403, "forbidden", "only the server may do that");
            }
            core_call(app, op, args).await
        }
        _ => Reply::error(404, "not_found", format!("no such endpoint: {method} {path}")),
    }
}


/// The script added to every HTML page under /zim/. The page runs in a sandboxed frame (no origin), so the app cannot reach into
/// it: the script tells the app where the frame is and what the page is called, takes "back" and "forward" from it, and sends
/// a click on a link that leaves the ZIM to the app, which opens it in a new tab. Links inside the ZIM are left to the browser.
const ZIM_FRAME_SCRIPT: &str = r#"<script>(function(){
var post=function(m){try{parent.postMessage(m,'*')}catch(e){}};
var report=function(){post({cacheZim:'page',href:location.pathname+location.search+location.hash,title:document.title||''})};
addEventListener('load',report);addEventListener('hashchange',report);addEventListener('popstate',report);
addEventListener('message',function(e){if(e.source!==parent||!e.data)return;if(e.data.cacheZim==='back')history.back();else if(e.data.cacheZim==='forward')history.forward()});
document.addEventListener('click',function(e){
var a=e.target&&e.target.closest?e.target.closest('a[href]'):null;if(!a||e.defaultPrevented)return;
var u;try{u=new URL(a.href,location.href)}catch(x){return}
if(u.origin===location.origin&&(u.protocol==='https:'||u.protocol==='http:'))return;
e.preventDefault();if(u.protocol==='https:'||u.protocol==='http:'||u.protocol==='mailto:')post({cacheZim:'external',url:u.href})},true);
})();</script>"#;

/// `html` with [ZIM_FRAME_SCRIPT] before its last `</body>` (at the end when it has none).
fn with_frame_script(html: &[u8]) -> Vec<u8> {
    let text = String::from_utf8_lossy(html);
    let at = text.to_ascii_lowercase().rfind("</body").unwrap_or(text.len());
    let mut out = String::with_capacity(text.len() + ZIM_FRAME_SCRIPT.len());
    out.push_str(&text[..at]);
    out.push_str(ZIM_FRAME_SCRIPT);
    out.push_str(&text[at..]);
    out.into_bytes()
}

/// The type to serve an entry as. The ZIM's own type is kept when it is specific; when it is missing, empty or the generic
/// `application/octet-stream` (some ZIMs store scripts and style sheets so), the type comes from the path's extension. With
/// `nosniff` on, a script or style sheet served as octet-stream is refused by the browser, so this must not be left generic.
fn effective_mime(mime: &str, entry: &str) -> String {
    let essence = mime.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    if !essence.is_empty() && essence != "application/octet-stream" {
        return mime.to_string();
    }
    let path = entry.split(['?', '#']).next().unwrap_or("");
    let name = path.rsplit('/').next().unwrap_or("");
    let ext = match name.rsplit_once('.') {
        Some((_, e)) => e.to_ascii_lowercase(),
        None => return mime.to_string(),
    };
    let inferred = match ext.as_str() {
        "js" | "mjs" => "text/javascript",
        "css" => "text/css",
        "html" | "htm" => "text/html",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "ico" => "image/x-icon",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        "json" => "application/json",
        "wasm" => "application/wasm",
        "txt" => "text/plain",
        _ => return mime.to_string(),
    };
    inferred.to_string()
}

/// `GET /zim/<token>/<zim id>/<entry path>`: one entry of a ZIM, for the reader's frame. The token in the path is the only
/// credential (see the module doc): the session cookie is neither needed nor looked at.
async fn zim(app: &App, method: &str, path: &str, query: &str) -> Reply {
    if method != "GET" && method != "HEAD" {
        return Reply::empty(405);
    }
    let rest = &path["/zim/".len()..];
    let Some((token, rest)) = rest.split_once('/') else { return Reply::empty(404) };
    if !app.auth.zim_token_valid(token) {
        return Reply::empty(401);
    }
    let Some((id, entry)) = rest.split_once('/') else { return Reply::empty(404) };
    let id_ok = id.len() == 36 && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-');
    if !id_ok || entry.is_empty() {
        return Reply::empty(404);
    }
    let address = if query.is_empty() { format!("zim:{}/{entry}", id.to_ascii_lowercase()) } else { format!("zim:{}/{entry}?{query}", id.to_ascii_lowercase()) };
    let Some(helper) = app.helper.clone() else { return Reply::empty(503) };
    let reply = match helper.call("zimGet", json!({"address": address})).await {
        Ok(r) => r,
        Err(_) => return Reply::empty(503),
    };
    if reply["ok"] != json!(true) {
        return Reply::empty(if reply["error"]["code"] == json!("not_found") { 404 } else { 502 });
    }
    use base64::Engine;
    let result = &reply["result"];
    let bytes = result[0]["$bytes"].as_str().and_then(|b| base64::engine::general_purpose::STANDARD.decode(b).ok());
    let (Some(bytes), Some(mime)) = (bytes, result[1].as_str()) else { return Reply::empty(502) };
    let mime = &effective_mime(mime, entry);
    let essence = mime.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    let is_html = essence == "text/html";
    let content_type = if mime.to_ascii_lowercase().contains("charset") || !essence.starts_with("text/") { mime.to_string() } else { format!("{essence}; charset=utf-8") };
    let body = if is_html { with_frame_script(&bytes) } else { bytes };
    Reply {
        status: 200,
        headers: vec![
            ("Content-Type", content_type),
            // Third-party content: a page here has no origin of its own, so it cannot use this site's session or call /api/.
            ("Content-Security-Policy", "sandbox allow-scripts allow-popups".into()),
            ("Referrer-Policy", "no-referrer".into()),
            // The frame has no origin, so its page reads its own style sheets and fonts as another site's: allowed, without cookies.
            ("Access-Control-Allow-Origin", "*".into()),
            ("Cache-Control", "private, max-age=600".into()),
        ],
        body: if method == "HEAD" { vec![] } else { body },
        stream: None,
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
                    stream: None,
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
        stream: None,
    }
}

/// One request to one reply.
pub async fn route(app: &App, method: &str, target: &str, cookie: Option<&str>, body: &[u8]) -> Reply {
    // `target` is the path and, after a `?`, the query.
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
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
        // ZIM pages: the token in the path is the credential; the session cookie plays no part.
        _ if path.starts_with("/zim/") => zim(app, method, path, query).await,
        _ if path == "/api" || path.starts_with("/api/") => {
            if !signed_in {
                return Reply::error(401, "unauthorized", "sign in first");
            }
            if let (Some(t), "POST", "/api/zim/token") = (token, method, path) {
                return match app.auth.create_zim_token(t) {
                    Ok(z) => ok(json!({"token": z, "ttl": app.auth.zim_secs})),
                    Err(_) => Reply::error(500, "internal", "no token could be made"),
                };
            }
            api(app, method, path, query, body).await
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
                    Reply { status: 200, headers: vec![("Content-Type", ct.into())], body: if head { vec![] } else { bytes }, stream: None }
                }
                Ok(Err(code)) => Reply::empty(code),
                Err(_) => Reply::empty(500),
            }
        }
        _ => Reply::empty(405),
    }
}

/// The response body: whole, or arriving in pieces.
type ResponseBody = UnsyncBoxBody<Bytes, std::io::Error>;

async fn handle(app: Arc<App>, req: Request<Incoming>) -> Response<ResponseBody> {
    let started = Instant::now();
    let method = req.method().as_str().to_string();
    let path = req.uri().path().to_string();
    let target = req.uri().path_and_query().map_or(path.clone(), |p| p.as_str().to_string());
    let cookie = req.headers().get(hyper::header::COOKIE).and_then(|v| v.to_str().ok()).map(str::to_string);
    // The big limit is for signed-in /api/core calls only; everyone else gets the small one before anything is read.
    let signed_in = cookie.as_deref().and_then(token_from_cookie).is_some_and(|t| app.auth.is_signed_in(t));
    let limit = if path == "/api/core" && signed_in {
        MAX_CORE_BODY
    } else if path == "/api/llm/generate" && signed_in {
        llm::MAX_GENERATE_BODY
    } else if path == "/auth/keyfile" {
        KEYFILE_MAX
    } else {
        MAX_BODY
    };
    let reply = if signed_in && method == "POST" && path == "/api/library/upload" {
        // An upload is streamed to disk as it arrives, whatever its size: it is never collected here.
        let len = req.headers().get(hyper::header::CONTENT_LENGTH).and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok());
        let query = req.uri().query().unwrap_or("").to_string();
        library_reply(app.library.upload(&query, len, req.into_body()).await)
    } else if let (true, "POST", Some((lib, replace))) = (signed_in, method.as_str(), build_upload_target(&path)) {
        // A PDF upload is streamed to disk the same way.
        let len = req.headers().get(hyper::header::CONTENT_LENGTH).and_then(|v| v.to_str().ok()).and_then(|v| v.parse::<u64>().ok());
        let query = req.uri().query().unwrap_or("").to_string();
        library_reply(app.build.upload(&lib, replace.as_deref(), &query, len, req.into_body()).await)
    } else {
        match Limited::new(req.into_body(), limit).collect().await {
            Ok(b) => route(&app, &method, &target, cookie.as_deref(), &b.to_bytes()).await,
            Err(_) => Reply::empty(413),
        }
    };
    eprintln!("{method} {path} {} {}ms", reply.status, started.elapsed().as_millis());
    let body: ResponseBody = match reply.stream {
        Some(rx) => ChannelBody(rx).boxed_unsync(),
        None => Full::new(Bytes::from(reply.body)).map_err(|never| match never {}).boxed_unsync(),
    };
    let mut resp = Response::new(body);
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

    fn test_embed(dir: &TempDir) -> Arc<EmbedService> {
        // the address is one nothing listens on, so a test that starts the model download never reaches the network
        EmbedService::with_spec(dir.0.clone(), dir.0.join("none.so"), crate::embed::ModelSpec { url: "http://127.0.0.1:1/none".into(), ..crate::embed::ModelSpec::bge_m3() })
    }

    /// An app with the fake embedder in the build service (nothing is downloaded and the build thread is not started).
    fn test_app(dir: &TempDir, auth: Arc<Auth>, web: PathBuf) -> App {
        let library = Library::new(dir.0.clone(), None);
        let build = BuildService::new(dir.0.clone(), library.clone(), crate::libbuild::tests::FakeEmbed::new(true), crate::libbuild::BuildConfig::default());
        let embed = test_embed(dir);
        let llm = LlmService::new(dir.0.clone(), dir.0.join("none.so"), embed.model_id().to_string());
        App { auth, helper: None, web, library, embed, llm, build }
    }

    fn app(dir: &TempDir) -> App {
        let auth = Auth::new(None, Sessions::load(&dir.0.join("sessions.json")), true);
        test_app(dir, Arc::new(auth), dir.0.join("web"))
    }

    #[tokio::test]
    async fn api_needs_a_session() {
        let d = TempDir::new("http");
        let a = app(&d);
        for (m, p) in [("GET", "/api/status"), ("POST", "/api/core"), ("GET", "/api/other"), ("GET", "/api/linked-folders/libraries"), ("POST", "/api/linked-folders/example")] {
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
        let f = crate::auth::AuthFile { password: Some(StoredPassword::with_iterations("pw", 1000).unwrap()), ..Default::default() };
        f.save(&dir.0.join("auth.json")).unwrap();
        std::fs::create_dir_all(dir.0.join("web")).unwrap();
        std::fs::write(dir.0.join("web/index.html"), b"the app").unwrap();
        std::fs::write(dir.0.join("web/main.dart.js"), b"js").unwrap();
        std::fs::write(dir.0.join("secret.txt"), b"no").unwrap();
        test_app(dir, Arc::new(Auth::load(&dir.0, true).unwrap()), dir.0.join("web"))
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
    async fn the_bookshelves_routes_serve_the_view_and_take_the_events_of_a_book_page() {
        use crate::libbuild::testpdf::book;
        let d = TempDir::new("route-shelves");
        let a = file_app(&d);
        let c = sign_in(&a).await;
        let (_, v) = json_call(&a, "POST", "/api/build/libraries", &c, r#"{"title":"Wells"}"#).await;
        let lib = v["result"]["id"].as_str().unwrap().to_string();
        let up = format!("/api/build/upload?library_id={lib}&name=well.pdf");
        assert_eq!(route(&a, "POST", &up, Some(&c), &book("well", 3, Some("Well book"))).await.status, 200);
        assert!(matches!(a.build.run_one(), crate::libbuild::Run::Ran));
        // the view: this server's device id, the stamp and one book keyed by its copy
        let (s, v) = json_call(&a, "GET", "/api/build/bookshelves", &c, "").await;
        assert_eq!(s, 200);
        assert_eq!(v["result"]["device"], json!(a.build.device));
        let stamp = v["result"]["stamp"].as_str().unwrap().to_string();
        assert!(!stamp.is_empty());
        assert_eq!(json_call(&a, "GET", "/api/build/bookshelves/stamp", &c, "").await.1["result"]["stamp"], json!(stamp));
        let copy = v["result"]["view"]["books"].as_object().unwrap().keys().next().unwrap().to_string();
        let (_, b) = json_call(&a, "GET", &format!("/api/build/libraries/{lib}/books"), &c, "").await;
        let doc = b["result"][0]["id"].as_str().unwrap().to_string();
        // the facts: the pack's header, without the bulky samebook block
        let (s, f) = json_call(&a, "GET", "/api/build/bookshelves/facts", &c, "").await;
        assert_eq!(s, 200);
        let docs = f["result"]["libraries"].as_object().unwrap().values().find(|d| d.get(&doc).is_some()).expect("the book's pack header");
        assert_eq!(docs[&doc]["doc_id"], json!(doc));
        assert!(docs[&doc].get("samebook").is_none());
        // a placement is the server's own: the number is its next free one, whatever number the page sent
        let place = json!({"events": [
            {"ev": "place", "copy": copy, "div": "530", "by": "user", "at": 1},
            {"ev": "assign", "copy": copy, "div": "530", "seq": 7, "at": 1},
        ]})
        .to_string();
        let (s, v) = json_call(&a, "POST", "/api/build/bookshelves/events", &c, &place).await;
        assert_eq!((s, v["result"]["moved"].clone()), (200, json!(1)), "{v}");
        let (_, b) = json_call(&a, "GET", &format!("/api/build/libraries/{lib}/books"), &c, "").await;
        assert_eq!((b["result"][0]["division"].clone(), b["result"][0]["call_number"].clone()), (json!("530"), json!("CDS 530-001")));
        let (_, v) = json_call(&a, "GET", "/api/build/bookshelves", &c, "").await;
        assert_eq!(v["result"]["view"]["books"][&copy]["call"]["text"], json!("CDS 530-001"));
        assert_ne!(v["result"]["stamp"], json!(stamp), "the stamp follows the log");
        // hiding is written as it came
        let (s, v) = json_call(&a, "POST", "/api/build/bookshelves/events", &c, &json!({"events": [{"ev": "remove", "copy": copy}]}).to_string()).await;
        assert_eq!((s, v["result"]["written"].clone()), (200, json!(1)), "{v}");
        let (_, v) = json_call(&a, "GET", "/api/build/bookshelves", &c, "").await;
        assert_eq!(v["result"]["view"]["books"][&copy]["removed"], json!(true));
        // refused: not JSON, no events, an event the Library does not write, a division that does not exist
        for body in [
            "nope".to_string(),
            "{}".to_string(),
            r#"{"events":[]}"#.to_string(),
            json!({"events": [{"ev": "facts", "copy": copy, "author": "A"}]}).to_string(),
            json!({"events": [{"ev": "place", "copy": copy, "div": "999", "by": "user"}]}).to_string(),
        ] {
            assert_eq!(json_call(&a, "POST", "/api/build/bookshelves/events", &c, &body).await.0, 400, "{body}");
        }
    }

    #[tokio::test]
    async fn the_embedder_routes_need_a_session_and_check_their_input() {
        let d = TempDir::new("route-embed");
        let a = file_app(&d);
        for (m, p) in [("GET", "/api/models/embedder"), ("POST", "/api/models/embedder/download"), ("POST", "/api/embed")] {
            assert_eq!(route(&a, m, p, None, b"{}").await.status, 401, "{m} {p}");
        }
        let c = sign_in(&a).await;
        let (s, v) = json_call(&a, "GET", "/api/models/embedder", &c, "").await;
        assert_eq!((s, v["result"]["state"].clone(), v["result"]["library_found"].clone()), (200, json!("missing"), json!(false)));
        assert_eq!(json_call(&a, "POST", "/api/embed", &c, "nope").await.0, 400);
        assert_eq!(json_call(&a, "POST", "/api/embed", &c, r#"{"texts":[]}"#).await.0, 400);
        let many = json!({"texts": vec!["x"; 65]}).to_string();
        assert_eq!(json_call(&a, "POST", "/api/embed", &c, &many).await.0, 400);
        // a good call with no model on the server: asked to wait, and the download has started
        let (s, v) = json_call(&a, "POST", "/api/embed", &c, r#"{"texts":["hello"]}"#).await;
        assert_eq!((s, v["error"]["code"].clone()), (503, json!("model_missing")));
    }

    #[tokio::test]
    async fn the_llm_routes_need_a_session_and_check_their_input() {
        let d = TempDir::new("route-llm");
        let a = file_app(&d);
        for (m, p) in [("GET", "/api/llm/models"), ("POST", "/api/llm/load"), ("POST", "/api/llm/generate"), ("POST", "/api/llm/stop")] {
            assert_eq!(route(&a, m, p, None, b"{}").await.status, 401, "{m} {p}");
        }
        let c = sign_in(&a).await;
        std::fs::create_dir_all(d.0.join("models")).unwrap();
        std::fs::write(d.0.join("models").join("chat.gguf"), b"abc").unwrap();
        std::fs::write(d.0.join("models").join("bge-m3-Q8_0.gguf"), b"e").unwrap();
        let (s, v) = json_call(&a, "GET", "/api/llm/models", &c, "").await;
        assert_eq!(s, 200);
        assert_eq!(v["result"]["models"], json!([{"id": "chat.gguf", "size": 3, "loaded": false}]));
        assert_eq!(json_call(&a, "GET", "/api/llm/models?v=2", &c, "").await.0, 400);
        assert_eq!(json_call(&a, "GET", "/api/llm/models?v=1", &c, "").await.0, 200);
        // every POST carries v:1
        for p in ["load", "generate", "stop"] {
            let (s, v) = json_call(&a, "POST", &format!("/api/llm/{p}"), &c, r#"{"v":2,"model":"chat.gguf","request":{}}"#).await;
            assert_eq!((s, v["error"]["code"].clone()), (400, json!("unsupported_version")), "{p}");
            assert_eq!(json_call(&a, "POST", &format!("/api/llm/{p}"), &c, "{}").await.0, 400, "{p}");
        }
        // an id, never a path
        for bad in ["../chat.gguf", "/etc/passwd", "models/chat.gguf"] {
            let body = json!({"v": 1, "model": bad}).to_string();
            assert_eq!(json_call(&a, "POST", "/api/llm/load", &c, &body).await.0, 400, "{bad}");
        }
        let (s, v) = json_call(&a, "POST", "/api/llm/load", &c, r#"{"v":1,"model":"nope.gguf"}"#).await;
        assert_eq!((s, v["error"]["code"].clone()), (404, json!("model_not_found")));
        // the embedder is not a chat model
        assert_eq!(json_call(&a, "POST", "/api/llm/load", &c, r#"{"v":1,"model":"bge-m3-Q8_0.gguf"}"#).await.0, 404);
        // a real file but no library: the load says why
        let (s, v) = json_call(&a, "POST", "/api/llm/load", &c, r#"{"v":1,"model":"chat.gguf"}"#).await;
        assert_eq!((s, v["error"]["code"].clone()), (503, json!("load_failed")));
        // nothing loaded: generate is refused before any stream starts
        let (s, v) = json_call(&a, "POST", "/api/llm/generate", &c, r#"{"v":1,"request":{"messages":[]}}"#).await;
        assert_eq!((s, v["error"]["code"].clone()), (409, json!("no_model")));
        let (s, v) = json_call(&a, "POST", "/api/llm/stop", &c, r#"{"v":1}"#).await;
        assert_eq!((s, v["result"]["stopped"].clone()), (200, json!(false)));
        assert_eq!(json_call(&a, "GET", "/api/llm/other", &c, "").await.0, 404);
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

    const ID: &str = "0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b";

    async fn zim_token(a: &App, cookie: &str) -> String {
        let r = route(a, "POST", "/api/zim/token", Some(cookie), b"").await;
        assert_eq!(r.status, 200);
        let v: Value = serde_json::from_slice(&r.body).unwrap();
        v["result"]["token"].as_str().unwrap().to_string()
    }

    #[tokio::test]
    async fn a_zim_token_needs_a_session_to_be_made() {
        let d = TempDir::new("zimtok");
        let a = file_app(&d);
        assert_eq!(route(&a, "POST", "/api/zim/token", None, b"").await.status, 401);
        assert_eq!(route(&a, "POST", "/api/zim/token", Some("cache_session=forged"), b"").await.status, 401);
        let c = sign_in(&a).await;
        let r = route(&a, "POST", "/api/zim/token", Some(&c), b"").await;
        assert_eq!(serde_json::from_slice::<Value>(&r.body).unwrap()["result"]["ttl"], 12 * 3600);
        let t = zim_token(&a, &c).await;
        assert!(t.len() >= 40 && t != c.trim_start_matches("cache_session="));
        assert_ne!(t, zim_token(&a, &c).await, "every call makes a new one");
    }

    #[tokio::test]
    async fn a_zim_token_opens_zim_and_nothing_under_api() {
        let d = TempDir::new("zimonly");
        let a = file_app(&d);
        let c = sign_in(&a).await;
        let t = zim_token(&a, &c).await;
        // as a path with no cookie: /zim/ accepts it (503: the token is good, there is no helper in this test)
        assert_eq!(route(&a, "GET", &format!("/zim/{t}/{ID}/A/x.html"), None, b"").await.status, 503);
        // sent in place of the session cookie, it is not a session anywhere
        let as_cookie = format!("cache_session={t}");
        for (m, p) in [("GET", "/api/status"), ("POST", "/api/core"), ("POST", "/api/zim/token"), ("GET", "/api/library/items"), ("POST", "/api/library/upload"), ("GET", "/api/fetch")] {
            assert_eq!(route(&a, m, p, Some(&as_cookie), br#"{"op":"version"}"#).await.status, 401, "{m} {p} with the token as the cookie");
            assert_eq!(route(&a, m, p, None, br#"{"op":"version"}"#).await.status, 401, "{m} {p} with no cookie");
        }
        // carried in the path of an /api/ request, it does not sign anything in
        for p in [format!("/api/core/{t}"), format!("/api/status/{t}"), format!("/api/zim/{t}/status")] {
            assert_eq!(route(&a, "GET", &p, None, b"").await.status, 401, "{p}");
        }
        assert_eq!(route(&a, "GET", "/auth/check", Some(&as_cookie), b"").await.status, 401);
        assert_eq!(route(&a, "GET", "/main.dart.js", Some(&as_cookie), b"").await.status, 401);
        // and the session does not open /zim/ without the token
        assert_eq!(route(&a, "GET", &format!("/zim/{ID}/A/x.html"), Some(&c), b"").await.status, 401);
    }

    #[tokio::test]
    async fn zim_refuses_a_bad_or_expired_token() {
        let d = TempDir::new("zimbad");
        let a = file_app(&d);
        let c = sign_in(&a).await;
        let t = zim_token(&a, &c).await;
        for bad in ["nope".to_string(), String::new(), format!("{t}x"), t.to_uppercase(), c.trim_start_matches("cache_session=").to_string()] {
            let r = route(&a, "GET", &format!("/zim/{bad}/{ID}/A/x.html"), Some(&c), b"").await;
            assert_eq!(r.status, 401, "token {bad:?}");
        }
        assert_eq!(route(&a, "GET", "/zim/", Some(&c), b"").await.status, 404);
        assert_eq!(route(&a, "GET", &format!("/zim/{t}"), None, b"").await.status, 404);
        assert_eq!(route(&a, "GET", &format!("/zim/{t}/not-a-uuid/x"), None, b"").await.status, 404);
        assert_eq!(route(&a, "POST", &format!("/zim/{t}/{ID}/x"), None, b"").await.status, 405);
        // expiry: good until the end of its 12 hours, gone after
        let at = crate::auth::now();
        assert!(a.auth.zim_token_valid_at(&t, at + crate::auth::ZIM_TOKEN_SECS - 5));
        assert!(!a.auth.zim_token_valid_at(&t, at + crate::auth::ZIM_TOKEN_SECS + 1));
        // a server told to make them short-lived
        let d2 = TempDir::new("zimshort");
        let mut short = file_app(&d2);
        let mut auth = Auth::load(&d2.0, true).unwrap();
        auth.zim_secs = 0;
        short.auth = Arc::new(auth);
        let c2 = sign_in(&short).await;
        let t2 = zim_token(&short, &c2).await;
        assert_eq!(route(&short, "GET", &format!("/zim/{t2}/{ID}/A/x.html"), None, b"").await.status, 401);
    }

    #[tokio::test]
    async fn zim_tokens_end_with_their_session() {
        let d = TempDir::new("zimlogout");
        let a = file_app(&d);
        let c = sign_in(&a).await;
        let c_other = sign_in(&a).await;
        let t = zim_token(&a, &c).await;
        let t_other = zim_token(&a, &c_other).await;
        let page = |t: &str| format!("/zim/{t}/{ID}/A/x.html");
        assert_eq!(route(&a, "GET", &page(&t), None, b"").await.status, 503);
        assert_eq!(route(&a, "POST", "/auth/logout", Some(&c), b"").await.status, 204);
        assert_eq!(route(&a, "GET", &page(&t), None, b"").await.status, 401, "its session signed out");
        assert_eq!(route(&a, "GET", &page(&t_other), None, b"").await.status, 503, "another session's token is untouched");
        // a session cleared by `set-password --sign-out-all` takes its tokens along
        crate::auth::Sessions::clear_file(&d.0.join("sessions.json")).unwrap();
        assert_eq!(route(&a, "GET", &page(&t_other), None, b"").await.status, 401);
    }

    #[test]
    fn zim_entries_with_a_generic_type_get_one_from_the_extension() {
        for (mime, entry, want) in [
            ("application/octet-stream", "assets/index.js", "text/javascript"),
            ("", "assets/index.mjs", "text/javascript"),
            ("application/octet-stream", "assets/index.css?v=3", "text/css"),
            ("Application/Octet-Stream; x=y", "A/Page.HTML", "text/html"),
            ("", "i/logo.svg", "image/svg+xml"),
            ("", "i/a.png", "image/png"),
            ("", "i/a.JPG", "image/jpeg"),
            ("", "i/a.jpeg", "image/jpeg"),
            ("", "i/a.gif", "image/gif"),
            ("", "i/a.webp", "image/webp"),
            ("", "i/favicon.ico", "image/x-icon"),
            ("", "f/a.woff", "font/woff"),
            ("", "f/a.woff2", "font/woff2"),
            ("", "f/a.ttf", "font/ttf"),
            ("", "d/a.json", "application/json"),
            ("", "d/a.wasm", "application/wasm"),
            ("", "d/a.txt", "text/plain"),
            // a specific type from the ZIM is kept, whatever the extension says
            ("text/css", "assets/odd.js", "text/css"),
            ("text/html; charset=utf-8", "A/x.html", "text/html; charset=utf-8"),
            // nothing to infer from: unchanged
            ("application/octet-stream", "A/noext", "application/octet-stream"),
            ("application/octet-stream", "A/dir.v2/noext", "application/octet-stream"),
            ("application/octet-stream", "A/x.bin", "application/octet-stream"),
        ] {
            assert_eq!(effective_mime(mime, entry), want, "{mime:?} {entry}");
        }
    }

    #[tokio::test]
    async fn the_build_routes_need_a_session() {
        let d = TempDir::new("route-build-auth");
        let a = file_app(&d);
        for (m, p) in [
            ("GET", "/api/build/libraries"),
            ("POST", "/api/build/libraries"),
            ("PATCH", "/api/build/libraries/x"),
            ("DELETE", "/api/build/libraries/x"),
            ("GET", "/api/build/libraries/x/books"),
            ("POST", "/api/build/upload?library_id=x&name=a.pdf"),
            ("GET", "/api/build/queue"),
            ("POST", "/api/build/queue/pause"),
            ("POST", "/api/build/queue/stop"),
            ("GET", "/api/build/drop"),
            ("PUT", "/api/build/drop"),
            ("POST", "/api/build/drop/check"),
            ("GET", "/api/build/classes"),
            ("POST", "/api/build/classes/reclassify"),
            ("GET", "/api/build/removed"),
            ("POST", "/api/build/removed/x/restore"),
            ("DELETE", "/api/build/removed"),
            ("POST", "/api/build/queue/x/decide"),
            ("POST", "/api/build/libraries/x/books/y/place"),
            ("GET", "/api/build/libraries/x/books/y/suggestions"),
            ("GET", "/api/build/bookshelves"),
            ("GET", "/api/build/bookshelves/stamp"),
            ("GET", "/api/build/bookshelves/facts"),
            ("POST", "/api/build/bookshelves/events"),
        ] {
            let r = route(&a, m, p, None, b"{}").await;
            assert_eq!(r.status, 401, "{m} {p}");
        }
    }

    #[tokio::test]
    async fn the_build_api_makes_libraries_queues_books_and_runs_the_drop_folder() {
        use crate::libbuild::testpdf::book;
        let d = TempDir::new("route-build");
        let a = file_app(&d);
        let c = sign_in(&a).await;
        // libraries
        assert_eq!(json_call(&a, "POST", "/api/build/libraries", &c, "nope").await.0, 400);
        assert_eq!(json_call(&a, "POST", "/api/build/libraries", &c, "{}").await.0, 400);
        let (s, v) = json_call(&a, "POST", "/api/build/libraries", &c, r#"{"title":"Wells"}"#).await;
        assert_eq!((s, v["ok"].clone()), (200, json!(true)));
        let lib = v["result"]["id"].as_str().unwrap().to_string();
        assert_eq!(v["result"]["books"], json!(0));
        let (s, v) = json_call(&a, "POST", "/api/build/libraries", &c, r#"{"title":"wells"}"#).await;
        assert_eq!((s, v["error"]["code"].clone()), (409, json!("name_taken")));
        let (_, v) = json_call(&a, "PATCH", &format!("/api/build/libraries/{lib}"), &c, r#"{"title":"Water wells"}"#).await;
        assert_eq!(v["result"]["title"], json!("Water wells"));
        assert_eq!(json_call(&a, "PATCH", "/api/build/libraries/nope", &c, r#"{"title":"x"}"#).await.0, 404);
        // an upload is queued; a non-PDF and an unknown library are refused
        let pdf = book("well", 3, Some("Well book"));
        let up = format!("/api/build/upload?library_id={lib}&name=well.pdf");
        let r = route(&a, "POST", &up, Some(&c), &pdf).await;
        assert_eq!(r.status, 200, "{}", body_str(&r));
        let v: Value = serde_json::from_slice(&r.body).unwrap();
        let item = v["result"]["id"].as_str().unwrap().to_string();
        assert_eq!((v["result"]["state"].clone(), v["result"]["position"].clone()), (json!("queued"), json!(1)));
        assert_eq!(route(&a, "POST", &format!("/api/build/upload?library_id={lib}&name=a.pdf"), Some(&c), b"plain text").await.status, 400);
        assert_eq!(route(&a, "POST", "/api/build/upload?library_id=nope&name=a.pdf", Some(&c), &pdf).await.status, 404);
        // the queue, pause and resume
        let (_, q) = json_call(&a, "GET", "/api/build/queue", &c, "").await;
        assert_eq!((q["result"]["counts"]["waiting"].clone(), q["result"]["items"][0]["file_name"].clone()), (json!(1), json!("well.pdf")));
        assert_eq!(json_call(&a, "POST", "/api/build/queue/pause", &c, "").await.1["result"]["paused"], json!(true));
        assert_eq!(json_call(&a, "POST", "/api/build/queue/resume", &c, "").await.1["result"]["paused"], json!(false));
        assert_eq!(json_call(&a, "POST", &format!("/api/build/queue/{item}/retry"), &c, "").await.0, 409);
        assert_eq!(json_call(&a, "POST", "/api/build/queue/nope/retry", &c, "").await.0, 404);
        // build it (the service's thread is not started in tests), then the books
        assert!(matches!(a.build.run_one(), crate::libbuild::Run::Ran));
        let (_, q) = json_call(&a, "GET", "/api/build/queue", &c, "").await;
        assert_eq!(q["result"]["items"][0]["state"], json!("done"));
        let (_, l) = json_call(&a, "GET", "/api/build/libraries", &c, "").await;
        assert_eq!((l["result"][0]["books"].clone(), l["result"][0]["published"].clone()), (json!(1), json!(true)));
        let (_, b) = json_call(&a, "GET", &format!("/api/build/libraries/{lib}/books"), &c, "").await;
        let doc = b["result"][0]["id"].as_str().unwrap().to_string();
        assert_eq!(b["result"][0]["title"], json!("Well book"));
        let (_, v) = json_call(&a, "PATCH", &format!("/api/build/libraries/{lib}/books/{doc}"), &c, r#"{"title":"Wells, 2nd"}"#).await;
        assert_eq!(v["result"]["title"], json!("Wells, 2nd"));
        // a new edition goes through the replace upload
        let v2 = book("pump", 4, None);
        let r = route(&a, "POST", &format!("/api/build/libraries/{lib}/books/{doc}/replace?name=well%20v2.pdf"), Some(&c), &v2).await;
        assert_eq!(r.status, 200, "{}", body_str(&r));
        assert_eq!(serde_json::from_slice::<Value>(&r.body).unwrap()["result"]["replace"], json!(doc));
        assert_eq!(route(&a, "POST", &format!("/api/build/libraries/{lib}/books/nope/replace?name=x.pdf"), Some(&c), &v2).await.status, 404);
        assert!(matches!(a.build.run_one(), crate::libbuild::Run::Ran));
        let (_, b) = json_call(&a, "GET", &format!("/api/build/libraries/{lib}/books"), &c, "").await;
        assert_eq!((b["result"][0]["doc_version"].clone(), b["result"][0]["title"].clone()), (json!(2), json!("Wells, 2nd")));
        // stop takes the waiting books off the list
        let _ = route(&a, "POST", &up, Some(&c), &book("river", 2, None)).await;
        let (_, v) = json_call(&a, "POST", "/api/build/queue/stop", &c, "").await;
        assert_eq!(v["result"]["removed"], json!(1));
        // the drop folder
        let (_, dv) = json_call(&a, "GET", "/api/build/drop", &c, "").await;
        assert_eq!((dv["result"]["settings"]["enabled"].clone(), dv["result"]["status"]["state"].clone()), (json!(false), json!("off")));
        let folder = d.0.join("dropped");
        let body = json!({"folder": folder.to_string_lossy(), "enabled": true, "library_id": lib}).to_string();
        let (s, dv) = json_call(&a, "PUT", "/api/build/drop", &c, &body).await;
        assert_eq!((s, dv["result"]["settings"]["library_title"].clone()), (200, json!("Water wells")));
        assert_eq!(json_call(&a, "PUT", "/api/build/drop", &c, r#"{"folder":"relative"}"#).await.0, 400);
        std::fs::write(folder.join("ingest/notes.txt"), b"x").unwrap();
        // the file has to settle (30 s) before it is taken: the first check only notices it
        let (_, dv) = json_call(&a, "POST", "/api/build/drop/check", &c, "").await;
        assert_eq!(dv["result"]["status"]["state"], json!("ok"));
        assert!(dv["result"]["status"]["last_check"].is_string());
        assert_eq!(dv["result"]["files"][0]["state"], json!("new"));
        assert_eq!(json_call(&a, "POST", "/api/build/drop/retry", &c, r#"{"name":"missing.pdf"}"#).await.0, 409);
        // the library goes
        assert_eq!(json_call(&a, "DELETE", &format!("/api/build/libraries/{lib}/books/{doc}"), &c, "").await.0, 200);
        assert_eq!(json_call(&a, "DELETE", &format!("/api/build/libraries/{lib}"), &c, "").await.0, 200);
        assert_eq!(json_call(&a, "DELETE", &format!("/api/build/libraries/{lib}"), &c, "").await.0, 404);
        // filing, choices and Removed
        let (s, v) = json_call(&a, "GET", "/api/build/classes", &c, "").await;
        assert_eq!((s, v["result"]["classes"].as_array().map(|x| x.len())), (200, Some(10)));
        assert_eq!(json_call(&a, "GET", "/api/build/classes?library_id=nope", &c, "").await.0, 404);
        assert_eq!(json_call(&a, "POST", &format!("/api/build/libraries/{lib}/books/nope/place"), &c, r#"{"division":"510"}"#).await.0, 404);
        assert_eq!(json_call(&a, "POST", "/api/build/queue/nope/decide", &c, r#"{"action":"keep_both"}"#).await.0, 404);
        // no classifier model file in this data folder
        assert_eq!(json_call(&a, "POST", "/api/build/classes/reclassify", &c, "{}").await.0, 409);
        assert_eq!(json_call(&a, "GET", &format!("/api/build/libraries/{lib}/books/nope/suggestions"), &c, "").await.0, 404);
        let (s, v) = json_call(&a, "GET", "/api/build/removed", &c, "").await;
        assert!(s == 200 && v["result"]["count"].is_u64() && v["result"]["items"].is_array());
        assert_eq!(json_call(&a, "POST", "/api/build/removed/nope/restore", &c, "").await.0, 404);
        assert_eq!(json_call(&a, "DELETE", "/api/build/removed/nope", &c, "").await.0, 404);
        assert_eq!(json_call(&a, "DELETE", "/api/build/removed", &c, "").await.0, 200);
        // unknown build endpoints are 404 like the rest
        assert_eq!(json_call(&a, "GET", "/api/build/nope", &c, "").await.0, 404);
    }
}
