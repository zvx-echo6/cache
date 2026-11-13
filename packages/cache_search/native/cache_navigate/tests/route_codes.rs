//! The error codes the app gets from a failed route (`cs_map_route`), which are not the codes the model reads (those are in
//! tool.rs, golden): 154 stays `too_far`; 170, 171 and 442 are never `too_far`; a stop with no road tile after the fetch is
//! `no_road_data` with the end; data present is `no_route`.

use cache_navigate::map::{app_error, route, MapEnd, MapRouteReq};
use cache_navigate::{FetchState, NavCore, NavigateCfg, PlaceSlot, TilePrep, TileStream};
use cache_offroad::directions::{DirectionsError, TravelMode};
use cache_offroad::router::Boundary;
use cache_offroad::valhalla::{Trace, Trip, Valhalla, ValhallaError};
use std::sync::Arc;

/// A router that fails every route with a code.
struct Fails(i64);
impl Valhalla for Fails {
    fn locate(&self, _: f64, _: f64, _: &str) -> Option<cache_offroad::valhalla::LocateSnap> {
        None
    }
    fn route(&self, _: (f64, f64), _: (f64, f64), _: &str) -> Result<Trip, ValhallaError> {
        Err(ValhallaError { code: Some(self.0), message: "No path could be found for input".into(), timeout: false })
    }
    fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("not used"))
    }
}

/// A tile stream that says what it came to.
struct Prep(TilePrep);
impl TileStream for Prep {
    fn prepare(&self, _: &[(f64, f64)]) -> TilePrep {
        self.0.clone()
    }
}

fn end(name: &str, lat: f64, lon: f64) -> MapEnd {
    MapEnd { id: None, name: Some(name.into()), lat, lon, osm_category: None, arrival: None }
}

fn req(via: Vec<MapEnd>) -> MapRouteReq {
    MapRouteReq { from: end("A", 42.5, -113.8), via, to: end("B", 42.5, -113.5), mode: TravelMode::Drive, land_access: Boundary::Pragmatic, alternatives: 0 }
}

/// The first error of the route the app is told about: (code, end).
fn told(code: i64, prep: TilePrep, via: Vec<MapEnd>) -> (String, Option<String>) {
    let c = NavCore::with_valhalla(NavigateCfg::default(), PlaceSlot::default(), Arc::new(Fails(code)));
    let s: Arc<dyn TileStream> = Arc::new(Prep(prep));
    c.set_stream(Some(s));
    let (out, active) = route(&c, &req(via)).unwrap();
    assert_eq!(out["ok"], false);
    assert!(active.is_empty());
    let e = &out["errors"][0];
    (e["code"].as_str().unwrap().into(), e["end"].as_str().map(String::from))
}

fn prep(state: FetchState, lacking: &[usize]) -> TilePrep {
    TilePrep { state, missing: 0, index_known: true, lacking: lacking.to_vec() }
}

fn prep_missing(state: FetchState, missing: usize, lacking: &[usize]) -> TilePrep {
    TilePrep { state, missing, index_known: true, lacking: lacking.to_vec() }
}

fn err(code: &str, vcode: i64) -> DirectionsError {
    DirectionsError { code: code.into(), message: "m".into(), valhalla_code: Some(vcode) }
}

#[test]
fn a_path_over_the_distance_limit_is_still_too_far() {
    assert_eq!(told(154, prep(FetchState::Done, &[]), vec![]).0, "too_far");
    // even with a stop short of tiles: the router answered about the distance
    assert_eq!(told(154, prep(FetchState::Offline, &[0]), vec![]).0, "too_far");
}

#[test]
fn with_the_data_present_170_171_and_442_are_no_route_never_too_far() {
    for code in [170, 171, 442, 443] {
        assert_eq!(told(code, prep(FetchState::Done, &[]), vec![]), ("no_route".into(), None), "{code}");
    }
}

#[test]
fn a_stop_without_road_tiles_after_the_fetch_is_no_road_data_with_its_end() {
    for state in [FetchState::Offline, FetchState::Failed, FetchState::TimedOut] {
        for code in [170, 171, 442] {
            assert_eq!(told(code, prep(state, &[0]), vec![]), ("no_road_data".into(), Some("from".into())), "{state:?} {code}");
            assert_eq!(told(code, prep(state, &[1]), vec![]), ("no_road_data".into(), Some("to".into())), "{state:?} {code}");
        }
    }
    // with a stop between: stops are start 0, via 1, end 2; the failing leg is the first, so a lack at the end of leg one is the via
    let via = || vec![end("V", 42.6, -113.6)];
    assert_eq!(told(171, prep(FetchState::Done, &[1]), via()), ("no_road_data".into(), Some("via".into())));
    // a lack beyond the failing leg is not what failed it
    assert_eq!(told(171, prep(FetchState::Done, &[2]), via()), ("no_route".into(), None));
    // the start is named first when both ends lack
    assert_eq!(told(170, prep(FetchState::Offline, &[0, 1]), vec![]), ("no_road_data".into(), Some("from".into())));
}

#[test]
fn app_error_by_stop_position() {
    // the end of a three-stop trip is stop 2: a leg (1, 2) lacking at 2 is "to"
    assert_eq!(app_error(&err("too_far", 170), &prep(FetchState::Failed, &[2]), (1, 2), 2), ("no_road_data".into(), Some("to")));
    assert_eq!(app_error(&err("too_far", 171), &prep(FetchState::Failed, &[1]), (1, 2), 2), ("no_road_data".into(), Some("via")));
    assert_eq!(app_error(&err("too_far", 171), &prep(FetchState::Done, &[]), (1, 2), 2), ("no_route".into(), None));
    // outside the maps' area with the data present, the router's own answer stands
    assert_eq!(app_error(&err("out_of_coverage", 170), &prep(FetchState::Done, &[]), (0, 1), 1), ("out_of_coverage".into(), None));
    // codes this layer does not re-read pass through
    let timeout = DirectionsError { code: "upstream_timeout".into(), message: "m".into(), valhalla_code: None };
    assert_eq!(app_error(&timeout, &prep(FetchState::Done, &[0]), (0, 1), 1), ("upstream_timeout".into(), None));
}

#[test]
fn outside_the_maps_area_is_out_of_coverage_whatever_is_lacking() {
    // a stop outside coverage never has a tile: connecting does not fix it
    let e = err("out_of_coverage", 171);
    for lacking in [vec![], vec![0], vec![1], vec![0, 1]] {
        for state in [FetchState::Done, FetchState::Offline, FetchState::Failed] {
            assert_eq!(app_error(&e, &prep_missing(state, 3, &lacking), (0, 1), 1), ("out_of_coverage".into(), None), "{state:?} {lacking:?}");
        }
    }
}

#[test]
fn tiles_missing_between_the_ends_is_no_road_data_without_an_end() {
    // both ends present, tiles between them absent (offline, or a fetch that ran out of time)
    for state in [FetchState::Offline, FetchState::TimedOut, FetchState::Failed] {
        for code in [170, 171, 442, 443] {
            assert_eq!(app_error(&err("no_route", code), &prep_missing(state, 4, &[]), (0, 1), 1), ("no_road_data".into(), None), "{state:?} {code}");
        }
    }
    // through the route call, from a stream
    assert_eq!(told(442, prep_missing(FetchState::Offline, 2, &[]), vec![]), ("no_road_data".into(), None));
    // a lacking stop is still named first; nothing missing is no_route; 154 stays too_far
    assert_eq!(told(442, prep_missing(FetchState::Offline, 2, &[1]), vec![]), ("no_road_data".into(), Some("to".into())));
    assert_eq!(told(442, prep_missing(FetchState::Done, 0, &[]), vec![]), ("no_route".into(), None));
    assert_eq!(told(154, prep_missing(FetchState::Offline, 2, &[]), vec![]).0, "too_far");
}

#[test]
fn a_fetch_that_did_not_finish_with_no_index_known_is_no_road_data() {
    let unknown = |state| TilePrep { state, missing: 0, index_known: false, lacking: vec![] };
    for state in [FetchState::Offline, FetchState::Failed, FetchState::TimedOut] {
        for code in [170, 171, 442, 443] {
            assert_eq!(app_error(&err("no_route", code), &unknown(state), (0, 1), 1), ("no_road_data".into(), None), "{state:?} {code}");
        }
        // with the index known and nothing missing, it is no_route; out_of_coverage and 154 are as they were
        let known = TilePrep { index_known: true, ..unknown(state) };
        assert_eq!(app_error(&err("no_route", 442), &known, (0, 1), 1), ("no_route".into(), None), "{state:?}");
        assert_eq!(app_error(&err("out_of_coverage", 170), &unknown(state), (0, 1), 1), ("out_of_coverage".into(), None));
        assert_eq!(app_error(&err("too_far", 154), &unknown(state), (0, 1), 1), ("too_far".into(), None));
    }
    // fetch Done: no_route, as before
    assert_eq!(app_error(&err("no_route", 442), &unknown(FetchState::Done), (0, 1), 1), ("no_route".into(), None));
}

#[test]
fn a_crashing_fetch_does_not_fail_the_route() {
    struct Crash;
    impl TileStream for Crash {
        fn prepare(&self, _: &[(f64, f64)]) -> TilePrep {
            panic!("the fetch crashed");
        }
    }
    let c = NavCore::with_valhalla(NavigateCfg::default(), PlaceSlot::default(), Arc::new(Fails(442)));
    let s: Arc<dyn TileStream> = Arc::new(Crash);
    c.set_stream(Some(s));
    let p = c.prepare_tiles(&[(42.5, -113.8)]);
    assert_eq!(p.state, FetchState::Failed);
    // the route still runs; nothing is known about the tiles, so the failure is told as missing road data
    let (out, _) = route(&c, &req(vec![])).unwrap();
    assert_eq!(out["ok"], false);
    assert_eq!(out["errors"][0]["code"], "no_road_data");
}
