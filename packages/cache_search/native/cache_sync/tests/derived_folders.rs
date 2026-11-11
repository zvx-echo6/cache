//! What each device builds for itself in a shared folder (a library's search index, `*/index`) never syncs: not sent, not
//! fetched, not deleted. A device that synced such a folder with an earlier version keeps its copy, and so does the other
//! device; and a library removed elsewhere goes with its index.

use cache_sync::{excluded, Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

/// The app's patterns (app/lib/sources/libraries_state.dart kLibraryNotShared, app/lib/regions/regions_state.dart
/// kRegionsNotShared and kMapLayersNotShared); keep them equal.
fn app_patterns() -> Value {
    json!({
        "libraries": ["*/index"],
        "regions": ["index", "places/index", "**/*-shm", "**/*-journal"],
        "maps": ["tiles.sqlite*", "tilejson", "**/*-shm", "**/*-journal"],
    })
}

fn engine(dir: &Path, name: &str, port: Option<u16>, exclude: bool) -> SyncEngine {
    let ex = if exclude { app_patterns() } else { json!({}) };
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "port": port, "exclude": ex,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

/// The port an engine was given (or chose): a device found again only by its address is opened again on it.
fn port_of(e: &SyncEngine) -> u16 {
    e.port().expect("the engine listens on a port")
}

/// Runs sync rounds on both until `ok` (files only count once they have settled, so this takes a few seconds).
fn until(what: &str, secs: u64, a: &SyncEngine, b: &SyncEngine, mut ok: impl FnMut() -> bool) {
    for i in 0..secs * 2 {
        if ok() {
            return;
        }
        if i % 2 == 0 {
            call(a, "sync_now", json!({}));
            call(b, "sync_now", json!({}));
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let log = |e: &SyncEngine| call(e, "status", json!({}))["log"].to_string();
    panic!("timed out waiting for {what}\nA: {}\nB: {}", log(a), log(b));
}

/// Lets both run a few rounds with every file settled, for checks that something did not happen.
fn rounds(a: &SyncEngine, b: &SyncEngine) {
    std::thread::sleep(Duration::from_secs(6));
    for _ in 0..3 {
        call(a, "sync_now", json!({}));
        call(b, "sync_now", json!({}));
        std::thread::sleep(Duration::from_secs(1));
    }
}

fn write(p: &Path, text: &str) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

#[test]
fn patterns_match_by_segment() {
    let p = vec!["*/index".to_string()];
    assert!(excluded(&p, "lib1/index"));
    assert!(excluded(&p, "lib1/index/meta.json"));
    assert!(excluded(&p, "lib1/index/a/b"));
    assert!(!excluded(&p, "lib1"));
    assert!(!excluded(&p, "index/meta.json"));
    assert!(!excluded(&p, "lib1/indexes/meta.json"));
    assert!(!excluded(&p, "lib1/shard/index/x"));
    assert!(!excluded(&p, "lib1/cache-library.json"));
    assert!(!excluded(&[], "lib1/index/meta.json"));
    assert!(!excluded(&["".to_string()], "lib1"));
}

#[test]
fn a_librarys_own_snapshots_beside_its_index_never_sync() {
    let p = vec!["*/index".to_string(), "*/index-snapshots".to_string()];
    assert!(excluded(&p, "lib1/index-snapshots"));
    assert!(excluded(&p, "lib1/index-snapshots/library/mine/snap/b1/manifest.json"));
    assert!(!excluded(&p, "lib1/index-snapshots2/x"));
    assert!(!excluded(&p, "lib1/shard/index-snapshots/x"));
}

#[test]
fn globs_within_a_segment_and_at_any_depth() {
    let p: Vec<String> = ["tiles.sqlite*", "**/*-shm", "places/index", "index"].iter().map(|s| s.to_string()).collect();
    for yes in ["tiles.sqlite", "tiles.sqlite-wal", "tiles.sqlite-shm", "regions.sqlite-shm", "places/2026-10.sqlite-shm", "a/b/c/x-shm", "index", "index/2026-10.tsv", "places/index/2026-10.tsv"] {
        assert!(excluded(&p, yes), "{yes} is excluded");
    }
    for no in ["tiles", "tiles/2026-10/0/003/196.gph", "store/osm.sqlite", "store/osm.sqlite-wal", "regions.sqlite", "regions.sqlite-wal", "places/2026-10.sqlite", "places/2026-10/common.sqlite", "places/CURRENT", "x-shm.txt", "indexes/a", "offroad/2026-10/idaho/offroad.sqlite"] {
        assert!(!excluded(&p, no), "{no} syncs");
    }
    let mid = vec!["a*b*c".to_string()];
    assert!(excluded(&mid, "abc") && excluded(&mid, "aXbYc") && !excluded(&mid, "acb") && !excluded(&mid, "ab"));
}

/// The Regions folders: every downloaded part travels; what a device fetched or cached for itself, and SQLite's -shm, never does.
#[test]
fn region_caches_never_travel() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (ra, rb, ma, mb) = (tmp.path().join("regions-a"), tmp.path().join("regions-b"), tmp.path().join("maps-a"), tmp.path().join("maps-b"));
    let parts = ["regions.sqlite", "regions.sqlite-wal", "tiles/2026-10/1/047/701.gph", "places/2026-10.sqlite", "places/2026-10/common.sqlite", "places/CURRENT", "offroad/offroad-2026-10/idaho/offroad.sqlite"];
    let caches = ["index/2026-10.tsv", "places/index/2026-10.tsv", "regions.sqlite-shm", "places/2026-10.sqlite-shm"];
    let layer_parts = ["store/osm.sqlite", "store/osm.sqlite-wal", "catalogue.json", "latest.json", "user-defs/mine.json"];
    let layer_caches = ["tiles.sqlite", "tiles.sqlite-wal", "tiles.sqlite-shm", "tilejson/osm.json", "store/osm.sqlite-shm"];
    for f in parts.iter().chain(&caches) {
        write(&ra.join(f), &format!("A {f}"));
    }
    for f in layer_parts.iter().chain(&layer_caches) {
        write(&ma.join(f), &format!("A {f}"));
    }
    // B has its own caches already (as copies an earlier version brought would be): they stay B's.
    write(&rb.join("index/2026-10.tsv"), "B's index");
    write(&mb.join("tiles.sqlite"), "B's cache");
    // No restart in this test: any free port.
    let a = engine(&da, "Desk", None, true);
    let b = engine(&db, "Phone", None, true);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    for (e, r, m) in [(&a, &ra, &ma), (&b, &rb, &mb)] {
        call(e, "share_add", json!({"id": "regions", "name": "Regions (regions)", "path": r}));
        call(e, "share_add", json!({"id": "maps", "name": "Regions (maps)", "path": m}));
    }
    std::thread::sleep(Duration::from_secs(6));
    until("every part on B", 90, &a, &b, || parts.iter().all(|f| rb.join(f).exists()) && layer_parts.iter().all(|f| mb.join(f).exists()));
    rounds(&a, &b);
    for f in &caches {
        if *f != "index/2026-10.tsv" {
            assert!(!rb.join(f).exists(), "{f} must not travel");
        }
        assert!(ra.join(f).exists(), "A keeps its {f}");
    }
    for f in &layer_caches {
        if *f != "tiles.sqlite" {
            assert!(!mb.join(f).exists(), "{f} must not travel");
        }
        assert!(ma.join(f).exists(), "A keeps its {f}");
    }
    assert_eq!(std::fs::read_to_string(rb.join("index/2026-10.tsv")).unwrap(), "B's index");
    assert_eq!(std::fs::read_to_string(mb.join("tiles.sqlite")).unwrap(), "B's cache");
    assert!(!ra.join("index/2026-10.tsv").exists() || std::fs::read_to_string(ra.join("index/2026-10.tsv")).unwrap() == "A index/2026-10.tsv");
    assert_eq!(std::fs::read_to_string(ma.join("tiles.sqlite")).unwrap(), "A tiles.sqlite");
    let st = call(&b, "status", json!({}));
    let files = |id: &str| st["shares"].as_array().unwrap().iter().find(|s| s["id"] == id).unwrap()["files"].clone();
    assert_eq!(files("regions"), parts.len(), "{st}");
    assert_eq!(files("maps"), layer_parts.len(), "{st}");
    a.close();
    b.close();
}

#[test]
fn a_library_index_never_travels() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (fa, fb) = (tmp.path().join("libs-a"), tmp.path().join("libs-b"));

    write(&fa.join("lib1/cache-library.json"), "{}");
    write(&fa.join("lib1/shard/seg.bin"), "segment one");
    write(&fa.join("lib1/index/meta.json"), "index of A");
    std::fs::create_dir_all(&fb).unwrap();

    // 1.0.29: neither excludes anything, so A's index arrives on B with the library.
    // Each takes any free port and keeps it for its restarts below (a port picked beforehand could be taken meanwhile).
    let a = engine(&da, "Desk", None, false);
    let b = engine(&db, "Phone", None, false);
    let (pa, pb) = (Some(port_of(&a)), Some(port_of(&b)));
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"id": "libraries", "name": "Library (libraries)", "path": fa}));
    call(&b, "share_add", json!({"id": "libraries", "name": "Library (libraries)", "path": fb}));
    std::thread::sleep(Duration::from_secs(6));
    until("the library and its index on B", 60, &a, &b, || {
        fb.join("lib1/shard/seg.bin").exists() && fb.join("lib1/index/meta.json").exists()
    });
    // B is updated (it excludes `*/index`); A is not yet. Only one restarts at a time: with no lookup service a device is found
    // again only by one that still knows its address.
    b.close();
    let b = engine(&db, "Phone", pb, true);
    write(&fa.join("lib1/index/meta.json"), "index of A, rebuilt");
    write(&fa.join("lib1/index/seg2"), "more of A's index");
    write(&fa.join("lib1/shard/seg2.bin"), "segment two");
    write(&fb.join("lib1/index/built-on-b"), "B's own");
    std::thread::sleep(Duration::from_secs(6));
    until("the new segment on B", 60, &a, &b, || fb.join("lib1/shard/seg2.bin").exists());
    rounds(&a, &b);
    // B kept the copy it had and took nothing new of A's index; A lost nothing and got nothing of B's.
    assert_eq!(std::fs::read_to_string(fb.join("lib1/index/meta.json")).unwrap(), "index of A");
    assert!(!fb.join("lib1/index/seg2").exists(), "A's index must not be fetched");
    assert_eq!(std::fs::read_to_string(fa.join("lib1/index/meta.json")).unwrap(), "index of A, rebuilt");
    assert!(fa.join("lib1/index/seg2").exists(), "nothing of A's index may be deleted");
    assert!(!fa.join("lib1/index/built-on-b").exists(), "B's index must not be sent");
    // B no longer lists the index: its share counts the library's own files only, with nothing pending.
    let st = call(&b, "status", json!({}));
    let sh = &st["shares"][0];
    assert_eq!(sh["files"], 3, "{st}");
    assert_eq!(sh["pending_files"], 0, "{st}");
    let listed = std::fs::read_to_string(db.join("index").join("libraries.json")).unwrap();
    assert!(!listed.contains("lib1/index"), "{listed}");

    // Both updated: still nothing of either index travels, and the rest still does.
    a.close();
    let a = engine(&da, "Desk", pa, true);
    write(&fa.join("lib1/index/seg3"), "and more");
    write(&fa.join("lib1/shard/seg3.bin"), "segment three");
    std::thread::sleep(Duration::from_secs(6));
    until("the third segment on B", 60, &a, &b, || fb.join("lib1/shard/seg3.bin").exists());
    rounds(&a, &b);
    assert!(!fb.join("lib1/index/seg3").exists());
    assert!(fa.join("lib1/index/seg2").exists() && fa.join("lib1/index/seg3").exists());
    assert!(!fa.join("lib1/index/built-on-b").exists());
    let st = call(&a, "status", json!({}));
    assert_eq!(st["shares"][0]["files"], 4, "{st}");

    // The library is removed on A: on B it goes, and its index (built from it) with it.
    std::fs::remove_dir_all(fa.join("lib1")).unwrap();
    until("the library gone from B", 60, &a, &b, || !fb.join("lib1").exists());
    assert!(fb.is_dir(), "the shared folder itself stays");
    a.close();
    b.close();
}

/// A library's settings file arrives on the other device byte for byte: sync copies files by hash and never reads or rewrites them,
/// so a library whose settings say `"own": true` (made on the person's other device) is `own` there too, and one that does not say it
/// never becomes so.
#[test]
fn a_librarys_settings_file_arrives_unchanged() {
    let tmp = tempfile::tempdir().unwrap();
    let (da, db) = (tmp.path().join("a"), tmp.path().join("b"));
    let (la, lb) = (tmp.path().join("libs-a"), tmp.path().join("libs-b"));
    let mine = "{\n  \"format\": 1,\n  \"library_id\": \"my-books-x\",\n  \"own\": true,\n  \"own_default\": true\n}\n";
    let built = "{\"format\":1,\"library_id\":\"field\",\"version\":\"7\"}";
    write(&la.join("my-books-x/cache-library.json"), mine);
    write(&la.join("field/cache-library.json"), built);
    write(&la.join("my-books-x/copies.jsonl"), "{}\n");
    std::fs::create_dir_all(&lb).unwrap();
    let a = engine(&da, "Desk", None, true);
    let b = engine(&db, "Phone", None, true);
    let code = call(&a, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b, "link", json!({"code": code}));
    call(&a, "share_add", json!({"id": "libraries", "name": "Libraries", "path": la}));
    call(&b, "share_add", json!({"id": "libraries", "name": "Libraries", "path": lb}));
    std::thread::sleep(Duration::from_secs(6));
    until("both settings files on B", 90, &a, &b, || lb.join("my-books-x/cache-library.json").exists() && lb.join("field/cache-library.json").exists());
    rounds(&a, &b);
    assert_eq!(std::fs::read(lb.join("my-books-x/cache-library.json")).unwrap(), mine.as_bytes(), "byte for byte");
    assert_eq!(std::fs::read(lb.join("field/cache-library.json")).unwrap(), built.as_bytes());
    a.close();
    b.close();
}
