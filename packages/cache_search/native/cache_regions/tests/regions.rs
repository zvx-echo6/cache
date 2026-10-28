//! The regions engine against a tiny local routing server that publishes like cache.echo6.co/routing/: current.json, a
//! gzipped index and gzipped tiles. Seven tiles with roads: three around Burley, Idaho (one per level), one more level 2 tile
//! east of them, and three near North Platte, Nebraska.

use cache_regions::{Config, Regions};
use flate2::{write::GzEncoder, Compression};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

/// Region A's tiles: the level 0, 1 and 2 tiles of a box smaller than one level 2 tile near Burley.
const A: [&str; 3] = ["0/002/986", "1/047/586", "2/000/763/464"];
/// The level 2 tile east of A's: region B is A's box stretched east into it.
const B_ONLY: &str = "2/000/763/465";
/// Near North Platte: one tile per level.
const FAR: [&str; 3] = ["0/002/899", "1/046/879", "2/000/749/119"];
const TILE_BYTES: usize = 1000;

fn all() -> Vec<&'static str> {
    let mut v: Vec<&str> = A.to_vec();
    v.push(B_ONLY);
    v.extend(FAR);
    v
}

fn gz(b: &[u8]) -> Vec<u8> {
    let mut e = GzEncoder::new(Vec::new(), Compression::default());
    e.write_all(b).unwrap();
    e.finish().unwrap()
}

fn hex(b: &[u8]) -> String {
    Sha256::digest(b).iter().map(|x| format!("{x:02x}")).collect()
}

/// A tile's content in a build: different in every build, always TILE_BYTES long.
fn tile(build: &str, path: &str) -> Vec<u8> {
    let seed = format!("{build} {path} ");
    seed.bytes().cycle().take(TILE_BYTES).collect()
}

fn gz_len(build: &str, path: &str) -> u64 {
    gz(&tile(build, path)).len() as u64
}

fn rect(w: f64, s: f64, e: f64, n: f64) -> Value {
    json!({"type": "Feature", "properties": {}, "geometry": {"type": "Polygon", "coordinates": [[[w, s], [e, s], [e, n], [w, n], [w, s]]]}})
}

fn region_a() -> Value {
    rect(-113.95, 42.55, -113.80, 42.65)
}

fn region_b() -> Value {
    rect(-113.95, 42.55, -113.55, 42.65)
}

struct Server {
    port: u16,
    files: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    /// Paths answered with a damaged tile this many more times before the real one.
    damaged: Arc<Mutex<HashMap<String, usize>>>,
    hits: Arc<Mutex<Vec<String>>>,
    last_ua: Arc<Mutex<String>>,
}

impl Server {
    fn start() -> Server {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let port = server.server_addr().to_ip().unwrap().port();
        let s = Server { port, files: Arc::default(), damaged: Arc::default(), hits: Arc::default(), last_ua: Arc::default() };
        let (files, damaged, hits, ua) = (s.files.clone(), s.damaged.clone(), s.hits.clone(), s.last_ua.clone());
        std::thread::spawn(move || {
            for req in server.incoming_requests() {
                let url = req.url().to_string();
                hits.lock().unwrap().push(url.clone());
                *ua.lock().unwrap() = req.headers().iter().find(|h| h.field.equiv("User-Agent")).map(|h| h.value.to_string()).unwrap_or_default();
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

    /// Publishes `build` (its seven tiles and index) and makes it the current one.
    fn publish(&self, build: &str) {
        let mut files = self.files.lock().unwrap();
        let mut lines = Vec::new();
        for p in all() {
            let raw = tile(build, p);
            let z = gz(&raw);
            lines.push(format!("{p}\t{}\t{}\t{}", raw.len(), hex(&raw), z.len()));
            files.insert(format!("/{build}/{p}.gph.gz"), z);
        }
        lines.sort();
        let index = gz(format!("{}\n", lines.join("\n")).as_bytes());
        let current = json!({
            "format": 1, "build": build, "valhalla": "3.7.0", "source": "test", "tiles": lines.len(),
            "bytes": lines.len() * TILE_BYTES, "gz_bytes": 0, "index": format!("{build}/index.tsv.gz"), "index_sha256": hex(&index),
        });
        files.insert(format!("/{build}/index.tsv.gz"), index);
        files.insert("/current.json".into(), current.to_string().into_bytes());
    }

    fn damage(&self, build: &str, path: &str, times: usize) {
        self.damaged.lock().unwrap().insert(format!("/{build}/{path}.gph.gz"), times);
    }

    fn total(&self) -> usize {
        self.hits.lock().unwrap().len()
    }

    fn hits_of(&self, build: &str, path: &str) -> usize {
        let want = format!("/{build}/{path}.gph.gz");
        self.hits.lock().unwrap().iter().filter(|u| **u == want).count()
    }

    fn tile_hits(&self) -> usize {
        self.hits.lock().unwrap().iter().filter(|u| u.ends_with(".gph.gz")).count()
    }
}

struct Tmp(PathBuf);

impl Tmp {
    fn new(name: &str) -> Tmp {
        let d = std::env::temp_dir().join(format!("cache-regions-test-{}-{name}", std::process::id()));
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
    let mut cfg = json!({"dir": dir, "base_url": srv.base(), "reserve_bytes": 0});
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

fn tile_file(dir: &Path, build: &str, path: &str) -> PathBuf {
    dir.join("tiles").join(build).join(format!("{path}.gph"))
}

/// Every file under `dir` whose name starts with '.' (a temp file left behind).
fn hidden_files(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut todo = vec![dir.to_path_buf()];
    while let Some(d) = todo.pop() {
        for e in std::fs::read_dir(&d).into_iter().flatten().flatten() {
            if e.path().is_dir() {
                todo.push(e.path());
            } else if e.file_name().to_string_lossy().starts_with('.') {
                out.push(e.path());
            }
        }
    }
    out
}

#[test]
fn plan_then_add_downloads_every_tile_checked() {
    let srv = Server::start();
    srv.publish("b1");
    let t = Tmp::new("add");
    let e = engine(&t.0, &srv, json!({}));
    let st = call(&e, "status", json!({}));
    assert_eq!(st, json!({"build": null, "tile_dir": null, "regions": [], "stream": {"tiles": 0, "bytes": 0, "cap": 2147483648u64}, "update": null, "paused": null}));

    let a_gz: u64 = A.iter().map(|p| gz_len("b1", p)).sum();
    let plan = call(&e, "plan", json!({"id": "a", "name": "Burley", "geometry": region_a()}));
    assert_eq!(plan, json!({"tiles": 3, "bytes": 3000, "download_bytes": a_gz, "shared_tiles": 0}));
    assert_eq!(srv.tile_hits(), 0, "a plan fetches no tiles");

    let added = call(&e, "add", json!({"id": "a", "name": "Burley", "geometry": region_a()}));
    assert_eq!(added, json!({"ok": true, "tiles": 3, "bytes": 3000, "download_bytes": a_gz}));
    wait_state(&e, "a", "ready");
    for p in A {
        assert_eq!(std::fs::read(tile_file(&t.0, "b1", p)).unwrap(), tile("b1", p), "{p}");
        assert_eq!(srv.hits_of("b1", p), 1, "{p} fetched once");
    }
    assert!(hidden_files(&t.0.join("tiles")).is_empty(), "{:?}", hidden_files(&t.0.join("tiles")));
    assert!(srv.last_ua.lock().unwrap().starts_with("Cache/"));
    let st = call(&e, "status", json!({}));
    assert_eq!(st["build"], "b1");
    assert_eq!(st["tile_dir"], &*t.0.join("tiles").join("b1").to_string_lossy());
    assert_eq!(
        st["regions"],
        json!([{"id": "a", "name": "Burley", "state": "ready", "tiles": 3, "bytes": 3000, "done_tiles": 3, "done_bytes": 3000, "error": null}])
    );
    assert_eq!(st["paused"], Value::Null);
    assert_eq!(e.tile_dir(), Some(t.0.join("tiles").join("b1")));

    // B overlaps A: only its one other tile is to fetch.
    let plan = call(&e, "plan", json!({"id": "b", "geometry": region_b()}));
    assert_eq!(plan, json!({"tiles": 4, "bytes": 4000, "download_bytes": gz_len("b1", B_ONLY), "shared_tiles": 3}));
    // The cached index answers once the server is gone (it was checked against index_sha256 when fetched).
    assert!(t.0.join("index").join("b1.tsv").is_file());
}

#[test]
fn a_damaged_tile_is_tried_again_and_then_its_region_fails() {
    let srv = Server::start();
    srv.publish("b1");
    srv.damage("b1", "2/000/763/464", 2);
    let t = Tmp::new("damaged");
    let e = engine(&t.0, &srv, json!({}));
    call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    wait_state(&e, "a", "ready");
    assert_eq!(srv.hits_of("b1", "2/000/763/464"), 3, "two damaged answers, then the tile");
    assert_eq!(std::fs::read(tile_file(&t.0, "b1", "2/000/763/464")).unwrap(), tile("b1", "2/000/763/464"));
    drop(e);

    // Damaged every time: four tries in all, then the region fails with the reason; nothing half-written is left.
    srv.damage("b1", "2/000/763/464", 100);
    let t2 = Tmp::new("damaged-for-good");
    let e = engine(&t2.0, &srv, json!({}));
    let before = srv.hits_of("b1", "2/000/763/464");
    call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    wait_state(&e, "a", "failed");
    let r = region(&e, "a");
    assert!(r["error"].as_str().unwrap().contains("2/000/763/464"), "{r}");
    assert_eq!(srv.hits_of("b1", "2/000/763/464") - before, 4);
    assert!(!tile_file(&t2.0, "b1", "2/000/763/464").exists());
    assert_eq!(r["done_tiles"], 2);
    assert!(hidden_files(&t2.0.join("tiles")).is_empty());
    // Added again once the server is right: it is tried again and completes.
    srv.damage("b1", "2/000/763/464", 0);
    call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    wait_state(&e, "a", "ready");
}

#[test]
fn remove_keeps_the_tiles_another_region_uses() {
    let srv = Server::start();
    srv.publish("b1");
    let t = Tmp::new("remove");
    let e = engine(&t.0, &srv, json!({}));
    call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    call(&e, "add", json!({"id": "b", "geometry": region_b()}));
    wait_state(&e, "a", "ready");
    wait_state(&e, "b", "ready");
    assert_eq!(srv.tile_hits(), 4, "the shared tiles are fetched once");

    assert_eq!(call(&e, "remove", json!({"id": "b"})), json!({"ok": true, "deleted_tiles": 1}));
    assert!(!tile_file(&t.0, "b1", B_ONLY).exists());
    for p in A {
        assert!(tile_file(&t.0, "b1", p).exists(), "{p} is A's too");
    }
    assert_eq!(call(&e, "remove", json!({"id": "a"})), json!({"ok": true, "deleted_tiles": 3}));
    // Empty folders go with their last tile.
    assert_eq!(std::fs::read_dir(t.0.join("tiles").join("b1")).unwrap().count(), 0);
    assert_eq!(call(&e, "status", json!({}))["regions"], json!([]));
    assert_eq!(e.call("remove", &json!({"id": "a"})).unwrap_err().code, "not_found");
}

#[test]
fn no_request_at_all_while_the_network_is_off() {
    let srv = Server::start();
    srv.publish("b1");
    let t = Tmp::new("offline");
    let e = engine(&t.0, &srv, json!({}));
    call(&e, "plan", json!({"id": "a", "geometry": region_a()}));
    assert_eq!(call(&e, "set_policy", json!({"network": false})), json!({"ok": true}));
    let before = srv.total();

    // Planned and added from the index already on the device; nothing is fetched.
    let added = call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    assert_eq!(added["tiles"], 3);
    wait_state(&e, "a", "paused");
    assert_eq!(call(&e, "status", json!({}))["paused"], "Paused: no network it may use");
    assert_eq!(call(&e, "plan", json!({"geometry": region_b()}))["tiles"], 4);
    assert_eq!(call(&e, "stream", json!({"points": [[42.6, -113.9]], "timeout_ms": 5000})), json!({"fetched": 0, "missing": 4, "ok": false}));
    assert_eq!(e.call("check_update", &json!({})).unwrap_err().code, "offline");
    std::thread::sleep(Duration::from_millis(600));
    assert_eq!(srv.total(), before, "no request while the network is off");

    call(&e, "set_policy", json!({"network": true}));
    wait_state(&e, "a", "ready");
    assert_eq!(call(&e, "status", json!({}))["paused"], Value::Null);
}

#[test]
fn a_fresh_device_offline_cannot_plan() {
    let srv = Server::start();
    srv.publish("b1");
    let t = Tmp::new("fresh-offline");
    let e = engine(&t.0, &srv, json!({}));
    call(&e, "set_policy", json!({"network": false}));
    assert_eq!(e.call("plan", &json!({"geometry": region_a()})).unwrap_err().code, "offline");
    assert_eq!(e.call("add", &json!({"id": "a", "geometry": region_a()})).unwrap_err().code, "offline");
    assert_eq!(call(&e, "stream", json!({"points": [[42.6, -113.9]]})), json!({"fetched": 0, "missing": 0, "ok": false}));
    assert_eq!(srv.total(), 0);
    assert_eq!(e.call("plan", &json!({"id": "a"})).unwrap_err().code, "bad_json");
}

#[test]
fn a_restart_carries_on_and_clears_what_a_stopped_write_left() {
    let srv = Server::start();
    srv.publish("b1");
    let t = Tmp::new("restart");
    {
        let e = engine(&t.0, &srv, json!({}));
        call(&e, "plan", json!({"geometry": region_a()}));
        call(&e, "set_policy", json!({"network": false}));
        call(&e, "add", json!({"id": "a", "name": "Burley", "geometry": region_a()}));
        wait_state(&e, "a", "paused");
    }
    // As if a write had been cut off: a hidden temp file beside where the tile goes.
    let junk = t.0.join("tiles/b1/2/000/763/.464.gph.1.0.tmp");
    std::fs::create_dir_all(junk.parent().unwrap()).unwrap();
    std::fs::write(&junk, b"half a ti").unwrap();
    let e = engine(&t.0, &srv, json!({}));
    assert!(!junk.exists(), "cleared on open");
    wait_state(&e, "a", "ready");
    assert_eq!(region(&e, "a")["name"], "Burley");
    for p in A {
        assert_eq!(std::fs::read(tile_file(&t.0, "b1", p)).unwrap(), tile("b1", p));
    }
}

#[test]
fn stream_fetches_near_the_route_and_keeps_within_the_cap() {
    let srv = Server::start();
    srv.publish("b1");
    let t = Tmp::new("stream");
    let e = engine(&t.0, &srv, json!({"stream_cap_bytes": 3000}));
    // A fresh device: the newest build is taken. Near Burley: A's three tiles and the one east of them.
    let s = call(&e, "stream", json!({"points": [[42.6, -113.9]], "timeout_ms": 10000}));
    assert_eq!(s, json!({"fetched": 4, "missing": 0, "ok": true}));
    let st = call(&e, "status", json!({}));
    assert_eq!(st["build"], "b1");
    // The route's own tiles stay even over the cap.
    assert_eq!(st["stream"], json!({"tiles": 4, "bytes": 4000, "cap": 3000}));

    // A region over tiles already here: nothing to fetch, and they are the region's now, not the stream cache's.
    assert_eq!(call(&e, "add", json!({"id": "a", "geometry": region_a()}))["download_bytes"], 0);
    wait_state(&e, "a", "ready");
    assert_eq!(call(&e, "status", json!({}))["stream"], json!({"tiles": 1, "bytes": 1000, "cap": 3000}));

    // Another route far away: its three tiles come, the oldest stream-only tile goes; the region's stay.
    let s = call(&e, "stream", json!({"points": [[40.1, -100.15], [40.12, -100.13]]}));
    assert_eq!(s, json!({"fetched": 3, "missing": 0, "ok": true}));
    assert!(!tile_file(&t.0, "b1", B_ONLY).exists(), "evicted");
    for p in A.iter().chain(FAR.iter()) {
        assert!(tile_file(&t.0, "b1", p).exists(), "{p}");
    }
    assert_eq!(call(&e, "status", json!({}))["stream"], json!({"tiles": 3, "bytes": 3000, "cap": 3000}));

    // The region goes; its tiles were used by a route, so they stay in the stream cache until the cap needs the room.
    assert_eq!(call(&e, "remove", json!({"id": "a"})), json!({"ok": true, "deleted_tiles": 0}));
    assert!(tile_file(&t.0, "b1", A[2]).exists());
    let s = call(&e, "stream", json!({"points": [[40.1, -100.15]]}));
    assert_eq!(s, json!({"fetched": 0, "missing": 0, "ok": true}));
    for p in A {
        assert!(!tile_file(&t.0, "b1", p).exists(), "{p} evicted");
    }
    assert_eq!(call(&e, "status", json!({}))["stream"], json!({"tiles": 3, "bytes": 3000, "cap": 3000}));
    assert_eq!(srv.hits_of("b1", FAR[0]), 1, "a tile here is not fetched again");
}

#[test]
fn an_update_downloads_the_new_build_and_switches_only_when_complete() {
    let srv = Server::start();
    srv.publish("b1");
    let t = Tmp::new("update");
    let e = engine(&t.0, &srv, json!({}));
    call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    wait_state(&e, "a", "ready");
    assert_eq!(call(&e, "check_update", json!({})), json!({"build": "b1", "update": null}));

    // b2 is published; one of its tiles comes damaged for now.
    srv.publish("b2");
    srv.damage("b2", "2/000/763/464", 100);
    let a_gz: u64 = A.iter().map(|p| gz_len("b2", p)).sum();
    assert_eq!(call(&e, "check_update", json!({})), json!({"build": "b2", "update": {"build": "b2", "download_bytes": a_gz}}));
    assert_eq!(call(&e, "status", json!({}))["update"], json!({"build": "b2", "download_bytes": a_gz, "downloading": false}));
    assert_eq!(call(&e, "update", json!({})), json!({"ok": true, "build": "b2", "download_bytes": a_gz}));
    wait_state(&e, "a", "failed");
    // Not all of b2 is here: the device stays on b1, whole.
    let st = call(&e, "status", json!({}));
    assert_eq!(st["build"], "b1");
    assert_eq!(st["update"], json!({"build": "b2", "download_bytes": gz_len("b2", "2/000/763/464"), "downloading": true}));
    for p in A {
        assert_eq!(std::fs::read(tile_file(&t.0, "b1", p)).unwrap(), tile("b1", p));
    }

    // Right again: adding the region again tries again, the last tile comes, and the device moves to b2.
    srv.damage("b2", "2/000/763/464", 0);
    call(&e, "add", json!({"id": "a", "geometry": region_a()}));
    wait("the switch to b2", 20, || call(&e, "status", json!({}))["build"] == "b2");
    wait_state(&e, "a", "ready");
    let st = call(&e, "status", json!({}));
    assert_eq!(st["update"], Value::Null);
    assert_eq!(st["tile_dir"], &*t.0.join("tiles").join("b2").to_string_lossy());
    for p in A {
        assert_eq!(std::fs::read(tile_file(&t.0, "b2", p)).unwrap(), tile("b2", p));
    }
    assert!(!t.0.join("tiles").join("b1").exists(), "the old build is deleted");
    assert!(!t.0.join("index").join("b1.tsv").exists());
    assert!(hidden_files(&t.0.join("tiles")).is_empty());
    assert_eq!(call(&e, "check_update", json!({})), json!({"build": "b2", "update": null}));
}

#[test]
fn too_little_free_space_pauses_a_region_with_the_reason() {
    let srv = Server::start();
    srv.publish("b1");
    let t = Tmp::new("space");
    let e = engine(&t.0, &srv, json!({"reserve_bytes": u64::MAX / 4}));
    call(&e, "add", json!({"id": "a", "name": "Burley", "geometry": region_a()}));
    wait_state(&e, "a", "paused");
    let p = call(&e, "status", json!({}))["paused"].as_str().unwrap().to_string();
    assert!(p.starts_with("Paused: Burley needs 2.9 KB") && p.ends_with("is kept free"), "{p}");
    assert_eq!(srv.tile_hits(), 0);
    call(&e, "set_policy", json!({"reserve_bytes": 0}));
    wait_state(&e, "a", "ready");
}
