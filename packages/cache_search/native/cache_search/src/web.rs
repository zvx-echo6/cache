//! Web search and web reads: the `web_search` tool, the provider interface, the Kagi provider, and the page fetch
//! behind `read` on a `web:` address. See DESIGN.md, "Web search".
//!
//! - `web_search` is a registered `cache_tool::Tool` (`WebSearchTool`) that shares a `WebState` with the handle. It
//!   is offered only while a provider, a key and the app's "online" flag are all set.
//! - The key lives only in `WebState`, in memory. It is sent as a request header, never written to disk, never put
//!   in a URL, a log line, an output or an error detail.
//! - Every network call runs on its own thread and the caller waits at most until the deadline, so a stalled DNS
//!   lookup or a slow server cannot hold the handle past the budget.
//! - Nothing from the web is written to disk or added to a library; it lives in the conversation only.
//! - HTTP is `ureq` with rustls and the compiled-in root certificates (webpki-roots), the same client as `cache_live`,
//!   `cache_layers` and `cache_video`. It does not use the platform certificate verifier: that one needs the Android
//!   JVM handed to it at start-up, which a Dart FFI library never does (see `tls_roots`).

use crate::conv::one_line;
use crate::error::{Error, Result};
use crate::html;
use cache_tool::{text_marker, Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Value};
use std::error::Error as StdError;
use std::io::Read;
use std::sync::{mpsc, Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// The default Kagi search endpoint.
pub const KAGI_URL: &str = "https://kagi.com/api/v1/search";
/// Time for `web_search` from the call to the result.
pub const SEARCH_BUDGET: Duration = Duration::from_secs(6);
/// Time for the fetch, download and parse of `read` on a web result.
pub const READ_BUDGET: Duration = Duration::from_secs(8);
/// Bytes of a page downloaded; the rest is dropped.
pub const PAGE_CAP: usize = 2 * 1024 * 1024;
/// Bytes of a provider's answer read.
const API_CAP: usize = 1024 * 1024;
/// Results `web_search` returns.
pub const WEB_HITS: usize = 5;
/// A fetched page whose extracted text is shorter than this many characters is treated as having little readable text
/// (a script-rendered shell with only navigation or a footer): `read` adds the stored snippet and a closing marker.
pub const LITTLE_TEXT_CHARS: usize = 500;
/// Redirects followed.
const MAX_REDIRECTS: usize = 5;
/// Longest title shown, in characters.
const TITLE_CHARS: usize = 150;

/// The schema of `web_search`, verbatim from docs/TOOLS.md.
const WEB_SEARCH_SCHEMA: &str = r#"{"type": "function", "function": {
  "name": "web_search",
  "description": "Search the web. Only for what the offline library cannot answer or for current information (news, prices, recent events). Search the offline library first.",
  "parameters": {"type": "object", "properties": {
    "query": {"type": "string", "minLength": 1, "maxLength": 200,
              "description": "What to search for, in plain words."}},
    "required": ["query"], "additionalProperties": false}}}"#;

fn user_agent() -> String {
    format!("Cache/{}", env!("CARGO_PKG_VERSION"))
}

// ---- provider interface ----------------------------------------------------------------------------------

/// One web search result.
#[derive(Clone, Debug, PartialEq)]
pub struct WebHit {
    pub url: String,
    pub title: String,
    pub snippet: String,
}

/// A web search service. `search` returns at most `limit` hits and must be done by `deadline`.
/// The `key` is the account key; a provider must send it only to its own service.
pub trait WebSearchProvider: Send + Sync {
    fn search(&self, query: &str, limit: usize, key: &str, deadline: Instant) -> std::result::Result<Vec<WebHit>, ToolError>;

    /// Debug data the service sent with the last answer (for Kagi, its `meta` object: request id, timing). It goes to
    /// the debug timing field only and is never shown to the model. Taking it clears it.
    fn take_meta(&self) -> Option<Value> {
        None
    }

    /// The full error chain of the last failed request (transport failures only), for the debug timing field and never shown
    /// to the model. It holds no key and no query. Taking it clears it.
    fn take_failure(&self) -> Option<String> {
        None
    }
}

/// Kagi's search API (v1): `POST` with a JSON body and `Authorization: Bearer <key>`. It matches the request AIDA uses in
/// production (Open WebUI kagi.py); the invalid-key answer is live-verified (2026-10-26), a valid search is not. Tested against a local stand-in server.
#[derive(Debug)]
pub struct KagiProvider {
    pub base_url: String,
    meta: Mutex<Option<Value>>,
    failure: Mutex<Option<String>>,
}

impl Default for KagiProvider {
    fn default() -> Self {
        KagiProvider::with_base_url(KAGI_URL)
    }
}

impl KagiProvider {
    /// Kagi at another address (tests point it at a local server).
    pub fn with_base_url(base_url: impl Into<String>) -> Self {
        KagiProvider { base_url: base_url.into(), meta: Mutex::new(None), failure: Mutex::new(None) }
    }
}

impl WebSearchProvider for KagiProvider {
    fn search(&self, query: &str, limit: usize, key: &str, deadline: Instant) -> std::result::Result<Vec<WebHit>, ToolError> {
        let lower = self.base_url.trim().to_ascii_lowercase();
        if !(lower.starts_with("http://") || lower.starts_with("https://")) {
            return Err(ToolError::new(ToolError::NOT_CONFIGURED, "the web search address is not valid"));
        }
        let auth = format!("Bearer {key}");
        let body = json!({"query": query, "limit": limit}).to_string();
        *lock(&self.failure) = None;
        let reply = http_request(
            self.base_url.trim(),
            &[("Authorization", auth.as_str()), ("Accept", "application/json"), ("Content-Type", "application/json")],
            Some(body),
            deadline,
            API_CAP,
        )
        .map_err(|f| {
            // the key is in a header and the query in the body, neither in an error; the tool scrubs the key from both anyway
            *lock(&self.failure) = Some(f.chain.clone());
            match f.kind {
                HttpFail::TimedOut => ToolError::new(ToolError::FETCH_FAILED, "web search timed out"),
                HttpFail::Connect => ToolError::new(ToolError::FETCH_FAILED, format!("could not reach the web search server ({})", f.cause)),
                HttpFail::Other => ToolError::new(ToolError::FETCH_FAILED, format!("the web search request failed ({})", f.cause)),
            }
        })?;
        *lock(&self.meta) = None;
        let (hits, meta) = parse_kagi_full(reply.status, &reply.body, limit)?;
        *lock(&self.meta) = meta;
        Ok(hits)
    }

    fn take_meta(&self) -> Option<Value> {
        lock(&self.meta).take()
    }

    fn take_failure(&self) -> Option<String> {
        lock(&self.failure).take()
    }
}

fn key_rejected() -> ToolError {
    ToolError::new(ToolError::KEY_MISSING, "web search key rejected")
}

fn quota_reached() -> ToolError {
    ToolError::new(ToolError::QUOTA, "web search limit reached")
}

/// Kagi's answer as hits or a tool error. The results are `data.search`, an array of objects with `url`, `title` and an
/// optional `snippet`; other fields and other `data` members are ignored. A failure is an `error` array or object (seen
/// once live: HTTP 400 with `errors[].code` "general.invalid_token" is a rejected key; also a 401/403 code or status, a 402/429 code or a message about
/// balance, credit or quota is `quota`). A 200 with an `error`, or without a `data` object, is `bad_response` (its
/// detail lists the key names, never values). A `data` object whose `search` is missing or null is zero results.
pub fn parse_kagi(status: u16, body: &[u8], limit: usize) -> std::result::Result<Vec<WebHit>, ToolError> {
    parse_kagi_full(status, body, limit).map(|(hits, _)| hits)
}

/// Names of the members of a JSON object (at most 20, each cut to 40 chars, one line); never any value.
fn key_names(v: &Value) -> String {
    let Some(o) = v.as_object() else { return "none".to_string() };
    let names: Vec<String> = o.keys().take(20).map(|k| one_line(&k.chars().take(40).collect::<String>())).collect();
    if names.is_empty() { "none".to_string() } else { names.join(", ") }
}

/// `parse_kagi` plus Kagi's `meta` object, when the answer has one.
pub fn parse_kagi_full(status: u16, body: &[u8], limit: usize) -> std::result::Result<(Vec<WebHit>, Option<Value>), ToolError> {
    if status == 401 || status == 403 {
        return Err(key_rejected());
    }
    if status == 402 || status == 429 {
        return Err(quota_reached());
    }
    let parsed: Option<Value> = serde_json::from_slice(body).ok();
    // Kagi v1 answers a failure with `errors` (an array); `error` is the older spelling and is read too
    let mut errors: Vec<&Value> = Vec::new();
    for name in ["errors", "error"] {
        match parsed.as_ref().map(|v| &v[name]) {
            Some(Value::Array(a)) => errors.extend(a.iter()),
            Some(e @ Value::Object(_)) | Some(e @ Value::String(_)) => errors.push(e),
            _ => {}
        }
    }
    let msg_of = |e: &Value| -> String {
        e.as_str().or_else(|| e["msg"].as_str()).or_else(|| e["message"].as_str()).unwrap_or("").to_string()
    };
    for e in &errors {
        let msg = msg_of(e).to_lowercase();
        match e["code"].as_i64() {
            Some(401) | Some(403) => return Err(key_rejected()),
            Some(402) | Some(429) => return Err(quota_reached()),
            _ => {}
        }
        // observed 2026-10-26: an invalid key is HTTP 400 with code "general.invalid_token"
        if e["code"].as_str().is_some_and(|c| c == "general.invalid_token") {
            return Err(key_rejected());
        }
        if ["balance", "quota", "credit"].iter().any(|w| msg.contains(w)) {
            return Err(quota_reached());
        }
    }
    if !(200..300).contains(&status) {
        // the service's error code (a short identifier such as "general.invalid_token"), when it gave one
        let code: String = errors.iter().find_map(|e| e["code"].as_str()).map(|c| c.chars().filter(|c| c.is_ascii_alphanumeric() || "._-".contains(*c)).take(40).collect()).unwrap_or_default();
        let tail = if code.is_empty() { String::new() } else { format!(", {code}") };
        return Err(ToolError::new(ToolError::FETCH_FAILED, format!("web search failed (HTTP {status}{tail})")));
    }
    if let Some(e) = errors.first() {
        let msg: String = msg_of(e).chars().take(120).collect();
        return Err(ToolError::new(ToolError::BAD_RESPONSE, format!("web search error: {}", one_line(&msg))));
    }
    let Some(v) = parsed else {
        return Err(ToolError::new(ToolError::BAD_RESPONSE, "web search answered with something unreadable"));
    };
    let meta = v["meta"].as_object().filter(|m| !m.is_empty()).map(|_| v["meta"].clone());
    if !v["data"].is_object() {
        return Err(ToolError::new(
            ToolError::BAD_RESPONSE,
            format!("web search answered without a result list (keys: {})", key_names(&v)),
        ));
    }
    let empty = Vec::new();
    let data = match &v["data"]["search"] {
        Value::Null => &empty,
        Value::Array(a) => a,
        _ => {
            return Err(ToolError::new(
                ToolError::BAD_RESPONSE,
                format!("web search answered without a result list (keys: {}; data keys: {})", key_names(&v), key_names(&v["data"])),
            ));
        }
    };
    let mut hits = Vec::new();
    for item in data {
        let Some(url) = item["url"].as_str().map(str::trim).filter(|u| !u.is_empty()) else { continue };
        hits.push(WebHit {
            url: url.to_string(),
            title: item["title"].as_str().unwrap_or("").to_string(),
            snippet: item["snippet"].as_str().unwrap_or("").to_string(),
        });
        if hits.len() >= limit {
            break;
        }
    }
    Ok((hits, meta))
}

// ---- HTTP ------------------------------------------------------------------------------------------------

#[derive(Debug)]
pub struct HttpReply {
    pub status: u16,
    pub content_type: Option<String>,
    pub body: Vec<u8>,
    /// True when the body was longer than the cap and the rest was dropped.
    pub capped: bool,
}

/// The class of a failed request, which decides the message the model sees.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum HttpFail {
    TimedOut,
    /// Name lookup, connecting, or the TLS handshake failed: the server was not reached.
    Connect,
    Other,
}

/// A failed request. `cause` is one short line led by the layer that failed (`tls: invalid peer certificate: UnknownIssuer`,
/// `dns: ...`, `connect: ...`, `timeout`, `io: ...`) and goes into the error detail. `chain` is the whole error chain and
/// goes only into the debug timing field. Neither holds the key (a header), the request body, or a URL's query string.
#[derive(Debug, PartialEq, Eq)]
pub struct HttpFailure {
    pub kind: HttpFail,
    pub cause: String,
    pub chain: String,
}

impl HttpFailure {
    fn timed_out(chain: impl Into<String>) -> HttpFailure {
        HttpFailure { kind: HttpFail::TimedOut, cause: "timeout".to_string(), chain: chain.into() }
    }

    fn other(layer: &str, chain: impl Into<String>) -> HttpFailure {
        let chain: String = chain.into();
        HttpFailure { kind: HttpFail::Other, cause: cap_chars(&format!("{layer}: {chain}"), CAUSE_CHARS), chain }
    }
}

/// Longest cause in an error detail, in characters.
const CAUSE_CHARS: usize = 120;

fn cap_chars(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        format!("{}...", s.chars().take(n).collect::<String>())
    }
}

/// Where the web client gets the root certificates it trusts.
#[derive(Debug, PartialEq, Eq, Clone, Copy)]
pub enum TlsRoots {
    /// The roots compiled into the library (webpki-roots, through ureq's rustls): the same on every platform.
    Bundled,
    /// The operating system's verifier (rustls-platform-verifier). On Android it needs the JVM and the app context handed
    /// to it from Kotlin before the first request; a Dart FFI library gets neither, so every HTTPS request failed.
    /// This is what `reqwest`'s `rustls` feature used here until v4. Nothing builds a client with it any more.
    Platform,
}

/// The roots the web client verifies servers against. `web_agent` is the only place a client is built and it takes no
/// platform verifier; the test `the_web_client_uses_bundled_roots` checks the dependency that selects it.
pub const fn tls_roots() -> TlsRoots {
    TlsRoots::Bundled
}

/// The one HTTP client of web search and web reads: `ureq` (blocking, rustls, `tls_roots()`), a fresh agent per request so
/// the request's own timeout is the remaining time to the deadline.
fn web_agent(timeout: Duration) -> ureq::Agent {
    // ureq's limit counts the final request too: `redirects(n)` follows n - 1 redirects, so one more than MAX_REDIRECTS
    ureq::AgentBuilder::new().timeout(timeout).redirects(MAX_REDIRECTS as u32 + 1).user_agent(&user_agent()).build()
}

/// `s` with `url`'s query string taken out wherever the URL (or just its query) appears.
fn scrub_url(s: &str, url: &str) -> String {
    let Some((base, query)) = url.split_once('?') else { return s.to_string() };
    let query = query.split('#').next().unwrap_or("");
    let mut out = s.replace(url, base);
    if !query.is_empty() {
        out = out.replace(query, "...");
    }
    out
}

/// The failure of one request as a layer, a short cause and the full chain. Walks the transport error and every source
/// beneath it (an I/O error, a rustls error), which `Display` of the transport alone does not show.
fn describe(t: &ureq::Transport, url: &str) -> HttpFailure {
    let mut parts: Vec<String> = Vec::new();
    let mut add = |s: String| {
        let s = one_line(&scrub_url(&s, url));
        if !s.is_empty() && !parts.iter().any(|p| p.contains(&s)) {
            parts.push(s);
        }
    };
    if let Some(m) = t.message() {
        add(m.to_string());
    }
    let mut timed_out = false;
    let mut src = StdError::source(t);
    while let Some(e) = src {
        if let Some(io) = e.downcast_ref::<std::io::Error>() {
            timed_out |= matches!(io.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock);
        }
        add(e.to_string());
        src = e.source();
    }
    // the part that says the most is the deepest one that is not a bare wrapper
    let chain = if parts.is_empty() { format!("{:?}", t.kind()) } else { parts.join(" <- ") };
    let detail = parts.last().cloned().unwrap_or_else(|| format!("{:?}", t.kind()));
    if timed_out || chain.to_ascii_lowercase().contains("timed out") {
        return HttpFailure::timed_out(chain);
    }
    let lower = chain.to_ascii_lowercase();
    let tls = ["certificate", "handshake", "tls", "rustls", "peer ", "alert", "invalid message", "corrupt"].iter().any(|w| lower.contains(w));
    use ureq::ErrorKind as K;
    let (kind, layer) = match t.kind() {
        K::Io | K::ConnectionFailed if tls => (HttpFail::Connect, "tls"),
        K::Dns => (HttpFail::Connect, "dns"),
        K::ConnectionFailed => (HttpFail::Connect, "connect"),
        K::Io => (HttpFail::Other, "io"),
        K::TooManyRedirects => (HttpFail::Other, "redirects"),
        K::BadStatus | K::BadHeader => (HttpFail::Other, "protocol"),
        K::InvalidUrl | K::UnknownScheme | K::InsecureRequestHttpsOnly => (HttpFail::Other, "url"),
        K::InvalidProxyUrl | K::ProxyConnect | K::ProxyUnauthorized => (HttpFail::Other, "proxy"),
        K::HTTP => (HttpFail::Other, "http"),
    };
    HttpFailure { kind, cause: cap_chars(&format!("{layer}: {detail}"), CAUSE_CHARS), chain }
}

fn send_blocking(url: &str, headers: &[(String, String)], body: Option<String>, deadline: Instant, cap: usize) -> std::result::Result<HttpReply, HttpFailure> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(HttpFailure::timed_out("the deadline had passed before the request started"));
    }
    let agent = web_agent(remaining);
    let mut req = match body {
        Some(_) => agent.post(url),
        None => agent.get(url),
    };
    for (k, v) in headers {
        req = req.set(k, v);
    }
    let sent = match &body {
        Some(b) => req.send_string(b),
        None => req.call(),
    };
    let resp = match sent {
        Ok(r) => r,
        // an HTTP error status is an answer: the callers read its body and judge the status
        Err(ureq::Error::Status(_, r)) => r,
        Err(ureq::Error::Transport(t)) => return Err(describe(&t, url)),
    };
    let status = resp.status();
    let content_type = resp.header("content-type").map(str::to_string);
    let mut body = Vec::new();
    if let Err(e) = resp.into_reader().take(cap as u64 + 1).read_to_end(&mut body) {
        let chain = scrub_url(&one_line(&e.to_string()), url);
        let timed_out = matches!(e.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock) || Instant::now() >= deadline;
        return Err(if timed_out { HttpFailure::timed_out(chain) } else { HttpFailure::other("io", chain) });
    }
    let capped = body.len() > cap;
    body.truncate(cap);
    Ok(HttpReply { status, content_type, body, capped })
}

/// GET `url` and read at most `cap` bytes of the body, finishing by `deadline`. Follows up to 5 redirects. The work
/// runs on its own thread; if it has not answered by the deadline the call returns `TimedOut` and the thread ends by
/// itself when its own request times out.
pub fn http_get(url: &str, headers: &[(&str, &str)], deadline: Instant, cap: usize) -> std::result::Result<HttpReply, HttpFailure> {
    http_request(url, headers, None, deadline, cap)
}

/// `http_get`, or a POST with `body` when one is given (no redirects are followed differently; same limits).
pub fn http_request(url: &str, headers: &[(&str, &str)], body: Option<String>, deadline: Instant, cap: usize) -> std::result::Result<HttpReply, HttpFailure> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(HttpFailure::timed_out("the deadline had passed before the request started"));
    }
    let url = url.to_string();
    let headers: Vec<(String, String)> = headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(send_blocking(&url, &headers, body, deadline, cap));
    });
    match rx.recv_timeout(remaining) {
        Ok(r) => r,
        Err(mpsc::RecvTimeoutError::Timeout) => Err(HttpFailure::timed_out("no answer by the deadline")),
        Err(mpsc::RecvTimeoutError::Disconnected) => Err(HttpFailure::other("internal", "the request thread ended without an answer")),
    }
}

// ---- reading a page --------------------------------------------------------------------------------------

/// The result of fetching a page for `read`.
#[derive(Debug, PartialEq)]
pub enum Page {
    /// The page as plain text (uncut). `capped`: the download hit the size cap.
    Text { text: String, capped: bool },
    TimedOut,
    Unavailable,
}

/// Fetch `url` and turn it into text by `deadline`: HTML like a ZIM article (headings kept, script and style
/// removed), plain text as it is. Other content types, a bad status, or a page with no text are `Unavailable`.
pub fn fetch_page(url: &str, deadline: Instant, cap: usize) -> Page {
    fetch_page_why(url, deadline, cap).0
}

/// `fetch_page`, and why it failed when it did (a debug chain without the URL's query; see `HttpFailure`).
pub fn fetch_page_why(url: &str, deadline: Instant, cap: usize) -> (Page, Option<String>) {
    let lower = url.to_ascii_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return (Page::Unavailable, Some("not an http or https address".to_string()));
    }
    let reply = match http_get(url, &[("Accept", "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.1")], deadline, cap) {
        Ok(r) => r,
        Err(f) if f.kind == HttpFail::TimedOut => return (Page::TimedOut, Some(f.chain)),
        Err(f) => return (Page::Unavailable, Some(format!("{}: {}", f.cause, f.chain))),
    };
    if !(200..300).contains(&reply.status) {
        return (Page::Unavailable, Some(format!("HTTP status {}", reply.status)));
    }
    let page = page_of(reply, deadline);
    (page, None)
}

fn page_of(reply: HttpReply, deadline: Instant) -> Page {
    let ct = reply.content_type.as_deref().unwrap_or("text/html").to_ascii_lowercase();
    let is_html = ct.starts_with("text/html") || ct.starts_with("application/xhtml");
    let raw = String::from_utf8_lossy(&reply.body);
    let text = if is_html {
        html::html_to_text(&raw)
    } else if ct.starts_with("text/") {
        raw.trim().to_string()
    } else {
        return Page::Unavailable;
    };
    if Instant::now() > deadline {
        return Page::TimedOut;
    }
    if text.trim().is_empty() {
        return Page::Unavailable;
    }
    Page::Text { text, capped: reply.capped }
}

// ---- state and tool --------------------------------------------------------------------------------------

/// What the conversation remembers of one web result, so `read` can fall back to it.
#[derive(Clone, Debug, PartialEq)]
pub struct WebNote {
    pub title: String,
    pub snippet: String,
    /// Local time the result was downloaded, `YYYY-MM-DD HH:MM`.
    pub fetched: String,
}

struct Config {
    provider: Option<Arc<dyn WebSearchProvider>>,
    key: Option<String>,
    online: bool,
    search_budget: Duration,
    read_budget: Duration,
    page_cap: usize,
    snippet_chars: usize,
}

/// The web settings of a handle, shared with the `web_search` tool. Its `Debug` is deliberately absent so the key
/// cannot be printed by accident.
pub struct WebState {
    cfg: Mutex<Config>,
    pending: Mutex<Vec<(String, WebNote)>>,
    timing: Mutex<Option<Value>>,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|p| p.into_inner())
}

impl Default for WebState {
    fn default() -> Self {
        WebState::new()
    }
}

impl WebState {
    pub fn new() -> WebState {
        WebState {
            cfg: Mutex::new(Config {
                provider: None,
                key: None,
                online: false,
                search_budget: SEARCH_BUDGET,
                read_budget: READ_BUDGET,
                page_cap: PAGE_CAP,
                snippet_chars: 400,
            }),
            pending: Mutex::new(Vec::new()),
            timing: Mutex::new(None),
        }
    }

    /// Set the provider, the key and the online flag (an empty key is no key).
    pub fn configure(&self, provider: Option<Arc<dyn WebSearchProvider>>, key: Option<&str>, online: bool) {
        let mut c = lock(&self.cfg);
        c.provider = provider;
        c.key = key.filter(|k| !k.is_empty()).map(str::to_string);
        c.online = online;
    }

    /// `cs_set_web`: `provider` is "kagi" or None (web search off); an unknown name is `bad_json` and changes nothing.
    pub fn configure_named(&self, provider: Option<&str>, key: Option<&str>, online: bool) -> Result<()> {
        let p: Option<Arc<dyn WebSearchProvider>> = match provider.map(str::trim).filter(|p| !p.is_empty()) {
            None => None,
            Some(name) if name.eq_ignore_ascii_case("kagi") => Some(Arc::new(KagiProvider::default())),
            Some(_) => return Err(Error::bad_json("unknown web search provider (use \"kagi\")")),
        };
        self.configure(p, key, online);
        Ok(())
    }

    /// Time limits and the page size cap (tests use short ones).
    pub fn set_limits(&self, search_budget: Duration, read_budget: Duration, page_cap: usize) {
        let mut c = lock(&self.cfg);
        c.search_budget = search_budget;
        c.read_budget = read_budget;
        c.page_cap = page_cap;
    }

    pub fn set_snippet_chars(&self, n: usize) {
        lock(&self.cfg).snippet_chars = n;
    }

    /// True when `web_search` is offered: a provider, a key, and online.
    pub fn available(&self) -> bool {
        let c = lock(&self.cfg);
        c.provider.is_some() && c.key.is_some() && c.online
    }

    /// The web hits of the last `web_search` run, for the conversation to remember (cleared by the call).
    pub fn take_pending(&self) -> Vec<(String, WebNote)> {
        std::mem::take(&mut *lock(&self.pending))
    }

    /// Debug timing of the last web call: `{"search": ms}` (plus `"kagi_meta"` when the provider sent one) or
    /// `{"fetch": ms}`, plus `"failure"` (the full error chain: layer, TLS, DNS, connect, status, timeout) when the request
    /// failed. Never shown to the model; never holds the key or a query string.
    pub fn take_timing(&self) -> Option<Value> {
        lock(&self.timing).take()
    }

    fn set_timing(&self, what: &str, since: Instant, meta: Option<Value>, failure: Option<String>) {
        let mut t = json!({ what: since.elapsed().as_millis() as u64 });
        if let Some(m) = meta {
            t["kagi_meta"] = m;
        }
        if let Some(f) = failure {
            t["failure"] = Value::String(f);
        }
        *lock(&self.timing) = Some(t);
    }

    /// `read` of a web result: the page as text within the read budget. Offline, nothing is fetched.
    pub fn read_page(&self, url: &str) -> Page {
        let (online, budget, cap) = {
            let c = lock(&self.cfg);
            (c.online, c.read_budget, c.page_cap)
        };
        if !online {
            return Page::Unavailable;
        }
        let t0 = Instant::now();
        let (page, why) = fetch_page_why(url, t0 + budget, cap);
        self.set_timing("fetch", t0, None, why);
        page
    }
}

/// `YYYY-MM-DD HH:MM` from an ISO 8601 local time like `2026-10-25T14:20:05-06:00` (the date and time as written, not
/// converted). Anything of another shape is returned as it is.
pub fn fetched_stamp(now: &str) -> String {
    let b = now.as_bytes();
    if b.len() >= 16 && now.is_char_boundary(16) && (b[10] == b'T' || b[10] == b' ') && b[13] == b':' {
        format!("{} {}", &now[..10], &now[11..16])
    } else {
        now.to_string()
    }
}

/// Text from the web made safe for a result line: one line, no address markers, and (titles) no ` — `, which
/// the numbering reads as the end of the title.
/// A title or snippet from the web as plain text: tags removed, entities (named, decimal, hex) decoded, whitespace
/// collapsed. It runs before `clean`, so text that decodes to `{{` or ` — ` is still made safe there.
fn plain_fragment(s: &str) -> String {
    one_line(&html::strip(s))
}

fn clean(s: &str, title: bool) -> String {
    let mut t = one_line(s).replace("{{", "{ {");
    if title {
        t = t.replace(" \u{2014} ", " - ");
    }
    t
}

fn clean_url(u: &str) -> Option<String> {
    let u = u.trim();
    if u.is_empty() || u.chars().any(char::is_control) {
        return None;
    }
    Some(u.replace(' ', "%20").replace('{', "%7B").replace('}', "%7D"))
}

fn scrub(mut e: ToolError, key: &str) -> ToolError {
    if !key.is_empty() {
        e.detail = e.detail.replace(key, "***");
    }
    e
}

/// The registered `web_search` tool.
pub struct WebSearchTool(pub Arc<WebState>);

impl Tool for WebSearchTool {
    fn name(&self) -> &'static str {
        "web_search"
    }

    fn schema(&self) -> Option<Value> {
        self.0.available().then(|| serde_json::from_str(WEB_SEARCH_SCHEMA).expect("web_search schema is valid JSON"))
    }

    fn run(&self, ctx: &ToolCtx, args: &Value) -> std::result::Result<ToolOutput, ToolError> {
        let (provider, key, budget, snippet_chars) = {
            let c = lock(&self.0.cfg);
            match (&c.provider, &c.key) {
                (Some(p), Some(k)) if c.online => (p.clone(), k.clone(), c.search_budget, c.snippet_chars),
                _ => return Err(ToolError::new(ToolError::NOT_SET_UP, "web_search is not set up")),
            }
        };
        let query = args["query"].as_str().unwrap_or("");
        let t0 = Instant::now();
        let result = provider.search(query, WEB_HITS, &key, t0 + budget);
        let failure = provider.take_failure().map(|f| if key.is_empty() { f } else { f.replace(&key, "***") });
        self.0.set_timing("search", t0, provider.take_meta(), failure);
        let hits = result.map_err(|e| scrub(e, &key))?;
        let stamp = fetched_stamp(ctx.now);
        let mut seen: Vec<String> = Vec::new();
        let mut lines: Vec<String> = Vec::new();
        let mut notes: Vec<(String, WebNote)> = Vec::new();
        for h in hits {
            let Some(url) = clean_url(&h.url) else { continue };
            if seen.contains(&url) {
                continue;
            }
            seen.push(url.clone());
            let mut title = html::snippet_from_text(&clean(&plain_fragment(&h.title), true), TITLE_CHARS);
            if title.is_empty() {
                title = clean(&url, true);
            }
            let snippet = html::snippet_from_text(&clean(&plain_fragment(&h.snippet), false), snippet_chars);
            let address = format!("web:{url}");
            let mut line = format!("{} {title} (web, fetched {stamp})", text_marker(&address));
            if !snippet.is_empty() {
                line.push_str(&format!(" \u{2014} {snippet}"));
            }
            lines.push(line);
            notes.push((address, WebNote { title, snippet, fetched: stamp.clone() }));
            if lines.len() >= WEB_HITS {
                break;
            }
        }
        if lines.is_empty() {
            return Ok(ToolOutput::Text("No results found.".to_string()));
        }
        lock(&self.0.pending).extend(notes);
        Ok(ToolOutput::Text(lines.join("\n")))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn parse(status: u16, body: &str) -> std::result::Result<Vec<WebHit>, ToolError> {
        parse_kagi(status, body.as_bytes(), 5)
    }

    fn code(r: std::result::Result<Vec<WebHit>, ToolError>) -> (String, String) {
        let e = r.unwrap_err();
        (e.code, e.detail)
    }

    #[test]
    fn results_are_read_and_extra_fields_tolerated() {
        let body = r#"{"meta":{"id":"x","ms":12},"data":{"search":[
            {"rank":1,"url":"https://a.example/1","title":"One","snippet":"First.","published":null},
            {"rank":2,"url":"https://b.example/2","title":"Two"},
            {"url":"","title":"No url"},
            {"title":"No url at all"},
            {"rank":3,"url":"https://d.example/4","title":"Four","snippet":"4th","extra":{"x":1}}],
            "related_searches":["related one"]}}"#;
        let hits = parse(200, body).unwrap();
        assert_eq!(
            hits,
            vec![
                WebHit { url: "https://a.example/1".into(), title: "One".into(), snippet: "First.".into() },
                WebHit { url: "https://b.example/2".into(), title: "Two".into(), snippet: String::new() },
                WebHit { url: "https://d.example/4".into(), title: "Four".into(), snippet: "4th".into() },
            ]
        );
    }

    #[test]
    fn limit_is_honoured_and_empty_is_empty() {
        let body = r#"{"data":{"search":[{"url":"https://a/1","title":"A"},{"url":"https://a/2","title":"B"},{"url":"https://a/3","title":"C"}]}}"#;
        assert_eq!(parse_kagi(200, body.as_bytes(), 2).unwrap().len(), 2);
        assert_eq!(parse(200, r#"{"meta":{},"data":{"search":[]}}"#).unwrap(), vec![]);
    }

    #[test]
    fn auth_and_quota_statuses() {
        assert_eq!(code(parse(401, "")), ("key_missing".into(), "web search key rejected".into()));
        assert_eq!(code(parse(403, "not json")).0, "key_missing");
        assert_eq!(code(parse(429, "")).0, "quota");
        assert_eq!(code(parse(402, "")).0, "quota");
        assert_eq!(code(parse(500, "")), ("fetch_failed".into(), "web search failed (HTTP 500)".into()));
        assert_eq!(code(parse(404, "{}")).0, "fetch_failed");
    }

    #[test]
    fn error_arrays() {
        let q = r#"{"meta":{},"data":null,"error":[{"code":0,"msg":"Insufficient credit balance","ref":null}]}"#;
        assert_eq!(code(parse(200, q)).0, "quota");
        assert_eq!(code(parse(400, q)).0, "quota");
        let q = r#"{"data":null,"error":[{"code":1,"msg":"Monthly quota exceeded"}]}"#;
        assert_eq!(code(parse(200, q)).0, "quota");
        let k = r#"{"data":null,"error":[{"code":401,"msg":"Unauthorized"}]}"#;
        assert_eq!(code(parse(200, k)).0, "key_missing");
        let other = r#"{"data":null,"error":[{"code":7,"msg":"Bad\nquery"}]}"#;
        assert_eq!(code(parse(200, other)), ("bad_response".into(), "web search error: Bad query".into()));
        // an error object or string is judged the same way
        assert_eq!(code(parse(200, r#"{"error":{"message":"Out of credit"}}"#)).0, "quota");
        assert_eq!(code(parse(200, r#"{"error":"Insufficient balance"}"#)).0, "quota");
        assert_eq!(code(parse(200, r#"{"error":{"code":403,"message":"no"}}"#)).0, "key_missing");
        assert_eq!(code(parse(200, r#"{"error":{"message":"odd"},"data":{"search":[]}}"#)).0, "bad_response");
        // an empty error list is no error
        assert!(parse(200, r#"{"data":{"search":[]},"error":[]}"#).unwrap().is_empty());
    }

    #[test]
    fn kagi_invalid_key_as_seen_live() {
        // verbatim shape of Kagi's answer to an invalid token (2026-10-26): HTTP 400, `errors`, a string code
        let body = r#"{"meta":{"trace":"t","ms":23,"node":"us-central1"},"data":null,"errors":[{"code":"general.invalid_token","url":"https://kagi.com/api#todo","message":"Token signature failed to verify. Ensure your token has been correctly copied from your dashboard, containing no extra spaces or newlines."}]}"#;
        assert_eq!(code(parse(400, body)), ("key_missing".into(), "web search key rejected".into()));
        assert_eq!(code(parse(200, body)).0, "key_missing");
        // another 400 keeps its code in the detail and is not a key problem
        let other = r#"{"data":null,"errors":[{"code":"search.bad_query","message":"x"}]}"#;
        assert_eq!(code(parse(400, other)), ("fetch_failed".into(), "web search failed (HTTP 400, search.bad_query)".into()));
    }

    #[test]
    fn unreadable_answers_are_bad_response() {
        assert_eq!(code(parse(200, "<html>")).0, "bad_response");
        assert_eq!(code(parse(200, "")).0, "bad_response");
        assert_eq!(code(parse(200, r#"{"meta":{}}"#)).0, "bad_response");
        assert_eq!(code(parse(200, r#"{"data":"x"}"#)).0, "bad_response");
        assert_eq!(code(parse(200, r#"{"data":[]}"#)).0, "bad_response");
        assert_eq!(code(parse(200, r#"{"data":{"search":"x"}}"#)).0, "bad_response");
    }

    #[test]
    fn a_data_object_without_a_result_list_is_zero_results() {
        assert!(parse(200, r#"{"meta":{"id":"x"},"data":{}}"#).unwrap().is_empty());
        assert!(parse(200, r#"{"data":{"search":null}}"#).unwrap().is_empty());
        assert!(parse(200, r#"{"data":{"related_searches":["a"]}}"#).unwrap().is_empty());
        // an error still wins, and no data at all is still bad
        assert_eq!(code(parse(200, r#"{"data":{},"error":[{"msg":"boom"}]}"#)).0, "bad_response");
        assert_eq!(code(parse(200, r#"{"meta":{}}"#)).0, "bad_response");
    }

    #[test]
    fn bad_response_detail_has_key_names_and_no_values() {
        let (c, d) = code(parse(200, r#"{"meta":{"id":"SECRETVALUE"},"other":"SECRETVALUE2"}"#));
        assert_eq!(c, "bad_response");
        assert!(d.contains("keys: meta, other"), "{d}");
        assert!(!d.contains("SECRETVALUE"), "{d}");
        let (_, d) = code(parse(200, r#"{"data":{"search":"SECRETVALUE","zeta":1}}"#));
        assert!(d.contains("keys: data") && d.contains("data keys: search, zeta"), "{d}");
        assert!(!d.contains("SECRETVALUE"), "{d}");
        let (_, d) = code(parse(200, r#"{"data":[1]}"#));
        assert!(d.contains("keys: data") && !d.contains("data keys"), "{d}");
        let (_, d) = code(parse(200, "[1]"));
        assert!(d.contains("keys: none"), "{d}");
    }

    #[test]
    fn kagi_meta_is_returned_when_present() {
        let (hits, meta) = parse_kagi_full(200, br#"{"meta":{"id":"r1","ms":5},"data":{"search":[{"url":"https://a/"}]}}"#, 5).unwrap();
        assert_eq!(hits.len(), 1);
        assert_eq!(meta, Some(json!({"id": "r1", "ms": 5})));
        let (_, meta) = parse_kagi_full(200, br#"{"data":{}}"#, 5).unwrap();
        assert_eq!(meta, None);
        let w = WebState::new();
        w.set_timing("search", Instant::now(), Some(json!({"id": "r1"})), None);
        let t = w.take_timing().unwrap();
        assert!(t["search"].is_u64());
        assert_eq!(t["kagi_meta"], json!({"id": "r1"}));
        w.set_timing("fetch", Instant::now(), None, Some("dns: x".into()));
        let t = w.take_timing().unwrap();
        assert!(t.get("kagi_meta").is_none());
        assert_eq!(t["failure"], "dns: x");
    }

    #[test]
    fn html_in_titles_and_snippets_becomes_plain_text() {
        let s = "Instinct took Silicon Valley by storm. Meet the &#39;brilliant&#39; 23-year-old";
        assert_eq!(clean(&plain_fragment(s), false), "Instinct took Silicon Valley by storm. Meet the 'brilliant' 23-year-old");
        let s = "<strong>Long</strong>, <strong>Duncan</strong> \u{b7} View all 11 copies";
        assert_eq!(clean(&plain_fragment(s), false), "Long, Duncan \u{b7} View all 11 copies");
        assert_eq!(plain_fragment("a &quot;b&quot; &amp; c&#x21;  d\n<br>e"), "a \"b\" & c! d e");
        // decoded text is still made safe afterwards
        assert_eq!(clean(&plain_fragment("a &#123;&#x7B; b"), false), "a { { b");
        assert_eq!(clean(&plain_fragment("Site &mdash; Home"), true), "Site - Home");
        assert_eq!(clean(&plain_fragment("Site &#8212; Home"), true), "Site - Home");
    }

    #[test]
    fn stamps() {
        assert_eq!(fetched_stamp("2026-10-25T14:20:05-06:00"), "2026-10-25 14:20");
        assert_eq!(fetched_stamp("2026-10-25 09:05"), "2026-10-25 09:05");
        assert_eq!(fetched_stamp("noon"), "noon");
        assert_eq!(fetched_stamp("2026-10-25T\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}"), "2026-10-25T\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}\u{e9}");
    }

    #[test]
    fn untrusted_text_cannot_carry_markers_or_title_breaks() {
        assert_eq!(clean("a {{addr:x}} b\n c", false), "a { {addr:x}} b c");
        assert_eq!(clean("Site \u{2014} Home", true), "Site - Home");
        assert_eq!(clean("Site \u{2014} Home", false), "Site \u{2014} Home");
        assert_eq!(clean_url("https://a/b c{d}").unwrap(), "https://a/b%20c%7Bd%7D");
        assert!(clean_url("  ").is_none());
        assert!(clean_url("https://a/\nb").is_none());
    }

    #[test]
    fn availability_needs_provider_key_and_online() {
        let w = WebState::new();
        assert!(!w.available());
        w.configure_named(Some("kagi"), Some("k"), false).unwrap();
        assert!(!w.available());
        w.configure_named(Some("KAGI"), Some("k"), true).unwrap();
        assert!(w.available());
        w.configure_named(Some("kagi"), None, true).unwrap();
        assert!(!w.available());
        w.configure_named(Some("kagi"), Some(""), true).unwrap();
        assert!(!w.available());
        w.configure_named(None, Some("k"), true).unwrap();
        assert!(!w.available());
        assert_eq!(w.configure_named(Some("bing"), Some("k"), true).unwrap_err().code, crate::ErrorCode::BadJson);
    }

    /// A server that accepts one connection, sends `reply` (or nothing) and closes.
    fn one_shot_server(reply: &'static [u8]) -> String {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        std::thread::spawn(move || {
            if let Ok((mut s, _)) = l.accept() {
                use std::io::Write;
                let mut buf = [0u8; 2048];
                let _ = s.read(&mut buf);
                let _ = s.write_all(reply);
            }
        });
        addr.to_string()
    }

    fn soon() -> Instant {
        Instant::now() + Duration::from_secs(5)
    }

    #[test]
    fn the_web_client_uses_bundled_roots() {
        // the config kind the one client builder uses
        assert_eq!(tls_roots(), TlsRoots::Bundled);
        // and the dependency that selects it: ureq with its own rustls and webpki-roots, not reqwest's platform verifier
        let manifest = include_str!("../Cargo.toml");
        let dep = |name: &str| manifest.lines().find(|l| l.trim_start().starts_with(&format!("{name} =")));
        assert!(dep("reqwest").is_none(), "reqwest (rustls-platform-verifier) must not be a dependency of the web client");
        let ureq = dep("ureq").expect("ureq is the web client");
        assert!(ureq.contains("default-features = false") && ureq.contains("\"tls\""), "{ureq}");
        assert!(!manifest.contains("platform-verifier"));
    }

    #[test]
    fn a_tls_failure_names_the_tls_layer_and_hides_the_query() {
        // a server that answers a TLS hello with plain text: the handshake fails in rustls
        let addr = one_shot_server(b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
        let f = http_get(&format!("https://{addr}/search?q=secret-query-text"), &[], soon(), 1 << 16).unwrap_err();
        assert_eq!(f.kind, HttpFail::Connect, "{f:?}");
        assert!(f.cause.starts_with("tls: "), "{f:?}");
        assert!(f.cause.chars().count() <= CAUSE_CHARS + 3);
        assert!(!f.cause.contains("secret-query-text") && !f.chain.contains("secret-query-text"), "{f:?}");
    }

    #[test]
    fn a_refused_connection_names_the_connect_layer() {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        drop(l);
        let f = http_get(&format!("http://{addr}/p?x=1"), &[], soon(), 1 << 16).unwrap_err();
        assert_eq!(f.kind, HttpFail::Connect, "{f:?}");
        assert!(f.cause.starts_with("connect: "), "{f:?}");
    }

    #[test]
    fn a_dns_failure_names_the_dns_layer() {
        let f = http_get("http://no-such-host.invalid/p", &[], soon(), 1 << 16).unwrap_err();
        assert_eq!(f.kind, HttpFail::Connect, "{f:?}");
        assert!(f.cause.starts_with("dns: "), "{f:?}");
    }

    #[test]
    fn a_silent_server_is_a_timeout() {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        std::thread::spawn(move || {
            let _held = l.accept();
            std::thread::sleep(Duration::from_secs(3));
        });
        let f = http_get(&format!("http://{addr}/p"), &[], Instant::now() + Duration::from_millis(300), 1 << 16).unwrap_err();
        assert_eq!(f.kind, HttpFail::TimedOut, "{f:?}");
        assert_eq!(f.cause, "timeout");
    }

    #[test]
    fn an_http_error_status_is_an_answer_with_its_body() {
        let addr = one_shot_server(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 12\r\nConnection: close\r\n\r\n{\"e\":\"nope\"}");
        let r = http_get(&format!("http://{addr}/p"), &[], soon(), 1 << 16).unwrap();
        assert_eq!(r.status, 403);
        assert!(r.body.starts_with(b"{\"e\""));
    }

    #[test]
    fn scrub_url_takes_out_the_query() {
        assert_eq!(scrub_url("GET https://a/b?q=1&r=2 failed", "https://a/b?q=1&r=2"), "GET https://a/b failed");
        assert_eq!(scrub_url("bad q=1&r=2 here", "https://a/b?q=1&r=2"), "bad ... here");
        assert_eq!(scrub_url("nothing", "https://a/b"), "nothing");
    }

    #[test]
    fn scrub_removes_the_key() {
        let e = scrub(ToolError::new("x", "bad key SECRET123 here"), "SECRET123");
        assert_eq!(e.detail, "bad key *** here");
    }
}
