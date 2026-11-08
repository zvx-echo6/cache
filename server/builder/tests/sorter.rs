//! `cache-build library --classifier`: the books no label placed are filed by the sorter from their vectors. A confident book gets
//! its division as `suggested` (source classifier) and a place and assign in the seed log; any other is left in Unsorted, with its
//! best guess in the view and no place event. A labeled book is not touched. Packs are made up (vectors on axes), no PDFs.

use cache_builder::docs::{default_division_names, Overrides};
use cache_builder::embed::DIMS;
use cache_builder::library::{build_library_with, LibraryOptions};
use cache_builder::pack::{write_pack, BookBlock, Chunker, EmbeddingInfo, Header, Pack, PackPiece, Source, Suggested, Tool, PACK_FORMAT};
use cache_builder::sorter::load_model;
use cache_classify::{encode, Class, ModelSpec, Recipe, Weights};
use serde_json::Value;
use std::path::Path;
use std::process::Command;

const PROSE: &str = "The well note explains how the well works in the field and why it matters to anyone digging a new one by hand";

/// A model over the 1024-dimension vectors: axis 0 votes for division 110, axis 1 for 120, axis 2 for 130. Threshold 0.6.
fn model_bytes(version: u32, sha: &str) -> Vec<u8> {
    let mut sha_bytes = [0u8; 32];
    for (i, b) in sha_bytes.iter_mut().enumerate() {
        *b = u8::from_str_radix(&sha[i * 2..i * 2 + 2], 16).unwrap();
    }
    let mut w = vec![0f32; DIMS * 3];
    for j in 0..3 {
        w[j * 3 + j] = 6.0;
    }
    encode(&ModelSpec {
        classifier_version: version,
        embedding_sha256: sha_bytes,
        dims: DIMS as u32,
        threshold: 0.6,
        recipe: Recipe { first_pieces: 2, spread_pieces: 1 },
        classes: vec![Class { division: 110, label: "A".into() }, Class { division: 120, label: "B".into() }, Class { division: 130, label: "C".into() }],
        bias: vec![0.0; 3],
        weights: Weights::F32(w),
    })
}

fn good_model() -> Vec<u8> {
    model_bytes(2, cache_embed::DECIDED_MODEL_SHA256)
}

fn axis(v: &[(usize, f32)]) -> Vec<f32> {
    let mut x = vec![0f32; DIMS];
    for (i, a) in v {
        x[*i] = *a;
    }
    x
}

fn pack(id: &str, title: &str, text: &str, vector: Vec<f32>, label: Option<&str>) -> Pack {
    let pieces: Vec<PackPiece> = (0..2u32)
        .map(|i| PackPiece { index: i, text: format!("{text} {i}"), page: "1".into(), pdf_page: Some(1), page_end: None, pdf_page_end: None, heading_path: vec![], vector: vector.clone() })
        .collect();
    let suggested = label.map(|d| Suggested { div: d.into(), label: "Labelled".into(), score: None, classifier_version: None, source: "label".into(), second_div: None });
    Pack {
        header: Header {
            cdoc: PACK_FORMAT,
            doc_id: id.into(),
            doc_version: 1,
            title: title.into(),
            source: Source { blake3: format!("{id:0<64}").replace(|c: char| !c.is_ascii_hexdigit(), "a"), size: 1, file_name: format!("{id}.pdf"), https: None },
            extractor: Tool { name: "mupdf".into(), version: "0".into(), layout_version: None },
            chunker: Chunker { version: 1, target_words: 200, max_words: 300 },
            embedding: EmbeddingInfo { embedder: "fake-hash-v1".into(), dims: DIMS },
            created_at: "2026-11-03T00:00:00Z".into(),
            page_count: 1,
            ocr_pages: vec![],
            text_source_ocr_pages: vec![],
            pieces: 2,
            division: None,
            book: Some(BookBlock { title: title.into(), source_title: None, original_blake3: "ab".repeat(32), compression: None, ocr: None, suggested, author: None, edition: None, year: None }),
            samebook: None,
        },
        pieces,
    }
}

fn packs(dir: &Path) {
    // A: confident (axis 1 = division 120). B: between 110 and 130, not sure. C: labeled 440. D: no real text.
    for p in [
        pack("a1", "Alpha", PROSE, axis(&[(1, 1.0)]), None),
        pack("b1", "Bravo", PROSE, axis(&[(0, 1.0), (2, 1.0)]), None),
        pack("c1", "Charlie", PROSE, axis(&[(1, 1.0)]), Some("440")),
        pack("d1", "Delta", "1 2 3 4 5", axis(&[(1, 1.0)]), None),
    ] {
        write_pack(&p, dir).unwrap();
    }
}

fn opts(archive: bool) -> LibraryOptions {
    LibraryOptions { id: "sorted".into(), title: "Sorted".into(), version: "1".into(), vector_datatype: Default::default(), archive, built_at: 1793491200000 }
}

fn read_json(p: &Path) -> Value {
    serde_json::from_slice(&std::fs::read(p).unwrap()).unwrap()
}

#[test]
fn the_sorter_files_the_unplaced_books_and_leaves_the_unsure_ones_in_unsorted() {
    let tmp = tempfile::tempdir().unwrap();
    let pk = tmp.path().join("packs");
    packs(&pk);
    let lib = tmp.path().join("lib");
    let over = Overrides { names: default_division_names(), sorter: Some(load_model(&good_model()).unwrap()), ..Default::default() };
    let (report, _) = build_library_with(&pk, &lib, &opts(false), &over).unwrap();

    // the report: the three the sorter looked at (not the labeled one)
    let mut rows = report.sorter.clone();
    rows.sort_by(|a, b| a.doc_id.cmp(&b.doc_id));
    assert_eq!(rows.iter().map(|r| r.doc_id.as_str()).collect::<Vec<_>>(), ["a1", "b1", "d1"]);
    assert_eq!((rows[0].division.as_deref(), rows[0].unsure.as_deref(), rows[0].classifier_version), (Some("120"), None, 2));
    assert!(rows[0].score > 0.9 && rows[0].top.len() == 3 && rows[0].top[0].division == "120");
    assert_eq!((rows[1].division.clone(), rows[1].unsure.as_deref()), (None, Some("low")));
    assert!(rows[1].score < 0.6 && !rows[1].top.is_empty());
    assert_eq!((rows[2].division.clone(), rows[2].unsure.as_deref(), rows[2].top.len()), (None, Some("no_text"), 0));

    // the seed log: place and assign for the sorted book and the labeled one; nothing for the unsure ones
    let log = std::fs::read_to_string(lib.join("log").join("builder-sorted.jsonl")).unwrap();
    assert!(log.contains(r#""ev":"place","doc":"a1","div":"120","by":"auto""#), "{log}");
    assert!(log.contains(r#""ev":"place","doc":"c1","div":"440","by":"auto""#), "{log}");
    assert!(!log.contains(r#""doc":"b1""#) && !log.contains(r#""doc":"d1""#), "{log}");

    // the view: the sorter's answer as suggested (classifier, score, second choice, version); the unsure book has its guess and no shelf
    let v = read_json(&lib.join(".local").join("docs.json"));
    let a = &v["docs"]["a1"];
    assert_eq!((a["shelf"].clone(), a["suggested"]["source"].clone(), a["suggested"]["div"].clone(), a["suggested"]["classifier_version"].clone()), ("120".into(), "classifier".into(), "120".into(), 2.into()));
    assert!(a["suggested"]["score"].as_f64().unwrap() > 0.9 && a["suggested"]["second_div"].is_string());
    assert_eq!(a["call"]["text"], Value::from("CDS 120-001"));
    let b = &v["docs"]["b1"];
    assert_eq!((b["shelf"].clone(), b["call"].clone(), b["suggested"]["source"].clone()), (Value::Null, Value::Null, "classifier".into()));
    assert!(b["suggested"]["score"].as_f64().unwrap() < 0.6);
    assert_eq!(v["docs"]["c1"]["suggested"]["source"], Value::from("label"));
    assert_eq!(v["docs"]["c1"]["shelf"], Value::from("440"));
    assert_eq!(v["docs"]["d1"]["suggested"], Value::Null);
    assert_eq!(v["docs"]["d1"]["shelf"], Value::Null);
}

#[test]
fn without_a_classifier_the_unlabelled_books_stay_unsorted_as_before() {
    let tmp = tempfile::tempdir().unwrap();
    let pk = tmp.path().join("packs");
    packs(&pk);
    let lib = tmp.path().join("lib");
    let (report, _) = build_library_with(&pk, &lib, &opts(false), &Overrides::default()).unwrap();
    assert!(report.sorter.is_empty());
    let log = std::fs::read_to_string(lib.join("log").join("builder-sorted.jsonl")).unwrap();
    assert_eq!(log.lines().count(), 2, "only the labeled book is placed: {log}");
}

#[test]
fn a_model_trained_on_another_embedder_is_refused() {
    assert!(load_model(&good_model()).is_ok());
    let e = load_model(&model_bytes(2, &"ab".repeat(32))).unwrap_err();
    assert!(e.0.contains("another embedding model"), "{e}");
    assert!(load_model(b"damaged").is_err());
}

#[test]
fn the_command_line_takes_the_model_and_writes_the_report() {
    let tmp = tempfile::tempdir().unwrap();
    let pk = tmp.path().join("packs");
    packs(&pk);
    let model = tmp.path().join("cache-classifier-2.bin");
    std::fs::write(&model, good_model()).unwrap();
    let report = tmp.path().join("sorter.tsv");
    let run = |out: &str, extra: &[&Path]| {
        let mut c = Command::new(env!("CARGO_BIN_EXE_cache-build"));
        c.arg("library").arg("--packs").arg(&pk).arg("--out").arg(tmp.path().join(out)).args(["--id", "sorted", "--title", "Sorted", "--built-at", "1793491200000"]);
        for e in extra {
            c.arg(e);
        }
        c.output().unwrap()
    };
    let out = run("lib", &[Path::new("--classifier"), model.as_path(), Path::new("--sorter-report"), report.as_path()]);
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let stdout = String::from_utf8_lossy(&out.stdout);
    assert!(stdout.contains("sorter: 3 books looked at, 1 filed, 2 left in Unsorted"), "{stdout}");
    let tsv = std::fs::read_to_string(&report).unwrap();
    let rows: Vec<Vec<&str>> = tsv.lines().skip(1).map(|l| l.split('\t').collect()).collect();
    assert_eq!(tsv.lines().next().unwrap(), "doc_id\tfile_name\ttitle\tclassifier_version\tdivision\tscore\tdecision\ttop3\treason");
    let row = |id: &str| rows.iter().find(|r| r[0] == id).unwrap().clone();
    assert_eq!((row("a1")[4], row("a1")[6], row("a1")[3]), ("120", "Filed", "2"));
    assert!(row("a1")[7].starts_with("120=0.99"), "{:?}", row("a1"));
    assert_eq!((row("b1")[4], row("b1")[6], row("b1")[8]), ("", "Unsorted", "low"));
    assert_eq!((row("d1")[6], row("d1")[8]), ("Unsorted", "no_text"));
    assert!(rows.iter().all(|r| r[0] != "c1"));
    // refused: a model for another embedder, a report with no model
    let bad = tmp.path().join("bad.bin");
    std::fs::write(&bad, model_bytes(2, &"ab".repeat(32))).unwrap();
    let out = run("lib2", &[Path::new("--classifier"), bad.as_path()]);
    assert_eq!(out.status.code(), Some(2));
    assert!(!tmp.path().join("lib2").exists());
    let out = run("lib3", &[Path::new("--sorter-report"), report.as_path()]);
    assert_eq!(out.status.code(), Some(2));
}
