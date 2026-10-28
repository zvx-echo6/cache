//! Addresses, kind rows and the "no places" states over a merged database built from the fixture's tiles. The merge here is
//! a small stand-in written for these tests (the engine's own is `merged::merge_tile`); it lays the tiles out as
//! `MERGED_SCHEMA` says: merged ids, FTS, R-trees, vector refs and counts.

use cache_places::fixture::{fake_embed, fixture_tiles, write_fixture_common, write_fixture_pack, write_fixture_shard, FAKE_MODEL, FIXTURE_BUILD, FIXTURE_NOW};
use cache_places::map::SearchOpts;
use cache_places::schema::{merged_id, tile_id_l1, tile_path_l1, tile_rect_l1, MERGED_FORMAT_VERSION, MERGED_SCHEMA};
use cache_places::{tools, Geocoder, HitKind, PackGeocoder, PackSet, PlacesCfg, PlacesCore, PrepareAnswer};
use cache_tool::{NoSavedPlaces, ToolCtx, ToolOutput};
use rusqlite::{params, Connection};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cp-addr-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Tmp(p)
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

const BURLEY: (f64, f64) = (42.5357, -113.7928);
const STANLEY: (f64, f64) = (44.2210, -114.9360);
const BOISE: (f64, f64) = (43.6150, -116.2023);

/// A merged database of the fixture's `tiles` (all of them when None) at `<dir>/merged.sqlite`.
fn merged(dir: &Path, tiles: Option<&[u32]>) -> PathBuf {
    let db = dir.join("merged.sqlite");
    let common = dir.join("common.sqlite");
    write_fixture_common(&common, FIXTURE_BUILD);
    let c = Connection::open(&db).unwrap();
    c.execute_batch(MERGED_SCHEMA).unwrap();
    c.execute("ATTACH ?1 AS cm", params![common.to_string_lossy()]).unwrap();
    c.execute_batch(
        "INSERT INTO meta SELECT key, value FROM cm.meta;
         INSERT INTO categories(id, title, description, rules, sort) SELECT id, title, description, rules, sort FROM cm.categories;
         INSERT INTO kinds(id, label, description, category, rules, sort) SELECT id, label, description, category, rules, sort FROM cm.kinds;
         INSERT INTO states SELECT code, name, country FROM cm.states;
         INSERT INTO vectors(kind, ref, vec) SELECT kind, ref, vec FROM cm.vectors;
         DETACH cm;",
    )
    .unwrap();
    let all = fixture_tiles();
    let tiles = tiles.unwrap_or(&all);
    let mut bbox = [f64::MAX, f64::MAX, f64::MIN, f64::MIN];
    for &t in tiles {
        let r = tile_rect_l1(t);
        bbox = [bbox[0].min(r[1]), bbox[1].min(r[0]), bbox[2].max(r[3]), bbox[3].max(r[2])];
        let shard = dir.join(format!("{t}.sqlite"));
        write_fixture_shard(&shard, t, FIXTURE_BUILD);
        c.execute("ATTACH ?1 AS t", params![shard.to_string_lossy()]).unwrap();
        let base = merged_id(t, 0);
        let run = |sql: &str| {
            c.execute(sql, params![base]).unwrap_or_else(|e| panic!("{sql}: {e}"));
        };
        run("INSERT INTO places(id, name, category, kind, kind_id, lat, lon, street, locality, county, state, country, phone, hours, website, \
             wikidata_id, wikipedia_title, wikivoyage_title, summary, brand_wikidata, matched_source_id, source, source_id, confidence) \
             SELECT ?1 + id, name, category, kind, kind_id, lat, lon, street, locality, county, state, country, phone, hours, website, \
             wikidata_id, wikipedia_title, wikivoyage_title, summary, brand_wikidata, matched_source_id, source, source_id, confidence FROM t.places");
        run("INSERT INTO places_rt SELECT ?1 + id, lat, lat, lon, lon FROM t.places");
        run("INSERT INTO places_fts(rowid, name, alt_names) SELECT ?1 + id, name, alt_names FROM t.places WHERE name IS NOT NULL");
        run("INSERT INTO localities(id, name, kind, lat, lon, population, county, state, country, wikidata_id, wikipedia_title, wikivoyage_title, summary, source_id) \
             SELECT ?1 + id, name, kind, lat, lon, population, county, state, country, wikidata_id, wikipedia_title, wikivoyage_title, summary, source_id FROM t.localities");
        run("INSERT INTO localities_rt SELECT ?1 + id, lat, lat, lon, lon FROM t.localities");
        run("INSERT INTO localities_fts(rowid, name, alt_names) SELECT ?1 + id, name, alt_names FROM t.localities");
        c.execute(
            "INSERT INTO localities_ctx(id, tile, name, kind, lat, lon, population, state, country, source_id) \
             SELECT ?1 + id, ?2, name, kind, lat, lon, population, state, country, source_id FROM t.localities_ctx",
            params![base, t],
        )
        .unwrap();
        run("INSERT INTO addr_streets(id, uid, street, street_expanded, locality, postal_city, postcode, state, country, lat, lon, \
             min_lat, max_lat, min_lon, max_lon, n, numbers) SELECT ?1 + id, uid, street, street_expanded, locality, postal_city, postcode, state, \
             country, lat, lon, min_lat, max_lat, min_lon, max_lon, n, numbers FROM t.addr_streets");
        run("INSERT INTO addr_rt SELECT ?1 + id, min_lat, max_lat, min_lon, max_lon FROM t.addr_streets");
        run("INSERT INTO addr_fts(rowid, street, street_expanded) SELECT ?1 + id, street, street_expanded FROM t.addr_streets");
        run("INSERT INTO vectors(kind, ref, vec) SELECT kind, CAST(?1 + ref AS TEXT), vec FROM t.vectors");
        c.execute("INSERT INTO tile_counts SELECT ?1, what, id, n FROM t.tile_counts", params![t]).unwrap();
        c.execute("INSERT INTO tiles VALUES (?1, ?2, 'sha', 0, 0)", params![t, tile_path_l1(t)]).unwrap();
        c.execute("DETACH t", []).unwrap();
    }
    c.execute_batch(
        "UPDATE categories SET place_count = COALESCE((SELECT SUM(n) FROM tile_counts WHERE what = 'category' AND id = categories.id), 0);
         UPDATE kinds SET place_count = COALESCE((SELECT SUM(n) FROM tile_counts WHERE what = 'kind' AND id = kinds.id), 0);",
    )
    .unwrap();
    if tiles.is_empty() {
        bbox = [0.0, 0.0, 0.0, 0.0];
    }
    for (k, v) in [
        ("format_version", MERGED_FORMAT_VERSION.to_string()),
        ("kind", "merged".into()),
        ("region_id", "device".into()),
        ("region_name", "Test".into()),
        ("min_lat", bbox[0].to_string()),
        ("min_lon", bbox[1].to_string()),
        ("max_lat", bbox[2].to_string()),
        ("max_lon", bbox[3].to_string()),
    ] {
        c.execute("INSERT OR REPLACE INTO meta(key, value) VALUES (?1, ?2)", params![k, v]).unwrap();
    }
    db
}

fn geo(db: &Path) -> PackGeocoder {
    PackGeocoder::new(Arc::new(PackSet::new(vec![db.to_path_buf()])))
}

fn core(db: &Path) -> PlacesCore {
    PlacesCore::new(&PlacesCfg { packs: vec![db.to_string_lossy().into_owned()] })
}

fn search(c: &PlacesCore, q: &str, opts: SearchOpts) -> Value {
    c.search(q, &opts, None).unwrap()
}

fn near(p: (f64, f64)) -> SearchOpts {
    SearchOpts { near: Some(p), ..Default::default() }
}

#[test]
fn the_merged_fixture_opens_as_a_pack() {
    let t = Tmp::new("open");
    let db = merged(&t.0, None);
    let set = PackSet::new(vec![db]);
    let packs = set.current();
    assert_eq!(packs.len(), 1);
    assert_eq!(packs[0].format, 3);
    assert!(packs[0].has_addresses());
    assert_eq!(packs[0].category("pharmacy").unwrap().place_count, 3);
}

#[test]
fn an_exact_number_with_the_street_in_either_form() {
    let t = Tmp::new("exact");
    let g = geo(&merged(&t.0, None));
    // The data has "Overland Ave" (expanded "Overland Avenue") and "W 10TH ST" (expanded "WEST 10TH STREET").
    for q in ["1414 Overland Ave, Burley", "1414 Overland Avenue, Burley", "1414 overland ave, burley, id", "1414 Overland Av"] {
        let h = &g.forward(q, None, 5)[0];
        assert_eq!(h.kind, HitKind::Address, "{q}");
        assert_eq!(h.name, "1414 Overland Ave", "{q}");
        assert_eq!(h.label, "1414 Overland Ave, Burley, ID", "{q}");
        assert!(h.address.starts_with("addr:") && h.address.ends_with("/1414"), "{}", h.address);
        assert!((h.lat - 42.5390).abs() < 1e-6 && (h.lon + 113.7870).abs() < 1e-6, "{q}");
        assert!(!h.approximate && h.name_match == 100.0);
        assert_eq!((h.kind_id.as_deref(), h.kind_label.as_deref(), h.street.as_deref()), (Some("address"), Some("Address"), Some("Overland Ave")));
    }
    for q in ["200 W 10th St, Burley", "200 W 10th Street, Burley", "200 West 10th Street, Burley, Idaho", "200 W 10TH ST"] {
        let h = &g.forward(q, Some(BURLEY), 3)[0];
        assert_eq!((h.kind, h.name.as_str(), h.approximate), (HitKind::Address, "200 W 10TH ST", false), "{q}");
        assert!((h.lat - 42.5350).abs() < 1e-6 && (h.lon + 113.7930).abs() < 1e-6, "{q}");
    }
    // A lettered number, in any letter case.
    let h = &g.forward("1420a Overland Ave, Burley", None, 1)[0];
    assert_eq!((h.name.as_str(), h.approximate), ("1420A Overland Ave", false));
}

#[test]
fn a_number_between_known_numbers_is_placed_on_its_side_of_the_street() {
    let t = Tmp::new("interp");
    let g = geo(&merged(&t.0, None));
    // Evens 1410 and 1414: 1412 is half way. Odds 1405 and 1415: 1407 is a fifth of the way.
    let h = &g.forward("1412 Overland Avenue, Burley", None, 1)[0];
    assert_eq!((h.kind, h.name.as_str(), h.approximate, h.name_match), (HitKind::Address, "1412 Overland Ave", true, 70.0));
    let lat1410 = 42.5300 + 410.0 / 500.0 * 0.02;
    assert!((h.lat - (lat1410 + 42.5390) / 2.0).abs() < 2e-6 && (h.lon + (113.7872 + 113.7870) / 2.0).abs() < 2e-6, "{} {}", h.lat, h.lon);
    let h = &g.forward("1407 Overland Ave, Burley", None, 1)[0];
    let (lo, hi) = (42.5300 + 400.0 / 500.0 * 0.02 + 0.0001, 42.5300 + 410.0 / 500.0 * 0.02 + 0.0001);
    assert!(h.approximate && (h.lat - (lo + 0.2 * (hi - lo))).abs() < 2e-6 && (h.lon + 113.7868).abs() < 1e-6, "{}", h.lat);
    // Beyond the last number there is nothing to place it between: no address, the name search runs instead.
    assert!(g.forward("9999 Overland Ave, Burley", None, 3).iter().all(|h| h.kind != HitKind::Address));
}

#[test]
fn a_street_cut_by_a_tile_edge_is_one_street() {
    let t = Tmp::new("edge");
    let db = merged(&t.0, None);
    let set = PackSet::new(vec![db.clone()]);
    let packs = set.current();
    let p = &packs[0];
    assert_eq!(p.fts_streets("\"baseline\"", 10).unwrap().len(), 2, "two rows, one per tile");
    let g = geo(&db);
    // 2040 is west of 113 W, 2050 east of it: 2044 lies between the two rows.
    let h = &g.forward("2044 Baseline Rd, Burley", None, 3)[0];
    assert!(h.kind == HitKind::Address && h.approximate, "{h:?}");
    assert!(h.lon > -113.002 && h.lon < -113.0, "{}", h.lon);
    // The two rows give one result, not one per tile.
    assert_eq!(g.forward("2050 Baseline Road, Burley", None, 5).iter().filter(|h| h.kind == HitKind::Address).count(), 1);
}

#[test]
fn the_town_after_the_comma_filters_the_streets() {
    let t = Tmp::new("area");
    let g = geo(&merged(&t.0, None));
    // A town 15 km away is still Burley's (Heyburn is about 3 km away); a far town is not.
    assert_eq!(g.forward("1414 Overland Ave, Heyburn", None, 1)[0].kind, HitKind::Address);
    assert!(g.forward("1414 Overland Ave, Stanley", None, 3).iter().all(|h| h.kind != HitKind::Address));
    // A misspelt town still resolves.
    assert_eq!(g.forward("1414 Overland Ave, Burly", None, 1)[0].kind, HitKind::Address);
    // Another state: nothing.
    assert!(g.forward("1414 Overland Ave, Burley, ND", None, 3).iter().all(|h| h.kind != HitKind::Address));
}

#[test]
fn a_name_that_starts_with_a_number_is_still_a_name() {
    let t = Tmp::new("seven");
    let db = merged(&t.0, None);
    {
        let c = Connection::open(&db).unwrap();
        let id = merged_id(tile_id_l1(BURLEY.0, BURLEY.1), 9000);
        c.execute(
            "INSERT INTO places(id, name, kind, kind_id, lat, lon, locality, state, source, source_id) VALUES (?1, '7 Eleven', 'shop=convenience', 'convenience', 42.5401, -113.7901, 'Burley', 'ID', 'osm', 'osm:n7')",
            params![id],
        )
        .unwrap();
        c.execute("INSERT INTO places_rt VALUES (?1, 42.5401, 42.5401, -113.7901, -113.7901)", params![id]).unwrap();
        c.execute("INSERT INTO places_fts(rowid, name, alt_names) VALUES (?1, '7 Eleven', '')", params![id]).unwrap();
    }
    let g = geo(&db);
    let h = &g.forward("7 Eleven", Some(BURLEY), 3)[0];
    assert_eq!((h.kind, h.name.as_str()), (HitKind::Place, "7 Eleven"));
    assert_eq!(g.forward("500 Walgreens", Some(BURLEY), 3)[0].name, "Walgreens");
    // A single-region pack has no streets: the address step is skipped.
    let legacy = t.0.join("legacy.sqlite");
    write_fixture_pack(&legacy);
    assert!(geo(&legacy).forward("1414 Overland Ave, Burley", None, 3).iter().all(|h| h.kind != HitKind::Address));
}

#[test]
fn address_ids_route_and_locate() {
    let t = Tmp::new("lookup");
    let db = merged(&t.0, None);
    let c = core(&db);
    let g = geo(&db);
    for q in ["1414 Overland Ave, Burley", "1412 Overland Ave, Burley", "2044 Baseline Rd, Burley"] {
        let h = &g.forward(q, None, 1)[0];
        let e = c.lookup(&h.address).unwrap_or_else(|| panic!("{}", h.address));
        assert!((e.lat - h.lat).abs() < 1e-9 && (e.lon - h.lon).abs() < 1e-9, "{q}");
        assert_eq!(e.name.as_deref(), Some(h.name.as_str()));
        assert_eq!(c.resolve_text(q, None).unwrap().id.as_deref(), Some(h.address.as_str()));
    }
    assert!(c.lookup("addr:0000000000000000/1").is_none());
    assert!(c.lookup(&format!("{}9", g.forward("1414 Overland Ave, Burley", None, 1)[0].address)).is_none(), "14149 is beyond the street");

    let ts = tools(&PlacesCfg { packs: vec![db.to_string_lossy().into_owned()] });
    let locate = ts.iter().find(|t| t.name() == "locate").unwrap();
    let ctx = ToolCtx { location: None, places: &NoSavedPlaces, now: FIXTURE_NOW, geocoder: None, live_fetcher: None };
    let Ok(ToolOutput::Json(v)) = locate.run(&ctx, &json!({"place": "1414 Overland Avenue, Burley"})) else { panic!("locate") };
    assert_eq!(v["kind"], "address");
    assert_eq!(v["place_name"], "1414 Overland Ave, Burley, ID");
    assert!(v["address"].as_str().unwrap().starts_with("addr:"));
    assert_eq!((v["lat"].as_f64(), v["nearest_town"].as_str()), (Some(42.539), Some("Burley, ID")));
}

#[test]
fn map_search_gives_address_rows() {
    let t = Tmp::new("map");
    let c = core(&merged(&t.0, None));
    let v = search(&c, "1414 Overland Ave, Burley", near(BURLEY));
    let r = &v["results"][0];
    assert_eq!((r["type"].as_str(), r["kind"].as_str(), r["kind_id"].as_str()), (Some("address"), Some("Address"), Some("address")), "{v}");
    assert_eq!((r["name"].as_str(), r["address"].as_str()), (Some("1414 Overland Ave"), Some("1414 Overland Ave, Burley, ID")));
    assert!(r["id"].as_str().unwrap().starts_with("addr:") && r.get("approximate").is_none());
    let v = search(&c, "1412 Overland Avenue", near(BURLEY));
    assert_eq!((v["results"][0]["type"].as_str(), v["results"][0]["approximate"].as_bool()), (Some("address"), Some(true)), "{v}");
    assert_eq!(v["places"], json!({"installed": true, "covers": true, "pending": 0}));
    assert!(v.get("warning_code").is_none());
}

#[test]
fn warning_codes() {
    let t = Tmp::new("warn");
    let code = |v: &Value| v.get("warning_code").and_then(Value::as_str).map(str::to_string);
    // Nothing installed at all.
    let none = PlacesCore::new(&PlacesCfg { packs: vec![t.0.join("missing.sqlite").to_string_lossy().into_owned()] });
    let v = search(&none, "pharmacy", near(BURLEY));
    assert_eq!((code(&v).as_deref(), v["warning"].as_str()), (Some("no_places"), Some("no places data is installed")));
    assert_eq!(v["places"], json!({"installed": false, "covers": false, "pending": 0}));
    let offline = PrepareAnswer { ok: false, ..Default::default() };
    assert_eq!(code(&search(&none, "pharmacy", SearchOpts { prepared: Some(offline), ..near(BURLEY) })).as_deref(), Some("no_places"));
    let arriving = PrepareAnswer { pending: 1, ok: true, ..Default::default() };
    let v = search(&none, "pharmacy", SearchOpts { prepared: Some(arriving), ..near(BURLEY) });
    assert_eq!((code(&v).as_deref(), &v["places"]["pending"]), (Some("fetching"), &json!(1)));

    // A merged database with no tiles is nothing installed.
    let empty_dir = t.0.join("empty");
    std::fs::create_dir_all(&empty_dir).unwrap();
    let empty = core(&merged(&empty_dir, Some(&[][..])));
    assert_eq!(code(&search(&empty, "pharmacy", near(BURLEY))).as_deref(), Some("no_places"));

    // Burley's tile only: Burley is covered, Boise is not.
    let burley = core(&merged(&t.0, Some(&[tile_id_l1(BURLEY.0, BURLEY.1)][..])));
    let v = search(&burley, "pharmacy", near(BURLEY));
    assert_eq!((code(&v), &v["places"]["covers"]), (None, &json!(true)), "{v}");
    assert_eq!(v["results"][0]["id"], "category:pharmacy");
    let v = search(&burley, "hospital", near(BOISE));
    assert_eq!((code(&v).as_deref(), &v["places"]["installed"], &v["places"]["covers"]), (Some("not_here"), &json!(true), &json!(false)), "{v}");
    assert_eq!(code(&search(&burley, "hospital", SearchOpts { prepared: Some(offline), ..near(BOISE) })).as_deref(), Some("not_here"));
    assert_eq!(code(&search(&burley, "hospital", SearchOpts { prepared: Some(arriving), ..near(BOISE) })).as_deref(), Some("fetching"));
    // The feed fetched everything there is around Boise (none of it on the phone yet): nothing to warn about.
    let done = PrepareAnswer { ok: true, ..Default::default() };
    assert_eq!(code(&search(&burley, "hospital", SearchOpts { prepared: Some(done), ..near(BOISE) })), None);
    // A single-region pack covers its box, as before.
    let legacy = t.0.join("legacy.sqlite");
    write_fixture_pack(&legacy);
    let lc = core(&legacy);
    assert_eq!(code(&search(&lc, "hospital", near(BOISE))), None);
    assert_eq!(code(&search(&lc, "hospital", near((40.76, -111.89)))).as_deref(), Some("not_here"));
}

#[test]
fn kinds_matched_by_meaning_give_rows_and_their_places() {
    let t = Tmp::new("kinds");
    let c = core(&merged(&t.0, None));
    let kind_vec = |text: &str| Some((FAKE_MODEL.to_string(), fake_embed(text)));
    // The vector of the water body kind's own text, for a query with no word of any category in it.
    let opts = SearchOpts { vector: kind_vec("Lake or other water body: a lake, pond, reservoir or river; not a drinking water source"), ..near(STANLEY) };
    let v = search(&c, "zzqx", opts);
    let r = &v["results"][0];
    assert_eq!((r["id"].as_str(), r["type"].as_str(), r["name"].as_str(), r["matched"].as_str()), (Some("kind:water_body"), Some("category"), Some("Lake or other water body"), Some("meaning")), "{v}");
    assert!(r["category"].is_null());
    assert_eq!(v["meaning"], "used");
    let names: Vec<&str> = v["results"].as_array().unwrap().iter().filter_map(|r| r["name"].as_str()).collect();
    assert!(names.contains(&"Water Hole Lake") && names.contains(&"Stanley Lake"), "{names:?}");

    // A kind whose category is matched too is folded into the category's row.
    let opts = SearchOpts { vector: kind_vec("Drinking water tap: a tap, fountain or pump that the map data marks as drinking water"), ..near(STANLEY) };
    let v = search(&c, "water", opts);
    let ids: Vec<&str> = v["results"].as_array().unwrap().iter().filter_map(|r| r["id"].as_str()).collect();
    assert!(ids.contains(&"category:water") && !ids.iter().any(|i| i.starts_with("kind:")), "{ids:?}");

    // A kind id is a route end: the nearest place of that kind to the centre.
    let e = c.lookup_near("kind:water_body", Some(STANLEY)).unwrap();
    assert_eq!(e.name.as_deref(), Some("Water Hole Lake"));
    assert!(c.lookup("kind:water_body").is_none(), "no centre, no nearest");
    assert!(c.lookup_near("kind:nope", Some(STANLEY)).is_none());
}
