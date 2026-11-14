//! The work shard a server's ingest publishes is saved with its vector index (HNSW) once it is past Qdrant's threshold (see
//! vector_index.rs).

use cache_builder::embed::{fake_vector, DIMS};
use cache_builder::incremental::{publish_copy, WorkShard};
use cache_builder::pack::{Chunker, EmbeddingInfo, Header, Pack, PackPiece, Source, Tool, PACK_FORMAT};
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

fn pack(id: &str, n: u32) -> Pack {
    let pieces = pieces(id, n);
    Pack {
        header: Header {
            cdoc: PACK_FORMAT,
            doc_id: id.into(),
            doc_version: 1,
            title: format!("Pack {id}"),
            source: Source { blake3: "cd".repeat(32), size: 1, file_name: "x.pdf".into(), https: None },
            extractor: Tool { name: "mupdf".into(), version: "0".into(), layout_version: None },
            chunker: Chunker { version: 1, target_words: 200, max_words: 300 },
            embedding: EmbeddingInfo { embedder: "fake-hash-v1".into(), dims: DIMS },
            created_at: "2026-11-01T00:00:00Z".into(),
            page_count: n as usize,
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

#[test]
fn a_work_shard_optimized_before_publishing_has_its_vector_index() {
    let tmp = tempfile::tempdir().unwrap();
    let work = tmp.path().join("work");
    {
        let w = WorkShard::open(&work).unwrap();
        for d in 0..30 {
            w.upsert_pack(&pack(&format!("w{d:04}"), 100)).unwrap();
        }
        w.flush().unwrap();
        // the way a server's ingest has always left it: one plain segment
        assert!(!segment_indexes(&work).iter().any(|k| k == "hnsw"));
        w.optimize().unwrap();
        w.flush().unwrap();
    }
    let published = tmp.path().join("published");
    assert_eq!(publish_copy(&work, &published).unwrap(), 30);
    let kinds = segment_indexes(&published);
    assert!(kinds.iter().any(|k| k == "hnsw"), "the published copy has the vector index: {kinds:?}");
    // more books after it go on in the same work shard
    let w = WorkShard::open(&work).unwrap();
    w.upsert_pack(&pack("w9999", 3)).unwrap();
    w.optimize().unwrap();
    w.flush().unwrap();
}
