//! A panic inside one sync round ends that round only: it is said in the activity, and later rounds still sync.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

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

fn log(e: &SyncEngine) -> String {
    call(e, "status", json!({}))["log"].to_string()
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
fn a_round_that_panics_is_noted_and_the_next_round_still_syncs() {
    let tmp = tempfile::tempdir().unwrap();
    let da = tmp.path().join("a");
    let fa = tmp.path().join("folder-a");
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("before.txt"), "before").unwrap();

    let a = engine(&da, "Desk");
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    wait("the first file in A's index", 60, || indexed(&da, &id, "before.txt"));

    // The next round panics (once).
    let marker = da.join("panic-round");
    std::fs::write(&marker, b"").unwrap();
    call(&a, "sync_now", json!({}));
    wait("the panic in the activity", 60, || !marker.exists() && log(&a).contains("Sync stopped on an internal error and started again: test: a round panicked"));

    // Rounds carry on: a file made after the panic is listed.
    std::fs::write(fa.join("after.txt"), "after").unwrap();
    wait("a file made after the panic in A's index", 60, || {
        call(&a, "sync_now", json!({}));
        indexed(&da, &id, "after.txt")
    });
    a.close();
}
