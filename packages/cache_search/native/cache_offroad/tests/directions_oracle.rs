//! Directions port vs navi: `pieces_from_result`, `_path_detail`, `offroad_steps` and `_assemble_offroad`
//! (road pieces through a deterministic fake Valhalla, follow legs through a fake namer) on routes of the
//! synthetic worlds, recorded from navi's own code by gen_directions.py.
mod common;
use cache_offroad::cost::Mode;
use cache_offroad::directions::*;
use cache_offroad::grid::GridMeta;
use cache_offroad::offroad_legs::*;
use cache_offroad::pack::MemPack;
use cache_offroad::router::*;
use cache_offroad::valhalla::*;
use serde_json::Value;
use std::collections::BTreeSet;
use std::time::Instant;

struct Fake;
impl Valhalla for Fake {
    fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
        None
    }
    fn route(&self, a: (f64, f64), b: (f64, f64), _c: &str) -> Result<Trip, ValhallaError> {
        let mid = ((a.0 + b.0) / 2.0 + 0.0004, (a.1 + b.1) / 2.0 - 0.0003);
        let enc = encode_polyline6(&[a, mid, b]);
        let shape = decode_polyline6(&enc);
        let h = |p: (f64, f64), q: (f64, f64)| cache_offroad::grid::haversine_m(p.0, p.1, q.0, q.1);
        let (d0, d1) = (h(shape[0], shape[1]) / 1000.0, h(shape[1], shape[2]) / 1000.0);
        let mans = vec![
            Maneuver { kind: 1, instruction: "Drive north.".into(), street_names: vec!["Test Rd".into()], bearing_after: Some(10.4), begin_shape_index: 0, end_shape_index: 1, length_km: d0, time_s: d0 * 60.0 + 0.4, ..Default::default() },
            Maneuver { kind: 15, instruction: "Turn left onto X St.".into(), street_names: vec!["X St".into(), "Alt".into()], bearing_before: Some(11.0), begin_shape_index: 1, end_shape_index: 2, length_km: d1, time_s: d1 * 60.0 + 0.6, ..Default::default() },
            Maneuver { kind: 4, instruction: "Your destination is on the right.".into(), bearing_before: Some(200.0), begin_shape_index: 2, end_shape_index: 2, ..Default::default() },
        ];
        Ok(Trip { shape, shape_encoded: enc, maneuvers: mans, length_km: d0 + d1, time_s: d0 * 60.0 + d1 * 60.0 + 1.0 })
    }
    fn trace_attributes(&self, _: &str) -> Result<Trace, ValhallaError> {
        Err(ValhallaError::msg("n/a"))
    }
}

fn close(a: &Value, b: &Value, path: &str) {
    match (a, b) {
        (Value::Number(x), Value::Number(y)) => {
            let (x, y) = (x.as_f64().unwrap(), y.as_f64().unwrap());
            assert!((x - y).abs() <= 1e-9 * y.abs().max(1.0), "{path}: {x} vs {y}");
        }
        (Value::Array(x), Value::Array(y)) => {
            assert_eq!(x.len(), y.len(), "{path}: array length");
            for (i, (p, q)) in x.iter().zip(y).enumerate() {
                close(p, q, &format!("{path}[{i}]"));
            }
        }
        (Value::Object(x), Value::Object(y)) => {
            let kx: BTreeSet<_> = x.keys().collect();
            let ky: BTreeSet<_> = y.keys().collect();
            assert_eq!(kx, ky, "{path}: keys");
            for k in x.keys() {
                close(&x[k], &y[k], &format!("{path}.{k}"));
            }
        }
        _ => assert_eq!(a, b, "{path}"),
    }
}

#[test]
fn directions_assembly_matches_navi() {
    let worlds = common::load_gz(include_bytes!("fixtures/oracle_cases.json.gz"));
    let cases = common::load_gz(include_bytes!("fixtures/directions_cases.json.gz"));
    let mut n_checked = 0;
    let mut kinds = BTreeSet::new();
    for c in cases.as_array().unwrap() {
        let world = worlds.as_array().unwrap().iter().find(|w| w["name"] == c["case"]).unwrap();
        let (rows, cols) = (world["rows"].as_u64().unwrap() as usize, world["cols"].as_u64().unwrap() as usize);
        let m = &world["meta"];
        let f = |k: &str| m[k].as_f64().unwrap();
        let meta = GridMeta {
            bounds: (f("south"), f("north"), f("west"), f("east")), pixel_size_lat: f("pixel_size_lat"), pixel_size_lon: f("pixel_size_lon"),
            origin_lat: f("origin_lat"), origin_lon: f("origin_lon"), cell_size_m: f("cell_size_m"), rows, cols, global_row0: 0, global_col0: 0,
        };
        let mut pack = MemPack::blank(rows, cols, 0.0);
        pack.elev = common::f32_from_bits(if c["flat_elev"].is_null() { &world["elev"] } else { &c["flat_elev"] });
        pack.friction = common::u8s(&world["friction"]);
        pack.class = Some(common::u8s(&world["class"]));
        pack.trails = common::u8s(&world["trails"]);
        pack.barriers = common::u8s(&world["barriers"]);
        pack.wilderness = Some(common::u8s(&world["wilderness"]));
        let pts = |k: &str, kind: &str| -> Vec<cache_offroad::pack::PointRec> {
            world[k].as_array().unwrap().iter().map(|p| cache_offroad::pack::PointRec {
                lat: p["lat"].as_f64().unwrap(), lon: p["lon"].as_f64().unwrap(), name: p["name"].as_str().unwrap().into(),
                kind: kind.into(), access: p.get("access").and_then(|a| a.as_str()).unwrap_or("").into(),
            }).collect()
        };
        pack.parking = pts("parking", "surface");
        pack.trailheads = pts("trailheads", "track");
        let s = &c["sc"];
        let start = (c["start_ll"][0].as_f64().unwrap(), c["start_ll"][1].as_f64().unwrap());
        let end = (c["end_ll"][0].as_f64().unwrap(), c["end_ll"][1].as_f64().unwrap());
        let mut req = RouteRequest::new(start, end, RequestMode::Auto, Boundary::from_name(s["boundary"].as_str().unwrap()).unwrap());
        req.collect_detail = true;
        let modes = |v: &Value| -> BTreeSet<usize> { v.as_array().unwrap().iter().map(|x| Mode::from_name(x.as_str().unwrap()).unwrap().idx()).chain([0]).collect() };
        if let Some(a) = s.get("affinity").filter(|a| a.is_object()) {
            req.network_affinity = Some(a.as_object().unwrap().iter().map(|(k, v)| (Mode::from_name(k).unwrap(), v.as_f64().unwrap())).collect());
        }
        let router = Router { pack: &pack, elevation: &pack, valhalla: &cache_offroad::StubValhalla, opts: RouteOptions::default() };
        let res = router.search_on_grid(&req, meta, &modes(&s["start_modes"]), &modes(&s["end_modes"]), Instant::now()).unwrap();
        let tag = format!("{} #{} merge {}", c["case"], c["sc_index"], c["merge"]);

        // path detail vs navi's _path_detail
        let d = res.detail.as_ref().unwrap();
        let ed = &c["detail"];
        let n = d.lat.len();
        assert_eq!(n, ed["lat"].as_array().unwrap().len(), "{tag}: detail length");
        for i in 0..n {
            assert!((d.lat[i] - ed["lat"][i].as_f64().unwrap()).abs() < 1e-12 && (d.lon[i] - ed["lon"][i].as_f64().unwrap()).abs() < 1e-12, "{tag}: latlon {i}");
            assert_eq!(d.mode[i].name(), ed["mode"][i].as_str().unwrap(), "{tag}: mode {i}");
            match (&d.elev[i], &ed["elev"][i]) {
                (Some(a), Value::Number(b)) => assert!((a - b.as_f64().unwrap()).abs() < 1e-9, "{tag}: elev"),
                (None, Value::Null) => {}
                other => panic!("{tag}: elev {other:?}"),
            }
            assert_eq!(d.terrain[i] as u64, ed["terrain"][i].as_u64().unwrap(), "{tag}: terrain");
            assert_eq!(d.trail[i] as u64, ed["trail"][i].as_u64().unwrap(), "{tag}: trail");
        }
        for i in 0..n - 1 {
            let e = ed["step_s"][i].as_f64().unwrap();
            assert!((d.step_s[i] - e).abs() <= 1e-6 * e.abs().max(1.0), "{tag}: step_s {i}: {} vs {e}", d.step_s[i]);
        }

        // pieces + assembly
        let pieces = pieces_from_result(&res);
        let ep = c["pieces"].as_array().unwrap();
        assert_eq!(pieces.len(), ep.len(), "{tag}: pieces");
        for (p, e) in pieces.iter().zip(ep) {
            let ty = match p.kind { PieceKind::Road { .. } => "road", _ => "offroad" };
            assert_eq!((ty, p.mode.as_str()), (e["type"].as_str().unwrap(), e["mode"].as_str().unwrap()), "{tag}");
            assert!((p.extra_s - e["extra_s"].as_f64().unwrap()).abs() < 1e-6, "{tag}: extra_s");
            kinds.insert(format!("{ty}:{}", p.mode));
        }
        let namer = |pts: &[(f64, f64)], kind: &str| -> Option<Vec<Option<String>>> {
            Some(pts.iter().map(|(la, _)| if kind != "trail" { Some(format!("Rd{}", ((la.abs() * 2000.0) as i64) % 3)) } else { None }).collect())
        };
        let env = Env { pack: &pack, elevation: &pack, valhalla: &Fake, options: RouteOptions::default(), namer: Some(&namer), version: "t".into() };
        let mut dr = DirectionsRequest::new(start, end, TravelMode::Drive);
        dr.merge_bearing_deg = c["merge"].as_f64().unwrap();
        dr.min_leg_m = c["min_leg"].as_f64().unwrap();
        let asm = env.assemble_offroad(&pieces, &dr).unwrap_or_else(|e| panic!("{tag}: {e:?}"));
        let got: Vec<Value> = asm.steps.iter().map(|s| s.to_json()).collect();
        let exp = c["steps"].as_array().unwrap();
        assert_eq!(got.len(), exp.len(), "{tag}: step count");
        for (i, (g, e)) in got.iter().zip(exp).enumerate() {
            close(g, e, &format!("{tag} step {i}"));
        }
        let eshape = c["shape"].as_array().unwrap();
        assert_eq!(asm.shape.len(), eshape.len(), "{tag}: shape");
        assert!((asm.km - c["km"].as_f64().unwrap()).abs() < 1e-6, "{tag}: km");
        n_checked += 1;
    }
    assert!(n_checked >= 20);
    assert!(kinds.contains("road:vehicle") && kinds.contains("offroad:foot") && kinds.contains("offroad:4w"), "{kinds:?}");
}
