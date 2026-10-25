//! The navigate tool through the three front doors: the `cs` CLI, `cs serve` (HTTP) and the C ABI (the `Core` wrapper).
//! The same calls run against three separate states and every result must be byte-identical.
//!
//! Needs the Idaho data, so it skips (and says so) unless these are set:
//!   OFFROAD_VALHALLA_TILES  .../idaho/valhalla/tiles.tar        OFFROAD_VALHALLA_LIB  the shim library (valhalla_shim.dll)
//!   OFFROAD_IDAHO_PACK      .../idaho/offroad.sqlite             OFFROAD_IDAHO_ELEVATION  .../idaho/elevation.pmtiles
//! NAVIGATE_OUT_DIR, when set, receives each result as pretty JSON (nav-<step>.json).

use cache_search_cli::engine::{Conv, Core};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cs-nav-{}-{}", std::process::id(), name));
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

fn data() -> Option<(String, String, String, String)> {
    let g = |k: &str| std::env::var(k).ok().filter(|v| !v.is_empty() && std::path::Path::new(v).exists());
    Some((g("OFFROAD_VALHALLA_TILES")?, g("OFFROAD_VALHALLA_LIB")?, g("OFFROAD_IDAHO_PACK")?, g("OFFROAD_IDAHO_ELEVATION")?))
}

const NOW: &str = "2026-10-25T14:00:00-06:00";

fn routing(with_offroad: bool) -> Value {
    let (tiles, shim, pack, elev) = data().unwrap();
    let mut r = json!({"valhalla": {"tiles": tiles, "shim": shim}});
    if with_offroad {
        r["offroad"] = json!({"pack": pack, "elevation": elev});
    }
    r
}

fn config_file(t: &Tmp, name: &str, routing: Option<Value>) -> (String, String) {
    let mut cfg = json!({"sources": []});
    if let Some(r) = routing {
        cfg["routing"] = r;
    }
    let path = t.0.join(name).to_string_lossy().into_owned();
    std::fs::write(&path, cfg.to_string()).unwrap();
    (path, cfg.to_string())
}

fn cli(args: &[&str]) -> String {
    let o = Command::new(env!("CARGO_BIN_EXE_cs")).args(args).output().expect("run cs");
    // nothing may reach stdout besides the result line: Valhalla's own log is silenced
    let out = String::from_utf8(o.stdout).unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    out.strip_suffix('\n').expect("newline-terminated").to_string()
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
    fn new(t: &Tmp, with_offroad: bool) -> Doors {
        Doors::with_routing(t, Some(routing(with_offroad)))
    }

    fn with_routing(t: &Tmp, routing: Option<Value>) -> Doors {
        let (cfg_path, cfg_json) = config_file(t, "config.json", routing);
        Doors { http: Http::start(&cfg_path), core: Core::open(&cfg_json).unwrap(), cfg_path }
    }

    /// One tool call through all three; asserts they agree and returns the `cs_tool` reply `{"content","ids"}` as the CLI printed it.
    fn tool(&mut self, args: &Value, loc: Option<(f64, f64)>) -> String {
        let a = args.to_string();
        let c = self.cfg_path.clone();
        let mut argv = vec!["tool".to_string(), "navigate".into(), "--config".into(), c, "--args".into(), a.clone(), "--now".into(), NOW.into(), "--json".into()];
        if let Some((lat, lon)) = loc {
            argv.extend(["--lat".into(), lat.to_string(), "--lon".into(), lon.to_string()]);
        }
        let argv: Vec<&str> = argv.iter().map(String::as_str).collect();
        let from_cli = cli(&argv);

        if let Some((lat, lon)) = loc {
            self.http.req("POST", "/location", &json!({"lat": lat, "lon": lon, "fixed_at": NOW}).to_string());
            self.core.set_location(lat, lon, -1.0, NOW).unwrap();
        }
        let id = serde_json::from_str::<Value>(&self.http.req("POST", "/conversations", "")).unwrap()["id"].as_str().unwrap().to_string();
        let from_http = self.http.req("POST", &format!("/conversations/{id}/tool"), &json!({"name": "navigate", "args": args, "now": NOW}).to_string());
        let from_abi = self.core.tool(&mut Conv::new().unwrap(), "navigate", &a, NOW).unwrap();
        if loc.is_some() {
            self.http.req("DELETE", "/location", "");
            self.core.clear_location().unwrap();
        }
        assert_eq!(from_http, from_cli, "serve differs from the CLI for {args}");
        assert_eq!(from_abi, from_cli, "the C ABI differs from the CLI for {args}");
        from_cli
    }

    /// The tool's result as the model sees it.
    fn content(&mut self, name: &str, args: Value, loc: Option<(f64, f64)>) -> Value {
        let reply: Value = serde_json::from_str(&self.tool(&args, loc)).unwrap();
        let v: Value = serde_json::from_str(reply["content"].as_str().unwrap()).unwrap();
        if let Ok(dir) = std::env::var("NAVIGATE_OUT_DIR") {
            std::fs::write(PathBuf::from(dir).join(format!("nav-{name}.json")), serde_json::to_string_pretty(&v).unwrap()).unwrap();
        }
        v
    }
}

fn err_type(v: &Value) -> &str {
    assert_eq!(v["ok"], false, "{v}");
    v["error"]["type"].as_str().unwrap()
}

#[test]
fn navigate_is_identical_through_cli_serve_and_the_c_abi() {
    if data().is_none() {
        eprintln!("skipped: set OFFROAD_VALHALLA_TILES, OFFROAD_VALHALLA_LIB, OFFROAD_IDAHO_PACK and OFFROAD_IDAHO_ELEVATION");
        return;
    }
    let t = Tmp::new("full");
    let mut d = Doors::new(&t, true);

    // the schema: the same bytes from the three doors, navigate listed after search and read
    let schemas = cli(&["tool-schemas", "--config", &d.cfg_path]);
    assert_eq!(d.http.req("GET", "/tools", ""), schemas);
    assert_eq!(d.core.tool_schemas().unwrap(), schemas);
    let names: Vec<String> = serde_json::from_str::<Value>(&schemas).unwrap().as_array().unwrap().iter().map(|s| s["function"]["name"].as_str().unwrap().to_string()).collect();
    assert_eq!(names, ["search", "read", "navigate"]);

    // 1. drive, Burley to Boise, from the phone's position
    let burley = (42.536, -113.792);
    let drive = d.content("drive-burley-boise", json!({"to": "43.615,-116.202", "mode": "drive"}), Some(burley));
    assert_eq!(drive["ok"], true);
    assert_eq!(drive["n"], 1);
    assert_eq!(drive["mode"], "drive");
    assert_eq!(drive["location_bias"], "phone_location");
    assert_eq!(drive["from_matched"]["place_name"], "current location");
    assert_eq!(drive["map_region"], "Idaho");
    assert!(drive["map_region_age"].as_str().unwrap().ends_with("old"), "{}", drive["map_region_age"]);
    let km = drive["distance_km"].as_f64().unwrap();
    assert!((200.0..300.0).contains(&km), "{km}");
    assert!(drive.get("offroad_mi").is_none());
    assert_eq!(drive["steps"].as_array().unwrap().len(), 15.min(drive["step_count"].as_u64().unwrap() as usize));

    // 2. walk from a point in the Sawtooths out to the nearest road and on to Stanley (off-road at the start)
    let walk = d.content("walk-sawtooths-stanley", json!({"from": "44.0543,-115.4237", "to": "44.2210,-114.9318", "mode": "walk"}), None);
    assert_eq!(walk["ok"], true, "{walk}");
    assert_eq!(walk["location_bias"], "none");
    assert!(walk["offroad_mi"].as_f64().unwrap() > 0.0);
    assert!(walk["offroad_note"].as_str().is_some());
    assert_eq!(walk["steps"][0]["kind"], "offroad");
    for k in ["travel", "grade_class", "elev_gain_m", "elev_loss_m", "terrain"] {
        assert!(walk["steps"][0].get(k).is_some(), "{k}");
    }

    // 3. a strict land-access foot route from the off-road parity set (R08)
    let strict = d.content("strict-foot-r08", json!({"from": "44.18,-114.95", "to": "44.23,-114.9", "mode": "offroad_foot", "land_access": "strict"}), None);
    assert_eq!(strict["ok"], true, "{strict}");
    assert_eq!(strict["mode"], "offroad_foot");
    assert!(strict["steps"].as_array().unwrap().iter().all(|s| s["kind"] != "road"));
    // the same trip with the other land-access modes is a different request (the route may differ)
    let _ = d.content("pragmatic-foot-r08", json!({"from": "44.18,-114.95", "to": "44.23,-114.9", "mode": "offroad_foot", "land_access": "pragmatic"}), None);

    // 4. errors, in every door
    let e = d.content("err-no-location", json!({"to": "43.615,-116.202", "mode": "drive"}), None);
    assert_eq!(err_type(&e), "no_location");
    let e = d.content("err-geocode", json!({"to": "Cassia Regional Hospital", "mode": "drive"}), Some(burley));
    assert_eq!(err_type(&e), "geocode_empty");
    assert_eq!(e["error"]["which"], "to");
    let e = d.content("err-to-type", json!({"to_type": "hospital", "mode": "drive"}), Some(burley));
    assert_eq!(err_type(&e), "not_set_up");
    let e = d.content("err-same-place", json!({"to": "42.536,-113.792", "mode": "drive"}), Some(burley));
    assert_eq!(err_type(&e), "same_place");
    let e = d.content("err-bad-mode", json!({"to": "43.615,-116.202", "mode": "fly"}), Some(burley));
    assert_eq!(err_type(&e), "bad_arguments");
    // a trip outside the installed region
    let e = d.content("err-outside", json!({"from": "47.6062,-122.3321", "to": "47.25,-122.44", "mode": "drive"}), None);
    assert_eq!(err_type(&e), "not_set_up", "{e}");

    // numbering: a second route in the same conversation continues from [2]
    let id = serde_json::from_str::<Value>(&d.http.req("POST", "/conversations", "")).unwrap()["id"].as_str().unwrap().to_string();
    let call = |d: &Doors, to: &str| -> Value {
        let r: Value = serde_json::from_str(&d.http.req("POST", &format!("/conversations/{id}/tool"), &json!({"name": "navigate", "args": {"from": "42.536,-113.792", "to": to, "mode": "drive"}, "now": NOW}).to_string())).unwrap();
        serde_json::from_str(r["content"].as_str().unwrap()).unwrap()
    };
    assert_eq!(call(&d, "42.617,-113.675")["n"], 1);
    assert_eq!(call(&d, "42.93,-114.40")["n"], 2);
    assert_eq!(call(&d, "42.617,-113.675")["n"], 1);
}

#[test]
fn without_the_off_road_data_roads_still_route_and_off_road_is_a_clear_error() {
    if data().is_none() {
        eprintln!("skipped: the Idaho data is not set");
        return;
    }
    let t = Tmp::new("roadonly");
    let mut d = Doors::new(&t, false);
    let drive = d.content("roadonly-drive", json!({"from": "42.536,-113.792", "to": "42.617,-113.675", "mode": "drive"}), None);
    assert_eq!(drive["ok"], true);
    let e = d.content("roadonly-offroad", json!({"from": "44.18,-114.95", "to": "44.23,-114.9", "mode": "offroad_foot"}), None);
    assert_eq!(err_type(&e), "not_set_up");
    assert!(e["error"]["detail"].as_str().unwrap().contains("off-road"));
    // a destination far from any road still gets the road route, with a warning
    let w = d.content("roadonly-gap", json!({"from": "44.0543,-115.4237", "to": "44.2210,-114.9318", "mode": "walk"}), None);
    assert_eq!(w["ok"], true, "{w}");
    assert_eq!(w["warnings"][0]["code"], "offroad_unavailable");
}

#[test]
fn navigate_is_not_offered_without_the_routing_data() {
    let t = Tmp::new("none");
    let mut d = Doors::with_routing(&t, None);
    let schemas = cli(&["tool-schemas", "--config", &d.cfg_path]);
    assert_eq!(d.core.tool_schemas().unwrap(), schemas);
    assert!(!schemas.contains("navigate"));
    // tiles that are not there: configured but not installed, so it is left out too
    let t2 = Tmp::new("missing");
    let missing = json!({"valhalla": {"tiles": t2.0.join("tiles.tar"), "shim": t2.0.join("valhalla_shim.dll")}});
    let mut d2 = Doors::with_routing(&t2, Some(missing));
    let s2 = d2.core.tool_schemas().unwrap();
    assert!(!s2.contains("navigate"));
    let r = d2.core.tool(&mut Conv::new().unwrap(), "navigate", r#"{"to":"1,2","mode":"drive"}"#, NOW).unwrap();
    assert!(r.contains("not_set_up"), "{r}");
}
