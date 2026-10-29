//! cs_tool, cs_tool_schemas and cs_set_location through the C ABI, over a small generated library (BM25-scored
//! text index of its own, so keyword search needs no index job).

use cache_search::conv::Conversation;
use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::library::{ensure_init, MANIFEST_FILE};
use cache_tool::{Tool, ToolCtx, ToolError, ToolOutput};
use edge::{
    CreateIndex, Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, FieldIndexOperations, PayloadFieldSchema,
    PayloadSchemaParams, PointInsertOperations, PointOperations, PointStruct, TextIndexParams, TextScoringParams, UpdateOperation,
};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::ptr;

const NOW: &str = "2026-10-25T14:20:05-06:00";
const MODEL: &str = "test-model.gguf";

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-tooltest-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn vector(i: u64) -> Vec<f32> {
    vec![1.0, i as f32, 0.5, 0.25]
}

fn build_shard(dir: &std::path::Path) {
    ensure_init();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(4, Distance::Cosine).build()).build();
    let shard = EdgeShard::new(dir, cfg).unwrap();
    let schema = PayloadFieldSchema::FieldParams(PayloadSchemaParams::Text(TextIndexParams {
        scoring: Some(TextScoringParams::default()),
        ..TextIndexParams::default()
    }));
    shard
        .update(UpdateOperation::FieldIndexOperation(FieldIndexOperations::CreateIndex(CreateIndex {
            field_name: "content".parse().unwrap(),
            field_schema: Some(schema),
        })))
        .unwrap();
    let pts: Vec<_> = (1..=8u64)
        .map(|i| {
            let content = match i {
                3 => "The sesquipedalian word appears once\n\nA second paragraph about the word follows it here.".to_string(),
                5 => "A sesquipedalian tale   with\nodd   spacing".to_string(),
                _ => format!("Alpha text number {i} here"),
            };
            PointStruct::new(i, vector(i), json!({"title": format!("Doc {i}"), "content": content})).0
        })
        .collect();
    shard
        .update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(pts))))
        .unwrap();
    shard.flush().unwrap();
    drop(shard);
    let _ = std::fs::remove_file(dir.join(MANIFEST_FILE));
}

struct Fx {
    _tmp: TempDir,
    h: *mut Handle,
    c: *mut Conversation,
}

impl Fx {
    fn new(name: &str) -> Fx {
        let tmp = TempDir::new(name);
        let shard = tmp.0.join("shard");
        build_shard(&shard);
        let settings = json!({"format":1,"library_id":"own","title":"Own","fields":{"title":"title","text":"content"},
            "embedding":{"vector":"","model":MODEL,"sha256":"x","dims":4},"keyword_index":"auto"});
        let cfg = json!({"sources":[{"kind":"library","path":shard.to_str().unwrap(),"index_dir":"/nonexistent/idx","settings":settings}]});
        let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
        assert!(!h.is_null());
        let t0 = std::time::Instant::now();
        loop {
            let v: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
            if v["sources"][0]["opening"] == false {
                break;
            }
            assert!(t0.elapsed().as_secs() < 60, "{v}");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        Fx { _tmp: tmp, h, c: cs_conversation_new() }
    }

    fn tool(&self, name: &str, args: &str) -> Value {
        let p = unsafe { cs_tool(self.h, self.c, cstr(name).as_ptr(), cstr(args).as_ptr(), cstr(NOW).as_ptr()) };
        serde_json::from_str(&take(p).unwrap_or_else(|| panic!("cs_tool failed: {:?}", last_error(self.h)))).unwrap()
    }

    fn format(&self, results: &str) -> Value {
        serde_json::from_str(&take(unsafe { cs_format(self.c, cstr(results).as_ptr()) }).unwrap()).unwrap()
    }
}

impl Drop for Fx {
    fn drop(&mut self) {
        unsafe {
            cs_conversation_free(self.c);
            cs_close(self.h);
        }
    }
}

fn last_error(h: *mut Handle) -> Option<Value> {
    take(unsafe { cs_last_error(h) }).map(|s| serde_json::from_str(&s).unwrap())
}

#[test]
fn search_numbers_its_lines_and_cs_format_keeps_the_numbers() {
    let f = Fx::new("search");
    let v = f.tool("search", r#"{"query":"sesquipedalian"}"#);
    let lines: Vec<&str> = v["content"].as_str().unwrap().lines().collect();
    assert_eq!(lines.len(), 2, "{v}");
    // one line each, "[n] title \u{2014} snippet", numbered in the order shown, no marker left
    let ids = v["ids"].as_array().unwrap();
    assert_eq!(ids.len(), 2, "{v}");
    for (i, l) in lines.iter().enumerate() {
        let id = &ids[i];
        assert_eq!(id["n"], i + 1);
        assert!(l.starts_with(&format!("[{}] {} \u{2014} ", i + 1, id["title"].as_str().unwrap())), "{v}");
    }
    let mut addrs: Vec<&str> = ids.iter().map(|x| x["address"].as_str().unwrap()).collect();
    addrs.sort();
    assert_eq!(addrs, ["lib:own/3", "lib:own/5"]);
    assert!(!v["content"].as_str().unwrap().contains("{{addr:"), "{v}");
    // the snippet's runs of whitespace are single spaces
    assert!(v["content"].as_str().unwrap().contains("tale with odd spacing"), "{v}");
    let n3 = ids.iter().find(|x| x["address"] == "lib:own/3").unwrap()["n"].as_u64().unwrap();
    assert!(f.tool("search", r#"{"query":"sesquipedalian"}"#)["ids"].as_array().unwrap().is_empty(), "known addresses give no new ids");
    // a later cs_format with the same address keeps its number, and a new one continues
    let g = f.format(r#"[{"address":"lib:own/3","title":"Doc 3","snippet":"x"},{"address":"lib:own/9","title":"New","snippet":"y"}]"#);
    assert_eq!(g["tool_message"], format!("[{n3}] Doc 3 \u{2014} x\n[3] New \u{2014} y"));
}

#[test]
fn the_search_line_is_the_tool_message_of_cs_format() {
    // Same title and snippet rules as cs_format: the content of search equals cs_format's tool_message for the
    // same results.
    let f = Fx::new("same");
    let raw: Value = serde_json::from_str(
        &take(unsafe { cs_search(f.h, cstr("sesquipedalian").as_ptr(), cstr(r#"{"k":5}"#).as_ptr()) }).unwrap(),
    )
    .unwrap();
    let want = f.format(&raw["results"].to_string());
    let got = f.tool("search", r#"{"query":"sesquipedalian"}"#);
    assert_eq!(got["content"], want["tool_message"]);
}

#[test]
fn nothing_found() {
    let f = Fx::new("none");
    let v = f.tool("search", r#"{"query":"qqqqzzzz"}"#);
    assert_eq!(v["content"], "No results found.");
    assert_eq!(v["ids"], json!([]));
}

#[test]
fn read_by_number() {
    let f = Fx::new("read");
    let s = f.tool("search", r#"{"query":"sesquipedalian"}"#);
    let n = s["ids"].as_array().unwrap().iter().find(|x| x["address"] == "lib:own/3").unwrap()["n"].as_u64().unwrap();
    let v = f.tool("read", &json!({"n": n}).to_string());
    assert_eq!(
        v["content"],
        format!("[{n}] Doc 3\nThe sesquipedalian word appears once\n\nA second paragraph about the word follows it here.")
    );
    assert_eq!(v["ids"], json!([]), "read keeps the number it was given");
    let v = f.tool("read", r#"{"n":7}"#);
    assert_eq!(v["content"], r#"{"ok":false,"error":{"type":"not_found","detail":"no result [7] in this conversation"}}"#);
}

#[test]
fn bad_arguments_and_unknown_tools_are_content() {
    let f = Fx::new("bad");
    for (name, args, detail) in [
        ("search", "{}", "query: required"),
        ("search", r#"{"query":""}"#, "query: must be at least 1 characters"),
        ("search", r#"{"query":3}"#, "query: must be a string"),
        ("search", r#"{"query":"a","k":9}"#, "k: not allowed"),
        ("read", r#"{"n":0}"#, "n: must be at least 1"),
        ("read", r#"{"n":"1"}"#, "n: must be an integer"),
        ("read", "[]", "arguments: must be an object"),
        ("navigate", "{}", "no tool named navigate"),
    ] {
        let v = f.tool(name, args);
        assert_eq!(
            v["content"],
            json!({"ok":false,"error":{"type":"bad_arguments","detail":detail}}).to_string(),
            "{name} {args}"
        );
        assert_eq!(v["ids"], json!([]));
    }
    let long = "x".repeat(201);
    let v = f.tool("search", &json!({"query": long}).to_string());
    assert!(v["content"].as_str().unwrap().contains("query: must be at most 200 characters"));
}

#[test]
fn c_errors_are_only_for_invalid_handle_conv_args_json_or_now() {
    let f = Fx::new("cerr");
    unsafe {
        let (n, a, t) = (cstr("search"), cstr(r#"{"query":"x"}"#), cstr(NOW));
        assert!(cs_tool(f.h, ptr::null_mut(), n.as_ptr(), a.as_ptr(), t.as_ptr()).is_null());
        assert_eq!(last_error(f.h).unwrap()["code"], "bad_json");
        assert!(cs_tool(ptr::null_mut(), f.c, n.as_ptr(), a.as_ptr(), t.as_ptr()).is_null());
        let bad = cstr("{");
        assert!(cs_tool(f.h, f.c, n.as_ptr(), bad.as_ptr(), t.as_ptr()).is_null());
        assert_eq!(last_error(f.h).unwrap()["code"], "bad_json");
        let empty = cstr("");
        assert!(cs_tool(f.h, f.c, n.as_ptr(), a.as_ptr(), empty.as_ptr()).is_null());
        assert!(last_error(f.h).unwrap()["message"].as_str().unwrap().contains("now"));
        assert!(cs_tool(f.h, f.c, n.as_ptr(), a.as_ptr(), ptr::null()).is_null());
        assert!(cs_tool(f.h, f.c, ptr::null(), a.as_ptr(), t.as_ptr()).is_null());
        assert!(cs_tool_schemas(ptr::null_mut()).is_null());
        // a good call clears the error
        take(cs_tool(f.h, f.c, n.as_ptr(), a.as_ptr(), t.as_ptr())).unwrap();
        assert!(last_error(f.h).is_none());
    }
}

struct Echo;
impl Tool for Echo {
    fn name(&self) -> &'static str {
        "locate"
    }
    fn schema(&self) -> Option<Value> {
        Some(json!({"type":"function","function":{"name":"locate","description":"d","parameters":{"type":"object","properties":{
            "place":{"type":"string","minLength":1}},"required":[],"additionalProperties":false}}}))
    }
    fn run(&self, ctx: &ToolCtx, args: &Value) -> Result<ToolOutput, ToolError> {
        match ctx.location {
            None if args.get("place").is_none() => Err(ToolError::new(ToolError::NO_LOCATION, "no fix")),
            None => Ok(ToolOutput::Json(json!({"place": args["place"], "now": ctx.now}))),
            Some(l) => Ok(ToolOutput::Json(json!({
                "address": "pt:here", "place_name": "current location", "lat": l.lat, "lon": l.lon,
                "accuracy_m": l.accuracy_m, "fixed_at": l.fixed_at, "now": ctx.now
            }))),
        }
    }
}

#[test]
fn a_registered_tool_gets_the_location_and_now_and_its_result_is_numbered() {
    let f = Fx::new("reg");
    let names = |f: &Fx| -> Vec<String> {
        let v: Value = serde_json::from_str(&take(unsafe { cs_tool_schemas(f.h) }).unwrap()).unwrap();
        v.as_array().unwrap().iter().map(|s| s["function"]["name"].as_str().unwrap().to_string()).collect()
    };
    assert_eq!(names(&f), ["search", "read", "calculate"]);
    unsafe { (*f.h).register_tool(Box::new(Echo)) };
    assert_eq!(names(&f), ["search", "read", "locate", "calculate"]);

    assert_eq!(f.tool("locate", "{}")["content"], r#"{"ok":false,"error":{"type":"no_location","detail":"no fix"}}"#);
    assert_eq!(
        f.tool("locate", r#"{"place":"Burley"}"#)["content"],
        format!(r#"{{"ok":true,"place":"Burley","now":"{NOW}"}}"#)
    );
    unsafe {
        assert_eq!(cs_set_location(f.h, 42.536, -113.792, 12.0, cstr("2026-10-25T14:19:00-06:00").as_ptr()), 0);
    }
    let v = f.tool("locate", "{}");
    assert_eq!(
        v["content"],
        format!(
            r#"{{"ok":true,"n":1,"place_name":"current location","lat":42.536,"lon":-113.792,"accuracy_m":12.0,"fixed_at":"2026-10-25T14:19:00-06:00","now":"{NOW}"}}"#
        )
    );
    assert_eq!(v["ids"], json!([{"n":1,"address":"pt:here","title":"current location"}]));
    unsafe {
        assert_eq!(cs_set_location(f.h, 42.0, -113.0, -1.0, cstr("t").as_ptr()), 0);
    }
    assert!(f.tool("locate", "{}")["content"].as_str().unwrap().contains(r#""accuracy_m":null"#));
    unsafe {
        assert_eq!(cs_clear_location(f.h), 0);
    }
    assert!(f.tool("locate", "{}")["content"].as_str().unwrap().contains("no_location"));
}

#[test]
fn bad_locations_are_c_errors() {
    let f = Fx::new("loc");
    unsafe {
        assert_eq!(cs_set_location(f.h, 91.0, 0.0, 5.0, cstr("t").as_ptr()), -1);
        assert_eq!(last_error(f.h).unwrap()["code"], "bad_json");
        assert_eq!(cs_set_location(f.h, 0.0, 0.0, 5.0, ptr::null()), -1);
        assert_eq!(cs_set_location(ptr::null_mut(), 0.0, 0.0, 5.0, cstr("t").as_ptr()), -1);
        assert_eq!(cs_clear_location(ptr::null_mut()), -1);
    }
}

#[test]
fn the_query_embedder_gives_search_its_vector() {
    let f = Fx::new("emb");
    // no keyword hit and no embedder: keyword-only, nothing found
    assert_eq!(f.tool("search", r#"{"query":"qqqqzzzz"}"#)["content"], "No results found.");
    let seen = std::sync::Arc::new(std::sync::Mutex::new(Vec::<String>::new()));
    let s2 = seen.clone();
    unsafe {
        (*f.h).set_query_embedder(Box::new(move |q: &str| {
            s2.lock().unwrap().push(q.to_string());
            Some((MODEL.to_string(), vector(6)))
        }));
    }
    let v = f.tool("search", r#"{"query":"qqqqzzzz"}"#);
    assert!(v["content"].as_str().unwrap().starts_with("[1] Doc 6"), "{v}");
    assert_eq!(*seen.lock().unwrap(), ["qqqqzzzz"]);
    // a vector of another model is not used
    unsafe { (*f.h).set_query_embedder(Box::new(|_q: &str| Some(("other".to_string(), vector(6))))) };
    assert_eq!(f.tool("search", r#"{"query":"qqqqzzzz"}"#)["content"], "No results found.");
    // an embedder that gives nothing falls back to keywords
    unsafe { (*f.h).set_query_embedder(Box::new(|_q: &str| None)) };
    assert!(f.tool("search", r#"{"query":"sesquipedalian"}"#)["content"].as_str().unwrap().contains("Doc 5"));
}

#[test]
fn the_host_gives_search_its_query_vector() {
    let f = Fx::new("hostvec");
    let qv = json!({"model": MODEL, "vector": vector(6)});
    let args = json!({"query": "qqqqzzzz", "query_vector": qv}).to_string();
    // the host's vector is used, and is not an argument the schema rejects
    let v = f.tool("search", &args);
    assert!(v["content"].as_str().unwrap().starts_with("[1] Doc 6"), "{v}");
    // it wins over the handle's embedder
    unsafe { (*f.h).set_query_embedder(Box::new(|_q: &str| Some(("other".to_string(), vector(6))))) };
    let v = f.tool("search", &json!({"query": "qqqqzzzz", "query_vector": {"model": MODEL, "vector": vector(6)}}).to_string());
    assert!(v["content"].as_str().unwrap().starts_with("[1] Doc 6"), "{v}");
    // a null vector leaves the embedder's (of another model here: keywords only)
    assert_eq!(f.tool("search", r#"{"query":"qqqqzzzz","query_vector":null}"#)["content"], "No results found.");
    // other tools still reject it
    let v = f.tool("read", r#"{"n":1,"query_vector":{"model":"m","vector":[1]}}"#);
    assert!(v["content"].as_str().unwrap().contains("bad_arguments"), "{v}");
}
