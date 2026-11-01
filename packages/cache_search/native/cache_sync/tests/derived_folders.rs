//! What each device builds for itself in a shared folder (a library's search index, `*/index`) never syncs: not sent, not
//! fetched, not deleted. A device that synced such a folder with an earlier version keeps its copy, and so does the other
//! device; and a library removed elsewhere goes with its index.

use cache_sync::{excluded, Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str, port: u16, exclude: bool) -> SyncEngine {
    let ex = if exclude { json!({"libraries": ["*/index"]}) } else { json!({}) };
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "port": port, "exclude": ex,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn port() -> u16 {
    std::net::UdpSocket::bind("0.0.0.0:0").unwrap().local_addr().unwrap().port()
}

/// Runs sync rounds on both until `ok` (files only count once they have settled, so this takes a few seconds).
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

/// Lets both run a few rounds with every file settled, for checks that something did not happen.
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

#[test]
fn patterns_match_by_segment() {
    let p = vec!["*/index".to_string()];
    assert!(excluded(&p, "lib1/index"));
    assert!(excluded(&p, "lib1/index/meta.json"));
    assert!(excluded(&p, "lib1/index/a/b"));
    assert!(!excluded(&p, "lib1"));
    assert!(!excluded(&p, "index/meta.json"));
    assert!(!excluded(&p, "lib1/indexes/meta.json"));
    assert!(!excluded(&p, "lib1/shard/index/x"));
    assert!(!excluded(&p, "lib1/cache-library.json"));
    assert!(!excluded(&[], "lib1/index/meta.json"));
    assert!(!excluded(&["".to_string()], "lib1"));
}

#[test]
fn a_library_index_never_travels() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("libs-a"), tmp.path().join("libs-b"));
    let (pa, pb) = (port(), port());
    write(&fa.join("lib1/cache-library.json"), "{}");
    write(&fa.join("lib1/shard/seg.bin"), "segment one");
    write(&fa.join("lib1/index/meta.json"), "index of A");
    std::fs::create_dir_all(&fb).unwrap();

    // 1.0.29: neither excludes anything, so A's index arrives on B with the library.
    let a = engine(&da, "Desk", pa, false);
    let b = engine(&db, "Phone", pb, false);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"id": "libraries", "name": "Library (libraries)", "path": fa}));
    call(&b, "share_add", json!({"id": "libraries", "name": "Library (libraries)", "path": fb}));
    std::thread::sleep(Duration::from_secs(6));
    until("the library and its index on B", 60, &a, &b, || {
        fb.join("lib1/shard/seg.bin").exists() && fb.join("lib1/index/meta.json").exists()
    });
    // B is updated (it excludes `*/index`); A is not yet. Only one restarts at a time: with no lookup service a device is found
    // again only by one that still knows its address.
    b.close();
    let b = engine(&db, "Phone", pb, true);
    write(&fa.join("lib1/index/meta.json"), "index of A, rebuilt");
    write(&fa.join("lib1/index/seg2"), "more of A's index");
    write(&fa.join("lib1/shard/seg2.bin"), "segment two");
    write(&fb.join("lib1/index/built-on-b"), "B's own");
    std::thread::sleep(Duration::from_secs(6));
    until("the new segment on B", 60, &a, &b, || fb.join("lib1/shard/seg2.bin").exists());
    rounds(&a, &b);
    // B kept the copy it had and took nothing new of A's index; A lost nothing and got nothing of B's.
    assert_eq!(std::fs::read_to_string(fb.join("lib1/index/meta.json")).unwrap(), "index of A");
    assert!(!fb.join("lib1/index/seg2").exists(), "A's index must not be fetched");
    assert_eq!(std::fs::read_to_string(fa.join("lib1/index/meta.json")).unwrap(), "index of A, rebuilt");
    assert!(fa.join("lib1/index/seg2").exists(), "nothing of A's index may be deleted");
    assert!(!fa.join("lib1/index/built-on-b").exists(), "B's index must not be sent");
    // B no longer lists the index: its share counts the library's own files only, with nothing pending.
    let st = call(&b, "status", json!({}));
    let sh = &st["shares"][0];
    assert_eq!(sh["files"], 3, "{st}");
    assert_eq!(sh["pending_files"], 0, "{st}");
    let listed = std::fs::read_to_string(db.join("index").join("libraries.json")).unwrap();
    assert!(!listed.contains("lib1/index"), "{listed}");

    // Both updated: still nothing of either index travels, and the rest still does.
    a.close();
    let a = engine(&da, "Desk", pa, true);
    write(&fa.join("lib1/index/seg3"), "and more");
    write(&fa.join("lib1/shard/seg3.bin"), "segment three");
    std::thread::sleep(Duration::from_secs(6));
    until("the third segment on B", 60, &a, &b, || fb.join("lib1/shard/seg3.bin").exists());
    rounds(&a, &b);
    assert!(!fb.join("lib1/index/seg3").exists());
    assert!(fa.join("lib1/index/seg2").exists() && fa.join("lib1/index/seg3").exists());
    assert!(!fa.join("lib1/index/built-on-b").exists());
    let st = call(&a, "status", json!({}));
    assert_eq!(st["shares"][0]["files"], 4, "{st}");

    // The library is removed on A: on B it goes, and its index (built from it) with it.
    std::fs::remove_dir_all(fa.join("lib1")).unwrap();
    until("the library gone from B", 60, &a, &b, || !fb.join("lib1").exists());
    assert!(fb.is_dir(), "the shared folder itself stays");
    a.close();
    b.close();
}
