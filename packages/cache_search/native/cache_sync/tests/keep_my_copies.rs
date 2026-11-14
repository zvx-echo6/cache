//! "Don't replace my copies from this device" (`set_keep_copies`, one linked device, this device's own choice): with it on,
//! nothing that device does replaces or removes a file here. In a share of things the person made (`beside`, Cache's
//! notebooks with their places and photos) its newer version of a file held here arrives beside it, as
//! "<name> (from <device>)", and its new files still come; in any other share (things that can be downloaded again) nothing of
//! it is taken. Shares listed in `not_copies` are never touched. With the switch off nothing changes. Two devices, then three
//! (A matches B, B sends to C). Files are checked byte for byte.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "beside": ["notebooks"], "not_copies": ["settings"],
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn status(e: &SyncEngine) -> Value {
    call(e, "status", json!({}))
}

fn id_of(e: &SyncEngine) -> String {
    status(e)["id"].as_str().unwrap().to_string()
}

fn peer(e: &SyncEngine, of: &str) -> Value {
    status(e)["peers"].as_array().unwrap().iter().find(|p| p["id"] == of).cloned().unwrap_or(Value::Null)
}

fn link(a: &SyncEngine, b: &SyncEngine) {
    let code = call(a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(b, "link", json!({"code": code}));
}

fn keep_copies(e: &SyncEngine, of: &str, on: bool) {
    call(e, "set_keep_copies", json!({"peer": of, "on": on}));
    assert_eq!(peer(e, of)["keep_copies"], on);
}

fn logs(all: &[&SyncEngine]) -> String {
    all.iter().map(|e| status(e)["log"].to_string()).collect::<Vec<_>>().join("\n")
}

/// Waits for `ok`, asking every engine for a round now and then.
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
    panic!("timed out waiting for {what}\n{}", logs(all));
}

/// Waits until each engine has finished at least `n` more whole rounds (each one reads every linked device's file list).
fn more_rounds(all: &[&SyncEngine], n: u64) {
    let start: Vec<u64> = all.iter().map(|e| status(e)["rounds"].as_u64().unwrap_or(0)).collect();
    until("more rounds", 120, all, || all.iter().zip(&start).all(|(e, s)| status(e)["rounds"].as_u64().unwrap_or(0) >= s + n));
}

fn put(p: &Path, bytes: &[u8]) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, bytes).unwrap();
}

/// The file's bytes are exactly `want`.
fn is(p: &Path, want: &[u8]) -> bool {
    std::fs::read(p).map(|b| b == want).unwrap_or(false)
}

/// The names in `dir` (not recursive).
fn names(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir).map(|r| r.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default();
    v.sort();
    v
}

/// A copy of `stem` beside it from `device` (`<stem> (from <device>)` with `stamped`, `<stem> (from <device>, <time>)`)
/// holds exactly `want`.
fn beside_holds(dir: &Path, stem: &str, ext: &str, device: &str, stamped: bool, want: &[u8]) -> bool {
    names(dir).iter().any(|n| {
        let ok = if stamped { n.starts_with(&format!("{stem} (from {device}, ")) && n.ends_with(&format!("){ext}")) } else { *n == format!("{stem} (from {device}){ext}") };
        ok && is(&dir.join(n), want)
    })
}

fn any_beside(dir: &Path) -> bool {
    names(dir).iter().any(|n| n.contains("(from "))
}

/// A conflict copy of `stem` in `dir` holds exactly `want`.
fn copy_holds(dir: &Path, stem: &str, want: &[u8]) -> bool {
    names(dir).iter().any(|n| n.starts_with(&format!("{stem} (conflict, ")) && is(&dir.join(n), want))
}

fn any_conflict_copy(dir: &Path) -> bool {
    names(dir).iter().any(|n| n.contains("(conflict, "))
}

/// `e` has indexed `share` holding `here` and not `gone` (its items, `share_items`).
fn indexed(e: &SyncEngine, share: &str, here: &[&str], gone: &[&str]) -> bool {
    let items = call(e, "share_items", json!({"id": share}))["items"].as_array().unwrap().clone();
    let held = |n: &str| items.iter().any(|i| i["name"] == n && i["files"].as_u64().unwrap_or(0) > 0);
    here.iter().all(|n| held(n)) && gone.iter().all(|n| !held(n))
}

fn pending(e: &SyncEngine, share: &str) -> u64 {
    status(e)["shares"].as_array().unwrap().iter().find(|s| s["id"] == share).map(|s| s["pending_files"].as_u64().unwrap_or(0)).unwrap_or(0)
}

/// Joins `share` on `e` into `dir` once a linked device offers it.
fn join(e: &SyncEngine, share: &str, dir: &Path, all: &[&SyncEngine]) {
    until("the offer", 60, all, || status(e)["offers"].as_array().map(|o| o.iter().any(|x| x["id"] == share)).unwrap_or(false));
    call(e, "share_join", json!({"id": share, "path": dir}));
}

/// A Desk sharing four files with a Tablet in a share of its own (not one of things the person made), both holding them
/// (folders `folder-a` and `folder-c`).
struct Pair {
    a: SyncEngine,
    c: SyncEngine,
    ic: String,
    share: String,
}

fn pair(tmp: &Path, big: &[u8]) -> Pair {
    let (fa, fc) = (tmp.join("folder-a"), tmp.join("folder-c"));
    put(&fa.join("edit.txt"), b"desk v1");
    put(&fa.join("del.txt"), b"desk keeps this");
    put(&fa.join("ren.bin"), big);
    put(&fa.join("untouched.txt"), b"goes when the desk deletes it");
    std::fs::create_dir_all(&fc).unwrap();
    let a = engine(&tmp.join("a"), "Desk");
    let c = engine(&tmp.join("c"), "Tablet");
    link(&a, &c);
    let ic = id_of(&c);
    let share = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    join(&c, &share, &fc, &[&a, &c]);
    until("the Desk's files on the Tablet", 90, &[&a, &c], || {
        is(&fc.join("edit.txt"), b"desk v1") && is(&fc.join("del.txt"), b"desk keeps this") && is(&fc.join("ren.bin"), big) && fc.join("untouched.txt").exists()
    });
    Pair { a, c, ic, share }
}

/// The Tablet edits edit.txt, deletes del.txt, renames ren.bin to renamed.bin and adds new.txt, and has indexed it all.
fn tablet_changes(p: &Pair, fc: &Path) {
    std::thread::sleep(Duration::from_millis(1100));
    put(&fc.join("edit.txt"), b"tablet edit");
    std::fs::remove_file(fc.join("del.txt")).unwrap();
    std::fs::rename(fc.join("ren.bin"), fc.join("renamed.bin")).unwrap();
    put(&fc.join("new.txt"), b"tablet new");
    until("the Tablet's changes indexed", 90, &[&p.a, &p.c], || indexed(&p.c, &p.share, &["edit.txt", "renamed.bin", "new.txt"], &["del.txt", "ren.bin"]));
}

/// Two devices sharing `id` (a fixed share id, "" for one of its own), the Desk's `files` on both.
fn two(tmp: &Path, id: &str, files: &[(&str, &[u8])]) -> (SyncEngine, SyncEngine, String, String, String) {
    let (fa, fc) = (tmp.join(format!("{id}-a")), tmp.join(format!("{id}-c")));
    for (rel, data) in files {
        put(&fa.join(rel), data);
    }
    std::fs::create_dir_all(&fc).unwrap();
    let a = engine(&tmp.join(format!("{id}-dev-a")), "Desk");
    let c = engine(&tmp.join(format!("{id}-dev-c")), "Tablet");
    link(&a, &c);
    let (ia, ic) = (id_of(&a), id_of(&c));
    let share = add(&a, &fa, id);
    join(&c, &share, &fc, &[&a, &c]);
    until("the Desk's files on the Tablet", 90, &[&a, &c], || files.iter().all(|(rel, data)| is(&fc.join(rel), data)));
    (a, c, ia, ic, share)
}

fn add(e: &SyncEngine, dir: &Path, id: &str) -> String {
    let mut args = json!({"path": dir, "name": "Shared"});
    if !id.is_empty() {
        args["id"] = json!(id);
    }
    call(e, "share_add", args)["id"].as_str().unwrap().to_string()
}

#[test]
fn made_things_newer_versions_from_that_device_arrive_beside_mine_and_nothing_is_replaced_or_removed() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fc) = (tmp.path().join("notebooks-a"), tmp.path().join("notebooks-c"));
    let photo: Vec<u8> = (0..1_500_000u32).map(|i| (i * 7 % 251) as u8).collect();
    let (a, c, ia, ic, share) = two(
        tmp.path(),
        "notebooks",
        &[("Journal/entry.md", &b"desk v1"[..]), ("Journal/del.md", &b"desk keeps this"[..]), ("photos/p.jpg", &photo[..]), ("Journal/untouched.md", &b"goes when the desk deletes it"[..])],
    );
    let all = [&a, &c];
    keep_copies(&a, &ic, true);
    assert_eq!(peer(&c, &ia)["keep_copies"], false, "the switch is the Desk's own, never sent");

    // The Tablet edits, deletes, renames and adds.
    std::thread::sleep(Duration::from_millis(1100));
    put(&fc.join("Journal/entry.md"), b"tablet edit");
    std::fs::remove_file(fc.join("Journal/del.md")).unwrap();
    std::fs::rename(fc.join("photos/p.jpg"), fc.join("photos/p2.jpg")).unwrap();
    put(&fc.join("Journal/new.md"), b"tablet new");
    until("the Tablet's version beside the Desk's, and its new files", 120, &all, || {
        beside_holds(&fa.join("Journal"), "entry", ".md", "Tablet", false, b"tablet edit") && is(&fa.join("photos/p2.jpg"), &photo) && is(&fa.join("Journal/new.md"), b"tablet new")
    });
    more_rounds(&all, 3);
    assert!(is(&fa.join("Journal/entry.md"), b"desk v1"), "the Desk's entry was replaced: {:?}\n{}", std::fs::read(fa.join("Journal/entry.md")), logs(&all));
    assert!(is(&fa.join("Journal/del.md"), b"desk keeps this"), "the Desk's del.md was deleted\n{}", logs(&all));
    assert!(is(&fa.join("photos/p.jpg"), &photo), "the Desk's photo was renamed away");
    assert!(!any_conflict_copy(&fa.join("Journal")), "{:?}", names(&fa.join("Journal")));
    assert_eq!(pending(&a, &share), 0, "nothing waits: the copy is there, and nothing else is to come");
    assert!(!any_beside(&fc.join("Journal")), "the copy of the Tablet's own version never goes back to it: {:?}", names(&fc.join("Journal")));
    assert!(is(&fc.join("Journal/entry.md"), b"tablet edit") && !fc.join("Journal/del.md").exists() && !fc.join("photos/p.jpg").exists());

    // A second newer version: a second copy, with the time in its name; the first copy and the Desk's own stay as they are.
    std::thread::sleep(Duration::from_millis(1100));
    put(&fc.join("Journal/entry.md"), b"tablet edit 2");
    until("the second copy beside", 120, &all, || beside_holds(&fa.join("Journal"), "entry", ".md", "Tablet", true, b"tablet edit 2"));
    more_rounds(&all, 2);
    assert!(beside_holds(&fa.join("Journal"), "entry", ".md", "Tablet", false, b"tablet edit") && is(&fa.join("Journal/entry.md"), b"desk v1"), "{:?}", names(&fa.join("Journal")));
    assert_eq!(names(&fa.join("Journal")).iter().filter(|n| n.contains("(from Tablet")).count(), 2, "each version once: {:?}", names(&fa.join("Journal")));

    // The Desk's own changes still go to the Tablet as before: an edit of a file the Tablet changed arrives with the
    // Tablet's version kept as a conflict copy there, and a delete of a file it never touched is done.
    std::thread::sleep(Duration::from_millis(1100));
    put(&fa.join("Journal/entry.md"), b"desk v2");
    std::fs::remove_file(fa.join("Journal/untouched.md")).unwrap();
    until("the Desk's changes on the Tablet", 120, &all, || {
        is(&fc.join("Journal/entry.md"), b"desk v2") && copy_holds(&fc.join("Journal"), "entry", b"tablet edit 2") && !fc.join("Journal/untouched.md").exists()
    });
    more_rounds(&all, 2);
    assert!(is(&fa.join("Journal/entry.md"), b"desk v2") && is(&fa.join("Journal/del.md"), b"desk keeps this"));
    assert!(!any_beside(&fc.join("Journal")), "{:?}", names(&fc.join("Journal")));
    a.close();
    c.close();
}

#[test]
fn things_that_can_be_downloaded_again_are_not_taken_from_that_device_at_all() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fc) = (tmp.path().join("library-a"), tmp.path().join("library-c"));
    let zim: Vec<u8> = (0..1_500_000u32).map(|i| (i * 3 % 251) as u8).collect();
    let (a, c, _ia, ic, share) = two(tmp.path(), "library", &[("a.zim", &zim[..]), ("c.zim", &b"a small zim"[..]), ("a.zim.icon.png", &b"icon"[..])]);
    // A share the switch never touches (the settings log), linked the same way.
    let (sa, sc) = (tmp.path().join("settings-a"), tmp.path().join("settings-c"));
    put(&sa.join("log/desk.jsonl"), b"desk 1\n");
    std::fs::create_dir_all(&sc).unwrap();
    add(&a, &sa, "settings");
    join(&c, "settings", &sc, &[&a, &c]);
    until("the settings log on the Tablet", 90, &[&a, &c], || sc.join("log/desk.jsonl").exists());
    let all = [&a, &c];
    keep_copies(&a, &ic, true);

    std::thread::sleep(Duration::from_millis(1100));
    let newer: Vec<u8> = zim.iter().map(|b| b.wrapping_add(1)).collect();
    put(&fc.join("a.zim"), &newer);
    std::fs::remove_file(fc.join("c.zim")).unwrap();
    put(&fc.join("b.zim"), b"a new zim");
    put(&sc.join("log/tablet.jsonl"), b"tablet 1\n");
    until("the Tablet's changes indexed", 90, &all, || indexed(&c, &share, &["a.zim", "b.zim"], &["c.zim"]));
    until("the settings log from the Tablet, which the switch never touches", 90, &all, || is(&sa.join("log/tablet.jsonl"), b"tablet 1\n"));
    more_rounds(&all, 3);
    assert!(is(&fa.join("a.zim"), &zim), "the Desk's ZIM was replaced");
    assert!(is(&fa.join("c.zim"), b"a small zim"), "the Desk's ZIM was deleted");
    assert!(!fa.join("b.zim").exists(), "nothing of the Tablet's library comes: {:?}", names(&fa));
    assert!(!any_beside(&fa) && !any_conflict_copy(&fa), "no copies of downloadable things: {:?}", names(&fa));
    assert_eq!(pending(&a, &share), 0);
    a.close();
    c.close();
}

#[test]
fn with_the_switch_off_nothing_changes_and_switching_it_off_again_takes_what_waited() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fc) = (tmp.path().join("folder-a"), tmp.path().join("folder-c"));
    let big: Vec<u8> = (0..1_500_000u32).map(|i| (i * 11 % 251) as u8).collect();
    let p = pair(tmp.path(), &big);
    let all = [&p.a, &p.c];
    assert_eq!(peer(&p.a, &p.ic)["keep_copies"], false, "off unless switched on");
    // Off: the Tablet's edit, delete, rename and new file all reach the Desk, as on every link before.
    tablet_changes(&p, &fc);
    until("the Tablet's changes on the Desk", 120, &all, || {
        is(&fa.join("edit.txt"), b"tablet edit") && !fa.join("del.txt").exists() && !fa.join("ren.bin").exists() && is(&fa.join("renamed.bin"), &big) && is(&fa.join("new.txt"), b"tablet new")
    });

    // On: a later edit waits on the Tablet. Off again: it comes.
    keep_copies(&p.a, &p.ic, true);
    std::thread::sleep(Duration::from_millis(1100));
    put(&fc.join("edit.txt"), b"tablet edit 2");
    until("the second edit indexed", 90, &all, || {
        call(&p.c, "share_items", json!({"id": p.share}))["items"].as_array().unwrap().iter().any(|i| i["name"] == "edit.txt" && i["bytes"] == 13)
    });
    more_rounds(&all, 3);
    assert!(is(&fa.join("edit.txt"), b"tablet edit"), "with the switch on the second edit stays on the Tablet: {:?}", std::fs::read(fa.join("edit.txt")));
    keep_copies(&p.a, &p.ic, false);
    until("the second edit on the Desk once the switch is off", 90, &all, || is(&fa.join("edit.txt"), b"tablet edit 2"));
    more_rounds(&all, 2);
    assert!(!any_conflict_copy(&fa) && !any_conflict_copy(&fc), "A: {:?} C: {:?}", names(&fa), names(&fc));
    p.a.close();
    p.c.close();
}

#[test]
fn three_devices_a_matches_b_and_b_sends_to_c() {
    let tmp = tempfile::tempdir().unwrap();
    let t = tmp.path();
    let dirs = |share: &str| (t.join(format!("{share}-a")), t.join(format!("{share}-b")), t.join(format!("{share}-c")));
    // Notebooks (things the person made) and a library (things that can be downloaded again).
    let (na, nb, nc) = dirs("notebooks");
    let (la, lb, lc) = dirs("library");
    let zim: Vec<u8> = (0..1_200_000u32).map(|i| (i * 13 % 241) as u8).collect();
    let notes: [(&str, &[u8]); 4] = [("n.md", &b"v1"[..]), ("k.md", &b"keep me"[..]), ("g.md", &b"untouched"[..]), ("changed-then-deleted.md", &b"base"[..])];
    for (rel, data) in notes {
        put(&na.join(rel), data);
    }
    put(&la.join("z.zim"), &zim);
    for d in [&nb, &nc, &lb, &lc] {
        std::fs::create_dir_all(d).unwrap();
    }
    let a = engine(&t.join("a"), "Desk");
    let b = engine(&t.join("b"), "Hub");
    let c = engine(&t.join("c"), "Tablet");
    link(&a, &b);
    link(&b, &c);
    let (ia, ib, ic) = (id_of(&a), id_of(&b), id_of(&c));
    let all = [&a, &b, &c];
    // A and B: Match both ways, chosen on A. B and C: Send mine, chosen on B. On B, the switch for C.
    call(&a, "set_link", json!({"peer": ib, "link": {"mode": "match", "from": ia}}));
    call(&b, "set_link", json!({"peer": ic, "link": {"mode": "send", "from": ib}}));
    keep_copies(&b, &ic, true);
    for (id, fa, fb, fc) in [("notebooks", &na, &nb, &nc), ("library", &la, &lb, &lc)] {
        add(&a, fa, id);
        join(&b, id, fb, &all);
        join(&c, id, fc, &all);
    }
    let start = |n: &Path, l: &Path| notes.iter().all(|(rel, data)| is(&n.join(rel), data)) && is(&l.join("z.zim"), &zim);
    until("A's files on B and C", 120, &all, || start(&nb, &lb) && start(&nc, &lc));
    until("the links taken", 30, &all, || peer(&c, &ib)["link"]["mode"] == "send" && peer(&b, &ia)["link"]["mode"] == "match");

    // C edits, deletes and adds, in both.
    std::thread::sleep(Duration::from_millis(1100));
    put(&nc.join("n.md"), b"C's edit");
    std::fs::remove_file(nc.join("k.md")).unwrap();
    put(&nc.join("c-new.md"), b"from C");
    put(&nc.join("changed-then-deleted.md"), b"C changed this");
    let zc: Vec<u8> = zim.iter().map(|x| x.wrapping_add(1)).collect();
    put(&lc.join("z.zim"), &zc);
    put(&lc.join("c.zim"), b"C's zim");
    until("C's changes indexed", 90, &all, || indexed(&c, "library", &["z.zim", "c.zim"], &[]) && indexed(&c, "notebooks", &["c-new.md"], &["k.md"]));
    // B keeps its copies: C's newer notes arrive beside them, its new note comes, and through B all of that reaches A.
    until("C's notes beside B's and A's", 150, &all, || {
        [&nb, &na].iter().all(|d| beside_holds(d, "n", ".md", "Tablet", false, b"C's edit") && beside_holds(d, "changed-then-deleted", ".md", "Tablet", false, b"C changed this") && is(&d.join("c-new.md"), b"from C"))
    });
    more_rounds(&all, 3);
    for (who, n, l) in [("A", &na, &la), ("B", &nb, &lb)] {
        assert!(start(n, l), "{who}'s copies were replaced or removed: {:?} {:?}\n{}", names(n), names(l), logs(&all));
        assert!(!l.join("c.zim").exists() && !any_beside(l) && !any_conflict_copy(l), "nothing of C's library on {who}: {:?}", names(l));
        assert!(!any_conflict_copy(n), "{who}: {:?}", names(n));
    }
    assert!(!any_beside(&nc), "the copies of C's own versions never go back to C: {:?}", names(&nc));
    for id in ["notebooks", "library"] {
        assert_eq!(pending(&b, id), 0, "nothing waits on B in {id}");
    }

    // Now C keeps its copies from B too. A changes things in both: B takes them (Match); on C its newer note arrives beside
    // C's ("from Hub", the device it came from), its delete of a note C never touched leaves C's copy, its new note comes; of
    // the library nothing comes.
    keep_copies(&c, &ib, true);
    std::thread::sleep(Duration::from_millis(1100));
    put(&na.join("n.md"), b"A's edit");
    std::fs::remove_file(na.join("g.md")).unwrap();
    put(&na.join("a-new.md"), b"new from A");
    let za: Vec<u8> = zim.iter().map(|x| x.wrapping_add(2)).collect();
    put(&la.join("z.zim"), &za);
    put(&la.join("a-new.zim"), b"A's new zim");
    until("A's changes on B, and A's notes on C", 150, &all, || {
        is(&nb.join("n.md"), b"A's edit")
            && !nb.join("g.md").exists()
            && is(&nb.join("a-new.md"), b"new from A")
            && is(&lb.join("z.zim"), &za)
            && is(&lb.join("a-new.zim"), b"A's new zim")
            && beside_holds(&nc, "n", ".md", "Hub", false, b"A's edit")
            && is(&nc.join("a-new.md"), b"new from A")
    });
    more_rounds(&all, 3);
    assert!(is(&nc.join("n.md"), b"C's edit"), "C's note was replaced: {:?}\n{}", names(&nc), logs(&all));
    assert!(is(&nc.join("g.md"), b"untouched"), "A's delete removed C's copy through B");
    assert!(is(&nc.join("changed-then-deleted.md"), b"C changed this") && is(&nc.join("c-new.md"), b"from C") && !nc.join("k.md").exists(), "C keeps its own: {:?}", names(&nc));
    assert!(is(&lc.join("z.zim"), &zc) && is(&lc.join("c.zim"), b"C's zim") && !lc.join("a-new.zim").exists(), "nothing of B's library on C: {:?}", names(&lc));
    assert!(!any_beside(&lc) && !any_conflict_copy(&lc) && !any_conflict_copy(&nc), "C: {:?} {:?}", names(&nc), names(&lc));
    for (who, n, l) in [("A", &na, &la), ("B", &nb, &lb)] {
        assert!(is(&n.join("n.md"), b"A's edit") && is(&n.join("k.md"), b"keep me") && !n.join("g.md").exists() && is(&n.join("a-new.md"), b"new from A"), "{who}: {:?}", names(n));
        assert!(is(&l.join("z.zim"), &za) && is(&l.join("a-new.zim"), b"A's new zim") && !l.join("c.zim").exists(), "{who}: {:?}", names(l));
        assert!(!beside_holds(n, "n", ".md", "Hub", false, b"A's edit"), "C's copy of B's version never goes back: {who} {:?}", names(n));
    }
    a.close();
    b.close();
    c.close();
}
