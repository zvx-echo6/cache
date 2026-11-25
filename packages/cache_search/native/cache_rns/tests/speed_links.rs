//! Speed classes on real links (design 2b): a stand-in link (a local TCP proxy with a delay each way) is classed Fast, Medium or
//! Slow by its round trip time; each end checks what it asks and what it answers; a modified asker that ignores its class is
//! refused; and a link that gets faster is judged again.

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use cache_rns::blobs::{self, encode_want, fetch, is_too_slow, TOO_SLOW, WINDOW_CHUNKS};
use cache_rns::{destination_for, Asker, BoxFut, Config, Handler, Iface, RnsNode, Speed};
use cache_store::{Hash, Options, Store};
use iroh::{PublicKey, SecretKey};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

struct Small;
impl Handler for Small {
    fn request(&self, _: Asker, _: &str, _: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        Box::pin(async { Ok(b"ok".to_vec()) })
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

/// One direction: bytes read are written `delay` later (the delay is read as each chunk arrives, so it can change).
async fn pipe(delay_ms: Arc<AtomicU64>, mut r: tokio::net::tcp::OwnedReadHalf, mut w: tokio::net::tcp::OwnedWriteHalf) {
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<(Instant, Vec<u8>)>();
    tokio::spawn(async move {
        let mut buf = vec![0u8; 16 * 1024];
        loop {
            match r.read(&mut buf).await {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    let due = Instant::now() + Duration::from_millis(delay_ms.load(Ordering::Relaxed));
                    if tx.send((due, buf[..n].to_vec())).is_err() {
                        break;
                    }
                }
            }
        }
    });
    while let Some((due, bytes)) = rx.recv().await {
        tokio::time::sleep_until(due.into()).await;
        if w.write_all(&bytes).await.is_err() {
            break;
        }
    }
}

async fn proxy(to: u16, delay_ms: Arc<AtomicU64>) -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let Ok((c, _)) = l.accept().await else { break };
            let Ok(s) = TcpStream::connect(("127.0.0.1", to)).await else { continue };
            let (cr, cw) = c.into_split();
            let (sr, sw) = s.into_split();
            tokio::spawn(pipe(delay_ms.clone(), cr, sw));
            tokio::spawn(pipe(delay_ms.clone(), sr, cw));
        }
    });
    port
}

struct Link {
    a: RnsNode,
    b: RnsNode,
    ka: PublicKey,
    kb: PublicKey,
    a_store: Store,
    b_store: Store,
    delay: Arc<AtomicU64>,
    _dirs: (tempfile::TempDir, tempfile::TempDir),
}

/// A (listening, holds the files) and B (connects through the proxy, asks), with `delay_ms` each way on the way between them.
async fn link(delay_ms: u64) -> Link {
    let (ska, skb) = (SecretKey::generate(), SecretKey::generate());
    let (da, db) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
    let a_store = Store::open(&da.path().join("store"), Options::default()).unwrap();
    let b_store = Store::open(&db.path().join("store"), Options::default()).unwrap();
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let delay = Arc::new(AtomicU64::new(delay_ms));
    let pport = proxy(port, delay.clone()).await;
    let cfg = |k: &SecretKey, i: Iface, peer: &SecretKey, store: &Store| Config {
        device: k.clone(),
        interfaces: vec![i],
        peers: vec![(peer.public(), Some(destination_for(peer).unwrap()))],
        wifi_group: None,
        paths: vec!["/x".into()],
        open_paths: vec![],
        max_bytes: 64 * 1024 * 1024,
        blobs: Some(store.clone()),
        pair_local_tcp: false,
    };
    let a = RnsNode::start(cfg(&ska, Iface::TcpListen(format!("127.0.0.1:{port}")), &skb, &a_store), Arc::new(Small)).await.unwrap();
    let b = RnsNode::start(cfg(&skb, Iface::TcpConnect(format!("127.0.0.1:{pport}")), &ska, &b_store), Arc::new(Small)).await.unwrap();
    // The probes in these tests are made at every request, so a changed link is judged at the next one.
    a.speeds().set_probe_every(Duration::ZERO);
    b.speeds().set_probe_every(Duration::ZERO);
    let end = Instant::now() + Duration::from_secs(60);
    while !(b.reachable(&ska.public()) && a.reachable(&skb.public())) {
        assert!(Instant::now() < end, "the two devices hear each other within 60 s");
        let _ = a.announce().await;
        let _ = b.announce().await;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    Link { a, b, ka: ska.public(), kb: skb.public(), a_store, b_store, delay, _dirs: (da, db) }
}

/// B asks A something small, so a link exists and its round trip time is known on both ends.
async fn touch(l: &Link) {
    let r = l.b.request(&l.ka, "/x", b"", Duration::from_secs(60)).await.unwrap();
    assert_eq!(r, b"ok");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_slow_link_is_classed_slow_on_both_ends_and_carries_no_file() {
    let l = link(900).await;
    touch(&l).await;
    assert_eq!(l.b.speeds().ask_speed(&l.ka), Speed::Slow, "the asking end");
    // The answering end learns the round trip time from the link when it is up.
    let end = Instant::now() + Duration::from_secs(20);
    while l.a.speeds().serve_speed(&l.kb) != Speed::Slow {
        assert!(Instant::now() < end, "A classes B's link as slow");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    let data = random(2 * 1024 * 1024, 3);
    let hash = l.a_store.add_bytes(&data).unwrap().hash;
    // An honest asker does not ask: it is told it is too slow, and holds nothing of the file.
    let r = fetch(&l.b, &l.ka, &l.b_store, hash, Duration::from_secs(60), |_| {}).await;
    let e = r.expect_err("a slow link carries no file");
    assert!(is_too_slow(&e), "{e:#}");
    assert!(!l.b_store.has(&hash).unwrap_or(false));
    // A modified asker that ignores its class is refused by the answering end, whatever it asks for.
    let reply = l.b.request(&l.ka, blobs::BLOB_PATH, &encode_want(&hash, 0, 64), Duration::from_secs(60)).await.unwrap();
    assert_eq!(reply, vec![TOO_SLOW], "the slow answering end refuses the window");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_medium_link_carries_small_files_in_one_mib_windows_and_nothing_big() {
    let l = link(200).await;
    touch(&l).await;
    assert_eq!(l.b.speeds().ask_speed(&l.ka), Speed::Medium);
    let end = Instant::now() + Duration::from_secs(20);
    while l.a.speeds().serve_speed(&l.kb) != Speed::Medium {
        assert!(Instant::now() < end, "A classes B's link as medium");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    // 5 MiB: five windows of 1 MiB.
    let small = random(5 * 1024 * 1024, 5);
    let hs = l.a_store.add_bytes(&small).unwrap().hash;
    let f = fetch(&l.b, &l.ka, &l.b_store, hs, Duration::from_secs(120), |_| {}).await.unwrap();
    assert_eq!((f.size, f.windows), (5 * 1024 * 1024, 5), "1 MiB windows");
    assert!(l.b_store.get_bytes(&hs).unwrap() == small);
    // 20 MiB is more than a medium link carries: not fetched.
    let big = random(20 * 1024 * 1024, 6);
    let hb = l.a_store.add_bytes(&big).unwrap().hash;
    let e = fetch(&l.b, &l.ka, &l.b_store, hb, Duration::from_secs(120), |_| {}).await.expect_err("too big for medium");
    assert!(is_too_slow(&e), "{e:#}");
    assert!(!l.b_store.has(&hb).unwrap_or(false));
    // A modified asker: a 16 MiB window, or a window of the 20 MiB file, is refused by the answering end.
    let r = l.b.request(&l.ka, blobs::BLOB_PATH, &encode_want(&hs, 0, WINDOW_CHUNKS), Duration::from_secs(120)).await.unwrap();
    assert_eq!(r, vec![TOO_SLOW], "a 16 MiB window is too big for medium");
    let r = l.b.request(&l.ka, blobs::BLOB_PATH, &encode_want(&hb, 0, 1024), Duration::from_secs(120)).await.unwrap();
    assert_eq!(r, vec![TOO_SLOW], "a 20 MiB file is too big for medium");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_fast_link_is_as_it_was() {
    let l = link(1).await;
    touch(&l).await;
    assert_eq!(l.b.speeds().ask_speed(&l.ka), Speed::Fast);
    let data = random(20 * 1024 * 1024 + 77, 8);
    let hash = l.a_store.add_bytes(&data).unwrap().hash;
    let f = fetch(&l.b, &l.ka, &l.b_store, hash, Duration::from_secs(120), |_| {}).await.unwrap();
    assert_eq!(f.windows, 2, "16 MiB windows");
    assert!(l.b_store.get_bytes(&hash).unwrap() == data);
    let _ = Hash::new(b"");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_link_that_gets_faster_is_judged_again_on_both_ends() {
    let l = link(900).await;
    touch(&l).await;
    assert_eq!(l.b.speeds().ask_speed(&l.ka), Speed::Slow);
    let data = random(3 * 1024 * 1024, 4);
    let hash = l.a_store.add_bytes(&data).unwrap().hash;
    assert!(is_too_slow(&fetch(&l.b, &l.ka, &l.b_store, hash, Duration::from_secs(60), |_| {}).await.expect_err("slow")));
    // The path gets fast under the idle link: the next small request is the measurement, and the link is made again so the
    // answering end gets the new round trip time too.
    l.delay.store(1, Ordering::Relaxed);
    let stop = Arc::new(AtomicBool::new(false));
    let _ = &stop;
    let end = Instant::now() + Duration::from_secs(90);
    loop {
        touch(&l).await;
        if l.b.speeds().ask_speed(&l.ka) == Speed::Fast && l.a.speeds().serve_speed(&l.kb) == Speed::Fast {
            break;
        }
        assert!(Instant::now() < end, "both ends judge the link fast: B {:?}, A {:?}", l.b.speeds().ask_speed(&l.ka), l.a.speeds().serve_speed(&l.kb));
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    let f = fetch(&l.b, &l.ka, &l.b_store, hash, Duration::from_secs(60), |_| {}).await.unwrap();
    assert_eq!(f.size, 3 * 1024 * 1024);
    assert!(l.b_store.get_bytes(&hash).unwrap() == data);
}
