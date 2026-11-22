//! cs_live_fetch and cs_live_fetch_start for a source that needs a key, asked the way the app asks (Update now, the background
//! run, "Where I am"): the request names the source, the place and the time, and no key. The key set with cs_live_set_key is
//! used; a key in the request comes first (the key check of the setup page); and no key is in anything returned or stored.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::job::Job;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU16, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const T0: &str = "2026-11-07T12:40:00-07:00";
const SOURCE: &str = "own-creek-level-at-the-bridge";
/// The key the host holds: no output and no file may contain it.
const HELD: &str = "SENTINEL-HELD-KEY-4d1b-do-not-leak";
/// A key given in a request.
const GIVEN: &str = "SENTINEL-GIVEN-KEY-a07c-do-not-leak";

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn fixture(name: &str) -> String {
    std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../cache_live/tests/fixtures").join(name)).unwrap()
}

/// A server on this machine: it answers every request with the recorded gauge answer (or with `status` when that is not 200)
/// and notes the request lines.
struct Server {
    base: String,
    asked: Arc<Mutex<Vec<String>>>,
    status: Arc<AtomicU16>,
}

fn serve() -> Server {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let s = Server { base: format!("http://{}", l.local_addr().unwrap()), asked: Arc::default(), status: Arc::new(AtomicU16::new(200)) };
    let (asked, status) = (s.asked.clone(), s.status.clone());
    let body = fixture("own_source_response.json");
    std::thread::spawn(move || {
        for c in l.incoming() {
            let Ok(mut c) = c else { break };
            let mut raw = Vec::new();
            let mut buf = [0u8; 2048];
            while !raw.windows(4).any(|w| w == b"\r\n\r\n") {
                match c.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => raw.extend_from_slice(&buf[..n]),
                }
            }
            asked.lock().unwrap().push(String::from_utf8_lossy(&raw).lines().next().unwrap_or("").to_string());
            let reply = match status.load(Ordering::SeqCst) {
                200 => format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()),
                code => format!("HTTP/1.1 {code} Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"),
            };
            let _ = c.write_all(reply.as_bytes());
        }
    });
    s
}

fn error_of(h: *mut Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_last_error(h) }).expect("an error")).unwrap()
}

fn wait(j: *mut Job) -> Value {
    let t = Instant::now();
    loop {
        let p: Value = serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap();
        if p["state"] != "running" {
            return p;
        }
        assert!(t.elapsed() < Duration::from_secs(30), "{p}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn a_fetch_whose_request_has_no_key_uses_the_key_set_for_the_source() {
    let srv = serve();
    let dir: PathBuf = std::env::temp_dir().join(format!("cs-livekey-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("sources")).unwrap();
    std::fs::write(dir.join("sources").join(format!("{SOURCE}.json")), fixture("own_source_def.json").replace("https://sensors.example.org", &srv.base)).unwrap();
    let cfg = json!({"sources": [], "live": {"db_path": dir.join("live.sqlite"), "sources_dir": dir.join("sources")}});
    let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
    assert!(!h.is_null(), "cs_open: {:?}", take(unsafe { cs_last_error(std::ptr::null_mut()) }));
    // what the app sends: the source, the place and the time (forced, so every call downloads)
    let place = json!({"key": "at:42.54,-113.79", "name": "current location", "lat": 42.536, "lon": -113.792});
    let req = json!({"source": SOURCE, "place": place, "now": T0, "force": true}).to_string();
    let asked = || srv.asked.lock().unwrap().clone();
    let mut seen: Vec<String> = Vec::new();

    // no key anywhere: refused before anything is sent
    assert!(unsafe { cs_live_fetch(h, cstr(&req).as_ptr()) }.is_null());
    assert_eq!(error_of(h)["code"], "key_missing");
    assert!(asked().is_empty(), "nothing is sent without the key");

    // the host hands the key over once; the same request now downloads with it
    assert_eq!(unsafe { cs_live_set_key(h, cstr(SOURCE).as_ptr(), cstr(HELD).as_ptr()) }, 0);
    let out = take(unsafe { cs_live_fetch(h, cstr(&req).as_ptr()) }).unwrap_or_else(|| panic!("the fetch failed: {}", error_of(h)));
    let v: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(v["fetched"], true);
    assert_eq!(v["items"][0]["label"], "Water level 1.42");
    assert_eq!(asked().len(), 1);
    assert!(asked()[0].contains(&format!("key={HELD}")), "{:?}", asked());
    seen.push(out);

    // the same on a thread of its own (cs_live_fetch_start), which is how the app's update downloads
    let j = unsafe { cs_live_fetch_start(h, cstr(&req).as_ptr()) };
    assert!(!j.is_null(), "{:?}", take(unsafe { cs_last_error(h) }));
    let p = wait(j);
    unsafe { cs_job_free(j) };
    assert_eq!(p["state"], "done", "{p}");
    assert_eq!(p["result"]["fetched"], true);
    assert_eq!(asked().len(), 2);
    assert!(asked()[1].contains(&format!("key={HELD}")), "{:?}", asked());
    seen.push(p.to_string());

    // a key in the request comes first (the setup page checks a key before it is saved)
    let with = json!({"source": SOURCE, "place": place, "now": T0, "force": true, "api_key": GIVEN}).to_string();
    seen.push(take(unsafe { cs_live_fetch(h, cstr(&with).as_ptr()) }).unwrap_or_else(|| panic!("the fetch failed: {}", error_of(h))));
    assert!(asked()[2].contains(&format!("key={GIVEN}")) && !asked()[2].contains(HELD), "{:?}", asked());

    // a provider that refuses: the error and the recorded failure do not hold the key
    srv.status.store(403, Ordering::SeqCst);
    assert!(unsafe { cs_live_fetch(h, cstr(&req).as_ptr()) }.is_null());
    let e = error_of(h);
    assert_eq!(e["code"], "fetch_failed", "{e}");
    seen.push(e.to_string());
    let get = json!({"source": SOURCE, "place": place, "now": T0}).to_string();
    let stored = take(unsafe { cs_live_get(h, cstr(&get).as_ptr()) }).unwrap();
    assert_eq!(serde_json::from_str::<Value>(&stored).unwrap()["last_error"]["code"], "fetch_failed");
    seen.push(stored);
    seen.push(take(unsafe { cs_status(h) }).unwrap_or_default());
    srv.status.store(200, Ordering::SeqCst);

    // the key cleared: refused again, and nothing more is sent
    let sent = asked().len();
    assert_eq!(unsafe { cs_live_set_key(h, cstr(SOURCE).as_ptr(), std::ptr::null()) }, 0);
    assert!(unsafe { cs_live_fetch(h, cstr(&req).as_ptr()) }.is_null());
    assert_eq!(error_of(h)["code"], "key_missing");
    assert_eq!(asked().len(), sent);

    unsafe { cs_close(h) };
    for s in &seen {
        assert!(!s.contains(HELD) && !s.contains(GIVEN), "a key leaked into: {s}");
    }
    // and no key is in the database, its journal or anything else written beside it
    for f in std::fs::read_dir(&dir).unwrap().flatten().filter(|f| f.path().is_file()) {
        let bytes = String::from_utf8_lossy(&std::fs::read(f.path()).unwrap()).into_owned();
        assert!(!bytes.contains(HELD) && !bytes.contains(GIVEN), "a key is stored in {:?}", f.path());
    }
    let _ = std::fs::remove_dir_all(&dir);
}
