//! OCR of scanned pages (Tesseract, built into MuPDF), through the real crash-proof child (`cache-build extract-pdf`).
//! The scanned pages are generated here: a page of text is drawn to a 300 dpi gray bitmap that becomes the whole page, so the PDF has no
//! text layer. Needs `eng.traineddata`: CACHE_TESSDATA_DIR names its folder (the Linux workflows set it, and CACHE_REQUIRE_OCR_TESTS=1
//! turns a missing file into a failure); elsewhere these tests say so and pass.

mod common;

use cache_builder::build::build_pack_with_extractor;
use cache_builder::embed::FakeEmbedder;
use cache_builder::extract::extract_pdf;
use cache_builder::isolate::ChildExtractor;
use cache_builder::ocr::{OcrSettings, OCR_ENGINE, OCR_VERSION};
use cache_builder::pack::Pack;
use cache_builder::BuildOptions;
use common::*;
use std::path::PathBuf;
use std::time::Instant;

const STAMP: &str = "2026-11-10T00:00:00Z";

fn settings() -> Option<OcrSettings> {
    std::env::set_var("CACHE_OCR_DEBUG", "1");
    let s = OcrSettings::discover();
    if s.is_none() {
        assert!(std::env::var_os("CACHE_REQUIRE_OCR_TESTS").is_none(), "CACHE_REQUIRE_OCR_TESTS is set but there is no eng.traineddata (CACHE_TESSDATA_DIR)");
        eprintln!("skipped: no eng.traineddata (set CACHE_TESSDATA_DIR)");
    }
    s
}

fn child(tag: &str) -> (ChildExtractor, PathBuf) {
    let tmp = std::env::temp_dir().join(format!("cache-ocr-{tag}-{}", std::process::id()));
    let mut e = ChildExtractor::current_exe(tmp.clone());
    e.exe = PathBuf::from(env!("CARGO_BIN_EXE_cache-build"));
    (e, tmp)
}

fn lines(topic: usize) -> Vec<String> {
    sample_lines(topic)
}

fn build(pdf: &[u8], e: &ChildExtractor, s: Option<&OcrSettings>) -> Result<Pack, String> {
    let extract = |b: &[u8]| e.extract_with_ocr(b, s, &mut |_, _| {});
    build_pack_with_extractor(pdf, &BuildOptions::new("book.pdf", STAMP), &FakeEmbedder, &mut |_| {}, &extract).map(|(p, _)| p).map_err(|e| e.to_string())
}

fn text_of(p: &Pack, pdf_page: u32) -> String {
    p.pieces.iter().filter(|x| x.pdf_page.is_some_and(|a| a <= pdf_page) && pdf_page <= x.pdf_page_end.or(x.pdf_page).unwrap_or(0)).map(|x| x.text.to_lowercase()).collect::<Vec<_>>().join(" ")
}

#[test]
fn a_scanned_page_ends_searchable_and_the_book_keeps_its_identity() {
    let Some(s) = settings() else { return };
    let (e, tmp) = child("scan");
    let pdf = make_mixed_pdf(&[Mixed::Scan(lines(0))]);
    // it really has no text layer
    let plain = extract_pdf(&pdf).unwrap();
    assert_eq!(plain.pages[0].text_chars(), 0);
    assert_eq!(plain.pages[0].images, 1);
    // without OCR it is a scan nobody can search
    assert!(build(&pdf, &e, None).is_err());
    let t0 = Instant::now();
    let pack = build(&pdf, &e, Some(&s)).expect("a scanned PDF builds with OCR");
    eprintln!("OCR-MEASURE one page, child included: {:.2}s", t0.elapsed().as_secs_f32());
    let words = text_of(&pack, 1);
    for w in ["rainwater", "mosquitoes", "reservoir", "irrigation", "valley", "water table"] {
        assert!(words.contains(w), "OCR text lacks {w:?}: {words}");
    }
    // marked as OCR text, recorded, and nothing is left that still needs OCR
    assert_eq!(pack.header.text_source_ocr_pages, vec![1]);
    assert!(pack.header.ocr_pages.is_empty());
    let o = pack.header.book.as_ref().unwrap().ocr.clone().expect("book.ocr");
    assert_eq!((o.engine.as_str(), o.version.as_str(), o.pages_ocrd), (OCR_ENGINE, OCR_VERSION, 1));
    // the book is still the file as it arrived: same hash in the source and as the original
    let h = blake3::hash(&pdf).to_hex().to_string();
    assert_eq!(pack.header.source.blake3, h);
    assert_eq!(pack.header.book.as_ref().unwrap().original_blake3, h);
    assert_eq!(pack.header.source.size, pdf.len() as u64);
    // the work folder is gone
    assert_eq!(std::fs::read_dir(&tmp).map(|d| d.count()).unwrap_or(0), 0);
    let _ = std::fs::remove_dir_all(&tmp);
}

#[test]
fn a_mixed_pdf_only_has_its_scanned_pages_read_by_ocr() {
    let Some(s) = settings() else { return };
    let (e, tmp) = child("mixed");
    let pdf = make_mixed_pdf(&[Mixed::Text(lines(1)), Mixed::Scan(lines(0)), Mixed::Text(lines(2)), Mixed::Scan(lines(1))]);
    let mut seen = Vec::new();
    let mut extract = |b: &[u8]| e.extract_with_ocr(b, Some(&s), &mut |done, total| seen.push((done, total)));
    let ext = extract(&pdf).unwrap();
    // pages 2 and 4 (0-based 1 and 3) were read by OCR; the text pages keep the PDF's own text, exactly as a plain read gives it
    assert_eq!(ext.ocr_pages, vec![1, 3]);
    let plain = extract_pdf(&pdf).unwrap();
    assert_eq!(ext.pages[0], plain.pages[0]);
    assert_eq!(ext.pages[2], plain.pages[2]);
    assert!(ext.pages[1].text_chars() > 100 && ext.pages[3].text_chars() > 100);
    assert_eq!(seen.first(), Some(&(0, 2)));
    assert_eq!(seen.last(), Some(&(2, 2)));
    let pack = build(&pdf, &e, Some(&s)).expect("builds");
    assert_eq!(pack.header.text_source_ocr_pages, vec![2, 4]);
    assert!(pack.header.ocr_pages.is_empty());
    assert_eq!(pack.header.book.as_ref().unwrap().ocr.as_ref().unwrap().pages_ocrd, 2);
    // the right words are on the right pages
    assert!(text_of(&pack, 1).contains("bread"), "{}", text_of(&pack, 1));
    assert!(text_of(&pack, 2).contains("reservoir"), "{}", text_of(&pack, 2));
    assert!(text_of(&pack, 3).contains("mountain") || text_of(&pack, 3).contains("hikers"), "{}", text_of(&pack, 3));
    assert!(text_of(&pack, 4).contains("bread") || text_of(&pack, 4).contains("baker"), "{}", text_of(&pack, 4));
    assert_eq!(pack.header.source.blake3, blake3::hash(&pdf).to_hex().to_string());
    let _ = std::fs::remove_dir_all(&tmp);
}

#[test]
fn a_pdf_with_only_text_is_read_without_ocr_and_has_no_ocr_record() {
    let Some(s) = settings() else { return };
    let (e, tmp) = child("text");
    let pdf = make_mixed_pdf(&[Mixed::Text(lines(1)), Mixed::Text(lines(2))]);
    let mut calls = 0;
    let ext = e.extract_with_ocr(&pdf, Some(&s), &mut |_, _| calls += 1).unwrap();
    assert_eq!((calls, ext.ocr_pages.len()), (0, 0));
    let pack = build(&pdf, &e, Some(&s)).unwrap();
    assert!(pack.header.text_source_ocr_pages.is_empty());
    assert!(pack.header.book.as_ref().unwrap().ocr.is_none());
    let _ = std::fs::remove_dir_all(&tmp);
}

/// Prints the time OCR takes per page here (the Linux workflows copy the line into the run summary).
#[test]
fn ocr_speed_per_page() {
    let Some(s) = settings() else { return };
    let (e, tmp) = child("speed");
    let pages: Vec<Mixed> = (0..10).map(|i| Mixed::Scan(lines(i))).collect();
    let pdf = make_mixed_pdf(&pages);
    let t0 = Instant::now();
    let ext = e.extract_with_ocr(&pdf, Some(&s), &mut |_, _| {}).unwrap();
    let secs = t0.elapsed().as_secs_f32();
    assert_eq!(ext.ocr_pages.len(), 10);
    eprintln!("OCR-MEASURE pages=10 total={secs:.2}s per_page={:.2}s (300 dpi, eng fast model, one child per 5 pages, includes reading the PDF)", secs / 10.0);
    let _ = std::fs::remove_dir_all(&tmp);
}

/// The same OCR without the child: shows the error, if there is one, instead of a page with no text.
#[test]
fn ocr_in_this_process_reads_a_scanned_page() {
    let Some(s) = settings() else { return };
    let tmp = std::env::temp_dir().join(format!("cache-ocr-inproc-{}", std::process::id()));
    std::fs::create_dir_all(&tmp).unwrap();
    let pdf = make_mixed_pdf(&[Mixed::Scan(lines(0))]);
    let read = cache_builder::ocr::ocr_pages(&pdf, &[0], &s, &tmp).unwrap_or_else(|e| panic!("OCR failed: {e}"));
    let _ = std::fs::remove_dir_all(&tmp);
    assert_eq!(read.len(), 1);
    let text: String = read[0].blocks.iter().flat_map(|b| b.lines.iter().map(|l| l.text.clone())).collect::<Vec<_>>().join(" ");
    assert!(text.to_lowercase().contains("reservoir"), "OCR text: {text:?}");
}
