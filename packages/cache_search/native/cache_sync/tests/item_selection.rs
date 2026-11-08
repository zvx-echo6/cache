//! The person's choice of items inside one shared folder (`off`, replaced by `set_off`), the items a share holds here and on
//! each linked device (`share_items`), Sync now for one device, one shared folder or one item (`sync_now` with a scope), what
//! this device calls a linked device (`set_peer_name`), and a linked device's free space in the status.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str, interval: u64, off: Option<Value>) -> SyncEngine {
    let mut cfg = json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": interval, "reserve_bytes": 0,
    });
    if let Some(o) = off {
        cfg["off"] = o;
    }
    SyncEngine::open(serde_json::from_value::<Config>(cfg).unwrap()).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn status(e: &SyncEngine) -> Value {
    call(e, "status", json!({}))
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
    panic!("timed out waiting for {what}\nA: {}\nB: {}", status(a)["log"], status(b)["log"]);
}

/// Waits for `ok` without starting any round.
fn wait(what: &str, secs: u64, e: &SyncEngine, mut ok: impl FnMut() -> bool) {
    for _ in 0..secs * 4 {
        if ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("timed out waiting for {what}\n{}", status(e)["log"]);
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

fn link(a: &SyncEngine, b: &SyncEngine) {
    let code = call(a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(b, "link", json!({"code": code}));
}

#[test]
fn an_item_switched_off_neither_comes_nor_goes_and_comes_back_when_switched_on() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("lib-a"), tmp.path().join("lib-b"));
    write(&fa.join("keep/a.txt"), "kept");
    write(&fa.join("skip/b.txt"), "skipped");
    write(&fb.join("mine/c.txt"), "mine");

    // B has two items switched off from its start: one only A holds, one only B holds.
    let a = engine(&da, "Desk", 5, None);
    let b = engine(&db, "Phone", 5, Some(json!({"lib": ["skip", "mine"]})));
    link(&a, &b);
    call(&a, "share_add", json!({"id": "lib", "name": "Library", "path": fa}));
    call(&b, "share_add", json!({"id": "lib", "name": "Library", "path": fb}));
    until("the item switched on, on B", 60, &a, &b, || fb.join("keep/a.txt").exists());
    rounds(&a, &b);
    assert!(!fb.join("skip").exists(), "an item switched off on B is not fetched by B");
    assert!(!fa.join("mine").exists(), "nor is B's own copy of one offered");
    assert_eq!(status(&b)["shares"][0]["off"], json!(["skip", "mine"]));
    assert_eq!(status(&b)["shares"][0]["pending_files"], 0, "what is switched off is not waiting either");

    // The share's items as B sees them: here, on A, or both.
    let items = call(&b, "share_items", json!({"id": "lib"}))["items"].clone();
    let item = |n: &str| items.as_array().unwrap().iter().find(|i| i["name"] == n).cloned().unwrap_or_else(|| panic!("{n} in {items}"));
    assert_eq!(item("keep")["files"], 1);
    assert_eq!(item("keep")["bytes"], 4);
    assert_eq!(item("keep")["peers"][0]["peer_name"], "Desk");
    assert_eq!(item("skip")["files"], 0, "not here");
    assert_eq!(item("skip")["peers"][0]["bytes"], 7, "on A");
    assert_eq!(item("mine")["files"], 1);
    assert!(item("mine")["peers"].as_array().unwrap().is_empty(), "A was never offered it");
    let deep = call(&b, "share_items", json!({"id": "lib", "depth": 2}))["items"].clone();
    assert!(deep.as_array().unwrap().iter().any(|i| i["name"] == "keep/a.txt"), "{deep}");

    // Switched on: it comes.
    call(&b, "set_off", json!({"id": "lib", "off": ["mine"]}));
    until("the item switched on again, on B", 60, &a, &b, || fb.join("skip/b.txt").exists());

    // Switched off and deleted on B: A keeps its copy.
    call(&b, "set_off", json!({"id": "lib", "off": ["mine", "keep"]}));
    std::fs::remove_file(fb.join("keep/a.txt")).unwrap();
    rounds(&a, &b);
    assert!(fa.join("keep/a.txt").exists(), "a delete of an item switched off stays on the device that made it");

    // Everything on: A's copy comes back to B, and B's own item goes to A.
    let r = call(&b, "set_off", json!({"id": "lib", "off": []}));
    assert_eq!(r["fetchable_again"], 1, "{r}");
    until("A's copy back on B and B's item on A", 60, &a, &b, || fb.join("keep/a.txt").exists() && fa.join("mine/c.txt").exists());
    assert_eq!(std::fs::read_to_string(fb.join("keep/a.txt")).unwrap(), "kept");
    assert_eq!(status(&b)["shares"][0]["off"], Value::Null);
    a.close();
    b.close();
}

#[test]
fn sync_now_for_one_item_one_folder_or_one_device_takes_just_that() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("lib-a"), tmp.path().join("lib-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    write(&fa.join("base.txt"), "base");

    // No rounds on their own for an hour: only what the test starts runs.
    let a = engine(&da, "Desk", 3600, None);
    let b = engine(&db, "Phone", 3600, None);
    link(&a, &b);
    call(&a, "share_add", json!({"id": "lib", "name": "Library", "path": fa}));
    call(&b, "share_add", json!({"id": "lib", "name": "Library", "path": fb}));
    until("the first file on B", 60, &a, &b, || fb.join("base.txt").exists());
    let a_id = status(&a)["id"].as_str().unwrap().to_string();

    // A takes no network from now on, so it never asks B for anything (which would start a whole round on B); it still answers.
    call(&a, "set_policy", json!({"network": false}));
    // Any round already asked for on either device finishes on what A listed before.
    std::thread::sleep(Duration::from_secs(4));
    write(&fa.join("one/x.txt"), "one");
    write(&fa.join("two/y.txt"), "two");
    let files = |e: &SyncEngine| status(e)["shares"][0]["files"].as_u64().unwrap_or(0);
    wait("A listing its new files", 60, &a, || {
        call(&a, "sync_now", json!({}));
        files(&a) == 3
    });

    // One item.
    call(&b, "sync_now", json!({"share": "lib", "paths": ["one"]}));
    wait("the one item on B", 60, &b, || fb.join("one/x.txt").exists());
    std::thread::sleep(Duration::from_secs(3));
    assert!(!fb.join("two").exists(), "Sync now for one item takes only that item");

    // One shared folder (a kind).
    call(&b, "sync_now", json!({"shares": ["lib"]}));
    wait("the rest of the folder on B", 60, &b, || fb.join("two/y.txt").exists());

    // One device.
    write(&fa.join("three/z.txt"), "three");
    wait("A listing the third file", 60, &a, || {
        call(&a, "sync_now", json!({}));
        files(&a) == 4
    });
    call(&b, "sync_now", json!({"peer": a_id}));
    wait("the third file on B", 60, &b, || fb.join("three/z.txt").exists());

    // A scope naming something that is not there is refused.
    assert!(b.call("sync_now", &json!({"peer": "not-a-device"})).is_err());
    assert!(b.call("sync_now", &json!({"shares": ["nothing"]})).is_err());

    // B knows A's free space from A's list, and calls A what the person chose.
    let peer = status(&b)["peers"][0].clone();
    assert!(peer["free_bytes"].as_u64().is_some(), "{peer}");
    call(&b, "set_peer_name", json!({"peer": a_id, "name": "  Office  "}));
    assert_eq!(status(&b)["peers"][0]["name"], "Office");
    assert_eq!(status(&a)["name"], "Desk", "A's own name stays its own");
    assert!(b.call("set_peer_name", &json!({"peer": a_id, "name": " "})).is_err());
    assert!(b.call("set_peer_name", &json!({"peer": "not-a-device", "name": "X"})).is_err());
    a.close();
    b.close();
}
