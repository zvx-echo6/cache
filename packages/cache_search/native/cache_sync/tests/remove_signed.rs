//! A device that unlinks another tells the devices it is still linked with, in a request it signs (a Removal, carried in its file
//! list), and they unlink it too. Three devices, all linked: A, B and X.
//!
//! A Removal holds up only when its sender is linked here, the signature is the sender's, the target is linked here and is not
//! this device, and its time is after this device linked with the target. Applying it is a plain unlink here: nothing is offered
//! on, so nothing echoes. A build before this one ignores the field and keeps its own way (a 403 after two refusals).
//!
//! Hooks (files in a device's folder, read by the test-hooks build): `inject-removals.json` (the file list carries exactly these
//! Removals) and `no-removed-field` (the device acts as build 54, which says nothing about unlinks).

use cache_sync::{Config, SyncEngine};
use iroh::SecretKey;
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

fn engine_on(dir: &Path, name: &str) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn peers(e: &SyncEngine) -> Vec<Value> {
    call(e, "status", json!({}))["peers"].as_array().cloned().unwrap_or_default()
}

fn log(e: &SyncEngine) -> String {
    call(e, "status", json!({}))["log"].to_string()
}

fn tick(e: &SyncEngine) {
    call(e, "sync_now", json!({}));
    std::thread::sleep(Duration::from_millis(300));
}

fn wait(what: &str, secs: u64, engines: &[&SyncEngine], mut ok: impl FnMut() -> bool) {
    let end = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < end {
        if ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("timed out waiting for {what}\n{}", engines.iter().map(|e| log(e)).collect::<Vec<_>>().join("\n"));
}

fn listed(e: &SyncEngine, id: &str) -> bool {
    peers(e).iter().any(|p| p["id"] == id)
}

/// `shower` shows a code, `reader` reads it, and the link is confirmed on both.
fn link(shower: &SyncEngine, reader: &SyncEngine) {
    let code = call(shower, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(reader, "link", json!({"code": code}));
    wait("the link confirmed", 60, &[shower, reader], || {
        tick(reader);
        peers(shower).iter().all(|p| p["unconfirmed"] == false) && !peers(shower).is_empty()
    });
}

fn id_of(e: &SyncEngine, name: &str) -> String {
    peers(e).iter().find(|p| p["name"] == name).unwrap_or_else(|| panic!("no {name} linked")).get("id").unwrap().as_str().unwrap().to_string()
}

struct Three {
    _tmp: tempfile::TempDir,
    da: PathBuf,
    db: PathBuf,
    a: SyncEngine,
    b: SyncEngine,
    x: SyncEngine,
    a_id: String,
    b_id: String,
    x_id: String,
}

fn three() -> Three {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db, dx) = (tmp.path().join("a"), tmp.path().join("b"), tmp.path().join("x"));
    for d in [&da, &db, &dx] {
        std::fs::create_dir_all(d).unwrap();
    }
    let (a, b, x) = (engine_on(&da, "Desk"), engine_on(&db, "Phone"), engine_on(&dx, "Tablet"));
    link(&a, &b);
    link(&a, &x);
    link(&b, &x);
    let (a_id, b_id, x_id) = (id_of(&b, "Desk"), id_of(&a, "Phone"), id_of(&a, "Tablet"));
    assert!(listed(&b, &x_id) && listed(&x, &b_id) && listed(&x, &a_id));
    Three { _tmp: tmp, da, db, a, b, x, a_id, b_id, x_id }
}

impl Three {
    fn close(self) {
        self.a.close();
        self.b.close();
        self.x.close();
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

fn saved(dir: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(dir.join("sync.json")).unwrap()).unwrap()
}

/// A Removal as the format says: the device key's signature over "cache remove v1", the target's id and the time (8 bytes,
/// big endian), in hex.
fn removal(dir: &Path, target: &str, t: u64) -> Value {
    let key = SecretKey::from_bytes(&std::fs::read(dir.join("identity.key")).unwrap().try_into().unwrap());
    signed_by(&key, target, t)
}

fn signed_by(key: &SecretKey, target: &str, t: u64) -> Value {
    let mut m = b"cache remove v1".to_vec();
    m.extend_from_slice(target.as_bytes());
    m.extend_from_slice(&t.to_be_bytes());
    json!({"target": target, "by": key.public().to_string(), "t": t, "sig": data_encoding::HEXLOWER.encode(&key.sign(&m).to_bytes())})
}

fn inject(dir: &Path, list: Vec<Value>) {
    std::fs::write(dir.join("inject-removals.json"), serde_json::to_vec(&list).unwrap()).unwrap();
}

/// B checks in with A for a few rounds.
fn b_rounds(t: &Three, n: usize) {
    for _ in 0..n {
        tick(&t.b);
    }
}

#[test]
fn unlinking_on_one_device_unlinks_it_on_the_others() {
    let t = three();
    call(&t.a, "unlink", json!({"peer": t.x_id}));
    // A keeps the signed request for the others.
    let removals = saved(&t.da)["removals"].clone();
    assert_eq!(removals.as_array().unwrap().len(), 1, "{removals}");
    assert_eq!(removals[0]["target"], t.x_id.as_str());
    assert_eq!(removals[0]["by"], t.a_id.as_str());
    wait("B unlinking X", 60, &[&t.a, &t.b], || {
        tick(&t.b);
        !listed(&t.b, &t.x_id)
    });
    assert!(log(&t.b).contains("Desk unlinked Tablet"), "{}", log(&t.b));
    assert!(listed(&t.b, &t.a_id), "B still has A");
    // No echo: B made no Removal of its own, and offers none.
    assert!(saved(&t.db).get("removals").is_none(), "{}", saved(&t.db));
    // The saved links no longer list X.
    assert!(!saved(&t.db)["peers"].to_string().contains(&t.x_id));
    t.close();
}

#[test]
fn a_forged_removal_is_ignored() {
    let t = three();
    // A bad signature: A's own request with one character of the signature changed.
    let mut bad = removal(&t.da, &t.x_id, now_ms());
    let sig = bad["sig"].as_str().unwrap().to_string();
    let flipped = format!("{}{}", &sig[..sig.len() - 1], if sig.ends_with('0') { "1" } else { "0" });
    bad["sig"] = json!(flipped);
    // A sender B is not linked with, with a good signature of its own.
    let stranger = SecretKey::generate();
    let unknown = signed_by(&stranger, &t.x_id, now_ms());
    inject(&t.da, vec![bad, unknown]);
    b_rounds(&t, 4);
    assert!(listed(&t.b, &t.x_id), "X is still linked\n{}", log(&t.b));
    assert!(!log(&t.b).contains("unlinked"), "{}", log(&t.b));
    t.close();
}

#[test]
fn a_removal_older_than_the_link_is_ignored_and_says_so_once() {
    let t = three();
    let linked = saved(&t.db)["peers"].as_array().unwrap().iter().find(|p| p["id"] == t.x_id.as_str()).unwrap()["linked"].as_u64().unwrap();
    assert!(linked > 1000, "B saved when it linked with X");
    inject(&t.da, vec![removal(&t.da, &t.x_id, linked - 1000)]);
    b_rounds(&t, 4);
    assert!(listed(&t.b, &t.x_id), "X is still linked");
    let l = log(&t.b);
    assert!(l.contains("Not unlinked Tablet: the request from Desk is older than this link (check the clocks on both devices)"), "{l}");
    assert_eq!(l.matches("Not unlinked Tablet").count(), 1, "said once: {l}");
    t.close();
}

#[test]
fn a_removal_of_this_device_is_ignored() {
    let t = three();
    inject(&t.da, vec![removal(&t.da, &t.b_id, now_ms())]);
    b_rounds(&t, 4);
    assert!(listed(&t.b, &t.a_id), "B still has A");
    assert!(listed(&t.b, &t.x_id));
    assert!(!log(&t.b).contains("unlinked"), "{}", log(&t.b));
    t.close();
}

#[test]
fn a_build_54_device_still_syncs_and_says_nothing_about_unlinks() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("fa"), tmp.path().join("fb"));
    for d in [&da, &db, &fa] {
        std::fs::create_dir_all(d).unwrap();
    }
    std::fs::write(fa.join("note.txt"), "from the old build").unwrap();
    std::fs::write(da.join("no-removed-field"), b"").unwrap();
    let (a, b) = (engine_on(&da, "Desk"), engine_on(&db, "Phone"));
    link(&a, &b);
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    wait("the offer on B", 60, &[&a, &b], || {
        tick(&b);
        call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false)
    });
    call(&b, "share_join", json!({"id": id, "path": fb}));
    wait("the file on B", 60, &[&a, &b], || {
        tick(&b);
        fb.join("note.txt").exists()
    });
    a.close();
    b.close();
}

#[test]
fn a_sync_json_from_build_54_loads() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    for d in [&da, &db] {
        std::fs::create_dir_all(d).unwrap();
    }
    let (a, b) = (engine_on(&da, "Desk"), engine_on(&db, "Phone"));
    link(&a, &b);
    let a_id = id_of(&b, "Desk");
    a.close();
    b.close();
    // Build 54's file: no `removals` anywhere, and nothing but what that build wrote for a link.
    let mut v = saved(&db);
    v.as_object_mut().unwrap().remove("removals");
    std::fs::write(db.join("sync.json"), serde_json::to_vec(&v).unwrap()).unwrap();
    let b = engine_on(&db, "Phone");
    assert!(listed(&b, &a_id), "the link was read from the file");
    // An unlink here then creates the first removal, and the file still reads.
    call(&b, "unlink", json!({"peer": a_id}));
    assert_eq!(saved(&db)["removals"].as_array().unwrap().len(), 1);
    b.close();
    let b = engine_on(&db, "Phone");
    assert!(peers(&b).is_empty());
    b.close();
}
