//! Field order of every JSON the C ABI returns: the order cache_search.h documents (serde_json `preserve_order`
//! keeps insertion order, so the order is the one written in the code, not alphabetical). Each test compares
//! bytes or the key order, never a sorted view.

use cache_search::ffi::*;
use cache_search::job::Job;
use cache_search::library::{ensure_init, MANIFEST_FILE};
use cache_search::Error;
use edge::{
    CreateIndex, Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, FieldIndexOperations, PayloadFieldSchema,
    PayloadSchemaParams, PointInsertOperations, PointOperations, PointStruct, TextIndexParams, TextScoringParams, UpdateOperation,
};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::ptr;

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

fn keys(v: &Value) -> Vec<&str> {
    v.as_object().unwrap().keys().map(String::as_str).collect()
}

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-ordertest-{}-{}", std::process::id(), name));
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

#[test]
fn version_and_numbering_bytes() {
    assert_eq!(take(cs_version()).unwrap(), r#"{"version":"0.1.0","index_format":3}"#);
    let c = cs_conversation_new();
    let f = |json: &str| take(unsafe { cs_format(c, cstr(json).as_ptr()) }).unwrap();
    assert_eq!(f("[]"), r#"{"tool_message":"No results found.","ids":[]}"#);
    assert_eq!(
        f(r#"[{"address":"a","title":"A","snippet":"s"},{"address":"b","title":"B","snippet":""}]"#),
        r#"{"tool_message":"[1] A — s\n[2] B","ids":[{"n":1,"address":"a","title":"A"},{"n":2,"address":"b","title":"B"}]}"#
    );
    assert_eq!(
        take(unsafe { cs_conversation_ids(c) }).unwrap(),
        r#"{"ids":[{"n":1,"address":"a","title":"A"},{"n":2,"address":"b","title":"B"}]}"#
    );
    unsafe { cs_conversation_free(c) };
}

#[test]
fn error_json_bytes() {
    assert_eq!(Error::bad_json("x").to_json(), r#"{"code":"bad_json","message":"x"}"#);
    assert_eq!(
        Error::no_space("short", 10, 4).to_json(),
        r#"{"code":"no_space","message":"short","needed":10,"available":4}"#
    );
}

#[test]
fn status_of_a_missing_zim_and_library() {
    let cfg = cstr(r#"{"sources":[{"kind":"zim","path":"/nonexistent/a.zim"},{"kind":"library","path":"/nonexistent/recon"}]}"#);
    let h = unsafe { cs_open(cfg.as_ptr()) };
    let v: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
    assert_eq!(keys(&v), ["sources"]);
    let want = ["id", "kind", "path", "title", "language", "indexed", "building", "stale", "opening", "updating", "docs", "embedding_model", "error"];
    for s in v["sources"].as_array().unwrap() {
        assert_eq!(keys(s), want, "{s}");
        assert_eq!(keys(&s["error"]), ["code", "message"]);
    }
    unsafe { cs_close(h) };
}

const DIMS: usize = 4;

fn build_shard(dir: &std::path::Path) {
    ensure_init();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).build()).build();
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
    let pts: Vec<_> = (1..=5u64)
        .map(|i| {
            let content = if i == 3 { "The sesquipedalian word appears once".to_string() } else { format!("Alpha text number {i} here") };
            PointStruct::new(i, vec![1.0, i as f32, 0.5, 0.25], json!({"title": format!("Doc {i}"), "content": content})).0
        })
        .collect();
    shard
        .update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(pts))))
        .unwrap();
    shard.flush().unwrap();
    drop(shard);
    let _ = std::fs::remove_file(dir.join(MANIFEST_FILE));
}

#[test]
fn search_read_and_library_status_order() {
    let tmp = TempDir::new("lib");
    let shard = tmp.0.join("shard");
    build_shard(&shard);
    let settings = json!({"format":1,"library_id":"own","title":"Own","fields":{"title":"title","text":"content"},
        "embedding":{"vector":"","model":"m","sha256":"x","dims":DIMS},"keyword_index":"auto"});
    let cfg = json!({"sources":[{"kind":"library","path":shard.to_str().unwrap(),"index_dir":"/nonexistent/idx","settings":settings}]});
    let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
    let t0 = std::time::Instant::now();
    let status = loop {
        let v: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
        if v["sources"][0]["opening"] == false {
            break v;
        }
        assert!(t0.elapsed().as_secs() < 60);
        std::thread::sleep(std::time::Duration::from_millis(5));
    };
    let s = &status["sources"][0];
    assert_eq!(
        keys(s),
        ["id", "kind", "path", "title", "language", "indexed", "building", "stale", "opening", "updating", "docs", "embedding_model",
         "library_id", "keyword_source", "whole_library_only", "settings", "error"]
    );
    assert_eq!(
        keys(&s["settings"]),
        ["format", "library_id", "version", "title", "fields", "leave_out", "embedding", "keyword_index", "guessed"]
    );
    assert_eq!(keys(&s["settings"]["embedding"]), ["vector", "model", "sha256", "dims"]);
    // "time" is there because the status JSON echoes the library's field mapping for the app; the model never sees it
    assert_eq!(
        keys(&s["settings"]["fields"]),
        ["title", "title_fallback", "text", "summary", "page", "source_type", "author", "link", "time", "document"]
    );

    let r = take(unsafe { cs_search(h, cstr("sesquipedalian").as_ptr(), cstr(r#"{"k":3}"#).as_ptr()) }).unwrap();
    let v: Value = serde_json::from_str(&r).unwrap();
    assert_eq!(keys(&v), ["results", "total_estimate", "vector_sources", "keyword_only_sources"]);
    assert_eq!(keys(&v["results"][0]), ["address", "title", "snippet", "source_id", "source_kind", "source_title", "page"]);
    assert_eq!(v["results"][0]["address"], "lib:own/3");

    let r = take(unsafe { cs_read(h, cstr("lib:own/3").as_ptr(), 6000) }).unwrap();
    let v: Value = serde_json::from_str(&r).unwrap();
    assert_eq!(keys(&v), ["address", "title", "text", "truncated", "author", "page", "source_type"]);
    unsafe { cs_close(h) };
}

#[test]
fn job_progress_order() {
    let tmp = TempDir::new("job");
    let shard = tmp.0.join("shard");
    build_shard(&shard);
    let params = json!({"library_path": shard.to_str().unwrap(), "index_dir": tmp.0.join("idx").to_str().unwrap(), "heap_mb": 50,
        "settings": {"format":1,"library_id":"own","title":"Own","fields":{"title":"title","text":"content"},
                     "embedding":{"vector":"","model":"m","sha256":"x","dims":DIMS},"keyword_index":"on"}});
    let j: *mut Job = unsafe { cs_job_start(cstr("index_library").as_ptr(), cstr(&params.to_string()).as_ptr()) };
    assert!(!j.is_null(), "{:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    let t0 = std::time::Instant::now();
    let p = loop {
        let p = take(unsafe { cs_job_progress(j) }).unwrap();
        if !p.contains(r#""state":"running""#) {
            break p;
        }
        assert!(t0.elapsed().as_secs() < 60, "{p}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    };
    let v: Value = serde_json::from_str(&p).unwrap();
    assert_eq!(keys(&v), ["state", "done", "total", "error"], "{p}");
    assert_eq!(v["state"], "done");
    unsafe { cs_job_free(j) };
}
