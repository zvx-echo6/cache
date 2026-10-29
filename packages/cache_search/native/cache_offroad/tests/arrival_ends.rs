//! Route ends through `Navigator`: a place's arrival point (a hospital's emergency entrance on its service drive) is routed
//! to as it is, never moved to the public road; a bare point on a service road is (`snap`).
use cache_offroad::navigate::{NavigateRequest, Navigator, Waypoint};
use cache_offroad::pack::MemPack;
use cache_offroad::router::Boundary;
use cache_offroad::valhalla::*;
use cache_offroad::TravelMode;
use std::sync::Mutex;

/// Every point's nearest edge is a hospital's service drive; a public road is 250 m away. Records the route calls' ends.
struct Drive(Mutex<Vec<(RouteEnd, RouteEnd)>>);
impl Valhalla for Drive {
    fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
        None
    }
    fn route(&self, _: (f64, f64), _: (f64, f64), _: &str) -> Result<Trip, ValhallaError> {
        unreachable!("drive ends go through route_ends")
    }
    fn candidates(&self, lat: f64, lon: f64, _: &str, o: &EndOptions) -> Vec<EdgeCandidate> {
        let (d, cls, use_) = if o.min_road_class.is_some() { (250.0, "secondary", "road") } else { (15.0, "service_other", "service_road") };
        vec![EdgeCandidate { lat, lon: lon + 0.0001, distance_m: d, road_class: Some(cls.into()), use_: Some(use_.into()) }]
    }
    fn route_ends(&self, f: &RouteEnd, t: &RouteEnd, _: &str) -> Result<Trip, ValhallaError> {
        self.0.lock().unwrap().push((f.clone(), t.clone()));
        let shape = vec![f.point(), t.point()];
        let m = Maneuver { kind: 1, instruction: "Drive.".into(), length_km: 1.0, time_s: 60.0, end_shape_index: 1, ..Default::default() };
        Ok(Trip { shape_encoded: encode_polyline6(&shape), shape, maneuvers: vec![m], length_km: 1.0, time_s: 60.0 })
    }
    fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("none"))
    }
}

#[test]
fn an_arrival_point_is_routed_to_as_it_is_and_a_bare_point_moves_to_the_public_road() {
    let v = Drive(Mutex::new(vec![]));
    let (pack, elev) = (MemPack::blank(1, 1, 0.0), MemPack::blank(1, 1, 0.0));
    let nav = Navigator::new(&pack, &elev, &v);
    let er_door = (40.7712, -111.8395);
    let hospital = Waypoint::place("University Hospital", 40.7703, -111.8411).with_arrival(Some(er_door));
    let from = Waypoint::point(40.7608, -111.8910);
    let mut req = NavigateRequest::new(from, hospital, TravelMode::Drive, Boundary::Pragmatic);
    req.offroad = cache_offroad::navigate::OffroadChoice::Never;
    let d = nav.navigate(&req).unwrap();
    assert!(d.ok);
    let calls = v.0.lock().unwrap().clone();
    assert_eq!(calls.len(), 1);
    let (f, t) = &calls[0];
    assert_eq!(t.point(), er_door, "the route ends at the emergency entrance");
    assert_eq!(t.opts, EndOptions::default(), "and is not moved to the public road");
    assert_eq!(f.opts.min_road_class.as_deref(), Some("residential"), "a bare point on a service road is");
    assert_eq!((d.to.as_ref().unwrap().lat, d.to.as_ref().unwrap().lon), er_door);
}
