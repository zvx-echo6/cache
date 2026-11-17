//! `cache-build library-patch`: replacing a few documents of a finished library in place. A small made-up library (three
//! documents); the checks are that only the replaced documents' points and rows change, an old version's points are gone,
//! SHA256SUMS is valid, and a document that is not in the library is refused with the folder untouched.

use cache_builder::embed::{fake_vector, DIMS};
use cache_builder::library::{write_library, LibDoc, LibraryOptions, COPIES_FILE, DOCUMENTS_FILE, SUMS_FILE};
use cache_builder::pack::{Chunker, EmbeddingInfo, Header, Pack, PackPiece, Source, Tool, PACK_FORMAT};
use cache_builder::patch::{patch_library, LOCK_FILE};
use edge::{EdgeShardRead, ScrollRequest, WithPayloadInterface, WithVector};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::Path;

fn piece(index: u32, text: &str) -> PackPiece {
    PackPiece { index, text: text.into(), page: format!("{}", index + 1), pdf_page: Some(index + 1), page_end: None, pdf_page_end: None, heading_path: vec!["H".into()], vector: fake_vector(text) }
}

fn pack(id: &str, version: u32, source: &str, texts: &[&str]) -> Pack {
    let pieces: Vec<PackPiece> = texts.iter().enumerate().map(|(i, t)| piece(i as u32, t)).collect();
    Pack {
        header: Header {
            cdoc: PACK_FORMAT,
            doc_id: id.into(),
            doc_version: version,
            title: format!("Title of {id}"),
            source: Source { blake3: source.repeat(32), size: 1, file_name: "x.pdf".into(), https: None },
            extractor: Tool { name: "mupdf".into(), version: "0".into(), layout_version: None },
            chunker: Chunker { version: 1, target_words: 200, max_words: 300 },
            embedding: EmbeddingInfo { embedder: "fake-hash-v1".into(), dims: DIMS },
            created_at: "2026-11-01T00:00:00Z".into(),
            page_count: 12,
            ocr_pages: vec![],
            text_source_ocr_pages: vec![],
            pieces: pieces.len(),
            division: None,
            book: None,
            samebook: None,
        },
        pieces,
    }
}

/// a, b and c: 3, 2 and 2 pieces.
fn library(dir: &Path) {
    let opts = LibraryOptions { id: "patch-test".into(), title: "Patch test".into(), version: "1".into(), vector_datatype: Default::default(), archive: false, built_at: 0 };
    let packs = [
        pack("a", 1, "aa", &["a one", "a two", "a three"]),
        pack("b", 1, "bb", &["b one \u{f731}", "b two"]),
        pack("c", 1, "cc", &["c one", "c two"]),
    ];
    write_library(dir, &opts, packs.iter().map(LibDoc::from_pack)).unwrap();
}

/// Every point: id -> (payload text, version, the vector as text).
fn points(dir: &Path) -> BTreeMap<String, (String, String, String)> {
    let shard = cache_search::library::open_shard_for_scroll(&dir.join("shard")).unwrap();
    let mut sr = ScrollRequest::new();
    sr.limit = Some(1000);
    sr.with_payload = Some(WithPayloadInterface::Bool(true));
    sr.with_vector = WithVector::Bool(true);
    let (recs, _) = EdgeShardRead::scroll(&shard, sr).unwrap();
    recs.iter()
        .map(|r| {
            let p = &r.payload.as_ref().unwrap().0;
            (format!("{:?}", r.id), (p["text"].to_string(), format!("{}{}", p["doc_id"], p["doc_version"]), format!("{:?}", r.vector)))
        })
        .collect()
}

fn lines(path: &Path) -> Vec<String> {
    std::fs::read_to_string(path).unwrap().lines().map(str::to_string).collect()
}

fn row<'a>(all: &'a [String], id: &str) -> &'a str {
    all.iter().find(|l| l.starts_with(&format!("{id}\t")) || l.contains(&format!("\"doc_id\":\"{id}\""))).unwrap_or_else(|| panic!("no row for {id}"))
}

fn files_state(dir: &Path) -> BTreeMap<String, Vec<u8>> {
    fn walk(base: &Path, d: &Path, out: &mut BTreeMap<String, Vec<u8>>) {
        for e in std::fs::read_dir(d).unwrap() {
            let p = e.unwrap().path();
            if p.is_dir() {
                walk(base, &p, out);
            } else {
                out.insert(p.strip_prefix(base).unwrap().to_string_lossy().into_owned(), std::fs::read(&p).unwrap());
            }
        }
    }
    let mut m = BTreeMap::new();
    walk(dir, dir, &mut m);
    m
}

fn sums_valid(dir: &Path) {
    let listed = lines(&dir.join(SUMS_FILE));
    let mut n = 0;
    for l in &listed {
        let (hash, rel) = l.split_once("  ").unwrap();
        let got = format!("{:x}", Sha256::digest(std::fs::read(dir.join(rel)).unwrap()));
        assert_eq!(hash, got, "SHA256SUMS is wrong for {rel}");
        n += 1;
    }
    assert!(n >= 4, "SHA256SUMS lists only {n} files");
    for rel in files_state(dir).keys() {
        if rel == SUMS_FILE || rel.starts_with('.') || rel.contains("/.") {
            continue;
        }
        assert!(listed.iter().any(|l| l.ends_with(&format!("  {rel}"))), "{rel} is not in SHA256SUMS");
    }
}

#[test]
fn a_version_two_replacement_changes_only_that_document() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("lib");
    library(&dir);
    let before = points(&dir);
    let (tsv0, cop0) = (lines(&dir.join(DOCUMENTS_FILE)), lines(&dir.join(COPIES_FILE)));
    assert_eq!(before.len(), 7);

    // b becomes version 2 with three pieces and a different stored file
    let new_b = pack("b", 2, "ee", &["b one 1", "b two", "b three"]);
    let r = patch_library(&dir, std::slice::from_ref(&new_b), None).unwrap();
    assert_eq!(r.points, 8);
    assert_eq!(r.docs, vec![("b".to_string(), 1, 2, 2, 3)]);
    assert!(!dir.join(LOCK_FILE).exists(), "the lock must be gone");

    let after = points(&dir);
    assert_eq!(after.len(), 8);
    // a and c: every point byte for byte as before (same ids, payloads and vectors)
    for (id, v) in &before {
        if v.1.starts_with("\"a\"") || v.1.starts_with("\"c\"") {
            assert_eq!(after.get(id), Some(v), "a point of a document that was not replaced changed");
        } else {
            assert!(!after.contains_key(id), "an old version-1 point of b is still in the shard");
        }
    }
    let b_new: Vec<_> = after.values().filter(|v| v.1.starts_with("\"b\"")).collect();
    assert_eq!(b_new.len(), 3);
    assert!(b_new.iter().all(|v| v.1 == "\"b\"2"), "every b point is version 2");
    assert!(b_new.iter().any(|v| v.0 == "\"b one 1\""));
    assert!(!after.values().any(|v| v.0.contains('\u{f731}')), "the old-style character is gone");

    // rows: a and c untouched, b rewritten
    let (tsv1, cop1) = (lines(&dir.join(DOCUMENTS_FILE)), lines(&dir.join(COPIES_FILE)));
    assert_eq!(tsv0.len(), tsv1.len());
    assert_eq!(cop0.len(), cop1.len());
    for id in ["a", "c"] {
        assert_eq!(row(&tsv0, id), row(&tsv1, id));
        assert_eq!(row(&cop0, id), row(&cop1, id));
    }
    assert_eq!(tsv1[0], tsv0[0], "the header row");
    let b_tsv: Vec<&str> = row(&tsv1, "b").split('\t').collect();
    assert_eq!((b_tsv[1], b_tsv[2], b_tsv[3], b_tsv[4], b_tsv[5]), ("2", "Title of b", "ee".repeat(32).as_str(), "3", "12"));
    let b_cop = row(&cop1, "b");
    assert!(b_cop.contains("\"doc_version\":2"), "{b_cop}");
    assert!(b_cop.contains(&"ee".repeat(32)), "{b_cop}");
    assert!(!b_cop.contains(&"bb".repeat(32)));
    sums_valid(&dir);
    // the core still accepts the library
    cache_builder::check_library_dir(&dir).unwrap();
}

#[test]
fn a_same_version_replacement_with_fewer_pieces_leaves_no_old_points() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("lib");
    library(&dir);
    let before = points(&dir);
    let new_a = pack("a", 1, "aa", &["a one", "a TWO"]);
    let r = patch_library(&dir, &[new_a], None).unwrap();
    assert_eq!(r.points, 6);
    let after = points(&dir);
    let a: Vec<_> = after.values().filter(|v| v.1.starts_with("\"a\"")).collect();
    assert_eq!(a.len(), 2);
    assert!(a.iter().any(|v| v.0 == "\"a TWO\""));
    assert!(!after.values().any(|v| v.0 == "\"a two\"" || v.0 == "\"a three\""));
    for (id, v) in &before {
        if !v.1.starts_with("\"a\"") {
            assert_eq!(after.get(id), Some(v));
        }
    }
    sums_valid(&dir);
}

#[test]
fn a_document_that_is_not_in_the_library_is_refused_and_nothing_changes() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("lib");
    library(&dir);
    let state = files_state(&dir);
    // b is fine but z is not there: nothing may be written, not even for b
    let packs = [pack("b", 2, "ee", &["b new"]), pack("z", 1, "ff", &["z one"])];
    let e = patch_library(&dir, &packs, None).unwrap_err();
    assert!(e.to_string().contains("z is not in the library"), "{e}");
    assert_eq!(files_state(&dir), state, "a refused patch changed the folder");
    assert!(!dir.join(LOCK_FILE).exists());
    // the same document twice is refused too
    let e = patch_library(&dir, &[pack("a", 1, "aa", &["x"]), pack("a", 1, "aa", &["y"])], None).unwrap_err();
    assert!(e.to_string().contains("given twice"), "{e}");
    assert_eq!(files_state(&dir), state);
    // and a lower version than the library's
    let mut low = pack("b", 1, "bb", &["x"]);
    low.header.doc_version = 0;
    assert!(patch_library(&dir, &[low], None).unwrap_err().to_string().contains("version"));
    assert_eq!(files_state(&dir), state);
}

#[test]
fn a_folder_with_a_patch_running_or_an_installed_path_is_refused() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("lib");
    library(&dir);
    std::fs::write(dir.join(LOCK_FILE), b"").unwrap();
    let state = files_state(&dir);
    let e = patch_library(&dir, &[pack("a", 1, "aa", &["x"])], None).unwrap_err();
    assert!(e.to_string().contains(LOCK_FILE), "{e}");
    assert_eq!(files_state(&dir), state);
    std::fs::remove_file(dir.join(LOCK_FILE)).unwrap();
    // a library the core is updating (its staging copy sits beside it)
    std::fs::create_dir(t.path().join("lib.cs-stage")).unwrap();
    let e = patch_library(&dir, &[pack("a", 1, "aa", &["x"])], None).unwrap_err();
    assert!(e.to_string().contains("being updated"), "{e}");
    assert!(patch_library(&t.path().join("nothing"), &[pack("a", 1, "aa", &["x"])], None).is_err());
}

#[test]
fn a_new_version_is_written_and_the_checksums_still_verify() {
    let t = tempfile::tempdir().unwrap();
    let dir = t.path().join("lib");
    library(&dir);
    let settings0 = std::fs::read_to_string(dir.join("cache-library.json")).unwrap();
    assert!(settings0.contains("\"version\": \"1\""), "{settings0}");
    // no new version asked for: the settings file stays byte for byte
    patch_library(&dir, &[pack("a", 1, "aa", &["a one", "a two", "a three"])], None).unwrap();
    assert_eq!(std::fs::read_to_string(dir.join("cache-library.json")).unwrap(), settings0);
    patch_library(&dir, &[pack("c", 1, "cc", &["c one", "c 2"])], Some("2026.11.17")).unwrap();
    let settings1 = std::fs::read_to_string(dir.join("cache-library.json")).unwrap();
    assert_eq!(settings1, settings0.replace("\"version\": \"1\"", "\"version\": \"2026.11.17\""), "only the version line changes");
    sums_valid(&dir);
    assert!(lines(&dir.join(SUMS_FILE)).iter().any(|l| l.ends_with("  cache-library.json")));
    cache_builder::check_library_dir(&dir).unwrap();
}
