//! cs_live_fetch_start: cs_live_fetch as a job on a thread of its own, so a weather download never holds the app's one core
//! worker (build 46). Its answer and its errors are cs_live_fetch's.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::job::Job;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::ptr;
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

fn error_of(h: *mut Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_last_error(h) }).expect("an error")).unwrap()
}

fn open(cfg: Value) -> *mut Handle {
    let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
    assert!(!h.is_null(), "cs_open: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    h
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
fn a_live_fetch_job_fails_as_the_fetch_does_and_needs_the_live_section() {
    let dir: PathBuf = std::env::temp_dir().join(format!("cs-livejob-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("sources")).unwrap();
    let h = open(json!({"sources": [], "live": {"db_path": dir.join("live.sqlite"), "sources_dir": dir.join("sources")}}));
    let req = json!({"source": "nope", "place": {"key": "at:42.50,-113.80", "name": "here", "lat": 42.5, "lon": -113.8}}).to_string();

    // the fetch itself, on the caller's thread
    assert!(unsafe { cs_live_fetch(h, cstr(&req).as_ptr()) }.is_null());
    let direct = error_of(h);
    assert_eq!(direct["code"], "not_found");

    // the same as a job: started at once, failed with the same error
    let j = unsafe { cs_live_fetch_start(h, cstr(&req).as_ptr()) };
    assert!(!j.is_null(), "{:?}", take(unsafe { cs_last_error(h) }));
    let p = wait(j);
    unsafe { cs_job_free(j) };
    assert_eq!(p["state"], "failed", "{p}");
    assert_eq!(p["error"]["code"], direct["code"]);
    assert_eq!(p["error"]["message"], direct["message"]);

    // a bad request is the job's failure too
    let j = unsafe { cs_live_fetch_start(h, cstr("{\"nope\":1}").as_ptr()) };
    assert!(!j.is_null());
    assert_eq!(wait(j)["error"]["code"], "bad_json");
    unsafe { cs_job_free(j) };
    unsafe { cs_close(h) };

    // no "live" section: no job
    let h = open(json!({"sources": []}));
    assert!(unsafe { cs_live_fetch_start(h, cstr(&req).as_ptr()) }.is_null());
    assert_eq!(error_of(h)["code"], "not_configured");
    unsafe { cs_close(h) };
    let _ = std::fs::remove_dir_all(&dir);
}
