//! End-to-end oracle: navi's own `_route_auto` (numba kernel, scipy blur, real cost layers) was run on
//! synthetic worlds (gen_fixtures.py) and recorded; the Rust port must reproduce path, cost, distance,
//! transitions and mode segments.
mod common;
use cache_offroad::cost::Mode;
use cache_offroad::grid::GridMeta;
use cache_offroad::pack::{MemPack, PointRec};
use cache_offroad::router::*;
use cache_offroad::valhalla::StubValhalla;
use serde_json::Value;
use std::collections::{BTreeSet, HashMap};
use std::time::Instant;

fn modes(v: &Value) -> BTreeSet<usize> {
    v.as_array().unwrap().iter().map(|m| Mode::from_name(m.as_str().unwrap()).unwrap().idx()).collect()
}

#[test]
fn route_matches_navi_route_auto() {
    let cases = common::load_gz(include_bytes!("fixtures/oracle_cases.json.gz"));
    let mut checked = 0;
    for case in cases.as_array().unwrap() {
        let (rows, cols) = (case["rows"].as_u64().unwrap() as usize, case["cols"].as_u64().unwrap() as usize);
        let m = &case["meta"];
        let f = |k: &str| m[k].as_f64().unwrap();
        let meta = GridMeta {
            bounds: (f("south"), f("north"), f("west"), f("east")),
            pixel_size_lat: f("pixel_size_lat"), pixel_size_lon: f("pixel_size_lon"),
            origin_lat: f("origin_lat"), origin_lon: f("origin_lon"), cell_size_m: f("cell_size_m"),
            rows, cols, global_row0: 0, global_col0: 0,
        };
        let pts = |k: &str, kind: &str| -> Vec<PointRec> {
            case[k].as_array().unwrap().iter().map(|p| PointRec {
                lat: p["lat"].as_f64().unwrap(), lon: p["lon"].as_f64().unwrap(),
                name: p["name"].as_str().unwrap().into(),
                kind: kind.into(), access: p.get("access").and_then(|a| a.as_str()).unwrap_or("").into(),
            }).collect()
        };
        let mut pack = MemPack::blank(rows, cols, 0.0);
        pack.elev = common::f32_from_bits(&case["elev"]);
        pack.friction = common::u8s(&case["friction"]);
        pack.class = Some(common::u8s(&case["class"]));
        pack.trails = common::u8s(&case["trails"]);
        pack.barriers = common::u8s(&case["barriers"]);
        pack.wilderness = Some(common::u8s(&case["wilderness"]));
        pack.parking = pts("parking", "surface");
        pack.trailheads = pts("trailheads", "track");
        for sc in case["scenarios"].as_array().unwrap() {
            let s = &sc["sc"];
            let start = (sc["start_ll"][0].as_f64().unwrap(), sc["start_ll"][1].as_f64().unwrap());
            let end = (sc["end_ll"][0].as_f64().unwrap(), sc["end_ll"][1].as_f64().unwrap());
            let boundary = Boundary::from_name(s["boundary"].as_str().unwrap()).unwrap();
            let mut req = RouteRequest::new(start, end, RequestMode::Auto, boundary);
            let ms = |v: &Value| -> Vec<Mode> { modes(v).into_iter().map(Mode::from_idx).collect() };
            req.start_modes = Some(ms(&s["start_modes"]));
            req.end_modes = Some(ms(&s["end_modes"]));
            if let Some(a) = s.get("affinity").filter(|a| a.is_object()) {
                let mut h = HashMap::new();
                for (k, v) in a.as_object().unwrap() {
                    h.insert(Mode::from_name(k).unwrap(), v.as_f64().unwrap());
                }
                req.network_affinity = Some(h);
            }
            let router = Router { pack: &pack, valhalla: &StubValhalla, opts: RouteOptions::default() };
            let o_set = modes(&s["start_modes"]);
            let g_set = modes(&s["end_modes"]);
            let (mut o2, mut g2) = (o_set.clone(), g_set.clone());
            o2.insert(0);
            g2.insert(0);
            let got = router.search_on_grid(&req, meta.clone(), &o2, &g2, Instant::now()).expect("route");
            let exp = &sc["res"];
            let tag = format!("{} {:?}->{:?} {}", case["name"], s["start"], s["end"], s["boundary"]);
            // path cells
            let epath = sc["cap"]["path"].as_array().unwrap();
            assert_eq!(got.cells.len(), epath.len(), "{tag}: path length");
            for (i, (c, e)) in got.cells.iter().zip(epath).enumerate() {
                assert_eq!((c.row, c.col, c.mode.idx() as i64),
                    (e[0].as_i64().unwrap(), e[1].as_i64().unwrap(), e[2].as_i64().unwrap()), "{tag}: cell {i}");
            }
            let ecost = sc["cap"]["cost"].as_f64().unwrap();
            assert!((got.cost_s - ecost).abs() <= 1e-6 * ecost.max(1.0), "{tag}: cost {} vs {}", got.cost_s, ecost);
            let em = exp["total_effort_minutes"].as_f64().unwrap();
            assert!((got.total_effort_minutes - em).abs() <= 1e-6 * em.max(1.0), "{tag}: minutes");
            let ed = exp["total_distance_km"].as_f64().unwrap();
            assert!((got.total_distance_km - ed).abs() <= 1e-9 * ed.max(1.0), "{tag}: distance {} vs {}", got.total_distance_km, ed);
            let mset: Vec<String> = exp["selected_mode_set"].as_array().unwrap().iter().map(|x| x.as_str().unwrap().into()).collect();
            assert_eq!(got.selected_mode_set, mset, "{tag}: mode set");
            let ecomb = exp["combined"].as_array().unwrap();
            assert_eq!(got.combined.len(), ecomb.len(), "{tag}: combined len");
            for (c, e) in got.combined.iter().zip(ecomb) {
                assert!((c.0 - e[0].as_f64().unwrap()).abs() < 1e-12 && (c.1 - e[1].as_f64().unwrap()).abs() < 1e-12, "{tag}: coords");
            }
            let eseg = exp["segments"].as_array().unwrap();
            assert_eq!(got.segments.len(), eseg.len(), "{tag}: segments");
            for (g, e) in got.segments.iter().zip(eseg) {
                assert_eq!((g.mode.name(), g.coords.len() as u64), (e[0].as_str().unwrap(), e[1].as_u64().unwrap()), "{tag}: segment");
            }
            let etr = exp["transitions"].as_array().unwrap();
            assert_eq!(got.transitions.len(), etr.len(), "{tag}: transitions");
            for (g, e) in got.transitions.iter().zip(etr) {
                assert_eq!((g.from_mode.name(), g.to_mode.name()), (e[2].as_str().unwrap(), e[3].as_str().unwrap()));
                assert!((g.lat - e[0].as_f64().unwrap()).abs() < 1e-12);
            }
            assert_eq!(got.stats.transition_cells, sc["cap"]["trans"].as_array().unwrap().len(), "{tag}: transition cell count");
            checked += 1;
        }
    }
    assert!(checked >= 9, "ran {checked} scenarios");
}
