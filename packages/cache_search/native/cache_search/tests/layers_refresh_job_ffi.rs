//! cs_layers_refresh_start: cs_layers_refresh as a job on a thread of its own. At every app start the catalogue refresh ran on the
//! app's one core worker and held it for seconds over the network (once for an hour, across a suspension), with saved places,
//! live data and searches queued behind it. A slow catalogue now holds only its own thread.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::job::Job;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::ptr;
use std::sync::mpsc;
use std::time::{Duration, Instant};

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

fn open(cfg: Value) -> *mut Handle {
    let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
    assert!(!h.is_null(), "cs_open: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    h
}

fn progress(j: *mut Job) -> Value {
    serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap()
}

fn list(h: *mut Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_layers_list(h) }).expect("cs_layers_list")).unwrap()
}

fn ids(l: &Value) -> Vec<String> {
    l["layers"].as_array().unwrap().iter().map(|e| e["definition"]["id"].as_str().unwrap().to_string()).collect()
}

/// A catalogue host that answers only when `release` is sent: the slow network of a phone.
fn slow_catalogue(release: mpsc::Receiver<()>) -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    std::thread::spawn(move || {
        let Ok((mut s, _)) = l.accept() else { return };
        let mut buf = [0u8; 4096];
        let _ = s.read(&mut buf);
        let _ = release.recv_timeout(Duration::from_secs(30));
        let body = json!([{
            "format": 1, "id": "fromcat", "title": "fromcat", "kind": "vector", "transform": "as_is",
            "source": {"type": "xyz", "url": "https://tiles.test/{z}/{x}/{y}", "minzoom": 0, "maxzoom": 12, "tile_format": "mvt"},
            "attribution": "test", "license": "test", "update": {"version": "1"}
        }])
        .to_string();
        let _ = write!(s, "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
    });
    port
}

#[test]
fn a_slow_catalogue_refresh_runs_as_a_job_and_holds_no_other_call() {
    let dir = std::env::temp_dir().join(format!("cs-layers-refresh-job-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let (release, wait) = mpsc::channel();
    let port = slow_catalogue(wait);
    let h = open(json!({"sources": [], "layers": {
        "dir": dir.join("layers"), "defs_dirs": [], "catalogue_urls": [format!("http://127.0.0.1:{port}/catalogue.json")],
        "cache_max_bytes": 1 << 20, "online": true
    }}));

    let t = Instant::now();
    let j = unsafe { cs_layers_refresh_start(h) };
    assert!(!j.is_null(), "{:?}", take(unsafe { cs_last_error(h) }));
    assert!(t.elapsed() < Duration::from_secs(2), "the start returns at once");
    // The catalogue host has not answered: the job runs, and the handle answers other calls meanwhile.
    std::thread::sleep(Duration::from_millis(300));
    assert_eq!(progress(j)["state"], "running");
    let t = Instant::now();
    assert!(!ids(&list(h)).contains(&"fromcat".to_string()));
    assert!(t.elapsed() < Duration::from_secs(2), "a list waits for nothing");

    release.send(()).unwrap();
    let t = Instant::now();
    let p = loop {
        let p = progress(j);
        if p["state"] != "running" {
            break p;
        }
        assert!(t.elapsed() < Duration::from_secs(30), "{p}");
        std::thread::sleep(Duration::from_millis(10));
    };
    unsafe { cs_job_free(j) };
    assert_eq!(p["state"], "done", "{p}");
    assert_eq!(p["result"]["catalogues"][0]["layers"], 1, "{p}");
    // The handle's own catalogue has the new layer.
    assert!(ids(&list(h)).contains(&"fromcat".to_string()));
    unsafe { cs_close(h) };

    // No "layers" section: no job.
    let h = open(json!({"sources": []}));
    assert!(unsafe { cs_layers_refresh_start(h) }.is_null());
    let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(h) }).unwrap()).unwrap();
    assert_eq!(e["code"], "not_configured");
    unsafe { cs_close(h) };
    let _ = std::fs::remove_dir_all(&dir);
}
