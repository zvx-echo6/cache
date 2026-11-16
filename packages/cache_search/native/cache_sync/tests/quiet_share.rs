//! A share the app lists in its own words (`quiet`: the notebooks) puts no line per file in the Activity: no "got <file>" naming
//! a person's notebook file. Another share still says each file it gets.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

fn engine(dir: &Path, name: &str, quiet: &[&str]) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "quiet": quiet,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
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
    panic!("timed out waiting for {what}\n{}", all.iter().map(|e| call(e, "status", json!({}))["log"].to_string()).collect::<Vec<_>>().join("\n"));
}

fn log_text(e: &SyncEngine) -> String {
    call(e, "status", json!({}))["log"].as_array().unwrap().iter().filter_map(|l| l["text"].as_str()).collect::<Vec<_>>().join("\n")
}

#[test]
fn a_quiet_share_lists_no_file_lines_and_another_share_still_does() {
    let tmp = tempfile::tempdir().unwrap();
    let (fa, fb, ga, gb) = (tmp.path().join("na"), tmp.path().join("nb"), tmp.path().join("oa"), tmp.path().join("ob"));
    for d in [&fa, &fb, &ga, &gb] {
        std::fs::create_dir_all(d).unwrap();
    }
    std::fs::write(fa.join("R9 Renamed.md"), b"a private entry").unwrap();
    std::fs::write(ga.join("plain.txt"), b"an ordinary file").unwrap();
    let a = engine(&tmp.path().join("dev-a"), "Desk", &[]);
    let b = engine(&tmp.path().join("dev-b"), "Phone", &["notebooks"]);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    let (notebooks, other) = ("notebooks", "othershare");
    call(&a, "share_add", json!({"id": notebooks, "path": fa, "name": "Notebooks"}));
    call(&a, "share_add", json!({"id": other, "path": ga, "name": "Other"}));
    for (share, dir) in [(notebooks, &fb), (other, &gb)] {
        until("the offer", 60, &[&a, &b], || call(&b, "status", json!({}))["offers"].as_array().map(|o| o.iter().any(|x| x["id"] == share)).unwrap_or(false));
        call(&b, "share_join", json!({"id": share, "path": dir}));
    }
    until("both files on B", 90, &[&a, &b], || fb.join("R9 Renamed.md").exists() && gb.join("plain.txt").exists());
    let text = log_text(&b);
    assert!(text.contains("Other: got plain.txt"), "an ordinary share says each file it got:\n{text}");
    assert!(!text.contains("Notebooks: got"), "the quiet share says no file line:\n{text}");
    assert!(!text.contains("R9 Renamed"), "no notebook file name in the Activity:\n{text}");
    // the sender never had a line for the file either
    assert!(!log_text(&a).contains("R9 Renamed"));
    a.close();
    b.close();
}
