//! The web read and web search are guarded against private addresses on every platform, with no setting: what the model reads is
//! public by definition. This process never lets loopback through (tests/web_ffi.rs, which stands servers up on this machine, does),
//! so a local server is a private address here and must not be connected to.

use cache_search::web::{fetch_page, http_get, HttpFail, Page};
use std::io::{Read, Write};
use std::net::TcpListener;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

fn soon() -> Instant {
    Instant::now() + Duration::from_secs(5)
}

#[test]
fn a_private_address_is_refused_with_no_guard_setting_and_nothing_connects() {
    assert!(std::env::var_os("CACHE_NET_GUARD").is_none());
    assert!(!cache_netguard::installed());
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    let hits = Arc::new(AtomicUsize::new(0));
    let h = hits.clone();
    std::thread::spawn(move || {
        for s in l.incoming() {
            let Ok(mut s) = s else { break };
            h.fetch_add(1, Ordering::SeqCst);
            let mut buf = [0u8; 2048];
            let _ = s.read(&mut buf);
            let _ = s.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 12\r\nConnection: close\r\n\r\n<p>inside</p>");
        }
    });
    let url = format!("http://127.0.0.1:{port}/p");
    // the read: the existing "not available" outcome
    assert_eq!(fetch_page(&url, soon(), 1 << 16), Page::Unavailable);
    // the raw page request: the connect-layer failure
    let f = http_get(&url, &[], soon(), 1 << 16).unwrap_err();
    assert_eq!(f.kind, HttpFail::Connect, "{f:?}");
    for u in ["http://192.168.1.240/x", "http://169.254.169.254/latest/meta-data/", "http://[::ffff:10.0.0.1]/x", "http://0x7f.1/x", "http://2130706433/x", "http://[::1]/x"] {
        assert_eq!(fetch_page(u, soon(), 1 << 16), Page::Unavailable, "{u}");
        assert_eq!(http_get(u, &[], soon(), 1 << 16).unwrap_err().kind, HttpFail::Connect, "{u}");
    }
    assert_eq!(hits.load(Ordering::SeqCst), 0, "no connection may be made to a private address");
}

#[test]
fn a_page_read_that_redirects_to_127_0_0_1_is_refused() {
    // Only the origin's own port is let through (a stand-in for a public page); the redirect target is plain 127.0.0.1 on another
    // port, with nothing enabling it, as is every private address.
    let hits2 = Arc::new(AtomicUsize::new(0));
    let l2 = TcpListener::bind("127.0.0.1:0").unwrap();
    let port2 = l2.local_addr().unwrap().port();
    let h = hits2.clone();
    std::thread::spawn(move || {
        for s in l2.incoming() {
            let Ok(mut s) = s else { break };
            h.fetch_add(1, Ordering::SeqCst);
            let mut buf = [0u8; 2048];
            let _ = s.read(&mut buf);
            let _ = s.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 12\r\nConnection: close\r\n\r\n<p>inside</p>");
        }
    });
    let l1 = TcpListener::bind("127.0.0.1:0").unwrap();
    let port1 = l1.local_addr().unwrap().port();
    let hits1 = Arc::new(AtomicUsize::new(0));
    let h = hits1.clone();
    std::thread::spawn(move || {
        for s in l1.incoming() {
            let Ok(mut s) = s else { break };
            h.fetch_add(1, Ordering::SeqCst);
            let mut buf = [0u8; 2048];
            let _ = s.read(&mut buf);
            let _ = s.write_all(format!("HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:{port2}/secret\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes());
        }
    });
    cache_netguard::loopback_port_for_tests(port1);
    assert_eq!(fetch_page(&format!("http://127.0.0.1:{port1}/p"), soon(), 1 << 16), Page::Unavailable);
    assert!(hits1.load(Ordering::SeqCst) >= 1, "the origin was reached");
    assert_eq!(hits2.load(Ordering::SeqCst), 0, "the redirect target must not be connected to");
}
