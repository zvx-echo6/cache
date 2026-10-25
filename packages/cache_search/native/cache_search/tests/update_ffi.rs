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
    assert!(!libupdate::stage_path(&f.lib).unwrap().exists(), "staging copy left behind");
    assert!(!libupdate::old_path(&f.lib).unwrap().exists(), "old library left behind");
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

// ---- real-copy staging: the library is untouched until the swap, space check, crash leftovers -------------------

/// (number of names, unique file identity) of a file: (nlink, inode) on unix; on Windows the link count and the
/// 64-bit file index from `GetFileInformationByHandle`.
#[cfg(unix)]
fn link_info(path: &Path) -> (u64, u64) {
    use std::os::unix::fs::MetadataExt;
    let md = std::fs::metadata(path).unwrap();
    (md.nlink(), md.ino())
}

#[cfg(windows)]
fn link_info(path: &Path) -> (u64, u64) {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Storage::FileSystem::{GetFileInformationByHandle, BY_HANDLE_FILE_INFORMATION};
    let f = std::fs::File::open(path).unwrap();
    let mut info: BY_HANDLE_FILE_INFORMATION = unsafe { std::mem::zeroed() };
    // SAFETY: `f` is an open file handle and `info` a valid, writable struct.
    let ok = unsafe { GetFileInformationByHandle(f.as_raw_handle() as _, &mut info) };
    assert!(ok != 0, "GetFileInformationByHandle failed: {}", std::io::Error::last_os_error());
    (info.nNumberOfLinks as u64, ((info.nFileIndexHigh as u64) << 32) | info.nFileIndexLow as u64)
}

/// Create a symbolic link to a target that does not exist.
#[cfg(unix)]
fn dangling_symlink(link: &Path) {
    std::os::unix::fs::symlink("/nonexistent", link).unwrap();
}

#[cfg(windows)]
fn dangling_symlink(link: &Path) {
    std::os::windows::fs::symlink_file(r"C:\nonexistent", link).unwrap();
}

/// Every file under `dir` has exactly one name (no hard links).
fn no_hard_links(dir: &Path) -> bool {
    fingerprint(dir).keys().all(|n| link_info(&dir.join(n)).0 == 1)
}

fn wait_progress(j: *mut Job, at_least: u64) {
    let t0 = Instant::now();
    while progress(j)["done"].as_u64().unwrap() < at_least {
        assert!(t0.elapsed().as_secs() < 60, "job did not reach step {at_least}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn is_clean(f: &Fixture) -> bool {
    let p = f.lib.parent().unwrap();
    !libupdate::stage_path(&f.lib).unwrap().exists() && !libupdate::old_path(&f.lib).unwrap().exists() && !p.join("lib_shard.cs-update-tmp").exists()
}

#[test]
fn the_library_is_byte_identical_until_the_swap_and_the_swap_gives_the_new_points() {
    let f = fixture("untouched", false);
    let h = open(&f.lib);
    let before = fingerprint(&f.lib);
    let (stage, old) = (libupdate::stage_path(&f.lib).unwrap(), libupdate::old_path(&f.lib).unwrap());
    assert!(stage.to_str().unwrap().ends_with("lib_shard.cs-stage"));
    // the job pauses after the staging copy has been updated (recover + load done on it), before the swap
    let hold = f.lib.parent().unwrap().join("hold-swap");
    std::fs::write(&hold, b"").unwrap();
    let mut p = job_params(&f, 0);
    p["hold_swap_file"] = json!(hold.to_str().unwrap());
    let j = start_job(p);
    wait_progress(j, 3);
    // the staging copy exists, has the update (the original does not), and shares no inode with the original
    assert!(stage.is_dir() && !old.exists());
    assert_ne!(fingerprint(&stage), before, "the staging copy was changed");
    assert!(no_hard_links(&f.lib) && no_hard_links(&stage), "a real copy: no file has a second name");
    let (c, m, g) = compare(&before, &fingerprint(&f.lib));
    assert_eq!((c.len(), m.len(), g), (0, 0, 0), "content and mtime of every file of the library are as before the job: content {c:?}, mtime {m:?}");
    assert_eq!(segment_ids(&f.lib), f.v1_segments);
    std::fs::remove_file(&hold).unwrap(); // release the job
    let done = wait_job(j);
    assert_eq!(done["state"], "done", "{done}");
    assert_eq!(done["done"], 5);
    unsafe { cs_job_free(j) };
    wait_ready(h);
    check_updated(&f, h); // 310 points, new ones found, deleted ones gone, nothing left beside the library
    assert!(is_clean(&f));
    assert_eq!(count_points(&f.lib), 310);
    unsafe { cs_close(h) };
}

#[test]
fn a_failure_after_the_copy_leaves_the_library_unchanged_and_no_stage() {
    // before_swap: the staging copy is fully updated, then the job fails; after_copy: right after the copy;
    // after_swap: the swap is done and then fails (before the open), so the swap is undone
    for point in ["after_copy", "before_swap", "after_swap"] {
        let f = fixture(&format!("fail-{point}"), false);
        let h = open(&f.lib);
        let before = fingerprint(&f.lib);
        let mut p = job_params(&f, 0);
        p["fail_at"] = json!(point);
        let j = start_job(p);
        let done = wait_job(j);
        assert_eq!(done["state"], "failed", "{point}: {done}");
        assert_eq!(done["error"]["code"], "internal", "{point}: {done}");
        assert!(done["error"]["message"].as_str().unwrap().contains(point), "{done}");
        unsafe { cs_job_free(j) };
        assert!(is_clean(&f), "{point}: no stage, old or unpack folder left");
        assert_eq!(fingerprint(&f.lib), before, "{point}: the library is as it was");
        // the handle opens the unchanged library again
        wait_ready(h);
        let v = status(h);
        assert_eq!(v["sources"][0]["docs"], 300, "{point}: {v}");
        assert_eq!(v["sources"][0]["error"], Value::Null);
        assert_eq!(first_addr(&search(h, &random_vec(5), 3)), "lib:t/5");
        // and the update still works afterwards
        let j = start_job(job_params(&f, 0));
        assert_eq!(wait_job(j)["state"], "done");
        unsafe { cs_job_free(j) };
        wait_ready(h);
        check_updated(&f, h);
        unsafe { cs_close(h) };
    }
}

#[test]
fn a_failed_copy_deletes_the_partial_stage() {
    // the library vanishes after the job started its hold: the copy fails and nothing is left
    let f = fixture("copyfail", false);
    let j = start_job(job_params(&f, 3000));
    wait_progress(j, 2);
    // a file the copy cannot read: a symbolic link inside the library
    dangling_symlink(&f.lib.join("stray-link"));
    let done = wait_job(j);
    assert_eq!(done["state"], "failed", "{done}");
    assert_eq!(done["error"]["code"], "unsupported", "{done}");
    unsafe { cs_job_free(j) };
    assert!(is_clean(&f));
}

#[test]
fn copy_tree_makes_a_real_copy() {
    let f = fixture("copytree", true);
    let dst = f.lib.parent().unwrap().join("copy");
    let n = libupdate::copy_tree(&f.lib, &dst).unwrap();
    assert_eq!(n, libupdate::tree_size(&f.lib).unwrap());
    assert_eq!(fingerprint(&f.lib).iter().map(|(k, v)| (k.clone(), v.0)).collect::<BTreeMap<_, _>>(), fingerprint(&dst).iter().map(|(k, v)| (k.clone(), v.0)).collect::<BTreeMap<_, _>>());
    assert!(no_hard_links(&f.lib) && no_hard_links(&dst));
    for name in fingerprint(&f.lib).keys() {
        assert_ne!(link_info(&f.lib.join(name)).1, link_info(&dst.join(name)).1, "{name}");
    }
    // an existing destination is refused, and so is a link
    assert!(libupdate::copy_tree(&f.lib, &dst).is_err());
    dangling_symlink(&f.lib.join("l"));
    let dst2 = f.lib.parent().unwrap().join("copy2");
    assert_eq!(libupdate::copy_tree(&f.lib, &dst2).unwrap_err().code.as_str(), "unsupported");
}

// ---- the free-space check ---------------------------------------------------------------------------------------

#[test]
fn margin_and_free_space_helpers() {
    let mib = 1024 * 1024u64;
    assert_eq!(libupdate::margin_for(0), 256 * mib);
    assert_eq!(libupdate::margin_for(1024 * mib), 256 * mib, "5% of 1 GiB is below the floor");
    assert_eq!(libupdate::margin_for(100 * 1024 * mib), 100 * 1024 * mib / 100 * 5, "5% of 100 GiB");
    let t = TempDir::new("statvfs");
    assert!(libupdate::available_bytes(&t.0).unwrap() > 0);
    assert!(libupdate::available_bytes(Path::new("/nonexistent/x")).is_err());
}

#[test]
fn no_space_fails_the_job_and_changes_nothing_on_disk() {
    let f = fixture("nospace", false);
    let h = open(&f.lib);
    let root = f._tmp.0.clone();
    let before = fingerprint(&root);
    let entries = std::fs::read_dir(&root).unwrap().count();
    let lib_bytes = libupdate::tree_size(&f.lib).unwrap();
    let snap_bytes = std::fs::metadata(&f.snapshot).unwrap().len();
    let needed = lib_bytes + snap_bytes + libupdate::margin_for(lib_bytes);
    let mut p = job_params(&f, 0);
    p["fake_available_bytes"] = json!(needed - 1);
    let j = start_job(p);
    let done = wait_job(j);
    assert_eq!(done["state"], "failed", "{done}");
    let e = &done["error"];
    assert_eq!(e["code"], "no_space", "{done}");
    assert_eq!(e["needed"], needed, "{done}");
    assert_eq!(e["available"], needed - 1, "{done}");
    let msg = e["message"].as_str().unwrap();
    assert!(msg.contains(&needed.to_string()) && msg.contains(&(needed - 1).to_string()), "{msg}");
    assert_eq!(e.as_object().unwrap().len(), 4, "code, message, needed, available: {e}");
    unsafe { cs_job_free(j) };
    // nothing on disk changed: every file of the whole tree (library, snapshot, manifest, v2) is as before, and
    // no folder was created beside the library
    assert_eq!(fingerprint(&root), before);
    assert!(is_clean(&f));
    assert_eq!(std::fs::read_dir(&root).unwrap().count(), entries);
    // the library comes back for the handle
    wait_ready(h);
    assert_eq!(status(h)["sources"][0]["docs"], 300);
    // exactly what is needed is enough
    let mut p = job_params(&f, 0);
    p["fake_available_bytes"] = json!(needed);
    let j = start_job(p);
    assert_eq!(wait_job(j)["state"], "done");
    unsafe { cs_job_free(j) };
    wait_ready(h);
    check_updated(&f, h);
    unsafe { cs_close(h) };
}

// ---- crash leftovers --------------------------------------------------------------------------------------------

/// A folder that stands for a crashed update's staging copy: a partly copied library.
fn fake_stage(f: &Fixture) {
    let stage = libupdate::stage_path(&f.lib).unwrap();
    std::fs::create_dir_all(stage.join("segments")).unwrap();
    std::fs::write(stage.join("segments").join("half-copied"), b"x").unwrap();
}

#[test]
fn leftover_stage_only_is_deleted_when_the_library_is_opened() {
    let f = fixture("left-stage", false);
    fake_stage(&f);
    let before = fingerprint(&f.lib);
    let h = open(&f.lib);
    assert!(is_clean(&f));
    assert_eq!(status(h)["sources"][0]["docs"], 300);
    assert_eq!(fingerprint(&f.lib), before);
    unsafe { cs_close(h) };
}

#[test]
fn leftover_old_with_a_complete_library_is_deleted() {
    let f = fixture("left-old", false);
    // the swap finished, the crash came before the old library was deleted
    let old = libupdate::old_path(&f.lib).unwrap();
    copy_dir(&f.v2, &old);
    assert!(libupdate::library_is_complete(&f.lib));
    let before = fingerprint(&f.lib);
    let h = open(&f.lib);
    assert!(is_clean(&f));
    assert_eq!(status(h)["sources"][0]["docs"], 300, "the library is what it was");
    assert_eq!(fingerprint(&f.lib), before);
    unsafe { cs_close(h) };
}

#[test]
fn leftover_old_alone_is_renamed_back() {
    let f = fixture("left-only-old", false);
    // the crash came between the two renames: no library, only .cs-old
    let old = libupdate::old_path(&f.lib).unwrap();
    let before = fingerprint(&f.lib);
    std::fs::rename(&f.lib, &old).unwrap();
    assert!(!f.lib.exists());
    let h = open(&f.lib);
    assert!(is_clean(&f));
    assert_eq!(status(h)["sources"][0]["docs"], 300);
    assert_eq!(fingerprint(&f.lib), before);
    unsafe { cs_close(h) };
}

#[test]
fn leftover_old_with_an_incomplete_library_is_restored() {
    let f = fixture("left-bad", false);
    // the swap finished but what is now the library is not usable: the old one comes back
    let old = libupdate::old_path(&f.lib).unwrap();
    let before = fingerprint(&f.lib);
    std::fs::rename(&f.lib, &old).unwrap();
    std::fs::create_dir_all(f.lib.join("segments")).unwrap();
    std::fs::write(f.lib.join("segments").join("junk"), b"x").unwrap();
    assert!(!libupdate::library_is_complete(&f.lib));
    let h = open(&f.lib);
    assert!(is_clean(&f));
    assert_eq!(status(h)["sources"][0]["docs"], 300);
    assert_eq!(fingerprint(&f.lib), before);
    unsafe { cs_close(h) };
}

#[test]
fn completeness_is_manifest_listed_segments_and_a_read_only_open() {
    let f = fixture("complete", false);
    assert!(libupdate::library_is_complete(&f.lib));
    assert!(!libupdate::library_is_complete(Path::new("/nonexistent/lib")));
    let c = f.lib.parent().unwrap().join("c");
    // no manifest file
    copy_dir(&f.lib, &c);
    std::fs::remove_file(c.join(MANIFEST_FILE)).unwrap();
    assert!(!libupdate::library_is_complete(&c));
    // a listed segment is missing
    std::fs::write(c.join(MANIFEST_FILE), json!({"00000000-0000-0000-0000-000000000000": "active"}).to_string()).unwrap();
    assert!(!libupdate::library_is_complete(&c));
    // the manifest is not an object
    std::fs::write(c.join(MANIFEST_FILE), b"[]").unwrap();
    assert!(!libupdate::library_is_complete(&c));
    // everything listed is there, but the shard does not open (its segment folder is emptied)
    let seg = segment_ids(&f.lib).into_iter().next().unwrap();
    std::fs::write(c.join(MANIFEST_FILE), json!({seg.clone(): "active"}).to_string()).unwrap();
    for e in std::fs::read_dir(c.join("segments").join(&seg)).unwrap() {
        let p = e.unwrap().path();
        if p.is_dir() { std::fs::remove_dir_all(p).unwrap() } else { std::fs::remove_file(p).unwrap() }
    }
    assert!(!libupdate::library_is_complete(&c));
}

#[test]
fn an_update_start_puts_leftovers_right_first() {
    // stage + old + complete library: the update starts clean and finishes
    let f = fixture("left-start", false);
    fake_stage(&f);
    copy_dir(&f.v2, &libupdate::old_path(&f.lib).unwrap());
    let j = start_job(job_params(&f, 0));
    assert_eq!(wait_job(j)["state"], "done");
    unsafe { cs_job_free(j) };
    assert!(is_clean(&f));
    let h = open(&f.lib);
    check_updated(&f, h);
    unsafe { cs_close(h) };

    // a crash between the renames: only .cs-old. The update job would say not_found for the missing library
    // without the recovery
    let f = fixture("left-start2", false);
    std::fs::rename(&f.lib, libupdate::old_path(&f.lib).unwrap()).unwrap();
    let j = start_job(job_params(&f, 0));
    assert_eq!(wait_job(j)["state"], "done");
    unsafe { cs_job_free(j) };
    assert!(is_clean(&f));
    let h = open(&f.lib);
    check_updated(&f, h);
    unsafe { cs_close(h) };
}

// ---- evidence for DESIGN.md, Libraries / Updates: why the update is not staged with hard links -------------------
//
// A staging copy made of hard links (cp -al) would make the swap atomic at almost no disk cost, but only if
// nothing in the update path writes into an existing inode. These tests measure that on the pinned Qdrant rev:
// every file of the original is hashed (content) and stat-ed (mtime) before and after the work on the linked copy.

use std::collections::BTreeMap;
use std::hash::{Hash, Hasher};

type Fingerprint = BTreeMap<String, (u64, u128)>;

fn fingerprint(dir: &Path) -> Fingerprint {
    fn walk(base: &Path, dir: &Path, out: &mut Fingerprint) {
        for e in std::fs::read_dir(dir).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                walk(base, &p, out);
            } else {
                let mut h = std::collections::hash_map::DefaultHasher::new();
                std::fs::read(&p).unwrap_or_else(|e| panic!("reading {}: {e}", p.display())).hash(&mut h);
                let m = std::fs::metadata(&p).unwrap_or_else(|e| panic!("stat {}: {e}", p.display())).modified().unwrap().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
                out.insert(p.strip_prefix(base).unwrap().to_string_lossy().into_owned(), (h.finish(), m));
            }
        }
    }
    let mut out = BTreeMap::new();
    walk(dir, dir, &mut out);
    out
}

/// (files whose content changed, files whose content is the same but whose mtime moved, files added or removed)
fn compare(before: &Fingerprint, after: &Fingerprint) -> (Vec<String>, Vec<String>, usize) {
    let (mut content, mut mtime) = (vec![], vec![]);
    for (k, (h, m)) in before {
        if let Some((h2, m2)) = after.get(k) {
            if h != h2 {
                content.push(k.clone());
            } else if m != m2 {
                mtime.push(k.clone());
            }
        }
    }
    let gone_or_new = before.keys().filter(|k| !after.contains_key(*k)).count() + after.keys().filter(|k| !before.contains_key(*k)).count();
    (content, mtime, gone_or_new)
}

/// Bytes in the named files of `dir`, and in all of its files.
fn sizes(dir: &Path, names: &[String]) -> (u64, u64) {
    let sel = names.iter().map(|n| std::fs::metadata(dir.join(n)).map(|m| m.len()).unwrap_or(0)).sum();
    let all = fingerprint(dir).keys().map(|n| std::fs::metadata(dir.join(n)).map(|m| m.len()).unwrap_or(0)).sum();
    (sel, all)
}

fn link_tree(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for e in std::fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let t = to.join(e.file_name());
        if e.path().is_dir() {
            link_tree(&e.path(), &t);
        } else {
            std::fs::hard_link(e.path(), &t).unwrap();
        }
    }
}

/// A library with payload indexes of three kinds (so the index files exist), as v1 of the staging experiments.
fn build_v1_indexed(dir: &Path, optimize: bool) {
    use edge::{CreateIndex, FieldIndexOperations, PayloadFieldSchema, PayloadSchemaType};
    ensure_init();
    let shard = EdgeShard::new(dir, config(optimize)).unwrap();
    for (f, t) in [("title", PayloadSchemaType::Keyword), ("_start_page", PayloadSchemaType::Integer), ("content", PayloadSchemaType::Text)] {
        shard
            .update(UpdateOperation::FieldIndexOperation(FieldIndexOperations::CreateIndex(CreateIndex {
                field_name: f.parse().unwrap(),
                field_schema: Some(PayloadFieldSchema::FieldType(t)),
            })))
            .unwrap();
    }
    upsert(&shard, 1..=150, "Original text.");
    upsert(&shard, 151..=300, "Original text.");
    if optimize {
        shard.optimize().unwrap();
    }
    shard.flush().unwrap();
    drop(shard);
    let _ = std::fs::remove_file(dir.join(MANIFEST_FILE));
}

struct StageFixture {
    _tmp: TempDir,
    root: PathBuf,
    v1: PathBuf,
    against: SnapshotManifest,
    snapshot: PathBuf,
}

fn stage_fixture(name: &str, optimize: bool) -> StageFixture {
    let tmp = TempDir::new(name);
    let root = tmp.0.clone();
    let v1 = root.join("v1");
    build_v1_indexed(&v1, optimize);
    let (json_text, _) = libupdate::library_manifest(&v1).unwrap();
    let v2 = root.join("v2");
    copy_dir(&v1, &v2);
    {
        let shard = EdgeShard::load(&v2, None).unwrap();
        upsert(&shard, 301..=320, "Brand new text.");
        delete(&shard, 1..=10);
        upsert(&shard, 50..=50, "Rewritten text CHANGED.");
        if optimize {
            shard.optimize().unwrap();
        }
        shard.flush().unwrap();
    }
    let against: SnapshotManifest = serde_json::from_str(&json_text).unwrap();
    let snapshot = root.join("partial.snapshot");
    make_partial_snapshot(&v2, &against, &snapshot);
    StageFixture { _tmp: tmp, root, v1, against, snapshot }
}

impl StageFixture {
    /// A fresh, independent copy of v1 (real copies, not links).
    fn fresh(&self, name: &str) -> PathBuf {
        let d = self.root.join(name);
        copy_dir(&self.v1, &d);
        d
    }

    fn unpacked(&self, name: &str) -> (PathBuf, SnapshotManifest) {
        let d = self.root.join(name);
        std::fs::create_dir_all(&d).unwrap();
        EdgeShard::unpack_snapshot(&self.snapshot, &d).unwrap();
        let m = SnapshotManifest::load_from_snapshot(&d, Some(shard::snapshots::snapshot_manifest::RecoveryType::Partial)).unwrap();
        (d, m)
    }
}

fn count_points(dir: &Path) -> usize {
    cache_search::library::write_segments_manifest(dir).unwrap();
    let ro = cache_search::library::open_shard_for_scroll(dir).unwrap();
    edge::EdgeShardRead::count(&ro, edge::CountRequest::new()).unwrap()
}

#[test]
fn hard_link_staging_a_the_qdrant_merge_overwrites_linked_files_in_place() {
    // v2 is v1 plus changes in the same (appendable) segment, so the snapshot carries files the library already
    // has. `recover_partial_snapshot` merges the segments folder with fs_extra's move_dir, which copies over an
    // existing file (open + truncate), i.e. writes into the inode that the original shares.
    let f = stage_fixture("stage-a", false);
    let original = f.fresh("original");
    let staging = f.root.join("staging");
    link_tree(&original, &staging);
    let before = fingerprint(&original);
    let (unp, sm) = f.unpacked("unp");
    drop(EdgeShard::recover_partial_snapshot(&staging, &f.against, &unp, &sm).unwrap());
    let (content, mtime, _) = compare(&before, &fingerprint(&original));
    let (bytes, total) = sizes(&original, &[content.clone(), mtime.clone()].concat());
    eprintln!(
        "hard-link staging, recover_partial_snapshot: {} original files changed content, {} changed mtime only ({bytes} of {total} bytes)",
        content.len(),
        mtime.len()
    );
    assert!(!content.is_empty(), "if this fails the merge no longer writes in place: re-evaluate hard-link staging");
}

#[test]
fn hard_link_staging_b_the_read_write_load_writes_linked_files_in_place() {
    // The read-write load alone (what library_manifest and the end of recover_partial_snapshot do) opens flags,
    // trackers, deleted bitmaps and id-tracker files writable and mmaps them: mtimes move on files that are
    // shared with the original (content stays equal on an unchanged library).
    let f = stage_fixture("stage-b", true);
    let original = f.fresh("original");
    let staging = f.root.join("staging");
    link_tree(&original, &staging);
    let before = fingerprint(&original);
    drop(EdgeShard::load(&staging, None).unwrap());
    let (content, mtime, gone_or_new) = compare(&before, &fingerprint(&original));
    let (bytes, total) = sizes(&original, &mtime);
    eprintln!(
        "hard-link staging, read-write load: {} of {} original files changed mtime, {} content ({bytes} of {total} bytes)",
        mtime.len(),
        before.len(),
        content.len()
    );
    for m in &mtime {
        eprintln!("  mtime moved: {m}");
    }
    assert_eq!(gone_or_new, 0);
    assert!(!mtime.is_empty() || !content.is_empty(), "if this fails the load no longer writes in place: re-evaluate hard-link staging");
}

#[test]
fn hard_link_staging_c_rename_only_merge_without_load_leaves_the_original_untouched() {
    // The variant that would be safe: execute the merge plan with rename/unlink only (every changed file gets a
    // new inode), skip the read-write load, verify with the read-only open. Measured on both library shapes:
    // the original is identical in content and mtime, and the result has the same points as recover + load.
    for (name, optimize) in [("stage-c1", false), ("stage-c2", true)] {
        let f = stage_fixture(name, optimize);
        let original = f.fresh("original");
        let staging = f.root.join("staging");
        link_tree(&original, &staging);
        let before = fingerprint(&original);
        let (unp, sm) = f.unpacked("unp");
        let plan = shard::snapshots::snapshot_utils::SnapshotUtils::partial_snapshot_merge_plan(&staging, &f.against, &unp, &sm);
        for (from, to) in plan.move_files {
            std::fs::rename(from, to).unwrap();
        }
        for (from, to) in plan.replace_directories {
            if to.exists() {
                std::fs::remove_dir_all(&to).unwrap();
            }
            std::fs::rename(from, to).unwrap();
        }
        fn merge_dir(from: &Path, to: &Path) {
            std::fs::create_dir_all(to).unwrap();
            for e in std::fs::read_dir(from).unwrap() {
                let e = e.unwrap();
                if e.path().is_dir() {
                    merge_dir(&e.path(), &to.join(e.file_name()));
                } else {
                    std::fs::rename(e.path(), to.join(e.file_name())).unwrap();
                }
            }
        }
        for (from, to) in plan.merge_directories {
            merge_dir(&from, &to);
        }
        for file in plan.delete_files {
            std::fs::remove_file(file).unwrap();
        }
        for dir in plan.delete_directories {
            std::fs::remove_dir_all(dir).unwrap();
        }
        let n = count_points(&staging);
        let (content, mtime, gone_or_new) = compare(&before, &fingerprint(&original));
        assert_eq!((content.len(), mtime.len(), gone_or_new), (0, 0, 0), "{name}: the original must be untouched");
        // the same update through recover_partial_snapshot on an independent copy
        let other = f.fresh("other");
        let (unp2, sm2) = f.unpacked("unp2");
        drop(EdgeShard::recover_partial_snapshot(&other, &f.against, &unp2, &sm2).unwrap());
        assert_eq!(n, count_points(&other), "{name}");
        assert_eq!(n, 310, "{name}");
    }
}

// ---------------------------------------------------------------------------------------------------------
// A library with missing segments is reported as damaged and left alone

/// Remove one segment's folder (`false`) or only the files inside it (`true`).
fn damage(f: &Fixture, empty_only: bool) -> String {
    let seg = segment_ids(&f.lib).into_iter().next().unwrap();
    let dir = f.lib.join("segments").join(&seg);
    if empty_only {
        for e in std::fs::read_dir(&dir).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() { std::fs::remove_dir_all(p).unwrap() } else { std::fs::remove_file(p).unwrap() }
        }
    } else {
        std::fs::remove_dir_all(&dir).unwrap();
    }
    seg
}

fn assert_damaged_source(h: *mut cache_search::handle::Handle, lib: &Path) {
    let v = status(h);
    let s = &v["sources"][0];
    assert_eq!(s["opening"], false, "{v}");
    assert!(s["id"].is_null(), "{v}");
    assert_eq!(s["error"]["code"], "damaged", "{v}");
    let msg = s["error"]["message"].as_str().unwrap();
    assert!(msg.contains(lib.to_str().unwrap()), "{msg}");
    assert!(msg.contains("lists"), "{msg}");
    let r = search(h, &random_vec(5), 3);
    assert!(r["results"].as_array().unwrap().is_empty(), "{r}");
}

#[test]
fn a_manifest_segment_whose_folder_is_gone_is_damaged_and_nothing_is_touched() {
    let f = fixture("damaged-folder", false);
    damage(&f, false);
    let before = fingerprint(&f.lib);
    let h = open(&f.lib);
    assert_damaged_source(h, &f.lib);
    unsafe { cs_close(h) };
    assert_eq!(fingerprint(&f.lib), before, "byte-identical, manifest not regenerated");
    assert!(!is_clean_leftovers(&f.lib));
}

fn is_clean_leftovers(lib: &Path) -> bool {
    libupdate::has_leftovers(lib)
}

#[test]
fn a_segment_folder_with_its_files_gone_is_damaged_and_nothing_is_touched() {
    let f = fixture("damaged-files", false);
    damage(&f, true);
    let before = fingerprint(&f.lib);
    let h = open(&f.lib);
    assert_damaged_source(h, &f.lib);
    unsafe { cs_close(h) };
    assert_eq!(fingerprint(&f.lib), before);
}

#[test]
fn update_and_manifest_jobs_on_a_damaged_library_fail_with_damaged_and_change_nothing() {
    // folder gone: refused by cs_job_start
    let f = fixture("damaged-job-folder", false);
    damage(&f, false);
    let before = fingerprint(&f.lib);
    assert_eq!(start_err(job_params(&f, 0))["code"], "damaged");
    let out = f.lib.parent().unwrap().join("m.json");
    assert_eq!(start_kind_err("library_manifest", manifest_params(&f, &out, 0))["code"], "damaged");
    assert!(!out.exists());
    assert_eq!(fingerprint(&f.lib), before);
    // files gone: the job fails before it closes or writes anything
    let g = fixture("damaged-job-files", false);
    damage(&g, true);
    let before = fingerprint(&g.lib);
    let j = start_job(job_params(&g, 0));
    let done = wait_job(j);
    assert_eq!(done["state"], "failed", "{done}");
    assert_eq!(done["error"]["code"], "damaged", "{done}");
    unsafe { cs_job_free(j) };
    let out = g.lib.parent().unwrap().join("m2.json");
    let j = start_kind("library_manifest", manifest_params(&g, &out, 0));
    let done = wait_job(j);
    assert_eq!(done["error"]["code"], "damaged", "{done}");
    unsafe { cs_job_free(j) };
    assert!(!out.exists());
    assert_eq!(fingerprint(&g.lib), before);
    assert!(is_clean(&g));
}

#[test]
fn a_library_with_no_manifest_still_gets_one_written_on_open() {
    let f = fixture("no-manifest", false);
    std::fs::remove_file(f.lib.join(MANIFEST_FILE)).unwrap();
    let h = open(&f.lib);
    assert_eq!(status(h)["sources"][0]["docs"], 300);
    unsafe { cs_close(h) };
    assert_eq!(listed_in_manifest_file(&f.lib), segment_ids(&f.lib));
}
