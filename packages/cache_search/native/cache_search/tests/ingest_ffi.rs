//! The Add PDF job on the core's own library store (packages/cache_ingest/INGEST-API.md): a real shard and a real keyword index, a
//! generated PDF read by a fake PDF engine, fake embeddings. The job's logic is tested in packages/cache_ingest/tests/ingest.rs.

use cache_ingest::testing::{book, make_pdf, FakeEmbedder, FakePdfEngine, Kind};
use cache_ingest::{Code, Env, LibraryStore, Point, Service};
use cache_search::ingest::{service_with, CoreStore};
use cache_search::libindex::{build_library_index, keyword_hits, LibBuildParams, LibOpenIndex, TOKENIZER};
use cache_search::libreg;
use cache_search::libupdate;
use cache_search::library::{ensure_init, write_segments_manifest};
use edge::{Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::Arc;

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-ingest-{}-{}", std::process::id(), name));
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

fn settings() -> Value {
    json!({"format": 1, "library_id": "mine", "title": "Mine", "fields": {"title": "title", "text": "text", "page": "page", "source_type": "source", "link": "link", "document": "doc_id"},
           "leave_out": [], "embedding": {"vector": "", "model": "fake-hash-v1", "dims": 1024}, "keyword_index": "auto"})
}

/// An empty library as the app keeps it: `shard/` (one unnamed 1024-dimension Cosine vector) and `cache-library.json`.
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

fn docs(lib: &Path) -> u64 {
    cache_search::libadd::check_library(&lib.join("shard"), Some(&settings())).unwrap()["docs"].as_u64().unwrap()
}

fn add_book(svc: &Service, root: &Path, lib: &Path, name: &str, topic: &str, pages: usize) -> Value {
    let pdf = root.join("Inbox").join(format!("{name}.pdf"));
    std::fs::create_dir_all(pdf.parent().unwrap()).unwrap();
    std::fs::write(&pdf, make_pdf(Some(name), Kind::Ok, &book(topic, pages))).unwrap();
    let s: Value = serde_json::from_str(&svc.start(&json!({"library_dir": lib, "pdf_path": pdf, "job_dir": root.join("ingest").join(name)}).to_string()).unwrap()).unwrap();
    let job = s["job"].as_u64().unwrap();
    loop {
        let r: Value = serde_json::from_str(&svc.step(&json!({"job": job, "budget_ms": 60_000}).to_string()).unwrap()).unwrap();
        match r["state"].as_str().unwrap() {
            "done" => return r,
            "failed" => panic!("failed: {r}"),
            _ => {}
        }
    }
}

fn no_leftovers(lib: &Path) {
    let shard = lib.join("shard");
    assert!(!libupdate::has_leftovers(&shard), "no .cs-stage or .cs-old beside the shard");
    for n in ["index.cs-stage", "index.cs-old"] {
        assert!(!lib.join(n).exists(), "{n} is left");
    }
    assert!(!libreg::entry_for(&shard).updating(), "the library is released");
}

#[test]
fn a_book_is_added_to_the_shard_and_the_library_is_whole() {
    let tmp = TempDir::new("whole");
    let lib = make_library(&tmp.0);
    assert_eq!(docs(&lib), 0);
    let svc = service();
    let done = add_book(&svc, &tmp.0, &lib, "Quasar Guide", "quasar", 6);
    let pieces = done["result"]["pieces"].as_u64().unwrap();
    assert!(pieces >= 3);
    assert_eq!(docs(&lib), pieces, "every piece is a point");
    no_leftovers(&lib);
    let copy = done["result"]["copy"].as_str().unwrap();
    assert!(lib.join("packs").join(format!("{copy}@1.cdoc")).is_file());
    assert!(std::fs::read_to_string(lib.join("copies.jsonl")).unwrap().contains(copy));
    // a second book adds to the first
    let second = add_book(&svc, &tmp.0, &lib, "Nebula Guide", "nebula", 5);
    assert_eq!(docs(&lib), pieces + second["result"]["pieces"].as_u64().unwrap());
    assert_eq!(std::fs::read_to_string(lib.join("copies.jsonl")).unwrap().lines().count(), 2);
    no_leftovers(&lib);
    // the same book again changes nothing (the points have fixed ids)
    let again = add_book(&svc, &tmp.0, &lib, "Quasar Guide", "quasar", 6);
    assert_eq!(again["result"]["copy"], done["result"]["copy"]);
    assert_eq!(docs(&lib), pieces + second["result"]["pieces"].as_u64().unwrap());
    assert_eq!(std::fs::read_to_string(lib.join("copies.jsonl")).unwrap().lines().count(), 2, "its line is replaced, not repeated");
}

#[test]
fn the_keyword_index_gets_the_new_book() {
    let tmp = TempDir::new("kw");
    let lib = make_library(&tmp.0);
    let svc = service();
    let first = add_book(&svc, &tmp.0, &lib, "Quasar Guide", "quasar", 5);
    // the device builds its keyword index when the library is added; here, over the first book
    let idx = lib.join("index");
    std::fs::create_dir_all(&idx).unwrap();
    let cfg = settings();
    let p = LibBuildParams { threads: Some(1), pace: None, library_path: &lib.join("shard"), settings: Some(&cfg), index_dir: &idx, heap_mb: 15, checkpoint_docs: 1000 };
    build_library_index(&p, &|_, _| {}, &|| false).unwrap();
    let before = LibOpenIndex::open(&idx, TOKENIZER).unwrap();
    assert_eq!(before.docs, first["result"]["pieces"].as_u64().unwrap());
    assert!(keyword_hits(&before, "nebula", 10).unwrap().0.is_empty());
    drop(before);

    let second = add_book(&svc, &tmp.0, &lib, "Nebula Guide", "nebula", 5);
    no_leftovers(&lib);
    let after = LibOpenIndex::open(&idx, TOKENIZER).unwrap();
    assert_eq!(after.docs, first["result"]["pieces"].as_u64().unwrap() + second["result"]["pieces"].as_u64().unwrap());
    let (hits, _) = keyword_hits(&after, "nebula", 50).unwrap();
    assert!(!hits.is_empty(), "the new book is found by its words");
    assert!(!keyword_hits(&after, "quasar", 50).unwrap().0.is_empty(), "the old book still is");
    // the hits are points of the shard
    assert_eq!(docs(&lib), after.docs);
}

fn commit_staged(lib: &Path, staged: &mut Box<dyn cache_ingest::Staged>) {
    let steps: Vec<cache_ingest::commit::Step> =
        staged.plan().into_iter().map(|s| cache_ingest::commit::Step { old: format!("{}.cs-old", s.target), target: s.target, stage: s.stage }).collect();
    cache_ingest::commit::run(lib, &steps, &mut **staged).unwrap();
}

fn point(i: u32) -> Point {
    let doc = "xxxxxxxx".to_string();
    let id = format!("00000000-0000-4000-8000-{i:012}");
    let mut v = vec![0f32; 1024];
    v[i as usize] = 1.0;
    Point { id, vector: v, payload: json!({"title": "T", "text": format!("a lone passage {i}"), "page": 1, "source": "book", "link": "", "doc_id": doc, "doc_version": 1}) }
}

#[test]
fn the_library_is_updating_while_a_write_is_staged_and_a_dropped_write_changes_nothing() {
    let tmp = TempDir::new("stage");
    let lib = make_library(&tmp.0);
    let shard = lib.join("shard");
    let entry = libreg::entry_for(&shard);
    assert!(!entry.updating());
    let staged = CoreStore.begin(&lib, &[point(1), point(2)]).expect("begin");
    assert!(entry.updating(), "search skips the library meanwhile, as during update_library");
    assert!(libupdate::has_leftovers(&shard), "the copy is beside the library, not in it");
    assert_eq!(CoreStore.begin(&lib, &[point(3)]).err().unwrap().code, Code::Busy);
    drop(staged);
    assert!(!entry.updating());
    no_leftovers(&lib);
    assert_eq!(docs(&lib), 0, "nothing was committed");

    // committed: the points are there
    let mut staged = CoreStore.begin(&lib, &[point(1), point(2)]).expect("begin");
    commit_staged(&lib, &mut staged);
    assert!(entry.updating(), "still updating until the write is finished");
    drop(staged);
    assert!(!entry.updating());
    no_leftovers(&lib);
    assert_eq!(docs(&lib), 2);

}

#[test]
fn a_second_job_gets_busy_while_an_update_owns_the_library() {
    let tmp = TempDir::new("busy");
    let lib = make_library(&tmp.0);
    let svc = service();
    let pdf = tmp.0.join("b.pdf");
    std::fs::write(&pdf, make_pdf(None, Kind::Ok, &book("beacon", 4))).unwrap();
    let s: Value = serde_json::from_str(&svc.start(&json!({"library_dir": lib, "pdf_path": pdf, "job_dir": tmp.0.join("job")}).to_string()).unwrap()).unwrap();
    let job = s["job"].as_u64().unwrap();
    // an update_library job (or another ingest job) holds the library
    let guard = libreg::entry_for(&lib.join("shard")).begin_update().unwrap();
    let e = svc.step(&json!({"job": job, "budget_ms": 60_000}).to_string()).err().unwrap();
    assert_eq!(e.code, Code::Busy);
    assert_eq!(docs(&lib), 0);
    drop(guard);
    let r: Value = serde_json::from_str(&svc.step(&json!({"job": job, "budget_ms": 60_000}).to_string()).unwrap()).unwrap();
    assert_eq!(r["state"], "done");
    assert!(docs(&lib) > 0);
}

#[test]
fn a_library_folder_without_a_shard_is_not_found_and_nothing_is_created() {
    // (the free-space check is libupdate's own, tested in update_ffi.rs)
    let tmp = TempDir::new("nolib");
    let lib = tmp.0.join("libraries").join("none");
    std::fs::create_dir_all(&lib).unwrap();
    let e = CoreStore.begin(&lib, &[point(1)]).err().unwrap();
    assert_eq!(e.code, Code::NotFound);
    assert!(!lib.join("shard").exists());
}

fn probe(v: Value) -> Value {
    serde_json::from_str(&cache_search::ingest::probe(&v.to_string()).unwrap()).unwrap()
}

#[test]
fn probe_reports_missing_engines_and_hashes_the_model_without_failing() {
    let tmp = TempDir::new("probe");
    let model = tmp.0.join("model.gguf");
    std::fs::write(&model, b"abc").unwrap();
    // the SHA-256 of "abc"
    let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad";
    let r = probe(json!({"engines": {"pdfium_lib": tmp.0.join("none.so"), "embed_lib": tmp.0.join("none-llama.so"), "embed_model": model, "embed_sha256": abc}}));
    assert_eq!(r["pdfium"]["ok"], false);
    assert!(r["pdfium"]["error"].as_str().unwrap().contains("PDFium"));
    assert_eq!(r["embedder"]["ok"], false);
    assert_eq!(r["model"], json!({"ok": true, "sha256": abc, "expected": abc, "matches": true}));
    // a wrong expected hash, and the hash reported with none expected
    let r = probe(json!({"engines": {"embed_model": model, "embed_sha256": "00"}}));
    assert_eq!((r["model"]["ok"].clone(), r["model"]["matches"].clone(), r["model"]["sha256"].clone()), (json!(false), json!(false), json!(abc)));
    let r = probe(json!({"engines": {"embed_model": model}}));
    assert_eq!((r["model"]["ok"].clone(), r["model"]["matches"].clone(), r["model"]["sha256"].clone()), (json!(true), Value::Null, json!(abc)));
    // hashing can be skipped
    let r = probe(json!({"engines": {"embed_model": model}, "hash_model": false}));
    assert_eq!((r["model"]["ok"].clone(), r["model"]["sha256"].clone()), (json!(true), Value::Null));
    // a missing model, and no engines at all: reported, not an error
    let r = probe(json!({"engines": {"embed_model": tmp.0.join("gone.gguf")}}));
    assert_eq!(r["model"]["ok"], false);
    assert!(r["model"]["error"].is_string());
    let r = probe(json!({}));
    assert_eq!((r["embedder"]["ok"].clone(), r["model"]["ok"].clone()), (json!(false), json!(false)));
    assert!(cache_search::ingest::probe("not json").is_err());
}

/// `sha256sum -c` semantics: every line's file exists and has that hash; and every file of the library that is not local (a leading
/// dot) or a copy or backup of a write is listed.
fn check_sums(lib: &Path) {
    use sha2::{Digest, Sha256};
    let text = std::fs::read_to_string(lib.join("SHA256SUMS")).unwrap();
    let mut listed = std::collections::BTreeSet::new();
    for l in text.lines() {
        let (hash, rel) = l.split_once("  ").unwrap();
        assert!(!rel.contains("cs-old") && !rel.contains("cs-stage"), "{rel} is listed");
        let bytes = std::fs::read(lib.join(rel)).unwrap_or_else(|_| panic!("{rel} is listed but not there"));
        let got: String = Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(got, hash, "{rel}");
        listed.insert(rel.to_string());
    }
    fn walk(base: &Path, dir: &Path, out: &mut Vec<String>) {
        for e in std::fs::read_dir(dir).unwrap() {
            let e = e.unwrap();
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name == "SHA256SUMS" || name.ends_with(".cs-old") || name.ends_with(".cs-stage") {
                continue;
            }
            if e.file_type().unwrap().is_dir() {
                walk(base, &e.path(), out);
            } else {
                out.push(e.path().strip_prefix(base).unwrap().to_string_lossy().replace('\\', "/"));
            }
        }
    }
    let mut on_disk = Vec::new();
    walk(lib, lib, &mut on_disk);
    for f in on_disk {
        assert!(listed.contains(&f), "{f} is in the library but not in SHA256SUMS");
    }
}

#[test]
fn sha256sums_check_out_after_every_ingest_into_a_real_library() {
    let tmp = TempDir::new("sums");
    let lib = make_library(&tmp.0);
    std::fs::write(lib.join("SHA256SUMS"), "").unwrap();
    let svc = service();
    add_book(&svc, &tmp.0, &lib, "Quasar Guide", "quasar", 5);
    check_sums(&lib);
    // with a keyword index too (a second folder swapped in)
    let idx = lib.join("index");
    std::fs::create_dir_all(&idx).unwrap();
    let cfg = settings();
    let p = LibBuildParams { threads: Some(1), pace: None, library_path: &lib.join("shard"), settings: Some(&cfg), index_dir: &idx, heap_mb: 15, checkpoint_docs: 1000 };
    build_library_index(&p, &|_, _| {}, &|| false).unwrap();
    add_book(&svc, &tmp.0, &lib, "Nebula Guide", "nebula", 5);
    check_sums(&lib);
    let text = std::fs::read_to_string(lib.join("SHA256SUMS")).unwrap();
    assert!(text.contains("documents.tsv") && text.contains("copies.jsonl") && text.contains("packs/") && text.contains("shard/"));
    assert!(std::fs::read_to_string(lib.join("documents.tsv")).unwrap().lines().count() == 3);
}

#[test]
fn a_kill_after_a_rename_is_rolled_forward_when_the_library_is_next_touched() {
    use cache_ingest::commit::{run_with, Step};
    let tmp = TempDir::new("journal");
    let lib = make_library(&tmp.0);
    let shard = lib.join("shard");
    for kill_after in [0usize, 1] {
        let before = docs(&lib);
        let mut staged = CoreStore.begin(&lib, &[point(10 + kill_after as u32)]).expect("begin");
        let steps: Vec<Step> = staged
            .plan()
            .into_iter()
            .map(|s| Step { old: format!("{}.cs-old", s.target), target: s.target, stage: s.stage })
            .collect();
        // killed after `kill_after` renames: the journal is left, the library is in between
        assert!(!run_with(&lib, &steps, &mut *staged, Some(kill_after)).unwrap());
        drop(staged);
        assert!(cache_ingest::commit::pending(&lib));
        // the next touch of the library (opening it, or the next write) finishes the commit
        libupdate::recover_if_leftovers(&shard).unwrap();
        assert!(!cache_ingest::commit::pending(&lib));
        no_leftovers(&lib);
        assert_eq!(docs(&lib), before + 1, "the book is in after a kill at {kill_after}");
    }
    // a new write also finds a journal first, and finishes it before it stages anything
    let mut staged = CoreStore.begin(&lib, &[point(20)]).expect("begin");
    let steps: Vec<Step> = staged.plan().into_iter().map(|s| Step { old: format!("{}.cs-old", s.target), target: s.target, stage: s.stage }).collect();
    assert!(!run_with(&lib, &steps, &mut *staged, Some(1)).unwrap());
    drop(staged);
    // (the two books of the loop above are in; the library cannot be counted while a commit is half done)
    let before = 2u64;
    let staged = CoreStore.begin(&lib, &[point(21)]).expect("begin");
    assert!(!cache_ingest::commit::pending(&lib));
    drop(staged);
    assert_eq!(docs(&lib), before + 1, "the interrupted book (20) is in; the dropped one (21) is not");
}
