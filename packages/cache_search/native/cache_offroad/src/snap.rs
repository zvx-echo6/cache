//! Where a drive starts and ends on the road network, the way Apple Maps picks it (project decision, 2026-10-29: "match what
//! Apple Maps does"). Valhalla on its own snaps each end to the nearest edge of any class, which puts a trip from an airport
//! terminal on the airfield's service roads and a start beside a divided street on whichever carriageway is a metre closer.
//!
//! - When the nearest edge is a generic service road (airport, campus and private access roads), the end goes to the nearest
//!   public road (residential or better) within [`PUBLIC_ROAD_M`]. That gap is how people get to the car, not an off-road
//!   leg: directions add no off-road leg and no `offroad_unavailable` warning for it.
//! - When the other carriageway of a split one-way street (an edge of the same name) is within [`SPLIT_EXTRA_M`] of the
//!   nearest one, the trip is routed from both and the faster route kept: two route calls, only in that case.
//!
//! Only driving does this; walking and cycling keep Valhalla's own snapping (service roads and paths are where people walk).
use crate::grid::haversine_m;
use crate::valhalla::{EdgeCandidate, EndOptions, RouteEnd, Trip, Valhalla, ValhallaError};

/// How far an end may move past service roads to reach a public road.
pub const PUBLIC_ROAD_M: f64 = 600.0;
/// The road class a public road has at least (Valhalla's classes: motorway ... residential, then service_other).
pub const PUBLIC_MIN_CLASS: &str = "residential";
/// Another edge this much farther than the nearest is as likely a start, and is routed too.
pub const SPLIT_EXTRA_M: f64 = 25.0;
/// Edges whose nearest points are closer than this are one road (the two directions of a two-way street).
const SAME_ROAD_M: f64 = 5.0;
/// Valhalla's `service_limits.max_radius`.
const MAX_RADIUS_M: f64 = 200.0;

/// How one end of a drive snaps.
#[derive(Debug, Clone, PartialEq)]
pub struct EndPlan {
    /// The end to route from or to, and (when two roads are about as near) the other road's end, tried too.
    pub ends: Vec<RouteEnd>,
    /// The end moved past service roads to a public road: the gap is not an off-road leg.
    pub public_road: bool,
}

impl EndPlan {
    fn plain(p: (f64, f64)) -> EndPlan {
        EndPlan { ends: vec![RouteEnd::at(p)], public_road: false }
    }
}

/// A generic service road: what airfields, campuses and private access roads are mapped as. Parking aisles, driveways,
/// alleys and drive-throughs are left alone: they are where a trip to a shop or a house really ends.
fn service_road(c: &EdgeCandidate) -> bool {
    c.road_class.as_deref() == Some("service_other") && c.use_.as_deref() == Some("service_road")
}

/// The snapping of the end at `p` for `costing`. `to_public` false keeps the end on its nearest road even when that is a
/// service road (a place's arrival point from the places data, which is already where people go).
pub fn plan_end(v: &dyn Valhalla, p: (f64, f64), costing: &str, to_public: bool) -> EndPlan {
    if costing != "auto" {
        return EndPlan::plain(p);
    }
    let near = v.candidates(p.0, p.1, costing, &EndOptions::default());
    let Some(first) = near.first() else { return EndPlan::plain(p) };
    let mut opts = EndOptions::default();
    let mut public_road = false;
    let mut nearest = first.distance_m;
    if to_public && service_road(first) {
        let public = EndOptions { min_road_class: Some(PUBLIC_MIN_CLASS.into()), radius_m: None };
        if let Some(c) = v.candidates(p.0, p.1, costing, &public).first() {
            if c.distance_m <= PUBLIC_ROAD_M {
                nearest = c.distance_m;
                opts = public;
                public_road = true;
            }
        }
    }
    let mut ends = vec![RouteEnd { lat: p.0, lon: p.1, opts: opts.clone() }];
    let radius = (nearest + SPLIT_EXTRA_M).ceil().min(MAX_RADIUS_M);
    if radius > nearest {
        let wide = EndOptions { radius_m: Some(radius as u32), ..opts.clone() };
        let cands = v.candidates(p.0, p.1, costing, &wide);
        if let Some(best) = cands.first() {
            let other = cands.iter().find(|c| {
                c.distance_m <= best.distance_m + SPLIT_EXTRA_M
                    && haversine_m(best.lat, best.lon, c.lat, c.lon) > SAME_ROAD_M
                    && c.names.iter().any(|n| best.names.contains(n))
            });
            if let Some(o) = other {
                ends.push(RouteEnd { lat: o.lat, lon: o.lon, opts: opts.clone() });
            }
        }
    }
    EndPlan { ends, public_road }
}

/// The road route between two planned ends: the first ends, then each other end in turn (the other end at its pick so far),
/// keeping whichever is faster. Falls back to Valhalla's own snapping when the planned ends find no route.
pub fn route_planned(v: &dyn Valhalla, from: &EndPlan, to: &EndPlan, costing: &str) -> Result<(Trip, EndPlan, EndPlan), ValhallaError> {
    let (mut f, mut t) = (from.ends[0].clone(), to.ends[0].clone());
    let mut best = v.route_ends(&f, &t, costing);
    for which in [0, 1] {
        let plan = if which == 0 { from } else { to };
        for alt in plan.ends.iter().skip(1) {
            let (af, at) = if which == 0 { (alt.clone(), t.clone()) } else { (f.clone(), alt.clone()) };
            let Ok(trip) = v.route_ends(&af, &at, costing) else { continue };
            if best.as_ref().map_or(true, |b| trip.time_s < b.time_s) {
                best = Ok(trip);
                (f, t) = (af, at);
            }
        }
    }
    let picked = |plan: &EndPlan, e: RouteEnd| EndPlan { ends: vec![e], public_road: plan.public_road };
    match best {
        Ok(trip) => Ok((trip, picked(from, f), picked(to, t))),
        Err(e) => {
            let changed = |plan: &EndPlan| plan.ends.len() > 1 || plan.ends[0].opts != EndOptions::default();
            if !(changed(from) || changed(to)) {
                return Err(e);
            }
            let (pf, pt) = (EndPlan::plain(from.ends[0].point()), EndPlan::plain(to.ends[0].point()));
            let trip = v.route_ends(&pf.ends[0], &pt.ends[0], costing).map_err(|_| e)?;
            Ok((trip, pf, pt))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::valhalla::{encode_polyline6, Maneuver, LocateSnap, Trace};
    use std::sync::Mutex;

    /// Roads as candidate lists: what `candidates` answers for (filtered, radius), and route times by the start's latitude.
    struct Roads {
        plain: Vec<EdgeCandidate>,
        public: Vec<EdgeCandidate>,
        calls: Mutex<Vec<(RouteEnd, RouteEnd)>>,
        /// Seconds per route by the start's latitude (rounded to 1e-4); others 100.
        times: Vec<(f64, f64)>,
    }
    fn edge(lat: f64, lon: f64, d: f64, cls: &str, use_: &str) -> EdgeCandidate {
        EdgeCandidate { lat, lon, distance_m: d, road_class: Some(cls.into()), use_: Some(use_.into()), names: vec![] }
    }
    fn named(mut e: EdgeCandidate, name: &str) -> EdgeCandidate {
        e.names = vec![name.into()];
        e
    }
    impl Valhalla for Roads {
        fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
            None
        }
        fn route(&self, _: (f64, f64), _: (f64, f64), _: &str) -> Result<Trip, ValhallaError> {
            unreachable!("route_ends is used")
        }
        fn candidates(&self, _: f64, _: f64, _: &str, o: &EndOptions) -> Vec<EdgeCandidate> {
            let all = if o.min_road_class.is_some() { &self.public } else { &self.plain };
            let first = all.first().map_or(0.0, |c| c.distance_m);
            let r = o.radius_m.map_or(first, |r| r as f64);
            all.iter().filter(|c| c.distance_m <= r).cloned().collect()
        }
        fn route_ends(&self, f: &RouteEnd, t: &RouteEnd, _: &str) -> Result<Trip, ValhallaError> {
            self.calls.lock().unwrap().push((f.clone(), t.clone()));
            let time = self.times.iter().find(|(lat, _)| (lat - f.lat).abs() < 1e-4).map_or(100.0, |x| x.1);
            let shape = vec![f.point(), t.point()];
            Ok(Trip { shape_encoded: encode_polyline6(&shape), shape, maneuvers: vec![Maneuver::default()], length_km: 1.0, time_s: time })
        }
        fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
            Err(ValhallaError::msg("n/a"))
        }
    }
    fn roads(plain: Vec<EdgeCandidate>, public: Vec<EdgeCandidate>) -> Roads {
        Roads { plain, public, calls: Mutex::new(vec![]), times: vec![] }
    }
    const P: (f64, f64) = (40.7884, -111.9778);

    #[test]
    fn an_end_on_airfield_service_roads_moves_to_the_public_road() {
        // SLC's terminal: the nearest edges are airport service roads 55 m away, Terminal Drive (primary) is 580 m.
        let v = roads(vec![edge(40.78836, -111.97845, 55.0, "service_other", "service_road")], vec![edge(40.78400, -111.98147, 580.0, "primary", "road")]);
        let plan = plan_end(&v, P, "auto", true);
        assert!(plan.public_road);
        assert_eq!(plan.ends.len(), 1);
        assert_eq!(plan.ends[0].opts.min_road_class.as_deref(), Some("residential"));
        assert_eq!(plan.ends[0].point(), P, "the end stays the point asked for; Valhalla snaps it under the filter");
    }

    #[test]
    fn an_arrival_point_from_the_places_data_keeps_its_own_road() {
        // A terminal's curb on a service-class frontage road: that is where people go.
        let v = roads(vec![edge(40.7841, -111.9850, 12.0, "service_other", "service_road")], vec![edge(40.7840, -111.9815, 300.0, "primary", "road")]);
        let plan = plan_end(&v, P, "auto", false);
        assert!(!plan.public_road);
        assert_eq!(plan.ends, vec![RouteEnd::at(P)]);
    }

    #[test]
    fn a_public_road_too_far_away_leaves_the_service_road() {
        let v = roads(vec![edge(40.7, -111.9, 20.0, "service_other", "service_road")], vec![edge(40.71, -111.9, 900.0, "secondary", "road")]);
        let plan = plan_end(&v, P, "auto", true);
        assert!(!plan.public_road);
        assert_eq!(plan.ends, vec![RouteEnd::at(P)]);
    }

    #[test]
    fn parking_aisles_driveways_and_walking_are_left_alone() {
        let v = roads(vec![edge(40.7, -111.9, 13.0, "service_other", "parking_aisle")], vec![edge(40.71, -111.9, 25.0, "primary", "road")]);
        let plan = plan_end(&v, P, "auto", true);
        assert!(!plan.public_road && plan.ends[0].opts == EndOptions::default());
        let v = roads(vec![edge(40.7, -111.9, 55.0, "service_other", "service_road")], vec![edge(40.71, -111.9, 80.0, "primary", "road")]);
        assert_eq!(plan_end(&v, P, "pedestrian", true), EndPlan::plain(P));
        assert_eq!(plan_end(&v, P, "bicycle", true), EndPlan::plain(P));
        // No answer from the router: Valhalla's own snapping.
        assert_eq!(plan_end(&roads(vec![], vec![]), P, "auto", true), EndPlan::plain(P));
    }

    #[test]
    fn the_other_carriageway_is_routed_too_and_the_faster_route_kept() {
        // A street's two one-way carriageways, 109 m and 124 m away; a cross street at 115 m is another road, and the same
        // street at 160 m is too far to count.
        let near = named(edge(40.769417, -111.891896, 109.0, "tertiary", "road"), "South Temple");
        let cross = named(edge(40.769500, -111.891500, 115.0, "tertiary", "road"), "State Street");
        let other = named(edge(40.769280, -111.891900, 124.0, "tertiary", "road"), "South Temple");
        let far = named(edge(40.7690, -111.8930, 160.0, "tertiary", "road"), "South Temple");
        let mut v = roads(vec![near.clone(), cross, other.clone(), far], vec![]);
        v.times = vec![(other.lat, 60.0)];
        let from = plan_end(&v, P, "auto", true);
        assert_eq!(from.ends.len(), 2);
        assert_eq!(from.ends[1].point(), (other.lat, other.lon));
        let to = EndPlan::plain((40.76, -111.85));
        let (trip, f, t) = route_planned(&v, &from, &to, "auto").unwrap();
        assert_eq!(trip.time_s, 60.0, "the faster start wins");
        assert_eq!(f.ends, vec![from.ends[1].clone()]);
        assert_eq!(t.ends, to.ends);
        assert_eq!(v.calls.lock().unwrap().len(), 2, "two route calls in the ambiguous case");
    }

    #[test]
    fn one_road_in_both_directions_is_one_route_call() {
        // A two-way street: two edges (one per direction) at the same point.
        let v = roads(vec![edge(40.7, -111.9, 16.0, "residential", "road"), edge(40.7, -111.9, 16.0, "residential", "road")], vec![]);
        let from = plan_end(&v, P, "auto", true);
        assert_eq!(from.ends.len(), 1);
        route_planned(&v, &from, &EndPlan::plain((40.8, -111.9)), "auto").unwrap();
        assert_eq!(v.calls.lock().unwrap().len(), 1);
    }

    /// A router whose filtered route fails: the plain points are routed instead.
    struct NoFiltered(Roads);
    impl Valhalla for NoFiltered {
        fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
            None
        }
        fn route(&self, _: (f64, f64), _: (f64, f64), _: &str) -> Result<Trip, ValhallaError> {
            unreachable!()
        }
        fn candidates(&self, la: f64, lo: f64, c: &str, o: &EndOptions) -> Vec<EdgeCandidate> {
            self.0.candidates(la, lo, c, o)
        }
        fn route_ends(&self, f: &RouteEnd, t: &RouteEnd, c: &str) -> Result<Trip, ValhallaError> {
            if f.opts.min_road_class.is_some() {
                return Err(ValhallaError { code: Some(442), message: "No path could be found for input".into(), timeout: false });
            }
            self.0.route_ends(f, t, c)
        }
        fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
            Err(ValhallaError::msg("n/a"))
        }
    }

    #[test]
    fn a_filtered_end_that_finds_no_route_falls_back_to_valhallas_snapping() {
        let v = NoFiltered(roads(vec![edge(40.78836, -111.97845, 55.0, "service_other", "service_road")], vec![edge(40.784, -111.981, 580.0, "primary", "road")]));
        let from = plan_end(&v, P, "auto", true);
        assert!(from.public_road);
        let (_, f, _) = route_planned(&v, &from, &EndPlan::plain((40.76, -111.90)), "auto").unwrap();
        assert_eq!(f, EndPlan::plain(P), "the plain end, and the gap is an ordinary snap again");
    }
}
