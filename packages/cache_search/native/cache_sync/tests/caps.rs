//! What a device says about itself to the linked devices (`Config::caps`, `set_caps`): the app's facts, sent with the file list and
//! shown for each linked device in the status; a device that sends none (an older version) shows none.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str, caps: Value) -> SyncEngine {
    let cfg = json!({"dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false, "interval_secs": 5, "reserve_bytes": 0, "caps": caps});
    SyncEngine::open(serde_json::from_value::<Config>(cfg).unwrap()).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn id(e: &SyncEngine) -> String {
    call(e, "status", json!({}))["id"].as_str().unwrap().to_string()
}

fn caps_of(e: &SyncEngine, of: &str) -> Value {
    call(e, "status", json!({}))["peers"].as_array().unwrap().iter().find(|p| p["id"] == of).map(|p| p["caps"].clone()).unwrap_or(Value::Null)
}

fn until(what: &str, secs: u64, all: &[&SyncEngine], mut ok: impl FnMut() -> bool) {
    for i in 0..secs * 2 {
        if ok() {
            return;
        }
        if i % 2 == 0 {
            for e in all {
                call(e, "sync_now", json!({}));
            }
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    panic!("timed out waiting for {what}");
}

#[test]
fn a_device_tells_the_others_its_caps_and_can_change_them() {
    let tmp = tempfile::tempdir().unwrap();
    let a = engine(&tmp.path().join("a"), "Desk", json!({"notebook_format": 2}));
    let b = engine(&tmp.path().join("b"), "Phone", Value::Null);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    let (ia, ib) = (id(&a), id(&b));
    until("B sees A's caps", 60, &[&a, &b], || caps_of(&b, &ia) == json!({"notebook_format": 2}));
    assert_eq!(caps_of(&a, &ib), Value::Null, "a device that sends none shows none");
    call(&a, "set_caps", json!({"caps": {"notebook_format": 2, "notebook_legacy": false}}));
    until("B sees A's new caps", 60, &[&a, &b], || caps_of(&b, &ia) == json!({"notebook_format": 2, "notebook_legacy": false}));
    call(&b, "set_caps", json!({"caps": {"notebook_format": 2}}));
    until("A sees B's caps", 60, &[&a, &b], || caps_of(&a, &ib) == json!({"notebook_format": 2}));
}
