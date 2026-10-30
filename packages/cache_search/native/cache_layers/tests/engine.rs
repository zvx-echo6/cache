//! Engine tests against fake tile hosts on 127.0.0.1 (no real network).

mod common;
use cache_layers::pmtiles::{self, Header, Writer};
use cache_layers::{AreaReq, Done, Layers, TileOut};
use common::*;
use serde_json::{json, Value};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

fn xyz_def(id: &str, port: u16, extra: Value) -> String {
    let mut d = json!({
        "format": 1, "id": id, "title": id, "kind": "vector", "transform": "as_is",
        "source": {"type": "xyz", "url": format!("http://127.0.0.1:{port}/{{z}}/{{x}}/{{y}}"), "minzoom": 0, "maxzoom": 12, "tile_format": "mvt"},
        "attribution": "test", "license": "test", "update": {"version": "1"}
    });
    for (k, v) in extra.as_object().unwrap() {
        d[k] = v.clone();
    }
    d.to_string()
}

fn tile_body(z: u8, x: u32, y: u32) -> Vec<u8> {
    format!("tile-{z}-{x}-{y}-{}", "abc".repeat(((x + y) % 5) as usize + 1)).into_bytes()
}

fn tile_host(delay: u64) -> Fake {
    fake_host(delay, |url, _| match parse_zxy(url) {
        Some((z, x, y)) => (200, tile_body(z, x, y)),
        None => (404, vec![]),
    })
}

fn tile_bytes(o: TileOut) -> (Vec<u8>, &'static str) {
    match o {
        TileOut::Tile { bytes, from, .. } => (bytes, from),
        TileOut::Empty => panic!("empty"),
        TileOut::Miss => panic!("miss"),
        TileOut::NeedsConnection => panic!("needs connection"),
    }
}

#[test]
fn starter_definitions_all_load() {
    let sc = Scratch::new("starter");
    let inner = cache_layers::Inner::open(cache_layers::LayersCfg {
        dir: sc.path("l").to_string_lossy().into_owned(),
        defs_dirs: vec![concat!(env!("CARGO_MANIFEST_DIR"), "/../../layers").to_string()],
        catalogue_urls: vec![],
        cache_max_bytes: 1 << 20,
        online: false,
    })
    .unwrap();
    let l = inner.list();
    assert_eq!(l["invalid"].as_array().unwrap().len(), 0, "{}", l["invalid"]);
    let ids: Vec<&str> = l["layers"].as_array().unwrap().iter().map(|x| x["definition"]["id"].as_str().unwrap()).collect();
    for want in ["openfreemap", "elevation", "hillshade", "contours", "landcover", "usgs-imagery", "esri-world-imagery"] {
        assert!(ids.contains(&want), "{want} in {ids:?}");
    }
    let by = |id: &str| l["layers"].as_array().unwrap().iter().find(|x| x["definition"]["id"] == id).unwrap().clone();
    assert_eq!(by("esri-world-imagery")["definition"]["enabled_by_default"], false);
    assert_eq!(by("openfreemap")["definition"]["enabled_by_default"], false);
    assert_eq!(by("openfreemap")["definition"]["layout"], "openmaptiles");
    assert_eq!(by("esri-world-imagery")["downloadable"], false);
    assert_eq!(by("esri-world-imagery")["needs_connection"], true);
    assert_eq!(by("usgs-imagery")["definition"]["offline"]["max_tiles_per_download"], 100000);
    assert_eq!(by("hillshade")["download_layer"], "elevation");
    assert_eq!(by("openfreemap")["definition"]["offline"]["max_bytes_per_download"], 52428800);
    // TileJSON of the derived layers, without a network
    let tj = inner.tilejson("hillshade", "http://127.0.0.1:1").unwrap();
    assert_eq!((tj["type"].as_str(), tj["encoding"].as_str(), tj["tileSize"].as_u64()), (Some("raster-dem"), Some("terrarium"), Some(512)));
    let tj = inner.tilejson("contours", "http://127.0.0.1:1").unwrap();
    assert_eq!(tj["vector_layers"][0]["id"], "contours");
    assert_eq!((tj["minzoom"].as_u64(), tj["maxzoom"].as_u64()), (Some(3), Some(15)));
}

#[test]
fn catalogue_user_definitions_and_validation() {
    let sc = Scratch::new("cat");
    let defs = sc.path("defs");
    std::fs::create_dir_all(&defs).unwrap();
    let host = tile_host(0);
    std::fs::write(defs.join("a.json"), xyz_def("alpha", host.port, json!({}))).unwrap();
    std::fs::write(defs.join("bad.json"), r#"{"format":1,"id":"Bad Id","title":"x","kind":"vector","transform":"as_is"}"#).unwrap();
    std::fs::write(defs.join("notjson.json"), "{").unwrap();
    // a catalogue file holding a list
    let inner = cache_layers::Inner::open(cache_layers::LayersCfg {
        dir: sc.path("l").to_string_lossy().into_owned(),
        defs_dirs: vec![defs.to_string_lossy().into_owned()],
        catalogue_urls: vec![],
        cache_max_bytes: 1 << 20,
        online: false,
    })
    .unwrap();
    let l = inner.list();
    assert_eq!(l["layers"].as_array().unwrap().len(), 1);
    assert_eq!(l["invalid"].as_array().unwrap().len(), 2);
    assert_eq!(l["layers"][0]["origin"], "folder");
    // add a user definition, edit it, then remove it
    inner.save_user_def(&xyz_def("mine", host.port, json!({"title": "Mine"}))).unwrap();
    assert_eq!(inner.def("mine").unwrap().title, "Mine");
    inner.save_user_def(&xyz_def("mine", host.port, json!({"title": "Mine 2"}))).unwrap();
    assert_eq!(inner.def("mine").unwrap().title, "Mine 2");
    // a user definition overrides one with the same id
    inner.save_user_def(&xyz_def("alpha", host.port, json!({"title": "Mine over alpha"}))).unwrap();
    let l = inner.list();
    let alpha = l["layers"].as_array().unwrap().iter().find(|x| x["definition"]["id"] == "alpha").unwrap().clone();
    assert_eq!(alpha["origin"], "user");
    let e = inner.save_user_def(r#"{"format":1,"id":"x","title":"x","kind":"vector","transform":"as_is","source":{"type":"xyz","url":"http://example.com/{z}/{x}/{y}"}}"#).unwrap_err();
    assert_eq!(e.code, "bad_json");
    inner.remove_user_def("mine").unwrap();
    assert_eq!(inner.remove_user_def("mine").unwrap_err().code, "not_found");
    assert_eq!(inner.remove_user_def("beta").unwrap_err().code, "not_found");
    // the user's definitions survive a restart
    let again = cache_layers::Inner::open(inner.cfg.clone()).unwrap();
    assert_eq!(again.def("alpha").unwrap().title, "Mine over alpha");
}

#[test]
fn tile_order_cache_offline_and_user_agent() {
    let sc = Scratch::new("order");
    let host = tile_host(0);
    let inner = engine(&sc);
    inner.save_user_def(&xyz_def("base", host.port, json!({}))).unwrap();
    let (b, from) = tile_bytes(inner.tile("base", 5, 3, 4).unwrap());
    assert_eq!((b, from), (tile_body(5, 3, 4), "network"));
    let (_, from) = tile_bytes(inner.tile("base", 5, 3, 4).unwrap());
    assert_eq!(from, "cache");
    assert_eq!(host.stats.hits.load(Ordering::SeqCst), 1);
    assert!(host.stats.agents.lock().unwrap().iter().all(|a| a == &format!("Cache/{}", env!("CARGO_PKG_VERSION"))));
    let h = inner.health("base");
    assert_eq!((h["state"].as_str(), h["recent_requests"].as_u64(), h["recent_failures"].as_u64()), (Some("ok"), Some(1), Some(0)));
    assert_eq!(inner.health("never-used")["state"], "unknown");
    // offline: cached tile still comes, an unseen one is a clean miss, nothing is requested
    inner.set_online(false);
    assert_eq!(tile_bytes(inner.tile("base", 5, 3, 4).unwrap()).1, "cache");
    assert!(matches!(inner.tile("base", 5, 9, 9).unwrap(), TileOut::Miss));
    assert_eq!(host.stats.hits.load(Ordering::SeqCst), 1);
    // outside the zoom range of the layer: empty, no request
    inner.set_online(true);
    assert!(matches!(inner.tile("base", 13, 0, 0).unwrap(), TileOut::Empty));
    // online-only layers: pass-through with cache, "needs a connection" offline when not cached
    inner
        .save_user_def(&xyz_def("sat", host.port, json!({"kind": "online-raster", "transform": "online_only", "offline": {"allowed": false}})))
        .unwrap();
    tile_bytes(inner.tile("sat", 2, 1, 1).unwrap());
    inner.set_online(false);
    assert_eq!(tile_bytes(inner.tile("sat", 2, 1, 1).unwrap()).1, "cache");
    assert!(matches!(inner.tile("sat", 2, 0, 1).unwrap(), TileOut::NeedsConnection));
    let e = inner.plan(&AreaReq::parse(r#"{"layer":"sat","bbox":[-114,42,-113,43],"minzoom":0,"maxzoom":3}"#).unwrap()).unwrap_err();
    assert_eq!(e.code, "offline");
    // upstream "no tile" is remembered as empty
    inner.set_online(true);
}

#[test]
fn upstream_missing_tile_is_empty_and_remembered() {
    let sc = Scratch::new("empty");
    let host = fake_host(0, |_, _| (404, vec![]));
    let inner = engine(&sc);
    inner.save_user_def(&xyz_def("base", host.port, json!({}))).unwrap();
    assert!(matches!(inner.tile("base", 3, 1, 1).unwrap(), TileOut::Empty));
    assert!(matches!(inner.tile("base", 3, 1, 1).unwrap(), TileOut::Empty));
    assert_eq!(host.stats.hits.load(Ordering::SeqCst), 1);
}

#[test]
fn size_estimate_samples_every_zoom_and_skips_empty_tiles() {
    let sc = Scratch::new("estimate");
    let req = AreaReq::parse(&format!(r#"{{"layer":"half","name":"T",{BOX}}}"#)).unwrap();
    let cover = req.tiles(0, 10).unwrap();
    let inner = engine(&sc);
    // Half the tiles have nothing (404); the others are 1000 bytes. The empty ones must not pull the mean down.
    let half = fake_host(0, |url, _| match parse_zxy(url) {
        Some((_, x, y)) if (x + y) % 2 == 0 => (200, vec![7u8; 1000]),
        _ => (404, vec![]),
    });
    inner.save_user_def(&xyz_def("half", half.port, json!({"offline": {"allowed": true, "max_tiles_per_download": 100000}}))).unwrap();
    let plan = inner.plan(&req).unwrap();
    assert_eq!(plan["estimated_bytes"], cover.len() as u64 * 1000, "{plan}");
    assert_eq!(plan["estimate_method"], "sample of 16 tiles");
    assert_eq!(half.stats.hits.load(Ordering::SeqCst), 16);
    // Tiles grow with the zoom: every zoom is sampled, so each zoom counts at its own size.
    let grow = fake_host(0, |url, _| match parse_zxy(url) {
        Some((z, _, _)) => (200, vec![7u8; 100 * (z as usize + 1)]),
        None => (404, vec![]),
    });
    inner.save_user_def(&xyz_def("grow", grow.port, json!({"offline": {"allowed": true, "max_tiles_per_download": 100000}}))).unwrap();
    let plan = inner.plan(&AreaReq::parse(&format!(r#"{{"layer":"grow","name":"T",{BOX}}}"#)).unwrap()).unwrap();
    let want: u64 = cover.iter().map(|t| 100 * (t.1 as u64 + 1)).sum();
    assert_eq!(plan["estimated_bytes"], want, "{plan}");
}

fn run(inner: &cache_layers::Inner, req: &str, stop_after: Option<usize>) -> (cache_layers::Result<Done>, Vec<(u64, u64)>) {
    let req = AreaReq::parse(req).unwrap();
    let progress = std::sync::Mutex::new(Vec::new());
    let calls = AtomicUsize::new(0);
    let r = inner.run_download(
        &req,
        &|d, t, _| {
            progress.lock().unwrap().push((d, t));
            calls.fetch_add(1, Ordering::SeqCst);
        },
        &|| stop_after.map(|n| calls.load(Ordering::SeqCst) > n).unwrap_or(false),
    );
    (r, progress.into_inner().unwrap())
}

const BOX: &str = r#""bbox":[-115,41,-112,44],"minzoom":0,"maxzoom":10"#;

#[test]
fn plan_limits_download_serve_delete() {
    let sc = Scratch::new("dl");
    let host = tile_host(0);
    let inner = engine(&sc);
    inner.save_user_def(&xyz_def("base", host.port, json!({"offline": {"allowed": true, "max_tiles_per_download": 100000, "max_parallel": 3}}))).unwrap();
    let req = format!(r#"{{"layer":"base","name":"Test","area":"t1",{BOX}}}"#);
    let areq = AreaReq::parse(&req).unwrap();
    let n = areq.tiles(0, 10).unwrap().len() as u64;
    let plan = inner.plan(&areq).unwrap();
    assert_eq!(plan["tiles"], n);
    assert_eq!(plan["ok_to_start"], true, "{plan}");
    assert!(plan["estimated_bytes"].as_u64().unwrap() > 0);
    assert_eq!(plan["limits"]["max_parallel"], 3);
    assert!(plan["estimate_method"].as_str().unwrap().starts_with("sample"));
    assert_eq!(plan["per_zoom"]["0"], 1);
    // limits
    inner.save_user_def(&xyz_def("tiny", host.port, json!({"offline": {"allowed": true, "max_tiles_per_download": 5}}))).unwrap();
    let p = inner.plan(&AreaReq::parse(&req.replace("\"base\"", "\"tiny\"")).unwrap()).unwrap();
    assert_eq!(p["ok_to_start"], false);
    assert_eq!(p["problems"][0]["code"], "limit_exceeded");
    let hits_before = host.stats.hits.load(Ordering::SeqCst);
    let (r, _) = run(&inner, &req.replace("\"base\"", "\"tiny\""), None);
    assert_eq!(r.err().unwrap().code, "limit_exceeded");
    inner.save_user_def(&xyz_def("small", host.port, json!({"offline": {"allowed": true, "max_bytes_per_download": 100}}))).unwrap();
    let (r, _) = run(&inner, &req.replace("\"base\"", "\"small\""), None);
    assert_eq!(r.err().unwrap().code, "limit_exceeded");
    assert!(host.stats.hits.load(Ordering::SeqCst) < hits_before + 40, "only the plan's samples were fetched");
    // bad areas
    let no_area = AreaReq::parse(r#"{"layer":"base","minzoom":0}"#).unwrap();
    assert_eq!(inner.plan(&no_area).unwrap_err().code, "bad_json");
    assert_eq!(inner.plan(&AreaReq::parse(r#"{"layer":"base","bbox":[10,2,3,4],"minzoom":0}"#).unwrap()).unwrap_err().code, "bad_json");
    assert_eq!(inner.plan(&AreaReq::parse(r#"{"layer":"nope","bbox":[1,2,3,4],"minzoom":0}"#).unwrap()).unwrap_err().code, "not_found");

    // download
    let (r, progress) = run(&inner, &req, None);
    assert!(matches!(r.unwrap(), Done::Finished));
    assert_eq!(progress.last().unwrap(), &(n, n));
    let areas = inner.areas("base");
    assert_eq!(areas.len(), 1);
    assert_eq!(areas[0].meta["tiles_present"], n);
    assert_eq!(areas[0].meta["version"], "1");
    assert_eq!(areas[0].meta["name"], "Test");
    let st = inner.store_read("base").unwrap();
    assert_eq!(st.tile_count(), n);
    for (_, z, x, y) in areq.tiles(0, 10).unwrap() {
        let raw = st.get(z, x, y).unwrap().unwrap_or_else(|| panic!("missing {z}/{x}/{y}"));
        assert_eq!(gunzip(&raw), tile_body(z, x, y));
    }
    assert!(host.stats.max_in_flight.load(Ordering::SeqCst) <= 3, "per-layer parallel limit");
    // served from the download with no connection and no request
    inner.set_online(false);
    let hits = host.stats.hits.load(Ordering::SeqCst);
    let t8 = areq.tiles(8, 8).unwrap()[0];
    let (b, from) = tile_bytes(inner.tile("base", 8, t8.2, t8.3).unwrap());
    assert_eq!(from, "downloaded");
    assert_eq!(b, tile_body(8, t8.2, t8.3));
    assert_eq!(host.stats.hits.load(Ordering::SeqCst), hits);
    // listing shows it installed
    let l = inner.list();
    let me = l["layers"].as_array().unwrap().iter().find(|x| x["definition"]["id"] == "base").unwrap().clone();
    assert_eq!(me["installed"]["downloaded"], true);
    assert!(me["installed"]["bytes"].as_u64().unwrap() > 0);
    assert_eq!(me["update_available"], false);
    // an area inside the first one needs nothing new: no request, and the plan says what is already there
    inner.set_online(true);
    let inside = r#"{"layer":"base","area":"inner","name":"Inside","bbox":[-114.5,42.2,-113.5,42.8],"minzoom":4,"maxzoom":10}"#;
    let ip = inner.plan(&AreaReq::parse(inside).unwrap()).unwrap();
    assert_eq!((ip["tiles_to_download"].as_u64(), ip["estimated_bytes"].as_u64()), (Some(0), Some(0)), "{ip}");
    assert_eq!(ip["tiles_already"], ip["tiles"]);
    assert!(ip["already_bytes"].as_u64().unwrap() > 0);
    let hits = host.stats.hits.load(Ordering::SeqCst);
    let (r, _) = run(&inner, inside, None);
    assert!(matches!(r.unwrap(), Done::Finished));
    assert_eq!(host.stats.hits.load(Ordering::SeqCst), hits, "nothing was fetched");
    assert_eq!(inner.areas("base").len(), 2);
    // an area that overlaps the edge fetches only the part that is new
    let edge = r#"{"layer":"base","area":"edge","bbox":[-112.5,41,-111.5,44],"minzoom":6,"maxzoom":10}"#;
    let ep = inner.plan(&AreaReq::parse(edge).unwrap()).unwrap();
    assert!(ep["tiles_to_download"].as_u64().unwrap() > 0 && ep["tiles_to_download"].as_u64().unwrap() < ep["tiles"].as_u64().unwrap(), "{ep}");
    // delete the inner area: every tile is still covered by the big one
    let d = inner.delete_areas("base", Some("inner")).unwrap();
    assert_eq!(d["tiles_removed"], 0, "{d}");
    assert!(d["tiles_kept"].as_u64().unwrap() > 0);
    assert_eq!(st.tile_count(), n);
    // delete the big one: its tiles go and the file gives the space back
    let d = inner.delete_areas("base", Some("t1")).unwrap();
    assert!(d["freed_bytes"].as_u64().unwrap() > 0);
    assert_eq!(d["tiles_removed"], n);
    assert!(d["file_bytes_after"].as_u64().unwrap() < d["file_bytes_before"].as_u64().unwrap(), "{d}");
    assert_eq!(inner.areas("base").len(), 0);
    inner.set_online(false);
    assert!(matches!(inner.tile("base", 8, t8.2, t8.3).unwrap(), TileOut::Miss));
    assert_eq!(inner.delete_areas("base", Some("t1")).unwrap_err().code, "not_found");
}

#[test]
fn parallel_limit_is_kept() {
    let sc = Scratch::new("par");
    let host = tile_host(25);
    let inner = engine(&sc);
    inner.save_user_def(&xyz_def("slow", host.port, json!({"offline": {"allowed": true, "max_parallel": 2}}))).unwrap();
    let (r, _) = run(&inner, r#"{"layer":"slow","area":"p","bbox":[-114,42,-113,43],"minzoom":0,"maxzoom":8}"#, None);
    assert!(matches!(r.unwrap(), Done::Finished));
    let m = host.stats.max_in_flight.load(Ordering::SeqCst);
    assert_eq!(m, 2, "max in flight {m}");
}

#[test]
fn resume_after_interruption_and_update_replaces_only_when_complete() {
    let sc = Scratch::new("resume");
    let host = tile_host(0);
    let inner = engine(&sc);
    inner.save_user_def(&xyz_def("base", host.port, json!({"offline": {"allowed": true, "max_parallel": 4}}))).unwrap();
    let req = format!(r#"{{"layer":"base","area":"r1",{BOX}}}"#);
    let n = AreaReq::parse(&req).unwrap().tiles(0, 10).unwrap().len() as u64;
    assert!(n > 100, "need more than two batches, have {n}");
    // interrupted after the second progress report
    let (r, p1) = run(&inner, &req, Some(2));
    assert!(matches!(r.unwrap(), Done::Cancelled));
    let done1 = p1.last().unwrap().0;
    assert!(done1 > 0 && done1 < n, "{done1}/{n}");
    assert!(inner.areas("base").iter().all(|a| a.state == "partial"), "nothing counts as installed until it is complete");
    assert_eq!(inner.partials("base").len(), 1);
    assert_eq!(inner.list()["layers"][0]["installed"]["downloaded"], false);
    // the tiles fetched so far are already served
    assert!(inner.store_read("base").unwrap().tile_count() >= done1);
    let hits1 = host.stats.hits.load(Ordering::SeqCst);
    // resume: starts from where it was, fetches only the rest
    let (r, p2) = run(&inner, &req, None);
    assert!(matches!(r.unwrap(), Done::Finished));
    assert_eq!(p2.first().unwrap(), &(0, n - done1), "only the missing tiles are counted and fetched");
    let hits2 = host.stats.hits.load(Ordering::SeqCst) - hits1;
    assert!(hits2 as u64 <= n - done1 + 60, "fetched {hits2} more for {} remaining", n - done1);
    assert!(inner.partials("base").is_empty());
    let a = inner.areas("base");
    assert_eq!(a[0].meta["tiles_present"], n);
    assert_eq!(inner.store_read("base").unwrap().tile_count(), n);
    // a new version of the layer: the listing says an update is available
    host.stats.hits.store(0, Ordering::SeqCst);
    inner.save_user_def(&xyz_def("base", host.port, json!({"update": {"version": "2"}, "offline": {"allowed": true, "max_parallel": 4}}))).unwrap();
    let l = inner.list();
    let me = l["layers"].as_array().unwrap().iter().find(|x| x["definition"]["id"] == "base").unwrap().clone();
    assert_eq!(me["update_available"], true);
    // an update interrupted part way leaves the old version in place and serving
    let upd = r#"{"layer":"base","area":"r1","update":true}"#;
    let (r, _) = run(&inner, upd, Some(2));
    assert!(matches!(r.unwrap(), Done::Cancelled));
    assert_eq!(inner.areas("base")[0].meta["version"], "1");
    let t8 = AreaReq::parse(&req).unwrap().tiles(8, 8).unwrap()[0];
    inner.set_online(false);
    assert_eq!(tile_bytes(inner.tile("base", 8, t8.2, t8.3).unwrap()).1, "downloaded");
    inner.set_online(true);
    let (r, _) = run(&inner, upd, None);
    assert!(matches!(r.unwrap(), Done::Finished));
    let a = inner.areas("base");
    assert_eq!(a.len(), 1);
    assert_eq!(a[0].meta["version"], "2");
    assert_eq!(a[0].meta["tiles_present"], n);
    assert_eq!(inner.list()["layers"][0]["update_available"], false);
    // nothing left in staging, and every tile is now at the new version
    let st = inner.store_read("base").unwrap();
    assert_eq!(st.staging_count(), 0);
    assert!(AreaReq::parse(&req).unwrap().tiles(0, 10).unwrap().iter().all(|t| st.info(t.1, t.2, t.3).unwrap().unwrap().1 == "2"));
}

/// A PMTiles archive of raster-like tiles for z0..=zmax over the whole world, as a file.
fn build_source_pmtiles(path: &std::path::Path, zmax: u8) -> usize {
    let mut w = Writer::create(path).unwrap();
    let mut tiles = Vec::new();
    for z in 0..=zmax {
        for x in 0..(1u32 << z) {
            for y in 0..(1u32 << z) {
                let data = tile_body(z, x, y);
                let off = w.append(&data).unwrap();
                tiles.push((pmtiles::zxy_to_id(z, x, y), off, data.len() as u32));
            }
        }
    }
    tiles.sort();
    let n = tiles.len();
    w.finish(Header { tile_type: pmtiles::TYPE_PNG, tile_compression: pmtiles::COMP_NONE, max_zoom: zmax, bounds: [-180.0, -85.0, 180.0, 85.0], ..Default::default() }, &tiles, &json!({"name":"src"})).unwrap();
    n
}

#[test]
fn pmtiles_source_by_range_reads_streams_and_downloads() {
    let sc = Scratch::new("pm");
    let src = sc.path("src.pmtiles");
    build_source_pmtiles(&src, 6);
    let bytes = Arc::new(std::fs::read(&src).unwrap());
    let b2 = bytes.clone();
    let host = fake_host(0, move |url, range| {
        if url == "/src.pmtiles" {
            let (o, l) = range.unwrap_or((0, b2.len() as u64));
            let (s, e) = ((o as usize).min(b2.len()), ((o + l) as usize).min(b2.len()));
            (200, b2[s..e].to_vec())
        } else {
            (404, vec![])
        }
    });
    let inner = engine(&sc);
    let def = json!({
        "format": 1, "id": "terrain", "title": "T", "kind": "raster", "transform": "as_is",
        "source": {"type": "pmtiles", "url": format!("http://127.0.0.1:{}/src.pmtiles", host.port), "minzoom": 0, "maxzoom": 6, "tile_format": "png"},
        "offline": {"allowed": true, "max_parallel": 4}, "update": {"version": "9"}
    });
    inner.save_user_def(&def.to_string()).unwrap();
    // streaming one tile = a few range reads, then it is cached
    let (b, from) = tile_bytes(inner.tile("terrain", 5, 3, 7).unwrap());
    assert_eq!((b, from), (tile_body(5, 3, 7), "network"));
    // plan reads the real sizes from the directory
    let areq = AreaReq::parse(r#"{"layer":"terrain","area":"x","bbox":[-114,42,-113,43],"minzoom":0,"maxzoom":6}"#).unwrap();
    let plan = inner.plan(&areq).unwrap();
    assert_eq!(plan["estimate_method"], "directory");
    let want: u64 = areq.tiles(0, 6).unwrap().iter().map(|&(_, z, x, y)| tile_body(z, x, y).len() as u64).sum();
    assert_eq!(plan["estimated_bytes"], want);
    assert_eq!(plan["tiles_present"], plan["tiles"]);
    let (r, _) = run(&inner, r#"{"layer":"terrain","area":"x","bbox":[-114,42,-113,43],"minzoom":0,"maxzoom":6}"#, None);
    assert!(matches!(r.unwrap(), Done::Finished));
    let a = inner.areas("terrain");
    assert_eq!(a.len(), 1);
    let st = inner.store_read("terrain").unwrap();
    for (_, z, x, y) in areq.tiles(0, 6).unwrap() {
        assert_eq!(st.get(z, x, y).unwrap().unwrap(), tile_body(z, x, y));
    }
    // the archive is read with few requests (neighbouring tiles share reads)
    assert!(host.stats.hits.load(Ordering::SeqCst) < areq.tiles(0, 6).unwrap().len() / 2 + 20);
    // offline: from the download
    inner.set_online(false);
    let t6 = areq.tiles(6, 6).unwrap()[0];
    assert_eq!(tile_bytes(inner.tile("terrain", 6, t6.2, t6.3).unwrap()).1, "downloaded");
}

/// A Terrarium PNG whose elevation rises 0.4 m per pixel eastwards, continuous across tiles.
fn dem_png(x: u32, size: u32) -> Vec<u8> {
    let mut px = Vec::new();
    for _y in 0..size {
        for i in 0..size {
            let m = 1000.0 + 0.4 * ((x as f64 - 1000.0) * size as f64 + i as f64);
            let v = m + 32768.0;
            let (r, g) = ((v / 256.0).floor(), v.floor() % 256.0);
            px.extend([r as u8, g as u8, ((v - v.floor()) * 256.0) as u8]);
        }
    }
    let mut out = Vec::new();
    {
        let mut e = png::Encoder::new(&mut out, size, size);
        e.set_color(png::ColorType::Rgb);
        e.set_depth(png::BitDepth::Eight);
        e.write_header().unwrap().write_image_data(&px).unwrap();
    }
    out
}

#[test]
fn contours_from_elevation_tiles_with_overzoom() {
    let sc = Scratch::new("ctr");
    let host = fake_host(0, |url, _| match parse_zxy(url) {
        Some((z, x, _)) if z <= 12 => (200, dem_png(x, 256)),
        _ => (404, vec![]),
    });
    let inner = engine(&sc);
    inner.save_user_def(&xyz_def("dem", host.port, json!({"kind": "elevation", "source": {"type": "xyz", "url": format!("http://127.0.0.1:{}/{{z}}/{{x}}/{{y}}", host.port), "minzoom": 0, "maxzoom": 12, "encoding": "terrarium", "tile_format": "png", "tile_size": 256}}))).unwrap();
    inner.save_user_def(r#"{"format":1,"id":"contours","title":"C","kind":"vector","transform":"contours","derived_from":"dem"}"#).unwrap();
    inner.save_user_def(r#"{"format":1,"id":"hill","title":"H","kind":"elevation","transform":"hillshade","derived_from":"dem"}"#).unwrap();
    // hillshade serves the elevation tiles unchanged
    let (hb, _) = tile_bytes(inner.tile("hill", 12, 1000, 1500).unwrap());
    assert_eq!(hb, dem_png(1000, 256));
    // z13 (overzoom of a z12 parent): 100 ft minor, 500 ft index
    for (z, x, y, minor, index) in [(13u8, 2000u32, 3000u32, 100i64, 500i64), (14, 4000, 6000, 50, 200), (11, 1000, 700, 200, 1000)] {
        let (b, from) = tile_bytes(inner.tile("contours", z, x, y).unwrap());
        assert_eq!(from, "generated");
        let feats = cache_layers::contour::decode_mvt(&b).unwrap();
        assert!(!feats.is_empty(), "z{z} has lines");
        for (ele, level, lines) in &feats {
            assert_eq!(ele % minor, 0, "z{z}: {ele} is a multiple of {minor}");
            assert_eq!(*level, i64::from(ele % index == 0));
            // the plane rises towards the east, so every line is (nearly) vertical
            for l in lines {
                let (lo, hi) = (l.iter().map(|p| p.0).min().unwrap(), l.iter().map(|p| p.0).max().unwrap());
                assert!(hi - lo < 120, "z{z} line {ele} spans x {lo}..{hi}");
            }
        }
        // the second read comes from the cache
        assert_eq!(tile_bytes(inner.tile("contours", z, x, y).unwrap()).1, "cache");
    }
    // no contours below z3
    assert!(matches!(inner.tile("contours", 2, 1, 1).unwrap(), TileOut::Empty));
}

#[test]
fn contours_work_offline_from_a_download_and_miss_without_one() {
    let sc = Scratch::new("ctr2");
    let host = fake_host(0, |url, _| match parse_zxy(url) {
        Some((z, x, _)) if z <= 12 => (200, dem_png(x, 256)),
        _ => (404, vec![]),
    });
    let inner = engine(&sc);
    inner.save_user_def(&xyz_def("dem", host.port, json!({"kind": "elevation", "source": {"type": "xyz", "url": format!("http://127.0.0.1:{}/{{z}}/{{x}}/{{y}}", host.port), "minzoom": 0, "maxzoom": 12, "encoding": "terrarium", "tile_format": "png", "tile_size": 256}}))).unwrap();
    inner.save_user_def(r#"{"format":1,"id":"contours","title":"C","kind":"vector","transform":"contours","derived_from":"dem"}"#).unwrap();
    inner.set_online(false);
    assert!(matches!(inner.tile("contours", 12, 1000, 1500).unwrap(), TileOut::Miss));
    inner.set_online(true);
    // download the elevation for a small box around z12 tile 1000/1500 (lon/lat of its centre)
    let b = cache_layers::core::tile_bbox(12, 1000, 1500);
    let (clon, clat) = ((b[0] + b[2]) / 2.0, (b[1] + b[3]) / 2.0);
    let r = format!(r#"{{"layer":"contours","area":"c","bbox":[{},{},{},{}],"minzoom":12,"maxzoom":12}}"#, clon - 0.01, clat - 0.005, clon + 0.01, clat + 0.005);
    // the plan and the download of a derived layer are the elevation layer's
    let plan = inner.plan(&AreaReq::parse(&r).unwrap()).unwrap();
    assert_eq!(plan["download_layer"], "dem");
    let (res, _) = run(&inner, &r, None);
    assert!(matches!(res.unwrap(), Done::Finished));
    inner.set_online(false);
    let (b, _) = tile_bytes(inner.tile("contours", 12, 1000, 1500).unwrap());
    assert!(!cache_layers::contour::decode_mvt(&b).unwrap().is_empty());
}

#[test]
fn tile_server_over_http() {
    let sc = Scratch::new("srv");
    let host = tile_host(0);
    let layers = Layers::new(cache_layers::LayersCfg { dir: sc.path("l").to_string_lossy().into_owned(), defs_dirs: vec![], catalogue_urls: vec![], cache_max_bytes: 1 << 24, online: true }).unwrap();
    layers.inner.save_user_def(&xyz_def("base", host.port, json!({"attribution": "OSM"}))).unwrap();
    layers.inner.save_user_def(&xyz_def("sat", host.port, json!({"kind": "online-raster", "transform": "online_only", "offline": {"allowed": false}}))).unwrap();
    let s = layers.serve().unwrap();
    assert_eq!(layers.serve().unwrap()["port"], s["port"], "one server");
    let base = s["base_url"].as_str().unwrap().to_string();
    assert!(base.starts_with("http://127.0.0.1:"));
    let get = |p: &str| -> (u16, Vec<u8>, Option<String>) {
        match ureq::get(&format!("{base}{p}")).call() {
            Ok(r) => {
                let (st, h) = (r.status(), r.header("X-Cache-Status").map(String::from));
                let mut b = Vec::new();
                std::io::Read::read_to_end(&mut r.into_reader(), &mut b).unwrap();
                (st, b, h)
            }
            Err(ureq::Error::Status(c, r)) => (c, vec![], r.header("X-Cache-Status").map(String::from)),
            Err(e) => panic!("{e}"),
        }
    };
    let (st, b, h) = get("/layers/base/6/10/20");
    assert_eq!((st, b, h.as_deref()), (200, tile_body(6, 10, 20), Some("network")));
    assert_eq!(get("/layers/base/6/10/20.pbf").2.as_deref(), Some("cache"));
    let (st, b, _) = get("/layers/base/tilejson.json");
    let tj: Value = serde_json::from_slice(&b).unwrap();
    assert_eq!(st, 200);
    assert_eq!((tj["type"].as_str(), tj["attribution"].as_str(), tj["maxzoom"].as_u64()), (Some("vector"), Some("OSM"), Some(12)));
    assert_eq!(tj["tiles"][0], format!("{base}/layers/base/{{z}}/{{x}}/{{y}}"));
    assert_eq!(get("/layers/nope/1/1/1").0, 404);
    assert_eq!(get("/health").0, 200);
    layers.inner.set_online(false);
    let (st, _, h) = get("/layers/base/6/11/20");
    assert_eq!((st, h.as_deref()), (404, Some("miss")));
    let (st, _, h) = get("/layers/sat/6/11/20");
    assert_eq!((st, h.as_deref()), (503, Some("needs-connection")));
    // concurrent requests are served
    layers.inner.set_online(true);
    let hs: Vec<_> = (0..16u32).map(|i| {
        let base = base.clone();
        std::thread::spawn(move || {
            let r = ureq::get(&format!("{base}/layers/base/7/{i}/3")).call().unwrap();
            let mut b = Vec::new();
            std::io::Read::read_to_end(&mut r.into_reader(), &mut b).unwrap();
            assert_eq!(b, tile_body(7, i, 3));
        })
    }).collect();
    for h in hs {
        h.join().unwrap();
    }
}

#[test]
fn catalogues_are_fetched_merged_with_starters_and_a_dead_one_is_reported() {
    let sc = Scratch::new("catrefresh");
    let tiles = tile_host(0);
    let d = |id: &str, title: &str| serde_json::from_str::<Value>(&xyz_def(id, tiles.port, json!({"title": title}))).unwrap();
    let cat1 = json!({"layers": [d("from-cat1", "One"), d("shared", "Shared by 1"), {"format": 1, "id": "BAD"}]}).to_string();
    let cat2 = json!([d("shared", "Shared by 2"), d("from-cat2", "Two")]).to_string();
    let host = fake_host(0, move |url, _| match url {
        "/one.json" => (200, cat1.clone().into_bytes()),
        "/two.json" => (200, cat2.clone().into_bytes()),
        "/check.json" => (200, br#"{"version":"7"}"#.to_vec()),
        _ => (404, vec![]),
    });
    let defs = sc.path("defs");
    std::fs::create_dir_all(&defs).unwrap();
    std::fs::write(defs.join("starter.json"), xyz_def("starter", tiles.port, json!({"update": {"version": "1", "check_url": host.url("/check.json")}}))).unwrap();
    let cfg = |urls: Vec<String>| cache_layers::LayersCfg { dir: sc.path("l").to_string_lossy().into_owned(), defs_dirs: vec![defs.to_string_lossy().into_owned()], catalogue_urls: urls, cache_max_bytes: 1 << 20, online: true };
    let inner = cache_layers::Inner::open(cfg(vec![host.url("/one.json"), host.url("/missing.json"), host.url("/two.json")])).unwrap();
    assert_eq!(inner.list()["layers"].as_array().unwrap().len(), 1);
    let r = inner.refresh().unwrap();
    let cats = r["catalogues"].as_array().unwrap();
    assert_eq!((cats[0]["layers"].as_u64(), cats[0]["invalid"].as_array().unwrap().len()), (Some(2), 1));
    assert!(cats[1]["error"]["message"].as_str().unwrap().contains("404"), "{}", cats[1]);
    assert_eq!(cats[2]["layers"], 2);
    assert_eq!(r["updates"]["starter"], "7");
    let l = inner.list();
    let ids: Vec<&str> = l["layers"].as_array().unwrap().iter().map(|x| x["definition"]["id"].as_str().unwrap()).collect();
    assert_eq!(ids.len(), 4, "{ids:?}");
    assert_eq!(inner.def("shared").unwrap().title, "Shared by 2", "a later catalogue wins");
    assert_eq!(l["layers"].as_array().unwrap().iter().find(|x| x["definition"]["id"] == "from-cat1").unwrap()["origin"], "catalogue");
    // the user's own definition still beats the catalogue
    inner.save_user_def(&xyz_def("shared", tiles.port, json!({"title": "Mine"}))).unwrap();
    assert_eq!(inner.def("shared").unwrap().title, "Mine");
    // user agent on the catalogue fetches
    assert!(host.stats.agents.lock().unwrap().iter().all(|a| a.starts_with("Cache/")));
    // with every catalogue dead, refresh fails with fetch_failed; offline it says offline
    let dead = cache_layers::Inner::open(cfg(vec![host.url("/missing.json")])).unwrap();
    assert_eq!(dead.refresh().unwrap_err().code, "fetch_failed");
    dead.set_online(false);
    assert_eq!(dead.refresh().unwrap_err().code, "offline");
    // the default catalogue address is Cache's
    let c: cache_layers::LayersCfg = serde_json::from_str(r#"{"dir":"x"}"#).unwrap();
    assert_eq!(c.catalogue_urls, vec!["https://cache.echo6.co/catalogue.json".to_string()]);
    let c: cache_layers::LayersCfg = serde_json::from_str(r#"{"dir":"x","catalogue_urls":[]}"#).unwrap();
    assert!(c.catalogue_urls.is_empty());
}

#[test]
fn polygon_areas_hold_fewer_tiles_than_their_box() {
    let tri = AreaReq::parse(r#"{"layer":"x","polygon":[[-114,42],[-113,42],[-113.5,43]],"minzoom":10,"maxzoom":10}"#).unwrap();
    let bx = AreaReq::parse(r#"{"layer":"x","bbox":[-114,42,-113,43],"minzoom":10,"maxzoom":10}"#).unwrap();
    let (t, b) = (tri.tiles(10, 10).unwrap().len(), bx.tiles(10, 10).unwrap().len());
    assert!(t > 0 && t < b, "{t} < {b}");
    assert_eq!(tri.bounds().unwrap(), [-114.0, 42.0, -113.0, 43.0]);
    // ids differ for different shapes
    assert_ne!(tri.area_id().unwrap(), bx.area_id().unwrap());
}

#[test]
fn a_download_that_does_not_fit_the_disk_is_refused_before_it_starts() {
    let sc = Scratch::new("space");
    // an archive whose directory says each tile is 4 GB (the data itself is never read)
    let src = sc.path("huge.pmtiles");
    let mut w = Writer::create(&src).unwrap();
    let mut tiles = Vec::new();
    for x in 0..8u32 {
        for y in 0..8u32 {
            tiles.push((pmtiles::zxy_to_id(3, x, y), 0u64, 4_000_000_000u32));
        }
    }
    w.append(b"x").unwrap();
    tiles.sort();
    w.finish(Header { tile_type: pmtiles::TYPE_PNG, tile_compression: pmtiles::COMP_NONE, max_zoom: 3, ..Default::default() }, &tiles, &json!({})).unwrap();
    let bytes = Arc::new(std::fs::read(&src).unwrap());
    let host = fake_host(0, move |url, range| {
        if url == "/huge.pmtiles" {
            let (o, l) = range.unwrap_or((0, bytes.len() as u64));
            let (s, e) = ((o as usize).min(bytes.len()), ((o + l) as usize).min(bytes.len()));
            (200, bytes[s..e].to_vec())
        } else {
            (404, vec![])
        }
    });
    let inner = engine(&sc);
    inner
        .save_user_def(&json!({"format": 1, "id": "huge", "title": "H", "kind": "raster", "transform": "as_is",
            "source": {"type": "pmtiles", "url": format!("http://127.0.0.1:{}/huge.pmtiles", host.port), "minzoom": 0, "maxzoom": 3, "tile_format": "png"}}).to_string())
        .unwrap();
    let req = r#"{"layer":"huge","area":"h","bbox":[-179,-80,179,80],"minzoom":3,"maxzoom":3}"#;
    let plan = inner.plan(&AreaReq::parse(req).unwrap()).unwrap();
    assert_eq!(plan["ok_to_start"], false);
    assert_eq!(plan["problems"][0]["code"], "no_space");
    let (r, _) = run(&inner, req, None);
    let e = r.err().unwrap();
    assert_eq!(e.code, "no_space");
    let (needed, available) = e.space.unwrap();
    assert!(needed > available);
    assert!(inner.areas("huge").is_empty() && inner.partials("huge").is_empty());
}
