//! nearby, locate and the geocoder on the fixture pack.

use cache_places::fixture::{write_fixture_pack, FIXTURE_NOW};
use cache_places::{tools, Geocoder, PackGeocoder, PackSet, PlacesCfg};
use cache_tool::{Location, NoSavedPlaces, SavedPlace, SavedPlaces, Tool, ToolCtx, ToolOutput};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;

struct Dir(PathBuf);
impl Dir {
    fn new(name: &str) -> Dir {
        let p = std::env::temp_dir().join(format!("cp-test-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Dir(p)
    }
}
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn setup(name: &str) -> (Dir, Vec<Box<dyn Tool>>, String) {
    let d = Dir::new(name);
    let pack = d.0.join("places.sqlite");
    write_fixture_pack(&pack);
    let path = pack.to_string_lossy().into_owned();
    (d, tools(&PlacesCfg { packs: vec![path.clone()], merged_dir: None }), path)
}

fn tool<'a>(ts: &'a [Box<dyn Tool>], n: &str) -> &'a dyn Tool {
    ts.iter().find(|t| t.name() == n).unwrap().as_ref()
}

fn loc(lat: f64, lon: f64) -> Location {
    Location { lat, lon, accuracy_m: Some(12.0), fixed_at: "2026-10-25T14:20:05-06:00".into() }
}

fn run(t: &dyn Tool, location: Option<&Location>, args: Value) -> Value {
    let ctx = ToolCtx { location, places: &NoSavedPlaces, now: FIXTURE_NOW, geocoder: None, live_fetcher: None };
    match t.run(&ctx, &args) {
        Ok(ToolOutput::Json(v)) => v,
        Ok(ToolOutput::Text(_)) => panic!("text"),
        Err(e) => e.to_json(),
    }
}

fn s(v: &Value) -> String {
    serde_json::to_string(v).unwrap()
}

#[test]
fn nearby_pharmacy_around_burley() {
    let (_d, ts, _) = setup("n1");
    let v = run(tool(&ts, "nearby"), None, json!({"category": "pharmacy", "near": "Burley, Idaho"}));
    assert_eq!(v["category"], "pharmacy");
    assert_eq!(v["center"], "Burley, ID");
    assert_eq!(v["ranked_by"], "distance");
    let p = &v["places"][0];
    assert_eq!(p["name"], "Walgreens");
    assert_eq!(p["street"], "1414 Overland Ave");
    assert_eq!(p["phone"], "+1 208 678 3050");
    assert_eq!(p["hours"], "Mo-Su 08:00-22:00");
    assert_eq!(p["address"], "place:osm:n1");
    assert_eq!(v["places"][1]["name"], "Smith's Pharmacy");
    assert!(v["places"][1].get("phone").is_none() && v["places"][1].get("street").is_none());
    assert_eq!(v["places"].as_array().unwrap().len(), 3);
    assert_eq!(v["map_region"], "Idaho");
    assert_eq!(v["map_region_age"], "12 days old");
    // Field order is TOOLS.md's.
    let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
    assert_eq!(keys, ["category", "center", "ranked_by", "places", "map_region", "map_region_age"]);
    let pk: Vec<&String> = p.as_object().unwrap().keys().collect();
    assert_eq!(pk, ["address", "name", "kind", "kind_label", "street", "locality", "state", "distance_mi", "direction", "phone", "hours"]);
    assert_eq!((p["kind"].as_str(), p["kind_label"].as_str()), (Some("pharmacy"), Some("Pharmacy")));
}

#[test]
fn nearby_er_from_the_phone_location() {
    let (_d, ts, _) = setup("n2");
    let l = loc(43.828, -115.834);
    let v = run(tool(&ts, "nearby"), Some(&l), json!({"category": "emergency_room", "limit": 2}));
    assert_eq!(v["center"], "current location");
    assert_eq!(v["places"][0]["name"], "St. Luke's Boise Medical Center");
    assert_eq!(v["places"][0]["direction"], "SW");
    assert_eq!(v["places"][0]["er_tier"], "confirmed");
    assert!(v["places"][0].get("note").is_none());
    assert_eq!(v["places"].as_array().unwrap().len(), 2);
}

#[test]
fn emergency_rooms_confirmed_first_and_likely_hospitals_when_clearly_closer() {
    let (_d, ts, _) = setup("n6");
    let n = tool(&ts, "nearby");
    // Burley: no emergency room on file, but a hospital 0.6 mi away and another 8 mi away, both "likely"; the confirmed
    // ones (Twin Falls, Boise) are far. A hospital that an emergency room row stands for is not listed twice.
    let l = loc(42.536, -113.792);
    let v = run(n, Some(&l), json!({"category": "emergency_room", "limit": 5}));
    let seen: Vec<(String, String)> = v["places"].as_array().unwrap().iter().map(|p| (p["name"].as_str().unwrap().into(), p["er_tier"].as_str().unwrap().into())).collect();
    assert_eq!(
        seen,
        [
            ("Cassia Regional Hospital".to_string(), "likely".to_string()),
            ("Heyburn Hospital".into(), "likely".into()),
            ("Minidoka Memorial Hospital".into(), "likely".into()),
            ("St. Luke's Magic Valley Regional Medical Center".into(), "confirmed".into()),
            ("St. Luke's Boise Medical Center".into(), "confirmed".into()),
        ]
    );
    assert_eq!(v["places"][0]["note"], "hospital, likely has an emergency room");
    assert!(v["places"][3].get("note").is_none());

    // Between Twin Falls and Heyburn: the likely hospital is nearer, but by about 7 mi, less than the 10 mi margin, so the
    // confirmed emergency room stays first. A little further east it is nearer by about 14 mi and goes first.
    let mid = loc(42.56, -114.05);
    let v = run(n, Some(&mid), json!({"category": "emergency_room", "limit": 2}));
    assert_eq!((v["places"][0]["name"].as_str().unwrap(), v["places"][0]["er_tier"].as_str().unwrap()), ("St. Luke's Magic Valley Regional Medical Center", "confirmed"));
    assert_eq!(v["places"][1]["name"], "Cassia Regional Hospital");
    let mid = loc(42.56, -113.98);
    let v = run(n, Some(&mid), json!({"category": "emergency_room", "limit": 2}));
    assert_eq!((v["places"][0]["name"].as_str().unwrap(), v["places"][0]["er_tier"].as_str().unwrap()), ("Cassia Regional Hospital", "likely"));

    // Other categories have no tiers.
    let v = run(n, Some(&l), json!({"category": "hospital", "limit": 1}));
    assert!(v["places"][0].get("er_tier").is_none());
}

#[test]
fn nearby_errors() {
    let (_d, ts, _) = setup("n3");
    let n = tool(&ts, "nearby");
    assert_eq!(run(n, None, json!({"category": "fuel"}))["error"]["type"], "no_location");
    assert_eq!(run(n, None, json!({"category": "fuel", "near": "Nowhereville"}))["error"]["type"], "geocode_empty");
    // Far north in Idaho: the only fuel is 800 km away.
    let far = loc(48.9, -116.5);
    let e = run(n, Some(&far), json!({"category": "fuel"}));
    assert_eq!(e["error"]["type"], "nearby_empty");
    assert_eq!(e["error"]["category"], "fuel");
    // Outside every installed region.
    let out = loc(30.0, -90.0);
    assert_eq!(run(n, Some(&out), json!({"category": "fuel"}))["error"]["type"], "not_set_up");
}

#[test]
fn schema_is_filled_from_the_pack_and_absent_without_one() {
    let (_d, ts, _) = setup("n4");
    let sc = tool(&ts, "nearby").schema().unwrap();
    let cat = &sc["function"]["parameters"]["properties"]["category"];
    // Only categories with places in the pack; urgent_care has none.
    assert_eq!(cat["enum"], json!(["emergency_room", "hospital", "pharmacy", "fuel", "police", "water", "shelter"]));
    let d = cat["description"].as_str().unwrap();
    assert!(d.contains("emergency_room = hospital emergency rooms; for a hospital in an emergency use emergency_room"), "{d}");
    assert!(!d.contains("urgent_care"));

    let none = tools(&PlacesCfg { packs: vec!["/definitely/not/here/places.sqlite".into()], merged_dir: None });
    assert!(tool(&none, "nearby").schema().is_none());
    assert!(tool(&none, "locate").schema().is_some());
    let e = run(tool(&none, "nearby"), Some(&loc(42.5, -113.8)), json!({"category": "fuel"}));
    assert_eq!(e["error"]["type"], "not_set_up");
}

#[test]
fn a_pack_that_appears_later_is_picked_up() {
    let d = Dir::new("n5");
    let pack = d.0.join("places.sqlite");
    let ts = tools(&PlacesCfg { packs: vec![pack.to_string_lossy().into_owned()], merged_dir: None });
    assert!(tool(&ts, "nearby").schema().is_none());
    write_fixture_pack(&pack);
    assert!(tool(&ts, "nearby").schema().is_some());
}

#[test]
fn locate_places_and_current_location() {
    let (_d, ts, _) = setup("l1");
    let l = tool(&ts, "locate");
    let v = run(l, None, json!({"place": "Stanley, Idaho"}));
    assert_eq!(v["place_name"], "Stanley, ID");
    assert_eq!(v["nearest_town"], "Stanley, ID");
    assert_eq!(v["distance_to_town_mi"], 0.0);
    assert!(v.get("accuracy_m").is_none() && v.get("fixed_at").is_none());
    assert!(v["lat_lon_dms"].as_str().unwrap().starts_with("44\u{b0}13'"));
    assert!(v["usng"].as_str().unwrap().starts_with("11T "));
    assert_eq!(v["plus_code"].as_str().unwrap().len(), 11);

    let boise = loc(43.615, -116.202);
    let v = run(l, Some(&boise), json!({}));
    assert_eq!(v["place_name"], "current location");
    assert_eq!(v["lat"], 43.615);
    assert_eq!(v["nearest_town"], "Boise, ID");
    assert_eq!(v["accuracy_m"], 12);
    assert_eq!(v["fixed_at"], "2026-10-25T14:20:05-06:00");
    let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
    assert_eq!(
        keys,
        ["address", "place_name", "lat", "lon", "lat_lon_dms", "nearest_town", "distance_to_town_mi", "accuracy_m", "fixed_at", "usng", "plus_code"]
    );

    assert_eq!(run(l, None, json!({}))["error"]["type"], "no_location");
    assert_eq!(run(l, None, json!({"place": "Nowhereville"}))["error"]["type"], "geocode_empty");
}

#[test]
fn locate_works_without_a_pack_for_a_gps_fix() {
    let none = tools(&PlacesCfg { packs: vec![], merged_dir: None });
    let v = run(tool(&none, "locate"), Some(&loc(43.615, -116.202)), json!({}));
    assert_eq!(v["lat"], 43.615);
    assert!(v.get("nearest_town").is_none());
    assert!(v["usng"].as_str().unwrap().starts_with("11T "));
    assert_eq!(run(tool(&none, "locate"), None, json!({"place": "Stanley"}))["error"]["type"], "not_set_up");
}

#[test]
fn saved_places_resolve_before_the_geocoder() {
    struct Home;
    impl SavedPlaces for Home {
        fn resolve(&self, name: &str) -> Option<SavedPlace> {
            name.eq_ignore_ascii_case("home").then(|| SavedPlace { key: "home".into(), name: "Home".into(), lat: 42.536, lon: -113.792, label: None })
        }
        fn list(&self) -> Vec<SavedPlace> {
            vec![]
        }
    }
    let (_d, ts, _) = setup("l2");
    let ctx = ToolCtx { location: None, places: &Home, now: FIXTURE_NOW, geocoder: None, live_fetcher: None };
    let Ok(ToolOutput::Json(v)) = tool(&ts, "nearby").run(&ctx, &json!({"category": "pharmacy", "near": "Home", "limit": 1})) else { panic!() };
    assert_eq!(v["center"], "Home");
    assert_eq!(v["places"][0]["name"], "Walgreens");
}

#[test]
fn geocoder_prefers_the_town_over_things_named_after_it() {
    let (_d, _ts, path) = setup("g1");
    let g = PackGeocoder::new(Arc::new(PackSet::new(vec![PathBuf::from(path)], None)));
    let h = g.forward("Burley", None, 5);
    assert_eq!(h[0].label, "Burley, ID");
    assert!(h.iter().any(|x| x.name == "Burley Elementary School"));
    assert!(h.iter().any(|x| x.name == "Burley" && x.address.starts_with("place:")));
    // Partial typing.
    assert_eq!(g.forward("Burl", None, 3)[0].label, "Burley, ID");
    // Two Stanleys: the state picks one, and without a state the near bias does.
    assert_eq!(g.forward("Stanley, North Dakota", None, 1)[0].state.as_deref(), Some("ND"));
    assert_eq!(g.forward("Stanley ID", None, 1)[0].state.as_deref(), Some("ID"));
    assert_eq!(g.forward("Stanley", Some((46.3, -97.2)), 1)[0].state.as_deref(), Some("ND"));
    // A place by name, with its town as the qualifier; and by an alternative name.
    assert_eq!(g.forward("Walgreens, Burley", None, 1)[0].name, "Walgreens");
    assert_eq!(g.forward("Cassia Regional Medical Center", None, 1)[0].name, "Cassia Regional Hospital");
    assert!(g.forward("zzzz", None, 3).is_empty());
    // Several words, one wrong: still finds the hospital.
    assert_eq!(g.forward("Cassia Regional Hospital Burley Idaho", None, 1)[0].name, "Cassia Regional Hospital");
}

#[test]
fn reverse_gives_the_nearest_town() {
    let (_d, _ts, path) = setup("g2");
    let g = PackGeocoder::new(Arc::new(PackSet::new(vec![PathBuf::from(path)], None)));
    let n = g.reverse(42.60, -113.70).unwrap();
    assert_eq!(n.name, "Rupert");
    assert!(n.km < 8.0);
    // Near the hamlet of Lowman, Idaho City's 40 km wins over nothing closer than a hamlet only if it is far.
    let n = g.reverse(44.0900, -115.6200).unwrap();
    assert_eq!(n.name, "Lowman");
}

#[test]
fn place_source_for_navigate() {
    use cache_tool::places::{GeocodeQuery, NearestQuery};
    let d = Dir::new("ps1");
    let pack = d.0.join("places.sqlite");
    let none = cache_places::tools_and_source(&PlacesCfg { packs: vec![pack.to_string_lossy().into_owned()], merged_dir: None }).1;
    assert!(none.categories().is_none());
    assert_eq!(none.geocode(&GeocodeQuery { text: "Burley", near: None, bias: None, limit: 3 }).unwrap_err().code, "not_set_up");
    assert_eq!(none.nearest(&NearestQuery { category: "fuel", from: (42.5, -113.8), limit: 3 }).unwrap_err().code, "not_set_up");

    write_fixture_pack(&pack);
    let src = none; // the same source sees the pack that appeared
    assert_eq!(src.categories().unwrap(), ["emergency_room", "hospital", "pharmacy", "fuel", "police", "water", "shelter"]);

    let a = src.geocode(&GeocodeQuery { text: "Walgreens", near: Some("Burley, Idaho"), bias: Some((42.5357, -113.7928)), limit: 3 }).unwrap();
    let m = &a.matches[0];
    assert_eq!((m.place_name.as_str(), m.kind.as_deref(), m.street.as_deref(), m.locality.as_deref(), m.state.as_deref()), ("Walgreens", Some("pharmacy"), Some("1414 Overland Ave"), Some("Burley"), Some("ID")));
    assert_eq!(m.osm_category.as_deref(), Some("amenity:pharmacy"));
    assert!(m.distance_km.unwrap() < 1.0);

    let t = src.geocode(&GeocodeQuery { text: "Stanley", near: Some("Idaho"), bias: None, limit: 1 }).unwrap();
    assert_eq!((t.matches[0].place_name.as_str(), t.matches[0].kind.as_deref(), t.matches[0].state.as_deref()), ("Stanley", Some("town"), Some("ID")));
    assert!(src.geocode(&GeocodeQuery { text: "Nowhereville", near: None, bias: None, limit: 3 }).unwrap().matches.is_empty());

    let n = src.nearest(&NearestQuery { category: "emergency_room", from: (43.828, -115.834), limit: 2 }).unwrap();
    assert_eq!(n.matches.len(), 2);
    assert_eq!(n.matches[0].place_name, "St. Luke's Boise Medical Center");
    assert_eq!(n.matches[0].er_tier, Some(1));
    assert!((n.matches[0].distance_km.unwrap() - 37.5).abs() < 2.0, "{:?}", n.matches[0].distance_km);
    // Near Burley the likely hospitals come first, with navi's tier 3.
    let b = src.nearest(&NearestQuery { category: "emergency_room", from: (42.536, -113.792), limit: 2 }).unwrap();
    assert_eq!((b.matches[0].place_name.as_str(), b.matches[0].er_tier), ("Cassia Regional Hospital", Some(3)));
    assert!(src.nearest(&NearestQuery { category: "urgent_care", from: (43.8, -115.8), limit: 2 }).unwrap().matches.is_empty());
}

// ---- `cache_tool::places::Geocoder`: the one-point lookup live_data resolves place names with ----

fn source(name: &str) -> (Dir, Arc<dyn cache_tool::places::PlaceSource>) {
    let (d, _, path) = setup(name);
    let (_, source) = cache_places::tools_and_source(&PlacesCfg { packs: vec![path], merged_dir: None });
    (d, source)
}

#[test]
fn resolve_gives_one_point_for_a_name_however_it_is_written() {
    let (_d, src) = source("resolve1");
    let g = src.geocoder().expect("the pack source is a geocoder");
    for text in ["Burley, Idaho", "Burley ID", "burley", "BURLEY", "  Burley  ", "burley id", "burley, id", "Burley, Idaho."] {
        let (name, lat, lon) = g.resolve(text, None).unwrap_or_else(|| panic!("{text}"));
        assert_eq!(name, "Burley, ID", "{text}");
        assert!((lat - 42.5357).abs() < 1e-3 && (lon + 113.7928).abs() < 1e-3);
    }
    // a place that is not a town: its name as the pack shows it
    assert_eq!(g.resolve("Cassia Regional Hospital", None).unwrap().0, "Cassia Regional Hospital (Burley, ID)");
    // nothing: not a place, empty text, or only a weak match (a place that has one of the words in its name)
    assert!(g.resolve("Xyzzy Plugh", None).is_none());
    assert!(g.resolve("   ", None).is_none());
}

#[test]
fn describe_point_words_a_point_by_its_nearest_town_like_the_map_search() {
    let (_d, src) = source("describe1");
    let g = src.geocoder().unwrap();
    // 0.44 km north of Burley: the nearest town is Burley, the point lies north of it
    assert_eq!(g.describe_point(42.5397, -113.7928).as_deref(), Some("0.3 mi N of Burley, ID"));
    // under 0.1 mi the distance is rounded to one decimal and shows as 0, exactly as the map search words it
    assert_eq!(g.describe_point(42.5362, -113.7928).as_deref(), Some("0 mi N of Burley, ID"));
    // south and east
    assert_eq!(g.describe_point(42.5317, -113.7928).as_deref(), Some("0.3 mi S of Burley, ID"));
    assert!(g.describe_point(42.5357, -113.7878).unwrap().contains(" mi E of Burley, ID"));
    // no town anywhere near, or not a point
    assert_eq!(g.describe_point(0.0, 0.0), None);
    assert_eq!(g.describe_point(f64::NAN, 0.0), None);
}

#[test]
fn resolve_takes_a_town_with_a_typing_slip() {
    let (_d, src) = source("resolve2");
    let g = src.geocoder().unwrap();
    // swapped neighbours, a missing letter, a doubled letter, a wrong letter
    for (typo, town) in [("Burlye", "Burley, ID"), ("Burly", "Burley, ID"), ("Heybrn", "Heyburn, ID"), ("Twin Fals", "Twin Falls, ID"), ("Ruppert", "Rupert, ID"), ("Boisse", "Boise, ID"), ("Idaho Cty", "Idaho City, ID"), ("Twin Fallz Idaho", "Twin Falls, ID")] {
        assert_eq!(g.resolve(typo, None).map(|r| r.0).as_deref(), Some(town), "{typo}");
    }
    // a short name must be exact (no edits allowed under 4 letters), and too many edits is no match
    assert!(g.resolve("Bose", None).is_some()); // 4 letters: one slip
    assert!(g.resolve("Bxi", None).is_none());
    assert!(g.resolve("Bxrlxy", None).is_none());
    assert!(g.resolve("Burleyville Road Extension", None).is_none());
}

#[test]
fn a_misspelt_town_in_two_states_goes_to_the_one_asked_for_or_the_nearer_one() {
    let (_d, src) = source("resolve3");
    let g = src.geocoder().unwrap();
    // the fixture has a Stanley in Idaho (100 people) and one in North Dakota (80)
    assert_eq!(g.resolve("Stanly", None).unwrap().0, "Stanley, ID"); // more people
    assert_eq!(g.resolve("Stanly, ND", None).unwrap().0, "Stanley, ND"); // the state asked for
    assert_eq!(g.resolve("Stanly", Some((46.3, -97.2))).unwrap().0, "Stanley, ND"); // nearer the phone
    assert_eq!(g.resolve("Stanly", Some((43.6, -116.2))).unwrap().0, "Stanley, ID");
}

// ---- one resolver for navigate, locate and live_data: case-insensitive, with the misspelling fallback inside ----

#[test]
fn a_misspelt_town_resolves_the_same_in_navigate_locate_and_live_data() {
    use cache_tool::places::GeocodeQuery;
    let (_d, ts, path) = setup("slip1");
    let (_, src) = cache_places::tools_and_source(&PlacesCfg { packs: vec![path], merged_dir: None });
    for text in ["Islnd Park", "Islnd Park, Idaho", "islnd park id", "Ilsand Park"] {
        // navigate: `PlaceSource::geocode`
        let a = src.geocode(&GeocodeQuery { text, near: None, bias: None, limit: 3 }).unwrap();
        assert_eq!((a.matches[0].place_name.as_str(), a.matches[0].state.as_deref()), ("Island Park", Some("ID")), "navigate {text}");
        // locate
        let v = run(tool(&ts, "locate"), None, json!({"place": text}));
        assert_eq!(v["place_name"], "Island Park, ID", "locate {text}: {v}");
        assert_eq!(v["nearest_town"], "Island Park, ID");
        // live_data: `Geocoder::resolve`
        assert_eq!(src.geocoder().unwrap().resolve(text, None).unwrap().0, "Island Park, ID", "live_data {text}");
    }
}

#[test]
fn an_exact_name_beats_a_close_fuzzy_one() {
    let (_d, src) = source("exact1");
    let (_d2, _ts, path) = setup("exact2");
    let g = PackGeocoder::new(Arc::new(PackSet::new(vec![PathBuf::from(path)], None)));
    // "Boyse" is one edit from "Boise" and has far more people, and the phone is at it: the exact name still wins, both ways round
    let near_boyse = Some((46.0, -112.5));
    for (text, want) in [("Boise", "Boise, ID"), ("boise", "Boise, ID"), ("Boyse", "Boyse, ID")] {
        assert_eq!(g.forward(text, near_boyse, 3)[0].label, want, "{text}");
        assert_eq!(src.geocoder().unwrap().resolve(text, near_boyse).unwrap().0, want, "{text}");
    }
    // and the slip is still taken when there is no exact name: "Boisse" is one edit from both, the nearer town wins the tie
    assert_eq!(src.geocoder().unwrap().resolve("Boisse", Some((43.6, -116.2))).unwrap().0, "Boise, ID");
}

#[test]
fn a_whole_name_town_slip_beats_a_poi_prefix_match() {
    let (_d, src) = source("poi1");
    let (_d2, _ts, path) = setup("poi2");
    let g = PackGeocoder::new(Arc::new(PackSet::new(vec![PathBuf::from(path)], None)));
    let near_shelley = Some((43.37, -112.12));
    // "Amon" is a prefix of the place "Amonara" (Shelley) and one edit from the town Ammon: the town wins
    for text in ["amon", "Amon", "AMON"] {
        assert_eq!(g.forward(text, near_shelley, 3)[0].label, "Ammon, ID", "{text}");
        assert_eq!(src.geocoder().unwrap().resolve(text, near_shelley).unwrap().0, "Ammon, ID", "{text}");
    }
    // a place query that names a place still finds the place
    assert_eq!(g.forward("Stanley Ranger Station", None, 3)[0].name, "Stanley Ranger Station");
    assert_eq!(g.forward("Islnd Park", None, 3)[0].label, "Island Park, ID");
    // a place whose whole name is the text beats the town one edit away
    assert_eq!(g.forward("Ammin", None, 3)[0].name, "Ammin");
    assert_eq!(g.forward("Ammin", None, 3)[0].kind, cache_places::HitKind::Place);
    // the full name of the place is still itself
    assert_eq!(g.forward("Amonara", None, 3)[0].name, "Amonara");
}

#[test]
fn a_state_in_any_letter_case_is_the_same_query() {
    let (_d, ts, path) = setup("case1");
    let g = PackGeocoder::new(Arc::new(PackSet::new(vec![PathBuf::from(path)], None)));
    let labels = |q: &str| g.forward(q, None, 3).into_iter().map(|h| h.label).collect::<Vec<_>>();
    let want = labels("Rupert ID");
    assert_eq!(want[0], "Rupert, ID");
    for q in ["rupert id", "RUPERT ID", "rupert Id", "Rupert, id", "rupert idaho", "RUPERT, IDAHO"] {
        assert_eq!(labels(q), want, "{q}");
    }
    assert_eq!(run(tool(&ts, "locate"), None, json!({"place": "rupert id"})), run(tool(&ts, "locate"), None, json!({"place": "Rupert ID"})));
    assert_eq!(g.forward("stanley nd", None, 1)[0].state.as_deref(), Some("ND"));
}
