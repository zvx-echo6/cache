//! Ports of navi's Phase-4 `_route_auto` integration tests, the category / spatial-eligibility tests
//! and the Valhalla-bypass tests. Synthetic grids via MemPack + GridMeta::synthetic-like metas.
use cache_offroad::cost::Mode;
use cache_offroad::grid::GridMeta;
use cache_offroad::pack::*;
use cache_offroad::router::*;
use cache_offroad::valhalla::*;
use std::collections::{BTreeSet, HashMap};
use std::time::Instant;

fn meta100(rows: usize, cols: usize) -> GridMeta {
    let cell = 100.0;
    let dlat = cell / 111000.0;
    let dlon = cell / (111000.0 * 40.0f64.to_radians().cos());
    GridMeta {
        bounds: (40.0, 40.0 + rows as f64 * dlat, -111.0, -111.0 + cols as f64 * dlon),
        pixel_size_lat: -dlat, pixel_size_lon: dlon, origin_lat: 40.0 + rows as f64 * dlat, origin_lon: -111.0,
        cell_size_m: cell, rows, cols, global_row0: 0, global_col0: 0,
    }
}
fn px2ll(m: &GridMeta, r: i64, c: i64) -> (f64, f64) {
    m.pixel_to_latlon(r, c)
}
fn set(v: &[Mode]) -> BTreeSet<usize> {
    v.iter().map(|m| m.idx()).chain([0]).collect()
}
const ALLM: [Mode; 4] = [Mode::Foot, Mode::TwoW, Mode::FourW, Mode::Vehicle];

fn run(pack: &MemPack, meta: &GridMeta, s: (i64, i64), e: (i64, i64), sm: &[Mode], em: &[Mode], b: Boundary, aff: Option<HashMap<Mode, f64>>) -> RouteResult {
    let mut req = RouteRequest::new(px2ll(meta, s.0, s.1), px2ll(meta, e.0, e.1), RequestMode::Auto, b);
    req.network_affinity = aff;
    let router = Router { pack, valhalla: &StubValhalla, opts: RouteOptions::default() };
    router.search_on_grid(&req, meta.clone(), &set(sm), &set(em), Instant::now()).expect("route")
}

#[test]
fn wilderness_to_home_walk_then_drive() {
    let (rows, cols) = (3usize, 40usize);
    let meta = meta100(rows, cols);
    let mut p = MemPack::blank(rows, cols, 1000.0);
    p.class = Some(vec![10; rows * cols]);
    p.friction = vec![20; rows * cols];
    for c in 8..40 {
        p.trails[cols + c] = 5;
    }
    let out = run(&p, &meta, (1, 0), (1, 39), &[Mode::Foot], &ALLM, Boundary::Pragmatic, None);
    assert!(out.selected_mode_set.contains(&"foot".to_string()) && out.selected_mode_set.contains(&"vehicle".to_string()));
    assert_eq!(out.segments.first().unwrap().mode, Mode::Foot);
    assert_eq!(out.segments.last().unwrap().mode, Mode::Vehicle);
    assert_eq!(out.transitions.len(), 1);
    let t = &out.transitions[0];
    assert_eq!(meta.latlon_to_pixel_eps(t.lat, t.lon), (1, 8));
}

#[test]
fn foot_to_offpath() {
    let (rows, cols) = (3usize, 12usize);
    let meta = meta100(rows, cols);
    let p = MemPack::blank(rows, cols, 1000.0);
    let out = run(&p, &meta, (1, 0), (1, 11), &[Mode::Foot], &[Mode::Foot], Boundary::Pragmatic, None);
    assert_eq!(out.selected_mode_set, vec!["foot".to_string()]);
    assert!(out.transitions.is_empty());
    assert!(out.segments.iter().all(|s| s.mode == Mode::Foot));
}

#[test]
fn road_to_road_stays_on_network() {
    let (rows, cols) = (3usize, 20usize);
    let meta = meta100(rows, cols);
    let mut p = MemPack::blank(rows, cols, 1000.0);
    p.class = Some(vec![10; rows * cols]);
    p.friction = vec![20; rows * cols];
    for c in 0..cols {
        p.trails[cols + c] = 5;
    }
    let out = run(&p, &meta, (1, 0), (1, 19), &ALLM, &ALLM, Boundary::Pragmatic, None);
    assert!(out.selected_mode_set.contains(&"vehicle".to_string()));
    for c in &out.cells {
        assert_ne!(p.trails[c.row as usize * cols + c.col as usize], 0);
    }
}

#[test]
fn network_affinity_biases_path() {
    let (rows, cols) = (4usize, 14usize);
    let meta = meta100(rows, cols);
    let mut p = MemPack::blank(rows, cols, 1000.0);
    for c in 0..cols {
        p.trails[c] = 5;
    }
    let on_net = |r: &RouteResult| r.cells.iter().filter(|c| p.trails[c.row as usize * cols + c.col as usize] != 0).count();
    let base = run(&p, &meta, (0, 0), (0, 13), &ALLM, &ALLM, Boundary::Pragmatic, None);
    let aff: HashMap<Mode, f64> = ALLM.iter().map(|m| (*m, 80.0)).collect();
    let biased = run(&p, &meta, (0, 0), (0, 13), &ALLM, &ALLM, Boundary::Pragmatic, Some(aff));
    assert!(on_net(&biased) < on_net(&base), "{} !< {}", on_net(&biased), on_net(&base));
}

#[test]
fn perf_50km_grid() {
    let n = 500usize;
    let meta = meta100(n, n);
    let p = MemPack::blank(n, n, 1000.0);
    let t = Instant::now();
    let out = run(&p, &meta, (250, 20), (250, 480), &[Mode::Foot], &[Mode::Foot], Boundary::Pragmatic, None);
    assert_eq!(out.selected_mode_set, vec!["foot".to_string()]);
    eprintln!("50 km synthetic route: {:?}", t.elapsed());
}

#[test]
fn single_mode_seeds_only_that_mode() {
    let (rows, cols) = (3usize, 40usize);
    let meta = meta100(rows, cols);
    let mut p = MemPack::blank(rows, cols, 1000.0);
    for c in 8..40 {
        p.trails[cols + c] = 5;
    }
    let mut req = RouteRequest::new(px2ll(&meta, 1, 10), px2ll(&meta, 1, 39), RequestMode::Single(Mode::Foot), Boundary::Pragmatic);
    req.network_affinity = None;
    let r = Router { pack: &p, valhalla: &StubValhalla, opts: RouteOptions::default() };
    let one: BTreeSet<usize> = [0].into_iter().collect();
    let out = r.search_on_grid(&req, meta.clone(), &one, &one, Instant::now()).unwrap();
    assert_eq!(out.selected_mode_set, vec!["foot".to_string()]);
    assert!(out.transitions.is_empty());
}

// ---- eligibility -------------------------------------------------------------------------------

fn names(s: &BTreeSet<usize>) -> Vec<&'static str> {
    s.iter().map(|&i| Mode::from_idx(i).name()).collect()
}

#[test]
fn eligible_modes_from_category_table() {
    let e = |c: &str| eligible_modes_from_category(Some(c)).map(|s| names(&s));
    assert_eq!(e("highway:residential").unwrap(), vec!["foot", "2w", "4w", "vehicle"]);
    assert_eq!(e("highway:track").unwrap(), vec!["foot", "2w", "4w"]);
    assert_eq!(e("highway:path").unwrap(), vec!["foot", "2w"]);
    assert_eq!(e("highway:footway").unwrap(), vec!["foot"]);
    assert_eq!(e("building:house").unwrap(), vec!["foot", "2w", "4w", "vehicle"]);
    assert_eq!(e("amenity:cafe").unwrap().len(), 4);
    assert_eq!(e("natural:peak").unwrap(), vec!["foot"]);
    assert!(e("bogus:thing").is_none());
    assert!(eligible_modes_from_category(None).is_none());
    assert!(eligible_modes_from_category(Some("")).is_none());
}

struct Fixed(Option<LocateSnap>);
impl Valhalla for Fixed {
    fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
        self.0.clone()
    }
    fn route_vehicle(&self, _: (f64, f64), _: (f64, f64)) -> Result<NetworkRoute, String> {
        Err("none".into())
    }
    fn route_shape(&self, _: (f64, f64), _: (f64, f64)) -> Vec<(f64, f64)> {
        vec![]
    }
    fn surface_change_candidates(&self, _: &[(f64, f64)]) -> Vec<(f64, f64)> {
        vec![]
    }
}
fn snap(d: f64, c: Option<&str>, u: Option<&str>) -> Fixed {
    Fixed(Some(LocateSnap { snap_distance_m: d, road_class: c.map(String::from), use_: u.map(String::from) }))
}

/// A pack that fails every read: proves the bypass skips the raster pipeline.
struct NoRead;
impl PackSource for NoRead {
    fn has_layer(&self, _: Layer) -> bool {
        true
    }
    fn read_u8(&self, _: Layer, _: i64, _: i64, _: usize, _: usize) -> PResult<Vec<u8>> {
        Err(PackError::Msg("no read".into()))
    }
    fn read_elevation(&self, _: i64, _: i64, _: usize, _: usize) -> PResult<Vec<f32>> {
        Err(PackError::Msg("no read".into()))
    }
    fn parking_in_box(&self, _: f64, _: f64, _: f64, _: f64) -> PResult<Vec<PointRec>> {
        Ok(vec![])
    }
    fn trailheads_in_box(&self, _: f64, _: f64, _: f64, _: f64) -> PResult<Vec<PointRec>> {
        Ok(vec![])
    }
    fn mvum_in_box(&self, _: f64, _: f64, _: f64, _: f64) -> PResult<Vec<MvumFeature>> {
        Ok(vec![])
    }
}

fn seed_of(v: &dyn Valhalla, lat: f64, lon: f64) -> Vec<&'static str> {
    // seeds are observable through the bypass: use a pack that cannot read and a request
    // with the same snap at both ends; instead test via the public eligibility route below.
    let _ = (v, lat, lon);
    vec![]
}

#[test]
fn bypass_fires_for_tagged_roads_and_skips_raster() {
    struct Ok1;
    impl Valhalla for Ok1 {
        fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
            None
        }
        fn route_vehicle(&self, s: (f64, f64), e: (f64, f64)) -> Result<NetworkRoute, String> {
            Ok(NetworkRoute { coords: vec![(s.1, s.0), (e.1, e.0)], distance_km: 1.2, duration_min: 1.5, maneuvers: vec![] })
        }
        fn route_shape(&self, _: (f64, f64), _: (f64, f64)) -> Vec<(f64, f64)> {
            vec![]
        }
        fn surface_change_candidates(&self, _: &[(f64, f64)]) -> Vec<(f64, f64)> {
            vec![]
        }
    }
    let mut req = RouteRequest::new((42.5558, -114.4701), (42.5644, -114.4631), RequestMode::Auto, Boundary::Pragmatic);
    req.start_category = Some("highway:residential".into());
    req.end_category = Some("highway:residential".into());
    let out = route(&NoRead, &Ok1, &req, &RouteOptions::default()).unwrap();
    assert!(out.auto_bypass);
    assert_eq!(out.scenario, "D");
    assert_eq!(out.selected_mode, "vehicle");
    assert_eq!(out.selected_mode_set, vec!["vehicle".to_string()]);
    let j = out.to_json();
    assert_eq!(j["summary"]["auto_bypass"], true);

    // road -> footway: no bypass, the raster pipeline runs (and our NoRead pack fails there)
    let mut req2 = req.clone();
    req2.end_category = Some("highway:footway".into());
    assert!(matches!(route(&NoRead, &Ok1, &req2, &RouteOptions::default()), Err(RouteError::Terrain(_))));
    // untagged with a snap-less Valhalla -> foot only -> no bypass
    req2.start_category = None;
    req2.end_category = None;
    assert!(matches!(route(&NoRead, &Ok1, &req2, &RouteOptions::default()), Err(RouteError::Terrain(_))));
    // bypass falls through when Valhalla errors (the stub)
    assert!(matches!(route(&NoRead, &StubValhalla, &req, &RouteOptions::default()), Err(RouteError::Terrain(_))));
    let _ = seed_of(&Fixed(None), 0.0, 0.0);
}

#[test]
fn spatial_seeding_rules_via_untagged_bypass() {
    // Untagged endpoints: a tight (3 m) snap to a paved road grants vehicle at both ends -> bypass fires.
    struct Tight;
    impl Valhalla for Tight {
        fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
            Some(LocateSnap { snap_distance_m: 3.0, road_class: Some("residential".into()), use_: Some("road".into()) })
        }
        fn route_vehicle(&self, s: (f64, f64), e: (f64, f64)) -> Result<NetworkRoute, String> {
            Ok(NetworkRoute { coords: vec![(s.1, s.0), (e.1, e.0)], distance_km: 1.0, duration_min: 2.0, maneuvers: vec![] })
        }
        fn route_shape(&self, _: (f64, f64), _: (f64, f64)) -> Vec<(f64, f64)> {
            vec![]
        }
        fn surface_change_candidates(&self, _: &[(f64, f64)]) -> Vec<(f64, f64)> {
            vec![]
        }
    }
    let req = RouteRequest::new((42.5558, -114.4701), (42.5644, -114.4631), RequestMode::Auto, Boundary::Pragmatic);
    assert!(route(&NoRead, &Tight, &req, &RouteOptions::default()).unwrap().auto_bypass);
    // 50 m snap needs the flat-terrain grace; NoRead cannot sample the DEM -> not flat -> no vehicle -> unified (fails on read)
    struct Relaxed(Tight);
    impl Valhalla for Relaxed {
        fn locate(&self, a: f64, b: f64, c: &str) -> Option<LocateSnap> {
            self.0.locate(a, b, c).map(|mut s| {
                s.snap_distance_m = 50.0;
                s
            })
        }
        fn route_vehicle(&self, s: (f64, f64), e: (f64, f64)) -> Result<NetworkRoute, String> {
            self.0.route_vehicle(s, e)
        }
        fn route_shape(&self, _: (f64, f64), _: (f64, f64)) -> Vec<(f64, f64)> {
            vec![]
        }
        fn surface_change_candidates(&self, _: &[(f64, f64)]) -> Vec<(f64, f64)> {
            vec![]
        }
    }
    assert!(matches!(route(&NoRead, &Relaxed(Tight), &req, &RouteOptions::default()), Err(RouteError::Terrain(_))));
    // ... and with a flat DEM the relaxed snap does grant vehicle (flat-terrain grace) -> bypass
    // (a MemPack keyed at the global pixel of the endpoint)
    let (gr, gc) = cache_offroad::grid::global_pixel(42.5558, -114.4701).unwrap();
    let mut flat = MemPack::blank(400, 400, 1300.0);
    flat.row0 = gr - 200;
    flat.col0 = gc - 200;
    assert!(route(&flat, &Relaxed(Tight), &req, &RouteOptions::default()).unwrap().auto_bypass);
}

#[test]
fn too_long_is_refused_before_reading() {
    let req = RouteRequest::new((43.0, -116.0), (44.0, -114.5), RequestMode::Single(Mode::Foot), Boundary::Pragmatic);
    let opts = RouteOptions { max_cells: 8_000_000, ..Default::default() };
    match route(&NoRead, &StubValhalla, &req, &opts) {
        Err(RouteError::TooLong { estimated, max }) => assert!(estimated > max && max == 8_000_000),
        other => panic!("expected TooLong, got {:?}", other.map(|r| r.scenario)),
    }
}

#[test]
fn spatial_eligible_modes_cases() {
    let pack = MemPack::blank(10, 10, 0.0);
    let mut cache = SnapCache::new();
    let mut modes = |d: f64, c: Option<&str>, u: Option<&str>| names(&spatial_eligible_modes(&pack, &snap(d, c, u), 43.6, -116.2, &mut cache));
    // (a) paved grade close in -> vehicle (tight tier)
    assert_eq!(modes(3.0, Some("service_other"), Some("road")), vec!["foot", "2w", "4w", "vehicle"]);
    // (b) no grade, use=track -> 4w/2w/foot, not vehicle
    let mut cache2 = SnapCache::new();
    assert_eq!(names(&spatial_eligible_modes(&pack, &snap(20.0, None, Some("track")), 43.6, -116.2, &mut cache2)), vec!["foot", "2w", "4w"]);
    // (c) footway -> 2w/foot
    let mut cache3 = SnapCache::new();
    assert_eq!(names(&spatial_eligible_modes(&pack, &snap(20.0, None, Some("footway")), 43.6, -116.2, &mut cache3)), vec!["foot", "2w"]);
    // (d) nothing recognised -> foot
    let mut cache4 = SnapCache::new();
    assert_eq!(names(&spatial_eligible_modes(&pack, &snap(20.0, None, None), 43.6, -116.2, &mut cache4)), vec!["foot"]);
}
