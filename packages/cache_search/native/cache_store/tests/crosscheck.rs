//! Cross-checks against iroh-blobs 0.103.1 (a dev-dependency only, dropped with iroh at step 6b):
//! the `Hash` text and binary forms, the inline limit, and the verified pieces in both directions.

use std::{fs, path::Path};

use cache_store::{ChunkNum, ChunkRanges, ExportMode, Hash, ImportMode, Options, Status, Store, INLINE_MAX};
use iroh_blobs::store::fs::{options::InlineOptions, FsStore};
use tempfile::TempDir;

/// 16 MiB of 1 KiB chunks: the window `cache_rns` asks for.
const RNS_WINDOW: u64 = 16 * 1024;

fn bytes(seed: u8, n: usize) -> Vec<u8> {
    let mut v = vec![0u8; n];
    blake3::Hasher::new().update(&[seed]).finalize_xof().fill(&mut v);
    v
}

fn theirs(h: &Hash) -> iroh_blobs::Hash {
    iroh_blobs::Hash::from_bytes(*h.as_bytes())
}

fn ours(h: iroh_blobs::Hash) -> Hash {
    Hash::from_bytes(*h.as_bytes())
}

fn window(k: u64, chunks: u64) -> ChunkRanges {
    ChunkRanges::from(ChunkNum(k * chunks)..ChunkNum((k + 1) * chunks))
}

/// How many windows of `chunks` chunks a file of `size` bytes needs (one, even for the empty file).
fn windows(size: u64, chunks: u64) -> u64 {
    size.div_ceil(chunks * 1024).max(1)
}

fn file_hash(p: &Path) -> Hash {
    let mut h = blake3::Hasher::new();
    h.update_reader(fs::File::open(p).unwrap()).unwrap();
    Hash::from(h.finalize())
}

#[test]
fn hash_serializes_like_iroh_blobs() {
    for data in [&b""[..], b"a", b"hello world", &[7u8; 1000]] {
        let (a, b) = (Hash::new(data), iroh_blobs::Hash::new(data));
        assert_eq!(a.as_bytes(), b.as_bytes());
        assert_eq!(a.to_hex(), b.to_hex());
        assert_eq!(a.to_string(), b.to_string());
        assert_eq!(a.fmt_short().as_str(), b.fmt_short().as_str());

        // Human-readable form (serde_json): the same text both ways.
        let (ja, jb) = (serde_json::to_string(&a).unwrap(), serde_json::to_string(&b).unwrap());
        assert_eq!(ja, jb);
        assert_eq!(ja, format!("\"{}\"", a.to_hex()));
        assert_eq!(serde_json::from_str::<Hash>(&jb).unwrap(), a);
        assert_eq!(serde_json::from_str::<iroh_blobs::Hash>(&ja).unwrap(), b);

        // Binary form (postcard, which iroh-blobs uses): the same bytes both ways, 32 with no length prefix.
        let (pa, pb) = (postcard::to_allocvec(&a).unwrap(), postcard::to_allocvec(&b).unwrap());
        assert_eq!(pa, pb);
        assert_eq!(pa.len(), 32);
        assert_eq!(postcard::from_bytes::<Hash>(&pb).unwrap(), a);
        assert_eq!(postcard::from_bytes::<iroh_blobs::Hash>(&pa).unwrap(), b);
    }
    // Inside a struct and a list too, as sync.json and the sync messages hold them.
    #[derive(serde::Serialize, serde::Deserialize, PartialEq, Debug)]
    struct Mine {
        h: Hash,
        list: Vec<Hash>,
    }
    #[derive(serde::Serialize, serde::Deserialize, PartialEq, Debug)]
    struct Theirs {
        h: iroh_blobs::Hash,
        list: Vec<iroh_blobs::Hash>,
    }
    let m = Mine { h: Hash::new(b"x"), list: vec![Hash::new(b"y"), Hash::EMPTY] };
    let t = Theirs { h: iroh_blobs::Hash::new(b"x"), list: vec![iroh_blobs::Hash::new(b"y"), iroh_blobs::Hash::EMPTY] };
    assert_eq!(serde_json::to_string(&m).unwrap(), serde_json::to_string(&t).unwrap());
    assert_eq!(postcard::to_allocvec(&m).unwrap(), postcard::to_allocvec(&t).unwrap());
    assert_eq!(serde_json::from_str::<Mine>(&serde_json::to_string(&t).unwrap()).unwrap(), m);
    assert_eq!(postcard::from_bytes::<Theirs>(&postcard::to_allocvec(&m).unwrap()).unwrap(), t);
    // Parsing: hex and base32, as iroh-blobs does.
    let h = iroh_blobs::Hash::new(b"parse");
    let b32 = data_encoding::BASE32_NOPAD.encode(h.as_bytes()).to_ascii_lowercase();
    assert_eq!(b32.parse::<Hash>().unwrap(), ours(h));
    assert_eq!(b32.parse::<iroh_blobs::Hash>().unwrap(), h);
    assert_eq!(Hash::EMPTY, ours(iroh_blobs::Hash::EMPTY));
    // Order.
    let (x, y) = (Hash::new(b"1"), Hash::new(b"2"));
    assert_eq!(x.cmp(&y), theirs(&x).cmp(&theirs(&y)));
}

#[test]
fn the_inline_limit_is_iroh_blobs_default() {
    assert_eq!(INLINE_MAX, InlineOptions::default().max_data_inlined);
    assert_eq!(INLINE_MAX, InlineOptions::default().max_outboard_inlined);
    assert_eq!(INLINE_MAX, 16 * 1024);
}

/// One size, one window width, both directions, with byte-for-byte comparison of what each side serves.
async fn crosscheck(size: usize, chunks: u64) {
    let d = TempDir::new().unwrap();
    let file = d.path().join("f.bin");
    fs::write(&file, bytes(1, size)).unwrap();
    let want = file_hash(&file);

    // Both stores hold the file.
    let iroh = FsStore::load(d.path().join("iroh")).await.unwrap();
    let tag = iroh.add_path(&file).await.unwrap();
    assert_eq!(ours(tag.hash), want, "iroh-blobs and this store give the file the same id");
    let mine = Store::open(&d.path().join("mine"), Options::default()).unwrap();
    assert_eq!(mine.add_path(&file, ImportMode::Copy).unwrap().hash, want);
    let n = windows(size as u64, chunks);

    // Direction 1: windows iroh-blobs serves for the file verify and import in cache_store.
    let into_mine = Store::open(&d.path().join("into_mine"), Options::default()).unwrap();
    for k in 0..n {
        let w = window(k, chunks);
        let from_iroh = iroh.export_bao(tag.hash, w.clone()).bao_to_vec().await.unwrap();
        // The same bytes this store serves for the same window.
        let from_mine = mine.encode_ranges_to_vec(&want, &w).unwrap();
        assert_eq!(from_iroh, from_mine, "window {k} of {n}: encodings differ");
        into_mine.import_ranges(&want, &w, &from_iroh).unwrap();
    }
    assert_eq!(into_mine.status(&want).unwrap(), Status::Complete { size: size as u64 }, "size {size}");
    let out1 = d.path().join("out1.bin");
    into_mine.export(&want, &out1, ExportMode::Copy).unwrap();
    assert_eq!(fs::metadata(&out1).unwrap().len(), size as u64);
    assert_eq!(file_hash(&out1), want, "size {size}: data imported from iroh-blobs reads back whole");

    // Direction 2: windows cache_store serves verify and import in iroh-blobs.
    let into_iroh = FsStore::load(d.path().join("into_iroh")).await.unwrap();
    for k in 0..n {
        let w = window(k, chunks);
        let piece = mine.encode_ranges_to_vec(&want, &w).unwrap();
        into_iroh.import_bao_bytes(tag.hash, w, bytes::Bytes::from(piece)).await.unwrap();
    }
    let out2 = d.path().join("out2.bin");
    if size == 0 {
        // iroh-blobs keeps no entry for the empty file; its import of a size-0 window is a no-op that must not fail.
        assert!(!out2.exists());
    } else {
        let have = into_iroh.observe(tag.hash).await.unwrap();
        assert!(have.is_complete(), "size {size}: iroh-blobs holds the whole file");
        assert_eq!(have.size(), size as u64);
        into_iroh.export(tag.hash, &out2).finish().await.unwrap();
        assert_eq!(file_hash(&out2), want, "size {size}: data imported by iroh-blobs reads back whole");
    }
    // Piece by piece the other way round too: the partial entry cache_store builds serves what iroh-blobs can verify.
    if size > 2 * 16 * 1024 {
        let half = window(0, 16);
        let part = Store::open(&d.path().join("part"), Options::default()).unwrap();
        part.import_ranges(&want, &half, &mine.encode_ranges_to_vec(&want, &half).unwrap()).unwrap();
        let again = part.encode_ranges_to_vec(&want, &half).unwrap();
        let fresh = FsStore::load(d.path().join("fresh")).await.unwrap();
        fresh.import_bao_bytes(tag.hash, half.clone(), bytes::Bytes::from(again)).await.unwrap();
        let have = fresh.observe(tag.hash).await.unwrap();
        assert!(!have.is_complete() && have.ranges.is_superset(&half));
        fresh.shutdown().await.unwrap();
    }
    into_iroh.shutdown().await.unwrap();
    iroh.shutdown().await.unwrap();
    eprintln!("crosscheck: {size} bytes, {n} window(s) of {chunks} chunks: iroh-blobs to cache_store ok, cache_store to iroh-blobs ok");
}

#[tokio::test(flavor = "multi_thread")]
async fn size_0() {
    crosscheck(0, RNS_WINDOW).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn size_1() {
    crosscheck(1, RNS_WINDOW).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn size_16_kib() {
    crosscheck(16 * 1024, RNS_WINDOW).await;
    crosscheck(16 * 1024, 16).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn size_16_kib_plus_1() {
    crosscheck(16 * 1024 + 1, RNS_WINDOW).await;
    crosscheck(16 * 1024 + 1, 16).await;
}

#[tokio::test(flavor = "multi_thread")]
async fn size_about_1_mib() {
    // The cache_rns window, and small windows so the multi-window path and the middle of the tree are exercised.
    crosscheck(1024 * 1024 + 777, RNS_WINDOW).await;
    crosscheck(1024 * 1024 + 777, 64).await;
    crosscheck(1024 * 1024 + 777, 16).await;
}

/// About 100 MiB: seven 16 MiB windows. Kept out of the default run for time and disk; run with
/// `cargo test -p cache_store --test crosscheck -- --ignored`.
#[tokio::test(flavor = "multi_thread")]
#[ignore = "about 100 MiB, several copies on disk; run explicitly"]
async fn size_about_100_mib() {
    crosscheck(100 * 1024 * 1024 + 1234, RNS_WINDOW).await;
}
