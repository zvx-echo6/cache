//! `cs_read_document` through the C ABI: a library document read whole, page by page. The shard is generated here with
//! the read-write EdgeShard, then opened by the core read-only.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::library::{ensure_init, MANIFEST_FILE};
use edge::{Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, PointInsertOperations, PointOperations, PointStruct, UpdateOperation};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::OnceLock;

const DIMS: usize = 4;
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
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn pt(id: u64, doc: &str, piece: Option<u64>, page: Value, junk: bool, text: &str) -> PointStruct {
    let mut p = json!({"title": format!("Title {doc}"), "content": text, "doc_id": doc, "junk": junk, "_start_page": page});
    if let Some(n) = piece {
        p["piece"] = json!(n);
    }
    PointStruct::new(id, vec![1.0, 0.0, 0.0, id as f32 / 1000.0], p)
}

fn build_shard(dir: &Path) {
    ensure_init();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).build()).build();
    let shard = EdgeShard::new(dir, cfg).unwrap();
    let long = |c: &str| c.repeat(100);
    let pts = vec![
        // doc "a": every point has a piece; piece order is 2, 3, 1, 4 and differs from page order
        pt(1, "a", Some(2), json!(5), false, "text one"),
        pt(2, "a", Some(0), json!(9), false, "text two"),
        pt(3, "a", Some(1), json!(9), false, "text three"),
        pt(4, "a", Some(3), json!(1), false, "text four"),
        // doc "b": one point has no piece, so pages decide (numeric), then point id
        pt(11, "b", Some(2), json!(5), false, "b one"),
        pt(12, "b", Some(0), json!(9), false, "b two"),
        pt(13, "b", None, json!(9), false, "b three"),
        pt(14, "b", Some(3), json!(1), false, "b four"),
        // doc "s": text pages, compared as text
        pt(21, "s", None, json!("9"), false, "s nine"),
        pt(22, "s", None, json!("10"), false, "s ten"),
        // doc "l": the first point is left out
        pt(41, "l", Some(0), json!(1), true, "left out text"),
        pt(42, "l", Some(1), json!(2), false, "kept two"),
        pt(43, "l", Some(2), json!(3), false, "kept three"),
        // doc "t": three long passages
        pt(51, "t", Some(0), json!(1), false, &long("a")),
        pt(52, "t", Some(1), json!(2), false, &long("b")),
        pt(53, "t", Some(2), json!(3), false, &long("c")),
    ];
    let mut pts = pts;
    // doc "w": 300 passages of 100 characters; doc "big": 5,100 short ones
    for n in 0..300u64 {
        pts.push(pt(1000 + n, "w", Some(n), json!(n + 1), false, &format!("{n:>4}{}", "w".repeat(96))));
    }
    for n in 0..5100u64 {
        pts.push(pt(20000 + n, "big", Some(n), json!(n + 1), false, &format!("passage {n}")));
    }
    for chunk in pts.chunks(500) {
        let list = chunk.iter().map(|p| p.0.clone()).collect();
        shard
            .update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(list))))
            .unwrap();
    }
    shard.flush().unwrap();
    drop(shard);
    let _ = std::fs::remove_file(dir.join(MANIFEST_FILE));
}

struct Fixture {
    _tmp: TempDir,
    dir: PathBuf,
}

fn shared() -> &'static Fixture {
    static F: OnceLock<Fixture> = OnceLock::new();
    F.get_or_init(|| {
        let tmp = TempDir(std::env::temp_dir().join(format!("cs-libdoc-{}", std::process::id())));
        let _ = std::fs::remove_dir_all(&tmp.0);
        std::fs::create_dir_all(&tmp.0).unwrap();
        let dir = tmp.0.join("lib_shard");
        build_shard(&dir);
        Fixture { _tmp: tmp, dir }
    })
}

fn settings(with_document: bool) -> Value {
    let mut fields = json!({"title": "title", "text": "content", "page": "_start_page"});
    if with_document {
        fields["document"] = json!("doc_id");
    }
    json!({"format":1,"library_id":"t","title":"Test Lib","fields":fields,
           "leave_out":[{"field":"junk","equals":true}],
           "embedding":{"vector":"","model":MODEL,"sha256":"x","dims":DIMS},"keyword_index":"auto"})
}

fn open(with_document: bool) -> *mut Handle {
    let src = json!({"kind":"library","path":shared().dir.to_str().unwrap(),"index_dir":"/nonexistent/idx","settings":settings(with_document)});
    let cfg = cstr(&json!({"sources":[src]}).to_string());
    let h = unsafe { cs_open(cfg.as_ptr()) };
    assert!(!h.is_null(), "cs_open failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    let t0 = std::time::Instant::now();
    loop {
        let v: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
        if v["sources"].as_array().unwrap().iter().all(|s| s["opening"] == false) {
            break;
        }
        assert!(t0.elapsed().as_secs() < 60, "library did not open: {v}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    h
}

fn doc(h: *mut Handle, addr: &str, max: i32) -> Value {
    let s = take(unsafe { cs_read_document(h, cstr(addr).as_ptr(), max) }).expect("a document");
    serde_json::from_str(&s).unwrap()
}

fn pages(d: &Value) -> Vec<(Value, String)> {
    d["pages"].as_array().unwrap().iter().map(|p| (p["page"].clone(), p["text"].as_str().unwrap().to_string())).collect()
}

#[test]
fn ordered_by_piece_and_grouped_by_page() {
    let h = open(true);
    let d = doc(h, "lib:t/1", 100_000);
    assert_eq!(d["title"], "Title a");
    assert_eq!((d["more_before"].clone(), d["more_after"].clone()), (json!(false), json!(false)));
    assert_eq!(
        pages(&d),
        vec![
            (json!(9), "text two\n\ntext three".to_string()),
            (json!(5), "text one".to_string()),
            (json!(1), "text four".to_string())
        ]
    );
    assert_eq!(d["pages"][0]["addresses"], json!(["lib:t/2", "lib:t/3"]));
    // at_page is the page holding the opened passage, whichever passage of the document opened it
    assert_eq!(d["at_page"], 1);
    assert_eq!(doc(h, "lib:t/3", 100_000)["at_page"], 0);
    assert_eq!(doc(h, "lib:t/4", 100_000)["at_page"], 2);
    unsafe { cs_close(h) };
}

#[test]
fn falls_back_to_page_order_without_piece() {
    let h = open(true);
    let d = doc(h, "lib:t/11", 100_000);
    assert_eq!(
        pages(&d),
        vec![
            (json!(1), "b four".to_string()),
            (json!(5), "b one".to_string()),
            (json!(9), "b two\n\nb three".to_string())
        ]
    );
    assert_eq!(d["at_page"], 1);
    // text pages sort as text: "10" before "9"
    let d = doc(h, "lib:t/21", 100_000);
    assert_eq!(pages(&d), vec![(json!("10"), "s ten".to_string()), (json!("9"), "s nine".to_string())]);
    assert_eq!(d["at_page"], 1);
    unsafe { cs_close(h) };
}

#[test]
fn no_document_field_is_one_page() {
    let h = open(false);
    let d = doc(h, "lib:t/1", 100_000);
    assert_eq!(pages(&d), vec![(json!(5), "text one".to_string())]);
    assert_eq!(d["pages"][0]["addresses"], json!(["lib:t/1"]));
    assert_eq!(d["at_page"], 0);
    assert_eq!((d["more_before"].clone(), d["more_after"].clone()), (json!(false), json!(false)));
    unsafe { cs_close(h) };
}

#[test]
fn left_out_points_are_dropped() {
    let h = open(true);
    let d = doc(h, "lib:t/42", 100_000);
    assert_eq!(pages(&d), vec![(json!(2), "kept two".to_string()), (json!(3), "kept three".to_string())]);
    assert_eq!(d["at_page"], 0);
    unsafe { cs_close(h) };
}

#[test]
fn long_documents_are_cut_at_whole_passages() {
    let h = open(true);
    // doc "t": three passages of 100 characters. From the first, only it fits in 150.
    let d = doc(h, "lib:t/51", 150);
    assert_eq!((d["more_before"].clone(), d["more_after"].clone()), (json!(false), json!(true)));
    assert_eq!(pages(&d).len(), 1);
    assert_eq!(pages(&d)[0].1.chars().count(), 100);
    // from the middle one, a window of the one passage: nothing else fits next to it, both sides are cut off
    let d = doc(h, "lib:t/52", 150);
    assert_eq!((d["more_before"].clone(), d["more_after"].clone()), (json!(true), json!(true)));
    assert_eq!(d["pages"][d["at_page"].as_u64().unwrap() as usize]["addresses"], json!(["lib:t/52"]));
    // a passage longer than the limit is cut itself
    let d = doc(h, "lib:t/52", 50);
    assert!(pages(&d)[0].1.chars().count() <= 50);
    assert_eq!(d["pages"][0]["addresses"], json!(["lib:t/52"]));
    assert_eq!(d["more_before"], true);
    assert_eq!(doc(h, "lib:t/51", 100_000)["more_after"], false);
    unsafe { cs_close(h) };
}

fn window_of(d: &Value) -> Vec<String> {
    d["pages"].as_array().unwrap().iter().flat_map(|p| p["addresses"].as_array().unwrap().iter().map(|a| a.as_str().unwrap().to_string())).collect()
}

#[test]
fn a_deep_passage_comes_back_in_a_window_around_it() {
    let h = open(true);
    // doc "w": 300 passages of 100 characters, ids 1000..1300, in piece order
    let d = doc(h, "lib:t/1150", 1000);
    let all = window_of(&d);
    assert!(all.len() >= 5 && all.len() <= 10, "{}", all.len());
    assert!(all.contains(&"lib:t/1150".to_string()));
    let at = d["at_page"].as_u64().unwrap() as usize;
    assert!(d["pages"][at]["addresses"].as_array().unwrap().contains(&json!("lib:t/1150")));
    assert!(at > 0 && at < d["pages"].as_array().unwrap().len() - 1, "grows both ways: at_page {at}");
    assert_eq!((d["more_before"].clone(), d["more_after"].clone()), (json!(true), json!(true)));
    let total: usize = pages(&d).iter().map(|(_, t)| t.chars().count()).sum();
    assert!(total <= 1000, "{total}");
    // the window is consecutive passages
    let ids: Vec<u64> = all.iter().map(|a| a.rsplit('/').next().unwrap().parse().unwrap()).collect();
    assert!(ids.windows(2).all(|w| w[1] == w[0] + 1), "{ids:?}");
    // the first passage opens at the start: nothing before it
    let d = doc(h, "lib:t/1000", 1000);
    assert_eq!((d["more_before"].clone(), d["more_after"].clone()), (json!(false), json!(true)));
    assert_eq!(d["at_page"], 0);
    assert_eq!(window_of(&d)[0], "lib:t/1000");
    // the last one ends the document
    let d = doc(h, "lib:t/1299", 1000);
    assert_eq!((d["more_before"].clone(), d["more_after"].clone()), (json!(true), json!(false)));
    assert_eq!(window_of(&d).last().unwrap(), "lib:t/1299");
    unsafe { cs_close(h) };
}

#[test]
fn the_opened_passage_is_in_even_when_the_capped_scroll_misses_it() {
    let h = open(true);
    // doc "big": 5,100 points, ids 20000.., so the last 100 are past the 5,000 the scroll takes
    let d = doc(h, "lib:t/25050", 300);
    let all = window_of(&d);
    assert!(all.contains(&"lib:t/25050".to_string()), "{all:?}");
    let at = d["at_page"].as_u64().unwrap() as usize;
    assert!(d["pages"][at]["addresses"].as_array().unwrap().contains(&json!("lib:t/25050")));
    assert_eq!(d["more_before"], true);
    unsafe { cs_close(h) };
}

#[test]
fn errors() {
    let h = open(true);
    for (addr, code) in [("zim:abc/A/x", "bad_json"), ("lib:t/999", "not_found"), ("lib:nope/1", "not_found")] {
        assert!(take(unsafe { cs_read_document(h, cstr(addr).as_ptr(), 1000) }).is_none(), "{addr}");
        let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(h) }).expect("an error")).unwrap();
        assert_eq!(e["code"], code, "{addr}");
    }
    unsafe { cs_close(h) };
}
