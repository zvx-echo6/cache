//! The map's calls (search, route, progress) through the three front doors: the `cs` CLI, `cs serve` (HTTP) and the C ABI
//! (the `Core` wrapper). The same requests run against separate states and every answer must be byte-identical.
//!
//! Search needs only the small fixture pack. Route and progress need the Idaho data, so they skip (and say so) unless
//! OFFROAD_VALHALLA_TILES, OFFROAD_VALHALLA_LIB, OFFROAD_IDAHO_PACK and OFFROAD_IDAHO_ELEVATION are set; MAP_OUT_DIR, when
//! set, receives each answer as pretty JSON (map-<step>.json).

use cache_places::fixture::{fake_embed, write_fixture_pack_with_vectors, FAKE_MODEL, FIXTURE_NOW};
use cache_search_cli::engine::{Conv, Core};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cs-map-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Tmp(p)
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn cli(args: &[&str]) -> String {
    let o = Command::new(env!("CARGO_BIN_EXE_cs")).args(args).output().expect("run cs");
    if o.status.success() {
        String::from_utf8(o.stdout).unwrap().strip_suffix('\n').expect("newline-terminated").to_string()
    } else {
        String::from_utf8(o.stderr).unwrap().trim_end().to_string()
    }
}

struct Http {
    child: Child,
    addr: String,
}
impl Http {
    fn start(config: &str) -> Http {
        let mut child = Command::new(env!("CARGO_BIN_EXE_cs"))
            .args(["serve", "--listen", "127.0.0.1:0", "--config", config])
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
        let addr = line.trim().strip_prefix("listening ").unwrap().to_string();
        Http { child, addr }
    }
    fn req(&self, method: &str, path: &str, body: &str) -> String {
        let mut s = TcpStream::connect(&self.addr).unwrap();
        write!(s, "{method} {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()).unwrap();
        let mut raw = Vec::new();
        s.read_to_end(&mut raw).unwrap();
        String::from_utf8(raw).unwrap().split_once("\r\n\r\n").unwrap().1.to_string()
    }
}
impl Drop for Http {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

/// The three doors over one config.
struct Doors {
    cfg_path: String,
    http: Http,
    core: Core,
}

impl Doors {
    fn new(t: &Tmp, cfg: &Value) -> Doors {
        let path = t.0.join("config.json").to_string_lossy().into_owned();
        std::fs::write(&path, cfg.to_string()).unwrap();
        Doors { http: Http::start(&path), core: Core::open(&cfg.to_string()).unwrap(), cfg_path: path }
    }

    fn fix(&mut self, fix: Option<(f64, f64)>) {
        match fix {
            Some((lat, lon)) => {
                self.http.req("POST", "/location", &json!({"lat": lat, "lon": lon, "fixed_at": FIXTURE_NOW}).to_string());
                self.core.set_location(lat, lon, -1.0, FIXTURE_NOW).unwrap();
            }
            None => {
                self.http.req("DELETE", "/location", "");
                self.core.clear_location().unwrap();
            }
        }
    }

    /// One call through the CLI, `cs serve` and the C ABI; asserts they agree and returns the answer text.
    fn call(&mut self, op: &str, request: &Value, fix: Option<(f64, f64)>) -> String {
        let body = request.to_string();
        let (lat, lon);
        let mut argv = vec![format!("map-{op}"), "--config".into(), self.cfg_path.clone(), "--request".into(), body.clone()];
        if let Some((la, lo)) = fix {
            (lat, lon) = (la.to_string(), lo.to_string());
            argv.extend(["--lat".into(), lat, "--lon".into(), lon]);
        }
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        let from_cli = cli(&argv);
        self.fix(fix);
        let from_http = self.http.req("POST", &format!("/map/{op}"), &body);
        let from_abi = match op {
            "search" => self.core.map_search(&body),
            "route" => self.core.map_route(&body),
            _ => self.core.map_progress(&body),
        }
        .unwrap_or_else(|e| e.to_json());
        self.fix(None);
        assert_eq!(from_http, from_cli, "serve differs from the CLI for map-{op} {body}");
        assert_eq!(from_abi, from_cli, "the C ABI differs from the CLI for map-{op} {body}");
        from_cli
    }

    fn json(&mut self, op: &str, request: &Value, fix: Option<(f64, f64)>) -> Value {
        let out = self.call(op, request, fix);
        serde_json::from_str(&out).unwrap_or_else(|e| panic!("not JSON ({e}): {out}"))
    }
}

fn save(name: &str, v: &Value) {
    if let Ok(dir) = std::env::var("MAP_OUT_DIR") {
        std::fs::write(PathBuf::from(dir).join(format!("map-{name}.json")), serde_json::to_string_pretty(v).unwrap()).unwrap();
    }
}

const BURLEY: (f64, f64) = (42.536, -113.792);
const STANLEY: (f64, f64) = (44.221, -114.936);

#[test]
fn map_search_is_identical_through_cli_serve_and_the_c_abi() {
    let t = Tmp::new("search");
    let pack = t.0.join("places.sqlite");
    write_fixture_pack_with_vectors(&pack);
    let cfg = json!({"sources": [], "places": {"packs": [pack.to_string_lossy()]}});
    let mut d = Doors::new(&t, &cfg);

    // coordinates, any format
    let v = d.json("search", &json!({"query": "43.6,-116.2", "near": {"lat": BURLEY.0, "lon": BURLEY.1}}), None);
    assert_eq!(v["interpreted"]["kind"], "coordinates");
    assert_eq!(v["results"][0]["type"], "coordinates");
    assert_eq!(v["results"][0]["address"].as_str().unwrap().contains("Boise"), true, "{v}");
    save("search-coordinates", &v);
    let formats = v["results"][0]["formats"].clone();
    for k in ["dms", "usng", "plus_code"] {
        let q = formats[k].as_str().unwrap();
        let back = d.json("search", &json!({"query": q}), None);
        assert_eq!(back["interpreted"]["kind"], "coordinates", "{q}: {back}");
        assert!((back["results"][0]["lat"].as_f64().unwrap() - 43.6).abs() < 0.001, "{k}: {back}");
    }

    // a name, a category with a town, a category alone, a meaning with a given vector
    let v = d.json("search", &json!({"query": "Stanley", "near": {"lat": BURLEY.0, "lon": BURLEY.1}}), None);
    assert_eq!(v["results"][0]["name"], "Stanley");
    assert_eq!(v["results"][0]["type"], "town");
    let v = d.json("search", &json!({"query": "pharmacy near Burley", "limit": 4}), Some(STANLEY));
    assert_eq!(v["results"][0]["id"], "category:pharmacy");
    assert_eq!(v["results"][1]["name"], "Walgreens");
    // distances are from the GPS fix when the request has no "near"
    assert!(v["results"][1]["distance_m"].as_i64().unwrap() > 190_000, "{v}");
    save("search-pharmacy-near-burley", &v);
    let v = d.json("search", &json!({"query": "gas station"}), Some(BURLEY));
    assert_eq!(v["results"][0]["id"], "category:fuel");
    let v = d.json("search", &json!({"query": "agua", "near": {"lat": STANLEY.0, "lon": STANLEY.1}, "query_vector": {"model": FAKE_MODEL, "vector": fake_embed("drinking water springs")}}), None);
    assert_eq!(v["meaning"], "used");
    assert_eq!(v["results"][0]["id"], "category:water");
    save("search-meaning", &v);
    // no embedder, so the meaning step says so and keywords still answer
    let v = d.json("search", &json!({"query": "somewhere to get water", "near": {"lat": STANLEY.0, "lon": STANLEY.1}}), None);
    assert_eq!(v["meaning"], "no_embedder");
    assert_eq!(v["results"][0]["id"], "category:water");

    // errors read the same in every door
    for bad in [json!({}), json!({"query": "x", "limit": 0}), json!({"query": "x", "frobnicate": 1}), json!({"query": 4})] {
        let e: Value = serde_json::from_str(&d.call("search", &bad, None)).unwrap();
        assert_eq!(e["code"], "bad_json", "{bad}: {e}");
    }
    // routing is not configured here
    let e: Value = serde_json::from_str(&d.call("route", &json!({"to": "Stanley"}), None)).unwrap();
    assert_eq!(e["code"], "not_configured");
    let e: Value = serde_json::from_str(&d.call("progress", &json!({"route_id": "x", "lat": 1.0, "lon": 2.0}), None)).unwrap();
    assert_eq!(e["code"], "not_found");

    // without a places section map search is not configured
    let t2 = Tmp::new("noplaces");
    let mut d2 = Doors::new(&t2, &json!({"sources": []}));
    let e: Value = serde_json::from_str(&d2.call("search", &json!({"query": "x"}), None)).unwrap();
    assert_eq!(e["code"], "not_configured");
}

fn data() -> Option<(String, String, String, String)> {
    let g = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty() && std::path::Path::new(v).exists());
    Some((g("OFFROAD_VALHALLA_TILES")?, g("OFFROAD_VALHALLA_LIB")?, g("OFFROAD_IDAHO_PACK")?, g("OFFROAD_IDAHO_ELEVATION")?))
}

#[test]
fn map_route_and_progress_are_identical_through_the_three_doors() {
    let Some((tiles, shim, pack, elev)) = data() else {
        eprintln!("skipped: set OFFROAD_VALHALLA_TILES, OFFROAD_VALHALLA_LIB, OFFROAD_IDAHO_PACK and OFFROAD_IDAHO_ELEVATION");
        return;
    };
    let t = Tmp::new("route");
    let places = t.0.join("places.sqlite");
    write_fixture_pack_with_vectors(&places);
    let cfg = json!({"sources": [], "places": {"packs": [places.to_string_lossy()]},
                     "routing": {"valhalla": {"tiles": tiles, "shim": shim}, "offroad": {"pack": pack, "elevation": elev}}});
    let mut d = Doors::new(&t, &cfg);

    // 1. drive, Burley to Boise, from the GPS fix, to a place found by search
    let found = d.json("search", &json!({"query": "St. Luke's Boise Medical Center"}), Some(BURLEY));
    let to = found["results"][0].clone();
    assert_eq!(to["type"], "place");
    let drive = d.json("route", &json!({"to": {"id": to["id"], "lat": to["lat"], "lon": to["lon"]}, "mode": "drive"}), Some(BURLEY));
    save("route-drive-burley-boise", &drive);
    assert_eq!(drive["ok"], true, "{drive}");
    assert_eq!(drive["from"]["name"], "Current location");
    assert_eq!(drive["to"]["name"], "St. Luke's Boise Medical Center");
    let steps = drive["maneuvers"].as_array().unwrap();
    assert!(steps.len() >= 8, "{}", steps.len());
    let km = drive["distance_m"].as_f64().unwrap() / 1000.0;
    assert!((200.0..300.0).contains(&km), "{km}");
    assert_eq!(drive["segments"].as_array().unwrap().iter().filter(|s| s["kind"] == "road").count() >= 1, true);
    assert!(drive["geometry"].as_str().unwrap().len() > 1000);
    assert!(drive["point_count"].as_u64().unwrap() > 500);
    for (i, m) in steps.iter().enumerate() {
        assert_eq!(m["index"], i);
        assert!(m["begin_index"].as_u64().unwrap() <= m["end_index"].as_u64().unwrap());
    }
    // the same engine as the tool: same route id and the same time
    let nav = {
        let mut conv = Conv::new().unwrap();
        d.core.set_location(BURLEY.0, BURLEY.1, -1.0, FIXTURE_NOW).unwrap();
        let out = d.core.tool(&mut conv, "navigate", &json!({"to": format!("{},{}", to["lat"], to["lon"]), "mode": "drive"}).to_string(), FIXTURE_NOW).unwrap();
        d.core.clear_location().unwrap();
        let v: Value = serde_json::from_str(&out).unwrap();
        serde_json::from_str::<Value>(v["content"].as_str().unwrap()).unwrap()
    };
    assert_eq!(nav["route_id"], drive["route_id"], "the map and the tool route with the same code");
    assert_eq!(nav["step_count"].as_u64().unwrap() as usize, steps.len(), "every step the tool counted, none dropped");
    assert!((nav["duration_minutes"].as_f64().unwrap() * 60.0 - drive["duration_s"].as_f64().unwrap()).abs() < 4.0, "the tool rounds to 0.1 min");

    // 2. walking from a point in the Sawtooths to Stanley: off-road legs, with their own kind in the geometry
    let walk = d.json("route", &json!({"from": {"lat": 44.0543, "lon": -115.4237, "name": "Sawtooth trailhead"}, "to": {"lat": 44.2210, "lon": -114.9318, "name": "Stanley"}, "mode": "walk"}), None);
    save("route-walk-sawtooths-stanley", &walk);
    assert_eq!(walk["ok"], true, "{walk}");
    assert_eq!(walk["routing"], "offroad");
    assert!(walk["totals"]["offroad_m"].as_f64().unwrap() > 500.0);
    assert!(walk["segments"].as_array().unwrap().iter().any(|s| s["kind"] != "road"));
    assert!(walk["maneuvers"].as_array().unwrap().len() > 12, "all the off-road steps too");
    let off = walk["maneuvers"].as_array().unwrap().iter().find(|m| m["kind"] == "offroad").expect("an off-road maneuver");
    for k in ["grade_class", "elev_gain_m", "elev_loss_m", "bearing_deg", "cardinal", "travel"] {
        assert!(off.get(k).is_some(), "{k}");
    }
    assert_eq!(walk["alternatives"], json!([]));

    // 3. a stop on the way, and a bike
    let via = d.json("route", &json!({"from": "42.536,-113.792", "via": [{"lat": 42.617, "lon": -113.675, "name": "Rupert"}], "to": "42.93,-114.40", "mode": "drive", "alternatives": 0}), None);
    assert_eq!(via["ok"], true, "{via}");
    assert!(via["maneuvers"].as_array().unwrap().iter().any(|m| m["type"] == "via"));
    assert_eq!(via["via"][0]["name"], "Rupert");
    save("route-via", &via);
    let bike = d.json("route", &json!({"from": "42.536,-113.792", "to": "42.617,-113.675", "mode": "bike"}), None);
    assert_eq!(bike["ok"], true, "{bike}");
    assert_eq!(bike["mode"], "bike");

    // 4. a trip Valhalla gives alternatives for
    let alt = d.json("route", &json!({"from": "42.536,-113.792", "to": "43.615,-116.202", "mode": "drive", "alternatives": 2}), None);
    save("route-alternatives", &alt);
    eprintln!("alternatives: {}", alt["alternatives"].as_array().unwrap().len());

    // 5. errors
    let e: Value = serde_json::from_str(&d.call("route", &json!({"to": "43.615,-116.202"}), None)).unwrap();
    assert_eq!(e["code"], "bad_json");
    let e: Value = serde_json::from_str(&d.call("route", &json!({"from": "1,1", "to": "nowhere-at-all"}), None)).unwrap();
    assert_eq!(e["code"], "bad_json");
    let out = d.json("route", &json!({"from": "47.6062,-122.3321", "to": "47.25,-122.44"}), None);
    assert_eq!(out["ok"], false, "{out}");
    assert!(["no_route", "too_far", "out_of_coverage"].contains(&out["errors"][0]["code"].as_str().unwrap()), "{out}");

    // 6. progress along the drive: the same fixes in serve and the C ABI (state follows the route id); the CLI, a fresh
    //    process each time, is given the route itself and agrees on the first fix
    let id = drive["route_id"].as_str().unwrap();
    let pts = cache_offroad_decode(drive["geometry"].as_str().unwrap());
    let n = pts.len();
    let fix_at = |f: f64| pts[((n - 1) as f64 * f) as usize];
    let first = fix_at(0.2);
    let req = json!({"route": drive, "lat": first.0 + 0.0001, "lon": first.1, "now": "2026-10-26T12:00:00-06:00"});
    let first_out = d.call("progress", &req, None);
    let p: Value = serde_json::from_str(&first_out).unwrap();
    assert_eq!(p["on_route"], true, "{p}");
    assert!((p["progress"].as_f64().unwrap() - 0.2).abs() < 0.05, "{p}");
    assert!(p["next"]["instruction"].as_str().unwrap().len() > 3);
    assert!(p["remaining"]["eta"].as_str().unwrap().starts_with("2026-10-26T"));
    save("progress-on-route", &p);
    // the rest of the track on the two live handles
    for (i, f) in [0.25, 0.3, 0.5, 0.9, 1.0].into_iter().enumerate() {
        let c = fix_at(f);
        let r = json!({"route_id": id, "lat": c.0, "lon": c.1});
        let a = d.http.req("POST", "/map/progress", &r.to_string());
        let b = d.core.map_progress(&r.to_string()).unwrap();
        assert_eq!(a, b, "fix {i}");
        let v: Value = serde_json::from_str(&a).unwrap();
        assert_eq!(v["off_route"], false);
        if f >= 1.0 {
            assert_eq!(v["arrived"], true, "{v}");
            save("progress-arrived", &v);
        }
    }
    // off the road for three fixes: the route is to be recalculated
    let c = fix_at(0.4);
    for n in 1..=3 {
        let r = json!({"route_id": id, "lat": c.0 + 0.01, "lon": c.1 + 0.01});
        let a = d.http.req("POST", "/map/progress", &r.to_string());
        assert_eq!(a, d.core.map_progress(&r.to_string()).unwrap());
        let v: Value = serde_json::from_str(&a).unwrap();
        assert_eq!(v["off_route"], n == 3, "fix {n}: {v}");
        if n == 3 {
            save("progress-off-route", &v);
        }
    }
    // an off-road leg reports where to head
    let wid = walk["route_id"].as_str().unwrap();
    let wpts = cache_offroad_decode(walk["geometry"].as_str().unwrap());
    let w0 = wpts[wpts.len() / 20];
    let r = json!({"route_id": wid, "lat": w0.0, "lon": w0.1});
    let a = d.http.req("POST", "/map/progress", &r.to_string());
    assert_eq!(a, d.core.map_progress(&r.to_string()).unwrap());
    let v: Value = serde_json::from_str(&a).unwrap();
    if v["current"]["kind"] != "road" {
        for k in ["bearing_deg", "distance_m", "climb_m", "cardinal"] {
            assert!(v["leg"].get(k).is_some(), "{k}: {v}");
        }
    }
    save("progress-offroad", &v);
}

/// polyline6 -> points, with the same decoder the core uses.
fn cache_offroad_decode(enc: &str) -> Vec<(f64, f64)> {
    let b = enc.as_bytes();
    let (mut idx, mut lat, mut lon) = (0usize, 0i64, 0i64);
    let mut out = Vec::new();
    while idx < b.len() {
        for axis in 0..2 {
            let (mut shift, mut result) = (0u32, 0i64);
            loop {
                let c = b[idx] as i64 - 63;
                idx += 1;
                result |= (c & 0x1f) << shift;
                shift += 5;
                if c < 0x20 {
                    break;
                }
            }
            let delta = if result & 1 != 0 { !(result >> 1) } else { result >> 1 };
            if axis == 0 {
                lat += delta;
            } else {
                lon += delta;
            }
        }
        out.push((lat as f64 / 1e6, lon as f64 / 1e6));
    }
    out
}
