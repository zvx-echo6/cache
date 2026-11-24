//! A device updated from a build with the iroh-blobs store moves it into the new store when the engine opens: in the background,
//! with progress in the status, one log line per file left out, and one total line. The old store is a real iroh-blobs 0.103.1
//! store checked in under cache_store/tests/data/.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{fs, path::Path, time::Duration};

fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for e in fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let t = to.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            copy_dir(&e.path(), &t);
        } else {
            fs::copy(e.path(), t).unwrap();
        }
    }
}

#[test]
fn an_old_store_is_moved_when_the_engine_opens() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = tmp.path().join("sync");
    let fixture = Path::new(env!("CARGO_MANIFEST_DIR")).join("../cache_store/tests/data/clean/blobs");
    copy_dir(&fixture, &dir.join("blobs"));
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": "Desk", "relay": false, "dht": false, "mdns": false, "lookup": false, "interval_secs": 5, "reserve_bytes": 0,
    }))
    .unwrap();
    let e = SyncEngine::open(cfg).unwrap();
    let status = || -> Value { e.call("status", &json!({})).unwrap() };
    let mut st = status();
    for _ in 0..120 {
        let text = st["log"].to_string();
        if st["store_move"].is_null() && text.contains("store move: done") {
            break;
        }
        std::thread::sleep(Duration::from_millis(250));
        st = status();
    }
    let log: Vec<String> = st["log"].as_array().unwrap().iter().map(|l| l["text"].as_str().unwrap().to_string()).collect();
    let moves: Vec<&String> = log.iter().filter(|l| l.starts_with("store move:")).collect();
    // The in-place files of the fixture point at a folder that is not here: those two are left out, each with a line of its own
    // (id, kind, reason); then one total line.
    let left: Vec<&&String> = moves.iter().filter(|l| l.starts_with("store move: left out ")).collect();
    assert_eq!(left.len(), 2, "{moves:?}");
    assert!(left.iter().filter(|l| l.contains("(external)")).count() == 2, "{moves:?}");
    let total = moves.iter().find(|l| l.contains("done.")).unwrap_or_else(|| panic!("{moves:?}"));
    assert!(total.contains("moved 6 files") && total.contains("2 left out") && total.contains("1 partial downloads dropped"), "{total}");
    // The same lines went to the app's log buffer (what becomes cache.log): the summary, each file left out, each tag dropped.
    let said: Vec<String> = cache_sync::take_log().into_iter().filter(|l| l.starts_with("store move:")).collect();
    assert!(said.iter().any(|l| l.contains("done.") && l.contains("2 left out")), "{said:?}");
    assert_eq!(said.iter().filter(|l| l.contains("left out ") && l.contains("(external)")).count(), 2, "{said:?}");
    assert!(said.iter().any(|l| l.contains("dropped tag share3/partial.bin") && l.contains("partial download")), "{said:?}");
    assert!(said.iter().any(|l| l.contains("dropped tag share2/ext1.bin") && l.contains("left out")), "{said:?}");
    let activity_tags = moves.iter().filter(|l| l.contains("dropped tag")).count();
    assert_eq!(activity_tags, 3, "the Activity has them too: {moves:?}");
    assert!(st["store_move"].is_null());
    assert!(!dir.join("blobs/blobs.db").exists(), "the old database is gone");
    assert!(dir.join("store/index.sqlite").exists());
    e.close();
}
