//! A route made without elevation data that was missing (not on the phone, not streamed) says so (`data_gap`); one made
//! from data that was there, or around ground that is really impassable, does not.
use cache_offroad::directions::*;
use cache_offroad::elevation::ElevError;
use cache_offroad::pack::{Layer, MemPack, MvumFeature, PResult, PackError, PackSource, PointRec};
use cache_offroad::valhalla::*;
use cache_offroad::{ElevationSource, TravelMode};

const FROM: (f64, f64) = (42.5558, -114.4701);
const TO: (f64, f64) = (42.565, -114.46);

struct NoRoads;
impl Valhalla for NoRoads {
    fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
        None
    }
    fn route(&self, _: (f64, f64), _: (f64, f64), _: &str) -> Result<Trip, ValhallaError> {
        Err(ValhallaError::msg("no roads here"))
    }
    fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("none"))
    }
}

fn world() -> (MemPack, (i64, i64)) {
    let mid = cache_offroad::grid::global_pixel((FROM.0 + TO.0) / 2.0, (FROM.1 + TO.1) / 2.0).unwrap();
    let mut p = MemPack::blank(600, 600, 1300.0);
    p.row0 = mid.0 - 300;
    p.col0 = mid.1 - 300;
    (p, mid)
}

/// The pack's elevation with a square of NaN around the route's middle. `missing` says whether those cells are NaN because the
/// data could not be had (reported as an unavailable tile) or because the ground is not passable (sea, a lake: no tile here).
struct Hole<'a> {
    pack: &'a MemPack,
    mid: (i64, i64),
    missing: bool,
}
impl Hole<'_> {
    fn rect(&self) -> (i64, i64, i64, i64) {
        (self.mid.0 - 30, self.mid.1 - 30, self.mid.0 + 30, self.mid.1 + 30)
    }
}
impl ElevationSource for Hole<'_> {
    fn read_elevation(&self, row0: i64, col0: i64, rows: usize, cols: usize) -> Result<Vec<f32>, ElevError> {
        let mut v = self.pack.read_elevation(row0, col0, rows, cols)?;
        let (r0, c0, r1, c1) = self.rect();
        for r in 0..rows {
            for c in 0..cols {
                let (gr, gc) = (row0 + r as i64, col0 + c as i64);
                if gr >= r0 && gr < r1 && gc >= c0 && gc < c1 {
                    v[r * cols + c] = f32::NAN;
                }
            }
        }
        Ok(v)
    }
    fn unavailable_rects(&self, _: i64, _: i64, _: usize, _: usize) -> Vec<(i64, i64, i64, i64)> {
        if self.missing {
            vec![self.rect()]
        } else {
            vec![]
        }
    }
}

fn route(elev: &dyn ElevationSource, pack: &MemPack) -> Directions {
    let v = NoRoads;
    let env = Env { pack, elevation: elev, valhalla: &v, options: Default::default(), namer: None, version: "t".into() };
    env.directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFoot))
}

#[test]
fn a_route_made_around_missing_elevation_data_says_so() {
    let (w, mid) = world();
    let d = route(&Hole { pack: &w, mid, missing: true }, &w);
    assert!(d.ok, "the route still comes back: {:?}", d.errors);
    assert!(d.data_gap);
}

#[test]
fn a_route_made_from_all_its_data_says_nothing() {
    let (w, _) = world();
    let d = route(&w, &w);
    assert!(d.ok && !d.data_gap);
}

#[test]
fn a_route_around_ground_that_is_really_impassable_says_nothing() {
    let (w, mid) = world();
    let d = route(&Hole { pack: &w, mid, missing: false }, &w);
    assert!(d.ok, "{:?}", d.errors);
    assert!(!d.data_gap, "NaN from real terrain is not missing data");
}

/// The pack, except that its access-rules (MVUM) query fails.
struct BrokenRules<'a>(&'a MemPack);
impl PackSource for BrokenRules<'_> {
    fn has_layer(&self, l: Layer) -> bool {
        self.0.has_layer(l)
    }
    fn read_u8(&self, l: Layer, r: i64, c: i64, rows: usize, cols: usize) -> PResult<Vec<u8>> {
        self.0.read_u8(l, r, c, rows, cols)
    }
    fn parking_in_box(&self, a: f64, b: f64, c: f64, d: f64) -> PResult<Vec<PointRec>> {
        self.0.parking_in_box(a, b, c, d)
    }
    fn trailheads_in_box(&self, a: f64, b: f64, c: f64, d: f64) -> PResult<Vec<PointRec>> {
        self.0.trailheads_in_box(a, b, c, d)
    }
    fn mvum_in_box(&self, _: f64, _: f64, _: f64, _: f64) -> PResult<Vec<MvumFeature>> {
        Err(PackError::Msg("no such table: mvum".into()))
    }
    fn covers(&self, a: f64, b: f64) -> bool {
        self.0.covers(a, b)
    }
}

#[test]
fn a_failed_access_rules_query_is_missing_data_not_no_restrictions() {
    let (w, _) = world();
    let v = NoRoads;
    let broken = BrokenRules(&w);
    let env = Env { pack: &broken, elevation: &w, valhalla: &v, options: Default::default(), namer: None, version: "t".into() };
    let d = env.directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFoot));
    assert!(d.ok, "the route still comes back: {:?}", d.errors);
    assert!(d.data_gap);
    // the same pack with its rules query working (none in the box): nothing missing
    let d = route(&w, &w);
    assert!(d.ok && !d.data_gap);
}

/// The pack, plus pack tiles it says are missing (neither stored nor listed as processed).
struct MissingPackTiles<'a>(&'a MemPack, (i64, i64, i64, i64));
impl PackSource for MissingPackTiles<'_> {
    fn has_layer(&self, l: Layer) -> bool {
        self.0.has_layer(l)
    }
    fn read_u8(&self, l: Layer, r: i64, c: i64, rows: usize, cols: usize) -> PResult<Vec<u8>> {
        self.0.read_u8(l, r, c, rows, cols)
    }
    fn parking_in_box(&self, a: f64, b: f64, c: f64, d: f64) -> PResult<Vec<PointRec>> {
        self.0.parking_in_box(a, b, c, d)
    }
    fn trailheads_in_box(&self, a: f64, b: f64, c: f64, d: f64) -> PResult<Vec<PointRec>> {
        self.0.trailheads_in_box(a, b, c, d)
    }
    fn mvum_in_box(&self, a: f64, b: f64, c: f64, d: f64) -> PResult<Vec<MvumFeature>> {
        self.0.mvum_in_box(a, b, c, d)
    }
    fn covers(&self, a: f64, b: f64) -> bool {
        self.0.covers(a, b)
    }
    fn missing_rects(&self, _: i64, _: i64, _: usize, _: usize) -> Vec<(i64, i64, i64, i64)> {
        vec![self.1]
    }
}

#[test]
fn a_pack_tile_the_pack_says_is_missing_in_the_corridor_is_missing_data() {
    let (w, mid) = world();
    let v = NoRoads;
    let rect = (mid.0 - 30, mid.1 - 30, mid.0 + 30, mid.1 + 30);
    let p = MissingPackTiles(&w, rect);
    let env = Env { pack: &p, elevation: &w, valhalla: &v, options: Default::default(), namer: None, version: "t".into() };
    let d = env.directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFoot));
    assert!(d.ok, "{:?}", d.errors);
    assert!(d.data_gap);
}
