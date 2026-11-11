//! cache_live with the public-address guard installed (what the Linux server's helper does): its request client refuses a LAN or loopback address and a redirect to one.
//! Separate from guard_off.rs because the guard is installed per process.

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
fn a_loopback_or_lan_address_is_refused_and_nothing_connects() {
    cache_netguard::install();
    let (port, hits) = listen("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".to_string());
    let r = cache_live::request::agent(5).get(&format!("http://127.0.0.1:{port}/x")).call();
    assert!(r.is_err());
    assert_eq!(hits.load(Ordering::SeqCst), 0, "the guard must refuse before any connection");
    for u in ["https://192.168.1.240/x", "https://169.254.169.254/latest/meta-data", "https://10.0.0.1/x", "https://100.64.0.4/x"] {
        let r = cache_live::request::agent(5).get(u).call();
        assert!(r.is_err(), "{u}");
    }
}

#[test]
fn a_redirect_to_a_private_address_is_refused() {
    cache_netguard::install();
    // the second server is what an unguarded client would reach through ::ffff:127.0.0.1 (the same machine, spelled as an IPv6 address)
    let (port2, hits2) = listen("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".to_string());
    let (port1, hits1) = listen(format!("HTTP/1.1 302 Found\r\nLocation: http://[::ffff:127.0.0.1]:{port2}/x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"));
    // the first hop is allowed for this thread only (a stand-in for a public host); the hop after it is not
    let _scope = cache_netguard::loopback_here_for_tests();
    let r = cache_live::request::agent(5).get(&format!("http://127.0.0.1:{port1}/x")).call();
    assert!(r.is_err());
    assert!(hits1.load(Ordering::SeqCst) >= 1, "the first hop was reached");
    assert_eq!(hits2.load(Ordering::SeqCst), 0, "the redirect target must not be connected to");
}
