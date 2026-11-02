//! Measurements, not assertions (all `#[ignore]`d; run with `--release -- --ignored --nocapture`), for DESIGN.md "Memory budget":
//!
//! - `budget_run`: the process-wide private bytes and the query times of a whole config (`CS_COST_CONFIG`, e.g.
//!   sources-full.json) for one `zim_budget_mb` (`CS_COST_BUDGET_MB`), over 20 varied queries run twice.
//! - `wikipedia_reopen`: what it costs to reopen Wikipedia (`CS_COST_WIKI`) after the budget closed it: the open, the first
//!   full-text query and the first suggestion, at the first open and after each of two evictions.
//!
//! Private bytes are the process's PrivateUsage on Windows; elsewhere they print 0.

#![cfg(zimx)]

use cache_search::ffi::*;
use cache_search::handle::{Handle, Source};
use std::ffi::{c_char, CStr, CString};
use std::time::{Duration, Instant};

#[cfg(windows)]
fn private_bytes() -> u64 {
    use windows_sys::Win32::System::ProcessStatus::{GetProcessMemoryInfo, PROCESS_MEMORY_COUNTERS_EX};
    use windows_sys::Win32::System::Threading::GetCurrentProcess;
    unsafe {
        let mut c: PROCESS_MEMORY_COUNTERS_EX = std::mem::zeroed();
        c.cb = std::mem::size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32;
        if GetProcessMemoryInfo(GetCurrentProcess(), &mut c as *mut _ as *mut _, c.cb) == 0 {
            return 0;
        }
        c.PrivateUsage as u64
    }
}

#[cfg(not(windows))]
fn private_bytes() -> u64 {
    0
}

fn mib(b: u64) -> f64 {
    b as f64 / 1048576.0
}

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

const QUERIES: [&str; 20] = [
    "flood insurance", "water purification", "meshtastic firmware", "radio antenna", "first aid burns", "solar panel wiring",
    "reticulum transport", "hypothermia treatment", "battery storage", "emergency shelter", "lora range", "water filter",
    "tourniquet", "generator safety", "wilderness navigation", "tsunami warning", "mesh routing", "radio license",
    "vaccine schedule", "repair laptop screen",
];

/// Wait until no source is still `opening` (the library opens on a background thread), at most 180 s.
fn wait_open(h: *mut Handle) {
    let t0 = Instant::now();
    loop {
        let st = take(unsafe { cs_status(h) }).unwrap();
        if !st.contains("\"opening\":true") || t0.elapsed() > Duration::from_secs(180) {
            return;
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

#[test]
#[ignore]
fn budget_run() {
    let (Ok(cfg_path), Ok(mb)) = (std::env::var("CS_COST_CONFIG"), std::env::var("CS_COST_BUDGET_MB")) else {
        eprintln!("CS_COST_CONFIG and CS_COST_BUDGET_MB not set");
        return;
    };
    let mut cfg: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&cfg_path).unwrap()).unwrap();
    cfg["zim_budget_mb"] = serde_json::json!(mb.parse::<u64>().unwrap());
    cfg["prewarm"] = serde_json::json!(std::env::var("CS_COST_PREWARM").map(|v| v == "1").unwrap_or(false));
    if let Ok(extra) = std::env::var("CS_COST_EXTRA") {
        for (k, v) in serde_json::from_str::<serde_json::Value>(&extra).unwrap().as_object().unwrap() {
            cfg[k] = v.clone();
        }
    }
    let start = private_bytes();
    let c = CString::new(cfg.to_string()).unwrap();
    let h = unsafe { cs_open(c.as_ptr()) };
    assert!(!h.is_null());
    wait_open(h);
    std::thread::sleep(Duration::from_secs(3));
    let opened = private_bytes();
    let opts = CString::new("{\"k\":10}").unwrap();
    for pass in 0..2 {
        let mut per = Vec::new();
        for q in QUERIES {
            let c = CString::new(q).unwrap();
            let t = Instant::now();
            let r = take(unsafe { cs_search(h, c.as_ptr(), opts.as_ptr()) });
            assert!(r.is_some(), "{q}");
            per.push(t.elapsed().as_secs_f64() * 1000.0);
        }
        std::thread::sleep(Duration::from_secs(3));
        let mean = per.iter().sum::<f64>() / per.len() as f64;
        let mut sorted = per.clone();
        sorted.sort_by(|a, b| a.partial_cmp(b).unwrap());
        let s = unsafe { &*h }.zim_budget.snapshot();
        println!(
            "BUDGET {}",
            serde_json::json!({"budget_mb": mb, "pass": pass, "mean_ms": mean.round(), "median_ms": sorted[10].round(), "max_ms": sorted[19].round(),
                "private_mib": mib(private_bytes()).round(), "private_after_open_mib": mib(opened).round(), "start_mib": mib(start).round(),
                "kept": s.kept.len(), "est_total_mib": mib(s.total).round(), "evictions": s.evictions, "opens": s.opens, "per_query": s.per_query})
        );
    }
    unsafe { cs_close(h) };
}

fn call_ms(f: impl FnOnce() -> Option<String>) -> f64 {
    let t = Instant::now();
    let r = f();
    assert!(r.is_some());
    t.elapsed().as_secs_f64() * 1000.0
}

#[test]
#[ignore]
fn wikipedia_reopen() {
    let Ok(wiki) = std::env::var("CS_COST_WIKI") else {
        eprintln!("CS_COST_WIKI not set");
        return;
    };
    let cfg = serde_json::json!({"sources": [{"kind": "zim", "path": wiki}], "prewarm": false});
    let c = CString::new(cfg.to_string()).unwrap();
    let h = unsafe { cs_open(c.as_ptr()) };
    assert!(!h.is_null());
    let hd: &Handle = unsafe { &*h };
    let src = match &hd.sources[0] {
        Source::Zim(z) => &z.src,
        _ => panic!("not a zim"),
    };
    let q = CString::new(std::env::var("CS_COST_WIKI_QUERY").unwrap_or_else(|_| "hypothermia treatment".into())).unwrap();
    let pre = CString::new(std::env::var("CS_COST_WIKI_PREFIX").unwrap_or_else(|_| "hypoth".into())).unwrap();
    let sopts = CString::new("{\"k\":10}").unwrap();
    let kopts = CString::new("{\"k\":5}").unwrap();
    let limit = hd.zim_budget.limit();
    for cycle in 0..3 {
        let before = private_bytes();
        let t = Instant::now();
        let z = src.xapian().expect("open");
        let open_ms = t.elapsed().as_secs_f64() * 1000.0;
        drop(z);
        let search_ms = call_ms(|| take(unsafe { cs_search(h, q.as_ptr(), sopts.as_ptr()) }));
        let suggest_ms = call_ms(|| take(unsafe { cs_suggest(h, pre.as_ptr(), kopts.as_ptr()) }));
        let warm_search_ms = call_ms(|| take(unsafe { cs_search(h, q.as_ptr(), sopts.as_ptr()) }));
        let warm_suggest_ms = call_ms(|| take(unsafe { cs_suggest(h, pre.as_ptr(), kopts.as_ptr()) }));
        std::thread::sleep(Duration::from_secs(2));
        let held = private_bytes();
        println!(
            "WIKI {}",
            serde_json::json!({"cycle": cycle, "what": if cycle == 0 { "first open" } else { "reopen after eviction" }, "open_ms": open_ms.round(),
                "first_search_ms": search_ms.round(), "first_suggest_ms": suggest_ms.round(), "warm_search_ms": warm_search_ms.round(),
                "warm_suggest_ms": warm_suggest_ms.round(), "total_cold_ms": (open_ms + search_ms + suggest_ms).round(),
                "private_growth_mib": mib(held).round() - mib(before).round(), "archive_open": src.archive_open()})
        );
        // evict: the budget shrinks to 0, which closes the archive, then goes back
        hd.zim_budget.set_limit(0);
        assert!(!src.archive_open());
        std::thread::sleep(Duration::from_secs(1));
        println!("WIKI_CLOSED {{\"private_after_close_mib\":{}}}", mib(private_bytes()).round() - mib(before).round());
        hd.zim_budget.set_limit(limit);
    }
    unsafe { cs_close(h) };
}
