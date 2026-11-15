//! Opening the engine says each step to the function the app gave (`set_log`), in order, with the time since the open began.
//! One test only: the sink is process-wide.

use cache_sync::{set_log, Config, SyncEngine};
use serde_json::json;
use std::ffi::{c_char, CString};
use std::sync::Mutex;

static LINES: Mutex<Vec<String>> = Mutex::new(Vec::new());

extern "C" fn collect(line: *const c_char) {
    // The line is the callee's to free, as the app's does with cs_free_string.
    let s = unsafe { CString::from_raw(line as *mut c_char) }.to_string_lossy().into_owned();
    LINES.lock().unwrap().push(s);
}

#[test]
fn an_open_says_its_steps_in_order() {
    let tmp = tempfile::tempdir().unwrap();
    let cfg: Config = serde_json::from_value(json!({
        "dir": tmp.path().join("a"), "name": "Phone", "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0,
    }))
    .unwrap();
    set_log(Some(collect));
    let e = SyncEngine::open(cfg).unwrap();
    set_log(None);
    e.close();
    let lines = LINES.lock().unwrap().clone();
    for l in &lines {
        println!("{l}");
    }
    let steps = ["started", "links loaded", "identity loaded", "endpoint bound", "blob store opened", "state saved", "done"];
    assert_eq!(lines.len(), steps.len(), "{lines:?}");
    for (l, want) in lines.iter().zip(steps) {
        assert!(l.starts_with(&format!("sync open: {want} +")) && l.ends_with(" ms"), "{l}");
    }
    let ms: Vec<u64> = lines.iter().map(|l| l.rsplit_once('+').unwrap().1.trim_end_matches(" ms").parse().unwrap()).collect();
    assert!(ms.windows(2).all(|w| w[0] <= w[1]), "times only grow: {ms:?}");
}
