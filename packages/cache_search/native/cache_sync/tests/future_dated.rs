//! A file dated in the future (written by a device with a wrong clock) still syncs once it has stopped changing, and a file
//! that keeps being rewritten is held back whatever its date says.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{
    path::Path,
    time::{Duration, SystemTime},
};

fn engine(dir: &Path, name: &str) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn wait(what: &str, secs: u64, mut ok: impl FnMut() -> bool) {
    for _ in 0..secs * 4 {
        if ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("timed out waiting for {what}");
}

/// Dates `p` a day ahead, as a device whose clock is a day fast would have.
fn date_ahead(p: &Path) {
    let f = std::fs::File::options().write(true).open(p).unwrap();
    f.set_modified(SystemTime::now() + Duration::from_secs(86_400)).unwrap();
}

/// Whether `path` is listed (and not as a delete) in the share's stored index on `dir`.
fn indexed(dir: &Path, id: &str, path: &str) -> bool {
    let Ok(bytes) = std::fs::read(dir.join("index").join(format!("{id}.json"))) else {
        return false;
    };
    let Ok(idx) = serde_json::from_slice::<Value>(&bytes) else {
        return false;
    };
    idx["files"].get(path).map(|e| e["deleted"] != true).unwrap_or(false)
}

#[test]
fn a_file_dated_in_the_future_syncs() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("clock.txt"), "dated tomorrow").unwrap();
    date_ahead(&fa.join("clock.txt"));

    let a = engine(&da, "Desk");
    let b = engine(&db, "Phone");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&a, "sync_now", json!({}));
    wait("the future-dated file in A's index", 60, || indexed(&da, &id, "clock.txt"));

    call(&b, "sync_now", json!({}));
    wait("the offer on B", 30, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));
    wait("the future-dated file on B", 60, || std::fs::read_to_string(fb.join("clock.txt")).map(|s| s == "dated tomorrow").unwrap_or(false));
    a.close();
    b.close();
}

#[test]
fn a_future_dated_file_still_being_rewritten_is_held_back() {
    let tmp = tempfile::tempdir().unwrap();
    let da = tmp.path().join("a");
    let fa = tmp.path().join("folder-a");
    std::fs::create_dir_all(&fa).unwrap();
    let growing = fa.join("growing.txt");
    std::fs::write(&growing, "0").unwrap();
    date_ahead(&growing);

    let a = engine(&da, "Desk");
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    // Rewritten every second for well over the settling time, with rounds running all the while: never listed.
    let mut text = String::from("0");
    for i in 0..14 {
        call(&a, "sync_now", json!({}));
        std::thread::sleep(Duration::from_secs(1));
        assert!(!indexed(&da, &id, "growing.txt"), "a file still being rewritten was listed (second {i})");
        text.push_str(" more");
        std::fs::write(&growing, &text).unwrap();
        date_ahead(&growing);
    }
    // Left alone, it settles and is listed.
    wait("the file in A's index once it stopped changing", 60, || {
        call(&a, "sync_now", json!({}));
        indexed(&da, &id, "growing.txt")
    });
    a.close();
}
