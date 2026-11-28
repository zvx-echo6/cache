//! Step 4 proof (b) against the real test rnsds on cache-build-1: failover between two entry points. Two linked engines each have
//! entries for hub1 AND hub2 (both rnsds running, not joined), Reticulum in the "entries" mode (no Wi-Fi auto), and iroh given
//! nothing to find the other with (no relay, DHT, mDNS or lookup, and the link code carries no iroh address). A 30 MB file starts
//! to sync; mid-sync hub1 is stopped (`~/rns4/run.sh stop hub1`, run by this test); the sync must carry on through hub2 and the
//! file arrive whole.
//!
//! `#[ignore]`d: it starts no rnsd (`~/rns4/run.sh start hub1` and `start hub2` first), and is run by hand ON cache-build-1, because
//! the IFAC names and passphrases are read from `~/rns4/test-ifac.env` here, never printed or put on a command line:
//! `cargo test -p cache_sync --test real_rnsd_failover -- --ignored --nocapture`
//! Prints a timeline (seconds since the start) of the status's `via`, the transfer's progress and the engine's log lines.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use cache_sync::{Config, SyncEngine};
use common::*;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Instant;

const ID1: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const ID2: &str = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";

/// The entry records for hub1 and hub2, read from test-ifac.env here (the passphrases go only into the engines' own
/// `entry_points.json`, as the app keeps them).
fn records() -> Value {
    let text = std::fs::read_to_string(format!("{}/rns4/test-ifac.env", std::env::var("HOME").unwrap())).unwrap();
    let get = |k: &str| -> String {
        text.lines()
            .find_map(|l| l.strip_prefix(&format!("{k}=")))
            .unwrap_or_else(|| panic!("{k} is not in test-ifac.env"))
            .trim()
            .trim_matches('"')
            .to_string()
    };
    let rec = |id: &str, hub: &str| {
        let addr = get(&format!("{hub}_ADDR"));
        let (host, port) = addr.rsplit_once(':').unwrap();
        json!({"id": id, "host": host, "port": port.parse::<u16>().unwrap(), "private": true, "network_name": get(&format!("{hub}_NAME")),
               "passphrase": get(&format!("{hub}_PASS")), "on": true, "cap_bytes": 50 * 1024 * 1024, "t": 1_790_000_000_000u64, "dev": "dev-x"})
    };
    json!([rec(ID1, "HUB1"), rec(ID2, "HUB2")])
}

fn engine_entries(dir: &Path, name: &str) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "reticulum": "entries",
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn entry_status(e: &SyncEngine) -> String {
    let l = call(e, "entry_points", json!({}));
    let tag = |v: &Value| if v["id"] == ID1 { "hub1" } else { "hub2" };
    l["entries"].as_array().unwrap().iter().map(|v| format!("{}={}", tag(v), v["status"].as_str().unwrap_or("?"))).collect::<Vec<_>>().join(" ")
}

fn sha256(p: &Path) -> String {
    let o = std::process::Command::new("sha256sum").arg(p).output().unwrap();
    String::from_utf8(o.stdout).unwrap().split_whitespace().next().unwrap().to_string()
}

fn stamp(t0: &Instant, what: &str) {
    println!("[{:7.1}s] {what}", t0.elapsed().as_secs_f64());
}

#[test]
#[ignore]
fn proof_b_failover_from_hub1_to_hub2_mid_sync() {
    let t0 = Instant::now();
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    rns_only_dirs(&[&da, &db]);
    for d in [&da, &db] {
        std::fs::write(d.join("entry_points.json"), records().to_string()).unwrap();
    }
    let a = engine_entries(&da, "Desk");
    let b = engine_entries(&db, "Phone");
    wait("both engines connected to both hubs", 90, || entry_status(&a).matches("=connected").count() >= 1 && entry_status(&b).matches("=connected").count() >= 1);
    stamp(&t0, &format!("A: {}  B: {}", entry_status(&a), entry_status(&b)));

    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert!(code.starts_with("CACHE-") && !code.starts_with("CACHE1-"), "a short (Reticulum only) code");
    assert_eq!(call(&b, "link", json!({"code": code}))["name"], "Desk");
    stamp(&t0, "linked over Reticulum through the entry points");

    // A 30 MB file of data Prns will not compress, in a folder A shares and B joins.
    let big = random(30 * 1024 * 1024, 77);
    std::fs::write(fa.join("big.bin"), &big).unwrap();
    drop(big);
    let want = sha256(&fa.join("big.bin"));
    println!("sha256 of the 30 MB file: {want}");
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 90, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));
    stamp(&t0, "B joined: the 30 MB file starts to sync");

    let done_of = |e: &SyncEngine| call(e, "status", json!({}))["transfer"]["done"].as_u64();
    let mut last_via: Option<String> = None;
    let mut stopped_at: Option<f64> = None;
    let mut resumed_at: Option<f64> = None;
    let mut done_at_stop = 0u64;
    let mut last_done = 0u64;
    let mut last_printed = 0u64;
    let mut last_tick = 0u64;
    let mut diag_done = false;
    let mut vias: Vec<(f64, String)> = vec![];
    let end = Instant::now() + std::time::Duration::from_secs(420);
    let finished = loop {
        if let Some(st) = stopped_at {
            assert!(t0.elapsed().as_secs_f64() < st + 200.0, "the file did not arrive whole within 200 s of stopping hub1");
            if !diag_done && t0.elapsed().as_secs_f64() > st + 70.0 {
                diag_done = true;
                // Diagnostic: does hub2's rnsd itself still know a path to Desk? A standard RNS client on hub2 asks for it.
                let dest = saved_peer(&db)["rns"]["dest"].as_str().unwrap_or("").to_string();
                let home = std::env::var("HOME").unwrap();
                let o = std::process::Command::new(format!("{home}/rns4/venv/bin/python"))
                    .args([format!("{home}/rns4/probe.py"), "--config".into(), format!("{home}/rns4/probes/b-diag"), "--hub".into(), "hub2".into(), "find".into(), dest.clone(), "--wait".into(), "20".into()])
                    .output()
                    .unwrap();
                stamp(&t0, &format!("DIAG standard RNS client on hub2 asks for Desk ({dest}): {}", String::from_utf8_lossy(&o.stdout).replace('\n', " | ")));
            }
            let tick = (t0.elapsed().as_secs_f64() - st) as u64 / 10;
            if tick != last_tick {
                last_tick = tick;
                let peers = call(&b, "status", json!({}))["peers"].to_string();
                stamp(&t0, &format!("after stop: A: {}  B: {}  B peers: {}", entry_status(&a), entry_status(&b), peers.chars().take(400).collect::<String>()));
            }
        }
        assert!(Instant::now() < end, "the file did not arrive whole in 420 s");
        for l in cache_sync::take_log() {
            println!("[{:7.1}s] log: {l}", t0.elapsed().as_secs_f64());
        }
        let v = via(&b, "Desk");
        if v != last_via {
            stamp(&t0, &format!("B's via for Desk: {:?}", v));
            if let Some(v) = &v {
                vias.push((t0.elapsed().as_secs_f64(), v.clone()));
            }
            last_via = v;
        }
        let done = done_of(&b).unwrap_or(0);
        if done / (4 * 1024 * 1024) != last_printed / (4 * 1024 * 1024) || (done == 0) != (last_printed == 0) {
            stamp(&t0, &format!("B transfer done = {} MB", done / (1024 * 1024)));
            last_printed = done;
        }
        if stopped_at.is_some() && resumed_at.is_none() && done > done_at_stop {
            resumed_at = Some(t0.elapsed().as_secs_f64());
            stamp(&t0, &format!("progress resumed after the stop (done {} MB, via {:?})", done / (1024 * 1024), last_via));
        }
        last_done = done.max(last_done);
        if stopped_at.is_none() && done >= 8 * 1024 * 1024 {
            assert!(!fb.join("big.bin").exists(), "the file was already whole before hub1 was stopped");
            stamp(&t0, &format!("via before the stop: {:?}; A: {}  B: {}", last_via, entry_status(&a), entry_status(&b)));
            // Which hub carries the sync is the path table's choice, not the test's. Stopping the one that is NOT in use proves
            // nothing, so such a run is thrown away (hub1 is left running) and run again.
            assert_eq!(last_via.as_deref(), Some(format!("entry:{ID1}").as_str()), "INVALID RUN: the route is not through hub1, so stopping it is not a failover; run again");
            done_at_stop = done;
            let o = std::process::Command::new(format!("{}/rns4/run.sh", std::env::var("HOME").unwrap())).args(["stop", "hub1"]).output().unwrap();
            stopped_at = Some(t0.elapsed().as_secs_f64());
            stamp(&t0, &format!("STOPPED hub1 at done = {} MB: {}", done / (1024 * 1024), String::from_utf8_lossy(&o.stdout).trim()));
        }
        if fb.join("big.bin").exists() && call(&b, "status", json!({}))["transfer"].is_null() {
            break true;
        }
        std::thread::sleep(std::time::Duration::from_millis(250));
    };
    assert!(finished);
    let got = sha256(&fb.join("big.bin"));
    stamp(&t0, &format!("the file is whole on B; via now {:?}; A: {}  B: {}", via(&b, "Desk"), entry_status(&a), entry_status(&b)));
    println!("sha256 sent    {want}\nsha256 arrived {got}");
    println!("RESULT stopped_at={:?} resumed_at={:?} vias={:?}", stopped_at, resumed_at, vias);
    assert_eq!(got, want, "the file is byte for byte the original");
    assert!(stopped_at.is_some(), "hub1 was stopped mid-sync");
    // The row's route: it ends through hub2.
    let end_via = via(&b, "Desk");
    assert_eq!(end_via, Some(format!("entry:{ID2}")), "the device row ends as 'Through hub2'");
    for l in cache_sync::take_log() {
        println!("[{:7.1}s] log: {l}", t0.elapsed().as_secs_f64());
    }
    a.close();
    b.close();
}
