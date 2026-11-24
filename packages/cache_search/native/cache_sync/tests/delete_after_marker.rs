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
