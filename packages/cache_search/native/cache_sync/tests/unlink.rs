//! Unlinking tells the other device. A device that is unlinked here removes this one from its list; if it is off, the unlink waits
//! (saved in the same write that removes the device) and is delivered when it is back; it is dropped after 30 days; an old device
//! that has no such message is retried slowly; and nothing ever deletes a file.
//!
//! No relay, DHT or lookup service here: a device that restarts is found again only by one that still knows its address (so only
//! one restarts at a time), except in the one test that restarts both, which turns mDNS on.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    time::Duration,
};

fn engine_with(dir: &Path, name: &str, port: Option<u16>, mdns: bool) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": mdns, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "port": port,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn engine(dir: &Path, name: &str) -> SyncEngine {
    engine_with(dir, name, None, false)
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
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

/// Waits for `ok`, asking `devices` to sync about every 2 seconds (a round is what sends a waiting unlink).
fn wait_syncing(what: &str, secs: u64, devices: &[&SyncEngine], mut ok: impl FnMut() -> bool) {
    for i in 0..secs * 4 {
        if ok() {
            return;
        }
        if i % 8 == 0 {
            for d in devices {
                call(d, "sync_now", json!({}));
            }
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("timed out waiting for {what}");
}

fn status(e: &SyncEngine) -> Value {
    call(e, "status", json!({}))
}

fn log(e: &SyncEngine) -> String {
    status(e)["log"].to_string()
}

fn peers(e: &SyncEngine) -> Vec<Value> {
    status(e)["peers"].as_array().cloned().unwrap_or_default()
}

/// What is waiting to be told ("unlinks" in the status).
fn unlinks(e: &SyncEngine) -> Vec<Value> {
    status(e)["unlinks"].as_array().cloned().unwrap_or_default()
}

fn id_of(e: &SyncEngine) -> String {
    status(e)["id"].as_str().unwrap().to_string()
}

fn linked_pair(tmp: &Path, mdns: bool) -> (SyncEngine, SyncEngine, PathBuf, PathBuf) {
    let (da, db) = (tmp.join("a"), tmp.join("b"));
    let a = engine_with(&da, "Desk", None, mdns);
    let b = engine_with(&db, "Phone", None, mdns);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("the link on both", 30, || peers(&a).len() == 1 && peers(&b).len() == 1);
    (a, b, da, db)
}

/// Both unlink hooks of the core are files in the device's folder: the time an unlink is kept, and how often an old device is
/// tried again.
fn keep_ms(dir: &Path, ms: u64) {
    std::fs::write(dir.join("unlink-keep-ms"), ms.to_string()).unwrap();
}

fn old_retry_ms(dir: &Path, ms: u64) {
    std::fs::write(dir.join("unlink-old-retry-ms"), ms.to_string()).unwrap();
}

#[test]
fn both_online_the_entry_goes_and_the_files_stay() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _da, db) = linked_pair(tmp.path(), false);
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fa).unwrap();
    std::fs::write(fa.join("note.txt"), "from the desk").unwrap();
    let share = call(&a, "share_add", json!({"path": fa, "name": "Family"}))["id"].as_str().unwrap().to_string();
    wait_syncing("the offer on B", 30, &[&a, &b], || status(&b)["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    call(&b, "share_join", json!({"id": share, "path": fb}));
    wait_syncing("the file on B", 60, &[&a, &b], || fb.join("note.txt").exists());

    call(&a, "unlink", json!({"peer": id_of(&b)}));
    assert!(peers(&a).is_empty(), "gone from A at once");
    wait_syncing("B's entry gone", 60, &[&a, &b], || peers(&b).is_empty());
    wait_syncing("A's waiting unlink delivered", 60, &[&a, &b], || unlinks(&a).is_empty() && log(&a).contains("Phone was told it is unlinked."));
    assert!(log(&b).contains("Desk unlinked this device."), "{}", log(&b));
    // Nothing is deleted anywhere, and B's links file no longer lists A.
    assert_eq!(std::fs::read_to_string(fb.join("note.txt")).unwrap(), "from the desk");
    assert_eq!(std::fs::read_to_string(fa.join("note.txt")).unwrap(), "from the desk");
    assert!(std::fs::read_to_string(db.join("sync.json")).unwrap().contains("\"peers\":[]"));
    a.close();
    b.close();
}

#[test]
fn b_offline_then_back_is_told() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _da, db) = linked_pair(tmp.path(), false);
    let pb = b.port().unwrap();
    let bid = id_of(&b);
    b.close();
    call(&a, "unlink", json!({"peer": bid}));
    // Waiting: A shows it, with the name, and it is not an old device.
    wait("the waiting unlink", 10, || unlinks(&a).len() == 1);
    let u = unlinks(&a)[0].clone();
    assert_eq!(u["name"], "Phone", "{u}");
    assert!(u["old"] != json!(true), "{u}");
    assert!(peers(&a).is_empty());
    // B comes back (same port, so A still finds it) and is told.
    let b = engine_with(&db, "Phone", Some(pb), false);
    wait_syncing("B told", 90, &[&a, &b], || peers(&b).is_empty() && unlinks(&a).is_empty());
    assert!(log(&b).contains("Desk unlinked this device."), "{}", log(&b));
    assert!(log(&a).contains("Phone was told it is unlinked."), "{}", log(&a));
    a.close();
    b.close();
}

#[test]
fn a_restart_in_between_keeps_the_waiting_unlink() {
    let tmp = tempfile::tempdir().unwrap();
    // mDNS is on: both devices restart, and neither would find the other again by its address.
    let (a, b, da, db) = linked_pair(tmp.path(), true);
    let (pa, pb) = (a.port().unwrap(), b.port().unwrap());
    let bid = id_of(&b);
    b.close();
    call(&a, "unlink", json!({"peer": bid}));
    wait("the waiting unlink", 10, || unlinks(&a).len() == 1);
    // On disk in the same file that no longer lists B.
    let saved: Value = serde_json::from_str(&std::fs::read_to_string(da.join("sync.json")).unwrap()).unwrap();
    assert_eq!(saved["peers"], json!([]), "{saved}");
    assert_eq!(saved["unlinks"].as_array().map(|u| u.len()), Some(1), "{saved}");
    a.close();
    let a = engine_with(&da, "Desk", Some(pa), true);
    assert_eq!(unlinks(&a).len(), 1, "the waiting unlink survives a restart");
    let b = engine_with(&db, "Phone", Some(pb), true);
    wait_syncing("B told after A restarted", 120, &[&a, &b], || peers(&b).is_empty() && unlinks(&a).is_empty());
    a.close();
    b.close();
}

#[test]
fn both_unlink_at_once_and_both_clear() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _da, _db) = linked_pair(tmp.path(), false);
    // Neither may use the network until both have unlinked, so each one's message finds the other already unlinked.
    call(&a, "set_policy", json!({"network": false}));
    call(&b, "set_policy", json!({"network": false}));
    call(&a, "unlink", json!({"peer": id_of(&b)}));
    call(&b, "unlink", json!({"peer": id_of(&a)}));
    assert_eq!(unlinks(&a).len(), 1);
    assert_eq!(unlinks(&b).len(), 1);
    call(&a, "set_policy", json!({"network": true}));
    call(&b, "set_policy", json!({"network": true}));
    wait_syncing("both waiting unlinks cleared", 90, &[&a, &b], || unlinks(&a).is_empty() && unlinks(&b).is_empty());
    assert!(peers(&a).is_empty() && peers(&b).is_empty());
    a.close();
    b.close();
}

#[test]
fn a_link_made_again_before_the_unlink_arrives_stays() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _da, _db) = linked_pair(tmp.path(), false);
    call(&a, "set_policy", json!({"network": false}));
    call(&a, "unlink", json!({"peer": id_of(&b)}));
    assert_eq!(unlinks(&a).len(), 1);
    // B still lists A. The two link again before anything was sent: a new link, a new id.
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("the new link on both", 30, || peers(&a).len() == 1 && peers(&b).len() == 1);
    assert!(unlinks(&a).is_empty(), "linking again clears the waiting unlink");
    assert_eq!(peers(&a)[0]["link_id"], peers(&b)[0]["link_id"], "both hold the new link's id");
    assert!(peers(&a)[0]["link_id"].is_string());
    call(&a, "set_policy", json!({"network": true}));
    wait_syncing("a few rounds", 20, &[&a, &b], || status(&a)["rounds"].as_u64().unwrap_or(0) >= 3);
    assert_eq!(peers(&b).len(), 1, "{}", log(&b));
    assert_eq!(peers(&a).len(), 1);
    assert!(!log(&b).contains("unlinked this device"), "{}", log(&b));
    a.close();
    b.close();
}

#[test]
fn an_unlink_for_an_older_link_is_refused_as_stale() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _da, _db) = linked_pair(tmp.path(), false);
    // B now holds a different link than the one A is ending (as if the two had linked again and the message crossed it).
    call(&b, "test_set_link_id", json!({"peer": id_of(&a), "link_id": "ffffffffffffffffffffffffffffffff"}));
    call(&a, "set_policy", json!({"network": false}));
    call(&a, "unlink", json!({"peer": id_of(&b)}));
    call(&a, "set_policy", json!({"network": true}));
    wait_syncing("A's message answered", 60, &[&a, &b], || unlinks(&a).is_empty());
    // B changed nothing: it still lists A, and says nothing of an unlink.
    assert_eq!(peers(&b).len(), 1);
    assert!(!log(&b).contains("unlinked this device"), "{}", log(&b));
    a.close();
    b.close();
}

#[test]
fn a_link_with_no_id_is_unlinked_by_a_message_with_no_id_and_never_by_one_for_a_new_link() {
    let tmp = tempfile::tempdir().unwrap();
    // As links made before this version are: no id on either device.
    let (a, b, _da, _db) = linked_pair(tmp.path(), false);
    call(&a, "test_set_link_id", json!({"peer": id_of(&b), "link_id": null}));
    call(&b, "test_set_link_id", json!({"peer": id_of(&a), "link_id": null}));
    call(&a, "unlink", json!({"peer": id_of(&b)}));
    wait_syncing("the legacy link ended", 60, &[&a, &b], || peers(&b).is_empty() && unlinks(&a).is_empty());
    a.close();
    b.close();

    // An id-less message never ends a link that has an id.
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _da, _db) = linked_pair(tmp.path(), false);
    call(&a, "test_set_link_id", json!({"peer": id_of(&b), "link_id": null}));
    call(&a, "unlink", json!({"peer": id_of(&b)}));
    wait_syncing("the message answered", 60, &[&a, &b], || unlinks(&a).is_empty());
    assert_eq!(peers(&b).len(), 1, "{}", log(&b));
    a.close();
    b.close();
}

#[test]
fn a_link_the_other_device_never_learned_of_clears_the_waiting_unlink() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _da, _db) = linked_pair(tmp.path(), false);
    // The answer to the code never reached B: it holds no link at all (and says nothing to A about it).
    call(&b, "test_drop_peer", json!({"peer": id_of(&a)}));
    assert!(peers(&b).is_empty());
    call(&a, "unlink", json!({"peer": id_of(&b)}));
    wait_syncing("the waiting unlink cleared", 60, &[&a, &b], || unlinks(&a).is_empty());
    assert!(log(&a).contains("Phone was told it is unlinked."), "{}", log(&a));
    a.close();
    b.close();
}

#[test]
fn only_a_linked_device_can_unlink_and_only_itself() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, _da, _db) = linked_pair(tmp.path(), false);
    // A third device, linked to A as well.
    let c = engine(&tmp.path().join("c"), "Tablet");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&c, "link", json!({"code": code}));
    wait("C linked", 30, || peers(&a).len() == 2);

    // A stranger's key cannot even connect for it.
    let d = engine(&tmp.path().join("d"), "Stranger");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    let forged = d.call("test_unlink_message", &json!({"code": code, "link_id": null}));
    assert!(forged.is_err(), "a key that is not linked must be refused: {forged:?}");
    assert_eq!(peers(&a).len(), 2);

    // A linked device naming a link that is not its own changes nothing; naming its own removes only itself.
    let wrong = call(&b, "test_unlink_message", json!({"peer": id_of(&a), "link_id": "00000000000000000000000000000000"}));
    assert_eq!(wrong["done"], "stale", "{wrong}");
    assert_eq!(peers(&a).len(), 2);
    let own = peers(&b)[0]["link_id"].clone();
    let right = call(&b, "test_unlink_message", json!({"peer": id_of(&a), "link_id": own}));
    assert_eq!(right["done"], "unlinked", "{right}");
    let left: Vec<String> = peers(&a).iter().map(|p| p["name"].as_str().unwrap_or("").to_string()).collect();
    assert_eq!(left, vec!["Tablet".to_string()], "only the sender goes");
    a.close();
    b.close();
    c.close();
    d.close();
}

#[test]
fn a_lost_links_file_on_one_device_never_unlinks_the_other() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, da, _db) = linked_pair(tmp.path(), false);
    let pa = a.port().unwrap();
    a.close();
    // The links file and its good copy are both gone.
    let _ = std::fs::remove_file(da.join("sync.json"));
    let _ = std::fs::remove_file(da.join("sync.json.bak"));
    let a = engine_with(&da, "Desk", Some(pa), false);
    assert!(peers(&a).is_empty());
    wait_syncing("several rounds on both", 40, &[&a, &b], || status(&b)["rounds"].as_u64().unwrap_or(0) >= 4);
    assert!(unlinks(&a).is_empty(), "nothing is waiting to be sent");
    assert_eq!(peers(&b).len(), 1, "B keeps its link: a refusal is never an unlink; {}", log(&b));
    assert!(!log(&b).contains("unlinked this device"));
    a.close();
    b.close();
}

#[test]
fn an_unlink_not_delivered_in_time_is_dropped_and_the_other_device_keeps_its_link() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, da, db) = linked_pair(tmp.path(), false);
    let pb = b.port().unwrap();
    let bid = id_of(&b);
    b.close();
    // The keep time is three seconds here (thirty days really).
    keep_ms(&da, 3000);
    call(&a, "unlink", json!({"peer": bid}));
    wait("the unlink dropped", 90, || {
        call(&a, "sync_now", json!({}));
        unlinks(&a).is_empty() && log(&a).contains("Phone was not reached within 30 days; it may still show this device.")
    });
    let saved = std::fs::read_to_string(da.join("sync.json")).unwrap();
    assert!(!saved.contains("unlinks"), "{saved}");
    // B is back and was never told: it keeps its link (shown as not reachable, to be unlinked there by hand).
    let b = engine_with(&db, "Phone", Some(pb), false);
    wait_syncing("several rounds on B", 40, &[&a, &b], || status(&b)["rounds"].as_u64().unwrap_or(0) >= 3);
    assert_eq!(peers(&b).len(), 1, "{}", log(&b));
    assert!(!log(&b).contains("unlinked this device"));
    a.close();
    b.close();
}

#[test]
fn an_old_device_gets_no_change_and_is_tried_again_slowly() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    // B plays an old version: it does not answer the new message at all.
    std::fs::create_dir_all(&db).unwrap();
    std::fs::write(db.join("no-unlink-alpn"), b"").unwrap();
    let a = engine(&da, "Desk");
    let b = engine(&db, "Phone");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    wait("the link on both", 30, || peers(&a).len() == 1 && peers(&b).len() == 1);
    let before = peers(&b)[0].clone();
    // Six hours between tries (the default); this device does not wait for them.
    call(&a, "unlink", json!({"peer": id_of(&b)}));
    wait_syncing("A to find B an old device", 90, &[&a, &b], || unlinks(&a).first().map(|u| u["old"] == json!(true)).unwrap_or(false));
    let tries = unlinks(&a)[0]["tries"].as_u64().unwrap_or(0);
    // Rounds on both, and B asking A again and again (each a refused knock): no new try on a six-hour wait.
    wait_syncing("several rounds", 40, &[&a, &b], || status(&a)["rounds"].as_u64().unwrap_or(0) >= 4 && status(&b)["rounds"].as_u64().unwrap_or(0) >= 4);
    assert_eq!(unlinks(&a)[0]["tries"].as_u64().unwrap_or(0), tries, "an old device is not tried every round");
    // B changed nothing: the same link, nothing said about an unlink.
    assert_eq!(peers(&b).len(), 1, "{}", log(&b));
    assert_eq!(peers(&b)[0]["id"], before["id"]);
    assert_eq!(peers(&b)[0]["link_id"], before["link_id"]);
    assert!(!log(&b).contains("unlinked this device"));
    // With a short wait it is tried again, and the waiting unlink is still there.
    old_retry_ms(&da, 1000);
    wait_syncing("another try", 60, &[&a, &b], || unlinks(&a).first().map(|u| u["tries"].as_u64().unwrap_or(0) > tries).unwrap_or(false));
    assert_eq!(unlinks(&a)[0]["old"], json!(true));
    a.close();
    b.close();
}

#[test]
fn an_unlink_during_a_round_applies_nothing_more_from_that_peer() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b, da, _db) = linked_pair(tmp.path(), false);
    let (fa, fb) = (tmp.path().join("folder-a"), tmp.path().join("folder-b"));
    std::fs::create_dir_all(&fb).unwrap();
    std::fs::write(fb.join("first.txt"), "first").unwrap();
    let share = call(&b, "share_add", json!({"path": fb, "name": "Family"}))["id"].as_str().unwrap().to_string();
    wait_syncing("the offer on A", 30, &[&a, &b], || status(&a)["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false));
    call(&a, "share_join", json!({"id": share, "path": fa}));
    wait_syncing("the first file on A", 60, &[&a, &b], || fa.join("first.txt").exists());
    // A new file on B; A's next round has its index and is held before it applies anything.
    std::thread::sleep(Duration::from_millis(1100));
    std::fs::write(fb.join("second.txt"), "second").unwrap();
    call(&b, "sync_now", json!({}));
    std::fs::write(da.join("hold-apply"), b"").unwrap();
    wait("A's round held before it applies", 60, || {
        call(&a, "sync_now", json!({}));
        da.join("hold-apply.held").exists()
    });
    call(&a, "unlink", json!({"peer": id_of(&b)}));
    std::fs::remove_file(da.join("hold-apply")).unwrap();
    wait_syncing("a few more rounds on A", 30, &[&a], || status(&a)["rounds"].as_u64().unwrap_or(0) >= 3);
    assert!(!fa.join("second.txt").exists(), "nothing more comes from a device that was unlinked meanwhile");
    assert!(!log(&a).contains("second.txt"), "{}", log(&a));
    assert!(fa.join("first.txt").exists(), "nothing already here is touched");
    a.close();
    b.close();
}

#[test]
fn the_clean_up_of_an_unconfirmed_link_tells_the_other_device_too() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let folder = tmp.path().join("folder");
    std::fs::create_dir_all(&folder).unwrap();
    std::fs::write(folder.join("note.txt"), "note").unwrap();
    let a = engine(&da, "Desk");
    let b = engine(&db, "Phone");
    // The wait for a confirmation is two seconds here; A's round is held, and B may not use the network, so B asks A for nothing.
    std::fs::write(da.join("confirm-window-ms"), "2000").unwrap();
    std::fs::write(da.join("hold-rescan"), b"").unwrap();
    call(&a, "share_add", json!({"path": folder, "name": "Family"}));
    wait("A's round held", 60, || da.join("hold-rescan.held").exists());
    call(&b, "set_policy", json!({"network": false}));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    assert_eq!(peers(&a)[0]["unconfirmed"], true);
    assert_eq!(peers(&b).len(), 1);
    std::fs::remove_file(da.join("hold-rescan")).unwrap();
    // A removes the link it never saw confirmed, and B (which still holds it) is told, so it goes from B's list too.
    wait_syncing("A's clean-up and B told", 180, &[&a], || peers(&a).is_empty() && peers(&b).is_empty());
    wait_syncing("A's waiting unlink delivered", 60, &[&a], || unlinks(&a).is_empty());
    assert!(log(&a).contains("Phone did not finish linking with this device"), "{}", log(&a));
    assert!(log(&b).contains("Desk unlinked this device."), "{}", log(&b));
    a.close();
    b.close();
}
