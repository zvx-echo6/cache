//! Integration tests: spawn the `cs` binary.
//! - ZIM tests run only when CS_TEST_ZIM_DIR and CS_TEST_IDX_DIR are set (they build an index of the small NHS ZIM).
//! - The embedder test runs only when the embedding library and model are mounted (CS_TEST_EMB_DIR, default /emb).

use cache_search_cli::embed::{Embedder, DECIDED_MODEL_FILE, DECIDED_MODEL_SHA256};
use edge::{
    CreateIndex, Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, FieldIndexOperations, PayloadFieldSchema, PayloadSchemaParams,
    PointInsertOperations, PointOperations, PointStruct, TextIndexParams, TextScoringParams, UpdateOperation,
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

// ---- library-manifest and update-library ---------------------------------------------------------------------

#[test]
fn library_manifest_and_update_library_commands() {
    let tmp = TempDir::new("upd");
    let shard = tmp.path("shard");
    {
        cache_search::library::ensure_init();
        let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(4, Distance::Cosine).build()).build();
        let sh = EdgeShard::new(Path::new(&shard), cfg).unwrap();
        let pts: Vec<_> = (1..=20u64)
            .map(|i| PointStruct::new(i, vec![1.0, i as f32, 0.5, 0.25], json!({"title": format!("T{i}"), "content": format!("text {i}")})).0)
            .collect();
        sh.update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(pts)))).unwrap();
        sh.flush().unwrap();
    }
    let seg_dirs = |d: &str| -> Vec<String> {
        let mut v: Vec<String> =
            std::fs::read_dir(format!("{d}/segments")).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
        v.sort();
        v
    };
    // to stdout: the manifest JSON, keyed by segment id
    let m = j(&cs_ok(&["library-manifest", "--library", &shard]));
    let mut keys: Vec<String> = m.as_object().unwrap().keys().cloned().collect();
    keys.sort();
    assert_eq!(keys, seg_dirs(&shard));
    for (_, seg) in m.as_object().unwrap() {
        assert!(seg["segment_version"].is_number() && seg["file_versions"].is_object(), "{seg}");
    }
    // the library manifest function also leaves segments_manifest.json in step with the folders
    let sm = j(&std::fs::read_to_string(format!("{shard}/segments_manifest.json")).unwrap());
    let mut listed: Vec<String> = sm.as_object().unwrap().keys().cloned().collect();
    listed.sort();
    assert_eq!(listed, seg_dirs(&shard));
    // to a file
    let out = tmp.path("m.json");
    let r = j(&cs_ok(&["library-manifest", "--library", &shard, "--out", &out]));
    assert_eq!(r["segments"], keys.len());
    assert_eq!(j(&std::fs::read_to_string(&out).unwrap()), m);
    // errors
    let o = cs(&["library-manifest", "--library", "/nonexistent/shard"]);
    assert!(!o.ok);
    assert_eq!(j(o.stderr.trim())["code"], "not_found");

    // update-library: a missing snapshot, then a corrupt one; the library is untouched by both
    let o = cs(&["update-library", "--library", &shard, "--snapshot", "/nonexistent/s.snapshot", "--manifest", &out]);
    assert!(!o.ok);
    assert_eq!(j(o.stderr.trim())["code"], "not_found", "{}", o.stderr);
    let bad = tmp.path("bad.snapshot");
    std::fs::write(&bad, vec![9u8; 2048]).unwrap();
    let o = cs(&["update-library", "--library", &shard, "--snapshot", &bad, "--manifest", &out]);
    assert!(!o.ok);
    let last = o.stderr.lines().last().unwrap();
    assert_eq!(j(last)["code"], "io", "{}", o.stderr);
    assert!(o.stderr.contains("failed"), "progress lines go to stderr: {}", o.stderr);
    assert_eq!(j(o.stdout.trim())["state"], "failed");
    assert_eq!(seg_dirs(&shard), keys);
    // and the library still opens
    let config = tmp.path("sources.json");
    std::fs::write(&config, json!({"sources": [{"kind": "library", "path": shard}]}).to_string()).unwrap();
    let st = j(&cs_ok(&["status", "--config", &config]));
    assert_eq!(st["sources"][0]["docs"], 20, "{st}");
    assert_eq!(st["sources"][0]["updating"], false);
}

// ---- tools -------------------------------------------------------------------------------------------------------

const NOW: &str = "2026-10-25T14:20:05-06:00";

/// A small library with a BM25-scored text index of its own (keyword search needs no index job); returns the
/// path of its sources.json.
fn tool_fixture(tmp: &TempDir) -> String {
    let shard = tmp.path("shard");
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
    let config = tmp.path("sources.json");
    std::fs::write(&config, json!({"sources": [{"kind": "library", "path": shard, "settings": settings}]}).to_string()).unwrap();
    config
}

#[test]
fn tool_command_search_schemas_and_errors() {
    let tmp = TempDir::new("tool");
    let config = tool_fixture(&tmp);

    // the tool message, then the ids line
    let out = cs_ok(&["tool", "search", "--config", &config, "--args", r#"{"query":"sesquipedalian"}"#, "--now", NOW]);
    assert_eq!(out.lines().count(), 2, "{out}");
    assert!(out.starts_with("[1] Doc 3 \u{2014} "), "{out}");
    assert_eq!(out.lines().nth(1).unwrap(), r#"ids [{"n":1,"address":"lib:fx/3","title":"Doc 3"}]"#);
    // --json is the core's {"content","ids"}
    let full = j(&cs_ok(&["tool", "search", "--config", &config, "--args", r#"{"query":"sesquipedalian"}"#, "--now", NOW, "--json"]));
    assert_eq!(full["content"], out.lines().next().unwrap());
    assert_eq!(full["ids"][0]["address"], "lib:fx/3");
    // no --now: the current local time is used
    assert!(cs_ok(&["tool", "search", "--config", &config, "--args", r#"{"query":"sesquipedalian"}"#]).starts_with("[1] Doc 3"));
    // nothing found
    assert!(cs_ok(&["tool", "search", "--config", &config, "--args", r#"{"query":"qqqqzzzz"}"#]).starts_with("No results found.\nids []"));

    // a tool's failure is its content, with exit status 0
    let bad = cs_ok(&["tool", "search", "--config", &config, "--args", r#"{"query":""}"#, "--json"]);
    assert_eq!(
        j(&bad)["content"],
        r#"{"ok":false,"error":{"type":"bad_arguments","detail":"query: must be at least 1 characters"}}"#
    );
    let none = j(&cs_ok(&["tool", "navigate", "--config", &config, "--json"]));
    assert_eq!(none["content"], r#"{"ok":false,"error":{"type":"bad_arguments","detail":"no tool named navigate"}}"#);
    // a fresh conversation has no result to read
    let rd = j(&cs_ok(&["tool", "read", "--config", &config, "--args", r#"{"n":1}"#, "--json"]));
    assert!(rd["content"].as_str().unwrap().contains("not_found"));
    // --lat/--lon are accepted; one alone, or malformed args, are errors
    cs_ok(&["tool", "search", "--config", &config, "--args", r#"{"query":"alpha"}"#, "--lat", "42.5", "--lon", "-113.7", "--accuracy", "10"]);
    assert!(!cs(&["tool", "search", "--config", &config, "--lat", "42.5"]).ok);
    let o = cs(&["tool", "search", "--config", &config, "--args", "{"]);
    assert!(!o.ok);
    assert_eq!(j(o.stderr.trim())["code"], "bad_json");
    let o = cs(&["tool", "--config", &config]);
    assert!(!o.ok && j(o.stderr.trim())["code"] == "bad_json", "{}", o.stderr);

    // tool-schemas: with and without a config
    for args in [vec!["tool-schemas", "--config", config.as_str()], vec!["tool-schemas"]] {
        let s = j(&cs_ok(&args));
        let names: Vec<&str> = s.as_array().unwrap().iter().map(|x| x["function"]["name"].as_str().unwrap()).collect();
        assert_eq!(names, ["search", "read"]);
    }
}

#[test]
fn serve_tool_endpoints() {
    let tmp = TempDir::new("servetool");
    let config = tool_fixture(&tmp);
    let s = Serve::start(&["--config", &config]);

    // GET /tools is cs tool-schemas
    let (code, body) = s.req("GET", "/tools", None);
    assert_eq!(code, 200);
    assert_eq!(body, cs_ok(&["tool-schemas"]));

    // a conversation: search numbers [1], read opens it
    let (_, b) = s.req("POST", "/conversations", None);
    let id = j(&b)["id"].as_str().unwrap().to_string();
    let path = format!("/conversations/{id}/tool");
    let (code, body) = s.req("POST", &path, Some(&json!({"name": "search", "args": {"query": "sesquipedalian"}, "now": NOW})));
    assert_eq!(code, 200, "{body}");
    let v = j(&body);
    assert_eq!(v.as_object().unwrap().keys().collect::<Vec<_>>(), ["content", "ids"]);
    assert!(v["content"].as_str().unwrap().starts_with("[1] Doc 3 \u{2014} "), "{body}");
    assert_eq!(v["ids"][0]["address"], "lib:fx/3");
    let (code, body) = s.req("POST", &path, Some(&json!({"name": "read", "args": {"n": 1}, "now": NOW})));
    assert_eq!((code, j(&body)["content"].as_str().unwrap()), (200, "[1] Doc 3\nThe sesquipedalian word appears once"));
    // the same call through the CLI gives the same bytes (fresh conversation, same search)
    let (_, body) = s.req("POST", "/conversations", None);
    let id2 = j(&body)["id"].as_str().unwrap().to_string();
    let (_, body) = s.req("POST", &format!("/conversations/{id2}/tool"), Some(&json!({"name": "search", "args": {"query": "sesquipedalian"}, "now": NOW})));
    assert_eq!(body, cs_ok(&["tool", "search", "--config", &config, "--args", r#"{"query":"sesquipedalian"}"#, "--now", NOW, "--json"]));

    // a tool's failure is a 200 with the error as content; a missing now, or an unknown conversation, are errors
    let (code, body) = s.req("POST", &path, Some(&json!({"name": "nope", "now": NOW})));
    assert_eq!(code, 200);
    assert!(j(&body)["content"].as_str().unwrap().contains("no tool named nope"));
    let (code, body) = s.req("POST", &path, Some(&json!({"name": "search", "args": {"query": "x"}})));
    assert_eq!((code, j(&body)["code"].as_str().unwrap().to_string()), (400, "bad_json".to_string()), "{body}");
    let (code, _) = s.req("POST", &path, Some(&json!({"args": {}, "now": NOW})));
    assert_eq!(code, 400);
    let (code, _) = s.req("POST", "/conversations/zzz/tool", Some(&json!({"name": "search", "args": {"query": "x"}, "now": NOW})));
    assert_eq!(code, 404);

    // location: set, clear, and a value out of range
    let (code, body) = s.req("POST", "/location", Some(&json!({"lat": 42.5, "lon": -113.7, "accuracy_m": 12.0, "fixed_at": NOW})));
    assert_eq!((code, body.as_str()), (200, r#"{"ok":true}"#));
    let (code, _) = s.req("POST", "/location", Some(&json!({"lat": 42.5, "lon": -113.7, "fixed_at": NOW})));
    assert_eq!(code, 200, "accuracy_m is optional");
    let (code, body) = s.req("POST", "/location", Some(&json!({"lat": 95.0, "lon": 0.0, "fixed_at": NOW})));
    assert_eq!((code, j(&body)["code"].as_str().unwrap().to_string()), (400, "bad_json".to_string()), "{body}");
    let (code, _) = s.req("POST", "/location", Some(&json!({"lat": 1.0, "fixed_at": NOW})));
    assert_eq!(code, 400);
    let (code, body) = s.req("DELETE", "/location", None);
    assert_eq!((code, body.as_str()), (200, r#"{"ok":true}"#));
}

// ---- web search ------------------------------------------------------------------------------------------------

const WEB_KEY: &str = "CLI-TESTKEY-31337-do-not-leak";

/// `cs` with extra environment variables.
fn cs_env(args: &[&str], env: &[(&str, &str)]) -> Out {
    let o = Command::new(env!("CARGO_BIN_EXE_cs"))
        .args(args)
        .env_remove("CACHE_WEB_PROVIDER")
        .env_remove("CACHE_WEB_KEY")
        .env_remove("CACHE_WEB_BASE_URL")
        .envs(env.iter().copied())
        .output()
        .expect("run cs");
    Out { ok: o.status.success(), stdout: String::from_utf8(o.stdout).unwrap(), stderr: String::from_utf8(o.stderr).unwrap() }
}

/// A one-answer HTTP server standing in for Kagi's v1 API (no real network is touched). Returns its base address. It
/// insists on a POST to /api/v1/search with `Authorization: Bearer <WEB_KEY>` and a JSON body with `query` and `limit`
/// (a wrong header gets 401, anything else wrong gets 400), and records the Authorization header of each request. A
/// query of "nosnippet" gets a result with no snippet.
fn stand_in_kagi(seen: std::sync::Arc<std::sync::Mutex<Vec<String>>>) -> String {
    let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let base = format!("http://{}/api/v1/search", l.local_addr().unwrap());
    std::thread::spawn(move || {
        for mut s in l.incoming().flatten() {
            let mut raw: Vec<u8> = Vec::new();
            let mut buf = vec![0u8; 4096];
            let mut head_end = None;
            while head_end.is_none() {
                match s.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => raw.extend_from_slice(&buf[..n]),
                }
                head_end = raw.windows(4).position(|w| w == b"\r\n\r\n").map(|p| p + 4);
            }
            let Some(head_end) = head_end else { continue };
            let head = String::from_utf8_lossy(&raw[..head_end]).to_string();
            let header = |name: &str| -> String {
                head.lines()
                    .find(|l| l.to_ascii_lowercase().starts_with(&format!("{name}:")))
                    .unwrap_or("")
                    .to_string()
            };
            let want: usize = header("content-length").split_once(':').and_then(|(_, v)| v.trim().parse().ok()).unwrap_or(0);
            let mut body = raw[head_end..].to_vec();
            while body.len() < want {
                match s.read(&mut buf) {
                    Ok(0) | Err(_) => break,
                    Ok(n) => body.extend_from_slice(&buf[..n]),
                }
            }
            let auth = header("authorization");
            seen.lock().unwrap().push(auth.clone());
            let first = head.lines().next().unwrap_or("");
            let parsed: Option<Value> = serde_json::from_slice(&body).ok();
            let (status, out) = if auth.split_once(':').map(|(_, v)| v.trim()) != Some(format!("Bearer {WEB_KEY}").as_str()) {
                (401, r#"{"error":[{"code":401,"msg":"unauthorized"}]}"#.to_string())
            } else if !first.starts_with("POST /api/v1/search ")
                || !parsed.as_ref().is_some_and(|b| b["query"].is_string() && b["limit"].is_u64())
            {
                (400, r#"{"error":[{"code":400,"msg":"bad request"}]}"#.to_string())
            } else if parsed.as_ref().unwrap()["query"] == "nosnippet" {
                (200, json!({"data": {"search": [{"url": "https://n.example/1", "title": "Bare"}]}}).to_string())
            } else {
                let r = json!({"meta": {}, "data": {"search": [
                    {"url": "https://a.example/1", "title": "Burn ban lifted", "snippet": "Ended on Friday.", "rank": 1}],
                    "related_searches": ["x"]}});
                (200, r.to_string())
            };
            let _ = write!(s, "HTTP/1.1 {status} X\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{out}", out.len());
        }
    });
    base
}

#[test]
fn web_search_through_the_cli_needs_the_environment() {
    // without the variables: not in the schemas, and a call is not_set_up
    let names = |o: &Out| -> Vec<String> {
        j(o.stdout.trim()).as_array().unwrap().iter().map(|x| x["function"]["name"].as_str().unwrap().to_string()).collect()
    };
    assert_eq!(names(&cs_env(&["tool-schemas"], &[])), ["search", "read"]);
    assert_eq!(names(&cs_env(&["tool-schemas"], &[("CACHE_WEB_PROVIDER", "kagi")])), ["search", "read"]);
    assert_eq!(names(&cs_env(&["tool-schemas"], &[("CACHE_WEB_KEY", WEB_KEY)])), ["search", "read"]);
    let o = cs_env(&["tool", "web_search", "--config", &empty_config(), "--args", r#"{"query":"x"}"#, "--json"], &[]);
    assert!(o.ok, "{}", o.stderr);
    assert_eq!(j(o.stdout.trim())["content"], r#"{"ok":false,"error":{"type":"not_set_up","detail":"web_search is not set up"}}"#);
    // both set: offered
    let both = [("CACHE_WEB_PROVIDER", "kagi"), ("CACHE_WEB_KEY", WEB_KEY)];
    assert_eq!(names(&cs_env(&["tool-schemas"], &both)), ["search", "read", "web_search"]);
    // an unknown provider is refused at start
    let o = cs_env(&["tool-schemas"], &[("CACHE_WEB_PROVIDER", "bing"), ("CACHE_WEB_KEY", WEB_KEY)]);
    assert!(!o.ok && j(o.stderr.trim())["code"] == "bad_json", "{}", o.stderr);
    assert!(!o.stderr.contains(WEB_KEY) && !o.stdout.contains(WEB_KEY));
}

fn empty_config() -> String {
    let p = std::env::temp_dir().join(format!("cs-clitest-web-{}.json", std::process::id()));
    std::fs::write(&p, r#"{"sources":[]}"#).unwrap();
    p.to_string_lossy().into_owned()
}

#[test]
fn cs_tool_web_search_against_a_stand_in_server() {
    let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
    let base = stand_in_kagi(seen.clone());
    let cfg = empty_config();
    let env = [("CACHE_WEB_PROVIDER", "kagi"), ("CACHE_WEB_KEY", WEB_KEY), ("CACHE_WEB_BASE_URL", base.as_str())];
    let args = ["tool", "web_search", "--config", cfg.as_str(), "--args", r#"{"query":"burn ban"}"#, "--now", NOW];
    let o = cs_env(&args, &env);
    assert!(o.ok, "{}", o.stderr);
    let lines: Vec<&str> = o.stdout.lines().collect();
    assert_eq!(lines[0], "[1] Burn ban lifted (web, fetched 2026-10-25 14:20) \u{2014} Ended on Friday.");
    assert_eq!(lines[1], r#"ids [{"n":1,"address":"web:https://a.example/1","title":"Burn ban lifted (web, fetched 2026-10-25 14:20)"}]"#);
    assert!(o.stderr.starts_with("timing_ms {\"search\":"), "{}", o.stderr);
    // --json carries the timing next to content and ids
    let mut json_args = args.to_vec();
    json_args.push("--json");
    let o = cs_env(&json_args, &env);
    let v = j(o.stdout.trim());
    assert_eq!(v.as_object().unwrap().keys().collect::<Vec<_>>(), ["content", "ids", "timing_ms"]);
    assert!(v["timing_ms"]["search"].is_u64());
    // the key went out as a header, and appears in nothing cs printed
    assert_eq!(seen.lock().unwrap()[0].split_once(':').unwrap().1.trim(), format!("Bearer {WEB_KEY}"));
    assert!(!o.stdout.contains(WEB_KEY) && !o.stderr.contains(WEB_KEY));
    // a result with no snippet is a line with no dash part
    let nosnip = ["tool", "web_search", "--config", cfg.as_str(), "--args", r#"{"query":"nosnippet"}"#, "--now", NOW];
    let o = cs_env(&nosnip, &env);
    assert!(o.ok, "{}", o.stderr);
    assert_eq!(o.stdout.lines().next().unwrap(), "[1] Bare (web, fetched 2026-10-25 14:20)");
    // a wrong key is a 401 from the stand-in: key_missing, and the key is not echoed
    let wrong = [("CACHE_WEB_PROVIDER", "kagi"), ("CACHE_WEB_KEY", "not-the-key"), ("CACHE_WEB_BASE_URL", base.as_str())];
    let o = cs_env(&args, &wrong);
    assert!(o.stdout.contains("key_missing") || o.stderr.contains("key_missing"), "{} {}", o.stdout, o.stderr);
}

#[test]
fn serve_web_endpoints_set_and_clear_search_without_echoing_the_key() {
    let tmp = TempDir::new("serveweb");
    let config = tmp.path("sources.json");
    std::fs::write(&config, r#"{"sources":[]}"#).unwrap();
    let s = Serve::start(&["--config", &config]);
    let names = |s: &Serve| -> Vec<String> {
        j(&s.req("GET", "/tools", None).1).as_array().unwrap().iter().map(|x| x["function"]["name"].as_str().unwrap().to_string()).collect()
    };
    assert_eq!(names(&s), ["search", "read"]);

    // on: provider, key and online
    let (code, body) = s.req("POST", "/web", Some(&json!({"provider": "kagi", "key": WEB_KEY, "online": true})));
    assert_eq!((code, body.as_str()), (200, r#"{"ok":true}"#));
    assert_eq!(names(&s), ["search", "read", "web_search"]);
    // offline: gone; online again: back
    s.req("POST", "/web", Some(&json!({"provider": "kagi", "key": WEB_KEY, "online": false})));
    assert_eq!(names(&s), ["search", "read"]);
    s.req("POST", "/web", Some(&json!({"provider": "kagi", "key": WEB_KEY, "online": true})));
    assert_eq!(names(&s), ["search", "read", "web_search"]);
    // an unknown provider, a missing online, a wrong type: errors that do not echo the key
    for bad in [json!({"provider": "bing", "key": WEB_KEY, "online": true}), json!({"provider": "kagi", "key": WEB_KEY}), json!({"provider": "kagi", "key": 5, "online": true})] {
        let (code, body) = s.req("POST", "/web", Some(&bad));
        assert_eq!(code, 400, "{body}");
        assert!(!body.contains(WEB_KEY), "{body}");
    }
    assert_eq!(names(&s), ["search", "read", "web_search"], "a refused request changes nothing");
    // clear
    let (code, body) = s.req("DELETE", "/web", None);
    assert_eq!((code, body.as_str()), (200, r#"{"ok":true}"#));
    assert_eq!(names(&s), ["search", "read"]);
    let (_, b) = s.req("POST", "/conversations", None);
    let id = j(&b)["id"].as_str().unwrap().to_string();
    let (_, body) = s.req("POST", &format!("/conversations/{id}/tool"), Some(&json!({"name": "web_search", "args": {"query": "x"}, "now": NOW})));
    assert!(j(&body)["content"].as_str().unwrap().contains("not_set_up"));
    assert!(!body.contains(WEB_KEY));
}
