//! Optional `book.author`, `book.edition` and `book.year`: read from a `--titles` file, written into the pack's `book` block
//! only when present, and (for `cache-build library`, which never rewrites packs) left out of its output.

mod common;

use cache_builder::pack::{pack_bytes, read_header, read_pack, read_pack_bytes};
use common::*;
use serde_json::{json, Value};
use std::io::Read;
use std::path::Path;
use std::process::Command;

const STAMP: &str = "2026-11-01T00:00:00Z";

fn cli() -> Command {
    Command::new(env!("CARGO_BIN_EXE_cache-build"))
}

fn doc_pdf(title: &str, topic: &str) -> Vec<u8> {
    let mut p = Page::new();
    p.line(45.0, 40.0, 14.0, Font::Regular, "Heading 1");
    let text = format!("The {topic} moves through the ground and the roots of the trees take it up before the sun draws it out again. ").repeat(8);
    p.block(45.0, 80.0, 10.0, Font::Regular, &wrap(&text, 70).iter().map(|s| s.as_str()).collect::<Vec<_>>());
    make_pdf(&[p], Some(title))
}

/// The pack's first line as raw JSON (to see which keys are really written).
fn header_json(path: &Path) -> Value {
    let bytes = std::fs::read(path).unwrap();
    let mut s = String::new();
    flate2::read::GzDecoder::new(&bytes[..]).read_to_string(&mut s).unwrap();
    serde_json::from_str(s.lines().next().unwrap()).unwrap()
}

fn build_pdf(dir: &Path, name: &str, pdf: &[u8], out: &Path, extra: &[&std::ffi::OsStr]) -> (String, String) {
    let p = dir.join(name);
    std::fs::write(&p, pdf).unwrap();
    let o = cli().arg("pdf").arg(&p).arg("--out").arg(out).args(["--fake-embedder", "--in-process", "--created-at", STAMP]).args(extra).output().unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    (String::from_utf8_lossy(&o.stdout).into_owned(), blake3::hash(pdf).to_hex().to_string())
}

#[test]
fn book_block_has_the_facts_only_when_present() {
    let tmp = tempfile::tempdir().unwrap();
    let pdf = doc_pdf("Water cycle", "water");

    // no titles file: none of the three keys, not even null
    let plain = tmp.path().join("plain");
    let (_, hash) = build_pdf(tmp.path(), "water.pdf", &pdf, &plain, &[]);
    let book = header_json(&plain.join(format!("{hash}@1.cdoc")))["book"].clone();
    for k in ["author", "edition", "year"] {
        assert!(book.get(k).is_none(), "{k} written with no value: {book}");
    }
    assert!(book.get("source_title").is_some(), "the existing keys stay: {book}");

    // all three, from a titles file; the year is a JSON integer
    let titles = tmp.path().join("titles.jsonl");
    std::fs::write(&titles, json!({"path": "/x/water.pdf", "title": "How Water Moves", "ok": true, "author": "  A. Writer ", "edition": "7th edition", "year": 2018}).to_string() + "\n").unwrap();
    let full = tmp.path().join("full");
    let (stdout, _) = build_pdf(tmp.path(), "water.pdf", &pdf, &full, &["--titles".as_ref(), titles.as_os_str()]);
    let book = header_json(&full.join(format!("{hash}@1.cdoc")))["book"].clone();
    assert_eq!((book["author"].clone(), book["edition"].clone(), book["year"].clone()), (json!("A. Writer"), json!("7th edition"), json!(2018)));
    assert_eq!(book["title"], json!("How Water Moves"));
    assert!(stdout.contains("given to 1 documents, 0 values dropped"), "{stdout}");
    // the typed header reads them back, and a title change (the server's rename) keeps them
    let mut pack = read_pack(&full.join(format!("{hash}@1.cdoc"))).unwrap();
    pack.header.set_title("Renamed");
    let back = read_pack_bytes(&pack_bytes(&pack).unwrap()).unwrap();
    let b = back.header.book.unwrap();
    assert_eq!((b.author.as_deref(), b.edition.as_deref(), b.year), (Some("A. Writer"), Some("7th edition"), Some(2018)));
}

#[test]
fn bad_values_are_dropped_one_by_one_and_a_line_without_a_title_still_gives_facts() {
    let tmp = tempfile::tempdir().unwrap();
    let pdf = doc_pdf("Water cycle", "water");
    // a bad year and an over-long edition are dropped; the good author and the title stay
    let t1 = tmp.path().join("t1.jsonl");
    std::fs::write(&t1, json!({"path": "water.pdf", "title": "Good Title", "ok": true, "author": "A. Writer", "edition": "e".repeat(61), "year": 1399}).to_string() + "\n").unwrap();
    let o1 = tmp.path().join("o1");
    let (stdout, hash) = build_pdf(tmp.path(), "water.pdf", &pdf, &o1, &["--titles".as_ref(), t1.as_os_str()]);
    assert!(stdout.contains("2 values dropped"), "{stdout}");
    let book = header_json(&o1.join(format!("{hash}@1.cdoc")))["book"].clone();
    assert_eq!((book["title"].clone(), book["author"].clone()), (json!("Good Title"), json!("A. Writer")));
    assert!(book.get("edition").is_none() && book.get("year").is_none(), "{book}");

    // no title and ok=false: the title stays, the facts still apply; an empty author and a string year are dropped
    let t2 = tmp.path().join("t2.jsonl");
    std::fs::write(&t2, [
        json!({"path": "water.pdf", "title": "Ignored", "ok": false, "edition": "2nd edition", "year": 2100, "author": "   "}),
    ].iter().map(|v| v.to_string()).collect::<Vec<_>>().join("\n") + "\n").unwrap();
    let o2 = tmp.path().join("o2");
    let (stdout, _) = build_pdf(tmp.path(), "water.pdf", &pdf, &o2, &["--titles".as_ref(), t2.as_os_str()]);
    assert!(stdout.contains("1 values dropped"), "{stdout}");
    let book = header_json(&o2.join(format!("{hash}@1.cdoc")))["book"].clone();
    assert_eq!(book["title"], json!("Water cycle"));
    assert_eq!((book["edition"].clone(), book["year"].clone()), (json!("2nd edition"), json!(2100)));
    assert!(book.get("author").is_none(), "{book}");

    // a year that is a string or a float is not an integer: dropped
    let t3 = tmp.path().join("t3.jsonl");
    std::fs::write(&t3, json!({"path": "water.pdf", "author": "Only Author", "year": "2018"}).to_string() + "\n" + &json!({"path": "other.pdf", "year": 2018.5}).to_string() + "\n").unwrap();
    let o3 = tmp.path().join("o3");
    let (stdout, _) = build_pdf(tmp.path(), "water.pdf", &pdf, &o3, &["--titles".as_ref(), t3.as_os_str()]);
    assert!(stdout.contains("2 values dropped"), "{stdout}");
    let book = header_json(&o3.join(format!("{hash}@1.cdoc")))["book"].clone();
    assert_eq!((book["author"].clone(), book["title"].clone()), (json!("Only Author"), json!("Water cycle")));
    assert!(book.get("year").is_none());
}

#[test]
fn the_library_path_does_not_rewrite_packs() {
    let tmp = tempfile::tempdir().unwrap();
    let packs = tmp.path().join("packs");
    let (_, hash) = build_pdf(tmp.path(), "water.pdf", &doc_pdf("Water cycle", "water"), &packs, &[]);
    let pack_path = packs.join(format!("{hash}@1.cdoc"));
    let before = std::fs::read(&pack_path).unwrap();
    let titles = tmp.path().join("t.jsonl");
    std::fs::write(&titles, json!({"path": "water.pdf", "title": "How Water Moves", "author": "A. Writer", "year": 2018}).to_string() + "\n").unwrap();
    let lib = tmp.path().join("lib");
    let o = cli().arg("library").arg("--packs").arg(&packs).arg("--out").arg(&lib).args(["--id", "r", "--title", "R", "--titles"]).arg(&titles).output().unwrap();
    assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
    let stdout = String::from_utf8_lossy(&o.stdout);
    assert!(stdout.contains("author/edition/year given to 1 documents"), "{stdout}");
    assert_eq!(std::fs::read(&pack_path).unwrap(), before, "library must not touch the packs");
    // rebuilding the pack from the PDF with the same titles file is what writes the facts
    let again = tmp.path().join("again");
    let (_, _) = build_pdf(tmp.path(), "water.pdf", &doc_pdf("Water cycle", "water"), &again, &["--titles".as_ref(), titles.as_os_str()]);
    let h = read_header(&again.join(format!("{hash}@1.cdoc"))).unwrap();
    assert_eq!(h.book.unwrap().author.as_deref(), Some("A. Writer"));
}

#[test]
fn the_seed_log_gets_facts_events_after_the_titles_and_is_byte_identical_across_runs() {
    let tmp = tempfile::tempdir().unwrap();
    let packs = tmp.path().join("packs");
    let (_, h1) = build_pdf(tmp.path(), "water.pdf", &doc_pdf("Water cycle", "water"), &packs, &[]);
    let (_, h2) = build_pdf(tmp.path(), "stone.pdf", &doc_pdf("Stone work", "stone"), &packs, &[]);
    let titles = tmp.path().join("t.jsonl");
    // water: a title and all three facts, the year invalid (dropped); stone: only an edition, no title change
    std::fs::write(
        &titles,
        json!({"path": "water.pdf", "title": "How Water Moves", "ok": true, "author": " A. Writer ", "edition": "7th edition", "year": 1399}).to_string()
            + "\n"
            + &json!({"path": "stone.pdf", "ok": false, "edition": "2nd edition"}).to_string()
            + "\n",
    )
    .unwrap();
    let run = |name: &str| -> String {
        let lib = tmp.path().join(name);
        let o = cli().arg("library").arg("--packs").arg(&packs).arg("--out").arg(&lib).args(["--id", "r", "--title", "R", "--built-at", "2026-11-01T00:00:00Z", "--titles"]).arg(&titles).output().unwrap();
        assert!(o.status.success(), "{}", String::from_utf8_lossy(&o.stderr));
        std::fs::read_to_string(lib.join("log").join("builder-r.jsonl")).unwrap()
    };
    let (a, b) = (run("lib1"), run("lib2"));
    assert_eq!(a, b, "the seed log is byte-identical across runs");
    let lines: Vec<Value> = a.lines().map(|l| serde_json::from_str(l).unwrap()).collect();
    let evs: Vec<&str> = lines.iter().map(|l| l["ev"].as_str().unwrap()).collect();
    let first_facts = evs.iter().position(|e| *e == "facts").unwrap();
    assert!(evs[first_facts..].iter().all(|e| *e == "facts"), "facts come after every title event: {evs:?}");
    assert!(evs.contains(&"title"));
    let facts: Vec<&Value> = lines.iter().filter(|l| l["ev"] == "facts").collect();
    assert_eq!(facts.len(), 2);
    // doc order
    let mut docs = vec![h1.clone(), h2.clone()];
    docs.sort();
    assert_eq!(facts.iter().map(|f| f["doc"].as_str().unwrap().to_string()).collect::<Vec<_>>(), docs);
    let water = facts.iter().find(|f| f["doc"] == json!(h1)).unwrap();
    assert_eq!((water["author"].clone(), water["edition"].clone()), (json!("A. Writer"), json!("7th edition")));
    assert!(water.get("year").is_none(), "the invalid year is dropped: {water}");
    assert_eq!(water["copy"], json!(h1));
    assert_eq!(water["loc"], json!(format!("r/{h1}")));
    let stone = facts.iter().find(|f| f["doc"] == json!(h2)).unwrap();
    assert_eq!(stone["edition"], json!("2nd edition"));
    assert!(stone.get("author").is_none() && stone.get("year").is_none());
}
