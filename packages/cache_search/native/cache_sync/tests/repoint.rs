//! A share's folder moves (the app's container path changes after an update): the same share id is added again with the new
//! path and is re-pointed. Its first scan never records deletes, and a folder that is missing is never scanned as empty.

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

fn wait(what: &str, secs: u64, mut ok: impl FnMut() -> bool) {
    for _ in 0..secs * 4 {
        if ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("timed out waiting for {what}");
}

fn log(e: &SyncEngine) -> String {
    call(e, "status", json!({}))["log"].to_string()
}

fn share_path(e: &SyncEngine, id: &str) -> String {
    let st = call(e, "status", json!({}));
    st["shares"].as_array().unwrap().iter().find(|s| s["id"] == id).unwrap()["path"].as_str().unwrap().to_string()
}

/// The deletes in a share's stored index on `dir`.
fn deletes(dir: &Path, id: &str) -> Vec<String> {
    let idx: Value = serde_json::from_slice(&std::fs::read(dir.join("index").join(format!("{id}.json"))).unwrap()).unwrap();
    idx["files"].as_object().unwrap().iter().filter(|(_, e)| e["deleted"] == true).map(|(p, _)| p.clone()).collect()
}

fn put(p: &Path, text: &str) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

#[test]
fn same_id_repoints_the_same_folder_under_another_id_is_refused() {
    let tmp = tempfile::tempdir().unwrap();
    let a = engine(&tmp.path().join("a"), "Desk");
    let (f1, f2, f3) = (tmp.path().join("one"), tmp.path().join("two"), tmp.path().join("three"));
    for f in [&f1, &f2, &f3] {
        std::fs::create_dir_all(f).unwrap();
    }
    call(&a, "share_add", json!({"path": f1, "name": "Notebooks", "id": "nb1"}));
    // Another id on a folder already shared: refused.
    assert!(a.call("share_add", &json!({"path": f1, "name": "Other", "id": "nb2"})).is_err());
    // The same id on the same path: nothing to do.
    call(&a, "share_add", json!({"path": f1, "name": "Notebooks", "id": "nb1"}));
    // The same id on a new path: re-pointed, name kept, one plain line in the activity.
    call(&a, "share_add", json!({"path": f2, "name": "Renamed", "id": "nb1"}));
    let st = call(&a, "status", json!({}));
    assert_eq!(st["shares"].as_array().unwrap().len(), 1);
    assert_eq!(st["shares"][0]["name"], "Notebooks");
    assert_eq!(share_path(&a, "nb1"), f2.to_string_lossy());
    assert!(log(&a).contains("Notebooks: folder moved after an update; checking files"), "{}", log(&a));
    // A folder already used by another share is still refused for a re-point.
    call(&a, "share_add", json!({"path": f3, "name": "Second", "id": "nb3"}));
    assert!(a.call("share_add", &json!({"path": f3, "name": "Notebooks", "id": "nb1"})).is_err());
    assert_eq!(share_path(&a, "nb1"), f2.to_string_lossy());
    a.close();
}

#[test]
fn a_missing_folder_is_an_error_and_never_scanned_as_empty() {
    let tmp = tempfile::tempdir().unwrap();
    let da = tmp.path().join("a");
    let a = engine(&da, "Desk");
    let f = tmp.path().join("folder");
    put(&f.join("keep.txt"), "kept");
    put(&f.join("sub/also.txt"), "also");
    call(&a, "share_add", json!({"path": f, "name": "Notebooks", "id": "nb1"}));
    wait("the files indexed", 30, || {
        call(&a, "sync_now", json!({}));
        call(&a, "status", json!({}))["shares"][0]["files"] == 2
    });
    // The folder goes (a stale container path): an error in the activity, and no delete recorded.
    std::fs::rename(&f, tmp.path().join("elsewhere")).unwrap();
    wait("the missing error", 30, || {
        call(&a, "sync_now", json!({}));
        log(&a).contains("is missing")
    });
    assert!(deletes(&da, "nb1").is_empty(), "a missing folder must record no deletes: {:?}", deletes(&da, "nb1"));
    assert_eq!(call(&a, "status", json!({}))["shares"][0]["files"], 2);
    a.close();
}

#[test]
fn a_repoint_records_no_deletes_and_pulls_missing_files_back() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb_old) = (tmp.path().join("folder-a"), tmp.path().join("old-container"));
    put(&fa.join("one.txt"), "first");
    put(&fa.join("sub/two.txt"), "second");
    put(&fa.join("three.txt"), "third");

    let a = engine(&da, "Desk");
    let b = engine(&db, "Phone");
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"path": fa, "name": "Notebooks", "id": "nb1"}));
    wait("the offer on B", 30, || {
        call(&b, "sync_now", json!({}));
        call(&b, "status", json!({}))["offers"].as_array().map(|o| !o.is_empty()).unwrap_or(false)
    });
    call(&b, "share_join", json!({"id": "nb1", "path": fb_old}));
    wait("the files on B", 60, || fb_old.join("three.txt").exists() && fb_old.join("sub/two.txt").exists() && fb_old.join("one.txt").exists());

    // The container moves: the old folder is gone, the files are in a new one, same content.
    let fb_same = tmp.path().join("new-container-same");
    put(&fb_same.join("one.txt"), "first");
    put(&fb_same.join("sub/two.txt"), "second");
    put(&fb_same.join("three.txt"), "third");
    std::fs::remove_dir_all(&fb_old).unwrap();
    call(&b, "share_add", json!({"path": fb_same, "name": "Notebooks", "id": "nb1"}));
    for _ in 0..3 {
        call(&b, "sync_now", json!({}));
        call(&a, "sync_now", json!({}));
        std::thread::sleep(Duration::from_secs(2));
    }
    assert!(deletes(&db, "nb1").is_empty() && deletes(&da, "nb1").is_empty());
    assert!(fa.join("three.txt").exists() && fa.join("sub/two.txt").exists());
    // Sync resumes: an edit on A arrives in the new folder.
    std::thread::sleep(Duration::from_millis(1100));
    put(&fa.join("one.txt"), "edited on the desk");
    call(&a, "sync_now", json!({}));
    wait("the edit on B", 60, || {
        call(&b, "sync_now", json!({}));
        std::fs::read_to_string(fb_same.join("one.txt")).map(|s| s == "edited on the desk").unwrap_or(false)
    });
    // After that first scan, a real delete on B is a delete again.
    std::fs::remove_file(fb_same.join("three.txt")).unwrap();
    wait("a real delete reaching A", 60, || {
        call(&b, "sync_now", json!({}));
        call(&a, "sync_now", json!({}));
        !fa.join("three.txt").exists()
    });

    // The container moves again, onto a folder with FEWER files: nothing is deleted on A, and B gets the rest back.
    let fb_few = tmp.path().join("new-container-fewer");
    put(&fb_few.join("one.txt"), "edited on the desk");
    std::fs::remove_dir_all(&fb_same).unwrap();
    call(&b, "share_join", json!({"id": "nb1", "path": fb_few}));
    assert!(log(&b).contains("folder moved after an update"));
    for _ in 0..3 {
        call(&b, "sync_now", json!({}));
        call(&a, "sync_now", json!({}));
        std::thread::sleep(Duration::from_secs(2));
    }
    wait("the missing file pulled back", 60, || {
        call(&b, "sync_now", json!({}));
        fb_few.join("sub/two.txt").exists()
    });
    assert_eq!(std::fs::read_to_string(fb_few.join("sub/two.txt")).unwrap(), "second");
    assert!(fa.join("sub/two.txt").exists() && fa.join("one.txt").exists(), "nothing may be deleted on the peer");
    assert!(!deletes(&da, "nb1").contains(&"sub/two.txt".to_string()));
    assert!(!deletes(&db, "nb1").contains(&"sub/two.txt".to_string()));
    a.close();
    b.close();
}
