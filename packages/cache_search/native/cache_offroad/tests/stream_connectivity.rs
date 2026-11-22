//! A route over tiles that arrive after the router started, with the REAL Valhalla shim (the Linux build of packages/valhalla).
//! Mirrors the phone case: the destination's downloaded region is one island of tiles; stream() adds the tiles around the start
//! and the level 0/1 tiles between them, into the same folder, while the router lives. Runs only when the env vars are set:
//!   OFFROAD_VALHALLA_LIB      libvalhalla_shim.so
//!   OFFROAD_ROUTE_ISLAND      folder of tiles (levels 0/1/2) around the destination (tests/route_islands.py makes it)
//!   OFFROAD_ROUTE_FETCHED     folder of tiles stream() adds for the trip (route_islands.py)
//! OFFROAD_ROUTE_CONNECTIVITY=on forces `loki.use_connectivity` true (what config_for_tile_dir did before the fix): the test must fail then.
#![cfg(feature = "shim")]
use cache_offroad::shim::{config_for_tile_dir, ShimValhalla};
use cache_offroad::valhalla::Valhalla;
use serde_json::Value;
use std::path::{Path, PathBuf};

const START: (f64, f64) = (42.57368, -114.60665);
const DEST: (f64, f64) = (43.49270, -112.04080);
/// Two points inside the island, for the warm-up route.
const INSIDE: ((f64, f64), (f64, f64)) = ((43.4927, -112.0408), (43.6724, -111.9150));

fn env(k: &str) -> Option<String> {
    std::env::var(k).ok().filter(|v| !v.is_empty())
}

fn copy_tree(from: &Path, to: &Path) {
    for e in std::fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let dst = to.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            std::fs::create_dir_all(&dst).unwrap();
            copy_tree(&e.path(), &dst);
        } else {
            std::fs::copy(e.path(), &dst).unwrap();
        }
    }
}

struct Setup {
    lib: PathBuf,
    island: PathBuf,
    fetched: PathBuf,
    work: PathBuf,
}

fn setup(name: &str) -> Option<Setup> {
    let (Some(lib), Some(island), Some(fetched)) = (env("OFFROAD_VALHALLA_LIB"), env("OFFROAD_ROUTE_ISLAND"), env("OFFROAD_ROUTE_FETCHED")) else {
        eprintln!("route-island env vars not set: skipping");
        return None;
    };
    let work = std::env::temp_dir().join(format!("stream_connectivity_{name}_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work).unwrap();
    Some(Setup { lib: lib.into(), island: island.into(), fetched: fetched.into(), work })
}

fn start_router(s: &Setup) -> ShimValhalla {
    let mut c: Value = serde_json::from_str(&config_for_tile_dir(&s.work)).unwrap();
    if env("OFFROAD_ROUTE_CONNECTIVITY").as_deref() == Some("on") {
        c["loki"]["use_connectivity"] = Value::Bool(true);
    }
    ShimValhalla::load(&s.lib, &c.to_string()).unwrap()
}

fn assert_route(v: &ShimValhalla) {
    match v.route(START, DEST, "auto") {
        Ok(t) => {
            eprintln!("route ok: {:.1} km, {} maneuvers", t.length_km, t.maneuvers.len());
            assert!((100.0..=300.0).contains(&t.length_km), "route length {} km", t.length_km);
        }
        Err(e) => panic!("route start -> destination failed: Valhalla code {:?}: {}", e.code, e.message),
    }
}

/// The router starts on the island, routes inside it, then the fetched tiles land in the same folder: the same router must route.
#[test]
fn router_started_before_the_tiles_arrive_routes_through_them() {
    let Some(s) = setup("warm") else { return };
    copy_tree(&s.island, &s.work);
    let v = start_router(&s);
    let t = v.route(INSIDE.0, INSIDE.1, "auto").expect("warm-up route inside the island");
    eprintln!("warm-up inside the island: {:.1} km", t.length_km);
    copy_tree(&s.fetched, &s.work);
    assert_route(&v);
    let _ = std::fs::remove_dir_all(&s.work);
}

/// The router is created only after the fetched tiles are in the folder.
#[test]
fn router_started_after_the_tiles_arrive_routes_through_them() {
    let Some(s) = setup("fresh") else { return };
    copy_tree(&s.island, &s.work);
    copy_tree(&s.fetched, &s.work);
    let v = start_router(&s);
    assert_route(&v);
    let _ = std::fs::remove_dir_all(&s.work);
}

/// How long the router takes to say no, with `use_connectivity` off, for a pair with no way through (a folder of tiles in
/// OFFROAD_ROUTE_GAP_DIR; the pair is OFFROAD_ROUTE_GAP_FROM and OFFROAD_ROUTE_GAP_TO as "lat,lon"). Prints the code and the ms of 3 runs.
#[test]
fn time_to_give_up_on_a_pair_with_no_way_through() {
    let (Some(dir), Some(from), Some(to), Some(lib)) =
        (env("OFFROAD_ROUTE_GAP_DIR"), env("OFFROAD_ROUTE_GAP_FROM"), env("OFFROAD_ROUTE_GAP_TO"), env("OFFROAD_VALHALLA_LIB"))
    else {
        eprintln!("gap env vars not set: skipping");
        return;
    };
    let pt = |s: String| {
        let (a, o) = s.split_once(',').unwrap();
        (a.trim().parse::<f64>().unwrap(), o.trim().parse::<f64>().unwrap())
    };
    let (from, to) = (pt(from), pt(to));
    let v = ShimValhalla::load(Path::new(&lib), &config_for_tile_dir(Path::new(&dir))).unwrap();
    for run in 1..=3 {
        let t = std::time::Instant::now();
        let r = v.route(from, to, "auto");
        let ms = t.elapsed().as_millis();
        match r {
            Ok(t) => eprintln!("GAP run {run}: {ms} ms, ROUTE {:.1} km", t.length_km),
            Err(e) => eprintln!("GAP run {run}: {ms} ms, code {:?}: {}", e.code, e.message),
        }
    }
}
