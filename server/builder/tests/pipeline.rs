//! End-to-end tests on PDFs generated at test time: extraction, reading order, headings, furniture, chunking, packs,
//! and the library built from the packs.

mod common;

use cache_builder::build::{build_pack, BuildOptions};
use cache_builder::embed::{fake_vector, FakeEmbedder};
use cache_builder::extract::extract_pdf;
use cache_builder::layout::{layout, Element};
use cache_builder::pack::{pack_bytes, read_pack, write_pack, Pack};
use common::*;

const STAMP: &str = "2026-11-01T00:00:00Z";

fn build(pdf: &[u8]) -> (Pack, cache_builder::Report) {
    build_pack(pdf, &BuildOptions::new("book.pdf", STAMP), &FakeEmbedder).expect("build")
}

fn all_text(p: &Pack) -> String {
    p.pieces.iter().map(|x| x.text.as_str()).collect::<Vec<_>>().join(" ")
}

/// A page shaped like page 18 of a joint-doctrine PDF: two columns, a full-width italic epigraph at the top, its
/// attribution in the right column, and a sentence that runs from the end of the left column into the start of the right
/// one ("... designators (i.e.," / "Combined Task Force (CTF) 62.1), not by the terms").
fn epigraph_page() -> Page {
    let mut p = Page::new();
    p.line(185.0, 24.0, 14.0, Font::Regular, "CHAPTER I");
    p.line(100.0, 41.0, 12.0, Font::Bold, "CONCEPT OF AMPHIBIOUS OPERATIONS");
    p.line(54.0, 64.0, 10.0, Font::Italic, "\"A landing on a foreign coast in the face of hostile troops");
    p.line(54.0, 76.0, 10.0, Font::Italic, "has always been one of the most difficult operations of war.\"");
    p.line(262.0, 100.0, 9.0, Font::Bold, "Captain Sir Basil H. Liddell Hart");
    // left column
    p.line(45.0, 127.0, 12.0, Font::Bold, "1. General");
    let left = [
        "a. An amphibious operation is a military",
        "operation launched from the sea by an",
        "amphibious force, embarked in ships or craft",
        "with the primary purpose of introducing a",
        "landing force ashore to accomplish the",
        "assigned mission. Types of amphibious",
        "operations include assaults, withdrawals,",
        "demonstrations, raids, and other amphibious",
        "operations in a permissive environment.",
    ];
    p.block(45.0, 152.0, 10.0, Font::Regular, &left);
    let left2 = [
        "b. An amphibious force conducts amphibious",
        "operations. An amphibious force is defined as",
        "an amphibious task force and a landing force,",
        "together with other forces that are trained,",
        "organized, and equipped for amphibious",
        "operations. In operations and exercises,",
        "amphibious commanders are referred to by",
        "either their operational command titles (i.e.,",
    ];
    p.block(45.0, 284.0, 10.0, Font::Regular, &left2);
    // right column
    let right = [
        "Combined Task Force (CTF) 62.1),",
        "not by the terms CATF or CLF. The",
        "terms CATF and CLF do not connote",
        "titles or command relationships.",
    ];
    p.block(262.0, 128.0, 10.0, Font::Regular, &right);
    let right2 = [
        "d. Amphibious operations apply",
        "maneuver principles to expeditionary",
        "power projection in joint operations.",
        "Maneuver is used to destroy or",
        "seriously disrupt the enemy cohesion",
        "through rapid and focused actions.",
    ];
    p.block(262.0, 236.0, 10.0, Font::Regular, &right2);
    p
}

fn epigraph_pdf() -> Vec<u8> {
    // a few ordinary pages first so the body size and heading sizes are established
    let mut pages = vec![epigraph_page()];
    for n in 0..3 {
        let mut p = Page::new();
        p.line(45.0, 40.0, 14.0, Font::Regular, &format!("CHAPTER {}", n + 2));
        let text = "The body of the chapter carries on in ordinary type at ten points so that the median size of the document is ten. ".repeat(4);
        p.block(45.0, 80.0, 10.0, Font::Regular, &wrap(&text, 80).iter().map(|s| s.as_str()).collect::<Vec<_>>());
        pages.push(p);
    }
    make_pdf(&pages, Some("Amphibious test"))
}

#[test]
fn epigraph_does_not_interrupt_the_sentence() {
    let pdf = epigraph_pdf();
    if let Ok(d) = std::env::var("CACHE_BUILDER_WRITE_FIXTURES") {
        std::fs::write(std::path::Path::new(&d).join("epigraph.pdf"), &pdf).unwrap();
    }
    let ext = extract_pdf(&pdf).unwrap();
    assert_eq!(ext.pages.len(), 4);
    assert_eq!(ext.title.as_deref(), Some("Amphibious test"));
    let lay = layout(&ext);
    let texts: Vec<&str> = lay
        .elements
        .iter()
        .filter_map(|e| match e {
            Element::Para { text, page: 0, .. } => Some(text.as_str()),
            _ => None,
        })
        .collect();
    let joined = texts.join(" ");
    // the sentence is whole across the column break
    assert!(joined.contains("(i.e., Combined Task Force (CTF) 62.1), not by the terms"), "{joined}");
    // and the epigraph, its attribution come after the column text
    let a = joined.find("A landing on a foreign coast").expect("epigraph present");
    let b = joined.find("not by the terms").unwrap();
    let c = joined.find("Maneuver is used to destroy").unwrap();
    assert!(a > b && a > c, "the epigraph goes after the column text: {joined}");
    // headings were found and the section heading starts the path
    let (pack, _) = build(&pdf);
    let all = all_text(&pack);
    assert!(all.contains("(i.e., Combined Task Force"));
    assert!(pack.pieces.iter().any(|p| p.heading_path.iter().any(|h| h == "1. General")));
}

#[test]
fn headings_get_levels_and_paths() {
    let mut pages = Vec::new();
    for n in 1..=3 {
        let mut p = Page::new();
        p.line(45.0, 40.0, 20.0, Font::Regular, &format!("Part {n}"));
        p.line(45.0, 80.0, 14.0, Font::Regular, &format!("Alpha {n}"));
        p.line(45.0, 110.0, 10.0, Font::Bold, &format!("Notes {n}"));
        let text = format!("Rivers carry water to the sea and the notes for part {n} explain how. They also carry silt, and the silt builds the delta over many years of slow work. ");
        let lines = wrap(&text.repeat(5), 80);
        p.block(45.0, 130.0, 10.0, Font::Regular, &lines.iter().map(|s| s.as_str()).collect::<Vec<_>>());
        pages.push(p);
    }
    let pdf = make_pdf(&pages, None);
    let ext = extract_pdf(&pdf).unwrap();
    let lay = layout(&ext);
    let heads: Vec<(u8, String)> = lay
        .elements
        .iter()
        .filter_map(|e| match e {
            Element::Heading { level, text, .. } => Some((*level, text.clone())),
            _ => None,
        })
        .collect();
    assert_eq!(heads[0], (1, "Part 1".to_string()));
    assert_eq!(heads[1], (2, "Alpha 1".to_string()));
    assert_eq!(heads[2], (4, "Notes 1".to_string()));
    assert_eq!(heads.len(), 9);
    let (pack, report) = build(&pdf);
    assert_eq!(report.heading_count, 9);
    let p2 = pack.pieces.iter().find(|p| p.heading_path.first().map(|s| s.as_str()) == Some("Part 2")).unwrap();
    assert_eq!(p2.heading_path, vec!["Part 2", "Alpha 2", "Notes 2"]);
    assert_eq!(p2.page, "2");
    // a heading never leaks into the next one's pieces
    for p in &pack.pieces {
        let n = p.heading_path[0].trim_start_matches("Part ").to_string();
        assert!(p.text.contains(&format!("part {n} ")) || p.text.contains("silt"), "{}", p.text);
        assert_eq!(p.pdf_page, Some(n.parse::<u32>().unwrap()));
    }
}

#[test]
fn a_bold_first_line_of_a_wrapped_paragraph_is_not_a_heading() {
    let mut p = Page::new();
    p.block(45.0, 60.0, 10.0, Font::Regular, &wrap(&"Ordinary text runs along the page in the regular face for many lines. ".repeat(12), 70).iter().map(|s| s.as_str()).collect::<Vec<_>>());
    p.line(45.0, 400.0, 10.0, Font::Bold, "a. The first line of a list item in bold");
    p.line(45.0, 412.0, 10.0, Font::Regular, "carries on in lowercase on the next line.");
    let pdf = make_pdf(&[p], None);
    let lay = layout(&extract_pdf(&pdf).unwrap());
    assert!(lay.elements.iter().all(|e| !matches!(e, Element::Heading { .. })), "{:?}", lay.elements);
}

#[test]
fn a_paragraph_in_large_type_is_not_a_heading() {
    let mut pages = Vec::new();
    for n in 0..4 {
        let mut p = Page::new();
        p.block(45.0, 60.0, 10.0, Font::Regular, &wrap(&format!("Small print number {n} runs for a good while. ").repeat(14), 80).iter().map(|s| s.as_str()).collect::<Vec<_>>());
        pages.push(p);
    }
    let mut big = Page::new();
    big.block(45.0, 60.0, 14.0, Font::Regular, &["This manual has been prepared for the", "reader who would like to learn more", "about the subject. Most important, it", "touches on the critical decisions."]);
    pages.push(big);
    let lay = layout(&extract_pdf(&make_pdf(&pages, None)).unwrap());
    assert!(lay.elements.iter().all(|e| !matches!(e, Element::Heading { .. })), "{:?}", lay.elements);
    assert!(lay.elements.iter().any(|e| matches!(e, Element::Para { text, .. } if text.starts_with("This manual has been prepared"))));
}

#[test]
fn callouts_times_and_references_are_not_headings() {
    let mut p = Page::new();
    let body = wrap(&"Ordinary text runs along the page in the regular face for many lines. ".repeat(30), 70);
    let body: Vec<&str> = body.iter().map(|s| s.as_str()).collect();
    p.block(45.0, 40.0, 10.0, Font::Regular, &body[..6]);
    p.line(45.0, 140.0, 10.0, Font::Bold, "NOTE: The team will not initiate contact");
    p.block(45.0, 170.0, 10.0, Font::Regular, &body[6..12]);
    p.line(45.0, 270.0, 10.0, Font::Bold, "0800");
    p.line(45.0, 300.0, 10.0, Font::Bold, "6-7");
    p.line(45.0, 330.0, 10.0, Font::Bold, "Figure 4-1");
    p.block(45.0, 360.0, 10.0, Font::Regular, &body[12..18]);
    p.line(45.0, 460.0, 10.0, Font::Bold, "MARKSMANSHIP");
    p.block(45.0, 490.0, 10.0, Font::Regular, &body[18..24]);
    let lay = layout(&extract_pdf(&make_pdf(&[p], None)).unwrap());
    let heads: Vec<&str> = lay.elements.iter().filter_map(|e| if let Element::Heading { text, .. } = e { Some(text.as_str()) } else { None }).collect();
    assert_eq!(heads, vec!["MARKSMANSHIP"]);
}

#[test]
fn running_heads_and_page_numbers_are_removed() {
    let mut pages = Vec::new();
    for n in 1..=9 {
        let mut p = Page::new();
        p.line(120.0, 20.0, 9.0, Font::Regular, "A Short History of Rivers");
        p.line(210.0, 615.0, 9.0, Font::Regular, &n.to_string());
        let text = format!("Page text number {} says that the river runs down to the sea. ", ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"][n - 1]);
        p.block(45.0, 80.0, 10.0, Font::Regular, &wrap(&text.repeat(8), 70).iter().map(|s| s.as_str()).collect::<Vec<_>>());
        pages.push(p);
    }
    let (pack, _) = build(&make_pdf(&pages, None));
    let all = all_text(&pack);
    assert!(!all.contains("Short History"), "{all}");
    assert!(!all.chars().any(|c| c.is_ascii_digit()), "page numbers leaked: {all}");
    assert!(all.contains("the river runs down to the sea"));
}

#[test]
fn hyphenated_words_and_split_justified_lines_are_rejoined() {
    let mut p = Page::new();
    p.block(
        45.0,
        60.0,
        10.0,
        Font::Regular,
        &[
            "The committee published the informa-",
            "tion about the new regulations in the",
            "spring. A well-known example is the one",
            "that every student of the subject learns.",
        ],
    );
    // a justified line that the extractor sees as several runs with wide gaps
    for (i, (x, w)) in [(45.0, "Commanding"), (140.0, "General,"), (215.0, "2d"), (265.0, "Marine")].iter().enumerate() {
        let _ = i;
        p.line(*x, 140.0, 10.0, Font::Regular, w);
    }
    p.block(45.0, 152.0, 10.0, Font::Regular, &["Expeditionary Brigade is the unit named by the order."]);
    let (pack, _) = build(&make_pdf(&[p], None));
    let all = all_text(&pack);
    assert!(all.contains("published the information about the new regulations"), "{all}");
    assert!(all.contains("A well-known example"), "{all}");
    assert!(all.contains("Commanding General, 2d Marine Expeditionary Brigade"), "{all}");
    assert!(!all.contains("  "), "double spaces in {all}");
}

#[test]
fn pages_without_a_text_layer_are_marked_for_ocr() {
    let mut a = Page::new();
    a.block(45.0, 60.0, 10.0, Font::Regular, &wrap(&"Some ordinary words fill this first page of the document. ".repeat(6), 70).iter().map(|s| s.as_str()).collect::<Vec<_>>());
    let mut b = Page::new();
    b.picture = true;
    let mut c = a.clone();
    c.picture = false;
    let pdf = make_pdf(&[a, b, c], None);
    let ext = extract_pdf(&pdf).unwrap();
    assert_eq!(ext.pages[1].images, 1);
    let (pack, report) = build(&pdf);
    assert_eq!(report.ocr_pages, vec![2]);
    assert_eq!(pack.header.ocr_pages, vec![2]);
    // a PDF with nothing but a picture is a clear error, not an empty pack
    let mut only = Page::new();
    only.picture = true;
    let err = build_pack(&make_pdf(&[only], None), &BuildOptions::new("x.pdf", STAMP), &FakeEmbedder).unwrap_err();
    assert!(err.0.contains("OCR"), "{err}");
}

fn two_page_doc() -> Vec<u8> {
    let mut pages = Vec::new();
    for n in 1..=2 {
        let mut p = Page::new();
        p.line(45.0, 40.0, 14.0, Font::Regular, &format!("Heading {n}"));
        let text = "Water moves through the ground and the roots of the trees take it up before the sun draws it out again. ".repeat(8);
        p.block(45.0, 80.0, 10.0, Font::Regular, &wrap(&text, 70).iter().map(|s| s.as_str()).collect::<Vec<_>>());
        pages.push(p);
    }
    make_pdf(&pages, Some("Water cycle"))
}

#[test]
fn same_pdf_gives_identical_packs_and_ids() {
    let pdf = two_page_doc();
    let (a, _) = build(&pdf);
    let (b, _) = build(&pdf);
    assert_eq!(pack_bytes(&a).unwrap(), pack_bytes(&b).unwrap());
    assert_eq!(a.header.doc_id, blake3::hash(&pdf).to_hex().to_string());
    assert_eq!(a.header.doc_version, 1);
    assert_eq!(a.header.source.size, pdf.len() as u64);
    assert_eq!(a.header.title, "Water cycle");
    // a supplied id and a new version
    let mut o = BuildOptions::new("w.pdf", STAMP);
    o.doc_id = Some("water-cycle".into());
    o.doc_version = 2;
    o.https = Some("https://example.org/w.pdf".into());
    let (c, _) = build_pack(&pdf, &o, &FakeEmbedder).unwrap();
    assert_eq!((c.header.doc_id.as_str(), c.header.doc_version), ("water-cycle", 2));
    assert_eq!(c.header.source.https.as_deref(), Some("https://example.org/w.pdf"));
    assert_eq!(a.pieces.len(), c.pieces.len());
    let mut bad = BuildOptions::new("w.pdf", STAMP);
    bad.doc_id = Some("a/b".into());
    assert!(build_pack(&pdf, &bad, &FakeEmbedder).is_err());
}

#[test]
fn pack_round_trip() {
    let dir = tempfile::tempdir().unwrap();
    let (pack, _) = build(&two_page_doc());
    let path = write_pack(&pack, dir.path()).unwrap();
    assert_eq!(path.file_name().unwrap().to_string_lossy(), format!("{}@1.cdoc", pack.header.doc_id));
    let back = read_pack(&path).unwrap();
    assert_eq!(back, pack);
    assert_eq!(back.pieces[0].vector, fake_vector(&back.pieces[0].text));
    // no temporary file is left behind
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
}

#[test]
fn library_is_checked_by_the_core() {
    use cache_builder::library::{build_library, check_library_dir, point_uuid, LibraryOptions};
    let packs = tempfile::tempdir().unwrap();
    let out = tempfile::tempdir().unwrap();
    let (a, _) = build(&two_page_doc());
    let mut o = BuildOptions::new("other.pdf", STAMP);
    o.doc_id = Some("other-doc".into());
    let (b, _) = build_pack(&epigraph_pdf(), &o, &FakeEmbedder).unwrap();
    write_pack(&a, packs.path()).unwrap();
    write_pack(&b, packs.path()).unwrap();
    // an older version of "other-doc" sits beside the newer one and is not used
    let mut o2 = BuildOptions::new("other.pdf", STAMP);
    o2.doc_id = Some("other-doc".into());
    o2.doc_version = 2;
    let (b2, _) = build_pack(&two_page_doc(), &o2, &FakeEmbedder).unwrap();
    write_pack(&b2, packs.path()).unwrap();
    let lib = out.path().join("lib");
    let opts = LibraryOptions { id: "test-lib".into(), title: "Test library".into(), version: "1".into(), archive: true };
    let r = build_library(packs.path(), &lib, &opts).unwrap();
    assert_eq!(r.documents, 2);
    assert_eq!(r.points, a.pieces.len() + b2.pieces.len());
    let check = check_library_dir(&lib).unwrap();
    assert_eq!(check["docs"].as_u64().unwrap() as usize, r.points);
    assert_eq!(check["whole_library_only"], serde_json::json!(false));
    assert_eq!(check["resolved"]["library_id"], serde_json::json!("test-lib"));
    assert_eq!(check["resolved"]["fields"]["text"], serde_json::json!("text"));
    assert_eq!(check["resolved"]["fields"]["document"], serde_json::json!("doc_id"));
    // the documented id example
    assert_eq!(point_uuid("first-aid-manual", 1, 0).to_string(), "53c4f2de-73d1-52fd-88f6-0995418c88aa");

    // the .cache-library goes through the app's own add path (unpack, then check) and holds the same library
    let arch = r.archive.clone().expect("archive");
    let target = out.path().join("unpacked");
    let req = cache_search::libadd::prepare_unpack(arch.to_str().unwrap(), target.to_str().unwrap(), None, None).unwrap();
    let detail = std::cell::RefCell::new(serde_json::Value::Null);
    let outcome = cache_search::libadd::run_unpack(&req, &|_, _| {}, &|v| *detail.borrow_mut() = v, &|| false).unwrap();
    assert!(matches!(outcome, cache_search::index::Outcome::Done));
    let d = detail.borrow();
    assert_eq!(d["docs"].as_u64().unwrap() as usize, r.points);
    assert_eq!(d["whole_library_only"], serde_json::json!(false));
    assert_eq!(d["settings_source"], serde_json::json!("archive"));
    assert_eq!(d["resolved"]["library_id"], serde_json::json!("test-lib"));
}

/// Real books: set CACHE_BUILDER_BOOKS to PDF paths separated by ':' and run with `--ignored --nocapture`.
#[test]
#[ignore]
fn real_books() {
    let Ok(paths) = std::env::var("CACHE_BUILDER_BOOKS") else { return };
    for path in paths.split(':').filter(|p| !p.is_empty()) {
        let t0 = std::time::Instant::now();
        let bytes = std::fs::read(path).unwrap();
        let (_, r) = build(&bytes);
        println!(
            "{path}: pages {} pieces {} words mean {:.0} min {} max {} ocr {} headings {} in {:.1}s",
            r.pages, r.pieces, r.mean_words, r.min_words, r.max_words, r.ocr_pages.len(), r.heading_count, t0.elapsed().as_secs_f32()
        );
        assert!(r.max_words <= 300);
    }
}
