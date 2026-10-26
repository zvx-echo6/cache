//! The map's routing (`cs_map_route`, `cs_map_progress`): the complete route for drawing and guiding, built on the same
//! [`NavCore`](crate::NavCore) the `navigate` tool uses.
//!
//! The tool shortens a route for a language model (12 steps, text only). The map needs all of it: the full geometry as a
//! polyline with the kind of each stretch (road, off-road, or following a trail), every maneuver with its position, the
//! totals, the warnings, and the alternatives Valhalla gives. `cs_map_progress` then tells where a GPS fix is on that route.
//!
//! Geometry is a polyline6 string (Google's polyline algorithm at 1e-6 degrees, as Valhalla writes it). Maneuvers and segments
//! refer to it by point index, so a screen can colour a stretch or find a turn without matching coordinates.

use crate::build;
use crate::{NavCore, ToolError};
use cache_offroad::directions::{Directions, TravelMode, DEFAULT_OFFROAD_SNAP_M};
use cache_offroad::grid::haversine_m;
use cache_offroad::navigate::{NavigateRequest, Waypoint};
use cache_offroad::offroad_legs::{bearing_deg, cardinal, round_py, Step};
use cache_offroad::router::Boundary;
use cache_offroad::valhalla::{decode_polyline6, encode_polyline6};
use serde_json::{json, Map, Value};
use std::collections::VecDeque;
use std::sync::{Arc, Mutex};

/// How many routes the handle keeps for `cs_map_progress` (the active one, its alternatives, the one before).
const KEEP_ROUTES: usize = 8;
/// Defaults of `cs_map_progress`.
pub const OFF_ROUTE_M: f64 = 50.0;
pub const OFF_ROUTE_FIXES: usize = 3;
pub const ARRIVE_M: f64 = 25.0;
/// An off-road leg is a straight line between turn points over a 30 m grid: its tolerance is this many times wider.
const OFFROAD_TOLERANCE: f64 = 2.0;
/// The window around the last matched position that a fix is matched in first, so a route that comes back past itself
/// is not mistaken for the other pass.
const WINDOW_BACK_M: f64 = 300.0;
const WINDOW_AHEAD_M: f64 = 3000.0;

/// An end of a route, resolved: where it is, what it is called, and the OSM category that seeds the off-road modes there.
#[derive(Debug, Clone)]
pub struct MapEnd {
    pub id: Option<String>,
    pub name: Option<String>,
    pub lat: f64,
    pub lon: f64,
    pub osm_category: Option<String>,
}

impl MapEnd {
    fn waypoint(&self) -> Waypoint {
        match (&self.name, &self.osm_category) {
            (Some(n), Some(c)) => Waypoint::place_with_category(n, self.lat, self.lon, c),
            (Some(n), None) => Waypoint::place(n, self.lat, self.lon),
            _ => Waypoint::point(self.lat, self.lon),
        }
    }

    fn json(&self, snap_m: Option<i64>) -> Value {
        json!({"id": self.id, "name": self.name, "lat": round_py(self.lat, 6), "lon": round_py(self.lon, 6), "snap_distance_m": snap_m})
    }
}

pub struct MapRouteReq {
    pub from: MapEnd,
    pub via: Vec<MapEnd>,
    pub to: MapEnd,
    pub mode: TravelMode,
    pub land_access: Boundary,
    /// How many alternatives to ask for (0 for none).
    pub alternatives: usize,
}

/// The mode, land access and alternatives of a route request (the ends are resolved by the caller).
pub fn parse_opts(v: &Value) -> Result<(TravelMode, Boundary, usize), ToolError> {
    let bad = |m: String| ToolError::new(ToolError::BAD_ARGUMENTS, m);
    let mode = match v.get("mode") {
        None | Some(Value::Null) => TravelMode::Drive,
        Some(m) => m.as_str().and_then(TravelMode::from_name).ok_or_else(|| bad("mode: must be one of drive, walk, bike".into()))?,
    };
    let land = match v.get("land_access") {
        None | Some(Value::Null) => Boundary::Pragmatic,
        Some(m) => m.as_str().and_then(Boundary::from_name).ok_or_else(|| bad("land_access: must be one of strict, pragmatic, emergency".into()))?,
    };
    let alts = match v.get("alternatives") {
        None | Some(Value::Null) => 2,
        Some(Value::Bool(b)) => *b as usize * 2,
        Some(n) => n.as_u64().filter(|n| *n <= 3).ok_or_else(|| bad("alternatives: must be true, false or 0 to 3".into()))? as usize,
    };
    Ok((mode, land, alts))
}

// ---- building the route ----------------------------------------------------------------------------------------------

fn cumulative(pts: &[(f64, f64)]) -> Vec<f64> {
    let mut c = Vec::with_capacity(pts.len());
    let mut d = 0.0;
    for (i, p) in pts.iter().enumerate() {
        if i > 0 {
            d += haversine_m(pts[i - 1].0, pts[i - 1].1, p.0, p.1);
        }
        c.push(d);
    }
    c
}

/// The first point at or after `from` that is at `p` (the steps carry their points rounded to 6 decimals, the geometry
/// carries the same values), or else the nearest one after it.
fn find_from(pts: &[(f64, f64)], from: usize, p: (f64, f64)) -> usize {
    let from = from.min(pts.len().saturating_sub(1));
    for (i, q) in pts.iter().enumerate().skip(from) {
        if (q.0 - p.0).abs() < 4e-6 && (q.1 - p.1).abs() < 4e-6 {
            return i;
        }
    }
    let mut best = (f64::MAX, from);
    for (i, q) in pts.iter().enumerate().skip(from) {
        let d = haversine_m(q.0, q.1, p.0, p.1);
        if d < best.0 {
            best = (d, i);
        }
    }
    best.1
}

fn kind_class(s: &Step) -> &'static str {
    match s.kind.as_str() {
        "offroad" => "offroad",
        "offroad_follow" => "follow",
        _ => "road",
    }
}

fn travel_of(s: &Step, trip_mode: TravelMode) -> String {
    match s.mode.as_deref() {
        Some(m) => m.to_string(),
        None => trip_mode.name().to_string(),
    }
}

fn fnv(s: &str) -> u32 {
    let mut h: u32 = 2166136261;
    for b in s.bytes() {
        h = (h ^ b as u32).wrapping_mul(16777619);
    }
    h
}

/// One route object from the legs of a trip (one leg, or one per via point): geometry, segments, maneuvers, totals and warnings.
fn route_object(legs: &[Directions], ends: &[&MapEnd], mode: TravelMode, land: Boundary, have_offroad: bool) -> Value {
    let mut pts: Vec<(f64, f64)> = Vec::new();
    // (step, begin index, end index in the combined geometry, leg)
    let mut placed: Vec<(Step, usize, usize)> = Vec::new();
    for (li, d) in legs.iter().enumerate() {
        let leg_pts = decode_polyline6(&d.shape);
        let base = if pts.is_empty() { 0 } else { pts.len() - 1 };
        let mut cursor = 0usize;
        let skip_first = !pts.is_empty();
        for (i, p) in leg_pts.iter().enumerate() {
            if skip_first && i == 0 {
                continue;
            }
            pts.push(*p);
        }
        for s in &d.steps {
            let b = find_from(&leg_pts, cursor, s.start);
            let e = find_from(&leg_pts, b, s.end);
            cursor = b;
            let mut s = s.clone();
            // a via point is an arrival that is not the end
            if li + 1 < legs.len() && s.type_.starts_with("destination") {
                s.type_ = "via".into();
                let name = ends.get(li + 1).and_then(|e| e.name.clone()).unwrap_or_else(|| format!("stop {}", li + 1));
                s.instruction = Some(format!("Stop {} reached: {name}", li + 1));
            }
            placed.push((s, base + b, base + e));
        }
    }
    let cum = cumulative(&pts);
    let at = |i: usize| cum.get(i).copied().unwrap_or(0.0);

    let mut maneuvers: Vec<Value> = Vec::new();
    let mut segments: Vec<Value> = Vec::new();
    let (mut ascent, mut descent) = (0i64, 0i64);
    let mut seg: Option<(&'static str, String, usize, usize)> = None;
    let flush = |seg: &mut Option<(&'static str, String, usize, usize)>, segments: &mut Vec<Value>, cum_at: &dyn Fn(usize) -> f64| {
        if let Some((kind, travel, a, b)) = seg.take() {
            segments.push(json!({"kind": kind, "travel": travel, "start_index": a, "end_index": b, "distance_m": round_py(cum_at(b) - cum_at(a), 1)}));
        }
    };
    for (i, (s, b, e)) in placed.iter().enumerate() {
        let (b, e) = (*b, (*e).max(*b));
        let class = kind_class(s);
        let travel = travel_of(s, mode);
        ascent += s.elev_gain_m.unwrap_or(0);
        descent += s.elev_loss_m.unwrap_or(0);
        let extend = matches!(&seg, Some((k, t, _, _)) if *k == class && *t == travel);
        if extend {
            if let Some(cur) = seg.as_mut() {
                cur.3 = e;
            }
        } else {
            let start = seg.as_ref().map(|x| x.3).unwrap_or(b);
            flush(&mut seg, &mut segments, &at);
            seg = Some((class, travel.clone(), start.min(b), e));
        }
        let mut m = Map::new();
        m.insert("index".into(), json!(i));
        m.insert("kind".into(), json!(s.kind));
        m.insert("type".into(), json!(s.type_));
        m.insert("instruction".into(), json!(build::step_text(s, mode.name())));
        m.insert("street_names".into(), json!(s.street_names));
        m.insert("distance_m".into(), json!(round_py(at(e) - at(b), 1)));
        m.insert("duration_s".into(), json!(s.duration_s));
        let start = pts.get(b).copied().unwrap_or(s.start);
        m.insert("lat".into(), json!(round_py(start.0, 6)));
        m.insert("lon".into(), json!(round_py(start.1, 6)));
        m.insert("begin_index".into(), json!(b));
        m.insert("end_index".into(), json!(e));
        m.insert("bearing_deg".into(), json!(s.bearing_deg));
        m.insert("cardinal".into(), json!(s.cardinal));
        m.insert("travel".into(), json!(travel));
        if class != "road" {
            m.insert("grade_class".into(), json!(s.grade_class));
            m.insert("elev_gain_m".into(), json!(s.elev_gain_m));
            m.insert("elev_loss_m".into(), json!(s.elev_loss_m));
            if let Some(t) = s.terrain.as_deref().filter(|t| !t.is_empty() && *t != "unknown") {
                m.insert("terrain".into(), json!(t.replace('_', " ")));
            }
            if let Some(f) = &s.follow {
                m.insert("follow".into(), json!({"name": f.name, "trail_kind": f.trail_kind}));
            }
        }
        maneuvers.push(Value::Object(m));
    }
    flush(&mut seg, &mut segments, &at);
    // the segments cover the line without gaps
    for i in 1..segments.len() {
        let prev_end = segments[i - 1]["end_index"].clone();
        segments[i]["start_index"] = prev_end;
    }
    if let (Some(first), Some(last)) = (segments.first_mut(), pts.len().checked_sub(1)) {
        first["start_index"] = json!(0);
        let n = segments.len();
        segments[n - 1]["end_index"] = json!(last);
    }
    let seg_len = |kind_road: bool| -> f64 {
        segments
            .iter()
            .filter(|s| (s["kind"] == "road") == kind_road)
            .map(|s| s["distance_m"].as_f64().unwrap_or(0.0))
            .sum()
    };
    let (road_m, offroad_m) = (seg_len(true), seg_len(false));
    let total_m = pts.len().checked_sub(1).map(at).unwrap_or(0.0);
    let duration_s: i64 = legs.iter().map(|d| d.duration_s).sum();

    let first = &legs[0];
    let last = &legs[legs.len() - 1];
    let id = if legs.len() == 1 {
        first.route_id.clone()
    } else {
        format!("{}+{:08x}", first.route_id, fnv(&legs.iter().map(|d| d.route_id.as_str()).collect::<String>()))
    };
    let mut o = Map::new();
    o.insert("route_id".into(), json!(id));
    o.insert("mode".into(), json!(mode.name()));
    o.insert("land_access".into(), json!(land.name()));
    o.insert("routing".into(), json!(if offroad_m > 0.0 { "offroad" } else { "road" }));
    o.insert("from".into(), ends[0].json(first.from.as_ref().map(|e| e.snap_distance_m)));
    o.insert("via".into(), Value::Array(ends[1..ends.len() - 1].iter().map(|e| e.json(None)).collect()));
    o.insert("to".into(), ends[ends.len() - 1].json(last.to.as_ref().map(|e| e.snap_distance_m)));
    o.insert("distance_m".into(), json!(round_py(total_m, 1)));
    o.insert("duration_s".into(), json!(duration_s));
    o.insert(
        "totals".into(),
        json!({"distance_m": round_py(total_m, 1), "duration_s": duration_s, "road_m": round_py(road_m, 1), "offroad_m": round_py(offroad_m, 1), "ascent_m": ascent, "descent_m": descent}),
    );
    o.insert("geometry".into(), json!(encode_polyline6(&pts)));
    o.insert("point_count".into(), json!(pts.len()));
    o.insert("segments".into(), Value::Array(segments));
    o.insert("maneuvers".into(), Value::Array(maneuvers));
    o.insert("major_roads".into(), Value::Array(first.major_roads.iter().map(|(n, k)| json!({"name": n, "distance_km": k})).collect()));
    let mut warnings: Vec<Value> = Vec::new();
    for d in legs {
        warnings.extend(build::warnings(d, have_offroad, DEFAULT_OFFROAD_SNAP_M));
    }
    o.insert("warnings".into(), Value::Array(warnings));
    Value::Object(o)
}

/// A failed route is a result, not a crash: `{"ok": false, "errors": [{code, message}]}` (no_route, too_far, out_of_coverage,
/// route_too_long, upstream_timeout, internal), with the ends that were asked for.
fn failure(d: &Directions, req: &MapRouteReq) -> Value {
    json!({
        "ok": false,
        "route_id": d.route_id,
        "mode": req.mode.name(),
        "from": req.from.json(None),
        "to": req.to.json(None),
        "errors": d.errors.iter().map(|e| json!({"code": e.code, "message": e.message})).collect::<Vec<_>>(),
    })
}

/// The complete route: `{"ok": true, ...route object..., "alternatives": [route objects]}`, or `{"ok": false, "errors": [...]}`.
/// Also returns the routes (best first, then alternatives) in the form `cs_map_progress` follows.
pub fn route(core: &NavCore, req: &MapRouteReq) -> Result<(Value, Vec<Arc<ActiveRoute>>), ToolError> {
    let mut stops: Vec<&MapEnd> = vec![&req.from];
    stops.extend(req.via.iter());
    stops.push(&req.to);
    let mut legs: Vec<Directions> = Vec::new();
    let mut have_offroad = false;
    for pair in stops.windows(2) {
        let nr = NavigateRequest::new(pair[0].waypoint(), pair[1].waypoint(), req.mode, req.land_access);
        let (d, h) = core.navigate(nr)?;
        have_offroad = h;
        if !d.ok {
            return Ok((failure(&d, req), vec![]));
        }
        legs.push(d);
    }
    let mut main = route_object(&legs, &stops, req.mode, req.land_access, have_offroad);
    let mut alternatives: Vec<Value> = Vec::new();
    // alternatives exist for a plain road route (one leg, nothing off-road)
    if req.alternatives > 0 && legs.len() == 1 && main["routing"] == "road" {
        let nr = NavigateRequest::new(req.from.waypoint(), req.to.waypoint(), req.mode, req.land_access);
        for d in core.alternatives(&nr, req.alternatives)? {
            let o = route_object(std::slice::from_ref(&d), &stops, req.mode, req.land_access, have_offroad);
            if o["geometry"] != main["geometry"] && !alternatives.iter().any(|a| a["geometry"] == o["geometry"]) {
                alternatives.push(o);
            }
        }
    }
    let mut active = vec![Arc::new(ActiveRoute::from_json(&main).map_err(|e| ToolError::new(ToolError::INTERNAL, e))?)];
    for a in &alternatives {
        active.push(Arc::new(ActiveRoute::from_json(a).map_err(|e| ToolError::new(ToolError::INTERNAL, e))?));
    }
    let m = main.as_object_mut().expect("object");
    m.insert("alternatives".into(), Value::Array(alternatives));
    let mut out = Map::new();
    out.insert("ok".into(), json!(true));
    out.extend(std::mem::take(m));
    Ok((Value::Object(out), active))
}

// ---- following the route ---------------------------------------------------------------------------------------------

struct Man {
    json: Value,
    begin_m: f64,
    end_m: f64,
    duration_s: f64,
    class: &'static str,
    elev_gain: Option<i64>,
    elev_loss: Option<i64>,
    end_pt: (f64, f64),
}

struct ProgState {
    last_m: f64,
    off_count: usize,
    fixes: usize,
}

/// A route held for `cs_map_progress`: its points, distances along it, maneuvers, and the fix-to-fix state (where the last fix
/// matched, how many fixes in a row were off the route).
pub struct ActiveRoute {
    pub id: String,
    pts: Vec<(f64, f64)>,
    cum: Vec<f64>,
    mans: Vec<Man>,
    total_m: f64,
    total_s: f64,
    state: Mutex<ProgState>,
}

impl ActiveRoute {
    /// From a route object as `route()` returns it (also how a route from an earlier session is loaded again).
    pub fn from_json(r: &Value) -> Result<ActiveRoute, String> {
        let id = r["route_id"].as_str().ok_or("the route has no route_id")?.to_string();
        let pts = decode_polyline6(r["geometry"].as_str().ok_or("the route has no geometry")?);
        if pts.len() < 2 {
            return Err("the route geometry has fewer than two points".into());
        }
        let cum = cumulative(&pts);
        let at = |i: usize| cum.get(i).copied().unwrap_or_else(|| *cum.last().unwrap());
        let mut mans = Vec::new();
        for m in r["maneuvers"].as_array().ok_or("the route has no maneuvers")? {
            let b = m["begin_index"].as_u64().ok_or("a maneuver has no begin_index")? as usize;
            let e = m["end_index"].as_u64().ok_or("a maneuver has no end_index")? as usize;
            let class = match m["kind"].as_str() {
                Some("offroad") => "offroad",
                Some("offroad_follow") => "follow",
                _ => "road",
            };
            mans.push(Man {
                json: m.clone(),
                begin_m: at(b),
                end_m: at(e),
                duration_s: m["duration_s"].as_f64().unwrap_or(0.0),
                class,
                elev_gain: m["elev_gain_m"].as_i64(),
                elev_loss: m["elev_loss_m"].as_i64(),
                end_pt: pts.get(e).copied().unwrap_or(pts[pts.len() - 1]),
            });
        }
        if mans.is_empty() {
            return Err("the route has no maneuvers".into());
        }
        let total_m = *cum.last().unwrap();
        let total_s = r["duration_s"].as_f64().unwrap_or_else(|| mans.iter().map(|m| m.duration_s).sum());
        Ok(ActiveRoute { id, pts, cum, mans, total_m, total_s, state: Mutex::new(ProgState { last_m: 0.0, off_count: 0, fixes: 0 }) })
    }

    /// The maneuver a distance along the route falls in: the last one that has begun, leaving the final arrival (a point, not a
    /// stretch) to be the "next" one.
    fn man_at(&self, m: f64) -> usize {
        let n = self.mans.len();
        let limit = if n > 1 && self.mans[n - 1].end_m <= self.mans[n - 1].begin_m + 1e-6 { n - 1 } else { n };
        let mut ix = 0;
        for i in 0..limit {
            if self.mans[i].begin_m <= m + 1e-6 {
                ix = i;
            }
        }
        ix
    }

    /// The closest point of the route to `p` among the segments whose start lies in `[lo_m, hi_m]` along it:
    /// (segment, distance along the route, offset in metres, matched point).
    fn nearest(&self, p: (f64, f64), lo_m: f64, hi_m: f64) -> Option<(usize, f64, f64, (f64, f64))> {
        let k = p.0.to_radians().cos();
        let xy = |q: (f64, f64)| ((q.1 - p.1) * k * 111_320.0, (q.0 - p.0) * 110_574.0);
        let first = self.cum.partition_point(|c| *c < lo_m).saturating_sub(1);
        let mut best: Option<(usize, f64, f64, (f64, f64))> = None;
        for i in first..self.pts.len() - 1 {
            if self.cum[i] > hi_m {
                break;
            }
            let (a, b) = (xy(self.pts[i]), xy(self.pts[i + 1]));
            let (dx, dy) = (b.0 - a.0, b.1 - a.1);
            let n = dx * dx + dy * dy;
            let t = if n == 0.0 { 0.0 } else { (((0.0 - a.0) * dx + (0.0 - a.1) * dy) / n).clamp(0.0, 1.0) };
            let off = (a.0 + t * dx).hypot(a.1 + t * dy);
            if best.is_none_or(|x| off < x.2) {
                let along = self.cum[i] + t * (self.cum[i + 1] - self.cum[i]);
                let pt = (self.pts[i].0 + t * (self.pts[i + 1].0 - self.pts[i].0), self.pts[i].1 + t * (self.pts[i + 1].1 - self.pts[i].1));
                best = Some((i, along, off, pt));
            }
        }
        best
    }

    /// Where a fix is on the route. See [`ProgressReq`].
    pub fn progress(&self, q: &ProgressReq) -> Value {
        let mut st = self.state.lock().unwrap_or_else(|e| e.into_inner());
        if q.reset {
            *st = ProgState { last_m: 0.0, off_count: 0, fixes: 0 };
        }
        let p = (q.lat, q.lon);
        let acc = q.accuracy_m.unwrap_or(0.0).max(0.0);
        // near the last match first; the whole route only when that finds nothing on it
        let tol_for = |m: f64, base: f64| -> f64 {
            let i = self.man_at(m);
            let t = if self.mans[i].class == "road" { base } else { base * OFFROAD_TOLERANCE };
            t.max(acc)
        };
        let windowed = if st.fixes > 0 { self.nearest(p, st.last_m - WINDOW_BACK_M, st.last_m + WINDOW_AHEAD_M) } else { None };
        let mut hit = windowed.filter(|w| w.2 <= tol_for(w.1, q.off_route_m));
        if hit.is_none() {
            hit = self.nearest(p, 0.0, f64::MAX);
        }
        let (seg, along, offset, matched) = hit.expect("a route has segments");
        let on_route = offset <= tol_for(along, q.off_route_m);
        st.fixes += 1;
        if on_route {
            st.off_count = 0;
            st.last_m = along;
        } else {
            st.off_count += 1;
        }
        let off_route = st.off_count >= q.off_route_fixes;
        let off_count = st.off_count;
        let fix_no = st.fixes;
        drop(st);

        let remaining_m = (self.total_m - along).max(0.0);
        let ci = self.man_at(along);
        let cur = &self.mans[ci];
        let span = cur.end_m - cur.begin_m;
        let frac_left = if span > 0.0 { ((cur.end_m - along) / span).clamp(0.0, 1.0) } else { 0.0 };
        let remaining_s = cur.duration_s * frac_left + self.mans[ci + 1..].iter().map(|m| m.duration_s).sum::<f64>();
        let arrived = on_route && remaining_m <= q.arrive_m;

        let man_view = |i: usize, dist: f64| -> Value {
            let m = &self.mans[i].json;
            let mut v = json!({
                "index": m["index"], "kind": m["kind"], "type": m["type"], "instruction": m["instruction"], "street_names": m["street_names"],
                "travel": m["travel"], "lat": m["lat"], "lon": m["lon"], "distance_m": round_py(dist.max(0.0), 1),
                "length_m": m["distance_m"], "cardinal": m["cardinal"], "bearing_deg": m["bearing_deg"],
            });
            if self.mans[i].class != "road" {
                v["follow"] = m["follow"].clone();
                v["elev_gain_m"] = m["elev_gain_m"].clone();
                v["elev_loss_m"] = m["elev_loss_m"].clone();
                v["grade_class"] = m["grade_class"].clone();
            }
            v
        };
        let next = if ci + 1 < self.mans.len() { Some(man_view(ci + 1, self.mans[ci + 1].begin_m - along)) } else { None };
        let then = if ci + 2 < self.mans.len() { Some(man_view(ci + 2, self.mans[ci + 2].begin_m - self.mans[ci + 1].begin_m)) } else { None };

        // off-road: where to head, how far, and the climb on the way
        let leg = if cur.class != "road" {
            let t = cur.end_pt;
            Some(json!({
                "kind": cur.json["kind"],
                "target": {"lat": round_py(t.0, 6), "lon": round_py(t.1, 6)},
                "bearing_deg": bearing_deg(p, t).round() as i64 % 360,
                "cardinal": cardinal(bearing_deg(p, t)),
                "distance_m": round_py(haversine_m(p.0, p.1, t.0, t.1), 1),
                "climb_m": cur.elev_gain,
                "descent_m": cur.elev_loss,
                "grade_class": cur.json["grade_class"],
                "travel": cur.json["travel"],
            }))
        } else {
            None
        };

        let route_bearing = bearing_deg(self.pts[seg], self.pts[seg + 1]);
        let mut remaining = Map::new();
        remaining.insert("distance_m".into(), json!(round_py(remaining_m, 1)));
        remaining.insert("duration_s".into(), json!(remaining_s.round() as i64));
        if let Some(eta) = q.now.as_deref().and_then(|n| chrono::DateTime::parse_from_rfc3339(n.trim()).ok()) {
            let at = eta + chrono::Duration::seconds(remaining_s.round() as i64);
            remaining.insert("eta".into(), json!(at.to_rfc3339_opts(chrono::SecondsFormat::Secs, false)));
        }
        json!({
            "route_id": self.id,
            "fix": fix_no,
            "matched": {
                "lat": round_py(matched.0, 6), "lon": round_py(matched.1, 6), "distance_along_m": round_py(along, 1),
                "offset_m": round_py(offset, 1), "segment": seg, "route_bearing_deg": route_bearing.round() as i64 % 360,
            },
            "on_route": on_route,
            "off_route": off_route,
            "off_route_count": off_count,
            "arrived": arrived,
            "progress": round_py(if self.total_m > 0.0 { along / self.total_m } else { 1.0 }, 4),
            "remaining": Value::Object(remaining),
            "total": {"distance_m": round_py(self.total_m, 1), "duration_s": self.total_s.round() as i64},
            "current": man_view(ci, 0.0),
            "next": next,
            "then": then,
            "leg": leg,
        })
    }
}

/// A fix and the thresholds. `route` is read by the caller (the active route is found by `route_id`, or loaded from the `route` object).
pub struct ProgressReq {
    pub lat: f64,
    pub lon: f64,
    pub accuracy_m: Option<f64>,
    pub now: Option<String>,
    pub reset: bool,
    /// More than this far from the route (metres; the GPS accuracy if that is larger; twice as much on an off-road leg).
    pub off_route_m: f64,
    /// ... for this many fixes in a row is `off_route`.
    pub off_route_fixes: usize,
    /// Within this of the end is `arrived`.
    pub arrive_m: f64,
}

impl ProgressReq {
    pub fn from_json(v: &Value) -> Result<ProgressReq, ToolError> {
        let bad = |m: String| ToolError::new(ToolError::BAD_ARGUMENTS, m);
        let o = v.as_object().ok_or_else(|| bad("the request must be a JSON object".into()))?;
        for k in o.keys() {
            if !["route_id", "route", "lat", "lon", "accuracy_m", "heading_deg", "speed_mps", "now", "reset", "off_route_m", "off_route_fixes", "arrive_m"].contains(&k.as_str()) {
                return Err(bad(format!("{k}: not allowed")));
            }
        }
        let num = |k: &str| -> Result<Option<f64>, ToolError> {
            match o.get(k) {
                None | Some(Value::Null) => Ok(None),
                Some(x) => x.as_f64().filter(|f| f.is_finite()).map(Some).ok_or_else(|| bad(format!("{k}: must be a number"))),
            }
        };
        let lat = num("lat")?.filter(|x| x.abs() <= 90.0).ok_or_else(|| bad("lat: a number from -90 to 90 is required".into()))?;
        let lon = num("lon")?.filter(|x| x.abs() <= 180.0).ok_or_else(|| bad("lon: a number from -180 to 180 is required".into()))?;
        let off_route_m = num("off_route_m")?.unwrap_or(OFF_ROUTE_M);
        if off_route_m <= 0.0 {
            return Err(bad("off_route_m: must be above 0".into()));
        }
        let fixes = match o.get("off_route_fixes") {
            None | Some(Value::Null) => OFF_ROUTE_FIXES,
            Some(n) => n.as_u64().filter(|n| (1..=20).contains(n)).ok_or_else(|| bad("off_route_fixes: must be 1 to 20".into()))? as usize,
        };
        Ok(ProgressReq {
            lat,
            lon,
            accuracy_m: num("accuracy_m")?,
            now: o.get("now").and_then(Value::as_str).map(str::to_string),
            reset: o.get("reset").and_then(Value::as_bool).unwrap_or(false),
            off_route_m,
            off_route_fixes: fixes,
            arrive_m: num("arrive_m")?.unwrap_or(ARRIVE_M),
        })
    }
}

/// The routes the handle keeps for `cs_map_progress`, newest last.
#[derive(Default)]
pub struct RouteStore {
    routes: Mutex<VecDeque<Arc<ActiveRoute>>>,
}

impl RouteStore {
    pub fn add(&self, routes: &[Arc<ActiveRoute>]) {
        let mut g = self.routes.lock().unwrap_or_else(|e| e.into_inner());
        for r in routes {
            g.retain(|x| x.id != r.id);
            g.push_back(r.clone());
        }
        while g.len() > KEEP_ROUTES {
            g.pop_front();
        }
    }

    pub fn get(&self, id: &str) -> Option<Arc<ActiveRoute>> {
        self.routes.lock().unwrap_or_else(|e| e.into_inner()).iter().find(|r| r.id == id).cloned()
    }
}
