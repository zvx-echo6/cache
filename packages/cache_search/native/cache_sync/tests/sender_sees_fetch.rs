//! A device that only sends sees the other one fetching from it: the status of a linked device says so while the transfer runs.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 3600, "reserve_bytes": 0,
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

fn fetching(e: &SyncEngine) -> Value {
    call(e, "status", json!({}))["peers"][0]["fetching"].clone()
}

#[test]
fn the_sender_sees_the_other_device_fetching_until_it_is_done() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("video.bin"), vec![7u8; 1_000_000]).unwrap();

    let a = engine(&da, "Desk");
    let b = engine(&db, "Phone");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    let id = call(&a, "share_add", json!({"path": fa, "name": "Videos"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 30, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));

    // B's fetch is held part way: B is fetching and A is only sending.
    std::fs::write(db.join("hold-fetch"), b"").unwrap();
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));
    wait("B to hold its fetch", 30, || db.join("hold-fetch.held").exists());
    assert!(call(&b, "status", json!({}))["transfer"].is_object(), "B reports its own transfer");
    assert_eq!(fetching(&a), Value::Null, "nothing is known until A asks B");
    wait("A to see B fetching", 30, || {
        call(&a, "sync_now", json!({}));
        fetching(&a).is_object()
    });
    let f = fetching(&a);
    assert_eq!(f["share"], id.as_str());
    assert_eq!(f["size"], 1_000_000);
    assert!(f.get("path").is_none(), "the path is not shared");
    assert_eq!(call(&a, "status", json!({}))["transfer"], Value::Null, "A itself fetches nothing");

    // B finishes: the next look at B says it fetches nothing.
    std::fs::remove_file(db.join("hold-fetch")).unwrap();
    wait("the file on B", 60, || fb.join("video.bin").exists());
    wait("A to see B idle", 30, || {
        call(&a, "sync_now", json!({}));
        fetching(&a) == Value::Null
    });
    a.close();
    b.close();
}
