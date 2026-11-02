//! Pack revision 3 (`division`, `samebook`), the better-copy order, `docs.json` and the `--labels` / `--titles` options of
//! `cache-build library`.

mod common;

use cache_builder::build::{build_pack, BuildOptions};
use cache_builder::docs::{Docs, DOCS_FILE};
use cache_builder::embed::FakeEmbedder;
use cache_builder::library::{build_library, LibraryOptions, SETTINGS_FILE, SUMS_FILE};
use cache_builder::pack::{f16_to_f32, f32_to_f16, pack_bytes, read_pack, read_pack_bytes, write_pack, Division, Pack, Samebook};
use cache_builder::samebook::{best_copy, CopyQuality};
use common::*;
use serde_json::{json, Value};
use std::io::{Read, Write};
use std::path::Path;
use std::process::Command;

const STAMP: &str = "2026-11-01T00:00:00Z";

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

#[test]
fn a_revision_3_pack_round_trips_and_older_packs_still_load() {
    let pdf = doc_pdf("Water cycle", "water", 3);
    let mut pack = build(&pdf, "water.pdf");
    let sb = pack.header.samebook.clone().expect("the builder writes samebook");
    assert_eq!(sb.pages, 3);
    assert_eq!(sb.source_size, pdf.len() as u64);
    assert_eq!(sb.minhash.len(), 128);
    assert_eq!(sb.mean_vector.len(), 1024);
    assert!(sb.text_pages >= 1 && sb.text_pages <= 3);
    pack.header.division = Some(Division {
        division: "440".into(),
        label: "Water".into(),
        score: Some(0.875),
        classifier_version: Some(3),
        source: "sorter".into(),
        second_division: Some("450".into()),
    });
    let bytes = pack_bytes(&pack).unwrap();
    assert_eq!(read_pack_bytes(&bytes).unwrap(), pack, "a revision 3 pack reads back equal");
    assert_eq!(bytes, pack_bytes(&pack).unwrap(), "and is deterministic");
    let h = header_json(&bytes);
    assert_eq!(h["cdoc"], json!(1));
    assert_eq!(h["division"]["division"], json!("440"));
    assert_eq!(h["division"]["second_division"], json!("450"));
    assert_eq!(h["samebook"]["minhash"].as_array().unwrap().len(), 128);
    // 1024 halves = 2048 bytes = 2732 base64 characters
    assert_eq!(h["samebook"]["mean_vector"].as_str().unwrap().len(), 2732);

    // an older pack has neither key and loads, with both None
    let old = rewrite_header(&bytes, |h| {
        h.remove("division");
        h.remove("samebook");
    });
    let back = read_pack_bytes(&old).unwrap();
    assert!(back.header.division.is_none() && back.header.samebook.is_none());
    assert_eq!(back.pieces, pack.pieces);

    // an older reader ignores the new keys: every key it knows is still there with the same value
    let before = header_json(&old);
    let after = header_json(&bytes);
    for (k, v) in before.as_object().unwrap() {
        assert_eq!(&after[k], v, "{k}");
    }

    // a division with a source this reader does not know is refused; null score and second division are fine
    let bad = rewrite_header(&bytes, |h| h["division"]["source"] = json!("guess"));
    assert!(read_pack_bytes(&bad).is_err());
    let nulls = rewrite_header(&bytes, |h| {
        h["division"]["score"] = Value::Null;
        h["division"]["classifier_version"] = Value::Null;
        h["division"]["second_division"] = Value::Null;
        h["division"]["source"] = json!("user");
    });
    let d = read_pack_bytes(&nulls).unwrap().header.division.unwrap();
    assert_eq!((d.score, d.classifier_version, d.second_division, d.source.as_str()), (None, None, None, "user"));
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
    LibraryOptions { id: "r3".into(), title: "Revision 3".into(), version: "1".into(), vector_datatype: Default::default(), archive: true }
}

fn two_packs(dir: &Path) -> (Pack, Pack) {
    let mut a = build(&doc_pdf("Water", "water", 2), "water.pdf");
    a.header.division = Some(Division { division: "440".into(), label: "Water".into(), score: Some(0.5), classifier_version: Some(2), source: "sorter".into(), second_division: None });
    let b = build(&doc_pdf("Stone", "stone", 2), "stone.pdf");
    write_pack(&a, dir).unwrap();
    write_pack(&b, dir).unwrap();
    (a, b)
}

#[test]
fn docs_json_is_written_atomically_listed_and_never_in_a_payload() {
    let tmp = tempfile::tempdir().unwrap();
    let packs = tmp.path().join("packs");
    let (a, b) = two_packs(&packs);
    let lib = tmp.path().join("lib");
    let r = build_library(&packs, &lib, &library_opts()).unwrap();

    // listed in cache-library.json (the guide-schema test pins that this is the only added key)
    let settings: Value = serde_json::from_slice(&std::fs::read(lib.join(SETTINGS_FILE)).unwrap()).unwrap();
    assert_eq!(settings["docs"], json!("docs.json"));
    // well formed, in doc_id order, every key present
    let raw = std::fs::read(lib.join(DOCS_FILE)).unwrap();
    let docs = Docs::from_bytes(&raw).unwrap();
    assert_eq!(docs.format, 1);
    assert_eq!(docs.docs.len(), 2);
    let ea = &docs.docs[&a.header.doc_id];
    assert_eq!((ea.division.as_deref(), ea.label.as_deref(), ea.source.as_deref(), ea.score, ea.classifier_version), (Some("440"), Some("Water"), Some("sorter"), Some(0.5), Some(2)));
    let eb = &docs.docs[&b.header.doc_id];
    assert_eq!((eb.division.clone(), eb.source.clone(), eb.second_division.clone(), eb.title.as_str()), (None, None, None, "Stone"));
    let v: Value = serde_json::from_slice(&raw).unwrap();
    for k in ["division", "label", "score", "classifier_version", "source", "second_division", "title", "source_title"] {
        assert!(v["docs"][&b.header.doc_id].as_object().unwrap().contains_key(k), "{k} is always written, null when unknown");
    }
    // atomic: no temporary file is left, and the file is covered by SHA256SUMS
    assert!(std::fs::read_dir(&lib).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().ends_with(".tmp")));
    let sums = std::fs::read_to_string(lib.join(SUMS_FILE)).unwrap();
    assert!(sums.lines().any(|l| l.ends_with("  docs.json")));
    // a rewrite replaces the file whole and leaves no temporary behind
    cache_builder::docs::write_docs(&lib, &Docs::default()).unwrap();
    assert_eq!(Docs::from_bytes(&std::fs::read(lib.join(DOCS_FILE)).unwrap()).unwrap().docs.len(), 0);
    assert!(!lib.join(".docs.json.tmp").exists());
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
            assert!(!["division", "label", "second_division", "samebook", "source_title"].contains(&k.as_str()), "{k} is in a payload");
        }
    }
    // the .cache-library carries it too
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
    assert!(names.contains(&"docs.json".to_string()) && names.contains(&"cache-library.json".to_string()), "{names:?}");
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
    let docs = Docs::from_bytes(&std::fs::read(lib.join(DOCS_FILE)).unwrap()).unwrap().docs;

    // a: the label overrides the pack's own division; the default class names give the label; the title is replaced
    let ea = &docs[&a.header.doc_id];
    assert_eq!(ea.division.as_deref(), Some("440"));
    assert_eq!(ea.second_division.as_deref(), Some("450"));
    assert_eq!(ea.source.as_deref(), Some("label"));
    assert_eq!(ea.label.as_deref(), Some("Canning"));
    assert_eq!((ea.score, ea.classifier_version), (None, None));
    assert_eq!((ea.title.as_str(), ea.source_title.as_deref()), ("How Water Moves", Some("Water")));
    // b: "unsure" is no division; an empty title leaves the old one
    let eb = &docs[&b.header.doc_id];
    assert_eq!((eb.division.clone(), eb.title.as_str(), eb.source_title.clone()), (None, "Stone", None));
    // c: found by BLAKE3, the label from the file
    let ec = &docs[&c.header.doc_id];
    assert_eq!((ec.division.as_deref(), ec.label.as_deref(), ec.source.as_deref()), (Some("320"), Some("Sand and soil"), Some("label")));
    // d: two records share the file name, so no label
    assert_eq!(docs[&d.header.doc_id].division, None);
    // e: the not-ok title line is skipped, the BLAKE3 one is used
    assert_eq!((docs[&e.header.doc_id].title.as_str(), docs[&e.header.doc_id].source_title.as_deref()), ("Table Salt", Some("Salt")));

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
    let plain_docs = Docs::from_bytes(&std::fs::read(plain.join(DOCS_FILE)).unwrap()).unwrap().docs;
    assert_eq!(plain_docs[&a.header.doc_id].source.as_deref(), Some("sorter"));
    assert_eq!(plain_docs[&a.header.doc_id].title, "Water");

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

/// The shard sizes (f32, f16) of the same packs written both ways, and the top-1 of each query in both.
fn f16_vs_f32(tmp: &Path) -> (u64, u64) {
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
    // the f16 shard says so in its own config; cache-library.json is the same apart from nothing (no field for it)
    let cfg = std::fs::read_to_string(b.join("shard/edge_config.json")).unwrap_or_default();
    if !cfg.is_empty() {
        assert!(cfg.to_lowercase().contains("float16"), "{cfg}");
        assert!(!std::fs::read_to_string(a.join("shard/edge_config.json")).unwrap().to_lowercase().contains("float16"));
    }
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
            assert_eq!(ha[0].address, hb[0].address, "top-1 differs for {t:.40}");
        }
    }
    (dir_bytes(&a.join("shard")), dir_bytes(&b.join("shard")))
}

#[test]
fn an_f16_library_opens_and_answers_like_the_f32_one_in_less_space() {
    let tmp = tempfile::tempdir().unwrap();
    let (f32_bytes, f16_bytes) = f16_vs_f32(tmp.path());
    assert!(f16_bytes < f32_bytes, "f16 {f16_bytes} bytes, f32 {f32_bytes} bytes");

    // the command line takes the option, and refuses anything else
    let packs = tmp.path().join("packs");
    let out = cli().arg("library").arg("--packs").arg(packs.as_path()).arg("--out").arg(tmp.path().join("cli16")).args(["--id", "r3", "--title", "T", "--vector-datatype", "f16"]).output().unwrap();
    assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    let out = cli().arg("library").arg("--packs").arg(packs.as_path()).arg("--out").arg(tmp.path().join("cli8")).args(["--id", "r3", "--title", "T", "--vector-datatype", "f8"]).output().unwrap();
    assert_eq!(out.status.code(), Some(2));
}
