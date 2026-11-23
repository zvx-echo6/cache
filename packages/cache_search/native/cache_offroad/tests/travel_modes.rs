//! The screen's travel modes (Drive with its avoid toggles, Walk, Bike, ATV) and what they ask of the engine: the internal ids
//! `offroad_moto`, `offroad_4w` and `offroad_sxs`, their profiles, Valhalla's costing and options, and the notes a route carries
//! when the pack lacks the data a profile wants (the dirt bike and over-50-in MVUM columns).
use cache_offroad::cost::{Mode, Variant, PROFILES, PROFILE_MOTO, PROFILE_SXS};
use cache_offroad::directions::*;
use cache_offroad::grid::GridMeta;
use cache_offroad::mvum::access_grids_ext;
use cache_offroad::pack::{MemPack, MvumFeature};
use cache_offroad::router::{Boundary, RequestMode, RouteOptions, Router, RouteRequest, NOTE_MOTO_FALLBACK, NOTE_NO_LAND_RULES, NOTE_SXS_FALLBACK};
use cache_offroad::valhalla::*;
use std::sync::Mutex;

const FROM: (f64, f64) = (42.5558, -114.4701);
const TO: (f64, f64) = (42.565, -114.46);

/// Finds no road, and records every costing and option set it is asked for.
struct Recorder(Mutex<Vec<(String, CostingOpts)>>);
impl Valhalla for Recorder {
    fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
        None
    }
    fn route(&self, f: (f64, f64), t: (f64, f64), c: &str) -> Result<Trip, ValhallaError> {
        self.route_with(&RouteEnd::at(f), &RouteEnd::at(t), c, &CostingOpts::default())
    }
    fn route_with(&self, f: &RouteEnd, t: &RouteEnd, c: &str, o: &CostingOpts) -> Result<Trip, ValhallaError> {
        self.0.lock().unwrap().push((c.to_string(), o.clone()));
        let shape = vec![f.point(), t.point()];
        Ok(Trip { shape_encoded: encode_polyline6(&shape), shape, maneuvers: vec![Maneuver::default()], length_km: 1.0, time_s: 100.0 })
    }
    fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("none"))
    }
}

fn flat_world() -> MemPack {
    let (gr, gc) = cache_offroad::grid::global_pixel((FROM.0 + TO.0) / 2.0, (FROM.1 + TO.1) / 2.0).unwrap();
    let mut p = MemPack::blank(600, 600, 1300.0);
    p.row0 = gr - 300;
    p.col0 = gc - 300;
    p
}

fn env<'a>(pack: &'a MemPack, v: &'a Recorder) -> Env<'a> {
    Env { pack, elevation: pack, valhalla: v, options: RouteOptions::default(), namer: None, version: "t".into() }
}

#[test]
fn the_new_ids_map_onto_the_engine() {
    let ids = [
        ("offroad_moto", TravelMode::OffroadMoto, RequestMode::Single(Mode::TwoW), "motorcycle", Variant::Moto),
        ("offroad_4w", TravelMode::OffroadFourW, RequestMode::Single(Mode::FourW), "auto", Variant::Standard),
        ("offroad_sxs", TravelMode::OffroadSxs, RequestMode::Single(Mode::FourW), "auto", Variant::Sxs),
    ];
    for (name, m, rm, costing, variant) in ids {
        assert_eq!(TravelMode::from_name(name), Some(m));
        assert_eq!(m.name(), name);
        assert!(m.offroad_only());
        assert_eq!(m.router_mode(), rm);
        assert_eq!(m.costing(), costing);
        assert_eq!(m.variant(), variant);
    }
    // the five ids the assistant knows are as they were
    assert_eq!(TravelMode::OffroadVehicle.router_mode(), RequestMode::Auto);
    assert_eq!(TravelMode::OffroadVehicle.variant(), Variant::Standard);
    assert_eq!(TravelMode::Bike.costing(), "bicycle");
    assert_eq!(TravelMode::Bike.router_mode(), RequestMode::Single(Mode::TwoW));
}

#[test]
fn road_pieces_of_an_offroad_route_use_the_machines_costing() {
    let moto = TravelMode::OffroadMoto.road_costing("2w");
    assert_eq!(moto.0, "motorcycle");
    assert_eq!(moto.1, CostingOpts { use_trails: Some(1.0), ..Default::default() });
    for m in [TravelMode::OffroadFourW, TravelMode::OffroadSxs] {
        let (c, o) = m.road_costing("4w");
        assert_eq!(c, "auto");
        assert_eq!((o.use_highways, o.use_tracks), (Some(0.0), Some(1.0)));
    }
    // the assistant's off-road modes keep what they had
    assert_eq!(TravelMode::OffroadVehicle.road_costing("4w"), ("auto", CostingOpts::default()));
    assert_eq!(TravelMode::OffroadVehicle.road_costing("2w"), ("bicycle", CostingOpts::default()));
    assert_eq!(TravelMode::OffroadFoot.road_costing("foot"), ("pedestrian", CostingOpts::default()));
}

#[test]
fn drives_toggles_reach_valhalla_as_costing_options() {
    let world = flat_world();
    let v = Recorder(Mutex::new(vec![]));
    let e = env(&world, &v);
    let ask = |h: bool, t: bool| {
        let mut r = DirectionsRequest::new(FROM, TO, TravelMode::Drive);
        r.avoid_highways = h;
        r.avoid_tolls = t;
        let d = e.directions(&r);
        assert!(d.ok, "{:?}", d.errors);
        d.route_id
    };
    let none = ask(false, false);
    let hw = ask(true, false);
    let both = ask(true, true);
    let tolls = ask(false, true);
    let calls = v.0.lock().unwrap().clone();
    assert_eq!(calls[0], ("auto".into(), CostingOpts::default()));
    assert_eq!(calls[1].1, CostingOpts { use_highways: Some(0.0), ..Default::default() });
    assert_eq!(calls[2].1, CostingOpts { use_highways: Some(0.0), use_tolls: Some(0.0), ..Default::default() });
    assert_eq!(calls[3].1, CostingOpts { use_tolls: Some(0.0), ..Default::default() });
    // each is its own route; with nothing avoided the id is the one a plain drive always had
    let ids = [&none, &hw, &both, &tolls];
    for (i, a) in ids.iter().enumerate() {
        for b in &ids[i + 1..] {
            assert_ne!(a, b);
        }
    }
    let plain = e.directions(&DirectionsRequest::new(FROM, TO, TravelMode::Drive)).route_id;
    assert_eq!(plain, none);
    // the toggles mean nothing to the other modes
    let mut w = DirectionsRequest::new(FROM, TO, TravelMode::Walk);
    w.avoid_highways = true;
    assert_eq!(w.road_opts(), CostingOpts::default());
}

#[test]
fn the_profiles_are_the_design_numbers() {
    let two = &PROFILES[Mode::TwoW.idx()];
    assert_eq!((PROFILE_MOTO.base_speed_kmh, PROFILE_MOTO.max_slope_deg), (30.0, 30.0));
    assert!(PROFILE_MOTO.base_speed_kmh > two.base_speed_kmh);
    assert!(PROFILE_MOTO.wilderness_impassable);
    let four = &PROFILES[Mode::FourW.idx()];
    assert_eq!((PROFILE_SXS.base_speed_kmh, PROFILE_SXS.max_slope_deg), (four.base_speed_kmh, four.max_slope_deg));
    assert_eq!(Variant::Moto.profile_for(Mode::TwoW).name, "moto");
    assert_eq!(Variant::Moto.profile_for(Mode::FourW).name, "4w");
    assert_eq!(Variant::Sxs.profile_for(Mode::FourW).name, "sxs");
    assert_eq!(Variant::Standard.profile_for(Mode::TwoW).name, "2w");
}

fn minutes(world: &MemPack, mode: Mode, variant: Variant) -> f64 {
    let v = Recorder(Mutex::new(vec![]));
    let mut rr = RouteRequest::new(FROM, TO, RequestMode::Single(mode), Boundary::Pragmatic);
    rr.variant = variant;
    let r = Router { pack: world, elevation: world, valhalla: &v, opts: RouteOptions::default() }.route(&rr).expect("a route");
    r.total_effort_minutes
}

#[test]
fn each_screen_choice_routes_with_its_own_profile() {
    let world = flat_world();
    let (foot, bike) = (minutes(&world, Mode::Foot, Variant::Standard), minutes(&world, Mode::TwoW, Variant::Standard));
    let moto = minutes(&world, Mode::TwoW, Variant::Moto);
    assert!(moto < bike && bike < foot, "dirt bike {moto}, bicycle {bike}, foot {foot}");
    // shrub costs a side-by-side more than a quad
    let mut shrub = flat_world();
    shrub.class = Some(vec![20; shrub.rows * shrub.cols]);
    let (quad, sxs) = (minutes(&shrub, Mode::FourW, Variant::Standard), minutes(&shrub, Mode::FourW, Variant::Sxs));
    assert!(sxs > quad, "side-by-side {sxs}, quad {quad}");
    // on open ground they are the same machine
    let (quad, sxs) = (minutes(&world, Mode::FourW, Variant::Standard), minutes(&world, Mode::FourW, Variant::Sxs));
    assert!((sxs - quad).abs() < 1e-9, "{sxs} vs {quad}");
}

#[test]
fn directions_by_dirt_bike_quad_and_side_by_side_are_off_road_all_the_way() {
    let world = flat_world();
    let v = Recorder(Mutex::new(vec![]));
    let e = env(&world, &v);
    for (m, tag) in [(TravelMode::OffroadMoto, "2w"), (TravelMode::OffroadFourW, "4w"), (TravelMode::OffroadSxs, "4w")] {
        let d = e.directions(&DirectionsRequest::new(FROM, TO, m));
        assert!(d.ok, "{:?}: {:?}", m, d.errors);
        assert_eq!(d.routing, "offroad");
        assert_eq!(d.to_json()["mode"], m.name());
        assert!(d.steps.iter().all(|s| s.kind.starts_with("offroad") && s.mode.as_deref() == Some(tag)), "{:?}: {:?}", m, d.steps);
        assert!(e.alternatives(&DirectionsRequest::new(FROM, TO, m), 2).is_empty());
    }
}

/// A closed-to-motorcycles line along the trip.
fn mvum_line(ext: [Option<(Option<String>, Option<String>)>; 2]) -> MvumFeature {
    let s = |x: &str| Some(x.to_string());
    MvumFeature {
        is_trail: true,
        symbol: s("1"),
        seasonal: s("yearlong"),
        access: [(s("open"), None), (s("open"), None), (s("open"), None)],
        ext,
        lines: vec![vec![(FROM.1, FROM.0), (TO.1, TO.0)]],
    }
}

fn notes(world: &MemPack, mode: TravelMode, boundary: Boundary) -> Vec<String> {
    let v = Recorder(Mutex::new(vec![]));
    let e = env(world, &v);
    let mut r = DirectionsRequest::new(FROM, TO, mode);
    r.boundary = boundary;
    let d = e.directions(&r);
    assert!(d.ok, "{:?}", d.errors);
    d.notes
}

#[test]
fn a_pack_without_the_new_columns_says_which_rules_were_used_instead() {
    let mut world = flat_world();
    world.mvum = vec![mvum_line([None, None])];
    let moto = notes(&world, TravelMode::OffroadMoto, Boundary::Pragmatic);
    assert!(moto.contains(&NOTE_MOTO_FALLBACK.to_string()), "{moto:?}");
    assert!(!moto.contains(&NOTE_SXS_FALLBACK.to_string()));
    let sxs = notes(&world, TravelMode::OffroadSxs, Boundary::Strict);
    assert!(sxs.contains(&NOTE_SXS_FALLBACK.to_string()), "{sxs:?}");
    // the quad, the foot and the assistant's modes have nothing to say about it
    for m in [TravelMode::OffroadFourW, TravelMode::OffroadFoot, TravelMode::OffroadVehicle] {
        let n = notes(&world, m, Boundary::Pragmatic);
        assert!(!n.contains(&NOTE_MOTO_FALLBACK.to_string()) && !n.contains(&NOTE_SXS_FALLBACK.to_string()), "{m:?}: {n:?}");
    }
    // Emergency ignores the land rules, so there is nothing to say about which were used
    assert!(!notes(&world, TravelMode::OffroadMoto, Boundary::Emergency).contains(&NOTE_MOTO_FALLBACK.to_string()));
}

#[test]
fn a_pack_with_the_new_columns_uses_them_and_stays_quiet() {
    let mut world = flat_world();
    let col = |s: &str| Some((Some(s.to_string()), None));
    world.mvum = vec![mvum_line([col("open"), col("open")])];
    assert!(notes(&world, TravelMode::OffroadMoto, Boundary::Pragmatic).iter().all(|n| n != NOTE_MOTO_FALLBACK));
    assert!(notes(&world, TravelMode::OffroadSxs, Boundary::Pragmatic).iter().all(|n| n != NOTE_SXS_FALLBACK));
}

#[test]
fn the_new_columns_become_their_own_grids() {
    let meta = GridMeta::from_bbox(42.55, 42.57, -114.48, -114.45);
    let col = |s: &str| Some((Some(s.to_string()), None));
    let none = access_grids_ext(&[mvum_line([None, None])], &meta, None);
    assert!(none[0].is_none() && none[1].is_none(), "no column, no grid: the caller falls back");
    let g = access_grids_ext(&[mvum_line([col("closed"), col("open")])], &meta, None);
    let (moto, wide) = (g[0].as_ref().unwrap(), g[1].as_ref().unwrap());
    assert!(moto.contains(&255) && !moto.contains(&1), "closed to motorcycles");
    assert!(wide.contains(&1) && !wide.contains(&255), "open to wide vehicles");
}

#[test]
fn the_no_land_rules_note_shows_only_when_the_pack_says_none() {
    let note = NOTE_NO_LAND_RULES.to_string();
    let with = |land: Option<&str>| {
        let mut w = flat_world();
        w.land_access = land.map(str::to_string);
        notes(&w, TravelMode::OffroadFoot, Boundary::Pragmatic)
    };
    assert!(with(Some("none")).contains(&note), "the pack says none");
    assert!(!with(Some("us")).contains(&note), "the pack says us");
    // silent: no MVUM and no barriers anywhere used to be read as "no rules"; now it says nothing
    assert!(!with(None).contains(&note), "the pack is silent");
}

/// Where a point falls in the synthetic world's own cells: (row, col) into its arrays.
fn cell_of(world: &MemPack, p: (f64, f64)) -> usize {
    let (gr, gc) = cache_offroad::grid::global_pixel(p.0, p.1).unwrap();
    (gr - world.row0) as usize * world.cols + (gc - world.col0) as usize
}

/// The cell and the ones around it are foot trail (a path a few cells wide, so the test does not depend on which cell the point falls in).
fn on_foot_trail(world: &mut MemPack, cell: usize) {
    for dr in -2i64..=2 {
        for dc in -2i64..=2 {
            world.trails[(cell as i64 + dr * world.cols as i64 + dc) as usize] = 25;
        }
    }
}

/// A quad standing on a foot trail (a path through a town: the pack marks it 25, which the quad may not ride) could never step off
/// it onto open ground, so the trip had "no way found" from that point and from no other. It leaves the trail by the nearest open cell.
#[test]
fn a_quad_that_starts_or_ends_on_a_foot_trail_still_finds_its_way() {
    let mut world = flat_world();
    let (s, e) = (cell_of(&world, FROM), cell_of(&world, TO));
    on_foot_trail(&mut world, s);
    let v = Recorder(Mutex::new(vec![]));
    for mode in [TravelMode::OffroadFourW, TravelMode::OffroadSxs] {
        let d = env(&world, &v).directions(&DirectionsRequest::new(FROM, TO, mode));
        assert!(d.ok, "{mode:?} from a foot trail: {:?}", d.errors);
    }
    on_foot_trail(&mut world, e);
    let d = env(&world, &v).directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFourW));
    assert!(d.ok, "to a foot trail too: {:?}", d.errors);
    // on foot the same trail is an ordinary way: that route is as it was
    assert!(env(&world, &v).directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFoot)).ok);
}

/// The nudge finds a way off a trail, not a way along one: where every cell is foot trail there is nowhere for a quad to go.
#[test]
fn the_quad_still_cannot_ride_a_foot_trail() {
    let mut world = flat_world();
    world.trails = vec![25; world.rows * world.cols];
    let v = Recorder(Mutex::new(vec![]));
    let quad = env(&world, &v).directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFourW));
    assert!(!quad.ok, "the quad rode a foot trail");
    assert!(env(&world, &v).directions(&DirectionsRequest::new(FROM, TO, TravelMode::OffroadFoot)).ok);
}
