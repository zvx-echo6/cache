//! The always-on indexes folder: sealed snapshots under `<kind>/<source id>/snap/<build>/`, the build folder `.build/` and SQLite's
//! working files never travel, a device fetches only the sources it holds (`only`, replaced by `set_only`), a snapshot's
//! manifest comes after the rest of it (`last`), and deleting a snapshot stays on the device that did it (`local_deletes`).

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str, only: Option<Value>) -> SyncEngine {
    let mut cfg = json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0,
        "exclude": {"indexes": ["**/.build", "**/*-shm", "**/*-journal", "**/*-wal"]},
        "local_deletes": {"indexes": ["*/*/snap"]},
        "last": {"indexes": ["*/*/snap/*/manifest.json"]},
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
    for i in 0..secs * 2 {
        if ok() {
            return;
        }
        if i % 2 == 0 {
            call(a, "sync_now", json!({}));
            call(b, "sync_now", json!({}));
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let log = |e: &SyncEngine| call(e, "status", json!({}))["log"].to_string();
    panic!("timed out waiting for {what}\nA: {}\nB: {}", log(a), log(b));
}

fn rounds(a: &SyncEngine, b: &SyncEngine) {
    std::thread::sleep(Duration::from_secs(6));
    for _ in 0..3 {
        call(a, "sync_now", json!({}));
        call(b, "sync_now", json!({}));
        std::thread::sleep(Duration::from_secs(1));
    }
}

fn write(p: &Path, text: &str) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

/// A sealed snapshot: two segment files, then its manifest.
fn snapshot(root: &Path, source: &str, build: &str) {
    let d = root.join(source).join("snap").join(build);
    write(&d.join("seg-1"), &format!("{source} {build} one"));
    write(&d.join("seg-2"), &format!("{source} {build} two"));
    write(&d.join("manifest.json"), &format!("{{\"build\":\"{build}\"}}"));
}

#[test]
fn indexes_travel_only_for_the_sources_a_device_holds() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (ia, ib) = (tmp.path().join("idx-a"), tmp.path().join("idx-b"));
    // A holds two ZIMs and a library; each has a sealed snapshot, and one ZIM a build in progress and SQLite working files.
    snapshot(&ia, "zim/Z1", "b1");
    snapshot(&ia, "zim/Z2", "b1");
    snapshot(&ia, "library/L1", "b1");
    write(&ia.join("zim/Z1/.build/seg-9"), "half built");
    write(&ia.join("places-index/P1/snap/b1/places.sqlite-shm"), "working file");
    write(&ia.join("places-index/P1/snap/b1/places.sqlite-wal"), "working file");
    std::fs::create_dir_all(&ib).unwrap();

    // B has the same ZIM Z1 (its own copy, the ZIM itself is not synced) and nothing else: until it says so it fetches nothing.
    let a = engine(&da, "Desk", None);
    let b = engine(&db, "Phone", Some(json!([])));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"id": "indexes", "name": "Search indexes", "path": ia}));
    call(&b, "share_add", json!({"id": "indexes", "name": "Search indexes", "path": ib}));
    rounds(&a, &b);
    assert!(std::fs::read_dir(&ib).unwrap().next().is_none(), "nothing before B says what it holds");
    let pending = |e: &SyncEngine| call(e, "status", json!({}))["shares"][0]["pending_files"].clone();
    assert_eq!(pending(&b), 0, "what B does not fetch is not waiting either");

    // B holds Z1: only Z1's snapshot comes, manifest last.
    call(&b, "set_only", json!({"id": "indexes", "only": ["zim/Z1"]}));
    until("Z1's snapshot on B", 60, &a, &b, || ib.join("zim/Z1/snap/b1/manifest.json").exists());
    rounds(&a, &b);
    for f in ["seg-1", "seg-2", "manifest.json"] {
        assert!(ib.join("zim/Z1/snap/b1").join(f).exists(), "{f}");
    }
    let mtime = |f: &str| std::fs::metadata(ib.join("zim/Z1/snap/b1").join(f)).unwrap().modified().unwrap();
    assert!(mtime("manifest.json") >= mtime("seg-1") && mtime("manifest.json") >= mtime("seg-2"), "the manifest comes last");
    assert!(!ib.join("zim/Z2").exists() && !ib.join("library").exists(), "only the sources B holds");
    assert!(!ib.join("zim/Z1/.build").exists(), "a build in progress never travels");
    assert!(!ib.join("places-index").exists(), "nor SQLite's working files");
    assert_eq!(call(&b, "status", json!({}))["shares"][0]["only"], json!(["zim/Z1"]));
    assert_eq!(pending(&b), 0);

    // A replaces Z1's snapshot: the new one comes; A's delete of the old one stays on A, so B keeps its copy.
    snapshot(&ia, "zim/Z1", "b2");
    std::fs::remove_dir_all(ia.join("zim/Z1/snap/b1")).unwrap();
    until("Z1's new snapshot on B", 60, &a, &b, || ib.join("zim/Z1/snap/b2/manifest.json").exists());
    rounds(&a, &b);
    assert!(ib.join("zim/Z1/snap/b1/manifest.json").exists(), "a delete on A stays on A");

    // B drops b2 (its core moved on): A keeps it, and B does not fetch it back.
    std::fs::remove_dir_all(ib.join("zim/Z1/snap/b2")).unwrap();
    rounds(&a, &b);
    rounds(&a, &b);
    assert!(ia.join("zim/Z1/snap/b2/manifest.json").exists(), "a delete on B stays on B");
    assert!(!ib.join("zim/Z1/snap/b2").exists(), "B does not fetch back what it deleted");

    // B gets Z2 too; and when it lets Z1 go and takes it again, Z1's snapshot can come back.
    call(&b, "set_only", json!({"id": "indexes", "only": ["zim/Z2"]}));
    until("Z2's snapshot on B", 60, &a, &b, || ib.join("zim/Z2/snap/b1/manifest.json").exists());
    let r = call(&b, "set_only", json!({"id": "indexes", "only": ["zim/Z1", "zim/Z2"]}));
    assert!(r["fetchable_again"].as_u64().unwrap() >= 3, "{r}");
    until("Z1's b2 again on B", 60, &a, &b, || ib.join("zim/Z1/snap/b2/manifest.json").exists());
    assert!(!ib.join("library").exists());
    a.close();
    b.close();
}
