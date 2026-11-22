//! The library reader of build 1.1.0-49 (the last shipped reader of pack headers and `copies.jsonl`; 1.0.30 has none) on a library
//! written by this build, whose `book.suggested` carries `filed` and `suggestions`. `tests/fixtures/old_library_build49.rs` is that
//! build's `packages/cache_shelves/src/library.rs` (its code, without its test module). It reads headers as `serde_json::Value`
//! (no struct with `deny_unknown_fields`), so keys it does not know are skipped; this test proves the library opens and gives the
//! same facts.

mod error {
    pub use cache_shelves::error::*;
}
mod events {
    pub use cache_shelves::events::*;
}
mod quality {
    pub use cache_shelves::quality::*;
}
mod same {
    pub use cache_shelves::same::*;
}
mod store {
    pub use cache_shelves::store::*;
}
#[path = "fixtures/old_library_build49.rs"]
#[allow(dead_code)]
mod old;

use cache_shelves::library::{load_library, LibraryRef, PackFacts, SuggestedDiv};
use serde_json::json;
use std::path::Path;

fn new_header(doc: &str) -> String {
    json!({
        "cdoc": 1, "doc_id": doc, "doc_version": 1, "title": "Water", "source": {"blake3": "stored"},
        "book": {"title": "Water", "original_blake3": "ORIG", "author": "A. Writer", "suggested": {
            "div": "610", "label": "Medicine", "score": 0.41, "classifier_version": 3, "source": "classifier", "second_div": "620",
            "filed": false,
            "suggestions": [{"div": "610", "label": "Medicine", "score": 0.41}, {"div": "620", "label": "Engineering", "score": 0.3}, {"div": "570", "label": "Life sciences", "score": 0.2}]
        }},
        "samebook": {"minhash": [], "mean_vector": "", "text_pages": 10, "pages": 10, "ppi": 150, "source_size": 99}
    })
    .to_string()
}

fn reader(p: &Path) -> Result<String, String> {
    std::fs::read_to_string(p).map_err(|e| e.to_string())
}

fn old_reader(p: &Path) -> std::result::Result<String, String> {
    reader(p)
}

#[test]
fn the_build_49_reader_reads_a_new_pack_header() {
    let f = old::PackFacts::from_header_line(&new_header("water")).expect("an old reader accepts the new header");
    assert_eq!((f.copy.as_str(), f.title.as_str(), f.suggested.as_ref().map(|s| s.div.as_str())), ("ORIG", "Water", Some("610")));
    assert_eq!(f.fields.author.as_deref(), Some("A. Writer"));
}

#[test]
fn the_build_49_reader_opens_a_library_of_new_packs_and_of_a_new_copies_file() {
    let root = std::env::temp_dir().join(format!("old-library-compat-{}", std::process::id()));
    let dir = root.join("lib");
    std::fs::create_dir_all(dir.join("packs")).unwrap();
    std::fs::write(dir.join("packs").join("water@1.cdoc"), new_header("water")).unwrap();
    // from the packs
    let old_lib = old::load_library(&old::LibraryRef::new("lib", &dir), &old_reader).expect("the library opens");
    assert_eq!((old_lib.copies.len(), old_lib.unreadable), (1, 0));
    assert_eq!(old_lib.copies[0].suggested.as_ref().map(|s| (s.div.as_str(), s.label.as_str())), Some(("610", "Medicine")));
    // from a copies.jsonl this build wrote (the same facts, with the new keys)
    let new_lib = load_library(&LibraryRef::new("lib", &dir), &reader).unwrap();
    let line = new_lib.copies[0].to_copies_line();
    assert!(line.contains("\"filed\":false") && line.contains("\"suggestions\""), "{line}");
    std::fs::remove_dir_all(dir.join("packs")).unwrap();
    std::fs::write(dir.join("copies.jsonl"), format!("{line}\n")).unwrap();
    let old_lib = old::load_library(&old::LibraryRef::new("lib", &dir), &old_reader).expect("a copies file with the new keys opens");
    assert_eq!((old_lib.copies.len(), old_lib.unreadable), (1, 0));
    assert_eq!(old_lib.copies[0].suggested.as_ref().map(|s| s.div.as_str()), Some("610"));
    assert_eq!((old_lib.copies[0].copy.as_str(), old_lib.copies[0].title.as_str()), ("ORIG", "Water"));
    // and what this build writes for an old pack (no flag) is what it always was
    let plain = PackFacts { suggested: Some(SuggestedDiv { div: "610".into(), label: "Medicine".into(), ..Default::default() }), ..new_lib.copies[0].clone() };
    assert!(!plain.to_copies_line().contains("filed"));
    let _ = std::fs::remove_dir_all(&root);
}
