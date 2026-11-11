//! cache_live with the guard not installed (a phone): its request client reaches this machine, as it always did.
//! Separate from guard_on.rs because the guard is installed per process.

use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;

/// A local server that counts connections and answers each with `reply`, raw.
fn listen(reply: String) -> (u16, Arc<AtomicUsize>) {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    let hits = Arc::new(AtomicUsize::new(0));
    let h = hits.clone();
    std::thread::spawn(move || {
        for s in l.incoming() {
            let Ok(mut s) = s else { break };
            h.fetch_add(1, Ordering::SeqCst);
            let mut buf = [0u8; 4096];
            let _ = s.read(&mut buf);
            let _ = s.write_all(reply.as_bytes());
        }
    });
    (port, hits)
}

#[test]
fn without_the_guard_a_loopback_address_is_reachable() {
    assert!(!cache_netguard::installed());
    let (port, hits) = listen("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".to_string());
    let r = cache_live::request::agent(5).get(&format!("http://127.0.0.1:{port}/x")).call();
    assert!(r.is_ok(), "{:?}", r.err());
    assert_eq!(hits.load(Ordering::SeqCst), 1);
}

/// The client follows no redirect by itself (it would carry a key header to any host and go from https to http): the request
/// code follows them, one checked hop at a time. tests/redirects.rs has those, on this machine and without the guard as here.
#[test]
fn the_client_follows_no_redirect_by_itself() {
    assert!(!cache_netguard::installed());
    let (port2, hits2) = listen("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".to_string());
    let (port1, hits1) = listen(format!("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{port2}/x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"));
    let r = cache_live::request::agent(5).get(&format!("http://127.0.0.1:{port1}/x")).call();
    assert_eq!(r.map(|r| r.status()).ok(), Some(302));
    assert_eq!((hits1.load(Ordering::SeqCst), hits2.load(Ordering::SeqCst)), (1, 0));
}
