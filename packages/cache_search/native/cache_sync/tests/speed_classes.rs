//! Step 3 part 3 (speed classes, design 2b) over Reticulum on loopback TCP through a stand-in link: a local proxy that delays every
//! chunk each way (so the round trip time is whatever the test sets, and can change under a live link). Each end puts the link in
//! a class; the asking end asks only for what its class allows, the answering end refuses what its class forbids even to a
//! modified asker; what a class holds back is listed as waiting and is fetched when the link is faster.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use cache_sync::{Config, SyncEngine};
use common::*;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

const WAITING: &str = "Waiting for a faster connection";

// --- the stand-in link ---

async fn pipe(delay_ms: Arc<AtomicU64>, mut r: tokio::net::tcp::OwnedReadHalf, mut w: tokio::net::tcp::OwnedWriteHalf) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(Instant, Vec<u8>)>();
    tokio::spawn(async move {
        let mut buf = vec![0u8; 16 * 1024];
        loop {
            match r.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let due = Instant::now() + Duration::from_millis(delay_ms.load(Ordering::Relaxed));
                    if tx.send((due, buf[..n].to_vec())).is_err() {
                        break;
                    }
                }
            }
        }
    });
    while let Some((due, bytes)) = rx.recv().await {
        tokio::time::sleep_until(due.into()).await;
        if w.write_all(&bytes).await.is_err() {
            break;
        }
    }
}

/// A proxy to `to` that delays each chunk by the shared `delay_ms` each way. It runs on its own thread and runtime.
fn proxy(to: u16, delay_ms: Arc<AtomicU64>) -> u16 {
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let rt = tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap();
        rt.block_on(async move {
            let l = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
            tx.send(l.local_addr().unwrap().port()).unwrap();
            loop {
                let Ok((c, _)) = l.accept().await else { break };
                let Ok(s) = tokio::net::TcpStream::connect(("127.0.0.1", to)).await else { continue };
                let (cr, cw) = c.into_split();
                let (sr, sw) = s.into_split();
                tokio::spawn(pipe(delay_ms.clone(), cr, sw));
                tokio::spawn(pipe(delay_ms.clone(), sr, cw));
            }
        });
    });
    rx.recv().unwrap()
}

// --- the two devices ---

fn eng(dir: &Path, name: &str, listen: Option<u16>, connect: Option<u16>) -> SyncEngine {
    let cfg = json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 3600, "reserve_bytes": 0, "reticulum": true,
        // A link is measured again at every request, so a changed link is judged at the next round.
        "speed_probe_ms": 0,
        "rns_interfaces": {
            "tcp_listen": listen.map(|p| format!("127.0.0.1:{p}")),
            "tcp_connect": connect.map(|p| format!("127.0.0.1:{p}")),
        },
    });
    SyncEngine::open(serde_json::from_value::<Config>(cfg).unwrap()).unwrap()
}

fn round(e: &SyncEngine) {
    call(e, "test_round", json!({}));
}

/// (summary, differences, whole list) requests made so far.
fn asked(e: &SyncEngine) -> (u64, u64, u64) {
    let v = call(e, "test_asked", json!({}));
    (v["summary"].as_u64().unwrap(), v["diff"].as_u64().unwrap(), v["full"].as_u64().unwrap())
}

fn status(e: &SyncEngine) -> Value {
    call(e, "status", json!({}))
}

fn speed(e: &SyncEngine) -> String {
    status(e)["peers"][0]["speed"].as_str().unwrap_or("none").to_string()
}

/// What the status lists as waiting: (what, share id, path).
fn waiting(e: &SyncEngine) -> Vec<(String, String, String)> {
    status(e)["waiting"]
        .as_array()
        .map(|l| {
            l.iter()
                .map(|w| {
                    assert_eq!(w["reason"], WAITING, "{w}");
                    (w["what"].as_str().unwrap().to_string(), w["share_id"].as_str().unwrap().to_string(), w["path"].as_str().unwrap_or("").to_string())
                })
                .collect()
        })
        .unwrap_or_default()
}

struct T {
    _tmp: tempfile::TempDir,
    da: PathBuf,
    db: PathBuf,
    folders: PathBuf,
    delay: Arc<AtomicU64>,
    a: SyncEngine,
    b: SyncEngine,
}

impl T {
    /// Rounds on A then B until `ok`.
    fn until(&self, what: &str, secs: u64, ok: impl Fn() -> bool) {
        let end = Instant::now() + Duration::from_secs(secs);
        loop {
            round(&self.a);
            round(&self.b);
            if ok() {
                return;
            }
            if Instant::now() > end {
                panic!("timed out waiting for {what}\nA: {}\nB: {}", brief(&self.a), brief(&self.b));
            }
            std::thread::sleep(Duration::from_millis(300));
        }
    }

    fn fa(&self, share: &str) -> PathBuf {
        self.folders.join("a").join(share)
    }

    fn fb(&self, share: &str) -> PathBuf {
        self.folders.join("b").join(share)
    }

    /// The link's delay each way, and both ends judging it `class` (B measures at its next request and makes the link again, so A
    /// learns it too).
    fn link_is(&self, delay_ms: u64, class: &str) {
        self.delay.store(delay_ms, Ordering::Relaxed);
        self.until(&format!("the link to be {class}"), 120, || speed(&self.b) == class && speed(&self.a) == class);
    }
}

/// A and B linked (over a fast stand-in link), each keeping the shares `ids`: A's folders hold `files` (share, name, bytes).
fn pair(ids: &[&str], files: &[(&str, &str, &str)]) -> T {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let folders = tmp.path().join("folders");
    for id in ids {
        std::fs::create_dir_all(folders.join("a").join(id)).unwrap();
        std::fs::create_dir_all(folders.join("b").join(id)).unwrap();
    }
    for (share, n, text) in files {
        std::fs::write(folders.join("a").join(share).join(n), text).unwrap();
    }
    let port = free_port();
    let delay = Arc::new(AtomicU64::new(1));
    let pport = proxy(port, delay.clone());
    rns_only_dirs(&[&da, &db]);
    let a = eng(&da, "Desk", Some(port), None);
    let b = eng(&db, "Phone", None, Some(pport));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("both sides to hold the address", 30, || saved_peer(&da)["rns"]["dest"].is_string() && saved_peer(&db)["rns"]["dest"].is_string());
    for id in ids {
        call(&a, "share_add", json!({"id": id, "name": id, "path": folders.join("a").join(id)}));
        call(&b, "share_add", json!({"id": id, "name": id, "path": folders.join("b").join(id)}));
    }
    T { _tmp: tmp, da, db, folders, delay, a, b }
}

fn read(p: &Path) -> Option<Vec<u8>> {
    std::fs::read(p).ok()
}

#[test]
fn a_slow_link_carries_summaries_and_differences_and_holds_files_and_lists_back_until_it_is_fast() {
    let t = pair(&["fam"], &[("fam", "first.txt", "one")]);
    t.until("the first file on B", 60, || read(&t.fb("fam").join("first.txt")).as_deref() == Some(b"one"));
    assert_eq!(speed(&t.b), "fast", "a link over loopback with nothing in the way");

    // The path becomes a slow one under the live link: each end judges it again at its next request.
    t.link_is(900, "slow");
    let before = asked(&t.b);

    // A big file and a small one, and a new folder B joins now: nothing needs the whole list of "fam" (B has its mirror).
    let big = random(60 * 1024 * 1024, 11);
    std::fs::write(t.fa("fam").join("big.bin"), &big).unwrap();
    std::fs::write(t.fa("fam").join("note.txt"), "a note").unwrap();
    std::fs::create_dir_all(t.fa("later")).unwrap();
    std::fs::create_dir_all(t.fb("later")).unwrap();
    std::fs::write(t.fa("later").join("l.txt"), "late").unwrap();
    call(&t.a, "share_add", json!({"id": "later", "name": "later", "path": t.fa("later")}));
    call(&t.b, "share_add", json!({"id": "later", "name": "later", "path": t.fb("later")}));
    t.until("the differences to arrive and the files to be held back", 120, || {
        let w = waiting(&t.b);
        w.iter().any(|x| x.0 == "file" && x.2 == "big.bin") && w.iter().any(|x| x.0 == "list" && x.1 == "later")
    });
    let after = asked(&t.b);
    assert!(after.1 > before.1, "the changes of fam came as differences over the slow link: {before:?} {after:?}");
    assert_eq!(after.2, before.2, "and no whole list was asked for: it waits on a slow link");
    // A notice still goes: A told B its folder moved (counted by B), and B's mirror of A is A's view of fam.
    let notices = call(&t.b, "test_asked", json!({}))["notice_got"].as_u64().unwrap();
    assert!(notices >= 1, "a notice came over the slow link: {notices}");
    let view = call(&t.a, "test_view", json!({"peer": saved_peer(&t.da)["id"]}));
    let files = view["shares"].as_array().unwrap().iter().find(|s| s["id"] == "fam").map(|s| s["index"]["files"].clone()).unwrap();
    let mirror = call(&t.b, "test_mirror", json!({"peer": saved_peer(&t.db)["id"], "share": "fam"}));
    assert_eq!(mirror["files"], files, "the mirror is A's view");
    // Held back, not failed: still wanted, the device is not in error, nothing is missing on B.
    let st = status(&t.b);
    assert!(st["peers"][0]["error"].is_null(), "{}", st["peers"][0]);
    assert!(!t.fb("fam").join("big.bin").exists() && !t.fb("later").join("l.txt").exists());
    let w = waiting(&t.b);
    assert!(w.iter().any(|x| x.0 == "file" && x.2 == "note.txt"), "files wait on a slow link (the 8 KB inline path is a later step): {w:?}");
    let fam = st["shares"].as_array().unwrap().iter().find(|s| s["id"] == "fam").unwrap().clone();
    assert!(fam["pending_files"].as_u64().unwrap() >= 2, "still wanted: {fam}");
    assert!(st["transfer"].is_null(), "nothing was started over the slow link");

    // The link gets fast: what waited comes, from where it stopped, and the waiting list empties.
    t.link_is(1, "fast");
    t.until("the held back files to arrive", 240, || {
        t.fb("fam").join("big.bin").exists() && t.fb("fam").join("note.txt").exists() && t.fb("later").join("l.txt").exists()
    });
    assert!(read(&t.fb("fam").join("big.bin")).unwrap() == big, "the big file is byte for byte the original");
    assert_eq!(read(&t.fb("later").join("l.txt")).as_deref(), Some(&b"late"[..]));
    assert!(waiting(&t.b).is_empty(), "{:?}", waiting(&t.b));
    t.a.close();
    t.b.close();
}

#[test]
fn a_medium_link_carries_small_files_in_pages_and_holds_back_big_ones_and_the_big_kinds() {
    let t = pair(&["fam", "library"], &[("fam", "first.txt", "one")]);
    t.until("the first file on B", 60, || read(&t.fb("fam").join("first.txt")).as_deref() == Some(b"one"));
    t.link_is(250, "medium");
    let before = asked(&t.b);

    let mid = random(5 * 1024 * 1024, 5);
    let big = random(20 * 1024 * 1024, 6);
    let zim = random(3 * 1024 * 1024, 7);
    std::fs::write(t.fa("fam").join("mid.bin"), &mid).unwrap();
    std::fs::write(t.fa("fam").join("big.bin"), &big).unwrap();
    std::fs::write(t.fa("library").join("small.zim"), &zim).unwrap();
    // A folder B has no mirror of yet: a medium link takes its whole list in pages, not as one request.
    std::fs::create_dir_all(t.fa("fresh")).unwrap();
    std::fs::create_dir_all(t.fb("fresh")).unwrap();
    for i in 0..30 {
        std::fs::write(t.fa("fresh").join(format!("f{i:02}.txt")), format!("file {i}")).unwrap();
    }
    call(&t.a, "share_add", json!({"id": "fresh", "name": "fresh", "path": t.fa("fresh")}));
    call(&t.b, "share_add", json!({"id": "fresh", "name": "fresh", "path": t.fb("fresh")}));
    t.until("the 5 MB file and the fresh folder on B", 240, || {
        read(&t.fb("fam").join("mid.bin")).is_some() && (0..30).all(|i| t.fb("fresh").join(format!("f{i:02}.txt")).exists())
    });
    assert!(read(&t.fb("fam").join("mid.bin")).unwrap() == mid, "5 MB went in 1 MiB windows, byte for byte");
    let after = asked(&t.b);
    assert!(after.1 > before.1, "differences were asked for: {before:?} {after:?}");
    assert_eq!(after.2, before.2, "the fresh folder's whole comparison came in pages, no whole list");
    // 20 MB waits, and so does a ZIM of the library kind however small.
    let w = waiting(&t.b);
    assert!(w.iter().any(|x| x.0 == "file" && x.1 == "fam" && x.2 == "big.bin"), "{w:?}");
    assert!(w.iter().any(|x| x.0 == "file" && x.1 == "library" && x.2 == "small.zim"), "{w:?}");
    assert!(!w.iter().any(|x| x.2 == "mid.bin"), "{w:?}");
    assert!(!t.fb("fam").join("big.bin").exists() && !t.fb("library").join("small.zim").exists());
    // Fast again: both arrive.
    t.link_is(1, "fast");
    t.until("the held back files to arrive", 240, || t.fb("fam").join("big.bin").exists() && t.fb("library").join("small.zim").exists());
    assert!(read(&t.fb("fam").join("big.bin")).unwrap() == big);
    assert!(read(&t.fb("library").join("small.zim")).unwrap() == zim);
    assert!(waiting(&t.b).is_empty());
    t.a.close();
    t.b.close();
}

#[test]
fn a_modified_asker_that_ignores_its_class_is_refused_by_a_slow_answering_end() {
    let t = pair(&["fam"], &[("fam", "first.txt", "one")]);
    t.until("the first file on B", 60, || read(&t.fb("fam").join("first.txt")).as_deref() == Some(b"one"));
    t.link_is(900, "slow");
    // From here B acts as a build that does not check its class: it asks for the whole list of a folder it has no mirror of.
    std::fs::write(t.db.join("ignore-class"), b"").unwrap();
    std::fs::create_dir_all(t.fa("x")).unwrap();
    std::fs::create_dir_all(t.fb("x")).unwrap();
    std::fs::write(t.fa("x").join("x.txt"), "x").unwrap();
    call(&t.a, "share_add", json!({"id": "x", "name": "x", "path": t.fa("x")}));
    call(&t.b, "share_add", json!({"id": "x", "name": "x", "path": t.fb("x")}));
    let full = asked(&t.b).2;
    t.until("A's refusal to reach B's status", 120, || {
        status(&t.b)["peers"][0]["error"].as_str().is_some_and(|e| e.contains("too slow"))
    });
    assert_eq!(asked(&t.b).2, full, "the whole list was asked for and refused: none came");
    assert!(!t.fb("x").join("x.txt").exists(), "nothing of the folder came");
    t.a.close();
    t.b.close();
}
