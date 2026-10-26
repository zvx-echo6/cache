//! The memory budget of the kept libzim searchers (budget.rs, DESIGN.md "Searcher memory budget"), on real ZIMs.
//!
//! These need CS_TEST_ZIM_DIR (the folder with the ZIMs named below) and a build with the `xapian` feature on Windows or
//! Android; otherwise they print why and return. The budget logic itself (LRU order, zero budget, the prewarm plan, the
//! per-target prewarm default) is covered without any ZIM by the unit tests in budget.rs.

#![cfg(zimx)]

use cache_search::budget::Kind;
use cache_search::ffi::*;
use cache_search::handle::Handle;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::time::{Duration, Instant};

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

/// Three small-to-medium ZIMs that carry a built-in Xapian index; `None` (with a message) when they are not there.
fn zims() -> Option<Vec<String>> {
    let Some(dir) = std::env::var("CS_TEST_ZIM_DIR").ok().filter(|s| !s.is_empty()) else {
        eprintln!("CS_TEST_ZIM_DIR not set: skipping the searcher budget tests");
        return None;
    };
    let names = ["www.ready.gov_en_2024-12.zim", "meshtastic.org_eng_2026-10_25.zim", "reticulum.network_eng_2026-10_22.zim"];
    let paths: Vec<String> = names.iter().map(|n| format!("{dir}/{n}")).collect();
    if let Some(missing) = paths.iter().find(|p| !std::path::Path::new(p).is_file()) {
        eprintln!("{missing} not found: skipping the searcher budget tests");
        return None;
    }
    Some(paths)
}

fn open_with(paths: &[String], extra: Value) -> *mut Handle {
    let mut cfg = json!({"sources": paths.iter().map(|p| json!({"kind": "zim", "path": p})).collect::<Vec<_>>()});
    for (k, v) in extra.as_object().unwrap() {
        cfg[k] = v.clone();
    }
    let c = cstr(&cfg.to_string());
    let h = unsafe { cs_open(c.as_ptr()) };
    assert!(!h.is_null(), "cs_open failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    h
}

fn search(h: *mut Handle, q: &str, opts: Value) -> Value {
    let r = take(unsafe { cs_search(h, cstr(q).as_ptr(), cstr(&opts.to_string()).as_ptr()) });
    serde_json::from_str(&r.unwrap_or_else(|| panic!("search failed for {q:?}: {:?}", take(unsafe { cs_last_error(h) })))).unwrap()
}

fn suggest(h: *mut Handle, prefix: &str) -> Value {
    let r = take(unsafe { cs_suggest(h, cstr(prefix).as_ptr(), cstr(&json!({"k": 5}).to_string()).as_ptr()) });
    serde_json::from_str(&r.expect("suggest result")).unwrap()
}

fn ids(h: *mut Handle) -> Vec<String> {
    let st: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
    st["sources"].as_array().unwrap().iter().map(|s| s["id"].as_str().unwrap().to_string()).collect()
}

fn handle<'a>(h: *mut Handle) -> &'a Handle {
    unsafe { &*h }
}

/// A search restricted to one source, so only that source's searcher is touched.
fn search_one(h: *mut Handle, id: &str, q: &str) -> Value {
    search(h, q, json!({"k": 5, "sources": [id]}))
}

const QUERIES: [&str; 4] = ["flood", "radio antenna", "mesh routing protocol", "emergency water supply"];

#[test]
fn a_zero_budget_builds_a_searcher_per_query_and_the_answers_are_right() {
    let Some(paths) = zims() else { return };
    let reference = open_with(&paths, json!({"prewarm": false}));
    let h = open_with(&paths, json!({"prewarm": false, "searcher_budget_mb": 0}));
    assert_eq!(handle(h).searcher_budget.limit(), 0);
    for q in QUERIES {
        let want = search(reference, q, json!({"k": 10}));
        let got = search(h, q, json!({"k": 10}));
        assert!(!got["results"].as_array().unwrap().is_empty(), "{q}: {got}");
        assert_eq!(got["results"], want["results"], "{q}");
        assert_eq!(got["total_estimate"], want["total_estimate"], "{q}");
    }
    let s = handle(h).searcher_budget.snapshot();
    assert!(s.kept.is_empty() && s.total == 0, "nothing is kept with a zero budget: {s:?}");
    assert!(s.per_query >= (QUERIES.len() * paths.len()) as u64, "every query built its own searchers: {s:?}");
    // suggestions too (the title searcher is under the same budget)
    assert_eq!(suggest(h, "flo")["suggestions"], suggest(reference, "flo")["suggestions"]);
    assert!(handle(h).searcher_budget.snapshot().kept.is_empty());
    // the default budget keeps them
    let r = handle(reference).searcher_budget.snapshot();
    assert_eq!(r.limit, 256 * 1024 * 1024);
    assert_eq!(r.kept.iter().filter(|k| k.kind == Kind::Fulltext).count(), paths.len(), "{r:?}");
    assert_eq!(r.per_query, 0);
    unsafe { cs_close(h) };
    unsafe { cs_close(reference) };
}

#[test]
fn a_tiny_budget_drops_the_least_recently_used_searcher() {
    let Some(paths) = zims() else { return };
    let h = open_with(&paths, json!({"prewarm": false}));
    let id = ids(h);
    // use the three sources in order: a, b, c (a is the least recently used)
    for i in &id {
        search_one(h, i, "flood");
    }
    let s = handle(h).searcher_budget.snapshot();
    assert_eq!(s.kept.len(), 3, "{s:?}");
    assert_eq!(s.evictions, 0);
    // room for two of the three: the budget can hold the two most recent but not all three
    let two = s.kept[1].cost + s.kept[2].cost;
    handle(h).searcher_budget.set_limit(two.max(s.total - 1));
    let s2 = handle(h).searcher_budget.snapshot();
    assert_eq!(s2.kept.len(), 2, "{s2:?}");
    assert_eq!(s2.evictions, 1);
    assert_eq!(s2.kept.iter().map(|k| k.id).collect::<Vec<_>>(), vec![s.kept[1].id, s.kept[2].id], "the first one used went");
    // searching the dropped source builds its searcher again and drops the one least recently used now (b)
    let again = search_one(h, &id[0], "flood");
    assert!(!again["results"].as_array().unwrap().is_empty());
    let s3 = handle(h).searcher_budget.snapshot();
    assert!(s3.total <= s3.limit, "{s3:?}");
    assert!(s3.kept.iter().any(|k| k.id == s.kept[0].id), "the source just searched is kept: {s3:?}");
    assert!(!s3.kept.iter().any(|k| k.id == s.kept[1].id), "the least recently used one went: {s3:?}");
    unsafe { cs_close(h) };
}

#[test]
fn results_are_identical_with_any_budget() {
    let Some(paths) = zims() else { return };
    let ref_h = open_with(&paths, json!({"prewarm": false}));
    let want: Vec<Value> = QUERIES.iter().map(|q| search(ref_h, q, json!({"k": 10}))).collect();
    let want_suggest = suggest(ref_h, "flo");
    let one_cost = handle(ref_h).searcher_budget.snapshot().kept.iter().map(|k| k.cost).min().unwrap();
    // 0 (every query on its own searcher), one source's worth (constant eviction), a few MB, the default
    for limit in [0, one_cost, one_cost * 2, 3 * 1024 * 1024, 256 * 1024 * 1024] {
        let h = open_with(&paths, json!({"prewarm": false}));
        handle(h).searcher_budget.set_limit(limit);
        // twice around, so kept, evicted and rebuilt searchers all answer
        for _ in 0..2 {
            for (q, w) in QUERIES.iter().zip(&want) {
                let got = search(h, q, json!({"k": 10}));
                assert_eq!(got["results"], w["results"], "limit {limit}, {q}");
                assert_eq!(got["total_estimate"], w["total_estimate"], "limit {limit}, {q}");
            }
            assert_eq!(suggest(h, "flo")["suggestions"], want_suggest["suggestions"], "limit {limit}");
            let s = handle(h).searcher_budget.snapshot();
            assert!(s.total <= s.limit, "limit {limit}: {s:?}");
        }
        unsafe { cs_close(h) };
    }
    unsafe { cs_close(ref_h) };
}

fn wait_until(what: &str, mut f: impl FnMut() -> bool) {
    let t0 = Instant::now();
    while !f() {
        assert!(t0.elapsed() < Duration::from_secs(60), "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn kept_sources(h: *mut Handle) -> usize {
    let mut v: Vec<u64> = handle(h).searcher_budget.snapshot().kept.iter().map(|k| k.id).collect();
    v.sort();
    v.dedup();
    v.len()
}

#[test]
fn prewarm_builds_only_what_fits_the_budget() {
    let Some(paths) = zims() else { return };
    // each of the three sources costs about 2.5 MiB (1.5 full-text + 1 title, see budget::estimate_cost): 0 MiB fits none, 6 MiB
    // fits two, 256 MiB all
    let none = open_with(&paths, json!({"prewarm": true, "searcher_budget_mb": 0}));
    let two = open_with(&paths, json!({"prewarm": true, "searcher_budget_mb": 6}));
    let all = open_with(&paths, json!({"prewarm": true}));
    wait_until("all three prewarmed", || kept_sources(all) == paths.len());
    wait_until("two prewarmed", || kept_sources(two) == 2);
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(kept_sources(none), 0);
    assert_eq!(kept_sources(two), 2, "{:?}", handle(two).searcher_budget.snapshot());
    assert_eq!(kept_sources(all), paths.len());
    for h in [none, two, all] {
        let s = handle(h).searcher_budget.snapshot();
        assert!(s.total <= s.limit && s.evictions == 0, "prewarm never evicts: {s:?}");
    }
    // and every one of them still answers, whatever was warmed
    let want = search(all, "flood", json!({"k": 5}));
    for h in [none, two] {
        assert_eq!(search(h, "flood", json!({"k": 5}))["results"], want["results"]);
    }
    for h in [none, two, all] {
        unsafe { cs_close(h) };
    }
}
