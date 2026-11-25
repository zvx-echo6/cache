//! Entry points in the engine (step 4, part 2): the four calls and the file they keep, the list between linked devices (over iroh
//! and over Reticulum), start-up from the file, the background mode with no Wi-Fi auto, and a peer's `via` through an entry point.
//! Stand-in rnsds (Prns transport nodes keyed with IFAC, on loopback) take the place of a real rnsd.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use cache_sync::{Config, SyncEngine};
use common::*;
use serde_json::{json, Value};
use std::path::Path;

const NAME1: &str = "cache-test-one";
const PASS1: &str = "pass-one-test-value-7f3a";
const SECRET: &str = "sekret-pass-123-do-not-print";

/// An engine with Reticulum as `reticulum` says (true, or "entries"), no interfaces of the test block but those the file or the
/// calls give, and no iroh lookups.
fn engine_entries(dir: &Path, name: &str, reticulum: Value) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "reticulum": reticulum, "rns_interfaces": {},
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn list(e: &SyncEngine) -> Vec<Value> {
    call(e, "entry_points", json!({}))["entries"].as_array().expect("an entries list").clone()
}

fn find(e: &SyncEngine, id: &str) -> Option<Value> {
    list(e).into_iter().find(|v| v["id"] == id)
}

fn status_of(e: &SyncEngine, id: &str) -> String {
    find(e, id).map(|v| v["status"].as_str().unwrap_or("?").to_string()).unwrap_or_else(|| "absent".into())
}

fn add(e: &SyncEngine, host: &str, port: u16, name: Option<&str>, pass: Option<&str>) -> String {
    let mut a = json!({"host": host, "port": port, "private": name.is_some() || pass.is_some()});
    if let Some(n) = name {
        a["network_name"] = json!(n);
    }
    if let Some(p) = pass {
        a["passphrase"] = json!(p);
    }
    call(e, "entry_point_set", a)["id"].as_str().expect("the id of the new entry").to_string()
}

fn saved_file(dir: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(dir.join("entry_points.json")).expect("entry_points.json is written")).unwrap()
}

fn records(dir: &Path) -> Vec<Value> {
    saved_file(dir).as_array().expect("the file is a list of records").clone()
}

/// Every file under `dir` that holds `needle`.
fn files_holding(dir: &Path, needle: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for f in rd.flatten() {
            let p = f.path();
            if p.is_dir() {
                stack.push(p);
            } else if std::fs::read(&p).map(|b| b.windows(needle.len()).any(|w| w == needle.as_bytes())).unwrap_or(false) {
                out.push(p.strip_prefix(dir).unwrap().display().to_string());
            }
        }
    }
    out
}

/// Two engines over loopback TCP, linked with a short code over Reticulum.
fn pair_over_reticulum(tmp: &Path) -> (SyncEngine, SyncEngine, std::path::PathBuf, std::path::PathBuf) {
    let (da, db) = (tmp.join("a"), tmp.join("b"));
    let port = free_port();
    rns_only_dirs(&[&da, &db]);
    let a = engine(&da, "Desk", Some(port), None, None);
    let b = engine(&db, "Phone", None, Some(port), None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("both sides to hold the address", 20, || saved_peer(&da)["rns"]["dest"].is_string() && saved_peer(&db)["rns"]["dest"].is_string());
    (a, b, da, db)
}

#[test]
fn the_calls_add_edit_switch_and_remove_and_the_file_follows() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("a");
    let a = old_engine(&dir, "Desk", None);
    assert!(list(&a).is_empty());

    // What is refused, in plain words.
    let refuse = |args: Value| a.call("entry_point_set", &args).expect_err("refused").to_string();
    assert!(refuse(json!({"host": "  ", "port": 4965})).to_lowercase().contains("address"));
    assert!(refuse(json!({"host": "rt.example.net", "port": 0})).to_lowercase().contains("port"));
    assert!(refuse(json!({"host": "rt.example.net", "port": 70000})).to_lowercase().contains("port"));
    assert!(refuse(json!({"host": "rt.example.net", "port": 4965, "private": true})).to_lowercase().contains("network name or a passphrase"));
    assert!(list(&a).is_empty(), "nothing refused is kept");

    let id = add(&a, "rt.example.net", 4965, Some("net-one"), Some(SECRET));
    assert_eq!(id.len(), 32, "16 random bytes in hex");
    assert!(id.chars().all(|c| c.is_ascii_hexdigit()));
    let v = find(&a, &id).unwrap();
    assert_eq!(v["host"], "rt.example.net");
    assert_eq!(v["port"], 4965);
    assert_eq!(v["private"], true);
    assert_eq!(v["network_name"], "net-one");
    assert_eq!(v["has_passphrase"], true);
    assert_eq!(v["on"], true);
    assert_eq!(v["cap_bytes"], 50 * 1024 * 1024);
    assert!(v.get("passphrase").is_none(), "the passphrase is never returned");
    assert!(v["status"].is_string());
    let t0 = v["t"].as_u64().unwrap();
    assert!(t0 > 1_700_000_000_000, "t is in ms");
    assert_eq!(v["dev"], call(&a, "status", json!({}))["id"]);

    // A duplicate of host:port is refused (any letter case), an edit of the same entry is not.
    let dup = refuse(json!({"host": "RT.example.net", "port": 4965}));
    assert!(dup.to_lowercase().contains("already"), "{dup}");
    assert_eq!(list(&a).len(), 1);

    // An edit that sends no passphrase keeps the one saved.
    std::thread::sleep(std::time::Duration::from_millis(5));
    call(&a, "entry_point_set", json!({"id": id, "host": "rt2.example.net", "port": 4966, "private": true, "network_name": "net-one"}));
    let v = find(&a, &id).unwrap();
    assert_eq!((v["host"].clone(), v["port"].clone(), v["has_passphrase"].clone()), (json!("rt2.example.net"), json!(4966), json!(true)));
    assert!(v["t"].as_u64().unwrap() > t0, "an edit bumps t");
    assert_eq!(records(&dir)[0]["passphrase"], SECRET, "the saved passphrase is still the one entered");

    // Off and on.
    call(&a, "entry_point_on", json!({"id": id, "on": false}));
    let v = find(&a, &id).unwrap();
    assert_eq!((v["on"].clone(), v["status"].clone()), (json!(false), json!("off")));
    assert_eq!(records(&dir)[0]["on"], false);
    call(&a, "entry_point_on", json!({"id": id, "on": true}));
    assert_eq!(find(&a, &id).unwrap()["on"], true);
    assert!(a.call("entry_point_on", &json!({"id": "00", "on": true})).is_err(), "no such entry point");

    // Remove: gone from the list; the file keeps a removal with no settings in it.
    call(&a, "entry_point_remove", json!({"id": id}));
    assert!(list(&a).is_empty());
    let recs = records(&dir);
    assert_eq!(recs.len(), 1);
    assert_eq!((recs[0]["id"].clone(), recs[0]["removed"].clone()), (json!(id), json!(true)));
    assert!(recs[0]["t"].as_u64().unwrap() > t0 && recs[0]["dev"].is_string());
    assert!(recs[0].get("host").is_none_or(|h| h.as_str().is_none_or(str::is_empty)), "a removal keeps no address");
    assert!(recs[0].get("passphrase").is_none_or(|p| p.is_null()), "a removal keeps no passphrase");
    assert!(!dir.join("entry_points.tmp").exists(), "written through a temporary file and renamed");
    // The same address can be entered again once removed.
    add(&a, "rt2.example.net", 4966, None, None);
    assert_eq!(list(&a).len(), 1);
    a.close();

    // The list is this device's own configuration: it is there after a restart.
    let a = old_engine(&dir, "Desk", None);
    assert_eq!(list(&a).len(), 1);
    a.close();
}

#[test]
fn the_passphrase_never_appears_in_any_output_or_in_the_log() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("a");
    let a = old_engine(&dir, "Desk", None);
    let seen = std::cell::RefCell::new(String::new());
    let note = |v: &Value| seen.borrow_mut().push_str(&v.to_string());
    let args = json!({"host": "rt.example.net", "port": 4965, "private": true, "network_name": "net-one", "passphrase": SECRET});
    note(&call(&a, "entry_point_set", args));
    // An error that comes with the passphrase in the request must not repeat it.
    let err = a.call("entry_point_set", &json!({"host": "rt.example.net", "port": 4965, "private": true, "passphrase": SECRET})).unwrap_err();
    seen.borrow_mut().push_str(&format!("{err:#}"));
    note(&call(&a, "entry_points", json!({})));
    let id = list(&a)[0]["id"].as_str().unwrap().to_string();
    note(&call(&a, "entry_point_on", json!({"id": id, "on": false})));
    note(&call(&a, "entry_point_on", json!({"id": id, "on": true})));
    note(&call(&a, "status", json!({})));
    std::thread::sleep(std::time::Duration::from_millis(500));
    for l in cache_sync::take_log() {
        seen.borrow_mut().push_str(&l);
    }
    assert!(!seen.borrow().contains(SECRET), "the passphrase appeared in an output or the log");
    // It is kept in the one file meant for it and nowhere else in the folder.
    assert_eq!(files_holding(&dir, SECRET), vec!["entry_points.json".to_string()]);
    a.close();
}

#[test]
fn start_up_reads_the_file_and_attaches_only_the_entries_that_are_on() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("a");
    std::fs::create_dir_all(&dir).unwrap();
    let (p1, p2) = (free_port(), free_port());
    let (_s1, _s2) = (rnsd::server(p1, Some((NAME1, PASS1))), rnsd::server(p2, None));
    let rec = |id: &str, port: u16, on: bool, pass: Option<&str>| {
        json!({"id": id, "host": "127.0.0.1", "port": port, "private": pass.is_some(), "network_name": pass.map(|_| NAME1), "passphrase": pass,
               "on": on, "cap_bytes": 52428800, "t": 1_790_000_000_000u64, "dev": "dev-x"})
    };
    let id1 = "11111111111111111111111111111111";
    let id2 = "22222222222222222222222222222222";
    let gone = "33333333333333333333333333333333";
    std::fs::write(
        dir.join("entry_points.json"),
        json!([rec(id1, p1, true, Some(PASS1)), rec(id2, p2, false, None), {"id": gone, "removed": true, "t": 1_790_000_000_000u64, "dev": "dev-x"}]).to_string(),
    )
    .unwrap();
    let a = engine_entries(&dir, "Desk", json!(true));
    assert_eq!(list(&a).len(), 2, "a removal is not listed");
    wait("the entry that is on to connect", 40, || status_of(&a, id1) == "connected");
    assert_eq!(status_of(&a, id2), "off", "an entry that is off is not attached");
    a.close();
}

#[test]
fn the_entries_mode_starts_the_entry_points_and_no_wifi_auto() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("a");
    std::fs::create_dir_all(&dir).unwrap();
    let p1 = free_port();
    let _s1 = rnsd::server(p1, Some((NAME1, PASS1)));
    let id1 = "11111111111111111111111111111111";
    std::fs::write(
        dir.join("entry_points.json"),
        json!([{"id": id1, "host": "127.0.0.1", "port": p1, "private": true, "network_name": NAME1, "passphrase": PASS1, "on": true,
                "cap_bytes": 52428800, "t": 1_790_000_000_000u64, "dev": "dev-x"}])
        .to_string(),
    )
    .unwrap();
    // `"entries"` with no test block at all: what the background service asks for.
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": "Phone", "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "reticulum": "entries",
    }))
    .unwrap();
    let a = SyncEngine::open(cfg).unwrap();
    wait("the entry to connect", 40, || status_of(&a, id1) == "connected");
    // Reticulum runs (a link code is the short kind) though nothing but the entry was started.
    assert!(call(&a, "link_code", json!({}))["code"].as_str().unwrap().starts_with("CACHE-"));
    a.close();
}

#[test]
fn an_entry_added_on_one_device_reaches_the_other_over_reticulum_and_its_node_attaches_it() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _da, db) = pair_over_reticulum(tmp.path());
    let p1 = free_port();
    let _s1 = rnsd::server(p1, Some((NAME1, PASS1)));

    let id = add(&a, "127.0.0.1", p1, Some(NAME1), Some(PASS1));
    wait("the entry on B", 60, || {
        call(&b, "sync_now", json!({}));
        find(&b, &id).is_some()
    });
    let v = find(&b, &id).unwrap();
    assert_eq!((v["host"].clone(), v["port"].clone(), v["network_name"].clone(), v["has_passphrase"].clone()), (json!("127.0.0.1"), json!(p1), json!(NAME1), json!(true)));
    assert_eq!(records(&db)[0]["passphrase"], PASS1, "the passphrase went with it (every linked device gets the list)");
    assert!(v.get("passphrase").is_none());
    // B's own node attached it and the rnsd is heard.
    wait("B's node to connect through it", 60, || status_of(&b, &id) == "connected");

    // Switched off on A: off on B, and B's node lets go.
    call(&a, "entry_point_on", json!({"id": id, "on": false}));
    wait("off on B", 60, || {
        call(&b, "sync_now", json!({}));
        find(&b, &id).is_some_and(|v| v["on"] == false)
    });
    assert_eq!(status_of(&b, &id), "off");
    // And on again.
    call(&a, "entry_point_on", json!({"id": id, "on": true}));
    wait("on again on B", 60, || {
        call(&b, "sync_now", json!({}));
        find(&b, &id).is_some_and(|v| v["on"] == true)
    });
    wait("B's node to connect again", 60, || status_of(&b, &id) == "connected");

    // An edit on B goes to A (the newer t wins on both).
    std::thread::sleep(std::time::Duration::from_millis(20));
    call(&b, "entry_point_set", json!({"id": id, "host": "localhost", "port": p1, "private": true, "network_name": NAME1}));
    wait("the edit on A", 60, || {
        call(&a, "sync_now", json!({}));
        find(&a, &id).is_some_and(|v| v["host"] == "localhost")
    });
    assert_eq!(find(&a, &id).unwrap()["has_passphrase"], true, "the passphrase B kept is the one A has");

    // Removed on A: gone on B, node and all.
    call(&a, "entry_point_remove", json!({"id": id}));
    wait("the removal on B", 60, || {
        call(&b, "sync_now", json!({}));
        find(&b, &id).is_none()
    });
    assert_eq!(call(&a, "entry_points", json!({})), call(&b, "entry_points", json!({})).clone(), "the lists end the same");
    a.close();
    b.close();
}

#[test]
fn the_list_reaches_a_device_linked_over_iroh_too() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let a = old_engine(&da, "Desk", None);
    let b = old_engine(&db, "Phone", None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert!(code.starts_with("CACHE1-"));
    call(&b, "link", json!({"code": code}));
    let id = add(&a, "rt.example.net", 4965, Some("net-one"), Some(SECRET));
    wait("the entry on B over iroh", 60, || {
        call(&b, "sync_now", json!({}));
        find(&b, &id).is_some()
    });
    assert_eq!(records(&db)[0]["passphrase"], SECRET);
    assert!(call(&b, "test_asked", json!({}))["entries"].as_u64().unwrap() >= 1);
    // The list is the same on both from here: nothing more is asked.
    std::thread::sleep(std::time::Duration::from_secs(1));
    let asked = call(&b, "test_asked", json!({}))["entries"].as_u64().unwrap();
    call(&b, "sync_now", json!({}));
    std::thread::sleep(std::time::Duration::from_secs(8));
    assert_eq!(call(&b, "test_asked", json!({}))["entries"].as_u64().unwrap(), asked, "equal lists: not asked again");
    a.close();
    b.close();
}

#[test]
fn changes_made_on_both_devices_at_once_end_as_the_same_list() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let a = old_engine(&da, "Desk", None);
    let b = old_engine(&db, "Phone", None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    // One entry both have, then each edits it and adds one of its own while they are apart (nothing synced between).
    let id = add(&a, "one.example.net", 4965, None, None);
    wait("B to have it", 60, || {
        call(&b, "sync_now", json!({}));
        find(&b, &id).is_some()
    });
    call(&a, "set_policy", json!({"network": false}));
    call(&b, "set_policy", json!({"network": false}));
    call(&a, "entry_point_set", json!({"id": id, "host": "from-a.example.net", "port": 4965}));
    std::thread::sleep(std::time::Duration::from_millis(20));
    call(&b, "entry_point_set", json!({"id": id, "host": "from-b.example.net", "port": 4965}));
    let only_a = add(&a, "a-only.example.net", 4965, None, None);
    let only_b = add(&b, "b-only.example.net", 4965, None, None);
    call(&a, "set_policy", json!({"network": true}));
    call(&b, "set_policy", json!({"network": true}));
    wait("both to hold all three", 90, || {
        call(&a, "sync_now", json!({}));
        call(&b, "sync_now", json!({}));
        let (la, lb) = (list(&a), list(&b));
        la.len() == 3 && lb.len() == 3 && find(&a, &only_b).is_some() && find(&b, &only_a).is_some()
    });
    // The later edit (B's) is the one both keep.
    wait("the same host on both", 60, || {
        call(&a, "sync_now", json!({}));
        call(&b, "sync_now", json!({}));
        find(&a, &id).unwrap()["host"] == "from-b.example.net" && find(&b, &id).unwrap()["host"] == "from-b.example.net"
    });
    let key = |e: &SyncEngine| {
        let mut v: Vec<(String, String)> = list(e).iter().map(|x| (x["id"].to_string(), x["host"].to_string())).collect();
        v.sort();
        v
    };
    assert_eq!(key(&a), key(&b));
    a.close();
    b.close();
}

#[test]
fn a_device_that_does_not_say_entries_v_is_not_asked_for_its_list() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let a = old_engine(&da, "Desk", None);
    let b = old_engine(&db, "Phone", None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    // A acts as a build from before entry points: its file list has no `entries_v`.
    std::fs::write(da.join("no-entries-v"), b"").unwrap();
    let id = add(&a, "rt.example.net", 4965, None, None);
    // The fields of its list that B reads show nothing about entries.
    let view = call(&a, "test_view", json!({"peer": call(&b, "status", json!({}))["id"]}));
    assert!(view.get("entries_v").is_none_or(|v| v.is_null()));
    for _ in 0..4 {
        call(&b, "sync_now", json!({}));
        std::thread::sleep(std::time::Duration::from_secs(2));
    }
    assert_eq!(call(&b, "test_asked", json!({}))["entries"], 0, "never asked");
    assert!(find(&b, &id).is_none());
    // Once A says it (a new build), B asks and takes the list.
    std::fs::remove_file(da.join("no-entries-v")).unwrap();
    wait("the entry on B", 60, || {
        call(&b, "sync_now", json!({}));
        find(&b, &id).is_some()
    });
    a.close();
    b.close();
}

#[test]
fn only_a_linked_device_is_answered() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let a = old_engine(&da, "Desk", None);
    let b = old_engine(&db, "Phone", None);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    let id = add(&a, "rt.example.net", 4965, Some("net-one"), Some(SECRET));
    let b_id = call(&b, "status", json!({}))["id"].as_str().unwrap().to_string();
    // The list as the engine answers a linked device's `cache.entries`.
    let got = call(&a, "test_answer_entries", json!({"peer": b_id}));
    assert_eq!(got["refused"], false);
    assert_eq!(got["list"].as_array().unwrap().iter().filter(|r| r["id"] == id).count(), 1);
    // A device that is not linked is refused, and is told nothing of what the list holds.
    let stranger = iroh_like_id();
    let got = call(&a, "test_answer_entries", json!({"peer": stranger}));
    assert_eq!(got["refused"], true);
    assert!(!got.to_string().contains(SECRET) && !got.to_string().contains("rt.example.net"));
    a.close();
    b.close();
}

/// A device id that nobody linked: the text of a key.
fn iroh_like_id() -> String {
    "0".repeat(64)
}

#[test]
fn a_peer_reached_through_an_entry_point_is_said_to_be_so_in_the_status() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let p1 = free_port();
    let _s1 = rnsd::server(p1, Some((NAME1, PASS1)));
    rns_only_dirs(&[&da, &db]);
    // Neither device has any way to the other but the rnsd both entered: the same entry, in both files from the start.
    let id = "44444444444444444444444444444444";
    let record = json!([{"id": id, "host": "127.0.0.1", "port": p1, "private": true, "network_name": NAME1, "passphrase": PASS1, "on": true,
                         "cap_bytes": 52428800, "t": 1_790_000_000_000u64, "dev": "dev-x"}])
    .to_string();
    std::fs::write(da.join("entry_points.json"), &record).unwrap();
    std::fs::write(db.join("entry_points.json"), &record).unwrap();
    let a = engine_entries(&da, "Desk", json!(true));
    let b = engine_entries(&db, "Phone", json!(true));
    wait("both to connect", 40, || status_of(&a, id) == "connected" && status_of(&b, id) == "connected");
    std::thread::sleep(std::time::Duration::from_secs(3));
    call(&a, "network_changed", json!({}));
    call(&b, "network_changed", json!({}));
    std::thread::sleep(std::time::Duration::from_secs(3));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert_eq!(call(&b, "link", json!({"code": code}))["name"], "Desk");
    wait("B to hear A", 60, || {
        call(&b, "sync_now", json!({}));
        via(&b, "Desk").is_some()
    });
    assert_eq!(via(&b, "Desk"), Some(format!("entry:{id}")), "reached through B's entry point");
    wait("A to hear B", 60, || {
        call(&a, "sync_now", json!({}));
        via(&a, "Phone").is_some()
    });
    assert_eq!(via(&a, "Phone"), Some(format!("entry:{id}")));
    a.close();
    b.close();
}
