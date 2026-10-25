//! Surface-change candidates vs navi `mvum_surface_change` (classification table, chunk joining, boundary
//! extraction) with a deterministic fake `trace_attributes`; polyline6 codec.
use cache_offroad::surface::*;
use cache_offroad::valhalla::*;
use serde_json::Value;

struct FakeTrace;
impl Valhalla for FakeTrace {
    fn locate(&self, _: f64, _: f64, _: &str) -> Option<LocateSnap> {
        None
    }
    fn route(&self, _: (f64, f64), _: (f64, f64), _: &str) -> Result<Trip, ValhallaError> {
        Err(ValhallaError::msg("n/a"))
    }
    fn trace_attributes(&self, enc: &str) -> Result<Trace, ValhallaError> {
        let coords = decode_polyline6(enc);
        let n = coords.len();
        let mut edges = Vec::new();
        let mut i = 0;
        while i + 1 < n {
            let j = (n - 1).min(i + 7);
            let k = ((coords[i].0.abs() * 1e5) as i64) % 4;
            let (u, rc, surf) = [("road", "residential", "paved_smooth"), ("road", "tertiary", "gravel"), ("track", "service_other", "dirt"), ("footway", "path", "path")][k as usize];
            edges.push(TraceEdge { use_: Some(u.into()), road_class: Some(rc.into()), surface: Some(surf.into()), begin_shape_index: Some(i as i64), end_shape_index: Some(j as i64) });
            i = j;
        }
        Ok(Trace { edges, shape: Some(enc.to_string()) })
    }
}

#[test]
fn classify_and_chunks_match_navi() {
    let j: Value = serde_json::from_str(include_str!("fixtures/surface_cases.json")).unwrap();
    for c in j["classify"].as_array().unwrap() {
        let e = TraceEdge {
            use_: Some(c["use"].as_str().unwrap().into()), road_class: Some(c["road_class"].as_str().unwrap().into()),
            surface: Some(c["surface"].as_str().unwrap().into()), ..Default::default()
        };
        let got = classify_surface(&e).map(|c| c.name().to_uppercase());
        assert_eq!(got.as_deref(), c["cat"].as_str(), "{c}");
    }
    for case in j["cases"].as_array().unwrap() {
        let coords: Vec<(f64, f64)> = case["coords"].as_array().unwrap().iter().map(|p| (p[0].as_f64().unwrap(), p[1].as_f64().unwrap())).collect();
        let got = get_surface_change_candidates_with(&FakeTrace, &coords, 40, 2000.0);
        let exp = case["cands"].as_array().unwrap();
        assert_eq!(got.len(), exp.len());
        for (g, e) in got.iter().zip(exp) {
            assert!((g.0 - e[0].as_f64().unwrap()).abs() < 1e-9 && (g.1 - e[1].as_f64().unwrap()).abs() < 1e-9);
            assert_eq!(format!("Surface change: {}→{}", g.2.name(), g.3.name()), e[2].as_str().unwrap());
        }
    }
}

#[test]
fn polyline6_matches_navi() {
    let j: Value = serde_json::from_str(include_str!("fixtures/surface_cases.json")).unwrap();
    let pts = [(44.123456, -115.654321), (44.1235, -115.6542), (43.99, -115.7)];
    assert_eq!(encode_polyline6(&pts), j["poly"]["enc"].as_str().unwrap());
    let dec = decode_polyline6(j["poly"]["enc"].as_str().unwrap());
    for (d, e) in dec.iter().zip(j["poly"]["dec"].as_array().unwrap()) {
        assert!((d.0 - e[0].as_f64().unwrap()).abs() < 1e-9 && (d.1 - e[1].as_f64().unwrap()).abs() < 1e-9);
    }
}
