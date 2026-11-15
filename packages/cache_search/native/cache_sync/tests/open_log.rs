//! Opening the engine puts each step in a buffer the app asks for (`take_log`), in order, with the time since the open began. Nothing
//! is called out to the app: a callback into Dart aborted the process in a background isolate. One test only: the buffer is process-wide.

use cache_sync::{take_log, Config, SyncEngine};
use serde_json::json;

#[test]
fn an_open_says_its_steps_in_order_and_taking_them_clears_them() {
    let tmp = tempfile::tempdir().unwrap();
    let cfg: Config = serde_json::from_value(json!({
        "dir": tmp.path().join("a"), "name": "Phone", "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0,
    }))
    .unwrap();
    take_log();
    let e = SyncEngine::open(cfg).unwrap();
    let lines = take_log();
    for l in &lines {
        println!("{l}");
    }
    let steps = ["started", "links loaded", "identity loaded", "endpoint bound", "blob store opened", "state saved", "done"];
    assert_eq!(lines.len(), steps.len(), "{lines:?}");
    for (l, want) in lines.iter().zip(steps) {
        assert!(l.starts_with(&format!("sync open: {want} +")) && l.ends_with(" ms"), "{l}");
    }
    let ms: Vec<u64> = lines.iter().map(|l| l.rsplit_once('+').unwrap().1.trim_end_matches(" ms").parse().unwrap()).collect();
    assert!(ms.windows(2).all(|w| w[0] <= w[1]), "times only grow: {ms:?}");
    assert!(take_log().is_empty(), "taking the lines clears them");
    e.close();
}
