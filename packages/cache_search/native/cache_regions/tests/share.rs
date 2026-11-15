//! The region engine's share with one writer per file (src/share.rs): what an older build's sync conflicts left is taken back into
//! this device's own databases, and this device's places database is shared as a snapshot under its own name.

use cache_places::fixture::{fixture_tiles, write_fixture_common, write_fixture_shard, FIXTURE_BUILD};
use cache_places::merged;
use cache_regions::{rescue_conflicts, Config, Regions};
use rusqlite::Connection;
use std::path::{Path, PathBuf};
use std::time::Duration;

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cr-share-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(p.join("regions/places")).unwrap();
        Tmp(p)
    }
    /// The regions folder (its parent holds the app's regions-app.json).
    fn dir(&self) -> PathBuf {
        self.0.join("regions")
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A regions.sqlite (the tables the engine makes) holding region `id`, with a tile list.
fn regions_db(path: &Path, id: &str) {
    let c = Connection::open(path).unwrap();
    c.execute_batch(
        "PRAGMA journal_mode = WAL;
         CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS regions(id TEXT PRIMARY KEY, name TEXT NOT NULL, geometry TEXT NOT NULL, added INTEGER NOT NULL, error TEXT,
                                            parts TEXT NOT NULL DEFAULT '[\"routing\"]', places_error TEXT, near TEXT);
         CREATE TABLE IF NOT EXISTS region_tiles2(region TEXT NOT NULL, component TEXT NOT NULL, build TEXT NOT NULL, path TEXT NOT NULL,
                                                  bytes INTEGER NOT NULL, sha256 TEXT NOT NULL, gz INTEGER NOT NULL, PRIMARY KEY(region, component, build, path));
         CREATE TABLE IF NOT EXISTS stream2(component TEXT NOT NULL, build TEXT NOT NULL, path TEXT NOT NULL, bytes INTEGER NOT NULL, last_used INTEGER NOT NULL,
                                            PRIMARY KEY(component, build, path));",
    )
    .unwrap();
    c.execute("INSERT INTO regions(id, name, geometry, added) VALUES(?1, ?1, '{}', 1)", [id]).unwrap();
    c.execute("INSERT INTO region_tiles2 VALUES(?1, 'routing', 'b', '1/047/586', 10, 'x', 5)", [id]).unwrap();
    // make sure the log is folded away or kept as the test wants
    let _ = c.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));
}

fn region_ids(path: &Path) -> Vec<String> {
    let c = Connection::open(path).unwrap();
    let mut q = c.prepare("SELECT id FROM regions ORDER BY id").unwrap();
    let ids: Vec<String> = q.query_map([], |r| r.get::<_, String>(0)).unwrap().map(|r| r.unwrap()).collect();
    drop(q);
    ids
}

fn conflict(dir: &Path, stem_ext: &str, who: &str, stamp: &str) -> PathBuf {
    let (stem, ext) = stem_ext.split_once('.').map(|(a, b)| (a, format!(".{b}"))).unwrap_or((stem_ext, String::new()));
    dir.join(format!("{stem} (conflict, {who}, {stamp}){ext}"))
}

#[test]
fn a_conflict_copy_of_regions_sqlite_is_this_devices_own_and_the_live_file_is_the_peers() {
    let t = Tmp::new("regions");
    let dir_buf = t.dir();
    let dir = &dir_buf;
    // the app lists the regions it holds itself
    std::fs::write(t.0.join("regions-app.json"), r#"{"regions": {"own-region": {"routing": true}, "earlier-region": {"routing": true}}}"#).unwrap();
    // what the old build left: the other device's database live, this device's own as a conflict copy
    regions_db(&dir.join("regions.sqlite"), "peers-region");
    let own = conflict(dir, "regions.sqlite", "Android device", "2026-11-15 2040 UTC");
    regions_db(&own, "own-region");
    let second = conflict(dir, "regions.sqlite", "Android device", "2026-11-14 1010 UTC");
    regions_db(&second, "earlier-region");
    // a log of a database that is gone, and a name that only has brackets
    let lone_log = dir.join("regions (conflict, X, 2026-11-13 0900 UTC).sqlite-wal");
    std::fs::write(&lone_log, b"log").unwrap();
    let bracket = dir.join("notes (conflict) final.sqlite");
    std::fs::write(&bracket, b"x").unwrap();

    assert!(rescue_conflicts(dir) >= 3);
    assert_eq!(region_ids(&dir.join("regions.sqlite")), ["earlier-region", "own-region"], "the peer's region is not this device's, the copies are");
    assert!(!own.exists() && !second.exists() && !lone_log.exists());
    assert!(bracket.exists(), "a name that is not a conflict copy is left alone");
    // the tile lists came with their regions
    let c = Connection::open(dir.join("regions.sqlite")).unwrap();
    assert_eq!(c.query_row("SELECT COUNT(*) FROM region_tiles2", [], |r| r.get::<_, i64>(0)).unwrap(), 2, "each region came with its tile list");
    assert_eq!(rescue_conflicts(dir), 0, "nothing left to do");
}

#[test]
fn a_copy_that_is_not_a_database_is_left_and_the_live_file_is_not_dropped_for_it() {
    let t = Tmp::new("broken");
    let dir_buf = t.dir();
    let dir = &dir_buf;
    regions_db(&dir.join("regions.sqlite"), "live-region");
    let broken = conflict(dir, "regions.sqlite", "A", "2026-11-15 2040 UTC");
    std::fs::write(&broken, b"not a database at all, not a database at all").unwrap();
    assert_eq!(rescue_conflicts(dir), 0);
    assert!(broken.exists());
    assert_eq!(region_ids(&dir.join("regions.sqlite")), ["live-region"]);
}

fn places_db(t: &Tmp, db: &Path, tiles: &[u32]) {
    let common = t.0.join("common.sqlite");
    write_fixture_common(&common, FIXTURE_BUILD);
    let mut c = merged::create(db, &common).unwrap();
    for &tile in tiles {
        let shard = t.0.join(format!("{tile}.sqlite"));
        write_fixture_shard(&shard, tile, FIXTURE_BUILD);
        merged::merge_tile(&mut c, tile, &shard, "0", 0).unwrap();
    }
    let _ = c.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));
}

#[test]
fn a_conflict_copy_of_the_places_database_becomes_the_live_one() {
    let t = Tmp::new("places");
    let tiles = fixture_tiles();
    assert!(tiles.len() >= 3);
    let places = t.dir().join("places");
    // the other device's merged database is live; this device's two copies hold one tile and two tiles
    places_db(&t, &places.join(format!("{FIXTURE_BUILD}.sqlite")), &tiles[..1]);
    let small = places.join(format!("{FIXTURE_BUILD} (conflict, A, 2026-11-14 1010 UTC).sqlite"));
    let big = places.join(format!("{FIXTURE_BUILD} (conflict, A, 2026-11-15 2040 UTC).sqlite"));
    places_db(&t, &small, &tiles[1..2]);
    places_db(&t, &big, &tiles[1..3]);
    std::fs::write(places.join("CURRENT (conflict, A, 2026-11-15 2040 UTC)"), FIXTURE_BUILD).unwrap();
    std::fs::create_dir_all(places.join(FIXTURE_BUILD)).unwrap();
    std::fs::write(places.join(FIXTURE_BUILD).join("common (conflict, A, 2026-11-15 2040 UTC).sqlite"), b"x").unwrap();

    assert!(rescue_conflicts(&t.dir()) >= 3);
    let tiles_of = |p: &Path| merged::tiles(&Connection::open(p).unwrap()).unwrap().len();
    assert_eq!(tiles_of(&places.join(format!("{FIXTURE_BUILD}.sqlite"))), 2, "the copy with the most tiles is the live database; the peer's one-tile file is gone");
    let left: Vec<String> = std::fs::read_dir(&places).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    assert!(left.iter().all(|n| !n.contains("(conflict")), "{left:?}");
    assert!(!places.join(FIXTURE_BUILD).join("common (conflict, A, 2026-11-15 2040 UTC).sqlite").exists());
}

#[test]
fn the_places_database_is_shared_as_a_snapshot_under_this_devices_name() {
    let t = Tmp::new("export");
    let tiles = fixture_tiles();
    let places = t.dir().join("places");
    places_db(&t, &places.join(format!("{FIXTURE_BUILD}.sqlite")), &tiles[..2]);
    std::fs::write(places.join("CURRENT"), FIXTURE_BUILD).unwrap();
    let r = Regions::open(Config {
        dir: t.dir(),
        base_url: "http://127.0.0.1:1/".into(),
        stream_cap_bytes: 0,
        user_agent: None,
        reserve_bytes: None,
        places_base_url: Some("http://127.0.0.1:1/".into()),
        places_stream_cap_bytes: 0,
        indexes_dir: None,
    })
    .unwrap();
    let id = std::fs::read_to_string(t.dir().join(".share-id")).unwrap();
    let snap = t.dir().join("places-share").join(FIXTURE_BUILD).join(format!("{}.sqlite", id.trim()));
    assert!(!r.share_places_now(Duration::from_secs(3600)), "just written to: not quiet yet");
    assert!(r.share_places_now(Duration::ZERO));
    assert!(snap.is_file());
    assert!(!r.share_places_now(Duration::ZERO), "unchanged: nothing to write again");
    // a whole database of its own: readable as a pack, with the same tiles, and no log beside it
    let p = cache_places::Pack::open(&snap).unwrap();
    assert_eq!(p.tiles().len(), 2);
    let names: Vec<String> = std::fs::read_dir(snap.parent().unwrap()).unwrap().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    assert_eq!(names.len(), 1, "{names:?}");
    r.close();
}

#[test]
fn a_live_regions_database_that_is_this_devices_own_stays_and_a_copy_that_is_another_devices_is_deleted() {
    let t = Tmp::new("regions-own-live");
    let dir = t.dir();
    std::fs::write(t.0.join("regions-app.json"), r#"{"regions": {"mine": {"routing": true}}}"#).unwrap();
    regions_db(&dir.join("regions.sqlite"), "mine");
    let theirs = conflict(&dir, "regions.sqlite", "B", "2026-11-15 2040 UTC");
    regions_db(&theirs, "theirs");
    assert_eq!(rescue_conflicts(&dir), 1);
    assert!(!theirs.exists());
    assert_eq!(region_ids(&dir.join("regions.sqlite")), ["mine"]);
}

#[test]
fn with_no_list_of_its_own_regions_the_live_database_stays_and_every_copy_is_merged_into_it() {
    let t = Tmp::new("regions-nolist");
    let dir = t.dir();
    regions_db(&dir.join("regions.sqlite"), "live");
    let copy = conflict(&dir, "regions.sqlite", "B", "2026-11-15 2040 UTC");
    regions_db(&copy, "copy");
    assert_eq!(rescue_conflicts(&dir), 1);
    assert_eq!(region_ids(&dir.join("regions.sqlite")), ["copy", "live"]);
}
