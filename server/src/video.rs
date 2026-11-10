//! Videos in the browser: the routes under `/api/video/` (sign-in is the session cookie, checked before this runs).
//!
//!   GET|HEAD /api/video/media/<path under the videos folder>  a saved video or sound, its captions and its picture, with Range
//!   GET|HEAD /api/video/zim/<zim id>/<entry path>             a video or caption entry of a ZIM, with Range
//!   GET      /api/video/stream?u=<address>                    a stream, caption file or picture of a video site, with Range
//!
//! A `<video>` element of the same origin sends the session cookie by itself, so these need no token (the `/zim/` route has one only
//! because its frame has no origin). The saved videos are the core's own files in `<docs>/videos` (the phone's folder under the files
//! root), which is where a video that arrives by sync lands too.
//!
//! * `media`: every segment of the path is checked (no `..`, no empty or hidden names, no `\`), and the real file, symlinks resolved,
//!   must be inside the videos folder. The type comes from the extension.
//! * `zim`: the entry is read through the helper (`zimGet`), whole; the last one read is kept in memory so seeking does not read it
//!   again, and Range is answered from it.
//! * `stream`: a browser may not read a video site, and a `<video>` cannot send a login header, so the server reads it. Only `http` and
//!   `https`, and only to hosts whose every address is public (the client resolves through a filter, so a redirect or a DNS answer cannot
//!   reach this machine or the home network). At most four redirects; `Range` is passed on. What comes back is sent as a media or text
//!   type only (anything else as `application/octet-stream`), always with `Content-Security-Policy: sandbox`, so a page cannot run here.
//!   An HLS playlist is rewritten so each of its parts comes back through this route, keeping a private video's `videoFileToken`.

use crate::helper::Helper;
use crate::http::Reply;
use hyper::body::Bytes;
use serde_json::json;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;
use tokio::sync::mpsc;

/// A piece of a body sent to the client.
const CHUNK: usize = 256 * 1024;
/// The largest HLS playlist rewritten.
const MAX_PLAYLIST: u64 = 4 << 20;
const USER_AGENT: &str = concat!("Cache/", env!("CARGO_PKG_VERSION"));

/// `GET|HEAD /api/video/...`; the caller has checked the session. [range] is the request's `Range` header.
pub async fn serve(helper: Option<Arc<Helper>>, method: &str, path: &str, query: &str, range: Option<&str>) -> Reply {
    if method != "GET" && method != "HEAD" {
        return Reply::empty(405);
    }
    let head = method == "HEAD";
    let rest = &path["/api/video/".len()..];
    if let Some(rel) = rest.strip_prefix("media/") {
        let Some(root) = videos_root(helper.as_ref()).await else { return Reply::error(503, "core_unavailable", "the core is not available") };
        let rel = rel.to_string();
        let range = range.map(str::to_string);
        return match tokio::task::spawn_blocking(move || media_reply(&root, &rel, range.as_deref(), head)).await {
            Ok(r) => r,
            Err(_) => Reply::empty(500),
        };
    }
    if let Some(entry) = rest.strip_prefix("zim/") {
        return zim_reply(helper, entry, range, head).await;
    }
    if rest == "stream" {
        let Some(url) = crate::fetch::query_param(query, "u") else { return Reply::error(400, "bad_request", "u (an address) is required") };
        return stream_reply(url, range.map(str::to_string), head).await;
    }
    Reply::error(404, "not_found", format!("no such endpoint: GET {path}"))
}

// ---- the videos folder

static ROOT: Mutex<Option<PathBuf>> = Mutex::new(None);

/// `<docs>/videos`, from the helper's `fs.roots` (asked once; the docs folder does not move while the server runs).
async fn videos_root(helper: Option<&Arc<Helper>>) -> Option<PathBuf> {
    if let Some(p) = cached_root() {
        return Some(p);
    }
    let reply = helper?.call("fs.roots", json!({})).await.ok()?;
    let docs = reply["result"]["docs"].as_str()?;
    let p = Path::new(docs).join("videos");
    set_root(p.clone());
    Some(p)
}

fn cached_root() -> Option<PathBuf> {
    ROOT.lock().unwrap().clone()
}

fn set_root(p: PathBuf) {
    *ROOT.lock().unwrap() = Some(p);
}

/// The path of `rel` inside `root`, or None when a segment is not a plain name or the real file is outside `root`.
pub fn safe_path(root: &Path, rel: &str) -> Option<PathBuf> {
    let decoded = percent_decode_path(rel)?;
    if decoded.is_empty() || decoded.len() > 1024 {
        return None;
    }
    let mut p = root.to_path_buf();
    for seg in decoded.split('/') {
        if seg.is_empty() || seg.starts_with('.') || seg.contains('\\') || seg.contains('\0') {
            return None;
        }
        p.push(seg);
    }
    let real = p.canonicalize().ok()?;
    let real_root = root.canonicalize().ok()?;
    (real.starts_with(&real_root) && real.is_file()).then_some(real)
}

/// `%XX` decoded (a `+` stays a plus: this is a path); None for a bad escape or text that is not UTF-8.
pub fn percent_decode_path(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            out.push(u8::from_str_radix(s.get(i + 1..i + 3)?, 16).ok()?);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// The type to send a file or entry of this name as.
pub fn type_of(name: &str) -> &'static str {
    let ext = name.rsplit_once('.').map(|(_, e)| e.to_ascii_lowercase()).unwrap_or_default();
    match ext.as_str() {
        "mp4" | "m4v" => "video/mp4",
        "webm" => "video/webm",
        "ogv" => "video/ogg",
        "mov" => "video/quicktime",
        "mkv" => "video/x-matroska",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "oga" | "ogg" | "opus" => "audio/ogg",
        "wav" => "audio/wav",
        "vtt" => "text/vtt; charset=utf-8",
        "srt" => "text/plain; charset=utf-8",
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "webp" => "image/webp",
        "gif" => "image/gif",
        _ => "application/octet-stream",
    }
}

// ---- Range

#[derive(Debug, PartialEq)]
pub enum Span {
    /// No (usable) Range: the whole body.
    Whole,
    /// First and last byte, both included.
    Part(u64, u64),
    /// Nothing of the body is in the range (416).
    Unsatisfiable,
}

/// A `Range: bytes=a-b` header against a body of `len` bytes. Only the first range of a list is taken; anything that is not a byte
/// range is ignored (the whole body, as RFC 9110 allows).
pub fn parse_range(header: Option<&str>, len: u64) -> Span {
    let Some(spec) = header.and_then(|h| h.trim().strip_prefix("bytes=")) else { return Span::Whole };
    let first = spec.split(',').next().unwrap_or("").trim();
    let Some((a, b)) = first.split_once('-') else { return Span::Whole };
    let (a, b) = (a.trim(), b.trim());
    if a.is_empty() {
        // the last n bytes
        let Ok(n) = b.parse::<u64>() else { return Span::Whole };
        if n == 0 || len == 0 {
            return Span::Unsatisfiable;
        }
        return Span::Part(len.saturating_sub(n), len - 1);
    }
    let Ok(start) = a.parse::<u64>() else { return Span::Whole };
    if start >= len {
        return Span::Unsatisfiable;
    }
    let end = if b.is_empty() {
        len - 1
    } else {
        match b.parse::<u64>() {
            Ok(e) if e >= start => e.min(len - 1),
            _ => return Span::Whole,
        }
    };
    Span::Part(start, end)
}

fn base_headers(content_type: &str) -> Vec<(&'static str, String)> {
    vec![
        ("Content-Type", content_type.to_string()),
        ("Accept-Ranges", "bytes".to_string()),
        // The files are somebody else's content: a page among them cannot run here.
        ("Content-Security-Policy", "sandbox".to_string()),
        ("Referrer-Policy", "no-referrer".to_string()),
    ]
}

/// Status, headers, first byte and byte count of an answer.
type SpanHead = (u16, Vec<(&'static str, String)>, u64, u64);

/// The status and headers of an answer for [span] over a body of `len` bytes; the 416 reply for a range nothing of the body is in.
fn span_head(content_type: &str, len: u64, span: &Span) -> Result<SpanHead, Reply> {
    let mut h = base_headers(content_type);
    match span {
        Span::Whole => {
            h.push(("Content-Length", len.to_string()));
            Ok((200, h, 0, len))
        }
        Span::Part(a, b) => {
            h.push(("Content-Length", (b - a + 1).to_string()));
            h.push(("Content-Range", format!("bytes {a}-{b}/{len}")));
            Ok((206, h, *a, b - a + 1))
        }
        Span::Unsatisfiable => {
            let mut r = Reply::empty(416);
            r.headers.push(("Content-Range", format!("bytes */{len}")));
            Err(r)
        }
    }
}

/// A body from `bytes`, which is cut into pieces and sent as the client takes them.
fn bytes_reply(bytes: Arc<Vec<u8>>, content_type: &str, range: Option<&str>, head: bool) -> Reply {
    let len = bytes.len() as u64;
    let (status, headers, from, count) = match span_head(content_type, len, &parse_range(range, len)) {
        Ok(x) => x,
        Err(r) => return r,
    };
    if head || count == 0 {
        return Reply { status, headers, body: vec![], stream: None };
    }
    let (tx, rx) = mpsc::channel::<std::io::Result<Bytes>>(4);
    tokio::spawn(async move {
        let (mut at, end) = (from as usize, (from + count) as usize);
        while at < end {
            let next = (at + CHUNK).min(end);
            if tx.send(Ok(Bytes::copy_from_slice(&bytes[at..next]))).await.is_err() {
                return;
            }
            at = next;
        }
    });
    Reply { status, headers, body: vec![], stream: Some(rx) }
}

// ---- saved files

/// The file `rel` of the videos folder, whole or as the range says.
pub fn media_reply(root: &Path, rel: &str, range: Option<&str>, head: bool) -> Reply {
    let Some(file) = safe_path(root, rel) else { return Reply::empty(404) };
    let Ok(mut f) = std::fs::File::open(&file) else { return Reply::empty(404) };
    let Ok(len) = f.metadata().map(|m| m.len()) else { return Reply::empty(500) };
    let name = file.file_name().and_then(|n| n.to_str()).unwrap_or("");
    let (status, headers, from, count) = match span_head(type_of(name), len, &parse_range(range, len)) {
        Ok(x) => x,
        Err(r) => return r,
    };
    if head || count == 0 {
        return Reply { status, headers, body: vec![], stream: None };
    }
    if f.seek(SeekFrom::Start(from)).is_err() {
        return Reply::empty(500);
    }
    let (tx, rx) = mpsc::channel::<std::io::Result<Bytes>>(4);
    tokio::task::spawn_blocking(move || pump(f.take(count), tx));
    Reply { status, headers, body: vec![], stream: Some(rx) }
}

/// Reads [r] to its end into [tx], a piece at a time; ends when the client has gone.
fn pump(mut r: impl Read, tx: mpsc::Sender<std::io::Result<Bytes>>) {
    let mut buf = vec![0u8; CHUNK];
    loop {
        match r.read(&mut buf) {
            Ok(0) => return,
            Ok(n) => {
                if tx.blocking_send(Ok(Bytes::copy_from_slice(&buf[..n]))).is_err() {
                    return;
                }
            }
            Err(e) => {
                let _ = tx.blocking_send(Err(e));
                return;
            }
        }
    }
}

// ---- ZIM entries

type ZimEntry = (String, Arc<Vec<u8>>, String);
static ZIM_LAST: Mutex<Option<ZimEntry>> = Mutex::new(None);

fn cached_entry(address: &str) -> Option<(Arc<Vec<u8>>, String)> {
    ZIM_LAST.lock().unwrap().as_ref().filter(|(a, _, _)| a == address).map(|(_, b, m)| (b.clone(), m.clone()))
}

fn keep_entry(address: String, bytes: Arc<Vec<u8>>, mime: String) {
    *ZIM_LAST.lock().unwrap() = Some((address, bytes, mime));
}

async fn zim_reply(helper: Option<Arc<Helper>>, entry: &str, range: Option<&str>, head: bool) -> Reply {
    let Some((id, name)) = entry.split_once('/') else { return Reply::empty(404) };
    let id_ok = id.len() == 36 && id.bytes().all(|b| b.is_ascii_hexdigit() || b == b'-');
    if !id_ok || name.is_empty() || name.len() > 2048 {
        return Reply::empty(404);
    }
    let Some(helper) = helper else { return Reply::error(503, "core_unavailable", "the core is not available") };
    let id = id.to_ascii_lowercase();
    // The browser sends the entry's name percent-encoded; the core knows it as written. Both are tried.
    let mut names = vec![name.to_string()];
    if let Some(d) = percent_decode_path(name).filter(|d| d != name) {
        names.insert(0, d);
    }
    for n in &names {
        let address = format!("zim:{id}/{n}");
        if let Some((bytes, mime)) = cached_entry(&address) {
            return bytes_reply(bytes, &entry_type(&mime, n), range, head);
        }
    }
    for n in &names {
        let address = format!("zim:{id}/{n}");
        let reply = match helper.call("zimGet", json!({"address": address})).await {
            Ok(r) => r,
            Err(_) => return Reply::empty(503),
        };
        if reply["ok"] != json!(true) {
            if reply["error"]["code"] == json!("not_found") {
                continue;
            }
            return Reply::empty(502);
        }
        use base64::Engine;
        let result = &reply["result"];
        let bytes = result[0]["$bytes"].as_str().and_then(|b| base64::engine::general_purpose::STANDARD.decode(b).ok());
        let (Some(bytes), Some(mime)) = (bytes, result[1].as_str()) else { return Reply::empty(502) };
        let bytes = Arc::new(bytes);
        let r = bytes_reply(bytes.clone(), &entry_type(mime, n), range, head);
        keep_entry(address, bytes, mime.to_string());
        return r;
    }
    Reply::empty(404)
}

/// The ZIM's own type when it is a media, caption or picture type; else by the entry's name (many ZIMs say octet-stream).
fn entry_type(mime: &str, name: &str) -> String {
    let essence = mime.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    if essence.starts_with("video/") || essence.starts_with("audio/") || essence.starts_with("image/") || essence == "text/vtt" {
        return essence;
    }
    let by_name = type_of(name);
    if by_name != "application/octet-stream" {
        return by_name.to_string();
    }
    "application/octet-stream".to_string()
}

// ---- the stream proxy

struct Upstream {
    status: u16,
    headers: Vec<(&'static str, String)>,
    content_type: String,
    final_url: String,
    reader: Box<dyn Read + Send + Sync>,
}

fn open_upstream(url: &str, range: Option<&str>) -> Result<Upstream, u16> {
    crate::fetch::parse_url(url).ok_or(400u16)?;
    // The shared public-address guard, checked at connect time on the request and on every redirect hop.
    let agent = cache_netguard::always(ureq::AgentBuilder::new())
        .redirects(4)
        .timeout_connect(Duration::from_secs(15))
        .timeout_read(Duration::from_secs(30))
        .user_agent(USER_AGENT)
        .build();
    let mut req = agent.get(url);
    if let Some(r) = range.filter(|r| r.len() < 100 && r.bytes().all(|b| b.is_ascii_alphanumeric() || b"=-, ".contains(&b))) {
        req = req.set("Range", r);
    }
    let resp = match req.call() {
        Ok(r) => r,
        Err(ureq::Error::Status(_, r)) => r,
        Err(_) => return Err(502),
    };
    let status = resp.status();
    if !(200..300).contains(&status) {
        // an error of the site is passed on; a redirect that was not followed to the end is a bad answer
        return Err(if status >= 400 { status.min(599) } else { 502 });
    }
    let content_type = resp.header("content-type").unwrap_or("").to_string();
    let mut headers = Vec::new();
    for (name, key) in [("content-length", "Content-Length"), ("content-range", "Content-Range"), ("accept-ranges", "Accept-Ranges")] {
        if let Some(v) = resp.header(name) {
            headers.push((key, v.to_string()));
        }
    }
    let final_url = resp.get_url().to_string();
    Ok(Upstream { status, headers, content_type, final_url, reader: resp.into_reader() })
}

/// The type to send a proxied answer as: media, caption, picture and playlist types as they are, text as plain text, the rest as bytes.
pub fn safe_type(upstream: &str, url: &str) -> String {
    let essence = upstream.split(';').next().unwrap_or("").trim().to_ascii_lowercase();
    let ok = essence.starts_with("video/")
        || essence.starts_with("audio/")
        || essence.starts_with("image/") && essence != "image/svg+xml"
        || matches!(essence.as_str(), "application/vnd.apple.mpegurl" | "application/x-mpegurl" | "audio/mpegurl" | "text/vtt");
    if ok {
        return essence;
    }
    let path = url.split(['?', '#']).next().unwrap_or("");
    let by_name = type_of(path.rsplit('/').next().unwrap_or(""));
    if by_name != "application/octet-stream" {
        return by_name.to_string();
    }
    if essence == "text/plain" || essence == "text/srt" || essence == "application/x-subrip" {
        return "text/plain; charset=utf-8".to_string();
    }
    "application/octet-stream".to_string()
}

fn is_playlist(content_type: &str, url: &str) -> bool {
    let c = content_type.to_ascii_lowercase();
    c.contains("mpegurl") || url.split(['?', '#']).next().is_some_and(|p| p.to_ascii_lowercase().ends_with(".m3u8"))
}

/// `%XX` for everything but unreserved characters.
pub fn pct_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3 / 2);
    for b in s.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

fn proxied(url: &str) -> String {
    format!("/api/video/stream?u={}", pct_encode(url))
}

/// The value of `videoFileToken` in [url]'s query.
fn file_token(url: &str) -> Option<String> {
    let q = url.split_once('?')?.1.split('#').next()?;
    crate::fetch::query_param(q, "videoFileToken")
}

/// `scheme://host[:port]` of an address.
fn authority(url: &str) -> &str {
    let after = url.find("://").map_or(0, |i| i + 3);
    &url[..url[after..].find(['/', '?', '#']).map_or(url.len(), |i| i + after)]
}

/// [target] (as the playlist writes it, resolved against [base]) as a proxy address, carrying [base]'s file token when [target] has none.
fn rewrite_target(base: &str, target: &str, token: Option<&str>) -> Option<String> {
    let mut abs = crate::fetch::resolve(base, target)?;
    if let Some(t) = token {
        // the token is for the site it came with, not for a host a playlist points to
        if file_token(&abs).is_none() && authority(&abs) == authority(base) {
            abs.push(if abs.contains('?') { '&' } else { '?' });
            abs.push_str(&format!("videoFileToken={}", pct_encode(t)));
        }
    }
    Some(proxied(&abs))
}

/// An HLS playlist whose every address (parts, sub-playlists, keys, maps) comes back through the proxy.
pub fn rewrite_playlist(base: &str, text: &str) -> String {
    let token = file_token(base);
    let mut out = String::with_capacity(text.len() * 2);
    for line in text.lines() {
        let t = line.trim_end();
        if t.is_empty() {
            out.push('\n');
        } else if let Some(tag) = t.strip_prefix('#') {
            // URI="..." attributes of tags (#EXT-X-KEY, #EXT-X-MAP, #EXT-X-MEDIA)
            let mut rest = tag;
            out.push('#');
            while let Some(i) = rest.find("URI=\"") {
                let (head, tail) = rest.split_at(i + 5);
                out.push_str(head);
                match tail.split_once('"') {
                    Some((uri, after)) => {
                        out.push_str(&rewrite_target(base, uri, token.as_deref()).unwrap_or_else(|| uri.to_string()));
                        out.push('"');
                        rest = after;
                    }
                    None => {
                        out.push_str(tail);
                        rest = "";
                    }
                }
            }
            out.push_str(rest);
            out.push('\n');
        } else {
            out.push_str(&rewrite_target(base, t.trim(), token.as_deref()).unwrap_or_default());
            out.push('\n');
        }
    }
    out
}

async fn stream_reply(url: String, range: Option<String>, head: bool) -> Reply {
    let opened = tokio::task::spawn_blocking(move || {
        let u = open_upstream(&url, range.as_deref())?;
        Ok::<_, u16>((u, url))
    })
    .await;
    let (up, asked) = match opened {
        Ok(Ok(x)) => x,
        Ok(Err(code)) => return Reply::empty(code),
        Err(_) => return Reply::empty(500),
    };
    let ctype = safe_type(&up.content_type, &up.final_url);
    let mut headers = base_headers(&ctype);
    headers.retain(|(k, _)| *k != "Accept-Ranges");
    if is_playlist(&up.content_type, &asked) || is_playlist(&up.content_type, &up.final_url) {
        let (final_url, mut reader) = (up.final_url.clone(), up.reader);
        let text = tokio::task::spawn_blocking(move || {
            let mut buf = Vec::new();
            reader.by_ref().take(MAX_PLAYLIST + 1).read_to_end(&mut buf).map(|_| buf)
        })
        .await;
        let Ok(Ok(buf)) = text else { return Reply::empty(502) };
        if buf.len() as u64 > MAX_PLAYLIST {
            return Reply::empty(502);
        }
        let body = rewrite_playlist(&final_url, &String::from_utf8_lossy(&buf)).into_bytes();
        headers[0].1 = "application/vnd.apple.mpegurl".to_string();
        headers.push(("Content-Length", body.len().to_string()));
        return Reply { status: 200, headers, body: if head { vec![] } else { body }, stream: None };
    }
    headers.extend(up.headers);
    if head {
        return Reply { status: up.status, headers, body: vec![], stream: None };
    }
    let (tx, rx) = mpsc::channel::<std::io::Result<Bytes>>(4);
    let reader = up.reader;
    tokio::task::spawn_blocking(move || pump(reader, tx));
    Reply { status: up.status, headers, body: vec![], stream: Some(rx) }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;
    use std::io::Write;

    async fn collect(mut r: Reply) -> Vec<u8> {
        let mut out = std::mem::take(&mut r.body);
        if let Some(mut rx) = r.stream.take() {
            while let Some(c) = rx.recv().await {
                out.extend_from_slice(&c.unwrap());
            }
        }
        out
    }

    fn header<'a>(r: &'a Reply, k: &str) -> Option<&'a str> {
        r.headers.iter().find(|(n, _)| n.eq_ignore_ascii_case(k)).map(|(_, v)| v.as_str())
    }

    #[test]
    fn ranges_follow_rfc_9110() {
        assert_eq!(parse_range(None, 100), Span::Whole);
        assert_eq!(parse_range(Some("bytes=0-9"), 100), Span::Part(0, 9));
        assert_eq!(parse_range(Some("bytes=10-"), 100), Span::Part(10, 99));
        assert_eq!(parse_range(Some("bytes=-10"), 100), Span::Part(90, 99));
        assert_eq!(parse_range(Some("bytes=-500"), 100), Span::Part(0, 99));
        assert_eq!(parse_range(Some("bytes=90-500"), 100), Span::Part(90, 99));
        assert_eq!(parse_range(Some("bytes=0-9, 20-29"), 100), Span::Part(0, 9));
        assert_eq!(parse_range(Some("bytes=100-"), 100), Span::Unsatisfiable);
        assert_eq!(parse_range(Some("bytes=0-"), 0), Span::Unsatisfiable);
        assert_eq!(parse_range(Some("bytes=5-2"), 100), Span::Whole);
        assert_eq!(parse_range(Some("items=0-9"), 100), Span::Whole);
        assert_eq!(parse_range(Some("bytes=x-y"), 100), Span::Whole);
    }

    #[test]
    fn only_plain_names_inside_the_folder_are_served() {
        let d = TempDir::new("video-safe");
        let root = d.0.join("videos");
        std::fs::create_dir_all(root.join("tube.example.org/abc")).unwrap();
        std::fs::write(root.join("tube.example.org/abc/video.mp4"), b"x").unwrap();
        std::fs::write(root.join("tube.example.org/abc/a b.vtt"), b"x").unwrap();
        std::fs::write(d.0.join("secret.txt"), b"s").unwrap();
        std::fs::write(root.join(".hidden"), b"h").unwrap();
        assert!(safe_path(&root, "tube.example.org/abc/video.mp4").is_some());
        assert!(safe_path(&root, "tube.example.org/abc/a%20b.vtt").is_some());
        for bad in ["", "..", "../secret.txt", "tube.example.org/../../secret.txt", "tube.example.org/%2e%2e/%2e%2e/secret.txt", ".hidden", "tube.example.org//abc/video.mp4",
            "tube.example.org/abc", "tube.example.org/abc/missing.mp4", "tube.example.org\\abc\\video.mp4", "%zz", "a%00b"] {
            assert!(safe_path(&root, bad).is_none(), "{bad:?}");
        }
        #[cfg(unix)]
        {
            std::os::unix::fs::symlink(d.0.join("secret.txt"), root.join("tube.example.org/abc/link.mp4")).unwrap();
            assert!(safe_path(&root, "tube.example.org/abc/link.mp4").is_none(), "a link out of the folder");
        }
    }

    #[tokio::test]
    async fn a_saved_file_is_sent_whole_or_by_range_with_the_right_headers() {
        let d = TempDir::new("video-media");
        let root = d.0.join("videos");
        std::fs::create_dir_all(root.join("i/u")).unwrap();
        let data: Vec<u8> = (0..=255u8).cycle().take(700_000).collect();
        std::fs::File::create(root.join("i/u/video.mp4")).unwrap().write_all(&data).unwrap();
        let r = media_reply(&root, "i/u/video.mp4", None, false);
        assert_eq!((r.status, header(&r, "Content-Type"), header(&r, "Accept-Ranges"), header(&r, "Content-Length")), (200, Some("video/mp4"), Some("bytes"), Some("700000")));
        assert_eq!(header(&r, "Content-Security-Policy"), Some("sandbox"));
        assert_eq!(collect(r).await, data);
        let r = media_reply(&root, "i/u/video.mp4", Some("bytes=300000-"), false);
        assert_eq!((r.status, header(&r, "Content-Range")), (206, Some("bytes 300000-699999/700000")));
        assert_eq!(collect(r).await, data[300_000..]);
        let r = media_reply(&root, "i/u/video.mp4", Some("bytes=5-9"), false);
        assert_eq!(header(&r, "Content-Length"), Some("5"));
        assert_eq!(collect(r).await, data[5..10]);
        let r = media_reply(&root, "i/u/video.mp4", Some("bytes=700000-"), false);
        assert_eq!((r.status, header(&r, "Content-Range")), (416, Some("bytes */700000")));
        let r = media_reply(&root, "i/u/video.mp4", None, true);
        assert_eq!((r.status, header(&r, "Content-Length")), (200, Some("700000")));
        assert_eq!(collect(r).await.len(), 0);
        assert_eq!(media_reply(&root, "i/u/none.mp4", None, false).status, 404);
        assert_eq!(media_reply(&root, "../x", None, false).status, 404);
    }

    #[tokio::test]
    async fn a_held_entry_is_cut_by_range() {
        let bytes = Arc::new((0..100u8).collect::<Vec<u8>>());
        let r = bytes_reply(bytes.clone(), "video/webm", Some("bytes=10-19"), false);
        assert_eq!((r.status, header(&r, "Content-Range")), (206, Some("bytes 10-19/100")));
        assert_eq!(collect(r).await, (10..20u8).collect::<Vec<u8>>());
        assert_eq!(collect(bytes_reply(bytes, "video/webm", None, false)).await.len(), 100);
    }

    #[test]
    fn addresses_that_are_not_public_are_refused() {
        for ip in ["127.0.0.1", "10.1.2.3", "192.168.1.240", "172.16.0.1", "169.254.1.1", "100.64.0.14", "0.0.0.0", "224.0.0.1", "198.18.0.1", "::1", "fd00::1", "fe80::1", "::ffff:127.0.0.1", "::ffff:192.168.1.1", "::", "::127.0.0.1", "64:ff9b::7f00:1", "2002:7f00:1::1", "fec0::1"] {
            assert!(!cache_netguard::is_public(ip.parse().unwrap()), "{ip}");
        }
        for ip in ["5.189.158.149", "8.8.8.8", "2606:4700:4700::1111", "::ffff:8.8.8.8"] {
            assert!(cache_netguard::is_public(ip.parse().unwrap()), "{ip}");
        }
    }

    #[test]
    fn what_comes_back_from_a_video_site_is_never_a_page() {
        assert_eq!(safe_type("video/mp4", "https://a/x"), "video/mp4");
        assert_eq!(safe_type("text/html; charset=utf-8", "https://a/x"), "application/octet-stream");
        assert_eq!(safe_type("text/html", "https://a/x.vtt"), "text/vtt; charset=utf-8");
        assert_eq!(safe_type("image/svg+xml", "https://a/x.svg"), "application/octet-stream");
        assert_eq!(safe_type("image/jpeg", "https://a/p"), "image/jpeg");
        assert_eq!(safe_type("text/plain", "https://a/x"), "text/plain; charset=utf-8");
        assert_eq!(safe_type("application/octet-stream", "https://a/v.mp4?x=1"), "video/mp4");
    }

    #[test]
    fn a_playlist_comes_back_through_the_proxy_keeping_the_file_token() {
        let base = "https://tube.example.org/static/streaming-playlists/hls/u/master.m3u8?videoFileToken=TOK";
        let text = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\n720p.m3u8\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXTINF:4,\n/seg/0.ts?x=1\nhttps://cdn.example.net/1.ts\n";
        let out = rewrite_playlist(base, text);
        let lines: Vec<&str> = out.lines().collect();
        assert_eq!(lines[0], "#EXTM3U");
        assert_eq!(lines[1], "#EXT-X-STREAM-INF:BANDWIDTH=1");
        assert_eq!(lines[2], "/api/video/stream?u=https%3A%2F%2Ftube.example.org%2Fstatic%2Fstreaming-playlists%2Fhls%2Fu%2F720p.m3u8%3FvideoFileToken%3DTOK");
        assert_eq!(lines[3], "#EXT-X-KEY:METHOD=AES-128,URI=\"/api/video/stream?u=https%3A%2F%2Ftube.example.org%2Fstatic%2Fstreaming-playlists%2Fhls%2Fu%2Fkey.bin%3FvideoFileToken%3DTOK\"");
        assert_eq!(lines[5], "/api/video/stream?u=https%3A%2F%2Ftube.example.org%2Fseg%2F0.ts%3Fx%3D1%26videoFileToken%3DTOK");
        assert_eq!(lines[6], "/api/video/stream?u=https%3A%2F%2Fcdn.example.net%2F1.ts", "the token goes to the site it came with only");
        // no token: addresses are only resolved
        let out = rewrite_playlist("https://a.example/x/m.m3u8", "#EXTM3U\ns.ts\n");
        assert_eq!(out.lines().nth(1), Some("/api/video/stream?u=https%3A%2F%2Fa.example%2Fx%2Fs.ts"));
    }

    /// A one-request server on 127.0.0.1 that answers with `status_line`, `headers` and `body`, and gives back the request it got.
    fn serve_once(response: Vec<u8>) -> (String, std::thread::JoinHandle<String>) {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let t = std::thread::spawn(move || {
            let (mut s, _) = l.accept().unwrap();
            let mut got = Vec::new();
            let mut b = [0u8; 1024];
            while !got.windows(4).any(|w| w == b"\r\n\r\n") {
                let n = s.read(&mut b).unwrap();
                if n == 0 {
                    break;
                }
                got.extend_from_slice(&b[..n]);
            }
            s.write_all(&response).unwrap();
            String::from_utf8_lossy(&got).to_string()
        });
        (format!("http://127.0.0.1:{port}/v.mp4"), t)
    }

    #[tokio::test]
    async fn the_proxy_passes_range_and_headers_through_and_sandboxes_the_answer() {
        let body = b"0123456789";
        let mut resp = b"HTTP/1.1 206 Partial Content\r\nContent-Type: text/html\r\nContent-Range: bytes 0-9/100\r\nContent-Length: 10\r\nConnection: close\r\n\r\n".to_vec();
        resp.extend_from_slice(body);
        let (url, t) = serve_once(resp);
        allow_origin(&url);
        let r = stream_reply(url, Some("bytes=0-9".into()), false).await;
        assert_eq!(r.status, 206);
        assert_eq!(header(&r, "Content-Type"), Some("video/mp4"), "by the address's name, never the page type");
        assert_eq!(header(&r, "Content-Range"), Some("bytes 0-9/100"));
        assert_eq!(header(&r, "Content-Security-Policy"), Some("sandbox"));
        assert_eq!(collect(r).await, body);
        assert!(t.join().unwrap().to_ascii_lowercase().contains("range: bytes=0-9"));
    }

    #[tokio::test]
    async fn the_proxy_will_not_reach_this_machine_or_odd_addresses() {
        // 127.0.0.1 is not public: refused before any connection (502 from the resolver)
        assert_eq!(stream_reply("http://127.0.0.1:9/v.mp4".into(), None, false).await.status, 502);
        assert_eq!(stream_reply("http://localhost:9/v.mp4".into(), None, false).await.status, 502);
        for bad in ["file:///etc/passwd", "ftp://a.example/x", "https://user@a.example/", "not a url", "https://a.example\\@b/"] {
            assert_eq!(stream_reply(bad.into(), None, false).await.status, 400, "{bad}");
        }
    }

    /// Lets this test's own loopback origin server (and only that port) through the address guard.
    fn allow_origin(url: &str) {
        let port: u16 = url.rsplit_once(':').unwrap().1.split('/').next().unwrap().parse().unwrap();
        cache_netguard::loopback_port_for_tests(port);
    }

    /// A listener on `host` (a loopback address) that must never be connected to; `None` where the host cannot be bound here.
    fn watch(host: &str) -> Option<(std::net::TcpListener, u16)> {
        let l = std::net::TcpListener::bind(format!("{host}:0")).ok()?;
        l.set_nonblocking(true).unwrap();
        let port = l.local_addr().unwrap().port();
        Some((l, port))
    }

    fn untouched(l: &std::net::TcpListener, what: &str) {
        std::thread::sleep(Duration::from_millis(100));
        assert!(matches!(l.accept(), Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock), "{what}: a connection was made");
    }

    #[tokio::test]
    async fn the_proxy_refuses_ipv6_forms_of_private_addresses_and_makes_no_connection() {
        let (l4, p4) = watch("127.0.0.1").unwrap();
        let w6 = watch("[::127.0.0.1]");
        let mut targets = vec![
            "http://[::127.0.0.1]/".to_string(),
            "http://[64:ff9b::7f00:1]/".to_string(),
            "http://[2002:7f00:1::1]/".to_string(),
            "http://192.168.1.240/".to_string(),
            format!("http://127.0.0.1:{p4}/"),
        ];
        if let Some((_, p6)) = &w6 {
            targets.push(format!("http://[::127.0.0.1]:{p6}/"));
        }
        for t in &targets {
            assert_eq!(stream_reply(t.clone(), None, false).await.status, 502, "direct: {t}");
        }
        untouched(&l4, "direct 127.0.0.1");
        if let Some((l6, _)) = &w6 {
            untouched(l6, "direct ::127.0.0.1");
        }
    }

    #[tokio::test]
    async fn the_proxy_refuses_a_redirect_to_a_private_address_and_makes_no_connection() {
        let (l4, p4) = watch("127.0.0.1").unwrap();
        let w6 = watch("[::127.0.0.1]");
        let mut targets = vec![
            "http://[::127.0.0.1]/".to_string(),
            "http://[64:ff9b::7f00:1]/".to_string(),
            "http://[2002:7f00:1::1]/".to_string(),
            "http://192.168.1.240/".to_string(),
            format!("http://127.0.0.1:{p4}/"),
        ];
        if let Some((_, p6)) = &w6 {
            targets.push(format!("http://[::127.0.0.1]:{p6}/"));
        }
        for t in &targets {
            let (url, origin) = serve_once(format!("HTTP/1.1 302 Found\r\nLocation: {t}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").into_bytes());
            allow_origin(&url);
            assert_eq!(stream_reply(url, None, false).await.status, 502, "redirect to {t}");
            origin.join().unwrap();
        }
        untouched(&l4, "redirect to 127.0.0.1");
        if let Some((l6, _)) = &w6 {
            untouched(l6, "redirect to ::127.0.0.1");
        }
    }

    #[tokio::test]
    async fn the_proxy_follows_a_redirect_between_allowed_origins() {
        // control: the guard refuses addresses, not redirects; a hop to another allowed loopback origin still works
        let (target, t2) = serve_once(b"HTTP/1.1 200 OK\r\nContent-Type: video/mp4\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc".to_vec());
        allow_origin(&target);
        let (url, t1) = serve_once(format!("HTTP/1.1 302 Found\r\nLocation: {target}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").into_bytes());
        allow_origin(&url);
        let r = stream_reply(url, None, false).await;
        assert_eq!(r.status, 200);
        assert_eq!(collect(r).await, b"abc");
        t1.join().unwrap();
        t2.join().unwrap();
    }

    #[tokio::test]
    async fn an_upstream_error_status_is_passed_on_without_a_body() {
        let (url, t) = serve_once(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_vec());
        allow_origin(&url);
        assert_eq!(stream_reply(url, None, false).await.status, 403);
        t.join().unwrap();
    }

    #[tokio::test]
    async fn routes_need_get_or_head_and_a_known_shape() {
        assert_eq!(serve(None, "POST", "/api/video/stream", "u=x", None).await.status, 405);
        assert_eq!(serve(None, "GET", "/api/video/stream", "", None).await.status, 400);
        assert_eq!(serve(None, "GET", "/api/video/other", "", None).await.status, 404);
        assert_eq!(serve(None, "GET", "/api/video/zim/not-an-id/x.mp4", "", None).await.status, 404);
    }
}
