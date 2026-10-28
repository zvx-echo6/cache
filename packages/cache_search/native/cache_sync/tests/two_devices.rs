//! Two engines on this machine, linked by code, keeping a folder the same (no relays, DHT, mDNS or lookup service: direct
//! addresses from the link code only).

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str) -> SyncEngine {
    engine_on(dir, name, None)
}

/// With no way to look a device up, a restarted device is found again only at the port it had when linked.
fn engine_on(dir: &Path, name: &str, port: Option<u16>) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "port": port,
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

#[test]
fn two_devices_link_share_and_stay_the_same() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(fa.join("maps")).unwrap();
    std::fs::write(fa.join("notes.txt"), "first").unwrap();
    let big: Vec<u8> = (0..3_000_000u32).map(|i| (i * 7 % 251) as u8).collect();
    std::fs::write(fa.join("maps/region.bin"), &big).unwrap();
    std::fs::write(fa.join(".hidden"), "never shared").unwrap();

    let a = engine(&da, "Desk");
    let b_port = std::net::UdpSocket::bind("0.0.0.0:0").unwrap().local_addr().unwrap().port();
    let b = engine_on(&db, "Phone", Some(b_port));

    // A stranger's key is refused: B tries to read A's file list before linking.
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    assert!(code.starts_with("CACHE1-"));
    let linked = call(&b, "link", json!({"code": code}));
    assert_eq!(linked["name"], "Desk");
    // The code worked once; a second use is refused.
    let c = engine(&tmp.path().join("c"), "Other");
    assert!(c.call("link", &json!({"code": code})).is_err());
    c.close();

    let id = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    call(&b, "sync_now", json!({}));
    wait("the offer on B", 30, || call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    // Not allowed to use the network (mobile data without permission): nothing is fetched, and the status says why.
    call(&b, "set_policy", json!({"network": false}));
    call(&b, "share_join", json!({"id": id, "path": fb}));
    call(&b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(4));
    assert!(!fb.join("notes.txt").exists() && !fb.join("maps/region.bin").exists(), "nothing may arrive while paused");
    assert_eq!(call(&b, "status", json!({}))["paused"], "Sync is paused: no network it may use");
    call(&b, "set_policy", json!({"network": true}));
    wait("the files on B", 60, || fb.join("maps/region.bin").exists() && fb.join("notes.txt").exists());
    assert_eq!(std::fs::read(fb.join("maps/region.bin")).unwrap(), big);
    assert!(!fb.join(".hidden").exists(), "hidden files are never shared");

    // An edit on B arrives on A.
    std::thread::sleep(Duration::from_millis(1100));
    std::fs::write(fb.join("notes.txt"), "edited on the phone").unwrap();
    call(&b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(1));
    call(&a, "sync_now", json!({}));
    wait("the edit on A", 60, || std::fs::read_to_string(fa.join("notes.txt")).map(|s| s == "edited on the phone").unwrap_or(false));

    // A new file and a delete on A arrive on B.
    std::fs::write(fa.join("maps/new.txt"), "new").unwrap();
    std::fs::remove_file(fa.join("maps/region.bin")).unwrap();
    call(&a, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(1));
    call(&b, "sync_now", json!({}));
    wait("the new file and the delete on B", 60, || fb.join("maps/new.txt").exists() && !fb.join("maps/region.bin").exists());

    // A delete that empties folders takes the folders too.
    std::fs::create_dir_all(fa.join("deep/er")).unwrap();
    std::fs::write(fa.join("deep/er/leaf.txt"), "leaf").unwrap();
    call(&a, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(1));
    call(&b, "sync_now", json!({}));
    wait("the nested file on B", 60, || fb.join("deep/er/leaf.txt").exists());
    std::fs::remove_dir_all(fa.join("deep")).unwrap();
    call(&a, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(1));
    call(&b, "sync_now", json!({}));
    wait("the emptied folders gone on B", 60, || !fb.join("deep").exists());

    // B is stopped half way through writing a file (as when the app is killed): on the next start the half file is replaced
    // from what B already has, and never taken for an edit that would go back to A.
    let whole: Vec<u8> = (0..2_000_000u32).map(|i| (i * 13 % 241) as u8).collect();
    std::env::set_var("CACHE_SYNC_CUT_WRITE", "maps/cut.bin");
    std::fs::write(fa.join("maps/cut.bin"), &whole).unwrap();
    call(&a, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(1));
    call(&b, "sync_now", json!({}));
    let writing = db.join("index").join(format!("{id}.writing.json"));
    wait("the cut-off write on B", 60, || fb.join("maps/cut.bin").exists() && writing.exists());
    std::env::remove_var("CACHE_SYNC_CUT_WRITE");
    b.close();
    assert!(std::fs::metadata(fb.join("maps/cut.bin")).unwrap().len() < whole.len() as u64, "the write was cut off");
    let b = engine_on(&db, "Phone", Some(b_port));
    call(&b, "sync_now", json!({}));
    wait("the whole file on B after the restart", 60, || std::fs::read(fb.join("maps/cut.bin")).map(|d| d == whole).unwrap_or(false));
    assert!(!writing.exists(), "nothing is left waiting to be written");
    std::thread::sleep(Duration::from_secs(7));
    call(&b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(1));
    call(&a, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(3));
    assert_eq!(std::fs::read(fa.join("maps/cut.bin")).unwrap(), whole, "A's copy is untouched");
    let log = call(&b, "status", json!({}))["log"].to_string();
    assert!(log.contains("cut off while being written"), "{log}");

    // Both edit the same file before syncing: neither edit is lost.
    call(&a, "set_policy", json!({"network": false}));
    call(&b, "set_policy", json!({"network": false}));
    std::thread::sleep(Duration::from_secs(1));
    std::fs::write(fa.join("maps/new.txt"), "desk version").unwrap();
    std::fs::write(fb.join("maps/new.txt"), "phone version").unwrap();
    call(&a, "sync_now", json!({}));
    call(&b, "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(2));
    call(&a, "set_policy", json!({"network": true}));
    call(&b, "set_policy", json!({"network": true}));
    let has_both = |dir: &Path| {
        let names: Vec<String> = std::fs::read_dir(dir.join("maps")).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
        let texts: Vec<String> = names.iter().filter(|n| n.starts_with("new")).filter_map(|n| std::fs::read_to_string(dir.join("maps").join(n)).ok()).collect();
        texts.contains(&"desk version".to_string()) && texts.contains(&"phone version".to_string())
    };
    let mut ok = false;
    for _ in 0..360 {
        call(&a, "sync_now", json!({}));
        call(&b, "sync_now", json!({}));
        if has_both(&fa) && has_both(&fb) {
            ok = true;
            break;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    if !ok {
        let list = |dir: &Path| -> Vec<(String, String)> {
            std::fs::read_dir(dir.join("maps")).unwrap().flatten().map(|e| (e.file_name().to_string_lossy().into_owned(), std::fs::read_to_string(e.path()).unwrap_or_default().chars().take(30).collect())).collect()
        };
        let logs = |e: &SyncEngine| call(e, "status", json!({}))["log"].as_array().unwrap().iter().map(|l| l["text"].as_str().unwrap_or("").to_string()).collect::<Vec<_>>();
        panic!("both versions did not reach both devices\nA: {:?}\nB: {:?}\nA log: {:#?}\nB log: {:#?}", list(&fa), list(&fb), logs(&a), logs(&b));
    }

    let st = call(&b, "status", json!({}));
    assert_eq!(st["peers"][0]["name"], "Desk");
    assert!(st["peers"][0]["error"].is_null(), "{st}");
    a.close();
    b.close();
}
