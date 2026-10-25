//! The Valhalla seam. Phase 3 plugs in the real shim (packages/valhalla); until then
//! [`StubValhalla`] answers "no network" for everything, so seeding falls back to foot-only and the
//! road-to-road bypass never fires unless an endpoint category says so (and then fails through).

/// Result of a `/locate` snap for one costing.
#[derive(Debug, Clone)]
pub struct LocateSnap {
    pub snap_distance_m: f64,
    /// `edge.classification.classification` (road grade), e.g. "residential".
    pub road_class: Option<String>,
    /// `edge.classification.use`, e.g. "track".
    pub use_: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Maneuver {
    pub instruction: String,
    pub kind: i64,
    pub distance_km: f64,
    pub time_seconds: f64,
    pub street_names: Vec<String>,
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

pub trait Valhalla: Send + Sync {
    /// `costing` is "auto", "pedestrian" or "bicycle". None = the call failed (navi: snap distance inf).
    fn locate(&self, lat: f64, lon: f64, costing: &str) -> Option<LocateSnap>;
    /// Auto-costing route between the endpoints (the road-to-road bypass).
    fn route_vehicle(&self, start: (f64, f64), end: (f64, f64)) -> Result<NetworkRoute, String>;
    /// Shape (lat, lon) of the auto route between the endpoints, for surface-change tracing.
    fn route_shape(&self, start: (f64, f64), end: (f64, f64)) -> Vec<(f64, f64)>;
    /// Surface-change candidate points (lat, lon) along a shape (trace_attributes).
    fn surface_change_candidates(&self, shape: &[(f64, f64)]) -> Vec<(f64, f64)>;
}

/// STUB. Not a real Valhalla: every call reports "nothing found". Replace in phase 3.
pub struct StubValhalla;

impl Valhalla for StubValhalla {
    fn locate(&self, _lat: f64, _lon: f64, _costing: &str) -> Option<LocateSnap> {
        None
    }
    fn route_vehicle(&self, _s: (f64, f64), _e: (f64, f64)) -> Result<NetworkRoute, String> {
        Err("StubValhalla: no network router wired yet (phase 3)".into())
    }
    fn route_shape(&self, _s: (f64, f64), _e: (f64, f64)) -> Vec<(f64, f64)> {
        Vec::new()
    }
    fn surface_change_candidates(&self, _shape: &[(f64, f64)]) -> Vec<(f64, f64)> {
        Vec::new()
    }
}
