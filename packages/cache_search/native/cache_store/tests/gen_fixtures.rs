//! Makes the old-store fixtures in `tests/data/` with the real iroh-blobs 0.103.1. Run once, by hand:
//!
//!   CACHE_STORE_FIXTURE_OUT=/some/empty/dir cargo test -p cache_store --test gen_fixtures -- --ignored --nocapture
//!
//! then copy `clean` and `killed` from that folder into `tests/data/`. The move tests (tests/move.rs) read only the checked-in
//! data, so they keep working after iroh-blobs is gone (step 6b). This file goes with iroh at 6b.

use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

use cache_store::{ChunkNum, ChunkRanges, Options, Store};
use iroh_blobs::{
    api::blobs::{AddPathOptions, ImportMode},
    store::fs::FsStore,
    BlobFormat, HashAndFormat,
};
use serde::Serialize;

/// Where the in-place files of the clean store are said to live; the tests point this at a folder of their own.
const PLACEHOLDER: &str = "/__shared__";

#[derive(Serialize)]
struct Item {
    name: String,
    seed: u8,
    size: usize,
    /// inline, owned, external or partial.
    kind: String,
    hash: String,
    tag: Option<String>,
}

fn bytes(seed: u8, n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    blake3::Hasher::new().update(&[seed]).finalize_xof().fill(&mut v);
    v
}

fn copy_dir(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for e in fs::read_dir(from).unwrap() {
        let e = e.unwrap();
        let t = to.join(e.file_name());
        if e.file_type().unwrap().is_dir() {
            copy_dir(&e.path(), &t);
        } else {
            fs::copy(e.path(), t).unwrap();
        }
    }
}

/// Fills a store and returns what it holds. `with_external` adds in-place files under `shared`.
async fn fill(store: &FsStore, shared: Option<&Path>) -> Vec<Item> {
    let mut items = Vec::new();
    // (name, seed, size, kind, tag)
    let plain: [(&str, u8, usize, &str, Option<&str>); 6] = [
        ("tiny.txt", 1, 3_000, "inline", Some("share1/tiny.txt")),
        ("small.txt", 2, 12_000, "inline", None),
        ("a.bin", 3, 20_000, "owned", None),
        ("b.bin", 4, 50_000, "owned", Some("share1/b.bin")),
        ("c.bin", 5, 70_000, "owned", Some("share1/c.bin")),
        ("edge.bin", 9, 16 * 1024 + 1, "owned", None),
    ];
    for (name, seed, size, kind, tag) in plain {
        let t = store.add_bytes(bytes(seed, size)).temp_tag().await.unwrap();
        let h = t.hash();
        if let Some(tag) = tag {
            store.tags().set(tag.as_bytes(), HashAndFormat::raw(h)).await.unwrap();
        }
        items.push(Item { name: name.into(), seed, size, kind: kind.into(), hash: h.to_hex(), tag: tag.map(String::from) });
    }
    if let Some(shared) = shared {
        fs::create_dir_all(shared).unwrap();
        for (name, seed, size, tag) in [("ext1.bin", 6u8, 60_000usize, "share2/ext1.bin"), ("ext2.bin", 7, 30_000, "share2/ext2.bin")] {
            let p = shared.join(name);
            fs::write(&p, bytes(seed, size)).unwrap();
            let t = store
                .add_path_with_opts(AddPathOptions { path: p, format: BlobFormat::Raw, mode: ImportMode::TryReference })
                .temp_tag()
                .await
                .unwrap();
            let h = t.hash();
            store.tags().set(tag.as_bytes(), HashAndFormat::raw(h)).await.unwrap();
            items.push(Item { name: name.into(), seed, size, kind: "external".into(), hash: h.to_hex(), tag: Some(tag.into()) });
        }
    }
    // A partial download: the first 32 chunks of a 120,000-byte file, imported as a verified window (the way a fetch does).
    let (seed, size) = (8u8, 120_000usize);
    let data = bytes(seed, size);
    let scratch = tempfile::TempDir::new().unwrap();
    let cs = Store::open(scratch.path(), Options::default()).unwrap();
    let h = cs.add_bytes(&data).unwrap().hash;
    let w = ChunkRanges::from(ChunkNum(0)..ChunkNum(32));
    let piece = cs.encode_ranges_to_vec(&h, &w).unwrap();
    let ih = iroh_blobs::Hash::from_bytes(*h.as_bytes());
    store.import_bao_bytes(ih, w, bytes::Bytes::from(piece)).await.unwrap();
    store.tags().set(b"share3/partial.bin", HashAndFormat::raw(ih)).await.unwrap();
    items.push(Item { name: "partial.bin".into(), seed, size, kind: "partial".into(), hash: h.to_hex(), tag: Some("share3/partial.bin".into()) });
    items
}

fn write_manifest(dir: &Path, items: &[Item]) {
    fs::write(dir.join("manifest.json"), serde_json::to_string_pretty(items).unwrap()).unwrap();
}

#[tokio::test(flavor = "multi_thread")]
#[ignore = "makes the checked-in fixtures; run by hand with CACHE_STORE_FIXTURE_OUT set"]
async fn generate() {
    let out = PathBuf::from(std::env::var("CACHE_STORE_FIXTURE_OUT").expect("set CACHE_STORE_FIXTURE_OUT to an empty folder"));

    // clean: closed with shutdown. Has in-place files, which live in `shared/` beside it (paths rewritten to the placeholder).
    let clean = out.join("clean");
    let real_shared = clean.join("shared");
    let store = FsStore::load(clean.join("blobs")).await.unwrap();
    let items = fill(&store, Some(&real_shared)).await;
    store.shutdown().await.unwrap();
    drop(store);
    let n = cache_store::old_store::rewrite_external_prefix(&clean.join("blobs/blobs.db"), &fs::canonicalize(&real_shared).unwrap(), Path::new(PLACEHOLDER)).unwrap();
    assert_eq!(n, 2);
    write_manifest(&clean, &items);

    // killed: the folder copied while the store is open and working, so its database was never closed. No in-place files (their
    // paths could not be rewritten without opening, and so repairing, the database).
    let live = out.join("killed-live");
    let store = FsStore::load(live.join("blobs")).await.unwrap();
    let items = fill(&store, None).await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let killed = out.join("killed");
    copy_dir(&live.join("blobs"), &killed.join("blobs"));
    write_manifest(&killed, &items);
    store.shutdown().await.unwrap();
    drop(store);
    fs::remove_dir_all(&live).unwrap();
    // Not part of the fixture: the generator's own scratch.
    let _ = fs::remove_dir_all(clean.join("blobs/temp"));
    let _ = fs::remove_dir_all(killed.join("blobs/temp"));
    println!("fixtures in {}", out.display());
}
