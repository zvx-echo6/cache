//! Places across linked devices: each device searches its own merged database and the snapshots its peers share
//! (`places-share/<build>/<device>.sqlite`), read-only and never merged into one file (share.rs).

use cache_places::fixture::{fixture_tiles, write_fixture_common, write_fixture_shard, FIXTURE_BUILD};
use cache_places::schema::tile_id_l1;
use cache_places::{merged, Geocoder, Pack, PackGeocoder, PackSet};
use rusqlite::Connection;
use std::path::PathBuf;
use std::sync::Arc;

const BURLEY: (f64, f64) = (42.5357, -113.7928);

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cp-share-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(p.join("regions/places")).unwrap();
        Tmp(p)
    }
    /// The folder `CURRENT` is in.
    fn places(&self) -> PathBuf {
        self.0.join("regions/places")
    }
    fn peers(&self) -> PathBuf {
        self.0.join("regions/places-share").join(FIXTURE_BUILD)
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A merged database of `tiles` at `db`.
fn merged_db(t: &Tmp, db: &std::path::Path, tiles: &[u32]) -> Connection {
    let common = t.0.join("common.sqlite");
    write_fixture_common(&common, FIXTURE_BUILD);
    let mut c = merged::create(db, &common).unwrap();
    for &tile in tiles {
        let shard = t.0.join(format!("{tile}.sqlite"));
        write_fixture_shard(&shard, tile, FIXTURE_BUILD);
        merged::merge_tile(&mut c, tile, &shard, "0", 0).unwrap();
    }
    merged::set_regions(&c, "Idaho").unwrap();
    c
}

fn labels(g: &PackGeocoder, q: &str) -> Vec<String> {
    g.forward(q, None, 8).iter().map(|h| format!("{:?} {} {:.5} {:.5}", h.kind, h.label, h.lat, h.lon)).collect()
}

/// This device (A) holds only the tiles around Burley; a linked device (B) shared a snapshot of everything.
fn two_devices(name: &str) -> (Tmp, Arc<PackSet>) {
    let t = Tmp::new(name);
    let burley = tile_id_l1(BURLEY.0, BURLEY.1);
    let own = merged_db(&t, &t.places().join(format!("{FIXTURE_BUILD}.sqlite")), &[burley]);
    drop(own);
    std::fs::write(t.places().join("CURRENT"), FIXTURE_BUILD).unwrap();
    std::fs::write(t.0.join("regions/.share-id"), "devicea").unwrap();
    std::fs::create_dir_all(t.peers()).unwrap();
    let full = merged_db(&t, &t.0.join("full.sqlite"), &fixture_tiles());
    full.execute("VACUUM INTO ?1", [t.peers().join("deviceb.sqlite").to_string_lossy().as_ref()]).unwrap();
    let set = Arc::new(PackSet::new(vec![], Some(t.places())));
    (t, set)
}

#[test]
fn a_device_searches_its_own_places_and_a_peers_shared_copy_and_finds_what_only_the_peer_has() {
    let (t, set) = two_devices("union");
    let packs = set.current();
    assert_eq!(packs.len(), 2, "its own database, then the peer's snapshot");
    assert!(packs[0].path.ends_with(format!("{FIXTURE_BUILD}.sqlite")), "own first");
    assert!(packs[1].path.ends_with("deviceb.sqlite"));
    let g = PackGeocoder::new(set.clone());
    // Stanley is in no tile this device holds
    let own_only = PackGeocoder::new(Arc::new(PackSet::new(vec![t.places().join(format!("{FIXTURE_BUILD}.sqlite"))], None)));
    assert!(labels(&own_only, "Stanley").is_empty(), "A alone does not have Stanley");
    assert!(!labels(&g, "Stanley").is_empty(), "A with B's copy does");
    // and a place both hold is listed once, as when the peer's copy alone answers
    let alone = PackGeocoder::new(Arc::new(PackSet::new(vec![t.peers().join("deviceb.sqlite")], None)));
    for q in ["Walgreens, Burley", "Burley", "Stanley, Idaho", "pharmacy"] {
        assert_eq!(labels(&g, q), labels(&alone, q), "{q}: the union answers as the full copy does");
    }
    // never merged: A's own database still holds only its own tile
    assert_eq!(Pack::open(&t.places().join(format!("{FIXTURE_BUILD}.sqlite"))).unwrap().tiles().len(), 1);
}

#[test]
fn this_devices_own_snapshot_and_anything_that_is_not_a_snapshot_are_never_read() {
    let (t, set) = two_devices("skip");
    std::fs::write(t.peers().join("devicea.sqlite"), b"its own, stale").unwrap();
    std::fs::write(t.peers().join(".deviceb.sqlite.tmp1"), b"half").unwrap();
    std::fs::write(t.peers().join("deviceb (conflict, X, 2026-11-15 2040 UTC).sqlite"), b"copy").unwrap();
    std::fs::write(t.peers().join("devicec.sqlite"), b"still arriving").unwrap();
    assert_eq!(set.current().len(), 2, "A's own, the hidden, conflict and broken files are left out");
}

#[test]
fn a_device_with_no_places_of_its_own_yet_reads_a_peers_newest_build() {
    let t = Tmp::new("nobuild");
    std::fs::create_dir_all(t.peers()).unwrap();
    std::fs::write(t.0.join("regions/.share-id"), "devicea").unwrap();
    let full = merged_db(&t, &t.0.join("full.sqlite"), &fixture_tiles());
    full.execute("VACUUM INTO ?1", [t.peers().join("deviceb.sqlite").to_string_lossy().as_ref()]).unwrap();
    let set = Arc::new(PackSet::new(vec![], Some(t.places())));
    assert_eq!(set.current().len(), 1);
    assert!(!labels(&PackGeocoder::new(set), "Stanley").is_empty());
}

#[test]
fn nearby_and_the_map_search_list_a_place_both_devices_hold_once() {
    use cache_places::fixture::{fake_embed, FAKE_MODEL, FIXTURE_NOW};
    use cache_places::map::SearchOpts;
    use cache_places::{PlacesCfg, PlacesCore};
    use cache_tool::{NoSavedPlaces, ToolCtx, ToolOutput};
    let (t, _set) = two_devices("dedupe");
    let union = PlacesCfg { packs: vec![], merged_dir: Some(t.places().to_string_lossy().into_owned()) };
    let alone = PlacesCfg { packs: vec![t.peers().join("deviceb.sqlite").to_string_lossy().into_owned()], merged_dir: None };
    let nearby = |cfg: &PlacesCfg, args: serde_json::Value| {
        let ts = cache_places::tools(cfg);
        let tool = ts.iter().find(|x| x.name() == "nearby").unwrap();
        let ctx = ToolCtx { location: None, places: &NoSavedPlaces, now: FIXTURE_NOW, geocoder: None, live_fetcher: None };
        match tool.run(&ctx, &args) {
            Ok(ToolOutput::Json(v)) => v,
            other => panic!("{:?}", other.is_ok()),
        }
    };
    for args in [serde_json::json!({"category": "pharmacy", "near": "Burley, Idaho"}), serde_json::json!({"category": "hospital", "near": "Burley"})] {
        let (a, b) = (nearby(&union, args.clone()), nearby(&alone, args.clone()));
        assert_eq!(a["results"], b["results"], "{args}");
    }
    let embed = |q: &str| Some((FAKE_MODEL.to_string(), fake_embed(q)));
    let (u, a) = (PlacesCore::new(&union), PlacesCore::new(&alone));
    for (q, near) in [("pharmacy", Some(BURLEY)), ("Walgreens", Some(BURLEY)), ("Stanley", None), ("hospital", Some(BURLEY))] {
        let opts = SearchOpts { near, ..Default::default() };
        let plain = SearchOpts { near, meaning: false, ..Default::default() };
        let ids = |v: &serde_json::Value| v["results"].as_array().unwrap().iter().map(|r| r["id"].as_str().unwrap().to_string()).collect::<Vec<_>>();
        assert_eq!(ids(&u.search(q, &opts, Some(&embed)).unwrap()), ids(&a.search(q, &opts, Some(&embed)).unwrap()), "{q}");
        assert_eq!(ids(&u.search(q, &plain, None).unwrap()), ids(&a.search(q, &plain, None).unwrap()), "{q} (names and categories only)");
    }
}
