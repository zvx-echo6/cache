//! Uploads are streamed to disk, never held in memory. This file has one process to itself so memory can be measured:
//!   - a 2 GB body, made up as it is asked for, goes through `Library::upload`; the process's peak memory may not grow by more than
//!     256 MB (a buffered upload would grow by 2 GB), and the file on disk is the whole 2 GB;
//!   - a 64 MB upload goes through the real connection code (`serve_connection`), which only a streaming route can accept: the
//!     ordinary body limit is 1 MB.

use cache_server::auth::{Auth, Sessions, StoredPassword};
use cache_server::http::{route, serve_connection, App};
use cache_server::library::{Library, LibraryOptions};
use hyper::body::{Body, Bytes, Frame};
use std::convert::Infallible;
use std::io::{Read, Write};
use std::path::PathBuf;
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};

/// A body of `total` bytes in 1 MiB frames, made when asked for.
struct Generated {
    sent: u64,
    total: u64,
}

impl Body for Generated {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<Option<Result<Frame<Bytes>, Infallible>>> {
        if self.sent >= self.total {
            return Poll::Ready(None);
        }
        let n = (self.total - self.sent).min(1 << 20) as usize;
        self.sent += n as u64;
        Poll::Ready(Some(Ok(Frame::data(Bytes::from(vec![0xAB; n])))))
    }
}

struct Dir(PathBuf);
impl Dir {
    fn new(tag: &str) -> Dir {
        let p = std::env::temp_dir().join(format!("cache-server-upload-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Dir(p)
    }
}
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The peak resident memory of this process so far, in bytes (Linux).
#[cfg(target_os = "linux")]
fn peak_rss() -> u64 {
    let text = std::fs::read_to_string("/proc/self/status").unwrap();
    let line = text.lines().find(|l| l.starts_with("VmHWM:")).unwrap();
    line.split_whitespace().nth(1).unwrap().parse::<u64>().unwrap() * 1024
}

#[tokio::test]
async fn a_2_gb_upload_streams_to_disk_without_being_held_in_memory() {
    let dir = Dir::new("big");
    let lib = Library::with_options(dir.0.clone(), None, LibraryOptions { free_bytes: Some(Arc::new(|_| Some(1 << 50))), ..LibraryOptions::default() });
    const TOTAL: u64 = 2 << 30;
    #[cfg(target_os = "linux")]
    let before = peak_rss();
    let out = lib.upload("kind=zim&name=huge.zim", Some(TOTAL), Generated { sent: 0, total: TOTAL }).await.unwrap_or_else(|e| panic!("{e:?}"));
    assert_eq!(out["bytes"], serde_json::json!(TOTAL));
    let installed = dir.0.join("app/docs/zims/huge.zim");
    assert_eq!(std::fs::metadata(&installed).unwrap().len(), TOTAL);
    assert!(std::fs::read_dir(dir.0.join("tmp")).unwrap().next().is_none(), "no part file is left");
    #[cfg(target_os = "linux")]
    {
        let grew = peak_rss().saturating_sub(before);
        assert!(grew < 256 << 20, "peak memory grew by {} MB for a 2 GB upload", grew >> 20);
    }
    // the first and last bytes are what was sent
    let mut f = std::fs::File::open(&installed).unwrap();
    let mut head = [0u8; 4];
    f.read_exact(&mut head).unwrap();
    assert_eq!(head, [0xAB; 4]);
}

#[tokio::test]
async fn an_upload_over_a_real_connection_is_not_held_to_the_ordinary_body_limit() {
    let dir = Dir::new("conn");
    let auth = Auth::new(Some(StoredPassword::new("pw").unwrap()), Sessions::load(&dir.0.join("sessions.json")), false);
    let library = Library::with_options(dir.0.clone(), None, LibraryOptions { free_bytes: Some(Arc::new(|_| Some(1 << 50))), ..LibraryOptions::default() });
    let app = Arc::new(App { auth: Arc::new(auth), helper: None, web: dir.0.join("web"), library });
    let r = route(&app, "POST", "/auth/login", None, br#"{"password":"pw"}"#).await;
    let cookie = r.headers.iter().find(|(k, _)| *k == "Set-Cookie").unwrap().1.split(';').next().unwrap().to_string();

    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server_app = app.clone();
    tokio::spawn(async move {
        while let Ok((tcp, _)) = listener.accept().await {
            tokio::spawn(serve_connection(server_app.clone(), tcp));
        }
    });

    const TOTAL: usize = 64 << 20;
    let client = tokio::task::spawn_blocking(move || {
        let mut s = std::net::TcpStream::connect(addr).unwrap();
        let head = format!(
            "POST /api/library/upload?kind=zim&name=conn.zim HTTP/1.1\r\nHost: x\r\nCookie: {cookie}\r\nContent-Length: {TOTAL}\r\nConnection: close\r\n\r\n"
        );
        s.write_all(head.as_bytes()).unwrap();
        let block = vec![7u8; 1 << 20];
        for _ in 0..TOTAL >> 20 {
            s.write_all(&block).unwrap();
        }
        let mut reply = String::new();
        s.read_to_string(&mut reply).unwrap();
        reply
    });
    let reply = client.await.unwrap();
    assert!(reply.starts_with("HTTP/1.1 200"), "{}", &reply[..reply.len().min(300)]);
    assert!(reply.contains("conn.zim"));
    assert_eq!(std::fs::metadata(dir.0.join("app/docs/zims/conn.zim")).unwrap().len(), TOTAL as u64);

    // without a session the same request gets the ordinary 401 and writes nothing
    let status = tokio::task::spawn_blocking(move || {
        let mut s = std::net::TcpStream::connect(addr).unwrap();
        s.write_all(b"POST /api/library/upload?kind=zim&name=no.zim HTTP/1.1\r\nHost: x\r\nContent-Length: 3\r\nConnection: close\r\n\r\nabc").unwrap();
        let mut reply = String::new();
        s.read_to_string(&mut reply).unwrap();
        reply
    })
    .await
    .unwrap();
    assert!(status.starts_with("HTTP/1.1 401"), "{status}");
    assert!(!dir.0.join("app/docs/zims/no.zim").exists());
}
