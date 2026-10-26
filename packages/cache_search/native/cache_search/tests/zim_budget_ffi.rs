//! The memory budget of open libzim archives (budget.rs, DESIGN.md "Memory budget"), on real ZIMs.
//!
//! These need CS_TEST_ZIM_DIR (the folder with the ZIMs named below) and a build with the `xapian` feature on Windows or
//! Android; otherwise they print why and return. The budget logic itself (LRU order, zero budget, the prewarm plan, the
//! cost model, the per-target defaults) is covered without any ZIM by the unit tests in budget.rs.

#![cfg(zimx)]

use cache_search::budget::Caps;
use cache_search::handle::Source;
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


/// Source ids whose libzim archive is open right now, in source order.
fn open_ids(h: *mut Handle) -> Vec<String> {
    handle(h)
        .sources
        .iter()
        .filter_map(|s| match s {
            Source::Zim(z) if z.src.archive_open() => Some(z.src.id.clone()),
            _ => None,
        })
        .collect()
}

/// Each source's estimated archive cost under the default caps, keyed by id.
fn costs(h: *mut Handle) -> Vec<(String, u64)> {
    handle(h)
        .sources
        .iter()
        .filter_map(|s| match s {
            Source::Zim(z) => Some((z.src.id.clone(), z.src.archive_cost(&Caps::default()))),
            _ => None,
        })
        .collect()
}

fn reserved(h: *mut Handle) -> u64 {
    handle(h).zim_budget.snapshot().reserved
}

#[test]
fn a_zero_budget_opens_and_closes_per_query_and_the_answers_are_right() {
    let Some(paths) = zims() else { return };
    let reference = open_with(&paths, json!({"prewarm": false}));
    let h = open_with(&paths, json!({"prewarm": false, "zim_budget_mb": 0}));
    assert_eq!(handle(h).zim_budget.limit(), 0);
    for q in QUERIES {
        let want = search(reference, q, json!({"k": 10}));
        let got = search(h, q, json!({"k": 10}));
        assert!(!got["results"].as_array().unwrap().is_empty(), "{q}: {got}");
        assert_eq!(got["results"], want["results"], "{q}");
        assert_eq!(got["total_estimate"], want["total_estimate"], "{q}");
        assert!(open_ids(h).is_empty(), "no archive stays open after a query with a zero budget ({q})");
    }
    let s = handle(h).zim_budget.snapshot();
    assert!(s.kept.is_empty() && s.total == 0, "nothing is kept with a zero budget: {s:?}");
    assert!(s.per_query >= (QUERIES.len() * paths.len()) as u64, "every query opened its own archives: {s:?}");
    assert!(s.opens >= s.per_query, "{s:?}");
    // suggestions too
    assert_eq!(suggest(h, "flo")["suggestions"], suggest(reference, "flo")["suggestions"]);
    assert!(open_ids(h).is_empty());
    // the default budget keeps them all open, each opened once
    let r = handle(reference).zim_budget.snapshot();
    assert_eq!(r.limit, 1024 * 1024 * 1024, "the desktop default");
    assert_eq!(r.kept.len(), paths.len(), "{r:?}");
    assert_eq!(open_ids(reference).len(), paths.len());
    assert_eq!((r.per_query, r.evictions, r.opens), (0, 0, paths.len() as u64), "{r:?}");
    unsafe { cs_close(h) };
    unsafe { cs_close(reference) };
}

#[test]
fn a_tiny_budget_closes_the_least_recently_used_archive() {
    let Some(paths) = zims() else { return };
    let h = open_with(&paths, json!({"prewarm": false}));
    let id = ids(h);
    let c = costs(h);
    let total: u64 = c.iter().map(|x| x.1).sum();
    let min = c.iter().map(|x| x.1).min().unwrap();
    // room for any two of the three, never all three
    handle(h).zim_budget.set_limit(reserved(h) + total - min);
    // use a, b, c in order: c's admission closes a, the least recently used
    for i in &id {
        search_one(h, i, "flood");
    }
    assert_eq!(open_ids(h), vec![id[1].clone(), id[2].clone()], "a was closed");
    let s = handle(h).zim_budget.snapshot();
    assert_eq!((s.kept.len(), s.evictions), (2, 1), "{s:?}");
    assert!(s.total <= s.limit - s.reserved, "{s:?}");
    // searching a again reopens it transparently (and gives an answer) and closes b, now the least recently used
    let again = search_one(h, &id[0], "flood");
    assert!(!again["results"].as_array().unwrap().is_empty());
    assert_eq!(open_ids(h), vec![id[0].clone(), id[2].clone()]);
    let s2 = handle(h).zim_budget.snapshot();
    assert_eq!((s2.evictions, s2.opens), (2, 4), "{s2:?}");
    unsafe { cs_close(h) };
}

#[test]
fn the_most_recently_used_archive_stays_open() {
    let Some(paths) = zims() else { return };
    let h = open_with(&paths, json!({"prewarm": false}));
    let id = ids(h);
    let c = costs(h);
    let total: u64 = c.iter().map(|x| x.1).sum();
    let min = c.iter().map(|x| x.1).min().unwrap();
    handle(h).zim_budget.set_limit(reserved(h) + total - min);
    // a, b, then a again (so b is the least recently used), then c: b goes, a stays
    for i in [&id[0], &id[1], &id[0], &id[2]] {
        search_one(h, i, "flood");
    }
    assert_eq!(open_ids(h), vec![id[0].clone(), id[2].clone()], "b, the least recently used, was closed");
    // alternate between a and c: nothing is closed or reopened
    let opens = handle(h).zim_budget.snapshot().opens;
    for _ in 0..3 {
        search_one(h, &id[0], "flood");
        search_one(h, &id[2], "flood");
    }
    assert_eq!(handle(h).zim_budget.snapshot().opens, opens, "the two most recent archives were never reopened");
    // an archive larger than the whole budget opens for the query and closes after it
    let a_cost = c[0].1;
    handle(h).zim_budget.set_limit(reserved(h) + a_cost - 1);
    assert!(open_ids(h).iter().all(|i| *i != id[0]));
    let r = search_one(h, &id[0], "flood");
    assert!(!r["results"].as_array().unwrap().is_empty());
    assert!(!open_ids(h).contains(&id[0]), "over the whole budget: closed after the query");
    assert!(handle(h).zim_budget.snapshot().per_query >= 1);
    unsafe { cs_close(h) };
}

#[test]
fn results_are_identical_with_any_budget() {
    let Some(paths) = zims() else { return };
    let ref_h = open_with(&paths, json!({"prewarm": false}));
    let want: Vec<Value> = QUERIES.iter().map(|q| search(ref_h, q, json!({"k": 10}))).collect();
    let want_suggest = suggest(ref_h, "flo");
    let c = costs(ref_h);
    let total: u64 = c.iter().map(|x| x.1).sum();
    let (min, max) = (c.iter().map(|x| x.1).min().unwrap(), c.iter().map(|x| x.1).max().unwrap());
    let res = reserved(ref_h);
    // 0 (every query opens its own), under the smallest (same), one archive's worth (constant eviction), two's worth, all
    for limit in [0, res + min - 1, res + max, res + total - min, res + total, 1024 * 1024 * 1024] {
        let h = open_with(&paths, json!({"prewarm": false}));
        handle(h).zim_budget.set_limit(limit);
        // twice around, so open, closed and reopened archives all answer
        for _ in 0..2 {
            for (q, w) in QUERIES.iter().zip(&want) {
                let got = search(h, q, json!({"k": 10}));
                assert_eq!(got["results"], w["results"], "limit {limit}, {q}");
                assert_eq!(got["total_estimate"], w["total_estimate"], "limit {limit}, {q}");
            }
            assert_eq!(suggest(h, "flo")["suggestions"], want_suggest["suggestions"], "limit {limit}");
            let s = handle(h).zim_budget.snapshot();
            assert!(s.total <= s.limit.saturating_sub(s.reserved), "limit {limit}: {s:?}");
            assert_eq!(open_ids(h).len(), s.kept.len(), "what is open is what the budget counts: {s:?}");
        }
        unsafe { cs_close(h) };
    }
    unsafe { cs_close(ref_h) };
}

#[test]
fn the_old_key_name_is_an_alias() {
    let Some(paths) = zims() else { return };
    let old = open_with(&paths, json!({"prewarm": false, "searcher_budget_mb": 0}));
    assert_eq!(handle(old).zim_budget.limit(), 0, "searcher_budget_mb still sets the budget");
    search_one(old, &ids(old)[0], "flood");
    assert!(open_ids(old).is_empty());
    let both = open_with(&paths, json!({"prewarm": false, "searcher_budget_mb": 0, "zim_budget_mb": 7}));
    assert_eq!(handle(both).zim_budget.limit(), 7 * 1024 * 1024, "zim_budget_mb wins when both are given");
    let new = open_with(&paths, json!({"prewarm": false, "zim_budget_mb": 5, "zim_cluster_cache_mb": 2}));
    let s = handle(new).zim_budget.snapshot();
    assert_eq!((s.limit, s.reserved), (5 * 1024 * 1024, cache_search::budget::reserved_cost(&Caps { cluster_cache: 2 * 1024 * 1024, ..Caps::default() })));
    for h in [old, both, new] {
        unsafe { cs_close(h) };
    }
}

fn wait_until(what: &str, mut f: impl FnMut() -> bool) {
    let t0 = Instant::now();
    while !f() {
        assert!(t0.elapsed() < Duration::from_secs(60), "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[test]
fn prewarm_opens_only_what_fits_the_budget() {
    let Some(paths) = zims() else { return };
    let probe = open_with(&paths, json!({"prewarm": false}));
    let mut c: Vec<u64> = costs(probe).into_iter().map(|x| x.1).collect();
    c.sort();
    let res = reserved(probe);
    unsafe { cs_close(probe) };
    // whole MiB that fit the two cheapest but not the third: need the cluster cache reserve inside the limit too
    let mb = (res + c[0] + c[1]).div_ceil(1024 * 1024);
    assert!((mb * 1024 * 1024) < res + c[0] + c[1] + c[2], "the three costs are far enough apart: {c:?}");
    let none = open_with(&paths, json!({"prewarm": true, "zim_budget_mb": 0}));
    let two = open_with(&paths, json!({"prewarm": true, "zim_budget_mb": mb}));
    let all = open_with(&paths, json!({"prewarm": true}));
    wait_until("all three prewarmed", || open_ids(all).len() == paths.len());
    wait_until("two prewarmed", || open_ids(two).len() == 2);
    std::thread::sleep(Duration::from_secs(2));
    assert_eq!(open_ids(none).len(), 0);
    assert_eq!(open_ids(two).len(), 2, "{:?}", handle(two).zim_budget.snapshot());
    assert_eq!(open_ids(all).len(), paths.len());
    for h in [none, two, all] {
        let s = handle(h).zim_budget.snapshot();
        assert!(s.total <= s.limit.saturating_sub(s.reserved) && s.evictions == 0, "prewarm never closes anything: {s:?}");
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
