//! cache.log says why a Reticulum link closed: the node tells its handler the reason when a link to a linked device closes.

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use cache_rns::{destination_for, Asker, BoxFut, Config, Handler, Iface, RnsNode};
use iroh::{PublicKey, SecretKey};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};

/// The device, the reason, how long the link was open and its round trip time, as the handler was told.
type Closed = (PublicKey, String, Option<u64>, Option<u64>);

#[derive(Default)]
struct Rec {
    closed: Mutex<Vec<Closed>>,
}
impl Handler for Rec {
    fn request(&self, _: Asker, _: &str, _: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        Box::pin(async { Ok(Vec::new()) })
    }
    fn notify(&self, _: PublicKey, _: Vec<u8>) {}
    fn link_closed(&self, peer: PublicKey, reason: &str, secs: Option<u64>, rtt: Option<u64>) {
        self.closed.lock().unwrap().push((peer, reason.to_string(), secs, rtt));
    }
}

/// A TCP relay that can go silent (the connection stays up, nothing crosses): the blackhole of a Wi-Fi path that has gone away.
async fn pipe(hole: Arc<AtomicBool>, mut r: tokio::net::tcp::OwnedReadHalf, mut w: tokio::net::tcp::OwnedWriteHalf) {
    let mut buf = vec![0u8; 16 * 1024];
    while let Ok(n) = r.read(&mut buf).await {
        if n == 0 {
            break;
        }
        if hole.load(Ordering::Relaxed) {
            continue;
        }
        if w.write_all(&buf[..n]).await.is_err() {
            break;
        }
    }
}

async fn proxy(hole: Arc<AtomicBool>, to: u16) -> u16 {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    tokio::spawn(async move {
        loop {
            let Ok((c, _)) = l.accept().await else { break };
            let Ok(s) = TcpStream::connect(("127.0.0.1", to)).await else { continue };
            let (cr, cw) = c.into_split();
            let (sr, sw) = s.into_split();
            tokio::spawn(pipe(hole.clone(), cr, sw));
            tokio::spawn(pipe(hole.clone(), sr, cw));
        }
    });
    port
}

async fn two(hole: Arc<AtomicBool>) -> (RnsNode, RnsNode, SecretKey, SecretKey, Arc<Rec>, Arc<Rec>) {
    let (ka, kb) = (SecretKey::generate(), SecretKey::generate());
    let port = std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let pport = proxy(hole, port).await;
    let cfg = |k: &SecretKey, i: Iface, peer: &SecretKey| Config {
        device: k.clone(),
        interfaces: vec![i],
        peers: vec![(peer.public(), Some(destination_for(peer).unwrap()))],
        wifi_group: None,
        paths: vec!["/x".to_string()],
        open_paths: vec!["/x".to_string()],
        max_bytes: 64 * 1024 * 1024,
        blobs: None,
        pair_local_tcp: false,
    };
    let (ra, rb) = (Arc::new(Rec::default()), Arc::new(Rec::default()));
    let a = RnsNode::start(cfg(&ka, Iface::TcpListen(format!("127.0.0.1:{port}")), &kb), ra.clone()).await.unwrap();
    let b = RnsNode::start(cfg(&kb, Iface::TcpConnect(format!("127.0.0.1:{pport}")), &ka), rb.clone()).await.unwrap();
    let end = Instant::now() + Duration::from_secs(30);
    while !(b.reachable(&ka.public()) && a.reachable(&kb.public())) {
        assert!(Instant::now() < end, "the two devices hear each other within 30 s");
        let _ = a.announce().await;
        let _ = b.announce().await;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    (a, b, ka, kb, ra, rb)
}

/// A link that goes silent is closed by Prns's stale teardown; the handler is told, with the reason a timeout.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_silent_link_closes_with_a_timeout_reason() {
    let hole = Arc::new(AtomicBool::new(false));
    let (_a, b, ka, _kb, ra, rb) = two(hole.clone()).await;
    // The link opens (and the hello that makes it a linked device's link is answered) before the path goes silent.
    let r = b.request(&ka.public(), "/x", b"", Duration::from_secs(10)).await;
    assert!(r.is_ok(), "the request is answered: {r:?}");
    hole.store(true, Ordering::Relaxed);
    let end = Instant::now() + Duration::from_secs(120);
    loop {
        {
            let c = rb.closed.lock().unwrap();
            if !c.is_empty() {
                let (peer, reason, secs, rtt) = &c[0];
                assert_eq!(*peer, ka.public(), "the line names the linked device");
                assert!(reason.starts_with("timeout"), "the reason is a timeout, not {reason:?}");
                assert!(secs.is_some(), "how long it was open is known");
                let _ = rtt; // the end that opened the link is not told its round trip time by Prns
                break;
            }
        }
        assert!(Instant::now() < end, "the stale link is closed within 120 s");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
    // The other end (which was told the round trip time) says it too.
    let end = Instant::now() + Duration::from_secs(60);
    loop {
        if let Some((peer, reason, secs, rtt)) = ra.closed.lock().unwrap().first() {
            assert_eq!(*peer, _kb.public());
            assert!(reason.starts_with("timeout"), "the reason is a timeout, not {reason:?}");
            assert!(secs.is_some() && rtt.is_some(), "how long it was open and its round trip time are known");
            break;
        }
        assert!(Instant::now() < end, "the other end closes it too");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}

/// A device that stops: the other end's handler is told (the reason is the other device closing it, or a timeout if it vanished).
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_stopped_device_closes_its_link_with_a_reason() {
    let hole = Arc::new(AtomicBool::new(false));
    let (a, b, ka, _kb, _ra, rb) = two(hole).await;
    let r = b.request(&ka.public(), "/x", b"", Duration::from_secs(10)).await;
    assert!(r.is_ok(), "the request is answered: {r:?}");
    a.stop();
    let end = Instant::now() + Duration::from_secs(60);
    loop {
        if let Some((peer, reason, _, _)) = rb.closed.lock().unwrap().first() {
            assert_eq!(*peer, ka.public());
            assert!(!reason.is_empty());
            println!("reason after stop: {reason}");
            break;
        }
        assert!(Instant::now() < end, "the link to a stopped device is reported closed within 60 s");
        tokio::time::sleep(Duration::from_millis(500)).await;
    }
}
