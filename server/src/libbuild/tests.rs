//! Tests of the build service: the queue, the library swap, the drop folder. The embedder is the builder crate's fake.

use super::dropdir::unique_name;
use super::testpdf::{book, make_pdf, picture_page, text_page};
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
    *lock(&fake.hook) = Some(Box::new(move || {
        let v = s2.stop();
        assert_eq!(v["removed"], json!(3));
    }));
    assert!(matches!(svc.run_one(), Run::Ran));
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
    let seen: Arc<Mutex<Vec<(bool, Option<usize>)>>> = Arc::new(Mutex::new(vec![]));
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
    let complete = names(&root, "complete");
    assert_eq!(complete.len(), 2, "{complete:?}");
    let failed = names(&root, "failed");
    assert_eq!(failed, vec!["Scan.PDF", "Scan.PDF.why.txt", "broken.pdf", "broken.pdf.why.txt"]);
    assert!(!std::fs::read_to_string(root.join("failed/broken.pdf.why.txt")).unwrap().trim().is_empty());
    assert!(std::fs::read_to_string(root.join("failed/Scan.PDF.why.txt")).unwrap().contains("OCR"));
    // the table says why
    let v = svc.drop_view();
    let files = v["files"].as_array().unwrap();
    let dup = files.iter().find(|f| f["folder"] == json!("complete") && f["state"] == json!("duplicate")).expect("a duplicate");
    assert_eq!(dup["reason"], json!("Duplicate: the same content is already in Spring"));
    let broken = files.iter().find(|f| f["name"] == json!("broken.pdf")).unwrap();
    assert_eq!((broken["state"].as_str(), broken["can_retry"].as_bool()), (Some("failed"), Some(true)));
    assert_eq!(v["status"]["counts"]["complete"], json!(2));
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
    assert_eq!(names(&root, "complete"), vec!["kit.cache-library", "kit2.tar.gz", "wiki.zim"]);
    assert_eq!(names(&root, "failed"), vec!["fake.gz", "fake.gz.why.txt", "notes.txt", "notes.txt.why.txt"]);
    assert_eq!(std::fs::read_to_string(root.join("failed/notes.txt.why.txt")).unwrap().trim(), "Not a file Cache can use");
    assert_eq!(std::fs::read_to_string(root.join("failed/fake.gz.why.txt")).unwrap().trim(), "Not a file Cache can use");
    assert_eq!(names(&root, "ingest"), vec![".hidden.pdf"], "hidden files are left alone");
    // installed where an upload would put them
    assert_eq!(std::fs::read(d.0.join("app/docs/zims/wiki.zim")).unwrap(), b"ZIMDATA");
    assert_eq!(std::fs::read(d.0.join("app/docs/incoming/kit.cache-library")).unwrap(), b"LIBDATA");
    assert!(d.0.join("app/docs/incoming/kit2.tar.gz").is_file());
    // the copies in complete/ are the files themselves
    assert_eq!(std::fs::read(root.join("complete/wiki.zim")).unwrap(), b"ZIMDATA");
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
    assert_eq!(names(&root, "complete"), vec!["wiki (2).zim", "wiki.zim"]);
    assert_eq!(unique_name(&root.join("complete"), "none"), "none");
    assert_eq!(unique_name(&root.join("complete"), "wiki.zim"), "wiki (3).zim");
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
    assert_eq!(names(&root, "complete"), vec!["b.pdf"]);
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
