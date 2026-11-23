//! Devices linked the old way (over iroh, a sync.json like build 54's, no Reticulum fields) learn each other's Reticulum
//! address through the index exchange, then sync over Reticulum with iroh unable to reach the other device.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use common::*;
use serde_json::json;

#[test]
fn old_links_learn_the_reticulum_address_and_use_it() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("before.txt"), "made before").unwrap();
    let (pa, pb, rns_port) = (free_port(), free_port(), free_port());

    // 1. Linked the old way: the marker makes each device say nothing about Reticulum (a code with no `r`, no Reticulum in the
    //    pairing or the file lists), as build 54 does, so the link goes over iroh and sync.json has no `rns`.
    let (a, b) = (engine(&da, "Desk", Some(rns_port), None, Some(pa)), engine(&db, "Phone", None, Some(rns_port), Some(pb)));
    let marker = |d: &std::path::Path| d.join("no-rns-fields");
    std::fs::write(marker(&da), b"").unwrap();
    std::fs::write(marker(&db), b"").unwrap();
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert!(!code.is_empty());
    call(&b, "link", json!({"code": code}));
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 60, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));
    wait("the file on B", 60, || fb.join("before.txt").exists());
    assert!(saved_peer(&da).get("rns").is_none() && saved_peer(&db).get("rns").is_none(), "build 54's sync.json has no rns");
    assert_eq!(via(&b, "Desk").as_deref(), Some("direct"));

    // 2. The marker goes: the next file lists carry each one's Reticulum address.
    std::fs::remove_file(marker(&da)).unwrap();
    std::fs::remove_file(marker(&db)).unwrap();
    call(&a, "sync_now", json!({}));
    call(&b, "sync_now", json!({}));
    wait_dbg(
        "both to learn the other's address",
        90,
        || saved_peer(&da)["rns"]["dest"].is_string() && saved_peer(&db)["rns"]["dest"].is_string(),
        || format!("A saved {} / B saved {}\nA {}\nB {}", saved_peer(&da), saved_peer(&db), brief(&a), brief(&b)),
    );

    // 3. Both restart where iroh cannot find the other (new ports, nothing remembered): only Reticulum is left.
    a.close();
    b.close();
    std::fs::write(fa.join("after.txt"), "made after").unwrap();
    let a = engine(&da, "Desk", Some(rns_port), None, None);
    let b = engine(&db, "Phone", None, Some(rns_port), None);
    call(&b, "sync_now", json!({}));
    wait("the new file on B over Reticulum", 120, || fb.join("after.txt").exists());
    assert_eq!(via(&b, "Desk").as_deref(), Some("reticulum"));
    a.close();
    b.close();
}
