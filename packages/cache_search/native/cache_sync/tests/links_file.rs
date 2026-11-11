//! The file that holds the links and shares (`sync.json`): a damaged one never costs the links when a good copy exists, is
//! never deleted or overwritten, and one that cannot be read at all stops the start instead of being saved over.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::path::Path;

const GARBAGE: &[u8] = b"{\"name\": \"Phone\", \"peers\": [{\"id";

fn config(dir: &Path, name: &str) -> Config {
    serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0,
    }))
    .unwrap()
}

fn engine(dir: &Path, name: &str) -> SyncEngine {
    SyncEngine::open(config(dir, name)).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn log(e: &SyncEngine) -> String {
    call(e, "status", json!({}))["log"].to_string()
}

/// How many linked devices and shares the status shows.
fn counts(e: &SyncEngine) -> (usize, usize) {
    let st = call(e, "status", json!({}));
    (st["peers"].as_array().map(|p| p.len()).unwrap_or(0), st["shares"].as_array().map(|s| s.len()).unwrap_or(0))
}

fn parsed(p: &Path) -> Option<Value> {
    serde_json::from_slice(&std::fs::read(p).ok()?).ok()
}

#[test]
fn a_damaged_links_file_with_a_good_copy_keeps_the_links() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let folder = tmp.path().join("folder");
    std::fs::create_dir_all(&folder).unwrap();
    let a = engine(&da, "Desk");
    let b = engine(&db, "Phone");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&b, "share_add", json!({"path": folder, "name": "Notebooks", "id": "nb1"}));
    assert_eq!(counts(&b), (1, 1));
    b.close();
    a.close();

    // The file as last saved is the good copy; the file itself is cut off half way.
    let saved = parsed(&db.join("sync.json")).expect("the links file parses");
    assert_eq!((saved["peers"].as_array().unwrap().len(), saved["shares"].as_array().unwrap().len()), (1, 1), "{saved}");
    std::fs::copy(db.join("sync.json"), db.join("sync.json.bak")).unwrap();
    std::fs::write(db.join("sync.json"), GARBAGE).unwrap();

    let b = engine(&db, "Phone");
    assert_eq!(counts(&b), (1, 1), "the link and the share are still there");
    assert!(log(&b).contains("restored from the last good copy"), "{}", log(&b));
    assert_eq!(std::fs::read(db.join("sync.json.damaged")).unwrap(), GARBAGE, "the damaged file is kept aside");
    let now = parsed(&db.join("sync.json")).expect("the links file parses again");
    assert_eq!(now["peers"].as_array().unwrap().len(), 1);
    b.close();
}

#[test]
fn a_damaged_links_file_with_no_good_copy_starts_empty_and_is_kept() {
    let tmp = tempfile::tempdir().unwrap();
    let da = tmp.path().join("a");
    let folder = tmp.path().join("folder");
    std::fs::create_dir_all(&folder).unwrap();
    let a = engine(&da, "Desk");
    call(&a, "share_add", json!({"path": folder, "name": "Notebooks", "id": "nb1"}));
    a.close();
    let _ = std::fs::remove_file(da.join("sync.json.bak"));
    std::fs::write(da.join("sync.json"), GARBAGE).unwrap();

    let a = engine(&da, "Desk");
    assert_eq!(counts(&a), (0, 0));
    assert!(log(&a).contains("there was no good copy"), "{}", log(&a));
    assert_eq!(std::fs::read(da.join("sync.json.damaged")).unwrap(), GARBAGE, "the damaged file is kept aside, not overwritten");
    assert!(parsed(&da.join("sync.json")).is_some(), "a new links file was written");
    a.close();

    // Damaged a second time: the first damaged file is still there, beside the new one.
    std::fs::remove_file(da.join("sync.json.bak")).ok();
    std::fs::write(da.join("sync.json"), b"again").unwrap();
    let a = engine(&da, "Desk");
    a.close();
    assert_eq!(std::fs::read(da.join("sync.json.damaged")).unwrap(), GARBAGE);
    let kept: Vec<String> = std::fs::read_dir(&da).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).filter(|n| n.starts_with("sync.json.damaged.")).collect();
    assert_eq!(kept.len(), 1, "{kept:?}");
    assert_eq!(std::fs::read(da.join(&kept[0])).unwrap(), b"again");
}

#[test]
fn a_missing_links_file_is_a_fresh_start_and_each_save_keeps_the_one_before() {
    let tmp = tempfile::tempdir().unwrap();
    let da = tmp.path().join("a");
    let folder = tmp.path().join("folder");
    std::fs::create_dir_all(&folder).unwrap();
    let a = engine(&da, "Desk");
    assert_eq!(counts(&a), (0, 0));
    assert!(!log(&a).contains("could not be read"), "{}", log(&a));
    assert!(parsed(&da.join("sync.json")).is_some());
    assert!(!da.join("sync.json.damaged").exists());

    // The next save keeps the file it replaces: the copy is the one from before the share.
    call(&a, "share_add", json!({"path": folder, "name": "Notebooks", "id": "nb1"}));
    let bak = parsed(&da.join("sync.json.bak")).expect("the copy parses");
    assert!(bak["shares"].as_array().map(|s| s.is_empty()).unwrap_or(true), "{bak}");
    let now = parsed(&da.join("sync.json")).unwrap();
    assert_eq!(now["shares"].as_array().unwrap().len(), 1);
    a.close();
}

#[test]
fn a_links_file_that_cannot_be_read_stops_the_start_and_is_left_alone() {
    let tmp = tempfile::tempdir().unwrap();
    let da = tmp.path().join("a");
    // There, but not readable as a file (a folder in its place): reading it fails with something other than "not found".
    std::fs::create_dir_all(da.join("sync.json")).unwrap();
    assert!(SyncEngine::open(config(&da, "Desk")).is_err());
    assert!(da.join("sync.json").is_dir(), "nothing was written over it");
    assert!(!da.join("sync.json.bak").exists() && !da.join("sync.json.damaged").exists());
}
