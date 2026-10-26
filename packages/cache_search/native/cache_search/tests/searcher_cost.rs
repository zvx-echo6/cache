//! Measurements, not assertions (all `#[ignore]`d; run with `--release -- --ignored --nocapture`):
//!
//! - `searcher_cost_one_zim`: the private bytes a kept libzim searcher costs on one ZIM (`CS_COST_ZIM` = the .zim path).
//!   Run it once per ZIM, in a fresh process each time, so allocator state does not carry over. Prints one line.
//! - `cluster_cache_effect`: the same kind of reading with libzim's cluster cache emptied.
//! - `latency_for_budget`: the mean warm query time over the sources in `CS_COST_CONFIG` (a cs config file such as
//!   sources-full.json) for one `searcher_budget_mb` (`CS_COST_BUDGET_MB`).
//!
//! Private bytes are the process's PrivateUsage (the same number as .NET's PrivateMemorySize64) on Windows; elsewhere
//! the measurement prints 0 and says so.

#![cfg(zimx)]

use cache_search::ffi::*;
use cache_search::zimsrc::ZimSource;
use cache_search::zimx::Zimx;
use std::ffi::{c_char, CStr, CString};
use std::path::Path;
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

/// Sampled after a short settle, so background threads and lazy frees have finished.
fn settled() -> u64 {
    std::thread::sleep(Duration::from_millis(1500));
    let mut best = private_bytes();
    for _ in 0..3 {
        std::thread::sleep(Duration::from_millis(300));
        best = private_bytes();
    }
    best
}

#[test]
#[ignore]
fn searcher_cost_one_zim() {
    let Ok(path) = std::env::var("CS_COST_ZIM") else {
        eprintln!("CS_COST_ZIM not set");
        return;
    };
    let query = std::env::var("CS_COST_QUERY").unwrap_or_else(|_| "water".to_string());
    let base = settled();
    let src = ZimSource::open(Path::new(&path)).unwrap();
    let ft_bytes = src.zim.fulltext_index().ok().flatten().and_then(|c| c.len().ok()).unwrap_or(0);
    let ti_bytes = src.zim.title_index().ok().flatten().and_then(|c| c.len().ok()).unwrap_or(0);
    let after_src = settled();
    let z = Zimx::open(Path::new(&path)).unwrap();
    let a_open = settled();
    let mut m = serde_json::Map::new();
    let mut put = |k: &str, v: u64| {
        m.insert(k.to_string(), serde_json::json!(v));
    };
    put("base", base);
    put("after_zim_crate", after_src);
    put("a_open", a_open);
    let (mut b_pre, mut c_k0, mut d_k10, mut e_drop, mut f_rebuild) = (a_open, a_open, a_open, a_open, a_open);
    let (mut cc_k0, mut cc_k10) = (0, 0);
    let (mut first_ms, mut warm_ms, mut k0_ms) = (0.0, 0.0, 0.0);
    if z.has_fulltext() {
        z.prewarm(true, false).unwrap();
        b_pre = settled();
        // one search that only counts: the searcher and the Xapian database, no article read
        let t = Instant::now();
        let _ = z.search(&query, 0, 0).unwrap();
        k0_ms = t.elapsed().as_secs_f64() * 1000.0;
        c_k0 = settled();
        cc_k0 = cache_search::zimx::cluster_cache().0;
        // then ten results with snippets: libzim reads and decompresses articles
        let t = Instant::now();
        let _ = z.search(&query, 0, 10).unwrap();
        first_ms = t.elapsed().as_secs_f64() * 1000.0;
        let t = Instant::now();
        let _ = z.search(&query, 0, 10).unwrap();
        warm_ms = t.elapsed().as_secs_f64() * 1000.0;
        d_k10 = settled();
        cc_k10 = cache_search::zimx::cluster_cache().0;
        // release the searcher, as an eviction does
        z.drop_searchers(true, false);
        e_drop = settled();
        // and build it again, count only
        let _ = z.search(&query, 0, 0).unwrap();
        f_rebuild = settled();
    }
    put("b_prewarm_ft", b_pre);
    put("c_ft_search_k0", c_k0);
    put("d_ft_search_k10", d_k10);
    put("e_ft_dropped", e_drop);
    put("f_ft_rebuilt_k0", f_rebuild);
    put("cluster_cache_after_k0", cc_k0);
    put("cluster_cache_after_k10", cc_k10);
    let (mut g_ti, mut h_ti_drop) = (f_rebuild, f_rebuild);
    if z.has_title_index() {
        z.prewarm(false, true).unwrap();
        let _ = z.suggest("wa", 0);
        let _ = z.suggest("wa", 5);
        g_ti = settled();
        z.drop_searchers(false, true);
        h_ti_drop = settled();
    }
    put("g_titles_used", g_ti);
    put("h_titles_dropped", h_ti_drop);
    z.drop_searchers(true, true);
    drop(z);
    put("i_archive_closed", settled());
    let zim_bytes = std::fs::metadata(&path).map(|m| m.len()).unwrap_or(0);
    let name = Path::new(&path).file_name().unwrap().to_string_lossy().to_string();
    m.insert("zim".into(), serde_json::json!(name));
    m.insert("zim_bytes".into(), serde_json::json!(zim_bytes));
    m.insert("fulltext_index_bytes".into(), serde_json::json!(ft_bytes));
    m.insert("title_index_bytes".into(), serde_json::json!(ti_bytes));
    m.insert("first_search_ms".into(), serde_json::json!(first_ms));
    m.insert("warm_search_ms".into(), serde_json::json!(warm_ms));
    m.insert("k0_search_ms".into(), serde_json::json!(k0_ms));
    println!("COST {}", serde_json::Value::Object(m));
}

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

/// Mean warm query time over `CS_COST_CONFIG` for one searcher budget (`CS_COST_BUDGET_MB`): what a small budget costs in
/// latency when every query touches every source (so the least recently used searcher is always the next one needed).
#[test]
#[ignore]
fn latency_for_budget() {
    let (Ok(cfg_path), Ok(mb)) = (std::env::var("CS_COST_CONFIG"), std::env::var("CS_COST_BUDGET_MB")) else {
        eprintln!("CS_COST_CONFIG and CS_COST_BUDGET_MB not set");
        return;
    };
    let mut cfg: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&cfg_path).unwrap()).unwrap();
    cfg["searcher_budget_mb"] = serde_json::json!(mb.parse::<u64>().unwrap());
    let c = CString::new(cfg.to_string()).unwrap();
    let h = unsafe { cs_open(c.as_ptr()) };
    assert!(!h.is_null());
    let queries = [
        "flood insurance", "water purification", "meshtastic firmware", "radio antenna", "first aid burns",
        "solar panel wiring", "reticulum transport", "hypothermia treatment", "battery storage", "emergency shelter",
    ];
    let opts = CString::new("{\"k\":10}").unwrap();
    std::thread::sleep(Duration::from_secs(20));
    let mut results = Vec::new();
    for pass in 0..2 {
        let mut per = Vec::new();
        for q in queries {
            let c = CString::new(q).unwrap();
            let t = Instant::now();
            let r = take(unsafe { cs_search(h, c.as_ptr(), opts.as_ptr()) });
            assert!(r.is_some(), "{q}");
            per.push(t.elapsed().as_secs_f64() * 1000.0);
        }
        let mean = per.iter().sum::<f64>() / per.len() as f64;
        results.push(mean);
        let s = unsafe { &*h }.searcher_budget.snapshot();
        println!(
            "LATENCY budget {mb} MiB pass {pass}: mean {mean:.0} ms; per query {:?}; kept {} ({:.0} MiB est.), evictions {}, per-query builds {}, private {:.0} MiB",
            per.iter().map(|x| x.round() as i64).collect::<Vec<_>>(),
            s.kept.len(),
            s.total as f64 / 1048576.0,
            s.evictions,
            s.per_query,
            private_bytes() as f64 / 1048576.0
        );
    }
    unsafe { cs_close(h) };
}

/// Where the memory of a search that reads results goes: libzim's cluster cache (shared by all archives). Reads ten results,
/// then empties the cache by setting its limit to 0 and reports the private bytes at each step (`CS_COST_ZIM`).
#[test]
#[ignore]
fn cluster_cache_effect() {
    let Ok(path) = std::env::var("CS_COST_ZIM") else {
        eprintln!("CS_COST_ZIM not set");
        return;
    };
    let z = Zimx::open(Path::new(&path)).unwrap();
    let a_open = settled();
    let (_, max0) = cache_search::zimx::cluster_cache();
    let _ = z.search("water", 0, 0).unwrap();
    let c_k0 = settled();
    let _ = z.search("water", 0, 10).unwrap();
    let d_k10 = settled();
    let (cur10, _) = cache_search::zimx::cluster_cache();
    cache_search::zimx::set_cluster_cache_max(0);
    let e_cc0 = settled();
    let (cur0, _) = cache_search::zimx::cluster_cache();
    cache_search::zimx::set_cluster_cache_max(16 * 1024 * 1024);
    let _ = z.search("water", 0, 10).unwrap();
    let f_cc16 = settled();
    let (cur16, _) = cache_search::zimx::cluster_cache();
    let name = Path::new(&path).file_name().unwrap().to_string_lossy().to_string();
    println!(
        "CCX {{\"zim\":\"{name}\",\"cache_max_default\":{max0},\"a_open\":{a_open},\"c_k0\":{c_k0},\"d_k10\":{d_k10},\"cache_after_k10\":{cur10},\"e_cache_limit_0\":{e_cc0},\"cache_after_0\":{cur0},\"f_cache_limit_16MiB_k10\":{f_cc16},\"cache_after_16\":{cur16}}}"
    );
}
