//! Saved places, live data and the `live_data` tool through the three front doors: the `cs` CLI, `cs serve` (HTTP) and the
//! C ABI (the `Core` wrapper, which makes exactly the `cs_*` calls, `cs_tool` included). The same sequence runs on three separate states and every
//! step must give byte-identical output. No network: a local server plays Open-Meteo with a recorded response.

use cache_search_cli::engine::{Conv, Core};
use edge::{
    CreateIndex, Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, FieldIndexOperations, PayloadFieldSchema, PayloadSchemaParams,
    PointInsertOperations, PointOperations, PointStruct, TextIndexParams, TextScoringParams, UpdateOperation,
};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cs-feat-{}-{}", std::process::id(), name));
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

fn manifest() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

/// Serves the recorded Open-Meteo response for any request, until the process ends.
fn mock_server() -> u16 {
    let body = std::fs::read_to_string(manifest().join("../native/cache_live/tests/fixtures/openmeteo_burley.json")).unwrap();
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let port = server.server_addr().to_ip().unwrap().port();
    std::thread::spawn(move || {
        for req in server.incoming_requests() {
            let _ = req.respond(tiny_http::Response::from_string(body.clone()));
        }
    });
    port
}

/// A state directory: sources (the real weather definition, pointed at the mock), user.sqlite and live.sqlite paths,
/// and the `cs_open` config.
fn state(name: &str, port: u16) -> (Tmp, String, String) {
    let t = Tmp::new(name);
    std::fs::create_dir_all(t.0.join("sources")).unwrap();
    let mut d: Value = serde_json::from_str(&std::fs::read_to_string(manifest().join("../sources/weather.json")).unwrap()).unwrap();
    let url = d["request"]["url"].as_str().unwrap().to_string();
    d["request"]["url"] = json!(format!("http://127.0.0.1:{port}/v1/forecast{}", &url[url.find('?').unwrap()..]));
    std::fs::write(t.0.join("sources/weather.json"), d.to_string()).unwrap();
    let p = |f: &str| t.0.join(f).to_string_lossy().into_owned();
    let cfg = json!({"sources": [], "user": {"db_path": p("user.sqlite")}, "live": {"db_path": p("live.sqlite"), "sources_dir": p("sources")}});
    std::fs::write(t.0.join("config.json"), cfg.to_string()).unwrap();
    let cfg_path = p("config.json");
    (t, cfg_path, cfg.to_string())
}

/// One step's result: the JSON on success, or the `{"code","message"}` error JSON.
type Out = String;

trait Door {
    fn call(&mut self, op: &str, arg: &str, extra: &[&str]) -> Out;
}

fn cli(args: &[&str]) -> Out {
    let o = Command::new(env!("CARGO_BIN_EXE_cs")).args(args).output().expect("run cs");
    if o.status.success() {
        String::from_utf8(o.stdout).unwrap().strip_suffix('\n').expect("newline-terminated").to_string()
    } else {
        String::from_utf8(o.stderr).unwrap().trim_end().to_string()
    }
}

struct Cli(String);
impl Door for Cli {
    fn call(&mut self, op: &str, arg: &str, extra: &[&str]) -> Out {
        let c = self.0.as_str();
        match op {
            "places_list" => cli(&["places", "list", "--config", c]),
            "place_save" => cli(&["places", "save", "--config", c, "--place", arg]),
            "place_delete" => cli(&["places", "delete", "--config", c, "--key", arg]),
            "sources" => cli(&["live-sources", "--config", c]),
            "fetch" => cli(&["live-fetch", "--config", c, "--request", arg]),
            "get" => cli(&["live-get", "--config", c, "--request", arg]),
            "data" => {
                let (lat, lon);
                let mut a = vec!["tool", "live_data", "--config", c, "--args", arg, "--now", extra[1], "--json"];
                if !extra[0].is_empty() {
                    let l: Value = serde_json::from_str(extra[0]).unwrap();
                    (lat, lon) = (l["lat"].to_string(), l["lon"].to_string());
                    a.extend(["--lat", &lat, "--lon", &lon]);
                }
                cli(&a)
            }
            "schema" => cli(&["tool-schemas", "--config", c]),
            _ => unreachable!(),
        }
    }
}

struct Http {
    child: Child,
    addr: String,
}
impl Http {
    fn start(config: &str) -> Http {
        Http::start_with(config, &[])
    }
    fn start_with(config: &str, extra: &[&str]) -> Http {
        let mut child = Command::new(env!("CARGO_BIN_EXE_cs"))
            .args(["serve", "--listen", "127.0.0.1:0", "--config", config])
            .args(extra)
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
        let addr = line.trim().strip_prefix("listening ").unwrap().to_string();
        Http { child, addr }
    }
    fn req(&self, method: &str, path: &str, body: &str) -> Out {
        let mut s = TcpStream::connect(&self.addr).unwrap();
        write!(s, "{method} {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()).unwrap();
        let mut raw = Vec::new();
        s.read_to_end(&mut raw).unwrap();
        let text = String::from_utf8(raw).unwrap();
        text.split_once("\r\n\r\n").unwrap().1.to_string()
    }
}
impl Drop for Http {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
impl Door for Http {
    fn call(&mut self, op: &str, arg: &str, extra: &[&str]) -> Out {
        match op {
            "places_list" => self.req("GET", "/places", ""),
            "place_save" => self.req("POST", "/places", arg),
            "place_delete" => self.req("DELETE", &format!("/places/{arg}"), ""),
            "sources" => self.req("GET", "/live/sources", ""),
            "fetch" => self.req("POST", "/live/fetch", arg),
            "get" => self.req("POST", "/live/get", arg),
            "data" => {
                if !extra[0].is_empty() {
                    let mut l: Value = serde_json::from_str(extra[0]).unwrap();
                    l["fixed_at"] = json!(extra[1]);
                    self.req("POST", "/location", &l.to_string());
                }
                let id = serde_json::from_str::<Value>(&self.req("POST", "/conversations", "")).unwrap()["id"].as_str().unwrap().to_string();
                let b = json!({"name": "live_data", "args": serde_json::from_str::<Value>(arg).unwrap(), "now": extra[1]});
                let out = self.req("POST", &format!("/conversations/{id}/tool"), &b.to_string());
                if !extra[0].is_empty() {
                    self.req("DELETE", "/location", "");
                }
                out
            }
            "schema" => self.req("GET", "/tools", ""),
            _ => unreachable!(),
        }
    }
}

struct Direct(Core);
impl Door for Direct {
    fn call(&mut self, op: &str, arg: &str, extra: &[&str]) -> Out {
        let r = match op {
            "places_list" => self.0.places_list(),
            "place_save" => self.0.place_save(arg),
            "place_delete" => self.0.place_delete(arg),
            "sources" => self.0.live_sources(),
            "fetch" => self.0.live_fetch(arg),
            "get" => self.0.live_get(arg),
            "data" => {
                if !extra[0].is_empty() {
                    let l: Value = serde_json::from_str(extra[0]).unwrap();
                    self.0.set_location(l["lat"].as_f64().unwrap(), l["lon"].as_f64().unwrap(), -1.0, extra[1]).unwrap();
                }
                let r = Conv::new().and_then(|mut c| self.0.tool(&mut c, "live_data", arg, extra[1]));
                if !extra[0].is_empty() {
                    self.0.clear_location().unwrap();
                }
                r
            }
            "schema" => self.0.tool_schemas(),
            _ => unreachable!(),
        };
        match r {
            Ok(s) => s,
            Err(e) => e.to_json(),
        }
    }
}

const NOW: &str = "2026-10-25T10:50:00-06:00";

#[test]
fn places_and_live_data_are_identical_through_cli_serve_and_the_c_abi() {
    let port = mock_server();
    let (_t1, cfg1, _) = state("cli", port);
    let (_t2, cfg2, _) = state("http", port);
    let (_t3, _, json3) = state("abi", port);
    let (cfg2, _) = (cfg2, ());
    let mut doors: Vec<(&str, Box<dyn Door>)> = vec![
        ("cli", Box::new(Cli(cfg1))),
        ("serve", Box::new(Http::start(&cfg2))),
        ("c abi", Box::new(Direct(Core::open(&json3).unwrap()))),
    ];
    let here = r#"{"lat":42.536,"lon":-113.792,"accuracy_m":12,"fixed_at":"2026-10-25T10:40:00-06:00"}"#;
    let steps: Vec<(&str, String, [&str; 2])> = vec![
        ("places_list", String::new(), ["", ""]),
        ("sources", String::new(), ["", ""]),
        ("schema", String::new(), ["", ""]),
        ("place_save", r#"{"name":"Home","lat":42.536,"lon":-113.792}"#.into(), ["", ""]),
        ("place_save", r#"{"name":"Cabin","lat":43.1,"lon":-114.2,"label":"cabin"}"#.into(), ["", ""]),
        ("place_save", r#"{"name":"","lat":1,"lon":2}"#.into(), ["", ""]),
        ("places_list", String::new(), ["", ""]),
        ("data", r#"{"source":"weather","place":"Home"}"#.into(), ["", NOW]),
        ("get", format!(r#"{{"source":"weather","place":"Home","now":"{NOW}"}}"#), ["", ""]),
        ("fetch", format!(r#"{{"source":"weather","place":"Home","now":"{NOW}"}}"#), ["", ""]),
        ("fetch", format!(r#"{{"source":"weather","place":"home","now":"2026-10-25T11:00:00-06:00"}}"#), ["", ""]),
        ("fetch", format!(r#"{{"source":"weather","place":{{"key":"at:42.54,-113.79","name":"current location","lat":42.536,"lon":-113.792}},"now":"{NOW}"}}"#), ["", ""]),
        ("fetch", format!(r#"{{"source":"nope","place":"Home","now":"{NOW}"}}"#), ["", ""]),
        ("fetch", format!(r#"{{"source":"weather","place":"Nobody","now":"{NOW}"}}"#), ["", ""]),
        ("get", format!(r#"{{"source":"weather","place":"Home","now":"2026-10-25T12:50:00-06:00"}}"#), ["", ""]),
        ("data", r#"{"source":"weather","place":"home"}"#.into(), ["", "2026-10-25T12:50:00-06:00"]),
        ("data", r#"{"source":"weather"}"#.into(), [here, "2026-10-25T12:50:00-06:00"]),
        ("data", r#"{"source":"weather"}"#.into(), ["", NOW]),
        ("data", r#"{"source":"weather","place":"home"}"#.into(), ["", "2026-11-10T00:00:01-07:00"]),
        ("data", r#"{"source":"weather","place":"cabin"}"#.into(), ["", NOW]),
        ("data", r#"{"source":"weather","bogus":1}"#.into(), ["", NOW]),
        ("place_delete", "home".into(), ["", ""]),
        ("place_delete", "home".into(), ["", ""]),
        ("get", format!(r#"{{"source":"weather","place":{{"key":"home","name":"Home","lat":42.536,"lon":-113.792}},"now":"{NOW}"}}"#), ["", ""]),
        ("places_list", String::new(), ["", ""]),
    ];
    for (i, (op, arg, extra)) in steps.iter().enumerate() {
        let outs: Vec<(String, Out)> = doors.iter_mut().map(|(n, d)| (n.to_string(), d.call(op, arg, extra))).collect();
        for (n, o) in &outs[1..] {
            assert_eq!(o, &outs[0].1, "step {i} {op} {arg}: {n} differs from {}", outs[0].0);
        }
        // spot checks on the shared result
        let mut v: Value = serde_json::from_str(&outs[0].1).unwrap_or_else(|e| panic!("step {i} {op}: not JSON ({e}): {}", outs[0].1));
        if *op == "data" {
            // cs_tool gives {"content","ids"}; the content is the tool result as the model sees it
            v = serde_json::from_str(v["content"].as_str().unwrap()).unwrap();
        }
        match (i, *op) {
            (0, _) => assert_eq!(v, json!({"places": []})),
            (2, _) => {
                let live = v.as_array().unwrap().iter().find(|t| t["function"]["name"] == "live_data").expect("live_data is offered");
                assert_eq!(live["function"]["parameters"]["properties"]["source"]["enum"], json!(["weather"]));
            }
            (3, _) => assert_eq!(v["key"], "home"),
            (5, _) => assert_eq!(v["code"], "bad_json"),
            (7, _) => assert_eq!(v["error"]["type"], "no_data"),
            (8, _) => assert_eq!(v["code"], "not_found"),
            (9, _) => assert_eq!((v["fetched"].clone(), v["items"].as_array().unwrap().len()), (json!(true), 17)),
            (10, _) => assert_eq!(v["fetched"], false),
            (12, _) => assert_eq!(v["code"], "not_found"),
            (15, _) => {
                assert_eq!(v["ok"], true);
                assert_eq!(v["items"].as_array().unwrap().len(), 12);
                // the framework swapped each item's address for its number
                assert_eq!(v["items"][0]["n"], 1);
                assert_eq!(v["items"][11]["n"], 12);
                assert!(v["items"][0].get("address").is_none());
                assert_eq!(v["items"][0].as_object().unwrap().keys().collect::<Vec<_>>(), ["n", "label", "time", "fields"]);
                assert_eq!(v["age"], "2 hours old");
            }
            // the phone's position is a place too (fetched in step 11 under its rounded key)
            (16, _) => assert_eq!((v["place"].clone(), v["items"][0]["label"].clone()), (json!("current location"), json!("Now"))),
            (17, _) => assert_eq!(v["error"]["type"], "no_location"),
            (18, _) => assert_eq!(v["error"]["type"], "expired"),
            (19, _) => assert_eq!(v["error"]["type"], "no_data"),
            (20, _) => assert_eq!(v["error"]["type"], "bad_arguments"),
            (21, _) => assert_eq!(v, json!({"deleted": "home"})),
            (22, _) => assert_eq!(v["code"], "not_found"),
            // deleting the saved place deleted its downloaded data
            (23, _) => assert_eq!(v["code"], "not_found"),
            (24, _) => assert_eq!(v["places"].as_array().unwrap().len(), 1),
            _ => {}
        }
    }
    // an unconfigured handle
    let t = Tmp::new("bare");
    let mut core = Core::open(r#"{"sources":[]}"#).unwrap();
    assert_eq!(core.places_list().unwrap_err().code, "not_configured");
    assert_eq!(core.live_get("{}").unwrap_err().code, "not_configured");
    let _ = (&t, Path::new("."));
}

// ---- the live_data tool through cs_tool: numbering across tools, and when it is offered ---------------------------------

/// A small library (for `search`) next to the user and live sections; returns (config path, config JSON).
fn tool_state(name: &str, port: u16, with_definitions: bool, with_live: bool) -> (Tmp, String, String) {
    let (t, _, _) = state(name, port);
    let shard = t.0.join("shard").to_string_lossy().into_owned();
    {
        cache_search::library::ensure_init();
        let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(4, Distance::Cosine).build()).build();
        let sh = EdgeShard::new(Path::new(&shard), cfg).unwrap();
        let schema = PayloadFieldSchema::FieldParams(PayloadSchemaParams::Text(TextIndexParams {
            scoring: Some(TextScoringParams::default()),
            ..TextIndexParams::default()
        }));
        sh.update(UpdateOperation::FieldIndexOperation(FieldIndexOperations::CreateIndex(CreateIndex {
            field_name: "content".parse().unwrap(),
            field_schema: Some(schema),
        })))
        .unwrap();
        let pts: Vec<_> = (1..=6u64)
            .map(|i| {
                let content = if i == 3 { "The sesquipedalian word appears once".to_string() } else { format!("Alpha text number {i} here") };
                PointStruct::new(i, vec![1.0, i as f32, 0.5, 0.25], json!({"title": format!("Doc {i}"), "content": content})).0
            })
            .collect();
        sh.update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(pts)))).unwrap();
        sh.flush().unwrap();
        drop(sh);
        cache_search::library::write_segments_manifest(Path::new(&shard)).unwrap();
    }
    let settings = json!({"format": 1, "library_id": "fx", "title": "Fixture", "fields": {"title": "title", "text": "content"},
        "embedding": {"vector": "", "model": "m", "sha256": "x", "dims": 4}, "keyword_index": "auto"});
    let p = |f: &str| t.0.join(f).to_string_lossy().into_owned();
    if !with_definitions {
        std::fs::remove_file(t.0.join("sources/weather.json")).unwrap();
    }
    let mut cfg = json!({"sources": [{"kind": "library", "path": shard, "settings": settings}], "user": {"db_path": p("user.sqlite")}});
    if with_live {
        cfg["live"] = json!({"db_path": p("live.sqlite"), "sources_dir": p("sources")});
    }
    let path = p("config.json");
    std::fs::write(&path, cfg.to_string()).unwrap();
    (t, path, cfg.to_string())
}

fn names(schemas: &str) -> Vec<String> {
    serde_json::from_str::<Value>(schemas).unwrap().as_array().unwrap().iter().map(|t| t["function"]["name"].as_str().unwrap().to_string()).collect()
}

#[test]
fn live_data_through_cs_tool_numbers_and_continues_after_search() {
    let port = mock_server();
    let (_t1, cfg1, _) = tool_state("e2e-http", port, true, true);
    let (_t2, _cfg2, json2) = tool_state("e2e-abi", port, true, true);
    let (_t3, cfg3, _) = tool_state("e2e-cli", port, true, true);
    let mut http = Http::start(&cfg1);
    let mut core = Core::open(&json2).unwrap();
    core.wait_ready(std::time::Duration::from_secs(60)).unwrap();
    let mut conv = Conv::new().unwrap();
    // a saved place and its downloaded weather, set up the same way on the three states
    let place = r#"{"name":"Home","lat":42.536,"lon":-113.792}"#;
    let fetch = format!(r#"{{"source":"weather","place":"Home","now":"{NOW}"}}"#);
    http.call("place_save", place, &["", ""]);
    http.call("fetch", &fetch, &["", ""]);
    core.place_save(place).unwrap();
    core.live_fetch(&fetch).unwrap();
    let mut cli_door = Cli(cfg3.clone());
    cli_door.call("place_save", place, &["", ""]);
    cli_door.call("fetch", &fetch, &["", ""]);

    // serve: one conversation; the C ABI: one conversation; same calls, same bytes
    let id = serde_json::from_str::<Value>(&http.req("POST", "/conversations", "")).unwrap()["id"].as_str().unwrap().to_string();
    let path = format!("/conversations/{id}/tool");
    let calls: Vec<(&str, Value)> = vec![
        ("search", json!({"query": "sesquipedalian"})),
        ("live_data", json!({"source": "weather", "place": "home"})),
        ("live_data", json!({"source": "weather", "place": "Home"})),
        ("search", json!({"query": "alpha"})),
        ("live_data", json!({"source": "weather", "place": "Home"})),
    ];
    let mut outs = Vec::new();
    for (name, args) in &calls {
        let b = http.req("POST", &path, &json!({"name": name, "args": args, "now": NOW}).to_string());
        let a = core.tool(&mut conv, name, &args.to_string(), NOW).unwrap();
        assert_eq!(a, b, "{name} {args}: the C ABI and serve differ");
        outs.push(serde_json::from_str::<Value>(&a).unwrap());
    }
    // 1. search numbered its one hit [1]
    assert!(outs[0]["content"].as_str().unwrap().starts_with("[1] Doc 3"), "{}", outs[0]["content"]);
    // 2. live_data continues from [2]: 12 items, "n" in place of "address", in TOOLS.md's field order
    let live: Value = serde_json::from_str(outs[1]["content"].as_str().unwrap()).unwrap();
    assert_eq!(live["ok"], true);
    assert_eq!(live.as_object().unwrap().keys().collect::<Vec<_>>(), ["ok", "source", "place", "fetched_at", "valid_until", "age", "expired", "items", "more", "not_covered_after"]);
    assert_eq!(live["place"], "Home");
    let ns: Vec<u64> = live["items"].as_array().unwrap().iter().map(|i| i["n"].as_u64().unwrap()).collect();
    assert_eq!(ns, (2..=13).collect::<Vec<u64>>());
    assert_eq!(live["items"][0].as_object().unwrap().keys().collect::<Vec<_>>(), ["n", "label", "time", "fields"]);
    assert_eq!(live["items"][0]["fields"].as_object().unwrap().keys().collect::<Vec<_>>(), ["Temperature", "Feels like", "Wind", "Conditions"]);
    assert!(!outs[1]["content"].as_str().unwrap().contains("\"address\""));
    // the ids the citation check gets: the search hit, then the live items, addresses with the place key
    let ids = outs[1]["ids"].as_array().unwrap();
    assert_eq!(ids.len(), 12);
    assert_eq!(ids[0], json!({"n": 2, "address": "live:weather/home/now", "title": "Now"}));
    assert_eq!(ids[1]["address"], "live:weather/home/2026-10-25");
    // 3. the same items again keep their numbers (the place was found by name, case-insensitively, via cache_user)
    assert_eq!(outs[2]["content"], outs[1]["content"]);
    // 4. a later search continues after the live items
    assert!(outs[3]["content"].as_str().unwrap().contains("[14] "), "{}", outs[3]["content"]);
    // 5. and live_data after it still has its old numbers
    assert_eq!(outs[4]["content"], outs[1]["content"]);
    // a repeated call numbers nothing new; the whole id map is the search hit, 12 live items and the 5 later hits
    assert_eq!(outs[2]["ids"], json!([]));
    let map = serde_json::from_str::<Value>(&conv.ids().unwrap()).unwrap();
    let ns: Vec<u64> = map["ids"].as_array().unwrap().iter().map(|i| i["n"].as_u64().unwrap()).collect();
    assert_eq!(ns, (1..=18).collect::<Vec<u64>>());
    assert_eq!(map["ids"][1]["address"], "live:weather/home/now");

    // a fresh conversation numbers from [1]; the CLI gives the same bytes as serve and the C ABI for it
    let id2 = serde_json::from_str::<Value>(&http.req("POST", "/conversations", "")).unwrap()["id"].as_str().unwrap().to_string();
    let from_http = http.req("POST", &format!("/conversations/{id2}/tool"), &json!({"name": "live_data", "args": {"source": "weather", "place": "Home"}, "now": NOW}).to_string());
    let from_abi = core.tool(&mut Conv::new().unwrap(), "live_data", r#"{"source":"weather","place":"Home"}"#, NOW).unwrap();
    let from_cli = cli(&["tool", "live_data", "--config", &cfg3, "--args", r#"{"source":"weather","place":"Home"}"#, "--now", NOW, "--json"]);
    assert_eq!(from_http, from_abi);
    assert_eq!(from_cli, from_abi);
    let fresh: Value = serde_json::from_str(&serde_json::from_str::<Value>(&from_cli).unwrap()["content"].as_str().unwrap().to_string()).unwrap();
    assert_eq!(fresh["items"][0]["n"], 1);

    // cs_tool_schemas offers live_data only when definitions are installed
    let with = http.req("GET", "/tools", "");
    assert_eq!(names(&with), ["search", "read", "live_data", "calculate"]);
    assert_eq!(with, core.tool_schemas().unwrap());
    assert_eq!(with, cli(&["tool-schemas", "--config", &cfg3]));
    let (_ta, cfg_nodefs, json_nodefs) = tool_state("e2e-nodefs", port, false, true);
    let (_tb, cfg_nolive, json_nolive) = tool_state("e2e-nolive", port, true, false);
    for (cfg, json_cfg) in [(&cfg_nodefs, &json_nodefs), (&cfg_nolive, &json_nolive)] {
        let abi = Core::open(json_cfg).unwrap().tool_schemas().unwrap();
        assert_eq!(names(&abi), ["search", "read", "calculate"], "{json_cfg}");
        assert_eq!(abi, cli(&["tool-schemas", "--config", cfg]));
    }
    // without definitions the tool is simply not there: a call is the unknown-tool error, like any unregistered tool
    let mut nodefs = Core::open(&json_nodefs).unwrap();
    let r = nodefs.tool(&mut Conv::new().unwrap(), "live_data", r#"{"source":"weather"}"#, NOW).unwrap();
    assert!(serde_json::from_str::<Value>(&r).unwrap()["content"].as_str().unwrap().contains("not_set_up"), "{r}");
}

// ---- live_data resolves the place through the places pack (cs_tool: the handle plugs the pack in as ToolCtx::geocoder) ----

#[test]
fn live_data_resolves_place_names_through_the_places_pack() {
    let port = mock_server();
    let (t, _, json) = state("places-pack", port);
    let pack = t.0.join("places.sqlite");
    cache_places::fixture::write_fixture_pack(&pack);
    let mut cfg: Value = serde_json::from_str(&json).unwrap();
    let plain = cfg.to_string();
    cfg["places"] = json!({"packs": [pack.to_string_lossy()]});
    let with_pack = cfg.to_string();

    let tool = |core: &mut Core, args: Value| -> Value {
        let out = core.tool(&mut Conv::new().unwrap(), "live_data", &args.to_string(), NOW).unwrap();
        serde_json::from_str::<Value>(&serde_json::from_str::<Value>(&out).unwrap()["content"].as_str().unwrap().to_string()).unwrap()
    };
    // weather for Burley, stored under a saved place; Rupert is 13 km away and has none of its own
    let mut core = Core::open(&with_pack).unwrap();
    core.wait_ready(std::time::Duration::from_secs(60)).unwrap();
    core.place_save(r#"{"name":"Home","lat":42.536,"lon":-113.792}"#).unwrap();
    core.live_fetch(&format!(r#"{{"source":"weather","place":"Home","now":"{NOW}"}}"#)).unwrap();
    let mut first: Option<Value> = None;
    for text in ["Rupert, Idaho", "rupert id", "Rupret", "42.6166,-113.6747"] {
        let v = tool(&mut core, json!({"source": "weather", "place": text}));
        assert_eq!(v["ok"], true, "{text}: {v}");
        assert_eq!(v["place"], "Home", "{text}");
        assert_eq!(v["distance_from_asked_km"], 13, "{text}");
        assert!(v["asked_place"].as_str().unwrap().starts_with("Rupert, ID") || text.starts_with("42."), "{text}: {v}");
        assert!(v["items"][0]["n"].is_number() && v["items"][0].get("address").is_none());
        let items = v["items"].clone();
        assert_eq!(first.get_or_insert(items.clone()), &items, "{text}");
    }
    // out of range: no_data naming the nearest, not geocode_empty; a name that is no place is geocode_empty
    let e = tool(&mut core, json!({"source": "weather", "place": "Boise"}));
    assert_eq!(e["ok"], false);
    assert_eq!(e["error"]["type"], "no_data");
    assert!(e["error"]["detail"].as_str().unwrap().contains("the nearest place with data is Home, 230 km away"), "{e}");
    assert_eq!(tool(&mut core, json!({"source": "weather", "place": "Xqzvk Plugh"}))["error"]["type"], "geocode_empty");
    // the phone's position, 10 km from Burley
    core.set_location(42.60, -113.70, 10.0, NOW).unwrap();
    let v = tool(&mut core, json!({"source": "weather"}));
    assert_eq!((v["place"].as_str(), v["asked_place"].as_str(), v["distance_from_asked_km"].as_i64()), (Some("Home"), Some("current location"), Some(10)));
    drop(core);

    // the same state without a places section: the saved place and coordinates work, a town name is geocode_empty
    let mut core = Core::open(&plain).unwrap();
    core.wait_ready(std::time::Duration::from_secs(60)).unwrap();
    assert_eq!(tool(&mut core, json!({"source": "weather", "place": "Home"}))["place"], "Home");
    assert_eq!(tool(&mut core, json!({"source": "weather", "place": "42.60,-113.70"}))["place"], "Home");
    assert_eq!(tool(&mut core, json!({"source": "weather", "place": "Rupert, Idaho"}))["error"]["type"], "geocode_empty");
}

// ---- cs serve --live-state: live_data's not_refreshed without a network --------------------------------------------------

#[test]
fn serve_live_state_gives_each_not_refreshed_reason_and_leaves_everything_else_alone() {
    let port = mock_server();
    let (t, cfg, _) = state("livestate", port);
    // alerts installed too (never downloaded here: every state below stands in for the network)
    std::fs::copy(manifest().join("../sources/alerts.json"), t.0.join("sources/alerts.json")).unwrap();
    cli(&["places", "save", "--config", &cfg, "--place", r#"{"name":"Home","lat":42.536,"lon":-113.792}"#]);
    let fetched = cli(&["live-fetch", "--config", &cfg, "--request", &format!(r#"{{"source":"weather","place":"Home","now":"{NOW}"}}"#)]);
    assert!(fetched.contains(r#""fetched":true"#), "{fetched}");
    // four hours after the download: past weather's 3-hour refresh interval, still valid
    let due = "2026-10-25T14:50:00-06:00";
    let expired = "2027-01-01T12:00:00-07:00";
    let ask = |h: &Http, args: Value, now: &str| -> Value {
        let id = serde_json::from_str::<Value>(&h.req("POST", "/conversations", "")).unwrap()["id"].as_str().unwrap().to_string();
        let b = h.req("POST", &format!("/conversations/{id}/tool"), &json!({"name": "live_data", "args": args, "now": now}).to_string());
        serde_json::from_str(serde_json::from_str::<Value>(&b).unwrap()["content"].as_str().unwrap()).unwrap()
    };
    let home = json!({"source": "weather", "place": "Home"});
    let plain = Http::start(&cfg);
    let before = ask(&plain, home.clone(), due);
    let tools = plain.req("GET", "/tools", "");
    drop(plain);
    assert!(before.get("not_refreshed").is_none());
    for (flags, words) in [
        (vec!["--live-state", "off"], "this source is switched off"),
        (vec!["--live-state", "offline"], "no connection"),
        (vec!["--live-state", "metered"], "mobile data updates are off"),
        (vec!["--live-state", "fail:fetch_failed"], "refresh failed: couldn't reach the source"),
        (vec!["--live-state", "fail:quota"], "refresh failed: daily limit reached"),
        (vec!["--live-state", "fail:key_missing"], "refresh failed: API key missing"),
        (vec!["--live-state", "fail:bad_response"], "refresh failed: the source sent bad data"),
        // one source's own state wins over the one for every source
        (vec!["--live-state", "offline", "--live-state", "weather=metered"], "mobile data updates are off"),
    ] {
        let h = Http::start_with(&cfg, &flags);
        let v = ask(&h, home.clone(), due);
        assert_eq!(v["not_refreshed"], words, "{flags:?}");
        let mut without = v.clone();
        without.as_object_mut().unwrap().remove("not_refreshed");
        assert_eq!(without.to_string(), before.to_string(), "{flags:?}: only the new field");
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys[..8], ["ok", "source", "place", "fetched_at", "valid_until", "age", "expired", "not_refreshed"]);
        assert_eq!(h.req("GET", "/tools", ""), tools, "{flags:?}: the tool list does not follow the live state");
    }
    // normal: no reason, the same bytes as without the flag
    let h = Http::start_with(&cfg, &["--live-state", "normal"]);
    assert_eq!(ask(&h, home.clone(), due).to_string(), before.to_string());
    drop(h);
    // the two combined cases in one serve: weather expired on metered data, and alerts (never downloaded) while offline
    let h = Http::start_with(&cfg, &["--live-state", "metered", "--live-state", "alerts=offline"]);
    let v = ask(&h, home.clone(), expired);
    assert_eq!((v["error"]["type"].as_str(), v["not_refreshed"].as_str()), (Some("expired"), Some("mobile data updates are off")), "{v}");
    let v = ask(&h, json!({"source": "alerts", "place": "Home"}), due);
    assert_eq!((v["error"]["type"].as_str(), v["not_refreshed"].as_str()), (Some("no_data"), Some("no connection")), "{v}");
    drop(h);
    // a bad state stops the start
    for bad in [vec!["--live-state", "sleepy"], vec!["--live-state", "off", "--live-state", "offline"], vec!["--live-state", "=off"]] {
        let mut args = vec!["serve", "--listen", "127.0.0.1:0", "--config", cfg.as_str()];
        args.extend(bad.iter());
        let o = Command::new(env!("CARGO_BIN_EXE_cs")).args(&args).output().unwrap();
        assert!(!o.status.success(), "{bad:?}");
    }
}
