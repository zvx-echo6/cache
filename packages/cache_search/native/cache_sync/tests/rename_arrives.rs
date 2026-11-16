//! A rename on one device arrives on the other as a rename: the new path with the same bytes, the old one gone, and the
//! content still readable from there for a third device. Found by keep_my_copies.rs on cache-build-2. Two ways it failed:
//! - the other device took the delete of the old path first (paths in order: "a.jpg", the old name, before "b.jpg"), which took away the file
//!   its store read that content from: the new path then could not be written ("could not write ...: Error::Io") until the
//!   store's clean-up (up to ten minutes), and meanwhile the file was gone there; and once written, the store still read the
//!   old path first, so a third device could not fetch it from there;
//! - a rename of a file that arrived moments ago (it keeps that file's time, so it is still settling) was listed as a delete
//!   in one scan and as a new file only in the next, so the other device deleted first in any order.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str) -> SyncEngine {
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

fn until(what: &str, secs: u64, all: &[&SyncEngine], mut ok: impl FnMut() -> bool) {
    for i in 0..secs * 2 {
        if ok() {
            return;
        }
        if i % 2 == 0 {
            for e in all {
                call(e, "sync_now", json!({}));
            }
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    panic!("timed out waiting for {what}\n{}", all.iter().map(|e| call(e, "status", json!({}))["log"].to_string()).collect::<Vec<_>>().join("\n"));
}

fn link(a: &SyncEngine, b: &SyncEngine) {
    let code = call(a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(b, "link", json!({"code": code}));
}

fn is(p: &Path, want: &[u8]) -> bool {
    std::fs::read(p).map(|b| b == want).unwrap_or(false)
}

fn join(e: &SyncEngine, share: &str, dir: &Path, all: &[&SyncEngine]) {
    until("the offer", 60, all, || call(e, "status", json!({}))["offers"].as_array().map(|o| o.iter().any(|x| x["id"] == share)).unwrap_or(false));
    call(e, "share_join", json!({"id": share, "path": dir}));
}

fn devices(tmp: &Path, name: &str) -> (SyncEngine, SyncEngine) {
    (engine(&tmp.join(format!("dev-{name}-a")), "Desk"), engine(&tmp.join(format!("dev-{name}-b")), "Phone"))
}

#[test]
fn a_rename_arrives_as_a_rename_and_its_content_can_still_be_fetched_from_there() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb, fc) = (tmp.path().join("a"), tmp.path().join("b"), tmp.path().join("c"));
    let big: Vec<u8> = (0..2_000_000u32).map(|i| (i * 17 % 251) as u8).collect();
    std::fs::create_dir_all(fa.join("photos")).unwrap();
    std::fs::write(fa.join("photos/a.jpg"), &big).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    std::fs::create_dir_all(&fc).unwrap();
    let (a, b) = devices(tmp.path(), "1");
    link(&a, &b);
    let share = call(&a, "share_add", json!({"path": fa, "name": "Shared"}))["id"].as_str().unwrap().to_string();
    join(&b, &share, &fb, &[&a, &b]);
    until("the photo on B", 90, &[&a, &b], || is(&fb.join("photos/a.jpg"), &big));

    // Renamed to a name after the old one (the delete of the old path comes first in path order), the file long settled:
    // one scan lists both.
    std::thread::sleep(Duration::from_millis(6000));
    std::fs::rename(fa.join("photos/a.jpg"), fa.join("photos/b.jpg")).unwrap();
    until("the rename on B", 120, &[&a, &b], || is(&fb.join("photos/b.jpg"), &big) && !fb.join("photos/a.jpg").exists());

    // A third device, linked to B only, while A is gone: the content must come from B's new path.
    a.close();
    let c = engine(&tmp.path().join("dev-1-c"), "Tablet");
    link(&b, &c);
    join(&c, &share, &fc, &[&b, &c]);
    until("the renamed photo on C, from B", 120, &[&b, &c], || is(&fc.join("photos/b.jpg"), &big));
    assert!(!fc.join("photos/a.jpg").exists());
    b.close();
    c.close();
}

#[test]
fn a_rename_of_a_file_that_just_arrived_arrives_too() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb) = (tmp.path().join("a"), tmp.path().join("b"));
    let big: Vec<u8> = (0..1_500_000u32).map(|i| (i * 11 % 251) as u8).collect();
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("ren.bin"), &big).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    let (a, b) = devices(tmp.path(), "2");
    link(&a, &b);
    let share = call(&a, "share_add", json!({"path": fa, "name": "Shared"}))["id"].as_str().unwrap().to_string();
    join(&b, &share, &fb, &[&a, &b]);
    until("the file on B", 90, &[&a, &b], || is(&fb.join("ren.bin"), &big));
    // Renamed on B at once (the file keeps the time it was written there, moments ago); A made it, and its store reads it
    // from A's own ren.bin.
    std::fs::rename(fb.join("ren.bin"), fb.join("renamed.bin")).unwrap();
    until("the rename on A", 120, &[&a, &b], || is(&fa.join("renamed.bin"), &big) && !fa.join("ren.bin").exists());
    a.close();
    b.close();
}
