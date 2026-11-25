//! Step 3 part 2 over Reticulum (loopback TCP, no iroh address anywhere): a device that changes a folder tells the linked devices
//! that keep it ("folder F is at counter N", a notice); the one that gets it asks for a summary at once. A device that answers
//! summaries and is reached over Reticulum has no timer round: it is asked when a notice makes it due, when it is reachable
//! again, every safety interval (15 minutes; `safety_secs` here), and on Sync now. Any other device keeps today's timer round.
//! And a device that only sends sees the other one fetching from it ("fetching": the file windows it serves, and the summary the
//! fetcher sends).
//!
//! Hooks (files in a device's folder, read by the test-hooks build): `no-notice` (this device sends no notices: a lost one),
//! `no-summary` (acts as an older build), `reach-gap-ms` (how long without an announce makes a device reachable again),
//! `hold-store-ready` (this device's file windows are not served: its file store counts as not ready), `hold-fetch-mid` (a fetch is held after its first window, and says so with `hold-fetch.held`), `no-summary-fetching` (the
//! summary says nothing of a fetch in progress), `no-serve-signal` (the windows served are not noted).
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use cache_sync::{Config, SyncEngine};
use common::*;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// An engine with Reticulum on loopback TCP. `interval` is the timer round, `safety` the safety round (both in seconds).
fn eng(dir: &Path, name: &str, listen: Option<u16>, connect: Option<u16>, interval: u64, safety: u64) -> SyncEngine {
    let cfg = json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": interval, "safety_secs": safety, "reserve_bytes": 0, "reticulum": true,
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

fn rounds(e: &SyncEngine) -> u64 {
    call(e, "status", json!({}))["rounds"].as_u64().unwrap()
}

/// (summary, differences, whole list) requests made so far.
fn asked(e: &SyncEngine) -> (u64, u64, u64) {
    let v = call(e, "test_asked", json!({}));
    (v["summary"].as_u64().unwrap(), v["diff"].as_u64().unwrap(), v["full"].as_u64().unwrap())
}

/// (notices sent, notices taken) so far.
fn notices(e: &SyncEngine) -> (u64, u64) {
    let v = call(e, "test_asked", json!({}));
    (v["notice_sent"].as_u64().unwrap(), v["notice_got"].as_u64().unwrap())
}

fn peer_id(dir: &Path) -> String {
    saved_peer(dir)["id"].as_str().unwrap().to_string()
}

fn quiet(e: &SyncEngine, peer: &str) -> bool {
    call(e, "test_quiet", json!({"peer": peer}))["quiet"].as_bool().unwrap()
}

fn read(p: &Path) -> Option<String> {
    std::fs::read_to_string(p).ok()
}

/// A file written "a minute ago" as far as the file system says, so it is not held back as still being written.
fn put(path: &Path, bytes: &[u8]) {
    let f = std::fs::File::create(path).unwrap();
    std::io::Write::write_all(&mut &f, bytes).unwrap();
    f.set_modified(std::time::SystemTime::now() - Duration::from_secs(60)).unwrap();
}

struct Pair {
    _tmp: tempfile::TempDir,
    da: PathBuf,
    db: PathBuf,
    fa: PathBuf,
    fb: PathBuf,
    port: u16,
    a: Option<SyncEngine>,
    b: Option<SyncEngine>,
}

impl Pair {
    fn a(&self) -> &SyncEngine {
        self.a.as_ref().unwrap()
    }
    fn b(&self) -> &SyncEngine {
        self.b.as_ref().unwrap()
    }
    /// Rounds on both until `ok`.
    fn until(&self, what: &str, ok: impl Fn() -> bool) {
        for _ in 0..60 {
            round(self.a());
            round(self.b());
            if ok() {
                return;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        panic!("timed out waiting for {what}\nA: {}\nB: {}", brief(self.a()), brief(self.b()));
    }
    /// Until each device holds the other as quiet (summary-capable, reached over Reticulum, last round good).
    fn settle(&self) {
        // Each folder holds the id of the other device: A's folder says B, B's says A.
        let (b_id, a_id) = (peer_id(&self.da), peer_id(&self.db));
        for _ in 0..40 {
            round(self.a());
            round(self.b());
            if quiet(self.a(), &b_id) && quiet(self.b(), &a_id) {
                return;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
        panic!("the devices never became quiet\nA: {}\nB: {}", brief(self.a()), brief(self.b()));
    }
}

/// Two devices linked over Reticulum, keeping the share `fam`: A has `files`, B has nothing. `hooks_a` and `hooks_b` are hook files
/// made before the engines open. `(interval, safety)` for A and for B, in seconds.
fn pair(files: &[(&str, &str)], hooks_a: &[&str], hooks_b: &[&str], ta: (u64, u64), tb: (u64, u64)) -> Pair {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    for (n, t) in files {
        put(&fa.join(n), t.as_bytes());
    }
    let port = free_port();
    rns_only_dirs(&[&da, &db]);
    for h in hooks_a {
        std::fs::write(da.join(h), b"").unwrap();
    }
    for h in hooks_b {
        std::fs::write(db.join(h), b"").unwrap();
    }
    let a = eng(&da, "Desk", Some(port), None, ta.0, ta.1);
    let b = eng(&db, "Phone", None, Some(port), tb.0, tb.1);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("both sides to hold the address", 20, || saved_peer(&da)["rns"]["dest"].is_string() && saved_peer(&db)["rns"]["dest"].is_string());
    call(&a, "share_add", json!({"id": "fam", "name": "Family", "path": fa}));
    call(&b, "share_add", json!({"id": "fam", "name": "Family", "path": fb}));
    Pair { _tmp: tmp, da, db, fa, fb, port, a: Some(a), b: Some(b) }
}

fn close(mut t: Pair) {
    t.a.take().unwrap().close();
    t.b.take().unwrap().close();
}

// --- Notices ---

#[test]
fn a_change_on_a_reaches_b_within_seconds_with_every_timer_long() {
    // Both the timer round and the safety round are 600 s: only a notice can carry this change.
    let t = pair(&[("first.txt", "one")], &[], &[], (600, 600), (600, 600));
    let fb = t.fb.clone();
    t.until("the first file on B", || fb.join("first.txt").exists());
    t.settle();
    let before = notices(t.b());
    let started = Instant::now();
    put(&t.fa.join("second.txt"), b"two");
    call(t.a(), "sync_now", json!({}));
    wait("the second file on B", 12, || read(&fb.join("second.txt")).as_deref() == Some("two"));
    eprintln!("second file reached B after {:?}", started.elapsed());
    assert!(notices(t.b()).1 > before.1, "B took a notice: {before:?} {:?}", notices(t.b()));
    close(t);
}

#[test]
fn many_writes_in_a_burst_make_few_notices_per_peer_and_folder() {
    let t = pair(&[("first.txt", "one")], &[], &[], (600, 600), (600, 600));
    let fb = t.fb.clone();
    t.until("the first file on B", || fb.join("first.txt").exists());
    t.settle();
    // B writes each fetched file into its index on its own (30 stores in a few seconds): the notices to A are coalesced.
    let before = notices(t.b());
    for i in 0..30 {
        put(&t.fa.join(format!("burst{i:02}.txt")), format!("{i}").as_bytes());
    }
    call(t.a(), "sync_now", json!({}));
    wait("the burst on B", 30, || (0..30).all(|i| fb.join(format!("burst{i:02}.txt")).exists()));
    let sent = notices(t.b()).0 - before.0;
    assert!((1..=10).contains(&sent), "30 files written one by one made {sent} notices to one peer");
    close(t);
}

// --- An entry-point change is a notice too (step 4) ---

fn entry_ids(e: &SyncEngine) -> Vec<String> {
    call(e, "entry_points", json!({}))["entries"].as_array().unwrap().iter().map(|v| v["id"].as_str().unwrap().to_string()).collect()
}

#[test]
fn an_entry_added_on_a_reaches_a_quiet_b_within_seconds() {
    // Timer and safety rounds are 600 s on both and both hold the other as quiet: only a notice that carries the new `entries_v`
    // can make B ask `cache.entries`.
    let t = pair(&[("first.txt", "one")], &[], &[], (600, 600), (600, 600));
    let fb = t.fb.clone();
    t.until("the first file on B", || fb.join("first.txt").exists());
    t.settle();
    let before = notices(t.b());
    let started = Instant::now();
    // Nothing listens on this port: the entry only has to be in the list.
    let id = call(t.a(), "entry_point_set", json!({"host": "127.0.0.1", "port": free_port()}))["id"].as_str().unwrap().to_string();
    wait("the entry on B", 12, || entry_ids(t.b()).contains(&id));
    eprintln!("the entry reached B after {:?}", started.elapsed());
    assert!(notices(t.b()).1 > before.1, "B took a notice: {before:?} {:?}", notices(t.b()));
    // And a removal travels the same way.
    call(t.a(), "entry_point_remove", json!({"id": id}));
    wait("the removal on B", 12, || !entry_ids(t.b()).contains(&id));
    close(t);
}

// --- Nothing runs on a timer between two devices that answer summaries ---

#[test]
fn two_idle_summary_devices_make_no_rounds_after_the_first_catch_up() {
    // Timer 5 s on both: the old behaviour is a round every 5 s on each.
    let t = pair(&[("first.txt", "one")], &[], &[], (5, 600), (5, 600));
    let fb = t.fb.clone();
    t.until("the first file on B", || fb.join("first.txt").exists());
    t.settle();
    // Past anything the catch-up woke (a reachable-again note at the start, the last round's own wake).
    std::thread::sleep(Duration::from_secs(12));
    let (a0, b0) = (rounds(t.a()), rounds(t.b()));
    // Nothing happening is the point here, so this one is a fixed wait: 4 timer intervals.
    std::thread::sleep(Duration::from_secs(20));
    let (da, db) = (rounds(t.a()) - a0, rounds(t.b()) - b0);
    eprintln!("rounds over 20 s: A {da}, B {db}");
    assert!(da == 0 && db == 0, "idle summary devices still ran rounds: A {da}, B {db}");
    close(t);
}

// --- Away and back ---

#[test]
fn a_device_that_was_away_catches_up_without_waiting_for_the_safety_round() {
    let mut t = pair(&[("one.txt", "one"), ("two.txt", "two")], &[], &[], (600, 600), (600, 600));
    let fb = t.fb.clone();
    t.until("the files on B", || fb.join("one.txt").exists() && fb.join("two.txt").exists());
    t.settle();
    // B goes away; A changes several things meanwhile (its notices to B go nowhere).
    t.b.take().unwrap().close();
    put(&t.fa.join("three.txt"), b"three");
    put(&t.fa.join("one.txt"), b"one, edited");
    std::fs::remove_file(t.fa.join("two.txt")).unwrap();
    call(t.a(), "sync_now", json!({}));
    std::thread::sleep(Duration::from_secs(3));
    // B comes back; no one calls anything on it.
    t.b = Some(eng(&t.db, "Phone", None, Some(t.port), 600, 600));
    wait("B to catch up", 30, || {
        read(&fb.join("three.txt")).as_deref() == Some("three") && read(&fb.join("one.txt")).as_deref() == Some("one, edited") && !fb.join("two.txt").exists()
    });
    close(t);
}

#[test]
fn a_device_that_is_reachable_again_is_asked_when_its_notice_was_lost() {
    // B counts a device as reachable again after 3 s without an announce. A sends no notices (the hook), so only the announce
    // that A's restart sends can tell B. The timer and safety rounds are 600 s.
    let mut t = pair(&[("one.txt", "one")], &["no-notice"], &[], (600, 600), (600, 600));
    std::fs::write(t.db.join("reach-gap-ms"), b"3000").unwrap();
    let fb = t.fb.clone();
    t.until("the file on B", || fb.join("one.txt").exists());
    t.settle();
    // B takes its reach gap from its folder at start: open it again.
    t.b.take().unwrap().close();
    t.b = Some(eng(&t.db, "Phone", None, Some(t.port), 600, 600));
    t.settle();
    let before = asked(t.b());
    // A goes away for longer than the gap, changes a folder meanwhile, and comes back.
    t.a.take().unwrap().close();
    put(&t.fa.join("late.txt"), b"late");
    std::thread::sleep(Duration::from_secs(6));
    t.a = Some(eng(&t.da, "Desk", Some(t.port), None, 600, 600));
    wait("B to catch up", 60, || read(&fb.join("late.txt")).as_deref() == Some("late"));
    let after = asked(t.b());
    // The link B held to A died with A, so the summary may fail on it and the whole list come on the new one: either way B asked.
    assert!(after.0 + after.1 + after.2 > before.0 + before.1 + before.2, "B asked A: {before:?} {after:?}");
    close(t);
}

// --- A lost notice: the safety round ---

#[test]
fn a_lost_notice_is_covered_by_the_safety_round_with_a_summary_and_no_whole_list() {
    // A sends no notices. B's timer is 600 s but its safety round is 5 s.
    let t = pair(&[("first.txt", "one")], &["no-notice"], &[], (600, 600), (600, 5));
    let fb = t.fb.clone();
    t.until("the first file on B", || fb.join("first.txt").exists());
    t.settle();
    let before = asked(t.b());
    put(&t.fa.join("second.txt"), b"two");
    call(t.a(), "sync_now", json!({}));
    wait_dbg("the second file on B", 25, || read(&fb.join("second.txt")).as_deref() == Some("two"), || format!("asked {before:?} {:?} quiet {}\nA: {}\nB: {}", asked(t.b()), quiet(t.b(), &peer_id(&t.db)), brief(t.a()), brief(t.b())));
    let after = asked(t.b());
    assert!(after.0 > before.0, "a summary was asked for: {before:?} {after:?}");
    assert!(after.1 > before.1, "and the differences: {before:?} {after:?}");
    assert_eq!(after.2, before.2, "and not the whole list: {before:?} {after:?}");
    assert_eq!(notices(t.a()).0, 0, "A sent no notice");
    close(t);
}

// --- Devices that do not answer summaries keep today's behaviour ---

#[test]
fn a_device_without_summary_support_still_gets_the_timer_round_and_wakes_on_asked() {
    // A acts as an older build. B's timer is 5 s.
    let t = pair(&[("first.txt", "one")], &["no-summary"], &[], (600, 600), (5, 600));
    let fb = t.fb.clone();
    t.until("the first file on B", || fb.join("first.txt").exists());
    let a_id = peer_id(&t.db);
    assert!(!quiet(t.b(), &a_id), "an older build is not quiet");
    let b0 = rounds(t.b());
    // The timer is the point here: B must run rounds on its own. A minimum count, so wait for it (a loaded machine is slow).
    wait("B to run two rounds on its own timer", 60, || rounds(t.b()) - b0 >= 2);
    // A device that asks wakes a round, as today (a fresh device is not rate limited).
    assert!(call(t.b(), "test_ask", json!({"peer": a_id}))["wakes"].as_bool().unwrap(), "an older build that asks wakes a round");
    close(t);
}

#[test]
fn a_summary_device_that_asks_does_not_wake_a_round() {
    let t = pair(&[("first.txt", "one")], &[], &[], (600, 600), (600, 600));
    let fb = t.fb.clone();
    t.until("the first file on B", || fb.join("first.txt").exists());
    t.settle();
    let a_id = peer_id(&t.db);
    assert!(!call(t.b(), "test_ask", json!({"peer": a_id}))["wakes"].as_bool().unwrap(), "a notice replaces the wake");
    close(t);
}

// --- A notice from a device that is no longer linked ---

#[test]
fn a_notice_from_a_device_that_was_unlinked_is_refused_and_starts_nothing() {
    let t = pair(&[("first.txt", "one")], &[], &[], (600, 600), (600, 600));
    let fb = t.fb.clone();
    t.until("the first file on B", || fb.join("first.txt").exists());
    t.settle();
    // A unlinks B; B does not know yet.
    let b_id = peer_id(&t.da);
    call(t.a(), "unlink", json!({"peer": b_id}));
    std::thread::sleep(Duration::from_secs(2));
    let (a_rounds, a_notices) = (rounds(t.a()), notices(t.a()));
    let b_sent = notices(t.b()).0;
    put(&t.fb.join("from-b.txt"), b"hello");
    call(t.b(), "sync_now", json!({}));
    // B tries to send a notice; A refuses it. Nothing happening on A is the point, so this one is a fixed wait.
    wait("B to try a notice", 10, || notices(t.b()).0 > b_sent);
    std::thread::sleep(Duration::from_secs(6));
    assert_eq!(notices(t.a()).1, a_notices.1, "A took no notice");
    assert_eq!(rounds(t.a()), a_rounds, "and ran no round");
    assert!(!t.fa.join("from-b.txt").exists(), "and fetched nothing");
    close(t);
}

// --- A device that only sends sees the other one fetching ---

const BIG: usize = 40 * 1024 * 1024;

/// A pair in which B is fetching a 40 MiB file from A and is held part way (after its first window), A only sending.
fn held_fetch(hooks_a: &[&str], hooks_b: &[&str]) -> (Pair, Vec<u8>) {
    let mut b_hooks = vec!["hold-fetch-mid"];
    b_hooks.extend_from_slice(hooks_b);
    let t = pair(&[], hooks_a, &b_hooks, (600, 600), (600, 600));
    t.settle();
    let big = random(BIG, 5);
    put(&t.fa.join("video.bin"), &big);
    call(t.a(), "sync_now", json!({}));
    wait("B to hold its fetch", 120, || t.db.join("hold-fetch.held").exists());
    assert!(call(t.b(), "status", json!({}))["transfer"].is_object(), "B reports its own transfer");
    (t, big)
}

fn fetching(e: &SyncEngine) -> Value {
    call(e, "status", json!({}))["peers"][0]["fetching"].clone()
}

#[test]
fn the_sender_sees_the_other_device_fetching_through_the_windows_it_serves() {
    // B's summary says nothing of its fetch, so only what A serves can say it.
    let (t, _) = held_fetch(&[], &["no-summary-fetching"]);
    wait("A to see B fetching", 20, || fetching(t.a()).is_object());
    let f = fetching(t.a());
    assert_eq!(f["share"], "fam");
    assert_eq!(f["size"], BIG as u64);
    assert!(f["done"].as_u64().unwrap() >= 16 * 1024 * 1024, "at least the first window was served: {f}");
    assert!(f.get("path").is_none(), "the path is not shared");
    assert_eq!(call(t.a(), "status", json!({}))["transfer"], Value::Null, "A itself fetches nothing");
    // B finishes: the windows stop, and some 10 seconds after the last one A says so (no round on A in between).
    std::fs::remove_file(t.db.join("hold-fetch-mid")).unwrap();
    wait("the file on B", 120, || t.fb.join("video.bin").exists() && call(t.b(), "status", json!({}))["transfer"].is_null());
    let ended = Instant::now();
    wait("A to see B idle", 25, || fetching(t.a()) == Value::Null);
    eprintln!("cleared {:?} after the file was whole", ended.elapsed());
    close(t);
}

#[test]
fn the_sender_sees_the_other_device_fetching_through_the_summary_it_sends() {
    // A notes no windows served, so only B's summary can say it.
    let (t, _) = held_fetch(&["no-serve-signal"], &[]);
    assert_eq!(fetching(t.a()), Value::Null, "nothing yet: A has not asked B since");
    wait("A to see B fetching", 20, || {
        round(t.a());
        fetching(t.a()).is_object()
    });
    let f = fetching(t.a());
    assert_eq!(f["share"], "fam");
    assert_eq!(f["size"], BIG as u64);
    assert!(f.get("path").is_none(), "the path is not shared");
    std::fs::remove_file(t.db.join("hold-fetch-mid")).unwrap();
    wait("the file on B", 120, || t.fb.join("video.bin").exists() && call(t.b(), "status", json!({}))["transfer"].is_null());
    // The next look at B says it fetches nothing.
    wait("A to see B idle", 20, || {
        round(t.a());
        fetching(t.a()) == Value::Null
    });
    close(t);
}

// --- Files are served over Reticulum only once the file store is ready ---

#[test]
fn a_device_whose_file_store_is_not_ready_is_not_taken_as_not_having_the_file() {
    // B holds the file and its store counts as not ready (as during a move of an old store): A asks for the file and gets no data,
    // but is told "not ready", not "I do not have it". A keeps it wanted (nothing failed or dropped), and when B is ready it comes.
    let t = pair(&[], &[], &["hold-store-ready"], (600, 600), (600, 600));
    put(&t.fb.join("clip.bin"), &random(300 * 1024, 7));
    let want = std::fs::read(t.fb.join("clip.bin")).unwrap();
    call(t.b(), "sync_now", json!({}));
    call(t.a(), "sync_now", json!({}));
    wait_dbg(
        "A to be told B is not ready",
        60,
        || {
            call(t.a(), "sync_now", json!({}));
            brief(t.a()).contains("not ready")
        },
        || format!("A: {}\nB: {}", brief(t.a()), brief(t.b())),
    );
    assert!(!t.fa.join("clip.bin").exists(), "no data came from a device that is not ready");
    let b_says = brief(t.a());
    assert!(!b_says.contains("does not have"), "A was told B lacks the file: {b_says}");
    std::fs::remove_file(t.db.join("hold-store-ready")).unwrap();
    wait_dbg(
        "the file on A",
        60,
        || {
            call(t.a(), "sync_now", json!({}));
            std::fs::read(t.fa.join("clip.bin")).ok().as_deref() == Some(&want[..])
        },
        || format!("A: {}\nB: {}", brief(t.a()), brief(t.b())),
    );
    close(t);
}
