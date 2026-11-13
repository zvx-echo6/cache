//! The /api/core proxy against a fake helper (testbin/fake_helper.rs) that speaks the helper's line protocol.

use cache_server::auth::{Auth, Sessions, StoredPassword};
use cache_server::helper::{Helper, HelperConfig};
use cache_server::http::{route, App, Reply};
use cache_server::library::Library;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

struct Dir(PathBuf);
impl Dir {
    fn new(tag: &str) -> Dir {
        let p = std::env::temp_dir().join(format!("cache-test-proxy-{}-{tag}", std::process::id()));
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
}

impl Rig {
    fn log(&self) -> Vec<String> {
        std::fs::read_to_string(self.dir.0.join("ops.log")).unwrap_or_default().lines().map(str::to_string).collect()
    }

    async fn core(&self, body: &str) -> (u16, Value) {
        let r = route(&self.app, "POST", "/api/core", Some(&self.cookie), body.as_bytes()).await;
        (r.status, serde_json::from_slice(&r.body).unwrap())
    }
}

async fn rig(tag: &str, sources: Option<&str>) -> Rig {
    let dir = Dir::new(tag);
    // FAKE_* reach the child through the environment it inherits; the tests use one process-wide log per rig dir, so set them
    // right before each start (the tests in this file run their rigs one after another under LOCK).
    std::env::set_var("FAKE_LOG", dir.0.join("ops.log"));
    std::env::set_var("FAKE_MARKER", dir.0.join("marker"));
    if let Some(s) = sources {
        std::fs::write(dir.0.join("sources.json"), s).unwrap();
    }
    let mut cfg = HelperConfig::new(PathBuf::from(env!("CARGO_BIN_EXE_fake-helper")), PathBuf::from("libfake"), dir.0.join("sources.json"));
    cfg.app_dirs = Some((PathBuf::from("/app/support"), PathBuf::from("/app/docs")));
    cfg.data_dir = Some(PathBuf::from("/var/lib/cache-app"));
    cfg.shim = PathBuf::from("/opt/cache/lib/libvalhalla_shim.so");
    cfg.backoff = vec![Duration::from_millis(50), Duration::from_millis(100)];
    cfg.ready_timeout = Duration::from_secs(10);
    cfg.stop_wait = Duration::from_secs(5);
    let helper = Helper::start(cfg).await;
    let auth = Auth::new(Some(StoredPassword::new("pw").unwrap()), Sessions::load(&dir.0.join("sessions.json")), false);
    let library = Library::new(dir.0.clone(), Some(helper.clone()));
    let embed = cache_server::embed::EmbedService::new(dir.0.clone(), dir.0.join("none.so"));
    let llm = cache_server::llm::LlmService::new(dir.0.clone(), dir.0.join("none.so"), "bge-m3-Q8_0.gguf".into());
    let build = cache_server::libbuild::BuildService::new(dir.0.clone(), library.clone(), Arc::new(embed.clone()), Default::default());
    let app = App { auth: Arc::new(auth), helper: Some(helper), web: dir.0.join("web"), library, embed, llm, build };
    let r: Reply = route(&app, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
    assert_eq!(r.status, 204);
    let cookie = r.headers.iter().find(|(k, _)| *k == "Set-Cookie").unwrap().1.split(';').next().unwrap().to_string();
    Rig { dir, app, cookie }
}

fn open_args(line: &str) -> Value {
    serde_json::from_str(line.strip_prefix("open ").expect("an open line")).unwrap()
}

static LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

#[tokio::test]
async fn needs_sign_in() {
    let _g = LOCK.lock().await;
    let rig = rig("auth", None).await;
    let r = route(&rig.app, "POST", "/api/core", None, br#"{"op":"version","args":{}}"#).await;
    assert_eq!(r.status, 401);
    let v: Value = serde_json::from_slice(&r.body).unwrap();
    assert_eq!(v["ok"], false);
    assert!(v["error"]["code"].is_string() && v["error"]["message"].is_string());
    assert!(rig.log().iter().all(|l| l.starts_with("open ")), "nothing reaches the helper: {:?}", rig.log());
    rig.app.helper.as_ref().unwrap().shutdown().await;
}

#[tokio::test]
async fn forwards_ops_and_answers_open_and_close_itself() {
    let _g = LOCK.lock().await;
    let rig = rig("fwd", Some(r#"[{"kind":"zim","path":"/z/a.zim","index_dir":"/i/a"}]"#)).await;
    assert_eq!(rig.core(r#"{"op":"version","args":{}}"#).await, (200, json!({"ok": true, "result": "fake-1"})));
    assert_eq!(rig.core(r#"{"op":"echo","args":{"q":[1,2,{"a":"b"}]}}"#).await, (200, json!({"ok": true, "result": {"q": [1, 2, {"a": "b"}]}})));
    // args may be left out
    assert_eq!(rig.core(r#"{"op":"status"}"#).await, (200, json!({"ok": true, "result": []})));
    // the helper's own errors come back as HTTP 200 with ok:false
    let (s, v) = rig.core(r#"{"op":"boom","args":{}}"#).await;
    assert_eq!((s, v), (200, json!({"ok": false, "error": {"code": "not_found", "message": "nothing here"}})));
    // /api/status is the status op
    let r = route(&rig.app, "GET", "/api/status", Some(&rig.cookie), b"").await;
    assert_eq!((r.status, serde_json::from_slice::<Value>(&r.body).unwrap()), (200, json!({"ok": true, "result": []})));
    // open, close and setSources are answered here; a tab never replaces the server's source list
    assert_eq!(
        rig.core(r#"{"op":"setSources","args":{"sources":[{"kind":"zim","path":"/evil.zim","index_dir":"/x"}]}}"#).await,
        (200, json!({"ok": true, "result": null}))
    );
    assert_eq!(rig.core(r#"{"op":"open","args":{"sources":[]}}"#).await, (200, json!({"ok": true, "result": null})));
    assert_eq!(rig.core(r#"{"op":"close","args":{}}"#).await, (200, json!({"ok": true, "result": null})));
    assert_eq!(rig.core(r#"{"op":"version","args":{}}"#).await.0, 200);
    // bad requests never reach the helper
    assert_eq!(rig.core("not json").await.0, 400);
    assert_eq!(rig.core(r#"{"args":{}}"#).await.0, 400);
    let log = rig.log();
    // the server's own open, with the server's sources, was the first thing the helper saw and the only open/close
    assert_eq!(open_args(&log[0]), json!({"sources": [{"kind": "zim", "path": "/z/a.zim", "index_dir": "/i/a"}]}));
    assert_eq!(log.iter().filter(|l| l.starts_with("open ") || l.starts_with("close ")).count(), 1, "{log:?}");
    assert!(log.iter().all(|l| !l.starts_with("setSources")), "setSources is not forwarded: {log:?}");
    assert_eq!(log.len(), 1 + 6, "{log:?}");
    rig.app.helper.as_ref().unwrap().shutdown().await;
}

#[tokio::test]
async fn no_sources_file_opens_with_null_sources_and_the_helper_gets_the_app_folders() {
    let _g = LOCK.lock().await;
    let rig = rig("nosrc", None).await;
    assert_eq!(open_args(&rig.log()[0]), json!({"sources": null}));
    assert_eq!(
        rig.core(r#"{"op":"env","args":{}}"#).await,
        (200, json!({"ok": true, "result": {"support": "/app/support", "docs": "/app/docs", "shim": "/opt/cache/lib/libvalhalla_shim.so", "data": "/var/lib/cache-app"}}))
    );
    rig.app.helper.as_ref().unwrap().shutdown().await;
}

#[tokio::test]
async fn the_sharing_ops_need_a_session_and_are_forwarded_to_the_helper() {
    let _g = LOCK.lock().await;
    let rig = rig("sharing", None).await;
    let ops = [
        r#"{"op":"sharing.state","args":{}}"#,
        r#"{"op":"sharing.setup","args":{}}"#,
        r#"{"op":"sharing.set_kind","args":{"kind":"library","on":true}}"#,
        r#"{"op":"sharing.set_item","args":{"kind":"library","key":"library/a.zim","on":false}}"#,
        r#"{"op":"sharing.link_start","args":{"code":"x"}}"#,
        r#"{"op":"sharing.call","args":{"method":"link_code","args":{}}}"#,
    ];
    // without a session none of them reaches the helper
    for body in ops {
        let r = route(&rig.app, "POST", "/api/core", None, body.as_bytes()).await;
        assert_eq!(r.status, 401, "{body}");
    }
    assert!(rig.log().iter().all(|l| l.starts_with("open ")), "{:?}", rig.log());
    // signed in, each one is forwarded as it came (the helper decides what a browser may do)
    for body in ops {
        assert_eq!(rig.core(body).await.0, 200, "{body}");
    }
    let log = rig.log();
    let sent: Vec<&str> = log.iter().filter(|l| l.starts_with("sharing.")).map(|l| l.split(' ').next().unwrap()).collect();
    assert_eq!(sent, ["sharing.state", "sharing.setup", "sharing.set_kind", "sharing.set_item", "sharing.link_start", "sharing.call"], "{log:?}");
    rig.app.helper.as_ref().unwrap().shutdown().await;
}

#[tokio::test]
async fn the_helper_is_started_with_the_public_address_guard_installed() {
    let _g = LOCK.lock().await;
    // a value set in the server's own environment is overridden: the server decides, not whatever started it
    std::env::set_var("CACHE_NET_GUARD", "off");
    let rig = rig("netguard", None).await;
    std::env::remove_var("CACHE_NET_GUARD");
    assert_eq!(rig.core(r#"{"op":"netguard","args":{}}"#).await, (200, json!({"ok": true, "result": "public"})));
    rig.app.helper.as_ref().unwrap().shutdown().await;
}

#[tokio::test]
async fn a_crash_mid_request_gives_503_then_the_helper_comes_back() {
    let _g = LOCK.lock().await;
    let rig = rig("crash", None).await;
    let (s, v) = rig.core(r#"{"op":"crash","args":{}}"#).await;
    assert_eq!(s, 503);
    assert_eq!((v["ok"].clone(), v["error"]["code"].clone()), (json!(false), json!("core_unavailable")));
    // it restarts by itself, with open sent again
    let mut ok = None;
    for _ in 0..100 {
        let (s, v) = rig.core(r#"{"op":"crash","args":{}}"#).await;
        if s == 200 {
            ok = Some(v);
            break;
        }
        assert_eq!(s, 503);
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    assert_eq!(ok, Some(json!({"ok": true, "result": "back"})));
    assert_eq!(rig.log().iter().filter(|l| l.starts_with("open ")).count(), 2, "{:?}", rig.log());
    assert_eq!(rig.core(r#"{"op":"version","args":{}}"#).await.0, 200);
    rig.app.helper.as_ref().unwrap().shutdown().await;
}

#[tokio::test]
async fn a_helper_that_never_starts_gives_503() {
    let _g = LOCK.lock().await;
    let dir = Dir::new("nostart");
    let mut cfg = HelperConfig::new(dir.0.join("no-such-program"), PathBuf::from("x"), dir.0.join("sources.json"));
    cfg.backoff = vec![Duration::from_millis(50)];
    let helper = Helper::start(cfg).await;
    let err = helper.call("version", json!({})).await.unwrap_err();
    assert!(err.contains("not available"), "{err}");
    helper.shutdown().await;
}

#[tokio::test]
async fn a_bad_sources_file_is_reported_not_ignored() {
    let _g = LOCK.lock().await;
    let dir = Dir::new("badsrc");
    std::fs::write(dir.0.join("sources.json"), "{}").unwrap();
    assert!(cache_server::helper::read_sources(&dir.0.join("sources.json")).is_err());
    assert_eq!(cache_server::helper::read_sources(&dir.0.join("none.json")).unwrap(), Value::Null);
}

const ZID: &str = "0f1e2d3c-4b5a-6978-8a9b-0c1d2e3f4a5b";

fn header<'a>(r: &'a Reply, k: &str) -> Option<&'a str> {
    r.headers.iter().find(|(h, _)| h.eq_ignore_ascii_case(k)).map(|(_, v)| v.as_str())
}

#[tokio::test]
async fn zim_serves_entries_sandboxed_with_the_token_alone() {
    let _g = LOCK.lock().await;
    let rig = rig("zim", None).await;
    let r = route(&rig.app, "POST", "/api/zim/token", Some(&rig.cookie), b"").await;
    let v: Value = serde_json::from_slice(&r.body).unwrap();
    let t = v["result"]["token"].as_str().unwrap().to_string();

    // a page: its own mime type, the sandbox, and the frame script added; no cookie is sent
    let r = route(&rig.app, "GET", &format!("/zim/{t}/{ZID}/A/Some%20Page.html"), None, b"").await;
    assert_eq!(r.status, 200);
    assert_eq!(header(&r, "Content-Type"), Some("text/html; charset=utf-8"));
    assert_eq!(header(&r, "Content-Security-Policy"), Some("sandbox allow-scripts allow-popups"));
    assert!(!header(&r, "Content-Security-Policy").unwrap().contains("allow-same-origin"));
    let body = String::from_utf8(r.body).unwrap();
    assert!(body.contains(&format!("page zim:{ZID}/A/Some%20Page.html")), "{body}");
    assert!(body.contains("cacheZim") && body.find("cacheZim").unwrap() < body.find("</body>").unwrap(), "{body}");

    // the query goes to the core as the phone's address has it; a picture's bytes are not touched
    let r = route(&rig.app, "GET", &format!("/zim/{t}/{}/I/pic.png?x=1", ZID.to_uppercase()), None, b"").await;
    assert_eq!(r.status, 200);
    assert_eq!(r.body, vec![0, 1, 2, 250, 255]);
    assert_eq!(header(&r, "Content-Type"), Some("image/png"));
    assert_eq!(header(&r, "Content-Security-Policy"), Some("sandbox allow-scripts allow-popups"));
    assert!(rig.log().iter().any(|l| l == &format!("zimGet {{\"address\":\"zim:{ZID}/I/pic.png?x=1\"}}")), "{:?}", rig.log());

    // text that is not HTML is left alone; a missing entry is a 404; HEAD has no body
    let r = route(&rig.app, "GET", &format!("/zim/{t}/{ZID}/-/style.css"), None, b"").await;
    assert_eq!((r.status, r.body.as_slice(), header(&r, "Content-Type")), (200, &b"plain"[..], Some("text/plain; charset=utf-8")));
    assert_eq!(route(&rig.app, "GET", &format!("/zim/{t}/{ZID}/A/missing.html"), None, b"").await.status, 404);
    let r = route(&rig.app, "HEAD", &format!("/zim/{t}/{ZID}/A/x.html"), None, b"").await;
    assert_eq!((r.status, r.body.len()), (200, 0));

    // the token never reaches the core: the helper saw only addresses
    assert!(rig.log().iter().all(|l| !l.contains(&t)), "{:?}", rig.log());
    // a wrong token reaches nothing
    let before = rig.log().len();
    assert_eq!(route(&rig.app, "GET", &format!("/zim/wrong/{ZID}/A/x.html"), Some(&rig.cookie), b"").await.status, 401);
    assert_eq!(rig.log().len(), before);
    rig.app.helper.as_ref().unwrap().shutdown().await;
}

/// A stand-in for the core's tile server: answers every request with the same shape the real one uses and records the paths.
fn fake_tile_server(seen: Arc<std::sync::Mutex<Vec<String>>>) -> u16 {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let mut s = stream.unwrap();
            let mut buf = [0u8; 2048];
            let n = s.read(&mut buf).unwrap();
            let line = String::from_utf8_lossy(&buf[..n]).lines().next().unwrap_or("").to_string();
            let path = line.split(' ').nth(1).unwrap_or("").to_string();
            seen.lock().unwrap().push(path.clone());
            let (status, extra, body): (&str, &str, &[u8]) = if path.ends_with("/9/9/9") {
                ("503 Service Unavailable", "X-Cache-Status: miss\r\nRetry-After: 5\r\nContent-Type: text/plain\r\n", b"not on this device and no connection")
            } else if path.ends_with("/tilejson.json") {
                ("200 OK", "Content-Type: application/json\r\n", b"{\"tiles\":[]}")
            } else {
                ("200 OK", "Content-Type: application/x-protobuf\r\nX-Cache-Status: downloaded\r\n", &[1, 2, 3, 0, 255])
            };
            let _ = write!(s, "HTTP/1.1 {status}\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n", body.len());
            let _ = s.write_all(body);
        }
    });
    port
}

#[tokio::test]
async fn tiles_are_proxied_behind_the_session_and_only_for_layers() {
    let _g = LOCK.lock().await;
    let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
    let port = fake_tile_server(seen.clone());
    std::env::set_var("FAKE_TILE_PORT", port.to_string());
    let rig = rig("tiles", None).await;

    // no session: refused before anything is asked of the core
    let r = route(&rig.app, "GET", "/api/tiles/layers/base/1/2/3", None, b"").await;
    assert_eq!(r.status, 401);
    assert!(rig.log().iter().all(|l| !l.starts_with("layers")), "{:?}", rig.log());
    assert_eq!(route(&rig.app, "GET", "/api/tiles/layers/base/1/2/3", Some("cache_session=forged"), b"").await.status, 401);

    // a tile: bytes, type and cache status come through; the query is dropped; HEAD has no body
    let c = Some(rig.cookie.as_str());
    let r = route(&rig.app, "GET", "/api/tiles/layers/base/1/2/3.pbf?g=2", c, b"").await;
    assert_eq!((r.status, r.body.as_slice()), (200, &[1u8, 2, 3, 0, 255][..]));
    assert_eq!(header(&r, "Content-Type"), Some("application/x-protobuf"));
    assert_eq!(header(&r, "X-Cache-Status"), Some("downloaded"));
    let r = route(&rig.app, "HEAD", "/api/tiles/layers/base/1/2/3", c, b"").await;
    assert_eq!((r.status, r.body.len()), (200, 0));
    let r = route(&rig.app, "GET", "/api/tiles/layers/base/tilejson.json", c, b"").await;
    assert_eq!((r.status, header(&r, "Content-Type")), (200, Some("application/json")));

    // a tile that may come later keeps its 503 and Retry-After (the map asks again)
    let r = route(&rig.app, "GET", "/api/tiles/layers/base/9/9/9", c, b"").await;
    assert_eq!((r.status, header(&r, "Retry-After"), header(&r, "X-Cache-Status")), (503, Some("5"), Some("miss")));

    // the tile server was asked for its port once, without the `online` option; the paths it saw are the layers paths
    let asks: Vec<String> = rig.log().into_iter().filter(|l| l.starts_with("layers")).collect();
    assert_eq!(asks.len(), 1, "the port is kept: {asks:?}");
    assert!(asks[0].contains("\"op\":\"server\"") && !asks[0].contains("online"), "{asks:?}");
    assert_eq!(seen.lock().unwrap().as_slice(), ["/layers/base/1/2/3.pbf", "/layers/base/1/2/3", "/layers/base/tilejson.json", "/layers/base/9/9/9"]);

    // nothing but layers paths, and not other methods
    for bad in ["/api/tiles/health", "/api/tiles/layers/../../x", "/api/tiles/", "/api/tiles/layers/a%2f..%2fb/1"] {
        assert_eq!(route(&rig.app, "GET", bad, c, b"").await.status, 404, "{bad}");
    }
    assert_eq!(route(&rig.app, "POST", "/api/tiles/layers/base/1/2/3", c, b"").await.status, 405);
    assert_eq!(seen.lock().unwrap().len(), 4, "refused paths never reach the tile server");
    rig.app.helper.as_ref().unwrap().shutdown().await;
}

#[tokio::test]
async fn a_dead_tile_port_gives_502_not_a_hang() {
    let _g = LOCK.lock().await;
    // port 1: nobody listens there; the route asks the core for the port again once, then answers 502
    std::env::set_var("FAKE_TILE_PORT", "1");
    let rig = rig("tiles-dead", None).await;
    let r = route(&rig.app, "GET", "/api/tiles/layers/base/1/2/3", Some(rig.cookie.as_str()), b"").await;
    assert_eq!(r.status, 502);
    assert_eq!(rig.log().iter().filter(|l| l.starts_with("layers")).count(), 2, "{:?}", rig.log());
    rig.app.helper.as_ref().unwrap().shutdown().await;
}
