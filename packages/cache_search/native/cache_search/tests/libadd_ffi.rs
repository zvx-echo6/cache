//! Adding a library through the C ABI: the `library_template`, `unpack_library` and `check_library` jobs, and the
//! round trip the app makes (generate the blank template, add it back, build its keyword index, see it ready with
//! 0 entries).

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::job::Job;
use cache_search::libadd;
use cache_search::library::{ensure_init, MANIFEST_FILE};
use edge::{
    Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, PointInsertOperations, PointOperations, PointStruct,
    UpdateOperation,
};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;

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
        let p = std::env::temp_dir().join(format!("cs-libadd-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }
    fn path(&self, rel: &str) -> PathBuf {
        self.0.join(rel)
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn last_error() -> Value {
    serde_json::from_str(&take(unsafe { cs_last_error(ptr::null_mut()) }).expect("an error")).unwrap()
}

fn start(kind: &str, params: Value) -> *mut Job {
    unsafe { cs_job_start(cstr(kind).as_ptr(), cstr(&params.to_string()).as_ptr()) }
}

fn run(kind: &str, params: Value) -> Value {
    let j = start(kind, params);
    assert!(!j.is_null(), "{kind} did not start: {}", last_error());
    let t0 = std::time::Instant::now();
    let p = loop {
        let p: Value = serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap();
        if p["state"] != "running" {
            break p;
        }
        assert!(t0.elapsed().as_secs() < 300, "{kind} did not finish: {p}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    };
    unsafe { cs_job_free(j) };
    p
}

fn status(h: *mut Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap()
}

fn open_ready(src: Value) -> (*mut Handle, Value) {
    let h = unsafe { cs_open(cstr(&json!({"sources": [src]}).to_string()).as_ptr()) };
    assert!(!h.is_null(), "cs_open failed: {}", last_error());
    let t0 = std::time::Instant::now();
    loop {
        let v = status(h);
        if v["sources"][0]["opening"] == false {
            return (h, v["sources"][0].clone());
        }
        assert!(t0.elapsed().as_secs() < 120, "library did not open: {v}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

/// The names and bytes of the files in a tar.
/// The files of a tar, compressed with gzip or not.
fn tar_files(path: &Path) -> Vec<(String, Vec<u8>)> {
    let f = std::fs::File::open(path).unwrap();
    let r: Box<dyn std::io::Read> = if libadd::is_gzip(path).unwrap() { Box::new(flate2::read::GzDecoder::new(f)) } else { Box::new(f) };
    let mut a = tar::Archive::new(r);
    let mut out = Vec::new();
    for e in a.entries().unwrap() {
        let mut e = e.unwrap();
        if e.header().entry_type().is_file() {
            let name = e.path().unwrap().to_string_lossy().into_owned();
            let mut b = Vec::new();
            std::io::Read::read_to_end(&mut e, &mut b).unwrap();
            out.push((name, b));
        }
    }
    out
}

/// A .cache-library archive: the snapshot with cache-library.json appended at its root (what `tar -rf` does).
fn cache_library(snapshot: &Path, settings: &Value, out: &Path) {
    let mut b = tar::Builder::new(std::fs::File::create(out).unwrap());
    let mut a = tar::Archive::new(std::fs::File::open(snapshot).unwrap());
    for e in a.entries().unwrap() {
        let mut e = e.unwrap();
        let mut h = e.header().clone();
        let p = e.path().unwrap().into_owned();
        b.append_data(&mut h, p, &mut e).unwrap();
    }
    let bytes = serde_json::to_vec(settings).unwrap();
    let mut h = tar::Header::new_gnu();
    h.set_size(bytes.len() as u64);
    h.set_mode(0o644);
    h.set_cksum();
    b.append_data(&mut h, libadd::SETTINGS_FILE, &bytes[..]).unwrap();
    b.finish().unwrap();
}

/// Generate the template in `t` and return (snapshot path, settings).
fn template(t: &TempDir) -> (PathBuf, Value) {
    let out = t.path("cache-library-template.tar");
    let p = run("library_template", json!({"out_path": out.to_str().unwrap()}));
    assert_eq!(p["state"], "done", "{p}");
    assert_eq!((p["done"].as_u64(), p["total"].as_u64()), (Some(3), Some(3)));
    assert!(libadd::is_gzip(&out).unwrap(), "the template is written compressed");
    let files = tar_files(&out);
    let names: Vec<&str> = files.iter().map(|f| f.0.as_str()).collect();
    assert_eq!(names, ["README.md", "cache-library.json", "blank-library.snapshot"]);
    let readme = String::from_utf8(files[0].1.clone()).unwrap();
    assert!(readme.contains("LIBRARY-FORMAT.md") && readme.contains("doc_version"), "{readme}");
    let settings: Value = serde_json::from_slice(&files[1].1).unwrap();
    assert_eq!(settings["format"], 1);
    assert_eq!(settings["library_id"], "my-library");
    assert_eq!(settings["version"], "1");
    assert_eq!(settings["embedding"]["model"], "bge-m3-Q8_0.gguf");
    assert_eq!(settings["embedding"]["sha256"], "c98c7c907bb3ab8c3be4c8ad827cc934c7c1a7e014d1c999e0c45c8027c158bb");
    assert_eq!(settings["embedding"]["repo"], "lm-kit/bge-m3-gguf");
    assert_eq!(settings["embedding"]["revision"], "9379ce497e8814b200f2dc0d18eb4045426dcb8c");
    assert_eq!(settings["embedding"]["size"], 634_553_856u64);
    assert_eq!(settings["embedding"]["dims"], 1024);
    let snap = t.path("blank-library.snapshot");
    std::fs::write(&snap, &files[2].1).unwrap();
    // the snapshot is a shard folder in a tar, without segments_manifest.json, and no hidden work folder is left
    let inner: Vec<String> = tar_files(&snap).into_iter().map(|f| f.0).collect();
    assert!(inner.iter().any(|n| n.starts_with("segments/")), "{inner:?}");
    assert!(!inner.iter().any(|n| n == MANIFEST_FILE), "{inner:?}");
    let left: Vec<_> = std::fs::read_dir(&t.0).unwrap().filter_map(|e| e.ok()).map(|e| e.file_name()).collect();
    assert!(left.iter().all(|n| !n.to_string_lossy().starts_with('.')), "{left:?}");
    (snap, settings)
}

#[test]
fn a_compressed_library_adds_like_an_uncompressed_one() {
    let t = TempDir::new("gzip");
    // A plain snapshot (its settings are worked out from the payload), and the same file compressed.
    let plain = plain_snapshot(&t, "gz", true);
    let packed = t.path("gz.cache-library.gz");
    {
        let mut e = flate2::write::GzEncoder::new(std::fs::File::create(&packed).unwrap(), flate2::Compression::best());
        std::io::copy(&mut std::fs::File::open(&plain).unwrap(), &mut e).unwrap();
        e.finish().unwrap();
    }
    assert!(std::fs::metadata(&packed).unwrap().len() < std::fs::metadata(&plain).unwrap().len());
    let mut docs = Vec::new();
    for (name, file) in [("a", &plain), ("b", &packed)] {
        let dir = t.path(&format!("libs/{name}/shard"));
        std::fs::create_dir_all(dir.parent().unwrap()).unwrap();
        let p = run("unpack_library", json!({"snapshot_path": file.to_str().unwrap(), "dir": dir.to_str().unwrap()}));
        assert_eq!(p["state"], "done", "{name}: {p}");
        assert_eq!(p["done"], p["total"], "{name}: progress counts the file's own bytes");
        docs.push(p["detail"]["docs"].clone());
    }
    assert_eq!(docs[0], docs[1]);
    assert_eq!(docs[0], 30);
    // a gzip file that does not hold a tar is refused before anything is made
    let junk = t.path("junk.cache-library");
    {
        let mut e = flate2::write::GzEncoder::new(std::fs::File::create(&junk).unwrap(), flate2::Compression::fast());
        std::io::Write::write_all(&mut e, &[7u8; 2048]).unwrap();
        e.finish().unwrap();
    }
    let dir = t.path("libs/junk/shard");
    std::fs::create_dir_all(dir.parent().unwrap()).unwrap();
    assert!(start("unpack_library", json!({"snapshot_path": junk.to_str().unwrap(), "dir": dir.to_str().unwrap()})).is_null());
}

/// The guide that ships in the app (app/assets/guide, gzip-compressed) adds like any library: it is the Cache guide, with entries.
#[test]
fn the_bundled_guide_adds_through_the_compressed_import() {
    let t = TempDir::new("guide");
    let guide = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../../app/assets/guide/cache-guide.cache-library");
    assert!(libadd::is_gzip(&guide).unwrap(), "the bundled guide is compressed");
    let dir = t.path("libraries/cache-guide/shard");
    std::fs::create_dir_all(dir.parent().unwrap()).unwrap();
    let p = run("unpack_library", json!({"snapshot_path": guide.to_str().unwrap(), "dir": dir.to_str().unwrap()}));
    assert_eq!(p["state"], "done", "{p}");
    let d = &p["detail"];
    assert_eq!(d["settings_source"], "archive");
    assert_eq!(d["resolved"]["library_id"], "cache-guide");
    assert_eq!(d["resolved"]["version"], "2026-10-30b");
    assert!(d["docs"].as_u64().unwrap() > 50, "{d}");
}

#[test]
fn blank_template_adds_back_as_an_empty_ready_library() {
    let t = TempDir::new("roundtrip");
    let (snap, settings) = template(&t);
    let archive = t.path("my-library.cache-library");
    cache_library(&snap, &settings, &archive);

    let dir = t.path("libraries/my-library/shard");
    std::fs::create_dir_all(dir.parent().unwrap()).unwrap();
    let p = run("unpack_library", json!({"snapshot_path": archive.to_str().unwrap(), "dir": dir.to_str().unwrap()}));
    assert_eq!(p["state"], "done", "{p}");
    let d = &p["detail"];
    assert_eq!(d["docs"], 0);
    assert_eq!(d["settings_source"], "archive");
    assert_eq!(d["settings"], settings, "the archive's settings file is handed back as it was");
    assert_eq!(d["resolved"]["library_id"], "my-library");
    assert_eq!(d["resolved"]["version"], "1");
    assert_eq!(d["resolved"]["guessed"], false);
    assert!(d["settings_error"].is_null());
    assert_eq!(d["whole_library_only"], false, "an empty library lacks nothing");
    assert_eq!(d["own_text_index"], false);
    assert_eq!(p["done"], p["total"]);
    assert!(!dir.join(libadd::SETTINGS_FILE).exists(), "the settings file is taken out of the shard folder");
    assert!(dir.join(MANIFEST_FILE).is_file());

    // the source config the app uses: shard folder, index folder beside it, the settings object
    let idx = t.path("libraries/my-library/index");
    let src = json!({"kind": "library", "path": dir.to_str().unwrap(), "index_dir": idx.to_str().unwrap(), "settings": settings});
    let ip = run("index_library", json!({"library_path": dir.to_str().unwrap(), "index_dir": idx.to_str().unwrap(),
                                         "heap_mb": 50, "settings": settings}));
    assert_eq!(ip["state"], "done", "{ip}");
    let (h, s) = open_ready(src);
    assert!(s["error"].is_null(), "{s}");
    assert_eq!(s["id"], "my-library");
    assert_eq!(s["title"], "My library");
    assert_eq!(s["docs"], 0);
    assert_eq!(s["indexed"], true, "ready: the keyword index is built");
    assert_eq!(s["keyword_source"], "device");
    assert_eq!(s["whole_library_only"], false);
    assert_eq!(s["settings"]["version"], "1");
    let r: Value = serde_json::from_str(
        &take(unsafe { cs_search(h, cstr("water").as_ptr(), cstr(r#"{"k":5}"#).as_ptr()) }).expect("search works"),
    )
    .unwrap();
    assert_eq!(r["results"].as_array().unwrap().len(), 0);
    unsafe { cs_close(h) };
}

fn build_shard(dir: &Path, with_identity: bool) {
    ensure_init();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(4, Distance::Cosine).build()).build();
    let shard = EdgeShard::new(dir, cfg).unwrap();
    let pts: Vec<_> = (1..=30u64)
        .map(|i| {
            let mut p = json!({"title": format!("Manual {}", i / 10), "content": format!("Passage {i} about boiling water.")});
            if with_identity {
                p["doc_id"] = json!(format!("manual-{}", i / 10));
                p["doc_version"] = json!(1);
            }
            PointStruct::new(i, vec![1.0, i as f32, 0.0, 0.5], p).0
        })
        .collect();
    shard.update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(pts)))).unwrap();
    shard.flush().unwrap();
    drop(shard);
}

/// A plain snapshot (no settings file inside) of a small shard.
fn plain_snapshot(t: &TempDir, name: &str, with_identity: bool) -> PathBuf {
    let shard = t.path(&format!("{name}-src"));
    build_shard(&shard, with_identity);
    let snap = t.path(&format!("{name}.snapshot"));
    libadd::pack_snapshot(&shard, &snap).unwrap();
    snap
}

#[test]
fn plain_snapshot_is_guessed_or_takes_chosen_settings() {
    let t = TempDir::new("plain");
    let snap = plain_snapshot(&t, "old", false);
    // no settings anywhere: the core guesses them from the payload
    let dir = t.path("guessed");
    let p = run("unpack_library", json!({"snapshot_path": snap.to_str().unwrap(), "dir": dir.to_str().unwrap()}));
    assert_eq!(p["state"], "done", "{p}");
    let d = &p["detail"];
    assert_eq!(d["docs"], 30);
    assert!(d["settings"].is_null() && d["settings_source"].is_null());
    assert_eq!(d["resolved"]["guessed"], true);
    assert_eq!(d["resolved"]["fields"]["text"], "content");
    assert_eq!(d["whole_library_only"], true, "these points carry no doc_id/doc_version");

    // settings chosen beside the snapshot
    let chosen = json!({"format": 1, "library_id": "manuals", "version": 2, "title": "Manuals",
                        "fields": {"title": "title", "text": "content"}});
    let dir2 = t.path("given");
    let p = run("unpack_library", json!({"snapshot_path": snap.to_str().unwrap(), "dir": dir2.to_str().unwrap(), "settings": chosen}));
    assert_eq!(p["state"], "done", "{p}");
    assert_eq!(p["detail"]["settings_source"], "given");
    assert_eq!(p["detail"]["resolved"]["library_id"], "manuals");
    assert_eq!(p["detail"]["resolved"]["version"], "2", "a whole-number version is kept as text");

    // check_library on the unpacked folder with other settings
    let c = run("check_library", json!({"library_path": dir.to_str().unwrap(), "settings": chosen}));
    assert_eq!(c["state"], "done", "{c}");
    assert_eq!(c["detail"]["resolved"]["title"], "Manuals");
    assert_eq!(c["detail"]["docs"], 30);

    // a library whose points carry doc_id and doc_version is not whole-library only
    let snap3 = plain_snapshot(&t, "new", true);
    let dir3 = t.path("identity");
    let p = run("unpack_library", json!({"snapshot_path": snap3.to_str().unwrap(), "dir": dir3.to_str().unwrap(), "settings": chosen}));
    assert_eq!(p["detail"]["whole_library_only"], false, "{p}");
    let (h, s) = open_ready(json!({"kind": "library", "path": dir3.to_str().unwrap(), "settings": chosen}));
    assert_eq!(s["whole_library_only"], false, "{s}");
    unsafe { cs_close(h) };
    let (h, s) = open_ready(json!({"kind": "library", "path": dir.to_str().unwrap(), "settings": chosen}));
    assert_eq!(s["whole_library_only"], true, "{s}");
    unsafe { cs_close(h) };
}

#[test]
fn empty_library_without_settings_reports_what_cannot_be_guessed() {
    let t = TempDir::new("noguess");
    let (snap, _) = template(&t);
    let dir = t.path("lib");
    let p = run("unpack_library", json!({"snapshot_path": snap.to_str().unwrap(), "dir": dir.to_str().unwrap()}));
    assert_eq!(p["state"], "done", "{p}");
    assert!(p["detail"]["resolved"].is_null());
    assert_eq!(p["detail"]["settings_error"]["code"], "unsupported", "{p}");
    assert!(dir.is_dir(), "the unpacked library stays, so a settings file can be chosen without unpacking again");
}

#[test]
fn unpack_refusals_change_nothing() {
    let t = TempDir::new("refuse");
    let snap = plain_snapshot(&t, "s", false);
    let code = |params: Value| -> String {
        assert!(start("unpack_library", params).is_null());
        last_error()["code"].as_str().unwrap().to_string()
    };
    // the folder already holds something
    let full = t.path("full");
    std::fs::create_dir_all(&full).unwrap();
    std::fs::write(full.join("x"), b"x").unwrap();
    assert_eq!(code(json!({"snapshot_path": snap.to_str().unwrap(), "dir": full.to_str().unwrap()})), "bad_json");
    assert!(full.join("x").exists());
    // not a tar archive
    let junk = t.path("junk.snapshot");
    std::fs::write(&junk, vec![7u8; 4096]).unwrap();
    assert_eq!(code(json!({"snapshot_path": junk.to_str().unwrap(), "dir": t.path("a").to_str().unwrap()})), "io");
    assert!(!t.path("a").exists());
    // missing file, bad settings
    assert_eq!(code(json!({"snapshot_path": t.path("none").to_str().unwrap(), "dir": t.path("b").to_str().unwrap()})), "not_found");
    assert_eq!(
        code(json!({"snapshot_path": snap.to_str().unwrap(), "dir": t.path("c").to_str().unwrap(), "settings": {"library_id": "x"}})),
        "bad_json"
    );
    // too little room: snapshot size + 256 MiB margin
    let size = std::fs::metadata(&snap).unwrap().len();
    let needed = size + libadd_margin(size);
    assert!(start("unpack_library", json!({"snapshot_path": snap.to_str().unwrap(), "dir": t.path("d").to_str().unwrap(),
                                           "fake_available_bytes": needed - 1})).is_null());
    let e = last_error();
    assert_eq!(e["code"], "no_space");
    assert_eq!(e["needed"], needed);
    assert!(!t.path("d").exists());
    let p = run("unpack_library", json!({"snapshot_path": snap.to_str().unwrap(), "dir": t.path("d").to_str().unwrap(),
                                         "fake_available_bytes": needed}));
    assert_eq!(p["state"], "done", "exactly the needed bytes is enough: {p}");
    // a tar that is not a shard snapshot fails, and the folder is removed again
    let other = t.path("other.tar");
    {
        let mut b = tar::Builder::new(std::fs::File::create(&other).unwrap());
        let mut h = tar::Header::new_gnu();
        h.set_size(5);
        h.set_mode(0o644);
        h.set_cksum();
        b.append_data(&mut h, "hello.txt", &b"hello"[..]).unwrap();
        b.finish().unwrap();
    }
    let p = run("unpack_library", json!({"snapshot_path": other.to_str().unwrap(), "dir": t.path("e").to_str().unwrap()}));
    assert_eq!(p["state"], "failed", "{p}");
    assert!(!t.path("e").exists(), "a failed unpack removes its folder");
    // check_library on a missing folder
    assert!(start("check_library", json!({"library_path": t.path("none").to_str().unwrap()})).is_null());
    assert_eq!(last_error()["code"], "not_found");
    // the template needs a folder that exists
    assert!(start("library_template", json!({"out_path": ""})).is_null());
    let p = run("library_template", json!({"out_path": t.path("no/such/x.tar").to_str().unwrap()}));
    assert_eq!(p["state"], "failed");
    assert_eq!(p["error"]["code"], "not_found");
}

fn libadd_margin(size: u64) -> u64 {
    cache_search::libupdate::margin_for(size)
}
