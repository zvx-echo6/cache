//! The Add PDF job on the core's own library store (packages/cache_ingest/INGEST-API.md): a real shard and a real keyword index, a
//! generated PDF read by a fake PDF engine, fake embeddings. The job's logic is tested in packages/cache_ingest/tests/ingest.rs.

use cache_ingest::testing::{book, make_pdf, FakeEmbedder, FakePdfEngine, Kind};
use cache_ingest::{Code, Env, LibraryStore, Point, Service};
use cache_search::ingest::{service_with, CoreStore};
use cache_search::libindex::{build_library_index, keyword_hits, LibBuildParams, LibOpenIndex, TOKENIZER};
use cache_search::libreg;
use cache_search::libupdate;
use cache_search::library::{ensure_init, write_segments_manifest};
use edge::{Distance, EdgeConfig, EdgeShard, EdgeShardRead, EdgeVectorParamsBuilder, PointId, PointOperations, ScrollRequest, UpdateOperation, WithPayloadInterface};
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
           "leave_out": [], "embedding": {"vector": "", "model": "fake-hash-v1", "dims": 1024}, "keyword_index": "auto", "own": true})
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
    // the embedder's load can be skipped: the model file is still checked
    let r = probe(json!({"engines": {"embed_lib": tmp.0.join("none-llama.so"), "embed_model": model, "embed_sha256": abc}, "load_embedder": false}));
    assert_eq!(r["embedder"], json!({"ok": null, "skipped": true}));
    assert_eq!(r["model"], json!({"ok": true, "sha256": abc, "expected": abc, "matches": true}));
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

// ---------------------------------------------------------------------------------------------------------
// Filing: the sorter of the Linux builder, from the vectors the job already made

fn sha_bytes(hex: &str) -> [u8; 32] {
    let mut b = [0u8; 32];
    for (i, x) in b.iter_mut().enumerate() {
        *x = u8::from_str_radix(&hex[i * 2..i * 2 + 2], 16).unwrap();
    }
    b
}

/// A small classifier: each division's column is the fake embedder's vector of its name and words, scaled; the threshold sits between
/// a book about the divisions and a book about nothing here (as libbuild's small_model does).
fn small_model(embedding_sha: &str) -> Vec<u8> {
    use cache_classify::{encode, Class, ModelSpec, Recipe, Weights};
    use cache_ingest::testing::prose;
    use cache_pack::embed::fake_vector;
    let divs = [(510u16, "Wells", "well well wells digging"), (520, "Rain", "rainwater cistern barrel"), (710, "Radio", "radio antenna transmitter")];
    let cols: Vec<Vec<f32>> = divs.iter().map(|(_, n, t)| fake_vector(&format!("{n}. {t}"))).collect();
    let (dims, n) = (cols[0].len(), cols.len());
    let mut w = vec![0f32; dims * n];
    for (j, c) in cols.iter().enumerate() {
        for (i, x) in c.iter().enumerate() {
            w[i * n + j] = 25.0 * x;
        }
    }
    let top = |topic: &str| -> f32 {
        let v = fake_vector(&prose(topic, 1, 120).replace('\n', " "));
        let e: Vec<f32> = (0..n).map(|j| (0..dims).map(|i| v[i] * w[i * n + j]).sum::<f32>()).collect();
        let m = e.iter().cloned().fold(f32::MIN, f32::max);
        1.0 / e.iter().map(|x| (x - m).exp()).sum::<f32>()
    };
    let (pos, neg) = (top("well"), top("kiln"));
    assert!(pos > neg + 0.05, "the test model cannot tell the topics apart: {pos} {neg}");
    encode(&ModelSpec {
        classifier_version: 1,
        embedding_sha256: sha_bytes(embedding_sha),
        dims: dims as u32,
        threshold: ((pos + neg) / 2.0) as f64,
        recipe: Recipe { first_pieces: 8, spread_pieces: 16 },
        classes: divs.iter().map(|(d, n, _)| Class { division: *d, label: n.to_string() }).collect(),
        bias: vec![0.0; n],
        weights: Weights::F32(w),
    })
}

fn service_filing(classifier: Option<Arc<dyn cache_ingest::Classifier>>) -> Service {
    service_with(Box::new(move |_engines: &Value| {
        Ok(Env {
            pdf: Arc::new(FakePdfEngine::default()),
            embedder: Arc::new(FakeEmbedder::default()),
            store: Arc::new(CoreStore),
            classifier: classifier.clone(),
            clock: Arc::new(|| 1_700_000_000_000),
        })
    }))
}

fn add_shelved(svc: &Service, root: &Path, lib: &Path, name: &str, topic: &str) -> Value {
    let pdf = root.join("Inbox").join(format!("{name}.pdf"));
    std::fs::create_dir_all(pdf.parent().unwrap()).unwrap();
    std::fs::write(&pdf, make_pdf(Some(name), Kind::Ok, &book(topic, 5))).unwrap();
    let p = json!({"library_dir": lib, "pdf_path": pdf, "job_dir": root.join("ingest").join(name), "bookshelves": {"dir": root.join("bookshelves"), "dev": "phone-1"}});
    let s: Value = serde_json::from_str(&svc.start(&p.to_string()).unwrap()).unwrap();
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

fn shelf_log(root: &Path) -> Vec<Value> {
    std::fs::read_to_string(root.join("bookshelves").join("log").join("phone-1.jsonl")).map(|t| t.lines().map(|l| serde_json::from_str(l).unwrap()).collect()).unwrap_or_default()
}

#[test]
fn a_book_is_filed_by_the_builders_sorter_and_a_copy_of_it_is_not_scored() {
    let tmp = TempDir::new("filing");
    let lib = make_library(&tmp.0);
    let model = tmp.0.join("cache-classifier-1.bin");
    std::fs::write(&model, small_model(cache_embed::DECIDED_MODEL_SHA256)).unwrap();
    let (c, version) = cache_search::ingest::load_classifier(model.to_str().unwrap(), cache_embed::DECIDED_MODEL_SHA256).unwrap();
    assert_eq!(version, 1);
    let svc = service_filing(Some(c));

    // confident: placed in its division and given the next number; the guess is in the pack and the copies line
    let a = add_shelved(&svc, &tmp.0, &lib, "Well Book", "well");
    assert_eq!(a["result"]["shelf"], json!({"div": "510", "by": "auto"}));
    assert_eq!(a["result"]["suggested"]["div"], "510");
    assert_eq!(a["result"]["suggested"]["classifier_version"], 1);
    let ev = shelf_log(&tmp.0);
    assert_eq!(ev.iter().map(|e| e["ev"].as_str().unwrap()).collect::<Vec<_>>(), vec!["place", "assign"]);
    assert_eq!((ev[0]["div"].as_str(), ev[0]["by"].as_str(), ev[1]["seq"].as_u64()), (Some("510"), Some("auto"), Some(1)));
    let copy = a["result"]["copy"].as_str().unwrap();
    let pack = cache_pack::pack::read_pack(&lib.join("packs").join(format!("{copy}@1.cdoc"))).unwrap();
    let sug = pack.header.book.as_ref().unwrap().suggested.clone().unwrap();
    assert_eq!((sug.div.as_str(), sug.label.as_str(), sug.source.as_str()), ("510", "Wells", "classifier"));
    // the pack says the sorter was confident, and keeps its top three (the model has three divisions)
    assert_eq!((sug.filed, sug.suggestions.len()), (Some(true), 3));
    assert_eq!(sug.suggestions[0].div, "510");
    let line: Value = std::fs::read_to_string(lib.join("copies.jsonl")).unwrap().lines().map(|l| serde_json::from_str::<Value>(l).unwrap()).find(|l| l["copy"] == copy).unwrap();
    assert_eq!((line["suggested"]["div"].as_str(), line["suggested"]["label"].as_str(), line["suggested"]["filed"].as_bool()), (Some("510"), Some("Wells"), Some(true)));
    assert_eq!(line["suggested"]["suggestions"].as_array().unwrap().len(), 3);

    // not confident: Unsorted, no place, and the guess kept
    let k = add_shelved(&svc, &tmp.0, &lib, "Kiln Book", "kiln");
    assert_eq!(k["result"]["shelf"], Value::Null);
    assert!(k["result"]["suggested"]["div"].is_string(), "the best guess is reported even though the book stays in Unsorted");
    assert_eq!(shelf_log(&tmp.0).len(), 2, "nothing was placed");
    let kc = k["result"]["copy"].as_str().unwrap();
    let ksug = cache_pack::pack::read_pack(&lib.join("packs").join(format!("{kc}@1.cdoc"))).unwrap().header.book.as_ref().unwrap().suggested.clone().unwrap();
    assert_eq!((ksug.filed, ksug.suggestions.len()), (Some(false), 3), "not confident: the pack says so and keeps the three");

    // a copy of a book on the shelves is detected, and skips filing
    let w2 = add_shelved(&svc, &tmp.0, &lib, "Well Book Again", "well");
    assert_eq!(w2["result"]["same"].as_array().unwrap().len(), 1);
    assert_eq!(w2["result"]["shelf"], Value::Null);
    assert_eq!(w2["result"]["suggested"], Value::Null);
    let ev = shelf_log(&tmp.0);
    assert_eq!(ev.len(), 3);
    assert_eq!(ev[2]["ev"], "same");
    let c2 = w2["result"]["copy"].as_str().unwrap();
    assert!(cache_pack::pack::read_pack(&lib.join("packs").join(format!("{c2}@1.cdoc"))).unwrap().header.book.as_ref().unwrap().suggested.is_none());
}

#[test]
fn a_classifier_trained_on_another_embedder_is_refused_and_the_book_goes_to_unsorted() {
    let tmp = TempDir::new("otherembed");
    let lib = make_library(&tmp.0);
    let model = tmp.0.join("cache-classifier-2.bin");
    std::fs::write(&model, small_model(&"ab".repeat(32))).unwrap();
    let e = cache_search::ingest::load_classifier(model.to_str().unwrap(), cache_embed::DECIDED_MODEL_SHA256).err().unwrap();
    assert!(e.contains("another embedding model"), "{e}");
    // the same model is accepted when the embedder in use is the one it was trained on
    assert!(cache_search::ingest::load_classifier(model.to_str().unwrap(), &"ab".repeat(32)).is_ok());
    // the service has no classifier then
    let svc = service_filing(None);
    let a = add_shelved(&svc, &tmp.0, &lib, "Well Book", "well");
    assert_eq!(a["result"]["shelf"], Value::Null);
    assert_eq!(a["result"]["suggested"], Value::Null);
    assert!(shelf_log(&tmp.0).is_empty());
    // the probe says which
    let r = probe(json!({"engines": {"classifier": model, "embed_sha256": cache_embed::DECIDED_MODEL_SHA256}}));
    assert_eq!(r["classifier"]["ok"], false);
    assert!(r["classifier"]["error"].as_str().unwrap().contains("another embedding model"));
    let good = tmp.0.join("cache-classifier-1.bin");
    std::fs::write(&good, small_model(cache_embed::DECIDED_MODEL_SHA256)).unwrap();
    assert_eq!(probe(json!({"engines": {"classifier": good}}))["classifier"], json!({"ok": true, "version": 1}));
    assert_eq!(probe(json!({}))["classifier"]["ok"], false);
}

// ---------------------------------------------------------------------------------------------------------
// Add PDF after the keyword index was sealed into a snapshot (the seal removes the library's old `index` folder)

mod sealed {
    use super::*;
    use cache_search::ffi::*;
    use cache_search::handle::Handle;
    use std::ffi::{c_char, CStr, CString};

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

    fn status(h: *mut Handle) -> Value {
        serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap()
    }

    pub fn open(lib: &Path, indexes: &Path) -> *mut Handle {
        let src = json!({"kind": "library", "path": lib.join("shard").to_str().unwrap(), "index_dir": lib.join("index").to_str().unwrap(), "settings": settings()});
        let cfg = cstr(&json!({"sources": [src], "indexes_dir": indexes.to_str().unwrap()}).to_string());
        let h = unsafe { cs_open(cfg.as_ptr()) };
        assert!(!h.is_null(), "cs_open failed: {:?}", take(unsafe { cs_last_error(std::ptr::null_mut()) }));
        let t0 = std::time::Instant::now();
        while !status(h)["sources"].as_array().unwrap().iter().all(|s| s["opening"] == false) {
            assert!(t0.elapsed().as_secs() < 120, "the library did not open");
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        h
    }

    pub fn until_snapshot(h: *mut Handle) {
        let t0 = std::time::Instant::now();
        while status(h)["sources"][0]["index"]["location"] != "snapshot" {
            assert!(t0.elapsed().as_secs() < 60, "no snapshot: {}", status(h));
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    pub fn seal(indexes: &Path) -> Value {
        let params = json!({"indexes_dir": indexes.to_str().unwrap(), "kind": "library", "source_id": "mine"});
        let j = unsafe { cs_job_start(cstr("index_seal").as_ptr(), cstr(&params.to_string()).as_ptr()) };
        assert!(!j.is_null(), "index_seal did not start: {:?}", take(unsafe { cs_last_error(std::ptr::null_mut()) }));
        let t0 = std::time::Instant::now();
        loop {
            let p: Value = serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap();
            if p["state"] != "running" {
                unsafe { cs_job_free(j) };
                return p;
            }
            assert!(t0.elapsed().as_secs() < 60);
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    pub fn pending(h: *mut Handle) -> Value {
        status(h)["sources"][0]["keyword_pending"].clone()
    }

    pub fn until_generation(h: *mut Handle, generation: u64) {
        let t0 = std::time::Instant::now();
        loop {
            let s = status(h)["sources"][0].clone();
            let snap = s["index"]["snapshot"].as_str().map(|n| n.to_string());
            if let (Some(name), "snapshot") = (snap, s["index"]["location"].as_str().unwrap_or("")) {
                let dir = std::path::PathBuf::from(s["index"]["dir"].as_str().unwrap());
                let m: Value = serde_json::from_str(&std::fs::read_to_string(dir.join("manifest.json")).unwrap()).unwrap();
                if m["generation"].as_u64().unwrap_or(0) == generation && !name.is_empty() {
                    return;
                }
            }
            assert!(t0.elapsed().as_secs() < 60, "generation {generation} did not open: {s}");
            std::thread::sleep(std::time::Duration::from_millis(20));
        }
    }

    pub fn extend(lib: &Path, indexes: &Path) -> Value {
        extend_with(lib, indexes, json!({}))
    }

    pub fn extend_with(lib: &Path, indexes: &Path, extra: Value) -> Value {
        let mut params = json!({"indexes_dir": indexes.to_str().unwrap(), "library_path": lib.join("shard").to_str().unwrap(), "settings": super::settings(), "heap_mb": 15});
        for (k, v) in extra.as_object().unwrap() {
            params[k] = v.clone();
        }
        let j = unsafe { cs_job_start(cstr("index_extend").as_ptr(), cstr(&params.to_string()).as_ptr()) };
        assert!(!j.is_null(), "index_extend did not start: {:?}", take(unsafe { cs_last_error(std::ptr::null_mut()) }));
        let t0 = std::time::Instant::now();
        loop {
            let p: Value = serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap();
            if p["state"] != "running" {
                unsafe { cs_job_free(j) };
                return p;
            }
            assert!(t0.elapsed().as_secs() < 120);
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
    }

    pub fn found(h: *mut Handle, word: &str) -> usize {
        let r = take(unsafe { cs_search(h, cstr(word).as_ptr(), cstr(r#"{"k": 20}"#).as_ptr()) }).expect("search result");
        let v: Value = serde_json::from_str(&r).unwrap();
        v["results"].as_array().map(|a| a.len()).unwrap_or(0)
    }

    pub fn close(h: *mut Handle) {
        unsafe { cs_close(h) };
    }
}

fn file_hashes(dir: &Path) -> std::collections::BTreeMap<String, (u64, String)> {
    let mut m = std::collections::BTreeMap::new();
    for e in std::fs::read_dir(dir).unwrap().flatten() {
        if e.file_type().unwrap().is_file() {
            m.insert(e.file_name().to_string_lossy().into_owned(), cache_search::snapshot::hash_file(&e.path()).map(|(h, n)| (n, h)).unwrap());
        }
    }
    m
}

fn snap_dirs(indexes: &Path) -> Vec<PathBuf> {
    let d = indexes.join("library").join("mine").join("snap");
    let mut v: Vec<PathBuf> = std::fs::read_dir(d).unwrap().flatten().map(|e| e.path()).collect();
    v.sort();
    v
}

fn generation(dir: &Path) -> u64 {
    let m: Value = serde_json::from_str(&std::fs::read_to_string(dir.join("manifest.json")).unwrap()).unwrap();
    m["generation"].as_u64().unwrap_or(0)
}

fn sealed_library(tmp: &TempDir) -> (PathBuf, Service, PathBuf) {
    let lib = make_library(&tmp.0);
    let svc = service();
    add_book(&svc, &tmp.0, &lib, "Quasar Guide", "quasar", 5);
    let idx = lib.join("index");
    std::fs::create_dir_all(&idx).unwrap();
    let cfg = settings();
    let p = LibBuildParams { threads: Some(1), pace: None, library_path: &lib.join("shard"), settings: Some(&cfg), index_dir: &idx, heap_mb: 15, checkpoint_docs: 1000 };
    build_library_index(&p, &|_, _| {}, &|| false).unwrap();
    let indexes = tmp.0.join("indexes");
    let h = sealed::open(&lib, &indexes);
    let done = sealed::seal(&indexes);
    assert_eq!(done["state"], "done", "{done}");
    sealed::until_snapshot(h);
    assert!(sealed::found(h, "quasar") > 0);
    sealed::close(h);
    (lib, svc, indexes)
}

/// The device sealed the library's keyword index into a snapshot, which removes `index/`. The books added after it are in the shard
/// and found by meaning at once; their words are added by one `index_extend` job as the next generation of the same snapshot. Until
/// it has run the status says the words are pending, and the new book is not found by its words; afterwards it is, and the status
/// says nothing is pending. The first generation's files are not touched: the next one links them.
#[test]
fn books_added_after_the_keyword_index_was_sealed_are_found_by_their_words_once_the_snapshot_is_extended() {
    let tmp = TempDir::new("sealed-add");
    let (lib, svc, indexes) = sealed_library(&tmp);
    let g0 = snap_dirs(&indexes);
    assert_eq!(g0.len(), 1);
    assert_eq!(generation(&g0[0]), 0);
    let g0_files = file_hashes(&g0[0]);

    add_book(&svc, &tmp.0, &lib, "Nebula Guide", "nebula", 5);
    let h = sealed::open(&lib, &indexes);
    sealed::until_snapshot(h);
    assert_eq!(sealed::pending(h), json!(true), "its newest pieces are not in the keyword snapshot");
    assert_eq!(sealed::found(h, "nebula"), 0, "so their words are not searchable yet");
    sealed::close(h);

    let r = sealed::extend(&lib, &indexes);
    assert_eq!(r["state"], "done", "{r}");
    assert_eq!(r["result"]["extended"], true, "{r}");
    assert_eq!(r["result"]["generation"], 1);
    assert!(r["result"]["added"].as_u64().unwrap() >= 3);
    assert!(r["result"]["reused"].as_u64().unwrap() >= 1, "the old segment files are linked, not rewritten: {r}");
    let g = snap_dirs(&indexes);
    assert_eq!(g.len(), 2, "the first generation stays beside the next as the rollback");
    let newest = g.iter().find(|d| generation(d) == 1).unwrap();
    // the reuse proof: every file of generation 0 is exactly what it was
    assert_eq!(file_hashes(&g0[0]), g0_files, "the old generation's files are untouched");
    let g1 = file_hashes(newest);
    let shared = g0_files.iter().filter(|(n, v)| g1.get(*n) == Some(*v)).count();
    assert!(shared >= 1 && g1.len() > shared, "generation 1 reuses old files and adds new ones");

    let h = sealed::open(&lib, &indexes);
    sealed::until_generation(h, 1);
    assert!(sealed::found(h, "nebula") > 0, "the book's words are searchable after the extension");
    assert!(sealed::found(h, "quasar") > 0, "the first book still is");
    assert_eq!(sealed::pending(h), json!(false));
    sealed::close(h);

    // a second add, a second generation; nothing to do when there is nothing to add
    add_book(&svc, &tmp.0, &lib, "Pulsar Guide", "pulsar", 5);
    let r = sealed::extend(&lib, &indexes);
    assert_eq!(r["result"]["generation"], 2, "{r}");
    let again = sealed::extend(&lib, &indexes);
    assert_eq!(again["result"]["unchanged"], true, "nothing new: no new generation: {again}");
    let h = sealed::open(&lib, &indexes);
    sealed::until_generation(h, 2);
    for w in ["pulsar", "nebula", "quasar"] {
        assert!(sealed::found(h, w) > 0, "{w}");
    }
    assert_eq!(sealed::pending(h), json!(false));
    sealed::close(h);
    assert_eq!(snap_dirs(&indexes).len(), 2, "the highest generation and one rollback are kept");
    no_leftovers(&lib);
}

/// Where the old segments cannot be linked into the next generation, the extension is a whole build, published as the next generation:
/// slower, but the words are searchable.
#[test]
fn an_extension_that_cannot_link_falls_back_to_a_whole_build() {
    let tmp = TempDir::new("sealed-fallback");
    let (lib, svc, indexes) = sealed_library(&tmp);
    add_book(&svc, &tmp.0, &lib, "Nebula Guide", "nebula", 5);
    cache_search::idxsnap::force_no_link_under(&snap_dirs(&indexes)[0]);
    let r = sealed::extend(&lib, &indexes);
    assert_eq!(r["state"], "done", "{r}");
    assert_eq!(r["result"]["built"], true, "{r}");
    assert_eq!(r["result"]["generation"], 1);
    let h = sealed::open(&lib, &indexes);
    sealed::until_generation(h, 1);
    assert!(sealed::found(h, "nebula") > 0 && sealed::found(h, "quasar") > 0);
    assert_eq!(sealed::pending(h), json!(false));
    sealed::close(h);
}

/// A segment added to a folder of linked files: Tantivy writes new files only. A replaced point (the same id again) and a changed
/// text are found as the new text; the old files are byte for byte what they were, including after a delete (a new `.del` file).
#[test]
fn a_linked_extension_writes_only_new_files_and_a_replaced_point_is_deleted_by_a_new_del_file() {
    let tmp = TempDir::new("extend-linked");
    let lib = make_library(&tmp.0);
    let svc = service();
    add_book(&svc, &tmp.0, &lib, "Quasar Guide", "quasar", 5);
    let base = tmp.0.join("base");
    std::fs::create_dir_all(&base).unwrap();
    let cfg = settings();
    let p = LibBuildParams { threads: Some(1), pace: None, library_path: &lib.join("shard"), settings: Some(&cfg), index_dir: &base, heap_mb: 15, checkpoint_docs: 1000 };
    build_library_index(&p, &|_, _| {}, &|| false).unwrap();
    let open = LibOpenIndex::open(&base, TOKENIZER).unwrap();
    let first_id = {
        let (hits, _) = keyword_hits(&open, "quasar", 5).unwrap();
        hits[0].point_id.clone()
    };
    drop(open);
    let before = file_hashes(&base);

    // the next generation's folder: the same files by hard link, then one segment on top
    let next = tmp.0.join("next");
    std::fs::create_dir_all(&next).unwrap();
    for n in before.keys().filter(|n| !["cache_search_index.json", ".tantivy-writer.lock", ".tantivy-meta.lock"].contains(&n.as_str())) {
        std::fs::hard_link(base.join(n), next.join(n)).unwrap();
    }
    let docs = vec![
        cache_search::libindex::IndexDoc { point_id: "new-1".into(), title: "T".into(), body: "zeppelin hangar".into(), source_type: String::new() },
        cache_search::libindex::IndexDoc { point_id: first_id.clone(), title: "T".into(), body: "replacement words only".into(), source_type: String::new() },
    ];
    let segments_before = cache_search::libindex::append_segment(&next, TOKENIZER, &docs, &[], 1, 15).unwrap();
    assert_eq!(segments_before, 1);

    assert_eq!(file_hashes(&base), before, "the old folder's files are exactly what they were: Tantivy wrote new files beside, linked ones untouched");
    let after = file_hashes(&next);
    let new_files: Vec<&String> = after.keys().filter(|n| !before.contains_key(*n)).collect();
    assert!(!new_files.is_empty(), "a new segment's files");
    assert!(new_files.iter().any(|n| n.ends_with(".del")), "the delete of the replaced point is a new .del file: {new_files:?}");
    // no merge ran: every old segment file is still there under the same name and bytes
    for (n, v) in before.iter().filter(|(n, _)| n.ends_with(".idx") || n.ends_with(".term") || n.ends_with(".store") || n.ends_with(".pos")) {
        assert_eq!(after.get(n), Some(v), "{n}");
    }
    let open = LibOpenIndex::open(&next, TOKENIZER).unwrap();
    assert!(!keyword_hits(&open, "zeppelin", 5).unwrap().0.is_empty(), "the new document is found");
    assert!(!keyword_hits(&open, "replacement", 5).unwrap().0.is_empty(), "the replaced point has its new text");
    let quasar = keyword_hits(&open, "quasar", 20).unwrap().0;
    assert!(quasar.iter().all(|h| h.point_id != first_id), "and no longer its old text");
    drop(open);
    let old = LibOpenIndex::open(&base, TOKENIZER).unwrap();
    assert!(keyword_hits(&old, "zeppelin", 5).unwrap().0.is_empty(), "the old folder does not have the new document");
    assert!(keyword_hits(&old, "quasar", 20).unwrap().0.iter().any(|h| h.point_id == first_id), "and still has the old text");
}

/// Deletes every point of the book `title` from the library's shard (what removing a book does), and returns how many.
fn delete_book(lib: &Path, title: &str) -> usize {
    ensure_init();
    let shard_dir = lib.join("shard");
    let shard = EdgeShard::load(&shard_dir, None).unwrap();
    let mut sr = ScrollRequest::new();
    sr.limit = Some(100_000);
    sr.with_payload = Some(WithPayloadInterface::Bool(true));
    let (recs, _) = EdgeShardRead::scroll(&shard, sr).unwrap();
    let ids: Vec<PointId> = recs
        .iter()
        .filter(|r| r.payload.as_ref().and_then(|p| p.0.get("title")).and_then(|t| t.as_str()) == Some(title))
        .map(|r| r.id)
        .collect();
    let n = ids.len();
    assert!(n > 0, "no points of {title}");
    shard.update(UpdateOperation::PointOperation(PointOperations::DeletePoints { ids })).unwrap();
    shard.flush().unwrap();
    drop(shard);
    write_segments_manifest(&shard_dir).unwrap();
    n
}

/// What a search does with a keyword hit on a point the shard no longer has: the point is looked up in the shard and dropped (the hit
/// vanishes, nothing errors), but its document stays in every linked segment unless the extension deletes it by id, and a hit that is
/// dropped still takes one of the keyword candidates. Two books are added, the snapshot is extended, one book is deleted, the snapshot is
/// extended again: a search for words only in the deleted book finds nothing, and the generation says what it removed.
#[test]
fn a_book_removed_from_the_library_is_removed_from_the_next_generation_of_the_snapshot() {
    let tmp = TempDir::new("sealed-delete");
    let (lib, svc, indexes) = sealed_library(&tmp);
    add_book(&svc, &tmp.0, &lib, "Nebula Guide", "nebula", 5);
    add_book(&svc, &tmp.0, &lib, "Pulsar Guide", "pulsar", 5);
    let r = sealed::extend(&lib, &indexes);
    assert_eq!(r["result"]["generation"], 1, "{r}");
    let h = sealed::open(&lib, &indexes);
    sealed::until_generation(h, 1);
    for w in ["quasar", "nebula", "pulsar"] {
        assert!(sealed::found(h, w) > 0, "{w}");
    }
    sealed::close(h);

    let gone = delete_book(&lib, "Nebula Guide");
    // nothing new to add, but the snapshot has what the shard has not: the extension is a new generation that deletes by id
    let r = sealed::extend(&lib, &indexes);
    assert_eq!(r["state"], "done", "{r}");
    assert_eq!(r["result"]["extended"], true, "{r}");
    assert_eq!(r["result"]["generation"], 2, "{r}");
    assert_eq!(r["result"]["added"], 0, "{r}");
    assert_eq!(r["result"]["removed"], gone, "{r}");
    let h = sealed::open(&lib, &indexes);
    sealed::until_generation(h, 2);
    assert_eq!(sealed::found(h, "nebula"), 0, "words only in the deleted book find nothing");
    assert!(sealed::found(h, "quasar") > 0 && sealed::found(h, "pulsar") > 0, "the other books still are found");
    sealed::close(h);
    // and nothing is left to do
    let again = sealed::extend(&lib, &indexes);
    assert_eq!(again["result"]["unchanged"], true, "{again}");
    // the keyword index itself no longer has the deleted book (a search drops a hit the shard cannot answer, so the search alone would
    // pass without the delete: look in the index)
    let g2 = snap_dirs(&indexes).into_iter().find(|d| generation(d) == 2).unwrap();
    let now = LibOpenIndex::open(&g2, TOKENIZER).unwrap();
    assert!(keyword_hits(&now, "nebula", 20).unwrap().0.is_empty(), "the deleted book's documents are deleted from the index");
    assert!(!keyword_hits(&now, "pulsar", 20).unwrap().0.is_empty());
    drop(now);
    // the generation before it is untouched (the rollback still has the deleted book)
    let g1 = snap_dirs(&indexes).into_iter().find(|d| generation(d) == 1).unwrap();
    let old = LibOpenIndex::open(&g1, TOKENIZER).unwrap();
    assert!(!keyword_hits(&old, "nebula", 5).unwrap().0.is_empty());
}

/// A library whose settings leave some points out of the keyword index (so the index always holds fewer documents than the shard has
/// points), on a file system that refuses hard links (so an extension always falls back to a whole build). Each app start looks at the
/// status and runs an extension when the words are pending. The whole build records how many points it covered, so the second start
/// finds nothing pending: one build, not one at every start.
#[test]
fn a_whole_build_records_its_point_count_so_left_out_points_do_not_bring_a_build_at_every_start() {
    let tmp = TempDir::new("whole-build-points");
    let lib = make_library(&tmp.0);
    let mut cfg = settings();
    cfg["leave_out"] = json!([{"field": "title", "equals": "Nebula Guide"}]);
    std::fs::write(lib.join("cache-library.json"), cfg.to_string()).unwrap();
    let svc = service();
    add_book(&svc, &tmp.0, &lib, "Quasar Guide", "quasar", 5);
    add_book(&svc, &tmp.0, &lib, "Nebula Guide", "nebula", 5);
    let idx = lib.join("index");
    std::fs::create_dir_all(&idx).unwrap();
    let p = LibBuildParams { threads: Some(1), pace: None, library_path: &lib.join("shard"), settings: Some(&cfg), index_dir: &idx, heap_mb: 15, checkpoint_docs: 1000 };
    build_library_index(&p, &|_, _| {}, &|| false).unwrap();
    let indexes = tmp.0.join("indexes");
    let h = sealed::open(&lib, &indexes);
    assert_eq!(sealed::seal(&indexes)["state"], "done");
    sealed::until_snapshot(h);
    sealed::close(h);

    // one app start: the status, and the extension the app runs when the words are pending (links refused, so it builds whole)
    let builds = std::cell::Cell::new(0);
    let start = || {
        let h = sealed::open(&lib, &indexes);
        sealed::until_snapshot(h);
        let pending = sealed::pending(h);
        sealed::close(h);
        if pending == json!(true) {
            for d in snap_dirs(&indexes) {
                cache_search::idxsnap::force_no_link_under(&d);
            }
            let r = sealed::extend_with(&lib, &indexes, json!({"settings": cfg}));
            assert_eq!(r["state"], "done", "{r}");
            if r["result"]["built"] == json!(true) {
                builds.set(builds.get() + 1);
            }
        }
    };
    start();
    assert_eq!(builds.get(), 1, "the sealed snapshot records no point count and holds fewer documents than points: one build");
    start();
    assert_eq!(builds.get(), 1, "the build recorded the points it covered: the second start has nothing to do");
    let h = sealed::open(&lib, &indexes);
    sealed::until_snapshot(h);
    assert_eq!(sealed::pending(h), json!(false));
    assert!(sealed::found(h, "quasar") > 0);
    assert_eq!(sealed::found(h, "nebula"), 0, "the left-out book is not in the keyword index");
    sealed::close(h);
}

/// An extension holds the missing pieces, with their text, in memory. Past `max_extend_pieces` the library is built whole instead
/// (which streams the shard), published as the next generation, and every word is searchable.
#[test]
fn a_snapshot_too_far_behind_is_built_whole_not_extended() {
    let tmp = TempDir::new("sealed-too-far");
    let (lib, svc, indexes) = sealed_library(&tmp);
    add_book(&svc, &tmp.0, &lib, "Nebula Guide", "nebula", 5);
    add_book(&svc, &tmp.0, &lib, "Pulsar Guide", "pulsar", 5);
    // the bound is below the six or more pieces that are missing
    let r = sealed::extend_with(&lib, &indexes, json!({"max_extend_pieces": 2}));
    assert_eq!(r["state"], "done", "{r}");
    assert_eq!(r["result"]["built"], true, "past the bound it is a whole build: {r}");
    assert!(r["result"]["because"].as_str().unwrap().contains("behind"), "{r}");
    assert_eq!(r["result"]["generation"], 1);
    let h = sealed::open(&lib, &indexes);
    sealed::until_generation(h, 1);
    for w in ["quasar", "nebula", "pulsar"] {
        assert!(sealed::found(h, w) > 0, "{w}");
    }
    sealed::close(h);
    // at or under the bound (the default is 2,000) it is an extension
    add_book(&svc, &tmp.0, &lib, "Comet Guide", "comet", 5);
    let r = sealed::extend(&lib, &indexes);
    assert_eq!(r["result"]["extended"], true, "{r}");
}

/// Edits the manifest of the (only) first-generation snapshot in place (the manifest is not one of the hashed files).
fn edit_manifest(indexes: &Path, edit: impl Fn(&mut Value)) {
    let dir = &snap_dirs(indexes)[0];
    let mut m: Value = serde_json::from_str(&std::fs::read_to_string(dir.join("manifest.json")).unwrap()).unwrap();
    edit(&mut m);
    std::fs::write(dir.join("manifest.json"), m.to_string()).unwrap();
}

/// A base manifest the core still reads but would not write now (here a different token length cap) is not extended: the library is
/// built whole, as the next generation, so old and new segments are never tokenized differently.
#[test]
fn a_base_snapshot_not_exactly_what_this_core_writes_is_not_extended_but_built_whole() {
    let tmp = TempDir::new("sealed-guard");
    let (lib, svc, indexes) = sealed_library(&tmp);
    edit_manifest(&indexes, |m| m["tokenizer"]["remove_long"] = json!(20));
    add_book(&svc, &tmp.0, &lib, "Nebula Guide", "nebula", 5);
    let r = sealed::extend(&lib, &indexes);
    assert_eq!(r["state"], "done", "{r}");
    assert_eq!(r["result"]["built"], true, "a whole build, not an extension: {r}");
    assert!(r["result"].get("extended").is_none());
    assert_eq!(r["result"]["generation"], 1);
    let h = sealed::open(&lib, &indexes);
    sealed::until_generation(h, 1);
    assert!(sealed::found(h, "nebula") > 0 && sealed::found(h, "quasar") > 0);
    sealed::close(h);
}

/// A base manifest with another analyzer name is not usable at all: there is nothing to extend, and the library is built whole.
#[test]
fn a_base_snapshot_with_another_analyzer_is_built_whole() {
    let tmp = TempDir::new("sealed-analyzer");
    let (lib, svc, indexes) = sealed_library(&tmp);
    edit_manifest(&indexes, |m| m["tokenizer"]["analyzer"] = json!("some_other_analyzer"));
    add_book(&svc, &tmp.0, &lib, "Nebula Guide", "nebula", 5);
    let r = sealed::extend(&lib, &indexes);
    assert_eq!(r["state"], "done", "{r}");
    assert!(r["result"].get("extended").is_none(), "{r}");
    let h = sealed::open(&lib, &indexes);
    let t0 = std::time::Instant::now();
    while sealed::found(h, "nebula") == 0 {
        assert!(t0.elapsed().as_secs() < 60, "the whole build's words were not found");
        std::thread::sleep(std::time::Duration::from_millis(50));
    }
    assert!(sealed::found(h, "quasar") > 0);
    sealed::close(h);
}
