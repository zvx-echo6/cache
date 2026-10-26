//! Real fetches (OpenFreeMap, Mapterhorn, ESA WorldCover) for a small area around Burley, Idaho.
//! `cargo test -p cache_layers --test real_burley -- --ignored --nocapture`

mod common;
use cache_layers::offroad::{DownloadedTerrain, TerrainSource};
use cache_layers::{AreaReq, Done, Inner, LayersCfg, TileOut};
use common::*;
use std::sync::Arc;
use std::time::Instant;

const TOWN: (f64, f64) = (-113.7926, 42.5365); // lon, lat
const BOX: &str = "[-113.85,42.51,-113.73,42.57]";

fn lonlat_tile(z: u8, lon: f64, lat: f64) -> (u32, u32) {
    let n = (1u64 << z) as f64;
    let x = ((lon + 180.0) / 360.0 * n).floor() as u32;
    let y = ((1.0 - (lat.to_radians().tan() + 1.0 / lat.to_radians().cos()).ln() / std::f64::consts::PI) / 2.0 * n).floor() as u32;
    (x, y)
}

fn download(inner: &Inner, layer: &str, area: &str, zmin: u8, zmax: u8) {
    let req = AreaReq::parse(&format!(r#"{{"layer":"{layer}","area":"{area}","name":"Burley","bbox":{BOX},"minzoom":{zmin},"maxzoom":{zmax}}}"#)).unwrap();
    let plan = inner.plan(&req).unwrap();
    println!("PLAN {layer}: tiles={} present={} estimated_bytes={} method={} ok={} problems={}", plan["tiles"], plan["tiles_present"], plan["estimated_bytes"], plan["estimate_method"], plan["ok_to_start"], plan["problems"]);
    let t = Instant::now();
    let r = inner.run_download(&req, &|_, _, _| {}, &|| false).unwrap();
    assert!(matches!(r, Done::Finished));
    let a = inner.areas(&inner.base_of(layer).unwrap().id);
    let m = &a.iter().find(|x| x.id == area).unwrap().meta;
    println!("DOWNLOADED {layer}: tiles_requested={} tiles_present={} bytes={} store_file_bytes={} seconds={:.1}", m["tiles_requested"], m["tiles_present"], m["bytes"], std::fs::metadata(inner.store_path(&inner.base_of(layer).unwrap().id)).unwrap().len(), t.elapsed().as_secs_f32());
}

#[test]
#[ignore]
fn burley_base_map_elevation_contours_landcover() {
    let sc = Scratch::new("burley");
    let inner = Arc::new(
        Inner::open(LayersCfg {
            dir: sc.path("l").to_string_lossy().into_owned(),
            defs_dirs: vec![concat!(env!("CARGO_MANIFEST_DIR"), "/../../layers").to_string()],
            catalogue_urls: vec![],
            cache_max_bytes: 64 << 20,
            online: true,
        })
        .unwrap(),
    );
    assert_eq!(inner.list()["invalid"].as_array().unwrap().len(), 0);

    // base map and elevation downloads
    download(&inner, "openfreemap", "burley", 0, 14);
    download(&inner, "elevation", "burley", 0, 12);

    // offline from here on
    inner.set_online(false);
    let (x14, y14) = lonlat_tile(14, TOWN.0, TOWN.1);
    match inner.tile("openfreemap", 14, x14, y14).unwrap() {
        TileOut::Tile { bytes, from, .. } => println!("BASE TILE 14/{x14}/{y14}: {} bytes (MVT, un-gzipped) from {from}", bytes.len()),
        _ => panic!("base tile missing offline"),
    }
    // the TileJSON of the layers, offline
    let tj = inner.tilejson("openfreemap", "http://127.0.0.1:1").unwrap();
    println!("TILEJSON openfreemap: type={} minzoom={} maxzoom={} attribution={} vector_layers={}", tj["type"], tj["minzoom"], tj["maxzoom"], tj["attribution"], tj["vector_layers"].as_array().map(|a| a.len()).unwrap_or(0));
    let tj = inner.tilejson("hillshade", "http://127.0.0.1:1").unwrap();
    println!("TILEJSON hillshade: type={} encoding={} tileSize={}", tj["type"], tj["encoding"], tj["tileSize"]);

    // the elevation under the town
    let (x12, y12) = lonlat_tile(12, TOWN.0, TOWN.1);
    let TileOut::Tile { bytes, from, .. } = inner.tile("elevation", 12, x12, y12).unwrap() else { panic!("no elevation tile") };
    let dem = cache_layers::contour::decode_terrarium(&bytes).unwrap();
    let b = cache_layers::core::tile_bbox(12, x12, y12);
    let px = ((TOWN.0 - b[0]) / (b[2] - b[0]) * dem.w as f64) as i64;
    let lat_to_y = |lat: f64| (1.0 - (lat.to_radians().tan() + 1.0 / lat.to_radians().cos()).ln() / std::f64::consts::PI) / 2.0 * (1u64 << 12) as f64;
    let py = ((lat_to_y(TOWN.1) - y12 as f64) * dem.h as f64) as i64;
    let m = dem.get(px, py);
    let ft = m as f64 * cache_layers::contour::FEET_PER_METER;
    println!("ELEVATION 12/{x12}/{y12} ({}x{}, from {from}): town centre {m:.1} m = {ft:.0} ft", dem.w, dem.h);
    assert!((4100.0..=4200.0).contains(&ft), "Burley should be about 4,100-4,200 ft, got {ft}");

    // contours at several zooms, from the downloaded elevation
    for z in [10u8, 12, 13, 14, 15] {
        let (x, y) = lonlat_tile(z, TOWN.0, TOWN.1);
        let t = Instant::now();
        match inner.tile("contours", z, x, y).unwrap() {
            TileOut::Tile { bytes, .. } => {
                let f = cache_layers::contour::decode_mvt(&bytes).unwrap();
                let eles: Vec<i64> = f.iter().map(|x| x.0).collect();
                let lines: usize = f.iter().map(|x| x.2.len()).sum();
                let pts: usize = f.iter().flat_map(|x| x.2.iter()).map(|l| l.len()).sum();
                let idx: Vec<i64> = f.iter().filter(|x| x.1 == 1).map(|x| x.0).collect();
                println!("CONTOURS {z}/{x}/{y}: {} bytes, {} elevations {:?}, index {:?}, {lines} lines, {pts} points, {:.0} ms", bytes.len(), eles.len(), eles, idx, t.elapsed().as_secs_f32() * 1000.0);
                if z >= 12 {
                    assert!(eles.iter().all(|e| (3900..=4800).contains(e)), "{eles:?}");
                }
            }
            TileOut::Empty => println!("CONTOURS {z}/{x}/{y}: empty"),
            _ => panic!("contour miss"),
        }
    }

    // land cover: a real window out of the COG, then an area download
    inner.set_online(true);
    let (xl, yl) = lonlat_tile(11, TOWN.0, TOWN.1);
    let t = Instant::now();
    let TileOut::Tile { bytes, .. } = inner.tile("landcover", 11, xl, yl).unwrap() else { panic!("no land cover tile") };
    let (w, h, px) = cache_layers::cog::decode_indexed_png(&bytes).unwrap();
    let mut counts = std::collections::BTreeMap::new();
    for v in &px {
        *counts.entry(*v).or_insert(0usize) += 1;
    }
    println!("LANDCOVER 11/{xl}/{yl}: {w}x{h}, {} bytes png, {:.1} s, classes {:?}", bytes.len(), t.elapsed().as_secs_f32(), counts);
    assert!(counts.contains_key(&40) || counts.contains_key(&30) || counts.contains_key(&50), "Burley is farmland and town: {counts:?}");
    download(&inner, "landcover", "burley", 8, 12);

    // the off-road reader over the downloads
    inner.set_online(false);
    let terrain = DownloadedTerrain::new(inner.clone(), "elevation", Some("landcover"));
    let bx = [-113.81, 42.525, -113.77, 42.55];
    let t = Instant::now();
    let e = terrain.elevation_m(bx, 30.0).unwrap();
    let valid: Vec<f32> = e.data.iter().copied().filter(|v| !v.is_nan()).collect();
    let (lo, hi) = (valid.iter().cloned().fold(f32::MAX, f32::min), valid.iter().cloned().fold(f32::MIN, f32::max));
    println!("OFFROAD elevation: {}x{} cells at 30 m (source zoom {}), {} valid, {lo:.0}..{hi:.0} m, {:.0} ms", e.cols, e.rows, e.source_zoom, valid.len(), t.elapsed().as_secs_f32() * 1000.0);
    assert_eq!(valid.len(), e.data.len());
    assert!(lo > 1150.0 && hi < 1400.0);
    let c = terrain.land_cover(bx, 30.0).unwrap();
    let mut cc = std::collections::BTreeMap::new();
    for v in &c.data {
        *cc.entry(*v).or_insert(0usize) += 1;
    }
    println!("OFFROAD land cover: {}x{} cells (source zoom {}), classes {:?}", c.cols, c.rows, c.source_zoom, cc);
    println!("OFFROAD coverage: {:?}", terrain.coverage());
}

/// The built layers on R2: refresh the catalogue, stream tiles through the local tile server, then download a small box.
#[test]
#[ignore]
fn r2_catalogue_layers_stream_and_download() {
    let sc = Scratch::new("r2");
    let cfg: LayersCfg = serde_json::from_value(serde_json::json!({
        "dir": sc.path("l").to_string_lossy(),
        "defs_dirs": [concat!(env!("CARGO_MANIFEST_DIR"), "/../../layers")],
    }))
    .unwrap();
    assert_eq!(cfg.catalogue_urls, vec!["https://cache.echo6.co/catalogue.json".to_string()]);
    let layers = cache_layers::Layers::new(cfg).unwrap();
    let inner = layers.inner.clone();
    let before = inner.list()["layers"].as_array().unwrap().len();
    let r = inner.refresh().unwrap();
    println!("REFRESH: {}", r["catalogues"]);
    let l = inner.list();
    let all = l["layers"].as_array().unwrap();
    println!("LAYERS: {before} starter, {} after merging the catalogue; invalid: {}", all.len(), l["invalid"]);
    let server = layers.serve().unwrap();
    let base = server["base_url"].as_str().unwrap().to_string();
    let (lon, lat) = TOWN;
    let mut streamed = 0;
    for x in all.iter().filter(|x| x["origin"] == "catalogue") {
        let d = &x["definition"];
        let id = d["id"].as_str().unwrap();
        let bb = d["coverage"]["bbox"].as_array().map(|b| b.iter().map(|v| v.as_f64().unwrap()).collect::<Vec<_>>()).unwrap_or(vec![-180.0, -90.0, 180.0, 90.0]);
        let covers = lon >= bb[0] && lon <= bb[2] && lat >= bb[1] && lat <= bb[3];
        println!("\nLAYER {id}: {} source={} z{}-{} covers Burley={covers} version={}", d["title"], d["source"]["type"], d["source"]["minzoom"], d["source"]["maxzoom"], d["update"]["version"]);
        if !covers || d["source"]["type"] != "pmtiles" {
            continue;
        }
        let tj = ureq::get(&format!("{base}/layers/{id}/tilejson.json")).call().unwrap().into_string().unwrap();
        let tj: serde_json::Value = serde_json::from_str(&tj).unwrap();
        println!("  TILEJSON type={} zoom {}-{} attribution={}", tj["type"], tj["minzoom"], tj["maxzoom"], tj["attribution"].as_str().unwrap_or("").chars().take(60).collect::<String>());
        let (zmin, zmax) = (d["source"]["minzoom"].as_u64().unwrap() as u8, d["source"]["maxzoom"].as_u64().unwrap() as u8);
        for z in [zmin.max(8), zmax.min(12), zmax] {
            let (tx, ty) = lonlat_tile(z, lon, lat);
            for pass in ["first", "again"] {
                let t = Instant::now();
                let (st, n, from) = match ureq::get(&format!("{base}/layers/{id}/{z}/{tx}/{ty}")).call() {
                    Ok(r) => {
                        let from = r.header("X-Cache-Status").unwrap_or("").to_string();
                        let st = r.status();
                        let mut b = Vec::new();
                        std::io::Read::read_to_end(&mut r.into_reader(), &mut b).unwrap();
                        (st, b.len(), from)
                    }
                    Err(e) => panic!("{id} {z}/{tx}/{ty}: {e}"),
                };
                println!("  TILE {z}/{tx}/{ty} {pass}: HTTP {st}, {n} bytes, {from}, {:.0} ms", t.elapsed().as_secs_f32() * 1000.0);
            }
        }
        streamed += 1;
        // a small box around the town
        let req = AreaReq::parse(&format!(r#"{{"layer":"{id}","area":"burley","name":"Burley","bbox":[-113.82,42.52,-113.76,42.55],"minzoom":{zmin},"maxzoom":{zmax}}}"#)).unwrap();
        let plan = inner.plan(&req).unwrap();
        println!("  PLAN tiles={} present={} estimated_bytes={} method={} ok={}", plan["tiles"], plan["tiles_present"], plan["estimated_bytes"], plan["estimate_method"], plan["ok_to_start"]);
        let t = Instant::now();
        let res = inner.run_download(&req, &|_, _, _| {}, &|| false).unwrap();
        assert!(matches!(res, Done::Finished));
        let a = inner.areas_fresh(id);
        let m = &a[0].meta;
        println!("  DOWNLOADED tiles_present={} bytes={} in {:.1} s", m["tiles_present"], m["bytes"], t.elapsed().as_secs_f32());
        // now it comes from the download with no connection
        inner.set_online(false);
        let (tx, ty) = lonlat_tile(zmax.min(12), lon, lat);
        match inner.tile(id, zmax.min(12), tx, ty).unwrap() {
            TileOut::Tile { bytes, from, .. } => println!("  OFFLINE TILE {}/{tx}/{ty}: {} bytes from {from}", zmax.min(12), bytes.len()),
            TileOut::Empty => println!("  OFFLINE TILE {}/{tx}/{ty}: empty (no features there)", zmax.min(12)),
            _ => panic!("offline miss after download"),
        }
        inner.set_online(true);
    }
    assert!(streamed > 0, "at least one catalogue layer covering Burley should have streamed");
}
