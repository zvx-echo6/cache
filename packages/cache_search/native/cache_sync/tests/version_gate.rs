//! The version gate: a device on another sync version stops syncing with this one, in both directions, and picks up again by
//! itself when the versions match. A "1.0" device is an engine with `legacy_proto` (sends no version, gates nothing, as 1.0.x);
//! a device on another version is one set to `SYNC_MIN_PROTO - 1` or to a newer range with `test_set_proto`. The numbers come from
//! the constants, so these stay true when they are raised.

use cache_sync::{Config, SyncEngine, SYNC_MIN_PROTO, SYNC_PROTO};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str, legacy: bool, port: Option<u16>) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "port": port, "app_version": "1.1.0", "legacy_proto": legacy,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn wait(what: &str, secs: u64, mut ok: impl FnMut() -> bool) {
    for _ in 0..secs * 4 {
        if ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("timed out waiting for {what}");
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn peer0(e: &SyncEngine) -> Value {
    call(e, "status", json!({}))["peers"][0].clone()
}

fn offers(e: &SyncEngine) -> usize {
    call(e, "status", json!({}))["offers"].as_array().map(|o| o.len()).unwrap_or(0)
}

/// How a device on another version is made: none at all (1.0.x, build 49), or one below this build's oldest.
#[derive(Clone, Copy, Debug)]
enum Old {
    NoVersion,
    BelowMin,
}

fn make_old(e: &SyncEngine, how: Old) {
    match how {
        Old::NoVersion => call(e, "test_set_proto", json!({"legacy": true})),
        // Below the oldest this build syncs with, and itself accepting only that and up.
        Old::BelowMin => call(e, "test_set_proto", json!({"proto": SYNC_MIN_PROTO - 1, "min": SYNC_MIN_PROTO - 1})),
    };
}

fn make_current(e: &SyncEngine) {
    call(e, "test_set_proto", json!({"proto": SYNC_PROTO, "min": SYNC_MIN_PROTO}));
}

/// Two linked devices, a share both joined, the files in it on both.
struct Pair {
    _tmp: tempfile::TempDir,
    a: SyncEngine,
    b: SyncEngine,
    fa: std::path::PathBuf,
    fb: std::path::PathBuf,
}

fn pair_with_files(a_name: &str, b_name: &str) -> Pair {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb) = (tmp.path().join("fa"), tmp.path().join("fb"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("keep.txt"), "kept").unwrap();
    std::fs::write(fa.join("remove.txt"), "to be removed").unwrap();
    let a = engine(&tmp.path().join("a"), a_name, false, None);
    let b = engine(&tmp.path().join("b"), b_name, false, None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    let share = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 30, || offers(&b) > 0);
    call(&b, "share_join", json!({"id": share, "path": fb}));
    wait("the files on B", 60, || fb.join("keep.txt").exists() && fb.join("remove.txt").exists());
    Pair { _tmp: tmp, a, b, fa, fb }
}

#[test]
fn matching_versions_sync_and_say_so() {
    let p = pair_with_files("Desk", "Phone");
    assert_eq!(peer0(&p.b)["compat"], "ok");
    assert_eq!(peer0(&p.b)["peer_version"], "1.1.0");
    assert_eq!(peer0(&p.b)["our_version"], "1.1.0");
    // And a removal on one arrives on the other.
    std::fs::remove_file(p.fa.join("remove.txt")).unwrap();
    call(&p.b, "sync_now", json!({}));
    wait("the removal on B", 60, || !p.fb.join("remove.txt").exists());
    p.a.close();
    p.b.close();
}

#[test]
fn an_unknown_device_is_gated_until_it_answers() {
    let tmp = tempfile::tempdir().unwrap();
    let fa = tmp.path().join("fa");
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("notes.txt"), "hello").unwrap();
    let a = engine(&tmp.path().join("a"), "Desk", false, None);
    let b = engine(&tmp.path().join("b"), "Phone", false, None);
    // Neither asks anything (no network it may use), so neither has heard from the other.
    call(&a, "set_policy", json!({"network": false}));
    call(&b, "set_policy", json!({"network": false}));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"path": fa, "name": "Family"}));
    call(&b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(3));
    // B has asked nothing (no network it may use): it has not heard from Desk, so Desk is unknown and nothing is offered.
    assert_eq!(peer0(&b)["compat"], "unknown");
    assert_eq!(offers(&b), 0);
    // And Desk gives B no files: B has not asked it anything, so it is not known to be compatible (rejected at the handshake).
    let a_id = peer0(&b)["id"].as_str().unwrap().to_string();
    let probe = call(&b, "test_blob_probe", json!({"peer": a_id}))["result"].as_str().unwrap().to_string();
    eprintln!("PROBE unknown: {probe}");
    assert_ne!(probe, "open", "an unknown device's file fetch is refused (by either side's gate): {probe}");
    // Check again with no network it may use connects to nothing and says so.
    assert_eq!(call(&b, "check_version", json!({"peer": a_id}))["compat"], "network_off");
    call(&a, "set_policy", json!({"network": true}));
    call(&b, "set_policy", json!({"network": true}));
    wait("the answer", 30, || peer0(&b)["compat"] == "ok");
    wait("the offer", 30, || offers(&b) > 0);
    let probe = call(&b, "test_blob_probe", json!({"peer": a_id}))["result"].as_str().unwrap().to_string();
    assert_eq!(probe, "open", "once compatible, the files protocol is open");
    a.close();
    b.close();
}

#[test]
fn a_device_with_no_version_or_below_the_oldest_cannot_fetch_files_and_gets_an_error() {
    for how in [Old::NoVersion, Old::BelowMin] {
        let p = pair_with_files("Desk", "Old");
        make_old(&p.b, how);
        let a_id = peer0(&p.b)["id"].as_str().unwrap().to_string();
        // Desk learns it from its next ask and refuses its file fetch at the handshake (409); a device on a version range also refuses
        // to fetch from Desk itself, through its own gate.
        wait("Desk to see the mismatch", 30, || peer0(&p.a)["compat"] == "peer_older");
        let probe = call(&p.b, "test_blob_probe", json!({"peer": a_id}))["result"].as_str().unwrap().to_string();
        eprintln!("PROBE {how:?}: {probe}");
        assert_ne!(probe, "open", "{how:?}: file fetch refused: {probe}");
        p.a.close();
        p.b.close();
    }
}

#[test]
fn a_current_device_removing_a_file_does_not_reach_an_old_one_that_stays_running() {
    for how in [Old::NoVersion, Old::BelowMin] {
        // Both devices on the old version, a share both joined, running, with the files on both.
        let tmp = tempfile::tempdir().unwrap();
        let (fa, fb) = (tmp.path().join("fa"), tmp.path().join("fb"));
        std::fs::create_dir_all(&fa).unwrap();
        std::fs::write(fa.join("keep.txt"), "kept").unwrap();
        std::fs::write(fa.join("remove.txt"), "to be removed").unwrap();
        let a = engine(&tmp.path().join("a"), "Desk", false, None);
        let b = engine(&tmp.path().join("b"), "Old", false, None);
        make_old(&a, how);
        make_old(&b, how);
        let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
        call(&b, "link", json!({"code": code}));
        let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
        call(&b, "share_join", json!({"id": id, "path": fb}));
        wait("the files on the old device", 60, || fb.join("keep.txt").exists() && fb.join("remove.txt").exists());

        // Desk moves to the current version and removes a file; the old device keeps running, with its index in memory.
        make_current(&a);
        std::fs::remove_file(fa.join("remove.txt")).unwrap();
        call(&a, "sync_now", json!({}));
        wait("Desk to see the old device", 30, || {
            call(&a, "sync_now", json!({}));
            peer0(&a)["compat"] == "peer_older"
        });
        // Rounds on both sides, several times over.
        std::thread::sleep(Duration::from_secs(16));
        assert!(fb.join("remove.txt").exists(), "{how:?}: the removal never reached the old device");
        assert!(fb.join("keep.txt").exists());
        assert_eq!(std::fs::read_to_string(fb.join("remove.txt")).unwrap(), "to be removed");
        assert!(!fa.join("remove.txt").exists(), "Desk kept its own removal");
        // And nothing came the other way: a new file on the old device is not taken by Desk.
        std::fs::write(fb.join("new.txt"), "from the old device").unwrap();
        call(&b, "sync_now", json!({}));
        std::thread::sleep(Duration::from_secs(10));
        assert!(!fa.join("new.txt").exists(), "{how:?}: nothing crosses to Desk either");
        a.close();
        b.close();
    }
}

#[test]
fn a_1_0_device_gets_an_error_and_nothing_crosses_then_it_updates_and_syncs() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb, fb2) = (tmp.path().join("fa"), tmp.path().join("fb"), tmp.path().join("fb2"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    std::fs::write(fa.join("notes.txt"), "from desk").unwrap();
    std::fs::write(fb.join("theirs.txt"), "from the old phone").unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let a = engine(&da, "Desk", false, None);
    let b = engine(&db, "Old phone", true, None);
    let b_port = b.port().unwrap();
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "share_add", json!({"path": fb, "name": "Old"}));
    // The old phone joins Desk's share (it would, from an offer it saw before); nothing may come.
    call(&b, "share_join", json!({"id": id, "path": fb2}));
    call(&a, "sync_now", json!({}));
    call(&b, "sync_now", json!({}));

    // Our side: the mismatch, no version from it, and nothing of its list kept.
    wait("the mismatch on Desk", 30, || peer0(&a)["compat"] == "peer_older");
    assert!(peer0(&a)["peer_version"].is_null());
    assert_eq!(peer0(&a)["our_version"], "1.1.0");
    // Their side: an error (what 1.0 shows as Not reachable; it keeps only "connection lost", not our text), never an answer.
    wait("the error on the old phone", 30, || peer0(&b)["error"].is_string());
    assert!(peer0(&b)["last_seen"].is_null(), "the old phone never got an answer from Desk");
    std::thread::sleep(Duration::from_secs(4));
    assert_eq!(offers(&a), 0, "nothing of theirs is offered here");
    assert_eq!(offers(&b), 0, "nothing of ours is offered there");
    std::thread::sleep(Duration::from_secs(8));
    assert!(!fb2.join("notes.txt").exists(), "no file crossed to the old phone, though it joined the share");
    assert!(!fa.join("theirs.txt").exists(), "no file crossed from the old phone");

    // Not asked again every round: the last time Desk heard from it stays put, until the person checks.
    let seen = peer0(&a)["last_seen"].clone();
    std::thread::sleep(Duration::from_secs(12));
    assert_eq!(peer0(&a)["last_seen"], seen, "a mismatched device is not retried on a schedule");
    let r = call(&a, "check_version", json!({"peer": peer0(&a)["id"]}));
    assert_eq!(r["compat"], "peer_older");
    assert_ne!(peer0(&a)["last_seen"], seen, "Check again asks now");

    // The old phone updates (restarts as a current build): Desk takes the new version when it is checked, with no new link.
    // (A restarted device is found again by the others only at its old port, so Desk reaches out; the phone learns Desk's address
    // from that connection. Out in the world the lookup services do this.)
    b.close();
    let b = engine(&db, "Old phone", false, Some(b_port));
    let pid = peer0(&a)["id"].clone();
    wait("the match on Desk", 40, || {
        let _ = a.call("check_version", &json!({"peer": pid}));
        peer0(&a)["compat"] == "ok"
    });
    wait("the file on the phone", 60, || fb2.join("notes.txt").exists());
    a.close();
    b.close();
}

#[test]
fn a_downgrade_is_a_mismatch_at_once_and_its_old_list_is_dropped() {
    let p = pair_with_files("Desk", "Phone");
    assert_eq!(peer0(&p.a)["compat"], "ok");
    // The phone is replaced by an older build while Desk keeps running: its next ask says so.
    make_old(&p.b, Old::NoVersion);
    wait("Desk to see the downgrade, with no round of its own", 20, || peer0(&p.a)["compat"] == "peer_older");
    assert_eq!(offers(&p.a), 0, "nothing is kept of its old list");
    std::fs::write(p.fb.join("late.txt"), "from the downgraded phone").unwrap();
    call(&p.b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(10));
    assert!(!p.fa.join("late.txt").exists(), "nothing is applied from its old list or its new one");
    p.a.close();
    p.b.close();
}

#[test]
fn keys_are_withheld_from_a_device_on_another_version() {
    let p = pair_with_files("Desk", "Phone");
    let b_id = peer0(&p.a)["id"].as_str().unwrap().to_string();
    let a_id = peer0(&p.b)["id"].as_str().unwrap().to_string();
    call(&p.a, "set_secrets", json!({"peer": b_id, "secrets": {"search.key": "s3cret"}}));
    // A matching device gets them...
    let got = call(&p.b, "test_fetch_secrets", json!({"peer": a_id}));
    assert_eq!(got["secrets"]["search.key"], "s3cret");
    // ...one with no version does not, nor one below the oldest.
    for how in [Old::NoVersion, Old::BelowMin] {
        make_old(&p.b, how);
        let r = p.b.call("test_fetch_secrets", &json!({"peer": a_id}));
        assert!(r.is_err(), "{how:?}: the keys are withheld: {r:?}");
        make_current(&p.b);
        assert_eq!(call(&p.b, "test_fetch_secrets", json!({"peer": a_id}))["secrets"]["search.key"], "s3cret", "and given again when it matches");
    }
    p.a.close();
    p.b.close();
}

#[test]
fn check_again_says_unreachable_not_a_stale_answer() {
    let p = pair_with_files("Desk", "Phone");
    let a_id = peer0(&p.b)["id"].as_str().unwrap().to_string();
    assert_eq!(call(&p.b, "check_version", json!({"peer": a_id}))["compat"], "ok");
    // Desk goes away: what B knew of it (ok) is not given as the answer.
    p.a.close();
    let r = call(&p.b, "check_version", json!({"peer": a_id}));
    assert_eq!(r["compat"], "unreachable", "{r}");
    assert_eq!(r["ok"], false);
    p.b.close();
}

#[test]
fn a_newer_device_that_cannot_sync_with_us_is_told_our_version() {
    // The header-only answer: a device on a range above ours still learns ours (so it can say so), and gets nothing else.
    let p = pair_with_files("Desk", "Phone");
    call(&p.b, "test_set_proto", json!({"proto": SYNC_PROTO + 1, "min": SYNC_PROTO + 1}));
    wait("Desk to see a newer device", 30, || peer0(&p.a)["compat"] == "peer_newer");
    assert_eq!(peer0(&p.a)["peer_version"], "1.1.0", "it sent its version in the header-only list");
    assert_eq!(offers(&p.a), 0);
    // The phone learns Desk is older than it accepts, from the same short answer.
    wait("the phone to see Desk as older", 30, || peer0(&p.b)["compat"] == "peer_older");
    assert_eq!(peer0(&p.b)["peer_version"], "1.1.0");
    p.a.close();
    p.b.close();
}
