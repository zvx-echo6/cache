//! Maps sync with one writer per file. Each device writes its own live map databases (`store/<layer>.sqlite`, `regions.sqlite`,
//! `places/<build>.sqlite`, with their -wal); when those synced as ordinary files, two devices that each downloaded a different
//! region replaced each other's database and kept their own as "(conflict, ...)" copies, and one of them lost its region (the
//! 2026-11-15 emulator run). Now the live files never sync, and each device shares its own snapshot under its own name
//! (`store-share/<layer>/<device>.sqlite`, `regions-share/<device>.json`, `places-share/<build>/<device>.sqlite`) and a record of
//! what it deleted. Real engines, the app's real patterns, and an old build's engine that still syncs the live files.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

/// The app's patterns (app/lib/sharing/share_rules.dart kRegionsNotShared and kMapLayersNotShared, which the phone and Cache Server
/// both use); keep them equal. `MAPS_OLD_PATTERNS=1` runs the same test with the patterns of the builds before the fix, which is
/// how the test was first seen failing.
fn app_patterns() -> Value {
    if std::env::var("MAPS_OLD_PATTERNS").is_ok() {
        return json!({
            "regions": ["index", "places/index", "**/*-shm", "**/*-journal"],
            "maps": ["tiles.sqlite*", "tilejson", "**/*-shm", "**/*-journal"],
        });
    }
    json!({
        "regions": ["index", "places/index", "**/*-shm", "**/*-journal", "regions.sqlite*", "places/*.sqlite*", "places/*/common.sqlite*", "places/CURRENT"],
        "maps": ["tiles.sqlite*", "tilejson", "**/*-shm", "**/*-journal", "store/*.sqlite*"],
    })
}

fn engine(dir: &Path, name: &str, exclude: bool) -> SyncEngine {
    let ex = if exclude { app_patterns() } else { json!({}) };
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "port": null, "exclude": ex,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

fn until(what: &str, secs: u64, engines: &[&SyncEngine], mut ok: impl FnMut() -> bool) {
    for i in 0..secs * 2 {
        if ok() {
            return;
        }
        if i % 2 == 0 {
            for e in engines {
                call(e, "sync_now", json!({}));
            }
        }
        std::thread::sleep(Duration::from_millis(500));
    }
    let log = |e: &SyncEngine| call(e, "status", json!({}))["log"].to_string();
    panic!("timed out waiting for {what}\n{}", engines.iter().map(|e| log(e)).collect::<Vec<_>>().join("\n"));
}

/// Lets every engine run a few rounds with the files settled, for checks that something did not happen.
fn rounds(engines: &[&SyncEngine]) {
    std::thread::sleep(Duration::from_secs(6));
    for _ in 0..3 {
        for e in engines {
            call(e, "sync_now", json!({}));
        }
        std::thread::sleep(Duration::from_secs(1));
    }
}

fn write(p: &Path, text: &str) {
    std::fs::create_dir_all(p.parent().unwrap()).unwrap();
    std::fs::write(p, text).unwrap();
}

fn read(p: &Path) -> String {
    std::fs::read_to_string(p).unwrap_or_default()
}

fn names(root: &Path) -> Vec<String> {
    fn go(dir: &Path, base: &Path, out: &mut Vec<String>) {
        for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
            if e.path().is_dir() {
                go(&e.path(), base, out);
            } else {
                out.push(e.path().strip_prefix(base).unwrap().to_string_lossy().into_owned());
            }
        }
    }
    let mut v = Vec::new();
    go(root, root, &mut v);
    v.sort();
    v
}

struct Dev {
    e: SyncEngine,
    maps: std::path::PathBuf,
    regions: std::path::PathBuf,
}

fn dev(tmp: &Path, name: &str, exclude: bool) -> Dev {
    let (maps, regions) = (tmp.join(format!("maps-{name}")), tmp.join(format!("regions-{name}")));
    std::fs::create_dir_all(&maps).unwrap();
    std::fs::create_dir_all(&regions).unwrap();
    Dev { e: engine(&tmp.join(format!("sync-{name}")), name, exclude), maps, regions }
}

fn share(d: &Dev) {
    call(&d.e, "share_add", json!({"id": "maps", "name": "Regions (maps)", "path": d.maps}));
    call(&d.e, "share_add", json!({"id": "regions", "name": "Regions (regions)", "path": d.regions}));
}

fn link(a: &Dev, b: &Dev) {
    let code = call(&a.e, "link_code", json!({}))["code"].as_str().unwrap().to_string();
    call(&b.e, "link", json!({"code": code}));
}

/// What a device keeps of its own: its live databases and the snapshot files it shares under its own name.
fn own_files(d: &Dev, id: &str, region: &str) {
    write(&d.maps.join("store/basemap.sqlite"), &format!("{id} basemap with {region}"));
    write(&d.maps.join("store/basemap.sqlite-wal"), &format!("{id} basemap log"));
    write(&d.regions.join("regions.sqlite"), &format!("{id} regions with {region}"));
    write(&d.regions.join("regions.sqlite-wal"), &format!("{id} regions log"));
    write(&d.regions.join("places/2026-10.sqlite"), &format!("{id} places"));
    write(&d.regions.join("places/2026-10.sqlite-wal"), &format!("{id} places log"));
    write(&d.regions.join("places/CURRENT"), "2026-10");
    write(&d.regions.join("places/2026-10/common.sqlite"), &format!("{id} common"));
    write(&d.maps.join(format!("store-share/basemap/{id}.sqlite")), &format!("{id} snapshot of basemap with {region}"));
    write(&d.regions.join(format!("regions-share/{id}.json")), &format!("{{\"{region}\":true}}"));
    write(&d.regions.join(format!("places-share/2026-10/{id}.sqlite")), &format!("{id} places snapshot"));
    // routing tiles are immutable, one writer, and travel as before
    write(&d.regions.join(format!("tiles/2026-10/1/047/{region}.gph")), &format!("{id} tile"));
}

#[test]
fn two_devices_with_different_regions_end_with_both_and_no_conflict_files() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b) = (dev(tmp.path(), "A", true), dev(tmp.path(), "B", true));
    own_files(&a, "A", "idaho");
    own_files(&b, "B", "anguilla");
    link(&a, &b);
    share(&a);
    share(&b);
    std::thread::sleep(Duration::from_secs(6));
    let both = |d: &Dev, other: &str, region: &str| {
        d.maps.join(format!("store-share/basemap/{other}.sqlite")).exists()
            && d.regions.join(format!("regions-share/{other}.json")).exists()
            && d.regions.join(format!("places-share/2026-10/{other}.sqlite")).exists()
            && d.regions.join(format!("tiles/2026-10/1/047/{region}.gph")).exists()
    };
    until("each device to have the other's shared files", 90, &[&a.e, &b.e], || both(&a, "B", "anguilla") && both(&b, "A", "idaho"));
    rounds(&[&a.e, &b.e]);

    for (d, other) in [(&a, "B"), (&b, "A")] {
        let all: Vec<String> = names(&d.maps).into_iter().chain(names(&d.regions)).collect();
        assert!(all.iter().all(|n| !n.contains("(conflict")), "no conflict copy: {all:?}");
        // each device's live files are as it wrote them: nothing replaced them
        let id = if other == "B" { "A" } else { "B" };
        assert!(read(&d.maps.join("store/basemap.sqlite")).starts_with(id), "{id}'s own store is still its own");
        assert!(read(&d.maps.join("store/basemap.sqlite-wal")).starts_with(id));
        assert!(read(&d.regions.join("regions.sqlite")).starts_with(id));
        assert!(read(&d.regions.join("regions.sqlite-wal")).starts_with(id));
        assert!(read(&d.regions.join("places/2026-10.sqlite")).starts_with(id));
        assert!(read(&d.regions.join("places/2026-10.sqlite-wal")).starts_with(id));
        assert!(read(&d.regions.join("places/2026-10/common.sqlite")).starts_with(id));
        // and the other device's did not arrive
        assert!(read(&d.maps.join(format!("store-share/basemap/{other}.sqlite"))).starts_with(other));
        assert!(read(&d.regions.join(format!("regions-share/{other}.json"))).contains('{'));
    }
    // neither live database nor log is in the other's tree under the live names: what is there is the device's own
    for d in [&a, &b] {
        let all = names(&d.maps);
        assert_eq!(all.iter().filter(|n| n.starts_with("store/")).count(), 2, "{all:?}");
    }
    a.e.close();
    b.e.close();
}

#[test]
fn a_delete_record_travels_and_a_peers_old_build_files_are_neither_fetched_nor_deleted() {
    let tmp = tempfile::tempdir().unwrap();
    let (a, b) = (dev(tmp.path(), "A", true), dev(tmp.path(), "B", true));
    // an old build (no exclusions) still writes the live files, and syncs them to anyone that does not exclude them
    let c = dev(tmp.path(), "C", false);
    own_files(&a, "A", "idaho");
    own_files(&b, "B", "anguilla");
    write(&c.maps.join("store/basemap.sqlite"), "C basemap");
    write(&c.regions.join("regions.sqlite"), "C regions");
    write(&c.regions.join("places/2026-10.sqlite"), "C places");
    link(&a, &b);
    link(&a, &c);
    for d in [&a, &b, &c] {
        share(d);
    }
    std::thread::sleep(Duration::from_secs(6));
    until("A and B to have each other's snapshots", 90, &[&a.e, &b.e, &c.e], || {
        a.maps.join("store-share/basemap/B.sqlite").exists() && b.maps.join("store-share/basemap/A.sqlite").exists()
    });
    rounds(&[&a.e, &b.e, &c.e]);
    // C's live files are not fetched by A or B, and A's and B's are not sent to C
    for d in [&a, &b] {
        assert!(read(&d.maps.join("store/basemap.sqlite")).starts_with(if d.maps == a.maps { "A" } else { "B" }));
        assert!(read(&d.regions.join("regions.sqlite")).starts_with(if d.regions == a.regions { "A" } else { "B" }));
    }
    assert_eq!(read(&c.maps.join("store/basemap.sqlite")), "C basemap");
    assert_eq!(read(&c.regions.join("regions.sqlite")), "C regions");
    // the old build deleting its live file deletes nothing of A's or B's
    std::fs::remove_file(c.maps.join("store/basemap.sqlite")).unwrap();
    std::fs::remove_file(c.regions.join("regions.sqlite")).unwrap();
    rounds(&[&a.e, &b.e, &c.e]);
    assert!(a.maps.join("store/basemap.sqlite").exists() && b.maps.join("store/basemap.sqlite").exists());
    assert!(a.regions.join("regions.sqlite").exists() && b.regions.join("regions.sqlite").exists());

    // A deletes a region: a record in its own shared folder reaches B, and the same name is never written by B
    write(&a.maps.join("store-share/A.deletes.json"), r#"{"deletes":[{"layer":"basemap","area":"idaho","at":1}]}"#);
    write(&a.regions.join("regions-share/A.deletes.json"), r#"{"deletes":[{"id":"idaho","at":1}]}"#);
    until("the delete records on B", 90, &[&a.e, &b.e, &c.e], || {
        b.maps.join("store-share/A.deletes.json").exists() && b.regions.join("regions-share/A.deletes.json").exists()
    });
    assert!(read(&b.maps.join("store-share/A.deletes.json")).contains("idaho"));
    a.e.close();
    b.e.close();
    c.e.close();
}
