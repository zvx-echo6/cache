//! The vector index (HNSW): a library big enough to need one is saved with it, by the library writer and by the work shard a
//! server's ingest publishes. Qdrant Edge never builds it by itself; without it a meaning search reads every vector (a 6.6 GB
//! library took 4.5 s a search on an 8 GB server). A small library stays "plain" by design (Qdrant indexes a segment only above
//! its threshold, about 2,400 vectors of 1024 floats) and is still a good library.

use cache_builder::embed::fake_vector;
use cache_builder::library::{check_library_dir, write_library, LibDoc, LibraryOptions};
use cache_builder::pack::PackPiece;
use serde_json::Value;
use std::path::Path;

fn piece(index: u32, text: &str) -> PackPiece {
    PackPiece {
        index,
        text: text.into(),
        page: (index + 1).to_string(),
        pdf_page: Some(index + 1),
        page_end: None,
        pdf_page_end: None,
        heading_path: vec![],
        vector: fake_vector(text),
    }
}

fn pieces(doc: &str, n: u32) -> Vec<PackPiece> {
    (0..n).map(|i| piece(i, &format!("{doc} passage {i} about water, shelter and fire"))).collect()
}

fn doc(id: &str, n: u32) -> LibDoc {
    LibDoc {
        title: format!("Title of {id}"),
        doc_id: id.into(),
        doc_version: 1,
        source_blake3: "ab".repeat(32),
        original_blake3: None,
        link: String::new(),
        author: None,
        zim: None,
        pages: Some(n as usize),
        pieces: pieces(id, n),
        entry: None,
    }
}

fn opts(id: &str) -> LibraryOptions {
    LibraryOptions { id: id.into(), title: id.into(), version: "1".into(), vector_datatype: Default::default(), archive: false, built_at: 0 }
}

/// Each segment's vector index type and point count, from its segment.json.
fn segment_indexes(shard: &Path) -> Vec<String> {
    let mut out = vec![];
    for e in std::fs::read_dir(shard.join("segments")).unwrap() {
        let seg = e.unwrap().path();
        let Ok(text) = std::fs::read_to_string(seg.join("segment.json")) else { continue };
        let v: Value = serde_json::from_str(&text).unwrap();
        out.push(v["config"]["vector_data"][""]["index"]["type"].as_str().unwrap_or("?").to_string());
    }
    out.sort();
    out
}

#[test]
fn a_library_past_the_threshold_is_saved_with_its_vector_index() {
    let tmp = tempfile::tempdir().unwrap();
    let out = tmp.path().join("big");
    // 3,000 passages of 1024 floats (12 MB), past Qdrant's indexing threshold
    let docs = (0..30).map(|d| doc(&format!("b{d:04}"), 100));
    let report = write_library(&out, &opts("index-test-big"), docs).unwrap();
    assert_eq!(report.points, 3000);
    let kinds = segment_indexes(&out.join("shard"));
    assert!(kinds.iter().any(|k| k == "hnsw"), "a segment with the vector index: {kinds:?}");
    check_library_dir(&out).unwrap();
}

#[test]
fn a_small_library_stays_plain_and_is_still_good() {
    let tmp = tempfile::tempdir().unwrap();
    let out = tmp.path().join("small");
    write_library(&out, &opts("index-test-small"), vec![doc("s0001", 5), doc("s0002", 5)]).unwrap();
    let kinds = segment_indexes(&out.join("shard"));
    assert!(kinds.iter().all(|k| k == "plain"), "below the threshold nothing is indexed: {kinds:?}");
    check_library_dir(&out).unwrap();
}
