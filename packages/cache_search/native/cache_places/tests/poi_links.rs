//! A chip's link, end to end through the places core: a tile with `poi_links` merged into a database, then `PlacesCore::search`
//! with a `poi` probe (what `cs_map_search` runs for a tapped chip). The answer is the linked place or nothing; a search is never made.

use cache_places::fixture::{write_fixture_common, write_fixture_shard, FIXTURE_BUILD};
use cache_places::map::{PoiProbe, SearchOpts};
use cache_places::merged::{create, merge_tile};
use cache_places::schema::tile_id_l1;
use cache_places::{PlacesCfg, PlacesCore};
use rusqlite::{params, Connection};
use std::path::PathBuf;

const BURLEY: (f64, f64) = (42.5357, -113.7928);

struct Tmp(PathBuf);
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn probe(kind: &str, name: &str, lat: f64, lon: f64) -> SearchOpts {
    SearchOpts { poi: Some(PoiProbe { kind: kind.into(), name: name.into(), lat, lon }), near: Some((lat, lon)), limit: 1, meaning: false, ..Default::default() }
}

#[test]
fn a_tapped_chip_answers_with_its_linked_place_and_an_unlinked_chip_with_nothing() {
    let dir = Tmp(std::env::temp_dir().join(format!("cp-poi-{}", std::process::id())));
    let _ = std::fs::remove_dir_all(&dir.0);
    std::fs::create_dir_all(&dir.0).unwrap();
    let tile = tile_id_l1(BURLEY.0, BURLEY.1);
    let common = dir.0.join("common.sqlite");
    write_fixture_common(&common, FIXTURE_BUILD);
    let shard = dir.0.join("shard.sqlite");
    write_fixture_shard(&shard, tile, FIXTURE_BUILD);
    let (sid, lat, lon): (String, f64, f64) = {
        let m = Connection::open(&shard).unwrap();
        let row = m.query_row("SELECT source_id, lat, lon FROM places WHERE name = 'Walgreens'", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
        m.execute("INSERT INTO meta VALUES ('poi_links', '{}')", []).unwrap();
        m.execute("INSERT INTO poi_links VALUES ('walgreens', 'pharmacy', ?1, ?2, ?3)", params![row.1, row.2, row.0]).unwrap();
        row
    };
    let db = dir.0.join("merged.sqlite");
    let mut c = create(&db, &common).unwrap();
    merge_tile(&mut c, tile, &shard, "aa", 1).unwrap();
    drop(c);
    let core = PlacesCore::new(&PlacesCfg { packs: vec![db.to_string_lossy().into_owned()], merged_dir: None });

    // The chip, a few metres off its stored point and with the name spelled as the tile does.
    let v = core.search("Walgreens", &probe("pharmacy", "Walgreens", lat + 0.00002, lon + 0.00002), None).unwrap();
    assert_eq!(v["interpreted"]["kind"], "poi");
    assert_eq!(v["poi_links"], true);
    let r = &v["results"];
    assert_eq!(r.as_array().unwrap().len(), 1, "{v}");
    assert_eq!(r[0]["id"], format!("place:{sid}"));
    assert_eq!(r[0]["matched"], "link");
    assert_eq!(r[0]["name"], "Walgreens");
    // Another kind (an attraction chip of the same name), another place of the name far away, or a chip with no link: nothing.
    for p in [probe("attraction", "Walgreens", lat, lon), probe("pharmacy", "Walgreens", lat + 0.01, lon), probe("pharmacy", "CVS", lat, lon)] {
        let v = core.search("x", &p, None).unwrap();
        assert!(v["results"].as_array().unwrap().is_empty(), "{v}");
        assert_eq!(v["poi_links"], true, "no link in a database that has links is still a database that has links");
    }
}

#[test]
fn a_database_from_tiles_cut_before_the_links_says_it_has_none() {
    let dir = Tmp(std::env::temp_dir().join(format!("cp-poi-old-{}", std::process::id())));
    let _ = std::fs::remove_dir_all(&dir.0);
    std::fs::create_dir_all(&dir.0).unwrap();
    let tile = tile_id_l1(BURLEY.0, BURLEY.1);
    let common = dir.0.join("common.sqlite");
    write_fixture_common(&common, FIXTURE_BUILD);
    let shard = dir.0.join("shard.sqlite");
    write_fixture_shard(&shard, tile, FIXTURE_BUILD);
    Connection::open(&shard).unwrap().execute_batch("DROP TABLE poi_links;").unwrap();
    let db = dir.0.join("merged.sqlite");
    let mut c = create(&db, &common).unwrap();
    merge_tile(&mut c, tile, &shard, "aa", 1).unwrap();
    drop(c);
    let core = PlacesCore::new(&PlacesCfg { packs: vec![db.to_string_lossy().into_owned()], merged_dir: None });
    let v = core.search("x", &probe("pharmacy", "Walgreens", BURLEY.0, BURLEY.1), None).unwrap();
    assert_eq!(v["poi_links"], false);
    assert!(v["results"].as_array().unwrap().is_empty());
}

/// With a real tile (`CACHE_POI_TILE`, `CACHE_POI_COMMON`, the tile's id in `CACHE_POI_TILE_ID`): the chips at Shoshone Falls.
/// `cargo test -p cache_places --test poi_links -- --ignored --nocapture`
#[test]
#[ignore]
fn the_real_twin_falls_tile_links_the_shoshone_chips() {
    let (tile_file, common, id) = (std::env::var("CACHE_POI_TILE").unwrap(), std::env::var("CACHE_POI_COMMON").unwrap(), std::env::var("CACHE_POI_TILE_ID").unwrap().parse::<u32>().unwrap());
    let dir = Tmp(std::env::temp_dir().join(format!("cp-poi-real-{}", std::process::id())));
    std::fs::create_dir_all(&dir.0).unwrap();
    let shard = dir.0.join("shard.sqlite");
    std::fs::copy(&tile_file, &shard).unwrap();
    let db = dir.0.join("merged.sqlite");
    let mut c = create(&db, &PathBuf::from(&common)).unwrap();
    merge_tile(&mut c, id, &shard, "aa", 1).unwrap();
    drop(c);
    let core = PlacesCore::new(&PlacesCfg { packs: vec![db.to_string_lossy().into_owned()], merged_dir: None });
    // The three chips as the tiles carry them (z12 to z15 points differ by metres): the attraction, the park, the other attraction.
    for (kind, lat, lon, want_id, want_kind) in [
        ("attraction", 42.59601, -114.40216, "place:osm:n1671534021", "Attraction"),
        ("park", 42.59302, -114.40056, "place:osm:w121853382", "Park"),
        ("attraction", 42.59366, -114.40196, "place:osm:n1183479286", "Attraction"),
    ] {
        let v = core.search("Shoshone Falls", &probe(kind, "Shoshone Falls", lat, lon), None).unwrap();
        println!("{kind} chip at {lat},{lon} -> {} ({}) matched={}", v["results"][0]["id"], v["results"][0]["kind"], v["results"][0]["matched"]);
        assert_eq!(v["results"][0]["id"], want_id);
        assert_eq!(v["results"][0]["kind"], want_kind);
    }
    // The old behaviour, for comparison: a plain name search near the attraction chip ranks the park's record first.
    let v = core.search("Shoshone Falls", &SearchOpts { near: Some((42.59601, -114.40216)), limit: 5, meaning: false, ..Default::default() }, None).unwrap();
    println!("plain search order: {:?}", v["results"].as_array().unwrap().iter().map(|r| format!("{} {}", r["id"], r["kind"])).collect::<Vec<_>>());
}
