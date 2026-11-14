//! A device the other one has unlinked drops that link itself: when its check-in is refused 403 "not linked" on two separate
//! rounds at least the interval apart (ten minutes; a hook here makes it seconds). Nothing is sent and nothing is shown. The
//! other device answers 403 only from a healthy links file: after a recovery or a fresh start it answers 409 "links reset" for the
//! grace (seven days; a hook here makes it seconds), and never answers 403 while the file is being rewritten. Files stay.
//!
//! Hooks (files in the device's folder, read by the test-hooks build): `unlink-interval-ms` on the device that checks in,
//! `grace-ms` on the device that answers, `no-unlink-on-403` (the device acts as an older build, which never acts on a 403) and
//! `hold-write` (a rewrite of sync.json is held part way, and says so with `hold-write.held`).

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

fn engine_on(dir: &Path, name: &str, port: Option<u16>) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "port": port,
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

/// A round on `e` now, then a short wait.
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

/// `b` checks in every 300 ms for `secs` seconds; it must keep listing `a_id` the whole time.
fn b_keeps_a_for(b: &SyncEngine, a_id: &str, secs: u64) {
    let end = Instant::now() + Duration::from_secs(secs);
    while Instant::now() < end {
        tick(b);
        assert!(peers(b).iter().any(|p| p["id"] == a_id), "B dropped A\n{}", log(b));
    }
}

struct Pair {
    _tmp: tempfile::TempDir,
    da: PathBuf,
    db: PathBuf,
    folder: PathBuf,
    a: SyncEngine,
    b: SyncEngine,
    a_id: String,
    b_id: String,
    a_port: u16,
}

/// Two linked devices. A's grace is 1 ms (so it is a healthy A as soon as it starts), B's interval is 1.5 s unless `interval`
/// says otherwise. B shares a folder with one file in it.
fn linked(interval: &str) -> Pair {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let folder = tmp.path().join("folder");
    std::fs::create_dir_all(&da).unwrap();
    std::fs::create_dir_all(&db).unwrap();
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("note.txt"), "my note").unwrap();
    std::fs::write(da.join("grace-ms"), "1").unwrap();
    std::fs::write(db.join("unlink-interval-ms"), interval).unwrap();
    let a = engine_on(&da, "Desk", None);
    let a_port = a.port().unwrap();
    let b = engine_on(&db, "Phone", None);
    call(&b, "share_add", json!({"path": folder, "name": "Mine"}));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("the link confirmed on A", 60, &[&a, &b], || {
        tick(&b);
        peers(&a).first().map(|p| p["unconfirmed"] == false).unwrap_or(false)
    });
    let (a_id, b_id) = (peers(&b)[0]["id"].as_str().unwrap().to_string(), peers(&a)[0]["id"].as_str().unwrap().to_string());
    Pair { _tmp: tmp, da, db, folder, a, b, a_id, b_id, a_port }
}

fn kept(p: &Pair) {
    assert_eq!(std::fs::read(p.folder.join("note.txt")).unwrap(), b"my note", "B's files stay");
}

#[test]
fn a_device_the_other_unlinked_drops_it_after_two_refusals_apart_and_keeps_its_files() {
    let p = linked("1500");
    call(&p.a, "unlink", json!({"peer": p.b_id}));
    let start = Instant::now();
    wait("B dropping A", 90, &[&p.a, &p.b], || {
        tick(&p.b);
        peers(&p.b).is_empty()
    });
    assert!(start.elapsed() >= Duration::from_millis(1500), "two refusals at least the interval apart");
    // The same removal as a local unlink: the saved links, and the share is still there.
    wait("the saved links without A", 30, &[&p.b], || std::fs::read_to_string(p.db.join("sync.json")).map(|t| t.contains("\"peers\":[]")).unwrap_or(false));
    assert_eq!(call(&p.b, "status", json!({}))["shares"].as_array().unwrap().len(), 1, "B's share is kept");
    kept(&p);
    p.a.close();
    p.b.close();
}

#[test]
fn one_refusal_does_not_drop_the_link() {
    // The real interval (ten minutes): B meets 403 on every round and keeps A, because no two are ten minutes apart.
    let p = linked("600000");
    call(&p.a, "unlink", json!({"peer": p.b_id}));
    b_keeps_a_for(&p.b, &p.a_id, 8);
    assert!(peers(&p.b)[0]["error"].is_string() || !peers(&p.b)[0]["error"].is_null(), "A was refusing B");
    kept(&p);
    p.a.close();
    p.b.close();
}

#[test]
fn a_restart_of_the_other_device_does_not_drop_the_link() {
    let mut p = linked("1500");
    let (da, port) = (p.da.clone(), p.a_port);
    p.a.close();
    p.a = engine_on(&da, "Desk", Some(port));
    // A healthy load: A still lists B, so it answers B; B keeps A well past the interval.
    wait("B reaching A again", 60, &[&p.a, &p.b], || {
        tick(&p.b);
        peers(&p.b)[0]["error"].is_null()
    });
    b_keeps_a_for(&p.b, &p.a_id, 6);
    assert_eq!(peers(&p.a).len(), 1);
    kept(&p);
    p.a.close();
    p.b.close();
}

/// A restarts after its links file was damaged. `bak`: the last good copy is there, and was made before the link to B (so it does
/// not list B); otherwise there is none and A starts with no links. Either way A does not know B, and answers 409 for the grace.
fn damaged_links_file(bak: bool) {
    let mut p = linked("1500");
    let (da, port) = (p.da.clone(), p.a_port);
    p.a.close();
    // The copy before the link to B is the one A started with; take it from the file as it was at the first write.
    let mut old: Value = serde_json::from_slice(&std::fs::read(da.join("sync.json")).unwrap()).unwrap();
    old["peers"] = json!([]);
    std::fs::write(da.join("sync.json.bak"), serde_json::to_vec(&old).unwrap()).unwrap();
    if !bak {
        std::fs::remove_file(da.join("sync.json.bak")).unwrap();
    }
    std::fs::write(da.join("sync.json"), b"{ damaged").unwrap();
    // The grace here is eight seconds, counted from this start.
    std::fs::write(da.join("grace-ms"), "8000").unwrap();
    let began = Instant::now();
    p.a = engine_on(&da, "Desk", Some(port));
    assert!(peers(&p.a).is_empty(), "A does not know B now");
    // Many rounds within the grace: A answers 409 "links reset", which B never takes for an unlink.
    while began.elapsed() < Duration::from_secs(5) {
        tick(&p.b);
        assert!(peers(&p.b).iter().any(|x| x["id"] == p.a_id), "B dropped A during the grace\n{}", log(&p.b));
    }
    kept(&p);
    // And after the grace A answers 403 as it would from a healthy file: B takes it, on two rounds apart.
    wait("B dropping A after the grace", 90, &[&p.a, &p.b], || {
        tick(&p.b);
        peers(&p.b).is_empty()
    });
    assert!(began.elapsed() >= Duration::from_secs(8), "not before the grace ended");
    kept(&p);
    p.a.close();
    p.b.close();
}

#[test]
fn a_device_that_recovered_its_links_from_the_last_good_copy_answers_409_for_the_grace() {
    damaged_links_file(true);
}

#[test]
fn a_device_that_started_with_no_links_after_damage_answers_409_for_the_grace() {
    damaged_links_file(false);
}

#[test]
fn the_grace_survives_a_restart() {
    let mut p = linked("1500");
    let (da, port) = (p.da.clone(), p.a_port);
    p.a.close();
    std::fs::write(da.join("sync.json"), b"{ damaged").unwrap();
    std::fs::remove_file(da.join("sync.json.bak")).ok();
    std::fs::write(da.join("grace-ms"), "600000").unwrap();
    p.a = engine_on(&da, "Desk", Some(port));
    p.a.close();
    // The next start reads a good file (the recovery wrote one), and is still inside the grace.
    p.a = engine_on(&da, "Desk", Some(port));
    b_keeps_a_for(&p.b, &p.a_id, 6);
    kept(&p);
    p.a.close();
    p.b.close();
}

#[test]
fn a_refusal_cannot_come_while_the_links_file_is_being_rewritten() {
    let p = linked("1500");
    call(&p.a, "unlink", json!({"peer": p.b_id}));
    // A rewrite of sync.json is held part way (a share added meanwhile, on another thread).
    std::fs::write(p.da.join("hold-write"), b"").unwrap();
    std::thread::scope(|s| {
        let writer = s.spawn(|| {
            let _ = p.a.call("share_add", &json!({"path": p.folder, "name": "Desk's"}));
        });
        wait("the rewrite held", 60, &[&p.b], || p.da.join("hold-write.held").exists());
        // B is unlinked on A, and A would answer 403: but not while the file is being rewritten.
        b_keeps_a_for(&p.b, &p.a_id, 6);
        // Let go: now it is a plain refusal, and B drops A.
        std::fs::remove_file(p.da.join("hold-write")).unwrap();
        writer.join().unwrap();
    });
    wait("B dropping A once the rewrite is done", 90, &[&p.b], || {
        tick(&p.b);
        peers(&p.b).is_empty()
    });
    kept(&p);
    p.a.close();
    p.b.close();
}

#[test]
fn an_older_build_never_acts_on_a_refusal_and_keeps_its_entry() {
    let p = linked("1500");
    // B acts as an older build: it does not know the rule. (The real older build is checked by the two-device proof.)
    std::fs::write(p.db.join("no-unlink-on-403"), b"").unwrap();
    call(&p.a, "unlink", json!({"peer": p.b_id}));
    assert!(peers(&p.a).is_empty(), "A no longer lists B");
    b_keeps_a_for(&p.b, &p.a_id, 8);
    kept(&p);
    p.a.close();
    p.b.close();
}
