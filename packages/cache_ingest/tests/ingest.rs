//! The Add PDF job on fakes: a generated PDF, a fake PDF engine, a fake embedder, a fake OCR (the test plays the host) and a fake
//! library store. The job's own files, the pack, copies.jsonl and the Bookshelves log are real; the real shard is tested through
//! the core (packages/cache_search/native/cache_search/tests/ingest_ffi.rs).

use cache_ingest::testing::{book, make_pdf, prose, FakeEmbedder, FakePage, FakePdfEngine, Kind};
use cache_ingest::{Classifier, Code, Env, Error, LibraryStore, Placement, Point, Service, Staged};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Mutex};

const NOW: u64 = 1_700_000_000_000;

// ---------------------------------------------------------------------------------------------------------
// The fake library store

#[derive(Default)]
struct StoreInner {
    writing: Mutex<HashSet<PathBuf>>,
    /// `(library, point ids)` of each committed write.
    committed: Mutex<Vec<(PathBuf, Vec<String>)>>,
    /// Called once, inside `begin`, while the library is held (the test waits there).
    hook: Mutex<Option<Box<dyn Fn() + Send + Sync>>>,
    fail_commit: AtomicBool,
}

#[derive(Clone, Default)]
struct FakeStore(Arc<StoreInner>);

struct FakeStaged {
    store: Arc<StoreInner>,
    lib: PathBuf,
    ids: Vec<String>,
}

impl Staged for FakeStaged {
    fn commit(&mut self) -> Result<(), Error> {
        if self.store.fail_commit.load(Ordering::SeqCst) {
            return Err(Error::new(Code::Io, "the swap failed"));
        }
        self.store.committed.lock().unwrap().push((self.lib.clone(), self.ids.clone()));
        Ok(())
    }
    fn undo(&mut self) {
        self.store.committed.lock().unwrap().pop();
    }
}

impl Drop for FakeStaged {
    fn drop(&mut self) {
        self.store.writing.lock().unwrap().remove(&self.lib);
    }
}

impl LibraryStore for FakeStore {
    fn begin(&self, library_dir: &Path, points: &[Point]) -> Result<Box<dyn Staged>, Error> {
        if !self.0.writing.lock().unwrap().insert(library_dir.to_path_buf()) {
            return Err(Error::busy("the library is being written by another job"));
        }
        let hook = self.0.hook.lock().unwrap().take();
        if let Some(h) = hook {
            h();
        }
        Ok(Box::new(FakeStaged { store: self.0.clone(), lib: library_dir.to_path_buf(), ids: points.iter().map(|p| p.id.clone()).collect() }))
    }
}

struct Confident(Placement);

impl Classifier for Confident {
    fn classify(&self, _mean_vector: &[f32]) -> Option<Placement> {
        Some(self.0.clone())
    }
}

fn medicine() -> Arc<dyn Classifier> {
    Arc::new(Confident(Placement { div: "610".into(), label: "Medicine".into(), score: 0.9, classifier_version: 3, second_div: None }))
}

// ---------------------------------------------------------------------------------------------------------
// The rig

struct Rig {
    root: tempfile::TempDir,
    pdf: Arc<FakePdfEngine>,
    emb: Arc<FakeEmbedder>,
    store: FakeStore,
    classifier: Option<Arc<dyn Classifier>>,
}

impl Rig {
    fn new() -> Rig {
        Rig { root: tempfile::tempdir().unwrap(), pdf: Arc::new(FakePdfEngine::default()), emb: Arc::new(FakeEmbedder::default()), store: FakeStore::default(), classifier: None }
    }

    /// A service on the rig's fakes. A new service is a new process: nothing of an earlier one is remembered but the files.
    fn service(&self) -> Service {
        let (pdf, emb, store, classifier) = (self.pdf.clone(), self.emb.clone(), self.store.clone(), self.classifier.clone());
        Service::new(Box::new(move |_engines: &Value| {
            Ok(Env { pdf: pdf.clone(), embedder: emb.clone(), store: Arc::new(store.clone()), classifier: classifier.clone(), clock: Arc::new(|| NOW) })
        }))
    }

    fn lib(&self, name: &str) -> PathBuf {
        let d = self.root.path().join("libraries").join(name);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    fn pdf_file(&self, name: &str, title: Option<&str>, kind: Kind, pages: &[FakePage]) -> PathBuf {
        let p = self.root.path().join("Inbox").join(name);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(&p, make_pdf(title, kind, pages)).unwrap();
        p
    }

    fn job_dir(&self, name: &str) -> PathBuf {
        self.root.path().join("ingest").join(name)
    }

    fn bookshelves(&self) -> Value {
        json!({"dir": self.root.path().join("bookshelves"), "dev": "phone-1"})
    }
}

fn ok(r: Result<String, Error>) -> Value {
    serde_json::from_str(&r.unwrap_or_else(|e| panic!("the call failed: {e}"))).unwrap()
}

fn err(r: Result<String, Error>) -> Error {
    r.expect_err("the call should fail")
}

fn start_params(lib: &Path, pdf: &Path, job_dir: &Path, opts: Value) -> String {
    json!({"library_dir": lib, "pdf_path": pdf, "job_dir": job_dir, "opts": opts}).to_string()
}

fn step(svc: &Service, job: u64, budget: u64) -> Value {
    ok(svc.step(&json!({"job": job, "budget_ms": budget}).to_string()))
}

/// Steps until the state is one of `stop` (or done/failed). Returns the last status and the states seen, in order.
fn run(svc: &Service, job: u64, stop: &[&str]) -> (Value, Vec<String>) {
    let mut seen: Vec<String> = Vec::new();
    for _ in 0..10_000 {
        let s = step(svc, job, 0);
        let st = s["state"].as_str().unwrap().to_string();
        if seen.last() != Some(&st) {
            seen.push(st.clone());
        }
        if st == "done" || st == "failed" || stop.contains(&st.as_str()) {
            return (s, seen);
        }
    }
    panic!("the job did not finish");
}

fn read_pack(lib: &Path, copy: &str) -> cache_pack::pack::Pack {
    cache_pack::pack::read_pack(&lib.join("packs").join(format!("{copy}@1.cdoc"))).unwrap()
}

fn files_of(lib: &Path, copy: &str) -> (Vec<u8>, String) {
    (std::fs::read(lib.join("packs").join(format!("{copy}@1.cdoc"))).unwrap(), std::fs::read_to_string(lib.join("copies.jsonl")).unwrap())
}

// ---------------------------------------------------------------------------------------------------------
// A full run

#[test]
fn a_book_is_read_embedded_and_written() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    std::fs::write(lib.join("SHA256SUMS"), "").unwrap();
    let pdf = rig.pdf_file("Wilderness Medicine.pdf", Some("Wilderness Medicine"), Kind::Ok, &book("water", 8));
    let svc = rig.service();
    let jd = rig.job_dir("a");
    let s = ok(svc.start(&start_params(&lib, &pdf, &jd, json!({}))));
    let job = s["job"].as_u64().unwrap();
    assert_eq!(s["resumed"], false);
    assert_eq!(s["pages"], 8);
    let copy = s["copy"].as_str().unwrap().to_string();
    assert_eq!(copy, blake3::hash(&std::fs::read(&pdf).unwrap()).to_hex().to_string());

    // nothing is in the library before the write
    let (done, seen) = run(&svc, job, &[]);
    assert_eq!(seen, vec!["reading", "embedding", "writing", "done"]);
    let r = &done["result"];
    assert_eq!(r["doc_id"], copy);
    assert_eq!(r["copy"], copy);
    assert_eq!(r["title"], "Wilderness Medicine");
    assert_eq!(r["ocr"], Value::Null);
    assert_eq!(r["pages_without_text"], 0);
    assert!(r.get("same").is_none() && r.get("shelf").is_none(), "no Bookshelves without bookshelves");
    let pieces = r["pieces"].as_u64().unwrap();
    assert!(pieces >= 3);
    assert_eq!(done["progress"]["pieces_done"], pieces);

    // the job's folder is gone and the job with it
    assert!(!jd.exists());
    assert_eq!(err(svc.step(&json!({"job": job}).to_string())).code, Code::NotFound);

    // the pack
    let pack = read_pack(&lib, &copy);
    assert_eq!(pack.header.extractor.name, "pdfium");
    assert_eq!(pack.header.extractor.layout_version, None);
    assert_eq!(pack.header.embedding.embedder, "fake-hash-v1");
    assert_eq!(pack.header.page_count, 8);
    assert_eq!(pack.pieces.len() as u64, pieces);
    assert!(pack.header.ocr_pages.is_empty() && pack.header.text_source_ocr_pages.is_empty());
    let book_block = pack.header.book.as_ref().unwrap();
    assert_eq!(book_block.original_blake3, copy);
    assert!(book_block.ocr.is_none());
    // the line of copies.jsonl, the points and the sums
    let copies = std::fs::read_to_string(lib.join("copies.jsonl")).unwrap();
    assert_eq!(copies.lines().count(), 1);
    assert!(copies.contains(&copy) && copies.contains("Wilderness Medicine"));
    let committed = rig.store.0.committed.lock().unwrap();
    assert_eq!(committed.len(), 1);
    assert_eq!(committed[0].1.len() as u64, pieces);
    let docs = std::fs::read_to_string(lib.join("documents.tsv")).unwrap();
    assert_eq!(docs.lines().next(), Some("doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages"));
    assert_eq!(docs.lines().nth(1).unwrap(), format!("{copy}\t1\tWilderness Medicine\t{copy}\t{pieces}\t8"));
    assert!(!lib.join("source-identities.json").exists());
    let sums = std::fs::read_to_string(lib.join("SHA256SUMS")).unwrap();
    assert!(sums.contains(&format!("packs/{copy}@1.cdoc")) && sums.contains("copies.jsonl") && sums.contains("documents.tsv"));
    // no temporary files are left in the library
    assert!(std::fs::read_dir(lib.join("packs")).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().starts_with('.')));
    assert!(std::fs::read_dir(&lib).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().ends_with(".tmp")));
}

#[test]
fn the_title_is_the_option_else_the_pdf_title_else_the_file_name() {
    let rig = Rig::new();
    let svc = rig.service();
    let lib = rig.lib("t");
    for (name, title, opt, want) in [
        ("A.pdf", Some("Metadata Title"), None, "Metadata Title"),
        ("My_Notes.pdf", None, None, "My_Notes"),
        ("C.pdf", Some("Metadata Title"), Some("Mine"), "Mine"),
    ] {
        let pdf = rig.pdf_file(name, title, Kind::Ok, &book(name, 3));
        let opts = opt.map(|t| json!({"title": t})).unwrap_or(json!({}));
        let job = ok(svc.start(&start_params(&lib, &pdf, &rig.job_dir(name), opts)))["job"].as_u64().unwrap();
        let (d, _) = run(&svc, job, &[]);
        assert_eq!(d["result"]["title"], want);
    }
}

#[test]
fn a_step_does_one_unit_over_a_zero_budget_and_the_batch_and_threads_are_honoured() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let pdf = rig.pdf_file("b.pdf", None, Kind::Ok, &book("bridge", 10));
    let svc = rig.service();
    let job = ok(svc.start(&start_params(&lib, &pdf, &rig.job_dir("b"), json!({"embed_batch": 2, "embed_threads": 3}))))["job"].as_u64().unwrap();
    // reading: a page per step
    for i in 1..=10u64 {
        let s = step(&svc, job, 0);
        assert_eq!(s["progress"]["pages_done"], i, "one page per step");
        // the pieces are known once reading is finished, and not before
        assert_eq!(s["progress"]["pieces"].as_u64().unwrap() > 0, i == 10);
    }
    let mut last = 0;
    let mut steps = 0;
    loop {
        let s = step(&svc, job, 0);
        steps += 1;
        let done = s["progress"]["pieces_done"].as_u64().unwrap();
        if s["state"] == "done" {
            break;
        }
        assert!(done - last <= 2, "at most one batch per step");
        last = done;
        assert!(steps < 100);
    }
    let calls = rig.emb.calls.lock().unwrap();
    assert!(calls.len() >= 3);
    assert!(calls.iter().all(|(n, threads)| *n <= 2 && *threads == 3), "{calls:?}");
    assert!(calls[..calls.len() - 1].iter().all(|(n, _)| *n == 2));
}

#[test]
fn a_big_budget_does_everything_in_one_step() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let pdf = rig.pdf_file("c.pdf", None, Kind::Ok, &book("cave", 4));
    let svc = rig.service();
    let job = ok(svc.start(&start_params(&lib, &pdf, &rig.job_dir("c"), json!({}))))["job"].as_u64().unwrap();
    let s = step(&svc, job, 60_000);
    assert_eq!(s["state"], "done");
}

// ---------------------------------------------------------------------------------------------------------
// Kill and resume

fn kill_and_resume(steps_before_kill: usize, tear_the_pages_file: bool) {
    let rig = Rig::new();
    let pdf = rig.pdf_file("long.pdf", Some("Long"), Kind::Ok, &book("river", 12));
    let opts = json!({"embed_batch": 2});

    // the uninterrupted run
    let reference = rig.lib("reference");
    let svc = rig.service();
    let job = ok(svc.start(&start_params(&reference, &pdf, &rig.job_dir("ref"), opts.clone())))["job"].as_u64().unwrap();
    let (done, _) = run(&svc, job, &[]);
    let copy = done["result"]["copy"].as_str().unwrap().to_string();
    let total_calls = rig.emb.calls.lock().unwrap().len();
    rig.emb.calls.lock().unwrap().clear();

    // the run that is killed after some steps, then started again with the same job_dir
    let killed = rig.lib("killed");
    let jd = rig.job_dir("killed");
    let svc1 = rig.service();
    let job1 = ok(svc1.start(&start_params(&killed, &pdf, &jd, opts.clone())))["job"].as_u64().unwrap();
    for _ in 0..steps_before_kill {
        step(&svc1, job1, 0);
    }
    drop(svc1);
    let calls_before = rig.emb.calls.lock().unwrap().len();
    if tear_the_pages_file {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new().append(true).open(jd.join("pages.jsonl")).unwrap();
        f.write_all(b"{\"p\":99,\"label\":\"\",\"te").unwrap();
    }
    assert!(!killed.join("packs").exists(), "nothing is in the library before the write");
    let svc2 = rig.service();
    let s = ok(svc2.start(&start_params(&killed, &pdf, &jd, opts)));
    assert_eq!(s["resumed"], true);
    let job2 = s["job"].as_u64().unwrap();
    let (done2, _) = run(&svc2, job2, &[]);
    assert_eq!(done2["result"]["copy"], copy);

    // the same book: the same bytes
    assert_eq!(files_of(&reference, &copy), files_of(&killed, &copy));
    // and the embedder was not asked again for what it had done
    let calls_after = rig.emb.calls.lock().unwrap().len();
    assert!(calls_after >= calls_before);
    assert!(calls_after <= total_calls, "{calls_after} calls after the kill, {total_calls} in a whole run");
    assert_eq!(rig.store.0.committed.lock().unwrap().len(), 2);
}

#[test]
fn killed_while_reading_it_resumes_and_gives_the_same_book() {
    kill_and_resume(5, false);
}

#[test]
fn a_torn_checkpoint_line_is_dropped_on_resume() {
    kill_and_resume(5, true);
}

#[test]
fn killed_while_embedding_it_resumes_and_gives_the_same_book() {
    kill_and_resume(12 + 2, false);
}

#[test]
fn a_checkpoint_of_another_file_is_discarded() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let a = rig.pdf_file("a.pdf", None, Kind::Ok, &book("alpha", 5));
    let b = rig.pdf_file("b.pdf", None, Kind::Ok, &book("beta", 5));
    let jd = rig.job_dir("x");
    let svc = rig.service();
    let ja = ok(svc.start(&start_params(&lib, &a, &jd, json!({}))))["job"].as_u64().unwrap();
    for _ in 0..3 {
        step(&svc, ja, 0);
    }
    let svc2 = rig.service();
    let s = ok(svc2.start(&start_params(&lib, &b, &jd, json!({}))));
    assert_eq!(s["resumed"], false);
    assert_eq!(step(&svc2, s["job"].as_u64().unwrap(), 0)["progress"]["pages_done"], 1);
}

#[test]
fn two_jobs_cannot_share_a_job_dir() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let a = rig.pdf_file("a.pdf", None, Kind::Ok, &book("alpha", 3));
    let jd = rig.job_dir("x");
    let svc = rig.service();
    ok(svc.start(&start_params(&lib, &a, &jd, json!({}))));
    assert_eq!(err(svc.start(&start_params(&lib, &a, &jd, json!({})))).code, Code::Busy);
}

// ---------------------------------------------------------------------------------------------------------
// OCR

fn mixed_pages() -> Vec<FakePage> {
    vec![
        FakePage::text(&prose("harbor", 1, 150)),
        FakePage::scanned(),
        FakePage::text(&prose("harbor", 3, 150)),
        FakePage::scanned(),
    ]
}

fn ocr_call(svc: &Service, job: u64, engine: &str, version: &str, pages: Value) -> Result<String, Error> {
    svc.ocr(&json!({"job": job, "engine": engine, "version": version, "pages": pages}).to_string())
}

#[test]
fn a_scanned_page_goes_to_ocr_and_its_text_is_in_the_book() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let pdf = rig.pdf_file("mixed.pdf", Some("Harbor"), Kind::Ok, &mixed_pages());
    let svc = rig.service();
    let jd = rig.job_dir("m");
    let job = ok(svc.start(&start_params(&lib, &pdf, &jd, json!({}))))["job"].as_u64().unwrap();
    let (s, _) = run(&svc, job, &["needs_ocr"]);
    assert_eq!(s["state"], "needs_ocr");
    assert_eq!(s["progress"]["pages"], 4);
    assert_eq!(s["progress"]["pages_done"], 2, "the two text pages are done; the two scans wait");
    let list = s["needs_ocr"].as_array().unwrap();
    assert_eq!(list.iter().map(|p| p["page"].as_u64().unwrap()).collect::<Vec<_>>(), vec![2, 4]);
    for p in list {
        assert!(Path::new(p["image_path"].as_str().unwrap()).is_file());
        assert_eq!(p["dpi"], 300);
        assert_eq!((p["width"].as_u64().unwrap(), p["height"].as_u64().unwrap()), (10, 12));
    }
    // stepping again returns the same list
    assert_eq!(step(&svc, job, 0)["needs_ocr"], s["needs_ocr"]);

    // a page that was not asked for, and an empty engine, are refused and change nothing
    assert_eq!(err(ocr_call(&svc, job, "apple-vision", "4", json!([{"page": 3, "text": "x"}]))).code, Code::BadJson);
    assert_eq!(err(ocr_call(&svc, job, "", "4", json!([{"page": 2, "text": "x"}]))).code, Code::BadJson);
    // a batch with one good and one bad page is taken whole or not at all
    assert_eq!(err(ocr_call(&svc, job, "apple-vision", "4", json!([{"page": 2, "text": "x"}, {"page": 9, "text": "y"}]))).code, Code::BadJson);
    assert_eq!(step(&svc, job, 0)["needs_ocr"].as_array().unwrap().len(), 2);

    let page2 = "Harbor lights guide the ships in at night. The lamp keeps the channel clear for every captain who comes in.";
    let a = ok(ocr_call(&svc, job, "apple-vision", "4", json!([{"page": 2, "text": page2, "confidence": 0.9}])));
    assert_eq!((a["accepted"].as_u64(), a["remaining"].as_u64()), (Some(1), Some(1)));
    assert!(!Path::new(list[0]["image_path"].as_str().unwrap()).exists(), "the image goes when its text is taken");
    assert!(Path::new(list[1]["image_path"].as_str().unwrap()).exists());
    // one engine and version per job
    assert_eq!(err(ocr_call(&svc, job, "mlkit", "4", json!([{"page": 4, "text": "z"}]))).code, Code::BadJson);
    assert_eq!(err(ocr_call(&svc, job, "apple-vision", "5", json!([{"page": 4, "text": "z"}]))).code, Code::BadJson);
    assert_eq!(step(&svc, job, 0)["needs_ocr"].as_array().unwrap().iter().map(|p| p["page"].as_u64().unwrap()).collect::<Vec<_>>(), vec![4]);
    // a page taken once is not asked for again
    assert_eq!(err(ocr_call(&svc, job, "apple-vision", "4", json!([{"page": 2, "text": "again"}]))).code, Code::BadJson);
    // an empty text is a blank page
    let b = ok(ocr_call(&svc, job, "apple-vision", "4", json!([{"page": 4, "text": ""}])));
    assert_eq!(b["remaining"], 0);

    let (done, _) = run(&svc, job, &[]);
    let r = &done["result"];
    assert_eq!(r["ocr"], json!({"engine": "apple-vision", "version": "4", "pages_ocrd": 2}));
    assert_eq!(r["pages_without_text"], 1, "the blank page");
    let copy = r["copy"].as_str().unwrap();
    let pack = read_pack(&lib, copy);
    let ocr = pack.header.book.as_ref().unwrap().ocr.clone().unwrap();
    assert_eq!((ocr.engine.as_str(), ocr.version.as_str(), ocr.pages_ocrd), ("apple-vision", "4", 2));
    assert!((ocr.confidence.unwrap() - 0.9).abs() < 1e-6, "the mean of the confidences given");
    assert_eq!(pack.header.text_source_ocr_pages, vec![2, 4]);
    assert!(pack.header.ocr_pages.is_empty(), "no page is left waiting for OCR");
    // the OCR text is in the pieces, in page order, between the text of pages 1 and 3
    let all: String = pack.pieces.iter().map(|p| p.text.as_str()).collect::<Vec<_>>().join(" ");
    let (i1, i2, i3) = (all.find("harbor note 1-1").unwrap(), all.find("Harbor lights guide").unwrap(), all.find("harbor note 3-1").unwrap());
    assert!(i1 < i2 && i2 < i3);
    assert_eq!(pack.header.extractor.name, "pdfium");
    // the PDF is untouched, the job folder gone
    assert!(!jd.exists());
}

#[test]
fn killed_while_waiting_for_ocr_it_resumes_and_asks_again() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let pdf = rig.pdf_file("mixed.pdf", None, Kind::Ok, &mixed_pages());
    let jd = rig.job_dir("m");
    let svc = rig.service();
    let job = ok(svc.start(&start_params(&lib, &pdf, &jd, json!({}))))["job"].as_u64().unwrap();
    run(&svc, job, &["needs_ocr"]);
    ok(ocr_call(&svc, job, "mlkit", "1.2", json!([{"page": 2, "text": "Text read from the first scan, with a few words in it."}])));
    drop(svc);
    let svc2 = rig.service();
    let s = ok(svc2.start(&start_params(&lib, &pdf, &jd, json!({}))));
    assert_eq!(s["resumed"], true);
    let job2 = s["job"].as_u64().unwrap();
    // the engine of the first call is remembered
    let (st, _) = run(&svc2, job2, &["needs_ocr"]);
    assert_eq!(st["needs_ocr"].as_array().unwrap().iter().map(|p| p["page"].as_u64().unwrap()).collect::<Vec<_>>(), vec![4]);
    assert!(Path::new(st["needs_ocr"][0]["image_path"].as_str().unwrap()).is_file());
    assert_eq!(err(ocr_call(&svc2, job2, "apple-vision", "4", json!([{"page": 4, "text": "x"}]))).code, Code::BadJson);
    ok(ocr_call(&svc2, job2, "mlkit", "1.2", json!([{"page": 4, "text": "Text read from the second scan, also with several words."}])));
    let (done, _) = run(&svc2, job2, &[]);
    assert_eq!(done["result"]["ocr"]["pages_ocrd"], 2);
}

#[test]
fn with_ocr_off_pages_without_text_are_skipped_and_counted() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let pdf = rig.pdf_file("mixed.pdf", None, Kind::Ok, &mixed_pages());
    let svc = rig.service();
    let job = ok(svc.start(&start_params(&lib, &pdf, &rig.job_dir("o"), json!({"ocr": "off"}))))["job"].as_u64().unwrap();
    let (done, seen) = run(&svc, job, &[]);
    assert!(!seen.contains(&"needs_ocr".to_string()));
    assert_eq!(done["result"]["pages_without_text"], 2);
    assert_eq!(done["result"]["ocr"], Value::Null);
    let pack = read_pack(&lib, done["result"]["copy"].as_str().unwrap());
    assert_eq!(pack.header.ocr_pages, vec![2, 4]);
    assert!(pack.header.text_source_ocr_pages.is_empty());
    assert_eq!(rig.pdf.renders.load(Ordering::SeqCst), 0, "no page is drawn when OCR is off");
}

#[test]
fn a_book_with_no_text_at_all_fails_and_writes_nothing() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let pdf = rig.pdf_file("scans.pdf", None, Kind::Ok, &[FakePage::scanned(), FakePage::scanned()]);
    let svc = rig.service();
    let job = ok(svc.start(&start_params(&lib, &pdf, &rig.job_dir("s"), json!({"ocr": "off"}))))["job"].as_u64().unwrap();
    let (s, _) = run(&svc, job, &[]);
    assert_eq!(s["state"], "failed");
    assert_eq!(s["error"]["code"], "no_text");
    assert!(rig.job_dir("s").exists(), "the job folder is kept for the reason to be shown");
    assert!(!lib.join("packs").exists() && !lib.join("copies.jsonl").exists());
    // cancel removes it
    ok(svc.cancel(&json!({"job": job}).to_string()));
    assert!(!rig.job_dir("s").exists());
}

#[test]
fn a_page_that_cannot_be_drawn_fails_the_job() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let pdf = rig.pdf_file("mixed.pdf", None, Kind::Ok, &mixed_pages());
    *rig.pdf.fail_render_of.lock().unwrap() = Some(1);
    let svc = rig.service();
    let job = ok(svc.start(&start_params(&lib, &pdf, &rig.job_dir("f"), json!({}))))["job"].as_u64().unwrap();
    let (s, _) = run(&svc, job, &[]);
    assert_eq!(s["state"], "failed");
    assert_eq!(s["error"]["code"], "damaged");
    assert!(s["error"]["message"].as_str().unwrap().contains("page 2"));
}

// ---------------------------------------------------------------------------------------------------------
// Failures

#[test]
fn an_embedder_failure_ends_the_job_with_the_embed_code_and_a_new_start_carries_on() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let pdf = rig.pdf_file("b.pdf", None, Kind::Ok, &book("tide", 12));
    *rig.emb.fail_call.lock().unwrap() = Some(2);
    let svc = rig.service();
    let jd = rig.job_dir("e");
    let job = ok(svc.start(&start_params(&lib, &pdf, &jd, json!({"embed_batch": 2}))))["job"].as_u64().unwrap();
    let (s, _) = run(&svc, job, &[]);
    assert_eq!(s["state"], "failed");
    assert_eq!(s["error"]["code"], "embed");
    assert!(!lib.join("packs").exists());
    assert_eq!(s["progress"]["pieces_done"], 4, "two batches were done and kept");
    // the app starts again with the same job_dir after fixing the cause
    *rig.emb.fail_call.lock().unwrap() = None;
    drop(svc);
    let svc2 = rig.service();
    let s2 = ok(svc2.start(&start_params(&lib, &pdf, &jd, json!({"embed_batch": 2}))));
    assert_eq!(s2["resumed"], true);
    let (done, _) = run(&svc2, s2["job"].as_u64().unwrap(), &[]);
    assert_eq!(done["state"], "done");
}

#[test]
fn locked_damaged_and_not_pdf_files_are_refused_at_start() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let svc = rig.service();
    let locked = rig.pdf_file("locked.pdf", None, Kind::Locked, &book("x", 2));
    assert_eq!(err(svc.start(&start_params(&lib, &locked, &rig.job_dir("l"), json!({})))).code, Code::Locked);
    let damaged = rig.pdf_file("damaged.pdf", None, Kind::Damaged, &book("x", 2));
    assert_eq!(err(svc.start(&start_params(&lib, &damaged, &rig.job_dir("d"), json!({})))).code, Code::Damaged);
    let text = rig.root.path().join("notes.pdf");
    std::fs::write(&text, "just some words, not a PDF").unwrap();
    assert_eq!(err(svc.start(&start_params(&lib, &text, &rig.job_dir("n"), json!({})))).code, Code::NotPdf);
    let missing = rig.root.path().join("none.pdf");
    assert_eq!(err(svc.start(&start_params(&lib, &missing, &rig.job_dir("n"), json!({})))).code, Code::Io);
    let nopages = rig.pdf_file("empty.pdf", None, Kind::Ok, &[]);
    assert_eq!(err(svc.start(&start_params(&lib, &nopages, &rig.job_dir("p"), json!({})))).code, Code::Damaged);
    assert_eq!(err(svc.start("{}")).code, Code::BadJson);
    assert_eq!(err(svc.start("not json")).code, Code::BadJson);
    assert_eq!(err(svc.start(&start_params(&lib, &locked, &rig.job_dir("q"), json!({"ocr": "maybe"})))).code, Code::BadJson);
    assert_eq!(err(svc.start(&start_params(&lib, &locked, &rig.job_dir("q"), json!({"embed_batch": 0})))).code, Code::BadJson);
    // none of them left a job folder
    for n in ["l", "d", "n", "p"] {
        assert!(!rig.job_dir(n).join("state.json").exists());
    }
    assert!(!lib.join("packs").exists());
}

#[test]
fn a_failed_swap_leaves_the_library_as_it_was() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    std::fs::write(lib.join("copies.jsonl"), "").unwrap();
    let pdf = rig.pdf_file("b.pdf", None, Kind::Ok, &book("tide", 3));
    rig.store.0.fail_commit.store(true, Ordering::SeqCst);
    let svc = rig.service();
    let job = ok(svc.start(&start_params(&lib, &pdf, &rig.job_dir("w"), json!({}))))["job"].as_u64().unwrap();
    let (s, _) = run(&svc, job, &[]);
    assert_eq!(s["state"], "failed");
    assert_eq!(std::fs::read_to_string(lib.join("copies.jsonl")).unwrap(), "");
    assert!(!lib.join("packs").exists() || std::fs::read_dir(lib.join("packs")).unwrap().next().is_none());
    assert!(rig.store.0.committed.lock().unwrap().is_empty());
    assert!(rig.store.0.writing.lock().unwrap().is_empty(), "the library is released");
}

// ---------------------------------------------------------------------------------------------------------
// Cancel

#[test]
fn cancel_deletes_the_job_folder_and_leaves_the_library_alone() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let pdf = rig.pdf_file("c.pdf", None, Kind::Ok, &book("cave", 6));
    let svc = rig.service();
    let jd = rig.job_dir("c");
    let job = ok(svc.start(&start_params(&lib, &pdf, &jd, json!({}))))["job"].as_u64().unwrap();
    for _ in 0..4 {
        step(&svc, job, 0);
    }
    assert!(jd.join("pages.jsonl").exists());
    assert_eq!(ok(svc.cancel(&json!({"job": job}).to_string())), json!({"cancelled": true}));
    assert!(!jd.exists());
    assert!(!lib.join("packs").exists() && !lib.join("copies.jsonl").exists());
    assert_eq!(err(svc.step(&json!({"job": job}).to_string())).code, Code::NotFound);
    assert_eq!(err(svc.cancel(&json!({"job": job}).to_string())).code, Code::NotFound);
    assert_eq!(err(ocr_call(&svc, job, "e", "1", json!([]))).code, Code::NotFound);
    // a job_dir can be used again
    let s = ok(svc.start(&start_params(&lib, &pdf, &jd, json!({}))));
    assert_eq!(s["resumed"], false);
}

#[test]
fn cancel_after_done_is_not_found() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let pdf = rig.pdf_file("c.pdf", None, Kind::Ok, &book("cave", 3));
    let svc = rig.service();
    let job = ok(svc.start(&start_params(&lib, &pdf, &rig.job_dir("c"), json!({}))))["job"].as_u64().unwrap();
    run(&svc, job, &[]);
    assert_eq!(err(svc.cancel(&json!({"job": job}).to_string())).code, Code::NotFound);
}

// ---------------------------------------------------------------------------------------------------------
// Two jobs, one library

#[test]
fn the_second_job_gets_busy_while_the_first_writes() {
    let rig = Rig::new();
    let lib = rig.lib("shared");
    let a = rig.pdf_file("a.pdf", None, Kind::Ok, &book("alpha", 3));
    let b = rig.pdf_file("b.pdf", None, Kind::Ok, &book("beta", 3));
    let svc = Arc::new(rig.service());
    let ja = ok(svc.start(&start_params(&lib, &a, &rig.job_dir("a"), json!({}))))["job"].as_u64().unwrap();
    let jb = ok(svc.start(&start_params(&lib, &b, &rig.job_dir("b"), json!({}))))["job"].as_u64().unwrap();

    let (in_tx, in_rx) = mpsc::channel::<()>();
    let (go_tx, go_rx) = mpsc::channel::<()>();
    let go_rx = Mutex::new(go_rx);
    *rig.store.0.hook.lock().unwrap() = Some(Box::new(move || {
        in_tx.send(()).ok();
        let _ = go_rx.lock().unwrap().recv();
    }));
    let svc_a = svc.clone();
    let first = std::thread::spawn(move || step(&svc_a, ja, 60_000));
    in_rx.recv().unwrap();
    // job A is inside its write: job B reads and embeds, then gets busy at its own write, and is still alive
    let e = err(svc.step(&json!({"job": jb, "budget_ms": 60_000}).to_string()));
    assert_eq!(e.code, Code::Busy);
    go_tx.send(()).unwrap();
    assert_eq!(first.join().unwrap()["state"], "done");
    let s = step(&svc, jb, 60_000);
    assert_eq!(s["state"], "done");
    let copies = std::fs::read_to_string(lib.join("copies.jsonl")).unwrap();
    assert_eq!(copies.lines().count(), 2, "both books are in the library");
    assert_eq!(rig.store.0.committed.lock().unwrap().len(), 2);
}

// ---------------------------------------------------------------------------------------------------------
// Bookshelves

fn log_events(rig: &Rig) -> Vec<Value> {
    let p = rig.root.path().join("bookshelves").join("log").join("phone-1.jsonl");
    std::fs::read_to_string(p).map(|t| t.lines().map(|l| serde_json::from_str(l).unwrap()).collect()).unwrap_or_default()
}

fn with_shelves(lib: &Path, pdf: &Path, jd: &Path, rig: &Rig) -> String {
    json!({"library_dir": lib, "pdf_path": pdf, "job_dir": jd, "bookshelves": rig.bookshelves()}).to_string()
}

#[test]
fn a_new_book_is_placed_and_numbered_and_a_copy_of_it_is_detected() {
    let mut rig = Rig::new();
    rig.classifier = Some(medicine());
    let lib = rig.lib("mine");
    let svc = rig.service();
    // 1: a new book: place and assign 1
    let a = rig.pdf_file("a.pdf", Some("First"), Kind::Ok, &book("first", 6));
    let ja = ok(svc.start(&with_shelves(&lib, &a, &rig.job_dir("a"), &rig)))["job"].as_u64().unwrap();
    let (da, _) = run(&svc, ja, &[]);
    assert_eq!(da["result"]["same"], json!([]));
    assert_eq!(da["result"]["shelf"], json!({"div": "610", "by": "auto"}));
    let copy_a = da["result"]["copy"].as_str().unwrap().to_string();
    let ev = log_events(&rig);
    assert_eq!(ev.iter().map(|e| e["ev"].as_str().unwrap()).collect::<Vec<_>>(), vec!["place", "assign"]);
    assert_eq!(ev[0]["copy"], copy_a);
    assert_eq!((ev[0]["div"].as_str(), ev[0]["by"].as_str()), (Some("610"), Some("auto")));
    assert_eq!((ev[1]["div"].as_str(), ev[1]["seq"].as_u64()), (Some("610"), Some(1)));
    assert_eq!(ev[0]["dev"], "phone-1");
    // the classifier's suggestion is in the pack
    let pa = read_pack(&lib, &copy_a);
    let sug = pa.header.book.as_ref().unwrap().suggested.clone().unwrap();
    assert_eq!((sug.div.as_str(), sug.source.as_str(), sug.classifier_version), ("610", "classifier", Some(3)));

    // 2: the same text in another file (another BLAKE3): detected as the same book, by text, and not placed again
    let b = rig.pdf_file("a copy.pdf", Some("First (scan 2)"), Kind::Ok, &book("first", 6));
    let jb = ok(svc.start(&with_shelves(&lib, &b, &rig.job_dir("b"), &rig)))["job"].as_u64().unwrap();
    let (db, _) = run(&svc, jb, &[]);
    let copy_b = db["result"]["copy"].as_str().unwrap().to_string();
    assert_ne!(copy_a, copy_b);
    let same = db["result"]["same"].as_array().unwrap();
    assert_eq!(same.len(), 1);
    assert_eq!((same[0]["with"].as_str(), same[0]["how"].as_str()), (Some(copy_a.as_str()), Some("text")));
    assert!(same[0]["score"].as_f64().unwrap() > 0.99);
    assert_eq!(db["result"]["shelf"], Value::Null);
    let ev = log_events(&rig);
    assert_eq!(ev.len(), 3);
    assert_eq!(ev[2]["ev"], "same");
    assert_eq!((ev[2]["copy"].as_str(), ev[2]["with"].as_str(), ev[2]["by"].as_str(), ev[2]["how"].as_str()), (Some(copy_b.as_str()), Some(copy_a.as_str()), Some("auto"), Some("text")));

    // 3: another new book takes the next number on the shelf
    let c = rig.pdf_file("c.pdf", None, Kind::Ok, &book("quite different words about gardens", 6));
    let jc = ok(svc.start(&with_shelves(&lib, &c, &rig.job_dir("c"), &rig)))["job"].as_u64().unwrap();
    let (dc, _) = run(&svc, jc, &[]);
    assert_eq!(dc["result"]["shelf"], json!({"div": "610", "by": "auto"}));
    let ev = log_events(&rig);
    assert_eq!(ev.len(), 5);
    assert_eq!((ev[4]["ev"].as_str(), ev[4]["seq"].as_u64()), (Some("assign"), Some(2)));
}

#[test]
fn only_the_listed_libraries_and_the_target_are_compared() {
    let mut rig = Rig::new();
    rig.classifier = Some(medicine());
    let svc = rig.service();
    let one = rig.lib("one");
    let two = rig.lib("two");
    let a = rig.pdf_file("a.pdf", Some("A"), Kind::Ok, &book("harvest", 6));
    let ja = ok(svc.start(&with_shelves(&one, &a, &rig.job_dir("a"), &rig)))["job"].as_u64().unwrap();
    run(&svc, ja, &[]);
    // not listed: the sibling folder is not looked at
    let b = rig.pdf_file("b.pdf", Some("B"), Kind::Ok, &book("harvest", 6));
    let jb = ok(svc.start(&with_shelves(&two, &b, &rig.job_dir("b"), &rig)))["job"].as_u64().unwrap();
    let (db, _) = run(&svc, jb, &[]);
    assert_eq!(db["result"]["same"], json!([]));
    // listed: it is compared
    let c = rig.pdf_file("c.pdf", Some("C"), Kind::Ok, &book("harvest", 6));
    let params = json!({"library_dir": two, "pdf_path": c, "job_dir": rig.job_dir("c"),
        "bookshelves": {"dir": rig.root.path().join("bookshelves"), "dev": "phone-1", "libraries": [{"library_id": "one", "dir": one}]}}).to_string();
    let jc = ok(svc.start(&params))["job"].as_u64().unwrap();
    let (dc, _) = run(&svc, jc, &[]);
    assert!(!dc["result"]["same"].as_array().unwrap().is_empty());
}

#[test]
fn without_a_classifier_nothing_is_placed_and_the_book_is_in_unsorted() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let svc = rig.service();
    let a = rig.pdf_file("a.pdf", None, Kind::Ok, &book("first", 5));
    let ja = ok(svc.start(&with_shelves(&lib, &a, &rig.job_dir("a"), &rig)))["job"].as_u64().unwrap();
    let (d, _) = run(&svc, ja, &[]);
    assert_eq!(d["result"]["same"], json!([]));
    assert_eq!(d["result"]["shelf"], Value::Null);
    assert!(log_events(&rig).is_empty(), "no place, no unsort, no assign");
    let pack = read_pack(&lib, d["result"]["copy"].as_str().unwrap());
    assert!(pack.header.book.as_ref().unwrap().suggested.is_none());
}

// ---------------------------------------------------------------------------------------------------------
// One writer

#[test]
fn the_pack_is_the_builders_pack_but_for_the_extractor() {
    use cache_pack::build_types::BuildOptions;
    use cache_pack::embed::FakeEmbedder as BuilderFake;
    use cache_pack::pack::Tool;
    use cache_pack::pagewriter::{build_pack_from_pages, PageIn, PagesSource, TextSource};

    let rig = Rig::new();
    let lib = rig.lib("mine");
    let texts: Vec<String> = (1..=7).map(|i| prose("lantern", i, 130)).collect();
    let pages: Vec<FakePage> = texts.iter().map(|t| FakePage::text(t)).collect();
    let pdf = rig.pdf_file("Lantern Light.pdf", Some("Lantern Light"), Kind::Ok, &pages);
    let svc = rig.service();
    let job = ok(svc.start(&start_params(&lib, &pdf, &rig.job_dir("p"), json!({"embed_batch": 3}))))["job"].as_u64().unwrap();
    let (done, _) = run(&svc, job, &[]);
    let got = read_pack(&lib, done["result"]["copy"].as_str().unwrap());

    // the same pages through the shared writer, as the Linux builder calls it (MuPDF and its layout step named as extractor)
    let bytes = std::fs::read(&pdf).unwrap();
    let ins: Vec<PageIn> = texts
        .iter()
        .enumerate()
        .map(|(i, t)| PageIn { pdf_page: i + 1, label: String::new(), text_source: TextSource::Layer, blocks: cache_ingest::job::blocks_from_text(t) })
        .collect();
    let src = PagesSource {
        blake3: blake3::hash(&bytes).to_hex().to_string(),
        size: bytes.len() as u64,
        file_name: "Lantern Light.pdf".to_string(),
        extractor: Tool { name: "mupdf".into(), version: "0.8.0".into(), layout_version: Some(2) },
        meta_title: Some("Lantern Light".to_string()),
        ppi: None,
        year: None,
        page_count: 7,
        ocr_pages: Some(vec![]),
        text_pages: None,
    };
    let opts = BuildOptions::new("Lantern Light.pdf", "2023-11-14T22:13:20Z");
    let (mut want, _) = build_pack_from_pages(&src, &ins, &opts, &BuilderFake, &mut |_| {}).unwrap();
    assert_ne!(want.header.extractor, got.header.extractor);
    want.header.extractor = got.header.extractor.clone();
    assert_eq!(want, got);
    assert_eq!(cache_pack::pack::pack_bytes(&want).unwrap(), std::fs::read(lib.join("packs").join(format!("{}@1.cdoc", got.header.doc_id))).unwrap());
}

#[test]
fn a_text_page_and_a_scanned_page_make_one_book() {
    let rig = Rig::new();
    let lib = rig.lib("mine");
    let pages = vec![FakePage { text: Some(prose("anchor", 1, 140)), label: Some("i".into()) }, FakePage::scanned()];
    let pdf = rig.pdf_file("two.pdf", None, Kind::Ok, &pages);
    let svc = rig.service();
    let job = ok(svc.start(&start_params(&lib, &pdf, &rig.job_dir("t"), json!({}))))["job"].as_u64().unwrap();
    run(&svc, job, &["needs_ocr"]);
    ok(ocr_call(&svc, job, "mlkit", "1", json!([{"page": 2, "text": "The scanned page says that the anchor holds the ship fast in the bay. It was read by the engine.\nA second line follows."}])));
    let (done, _) = run(&svc, job, &[]);
    let pack = read_pack(&lib, done["result"]["copy"].as_str().unwrap());
    assert_eq!(pack.header.text_source_ocr_pages, vec![2]);
    assert_eq!(pack.header.page_count, 2);
    // the label of page 1 is kept, page 2 has none and is called by its number
    assert_eq!(pack.pieces[0].page, "i");
    let last = pack.pieces.last().unwrap();
    assert!(last.pdf_page_end == Some(2) || last.pdf_page == Some(2));
    assert!(pack.pieces.iter().any(|p| p.text.contains("scanned page says")));
    let ocr = pack.header.book.as_ref().unwrap().ocr.clone().unwrap();
    assert_eq!(ocr.pages_ocrd, 1);
    assert_eq!(ocr.confidence, None, "no confidence was given");
}
