//! Directions on the Idaho data against navi PROD's POST /api/directions (recorded 2026-10-25, mode drive,
//! describe_ends false). Runs only with the Idaho env vars (see parity_idaho.rs).
//!
//! D4 (Yellow Pine) and D6 (track to track) are pure Valhalla road routes: steps, summary and shape must be
//! identical. D1 (wilderness start, 40 km) has an off-road lead leg whose cells differ by the layer-alignment
//! effect (DESIGN-OFFROAD.md); its totals must agree to 2% and the road part is the same.
#![cfg(feature = "shim")]
use cache_offroad::directions::*;
use cache_offroad::shim::{config_for_tiles, ShimValhalla};
use cache_offroad::{PmtilesElevation, RouteOptions, SqlitePack};
use serde_json::Value;
use std::path::Path;

fn run(from: (f64, f64), to: (f64, f64)) -> Option<(Value, Directions)> {
    let env = |k: &str| std::env::var(k).ok();
    let (Some(pack), Some(elev), Some(lib), Some(tiles)) =
        (env("OFFROAD_IDAHO_PACK"), env("OFFROAD_IDAHO_ELEVATION"), env("OFFROAD_VALHALLA_LIB"), env("OFFROAD_VALHALLA_TILES"))
    else {
        eprintln!("Idaho data env vars not set: skipping");
        return None;
    };
    let pack = SqlitePack::open(Path::new(&pack)).unwrap();
    let elev = PmtilesElevation::open(Path::new(&elev)).unwrap();
    let v = ShimValhalla::load(Path::new(&lib), &config_for_tiles(Path::new(&tiles))).unwrap();
    let e = Env { pack: &pack, elevation: &elev, valhalla: &v, options: RouteOptions::default(), namer: None, version: "test".into() };
    let d = e.directions(&DirectionsRequest::new(from, to, TravelMode::Drive));
    Some((d.to_json(), d))
}

fn cmp(a: &Value, b: &Value, path: &str) {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => assert!((x.as_f64().unwrap() - y.as_f64().unwrap()).abs() <= 1e-9, "{path}: {x} vs {y}"),
        (Value::Array(x), Value::Array(y)) => {
            assert_eq!(x.len(), y.len(), "{path}");
            for (i, (p, q)) in x.iter().zip(y).enumerate() {
                cmp(p, q, &format!("{path}[{i}]"));
            }
        }
        (Value::Object(x), Value::Object(y)) => {
            for k in x.keys().chain(y.keys()) {
                cmp(x.get(k).unwrap_or(&Value::Null), y.get(k).unwrap_or(&Value::Null), &format!("{path}.{k}"));
            }
        }
        _ => assert_eq!(a, b, "{path}"),
    }
}

#[test]
fn road_directions_identical_to_navi() {
    for (name, from, to, expected) in [
        ("D4", (44.95441, -115.48184), (45.16382, -115.43481), include_str!("fixtures/navi_directions_D4.json")),
        ("D6", (44.18793, -114.95605), (44.25092, -115.00720), include_str!("fixtures/navi_directions_D6.json")),
    ] {
        let Some((got, _)) = run(from, to) else { return };
        let exp: Value = serde_json::from_str(expected).unwrap();
        assert_eq!(got["ok"], true, "{name}");
        for k in ["steps", "shape", "summary", "routing", "from", "to", "costing", "mode", "leg_params"] {
            cmp(&got[k], &exp[k], &format!("{name}.{k}"));
        }
    }
}

#[test]
fn offroad_lead_directions_close_to_navi() {
    let Some((got, d)) = run((44.03164, -114.98780), (44.13596, -114.91450)) else { return };
    let exp: Value = serde_json::from_str(include_str!("fixtures/navi_directions_D1.json")).unwrap();
    assert!(d.ok && got["routing"] == "offroad" && exp["routing"] == "offroad");
    let (gk, ek) = (got["summary"]["distance_km"].as_f64().unwrap(), exp["summary"]["distance_km"].as_f64().unwrap());
    let (gs, es) = (got["summary"]["duration_s"].as_f64().unwrap(), exp["summary"]["duration_s"].as_f64().unwrap());
    assert!((gk - ek).abs() / ek < 0.02, "distance {gk} vs {ek}");
    assert!((gs - es).abs() / es < 0.02, "duration {gs} vs {es}");
    // the road part (Valhalla steps) is the tail of both
    let road = |v: &Value| v["steps"].as_array().unwrap().iter().filter(|s| s["kind"] == "road").count();
    assert_eq!(road(&got), road(&exp));
}
