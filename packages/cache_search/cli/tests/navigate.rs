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
    assert_eq!(drive["location_bias"], "sender_node_position");
    assert_eq!(drive["from_matched"]["place_name"], "current location");
    assert_eq!(drive["map_region"], "Idaho");
    assert!(drive["map_region_age"].as_str().unwrap().ends_with("old"), "{}", drive["map_region_age"]);
    let km = drive["distance_km"].as_f64().unwrap();
    assert!((200.0..300.0).contains(&km), "{km}");
    assert!(drive.get("offroad_mi").is_none());
    assert!(drive.get("steps").is_none());
    assert_eq!(drive["route_id"].as_str().unwrap().len(), 16);
    // no traffic source yet: always present, null
    assert!(drive.get("traffic").is_some_and(Value::is_null), "{drive}");

    // 2. walk from a point in the Sawtooths out to the nearest road and on to Stanley (off-road legs come back inside the route)
    let walk = d.content("walk-sawtooths-stanley", json!({"from": "44.0543,-115.4237", "to": "44.2210,-114.9318", "mode": "walk"}), None);
    assert_eq!(walk["ok"], true, "{walk}");
    assert_eq!(walk["location_bias"], "from_place");
    assert!(walk["offroad_mi"].as_f64().unwrap() > 0.0);
    assert!(walk["offroad_note"].as_str().is_some());
    assert!(walk.get("steps").is_none());

    // 3. a strict land-access foot route from the off-road parity set (R08)
    let strict = d.content("strict-foot-r08", json!({"from": "44.18,-114.95", "to": "44.23,-114.9", "mode": "walk", "land_access": "strict"}), None);
    assert_eq!(strict["ok"], true, "{strict}");
    assert_eq!(strict["mode"], "walk");
    assert!(strict["offroad_mi"].as_f64().unwrap() > 0.0);
    let _ = d.content("pragmatic-foot-r08", json!({"from": "44.18,-114.95", "to": "44.23,-114.9", "mode": "walk", "land_access": "pragmatic"}), None);

    // 4. errors, in every door
    let e = d.content("err-no-location", json!({"to": "43.615,-116.202", "mode": "drive"}), None);
    assert_eq!(err_type(&e), "origin_unknown");
    let e = d.content("err-geocode", json!({"to": "Cassia Regional Hospital", "mode": "drive"}), Some(burley));
    assert_eq!(err_type(&e), "geocode_empty");
    assert_eq!(e["error"]["which"], "to");
    assert!(e["error"].get("detail").is_none());
    let e = d.content("err-to-type", json!({"to_type": "hospital", "mode": "drive"}), Some(burley));
    assert_eq!(err_type(&e), "not_set_up");
    let e = d.content("err-same-place", json!({"to": "42.536,-113.792", "mode": "drive"}), Some(burley));
    assert_eq!(err_type(&e), "same_place");
    assert!(e["from_matched"].is_object() && e["to_matched"].is_object());
    let e = d.content("err-bad-mode", json!({"to": "43.615,-116.202", "mode": "fly"}), Some(burley));
    assert_eq!(err_type(&e), "bad_arguments");
    // a trip outside the installed region: the router's own code, with both places beside it
    let e = d.content("err-outside", json!({"from": "47.6062,-122.3321", "to": "47.25,-122.44", "mode": "drive"}), None);
    assert!(["no_route", "too_far", "out_of_coverage"].contains(&err_type(&e)), "{e}");
    assert!(e["from_matched"].is_object() && e["to_matched"].is_object(), "{e}");

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
fn without_the_off_road_data_roads_still_route_and_the_gap_is_a_warning() {
    if data().is_none() {
        eprintln!("skipped: the Idaho data is not set");
        return;
    }
    let t = Tmp::new("roadonly");
    let mut d = Doors::new(&t, false);
    let drive = d.content("roadonly-drive", json!({"from": "42.536,-113.792", "to": "42.617,-113.675", "mode": "drive"}), None);
    assert_eq!(drive["ok"], true);
    // a destination far from any road still gets the road route, with a warning
    let w = d.content("roadonly-gap", json!({"from": "44.0543,-115.4237", "to": "44.2210,-114.9318", "mode": "walk"}), None);
    assert_eq!(w["ok"], true, "{w}");
    assert_eq!(w["warnings"][0]["code"], "offroad_unavailable");
    assert!(w["warnings"][0]["road_point"]["lat"].is_number());
}

#[test]
fn offroad_modes_route_the_whole_trip_off_road_under_each_land_access() {
    if data().is_none() {
        eprintln!("skipped: the Idaho data is not set");
        return;
    }
    let t = Tmp::new("offroad-modes");
    let mut d = Doors::new(&t, true);
    let schemas: Value = serde_json::from_str(&cli(&["tool-schemas", "--config", &d.cfg_path])).unwrap();
    let nav = schemas.as_array().unwrap().iter().find(|s| s["function"]["name"] == "navigate").unwrap();
    if let Ok(dir) = std::env::var("NAVIGATE_OUT_DIR") {
        std::fs::write(PathBuf::from(dir).join("navigate-schema.json"), serde_json::to_string_pretty(nav).unwrap()).unwrap();
    }
    assert_eq!(nav["function"]["parameters"]["properties"]["mode"]["enum"], json!(["drive", "walk", "bike", "offroad_foot", "offroad_vehicle"]));
    // on foot between two points of the off-road parity set (R08), and by vehicle from Redfish Lake Lodge into the backcountry
    let trips = [("foot-r08", "offroad_foot", "44.18,-114.95", "44.23,-114.9"), ("vehicle-redfish", "offroad_vehicle", "44.1359,-114.9145", "44.1047,-114.9447")];
    for (name, mode, from, to) in trips {
        let mut ids = std::collections::BTreeSet::new();
        for land in ["strict", "pragmatic", "emergency"] {
            let v = d.content(&format!("offroad-{name}-{land}"), json!({"from": from, "to": to, "mode": mode, "land_access": land}), None);
            if v["ok"] == false {
                // no way under strict land access is the router's no_route, never a road route instead
                assert_eq!((land, err_type(&v)), ("strict", "no_route"), "{v}");
                continue;
            }
            assert_eq!(v["mode"], mode);
            assert!(v["offroad_mi"].as_f64().unwrap() > 0.0, "{v}");
            assert!(v.get("warnings").is_none(), "{v}");
            assert!(v.get("traffic").is_some_and(Value::is_null), "{v}");
            ids.insert(v["route_id"].as_str().unwrap().to_string());
            // the map's snapshot of the same route says the mode and the land access
            let full: Value = serde_json::from_str(&d.core.map_route(&json!({"route_id": v["route_id"]}).to_string()).unwrap()).unwrap();
            assert_eq!((full["mode"].as_str(), full["land_access"].as_str(), full["routing"].as_str()), (Some(mode), Some(land), Some("offroad")));
            assert_eq!(full["alternatives"], json!([]));
        }
        assert!(ids.len() >= 2, "{name}: each land access is its own route");
    }

    // without the off-road data an off-road mode says what is missing, through every door
    let t2 = Tmp::new("offroad-modes-road");
    let mut road = Doors::new(&t2, false);
    let e = road.content("offroad-foot-no-data", json!({"from": "44.18,-114.95", "to": "44.23,-114.9", "mode": "offroad_foot"}), None);
    assert_eq!(err_type(&e), "not_set_up");
    assert!(e["error"]["detail"].as_str().unwrap().contains("off-road data for this area"), "{e}");
    // and an area the installed off-road pack does not cover is the same
    let e = d.content("offroad-vehicle-outside", json!({"from": "47.6062,-122.3321", "to": "47.25,-122.44", "mode": "offroad_vehicle"}), None);
    assert_eq!(err_type(&e), "not_set_up", "{e}");
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


// ---- AIDA's recorded navigate results (cli/tests/fixtures/aida_navigate) ----------------------------------------------

/// AIDA's build order of the result and of a step (nav_runtime.py `navigate()`), with Cache's `n` after `ok` and its
/// two own fields last. The recorded rows are serialised with sorted keys, so order is checked against this list.
const RESULT_ORDER: [&str; 20] = [
    "ok", "n", "mode", "location_bias", "route_id", "from_matched", "to_matched", "other_destination_candidates", "nearest_search",
    "distance_mi", "distance_km", "duration_minutes", "direction_from_start", "major_roads", "traffic", "offroad_mi", "offroad_note", "warnings", "map_region", "map_region_age",
];
const PLACE_ORDER: [&str; 11] = ["place_name", "kind", "street", "locality", "county", "state", "distance_km", "near", "snap_distance_m", "lat", "lon"];

fn kind_of(v: &Value) -> &'static str {
    match v {
        Value::Null => "null",
        Value::Bool(_) => "bool",
        Value::Number(_) => "number",
        Value::String(_) => "string",
        Value::Array(_) => "array",
        Value::Object(_) => "object",
    }
}

fn names(v: &Value) -> Vec<String> {
    v.as_object().unwrap().keys().cloned().collect()
}

/// `got` lists keys in `order`'s order (it may leave some out).
fn in_order(got: &[String], order: &[&str], what: &str) {
    let mut at = 0;
    for k in got {
        let i = order.iter().position(|o| o == k).unwrap_or_else(|| panic!("{what}: unexpected key {k}"));
        assert!(i >= at, "{what}: {k} is out of order in {got:?}");
        at = i;
    }
}

/// Same types for every key both have (null stands in for anything: an unknown value).
fn same_types(got: &Value, want: &Value, what: &str) {
    for (k, g) in got.as_object().unwrap() {
        if let Some(w) = want.get(k) {
            if !g.is_null() && !w.is_null() {
                assert_eq!(kind_of(g), kind_of(w), "{what}.{k}: Cache {g} vs AIDA {w}");
            }
        }
    }
}

fn sorted(mut v: Vec<String>) -> Vec<String> {
    v.sort();
    v
}

/// What Cache cannot fill, and why (the values are null, the keys stay):
///  county, distance_km (the geocoder's county and distance to the bias point), and the `near` of from_matched / to_matched
///  (navi's reverse geocode of the end): no places pack yet; kind, street, locality, state of a place given as coordinates.
///  er_tier: only the places pack knows it.  pins, bridge: Meshtastic radio features, not on the phone.
fn compare_to_aida(example: &str, cache: &Value) {
    let rec: Value = serde_json::from_str(&std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/aida_navigate").join(example)).unwrap()).unwrap();
    let aida = &rec["result"];
    assert_eq!(cache["ok"], true, "{example}: {cache}");
    let got = names(cache);
    in_order(&got, &RESULT_ORDER, example);
    // every key of AIDA's result is in Cache's, except the radio's `pins` and the ones that depend on the route
    let conditional = ["pins", "road_steps_omitted", "offroad_steps_omitted", "offroad_mi", "offroad_note", "warnings", "nearest_search"];
    for k in names(aida) {
        if !conditional.contains(&k.as_str()) && !["steps", "step_count", "steps_truncated"].contains(&k.as_str()) {
            assert!(got.contains(&k), "{example}: AIDA has {k}, Cache does not ({got:?})");
        }
    }
    for k in &got {
        assert!(aida.get(k).is_some() || ["n", "map_region", "map_region_age", "direction_from_start", "traffic"].contains(&k.as_str()) || conditional.contains(&k.as_str()), "{example}: Cache has an extra key {k}");
    }
    same_types(cache, aida, example);
    for end in ["from_matched", "to_matched"] {
        in_order(&names(&cache[end]), &PLACE_ORDER, end);
        // AIDA's `_place` fields, `near` and `snap_distance_m`, plus er_tier when the source has one
        // (Cache adds `lat` and `lon` to both ends)
        let mut want: Vec<String> = names(&aida[end]).into_iter().filter(|k| k != "er_tier").collect();
        want.extend(["lat".to_string(), "lon".to_string()]);
        let have: Vec<String> = names(&cache[end]).into_iter().filter(|k| k != "er_tier").collect();
        assert_eq!(sorted(have), sorted(want), "{example}.{end}");
        same_types(&cache[end], &aida[end], end);
    }
    for c in cache["other_destination_candidates"].as_array().unwrap() {
        let want: Vec<String> = names(&aida["other_destination_candidates"][0]);
        assert_eq!(sorted(names(c)), sorted(want), "{example}: candidate");
    }
    for m in cache["major_roads"].as_array().unwrap() {
        assert_eq!(sorted(names(m)), ["distance_km", "name"], "{example}");
    }
    assert!(cache.get("steps").is_none(), "turn instructions belong to Maps");
    if let Some(w) = cache.get("warnings") {
        assert_eq!(names(&w[0]), ["code", "end", "road_point", "gap_m"]);
        if let Some(aw) = aida.get("warnings") {
            assert_eq!(sorted(names(&w[0])), sorted(names(&aw[0])));
        }
    }
    if let Some(n) = cache.get("offroad_note") {
        // AIDA's note with the grid size corrected (the z12 pixel grid is ~15 m in the US, not 30 m)
        let want = aida["offroad_note"].as_str().unwrap().replace("~30 m", "~15 m");
        assert_ne!(want, aida["offroad_note"].as_str().unwrap(), "{example}: AIDA's note no longer says ~30 m");
        assert_eq!(n.as_str().unwrap(), want, "{example}: AIDA's note text, grid size corrected");
    }
}

#[test]
fn results_match_aidas_recorded_navigate_results() {
    if data().is_none() {
        eprintln!("skipped: the Idaho data is not set");
        return;
    }
    let t = Tmp::new("golden");
    let (_, cfg) = config_file(&t, "config.json", Some(routing(true)));
    let mut core = Core::open(&cfg).unwrap();
    // AIDA's requests with the place names turned into coordinates (Cache has no geocoder yet); values differ, names and types must not
    let cases: [(&str, Value); 3] = [
        ("offroad-v24-12-t1-h.json", json!({"from": "43.4868,-116.4166", "to": "43.4575,-116.4180", "mode": "drive", "near": "Kuna, Idaho"})),
        ("offroad-v24-18-t1-h.json", json!({"from": "42.1167,-113.6339", "to": "42.0728,-113.7020", "mode": "drive", "near": "Almo, Idaho"})),
        ("v25-nav-offroad-010-r.json", json!({"from": "45.1763,-113.8956", "to": "45.0000,-113.9500", "mode": "drive", "near": "Salmon"})),
    ];
    let mut kinds = std::collections::BTreeSet::new();
    for (example, args) in &cases {
        let reply: Value = serde_json::from_str(&core.tool(&mut Conv::new().unwrap(), "navigate", &args.to_string(), NOW).unwrap()).unwrap();
        let v: Value = serde_json::from_str(reply["content"].as_str().unwrap()).unwrap();
        if let Ok(dir) = std::env::var("NAVIGATE_OUT_DIR") {
            std::fs::write(PathBuf::from(dir).join(format!("golden-{example}")), serde_json::to_string_pretty(&v).unwrap()).unwrap();
        }
        // the wire form of the c-abi result itself is `ok:true, n:1` first
        assert_eq!(names(&v)[..2], ["ok", "n"]);
        compare_to_aida(example, &v);
        if v["offroad_mi"].as_f64().unwrap_or(0.0) > 0.0 { kinds.insert("offroad".to_string()); }
    }
    // the off-road step fields were compared against AIDA's recorded ones somewhere in these routes
    assert!(kinds.contains("offroad") || kinds.contains("offroad_follow"), "no off-road legs in any golden route: {kinds:?}");

    // the warning example needs a road-only config: the road route stands in for the off-road leg
    let t2 = Tmp::new("golden-road");
    let (_, cfg2) = config_file(&t2, "config.json", Some(routing(false)));
    let mut road = Core::open(&cfg2).unwrap();
    let args = json!({"from": "44.1359,-114.9145", "to": "44.1047,-114.9447", "mode": "walk"});
    let reply: Value = serde_json::from_str(&road.tool(&mut Conv::new().unwrap(), "navigate", &args.to_string(), NOW).unwrap()).unwrap();
    let v: Value = serde_json::from_str(reply["content"].as_str().unwrap()).unwrap();
    if let Ok(dir) = std::env::var("NAVIGATE_OUT_DIR") {
        std::fs::write(PathBuf::from(dir).join("golden-warning.json"), serde_json::to_string_pretty(&v).unwrap()).unwrap();
    }
    compare_to_aida("warning-v25-offroad-v24-01-t1-r.json", &v);
    assert!(v.get("warnings").is_some(), "{v}");
}

#[test]
fn retained_route_lookup_rejects_missing_or_mixed_requests_without_rerouting() {
    let mut core = Core::open(r#"{"sources":[]}"#).unwrap();
    let missing = core.map_route(r#"{"route_id":"missing"}"#).unwrap_err().to_json();
    assert!(missing.contains("not_found"), "{missing}");
    for request in [r#"{"route_id":12}"#, r#"{"route_id":""}"#, r#"{"route_id":"x","to":"43,-116"}"#] {
        let error = core.map_route(request).unwrap_err().to_json();
        assert!(error.contains("bad_json"), "{error}");
    }
}

#[test]
fn tool_route_opens_exact_snapshot_through_http_and_c_abi_without_current_location() {
    if data().is_none() { eprintln!("skipped: snapshot integration needs Idaho routing data"); return; }
    let tmp = Tmp::new("tool-snapshot");
    let mut doors = Doors::new(&tmp, false);
    let summary = doors.content("snapshot", json!({"to":"42.7319,-114.5173", "mode":"bike", "land_access":"strict"}), Some((42.536,-113.792)));
    assert!(summary.get("steps").is_none());
    let request = json!({"route_id":summary["route_id"]}).to_string();
    let snapshot = doors.core.map_route(&request).unwrap();
    let http = doors.http.req("POST", "/map/route", &request);
    assert_eq!(snapshot, http);
    let full: Value = serde_json::from_str(&snapshot).unwrap();
    assert_eq!(full["ok"], true);
    assert_eq!(full["route_id"], summary["route_id"]);
    assert_eq!(full["mode"], "bike");
    assert_eq!(full["land_access"], "strict");
    assert!(full["maneuvers"].as_array().unwrap().len() > 0);
    assert!(!full["geometry"].as_str().unwrap().is_empty());
    assert_eq!(full["alternatives"], json!([]));
    // Opening a preview must register this snapshot for subsequent guidance progress.
    let progress = doors.core.map_progress(&json!({"route_id":summary["route_id"], "lat":42.536, "lon":-113.792, "now":NOW}).to_string()).unwrap();
    let progress: Value = serde_json::from_str(&progress).unwrap();
    assert_ne!(progress["ok"], false, "{progress}");
    assert_eq!(doors.core.map_route(&request).unwrap(), snapshot);
}
