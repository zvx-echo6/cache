//! Pack revisions 3 and 4 (`samebook`, the `book` block), the better-copy order, the seed log and the local view, and the
//! `--labels` / `--titles` options of `cache-build library` and `cache-build pdf`.

mod common;

use cache_builder::build::{build_pack, BuildOptions};
use cache_builder::embed::FakeEmbedder;
use cache_builder::library::{build_library, seed_events, LibraryOptions, SETTINGS_FILE, SUMS_FILE};
use cache_builder::log::{resolve, By, Kind};
use cache_builder::pack::{f16_to_f32, f32_to_f16, pack_bytes, read_header, read_pack, read_pack_bytes, write_pack, OcrInfo, Pack, Suggested};
use cache_builder::view::BookFacts;
use cache_builder::samebook::{best_copy, CopyQuality};
use common::*;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::collections::BTreeMap;
use std::path::Path;
use std::process::Command;

const STAMP: &str = "2026-11-01T00:00:00Z";
/// 2026-11-01T00:00:00Z in milliseconds.
const BUILT_AT: u64 = 1793491200000;

fn doc_pdf(title: &str, topic: &str, pages: usize) -> Vec<u8> {
    let mut v = Vec::new();
    for n in 1..=pages {
        let mut p = Page::new();
        p.line(45.0, 40.0, 14.0, Font::Regular, &format!("Heading {n}"));
        let text = format!("The {topic} moves through the ground and the roots of the trees take it up before the sun draws it out again. ").repeat(8);
        p.block(45.0, 80.0, 10.0, Font::Regular, &wrap(&text, 70).iter().map(|s| s.as_str()).collect::<Vec<_>>());
        v.push(p);
    }
    make_pdf(&v, Some(title))
}

fn build(pdf: &[u8], name: &str) -> Pack {
    build_pack(pdf, &BuildOptions::new(name, STAMP), &FakeEmbedder).expect("build").0
}

fn cli() -> Command {
    Command::new(env!("CARGO_BIN_EXE_cache-build"))
}

fn header_json(bytes: &[u8]) -> Value {
    let mut s = String::new();
    flate2::read::GzDecoder::new(bytes).read_to_string(&mut s).unwrap();
    serde_json::from_str(s.lines().next().unwrap()).unwrap()
}

/// The pack's bytes with the header rewritten by `f` (every other line as it was).
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
fn half_precision_rounds_like_ieee() {
    for (x, bits) in [(0.0f32, 0x0000u16), (1.0, 0x3c00), (-2.0, 0xc000), (0.5, 0x3800), (65504.0, 0x7bff), (1e9, 0x7c00), (1.0 / 16384.0, 0x0400)] {
        assert_eq!(f32_to_f16(x), bits, "{x}");
        assert_eq!(f16_to_f32(bits), if x == 1e9 { f32::INFINITY } else { x }, "{x}");
    }
    // a value between two halves goes to the nearer; a tie goes to the even one
    assert_eq!(f32_to_f16(1.0 + 1.0 / 2048.0), 0x3c00);
    assert_eq!(f32_to_f16(1.0 + 3.0 / 2048.0), 0x3c02);
    // every half converts back to itself
    for h in 0u16..=0xffff {
        let f = f16_to_f32(h);
        if f.is_nan() {
            continue;
        }
        assert_eq!(f32_to_f16(f), h, "{h:#06x}");
    }
}

fn suggestion(div: &str, label: &str, source: &str) -> Suggested {
    Suggested { div: div.into(), label: label.into(), score: Some(0.875), classifier_version: Some(3), source: source.into(), second_div: Some("450".into()) }
}

#[test]
fn a_revision_4_pack_round_trips_and_revision_2_and_3_packs_still_load() {
    let pdf = doc_pdf("Water cycle", "water", 3);
    let mut pack = build(&pdf, "water.pdf");
    let sb = pack.header.samebook.clone().expect("the builder writes samebook");
    assert_eq!(sb.pages, 3);
    assert_eq!(sb.source_size, pdf.len() as u64);
    assert_eq!(sb.minhash.len(), 128);
    assert_eq!(sb.mean_vector.len(), 1024);
    assert!(sb.text_pages >= 1 && sb.text_pages <= 3);
    // the builder writes the book block: the title, the arrival hash, and nothing it was not told
    let book = pack.header.book.clone().expect("the builder writes book");
    assert_eq!(book.title, "Water cycle");
    assert_eq!(book.source_title, None);
    assert_eq!(book.original_blake3, pack.header.source.blake3);
    assert!(book.compression.is_none() && book.ocr.is_none() && book.suggested.is_none());
    {
        let b = pack.header.book.as_mut().unwrap();
        b.suggested = Some(suggestion("440", "Water", "classifier"));
        b.ocr = Some(OcrInfo { engine: "doctr".into(), version: "1.1.0".into(), pages_ocrd: 12, confidence: None });
    }
    let bytes = pack_bytes(&pack).unwrap();
    assert_eq!(read_pack_bytes(&bytes).unwrap(), pack, "a revision 4 pack reads back equal");
    assert_eq!(bytes, pack_bytes(&pack).unwrap(), "and is deterministic");
    let h = header_json(&bytes);
    assert_eq!(h["cdoc"], json!(1));
    assert!(h.get("division").is_none(), "revision 3's division is not written any more");
    assert_eq!(h["book"]["title"], json!("Water cycle"));
    assert_eq!(h["book"]["original_blake3"], h["source"]["blake3"]);
    assert_eq!(h["book"]["suggested"]["div"], json!("440"));
    assert_eq!(h["book"]["suggested"]["second_div"], json!("450"));
    assert_eq!(h["book"]["suggested"]["source"], json!("classifier"));
    assert_eq!(h["book"]["compression"], Value::Null);
    assert_eq!(h["book"]["ocr"], json!({"engine": "doctr", "version": "1.1.0", "pages_ocrd": 12}));
    assert_eq!(h["samebook"]["minhash"].as_array().unwrap().len(), 128);
    // 1024 halves = 2048 bytes = 2732 base64 characters
    assert_eq!(h["samebook"]["mean_vector"].as_str().unwrap().len(), 2732);

    // a revision 3 pack has a division and no book: it loads, and the division reads as the suggestion
    let rev3 = rewrite_header(&bytes, |h| {
        h.remove("book");
        h.insert("division".into(), json!({"division": "440", "label": "Water", "score": 0.875, "classifier_version": 3, "source": "sorter", "second_division": "450"}));
    });
    let back = read_pack_bytes(&rev3).unwrap();
    assert!(back.header.book.is_none());
    let sg = back.header.suggested().unwrap();
    assert_eq!((sg.div.as_str(), sg.label.as_str(), sg.source.as_str(), sg.second_div.as_deref(), sg.score, sg.classifier_version), ("440", "Water", "classifier", Some("450"), Some(0.875), Some(3)));
    assert_eq!(back.header.book_title(), "Water cycle");
    assert_eq!(back.pieces, pack.pieces);
    // a person's or a label's division is a label
    let user = rewrite_header(&rev3, |h| h["division"]["source"] = json!("user"));
    assert_eq!(read_pack_bytes(&user).unwrap().header.suggested().unwrap().source, "label");
    // written again, a revision 3 pack becomes revision 4 with its division as book.suggested
    let again = header_json(&pack_bytes(&back).unwrap());
    assert!(again.get("division").is_none());
    assert_eq!(again["book"]["suggested"]["source"], json!("classifier"));
    assert_eq!(again["book"]["title"], json!("Water cycle"));
    assert_eq!(again["book"]["original_blake3"], again["source"]["blake3"]);

    // a revision 2 pack has neither and loads, with nothing suggested
    let old = rewrite_header(&bytes, |h| {
        h.remove("book");
        h.remove("division");
        h.remove("samebook");
    });
    let back = read_pack_bytes(&old).unwrap();
    assert!(back.header.book.is_none() && back.header.division.is_none() && back.header.samebook.is_none());
    assert!(back.header.suggested().is_none());
    assert_eq!(back.header.book_title(), "Water cycle");
    // an older reader ignores the new keys: every key it knows is still there with the same value
    let before = header_json(&old);
    let after = header_json(&bytes);
    for (k, v) in before.as_object().unwrap() {
        assert_eq!(&after[k], v, "{k}");
    }

    // a source this reader does not know is refused; null score and second division are fine
    let bad = rewrite_header(&bytes, |h| h["book"]["suggested"]["source"] = json!("guess"));
    assert!(read_pack_bytes(&bad).is_err());
    let bad3 = rewrite_header(&rev3, |h| h["division"]["source"] = json!("guess"));
    assert!(read_pack_bytes(&bad3).is_err());
    let nulls = rewrite_header(&bytes, |h| {
        h["book"]["suggested"]["score"] = Value::Null;
        h["book"]["suggested"]["classifier_version"] = Value::Null;
        h["book"]["suggested"]["second_div"] = Value::Null;
        h["book"]["suggested"]["source"] = json!("label");
    });
    let d = read_pack_bytes(&nulls).unwrap().header.book.unwrap().suggested.unwrap();
    assert_eq!((d.score, d.classifier_version, d.second_div, d.source.as_str()), (None, None, None, "label"));

    // the header alone can be read without the vectors
    let tmp = tempfile::tempdir().unwrap();
    let path = write_pack(&pack, tmp.path()).unwrap();
    assert_eq!(read_header(&path).unwrap(), pack.header);
}

#[test]
fn the_cli_pdf_command_writes_samebook_into_each_pack() {
    let tmp = tempfile::tempdir().unwrap();
    let pdf_path = tmp.path().join("water.pdf");
    let pdf = doc_pdf("Water cycle", "water", 2);
    std::fs::write(&pdf_path, &pdf).unwrap();
    let packs = tmp.path().join("packs");
    let out = cli().args(["pdf"]).arg(pdf_path.as_path()).args(["--out"]).arg(packs.as_path()).args(["--fake-embedder", "--in-process", "--created-at", STAMP]).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let file = std::fs::read_dir(&packs).unwrap().next().unwrap().unwrap().path();
    let pack = read_pack(&file).unwrap();
    let sb = pack.header.samebook.expect("cache-build pdf writes samebook");
    assert_eq!((sb.pages, sb.source_size), (2, pdf.len() as u64));
    assert_eq!(sb.minhash.len(), 128);
    assert_eq!(Some(sb), build(&pdf, "water.pdf").header.samebook);
}

#[test]
fn the_cli_pdf_command_writes_the_book_block() {
    let tmp = tempfile::tempdir().unwrap();
    let pdf_path = tmp.path().join("water.pdf");
    let pdf = doc_pdf("Water cycle", "water", 2);
    std::fs::write(&pdf_path, &pdf).unwrap();
    let hash = blake3::hash(&pdf).to_hex().to_string();

    // nothing asked: the title from the PDF, the arrival hash is the file's, nothing else
    let plain = tmp.path().join("plain");
    let out = cli().arg("pdf").arg(pdf_path.as_path()).arg("--out").arg(plain.as_path()).args(["--fake-embedder", "--in-process", "--created-at", STAMP]).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let h = read_header(&plain.join(format!("{hash}@1.cdoc"))).unwrap();
    let b = h.book.expect("book");
    assert_eq!((b.title.as_str(), b.original_blake3.as_str()), ("Water cycle", hash.as_str()));
    assert!(b.source_title.is_none() && b.compression.is_none() && b.ocr.is_none() && b.suggested.is_none());

    // a title, a label, an OCR record and the original's hash (the file given is an OCR copy)
    let labels = tmp.path().join("labels.json");
    std::fs::write(&labels, json!([{"id": "w1", "path": "/mnt/library/water.pdf", "final": "440", "second_division": "450"}]).to_string()).unwrap();
    let full = tmp.path().join("full");
    let original = "ab".repeat(32);
    let out = cli()
        .arg("pdf")
        .arg(pdf_path.as_path())
        .arg("--out")
        .arg(full.as_path())
        .args(["--fake-embedder", "--in-process", "--created-at", STAMP, "--doc-id", "w1", "--title", "How Water Moves", "--original-blake3", original.as_str()])
        .args(["--ocr-engine", "doctr", "--ocr-version", "1.1.0", "--ocr-pages", "12", "--labels"])
        .arg(labels.as_path())
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let h = read_header(&full.join("w1@1.cdoc")).unwrap();
    assert_eq!((h.title.as_str(), h.source.blake3.as_str()), ("How Water Moves", hash.as_str()));
    let b = h.book.expect("book");
    assert_eq!((b.title.as_str(), b.source_title.as_deref(), b.original_blake3.as_str()), ("How Water Moves", Some("Water cycle"), original.as_str()));
    assert_eq!(b.ocr, Some(OcrInfo { engine: "doctr".into(), version: "1.1.0".into(), pages_ocrd: 12, confidence: None }));
    let sg = b.suggested.expect("suggested from the label");
    assert_eq!((sg.div.as_str(), sg.label.as_str(), sg.source.as_str(), sg.second_div.as_deref(), sg.score), ("440", "Canning", "label", Some("450"), None));

    // the OCR record from a JSON file keyed by the input's file name
    let side = tmp.path().join("ocr.json");
    std::fs::write(&side, json!({"water.pdf": {"engine": "tesseract", "version": "5.5", "pages_ocrd": 3, "original_blake3": original}, "other.pdf": {"engine": "x", "version": "1"}}).to_string()).unwrap();
    let keyed = tmp.path().join("keyed");
    let out = cli().arg("pdf").arg(pdf_path.as_path()).arg("--out").arg(keyed.as_path()).args(["--fake-embedder", "--in-process", "--created-at", STAMP, "--ocr-json"]).arg(side.as_path()).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let b = read_header(&keyed.join(format!("{hash}@1.cdoc"))).unwrap().book.unwrap();
    assert_eq!(b.ocr, Some(OcrInfo { engine: "tesseract".into(), version: "5.5".into(), pages_ocrd: 3, confidence: None }));
    assert_eq!(b.original_blake3, original);

    // --ocr-engine without --ocr-version is refused
    let out = cli().arg("pdf").arg(pdf_path.as_path()).arg("--out").arg(tmp.path().join("no")).args(["--fake-embedder", "--in-process", "--ocr-engine", "doctr"]).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
}

#[test]
fn the_better_copy_comes_from_the_packs_and_is_the_same_in_any_order() {
    // two files of one book: the longer scan has more pages with text
    let short = build(&doc_pdf("Water", "water", 2), "a.pdf");
    let long = build(&doc_pdf("Water", "water", 4), "b.pdf");
    let mut copies: Vec<CopyQuality> = [&short, &long].iter().map(|p| CopyQuality::of_pack(p).unwrap()).collect();
    assert_eq!(copies[best_copy(&copies).unwrap()].doc_id, long.header.doc_id);
    copies.reverse();
    assert_eq!(copies[best_copy(&copies).unwrap()].doc_id, long.header.doc_id);
    // a pack without samebook cannot be compared
    let mut old = short.clone();
    old.header.samebook = None;
    assert!(CopyQuality::of_pack(&old).is_none());
    // the final tie-break is the lower doc_id, so identical files agree
    let q = |id: &str| CopyQuality { doc_id: id.into(), text_pages: 5, pages: 5, ppi: Some(150), size: 100 };
    assert_eq!(best_copy(&[q("zz"), q("aa"), q("mm")]), Some(1));
}

fn library_opts() -> LibraryOptions {
    LibraryOptions { id: "r3".into(), title: "Revision 3".into(), version: "1".into(), vector_datatype: Default::default(), archive: true, built_at: BUILT_AT }
}

fn two_packs(dir: &Path) -> (Pack, Pack) {
    let mut a = build(&doc_pdf("Water", "water", 2), "water.pdf");
    a.header.book.as_mut().unwrap().suggested = Some(Suggested { div: "440".into(), label: "Water".into(), score: Some(0.5), classifier_version: Some(2), source: "classifier".into(), second_div: None });
    let b = build(&doc_pdf("Stone", "stone", 2), "stone.pdf");
    write_pack(&a, dir).unwrap();
    write_pack(&b, dir).unwrap();
    (a, b)
}

fn read_json(p: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(p).unwrap()).unwrap()
}

#[test]
fn the_library_writes_a_seed_log_and_the_local_view_and_a_rebuild_is_byte_identical() {
    let tmp = tempfile::tempdir().unwrap();
    let packs = tmp.path().join("packs");
    let (a, b) = two_packs(&packs);
    let lib = tmp.path().join("lib");
    let r = build_library(&packs, &lib, &library_opts()).unwrap();

    // the format 1 files are gone: no docs.json at the root, no overrides.json, and the settings file lists no docs
    assert!(!lib.join("docs.json").exists() && !lib.join("overrides.json").exists());
    let settings = read_json(&lib.join(SETTINGS_FILE));
    assert!(settings.get("docs").is_none());

    // the seed log: place then assign for the book that has a division, nothing for the one that has none
    let log_path = lib.join("log").join("builder-r3.jsonl");
    let text = std::fs::read_to_string(&log_path).unwrap();
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines.len(), 2, "{text}");
    assert_eq!(lines[0], format!(r#"{{"v":1,"at":{BUILT_AT},"dev":"builder-r3","ev":"place","doc":"{}","div":"440","by":"auto"}}"#, a.header.doc_id));
    assert_eq!(lines[1], format!(r#"{{"v":1,"at":{BUILT_AT},"dev":"builder-r3","ev":"assign","doc":"{}","div":"440","seq":1}}"#, a.header.doc_id));
    assert!(!text.contains(&b.header.doc_id));

    // the local view: format 2, rebuilt from the packs and the log
    let v = read_json(&lib.join(".local").join("docs.json"));
    assert_eq!(v["format"], json!(2));
    assert_eq!(v["built_from"]["packs"], json!(2));
    assert_eq!(v["built_from"]["logs"]["builder-r3.jsonl"], json!(text.len()));
    let va = &v["docs"][&a.header.doc_id];
    assert_eq!(va["title"], json!("Water"));
    assert_eq!(va["shelf"], json!("440"));
    assert_eq!(va["call"], json!({"div": "440", "seq": 1, "suffix": 0, "text": "CDS 440-001"}));
    assert_eq!(va["suggested"]["source"], json!("classifier"));
    assert_eq!(va["removed"], json!(false));
    let vb = &v["docs"][&b.header.doc_id];
    assert_eq!((vb["title"].clone(), vb["shelf"].clone(), vb["call"].clone(), vb["suggested"].clone()), (json!("Stone"), Value::Null, Value::Null, Value::Null));
    for k in ["title", "source_title", "shelf", "call", "suggested", "removed", "compression", "ocr"] {
        assert!(vb.as_object().unwrap().contains_key(k), "{k} is always written, null when unknown");
    }
    assert_eq!(v["retired"], json!({}));

    // SHA256SUMS covers the synced log and leaves the local view out
    let sums = std::fs::read_to_string(lib.join(SUMS_FILE)).unwrap();
    assert!(sums.lines().any(|l| l.ends_with("  log/builder-r3.jsonl")), "{sums}");
    assert!(!sums.contains(".local") && !sums.contains("docs.json"));
    // atomic: no temporary file is left
    assert!(std::fs::read_dir(lib.join(".local")).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().ends_with(".tmp")));

    // never part of a search payload
    let shard = cache_search::library::open_shard_for_scroll(&lib.join("shard")).unwrap();
    let mut sr = edge::ScrollRequest::new();
    sr.limit = Some(1000);
    sr.with_payload = Some(edge::WithPayloadInterface::Bool(true));
    sr.with_vector = edge::WithVector::Bool(false);
    let (recs, _) = edge::EdgeShardRead::scroll(&shard, sr).unwrap();
    assert_eq!(recs.len(), r.points);
    for rec in recs {
        for k in rec.payload.unwrap().0.keys() {
            assert!(!["division", "label", "second_division", "samebook", "source_title", "call", "shelf", "suggested"].contains(&k.as_str()), "{k} is in a payload");
        }
    }
    // the .cache-library holds the settings file and no docs.json
    let arch = r.archive.unwrap();
    let raw = std::fs::read(&arch).unwrap();
    let tar_bytes = if raw.starts_with(&[0x1f, 0x8b]) {
        let mut v = Vec::new();
        flate2::read::GzDecoder::new(&raw[..]).read_to_end(&mut v).unwrap();
        v
    } else {
        raw
    };
    let names: Vec<String> = tar::Archive::new(&tar_bytes[..]).entries().unwrap().map(|e| e.unwrap().path().unwrap().to_string_lossy().into_owned()).collect();
    assert!(names.contains(&"cache-library.json".to_string()) && !names.contains(&"docs.json".to_string()), "{names:?}");

    // the same inputs and the same --built-at give the same seed log and the same view, byte for byte
    let lib2 = tmp.path().join("lib2");
    build_library(&packs, &lib2, &library_opts()).unwrap();
    assert_eq!(std::fs::read(&log_path).unwrap(), std::fs::read(lib2.join("log").join("builder-r3.jsonl")).unwrap());
    let view1 = std::fs::read(lib.join(".local").join("docs.json")).unwrap();
    assert_eq!(view1, std::fs::read(lib2.join(".local").join("docs.json")).unwrap());

    // `cache-build view` makes the view again from the packs and the log
    std::fs::remove_file(lib.join(".local").join("docs.json")).unwrap();
    let out = cli().arg("view").arg("--library").arg(lib.as_path()).arg("--packs").arg(packs.as_path()).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    assert_eq!(std::fs::read(lib.join(".local").join("docs.json")).unwrap(), view1);
    // with no packs folder it says so and fails
    let out = cli().arg("view").arg("--library").arg(tmp.path().join("nolib")).output().unwrap();
    assert_eq!(out.status.code(), Some(1));
}

#[test]
fn the_library_writes_copies_jsonl_that_reads_like_its_packs_and_travels_in_the_archive() {
    use cache_builder::bookshelves::header_line;
    use cache_builder::library::COPIES_FILE;
    use cache_shelves::library::{copy_key, load_library, LibraryRef};
    let tmp = tempfile::tempdir().unwrap();
    let packs = tmp.path().join("packs");
    let (a, b) = two_packs(&packs);
    let lib = tmp.path().join("lib");
    let r = build_library(&packs, &lib, &library_opts()).unwrap();

    // one line per document, sorted by doc_id, no line break inside a line, listed in SHA256SUMS
    let text = std::fs::read_to_string(lib.join(COPIES_FILE)).unwrap();
    let ids: Vec<String> = text.lines().map(|l| serde_json::from_str::<Value>(l).unwrap()["doc_id"].as_str().unwrap().to_string()).collect();
    let mut want = vec![a.header.doc_id.clone(), b.header.doc_id.clone()];
    want.sort();
    assert_eq!(ids, want);
    assert!(text.ends_with('\n'));
    let sums = std::fs::read_to_string(lib.join(SUMS_FILE)).unwrap();
    assert!(sums.lines().any(|l| l.ends_with("  copies.jsonl")), "{sums}");

    // the library read through copies.jsonl (it has no packs folder) is the library read through the packs
    assert!(!lib.join("packs").exists());
    let from_file = load_library(&LibraryRef::new("r3", &lib), &header_line).unwrap();
    let from_packs = load_library(&LibraryRef::new("r3", tmp.path()), &header_line).unwrap();
    assert_eq!(from_packs.copies.len(), 2);
    assert_eq!(from_file.copies, from_packs.copies, "key, hash, title, quality, samebook facts, book facts and suggestion");
    assert_eq!(from_file.unreadable, 0);
    for c in &from_file.copies {
        assert_eq!(c.copy, copy_key(c.original_blake3.as_deref(), &c.doc_id));
        assert!(c.same.is_some());
    }
    let ca = from_file.copies.iter().find(|c| c.doc_id == a.header.doc_id).unwrap();
    assert_eq!(ca.suggested.as_ref().map(|s| s.div.as_str()), Some("440"));
    assert_eq!(ca.copy, a.header.book.as_ref().unwrap().original_blake3);
    // the encodings are the pack's own
    let sb = a.header.samebook.as_ref().unwrap();
    assert_eq!(ca.same.as_ref().unwrap().mean_vector, sb.mean_vector);
    assert_eq!(ca.same.as_ref().unwrap().minhash, sb.minhash);
    assert_eq!(cache_shelves::same::f32_to_f16(0.3), f32_to_f16(0.3));
    assert_eq!(cache_shelves::same::mean_vector_to(&sb.mean_vector), cache_builder::pack::encode_vector_f16(&sb.mean_vector));

    // a rebuild is byte-identical
    let lib2 = tmp.path().join("lib2");
    build_library(&packs, &lib2, &library_opts()).unwrap();
    assert_eq!(std::fs::read(lib2.join(COPIES_FILE)).unwrap(), text.as_bytes());

    // the .cache-library carries it like documents.tsv and source-identities.json: it unpacks beside them
    let target = tmp.path().join("unpacked");
    let req = cache_search::libadd::prepare_unpack(r.archive.unwrap().to_str().unwrap(), target.to_str().unwrap(), None, None).unwrap();
    assert!(matches!(cache_search::libadd::run_unpack(&req, &|_, _| {}, &|_| {}, &|| false).unwrap(), cache_search::index::Outcome::Done));
    assert_eq!(std::fs::read(target.join(COPIES_FILE)).unwrap(), text.as_bytes());
    assert!(target.join("documents.tsv").exists());
    // and a library folder made from the archive's files, with no packs, reads the same copies
    let rebuilt = tmp.path().join("downloaded");
    std::fs::create_dir_all(&rebuilt).unwrap();
    std::fs::copy(target.join(COPIES_FILE), rebuilt.join(COPIES_FILE)).unwrap();
    assert_eq!(load_library(&LibraryRef::new("r3", &rebuilt), &header_line).unwrap().copies, from_packs.copies);
    // left in shard/ (before the app moves it), it is found there too
    let shard_only = tmp.path().join("shard-only");
    std::fs::create_dir_all(shard_only.join("shard")).unwrap();
    std::fs::copy(target.join(COPIES_FILE), shard_only.join("shard").join(COPIES_FILE)).unwrap();
    assert_eq!(load_library(&LibraryRef::new("r3", &shard_only), &header_line).unwrap().copies, from_packs.copies);
}

#[test]
fn seed_numbers_run_from_1_in_title_then_doc_id_order_within_a_division() {
    let sug = |d: &str| Some(Suggested { div: d.into(), label: "x".into(), score: None, classifier_version: None, source: "label".into(), second_div: None });
    let mut facts = BTreeMap::new();
    facts.insert("id9".to_string(), BookFacts::new("Zinc", sug("440")));
    facts.insert("id2".to_string(), BookFacts::new("Alpha", sug("440")));
    facts.insert("id1".to_string(), BookFacts::new("Alpha", sug("440")));
    facts.insert("id5".to_string(), BookFacts::new("Other", sug("320")));
    facts.insert("id7".to_string(), BookFacts::new("Shelfless", None));
    facts.insert("id8".to_string(), BookFacts::new("Bad code", sug("44")));
    let ev = seed_events(&facts, "builder-x", 5);
    let order: Vec<(String, String)> = ev
        .iter()
        .map(|e| match &e.kind {
            Kind::Place { doc, div, by } => (format!("place {doc} {div}"), by.as_str().to_string()),
            Kind::Assign { doc, div, seq } => (format!("assign {doc} {div} {seq}"), String::new()),
            other => (format!("{other:?}"), String::new()),
        })
        .collect();
    let want = [
        "place id5 320",
        "assign id5 320 1",
        "place id1 440",
        "assign id1 440 1",
        "place id2 440",
        "assign id2 440 2",
        "place id9 440",
        "assign id9 440 3",
    ];
    assert_eq!(order.iter().map(|o| o.0.as_str()).collect::<Vec<_>>(), want);
    assert!(ev.iter().all(|e| e.at == 5 && e.dev == "builder-x"));
    // the same input gives the same events
    assert_eq!(ev, seed_events(&facts, "builder-x", 5));
    // a replaced title sorts as the new title, and is recorded as a title event after the placements
    facts.get_mut("id2").unwrap().title_override = Some("Aardvark".into());
    let ev = seed_events(&facts, "builder-x", 5);
    let r = resolve(&ev);
    let calls: Vec<(String, String)> = ["id2", "id1", "id9"].iter().map(|d| (d.to_string(), r.doc(d).unwrap().call.as_ref().unwrap().text.clone())).collect();
    assert_eq!(calls, [("id2".to_string(), "CDS 440-001".to_string()), ("id1".to_string(), "CDS 440-002".to_string()), ("id9".to_string(), "CDS 440-003".to_string())]);
    assert_eq!(r.doc("id2").unwrap().title.as_deref(), Some("Aardvark"));
    assert_eq!(ev.last().map(|e| e.kind.clone()), Some(Kind::Title { doc: "id2".into(), title: "Aardvark".into() }));
    assert!(r.doc("id7").is_none() && r.doc("id8").is_none(), "no division, no events");
    assert!(ev.iter().filter_map(|e| if let Kind::Place { by, .. } = &e.kind { Some(*by) } else { None }).all(|b| b == By::Auto));
}

fn run_library(packs: &Path, out: &Path, extra: &[&Path]) -> std::process::Output {
    let mut c = cli();
    c.arg("library").arg("--packs").arg(packs).arg("--out").arg(out).args(["--id", "r3", "--title", "Revision 3"]);
    for e in extra {
        c.arg(e);
    }
    c.output().unwrap()
}

#[test]
fn labels_and_titles_files_set_the_division_and_the_title() {
    let tmp = tempfile::tempdir().unwrap();
    let packs = tmp.path().join("packs");
    let (a, b) = two_packs(&packs);
    // three more books: one found by its BLAKE3, one whose file name two records share, one with a title line that is not ok
    let c = build(&doc_pdf("Sand", "sand", 2), "sand.pdf");
    let d = build(&doc_pdf("Clay", "clay", 2), "same-name.pdf");
    let e = build(&doc_pdf("Salt", "salt", 2), "salt.pdf");
    for p in [&c, &d, &e] {
        write_pack(p, &packs).unwrap();
    }
    let labels = json!([
        // by file name (the path's last part), with a second division; a name from the default classes
        {"id": "b0001", "path": "/mnt/library/Water/water.pdf", "final": "440", "second_division": "450", "haiku": {"division": "999"}},
        {"id": "b0002", "path": "/mnt/library/Stone/stone.pdf", "final": "unsure", "second_division": null},
        // by BLAKE3
        {"id": "b0003", "path": "/elsewhere/x.pdf", "blake3": c.header.source.blake3, "final": "320", "second_division": null, "label": "Sand and soil"},
        // two records share a file name: neither is used for a pack with that name
        {"id": "b0004", "path": "/a/same-name.pdf", "final": "100", "second_division": null},
        {"id": "b0005", "path": "/b/same-name.pdf", "final": "110", "second_division": null},
    ]);
    let titles = [
        json!({"id": "b0001", "path": "/mnt/library/Water/water.pdf", "title": "How Water Moves", "source_title": "water.pdf", "method": "e2b", "ok": true}),
        json!({"id": "b0002", "path": "/mnt/library/Stone/stone.pdf", "title": "", "source_title": null, "method": "e2b", "ok": true}),
        json!({"id": "x", "path": "/q/salt.pdf", "title": "Bad Salt", "source_title": null, "method": "e2b", "ok": false}),
        json!({"id": "doc-id-match", "blake3": e.header.source.blake3, "path": "/z/other.pdf", "title": "Table Salt", "source_title": null, "method": "e2b", "ok": true}),
    ];
    let lf = tmp.path().join("labels.json");
    let tf = tmp.path().join("titles.jsonl");
    std::fs::write(&lf, labels.to_string()).unwrap();
    std::fs::write(&tf, titles.iter().map(|t| t.to_string()).collect::<Vec<_>>().join("\n") + "\n\n").unwrap();

    let lib = tmp.path().join("lib");
    let out = cli()
        .arg("library")
        .arg("--packs")
        .arg(packs.as_path())
        .arg("--out")
        .arg(lib.as_path())
        .args(["--id", "r3", "--title", "Revision 3", "--labels"])
        .arg(lf.as_path())
        .arg("--titles")
        .arg(tf.as_path())
        .output()
        .unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("labels: 2 matched, 1 ambiguous"), "{stdout}");
    let view = read_json(&lib.join(".local").join("docs.json"));
    let docs = &view["docs"];
    let entry = |p: &Pack| docs[&p.header.doc_id].clone();

    // a: the label overrides the pack's own suggestion; the default class names give the label; the title is replaced
    let ea = entry(&a);
    assert_eq!(ea["shelf"], json!("440"));
    assert_eq!(ea["suggested"]["div"], json!("440"));
    assert_eq!(ea["suggested"]["second_div"], json!("450"));
    assert_eq!(ea["suggested"]["source"], json!("label"));
    assert_eq!(ea["suggested"]["label"], json!("Canning"));
    assert_eq!((ea["suggested"]["score"].clone(), ea["suggested"]["classifier_version"].clone()), (Value::Null, Value::Null));
    assert_eq!((ea["title"].clone(), ea["source_title"].clone()), (json!("How Water Moves"), json!("Water")));
    // b: "unsure" is no division; an empty title leaves the old one
    let eb = entry(&b);
    assert_eq!((eb["shelf"].clone(), eb["title"].clone(), eb["source_title"].clone()), (Value::Null, json!("Stone"), Value::Null));
    // c: found by BLAKE3, the label from the file
    let ec = entry(&c);
    assert_eq!((ec["shelf"].clone(), ec["suggested"]["label"].clone(), ec["suggested"]["source"].clone()), (json!("320"), json!("Sand and soil"), json!("label")));
    // d: two records share the file name, so no label
    assert_eq!(entry(&d)["shelf"], Value::Null);
    // e: the not-ok title line is skipped, the BLAKE3 one is used
    let ee = entry(&e);
    assert_eq!((ee["title"].clone(), ee["source_title"].clone()), (json!("Table Salt"), json!("Salt")));
    // the seed log records the divisions and the replaced titles, so the view can be made again from the log and the packs
    let seed = std::fs::read_to_string(lib.join("log").join("builder-r3.jsonl")).unwrap();
    assert!(seed.contains(&format!(r#""ev":"title","doc":"{}","title":"How Water Moves""#, a.header.doc_id)), "{seed}");
    assert!(seed.contains(&format!(r#""ev":"title","doc":"{}","title":"Table Salt""#, e.header.doc_id)));
    std::fs::remove_file(lib.join(".local").join("docs.json")).unwrap();
    let again = cli().arg("view").arg("--library").arg(lib.as_path()).arg("--packs").arg(packs.as_path()).output().unwrap();
    assert!(again.status.success(), "{}", String::from_utf8_lossy(&again.stderr));
    let rebuilt = read_json(&lib.join(".local").join("docs.json"));
    // titles from the log, divisions (shelf) from the log; the label's own details are in the packs only, so the rebuild shows
    // the packs' suggestion but the same shelf and title
    for p in [&a, &b, &c, &d, &e] {
        let id = &p.header.doc_id;
        assert_eq!((rebuilt["docs"][id]["shelf"].clone(), rebuilt["docs"][id]["title"].clone(), rebuilt["docs"][id]["call"].clone()), (docs[id]["shelf"].clone(), docs[id]["title"].clone(), docs[id]["call"].clone()));
    }

    // the new title is the library's title: documents.tsv and the payloads
    let tsv = std::fs::read_to_string(lib.join("documents.tsv")).unwrap();
    assert!(tsv.contains("How Water Moves") && !tsv.contains("\tWater\t"), "{tsv}");
    let shard = cache_search::library::open_shard_for_scroll(&lib.join("shard")).unwrap();
    let mut sr = edge::ScrollRequest::new();
    sr.limit = Some(1000);
    sr.with_payload = Some(edge::WithPayloadInterface::Bool(true));
    sr.with_vector = edge::WithVector::Bool(false);
    let (recs, _) = edge::EdgeShardRead::scroll(&shard, sr).unwrap();
    let titles_in_payloads: std::collections::BTreeSet<String> = recs.iter().map(|r| r.payload.as_ref().unwrap().0["title"].as_str().unwrap().to_string()).collect();
    assert!(titles_in_payloads.contains("How Water Moves") && !titles_in_payloads.contains("Water"));

    // without the options the pack's own division and title stand
    let plain = tmp.path().join("plain");
    let o = run_library(&packs, &plain, &[]);
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    let plain_docs = read_json(&plain.join(".local").join("docs.json"));
    assert_eq!(plain_docs["docs"][&a.header.doc_id]["suggested"]["source"], json!("classifier"));
    assert_eq!(plain_docs["docs"][&a.header.doc_id]["title"], json!("Water"));

    // a labels file that is not a list is refused before anything is written
    let bad = tmp.path().join("bad.json");
    std::fs::write(&bad, "{}").unwrap();
    let out = cli().arg("library").arg("--packs").arg(packs.as_path()).arg("--out").arg(tmp.path().join("nolib")).args(["--id", "r3", "--title", "T", "--labels"]).arg(bad.as_path()).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
    assert!(!tmp.path().join("nolib").exists());
}

fn dir_bytes(dir: &Path) -> u64 {
    std::fs::read_dir(dir)
        .unwrap()
        .map(|e| {
            let p = e.unwrap().path();
            if p.is_dir() {
                dir_bytes(&p)
            } else {
                std::fs::metadata(&p).unwrap().len()
            }
        })
        .sum()
}

/// The same packs written both ways: the shard configs say so, and every query has the same top-1 in both.
fn f16_vs_f32(tmp: &Path) {
    use cache_builder::embed::fake_vector;
    use cache_builder::library::VectorDatatype;
    let packs = tmp.join("packs");
    let mut texts = Vec::new();
    for (title, topic) in [("Water", "water"), ("Stone", "stone"), ("Sand", "sand"), ("Clay", "clay")] {
        let p = build(&doc_pdf(title, topic, 3), &format!("{topic}.pdf"));
        texts.extend(p.pieces.iter().map(|x| x.text.clone()));
        write_pack(&p, &packs).unwrap();
    }
    let mk = |name: &str, dt: VectorDatatype| {
        let out = tmp.join(name);
        let o = LibraryOptions { vector_datatype: dt, archive: false, ..library_opts() };
        build_library(&packs, &out, &o).unwrap();
        out
    };
    let (a, b) = (mk("f32", VectorDatatype::F32), mk("f16", VectorDatatype::F16));
    // the f16 shard says so in its own config and its segment; cache-library.json has no field for it and is the same
    let datatype = |d: &Path| -> (String, String) {
        let cfg: Value = serde_json::from_slice(&std::fs::read(d.join("shard/edge_config.json")).unwrap()).unwrap();
        let seg = std::fs::read_dir(d.join("shard/segments")).unwrap().next().unwrap().unwrap().path().join("segment.json");
        let seg: Value = serde_json::from_slice(&std::fs::read(seg).unwrap()).unwrap();
        (cfg["vectors"][""]["datatype"].as_str().unwrap().to_string(), seg["config"]["vector_data"][""]["datatype"].as_str().unwrap().to_string())
    };
    assert_eq!(datatype(&a), ("float32".to_string(), "float32".to_string()));
    assert_eq!(datatype(&b), ("float16".to_string(), "float16".to_string()));
    assert_eq!(std::fs::read(a.join(SETTINGS_FILE)).unwrap(), std::fs::read(b.join(SETTINGS_FILE)).unwrap());
    let open = |d: &Path| {
        let s: Value = serde_json::from_slice(&std::fs::read(d.join(SETTINGS_FILE)).unwrap()).unwrap();
        cache_search::library::open_library(&d.join("shard"), None, Some(&s)).unwrap()
    };
    let (sa, sb) = (open(&a), open(&b));
    assert_eq!((sa.docs, sb.docs), (texts.len(), texts.len()));
    // queries are f32 (the pieces' own vectors, and a nearby one); both libraries answer with the same top-1
    for t in texts.iter().step_by(3) {
        let v = fake_vector(t);
        let mut near = v.clone();
        near.iter_mut().step_by(7).for_each(|x| *x *= 1.02);
        for q in [&v, &near] {
            let ha = sa.dense_search(q, 1, 1, 200).unwrap();
            let hb = sb.dense_search(q, 1, 1, 200).unwrap();
            // the test books repeat their sentences, so equal pieces tie exactly: compare what the hit says, not its point id or page
            assert_eq!(ha[0].snippet, hb[0].snippet, "top-1 differs for {t:.40}");
        }
    }
}

#[test]
fn an_f16_library_opens_and_answers_like_the_f32_one_in_less_space() {
    let tmp = tempfile::tempdir().unwrap();
    f16_vs_f32(tmp.path());

    // the command line takes the option, and refuses anything else
    let packs = tmp.path().join("packs");
    let out = cli().arg("library").arg("--packs").arg(packs.as_path()).arg("--out").arg(tmp.path().join("cli16")).args(["--id", "r3", "--title", "T", "--vector-datatype", "f16"]).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let out = cli().arg("library").arg("--packs").arg(packs.as_path()).arg("--out").arg(tmp.path().join("cli8")).args(["--id", "r3", "--title", "T", "--vector-datatype", "f8"]).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
}

/// Edge keeps vectors in 32 MiB chunks it creates whole, so a small library is the same size either way; f16 holds twice the
/// vectors per chunk (16384 against 8192 of 1024 dimensions). 9000 pieces need two chunks as f32 and one as f16.
#[test]
fn an_f16_shard_is_smaller_once_the_vectors_fill_a_chunk_and_still_finds_the_same_top_1() {
    use cache_builder::embed::fake_vector;
    use cache_builder::library::{write_library, LibDoc, VectorDatatype};
    use cache_builder::pack::PackPiece;
    let pieces: Vec<PackPiece> = (0..9000u32)
        .map(|i| {
            let text = format!("passage number {i} about subject {} and detail {}", i % 97, i % 13);
            PackPiece {
                index: i,
                vector: fake_vector(&text),
                text,
                page: "1".into(),
                pdf_page: Some(1),
                page_end: None,
                pdf_page_end: None,
                heading_path: vec![],
            }
        })
        .collect();
    let doc = || LibDoc {
        title: "Big".into(),
        doc_id: "big".into(),
        doc_version: 1,
        source_blake3: "ab".repeat(32),
        original_blake3: None,
        link: String::new(),
        author: None,
        zim: None,
        pages: Some(1),
        pieces: pieces.clone(),
        entry: None,
    };
    let tmp = tempfile::tempdir().unwrap();
    let mk = |name: &str, dt: VectorDatatype| {
        let out = tmp.path().join(name);
        let o = LibraryOptions { vector_datatype: dt, archive: false, ..library_opts() };
        write_library(&out, &o, [doc()]).unwrap();
        out
    };
    let (a, b) = (mk("f32", VectorDatatype::F32), mk("f16", VectorDatatype::F16));
    let (sa, sb) = (dir_bytes(&a.join("shard")), dir_bytes(&b.join("shard")));
    assert!(sb + 30 * 1024 * 1024 < sa, "f16 {sb} bytes, f32 {sa} bytes");
    let open = |d: &Path| {
        let s: Value = serde_json::from_slice(&std::fs::read(d.join(SETTINGS_FILE)).unwrap()).unwrap();
        cache_search::library::open_library(&d.join("shard"), None, Some(&s)).unwrap()
    };
    let (la, lb) = (open(&a), open(&b));
    assert_eq!((la.docs, lb.docs), (9000, 9000));
    for i in [0usize, 777, 4500, 8999] {
        let mut q = pieces[i].vector.clone();
        q.iter_mut().step_by(5).for_each(|x| *x *= 1.03);
        let ha = la.dense_search(&q, 1, 1, 200).unwrap();
        let hb = lb.dense_search(&q, 1, 1, 200).unwrap();
        assert_eq!(ha[0].address, hb[0].address, "top-1 differs for piece {i}");
        assert_eq!(ha[0].address, format!("lib:r3/{}", cache_builder::library::point_uuid("big", 1, i as u32)), "piece {i} is its own nearest");
    }
}

#[test]
fn a_compression_outcome_and_ocr_travel_in_the_view_when_the_caller_has_them() {
    use cache_builder::compress::CompressionOutcome;
    use cache_builder::embed::fake_vector;
    use cache_builder::library::{write_library, LibDoc};
    use cache_builder::pack::PackPiece;
    let piece = |i: u32| {
        let text = format!("passage {i} of the compressed book");
        PackPiece { index: i, vector: fake_vector(&text), text, page: "1".into(), pdf_page: Some(1), page_end: None, pdf_page_end: None, heading_path: vec![] }
    };
    let doc = |id: &str, c: Option<CompressionOutcome>, ocr: Option<OcrInfo>| {
        let mut e = BookFacts::new(id, None);
        e.compression = c;
        e.ocr = ocr;
        LibDoc {
            title: id.into(),
            doc_id: id.into(),
            doc_version: 1,
            source_blake3: "ab".repeat(32),
            original_blake3: None,
            link: String::new(),
            author: None,
            zim: None,
            pages: Some(1),
            pieces: vec![piece(0), piece(1)],
            entry: Some(e),
        }
    };
    let outcome = CompressionOutcome {
        original_size: 9000,
        stored_size: 4000,
        level: "smaller_scans".into(),
        preset: Some("balanced".into()),
        kept_original: false,
        kept_reason: None,
        psnr_min: Some(41.5),
    };
    let ocr = OcrInfo { engine: "doctr".into(), version: "1.1.0".into(), pages_ocrd: 7, confidence: None };
    let tmp = tempfile::tempdir().unwrap();
    let out = tmp.path().join("lib");
    write_library(&out, &library_opts(), [doc("with", Some(outcome), Some(ocr)), doc("without", None, None)]).unwrap();
    let v = read_json(&out.join(".local").join("docs.json"));
    assert_eq!(v["docs"]["with"]["compression"]["stored_size"], json!(4000));
    assert_eq!(v["docs"]["with"]["compression"]["preset"], json!("balanced"));
    assert_eq!(v["docs"]["with"]["ocr"], json!({"engine": "doctr", "version": "1.1.0", "pages_ocrd": 7}));
    assert_eq!((v["docs"]["without"]["compression"].clone(), v["docs"]["without"]["ocr"].clone()), (Value::Null, Value::Null));
    // no division and no replaced title: no seed log at all
    assert!(!out.join("log").exists());
}
