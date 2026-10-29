//! The navigate tool against a fake Valhalla: argument handling, name resolution, errors, the result shape.
//! The real routes (Idaho tiles, off-road pack) are tested through cs_tool in the cache_search_cli crate.

use cache_navigate::{NavigateCfg, NavigateTool, PlaceSlot, ValhallaCfg};
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
    /// The first this many `route` calls fail (the later ones succeed).
    fail_first: std::sync::atomic::AtomicUsize,
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
        let left = self.fail_first.load(std::sync::atomic::Ordering::SeqCst);
        if left > 0 {
            self.fail_first.store(left - 1, std::sync::atomic::Ordering::SeqCst);
            return Err(ValhallaError { code: Some(442), message: "No path could be found for input".into(), timeout: false });
        }
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
    Fake { maneuvers: 5, snap: 0.0, fail: None, no_edges: false, per_deg_s: 0.0, fail_first: std::sync::atomic::AtomicUsize::new(0) }
}

const NOW: &str = "2026-10-25T12:00:00-06:00";

fn here() -> Location {
    Location { lat: 42.536, lon: -113.792, accuracy_m: Some(10.0), fixed_at: NOW.into() }
}

fn run(t: &NavigateTool, loc: Option<&Location>, args: Value) -> Result<Value, ToolError> {
    let ctx = ToolCtx { location: loc, places: &Saved, now: NOW, geocoder: None, live_fetcher: None };
    match t.run(&ctx, &args)? {
        ToolOutput::Json(v) => Ok(v),
        ToolOutput::Text(_) => panic!("navigate gives JSON"),
    }
}

fn code(r: Result<Value, ToolError>) -> String {
    r.expect_err("an error").code
}

fn keys(v: &Value) -> Vec<&str> {
    v.as_object().unwrap().keys().map(String::as_str).collect()
}

const PLACE_KEYS: [&str; 7] = ["place_name", "kind", "street", "locality", "county", "state", "distance_km"];

#[test]
fn schema_needs_the_routing_data_and_lists_the_modes_and_types() {
    let slot: PlaceSlot = Default::default();
    let not_installed = NavigateTool::new(cfg(), slot.clone());
    assert!(not_installed.schema().is_none(), "tiles and shim are missing");
    assert!(NavigateTool::new(NavigateCfg::default(), slot).schema().is_none());

    let s = tool(fake(), None).schema().unwrap();
    let p = &s["function"]["parameters"]["properties"];
    assert_eq!(s["function"]["name"], "navigate");
    // AIDA's modes (off-road legs come inside the result), then the two off-road modes
    assert_eq!(p["mode"]["enum"], json!(["drive", "walk", "bike", "offroad_foot", "offroad_vehicle"]));
    assert!(p["mode"]["description"].as_str().unwrap().contains("offroad_vehicle"));
    assert_eq!(p["to_type"]["enum"][0], "emergency_room");
    assert_eq!(p["to_type"]["enum"].as_array().unwrap().len(), 11);
    assert_eq!(s["function"]["parameters"]["required"], json!(["mode"]));
    // land_access is the one new argument, last
    assert_eq!(keys(p), ["from", "to", "to_type", "mode", "near", "land_access"]);
    assert_eq!(p["land_access"]["enum"], json!(["strict", "pragmatic", "emergency"]));
    let s = tool(fake(), Some(Arc::new(Pack { empty: false }))).schema().unwrap();
    assert_eq!(s["function"]["parameters"]["properties"]["to_type"]["enum"], json!(["hospital", "fuel"]));
}

#[test]
fn road_route_has_aidas_shape() {
    let t = tool(fake(), None);
    let v = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": "drive"})).unwrap();
    assert_eq!(
        keys(&v),
        ["address", "mode", "location_bias", "route_id", "from_matched", "to_matched", "other_destination_candidates", "distance_mi", "distance_km", "duration_minutes", "direction_from_start", "major_roads", "traffic", "map_region", "map_region_age"]
    );
    // no traffic source yet: the block is always there and null
    assert_eq!(v["traffic"], Value::Null);
    assert!(v["address"].as_str().unwrap().starts_with("nav:"));
    assert_eq!(v["address"], format!("nav:{}", v["route_id"].as_str().unwrap()));
    assert_eq!(v["mode"], "drive");
    assert_eq!(v["location_bias"], "sender_node_position");
    let mut want: Vec<&str> = PLACE_KEYS.to_vec();
    want.extend(["near", "snap_distance_m", "lat", "lon"]);
    assert_eq!(keys(&v["from_matched"]), want);
    assert_eq!(v["from_matched"]["place_name"], "current location");
    assert_eq!(v["to_matched"]["place_name"], "42.60,-113.70");
    assert_eq!(v["from_matched"]["snap_distance_m"], 0);
    assert_eq!(v["other_destination_candidates"], json!([]));
    assert_eq!(v["distance_km"], 7.5);
    assert_eq!(v["duration_minutes"], 7.5);
    assert_eq!(v["major_roads"][0], json!({"name": "Road 0", "distance_km": 3.0}));
    assert_eq!(v["map_region"], "Idaho");
    assert_eq!(v["map_region_age"], "unknown");
    assert!(v.get("steps").is_none());
    let snapshot = t.core().tool_route(v["route_id"].as_str().unwrap()).unwrap();
    assert_eq!(snapshot["maneuvers"].as_array().unwrap().len(), 5);
}

#[test]
fn assistant_gets_summary_and_navigation_page_gets_all_steps() {
    let t = tool(Fake { maneuvers: 20, ..fake() }, None);
    let v = run(&t, Some(&here()), json!({"to":"42.60,-113.70", "mode":"drive"})).unwrap();
    for k in ["steps", "step_count", "steps_truncated", "road_steps_omitted", "offroad_steps_omitted", "geometry", "maneuvers"] {
        assert!(v.get(k).is_none(), "model context must not carry {k}");
    }
    let snapshot = t.core().tool_route(v["route_id"].as_str().unwrap()).unwrap();
    assert_eq!(snapshot["maneuvers"].as_array().unwrap().len(), 20);
    assert!(v["distance_km"].as_f64().unwrap() > 0.0);
}

#[test]
fn names_resolve_through_coordinates_saved_places_and_the_places_pack() {
    let t = tool(fake(), None);
    let v = run(&t, None, json!({"from": "home", "to": "42.60,-113.70", "mode": "walk"})).unwrap();
    assert_eq!(v["from_matched"]["place_name"], "Home");
    // no fix and no near: the matched start is the area
    assert_eq!(v["location_bias"], "from_place");
    assert_eq!(v["mode"], "walk");
    // a name nothing knows: AIDA's fields, no detail, no matched places
    let e = run(&t, Some(&here()), json!({"to": "Cassia Regional Hospital", "mode": "drive"})).unwrap_err();
    assert_eq!(e.to_json(), json!({"ok": false, "error": {"type": "geocode_empty", "which": "to", "query": "Cassia Regional Hospital", "searched_within_km": null}}));
    // a from that is not found says to omit it, because the phone's position is known
    let e = run(&t, Some(&here()), json!({"from": "Nowhere", "to": "Home", "mode": "drive"})).unwrap_err();
    assert_eq!(keys(&e.to_json()["error"]), ["type", "which", "query", "searched_within_km", "hint"]);
    assert_eq!(e.extra["which"], "from");
    let e = run(&t, None, json!({"from": "Nowhere", "to": "Home", "mode": "drive"})).unwrap_err();
    assert!(e.extra.get("hint").is_none());

    // with a places pack: the match, its details, and the other candidates
    let t = tool(fake(), Some(Arc::new(Pack { empty: false })));
    let v = run(&t, Some(&here()), json!({"to": "Cassia Regional Hospital", "mode": "drive", "near": "Burley, Idaho"})).unwrap();
    assert_eq!(v["to_matched"]["place_name"], "Cassia Regional Hospital");
    assert_eq!(v["to_matched"]["street"], "1501 Hiland Ave");
    assert_eq!(v["to_matched"]["locality"], "Burley");
    assert_eq!(v["other_destination_candidates"][0]["place_name"], "Cassia Hospital Annex");
    assert_eq!(keys(&v["other_destination_candidates"][0]), PLACE_KEYS);
    let t = tool(fake(), Some(Arc::new(Pack { empty: true })));
    let e = run(&t, Some(&here()), json!({"to": "Zzz", "mode": "drive"})).unwrap_err();
    assert_eq!((e.code.as_str(), e.extra["searched_within_km"].clone()), ("geocode_empty", json!(50.0)));
}

#[test]
fn location_bias_values() {
    let t = tool(fake(), Some(Arc::new(Pack { empty: false })));
    // the phone's position wins over near
    let v = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": "drive", "near": "Rupert, Idaho"})).unwrap();
    assert_eq!(v["location_bias"], "sender_node_position");
    // no fix: near, by the name the pack gave it
    let v = run(&t, None, json!({"from": "42.5,-113.8", "to": "42.60,-113.70", "mode": "drive", "near": "Rupert, Idaho"})).unwrap();
    assert_eq!(v["location_bias"], "near:Rupert");
}

#[test]
fn origin_errors() {
    let t = tool(fake(), None);
    let e = run(&t, None, json!({"to": "42.60,-113.70", "mode": "drive"})).unwrap_err();
    assert_eq!(e.to_json(), json!({"ok": false, "error": {"type": "origin_unknown", "detail": "no from and no phone location"}}));
    assert_eq!(code(run(&t, None, json!({"to": "42.60,-113.70", "mode": "drive", "near": "Burley, Idaho"}))), "origin_unknown");
}

#[test]
fn argument_errors() {
    let t = tool(fake(), None);
    for (args, field) in [
        (json!({"mode": "drive"}), "give exactly one of to or to_type"),
        (json!({"to": "Home", "to_type": "fuel", "mode": "drive"}), "give exactly one of to or to_type"),
        (json!({"to": "Home", "mode": "teleport"}), "mode"),
        (json!({"to": "Home", "mode": "offroad"}), "mode"),
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
fn same_place_carries_both_places() {
    let t = tool(fake(), None);
    let e = run(&t, Some(&here()), json!({"to": "Home", "mode": "drive"})).unwrap_err();
    let j = e.to_json();
    assert_eq!(keys(&j), ["ok", "error", "from_matched", "to_matched"]);
    assert_eq!(keys(&j["error"]), ["type", "detail", "hint"]);
    assert_eq!(j["error"]["detail"], "start and destination matched the same spot");
    assert_eq!(keys(&j["from_matched"]), PLACE_KEYS);
    assert_eq!(j["to_matched"]["place_name"], "Home");
    assert_eq!(code(run(&t, Some(&here()), json!({"to": "42.5361,-113.7921", "mode": "drive"}))), "same_place");
}

#[test]
fn nearest_of_a_type_is_ranked_by_travel_time() {
    let t = tool(fake(), None);
    let e = run(&t, Some(&here()), json!({"to_type": "hospital", "mode": "drive"})).unwrap_err();
    assert_eq!(e.code, "not_set_up");
    let t = tool(Fake { per_deg_s: 6000.0, ..fake() }, Some(Arc::new(Pack { empty: false })));
    let v = run(&t, Some(&here()), json!({"to_type": "hospital", "mode": "drive"})).unwrap();
    assert_eq!(v["to_matched"]["place_name"], "Near Hospital");
    assert_eq!(v["nearest_search"], json!({"to_type": "hospital", "ranked_by": "drive", "warnings": []}));
    let c = &v["other_destination_candidates"][0];
    assert_eq!(keys(c), ["place_name", "kind", "street", "locality", "county", "state", "distance_km", "drive_min"]);
    assert_eq!((c["place_name"].clone(), c["drive_min"].clone()), (json!("Far Hospital"), json!(57.5)));
    let k = keys(&v);
    assert_eq!(k[k.iter().position(|x| *x == "other_destination_candidates").unwrap() + 1], "nearest_search");
    // nothing of that type: AIDA's fields, and the start beside the error
    let t = tool(fake(), Some(Arc::new(Pack { empty: true })));
    let e = run(&t, Some(&here()), json!({"to_type": "hospital", "mode": "drive"})).unwrap_err();
    let j = e.to_json();
    assert_eq!(j["error"], json!({"type": "nearby_empty", "to_type": "hospital", "warnings": []}));
    assert!(j["error"]["warnings"].is_array(), "warnings is a list, never null: {j}");
    assert_eq!(keys(&j), ["ok", "error", "from_matched"]);
    let t = tool(fake(), Some(Arc::new(Pack { empty: false })));
    assert_eq!(code(run(&t, Some(&here()), json!({"to_type": "pharmacy", "mode": "drive"}))), "bad_arguments");
}

/// AIDA passes navi's `nearest_search` through: `ranked_by` is `drive` or `distance` (never the travel mode) and
/// `warnings` is a list.
#[test]
fn nearest_search_ranked_by_is_drive_or_distance_and_warnings_is_a_list() {
    for mode in ["drive", "walk", "bike"] {
        let t = tool(Fake { per_deg_s: 6000.0, ..fake() }, Some(Arc::new(Pack { empty: false })));
        let v = run(&t, Some(&here()), json!({"to_type": "hospital", "mode": mode})).unwrap();
        assert_eq!(v["mode"], mode);
        assert_eq!(v["nearest_search"], json!({"to_type": "hospital", "ranked_by": "drive", "warnings": []}), "mode {mode}");
        assert_eq!(v["to_matched"]["place_name"], "Near Hospital", "mode {mode}");
    }
    // routing fails for both candidates, then works for the chosen route: ranked by distance, with a warning string
    let t = tool(Fake { fail_first: std::sync::atomic::AtomicUsize::new(2), ..fake() }, Some(Arc::new(Pack { empty: false })));
    let v = run(&t, Some(&here()), json!({"to_type": "hospital", "mode": "walk"})).unwrap();
    let ns = &v["nearest_search"];
    assert_eq!((ns["to_type"].clone(), ns["ranked_by"].clone()), (json!("hospital"), json!("distance")));
    let w = ns["warnings"].as_array().expect("warnings is a list");
    assert_eq!(w.len(), 1);
    assert!(w[0].is_string());
    // the pack's order stands: "Far Hospital" was listed first
    assert_eq!(v["to_matched"]["place_name"], "Far Hospital");
}

#[test]
fn router_errors_pass_through_with_both_places() {
    let t = tool(Fake { fail: Some(442), ..fake() }, None);
    let e = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": "drive"})).unwrap_err();
    let j = e.to_json();
    assert_eq!(j["error"]["type"], "no_route");
    assert_eq!(j["error"]["detail"], "No path could be found for input");
    assert_eq!(keys(&j), ["ok", "error", "from_matched", "to_matched"]);
    let t = tool(Fake { fail: Some(171), no_edges: true, ..fake() }, None);
    let e = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": "drive"})).unwrap_err();
    assert_eq!(e.code, "too_far");
}

#[test]
fn an_end_off_the_road_network_without_off_road_data_is_a_warning() {
    // the route starts 0.01 degrees (1.1 km) from the points asked for
    let t = tool(Fake { snap: 0.01, ..fake() }, None);
    let v = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": "drive"})).unwrap();
    let w = v["warnings"].as_array().unwrap();
    assert_eq!(w.len(), 2);
    assert_eq!(keys(&w[0]), ["code", "end", "road_point", "gap_m", "reason", "detail"]);
    assert_eq!((w[0]["reason"].clone(), w[1]["reason"].clone()), (json!("not_downloaded"), json!("not_downloaded")));
    assert_eq!(w[0]["detail"], "Off-road data for this area isn't on the phone; it loads when the phone is online.");
    assert_eq!((w[0]["code"].clone(), w[0]["end"].clone(), w[1]["end"].clone()), (json!("offroad_unavailable"), json!("from"), json!("to")));
    assert!(w[0]["gap_m"].as_i64().unwrap() > 1000);
    assert_eq!(keys(&w[0]["road_point"]), ["lat", "lon"]);
    let k = keys(&v);
    assert_eq!(k[k.len() - 3..], ["warnings", "map_region", "map_region_age"]);
}

#[test]
fn navigation_page_gets_the_exact_complete_tool_route_and_cache_is_bounded() {
    let t = tool(Fake { maneuvers: 27, ..fake() }, None);
    let first = run(&t, Some(&here()), json!({"to":"42.60,-113.70", "mode":"bike", "land_access":"strict"})).unwrap();
    let id = first["route_id"].as_str().unwrap();
    let snapshot = t.core().tool_route(id).unwrap();
    assert_eq!(snapshot["ok"], true);
    assert_eq!(snapshot["route_id"], id);
    assert_eq!(snapshot["mode"], "bike");
    assert_eq!(snapshot["land_access"], "strict");
    assert_eq!(snapshot["maneuvers"].as_array().unwrap().len(), 27);
    assert!(!snapshot["geometry"].as_str().unwrap().is_empty());
    assert_eq!(snapshot["to"]["lat"], 42.6);
    assert_eq!(snapshot["alternatives"], json!([]));
    assert_eq!(t.core().tool_route(id).unwrap(), snapshot);
    assert!(t.core().tool_route("missing").is_none());
    for i in 0..8 {
        run(&t, Some(&here()), json!({"to":format!("{},-113.70", 42.61 + i as f64 * 0.01), "mode":"walk"})).unwrap();
    }
    assert!(t.core().tool_route(id).is_none(), "oldest of nine distinct routes is evicted");
}

#[test]
fn offroad_modes_without_the_off_road_data_say_what_is_missing() {
    // no off-road pack installed: no road route instead, and no off-road guess
    let t = tool(fake(), None);
    for mode in ["offroad_foot", "offroad_vehicle"] {
        for land in ["strict", "pragmatic", "emergency"] {
            let e = run(&t, Some(&here()), json!({"to": "42.60,-113.70", "mode": mode, "land_access": land})).unwrap_err();
            assert_eq!(e.code, "not_set_up", "{mode} {land}");
            assert_eq!(e.detail, cache_offroad::directions::OFFROAD_DATA_MISSING);
            let j = e.to_json();
            assert_eq!(keys(&j), ["ok", "error", "from_matched", "to_matched"]);
        }
    }
}
