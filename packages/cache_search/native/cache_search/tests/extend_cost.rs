//! How much an extension of a library's keyword snapshot costs, against building the whole index: a library of about 2,200 pieces (the
//! size of "My books" on the Pixel) is built and sealed, then 9 and 100 more pieces are added and the snapshot is extended; wall and
//! process CPU time are printed per added piece, and the whole build of the final library for comparison. Not part of the normal
//! run (it takes minutes and its numbers depend on the machine): `cargo test --release -p cache_search --test extend_cost -- --ignored
//! --nocapture`.

use cache_ingest::testing::{book, make_pdf, FakeEmbedder, FakePdfEngine, Kind};
use cache_ingest::{Env, Service};
use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::ingest::{service_with, CoreStore};
use cache_search::libindex::{build_library_index, LibBuildParams};
use cache_search::library::{ensure_init, write_segments_manifest};
use edge::{Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Instant;

fn settings() -> Value {
    json!({"format": 1, "library_id": "mine", "title": "Mine", "fields": {"title": "title", "text": "text", "page": "page", "source_type": "source", "link": "link", "document": "doc_id"},
           "leave_out": [], "embedding": {"vector": "", "model": "fake-hash-v1", "dims": 1024}, "keyword_index": "auto", "own": true})
}

fn make_library(root: &Path) -> PathBuf {
    ensure_init();
    let lib = root.join("libraries").join("mine");
    let shard = lib.join("shard");
    std::fs::create_dir_all(&shard).unwrap();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(1024, Distance::Cosine).build()).wal_enabled(false).build();
    let s = EdgeShard::new(&shard, cfg).unwrap();
    s.flush().unwrap();
    drop(s);
    write_segments_manifest(&shard).unwrap();
    std::fs::write(lib.join("cache-library.json"), settings().to_string()).unwrap();
    lib
}

fn service() -> Service {
    service_with(Box::new(|_engines: &Value| {
        Ok(Env {
            pdf: Arc::new(FakePdfEngine::default()),
            embedder: Arc::new(FakeEmbedder::default()),
            store: Arc::new(CoreStore),
            classifier: None,
            clock: Arc::new(|| 1_700_000_000_000),
        })
    }))
}

fn add_book(svc: &Service, root: &Path, lib: &Path, name: &str, topic: &str, pages: usize) -> usize {
    let pdf = root.join("Inbox").join(format!("{name}.pdf"));
    std::fs::create_dir_all(pdf.parent().unwrap()).unwrap();
    std::fs::write(&pdf, make_pdf(Some(name), Kind::Ok, &book(topic, pages))).unwrap();
    let s: Value = serde_json::from_str(&svc.start(&json!({"library_dir": lib, "pdf_path": pdf, "job_dir": root.join("ingest").join(name)}).to_string()).unwrap()).unwrap();
    let job = s["job"].as_u64().unwrap();
    loop {
        let r: Value = serde_json::from_str(&svc.step(&json!({"job": job, "budget_ms": 60_000}).to_string()).unwrap()).unwrap();
        match r["state"].as_str().unwrap() {
            "done" => return r["result"]["pieces"].as_u64().unwrap() as usize,
            "failed" => panic!("failed: {r}"),
            _ => {}
        }
    }
}

/// Process CPU seconds (user + system, every thread).
fn cpu_seconds() -> f64 {
    #[cfg(unix)]
    unsafe {
        let mut u: libc::rusage = std::mem::zeroed();
        libc::getrusage(libc::RUSAGE_SELF, &mut u);
        (u.ru_utime.tv_sec + u.ru_stime.tv_sec) as f64 + (u.ru_utime.tv_usec + u.ru_stime.tv_usec) as f64 / 1e6
    }
    #[cfg(windows)]
    unsafe {
        extern "system" {
            fn GetCurrentProcess() -> isize;
            fn GetProcessTimes(h: isize, creation: *mut u64, exit: *mut u64, kernel: *mut u64, user: *mut u64) -> i32;
        }
        let (mut c, mut e, mut k, mut u) = (0u64, 0u64, 0u64, 0u64);
        GetProcessTimes(GetCurrentProcess(), &mut c, &mut e, &mut k, &mut u);
        (k + u) as f64 / 1e7
    }
}

fn timed<T>(f: impl FnOnce() -> T) -> (T, f64, f64) {
    let (w, c) = (Instant::now(), cpu_seconds());
    let r = f();
    (r, w.elapsed().as_secs_f64(), cpu_seconds() - c)
}

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn job(kind: &str, params: Value) -> Value {
    let c = |s: &str| CString::new(s).unwrap();
    let j = unsafe { cs_job_start(c(kind).as_ptr(), c(&params.to_string()).as_ptr()) };
    assert!(!j.is_null(), "{kind} did not start: {:?}", take(unsafe { cs_last_error(std::ptr::null_mut()) }));
    loop {
        let p: Value = serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap();
        if p["state"] != "running" {
            unsafe { cs_job_free(j) };
            return p;
        }
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
}

fn open(lib: &Path, indexes: &Path) -> *mut Handle {
    let c = |s: &str| CString::new(s).unwrap();
    let src = json!({"kind": "library", "path": lib.join("shard").to_str().unwrap(), "index_dir": lib.join("index").to_str().unwrap(), "settings": settings()});
    let cfg = c(&json!({"sources": [src], "indexes_dir": indexes.to_str().unwrap()}).to_string());
    let h = unsafe { cs_open(cfg.as_ptr()) };
    assert!(!h.is_null());
    loop {
        let st: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
        if st["sources"].as_array().unwrap().iter().all(|s| s["opening"] == false) {
            return h;
        }
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

fn snapshot_ready(h: *mut Handle) {
    for _ in 0..4000 {
        let st: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
        if st["sources"][0]["index"]["location"] == "snapshot" {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(10));
    }
    panic!("no snapshot");
}

#[test]
#[ignore]
fn the_cost_of_extending_a_snapshot_per_piece_against_a_whole_build() {
    let root = std::env::temp_dir().join(format!("cs-extend-cost-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    std::fs::create_dir_all(&root).unwrap();
    let lib = make_library(&root);
    let svc = service();
    let mut pieces = 0usize;
    let mut n = 0usize;
    while pieces < 2200 {
        pieces += add_book(&svc, &root, &lib, &format!("Base {n}"), &format!("subject{n}"), 30);
        n += 1;
    }
    println!("EXTEND-COST base: {n} books, {pieces} pieces");

    // the whole build of the base, for comparison, and the index that gets sealed
    let idx = lib.join("index");
    std::fs::create_dir_all(&idx).unwrap();
    let cfg = settings();
    let heap = 50;
    let (_, w, c) = timed(|| {
        let p = LibBuildParams { threads: Some(1), pace: None, library_path: &lib.join("shard"), settings: Some(&cfg), index_dir: &idx, heap_mb: heap, checkpoint_docs: 200_000 };
        build_library_index(&p, &|_, _| {}, &|| false).unwrap();
    });
    println!("EXTEND-COST whole build of {pieces} pieces, 1 writer thread: wall {w:.2} s, cpu {c:.2} s ({:.2} ms per piece wall)", w * 1000.0 / pieces as f64);

    let indexes = root.join("indexes");
    let h = open(&lib, &indexes);
    let seal = job("index_seal", json!({"indexes_dir": indexes.to_str().unwrap(), "kind": "library", "source_id": "mine"}));
    assert_eq!(seal["state"], "done", "{seal}");
    snapshot_ready(h);
    unsafe { cs_close(h) };

    let mut total = pieces;
    for (label, target) in [("+9", 9usize), ("+100", 100usize)] {
        let mut added = 0usize;
        while added < target {
            added += add_book(&svc, &root, &lib, &format!("Add {label} {n}"), &format!("fresh{n}"), 6);
            n += 1;
        }
        total += added;
        let params = json!({"indexes_dir": indexes.to_str().unwrap(), "library_path": lib.join("shard").to_str().unwrap(), "settings": settings(), "heap_mb": heap});
        let (r, w, c) = timed(|| job("index_extend", params));
        assert_eq!(r["state"], "done", "{r}");
        let docs = r["result"]["added"].as_u64().unwrap_or(0);
        println!(
            "EXTEND-COST extend {label}: {added} pieces added (the job found {docs} missing), wall {w:.3} s, cpu {c:.3} s => {:.2} ms wall and {:.2} ms cpu per added piece; result {}",
            w * 1000.0 / docs.max(1) as f64,
            c * 1000.0 / docs.max(1) as f64,
            r["result"]
        );
    }
    let fresh = lib.join("index-fresh");
    std::fs::create_dir_all(&fresh).unwrap();
    let (_, w, c) = timed(|| {
        let p = LibBuildParams { threads: Some(1), pace: None, library_path: &lib.join("shard"), settings: Some(&cfg), index_dir: &fresh, heap_mb: heap, checkpoint_docs: 200_000 };
        build_library_index(&p, &|_, _| {}, &|| false).unwrap();
    });
    println!("EXTEND-COST whole build of the final {total} pieces: wall {w:.2} s, cpu {c:.2} s");
    let _ = std::fs::remove_dir_all(&root);
}
