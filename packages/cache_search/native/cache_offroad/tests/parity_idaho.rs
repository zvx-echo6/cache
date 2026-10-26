//! Parity of the port against navi PROD on the Idaho pack (12 routes). Needs the real data, so it only runs when
//! OFFROAD_IDAHO_PACK (offroad.sqlite), OFFROAD_IDAHO_ELEVATION (elevation.pmtiles), OFFROAD_VALHALLA_LIB (the
//! shim DLL / .so) and OFFROAD_VALHALLA_TILES (Idaho tiles.tar) are set; otherwise it is skipped.
//!
//! Expected values are navi's own answers (POST /api/offroute, mode "auto", recorded 2026-10-25). Nine routes
//! were sent WITHOUT seed categories (navi seeds itself from Valhalla /locate; the port does the same through
//! the shim); R03, R10, R11 (foot to foot) were recorded with `natural:peak` categories.
//! R08 (strict) is sensitive to the one-cell shift of the barrier raster between the aligned pack and navi's
//! per-query sampling; R06 differs in modes (2w/4w legs) for the same reason. See DESIGN-OFFROAD.md.
#![cfg(feature = "shim")]
use cache_offroad::shim::{config_for_tiles, ShimValhalla};
use cache_offroad::{route, Boundary, PmtilesElevation, RequestMode, RouteOptions, RouteRequest, SqlitePack};
use std::path::Path;

struct P {
    id: &'static str,
    start: (f64, f64),
    end: (f64, f64),
    start_cat: Option<&'static str>,
    end_cat: Option<&'static str>,
    boundary: &'static str,
    navi_min: f64,
    navi_km: f64,
    navi_modes: &'static [&'static str],
    tol: f64,
}

const ROUTES: &[P] = &[
    P { id: "R01-wild-to-road", start: (44.03164, -114.9878), end: (44.13596, -114.9145), start_cat: None, end_cat: None, boundary: "pragmatic", navi_min: 269.1582, navi_km: 21.1524, navi_modes: &["foot","vehicle"], tol: 0.03 },
    P { id: "R02-road-to-wild", start: (44.13596, -114.9145), end: (44.03164, -114.9878), start_cat: None, end_cat: None, boundary: "pragmatic", navi_min: 310.7227, navi_km: 21.2773, navi_modes: &["foot","vehicle"], tol: 0.03 },
    P { id: "R03-wild-to-wild", start: (43.98, -115.0), end: (44.1, -114.93), start_cat: Some("natural:peak"), end_cat: Some("natural:peak"), boundary: "pragmatic", navi_min: 304.5571, navi_km: 21.3819, navi_modes: &["foot"], tol: 0.03 },
    P { id: "R04-walkout-then-drive", start: (44.03164, -114.9878), end: (44.21008, -114.92566), start_cat: None, end_cat: None, boundary: "pragmatic", navi_min: 308.6073, navi_km: 26.2917, navi_modes: &["4w","foot","vehicle"], tol: 0.03 },
    P { id: "R05-track-4w", start: (44.18793, -114.95605), end: (44.25092, -115.0072), start_cat: None, end_cat: None, boundary: "pragmatic", navi_min: 8.3033, navi_km: 10.6833, navi_modes: &["4w","vehicle"], tol: 0.03 },
    P { id: "R06-foothills-2w", start: (43.71957, -116.09776), end: (43.77661, -116.06566), start_cat: None, end_cat: None, boundary: "pragmatic", navi_min: 34.1413, navi_km: 23.6077, navi_modes: &["2w","4w","foot","vehicle"], tol: 0.03 },
    P { id: "R07-yellowpine-long", start: (44.95441, -115.48184), end: (45.16382, -115.43481), start_cat: None, end_cat: None, boundary: "pragmatic", navi_min: 821.6299, navi_km: 40.0333, navi_modes: &["4w","foot","vehicle"], tol: 0.03 },
    P { id: "R08-barrier-strict", start: (44.18, -114.95), end: (44.23, -114.9), start_cat: None, end_cat: None, boundary: "strict", navi_min: 204.2417, navi_km: 12.8117, navi_modes: &["foot"], tol: 0.12 },
    P { id: "R09-barrier-pragmatic", start: (44.18, -114.95), end: (44.23, -114.9), start_cat: None, end_cat: None, boundary: "pragmatic", navi_min: 148.0800, navi_km: 13.8358, navi_modes: &["foot","vehicle"], tol: 0.03 },
    P { id: "R10-barrier-emergency", start: (44.18, -114.95), end: (44.23, -114.9), start_cat: Some("natural:peak"), end_cat: Some("natural:peak"), boundary: "emergency", navi_min: 112.4796, navi_km: 13.5991, navi_modes: &["foot","vehicle"], tol: 0.03 },
    P { id: "R11-foot-mountain", start: (44.03, -114.97), end: (43.93, -115.01), start_cat: Some("natural:peak"), end_cat: Some("natural:peak"), boundary: "pragmatic", navi_min: 324.1858, navi_km: 17.7855, navi_modes: &["foot"], tol: 0.03 },
    P { id: "R12-northidaho", start: (47.61594, -116.60005), end: (47.61513, -116.56211), start_cat: None, end_cat: None, boundary: "pragmatic", navi_min: 72.7309, navi_km: 6.4181, navi_modes: &["foot","vehicle"], tol: 0.03 },
];

#[test]
fn idaho_parity_with_navi() {
    let env = |k: &str| std::env::var(k).ok();
    let (Some(pack), Some(elev), Some(lib), Some(tiles)) =
        (env("OFFROAD_IDAHO_PACK"), env("OFFROAD_IDAHO_ELEVATION"), env("OFFROAD_VALHALLA_LIB"), env("OFFROAD_VALHALLA_TILES"))
    else {
        eprintln!("Idaho data env vars not set: skipping");
        return;
    };
    let pack = SqlitePack::open(Path::new(&pack)).expect("open pack");
    let elev = PmtilesElevation::open(Path::new(&elev)).expect("open elevation");
    let valhalla = ShimValhalla::load(Path::new(&lib), &config_for_tiles(Path::new(&tiles))).expect("load shim");
    let mut bad = Vec::new();
    for p in ROUTES {
        let mut req = RouteRequest::new(p.start, p.end, RequestMode::Auto, Boundary::from_name(p.boundary).unwrap());
        req.start_category = p.start_cat.map(String::from);
        req.end_category = p.end_cat.map(String::from);
        let r = route(&pack, &elev, &valhalla, &req, &RouteOptions::default()).unwrap_or_else(|e| panic!("{}: {e}", p.id));
        let de = (r.total_effort_minutes - p.navi_min) / p.navi_min;
        let dd = (r.total_distance_km - p.navi_km) / p.navi_km;
        eprintln!("{:<26} effort {:+6.2}%  distance {:+6.2}%  modes port {:?} navi {:?}", p.id, 100.0 * de, 100.0 * dd, r.selected_mode_set, p.navi_modes);
        if de.abs() > p.tol {
            bad.push(format!("{}: effort {:+.2}% beyond +/-{:.0}%", p.id, 100.0 * de, 100.0 * p.tol));
        }
    }
    assert!(bad.is_empty(), "{}", bad.join("; "));
}
