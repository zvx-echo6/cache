//! cache_video with the public-address guard installed (what the Linux server's helper does): a LAN or loopback instance, and a
//! redirect to one, are refused at connect time. The phone path (guard not installed) is tests/guard_off.rs; the two are separate
//! test binaries because the guard is installed per process.

use cache_video::{Video, VideoCfg};
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

fn video(name: &str) -> (std::path::PathBuf, Video) {
    let dir = std::env::temp_dir().join(format!("cv-guard-on-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let v = Video::new(&VideoCfg { dir: dir.to_string_lossy().into_owned() });
    (dir, v)
}

#[test]
fn a_loopback_or_lan_instance_is_refused_and_nothing_connects() {
    cache_netguard::install();
    let body = r#"{"serverVersion":"6.0.0","instance":{"name":"x"}}"#;
    let (port, hits) = listen(format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()));
    let (dir, v) = video("lan");
    assert!(v.instance_add(&format!(r#"{{"url":"http://127.0.0.1:{port}"}}"#)).is_err());
    assert_eq!(hits.load(Ordering::SeqCst), 0, "the guard must refuse before any connection");
    assert!(v.instance_add(r#"{"url":"https://192.168.1.240"}"#).is_err());
    assert!(v.instance_add(r#"{"url":"https://169.254.169.254"}"#).is_err());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_redirect_to_a_private_address_is_refused() {
    cache_netguard::install();
    // the second server is what an unguarded client would reach through ::ffff:127.0.0.1 (the same machine, spelled as an IPv6 address)
    let (port2, hits2) = listen("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}".to_string());
    let (port1, hits1) = listen(format!("HTTP/1.1 302 Found\r\nLocation: http://[::ffff:127.0.0.1]:{port2}/api/v1/config\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"));
    let (dir, v) = video("redirect");
    // the first hop is allowed for this thread only (a stand-in for a public instance); the hop after it is not
    let _scope = cache_netguard::loopback_here_for_tests();
    assert!(v.instance_add(&format!(r#"{{"url":"http://127.0.0.1:{port1}"}}"#)).is_err());
    assert!(hits1.load(Ordering::SeqCst) >= 1, "the first hop was reached");
    assert_eq!(hits2.load(Ordering::SeqCst), 0, "the redirect target must not be connected to");
    let _ = std::fs::remove_dir_all(dir);
}
