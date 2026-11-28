//! Step 4 failover at the engine level: two linked engines each have entries for two stand-in rnsds (not joined); a 30 MB file is
//! syncing through the one the route is through; that stand-in stops mid-transfer; the file arrives whole (sha256 equal) and the
//! device's `via` moves to the other entry.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use cache_sync::{Config, SyncEngine};
use common::*;
use serde_json::json;
use std::path::Path;
use std::time::{Duration, Instant};

const ID1: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const ID2: &str = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";
const NAME1: &str = "cache-test-one";
const PASS1: &str = "pass-one-test-value-7f3a";
const NAME2: &str = "cache-test-two";
const PASS2: &str = "pass-two-test-value-9c1d";

fn engine_entries(dir: &Path, name: &str) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "reticulum": "entries",
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn sha256(p: &Path) -> String {
    let o = std::process::Command::new("sha256sum").arg(p).output().unwrap();
    String::from_utf8(o.stdout).unwrap().split_whitespace().next().unwrap().to_string()
}

#[test]
fn a_30_mb_sync_carries_on_through_the_other_entry_when_the_one_in_use_stops() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    let (p1, p2) = (free_port(), free_port());
    let s1 = rnsd::server(p1, Some((NAME1, PASS1)));
    let s2 = rnsd::server(p2, Some((NAME2, PASS2)));
    rns_only_dirs(&[&da, &db]);
    let rec = |id: &str, port: u16, name: &str, pass: &str| {
        json!({"id": id, "host": "127.0.0.1", "port": port, "private": true, "network_name": name, "passphrase": pass, "on": true,
               "cap_bytes": 50 * 1024 * 1024, "t": 1_790_000_000_000u64, "dev": "dev-x"})
    };
    let records = json!([rec(ID1, p1, NAME1, PASS1), rec(ID2, p2, NAME2, PASS2)]).to_string();
    for d in [&da, &db] {
        std::fs::write(d.join("entry_points.json"), &records).unwrap();
    }
    let a = engine_entries(&da, "Desk");
    let b = engine_entries(&db, "Phone");
    let connected = |e: &SyncEngine| {
        call(e, "entry_points", json!({}))["entries"].as_array().unwrap().iter().filter(|v| v["status"] == "connected").count()
    };
    wait("both engines connected to both", 60, || connected(&a) == 2 && connected(&b) == 2);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert_eq!(call(&b, "link", json!({"code": code}))["name"], "Desk");

    let big = random(30 * 1024 * 1024, 77);
    std::fs::write(fa.join("big.bin"), &big).unwrap();
    drop(big);
    let want = sha256(&fa.join("big.bin"));
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 90, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    // The route B uses to Desk decides which stand-in is stopped (stopping the other proves nothing).
    wait("B knows its entry for Desk", 60, || {
        call(&b, "sync_now", json!({}));
        via(&b, "Desk").is_some_and(|v| v.starts_with("entry:"))
    });
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));

    let done_of = |e: &SyncEngine| call(e, "status", json!({}))["transfer"]["done"].as_u64().unwrap_or(0);
    let mut stop = Some(());
    let (mut s1, mut s2) = (Some(s1), Some(s2));
    let mut used: Option<String> = None;
    let mut stopped_at: Option<Instant> = None;
    let end = Instant::now() + Duration::from_secs(300);
    loop {
        assert!(Instant::now() < end, "the file did not arrive whole in 300 s (via {:?})", via(&b, "Desk"));
        if let Some(t) = stopped_at {
            assert!(t.elapsed() < Duration::from_secs(150), "the file did not arrive whole within 150 s of the stop (via {:?}, done {} MB)", via(&b, "Desk"), done_of(&b) >> 20);
        } else if done_of(&b) >= 8 * 1024 * 1024 {
            assert!(!fb.join("big.bin").exists(), "the file was already whole before the stop");
            let v = via(&b, "Desk").expect("a route");
            used = Some(v.clone());
            stop.take();
            // Only the one in use stops; the other sender is kept (dropping it would stop that stand-in too).
            let dead = if v == format!("entry:{ID1}") { s1.take() } else { s2.take() };
            dead.unwrap().send(()).ok();
            stopped_at = Some(Instant::now());
        }
        if fb.join("big.bin").exists() && call(&b, "status", json!({}))["transfer"].is_null() {
            break;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    assert_eq!(sha256(&fb.join("big.bin")), want, "the file is byte for byte the original");
    let used = used.expect("the stop happened mid-transfer");
    let other = if used == format!("entry:{ID1}") { format!("entry:{ID2}") } else { format!("entry:{ID1}") };
    assert_eq!(via(&b, "Desk"), Some(other), "the device row ends through the other entry");
    drop((s1, s2));
    a.close();
    b.close();
}
