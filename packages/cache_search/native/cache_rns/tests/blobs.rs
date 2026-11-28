//! B2: verified, resumable blob fetch over Reticulum between two real nodes, each with a real cache_store file store on disk.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use cache_rns::blobs::{fetch, WINDOW_CHUNKS};
use cache_rns::{destination_for, Asker, BoxFut, Config, Handler, Iface, RnsNode};
use cache_store::{ChunkNum, ChunkRanges, Hash, Options, Store};
use iroh::{PublicKey, SecretKey};

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
    a_store: Store,
    b_store: Store,
    b: RnsNode,
    a_key: PublicKey,
    _a: RnsNode,
    _dirs: (tempfile::TempDir, tempfile::TempDir),
}

async fn pair() -> Pair {
    let (ka, kb) = (SecretKey::generate(), SecretKey::generate());
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a_store = Store::open(&da.path().join("store"), Options::default()).unwrap();
    let b_store = Store::open(&db.path().join("store"), Options::default()).unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let cfg = |k: &SecretKey, i: Iface, peer: &SecretKey, store: &Store| Config {
        device: k.clone(),
        interfaces: vec![i],
        peers: vec![(peer.public(), Some(destination_for(peer).unwrap()))],
        wifi_group: None,
        paths: vec![],
        open_paths: vec![],
        max_bytes: 64 * 1024 * 1024,
        blobs: Some(store.clone()),
        pair_local_tcp: false,
    };
    let a = RnsNode::start(cfg(&ka, Iface::TcpListen(format!("127.0.0.1:{port}")), &kb, &a_store), Arc::new(Nothing))
        .await
        .unwrap();
    let b = RnsNode::start(cfg(&kb, Iface::TcpConnect(format!("127.0.0.1:{port}")), &ka, &b_store), Arc::new(Nothing))
        .await
        .unwrap();
    let end = Instant::now() + Duration::from_secs(20);
    while !(b.reachable(&ka.public()) && a.reachable(&kb.public())) {
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
    let hash = p.a_store.add_bytes(&data).unwrap().hash;

    // Resume: B already holds window 0 (as if an earlier fetch had stopped after it).
    let w = ChunkRanges::from(ChunkNum(0)..ChunkNum(WINDOW_CHUNKS));
    let w0 = p.a_store.encode_ranges_to_vec(&hash, &w).unwrap();
    p.b_store.import_ranges(&hash, &w, &w0).unwrap();

    let mut seen = Vec::new();
    let f = fetch(&p.b, &p.a_key, &p.b_store, hash, Duration::from_secs(60), |f| seen.push(f.have)).await.unwrap();
    assert_eq!(f.size, data.len() as u64);
    assert_eq!(f.skipped, 1, "the window already held is not fetched again");
    assert_eq!(f.windows, 2);
    assert_eq!(seen.last().copied(), Some(data.len() as u64));
    let got = p.b_store.get_bytes(&hash).unwrap();
    assert!(got == data, "the fetched file is byte for byte the original");

    // Fetching again does nothing: it is complete.
    let f = fetch(&p.b, &p.a_key, &p.b_store, hash, Duration::from_secs(60), |_| {}).await.unwrap();
    assert_eq!((f.windows, f.have), (0, data.len() as u64));

    // A file the other device does not have is refused cleanly.
    let missing = Hash::new(b"not there");
    let r = fetch(&p.b, &p.a_key, &p.b_store, missing, Duration::from_secs(30), |_| {}).await;
    assert!(r.is_err());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn fetch_speed_256_mib() {
    let p = pair().await;
    let data = random(256 * 1024 * 1024, 11);
    let hash = p.a_store.add_bytes(&data).unwrap().hash;
    let t = Instant::now();
    let f = fetch(&p.b, &p.a_key, &p.b_store, hash, Duration::from_secs(120), |_| {}).await.unwrap();
    let secs = t.elapsed().as_secs_f64();
    assert_eq!(f.have, 256 * 1024 * 1024);
    println!("RESULT b2_fetch bytes={} windows={} secs={secs:.2} MBps={:.1}", f.size, f.windows, f.size as f64 / 1e6 / secs);
}
