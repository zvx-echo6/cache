//! `cache-sync`: the sync engine of the app, on a desktop, from a terminal.
//!
//!   cache-sync --dir <folder> [--name <name>] [--port <n>] [--no-relay] [--no-dht] [--no-mdns] [--no-lookup] run
//!
//! Runs until stopped. Every two seconds it writes `<folder>/status.json` (what the app's Sharing screen shows). Commands are
//! files: put `{"method": "...", "args": {...}}` in `<folder>/commands/<name>.json` and the answer appears as
//! `<folder>/commands/<name>.result.json` (the same methods as the app: link_code, link, share_add, share_join, unlink,
//! share_remove, sync_now, set_policy, set_name, status). `cache-sync ... call <method> '<json args>'` writes such a file and
//! waits for its answer, for use from a second terminal while `run` is going.

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::PathBuf, time::Duration};

fn usage() -> ! {
    eprintln!("usage: cache-sync --dir <folder> [--name <name>] [--port <n>] [--no-relay] [--no-dht] [--no-mdns] [--no-lookup] run");
    eprintln!("       cache-sync --dir <folder> call <method> [<json args>]");
    std::process::exit(2)
}

fn main() {
    let mut args = std::env::args().skip(1);
    let mut dir = None;
    let mut cfg = json!({});
    let mut rest = Vec::new();
    while let Some(a) = args.next() {
        match a.as_str() {
            "--dir" => dir = args.next(),
            "--name" => cfg["name"] = json!(args.next().unwrap_or_else(|| usage())),
            "--port" => cfg["port"] = json!(args.next().and_then(|p| p.parse::<u16>().ok()).unwrap_or_else(|| usage())),
            "--no-relay" => cfg["relay"] = json!(false),
            "--no-dht" => cfg["dht"] = json!(false),
            "--no-mdns" => cfg["mdns"] = json!(false),
            "--no-lookup" => cfg["lookup"] = json!(false),
            "--interval" => cfg["interval_secs"] = json!(args.next().and_then(|p| p.parse::<u64>().ok()).unwrap_or_else(|| usage())),
            _ => rest.push(a),
        }
    }
    let dir = PathBuf::from(dir.unwrap_or_else(|| usage()));
    cfg["dir"] = json!(dir);
    match rest.first().map(|s| s.as_str()) {
        Some("run") => run(serde_json::from_value(cfg).expect("config")),
        Some("call") => {
            let method = rest.get(1).cloned().unwrap_or_else(|| usage());
            let a: Value = rest.get(2).map(|s| serde_json::from_str(s).expect("json args")).unwrap_or(json!({}));
            call(&dir, &method, a)
        }
        _ => usage(),
    }
}

fn run(cfg: Config) {
    let dir = cfg.dir.clone();
    let engine = match SyncEngine::open(cfg) {
        Ok(e) => e,
        Err(e) => {
            eprintln!("could not start: {e:#}");
            std::process::exit(1)
        }
    };
    let cmds = dir.join("commands");
    let _ = std::fs::create_dir_all(&cmds);
    let st = engine.call("status", &json!({})).unwrap_or_default();
    println!("device {} ({})", st["id"].as_str().unwrap_or(""), st["name"].as_str().unwrap_or(""));
    loop {
        if let Ok(rd) = std::fs::read_dir(&cmds) {
            let mut files: Vec<PathBuf> = rd
                .flatten()
                .map(|e| e.path())
                .filter(|p| p.extension().map(|x| x == "json").unwrap_or(false) && !p.to_string_lossy().ends_with(".result.json"))
                .collect();
            files.sort();
            for f in files {
                let Ok(body) = std::fs::read(&f) else { continue };
                let _ = std::fs::remove_file(&f);
                let req: Value = serde_json::from_slice(&body).unwrap_or(json!({}));
                let method = req["method"].as_str().unwrap_or("").to_string();
                let out = match engine.call(&method, &req["args"]) {
                    Ok(v) => v,
                    Err(e) => json!({"error": format!("{e:#}")}),
                };
                println!("{method}: {out}");
                let res = f.with_file_name(format!("{}.result.json", f.file_stem().unwrap().to_string_lossy()));
                let tmp = res.with_extension("tmp");
                let _ = std::fs::write(&tmp, serde_json::to_vec_pretty(&out).unwrap());
                let _ = std::fs::rename(&tmp, &res);
                if method == "quit" {
                    engine.close();
                    return;
                }
            }
        }
        if let Ok(st) = engine.call("status", &json!({})) {
            let p = dir.join("status.json");
            let tmp = dir.join("status.tmp");
            let _ = std::fs::write(&tmp, serde_json::to_vec_pretty(&st).unwrap());
            let _ = std::fs::rename(&tmp, &p);
        }
        std::thread::sleep(Duration::from_secs(2));
    }
}

fn call(dir: &std::path::Path, method: &str, args: Value) {
    let cmds = dir.join("commands");
    let _ = std::fs::create_dir_all(&cmds);
    let name = format!("c{}", std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis());
    let tmp = cmds.join(format!("{name}.tmp"));
    std::fs::write(&tmp, serde_json::to_vec(&json!({"method": method, "args": args})).unwrap()).expect("write command");
    std::fs::rename(&tmp, cmds.join(format!("{name}.json"))).expect("write command");
    let res = cmds.join(format!("{name}.result.json"));
    for _ in 0..600 {
        if let Ok(b) = std::fs::read(&res) {
            let _ = std::fs::remove_file(&res);
            println!("{}", String::from_utf8_lossy(&b));
            return;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    eprintln!("no answer (is `cache-sync run` going for this folder?)");
    std::process::exit(1)
}
