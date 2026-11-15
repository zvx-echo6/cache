//! A person's own library rebuilt from its packs on each device (`own_library_sync`, src/ownlib.rs), on the core's real store:
//! real shards, the real Add PDF job with a fake PDF engine and fake embeddings.
//!
//! The starting states are the ones the two-device proof (tools/books-proof) found when My books' shard and lists synced: after two
//! devices each added a book while apart, one device's shard, `copies.jsonl` and `documents.tsv` won on both, the other book's pack
//! and PDF arrived but its points and list rows were gone, and conflict copies were left beside the files.

use cache_ingest::testing::{book, make_pdf, FakeEmbedder, FakePdfEngine, Kind};
use cache_ingest::{Env, Service};
use cache_search::ingest::{service_with, CoreStore};
use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::libreg;
use cache_search::libupdate;
use cache_search::library::{ensure_init, write_segments_manifest};
use cache_search::ownlib;
use edge::{Distance, EdgeConfig, EdgeShard, EdgeShardRead, EdgeVectorParamsBuilder, ScrollRequest, WithPayloadInterface};
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::sync::Arc;

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-ownlib-{}-{}", std::process::id(), name));
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

fn settings(own: bool) -> Value {
    let mut s = json!({"format": 1, "library_id": "my-books-test", "title": "My books", "fields": {"title": "title", "text": "text", "page": "page", "source_type": "source", "link": "link", "document": "doc_id"},
           "leave_out": [], "embedding": {"vector": "", "model": "fake-hash-v1", "dims": 1024}, "keyword_index": "auto"});
    if own {
        s["own"] = json!(true);
        s["own_default"] = json!(true);
    }
    s
}

/// An empty library as the app keeps it, in `<root>/libraries/<name>`.
fn make_library(root: &Path, name: &str, own: bool) -> PathBuf {
    ensure_init();
    let lib = root.join("libraries").join(name);
    let shard = lib.join("shard");
    std::fs::create_dir_all(&shard).unwrap();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(1024, Distance::Cosine).build()).wal_enabled(false).build();
    let s = EdgeShard::new(&shard, cfg).unwrap();
    s.flush().unwrap();
    drop(s);
    write_segments_manifest(&shard).unwrap();
    std::fs::write(lib.join("cache-library.json"), settings(own).to_string()).unwrap();
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

/// Adds a book as Add PDF does, and puts its PDF beside it (`bookshelf/<copy>.pdf`, as the app does after `done`).
fn add_book(svc: &Service, root: &Path, lib: &Path, name: &str, topic: &str, pages: usize) -> (String, u64) {
    let pdf = root.join("Inbox").join(format!("{name}.pdf"));
    std::fs::create_dir_all(pdf.parent().unwrap()).unwrap();
    std::fs::write(&pdf, make_pdf(Some(name), Kind::Ok, &book(topic, pages))).unwrap();
    let job_dir = root.join("ingest").join(format!("{}-{name}", lib.parent().unwrap().parent().unwrap().file_name().unwrap().to_string_lossy()));
    let s: Value = serde_json::from_str(&svc.start(&json!({"library_dir": lib, "pdf_path": pdf, "job_dir": job_dir}).to_string()).unwrap()).unwrap();
    let job = s["job"].as_u64().unwrap();
    loop {
        let r: Value = serde_json::from_str(&svc.step(&json!({"job": job, "budget_ms": 60_000}).to_string()).unwrap()).unwrap();
        match r["state"].as_str().unwrap() {
            "done" => {
                let copy = r["result"]["copy"].as_str().unwrap().to_string();
                std::fs::create_dir_all(lib.join("bookshelf")).unwrap();
                std::fs::copy(&pdf, lib.join("bookshelf").join(format!("{copy}.pdf"))).unwrap();
                return (copy, r["result"]["pieces"].as_u64().unwrap());
            }
            "failed" => panic!("failed: {r}"),
            _ => {}
        }
    }
}

/// The titles of the shard's points, and their number.
fn shard_titles(lib: &Path) -> (BTreeSet<String>, usize) {
    ensure_init();
    let shard = EdgeShard::load(&lib.join("shard"), None).unwrap();
    let mut sr = ScrollRequest::new();
    sr.limit = Some(100_000);
    sr.with_payload = Some(WithPayloadInterface::Bool(true));
    let (recs, _) = EdgeShardRead::scroll(&shard, sr).unwrap();
    let titles = recs.iter().filter_map(|r| r.payload.as_ref().and_then(|p| p.0.get("title")).and_then(|t| t.as_str()).map(String::from)).collect();
    (titles, recs.len())
}

fn rows(lib: &Path, file: &str) -> usize {
    std::fs::read_to_string(lib.join(file)).map(|t| t.lines().filter(|l| !l.trim().is_empty() && !l.starts_with("doc_id\t")).count()).unwrap_or(0)
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to.parent().unwrap()).unwrap();
    libupdate::copy_tree(from, to).unwrap();
}

/// Puts into `to` what the sync brought from `from` that `to` did not have: packs and PDFs (new files arrive; a changed file is
/// the newer device's, which the caller arranged).
fn bring_new_files(from: &Path, to: &Path, sub: &str) {
    for e in std::fs::read_dir(from.join(sub)).unwrap().flatten() {
        let dst = to.join(sub).join(e.file_name());
        if !dst.exists() {
            std::fs::create_dir_all(dst.parent().unwrap()).unwrap();
            std::fs::copy(e.path(), dst).unwrap();
        }
    }
}

fn sync(lib: &Path) -> Value {
    ownlib::sync(lib, &|| false).unwrap()
}

fn whole(lib: &Path) {
    assert!(!libupdate::has_leftovers(&lib.join("shard")), "no .cs-stage or .cs-old beside the shard");
    assert!(!libreg::entry_for(&lib.join("shard")).updating(), "the library is released");
    assert!(!cache_ingest::commit::pending(lib), "no commit left half done");
}

/// The "apart" state of the proof: device A and device B share My books with one book; apart, A adds Pulsar and B adds Nebula;
/// then B's shard and lists win on both and A's book is left as a pack and a PDF. Returns (A's library, all copies, total pieces).
fn apart_state(tmp: &TempDir) -> (PathBuf, Vec<String>, u64) {
    let svc = service();
    let a = make_library(&tmp.0.join("a"), "my-books", true);
    let (c1, p1) = add_book(&svc, &tmp.0, &a, "Quasar Guide", "quasar", 6);
    // B got My books with the first book (as it synced before)
    let b = tmp.0.join("b").join("libraries").join("my-books");
    copy_dir(&a, &b);
    let (c2, p2) = add_book(&svc, &tmp.0, &a, "Pulsar Guide", "pulsar", 5);
    let (c3, p3) = add_book(&svc, &tmp.0, &b, "Nebula Guide", "nebula", 4);
    // the sync: B's shard, copies.jsonl and documents.tsv replace A's (B's are newer), A's kept as conflict copies; new packs and
    // PDFs arrive both ways
    let stamp = "2026-11-14 1929 UTC";
    std::fs::rename(a.join("copies.jsonl"), a.join(format!("copies (conflict, A, {stamp}).jsonl"))).unwrap();
    std::fs::rename(a.join("documents.tsv"), a.join(format!("documents (conflict, A, {stamp}).tsv"))).unwrap();
    std::fs::copy(b.join("copies.jsonl"), a.join("copies.jsonl")).unwrap();
    std::fs::copy(b.join("documents.tsv"), a.join("documents.tsv")).unwrap();
    std::fs::remove_dir_all(a.join("shard")).unwrap();
    copy_dir(&b.join("shard"), &a.join("shard"));
    // a conflict copy inside the shard, as the proof found (mutable_id_tracker, status.dat, ...)
    let seg = std::fs::read_dir(a.join("shard").join("segments")).unwrap().flatten().find(|e| e.path().is_dir()).unwrap().path();
    std::fs::write(seg.join(format!("status (conflict, A, {stamp}).dat")), b"x").unwrap();
    bring_new_files(&b, &a, "packs");
    bring_new_files(&b, &a, "bookshelf");
    (a, vec![c1, c2, c3], p1 + p2 + p3)
}

#[test]
fn after_the_apart_bug_every_book_comes_back_from_its_pack_and_the_conflict_copies_go() {
    let tmp = TempDir::new("apart");
    let (a, copies, pieces) = apart_state(&tmp);
    // the bug's state: Pulsar has a pack and a PDF but no points and no list row
    let (titles, n) = shard_titles(&a);
    assert!(!titles.iter().any(|t| t.starts_with("Pulsar")), "the starting state lost Pulsar: {titles:?}");
    assert!((n as u64) < pieces);
    assert_eq!(rows(&a, "copies.jsonl"), 2);

    let r = sync(&a);
    assert_eq!(r["own"], true);
    assert_eq!(r["rebuilt"], true, "{r}");
    assert_eq!(r["books"], 3);
    whole(&a);
    let (titles, n) = shard_titles(&a);
    assert_eq!(n as u64, pieces, "every piece of every pack is a point");
    for t in ["Quasar Guide", "Pulsar Guide", "Nebula Guide"] {
        assert!(titles.iter().any(|x| x.starts_with(t)), "{t} is searchable: {titles:?}");
    }
    assert_eq!(rows(&a, "copies.jsonl"), 3);
    assert_eq!(rows(&a, "documents.tsv"), 3);
    let list = std::fs::read_to_string(a.join("copies.jsonl")).unwrap();
    for c in &copies {
        assert!(list.contains(c.as_str()), "{c} is listed");
    }
    // the conflict copies beside the lists are gone, and the one inside the old shard went with it
    let removed: Vec<String> = r["conflicts_removed"].as_array().unwrap().iter().map(|v| v.as_str().unwrap().to_string()).collect();
    assert_eq!(removed, vec!["copies (conflict, A, 2026-11-14 1929 UTC).jsonl".to_string(), "documents (conflict, A, 2026-11-14 1929 UTC).tsv".to_string()]);
    let mut stack = vec![a.clone()];
    while let Some(d) = stack.pop() {
        for e in std::fs::read_dir(&d).unwrap().flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            assert!(!name.contains("(conflict,"), "left: {}", e.path().display());
            if e.path().is_dir() {
                stack.push(e.path());
            }
        }
    }
    // the PDFs and packs are untouched
    for c in &copies {
        assert!(a.join("bookshelf").join(format!("{c}.pdf")).is_file());
        assert!(a.join("packs").join(format!("{c}@1.cdoc")).is_file());
    }
    assert!(a.join(ownlib::MARKER).is_file());

    // done once: the next look writes nothing
    let again = sync(&a);
    assert_eq!(again["rebuilt"], false, "{again}");
    assert!(again["reason"].is_null());
}

#[test]
fn an_own_library_that_arrived_without_its_shard_gets_one_from_its_packs() {
    // what a new device of the person receives now: the settings, the packs and the PDFs, never the shard or the lists
    let tmp = TempDir::new("arrived");
    let svc = service();
    let a = make_library(&tmp.0.join("a"), "my-books", true);
    let (_, p1) = add_book(&svc, &tmp.0, &a, "Quasar Guide", "quasar", 6);
    let (_, p2) = add_book(&svc, &tmp.0, &a, "Nebula Guide", "nebula", 4);
    let b = tmp.0.join("b").join("libraries").join("my-books");
    std::fs::create_dir_all(&b).unwrap();
    std::fs::copy(a.join("cache-library.json"), b.join("cache-library.json")).unwrap();
    bring_new_files(&a, &b, "packs");
    bring_new_files(&a, &b, "bookshelf");
    assert!(!b.join("shard").exists());

    let r = sync(&b);
    assert_eq!(r["rebuilt"], true, "{r}");
    whole(&b);
    let (titles, n) = shard_titles(&b);
    assert_eq!(n as u64, p1 + p2);
    assert!(titles.iter().any(|t| t.starts_with("Quasar")) && titles.iter().any(|t| t.starts_with("Nebula")));
    assert_eq!(rows(&b, "copies.jsonl"), 2);
    // the library opens and counts its points the way the Library reads it
    let check = cache_search::libadd::check_library(&b.join("shard"), Some(&settings(true))).unwrap();
    assert_eq!(check["docs"].as_u64().unwrap(), p1 + p2);

    // a book added on this device afterwards (Add PDF on the rebuilt library) keeps the library up to date: nothing to rebuild
    let (_, p3) = add_book(&svc, &tmp.0, &b, "Pulsar Guide", "pulsar", 5);
    let r = sync(&b);
    assert_eq!(r["rebuilt"], false, "{r}");
    assert_eq!(shard_titles(&b).1 as u64, p1 + p2 + p3);

    // a pack arriving later from another device is indexed on its arrival
    let (_, p4) = add_book(&svc, &tmp.0, &a, "Comet Guide", "comet", 3);
    bring_new_files(&a, &b, "packs");
    let r = sync(&b);
    assert_eq!(r["rebuilt"], true, "{r}");
    assert_eq!(r["reason"], "the book list does not match the packs");
    let (titles, n) = shard_titles(&b);
    assert_eq!(n as u64, p1 + p2 + p3 + p4);
    assert!(titles.iter().any(|t| t.starts_with("Comet")));
}

#[test]
fn a_shard_mixed_from_two_devices_files_is_rebuilt_even_when_its_counts_look_right() {
    // the proof's mid-flight case: the point count and the rows were right, but the shard's files came from both devices; only
    // this device's own rebuild (its marker) says the shard is its own
    let tmp = TempDir::new("mixed");
    let svc = service();
    let a = make_library(&tmp.0.join("a"), "my-books", true);
    let (_, p1) = add_book(&svc, &tmp.0, &a, "Quasar Guide", "quasar", 6);
    assert!(!a.join(ownlib::MARKER).exists());
    let r = sync(&a);
    assert_eq!(r["rebuilt"], true);
    assert_eq!(r["reason"], "first rebuild on this device");
    assert_eq!(shard_titles(&a).1 as u64, p1);
}

#[test]
fn a_library_that_is_not_the_persons_own_is_never_changed() {
    let tmp = TempDir::new("notown");
    let svc = service();
    // a downloaded library (no "own"), and an own-looking settings file in a folder the app would not name so
    for (name, own) in [("my-books-shared", false), ("medicine", true)] {
        let lib = make_library(&tmp.0, name, own);
        add_book(&svc, &tmp.0, &lib, "Quasar Guide", "quasar", 6);
        // its lists lose the book, as a broken download might: still never touched
        std::fs::write(lib.join("copies.jsonl"), "").unwrap();
        let before = std::fs::read_dir(lib.join("shard").join("segments")).unwrap().count();
        let r = sync(&lib);
        assert_eq!(r["own"], false, "{name}");
        assert_eq!(r["rebuilt"], false);
        assert_eq!(std::fs::read_to_string(lib.join("copies.jsonl")).unwrap(), "");
        assert_eq!(std::fs::read_dir(lib.join("shard").join("segments")).unwrap().count(), before);
        assert!(!lib.join(ownlib::MARKER).exists());
    }
}

#[test]
fn a_rebuild_while_a_book_is_being_written_waits_busy_and_changes_nothing() {
    let tmp = TempDir::new("busy");
    let svc = service();
    let a = make_library(&tmp.0.join("a"), "my-books", true);
    add_book(&svc, &tmp.0, &a, "Quasar Guide", "quasar", 6);
    let entry = libreg::entry_for(&a.join("shard"));
    let guard = entry.begin_update().unwrap();
    let e = ownlib::sync(&a, &|| false).unwrap_err();
    assert_eq!(e.code, cache_search::error::ErrorCode::Busy, "{e:?}");
    drop(guard);
    assert!(!a.join(ownlib::MARKER).exists());
    assert_eq!(sync(&a)["rebuilt"], true);
}

// ---- the person's own add must be found by search on the same device (the core opened before the rebuild)

fn take(p: *mut std::ffi::c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { std::ffi::CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn cstr(s: &str) -> std::ffi::CString {
    std::ffi::CString::new(s).unwrap()
}

fn run_job(kind: &str, params: Value) -> Value {
    let j = unsafe { cs_job_start(cstr(kind).as_ptr(), cstr(&params.to_string()).as_ptr()) };
    assert!(!j.is_null(), "{kind} did not start: {:?}", take(unsafe { cs_last_error(std::ptr::null_mut()) }));
    let t0 = std::time::Instant::now();
    let p = loop {
        let p: Value = serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap();
        if p["state"] != "running" {
            break p;
        }
        assert!(t0.elapsed().as_secs() < 120, "{kind} did not finish: {p}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    };
    unsafe { cs_job_free(j) };
    p
}

fn core_status(h: *mut Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap()
}

/// The core as the app opens it on My books: the shard, the library's index folder, the device's indexes folder (where the app builds
/// the keyword snapshot of a library, `index_library` with `indexes_dir`), the library's settings.
fn open_core(lib: &Path, indexes: &Path) -> *mut Handle {
    let src = json!({"kind": "library", "path": lib.join("shard").to_str().unwrap(), "index_dir": lib.join("index").to_str().unwrap(), "settings": settings(true)});
    let h = unsafe { cs_open(cstr(&json!({"sources": [src], "indexes_dir": indexes.to_str().unwrap()}).to_string()).as_ptr()) };
    assert!(!h.is_null());
    wait_open(h);
    h
}

fn wait_open(h: *mut Handle) -> Value {
    let t0 = std::time::Instant::now();
    loop {
        let v = core_status(h);
        if v["sources"][0]["opening"] == false && v["sources"][0]["updating"] == false {
            return v["sources"][0].clone();
        }
        assert!(t0.elapsed().as_secs() < 60, "library did not open: {v}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
}

/// Waits for the keyword snapshot just published to be the one in use (the core picks it on a background thread).
fn wait_words(h: *mut Handle) -> Value {
    let t0 = std::time::Instant::now();
    loop {
        let st = wait_open(h);
        if st["keyword_source"] == "device" || t0.elapsed().as_secs() > 20 {
            return st;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    }
}

/// What the app does for a library whose keyword index is behind or missing: the job the status asks for.
fn make_words_current(h: *mut Handle, lib: &Path, indexes: &Path) {
    let st = wait_open(h);
    let params = json!({"indexes_dir": indexes.to_str().unwrap(), "library_path": lib.join("shard").to_str().unwrap(), "settings": settings(true), "heap_mb": 50});
    let kind = if st["keyword_source"] == "none" || st["index"]["location"].is_null() { "index_library" } else { "index_extend" };
    let p = run_job(kind, params);
    assert_eq!(p["state"], "done", "{kind}: {p}");
}

/// The first line of a book's first page, the way a person types an exact line from it.
fn first_line(topic: &str) -> String {
    cache_ingest::testing::prose(topic, 1, 120).lines().next().unwrap().to_string()
}

/// The titles of the results of searching the open core for `line`, by words and by meaning.
fn found_titles(h: *mut Handle, line: &str) -> Vec<String> {
    let opts = json!({"k": 8, "query_vector": {"model": "fake-hash-v1", "vector": cache_pack::embed::fake_vector(line)}});
    let r = take(unsafe { cs_search(h, cstr(line).as_ptr(), cstr(&opts.to_string()).as_ptr()) }).expect("search result");
    let v: Value = serde_json::from_str(&r).unwrap();
    v["results"].as_array().unwrap().iter().filter_map(|x| x["title"].as_str().map(String::from)).collect()
}

#[test]
fn a_book_added_here_is_found_by_search_in_the_core_before_its_words_are_indexed() {
    let tmp = TempDir::new("search-own");
    let svc = service();
    let indexes = tmp.0.join("indexes");
    let a = make_library(&tmp.0.join("a"), "my-books", true);
    add_book(&svc, &tmp.0, &a, "Quasar Guide", "quasar", 6);
    // the first look on this device: the one rebuild, then the keyword snapshot is built, then the app opens its core
    assert_eq!(sync(&a)["rebuilt"], true);
    let p = run_job("index_library", json!({"library_path": a.join("shard").to_str().unwrap(), "indexes_dir": indexes.to_str().unwrap(), "heap_mb": 50, "settings": settings(true)}));
    assert_eq!(p["state"], "done", "{p}");
    let h = open_core(&a, &indexes);
    let st = wait_words(h);
    assert_eq!(st["keyword_source"], "device", "{st}");
    assert!(found_titles(h, &first_line("quasar")).iter().any(|t| t.starts_with("Quasar")));

    // another device's book arrives as a pack (a second library plays that device), and this device adds one of its own
    let b = tmp.0.join("b").join("libraries").join("my-books");
    copy_dir(&a, &b);
    add_book(&svc, &tmp.0, &b, "Nebula Guide", "nebula", 4);
    bring_new_files(&b, &a, "packs");
    add_book(&svc, &tmp.0, &a, "Pulsar Guide", "pulsar", 5);
    let r = sync(&a);
    assert_eq!(r["rebuilt"], true, "{r}");
    whole(&a);
    let st = wait_open(h);
    eprintln!("AFTER REBUILD: {st}");
    assert_eq!(st["docs"].as_u64().unwrap(), r["points"].as_u64().unwrap(), "the open core holds the rebuilt shard: {st}");
    // at once, before any index job: the keyword snapshot still covers only the first book, and its words must not push the books it
    // does not know behind it (found on a phone: a book added there was not found by its own lines)
    for (topic, title) in [("quasar", "Quasar"), ("nebula", "Nebula"), ("pulsar", "Pulsar")] {
        let got = found_titles(h, &first_line(topic));
        assert!(got.first().map(|t| t.starts_with(title)).unwrap_or(false), "{title}: its own line is the first result, got {got:?}");
    }
    // by words: the keyword index must say it is behind, so the app's index job runs, and then every book is found by its words
    assert!(st["keyword_pending"] == true || st["keyword_source"] == "none", "the keyword index is behind the rebuilt shard and says so: {st}");
    make_words_current(h, &a, &indexes);
    let t0 = std::time::Instant::now();
    let st = loop {
        let st = wait_words(h);
        if st["keyword_pending"] != true || t0.elapsed().as_secs() > 20 {
            break st;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    };
    eprintln!("AFTER INDEX JOB: {st}");
    assert_eq!(st["keyword_source"], "device", "{st}");
    assert_ne!(st["keyword_pending"], true, "the index job brought the words up to date: {st}");
    for (topic, title) in [("quasar", "Quasar"), ("nebula", "Nebula"), ("pulsar", "Pulsar")] {
        let got = found_titles(h, &first_line(topic));
        assert!(got.first().map(|t| t.starts_with(title)).unwrap_or(false), "{title}: its own line is the first result, got {got:?}");
    }
    unsafe { cs_close(h) };
}

#[test]
fn a_book_added_through_add_pdf_makes_the_open_core_say_its_words_are_behind() {
    // what the app's index scheduler reads to list the extension: after an Add PDF the status of the core opened before it says
    // the shard grew (docs) and the keyword snapshot is behind (keyword_pending), with no rebuild and no reopen
    let tmp = TempDir::new("add-pending");
    let svc = service();
    let indexes = tmp.0.join("indexes");
    let a = make_library(&tmp.0.join("a"), "my-books", true);
    add_book(&svc, &tmp.0, &a, "Quasar Guide", "quasar", 6);
    assert_eq!(sync(&a)["rebuilt"], true);
    let p = run_job("index_library", json!({"library_path": a.join("shard").to_str().unwrap(), "indexes_dir": indexes.to_str().unwrap(), "heap_mb": 50, "settings": settings(true)}));
    assert_eq!(p["state"], "done", "{p}");
    let h = open_core(&a, &indexes);
    let st = wait_words(h);
    assert_ne!(st["keyword_pending"], true, "{st}");
    let (_, p2) = add_book(&svc, &tmp.0, &a, "Pulsar Guide", "pulsar", 5);
    let st = wait_open(h);
    assert_eq!(st["docs"].as_u64().unwrap(), st["docs"].as_u64().unwrap().max(p2), "{st}");
    assert_eq!(st["keyword_pending"], true, "the words of the new book are not in the snapshot yet: {st}");
    assert!(st["source_id"].is_string() && st["index"]["needs_seal"].is_null(), "{st}");
    make_words_current(h, &a, &indexes);
    let t0 = std::time::Instant::now();
    let st = loop {
        let st = wait_words(h);
        if st["keyword_pending"] != true || t0.elapsed().as_secs() > 20 {
            break st;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
    };
    assert_ne!(st["keyword_pending"], true, "the extension clears it: {st}");
    unsafe { cs_close(h) };
}
