//! A linked device's last seen time and name: kept across a restart, and following a rename on the other device.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine_on(dir: &Path, name: &str, port: Option<u16>) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 3600, "reserve_bytes": 0, "port": port,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn peer(e: &SyncEngine) -> Value {
    call(e, "status", json!({}))["peers"][0].clone()
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

/// Waits for `ok`, asking both devices to sync again about every 2 seconds. The app syncs again and again, and a restarted device
/// (no relay, DHT, mDNS or lookup here) learns where the other one is only when that one connects to it, so `other` syncing is
/// what lets `e` find it; one request alone can wait for ever. On a timeout the panic says what `e` saw of the other device.
fn wait_syncing(what: &str, secs: u64, e: &SyncEngine, other: &SyncEngine, mut ok: impl FnMut() -> bool) {
    for i in 0..secs * 4 {
        if ok() {
            return;
        }
        if i % 8 == 0 {
            call(other, "sync_now", json!({}));
            call(e, "sync_now", json!({}));
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("timed out waiting for {what}; the device sees the other one as {}", peer(e));
}

#[test]
fn last_seen_survives_a_restart_and_a_rename_follows() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let a = engine_on(&da, "Android device", None);
    let b = engine_on(&db, "Phone", None);
    let b_port = b.port().expect("B listens on a port");

    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    // Linked, never reached since: nothing to show yet.
    assert_eq!(peer(&b)["last_seen"], Value::Null);
    assert_eq!(peer(&b)["name"], "Android device");

    call(&b, "sync_now", json!({}));
    wait("B to reach A", 30, || peer(&b)["last_seen"].is_u64());
    assert_eq!(peer(&b)["via"], "direct");

    // B restarts: the time is still there before the first round says anything.
    let seen = peer(&b)["last_seen"].as_u64().unwrap();
    // The round saves it just after it notes it; wait for the file before stopping.
    wait("the time in the saved file", 30, || std::fs::read_to_string(db.join("sync.json")).map(|t| t.contains("last_seen")).unwrap_or(false));
    b.close();
    let b = engine_on(&db, "Phone", Some(b_port));
    // What is saved is at most a minute behind what was shown (the write is throttled).
    assert!(peer(&b)["last_seen"].as_u64().is_some_and(|t| t + 60_000 >= seen), "last seen survives a restart");
    assert_eq!(peer(&b)["via"], "direct");

    // A is renamed; B takes the new name on its next round.
    call(&a, "set_name", json!({"name": "Pixel nine"}));
    wait_syncing("B to take A's new name", 90, &b, &a, || peer(&b)["name"] == "Pixel nine");
    b.close();
    let b = engine_on(&db, "Phone", Some(b_port));
    assert_eq!(peer(&b)["name"], "Pixel nine", "the new name was saved");
    b.close();
    a.close();
}
