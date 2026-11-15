//! Sync is fully shared both ways (owner, 2026-11-15): "Don't replace my copies from this device" is gone. A link with a
//! `keep_copies` flag left in `sync.json` by an earlier test build (51.3) is read and the flag dropped: that device's changes
//! arrive here like any other's (an edit replaces the file in place, a delete removes it), nothing is written beside a file,
//! and "(from <device>)" copies the old behaviour made stay where they are, as ordinary files.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false, "interval_secs": 5, "reserve_bytes": 0,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn until(what: &str, secs: u64, all: &[&SyncEngine], mut ok: impl FnMut() -> bool) {
    for i in 0..secs * 2 {
        if ok() {
            return;
        }
        if i % 2 == 0 {
            for e in all {
                call(e, "sync_now", json!({}));
            }
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let logs: Vec<String> = all.iter().map(|e| call(e, "status", json!({}))["log"].to_string()).collect();
    panic!("timed out waiting for {what}\n{}", logs.join("\n"));
}

fn put(p: &Path, bytes: &[u8]) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, bytes).unwrap();
}

fn is(p: &Path, want: &[u8]) -> bool {
    std::fs::read(p).map(|b| b == want).unwrap_or(false)
}

fn names(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir).map(|r| r.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default();
    v.sort();
    v
}

#[test]
fn a_stored_keep_copies_flag_is_ignored_edits_and_deletes_arrive_and_old_side_copies_stay() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, dc) = (tmp.path().join("dev-a"), tmp.path().join("dev-c"));
    let (fa, fc) = (tmp.path().join("notebooks-a"), tmp.path().join("notebooks-c"));
    put(&fa.join("Journal/entry.md"), b"desk v1");
    put(&fa.join("Journal/del.md"), b"desk keeps this");
    // what the old behaviour left: a Tablet's version beside the Desk's, now just a file
    put(&fa.join("Journal/entry (from Tablet).md"), b"an old side copy");
    std::fs::create_dir_all(&fc).unwrap();

    let (a, c) = (engine(&da, "Desk"), engine(&dc, "Tablet"));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&c, "link", json!({"code": code}));
    let ic = call(&c, "status", json!({}))["id"].as_str().unwrap().to_string();
    let share = call(&a, "share_add", json!({"path": fa, "name": "Notebooks", "id": "notebooks"}))["id"].as_str().unwrap().to_string();
    until("the offer", 60, &[&a, &c], || call(&c, "status", json!({}))["offers"].as_array().map(|o| o.iter().any(|x| x["id"] == share)).unwrap_or(false));
    call(&c, "share_join", json!({"id": share, "path": fc}));
    until("the Desk's files on the Tablet", 90, &[&a, &c], || {
        is(&fc.join("Journal/entry.md"), b"desk v1") && is(&fc.join("Journal/del.md"), b"desk keeps this") && is(&fc.join("Journal/entry (from Tablet).md"), b"an old side copy")
    });

    // 51.3 left the flag in the Desk's saved file for the Tablet (only the Desk restarts: with no discovery the Tablet could not
    // find a restarted Desk, but the restarted Desk dials the Tablet, which is all this needs)
    a.close();
    let saved = da.join("sync.json");
    let mut v: Value = serde_json::from_slice(&std::fs::read(&saved).unwrap()).unwrap();
    for p in v["peers"].as_array_mut().unwrap() {
        if p["id"] == ic {
            p["keep_copies"] = json!(true);
        }
    }
    std::fs::write(&saved, serde_json::to_vec(&v).unwrap()).unwrap();
    let a = engine(&da, "Desk");
    let all = [&a, &c];
    let peer = call(&a, "status", json!({}))["peers"].as_array().unwrap().iter().find(|p| p["id"] == ic).cloned().unwrap();
    assert!(peer.get("keep_copies").is_none(), "the flag is no longer a thing: {peer}");

    // The Tablet edits one file and deletes another; both reach the Desk as they are.
    std::thread::sleep(Duration::from_millis(1100));
    put(&fc.join("Journal/entry.md"), b"tablet edit");
    std::fs::remove_file(fc.join("Journal/del.md")).unwrap();
    until("the edit in place and the delete on the Desk", 120, &all, || is(&fa.join("Journal/entry.md"), b"tablet edit") && !fa.join("Journal/del.md").exists());
    let after = names(&fa.join("Journal"));
    assert_eq!(after, ["entry (from Tablet).md", "entry.md"], "nothing written beside a file, and nothing else lost");
    assert!(is(&fa.join("Journal/entry (from Tablet).md"), b"an old side copy"), "the old side copy is left alone");
    a.close();
    c.close();
}
