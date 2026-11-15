//! The libraries share's not-shared patterns for a person's own library (app/lib/sharing/share_rules.dart kLibraryNotShared):
//! what My books keeps to each device (its shard and lists, made from its packs) and what still syncs (packs, PDFs, settings).
//! The app's list is copied here; app/test/sharing_items_test.dart checks the app's side is this list.

use cache_sync::excluded;

fn patterns() -> Vec<String> {
    ["*/index", "*/index-snapshots", "my-books*/shard*", "my-books*/copies.jsonl", "my-books*/documents.tsv", "my-books*/SHA256SUMS"].iter().map(|s| s.to_string()).collect()
}

#[test]
fn an_own_librarys_shard_and_lists_stay_on_each_device() {
    let p = patterns();
    for rel in [
        "my-books/shard",
        "my-books/shard/segments/f43b/payload_storage/page_0.dat",
        "my-books/shard.cs-stage/edge_config.json",
        "my-books/copies.jsonl",
        "my-books/documents.tsv",
        "my-books/SHA256SUMS",
        "my-books-2/shard/edge_config.json",
        "my-books-mhz3k1/copies.jsonl",
        "my-books/index/meta.json",
    ] {
        assert!(excluded(&p, rel), "{rel} stays on each device");
    }
}

#[test]
fn its_packs_pdfs_and_settings_still_sync_and_other_libraries_are_as_before() {
    let p = patterns();
    for rel in [
        "my-books/packs/f425a9ef@1.cdoc",
        "my-books/bookshelf/f425a9ef.pdf",
        "my-books/cache-library.json",
        "my-books/copies (conflict, A, 2026-11-14 1929 UTC).jsonl",
        "first-aid/shard/segments/a/vector_storage/vectors/chunk_0.mmap",
        "first-aid/copies.jsonl",
        "first-aid/documents.tsv",
        "first-aid/SHA256SUMS",
        "library-my-books-a1b2c3/shard/edge_config.json",
    ] {
        assert!(!excluded(&p, rel), "{rel} syncs");
    }
}
