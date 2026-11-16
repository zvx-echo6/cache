//! A second engine on a folder this process already runs one on does not wait on the first one's store (a background round did, and
//! never came back): it answers at once with an error, says so in the open's log lines, and the folder is free again once the first is
//! closed.

use cache_sync::{take_log, Config, SyncEngine};
use serde_json::json;
use std::time::{Duration, Instant};

fn cfg(dir: &std::path::Path) -> Config {
    serde_json::from_value(json!({"dir": dir, "name": "Phone", "relay": false, "dht": false, "mdns": false, "lookup": false, "interval_secs": 5, "reserve_bytes": 0})).unwrap()
}

#[test]
fn a_second_open_on_the_same_folder_fails_at_once_and_the_folder_is_free_after_the_first_closes() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("sync");
    take_log();
    let first = SyncEngine::open(cfg(&dir)).unwrap();
    let t = Instant::now();
    let second = SyncEngine::open(cfg(&dir));
    assert!(second.is_err(), "the folder is already open in this process");
    assert!(t.elapsed() < Duration::from_secs(2), "answered at once, not after waiting");
    assert!(take_log().iter().any(|l| l.contains("folder already open in this process")), "the open's log says why");
    first.close();
    let again = SyncEngine::open(cfg(&dir)).unwrap();
    again.close();
}
