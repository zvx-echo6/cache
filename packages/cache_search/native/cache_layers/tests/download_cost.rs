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
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

/// The archive holds every tile of this box, z0 to [ZMAX].
const ARCHIVE_BOX: [f64; 4] = [-120.0, 40.0, -108.0, 50.0];
/// The region asked for (inside the archive's box).
const REGION: &str = r#""bbox":[-117,42,-111,49]"#;
const ZMAX: u8 = 12;
const LEAF_ENTRIES: usize = 64;
/// Every answer of the stub takes this long, as a real host's round trip does (longer than storing a batch takes, as on a
/// phone's connection).
const DELAY: Duration = Duration::from_millis(15);

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
}

/// How long a read waits for the others before the stub gives up and records that they never overlapped.
const OVERLAP_WAIT: Duration = Duration::from_secs(30);

/// A latch on the stub's reads of one kind: once armed, each read is held until `need` of them are in flight together, then
/// all are let go and the latch stays open. Reads that never meet are let go after [OVERLAP_WAIT] with `never_overlapped` set,
/// so a sequential reader fails the test with a message instead of hanging it. No wall-clock measure of the reads is
/// involved. Unarmed (the default, and for every other test), it does nothing.
struct Gate {
    need: usize,
    state: Mutex<GateState>,
    cv: Condvar,
}

#[derive(Default)]
struct GateState {
    armed: bool,
    waiting: usize,
    open: bool,
    never_overlapped: bool,
}

impl Gate {
    fn new(need: usize) -> Gate {
        Gate { need, state: Default::default(), cv: Condvar::new() }
    }
    fn arm(&self) {
        self.state.lock().unwrap().armed = true;
    }
    fn never_overlapped(&self) -> bool {
        self.state.lock().unwrap().never_overlapped
    }
    fn pass(&self) {
        let mut g = self.state.lock().unwrap();
        if !g.armed || g.open {
            return;
        }
        g.waiting += 1;
        if g.waiting >= self.need {
            g.open = true;
            self.cv.notify_all();
            return;
        }
        let (mut g, res) = self.cv.wait_timeout_while(g, OVERLAP_WAIT, |s| !s.open).unwrap();
        if res.timed_out() && !g.open {
            g.never_overlapped = true;
            g.open = true;
            self.cv.notify_all();
        }
    }
}

struct Host {
    port: u16,
    log: Arc<Mutex<Vec<Req>>>,
    /// held until 4 directory page reads are in flight at once (when armed)
    leaf_gate: Arc<Gate>,
    /// held until 2 tile reads are in flight at once (when armed)
    data_gate: Arc<Gate>,
}

/// Serves the archive by ranges, logging what each request read and when. A thread for every connection, and every answer
/// closes its connection. (tiny_http, used by the other tests' stubs, serves connections from a small pool of threads that a
/// kept-alive connection holds while idle, and it can leave a new connection waiting for a thread: the reader's 16 concurrent
/// requests then sat unanswered until the client's 60 s timeout, so a read that was only queued was taken for one that never
/// overlapped the others.)
fn host(a: &Archive) -> Host {
    use std::io::{Read, Write};
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    let log: Arc<Mutex<Vec<Req>>> = Default::default();
    let (leaf_gate, data_gate) = (Arc::new(Gate::new(4)), Arc::new(Gate::new(2)));
    let (leaf0, data0) = (a.header.leaf_offset, a.header.data_offset);
    let (log2, bytes, lg, dg) = (log.clone(), a.bytes.clone(), leaf_gate.clone(), data_gate.clone());
    std::thread::spawn(move || {
        for conn in listener.incoming() {
            let Ok(mut conn) = conn else { continue };
            let (log, bytes, leaf_gate, data_gate) = (log2.clone(), bytes.clone(), lg.clone(), dg.clone());
            std::thread::spawn(move || {
                // the request head (a GET carries no body)
                let mut head = Vec::new();
                let mut buf = [0u8; 1024];
                while !head.windows(4).any(|w| w == b"\r\n\r\n") {
                    match conn.read(&mut buf) {
                        Ok(0) | Err(_) => return,
                        Ok(n) => head.extend_from_slice(&buf[..n]),
                    }
                }
                let start = Instant::now();
                let head = String::from_utf8_lossy(&head).to_string();
                let range = head.lines().find_map(|l| {
                    let (k, v) = l.split_once(':')?;
                    let (a, b) = k.eq_ignore_ascii_case("range").then(|| v.trim())?.strip_prefix("bytes=")?.split_once('-')?;
                    let (a, b): (u64, u64) = (a.parse().ok()?, b.parse().ok()?);
                    Some((a, b - a + 1))
                });
                let (o, l) = range.unwrap_or((0, bytes.len() as u64));
                let kind = if o >= data0 { Kind::Data } else if o >= leaf0 { Kind::Leaf } else { Kind::Head };
                match kind {
                    Kind::Leaf => leaf_gate.pass(),
                    Kind::Data => data_gate.pass(),
                    Kind::Head => {}
                }
                std::thread::sleep(DELAY);
                let (s0, e0) = ((o as usize).min(bytes.len()), ((o + l) as usize).min(bytes.len()));
                let body = &bytes[s0..e0];
                log.lock().unwrap().push(Req { kind, start });
                let hdr = format!("HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                let _ = conn.write_all(hdr.as_bytes()).and_then(|_| conn.write_all(body));
            });
        }
    });
    Host { port, log, leaf_gate, data_gate }
}

/// What one phase (the estimate, or the job) asked of the host.
#[derive(Debug, Default, Clone, Copy)]
struct Cost {
    requests: usize,
    leaf: usize,
    data: usize,
    /// directory page requests before the first tile read
    leaf_before_first_tile: usize,
}

fn cost(log: &[Req]) -> Cost {
    let mut v = log.to_vec();
    v.sort_by_key(|r| r.start);
    let first_tile = v.iter().filter(|r| r.kind == Kind::Data).map(|r| r.start).min();
    let before: Vec<&Req> = v.iter().filter(|r| r.kind == Kind::Leaf && first_tile.map(|t| r.start < t).unwrap_or(true)).collect();
    Cost {
        requests: v.len(),
        leaf: v.iter().filter(|r| r.kind == Kind::Leaf).count(),
        data: v.iter().filter(|r| r.kind == Kind::Data).count(),
        leaf_before_first_tile: before.len(),
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
    h.leaf_gate.arm();
    let plan = planner.plan(&areq).unwrap();
    let est = take(&h);
    assert_eq!(plan["tiles_to_download"], json!(cover.len()));

    // The download, as a job on an engine of its own.
    let job = common::engine(&sc);
    h.data_gate.arm();
    assert!(matches!(download(&job, &req), Done::Finished));
    let dl = take(&h);

    let report = format!(
        "region: {} tiles in {} directory pages\nestimate: {est:?}\njob: {dl:?}\ntotal requests: {}",
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

    // The estimate reads each page it needs about once, and in parallel (below).
    assert!(est.leaf <= pages + 2, "each page once\n{report}");
    // Proved by the stub's latch, not by timing: it held the directory reads until 4 were in flight together (the readers
    // run 16 at once, def.rs PMTILES_DOWNLOAD_PARALLEL and pmtiles.rs PREFETCH_WORKERS, whatever the machine).
    assert!(!h.leaf_gate.never_overlapped(), "reads never overlapped: no 4 directory reads were in flight at once\n{report}");
    // The job plans with the pages the estimate read: no directory request before its first tile, and none at all.
    assert_eq!(dl.leaf_before_first_tile, 0, "{report}");
    assert_eq!(dl.leaf, 0, "{report}");
    // Reads overlap while the job runs (the next batches' reads are in flight while a batch waits for its last one): the stub
    // held the tile reads until 2 were in flight together.
    assert!(!h.data_gate.never_overlapped(), "reads never overlapped: no 2 tile reads were in flight at once\n{report}");
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

#[test]
fn the_size_of_an_outline_is_the_outlines_and_is_what_its_download_stores() {
    let sc = Scratch::new("cost-outline-size");
    let a = archive();
    let h = host(&a);
    let planner = common::engine(&sc);
    planner.save_user_def(&def("costsize", h.port)).unwrap();
    let diamond = r#""polygon":[[-114,42],[-111,45.5],[-114,49],[-117,45.5]]"#;
    let preq = format!(r#"{{"layer":"costsize","area":"p1",{diamond},"minzoom":0,"maxzoom":{ZMAX}}}"#);
    let breq = format!(r#"{{"layer":"costsize","area":"b1",{REGION},"minzoom":0,"maxzoom":{ZMAX}}}"#);
    let pplan = planner.plan(&AreaReq::parse(&preq).unwrap()).unwrap();
    let bplan = planner.plan(&AreaReq::parse(&breq).unwrap()).unwrap();
    let (pest, best) = (pplan["estimated_bytes"].as_u64().unwrap(), bplan["estimated_bytes"].as_u64().unwrap());
    assert!(pest * 10 < best * 6, "the outline's size ({pest}) is well under its box's ({best})");
    // what the download stores is exactly the estimate
    let job = common::engine(&sc);
    assert!(matches!(download(&job, &preq), Done::Finished));
    let st = job.store_read("costsize").unwrap();
    let cover = AreaReq::parse(&preq).unwrap().tiles(0, ZMAX).unwrap();
    let mut stored = 0u64;
    for &(_, z, x, y) in &cover {
        if let Some(Stored::Tile(b)) = st.find(z, x, y).unwrap() {
            stored += b.len() as u64;
        }
    }
    assert_eq!(pest, stored, "the estimate is the bytes the download stores");
}

#[test]
fn a_plan_asks_the_store_one_range_query_per_zoom() {
    let sc = Scratch::new("cost-store");
    let a = archive();
    let h = host(&a);
    let first = common::engine(&sc);
    first.save_user_def(&def("coststore", h.port)).unwrap();
    let small = format!(r#"{{"layer":"coststore","area":"s1","bbox":[-116,43,-113,46],"minzoom":0,"maxzoom":{ZMAX}}}"#);
    assert!(matches!(download(&first, &small), Done::Finished));
    let scover = AreaReq::parse(&small).unwrap().tiles(0, ZMAX).unwrap();
    take(&h);

    // A larger region over it, planned on an engine of its own (its store is opened afresh, so its count starts at 0).
    let big = format!(r#"{{"layer":"coststore","area":"b1",{REGION},"minzoom":0,"maxzoom":{ZMAX}}}"#);
    let bcover = AreaReq::parse(&big).unwrap().tiles(0, ZMAX).unwrap();
    let planner = common::engine(&sc);
    let plan = planner.plan(&AreaReq::parse(&big).unwrap()).unwrap();
    let st = planner.store_read("coststore").unwrap();
    let plan_queries = st.queries();
    // what was on the device is told right: the tiles of both regions
    let both: std::collections::HashSet<_> = scover.iter().collect();
    let overlap = bcover.iter().filter(|t| both.contains(t)).count();
    assert_eq!(plan["tiles_already"], json!(overlap));
    assert_eq!(plan["already_bytes"], json!(bcover.iter().filter(|t| both.contains(t)).map(|t| body(t.1, t.2, t.3).len()).sum::<usize>()));
    assert_eq!(plan["tiles_to_download"], json!(bcover.len() - overlap));

    // The job: its plan, then what the area holds once done.
    let job = common::engine(&sc);
    assert!(matches!(download(&job, &big), Done::Finished));
    let job_queries = job.store_read("coststore").unwrap().queries();
    let zooms = ZMAX as u64 + 1;
    eprintln!(
        "store queries for {} tiles: plan {plan_queries} (one a tile before: {}), job {job_queries} (before: {})",
        bcover.len(),
        bcover.len() + overlap,
        2 * bcover.len() + overlap
    );
    assert_eq!(plan_queries, zooms, "one range query per zoom");
    assert_eq!(job_queries, 2 * zooms, "the plan's, and the count of what the area holds at the end");
    let held = job.store_read("coststore").unwrap();
    assert_eq!(held.tile_count() as usize, bcover.len());
    let area = job.areas("coststore").iter().find(|x| x.id == "b1").unwrap().meta.clone();
    assert_eq!(area["tiles_present"], json!(bcover.len()));
}

#[test]
fn an_outline_in_parts_downloads_their_union() {
    let sc = Scratch::new("cost-parts");
    let a = archive();
    let h = host(&a);
    let inner = common::engine(&sc);
    inner.save_user_def(&def("costparts", h.port)).unwrap();
    let west = "[[-117,42],[-115,43],[-116,45]]";
    let east = "[[-113,44],[-111,45],[-112,48],[-114,47]]";
    let req = format!(r#"{{"layer":"costparts","area":"u1","polygon":[{west},{east}],"minzoom":0,"maxzoom":{ZMAX}}}"#);
    let one = |ring: &str| AreaReq::parse(&format!(r#"{{"layer":"costparts","polygon":{ring}}}"#)).unwrap().tiles(0, ZMAX).unwrap();
    let mut union: Vec<_> = one(west).into_iter().chain(one(east)).collect();
    union.sort();
    union.dedup();
    let cover = AreaReq::parse(&req).unwrap().tiles(0, ZMAX).unwrap();
    assert_eq!(cover, union, "the cover of the parts is the union of their covers");
    assert!(matches!(download(&inner, &req), Done::Finished));
    take(&h);
    let st = inner.store_read("costparts").unwrap();
    assert_eq!(st.tile_count() as usize, union.len());
    for &(_, z, x, y) in &union {
        assert_eq!(st.find(z, x, y).unwrap(), Some(Stored::Tile(body(z, x, y))));
    }
    // the stored area keeps its outline: asked again by the area alone, it is the same shape and nothing is fetched
    assert!(matches!(download(&inner, r#"{"layer":"costparts","area":"u1"}"#), Done::Finished));
    assert_eq!(take(&h).data, 0);

    // Deleting an area keeps what another outline covers, and only that.
    let other = format!(r#"{{"layer":"costparts","area":"o1","polygon":{east},"minzoom":0,"maxzoom":{ZMAX}}}"#);
    assert!(matches!(download(&inner, &other), Done::Finished));
    let d = inner.delete_areas("costparts", Some("u1")).unwrap();
    let east_cover = one(east);
    assert_eq!(d["tiles_kept"], json!(east_cover.len()), "{d}");
    assert_eq!(st.tile_count() as usize, east_cover.len());
    for &(_, z, x, y) in &east_cover {
        assert!(st.find(z, x, y).unwrap().is_some());
    }
}

#[test]
fn a_stopped_download_keeps_whole_batches_nearest_first_and_carries_on_and_an_update_swaps_in_at_the_end() {
    let sc = Scratch::new("cost-resume");
    let a = archive();
    let h = host(&a);
    let inner = common::engine(&sc);
    inner.save_user_def(&def("costresume", h.port)).unwrap();
    let req = format!(r#"{{"layer":"costresume","area":"c1",{REGION},"minzoom":0,"maxzoom":{ZMAX},"near":[45.5,-114.0]}}"#);
    let areq = AreaReq::parse(&req).unwrap();
    let cover = areq.tiles(0, ZMAX).unwrap();
    // stopped after the second batch is stored
    let calls = std::sync::atomic::AtomicUsize::new(0);
    let r = inner.run_download(
        &areq,
        &|_, _, _| {
            calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        },
        &|| calls.load(std::sync::atomic::Ordering::SeqCst) > 2,
    );
    assert!(matches!(r.unwrap(), Done::Cancelled));
    let st = inner.store_read("costresume").unwrap();
    let mut order = cover.clone();
    cache_layers::download::order_blocks_from(&mut order, areq.near);
    let first: std::collections::HashSet<_> = order.iter().take(2048).map(|t| (t.1, t.2, t.3)).collect();
    assert_eq!(st.tile_count(), 2048, "two whole batches");
    for &(z, x, y) in &first {
        assert!(st.find(z, x, y).unwrap().is_some(), "the nearest tiles first: z{z}/{x}/{y}");
    }
    take(&h);
    // carried on: only the rest is read
    assert!(matches!(download(&inner, &req), Done::Finished));
    assert_eq!(st.tile_count() as usize, cover.len());
    let rest = take(&h);
    assert!(rest.data > 0);

    // a new version: fetched into staging, swapped in when all of it is there
    let mut d: serde_json::Value = serde_json::from_str(&def("costresume", h.port)).unwrap();
    d["update"]["version"] = json!("2");
    inner.save_user_def(&d.to_string()).unwrap();
    assert!(matches!(download(&inner, r#"{"layer":"costresume","area":"c1","update":true}"#), Done::Finished));
    assert_eq!(st.staging_count(), 0);
    for &(_, z, x, y) in &cover {
        assert_eq!(st.info(z, x, y).unwrap().map(|i| i.1), Some("2".to_string()), "z{z}/{x}/{y}");
    }
}
