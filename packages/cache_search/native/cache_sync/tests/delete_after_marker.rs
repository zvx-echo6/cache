//! R1 (build 57, FAILS until fixed): a delete made in Cache can come back on every device.
//!
//! The notebook engine deletes an entry in a share by writing `_deleted/<id>.json` first and then removing the entry's `.md`.
//! A scan lists the removal at once but holds the marker back for a round, because it changed less than SETTLE ago and could
//! still be being written. Another device that fetches in between gets the removal without the marker. Its notebook engine
//! then sees a missing file and no marker, so it writes the file back. When that file comes back to the first device, the
//! entry is restored and the marker removed (seen on a phone and VM 152, 2026-11-24).
//!
//! The requirement this test states: what a device offers is never ahead of its own folder's order of changes. A deletion is
//! not listed while a file in the same share written at or before it is still held back as unsettled, so a device that
//! stores the removal of the `.md` also stores the marker.
//!
//! The second test (R1 a2) is the receiving side: even when both are listed together, a device whose fetch of the marker fails
//! must not take the removal in that round, or its notebook engine sees the file gone with no marker and writes it back. A
//! share's deletions wait for a round in which every fetch from that share came.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{
    path::Path,
    time::{Duration, SystemTime},
};

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

/// The share's stored index on `dir` (what this device offers), or null before the first scan.
fn index(dir: &Path, id: &str) -> Value {
    std::fs::read(dir.join("index").join(format!("{id}.json"))).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(Value::Null)
}

fn live(idx: &Value, path: &str) -> bool {
    idx["files"].get(path).map(|e| e["deleted"] != true).unwrap_or(false)
}

fn deleted(idx: &Value, path: &str) -> bool {
    idx["files"].get(path).map(|e| e["deleted"] == true).unwrap_or(false)
}

#[test]
fn r1_a_delete_is_not_offered_ahead_of_the_marker_written_just_before_it() {
    let tmp = tempfile::tempdir().unwrap();
    let da = tmp.path().join("a");
    let fa = tmp.path().join("folder-a");
    let md = "F2test/2026-11-24 Charlie.md";
    let mk = "_deleted/02e14d31-19a7-49cc-8019-e0281f3a5b7a.json";
    std::fs::create_dir_all(fa.join("F2test")).unwrap();
    std::fs::write(fa.join(md), "---\nid: 02e14d31-19a7-49cc-8019-e0281f3a5b7a\n---\nCharlie, a longer body than the marker\n").unwrap();
    // Written a minute ago: settled, listed by the first scan.
    let f = std::fs::File::options().write(true).open(fa.join(md)).unwrap();
    f.set_modified(SystemTime::now() - Duration::from_secs(60)).unwrap();
    drop(f);

    let a = engine(&da, "Phone");
    let id = call(&a, "share_add", json!({"path": fa, "name": "Notebooks"}))["id"].as_str().unwrap().to_string();
    call(&a, "sync_now", json!({}));
    let mut ok = false;
    for _ in 0..240 {
        if live(&index(&da, &id), md) {
            ok = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    assert!(ok, "the entry's file was never listed");

    // What the notebook engine's delete does: the marker first, then the file goes. A scan right after.
    std::fs::create_dir_all(fa.join("_deleted")).unwrap();
    std::fs::write(fa.join(mk), "{\"id\":\"02e14d31-19a7-49cc-8019-e0281f3a5b7a\",\"at\":1795992197000}").unwrap();
    std::fs::remove_file(fa.join(md)).unwrap();
    call(&a, "sync_now", json!({}));

    // Every stored index from here on, until both changes are listed: none may list the removal without the marker.
    let mut both = false;
    for _ in 0..80 {
        let idx = index(&da, &id);
        assert!(
            !(deleted(&idx, md) && !live(&idx, mk)),
            "R1: the index offers {md} deleted while the marker {mk} written before it is not listed yet; a device fetching now \
             writes the file back and the delete is undone. Index: {}",
            idx["files"]
        );
        if deleted(&idx, md) && live(&idx, mk) {
            both = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    assert!(both, "the removal and the marker were not both listed within 8 s");
    a.close();
}

fn log(e: &SyncEngine) -> String {
    call(e, "status", json!({}))["log"].to_string()
}

/// Dates `p` a minute back: settled, so a scan lists it at once (as after the scan-side fix).
fn settled(p: &Path) {
    let f = std::fs::File::options().write(true).open(p).unwrap();
    f.set_modified(SystemTime::now() - Duration::from_secs(60)).unwrap();
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
    panic!("timed out waiting for {what}\nA: {}\nB: {}", log(a), log(b));
}

#[test]
fn r1_a2_a_delete_is_not_applied_in_a_round_where_the_marker_could_not_be_fetched() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("fa"), tmp.path().join("fb"));
    let md = "F2test/2026-11-24 Charlie.md";
    let mk = "_deleted/02e14d31-19a7-49cc-8019-e0281f3a5b7a.json";
    std::fs::create_dir_all(fa.join("F2test")).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    std::fs::write(fa.join(md), "---\nid: 02e14d31-19a7-49cc-8019-e0281f3a5b7a\n---\nCharlie, a longer body than the marker\n").unwrap();
    settled(&fa.join(md));

    let a = engine(&da, "Phone");
    let b = engine(&db, "Desk");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"id": "notebooks", "name": "Notebooks", "path": fa}));
    call(&b, "share_add", json!({"id": "notebooks", "name": "Notebooks", "path": fb}));
    until("Charlie on B", 90, &a, &b, || fb.join(md).exists());

    // B cannot fetch the marker (the hook the other fetch-failure tests use).
    std::fs::write(db.join("fail-fetch"), mk).unwrap();
    // A deletes Charlie: the marker, then the file goes; both listed in the same index (the marker already settled).
    std::fs::create_dir_all(fa.join("_deleted")).unwrap();
    std::fs::write(fa.join(mk), "{\"id\":\"02e14d31-19a7-49cc-8019-e0281f3a5b7a\",\"at\":1795992197000}").unwrap();
    settled(&fa.join(mk));
    std::fs::remove_file(fa.join(md)).unwrap();
    until("A listing both the removal and the marker", 60, &a, &b, || {
        let idx = index(&da, "notebooks");
        deleted(&idx, md) && live(&idx, mk)
    });

    // Rounds in which B has A's index with both and fails the marker: the removal must wait too.
    let failures = |e: &SyncEngine| log(e).matches("test: could not fetch _deleted/").count();
    until("B failing the marker at least twice", 90, &a, &b, || failures(&b) >= 2);
    assert!(
        fb.join(md).exists(),
        "R1 a2: B removed {md} in a round where it could not fetch the marker {mk}; its notebook engine now sees the file gone \
         with no marker and writes it back, and the delete is undone. B: {}",
        log(&b)
    );
    assert!(!fb.join(mk).exists());

    // The fetch works again: the marker and the removal both come.
    std::fs::remove_file(db.join("fail-fetch")).unwrap();
    until("the marker on B and Charlie gone", 90, &a, &b, || fb.join(mk).exists() && !fb.join(md).exists());
    a.close();
    b.close();
}
