//! What a region's map download costs, counted against a stub PMTiles host on 127.0.0.1: directory page requests, how many of
//! them run one after another before the first tile is read, and every request of the size estimate and of the download job.
//! The archive has small leaf directories (64 entries), so a region needs a few hundred of them, as a state's map does from the
//! planet file. The app sizes a download on one engine (the planner) and runs it as a job on another; the test does the same.

mod common;
use cache_layers::download::tile_range;
use cache_layers::pmtiles::{self, Entry, Header};
use cache_layers::store::Stored;
use cache_layers::{AreaReq, Done, Inner};
use common::*;
use serde_json::json;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tiny_http::{Header as HttpHeader, Response, Server};

/// The archive holds every tile of this box, z0 to [ZMAX].
const ARCHIVE_BOX: [f64; 4] = [-120.0, 40.0, -108.0, 50.0];
/// The region asked for (inside the archive's box).
const REGION: &str = r#""bbox":[-117,42,-111,49]"#;
const ZMAX: u8 = 12;
const LEAF_ENTRIES: usize = 64;
/// Every answer of the stub takes this long, as a real host's round trip does.
const DELAY: Duration = Duration::from_millis(3);

fn body(z: u8, x: u32, y: u32) -> Vec<u8> {
    format!("t{z}-{x}-{y}").into_bytes()
}

struct Archive {
    bytes: Arc<Vec<u8>>,
    header: Header,
    /// (id, z, x, y) of every tile it holds
    tiles: std::collections::HashSet<(u8, u32, u32)>,
}

/// A clustered archive with leaf directories of [LEAF_ENTRIES] entries: header, root, metadata, leaves, tile data.
fn archive() -> Archive {
    let mut tiles: Vec<(u64, u8, u32, u32)> = Vec::new();
    for z in 0..=ZMAX {
        let (x0, x1, y0, y1) = tile_range(ARCHIVE_BOX, z);
        for x in x0..=x1 {
            for y in y0..=y1 {
                tiles.push((pmtiles::zxy_to_id(z, x as u32, y as u32), z, x as u32, y as u32));
            }
        }
    }
    tiles.sort();
    let mut data = Vec::new();
    let mut entries = Vec::new();
    for &(id, z, x, y) in &tiles {
        let b = body(z, x, y);
        entries.push(Entry { tile_id: id, offset: data.len() as u64, length: b.len() as u32, run_length: 1 });
        data.extend_from_slice(&b);
    }
    let mut leaves = Vec::new();
    let mut ptrs = Vec::new();
    for chunk in entries.chunks(LEAF_ENTRIES) {
        let c = pmtiles::gzip(&pmtiles::serialize_dir(chunk));
        ptrs.push(Entry { tile_id: chunk[0].tile_id, offset: leaves.len() as u64, length: c.len() as u32, run_length: 0 });
        leaves.extend_from_slice(&c);
    }
    let root = pmtiles::gzip(&pmtiles::serialize_dir(&ptrs));
    assert!(root.len() + pmtiles::HEADER_LEN <= 16384, "the root must fit the first read");
    let meta = pmtiles::gzip(json!({"name": "cost"}).to_string().as_bytes());
    let mut h = Header {
        root_offset: pmtiles::HEADER_LEN as u64,
        root_len: root.len() as u64,
        addressed_tiles: tiles.len() as u64,
        tile_entries: entries.len() as u64,
        tile_contents: entries.len() as u64,
        clustered: true,
        internal_compression: pmtiles::COMP_GZIP,
        tile_compression: pmtiles::COMP_NONE,
        tile_type: pmtiles::TYPE_PNG,
        min_zoom: 0,
        max_zoom: ZMAX,
        bounds: ARCHIVE_BOX,
        ..Default::default()
    };
    h.meta_offset = h.root_offset + h.root_len;
    h.meta_len = meta.len() as u64;
    h.leaf_offset = h.meta_offset + h.meta_len;
    h.leaf_len = leaves.len() as u64;
    h.data_offset = h.leaf_offset + h.leaf_len;
    h.data_len = data.len() as u64;
    let mut bytes = h.serialize();
    bytes.extend_from_slice(&root);
    bytes.extend_from_slice(&meta);
    bytes.extend_from_slice(&leaves);
    bytes.extend_from_slice(&data);
    Archive { bytes: Arc::new(bytes), header: h, tiles: tiles.iter().map(|t| (t.1, t.2, t.3)).collect() }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Kind {
    Head,
    Leaf,
    Data,
}

#[derive(Clone, Copy, Debug)]
struct Req {
    kind: Kind,
    start: Instant,
    end: Instant,
}

struct Host {
    port: u16,
    log: Arc<Mutex<Vec<Req>>>,
}

/// Serves the archive by ranges, logging what each request read and when.
fn host(a: &Archive) -> Host {
    let server = Arc::new(Server::http("127.0.0.1:0").unwrap());
    let port = server.server_addr().to_ip().unwrap().port();
    let log: Arc<Mutex<Vec<Req>>> = Default::default();
    let (leaf0, data0) = (a.header.leaf_offset, a.header.data_offset);
    for _ in 0..48 {
        let (s, log, bytes) = (server.clone(), log.clone(), a.bytes.clone());
        std::thread::spawn(move || {
            while let Ok(req) = s.recv() {
                let start = Instant::now();
                let range = req.headers().iter().find(|h| h.field.equiv("Range")).and_then(|h| {
                    let v = h.value.to_string();
                    let (a, b) = v.strip_prefix("bytes=")?.split_once('-')?;
                    let (a, b): (u64, u64) = (a.parse().ok()?, b.parse().ok()?);
                    Some((a, b - a + 1))
                });
                let (o, l) = range.unwrap_or((0, bytes.len() as u64));
                std::thread::sleep(DELAY);
                let kind = if o >= data0 { Kind::Data } else if o >= leaf0 { Kind::Leaf } else { Kind::Head };
                let (s0, e0) = ((o as usize).min(bytes.len()), ((o + l) as usize).min(bytes.len()));
                let body = bytes[s0..e0].to_vec();
                log.lock().unwrap().push(Req { kind, start, end: Instant::now() });
                let r = Response::from_data(body).with_status_code(206).with_header(HttpHeader::from_bytes("Content-Type", "application/octet-stream").unwrap());
                let _ = req.respond(r);
            }
        });
    }
    Host { port, log }
}

/// What one phase (the estimate, or the job) asked of the host.
#[derive(Debug, Default, Clone, Copy)]
struct Cost {
    requests: usize,
    leaf: usize,
    data: usize,
    /// directory page requests before the first tile read
    leaf_before_first_tile: usize,
    /// of those, how many ran one after another (each started after every earlier one had ended)
    leaf_rounds_before_first_tile: usize,
}

fn cost(log: &[Req]) -> Cost {
    let mut v = log.to_vec();
    v.sort_by_key(|r| r.start);
    let first_tile = v.iter().filter(|r| r.kind == Kind::Data).map(|r| r.start).min();
    let before: Vec<&Req> = v.iter().filter(|r| r.kind == Kind::Leaf && first_tile.map(|t| r.start < t).unwrap_or(true)).collect();
    let mut rounds = 0;
    let mut ended: Option<Instant> = None;
    for r in &before {
        if ended.map(|e| r.start >= e).unwrap_or(true) {
            rounds += 1;
        }
        ended = Some(ended.map(|e| e.max(r.end)).unwrap_or(r.end));
    }
    Cost {
        requests: v.len(),
        leaf: v.iter().filter(|r| r.kind == Kind::Leaf).count(),
        data: v.iter().filter(|r| r.kind == Kind::Data).count(),
        leaf_before_first_tile: before.len(),
        leaf_rounds_before_first_tile: rounds,
    }
}

fn take(h: &Host) -> Cost {
    let mut g = h.log.lock().unwrap();
    let c = cost(&g);
    g.clear();
    c
}

fn def(id: &str, port: u16) -> String {
    json!({
        "format": 1, "id": id, "title": id, "kind": "raster", "transform": "as_is",
        "source": {"type": "pmtiles", "url": format!("http://127.0.0.1:{port}/{id}.pmtiles"), "minzoom": 0, "maxzoom": ZMAX, "tile_format": "png"},
        "offline": {"allowed": true}, "update": {"version": "1"}
    })
    .to_string()
}

fn download(inner: &Inner, req: &str) -> Done {
    inner.run_download(&AreaReq::parse(req).unwrap(), &|_, _, _| {}, &|| false).unwrap()
}

/// The directory pages the region's tiles are in.
fn leaves_needed(a: &Archive, cover: &[(u64, u8, u32, u32)]) -> usize {
    let mut ids: Vec<u64> = a.tiles.iter().map(|&(z, x, y)| pmtiles::zxy_to_id(z, x, y)).collect();
    ids.sort();
    let firsts: Vec<u64> = ids.chunks(LEAF_ENTRIES).map(|c| c[0]).collect();
    let mut pages: std::collections::HashSet<usize> = Default::default();
    for t in cover {
        pages.insert(firsts.partition_point(|&f| f <= t.0) - 1);
    }
    pages.len()
}

#[test]
fn a_region_download_plans_once_and_reads_the_directory_in_parallel() {
    let sc = Scratch::new("cost");
    let a = archive();
    let h = host(&a);
    let planner = common::engine(&sc);
    planner.save_user_def(&def("costmap", h.port)).unwrap();
    let req = format!(r#"{{"layer":"costmap","area":"r1",{REGION},"minzoom":0,"maxzoom":{ZMAX},"near":[45.5,-114.0]}}"#);
    let areq = AreaReq::parse(&req).unwrap();
    let cover = areq.tiles(0, ZMAX).unwrap();
    let pages = leaves_needed(&a, &cover);

    // The size estimate, on the planner, as the Regions sheet asks for it.
    let t = Instant::now();
    let plan = planner.plan(&areq).unwrap();
    let est_time = t.elapsed();
    let est = take(&h);
    assert_eq!(plan["tiles_to_download"], json!(cover.len()));

    // The download, as a job on an engine of its own.
    let job = common::engine(&sc);
    let t = Instant::now();
    assert!(matches!(download(&job, &req), Done::Finished));
    let job_time = t.elapsed();
    let dl = take(&h);

    let report = format!(
        "region: {} tiles in {} directory pages\nestimate: {est:?} in {est_time:?}\njob: {dl:?} in {job_time:?}\ntotal requests: {}",
        cover.len(),
        pages,
        est.requests + dl.requests
    );
    eprintln!("{report}");

    // Nothing changes in which tiles end up stored: every tile of the box, the archive's bytes, nothing else.
    let st = job.store_read("costmap").unwrap();
    for &(_, z, x, y) in &cover {
        let want = if a.tiles.contains(&(z, x, y)) { Stored::Tile(body(z, x, y)) } else { Stored::Empty };
        assert_eq!(st.find(z, x, y).unwrap(), Some(want), "z{z}/{x}/{y}");
    }
    assert_eq!(st.tile_count() as usize, cover.iter().filter(|t| a.tiles.contains(&(t.1, t.2, t.3))).count());

    // The estimate reads the pages it needs in parallel, a few rounds rather than one page after another.
    assert!(est.leaf <= pages + 2, "each page once\n{report}");
    assert!(est.leaf_rounds_before_first_tile <= 4, "pages in parallel\n{report}");
    // The job plans with the pages the estimate read: no directory request before its first tile, and none at all.
    assert_eq!(dl.leaf_before_first_tile, 0, "{report}");
    assert_eq!(dl.leaf, 0, "{report}");
}

#[test]
fn an_outline_downloads_fewer_tiles_than_its_box() {
    let sc = Scratch::new("cost-outline");
    let a = archive();
    let h = host(&a);
    let inner = common::engine(&sc);
    inner.save_user_def(&def("costoutline", h.port)).unwrap();
    // A diamond inside the region's box: half its area.
    let diamond = r#""polygon":[[-114,42],[-111,45.5],[-114,49],[-117,45.5]]"#;
    let preq = format!(r#"{{"layer":"costoutline","area":"p1",{diamond},"minzoom":0,"maxzoom":{ZMAX}}}"#);
    let breq = format!(r#"{{"layer":"costoutline","area":"b1",{REGION},"minzoom":0,"maxzoom":{ZMAX}}}"#);
    let pcover = AreaReq::parse(&preq).unwrap().tiles(0, ZMAX).unwrap();
    let bcover = AreaReq::parse(&breq).unwrap().tiles(0, ZMAX).unwrap();
    assert!(matches!(download(&inner, &preq), Done::Finished));
    let pc = take(&h);
    let st = inner.store_read("costoutline").unwrap();
    let p_stored = st.tile_count();
    assert!(matches!(download(&inner, &breq), Done::Finished));
    let bc = take(&h);
    let b_stored = st.tile_count();
    let report = format!("outline: {} tiles, {pc:?}, {p_stored} stored\nbox afterwards: {} tiles, {bc:?}, {b_stored} stored", pcover.len(), bcover.len());
    eprintln!("{report}");
    assert!(pcover.len() * 10 < bcover.len() * 6, "{report}");
    assert_eq!(p_stored as usize, pcover.len(), "every tile of the outline, nothing else\n{report}");
    assert_eq!(b_stored as usize, bcover.len(), "{report}");
    for &(_, z, x, y) in &pcover {
        assert_eq!(st.find(z, x, y).unwrap(), Some(Stored::Tile(body(z, x, y))));
    }
}
