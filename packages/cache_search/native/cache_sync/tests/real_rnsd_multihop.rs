//! Step 4 proof (g) against the real test rnsds on cache-build-1: two linked engines that reach each other only through several
//! hops. A has an entry for hub1 only, B for hub2 only (hub2-chained is running, hub2 is stopped, so the two rnsds are joined and
//! an announce crosses both). Each engine is held to its OWN entry: the `no-entries-v` hook makes it act as a build that does not
//! say its entry list changed, so neither asks for the other's list and neither gets an entry on the other's rnsd. Reticulum is in
//! the "entries" mode (no Wi-Fi auto), and iroh is given nothing (no relay, DHT, mDNS or lookup; no iroh address in the hello; the
//! short link code carries none), so the only way to each other is the standard path request answered through the chain.
//!
//! Asserts: the engines link (a short code, so a path request through the rnsds and no direct path: they share no rnsd), a small
//! file syncs whole, the link is up, each side's `via` for the other is its own entry, and the hop count the node's routing table
//! gives (Prns `NodeIntrospection::route`, read through the `test_route_hops` hook) is more than 1 for each other's destination.
//!
//! `#[ignore]`d: it starts no rnsd (`~/rns4/run.sh start hub1`, `start hub2-chained` first, hub2 stopped), and is run by hand ON
//! cache-build-1, because the IFAC names and passphrases are read from `~/rns4/test-ifac.env` here, never printed or put on a
//! command line: `cargo test -p cache_sync --test real_rnsd_multihop -- --ignored --nocapture`
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use cache_sync::{Config, SyncEngine};
use common::*;
use serde_json::{json, Value};
use std::path::Path;
use std::time::Instant;

const ID1: &str = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const ID2: &str = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";

/// The entry record for `hub` ("HUB1" or "HUB2"), read from test-ifac.env here (the passphrase goes only into the engine's own
/// `entry_points.json`, as the app keeps it).
fn record(id: &str, hub: &str) -> Value {
    let text = std::fs::read_to_string(format!("{}/rns4/test-ifac.env", std::env::var("HOME").unwrap())).unwrap();
    let get = |k: &str| -> String {
        text.lines()
            .find_map(|l| l.strip_prefix(&format!("{k}=")))
            .unwrap_or_else(|| panic!("{k} is not in test-ifac.env"))
            .trim()
            .trim_matches('"')
            .to_string()
    };
    let addr = get(&format!("{hub}_ADDR"));
    let (host, port) = addr.rsplit_once(':').unwrap();
    json!({"id": id, "host": host, "port": port.parse::<u16>().unwrap(), "private": true, "network_name": get(&format!("{hub}_NAME")),
           "passphrase": get(&format!("{hub}_PASS")), "on": true, "cap_bytes": 50 * 1024 * 1024, "t": 1_790_000_000_000u64, "dev": "dev-x"})
}

fn engine_entries(dir: &Path, name: &str) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "reticulum": "entries",
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

/// The ids of the entries the engine lists and their statuses, e.g. "a1a1...=connected".
fn entry_status(e: &SyncEngine) -> Vec<(String, String)> {
    let l = call(e, "entry_points", json!({}));
    l["entries"].as_array().unwrap().iter().map(|v| (v["id"].as_str().unwrap().to_string(), v["status"].as_str().unwrap_or("?").to_string())).collect()
}

fn sha256(p: &Path) -> String {
    let o = std::process::Command::new("sha256sum").arg(p).output().unwrap();
    String::from_utf8(o.stdout).unwrap().split_whitespace().next().unwrap().to_string()
}

fn stamp(t0: &Instant, what: &str) {
    println!("[{:7.1}s] {what}", t0.elapsed().as_secs_f64());
}

fn hops(e: &SyncEngine, dest: &str) -> Option<u64> {
    call(e, "test_route_hops", json!({"dest": dest}))["hops"].as_u64()
}

#[test]
#[ignore]
fn proof_g_two_devices_through_the_chained_rnsds_are_more_than_one_hop_apart() {
    let t0 = Instant::now();
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    rns_only_dirs(&[&da, &db]);
    std::fs::write(da.join("entry_points.json"), json!([record(ID1, "HUB1")]).to_string()).unwrap();
    std::fs::write(db.join("entry_points.json"), json!([record(ID2, "HUB2")]).to_string()).unwrap();
    // Each device keeps its own entry list: it does not say its list changed, so the other never asks for it.
    for d in [&da, &db] {
        std::fs::write(d.join("no-entries-v"), b"").unwrap();
    }
    let a = engine_entries(&da, "Desk");
    let b = engine_entries(&db, "Phone");
    wait("each engine connected to its own rnsd", 90, || {
        entry_status(&a).iter().any(|(_, s)| s == "connected") && entry_status(&b).iter().any(|(_, s)| s == "connected")
    });
    stamp(&t0, &format!("A (hub1 only): {:?}  B (hub2-chained only): {:?}", entry_status(&a), entry_status(&b)));

    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert!(code.starts_with("CACHE-") && !code.starts_with("CACHE1-"), "a short (Reticulum only) code: no iroh address, so no direct path");
    assert_eq!(call(&b, "link", json!({"code": code}))["name"], "Desk");
    stamp(&t0, "linked over Reticulum through the chained rnsds");

    // A small file in a folder A shares and B joins.
    let small = random(300 * 1024, 91);
    std::fs::write(fa.join("small.bin"), &small).unwrap();
    drop(small);
    let want = sha256(&fa.join("small.bin"));
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 90, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));
    wait("the file on B", 120, || fb.join("small.bin").exists() && call(&b, "status", json!({}))["transfer"].is_null());
    let got = sha256(&fb.join("small.bin"));
    stamp(&t0, "the small file is whole on B");
    println!("sha256 sent    {want}\nsha256 arrived {got}");
    assert_eq!(got, want, "the file is byte for byte the original");

    // The link is up, each side reaches the other through its own entry, and neither engine learned the other's entry.
    for (e, other, own) in [(&a, "Phone", ID1), (&b, "Desk", ID2)] {
        let st = call(e, "status", json!({}));
        let p = st["peers"].as_array().unwrap().iter().find(|p| p["name"] == other).unwrap();
        assert_eq!(p["live"], true, "the link to {other} is up: {p}");
        assert_eq!(p["via"], format!("entry:{own}"), "{other} is reached through this device's own entry");
        let ids: Vec<String> = entry_status(e).into_iter().map(|(i, _)| i).collect();
        assert_eq!(ids, vec![own.to_string()], "the entry list was not synced: only its own entry");
    }
    stamp(&t0, "both links up, each through its own entry, entry lists not shared");

    // The hop count the routing table gives for the other device's destination.
    let (dest_of_b, dest_of_a) = (saved_peer(&da)["rns"]["dest"].as_str().unwrap().to_string(), saved_peer(&db)["rns"]["dest"].as_str().unwrap().to_string());
    let (h_a, h_b) = (hops(&a, &dest_of_b), hops(&b, &dest_of_a));
    println!("RESULT hops A->B {h_a:?}  B->A {h_b:?}");
    assert!(h_a.is_some_and(|h| h > 1), "A's route to B is more than one hop: {h_a:?}");
    assert!(h_b.is_some_and(|h| h > 1), "B's route to A is more than one hop: {h_b:?}");
    for l in cache_sync::take_log() {
        println!("log: {l}");
    }
    a.close();
    b.close();
}
