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
    (d, tools(&PlacesCfg { packs: vec![path.clone()] }), path)
}

fn tool<'a>(ts: &'a [Box<dyn Tool>], n: &str) -> &'a dyn Tool {
    ts.iter().find(|t| t.name() == n).unwrap().as_ref()
}

fn loc(lat: f64, lon: f64) -> Location {
    Location { lat, lon, accuracy_m: Some(12.0), fixed_at: "2026-10-25T14:20:05-06:00".into() }
}

fn run(t: &dyn Tool, location: Option<&Location>, args: Value) -> Value {
    let ctx = ToolCtx { location, places: &NoSavedPlaces, now: FIXTURE_NOW };
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
    assert_eq!(pk, ["address", "name", "street", "locality", "state", "distance_mi", "direction", "phone", "hours"]);
}

#[test]
fn nearby_er_from_the_phone_location() {
    let (_d, ts, _) = setup("n2");
    let l = loc(43.828, -115.834);
    let v = run(tool(&ts, "nearby"), Some(&l), json!({"category": "emergency_room", "limit": 2}));
    assert_eq!(v["center"], "current location");
    assert_eq!(v["places"][0]["name"], "St. Luke's Boise Medical Center");
    assert_eq!(v["places"][0]["direction"], "SW");
    assert_eq!(v["places"].as_array().unwrap().len(), 2);
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
    assert_eq!(cat["enum"], json!(["emergency_room", "hospital", "pharmacy", "fuel", "police", "water"]));
    let d = cat["description"].as_str().unwrap();
    assert!(d.contains("emergency_room = hospital emergency rooms; for a hospital in an emergency use emergency_room"), "{d}");
    assert!(!d.contains("urgent_care"));

    let none = tools(&PlacesCfg { packs: vec!["/definitely/not/here/places.sqlite".into()] });
    assert!(tool(&none, "nearby").schema().is_none());
    assert!(tool(&none, "locate").schema().is_some());
    let e = run(tool(&none, "nearby"), Some(&loc(42.5, -113.8)), json!({"category": "fuel"}));
    assert_eq!(e["error"]["type"], "not_set_up");
}

#[test]
fn a_pack_that_appears_later_is_picked_up() {
    let d = Dir::new("n5");
    let pack = d.0.join("places.sqlite");
    let ts = tools(&PlacesCfg { packs: vec![pack.to_string_lossy().into_owned()] });
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
    let none = tools(&PlacesCfg { packs: vec![] });
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
    let ctx = ToolCtx { location: None, places: &Home, now: FIXTURE_NOW };
    let Ok(ToolOutput::Json(v)) = tool(&ts, "nearby").run(&ctx, &json!({"category": "pharmacy", "near": "Home", "limit": 1})) else { panic!() };
    assert_eq!(v["center"], "Home");
    assert_eq!(v["places"][0]["name"], "Walgreens");
}

#[test]
fn geocoder_prefers_the_town_over_things_named_after_it() {
    let (_d, _ts, path) = setup("g1");
    let g = PackGeocoder::new(Arc::new(PackSet::new(vec![PathBuf::from(path)])));
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
    let g = PackGeocoder::new(Arc::new(PackSet::new(vec![PathBuf::from(path)])));
    let n = g.reverse(42.60, -113.70).unwrap();
    assert_eq!(n.name, "Rupert");
    assert!(n.km < 8.0);
    // Near the hamlet of Lowman, Idaho City's 40 km wins over nothing closer than a hamlet only if it is far.
    let n = g.reverse(44.0900, -115.6200).unwrap();
    assert_eq!(n.name, "Lowman");
}

#[test]
fn place_source_for_navigate() {
    use cache_tool::places::{GeocodeQuery, NearestQuery, PlaceSource};
    let d = Dir::new("ps1");
    let pack = d.0.join("places.sqlite");
    let none = cache_places::tools_and_source(&PlacesCfg { packs: vec![pack.to_string_lossy().into_owned()] }).1;
    assert!(none.categories().is_none());
    assert_eq!(none.geocode(&GeocodeQuery { text: "Burley", near: None, bias: None, limit: 3 }).unwrap_err().code, "not_set_up");
    assert_eq!(none.nearest(&NearestQuery { category: "fuel", from: (42.5, -113.8), limit: 3 }).unwrap_err().code, "not_set_up");

    write_fixture_pack(&pack);
    let src = none; // the same source sees the pack that appeared
    assert_eq!(src.categories().unwrap(), ["emergency_room", "hospital", "pharmacy", "fuel", "police", "water"]);

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
    assert_eq!(n.matches[0].er_tier, Some(2));
    assert!((n.matches[0].distance_km.unwrap() - 37.5).abs() < 2.0, "{:?}", n.matches[0].distance_km);
    assert!(src.nearest(&NearestQuery { category: "urgent_care", from: (43.8, -115.8), limit: 2 }).unwrap().matches.is_empty());
}
