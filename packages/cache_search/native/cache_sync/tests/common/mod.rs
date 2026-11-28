//! Shared by the Reticulum tests: engines with Reticulum on over loopback TCP, links made over Reticulum only, and a Prns
//! transport node standing in for rnsd.
#![allow(dead_code)]

use cache_sync::{Config, SyncEngine};
use serde_json::{json, Value};
use std::{path::Path, time::Duration};

pub fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

/// An engine with Reticulum on and the given TCP block. iroh has no relay, DHT, mDNS or lookup: it can only reach a device
/// whose address it was given (a link code's), so a code with that address taken out leaves Reticulum the only way.
pub fn engine(dir: &Path, name: &str, listen: Option<u16>, connect: Option<u16>, iroh_port: Option<u16>) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "port": iroh_port, "reticulum": true,
        "rns_interfaces": {
            "tcp_listen": listen.map(|p| format!("127.0.0.1:{p}")),
            "tcp_connect": connect.map(|p| format!("127.0.0.1:{p}")),
        },
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

/// An engine with Reticulum off (as a build before 55 behaves), on a fixed iroh port.
pub fn old_engine(dir: &Path, name: &str, iroh_port: Option<u16>) -> SyncEngine {
    let cfg: Config = serde_json::from_value(json!({
        "dir": dir, "name": name, "relay": false, "dht": false, "mdns": false, "lookup": false,
        "interval_secs": 5, "reserve_bytes": 0, "port": iroh_port,
    }))
    .unwrap();
    SyncEngine::open(cfg).unwrap()
}

pub fn wait(what: &str, secs: u64, mut ok: impl FnMut() -> bool) {
    for _ in 0..secs * 4 {
        if ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("timed out waiting for {what}");
}

pub fn call(e: &SyncEngine, m: &str, a: Value) -> Value {
    e.call(m, &a).unwrap_or_else(|err| panic!("{m}: {err:#}"))
}

/// A short link code's parts: the 16 byte destination and the 5 byte secret.
pub fn short_parts(code: &str) -> (Vec<u8>, Vec<u8>) {
    let body: String = code.strip_prefix("CACHE-").expect("a short code").chars().filter(|c| *c != '-').collect();
    assert_eq!(body.len(), 34, "{code}");
    let raw = data_encoding::BASE32_NOPAD.decode(body.as_bytes()).unwrap();
    assert_eq!(raw.len(), 21);
    (raw[..16].to_vec(), raw[16..].to_vec())
}

/// A short code from its parts, written the way a device shows it.
pub fn short_code(dest: &[u8], secret: &[u8]) -> String {
    let body = data_encoding::BASE32_NOPAD.encode(&[dest, secret].concat());
    let groups: Vec<&str> = body.as_bytes().chunks(4).map(|c| std::str::from_utf8(c).unwrap()).collect();
    format!("CACHE-{}", groups.join("-"))
}

/// What the file `sync.json` in `dir` says about its first linked device.
pub fn saved_peer(dir: &Path) -> Value {
    let v: Value = serde_json::from_slice(&std::fs::read(dir.join("sync.json")).unwrap()).unwrap();
    v["peers"][0].clone()
}

/// How device `name` last answered, as the status shows it.
pub fn via(e: &SyncEngine, name: &str) -> Option<String> {
    let st = call(e, "status", json!({}));
    st["peers"].as_array()?.iter().find(|p| p["name"] == name)?["via"].as_str().map(String::from)
}

/// Data Prns will not compress (like real maps and ZIMs).
pub fn random(n: usize, seed: u64) -> Vec<u8> {
    let mut x = seed | 1;
    let mut v = Vec::with_capacity(n + 8);
    while v.len() < n {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        v.extend_from_slice(&x.to_le_bytes());
    }
    v.truncate(n);
    v
}

/// A Prns transport node standing in for rnsd: listens on `listen` and connects to `connect`, with Reticulum transport on.
/// It has no role in Cache's traffic. Dropping the returned sender stops it.
pub mod node {
    use personal_rns::prelude::*;

    pub fn transport(listen: u16, connect: u16) -> tokio::sync::oneshot::Sender<()> {
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
        std::thread::Builder::new()
            .stack_size(32 * 1024 * 1024)
            .spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
                let local = tokio::task::LocalSet::new();
                local.block_on(&rt, async move {
                    let destination = PreConfiguredDestination::Single {
                        resource_strategy: ResourceStrategy::AcceptNone,
                        maximum_request_bytes: Default::default(),
                        app_name: "cache-test",
                        aspects: &["transport"],
                        identity: try_generate_identity_secret().unwrap(),
                        announce_app_data: b"",
                        proof: ProofStrategy::ProveAll,
                        link_requests: LinkRequestPolicy::AcceptAll,
                        ratchet: RatchetPolicy::NoRatchets,
                        request_endpoints: ServeMyRequestEndpoints::No,
                    };
                    let node = PrnsNode::new(PrnsNodeRecipe {
                        transport_identity: Some(try_generate_identity_secret().unwrap()),
                        remote_control: RemoteControlService::Unavailable.into(),
                        pre_configured_destinations: [destination],
                        app_state: personal_rns::runtime::NoRemoteControlHostControls,
                        storage: GrowableHeap,
                        request_endpoints: request_endpoints![],
                        on_event: |_event, _state| {},
                        interfaces: move |node: &PrnsNodeHandle| {
                            node.attach(TcpClientInterface::new(format!("127.0.0.1:{connect}")));
                        },
                        persistence: NoPersistence,
                    });
                    let handle = node.handle();
                    let server = TcpServer::bind(format!("127.0.0.1:{listen}")).await.unwrap();
                    let _guard = handle.supervise(server);
                    ready_tx.send(()).unwrap();
                    tokio::select! {
                        _ = node.run() => {}
                        _ = stop_rx => {}
                    }
                });
            })
            .unwrap();
        ready_rx.recv().unwrap();
        stop_tx
    }
}

/// [`wait`], saying what `diag` reports when it times out.
pub fn wait_dbg(what: &str, secs: u64, mut ok: impl FnMut() -> bool, diag: impl Fn() -> String) {
    for _ in 0..secs * 4 {
        if ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(250));
    }
    panic!("timed out waiting for {what}\n{}", diag());
}

/// The peers and recent notes of an engine, for a failure message.
pub fn brief(e: &SyncEngine) -> String {
    let st = call(e, "status", json!({}));
    format!("peers={} log={}", st["peers"], st["log"].to_string().chars().take(1500).collect::<String>())
}

/// Makes both devices leave their iroh address out of a short code's pairing (iroh then cannot find the other device, so
/// everything after the link can only go over Reticulum).
pub fn rns_only_dirs(dirs: &[&Path]) {
    for d in dirs {
        std::fs::create_dir_all(d).unwrap();
        std::fs::write(d.join("no-iroh-in-hello"), b"").unwrap();
    }
}

/// Another stand-in for rnsd, as the entry-point tests use it: a Prns transport node that listens on `listen`, keyed with IFAC
/// when `ifac` is given (network name, passphrase) and announcing a destination of its own every second (so bytes keep arriving
/// on a client's connection, as on an rnsd with traffic). Dropping the returned sender stops it.
pub mod rnsd {
    use personal_rns::interfaces::{IfacContext, IfacSize};
    use personal_rns::prelude::*;
    use std::time::Duration;

    pub fn server(listen: u16, ifac: Option<(&str, &str)>) -> tokio::sync::oneshot::Sender<()> {
        let ifac = ifac.map(|(n, p)| (n.to_string(), p.to_string()));
        let (ready_tx, ready_rx) = std::sync::mpsc::channel();
        let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
        std::thread::Builder::new()
            .stack_size(32 * 1024 * 1024)
            .spawn(move || {
                let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
                let local = tokio::task::LocalSet::new();
                local.block_on(&rt, async move {
                    let destination = PreConfiguredDestination::Single {
                        resource_strategy: ResourceStrategy::AcceptNone,
                        maximum_request_bytes: Default::default(),
                        app_name: "cache-test",
                        aspects: &["standin"],
                        identity: try_generate_identity_secret().unwrap(),
                        announce_app_data: b"",
                        proof: ProofStrategy::ProveAll,
                        link_requests: LinkRequestPolicy::AcceptAll,
                        ratchet: RatchetPolicy::NoRatchets,
                        request_endpoints: ServeMyRequestEndpoints::No,
                    };
                    let mine = destination.destination_hash().unwrap();
                    let node = PrnsNode::new(PrnsNodeRecipe {
                        transport_identity: Some(try_generate_identity_secret().unwrap()),
                        remote_control: RemoteControlService::Unavailable.into(),
                        pre_configured_destinations: [destination],
                        app_state: personal_rns::runtime::NoRemoteControlHostControls,
                        storage: GrowableHeap,
                        request_endpoints: request_endpoints![],
                        on_event: |_event, _state| {},
                        interfaces: |_node: &PrnsNodeHandle| {},
                        persistence: NoPersistence,
                    });
                    let handle = node.handle();
                    let server = TcpServer::bind(format!("127.0.0.1:{listen}")).await.unwrap();
                    let _guard = match ifac {
                        Some((n, k)) => {
                            let ctx = IfacContext::derive(Some(&n), Some(&k), IfacSize::WIDE).unwrap();
                            handle.supervise_with_ifac_name(server, ctx, Some(n))
                        }
                        None => handle.supervise(server),
                    };
                    let h = handle.clone();
                    tokio::task::spawn_local(async move {
                        loop {
                            tokio::time::sleep(Duration::from_secs(1)).await;
                            let _ = h
                                .announce_now(AnnounceNow {
                                    destination: mine,
                                    target: AnnounceTarget::AllInterfaces,
                                    app_data: AnnounceAppData::Data(Default::default()),
                                })
                                .await;
                        }
                    });
                    ready_tx.send(()).unwrap();
                    tokio::select! {
                        _ = node.run() => {}
                        _ = stop_rx => {}
                    }
                });
            })
            .unwrap();
        ready_rx.recv().unwrap();
        stop_tx
    }
}
