//! A stand-in PeerTube for the tests: a local HTTP server (127.0.0.1, random port) that answers the endpoints the crate
//! uses with recorded responses (tests/fixtures; host example.org there is replaced by the server's address) and serves
//! files with `Range` support. Nothing here touches a real instance.
#![allow(dead_code)]

use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

pub const WEB_UUID: &str = "07273a4b-40a5-433f-a305-1c8f4268fd72";
pub const WEB_SHORT: &str = "1TesHJPJ33Jz5TUP7TA7cu";
pub const WEB_FILE: &str = "/static/web-videos/3c85ea25-bf2f-49fd-bf09-b1961332744b-608.mp4";
pub const WEB_SIZE: usize = 1_976_686;
pub const HLS_UUID: &str = "11111111-2222-4333-8444-555555555555";

#[derive(Clone, Debug)]
pub struct Hit {
    pub method: String,
    pub path: String,
    pub headers: Vec<(String, String)>,
    pub body: String,
}

impl Hit {
    pub fn header(&self, n: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(n)).map(|(_, v)| v.as_str())
    }
}

#[derive(Default)]
pub struct Knobs {
    /// Cut the next web-video file response after this many bytes (once).
    pub cut_after: Option<usize>,
    /// Pause between 32 KB pieces of a file, in ms.
    pub slow_ms: u64,
    pub download_disabled: bool,
    /// Serve a wrong checksum for the HLS audio file.
    pub bad_sha: bool,
    /// The HLS video is private (needs a login and a file token).
    pub private_hls: bool,
}

pub struct Mock {
    pub port: u16,
    pub hits: Arc<Mutex<Vec<Hit>>>,
    pub knobs: Arc<Mutex<Knobs>>,
}

pub fn blob(n: usize, seed: u64) -> Vec<u8> {
    let mut x = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
    (0..n)
        .map(|_| {
            x = x.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (x >> 33) as u8
        })
        .collect()
}

pub fn sha_hex(b: &[u8]) -> String {
    use sha2::{Digest, Sha256};
    Sha256::digest(b).iter().map(|x| format!("{x:02x}")).collect()
}

fn fixtures() -> PathBuf {
    // from this crate's tests, or from the cs crate's tests, which share this stand-in
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures");
    // a folder of that name is not enough: cli/tests/fixtures also holds other tools' fixtures (navigate), not these
    if here.join("config.json").is_file() { here } else { PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../native/cache_video/tests/fixtures") }
}

pub fn hls_details() -> Value {
    let base = "https://example.org/static/streaming-playlists/hls";
    let file = |id: i64, res: i64, label: &str, size: u64, audio: bool, video: bool| {
        json!({"id": id, "resolution": {"id": res, "label": label}, "size": size, "fps": if video {json!(30)} else {json!(0)},
               "hasAudio": audio, "hasVideo": video,
               "fileUrl": format!("{base}/{HLS_UUID}/{res}-fragmented.mp4"),
               "fileDownloadUrl": format!("https://example.org/download/streaming-playlists/hls/videos/{HLS_UUID}-{res}-fragmented.mp4")})
    };
    json!({
        "id": 900, "uuid": HLS_UUID, "shortUUID": "synthetic", "name": "Synthetic HLS video", "description": "built from the API reference, not recorded",
        "duration": 60, "publishedAt": "2026-01-01T00:00:00.000Z", "views": 1, "privacy": {"id": 1, "label": "Public"}, "isLive": false, "nsfw": false,
        "downloadEnabled": true, "state": {"id": 1, "label": "Published"},
        "thumbnailPath": "/lazy-static/thumbnails/fa8153a7-2d66-4179-9577-a12e0300abaf.jpg",
        "channel": {"name": "chan", "displayName": "Chan", "host": "example.org", "avatars": []},
        "files": [],
        "streamingPlaylists": [{"id": 1, "type": 1, "playlistUrl": format!("{base}/{HLS_UUID}/master.m3u8"),
                                "segmentsSha256Url": format!("{base}/{HLS_UUID}/segments-sha256.json"),
                                "files": [file(101, 720, "720p", 300_000, false, true), file(102, 360, "360p", 120_000, true, true), file(103, 0, "Audio", 40_000, true, false)]}],
    })
}

/// The bytes the stand-in serves for a path (None: not a file).
pub fn file_bytes(path: &str) -> Option<Vec<u8>> {
    if path == WEB_FILE {
        return Some(blob(WEB_SIZE, 7));
    }
    let p = path.split('?').next().unwrap();
    for (res, size) in [(720, 300_000), (360, 120_000), (0, 40_000)] {
        if p.ends_with(&format!("{HLS_UUID}/{res}-fragmented.mp4")) {
            return Some(blob(size, res as u64 + 100));
        }
    }
    None
}

impl Mock {
    pub fn start() -> Mock {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let hits: Arc<Mutex<Vec<Hit>>> = Default::default();
        let knobs: Arc<Mutex<Knobs>> = Default::default();
        let (h2, k2) = (hits.clone(), knobs.clone());
        std::thread::spawn(move || {
            for s in l.incoming().flatten() {
                let (h, k) = (h2.clone(), k2.clone());
                std::thread::spawn(move || {
                    let _ = serve(s, port, h, k);
                });
            }
        });
        Mock { port, hits, knobs }
    }

    pub fn url(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }

    pub fn id(&self) -> String {
        format!("127.0.0.1_{}", self.port)
    }

    pub fn hits_for(&self, needle: &str) -> Vec<Hit> {
        self.hits.lock().unwrap().iter().filter(|h| h.path.contains(needle)).cloned().collect()
    }
}

fn read_request(s: &mut TcpStream) -> Option<Hit> {
    let mut buf = Vec::new();
    let mut b = [0u8; 1];
    while !buf.ends_with(b"\r\n\r\n") {
        if s.read(&mut b).ok()? == 0 {
            return None;
        }
        buf.push(b[0]);
    }
    let text = String::from_utf8_lossy(&buf).into_owned();
    let mut lines = text.split("\r\n");
    let mut first = lines.next()?.split(' ');
    let (method, path) = (first.next()?.to_string(), first.next()?.to_string());
    let headers: Vec<(String, String)> = lines.filter_map(|l| l.split_once(": ").map(|(a, b)| (a.to_string(), b.to_string()))).collect();
    let len: usize = headers.iter().find(|(k, _)| k.eq_ignore_ascii_case("content-length")).and_then(|(_, v)| v.parse().ok()).unwrap_or(0);
    let mut body = vec![0u8; len];
    s.read_exact(&mut body).ok()?;
    Some(Hit { method, path, headers, body: String::from_utf8_lossy(&body).into_owned() })
}

fn send(s: &mut TcpStream, status: u16, ctype: &str, body: &[u8]) {
    let _ = write!(s, "HTTP/1.1 {status} X\r\nContent-Type: {ctype}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
    let _ = s.write_all(body);
}

fn send_json(s: &mut TcpStream, status: u16, v: &Value) {
    send(s, status, "application/json", v.to_string().as_bytes());
}

fn fixture(name: &str, port: u16) -> String {
    std::fs::read_to_string(fixtures().join(name)).unwrap().replace("https://example.org", &format!("http://127.0.0.1:{port}")).replace("\"example.org\"", &format!("\"127.0.0.1:{port}\""))
}

fn serve_file(s: &mut TcpStream, hit: &Hit, data: &[u8], knobs: &Arc<Mutex<Knobs>>, cut: bool) {
    let (slow, cut_after) = {
        let mut k = knobs.lock().unwrap();
        (k.slow_ms, if cut { k.cut_after.take() } else { None })
    };
    let (mut from, total) = (0usize, data.len());
    let mut status = 200;
    let mut extra = String::new();
    if let Some(r) = hit.header("Range") {
        if let Some(n) = r.strip_prefix("bytes=").and_then(|x| x.strip_suffix('-')).and_then(|x| x.parse::<usize>().ok()) {
            if n >= total {
                let _ = write!(s, "HTTP/1.1 416 X\r\nContent-Range: bytes */{total}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                return;
            }
            from = n;
            status = 206;
            extra = format!("Content-Range: bytes {from}-{}/{total}\r\n", total - 1);
        }
    }
    let body = &data[from..];
    let _ = write!(s, "HTTP/1.1 {status} X\r\nContent-Type: video/mp4\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n", body.len());
    let mut sent = 0;
    for piece in body.chunks(32 * 1024) {
        if let Some(c) = cut_after {
            if sent >= c {
                return; // drop the connection mid-body
            }
        }
        if s.write_all(piece).is_err() {
            return;
        }
        sent += piece.len();
        if slow > 0 {
            std::thread::sleep(Duration::from_millis(slow));
        }
    }
}

fn serve(mut s: TcpStream, port: u16, hits: Arc<Mutex<Vec<Hit>>>, knobs: Arc<Mutex<Knobs>>) -> Option<()> {
    let hit = read_request(&mut s)?;
    hits.lock().unwrap().push(hit.clone());
    let path = hit.path.split('?').next().unwrap().to_string();
    let q = hit.path.split_once('?').map(|x| x.1).unwrap_or("");
    let ua_ok = hit.header("User-Agent").map_or(false, |u| u.starts_with("Cache/"));
    if !ua_ok {
        send_json(&mut s, 400, &json!({"detail": "missing Cache user agent"}));
        return Some(());
    }
    let to_val = |t: String| serde_json::from_str::<Value>(&t).unwrap();
    let (disabled, private) = {
        let k = knobs.lock().unwrap();
        (k.download_disabled, k.private_hls)
    };
    match (hit.method.as_str(), path.as_str()) {
        ("GET", "/api/v1/config") => send(&mut s, 200, "application/json", fixture("config.json", port).as_bytes()),
        ("GET", "/api/v1/oauth-clients/local") => send_json(&mut s, 200, &json!({"client_id": "cid", "client_secret": "csecret"})),
        ("POST", "/api/v1/users/token") => {
            let form: Vec<(String, String)> = url::form_urlencoded::parse(hit.body.as_bytes()).into_owned().collect();
            let g = |k: &str| form.iter().find(|(a, _)| a == k).map(|(_, v)| v.clone()).unwrap_or_default();
            if g("client_id") != "cid" || g("client_secret") != "csecret" {
                send_json(&mut s, 400, &json!({"code": "invalid_client"}));
            } else if g("grant_type") == "refresh_token" {
                if g("refresh_token") == "R1" {
                    send_json(&mut s, 200, &json!({"token_type": "Bearer", "access_token": "A2", "refresh_token": "R2", "expires_in": 14399, "refresh_token_expires_in": 1209600}));
                } else {
                    send_json(&mut s, 400, &json!({"code": "invalid_grant"}));
                }
            } else if g("username") == "twofa" && hit.header("x-peertube-otp") != Some("123456") {
                send_json(&mut s, 401, &json!({"code": "missing_two_factor"}));
            } else if (g("username") == "alice" || g("username") == "twofa") && g("password") == "correct horse" {
                send_json(&mut s, 200, &json!({"token_type": "Bearer", "access_token": "A1", "refresh_token": "R1", "expires_in": 14399, "refresh_token_expires_in": 1209600}));
            } else {
                send_json(&mut s, 400, &json!({"code": "invalid_grant", "error": "Credentials are invalid."}));
            }
        }
        ("GET", "/api/v1/users/me") => {
            if hit.header("Authorization") == Some("Bearer A1") || hit.header("Authorization") == Some("Bearer A2") {
                send_json(&mut s, 200, &json!({"username": "alice", "email": "alice@example.invalid", "role": {"id": 2, "label": "Moderator"}, "account": {"displayName": "Alice"}}));
            } else {
                send_json(&mut s, 401, &json!({"detail": "Bad token"}));
            }
        }
        ("GET", "/api/v1/video-channels") => send(&mut s, 200, "application/json", fixture("channels.json", port).as_bytes()),
        ("GET", "/api/v1/search/video-channels") => send(&mut s, 200, "application/json", fixture("channel_search.json", port).as_bytes()),
        ("GET", "/api/v1/videos") => send(&mut s, 200, "application/json", fixture("videos.json", port).as_bytes()),
        ("GET", "/api/v1/search/videos") => send(&mut s, 200, "application/json", fixture("search.json", port).as_bytes()),
        ("GET", p) if p.starts_with("/api/v1/video-channels/") && p.ends_with("/videos") => send(&mut s, 200, "application/json", fixture("channel_videos.json", port).as_bytes()),
        ("GET", p) if p == format!("/api/v1/videos/{WEB_UUID}") || p == format!("/api/v1/videos/{WEB_SHORT}") => {
            let mut v = to_val(fixture("video_07273a4b.json", port));
            if disabled {
                v["downloadEnabled"] = json!(false);
            }
            send_json(&mut s, 200, &v)
        }
        ("GET", p) if p == format!("/api/v1/videos/{WEB_UUID}/captions") => send(&mut s, 200, "application/json", fixture("captions_07273a4b.json", port).as_bytes()),
        ("GET", p) if p == format!("/api/v1/videos/{HLS_UUID}") => {
            let t = hls_details().to_string().replace("https://example.org", &format!("http://127.0.0.1:{port}"));
            let mut v = to_val(t);
            if private {
                v["privacy"] = json!({"id": 3, "label": "Private"});
                if hit.header("Authorization") != Some("Bearer A1") {
                    send_json(&mut s, 403, &json!({"detail": "no", "code": "forbidden"}));
                    return Some(());
                }
            }
            send_json(&mut s, 200, &v)
        }
        ("GET", p) if p == format!("/api/v1/videos/{HLS_UUID}/captions") => send_json(&mut s, 200, &json!({"total": 0, "data": []})),
        ("POST", p) if p == format!("/api/v1/videos/{HLS_UUID}/token") => send_json(&mut s, 200, &json!({"files": {"token": "FT1", "expires": "2026-01-01T00:00:00.000Z"}})),
        ("GET", p) if p.starts_with("/api/v1/videos/") => send_json(&mut s, 404, &json!({"detail": "Video not found", "status": 404})),
        ("GET", p) if p.starts_with("/lazy-static/thumbnails/") => send(&mut s, 200, "image/jpeg", &blob(2048, 3)),
        ("GET", p) if p.starts_with("/lazy-static/video-captions/") => send(&mut s, 200, "text/vtt", b"WEBVTT\n\n00:00.000 --> 00:02.000\nhello\n"),
        ("GET", p) if p.ends_with("/segments-sha256.json") => {
            let audio_sha = if knobs.lock().unwrap().bad_sha { "00".repeat(32) } else { sha_hex(&blob(40_000, 100)) };
            send_json(&mut s, 200, &json!({"360-fragmented.mp4": sha_hex(&blob(120_000, 460)), "0-fragmented.mp4": audio_sha}))
        }
        ("GET", p) if p == format!("/download/videos/generate/{HLS_UUID}") => {
            if q.contains("videoFileIds=101") && q.contains("videoFileIds=103") {
                let mut b = blob(300_000, 201);
                b.extend(blob(40_000, 203));
                serve_file(&mut s, &hit, &b, &knobs, false)
            } else {
                send_json(&mut s, 400, &json!({"detail": "bad ids"}))
            }
        }
        ("GET", p) => match file_bytes(p) {
            Some(b) => {
                if p.contains(&format!("{HLS_UUID}")) && private && !q.contains("videoFileToken=FT1") {
                    send_json(&mut s, 403, &json!({"detail": "file token needed"}))
                } else {
                    serve_file(&mut s, &hit, &b, &knobs, p == WEB_FILE)
                }
            }
            None => send_json(&mut s, 404, &json!({"detail": "not found"})),
        },
        _ => send_json(&mut s, 404, &json!({"detail": "no route"})),
    }
    Some(())
}
