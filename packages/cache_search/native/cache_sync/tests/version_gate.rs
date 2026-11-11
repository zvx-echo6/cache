//! The version gate: a device on another sync version stops syncing with this one, in both directions, and picks up again by
//! itself when the versions match. A "1.0" device is an engine with `legacy_proto` (sends no version, gates nothing, as 1.0.x).

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str, legacy: bool, port: Option<u16>) -> SyncEngine {
    engine_at(dir, name, legacy, port, None)
}

/// [`engine`] on sync protocol `proto` (tests only): an older build.
fn engine_at(dir: &Path, name: &str, legacy: bool, port: Option<u16>, proto: Option<u32>) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "port": port, "app_version": "1.1.0", "legacy_proto": legacy, "test_proto": proto,
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

fn peer0(e: &SyncEngine) -> Value {
    call(e, "status", json!({}))["peers"][0].clone()
}

fn offers(e: &SyncEngine) -> usize {
    call(e, "status", json!({}))["offers"].as_array().map(|o| o.len()).unwrap_or(0)
}

#[test]
fn matching_versions_sync_and_say_so() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb) = (tmp.path().join("fa"), tmp.path().join("fb"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("notes.txt"), "hello").unwrap();
    let a = engine(&tmp.path().join("a"), "Desk", false, None);
    let b = engine(&tmp.path().join("b"), "Phone", false, None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 30, || offers(&b) > 0);
    call(&b, "share_join", json!({"id": id, "path": fb}));
    wait("the file on B", 60, || fb.join("notes.txt").exists());
    assert_eq!(peer0(&b)["compat"], "ok");
    assert_eq!(peer0(&b)["peer_version"], "1.1.0");
    assert_eq!(peer0(&b)["our_version"], "1.1.0");
    a.close();
    b.close();
}

#[test]
fn an_unknown_device_is_gated_until_it_answers() {
    let tmp = tempfile::tempdir().unwrap();
    let fa = tmp.path().join("fa");
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("notes.txt"), "hello").unwrap();
    let a = engine(&tmp.path().join("a"), "Desk", false, None);
    let b = engine(&tmp.path().join("b"), "Phone", false, None);
    call(&b, "set_policy", json!({"network": false}));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"path": fa, "name": "Family"}));
    call(&b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(3));
    // B has asked nothing (no network it may use): it has not heard from Desk, so Desk is unknown and nothing is offered.
    assert_eq!(peer0(&b)["compat"], "unknown");
    assert_eq!(offers(&b), 0);
    call(&b, "set_policy", json!({"network": true}));
    wait("the answer", 30, || peer0(&b)["compat"] == "ok");
    wait("the offer", 30, || offers(&b) > 0);
    a.close();
    b.close();
}

#[test]
fn a_1_0_device_gets_an_error_and_nothing_crosses_then_it_updates_and_syncs() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb, fb2) = (tmp.path().join("fa"), tmp.path().join("fb"), tmp.path().join("fb2"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    std::fs::write(fa.join("notes.txt"), "from desk").unwrap();
    std::fs::write(fb.join("theirs.txt"), "from the old phone").unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let a = engine(&da, "Desk", false, None);
    let b = engine(&db, "Old phone", true, None);
    let b_port = b.port().unwrap();
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "share_add", json!({"path": fb, "name": "Old"}));
    call(&a, "sync_now", json!({}));
    call(&b, "sync_now", json!({}));

    // Our side: the mismatch, no version from it, and nothing of its list kept.
    wait("the mismatch on Desk", 30, || peer0(&a)["compat"] == "peer_older");
    assert!(peer0(&a)["peer_version"].is_null());
    assert_eq!(peer0(&a)["our_version"], "1.1.0");
    // Their side: an error (what 1.0 shows as Not reachable; it keeps only "connection lost", not our text), never an answer.
    wait("the error on the old phone", 30, || peer0(&b)["error"].is_string());
    assert!(peer0(&b)["last_seen"].is_null(), "the old phone never got an answer from Desk");
    std::thread::sleep(Duration::from_secs(4));
    assert_eq!(offers(&a), 0, "nothing of theirs is offered here");
    assert_eq!(offers(&b), 0, "nothing of ours is offered there");
    std::thread::sleep(Duration::from_secs(8));
    assert!(!fb2.join("notes.txt").exists(), "no file crossed to the old phone");
    assert!(!fa.join("theirs.txt").exists(), "no file crossed from the old phone");

    // Not asked again every round: the last time Desk heard from it stays put, until the person checks.
    let seen = peer0(&a)["last_seen"].clone();
    std::thread::sleep(Duration::from_secs(12));
    assert_eq!(peer0(&a)["last_seen"], seen, "a mismatched device is not retried on a schedule");
    let r = call(&a, "check_version", json!({"peer": peer0(&a)["id"]}));
    assert_eq!(r["compat"], "peer_older");
    assert_ne!(peer0(&a)["last_seen"], seen, "Check again asks now");

    // The old phone updates (restarts as a current build): Desk takes the new version when it is checked, with no new link.
    b.close();
    let b = engine(&db, "Old phone", false, Some(b_port));
    // (A restarted device is found again by the others only at its old port, so Desk reaches out; the phone learns Desk's address
    // from that connection. Out in the world the lookup services do this.)
    let pid = peer0(&a)["id"].clone();
    wait("the match on Desk", 40, || {
        let _ = a.call("check_version", &json!({"peer": pid}));
        peer0(&a)["compat"] == "ok"
    });
    wait("the offer on the phone", 40, || offers(&b) > 0);
    call(&b, "share_join", json!({"id": id, "path": fb2}));
    wait("the file on the phone", 60, || fb2.join("notes.txt").exists());
    a.close();
    b.close();
}

#[test]
fn a_gate_only_build_is_gated_against_the_notebook_layout_build_and_gets_no_removals() {
    // Protocol 3 is notebook layout v2, whose conversion removes the old folders; a device on protocol 2 (the first gate build, old
    // layout) must not count as compatible, or the removals would reach it as deletes.
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb) = (tmp.path().join("fa"), tmp.path().join("fb"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("notes.txt"), "from desk").unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    // both on protocol 2: the file syncs
    let a = engine_at(&da, "Desk", false, None, Some(2));
    let b = engine_at(&db, "Phone", false, None, Some(2));
    let a_port = a.port().unwrap();
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on the phone", 30, || offers(&b) > 0);
    call(&b, "share_join", json!({"id": id, "path": fb}));
    wait("the file on the phone", 60, || fb.join("notes.txt").exists());
    assert_eq!(peer0(&b)["compat"], "ok");
    // Desk updates to this build (protocol 3) and removes the file, as the conversion removes the old folders
    a.close();
    let a = engine(&da, "Desk", false, Some(a_port));
    std::fs::remove_file(fa.join("notes.txt")).unwrap();
    call(&a, "sync_now", json!({}));
    call(&b, "sync_now", json!({}));
    let pid = peer0(&a)["id"].clone();
    wait("Desk finds the phone older", 40, || {
        let _ = a.call("check_version", &json!({"peer": pid}));
        peer0(&a)["compat"] == "peer_older"
    });
    wait("the phone finds Desk newer", 40, || {
        call(&b, "sync_now", json!({}));
        peer0(&b)["compat"] == "peer_newer" || peer0(&b)["error"].is_string()
    });
    std::thread::sleep(Duration::from_secs(10));
    assert!(fb.join("notes.txt").exists(), "the removal never reached the phone");
    assert_eq!(std::fs::read_to_string(fb.join("notes.txt")).unwrap(), "from desk");
    a.close();
    b.close();
}
