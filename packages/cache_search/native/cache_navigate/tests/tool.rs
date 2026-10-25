//! The navigate tool against a fake Valhalla: argument handling, name resolution, errors, the result shape.
//! The real routes (Idaho tiles, off-road pack) are tested through cs_tool in the cache_search_cli crate.

use cache_navigate::{NavigateCfg, NavigateTool, OffroadCfg, PlaceSlot, ValhallaCfg};
use cache_offroad::valhalla::{LocateSnap, Maneuver, Trace, Trip, Valhalla, ValhallaError};
use cache_tool::places::{GeocodeAnswer, GeocodeQuery, NearestQuery, PlaceMatch, PlaceSource};
use cache_tool::{Location, SavedPlace, SavedPlaces, Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Value};
use std::sync::{Arc, RwLock};

/// A road router that drives straight lines: `maneuvers` steps, the route starts and ends `snap` degrees from the points asked for.
struct Fake {
    maneuvers: usize,
    snap: f64,
    fail: Option<i64>,
    no_edges: bool,
    /// Extra seconds per degree of latitude travelled (0: every route takes the same time).
    per_deg_s: f64,
}

impl Valhalla for Fake {
    fn locate(&self, _lat: f64, _lon: f64, _costing: &str) -> Option<LocateSnap> {
        if self.no_edges {
            None
        } else {
            Some(LocateSnap { snap_distance_m: 5.0, road_class: None, use_: None })
        }
    }
    fn route(&self, from: (f64, f64), to: (f64, f64), _costing: &str) -> Result<Trip, ValhallaError> {
        if let Some(c) = self.fail {
            return Err(ValhallaError { code: Some(c), message: "No path could be found for input".into(), timeout: false });
        }
        let a = (from.0 + self.snap, from.1);
        let b = (to.0 + self.snap, to.1);
        let n = self.maneuvers.max(2);
        let shape: Vec<(f64, f64)> = (0..=n).map(|i| (a.0 + (b.0 - a.0) * i as f64 / n as f64, a.1 + (b.1 - a.1) * i as f64 / n as f64)).collect();
        let maneuvers: Vec<Maneuver> = (0..n)
            .map(|i| Maneuver {
                instruction: format!("Continue on Road {i}"),
                kind: if i == 0 { 1 } else if i == n - 1 { 4 } else { 8 },
                length_km: 1.5,
                time_s: 90.0,
                street_names: vec![format!("Road {}", i % 3)],
                begin_shape_index: i as i64,
                end_shape_index: i as i64 + 1,
                bearing_after: Some(90.0),
                bearing_before: None,
            })
            .collect();
        Ok(Trip { shape_encoded: cache_offroad::valhalla::encode_polyline6(&shape), shape, maneuvers, length_km: 1.5 * n as f64, time_s: 90.0 * n as f64 + (b.0 - a.0).abs() * self.per_deg_s })
    }
    fn trace_attributes(&self, _p: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("no"))
    }
}

struct Saved;
impl SavedPlaces for Saved {
    fn resolve(&self, name: &str) -> Option<SavedPlace> {
        (name.eq_ignore_ascii_case("home")).then(|| SavedPlace { key: "home".into(), name: "Home".into(), lat: 42.536, lon: -113.792, label: None })
    }
    fn list(&self) -> Vec<SavedPlace> {
        vec![]
    }
}

/// A places pack with three hospitals and a town.
struct Pack {
    empty: bool,
}
impl PlaceSource for Pack {
    fn categories(&self) -> Option<Vec<String>> {
        Some(vec!["hospital".into(), "fuel".into()])
    }
    fn geocode(&self, q: &GeocodeQuery) -> Result<GeocodeAnswer, ToolError> {
        let mut m = PlaceMatch::new("Cassia Regional Hospital", 42.531, -113.785);
        m.kind = Some("hospital".into());
        m.street = Some("1501 Hiland Ave".into());
        m.locality = Some("Burley".into());
        m.state = Some("ID".into());
        let mut other = PlaceMatch::new("Cassia Hospital Annex", 42.6, -113.7);
        other.locality = Some("Declo".into());
        let town = PlaceMatch::new("Rupert", 42.617, -113.675);
        Ok(GeocodeAnswer {
            matches: if self.empty {
                vec![]
            } else if q.text.contains("Rupert") {
                vec![town]
            } else {
                vec![m, other]
            },
            searched_within_km: Some(50.0),
        })
    }
    fn nearest(&self, q: &NearestQuery) -> Result<GeocodeAnswer, ToolError> {
        if self.empty {
            return Ok(GeocodeAnswer { matches: vec![], searched_within_km: Some(80.0) });
        }
        let far = PlaceMatch::new("Far Hospital", q.from.0 + 0.5, q.from.1);
        let near = PlaceMatch::new("Near Hospital", q.from.0 + 0.1, q.from.1);
        // the pack lists nearest by straight line; here the "far" one is listed first so the ranking must come from travel time
        Ok(GeocodeAnswer { matches: vec![far, near], searched_within_km: None })
    }
}

fn cfg() -> NavigateCfg {
    NavigateCfg {
        valhalla: Some(ValhallaCfg { tiles: "/nonexistent/idaho/valhalla/tiles.tar".into(), shim: "/nonexistent/shim".into(), region: Some("Idaho".into()) }),
        offroad: None,
    }
}

fn tool(fake: Fake, places: Option<Arc<dyn PlaceSource>>) -> NavigateTool {
    let slot: PlaceSlot = Arc::new(RwLock::new(places));
    NavigateTool::with_valhalla(cfg(), slot, Arc::new(fake))
}

fn fake() -> Fake {
    Fake { maneuvers: 5, snap: 0.0, fail: None, no_edges: false, per_deg_s: 0.0 }
}

const NOW: &str = "2026-10-25T12:00:00-06:00";

fn here() -> Location {
    Location { lat: 42.536, lon: -113.792, accuracy_m: Some(10.0), fixed_at: NOW.into() }
}

fn run(t: &NavigateTool, loc: Option<&Location>, args: Value) -> Result<Value, ToolError> {
    let ctx = ToolCtx { location: loc, places: &Saved, now: NOW };
    match t.run(&ctx, &args)? {
        ToolOutput::Json(v) => Ok(v),
        ToolOutput::Text(_) => panic!("navigate gives JSON"),
    }
}

fn code(r: Result<Value, ToolError>) -> String {
    r.expect_err("an error").code
}

#[test]
fn schema_needs_the_routing_data_and_lists_the_modes_and_types() {
    let slot: PlaceSlot = Default::default();
    let not_installed = NavigateTool::new(cfg(), slot.clone());
    assert!(not_installed.schema().is_none(), "tiles and shim are missing");
    assert!(NavigateTool::new(NavigateCfg::default(), slot).schema().is_none());

    let s = tool(fake(), None).schema().unwrap();
    let p = &s["function"]["parameters"]["properties"];
    assert_eq!(s["function"]["name"], "navigate");
    assert_eq!(p["mode"]["enum"], json!(["drive", "walk", "bike", "offroad_vehicle", "offroad_foot"]));
    // no places pack: TOOLS.md's list
    assert_eq!(p["to_type"]["enum"][0], "emergency_room");
    assert_eq!(p["to_type"]["enum"].as_array().unwrap().len(), 11);
    assert_eq!(s["function"]["parameters"]["required"], json!(["mode"]));
    assert_eq!(p.as_object().unwrap().keys().collect::<Vec<_>>(), ["from", "to", "to_type", "mode", "near", "land_access"]);
    // a places pack: its categories
    let s = tool(fake(), Some(Arc::new(Pack { empty: false }))).schema().unwrap();
    assert_eq!(s["function"]["parameters"]["properties"]["to_type"]["enum"], json!(["hospital", "fuel"]));
}

#[test]
fn road_route_has_the_documented_shape() {
    let t = tool(fake(), None);
    let v = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": "drive"})).unwrap();
    let keys: Vec<&String> = v.as_object().unwrap().keys().collect();
    assert_eq!(
        keys,
        ["address", "mode", "location_bias", "from_matched", "to_matched", "distance_mi", "distance_km", "duration_minutes", "major_roads", "step_count", "steps", "steps_truncated", "steps_omitted", "map_region", "map_region_age"]
    );
    assert!(v["address"].as_str().unwrap().starts_with("nav:"));
    assert_eq!(v["mode"], "drive");
    assert_eq!(v["location_bias"], "phone_location");
    assert_eq!(v["from_matched"], json!({"place_name": "current location", "lat": 42.536, "lon": -113.792}));
    assert_eq!(v["to_matched"], json!({"place_name": "42.60,-113.70", "lat": 42.6, "lon": -113.7}));
    assert_eq!(v["step_count"], 5);
    assert_eq!(v["steps_truncated"], false);
    assert_eq!(v["steps_omitted"], 0);
    assert_eq!(v["distance_km"], 7.5);
    assert_eq!(v["duration_minutes"], 7.5);
    assert_eq!(v["major_roads"], json!(["Road 0", "Road 1", "Road 2"]));
    assert_eq!(v["map_region"], "Idaho");
    // the tiles file does not exist, so its age is not known
    assert_eq!(v["map_region_age"], "unknown");
    let s0 = &v["steps"][0];
    assert_eq!(s0.as_object().unwrap().keys().collect::<Vec<_>>(), ["index", "kind", "street_names", "distance_mi", "cardinal", "instruction"]);
    assert_eq!(s0["kind"], "road");
    assert_eq!(s0["cardinal"], "E");
    assert_eq!(s0["instruction"], "Continue on Road 0");
    assert_eq!(s0["distance_mi"], 0.9);
}

#[test]
fn steps_are_capped_at_15() {
    let t = tool(Fake { maneuvers: 20, ..fake() }, None);
    let v = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": "drive"})).unwrap();
    assert_eq!(v["step_count"], 20);
    assert_eq!(v["steps"].as_array().unwrap().len(), 15);
    assert_eq!(v["steps_truncated"], true);
    assert_eq!(v["steps_omitted"], 5);
    assert_eq!(v["steps"][14]["index"], 14);
}

#[test]
fn names_resolve_through_coordinates_saved_places_and_the_places_pack() {
    let t = tool(fake(), None);
    // a saved place, case-insensitively, as the start
    let v = run(&t, None, json!({"from": "home", "to": "42.60,-113.70", "mode": "walk"})).unwrap();
    assert_eq!(v["from_matched"]["place_name"], "Home");
    assert_eq!(v["location_bias"], "none");
    assert_eq!(v["mode"], "walk");
    // a name nothing knows
    let e = run(&t, Some(&here()), json!({"to": "Cassia Regional Hospital", "mode": "drive"})).unwrap_err();
    assert_eq!(e.code, "geocode_empty");
    assert_eq!(e.extra["which"], "to");
    assert_eq!(e.extra["query"], "Cassia Regional Hospital");
    assert_eq!(e.extra["searched_within_km"], Value::Null);
    let e = run(&t, Some(&here()), json!({"from": "Nowhere", "to": "Home", "mode": "drive"})).unwrap_err();
    assert_eq!((e.code.as_str(), e.extra["which"].clone()), ("geocode_empty", json!("from")));

    // with a places pack: the match, its details, and the other candidates
    let t = tool(fake(), Some(Arc::new(Pack { empty: false })));
    let v = run(&t, Some(&here()), json!({"to": "Cassia Regional Hospital", "mode": "drive", "near": "Burley, Idaho"})).unwrap();
    assert_eq!(
        v["to_matched"],
        json!({"place_name": "Cassia Regional Hospital", "kind": "hospital", "street": "1501 Hiland Ave", "locality": "Burley", "state": "ID", "lat": 42.531, "lon": -113.785})
    );
    assert_eq!(v["other_destination_candidates"], json!([{"place_name": "Cassia Hospital Annex", "locality": "Declo"}]));
    assert_eq!(v["location_bias"], "near");
    let t = tool(fake(), Some(Arc::new(Pack { empty: true })));
    let e = run(&t, Some(&here()), json!({"to": "Zzz", "mode": "drive"})).unwrap_err();
    assert_eq!((e.code.as_str(), e.extra["searched_within_km"].clone()), ("geocode_empty", json!(50.0)));
}

#[test]
fn origin_errors() {
    let t = tool(fake(), None);
    assert_eq!(code(run(&t, None, json!({"to": "42.60,-113.70", "mode": "drive"}))), "no_location");
    // near names the town but nothing can find it
    assert_eq!(code(run(&t, None, json!({"to": "42.60,-113.70", "mode": "drive", "near": "Burley, Idaho"}))), "origin_unknown");
    // a places pack finds the town, so it is the start
    let t = tool(fake(), Some(Arc::new(Pack { empty: false })));
    let v = run(&t, None, json!({"to": "42.60,-113.70", "mode": "drive", "near": "Rupert, Idaho"})).unwrap();
    assert_eq!(v["from_matched"]["place_name"], "Rupert");
    assert_eq!(v["location_bias"], "near");
}

#[test]
fn argument_errors() {
    let t = tool(fake(), None);
    for (args, field) in [
        (json!({"mode": "drive"}), "give either to"),
        (json!({"to": "Home", "to_type": "fuel", "mode": "drive"}), "not both"),
        (json!({"to": "Home", "mode": "teleport"}), "mode"),
        (json!({"to": "Home", "mode": "drive", "bogus": 1}), "bogus"),
        (json!({"to": "Home", "mode": "drive", "land_access": "reckless"}), "land_access"),
        (json!({"to": "Home"}), "mode"),
    ] {
        let e = run(&t, Some(&here()), args.clone()).unwrap_err();
        assert_eq!(e.code, "bad_arguments", "{args}");
        assert!(e.detail.contains(field), "{args}: {}", e.detail);
    }
}

#[test]
fn same_place() {
    let t = tool(fake(), None);
    assert_eq!(code(run(&t, Some(&here()), json!({"to": "Home", "mode": "drive"}))), "same_place");
    assert_eq!(code(run(&t, Some(&here()), json!({"to": "42.5361,-113.7921", "mode": "drive"}))), "same_place");
}

#[test]
fn nearest_of_a_type_is_ranked_by_travel_time() {
    // no places pack
    let t = tool(fake(), None);
    let e = run(&t, Some(&here()), json!({"to_type": "hospital", "mode": "drive"})).unwrap_err();
    assert_eq!(e.code, "not_set_up");
    // with one: the listed-first "Far Hospital" is farther in minutes, so the near one wins
    let t = tool(Fake { per_deg_s: 6000.0, ..fake() }, Some(Arc::new(Pack { empty: false })));
    let v = run(&t, Some(&here()), json!({"to_type": "hospital", "mode": "drive"})).unwrap();
    assert_eq!(v["to_matched"]["place_name"], "Near Hospital");
    assert_eq!(v["nearest_search"], json!({"to_type": "hospital", "ranked_by": "drive_time"}));
    assert_eq!(v["other_destination_candidates"], json!([{"place_name": "Far Hospital", "drive_min": 57.5}]));
    // nothing of that type
    let t = tool(fake(), Some(Arc::new(Pack { empty: true })));
    let e = run(&t, Some(&here()), json!({"to_type": "hospital", "mode": "drive"})).unwrap_err();
    assert_eq!(e.code, "nearby_empty");
    assert_eq!((e.extra["to_type"].clone(), e.extra["searched_within_km"].clone()), (json!("hospital"), json!(80.0)));
    // a type the pack does not have
    let t = tool(fake(), Some(Arc::new(Pack { empty: false })));
    assert_eq!(code(run(&t, Some(&here()), json!({"to_type": "pharmacy", "mode": "drive"}))), "bad_arguments");
}

#[test]
fn route_failures() {
    let t = tool(Fake { fail: Some(442), ..fake() }, None);
    let e = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": "drive"})).unwrap_err();
    assert_eq!(e.code, "route_failed");
    assert_eq!(e.extra["reason"], "no_route");
    // no road near an end and no map there: not set up
    let t = tool(Fake { fail: Some(171), no_edges: true, ..fake() }, None);
    let e = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": "drive"})).unwrap_err();
    assert_eq!(e.code, "not_set_up");
    assert!(e.detail.contains("start"), "{}", e.detail);
}

#[test]
fn off_road_modes_need_the_off_road_data() {
    let t = tool(fake(), None);
    for mode in ["offroad_vehicle", "offroad_foot"] {
        let e = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": mode})).unwrap_err();
        assert_eq!(e.code, "not_set_up");
        assert!(e.detail.contains("off-road"), "{}", e.detail);
    }
    // a pack and elevation that are configured but missing are also not set up
    let mut c = cfg();
    c.offroad = Some(OffroadCfg { pack: "/nonexistent/offroad.sqlite".into(), elevation: "/nonexistent/elevation.pmtiles".into(), max_cells: None });
    let slot: PlaceSlot = Default::default();
    let t = NavigateTool::with_valhalla(c, slot, Arc::new(fake()));
    assert_eq!(code(run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": "offroad_foot"}))), "not_set_up");
}

#[test]
fn an_end_off_the_road_network_without_off_road_data_is_a_warning() {
    // the route starts 0.01 degrees (1.1 km) from the points asked for
    let t = tool(Fake { snap: 0.01, ..fake() }, None);
    let v = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": "drive"})).unwrap();
    let w = v["warnings"].as_array().unwrap();
    assert_eq!(w.len(), 2);
    assert_eq!(w[0]["code"], "offroad_unavailable");
    assert!(w[0]["gap_m"].as_i64().unwrap() > 1000);
    assert_eq!(w[0].as_object().unwrap().keys().collect::<Vec<_>>(), ["code", "gap_m"]);
}
