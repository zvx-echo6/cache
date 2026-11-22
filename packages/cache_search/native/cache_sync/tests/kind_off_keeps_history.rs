//! Switching a share off and on again on one device (what a kind's switch does) keeps what each side changed meanwhile:
//! `share_remove` with `keep_history` keeps the index, the seen file and the stored tags, so the share comes back with its
//! history instead of as a stranger (no "(conflict, ...)" copies, no deleted file coming back).

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

fn names(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir).unwrap().filter_map(|e| e.ok()).map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    v.sort();
    v
}

fn round(a: &SyncEngine, b: &SyncEngine) {
    call(a, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(1));
    call(b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(2));
}

#[test]
fn a_kind_switched_off_and_on_keeps_each_sides_changes() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    for n in ["x", "y", "z", "w", "v"] {
        std::fs::write(fa.join(n), format!("{n} original")).unwrap();
    }
    let a = engine(&da, "Desk");
    let b = engine(&db, "Phone");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    let id = call(&a, "share_add", json!({"path": fa, "name": "Notes"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 30, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));
    wait("all five files on B", 60, || ["x", "y", "z", "w", "v"].iter().all(|n| fb.join(n).exists()));
    // Let both sides settle so each knows the other has everything.
    std::thread::sleep(Duration::from_secs(6));
    round(&a, &b);

    // B's switch goes off.
    call(&b, "share_remove", json!({"id": id, "keep_history": true}));
    std::thread::sleep(Duration::from_millis(1200));

    // Meanwhile, on A: edit x, add a1, delete y. On B: edit w, add b1, delete v.
    std::fs::write(fa.join("x"), "x edited on A").unwrap();
    std::fs::write(fa.join("a1"), "a1").unwrap();
    std::fs::remove_file(fa.join("y")).unwrap();
    std::fs::write(fb.join("w"), "w edited on B").unwrap();
    std::fs::write(fb.join("b1"), "b1").unwrap();
    std::fs::remove_file(fb.join("v")).unwrap();
    call(&a, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(2));

    // Switched back on.
    call(&b, "share_add", json!({"id": id, "name": "Notes", "path": fb}));
    for _ in 0..4 {
        round(&a, &b);
        round(&b, &a);
    }

    for d in [&fa, &fb] {
        let n = names(d);
        assert_eq!(std::fs::read_to_string(d.join("x")).unwrap(), "x edited on A", "{d:?}: {n:?}");
        assert_eq!(std::fs::read_to_string(d.join("w")).unwrap(), "w edited on B", "{d:?}: {n:?}");
        assert!(d.join("a1").exists() && d.join("b1").exists(), "{d:?}: {n:?}");
        assert!(!d.join("y").exists() && !d.join("v").exists(), "a deleted file came back in {d:?}: {n:?}");
        assert!(n.iter().all(|f| !f.contains("conflict")), "a conflict copy in {d:?}: {n:?}");
    }
    a.close();
    b.close();
}

#[test]
fn share_remove_without_keep_history_deletes_index_and_seen() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, fa) = (tmp.path().join("a"), tmp.path().join("folder-a"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("x"), "x").unwrap();
    let a = engine(&da, "Desk");
    let id = call(&a, "share_add", json!({"path": fa, "name": "Notes"}))["id"].as_str().unwrap().to_string();
    let (index, seen) = (da.join("index").join(format!("{id}.json")), da.join("index").join(format!("{id}.seen.json")));
    call(&a, "sync_now", json!({}));
    wait("the index and seen files", 30, || index.exists() && seen.exists());
    call(&a, "share_remove", json!({"id": id}));
    assert!(!index.exists() && !seen.exists());
    a.close();
}
