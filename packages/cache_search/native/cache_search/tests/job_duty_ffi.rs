//! Job pacing (duty): throttling, pause and resume, cancel while paused or idle, cs_job_set, the defaults. The jobs are the
//! `test_pace` kind (items that busy-work a fixed time and then call the pace point, like an index loop).

use cache_search::ffi::*;
use cache_search::job::Job;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
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

fn start(kind: &str, params: Value) -> *mut Job {
    let j = unsafe { cs_job_start(cstr(kind).as_ptr(), cstr(&params.to_string()).as_ptr()) };
    assert!(!j.is_null(), "{kind}: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    j
}

fn progress(j: *mut Job) -> Value {
    serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap()
}

fn set(j: *mut Job, v: Value) -> Option<Value> {
    take(unsafe { cs_job_set(j, cstr(&v.to_string()).as_ptr()) }).map(|s| serde_json::from_str(&s).unwrap())
}

fn wait_end(j: *mut Job, limit: Duration) -> Value {
    let t0 = Instant::now();
    loop {
        let p = progress(j);
        if p["state"] != "running" {
            return p;
        }
        assert!(t0.elapsed() < limit, "job did not end: {p}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn timed(items: u64, item_ms: u64, duty: Option<Value>) -> Duration {
    let mut p = json!({"items": items, "item_ms": item_ms});
    if let Some(d) = duty {
        p["duty"] = d;
    }
    let t0 = Instant::now();
    let j = start("test_pace", p);
    let end = wait_end(j, Duration::from_secs(60));
    unsafe { cs_job_free(j) };
    assert_eq!(end["state"], "done", "{end}");
    t0.elapsed()
}

#[test]
fn duty_slows_a_job_measurably_and_work_ms_zero_does_not() {
    let full = timed(20, 10, Some(json!({"work_ms": 0})));
    // 20 items of 10 ms with 100 ms idle after every 50 ms of work: about 4 idles
    let slow = timed(20, 10, Some(json!({"work_ms": 50, "idle_ms": 100, "threads": 1})));
    assert!(slow >= full + Duration::from_millis(300), "full {full:?} slow {slow:?}");
    // the same job started again unthrottled takes the same time as before (within noise)
    let again = timed(20, 10, Some(json!({"work_ms": 0})));
    assert!(
        again < full + Duration::from_millis(150) && full < again + Duration::from_millis(150),
        "{full:?} {again:?}"
    );
}

#[test]
fn defaults_are_gentle_for_index_kinds_and_unthrottled_for_the_rest() {
    let j = start("test_pace", json!({"items": 1}));
    let p = wait_end(j, Duration::from_secs(10));
    assert_eq!(p["duty"], json!({"work_ms": 200, "idle_ms": 200, "threads": 1}), "{p}");
    assert_eq!(p["effective"], p["duty"]);
    assert_eq!(p["auto"], true);
    assert_eq!(p["paused"], false);
    unsafe { cs_job_free(j) };
    // a kind that is not index work: unthrottled
    let out = std::env::temp_dir().join(format!("cs-duty-template-{}.tar", std::process::id()));
    let j = start("library_template", json!({"out_path": out}));
    let p = wait_end(j, Duration::from_secs(60));
    assert_eq!(p["duty"], json!({"work_ms": 0, "idle_ms": 0, "threads": null}), "{p}");
    unsafe { cs_job_free(j) };
    let _ = std::fs::remove_file(&out);
    // "duty" fields left out keep the kind's defaults
    let j = start("test_pace", json!({"items": 1, "duty": {"work_ms": 0}}));
    let p = wait_end(j, Duration::from_secs(10));
    assert_eq!(p["duty"], json!({"work_ms": 0, "idle_ms": 200, "threads": 1}), "{p}");
    unsafe { cs_job_free(j) };
    // a bad duty is refused at start
    let j = unsafe { cs_job_start(cstr("test_pace").as_ptr(), cstr(r#"{"items":1,"duty":{"threads":0}}"#).as_ptr()) };
    assert!(j.is_null());
}

#[test]
fn pause_blocks_and_resume_continues() {
    let j = start("test_pace", json!({"items": 100_000, "item_ms": 1, "duty": {"work_ms": 0}}));
    std::thread::sleep(Duration::from_millis(100));
    let s = set(j, json!({"paused": true})).unwrap();
    assert_eq!(s["paused"], true);
    std::thread::sleep(Duration::from_millis(100)); // the item in flight finishes
    let a = progress(j);
    assert_eq!(a["paused"], true);
    std::thread::sleep(Duration::from_millis(300));
    let b = progress(j);
    assert_eq!(a["done"], b["done"], "a paused job does not advance: {a} {b}");
    assert_eq!(b["state"], "running");
    let s = set(j, json!({"paused": false})).unwrap();
    assert_eq!(s["paused"], false);
    std::thread::sleep(Duration::from_millis(200));
    let c = progress(j);
    assert!(c["done"].as_u64().unwrap() > b["done"].as_u64().unwrap() + 20, "{b} {c}");
    unsafe { cs_job_cancel(j) };
    assert_eq!(wait_end(j, Duration::from_secs(5))["state"], "cancelled");
    unsafe { cs_job_free(j) };
}

#[test]
fn cancel_while_paused_or_idle_ends_promptly() {
    // idling: 1 ms of work, then a minute of idle
    let j = start("test_pace", json!({"items": 1000, "item_ms": 2, "duty": {"work_ms": 1, "idle_ms": 60_000}}));
    std::thread::sleep(Duration::from_millis(150));
    assert_eq!(progress(j)["state"], "running");
    let t0 = Instant::now();
    unsafe { cs_job_cancel(j) };
    let p = wait_end(j, Duration::from_secs(5));
    assert_eq!(p["state"], "cancelled");
    assert!(t0.elapsed() < Duration::from_millis(500), "{:?}", t0.elapsed());
    unsafe { cs_job_free(j) };
    // paused
    let j = start("test_pace", json!({"items": 100_000, "item_ms": 1, "duty": {"work_ms": 0}}));
    set(j, json!({"paused": true})).unwrap();
    std::thread::sleep(Duration::from_millis(150));
    let t0 = Instant::now();
    unsafe { cs_job_cancel(j) };
    assert_eq!(wait_end(j, Duration::from_secs(5))["state"], "cancelled");
    assert!(t0.elapsed() < Duration::from_millis(500), "{:?}", t0.elapsed());
    unsafe { cs_job_free(j) };
    // freeing a paused job also returns promptly
    let j = start("test_pace", json!({"items": 100_000, "item_ms": 1, "duty": {"work_ms": 0}}));
    set(j, json!({"paused": true})).unwrap();
    std::thread::sleep(Duration::from_millis(100));
    let t0 = Instant::now();
    unsafe { cs_job_free(j) };
    assert!(t0.elapsed() < Duration::from_millis(500));
}

#[test]
fn a_duty_change_applies_to_a_job_that_is_already_idling() {
    let j = start("test_pace", json!({"items": 50, "item_ms": 2, "duty": {"work_ms": 1, "idle_ms": 60_000}}));
    std::thread::sleep(Duration::from_millis(100));
    let d = progress(j)["done"].as_u64().unwrap();
    assert!(d < 5);
    let s = set(j, json!({"work_ms": 0, "idle_ms": 0})).unwrap();
    assert_eq!(s["duty"]["work_ms"], 0);
    let p = wait_end(j, Duration::from_secs(5));
    assert_eq!(p["state"], "done", "{p}");
    unsafe { cs_job_free(j) };
}

#[test]
fn cs_job_set_errors_are_clean_and_auto_can_be_switched() {
    // no job
    assert!(take(unsafe { cs_job_set(ptr::null_mut(), cstr("{}").as_ptr()) }).is_none());
    let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(ptr::null_mut()) }).unwrap()).unwrap();
    assert_eq!(e["code"], "bad_json");
    let j = start("test_pace", json!({"items": 100_000, "item_ms": 1, "duty": {"work_ms": 0}}));
    for bad in ["not json", "[1]", r#"{"work_ms":"x"}"#, r#"{"threads":0}"#, r#"{"paused":"yes"}"#, r#"{"auto":3}"#] {
        assert!(take(unsafe { cs_job_set(j, cstr(bad).as_ptr()) }).is_none(), "{bad}");
        let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(ptr::null_mut()) }).unwrap()).unwrap();
        assert_eq!(e["code"], "bad_json", "{bad}");
    }
    assert!(take(unsafe { cs_job_set(j, ptr::null()) }).is_none());
    // the job is untouched by the failures; auto goes off and on, and the state comes back
    let s = set(j, json!({"auto": false, "work_ms": 100, "idle_ms": 10})).unwrap();
    assert_eq!(s["auto"], false);
    assert_eq!(s["duty"], json!({"work_ms": 100, "idle_ms": 10, "threads": 1}));
    assert_eq!(s["effective"], s["duty"]);
    let p = progress(j);
    assert_eq!((p["auto"].clone(), p["duty"].clone()), (json!(false), s["duty"].clone()));
    assert_eq!(set(j, json!({"auto": true})).unwrap()["auto"], true);
    // a call that sets nothing returns the current state
    assert_eq!(set(j, json!({})).unwrap()["duty"], s["duty"]);
    unsafe { cs_job_cancel(j) };
    wait_end(j, Duration::from_secs(5));
    unsafe { cs_job_free(j) };
}
