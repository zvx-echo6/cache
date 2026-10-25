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

use crate::conv::one_line;
use crate::error::{Error, Result};
use crate::html;
use cache_tool::{text_marker, Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Value};
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
}

/// Kagi's search API (v1): `POST` with a JSON body and `Authorization: Bearer <key>`. It matches the request AIDA uses in
/// production (Open WebUI kagi.py); live-verified: pending. Tested against a local stand-in server.
#[derive(Clone, Debug)]
pub struct KagiProvider {
    pub base_url: String,
}

impl Default for KagiProvider {
    fn default() -> Self {
        KagiProvider { base_url: KAGI_URL.to_string() }
    }
}

impl KagiProvider {
    /// Kagi at another address (tests point it at a local server).
    pub fn with_base_url(base_url: impl Into<String>) -> Self {
        KagiProvider { base_url: base_url.into() }
    }
}

impl WebSearchProvider for KagiProvider {
    fn search(&self, query: &str, limit: usize, key: &str, deadline: Instant) -> std::result::Result<Vec<WebHit>, ToolError> {
        let url = reqwest::Url::parse(&self.base_url)
            .map_err(|_| ToolError::new(ToolError::NOT_CONFIGURED, "the web search address is not valid"))?;
        let auth = format!("Bearer {key}");
        let body = json!({"query": query, "limit": limit}).to_string();
        let reply = http_request(
            url.as_str(),
            &[("Authorization", auth.as_str()), ("Accept", "application/json"), ("Content-Type", "application/json")],
            Some(body),
            deadline,
            API_CAP,
        )
        .map_err(|f| match f {
                HttpFail::TimedOut => ToolError::new(ToolError::FETCH_FAILED, "web search timed out"),
                HttpFail::Connect => ToolError::new(ToolError::FETCH_FAILED, "could not reach the web search server"),
                HttpFail::Other => ToolError::new(ToolError::FETCH_FAILED, "the web search request failed"),
            })?;
        parse_kagi(reply.status, &reply.body, limit)
    }
}

fn key_rejected() -> ToolError {
    ToolError::new(ToolError::KEY_MISSING, "web search key rejected")
}

fn quota_reached() -> ToolError {
    ToolError::new(ToolError::QUOTA, "web search limit reached")
}

/// Kagi's answer as hits or a tool error. The results are `data.search`, an array of objects with `url`, `title` and an
/// optional `snippet`; other fields and other `data` members are ignored. A failure is an `error` array or object (shape
/// unverified against the live API: a 401/403 code or status is a rejected key, a 402/429 code or a message about
/// balance, credit or quota is `quota`). A 200 with an `error`, or without `data.search`, is `bad_response`.
pub fn parse_kagi(status: u16, body: &[u8], limit: usize) -> std::result::Result<Vec<WebHit>, ToolError> {
    if status == 401 || status == 403 {
        return Err(key_rejected());
    }
    if status == 402 || status == 429 {
        return Err(quota_reached());
    }
    let parsed: Option<Value> = serde_json::from_slice(body).ok();
    let errors: Vec<&Value> = match parsed.as_ref().map(|v| &v["error"]) {
        Some(Value::Array(a)) => a.iter().collect(),
        Some(e @ Value::Object(_)) | Some(e @ Value::String(_)) => vec![e],
        _ => Vec::new(),
    };
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
        if ["balance", "quota", "credit"].iter().any(|w| msg.contains(w)) {
            return Err(quota_reached());
        }
    }
    if !(200..300).contains(&status) {
        return Err(ToolError::new(ToolError::FETCH_FAILED, format!("web search failed (HTTP {status})")));
    }
    if let Some(e) = errors.first() {
        let msg: String = msg_of(e).chars().take(120).collect();
        return Err(ToolError::new(ToolError::BAD_RESPONSE, format!("web search error: {}", one_line(&msg))));
    }
    let Some(v) = parsed else {
        return Err(ToolError::new(ToolError::BAD_RESPONSE, "web search answered with something unreadable"));
    };
    let Some(data) = v["data"]["search"].as_array() else {
        return Err(ToolError::new(ToolError::BAD_RESPONSE, "web search answered without a result list"));
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
    Ok(hits)
}

// ---- HTTP ------------------------------------------------------------------------------------------------

pub struct HttpReply {
    pub status: u16,
    pub content_type: Option<String>,
    pub body: Vec<u8>,
    /// True when the body was longer than the cap and the rest was dropped.
    pub capped: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub enum HttpFail {
    TimedOut,
    Connect,
    Other,
}

fn fail_of(e: &reqwest::Error) -> HttpFail {
    if e.is_timeout() {
        HttpFail::TimedOut
    } else if e.is_connect() {
        HttpFail::Connect
    } else {
        HttpFail::Other
    }
}

fn send_blocking(url: &str, headers: &[(String, String)], body: Option<String>, deadline: Instant, cap: usize) -> std::result::Result<HttpReply, HttpFail> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(HttpFail::TimedOut);
    }
    let client = reqwest::blocking::Client::builder()
        .timeout(remaining)
        .redirect(reqwest::redirect::Policy::limited(MAX_REDIRECTS))
        .user_agent(user_agent())
        .build()
        .map_err(|_| HttpFail::Other)?;
    let mut req = match body {
        Some(b) => client.post(url).body(b),
        None => client.get(url),
    };
    for (k, v) in headers {
        let mut value = reqwest::header::HeaderValue::from_str(v).map_err(|_| HttpFail::Other)?;
        if k.eq_ignore_ascii_case("authorization") {
            value.set_sensitive(true);
        }
        req = req.header(k.as_str(), value);
    }
    let mut resp = req.send().map_err(|e| fail_of(&e))?;
    let status = resp.status().as_u16();
    let content_type = resp.headers().get(reqwest::header::CONTENT_TYPE).and_then(|v| v.to_str().ok()).map(str::to_string);
    let mut body = Vec::new();
    if let Err(e) = (&mut resp).take(cap as u64 + 1).read_to_end(&mut body) {
        let timed_out = e.kind() == std::io::ErrorKind::TimedOut
            || Instant::now() >= deadline
            || e.get_ref().and_then(|s| s.downcast_ref::<reqwest::Error>()).is_some_and(|r| r.is_timeout());
        return Err(if timed_out { HttpFail::TimedOut } else { HttpFail::Other });
    }
    let capped = body.len() > cap;
    body.truncate(cap);
    Ok(HttpReply { status, content_type, body, capped })
}

/// GET `url` and read at most `cap` bytes of the body, finishing by `deadline`. Follows up to 5 redirects. The work
/// runs on its own thread; if it has not answered by the deadline the call returns `TimedOut` and the thread ends by
/// itself when its own request times out.
pub fn http_get(url: &str, headers: &[(&str, &str)], deadline: Instant, cap: usize) -> std::result::Result<HttpReply, HttpFail> {
    http_request(url, headers, None, deadline, cap)
}

/// `http_get`, or a POST with `body` when one is given (no redirects are followed differently; same limits).
pub fn http_request(url: &str, headers: &[(&str, &str)], body: Option<String>, deadline: Instant, cap: usize) -> std::result::Result<HttpReply, HttpFail> {
    let remaining = deadline.saturating_duration_since(Instant::now());
    if remaining.is_zero() {
        return Err(HttpFail::TimedOut);
    }
    let url = url.to_string();
    let headers: Vec<(String, String)> = headers.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect();
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let _ = tx.send(send_blocking(&url, &headers, body, deadline, cap));
    });
    match rx.recv_timeout(remaining) {
        Ok(r) => r,
        Err(mpsc::RecvTimeoutError::Timeout) => Err(HttpFail::TimedOut),
        Err(mpsc::RecvTimeoutError::Disconnected) => Err(HttpFail::Other),
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
    let lower = url.to_ascii_lowercase();
    if !(lower.starts_with("http://") || lower.starts_with("https://")) {
        return Page::Unavailable;
    }
    let reply = match http_get(url, &[("Accept", "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.1")], deadline, cap) {
        Ok(r) => r,
        Err(HttpFail::TimedOut) => return Page::TimedOut,
        Err(_) => return Page::Unavailable,
    };
    if !(200..300).contains(&reply.status) {
        return Page::Unavailable;
    }
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

    /// Debug timing of the last web call: `{"search": ms}` or `{"fetch": ms}`. Never shown to the model.
    pub fn take_timing(&self) -> Option<Value> {
        lock(&self.timing).take()
    }

    fn set_timing(&self, what: &str, since: Instant) {
        *lock(&self.timing) = Some(json!({ what: since.elapsed().as_millis() as u64 }));
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
        let page = fetch_page(url, t0 + budget, cap);
        self.set_timing("fetch", t0);
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
        self.0.set_timing("search", t0);
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
            let mut title = html::snippet_from_text(&clean(&h.title, true), TITLE_CHARS);
            if title.is_empty() {
                title = clean(&url, true);
            }
            let snippet = html::snippet_from_text(&clean(&h.snippet, false), snippet_chars);
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
    fn unreadable_answers_are_bad_response() {
        assert_eq!(code(parse(200, "<html>")).0, "bad_response");
        assert_eq!(code(parse(200, "")).0, "bad_response");
        assert_eq!(code(parse(200, r#"{"meta":{}}"#)).0, "bad_response");
        assert_eq!(code(parse(200, r#"{"data":"x"}"#)).0, "bad_response");
        assert_eq!(code(parse(200, r#"{"data":[]}"#)).0, "bad_response");
        assert_eq!(code(parse(200, r#"{"data":{"search":"x"}}"#)).0, "bad_response");
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

    #[test]
    fn scrub_removes_the_key() {
        let e = scrub(ToolError::new("x", "bad key SECRET123 here"), "SECRET123");
        assert_eq!(e.detail, "bad key *** here");
    }
}
