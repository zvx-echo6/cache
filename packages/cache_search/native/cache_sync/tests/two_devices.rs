//! Two engines on this machine, linked by code, keeping a folder the same (no relays, DHT, mDNS or lookup service: direct
//! addresses from the link code only).

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

fn wait(what: &str, secs: u64, mut ok: impl FnMut() -> bool) {
    for _ in 0..secs * 4 {
        if ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("timed out waiting for {what}");
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

#[test]
fn two_devices_link_share_and_stay_the_same() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(fa.join("maps")).unwrap();
    std::fs::write(fa.join("notes.txt"), "first").unwrap();
    let big: Vec<u8> = (0..3_000_000u32).map(|i| (i * 7 % 251) as u8).collect();
    std::fs::write(fa.join("maps/region.bin"), &big).unwrap();
    std::fs::write(fa.join(".hidden"), "never shared").unwrap();

    let a = engine(&da, "Desk");
    let b = engine(&db, "Phone");

    // A stranger's key is refused: B tries to read A's file list before linking.
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert!(code.starts_with("CACHE1-"));
    let linked = call(&b, "link", json!({"code": code}));
    assert_eq!(linked["name"], "Desk");
    // The code worked once; a second use is refused.
    let c = engine(&tmp.path().join("c"), "Other");
    assert!(c.call("link", &json!({"code": code})).is_err());
    c.close();

    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 30, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    // Not allowed to use the network (mobile data without permission): nothing is fetched, and the status says why.
    call(&b, "set_policy", json!({"network": false}));
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(4));
    assert!(!fb.join("notes.txt").exists() && !fb.join("maps/region.bin").exists(), "nothing may arrive while paused");
    assert_eq!(call(&b, "status", json!({}))["paused"], "Sync is paused: no network it may use");
    call(&b, "set_policy", json!({"network": true}));
    wait("the files on B", 60, || fb.join("maps/region.bin").exists() && fb.join("notes.txt").exists());
    assert_eq!(std::fs::read(fb.join("maps/region.bin")).unwrap(), big);
    assert!(!fb.join(".hidden").exists(), "hidden files are never shared");

    // An edit on B arrives on A.
    std::thread::sleep(Duration::from_millis(1100));
    std::fs::write(fb.join("notes.txt"), "edited on the phone").unwrap();
    call(&b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(1));
    call(&a, "sync_now", json!({}));
    wait("the edit on A", 60, || std::fs::read_to_string(fa.join("notes.txt")).map(|s| s == "edited on the phone").unwrap_or(false));

    // A new file and a delete on A arrive on B.
    std::fs::write(fa.join("maps/new.txt"), "new").unwrap();
    std::fs::remove_file(fa.join("maps/region.bin")).unwrap();
    call(&a, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(1));
    call(&b, "sync_now", json!({}));
    wait("the new file and the delete on B", 60, || fb.join("maps/new.txt").exists() && !fb.join("maps/region.bin").exists());

    // Both edit the same file before syncing: neither edit is lost.
    call(&a, "set_policy", json!({"network": false}));
    call(&b, "set_policy", json!({"network": false}));
    std::thread::sleep(Duration::from_secs(1));
    std::fs::write(fa.join("maps/new.txt"), "desk version").unwrap();
    std::fs::write(fb.join("maps/new.txt"), "phone version").unwrap();
    call(&a, "sync_now", json!({}));
    call(&b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(2));
    call(&a, "set_policy", json!({"network": true}));
    call(&b, "set_policy", json!({"network": true}));
    let has_both = |dir: &Path| {
        let names: Vec<String> = std::fs::read_dir(dir.join("maps")).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        let texts: Vec<String> = names.iter().filter(|n| n.starts_with("new")).filter_map(|n| std::fs::read_to_string(dir.join("maps").join(n)).ok()).collect();
        texts.contains(&"desk version".to_string()) && texts.contains(&"phone version".to_string())
    };
    wait("both versions on both devices", 90, || {
        call(&a, "sync_now", json!({}));
        call(&b, "sync_now", json!({}));
        has_both(&fa) && has_both(&fb)
    });

    let st = call(&b, "status", json!({}));
    assert_eq!(st["peers"][0]["name"], "Desk");
    assert!(st["peers"][0]["error"].is_null(), "{st}");
    a.close();
    b.close();
}
