//! Window interop between a pre-6a device and a post-6a one, over Reticulum on loopback (step 6a proof b).
//!
//! The pre-6a node runs main's old `blobs.rs` (tests/interop/old_blobs.rs, copied from origin/main) on an iroh-blobs 0.103.1
//! FsStore. The post-6a node runs the new `cache_rns::blobs` on a cache_store. Windows go both ways, whole files and files
//! resumed across the two: half from one, the rest from the other, each ending byte-identical.

#[path = "interop/old_blobs.rs"]
#[allow(dead_code)]
mod old_blobs;

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use bao_tree::ChunkNum;
use cache_rns::blobs as new_blobs;
use cache_rns::{destination_for, Asker, BoxFut, Config, Handler, Iface, RnsNode};
use cache_store::{ChunkRanges, Hash, Options, Store};
use iroh::{PublicKey, SecretKey};
use iroh_blobs::store::fs::FsStore;

const W: u64 = new_blobs::WINDOW_CHUNKS;
const T: Duration = Duration::from_secs(90);

fn random(n: usize, seed: u64) -> Vec<u8> {
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

/// The pre-6a node answers window requests with the old code, as the old `lib.rs` did for linked devices.
struct OldServes(Arc<FsStore>);
impl Handler for OldServes {
    fn request(&self, asker: Asker, path: &str, body: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        let store = self.0.clone();
        let wanted = path == old_blobs::BLOB_PATH && matches!(asker, Asker::Linked(_));
        Box::pin(async move {
            if wanted {
                Ok(old_blobs::serve_window(&store, &body).await)
            } else {
                Ok(Vec::new())
            }
        })
    }
    fn notify(&self, _: PublicKey, _: Vec<u8>) {}
}

struct Nothing;
impl Handler for Nothing {
    fn request(&self, _: Asker, _: &str, _: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        Box::pin(async { Ok(Vec::new()) })
    }
    fn notify(&self, _: PublicKey, _: Vec<u8>) {}
}

struct Rig {
    /// Pre-6a: node, key, and its iroh-blobs store.
    old_node: RnsNode,
    old_key: PublicKey,
    old_store: Arc<FsStore>,
    /// Post-6a: node, key, and its cache_store.
    new_node: RnsNode,
    new_key: PublicKey,
    new_store: Store,
    dir: tempfile::TempDir,
}

async fn rig() -> Rig {
    let (ko, kn) = (SecretKey::generate(), SecretKey::generate());
    let dir = tempfile::tempdir().unwrap();
    let old_store = Arc::new(FsStore::load(dir.path().join("old-blobs")).await.unwrap());
    let new_store = Store::open(&dir.path().join("new-store"), Options::default()).unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let old_cfg = Config {
        device: ko.clone(),
        interfaces: vec![Iface::TcpListen(format!("127.0.0.1:{port}"))],
        peers: vec![(kn.public(), Some(destination_for(&kn).unwrap()))],
        wifi_group: None,
        paths: vec![old_blobs::BLOB_PATH.to_string()],
        open_paths: vec![],
        max_bytes: 64 * 1024 * 1024,
        blobs: None,
        pair_local_tcp: false,
    };
    let new_cfg = Config {
        device: kn.clone(),
        interfaces: vec![Iface::TcpConnect(format!("127.0.0.1:{port}"))],
        peers: vec![(ko.public(), Some(destination_for(&ko).unwrap()))],
        wifi_group: None,
        paths: vec![],
        open_paths: vec![],
        max_bytes: 64 * 1024 * 1024,
        blobs: Some(new_store.clone()),
        pair_local_tcp: false,
    };
    let old_node = RnsNode::start(old_cfg, Arc::new(OldServes(old_store.clone()))).await.unwrap();
    let new_node = RnsNode::start(new_cfg, Arc::new(Nothing)).await.unwrap();
    let end = Instant::now() + Duration::from_secs(20);
    while !(new_node.reachable(&ko.public()) && old_node.reachable(&kn.public())) {
        assert!(Instant::now() < end, "the two devices hear each other within 20 s");
        let _ = old_node.announce().await;
        let _ = new_node.announce().await;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    Rig { old_node, old_key: ko.public(), old_store, new_node, new_key: kn.public(), new_store, dir }
}

fn ih(h: &Hash) -> iroh_blobs::Hash {
    iroh_blobs::Hash::from_bytes(*h.as_bytes())
}

fn window(k: u64) -> ChunkRanges {
    ChunkRanges::from(ChunkNum(k * W)..ChunkNum((k + 1) * W))
}

/// Asks `peer` for window `k` of `hash` with `node` (the wire request both versions send) and returns the bao bytes (size
/// prefix first), failing if the peer says it does not have the file.
async fn raw_window(node: &RnsNode, peer: &PublicKey, hash: &Hash, k: u64) -> Vec<u8> {
    // 32 hash bytes, then start and end chunk, big endian: the same request in the old code and the new.
    let want = old_blobs::encode_want(&ih(hash), k * W, (k + 1) * W);
    let reply = node.request(peer, old_blobs::BLOB_PATH, &want, T).await.unwrap();
    assert_eq!(reply.first(), Some(&0u8), "the other device served window {k}");
    reply[1..].to_vec()
}

struct Case {
    name: &'static str,
    size: usize,
}

const SIZES: [Case; 4] = [
    Case { name: "1 byte", size: 1 },
    Case { name: "16 KiB + 1", size: 16 * 1024 + 1 },
    Case { name: "about 1 MiB", size: 1024 * 1024 + 777 },
    Case { name: "33 MiB, 3 windows", size: 2 * 16 * 1024 * 1024 + 123_457 },
];

/// Whole files, both ways.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn windows_both_ways() {
    let r = rig().await;
    for (i, c) in SIZES.iter().enumerate() {
        let data = random(c.size, 100 + i as u64);
        let h = Hash::new(&data);
        // The same file on both devices.
        r.new_store.add_bytes(&data).unwrap();
        r.old_store.add_bytes(data.clone()).await.unwrap();

        // Old serves, new imports.
        let into_new = Store::open(&r.dir.path().join(format!("into-new-{i}")), Options::default()).unwrap();
        let f = new_blobs::fetch(&r.new_node, &r.old_key, &into_new, h, T, |_| {}).await.unwrap();
        assert_eq!(f.size, c.size as u64, "{}", c.name);
        assert!(into_new.get_bytes(&h).unwrap() == data, "{}: old serves, new imports", c.name);

        // New serves, old imports.
        let into_old = FsStore::load(r.dir.path().join(format!("into-old-{i}"))).await.unwrap();
        let f = old_blobs::fetch(&r.old_node, &r.new_key, &into_old, ih(&h), T, |_| {}).await.unwrap();
        assert_eq!(f.size, c.size as u64, "{}", c.name);
        let got = into_old.blobs().get_bytes(ih(&h)).await.unwrap();
        assert!(got.as_ref() == data.as_slice(), "{}: new serves, old imports", c.name);
        into_old.shutdown().await.unwrap();
        println!("INTEROP whole {:<20} old->new ok   new->old ok", c.name);
    }
}

/// A fetch resumed across the two versions: window 0 from one, the rest from the other, in each direction and for each
/// importer.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_partial_resumed_across_the_two() {
    let r = rig().await;
    let data = random(2 * 16 * 1024 * 1024 + 123_457, 7);
    let h = Hash::new(&data);
    r.new_store.add_bytes(&data).unwrap();
    r.old_store.add_bytes(data.clone()).await.unwrap();

    // 1. A new store: window 0 from the old node, the rest from the new node.
    let s1 = Store::open(&r.dir.path().join("s1"), Options::default()).unwrap();
    let w0 = raw_window(&r.new_node, &r.old_key, &h, 0).await;
    s1.import_ranges(&h, &window(0), &w0).unwrap();
    let f = new_blobs::fetch(&r.old_node, &r.new_key, &s1, h, T, |_| {}).await.unwrap();
    assert_eq!((f.skipped, f.windows), (1, 2), "the window already held is not fetched again");
    assert!(s1.get_bytes(&h).unwrap() == data, "new store: first from old, rest from new");

    // 2. A new store: window 0 from the new node, the rest from the old node.
    let s2 = Store::open(&r.dir.path().join("s2"), Options::default()).unwrap();
    let w0 = raw_window(&r.old_node, &r.new_key, &h, 0).await;
    s2.import_ranges(&h, &window(0), &w0).unwrap();
    let f = new_blobs::fetch(&r.new_node, &r.old_key, &s2, h, T, |_| {}).await.unwrap();
    assert_eq!((f.skipped, f.windows), (1, 2));
    assert!(s2.get_bytes(&h).unwrap() == data, "new store: first from new, rest from old");

    // 3. An old store: window 0 from the new node, the rest from the old node.
    let s3 = FsStore::load(r.dir.path().join("s3")).await.unwrap();
    let w0 = raw_window(&r.old_node, &r.new_key, &h, 0).await;
    s3.import_bao_bytes(ih(&h), window(0), bytes::Bytes::from(w0)).await.unwrap();
    let f = old_blobs::fetch(&r.new_node, &r.old_key, &s3, ih(&h), T, |_| {}).await.unwrap();
    assert_eq!((f.skipped, f.windows), (1, 2));
    assert!(s3.blobs().get_bytes(ih(&h)).await.unwrap().as_ref() == data.as_slice(), "old store: first from new, rest from old");
    s3.shutdown().await.unwrap();

    // 4. An old store: window 0 from the old node, the rest from the new node.
    let s4 = FsStore::load(r.dir.path().join("s4")).await.unwrap();
    let w0 = raw_window(&r.new_node, &r.old_key, &h, 0).await;
    s4.import_bao_bytes(ih(&h), window(0), bytes::Bytes::from(w0)).await.unwrap();
    let f = old_blobs::fetch(&r.old_node, &r.new_key, &s4, ih(&h), T, |_| {}).await.unwrap();
    assert_eq!((f.skipped, f.windows), (1, 2));
    assert!(s4.blobs().get_bytes(ih(&h)).await.unwrap().as_ref() == data.as_slice(), "old store: first from old, rest from new");
    s4.shutdown().await.unwrap();
    println!("INTEROP resume: new store old+new ok, new store new+old ok, old store new+old ok, old store old+new ok");
}
