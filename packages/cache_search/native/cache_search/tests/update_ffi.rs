//! `update_library` and the library manifest, without any Qdrant server.
//!
//! A real partial snapshot is made locally: shard v1 is built with the read-write EdgeShard, copied to v2, v2 is
//! changed (points added, deleted and rewritten), and a partial snapshot of v2 against v1's manifest is written
//! with Qdrant's own per-segment snapshot code (`SnapshotEntry::take_snapshot`, the streamable format the
//! server's `.../snapshot/partial/create` uses) plus an empty-WAL folder, as the server does for a snapshot
//! without WAL. What these tests do not cover: the server's own endpoint, the proxying and flushing it does on a
//! live shard, and the HTTP transfer (see DESIGN.md, To verify).

use cache_search::ffi::*;
use cache_search::job::Job;
use cache_search::libupdate;
use cache_search::library::{ensure_init, shard_open_count, MANIFEST_FILE};
use common::tar_ext::BuilderExt;
use edge::{
    Distance, EdgeConfig, EdgeOptimizersConfig, EdgeShard, EdgeVectorParamsBuilder, PointId, PointInsertOperations,
    PointOperations, PointStruct, UpdateOperation,
};
use segment::data_types::manifest::SegmentManifest;
use segment::entry::SnapshotEntry;
use segment::segment_constructor::load_segment;
use segment::types::SnapshotFormat;
use serde_json::{json, Value};
use shard::snapshots::snapshot_manifest::SnapshotManifest;
use std::collections::BTreeSet;
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::atomic::AtomicBool;
use std::time::{Duration, Instant};

const DIMS: usize = 16;
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
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-updtest-{}-{}", std::process::id(), name));
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

fn random_vec(seed: u64) -> Vec<f32> {
    let mut s = seed.wrapping_mul(7919).wrapping_add(13);
    let mut v: Vec<f32> = (0..DIMS)
        .map(|_| {
            s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            ((s >> 40) as f32 / (1u64 << 24) as f32) * 2.0 - 1.0
        })
        .collect();
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    v.iter_mut().for_each(|x| *x /= n);
    v
}

fn payload(i: u64, text: &str) -> Value {
    json!({"title": format!("Book {}", i / 20), "content": format!("Paragraph {i}. {text} Another sentence follows here."),
           "_start_page": i % 500 + 1})
}

fn upsert(shard: &EdgeShard, ids: std::ops::RangeInclusive<u64>, text: &str) {
    let pts: Vec<_> = ids.map(|i| PointStruct::new(i, random_vec(i), payload(i, text)).0).collect();
    shard
        .update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(pts))))
        .unwrap();
}

fn delete(shard: &EdgeShard, ids: std::ops::RangeInclusive<u64>) {
    let ids = ids.map(PointId::NumId).collect();
    shard.update(UpdateOperation::PointOperation(PointOperations::DeletePoints { ids })).unwrap();
}

fn config(small_segments: bool) -> EdgeConfig {
    let b = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).build());
    if small_segments {
        // make the optimizers index even a tiny segment, so optimize() replaces segments
        b.optimizers(EdgeOptimizersConfig { indexing_threshold: Some(1), default_segment_number: Some(2), ..Default::default() })
            .build()
    } else {
        b.build()
    }
}

/// Library v1: points 1..=300.
fn build_v1(dir: &Path, optimize: bool) {
    ensure_init();
    let shard = EdgeShard::new(dir, config(optimize)).unwrap();
    upsert(&shard, 1..=150, "Original text.");
    upsert(&shard, 151..=300, "Original text.");
    if optimize {
        shard.optimize().unwrap();
    }
    shard.flush().unwrap();
    drop(shard);
    let _ = std::fs::remove_file(dir.join(MANIFEST_FILE));
}

/// v2 = v1 plus 301..=320, minus 1..=10, with point 50 rewritten.
fn change_to_v2(dir: &Path, optimize: bool) {
    let shard = EdgeShard::load(dir, None).unwrap();
    upsert(&shard, 301..=320, "Brand new text.");
    delete(&shard, 1..=10);
    upsert(&shard, 50..=50, "Rewritten text CHANGED.");
    if optimize {
        shard.optimize().unwrap();
    }
    shard.flush().unwrap();
    drop(shard);
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let t = to.join(e.file_name());
        if e.path().is_dir() {
            copy_dir(&e.path(), &t);
        } else {
            std::fs::copy(e.path(), &t).unwrap();
        }
    }
}

fn segment_ids(dir: &Path) -> BTreeSet<String> {
    std::fs::read_dir(dir.join("segments"))
        .unwrap()
        .map(|e| e.unwrap())
        .filter(|e| e.path().is_dir() && !e.file_name().to_string_lossy().starts_with('.'))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect()
}

fn listed_in_manifest_file(dir: &Path) -> BTreeSet<String> {
    let v: Value = serde_json::from_slice(&std::fs::read(dir.join(MANIFEST_FILE)).unwrap()).unwrap();
    for (_, s) in v.as_object().unwrap() {
        assert_eq!(s, "active");
    }
    v.as_object().unwrap().keys().cloned().collect()
}

/// A partial snapshot of the (closed) shard at `shard_dir` against `against`, written to `out`: what the server
/// streams for `POST .../snapshot/partial/create`.
fn make_partial_snapshot(shard_dir: &Path, against: &SnapshotManifest, out: &Path) {
    let tar = BuilderExt::new_seekable_owned(std::fs::File::create(out).unwrap());
    let seg_tar = tar.descend(Path::new("segments")).unwrap();
    let temp = shard_dir.join("snapshot-temp");
    std::fs::create_dir_all(&temp).unwrap();
    for id in segment_ids(shard_dir) {
        let seg = load_segment(&shard_dir.join("segments").join(&id), uuid::Uuid::parse_str(&id).unwrap(), None, &AtomicBool::new(false), false).unwrap();
        let m = against.get(&id).cloned().unwrap_or_else(|| SegmentManifest::empty(id.clone()));
        seg.take_snapshot(&temp, &seg_tar, SnapshotFormat::Streamable, Some(&m)).unwrap();
    }
    drop(seg_tar);
    // the server archives an empty WAL (no WAL in a partial snapshot): an empty folder is enough for the merge
    let wal = temp.join("empty-wal");
    std::fs::create_dir_all(&wal).unwrap();
    std::fs::write(wal.join("placeholder"), b"").unwrap();
    tar.blocking_append_dir_all(&wal, Path::new("wal")).unwrap();
    tar.blocking_finish().unwrap();
    std::fs::remove_dir_all(&temp).unwrap();
}

fn settings() -> Value {
    json!({"format":1,"library_id":"t","title":"Test Lib",
           "fields":{"title":"title","text":"content","page":"_start_page"},
           "leave_out":[],"embedding":{"vector":"","model":MODEL,"sha256":"x","dims":DIMS},"keyword_index":"auto"})
}

fn open(path: &Path) -> *mut cache_search::handle::Handle {
    let cfg = cstr(&json!({"sources":[{"kind":"library","path":path.to_str().unwrap(),"index_dir":"/nonexistent/idx","settings":settings()}]}).to_string());
    let h = unsafe { cs_open(cfg.as_ptr()) };
    assert!(!h.is_null(), "cs_open failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    wait_ready(h);
    h
}

fn status(h: *mut cache_search::handle::Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap()
}

/// Poll cs_status until the library is neither opening nor updating.
fn wait_ready(h: *mut cache_search::handle::Handle) -> Value {
    let t0 = Instant::now();
    loop {
        let v = status(h);
        if v["sources"].as_array().unwrap().iter().all(|s| s["opening"] == false && s["updating"] == false) {
            return v;
        }
        assert!(t0.elapsed().as_secs() < 120, "library did not become ready: {v}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn search(h: *mut cache_search::handle::Handle, v: &[f32], k: usize) -> Value {
    let opts = json!({"k":k,"query_vector":{"model":MODEL,"vector":v}});
    serde_json::from_str(&take(unsafe { cs_search(h, cstr("ignored").as_ptr(), cstr(&opts.to_string()).as_ptr()) }).expect("search result")).unwrap()
}

fn first_addr(r: &Value) -> String {
    r["results"][0]["address"].as_str().unwrap().to_string()
}

fn read(h: *mut cache_search::handle::Handle, addr: &str) -> Result<Value, String> {
    match take(unsafe { cs_read(h, cstr(addr).as_ptr(), 6000) }) {
        Some(s) => Ok(serde_json::from_str(&s).unwrap()),
        None => {
            let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(h) }).unwrap()).unwrap();
            Err(e["code"].as_str().unwrap().to_string())
        }
    }
}

fn start_job(params: Value) -> *mut Job {
    start_kind("update_library", params)
}

fn start_kind(kind: &str, params: Value) -> *mut Job {
    let j = unsafe { cs_job_start(cstr(kind).as_ptr(), cstr(&params.to_string()).as_ptr()) };
    assert!(!j.is_null(), "cs_job_start failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    j
}

fn progress(j: *mut Job) -> Value {
    serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap()
}

fn wait_job(j: *mut Job) -> Value {
    let t0 = Instant::now();
    loop {
        let p = progress(j);
        if p["state"] != "running" {
            return p;
        }
        assert!(t0.elapsed().as_secs() < 300, "job did not finish: {p}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn start_err(params: Value) -> Value {
    start_kind_err("update_library", params)
}

fn start_kind_err(kind: &str, params: Value) -> Value {
    let j = unsafe { cs_job_start(cstr(kind).as_ptr(), cstr(&params.to_string()).as_ptr()) };
    assert!(j.is_null(), "expected cs_job_start to fail");
    serde_json::from_str(&take(unsafe { cs_last_error(ptr::null_mut()) }).unwrap()).unwrap()
}

struct Fixture {
    _tmp: TempDir,
    lib: PathBuf,
    v2: PathBuf,
    snapshot: PathBuf,
    manifest: PathBuf,
    v1_segments: BTreeSet<String>,
}

/// v1 library, its manifest file, v2 library and the partial snapshot v1 -> v2.
fn fixture(name: &str, optimize: bool) -> Fixture {
    let tmp = TempDir::new(name);
    let lib = tmp.0.join("lib_shard");
    build_v1(&lib, optimize);
    // the manifest comes from the library function the CLI uses
    let (json_text, n) = libupdate::library_manifest(&lib).unwrap();
    let manifest = tmp.0.join("v1-manifest.json");
    std::fs::write(&manifest, &json_text).unwrap();
    assert_eq!(n, segment_ids(&lib).len());
    assert_eq!(listed_in_manifest_file(&lib), segment_ids(&lib), "library_manifest keeps segments_manifest.json in step");
    let v1_segments = segment_ids(&lib);
    let v2 = tmp.0.join("v2_shard");
    copy_dir(&lib, &v2);
    change_to_v2(&v2, optimize);
    let against: SnapshotManifest = serde_json::from_str(&json_text).unwrap();
    let snapshot = tmp.0.join("partial.snapshot");
    make_partial_snapshot(&v2, &against, &snapshot);
    Fixture { _tmp: tmp, lib, v2, snapshot, manifest, v1_segments }
}

fn job_params(f: &Fixture, hold_ms: u64) -> Value {
    json!({"library_path": f.lib.to_str().unwrap(), "snapshot_path": f.snapshot.to_str().unwrap(),
           "snapshot_manifest_path": f.manifest.to_str().unwrap(), "hold_ms": hold_ms})
}

fn check_updated(f: &Fixture, h: *mut cache_search::handle::Handle) {
    let v = status(h);
    let s = &v["sources"][0];
    assert_eq!(s["opening"], false);
    assert_eq!(s["updating"], false);
    assert_eq!(s["error"], Value::Null, "{v}");
    assert_eq!(s["docs"], 300 + 20 - 10, "{v}");
    // a new point is found by its own vector; deleted points are gone; the rewritten point has its new text
    assert_eq!(first_addr(&search(h, &random_vec(305), 3)), "lib:t/305");
    assert_eq!(first_addr(&search(h, &random_vec(320), 3)), "lib:t/320");
    assert_eq!(read(h, "lib:t/5").unwrap_err(), "not_found");
    assert_eq!(read(h, "lib:t/10").unwrap_err(), "not_found");
    assert!(read(h, "lib:t/11").is_ok());
    assert!(read(h, "lib:t/50").unwrap()["text"].as_str().unwrap().contains("CHANGED"));
    assert!(read(h, "lib:t/305").unwrap()["text"].as_str().unwrap().contains("Brand new"));
    // segments_manifest.json lists exactly the segments on disk
    assert_eq!(listed_in_manifest_file(&f.lib), segment_ids(&f.lib));
    // the library has every segment v2 has and none that only v1 had (the read-write load that ends the merge
    // may add an empty appendable segment of its own)
    let (now, v2) = (segment_ids(&f.lib), segment_ids(&f.v2));
    assert!(v2.is_subset(&now), "missing {:?}", v2.difference(&now).collect::<Vec<_>>());
    assert!(f.v1_segments.difference(&v2).all(|s| !now.contains(s)), "segments removed in v2 are still there");
    // no leftovers beside the library
    let sibling = f.lib.parent().unwrap().join("lib_shard.cs-update-tmp");
    assert!(!sibling.exists(), "unpack folder left behind");
}

#[test]
fn update_applies_a_real_partial_snapshot() {
    let f = fixture("plain", false);
    let h = open(&f.lib);
    // before: v1
    assert_eq!(status(h)["sources"][0]["docs"], 300);
    assert_eq!(first_addr(&search(h, &random_vec(5), 3)), "lib:t/5");
    assert!(read(h, "lib:t/305").is_err());

    // hold the job for a moment before the apply step so the state in between can be observed
    let j = start_job(job_params(&f, 800));
    let v = status(h);
    let s = &v["sources"][0];
    assert_eq!(s["updating"], true, "{v}");
    assert_eq!(s["opening"], false, "{v}");
    assert_eq!(s["id"], "t");
    assert_eq!(s["title"], "Test Lib");
    // search skips the library meanwhile, and a read says busy
    let r = search(h, &random_vec(5), 3);
    assert_eq!(r["results"], json!([]), "{r}");
    assert_eq!(read(h, "lib:t/5").unwrap_err(), "busy");
    let p = progress(j);
    assert_eq!(p["state"], "running");
    assert_eq!(p["total"], 5);

    let done = wait_job(j);
    assert_eq!(done["state"], "done", "{done}");
    assert_eq!(done["done"], 5);
    assert_eq!(done["total"], 5);
    assert_eq!(done["error"], Value::Null);
    wait_ready(h);
    check_updated(&f, h);
    unsafe { cs_job_free(j) };
    unsafe { cs_close(h) };
}

#[test]
fn update_with_segments_added_and_removed() {
    let f = fixture("optimized", true);
    // the optimizer replaced segments: the partial snapshot adds and removes whole segments
    let v2_segments = segment_ids(&f.v2);
    assert!(!v2_segments.is_subset(&f.v1_segments), "v2 should have segments v1 lacks");
    assert!(!f.v1_segments.is_subset(&v2_segments), "v1 should have segments v2 lacks");
    let h = open(&f.lib);
    let j = start_job(job_params(&f, 0));
    let done = wait_job(j);
    assert_eq!(done["state"], "done", "{done}");
    wait_ready(h);
    check_updated(&f, h);
    unsafe { cs_job_free(j) };
    unsafe { cs_close(h) };
}

#[test]
fn update_without_any_handle() {
    let f = fixture("nohandle", false);
    let j = start_job(job_params(&f, 0));
    let done = wait_job(j);
    assert_eq!(done["state"], "done", "{done}");
    unsafe { cs_job_free(j) };
    let h = open(&f.lib);
    check_updated(&f, h);
    unsafe { cs_close(h) };
}

#[test]
fn cancel_before_apply_leaves_the_library_as_it_was() {
    let f = fixture("cancel", false);
    let h = open(&f.lib);
    let j = start_job(job_params(&f, 60_000));
    // wait until the job is in its hold (snapshot unpacked, step 2 done), then cancel
    let t0 = Instant::now();
    while progress(j)["done"].as_u64().unwrap() < 2 {
        assert!(t0.elapsed().as_secs() < 60);
        std::thread::sleep(Duration::from_millis(5));
    }
    assert_eq!(status(h)["sources"][0]["updating"], true);
    assert_eq!(unsafe { cs_job_cancel(j) }, 0);
    let p = wait_job(j);
    assert_eq!(p["state"], "cancelled", "{p}");
    wait_ready(h);
    // still v1, searchable again
    assert_eq!(status(h)["sources"][0]["docs"], 300);
    assert_eq!(first_addr(&search(h, &random_vec(5), 3)), "lib:t/5");
    assert_eq!(segment_ids(&f.lib), f.v1_segments);
    assert!(!f.lib.parent().unwrap().join("lib_shard.cs-update-tmp").exists());
    unsafe { cs_job_free(j) };
    unsafe { cs_close(h) };
}

#[test]
fn second_update_and_index_build_are_busy_while_one_runs() {
    let f = fixture("busy", false);
    let j = start_job(job_params(&f, 60_000));
    let e = start_err(job_params(&f, 0));
    assert_eq!(e["code"], "busy", "{e}");
    // an index build on the library is refused too
    let p = json!({"library_path": f.lib.to_str().unwrap(), "index_dir": f.lib.parent().unwrap().join("idx").to_str().unwrap()});
    let jb = unsafe { cs_job_start(cstr("index_library").as_ptr(), cstr(&p.to_string()).as_ptr()) };
    assert!(jb.is_null());
    let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(ptr::null_mut()) }).unwrap()).unwrap();
    assert_eq!(e["code"], "busy");
    // the manifest function refuses as well
    assert_eq!(libupdate::library_manifest(&f.lib).unwrap_err().code.as_str(), "busy");
    unsafe { cs_job_cancel(j) };
    assert_eq!(wait_job(j)["state"], "cancelled");
    unsafe { cs_job_free(j) };
    // after the job a new update can start
    let j = start_job(job_params(&f, 0));
    assert_eq!(wait_job(j)["state"], "done");
    unsafe { cs_job_free(j) };
}

#[test]
fn bad_parameters_are_reported_by_cs_job_start() {
    let f = fixture("params", false);
    let ok = job_params(&f, 0);
    let with = |k: &str, v: Value| {
        let mut p = ok.clone();
        p[k] = v;
        p
    };
    assert_eq!(start_err(json!({"library_path": "x"}))["code"], "bad_json");
    assert_eq!(start_err(with("library_path", json!("")))["code"], "bad_json");
    assert_eq!(start_err(with("library_path", json!("/nonexistent/lib")))["code"], "not_found");
    assert_eq!(start_err(with("snapshot_path", json!("/nonexistent/s.snapshot")))["code"], "not_found");
    assert_eq!(start_err(with("snapshot_manifest_path", json!("/nonexistent/m.json")))["code"], "not_found");
    // a manifest file that is not a manifest
    let junk = f.lib.parent().unwrap().join("junk.json");
    std::fs::write(&junk, b"[1,2").unwrap();
    assert_eq!(start_err(with("snapshot_manifest_path", json!(junk.to_str().unwrap())))["code"], "bad_json");
    // a manifest of another library: segments do not match the folder
    let empty = f.lib.parent().unwrap().join("other.json");
    std::fs::write(&empty, b"{}").unwrap();
    assert_eq!(start_err(with("snapshot_manifest_path", json!(empty.to_str().unwrap())))["code"], "bad_json");
    // nothing was marked as updating by the failures
    let h = open(&f.lib);
    assert_eq!(status(h)["sources"][0]["updating"], false);
    unsafe { cs_close(h) };
}

#[test]
fn corrupt_snapshot_fails_the_job_and_the_library_still_works() {
    let f = fixture("corrupt", false);
    // not a tar at all
    let bad = f.lib.parent().unwrap().join("bad.snapshot");
    std::fs::write(&bad, vec![7u8; 4096]).unwrap();
    let h = open(&f.lib);
    let mut p = job_params(&f, 0);
    p["snapshot_path"] = json!(bad.to_str().unwrap());
    let j = start_job(p);
    let done = wait_job(j);
    assert_eq!(done["state"], "failed", "{done}");
    assert_eq!(done["error"]["code"], "io", "{done}");
    unsafe { cs_job_free(j) };
    // the library is reopened from what is on disk: v1, untouched
    wait_ready(h);
    let v = status(h);
    assert_eq!(v["sources"][0]["docs"], 300, "{v}");
    assert_eq!(v["sources"][0]["error"], Value::Null);
    assert_eq!(first_addr(&search(h, &random_vec(5), 3)), "lib:t/5");
    assert_eq!(segment_ids(&f.lib), f.v1_segments);
    assert!(!f.lib.parent().unwrap().join("lib_shard.cs-update-tmp").exists());

    // a truncated real snapshot
    let bytes = std::fs::read(&f.snapshot).unwrap();
    let cut = f.lib.parent().unwrap().join("cut.snapshot");
    std::fs::write(&cut, &bytes[..bytes.len() / 2]).unwrap();
    let mut p = job_params(&f, 0);
    p["snapshot_path"] = json!(cut.to_str().unwrap());
    let j = start_job(p);
    let done = wait_job(j);
    assert_eq!(done["state"], "failed", "{done}");
    unsafe { cs_job_free(j) };
    wait_ready(h);
    assert_eq!(status(h)["sources"][0]["docs"], 300);

    // a full snapshot (every segment without a manifest) is not a partial snapshot
    let full = f.lib.parent().unwrap().join("full.snapshot");
    make_partial_snapshot(&f.v2, &SnapshotManifest::default(), &full);
    let no_manifest = {
        // the same archive, but its segments carry no segment manifests: unpack, strip, repack
        let dir = f.lib.parent().unwrap().join("strip");
        std::fs::create_dir_all(&dir).unwrap();
        common::tar_unpack::tar_unpack_file(&full, &dir).unwrap();
        for e in std::fs::read_dir(dir.join("segments")).unwrap() {
            let _ = std::fs::remove_file(e.unwrap().path().join("files").join("segment_manifest.json"));
        }
        let out = f.lib.parent().unwrap().join("full-stripped.snapshot");
        let tar = BuilderExt::new_seekable_owned(std::fs::File::create(&out).unwrap());
        tar.blocking_append_dir_all(&dir, Path::new("")).unwrap();
        tar.blocking_finish().unwrap();
        out
    };
    let mut p = job_params(&f, 0);
    p["snapshot_path"] = json!(no_manifest.to_str().unwrap());
    let j = start_job(p);
    let done = wait_job(j);
    assert_eq!(done["state"], "failed", "{done}");
    assert_eq!(done["error"]["code"], "unsupported", "{done}");
    unsafe { cs_job_free(j) };
    wait_ready(h);
    assert_eq!(status(h)["sources"][0]["docs"], 300);
    assert_eq!(segment_ids(&f.lib), f.v1_segments);

    // and the good snapshot still applies afterwards
    let j = start_job(job_params(&f, 0));
    assert_eq!(wait_job(j)["state"], "done");
    unsafe { cs_job_free(j) };
    wait_ready(h);
    check_updated(&f, h);
    unsafe { cs_close(h) };
}

#[test]
fn failed_reopen_is_reported_as_a_failed_source() {
    // the library disappears while the job holds (after the snapshot is unpacked): the apply fails, and the
    // handle's reopen fails too
    let f = fixture("gone", false);
    let h = open(&f.lib);
    let j = start_job(job_params(&f, 3000));
    let t0 = Instant::now();
    while progress(j)["done"].as_u64().unwrap() < 2 {
        assert!(t0.elapsed().as_secs() < 60);
        std::thread::sleep(Duration::from_millis(5));
    }
    std::fs::remove_dir_all(&f.lib).unwrap();
    let done = wait_job(j);
    assert_eq!(done["state"], "failed", "{done}");
    unsafe { cs_job_free(j) };
    // the handle reopens from disk, which does not work: the source is reported failed
    let v = wait_ready(h);
    let s = &v["sources"][0];
    assert!(s["error"].is_object(), "{v}");
    unsafe { cs_close(h) };
}

#[test]
fn library_manifest_refuses_an_open_library_and_matches_the_segments() {
    let f = fixture("manifest", false);
    let h = open(&f.lib);
    let e = libupdate::library_manifest(&f.lib).unwrap_err();
    assert_eq!(e.code.as_str(), "busy", "{e}");
    unsafe { cs_close(h) };
    let (text, n) = libupdate::library_manifest(&f.lib).unwrap();
    let m: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(m.as_object().unwrap().len(), n);
    assert_eq!(m.as_object().unwrap().keys().cloned().collect::<BTreeSet<_>>(), segment_ids(&f.lib));
    assert!(libupdate::library_manifest(Path::new("/nonexistent/lib")).is_err());
    // the library still opens read-only afterwards
    let h = open(&f.lib);
    assert_eq!(status(h)["sources"][0]["docs"], 300);
    unsafe { cs_close(h) };
}

// ---- one open per update, the shard handed to every handle ----------------------------------------------------

#[test]
fn update_opens_the_library_exactly_once_for_every_handle() {
    let f = fixture("once", false);
    // two handles with the library open, and a third source-less run below; h2 is never looked at while the job runs
    let (h1, h2) = (open(&f.lib), open(&f.lib));
    let before = shard_open_count(&f.lib);
    assert_eq!(before, 2, "one open per handle");
    let j = start_job(job_params(&f, 300));
    // h1 looks while the update runs (it turns into an updating source); h2 does not
    assert_eq!(status(h1)["sources"][0]["updating"], true);
    let done = wait_job(j);
    assert_eq!(done["state"], "done", "{done}");
    unsafe { cs_job_free(j) };
    wait_ready(h1);
    wait_ready(h2);
    check_updated(&f, h1);
    check_updated(&f, h2);
    assert_eq!(shard_open_count(&f.lib), before + 1, "the job's verifying open is the only open: no handle reopened the library");
    // both handles search the same, updated shard
    assert_eq!(first_addr(&search(h2, &random_vec(320), 3)), "lib:t/320");
    // a handle that opens afterwards opens for itself
    let h3 = open(&f.lib);
    assert_eq!(shard_open_count(&f.lib), before + 2);
    check_updated(&f, h3);
    for h in [h1, h2, h3] {
        unsafe { cs_close(h) };
    }
}

#[test]
fn update_without_handles_opens_once_and_a_failed_update_makes_the_handle_open_again() {
    let f = fixture("once2", false);
    let before = shard_open_count(&f.lib);
    let j = start_job(job_params(&f, 0));
    assert_eq!(wait_job(j)["state"], "done");
    unsafe { cs_job_free(j) };
    assert_eq!(shard_open_count(&f.lib), before + 1, "the check open, with nobody to hand it to");

    // a failed job (not a tar) hands nothing back: the handle opens the library itself, once
    let f = fixture("once3", false);
    let h = open(&f.lib);
    let before = shard_open_count(&f.lib);
    let bad = f.lib.parent().unwrap().join("bad.snapshot");
    std::fs::write(&bad, vec![7u8; 4096]).unwrap();
    let mut p = job_params(&f, 0);
    p["snapshot_path"] = json!(bad.to_str().unwrap());
    let j = start_job(p);
    assert_eq!(wait_job(j)["state"], "failed");
    unsafe { cs_job_free(j) };
    wait_ready(h);
    assert_eq!(status(h)["sources"][0]["docs"], 300);
    assert_eq!(shard_open_count(&f.lib), before + 1);
    unsafe { cs_close(h) };
}

// ---- the library_manifest job ----------------------------------------------------------------------------------

fn manifest_params(f: &Fixture, out: &Path, hold_ms: u64) -> Value {
    json!({"library_path": f.lib.to_str().unwrap(), "out_path": out.to_str().unwrap(), "hold_ms": hold_ms})
}

#[test]
fn library_manifest_job_writes_the_same_manifest_as_the_cli_helper() {
    let f = fixture("mjob", false);
    // what `cs library-manifest --out` writes: the helper's JSON, verbatim (library closed, no handle)
    let (cli_text, cli_n) = libupdate::library_manifest(&f.lib).unwrap();
    let cli_file = f.lib.parent().unwrap().join("cli-manifest.json");
    std::fs::write(&cli_file, &cli_text).unwrap();

    let h = open(&f.lib);
    let before = shard_open_count(&f.lib);
    let out = f.lib.parent().unwrap().join("job-manifest.json");
    let j = start_kind("library_manifest", manifest_params(&f, &out, 600));
    // the library is closed meanwhile: marked updating, search skips it
    let v = status(h);
    assert_eq!(v["sources"][0]["updating"], true, "{v}");
    assert_eq!(search(h, &random_vec(5), 3)["results"], json!([]));
    assert_eq!(read(h, "lib:t/5").unwrap_err(), "busy");
    let p = progress(j);
    assert_eq!(p["state"], "running");
    assert_eq!(p["total"], 5);
    let done = wait_job(j);
    assert_eq!(done["state"], "done", "{done}");
    assert_eq!((done["done"].as_u64(), done["total"].as_u64()), (Some(5), Some(5)));
    unsafe { cs_job_free(j) };

    assert_eq!(String::from_utf8(std::fs::read(&out).unwrap()).unwrap(), String::from_utf8(std::fs::read(&cli_file).unwrap()).unwrap(), "same bytes as the CLI subcommand");
    let m: Value = serde_json::from_slice(&std::fs::read(&out).unwrap()).unwrap();
    assert_eq!(m.as_object().unwrap().len(), cli_n);
    assert_eq!(m.as_object().unwrap().keys().cloned().collect::<BTreeSet<_>>(), segment_ids(&f.lib));
    assert_eq!(listed_in_manifest_file(&f.lib), segment_ids(&f.lib));
    // no temporary file left next to the output
    let stray: Vec<_> = std::fs::read_dir(f.lib.parent().unwrap())
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".tmp"))
        .collect();
    assert!(stray.is_empty(), "{stray:?}");

    // the handle has its library back without opening it again, and it still searches
    wait_ready(h);
    let v = status(h);
    assert_eq!(v["sources"][0]["docs"], 300, "{v}");
    assert_eq!(v["sources"][0]["error"], Value::Null);
    assert_eq!(first_addr(&search(h, &random_vec(5), 3)), "lib:t/5");
    assert_eq!(shard_open_count(&f.lib), before + 1, "one open: the job's");
    unsafe { cs_close(h) };

    // the manifest is usable: it describes the library for an update (prepare accepts it)
    let again = libupdate::library_manifest(&f.lib).unwrap().0;
    assert_eq!(again, cli_text, "the manifest of an unchanged library is stable");
}

#[test]
fn library_manifest_job_is_busy_cancellable_and_checks_its_parameters() {
    let f = fixture("mjob2", false);
    let out = f.lib.parent().unwrap().join("m.json");
    let h = open(&f.lib);
    let j = start_kind("library_manifest", manifest_params(&f, &out, 5000));
    // a second manifest job and an update refuse (busy) while it runs
    assert_eq!(start_kind_err("library_manifest", manifest_params(&f, &out, 0))["code"], "busy");
    assert_eq!(start_err(job_params(&f, 0))["code"], "busy");
    // cancelled before the read-write load: nothing is written and the library comes back unchanged
    unsafe { cs_job_cancel(j) };
    assert_eq!(wait_job(j)["state"], "cancelled");
    unsafe { cs_job_free(j) };
    assert!(!out.exists());
    wait_ready(h);
    assert_eq!(status(h)["sources"][0]["docs"], 300);
    assert_eq!(first_addr(&search(h, &random_vec(5), 3)), "lib:t/5");
    unsafe { cs_close(h) };

    let lib = f.lib.to_str().unwrap();
    assert_eq!(start_kind_err("library_manifest", json!({"library_path": "/nonexistent/lib", "out_path": out.to_str().unwrap()}))["code"], "not_found");
    assert_eq!(start_kind_err("library_manifest", json!({"library_path": lib, "out_path": ""}))["code"], "bad_json");
    assert_eq!(start_kind_err("library_manifest", json!({"library_path": lib}))["code"], "bad_json");
    let inside = f.lib.join("m.json");
    assert_eq!(start_kind_err("library_manifest", json!({"library_path": lib, "out_path": inside.to_str().unwrap()}))["code"], "bad_json");
    assert_eq!(start_kind_err("library_manifest", json!({"library_path": lib, "out_path": "/nonexistent/dir/m.json"}))["code"], "not_found");
    assert_eq!(start_kind_err("library_manifest", json!({"library_path": lib, "out_path": f.lib.parent().unwrap().to_str().unwrap()}))["code"], "bad_json");
    // none of those marked the library busy
    let j = start_kind("library_manifest", manifest_params(&f, &out, 0));
    assert_eq!(wait_job(j)["state"], "done");
    unsafe { cs_job_free(j) };
    assert!(out.exists());
}
