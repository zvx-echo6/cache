//! The map's search box over the small fixture pack: every kind of query, the ranking, the card details, the meaning step
//! with a stand-in embedder (plumbing only: real quality is measured with bge-m3 on the Idaho pack).

use cache_places::fixture::{fake_embed, write_fixture_pack, write_fixture_pack_with_vectors, FAKE_MODEL};
use cache_places::map::{parse_request, SearchOpts};
use cache_places::{PlacesCfg, PlacesCore};
use serde_json::{json, Value};
use std::path::PathBuf;

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cp-map-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Tmp(p)
    }
    fn pack(&self) -> PathBuf {
        self.0.join("places.sqlite")
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn core(t: &Tmp) -> PlacesCore {
    PlacesCore::new(&PlacesCfg { packs: vec![t.pack().to_string_lossy().into_owned()], merged_dir: None })
}

fn search(c: &PlacesCore, q: &str, near: Option<(f64, f64)>) -> Value {
    c.search(q, &SearchOpts { near, ..Default::default() }, None).unwrap()
}

fn names(v: &Value) -> Vec<String> {
    v["results"].as_array().unwrap().iter().map(|r| r["name"].as_str().unwrap().to_string()).collect()
}

const BURLEY: (f64, f64) = (42.5357, -113.7928);
const STANLEY: (f64, f64) = (44.2210, -114.9360);

#[test]
fn coordinates_in_every_format_give_one_result_with_all_formats() {
    let t = Tmp::new("coords");
    write_fixture_pack(&t.pack());
    let c = core(&t);
    let usng = cache_places::coord::usng(43.6, -116.2).unwrap();
    for (q, fmt) in [
        ("43.6,-116.2", "decimal"),
        ("43.6 -116.2", "decimal"),
        ("43\u{b0}36'0\"N 116\u{b0}12'0\"W", "dms"),
        (usng.as_str(), "usng"),
    ] {
        let v = search(&c, q, Some(BURLEY));
        let r = &v["results"].as_array().unwrap();
        assert_eq!(r.len(), 1, "{q}");
        assert_eq!(v["interpreted"]["kind"], "coordinates");
        assert_eq!(r[0]["type"], "coordinates");
        assert_eq!(r[0]["format"], fmt, "{q}");
        for k in ["decimal", "dms", "usng", "plus_code"] {
            assert!(r[0]["formats"][k].is_string(), "{q}: {k}");
        }
        assert!(r[0]["distance_m"].as_i64().unwrap() > 100_000);
        assert!(r[0]["id"].as_str().unwrap().starts_with("loc:"));
    }
    // the usng and plus code the result prints read back to the same point
    let v = search(&c, "43.6,-116.2", None);
    let formats = &v["results"][0]["formats"];
    for k in ["usng", "plus_code", "dms"] {
        let back = search(&c, formats[k].as_str().unwrap(), None);
        let (la, lo) = (back["results"][0]["lat"].as_f64().unwrap(), back["results"][0]["lon"].as_f64().unwrap());
        assert!((la - 43.6).abs() < 0.001 && (lo + 116.2).abs() < 0.001, "{k}: {la},{lo}");
    }
    // a short Plus Code is completed from the map centre
    let code = formats["plus_code"].as_str().unwrap();
    let short = &code[4..];
    let v = search(&c, short, Some((43.62, -116.21)));
    assert!((v["results"][0]["lat"].as_f64().unwrap() - 43.6).abs() < 0.001, "{short}");
}

#[test]
fn a_town_name_finds_the_town_first() {
    let t = Tmp::new("town");
    write_fixture_pack(&t.pack());
    let c = core(&t);
    let v = search(&c, "Stanley", Some(BURLEY));
    let r = &v["results"][0];
    assert_eq!((r["name"].as_str(), r["type"].as_str(), r["state"].as_str()), (Some("Stanley"), Some("town"), None));
    assert_eq!(r["matched"], "name");
    assert_eq!(r["address"], "ID");
    assert!(r["id"].as_str().unwrap().starts_with("town:"));
    // north of Burley, 190 km or so
    assert_eq!(r["direction"], "NW");
    let d = r["distance_m"].as_i64().unwrap();
    assert!((180_000..230_000).contains(&d), "{d}");
    // Burley the town beats Burley Elementary School and the convenience store called Burley
    let v = search(&c, "Burley", None);
    assert_eq!(v["results"][0]["type"], "town");
}

#[test]
fn a_category_gives_its_row_then_the_nearest_places_from_the_anchor_town() {
    let t = Tmp::new("category");
    write_fixture_pack(&t.pack());
    let c = core(&t);
    let v = search(&c, "pharmacy near Burley", Some((43.6, -116.2)));
    assert_eq!(v["interpreted"]["anchor"]["name"], "Burley");
    assert_eq!(v["interpreted"]["categories"], json!(["pharmacy"]));
    let r = v["results"].as_array().unwrap();
    assert_eq!(r[0]["type"], "category");
    assert_eq!(r[0]["id"], "category:pharmacy");
    let place_names: Vec<&str> = r.iter().filter(|x| x["type"] == "place").map(|x| x["name"].as_str().unwrap()).collect();
    // ranked from Burley, not from the map centre in Boise; Rupert Drug is the farthest of the three
    assert_eq!(place_names, vec!["Walgreens", "Smith's Pharmacy", "Rupert Drug"]);
    assert!(r[1]["distance_m"].as_i64().unwrap() > 150_000, "distance is from the map centre");
    assert_eq!(r[1]["phone"], "+1 208 678 3050");
    assert_eq!(r[1]["hours"], "Mo-Su 08:00-22:00");
    assert_eq!(r[1]["address"], "1414 Overland Ave, Burley, ID");
    assert_eq!(r[1]["matched"], "category");
    assert!(r[1]["id"].as_str().unwrap().starts_with("place:"));
    // without a town in the query it is the map centre that counts
    let v = search(&c, "pharmacy", Some(BURLEY));
    assert_eq!(v["results"][1]["name"], "Walgreens");
    // plurals and words from the description
    for q in ["pharmacies", "drug stores", "gas stations", "gas"] {
        let v = search(&c, q, Some(BURLEY));
        assert_eq!(v["results"][0]["type"], "category", "{q}: {v}");
    }
    assert_eq!(search(&c, "gas stations", Some(BURLEY))["results"][0]["id"], "category:fuel");
}

#[test]
fn an_anchor_can_be_a_small_place_but_not_a_word_the_categories_use() {
    let t = Tmp::new("anchor");
    write_fixture_pack(&t.pack());
    let c = core(&t);
    // Lowman is a hamlet in the fixture; "near Lowman" still anchors the search there
    let v = search(&c, "pharmacy near Lowman", Some(BURLEY));
    assert_eq!(v["interpreted"]["anchor"]["name"], "Lowman", "{v}");
    // the pharmacies come nearest-first from Lowman, not from Burley
    let places: Vec<&str> = v["results"].as_array().unwrap().iter().filter(|r| r["type"] == "place").map(|r| r["name"].as_str().unwrap()).collect();
    assert_eq!(places.len(), 3);
    // a run of words the categories themselves use is not read as a place name
    let v = search(&c, "water", Some(BURLEY));
    assert!(v["interpreted"]["anchor"].is_null());
    // the town named with a state: "Stanley ID" is a name, not an anchor
    let v = search(&c, "Stanley ID", Some(BURLEY));
    assert_eq!(v["results"][0]["type"], "town");
}

#[test]
fn a_name_with_a_town_finds_the_place() {
    let t = Tmp::new("nametown");
    write_fixture_pack(&t.pack());
    let c = core(&t);
    for q in ["Walgreens Burley", "Walgreens, Burley", "Walgreens"] {
        let v = search(&c, q, Some(STANLEY));
        assert_eq!(v["results"][0]["name"], "Walgreens", "{q}: {v}");
    }
    let v = search(&c, "Cassia Regional", Some(BURLEY));
    assert_eq!(v["results"][0]["name"], "Cassia Regional Hospital");
    assert_eq!(v["results"][0]["kind"], "Hospital");
    // an alternative name
    let v = search(&c, "Cassia Regional Medical Center", None);
    assert_eq!(v["results"][0]["name"], "Cassia Regional Hospital");
    // nothing matches
    let v = search(&c, "zzzzqqq", None);
    assert!(v["results"].as_array().unwrap().is_empty());
    assert_eq!(search(&c, "   ", None)["interpreted"]["kind"], "empty");
}

#[test]
fn a_name_many_places_share_finds_the_nearest() {
    let t = Tmp::new("chain");
    write_fixture_pack(&t.pack());
    // a chain with more stores than the text search reads (all with the same text score), the one near Burley added last
    let db = rusqlite::Connection::open(t.pack()).unwrap();
    for i in 0..121i64 {
        let (id, lat, lon) = if i < 120 { (1000 + i, 47.0 + i as f64 * 0.01, -116.5) } else { (1000 + i, 42.5370, -113.7900) };
        db.execute(
            "INSERT INTO places(id, name, category, kind, kind_id, lat, lon, state, country, source, source_id) \
             VALUES (?1, 'Maverik', 'fuel', 'amenity=fuel', 'fuel', ?2, ?3, 'ID', 'US', 'osm', ?4)",
            rusqlite::params![id, lat, lon, format!("osm:n{id}")],
        )
        .unwrap();
        db.execute("INSERT INTO places_rt(id, min_lat, max_lat, min_lon, max_lon) VALUES (?1, ?2, ?2, ?3, ?3)", rusqlite::params![id, lat, lon]).unwrap();
        db.execute("INSERT INTO places_fts(rowid, name, alt_names) VALUES (?1, 'Maverik', '')", rusqlite::params![id]).unwrap();
    }
    drop(db);
    let c = core(&t);
    let v = search(&c, "Maverik", Some(BURLEY));
    let r = &v["results"][0];
    assert_eq!(r["name"], "Maverik", "{v}");
    assert!(r["distance_m"].as_i64().unwrap() < 1000, "{v}");
    // the geocoder behind locate and navigate too
    let g = cache_places::PackGeocoder::new(std::sync::Arc::new(cache_places::PackSet::new(vec![t.pack()], None)));
    let h = &cache_places::Geocoder::forward(&g, "Maverik", Some(BURLEY), 3)[0];
    assert!((h.lat - 42.5370).abs() < 1e-6, "{h:?}");
}

#[test]
fn meaning_search_uses_the_pack_vectors_and_says_when_it_cannot() {
    let t = Tmp::new("meaning");
    write_fixture_pack_with_vectors(&t.pack());
    let c = core(&t);
    let embed = |q: &str| Some((FAKE_MODEL.to_string(), fake_embed(q)));
    let opts = SearchOpts { near: Some(STANLEY), ..Default::default() };
    // words of the category text and of a summary: the category row, its places, and the place whose summary says so
    let v = c.search("somewhere to refill drinking water", &opts, Some(&embed)).unwrap();
    assert_eq!(v["meaning"], "used", "{v}");
    let r = v["results"].as_array().unwrap();
    assert_eq!(r[0]["id"], "category:water", "{v}");
    // a query with no word in common with any category, but a vector that is close to the water category: found by meaning
    let far = SearchOpts { near: Some(STANLEY), vector: Some((FAKE_MODEL.into(), fake_embed("drinking water springs"))), ..Default::default() };
    let v2 = c.search("agua", &far, None).unwrap();
    assert_eq!(v2["results"][0]["id"], "category:water", "{v2}");
    assert_eq!(v2["results"][0]["matched"], "meaning", "{v2}");
    assert!(v2["results"].as_array().unwrap().iter().any(|x| x["name"] == "Sawtooth Spring"));
    assert!(r.iter().any(|x| x["name"] == "Sawtooth Spring"), "{v}");
    // the summary and the Wikipedia title travel with the result
    let spring = r.iter().find(|x| x["name"] == "Sawtooth Spring").unwrap();
    assert!(spring["summary"].as_str().unwrap().contains("spring"));
    assert_eq!(spring["wikipedia_title"], "Sawtooth Spring");
    // a query vector given by the caller is used as it is
    let given = SearchOpts { near: Some(STANLEY), vector: Some((FAKE_MODEL.into(), fake_embed("drinking water springs"))), ..Default::default() };
    assert_eq!(c.search("anything", &given, None).unwrap()["meaning"], "used");
    // no embedder, a vector of another model, meaning switched off
    assert_eq!(c.search("somewhere to refill drinking water", &opts, None).unwrap()["meaning"], "no_embedder");
    let other = |q: &str| Some(("some-other-model".to_string(), fake_embed(q)));
    assert_eq!(c.search("somewhere to refill drinking water", &opts, Some(&other)).unwrap()["meaning"], "model_mismatch");
    let off = SearchOpts { near: Some(STANLEY), meaning: false, ..Default::default() };
    assert_eq!(c.search("somewhere to refill drinking water", &off, Some(&embed)).unwrap()["meaning"], "off");
    // a pack that was never embedded
    let t2 = Tmp::new("novec");
    write_fixture_pack(&t2.pack());
    let c2 = core(&t2);
    assert_eq!(c2.search("somewhere to refill drinking water", &opts, Some(&embed)).unwrap()["meaning"], "no_vectors");
    // keyword search still answers when meaning cannot: "water" is the category's own title
    let v = c2.search("water", &opts, Some(&embed)).unwrap();
    assert_eq!(v["results"][0]["id"], "category:water");
}

#[test]
fn ids_come_back_as_ends_and_requests_are_checked() {
    let t = Tmp::new("ids");
    write_fixture_pack(&t.pack());
    let c = core(&t);
    let v = search(&c, "Walgreens", None);
    let id = v["results"][0]["id"].as_str().unwrap();
    let e = c.lookup(id).unwrap();
    assert_eq!(e.name.as_deref(), Some("Walgreens"));
    assert_eq!(e.osm_category.as_deref(), Some("amenity:pharmacy"));
    assert!((e.lat - 42.539).abs() < 1e-6);
    let town = search(&c, "Stanley", None);
    let e = c.lookup(town["results"][0]["id"].as_str().unwrap()).unwrap();
    assert_eq!(e.name.as_deref(), Some("Stanley"));
    assert!(c.lookup("place:nope").is_none());
    assert!(c.resolve_text("43.6,-116.2", None).is_some());
    assert_eq!(c.resolve_text("Cassia Regional", None).unwrap().name.as_deref(), Some("Cassia Regional Hospital"));

    assert!(parse_request(&json!({"query": "x", "limit": 0})).is_err());
    assert!(parse_request(&json!({"query": "x", "bogus": 1})).is_err());
    assert!(parse_request(&json!({"limit": 3})).is_err());
    assert!(parse_request(&json!({"query": "x", "near": {"lat": 99.0, "lon": 0.0}})).is_err());
    let (q, o) = parse_request(&json!({"query": "x", "near": {"lat": 1.0, "lon": 2.0}, "limit": 4, "meaning": false})).unwrap();
    assert_eq!((q.as_str(), o.near, o.limit, o.meaning), ("x", Some((1.0, 2.0)), 4, false));
}
