//! HTTP for PeerTube: JSON GET/POST, the OAuth form post, small file fetches and the streaming reader the downloader uses.
//! Blocking `ureq` with rustls, the same client as `cache_live`. Tokens go only to the instance's own API (never into
//! an error message, never to a file URL: private files use PeerTube's short-lived `videoFileToken` instead).

use crate::{user_agent, Error, Result};
use serde_json::Value;
use std::io::Read;
use std::time::Duration;

const MAX_JSON: u64 = 16 * 1024 * 1024;

pub fn agent() -> ureq::Agent {
    ureq::AgentBuilder::new()
        .timeout_connect(Duration::from_secs(15))
        // per read, not for the whole transfer: a stalled connection fails, a long download does not
        .timeout_read(Duration::from_secs(30))
        .timeout_write(Duration::from_secs(30))
        .user_agent(&user_agent())
        .build()
}

/// https always; plain http only to the machine itself (tests and a local server).
pub fn check_url(url: &str) -> Result<()> {
    if url.starts_with("https://") {
        return Ok(());
    }
    if let Some(r) = url.strip_prefix("http://") {
        let host = r.split(['/', '?', '#']).next().unwrap_or("");
        let host = host.rsplit('@').next().unwrap_or("");
        let host = if host.starts_with('[') { host.split(']').next().unwrap_or("").trim_start_matches('[') } else { host.split(':').next().unwrap_or("") };
        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return Ok(());
        }
    }
    Err(Error::bad_json("an instance must use https (http is allowed only to this machine)"))
}

/// The error for an HTTP status. `body` is PeerTube's error JSON when it sent one (`detail`, `code`).
fn status_error(code: u16, body: &str, what: &str, retry_after: Option<String>) -> Error {
    let v: Value = serde_json::from_str(body).unwrap_or(Value::Null);
    let pt_code = v["code"].as_str().unwrap_or("");
    let detail = v["detail"].as_str().or_else(|| v["error"].as_str()).or_else(|| v["error_description"].as_str()).unwrap_or("");
    let more = if detail.is_empty() { String::new() } else { format!(": {detail}") };
    match code {
        404 => Error::not_found(format!("{what} not found{more}")),
        401 | 403 => {
            if pt_code == "missing_two_factor" || pt_code == "invalid_two_factor" {
                Error::new("otp_required", format!("{what}: the account needs its two-factor code{more}"))
            } else {
                Error::auth_failed(format!("{what}: HTTP {code}{}{more}", if pt_code.is_empty() { String::new() } else { format!(" {pt_code}") }))
            }
        }
        400 if pt_code == "invalid_grant" => Error::auth_failed(format!("{what}: the user name or password is wrong{more}")),
        429 => Error::new("quota", format!("{what}: the instance asks to slow down{}", retry_after.map(|r| format!(" (retry after {r} s)")).unwrap_or_default())),
        _ => Error::fetch_failed(format!("{what}: HTTP {code}{more}")),
    }
}

fn map_err(e: ureq::Error, what: &str) -> Error {
    match e {
        ureq::Error::Status(code, resp) => {
            let ra = resp.header("Retry-After").map(str::to_string);
            let mut body = String::new();
            let _ = resp.into_reader().take(64 * 1024).read_to_string(&mut body);
            status_error(code, &body, what, ra)
        }
        ureq::Error::Transport(t) => Error::fetch_failed(format!("{what}: {:?}: {}", t.kind(), t.message().unwrap_or(""))),
    }
}

fn read_json(resp: ureq::Response, what: &str) -> Result<Value> {
    let mut body = String::new();
    resp.into_reader().take(MAX_JSON).read_to_string(&mut body).map_err(|e| Error::fetch_failed(format!("{what}: reading the response: {e}")))?;
    serde_json::from_str(&body).map_err(|e| Error::bad_response(format!("{what}: the response is not JSON: {e}")))
}

/// A GET is repeated once when the connection itself failed (a reset, a dropped keep-alive): it changes nothing on the
/// instance. An HTTP status is an answer and is never repeated.
// ureq's own error type, passed through as it is to the one caller that maps it
#[allow(clippy::result_large_err)]
fn call_get(make: impl Fn() -> ureq::Request) -> std::result::Result<ureq::Response, ureq::Error> {
    match make().call() {
        Err(ureq::Error::Transport(_)) => {
            std::thread::sleep(Duration::from_millis(400));
            make().call()
        }
        other => other,
    }
}

/// GET a JSON document from the instance's API, with the bearer token when there is one.
pub fn get_json(url: &str, token: Option<&str>, what: &str) -> Result<Value> {
    check_url(url)?;
    let make = || {
        let mut req = agent().get(url).set("Accept", "application/json");
        if let Some(t) = token.filter(|t| !t.is_empty()) {
            req = req.set("Authorization", &format!("Bearer {t}"));
        }
        req
    };
    read_json(call_get(make).map_err(|e| map_err(e, what))?, what)
}

/// POST a form (the OAuth token request) and read the JSON answer.
pub fn post_form(url: &str, form: &[(&str, &str)], headers: &[(&str, &str)], what: &str) -> Result<Value> {
    check_url(url)?;
    let mut req = agent().post(url).set("Accept", "application/json");
    for (k, v) in headers {
        req = req.set(k, v);
    }
    read_json(req.send_form(form).map_err(|e| map_err(e, what))?, what)
}

/// POST with no body (the video file token request), with the bearer token.
pub fn post_empty(url: &str, token: &str, what: &str) -> Result<Value> {
    check_url(url)?;
    let req = agent().post(url).set("Accept", "application/json").set("Authorization", &format!("Bearer {token}"));
    read_json(req.send_string("").map_err(|e| map_err(e, what))?, what)
}

/// A small file (thumbnail, caption, checksum list) read whole, up to `max` bytes.
pub fn get_bytes(url: &str, max: u64, what: &str) -> Result<Vec<u8>> {
    check_url(url)?;
    let resp = call_get(|| agent().get(url)).map_err(|e| map_err(e, what))?;
    let mut buf = Vec::new();
    resp.into_reader().take(max + 1).read_to_end(&mut buf).map_err(|e| Error::fetch_failed(format!("{what}: reading the response: {e}")))?;
    if buf.len() as u64 > max {
        return Err(Error::bad_response(format!("{what}: larger than {max} bytes")));
    }
    Ok(buf)
}

/// The answer to a (possibly ranged) file request: status, the parsed `Content-Range` start and total, and the body.
pub struct FileResponse {
    pub status: u16,
    pub range_start: Option<u64>,
    pub total: Option<u64>,
    pub content_length: Option<u64>,
    pub body: Box<dyn Read + Send + Sync>,
}

/// GET a file, optionally from byte `from` on (`Range: bytes=from-`). A 416 (nothing past `from`) is returned as a
/// response with status 416, not an error.
pub fn get_file(url: &str, from: u64) -> Result<FileResponse> {
    check_url(url)?;
    let mut req = agent().get(url);
    if from > 0 {
        req = req.set("Range", &format!("bytes={from}-"));
    }
    let resp = match req.call() {
        Ok(r) => r,
        Err(ureq::Error::Status(416, r)) => {
            return Ok(FileResponse { status: 416, range_start: None, total: parse_range(r.header("Content-Range")).map(|x| x.2), content_length: None, body: Box::new(std::io::empty()) });
        }
        Err(e) => return Err(map_err(e, "download")),
    };
    let status = resp.status();
    let cr = parse_range(resp.header("Content-Range"));
    let content_length = resp.header("Content-Length").and_then(|v| v.trim().parse().ok());
    Ok(FileResponse { status, range_start: cr.map(|x| x.0), total: cr.map(|x| x.2), content_length, body: Box::new(resp.into_reader()) })
}

/// `bytes 100-199/1000` (or `bytes */1000`) -> (start, end, total).
fn parse_range(h: Option<&str>) -> Option<(u64, u64, u64)> {
    let h = h?.trim().strip_prefix("bytes")?.trim();
    let (r, total) = h.split_once('/')?;
    let total: u64 = total.trim().parse().ok()?;
    if r.trim() == "*" {
        return Some((0, 0, total));
    }
    let (a, b) = r.split_once('-')?;
    Some((a.trim().parse().ok()?, b.trim().parse().ok()?, total))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_rules() {
        assert!(check_url("https://peertube.example/api/v1/config").is_ok());
        assert!(check_url("http://127.0.0.1:9000/x").is_ok());
        assert!(check_url("http://localhost/x").is_ok());
        assert!(check_url("http://example.org/x").is_err());
        assert!(check_url("http://127.0.0.1.evil.org/x").is_err());
        assert!(check_url("ftp://x").is_err());
    }

    #[test]
    fn ranges() {
        assert_eq!(parse_range(Some("bytes 100-199/1000")), Some((100, 199, 1000)));
        assert_eq!(parse_range(Some("bytes */1000")), Some((0, 0, 1000)));
        assert_eq!(parse_range(Some("items 1-2/3")), None);
        assert_eq!(parse_range(None), None);
    }

    #[test]
    fn status_errors() {
        assert_eq!(status_error(404, r#"{"detail":"Video not found"}"#, "video", None).code, "not_found");
        assert_eq!(status_error(400, r#"{"code":"invalid_grant"}"#, "login", None).code, "auth_failed");
        assert_eq!(status_error(401, r#"{"code":"missing_two_factor"}"#, "login", None).code, "otp_required");
        assert_eq!(status_error(403, r#"{"code":"video_requires_password"}"#, "video", None).code, "auth_failed");
        assert_eq!(status_error(429, "", "x", Some("5".into())).code, "quota");
        assert_eq!(status_error(503, "", "x", None).code, "fetch_failed");
    }
}
