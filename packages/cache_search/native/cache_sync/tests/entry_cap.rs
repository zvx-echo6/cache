//! Step 4, the file cap of an entry point, on the waiting path of step 3. Two devices that reach each other only through one
//! stand-in rnsd (a Prns transport node keyed with IFAC, on loopback): a file bigger than the entry's cap (50 MB by default) waits
//! with the reason "Bigger files wait for Wi-Fi" and one under it goes; an asker that ignores its cap is refused by the answering
//! end; a waiting file goes by itself once the cap is raised (the same decision as the route no longer being through a capped
//! entry: the watcher asks again when nothing holds the file back).
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use cache_sync::{Config, SyncEngine};
use common::*;
use serde_json::json;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const NAME1: &str = "cache-test-cap";
const PASS1: &str = "pass-cap-test-value-9c1d";
const ID: &str = "55555555555555555555555555555555";
const REASON: &str = "Bigger files wait for Wi-Fi";
const MB: usize = 1024 * 1024;

/// One of these at a time: each moves tens of MB through a stand-in rnsd, and the class of a link follows the rate its windows were
/// measured at (Fast needs over 1 MB/s), so tests run side by side on a busy machine would make each other's links Medium.
static ONE_AT_A_TIME: std::sync::Mutex<()> = std::sync::Mutex::new(());

fn engine_entries(dir: &Path, name: &str) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 3600, "reserve_bytes": 0, "reticulum": true, "rns_interfaces": {},
        // B's watcher, made quick: it looks every 100 ms and waits 600 ms before a retry.
        "resume_check_ms": 100, "resume_hold_ms": 600, "resume_backoff_max_ms": 3000,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn status_of(e: &SyncEngine) -> String {
    call(e, "entry_points", json!({}))["entries"].as_array().and_then(|l| l.iter().find(|v| v["id"] == ID)).and_then(|v| v["status"].as_str().map(String::from)).unwrap_or_default()
}

fn cap_of(e: &SyncEngine) -> Option<u64> {
    call(e, "entry_points", json!({}))["entries"].as_array()?.iter().find(|v| v["id"] == ID)?["cap_bytes"].as_u64()
}

fn round(e: &SyncEngine) {
    call(e, "test_round", json!({}));
}

fn read(p: &Path) -> Option<Vec<u8>> {
    std::fs::read(p).ok()
}

/// What the status lists as waiting on `e`: (path, reason).
fn waiting(e: &SyncEngine) -> Vec<(String, String)> {
    call(e, "status", json!({}))["waiting"]
        .as_array()
        .map(|l| l.iter().map(|w| (w["path"].as_str().unwrap_or("").to_string(), w["reason"].as_str().unwrap_or("").to_string())).collect())
        .unwrap_or_default()
}

struct T {
    _tmp: tempfile::TempDir,
    db: PathBuf,
    fa: PathBuf,
    fb: PathBuf,
    a: SyncEngine,
    b: SyncEngine,
    _rnsd: tokio::sync::oneshot::Sender<()>,
}

impl T {
    fn until(&self, what: &str, secs: u64, ok: impl Fn() -> bool) {
        let end = Instant::now() + Duration::from_secs(secs);
        loop {
            round(&self.a);
            round(&self.b);
            if ok() {
                return;
            }
            if Instant::now() > end {
                panic!("timed out waiting for {what}\nwaiting on B: {:?}\nA: {}\nB: {}", waiting(&self.b), brief(&self.a), brief(&self.b));
            }
            std::thread::sleep(Duration::from_millis(300));
        }
    }
}

/// A (Desk, holds the files) and B (Phone) linked through one entry point both have (the default 50 MB cap), no other way between
/// them. A's folder holds the files `files` (name, MB), each random.
fn pair(files: &[(&str, usize)]) -> T {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("fa"), tmp.path().join("fb"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    for (i, (n, mb)) in files.iter().enumerate() {
        std::fs::write(fa.join(n), random(mb * MB, 70 + i as u64)).unwrap();
    }
    let p1 = free_port();
    let rnsd = rnsd::server(p1, Some((NAME1, PASS1)));
    rns_only_dirs(&[&da, &db]);
    let record = json!([{"id": ID, "host": "127.0.0.1", "port": p1, "private": true, "network_name": NAME1, "passphrase": PASS1, "on": true,
                         "cap_bytes": 52428800, "t": 1_790_000_000_000u64, "dev": "dev-x"}])
    .to_string();
    std::fs::write(da.join("entry_points.json"), &record).unwrap();
    std::fs::write(db.join("entry_points.json"), &record).unwrap();
    let a = engine_entries(&da, "Desk");
    let b = engine_entries(&db, "Phone");
    wait("both to connect", 40, || status_of(&a) == "connected" && status_of(&b) == "connected");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert_eq!(call(&b, "link", json!({"code": code}))["name"], "Desk");
    for e in [&a, &b] {
        call(e, "entry_point_on", json!({"id": ID, "on": false}));
        call(e, "entry_point_on", json!({"id": ID, "on": true}));
    }
    wait("both to connect again", 40, || status_of(&a) == "connected" && status_of(&b) == "connected");
    wait("B to hear A through its entry point", 90, || {
        call(&b, "sync_now", json!({}));
        via(&b, "Desk") == Some(format!("entry:{ID}"))
    });
    wait("A to hear B through its entry point", 90, || {
        call(&a, "sync_now", json!({}));
        via(&a, "Phone") == Some(format!("entry:{ID}"))
    });
    call(&a, "share_add", json!({"id": "fam", "name": "fam", "path": fa}));
    call(&b, "share_add", json!({"id": "fam", "name": "fam", "path": fb}));
    T { _tmp: tmp, db, fa, fb, a, b, _rnsd: rnsd }
}

#[test]
fn a_file_over_the_entrys_cap_waits_for_wifi_and_one_under_it_goes() {
    let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    let t = pair(&[("small.bin", 40), ("big.bin", 60)]);
    t.until("the 40 MB file on B", 240, || read(&t.fb.join("small.bin")).is_some_and(|b| b.len() == 40 * MB));
    assert!(read(&t.fb.join("small.bin")).unwrap() == read(&t.fa.join("small.bin")).unwrap(), "byte for byte");
    t.until("the 60 MB file to be held back", 120, || waiting(&t.b).iter().any(|w| w.0 == "big.bin"));
    assert_eq!(waiting(&t.b).iter().find(|w| w.0 == "big.bin").unwrap().1, REASON);
    assert!(read(&t.fb.join("big.bin")).is_none(), "nothing of it is written");
    // The asking end held it back on its own: A refused nothing.
    assert_eq!(call(&t.a, "test_asked", json!({}))["refused_cap"], 0);
    t.a.close();
    t.b.close();
}

#[test]
fn an_asker_that_ignores_its_cap_is_refused_by_the_answering_end() {
    let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    let t = pair(&[("big.bin", 60)]);
    // B acts as a build that does not check the cap of its own entry point.
    std::fs::write(t.db.join("ignore-cap"), b"").unwrap();
    t.until("A to refuse a window", 120, || call(&t.a, "test_asked", json!({}))["refused_cap"].as_u64().unwrap_or(0) >= 1);
    // The refusal is a wait, not a failure, and nothing of the file is written.
    t.until("the file to be listed as waiting", 60, || waiting(&t.b).iter().any(|w| w.0 == "big.bin"));
    assert_eq!(waiting(&t.b).iter().find(|w| w.0 == "big.bin").unwrap().1, REASON);
    assert!(read(&t.fb.join("big.bin")).is_none());
    t.a.close();
    t.b.close();
}

#[test]
fn a_waiting_file_goes_by_itself_once_the_cap_is_raised() {
    let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    let t = pair(&[("big.bin", 60)]);
    t.until("the 60 MB file to be held back", 120, || waiting(&t.b).iter().any(|w| w.0 == "big.bin"));
    assert_eq!(waiting(&t.b).iter().find(|w| w.0 == "big.bin").unwrap().1, REASON);
    assert!(read(&t.fb.join("big.bin")).is_none());
    // The person raises the cap on one device; the list reaches the other, and each end then lets the file through.
    call(&t.a, "entry_point_set", json!({"id": ID, "cap_bytes": 100 * MB as u64}));
    wait("B to hold the raised cap", 90, || {
        call(&t.a, "sync_now", json!({}));
        call(&t.b, "sync_now", json!({}));
        cap_of(&t.b) == Some(100 * MB as u64)
    });
    // From here nobody asks for a round: the watcher has to notice by itself.
    let end = Instant::now() + Duration::from_secs(180);
    while read(&t.fb.join("big.bin")).is_none_or(|b| b.len() != 60 * MB) {
        assert!(Instant::now() < end, "the waiting file came by itself\nA: {}\nB: {}", brief(&t.a), brief(&t.b));
        std::thread::sleep(Duration::from_millis(500));
    }
    assert!(read(&t.fb.join("big.bin")).unwrap() == read(&t.fa.join("big.bin")).unwrap(), "byte for byte");
    assert!(waiting(&t.b).is_empty(), "{:?}", waiting(&t.b));
    t.a.close();
    t.b.close();
}
