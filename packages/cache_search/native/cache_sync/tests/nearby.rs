//! Nearby linking between engines with Reticulum on over loopback TCP (the test switch makes TCP count as local, as Wi-Fi does
//! on a phone; iroh has no relay, DHT, mDNS or lookup, so everything after the pairing can only go over Reticulum).
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use cache_sync::{Config, SyncEngine};
use common::*;
use serde_json::{json, Value};
use std::path::Path;

fn nearby_engine(dir: &Path, name: &str, kind: &str, listen: Option<u16>, connect: Option<u16>) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "reticulum": true, "device_kind": kind,
        "rns_interfaces": {
            "tcp_listen": listen.map(|p| format!("127.0.0.1:{p}")),
            "tcp_connect": connect.map(|p| format!("127.0.0.1:{p}")),
            "pair_local_tcp": true,
        },
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn state(e: &SyncEngine) -> Value {
    call(e, "nearby_state", json!({}))
}

fn state_is(e: &SyncEngine, s: &str) -> bool {
    state(e)["state"] == s
}

/// The id of the device named `name` in `e`'s Nearby list, once it is there with its name and kind.
fn listed(e: &SyncEngine, name: &str, kind: &str) -> String {
    let mut id = None;
    wait(&format!("{name} in the Nearby list"), 45, || {
        let l = call(e, "nearby_list", json!({}));
        id = l["devices"].as_array().and_then(|d| d.iter().find(|x| x["name"] == name && x["kind"] == kind)).map(|x| {
            assert_eq!(x["via"], "wifi");
            x["id"].as_str().unwrap().to_string()
        });
        id.is_some()
    });
    id.unwrap()
}

fn peers(dir: &Path) -> usize {
    let v: Value = serde_json::from_slice(&std::fs::read(dir.join("sync.json")).unwrap()).unwrap();
    v["peers"].as_array().map(|p| p.len()).unwrap_or(0)
}

fn words(e: &SyncEngine) -> Vec<String> {
    state(e)["words"].as_array().unwrap().iter().map(|w| w.as_str().unwrap().to_string()).collect()
}

fn pair(dir_a: &Path, dir_b: &Path, port: u16) -> (SyncEngine, SyncEngine) {
    let a = nearby_engine(dir_a, "Desk", "computer", Some(port), None);
    let b = nearby_engine(dir_b, "Phone", "phone", None, Some(port));
    call(&a, "pairing_open", json!({}));
    call(&b, "pairing_open", json!({}));
    (a, b)
}

#[test]
fn both_list_each_other_see_the_same_words_confirm_and_sync() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("notes.txt"), "first").unwrap();
    let (a, b) = pair(&da, &db, free_port());

    // Each lists the other with its name and kind.
    let phone = listed(&a, "Phone", "phone");
    let desk = listed(&b, "Desk", "computer");
    assert_ne!(phone, desk);

    // A taps Link: B shows the incoming request, then both show the same three words.
    call(&a, "nearby_link", json!({"id": phone}));
    wait("words on both", 45, || state_is(&a, "words") && state_is(&b, "words"));
    let (wa, wb) = (words(&a), words(&b));
    assert_eq!(wa.len(), 3);
    assert_eq!(wa, wb, "both devices show the same three words");
    assert_eq!(state(&b)["name"], "Desk", "B shows who is asking");
    assert_eq!(state(&a)["name"], "Phone");
    assert_eq!(peers(&da) + peers(&db), 0, "nothing is kept before both confirm");

    call(&a, "nearby_answer", json!({"ok": true}));
    wait("A to wait for B", 10, || state_is(&a, "waiting"));
    assert_eq!(peers(&da) + peers(&db), 0, "one confirmation keeps nothing");
    call(&b, "nearby_answer", json!({"ok": true}));
    wait("both linked", 20, || state_is(&a, "linked") && state_is(&b, "linked"));

    // Stored as a code link is: the device, its name, and its Reticulum address.
    wait("both sides to hold the other", 20, || peers(&da) == 1 && peers(&db) == 1);
    assert_eq!(saved_peer(&da)["name"], "Phone");
    assert_eq!(saved_peer(&db)["name"], "Desk");
    wait("both sides to hold the address", 20, || saved_peer(&da)["rns"]["dest"].is_string() && saved_peer(&db)["rns"]["dest"].is_string());
    assert!(saved_peer(&da)["unconfirmed"].is_null() || saved_peer(&da)["unconfirmed"] == false);

    // And they sync, over Reticulum.
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 90, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));
    wait("the file on B", 90, || fb.join("notes.txt").exists());
    assert_eq!(std::fs::read_to_string(fb.join("notes.txt")).unwrap(), "first");
    assert_eq!(via(&b, "Desk").as_deref(), Some("reticulum"));

    // The pairing address is used up: the page is closed on both, and the list is empty.
    call(&a, "pairing_close", json!({}));
    call(&b, "pairing_close", json!({}));
    assert!(call(&a, "nearby_list", json!({}))["devices"].as_array().unwrap().is_empty());
    a.close();
    b.close();
}

#[test]
fn a_stranger_declined_leaves_nothing() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (a, b) = pair(&da, &db, free_port());
    let phone = listed(&a, "Phone", "phone");
    call(&a, "nearby_link", json!({"id": phone}));
    wait("words on both", 45, || state_is(&a, "words") && state_is(&b, "words"));
    // B does not know this device: Cancel.
    call(&b, "nearby_answer", json!({"ok": false}));
    wait("both dropped", 20, || state_is(&a, "dropped") && state_is(&b, "dropped"));
    assert_eq!(state(&a)["reason"], "cancelled");
    assert_eq!(state(&b)["reason"], "cancelled");
    std::thread::sleep(std::time::Duration::from_secs(2));
    assert_eq!((peers(&da), peers(&db)), (0, 0), "nothing is stored on either side");
    a.close();
    b.close();
}

#[test]
fn a_man_in_the_middle_makes_the_words_differ_and_nothing_is_kept() {
    let tmp = tempfile::tempdir().unwrap();
    let d = |n: &str| tmp.path().join(n);
    let (pa, pb) = (free_port(), free_port());
    // A and B are far apart. The relay is two devices: R1 sits next to A and calls itself what B is called; R2 sits next to B and
    // calls itself what A is called. Each runs its own exchange, one as B to A and one as A to B.
    let a = nearby_engine(&d("a"), "Desk A", "computer", Some(pa), None);
    let r1 = nearby_engine(&d("r1"), "Phone B", "phone", None, Some(pa));
    let b = nearby_engine(&d("b"), "Phone B", "phone", Some(pb), None);
    let r2 = nearby_engine(&d("r2"), "Desk A", "computer", None, Some(pb));
    for e in [&a, &r1, &b, &r2] {
        call(e, "pairing_open", json!({}));
    }
    let b_as_seen_by_a = listed(&a, "Phone B", "phone");
    let a_as_seen_by_b = listed(&b, "Desk A", "computer");
    let _ = a_as_seen_by_b;
    let b_as_seen_by_r2 = listed(&r2, "Phone B", "phone");

    // A taps Link on what looks like B; the relay carries it on to B with its own exchange.
    call(&a, "nearby_link", json!({"id": b_as_seen_by_a}));
    call(&r2, "nearby_link", json!({"id": b_as_seen_by_r2}));
    wait("words on all four", 60, || [&a, &r1, &b, &r2].iter().all(|e| state_is(e, "words")));
    let (wa, wb) = (words(&a), words(&b));
    assert_eq!(wa, words(&r1), "A's exchange is with the relay");
    assert_eq!(wb, words(&r2), "B's exchange is with the relay");
    assert_ne!(wa, wb, "A and B are shown different words");

    // The two people compare, see they differ, and cancel.
    call(&a, "nearby_answer", json!({"ok": false}));
    call(&b, "nearby_answer", json!({"ok": false}));
    wait("A and B dropped", 20, || state_is(&a, "dropped") && state_is(&b, "dropped"));
    call(&r1, "nearby_answer", json!({"ok": false}));
    call(&r2, "nearby_answer", json!({"ok": false}));
    std::thread::sleep(std::time::Duration::from_secs(2));
    for n in ["a", "b", "r1", "r2"] {
        assert_eq!(peers(&d(n)), 0, "{n} keeps no link");
    }
    for e in [a, r1, b, r2] {
        e.close();
    }
}

#[test]
fn three_refusals_and_the_next_request_is_busy_for_a_minute() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (a, b) = pair(&da, &db, free_port());
    let phone = listed(&a, "Phone", "phone");
    for round in 1..=3 {
        call(&a, "nearby_link", json!({"id": phone}));
        wait(&format!("words, try {round}"), 45, || state_is(&a, "words") && state_is(&b, "words"));
        call(&b, "nearby_answer", json!({"ok": false}));
        wait(&format!("dropped, try {round}"), 20, || state_is(&a, "dropped") && state_is(&b, "dropped"));
    }
    // The fourth is turned away, and A is told so.
    call(&a, "nearby_link", json!({"id": phone}));
    wait("A to be told busy", 30, || state_is(&a, "dropped") && state(&a)["reason"] == "busy");
    assert!(!state_is(&b, "incoming") && !state_is(&b, "words"), "B never showed it");

    // A minute later (on B's clock) it is let through again.
    call(&b, "test_skew_clock", json!({"ms": 61_000}));
    call(&a, "nearby_link", json!({"id": phone}));
    wait("words again", 45, || state_is(&a, "words") && state_is(&b, "words"));
    call(&b, "nearby_answer", json!({"ok": false}));
    assert_eq!((peers(&da), peers(&db)), (0, 0));
    a.close();
    b.close();
}

#[test]
fn sixty_seconds_without_an_answer_drops_with_timeout() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (a, b) = pair(&da, &db, free_port());
    let phone = listed(&a, "Phone", "phone");
    call(&a, "nearby_link", json!({"id": phone}));
    wait("words on both", 45, || state_is(&a, "words") && state_is(&b, "words"));
    // Nobody answers; 60 seconds pass (the test clock).
    call(&a, "test_skew_clock", json!({"ms": 61_000}));
    call(&b, "test_skew_clock", json!({"ms": 61_000}));
    wait("both dropped", 20, || state_is(&a, "dropped") && state_is(&b, "dropped"));
    assert_eq!(state(&a)["reason"], "timeout");
    assert_eq!(state(&b)["reason"], "timeout");
    assert_eq!((peers(&da), peers(&db)), (0, 0));
    a.close();
    b.close();
}
