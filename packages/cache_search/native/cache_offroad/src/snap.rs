//! Where a drive starts and ends on the road network, the way Apple Maps picks it (project decision, 2026-10-29: "match what
//! Apple Maps does"). Valhalla on its own snaps each end to the nearest edge of any class, which puts a trip from an airport
//! terminal on the airfield's service roads.
//!
//! When the nearest edge is a generic service road (airport, campus and private access roads), the end goes to the nearest
//! public road (residential or better) within [`PUBLIC_ROAD_M`]. That gap is how people get to the car, not an off-road leg:
//! directions add no off-road leg and no `offroad_unavailable` warning for it. A place's arrival point from the places data
//! (a terminal, an emergency entrance, a main door, a parking) is never moved: it is already where people go.
//!
//! Only driving does this; walking and cycling keep Valhalla's own snapping (service roads and paths are where people walk).
use crate::valhalla::{EdgeCandidate, EndOptions, RouteEnd, Trip, Valhalla, ValhallaError};

/// How far an end may move past service roads to reach a public road.
pub const PUBLIC_ROAD_M: f64 = 600.0;
/// The road class a public road has at least (Valhalla's classes: motorway ... residential, then service_other).
pub const PUBLIC_MIN_CLASS: &str = "residential";

/// How one end of a drive snaps.
#[derive(Debug, Clone, PartialEq)]
pub struct EndPlan {
    /// The end to route from or to.
    pub end: RouteEnd,
    /// The end moved past service roads to a public road: the gap is not an off-road leg.
    pub public_road: bool,
}

impl EndPlan {
    fn plain(p: (f64, f64)) -> EndPlan {
        EndPlan { end: RouteEnd::at(p), public_road: false }
    }
}

/// A generic service road: what airfields, campuses and private access roads are mapped as. Parking aisles, driveways,
/// alleys and drive-throughs are left alone: they are where a trip to a shop or a house really ends.
fn service_road(c: &EdgeCandidate) -> bool {
    c.road_class.as_deref() == Some("service_other") && c.use_.as_deref() == Some("service_road")
}

/// The snapping of the end at `p` for `costing`. `to_public` false keeps the end on its nearest road even when that is a
/// service road (a place's arrival point from the places data).
pub fn plan_end(v: &dyn Valhalla, p: (f64, f64), costing: &str, to_public: bool) -> EndPlan {
    if costing != "auto" || !to_public {
        return EndPlan::plain(p);
    }
    let near = v.candidates(p.0, p.1, costing, &EndOptions::default());
    let Some(first) = near.first() else { return EndPlan::plain(p) };
    if service_road(first) {
        let public = EndOptions { min_road_class: Some(PUBLIC_MIN_CLASS.into()), radius_m: None };
        if v.candidates(p.0, p.1, costing, &public).first().is_some_and(|c| c.distance_m <= PUBLIC_ROAD_M) {
            return EndPlan { end: RouteEnd { lat: p.0, lon: p.1, opts: public }, public_road: true };
        }
    }
    EndPlan::plain(p)
}

/// The road route between two planned ends. Falls back to Valhalla's own snapping when the planned ends find no route.
pub fn route_planned(v: &dyn Valhalla, from: &EndPlan, to: &EndPlan, costing: &str) -> Result<(Trip, EndPlan, EndPlan), ValhallaError> {
    match v.route_ends(&from.end, &to.end, costing) {
        Ok(trip) => Ok((trip, from.clone(), to.clone())),
        Err(e) => {
            if !(from.public_road || to.public_road) {
                return Err(e);
            }
            let (pf, pt) = (EndPlan::plain(from.end.point()), EndPlan::plain(to.end.point()));
            let trip = v.route_ends(&pf.end, &pt.end, costing).map_err(|_| e)?;
            Ok((trip, pf, pt))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::valhalla::{encode_polyline6, Maneuver, LocateSnap, Trace};
    use std::sync::Mutex;

    /// Roads as candidate lists: what `candidates` answers, without and with the public-road filter.
    struct Roads {
        plain: Vec<EdgeCandidate>,
        public: Vec<EdgeCandidate>,
        calls: Mutex<Vec<(RouteEnd, RouteEnd)>>,
    }
    fn edge(lat: f64, lon: f64, d: f64, cls: &str, use_: &str) -> EdgeCandidate {
        EdgeCandidate { lat, lon, distance_m: d, road_class: Some(cls.into()), use_: Some(use_.into()) }
    }
    impl Valhalla for Roads {
        fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
            None
        }
        fn route(&self, _: (f64, f64), _: (f64, f64), _: &str) -> Result<Trip, ValhallaError> {
            unreachable!("route_ends is used")
        }
        fn candidates(&self, _: f64, _: f64, _: &str, o: &EndOptions) -> Vec<EdgeCandidate> {
            if o.min_road_class.is_some() { self.public.clone() } else { self.plain.clone() }
        }
        fn route_ends(&self, f: &RouteEnd, t: &RouteEnd, _: &str) -> Result<Trip, ValhallaError> {
            self.calls.lock().unwrap().push((f.clone(), t.clone()));
            let time = 100.0;
            let shape = vec![f.point(), t.point()];
            Ok(Trip { shape_encoded: encode_polyline6(&shape), shape, maneuvers: vec![Maneuver::default()], length_km: 1.0, time_s: time })
        }
        fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
            Err(ValhallaError::msg("n/a"))
        }
    }
    fn roads(plain: Vec<EdgeCandidate>, public: Vec<EdgeCandidate>) -> Roads {
        Roads { plain, public, calls: Mutex::new(vec![]) }
    }
    const P: (f64, f64) = (40.7884, -111.9778);

    #[test]
    fn an_end_on_airfield_service_roads_moves_to_the_public_road() {
        // SLC's terminal: the nearest edges are airport service roads 55 m away, Terminal Drive (primary) is 580 m.
        let v = roads(vec![edge(40.78836, -111.97845, 55.0, "service_other", "service_road")], vec![edge(40.78400, -111.98147, 580.0, "primary", "road")]);
        let plan = plan_end(&v, P, "auto", true);
        assert!(plan.public_road);
        assert_eq!(plan.end.opts.min_road_class.as_deref(), Some("residential"));
        assert_eq!(plan.end.point(), P, "the end stays the point asked for; Valhalla snaps it under the filter");
    }

    #[test]
    fn an_arrival_point_from_the_places_data_keeps_its_own_road() {
        // A terminal's curb on a service-class frontage road: that is where people go.
        let v = roads(vec![edge(40.7841, -111.9850, 12.0, "service_other", "service_road")], vec![edge(40.7840, -111.9815, 300.0, "primary", "road")]);
        let plan = plan_end(&v, P, "auto", false);
        assert_eq!(plan, EndPlan::plain(P));
        assert!(v.calls.lock().unwrap().is_empty());
    }

    #[test]
    fn a_public_road_too_far_away_leaves_the_service_road() {
        let v = roads(vec![edge(40.7, -111.9, 20.0, "service_other", "service_road")], vec![edge(40.71, -111.9, 900.0, "secondary", "road")]);
        let plan = plan_end(&v, P, "auto", true);
        assert_eq!(plan, EndPlan::plain(P));
    }

    #[test]
    fn parking_aisles_driveways_and_walking_are_left_alone() {
        let v = roads(vec![edge(40.7, -111.9, 13.0, "service_other", "parking_aisle")], vec![edge(40.71, -111.9, 25.0, "primary", "road")]);
        let plan = plan_end(&v, P, "auto", true);
        assert_eq!(plan, EndPlan::plain(P));
        let v = roads(vec![edge(40.7, -111.9, 55.0, "service_other", "service_road")], vec![edge(40.71, -111.9, 80.0, "primary", "road")]);
        assert_eq!(plan_end(&v, P, "pedestrian", true), EndPlan::plain(P));
        assert_eq!(plan_end(&v, P, "bicycle", true), EndPlan::plain(P));
        // No answer from the router: Valhalla's own snapping.
        assert_eq!(plan_end(&roads(vec![], vec![]), P, "auto", true), EndPlan::plain(P));
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
    fn one_route_call_per_trip() {
        let v = roads(vec![edge(40.78836, -111.97845, 55.0, "service_other", "service_road")], vec![edge(40.784, -111.981, 580.0, "primary", "road")]);
        let from = plan_end(&v, P, "auto", true);
        route_planned(&v, &from, &EndPlan::plain((40.76, -111.90)), "auto").unwrap();
        assert_eq!(v.calls.lock().unwrap().len(), 1);
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
