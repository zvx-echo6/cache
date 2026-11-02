//! Tests of the build service: the queue, the library swap, the drop folder. The embedder is the builder crate's fake.

use super::dropdir::unique_name;
use super::testpdf::{book, make_pdf, picture_page, text_page, Page};
use super::*;
use crate::TempDir;
use cache_builder::library::check_library_dir;
use cache_builder::FakeEmbedder;
use std::sync::atomic::AtomicUsize;

/// An [`Embed`] for tests: ready or not, counting calls, with a hook that runs inside each call.
pub(crate) struct FakeEmbed {
    pub ready: AtomicBool,
    pub calls: AtomicUsize,
    pub waiting: AtomicBool,
    pub hook: Mutex<Option<Box<dyn Fn() + Send + Sync>>>,
}

impl FakeEmbed {
    pub fn new(ready: bool) -> Arc<FakeEmbed> {
        Arc::new(FakeEmbed { ready: AtomicBool::new(ready), calls: AtomicUsize::new(0), waiting: AtomicBool::new(false), hook: Mutex::new(None) })
    }
}

impl Embed for FakeEmbed {
    fn ready(&self) -> Result<(), String> {
        if self.ready.load(Ordering::Relaxed) {
            Ok(())
        } else {
            Err(WAITING_FOR_MODEL.to_string())
        }
    }
    fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedErr> {
        self.calls.fetch_add(1, Ordering::Relaxed);
        if let Some(h) = lock(&self.hook).as_ref() {
            h();
        }
        if self.waiting.load(Ordering::Relaxed) {
            return Err(EmbedErr::Waiting(WAITING_FOR_MODEL.into()));
        }
        Ok(FakeEmbedder.embed_batch(texts))
    }
    fn name(&self) -> String {
        "fake-hash-v1".to_string()
    }
}

pub(crate) fn rig_with(dir: &TempDir, cfg: BuildConfig) -> (Arc<BuildService>, Arc<FakeEmbed>) {
    let fake = FakeEmbed::new(true);
    let lib = Library::new(dir.0.clone(), None);
    (BuildService::new(dir.0.clone(), lib, fake.clone(), cfg), fake)
}

fn cfg() -> BuildConfig {
    BuildConfig { settle: Duration::from_millis(200), poll: Duration::from_secs(3600), publish_every: Duration::from_secs(3600), on_rescan: None }
}

fn rig(dir: &TempDir) -> (Arc<BuildService>, Arc<FakeEmbed>) {
    rig_with(dir, cfg())
}

fn new_lib(svc: &BuildService, title: &str) -> String {
    let v = svc.create_library(json!({"title": title}).to_string().as_bytes()).unwrap();
    v["id"].as_str().unwrap().to_string()
}

/// Put a PDF in the staging folder and queue it, as an upload does.
fn add(svc: &BuildService, lib: &str, name: &str, pdf: &[u8]) -> String {
    let id = random_hex();
    let path = svc.data.join("build/pending").join(format!("{id}.pdf"));
    std::fs::write(&path, pdf).unwrap();
    svc.enqueue(Item::new(id.clone(), lib.to_string(), path.to_string_lossy().into_owned(), name.to_string(), pdf.len() as u64, Origin::Upload)).unwrap();
    id
}

fn state(svc: &BuildService, id: &str) -> S {
    lock(&svc.st).items.iter().find(|i| i.id == id).map(|i| i.state).unwrap_or_else(|| panic!("no item {id}"))
}

fn item(svc: &BuildService, id: &str) -> Item {
    lock(&svc.st).items.iter().find(|i| i.id == id).cloned().unwrap()
}

fn live_docs(svc: &BuildService, lib: &str) -> usize {
    check_library_dir(&svc.live_dir(lib)).unwrap()["docs"].as_u64().unwrap() as usize
}

fn passages(svc: &BuildService, lib: &str) -> u64 {
    svc.libraries().as_array().unwrap().iter().find(|l| l["id"] == json!(lib)).unwrap()["passages"].as_u64().unwrap()
}

fn drain(svc: &Arc<BuildService>) {
    while matches!(svc.run_one(), Run::Ran) {}
}

#[test]
fn books_are_built_one_at_a_time_into_a_library_the_core_can_open() {
    let d = TempDir::new("b1");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "Water systems");
    let a = add(&svc, &lib, "wells.pdf", &book("well", 3, Some("Wells")));
    let b = add(&svc, &lib, "tanks.pdf", &book("tank", 3, None));
    assert_eq!(state(&svc, &a), S::Queued);
    assert!(matches!(svc.run_one(), Run::Ran));
    assert_eq!((state(&svc, &a), state(&svc, &b)), (S::Done, S::Queued));
    assert!(matches!(svc.run_one(), Run::Ran));
    assert_eq!(state(&svc, &b), S::Done);
    assert!(matches!(svc.run_one(), Run::Idle));
    let ia = item(&svc, &a);
    assert_eq!((ia.pages, ia.ocr_pages, ia.error.clone()), (Some(3), 0, None));
    assert!(ia.pieces_total.unwrap() >= 1 && ia.pieces_done == ia.pieces_total.unwrap());
    // the library: both books, a pack and the original PDF for each, and a shard the core's own check opens
    let books = svc.books(&lib).unwrap();
    assert_eq!(books.as_array().unwrap().len(), 2);
    let titles: Vec<&str> = books.as_array().unwrap().iter().map(|b| b["title"].as_str().unwrap()).collect();
    assert!(titles.contains(&"Wells") && titles.contains(&"tanks"), "{titles:?}");
    for b in books.as_array().unwrap() {
        let doc = b["id"].as_str().unwrap();
        assert!(svc.source_path(&lib, doc).is_file());
        assert!(svc.packs_dir(&lib).join(format!("{doc}@1.cdoc")).is_file());
        assert_eq!(std::fs::read(svc.source_path(&lib, doc)).unwrap().len() as u64, b["size"].as_u64().unwrap());
    }
    assert_eq!(live_docs(&svc, &lib) as u64, passages(&svc, &lib));
    let settings: Value = serde_json::from_slice(&std::fs::read(svc.live_dir(&lib).join("cache-library.json")).unwrap()).unwrap();
    assert_eq!((settings["library_id"].as_str(), settings["title"].as_str()), (Some(lib.as_str()), Some("Water systems")));
    // the upload's staging file is gone
    assert_eq!(std::fs::read_dir(d.0.join("build/pending")).unwrap().count(), 0);
    // the source copy carries the original bytes
    let doc = books.as_array().unwrap()[0]["id"].as_str().unwrap();
    assert!(std::fs::read(svc.source_path(&lib, doc)).unwrap().starts_with(b"%PDF-"));
}

#[test]
fn the_pack_names_the_pdf_it_came_from() {
    let d = TempDir::new("b2");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    let pdf = book("pump", 2, None);
    add(&svc, &lib, "pump manual.pdf", &pdf);
    drain(&svc);
    let doc = blake3::hash(&pdf).to_hex().to_string();
    let p = read_pack(&svc.packs_dir(&lib).join(format!("{doc}@1.cdoc"))).unwrap();
    assert_eq!((p.header.source.blake3.as_str(), p.header.source.size, p.header.source.file_name.as_str()), (doc.as_str(), pdf.len() as u64, "pump manual.pdf"));
}

#[test]
fn the_same_content_is_skipped_within_a_library_but_not_across_libraries() {
    let d = TempDir::new("b3");
    let (svc, _) = rig(&d);
    let (l1, l2) = (new_lib(&svc, "One"), new_lib(&svc, "Two"));
    let pdf = book("river", 2, Some("River"));
    let a = add(&svc, &l1, "a.pdf", &pdf);
    let b = add(&svc, &l1, "renamed copy.pdf", &pdf);
    let c = add(&svc, &l2, "a.pdf", &pdf);
    drain(&svc);
    assert_eq!((state(&svc, &a), state(&svc, &b), state(&svc, &c)), (S::Done, S::SkippedDuplicate, S::Done));
    assert_eq!(item(&svc, &b).duplicate_of.as_deref(), Some("River"));
    assert_eq!(svc.books(&l1).unwrap().as_array().unwrap().len(), 1);
    assert_eq!(svc.books(&l2).unwrap().as_array().unwrap().len(), 1);
    // a skipped upload leaves nothing behind
    assert_eq!(std::fs::read_dir(d.0.join("build/pending")).unwrap().count(), 0);
}

#[test]
fn pause_finishes_the_current_book_then_holds_and_resume_goes_on() {
    let d = TempDir::new("b4");
    let (svc, fake) = rig(&d);
    let lib = new_lib(&svc, "L");
    let ids: Vec<String> = (0..3).map(|i| add(&svc, &lib, &format!("b{i}.pdf"), &book(&format!("topic{i}"), 2, None))).collect();
    let s2 = svc.clone();
    *lock(&fake.hook) = Some(Box::new(move || {
        s2.pause();
    }));
    assert!(matches!(svc.run_one(), Run::Ran));
    *lock(&fake.hook) = None;
    assert_eq!(state(&svc, &ids[0]), S::Done, "the book in progress is finished");
    assert!(matches!(svc.run_one(), Run::Idle));
    assert_eq!((state(&svc, &ids[1]), state(&svc, &ids[2])), (S::Queued, S::Queued));
    let q = svc.queue();
    assert_eq!(q["paused"], json!(true));
    assert_eq!(q["eta"]["low_seconds"], Value::Null);
    // paused is remembered across a restart
    let (svc2, _) = rig(&d);
    assert_eq!(svc2.queue()["paused"], json!(true));
    svc.resume();
    drain(&svc);
    assert!(ids.iter().all(|i| state(&svc, i) == S::Done));
}

#[test]
fn stop_drops_the_waiting_books_and_lets_the_current_one_finish() {
    let d = TempDir::new("b5");
    let (svc, fake) = rig(&d);
    let lib = new_lib(&svc, "L");
    let ids: Vec<String> = (0..4).map(|i| add(&svc, &lib, &format!("b{i}.pdf"), &book(&format!("kind{i}"), 2, None))).collect();
    let s2 = svc.clone();
    // the hook runs at every request to the embedder (the book's pieces, then the division texts): stop is asked at each, and the
    // waiting books go at the first
    let removed = Arc::new(AtomicUsize::new(0));
    let r2 = removed.clone();
    *lock(&fake.hook) = Some(Box::new(move || {
        let v = s2.stop();
        r2.fetch_add(v["removed"].as_u64().unwrap() as usize, Ordering::Relaxed);
    }));
    assert!(matches!(svc.run_one(), Run::Ran));
    assert_eq!(removed.load(Ordering::Relaxed), 3);
    assert_eq!(state(&svc, &ids[0]), S::Done);
    assert_eq!(lock(&svc.st).items.len(), 1);
    assert!(matches!(svc.run_one(), Run::Idle));
    // the stopped uploads' staging files are gone too
    assert_eq!(std::fs::read_dir(d.0.join("build/pending")).unwrap().count(), 0);
    assert_eq!(svc.books(&lib).unwrap().as_array().unwrap().len(), 1);
}

#[test]
fn a_book_interrupted_by_a_restart_starts_again_from_scratch() {
    let d = TempDir::new("b6");
    let id;
    let lib;
    {
        let (svc, _) = rig(&d);
        lib = new_lib(&svc, "L");
        id = add(&svc, &lib, "x.pdf", &book("flood", 2, None));
        add(&svc, &lib, "y.pdf", &book("dry", 2, None));
        // as if the server stopped half-way through the first
        {
            let mut st = lock(&svc.st);
            let it = &mut st.items[0];
            it.state = S::Building;
            it.pages = Some(2);
            it.pieces_done = 1;
            it.pieces_total = Some(3);
            svc.save_queue_locked(&st);
        }
    }
    let (svc, _) = rig(&d);
    let it = item(&svc, &id);
    assert_eq!((it.state, it.pages, it.pieces_done, it.pieces_total), (S::Queued, None, 0, None));
    assert_eq!(lock(&svc.st).items.len(), 2);
    assert_eq!(svc.libraries().as_array().unwrap().len(), 1);
    drain(&svc);
    assert_eq!(state(&svc, &id), S::Done);
    assert_eq!(svc.books(&lib).unwrap().as_array().unwrap().len(), 2);
}

#[test]
fn pages_that_need_ocr_make_a_partial_book_and_a_scan_only_pdf_is_ocr_needed_not_failed() {
    let d = TempDir::new("b7");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    let mixed = make_pdf(&[text_page("canal", 1, 150), picture_page(), text_page("canal", 3, 150), picture_page()], Some("Canals"));
    let scan = make_pdf(&[picture_page(), picture_page()], None);
    let a = add(&svc, &lib, "canals.pdf", &mixed);
    let b = add(&svc, &lib, "scan.pdf", &scan);
    drain(&svc);
    let ia = item(&svc, &a);
    assert_eq!(ia.state, S::Done);
    assert_eq!((ia.ocr_pages, ia.note.as_deref()), (2, Some("partial: 2 pages need OCR")));
    let books = svc.books(&lib).unwrap();
    let bk = &books[0];
    assert_eq!((bk["ocr_pages"].as_u64(), bk["partial"].as_str()), (Some(2), Some("partial: 2 pages need OCR")));
    let ib = item(&svc, &b);
    assert_eq!(ib.state, S::OcrNeeded);
    assert!(ib.error.unwrap().contains("OCR"));
    assert_eq!(svc.books(&lib).unwrap().as_array().unwrap().len(), 1);
    // the scan-only PDF is kept for the day OCR exists, and can be tried again
    assert!(std::path::Path::new(&item(&svc, &b).path).is_file());
    svc.retry(&b).unwrap();
    assert_eq!(state(&svc, &b), S::Queued);
}

#[test]
fn building_waits_for_the_search_model() {
    let d = TempDir::new("b8");
    let (svc, fake) = rig(&d);
    fake.ready.store(false, Ordering::Relaxed);
    let lib = new_lib(&svc, "L");
    let a = add(&svc, &lib, "a.pdf", &book("spring", 2, None));
    assert!(matches!(svc.run_one(), Run::Blocked));
    assert_eq!(state(&svc, &a), S::Queued);
    assert_eq!(svc.queue()["blocked"], json!("waiting for the search model"));
    assert_eq!(fake.calls.load(Ordering::Relaxed), 0);
    fake.ready.store(true, Ordering::Relaxed);
    assert!(matches!(svc.run_one(), Run::Ran));
    assert_eq!(state(&svc, &a), S::Done);
    assert_eq!(svc.queue()["blocked"], Value::Null);
    // the model going away in the middle of a book puts the book back
    let b = add(&svc, &lib, "b.pdf", &book("creek", 2, None));
    fake.waiting.store(true, Ordering::Relaxed);
    assert!(matches!(svc.run_one(), Run::Ran));
    let ib = item(&svc, &b);
    assert_eq!((ib.state, ib.error, ib.pieces_done), (S::Queued, None, 0));
    assert_eq!(svc.queue()["blocked"], json!("waiting for the search model"));
}

#[test]
fn a_bad_pdf_fails_alone_and_can_be_tried_again_at_the_end() {
    let d = TempDir::new("b9");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    let bad = add(&svc, &lib, "bad.pdf", b"%PDF-1.4\nthis is not a pdf at all");
    let good = add(&svc, &lib, "good.pdf", &book("rain", 2, None));
    drain(&svc);
    assert_eq!((state(&svc, &bad), state(&svc, &good)), (S::Failed, S::Done));
    assert!(item(&svc, &bad).error.is_some_and(|e| !e.is_empty()));
    assert_eq!(svc.retry(&good).unwrap_err().status, 409);
    svc.retry(&bad).unwrap();
    let order: Vec<String> = lock(&svc.st).items.iter().map(|i| i.id.clone()).collect();
    assert_eq!(order.last(), Some(&bad));
    assert_eq!(state(&svc, &bad), S::Queued);
    assert_eq!(svc.retry("nope").unwrap_err().status, 404);
    // dismissing takes it off the list and deletes the staged upload
    drain(&svc);
    let path = item(&svc, &bad).path;
    svc.dismiss(&bad).unwrap();
    assert!(!std::path::Path::new(&path).exists());
    assert_eq!(svc.dismiss(&bad).unwrap_err().status, 404);
}

#[test]
fn the_time_left_is_a_range_from_the_pieces_per_second_seen() {
    let d = TempDir::new("b10");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "a.pdf", &book("ridge", 4, None));
    drain(&svc);
    assert_eq!(svc.queue()["eta"]["low_seconds"], Value::Null, "nothing waiting");
    add(&svc, &lib, "b.pdf", &book("valley", 4, None));
    {
        let mut st = lock(&svc.st);
        st.built_secs = 10.0; // the fake embedder is too quick to measure
    }
    let q = svc.queue();
    let (lo, hi) = (q["eta"]["low_seconds"].as_u64().unwrap(), q["eta"]["high_seconds"].as_u64().unwrap());
    assert!(lo < hi, "{lo} {hi}");
    assert!(q["pieces_per_second"].as_f64().unwrap() > 0.0);
}

#[test]
fn a_new_edition_replaces_a_book_and_the_old_one_stays_searchable_until_it_is_swapped_in() {
    let d = TempDir::new("b11");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    let v1 = book("old", 3, Some("Field guide"));
    add(&svc, &lib, "guide.pdf", &v1);
    drain(&svc);
    let doc = svc.books(&lib).unwrap()[0]["id"].as_str().unwrap().to_string();
    let before = passages(&svc, &lib);
    // the replacement is queued: the book is "replacing" and the published library still holds the old points
    let v2 = book("fresh", 5, None);
    let id = random_hex();
    let path = svc.data.join("build/pending").join(format!("{id}.pdf"));
    std::fs::write(&path, &v2).unwrap();
    let mut it = Item::new(id.clone(), lib.clone(), path.to_string_lossy().into_owned(), "guide 2nd.pdf".into(), v2.len() as u64, Origin::Upload);
    it.replace = Some(doc.clone());
    svc.enqueue(it).unwrap();
    assert_eq!(svc.books(&lib).unwrap()[0]["status"], json!("replacing"));
    assert_eq!(live_docs(&svc, &lib) as u64, before);
    drain(&svc);
    assert_eq!(state(&svc, &id), S::Done);
    let books = svc.books(&lib).unwrap();
    let b = &books.as_array().unwrap()[0];
    assert_eq!((b["id"].as_str(), b["doc_version"].as_u64(), b["title"].as_str(), b["status"].as_str()), (Some(doc.as_str()), Some(2), Some("Field guide"), Some("ready")));
    assert_eq!(books.as_array().unwrap().len(), 1);
    assert!(!svc.packs_dir(&lib).join(format!("{doc}@1.cdoc")).exists());
    assert!(svc.packs_dir(&lib).join(format!("{doc}@2.cdoc")).is_file());
    assert_eq!(std::fs::read(svc.source_path(&lib, &doc)).unwrap(), v2);
    // after the swap only the new edition's points are in the library
    assert_eq!(live_docs(&svc, &lib) as u64, passages(&svc, &lib));
    assert_eq!(passages(&svc, &lib), b["passages"].as_u64().unwrap());
}

#[test]
fn removing_a_book_deletes_its_points_pack_and_pdf_copy_and_an_empty_library_leaves_the_core() {
    let d = TempDir::new("b12");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "a.pdf", &book("alpha", 3, None));
    add(&svc, &lib, "b.pdf", &book("beta", 3, None));
    drain(&svc);
    let books = svc.books(&lib).unwrap();
    let ids: Vec<String> = books.as_array().unwrap().iter().map(|b| b["id"].as_str().unwrap().to_string()).collect();
    let kept = books.as_array().unwrap().iter().find(|b| b["id"] == json!(ids[1])).unwrap()["passages"].as_u64().unwrap();
    assert_eq!(svc.delete_book(&lib, &ids[0]).unwrap()["removed"], json!(true));
    assert!(!svc.source_path(&lib, &ids[0]).exists());
    assert!(!svc.packs_dir(&lib).join(format!("{}@1.cdoc", ids[0])).exists());
    assert_eq!(svc.delete_book(&lib, &ids[0]).unwrap_err().status, 404);
    // not published yet: the core's copy still has both
    assert!(live_docs(&svc, &lib) as u64 > kept);
    drain(&svc); // idle: publishes
    assert_eq!(live_docs(&svc, &lib) as u64, kept);
    svc.delete_book(&lib, &ids[1]).unwrap();
    drain(&svc);
    assert!(!svc.live_dir(&lib).join("shard").exists(), "a library with no books is not offered to the core");
    assert!(svc.live_dir(&lib).join("packs").is_dir());
    // a book added again brings it back
    add(&svc, &lib, "c.pdf", &book("gamma", 2, None));
    drain(&svc);
    assert!(svc.live_dir(&lib).join("shard").is_dir());
}

#[test]
fn a_title_change_keeps_the_vectors_and_rewrites_the_payload() {
    let d = TempDir::new("b13");
    let (svc, fake) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "a.pdf", &book("alpha", 2, Some("Old title")));
    drain(&svc);
    let doc = svc.books(&lib).unwrap()[0]["id"].as_str().unwrap().to_string();
    let calls = fake.calls.load(Ordering::Relaxed);
    let before = read_pack(&svc.packs_dir(&lib).join(format!("{doc}@1.cdoc"))).unwrap();
    assert_eq!(svc.rename_book(&lib, &doc, br#"{"title":"  New title "}"#).unwrap()["title"], json!("New title"));
    assert_eq!(fake.calls.load(Ordering::Relaxed), calls, "nothing is embedded again");
    let after = read_pack(&svc.packs_dir(&lib).join(format!("{doc}@1.cdoc"))).unwrap();
    assert_eq!(after.header.title, "New title");
    assert_eq!(after.pieces, before.pieces);
    assert_eq!(svc.books(&lib).unwrap()[0]["title"], json!("New title"));
    assert_eq!(svc.rename_book(&lib, &doc, br#"{"title":" "}"#).unwrap_err().status, 400);
    assert_eq!(svc.rename_book(&lib, "nope", br#"{"title":"x"}"#).unwrap_err().status, 404);
    drain(&svc);
    assert_eq!(live_docs(&svc, &lib) as u64, passages(&svc, &lib), "same points, no extra ones");
}

#[test]
fn libraries_are_created_renamed_and_deleted() {
    let d = TempDir::new("b14");
    let (svc, _) = rig(&d);
    let a = new_lib(&svc, "Medical & first aid");
    assert!(a.starts_with("medical-first-aid-"), "{a}");
    assert_eq!(svc.create_library(br#"{"title":"medical & FIRST aid"}"#).unwrap_err().code, "name_taken");
    assert_eq!(svc.create_library(br#"{"title":"  "}"#).unwrap_err().status, 400);
    assert_eq!(svc.create_library(b"nope").unwrap_err().status, 400);
    let b = new_lib(&svc, "Water");
    assert_eq!(svc.rename_library(&b, br#"{"title":"Medical & first aid"}"#).unwrap_err().code, "name_taken");
    assert_eq!(svc.rename_library(&b, br#"{"title":"Water systems"}"#).unwrap()["title"], json!("Water systems"));
    assert_eq!(svc.rename_library("nope", br#"{"title":"x"}"#).unwrap_err().status, 404);
    add(&svc, &b, "w.pdf", &book("pipe", 2, None));
    drain(&svc);
    // renaming a published library changes the title in its settings
    svc.rename_library(&b, br#"{"title":"Plumbing"}"#).unwrap();
    let s: Value = serde_json::from_slice(&std::fs::read(svc.live_dir(&b).join("cache-library.json")).unwrap()).unwrap();
    assert_eq!(s["title"], json!("Plumbing"));
    // a restart finds both libraries and the book
    let (svc2, _) = rig(&d);
    assert_eq!(svc2.libraries().as_array().unwrap().len(), 2);
    assert_eq!(svc2.books(&b).unwrap().as_array().unwrap().len(), 1);
    // delete: files, work copy, PDF copies and metadata go
    add(&svc, &b, "w2.pdf", &book("valve", 2, None));
    assert_eq!(svc.delete_library("nope").unwrap_err().status, 404);
    svc.delete_library(&b).unwrap();
    assert!(!svc.live_dir(&b).exists() && !d.0.join("build/work").join(&b).exists() && !svc.meta_path(&b).exists());
    assert!(!d.0.join("app/docs/sources").join(&b).exists());
    assert_eq!(lock(&svc.st).items.len(), 0, "its waiting books went with it");
    assert_eq!(std::fs::read_dir(d.0.join("build/pending")).unwrap().count(), 0);
    assert_eq!(svc.libraries().as_array().unwrap().len(), 1);
}

/// The swap: at every request to the core to rescan, the library folder holds either no shard or a whole one.
#[test]
fn the_core_only_ever_sees_a_whole_shard() {
    let d = TempDir::new("b15");
    type Seen = Vec<(bool, Option<usize>)>;
    let seen: Arc<Mutex<Seen>> = Arc::new(Mutex::new(vec![]));
    let live = Arc::new(Mutex::new(PathBuf::new()));
    let (seen2, live2) = (seen.clone(), live.clone());
    let hook: Arc<dyn Fn() + Send + Sync> = Arc::new(move || {
        let dir = lock(&live2).clone();
        let shard = dir.join("shard").is_dir();
        let docs = if shard { Some(check_library_dir(&dir).expect("a shard the core sees must open")["docs"].as_u64().unwrap() as usize) } else { None };
        lock(&seen2).push((shard, docs));
    });
    let (svc, _) = rig_with(&d, BuildConfig { on_rescan: Some(hook), ..cfg() });
    let lib = new_lib(&svc, "L");
    *lock(&live) = svc.live_dir(&lib);
    add(&svc, &lib, "a.pdf", &book("one", 3, None));
    drain(&svc);
    let first = passages(&svc, &lib);
    // the first publish: nothing to take away, the core is told once, and the shard is whole
    assert_eq!(*lock(&seen), vec![(true, Some(first as usize))]);
    lock(&seen).clear();
    add(&svc, &lib, "b.pdf", &book("two", 3, None));
    drain(&svc);
    let all = passages(&svc, &lib);
    // the second: the old shard is moved away (no shard seen), then the new, whole one is in place
    assert_eq!(*lock(&seen), vec![(false, None), (true, Some(all as usize))]);
    // nothing of the swap is left behind
    let names: Vec<String> = std::fs::read_dir(svc.live_dir(&lib)).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    for n in &names {
        assert!(!n.starts_with('.'), "left behind: {names:?}");
    }
}

#[test]
fn books_are_published_when_the_queue_for_the_library_is_empty_or_after_the_interval() {
    let d = TempDir::new("b16");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "a.pdf", &book("one", 2, None));
    add(&svc, &lib, "b.pdf", &book("two", 2, None));
    assert!(matches!(svc.run_one(), Run::Ran));
    assert!(!svc.live_dir(&lib).join("shard").exists(), "more books are waiting: not yet");
    assert_eq!(svc.libraries()[0]["dirty"], json!(true));
    assert!(matches!(svc.run_one(), Run::Ran));
    assert!(svc.live_dir(&lib).join("shard").is_dir());
    assert_eq!(svc.libraries()[0]["dirty"], json!(false));
    // with an interval of zero, every book is published
    let d2 = TempDir::new("b16b");
    let (svc2, _) = rig_with(&d2, BuildConfig { publish_every: Duration::ZERO, ..cfg() });
    let lib2 = new_lib(&svc2, "L");
    add(&svc2, &lib2, "a.pdf", &book("one", 2, None));
    add(&svc2, &lib2, "b.pdf", &book("two", 2, None));
    assert!(matches!(svc2.run_one(), Run::Ran));
    assert!(svc2.live_dir(&lib2).join("shard").is_dir());
    // paused: finished books are published at once
    let d3 = TempDir::new("b16c");
    let (svc3, _) = rig(&d3);
    let lib3 = new_lib(&svc3, "L");
    add(&svc3, &lib3, "a.pdf", &book("one", 2, None));
    add(&svc3, &lib3, "b.pdf", &book("two", 2, None));
    assert!(matches!(svc3.run_one(), Run::Ran));
    svc3.pause();
    assert!(matches!(svc3.run_one(), Run::Idle));
    assert!(svc3.live_dir(&lib3).join("shard").is_dir());
}

#[test]
fn a_swap_cut_short_by_a_crash_is_repaired_at_the_next_start() {
    let d = TempDir::new("b17");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "a.pdf", &book("one", 3, None));
    drain(&svc);
    let live = svc.live_dir(&lib);
    let docs = live_docs(&svc, &lib);
    // crashed after the old shard was moved away, before the new one was put in place
    std::fs::rename(live.join("shard"), live.join(".shard.old")).unwrap();
    std::fs::create_dir_all(live.join(".shard.new.tmp")).unwrap();
    std::fs::write(live.join(".shard.new.tmp/half"), b"x").unwrap();
    let (_svc2, _) = rig(&d);
    assert_eq!(live_docs(&svc, &lib), docs, "the old shard is put back");
    assert!(!live.join(".shard.old").exists() && !live.join(".shard.new.tmp").exists());
    // crashed after the new copy was finished, before it was renamed in
    std::fs::rename(live.join("shard"), live.join(".shard.new")).unwrap();
    std::fs::create_dir_all(live.join(".shard.old")).unwrap();
    let (_svc3, _) = rig(&d);
    assert_eq!(live_docs(&svc, &lib), docs, "the finished copy is promoted");
    assert!(!live.join(".shard.old").exists() && !live.join(".shard.new").exists());
}

#[test]
fn a_lost_work_shard_is_made_again_from_the_packs() {
    let d = TempDir::new("b18");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "a.pdf", &book("one", 3, None));
    drain(&svc);
    let n = passages(&svc, &lib);
    std::fs::remove_dir_all(d.0.join("build/work")).unwrap();
    add(&svc, &lib, "b.pdf", &book("two", 3, None));
    drain(&svc);
    assert!(passages(&svc, &lib) > n);
    assert_eq!(live_docs(&svc, &lib) as u64, passages(&svc, &lib), "the first book is still there");
}

#[tokio::test]
async fn uploads_are_streamed_checked_and_queued() {
    use http_body_util::Full;
    let d = TempDir::new("b19");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    let pdf = book("uplink", 2, None);
    let q = format!("library_id={lib}&name=my%20book.pdf");
    let body = || Full::new(Bytes::from(pdf.clone()));
    let v = svc.upload("", None, &q, Some(pdf.len() as u64), body()).await.unwrap();
    assert_eq!((v["state"].as_str(), v["file_name"].as_str(), v["position"].as_u64()), (Some("queued"), Some("my book.pdf"), Some(1)));
    assert_eq!(std::fs::read(d.0.join("build/pending").join(format!("{}.pdf", v["id"].as_str().unwrap()))).unwrap(), pdf);
    assert_eq!(svc.upload("", None, &q, None, body()).await.unwrap_err().status, 411);
    assert_eq!(svc.upload("", None, &q, Some(5), body()).await.unwrap_err().code, "invalid");
    assert_eq!(svc.upload("", None, &q, Some(pdf.len() as u64 + 5), body()).await.unwrap_err().code, "upload_interrupted");
    let txt = Full::new(Bytes::from_static(b"just some text"));
    assert_eq!(svc.upload("", None, &q, Some(14), txt).await.unwrap_err().code, "not_pdf");
    assert_eq!(svc.upload("", None, "library_id=nope&name=a.pdf", Some(pdf.len() as u64), body()).await.unwrap_err().status, 404);
    assert_eq!(svc.upload(&lib, None, "name=..%2Fx.pdf", Some(pdf.len() as u64), body()).await.unwrap_err().code, "invalid_name");
    assert_eq!(svc.upload(&lib, Some("nope"), "name=a.pdf", Some(pdf.len() as u64), body()).await.unwrap_err().status, 404);
    // nothing but the one good upload is in the staging folder
    assert_eq!(std::fs::read_dir(d.0.join("build/pending")).unwrap().count(), 1);
}

// ---- the drop folder

fn drop_rig(dir: &TempDir, settle_ms: u64) -> (Arc<BuildService>, Arc<FakeEmbed>, String, PathBuf) {
    let (svc, fake) = rig_with(dir, BuildConfig { settle: Duration::from_millis(settle_ms), ..cfg() });
    let lib = new_lib(&svc, "Dropped");
    let root = dir.0.join("dropbox");
    svc.drop_put(json!({"folder": root.to_string_lossy(), "enabled": true, "library_id": lib}).to_string().as_bytes()).unwrap();
    (svc, fake, lib, root)
}

fn put(root: &Path, folder: &str, name: &str, data: &[u8]) {
    std::fs::write(root.join(folder).join(name), data).unwrap();
}

fn names(root: &Path, folder: &str) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(root.join(folder)).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    v.sort();
    v
}

/// Every file below `dir`, as paths relative to it with '/'.
fn tree_files(dir: &Path) -> Vec<String> {
    fn walk(base: &Path, dir: &Path, out: &mut Vec<String>) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            if e.path().is_dir() {
                walk(base, &e.path(), out);
            } else {
                out.push(e.path().strip_prefix(base).unwrap().to_string_lossy().replace('\\', "/"));
            }
        }
    }
    let mut v = vec![];
    walk(dir, dir, &mut v);
    v.sort();
    v
}

fn settle(ms: u64) {
    std::thread::sleep(Duration::from_millis(ms));
}

#[test]
fn the_drop_folder_makes_its_subfolders_and_takes_a_file_only_after_it_settles() {
    let d = TempDir::new("d1");
    let (svc, _, _, root) = drop_rig(&d, 300);
    for f in ["ingest", "complete", "failed"] {
        assert!(root.join(f).is_dir());
    }
    put(&root, "ingest", "a.pdf", &book("drop", 2, None));
    assert!(svc.scan(), "a new file is settling");
    assert!(lock(&svc.st).items.is_empty());
    // a file that is still growing starts its wait again
    settle(150);
    put(&root, "ingest", "a.pdf", &book("drop", 3, None));
    assert!(svc.scan());
    settle(200);
    assert!(svc.scan(), "it changed 200 ms ago");
    assert!(lock(&svc.st).items.is_empty());
    settle(350);
    assert!(!svc.scan());
    assert_eq!(lock(&svc.st).items.len(), 1);
    // looking again does not queue it twice
    svc.scan();
    assert_eq!(lock(&svc.st).items.len(), 1);
    let v = svc.drop_view();
    assert_eq!(v["files"][0]["state"], json!("queued"));
    assert_eq!(v["files"][0]["position"], json!(1));
    assert_eq!(v["status"]["counts"]["queue"], json!(1));
}

#[test]
fn built_and_duplicate_pdfs_move_to_complete_and_failures_to_failed_with_a_note() {
    let d = TempDir::new("d2");
    let (svc, _, lib, root) = drop_rig(&d, 0);
    let pdf = book("spring", 2, Some("Spring"));
    put(&root, "ingest", "one.pdf", &pdf);
    put(&root, "ingest", "same.pdf", &pdf);
    put(&root, "ingest", "broken.pdf", b"%PDF-1.4\nnot really");
    put(&root, "ingest", "Scan.PDF", &make_pdf(&[picture_page()], None));
    svc.scan();
    svc.scan(); // the first look sees the files; with a settle of zero the second takes them... or the first does
    assert_eq!(lock(&svc.st).items.len(), 4);
    assert!(names(&root, "ingest").len() == 4, "still in ingest/ while they wait");
    drain(&svc);
    assert_eq!(names(&root, "ingest"), Vec::<String>::new());
    let complete = tree_files(&root.join("complete"));
    assert_eq!(complete.len(), 1, "the built book is filed in complete/; the exact copy is in Removed: {complete:?}");
    assert!(complete[0].contains('/') && complete[0].ends_with(".pdf"), "{complete:?}");
    assert_eq!(svc.removed_view()["count"], json!(1));
    assert_eq!(svc.removed_view()["items"][0]["reason"], json!("Exact copy of Spring"));
    let failed = names(&root, "failed");
    assert_eq!(failed, vec!["Scan.PDF", "Scan.PDF.why.txt", "broken.pdf", "broken.pdf.why.txt"]);
    assert!(!std::fs::read_to_string(root.join("failed/broken.pdf.why.txt")).unwrap().trim().is_empty());
    assert!(std::fs::read_to_string(root.join("failed/Scan.PDF.why.txt")).unwrap().contains("OCR"));
    // the table says why
    let v = svc.drop_view();
    let files = v["files"].as_array().unwrap();
    let dup = files.iter().find(|f| f["folder"] == json!("removed") && f["state"] == json!("duplicate")).expect("a duplicate");
    assert_eq!(dup["reason"], json!("Exact copy of Spring"));
    let broken = files.iter().find(|f| f["name"] == json!("broken.pdf")).unwrap();
    assert_eq!((broken["state"].as_str(), broken["can_retry"].as_bool()), (Some("failed"), Some(true)));
    assert_eq!(v["status"]["counts"]["complete"], json!(1));
    assert_eq!(v["status"]["counts"]["failed"], json!(2));
    // the built book is in the library, with its PDF copy
    assert_eq!(svc.books(&lib).unwrap().as_array().unwrap().len(), 1);
}

#[test]
fn zims_and_library_packages_are_installed_and_other_files_are_refused() {
    let d = TempDir::new("d3");
    let (svc, _, _, root) = drop_rig(&d, 0);
    put(&root, "ingest", "wiki.zim", b"ZIMDATA");
    put(&root, "ingest", "kit.cache-library", b"LIBDATA");
    put(&root, "ingest", "kit2.tar.gz", &[0x1f, 0x8b, 8, 0, 1, 2, 3]);
    put(&root, "ingest", "fake.gz", b"plain text");
    put(&root, "ingest", "notes.txt", b"hello");
    put(&root, "ingest", ".hidden.pdf", b"x");
    svc.scan();
    assert_eq!(names(&root, "complete"), vec!["Library files", "ZIM files"]);
    assert_eq!(names(&root, "complete/Library files"), vec!["kit.cache-library", "kit2.tar.gz"]);
    assert_eq!(names(&root, "complete/ZIM files"), vec!["wiki.zim"]);
    assert_eq!(names(&root, "failed"), vec!["fake.gz", "fake.gz.why.txt", "notes.txt", "notes.txt.why.txt"]);
    assert_eq!(std::fs::read_to_string(root.join("failed/notes.txt.why.txt")).unwrap().trim(), "Not a file Cache can use");
    assert_eq!(std::fs::read_to_string(root.join("failed/fake.gz.why.txt")).unwrap().trim(), "Not a file Cache can use");
    assert_eq!(names(&root, "ingest"), vec![".hidden.pdf"], "hidden files are left alone");
    // installed where an upload would put them
    assert_eq!(std::fs::read(d.0.join("app/docs/zims/wiki.zim")).unwrap(), b"ZIMDATA");
    assert_eq!(std::fs::read(d.0.join("app/docs/incoming/kit.cache-library")).unwrap(), b"LIBDATA");
    assert!(d.0.join("app/docs/incoming/kit2.tar.gz").is_file());
    // the copies in complete/ are the files themselves
    assert_eq!(std::fs::read(root.join("complete/ZIM files/wiki.zim")).unwrap(), b"ZIMDATA");
    // not usable files cannot be retried; the table says so
    let v = svc.drop_view();
    let notes = v["files"].as_array().unwrap().iter().find(|f| f["name"] == json!("notes.txt")).unwrap();
    assert_eq!((notes["state"].as_str(), notes["can_retry"].as_bool()), (Some("unsupported"), Some(false)));
    // nothing is left in the work folder
    assert_eq!(std::fs::read_dir(d.0.join("tmp")).unwrap().count(), 0);
}

#[test]
fn retry_moves_a_failed_file_back_to_the_end_of_the_queue() {
    let d = TempDir::new("d4");
    let (svc, _, _, root) = drop_rig(&d, 0);
    put(&root, "ingest", "broken.pdf", b"%PDF-1.4\nnot really");
    svc.scan();
    drain(&svc);
    assert_eq!(names(&root, "failed"), vec!["broken.pdf", "broken.pdf.why.txt"]);
    put(&root, "ingest", "later.pdf", &book("later", 2, None));
    svc.scan();
    let v = svc.drop_retry(br#"{"name":"broken.pdf"}"#).unwrap();
    assert_eq!(names(&root, "failed"), Vec::<String>::new());
    assert_eq!(names(&root, "ingest"), vec!["broken.pdf", "later.pdf"]);
    assert!(v["files"].as_array().unwrap().iter().any(|f| f["name"] == json!("broken.pdf")));
    svc.scan();
    let order: Vec<String> = lock(&svc.st).items.iter().filter(|i| i.state == S::Queued).map(|i| i.file_name.clone()).collect();
    assert_eq!(order, vec!["later.pdf", "broken.pdf"], "the retried file is last");
    assert_eq!(svc.drop_retry(br#"{"name":"nothing.pdf"}"#).unwrap_err().status, 409);
    assert_eq!(svc.drop_retry(br#"{"name":"../x"}"#).unwrap_err().status, 400);
    // from the queue list: the same move
    drain(&svc);
    let id = lock(&svc.st).items.iter().find(|i| i.file_name == "broken.pdf").unwrap().id.clone();
    svc.retry(&id).unwrap();
    assert_eq!(names(&root, "ingest"), vec!["broken.pdf"]);
    assert_eq!(names(&root, "failed"), Vec::<String>::new());
}

#[test]
fn names_that_clash_in_complete_and_failed_get_a_number() {
    let d = TempDir::new("d5");
    let (svc, _, _, root) = drop_rig(&d, 0);
    for i in 0..3 {
        put(&root, "ingest", "notes.txt", format!("n{i}").as_bytes());
        svc.scan();
    }
    assert_eq!(names(&root, "failed"), vec!["notes (2).txt", "notes (2).txt.why.txt", "notes (3).txt", "notes (3).txt.why.txt", "notes.txt", "notes.txt.why.txt"]);
    for i in 0..2 {
        put(&root, "ingest", "wiki.zim", format!("z{i}").as_bytes());
        svc.scan();
    }
    assert_eq!(names(&root, "complete/ZIM files"), vec!["wiki (2).zim", "wiki.zim"]);
    assert_eq!(unique_name(&root.join("complete/ZIM files"), "none"), "none");
    assert_eq!(unique_name(&root.join("complete/ZIM files"), "wiki.zim"), "wiki (3).zim");
}

#[test]
fn a_file_taken_out_of_ingest_by_hand_leaves_the_queue() {
    let d = TempDir::new("d6");
    let (svc, _, _, root) = drop_rig(&d, 0);
    put(&root, "ingest", "a.pdf", &book("hand", 2, None));
    put(&root, "ingest", "b.pdf", &book("foot", 2, None));
    svc.scan();
    assert_eq!(lock(&svc.st).items.len(), 2);
    std::fs::remove_file(root.join("ingest/a.pdf")).unwrap();
    svc.scan();
    assert_eq!(lock(&svc.st).items.len(), 1);
    drain(&svc);
    assert_eq!(tree_files(&root.join("complete")).len(), 1);
    // a book whose file goes while it waits (and was not yet noticed by a check) is dropped quietly at its turn
    put(&root, "ingest", "c.pdf", &book("gone", 2, None));
    svc.scan();
    std::fs::remove_file(root.join("ingest/c.pdf")).unwrap();
    drain(&svc);
    assert!(lock(&svc.st).items.iter().all(|i| i.file_name != "c.pdf"));
    assert_eq!(names(&root, "failed"), Vec::<String>::new());
}

#[test]
fn a_missing_or_unreadable_folder_shows_in_the_status_and_keeps_the_files() {
    let d = TempDir::new("d7");
    let (svc, _, _, root) = drop_rig(&d, 0);
    put(&root, "ingest", "a.pdf", &book("usb", 2, None));
    svc.scan();
    svc.drop_view();
    let moved = d.0.join("unplugged");
    std::fs::rename(&root, &moved).unwrap();
    svc.scan();
    let v = svc.drop_view();
    assert_eq!((v["status"]["state"].as_str(), v["status"]["error"]["code"].as_str()), (Some("error"), Some("missing")));
    assert_eq!(v["status"]["error"]["message"], json!("The drop folder is missing"));
    assert_eq!(v["status"]["stale"], json!(true));
    assert_eq!(v["files"].as_array().unwrap().len(), 1, "the last known state is shown");
    assert!(!root.exists(), "an unplugged folder is not made again");
    // back again: it carries on
    std::fs::rename(&moved, &root).unwrap();
    svc.scan();
    let v = svc.drop_view();
    assert_eq!(v["status"]["state"], json!("ok"));
    assert_eq!(v["status"]["error"], Value::Null);
    // no permission
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(root.join("ingest"), std::fs::Permissions::from_mode(0o000)).unwrap();
        if std::fs::read_dir(root.join("ingest")).is_err() {
            svc.scan();
            let v = svc.drop_view();
            assert_eq!(v["status"]["error"]["code"], json!("denied"));
            assert_eq!(v["status"]["error"]["message"], json!("Cache can not read the drop folder"));
        }
        std::fs::set_permissions(root.join("ingest"), std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    // off means no looking
    svc.drop_put(br#"{"enabled":false}"#).unwrap();
    put(&root, "ingest", "z.txt", b"x");
    svc.scan();
    assert_eq!(names(&root, "failed"), Vec::<String>::new());
    assert_eq!(svc.drop_view()["status"]["state"], json!("off"));
}

#[test]
fn drop_settings_are_checked_and_remembered() {
    let d = TempDir::new("d8");
    let (svc, _) = rig(&d);
    let v = svc.drop_view();
    assert_eq!(v["settings"]["folder"], json!(d.0.join("drop").to_string_lossy()));
    assert_eq!((v["settings"]["enabled"].as_bool(), v["status"]["state"].as_str()), (Some(false), Some("off")));
    assert_eq!(svc.drop_put(b"nope").unwrap_err().status, 400);
    assert_eq!(svc.drop_put(br#"{"folder":"relative/path"}"#).unwrap_err().status, 400);
    assert_eq!(svc.drop_put(br#"{"folder":"/a/../b"}"#).unwrap_err().status, 400);
    assert_eq!(svc.drop_put(br#"{"enabled":"yes"}"#).unwrap_err().status, 400);
    assert_eq!(svc.drop_put(br#"{"library_id":"nope"}"#).unwrap_err().status, 404);
    let lib = new_lib(&svc, "L");
    let folder = d.0.join("elsewhere");
    let v = svc.drop_put(json!({"folder": folder.to_string_lossy(), "library_id": lib}).to_string().as_bytes()).unwrap();
    assert_eq!(v["settings"]["library_title"], json!("L"));
    // turning it on makes the folder and its three subfolders
    svc.drop_put(br#"{"enabled":true}"#).unwrap();
    assert!(folder.join("ingest").is_dir() && folder.join("complete").is_dir() && folder.join("failed").is_dir());
    let (svc2, _) = rig_with(&d, BuildConfig { settle: Duration::ZERO, ..cfg() });
    let v = svc2.drop_view();
    assert_eq!((v["settings"]["enabled"].as_bool(), v["settings"]["library_id"].as_str()), (Some(true), Some(lib.as_str())));
    // PDFs wait in ingest/ when no library is chosen
    svc2.drop_put(br#"{"library_id":null}"#).unwrap();
    put(&folder, "ingest", "a.pdf", &book("nolib", 2, None));
    svc2.scan();
    assert_eq!(names(&folder, "ingest"), vec!["a.pdf"]);
    assert_eq!(svc2.drop_view()["status"]["error"]["code"], json!("no_library"));
}

// ---- filing by subject, the same book in another file, Removed

/// A small set of classes whose descriptions use the words the test books are about (the fake embedder reads words), and a
/// classifier model that knows them.
fn small_classes(d: &TempDir) {
    small_classes_without_model(d);
    small_model(d);
}

/// A classifier model file for the small classes (version 1): each division's column is the fake embedder's vector of its name
/// and description, scaled; the threshold sits between the books about the divisions and a book about nothing here.
fn small_model(d: &TempDir) {
    use cache_classify::{encode, Class, ModelSpec, Recipe, Weights};
    let divs = [(510u16, "Wells", "well well wells digging"), (520, "Rain", "rainwater cistern barrel"), (710, "Radio", "radio antenna transmitter")];
    let texts: Vec<String> = divs.iter().map(|(_, n, t)| format!("{n}. {t}")).collect();
    let cols = FakeEmbedder.embed_batch(&texts);
    let (dims, n) = (cols[0].len(), cols.len());
    let mut w = vec![0f32; dims * n];
    for (j, c) in cols.iter().enumerate() {
        for (i, x) in c.iter().enumerate() {
            w[i * n + j] = 25.0 * x;
        }
    }
    let top = |topic: &str| -> f32 {
        let page = text_page(topic, 1, 120).lines.join(" ");
        let v = FakeEmbedder.embed_batch(&[page]).remove(0);
        let e: Vec<f32> = (0..n).map(|j| (0..dims).map(|i| v[i] * w[i * n + j]).sum::<f32>()).collect();
        let m = e.iter().cloned().fold(f32::MIN, f32::max);
        1.0 / e.iter().map(|x| (x - m).exp()).sum::<f32>()
    };
    let (pos, neg) = (top("well").min(top("radio")), top("kiln"));
    assert!(pos > neg + 0.05, "the test model cannot tell the topics apart: {pos} {neg}");
    let mut sha = [0u8; 32];
    for (i, b) in sha.iter_mut().enumerate() {
        *b = u8::from_str_radix(&cache_embed::DECIDED_MODEL_SHA256[i * 2..i * 2 + 2], 16).unwrap();
    }
    let bytes = encode(&ModelSpec {
        classifier_version: 1,
        embedding_sha256: sha,
        dims: dims as u32,
        threshold: ((pos + neg) / 2.0) as f64,
        recipe: Recipe { first_pieces: 8, spread_pieces: 16 },
        classes: divs.iter().map(|(d, n, _)| Class { division: *d, label: n.to_string() }).collect(),
        bias: vec![0.0; n],
        weights: Weights::F32(w),
    });
    std::fs::create_dir_all(d.0.join("models")).unwrap();
    std::fs::write(d.0.join("models/cache-classifier-1.bin"), bytes).unwrap();
}

fn small_classes_without_model(d: &TempDir) {
    std::fs::create_dir_all(d.0.join("build")).unwrap();
    let c = json!({"version": 1, "classes": [
        {"number": "500", "name": "Water and Energy", "divisions": [
            {"number": "510", "name": "Wells", "description": "well well wells digging"},
            {"number": "520", "name": "Rain", "description": "rainwater cistern barrel"}]},
        {"number": "700", "name": "Communication", "divisions": [
            {"number": "710", "name": "Radio", "description": "radio antenna transmitter"},
            {"number": "720", "name": "Unused", "description": ""}]}]});
    std::fs::write(d.0.join("build/classes.json"), c.to_string()).unwrap();
}

fn tune(d: &TempDir, v: Value) {
    std::fs::create_dir_all(d.0.join("build")).unwrap();
    std::fs::write(d.0.join("build/tuning.json"), v.to_string()).unwrap();
}

/// `n` text pages about `topic`, numbered from `from`, with a metadata title.
fn pdf_of(topic: &str, from: usize, n: usize, title: &str) -> Vec<u8> {
    let pages: Vec<Page> = (from..from + n).map(|i| text_page(topic, i, 120)).collect();
    make_pdf(&pages, Some(title))
}

fn by_title<'a>(books: &'a Value, title: &str) -> &'a Value {
    books.as_array().unwrap().iter().find(|b| b["title"] == json!(title)).unwrap_or_else(|| panic!("no book {title}: {books}"))
}

fn src_file(d: &TempDir, lib: &str, rel: &str) -> PathBuf {
    d.0.join("app/docs/sources").join(lib).join(rel)
}

#[test]
fn a_book_is_filed_by_meaning_and_an_unsure_one_goes_to_unsorted() {
    let d = TempDir::new("c1");
    small_classes(&d);
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    let a = add(&svc, &lib, "a.pdf", &book("well", 3, Some("The Well Handbook")));
    add(&svc, &lib, "b.pdf", &book("radio", 3, Some("Antenna Notes")));
    let c = add(&svc, &lib, "c.pdf", &book("kiln", 3, Some("Kiln Craft")));
    drain(&svc);
    let books = svc.books(&lib).unwrap();
    let w = by_title(&books, "The Well Handbook");
    assert_eq!((w["division"].as_str(), w["class"].as_str(), w["call_number"].as_str()), (Some("510"), Some("500"), Some("510 · WEL")));
    assert_eq!((w["division_name"].as_str(), w["unsorted"].as_bool()), (Some("Wells"), Some(false)));
    let sug = w["suggestions"].as_array().unwrap();
    assert!(!sug.is_empty() && sug.len() <= 3, "{sug:?}");
    assert_eq!(sug[0]["division"], json!("510"));
    let r = by_title(&books, "Antenna Notes");
    assert_eq!((r["division"].as_str(), r["class"].as_str(), r["call_number"].as_str()), (Some("710"), Some("700"), Some("710 · ANT")));
    let k = by_title(&books, "Kiln Craft");
    assert_eq!((k["division"].is_null(), k["unsorted"].as_bool(), k["call_number"].as_str()), (true, Some(true), Some("KIL")));
    assert!(k["unsure_reason"].as_str().is_some_and(|m| !m.is_empty()));
    assert_eq!(k["placed_by_hand"], json!(false));
    // the device copies are filed in the tree
    assert!(src_file(&d, &lib, "500 Water and Energy/510 Wells/510 · WEL  The Well Handbook.pdf").is_file());
    assert!(src_file(&d, &lib, "700 Communication/710 Radio/710 · ANT  Antenna Notes.pdf").is_file());
    assert!(src_file(&d, &lib, "Unsorted/KIL  Kiln Craft.pdf").is_file());
    assert_eq!(svc.source_path(&lib, w["id"].as_str().unwrap()), src_file(&d, &lib, "500 Water and Energy/510 Wells/510 · WEL  The Well Handbook.pdf"));
    assert_eq!(w["filed_in"], json!("500 Water and Energy/510 Wells"));
    // the queue says where each went
    let (ia, ic) = (item(&svc, &a), item(&svc, &c));
    assert_eq!((ia.division.as_deref(), ia.result.as_deref()), (Some("510"), Some("Filed in 510 Wells")));
    assert_eq!((ic.division, ic.result.as_deref()), (None, Some("Filed in Unsorted")));
    // counts per class and division, and Unsorted
    let v = svc.classes_view(None).unwrap();
    assert_eq!(v["classes"].as_array().unwrap().len(), 2);
    assert_eq!(v["unsorted"]["count"], json!(1));
    assert_eq!((v["libraries"][0]["divisions"]["510"].as_u64(), v["libraries"][0]["divisions"]["520"].as_u64()), (Some(1), Some(0)));
    assert_eq!((v["libraries"][0]["classes"]["500"].as_u64(), v["libraries"][0]["classes"]["700"].as_u64()), (Some(1), Some(1)));
    assert_eq!((v["libraries"][0]["unsorted"].as_u64(), v["classes"][0]["divisions"][0]["count"].as_u64()), (Some(1), Some(1)));
    assert_eq!(svc.classes_view(Some("nope")).unwrap_err().status, 404);
    assert_eq!(svc.classes_view(Some(&lib)).unwrap()["libraries"].as_array().unwrap().len(), 1);
    // books by division, by class, in Unsorted, and by call number (Unsorted first)
    assert_eq!(svc.books_q(&lib, "division=510").unwrap().as_array().unwrap().len(), 1);
    assert_eq!(svc.books_q(&lib, "division=520").unwrap().as_array().unwrap().len(), 0);
    assert_eq!(svc.books_q(&lib, "division=unsorted").unwrap().as_array().unwrap().len(), 1);
    assert_eq!(svc.books_q(&lib, "class=700").unwrap()[0]["title"], json!("Antenna Notes"));
    let by_call: Vec<String> = svc.books_q(&lib, "sort=call").unwrap().as_array().unwrap().iter().map(|b| b["call_number"].as_str().unwrap().to_string()).collect();
    assert_eq!(by_call, vec!["KIL", "510 · WEL", "710 · ANT"]);
    // classification is not in the search payloads: the pack header carries none of it
    let doc = w["id"].as_str().unwrap();
    let p = read_pack(&svc.packs_dir(&lib).join(format!("{doc}@1.cdoc"))).unwrap();
    let header = serde_json::to_string(&p.header).unwrap();
    assert!(!header.contains("division") && !header.contains("call_number") && !header.contains("suggestions"), "{header}");
}

#[test]
fn placing_a_book_moves_its_files_and_changes_its_call_number() {
    let d = TempDir::new("c2");
    small_classes(&d);
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "k.pdf", &book("kiln", 3, Some("Kiln Craft")));
    drain(&svc);
    let doc = svc.books(&lib).unwrap()[0]["id"].as_str().unwrap().to_string();
    let r = svc.place_book(&lib, &doc, br#"{"division":"510"}"#).unwrap();
    assert_eq!((r["call_number"].as_str(), r["division"].as_str(), r["placed_by_hand"].as_bool()), (Some("510 · KIL"), Some("510"), Some(true)));
    assert_eq!((r["moved_from"].as_str(), r["unsorted"].as_bool()), (Some("Unsorted"), Some(false)));
    assert!(!src_file(&d, &lib, "Unsorted/KIL  Kiln Craft.pdf").exists());
    assert!(src_file(&d, &lib, "500 Water and Energy/510 Wells/510 · KIL  Kiln Craft.pdf").is_file());
    assert!(svc.source_path(&lib, &doc).is_file());
    // refused
    assert_eq!(svc.place_book(&lib, &doc, br#"{"division":"999"}"#).unwrap_err().status, 400);
    assert_eq!(svc.place_book(&lib, &doc, br#"{"division":"720"}"#).unwrap_err().status, 400, "an unassigned division");
    assert_eq!(svc.place_book(&lib, &doc, br#"{"x":1}"#).unwrap_err().status, 400);
    assert_eq!(svc.place_book(&lib, &doc, b"nope").unwrap_err().code, "bad_json");
    assert_eq!(svc.place_book(&lib, "nope", br#"{"division":"510"}"#).unwrap_err().status, 404);
    // a book the person placed stays where it is when the books are looked at again
    let v = svc.reclassify(b"{}").unwrap();
    assert_eq!((v["checked"].as_u64(), v["moved"].as_u64()), (Some(0), Some(0)));
    // a new title keeps the call number's letters; the filed PDF takes the new name
    svc.rename_book(&lib, &doc, br#"{"title":"Zebra Notes"}"#).unwrap();
    assert!(src_file(&d, &lib, "500 Water and Energy/510 Wells/510 · KIL  Zebra Notes.pdf").is_file());
    assert_eq!(svc.books(&lib).unwrap()[0]["call_number"], json!("510 · KIL"));
    // and back to Unsorted
    let r = svc.place_book(&lib, &doc, br#"{"division":"unsorted"}"#).unwrap();
    assert_eq!((r["call_number"].as_str(), r["moved_from"].as_str()), (Some("KIL"), Some("510 Wells")));
    assert!(src_file(&d, &lib, "Unsorted/KIL  Zebra Notes.pdf").is_file());
    assert!(!src_file(&d, &lib, "500 Water and Energy/510 Wells/510 · KIL  Zebra Notes.pdf").exists());
}

#[test]
fn books_from_the_drop_folder_are_filed_in_complete_and_their_files_follow_a_placement() {
    let d = TempDir::new("c3");
    small_classes(&d);
    let (svc, _, lib, root) = drop_rig(&d, 0);
    put(&root, "ingest", "a.pdf", &book("well", 3, Some("The Well Handbook")));
    put(&root, "ingest", "b.pdf", &book("kiln", 3, Some("Kiln Craft")));
    svc.scan();
    drain(&svc);
    assert_eq!(tree_files(&root.join("complete")), vec!["500 Water and Energy/510 Wells/510 · WEL  The Well Handbook.pdf", "Unsorted/KIL  Kiln Craft.pdf"]);
    assert_eq!(names(&root, "ingest"), Vec::<String>::new());
    let v = svc.drop_view();
    let files = v["files"].as_array().unwrap();
    let well = files.iter().find(|f| f["path"] == json!("500 Water and Energy/510 Wells/510 · WEL  The Well Handbook.pdf")).expect("the well book");
    assert_eq!((well["class"].as_str(), well["division"].as_str(), well["call_number"].as_str()), (Some("500"), Some("510"), Some("510 · WEL")));
    assert_eq!((well["where"].as_str(), well["title"].as_str(), well["reason"].as_str()), (Some("500 Water and Energy/510 Wells"), Some("The Well Handbook"), Some("Filed in 510 Wells")));
    let kiln = files.iter().find(|f| f["name"] == json!("KIL  Kiln Craft.pdf")).expect("the kiln book");
    assert_eq!((kiln["division"].is_null(), kiln["where"].as_str(), kiln["reason"].as_str()), (true, Some("Unsorted"), Some("Filed in Unsorted")));
    // placing the unsure book moves the device copy and the copy in complete/
    let doc = svc.books(&lib).unwrap().as_array().unwrap().iter().find(|b| b["title"] == json!("Kiln Craft")).unwrap()["id"].as_str().unwrap().to_string();
    svc.place_book(&lib, &doc, br#"{"division":"520"}"#).unwrap();
    assert_eq!(tree_files(&root.join("complete")), vec!["500 Water and Energy/510 Wells/510 · WEL  The Well Handbook.pdf", "500 Water and Energy/520 Rain/520 · KIL  Kiln Craft.pdf"]);
    assert!(src_file(&d, &lib, "500 Water and Energy/520 Rain/520 · KIL  Kiln Craft.pdf").is_file());
    let v = svc.drop_view();
    let moved = v["files"].as_array().unwrap().iter().find(|f| f["path"] == json!("500 Water and Energy/520 Rain/520 · KIL  Kiln Craft.pdf")).expect("the placed book");
    assert_eq!((moved["moved_from"].as_str(), moved["division"].as_str()), (Some("Unsorted"), Some("520")));
    // two different books with the same title in one division: the second gets a number
    put(&root, "ingest", "c.pdf", &pdf_of("well", 50, 3, "Manual"));
    put(&root, "ingest", "d.pdf", &pdf_of("well", 80, 3, "Manual"));
    svc.scan();
    drain(&svc);
    let tree = tree_files(&root.join("complete"));
    assert!(tree.contains(&"500 Water and Energy/510 Wells/510 · MAN  Manual.pdf".to_string()), "{tree:?}");
    assert!(tree.contains(&"500 Water and Energy/510 Wells/510 · MAN  Manual (2).pdf".to_string()), "{tree:?}");
    assert!(src_file(&d, &lib, "500 Water and Energy/510 Wells/510 · MAN  Manual (2).pdf").is_file());
}

#[test]
fn flat_source_paths_are_migrated_at_start_up_and_the_books_are_filed_later() {
    let d = TempDir::new("c4");
    small_classes(&d);
    let lib;
    let docs: Vec<String>;
    {
        let (svc, _) = rig(&d);
        lib = new_lib(&svc, "L");
        add(&svc, &lib, "a.pdf", &book("well", 3, Some("The Well Handbook")));
        add(&svc, &lib, "k.pdf", &book("kiln", 3, Some("Kiln Craft")));
        drain(&svc);
        docs = svc.books(&lib).unwrap().as_array().unwrap().iter().map(|b| b["id"].as_str().unwrap().to_string()).collect();
        // as a library built before filing: the PDFs flat in sources/<library>/
        for doc in &docs {
            std::fs::rename(svc.source_path(&lib, doc), d.0.join("app/docs/sources").join(&lib).join(format!("{doc}.pdf"))).unwrap();
        }
    }
    let meta_path = d.0.join("build/libs").join(format!("{lib}.json"));
    let mut m: Value = serde_json::from_slice(&std::fs::read(&meta_path).unwrap()).unwrap();
    for b in m["books"].as_array_mut().unwrap() {
        let o = b.as_object_mut().unwrap();
        for k in ["source_rel", "letters", "division", "classified", "suggestions", "unsure", "minhash"] {
            o.remove(k);
        }
    }
    std::fs::write(&meta_path, m.to_string()).unwrap();
    let (svc, _) = rig(&d);
    for doc in &docs {
        let p = svc.source_path(&lib, doc);
        assert!(p.is_file(), "{p:?}");
        assert!(p.to_string_lossy().contains("/Unsorted/"), "{p:?}");
        assert!(!d.0.join("app/docs/sources").join(&lib).join(format!("{doc}.pdf")).exists(), "the flat file is gone");
    }
    // when the queue is idle each book is looked at once
    svc.maintenance();
    svc.maintenance();
    assert!(lock(&svc.st).libs[0].books.iter().all(|b| b.classified));
    let books = svc.books(&lib).unwrap();
    assert_eq!(by_title(&books, "The Well Handbook")["division"], json!("510"));
    assert!(src_file(&d, &lib, "500 Water and Energy/510 Wells/510 · WEL  The Well Handbook.pdf").is_file());
    assert!(src_file(&d, &lib, "Unsorted/KIL  Kiln Craft.pdf").is_file());
    assert!(!src_file(&d, &lib, "Unsorted/WEL  The Well Handbook.pdf").exists());
}

#[test]
fn the_classes_are_written_on_first_start_and_edits_are_picked_up() {
    let d = TempDir::new("c5");
    let (svc, fake) = rig(&d);
    assert!(d.0.join("build/classes.json").is_file());
    let v = svc.classes_view(None).unwrap();
    assert_eq!(v["classes"].as_array().unwrap().len(), 10);
    // no description vectors are made or kept: the classifier is a model file
    assert_eq!(fake.calls.load(Ordering::Relaxed), 0);
    assert!(!d.0.join("build/classes-vectors.json").exists());
    assert_eq!(svc.classes_view(None).unwrap()["settings"]["classifier_version"], Value::Null);
    let (svc2, fake2) = rig(&d);
    assert_eq!(fake2.calls.load(Ordering::Relaxed), 0);
    // an edit to the file is picked up; a broken file keeps the last good classes
    std::thread::sleep(Duration::from_millis(50));
    let path = d.0.join("build/classes.json");
    let mut c: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
    c["classes"][5]["divisions"][0]["description"] = json!("Wells, springs and boreholes, and how to find water underground.");
    std::fs::write(&path, c.to_string()).unwrap();
    let v = svc2.classes_view(None).unwrap();
    assert_eq!(v["classes"][5]["divisions"][0]["description"], json!("Wells, springs and boreholes, and how to find water underground."));
    std::thread::sleep(Duration::from_millis(50));
    std::fs::write(&path, "not json").unwrap();
    assert_eq!(svc2.classes_view(None).unwrap()["classes"].as_array().unwrap().len(), 10);
}

#[test]
fn with_no_model_file_every_book_waits_in_unsorted_and_a_model_dropped_in_files_them() {
    let d = TempDir::new("m1");
    small_classes_without_model(&d);
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "a.pdf", &book("well", 3, Some("The Well Handbook")));
    add(&svc, &lib, "b.pdf", &book("radio", 3, Some("Antenna Notes")));
    drain(&svc);
    // built and searchable, but not sorted: no suggestions, no classifier version, nothing broken
    let books = svc.books(&lib).unwrap();
    for t in ["The Well Handbook", "Antenna Notes"] {
        let b = by_title(&books, t);
        assert_eq!((b["unsorted"].as_bool(), b["suggestions"].as_array().map(|a| a.len()), b["classifier_version"].is_null()), (Some(true), Some(0), true), "{b}");
    }
    assert!(src_file(&d, &lib, "Unsorted/WEL  The Well Handbook.pdf").is_file());
    assert!(lock(&svc.st).libs[0].books.iter().all(|b| !b.classified));
    svc.maintenance();
    assert!(lock(&svc.st).libs[0].books.iter().all(|b| !b.classified), "nothing to do without a model");
    assert_eq!(svc.reclassify(b"{}").unwrap_err().code, "classifier_missing");
    // the place-it list is empty, not an error
    let doc = by_title(&books, "The Well Handbook")["id"].as_str().unwrap().to_string();
    let s = svc.suggestions(&lib, &doc).unwrap();
    assert_eq!((s["unsorted"].as_bool(), s["suggestions"].as_array().map(|a| a.len())), (Some(true), Some(0)));
    // a damaged or foreign model file changes nothing
    std::fs::create_dir_all(d.0.join("models")).unwrap();
    std::fs::write(d.0.join("models/cache-classifier-7.bin"), b"damaged").unwrap();
    assert_eq!(svc.reclassify(b"{}").unwrap_err().code, "classifier_missing");
    // the model file is dropped into the data folder: the waiting books are filed when the queue is idle
    small_model(&d);
    svc.maintenance();
    svc.maintenance();
    let books = svc.books(&lib).unwrap();
    let w = by_title(&books, "The Well Handbook");
    assert_eq!((w["division"].as_str(), w["classifier_version"].as_u64()), (Some("510"), Some(1)));
    assert_eq!(by_title(&books, "Antenna Notes")["division"], json!("710"));
    assert!(src_file(&d, &lib, "500 Water and Energy/510 Wells/510 · WEL  The Well Handbook.pdf").is_file());
}

#[test]
fn an_unsure_book_keeps_the_top_three_with_probabilities_and_the_version() {
    let d = TempDir::new("m2");
    small_classes(&d);
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "a.pdf", &book("well", 3, Some("The Well Handbook")));
    add(&svc, &lib, "k.pdf", &book("kiln", 3, Some("Kiln Craft")));
    drain(&svc);
    let books = svc.books(&lib).unwrap();
    let k = by_title(&books, "Kiln Craft");
    assert_eq!((k["unsorted"].as_bool(), k["classifier_version"].as_u64()), (Some(true), Some(1)));
    let doc = k["id"].as_str().unwrap();
    // stored in the build record
    let rec = lock(&svc.st).libs[0].books.iter().find(|b| b.doc_id == doc).cloned().unwrap();
    assert_eq!((rec.classifier_version, rec.unsure.as_deref(), rec.classified, rec.suggestions.len()), (Some(1), Some("low"), true, 3));
    // "Place it" offers them, best first, each with its probability and name; the three probabilities add up to 1
    let s = svc.suggestions(&lib, doc).unwrap();
    assert_eq!((s["unsorted"].as_bool(), s["classifier_version"].as_u64()), (Some(true), Some(1)));
    assert!(s["unsure_reason"].as_str().is_some_and(|m| !m.is_empty()));
    let list = s["suggestions"].as_array().unwrap();
    assert_eq!(list.len(), 3);
    let scores: Vec<f64> = list.iter().map(|x| x["score"].as_f64().unwrap()).collect();
    assert!(scores[0] >= scores[1] && scores[1] >= scores[2] && (scores.iter().sum::<f64>() - 1.0).abs() < 1e-4, "{scores:?}");
    let mut divs: Vec<&str> = list.iter().map(|x| x["division"].as_str().unwrap()).collect();
    divs.sort();
    assert_eq!(divs, vec!["510", "520", "710"]);
    assert!(list.iter().all(|x| x["name"].is_string() && x["class"].is_string()));
    // a filed book lists its three too, and says it is not in Unsorted
    let w = by_title(&books, "The Well Handbook")["id"].as_str().unwrap().to_string();
    let sw = svc.suggestions(&lib, &w).unwrap();
    assert_eq!((sw["unsorted"].as_bool(), sw["suggestions"][0]["division"].as_str()), (Some(false), Some("510")));
    assert!(sw["unsure_reason"].is_null());
    assert_eq!(svc.suggestions(&lib, "nope").unwrap_err().status, 404);
    // the choices survive a restart; the pack (what the search payloads are made of) carries none of it
    let (svc2, _) = rig(&d);
    assert_eq!(svc2.suggestions(&lib, doc).unwrap()["suggestions"].as_array().unwrap().len(), 3);
    let p = read_pack(&svc.packs_dir(&lib).join(format!("{doc}@1.cdoc"))).unwrap();
    let header = serde_json::to_string(&p.header).unwrap();
    assert!(!header.contains("classifier") && !header.contains("suggestions"), "{header}");
}

#[test]
fn every_placement_by_hand_is_logged_for_retraining_outside_the_search_data() {
    let d = TempDir::new("m3");
    small_classes(&d);
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "k.pdf", &book("kiln", 3, Some("Kiln Craft")));
    drain(&svc);
    let doc = svc.books(&lib).unwrap()[0]["id"].as_str().unwrap().to_string();
    let log = svc.corrections_path(&lib);
    assert!(!log.exists(), "the classifier's own filing is not a correction");
    svc.place_book(&lib, &doc, br#"{"division":"510","device":"  tablet 2 "}"#).unwrap();
    svc.place_book(&lib, &doc, br#"{"division":"520"}"#).unwrap();
    // refused placements are not logged
    assert!(svc.place_book(&lib, &doc, br#"{"division":"999"}"#).is_err());
    assert!(svc.place_book(&lib, "nope", br#"{"division":"510"}"#).is_err());
    svc.place_book(&lib, &doc, br#"{"division":"unsorted"}"#).unwrap();
    let text = std::fs::read_to_string(&log).unwrap();
    let rows: Vec<Value> = text.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    assert_eq!(rows.len(), 3, "{text}");
    let key = |r: &Value| (r["from"].as_str().unwrap().to_string(), r["to"].as_str().unwrap().to_string());
    assert_eq!(rows.iter().map(key).collect::<Vec<_>>(), vec![("unsorted".into(), "510".into()), ("510".into(), "520".into()), ("520".into(), "unsorted".into())]);
    assert!(rows.iter().all(|r| r["doc_id"] == json!(doc) && r["classifier_version"] == json!(1) && r["time"].as_str().is_some_and(|t| t.len() >= 20)));
    assert_eq!((rows[0]["device"].as_str(), rows[1]["device"].is_null()), (Some("tablet 2"), true));
    // it sits at the library's root beside packs/ and shard/, not in either, so no search payload carries it
    assert_eq!(log, svc.live_dir(&lib).join("corrections.jsonl"));
    assert!(!svc.packs_dir(&lib).join("corrections.jsonl").exists());
    svc.publish(&lib).unwrap();
    assert!(log.is_file());
    assert_eq!(live_docs(&svc, &lib), 1);
    let found = std::fs::read_dir(svc.live_dir(&lib).join("shard")).unwrap().flatten().count();
    assert!(found > 0);
    for e in std::fs::read_dir(svc.live_dir(&lib).join("shard")).unwrap().flatten() {
        assert_ne!(e.file_name().to_string_lossy(), "corrections.jsonl");
    }
    // it is appended to, never rewritten, and goes with the library
    svc.place_book(&lib, &doc, br#"{"division":"710"}"#).unwrap();
    assert_eq!(std::fs::read_to_string(&log).unwrap().lines().count(), 4);
    svc.delete_library(&lib).unwrap();
    assert!(!log.exists());
}

#[test]
fn the_same_book_in_a_better_file_replaces_the_old_one_and_a_worse_one_is_not_kept() {
    let d = TempDir::new("c6");
    small_classes(&d);
    tune(&d, json!({"same_cosine": 0.8}));
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "guide.pdf", &pdf_of("river", 1, 20, "River Guide"));
    drain(&svc);
    let b0 = svc.books(&lib).unwrap()[0].clone();
    let doc = b0["id"].as_str().unwrap().to_string();
    let call = b0["call_number"].as_str().unwrap().to_string();
    // a better file of it: more pages with text
    let better = pdf_of("river", 1, 21, "River Guide scan");
    let b = add(&svc, &lib, "guide scan.pdf", &better);
    drain(&svc);
    let ib = item(&svc, &b);
    assert_eq!((ib.state, ib.result.as_deref()), (S::Done, Some("Replaced: the new copy has 21 text pages vs 20")));
    let books = svc.books(&lib).unwrap();
    assert_eq!(books.as_array().unwrap().len(), 1);
    let nb = &books[0];
    assert_eq!((nb["id"].as_str(), nb["doc_version"].as_u64(), nb["title"].as_str(), nb["pages"].as_u64()), (Some(doc.as_str()), Some(2), Some("River Guide"), Some(21)));
    assert_eq!(nb["call_number"].as_str(), Some(call.as_str()), "the call number stays");
    assert_eq!(std::fs::read(svc.source_path(&lib, &doc)).unwrap(), better);
    assert!(svc.packs_dir(&lib).join(format!("{doc}@2.cdoc")).is_file() && !svc.packs_dir(&lib).join(format!("{doc}@1.cdoc")).exists());
    let r = svc.removed_view();
    assert_eq!((r["count"].as_u64(), r["items"][0]["kind"].as_str()), (Some(1), Some("source")));
    assert!(r["items"][0]["reason"].as_str().unwrap().starts_with("Replaced by a better copy: the new copy has 21 text pages vs 20"));
    // a worse file of it (fewer pages): not kept
    let c = add(&svc, &lib, "guide again.pdf", &pdf_of("river", 1, 20, "River Guide 3"));
    drain(&svc);
    let ic = item(&svc, &c);
    assert_eq!((ic.state, ic.result.as_deref(), ic.duplicate_of.as_deref()), (S::SkippedDuplicate, Some("Already have a better copy"), Some("River Guide")));
    assert_eq!(svc.books(&lib).unwrap().as_array().unwrap().len(), 1);
    assert_eq!(svc.removed_view()["count"], json!(2));
    assert_eq!(std::fs::read_dir(d.0.join("build/pending")).unwrap().count(), 0);
    // an excerpt is never the same book
    let e = add(&svc, &lib, "excerpt.pdf", &pdf_of("river", 1, 3, "River Excerpt"));
    drain(&svc);
    assert_eq!(state(&svc, &e), S::Done);
    assert_eq!(svc.books(&lib).unwrap().as_array().unwrap().len(), 2);
    // two different books on one topic are not the same
    let f = add(&svc, &lib, "other.pdf", &pdf_of("river", 100, 21, "Another River Book"));
    drain(&svc);
    assert_eq!(state(&svc, &f), S::Done);
    assert_eq!(svc.books(&lib).unwrap().as_array().unwrap().len(), 3);
}

/// Ten pages: the first eight about the river, the last two about `tail`.
fn edition_pdf(tail: &str) -> Vec<u8> {
    let mut pages: Vec<Page> = (1..=8).map(|i| text_page("river", i, 120)).collect();
    pages.push(text_page(tail, 9, 120));
    pages.push(text_page(tail, 10, 120));
    make_pdf(&pages, Some("Field Guide"))
}

#[test]
fn a_possible_new_edition_waits_for_a_choice_and_keep_both_adds_a_suffix() {
    let d = TempDir::new("c7");
    small_classes(&d);
    tune(&d, json!({"same_cosine": 0.5}));
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "guide.pdf", &edition_pdf("delta"));
    drain(&svc);
    let b = add(&svc, &lib, "guide 2nd.pdf", &edition_pdf("gamma"));
    assert!(matches!(svc.run_one(), Run::Ran));
    assert_eq!(state(&svc, &b), S::NeedsDecision);
    let it = item(&svc, &b);
    let dec = it.decision.clone().expect("a decision");
    assert_eq!((dec.other_title.as_str(), dec.new_title.as_str(), dec.new.pages, dec.old.pages), ("Field Guide", "Field Guide", 10, 10));
    assert!(dec.jaccard >= 0.5 && dec.jaccard < 0.85, "{}", dec.jaccard);
    let q = svc.queue();
    assert_eq!(q["counts"]["needs_decision"], json!(1));
    let qi = q["items"].as_array().unwrap().iter().find(|i| i["id"] == json!(b)).unwrap();
    assert_eq!((qi["state"].as_str(), qi["decision"]["old_title"].as_str(), qi["decision"]["summary"]["pages"]["new"].as_u64()), (Some("needs_decision"), Some("Field Guide"), Some(10)));
    assert_eq!(qi["decision"]["actions"], json!(["keep_both", "replace_older"]));
    // nothing was added, nothing moved or removed; the file waits where it is
    assert_eq!(svc.books(&lib).unwrap().as_array().unwrap().len(), 1);
    assert_eq!(svc.removed_view()["count"], json!(0));
    assert!(Path::new(&it.path).is_file());
    assert!(matches!(svc.run_one(), Run::Idle), "it is not built again while it waits");
    // the choice
    assert_eq!(svc.decide(&b, br#"{"action":"nope"}"#).unwrap_err().status, 400);
    assert_eq!(svc.decide("nope", br#"{"action":"keep_both"}"#).unwrap_err().status, 404);
    svc.decide(&b, br#"{"action":"keep_both"}"#).unwrap();
    assert_eq!(state(&svc, &b), S::Queued);
    assert_eq!(svc.decide(&b, br#"{"action":"keep_both"}"#).unwrap_err().status, 409);
    drain(&svc);
    assert_eq!(state(&svc, &b), S::Done);
    let books = svc.books(&lib).unwrap();
    assert_eq!(books.as_array().unwrap().len(), 2);
    let mut calls: Vec<String> = books.as_array().unwrap().iter().map(|x| x["call_number"].as_str().unwrap().to_string()).collect();
    calls.sort_by_key(|c| c.len());
    assert!(calls[0].ends_with("FIE") && calls[1].ends_with("FIE 2e"), "{calls:?}");
    let files = tree_files(&d.0.join("app/docs/sources").join(&lib));
    assert!(files.iter().any(|f| f.ends_with("FIE 2e  Field Guide.pdf")) && files.iter().any(|f| f.ends_with("FIE  Field Guide.pdf")), "{files:?}");
    assert_eq!(svc.removed_view()["count"], json!(0), "keep both removes nothing");
}

#[test]
fn replace_the_older_one_goes_first_in_the_queue_and_the_old_copy_goes_to_removed() {
    let d = TempDir::new("c8");
    small_classes(&d);
    tune(&d, json!({"same_cosine": 0.5}));
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    add(&svc, &lib, "guide.pdf", &edition_pdf("delta"));
    drain(&svc);
    let old_doc = svc.books(&lib).unwrap()[0]["id"].as_str().unwrap().to_string();
    let b = add(&svc, &lib, "guide 2nd.pdf", &edition_pdf("gamma"));
    assert!(matches!(svc.run_one(), Run::Ran));
    assert_eq!(state(&svc, &b), S::NeedsDecision);
    let other = add(&svc, &lib, "tank.pdf", &book("tank", 2, Some("Tanks")));
    // the other book was queued ahead of it
    {
        let mut st = lock(&svc.st);
        let (i, j) = (st.items.iter().position(|x| x.id == b).unwrap(), st.items.iter().position(|x| x.id == other).unwrap());
        st.items.swap(i, j);
    }
    svc.decide(&b, br#"{"action":"replace_older"}"#).unwrap();
    let order: Vec<String> = lock(&svc.st).items.iter().map(|i| i.id.clone()).collect();
    let (pb, po) = (order.iter().position(|x| *x == b).unwrap(), order.iter().position(|x| *x == other).unwrap());
    assert!(pb < po, "the rebuild goes to the front of the queue: {order:?}");
    drain(&svc);
    let ib = item(&svc, &b);
    assert_eq!((ib.state, ib.result.as_deref()), (S::Done, Some("Replaced: the older edition was replaced at your choice")));
    let books = svc.books(&lib).unwrap();
    assert_eq!(books.as_array().unwrap().len(), 2);
    let nb = by_title(&books, "Field Guide");
    assert_eq!((nb["id"].as_str(), nb["doc_version"].as_u64()), (Some(old_doc.as_str()), Some(2)));
    assert_eq!(svc.removed_view()["count"], json!(1));
    // a choice for a book that is not waiting
    assert_eq!(svc.decide(&b, br#"{"action":"replace_older"}"#).unwrap_err().status, 409);
}

#[test]
fn drop_folder_results_say_replaced_or_already_have_a_better_copy_and_a_restore_is_looked_at_again() {
    let d = TempDir::new("c9");
    small_classes(&d);
    tune(&d, json!({"same_cosine": 0.8}));
    let (svc, _, _, root) = drop_rig(&d, 0);
    put(&root, "ingest", "a.pdf", &pdf_of("river", 1, 20, "River Guide"));
    svc.scan();
    drain(&svc);
    assert_eq!(tree_files(&root.join("complete")).len(), 1);
    // a better copy: the book is rebuilt from it, the old copies go to Removed
    put(&root, "ingest", "b.pdf", &pdf_of("river", 1, 21, "River Guide v2"));
    svc.scan();
    drain(&svc);
    let tree = tree_files(&root.join("complete"));
    assert_eq!(tree.len(), 1, "{tree:?}");
    let v = svc.drop_view();
    let row = v["files"].as_array().unwrap().iter().find(|f| f["folder"] == json!("complete")).unwrap();
    assert_eq!(row["reason"], json!("Replaced: the new copy has 21 text pages vs 20"));
    let r = svc.removed_view();
    let mut kinds: Vec<&str> = r["items"].as_array().unwrap().iter().map(|i| i["kind"].as_str().unwrap()).collect();
    kinds.sort();
    assert_eq!(kinds, vec!["drop", "source"]);
    // a worse copy
    put(&root, "ingest", "c.pdf", &pdf_of("river", 1, 20, "River Guide again"));
    svc.scan();
    drain(&svc);
    assert_eq!(names(&root, "ingest"), Vec::<String>::new());
    assert_eq!(tree_files(&root.join("complete")).len(), 1);
    assert_eq!(svc.removed_view()["count"], json!(3));
    let v = svc.drop_view();
    let gone = v["files"].as_array().unwrap().iter().find(|f| f["folder"] == json!("removed")).expect("a removed row");
    assert_eq!((gone["name"].as_str(), gone["reason"].as_str()), (Some("c.pdf"), Some("Already have a better copy")));
    assert_eq!(v["status"]["counts"]["removed"], json!(1));
    // restore puts it back in ingest/; it is compared again and ends the same way
    let id = svc.removed_view()["items"].as_array().unwrap().iter().find(|i| i["reason"] == json!("Already have a better copy")).unwrap()["id"].as_str().unwrap().to_string();
    svc.restore_removed(&id).unwrap();
    assert_eq!(names(&root, "ingest"), vec!["c.pdf"]);
    assert_eq!(svc.removed_view()["count"], json!(2));
    svc.scan();
    drain(&svc);
    assert_eq!(names(&root, "ingest"), Vec::<String>::new());
    assert_eq!(svc.removed_view()["count"], json!(3));
    assert!(svc.removed_view()["items"].as_array().unwrap().iter().filter(|i| i["reason"] == json!("Already have a better copy")).count() == 1);
}

#[test]
fn removed_files_are_listed_restored_deleted_and_purged_after_thirty_days() {
    let d = TempDir::new("c10");
    let (svc, _) = rig(&d);
    let lib = new_lib(&svc, "L");
    let pdf = book("river", 2, Some("River"));
    add(&svc, &lib, "river.pdf", &pdf);
    add(&svc, &lib, "copy.pdf", &pdf);
    drain(&svc);
    let r = svc.removed_view();
    assert_eq!((r["count"].as_u64(), r["items"][0]["file"].as_str(), r["items"][0]["reason"].as_str(), r["items"][0]["kind"].as_str()), (Some(1), Some("copy.pdf"), Some("Exact copy of River"), Some("upload")));
    let id = r["items"][0]["id"].as_str().unwrap().to_string();
    assert!(d.0.join("build/removed/files").join(format!("{id}.pdf")).is_file());
    assert_eq!(svc.restore_removed("nope").unwrap_err().status, 404);
    // restore: the drop folder's ingest/
    let out = svc.restore_removed(&id).unwrap();
    assert_eq!(out["file"], json!("copy.pdf"));
    assert_eq!(std::fs::read(d.0.join("drop/ingest/copy.pdf")).unwrap(), pdf);
    assert_eq!(svc.removed_view()["count"], json!(0));
    assert_eq!(svc.restore_removed(&id).unwrap_err().status, 404);
    // the purge
    add(&svc, &lib, "copy2.pdf", &pdf);
    drain(&svc);
    assert_eq!(svc.removed_view()["count"], json!(1));
    assert_eq!(svc.purge_removed(epoch()), 0);
    assert_eq!(svc.purge_removed(epoch() + 29 * 24 * 3600), 0);
    assert_eq!(svc.purge_removed(epoch() + 31 * 24 * 3600), 1);
    assert_eq!(svc.removed_view()["count"], json!(0));
    assert_eq!(std::fs::read_dir(d.0.join("build/removed/files")).unwrap().count(), 0);
    // at start-up
    add(&svc, &lib, "copy3.pdf", &pdf);
    drain(&svc);
    assert_eq!(svc.removed_view()["count"], json!(1));
    let manifest = d.0.join("build/removed/manifest.json");
    let mut m: Value = serde_json::from_slice(&std::fs::read(&manifest).unwrap()).unwrap();
    m[0]["epoch"] = json!(1);
    std::fs::write(&manifest, m.to_string()).unwrap();
    let (svc2, _) = rig(&d);
    assert_eq!(svc2.removed_view()["count"], json!(0));
    assert_eq!(std::fs::read_dir(d.0.join("build/removed/files")).unwrap().count(), 0);
    // delete for good
    add(&svc2, &lib, "copy4.pdf", &pdf);
    drain(&svc2);
    assert_eq!(svc2.delete_removed("nope").unwrap_err().status, 404);
    assert_eq!(svc2.delete_removed("").unwrap()["deleted"], json!(1));
    assert_eq!(svc2.removed_view()["count"], json!(0));
}
