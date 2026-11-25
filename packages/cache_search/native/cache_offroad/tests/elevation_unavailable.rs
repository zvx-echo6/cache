//! An elevation tile the router cannot have must not become impassable NaN cells (a silent detour): the end the off-road
//! leg was for is reported as off-road data not downloaded (`covered` false), and an off-road-only trip fails as not set up.
use cache_offroad::directions::*;
use cache_offroad::elevation::ElevError;
use cache_offroad::pack::MemPack;
use cache_offroad::valhalla::*;
use cache_offroad::{ElevationSource, TravelMode};

const FROM: (f64, f64) = (42.5558, -114.4701);
/// The destination, 1.5 km east of where the road ends.
const TO: (f64, f64) = (42.5558, -114.4350);
const ROAD_END: (f64, f64) = (42.5558, -114.4525);

struct Road;
impl Valhalla for Road {
    fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
        None
    }
    fn route(&self, _: (f64, f64), _: (f64, f64), _: &str) -> Result<Trip, ValhallaError> {
        let shape = vec![FROM, ROAD_END];
        let m = Maneuver { kind: 1, instruction: "Drive.".into(), length_km: 1.5, time_s: 90.0, end_shape_index: 1, ..Default::default() };
        Ok(Trip { shape_encoded: encode_polyline6(&shape), shape, maneuvers: vec![m], length_km: 1.5, time_s: 90.0 })
    }
    fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("none"))
    }
}

fn world() -> MemPack {
    let (gr, gc) = cache_offroad::grid::global_pixel((FROM.0 + TO.0) / 2.0, (FROM.1 + TO.1) / 2.0).unwrap();
    let mut p = MemPack::blank(600, 600, 1300.0);
    p.row0 = gr - 300;
    p.col0 = gc - 300;
    p
}

/// The pack's elevation, except that one tile of it could not be had.
struct MissingTile;
impl ElevationSource for MissingTile {
    fn read_elevation(&self, _: i64, _: i64, _: usize, _: usize) -> Result<Vec<f32>, ElevError> {
        Err(ElevError::Unavailable)
    }
}

fn env<'a>(pack: &'a MemPack, elev: &'a dyn ElevationSource, v: &'a Road) -> Env<'a> {
    Env { pack, elevation: elev, valhalla: v, options: Default::default(), namer: None, version: "t".into() }
}

#[test]
fn a_missing_elevation_tile_reports_the_end_as_not_downloaded_not_as_no_way_found() {
    let (w, v) = (world(), Road);
    // with the data: the off-road tail is built, no warning
    let d = env(&w, &w, &v).directions(&DirectionsRequest::new(FROM, TO, TravelMode::Drive));
    assert!(d.ok && d.warnings.is_empty(), "{:?} {:?}", d.errors, d.warnings);
    // a tile missing: the road route stands, the end gets a warning, and it is the not-downloaded one
    let gone = MissingTile;
    let d = env(&w, &gone, &v).directions(&DirectionsRequest::new(FROM, TO, TravelMode::Drive));
    assert!(d.ok, "{:?}", d.errors);
    assert_eq!(d.warnings.len(), 1, "{:?}", d.warnings);
    assert_eq!(d.warnings[0].end, "to");
    assert!(!d.warnings[0].covered, "a tile that could not be had is not 'covered but no way found'");
}

#[test]
fn an_off_road_only_trip_with_a_missing_tile_fails_as_off_road_data_not_set_up() {
    let (w, v) = (world(), Road);
    let gone = MissingTile;
    let d = env(&w, &gone, &v).directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFoot));
    assert!(!d.ok);
    assert_eq!((d.errors[0].code.as_str(), d.errors[0].message.as_str()), ("not_set_up", OFFROAD_DATA_MISSING));
}
