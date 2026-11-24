//! The lines a sync round and a notice say into `take_log` (so they reach cache.log, the only log readable on a phone): idle linked
//! devices say nothing; a change on one says a notice sent, a notice taken, and the round it made. One test only: the buffer is
//! process-wide (the two devices here share it, told apart by their names).
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use cache_sync::{take_log, Config, SyncEngine};
use common::*;
use serde_json::json;
use std::path::Path;
use std::time::Duration;

fn eng(dir: &Path, name: &str, listen: Option<u16>, connect: Option<u16>) -> SyncEngine {
    let cfg = json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "safety_secs": 600, "reserve_bytes": 0, "reticulum": true,
        "rns_interfaces": {
            "tcp_listen": listen.map(|p| format!("127.0.0.1:{p}")),
            "tcp_connect": connect.map(|p| format!("127.0.0.1:{p}")),
        },
    });
    SyncEngine::open(serde_json::from_value::<Config>(cfg).unwrap()).unwrap()
}

fn put(path: &Path, bytes: &[u8]) {
    let f = std::fs::File::create(path).unwrap();
    std::io::Write::write_all(&mut &f, bytes).unwrap();
    f.set_modified(std::time::SystemTime::now() - Duration::from_secs(60)).unwrap();
}

fn quiet(e: &SyncEngine, peer: &str) -> bool {
    call(e, "test_quiet", json!({"peer": peer}))["quiet"].as_bool().unwrap()
}

#[test]
fn idle_devices_say_no_round_and_a_change_says_its_notice_and_the_round_it_made() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    put(&fa.join("first.txt"), b"one");
    let port = free_port();
    rns_only_dirs(&[&da, &db]);
    let a = eng(&da, "Desk", Some(port), None);
    let b = eng(&db, "Phone", None, Some(port));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("both sides to hold the address", 20, || saved_peer(&da)["rns"]["dest"].is_string() && saved_peer(&db)["rns"]["dest"].is_string());
    call(&a, "share_add", json!({"id": "fam", "name": "Family", "path": fa}));
    call(&b, "share_add", json!({"id": "fam", "name": "Family", "path": fb}));
    // The first catch-up, then both hold the other as quiet.
    let (b_id, a_id) = (saved_peer(&da)["id"].as_str().unwrap().to_string(), saved_peer(&db)["id"].as_str().unwrap().to_string());
    for _ in 0..40 {
        call(&a, "test_round", json!({}));
        call(&b, "test_round", json!({}));
        if fb.join("first.txt").exists() && quiet(&a, &b_id) && quiet(&b, &a_id) {
            break;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    assert!(fb.join("first.txt").exists());
    // Past anything the catch-up woke, then a window of several timer intervals with nothing happening.
    std::thread::sleep(Duration::from_secs(12));
    take_log();
    std::thread::sleep(Duration::from_secs(20));
    let idle = take_log();
    assert!(!idle.iter().any(|l| l.starts_with("sync round:")), "idle devices said a round: {idle:?}");

    // A change on A.
    put(&fa.join("second.txt"), b"two");
    call(&a, "sync_now", json!({}));
    wait("the second file on B", 20, || fb.join("second.txt").exists());
    std::thread::sleep(Duration::from_secs(2));
    let lines = take_log();
    for l in &lines {
        println!("{l}");
    }
    let has = |pre: &str| lines.iter().any(|l| l.starts_with(pre));
    assert!(has("notice sent to Phone: Family at "), "A says the notice it sent: {lines:?}");
    assert!(has("notice from Desk: Family at "), "B says the notice it took: {lines:?}");
    assert!(has("sync round: notice from Desk (1 device)"), "B says the round the notice made: {lines:?}");
    assert!(lines.iter().filter(|l| l.starts_with("notice sent to")).count() <= 3, "one line per coalesced send: {lines:?}");
    a.close();
    b.close();
}
