//! `set_sources` opens the ZIMs of a config side by side: the sources come out in config order, a ZIM that cannot be opened
//! is a failed source in its place (the others open), and the open reports how long each step took.
//!
//! Needs CS_TEST_ZIM_DIR (a folder of ZIMs; the first few are used) and a build with libzim; otherwise it prints why and
//! returns. The pool itself (order, bound, overlap) is covered without ZIMs by the unit tests in openpool.rs. The ignored
//! `open_bench` is the measurement: CS_BENCH_ZIM_DIR (every .zim in it) and CS_OPEN_THREADS (1 = serial).

use cache_search::handle::{Handle, Source};
use serde_json::{json, Value};
use std::path::PathBuf;

fn zims_in(var: &str, max: usize) -> Option<Vec<PathBuf>> {
    let Some(dir) = std::env::var(var).ok().filter(|s| !s.is_empty()) else {
        eprintln!("{var} not set: skipping");
        return None;
    };
    let mut v: Vec<PathBuf> = std::fs::read_dir(dir)
        .ok()?
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().map(|x| x == "zim").unwrap_or(false))
        .collect();
    v.sort();
    v.truncate(max);
    if v.is_empty() {
        eprintln!("{var}: no .zim files: skipping");
        return None;
    }
    Some(v)
}

fn config(paths: &[String]) -> String {
    json!({"sources": paths.iter().map(|p| json!({"kind": "zim", "path": p})).collect::<Vec<_>>()}).to_string()
}

/// What each source is, in order: a ZIM's id, or a failed source's path.
fn shape(h: &Handle) -> Vec<String> {
    h.sources
        .iter()
        .map(|s| match s {
            Source::Zim(z) => format!("zim {}", z.src.id),
            Source::Failed { path, .. } => format!("failed {}", path.display()),
            _ => "other".to_string(),
        })
        .collect()
}

#[test]
fn parallel_open_keeps_order_and_failures() {
    let Some(zims) = zims_in("CS_TEST_ZIM_DIR", 8) else { return };
    let tmp = std::env::temp_dir().join(format!("cs-open-parallel-{}", std::process::id()));
    std::fs::create_dir_all(&tmp).unwrap();
    let garbage = tmp.join("garbage.zim");
    std::fs::write(&garbage, b"not a zim file at all").unwrap();
    let missing = tmp.join("missing.zim");
    // good, garbage, good..., missing, good...: the failures sit among the good ones
    let mut paths: Vec<String> = Vec::new();
    for (i, z) in zims.iter().enumerate() {
        if i == 1 {
            paths.push(garbage.to_string_lossy().into_owned());
        }
        if i == 2 {
            paths.push(missing.to_string_lossy().into_owned());
        }
        paths.push(z.to_string_lossy().into_owned());
    }
    // the serial reference: each ZIM opened on its own, one after another
    let expect: Vec<String> = paths
        .iter()
        .map(|p| match cache_search::zimsrc::ZimSource::open(std::path::Path::new(p)) {
            Ok(z) => format!("zim {}", z.id),
            Err(_) => format!("failed {p}"),
        })
        .collect();
    let h = Handle::open(&config(&paths)).expect("a bad ZIM does not fail the open");
    assert_eq!(shape(&h), expect);
    assert!(expect.iter().any(|e| e.starts_with("failed")) && expect.iter().any(|e| e.starts_with("zim")));
    // the failed ones say why, as before
    let mut h = h;
    let st: Value = serde_json::from_str(&h.status_json()).unwrap();
    let list = st["sources"].as_array().unwrap();
    assert_eq!(list.len(), paths.len());
    for (s, p) in list.iter().zip(&paths) {
        if expect.contains(&format!("failed {p}")) {
            assert!(s["error"].is_object(), "{p}: {s}");
        }
    }
    // the timing lines are there
    let t = st["open_timings"].as_array().unwrap();
    assert_eq!(t.len(), 2);
    assert!(t[0].as_str().unwrap().starts_with("core open: "));
    assert!(t[1].as_str().unwrap().contains("total "));
    // a second set_sources with the same list reuses the open ZIMs and keeps the order
    h.set_sources(&config(&paths)).unwrap();
    assert_eq!(shape(&h), expect);
    std::fs::remove_dir_all(&tmp).ok();
}

#[test]
fn duplicate_zim_path_is_a_duplicate_id_error() {
    let Some(zims) = zims_in("CS_TEST_ZIM_DIR", 1) else { return };
    let p = zims[0].to_string_lossy().into_owned();
    let e = Handle::open(&config(&[p.clone(), p])).err().expect("the same ZIM twice fails the call");
    assert!(e.message.contains("duplicate source id"), "{}", e.message);
}

/// The measurement: open every .zim of CS_BENCH_ZIM_DIR (CS_BENCH_MAX caps the count), `CS_BENCH_RUNS` times (default 3), and
/// print the wall time of `Handle::open` and the core's own timing lines. Run with `--release --ignored --nocapture`.
#[test]
#[ignore]
fn open_bench() {
    let max = std::env::var("CS_BENCH_MAX").ok().and_then(|v| v.parse().ok()).unwrap_or(100);
    let Some(zims) = zims_in("CS_BENCH_ZIM_DIR", max) else { return };
    let runs: usize = std::env::var("CS_BENCH_RUNS").ok().and_then(|v| v.parse().ok()).unwrap_or(3);
    let paths: Vec<String> = zims.iter().map(|p| p.to_string_lossy().into_owned()).collect();
    let threads = std::env::var("CS_OPEN_THREADS").unwrap_or_else(|_| "default".into());
    for run in 1..=runs {
        let t = std::time::Instant::now();
        let mut h = Handle::open(&config(&paths)).unwrap();
        let ms = t.elapsed().as_millis();
        let ok = h.sources.iter().filter(|s| matches!(s, Source::Zim(_))).count();
        println!("BENCH threads={threads} run={run} zims={} ok={ok} cs_open_ms={ms}", paths.len());
        let st: Value = serde_json::from_str(&h.status_json()).unwrap();
        if let Some(lines) = st["open_timings"].as_array() {
            for l in lines {
                println!("BENCH   {}", l.as_str().unwrap_or(""));
            }
        }
    }
}
