//! A region's pre-cut map file (download/precut.rs) against a fake host on 127.0.0.1 that serves the planet archive and the
//! region files by ranges: fetched once and copied into the store, carried on from a partial file, and every way it can be
//! wrong falling back to range reads of the planet.

mod common;
use cache_layers::download::RegionFile;
use cache_layers::pmtiles::{self, Header, Writer};
use cache_layers::{AreaReq, Done, Inner};
use common::*;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashMap};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

const PLANET: &str = "9";
const TOP: u8 = 6;

fn body(z: u8, x: u32, y: u32) -> Vec<u8> {
    format!("tile {z}/{x}/{y} ").repeat(40).into_bytes()
}

/// A PMTiles archive of `tiles` (each [`body`]), with `name` in its metadata so every test's file is its own.
fn archive(path: &Path, tiles: &BTreeSet<(u8, u32, u32)>, name: &str) {
    let mut ids: Vec<(u64, u8, u32, u32)> = tiles.iter().map(|&(z, x, y)| (pmtiles::zxy_to_id(z, x, y), z, x, y)).collect();
    ids.sort();
    let mut w = Writer::create(path).unwrap();
    let mut entries = Vec::new();
    for (id, z, x, y) in ids {
        let d = body(z, x, y);
        let off = w.append(&d).unwrap();
        entries.push((id, off, d.len() as u32));
    }
    w.finish(Header { tile_type: pmtiles::TYPE_PNG, tile_compression: pmtiles::COMP_NONE, max_zoom: TOP, bounds: [-180.0, -85.0, 180.0, 85.0], ..Default::default() }, &entries, &json!({"name": name})).unwrap();
}

fn world() -> BTreeSet<(u8, u32, u32)> {
    let mut s = BTreeSet::new();
    for z in 0..=TOP {
        for x in 0..(1u32 << z) {
            for y in 0..(1u32 << z) {
                s.insert((z, x, y));
            }
        }
    }
    s
}

fn cover(req: &str) -> BTreeSet<(u8, u32, u32)> {
    AreaReq::parse(req).unwrap().tiles(0, TOP).unwrap().into_iter().map(|t| (t.1, t.2, t.3)).collect()
}

fn sha(b: &[u8]) -> String {
    Sha256::digest(b).iter().map(|b| format!("{b:02x}")).collect()
}

/// What the file host is told to do with the next request for a file.
#[derive(Clone, Copy, PartialEq)]
enum Serve {
    Whole,
    /// send half of what was asked, then end the response
    CutOnce,
    Missing,
}

struct World {
    _sc: Scratch,
    host: Fake,
    inner: Inner,
    files: Arc<Mutex<HashMap<String, Arc<Vec<u8>>>>>,
    serve: Arc<Mutex<Serve>>,
    /// every range asked of a file: (path, start, length)
    asked: Arc<Mutex<Vec<(String, u64, u64)>>>,
    planet_hits: Arc<AtomicUsize>,
}

impl World {
    fn new(tag: &str) -> World {
        let sc = Scratch::new(tag);
        let src = sc.path("planet.pmtiles");
        archive(&src, &world(), "planet");
        let planet = Arc::new(std::fs::read(&src).unwrap());
        let files: Arc<Mutex<HashMap<String, Arc<Vec<u8>>>>> = Default::default();
        let serve = Arc::new(Mutex::new(Serve::Whole));
        let asked: Arc<Mutex<Vec<(String, u64, u64)>>> = Default::default();
        let planet_hits = Arc::new(AtomicUsize::new(0));
        let (f2, s2, a2, p2) = (files.clone(), serve.clone(), asked.clone(), planet_hits.clone());
        let host = fake_host(0, move |url, range| {
            let slice = |b: &[u8], range: Option<(u64, u64)>| {
                let (o, l) = range.unwrap_or((0, b.len() as u64));
                let (s, e) = ((o as usize).min(b.len()), ((o + l) as usize).min(b.len()));
                b[s..e].to_vec()
            };
            if url == "/planet.pmtiles" {
                p2.fetch_add(1, Ordering::SeqCst);
                return (200, slice(&planet[..], range));
            }
            let Some(f) = f2.lock().unwrap().get(url).cloned() else { return (404, vec![]) };
            let (o, l) = range.unwrap_or((0, f.len() as u64));
            a2.lock().unwrap().push((url.to_string(), o, l));
            let mut s = s2.lock().unwrap();
            match *s {
                Serve::Missing => (404, vec![]),
                Serve::Whole => (200, slice(&f[..], range)),
                Serve::CutOnce => {
                    *s = Serve::Whole;
                    (200, slice(&f[..], Some((o, l / 2))))
                }
            }
        });
        let inner = engine(&sc);
        let def = json!({
            "format": 1, "id": "base", "title": "B", "kind": "raster", "transform": "as_is",
            "source": {"type": "pmtiles", "url": host.url("/planet.pmtiles"), "minzoom": 0, "maxzoom": TOP, "tile_format": "png"},
            "offline": {"allowed": true}, "update": {"version": PLANET}
        });
        inner.save_user_def(&def.to_string()).unwrap();
        World { _sc: sc, host, inner, files, serve, asked, planet_hits }
    }

    /// Publishes a file of `tiles` at `/files/<name>.pmtiles`; its entry in the region list.
    fn publish(&self, name: &str, tiles: &BTreeSet<(u8, u32, u32)>) -> RegionFile {
        let p = self._sc.path(&format!("{name}.pmtiles"));
        archive(&p, tiles, name);
        let b = std::fs::read(&p).unwrap();
        let path = format!("/files/{name}.pmtiles");
        let f = RegionFile { url: self.host.url(&path), bytes: b.len() as u64, sha256: sha(&b), planet: PLANET.into() };
        self.files.lock().unwrap().insert(path, Arc::new(b));
        f
    }

    fn file_requests(&self, f: &RegionFile) -> Vec<(u64, u64)> {
        let path = f.url.rsplit_once(&self.host.port.to_string()).unwrap().1.to_string();
        self.asked.lock().unwrap().iter().filter(|a| a.0 == path).map(|a| (a.1, a.2)).collect()
    }

    fn files_dir(&self) -> std::path::PathBuf {
        self.inner.dir.join("region-files")
    }

    fn part_of(&self, f: &RegionFile) -> std::path::PathBuf {
        self.files_dir().join(format!(".{}.pmtiles.part", f.sha256))
    }

    fn run(&self, req: &str, f: Option<&RegionFile>, cancel: &(dyn Fn() -> bool + Sync)) -> (Done, Vec<(u64, u64, Value)>) {
        let req = AreaReq::parse(req).unwrap();
        let seen = Mutex::new(Vec::new());
        let r = self.inner.run_download_with_file(&req, f, &|d, t, detail| seen.lock().unwrap().push((d, t, detail)), cancel).unwrap();
        (r, seen.into_inner().unwrap())
    }

    /// The tiles the store holds (with data), and each one's bytes are the planet's.
    fn stored(&self) -> BTreeSet<(u8, u32, u32)> {
        let st = self.inner.store_read("base").unwrap();
        let mut out = BTreeSet::new();
        for (z, x, y) in world() {
            if let Some(d) = st.get(z, x, y).unwrap() {
                assert_eq!(d, body(z, x, y), "{z}/{x}/{y}");
                out.insert((z, x, y));
            }
        }
        assert_eq!(st.tile_count(), out.len() as u64);
        out
    }

    fn no_files_left(&self) -> bool {
        std::fs::read_dir(self.files_dir()).map(|d| d.count() == 0).unwrap_or(true)
    }
}

const A: &str = r#"{"layer":"base","area":"ra","name":"A","bbox":[-114,42,-113,43],"minzoom":0,"maxzoom":6}"#;
const B: &str = r#"{"layer":"base","area":"rb","name":"B","bbox":[-113.5,42.5,-111,44],"minzoom":0,"maxzoom":6}"#;

fn never() -> bool {
    false
}

#[test]
fn a_region_with_a_file_fetches_it_once_and_the_store_ends_with_exactly_its_tiles() {
    let w = World::new("pc-once");
    let tiles = cover(A);
    let f = w.publish("a-once", &tiles);
    let (done, seen) = w.run(A, Some(&f), &never);
    assert!(matches!(done, Done::Finished));
    assert_eq!(w.file_requests(&f), vec![(0, f.bytes)], "one request for the whole file");
    assert_eq!(w.stored(), tiles);
    // the planet is opened (its header says what the store holds), and no tile is read from it
    assert!(w.planet_hits.load(Ordering::SeqCst) <= 2, "{} planet reads", w.planet_hits.load(Ordering::SeqCst));
    let areas = w.inner.areas("base");
    assert_eq!((areas.len(), areas[0].state.as_str()), (1, "complete"));
    assert!(w.no_files_left(), "the file is deleted once its tiles are in the store");
    // progress: the same total all the way, never back, ending done; bytes count the file
    let total = tiles.len() as u64;
    assert!(seen.iter().all(|s| s.1 == total), "{seen:?}");
    assert!(seen.windows(2).all(|p| p[0].0 <= p[1].0), "{seen:?}");
    assert_eq!(seen.last().map(|s| s.0), Some(total));
    assert_eq!(seen.last().unwrap().2["bytes"], json!(f.bytes));
}

#[test]
fn a_cut_connection_carries_on_from_the_partial_file() {
    let w = World::new("pc-cut");
    let tiles = cover(A);
    let f = w.publish("a-cut", &tiles);
    *w.serve.lock().unwrap() = Serve::CutOnce;
    let (done, _) = w.run(A, Some(&f), &never);
    assert!(matches!(done, Done::Finished));
    let half = f.bytes / 2;
    assert_eq!(w.file_requests(&f), vec![(0, f.bytes), (half, f.bytes - half)], "the second request starts where the first was cut");
    assert_eq!(w.stored(), tiles);
    assert!(w.no_files_left());
}

#[test]
fn a_download_stopped_during_the_file_carries_on_from_the_partial_file_next_time() {
    let w = World::new("pc-stop");
    let tiles = cover(A);
    let f = w.publish("a-stop", &tiles);
    *w.serve.lock().unwrap() = Serve::CutOnce;
    let part = w.part_of(&f);
    let p2 = part.clone();
    let stop = move || std::fs::metadata(&p2).map(|m| m.len() > 0).unwrap_or(false);
    let (done, _) = w.run(A, Some(&f), &stop);
    assert!(matches!(done, Done::Cancelled));
    let kept = std::fs::metadata(&part).unwrap().len();
    assert!(kept > 0 && kept < f.bytes, "a partial file under the hidden name: {kept} of {}", f.bytes);
    assert_eq!(w.inner.store_read("base").map(|s| s.tile_count()).unwrap_or(0), 0, "nothing copied yet");
    let (done, _) = w.run(A, Some(&f), &never);
    assert!(matches!(done, Done::Finished));
    let asked = w.file_requests(&f);
    assert_eq!(asked.last(), Some(&(kept, f.bytes - kept)), "the next start asks only for the rest: {asked:?}");
    assert_eq!(w.stored(), tiles);
    assert!(w.no_files_left());
}

#[test]
fn a_file_that_fails_its_check_falls_back_to_range_reads_and_still_completes() {
    let w = World::new("pc-sha");
    let tiles = cover(A);
    let mut f = w.publish("a-sha", &tiles);
    f.sha256 = "0".repeat(64);
    let (done, _) = w.run(A, Some(&f), &never);
    assert!(matches!(done, Done::Finished));
    assert_eq!(w.file_requests(&f).len(), 1);
    assert_eq!(w.stored(), tiles, "every tile of the area, read from the planet");
    assert!(w.planet_hits.load(Ordering::SeqCst) > 2);
    assert!(w.no_files_left(), "the file that failed is deleted");
}

#[test]
fn a_missing_file_falls_back_to_range_reads() {
    let w = World::new("pc-404");
    let tiles = cover(A);
    let f = w.publish("a-404", &tiles);
    *w.serve.lock().unwrap() = Serve::Missing;
    let (done, _) = w.run(A, Some(&f), &never);
    assert!(matches!(done, Done::Finished));
    assert_eq!(w.file_requests(&f).len(), 1, "a 404 is not asked again");
    assert_eq!(w.stored(), tiles);
    assert!(w.no_files_left());
}

#[test]
fn a_file_of_another_planet_build_or_for_fewer_zooms_is_not_fetched() {
    let w = World::new("pc-planet");
    let tiles = cover(A);
    let mut f = w.publish("a-planet", &tiles);
    f.planet = "8".into();
    let (done, _) = w.run(A, Some(&f), &never);
    assert!(matches!(done, Done::Finished));
    assert!(w.file_requests(&f).is_empty());
    assert_eq!(w.stored(), tiles);
    // an area stepped down below the layer's top zoom reads by ranges too
    let f = w.publish("b-zoom", &cover(B));
    let b5 = B.replace(r#""maxzoom":6"#, r#""maxzoom":5"#);
    let (done, _) = w.run(&b5, Some(&f), &never);
    assert!(matches!(done, Done::Finished));
    assert!(w.file_requests(&f).is_empty());
}

#[test]
fn an_overlapping_region_adds_only_the_tiles_its_file_has_that_are_not_here() {
    let w = World::new("pc-overlap");
    let (a, b) = (cover(A), cover(B));
    let shared: BTreeSet<_> = a.intersection(&b).copied().collect();
    assert!(!shared.is_empty() && shared.len() < b.len(), "the two regions overlap");
    let fa = w.publish("a-overlap", &a);
    let fb = w.publish("b-overlap", &b);
    assert!(matches!(w.run(A, Some(&fa), &never).0, Done::Finished));
    let before = w.planet_hits.load(Ordering::SeqCst);
    let (done, seen) = w.run(B, Some(&fb), &never);
    assert!(matches!(done, Done::Finished));
    let missing = (b.len() - shared.len()) as u64;
    assert!(seen.iter().all(|s| s.1 == missing), "B counts only the tiles not already here: {seen:?}");
    assert_eq!(seen.last().map(|s| s.0), Some(missing));
    assert_eq!(w.stored(), a.union(&b).copied().collect::<BTreeSet<_>>());
    assert!(w.planet_hits.load(Ordering::SeqCst) - before <= 2, "nothing of B read from the planet");
    // the delete rule is unchanged: removing A keeps the tiles B covers
    w.inner.delete_areas("base", Some("ra")).unwrap();
    assert_eq!(w.stored(), b);
}

#[test]
fn without_a_file_the_download_is_todays() {
    let w = World::new("pc-none");
    let (done, _) = w.run(A, None, &never);
    assert!(matches!(done, Done::Finished));
    assert_eq!(w.stored(), cover(A));
    assert!(!w.files_dir().exists(), "no folder for files is made");
}
