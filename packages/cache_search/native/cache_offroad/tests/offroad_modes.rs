//! The off-road travel modes of the directions (offroad_foot, offroad_vehicle): the whole trip goes through the off-road
//! router, never a road route first, and only where the off-road pack covers both ends. Land access other than pragmatic
//! is part of the route id.
use cache_offroad::cost::Mode;
use cache_offroad::directions::*;
use cache_offroad::pack::{Layer, MemPack, MvumFeature, PResult, PackSource, PointRec};
use cache_offroad::router::{Boundary, RequestMode, RouteOptions};
use cache_offroad::valhalla::*;
use std::sync::atomic::{AtomicUsize, Ordering};

const FROM: (f64, f64) = (42.5558, -114.4701);
const TO: (f64, f64) = (42.565, -114.46);

/// Finds no road route, and counts how often one was asked for.
struct Counting(AtomicUsize);
impl Valhalla for Counting {
    fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
        None
    }
    fn route(&self, _: (f64, f64), _: (f64, f64), _: &str) -> Result<Trip, ValhallaError> {
        self.0.fetch_add(1, Ordering::SeqCst);
        Err(ValhallaError::msg("no roads here"))
    }
    fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("none"))
    }
}

/// A flat open world around both ends, keyed at their global pixels.
fn flat_world() -> MemPack {
    let (gr, gc) = cache_offroad::grid::global_pixel((FROM.0 + TO.0) / 2.0, (FROM.1 + TO.1) / 2.0).unwrap();
    let mut p = MemPack::blank(600, 600, 1300.0);
    p.row0 = gr - 300;
    p.col0 = gc - 300;
    p
}

/// The same world, but the pack says it covers nowhere (no off-road data for the area).
struct Nowhere(MemPack);
impl PackSource for Nowhere {
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
    fn mvum_in_box(&self, s: f64, n: f64, w: f64, e: f64) -> PResult<Vec<MvumFeature>> {
        self.0.mvum_in_box(s, n, w, e)
    }
    fn covers(&self, _: f64, _: f64) -> bool {
        false
    }
}

fn env<'a>(pack: &'a dyn PackSource, elev: &'a MemPack, v: &'a Counting) -> Env<'a> {
    Env { pack, elevation: elev, valhalla: v, options: RouteOptions::default(), namer: None, version: "t".into() }
}

#[test]
fn mode_names_and_router_modes() {
    for (name, m) in [("offroad_foot", TravelMode::OffroadFoot), ("offroad_vehicle", TravelMode::OffroadVehicle)] {
        assert_eq!(TravelMode::from_name(name), Some(m));
        assert_eq!(m.name(), name);
        assert!(m.offroad_only());
    }
    assert_eq!(TravelMode::OffroadFoot.router_mode(), RequestMode::Single(Mode::Foot));
    assert_eq!(TravelMode::OffroadVehicle.router_mode(), RequestMode::Auto);
    assert_eq!((TravelMode::OffroadFoot.costing(), TravelMode::OffroadVehicle.costing()), ("pedestrian", "auto"));
    for m in [TravelMode::Drive, TravelMode::Walk, TravelMode::Bike] {
        assert!(!m.offroad_only());
    }
}

#[test]
fn offroad_modes_route_the_whole_trip_off_road() {
    let world = flat_world();
    let v = Counting(AtomicUsize::new(0));
    let e = env(&world, &world, &v);
    let foot = e.directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFoot));
    assert!(foot.ok, "{:?}", foot.errors);
    assert_eq!(foot.routing, "offroad");
    assert_eq!(foot.to_json()["mode"], "offroad_foot");
    assert!(foot.steps.iter().all(|s| s.kind.starts_with("offroad") && s.mode.as_deref() == Some("foot")), "{:?}", foot.steps);
    assert!(e.alternatives(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFoot), 2).is_empty());

    let vehicle = e.directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadVehicle));
    assert!(vehicle.ok, "{:?}", vehicle.errors);
    assert_eq!(vehicle.routing, "offroad");
    assert!(vehicle.steps.iter().all(|s| ["foot", "2w", "4w", "vehicle"].contains(&s.mode.as_deref().unwrap_or("vehicle"))));

    // drive asks the road router first (and fails here: no roads, not too far from them)
    let before = v.0.load(Ordering::SeqCst);
    let _ = e.directions(&DirectionsRequest::new(FROM, TO, TravelMode::Drive));
    assert!(v.0.load(Ordering::SeqCst) > before);
}

#[test]
fn offroad_modes_need_off_road_data_for_the_area() {
    let world = flat_world();
    let nowhere = Nowhere(flat_world());
    let v = Counting(AtomicUsize::new(0));
    let e = env(&nowhere, &world, &v);
    for m in [TravelMode::OffroadFoot, TravelMode::OffroadVehicle] {
        let d = e.directions(&DirectionsRequest::new(FROM, TO, m));
        assert!(!d.ok);
        assert_eq!(d.errors[0].code, "not_set_up");
        assert_eq!(d.errors[0].message, OFFROAD_DATA_MISSING);
        assert_eq!(d.to_json()["errors"][0]["code"], "not_set_up");
    }
    assert_eq!(v.0.load(Ordering::SeqCst), 0);
}

#[test]
fn land_access_other_than_pragmatic_is_part_of_the_route_id() {
    let nowhere = Nowhere(flat_world());
    let world = flat_world();
    let v = Counting(AtomicUsize::new(0));
    let e = env(&nowhere, &world, &v);
    let id = |b: Boundary| {
        let mut r = DirectionsRequest::new(FROM, TO, TravelMode::OffroadFoot);
        r.boundary = b;
        e.directions(&r).route_id
    };
    // pragmatic keeps navi's key (sha256 of "42.555800,-114.470100|42.565000,-114.460000|offroad_foot|t")
    assert_eq!(id(Boundary::Pragmatic), "61ce886a582d8e20");
    assert_eq!(id(Boundary::Strict), "1e00fd99935a3eb1");
    assert_eq!(id(Boundary::Emergency), "0336559888cf300f");
}
