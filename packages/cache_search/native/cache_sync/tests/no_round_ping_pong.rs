//! Two linked, idle devices must not keep waking each other: a device that asks for the other's index may have changes, so the
//! other compares soon, but at most once per round interval per asking device.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

const INTERVAL: u64 = 5;

fn engine(dir: &Path, name: &str) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": INTERVAL, "reserve_bytes": 0,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn rounds(e: &SyncEngine) -> u64 {
    call(e, "status", json!({}))["rounds"].as_u64().unwrap()
}

fn wait(what: &str, secs: u64, mut ok: impl FnMut() -> bool) {
    for _ in 0..secs * 20 {
        if ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("timed out waiting for {what}");
}

fn linked_pair(tmp: &Path) -> (SyncEngine, SyncEngine) {
    let a = engine(&tmp.join("a"), "Desk");
    let b = engine(&tmp.join("b"), "Phone");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    (a, b)
}

#[test]
fn idle_linked_devices_do_not_ping_pong() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b) = linked_pair(tmp.path());
    // Settle: the link itself and the first rounds.
    std::thread::sleep(Duration::from_secs(2 * INTERVAL));
    let (a0, b0) = (rounds(&a), rounds(&b));
    std::thread::sleep(Duration::from_secs(3 * INTERVAL));
    let (da, db) = (rounds(&a) - a0, rounds(&b) - b0);
    eprintln!("rounds over 3 intervals: A {da}, B {db}");
    // One round per interval from the timer, and at most one more per interval from the other device's ask: 2 per interval,
    // so 6 over 3 intervals, plus 1 for where the window starts. A ping-pong runs hundreds.
    assert!(da <= 7 && db <= 7, "idle devices ping-ponged: A ran {da} rounds, B ran {db} in 3 intervals");
    a.close();
    b.close();
}

#[test]
fn a_change_on_a_still_reaches_b_within_an_interval() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b) = linked_pair(tmp.path());
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("first.txt"), "one").unwrap();
    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 30, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));
    wait("the first file on B", 60, || fb.join("first.txt").exists());
    // Idle for longer than one interval, so B's wake for A is allowed again.
    std::thread::sleep(Duration::from_secs(INTERVAL + 2));
    // Written a minute ago as far as the file system says, so it is not held back as "still being written".
    let f = std::fs::File::create(fa.join("second.txt")).unwrap();
    std::io::Write::write_all(&mut &f, b"two").unwrap();
    f.set_modified(std::time::SystemTime::now() - Duration::from_secs(60)).unwrap();
    drop(f);
    call(&a, "sync_now", json!({}));
    let t = std::time::Instant::now();
    wait("the second file on B", INTERVAL - 1, || fb.join("second.txt").exists());
    eprintln!("second file reached B after {:?}", t.elapsed());
    a.close();
    b.close();
}
