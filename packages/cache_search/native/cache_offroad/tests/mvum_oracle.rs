//! MVUM access grids vs navi's `_row_access` + `_rasterize_feature` on random features.
mod common;
use cache_offroad::grid::GridMeta;
use cache_offroad::mvum::*;
use cache_offroad::pack::MvumFeature;

fn s(v: &serde_json::Value) -> Option<String> {
    v.as_str().map(|x| x.to_string())
}

#[test]
fn mvum_grids_match_navi() {
    let j = common::load_gz(include_bytes!("fixtures/mvum_cases.json.gz"));
    let (rows, cols) = (j["rows"].as_u64().unwrap() as usize, j["cols"].as_u64().unwrap() as usize);
    let (south, west) = (j["south"].as_f64().unwrap(), j["west"].as_f64().unwrap());
    let (dlat, dlon) = (j["dlat"].as_f64().unwrap(), j["dlon"].as_f64().unwrap());
    let north = south + rows as f64 * dlat;
    let meta = GridMeta {
        bounds: (south, north, west, west + cols as f64 * dlon),
        pixel_size_lat: -dlat, pixel_size_lon: dlon,
        origin_lat: north - 0.5 * dlat, origin_lon: west + 0.5 * dlon,
        cell_size_m: 13.4, rows, cols, global_row0: 0, global_col0: 0,
    };
    let feats: Vec<MvumFeature> = j["features"].as_array().unwrap().iter().map(|f| {
        let r = &f["row"];
        MvumFeature {
            is_trail: false, symbol: s(&r["symbol"]).filter(|x| !x.is_empty()).or(None), seasonal: s(&r["seasonal"]),
            access: [(s(&r["e_bike_class1"]), s(&r["e_bike_class1_dur"])), (s(&r["atv"]), s(&r["atv_datesopen"])),
                     (s(&r["highclearancevehicle"]), s(&r["highclearancevehicle_datesopen"]))],
            lines: f["lines"].as_array().unwrap().iter().map(|l| l.as_array().unwrap().iter()
                .map(|p| (p[0].as_f64().unwrap(), p[1].as_f64().unwrap())).collect()).collect(),
        }
    }).collect();
    for o in j["out"].as_array().unwrap() {
        let cd = if o["check"].is_null() { None } else { Some((o["check"][0].as_u64().unwrap() as u32, o["check"][1].as_u64().unwrap() as u32)) };
        let g = access_grids(&feats, &meta, cd);
        for (i, name) in MVUM_MODES.iter().enumerate() {
            let exp = common::u8s(&o["grids"][*name]);
            let diff = g[i].iter().zip(&exp).filter(|(a, b)| a != b).count();
            assert_eq!(diff, 0, "mode {name} check {cd:?}: {diff} cells differ");
        }
    }
}

#[test]
fn date_ranges() {
    assert_eq!(parse_date_range("05/01-11/30"), vec![(5, 1, 11, 30)]);
    assert_eq!(parse_date_range("06/15-10/15,12/01-03/31").len(), 2);
    assert!(parse_date_range("garbage").is_empty());
    assert!(is_date_in_range(1, 15, &parse_date_range("12/01-03/31")));
    assert!(!is_date_in_range(7, 15, &parse_date_range("12/01-03/31")));
    assert_eq!(check_access(Some("open"), Some("05/01-11/30"), None, Some((7, 1))), Some(true));
    assert_eq!(check_access(Some("open"), Some("05/01-11/30"), None, Some((1, 1))), Some(false));
    assert_eq!(check_access(Some(""), None, None, None), None);
    assert_eq!(check_access(Some("no"), None, None, None), Some(false));
    assert_eq!(symbol_to_access(Some("2"), "atv"), Some(false));
    assert_eq!(symbol_to_access(Some("2"), "vehicle"), Some(true));
    assert_eq!(symbol_to_access(Some("7"), "vehicle"), None);
}
