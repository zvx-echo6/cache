//! A pack whose `book.suggested` carries `filed` and `suggestions` (written by this build) opened by the reader of build 1.1.0-49 (the
//! last shipped reader of `.cdoc` packs: 1.0.30 has no pack reader at all). `tests/fixtures/old_pack_build49.rs` is that build's
//! `packages/cache_pack/src/pack.rs`, byte for byte (`git show build-1.1.0-49:packages/cache_pack/src/pack.rs`). Its header
//! structs have no `deny_unknown_fields`, so serde skips keys it does not know; this test proves it end to end.

mod compression {
    pub use cache_pack::compression::*;
}
mod error {
    pub use cache_pack::error::*;
}
#[path = "fixtures/old_pack_build49.rs"]
#[allow(dead_code)]
mod old;

use cache_pack::pack::{self, Pack, PackPiece};
use serde_json::{json, Value};

fn header_json(suggested: Value) -> Value {
    json!({
        "cdoc": 1, "doc_id": "water", "doc_version": 1, "title": "Water",
        "source": {"blake3": "ab".repeat(32), "size": 100, "file_name": "water.pdf"},
        "extractor": {"name": "pdfium", "version": "1"},
        "chunker": {"version": 1, "target_words": 200, "max_words": 300},
        "embedding": {"embedder": "fake", "dims": 3},
        "created_at": "2026-11-11T00:00:00Z", "page_count": 2, "ocr_pages": [], "pieces": 2,
        "book": {"title": "Water", "source_title": null, "original_blake3": "ab".repeat(32), "compression": null, "ocr": null, "suggested": suggested}
    })
}

fn pieces() -> Vec<PackPiece> {
    [(0, vec![1.0, 0.0, 0.0], "Boil water for one minute."), (1, vec![0.0, 1.0, 0.0], "Carry a spare filter.")]
        .into_iter()
        .map(|(i, vector, text)| PackPiece { index: i, text: text.into(), page: "1".into(), pdf_page: Some(1), page_end: None, pdf_page_end: None, heading_path: vec![], vector })
        .collect()
}

fn new_suggested(filed: bool) -> Value {
    json!({
        "div": "610", "label": "Medicine", "score": 0.41, "classifier_version": 3, "source": "classifier", "second_div": "620",
        "filed": filed,
        "suggestions": [
            {"div": "610", "label": "Medicine", "score": 0.41},
            {"div": "620", "label": "Engineering", "score": 0.3},
            {"div": "570", "label": "Life sciences", "score": 0.2}
        ]
    })
}

fn new_pack(suggested: Value) -> Pack {
    Pack { header: serde_json::from_value(header_json(suggested)).unwrap(), pieces: pieces() }
}

#[test]
fn the_new_writer_writes_filed_and_three_suggestions_and_an_old_pack_writes_neither() {
    let bytes = pack::pack_bytes(&new_pack(new_suggested(false))).unwrap();
    let back = pack::read_pack_bytes(&bytes).unwrap();
    let s = back.header.suggested().unwrap();
    assert_eq!(s.filed, Some(false));
    assert_eq!(s.suggestions.iter().map(|x| x.div.as_str()).collect::<Vec<_>>(), ["610", "620", "570"]);
    assert_eq!(s.second_div.as_deref(), Some("620"), "second_div stays for older readers");
    // a header without the keys reads back with neither, and writes without them (older packs keep their bytes)
    let plain = new_pack(json!({"div": "610", "label": "Medicine", "score": 0.41, "classifier_version": 3, "source": "classifier", "second_div": "620"}));
    let s = plain.header.suggested().unwrap();
    assert_eq!((s.filed, s.suggestions.len()), (None, 0));
    let line = serde_json::to_string(&plain.header).unwrap();
    assert!(!line.contains("filed") && !line.contains("suggestions"), "{line}");
}

#[test]
fn the_build_49_reader_opens_a_pack_with_the_new_keys_and_searches_it() {
    for filed in [true, false] {
        let bytes = pack::pack_bytes(&new_pack(new_suggested(filed))).unwrap();
        // the OLD reader, whole pack
        let old = old::read_pack_bytes(&bytes).expect("the build 49 reader accepts the new header");
        let sg = old.header.suggested().expect("it still finds the suggestion");
        assert_eq!((sg.div.as_str(), sg.second_div.as_deref(), sg.source.as_str()), ("610", Some("620"), "classifier"));
        assert_eq!(old.header.title, "Water");
        assert_eq!(old.pieces.len(), 2);
        // search the way a library does: the nearest piece to a query vector
        let q = [0.9f32, 0.1, 0.0];
        let best = old.pieces.iter().max_by(|a, b| dot(&a.vector, &q).total_cmp(&dot(&b.vector, &q))).unwrap();
        assert_eq!(best.text, "Boil water for one minute.");
    }
}

#[test]
fn the_build_49_reader_lists_a_pack_by_its_header_alone() {
    let dir = std::env::temp_dir().join(format!("old-pack-compat-{}", std::process::id()));
    let path = pack::write_pack(&new_pack(new_suggested(true)), &dir).unwrap();
    let h = old::read_header(&path).expect("header-only listing works");
    assert_eq!((h.doc_id.as_str(), h.pieces), ("water", 2));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn this_reader_opens_a_pack_the_old_writer_made_with_no_flag() {
    // a pack written by build 49 (no filed, no suggestions), read by this build: absent means "not confident", never filed
    let old_header: old::Header = serde_json::from_value(header_json(json!({"div": "610", "label": "Medicine", "score": 0.41, "classifier_version": 3, "source": "classifier", "second_div": "620"}))).unwrap();
    let bytes = old::pack_bytes(&old::Pack {
        header: old_header,
        pieces: pieces().into_iter().map(|p| old::PackPiece { index: p.index, text: p.text, page: p.page, pdf_page: p.pdf_page, page_end: p.page_end, pdf_page_end: p.pdf_page_end, heading_path: p.heading_path, vector: p.vector }).collect(),
    })
    .unwrap();
    let s = pack::read_pack_bytes(&bytes).unwrap().header.suggested().unwrap();
    assert_eq!((s.div.as_str(), s.filed, s.suggestions.len()), ("610", None, 0));
}

fn dot(a: &[f32], b: &[f32]) -> f32 {
    a.iter().zip(b).map(|(x, y)| x * y).sum()
}
