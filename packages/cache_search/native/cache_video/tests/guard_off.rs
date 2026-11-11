//! cache_video with the guard not installed (a phone): a LAN or loopback instance is reached as it always was. See guard_on.rs.

use cache_video::{Video, VideoCfg};
use std::io::{Read, Write};
use std::net::TcpListener;

#[test]
fn without_the_guard_a_loopback_instance_is_reachable() {
    assert!(!cache_netguard::installed());
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    let body = r#"{"serverVersion":"6.0.0","instance":{"name":"home"}}"#;
    let reply = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
    std::thread::spawn(move || {
        for s in l.incoming() {
            let Ok(mut s) = s else { break };
            let mut buf = [0u8; 4096];
            let _ = s.read(&mut buf);
            let _ = s.write_all(reply.as_bytes());
        }
    });
    let dir = std::env::temp_dir().join(format!("cv-guard-off-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let v = Video::new(&VideoCfg { dir: dir.to_string_lossy().into_owned() });
    let out = v.instance_add(&format!(r#"{{"url":"http://127.0.0.1:{port}"}}"#)).unwrap();
    assert!(out.contains("home"), "{out}");
    let _ = std::fs::remove_dir_all(dir);
}
