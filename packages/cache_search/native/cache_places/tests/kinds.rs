//! What kind of place every result is: the `kind` and `kind_label` of nearby, locate and the map search, unnamed places called
//! by their kind, the drinking water category without lakes, and the format 1 pack (no kinds) that must still open.

use cache_places::fixture::{write_fixture_pack, write_fixture_pack_v1, FIXTURE_NOW};
use cache_places::map::SearchOpts;
use cache_places::{tools, Pack, PlacesCfg, PlacesCore};
use cache_tool::{NoSavedPlaces, Tool, ToolCtx, ToolOutput};
use rusqlite::Connection;
use serde_json::{json, Value};
use std::path::PathBuf;

struct Dir(PathBuf);
impl Dir {
    fn new(name: &str) -> Dir {
        let p = std::env::temp_dir().join(format!("cp-kinds-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Dir(p)
    }
    fn pack(&self) -> PathBuf {
        self.0.join("places.sqlite")
    }
    fn cfg(&self) -> PlacesCfg {
        PlacesCfg { packs: vec![self.pack().to_string_lossy().into_owned()] }
    }
}
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn run(ts: &[Box<dyn Tool>], name: &str, args: Value) -> Value {
    let t = ts.iter().find(|t| t.name() == name).unwrap();
    let ctx = ToolCtx { location: None, places: &NoSavedPlaces, now: FIXTURE_NOW, geocoder: None, live_fetcher: None };
    match t.run(&ctx, &args) {
        Ok(ToolOutput::Json(v)) => v,
        Ok(ToolOutput::Text(_)) => panic!("text"),
        Err(e) => e.to_json(),
    }
}

fn places(v: &Value) -> Vec<&Value> {
    v["places"].as_array().unwrap().iter().collect()
}

#[test]
fn unnamed_water_places_are_called_by_their_kind() {
    let d = Dir::new("water");
    write_fixture_pack(&d.pack());
    let ts = tools(&d.cfg());
    let v = run(&ts, "nearby", json!({"category": "water", "near": "Stanley, Idaho", "limit": 10}));
    let ps = places(&v);
    assert_eq!(ps.len(), 4, "{v}");
    for p in &ps {
        // never a bare generic name, and always a kind
        assert_ne!(p["name"], "Water", "{p}");
        assert!(p["kind"].is_string() && p["kind_label"].is_string(), "{p}");
    }
    let by_kind = |k: &str| ps.iter().filter(|p| p["kind"] == k).collect::<Vec<_>>();
    // the three unnamed ones: the label stands for the name, and they say so
    let tap = by_kind("drinking_water");
    assert_eq!(tap.len(), 1);
    assert_eq!((tap[0]["name"].as_str(), tap[0]["kind_label"].as_str(), tap[0]["unnamed"].as_bool()), (Some("Drinking water tap"), Some("Drinking water tap"), Some(true)));
    let well = by_kind("water_well");
    assert_eq!((well[0]["name"].as_str(), well[0]["unnamed"].as_bool()), (Some("Water well"), Some(true)));
    // an unnamed spring and a named one
    let springs = by_kind("spring");
    assert_eq!(springs.len(), 2);
    let named = springs.iter().find(|p| p["name"] == "Sawtooth Spring").expect("the named spring");
    assert!(named.get("unnamed").is_none(), "a named place is not flagged");
    assert_eq!(named["kind_label"], "Spring");
    let unnamed = springs.iter().find(|p| p["unnamed"] == true).expect("the unnamed spring");
    assert_eq!(unnamed["name"], "Spring");
    // field order: the kind sits right after the name
    let keys: Vec<&String> = tap[0].as_object().unwrap().keys().collect();
    assert_eq!(keys[..5], ["address", "name", "kind", "kind_label", "unnamed"]);
}

#[test]
fn drinking_water_never_returns_a_lake() {
    let d = Dir::new("lake");
    write_fixture_pack(&d.pack());
    let ts = tools(&d.cfg());
    // nearby: the category holds taps, springs and wells only; Water Hole Lake (a water body, no category) and Stanley Lake are not in it
    let v = run(&ts, "nearby", json!({"category": "water", "near": "Stanley, Idaho", "limit": 10}));
    assert!(places(&v).iter().all(|p| ["drinking_water", "spring", "water_well", "water_point", "water_tap"].contains(&p["kind"].as_str().unwrap())), "{v}");
    assert!(places(&v).iter().all(|p| !p["name"].as_str().unwrap().contains("Lake")));

    // the map's search box: "drinking water" finds the water category and its places, and not the lakes, although one is named "Water Hole Lake"
    let core = PlacesCore::new(&d.cfg());
    for q in ["drinking water", "drinking water near Stanley", "water"] {
        let out = core.search(q, &SearchOpts { near: Some((44.2210, -114.9360)), ..Default::default() }, None).unwrap();
        let rs = out["results"].as_array().unwrap();
        assert!(rs.iter().any(|r| r["category"] == "water"), "{q}: {out}");
        for r in rs.iter().filter(|r| r["type"] == "place" && r["category"] == "water") {
            assert!(["drinking_water", "spring", "water_well"].contains(&r["kind_id"].as_str().unwrap()), "{q}: {r}");
        }
        if q != "water" {
            assert!(rs.iter().all(|r| r["kind_id"] != "water_body"), "{q}: a lake came back: {out}");
        }
    }
    // a lake is findable by name, and says what it is
    let out = core.search("Water Hole Lake", &SearchOpts { near: Some((44.2210, -114.9360)), ..Default::default() }, None).unwrap();
    let lake = out["results"].as_array().unwrap().iter().find(|r| r["name"] == "Water Hole Lake").unwrap_or_else(|| panic!("{out}"));
    assert_eq!((lake["kind_id"].as_str(), lake["kind_label"].as_str(), lake["category"].is_null()), (Some("water_body"), Some("Lake or other water body"), true));
}

#[test]
fn shelters_say_whether_they_are_emergency_or_picnic_shelters() {
    let d = Dir::new("shelter");
    write_fixture_pack(&d.pack());
    let ts = tools(&d.cfg());
    let v = run(&ts, "nearby", json!({"category": "shelter", "near": "Stanley, Idaho", "limit": 10}));
    let ps = places(&v);
    assert_eq!(ps.len(), 3, "{v}");
    let pick = |k: &str| ps.iter().find(|p| p["kind"] == k).unwrap_or_else(|| panic!("{k} in {v}"));
    // the unnamed one is a picnic shelter, not an emergency one, and its name is not a bare "Shelter"
    let picnic = pick("picnic_shelter");
    assert_eq!((picnic["name"].as_str(), picnic["unnamed"].as_bool()), (Some("Picnic shelter"), Some(true)));
    let emergency = pick("emergency_shelter");
    assert_eq!((emergency["name"].as_str(), emergency["kind_label"].as_str()), (Some("Redfish Lake Emergency Shelter"), Some("Emergency shelter")));
    assert_eq!(pick("wilderness_hut")["kind_label"], "Backcountry hut");
    assert!(ps.iter().all(|p| p["name"] != "Shelter"));
}

#[test]
fn locate_and_map_search_carry_the_kind() {
    let d = Dir::new("locate");
    write_fixture_pack(&d.pack());
    let ts = tools(&d.cfg());
    let v = run(&ts, "locate", json!({"place": "Walgreens, Burley"}));
    assert_eq!((v["kind"].as_str(), v["kind_label"].as_str()), (Some("pharmacy"), Some("Pharmacy")));
    let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
    assert_eq!(keys[..4], ["address", "place_name", "kind", "kind_label"]);
    let v = run(&ts, "locate", json!({"place": "Stanley, Idaho"}));
    assert_eq!((v["kind"].as_str(), v["kind_label"].as_str()), (Some("town"), Some("Town")));
    // the phone's own position is no place: no kind
    let ctx = ToolCtx { location: Some(&cache_tool::Location { lat: 43.6, lon: -116.2, accuracy_m: None, fixed_at: FIXTURE_NOW.into() }), places: &NoSavedPlaces, now: FIXTURE_NOW, geocoder: None, live_fetcher: None };
    let Ok(ToolOutput::Json(here)) = ts.iter().find(|t| t.name() == "locate").unwrap().run(&ctx, &json!({})) else { panic!() };
    assert!(here.get("kind").is_none());

    // the map search keeps `kind` as the text shown on the card and adds the machine id and label
    let core = PlacesCore::new(&d.cfg());
    let out = core.search("Walgreens", &SearchOpts { near: Some((42.5357, -113.7928)), ..Default::default() }, None).unwrap();
    let r = &out["results"][0];
    assert_eq!((r["kind"].as_str(), r["kind_id"].as_str(), r["kind_label"].as_str()), (Some("Pharmacy"), Some("pharmacy"), Some("Pharmacy")));
    assert!(r.get("unnamed").is_none());
    let out = core.search("shelter", &SearchOpts { near: Some((44.2210, -114.9360)), ..Default::default() }, None).unwrap();
    let unnamed: Vec<&Value> = out["results"].as_array().unwrap().iter().filter(|r| r["unnamed"] == true).collect();
    assert_eq!(unnamed.len(), 1, "{out}");
    assert_eq!((unnamed[0]["name"].as_str(), unnamed[0]["kind"].as_str(), unnamed[0]["kind_id"].as_str()), (Some("Picnic shelter"), Some("Picnic shelter"), Some("picnic_shelter")));
}

#[test]
fn navigate_names_an_unnamed_place_by_its_kind_too() {
    use cache_tool::places::NearestQuery;
    let d = Dir::new("nav");
    write_fixture_pack(&d.pack());
    let (_, src) = cache_places::tools_and_source(&d.cfg());
    let n = src.nearest(&NearestQuery { category: "shelter", from: (44.2210, -114.9360), limit: 3 }).unwrap();
    assert_eq!(n.matches[0].place_name, "Picnic shelter");
}

#[test]
fn a_format_1_pack_still_opens_with_no_kinds() {
    let d = Dir::new("v1");
    write_fixture_pack_v1(&d.pack());
    let p = Pack::open(&d.pack()).expect("a format 1 pack opens");
    assert_eq!(p.format, 1);
    assert!(p.kinds.is_empty() && p.kind("drinking_water").is_none());
    let row = p.nearby("water", 44.2210, -114.9360, 50.0, 10).unwrap();
    assert_eq!(row.len(), 4);
    assert!(row.iter().all(|(r, _)| r.kind_id.is_none()));
    // the tools work, say nothing about kinds, and still flag the places that have no name
    let ts = tools(&d.cfg());
    let v = run(&ts, "nearby", json!({"category": "water", "near": "Stanley, Idaho", "limit": 10}));
    assert_eq!(places(&v).len(), 4);
    for p in places(&v) {
        assert!(p.get("kind").is_none() && p.get("kind_label").is_none(), "{p}");
    }
    assert_eq!(places(&v).iter().filter(|p| p["unnamed"] == true).count(), 3);
    let v = run(&ts, "locate", json!({"place": "Walgreens, Burley"}));
    assert!(v.get("kind").is_none());
    let core = PlacesCore::new(&d.cfg());
    let out = core.search("Walgreens", &SearchOpts { near: Some((42.5357, -113.7928)), ..Default::default() }, None).unwrap();
    assert!(out["results"][0].get("kind_id").is_none());
    assert_eq!(out["results"][0]["kind"], "Pharmacy");
}

#[test]
fn only_known_formats_open() {
    let d = Dir::new("fmt");
    write_fixture_pack(&d.pack());
    let p = Pack::open(&d.pack()).unwrap();
    assert_eq!(p.format, 2);
    assert_eq!(p.kind("picnic_shelter").unwrap().label, "Picnic shelter");
    assert_eq!(p.kind("water_body").unwrap().category, None);
    assert!(!p.kind("drinking_water").unwrap().description.is_empty());
    // 3 is the merged database (`MERGED_SCHEMA`), which opens too.
    for bad in ["0", "4"] {
        Connection::open(d.pack()).unwrap().execute("UPDATE meta SET value = ?1 WHERE key = 'format_version'", [bad]).unwrap();
        let e = Pack::open(&d.pack()).err().expect("refused");
        assert!(e.message.contains("not supported"), "{}", e.message);
    }
}
