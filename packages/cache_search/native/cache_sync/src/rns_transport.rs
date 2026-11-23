//! Reticulum beside iroh (1.2, Android and Linux): [`MultiTransport`] is a [`Transport`] that asks both networks and takes
//! the first good answer, serves the same requests on both, and fetches files over whichever network last answered.
//!
//! Everything here rides standard Reticulum: announces, path requests, links, requests and resources, routed through ordinary
//! transport nodes. Nothing works only direct, and nothing here routes by itself.

use std::collections::HashMap;
use std::pin::Pin;
use std::sync::atomic::{AtomicU32, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, RwLock};
use std::task::{Context, Poll};
use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use cache_rns::{blobs, Asker, BoxFut as RnsFut, Config as RnsConfig, Handler, Iface, RnsNode, Via};
use iroh::{PublicKey, SecretKey};
use iroh_blobs::{store::fs::FsStore, Hash};
use n0_future::Stream;
use serde_json::{json, Value};
use tokio::sync::mpsc;

use crate::transport::{Ask, BoxFut, BoxStream, FetchEvent, IrohTransport, PairTarget, Serve, Transport, NO_REACH};
use crate::MAX_INDEX;

/// How long iroh waits before it starts when Reticulum has a path to the device: Reticulum answers first when it can, and
/// iroh covers it when it cannot.
const IROH_HEAD_START: Duration = Duration::from_millis(1500);
/// How long a pairing waits for a path to the code's Reticulum destination before it goes over iroh instead.
const PAIR_PATH_WAIT: Duration = Duration::from_secs(6);
/// How long a short code's pairing waits for a path to its destination (a routed answer may be slow).
const SHORT_PATH_WAIT: Duration = Duration::from_secs(20);
/// The longest one 16 MiB window of a file may take over Reticulum (the Reticulum fetch's own stall timeout; see
/// [`MultiTransport::fetch`]).
const WINDOW_TIMEOUT: Duration = Duration::from_secs(120);
/// While a window is on its way, the fetch says so this often.
const HEARTBEAT: Duration = Duration::from_secs(5);

const PATH_INDEX: &str = "/cache/index";
const PATH_SECRETS: &str = "/cache/secrets";
const PATH_PAIR: &str = "/cache/pair";

/// The network that last answered a device.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Net {
    Reticulum,
    Iroh,
}

#[derive(Clone)]
struct StartArgs {
    device: SecretKey,
    blobs: iroh_blobs::api::Store,
    serve: Arc<dyn Serve>,
    interfaces: Vec<Iface>,
    pair_local_tcp: bool,
}

struct Rns {
    node: Arc<RnsNode>,
    dest_hex: String,
    sig_hex: String,
}

/// iroh with Reticulum beside it.
pub struct MultiTransport {
    iroh: Arc<IrohTransport>,
    rns: RwLock<Option<Rns>>,
    /// What the node was started with, to start it again (a used-up Nearby pairing pool).
    start_args: Mutex<Option<StartArgs>>,
    /// Linked devices (iroh ids) and the Reticulum destination of each, when known (hex).
    peers: Mutex<HashMap<String, Option<String>>>,
    last_via: Mutex<HashMap<String, Net>>,
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if !s.len().is_multiple_of(2) || !s.is_ascii() {
        return None;
    }
    (0..s.len() / 2).map(|i| u8::from_str_radix(&s[2 * i..2 * i + 2], 16).ok()).collect()
}

impl MultiTransport {
    /// `peers`: the linked devices with the Reticulum destination saved for each.
    pub fn new(iroh: Arc<IrohTransport>, peers: impl IntoIterator<Item = (String, Option<String>)>) -> Arc<MultiTransport> {
        Arc::new(MultiTransport { iroh, rns: RwLock::new(None), start_args: Mutex::new(None), peers: Mutex::new(peers.into_iter().collect()), last_via: Mutex::default() })
    }

    /// Starts the Reticulum node (after the store has opened): the linked devices and their saved destinations, then the
    /// requests answered by `serve`. `interfaces` are the test block's; none means Wi-Fi auto.
    pub async fn start_rns(&self, device: SecretKey, store: &FsStore, serve: Arc<dyn Serve>, interfaces: Vec<Iface>, pair_local_tcp: bool) -> Result<()> {
        *self.start_args.lock().unwrap() = Some(StartArgs { device, blobs: (**store).clone(), serve, interfaces, pair_local_tcp });
        self.launch().await
    }

    async fn launch(&self) -> Result<()> {
        let a = self.start_args.lock().unwrap().clone().ok_or_else(|| anyhow!("Reticulum was not set up"))?;
        let cfg = RnsConfig {
            device: a.device.clone(),
            interfaces: a.interfaces.clone(),
            peers: self.peer_list(),
            wifi_group: None,
            paths: vec![PATH_INDEX.into(), PATH_SECRETS.into(), PATH_PAIR.into()],
            open_paths: vec![PATH_PAIR.into()],
            max_bytes: MAX_INDEX as u64,
            blobs: Some(a.blobs.clone()),
            pair_local_tcp: a.pair_local_tcp,
        };
        let node = Arc::new(RnsNode::start(cfg, Arc::new(Serving { serve: a.serve.clone() })).await?);
        let dest = node.destination();
        let sig = cache_rns::vouch_destination(&a.device, &dest);
        *self.rns.write().unwrap() = Some(Rns { node, dest_hex: cache_rns::dest_hex(&dest), sig_hex: hex(&sig) });
        Ok(())
    }

    /// Builds the Reticulum node again, with a fresh pairing pool (the old one is used up). Sync links drop and come back;
    /// iroh carries them meanwhile. The old node's listeners may take a moment to let go, so the start is retried.
    async fn restart(&self) -> Result<()> {
        if let Some(old) = self.rns.write().unwrap().take() {
            old.node.stop();
        }
        let mut last = anyhow!("not started");
        for _ in 0..30 {
            tokio::time::sleep(Duration::from_millis(200)).await;
            match self.launch().await {
                Ok(()) => return Ok(()),
                Err(e) => last = e,
            }
        }
        Err(last.context("could not start Reticulum again"))
    }

    fn node(&self) -> Option<Arc<RnsNode>> {
        self.rns.read().unwrap().as_ref().map(|r| r.node.clone())
    }

    fn peer_list(&self) -> Vec<(PublicKey, Option<cache_rns::DestinationHash>)> {
        self.peers
            .lock()
            .unwrap()
            .iter()
            .filter_map(|(id, d)| Some((id.parse::<PublicKey>().ok()?, d.as_deref().and_then(cache_rns::dest_from_hex))))
            .collect()
    }

    fn push_peers(&self) {
        if let Some(n) = self.node() {
            n.set_peers(&self.peer_list());
        }
    }

    fn note(&self, peer: &str, net: Net) {
        self.last_via.lock().unwrap().insert(peer.to_string(), net);
    }

    async fn pair_rns(&self, node: &Arc<RnsNode>, to: &PairTarget, dest_hex: &str, hello: &[u8]) -> Result<Vec<u8>> {
        let dest = cache_rns::dest_from_hex(dest_hex).ok_or_else(|| anyhow!("bad Reticulum destination"))?;
        let key = to.iroh.id;
        // The destination is stored for the device (so the node asks for a path to it) before the request.
        self.peers.lock().unwrap().insert(key.to_string(), Some(dest_hex.to_string()));
        self.push_peers();
        if !node.reachable(&key) {
            let _ = tokio::time::timeout(PAIR_PATH_WAIT, node.find_path_to(&key)).await;
        }
        if !node.reachable(&key) {
            bail!("no Reticulum path to the other device");
        }
        node.request_unlinked(dest, PATH_PAIR, hello, Duration::from_secs(30)).await
    }
}

impl Transport for MultiTransport {
    fn id(&self) -> String {
        self.iroh.id()
    }

    fn ask<'a>(&'a self, peer: &'a str, ask: Ask, closed: &'a AtomicU32) -> BoxFut<'a, Result<(Vec<u8>, String)>> {
        Box::pin(async move {
            let key: Option<PublicKey> = peer.parse().ok();
            let node = self.node().zip(key).filter(|(n, k)| n.reachable(k));
            let Some((node, key)) = node else {
                let r = self.iroh.ask(peer, ask, closed).await;
                if r.is_ok() {
                    self.note(peer, Net::Iroh);
                }
                return r;
            };
            let (path, wait) = match ask {
                Ask::Index => (PATH_INDEX, Duration::from_secs(120)),
                Ask::Secrets => (PATH_SECRETS, Duration::from_secs(30)),
            };
            let over_rns = async {
                let body = node.request(&key, path, b"ask", wait).await?;
                // "wifi" is what the app's Same Wi-Fi row keys on: the route comes in on a Wi-Fi interface.
                let via = if node.via(&key) == Some(Via::Wifi) { "wifi" } else { "reticulum" };
                Ok::<_, anyhow::Error>((body, via.to_string()))
            };
            let over_iroh = async {
                tokio::time::sleep(IROH_HEAD_START).await;
                self.iroh.ask(peer, ask, closed).await
            };
            tokio::pin!(over_rns, over_iroh);
            let (mut rns_done, mut iroh_done) = (false, false);
            let mut failure = None;
            // The first good answer wins and the other is dropped. `closed` (the 403 that can unlink) is only ever set by iroh.
            loop {
                tokio::select! {
                    r = &mut over_rns, if !rns_done => {
                        rns_done = true;
                        match r {
                            Ok(v) => {
                                self.note(peer, Net::Reticulum);
                                return Ok(v);
                            }
                            Err(e) => failure = failure.or(Some(e)),
                        }
                    }
                    r = &mut over_iroh, if !iroh_done => {
                        iroh_done = true;
                        match r {
                            Ok(v) => {
                                self.note(peer, Net::Iroh);
                                return Ok(v);
                            }
                            // iroh's failure is the one the engine knows how to read.
                            Err(e) => failure = Some(e),
                        }
                    }
                }
                if rns_done && iroh_done {
                    return Err(failure.unwrap_or_else(|| anyhow!("not reachable")));
                }
            }
        })
    }

    fn pair(&self, to: PairTarget, hello: Vec<u8>) -> BoxFut<'_, Result<Vec<u8>>> {
        Box::pin(async move {
            if let (Some(node), Some(dest)) = (self.node(), to.rns.clone()) {
                match self.pair_rns(&node, &to, &dest, &hello).await {
                    Ok(r) => return Ok(r),
                    Err(_) => {
                        // Not reachable that way: over iroh, as before.
                        self.peers.lock().unwrap().remove(&to.iroh.id.to_string());
                        self.push_peers();
                    }
                }
            }
            self.iroh.pair(to, hello).await
        })
    }

    fn pair_short(&self, dest_hex: &str, body: Vec<u8>) -> BoxFut<'_, Result<Vec<u8>>> {
        let dest_hex = dest_hex.to_string();
        Box::pin(async move {
            let node = self.node().ok_or_else(|| anyhow!(NO_REACH))?;
            let dest = cache_rns::dest_from_hex(&dest_hex).ok_or_else(|| anyhow!(NO_REACH))?;
            // A standard path request, answered through however many transport nodes lie between.
            if !node.find_path_dest(dest, SHORT_PATH_WAIT).await {
                bail!(NO_REACH);
            }
            node.request_unlinked(dest, PATH_PAIR, &body, Duration::from_secs(30)).await.map_err(|_| anyhow!(NO_REACH))
        })
    }

    fn verify_rns(&self, key: &str, dest: &str, sig: &str) -> bool {
        match (key.parse::<PublicKey>(), cache_rns::dest_from_hex(dest), unhex(sig)) {
            (Ok(k), Some(d), Some(s)) => cache_rns::check_vouch_destination(&k, &d, &s),
            _ => false,
        }
    }

    fn learn_iroh(&self, addr: iroh::EndpointAddr) {
        self.iroh.learn_iroh(addr);
    }

    fn link_addr(&self) -> BoxFut<'_, (iroh::EndpointAddr, Option<String>)> {
        Box::pin(async move { (self.iroh.iroh_addr().await, self.rns.read().unwrap().as_ref().map(|r| r.dest_hex.clone())) })
    }

    fn rns_info(&self) -> Option<(String, String)> {
        self.rns.read().unwrap().as_ref().map(|r| (r.dest_hex.clone(), r.sig_hex.clone()))
    }

    fn learn_rns(&self, peer: &str, dest: &str, sig: &str) -> bool {
        let (Ok(key), Some(d), Some(sig)) = (peer.parse::<PublicKey>(), cache_rns::dest_from_hex(dest), unhex(sig)) else {
            return false;
        };
        if self.rns.read().unwrap().is_none() || !cache_rns::check_vouch_destination(&key, &d, &sig) {
            return false;
        }
        self.peers.lock().unwrap().insert(peer.to_string(), Some(cache_rns::dest_hex(&d)));
        self.push_peers();
        true
    }

    fn allow(&self, peer: &str) {
        self.iroh.allow(peer);
        self.peers.lock().unwrap().entry(peer.to_string()).or_insert(None);
        self.push_peers();
    }

    fn disallow(&self, peer: &str) {
        self.iroh.disallow(peer);
        self.peers.lock().unwrap().remove(peer);
        self.last_via.lock().unwrap().remove(peer);
        self.push_peers();
    }

    /// A provider last reached over Reticulum is fetched from over Reticulum ([`cache_rns::blobs`]); the others over iroh's
    /// downloader as before. Both write into the same store, so a transfer cut on one network resumes, from the windows
    /// already verified, on either.
    ///
    /// Stall: the engine drops a transfer that reports no progress for 20 s, but over Reticulum progress comes once per 16 MiB
    /// window. So Reticulum gets its own stall timeout rather than finer progress (which would need a change to the window
    /// protocol): a window may take up to [`WINDOW_TIMEOUT`] (120 s, which a 16 MiB window needs about 140 KB/s to meet), and
    /// while it is in flight the stream repeats the verified byte count every few seconds so the engine's 20 s rule does not
    /// fire. A dead link ends the window with an error at the timeout at the latest; the next round resumes from what the
    /// store holds.
    fn fetch<'a>(&'a self, store: &'a FsStore, hash: Hash, providers: Vec<String>) -> BoxFut<'a, Result<BoxStream<FetchEvent>>> {
        Box::pin(async move {
            let via_rns = |p: &String| self.last_via.lock().unwrap().get(p) == Some(&Net::Reticulum);
            let (rns_providers, iroh_providers): (Vec<String>, Vec<String>) = providers.iter().cloned().partition(via_rns);
            let node = self.node();
            match node {
                Some(node) if iroh_providers.is_empty() && !rns_providers.is_empty() => {
                    let keys: Vec<PublicKey> = rns_providers.iter().filter_map(|p| p.parse().ok()).collect();
                    Ok(Box::pin(RnsFetch::start(node, (**store).clone(), hash, keys)) as BoxStream<FetchEvent>)
                }
                _ => self.iroh.fetch(store, hash, if iroh_providers.is_empty() { providers } else { iroh_providers }).await,
            }
        })
    }

    fn pairing_open(&self, name: String, kind: Option<String>) -> BoxFut<'_, Result<()>> {
        Box::pin(async move {
            let mut node = self.node().ok_or_else(|| anyhow!("Nearby linking needs Reticulum, which is not running on this device"))?;
            if node.nearby().pool_used_up() {
                self.restart().await?;
                node = self.node().ok_or_else(|| anyhow!("Reticulum did not come back"))?;
            }
            node.pair_open(cache_rns::PairSelf { name, kind }).await
        })
    }

    fn skew_clock(&self, ms: u64) {
        if let Some(n) = self.node() {
            n.nearby().skew_clock(ms);
        }
    }

    fn pairing_close(&self) -> BoxFut<'_, ()> {
        Box::pin(async move {
            if let Some(n) = self.node() {
                n.pair_close().await;
            }
        })
    }

    fn nearby_list(&self) -> Value {
        let devices: Vec<Value> = self
            .node()
            .map(|n| n.pair_list())
            .unwrap_or_default()
            .into_iter()
            .map(|d| json!({"id": d.id, "name": d.name, "kind": d.kind, "via": "wifi"}))
            .collect();
        json!({"devices": devices})
    }

    fn nearby_state(&self) -> Value {
        let Some(n) = self.node() else {
            return json!({"state": "idle", "name": null, "kind": null, "words": [], "reason": null});
        };
        let s = n.pair_status();
        json!({"state": s.state, "name": s.name, "kind": s.kind, "words": s.words.map(|w| w.to_vec()).unwrap_or_default(), "reason": s.reason})
    }

    fn nearby_link(&self, id: String, name: String, kind: Option<String>) -> BoxFut<'_, Result<()>> {
        Box::pin(async move {
            let node = self.node().ok_or_else(|| anyhow!("Nearby linking needs Reticulum, which is not running on this device"))?;
            node.pair_link(&id, cache_rns::PairSelf { name, kind }).await
        })
    }

    fn nearby_answer(&self, ok: bool) -> BoxFut<'_, Result<()>> {
        Box::pin(async move {
            let node = self.node().ok_or_else(|| anyhow!("Nearby linking needs Reticulum, which is not running on this device"))?;
            node.pair_answer(ok).await
        })
    }

    fn network_change(&self) -> BoxFut<'_, ()> {
        Box::pin(async move {
            if let Some(n) = self.node() {
                let _ = n.announce().await;
            }
            self.iroh.network_change().await;
        })
    }

    fn addresses(&self) -> (Option<String>, Vec<String>) {
        self.iroh.addresses()
    }

    fn port(&self) -> Option<u16> {
        self.iroh.port()
    }

    fn shutdown(&self) -> BoxFut<'_, ()> {
        Box::pin(async move {
            if let Some(n) = self.node() {
                n.stop();
            }
            self.iroh.shutdown().await;
        })
    }
}

/// A file fetched over Reticulum: a task running [`blobs::fetch`] (each provider in turn), reporting into a channel. Dropping
/// the stream ends the task; the windows verified so far stay in the store.
struct RnsFetch {
    rx: mpsc::Receiver<FetchEvent>,
    task: tokio::task::JoinHandle<()>,
}

impl RnsFetch {
    fn start(node: Arc<RnsNode>, store: iroh_blobs::api::Store, hash: Hash, providers: Vec<PublicKey>) -> RnsFetch {
        let (tx, rx) = mpsc::channel(32);
        let task = tokio::spawn(async move {
            let have = Arc::new(AtomicU64::new(0));
            let mut last = String::from("no linked device could be reached over Reticulum");
            for peer in providers {
                let (h, t2) = (have.clone(), tx.clone());
                let fetch = blobs::fetch(&node, &peer, &store, hash, WINDOW_TIMEOUT, move |f| {
                    h.store(f.have, Ordering::Relaxed);
                    let _ = t2.try_send(FetchEvent::Progress(f.have));
                });
                tokio::pin!(fetch);
                let mut beat = tokio::time::interval(HEARTBEAT);
                let res = loop {
                    tokio::select! {
                        r = &mut fetch => break r,
                        _ = beat.tick() => {
                            let _ = tx.try_send(FetchEvent::Progress(have.load(Ordering::Relaxed)));
                        }
                    }
                };
                match res {
                    Ok(f) => {
                        let _ = tx.send(FetchEvent::Progress(f.size)).await;
                        return;
                    }
                    Err(e) => last = format!("{e:#}"),
                }
            }
            let _ = tx.send(FetchEvent::Failed(last)).await;
        });
        RnsFetch { rx, task }
    }
}

impl Stream for RnsFetch {
    type Item = FetchEvent;
    fn poll_next(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<FetchEvent>> {
        self.rx.poll_recv(cx)
    }
}

impl Drop for RnsFetch {
    fn drop(&mut self) {
        self.task.abort();
    }
}

/// What the Reticulum node asks of the engine.
struct Serving {
    serve: Arc<dyn Serve>,
}

impl Handler for Serving {
    fn request(&self, asker: Asker, path: &str, body: Vec<u8>) -> RnsFut<Result<Vec<u8>>> {
        let serve = self.serve.clone();
        let path = path.to_string();
        Box::pin(async move {
            match path.as_str() {
                PATH_INDEX | PATH_SECRETS => {
                    let Asker::Linked(peer) = asker else { bail!("not a linked device") };
                    let peer = peer.to_string();
                    let ask = if path == PATH_SECRETS { Ask::Secrets } else { Ask::Index };
                    let reply = serve.clone().answer(peer.clone(), ask).await;
                    if ask == Ask::Index {
                        // A peer asking means it may have changes too: compare soon.
                        serve.asked(&peer);
                    }
                    Ok(reply)
                }
                PATH_PAIR => {
                    // Not a linked device yet: the hello names its device key and carries that key's signature over the
                    // Reticulum destination it comes from, so what is stored for it is its own.
                    let refuse = |why: &str| Ok(json!({"ok": false, "error": why}).to_string().into_bytes());
                    let Ok(v) = serde_json::from_slice::<Value>(&body) else { return refuse("not a pairing hello") };
                    // A short link code's pairing: `{secret, hello}`, every check made by the engine (the code being shown, the
                    // secret, the signature).
                    if v.get("secret").is_some() {
                        return Ok(serve.clone().pair_short(body).await);
                    }
                    let key = v.get("key").and_then(|k| k.as_str()).and_then(|k| k.parse::<PublicKey>().ok().map(|p| (k.to_string(), p)));
                    let proof = v.get("rns").and_then(|r| Some((r.get("dest")?.as_str()?.to_string(), r.get("sig")?.as_str()?.to_string())));
                    let (Some((id, key)), Some((dest, sig))) = (key, proof) else { return refuse("the hello does not say who it is from") };
                    let valid = cache_rns::dest_from_hex(&dest)
                        .zip(unhex(&sig))
                        .is_some_and(|(d, s)| cache_rns::check_vouch_destination(&key, &d, &s));
                    if !valid {
                        return refuse("the hello's signature does not check out");
                    }
                    Ok(serve.pair_hello(&id, &body))
                }
                _ => bail!("unknown path"),
            }
        })
    }

    fn notify(&self, from: PublicKey, _body: Vec<u8>) {
        self.serve.asked(&from.to_string());
    }

    fn pair_linked(&self, peer: PublicKey, name: String, destination: cache_rns::DestinationHash, sig: Vec<u8>) {
        self.serve.nearby_linked(&peer.to_string(), &name, &cache_rns::dest_hex(&destination), &hex(&sig));
    }
}
