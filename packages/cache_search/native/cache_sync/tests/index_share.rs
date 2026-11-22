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

/// [only] null: fetches everything.
fn engine_at(dir: &Path, name: &str, only: Value, port: Option<u16>) -> SyncEngine {
    let mut cfg = json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false, "interval_secs": 5,
        "reserve_bytes": 0, "port": port,
        "exclude": {"indexes": ["*/*/.build", ".local", "**/*-shm", "**/*-wal", "**/*-journal"]},
        "local_deletes": {"indexes": ["*/*/snap"]},
        "last": {"indexes": ["*/*/snap/*/manifest.json"]},
    });
    if !only.is_null() {
        cfg["only"] = json!({"indexes": only});
    }
    SyncEngine::open(serde_json::from_value::<Config>(cfg).unwrap()).unwrap()
}

/// The core removes an unusable snapshot itself, on disk, maybe while sync is not running (the app closed): sync does not fetch
/// it back, from the delete it finds when it looks again; and never_fetch keeps it away even without that record.
#[test]
fn a_snapshot_the_core_removed_is_not_fetched_back() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (ia, ib) = (tmp.path().join("idx-a"), tmp.path().join("idx-b"));
    snapshot(&ia, "zim/Z1", "bad");
    snapshot(&ia, "zim/Z2", "bad");
    write(&ia.join(".local/rejected.json"), "[]");
    std::fs::create_dir_all(&ib).unwrap();
    let a = engine_at(&da, "Desk", json!(null), None);
    let b = engine_at(&db, "Phone", json!(["zim/Z1"]), None);
    let b_port = b.port().unwrap();
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"id": "indexes", "name": "Search indexes", "path": ia}));
    call(&b, "share_add", json!({"id": "indexes", "name": "Search indexes", "path": ib}));
    std::thread::sleep(Duration::from_secs(6));
    until("Z1's snapshot on B", 60, &a, &b, || ib.join("zim/Z1/snap/bad/manifest.json").exists());
    assert!(!ib.join(".local").exists(), ".local never travels");

    // B's sync stops (the app is closed); its core finds the snapshot unusable and removes it; B starts again.
    b.close();
    std::fs::remove_dir_all(ib.join("zim/Z1/snap/bad")).unwrap();
    let b = engine_at(&db, "Phone", json!(["zim/Z1"]), Some(b_port));
    rounds(&a, &b);
    rounds(&a, &b);
    assert!(!ib.join("zim/Z1/snap/bad").exists(), "not fetched back");
    assert!(ia.join("zim/Z1/snap/bad/manifest.json").exists(), "A keeps its own");

    // never_fetch: a snapshot B's core rejected never comes, whatever B fetches.
    call(&b, "set_never_fetch", json!({"id": "indexes", "never_fetch": ["zim/Z2/snap/bad"]}));
    call(&b, "set_only", json!({"id": "indexes", "only": ["zim/Z1", "zim/Z2"]}));
    rounds(&a, &b);
    assert!(!ib.join("zim/Z2").exists());
    assert_eq!(call(&b, "status", json!({}))["shares"][0]["pending_files"], 0);
    assert_eq!(call(&b, "status", json!({}))["shares"][0]["never_fetch"], json!(["zim/Z2/snap/bad"]));
    call(&b, "set_never_fetch", json!({"id": "indexes", "never_fetch": null}));
    until("Z2 once allowed", 60, &a, &b, || ib.join("zim/Z2/snap/bad/manifest.json").exists());
    a.close();
    b.close();
}

/// A name starting with "." never travels, except the hidden files the share lets through (Tantivy's `.managed.json`, which a
/// snapshot's manifest lists, and the empty `.tantivy-meta.lock`).
#[test]
fn the_hidden_files_a_snapshot_needs_travel_and_no_others() {
    let tmp = tempfile::tempdir().unwrap();
    let (ia, ib) = (tmp.path().join("idx-a"), tmp.path().join("idx-b"));
    let d = ia.join("library/t/snap/b1");
    write(&d.join("seg"), "segment");
    write(&d.join(".managed.json"), "[\"seg\"]");
    write(&d.join(".tantivy-meta.lock"), "");
    write(&d.join(".other"), "stays");
    write(&ia.join("library/t/.hidden-dir/x"), "stays");
    std::fs::create_dir_all(&ib).unwrap();
    let open = |dir: &Path, name: &str| {
        SyncEngine::open(
            serde_json::from_value::<Config>(json!({
                "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false, "interval_secs": 5,
                "reserve_bytes": 0,
                "hidden": {"indexes": ["*/*/snap/*/.managed.json", "*/*/snap/*/.tantivy-meta.lock"]},
            }))
            .unwrap(),
        )
        .unwrap()
    };
    let a = open(&tmp.path().join("a"), "Desk");
    let b = open(&tmp.path().join("b"), "Phone");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"id": "indexes", "name": "Search indexes", "path": ia}));
    call(&b, "share_add", json!({"id": "indexes", "name": "Search indexes", "path": ib}));
    std::thread::sleep(Duration::from_secs(6));
    let got = ib.join("library/t/snap/b1");
    until("the snapshot on B", 60, &a, &b, || got.join("seg").exists() && got.join(".managed.json").exists() && got.join(".tantivy-meta.lock").exists());
    assert_eq!(std::fs::read_to_string(got.join(".managed.json")).unwrap(), "[\"seg\"]");
    rounds(&a, &b);
    assert!(!got.join(".other").exists(), "other hidden files stay");
    assert!(!ib.join("library/t/.hidden-dir").exists());
    a.close();
    b.close();
}

/// A generation g2 of an appendable library's snapshot reuses g1's segment files (the same bytes under another folder), and an older
/// build's clean-up on A removes g2 (it takes the earliest as the only one). The delete is A's alone: B keeps g2 and g1, and A does
/// not fetch g2 back. The file shared by both generations (seg-1) is not sent again: B already holds its bytes.
#[test]
fn an_older_builds_removal_of_a_newer_generation_stays_on_that_device() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (ia, ib) = (tmp.path().join("idx-a"), tmp.path().join("idx-b"));
    let generation = |root: &Path, build: &str, delta: &str| {
        let d = root.join("library/mine/snap").join(build);
        write(&d.join("seg-1"), "the first segment, shared by both generations");
        write(&d.join(delta), &format!("segment added in {build}"));
        write(&d.join("manifest.json"), &format!("{{\"build\":\"{build}\"}}"));
    };
    generation(&ia, "g1", "seg-2");
    std::fs::create_dir_all(&ib).unwrap();
    let a = engine(&da, "Desk", None);
    let b = engine(&db, "Phone", None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"id": "indexes", "name": "Search indexes", "path": ia}));
    call(&b, "share_add", json!({"id": "indexes", "name": "Search indexes", "path": ib}));
    until("g1 on B", 60, &a, &b, || ib.join("library/mine/snap/g1/manifest.json").exists());

    generation(&ia, "g2", "seg-3");
    until("g2 on B", 60, &a, &b, || ib.join("library/mine/snap/g2/manifest.json").exists());
    assert_eq!(
        std::fs::read_to_string(ib.join("library/mine/snap/g2/seg-1")).unwrap(),
        "the first segment, shared by both generations"
    );

    // the older build's clean-up on A removes g2, the newer generation
    std::fs::remove_dir_all(ia.join("library/mine/snap/g2")).unwrap();
    rounds(&a, &b);
    rounds(&a, &b);
    assert!(ib.join("library/mine/snap/g2/manifest.json").exists(), "A's delete of g2 stays on A: B keeps g2");
    assert!(ib.join("library/mine/snap/g1/manifest.json").exists());
    assert!(!ia.join("library/mine/snap/g2").exists(), "A does not fetch back what it removed");
    assert!(ia.join("library/mine/snap/g1/manifest.json").exists());
    a.close();
    b.close();
}
