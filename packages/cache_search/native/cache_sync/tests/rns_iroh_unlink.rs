//! Reticulum AND iroh both usable (as on a phone): the unlinked device still drops the link after two refusals apart, even
//! though the unlinking device is freshly installed and its iroh Gate says 409 "links reset" (7-day grace) to a key not linked.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use common::*;
use serde_json::{json, Value};
use std::time::Duration;

fn peers(e: &cache_sync::SyncEngine) -> Vec<Value> {
    call(e, "status", json!({}))["peers"].as_array().cloned().unwrap_or_default()
}

#[test]
fn unlinked_device_drops_the_link_with_iroh_and_reticulum_both_on() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (pa, pb, rns_port) = (free_port(), free_port(), free_port());
    std::fs::create_dir_all(&db).unwrap();
    std::fs::write(db.join("unlink-interval-ms"), "1500").unwrap();
    let a = engine(&da, "Desk", Some(rns_port), None, Some(pa));
    let b = engine(&db, "Phone", None, Some(rns_port), Some(pb));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("both sides to hold the address", 30, || saved_peer(&da)["rns"]["dest"].is_string() && saved_peer(&db)["rns"]["dest"].is_string());
    let b_id = peers(&a)[0]["id"].as_str().unwrap().to_string();
    for _ in 0..3 {
        call(&b, "sync_now", json!({}));
        std::thread::sleep(Duration::from_secs(2));
    }
    assert_eq!(peers(&b).len(), 1);
    println!("via before: {:?}", via(&b, "Desk"));
    call(&a, "unlink", json!({"peer": b_id}));
    let end = std::time::Instant::now() + Duration::from_secs(60);
    let mut n = 0;
    while !peers(&b).is_empty() {
        n += 1;
        println!("round {n}: {}", brief(&b));
        assert!(std::time::Instant::now() < end, "B did not drop A within 60 s");
        call(&b, "sync_now", json!({}));
        std::thread::sleep(Duration::from_secs(2));
    }
    a.close();
    b.close();
}
