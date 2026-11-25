//! Speed classes on real links (design 2b): a stand-in link (a local TCP proxy with a delay each way) is classed Fast, Medium or
//! Slow by its round trip time; each end checks what it asks and what it answers; a modified asker that ignores its class is
//! refused; and a link that gets faster is judged again.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use cache_rns::blobs::{self, encode_want, fetch, is_too_slow, TOO_SLOW, WINDOW_CHUNKS};
use cache_rns::{destination_for, Asker, BoxFut, Config, Handler, Iface, RnsNode, Speed};
use cache_store::{Hash, Options, Store};
use iroh::{PublicKey, SecretKey};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// Answers "ok" and counts the links that closed on its end.
#[derive(Default)]
struct Small {
    closed: Arc<AtomicU64>,
}
impl Handler for Small {
    fn request(&self, _: Asker, _: &str, _: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        Box::pin(async { Ok(b"ok".to_vec()) })
    }
    fn notify(&self, _: PublicKey, _: Vec<u8>) {}
    fn link_closed(&self, _: PublicKey, _: &str, _: Option<u64>, _: Option<u64>) {
        self.closed.fetch_add(1, Ordering::SeqCst);
    }
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
    /// Links that closed, as each end's handler was told.
    closed: (Arc<AtomicU64>, Arc<AtomicU64>),
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
    let (ha, hb) = (Small::default(), Small::default());
    let closed = (ha.closed.clone(), hb.closed.clone());
    let a = RnsNode::start(cfg(&ska, Iface::TcpListen(format!("127.0.0.1:{port}")), &skb, &a_store), Arc::new(ha)).await.unwrap();
    let b = RnsNode::start(cfg(&skb, Iface::TcpConnect(format!("127.0.0.1:{pport}")), &ska, &b_store), Arc::new(hb)).await.unwrap();
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
    Link { a, b, ka: ska.public(), kb: skb.public(), a_store, b_store, delay, closed, _dirs: (da, db) }
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

/// Item 1 (cache-pm): an idle-link measurement that changes the class updates the class on the asking end and does NOT close or
/// re-make the link. The answering end keeps its own estimate (the round trip time Reticulum gave it when the link came up, plus
/// the first hop): Prns fixes a link's round trip time when it comes up and gives the app no newer one, so nothing but a new link
/// would change it.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_class_change_keeps_the_same_link() {
    for (from, to, was, now) in [(900u64, 1u64, Speed::Slow, Speed::Fast), (1, 900, Speed::Fast, Speed::Slow)] {
        let l = link(from).await;
        touch(&l).await;
        assert_eq!(l.b.speeds().ask_speed(&l.ka), was);
        let id = l.b.link_id_to(&l.ka).expect("B has a link to A");
        let answering = l.a.speeds().serve_speed(&l.kb);
        l.delay.store(to, Ordering::Relaxed);
        let end = Instant::now() + Duration::from_secs(90);
        while l.b.speeds().ask_speed(&l.ka) != now {
            assert!(Instant::now() < end, "B's class follows the measurement: now {:?}", l.b.speeds().ask_speed(&l.ka));
            let _ = l.b.request(&l.ka, "/x", b"", Duration::from_secs(60)).await.unwrap();
            tokio::time::sleep(Duration::from_millis(300)).await;
        }
        assert_eq!(l.b.link_id_to(&l.ka), Some(id), "the same link, not made again");
        assert_eq!(l.closed.0.load(Ordering::SeqCst) + l.closed.1.load(Ordering::SeqCst), 0, "no link closed on either end");
        assert_eq!(l.a.speeds().serve_speed(&l.kb), answering, "the answering end keeps its own estimate");
    }
}

/// A device that also asks the other one (it has a link of its own to it) learns from its own probes: the answering end's class for
/// the other device's link then follows the path too, with no link closed or made again. (The path is the same one both ways.)
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_answering_end_follows_through_its_own_probes_when_it_asks_too() {
    let l = link(1).await;
    touch(&l).await;
    // A asks B too, so A has a link of its own to B.
    l.a.request(&l.kb, "/x", b"", Duration::from_secs(60)).await.unwrap();
    assert_eq!(l.a.speeds().serve_speed(&l.kb), Speed::Fast);
    let (ib, ia) = (l.b.link_id_to(&l.ka).unwrap(), l.a.link_id_to(&l.kb).unwrap());
    l.delay.store(900, Ordering::Relaxed);
    let end = Instant::now() + Duration::from_secs(120);
    while l.a.speeds().serve_speed(&l.kb) != Speed::Slow || l.b.speeds().ask_speed(&l.ka) != Speed::Slow {
        assert!(Instant::now() < end, "both ends follow: A answers {:?}, B asks {:?}", l.a.speeds().serve_speed(&l.kb), l.b.speeds().ask_speed(&l.ka));
        let _ = l.b.request(&l.ka, "/x", b"", Duration::from_secs(60)).await.unwrap();
        let _ = l.a.request(&l.kb, "/x", b"", Duration::from_secs(60)).await.unwrap();
        tokio::time::sleep(Duration::from_millis(300)).await;
    }
    assert_eq!((l.b.link_id_to(&l.ka).unwrap(), l.a.link_id_to(&l.kb).unwrap()), (ib, ia), "both links kept");
    assert_eq!(l.closed.0.load(Ordering::SeqCst) + l.closed.1.load(Ordering::SeqCst), 0, "no link closed");
}
