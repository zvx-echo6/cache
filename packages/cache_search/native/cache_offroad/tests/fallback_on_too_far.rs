//! The off-road fallback keys on the router's `too_far` code (154 and, inside the maps' area, 170 and 171): with Auto it is
//! tried instead of giving up; with Never the route fails as `too_far`. Pinned so a change to how failures are reported to the
//! app cannot silently turn the fallback off.
use cache_offroad::navigate::{NavigateRequest, Navigator, OffroadChoice, Waypoint};
use cache_offroad::pack::MemPack;
use cache_offroad::router::Boundary;
use cache_offroad::valhalla::*;
use cache_offroad::TravelMode;

struct Fails(i64);
impl Valhalla for Fails {
    fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
        None
    }
    fn route(&self, _: (f64, f64), _: (f64, f64), _: &str) -> Result<Trip, ValhallaError> {
        Err(ValhallaError { code: Some(self.0), message: "No path could be found for input".into(), timeout: false })
    }
    fn route_ends(&self, _: &RouteEnd, _: &RouteEnd, _: &str) -> Result<Trip, ValhallaError> {
        Err(ValhallaError { code: Some(self.0), message: "No path could be found for input".into(), timeout: false })
    }
    fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("none"))
    }
}

fn outcome(code: i64, choice: OffroadChoice) -> (bool, Vec<String>) {
    let (pack, elev) = (MemPack::blank(1, 1, 0.0), MemPack::blank(1, 1, 0.0));
    let v = Fails(code);
    let nav = Navigator::new(&pack, &elev, &v);
    // both ends in Idaho, inside the maps' area
    let mut req = NavigateRequest::new(Waypoint::point(42.5, -113.8), Waypoint::point(44.0, -115.0), TravelMode::Drive, Boundary::Pragmatic);
    req.offroad = choice;
    let d = nav.navigate(&req).unwrap();
    (d.ok, d.errors.iter().map(|e| e.code.clone()).collect())
}

#[test]
fn never_fails_as_too_far_and_auto_tries_the_off_road_fallback_instead() {
    for code in [154, 170, 171] {
        let (ok, errs) = outcome(code, OffroadChoice::Never);
        assert!(!ok);
        assert_eq!(errs, ["too_far"], "{code} with Never");
        let (ok, errs) = outcome(code, OffroadChoice::Auto);
        assert!(ok || errs != ["too_far"], "{code} with Auto: the fallback must have been tried, got {errs:?}");
    }
    // a code that is not too_far-class does not trigger it
    let (_, errs) = outcome(442, OffroadChoice::Auto);
    assert_eq!(errs, ["no_route"]);
}
