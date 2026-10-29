//! The nearby and locate tools through the three front doors: the `cs` CLI, `cs serve` (HTTP) and the C ABI (the `Core`
//! wrapper, which makes exactly the `cs_*` calls). The same sequence runs on three separate handles over the same
//! small Idaho pack and every step must give byte-identical output.

use cache_places::fixture::{write_fixture_pack, FIXTURE_NOW};
use cache_search_cli::engine::{Conv, Core};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cs-places-{}-{}", std::process::id(), name));
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

type Out = String;

/// One step: the tool name, its arguments, and the phone's location (lat, lon) if any.
trait Door {
    fn schemas(&mut self) -> Out;
    fn tool(&mut self, name: &str, args: &str, here: Option<(f64, f64)>) -> Out;
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
    fn schemas(&mut self) -> Out {
        cli(&["tool-schemas", "--config", &self.0])
    }
    fn tool(&mut self, name: &str, args: &str, here: Option<(f64, f64)>) -> Out {
        let mut a = vec!["tool", name, "--config", self.0.as_str(), "--args", args, "--now", FIXTURE_NOW, "--json"];
        let (lat, lon);
        if let Some((la, lo)) = here {
            (lat, lon) = (la.to_string(), lo.to_string());
            a.extend(["--lat", &lat, "--lon", &lon, "--accuracy", "12"]);
        }
        cli(&a)
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
    fn req(&self, method: &str, path: &str, body: &str) -> Out {
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
impl Door for Http {
    fn schemas(&mut self) -> Out {
        self.req("GET", "/tools", "")
    }
    fn tool(&mut self, name: &str, args: &str, here: Option<(f64, f64)>) -> Out {
        if let Some((lat, lon)) = here {
            self.req("POST", "/location", &json!({"lat": lat, "lon": lon, "accuracy_m": 12, "fixed_at": FIXTURE_NOW}).to_string());
        }
        let id = serde_json::from_str::<Value>(&self.req("POST", "/conversations", "")).unwrap()["id"].as_str().unwrap().to_string();
        let b = json!({"name": name, "args": serde_json::from_str::<Value>(args).unwrap(), "now": FIXTURE_NOW});
        let out = self.req("POST", &format!("/conversations/{id}/tool"), &b.to_string());
        if here.is_some() {
            self.req("DELETE", "/location", "");
        }
        out
    }
}

struct Direct(Core);
impl Door for Direct {
    fn schemas(&mut self) -> Out {
        self.0.tool_schemas().unwrap_or_else(|e| e.to_json())
    }
    fn tool(&mut self, name: &str, args: &str, here: Option<(f64, f64)>) -> Out {
        if let Some((lat, lon)) = here {
            self.0.set_location(lat, lon, 12.0, FIXTURE_NOW).unwrap();
        }
        let r = Conv::new().and_then(|mut c| self.0.tool(&mut c, name, args, FIXTURE_NOW));
        if here.is_some() {
            self.0.clear_location().unwrap();
        }
        r.unwrap_or_else(|e| e.to_json())
    }
}

fn content(out: &str) -> Value {
    let v: Value = serde_json::from_str(out).unwrap_or_else(|e| panic!("not JSON ({e}): {out}"));
    serde_json::from_str(v["content"].as_str().unwrap()).unwrap()
}

#[test]
fn nearby_and_locate_are_identical_through_cli_serve_and_the_c_abi() {
    let t = Tmp::new("pack");
    let pack = t.0.join("places.sqlite");
    write_fixture_pack(&pack);
    let cfg = json!({"sources": [], "places": {"packs": [pack.to_string_lossy()]}});
    let cfg_path = t.0.join("config.json");
    std::fs::write(&cfg_path, cfg.to_string()).unwrap();
    let cfg_path = cfg_path.to_string_lossy().into_owned();

    let mut doors: Vec<(&str, Box<dyn Door>)> = vec![
        ("cli", Box::new(Cli(cfg_path.clone()))),
        ("serve", Box::new(Http::start(&cfg_path))),
        ("c abi", Box::new(Direct(Core::open(&cfg.to_string()).unwrap()))),
    ];

    // The schemas: nearby's enum comes from the pack.
    let outs: Vec<Out> = doors.iter_mut().map(|(_, d)| d.schemas()).collect();
    assert!(outs.iter().all(|o| *o == outs[0]), "schemas differ");
    let schemas: Value = serde_json::from_str(&outs[0]).unwrap();
    let names: Vec<&str> = schemas.as_array().unwrap().iter().map(|s| s["function"]["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["search", "read", "nearby", "locate", "calculate"]);

    let burley = Some((42.536, -113.792));
    let idaho_city = Some((43.828, -115.834));
    let steps: Vec<(&str, &str, Option<(f64, f64)>)> = vec![
        ("nearby", r#"{"category":"pharmacy","near":"Burley, Idaho"}"#, None),
        ("nearby", r#"{"category":"pharmacy"}"#, burley),
        ("nearby", r#"{"category":"emergency_room","limit":2}"#, idaho_city),
        ("nearby", r#"{"category":"pharmacy"}"#, None),
        ("nearby", r#"{"category":"fuel","near":"Nowhereville"}"#, None),
        ("nearby", r#"{"category":"urgent_care"}"#, burley),
        ("nearby", r#"{"category":"fuel","limit":99}"#, burley),
        ("locate", r#"{"place":"Stanley, Idaho"}"#, None),
        ("locate", r#"{}"#, Some((43.615, -116.202))),
        ("locate", r#"{}"#, None),
        ("locate", r#"{"place":"Nowhereville"}"#, None),
        ("locate", r#"{"place":"Burley"}"#, None),
    ];
    for (i, (name, args, here)) in steps.iter().enumerate() {
        let outs: Vec<(String, Out)> = doors.iter_mut().map(|(n, d)| (n.to_string(), d.tool(name, args, *here))).collect();
        for (n, o) in &outs[1..] {
            assert_eq!(o, &outs[0].1, "step {i} {name} {args}: {n} differs from {}", outs[0].0);
        }
        let v = content(&outs[0].1);
        match i {
            0 => {
                assert_eq!(v["ok"], true);
                assert_eq!(v["places"][0]["n"], 1);
                assert_eq!(v["places"][0]["name"], "Walgreens");
                assert!(v["places"][0].get("address").is_none());
            }
            1 => assert_eq!(v["center"], "current location"),
            2 => assert_eq!(v["places"][0]["name"], "St. Luke's Boise Medical Center"),
            3 => assert_eq!(v["error"]["type"], "no_location"),
            4 => assert_eq!(v["error"]["type"], "geocode_empty"),
            5 | 6 => assert_eq!(v["error"]["type"], "bad_arguments"),
            7 => assert_eq!((v["n"].clone(), v["place_name"].clone()), (json!(1), json!("Stanley, ID"))),
            8 => assert_eq!((v["accuracy_m"].clone(), v["nearest_town"].clone()), (json!(12), json!("Boise, ID"))),
            9 => assert_eq!(v["error"]["type"], "no_location"),
            10 => assert_eq!(v["error"]["type"], "geocode_empty"),
            11 => assert_eq!(v["place_name"], "Burley, ID"),
            _ => {}
        }
    }

    // A handle with a places section but no pack file: nearby is not offered, locate is.
    let none = json!({"sources": [], "places": {"packs": [t.0.join("missing.sqlite").to_string_lossy()]}}).to_string();
    let mut core = Core::open(&none).unwrap();
    let s: Value = serde_json::from_str(&core.tool_schemas().unwrap()).unwrap();
    let names: Vec<&str> = s.as_array().unwrap().iter().map(|x| x["function"]["name"].as_str().unwrap()).collect();
    assert_eq!(names, ["search", "read", "locate", "calculate"]);
    let mut conv = Conv::new().unwrap();
    let out = core.tool(&mut conv, "nearby", r#"{"category":"fuel"}"#, FIXTURE_NOW).unwrap();
    assert_eq!(content(&out)["error"]["type"], "not_set_up");
}
