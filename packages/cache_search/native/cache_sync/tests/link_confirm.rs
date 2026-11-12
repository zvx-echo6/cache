//! A link made by showing a code waits to be confirmed by the other device: confirmed at once in a normal link, removed when
//! the other device never comes back, and never in doubt for links saved by older versions.

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

fn peers(e: &SyncEngine) -> Vec<Value> {
    call(e, "status", json!({}))["peers"].as_array().cloned().unwrap_or_default()
}

#[test]
fn a_normal_link_is_confirmed_on_both_devices() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let a = engine(&da, "Desk");
    let b = engine(&db, "Phone");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    // The device that read the code is never in doubt; the one that showed it is confirmed by the first contact.
    assert_eq!(peers(&b)[0]["unconfirmed"], false);
    wait("the link confirmed on the device that showed the code", 60, || {
        call(&b, "sync_now", json!({}));
        peers(&a).first().map(|p| p["unconfirmed"] == false).unwrap_or(false)
    });
    assert_eq!(peers(&b)[0]["unconfirmed"], false);
    wait("the saved link without the mark", 30, || std::fs::read_to_string(da.join("sync.json")).map(|t| t.contains("\"peers\":[{") && !t.contains("unconfirmed")).unwrap_or(false));
    a.close();
    b.close();
}

#[test]
fn a_link_the_other_device_never_confirms_is_removed() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let folder = tmp.path().join("folder");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("note.txt"), "note").unwrap();
    let a = engine(&da, "Desk");
    let b = engine(&db, "Phone");
    // The wait for a confirmation is two seconds here (counted from when the link is made).
    std::fs::write(da.join("confirm-window-ms"), "2000").unwrap();
    // A's round is held in its rescan, so A asks B for nothing; B may not use the network, so its rounds ask A for nothing.
    std::fs::write(da.join("hold-rescan"), b"").unwrap();
    call(&a, "share_add", json!({"path": folder, "name": "Family"}));
    wait("A's round held", 60, || da.join("hold-rescan.held").exists());
    call(&b, "set_policy", json!({"network": false}));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    assert_eq!(peers(&a).len(), 1);
    assert_eq!(peers(&a)[0]["unconfirmed"], true, "made by the code, not yet confirmed");
    // B goes away without ever coming back to A.
    b.close();
    std::fs::remove_file(da.join("hold-rescan")).unwrap();
    // Removed, said in the activity, and saved (in that order, so all three are waited for together).
    wait("the unconfirmed link removed on A", 180, || {
        call(&a, "sync_now", json!({}));
        peers(&a).is_empty()
            && log(&a).contains("Phone did not finish linking with this device")
            && std::fs::read_to_string(da.join("sync.json")).map(|t| t.contains("\"peers\":[]")).unwrap_or(false)
    });
    a.close();
}

#[test]
fn only_an_old_unconfirmed_link_is_removed_whatever_else_is_saved() {
    let tmp = tempfile::tempdir().unwrap();
    let da = tmp.path().join("a");
    std::fs::create_dir_all(&da).unwrap();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64;
    // As saved before this start, with the real wait (seven days): a link an older version wrote long ago (no mark), one made
    // long ago by a code and never confirmed, and one made just now by a code and not confirmed yet.
    let saved = json!({
        "name": "Desk",
        "peers": [
            {"id": "old", "name": "Phone", "linked": 5},
            {"id": "stale", "name": "Tablet", "linked": 5, "unconfirmed": true},
            {"id": "fresh", "name": "Laptop", "linked": now, "unconfirmed": true},
        ],
        "shares": [],
    });
    std::fs::write(da.join("sync.json"), serde_json::to_vec(&saved).unwrap()).unwrap();
    let a = engine(&da, "Desk");
    let ids = |e: &SyncEngine| peers(e).iter().map(|p| p["id"].as_str().unwrap_or("").to_string()).collect::<Vec<_>>();
    // The wait is counted from the saved time, so the stale one goes in the first rounds after the start.
    wait("the stale unconfirmed link removed", 60, || {
        call(&a, "sync_now", json!({}));
        !ids(&a).contains(&"stale".to_string()) && log(&a).contains("Tablet did not finish linking with this device")
    });
    let rounds = |e: &SyncEngine| call(e, "status", json!({}))["rounds"].as_u64().unwrap_or(0);
    let before = rounds(&a);
    wait("three more rounds on A", 60, || {
        call(&a, "sync_now", json!({}));
        rounds(&a) >= before + 3
    });
    // The link with no mark is confirmed and stays however old it is; the fresh one is still waiting.
    assert_eq!(ids(&a), vec!["old".to_string(), "fresh".to_string()], "{}", log(&a));
    assert_eq!(peers(&a)[0]["unconfirmed"], false);
    assert_eq!(peers(&a)[1]["unconfirmed"], true);
    a.close();
}
