//! Nearby linking on real Prns nodes over loopback TCP (the test switch makes TCP count as local): what a pairing address
//! answers and when, and that its announces stop when its page closes.

use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::{bail, Result};
use cache_rns::nearby::NAME_PATH;
use cache_rns::{Asker, BoxFut, Config, Handler, Iface, PairSelf, RnsNode};
use iroh::{PublicKey, SecretKey};

struct Quiet;

impl Handler for Quiet {
    fn request(&self, _asker: Asker, _path: &str, _body: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        Box::pin(async { bail!("no") })
    }
    fn notify(&self, _from: PublicKey, _body: Vec<u8>) {}
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

async fn node(iface: Iface, local_tcp: bool) -> Arc<RnsNode> {
    let cfg = Config {
        device: SecretKey::generate(),
        interfaces: vec![iface],
        peers: vec![],
        wifi_group: None,
        paths: vec![],
        open_paths: vec![],
        max_bytes: 1024 * 1024,
        blobs: None,
        pair_local_tcp: local_tcp,
    };
    Arc::new(RnsNode::start(cfg, Arc::new(Quiet)).await.unwrap())
}

async fn until(what: &str, secs: u64, mut f: impl FnMut() -> bool) {
    let end = Instant::now() + Duration::from_secs(secs);
    while !f() {
        assert!(Instant::now() < end, "{what} within {secs} s");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn me(name: &str, kind: &str) -> PairSelf {
    PairSelf { name: name.into(), kind: Some(kind.into()) }
}

/// A node that never opened its page gets no answer to the name path; one with its page open does; after the page closes its
/// announces stop, its name path is silent again, and it drops out of the other's list. A used address is not used again.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn name_privacy_and_page_close() {
    let port = free_port();
    let a = node(Iface::TcpListen(format!("127.0.0.1:{port}")), true).await;
    let b = node(Iface::TcpConnect(format!("127.0.0.1:{port}")), true).await;
    a.pair_open(me("Desk", "computer")).await.unwrap();

    // B never opened its page. Its first pairing address is announced anyway (a test hook), so A can reach it, and it is
    // still silent on the name path.
    let unopened = b.nearby().pool()[0];
    let n = a.nearby().clone();
    b.nearby().announce_unopened(0).await;
    until("A to hear B's unopened pairing address", 20, || n.announces_heard(&unopened) > 0).await;
    let r = a.nearby().ask(unopened, NAME_PATH, b"", Duration::from_secs(4)).await;
    assert!(r.is_err(), "a node that never opened its page answers no name: {r:?}");
    assert!(a.pair_list().is_empty(), "and is not listed");

    // Page open: it answers, and A lists it with the name and kind.
    b.pair_open(me("Phone", "phone")).await.unwrap();
    let active = b.nearby().active().expect("a page is open");
    until("A to list B", 30, || a.pair_list().iter().any(|d| d.name.as_deref() == Some("Phone") && d.kind.as_deref() == Some("phone"))).await;
    let got = a.nearby().ask(active, NAME_PATH, b"", Duration::from_secs(5)).await.unwrap();
    let v: serde_json::Value = serde_json::from_slice(&got).unwrap();
    assert_eq!((v["name"].as_str(), v["kind"].as_str()), (Some("Phone"), Some("phone")));

    // Page closed: the announces stop.
    b.pair_close().await;
    tokio::time::sleep(Duration::from_millis(1500)).await;
    let heard = a.nearby().announces_heard(&active);
    assert!(heard > 0);
    tokio::time::sleep(Duration::from_secs(15)).await;
    assert_eq!(a.nearby().announces_heard(&active), heard, "no new announce from the closed page for 15 s");
    let r = a.nearby().ask(active, NAME_PATH, b"", Duration::from_secs(4)).await;
    assert!(r.is_err(), "the name path no longer answers: {r:?}");
    until("B to drop out of A's list", 20, || a.pair_list().is_empty()).await;

    // The next page takes a different pairing address.
    b.pair_open(me("Phone", "phone")).await.unwrap();
    assert_ne!(b.nearby().active().unwrap(), active, "a pairing address is never reused");
    a.stop();
    b.stop();
}

/// In production TCP is not local: a pairing address is not announced on it, and an announce heard on it is not listed.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn no_pairing_announce_on_tcp_by_default() {
    let port = free_port();
    let a = node(Iface::TcpListen(format!("127.0.0.1:{port}")), false).await;
    let b = node(Iface::TcpConnect(format!("127.0.0.1:{port}")), false).await;
    a.pair_open(me("Desk", "computer")).await.unwrap();
    b.pair_open(me("Phone", "phone")).await.unwrap();
    let dest = b.nearby().active().unwrap();
    // The node's own announce (every 30 s) is heard, so the TCP link works; the pairing address is never sent.
    let own = a.nearby().clone();
    tokio::time::sleep(Duration::from_secs(12)).await;
    assert_eq!(own.announces_heard(&dest), 0, "no pairing announce on a TCP interface");
    assert!(a.pair_list().is_empty() && b.pair_list().is_empty());
    a.stop();
    b.stop();
}

/// A page that is left open closes itself after 15 minutes (the test clock): its paths go and it stops being announced.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_page_left_open_closes_after_fifteen_minutes() {
    let port = free_port();
    let a = node(Iface::TcpListen(format!("127.0.0.1:{port}")), true).await;
    a.pair_open(me("Desk", "computer")).await.unwrap();
    let dest = a.nearby().active().expect("open");
    a.nearby().skew_clock(14 * 60 * 1000);
    tokio::time::sleep(Duration::from_millis(800)).await;
    assert_eq!(a.nearby().active(), Some(dest), "still open at 14 minutes");
    a.nearby().skew_clock(61 * 1000);
    until("the page to close", 5, || a.nearby().active().is_none()).await;
    assert_eq!(a.pair_status().state, "idle");
    a.stop();
}

/// Only a `cache.pair.v1` announce is taken for one: a device's ordinary announce (its main destination) is heard but is
/// not a pairing announce, so it is never counted, listed or contacted.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_ordinary_announce_is_not_a_pairing_announce() {
    let port = free_port();
    let a = node(Iface::TcpListen(format!("127.0.0.1:{port}")), true).await;
    let b = node(Iface::TcpConnect(format!("127.0.0.1:{port}")), true).await;
    a.pair_open(me("Desk", "computer")).await.unwrap();
    let main = b.destination();
    b.announce().await.unwrap();
    tokio::time::sleep(Duration::from_secs(4)).await;
    assert_eq!(a.nearby().announces_heard(&main), 0, "B's main announce is not a pairing announce");
    assert!(a.pair_list().is_empty());
    // A real pairing announce, in the same conditions, is recognised.
    b.pair_open(me("Phone", "phone")).await.unwrap();
    let pair = b.nearby().active().unwrap();
    let n = a.nearby().clone();
    until("the pairing announce to be heard", 20, || n.announces_heard(&pair) > 0).await;
    a.stop();
    b.stop();
}
