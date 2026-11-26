//! The engine's identity options: `make_identity: false` (a phone's background round) never makes a new identity, and
//! `identity_keep` (Cache on Linux's `<data>/identity-keep`) brings back a key that went missing from the sync folder.

use cache_sync::identity::KEY_FILE;
use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};

fn cfg(extra: Value) -> Config {
    let mut v = json!({"name": "Phone", "relay": false, "dht": false, "mdns": false, "lookup": false, "interval_secs": 5, "reserve_bytes": 0});
    v.as_object_mut().unwrap().extend(extra.as_object().unwrap().clone());
    serde_json::from_value(v).unwrap()
}

fn id_of(e: &SyncEngine) -> String {
    e.call("status", &json!({})).unwrap()["id"].as_str().unwrap().to_string()
}

#[test]
fn with_make_identity_off_an_open_with_no_key_fails_and_makes_none() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("sync");
    let e = SyncEngine::open(cfg(json!({"dir": dir, "make_identity": false}))).err().expect("no identity may be made");
    assert!(format!("{e:#}").contains("Can't read this device's identity"), "{e:#}");
    assert!(!dir.join(KEY_FILE).exists());
}

#[test]
fn a_key_gone_from_the_sync_folder_comes_back_from_identity_keep() {
    let tmp = tempfile::tempdir().unwrap();
    let (dir, keep) = (tmp.path().join("sync"), tmp.path().join("identity-keep"));
    let c = || cfg(json!({"dir": dir, "identity_keep": keep}));
    let e = SyncEngine::open(c()).unwrap();
    let id = id_of(&e);
    e.close();
    assert!(keep.join(KEY_FILE).exists(), "the copy is written at the open");
    std::fs::remove_file(dir.join(KEY_FILE)).unwrap();
    let e = SyncEngine::open(c()).unwrap();
    assert_eq!(id_of(&e), id, "the same device");
    e.close();
}
