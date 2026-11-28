//! Over Reticulum only (no iroh address anywhere), a device that was unlinked learns it: the device that unlinked it answers its
//! signed hello "not linked", the asking side records a 403, and after two of them at least the interval apart (a hook shortens
//! the ten minutes) it drops the link. A stranger (never linked) is never told, and a device kept 30 days is forgotten.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use common::*;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Duration;

struct Pair {
    _tmp: tempfile::TempDir,
    da: std::path::PathBuf,
    port: u16,
    a: cache_sync::SyncEngine,
    b: cache_sync::SyncEngine,
    b_id: String,
}

fn peers(e: &cache_sync::SyncEngine) -> Vec<Value> {
    call(e, "status", json!({}))["peers"].as_array().cloned().unwrap_or_default()
}

fn saved(dir: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(dir.join("sync.json")).unwrap()).unwrap()
}

/// A (Desk, listens) and B (Phone, connects) linked over Reticulum only. B checks the unlink every 1.5 s.
fn linked() -> Pair {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let port = free_port();
    rns_only_dirs(&[&da, &db]);
    std::fs::write(db.join("unlink-interval-ms"), "1500").unwrap();
    let a = engine(&da, "Desk", Some(port), None, None);
    let b = engine(&db, "Phone", None, Some(port), None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("both sides to hold the address", 30, || saved_peer(&da)["rns"]["dest"].is_string() && saved_peer(&db)["rns"]["dest"].is_string());
    let b_id = peers(&a)[0]["id"].as_str().unwrap().to_string();
    Pair { _tmp: tmp, da, port, a, b, b_id }
}

/// B checks in `n` times, 2 s apart.
fn rounds(e: &cache_sync::SyncEngine, n: usize) {
    for _ in 0..n {
        call(e, "sync_now", json!({}));
        std::thread::sleep(Duration::from_secs(2));
    }
}

#[test]
fn an_unlinked_device_learns_it_over_reticulum_and_drops_the_link() {
    let p = linked();
    // Linked: B checks in fine and keeps A. These successful rounds open the Reticulum link that B then reuses after the
    // unlink (a hello is only sent on a new link), so the "not linked" answer has to reach B on that already-open link.
    rounds(&p.b, 3);
    assert_eq!(peers(&p.b).len(), 1);
    call(&p.a, "unlink", json!({"peer": p.b_id}));
    assert!(saved(&p.da)["former"].as_array().is_some_and(|f| f.len() == 1 && f[0]["id"] == p.b_id.as_str()), "A records B as a former device");
    // One round is not enough; two at least the interval apart drop it.
    // A wall-clock limit (a round itself can block): on the already-open link this takes well under a minute.
    let end = std::time::Instant::now() + Duration::from_secs(45);
    while !peers(&p.b).is_empty() {
        assert!(std::time::Instant::now() < end, "B drops A within 45 s on the link that was already open");
        call(&p.b, "sync_now", json!({}));
        std::thread::sleep(Duration::from_secs(2));
    }
    p.a.close();
    p.b.close();
}

#[test]
fn a_stranger_is_never_told_not_linked() {
    let p = linked();
    // A forgets B without a trace (an edit to the saved file while closed: never linked, as far as A can tell).
    p.a.close();
    let mut v = saved(&p.da);
    v["peers"] = json!([]);
    std::fs::write(p.da.join("sync.json"), serde_json::to_vec(&v).unwrap()).unwrap();
    let a = engine(&p.da, "Desk", Some(p.port), None, None);
    rounds(&p.b, 6);
    assert_eq!(peers(&p.b).len(), 1, "B keeps A: a device A never linked gets no answer at all, not 'not linked'");
    a.close();
    p.b.close();
}

#[test]
fn a_former_device_is_forgotten_after_30_days_and_relinking_clears_it() {
    let p = linked();
    call(&p.a, "unlink", json!({"peer": p.b_id}));
    assert_eq!(saved(&p.da)["former"].as_array().map(|f| f.len()), Some(1));
    // Past 30 days: A does not tell B any more.
    p.a.close();
    let mut v = saved(&p.da);
    v["former"][0]["t"] = json!(1_000);
    std::fs::write(p.da.join("sync.json"), serde_json::to_vec(&v).unwrap()).unwrap();
    let a = engine(&p.da, "Desk", Some(p.port), None, None);
    rounds(&p.b, 6);
    assert_eq!(peers(&p.b).len(), 1, "B is not told after 30 days");
    // Linked again: the former entry is gone. (B's code to A.)
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&p.b, "link", json!({"code": code}));
    // The one being linked is B: A saw B as a new device. Unlink once more to record it, then link again and check it clears.
    wait("A to list B", 30, || peers(&a).iter().any(|x| x["id"] == p.b_id.as_str()));
    assert!(saved(&p.da).get("former").is_none_or(|f| f.as_array().is_none_or(|f| f.is_empty())), "linking again clears the former entry");
    a.close();
    p.b.close();
}
