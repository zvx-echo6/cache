//! What two linked devices keep about their link (`set_link`: the device it is set on is where it comes from, and the other
//! takes it), shares kept only with some links (`with`, `set_share_with`: the Bookshelves log with Match devices only, the
//! settings log with Match and Send mine), and secrets for one device (`set_secrets`, `take_secrets`): sent only to that
//! device, only when asked, and never written to disk.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str, with: Value) -> SyncEngine {
    let cfg = json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "with": with,
    });
    SyncEngine::open(serde_json::from_value::<Config>(cfg).unwrap()).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn status(e: &SyncEngine) -> Value {
    call(e, "status", json!({}))
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
    panic!("timed out waiting for {what}\n{}", all.iter().map(|e| status(e)["log"].to_string()).collect::<Vec<_>>().join("\n"));
}

fn rounds(all: &[&SyncEngine]) {
    std::thread::sleep(Duration::from_secs(6));
    for _ in 0..3 {
        for e in all {
            call(e, "sync_now", json!({}));
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

fn write(p: &Path, text: &str) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

fn link(a: &SyncEngine, b: &SyncEngine) {
    let code = call(a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(b, "link", json!({"code": code}));
}

fn id(e: &SyncEngine) -> String {
    status(e)["id"].as_str().unwrap().to_string()
}

fn peer(e: &SyncEngine, of: &str) -> Value {
    status(e)["peers"].as_array().unwrap().iter().find(|p| p["id"] == of).cloned().unwrap_or(Value::Null)
}

/// Every file under `dir` holds no `needle`.
fn nowhere(dir: &Path, needle: &str) -> bool {
    let mut stack = vec![dir.to_path_buf()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap().flatten() {
            let p = e.path();
            if p.is_dir() {
                stack.push(p);
            } else if let Ok(bytes) = std::fs::read(&p) {
                if bytes.windows(needle.len()).any(|w| w == needle.as_bytes()) {
                    return false;
                }
            }
        }
    }
    true
}

#[test]
fn a_link_set_on_one_device_is_taken_by_the_other_and_gates_the_shares_kept_with_it() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb) = (tmp.path().join("shelves-a"), tmp.path().join("shelves-b"));
    let (sa, sb) = (tmp.path().join("settings-a"), tmp.path().join("settings-b"));
    write(&fa.join("log/a.jsonl"), "shelf from A\n");
    write(&fb.join("log/b.jsonl"), "shelf from B\n");
    let with = json!({"bookshelves": ["match"], "settings": ["match", "send"]});
    let a = engine(&tmp.path().join("a"), "Desk", with.clone());
    let b = engine(&tmp.path().join("b"), "Phone", with);
    link(&a, &b);
    let (ia, ib) = (id(&a), id(&b));
    for (e, f, s) in [(&a, &fa, &sa), (&b, &fb, &sb)] {
        call(e, "share_add", json!({"id": "bookshelves", "name": "Bookshelves", "path": f}));
        std::fs::create_dir_all(s).unwrap();
        call(e, "share_add", json!({"id": "settings", "name": "Settings", "path": s}));
    }
    // A new link is Off on both devices from the moment it exists, waiting for the person's answer.
    for (e, other) in [(&a, &ib), (&b, &ia)] {
        assert_eq!(peer(e, other)["link"], json!({"mode": "off", "ask": true}), "a new link starts Off");
    }

    // Answered Both ways on A: the Bookshelves log goes both ways.
    call(&a, "set_link", json!({"peer": ib, "link": {"mode": "match", "from": ia}}));
    until("each Bookshelves log on the other device", 60, &[&a, &b], || fb.join("log/a.jsonl").exists() && fa.join("log/b.jsonl").exists());
    until("each knows the other keeps links", 30, &[&a, &b], || peer(&a, &ib)["link_known"] == true && peer(&b, &ia)["link_known"] == true);

    // Send mine, chosen on A: B takes it, and the Bookshelves log stops; the settings log still goes.
    let r = call(&a, "set_link", json!({"peer": ib, "link": {"mode": "send", "from": ia}}));
    assert!(r["t"].as_u64().unwrap() > 0);
    until("B takes A's link", 30, &[&a, &b], || peer(&b, &ia)["link"]["mode"] == "send");
    assert_eq!(peer(&b, &ia)["link"]["from"], ia.as_str(), "the device it was chosen on is where settings come from");
    assert_eq!(peer(&b, &ia)["link_t"], peer(&a, &ib)["link_t"]);
    write(&fa.join("log/a2.jsonl"), "after send mine\n");
    write(&sa.join("log/a.jsonl"), "settings from A\n");
    until("A's settings log on B", 60, &[&a, &b], || sb.join("log/a.jsonl").exists());
    rounds(&[&a, &b]);
    assert!(!fb.join("log/a2.jsonl").exists(), "the Bookshelves log is kept with Match devices only");
    let st = status(&b);
    let shelves = st["shares"].as_array().unwrap().iter().find(|s| s["id"] == "bookshelves").unwrap().clone();
    assert_eq!(shelves["pending_files"], 0, "nothing waits from a device it is not kept with: {shelves}");
    assert_eq!(shelves["with"], json!(["match"]));

    // Changed later on B (Match): A takes it, and the Bookshelves log comes again.
    std::thread::sleep(Duration::from_millis(5));
    call(&b, "set_link", json!({"peer": ia, "link": {"mode": "match", "from": ib}}));
    until("A takes B's later link", 30, &[&a, &b], || peer(&a, &ib)["link"]["mode"] == "match");
    until("the Bookshelves log again", 60, &[&a, &b], || fb.join("log/a2.jsonl").exists());

    // Off: neither goes.
    call(&a, "set_link", json!({"peer": ib, "link": {"mode": "off", "from": ia}}));
    until("B takes Off", 30, &[&a, &b], || peer(&b, &ia)["link"]["mode"] == "off");
    write(&sa.join("log/a.jsonl"), "settings from A\nmore\n");
    write(&fa.join("log/a3.jsonl"), "after off\n");
    rounds(&[&a, &b]);
    assert_eq!(std::fs::read_to_string(sb.join("log/a.jsonl")).unwrap(), "settings from A\n", "Off keeps the settings log here");
    assert!(!fb.join("log/a3.jsonl").exists());

    // The list replaced later: the settings share goes everywhere again.
    call(&a, "set_share_with", json!({"id": "settings", "with": null}));
    call(&b, "set_share_with", json!({"id": "settings", "with": null}));
    until("the settings log with no list", 60, &[&a, &b], || std::fs::read_to_string(sb.join("log/a.jsonl")).unwrap().contains("more"));
    a.close();
    b.close();
}

#[test]
fn secrets_go_only_to_the_device_they_are_for_and_never_to_disk() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db, dc) = (tmp.path().join("a"), tmp.path().join("b"), tmp.path().join("c"));
    let a = engine(&da, "Desk", json!({}));
    let b = engine(&db, "Phone", json!({}));
    let c = engine(&dc, "Tablet", json!({}));
    link(&a, &b);
    link(&a, &c);
    let ib = id(&b);
    let ia = id(&a);
    let key = "SECRET-KEY-0123456789abcdef";
    call(&a, "set_secrets", json!({"peer": ib, "secrets": {"live.key.owm": key}}));
    let mut got = Value::Null;
    until("B gets its key", 60, &[&a, &b, &c], || {
        let t = call(&b, "take_secrets", json!({}));
        if t["secrets"][&ia].is_object() {
            got = t["secrets"][&ia].clone();
            return true;
        }
        false
    });
    assert_eq!(got, json!({"live.key.owm": key}));
    assert_eq!(call(&b, "take_secrets", json!({}))["secrets"], json!({}), "handed over once");
    rounds(&[&a, &b, &c]);
    assert_eq!(call(&b, "take_secrets", json!({}))["secrets"], json!({}), "not asked for again while unchanged");
    assert_eq!(call(&c, "take_secrets", json!({}))["secrets"], json!({}), "a device the key is not for never gets it");
    // A change is sent again.
    call(&a, "set_secrets", json!({"peer": ib, "secrets": {"live.key.owm": key, "search.kagi.key": "SECOND-SECRET-42"}}));
    until("B gets the changed keys", 60, &[&a, &b], || call(&b, "take_secrets", json!({}))["secrets"][&ia]["search.kagi.key"] == "SECOND-SECRET-42");
    assert!(a.call("set_secrets", &json!({"peer": "nobody", "secrets": {"k": "v"}})).is_err(), "only for a linked device");
    a.close();
    b.close();
    c.close();
    for d in [&da, &db, &dc] {
        assert!(nowhere(d, key), "a key is never written to disk ({})", d.display());
        assert!(nowhere(d, "SECOND-SECRET-42"), "a key is never written to disk ({})", d.display());
    }
}

#[test]
fn a_fresh_link_sends_nothing_from_the_shares_kept_with_some_links_before_a_mode_is_set() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb) = (tmp.path().join("shelves-a"), tmp.path().join("shelves-b"));
    let (sa, sb) = (tmp.path().join("settings-a"), tmp.path().join("settings-b"));
    let (pa, pb) = (tmp.path().join("plain-a"), tmp.path().join("plain-b"));
    write(&fa.join("log/a.jsonl"), "shelf from A\n");
    write(&fb.join("log/b.jsonl"), "shelf from B\n");
    write(&sa.join("log/a.jsonl"), "settings from A\n");
    write(&sb.join("log/b.jsonl"), "settings from B\n");
    write(&pa.join("a.txt"), "plain from A\n");
    std::fs::create_dir_all(&pb).unwrap();
    let with = json!({"bookshelves": ["match"], "settings": ["match", "send"]});
    let a = engine(&tmp.path().join("a"), "Desk", with.clone());
    let b = engine(&tmp.path().join("b"), "Phone", with);
    // The shares are there before the link, so the first round after it could send them.
    for (e, f, s, p) in [(&a, &fa, &sa, &pa), (&b, &fb, &sb, &pb)] {
        call(e, "share_add", json!({"id": "bookshelves", "name": "Bookshelves", "path": f}));
        call(e, "share_add", json!({"id": "settings", "name": "Settings", "path": s}));
        call(e, "share_add", json!({"id": "plain", "name": "Plain", "path": p}));
    }
    link(&a, &b);
    let (ia, ib) = (id(&a), id(&b));
    assert_eq!(peer(&a, &ib)["link"]["mode"], "off");
    assert_eq!(peer(&b, &ia)["link"]["mode"], "off");

    // A share kept with every device goes: the two are talking.
    until("the plain share on B", 60, &[&a, &b], || pb.join("a.txt").exists());
    rounds(&[&a, &b]);
    for (what, p) in [
        ("A's Bookshelves log on B", fb.join("log/a.jsonl")),
        ("B's Bookshelves log on A", fa.join("log/b.jsonl")),
        ("A's settings log on B", sb.join("log/a.jsonl")),
        ("B's settings log on A", sa.join("log/b.jsonl")),
    ] {
        assert!(!p.exists(), "{what}: nothing goes before a mode is set");
    }
    for (e, other) in [(&a, &ib), (&b, &ia)] {
        let offers = status(e)["offers"].as_array().unwrap().clone();
        assert!(
            offers.iter().all(|o| o["peer"] != other.as_str() || (o["id"] != "bookshelves" && o["id"] != "settings")),
            "nothing is offered from them either: {offers:?}"
        );
    }

    // Send mine on A: the settings log goes from A; the Bookshelves log still stays.
    call(&a, "set_link", json!({"peer": ib, "link": {"mode": "send", "from": ia}}));
    until("A's settings log on B", 60, &[&a, &b], || sb.join("log/a.jsonl").exists());
    assert!(!fb.join("log/a.jsonl").exists());
    a.close();
    b.close();
}

#[test]
fn links_made_before_new_links_started_off_become_match_once() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("a");
    std::fs::create_dir_all(&dir).unwrap();
    // As an earlier version left it: two links with no kind, and one set to Off.
    let old = json!({
        "name": "Desk",
        "peers": [
            {"id": "old-one", "name": "Phone", "linked": 1},
            {"id": "old-two", "name": "Tablet", "linked": 2},
            {"id": "old-off", "name": "Laptop", "linked": 3, "link": {"v": {"mode": "off", "from": "x"}, "t": 5}},
        ],
        "shares": [],
    });
    std::fs::write(dir.join("sync.json"), serde_json::to_vec(&old).unwrap()).unwrap();
    let a = engine(&dir, "Desk", json!({}));
    assert_eq!(peer(&a, "old-one")["link"], json!({"mode": "match"}));
    assert_eq!(peer(&a, "old-two")["link"], json!({"mode": "match"}));
    assert_eq!(peer(&a, "old-off")["link"], json!({"mode": "off", "from": "x"}), "a link already set is kept");
    a.close();
    let saved: Value = serde_json::from_slice(&std::fs::read(dir.join("sync.json")).unwrap()).unwrap();
    assert_eq!(saved["links_migrated"], true);

    // It never runs again: a link with no kind written in later (as only an older version would) stays as it is.
    let mut again = saved.clone();
    again["peers"].as_array_mut().unwrap().push(json!({"id": "later", "name": "Watch", "linked": 9}));
    std::fs::write(dir.join("sync.json"), serde_json::to_vec(&again).unwrap()).unwrap();
    let a = engine(&dir, "Desk", json!({}));
    assert_eq!(peer(&a, "later")["link"], Value::Null, "the migration ran once");
    assert_eq!(peer(&a, "old-one")["link"], json!({"mode": "match"}));
    a.close();
}

#[test]
fn the_first_answer_to_the_link_question_is_the_pairs_and_a_late_one_does_not_undo_it() {
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let (a, b) = (engine(da.path(), "Tablet", json!({})), engine(db.path(), "Pixel", json!({})));
    link(&a, &b);
    let (ia, ib) = (id(&a), id(&b));
    // Both answer before either hears the other: a sends (earlier), b answers Off (later, and stamped later).
    let from_a = json!({"mode": "send", "from": ia, "by": ia, "at": 1000});
    let from_b = json!({"mode": "off", "from": ib, "by": ib, "at": 2000});
    call(&a, "set_link", json!({"peer": ib, "link": from_a}));
    std::thread::sleep(Duration::from_millis(20));
    call(&b, "set_link", json!({"peer": ia, "link": from_b}));
    rounds(&[&a, &b]);
    for (e, other) in [(&a, &ib), (&b, &ia)] {
        let link = peer(e, other)["link"].clone();
        assert_eq!((link["mode"].as_str(), link["from"].as_str()), (Some("send"), Some(ia.as_str())), "{link}");
    }
}
