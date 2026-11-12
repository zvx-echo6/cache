//! The map's route and guidance over a stand-in router: the whole route comes back (no 12-step cap), via points, alternatives,
//! and progress along it (matching, the next maneuver, remaining, arrival, off route).

use cache_navigate::map::{parse_opts, route, ActiveRoute, MapEnd, MapRouteReq, ProgressReq, RouteStore};
use cache_navigate::{NavCore, NavigateCfg, PlaceSlot};
use cache_offroad::directions::TravelMode;
use cache_offroad::router::Boundary;
use cache_offroad::valhalla::{encode_polyline6, Lane, LocateSnap, Maneuver, Trace, Trip, Valhalla, ValhallaError};
use serde_json::{json, Value};
use std::sync::Arc;

/// A router that drives straight from A to B in `legs` equal maneuvers, 20 m/s, with `alts` alternatives that bow to the side.
struct Straight {
    maneuvers: usize,
    alts: usize,
    /// Maneuver 3 carries turn lanes.
    lanes: bool,
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
                    lanes: if self.lanes && i == 3 { vec![Lane { directions: 16, active: None, valid: None }, Lane { directions: 48, active: Some(32), valid: None }, Lane { directions: 32, active: None, valid: Some(32) }] } else { vec![] },
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
    NavCore::with_valhalla(NavigateCfg::default(), PlaceSlot::default(), Arc::new(Straight { maneuvers, alts, lanes: false }))
}

fn end(name: &str, lat: f64, lon: f64) -> MapEnd {
    MapEnd { id: None, name: Some(name.into()), lat, lon, osm_category: None, arrival: None }
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
    let (m, l, _) = parse_opts(&json!({"mode": "offroad_vehicle", "land_access": "emergency"})).unwrap();
    assert_eq!((m, l), (TravelMode::OffroadVehicle, Boundary::Emergency));
    assert_eq!(parse_opts(&json!({"mode": "offroad_foot"})).unwrap().0, TravelMode::OffroadFoot);
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
fn a_stop_on_a_street_driven_in_and_out_is_reached_once_and_not_gone_back_to() {
    // Made-up roads: east along one street to a corner, north up a side street to a stop at its end, back down the same side
    // street (the way out is drawn 3 m beside the way in, as two lanes are), and on east. Near the stop both passes of the
    // side street are within a few metres of every fix.
    let east = 1.0 / (111_320.0 * 42.5_f64.to_radians().cos());
    let (lat0, lon0, lon_j) = (42.5, -113.8, -113.79);
    let mut pts: Vec<(f64, f64)> = (0..=8).map(|i| (lat0, lon0 + (lon_j - lon0) * i as f64 / 8.0)).collect(); // 0..8, the corner is 8
    pts.extend((1..=6).map(|k| (lat0 + 0.0005 * k as f64, lon_j))); // 9..14, the stop is 14
    pts.extend((1..=6).map(|k| (lat0 + 0.0005 * (6 - k) as f64, lon_j + 3.0 * east))); // 15..20, back at the corner at 20
    pts.extend((1..=8).map(|i| (lat0, lon_j + 3.0 * east + 0.01 * i as f64 / 8.0))); // 21..28
    let man = |index: usize, kind: &str, text: &str, b: usize, e: usize| {
        json!({"index": index, "kind": "road", "type": kind, "instruction": text, "street_names": [], "duration_s": 60, "begin_index": b, "end_index": e, "lat": pts[b].0, "lon": pts[b].1})
    };
    let r = json!({
        "route_id": "in-and-out", "geometry": encode_polyline6(&pts), "duration_s": 300,
        "maneuvers": [
            man(0, "start", "Drive east on Tamarack Street.", 0, 8),
            man(1, "left", "Turn left onto Juniper Lane.", 8, 14),
            man(2, "via", "Stop 1 reached: Quartz Depot.", 14, 20),
            man(3, "left", "Turn left onto Tamarack Street.", 20, 28),
            man(4, "destination", "You have arrived.", 28, 28)
        ]
    });
    let route = Arc::new(ActiveRoute::from_json(&r).unwrap());
    let spur_m = cache_offroad::grid::haversine_m(pts[8].0, pts[8].1, pts[14].0, pts[14].1);
    let (mut last_along, mut last_index) = (0.0_f64, 0_u64);
    let mut check = |p: (f64, f64), what: &str| -> Value {
        let v = prog(&route, p);
        let (along, index) = (v["matched"]["distance_along_m"].as_f64().unwrap(), v["current"]["index"].as_u64().unwrap());
        assert_eq!(v["on_route"], true, "{what}: {v}");
        assert!(along + 15.0 >= last_along, "{what}: went back along the route from {last_along} to {along}");
        assert!(index >= last_index, "{what}: went back from step {last_index} to step {index}");
        last_along = along;
        last_index = index;
        v
    };
    // along the first street to the corner
    for i in 0..=40 {
        check((lat0, lon0 + (lon_j - lon0) * i as f64 / 40.0), "to the corner");
    }
    // up the side street, a fix every 10 m, each 2 m to the east: a metre nearer the way out than the way in. The stop stays the
    // next thing up to the last 25 m before it (there the way in and the way out are one place); the way out is not jumped to.
    let mut d = 10.0;
    while d < spur_m {
        let v = check((lat0 + d / 110_574.0, lon_j + 2.0 * east), "up to the stop");
        if d < spur_m - 25.0 {
            assert_eq!(v["current"]["index"], 1, "{d} m up: {v}");
            assert_eq!(v["next"]["type"], "via", "{d} m up: {v}");
        }
        d += 10.0;
    }
    check(pts[14], "at the stop");
    // back down, each fix 1 m east: a metre nearer the way in than the way out. From 20 m past the stop on, the stop is behind:
    // the step is the one after it, the next thing is the turn out of the side street, and the distance to it only falls.
    let mut to_turn = f64::MAX;
    let mut d = 10.0;
    while d < spur_m {
        let v = check((lat0 + (spur_m - d) / 110_574.0, lon_j + east), "back down from the stop");
        if d >= 20.0 {
            assert_eq!(v["current"]["index"], 2, "{d} m past the stop: {v}");
            assert_eq!(v["next"]["index"], 3, "{d} m past the stop: {v}");
            let left = v["next"]["distance_m"].as_f64().unwrap();
            assert!(left < to_turn, "{d} m past the stop the turn is {left} m off, after {to_turn}");
            to_turn = left;
        }
        d += 10.0;
    }
    // and on along the first street
    for i in 1..=8 {
        let v = check((lat0, lon_j + 3.0 * east + 0.01 * i as f64 / 8.0), "on to the end");
        assert!(v["current"]["index"].as_u64().unwrap() >= 3, "{v}");
    }
}

#[test]
fn a_drive_that_starts_where_the_route_goes_out_and_comes_back_is_on_the_way_out() {
    // Made-up roads: out along a road to a far stop and back along it (drawn 3 m beside), then on. A new route is given its
    // first fix on that road, a metre nearer the way back than the way out: it is on the way out, the far stop still ahead
    // (it was matched to the way back, and the stop counted as behind without having been reached).
    let east = 1.0 / (111_320.0 * 42.5_f64.to_radians().cos());
    let (lat0, lon0) = (42.5, -113.8);
    let mut pts: Vec<(f64, f64)> = (0..=10).map(|i| (lat0 + 0.01 * i as f64, lon0)).collect(); // 0..10, the far stop is 10
    pts.extend((1..=10).map(|i| (lat0 + 0.01 * (10 - i) as f64, lon0 + 3.0 * east))); // 11..20, back at the start at 20
    pts.extend((1..=4).map(|i| (lat0, lon0 + 3.0 * east + 0.01 * i as f64))); // 21..24
    let man = |index: usize, kind: &str, text: &str, b: usize, e: usize| {
        json!({"index": index, "kind": "road", "type": kind, "instruction": text, "street_names": [], "duration_s": 600, "begin_index": b, "end_index": e, "lat": pts[b].0, "lon": pts[b].1})
    };
    let r = json!({
        "route_id": "out-and-back", "geometry": encode_polyline6(&pts), "duration_s": 1800,
        "maneuvers": [
            man(0, "start", "Drive north on Basalt Road.", 0, 10),
            man(1, "via", "Stop 1 reached: Far Mesa.", 10, 20),
            man(2, "left", "Turn left onto Ridge Street.", 20, 24),
            man(3, "destination", "You have arrived.", 24, 24)
        ]
    });
    let out_m = cache_offroad::grid::haversine_m(pts[0].0, pts[0].1, pts[10].0, pts[10].1);
    let route = Arc::new(ActiveRoute::from_json(&r).unwrap());
    let first = prog(&route, (lat0 + 0.0234, lon0 + 2.0 * east));
    assert_eq!(first["on_route"], true, "{first}");
    assert!(first["matched"]["distance_along_m"].as_f64().unwrap() < out_m, "{first}");
    assert_eq!(first["current"]["index"], 0, "{first}");
    assert_eq!(first["next"]["type"], "via", "{first}");
    // and it stays on the way out as the drive goes on
    let next = prog(&route, (lat0 + 0.0236, lon0 + 2.0 * east));
    assert_eq!(next["current"]["index"], 0, "{next}");
    // A route picked up again part of the way back has not seen its stop reached: its fixes stay before the stop (the app
    // knows which stops are behind and asks for a new route without them when a fix is off the route).
    let again = Arc::new(ActiveRoute::from_json(&r).unwrap());
    let mut last = Value::Null;
    for k in 0..4 {
        last = prog(&again, (lat0 + 0.05 - 0.0003 * k as f64, lon0 + east));
    }
    assert!(last["matched"]["distance_along_m"].as_f64().unwrap() < out_m, "{last}");
    assert_eq!(last["stops_reached"], 0, "{last}");
}

#[test]
fn a_fix_is_never_matched_beyond_a_stop_that_has_not_been_reached() {
    // Made-up roads: north out to a far stop and back (drawn 3 m beside), then east past the start to a nearer stop and on to
    // the end. Stop 1 is the far one, Stop 2 the nearer one.
    let east = 1.0 / (111_320.0 * 42.5_f64.to_radians().cos());
    let (lat0, lon0) = (42.5, -113.8);
    let mut pts: Vec<(f64, f64)> = (0..=10).map(|i| (lat0 + 0.01 * i as f64, lon0)).collect(); // 0..10, the far stop is 10
    pts.extend((1..=10).map(|i| (lat0 + 0.01 * (10 - i) as f64, lon0 + 3.0 * east))); // 11..20, back at the start at 20
    pts.extend((1..=8).map(|i| (lat0, lon0 + 3.0 * east + 0.005 * i as f64))); // 21..28, the nearer stop is 24
    let man = |index: usize, kind: &str, text: &str, b: usize, e: usize| {
        json!({"index": index, "kind": "road", "type": kind, "instruction": text, "street_names": [], "duration_s": 600, "begin_index": b, "end_index": e, "lat": pts[b].0, "lon": pts[b].1})
    };
    let r = json!({
        "route_id": "far-then-near", "geometry": encode_polyline6(&pts), "duration_s": 2400,
        "maneuvers": [
            man(0, "start", "Drive north on Basalt Road.", 0, 10),
            man(1, "via", "Stop 1 reached: Far Mesa.", 10, 20),
            man(2, "left", "Turn left onto Ridge Street.", 20, 24),
            man(3, "via", "Stop 2 reached: Near Depot.", 24, 28),
            man(4, "destination", "You have arrived.", 28, 28)
        ]
    });
    let street = |i: f64| (lat0, lon0 + 3.0 * east + 0.005 * i);
    // The drive does not go out to the far stop: it goes straight east along the street the route only comes to later, up to
    // the nearer stop and past it. Every fix lies exactly on that later part of the route.
    let route = Arc::new(ActiveRoute::from_json(&r).unwrap());
    let first = prog(&route, pts[0]);
    assert_eq!((first["on_route"].clone(), first["current"]["index"].clone(), first["stops_reached"].clone()), (json!(true), json!(0), json!(0)), "{first}");
    for (n, i) in [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 3.9, 4.0, 4.2, 5.0].into_iter().enumerate() {
        let v = prog(&route, street(i));
        // off the route (after the usual three fixes in a row), still before Stop 1, no stop reached; never "Stop 2 reached"
        assert_eq!(v["on_route"], false, "at {i}: {v}");
        assert_eq!(v["off_route"], n >= 2, "at {i}: {v}");
        assert_eq!(v["stops_reached"], 0, "at {i}: {v}");
        assert_eq!(v["current"]["index"], 0, "at {i}: {v}");
        assert_eq!(v["next"]["instruction"], "Stop 1 reached: Far Mesa.", "at {i}: {v}");
        assert!(v["remaining"]["distance_m"].as_f64().unwrap() > 20_000.0, "at {i}: {v}");
    }
    // The same route driven as it goes: out to the far stop, back, then east. Each stop is reached in its turn, and only then
    // is the route beyond it matched.
    let route = Arc::new(ActiveRoute::from_json(&r).unwrap());
    for k in 0..=10 {
        let v = prog(&route, (lat0 + 0.01 * k as f64, lon0));
        assert_eq!(v["on_route"], true, "out {k}: {v}");
        assert_eq!(v["stops_reached"], if k == 10 { 1 } else { 0 }, "out {k}: {v}");
    }
    for k in 1..=9 {
        let v = prog(&route, (lat0 + 0.01 * (10 - k) as f64, lon0 + 3.0 * east));
        assert_eq!((v["on_route"].clone(), v["stops_reached"].clone(), v["current"]["index"].clone()), (json!(true), json!(1), json!(1)), "back {k}: {v}");
    }
    let near = prog(&route, street(2.0));
    assert_eq!((near["on_route"].clone(), near["current"]["index"].clone(), near["stops_reached"].clone()), (json!(true), json!(2), json!(1)), "{near}");
    assert_eq!(near["next"]["instruction"], "Stop 2 reached: Near Depot.", "{near}");
    let at = prog(&route, street(4.0));
    assert_eq!(at["stops_reached"], 2, "{at}");
    let on = prog(&route, street(6.0));
    assert_eq!((on["on_route"].clone(), on["current"]["index"].clone(), on["stops_reached"].clone()), (json!(true), json!(3), json!(2)), "{on}");
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

/// Records what a route asked to have fetched.
struct Record(std::sync::Mutex<Vec<Vec<(f64, f64)>>>);

impl cache_navigate::TileStream for Record {
    fn prepare(&self, points: &[(f64, f64)]) -> cache_navigate::TilePrep {
        self.0.lock().unwrap().push(points.to_vec());
        cache_navigate::TilePrep::default()
    }
}

#[test]
fn the_tile_stream_gets_every_stop_once_before_the_route() {
    let c = core(4, 0);
    let rec = Arc::new(Record(Default::default()));
    let s: Arc<dyn cache_navigate::TileStream> = rec.clone();
    c.set_stream(Some(s));
    let (r, _) = route(&c, &req(vec![end("V", 42.6, -113.6)], 0)).unwrap();
    assert_eq!(r["ok"], true);
    assert_eq!(*rec.0.lock().unwrap(), vec![vec![(42.5, -113.8), (42.6, -113.6), (42.5, -113.5)]]);
}

#[test]
fn an_off_road_mode_without_the_off_road_data_is_a_failed_route_that_says_so() {
    let mut r = req(vec![], 2);
    r.mode = TravelMode::OffroadFoot;
    r.land_access = Boundary::Strict;
    let (out, active) = route(&core(6, 2), &r).unwrap();
    assert_eq!(out["ok"], false);
    assert_eq!(out["mode"], "offroad_foot");
    assert_eq!(out["errors"][0]["code"], "not_set_up");
    assert_eq!(out["errors"][0]["message"], cache_offroad::directions::OFFROAD_DATA_MISSING);
    assert!(active.is_empty());
}

#[test]
fn turn_lanes_ride_on_the_maneuver_and_into_progress_only_where_there_are_some() {
    let c = NavCore::with_valhalla(NavigateCfg::default(), PlaceSlot::default(), Arc::new(Straight { maneuvers: 6, alts: 0, lanes: true }));
    let (out, active) = route(&c, &req(vec![], 0)).unwrap();
    let m = out["maneuvers"].as_array().unwrap();
    let want = json!([{"directions": 16}, {"directions": 48, "active": 32}, {"directions": 32, "valid": 32}]);
    assert_eq!(m[3]["lanes"], want);
    for (i, x) in m.iter().enumerate() {
        assert_eq!(x.get("lanes").is_some(), i == 3, "maneuver {i}");
    }
    // a route without lanes has no key anywhere, so its JSON is what it was
    let (plain, _) = route(&core(6, 0), &req(vec![], 0)).unwrap();
    assert!(!serde_json::to_string(&plain).unwrap().contains("lanes"));
    // progress: the next maneuver (3) carries them, the current and `then` ones do not
    let r = &active[0];
    let at3 = fix(&out, m[2]["distance_m"].as_f64().unwrap() * 2.0 + 10.0, 0.0);
    let p3 = prog(r, at3);
    assert_eq!(p3["next"]["index"], 3);
    assert_eq!(p3["next"]["lanes"], want);
    assert!(p3["current"].get("lanes").is_none());
}
