//! The closest test CI can run to "the browser adds a video instance on a LAN address while the Linux helper runs": the real core's
//! C entry point (`cs_video_instance_add`, which the helper's Dart FFI calls for the video op) with `CACHE_NET_GUARD=public` in the
//! process environment, as server/src/helper.rs sets it for the helper. A stand-in server on 127.0.0.1 must see no connection, and
//! the caller must get a prompt, clean `fetch_failed` error.
//!
//! Covered: core C entry -> cache_video -> the env-gated guard. Not covered here: the Dart helper process, the helper's op dispatch
//! and the Rust server's /api/core (no CI job runs those together with the real core). The server half, that the helper is started with
//! the variable, is server/tests/proxy.rs (`the_helper_is_started_with_the_public_address_guard_installed`).

use cache_search::ffi::*;
use serde_json::Value;
use std::ffi::{c_char, CStr, CString};
use std::io::{Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{mpsc, Arc};
use std::time::Duration;

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

#[test]
fn instance_add_of_a_lan_or_loopback_instance_is_refused_with_the_helpers_environment() {
    // exactly what the server puts in the helper's environment; set before anything builds a client (the variable is read once)
    std::env::set_var("CACHE_NET_GUARD", "public");

    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = l.local_addr().unwrap().port();
    let hits = Arc::new(AtomicUsize::new(0));
    let h = hits.clone();
    std::thread::spawn(move || {
        let body = r#"{"serverVersion":"6.0.0","instance":{"name":"home"}}"#;
        let reply = format!("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len());
        for s in l.incoming() {
            let Ok(mut s) = s else { break };
            h.fetch_add(1, Ordering::SeqCst);
            let mut buf = [0u8; 4096];
            let _ = s.read(&mut buf);
            let _ = s.write_all(reply.as_bytes());
        }
    });

    let dir = std::env::temp_dir().join(format!("cs-guard-env-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let cfg = CString::new(serde_json::json!({"sources": [], "video": {"dir": dir.to_string_lossy()}}).to_string()).unwrap();
    let handle = unsafe { cs_open(cfg.as_ptr()) } as usize;
    assert_ne!(handle, 0);

    // the browser's request, as the helper passes it to the core; a hang would fail the wait instead of stalling CI
    let (tx, rx) = mpsc::channel();
    std::thread::spawn(move || {
        let h = handle as *mut cache_search::handle::Handle;
        let mut out = Vec::new();
        for url in [format!("http://127.0.0.1:{port}"), "https://192.168.1.240".to_string(), "https://169.254.169.254".to_string()] {
            let req = CString::new(serde_json::json!({"url": url}).to_string()).unwrap();
            let answer = take(unsafe { cs_video_instance_add(h, req.as_ptr()) });
            let err = take(unsafe { cs_last_error(h) });
            out.push((url, answer, err));
        }
        let _ = tx.send(out);
    });
    let results = rx.recv_timeout(Duration::from_secs(60)).expect("instance_add must answer promptly, not hang");

    for (url, answer, err) in results {
        assert!(answer.is_none(), "{url} must be refused, got {answer:?}");
        let e: Value = serde_json::from_str(&err.unwrap_or_else(|| panic!("{url}: no error was reported"))).unwrap();
        assert_eq!(e["code"], "fetch_failed", "{url}: {e}");
        assert!(e["message"].as_str().is_some_and(|m| !m.is_empty()), "{url}: {e}");
    }
    assert_eq!(hits.load(Ordering::SeqCst), 0, "the stand-in must see no connection");

    // the stand-in does count connections (so the zero above means something)
    drop(TcpStream::connect(("127.0.0.1", port)).unwrap());
    for _ in 0..50 {
        if hits.load(Ordering::SeqCst) == 1 {
            break;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    assert_eq!(hits.load(Ordering::SeqCst), 1);

    unsafe { cs_close(handle as *mut cache_search::handle::Handle) };
    let _ = std::fs::remove_dir_all(dir);
}
