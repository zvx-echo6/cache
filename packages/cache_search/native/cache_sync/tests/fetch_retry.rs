//! A quiet device that has not finished a fetch keeps retrying it on the timer round, and cache.log says why the fetch stopped and
//! when it finished after a retry. Two summary-capable devices over Reticulum (loopback TCP), quiet to each other, timer 5 s, safety
//! 600 s. B's fetch is dropped after its first window (hook `drop-fetch-mid`: while `<dir>/drop-fetch-mid` exists a fetch fails after
//! its first window); when the hook goes B must finish well before the safety round. One test only: the log buffer is process-wide
//! (the devices are told apart by name).
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use cache_sync::{take_log, Config, SyncEngine};
use common::*;
use serde_json::json;
use std::path::Path;
use std::time::{Duration, Instant};

const BIG: usize = 24 * 1024 * 1024;

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

fn round(e: &SyncEngine) {
    call(e, "test_round", json!({}));
}

fn quiet(e: &SyncEngine, peer: &str) -> bool {
    call(e, "test_quiet", json!({"peer": peer}))["quiet"].as_bool().unwrap()
}

fn put(path: &Path, bytes: &[u8]) {
    let f = std::fs::File::create(path).unwrap();
    std::io::Write::write_all(&mut &f, bytes).unwrap();
    f.set_modified(std::time::SystemTime::now() - Duration::from_secs(60)).unwrap();
}

#[test]
fn a_quiet_device_retries_an_unfinished_fetch_on_the_timer_and_the_log_says_why_it_stopped() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    let port = free_port();
    rns_only_dirs(&[&da, &db]);
    let a = eng(&da, "Desk", Some(port), None);
    let b = eng(&db, "Phone", None, Some(port));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("both sides to hold the address", 20, || saved_peer(&da)["rns"]["dest"].is_string() && saved_peer(&db)["rns"]["dest"].is_string());
    call(&a, "share_add", json!({"id": "fam", "name": "Family", "path": fa}));
    call(&b, "share_add", json!({"id": "fam", "name": "Family", "path": fb}));
    let (b_id, a_id) = (saved_peer(&da)["id"].as_str().unwrap().to_string(), saved_peer(&db)["id"].as_str().unwrap().to_string());
    for _ in 0..40 {
        round(&a);
        round(&b);
        if quiet(&a, &b_id) && quiet(&b, &a_id) {
            break;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    assert!(quiet(&a, &b_id) && quiet(&b, &a_id), "the devices never became quiet");
    // A new big file on A; B's fetches are dropped after the first window.
    std::fs::write(db.join("drop-fetch-mid"), b"").unwrap();
    take_log();
    let big = random(BIG, 9);
    put(&fa.join("video.bin"), &big);
    call(&a, "sync_now", json!({}));
    let mut lines: Vec<String> = Vec::new();
    wait("B's fetch to stop", 120, || {
        lines.extend(take_log());
        lines.iter().any(|l| l.starts_with("fetch from Desk stopped at "))
    });
    assert!(!fb.join("video.bin").exists());
    // The link is back: from here B has to carry on by itself, on its timer round, not by the 600 s safety round.
    std::fs::remove_file(db.join("drop-fetch-mid")).unwrap();
    let back = Instant::now();
    wait_dbg("B to finish the file", 30, || fb.join("video.bin").exists(), || format!("log: {:?}\ntransfer: {}\nB: {}", take_log(), call(&b, "status", json!({}))["transfer"], brief(&b)));
    eprintln!("TIMING finished {:?} after the interruption ended", back.elapsed());
    assert!(std::fs::read(fb.join("video.bin")).unwrap() == big, "the file is whole and equal");
    std::thread::sleep(Duration::from_secs(1));
    lines.extend(take_log());
    for l in &lines {
        println!("{l}");
    }
    let stopped = lines.iter().find(|l| l.starts_with("fetch from Desk stopped at ")).unwrap();
    assert!(stopped.ends_with("(will retry)") && stopped.contains(" MB: "), "{stopped}");
    assert!(!stopped.contains("video"), "no file name in the line: {stopped}");
    assert!(lines.iter().any(|l| l == "fetch from Desk resumed and finished (24 MB)"), "B says it finished: {lines:?}");
    // With nothing held it is quiet again.
    wait("B to hold A as quiet again", 30, || {
        round(&b);
        quiet(&b, &a_id)
    });
    a.close();
    b.close();
}
