//! navigate's `to` and `from` matching a point of the user's map layers by its exact name, before the places search.

use cache_navigate::{NavigateCfg, NavigateTool, PlaceSlot, ValhallaCfg};
use cache_offroad::valhalla::{LocateSnap, Maneuver, Trace, Trip, Valhalla, ValhallaError};
use cache_tool::places::{GeocodeAnswer, GeocodeQuery, Geocoder, NearestQuery, PlaceMatch, PlaceSource};
use cache_tool::user::{UserCategory, UserPoint, UserPoints, UserPointsSlot};
use cache_tool::{Location, NoSavedPlaces, Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Map, Value};
use std::sync::{Arc, RwLock};

/// Straight-line routes of two 1.5 km steps.
struct Fake;
impl Valhalla for Fake {
    fn locate(&self, _lat: f64, _lon: f64, _costing: &str) -> Option<LocateSnap> {
        Some(LocateSnap { snap_distance_m: 5.0, road_class: None, use_: None })
    }
    fn route(&self, from: (f64, f64), to: (f64, f64), _costing: &str) -> Result<Trip, ValhallaError> {
        let shape = vec![from, ((from.0 + to.0) / 2.0, (from.1 + to.1) / 2.0), to];
        let maneuvers = (0..2)
            .map(|i| Maneuver {
                instruction: format!("Continue on Road {i}"),
                kind: if i == 0 { 1 } else { 4 },
                length_km: 1.5,
                time_s: 90.0,
                street_names: vec![format!("Road {i}")],
                begin_shape_index: i,
                end_shape_index: i + 1,
                bearing_after: Some(90.0),
                bearing_before: None,
            })
            .collect();
        Ok(Trip { shape_encoded: cache_offroad::valhalla::encode_polyline6(&shape), shape, maneuvers, length_km: 3.0, time_s: 180.0 })
    }
    fn trace_attributes(&self, _p: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("no"))
    }
}

/// A places pack that knows one hospital called "Rally Point" (so the layer point must win) and that the nearest town is Burley.
struct Pack;
impl Geocoder for Pack {
    fn resolve(&self, _text: &str, _near: Option<(f64, f64)>) -> Option<(String, f64, f64)> {
        None
    }
    fn nearest_town(&self, _lat: f64, _lon: f64) -> Option<String> {
        Some("Burley".into())
    }
}
impl PlaceSource for Pack {
    fn geocoder(&self) -> Option<&dyn Geocoder> {
        Some(self)
    }
    fn categories(&self) -> Option<Vec<String>> {
        Some(vec!["hospital".into()])
    }
    fn geocode(&self, _q: &GeocodeQuery) -> Result<GeocodeAnswer, ToolError> {
        let mut m = PlaceMatch::new("Rally Point Clinic", 43.0, -114.0);
        m.kind = Some("hospital".into());
        Ok(GeocodeAnswer { matches: vec![m], searched_within_km: Some(50.0) })
    }
    fn nearest(&self, _q: &NearestQuery) -> Result<GeocodeAnswer, ToolError> {
        Ok(GeocodeAnswer::default())
    }
}

/// Two layers with a point named "North gate"; the first is the most recently used.
struct Layers;
fn point(addr: &str, layer: &str, lat: f64, lon: f64) -> UserPoint {
    UserPoint { address: addr.into(), name: "North gate".into(), kind: "layer_point".into(), kind_label: layer.into(), locality: None, lat, lon, fields: Map::new() }
}
impl UserPoints for Layers {
    fn categories(&self) -> Vec<UserCategory> {
        vec![]
    }
    fn points(&self, _category: &str) -> Option<Vec<UserPoint>> {
        None
    }
    fn named(&self, name: &str) -> Vec<UserPoint> {
        if name.trim().eq_ignore_ascii_case("north gate") {
            vec![point("layer:y2/1", "Elk Camp", 42.60, -113.70), point("layer:y1/1", "Rally Points", 42.55, -113.79)]
        } else {
            vec![]
        }
    }
}

fn tool(with_layers: bool) -> NavigateTool {
    let cfg = NavigateCfg {
        valhalla: Some(ValhallaCfg { tiles: "/nonexistent/idaho/valhalla/tiles.tar".into(), shim: "/nonexistent/shim".into(), region: Some("Idaho".into()) }),
        offroad: None,
    };
    let places: PlaceSlot = Arc::new(RwLock::new(Some(Arc::new(Pack) as Arc<dyn PlaceSource>)));
    let user: UserPointsSlot = Arc::new(RwLock::new(with_layers.then(|| Arc::new(Layers) as Arc<dyn UserPoints>)));
    NavigateTool::with_valhalla(cfg, places, Arc::new(Fake)).with_user(user)
}

fn run(t: &NavigateTool, args: Value) -> Value {
    let here = Location { lat: 42.536, lon: -113.792, accuracy_m: Some(10.0), fixed_at: "2026-10-25T12:00:00-06:00".into() };
    let ctx = ToolCtx { location: Some(&here), places: &NoSavedPlaces, now: "2026-10-25T12:00:00-06:00", geocoder: None, live_fetcher: None };
    match t.run(&ctx, &args) {
        Ok(ToolOutput::Json(v)) => v,
        Ok(ToolOutput::Text(_)) => panic!("text"),
        Err(e) => e.to_json(),
    }
}

#[test]
fn to_matches_a_layer_point_and_the_same_name_elsewhere_is_a_candidate() {
    let v = run(&tool(true), json!({"to": "north GATE", "mode": "drive"}));
    assert_eq!(
        v["to_matched"].to_string(),
        r#"{"place_name":"North gate","kind":"layer_point","kind_label":"Elk Camp","street":null,"locality":"Burley","county":null,"state":null,"distance_km":10.363720836252638,"near":null,"snap_distance_m":0,"lat":42.6,"lon":-113.7}"#
    );
    assert_eq!(
        v["other_destination_candidates"].to_string(),
        r#"[{"place_name":"North gate","kind":"layer_point","kind_label":"Rally Points","street":null,"locality":"Burley","county":null,"state":null,"distance_km":1.5653280747254208}]"#
    );
}

#[test]
fn from_matches_a_layer_point_too() {
    let v = run(&tool(true), json!({"from": "North gate", "to": "42.70,-113.60", "mode": "drive"}));
    assert_eq!((v["from_matched"]["kind"].as_str(), v["from_matched"]["kind_label"].as_str()), (Some("layer_point"), Some("Elk Camp")));
}

#[test]
fn without_layers_the_places_search_answers_and_no_kind_label_is_added() {
    let v = run(&tool(false), json!({"to": "north gate", "mode": "drive"}));
    assert_eq!(v["to_matched"]["place_name"], "Rally Point Clinic");
    assert!(v["to_matched"].get("kind_label").is_none());
    let v = run(&tool(true), json!({"to": "Rally Point", "mode": "drive"}));
    assert_eq!(v["to_matched"]["place_name"], "Rally Point Clinic", "only exact layer point names match");
}
