//! `cs serve --layers` and `--repeaters`: the files are imported at start through the same import as the app's, and the tools
//! answer as on a handle that imported them through the C ABI.

use cache_places::fixture::{write_fixture_pack, FIXTURE_NOW};
use cache_search_cli::engine::{Conv, Core};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

struct Tmp(PathBuf);
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn fixture(f: &str) -> String {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../native/cache_user/tests/fixtures").join(f).to_string_lossy().into_owned()
}

struct Http {
    child: Child,
    addr: String,
}
impl Http {
    fn start(args: &[String]) -> Http {
        let mut child = Command::new(env!("CARGO_BIN_EXE_cs")).arg("serve").args(args).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().unwrap();
        let mut line = String::new();
        BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).unwrap();
        let addr = line.trim().strip_prefix("listening ").unwrap_or_else(|| panic!("{line}")).to_string();
        Http { child, addr }
    }
    fn req(&self, method: &str, path: &str, body: &str) -> String {
        let mut s = TcpStream::connect(&self.addr).unwrap();
        write!(s, "{method} {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{body}", body.len()).unwrap();
        let mut raw = Vec::new();
        s.read_to_end(&mut raw).unwrap();
        String::from_utf8(raw).unwrap().split_once("\r\n\r\n").unwrap().1.to_string()
    }
    fn tool(&self, name: &str, args: Value) -> String {
        let id = serde_json::from_str::<Value>(&self.req("POST", "/conversations", "")).unwrap()["id"].as_str().unwrap().to_string();
        self.req("POST", &format!("/conversations/{id}/tool"), &json!({"name": name, "args": args, "now": FIXTURE_NOW}).to_string())
    }
}
impl Drop for Http {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

fn setup(t: &Tmp, db: &str) -> (Value, String) {
    let pack = t.0.join("places.sqlite");
    write_fixture_pack(&pack);
    let cfg = json!({"sources": [], "places": {"packs": [pack]}, "user": {"db_path": t.0.join(db)}});
    let path = t.0.join(format!("{db}.json"));
    std::fs::write(&path, cfg.to_string()).unwrap();
    (cfg, path.to_string_lossy().into_owned())
}

#[test]
fn serve_imports_layers_and_repeaters_at_start() {
    let t = Tmp(std::env::temp_dir().join(format!("cs-userlayers-{}", std::process::id())));
    let _ = std::fs::remove_dir_all(&t.0);
    std::fs::create_dir_all(&t.0).unwrap();
    let (_, serve_cfg) = setup(&t, "serve.sqlite");
    let args: Vec<String> = [
        "--listen", "127.0.0.1:0", "--config", &serve_cfg,
        "--layers", &fixture("rally-points.geojson"), "--layers", &fixture("elk-camp.kml"),
        "--repeaters", &fixture("repeaters-fixture.kml"), "--repeaters", &fixture("repeaters-fixture.csv"),
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    // started twice: the second start replaces the first one's imports
    drop(Http::start(&args));
    let http = Http::start(&args);

    let (cfg, _) = setup(&t, "direct.sqlite");
    let mut core = Core::open(&cfg.to_string()).unwrap();
    for f in ["rally-points.geojson", "elk-camp.kml"] {
        core.userlayers_import(&json!({"kind": "layer", "paths": [fixture(f)]}).to_string()).unwrap();
    }
    core.userlayers_import(&json!({"kind": "repeaters", "paths": [fixture("repeaters-fixture.kml"), fixture("repeaters-fixture.csv")]}).to_string()).unwrap();
    let lists: Value = serde_json::from_str(&core.userlayers_list().unwrap()).unwrap();
    assert_eq!((lists["layers"].as_array().unwrap().len(), lists["repeater_lists"].as_array().unwrap().len()), (2, 1));

    assert_eq!(http.req("GET", "/tools", ""), core.tool_schemas().unwrap());
    core.set_location(42.5357, -113.7928, 12.0, FIXTURE_NOW).unwrap();
    http.req("POST", "/location", &json!({"lat": 42.5357, "lon": -113.7928, "accuracy_m": 12, "fixed_at": FIXTURE_NOW}).to_string());
    for (name, a) in [
        ("nearby", json!({"category": "repeater", "limit": 2})),
        ("nearby", json!({"category": "layer_rally_points"})),
        ("locate", json!({"place": "North gate"})),
    ] {
        let direct = Conv::new().and_then(|mut c| core.tool(&mut c, name, &a.to_string(), FIXTURE_NOW)).unwrap();
        let served = http.tool(name, a.clone());
        assert_eq!(served, direct, "{name} {a}");
        let v: Value = serde_json::from_str(&served).unwrap();
        assert!(v["content"].as_str().unwrap().contains("\"ok\":true"), "{v}");
    }
    let v: Value = serde_json::from_str(&http.tool("locate", json!({"place": "North gate"}))).unwrap();
    assert!(v["content"].as_str().unwrap().contains("\"kind_label\":\"Elk Camp\""), "{v}");
}
