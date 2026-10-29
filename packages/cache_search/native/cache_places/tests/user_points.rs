//! The user's imported repeaters and map layers in `nearby` and `locate` (docs/TOOLS.md), over the fixture pack and the
//! user store's fixture files.

use cache_places::fixture::{write_fixture_pack, FIXTURE_NOW};
use cache_places::{core_tools_and_source_with, PlacesCfg};
use cache_tool::user::{UserPoints, UserPointsSlot};
use cache_tool::{Location, NoSavedPlaces, Tool, ToolCtx, ToolOutput};
use cache_user::mapdata::MapStore;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::{Arc, RwLock};

struct Dir(PathBuf);
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn fixture(f: &str) -> String {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../cache_user/tests/fixtures").join(f).to_string_lossy().into_owned()
}

/// The tools over the fixture pack (or none) with a user store holding the given imports.
fn setup(name: &str, with_pack: bool, imports: &[Value]) -> (Dir, Vec<Box<dyn Tool>>, Arc<MapStore>) {
    let d = Dir(std::env::temp_dir().join(format!("cp-user-{}-{name}", std::process::id())));
    let _ = std::fs::remove_dir_all(&d.0);
    std::fs::create_dir_all(&d.0).unwrap();
    let mut packs = Vec::new();
    if with_pack {
        let pack = d.0.join("places.sqlite");
        write_fixture_pack(&pack);
        packs.push(pack.to_string_lossy().into_owned());
    }
    let store = Arc::new(MapStore::new(d.0.join("user.sqlite")));
    for i in imports {
        store.import(&i.to_string()).unwrap();
    }
    let slot: UserPointsSlot = Arc::new(RwLock::new(Some(store.clone() as Arc<dyn UserPoints>)));
    let (_, tools, _) = core_tools_and_source_with(&PlacesCfg { packs, merged_dir: None }, slot);
    (d, tools, store)
}

fn repeaters() -> Value {
    json!({"kind": "repeaters", "paths": [fixture("repeaters-fixture.kml"), fixture("repeaters-fixture.csv")]})
}

fn layer(f: &str) -> Value {
    json!({"kind": "layer", "paths": [fixture(f)]})
}

fn tool<'a>(ts: &'a [Box<dyn Tool>], n: &str) -> &'a dyn Tool {
    ts.iter().find(|t| t.name() == n).unwrap().as_ref()
}

fn burley() -> Location {
    Location { lat: 42.5357, lon: -113.7928, accuracy_m: Some(12.0), fixed_at: "2026-10-25T14:20:05-06:00".into() }
}

fn run(t: &dyn Tool, location: Option<&Location>, args: Value) -> String {
    let ctx = ToolCtx { location, places: &NoSavedPlaces, now: FIXTURE_NOW, geocoder: None, live_fetcher: None };
    match t.run(&ctx, &args) {
        Ok(ToolOutput::Json(v)) => v.to_string(),
        Ok(ToolOutput::Text(_)) => panic!("text"),
        Err(e) => e.to_json().to_string(),
    }
}

#[test]
fn the_categories_follow_the_packs_repeater_then_layers() {
    let (_d, ts, _) = setup("schema", true, &[layer("rally-points.geojson"), repeaters(), layer("elk-camp.kml")]);
    let s = tool(&ts, "nearby").schema().unwrap();
    let cat = &s["function"]["parameters"]["properties"]["category"];
    let ids: Vec<&str> = cat["enum"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
    let n = ids.len();
    assert_eq!(ids[n - 3..], ["repeater", "layer_elk_camp", "layer_rally_points"]);
    let d = cat["description"].as_str().unwrap();
    assert!(
        d.ends_with("; repeater = amateur radio repeaters from the user's imported lists; layer_elk_camp = Elk Camp: points in the user's own map layer; layer_rally_points = Rally Points: points in the user's own map layer."),
        "{d}"
    );
    // nothing imported: the categories are the pack's alone
    let (_d, ts, _) = setup("schema0", true, &[]);
    let s = tool(&ts, "nearby").schema().unwrap();
    assert!(!s["function"]["parameters"]["properties"]["category"]["enum"].as_array().unwrap().iter().any(|v| v == "repeater"));
    // no pack: the user's categories alone; nothing at all: no tool
    let (_d, ts, _) = setup("schema1", false, &[repeaters()]);
    assert_eq!(tool(&ts, "nearby").schema().unwrap()["function"]["parameters"]["properties"]["category"]["enum"], json!(["repeater"]));
    let (_d, ts, _) = setup("schema2", false, &[]);
    assert!(tool(&ts, "nearby").schema().is_none());
}

#[test]
fn nearby_repeaters_golden() {
    let (_d, ts, _) = setup("rep", true, &[repeaters()]);
    let v = run(tool(&ts, "nearby"), None, json!({"category": "repeater", "near": "Burley, Idaho", "limit": 3}));
    assert_eq!(
        v,
        concat!(
            r#"{"category":"repeater","center":"Burley, ID","ranked_by":"distance","places":["#,
            r#"{"address":"repeater:l1/1","name":"TEST1","kind":"repeater","kind_label":"Repeater","locality":"Burley","distance_mi":0.5,"direction":"NW","frequency":"927.1625 MHz","offset":"-25 MHz","tone":"151.4 Hz to transmit","mode":"FM","on_air":"yes","list":"repeaters-fixture.kml","details":"full page on RepeaterBook (opens in the browser; needs a connection)"},"#,
            r#"{"address":"repeater:l1/3","name":"TEST3","kind":"repeater","kind_label":"Repeater","locality":"Burley","distance_mi":1.6,"direction":"SE","frequency":"147.360 MHz","offset":"+600 kHz","tone":"100.0 Hz to transmit and receive","mode":"FM","on_air":"no","list":"repeaters-fixture.kml"},"#,
            r#"{"address":"repeater:l1/4","name":"TEST4","kind":"repeater","kind_label":"Repeater","locality":"Heyburn","distance_mi":2.4,"direction":"NE","frequency":"146.450 MHz","offset":"split: transmit 147.45 MHz","tone":"none","on_air":"yes","list":"repeaters-fixture.kml","details":"full page on RepeaterBook (opens in the browser; needs a connection)"}],"#,
            r#""map_region":"Idaho","map_region_age":"12 days old","#,
            r#""repeater_note":"From the user's imported repeater list; check the settings before transmitting."}"#
        )
    );
}

#[test]
fn nearby_repeater_kml_only_and_dcs_golden() {
    // TEST2 (DCS 432, merged) and TEST5 (in the KML only): the list does not state the offset amount or the tone's use
    let (_d, ts, _) = setup("rep2", true, &[repeaters()]);
    let tf = Location { lat: 42.5629, lon: -114.4609, ..burley() };
    let v = run(tool(&ts, "nearby"), Some(&tf), json!({"category": "repeater", "limit": 1}));
    assert_eq!(
        v,
        concat!(
            r#"{"category":"repeater","center":"current location","ranked_by":"distance","places":["#,
            r#"{"address":"repeater:l1/5","name":"TEST5","kind":"repeater","kind_label":"Repeater","locality":"Twin Falls","distance_mi":0.2,"direction":"S","frequency":"145.230 MHz","offset":"- (amount not in the imported list)","tone":"88.5 Hz (use not stated in the imported list)","on_air":"yes","list":"repeaters-fixture.kml"}],"#,
            r#""map_region":"Idaho","map_region_age":"12 days old","repeater_note":"From the user's imported repeater list; check the settings before transmitting."}"#
        )
    );
    let rupert = Location { lat: 42.62, lon: -113.68, ..burley() };
    let v: Value = serde_json::from_str(&run(tool(&ts, "nearby"), Some(&rupert), json!({"category": "repeater", "limit": 1}))).unwrap();
    assert_eq!((v["places"][0]["name"].as_str(), v["places"][0]["tone"].as_str(), v["places"][0]["mode"].as_str()), (Some("TEST2"), Some("DCS 432"), Some("DMR")));
}

#[test]
fn nearby_layer_points_golden_private_included() {
    // Rally Points is a private layer: shown like any other
    let (_d, ts, _) = setup("lay", true, &[layer("rally-points.geojson"), layer("elk-camp.kml")]);
    let v = run(tool(&ts, "nearby"), Some(&burley()), json!({"category": "layer_rally_points"}));
    assert_eq!(
        v,
        concat!(
            r#"{"category":"layer_rally_points","center":"current location","ranked_by":"distance","places":["#,
            r#"{"address":"layer:y1/2","name":"Canal bridge","kind":"layer_point","kind_label":"Rally Points","locality":"Burley","distance_mi":1.0,"direction":"SW"},"#,
            r#"{"address":"layer:y1/1","name":"North gate","kind":"layer_point","kind_label":"Rally Points","locality":"Burley","distance_mi":1.0,"direction":"N","notes":"Meet here at dawn. Bring water and the radio."}],"#,
            r#""map_region":"Idaho","map_region_age":"12 days old"}"#
        )
    );
    let v: Value = serde_json::from_str(&run(tool(&ts, "nearby"), Some(&burley()), json!({"category": "layer_elk_camp", "limit": 1}))).unwrap();
    assert_eq!((v["places"][0]["name"].as_str(), v["places"][0]["locality"].as_str()), (Some("Spring"), Some("Rupert")));
    let v: Value = serde_json::from_str(&run(tool(&ts, "nearby"), Some(&burley()), json!({"category": "layer_elk_camp", "limit": 2}))).unwrap();
    assert_eq!(v["places"][1]["notes"].as_str().unwrap().chars().count(), 200);
}

#[test]
fn nearby_user_errors() {
    let (_d, ts, store) = setup("err", true, &[layer("rally-points.geojson")]);
    let nearby = tool(&ts, "nearby");
    assert_eq!(run(nearby, Some(&burley()), json!({"category": "repeater"})), r#"{"ok":false,"error":{"type":"not_set_up","detail":"no repeater list is imported"}}"#);
    assert_eq!(
        run(nearby, Some(&burley()), json!({"category": "layer_hunting"})),
        r#"{"ok":false,"error":{"type":"bad_arguments","detail":"category: no such layer on this phone: \"layer_hunting\""}}"#
    );
    let boise = Location { lat: 46.3, lon: -97.2, ..burley() };
    assert_eq!(
        run(nearby, Some(&boise), json!({"category": "layer_rally_points"})),
        r#"{"ok":false,"error":{"type":"nearby_empty","detail":"no points of the layer \"Rally Points\" within 300 km of current location","category":"layer_rally_points","searched_within_km":300}}"#
    );
    assert_eq!(run(nearby, None, json!({"category": "layer_rally_points"})), r#"{"ok":false,"error":{"type":"no_location","detail":"no place was given and the phone's location is not known"}}"#);
    // a layer deleted while a conversation runs
    store.delete("y1").unwrap();
    assert!(run(nearby, Some(&burley()), json!({"category": "layer_rally_points"})).contains("no such layer on this phone"));
}

#[test]
fn nearby_without_a_pack_has_no_map_region() {
    let (_d, ts, _) = setup("nopack", false, &[repeaters()]);
    let v: Value = serde_json::from_str(&run(tool(&ts, "nearby"), Some(&burley()), json!({"category": "repeater", "limit": 1}))).unwrap();
    assert_eq!(v.as_object().unwrap().keys().collect::<Vec<_>>(), ["category", "center", "ranked_by", "places", "repeater_note"]);
    assert_eq!(v["places"][0]["locality"], "Burley", "the town from the list itself");
    let e = run(tool(&ts, "nearby"), None, json!({"category": "repeater", "near": "Burley, Idaho"}));
    assert!(e.contains("not_set_up"), "{e}");
}

#[test]
fn locate_a_layer_point_golden() {
    let (_d, ts, _) = setup("loc", true, &[layer("rally-points.geojson"), layer("elk-camp.kml")]);
    let v = run(tool(&ts, "locate"), Some(&burley()), json!({"place": "Canal Bridge"}));
    assert_eq!(
        v,
        r#"{"address":"layer:y1/2","place_name":"Canal bridge","kind":"layer_point","kind_label":"Rally Points","lat":42.53,"lon":-113.81,"lat_lon_dms":"42°31'48\"N 113°48'36\"W","nearest_town":"Burley, ID","distance_to_town_mi":1.0,"usng":"12T VN 63139 09460","plus_code":"85GFG54Q+22"}"#
    );
    // two layers with the same point name: the most recently used layer's
    let v: Value = serde_json::from_str(&run(tool(&ts, "locate"), None, json!({"place": "north gate"}))).unwrap();
    assert_eq!((v["kind_label"].as_str(), v["lat"].as_f64()), (Some("Elk Camp"), Some(42.6)));
}
