//! Libraries on the server: download jobs, uploads, the installed items, the catalogue fetch proxy and the refused rescan op.
//! The downloads run against a small HTTP server on this machine (`Origin`); the helper is the fake one (testbin/fake_helper.rs),
//! whose log shows that `sources.rescan` was sent.
//! The 2 GB streaming test is in tests/upload_stream.rs (its own process, so memory can be measured).

use cache_server::auth::{Auth, Sessions, StoredPassword};
use cache_server::fetch::FETCH_HOSTS;
use cache_server::helper::{Helper, HelperConfig};
use cache_server::http::{route, App};
use cache_server::library::{part_path, Library, LibraryOptions};
use http_body_util::Full;
use hyper::body::Bytes;
use ring::digest;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const BIG: u64 = 3_000_000;
const SLOW: u64 = 2_000_000;

fn byte(i: u64) -> u8 {
    (i.wrapping_mul(31).wrapping_add(7) & 0xff) as u8
}

fn content(from: u64, to: u64) -> Vec<u8> {
    (from..to).map(byte).collect()
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn sha_of(b: &[u8]) -> String {
    hex(digest::digest(&digest::SHA256, b).as_ref())
}

/// Percent-encode everything but unreserved characters.
fn enc(s: &str) -> String {
    s.bytes().map(|b| if b.is_ascii_alphanumeric() || b"-._~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect()
}

// ---- a small web server that behaves like a download host

struct Origin {
    port: u16,
    /// (path, Range header) of every request.
    log: Arc<Mutex<Vec<(String, Option<String>)>>>,
    /// When above zero, /big.zim sends only this many body bytes and then drops the connection.
    cut: Arc<AtomicU64>,
}

impl Origin {
    fn start() -> Origin {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let (log, cut) = (Arc::new(Mutex::new(vec![])), Arc::new(AtomicU64::new(0)));
        let (log2, cut2) = (log.clone(), cut.clone());
        std::thread::spawn(move || {
            for s in l.incoming().flatten() {
                let (log, cut) = (log2.clone(), cut2.clone());
                std::thread::spawn(move || serve(s, port, log, cut));
            }
        });
        Origin { port, log, cut }
    }

    fn url(&self, path: &str) -> String {
        format!("http://127.0.0.1:{}{path}", self.port)
    }

    fn requests(&self, path: &str) -> Vec<Option<String>> {
        self.log.lock().unwrap().iter().filter(|(p, _)| p == path).map(|(_, r)| r.clone()).collect()
    }
}

fn serve(mut s: TcpStream, port: u16, log: Arc<Mutex<Vec<(String, Option<String>)>>>, cut: Arc<AtomicU64>) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 1024];
    while !buf.windows(4).any(|w| w == b"\r\n\r\n") {
        match s.read(&mut chunk) {
            Ok(0) | Err(_) => return,
            Ok(n) => buf.extend_from_slice(&chunk[..n]),
        }
    }
    let text = String::from_utf8_lossy(&buf).to_string();
    let target = text.lines().next().unwrap_or("").split(' ').nth(1).unwrap_or("/");
    let path = target.split('?').next().unwrap_or("/").to_string();
    let range = text.lines().find_map(|l| {
        let (k, v) = l.split_once(':')?;
        k.eq_ignore_ascii_case("range").then(|| v.trim().to_string())
    });
    log.lock().unwrap().push((path.clone(), range.clone()));
    let head = |status: &str, extra: &str, len: Option<u64>| {
        let mut h = format!("HTTP/1.1 {status}\r\nConnection: close\r\n{extra}");
        if let Some(n) = len {
            h += &format!("Content-Length: {n}\r\n");
        }
        h += "\r\n";
        h
    };
    let small = |s: &mut TcpStream, status: &str, extra: &str, body: &[u8]| {
        let _ = s.write_all(head(status, extra, Some(body.len() as u64)).as_bytes());
        let _ = s.write_all(body);
    };
    match path.as_str() {
        "/big.zim" => {
            let start = range.as_deref().and_then(|r| r.strip_prefix("bytes=")).and_then(|r| r.trim_end_matches('-').parse::<u64>().ok()).unwrap_or(0);
            if start >= BIG {
                return small(&mut s, "416 Range Not Satisfiable", &format!("Content-Range: bytes */{BIG}\r\n"), b"");
            }
            let (status, extra) = if range.is_some() {
                ("206 Partial Content", format!("Content-Range: bytes {start}-{}/{BIG}\r\nAccept-Ranges: bytes\r\n", BIG - 1))
            } else {
                ("200 OK", "Accept-Ranges: bytes\r\n".to_string())
            };
            let _ = s.write_all(head(status, &extra, Some(BIG - start)).as_bytes());
            let stop = match cut.load(Ordering::Relaxed) {
                0 => BIG,
                c => (start + c).min(BIG),
            };
            let mut at = start;
            while at < stop {
                let to = (at + 65536).min(stop);
                if s.write_all(&content(at, to)).is_err() {
                    return;
                }
                at = to;
            }
            let _ = s.flush();
        }
        "/pub.zim" => small(&mut s, "200 OK", "", &content(0, 100_000)),
        "/pub.zim.sha256" => small(&mut s, "200 OK", "", format!("{}  pub.zim\n", "ff".repeat(32)).as_bytes()),
        "/slow.zim" => {
            let _ = s.write_all(head("200 OK", "", Some(SLOW)).as_bytes());
            let mut at = 0;
            while at < SLOW {
                let to = (at + 8192).min(SLOW);
                if s.write_all(&content(at, to)).is_err() {
                    return;
                }
                at = to;
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        "/icon.png" => small(&mut s, "200 OK", "Content-Type: image/png\r\n", b"\x89PNG-icon"),
        "/cat.xml" => small(&mut s, "200 OK", "Content-Type: application/atom+xml\r\n", b"<feed/>"),
        "/redir-ok" => small(&mut s, "302 Found", "Location: /cat.xml\r\n", b""),
        "/redir-evil" => small(&mut s, "302 Found", &format!("Location: http://evil.invalid:{port}/x\r\n"), b""),
        "/huge-len" => {
            let _ = s.write_all(head("200 OK", "", Some(100_000_000)).as_bytes());
        }
        "/endless" => {
            let _ = s.write_all(head("200 OK", "", None).as_bytes());
            let block = vec![b'x'; 65536];
            for _ in 0..48 {
                if s.write_all(&block).is_err() {
                    return;
                }
            }
        }
        _ => small(&mut s, "404 Not Found", "", b"no"),
    }
}

// ---- the server under test

struct Dir(PathBuf);
impl Dir {
    fn new(tag: &str) -> Dir {
        let p = std::env::temp_dir().join(format!("cache-server-lib-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Dir(p)
    }
}
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Rig {
    dir: Dir,
    app: App,
    cookie: String,
    origin: Origin,
}

impl Rig {
    fn data(&self) -> &Path {
        &self.dir.0
    }

    fn log(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.0.join("ops.log")).unwrap_or_default().lines().map(str::to_string).collect()
    }

    fn rescans(&self) -> usize {
        self.log().iter().filter(|l| l.starts_with("sources.rescan ")).count()
    }

    async fn call(&self, method: &str, path: &str, body: &str) -> (u16, Value) {
        let r = route(&self.app, method, path, Some(&self.cookie), body.as_bytes()).await;
        (r.status, serde_json::from_slice(&r.body).unwrap_or(Value::Null))
    }

    async fn jobs(&self) -> Vec<Value> {
        let (s, v) = self.call("GET", "/api/library/jobs", "").await;
        assert_eq!(s, 200);
        v["result"].as_array().unwrap().clone()
    }

    async fn job(&self, id: &str) -> Option<Value> {
        self.jobs().await.into_iter().find(|j| j["id"] == json!(id))
    }

    /// Wait until the job is in one of `states`; the job as it then is.
    async fn wait_state(&self, id: &str, states: &[&str]) -> Value {
        for _ in 0..600 {
            if let Some(j) = self.job(id).await {
                if states.contains(&j["state"].as_str().unwrap()) {
                    return j;
                }
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        panic!("job {id} never reached {states:?}: {:?}", self.job(id).await);
    }

    async fn download(&self, body: Value) -> Value {
        let (s, v) = self.call("POST", "/api/library/download", &body.to_string()).await;
        assert_eq!((s, v["ok"].clone()), (200, json!(true)), "{v}");
        v["result"].clone()
    }

    fn zims(&self) -> PathBuf {
        self.dir.0.join("app/docs/zims")
    }
}

static LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

struct Setup {
    options: LibraryOptions,
    status: Option<String>,
    seed: Option<Box<dyn FnOnce(&Path, &Origin)>>,
}

impl Setup {
    fn new() -> Setup {
        Setup { options: LibraryOptions::default(), status: None, seed: None }
    }
}

async fn rig(tag: &str, setup: Setup) -> Rig {
    let dir = Dir::new(tag);
    for d in ["tmp", "app/support", "app/docs/zims", "app/docs/libraries"] {
        std::fs::create_dir_all(dir.0.join(d)).unwrap();
    }
    let origin = Origin::start();
    if let Some(seed) = setup.seed {
        seed(&dir.0, &origin);
    }
    std::env::set_var("FAKE_LOG", dir.0.join("ops.log"));
    std::env::set_var("FAKE_MARKER", dir.0.join("marker"));
    match &setup.status {
        Some(s) => std::env::set_var("FAKE_STATUS", s),
        None => std::env::remove_var("FAKE_STATUS"),
    }
    let mut cfg = HelperConfig::new(PathBuf::from(env!("CARGO_BIN_EXE_fake-helper")), PathBuf::from("libfake"), dir.0.join("sources.json"));
    cfg.app_dirs = Some((dir.0.join("app/support"), dir.0.join("app/docs")));
    cfg.ready_timeout = Duration::from_secs(10);
    let helper = Helper::start(cfg).await;
    let auth = Auth::new(Some(StoredPassword::new("pw").unwrap()), Sessions::load(&dir.0.join("sessions.json")), false);
    let library = Library::with_options(dir.0.clone(), Some(helper.clone()), setup.options);
    let app = App { auth: Arc::new(auth), helper: Some(helper), web: dir.0.join("web"), library };
    let r = route(&app, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
    assert_eq!(r.status, 204);
    let cookie = r.headers.iter().find(|(k, _)| *k == "Set-Cookie").unwrap().1.split(';').next().unwrap().to_string();
    Rig { dir, app, cookie, origin }
}

async fn stop(rig: &Rig) {
    rig.app.helper.as_ref().unwrap().shutdown().await;
}

fn part_files(data: &Path) -> Vec<String> {
    std::fs::read_dir(data.join("tmp")).map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().to_string()).collect()).unwrap_or_default()
}

// ---- downloads

#[tokio::test]
async fn a_download_is_installed_like_the_phone_does_with_its_sidecars_and_the_core_is_told() {
    let _g = LOCK.lock().await;
    let rig = rig("dl", Setup::new()).await;
    let expect = content(0, BIG);
    let origin_json = json!({"name": "big", "flavour": "maxi", "release": "2026-09", "title": "Big Wiki", "catalogId": "abc"});
    let job = rig
        .download(json!({"url": rig.origin.url("/big.zim"), "kind": "zim", "name": "Big Wiki", "sha256": sha_of(&expect).to_uppercase(),
                         "origin": origin_json, "icon_url": rig.origin.url("/icon.png")}))
        .await;
    assert_eq!((job["name"].clone(), job["kind"].clone(), job["state"].clone()), (json!("Big Wiki.zim"), json!("zim"), json!("queued")));
    let done = rig.wait_state(job["id"].as_str().unwrap(), &["done", "failed"]).await;
    assert_eq!((done["state"].clone(), done["error"].clone(), done["bytes"].clone(), done["total"].clone()), (json!("done"), Value::Null, json!(BIG), json!(BIG)));
    // where the app would have put it, with the same sidecars
    assert_eq!(std::fs::read(rig.zims().join("Big Wiki.zim")).unwrap(), expect);
    let origin: Value = serde_json::from_slice(&std::fs::read(rig.zims().join("Big Wiki.zim.origin.json")).unwrap()).unwrap();
    assert_eq!(origin, origin_json);
    assert_eq!(std::fs::read(rig.zims().join("Big Wiki.zim.icon.png")).unwrap(), b"\x89PNG-icon");
    assert!(part_files(rig.data()).is_empty(), "{:?}", part_files(rig.data()));
    assert!(std::fs::read_dir(rig.zims()).unwrap().flatten().all(|e| !e.file_name().to_string_lossy().starts_with('.')), "no hidden install file is left");
    // the job is kept on disk, and the helper was told to rescan
    let kept: Value = serde_json::from_slice(&std::fs::read(rig.data().join("jobs.json")).unwrap()).unwrap();
    assert_eq!((kept[0]["state"].clone(), kept[0]["id"].clone()), (json!("done"), job["id"].clone()));
    assert_eq!(rig.rescans(), 1, "{:?}", rig.log());
    // the same address while nothing is active is a new job; the name comes from the address when none is given
    let again = rig.download(json!({"url": rig.origin.url("/big.zim?x=1"), "kind": "zim"})).await;
    assert_eq!(again["name"], json!("big.zim"));
    assert_ne!(again["id"], job["id"]);
    rig.wait_state(again["id"].as_str().unwrap(), &["done", "failed"]).await;
    stop(&rig).await;
}

#[tokio::test]
async fn bad_download_requests_are_refused_and_library_packages_wait_for_a_decision() {
    let _g = LOCK.lock().await;
    let rig = rig("dlbad", Setup::new()).await;
    let url = rig.origin.url("/big.zim");
    for (body, status, code) in [
        (json!({"kind": "zim"}), 400, "invalid"),
        (json!({"url": "ftp://x/y.zim", "kind": "zim"}), 400, "invalid"),
        (json!({"url": "http://example.com/a.zim", "kind": "zim"}), 400, "invalid"),
        (json!({"url": url, "kind": "other"}), 400, "invalid"),
        (json!({"url": url, "kind": "zim", "name": "../evil.zim"}), 400, "invalid_name"),
        (json!({"url": url, "kind": "zim", "name": "a/b.zim"}), 400, "invalid_name"),
        (json!({"url": url, "kind": "zim", "sha256": "abc"}), 400, "invalid"),
        (json!({"url": url, "kind": "zim", "origin": [1]}), 400, "invalid"),
        (json!({"url": url, "kind": "library"}), 501, "library_install_pending"),
    ] {
        let (s, v) = rig.call("POST", "/api/library/download", &body.to_string()).await;
        assert_eq!((s, v["error"]["code"].clone()), (status, json!(code)), "{body}");
    }
    assert_eq!(rig.call("POST", "/api/library/download", "nope").await.0, 400);
    assert!(rig.jobs().await.is_empty());
    // not signed in
    let r = route(&rig.app, "GET", "/api/library/jobs", None, b"").await;
    assert_eq!(r.status, 401);
    stop(&rig).await;
}

#[tokio::test]
async fn an_interrupted_download_continues_with_a_range_request() {
    let _g = LOCK.lock().await;
    let rig = rig("resume", Setup::new()).await;
    let url = rig.origin.url("/big.zim");
    rig.origin.cut.store(1_000_000, Ordering::Relaxed);
    let job = rig.download(json!({"url": url, "kind": "zim", "name": "r.zim"})).await;
    let failed = rig.wait_state(job["id"].as_str().unwrap(), &["done", "failed"]).await;
    assert_eq!(failed["state"], json!("failed"), "{failed}");
    assert!(failed["error"].as_str().unwrap().len() > 5);
    assert!(!rig.zims().join("r.zim").exists());
    let part = part_path(rig.data(), &url);
    let have = std::fs::metadata(&part).expect("the part file stays").len();
    assert!(have > 0 && have <= 1_000_000, "{have}");
    assert_eq!(std::fs::read(&part).unwrap(), content(0, have));
    // the same address again continues the file
    rig.origin.cut.store(0, Ordering::Relaxed);
    let again = rig.download(json!({"url": url, "kind": "zim", "name": "r.zim"})).await;
    let done = rig.wait_state(again["id"].as_str().unwrap(), &["done", "failed"]).await;
    assert_eq!(done["state"], json!("done"), "{done}");
    assert_eq!(std::fs::read(rig.zims().join("r.zim")).unwrap(), content(0, BIG));
    assert_eq!(rig.origin.requests("/big.zim").last().unwrap().as_deref(), Some(format!("bytes={have}-").as_str()));
    assert!(!part.exists());
    stop(&rig).await;
}

#[tokio::test]
async fn a_job_left_running_by_a_restart_goes_on_from_its_part_file() {
    let _g = LOCK.lock().await;
    let mut setup = Setup::new();
    setup.seed = Some(Box::new(|data, origin| {
        let url = origin.url("/big.zim");
        std::fs::write(part_path(data, &url), content(0, 1_200_000)).unwrap();
        let job = json!([{"id": "0123456789abcdef", "url": url, "kind": "zim", "name": "back.zim", "bytes": 1_200_000, "total": BIG,
                          "state": "running", "error": null, "sha256": sha_of(&content(0, BIG)), "origin": null, "icon_url": null}]);
        std::fs::write(data.join("jobs.json"), job.to_string()).unwrap();
    }));
    let rig = rig("restart", setup).await;
    let done = rig.wait_state("0123456789abcdef", &["done", "failed"]).await;
    assert_eq!(done["state"], json!("done"), "{done}");
    assert_eq!(std::fs::read(rig.zims().join("back.zim")).unwrap(), content(0, BIG));
    assert_eq!(rig.origin.requests("/big.zim"), vec![Some("bytes=1200000-".to_string())]);
    stop(&rig).await;
}

#[tokio::test]
async fn a_checksum_that_does_not_match_throws_the_file_away() {
    let _g = LOCK.lock().await;
    let rig = rig("sum", Setup::new()).await;
    // the checksum the caller gave
    let url = rig.origin.url("/big.zim");
    let job = rig.download(json!({"url": url, "kind": "zim", "name": "bad.zim", "sha256": "00".repeat(32)})).await;
    let failed = rig.wait_state(job["id"].as_str().unwrap(), &["done", "failed"]).await;
    assert_eq!(failed["state"], json!("failed"));
    assert!(failed["error"].as_str().unwrap().contains("checksum"), "{failed}");
    assert!(!rig.zims().join("bad.zim").exists());
    assert!(!part_path(rig.data(), &url).exists(), "a file that failed its checksum is not kept");
    // the checksum the host publishes beside a ZIM, when none was given
    let job = rig.download(json!({"url": rig.origin.url("/pub.zim"), "kind": "zim"})).await;
    let failed = rig.wait_state(job["id"].as_str().unwrap(), &["done", "failed"]).await;
    assert_eq!(failed["state"], json!("failed"));
    assert!(failed["error"].as_str().unwrap().contains("checksum"), "{failed}");
    assert!(!rig.zims().join("pub.zim").exists());
    assert_eq!(rig.rescans(), 0, "nothing was installed, so nothing to rescan: {:?}", rig.log());
    stop(&rig).await;
}

#[tokio::test]
async fn one_download_runs_at_a_time_and_cancel_stops_a_running_or_waiting_job() {
    let _g = LOCK.lock().await;
    let rig = rig("cancel", Setup::new()).await;
    let a = rig.download(json!({"url": rig.origin.url("/slow.zim"), "kind": "zim", "name": "a.zim"})).await;
    let b = rig.download(json!({"url": rig.origin.url("/big.zim"), "kind": "zim", "name": "b.zim"})).await;
    // asking for the running address again gives the same job
    let same = rig.download(json!({"url": rig.origin.url("/slow.zim"), "kind": "zim", "name": "a.zim"})).await;
    assert_eq!(same["id"], a["id"]);
    let (aid, bid) = (a["id"].as_str().unwrap(), b["id"].as_str().unwrap());
    let mut running = None;
    for _ in 0..200 {
        let j = rig.job(aid).await.unwrap();
        if j["state"] == json!("running") && j["bytes"].as_u64().unwrap() > 0 {
            running = Some(j);
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(running.is_some(), "the first job never started");
    assert_eq!(rig.job(bid).await.unwrap()["state"], json!("queued"), "the second waits its turn");
    assert!(rig.origin.requests("/big.zim").is_empty());
    // cancel the waiting job, then the running one
    let (s, v) = rig.call("DELETE", &format!("/api/library/jobs/{bid}"), "").await;
    assert_eq!((s, v["result"]["state"].clone()), (200, json!("cancelled")));
    let (s, v) = rig.call("DELETE", &format!("/api/library/jobs/{aid}"), "").await;
    assert_eq!((s, v["result"]["state"].clone()), (200, json!("cancelled")));
    // the worker notices, throws the part file away and does not install; the job it did not reach is never fetched
    let part = part_path(rig.data(), &rig.origin.url("/slow.zim"));
    for _ in 0..100 {
        if !part.exists() && rig.job(aid).await.is_some_and(|j| j["state"] == json!("cancelled")) {
            break;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert!(!part.exists());
    assert_eq!(rig.job(aid).await.unwrap()["state"], json!("cancelled"));
    assert!(!rig.zims().join("a.zim").exists() && !rig.zims().join("b.zim").exists());
    assert!(rig.origin.requests("/big.zim").is_empty());
    assert_eq!(rig.rescans(), 0);
    // a finished job is taken off the list by DELETE; an unknown one is a 404
    assert_eq!(rig.call("DELETE", &format!("/api/library/jobs/{aid}"), "").await.0, 200);
    assert!(rig.job(aid).await.is_none());
    assert_eq!(rig.call("DELETE", "/api/library/jobs/nope", "").await.0, 404);
    stop(&rig).await;
}

// ---- uploads

#[tokio::test]
async fn an_upload_is_installed_like_a_download_and_its_name_is_made_safe() {
    let _g = LOCK.lock().await;
    let rig = rig("up", Setup::new()).await;
    let up = |q: &str, body: &[u8]| {
        let (app, cookie, q) = (&rig.app, rig.cookie.clone(), q.to_string());
        let body = body.to_vec();
        async move {
            let r = route(app, "POST", &format!("/api/library/upload?{q}"), Some(&cookie), &body).await;
            (r.status, serde_json::from_slice::<Value>(&r.body).unwrap())
        }
    };
    let (s, v) = up("kind=zim&name=Small%20Pack", b"ZIMDATA").await;
    assert_eq!((s, v["result"]["name"].clone(), v["result"]["bytes"].clone()), (200, json!("Small Pack.zim"), json!(7)), "{v}");
    assert_eq!(std::fs::read(rig.zims().join("Small Pack.zim")).unwrap(), b"ZIMDATA");
    assert_eq!(rig.rescans(), 1);
    assert!(part_files(rig.data()).is_empty());
    // it replaces a file of the same name
    let (s, _) = up("kind=zim&name=Small%20Pack.zim", b"NEWER").await;
    assert_eq!(s, 200);
    assert_eq!(std::fs::read(rig.zims().join("Small Pack.zim")).unwrap(), b"NEWER");
    // names that could leave the folder, or hide, are refused before anything is written
    for bad in ["..%2F..%2Fetc%2Fx.zim", "a%2Fb.zim", "a%5Cb.zim", "..", "x..zim", ".hid.zim", "", "%2Fabs.zim", "a%00b.zim"] {
        let (s, v) = up(&format!("kind=zim&name={bad}"), b"x").await;
        assert_eq!((s, v["error"]["code"].clone()), (400, json!("invalid_name")), "{bad:?}");
    }
    assert_eq!(up("kind=zim", b"x").await.0, 400);
    assert_eq!(up("kind=other&name=a.zim", b"x").await.0, 400);
    let (s, v) = up("kind=library&name=a.cache-library", b"x").await;
    assert_eq!((s, v["error"]["code"].clone()), (501, json!("library_install_pending")));
    let names: Vec<String> = std::fs::read_dir(rig.zims()).unwrap().flatten().map(|e| e.file_name().to_string_lossy().to_string()).collect();
    assert_eq!(names, vec!["Small Pack.zim".to_string()]);
    assert!(part_files(rig.data()).is_empty());
    assert!(!rig.data().parent().unwrap().join("etc").exists());
    // a length is needed, and a body that is not the length it says is refused
    let lib = &rig.app.library;
    let e = lib.upload("kind=zim&name=a.zim", None, Full::new(Bytes::from_static(b"abc"))).await.unwrap_err();
    assert_eq!(e.status, 411);
    let e = lib.upload("kind=zim&name=a.zim", Some(5), Full::new(Bytes::from_static(b"abc"))).await.unwrap_err();
    assert_eq!(e.status, 400);
    let e = lib.upload("kind=zim&name=a.zim", Some(2), Full::new(Bytes::from_static(b"abc"))).await.unwrap_err();
    assert_eq!(e.status, 400);
    assert!(part_files(rig.data()).is_empty(), "{:?}", part_files(rig.data()));
    assert!(!rig.zims().join("a.zim").exists());
    // not signed in
    let r = route(&rig.app, "POST", "/api/library/upload?kind=zim&name=a.zim", None, b"x").await;
    assert_eq!(r.status, 401);
    stop(&rig).await;
}

#[tokio::test]
async fn an_upload_is_refused_with_507_unless_the_disk_has_its_size_and_a_gigabyte_more() {
    let _g = LOCK.lock().await;
    let free = Arc::new(AtomicU64::new((1 << 30) + 9));
    let f2 = free.clone();
    let mut setup = Setup::new();
    setup.options.free_bytes = Some(Arc::new(move |_| Some(f2.load(Ordering::Relaxed))));
    let rig = rig("507", setup).await;
    let q = "/api/library/upload?kind=zim&name=a.zim";
    // 10 bytes need 1 GiB + 10 bytes
    let r = route(&rig.app, "POST", q, Some(&rig.cookie), b"0123456789").await;
    assert_eq!(r.status, 507);
    assert_eq!(serde_json::from_slice::<Value>(&r.body).unwrap()["error"]["code"], "no_space");
    assert!(part_files(rig.data()).is_empty() && !rig.zims().join("a.zim").exists());
    free.store((1 << 30) + 10, Ordering::Relaxed);
    let r = route(&rig.app, "POST", q, Some(&rig.cookie), b"0123456789").await;
    assert_eq!(r.status, 200);
    assert_eq!(std::fs::read(rig.zims().join("a.zim")).unwrap(), b"0123456789");
    stop(&rig).await;
}

// ---- the rescan op

#[tokio::test]
async fn the_rescan_op_is_refused_from_a_browser_and_never_reaches_the_helper() {
    let _g = LOCK.lock().await;
    let rig = rig("rescan", Setup::new()).await;
    for body in [r#"{"op":"sources.rescan","args":{}}"#, r#"{"op":"sources.rescan","args":{"sources":[]}}"#, r#"{"op":"sources.rescan"}"#] {
        let (s, v) = rig.call("POST", "/api/core", body).await;
        assert_eq!((s, v["ok"].clone(), v["error"]["code"].clone()), (403, json!(false), json!("forbidden")), "{body}");
    }
    assert_eq!(rig.rescans(), 0, "{:?}", rig.log());
    // open, close and setSources are still answered by the server alone
    for op in ["open", "close", "setSources"] {
        let (s, v) = rig.call("POST", "/api/core", &json!({"op": op, "args": {}}).to_string()).await;
        assert_eq!((s, v), (200, json!({"ok": true, "result": null})), "{op}");
    }
    assert!(rig.log().iter().all(|l| !l.starts_with("setSources")), "{:?}", rig.log());
    // the server's own rescan does reach it
    assert_eq!(rig.app.library.rescan().await, Ok(0));
    assert_eq!(rig.rescans(), 1);
    stop(&rig).await;
}

// ---- the catalogue fetch

async fn read_all(mut rx: tokio::sync::mpsc::Receiver<std::io::Result<Bytes>>) -> (Vec<u8>, bool) {
    let mut got = vec![];
    while let Some(item) = rx.recv().await {
        match item {
            Ok(b) => got.extend_from_slice(&b),
            Err(_) => return (got, true),
        }
    }
    (got, false)
}

#[tokio::test]
async fn fetch_reads_allow_listed_hosts_only_and_holds_the_size_cap() {
    let _g = LOCK.lock().await;
    let mut setup = Setup::new();
    setup.options.fetch_hosts = Some(vec!["127.0.0.1".to_string()]);
    setup.options.fetch_max = Some(1_000_000);
    let rig = rig("fetch", setup).await;
    let get = |url: String| {
        let (app, cookie) = (&rig.app, rig.cookie.clone());
        async move { route(app, "GET", &format!("/api/fetch?url={}", enc(&url)), Some(&cookie), b"").await }
    };
    let code = |r: &cache_server::http::Reply| serde_json::from_slice::<Value>(&r.body).unwrap()["error"]["code"].clone();

    // allowed: the body comes through with its type
    let r = get(rig.origin.url("/cat.xml")).await;
    assert_eq!(r.status, 200);
    assert!(r.headers.iter().any(|(k, v)| *k == "Content-Type" && v == "application/atom+xml"));
    assert!(r.headers.iter().any(|(k, v)| *k == "Content-Security-Policy" && v.contains("sandbox")));
    assert_eq!(read_all(r.stream.unwrap()).await, (b"<feed/>".to_vec(), false));
    // a redirect that stays on the list is followed
    let r = get(rig.origin.url("/redir-ok")).await;
    assert_eq!(r.status, 200);
    assert_eq!(read_all(r.stream.unwrap()).await.0, b"<feed/>");
    // a redirect off the list is not
    let r = get(rig.origin.url("/redir-evil")).await;
    assert_eq!((r.status, code(&r)), (403, json!("host_not_allowed")));
    // hosts that are not on the list, by name or by address
    for u in ["https://example.com/catalog", "https://download.kiwix.org/zim/x.zim", &format!("http://localhost:{}/cat.xml", rig.origin.port)] {
        let r = get(u.to_string()).await;
        assert_eq!((r.status, code(&r)), (403, json!("host_not_allowed")), "{u}");
    }
    // addresses that are not addresses, or could be read two ways
    for u in ["", "cat.xml", "file:///etc/passwd", "ftp://127.0.0.1/x", "http://127.0.0.1@evil.invalid/x", "http://127.0.0.1\\@evil.invalid/x"] {
        let r = get(u.to_string()).await;
        assert_eq!((r.status, code(&r)), (400, json!("invalid")), "{u:?}");
    }
    let r = route(&rig.app, "GET", "/api/fetch", Some(&rig.cookie), b"").await;
    assert_eq!(r.status, 400);
    // signed in only
    let r = route(&rig.app, "GET", &format!("/api/fetch?url={}", enc(&rig.origin.url("/cat.xml"))), None, b"").await;
    assert_eq!(r.status, 401);
    // the cap: an answer that says it is too big is refused; one that grows past it is cut off
    let r = get(rig.origin.url("/huge-len")).await;
    assert_eq!((r.status, code(&r)), (413, json!("too_large")));
    let r = get(rig.origin.url("/endless")).await;
    assert_eq!(r.status, 200);
    let (got, cut) = read_all(r.stream.unwrap()).await;
    assert!(cut && got.len() <= 1_000_000, "{} bytes, cut {cut}", got.len());
    // an error from the host
    let r = get(rig.origin.url("/nothing")).await;
    assert_eq!((r.status, code(&r)), (502, json!("upstream_status")));
    stop(&rig).await;
}

#[test]
fn the_fetch_allow_list_is_exactly_the_hosts_the_apps_catalogues_use() {
    assert_eq!(FETCH_HOSTS, ["opds.library.kiwix.org", "data.cached.info", "cache.echo6.co"]);
    assert_eq!(cache_server::fetch::FETCH_MAX_BYTES, 50 << 20);
}

// ---- what is installed

#[tokio::test]
async fn items_list_what_is_installed_and_remove_takes_files_sidecars_and_index() {
    let _g = LOCK.lock().await;
    let mut setup = Setup::new();
    setup.status = Some(
        json!([{"id": "u1", "kind": "zim", "path": "/somewhere/zims/a.zim", "title": "Alpha Wiki"},
               {"id": "u2", "kind": "library", "path": "/somewhere/libraries/guide/shard", "title": "The Guide"}])
        .to_string(),
    );
    setup.seed = Some(Box::new(|data, _| {
        let zims = data.join("app/docs/zims");
        std::fs::write(zims.join("a.zim"), b"0123456789").unwrap();
        std::fs::write(zims.join("a.zim.origin.json"), b"{}").unwrap();
        std::fs::write(zims.join("a.zim.icon.png"), b"png").unwrap();
        std::fs::write(zims.join("b.zim"), b"bb").unwrap();
        std::fs::write(zims.join(".hidden.zim"), b"h").unwrap();
        std::fs::write(zims.join("notes.txt"), b"n").unwrap();
        std::fs::create_dir_all(data.join("app/support/indexes/a.zim.idx")).unwrap();
        std::fs::write(data.join("app/support/indexes/a.zim.idx/seg"), b"i").unwrap();
        let g = data.join("app/docs/libraries/guide");
        std::fs::create_dir_all(g.join("shard")).unwrap();
        std::fs::create_dir_all(g.join("index")).unwrap();
        std::fs::write(g.join("shard/s"), b"12345").unwrap();
        std::fs::write(g.join("index/i"), b"123").unwrap();
        std::fs::write(g.join("cache-library.json"), b"{}").unwrap();
        std::fs::create_dir_all(data.join("app/docs/libraries/noshard")).unwrap();
    }));
    let rig = rig("items", setup).await;
    let (s, v) = rig.call("GET", "/api/library/items", "").await;
    assert_eq!(s, 200);
    let items = v["result"].as_array().unwrap().clone();
    let view: Vec<(String, String, String, u64, String)> = items
        .iter()
        .map(|i| (i["kind"].as_str().unwrap().into(), i["name"].as_str().unwrap().into(), i["title"].as_str().unwrap().into(), i["bytes"].as_u64().unwrap(), i["path"].as_str().unwrap().into()))
        .collect();
    assert_eq!(
        view,
        vec![
            ("zim".into(), "a.zim".into(), "Alpha Wiki".into(), 10, "app/docs/zims/a.zim".into()),
            ("zim".into(), "b.zim".into(), "b.zim".into(), 2, "app/docs/zims/b.zim".into()),
            ("library".into(), "guide".into(), "The Guide".into(), 5 + 3 + 2, "app/docs/libraries/guide".into()),
        ]
    );
    let ids: Vec<&str> = items.iter().map(|i| i["id"].as_str().unwrap()).collect();
    assert!(ids.iter().all(|i| i.chars().all(|c| c.is_ascii_alphanumeric() || c == '-')));

    // remove the first ZIM: file, both sidecars and its index folder go; the rest stays
    let (s, v) = rig.call("DELETE", &format!("/api/library/items/{}", ids[0]), "").await;
    assert_eq!((s, v["result"]["removed"].clone()), (200, json!(true)), "{v}");
    let zims = rig.zims();
    for gone in ["a.zim", "a.zim.origin.json", "a.zim.icon.png"] {
        assert!(!zims.join(gone).exists(), "{gone}");
    }
    assert!(!rig.data().join("app/support/indexes/a.zim.idx").exists());
    assert!(zims.join("b.zim").exists() && zims.join(".hidden.zim").exists() && zims.join("notes.txt").exists());
    assert_eq!(rig.rescans(), 1);
    assert_eq!(rig.call("DELETE", &format!("/api/library/items/{}", ids[0]), "").await.0, 404);
    assert_eq!(rig.call("DELETE", "/api/library/items/zim-0000000000000000", "").await.0, 404);
    assert_eq!(rig.call("DELETE", "/api/library/items/..%2F..", "").await.0, 404);

    // refused while a download of the same item is running
    let job = rig.download(json!({"url": rig.origin.url("/slow.zim"), "kind": "zim", "name": "b.zim"})).await;
    let jid = job["id"].as_str().unwrap();
    rig.wait_state(jid, &["running"]).await;
    let (s, v) = rig.call("DELETE", &format!("/api/library/items/{}", ids[1]), "").await;
    assert_eq!((s, v["error"]["code"].clone()), (409, json!("busy")));
    assert!(zims.join("b.zim").exists());
    assert_eq!(rig.call("DELETE", &format!("/api/library/jobs/{jid}"), "").await.0, 200);
    rig.wait_state(jid, &["cancelled"]).await;
    let (s, _) = rig.call("DELETE", &format!("/api/library/items/{}", ids[1]), "").await;
    assert_eq!(s, 200);
    assert!(!zims.join("b.zim").exists());

    // a library goes with its folder (shard, index, settings)
    let (s, _) = rig.call("DELETE", &format!("/api/library/items/{}", ids[2]), "").await;
    assert_eq!(s, 200);
    assert!(!rig.data().join("app/docs/libraries/guide").exists());
    assert!(rig.data().join("app/docs/libraries/noshard").exists());
    let (_, v) = rig.call("GET", "/api/library/items", "").await;
    assert_eq!(v["result"], json!([]));
    stop(&rig).await;
}
