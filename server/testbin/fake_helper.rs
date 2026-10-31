//! A stand-in for the Dart helper, speaking its line protocol (see server/helper/bin/line_protocol.dart). Used by the proxy
//! tests. Behaviour:
//!   version -> "fake-1"      status -> []      echo -> the args      (anything else -> ok, null)
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
            "status" => json!({"id": id, "ok": true, "result": []}),
            "echo" => json!({"id": id, "ok": true, "result": args}),
            "open" if std::env::var_os("FAKE_OPEN_FAILS").is_some() => {
                json!({"id": id, "ok": false, "error": {"code": "bad_config", "message": "no"}})
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
