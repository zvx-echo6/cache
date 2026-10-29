//! The phone's merged database read like a pack: the fixture cut into level 1 tiles and merged gives every reader (geocoder,
//! nearby, locate, the map's search box, navigate's place source) the same answers as the single fixture pack built from the
//! same data; a tile merged while a `PackSet` is open is searched by the next call.

use cache_places::fixture::{
    fake_embed, fixture_tiles, write_fixture_common, write_fixture_pack_with_vectors, write_fixture_shard, FAKE_MODEL, FIXTURE_BUILD, FIXTURE_NOW,
};
use cache_places::map::SearchOpts;
use cache_places::schema::tile_id_l1;
use cache_places::{merged, Geocoder, Pack, PackGeocoder, PackSet, PlacesCfg, PlacesCore};
use cache_tool::places::{GeocodeQuery, NearestQuery};
use cache_tool::{Location, NoSavedPlaces, Tool, ToolCtx, ToolOutput};
use rusqlite::Connection;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cp-mergedrd-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(p.join("places")).unwrap();
        Tmp(p)
    }
    fn pack(&self) -> PathBuf {
        self.0.join("places.sqlite")
    }
    /// The folder `CURRENT` is in.
    fn merged_dir(&self) -> PathBuf {
        self.0.join("places")
    }
    fn db(&self) -> PathBuf {
        self.merged_dir().join(format!("{FIXTURE_BUILD}.sqlite"))
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// A merged database of `tiles` (the regions engine's steps: the common file, then each tile), named by `CURRENT`.
fn merged_db(t: &Tmp, tiles: &[u32]) -> Connection {
    let common = t.0.join("common.sqlite");
    write_fixture_common(&common, FIXTURE_BUILD);
    let mut c = merged::create(&t.db(), &common).unwrap();
    for &tile in tiles {
        merge(t, &mut c, tile);
    }
    merged::set_regions(&c, "Idaho").unwrap();
    std::fs::write(t.merged_dir().join("CURRENT"), FIXTURE_BUILD).unwrap();
    c
}

fn merge(t: &Tmp, c: &mut Connection, tile: u32) {
    let shard = t.0.join(format!("{tile}.sqlite"));
    write_fixture_shard(&shard, tile, FIXTURE_BUILD);
    merged::merge_tile(c, tile, &shard, "0", 0).unwrap();
}

fn pack_cfg(t: &Tmp) -> PlacesCfg {
    PlacesCfg { packs: vec![t.pack().to_string_lossy().into_owned()], merged_dir: None }
}

fn merged_cfg(t: &Tmp) -> PlacesCfg {
    PlacesCfg { packs: vec![], merged_dir: Some(t.merged_dir().to_string_lossy().into_owned()) }
}

/// The two ways of having the same data: the single fixture pack, and the fixture's tiles merged.
fn both(name: &str) -> (Tmp, Connection) {
    let t = Tmp::new(name);
    write_fixture_pack_with_vectors(&t.pack());
    let c = merged_db(&t, &fixture_tiles());
    (t, c)
}

fn run(ts: &[Box<dyn Tool>], name: &str, location: Option<&Location>, args: &Value) -> Value {
    let tool = ts.iter().find(|t| t.name() == name).unwrap();
    let ctx = ToolCtx { location, places: &NoSavedPlaces, now: FIXTURE_NOW, geocoder: None, live_fetcher: None };
    match tool.run(&ctx, args) {
        Ok(ToolOutput::Json(v)) => v,
        Ok(ToolOutput::Text(t)) => json!(t),
        Err(e) => e.to_json(),
    }
}

const BURLEY: (f64, f64) = (42.5357, -113.7928);
const STANLEY: (f64, f64) = (44.2210, -114.9360);
const BOISE: (f64, f64) = (43.6150, -116.2023);

#[test]
fn the_merged_database_opens_as_a_pack() {
    let (t, _c) = both("open");
    let p = Pack::open(&t.db()).unwrap();
    assert_eq!(p.format, 3);
    assert!(p.is_merged());
    assert_eq!(p.meta.region_name, "Idaho");
    assert_eq!(p.meta.region_id, "device");
    assert_eq!(p.tiles().len(), fixture_tiles().len());
    let single = Pack::open(&t.pack()).unwrap();
    assert!(!single.is_merged());
    // Counts, kinds and the matched hospitals are the same as the single pack's.
    let counts = |p: &Pack| p.categories.iter().map(|c| (c.id.clone(), c.place_count)).collect::<Vec<_>>();
    assert_eq!(counts(&p), counts(&single));
    assert_eq!(p.kinds, single.kinds);
    assert_eq!(p.matched, single.matched);
    assert_eq!(p.embedding(), single.embedding());
    // covers: by the tiles on the phone, not by a box.
    assert!(p.covers(BURLEY.0, BURLEY.1) && p.covers(STANLEY.0, STANLEY.1));
    assert!(!p.covers(45.5, -113.5), "inside the box of the tiles but not a tile with data");
    assert!(single.covers(45.5, -113.5));
}

#[test]
fn the_geocoder_answers_as_from_the_single_pack() {
    let (t, _c) = both("geo");
    let a = PackGeocoder::new(Arc::new(PackSet::new(vec![t.pack()], None)));
    let b = PackGeocoder::new(Arc::new(PackSet::new(vec![], Some(t.merged_dir()))));
    let show = |h: &cache_places::GeoHit| {
        format!("{:?} {} {} {:.5} {:.5} {:?} {:?} {:.1} {:.4}", h.kind, h.address, h.label, h.lat, h.lon, h.kind_id, h.what, h.name_match, h.score)
    };
    for (q, near) in [
        ("Stanley", None),
        ("Stanley, Idaho", None),
        ("Stanley", Some((46.0, -97.0))),
        ("Walgreens", Some(BURLEY)),
        ("Walgreens, Burley", None),
        ("Cassia Regional", None),
        ("Cassia Regional Medical Center", None),
        ("st lukes", Some(BOISE)),
        ("Boise", None),
        ("Boyse", None),
        ("Stanly", None),
        ("Burley", None),
        ("Ammon", None),
        ("Island Park, ID", None),
        ("pharmacy", Some(BURLEY)),
        ("Nowhereville", None),
    ] {
        let x: Vec<String> = a.forward(q, near, 8).iter().map(show).collect();
        let y: Vec<String> = b.forward(q, near, 8).iter().map(show).collect();
        assert_eq!(x, y, "{q} near {near:?}");
    }
    for (lat, lon) in [BURLEY, STANLEY, BOISE, (43.83, -115.83), (44.0, -115.6), (46.3, -97.2), (47.0, -100.0)] {
        let show = |n: Option<cache_places::Nearest>| n.map(|n| format!("{} {:.3} {:.1}", n.label, n.km, n.bearing));
        assert_eq!(show(a.reverse(lat, lon)), show(b.reverse(lat, lon)), "{lat},{lon}");
    }
}

#[test]
fn nearby_and_locate_answer_as_from_the_single_pack() {
    let (t, _c) = both("tools");
    let a = cache_places::tools(&pack_cfg(&t));
    let b = cache_places::tools(&merged_cfg(&t));
    let here = Location { lat: 43.828, lon: -115.834, accuracy_m: Some(10.0), fixed_at: FIXTURE_NOW.into() };
    for (loc, args) in [
        (None, json!({"category": "pharmacy", "near": "Burley, Idaho"})),
        (None, json!({"category": "emergency_room", "near": "Burley"})),
        (Some(&here), json!({"category": "emergency_room"})),
        (Some(&here), json!({"category": "hospital", "limit": 5})),
        (None, json!({"category": "water", "near": "Stanley, Idaho"})),
        (None, json!({"category": "shelter", "near": "Stanley, ID", "limit": 10})),
        (None, json!({"category": "fuel", "near": "Nowhereville"})),
        (None, json!({"category": "urgent_care", "near": "Boise"})),
    ] {
        let x = run(&a, "nearby", loc, &args);
        assert_eq!(x, run(&b, "nearby", loc, &args), "{args}");
        assert!(x.get("error").is_some() || x["map_region"] == "Idaho", "{x}");
    }
    for (loc, args) in [
        (None, json!({"place": "Walgreens, Burley"})),
        (None, json!({"place": "Stanley, Idaho"})),
        (Some(&here), json!({})),
        (None, json!({"place": "43.6,-116.2"})),
        (None, json!({"place": "Nowhereville"})),
    ] {
        assert_eq!(run(&a, "locate", loc, &args), run(&b, "locate", loc, &args), "{args}");
    }
    // The tool schemas (the installed categories) are the same too.
    let schema = |ts: &[Box<dyn Tool>]| ts.iter().map(|t| format!("{:?}", t.schema())).collect::<Vec<_>>();
    assert_eq!(schema(&a), schema(&b));
}

#[test]
fn map_search_answers_as_from_the_single_pack() {
    let (t, _c) = both("map");
    let a = PlacesCore::new(&pack_cfg(&t));
    let b = PlacesCore::new(&merged_cfg(&t));
    let embed = |q: &str| Some((FAKE_MODEL.to_string(), fake_embed(q)));
    for (q, near) in [
        ("pharmacy", Some(BURLEY)),
        ("pharmacy near Burley", None),
        ("hospital", Some(BOISE)),
        ("emergency room", Some(BURLEY)),
        ("water", Some(STANLEY)),
        ("somewhere to refill drinking water", Some(STANLEY)),
        ("lake beneath the mountains", Some(STANLEY)),
        ("Walgreens", Some(BURLEY)),
        ("Stanley", None),
        ("Stanly", Some(STANLEY)),
        ("St Lukes Boise", None),
        ("43.6,-116.2", Some(BURLEY)),
        ("shelter Stanley", None),
    ] {
        let opts = SearchOpts { near, ..Default::default() };
        let x = a.search(q, &opts, Some(&embed)).unwrap();
        let y = b.search(q, &opts, Some(&embed)).unwrap();
        let ids = |v: &Value| v["results"].as_array().unwrap().iter().map(|r| r["id"].as_str().unwrap().to_string()).collect::<Vec<_>>();
        if ids(&y).iter().any(|id| id.starts_with("kind:")) {
            // The merged database has kind vectors (from the common file) and the single pack none: a kind matched by
            // meaning adds its row and places, and every result of the single pack is still there.
            assert!(ids(&x).iter().all(|id| ids(&y).contains(id)), "{q}: {x} / {y}");
        } else {
            assert_eq!(x, y, "{q}");
        }
        let plain = SearchOpts { near, meaning: false, ..Default::default() };
        assert_eq!(a.search(q, &plain, None).unwrap(), b.search(q, &plain, None).unwrap(), "{q} (names and categories only)");
    }
    for id in ["place:osm:n1", "town:osm:n98", "place:osm:n999"] {
        let show = |e: Option<cache_places::map::Endpoint>| e.map(|e| format!("{:?} {:?} {} {} {:?}", e.id, e.name, e.lat, e.lon, e.osm_category));
        assert_eq!(show(a.lookup(id)), show(b.lookup(id)), "{id}");
    }
}

#[test]
fn navigates_place_source_answers_as_from_the_single_pack() {
    let (t, _c) = both("source");
    let (_, a) = cache_places::tools_and_source(&pack_cfg(&t));
    let (_, b) = cache_places::tools_and_source(&merged_cfg(&t));
    assert_eq!(a.categories(), b.categories());
    for (text, near, bias) in [
        ("Walgreens", Some("Burley, Idaho"), Some(BURLEY)),
        ("Stanley", Some("Idaho"), None),
        ("Stanley", None, Some((46.2, -97.1))),
        ("Cassia Regional Hospital", None, None),
        ("Nowhereville", None, None),
    ] {
        let q = GeocodeQuery { text, near, bias, limit: 3 };
        assert_eq!(format!("{:?}", a.geocode(&q).map(|g| g.matches)), format!("{:?}", b.geocode(&q).map(|g| g.matches)), "{text}");
    }
    for (category, from) in [("emergency_room", (43.828, -115.834)), ("emergency_room", (42.536, -113.792)), ("water", STANLEY), ("urgent_care", BOISE)] {
        let q = NearestQuery { category, from, limit: 3 };
        assert_eq!(format!("{:?}", a.nearest(&q).map(|g| g.matches)), format!("{:?}", b.nearest(&q).map(|g| g.matches)), "{category}");
    }
    let (ga, gb) = (a.geocoder().unwrap(), b.geocoder().unwrap());
    for text in ["Island Park, Idaho", "stanly, id", "Burley"] {
        assert_eq!(ga.resolve(text, None), gb.resolve(text, None), "{text}");
    }
}

#[test]
fn a_tile_merged_while_the_set_is_open_is_searched_next_time() {
    let t = Tmp::new("live");
    let set = Arc::new(PackSet::new(vec![], Some(t.merged_dir())));
    let geo = PackGeocoder::new(set.clone());
    assert!(set.current().is_empty(), "no CURRENT yet");
    let stanley = tile_id_l1(STANLEY.0, STANLEY.1);
    let mut c = merged_db(&t, &[stanley]);
    let first = set.current();
    assert_eq!(first.len(), 1);
    assert!(geo.forward("Walgreens", None, 3).is_empty());
    assert_eq!(first[0].category("pharmacy").unwrap().place_count, 0);

    // The engine merges Burley's tile through its own connection: the next search sees it, with no new PackSet.
    merge(&t, &mut c, tile_id_l1(BURLEY.0, BURLEY.1));
    let hits = geo.forward("Walgreens", None, 3);
    assert_eq!(hits.first().map(|h| h.name.as_str()), Some("Walgreens"));
    let now = set.current();
    assert_eq!(now[0].category("pharmacy").unwrap().place_count, 3, "the cached tables are read again");
    assert!(now[0].covers(BURLEY.0, BURLEY.1));
    // Nothing changed since: the same open pack.
    assert!(Arc::ptr_eq(&now[0], &set.current()[0]));

    // Removed again: gone from the next search.
    merged::remove_tile(&mut c, tile_id_l1(BURLEY.0, BURLEY.1)).unwrap();
    assert!(geo.forward("Walgreens", None, 3).is_empty());

    // A single-region pack added by the app's refresh is searched after the merged database.
    write_fixture_pack_with_vectors(&t.pack());
    set.set_legacy(vec![t.pack()]);
    let packs = set.current();
    assert_eq!(packs.len(), 2);
    assert!(packs[0].is_merged() && !packs[1].is_merged());
    assert_eq!(set.legacy_paths(), vec![t.pack()]);
    assert_eq!(geo.forward("Walgreens", None, 3).len(), 1, "deduped across the two");
}

#[test]
fn context_towns_stand_in_while_their_own_tile_is_missing() {
    // Only Idaho City's tile is on the phone: Boise (its own tile is not) is a context town of it.
    let t = Tmp::new("ctx");
    let (boise, idaho_city) = (tile_id_l1(BOISE.0, BOISE.1), tile_id_l1(43.8280, -115.8340));
    assert_ne!(boise, idaho_city);
    let mut c = merged_db(&t, &[idaho_city]);
    let geo = PackGeocoder::new(Arc::new(PackSet::new(vec![], Some(t.merged_dir()))));
    let near_boise = (43.62, -116.0);
    assert_eq!(tile_id_l1(near_boise.0, near_boise.1), idaho_city);
    assert_eq!(geo.reverse(near_boise.0, near_boise.1).unwrap().label, "Boise, ID");
    // With Boise's own tile here, its own row answers, once.
    merge(&t, &mut c, boise);
    let p = Pack::open(&t.db()).unwrap();
    let found = p.localities_near(BOISE.0, BOISE.1, 30.0).unwrap();
    assert_eq!(found.iter().filter(|(l, _)| l.name == "Boise").count(), 1);
    assert!(found.iter().all(|(l, _)| l.id > 0), "{found:?}");
    assert_eq!(geo.reverse(near_boise.0, near_boise.1).unwrap().label, "Boise, ID");
}
