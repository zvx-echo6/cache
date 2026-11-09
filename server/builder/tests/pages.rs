//! The shared pack writer: pages (blocks in reading order, from any source) become a pack. `cache-build pdf` goes through the same
//! writer after its layout step, so the same pages give the same passages wherever they were made. PDFs are generated at test time.

mod common;

use cache_builder::build::{build_pack, pages_of, BuildOptions};
use cache_builder::embed::FakeEmbedder;
use cache_builder::extract::extract_pdf;
use cache_builder::layout::{layout, LAYOUT_VERSION};
use cache_builder::pack::{pack_bytes, read_header, read_pack, read_pack_bytes, write_pack, Pack, Tool};
use cache_builder::pagewriter::{build_pack_from_pages, normalize_pages, pages_json, parse_pages, BlockKind, PageBlock, PageIn, PagesSource, TextSource};
use common::*;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::Path;
use std::process::Command;

const STAMP: &str = "2026-11-01T00:00:00Z";

fn cli() -> Command {
    Command::new(env!("CARGO_BIN_EXE_cache-build"))
}

/// Three pages with a bold heading, body text and a short italic line (a pull-quote).
fn headed_book() -> Vec<u8> {
    let body = wrap(&"Ordinary text runs along the page in the regular face for many lines and ends each sentence. ".repeat(30), 70);
    let body: Vec<&str> = body.iter().map(|s| s.as_str()).collect();
    let mut pages = Vec::new();
    for name in ["Water Purification Handbook", "Boiling and Filters", "Chlorine Doses"] {
        let mut p = Page::new();
        p.line(45.0, 40.0, 20.0, Font::Bold, name);
        p.line(60.0, 70.0, 10.0, Font::Italic, "\"Clean water first.\"");
        p.block(45.0, 100.0, 10.0, Font::Regular, &body[..12]);
        pages.push(p);
    }
    make_pdf(&pages, Some("The Metadata Title"))
}

fn token(n: usize) -> String {
    format!("{n:05}")
}

/// A column of `lines` lines of `per` numbered tokens at `x`.
fn column(p: &mut Page, x: f32, y: f32, first: usize, lines: usize, per: usize) {
    for k in 0..lines {
        let t: Vec<String> = (0..per).map(|j| token(first + k * per + j)).collect();
        p.line(x, y + 12.0 * k as f32, 10.0, Font::Regular, &t.join(" "));
    }
}

/// Three narrow columns on one page, then a page of two columns, as the column tests generate them.
fn column_book() -> Vec<u8> {
    let mut p = Page::new();
    for c in 0..3 {
        column(&mut p, 30.0 + 98.0 * c as f32, 100.0, c * 42, 14, 3);
    }
    let mut q = Page::new();
    q.line(30.0, 40.0, 14.0, Font::Bold, "Two columns");
    column(&mut q, 30.0, 100.0, 200, 14, 3);
    column(&mut q, 230.0, 100.0, 242, 14, 3);
    make_pdf(&[p, q], None)
}

fn pdf_pack(pdf: &[u8]) -> Pack {
    build_pack(pdf, &BuildOptions::new("book.pdf", STAMP), &FakeEmbedder).expect("build").0
}

/// The pages the layout step makes of the PDF, through JSON and back (what `cache-build pages` writes and `pack` reads).
fn dumped(pdf: &[u8]) -> (PagesSource, Vec<PageIn>) {
    let ext = extract_pdf(pdf).unwrap();
    let lay = layout(&ext);
    let (src, pages) = pages_of(&ext, &lay, pdf, "book.pdf");
    let mut back = parse_pages(&pages_json(&pages).unwrap()).unwrap();
    assert_eq!(back, pages, "pages.json round-trips");
    normalize_pages(&mut back);
    assert_eq!(back, pages, "text the layout step made is already normal");
    (src, back)
}

fn same_pack_from_pages(pdf: &[u8]) {
    let from_pdf = pdf_pack(pdf);
    let (src, pages) = dumped(pdf);
    let (from_pages, _) = build_pack_from_pages(&src, &pages, &BuildOptions::new("book.pdf", STAMP), &FakeEmbedder, &mut |_| {}).unwrap();
    assert!(!from_pdf.pieces.is_empty());
    assert_eq!(from_pages.pieces, from_pdf.pieces, "the same pieces");
    assert_eq!(from_pages, from_pdf, "and the same pack");
    assert_eq!(pack_bytes(&from_pages).unwrap(), pack_bytes(&from_pdf).unwrap());
    // the pdf path records the layout version beside the extractor
    assert_eq!(from_pdf.header.extractor.layout_version, Some(LAYOUT_VERSION));
}

#[test]
fn the_same_pages_through_pack_and_pdf_give_identical_pieces() {
    for pdf in [headed_book(), column_book()] {
        same_pack_from_pages(&pdf);
    }
}

#[test]
fn the_pages_dumped_to_a_file_and_read_by_the_pack_command_give_the_pdf_commands_pieces() {
    let tmp = tempfile::tempdir().unwrap();
    for (n, pdf) in [headed_book(), column_book()].iter().enumerate() {
        let pdf_path = tmp.path().join(format!("book{n}.pdf"));
        std::fs::write(&pdf_path, pdf).unwrap();
        let (a, b, pages_file) = (tmp.path().join(format!("a{n}")), tmp.path().join(format!("b{n}")), tmp.path().join(format!("pages{n}.json")));
        let out = cli().arg("pdf").arg(pdf_path.as_path()).arg("--out").arg(a.as_path()).args(["--fake-embedder", "--in-process", "--created-at", STAMP]).output().unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        let out = cli().arg("pages").arg(pdf_path.as_path()).arg("--out").arg(pages_file.as_path()).output().unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        let shape: Value = serde_json::from_slice(&std::fs::read(&pages_file).unwrap()).unwrap();
        assert_eq!(shape[0]["pdf_page"], json!(1));
        assert_eq!(shape[0]["text_source"], json!("layer"));
        assert!(shape[0]["blocks"][0]["text"].is_string() && shape[0]["blocks"][0]["kind"].is_string());
        let out = cli()
            .arg("pack")
            .arg("--pages")
            .arg(pages_file.as_path())
            .arg("--out")
            .arg(b.as_path())
            .arg("--source")
            .arg(pdf_path.as_path())
            .args(["--fake-embedder", "--created-at", STAMP])
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
        let one = |d: &Path| {
            let f = std::fs::read_dir(d).unwrap().next().unwrap().unwrap().path();
            read_pack(&f).unwrap()
        };
        let (pa, pb) = (one(&a), one(&b));
        assert!(!pa.pieces.is_empty());
        assert_eq!(pb.pieces, pa.pieces, "pack and pdf make the same pieces from the same pages");
        assert_eq!(pb.header.doc_id, pa.header.doc_id);
        assert_eq!(pb.header.page_count, pa.header.page_count);
        // pdf records the layout version; pack records the producer's extractor and no layout version unless told
        assert_eq!(pa.header.extractor.layout_version, Some(LAYOUT_VERSION));
        assert_eq!((pb.header.extractor.name.as_str(), pb.header.extractor.layout_version), ("pages", None));
    }
}

fn page(n: usize, text: &str, source: TextSource) -> PageIn {
    PageIn { pdf_page: n, label: n.to_string(), text_source: source, blocks: vec![PageBlock { text: text.into(), kind: BlockKind::Body, level: None, bullet: false }] }
}

fn sentence_page(n: usize) -> String {
    (0..14).map(|k| format!("Sentence {k} of page {n} is about the water that moves through the ground and the roots of trees.")).collect::<Vec<_>>().join(" ")
}

fn plain_source() -> PagesSource {
    PagesSource {
        blake3: "ab".repeat(32),
        size: 1000,
        file_name: "scan.pdf".into(),
        extractor: Tool { name: "vision".into(), version: "1".into(), layout_version: None },
        meta_title: None,
        ppi: Some(150),
        year: None,
        page_count: 0,
        ocr_pages: None,
        text_pages: None,
    }
}

#[test]
fn one_body_block_per_page_is_the_simplest_input_and_chunks_like_the_phones_plain_text() {
    let texts: Vec<String> = (1..=4).map(sentence_page).collect();
    let pages: Vec<PageIn> = texts.iter().enumerate().map(|(i, t)| page(i + 1, t, TextSource::Ocr)).collect();
    let mut o = BuildOptions::new("scan.pdf", STAMP);
    o.ocr = Some(cache_builder::pack::OcrInfo { engine: "apple-vision".into(), version: "17".into(), pages_ocrd: 4, confidence: None });
    let (pack, report) = build_pack_from_pages(&plain_source(), &pages, &o, &FakeEmbedder, &mut |_| {}).unwrap();
    assert_eq!((report.pages, report.text_pages, report.ocr_pages.len()), (4, 4, 0));
    assert!(pack.pieces.len() >= 4);
    // the text source of every page and the OCR record travel in the pack
    assert_eq!(pack.header.text_source_ocr_pages, vec![1, 2, 3, 4]);
    let book = pack.header.book.as_ref().unwrap();
    assert_eq!(book.ocr.as_ref().map(|o| (o.engine.as_str(), o.pages_ocrd)), Some(("apple-vision", 4)));
    assert_eq!((pack.header.extractor.name.as_str(), pack.header.extractor.layout_version), ("vision", None));
    // the shared chunker's plain-text path (what a phone uses) cuts the same passages
    let input: Vec<cache_chunk::PageInput> = texts.iter().enumerate().map(|(i, t)| cache_chunk::PageInput { index: i, label: (i + 1).to_string(), text: t.clone() }).collect();
    let chunked = cache_chunk::chunk_pages(&input);
    assert_eq!(chunked.pieces.len(), pack.pieces.len());
    for (a, b) in chunked.pieces.iter().zip(&pack.pieces) {
        assert_eq!((a.text.as_str(), a.page.as_str(), Some(a.pdf_page as u32)), (b.text.as_str(), b.page.as_str(), b.pdf_page));
    }
    // a written pack reads back equal, with text_source in the header (absent when every page is the text layer)
    let bytes = pack_bytes(&pack).unwrap();
    assert_eq!(read_pack_bytes(&bytes).unwrap(), pack);
    let mut s = String::new();
    flate2::read::GzDecoder::new(&bytes[..]).read_to_string(&mut s).unwrap();
    let h: Value = serde_json::from_str(s.lines().next().unwrap()).unwrap();
    assert_eq!(h["text_source_ocr_pages"], json!([1, 2, 3, 4]));
    let layer: Vec<PageIn> = texts.iter().enumerate().map(|(i, t)| page(i + 1, t, TextSource::Layer)).collect();
    let (plain, _) = build_pack_from_pages(&plain_source(), &layer, &BuildOptions::new("scan.pdf", STAMP), &FakeEmbedder, &mut |_| {}).unwrap();
    let mut s = String::new();
    flate2::read::GzDecoder::new(&pack_bytes(&plain).unwrap()[..]).read_to_string(&mut s).unwrap();
    assert!(!s.lines().next().unwrap().contains("text_source_ocr_pages"));
    assert_eq!(plain.pieces, pack.pieces, "the text source does not change the passages");
}

#[test]
fn the_pack_command_takes_ocr_pages_from_a_file_and_needs_the_ocr_record() {
    let tmp = tempfile::tempdir().unwrap();
    let pages: Vec<PageIn> = (1..=3).map(|n| page(n, &sentence_page(n), TextSource::Ocr)).collect();
    let f = tmp.path().join("pages.json");
    std::fs::write(&f, pages_json(&pages).unwrap()).unwrap();
    let out_dir = tmp.path().join("packs");
    let hash = "cd".repeat(32);
    let run = |extra: &[&str]| {
        cli()
            .arg("pack")
            .arg("--pages")
            .arg(f.as_path())
            .arg("--out")
            .arg(out_dir.as_path())
            .args(["--fake-embedder", "--created-at", STAMP, "--doc-id", "scan1", "--source-blake3", hash.as_str(), "--source-size", "1234", "--file-name", "scan.pdf"])
            .args(extra)
            .output()
            .unwrap()
    };
    // pages read by OCR with no OCR record: refused before anything is written
    let out = run(&[]);
    assert_eq!(out.status.code(), Some(2), "{}", String::from_utf8_lossy(&out.stderr));
    assert!(!out_dir.exists());
    let out = run(&["--ocr-engine", "ml-kit", "--ocr-version", "16.0", "--layout-version", "1", "--extractor-name", "pdfrx", "--extractor-version", "2"]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let h = read_header(&out_dir.join("scan1@1.cdoc")).unwrap();
    assert_eq!(h.text_source_ocr_pages, vec![1, 2, 3]);
    let ocr = h.book.as_ref().unwrap().ocr.clone().unwrap();
    assert_eq!((ocr.engine.as_str(), ocr.version.as_str(), ocr.pages_ocrd), ("ml-kit", "16.0", 3));
    assert_eq!((h.extractor.name.as_str(), h.extractor.version.as_str(), h.extractor.layout_version), ("pdfrx", "2", Some(1)));
    assert_eq!((h.source.blake3.as_str(), h.source.size, h.source.file_name.as_str()), ("cd".repeat(32).as_str(), 1234, "scan.pdf"));
    assert_eq!(h.book.as_ref().unwrap().original_blake3, "cd".repeat(32));
    // no source given: refused
    let out = cli().arg("pack").arg("--pages").arg(f.as_path()).arg("--out").arg(tmp.path().join("x")).arg("--fake-embedder").output().unwrap();
    assert_eq!(out.status.code(), Some(2));
}

#[test]
fn pages_that_cannot_be_written_are_refused() {
    let src = plain_source();
    let o = BuildOptions::new("scan.pdf", STAMP);
    let build = |pages: Vec<PageIn>| build_pack_from_pages(&src, &pages, &o, &FakeEmbedder, &mut |_| {});
    let ok = page(1, &sentence_page(1), TextSource::Layer);
    assert!(build(vec![ok.clone()]).is_ok());
    assert!(build(vec![PageIn { pdf_page: 0, ..ok.clone() }]).unwrap_err().0.contains("starts at 1"));
    assert!(build(vec![ok.clone(), ok.clone()]).unwrap_err().0.contains("twice"));
    let mut bad = ok.clone();
    bad.blocks.push(PageBlock { text: "Heading".into(), kind: BlockKind::Heading, level: Some(0), bullet: false });
    assert!(build(vec![bad]).unwrap_err().0.contains("level"));
    // no text at all
    let empty = PageIn { blocks: vec![], ..ok };
    assert!(build(vec![empty]).unwrap_err().0.contains("no text"));
    // the json shape: kind and text_source are words, level and bullet are optional, unknown words are refused
    let p = parse_pages(r#"[{"pdf_page":2,"blocks":[{"text":"A heading","kind":"heading","level":2},{"text":"- item","kind":"aside","bullet":true}]}]"#).unwrap();
    assert_eq!((p[0].label.as_str(), p[0].text_source, p[0].blocks[0].level, p[0].blocks[1].bullet), ("", TextSource::Layer, Some(2), true));
    assert!(parse_pages(r#"[{"pdf_page":1,"text_source":"guess","blocks":[]}]"#).is_err());
    assert!(parse_pages(r#"[{"pdf_page":1,"blocks":[{"text":"x","kind":"title"}]}]"#).is_err());
}

#[test]
fn headings_and_asides_in_the_pages_shape_the_passages() {
    let pages = vec![PageIn {
        pdf_page: 3,
        label: "iii".into(),
        text_source: TextSource::Layer,
        blocks: vec![
            PageBlock { text: "Wells".into(), kind: BlockKind::Heading, level: Some(1), bullet: false },
            PageBlock { text: sentence_page(3), kind: BlockKind::Body, level: None, bullet: false },
            PageBlock { text: "Digging by hand is slow.".into(), kind: BlockKind::Aside, level: None, bullet: false },
        ],
    }];
    let (pack, _) = build_pack_from_pages(&plain_source(), &pages, &BuildOptions::new("scan.pdf", STAMP), &FakeEmbedder, &mut |_| {}).unwrap();
    assert!(pack.pieces.iter().all(|p| p.heading_path == vec!["Wells".to_string()]));
    assert!(pack.pieces.iter().all(|p| p.page == "iii" && p.pdf_page == Some(3)));
    assert_eq!(pack.header.page_count, 3, "at least the highest page");
    assert_eq!(pack.header.ocr_pages, Vec::<usize>::new());
}

/// The pack's bytes with the header rewritten by `f`.
fn rewrite_header(bytes: &[u8], f: impl FnOnce(&mut serde_json::Map<String, Value>)) -> Vec<u8> {
    let mut s = String::new();
    flate2::read::GzDecoder::new(bytes).read_to_string(&mut s).unwrap();
    let mut lines = s.lines();
    let mut h: Value = serde_json::from_str(lines.next().unwrap()).unwrap();
    f(h.as_object_mut().unwrap());
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::new(6));
    writeln!(gz, "{h}").unwrap();
    for l in lines {
        writeln!(gz, "{l}").unwrap();
    }
    gz.finish().unwrap()
}

#[test]
fn packs_of_revision_2_3_and_4_still_read_and_the_new_keys_are_optional() {
    let pack = pdf_pack(&headed_book());
    let bytes = pack_bytes(&pack).unwrap();
    // revision 4 as written now: the layout version is there
    let mut s = String::new();
    flate2::read::GzDecoder::new(&bytes[..]).read_to_string(&mut s).unwrap();
    let h: Value = serde_json::from_str(s.lines().next().unwrap()).unwrap();
    assert_eq!(h["extractor"]["layout_version"], json!(LAYOUT_VERSION));
    assert!(h.get("text_source_ocr_pages").is_none(), "absent when every page is the text layer");
    assert_eq!(read_pack_bytes(&bytes).unwrap(), pack);
    // a pack written before the layout version was recorded (revision 4 earlier, 3 or 2): no layout_version, no book, no samebook
    let old = rewrite_header(&bytes, |h| {
        h["extractor"].as_object_mut().unwrap().remove("layout_version");
        h.remove("book");
        h.remove("samebook");
    });
    let back = read_pack_bytes(&old).unwrap();
    assert_eq!(back.header.extractor.layout_version, None);
    assert!(back.header.text_source_ocr_pages.is_empty());
    assert_eq!(back.pieces, pack.pieces);
    // revision 3 with a division
    let rev3 = rewrite_header(&old, |h| {
        h.insert("division".into(), json!({"division": "440", "label": "Water", "score": null, "classifier_version": null, "source": "label", "second_division": null}));
    });
    assert_eq!(read_pack_bytes(&rev3).unwrap().header.suggested().map(|s| s.div), Some("440".to_string()));
    // a pack with the text sources round-trips
    let with = rewrite_header(&bytes, |h| {
        h.insert("text_source_ocr_pages".into(), json!([2, 3]));
    });
    assert_eq!(read_pack_bytes(&with).unwrap().header.text_source_ocr_pages, vec![2, 3]);
    let tmp = tempfile::tempdir().unwrap();
    let path = write_pack(&read_pack_bytes(&with).unwrap(), tmp.path()).unwrap();
    assert_eq!(read_header(&path).unwrap().text_source_ocr_pages, vec![2, 3]);
}

#[test]
fn an_ocr_record_on_pdf_marks_every_page_as_ocr_unless_the_pages_are_listed() {
    let tmp = tempfile::tempdir().unwrap();
    let pdf_path = tmp.path().join("scan.pdf");
    std::fs::write(&pdf_path, headed_book()).unwrap(); // three pages
    let run = |out: &str, extra: &[&str]| {
        cli()
            .arg("pdf")
            .arg(pdf_path.as_path())
            .arg("--out")
            .arg(tmp.path().join(out))
            .args(["--fake-embedder", "--in-process", "--created-at", STAMP, "--doc-id", "scan"])
            .args(extra)
            .output()
            .unwrap()
    };
    let header = |out: &str| read_header(&tmp.path().join(out).join("scan@1.cdoc")).unwrap();
    // no OCR record: every page is the text layer
    assert!(run("none", &[]).status.success());
    assert!(header("none").text_source_ocr_pages.is_empty());
    // an OCR record: every page's text is OCR
    let o = run("all", &["--ocr-engine", "docTR", "--ocr-version", "1.1.0", "--ocr-pages", "3"]);
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    let h = header("all");
    assert_eq!(h.text_source_ocr_pages, vec![1, 2, 3]);
    assert_eq!(h.book.as_ref().unwrap().ocr.as_ref().map(|o| o.pages_ocrd), Some(3));
    // the same from a JSON file keyed by the input's name
    let side = tmp.path().join("ocr.json");
    std::fs::write(&side, json!({"scan.pdf": {"engine": "docTR", "version": "1.1.0", "pages_ocrd": 3}}).to_string()).unwrap();
    assert!(run("json", &["--ocr-json", side.to_str().unwrap()]).status.success());
    assert_eq!(header("json").text_source_ocr_pages, vec![1, 2, 3]);
    // partial OCR: the listed pages only
    let o = run("some", &["--ocr-engine", "docTR", "--ocr-version", "1.1.0", "--ocr-text-pages", "2-3"]);
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    assert_eq!(header("some").text_source_ocr_pages, vec![2, 3]);
    // a list that is not a list, or names a page the PDF does not have, is refused
    assert_eq!(run("bad1", &["--ocr-engine", "docTR", "--ocr-version", "1", "--ocr-text-pages", "3-1"]).status.code(), Some(2));
    assert!(!run("bad2", &["--ocr-engine", "docTR", "--ocr-version", "1", "--ocr-text-pages", "9"]).status.success());
    assert!(!tmp.path().join("bad2").join("scan@1.cdoc").exists());
}
