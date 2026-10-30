//! Turn-by-turn directions. Port of navi `directions.py` (`POST /api/directions`): one Valhalla road
//! route; when an end is too far from the road network the off-road router runs between that end's road
//! point and the requested point (last mile) and is stitched on; when Valhalla finds no edges the whole
//! trip is off-road. Off-road runs become decision-point legs (`offroad_legs`).
//!
//! Differences from navi are listed in DESIGN-OFFROAD.md: no reverse-geocode of the ends (`near` is null),
//! no PostGIS names for follow legs (null), and walk/bike use the same unified search with only that mode
//! seeded (navi sends them through its A/B/C scenario handlers).
use crate::cost::Mode;
use crate::elevation::ElevationSource;
use crate::grid::haversine_m;
use crate::offroad_legs::*;
use crate::pack::PackSource;
use crate::router::{Boundary, RequestMode, RouteError, RouteOptions, RouteRequest, Router};
use crate::snap::{plan_end, route_planned, EndPlan};
use crate::valhalla::{decode_polyline6, encode_polyline6, Maneuver, Valhalla, ValhallaError};
use serde_json::{json, Value};

/// A road piece of a route: its steps, its points, its maneuvers and its length.
type RoadPiece = (Vec<Step>, Vec<(f64, f64)>, Vec<Maneuver>, f64);

/// An off-road piece of a route: its steps, its points and its length.
type OffroadPiece = (Vec<Step>, Vec<(f64, f64)>, f64);

pub const DEFAULT_OFFROAD_SNAP_M: f64 = 150.0;
pub const DEFAULT_MERGE_BEARING_DEG: f64 = 60.0;
pub const DEFAULT_MIN_LEG_M: f64 = 150.0;
/// Where the Valhalla tiles end, (S, W, N, E): navi's North America default.
/// The error message of an off-road mode where no off-road data covers an end (code `not_set_up`).
pub const OFFROAD_DATA_MISSING: &str = "Off-road directions need off-road data for this area (the off-road pack and the elevation file), and none is installed for it";
pub const COVERAGE_BBOX: (f64, f64, f64, f64) = (7.0, -169.0, 84.0, -52.0);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TravelMode {
    Drive,
    Walk,
    Bike,
    /// Off-road the whole way on foot: trails and open ground (the unified search with only foot seeded).
    OffroadFoot,
    /// Off-road the whole way by vehicle: navi's unified Auto search over 4x4, ATV, two-wheeler and foot, switching at
    /// parking lots, trailheads and road ends (on foot for the last part where no vehicle can go).
    OffroadVehicle,
}
impl TravelMode {
    pub fn name(self) -> &'static str {
        match self {
            TravelMode::Drive => "drive",
            TravelMode::Walk => "walk",
            TravelMode::Bike => "bike",
            TravelMode::OffroadFoot => "offroad_foot",
            TravelMode::OffroadVehicle => "offroad_vehicle",
        }
    }
    pub fn from_name(s: &str) -> Option<TravelMode> {
        match s {
            "drive" => Some(TravelMode::Drive),
            "walk" => Some(TravelMode::Walk),
            "bike" => Some(TravelMode::Bike),
            "offroad_foot" => Some(TravelMode::OffroadFoot),
            "offroad_vehicle" => Some(TravelMode::OffroadVehicle),
            _ => None,
        }
    }
    pub fn costing(self) -> &'static str {
        match self {
            TravelMode::Drive => "auto",
            TravelMode::Walk => "pedestrian",
            TravelMode::Bike => "bicycle",
            TravelMode::OffroadFoot => "pedestrian",
            TravelMode::OffroadVehicle => "auto",
        }
    }
    /// Off-road router request mode: drive and offroad_vehicle mix vehicle/4w/2w/foot; walk and offroad_foot = foot; bike = 2w.
    pub fn router_mode(self) -> RequestMode {
        match self {
            TravelMode::Drive | TravelMode::OffroadVehicle => RequestMode::Auto,
            TravelMode::Walk | TravelMode::OffroadFoot => RequestMode::Single(Mode::Foot),
            TravelMode::Bike => RequestMode::Single(Mode::TwoW),
        }
    }
    /// The off-road modes route the whole trip with the off-road router (no road route first), and only where the
    /// off-road data covers both ends.
    pub fn offroad_only(self) -> bool {
        matches!(self, TravelMode::OffroadFoot | TravelMode::OffroadVehicle)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OffroadChoice {
    Auto,
    Never,
    Always,
}
impl OffroadChoice {
    pub fn from_name(s: &str) -> Option<OffroadChoice> {
        match s {
            "auto" => Some(OffroadChoice::Auto),
            "never" => Some(OffroadChoice::Never),
            "always" => Some(OffroadChoice::Always),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct DirectionsRequest {
    pub from: (f64, f64),
    pub to: (f64, f64),
    pub mode: TravelMode,
    pub offroad: OffroadChoice,
    pub offroad_snap_m: f64,
    pub merge_bearing_deg: f64,
    pub min_leg_m: f64,
    /// Land-access mode of the off-road search (navi's directions always use pragmatic).
    pub boundary: Boundary,
    /// Optional OSM category hints of the two ends (seed the unified search like navi's start/end_category).
    pub from_category: Option<String>,
    pub to_category: Option<String>,
    /// The end is a place's arrival point from the places data (a terminal, an entrance, a parking): it is where people go,
    /// so it snaps to its own nearest road and is never moved to a public road (`snap`).
    pub from_arrival: bool,
    pub to_arrival: bool,
}

impl DirectionsRequest {
    pub fn new(from: (f64, f64), to: (f64, f64), mode: TravelMode) -> Self {
        DirectionsRequest {
            from, to, mode, offroad: OffroadChoice::Auto, offroad_snap_m: DEFAULT_OFFROAD_SNAP_M,
            merge_bearing_deg: DEFAULT_MERGE_BEARING_DEG, min_leg_m: DEFAULT_MIN_LEG_M, boundary: Boundary::Pragmatic,
            from_category: None, to_category: None, from_arrival: false, to_arrival: false,
        }
    }
}

#[derive(Debug, Clone)]
pub struct DirectionsError {
    pub code: String,
    pub message: String,
    pub valhalla_code: Option<i64>,
}
impl DirectionsError {
    fn new(code: &str, message: impl Into<String>) -> Self {
        DirectionsError { code: code.into(), message: message.into(), valhalla_code: None }
    }
    fn to_json(&self) -> Value {
        json!({"code": self.code, "message": self.message, "valhalla_code": self.valhalla_code})
    }
}

#[derive(Debug, Clone)]
pub struct Warning {
    pub message: String,
    pub reason: Option<String>,
    pub end: String,
    pub road_point: (f64, f64),
    pub gap_m: i64,
    /// Whether the off-road data covers the end away from the road (when it does, the router itself found no way).
    pub covered: bool,
}

#[derive(Debug, Clone)]
pub struct EndInfo {
    pub lat: f64,
    pub lon: f64,
    pub snap_distance_m: i64,
    /// The end was moved past service roads to a public road (`snap`): its snap distance is how people get to the car, not
    /// a gap to the road network. Not in the response.
    pub public_road: bool,
}

#[derive(Debug, Clone)]
pub struct Directions {
    pub ok: bool,
    pub route_id: String,
    pub mode: TravelMode,
    pub from: Option<EndInfo>,
    pub to: Option<EndInfo>,
    pub distance_km: f64,
    pub distance_mi: f64,
    pub duration_s: i64,
    pub major_roads: Vec<(String, f64)>,
    pub steps: Vec<Step>,
    /// polyline6
    pub shape: String,
    /// "road" | "offroad"
    pub routing: String,
    pub leg_params: (f64, f64, f64), // offroad_snap_m, merge_bearing_deg, min_leg_m
    pub warnings: Vec<Warning>,
    pub errors: Vec<DirectionsError>,
}

impl Directions {
    /// navi's `/api/directions` response body.
    pub fn to_json(&self) -> Value {
        if !self.ok {
            return json!({"ok": false, "route_id": self.route_id, "mode": self.mode.name(), "costing": self.mode.costing(),
                          "errors": self.errors.iter().map(|e| e.to_json()).collect::<Vec<_>>()});
        }
        let end = |e: &Option<EndInfo>| e.as_ref().map(|e| json!({"lat": e.lat, "lon": e.lon, "snap_distance_m": e.snap_distance_m, "near": null}));
        let mut body = json!({
            "ok": true, "route_id": self.route_id, "mode": self.mode.name(), "costing": self.mode.costing(),
            "from": end(&self.from), "to": end(&self.to),
            "summary": {"distance_km": self.distance_km, "distance_mi": self.distance_mi, "duration_s": self.duration_s,
                        "step_count": self.steps.len(),
                        "major_roads": self.major_roads.iter().map(|(n, k)| json!({"name": n, "distance_km": k})).collect::<Vec<_>>()},
            "steps": self.steps.iter().map(|s| s.to_json()).collect::<Vec<_>>(),
            "shape": self.shape, "routing": self.routing,
            "leg_params": {"offroad_snap_m": self.leg_params.0, "merge_bearing_deg": self.leg_params.1, "min_leg_m": self.leg_params.2, "simplify_m": SIMPLIFY_M},
            "errors": [],
        });
        if !self.warnings.is_empty() {
            body["warnings"] = Value::Array(
                self.warnings
                    .iter()
                    .map(|w| json!({"code": "offroad_unavailable", "message": w.message, "reason": w.reason, "end": w.end,
                                    "road_point": {"lat": round_py(w.road_point.0, 6), "lon": round_py(w.road_point.1, 6)}, "gap_m": w.gap_m}))
                    .collect(),
            );
        }
        body
    }
}

fn in_coverage(lat: f64, lon: f64) -> bool {
    let (s, w, n, e) = COVERAGE_BBOX;
    s <= lat && lat <= n && w <= lon && lon <= e
}

/// navi's route id; a land access other than pragmatic (navi's only one) is part of the key, so the same trip under another
/// land access is another route.
fn route_id(frm: (f64, f64), to: (f64, f64), mode: &str, boundary: Boundary, version: &str) -> String {
    use sha2::{Digest, Sha256};
    let mode = if boundary == Boundary::Pragmatic { mode.to_string() } else { format!("{mode}|{}", boundary.name()) };
    let key = format!("{:.6},{:.6}|{:.6},{:.6}|{}|{}", frm.0, frm.1, to.0, to.1, mode, version);
    Sha256::digest(key.as_bytes()).iter().take(8).map(|b| format!("{:02x}", b)).collect()
}

fn valhalla_failure(e: &ValhallaError, frm: (f64, f64), to: (f64, f64)) -> DirectionsError {
    if e.timeout {
        return DirectionsError::new("upstream_timeout", "Valhalla did not answer in time");
    }
    let text = if e.message.is_empty() { "Valhalla error".to_string() } else { e.message.clone() };
    let mk = |code: &str| DirectionsError { code: code.into(), message: text.clone(), valhalla_code: e.code };
    match e.code {
        Some(442) | Some(443) => mk("no_route"),
        Some(170) | Some(171) => {
            if !(in_coverage(frm.0, frm.1) && in_coverage(to.0, to.1)) {
                mk("out_of_coverage")
            } else {
                mk("too_far")
            }
        }
        Some(154) => mk("too_far"),
        _ => mk("internal"),
    }
}

fn maneuver_type_name(t: i64) -> String {
    const N: [&str; 44] = [
        "none", "start", "start_right", "start_left", "destination", "destination_right", "destination_left", "becomes",
        "continue", "slight_right", "right", "sharp_right", "uturn_right", "uturn_left", "sharp_left", "left", "slight_left",
        "ramp_straight", "ramp_right", "ramp_left", "exit_right", "exit_left", "stay_straight", "stay_right", "stay_left",
        "merge", "roundabout_enter", "roundabout_exit", "ferry_enter", "ferry_exit", "transit", "transit_transfer",
        "transit_remain_on", "transit_connection_start", "transit_connection_transfer", "transit_connection_destination",
        "post_transit_connection_destination", "merge_right", "merge_left", "elevator_enter", "steps_enter", "escalator_enter",
        "building_enter", "building_exit",
    ];
    if (0..44).contains(&t) {
        N[t as usize].to_string()
    } else {
        format!("unknown_{t}")
    }
}

fn build_steps(maneuvers: &[Maneuver], shape: &[(f64, f64)]) -> Vec<Step> {
    let last = shape.len() as i64 - 1;
    let mut steps = Vec::new();
    for (i, m) in maneuvers.iter().enumerate() {
        let b = m.begin_shape_index.clamp(0, last.max(0));
        let e = m.end_shape_index.clamp(0, last.max(0));
        let (start, end) = (shape[b as usize], shape[e as usize]);
        let mut bearing = m.bearing_after;
        if bearing.is_none() && b < last {
            bearing = Some(bearing_deg(start, shape[b as usize + 1]));
        }
        if bearing.is_none() {
            bearing = m.bearing_before;
        }
        let km = m.length_km;
        steps.push(Step {
            index: i,
            kind: "road".into(),
            type_: maneuver_type_name(m.kind),
            mode: None,
            street_names: m.street_names.clone(),
            distance_m: None,
            distance_km: round_py(km, 2),
            distance_mi: round_py(km * KM_TO_MI, 2),
            duration_s: round_i(m.time_s),
            bearing_deg: bearing.map(|b| round_i(b).rem_euclid(360)),
            cardinal: bearing.map(|b| cardinal(b).to_string()),
            elev_gain_m: None,
            elev_loss_m: None,
            grade_class: None,
            terrain: None,
            start: pt(start),
            end: pt(end),
            instruction: Some(m.instruction.clone()),
            follow: None,
        });
    }
    steps
}

fn major_roads(maneuvers: &[Maneuver]) -> Vec<(String, f64)> {
    let mut totals: Vec<(String, f64)> = Vec::new();
    for m in maneuvers {
        let Some(n) = m.street_names.first() else { continue };
        if let Some(t) = totals.iter_mut().find(|t| &t.0 == n) {
            t.1 += m.length_km;
        } else {
            totals.push((n.clone(), m.length_km));
        }
    }
    // Python sorted(..., reverse=True) is stable w.r.t. the original order for ties
    totals.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap());
    totals.into_iter().take(3).map(|(n, k)| (n, round_py(k, 2))).collect()
}

/// Everything directions needs.
pub struct Env<'a> {
    pub pack: &'a dyn PackSource,
    pub elevation: &'a dyn ElevationSource,
    pub valhalla: &'a dyn Valhalla,
    pub options: RouteOptions,
    /// Names for follow legs (navi reads PostGIS entry_points; Cache has no such table, so None).
    pub namer: Option<Namer<'a>>,
    /// Mixed into route_id (navi: the git sha).
    pub version: String,
}

pub struct Assembled {
    pub steps: Vec<Step>,
    pub shape: Vec<(f64, f64)>,
    pub maneuvers: Vec<Maneuver>,
    pub km: f64,
}

pub type ADirResult<T> = Result<T, DirectionsError>;

impl Env<'_> {
    fn valhalla_route(&self, frm: (f64, f64), to: (f64, f64), costing: &str) -> ADirResult<crate::valhalla::Trip> {
        self.valhalla.route(frm, to, costing).map_err(|e| valhalla_failure(&e, frm, to))
    }

    fn run_offroad_router(&self, frm: (f64, f64), to: (f64, f64), req: &DirectionsRequest, from_cat: Option<&String>, to_cat: Option<&String>) -> Result<crate::router::RouteResult, RouteError> {
        let mut rr = RouteRequest::new(frm, to, req.mode.router_mode(), req.boundary);
        rr.collect_detail = true;
        rr.start_category = from_cat.cloned();
        rr.end_category = to_cat.cloned();
        Router { pack: self.pack, elevation: self.elevation, valhalla: self.valhalla, opts: self.options.clone() }.route(&rr)
    }

    pub fn assemble_offroad(&self, pieces: &[Piece], req: &DirectionsRequest) -> ADirResult<Assembled> {
        let mut steps: Vec<Step> = Vec::new();
        let mut shape: Vec<(f64, f64)> = Vec::new();
        let mut maneuvers: Vec<Maneuver> = Vec::new();
        let mut raw_m = 0.0;
        for (n, piece) in pieces.iter().enumerate() {
            let is_last = n == pieces.len() - 1;
            let mut got: Option<RoadPiece> = None;
            if let PieceKind::Road { start, end } = &piece.kind {
                let costing = if piece.mode == "vehicle" || piece.mode == "4w" { "auto" } else if piece.mode == "foot" { "pedestrian" } else if piece.mode == "2w" { "bicycle" } else { "auto" };
                match self.valhalla_route(*start, *end, costing) {
                    Ok(trip) => {
                        let pts = trip.shape.clone();
                        let mut new = build_steps(&trip.maneuvers, &pts);
                        if !is_last {
                            new.retain(|st| !(st.type_.starts_with("destination") && st.distance_km == 0.0));
                        }
                        if let Some(f) = new.first_mut() {
                            f.duration_s += round_i(piece.extra_s);
                        }
                        got = Some((new, pts, trip.maneuvers.clone(), trip.length_km * 1000.0));
                    }
                    Err(err) => {
                        if piece.cells.is_none() {
                            return Err(err);
                        }
                    }
                }
            }
            if got.is_none() {
                let cells = piece.cells.as_ref().unwrap();
                let after = match &piece.kind {
                    PieceKind::Offroad { after_switch } => *after_switch,
                    PieceKind::Road { .. } => false,
                };
                let (new, raw) = offroad_steps(cells, &piece.mode, req.merge_bearing_deg, req.min_leg_m, after, piece.extra_s, self.namer);
                let pts: Vec<(f64, f64)> = cells.lat.iter().cloned().zip(cells.lon.iter().cloned()).collect();
                got = Some((new, pts, vec![], raw.iter().map(|r| r.0).sum()));
            }
            let (new, pts, mans, m) = got.unwrap();
            steps.extend(new);
            for p in pts {
                if shape.last() != Some(&p) {
                    shape.push(p);
                }
            }
            maneuvers.extend(mans);
            raw_m += m;
        }
        for (i, st) in steps.iter_mut().enumerate() {
            st.index = i;
        }
        Ok(Assembled { steps, shape, maneuvers, km: raw_m / 1000.0 })
    }

    fn offroad_error(e: &RouteError) -> DirectionsError {
        match e {
            RouteError::TooLong { .. } => DirectionsError::new("route_too_long", e.to_string()),
            _ => DirectionsError::new("no_route", e.to_string()),
        }
    }

    fn last_mile(&self, a: (f64, f64), b: (f64, f64), req: &DirectionsRequest, after_road: bool, from_cat: Option<&String>, to_cat: Option<&String>) -> ADirResult<OffroadPiece> {
        let result = self.run_offroad_router(a, b, req, from_cat, to_cat).map_err(|e| Self::offroad_error(&e))?;
        let mut pieces = pieces_from_result(&result);
        if after_road {
            if let Some(p) = pieces.first_mut() {
                if let PieceKind::Offroad { after_switch } = &mut p.kind {
                    *after_switch = true;
                }
            }
        }
        let asm = self.assemble_offroad(&pieces, req)?;
        if asm.steps.is_empty() {
            return Err(DirectionsError::new("no_route", "Off-road router returned no usable path"));
        }
        Ok((asm.steps, asm.shape, asm.km))
    }

    fn fail(&self, req: &DirectionsRequest, rid: &str, e: DirectionsError) -> Directions {
        Directions {
            ok: false, route_id: rid.into(), mode: req.mode, from: None, to: None, distance_km: 0.0, distance_mi: 0.0,
            duration_s: 0, major_roads: vec![], steps: vec![], shape: String::new(), routing: String::new(),
            leg_params: (req.offroad_snap_m, req.merge_bearing_deg, req.min_leg_m), warnings: vec![], errors: vec![e],
        }
    }

    fn offroad_response(&self, req: &DirectionsRequest, rid: &str) -> Directions {
        let result = match self.run_offroad_router(req.from, req.to, req, req.from_category.as_ref(), req.to_category.as_ref()) {
            Ok(r) => r,
            Err(e) => return self.fail(req, rid, Self::offroad_error(&e)),
        };
        let pieces = pieces_from_result(&result);
        let asm = match self.assemble_offroad(&pieces, req) {
            Ok(a) => a,
            Err(e) => return self.fail(req, rid, e),
        };
        if asm.steps.is_empty() {
            return self.fail(req, rid, DirectionsError::new("no_route", "Off-road router returned no usable path"));
        }
        let km = asm.km;
        let first = asm.steps.first().unwrap().start;
        let last = asm.steps.last().unwrap().end;
        Directions {
            ok: true,
            route_id: rid.into(),
            mode: req.mode,
            from: Some(end_info(req.from, first)),
            to: Some(end_info(req.to, last)),
            distance_km: round_py(km, 2),
            distance_mi: round_py(km * KM_TO_MI, 2),
            duration_s: asm.steps.iter().map(|s| s.duration_s).sum(),
            major_roads: major_roads(&asm.maneuvers),
            steps: asm.steps,
            shape: encode_polyline6(&asm.shape),
            routing: "offroad".into(),
            leg_params: (req.offroad_snap_m, req.merge_bearing_deg, req.min_leg_m),
            warnings: vec![],
            errors: vec![],
        }
    }

    /// `POST /api/directions`.
    pub fn directions(&self, req: &DirectionsRequest) -> Directions {
        let rid = route_id(req.from, req.to, req.mode.name(), req.boundary, &self.version);
        if req.mode.offroad_only() {
            if !(self.pack.covers(req.from.0, req.from.1) && self.pack.covers(req.to.0, req.to.1)) {
                return self.fail(req, &rid, DirectionsError::new("not_set_up", OFFROAD_DATA_MISSING));
            }
            return self.offroad_response(req, &rid);
        }
        if req.offroad == OffroadChoice::Always {
            return self.offroad_response(req, &rid);
        }
        let (from, to) = self.plan_ends(req);
        let (trip, from, to) = match route_planned(self.valhalla, &from, &to, req.mode.costing()) {
            Ok(t) => t,
            Err(e) => {
                let e = valhalla_failure(&e, req.from, req.to);
                if req.offroad == OffroadChoice::Auto && e.code == "too_far" {
                    return self.offroad_response(req, &rid);
                }
                return self.fail(req, &rid, e);
            }
        };
        self.directions_for_trip(req, &rid, trip, (from.public_road, to.public_road))
    }

    /// How the two ends snap to the roads (`snap`: past service roads to a public road).
    fn plan_ends(&self, req: &DirectionsRequest) -> (EndPlan, EndPlan) {
        let c = req.mode.costing();
        (plan_end(self.valhalla, req.from, c, !req.from_arrival), plan_end(self.valhalla, req.to, c, !req.to_arrival))
    }

    /// Alternative road routes between the same two points (Valhalla's `alternates`), best first, each as full directions
    /// with its own route id (`<id>-1`, `<id>-2`). Road only: an end away from the roads gets no off-road leg here, so callers
    /// offer these only for a route that has none. Empty when the router gives no alternatives.
    pub fn alternatives(&self, req: &DirectionsRequest, count: usize) -> Vec<Directions> {
        if req.offroad == OffroadChoice::Always || req.mode.offroad_only() || count == 0 {
            return vec![];
        }
        let rid = route_id(req.from, req.to, req.mode.name(), req.boundary, &self.version);
        let mut road_only = req.clone();
        road_only.offroad = OffroadChoice::Never;
        let (from, to) = self.plan_ends(req);
        let public = (from.public_road, to.public_road);
        self.valhalla
            .alternatives_ends(&from.end, &to.end, req.mode.costing(), count)
            .into_iter()
            .enumerate()
            .map(|(i, t)| self.directions_for_trip(&road_only, &format!("{rid}-{}", i + 1), t, public))
            .filter(|d| d.ok)
            .collect()
    }

    /// Directions from a Valhalla trip: the steps, and (for `Auto`) the off-road lead and tail when an end is away from the road.
    /// `public_road` says which ends (from, to) were moved past service roads to a public road: that gap is how people get to
    /// the car, so it gets no off-road leg and no warning (project decision, 2026-10-29).
    fn directions_for_trip(&self, req: &DirectionsRequest, rid: &str, trip: crate::valhalla::Trip, public_road: (bool, bool)) -> Directions {
        let rid = rid.to_string();
        if trip.shape.is_empty() || trip.maneuvers.is_empty() {
            return self.fail(req, &rid, DirectionsError::new("no_route", "No route found"));
        }
        let shape = trip.shape.clone();
        let mut steps = build_steps(&trip.maneuvers, &shape);
        let mut km = trip.length_km;
        let mut distance_km = round_py(km, 2);
        let mut distance_mi = round_py(km * KM_TO_MI, 2);
        let mut duration_s = round_i(trip.time_s);
        let mut from_end = end_info(req.from, shape[0]);
        let mut to_end = end_info(req.to, *shape.last().unwrap());
        let mut warnings = Vec::new();
        let mut routing = "road".to_string();
        let mut out_shape = trip.shape_encoded.clone();
        if req.offroad == OffroadChoice::Auto {
            let (mut lead, mut tail) = (None, None);
            for (end, p, road, public) in [("from", req.from, shape[0], public_road.0), ("to", req.to, *shape.last().unwrap(), public_road.1)] {
                if public || haversine_m(p.0, p.1, road.0, road.1) <= req.offroad_snap_m {
                    continue;
                }
                let (a, b) = if end == "from" { (p, road) } else { (road, p) };
                let (fc, tc) = if end == "from" { (req.from_category.as_ref(), None) } else { (None, req.to_category.as_ref()) };
                match self.last_mile(a, b, req, end == "to", fc, tc) {
                    Err(e) => warnings.push(Warning {
                        message: e.message.clone(),
                        reason: if e.code == "no_route" { None } else { Some(e.code.clone()) },
                        end: end.into(),
                        road_point: road,
                        gap_m: round_i(haversine_m(p.0, p.1, road.0, road.1)),
                        covered: self.pack.covers(p.0, p.1),
                    }),
                    Ok(got) => {
                        if end == "from" {
                            lead = Some(got)
                        } else {
                            tail = Some(got)
                        }
                    }
                }
            }
            if lead.is_some() || tail.is_some() {
                routing = "offroad".into();
                if tail.is_some() {
                    steps.retain(|st| !(st.type_.starts_with("destination") && st.distance_km == 0.0));
                }
                let mut all: Vec<Step> = Vec::new();
                if let Some(l) = &lead {
                    all.extend(l.0.clone());
                }
                all.extend(steps);
                if let Some(t) = &tail {
                    all.extend(t.0.clone());
                }
                steps = all;
                for (i, st) in steps.iter_mut().enumerate() {
                    st.index = i;
                }
                let mut pts: Vec<(f64, f64)> = Vec::new();
                let parts: [&[(f64, f64)]; 3] = [lead.as_ref().map_or(&[][..], |l| &l.1[..]), &shape[..], tail.as_ref().map_or(&[][..], |t| &t.1[..])];
                for part in parts {
                    for p in part {
                        if pts.last() != Some(p) {
                            pts.push(*p);
                        }
                    }
                }
                out_shape = encode_polyline6(&pts);
                km += lead.as_ref().map_or(0.0, |l| l.2) + tail.as_ref().map_or(0.0, |t| t.2);
                distance_km = round_py(km, 2);
                distance_mi = round_py(km * KM_TO_MI, 2);
                duration_s = steps.iter().map(|s| s.duration_s).sum();
                from_end = end_info(req.from, steps.first().unwrap().start);
                to_end = end_info(req.to, steps.last().unwrap().end);
            }
        }
        from_end.public_road = public_road.0;
        to_end.public_road = public_road.1;
        Directions {
            ok: true,
            route_id: rid,
            mode: req.mode,
            from: Some(from_end),
            to: Some(to_end),
            distance_km,
            distance_mi,
            duration_s,
            major_roads: major_roads(&trip.maneuvers),
            steps,
            shape: out_shape,
            routing,
            leg_params: (req.offroad_snap_m, req.merge_bearing_deg, req.min_leg_m),
            warnings,
            errors: vec![],
        }
    }
}

fn end_info(p: (f64, f64), snap: (f64, f64)) -> EndInfo {
    EndInfo { lat: round_py(p.0, 6), lon: round_py(p.1, 6), snap_distance_m: round_i(haversine_m(p.0, p.1, snap.0, snap.1)), public_road: false }
}

/// Used by tests: decode the response shape.
pub fn shape_points(d: &Directions) -> Vec<(f64, f64)> {
    decode_polyline6(&d.shape)
}
