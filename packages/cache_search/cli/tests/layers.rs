//! Map layers through the three front doors: the `cs` CLI, `cs serve` (HTTP) and the C ABI (the `Core` wrapper).
//! The same sequence runs on three separate states against one fake tile host, and every step must give
//! byte-identical output (apart from the download time stamp, which is blanked). No real network.

use cache_search_cli::commands::tile_summary;
use cache_search_cli::engine::Core;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cs-layers-{}-{}", std::process::id(), name));
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

fn tile_body(z: u8, x: u32, y: u32) -> Vec<u8> {
    format!("tile-{z}-{x}-{y}-{}", "q".repeat(((x * 7 + y) % 9) as usize + 3)).into_bytes()
}

/// A fake XYZ host: `/z/x/y` for any tile.
fn host() -> u16 {
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let port = server.server_addr().to_ip().unwrap().port();
    std::thread::spawn(move || {
        for req in server.incoming_requests() {
            let p: Vec<u32> = req.url().trim_start_matches('/').split('/').filter_map(|s| s.parse().ok()).collect();
            let r = if p.len() == 3 { tiny_http::Response::from_data(tile_body(p[0] as u8, p[1], p[2])) } else { tiny_http::Response::from_data(vec![]).with_status_code(404) };
            let _ = req.respond(r);
        }
    });
    port
}

fn def(id: &str, port: u16, title: &str) -> Value {
    json!({"format": 1, "id": id, "title": title, "kind": "vector", "transform": "as_is",
      "source": {"type": "xyz", "url": format!("http://127.0.0.1:{port}/{{z}}/{{x}}/{{y}}"), "minzoom": 0, "maxzoom": 10, "tile_format": "mvt"},
      "attribution": "test", "license": "test", "offline": {"allowed": true, "max_tiles_per_download": 5000, "max_parallel": 3}, "update": {"version": "1"}})
}

fn state(name: &str, port: u16) -> (Tmp, String, String) {
    let t = Tmp::new(name);
    std::fs::create_dir_all(t.0.join("defs")).unwrap();
    std::fs::write(t.0.join("defs/base.json"), def("base", port, "Base").to_string()).unwrap();
    let sat = json!({"format": 1, "id": "sat", "title": "Sat", "kind": "online-raster", "transform": "online_only",
      "source": {"type": "xyz", "url": format!("http://127.0.0.1:{port}/{{z}}/{{x}}/{{y}}"), "tile_format": "jpg"}, "offline": {"allowed": false}, "enabled_by_default": false});
    std::fs::write(t.0.join("defs/sat.json"), sat.to_string()).unwrap();
    let p = |f: &str| t.0.join(f).to_string_lossy().into_owned();
    let cfg = json!({"sources": [], "layers": {"dir": p("layers"), "defs_dirs": [p("defs")], "online": true}});
    std::fs::write(t.0.join("config.json"), cfg.to_string()).unwrap();
    let cp = p("config.json");
    (t, cp, cfg.to_string())
}

type Out = String;

trait Door {
    fn call(&mut self, op: &str, arg: &str) -> Out;
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
    fn call(&mut self, op: &str, arg: &str) -> Out {
        let c = self.0.as_str();
        match op {
            "list" => cli(&["layers", "list", "--config", c]),
            "save" => cli(&["layers", "save", "--config", c, "--def", arg]),
            "remove" => cli(&["layers", "remove", "--config", c, "--id", arg]),
            "plan" => cli(&["layers", "plan", "--config", c, "--request", arg]),
            "download" => cli(&["layers", "download", "--config", c, "--request", arg]),
            "delete" => cli(&["layers", "delete", "--config", c, "--request", arg]),
            "clear" => cli(&["layers", "clear-cache", "--config", c]),
            "tile" => {
                let v: Value = serde_json::from_str(arg).unwrap();
                let s = |k: &str| v[k].to_string();
                cli(&["layers", "tile", "--config", c, "--layer", v["layer"].as_str().unwrap(), "--z", &s("z"), "--x", &s("x"), "--y", &s("y")])
            }
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
        let mut child = Command::new(env!("CARGO_BIN_EXE_cs")).args(["serve", "--listen", "127.0.0.1:0", "--config", config]).stdout(Stdio::piped()).stderr(Stdio::inherit()).spawn().unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
        Http { child, addr: line.trim().strip_prefix("listening ").unwrap().to_string() }
    }
}
fn http_req(addr: &str, method: &str, path: &str, body: &str) -> Out {
    let mut s = TcpStream::connect(addr).unwrap();
    write!(s, "{method} {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()).unwrap();
    let mut raw = Vec::new();
    s.read_to_end(&mut raw).unwrap();
    String::from_utf8(raw).unwrap().split_once("\r\n\r\n").unwrap().1.to_string()
}
impl Drop for Http {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}
impl Door for Http {
    fn call(&mut self, op: &str, arg: &str) -> Out {
        let a = &self.addr;
        match op {
            "list" => http_req(a, "GET", "/layers", ""),
            "save" => http_req(a, "POST", "/layers", arg),
            "remove" => http_req(a, "DELETE", &format!("/layers/{arg}"), ""),
            "plan" => http_req(a, "POST", "/layers/plan", arg),
            "download" => http_req(a, "POST", "/layers/download", arg),
            "delete" => http_req(a, "POST", "/layers/delete", arg),
            "clear" => http_req(a, "POST", "/layers/clear-cache", "{}"),
            "tile" => http_req(a, "POST", "/layers/tile", arg),
            _ => unreachable!(),
        }
    }
}

struct Direct(Core);
impl Door for Direct {
    fn call(&mut self, op: &str, arg: &str) -> Out {
        let r = match op {
            "list" => self.0.layers_list(),
            "save" => self.0.layers_save(arg),
            "remove" => self.0.layers_remove(arg),
            "plan" => self.0.layers_plan(arg),
            "download" => self.0.layers_download(&serde_json::from_str(arg).unwrap(), &mut |_| {}),
            "delete" => self.0.layers_delete(arg),
            "clear" => self.0.layers_clear_cache(None),
            "tile" => {
                let v: Value = serde_json::from_str(arg).unwrap();
                let (z, x, y) = (v["z"].as_i64().unwrap() as i32, v["x"].as_i64().unwrap() as i32, v["y"].as_i64().unwrap() as i32);
                self.0.layers_tile(v["layer"].as_str().unwrap(), z, x, y).map(|(m, b)| tile_summary(v["layer"].as_str().unwrap(), z, x, y, &m, &b))
            }
            _ => unreachable!(),
        };
        match r {
            Ok(s) => s,
            Err(e) => e.to_json(),
        }
    }
}

/// What differs between two states: when a download finished, how much disk happens to be free, source health.
fn blank_times(s: &str) -> String {
    // source health lives in the memory of one process (the CLI starts a new one per call), so it differs by door
    let mut s = match serde_json::from_str::<Value>(s) {
        Ok(mut v) if v["layers"].is_array() => {
            for l in v["layers"].as_array_mut().unwrap() {
                l.as_object_mut().unwrap().remove("health");
            }
            v.to_string()
        }
        _ => s.to_string(),
    };
    for key in ["\"created\":", "\"free_bytes\":"] {
        let mut out = String::new();
        let mut rest = s.as_str();
        while let Some(i) = rest.find(key) {
            let j = i + key.len();
            out.push_str(&rest[..j]);
            out.push('0');
            rest = rest[j..].trim_start_matches(|c: char| c.is_ascii_digit());
        }
        out.push_str(rest);
        s = out;
    }
    s
}

#[test]
fn layers_are_identical_through_cli_serve_and_the_c_abi() {
    let port = host();
    let (_t1, cfg1, _) = state("cli", port);
    let (_t2, cfg2, _) = state("http", port);
    let (_t3, _, json3) = state("abi", port);
    let mut doors: Vec<(&str, Box<dyn Door>)> = vec![
        ("cli", Box::new(Cli(cfg1))),
        ("serve", Box::new(Http::start(&cfg2))),
        ("c abi", Box::new(Direct(Core::open(&json3).unwrap()))),
    ];
    let bad_def = r#"{"format":1,"id":"Bad Id","title":"x","kind":"vector","transform":"as_is"}"#;
    let my_def = def("mine", port, "Mine").to_string();
    let area = r#"{"layer":"base","area":"a1","name":"Burley","bbox":[-114,42,-113,43],"minzoom":0,"maxzoom":8}"#;
    let steps: Vec<(&str, String)> = vec![
        ("list", String::new()),
        ("save", bad_def.into()),
        ("save", my_def),
        ("list", String::new()),
        ("plan", area.into()),
        ("plan", r#"{"layer":"sat","bbox":[-114,42,-113,43],"minzoom":0,"maxzoom":4}"#.into()),
        ("plan", r#"{"layer":"nope","bbox":[-114,42,-113,43],"minzoom":0,"maxzoom":4}"#.into()),
        ("plan", r#"{"layer":"base","bbox":[-114,42,-113],"minzoom":0,"maxzoom":4}"#.into()),
        ("download", area.into()),
        ("download", r#"{"layer":"sat","bbox":[-114,42,-113,43],"minzoom":0,"maxzoom":4}"#.into()),
        ("list", String::new()),
        ("tile", r#"{"layer":"base","z":6,"x":10,"y":23}"#.into()),
        ("tile", r#"{"layer":"base","z":11,"x":1,"y":1}"#.into()),
        ("tile", r#"{"layer":"nope","z":1,"x":1,"y":1}"#.into()),
        ("tile", r#"{"layer":"base","z":1,"x":5,"y":1}"#.into()),
        ("clear", String::new()),
        ("delete", r#"{"layer":"base","area":"zzz"}"#.into()),
        ("delete", r#"{"layer":"base","area":"a1"}"#.into()),
        ("list", String::new()),
        ("remove", "mine".into()),
        ("remove", "mine".into()),
    ];
    for (i, (op, arg)) in steps.iter().enumerate() {
        let outs: Vec<(String, Out)> = doors.iter_mut().map(|(n, d)| (n.to_string(), blank_times(&d.call(op, arg)))).collect();
        for (n, o) in &outs[1..] {
            assert_eq!(o, &outs[0].1, "step {i} {op} {arg}: {n} differs from {}", outs[0].0);
        }
        let v: Value = serde_json::from_str(&outs[0].1).unwrap_or_else(|e| panic!("step {i} {op}: not JSON ({e}): {}", outs[0].1));
        let layer = |v: &Value, id: &str| v["layers"].as_array().unwrap().iter().find(|l| l["definition"]["id"] == id).cloned().unwrap_or(Value::Null);
        match i {
            0 => {
                assert_eq!(v["layers"].as_array().unwrap().len(), 2);
                assert_eq!(layer(&v, "sat")["definition"]["enabled_by_default"], false);
                assert_eq!(layer(&v, "base")["installed"]["downloaded"], false);
            }
            1 => assert_eq!(v["code"], "bad_json"),
            2 => assert_eq!(v, json!({"id": "mine", "saved": true})),
            3 => assert_eq!(layer(&v, "mine")["origin"], "user"),
            4 => {
                assert_eq!(v["ok_to_start"], true);
                assert!(v["tiles"].as_u64().unwrap() > 5);
            }
            5 => assert_eq!(v["code"], "offline"),
            6 => assert_eq!(v["code"], "not_found"),
            7 => assert_eq!(v["code"], "bad_json"),
            8 => assert_eq!((v["state"].clone(), v["done"].clone() == v["total"].clone()), (json!("done"), true)),
            9 => assert_eq!(v["code"], "offline"),
            10 => {
                let b = layer(&v, "base");
                assert_eq!(b["installed"]["downloaded"], true);
                assert_eq!(b["installed"]["areas"][0]["name"], "Burley");
            }
            11 => assert_eq!(v["empty"], false),
            12 => assert_eq!(v["empty"], true),
            13 => assert_eq!(v["code"], "not_found"),
            14 => assert_eq!(v["code"], "bad_json"),
            16 => assert_eq!(v["code"], "not_found"),
            17 => assert!(v["freed_bytes"].as_u64().unwrap() > 0),
            18 => assert_eq!(layer(&v, "base")["installed"]["downloaded"], false),
            19 => assert_eq!(v, json!({"id": "mine", "removed": true})),
            20 => assert_eq!(v["code"], "not_found"),
            _ => {}
        }
    }
    // a handle with no layers section
    let mut core = Core::open(r#"{"sources":[]}"#).unwrap();
    assert_eq!(core.layers_list().unwrap_err().code, "not_configured");
}

#[test]
fn tile_server_through_the_cli() {
    let port = host();
    let (_t, cfg, _) = state("srv", port);
    let mut child = Command::new(env!("CARGO_BIN_EXE_cs")).args(["layers", "serve", "--config", &cfg]).stdout(Stdio::piped()).stderr(Stdio::inherit()).spawn().unwrap();
    let mut line = String::new();
    BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
    let v: Value = serde_json::from_str(&line).unwrap();
    let addr = format!("127.0.0.1:{}", v["port"]);
    let tj: Value = serde_json::from_str(&http_req(&addr, "GET", "/layers/base/tilejson.json", "")).unwrap();
    assert_eq!(tj["type"], "vector");
    let mut s = TcpStream::connect(&addr).unwrap();
    write!(s, "GET /layers/base/5/3/4 HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n").unwrap();
    let mut raw = Vec::new();
    s.read_to_end(&mut raw).unwrap();
    let text = String::from_utf8_lossy(&raw).to_string();
    assert!(text.starts_with("HTTP/1.1 200"), "{text}");
    assert!(text.ends_with(&String::from_utf8(tile_body(5, 3, 4)).unwrap()));
    let _ = child.kill();
    let _ = child.wait();
}
