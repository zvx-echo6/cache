//! A background run's engine stops itself at its time limit (the system may stop the process before the app can close it):
//! it says so in the activity, runs no more rounds, and a close after that is still safe.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::time::Duration;

fn engine(dir: &std::path::Path, lifetime: Option<u64>) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": "Phone", "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "lifetime_secs": lifetime,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn status(e: &SyncEngine) -> Value {
    e.call("status", &json!({})).unwrap()
}

#[test]
fn an_engine_with_a_lifetime_stops_itself_and_closes_safely_after() {
    let tmp = tempfile::tempdir().unwrap();
    let e = engine(&tmp.path().join("a"), Some(1));
    std::thread::sleep(Duration::from_secs(4));
    assert!(status(&e)["log"].to_string().contains("time limit of this run"), "the stop is said in the activity");
    let rounds = status(&e)["rounds"].as_u64().unwrap();
    e.call("sync_now", &json!({})).unwrap();
    std::thread::sleep(Duration::from_millis(1500));
    assert_eq!(status(&e)["rounds"].as_u64().unwrap(), rounds, "no round runs after the limit");
    e.close();
}

#[test]
fn an_engine_without_a_lifetime_runs_on() {
    let tmp = tempfile::tempdir().unwrap();
    let e = engine(&tmp.path().join("a"), None);
    std::thread::sleep(Duration::from_secs(3));
    assert!(!status(&e)["log"].to_string().contains("time limit of this run"));
    e.close();
}
