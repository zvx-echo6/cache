//! B2: verified, resumable blob fetch over Reticulum between two real nodes, each with a real iroh-blobs FsStore on disk.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use bao_tree::ChunkNum;
use cache_rns::blobs::{fetch, WINDOW_CHUNKS};
use cache_rns::{Asker, BoxFut, Config, Handler, Iface, RnsNode};
use iroh::{PublicKey, SecretKey};
use iroh_blobs::protocol::ChunkRanges;
use iroh_blobs::store::fs::FsStore;

struct Nothing;
impl Handler for Nothing {
    fn request(&self, _: Asker, _: &str, _: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        Box::pin(async { Ok(Vec::new()) })
    }
    fn notify(&self, _: PublicKey, _: Vec<u8>) {}
}

fn random(n: usize, seed: u64) -> Vec<u8> {
    // xorshift: incompressible enough that Prns ships it uncompressed, like real maps and ZIMs.
    let mut x = seed | 1;
    let mut v = Vec::with_capacity(n);
    while v.len() < n {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        v.extend_from_slice(&x.to_le_bytes());
    }
    v.truncate(n);
    v
}

struct Pair {
    a_store: FsStore,
    b_store: FsStore,
    b: RnsNode,
    a_key: PublicKey,
    _a: RnsNode,
    _dirs: (tempfile::TempDir, tempfile::TempDir),
}

async fn pair() -> Pair {
    let (ka, kb) = (SecretKey::generate(), SecretKey::generate());
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a_store = FsStore::load(da.path().join("blobs")).await.unwrap();
    let b_store = FsStore::load(db.path().join("blobs")).await.unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let cfg = |k: &SecretKey, i: Iface, peer: PublicKey, store: &FsStore| Config {
        device: k.clone(),
        interfaces: vec![i],
        peers: vec![peer],
        paths: vec![],
        open_paths: vec![],
        max_bytes: 64 * 1024 * 1024,
        blobs: Some((**store).clone()),
    };
    let a = RnsNode::start(cfg(&ka, Iface::TcpListen(format!("127.0.0.1:{port}")), kb.public(), &a_store), Arc::new(Nothing))
        .await
        .unwrap();
    let b = RnsNode::start(cfg(&kb, Iface::TcpConnect(format!("127.0.0.1:{port}")), ka.public(), &b_store), Arc::new(Nothing))
        .await
        .unwrap();
    let end = Instant::now() + Duration::from_secs(20);
    while !(b.knows(&ka.public()) && a.knows(&kb.public())) {
        assert!(Instant::now() < end, "the two devices hear each other within 20 s");
        let _ = a.announce().await;
        let _ = b.announce().await;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    Pair { a_store, b_store, b, a_key: ka.public(), _a: a, _dirs: (da, db) }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fetch_verified_and_resume() {
    let p = pair().await;
    // Three windows: two whole, one part.
    let data = random(2 * 16 * 1024 * 1024 + 123_457, 7);
    let tag = p.a_store.blobs().add_bytes(data.clone()).await.unwrap();

    // Resume: B already holds window 0 (as if an earlier fetch had stopped after it).
    let w0 = p
        .a_store
        .export_bao(tag.hash, ChunkRanges::from(ChunkNum(0)..ChunkNum(WINDOW_CHUNKS)))
        .bao_to_vec()
        .await
        .unwrap();
    p.b_store
        .import_bao_bytes(tag.hash, ChunkRanges::from(ChunkNum(0)..ChunkNum(WINDOW_CHUNKS)), w0)
        .await
        .unwrap();

    let mut seen = Vec::new();
    let f = fetch(&p.b, &p.a_key, &p.b_store, tag.hash, Duration::from_secs(60), |f| seen.push(f.have)).await.unwrap();
    assert_eq!(f.size, data.len() as u64);
    assert_eq!(f.skipped, 1, "the window already held is not fetched again");
    assert_eq!(f.windows, 2);
    assert_eq!(seen.last().copied(), Some(data.len() as u64));
    let got = p.b_store.blobs().get_bytes(tag.hash).await.unwrap();
    assert!(got.as_ref() == data.as_slice(), "the fetched file is byte for byte the original");

    // Fetching again does nothing: it is complete.
    let f = fetch(&p.b, &p.a_key, &p.b_store, tag.hash, Duration::from_secs(60), |_| {}).await.unwrap();
    assert_eq!((f.windows, f.have), (0, data.len() as u64));

    // A file the other device does not have is refused cleanly.
    let missing = iroh_blobs::Hash::new(b"not there");
    let r = fetch(&p.b, &p.a_key, &p.b_store, missing, Duration::from_secs(30), |_| {}).await;
    assert!(r.is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fetch_speed_256_mib() {
    let p = pair().await;
    let data = random(256 * 1024 * 1024, 11);
    let tag = p.a_store.blobs().add_bytes(data).await.unwrap();
    let t = Instant::now();
    let f = fetch(&p.b, &p.a_key, &p.b_store, tag.hash, Duration::from_secs(120), |_| {}).await.unwrap();
    let secs = t.elapsed().as_secs_f64();
    assert_eq!(f.have, 256 * 1024 * 1024);
    println!("RESULT b2_fetch bytes={} windows={} secs={secs:.2} MBps={:.1}", f.size, f.windows, f.size as f64 / 1e6 / secs);
}
