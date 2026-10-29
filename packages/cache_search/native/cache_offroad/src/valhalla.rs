//! The Valhalla seam. [`Valhalla`] is what the router and the directions code need from a network
//! router: `/locate` (verbose edge classification), `/route`, and `/trace_attributes` (map matching, for the
//! surface-change transitions). [`shim::ShimValhalla`] implements it on the C shim (packages/valhalla);
//! [`StubValhalla`] finds nothing (tests, and builds without the library).
//!
//! This module also carries the polyline6 codec (`mvum_surface_change.encode_polyline6/decode_polyline6`).

/// Result of a `/locate` snap for one costing.
#[derive(Debug, Clone)]
pub struct LocateSnap {
    pub snap_distance_m: f64,
    /// `edge.classification.classification` (road grade), e.g. "residential".
    pub road_class: Option<String>,
    /// `edge.classification.use`, e.g. "track".
    pub use_: Option<String>,
}

/// One Valhalla maneuver, with the fields navi's directions code reads.
#[derive(Debug, Clone, Default)]
pub struct Maneuver {
    pub instruction: String,
    /// Valhalla maneuver type enum
    pub kind: i64,
    pub length_km: f64,
    pub time_s: f64,
    pub street_names: Vec<String>,
    pub begin_shape_index: i64,
    pub end_shape_index: i64,
    pub bearing_after: Option<f64>,
    pub bearing_before: Option<f64>,
}

/// First leg of a `/route` reply (navi only ever uses `legs[0]` of a two-location request).
#[derive(Debug, Clone)]
pub struct Trip {
    /// (lat, lon)
    pub shape: Vec<(f64, f64)>,
    pub shape_encoded: String,
    pub maneuvers: Vec<Maneuver>,
    pub length_km: f64,
    pub time_s: f64,
}

#[derive(Debug, Clone)]
pub struct ValhallaError {
    /// Valhalla's `error_code` when it gave one.
    pub code: Option<i64>,
    pub message: String,
    pub timeout: bool,
}
impl ValhallaError {
    pub fn msg(m: impl Into<String>) -> Self {
        ValhallaError { code: None, message: m.into(), timeout: false }
    }
}

/// One `trace_attributes` edge (the attributes navi asks for).
#[derive(Debug, Clone, Default)]
pub struct TraceEdge {
    pub use_: Option<String>,
    pub road_class: Option<String>,
    pub surface: Option<String>,
    pub begin_shape_index: Option<i64>,
    pub end_shape_index: Option<i64>,
}

#[derive(Debug, Clone)]
pub struct Trace {
    pub edges: Vec<TraceEdge>,
    /// matched shape, polyline6 (the edge indices refer to it)
    pub shape: Option<String>,
}

/// A pure network route (scenario D / the bypass).
#[derive(Debug, Clone)]
pub struct NetworkRoute {
    /// (lon, lat)
    pub coords: Vec<(f64, f64)>,
    pub distance_km: f64,
    pub duration_min: f64,
    pub maneuvers: Vec<Maneuver>,
}

impl NetworkRoute {
    pub fn from_trip(t: &Trip) -> NetworkRoute {
        NetworkRoute {
            coords: t.shape.iter().map(|&(la, lo)| (lo, la)).collect(),
            distance_km: t.length_km,
            duration_min: t.time_s / 60.0,
            maneuvers: t.maneuvers.clone(),
        }
    }
}

/// How a route end snaps to the road network (Valhalla location options).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct EndOptions {
    /// `search_filter.min_road_class`: the lowest road class the end may snap to ("residential" leaves out service roads).
    pub min_road_class: Option<String>,
    /// `radius` in metres: every edge within it is a candidate, not only the nearest.
    pub radius_m: Option<u32>,
}

/// A route end: the point, and how it snaps.
#[derive(Debug, Clone, PartialEq)]
pub struct RouteEnd {
    pub lat: f64,
    pub lon: f64,
    pub opts: EndOptions,
}

impl RouteEnd {
    /// The point with Valhalla's own snapping.
    pub fn at(p: (f64, f64)) -> RouteEnd {
        RouteEnd { lat: p.0, lon: p.1, opts: EndOptions::default() }
    }
    pub fn point(&self) -> (f64, f64) {
        (self.lat, self.lon)
    }
}

/// One edge a route end could snap to (`/locate`, verbose).
#[derive(Debug, Clone, PartialEq)]
pub struct EdgeCandidate {
    /// The point on the edge nearest the asked-for point.
    pub lat: f64,
    pub lon: f64,
    /// Metres from the asked-for point.
    pub distance_m: f64,
    /// `edge.classification.classification`, e.g. "service_other".
    pub road_class: Option<String>,
    /// `edge.classification.use`, e.g. "service_road".
    pub use_: Option<String>,
    /// `edge_info.names`: the road's names.
    pub names: Vec<String>,
}

pub trait Valhalla: Send + Sync {
    /// `costing` is "auto", "pedestrian" or "bicycle". None = the call failed (navi: snap distance inf).
    fn locate(&self, lat: f64, lon: f64, costing: &str) -> Option<LocateSnap>;
    /// Two-location `/route` with distances in km.
    fn route(&self, from: (f64, f64), to: (f64, f64), costing: &str) -> Result<Trip, ValhallaError>;
    /// The edges an end at the point could snap to under `opts`, nearest first; empty when none, or when the router cannot
    /// say (the ends then snap as `route` snaps them).
    fn candidates(&self, _lat: f64, _lon: f64, _costing: &str, _opts: &EndOptions) -> Vec<EdgeCandidate> {
        Vec::new()
    }
    /// `route` with snapping options per end. The default ignores the options.
    fn route_ends(&self, from: &RouteEnd, to: &RouteEnd, costing: &str) -> Result<Trip, ValhallaError> {
        self.route(from.point(), to.point(), costing)
    }
    /// `/trace_attributes` of a polyline6 shape with auto costing and the attributes navi filters for.
    fn trace_attributes(&self, encoded_polyline6: &str) -> Result<Trace, ValhallaError>;
    /// Up to `count` alternative routes besides the best one (Valhalla's `alternates`), best first; none when the router gives
    /// none or cannot ask. Only the map's route preview uses this.
    fn alternatives(&self, _from: (f64, f64), _to: (f64, f64), _costing: &str, _count: usize) -> Vec<Trip> {
        Vec::new()
    }
    /// `alternatives` with snapping options per end. The default ignores the options.
    fn alternatives_ends(&self, from: &RouteEnd, to: &RouteEnd, costing: &str, count: usize) -> Vec<Trip> {
        self.alternatives(from.point(), to.point(), costing, count)
    }
}

/// STUB. Not a real Valhalla: every call reports "nothing found".
pub struct StubValhalla;

impl Valhalla for StubValhalla {
    fn locate(&self, _lat: f64, _lon: f64, _costing: &str) -> Option<LocateSnap> {
        None
    }
    fn route(&self, _f: (f64, f64), _t: (f64, f64), _c: &str) -> Result<Trip, ValhallaError> {
        Err(ValhallaError::msg("StubValhalla: no network router wired"))
    }
    fn trace_attributes(&self, _p: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("StubValhalla: no network router wired"))
    }
}

// ---- polyline6 ----------------------------------------------------------------------------------

pub fn encode_polyline6(coords: &[(f64, f64)]) -> String {
    let factor = 1e6;
    let mut out = String::new();
    let (mut plat, mut plon) = (0i64, 0i64);
    for &(lat, lon) in coords {
        let la = (lat * factor).round_ties_even() as i64;
        let lo = (lon * factor).round_ties_even() as i64;
        for delta in [la - plat, lo - plon] {
            let mut v: i64 = if delta < 0 { !(delta << 1) } else { delta << 1 };
            while v >= 0x20 {
                out.push((((0x20 | (v & 0x1f)) + 63) as u8) as char);
                v >>= 5;
            }
            out.push(((v + 63) as u8) as char);
        }
        plat = la;
        plon = lo;
    }
    out
}

/// Decode a polyline6 string to (lat, lon).
pub fn decode_polyline6(enc: &str) -> Vec<(f64, f64)> {
    let b = enc.as_bytes();
    let (mut idx, mut lat, mut lon) = (0usize, 0i64, 0i64);
    let mut out = Vec::new();
    while idx < b.len() {
        for axis in 0..2 {
            let (mut shift, mut result) = (0u32, 0i64);
            loop {
                if idx >= b.len() {
                    return out;
                }
                let c = b[idx] as i64 - 63;
                idx += 1;
                result |= (c & 0x1f) << shift;
                shift += 5;
                if c < 0x20 {
                    break;
                }
            }
            let delta = if result & 1 != 0 { !(result >> 1) } else { result >> 1 };
            if axis == 0 {
                lat += delta;
            } else {
                lon += delta;
            }
        }
        out.push((lat as f64 / 1e6, lon as f64 / 1e6));
    }
    out
}
