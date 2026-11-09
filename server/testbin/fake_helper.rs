//! A stand-in for the Dart helper, speaking its line protocol (see server/helper/bin/line_protocol.dart). Used by the proxy
//! tests. Behavior:
//!   env     -> {support, docs, shim, data}: CACHE_APP_SUPPORT, CACHE_APP_DOCS, CACHE_VALHALLA_SHIM and CACHE_DATA as the server set them
//!   version -> "fake-1"      status -> [] (or the JSON in FAKE_STATUS)      echo -> the args
//!   sources.rescan -> {sources: the length of args.sources, or 0}      (anything else -> ok, null)
//!   zimGet  -> an entry by address: ends in .html: a page that names the address; .png: 5 bytes of image/png; contains "missing":
//!              not_found; else text/plain
//!   layers  -> {port: FAKE_TILE_PORT} for op "server" (the core's tile server), else ok, null
//!   crash   -> exits without replying the first time (the marker file FAKE_MARKER is created), then replies "back"
//!   open    -> fails with ok:false when FAKE_OPEN_FAILS is set
//! Every op it receives is appended to the file FAKE_LOG, one `op args` line each. FAKE_NO_READY makes it exit at once.

use serde_json::{json, Value};
use std::io::{BufRead, Write};

fn main() {
    if std::env::var_os("FAKE_NO_READY").is_some() {
        std::process::exit(3);
    }
    let log_path = std::env::var("FAKE_LOG").ok();
    let marker = std::env::var("FAKE_MARKER").ok();
    let mut out = std::io::stdout();
    writeln!(out, "{}", json!({"ready": true})).unwrap();
    out.flush().unwrap();
    eprintln!("fake helper up, lib={}", std::env::var("CACHE_CORE_LIB").unwrap_or_default());
    for line in std::io::stdin().lock().lines() {
        let line = line.unwrap();
        let req: Value = serde_json::from_str(&line).unwrap();
        let (id, op, args) = (req["id"].clone(), req["op"].as_str().unwrap().to_string(), req["args"].clone());
        if let Some(p) = &log_path {
            let mut f = std::fs::OpenOptions::new().create(true).append(true).open(p).unwrap();
            writeln!(f, "{op} {args}").unwrap();
        }
        let reply = match op.as_str() {
            "version" => json!({"id": id, "ok": true, "result": "fake-1"}),
            "status" => match std::env::var("FAKE_STATUS") {
                Ok(t) => json!({"id": id, "ok": true, "result": serde_json::from_str::<Value>(&t).unwrap()}),
                Err(_) => json!({"id": id, "ok": true, "result": []}),
            },
            "sources.rescan" => {
                let n = args["sources"].as_array().map_or(0, Vec::len);
                json!({"id": id, "ok": true, "result": {"sources": n}})
            }
            "env" => json!({"id": id, "ok": true, "result": {
                "support": std::env::var("CACHE_APP_SUPPORT").ok(), "docs": std::env::var("CACHE_APP_DOCS").ok(),
                "shim": std::env::var("CACHE_VALHALLA_SHIM").ok(), "data": std::env::var("CACHE_DATA").ok()}}),
            "echo" => json!({"id": id, "ok": true, "result": args}),
            "open" if std::env::var_os("FAKE_OPEN_FAILS").is_some() => {
                json!({"id": id, "ok": false, "error": {"code": "bad_config", "message": "no"}})
            }
            "zimGet" => {
                use base64::Engine;
                let a = args["address"].as_str().unwrap_or("");
                let enc = |b: &[u8]| json!({"$bytes": base64::engine::general_purpose::STANDARD.encode(b)});
                let base = a.split('?').next().unwrap_or("");
                if a.contains("missing") {
                    json!({"id": id, "ok": false, "error": {"code": "not_found", "message": "no such entry"}})
                } else if base.ends_with(".html") {
                    let page = format!("<html><head><title>T</title></head><body>page {a}</body></html>");
                    json!({"id": id, "ok": true, "result": [enc(page.as_bytes()), "text/html"]})
                } else if base.ends_with(".png") {
                    json!({"id": id, "ok": true, "result": [enc(&[0, 1, 2, 250, 255]), "image/png"]})
                } else {
                    json!({"id": id, "ok": true, "result": [enc(b"plain"), "text/plain"]})
                }
            }
            "layers" if args["op"] == json!("server") => {
                let port: u64 = std::env::var("FAKE_TILE_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(0);
                json!({"id": id, "ok": true, "result": {"port": port, "online": false}})
            }
            "boom" => json!({"id": id, "ok": false, "error": {"code": "not_found", "message": "nothing here"}}),
            "crash" => {
                let m = marker.as_ref().unwrap();
                if std::path::Path::new(m).exists() {
                    json!({"id": id, "ok": true, "result": "back"})
                } else {
                    std::fs::write(m, b"x").unwrap();
                    std::process::exit(1);
                }
            }
            _ => json!({"id": id, "ok": true, "result": null}),
        };
        writeln!(out, "{reply}").unwrap();
        out.flush().unwrap();
    }
}
