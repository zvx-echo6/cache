//! The ZIM's own Xapian full-text and title indexes through libzim, on a small ZIM (the openZIM testing suite's `withns/small.zim`,
//! fetched by `native/zimx/fetch-test-zim.sh`; its path is CS_TEST_SMALL_ZIM). Built with the `zimx` cfg only (Windows, Android,
//! iOS and Linux with libzim). The ready.gov tests in zimx_ffi.rs need a 2.4 GB ZIM; this one runs in CI on every platform job that
//! builds libzim. Without CS_TEST_SMALL_ZIM it prints why and returns, unless CS_TEST_REQUIRE_SMALL_ZIM is set (CI sets it), then it fails.
#![cfg(zimx)]

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::zimx::{XGet, XMain, Zimx};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::Path;
use std::ptr;

fn small_zim() -> Option<String> {
    match std::env::var("CS_TEST_SMALL_ZIM").ok().filter(|s| !s.is_empty()) {
        Some(p) => Some(p),
        None => {
            assert!(std::env::var_os("CS_TEST_REQUIRE_SMALL_ZIM").is_none(), "CS_TEST_SMALL_ZIM is not set");
            eprintln!("CS_TEST_SMALL_ZIM not set: skipping the small-ZIM Xapian test");
            None
        }
    }
}

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

fn open(sources: Vec<Value>) -> *mut Handle {
    let cfg = cstr(&json!({"sources": sources}).to_string());
    let h = unsafe { cs_open(cfg.as_ptr()) };
    assert!(!h.is_null(), "cs_open failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    h
}

/// The longest plain word in the main page's text: a query that must be in the ZIM whatever it holds.
fn word_from_main_page(z: &Zimx) -> String {
    let XMain::Found(path) = z.main_page(10).unwrap() else { panic!("the ZIM has no main page") };
    let XGet::Found(e) = z.get(&path, 10).unwrap() else { panic!("main page {path} not readable") };
    let html = String::from_utf8_lossy(&e.bytes).to_string();
    let mut text = String::new();
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                text.push(' ');
            }
            _ if !in_tag => text.push(c),
            _ => {}
        }
    }
    text.split(|c: char| !c.is_ascii_alphabetic())
        .filter(|w| w.len() >= 4)
        .max_by_key(|w| w.len())
        .unwrap_or_else(|| panic!("no word in the main page text: {text:?}"))
        .to_lowercase()
}

#[test]
fn the_small_zim_is_searched_by_its_own_xapian_index() {
    let Some(zim) = small_zim() else { return };
    assert!(Path::new(&zim).is_file(), "{zim}");
    assert_eq!(cache_search::zimx::version(), "9.8.2");
    let z = Zimx::open(Path::new(&zim)).unwrap();
    eprintln!("fulltext={} titles={} main={:?}", z.has_fulltext(), z.has_title_index(), z.main_page(10).unwrap());
    assert!(z.has_fulltext(), "the small ZIM must have a full-text index");
    assert!(z.has_title_index(), "the small ZIM must have a title index");
    z.prewarm(true, true).unwrap();
    let q = word_from_main_page(&z);
    let (hits, total) = z.search(&q, 0, 5).unwrap();
    eprintln!("search {q:?}: {} hits, total {total}", hits.len());
    for h in &hits {
        eprintln!("  {} | {} | score {}", h.path, h.title, h.score);
    }
    assert!(!hits.is_empty() && total >= hits.len(), "no hit for {q:?}");
    assert_eq!(hits[0].score, 100, "the best hit scores 100");
    // a nonsense word finds nothing, and is not an error
    let (none, zero) = z.search("zzqxjwv", 0, 5).unwrap();
    assert!(none.is_empty() && zero == 0);

    // through the core: the ZIM's own index is the keyword index, with no Tantivy index folder at all
    let h = open(vec![json!({"kind": "zim", "path": zim})]);
    let st: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
    let s = &st["sources"][0];
    assert_eq!(s["indexed"], true, "{st}");
    assert_eq!(s["keyword_source"], "own", "{st}");
    let r = take(unsafe { cs_search(h, cstr(&q).as_ptr(), cstr(&json!({"k": 5}).to_string()).as_ptr()) })
        .unwrap_or_else(|| panic!("search failed: {:?}", take(unsafe { cs_last_error(h) })));
    let r: Value = serde_json::from_str(&r).unwrap();
    let results = r["results"].as_array().unwrap();
    assert!(!results.is_empty(), "{r}");
    assert_eq!(results[0]["source_kind"], "zim", "{r}");
    unsafe { cs_close(h) };
}
