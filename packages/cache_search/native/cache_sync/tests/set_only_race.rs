//! set_only while a sync round is part way through a rescan of the same share: the deletes it makes fetchable again must not be
//! written back by that round (they were, now and then: index_share timed out at "Z1's b2 again on B", run 41408966024).

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str, only: Option<Value>) -> SyncEngine {
    let mut cfg = json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0,
        "local_deletes": {"indexes": ["*/*/snap"]},
    });
    if let Some(o) = only {
        cfg["only"] = json!({"indexes": o});
    }
    SyncEngine::open(serde_json::from_value::<Config>(cfg).unwrap()).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn until(what: &str, secs: u64, a: &SyncEngine, b: &SyncEngine, mut ok: impl FnMut() -> bool) {
    for i in 0..secs * 4 {
        if ok() {
            return;
        }
        if i % 4 == 0 {
            call(a, "sync_now", json!({}));
            call(b, "sync_now", json!({}));
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("timed out waiting for {what}\nB: {}", call(b, "status", json!({}))["log"]);
}

fn write(p: &Path, text: &str) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

#[test]
fn set_only_during_a_rescan_is_not_lost() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (ia, ib) = (tmp.path().join("idx-a"), tmp.path().join("idx-b"));
    write(&ia.join("zim/Z1/snap/b1/seg"), "Z1 b1");
    write(&ia.join("zim/Z1/snap/b1/manifest.json"), "{}");
    std::fs::create_dir_all(&ib).unwrap();
    let a = engine(&da, "Desk", None);
    let b = engine(&db, "Phone", Some(json!(["zim/Z1"])));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"id": "indexes", "name": "Search indexes", "path": ia}));
    call(&b, "share_add", json!({"id": "indexes", "name": "Search indexes", "path": ib}));
    std::thread::sleep(Duration::from_secs(6));
    until("Z1 on B", 60, &a, &b, || ib.join("zim/Z1/snap/b1/manifest.json").exists());

    // B drops Z1's snapshot (its delete stays on B) and lets Z1 go.
    std::fs::remove_dir_all(ib.join("zim/Z1/snap/b1")).unwrap();
    call(&b, "set_only", json!({"id": "indexes", "only": []}));
    std::thread::sleep(Duration::from_secs(6));
    call(&b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(2));

    // A round of B is held part way through its rescan (the index read, not yet stored) while B takes Z1 again.
    let hold = db.join("hold-rescan");
    std::fs::write(&hold, b"").unwrap();
    call(&b, "sync_now", json!({}));
    for _ in 0..200 {
        if db.join("hold-rescan.held").exists() {
            break;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    assert!(db.join("hold-rescan.held").exists(), "a rescan of B is held");
    let r = call(&b, "set_only", json!({"id": "indexes", "only": ["zim/Z1"]}));
    assert!(r["fetchable_again"].as_u64().unwrap() >= 2, "{r}");
    std::fs::remove_file(&hold).unwrap();

    until("Z1's snapshot again on B", 60, &a, &b, || ib.join("zim/Z1/snap/b1/manifest.json").exists());
    a.close();
    b.close();
}
