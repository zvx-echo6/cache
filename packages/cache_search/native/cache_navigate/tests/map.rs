//! The map's route and guidance over a stand-in router: the whole route comes back (no 12-step cap), via points, alternatives,
//! and progress along it (matching, the next maneuver, remaining, arrival, off route).

use cache_navigate::map::{parse_opts, route, ActiveRoute, MapEnd, MapRouteReq, ProgressReq, RouteStore};
use cache_navigate::{NavCore, NavigateCfg, PlaceSlot};
use cache_offroad::directions::TravelMode;
use cache_offroad::router::Boundary;
use cache_offroad::valhalla::{encode_polyline6, LocateSnap, Maneuver, Trace, Trip, Valhalla, ValhallaError};
use serde_json::{json, Value};
use std::sync::Arc;

/// A router that drives straight from A to B in `legs` equal maneuvers, 20 m/s, with `alts` alternatives that bow to the side.
struct Straight {
    maneuvers: usize,
    alts: usize,
}

fn lerp(a: (f64, f64), b: (f64, f64), t: f64) -> (f64, f64) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t)
}

impl Straight {
    fn trip(&self, from: (f64, f64), to: (f64, f64), bow: f64) -> Trip {
        let n = self.maneuvers * 10;
        let shape: Vec<(f64, f64)> = (0..=n)
            .map(|i| {
                let t = i as f64 / n as f64;
                let p = lerp(from, to, t);
                (p.0 + bow * (t * std::f64::consts::PI).sin(), p.1)
            })
            .collect();
        let length_m: f64 = shape.windows(2).map(|w| cache_offroad::grid::haversine_m(w[0].0, w[0].1, w[1].0, w[1].1)).sum();
        let maneuvers: Vec<Maneuver> = (0..=self.maneuvers)
            .map(|i| {
                let last = i == self.maneuvers;
                Maneuver {
                    instruction: if i == 0 { "Drive east on Main Street.".into() } else if last { "You have arrived at your destination.".into() } else { format!("Turn left onto Road {i}.") },
                    kind: if i == 0 { 1 } else if last { 4 } else { 15 },
                    length_km: if last { 0.0 } else { length_m / 1000.0 / self.maneuvers as f64 },
                    time_s: if last { 0.0 } else { length_m / 20.0 / self.maneuvers as f64 },
                    street_names: vec![format!("Road {i}")],
                    begin_shape_index: (i * 10) as i64,
                    end_shape_index: (i * 10) as i64 + if last { 0 } else { 10 },
                    bearing_after: Some(90.0),
                    bearing_before: None,
                }
            })
            .collect();
        Trip { shape_encoded: encode_polyline6(&shape), shape, maneuvers, length_km: length_m / 1000.0, time_s: length_m / 20.0 }
    }
}

impl Valhalla for Straight {
    fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
        None
    }
    fn route(&self, from: (f64, f64), to: (f64, f64), _: &str) -> Result<Trip, ValhallaError> {
        Ok(self.trip(from, to, 0.0))
    }
    fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("not used"))
    }
    fn alternatives(&self, from: (f64, f64), to: (f64, f64), _: &str, count: usize) -> Vec<Trip> {
        // the first alternative is the best route again (the map must drop it), the others bow
        let mut v = vec![self.trip(from, to, 0.0)];
        v.extend((1..=self.alts).map(|i| self.trip(from, to, 0.01 * i as f64)));
        v.truncate(count);
        v
    }
}

fn core(maneuvers: usize, alts: usize) -> NavCore {
    NavCore::with_valhalla(NavigateCfg::default(), PlaceSlot::default(), Arc::new(Straight { maneuvers, alts }))
}

fn end(name: &str, lat: f64, lon: f64) -> MapEnd {
    MapEnd { id: None, name: Some(name.into()), lat, lon, osm_category: None }
}

fn req(via: Vec<MapEnd>, alternatives: usize) -> MapRouteReq {
    MapRouteReq { from: end("A", 42.5, -113.8), via, to: end("B", 42.5, -113.5), mode: TravelMode::Drive, land_access: Boundary::Pragmatic, alternatives }
}

#[test]
fn every_maneuver_comes_back_with_its_place_in_the_geometry() {
    let (out, active) = route(&core(30, 0), &req(vec![], 0)).unwrap();
    assert_eq!(out["ok"], true);
    // 30 turns and the arrival: the tool would show 12
    let m = out["maneuvers"].as_array().unwrap();
    assert_eq!(m.len(), 31);
    assert_eq!(m[0]["instruction"], "Drive east on Main Street.");
    assert_eq!(m[30]["type"], "destination");
    for (i, x) in m.iter().enumerate() {
        assert_eq!(x["index"], i);
        assert_eq!(x["begin_index"], i * 10);
        assert_eq!(x["kind"], "road");
        assert!(x["lat"].is_f64() && x["lon"].is_f64());
    }
    assert!((m[5]["distance_m"].as_f64().unwrap() - out["distance_m"].as_f64().unwrap() / 30.0).abs() < 1.0);
    // geometry, totals, segments
    assert_eq!(out["point_count"], 301);
    let t = &out["totals"];
    assert_eq!(t["offroad_m"], 0.0);
    assert!((t["road_m"].as_f64().unwrap() - out["distance_m"].as_f64().unwrap()).abs() < 1.0);
    let d = out["distance_m"].as_f64().unwrap();
    assert!((d - 24_600.0).abs() < 600.0, "{d}");
    assert_eq!(out["segments"], json!([{"kind": "road", "travel": "drive", "start_index": 0, "end_index": 300, "distance_m": out["segments"][0]["distance_m"]}]));
    assert_eq!(out["routing"], "road");
    assert_eq!(out["warnings"], json!([]));
    assert_eq!(out["from"]["name"], "A");
    assert_eq!(out["alternatives"], json!([]));
    assert_eq!(active.len(), 1);
}

#[test]
fn via_points_are_stops_on_the_one_route() {
    let r = req(vec![end("Cafe", 42.5, -113.65)], 2);
    let (out, active) = route(&core(4, 2), &r).unwrap();
    let m = out["maneuvers"].as_array().unwrap();
    // two legs of four turns and an arrival each
    assert_eq!(m.len(), 10);
    assert_eq!(m[4]["type"], "via");
    assert_eq!(m[4]["instruction"], "Stop 1 reached: Cafe");
    assert_eq!(m[9]["type"], "destination");
    assert_eq!(out["via"][0]["name"], "Cafe");
    // the second leg starts where the first ended
    assert_eq!(m[4]["begin_index"], m[5]["begin_index"]);
    assert_eq!(out["point_count"], 81);
    assert_eq!(out["segments"].as_array().unwrap().len(), 1);
    // no alternatives for a route with a stop
    assert_eq!(out["alternatives"], json!([]));
    assert_eq!(active.len(), 1);
    assert!(out["route_id"].as_str().unwrap().contains('+'));
}

#[test]
fn alternatives_are_other_routes_not_the_best_again() {
    let (out, active) = route(&core(6, 2), &req(vec![], 3)).unwrap();
    let alts = out["alternatives"].as_array().unwrap();
    assert_eq!(alts.len(), 2);
    for a in alts {
        assert_ne!(a["geometry"], out["geometry"]);
        assert_ne!(a["route_id"], out["route_id"]);
        assert!(a["distance_m"].as_f64().unwrap() > out["distance_m"].as_f64().unwrap());
        assert_eq!(a["maneuvers"].as_array().unwrap().len(), 7);
        assert!(a.get("alternatives").is_none());
    }
    assert_ne!(alts[0]["route_id"], alts[1]["route_id"]);
    assert_eq!(active.len(), 3);
    // asking for none gives none
    assert_eq!(route(&core(6, 2), &req(vec![], 0)).unwrap().0["alternatives"], json!([]));
}

#[test]
fn options_are_checked() {
    assert!(parse_opts(&json!({"mode": "fly"})).is_err());
    assert!(parse_opts(&json!({"land_access": "never"})).is_err());
    assert!(parse_opts(&json!({"alternatives": 9})).is_err());
    let (m, l, a) = parse_opts(&json!({"mode": "walk", "land_access": "strict", "alternatives": false})).unwrap();
    assert_eq!((m, l, a), (TravelMode::Walk, Boundary::Strict, 0));
    assert_eq!(parse_opts(&json!({})).unwrap().2, 2);
}

fn fix(r: &Value, along_m: f64, off_m: f64) -> (f64, f64) {
    // a point `along_m` along the first (east-west) route and `off_m` north of it
    let a = (42.5, -113.8);
    let total = r["distance_m"].as_f64().unwrap();
    let b = (42.5, -113.5);
    let p = lerp(a, b, along_m / total);
    (p.0 + off_m / 110_574.0, p.1)
}

fn prog(route: &Arc<ActiveRoute>, p: (f64, f64)) -> Value {
    route.progress(&ProgressReq { lat: p.0, lon: p.1, accuracy_m: None, now: Some("2026-10-26T12:00:00-06:00".into()), reset: false, off_route_m: 50.0, off_route_fixes: 3, arrive_m: 25.0 })
}

#[test]
fn progress_follows_the_fixes_along_the_route() {
    let (out, active) = route(&core(10, 0), &req(vec![], 0)).unwrap();
    let r = &active[0];
    let total = out["distance_m"].as_f64().unwrap();
    // 25% of the way, 10 m beside the road
    let p = prog(r, fix(&out, total * 0.25, 10.0));
    assert_eq!(p["on_route"], true);
    assert_eq!(p["off_route"], false);
    assert!((p["matched"]["distance_along_m"].as_f64().unwrap() - total * 0.25).abs() < 2.0, "{p}");
    assert!((p["matched"]["offset_m"].as_f64().unwrap() - 10.0).abs() < 1.0);
    assert!((p["remaining"]["distance_m"].as_f64().unwrap() - total * 0.75).abs() < 2.0);
    // the stand-in drives 20 m/s
    assert!((p["remaining"]["duration_s"].as_f64().unwrap() - total * 0.75 / 20.0).abs() < 2.0, "{p}");
    assert_eq!(p["remaining"]["eta"].as_str().unwrap().len(), 25);
    assert!(p["remaining"]["eta"].as_str().unwrap().starts_with("2026-10-26T12:"));
    // between turn 2 and turn 3: the next maneuver is turn 3, a fifth of the way minus where we are
    assert_eq!(p["current"]["index"], 2);
    assert_eq!(p["next"]["index"], 3);
    assert_eq!(p["next"]["instruction"], "Turn left onto Road 3.");
    let to_next = total * 0.3 - total * 0.25;
    assert!((p["next"]["distance_m"].as_f64().unwrap() - to_next).abs() < 3.0, "{p}");
    assert_eq!(p["then"]["index"], 4);
    assert!((p["progress"].as_f64().unwrap() - 0.25).abs() < 0.001);
    assert!(p["leg"].is_null());
    assert_eq!(p["arrived"], false);
    // the last stretch: next is the arrival
    let p = prog(r, fix(&out, total - 150.0, 0.0));
    assert_eq!(p["next"]["type"], "destination");
    assert!((p["next"]["distance_m"].as_f64().unwrap() - 150.0).abs() < 3.0, "{p}");
    assert!(p["then"].is_null());
    // at the end
    let p = prog(r, fix(&out, total - 5.0, 0.0));
    assert_eq!(p["arrived"], true);
    assert!(p["remaining"]["distance_m"].as_f64().unwrap() < 10.0);
}

#[test]
fn off_route_needs_a_few_fixes_in_a_row() {
    let (out, active) = route(&core(10, 0), &req(vec![], 0)).unwrap();
    let r = &active[0];
    let total = out["distance_m"].as_f64().unwrap();
    assert_eq!(prog(r, fix(&out, total * 0.4, 5.0))["off_route"], false);
    // 120 m off for two fixes: not yet
    let p = prog(r, fix(&out, total * 0.4, 120.0));
    assert_eq!((p["on_route"].clone(), p["off_route"].clone(), p["off_route_count"].clone()), (json!(false), json!(false), json!(1)));
    assert_eq!(prog(r, fix(&out, total * 0.41, 125.0))["off_route_count"], 2);
    // back on the road: the count starts again
    let p = prog(r, fix(&out, total * 0.42, 8.0));
    assert_eq!((p["on_route"].clone(), p["off_route_count"].clone()), (json!(true), json!(0)));
    for n in 1..=3 {
        let p = prog(r, fix(&out, total * 0.5, 200.0));
        assert_eq!(p["off_route"], n == 3, "fix {n}: {p}");
    }
    // a poor GPS fix is not held to 50 m
    let p = r.progress(&ProgressReq { lat: fix(&out, total * 0.6, 90.0).0, lon: fix(&out, total * 0.6, 90.0).1, accuracy_m: Some(120.0), now: None, reset: true, off_route_m: 50.0, off_route_fixes: 1, arrive_m: 25.0 });
    assert_eq!(p["on_route"], true);
    assert!(p["remaining"].get("eta").is_none());
}

#[test]
fn a_route_that_passes_itself_is_not_mistaken_for_the_other_pass() {
    // out and back along the same road: the second pass must match the second half
    let a = (42.5, -113.8);
    let b = (42.5, -113.5);
    let pts: Vec<(f64, f64)> = (0..=10).map(|i| lerp(a, b, i as f64 / 10.0)).chain((1..=10).map(|i| lerp(b, a, i as f64 / 10.0))).collect();
    let len: f64 = pts.windows(2).map(|w| cache_offroad::grid::haversine_m(w[0].0, w[0].1, w[1].0, w[1].1)).sum();
    let r = json!({
        "route_id": "loop", "geometry": encode_polyline6(&pts), "duration_s": 1000,
        "maneuvers": [
            {"index": 0, "kind": "road", "type": "start", "instruction": "Go", "street_names": [], "duration_s": 500, "begin_index": 0, "end_index": 10, "lat": a.0, "lon": a.1},
            {"index": 1, "kind": "road", "type": "uturn", "instruction": "Turn around", "street_names": [], "duration_s": 500, "begin_index": 10, "end_index": 20, "lat": b.0, "lon": b.1},
            {"index": 2, "kind": "road", "type": "destination", "instruction": "Arrive", "street_names": [], "duration_s": 0, "begin_index": 20, "end_index": 20, "lat": a.0, "lon": a.1}
        ]
    });
    let route = ActiveRoute::from_json(&r).unwrap();
    let at = |t: f64| lerp(a, b, t);
    let step = |p: (f64, f64)| prog(&Arc::new(ActiveRoute::from_json(&r).unwrap()), p);
    let _ = step;
    // outbound to 60%, past the turn-around, then back at 60%: the matched distance must go past half
    let p1 = prog(&Arc::new(route), at(0.6));
    assert!(p1["matched"]["distance_along_m"].as_f64().unwrap() < len / 2.0);
    let route = Arc::new(ActiveRoute::from_json(&r).unwrap());
    for t in [0.3, 0.8, 1.0] {
        prog(&route, at(t));
    }
    let back = prog(&route, at(0.8));
    assert!(back["matched"]["distance_along_m"].as_f64().unwrap() > len / 2.0, "{back}");
    assert_eq!(back["current"]["index"], 1);
}

#[test]
fn the_store_keeps_the_newest_routes() {
    let store = RouteStore::default();
    let (_, active) = route(&core(3, 3), &req(vec![], 3)).unwrap();
    store.add(&active);
    for a in &active {
        assert!(store.get(&a.id).is_some());
    }
    assert!(store.get("nope").is_none());
    // a route object read back from JSON is the same route
    let (out, active) = route(&core(3, 0), &req(vec![], 0)).unwrap();
    let again = ActiveRoute::from_json(&out).unwrap();
    assert_eq!(again.id, active[0].id);
    for i in 0..10 {
        let mut o = out.clone();
        o["route_id"] = json!(format!("r{i}"));
        store.add(&[Arc::new(ActiveRoute::from_json(&o).unwrap())]);
    }
    assert!(store.get("r9").is_some());
    assert!(store.get("r0").is_none(), "only the newest are kept");
}
