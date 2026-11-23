//! Two engines with Reticulum on over loopback TCP, linked with a short code over Reticulum only (the code has no iroh address;
//! iroh has no relay or lookup): a file syncs, then a 150 MB file is cut off half way and resumes from the windows
//! already verified.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use common::*;
use serde_json::json;
use std::time::{Duration, Instant};

#[test]
fn link_sync_cut_and_resume_over_reticulum() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("notes.txt"), "first").unwrap();

    let port = free_port();
    rns_only_dirs(&[&da, &db]);
    let a = engine(&da, "Desk", Some(port), None, None);
    let b = engine(&db, "Phone", None, Some(port), None);

    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    let linked = call(&b, "link", json!({"code": code}));
    assert_eq!(linked["name"], "Desk");
    // Both saved the other's Reticulum address from the pairing.
    wait("both sides to hold the address", 20, || saved_peer(&da)["rns"]["dest"].is_string() && saved_peer(&db)["rns"]["dest"].is_string());

    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 90, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));
    wait("the file on B", 90, || fb.join("notes.txt").exists());
    assert_eq!(via(&b, "Desk").as_deref(), Some("reticulum"), "Reticulum answered, not iroh");

    // 150 MB: cut off part way, then resumed.
    let big = random(150 * 1024 * 1024, 9);
    let want = blake3::hash(&big);
    std::fs::write(fa.join("big.bin"), &big).unwrap();
    drop(big);
    call(&a, "sync_now", json!({}));
    call(&b, "sync_now", json!({}));
    let done_of = |e: &cache_sync::SyncEngine| call(e, "status", json!({}))["transfer"]["done"].as_u64();
    let t = Instant::now();
    wait("a third of the file", 240, || done_of(&b).unwrap_or(0) >= 50 * 1024 * 1024);
    println!("RESULT t2_first_third secs={:.1}", t.elapsed().as_secs_f64());
    assert!(!fb.join("big.bin").exists(), "the file is not whole yet");

    // The cut: the provider stops (its TCP link goes), and this device stops waiting on the dead link.
    a.close();
    call(&b, "set_policy", json!({"network": false}));
    wait("the transfer to stop", 60, || call(&b, "status", json!({}))["transfer"].is_null());
    assert!(!fb.join("big.bin").exists());

    let a = engine(&da, "Desk", Some(port), None, None);
    call(&b, "set_policy", json!({"network": true}));
    let mut first_after = None;
    let start = Instant::now();
    wait("the file on B", 300, || {
        if first_after.is_none() {
            first_after = done_of(&b).filter(|d| *d > 0);
        }
        fb.join("big.bin").exists() && call(&b, "status", json!({}))["transfer"].is_null()
    });
    println!("RESULT t2_resume secs={:.1}", start.elapsed().as_secs_f64());
    let first = first_after.expect("progress was seen after the restart");
    assert!(first >= 48 * 1024 * 1024, "the resumed transfer starts from the verified windows ({first} bytes), not from zero");
    let got = std::fs::read(fb.join("big.bin")).unwrap();
    assert_eq!(blake3::hash(&got), want, "the file is byte for byte the original");
    a.close();
    b.close();
    let _ = Duration::from_secs(0);
}
