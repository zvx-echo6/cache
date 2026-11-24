//! Step 3 part 1 over Reticulum (loopback TCP, no iroh address anywhere): a device asks the other for a summary and, when only the
//! counter moved, for the differences; it keeps a mirror of the other's view of each folder, and the merge runs against that
//! exactly as it ran against a whole file list. The rule every test checks: after a round, the mirror equals what the other
//! device would send as its whole list for this device (`test_view`), and the files end up as the whole comparison leaves them.
#![cfg(any(target_os = "linux", target_os = "android"))]

mod common;
use cache_sync::{Config, SyncEngine};
use common::*;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// An engine with Reticulum on loopback TCP, rounds only when a test asks (the timer is an hour), and `extra` config keys.
fn eng(dir: &Path, name: &str, listen: Option<u16>, connect: Option<u16>, extra: Value) -> SyncEngine {
    let mut cfg = json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 3600, "reserve_bytes": 0, "reticulum": true,
        "rns_interfaces": {
            "tcp_listen": listen.map(|p| format!("127.0.0.1:{p}")),
            "tcp_connect": connect.map(|p| format!("127.0.0.1:{p}")),
        },
    });
    for (k, v) in extra.as_object().cloned().unwrap_or_default() {
        cfg[k] = v;
    }
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

fn peer_id(dir: &Path) -> String {
    saved_peer(dir)["id"].as_str().unwrap().to_string()
}

/// What `viewer` gets from `sender` as the share's whole list, and what `viewer` has saved as its mirror of it.
fn view_and_mirror(sender: &SyncEngine, viewer: &SyncEngine, viewer_id: &str, sender_id: &str, share: &str) -> (Value, Value) {
    let v = call(sender, "test_view", json!({"peer": viewer_id}));
    let files = v["shares"].as_array().unwrap().iter().find(|s| s["id"] == share).map(|s| s["index"]["files"].clone()).unwrap_or(Value::Null);
    let m = call(viewer, "test_mirror", json!({"peer": sender_id, "share": share}));
    (files, m)
}

/// The rule: B's mirror of A's folder equals what A would send B as its whole list.
fn assert_mirror(a: &SyncEngine, b: &SyncEngine, da: &Path, db: &Path, share: &str, what: &str) {
    let (view, mirror) = view_and_mirror(a, b, &peer_id(da), &peer_id(db), share);
    assert!(mirror.is_object(), "{what}: B has no mirror of A's {share}");
    assert_eq!(mirror["files"], view, "{what}: the mirror is not A's view");
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
    fn check(&self, what: &str) {
        assert_mirror(self.a(), self.b(), &self.da, &self.db, "fam", what);
    }
    /// Rounds on A then B until `ok`.
    fn until(&self, what: &str, ok: impl Fn() -> bool) {
        for _ in 0..60 {
            round(self.a());
            round(self.b());
            if ok() {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(500));
        }
        panic!("timed out waiting for {what}\nA: {}\nB: {}", brief(self.a()), brief(self.b()));
    }
}

/// Two devices linked over Reticulum, keeping the share `fam`: A has `files`, B has nothing. `extra_a` and `extra_b` are config.
fn pair(files: &[(&str, &str)], extra_a: Value, extra_b: Value) -> Pair {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::create_dir_all(&fb).unwrap();
    for (n, t) in files {
        if let Some(d) = Path::new(n).parent() {
            std::fs::create_dir_all(fa.join(d)).unwrap();
        }
        std::fs::write(fa.join(n), t).unwrap();
    }
    let port = free_port();
    rns_only_dirs(&[&da, &db]);
    let a = eng(&da, "Desk", Some(port), None, extra_a);
    let b = eng(&db, "Phone", None, Some(port), extra_b);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("both sides to hold the address", 20, || saved_peer(&da)["rns"]["dest"].is_string() && saved_peer(&db)["rns"]["dest"].is_string());
    call(&a, "share_add", json!({"id": "fam", "name": "Family", "path": fa}));
    call(&b, "share_add", json!({"id": "fam", "name": "Family", "path": fb}));
    Pair { _tmp: tmp, da, db, fa, fb, port, a: Some(a), b: Some(b) }
}

fn read(p: &Path) -> Option<String> {
    std::fs::read_to_string(p).ok()
}

#[test]
fn the_mirror_follows_a_device_through_changes_pages_and_a_reset_index() {
    let mut t = pair(&[("a.txt", "one"), ("b.txt", "two"), ("c.txt", "three")], json!({}), json!({}));
    let (fb, fa) = (t.fb.clone(), t.fa.clone());
    t.until("the files on B", || fb.join("a.txt").exists() && fb.join("b.txt").exists() && fb.join("c.txt").exists());
    t.check("the first list");
    let first = asked(t.b());
    assert!(first.2 >= 1, "the first contact asks for the whole list: {first:?}");
    // The device is known to answer summaries now (and that survives: a mirror is saved).

    // Nothing changed: a summary only.
    let before = asked(t.b());
    round(t.b());
    round(t.b());
    let after = asked(t.b());
    assert!(after.0 >= before.0 + 2, "{before:?} {after:?}");
    assert_eq!((after.1, after.2), (before.1, before.2), "nothing to fetch when everything is equal");
    t.check("quiet");

    // A new file, an edit and a delete on A come as differences.
    let before = asked(t.b());
    std::fs::write(fa.join("d.txt"), "four").unwrap();
    std::fs::write(fa.join("a.txt"), "one, edited").unwrap();
    std::fs::remove_file(fa.join("b.txt")).unwrap();
    t.until("the changes on B", || read(&fb.join("d.txt")).as_deref() == Some("four") && read(&fb.join("a.txt")).as_deref() == Some("one, edited") && !fb.join("b.txt").exists());
    let after = asked(t.b());
    assert!(after.1 > before.1, "differences were asked for: {before:?} {after:?}");
    assert_eq!(after.2, before.2, "and not the whole list");
    t.check("after the changes");

    // Many entries sharing one counter, over several pages.
    std::fs::write(t.da.join("diff-page-bytes"), "300").unwrap();
    for i in 0..12 {
        std::fs::write(fa.join(format!("p{i:02}.txt")), format!("page {i}")).unwrap();
    }
    let before = asked(t.b());
    t.until("the paged files on B", || (0..12).all(|i| fb.join(format!("p{i:02}.txt")).exists()));
    let after = asked(t.b());
    assert!(after.1 >= before.1 + 3, "several pages: {before:?} {after:?}");
    assert_eq!(after.2, before.2);
    t.check("after the pages");

    // A's index is reset (its epoch changes): the whole list again, the same files, no conflict copies.
    let share_index = t.da.join("index");
    t.a.take().unwrap().close();
    for f in std::fs::read_dir(&share_index).unwrap().flatten() {
        std::fs::remove_file(f.path()).unwrap();
    }
    let a = eng(&t.da, "Desk", Some(t.port), None, json!({}));
    t.a = Some(a);
    let before = asked(t.b());
    std::thread::sleep(std::time::Duration::from_secs(3));
    round(t.a());
    round(t.b());
    let after = asked(t.b());
    assert!(after.2 > before.2, "another epoch: the whole list again: {before:?} {after:?}");
    t.check("after the reset");
    let names: Vec<String> = std::fs::read_dir(&fb).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    assert!(names.iter().all(|n| !n.contains("conflict")), "{names:?}");
    assert_eq!(read(&fb.join("a.txt")).as_deref(), Some("one, edited"));
    t.a.take().unwrap().close();
    t.b.take().unwrap().close();
}

// --- A change of what A offers B forces the whole list for that folder, and the mirror drops or takes the entries ---

const FILTER_FILES: &[(&str, &str)] = &[("a.txt", "kept"), ("photos/p1.jpg", "photo"), ("photos/p2.jpg", "photo two"), ("notes/n1.txt", "note")];

/// `change` alters what A offers B (and says which paths leave its view); `undo` puts it back. After each, one whole list is
/// asked for, the mirror equals A's view, and the paths left out are not in the mirror.
fn filter_case(change: impl Fn(&SyncEngine), left: &[&str], undo: impl Fn(&SyncEngine)) {
    let mut t = pair(FILTER_FILES, json!({}), json!({}));
    let fb = t.fb.clone();
    t.until("the files on B", || fb.join("notes/n1.txt").exists() && fb.join("photos/p2.jpg").exists());
    t.check("the first list");
    round(t.b());
    let calm = asked(t.b());
    // A change that does not touch the view: no whole list.
    std::fs::write(t.fa.join("a.txt"), "kept, edited").unwrap();
    t.until("the edit on B", || read(&fb.join("a.txt")).as_deref() == Some("kept, edited"));
    assert_eq!(asked(t.b()).2, calm.2, "an edit alone does not ask for the whole list");

    let before = asked(t.b());
    change(t.a());
    round(t.a());
    round(t.b());
    let after = asked(t.b());
    assert!(after.2 > before.2, "the view changed: the whole list for the folder: {before:?} {after:?}");
    t.check("after the change");
    let m = call(t.b(), "test_mirror", json!({"peer": peer_id(&t.db), "share": "fam"}));
    for p in left {
        assert!(m["files"].get(*p).is_none(), "{p} is still in the mirror");
    }
    assert!(m["files"].get("a.txt").is_some());

    let before = asked(t.b());
    undo(t.a());
    round(t.a());
    round(t.b());
    let after = asked(t.b());
    assert!(after.2 > before.2, "and back: {before:?} {after:?}");
    t.check("after it was undone");
    let m = call(t.b(), "test_mirror", json!({"peer": peer_id(&t.db), "share": "fam"}));
    for p in left {
        assert!(m["files"].get(*p).is_some(), "{p} is not back in the mirror");
    }
    t.a.take().unwrap().close();
    t.b.take().unwrap().close();
}

fn off(e: &SyncEngine, list: &[&str]) {
    call(e, "set_off", json!({"id": "fam", "off": list}));
}

#[test]
fn a_kind_switched_off_and_on_forces_the_whole_list_and_the_mirror_follows() {
    // The app sends a kind that is off as a pattern for the folder of that kind.
    filter_case(|a| off(a, &["photos"]), &["photos/p1.jpg", "photos/p2.jpg"], |a| off(a, &[]));
}

#[test]
fn an_item_switched_off_and_on_forces_the_whole_list_and_the_mirror_follows() {
    filter_case(|a| off(a, &["notes/n1.txt"]), &["notes/n1.txt"], |a| off(a, &[]));
}

#[test]
fn a_private_item_forces_the_whole_list_and_the_mirror_follows() {
    // A private item is sent as the path of that item in the off list, with the others of its kind still on.
    filter_case(|a| off(a, &["photos/p2.jpg"]), &["photos/p2.jpg"], |a| off(a, &[]));
}

#[test]
fn a_held_back_folder_forces_the_whole_list_and_the_mirror_follows() {
    filter_case(
        |a| call(a, "set_gate", json!({"id": "fam", "dir": "photos", "allow": ["photos/p1.jpg"]})).as_object().map(|_| ()).unwrap_or(()),
        &["photos/p2.jpg"],
        |a| {
            call(a, "set_gate", json!({"id": "fam"}));
        },
    );
}

#[test]
fn a_pattern_that_never_syncs_changed_forces_the_whole_list_and_the_mirror_follows() {
    let mut t = pair(FILTER_FILES, json!({}), json!({}));
    let fb = t.fb.clone();
    t.until("the files on B", || fb.join("notes/n1.txt").exists());
    t.check("the first list");
    // A starts again with a pattern that keeps notes out of every list.
    t.a.take().unwrap().close();
    t.a = Some(eng(&t.da, "Desk", Some(t.port), None, json!({"exclude": {"fam": ["notes"]}})));
    let before = asked(t.b());
    std::thread::sleep(std::time::Duration::from_secs(3));
    round(t.a());
    round(t.b());
    let after = asked(t.b());
    assert!(after.2 > before.2, "{before:?} {after:?}");
    t.check("with the pattern");
    let m = call(t.b(), "test_mirror", json!({"peer": peer_id(&t.db), "share": "fam"}));
    assert!(m["files"].get("notes/n1.txt").is_none() && m["files"].get("a.txt").is_some());
    t.a.take().unwrap().close();
    t.b.take().unwrap().close();
}

// --- An older peer, a peer that does not answer, and a stop between applying a page and saving it ---

#[test]
fn a_device_that_does_not_answer_the_summary_is_synced_with_the_whole_list_as_today() {
    let mut t = pair(&[("a.txt", "one")], json!({}), json!({}));
    // A acts as an older build: its list says nothing of summaries, and carries no counters.
    std::fs::write(t.da.join("no-summary"), b"").unwrap();
    let fb = t.fb.clone();
    t.until("the file on B", || fb.join("a.txt").exists());
    let before = asked(t.b());
    std::fs::write(t.fa.join("b.txt"), "two").unwrap();
    t.until("the second file on B", || fb.join("b.txt").exists());
    let after = asked(t.b());
    assert_eq!((after.0, after.1), (0, 0), "no summary and no differences were asked of an older build: {after:?}");
    assert!(after.2 > before.2);
    assert!(call(t.b(), "test_mirror", json!({"peer": peer_id(&t.db), "share": "fam"})).is_null(), "no mirror of an older build");

    // A newer build again: the whole list once, then summaries.
    std::fs::remove_file(t.da.join("no-summary")).unwrap();
    t.until("a mirror", || call(t.b(), "test_mirror", json!({"peer": peer_id(&t.db), "share": "fam"})).is_object());
    t.check("a newer build");
    let before = asked(t.b());
    std::fs::write(t.fa.join("c.txt"), "three").unwrap();
    t.until("the third file on B", || fb.join("c.txt").exists());
    let after = asked(t.b());
    assert!(after.1 > before.1 && after.2 == before.2, "{before:?} {after:?}");

    // A claims to answer but does not (an answer that is not one): the whole list, and the folder still syncs.
    std::fs::write(t.da.join("no-delta"), b"").unwrap();
    let before = asked(t.b());
    std::fs::write(t.fa.join("d.txt"), "four").unwrap();
    t.until("the fourth file on B", || fb.join("d.txt").exists());
    let after = asked(t.b());
    assert!(after.2 > before.2, "{before:?} {after:?}");
    std::fs::remove_file(t.da.join("no-delta")).unwrap();
    t.until("the mirror back", || {
        let (view, m) = view_and_mirror(t.a(), t.b(), &peer_id(&t.da), &peer_id(&t.db), "fam");
        m["files"] == view
    });
    t.a.take().unwrap().close();
    t.b.take().unwrap().close();
}

#[test]
fn a_stop_between_applying_a_page_and_saving_it_leaves_the_mirror_as_it_was_and_it_catches_up_after_a_restart() {
    let mut t = pair(&[("a.txt", "one")], json!({}), json!({}));
    let fb = t.fb.clone();
    t.until("the file on B", || fb.join("a.txt").exists());
    t.check("the first list");
    let saved = std::fs::read(t.db.join("mirror").read_dir().unwrap().flatten().next().unwrap().path()).unwrap();
    // From here B is stopped after taking a page, before saving it: half of it reaches the temporary file.
    std::fs::write(t.db.join("kill-before-mirror-save"), b"").unwrap();
    for i in 0..4 {
        std::fs::write(t.fa.join(format!("n{i}.txt")), format!("new {i}")).unwrap();
    }
    let tmp = t.db.join("mirror").read_dir().unwrap().flatten().map(|e| e.path().with_extension("tmp")).next().unwrap();
    wait_dbg(
        "the stop",
        60,
        || {
            round(t.a());
            round(t.b());
            tmp.exists()
        },
        || brief(t.b()),
    );
    let file = tmp.with_extension("json");
    assert_eq!(std::fs::read(&file).unwrap(), saved, "the saved mirror is as it was");
    assert!(!fb.join("n0.txt").exists(), "nothing was written from a page that was not saved");
    t.b.take().unwrap().close();
    std::fs::remove_file(t.db.join("kill-before-mirror-save")).unwrap();
    let b = eng(&t.db, "Phone", None, Some(t.port), json!({}));
    t.b = Some(b);
    t.until("the new files on B", || (0..4).all(|i| fb.join(format!("n{i}.txt")).exists()));
    t.check("after the restart");
    t.a.take().unwrap().close();
    t.b.take().unwrap().close();
}

// --- What does not change: a retry, a forgotten entry, a fetch pattern, the same outcome as with the whole list ---

#[test]
fn a_failed_fetch_a_forgotten_entry_and_a_fetch_pattern_come_out_as_with_the_whole_list() {
    let mut t = pair(&[("a.txt", "one"), ("m.txt", "middle"), ("z.txt", "last")], json!({}), json!({}));
    let fb = t.fb.clone();
    // m.txt cannot be fetched on B yet.
    std::fs::write(t.db.join("fail-fetch"), "m.txt").unwrap();
    t.until("the other files on B", || fb.join("a.txt").exists() && fb.join("z.txt").exists());
    assert!(!fb.join("m.txt").exists());
    // The mirror holds it, and the next rounds (which ask nothing of A but a summary) retry it, as the whole list did.
    let before = asked(t.b());
    round(t.b());
    assert!(call(t.b(), "status", json!({}))["log"].to_string().matches("could not fetch m.txt").count() >= 2);
    assert_eq!(asked(t.b()).2, before.2);
    std::fs::remove_file(t.db.join("fail-fetch")).unwrap();
    t.until("m.txt on B", || fb.join("m.txt").exists());
    t.check("after the retry");

    // A fetch pattern changed on B: what it did not take comes when it is switched on, though A has not changed.
    std::fs::write(t.fa.join("late.txt"), "late").unwrap();
    call(t.b(), "set_never_fetch", json!({"id": "fam", "never_fetch": ["late.txt"]}));
    t.until("the mirror to hold late.txt", || {
        let m = call(t.b(), "test_mirror", json!({"peer": peer_id(&t.db), "share": "fam"}));
        m["files"].get("late.txt").is_some()
    });
    assert!(!fb.join("late.txt").exists(), "never fetched");
    call(t.b(), "set_never_fetch", json!({"id": "fam", "never_fetch": []}));
    let before = asked(t.b());
    t.until("late.txt on B", || fb.join("late.txt").exists());
    assert_eq!(asked(t.b()).2, before.2, "from the mirror, not a new list");

    // An entry forgotten on B (a write cut off while it was made): the next comparison fetches it again from the mirror.
    t.b.take().unwrap().close();
    let path = t.db.join("index").join("fam.json");
    let mut idx: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    idx["files"].as_object_mut().unwrap().remove("z.txt");
    std::fs::write(&path, serde_json::to_vec(&idx).unwrap()).unwrap();
    std::fs::remove_file(fb.join("z.txt")).unwrap();
    t.b = Some(eng(&t.db, "Phone", None, Some(t.port), json!({})));
    t.until("z.txt back on B", || read(&fb.join("z.txt")).as_deref() == Some("last"));
    t.check("after the forgotten entry");
    t.a.take().unwrap().close();
    t.b.take().unwrap().close();
}

// --- Every combination of only-here, only-there and both changed, against the whole comparison ---

/// The files under `root` as (path with the conflict stamp taken out, content), sorted.
fn tree(root: &Path) -> Vec<(String, String)> {
    fn walk(root: &Path, dir: &Path, out: &mut Vec<(String, String)>) {
        for e in std::fs::read_dir(dir).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                walk(root, &p, out);
            } else {
                let rel = p.strip_prefix(root).unwrap().to_string_lossy().into_owned();
                // "x (conflict, Phone, 2026-11-23 1504).txt" -> "x (conflict, Phone).txt"
                let rel = match (rel.find(" (conflict, "), rel.find(')')) {
                    (Some(i), Some(j)) => {
                        let inner = &rel[i + 12..j];
                        let dev = inner.split(',').next().unwrap_or("");
                        format!("{} (conflict, {dev}){}", &rel[..i], &rel[j + 1..])
                    }
                    _ => rel,
                };
                out.push((rel, std::fs::read_to_string(&p).unwrap_or_default()));
            }
        }
    }
    let mut v = Vec::new();
    walk(root, root, &mut v);
    v.sort();
    v
}

/// Both devices change the same folder while apart, in every combination; then they meet. `whole` makes both act as an older
/// build, so the whole list is what is compared (today's behaviour).
type Files = Vec<(String, String)>;

fn apart_and_together(whole: bool) -> (Files, Files) {
    let start = [
        ("only_a.txt", "start"),
        ("only_b.txt", "start"),
        ("both.txt", "start"),
        ("del_a_edit_b.txt", "start"),
        ("edit_a_del_b.txt", "start"),
        ("both_del.txt", "start"),
        ("del_a.txt", "start"),
        ("untouched.txt", "start"),
    ];
    let mut t = pair(&start, json!({}), json!({}));
    let (fa, fb) = (t.fa.clone(), t.fb.clone());
    t.until("the start on B", || start.iter().all(|(n, _)| fb.join(n).exists()));
    if !whole {
        t.check("together at the start");
    }
    if whole {
        std::fs::write(t.da.join("no-summary"), b"").unwrap();
        std::fs::write(t.db.join("no-summary"), b"").unwrap();
    }
    call(t.a(), "set_policy", json!({"network": false}));
    call(t.b(), "set_policy", json!({"network": false}));
    let pause = || std::thread::sleep(std::time::Duration::from_millis(60));
    let w = |p: &Path, n: &str, text: &str| std::fs::write(p.join(n), text).unwrap();
    w(&fa, "only_a.txt", "A edit");
    pause();
    w(&fb, "only_b.txt", "B edit");
    pause();
    w(&fa, "both.txt", "A edit of both");
    pause();
    w(&fb, "both.txt", "B edit of both");
    pause();
    std::fs::remove_file(fa.join("del_a_edit_b.txt")).unwrap();
    w(&fb, "del_a_edit_b.txt", "B edit after A deleted");
    pause();
    w(&fa, "edit_a_del_b.txt", "A edit before B deleted");
    std::fs::remove_file(fb.join("edit_a_del_b.txt")).unwrap();
    std::fs::remove_file(fa.join("both_del.txt")).unwrap();
    std::fs::remove_file(fb.join("both_del.txt")).unwrap();
    std::fs::remove_file(fa.join("del_a.txt")).unwrap();
    w(&fa, "new_a.txt", "new on A");
    w(&fb, "new_b.txt", "new on B");
    std::thread::sleep(std::time::Duration::from_secs(7));
    round(t.a());
    round(t.b());
    call(t.a(), "set_policy", json!({"network": true}));
    call(t.b(), "set_policy", json!({"network": true}));
    for _ in 0..8 {
        round(t.a());
        round(t.b());
        std::thread::sleep(std::time::Duration::from_millis(800));
    }
    if !whole {
        t.check("together again");
    }
    let out = (tree(&fa), tree(&fb));
    t.a.take().unwrap().close();
    t.b.take().unwrap().close();
    out
}

#[test]
fn every_combination_of_only_here_only_there_and_both_changed_ends_as_with_the_whole_comparison() {
    let today = apart_and_together(true);
    let mirrored = apart_and_together(false);
    assert_eq!(mirrored.0, today.0, "A's folder");
    assert_eq!(mirrored.1, today.1, "B's folder");
    // And the whole comparison itself did what the rules say.
    let a: std::collections::BTreeMap<_, _> = today.0.iter().cloned().collect();
    assert_eq!(a["only_a.txt"], "A edit");
    assert_eq!(a["only_b.txt"], "B edit");
    assert_eq!(a["new_b.txt"], "new on B");
    assert!(!a.contains_key("both_del.txt") && !a.contains_key("del_a.txt"));
    assert!(a.keys().any(|k| k.starts_with("both (conflict")), "{a:?}");
    assert_eq!(a["del_a_edit_b.txt"], "B edit after A deleted", "kept: changed after the delete");
    assert_eq!(a["edit_a_del_b.txt"], "A edit before B deleted", "kept");
}

// --- Three devices: one away through several changes and back ---

fn id_named(dir: &Path, name: &str) -> String {
    let v: Value = serde_json::from_slice(&std::fs::read(dir.join("sync.json")).unwrap()).unwrap();
    v["peers"].as_array().unwrap().iter().find(|p| p["name"] == name).unwrap()["id"].as_str().unwrap().to_string()
}

// Not run with the others: through the transport node the first exchanges take minutes (a routed path is slow to come, as in
// the routed test), and this did not finish in 700 seconds; run it by hand with `-- --ignored`.
#[test]
fn three_devices_one_away_through_several_changes_and_back_comes_back_by_differences() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db, dc) = (tmp.path().join("a"), tmp.path().join("b"), tmp.path().join("c"));
    let (fa, fb, fc) = (tmp.path().join("fa"), tmp.path().join("fb"), tmp.path().join("fc"));
    for f in [&fa, &fb, &fc] {
        std::fs::create_dir_all(f).unwrap();
    }
    std::fs::write(fa.join("one.txt"), "one").unwrap();
    std::fs::write(fa.join("two.txt"), "two").unwrap();
    // A listens; a transport node (what rnsd is on a real network) connects to it, and B and C connect to the node.
    let (port, port_mid) = (free_port(), free_port());
    rns_only_dirs(&[&da, &db, &dc]);
    let a = eng(&da, "Desk", Some(port), None, json!({}));
    let _mid = node::transport(port_mid, port);
    let b = eng(&db, "Phone", None, Some(port_mid), json!({}));
    let c = eng(&dc, "Tablet", None, Some(port_mid), json!({}));
    std::thread::sleep(std::time::Duration::from_secs(3));
    for e in [&a, &b, &c] {
        call(e, "network_changed", json!({}));
    }
    std::thread::sleep(std::time::Duration::from_secs(3));
    for (dev, dir) in [(&b, &db), (&c, &dc)] {
        let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
        call(dev, "link", json!({"code": code}));
        wait("the address", 20, || saved_peer(dir)["rns"]["dest"].is_string());
    }
    let (a_id, b_id, c_id) = (id_named(&db, "Desk"), id_named(&da, "Phone"), id_named(&da, "Tablet"));
    call(&a, "share_add", json!({"id": "fam", "name": "Family", "path": fa}));
    call(&b, "share_add", json!({"id": "fam", "name": "Family", "path": fb}));
    call(&c, "share_add", json!({"id": "fam", "name": "Family", "path": fc}));
    // Rounds on all three each time it looks (they run in the background; a routed path is slow to come the first time).
    let slow = |what: &str, ok: &dyn Fn() -> bool| {
        wait_dbg(
            what,
            400,
            || {
                for e in [&a, &b, &c] {
                    call(e, "sync_now", json!({}));
                }
                std::thread::sleep(std::time::Duration::from_millis(750));
                ok()
            },
            || format!("A: {}\nB: {}\nC: {}", brief(&a), brief(&b), brief(&c)),
        )
    };
    slow("the files on B and C", &|| fb.join("two.txt").exists() && fc.join("two.txt").exists());
    let mirrors_equal = |sender: &SyncEngine, viewer: &SyncEngine, vid: &str, sid: &str| {
        let (view, m) = view_and_mirror(sender, viewer, vid, sid, "fam");
        m.is_object() && m["files"] == view
    };
    slow("the mirrors", &|| mirrors_equal(&a, &b, &b_id, &a_id) && mirrors_equal(&a, &c, &c_id, &a_id));

    // C is away through several changes on A and B.
    call(&c, "set_policy", json!({"network": false}));
    let before = asked(&c);
    for step in 0..4 {
        std::fs::write(fa.join(format!("a{step}.txt")), format!("from A {step}")).unwrap();
        std::fs::write(fb.join(format!("b{step}.txt")), format!("from B {step}")).unwrap();
        if step == 1 {
            std::fs::write(fa.join("one.txt"), "one, edited").unwrap();
        }
        if step == 2 {
            std::fs::remove_file(fb.join("two.txt")).unwrap();
        }
        let n = step;
        slow("the step on A and B", &|| fb.join(format!("a{n}.txt")).exists() && fa.join(format!("b{n}.txt")).exists());
    }
    slow("the edit and the delete between A and B", &|| read(&fb.join("one.txt")).as_deref() == Some("one, edited") && !fa.join("two.txt").exists());
    assert!(!fc.join("b3.txt").exists(), "C is away");

    // C comes back: it asks for what changed, not the whole list, and ends the same as the others.
    call(&c, "set_policy", json!({"network": true}));
    slow("C to catch up", &|| {
        fc.join("b3.txt").exists() && fc.join("a3.txt").exists() && !fc.join("two.txt").exists() && read(&fc.join("one.txt")).as_deref() == Some("one, edited")
    });
    let after = asked(&c);
    assert!(after.1 > before.1, "differences: {before:?} {after:?}");
    assert_eq!(after.2, before.2, "not the whole list: {before:?} {after:?}");
    slow("the mirrors again", &|| mirrors_equal(&a, &c, &c_id, &a_id) && mirrors_equal(&a, &b, &b_id, &a_id));
    assert_eq!(tree(&fa), tree(&fc));
    assert_eq!(tree(&fa), tree(&fb));
    a.close();
    b.close();
    c.close();
}
