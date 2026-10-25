//! Integration tests: spawn the `cs` binary.
//! - ZIM tests run only when CS_TEST_ZIM_DIR and CS_TEST_IDX_DIR are set (they build an index of the small NHS ZIM).
//! - The embedder test runs only when the embedding library and model are mounted (CS_TEST_EMB_DIR, default /emb).

use cache_search_cli::embed::{Embedder, DECIDED_MODEL_FILE, DECIDED_MODEL_SHA256};
use edge::{
    Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, PointInsertOperations, PointOperations, PointStruct, UpdateOperation,
};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|s| !s.is_empty())
}

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-clitest-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }
    fn path(&self, f: &str) -> String {
        self.0.join(f).to_string_lossy().into_owned()
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct Out {
    ok: bool,
    stdout: String,
    stderr: String,
}

fn cs(args: &[&str]) -> Out {
    let o = Command::new(env!("CARGO_BIN_EXE_cs")).args(args).output().expect("run cs");
    Out { ok: o.status.success(), stdout: String::from_utf8(o.stdout).unwrap(), stderr: String::from_utf8(o.stderr).unwrap() }
}

/// Run `cs`, expect success, return stdout without the final newline.
fn cs_ok(args: &[&str]) -> String {
    let o = cs(args);
    assert!(o.ok, "cs {args:?} failed: {}", o.stderr);
    o.stdout.strip_suffix('\n').expect("newline-terminated").to_string()
}

fn j(s: &str) -> Value {
    serde_json::from_str(s).unwrap_or_else(|e| panic!("not JSON ({e}): {s}"))
}

// ---- HTTP -----------------------------------------------------------------------------------------------

struct Serve {
    child: Child,
    addr: String,
}

impl Serve {
    fn start(args: &[&str]) -> Serve {
        let mut child = Command::new(env!("CARGO_BIN_EXE_cs"))
            .arg("serve")
            .args(["--listen", "127.0.0.1:0"])
            .args(args)
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .spawn()
            .expect("spawn cs serve");
        let mut line = String::new();
        BufReader::new(child.stdout.as_mut().unwrap()).read_line(&mut line).expect("listening line");
        let addr = line.trim().strip_prefix("listening ").unwrap_or_else(|| panic!("unexpected first line {line:?}")).to_string();
        Serve { child, addr }
    }

    /// One request; returns (status, body).
    fn req(&self, method: &str, path: &str, body: Option<&Value>) -> (u16, String) {
        let mut s = TcpStream::connect(&self.addr).unwrap();
        let b = body.map(|b| b.to_string()).unwrap_or_default();
        write!(s, "{method} {path} HTTP/1.1\r\nHost: x\r\nConnection: close\r\nContent-Type: application/json\r\nContent-Length: {}\r\n\r\n{b}", b.len()).unwrap();
        let mut raw = Vec::new();
        s.read_to_end(&mut raw).unwrap();
        let text = String::from_utf8(raw).unwrap();
        let (head, body) = text.split_once("\r\n\r\n").expect("http response");
        let status: u16 = head.split_whitespace().nth(1).unwrap().parse().unwrap();
        (status, body.to_string())
    }
}

impl Drop for Serve {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

// ---- ZIM fixture ----------------------------------------------------------------------------------------

struct ZimFx {
    _tmp: TempDir,
    idx: String,
    config: String,
}

impl Drop for ZimFx {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.idx);
    }
}

/// Index the small NHS ZIM with `cs index-zim` into a fresh directory. None when the env is not set.
fn zim_fixture() -> Option<ZimFx> {
    let (zd, id) = (env("CS_TEST_ZIM_DIR")?, env("CS_TEST_IDX_DIR")?);
    let zim = format!("{zd}/nhs.uk_en_medicines_2025-12.zim");
    let idx = format!("{id}/cli-nhs.idx");
    let _ = std::fs::remove_dir_all(&idx);
    let tmp = TempDir::new("zim");
    // the index-zim subcommand: progress on stderr, the final progress JSON on stdout
    let out = cs_ok(&["index-zim", "--zim", &zim, "--index-dir", &idx, "--heap-mb", "100"]);
    let p = j(out.lines().last().unwrap());
    assert_eq!(p["state"], "done", "{p}");
    let config = tmp.path("sources.json");
    std::fs::write(&config, json!({"sources": [{"kind": "zim", "path": zim, "index_dir": idx}]}).to_string()).unwrap();
    Some(ZimFx { _tmp: tmp, idx, config })
}

/// One test, so the index is built once and removed at the end.
#[test]
fn zim_status_search_read_and_serve() {
    let Some(f) = zim_fixture() else {
        eprintln!("CS_TEST_ZIM_DIR / CS_TEST_IDX_DIR not set: skipping");
        return;
    };
    zim_cli(&f);
    serve_matches_the_cli_byte_for_byte(&f);
}

fn zim_cli(f: &ZimFx) {
    let st = j(&cs_ok(&["status", "--config", &f.config]));
    assert_eq!(st["sources"][0]["indexed"], true, "{st}");
    assert_eq!(st["sources"][0]["kind"], "zim");
    assert!(st["sources"][0]["docs"].as_u64().unwrap() > 10);

    let raw = cs_ok(&["search", "--config", &f.config, "--query", "ibuprofen", "--k", "3"]);
    let r = j(&raw);
    let results = r["results"].as_array().unwrap();
    assert_eq!(results.len(), 3, "{raw}");
    assert!(results[0]["address"].as_str().unwrap().starts_with("zim:"));
    assert!(r["keyword_only_sources"].as_array().unwrap().len() == 1);
    assert!(r["vector_sources"].as_array().unwrap().is_empty());
    // --json is the same JSON
    assert_eq!(cs_ok(&["search", "--config", &f.config, "--query", "ibuprofen", "--k", "3", "--json"]), raw);
    // paging goes through to the core
    let p2 = j(&cs_ok(&["search", "--config", &f.config, "--query", "ibuprofen", "--k", "2", "--offset", "1"]));
    assert_eq!(p2["results"][0]["address"], results[1]["address"]);

    // --format: the tool message of a fresh conversation
    let msg = cs_ok(&["search", "--config", &f.config, "--query", "ibuprofen", "--k", "3", "--format"]);
    let lines: Vec<&str> = msg.lines().collect();
    assert_eq!(lines.len(), 3, "{msg}");
    for (i, l) in lines.iter().enumerate() {
        assert!(l.starts_with(&format!("[{}] ", i + 1)), "{l}");
    }
    let full = j(&cs_ok(&["search", "--config", &f.config, "--query", "ibuprofen", "--k", "3", "--format", "--json"]));
    assert_eq!(full["tool_message"], msg.as_str());
    assert_eq!(full["ids"][2]["address"], results[2]["address"]);

    // read
    let addr = results[0]["address"].as_str().unwrap();
    let rd = j(&cs_ok(&["read", "--config", &f.config, "--address", addr, "--max-chars", "800"]));
    assert_eq!(rd["address"], addr);
    assert!(!rd["text"].as_str().unwrap().is_empty());
    assert!(rd["text"].as_str().unwrap().chars().count() <= 800 + 3);

    // errors: stderr JSON, exit 1
    let bad = cs(&["read", "--config", &f.config, "--address", "zim:nope/x"]);
    assert!(!bad.ok);
    assert!(bad.stdout.is_empty());
    let e = j(bad.stderr.trim());
    assert!(e["code"].is_string() && e["message"].is_string(), "{}", bad.stderr);
    let usage = cs(&["search", "--config", &f.config]);
    assert!(!usage.ok && j(usage.stderr.trim())["code"] == "bad_json");
}

fn serve_matches_the_cli_byte_for_byte(f: &ZimFx) {
    // refuses a public bind unless told
    let o = cs(&["serve", "--config", &f.config, "--listen", "0.0.0.0:0"]);
    assert!(!o.ok);
    assert!(o.stderr.contains("loopback"), "{}", o.stderr);

    let s = Serve::start(&["--config", &f.config]);
    let cli = cs_ok(&["search", "--config", &f.config, "--query", "ibuprofen", "--k", "4", "--offset", "1"]);
    let (code, body) = s.req("POST", "/search", Some(&json!({"query": "ibuprofen", "options": {"k": 4, "offset": 1}})));
    assert_eq!(code, 200);
    assert_eq!(body, cli);

    let r = j(&body);
    let addr = r["results"][0]["address"].as_str().unwrap().to_string();
    let cli_read = cs_ok(&["read", "--config", &f.config, "--address", &addr, "--max-chars", "1200"]);
    let (code, body) = s.req("POST", "/read", Some(&json!({"address": addr, "max_chars": 1200})));
    assert_eq!((code, body.as_str()), (200, cli_read.as_str()));

    let cli_status = cs_ok(&["status", "--config", &f.config]);
    let (code, body) = s.req("GET", "/status", None);
    assert_eq!((code, body.as_str()), (200, cli_status.as_str()));

    let (code, body) = s.req("POST", "/suggest", Some(&json!({"prefix": "ibup", "options": {"k": 3}})));
    assert_eq!(code, 200, "{body}");
    assert!(j(&body)["suggestions"].is_array());

    // errors carry the core's code and a matching status
    let (code, body) = s.req("POST", "/read", Some(&json!({"address": "not an address"})));
    assert_eq!((code, j(&body)["code"].as_str().unwrap().to_string()), (400, "bad_json".to_string()), "{body}");
    let (code, _) = s.req("POST", "/search", Some(&json!({"options": {}})));
    assert_eq!(code, 400);
    let (code, body) = s.req("GET", "/nope", None);
    assert_eq!((code, j(&body)["code"].as_str().unwrap().to_string()), (404, "not_found".to_string()));

    // conversation numbering across two calls
    let all = j(&cs_ok(&["search", "--config", &f.config, "--query", "ibuprofen", "--k", "5"]));
    let rs = all["results"].as_array().unwrap();
    assert!(rs.len() >= 4);
    let (code, body) = s.req("POST", "/conversations", None);
    assert_eq!(code, 200);
    let id = j(&body)["id"].as_str().unwrap().to_string();
    let (code, body) = s.req("POST", &format!("/conversations/{id}/format"), Some(&json!({"results": [rs[0], rs[1]]})));
    assert_eq!(code, 200, "{body}");
    let first = j(&body);
    assert!(first["tool_message"].as_str().unwrap().starts_with("[1] "));
    assert_eq!(first["ids"].as_array().unwrap().len(), 2);
    // second call: rs[1] again (keeps [2]) and two new results ([3], [4])
    let (_, body) = s.req("POST", &format!("/conversations/{id}/format"), Some(&json!({"results": [rs[2], rs[1], rs[3]]})));
    let second = j(&body);
    let lines: Vec<&str> = second["tool_message"].as_str().unwrap().lines().collect();
    assert!(lines[0].starts_with("[3] ") && lines[1].starts_with("[2] ") && lines[2].starts_with("[4] "), "{lines:?}");
    let (_, body) = s.req("GET", &format!("/conversations/{id}/ids"), None);
    let ids = j(&body);
    let ns: Vec<u64> = ids["ids"].as_array().unwrap().iter().map(|x| x["n"].as_u64().unwrap()).collect();
    assert_eq!(ns, vec![1, 2, 3, 4]);
    // a second conversation numbers from [1] again
    let (_, body) = s.req("POST", "/conversations", None);
    let id2 = j(&body)["id"].as_str().unwrap().to_string();
    assert_ne!(id, id2);
    let (_, body) = s.req("POST", &format!("/conversations/{id2}/format"), Some(&json!({"results": [rs[3]]})));
    assert!(j(&body)["tool_message"].as_str().unwrap().starts_with("[1] "));
    // delete
    let (code, _) = s.req("DELETE", &format!("/conversations/{id}"), None);
    assert_eq!(code, 200);
    let (code, body) = s.req("GET", &format!("/conversations/{id}/ids"), None);
    assert_eq!((code, j(&body)["code"].as_str().unwrap().to_string()), (404, "not_found".to_string()));
    let (code, _) = s.req("DELETE", &format!("/conversations/{id}"), None);
    assert_eq!(code, 404);
}

// ---- Embedder over a generated library --------------------------------------------------------------------

const POINTS: [(&str, &str); 6] = [
    ("Acupuncture for headaches", "Needling points on the head and hands is used to relieve migraine and tension headaches."),
    ("Rainwater collection", "A barrel under the downspout stores roof runoff that can be filtered and boiled for drinking."),
    ("Setting a broken forearm", "Splint the fractured arm from elbow to wrist with padding and keep the hand raised above the heart."),
    ("Sourdough starter", "Flour and water left to ferment capture wild yeast that makes bread rise."),
    ("Solar panel wiring", "Connecting photovoltaic modules in series raises voltage while parallel strings raise current."),
    ("Frostbite first aid", "Rewarm frozen fingers and toes in warm water and never rub the skin."),
];

#[test]
fn embedder_finds_the_query_point_and_serve_matches() {
    let emb_dir = env("CS_TEST_EMB_DIR").unwrap_or_else(|| "/emb".into());
    let lib = format!("{emb_dir}/build/libcache_llama.so");
    let model = format!("{emb_dir}/models/{DECIDED_MODEL_FILE}");
    if !Path::new(&lib).exists() || !Path::new(&model).exists() {
        eprintln!("{emb_dir} not mounted: skipping");
        return;
    }
    let tmp = TempDir::new("emb");
    let shard = tmp.path("shard");
    {
        // Vectors from the same cl_embed the CLI uses, so a query finds its point.
        let e = Embedder::load(&lib, &model, None, Some(DECIDED_MODEL_SHA256), 4).expect("embedder");
        assert_eq!(e.model_id, DECIDED_MODEL_FILE);
        assert_eq!(e.n_embd, 1024);
        cache_search::library::ensure_init();
        let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(1024, Distance::Cosine).build()).build();
        let sh = EdgeShard::new(Path::new(&shard), cfg).unwrap();
        let pts: Vec<_> = POINTS
            .iter()
            .enumerate()
            .map(|(i, (t, c))| PointStruct::new((i + 1) as u64, e.embed(c).unwrap(), json!({"title": t, "content": c})).0)
            .collect();
        sh.update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(pts)))).unwrap();
        sh.flush().unwrap();
        drop(sh);
        cache_search::library::write_segments_manifest(Path::new(&shard)).unwrap();
    }
    let settings = json!({"format": 1, "library_id": "fx", "title": "Fixture", "fields": {"title": "title", "text": "content"},
        "embedding": {"vector": "", "model": DECIDED_MODEL_FILE, "sha256": DECIDED_MODEL_SHA256, "dims": 1024}, "keyword_index": "off"});
    std::fs::write(tmp.path("cache-library.json"), settings.to_string()).unwrap();
    // settings_file (relative to sources.json) is the CLI convenience for the app's settings object
    let config = tmp.path("sources.json");
    std::fs::write(&config, json!({"sources": [{"kind": "library", "path": shard, "settings_file": "cache-library.json"}]}).to_string()).unwrap();

    let st = j(&cs_ok(&["status", "--config", &config]));
    assert_eq!(st["sources"][0]["opening"], false, "{st}");
    assert_eq!(st["sources"][0]["embedding_model"], DECIDED_MODEL_FILE);
    assert_eq!(st["sources"][0]["docs"], 6);

    let embed = ["--embed-lib", lib.as_str(), "--embed-model", model.as_str(), "--embed-sha256", DECIDED_MODEL_SHA256];
    let mut args: Vec<&str> = vec!["search", "--config", &config, "--query", "how do I treat a migraine with needles", "--k", "3"];
    args.extend(embed);
    let with_vec = cs_ok(&args);
    let r = j(&with_vec);
    assert_eq!(r["vector_sources"], json!(["fx"]), "{with_vec}");
    assert_eq!(r["results"][0]["address"], "lib:fx/1", "{with_vec}");
    assert_eq!(r["results"][0]["title"], "Acupuncture for headaches");

    // the same query with no embedder, and with a model id that is not the library's, is keyword-only
    let plain = j(&cs_ok(&["search", "--config", &config, "--query", "how do I treat a migraine with needles"]));
    assert_eq!(plain["keyword_only_sources"], json!(["fx"]));
    assert!(plain["results"].as_array().unwrap().is_empty());
    let mut args2 = args.clone();
    args2.extend(["--embed-model-id", "other-model"]);
    let other = j(&cs_ok(&args2));
    assert_eq!(other["keyword_only_sources"], json!(["fx"]), "{other}");
    assert!(other["vector_sources"].as_array().unwrap().is_empty());

    // a wrong sha256 stops the run
    let bad = cs(&["search", "--config", &config, "--query", "x", "--embed-lib", &lib, "--embed-model", &model, "--embed-sha256", "00"]);
    assert!(!bad.ok && bad.stderr.contains("sha256"), "{}", bad.stderr);
    let half = cs(&["search", "--config", &config, "--query", "x", "--embed-lib", &lib]);
    assert!(!half.ok && half.stderr.contains("go together"), "{}", half.stderr);

    // --format on a library hit
    let mut args3 = args.clone();
    args3.push("--format");
    let msg = cs_ok(&args3);
    assert!(msg.starts_with("[1] Acupuncture for headaches"), "{msg}");

    // read
    let rd = j(&cs_ok(&["read", "--config", &config, "--address", "lib:fx/3"]));
    assert_eq!(rd["title"], "Setting a broken forearm");
    assert!(rd["text"].as_str().unwrap().contains("Splint"));

    // serve with the embedder: the server embeds the query itself and answers exactly as the CLI does
    let mut sargs: Vec<&str> = vec!["--config", &config];
    sargs.extend(embed);
    let s = Serve::start(&sargs);
    let (code, body) = s.req("POST", "/search", Some(&json!({"query": "how do I treat a migraine with needles", "options": {"k": 3, "offset": 0}})));
    assert_eq!(code, 200, "{body}");
    assert_eq!(body, with_vec);
    // an explicit query_vector in the request is passed through, not replaced
    let (_, body) = s.req("POST", "/search", Some(&json!({"query": "zzz", "options": {"k": 1, "query_vector": {"model": "other-model", "vector": [0.0]}}})));
    assert_eq!(j(&body)["keyword_only_sources"], json!(["fx"]), "{body}");
    let (code, body) = s.req("POST", "/read", Some(&json!({"address": "lib:fx/3", "max_chars": 6000})));
    assert_eq!(code, 200);
    assert_eq!(body, cs_ok(&["read", "--config", &config, "--address", "lib:fx/3"]));
}
