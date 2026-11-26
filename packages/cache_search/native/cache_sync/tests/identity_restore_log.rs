//! When the key comes back from its second copy (`identity_keep`) the engine says so into `take_log`'s buffer, the same words the
//! phone's Dart side uses (app/lib/sharing/identity_keep.dart), so it reaches the Linux journal through the helper. One test only:
//! the buffer is process-wide.

use cache_sync::identity::KEY_FILE;
use cache_sync::{take_log, Config, SyncEngine};
use serde_json::json;

const LINE: &str = "this device's identity was brought back from its second copy";

fn cfg(dir: &std::path::Path, keep: &std::path::Path) -> Config {
    serde_json::from_value(json!({
        "dir": dir, "identity_keep": keep, "name": "Linux", "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0,
    }))
    .unwrap()
}

#[test]
fn a_restore_from_the_second_copy_leaves_a_log_line_and_a_normal_open_does_not() {
    let tmp = tempfile::tempdir().unwrap();
    let (dir, keep) = (tmp.path().join("sync"), tmp.path().join("identity-keep"));
    take_log();
    SyncEngine::open(cfg(&dir, &keep)).unwrap().close();
    assert!(!take_log().iter().any(|l| l.contains(LINE)), "a first open and a normal open do not say it");
    SyncEngine::open(cfg(&dir, &keep)).unwrap().close();
    assert!(!take_log().iter().any(|l| l.contains(LINE)), "an open with the key in place does not say it");
    std::fs::remove_file(dir.join(KEY_FILE)).unwrap();
    SyncEngine::open(cfg(&dir, &keep)).unwrap().close();
    let lines = take_log();
    assert_eq!(lines.iter().filter(|l| l.contains(LINE)).count(), 1, "said once on the restore: {lines:?}");
}
