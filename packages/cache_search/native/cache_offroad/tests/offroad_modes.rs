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
    for (name, m) in [("offroad_2w", TravelMode::OffroadTwoW), ("offroad_4w", TravelMode::OffroadFourW), ("offroad_car", TravelMode::OffroadCar)] {
        assert_eq!(TravelMode::from_name(name), Some(m));
        assert_eq!(m.name(), name);
        assert!(m.offroad_only());
    }
    // each choice on the directions screen asks the engine for a different profile
    assert_eq!(TravelMode::OffroadTwoW.router_mode(), RequestMode::Single(Mode::TwoW));
    assert_eq!(TravelMode::OffroadFourW.router_mode(), RequestMode::Single(Mode::FourW));
    assert_eq!(TravelMode::OffroadCar.router_mode(), RequestMode::Single(Mode::Vehicle));
    assert_eq!((TravelMode::OffroadTwoW.costing(), TravelMode::OffroadFourW.costing(), TravelMode::OffroadCar.costing()), ("bicycle", "auto", "auto"));
    // offroad_vehicle stays the mixed Auto search (the assistant's tool names it); the single vehicle mode has its own name
    assert_ne!(TravelMode::OffroadCar.name(), TravelMode::OffroadVehicle.name());
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
    // pragmatic keeps the reference server's key (sha256 of "42.555800,-114.470100|42.565000,-114.460000|offroad_foot|t")
    assert_eq!(id(Boundary::Pragmatic), "61ce886a582d8e20");
    assert_eq!(id(Boundary::Strict), "1e00fd99935a3eb1");
    assert_eq!(id(Boundary::Emergency), "0336559888cf300f");
}

/// The flat world with a straight track (trail value 5) joining both ends, thick enough for every profile to follow.
fn world_with_track() -> MemPack {
    track_world(1.0)
}

/// The same, but the track covers only the first `frac` of the way.
fn track_world(frac: f64) -> MemPack {
    let mut p = flat_world();
    let (r0, c0) = cache_offroad::grid::global_pixel(FROM.0, FROM.1).unwrap();
    let (r1, c1) = cache_offroad::grid::global_pixel(TO.0, TO.1).unwrap();
    let n = (r1 - r0).abs().max((c1 - c0).abs()).max(1);
    for i in 0..=((n as f64 * frac) as i64) {
        let (r, c) = (r0 + (r1 - r0) * i / n - p.row0, c0 + (c1 - c0) * i / n - p.col0);
        for dr in -1..=1 {
            for dc in -1..=1 {
                let idx = ((r + dr) as usize) * p.cols + (c + dc) as usize;
                p.trails[idx] = 5;
            }
        }
    }
    p
}

/// All five off-road choices are routed with their own profile: the same trip takes a different time in each, and each
/// leg is labeled with the mode that was asked for (Auto may mix them).
#[test]
fn each_offroad_mode_routes_differently() {
    let world = world_with_track();
    let v = Counting(AtomicUsize::new(0));
    let e = env(&world, &world, &v);
    let mut secs = std::collections::BTreeMap::new();
    for (m, tag) in [(TravelMode::OffroadFoot, "foot"), (TravelMode::OffroadTwoW, "2w"), (TravelMode::OffroadFourW, "4w"), (TravelMode::OffroadCar, "vehicle")] {
        let d = e.directions(&DirectionsRequest::new(FROM, TO, m));
        assert!(d.ok, "{:?}: {:?}", m, d.errors);
        assert_eq!(d.routing, "offroad");
        assert_eq!(d.to_json()["mode"], m.name());
        assert!(d.steps.iter().all(|s| s.kind.starts_with("offroad") && s.mode.as_deref() == Some(tag)), "{:?}: {:?}", m, d.steps);
        eprintln!("EVIDENCE {} -> {} s, {} km, steps {:?}", m.name(), d.duration_s, d.distance_km, d.steps.iter().map(|s| s.mode.clone()).collect::<Vec<_>>());
        secs.insert(tag, d.duration_s);
    }
    // Auto: start and end told to be a parking lot (all four modes may start and end there), so it mixes what is fastest
    let mut req = DirectionsRequest::new(FROM, TO, TravelMode::OffroadVehicle);
    req.from_category = Some("highway:residential".into());
    req.to_category = Some("highway:residential".into());
    let auto = e.directions(&req);
    assert!(auto.ok, "{:?}", auto.errors);
    eprintln!("EVIDENCE offroad_vehicle(Auto) -> {} s, steps {:?}", auto.duration_s, auto.steps.iter().map(|s| s.mode.clone()).collect::<Vec<_>>());
    // slower to faster: foot, bike, ATV, vehicle
    assert!(secs["foot"] > secs["2w"] && secs["2w"] > secs["4w"] && secs["4w"] > secs["vehicle"], "{secs:?}");
    // Auto is a search of its own: it is never slower than any single mode it may use
    assert!(auto.duration_s <= secs["foot"]);
    let all: std::collections::BTreeSet<i64> = [secs["foot"], secs["2w"], secs["4w"], secs["vehicle"], auto.duration_s].into_iter().collect();
    assert!(all.len() >= 4, "{all:?}");
}

/// Land a 4-wheel machine cannot cross (class 10) is crossed on foot and, slowly, on two wheels: so the choice changes whether a
/// route exists, not only how long it takes.
#[test]
fn four_wheel_cannot_cross_what_foot_and_two_wheel_can() {
    let mut world = flat_world();
    world.class = Some(vec![10; world.rows * world.cols]);
    let v = Counting(AtomicUsize::new(0));
    let e = env(&world, &world, &v);
    let foot = e.directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFoot));
    let two = e.directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadTwoW));
    let four = e.directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFourW));
    eprintln!("EVIDENCE class10: foot ok={} {} s; 2w ok={} {} s; 4w ok={} {:?}", foot.ok, foot.duration_s, two.ok, two.duration_s, four.ok, four.errors.first().map(|x| x.message.clone()));
    assert!(foot.ok, "{:?}", foot.errors);
    assert!(two.ok, "{:?}", two.errors);
    assert!(!four.ok);
    let car = e.directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadCar));
    eprintln!("EVIDENCE class10: vehicle ok={}", car.ok);
    assert!(!car.ok);
}

/// Where the track ends short of the destination, Auto drives the track and walks the rest; the single Vehicle mode stays in
/// the vehicle the whole way.
#[test]
fn auto_mixes_modes_where_the_vehicle_cannot_finish() {
    let world = track_world(0.5);
    let v = Counting(AtomicUsize::new(0));
    let e = env(&world, &world, &v);
    let car = e.directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadCar));
    let mut req = DirectionsRequest::new(FROM, TO, TravelMode::OffroadVehicle);
    req.from_category = Some("highway:residential".into());
    let auto = e.directions(&req);
    let modes: std::collections::BTreeSet<String> = auto.steps.iter().filter_map(|s| s.mode.clone()).collect();
    eprintln!("EVIDENCE half-track: vehicle-only {} s ok={} ; Auto ok={} {} s modes {:?}", car.duration_s, car.ok, auto.ok, auto.duration_s, modes);
    assert!(auto.ok, "{:?}", auto.errors);
    // Auto switches from the vehicle to walking where the track ends; the single Vehicle mode never does
    assert!(modes.contains("vehicle") && modes.contains("foot"), "{modes:?}");
    assert!(car.steps.iter().all(|s| s.mode.as_deref() == Some("vehicle")), "{:?}", car.steps);
}
