//! A fetch that takes longer than Prns's stale-link teardown (about 44 s on a quick, slow Wi-Fi link) keeps its link: the fetch
//! sends a small keepalive on the link about every 10 s, which the other device answers.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use cache_rns::blobs::fetch;
use cache_rns::{destination_for, Asker, BoxFut, Config, Handler, Iface, RnsNode};
use cache_store::{Options, Store};
use iroh::{PublicKey, SecretKey};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

struct Nothing;
impl Handler for Nothing {
    fn request(&self, _: Asker, _: &str, _: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        Box::pin(async { Ok(Vec::new()) })
    }
    fn notify(&self, _: PublicKey, _: Vec<u8>) {}
}

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

/// One direction: bytes read are written `delay` later, at no more than `rate` bytes a second.
async fn pipe(mut r: tokio::net::tcp::OwnedReadHalf, mut w: tokio::net::tcp::OwnedWriteHalf, delay: Duration, rate: f64) {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(Instant, Vec<u8>)>();
    tokio::spawn(async move {
        let mut buf = vec![0u8; 16 * 1024];
        while let Ok(n) = r.read(&mut buf).await {
            if n == 0 || tx.send((Instant::now() + delay, buf[..n].to_vec())).is_err() {
                break;
            }
        }
    });
    while let Some((due, bytes)) = rx.recv().await {
        tokio::time::sleep_until(due.into()).await;
        if w.write_all(&bytes).await.is_err() {
            break;
        }
        tokio::time::sleep(Duration::from_secs_f64(bytes.len() as f64 / rate)).await;
    }
}

async fn proxy(to: u16, delay: Duration, rate: f64) -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let Ok((c, _)) = l.accept().await else { break };
            let Ok(s) = TcpStream::connect(("127.0.0.1", to)).await else { continue };
            let (cr, cw) = c.into_split();
            let (sr, sw) = s.into_split();
            tokio::spawn(pipe(cr, sw, delay, rate));
            tokio::spawn(pipe(sr, cw, delay, rate));
        }
    });
    port
}

/// 70 MiB over a 90 ms round trip link at 1.2 MB/s takes about a minute: longer than the 44 s a link without traffic lasts. The fetch
/// finishes whole, over one link, and the other device answered keepalives on it (counted at the far end).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_long_fetch_keeps_its_link_and_the_other_device_answers_keepalives() {
    let (ka, kb) = (SecretKey::generate(), SecretKey::generate());
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a_store = Store::open(&da.path().join("store"), Options::default()).unwrap();
    let b_store = Store::open(&db.path().join("store"), Options::default()).unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let pport = proxy(port, Duration::from_millis(45), 1.2e6).await;
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
    let a = RnsNode::start(cfg(&ka, Iface::TcpListen(format!("127.0.0.1:{port}")), &kb, &a_store), Arc::new(Nothing)).await.unwrap();
    let b = RnsNode::start(cfg(&kb, Iface::TcpConnect(format!("127.0.0.1:{pport}")), &ka, &b_store), Arc::new(Nothing)).await.unwrap();
    let end = Instant::now() + Duration::from_secs(30);
    while !(b.reachable(&ka.public()) && a.reachable(&kb.public())) {
        assert!(Instant::now() < end, "the two devices hear each other within 30 s");
        let _ = a.announce().await;
        let _ = b.announce().await;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let data = random(70 * 1024 * 1024, 5);
    let hash = a_store.add_bytes(&data).unwrap().hash;
    let t = Instant::now();
    let r = fetch(&b, &ka.public(), &b_store, hash, Duration::from_secs(120), |_| {}).await;
    let took = t.elapsed();
    let f = r.unwrap_or_else(|e| panic!("the fetch stopped after {took:?}: {e:#}"));
    assert_eq!(f.have, f.size);
    assert!(took > Duration::from_secs(44), "the fetch outlasts the stale-link teardown ({took:?})");
    let hellos = a.hellos_answered();
    assert!(hellos >= 4, "the far end answered keepalives on top of the first hello: {hellos}");
    assert!(b_store.get_bytes(&hash).unwrap() == data);
}
