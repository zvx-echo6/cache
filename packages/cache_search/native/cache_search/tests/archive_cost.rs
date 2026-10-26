//! Measurements, not assertions (all `#[ignore]`d; run with `--release -- --ignored --nocapture`): what an open libzim archive
//! costs in private bytes, with libzim's own defaults and with its cache and preload options changed (DESIGN.md "Memory budget").
//!
//! - `archive_probe`: opens the ZIMs of `CS_PROBE_ZIMS` (paths separated by `;`) one after the other in this one process and
//!   prints one `PROBE {json}` line per ZIM: private bytes before, after the open, after the searcher is built, and after a
//!   few searches that read results. Options: `CS_PROBE_PX` (0/1 preload the Xapian database), `CS_PROBE_DR` (dirent ranges
//!   preloaded), `CS_PROBE_DC` (dirent cache limit), `CS_PROBE_CLUSTER_MB` (process-wide cluster cache limit).
//! - `zim_crate_reader_cost`: the private bytes the Rust `zim` crate reader (`ZimSource::open`, used by `cs_read` and
//!   `zim_get`) holds per ZIM after opening it and reading entries.
//!
//! Private bytes are the process's PrivateUsage on Windows; elsewhere the measurement prints 0.

#![cfg(zimx)]

use cache_search::zimsrc::ZimSource;
use cache_search::zimx::{OpenOpts, Zimx};
use std::path::Path;
use std::time::Duration;

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

fn settled() -> u64 {
    std::thread::sleep(Duration::from_millis(700));
    private_bytes()
}

fn env_n(k: &str) -> Option<u64> {
    std::env::var(k).ok().and_then(|v| v.parse().ok())
}

const QUERIES: [&str; 4] = ["water", "radio antenna", "emergency", "history"];

#[test]
#[ignore]
fn archive_probe() {
    let Ok(list) = std::env::var("CS_PROBE_ZIMS") else {
        eprintln!("CS_PROBE_ZIMS not set");
        return;
    };
    let opts = OpenOpts {
        preload_xapian: env_n("CS_PROBE_PX").map(|v| v != 0),
        preload_dirent_ranges: env_n("CS_PROBE_DR").map(|v| v as u32),
        dirent_cache: env_n("CS_PROBE_DC"),
    };
    if let Some(mb) = env_n("CS_PROBE_CLUSTER_MB") {
        cache_search::zimx::set_cluster_cache_max(mb * 1024 * 1024);
    }
    let mut open = Vec::new();
    let start = settled();
    for path in list.split(';').filter(|s| !s.is_empty()) {
        let name = Path::new(path).file_name().unwrap().to_string_lossy().to_string();
        let entries = ZimSource::open(Path::new(path)).map(|s| s.entry_count()).unwrap_or(0);
        let before = settled();
        let z = Zimx::open_with(Path::new(path), &opts).unwrap();
        let a_open = settled();
        let _ = z.prewarm(true, true);
        let b_searchers = settled();
        let mut hits = Vec::new();
        for q in QUERIES {
            match z.search(q, 0, 10) {
                Ok((h, total)) => hits.push(format!("{}:{}:{}", h.len(), total, h.first().map(|x| x.path.as_str()).unwrap_or(""))),
                Err(e) => hits.push(format!("ERR {}", e.message)),
            }
        }
        let sugg = z.suggest("wa", 5).map(|v| v.len() as i64).unwrap_or(-1);
        let c_read = settled();
        let (dcur, dmax) = z.dirent_cache();
        let (ccur, cmax) = cache_search::zimx::cluster_cache();
        println!(
            "PROBE {}",
            serde_json::json!({"zim": name, "entries": entries, "before": before, "open": a_open as i64 - before as i64, "searchers": b_searchers as i64 - a_open as i64,
                "read": c_read as i64 - b_searchers as i64, "total": c_read as i64 - before as i64, "dirent_cur": dcur, "dirent_max": dmax,
                "cluster_cur": ccur, "cluster_max": cmax, "hits": hits, "suggest": sugg})
        );
        open.push(z);
    }
    let end = settled();
    println!("PROBE_ALL {}", serde_json::json!({"start": start, "all_open": end, "delta": end as i64 - start as i64, "n": open.len()}));
    drop(open);
    println!("PROBE_CLOSED {}", settled() as i64 - start as i64);
}

#[test]
#[ignore]
fn zim_crate_reader_cost() {
    let Ok(list) = std::env::var("CS_PROBE_ZIMS") else {
        eprintln!("CS_PROBE_ZIMS not set");
        return;
    };
    let mut keep = Vec::new();
    let start = settled();
    for path in list.split(';').filter(|s| !s.is_empty()) {
        let name = Path::new(path).file_name().unwrap().to_string_lossy().to_string();
        let before = settled();
        let src = ZimSource::open(Path::new(path)).unwrap();
        let opened = settled();
        // what cs_read and zim_get do: a path lookup and an article read, over spread-out entries
        let n = src.zim.header.article_count.max(1) as u64;
        let mut read = 0usize;
        for i in 0..40u64 {
            if let Ok(e) = src.zim.get_by_url_index((i * n / 40) as u32) {
                if let Ok(Some(c)) = src.zim.entry_content(&e) {
                    read += c.to_vec().map(|v| v.len()).unwrap_or(0);
                }
            }
        }
        let _ = src.main_page_path();
        let after = settled();
        println!(
            "ZIMCRATE {}",
            serde_json::json!({"zim": name, "open": opened as i64 - before as i64, "after_40_reads": after as i64 - opened as i64, "bytes_read": read})
        );
        keep.push(src);
    }
    let end = settled();
    println!("ZIMCRATE_ALL {}", serde_json::json!({"n": keep.len(), "delta": end as i64 - start as i64}));
}
