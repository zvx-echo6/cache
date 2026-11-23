//! The network under the sync engine (1.2 spike, B3): everything the engine needs from it, behind one interface, so a second
//! network (Reticulum) can sit beside iroh without the engine knowing which carried a request.
//!
//! - [`Transport`]: what the engine asks of the network (ask a linked device, pair, fetch a file by hash, the allow list).
//! - [`Serve`]: what the network asks of the engine (answer a linked device, answer a pairing hello).
//! - [`IrohTransport`]: today's iroh code, moved here unchanged: the same protocols, timeouts, messages and gate.

use std::collections::HashSet;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::time::Duration;

use anyhow::{anyhow, Result};
use iroh::{
    endpoint::{AfterHandshakeOutcome, Connection, EndpointHooks, VarInt},
    protocol::{AcceptError, ProtocolHandler, Router},
    Endpoint, EndpointAddr, EndpointId,
};
use iroh_blobs::{
    api::downloader::{DownloadOptions, DownloadProgressItem, Shuffled, SplitStrategy},
    store::fs::FsStore,
    BlobsProtocol, Hash, HashAndFormat,
};
use n0_future::{Stream, StreamExt};

use crate::{closed_403, closed_code, is_no_space, now_ms, GateState, MAX_INDEX, NO_SPACE, PAIR_ALPN, SYNC_ALPN};

pub type BoxFut<'a, T> = Pin<Box<dyn Future<Output = T> + Send + 'a>>;
pub type BoxStream<T> = Pin<Box<dyn Stream<Item = T> + Send>>;

/// The two things one linked device asks another.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Ask {
    /// Its index (all shares).
    Index,
    /// The secrets it holds for the asking device.
    Secrets,
}

impl Ask {
    fn wire(self) -> &'static [u8] {
        match self {
            Ask::Index => b"index",
            Ask::Secrets => b"secrets",
        }
    }
}

/// One step of a file fetch.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum FetchEvent {
    /// Verified bytes held so far.
    Progress(u64),
    /// The fetch failed; [`NO_SPACE`] for a full disk.
    Failed(String),
}

/// Where a pairing hello goes: the iroh address from the link code, and the Reticulum destination (32 hex characters) when
/// the code carries one.
#[derive(Debug, Clone)]
pub struct PairTarget {
    pub iroh: EndpointAddr,
    pub rns: Option<String>,
}

/// What the engine asks of the network.
pub trait Transport: Send + Sync + 'static {
    /// This device's id (its iroh key), as the engine names devices.
    fn id(&self) -> String;
    /// Asks a linked device; the answer, and how it was reached ("direct", "relay"). If the other device's Gate closed the
    /// connection, `closed` is set to its close code (403 "not linked", 409, 503), whichever step met it.
    fn ask<'a>(&'a self, peer: &'a str, ask: Ask, closed: &'a AtomicU32) -> BoxFut<'a, Result<(Vec<u8>, String)>>;
    /// Sends a pairing hello to the device at `to` (from its link code); its answer.
    fn pair(&self, to: PairTarget, hello: Vec<u8>) -> BoxFut<'_, Result<Vec<u8>>>;
    /// The addresses that go in this device's link code: the iroh address and, when Reticulum runs, its destination (hex).
    fn link_addr(&self) -> BoxFut<'_, (EndpointAddr, Option<String>)>;
    /// This device's Reticulum destination (hex) and the device key's signature over it (hex), when Reticulum runs. What
    /// a pairing and an index carry, so the other device learns where to reach this one.
    fn rns_info(&self) -> Option<(String, String)> {
        None
    }
    /// A linked device's Reticulum destination and signature, as it gave them: stored for use when the signature is the
    /// device's own. False when it is not (or Reticulum is not running on this device).
    fn learn_rns(&self, _peer: &str, _dest: &str, _sig: &str) -> bool {
        false
    }
    /// Pairs with a short link code: finds a path to the Reticulum destination `dest_hex` (a routed path may take a while),
    /// opens a link and sends `body` to its pairing path; the answer. Over Reticulum only: a short code carries no iroh address.
    fn pair_short(&self, _dest_hex: &str, _body: Vec<u8>) -> BoxFut<'_, Result<Vec<u8>>> {
        Box::pin(async { Err(anyhow!(NO_REACH)) })
    }
    /// Whether `sig` (hex) is the device key `key`'s signature over the Reticulum destination `dest` (hex). Stores nothing.
    fn verify_rns(&self, _key: &str, _dest: &str, _sig: &str) -> bool {
        false
    }
    /// Lets iroh reach a device at the address it gave in a pairing (a short code carries none).
    fn learn_iroh(&self, _addr: EndpointAddr) {}
    /// Lets a device connect (linked, or about to be).
    fn allow(&self, peer: &str);
    /// Stops letting a device connect.
    fn disallow(&self, peer: &str);
    /// The devices this one used to be linked with and is not linked with now (ids): over Reticulum, one of them that asks is told
    /// "not linked" instead of not being answered at all. The whole list each time. iroh has its own Gate and ignores it.
    fn set_former(&self, _ids: &[String]) {}
    /// Fetches `hash` into `store` from any of `providers`. Dropping the stream ends the fetch; what arrived stays in the store.
    fn fetch<'a>(&'a self, store: &'a FsStore, hash: Hash, providers: Vec<String>) -> BoxFut<'a, Result<BoxStream<FetchEvent>>>;
    /// The phone moved between networks: find new paths.
    fn network_change(&self) -> BoxFut<'_, ()>;
    /// For the status: the relay in use and the direct addresses.
    fn addresses(&self) -> (Option<String>, Vec<String>);
    /// The UDP port this device listens on (IPv4).
    fn port(&self) -> Option<u16>;
    /// Stops accepting and closes connections.
    fn shutdown(&self) -> BoxFut<'_, ()>;
    /// Nearby linking: the link-code page opened (this device's name and kind, as it tells a device that asks).
    fn pairing_open(&self, _name: String, _kind: Option<String>) -> BoxFut<'_, Result<()>> {
        Box::pin(async { Err(anyhow!("Nearby linking needs Reticulum, which is not running on this device")) })
    }
    /// Nearby linking: the page closed.
    fn pairing_close(&self) -> BoxFut<'_, ()> {
        Box::pin(async {})
    }
    /// Nearby linking: `{"devices": [{id, name, kind, via}]}`.
    fn nearby_list(&self) -> serde_json::Value {
        serde_json::json!({"devices": []})
    }
    /// Nearby linking: `{state, name, kind, words, reason}`.
    fn nearby_state(&self) -> serde_json::Value {
        serde_json::json!({"state": "idle", "name": null, "kind": null, "words": [], "reason": null})
    }
    /// Nearby linking: Link was tapped on a listed device.
    fn nearby_link(&self, _id: String, _name: String, _kind: Option<String>) -> BoxFut<'_, Result<()>> {
        Box::pin(async { Err(anyhow!("Nearby linking needs Reticulum, which is not running on this device")) })
    }
    /// Tests only: moves the clock Nearby's 60 second and one minute waits run on.
    fn skew_clock(&self, _ms: u64) {}
    /// Nearby linking: Link (`true`) or Cancel on the three words.
    fn nearby_answer(&self, _ok: bool) -> BoxFut<'_, Result<()>> {
        Box::pin(async { Err(anyhow!("Nearby linking needs Reticulum, which is not running on this device")) })
    }
}

/// What a person is told when a short code's other device cannot be reached.
pub const NO_REACH: &str = "Could not reach the other device. Check both are on the same network, or connected to the internet through the same hub.";

/// What the network asks of the engine.
pub trait Serve: Send + Sync + 'static {
    /// A pairing hello from `peer` (any device, not linked yet): the answer to send back.
    fn pair_hello(&self, peer: &str, hello: &[u8]) -> Vec<u8>;
    /// A pairing request over Reticulum with a short link code's secret (`{secret, hello}`): the answer to send back.
    fn pair_short(self: Arc<Self>, body: Vec<u8>) -> BoxFut<'static, Vec<u8>>;
    /// A linked device asks (it holds the link, so this confirms it): the answer to send back.
    fn answer(self: Arc<Self>, peer: String, ask: Ask) -> BoxFut<'static, Vec<u8>>;
    /// After an index answer has been taken: the asking device may have changes too.
    fn asked(&self, peer: &str);
    /// A Nearby link both people confirmed, with the other device's destination and signature (hex): keep it.
    fn nearby_linked(&self, peer: &str, name: &str, dest: &str, sig: &str);
}

/// Refuses every connection from a key that is not linked, except on the linking protocol (which wants the one-time code).
#[derive(Debug)]
struct Gate {
    allowed: Arc<RwLock<HashSet<EndpointId>>>,
    state: Arc<GateState>,
}

impl EndpointHooks for Gate {
    async fn after_handshake<'a>(&'a self, conn: &'a Connection) -> AfterHandshakeOutcome {
        if conn.alpn() == PAIR_ALPN || self.allowed.read().map(|a| a.contains(&conn.remote_id())).unwrap_or(false) {
            AfterHandshakeOutcome::accept()
        } else {
            let r = self.state.refusal(now_ms());
            AfterHandshakeOutcome::Reject { error_code: VarInt::from_u32(r.code()), reason: r.reason().to_vec() }
        }
    }
}

/// iroh: the network Cache has used since 1.0.
pub struct IrohTransport {
    endpoint: Endpoint,
    /// Addresses given in a pairing (a short link code has none), for iroh to connect with later.
    known: iroh::address_lookup::MemoryLookup,
    allowed: Arc<RwLock<HashSet<EndpointId>>>,
    router: Mutex<Option<Router>>,
}

impl IrohTransport {
    /// Binds the endpoint from `builder` (its options set by the caller), with the gate fed by `allowed` and `gate`.
    pub(crate) async fn bind(
        builder: iroh::endpoint::Builder,
        allowed: impl IntoIterator<Item = String>,
        gate: Arc<GateState>,
    ) -> Result<Arc<IrohTransport>> {
        let allowed: Arc<RwLock<HashSet<EndpointId>>> =
            Arc::new(RwLock::new(allowed.into_iter().filter_map(|p| p.parse().ok()).collect()));
        let endpoint = builder.hooks(Gate { allowed: allowed.clone(), state: gate }).bind().await.map_err(|e| anyhow!("could not start networking: {e}"))?;
        let known = iroh::address_lookup::MemoryLookup::new();
        if let Ok(l) = endpoint.address_lookup() {
            l.add(known.clone());
        }
        Ok(Arc::new(IrohTransport { endpoint, known, allowed, router: Mutex::new(None) }))
    }

    /// The iroh address for a link code (waits a few seconds for the endpoint to be online).
    pub(crate) async fn iroh_addr(&self) -> EndpointAddr {
        let _ = tokio::time::timeout(Duration::from_secs(5), self.endpoint.online()).await;
        self.endpoint.addr()
    }

    /// Starts accepting: the blob protocol from `store`, pairing and sync answered by `serve`.
    pub fn serve(&self, store: &FsStore, serve: Arc<dyn Serve>) {
        let blobs = BlobsProtocol::new(store, None);
        let router = Router::builder(self.endpoint.clone())
            .accept(iroh_blobs::ALPN, blobs)
            .accept(PAIR_ALPN, PairProto(serve.clone()))
            .accept(SYNC_ALPN, SyncProto(serve))
            .spawn();
        *self.router.lock().unwrap() = Some(router);
    }
}

impl Transport for IrohTransport {
    fn id(&self) -> String {
        self.endpoint.id().to_string()
    }

    fn ask<'a>(&'a self, peer: &'a str, ask: Ask, closed: &'a AtomicU32) -> BoxFut<'a, Result<(Vec<u8>, String)>> {
        Box::pin(async move {
            // The close code of the other device's Gate, whichever step meets it (at connect the text carries it; at write or read
            // only the error's source does).
            let seen = |e: &(dyn std::error::Error + 'static)| {
                // 403 is the one that can unlink; any other close code of the Gate only says why this try failed.
                let c = if closed_403(e) { Some(403) } else { closed_code(e) };
                if let Some(c) = c {
                    closed.store(c, Ordering::Relaxed);
                }
            };
            let id: EndpointId = peer.parse().map_err(|_| anyhow!("bad device key"))?;
            let conn = tokio::time::timeout(Duration::from_secs(30), self.endpoint.connect(id, SYNC_ALPN))
                .await
                .map_err(|_| anyhow!("not reachable"))?
                .map_err(|e| {
                    seen(&e);
                    anyhow!("not reachable: {e}")
                })?;
            let via = conn.paths().iter().find(|p| p.is_selected()).map(|p| if p.is_relay() { "relay" } else { "direct" }).unwrap_or("direct").to_string();
            let (mut send, mut recv) = conn.open_bi().await.map_err(|e| {
                seen(&e);
                anyhow!("{e}")
            })?;
            send.write_all(ask.wire()).await.map_err(|e| {
                seen(&e);
                anyhow!("{e}")
            })?;
            send.finish().map_err(|e| anyhow!("{e}"))?;
            let (wait, limit, late) = match ask {
                Ask::Index => (120, MAX_INDEX, "timed out reading the file list"),
                Ask::Secrets => (30, 1024 * 1024, "timed out reading the keys"),
            };
            let bytes = tokio::time::timeout(Duration::from_secs(wait), recv.read_to_end(limit))
                .await
                .map_err(|_| anyhow!(late))?
                .map_err(|e| {
                    seen(&e);
                    anyhow!("{e}")
                })?;
            conn.close(0u32.into(), b"done");
            Ok((bytes, via))
        })
    }

    fn pair(&self, to: PairTarget, hello: Vec<u8>) -> BoxFut<'_, Result<Vec<u8>>> {
        Box::pin(async move {
            let conn = tokio::time::timeout(Duration::from_secs(45), self.endpoint.connect(to.iroh, PAIR_ALPN))
                .await
                .map_err(|_| anyhow!("the other device did not answer"))?
                .map_err(|e| anyhow!("could not reach the other device: {e}"))?;
            let (mut send, mut recv) = conn.open_bi().await.map_err(|e| anyhow!("{e}"))?;
            send.write_all(&hello).await.map_err(|e| anyhow!("{e}"))?;
            send.finish().map_err(|e| anyhow!("{e}"))?;
            let bytes = recv.read_to_end(4096).await.map_err(|e| anyhow!("{e}"))?;
            conn.close(0u32.into(), b"done");
            Ok(bytes)
        })
    }

    fn link_addr(&self) -> BoxFut<'_, (EndpointAddr, Option<String>)> {
        Box::pin(async move { (self.iroh_addr().await, None) })
    }

    fn learn_iroh(&self, addr: EndpointAddr) {
        self.known.add_endpoint_info(addr);
    }

    fn allow(&self, peer: &str) {
        if let Ok(k) = peer.parse::<EndpointId>() {
            self.allowed.write().unwrap().insert(k);
        }
    }

    fn disallow(&self, peer: &str) {
        if let Ok(k) = peer.parse::<EndpointId>() {
            self.allowed.write().unwrap().remove(&k);
        }
    }

    fn fetch<'a>(&'a self, store: &'a FsStore, hash: Hash, providers: Vec<String>) -> BoxFut<'a, Result<BoxStream<FetchEvent>>> {
        Box::pin(async move {
            let providers: Vec<EndpointId> = providers.iter().filter_map(|p| p.parse().ok()).collect();
            let strategy = if providers.len() > 1 { SplitStrategy::Split } else { SplitStrategy::None };
            let dl = store.downloader(&self.endpoint);
            let stream = dl
                .download_with_opts(DownloadOptions::new(HashAndFormat::raw(hash), Shuffled::new(providers), strategy))
                .stream()
                .await
                .map_err(|e| anyhow!("{e}"))?;
            let events = stream.filter_map(|item| match item {
                DownloadProgressItem::Progress(n) => Some(FetchEvent::Progress(n)),
                DownloadProgressItem::Error(e) => {
                    Some(FetchEvent::Failed(if is_no_space(&e) { NO_SPACE.to_string() } else { format!("{e}") }))
                }
                DownloadProgressItem::DownloadError => Some(FetchEvent::Failed("the transfer stopped".into())),
                _ => None,
            });
            Ok(Box::pin(events) as BoxStream<FetchEvent>)
        })
    }

    fn network_change(&self) -> BoxFut<'_, ()> {
        Box::pin(async move { self.endpoint.network_change().await })
    }

    fn addresses(&self) -> (Option<String>, Vec<String>) {
        let addr = self.endpoint.addr();
        let relay = addr.relay_urls().next().map(|u| u.to_string());
        let direct = addr.ip_addrs().map(|a| a.to_string()).collect();
        (relay, direct)
    }

    fn port(&self) -> Option<u16> {
        self.endpoint.bound_sockets().into_iter().find(|a| a.is_ipv4()).map(|a| a.port())
    }

    fn shutdown(&self) -> BoxFut<'_, ()> {
        Box::pin(async move {
            let router = self.router.lock().unwrap().take();
            if let Some(r) = router {
                let _ = tokio::time::timeout(Duration::from_secs(5), r.shutdown()).await;
            }
        })
    }
}

/// Linking: one hello with the one-time code, one answer.
#[derive(Clone)]
struct PairProto(Arc<dyn Serve>);

impl std::fmt::Debug for PairProto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("PairProto")
    }
}

impl ProtocolHandler for PairProto {
    async fn accept(&self, conn: Connection) -> Result<(), AcceptError> {
        let (mut send, mut recv) = conn.accept_bi().await?;
        let bytes = recv.read_to_end(4096).await.map_err(AcceptError::from_err)?;
        let reply = self.0.pair_hello(&conn.remote_id().to_string(), &bytes);
        send.write_all(&reply).await.map_err(AcceptError::from_err)?;
        send.finish()?;
        conn.closed().await;
        Ok(())
    }
}

/// Sends a linked device this device's index, or its secrets for that device.
#[derive(Clone)]
struct SyncProto(Arc<dyn Serve>);

impl std::fmt::Debug for SyncProto {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("SyncProto")
    }
}

impl ProtocolHandler for SyncProto {
    async fn accept(&self, conn: Connection) -> Result<(), AcceptError> {
        let (mut send, mut recv) = conn.accept_bi().await?;
        let ask = recv.read_to_end(64).await.map_err(AcceptError::from_err)?;
        let peer = conn.remote_id().to_string();
        let what = if ask == b"secrets" { Ask::Secrets } else { Ask::Index };
        let body = self.0.clone().answer(peer.clone(), what).await;
        send.write_all(&body).await.map_err(AcceptError::from_err)?;
        send.finish()?;
        conn.closed().await;
        if what == Ask::Index {
            // A peer asking means it may have changes too: compare soon.
            self.0.asked(&peer);
        }
        Ok(())
    }
}
