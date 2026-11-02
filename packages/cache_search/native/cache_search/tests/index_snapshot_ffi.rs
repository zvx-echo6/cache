//! The ZIM keyword index as a syncable snapshot: building into `indexes_dir`, searching the snapshot, sealing an index in the old
//! folder by hard links (`index_seal`), adopting a peer's snapshot, and the rules around them. The ZIM is a tiny one written here.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::job::Job;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::time::{Duration, Instant};

const UUID: &str = "0badc0de-0000-4000-8000-00000000cafe";
const OTHER: &str = "0badc0de-0000-4000-8000-00000000beef";

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
        let p = std::env::temp_dir().join(format!("cs-zimsnap-{}-{}", std::process::id(), name));
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

/// Write a minimal valid ZIM (major 6, minor 1: the `C` namespace for content, `M` for metadata): articles in one
/// uncompressed cluster, no `X/` index entries. libzim reports `hasFulltextIndex() == false` for it.
fn write_tiny_zim(path: &Path, uuid: &str) {
    // (namespace, path, title, mime index, body), sorted by (namespace, path)
    let mut entries: Vec<(u8, &str, &str, u16, Vec<u8>)> = vec![
        (b'C', "Alpha", "Alpha", 0, b"<html><body><p>Alpha is the first letter. It has nothing to do with water.</p></body></html>".to_vec()),
        (b'C', "Flood_notes", "Flood notes", 0, b"<html><body><h1>Flood notes</h1><p>A flood is water where it should not be. Move to higher ground before the flood arrives. Keep a bag ready.</p></body></html>".to_vec()),
        (b'C', "Zebra", "Zebra", 0, b"<html><body><p>Zebras have stripes.</p></body></html>".to_vec()),
        (b'M', "Language", "Language", 1, b"eng".to_vec()),
        (b'M', "Title", "Title", 1, b"Tiny".to_vec()),
    ];
    entries.sort_by(|a, b| (a.0, a.1).cmp(&(b.0, b.1)));
    let n = entries.len();

    let mime = b"text/html\0text/plain\0\0".to_vec();
    let mime_pos = 80u64;
    let url_ptr_pos = mime_pos + mime.len() as u64;
    let title_ptr_pos = url_ptr_pos + 8 * n as u64;
    let cluster_ptr_pos = title_ptr_pos + 4 * n as u64;
    let cluster_pos = cluster_ptr_pos + 8;

    // one cluster: info byte 1 (no compression, 4-byte offsets), n+1 offsets, then the blobs
    let mut cluster = vec![1u8];
    let mut off = (4 * (n + 1)) as u32;
    let mut offs = Vec::new();
    for e in &entries {
        offs.push(off);
        off += e.4.len() as u32;
    }
    offs.push(off);
    for o in &offs {
        cluster.extend_from_slice(&o.to_le_bytes());
    }
    for e in &entries {
        cluster.extend_from_slice(&e.4);
    }

    let entries_pos = cluster_pos + cluster.len() as u64;
    let mut dirents: Vec<u8> = Vec::new();
    let mut entry_pos: Vec<u64> = Vec::new();
    for (i, e) in entries.iter().enumerate() {
        entry_pos.push(entries_pos + dirents.len() as u64);
        dirents.extend_from_slice(&e.3.to_le_bytes()); // mime type
        dirents.push(0); // extra parameters length
        dirents.push(e.0); // namespace
        dirents.extend_from_slice(&0u32.to_le_bytes()); // revision
        dirents.extend_from_slice(&0u32.to_le_bytes()); // cluster number
        dirents.extend_from_slice(&(i as u32).to_le_bytes()); // blob number
        dirents.extend_from_slice(e.1.as_bytes());
        dirents.push(0);
        dirents.extend_from_slice(e.2.as_bytes());
        dirents.push(0);
    }
    let checksum_pos = entries_pos + dirents.len() as u64;

    // title pointer list: entry indexes ordered by (namespace, title)
    let mut by_title: Vec<u32> = (0..n as u32).collect();
    by_title.sort_by(|a, b| {
        let (x, y) = (&entries[*a as usize], &entries[*b as usize]);
        (x.0, x.2).cmp(&(y.0, y.2))
    });

    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(&0x044D495Au32.to_le_bytes());
    out.extend_from_slice(&6u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    let uuid: Vec<u8> =
        (0..16).map(|i| u8::from_str_radix(&uuid.replace('-', "")[2 * i..2 * i + 2], 16).unwrap()).collect();
    out.extend_from_slice(&uuid);
    out.extend_from_slice(&(n as u32).to_le_bytes());
    out.extend_from_slice(&1u32.to_le_bytes());
    for v in [url_ptr_pos, title_ptr_pos, cluster_ptr_pos, mime_pos] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&u32::MAX.to_le_bytes()); // main page: none
    out.extend_from_slice(&u32::MAX.to_le_bytes()); // layout page: none
    out.extend_from_slice(&checksum_pos.to_le_bytes());
    assert_eq!(out.len(), 80);
    out.extend_from_slice(&mime);
    for p in &entry_pos {
        out.extend_from_slice(&p.to_le_bytes());
    }
    for t in &by_title {
        out.extend_from_slice(&t.to_le_bytes());
    }
    out.extend_from_slice(&cluster_pos.to_le_bytes());
    out.extend_from_slice(&cluster);
    out.extend_from_slice(&dirents);
    out.extend_from_slice(&[0u8; 16]); // checksum (not verified on open)
    std::fs::write(path, out).unwrap();
}

fn wait_job(j: *mut Job) -> Value {
    let t0 = Instant::now();
    loop {
        let p: Value = serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap();
        if p["state"] != "running" {
            return p;
        }
        assert!(t0.elapsed() < Duration::from_secs(120), "job timed out: {p}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn try_start(kind: &str, params: Value) -> Option<*mut Job> {
    let j = unsafe { cs_job_start(cstr(kind).as_ptr(), cstr(&params.to_string()).as_ptr()) };
    (!j.is_null()).then_some(j)
}

fn run(kind: &str, params: Value) -> Value {
    let j = try_start(kind, params)
        .unwrap_or_else(|| panic!("job {kind} did not start: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) })));
    let p = wait_job(j);
    unsafe { cs_job_free(j) };
    p
}

fn open_handle(zim: &Path, legacy: Option<&Path>, idx: Option<&Path>) -> *mut Handle {
    let mut src = json!({"kind": "zim", "path": zim, "builtin_index": false});
    if let Some(d) = legacy {
        src["index_dir"] = json!(d);
    }
    let mut cfg = json!({"sources": [src]});
    if let Some(d) = idx {
        cfg["indexes_dir"] = json!(d);
    }
    let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
    assert!(!h.is_null(), "cs_open failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    h
}

fn status(h: *mut Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap()
}

/// The ZIM's entry once its snapshot (if there is one) is no longer being verified.
fn settle(h: *mut Handle, want_snapshot: bool) -> Value {
    let t0 = Instant::now();
    loop {
        let st = status(h);
        let z = st["sources"][0].clone();
        if !want_snapshot || z["index"]["location"] == "snapshot" {
            return z;
        }
        assert!(t0.elapsed() < Duration::from_secs(60), "snapshot did not open: {z}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn search(h: *mut Handle, q: &str) -> String {
    take(unsafe { cs_search(h, cstr(q).as_ptr(), cstr(r#"{"k":10}"#).as_ptr()) }).expect("search result")
}

fn zim_root(idx: &Path, uuid: &str) -> PathBuf {
    idx.join("zim").join(uuid)
}

fn snapshots(idx: &Path, uuid: &str) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(zim_root(idx, uuid).join("snap"))
        .map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    v.sort();
    v
}

/// (name -> (size, mtime)) of the files directly in `dir`.
fn listing(dir: &Path) -> BTreeMap<String, (u64, std::time::SystemTime)> {
    std::fs::read_dir(dir)
        .unwrap()
        .flatten()
        .map(|e| {
            let m = e.metadata().unwrap();
            (e.file_name().to_string_lossy().into_owned(), (m.len(), m.modified().unwrap()))
        })
        .collect()
}

struct Env {
    _tmp: TempDir,
    root: PathBuf,
    zim: PathBuf,
    idx: PathBuf,
    legacy: PathBuf,
}

fn env(name: &str) -> Env {
    let tmp = TempDir::new(name);
    let root = tmp.0.clone();
    let zim = root.join("tiny.zim");
    write_tiny_zim(&zim, UUID);
    Env { zim, idx: root.join("indexes"), legacy: root.join("zim-idx"), root, _tmp: tmp }
}

fn build_legacy(e: &Env) {
    let p = run("index_zim", json!({"zim_path": e.zim, "index_dir": e.legacy}));
    assert_eq!(p["state"], "done", "{p}");
}

fn build_snapshot(e: &Env) -> Value {
    let p = run("index_zim", json!({"zim_path": e.zim, "indexes_dir": e.idx}));
    assert_eq!(p["state"], "done", "{p}");
    p["result"].clone()
}

fn seal(e: &Env, extra: Value) -> Value {
    let mut p = json!({"indexes_dir": e.idx, "kind": "zim", "source_id": UUID});
    if let Value::Object(m) = extra {
        for (k, v) in m {
            p[k] = v;
        }
    }
    run("index_seal", p)
}

#[test]
fn legacy_keeps_working_with_indexes_dir_set_and_no_snapshot() {
    let e = env("legacy");
    build_legacy(&e);
    let h = open_handle(&e.zim, Some(&e.legacy), Some(&e.idx));
    let z = settle(h, false);
    assert_eq!(z["indexed"], true);
    assert_eq!(z["index"]["location"], "legacy");
    assert_eq!(z["index"]["needs_seal"], true);
    assert!(z["index"]["snapshot"].is_null());
    assert_eq!(z["source_id"], UUID);
    assert!(search(h, "flood").contains("Flood notes"));
    // without indexes_dir nothing changes: legacy, and no needs_seal
    let h2 = open_handle(&e.zim, Some(&e.legacy), None);
    let z = settle(h2, false);
    assert_eq!(z["index"]["location"], "legacy");
    assert!(z["index"].get("needs_seal").is_none());
    // no index at all
    let h3 = open_handle(&e.zim, None, Some(&e.idx));
    assert_eq!(settle(h3, false)["index"]["location"], "none");
    unsafe {
        cs_close(h);
        cs_close(h2);
        cs_close(h3);
    }
}

#[test]
fn index_zim_publishes_a_snapshot_and_search_uses_it() {
    let e = env("publish");
    let r = build_snapshot(&e);
    let snaps = snapshots(&e.idx, UUID);
    assert_eq!(snaps, vec![r["snapshot"].as_str().unwrap().to_string()]);
    assert!(!zim_root(&e.idx, UUID).join(".build").exists(), "the build is removed after publishing");
    let dir = zim_root(&e.idx, UUID).join("snap").join(&snaps[0]);
    let m: Value = serde_json::from_str(&std::fs::read_to_string(dir.join("manifest.json")).unwrap()).unwrap();
    assert_eq!(m["kind"], "zim");
    assert_eq!(m["source_id"], UUID);
    assert_eq!(m["format"], 3);
    assert_eq!(m["tantivy"], "0.27");
    assert_eq!(m["tokenizer"]["name"], "en_stem");
    assert!(m["core"].is_string() && m["created"].is_string() && !m["files"].as_array().unwrap().is_empty());
    let names: Vec<&str> = m["files"].as_array().unwrap().iter().map(|f| f["path"].as_str().unwrap()).collect();
    assert!(
        names.contains(&"meta.json") && !names.iter().any(|n| n.contains("lock") || n.contains("cache_search_index")),
        "{names:?}"
    );

    // a second job over a published source adopts it and builds nothing
    let p = run("index_zim", json!({"zim_path": e.zim, "indexes_dir": e.idx}));
    assert_eq!(p["result"]["adopted"], true, "{p}");
    assert_eq!(snapshots(&e.idx, UUID), snaps);

    let h = open_handle(&e.zim, None, Some(&e.idx));
    let before = listing(&dir);
    let z = settle(h, true);
    assert_eq!(z["indexed"], true);
    assert_eq!(z["index"]["snapshot"], snaps[0].as_str());
    assert_eq!(z["index"]["format"], 3);
    assert!(z["index"].get("needs_seal").is_none());
    assert!(search(h, "flood").contains("Flood notes"));
    assert_eq!(listing(&dir), before, "opening and searching wrote into the snapshot");
    unsafe { cs_close(h) };
}

#[test]
fn seal_by_hard_link_then_switch_with_identical_results() {
    let e = env("seal");
    build_legacy(&e);
    let h = open_handle(&e.zim, Some(&e.legacy), Some(&e.idx));
    let before_text = search(h, "flood");
    let before_other = search(h, "water");
    assert!(before_text.contains("Flood notes"));
    let legacy_meta = std::fs::metadata(e.legacy.join("meta.json")).unwrap();

    // the index is open in this handle: hard links still work, so it seals
    let j = try_start("index_seal", json!({"indexes_dir": e.idx, "kind": "zim", "source_id": UUID})).expect("start");
    let p = wait_job(j);
    unsafe { cs_job_free(j) };
    assert_eq!(p["state"], "done", "{p}");
    assert_eq!(p["phase"], "publish");
    assert_eq!(p["result"]["adopted"], false);
    assert_eq!(p["result"]["method"], "link");
    let snaps = snapshots(&e.idx, UUID);
    assert_eq!(snaps, vec![p["result"]["snapshot"].as_str().unwrap().to_string()]);
    let dir = zim_root(&e.idx, UUID).join("snap").join(&snaps[0]);
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        assert_eq!(std::fs::metadata(dir.join("meta.json")).unwrap().ino(), legacy_meta.ino(), "linked, not copied");
    }
    assert!(dir.join(".tantivy-meta.lock").exists());

    // switch: the handle opens the snapshot, then the old names go
    let snap_before = listing(&dir);
    let z = settle(h, true);
    assert_eq!(z["index"]["location"], "snapshot");
    assert_eq!(z["index"]["snapshot"], snaps[0].as_str());
    assert_eq!(search(h, "flood"), before_text);
    assert_eq!(search(h, "water"), before_other);
    assert_eq!(listing(&dir), snap_before, "opening and searching wrote into the snapshot");
    assert!(!e.legacy.join("meta.json").exists(), "old names are removed after the first open from the snapshot");
    assert!(!e.legacy.join("cache_search_index.json").exists());
    assert!(!zim_root(&e.idx, UUID).join(".build").exists());
    // a fresh handle, nothing of the old index left: same answers
    let h2 = open_handle(&e.zim, Some(&e.legacy), Some(&e.idx));
    settle(h2, true);
    assert_eq!(search(h2, "flood"), before_text);
    unsafe {
        cs_close(h);
        cs_close(h2);
    }
}

#[test]
fn a_peer_snapshot_is_adopted_instead_of_sealing() {
    let e = env("adopt");
    build_legacy(&e);
    // a "peer" built the snapshot elsewhere and it synced in: simulate with a second environment's build, copied over
    let other = env("adopt-peer");
    let r = build_snapshot(&other);
    let name = r["snapshot"].as_str().unwrap();
    let from = zim_root(&other.idx, UUID).join("snap").join(name);
    let to = zim_root(&e.idx, UUID).join("snap").join(name);
    std::fs::create_dir_all(&to).unwrap();
    for f in std::fs::read_dir(&from).unwrap().flatten() {
        std::fs::copy(f.path(), to.join(f.file_name())).unwrap();
    }
    let p = seal(&e, json!({"index_dir": e.legacy}));
    assert_eq!(p["state"], "done", "{p}");
    assert_eq!(p["result"]["adopted"], true);
    assert_eq!(p["result"]["snapshot"], name);
    assert_eq!(snapshots(&e.idx, UUID), vec![name.to_string()], "nothing sealed");
    assert!(e.legacy.join("meta.json").exists(), "the old index is left alone");
}

#[test]
fn a_stale_or_unfinished_legacy_index_is_refused() {
    let e = env("stale");
    build_legacy(&e);
    let meta_path = e.legacy.join("cache_search_index.json");
    let mut meta: Value = serde_json::from_str(&std::fs::read_to_string(&meta_path).unwrap()).unwrap();
    meta["index_format"] = json!(2);
    std::fs::write(&meta_path, meta.to_string()).unwrap();
    let p = seal(&e, json!({"index_dir": e.legacy}));
    assert_eq!(p["state"], "failed", "{p}");
    assert_eq!(p["error"]["code"], "index_stale");
    meta["index_format"] = json!(3);
    meta["state"] = json!("building");
    std::fs::write(&meta_path, meta.to_string()).unwrap();
    let p = seal(&e, json!({"index_dir": e.legacy}));
    assert_eq!(p["error"]["code"], "index_stale", "{p}");
    assert!(snapshots(&e.idx, UUID).is_empty());
    assert!(!zim_root(&e.idx, UUID).join(".build").join("publish-x").exists());
    let leftovers: Vec<_> =
        std::fs::read_dir(zim_root(&e.idx, UUID).join(".build")).map(|r| r.flatten().count()).into_iter().collect();
    assert!(leftovers.iter().all(|n| *n == 0), "a refused seal leaves nothing behind");
    // no old index at all
    let nothing = seal(&e, json!({"index_dir": e.root.join("nowhere")}));
    assert_eq!(nothing["error"]["code"], "index_missing", "{nothing}");
    // bad kind
    assert!(try_start("index_seal", json!({"indexes_dir": e.idx, "kind": "pdf", "source_id": UUID})).is_none());
}

#[test]
fn a_snapshot_for_an_unloaded_zim_is_not_attached() {
    let e = env("unloaded");
    build_snapshot(&e);
    // a handle whose only ZIM has another uuid: the snapshot of UUID is not looked at
    let zim2 = e.root.join("other.zim");
    write_tiny_zim(&zim2, OTHER);
    let h = open_handle(&zim2, None, Some(&e.idx));
    let z = settle(h, false);
    assert_eq!(z["id"], OTHER);
    assert_eq!(z["index"]["location"], "none");
    assert_eq!(z["indexed"], false);
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(settle(h, false)["index"]["location"], "none");
    unsafe { cs_close(h) };
}

#[test]
fn kill_during_the_build_then_resume_and_publish() {
    let e = env("resume");
    // cancel at the first checkpoint: the working folder stays, nothing is published
    let j = try_start("index_zim", json!({"zim_path": e.zim, "indexes_dir": e.idx, "checkpoint_articles": 1})).unwrap();
    unsafe { cs_job_cancel(j) };
    let p = wait_job(j);
    unsafe { cs_job_free(j) };
    assert!(p["state"] == "cancelled" || p["state"] == "done", "{p}");
    if p["state"] == "cancelled" {
        assert!(snapshots(&e.idx, UUID).is_empty());
        assert!(zim_root(&e.idx, UUID).join(".build").join("meta.json").exists());
        // and a dead job's lock does not block the next one
        let r = build_snapshot(&e);
        assert_eq!(snapshots(&e.idx, UUID).len(), 1);
        assert!(r["snapshot"].is_string());
    }
    // a build killed for real leaves a lock of a dead process and a half-written working folder
    let e2 = env("resume-kill");
    let build = zim_root(&e2.idx, UUID).join(".build");
    let j =
        try_start("index_zim", json!({"zim_path": e2.zim, "indexes_dir": e2.idx, "checkpoint_articles": 1})).unwrap();
    unsafe { cs_job_free(j) }; // freeing cancels at the next checkpoint and waits
    std::fs::create_dir_all(&build).unwrap();
    std::fs::write(
        build.join("cache_search_index.lock"),
        json!({"pid": 4_000_000_000u64, "start_ticks": 1, "boot_id": null, "started": 0}).to_string(),
    )
    .unwrap();
    let r = build_snapshot(&e2);
    assert_eq!(snapshots(&e2.idx, UUID).len(), 1, "{r}");
    let h = open_handle(&e2.zim, None, Some(&e2.idx));
    settle(h, true);
    assert!(search(h, "flood").contains("Flood notes"));
    unsafe { cs_close(h) };
}

#[test]
fn a_corrupt_snapshot_is_not_used() {
    let e = env("corrupt");
    build_legacy(&e);
    build_snapshot(&e);
    let snaps = snapshots(&e.idx, UUID);
    let dir = zim_root(&e.idx, UUID).join("snap").join(&snaps[0]);
    let target = std::fs::read_dir(&dir)
        .unwrap()
        .flatten()
        .find(|f| f.file_name() != "manifest.json" && f.metadata().unwrap().len() > 0)
        .unwrap();
    let mut bytes = std::fs::read(target.path()).unwrap();
    let last = bytes.len() - 1;
    bytes[last] ^= 0xff;
    std::fs::write(target.path(), bytes).unwrap();
    let h = open_handle(&e.zim, Some(&e.legacy), Some(&e.idx));
    std::thread::sleep(Duration::from_millis(300));
    let z = settle(h, false);
    assert_eq!(z["index"]["location"], "legacy", "a snapshot whose files do not match its manifest is ignored: {z}");
    assert!(search(h, "flood").contains("Flood notes"));
    unsafe { cs_close(h) };
}
