//! Two devices: A plans a region online, so its tile index is published as a snapshot in its indexes folder; the indexes folder
//! syncs (cache_sync, fetching region-index and places-index, as the app does); B, a fresh device with no network, plans the
//! same region from A's snapshot.

use cache_regions::{Config, Regions};
use cache_sync::{Config as SyncConfig, SyncEngine};
use flate2::{write::GzEncoder, Compression};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

const TILES: [&str; 3] = ["0/002/986", "1/047/586", "2/000/763/464"];

fn gz(b: &[u8]) -> Vec<u8> {
    let mut e = GzEncoder::new(Vec::new(), Compression::default());
    e.write_all(b).unwrap();
    e.finish().unwrap()
}

fn hex(b: &[u8]) -> String {
    Sha256::digest(b).iter().map(|x| format!("{x:02x}")).collect()
}

fn region() -> Value {
    let (w, s, e, n) = (-113.95, 42.55, -113.80, 42.65);
    json!({"type": "Feature", "properties": {}, "geometry": {"type": "Polygon", "coordinates": [[[w, s], [e, s], [e, n], [w, n], [w, s]]]}})
}

/// A routing server that publishes one build of three tiles.
fn server(build: &str) -> u16 {
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let port = server.server_addr().to_ip().unwrap().port();
    let mut files: HashMap<String, Vec<u8>> = HashMap::new();
    let mut lines = Vec::new();
    for p in TILES {
        let raw: Vec<u8> = format!("{build} {p} ").bytes().cycle().take(1000).collect();
        let z = gz(&raw);
        lines.push(format!("{p}\t{}\t{}\t{}", raw.len(), hex(&raw), z.len()));
        files.insert(format!("/{build}/{p}.gph.gz"), z);
    }
    lines.sort();
    let index = gz(format!("{}\n", lines.join("\n")).as_bytes());
    let current = json!({
        "format": 1, "build": build, "valhalla": "3.7.0", "source": "test", "tiles": lines.len(),
        "bytes": lines.len() * 1000, "gz_bytes": 0, "index": format!("{build}/index.tsv.gz"), "index_sha256": hex(&index),
    });
    files.insert(format!("/{build}/index.tsv.gz"), index);
    files.insert("/current.json".into(), current.to_string().into_bytes());
    let files = Arc::new(Mutex::new(files));
    std::thread::spawn(move || {
        for req in server.incoming_requests() {
            let body = files.lock().unwrap().get(req.url()).cloned();
            let resp = match body {
                Some(b) => tiny_http::Response::from_data(b),
                None => tiny_http::Response::from_data(Vec::new()).with_status_code(404),
            };
            let _ = req.respond(resp);
        }
    });
    port
}

fn regions(dir: &Path, indexes: &Path, port: u16) -> Regions {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "base_url": format!("http://127.0.0.1:{port}/"), "reserve_bytes": 0, "indexes_dir": indexes,
    }))
    .unwrap();
    Regions::open(cfg).unwrap()
}

/// The indexes share as the app sets it up (app/lib/search/indexes_share.dart): builds and SQLite files stay, deletes stay,
/// manifests last; this device fetches the tile indexes of every build.
fn sync(dir: &Path, name: &str) -> SyncEngine {
    let cfg: SyncConfig = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false, "interval_secs": 5,
        "reserve_bytes": 0,
        "exclude": {"indexes": ["*/*/.build", "**/*-shm", "**/*-wal", "**/*-journal"]},
        "local_deletes": {"indexes": ["*/*/snap"]},
        "last": {"indexes": ["*/*/snap/*/manifest.json"]},
        "only": {"indexes": ["places-index", "region-index"]},
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

fn has_manifest(root: &Path) -> bool {
    let snaps = root.join("region-index").join("r1").join("snap");
    std::fs::read_dir(&snaps).into_iter().flatten().flatten().any(|e| e.path().join("manifest.json").exists())
}

struct Tmp(PathBuf);

impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn a_device_with_no_network_plans_from_a_peers_index() {
    let t = Tmp(std::env::temp_dir().join(format!("cache-regions-peer-{}", std::process::id())));
    let _ = std::fs::remove_dir_all(&t.0);
    let p = |n: &str| t.0.join(n);
    for d in ["regions-a", "regions-b", "idx-a", "idx-b"] {
        std::fs::create_dir_all(p(d)).unwrap();
    }
    let port = server("r1");

    // A plans online: the index is fetched and kept as a snapshot.
    let a = regions(&p("regions-a"), &p("idx-a"), port);
    let plan_a = a.call("plan", &json!({"geometry": region()})).unwrap_or_else(|e| panic!("A plans: {}", e.message));
    assert!(has_manifest(&p("idx-a")), "A's index is a snapshot in its indexes folder");
    let status = a.call("status", &json!({})).unwrap();
    assert_eq!(status["indexes"]["routing"][0]["source_id"], "r1", "{status}");

    // B cannot ask the server, and knows no build.
    let b = regions(&p("regions-b"), &p("idx-b"), port);
    b.call("set_policy", &json!({"network": false})).unwrap();
    assert_eq!(b.call("plan", &json!({"geometry": region()})).unwrap_err().code, "offline");

    // The indexes folders sync.
    let sa = sync(&p("sync-a"), "Desk");
    let sb = sync(&p("sync-b"), "Phone");
    let code = sa.call("link_code", &json!({})).unwrap()["code"].as_str().unwrap().to_string();
    sb.call("link", &json!({"code": code})).unwrap();
    sa.call("share_add", &json!({"id": "indexes", "name": "Search indexes", "path": p("idx-a")})).unwrap();
    sb.call("share_add", &json!({"id": "indexes", "name": "Search indexes", "path": p("idx-b")})).unwrap();
    std::thread::sleep(Duration::from_secs(6));
    let mut arrived = false;
    for i in 0..240 {
        if has_manifest(&p("idx-b")) {
            arrived = true;
            break;
        }
        if i % 4 == 0 {
            sa.call("sync_now", &json!({})).unwrap();
            sb.call("sync_now", &json!({})).unwrap();
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    assert!(arrived, "A's snapshot reaches B: {}", sb.call("status", &json!({})).unwrap()["log"]);

    // B, still offline, plans the same region from it: the same tiles and size as A's plan.
    let plan_b = b.call("plan", &json!({"geometry": region()})).unwrap_or_else(|e| panic!("B plans offline: {} ({})", e.message, e.code));
    assert_eq!(plan_a["tiles"], 3, "{plan_a}");
    assert_eq!(plan_b["tiles"], plan_a["tiles"], "{plan_b}");
    assert_eq!(plan_b["bytes"], plan_a["bytes"], "{plan_b}");
    sa.close();
    sb.close();
}
