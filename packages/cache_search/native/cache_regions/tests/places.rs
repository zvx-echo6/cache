//! The places part of a region against a tiny local server that publishes like data.cached.info: routing at `/routing/`
//! (three tiles around Burley, Idaho) and places at `/places/` (the cache_places fixture cut into level 1 tiles, with its
//! common file).

use cache_places::fixture::{fixture_tiles, write_fixture_common, write_fixture_shard};
use cache_places::schema::{tile_id_l1, tile_path_l1};
use cache_places::PackSet;
use cache_regions::{Config, Regions};
use flate2::{write::GzEncoder, Compression};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Routing tiles of region A (as tests/regions.rs).
const ROUTING_TILES: [&str; 3] = ["0/002/986", "1/047/586", "2/000/763/464"];

const BURLEY: (f64, f64) = (42.5357, -113.7928);
const STANLEY: (f64, f64) = (44.2210, -114.9360);
const TWIN_FALLS: (f64, f64) = (42.5629, -114.4609);

fn gz(b: &[u8]) -> Vec<u8> {
    let mut e = GzEncoder::new(Vec::new(), Compression::default());
    e.write_all(b).unwrap();
    e.finish().unwrap()
}

fn hex(b: &[u8]) -> String {
    Sha256::digest(b).iter().map(|x| format!("{x:02x}")).collect()
}

fn rect(w: f64, s: f64, e: f64, n: f64) -> Value {
    json!({"type": "Feature", "properties": {}, "geometry": {"type": "Polygon", "coordinates": [[[w, s], [e, s], [e, n], [w, n], [w, s]]]}})
}

/// Inside Burley's level 1 places tile (1/047/586).
fn region_a() -> Value {
    rect(-113.95, 42.55, -113.80, 42.65)
}

/// A stretched east across 113 degrees west: Burley's places tile and the one east of it.
fn region_b() -> Value {
    rect(-113.95, 42.55, -112.90, 42.65)
}

fn burley() -> String {
    tile_path_l1(tile_id_l1(BURLEY.0, BURLEY.1))
}

fn burley_east() -> String {
    tile_path_l1(tile_id_l1(BURLEY.0, BURLEY.1) + 1)
}

struct Server {
    port: u16,
    files: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    damaged: Arc<Mutex<HashMap<String, usize>>>,
    hits: Arc<Mutex<Vec<String>>>,
    scratch: PathBuf,
}

impl Server {
    fn start(name: &str) -> Server {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let port = server.server_addr().to_ip().unwrap().port();
        let scratch = std::env::temp_dir().join(format!("cache-regions-places-srv-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&scratch);
        std::fs::create_dir_all(&scratch).unwrap();
        let s = Server { port, files: Arc::default(), damaged: Arc::default(), hits: Arc::default(), scratch };
        let (files, damaged, hits) = (s.files.clone(), s.damaged.clone(), s.hits.clone());
        std::thread::spawn(move || {
            for req in server.incoming_requests() {
                let url = req.url().to_string();
                hits.lock().unwrap().push(url.clone());
                let damage = match damaged.lock().unwrap().get_mut(&url) {
                    Some(n) if *n > 0 => {
                        *n -= 1;
                        true
                    }
                    _ => false,
                };
                let body = files.lock().unwrap().get(&url).cloned();
                let resp = match body {
                    Some(_) if damage => tiny_http::Response::from_data(gz(b"not the tile it should be")),
                    Some(b) => tiny_http::Response::from_data(b),
                    None => tiny_http::Response::from_data(Vec::new()).with_status_code(404),
                };
                let _ = req.respond(resp);
            }
        });
        s
    }

    fn base(&self) -> String {
        format!("http://127.0.0.1:{}/", self.port)
    }

    fn publish_routing(&self, build: &str) {
        let mut files = self.files.lock().unwrap();
        let mut lines = Vec::new();
        for p in ROUTING_TILES {
            let raw: Vec<u8> = format!("{build} {p} ").bytes().cycle().take(1000).collect();
            let z = gz(&raw);
            lines.push(format!("{p}\t{}\t{}\t{}", raw.len(), hex(&raw), z.len()));
            files.insert(format!("/routing/{build}/{p}.gph.gz"), z);
        }
        lines.sort();
        let index = gz(format!("{}\n", lines.join("\n")).as_bytes());
        let current = json!({"format": 1, "build": build, "index": format!("{build}/index.tsv.gz"), "index_sha256": hex(&index)});
        files.insert(format!("/routing/{build}/index.tsv.gz"), index);
        files.insert("/routing/current.json".into(), current.to_string().into_bytes());
    }

    /// Publishes places build `build`: the fixture's tiles, its common file, the index, then current.json.
    fn publish_places(&self, build: &str) {
        let mut lines = Vec::new();
        let mut put = Vec::new();
        for t in fixture_tiles() {
            let f = self.scratch.join(format!("{build}-{t}.sqlite"));
            write_fixture_shard(&f, t, build);
            let raw = std::fs::read(&f).unwrap();
            let z = gz(&raw);
            let path = tile_path_l1(t);
            lines.push(format!("{path}\t{}\t{}\t{}", raw.len(), hex(&raw), z.len()));
            put.push((format!("/places/{build}/{path}.sqlite.gz"), z));
        }
        let f = self.scratch.join(format!("{build}-common.sqlite"));
        write_fixture_common(&f, build);
        let common = std::fs::read(&f).unwrap();
        let common_gz = gz(&common);
        lines.sort();
        let index = gz(format!("{}\n", lines.join("\n")).as_bytes());
        let current = json!({
            "format": 1, "component": "places", "tile_schema": 1, "build": build, "levels": [1], "tiles": lines.len(),
            "index": format!("{build}/index.tsv.gz"), "index_sha256": hex(&index),
            "common": format!("{build}/common.sqlite.gz"), "common_sha256": hex(&common), "common_bytes": common.len(), "common_gz_bytes": common_gz.len(),
        });
        let mut files = self.files.lock().unwrap();
        for (k, v) in put {
            files.insert(k, v);
        }
        files.insert(format!("/places/{build}/common.sqlite.gz"), common_gz);
        files.insert(format!("/places/{build}/index.tsv.gz"), index);
        files.insert("/places/current.json".into(), current.to_string().into_bytes());
    }

    fn places_gz(&self, build: &str, path: &str) -> u64 {
        self.files.lock().unwrap()[&format!("/places/{build}/{path}.sqlite.gz")].len() as u64
    }

    fn common_gz(&self, build: &str) -> u64 {
        self.files.lock().unwrap()[&format!("/places/{build}/common.sqlite.gz")].len() as u64
    }

    fn damage_places(&self, build: &str, path: &str, times: usize) {
        self.damaged.lock().unwrap().insert(format!("/places/{build}/{path}.sqlite.gz"), times);
    }

    fn hits_of(&self, url: &str) -> usize {
        self.hits.lock().unwrap().iter().filter(|u| *u == url).count()
    }

    fn total(&self) -> usize {
        self.hits.lock().unwrap().len()
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.scratch);
    }
}

struct Tmp(PathBuf);

impl Tmp {
    fn new(name: &str) -> Tmp {
        let d = std::env::temp_dir().join(format!("cache-regions-places-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        Tmp(d)
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn engine(dir: &Path, srv: &Server, extra: Value) -> Regions {
    let mut cfg = json!({
        "dir": dir, "base_url": format!("{}routing/", srv.base()), "places_base_url": format!("{}places", srv.base()), "reserve_bytes": 0,
    });
    for (k, v) in extra.as_object().unwrap() {
        cfg[k] = v.clone();
    }
    let cfg: Config = serde_json::from_value(cfg).unwrap();
    Regions::open(cfg).unwrap()
}

fn call(e: &Regions, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {} ({})", err.message, err.code))
}

fn wait(what: &str, secs: u64, mut ok: impl FnMut() -> bool) {
    for _ in 0..secs * 20 {
        if ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    panic!("timed out waiting for {what}");
}

fn region(e: &Regions, id: &str) -> Value {
    let s = call(e, "status", json!({}));
    s["regions"].as_array().unwrap().iter().find(|r| r["id"] == id).cloned().unwrap_or(Value::Null)
}

fn wait_state(e: &Regions, id: &str, state: &str) {
    wait(&format!("{id} {state}"), 20, || region(e, id)["state"] == state);
}

/// The places tiles merged in, as the database says.
fn merged_tiles(e: &Regions) -> Vec<String> {
    let Some(db) = e.places_db() else { return Vec::new() };
    let c = rusqlite_open(&db);
    let mut v: Vec<String> = cache_places::merged::tiles(&c).unwrap().into_iter().map(tile_path_l1).collect();
    v.sort();
    v
}

fn rusqlite_open(p: &Path) -> rusqlite::Connection {
    rusqlite::Connection::open_with_flags(p, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).unwrap()
}

#[test]
fn plan_and_add_with_both_parts_then_search_the_merged_database() {
    let srv = Server::start("add");
    srv.publish_routing("r1");
    srv.publish_places("p1");
    let t = Tmp::new("add");
    let e = engine(&t.0, &srv, json!({}));
    let st = call(&e, "status", json!({}));
    assert_eq!(st["places"], json!({"build": null, "db": null, "tiles": 0, "generation": 0, "stream": {"tiles": 0, "bytes": 0, "cap": 536870912}, "update": null}));
    assert_eq!(st["updates"], json!({"routing": null, "places": null}));

    let plan = call(&e, "plan", json!({"id": "a", "name": "Burley", "geometry": region_a()}));
    let places_dl = srv.places_gz("p1", &burley()) + srv.common_gz("p1");
    assert_eq!(plan["tiles"], 3, "the top-level fields are routing's");
    assert_eq!(plan["parts"]["routing"]["tiles"], 3);
    assert_eq!(plan["parts"]["places"]["tiles"], 1);
    assert_eq!(plan["parts"]["places"]["download_bytes"], places_dl, "the tile and the common file");
    assert_eq!(plan["parts"]["places"]["shared_tiles"], 0);
    // Only one part asked for: only it.
    let only = call(&e, "plan", json!({"geometry": region_a(), "parts": ["places"]}));
    assert!(only["parts"].get("routing").is_none() && only["parts"]["places"]["tiles"] == 1, "{only}");
    assert_eq!(e.call("plan", &json!({"geometry": region_a(), "parts": ["maps"]})).unwrap_err().code, "bad_json");
    assert!(e.places_db().is_none(), "a plan sets nothing up");

    let added = call(&e, "add", json!({"id": "a", "name": "Burley", "geometry": region_a()}));
    assert_eq!(added["tiles"], 3);
    assert_eq!(added["parts"]["places"]["tiles"], 1);
    wait_state(&e, "a", "ready");
    let r = region(&e, "a");
    assert_eq!(r["parts"]["routing"]["state"], "ready");
    assert_eq!(r["parts"]["places"]["state"], "ready");
    assert_eq!(r["parts"]["places"]["done_tiles"], 1);
    let st = call(&e, "status", json!({}));
    assert_eq!(st["places"]["build"], "p1");
    assert_eq!(st["places"]["tiles"], 1);
    assert!(st["places"]["generation"].as_u64().unwrap() >= 2, "set up and one merge");
    assert_eq!(merged_tiles(&e), vec![burley()]);
    let db = e.places_db().unwrap();
    assert_eq!(db, t.0.join("places").join("p1.sqlite"));
    assert_eq!(st["places"]["db"], &*db.to_string_lossy());
    assert_eq!(std::fs::read_to_string(t.0.join("places").join("CURRENT")).unwrap(), "p1");
    assert!(t.0.join("places").join("p1").join("common.sqlite").is_file());
    assert!(t.0.join("places").join("index").join("p1.tsv").is_file());
    assert_eq!(srv.hits_of(&format!("/places/p1/{}.sqlite.gz", burley())), 1);

    // The readers find it from the folder alone, and it is the region's.
    let set = PackSet::new(vec![], e.places_dir());
    let packs = set.current();
    assert_eq!(packs.len(), 1);
    assert_eq!(packs[0].meta.region_name, "Burley");
    assert!(packs[0].covers(BURLEY.0, BURLEY.1) && !packs[0].covers(STANLEY.0, STANLEY.1));
    assert_eq!(packs[0].category("pharmacy").unwrap().place_count, 3);

    // Added again with places only: it keeps routing (parts only ever grow).
    let again = call(&e, "add", json!({"id": "a", "name": "Burley", "geometry": region_a(), "parts": ["places"]}));
    assert!(again["parts"].get("routing").is_some(), "{again}");
    assert_eq!(again["parts"]["places"]["download_bytes"], 0);
}

#[test]
fn regions_share_places_tiles_and_removing_one_keeps_the_others() {
    let srv = Server::start("share");
    srv.publish_routing("r1");
    srv.publish_places("p1");
    let t = Tmp::new("share");
    let e = engine(&t.0, &srv, json!({}));
    call(&e, "add", json!({"id": "a", "name": "A", "geometry": region_a()}));
    let plan = call(&e, "plan", json!({"geometry": region_b()}));
    wait_state(&e, "a", "ready");
    let plan_after = call(&e, "plan", json!({"geometry": region_b()}));
    assert_eq!(plan["parts"]["places"]["tiles"], 2);
    assert_eq!(plan_after["parts"]["places"]["shared_tiles"], 1);
    assert_eq!(plan_after["parts"]["places"]["download_bytes"], srv.places_gz("p1", &burley_east()), "one tile, no common file");
    call(&e, "add", json!({"id": "b", "name": "B", "geometry": region_b()}));
    wait_state(&e, "b", "ready");
    assert_eq!(merged_tiles(&e), vec![burley(), burley_east()]);
    assert_eq!(srv.hits_of(&format!("/places/p1/{}.sqlite.gz", burley())), 1, "a shared tile is fetched once");
    let set = PackSet::new(vec![], e.places_dir());
    assert_eq!(set.current()[0].meta.region_name, "A, B");

    let gone = call(&e, "remove", json!({"id": "b"}));
    assert_eq!(gone["parts"]["places"], json!({"deleted_tiles": 1}));
    assert_eq!(gone["deleted_tiles"], gone["parts"]["routing"]["deleted_tiles"].as_u64().unwrap() + 1);
    assert_eq!(merged_tiles(&e), vec![burley()]);
    assert_eq!(set.current()[0].meta.region_name, "A");
    let gone = call(&e, "remove", json!({"id": "a"}));
    assert_eq!(gone["parts"]["places"], json!({"deleted_tiles": 1}));
    assert!(merged_tiles(&e).is_empty());
    assert_eq!(call(&e, "status", json!({}))["places"]["tiles"], 0);
}

#[test]
fn a_search_streams_its_tiles_and_the_cap_evicts_only_stream_tiles() {
    let srv = Server::start("stream");
    srv.publish_routing("r1");
    srv.publish_places("p1");
    let t = Tmp::new("stream");
    let e = engine(&t.0, &srv, json!({"places_stream_cap_bytes": 1}));
    // A fresh device online with nothing downloaded: the first search sets up the newest build and fetches its tiles.
    let s = call(&e, "stream", json!({"component": "places", "points": [[STANLEY.0, STANLEY.1]], "timeout_ms": 10000}));
    let stanley_tiles = s["fetched"].as_u64().unwrap();
    assert!(stanley_tiles >= 2, "{s}");
    assert_eq!(s["pending"], 0);
    assert_eq!(s["missing"], 0);
    assert_eq!(s["ok"], true);
    let st = call(&e, "status", json!({}));
    assert_eq!(st["places"]["build"], "p1");
    assert_eq!(st["places"]["stream"]["tiles"], stanley_tiles, "the search's own tiles stay over the cap");
    assert!(merged_tiles(&e).contains(&tile_path_l1(tile_id_l1(STANLEY.0, STANLEY.1))));
    assert_eq!(call(&e, "stream", json!({"component": "places", "points": [[STANLEY.0, STANLEY.1]]}))["fetched"], 0, "already here");

    call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    wait_state(&e, "a", "ready");
    // Another search: its tiles come, the earlier search's go (over the cap); the region's stays.
    let s = e.prepare_places(TWIN_FALLS.0, TWIN_FALLS.1, Duration::from_secs(10));
    assert!(s.ok && s.fetched >= 1, "{s:?}");
    let have = merged_tiles(&e);
    assert!(have.contains(&burley()), "{have:?}");
    assert!(have.contains(&tile_path_l1(tile_id_l1(TWIN_FALLS.0, TWIN_FALLS.1))), "{have:?}");
    assert!(!have.contains(&tile_path_l1(tile_id_l1(STANLEY.0, STANLEY.1))), "evicted: {have:?}");
    assert_eq!(call(&e, "status", json!({}))["places"]["stream"]["tiles"], s.fetched);
    assert!(e.places_generation() > 0);

    // Offline: at once, nothing fetched, and what is missing is counted.
    call(&e, "set_policy", json!({"network": false}));
    let before = srv.total();
    let s = call(&e, "stream", json!({"component": "places", "points": [[STANLEY.0, STANLEY.1]]}));
    assert_eq!(s["ok"], false);
    assert_eq!(s["fetched"], 0);
    assert!(s["missing"].as_u64().unwrap() >= 1, "{s}");
    assert_eq!(srv.total(), before);
}

#[test]
fn a_places_update_fills_the_new_build_beside_the_old_and_switches_through_current() {
    let srv = Server::start("update");
    srv.publish_routing("r1");
    srv.publish_places("p1");
    let t = Tmp::new("update");
    let e = engine(&t.0, &srv, json!({}));
    call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    wait_state(&e, "a", "ready");
    assert_eq!(call(&e, "check_update", json!({"component": "places"})), json!({"build": "p1", "update": null}));

    srv.publish_places("p2");
    srv.damage_places("p2", &burley(), 100);
    let left = srv.places_gz("p2", &burley()) + srv.common_gz("p2");
    let both = call(&e, "check_update", json!({}));
    assert_eq!(both["update"], Value::Null, "routing has no update");
    assert_eq!(both["places"], json!({"build": "p2", "update": {"build": "p2", "download_bytes": left}}));
    assert_eq!(call(&e, "status", json!({}))["updates"]["places"], json!({"build": "p2", "download_bytes": left, "downloading": false}));
    let u = call(&e, "update", json!({"component": "places"}));
    assert_eq!(u["build"], "p2");
    wait("the places part to fail", 20, || region(&e, "a")["parts"]["places"]["state"] == "failed");
    // The new build is not complete: searches stay on p1.
    assert_eq!(std::fs::read_to_string(t.0.join("places").join("CURRENT")).unwrap(), "p1");
    assert_eq!(e.places_db().unwrap(), t.0.join("places").join("p1.sqlite"));
    assert!(t.0.join("places").join("p2.sqlite").is_file(), "built beside it");
    assert_eq!(region(&e, "a")["parts"]["routing"]["state"], "ready", "routing is not affected");

    srv.damage_places("p2", &burley(), 0);
    call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    wait("the switch to p2", 20, || call(&e, "status", json!({}))["places"]["build"] == "p2");
    wait_state(&e, "a", "ready");
    assert_eq!(std::fs::read_to_string(t.0.join("places").join("CURRENT")).unwrap(), "p2");
    assert_eq!(merged_tiles(&e), vec![burley()]);
    let st = call(&e, "status", json!({}));
    assert_eq!(st["places"]["update"], Value::Null);
    assert!(!t.0.join("places").join("p1.sqlite").exists(), "the old database goes");
    assert!(!t.0.join("places").join("p1").exists());
    assert!(!t.0.join("places").join("index").join("p1.tsv").exists());
    let set = PackSet::new(vec![], e.places_dir());
    assert!(set.current()[0].path.ends_with("p2.sqlite"));
}

#[test]
fn a_failing_places_tile_fails_only_the_places_part() {
    let srv = Server::start("fail");
    srv.publish_routing("r1");
    srv.publish_places("p1");
    srv.damage_places("p1", &burley(), 100);
    let t = Tmp::new("fail");
    let e = engine(&t.0, &srv, json!({}));
    call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    wait_state(&e, "a", "failed");
    wait("routing", 20, || region(&e, "a")["parts"]["routing"]["state"] == "ready");
    let r = region(&e, "a");
    assert_eq!(r["parts"]["places"]["state"], "failed");
    assert!(r["parts"]["places"]["error"].as_str().unwrap().contains(&burley()), "{r}");
    assert_eq!(r["error"], Value::Null, "routing's error");
    assert_eq!(srv.hits_of(&format!("/places/p1/{}.sqlite.gz", burley())), 4);
    assert!(merged_tiles(&e).is_empty());
    // Added again once the server is right: tried again.
    srv.damage_places("p1", &burley(), 0);
    call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    wait_state(&e, "a", "ready");
}

#[test]
fn a_tile_cut_off_between_download_and_merge_is_fetched_again() {
    let srv = Server::start("crash");
    srv.publish_routing("r1");
    srv.publish_places("p1");
    let t = Tmp::new("crash");
    {
        let e = engine(&t.0, &srv, json!({}));
        call(&e, "plan", json!({"geometry": region_a()}));
        call(&e, "set_policy", json!({"network": false}));
        // Offline with no places build yet: the region is recorded and its places wait for the network.
        let added = call(&e, "add", json!({"id": "a", "geometry": region_a()}));
        assert_eq!(added["parts"]["places"]["code"], "offline", "{added}");
        wait("paused", 20, || region(&e, "a")["parts"]["places"]["state"] == "paused");
    }
    let junk = t.0.join("places").join(".incoming").join("p1").join(format!("{}.sqlite", burley()));
    std::fs::create_dir_all(junk.parent().unwrap()).unwrap();
    std::fs::write(&junk, b"half a tile").unwrap();
    let e = engine(&t.0, &srv, json!({}));
    assert!(!junk.exists(), "cleared on open");
    wait_state(&e, "a", "ready");
    assert_eq!(merged_tiles(&e), vec![burley()]);
}

#[test]
fn an_old_regions_database_is_routing_only_and_keeps_working() {
    let srv = Server::start("migrate");
    srv.publish_routing("r1");
    srv.publish_places("p1");
    let t = Tmp::new("migrate");
    std::fs::create_dir_all(&t.0).unwrap();
    {
        // The layout before places, with one region and its tiles of r1.
        let c = rusqlite::Connection::open(t.0.join("regions.sqlite")).unwrap();
        c.execute_batch(
            "CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE regions(id TEXT PRIMARY KEY, name TEXT NOT NULL, geometry TEXT NOT NULL, added INTEGER NOT NULL, error TEXT);
             CREATE TABLE region_tiles(region TEXT NOT NULL, build TEXT NOT NULL, path TEXT NOT NULL, bytes INTEGER NOT NULL,
                                       sha256 TEXT NOT NULL, gz INTEGER NOT NULL, PRIMARY KEY(region, build, path));
             CREATE TABLE stream(build TEXT NOT NULL, path TEXT NOT NULL, bytes INTEGER NOT NULL, last_used INTEGER NOT NULL, PRIMARY KEY(build, path));
             INSERT INTO meta VALUES ('build', 'r1');",
        )
        .unwrap();
        c.execute("INSERT INTO regions VALUES ('a', 'Burley', ?1, 1, NULL)", [region_a().to_string()]).unwrap();
        let idx = srv.files.lock().unwrap()["/routing/r1/index.tsv.gz"].clone();
        let mut text = String::new();
        std::io::Read::read_to_string(&mut flate2::read::GzDecoder::new(&idx[..]), &mut text).unwrap();
        // An old device has the build's index too, as it was kept when fetched.
        std::fs::create_dir_all(t.0.join("index")).unwrap();
        std::fs::write(t.0.join("index").join("r1.tsv"), &text).unwrap();
        for line in text.lines() {
            let f: Vec<&str> = line.split('\t').collect();
            c.execute("INSERT INTO region_tiles VALUES ('a', 'r1', ?1, ?2, ?3, ?4)", rusqlite::params![f[0], f[1].parse::<i64>().unwrap(), f[2], f[3].parse::<i64>().unwrap()]).unwrap();
        }
        c.execute("INSERT INTO stream VALUES ('r1', '2/000/763/465', 1000, 5)", []).unwrap();
    }
    let e = engine(&t.0, &srv, json!({}));
    wait_state(&e, "a", "ready");
    let r = region(&e, "a");
    assert_eq!(r["parts"].as_object().unwrap().keys().collect::<Vec<_>>(), ["routing"]);
    assert_eq!(r["tiles"], 3);
    assert!(e.places_db().is_none(), "nothing asked for places");
    drop(e);
    let c = rusqlite::Connection::open(t.0.join("regions.sqlite")).unwrap();
    let n = |sql: &str| c.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
    assert_eq!(n("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('region_tiles', 'stream')"), 0);
    assert_eq!(n("SELECT COUNT(*) FROM region_tiles2 WHERE component = 'routing'"), 3);
    assert_eq!(n("SELECT COUNT(*) FROM stream2 WHERE component = 'routing'"), 1);
    let parts: String = c.query_row("SELECT parts FROM regions WHERE id = 'a'", [], |r| r.get(0)).unwrap();
    assert_eq!(parts, r#"["routing"]"#);
    drop(c);
    // Places offered later: the region gains its places part.
    let e = engine(&t.0, &srv, json!({}));
    call(&e, "add", json!({"id": "a", "name": "Burley", "geometry": region_a(), "parts": ["places"]}));
    wait_state(&e, "a", "ready");
    assert_eq!(region(&e, "a")["parts"].as_object().unwrap().len(), 2);
    assert_eq!(merged_tiles(&e), vec![burley()]);
}

#[test]
fn without_places_base_url_there_is_no_places_part() {
    let srv = Server::start("off");
    srv.publish_routing("r1");
    let t = Tmp::new("off");
    let cfg: Config = serde_json::from_value(json!({"dir": t.0, "base_url": format!("{}routing/", srv.base()), "reserve_bytes": 0})).unwrap();
    let e = Regions::open(cfg).unwrap();
    let st = call(&e, "status", json!({}));
    assert!(st.get("places").is_none() && st.get("updates").is_none());
    assert!(call(&e, "plan", json!({"geometry": region_a()})).get("parts").is_none());
    assert_eq!(e.call("plan", &json!({"geometry": region_a(), "parts": ["places"]})).unwrap_err().code, "bad_json");
    assert_eq!(call(&e, "stream", json!({"component": "places", "points": [[BURLEY.0, BURLEY.1]]})), json!({"fetched": 0, "pending": 0, "missing": 0, "ok": false}));
    assert!(e.places_dir().is_none() && e.places_db().is_none());
    assert_eq!(cache_regions::DEFAULT_BASE_URL, "https://data.cached.info/routing/");
}

#[test]
fn offline_with_nothing_on_the_device_neither_part_plans() {
    let srv = Server::start("fresh");
    srv.publish_routing("r1");
    srv.publish_places("p1");
    let t = Tmp::new("fresh");
    let e = engine(&t.0, &srv, json!({}));
    call(&e, "set_policy", json!({"network": false}));
    assert_eq!(e.call("plan", &json!({"geometry": region_a()})).unwrap_err().code, "offline");
    assert_eq!(call(&e, "stream", json!({"component": "places", "points": [[BURLEY.0, BURLEY.1]]})), json!({"fetched": 0, "pending": 0, "missing": 0, "ok": false}));
    assert_eq!(srv.total(), 0);
    // Online, the places part alone can be planned even when routing cannot.
    call(&e, "set_policy", json!({"network": true}));
    srv.files.lock().unwrap().remove("/routing/current.json");
    let plan = call(&e, "plan", json!({"geometry": region_a()}));
    assert_eq!(plan["parts"]["routing"]["code"], "fetch_failed");
    assert_eq!(plan["parts"]["places"]["tiles"], 1);
}
