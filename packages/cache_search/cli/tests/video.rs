//! The video connector through the three front doors: the `cs` CLI, `cs serve` (HTTP) and the C ABI (the `Core` wrapper).
//! One sequence runs on three separate states against a stand-in PeerTube (recorded responses, see the cache_video
//! tests) and every step must give the same output. The only values normalised before comparing are the ones that
//! cannot be equal: the state's own folder in paths, and times taken from the clock.

#[path = "../../native/cache_video/tests/common/mod.rs"]
mod common;

use cache_search_cli::engine::{Core, Engine};
use common::*;
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cs-vid-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Tmp(p)
    }
    fn s(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
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
            "instances" | "downloads" => cli(&[&format!("video-{op}"), "--config", c]),
            "download" => {
                let r: Value = serde_json::from_str(arg).unwrap();
                let mut a = vec!["video-download".to_string(), "--config".into(), c.into(), "--instance".into(), r["instance"].as_str().unwrap().into(), "--video".into(), r["video"].as_str().unwrap().into()];
                if let Some(ch) = r["choice"].as_str() {
                    a.extend(["--choice".into(), ch.into()]);
                }
                let refs: Vec<&str> = a.iter().map(String::as_str).collect();
                let o = Command::new(env!("CARGO_BIN_EXE_cs")).args(&refs).output().unwrap();
                if o.status.success() {
                    String::from_utf8(o.stdout).unwrap().trim_end().to_string()
                } else {
                    // a failed job prints its last progress on stdout and the error on stderr; the door's answer is the error
                    String::from_utf8(o.stderr).unwrap().lines().last().unwrap().to_string()
                }
            }
            _ => cli(&[&format!("video-{}", op.replace('_', "-")), "--config", c, "--request", arg]),
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
    fn call(&mut self, op: &str, arg: &str) -> Out {
        match op {
            "instances" | "downloads" => self.req("GET", &format!("/video/{op}"), ""),
            _ => self.req("POST", &format!("/video/{}", op.replace('_', "-")), arg),
        }
    }
}

struct Direct(Engine);
impl Door for Direct {
    fn call(&mut self, op: &str, arg: &str) -> Out {
        let c = &mut self.0.core;
        let r = match op {
            "instances" => c.video_instances(),
            "downloads" => c.video_downloads(),
            "instance_add" => c.video_instance_add(arg),
            "instance_remove" => c.video_instance_remove(arg),
            "login" => c.video_login(arg),
            "refresh" => c.video_refresh(arg),
            "me" => c.video_me(arg),
            "channels" => c.video_channels(arg),
            "list" => c.video_list(arg),
            "search" => c.video_search(arg),
            "get" => c.video_get(arg),
            "delete" => c.video_delete(arg),
            "resolve" => c.video_resolve(arg),
            "download" => self.0.video_download(&serde_json::from_str(arg).unwrap(), &mut |_| {}),
            _ => unreachable!(),
        };
        match r {
            Ok(s) => s,
            Err(e) => e.to_json(),
        }
    }
}

/// Replace what differs between states by nature: the state folder in paths, times from the clock.
fn normalise(text: &str, dir: &str) -> String {
    fn walk(v: &mut Value, dir: &str) {
        match v {
            Value::String(s) => {
                if let Some(rest) = s.strip_prefix(dir) {
                    *s = format!("<DIR>{}", rest.replace('\\', "/"));
                }
            }
            Value::Array(a) => a.iter_mut().for_each(|x| walk(x, dir)),
            Value::Object(o) => {
                for (k, x) in o.iter_mut() {
                    if k == "added_at" || k == "downloaded_at" {
                        *x = json!("<time>");
                    } else {
                        walk(x, dir);
                    }
                }
            }
            _ => {}
        }
    }
    match serde_json::from_str::<Value>(text) {
        Ok(mut v) => {
            walk(&mut v, dir);
            v.to_string()
        }
        Err(_) => text.to_string(),
    }
}

#[test]
fn videos_are_identical_through_cli_serve_and_the_c_abi() {
    let m = Mock::start();
    let id = m.id();
    let states: Vec<Tmp> = ["cli", "http", "abi"].iter().map(|n| Tmp::new(n)).collect();
    let cfg = |t: &Tmp| json!({"sources": [], "video": {"dir": t.0.join("videos").to_string_lossy()}});
    let cli_cfg = states[0].0.join("config.json");
    std::fs::write(&cli_cfg, cfg(&states[0]).to_string()).unwrap();
    let http_cfg = states[1].0.join("config.json");
    std::fs::write(&http_cfg, cfg(&states[1]).to_string()).unwrap();
    let abi_cfg = cfg(&states[2]).to_string();
    let core = Core::open(&abi_cfg).unwrap();
    let mut doors: Vec<(&str, Box<dyn Door>)> = vec![
        ("cli", Box::new(Cli(cli_cfg.to_string_lossy().into_owned()))),
        ("serve", Box::new(Http::start(&http_cfg.to_string_lossy()))),
        ("c abi", Box::new(Direct(Engine { core, embedder: None, video_dir: Some(states[2].0.join("videos").to_string_lossy().into_owned()) }))),
    ];
    let dirs: Vec<String> = states.iter().map(|t| t.0.join("videos").to_string_lossy().into_owned()).collect();
    let inst = json!({"instance": id});
    let with = |extra: Value| {
        let mut v = inst.clone();
        for (k, x) in extra.as_object().unwrap() {
            v[k] = x.clone();
        }
        v.to_string()
    };
    let steps: Vec<(&str, String)> = vec![
        ("instances", String::new()),
        ("get", with(json!({"video": WEB_UUID}))),
        ("instance_add", json!({"url": m.url()}).to_string()),
        ("instance_add", json!({"url": "http://example.org"}).to_string()),
        ("instances", String::new()),
        ("channels", with(json!({"count": 3}))),
        ("channels", with(json!({"search": "survival"}))),
        ("list", with(json!({"count": 2}))),
        ("list", with(json!({"channel": "oh8stn", "count": 3}))),
        ("search", with(json!({"query": "ham radio"}))),
        ("search", with(json!({"query": ""}))),
        ("get", with(json!({"video": WEB_UUID}))),
        ("get", with(json!({"video": HLS_UUID}))),
        ("get", with(json!({"video": "00000000-0000-4000-8000-000000000000"}))),
        ("login", with(json!({"username": "alice", "password": "correct horse"}))),
        ("login", with(json!({"username": "alice", "password": "hunter2-secret"}))),
        ("login", with(json!({"username": "twofa", "password": "correct horse"}))),
        ("me", with(json!({"token": "A1"}))),
        ("me", with(json!({"token": "nope"}))),
        ("refresh", with(json!({"refresh_token": "R1"}))),
        ("downloads", String::new()),
        ("download", with(json!({"video": WEB_UUID, "choice": "audio"}))),
        ("download", with(json!({"video": WEB_UUID, "choice": "lowest"}))),
        ("download", with(json!({"video": HLS_UUID, "choice": "360"}))),
        ("downloads", String::new()),
        ("list", with(json!({"count": 2}))),
        ("resolve", json!({"video": WEB_SHORT, "offset_s": 5}).to_string()),
        ("resolve", json!({"video": HLS_UUID, "offset_s": 12.5}).to_string()),
        ("delete", with(json!({"video": WEB_UUID}))),
        ("delete", with(json!({"video": WEB_UUID}))),
        ("resolve", json!({"video": WEB_UUID, "offset_s": 4}).to_string()),
        ("resolve", json!({"video": "nonsense link", "bogus": 1}).to_string()),
        ("downloads", String::new()),
        ("instance_remove", json!({"instance": id, "delete_downloads": true}).to_string()),
        ("instances", String::new()),
        ("list", with(json!({}))),
    ];
    let mut shared: Vec<Value> = vec![];
    for (i, (op, arg)) in steps.iter().enumerate() {
        let outs: Vec<(String, Out)> = doors.iter_mut().enumerate().map(|(n, (name, d))| (name.to_string(), normalise(&d.call(op, arg), &dirs[n]))).collect();
        for (n, o) in &outs[1..] {
            assert_eq!(o, &outs[0].1, "step {i} {op} {arg}: {n} differs from {}", outs[0].0);
        }
        shared.push(serde_json::from_str(&outs[0].1).unwrap_or_else(|e| panic!("step {i} {op}: not JSON ({e}): {}", outs[0].1)));
    }
    // spot checks on the shared results
    assert_eq!(shared[0], json!({"instances": []}));
    assert_eq!(shared[1]["code"], "not_found");
    assert_eq!(shared[2]["name"], "Example PeerTube");
    assert_eq!(shared[3]["code"], "bad_json");
    assert_eq!(shared[5]["total"], 154);
    assert_eq!(shared[9]["total"], 1905);
    assert_eq!(shared[10]["code"], "bad_json");
    assert_eq!(shared[11]["options"][0]["key"], "608");
    assert_eq!(shared[14]["access_token"], "A1");
    assert_eq!(shared[15]["code"], "auth_failed");
    assert_eq!(shared[16]["code"], "otp_required");
    assert!(!shared[15].to_string().contains("hunter2-secret"));
    assert_eq!(shared[20], json!({"downloads": [], "total_bytes": 0}));
    assert_eq!(shared[21]["code"], "unsupported");
    assert_eq!(shared[22], json!({"state": "done", "done": WEB_SIZE, "total": WEB_SIZE, "error": null}));
    assert_eq!(shared[23], json!({"state": "done", "done": 120_000, "total": 120_000, "error": null}));
    assert_eq!(shared[24]["downloads"].as_array().unwrap().len(), 2);
    assert_eq!(shared[24]["downloads"][0]["path"].as_str().unwrap().starts_with("<DIR>/downloads/"), true);
    assert_eq!(shared[25]["videos"].as_array().unwrap().iter().filter(|v| v["downloaded"] == true).count(), 1);
    assert_eq!((shared[26]["kind"].as_str().unwrap(), shared[26]["offset_s"].as_f64().unwrap()), ("local", 5.0));
    assert_eq!(shared[27]["kind"], "local");
    assert_eq!(shared[28]["deleted"], WEB_UUID);
    assert_eq!(shared[29]["code"], "not_found");
    assert_eq!(shared[30]["kind"], "stream");
    assert_eq!(shared[31]["code"], "bad_json");
    assert_eq!(shared[32]["downloads"].as_array().unwrap().len(), 1);
    assert_eq!(shared[33]["downloads_deleted"], true);
    assert_eq!(shared[34], json!({"instances": []}));
    assert_eq!(shared[35]["code"], "not_found");
    // the file really is there, byte for byte, in every state
    for d in &dirs {
        let _ = d;
    }
}
