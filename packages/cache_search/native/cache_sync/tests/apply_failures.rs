//! One file that cannot be fetched does not hold up the rest of its share, and a file that says the rest has come (`last`)
//! never comes while anything before it is missing.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str, last: Value) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "last": last,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn log(e: &SyncEngine) -> String {
    call(e, "status", json!({}))["log"].to_string()
}

/// Waits for `ok`, asking both devices to sync again every second.
fn until(what: &str, secs: u64, a: &SyncEngine, b: &SyncEngine, mut ok: impl FnMut() -> bool) {
    for i in 0..secs * 2 {
        if ok() {
            return;
        }
        if i % 2 == 0 {
            call(a, "sync_now", json!({}));
            call(b, "sync_now", json!({}));
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    panic!("timed out waiting for {what}\nA: {}\nB: {}", log(a), log(b));
}

/// Two linked devices keeping the share `fam` in `fa` and `fb`; B cannot fetch `failing`.
fn pair(tmp: &Path, last: Value, failing: &str) -> (SyncEngine, SyncEngine) {
    let (da, db) = (tmp.join("a"), tmp.join("b"));
    std::fs::create_dir_all(tmp.join("fb")).unwrap();
    let a = engine(&da, "Desk", json!({}));
    let b = engine(&db, "Phone", last);
    std::fs::write(db.join("fail-fetch"), failing).unwrap();
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"id": "fam", "name": "Family", "path": tmp.join("fa")}));
    call(&b, "share_add", json!({"id": "fam", "name": "Family", "path": tmp.join("fb")}));
    (a, b)
}

#[test]
fn a_file_that_cannot_be_fetched_does_not_hold_up_the_others() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb) = (tmp.path().join("fa"), tmp.path().join("fb"));
    std::fs::create_dir_all(&fa).unwrap();
    for f in ["a.txt", "m.txt", "z.txt"] {
        std::fs::write(fa.join(f), f).unwrap();
    }
    let (a, b) = pair(tmp.path(), json!({}), "m.txt");
    // The file before the failing one and the file after it both come.
    until("the two other files on B", 90, &a, &b, || fb.join("a.txt").exists() && fb.join("z.txt").exists());
    assert!(!fb.join("m.txt").exists(), "the failing file has not come");
    assert!(log(&b).contains("Family from Desk: test: could not fetch m.txt"), "{}", log(&b));
    // Once it can be fetched it comes too.
    std::fs::remove_file(tmp.path().join("b").join("fail-fetch")).unwrap();
    until("the third file on B", 90, &a, &b, || fb.join("m.txt").exists());
    a.close();
    b.close();
}

#[test]
fn what_says_the_rest_has_come_waits_for_a_failing_file() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb) = (tmp.path().join("fa"), tmp.path().join("fb"));
    std::fs::create_dir_all(&fa).unwrap();
    for f in ["manifest.json", "seg-1", "seg-2"] {
        std::fs::write(fa.join(f), f).unwrap();
    }
    let (a, b) = pair(tmp.path(), json!({"fam": ["manifest.json"]}), "seg-2");
    // Several rounds have tried and failed the one file, and the other has come: the manifest still has not.
    let failures = |e: &SyncEngine| log(e).matches("test: could not fetch seg-2").count();
    until("seg-1 on B and seg-2 failing more than once", 90, &a, &b, || fb.join("seg-1").exists() && failures(&b) >= 3);
    assert!(!fb.join("manifest.json").exists(), "the manifest came before the rest: {}", log(&b));
    assert!(!fb.join("seg-2").exists());
    // The failure is cleared: the rest comes, and then the manifest.
    std::fs::remove_file(tmp.path().join("b").join("fail-fetch")).unwrap();
    until("seg-2 and the manifest on B", 90, &a, &b, || fb.join("seg-2").exists() && fb.join("manifest.json").exists());
    a.close();
    b.close();
}
