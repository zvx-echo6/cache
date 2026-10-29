//! The plain Rust API for the navigate feature: route between two points, or to a place, given a travel
//! mode and a land-access mode, and get the directions result (navi's `/api/directions` shape).
//!
//! ```ignore
//! let nav = Navigator::new(&pack, &elevation, &valhalla);
//! let d = nav.navigate(&NavigateRequest::new(
//!     Waypoint::point(44.03, -114.99),
//!     Waypoint::place("Redfish Lake Lodge", 44.1359, -114.9145),
//!     TravelMode::Drive, Boundary::Pragmatic))?;
//! println!("{}", d.to_json());
//! ```
use crate::directions::*;
use crate::elevation::ElevationSource;
use crate::pack::PackSource;
use crate::router::{Boundary, RouteOptions};
use crate::valhalla::Valhalla;

pub use crate::directions::{Directions, OffroadChoice, TravelMode};

/// A start or end of a trip: a bare coordinate, or a resolved place (the geocoder/place search of the app
/// gives the coordinates; `category` is the place's OSM "key:value" hint, which seeds the travel modes at that
/// end exactly like navi's `start_category` / `end_category`; `arrival` is where a route to the place goes when the places
/// data says it is not the place's point: an airport's passenger terminal, a main entrance, a park's parking).
#[derive(Debug, Clone)]
pub enum Waypoint {
    Point { lat: f64, lon: f64 },
    Place { name: String, lat: f64, lon: f64, category: Option<String>, arrival: Option<(f64, f64)> },
}

impl Waypoint {
    pub fn point(lat: f64, lon: f64) -> Waypoint {
        Waypoint::Point { lat, lon }
    }
    pub fn place(name: &str, lat: f64, lon: f64) -> Waypoint {
        Waypoint::Place { name: name.into(), lat, lon, category: None, arrival: None }
    }
    pub fn place_with_category(name: &str, lat: f64, lon: f64, category: &str) -> Waypoint {
        Waypoint::Place { name: name.into(), lat, lon, category: Some(category.into()), arrival: None }
    }
    /// The place with the point a route to it goes to (no change to a bare coordinate).
    pub fn with_arrival(mut self, p: Option<(f64, f64)>) -> Waypoint {
        if let Waypoint::Place { arrival, .. } = &mut self {
            *arrival = p;
        }
        self
    }
    /// Where a route starts or ends: the place's arrival point when it has one, else its point.
    pub fn route_point(&self) -> (f64, f64) {
        match self {
            Waypoint::Place { arrival: Some(a), .. } => *a,
            _ => self.latlon(),
        }
    }
    fn has_arrival(&self) -> bool {
        matches!(self, Waypoint::Place { arrival: Some(_), .. })
    }
    pub fn latlon(&self) -> (f64, f64) {
        match self {
            Waypoint::Point { lat, lon } | Waypoint::Place { lat, lon, .. } => (*lat, *lon),
        }
    }
    fn category(&self) -> Option<String> {
        match self {
            Waypoint::Place { category, .. } => category.clone(),
            _ => None,
        }
    }
    pub fn name(&self) -> Option<&str> {
        match self {
            Waypoint::Place { name, .. } => Some(name),
            _ => None,
        }
    }
}

#[derive(Debug, Clone)]
pub struct NavigateRequest {
    pub from: Waypoint,
    pub to: Waypoint,
    pub mode: TravelMode,
    /// How private / closed land is treated: strict (never cross), pragmatic (cross at a penalty), emergency (ignore).
    pub land_access: Boundary,
    pub offroad: OffroadChoice,
    pub offroad_snap_m: f64,
    pub merge_bearing_deg: f64,
    pub min_leg_m: f64,
}

impl NavigateRequest {
    pub fn new(from: Waypoint, to: Waypoint, mode: TravelMode, land_access: Boundary) -> Self {
        NavigateRequest {
            from, to, mode, land_access, offroad: OffroadChoice::Auto, offroad_snap_m: DEFAULT_OFFROAD_SNAP_M,
            merge_bearing_deg: DEFAULT_MERGE_BEARING_DEG, min_leg_m: DEFAULT_MIN_LEG_M,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum NavigateError {
    #[error("bad request: {0}")]
    BadRequest(String),
}

pub struct Navigator<'a> {
    pub pack: &'a dyn PackSource,
    pub elevation: &'a dyn ElevationSource,
    pub valhalla: &'a dyn Valhalla,
    pub options: RouteOptions,
    pub version: String,
}

fn check_point(p: (f64, f64), name: &str) -> Result<(), NavigateError> {
    if !p.0.is_finite() || !p.1.is_finite() {
        return Err(NavigateError::BadRequest(format!("{name} must be finite numbers")));
    }
    if !(-90.0..=90.0).contains(&p.0) || !(-180.0..=180.0).contains(&p.1) {
        return Err(NavigateError::BadRequest(format!("{name} out of range")));
    }
    Ok(())
}

impl<'a> Navigator<'a> {
    pub fn new(pack: &'a dyn PackSource, elevation: &'a dyn ElevationSource, valhalla: &'a dyn Valhalla) -> Self {
        Navigator { pack, elevation, valhalla, options: RouteOptions::default(), version: env!("CARGO_PKG_VERSION").into() }
    }

    /// Route and build turn-by-turn directions. Route failures are an `Ok(Directions { ok: false, errors })`
    /// with a coded error (no_route, too_far, out_of_coverage, route_too_long, ...), as in navi; only a malformed
    /// request is an `Err`.
    pub fn navigate(&self, req: &NavigateRequest) -> Result<Directions, NavigateError> {
        check_point(req.from.route_point(), "from")?;
        check_point(req.to.route_point(), "to")?;
        for (v, n) in [(req.offroad_snap_m, "offroad_snap_m"), (req.min_leg_m, "min_leg_m")] {
            if !v.is_finite() || v < 0.0 {
                return Err(NavigateError::BadRequest(format!("{n} out of range")));
            }
        }
        if !(req.merge_bearing_deg > 0.0 && req.merge_bearing_deg <= 180.0) {
            return Err(NavigateError::BadRequest("merge_bearing_deg out of range".into()));
        }
        let mut dr = DirectionsRequest::new(req.from.route_point(), req.to.route_point(), req.mode);
        dr.from_arrival = req.from.has_arrival();
        dr.to_arrival = req.to.has_arrival();
        dr.offroad = req.offroad;
        dr.offroad_snap_m = req.offroad_snap_m;
        dr.merge_bearing_deg = req.merge_bearing_deg;
        dr.min_leg_m = req.min_leg_m;
        dr.boundary = req.land_access;
        dr.from_category = req.from.category();
        dr.to_category = req.to.category();
        let env = Env {
            pack: self.pack, elevation: self.elevation, valhalla: self.valhalla, options: self.options.clone(), namer: None,
            version: self.version.clone(),
        };
        Ok(env.directions(&dr))
    }

    /// Up to `count` alternative road routes (see [`Env::alternatives`]); empty for an off-road-only request or when the
    /// router gives none.
    pub fn alternatives(&self, req: &NavigateRequest, count: usize) -> Result<Vec<Directions>, NavigateError> {
        check_point(req.from.route_point(), "from")?;
        check_point(req.to.route_point(), "to")?;
        let mut dr = DirectionsRequest::new(req.from.route_point(), req.to.route_point(), req.mode);
        dr.from_arrival = req.from.has_arrival();
        dr.to_arrival = req.to.has_arrival();
        dr.offroad = req.offroad;
        dr.offroad_snap_m = req.offroad_snap_m;
        dr.merge_bearing_deg = req.merge_bearing_deg;
        dr.min_leg_m = req.min_leg_m;
        dr.boundary = req.land_access;
        dr.from_category = req.from.category();
        dr.to_category = req.to.category();
        let env = Env {
            pack: self.pack, elevation: self.elevation, valhalla: self.valhalla, options: self.options.clone(), namer: None,
            version: self.version.clone(),
        };
        Ok(env.alternatives(&dr, count))
    }
}
