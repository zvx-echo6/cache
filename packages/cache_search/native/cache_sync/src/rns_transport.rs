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
use cache_store::{Hash, Store};
use n0_future::Stream;
use serde_json::{json, Value};
use tokio::sync::mpsc;

use crate::entries::EntryPoint;
use crate::transport::{is_too_slow, Ask, BoxFut, BoxStream, Delta, EntryStatus, FetchEvent, IrohTransport, PairTarget, Serve, Speed, TooSlow, Transport, NO_REACH};
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
/// How long a notice waits for the other device's answer.
const NOTICE_TIMEOUT: Duration = Duration::from_secs(8);
/// While a window is on its way, the fetch says so this often.
const HEARTBEAT: Duration = Duration::from_secs(5);

const PATH_INDEX: &str = "/cache/index";
const PATH_SECRETS: &str = "/cache/secrets";
/// A summary of the file list, and the changes of one folder since a cursor (step 3). A build without them does not answer these
/// paths at all, so the engine asks only a device whose file list said it does.
const PATH_SUMMARY: &str = "/cache/summary";
const PATH_DIFF: &str = "/cache/diff";
/// "Folder F is at counter N", from a linked device that changed it (step 3 part 2); never open to an unlinked device.
const PATH_NOTICE: &str = "/cache/notice";
/// The entry points (with their passphrases), answered to a linked device only.
const PATH_ENTRIES: &str = "/cache/entries";
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
    blobs: Store,
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
    /// Devices that used to be linked (iroh ids), for the node to answer "not linked" to.
    former: Mutex<Vec<String>>,
    /// Tests only: how long without an announce makes a device reachable again, in ms (0: the node's own).
    reach_gap_ms: AtomicU64,
    /// The entry points (on and off) the node is to have, kept to start it again.
    entries: Mutex<Vec<cache_rns::EntryPoint>>,
    /// The cap of each entry point (id, bytes), kept to give a node that starts again.
    entry_caps: Mutex<Vec<(String, u64)>>,
    /// How long a link may go without a measurement before the next request is preceded by a small one, in ms (u64::MAX: the node's own).
    probe_ms: AtomicU64,
}

/// An entry point as the node takes it (the passphrase in a string that is wiped when dropped).
pub(crate) fn to_rns(e: &EntryPoint) -> cache_rns::EntryPoint {
    cache_rns::EntryPoint {
        id: e.id.clone(),
        host: e.host.clone(),
        port: e.port,
        network_name: e.network_name.clone(),
        passphrase: e.passphrase.clone().map(cache_rns::Zeroizing::new),
        on: e.on,
    }
}

/// How a route comes in, as the status says it: "wifi", "entry:<id>" through an entry point, or "reticulum".
fn via_name(node: &RnsNode, key: &PublicKey) -> String {
    match node.via(key) {
        Some(Via::Wifi) => "wifi".into(),
        Some(Via::Entry(id)) => format!("entry:{id}"),
        _ => "reticulum".into(),
    }
}

/// The engine's class for cache_rns's.
fn speed_of(s: cache_rns::Speed) -> Speed {
    match s {
        cache_rns::Speed::Slow => Speed::Slow,
        cache_rns::Speed::Medium => Speed::Medium,
        cache_rns::Speed::Fast => Speed::Fast,
    }
}

#[cfg(test)]
fn rns_speed_of(s: Speed) -> cache_rns::Speed {
    match s {
        Speed::Slow => cache_rns::Speed::Slow,
        Speed::Medium => cache_rns::Speed::Medium,
        Speed::Fast => cache_rns::Speed::Fast,
    }
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
        Arc::new(MultiTransport { iroh, rns: RwLock::new(None), start_args: Mutex::new(None), peers: Mutex::new(peers.into_iter().collect()), last_via: Mutex::default(), former: Mutex::default(), reach_gap_ms: AtomicU64::new(0), entries: Mutex::default(), entry_caps: Mutex::default(), probe_ms: AtomicU64::new(u64::MAX) })
    }

    /// Starts the Reticulum node (after the store has opened): the linked devices and their saved destinations, then the
    /// requests answered by `serve`. `interfaces` are the test block's; none means Wi-Fi auto.
    pub async fn start_rns(&self, device: SecretKey, store: &Store, serve: Arc<dyn Serve>, interfaces: Vec<Iface>, pair_local_tcp: bool) -> Result<()> {
        // The entry points among the interfaces are kept apart: a start again (a used-up Nearby pool) uses the list as it is then.
        let (entries, interfaces): (Vec<Iface>, Vec<Iface>) = interfaces.into_iter().partition(|i| matches!(i, Iface::Entry(_)));
        *self.entries.lock().unwrap() = entries.into_iter().filter_map(|i| if let Iface::Entry(e) = i { Some(e) } else { None }).collect();
        *self.start_args.lock().unwrap() = Some(StartArgs { device, blobs: store.clone(), serve, interfaces, pair_local_tcp });
        self.launch().await
    }

    async fn launch(&self) -> Result<()> {
        let a = self.start_args.lock().unwrap().clone().ok_or_else(|| anyhow!("Reticulum was not set up"))?;
        let cfg = RnsConfig {
            device: a.device.clone(),
            interfaces: a.interfaces.iter().cloned().chain(self.entries.lock().unwrap().iter().filter(|e| e.on).cloned().map(Iface::Entry)).collect(),
            peers: self.peer_list(),
            wifi_group: None,
            paths: vec![PATH_INDEX.into(), PATH_SECRETS.into(), PATH_PAIR.into(), PATH_SUMMARY.into(), PATH_DIFF.into(), PATH_NOTICE.into(), PATH_ENTRIES.into()],
            open_paths: vec![PATH_PAIR.into()],
            max_bytes: MAX_INDEX as u64,
            blobs: Some(a.blobs.clone()),
            pair_local_tcp: a.pair_local_tcp,
        };
        let node = Arc::new(RnsNode::start(cfg, Arc::new(Serving { serve: a.serve.clone() })).await?);
        let dest = node.destination();
        node.set_former(&self.former_keys());
        node.set_entry_caps(&self.entry_caps.lock().unwrap());
        if let Some(ms) = Some(self.reach_gap_ms.load(Ordering::Relaxed)).filter(|ms| *ms > 0) {
            node.set_reach_gap(Duration::from_millis(ms));
        }
        if let Some(ms) = Some(self.probe_ms.load(Ordering::Relaxed)).filter(|ms| *ms != u64::MAX) {
            node.speeds().set_probe_every(Duration::from_millis(ms));
        }
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

    /// Tests only: how long without an announce makes a device reachable again.
    #[cfg(feature = "test-hooks")]
    pub fn set_reach_gap(&self, d: Duration) {
        self.reach_gap_ms.store(d.as_millis() as u64, Ordering::Relaxed);
    }

    /// How long a link may go without a measurement before a small request measures it (the node's own default, 10 s, unless set;
    /// tests make it short). Set before [`MultiTransport::start_rns`].
    pub fn set_probe_every(&self, d: Duration) {
        self.probe_ms.store(d.as_millis() as u64, Ordering::Relaxed);
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

    fn former_keys(&self) -> Vec<PublicKey> {
        self.former.lock().unwrap().iter().filter_map(|id| id.parse().ok()).collect()
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
                Ask::Entries => (PATH_ENTRIES, Duration::from_secs(30)),
            };
            let over_rns = async {
                let body = node.request(&key, path, b"ask", wait).await?;
                // The other end's class for this link does not allow what was asked: the slower judgment wins from now on.
                if cache_rns::speed::is_refusal(&body) {
                    node.speeds().note_refused(&key);
                    return Err(anyhow::Error::new(TooSlow));
                }
                // "wifi" is what the app's Same Wi-Fi row keys on: the route comes in on a Wi-Fi interface.
                Ok::<_, anyhow::Error>((body, via_name(&node, &key)))
            };
            let over_iroh = async {
                tokio::time::sleep(IROH_HEAD_START).await;
                self.iroh.ask(peer, ask, closed).await
            };
            tokio::pin!(over_rns, over_iroh);
            let (mut rns_done, mut iroh_done) = (false, false);
            let mut failure = None;
            // The other device said "not linked" over Reticulum. That answer is given only to a device it unlinked itself, so
            // iroh's own refusal (a Gate that says 409 "links reset" for 7 days after a fresh start, or 503) must not replace it.
            let mut rns_not_linked = false;
            // The other device refused over Reticulum as too slow: iroh's own failure must not hide that.
            let mut rns_slow = false;
            // The first good answer wins and the other is dropped. `closed` (the 403 that can unlink) is set by iroh's Gate and,
            // over Reticulum, by the other device answering the hello "not linked" (the engine still waits for two, 10 minutes apart).
            loop {
                tokio::select! {
                    r = &mut over_rns, if !rns_done => {
                        rns_done = true;
                        match r {
                            Ok(v) => {
                                self.note(peer, Net::Reticulum);
                                return Ok(v);
                            }
                            Err(e) => {
                                if cache_rns::is_not_linked(&e) {
                                    rns_not_linked = true;
                                    closed.store(403, Ordering::Relaxed);
                                }
                                rns_slow |= is_too_slow(&e);
                                failure = failure.or(Some(e));
                            }
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
                    if rns_not_linked {
                        closed.store(403, Ordering::Relaxed);
                    }
                    if rns_slow {
                        return Err(anyhow::Error::new(TooSlow));
                    }
                    return Err(failure.unwrap_or_else(|| anyhow!("not reachable")));
                }
            }
        })
    }

    fn ask_delta<'a>(&'a self, peer: &'a str, what: Delta, body: Vec<u8>, closed: &'a AtomicU32) -> BoxFut<'a, Result<(Vec<u8>, String)>> {
        Box::pin(async move {
            let key: Option<PublicKey> = peer.parse().ok();
            let Some((node, key)) = self.node().zip(key).filter(|(n, k)| n.reachable(k)) else {
                bail!("no Reticulum path to the device");
            };
            let (path, wait) = match what {
                Delta::Summary => (PATH_SUMMARY, Duration::from_secs(30)),
                Delta::Diff => (PATH_DIFF, Duration::from_secs(60)),
            };
            match node.request(&key, path, &body, wait).await {
                Ok(reply) if cache_rns::speed::is_refusal(&reply) => {
                    node.speeds().note_refused(&key);
                    Err(anyhow::Error::new(TooSlow))
                }
                Ok(reply) => {
                    self.note(peer, Net::Reticulum);
                    Ok((reply, via_name(&node, &key)))
                }
                Err(e) => {
                    if cache_rns::is_not_linked(&e) {
                        closed.store(403, Ordering::Relaxed);
                    }
                    Err(e)
                }
            }
        })
    }

    fn send_notice<'a>(&'a self, peer: &'a str, body: Vec<u8>) -> BoxFut<'a, Result<()>> {
        Box::pin(async move {
            let key: Option<PublicKey> = peer.parse().ok();
            let Some((node, key)) = self.node().zip(key).filter(|(n, k)| n.reachable(k)) else {
                bail!("no Reticulum path to the device");
            };
            // A short wait: a notice that does not arrive is covered by the reconnect round and the safety round.
            let reply = node.request(&key, PATH_NOTICE, &body, NOTICE_TIMEOUT).await?;
            if reply != b"ok" {
                bail!("the device did not take the notice");
            }
            Ok(())
        })
    }

    fn speed(&self, peer: &str) -> Speed {
        if !self.reached_over_rns(peer) {
            return Speed::Fast;
        }
        peer.parse::<PublicKey>().ok().zip(self.node()).map_or(Speed::Fast, |(k, n)| speed_of(n.speeds().ask_speed(&k)))
    }

    fn measure(&self, peer: &str) -> BoxFut<'_, bool> {
        let key = peer.parse::<PublicKey>().ok().zip(self.node()).filter(|_| self.reached_over_rns(peer));
        Box::pin(async move {
            match key {
                Some((k, n)) => n.measure(&k, Duration::from_secs(30)).await.unwrap_or(false),
                None => false,
            }
        })
    }

    fn interface_gen(&self) -> u64 {
        self.node().map_or(0, |n| n.interface_gen())
    }

    #[cfg(feature = "test-hooks")]
    fn test_relink(&self, peer: &str) {
        if let Some((k, n)) = peer.parse::<PublicKey>().ok().zip(self.node()) {
            n.relink(&k);
        }
    }

    #[cfg(feature = "test-hooks")]
    fn test_attach_iface(&self) {
        if let Some(n) = self.node() {
            // Nothing listens there: the interface exists (and is trying to connect), which is all a test needs.
            n.attach_tcp_client("127.0.0.1:9");
        }
    }

    #[cfg(feature = "test-hooks")]
    fn test_route_hops(&self, dest_hex: &str) -> BoxFut<'_, Option<u8>> {
        let dest = cache_rns::dest_from_hex(dest_hex);
        Box::pin(async move {
            let (node, dest) = self.node().zip(dest)?;
            node.test_route_hops(dest).await
        })
    }

    fn reached_over_rns(&self, peer: &str) -> bool {
        let reached = self.last_via.lock().unwrap().get(peer) == Some(&Net::Reticulum);
        reached && peer.parse::<PublicKey>().ok().zip(self.node()).is_some_and(|(k, n)| n.reachable(&k))
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

    fn set_entry_points(&self, entries: Vec<EntryPoint>) {
        let all: Vec<cache_rns::EntryPoint> = entries.iter().map(to_rns).collect();
        *self.entries.lock().unwrap() = all.clone();
        let caps: Vec<(String, u64)> = entries.iter().map(|e| (e.id.clone(), e.cap_bytes)).collect();
        *self.entry_caps.lock().unwrap() = caps.clone();
        if let Some(n) = self.node() {
            n.set_entry_points(&all);
            n.set_entry_caps(&caps);
        }
    }

    fn over_cap(&self, peer: &str, size: u64) -> bool {
        if !self.reached_over_rns(peer) {
            return false;
        }
        let Some((k, n)) = peer.parse::<PublicKey>().ok().zip(self.node()) else { return false };
        match n.via(&k) {
            Some(Via::Entry(id)) => n.entry_cap(&id).is_some_and(|c| size > c),
            _ => false,
        }
    }

    fn entry_status(&self) -> Vec<EntryStatus> {
        let Some(n) = self.node() else { return Vec::new() };
        n.entry_status()
            .into_iter()
            .map(|(id, st, checked)| {
                let state = match st {
                    cache_rns::EntryState::Off => "off",
                    cache_rns::EntryState::Connecting => "connecting",
                    cache_rns::EntryState::Connected => "connected",
                    cache_rns::EntryState::NotAnswering => "not_answering",
                    cache_rns::EntryState::Mismatch => "mismatch",
                    cache_rns::EntryState::NothingHeard => "nothing_heard",
                };
                EntryStatus { id, state, checked }
            })
            .collect()
    }

    fn allow(&self, peer: &str) {
        self.iroh.allow(peer);
        self.peers.lock().unwrap().entry(peer.to_string()).or_insert(None);
        self.push_peers();
    }

    fn set_former(&self, ids: &[String]) {
        *self.former.lock().unwrap() = ids.to_vec();
        if let Some(n) = self.node() {
            n.set_former(&self.former_keys());
        }
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
    fn fetch<'a>(&'a self, store: &'a Store, hash: Hash, providers: Vec<String>) -> BoxFut<'a, Result<BoxStream<FetchEvent>>> {
        Box::pin(async move {
            let via_rns = |p: &String| self.last_via.lock().unwrap().get(p) == Some(&Net::Reticulum);
            let (rns_providers, iroh_providers): (Vec<String>, Vec<String>) = providers.iter().cloned().partition(via_rns);
            let node = self.node();
            match node {
                Some(node) if iroh_providers.is_empty() && !rns_providers.is_empty() => {
                    let keys: Vec<PublicKey> = rns_providers.iter().filter_map(|p| p.parse().ok()).collect();
                    Ok(Box::pin(RnsFetch::start(node, store.clone(), hash, keys)) as BoxStream<FetchEvent>)
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
    fn start(node: Arc<RnsNode>, store: Store, hash: Hash, providers: Vec<PublicKey>) -> RnsFetch {
        let (tx, rx) = mpsc::channel(32);
        let task = tokio::spawn(async move {
            let have = Arc::new(AtomicU64::new(0));
            let mut last = String::from("no linked device could be reached over Reticulum");
            let mut slow = false;
            let mut over = false;
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
                    Err(e) => {
                        slow |= blobs::is_too_slow(&e);
                        over |= blobs::is_over_cap(&e);
                        last = format!("{e:#}");
                    }
                }
            }
            // Every device that could not carry it said the link is too slow (or this end did): the file waits, it did not fail.
            // A device that holds it back for the entry point's cap says so (the file waits for Wi-Fi), whatever else was said.
            let _ = tx.send(if over { FetchEvent::OverCap(last) } else if slow { FetchEvent::Waiting(last) } else { FetchEvent::Failed(last) }).await;
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

/// A differences request ([`crate::delta::DiffAsk`]) whose page is held to `cap` bytes: its `max` is the smaller of what the asker
/// asked for and the cap. A body that is not that JSON is left as it is (the engine answers it "full").
fn cap_page(body: &[u8], cap: usize) -> Vec<u8> {
    let Ok(mut v) = serde_json::from_slice::<Value>(body) else { return body.to_vec() };
    let Some(o) = v.as_object_mut() else { return body.to_vec() };
    let max = o.get("max").and_then(|m| m.as_u64()).map_or(cap, |m| (m as usize).min(cap));
    o.insert("max".into(), json!(max));
    serde_json::to_vec(&v).unwrap_or_else(|_| body.to_vec())
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
                PATH_ENTRIES => {
                    // The list holds passphrases: a linked device only, and asking for it does not start a round.
                    let Asker::Linked(peer) = asker else { bail!("not a linked device") };
                    Ok(serve.clone().answer(peer.to_string(), Ask::Entries).await)
                }
                PATH_SUMMARY | PATH_DIFF => {
                    let Asker::Linked(peer) = asker else { bail!("not a linked device") };
                    let peer = peer.to_string();
                    let what = if path == PATH_SUMMARY { Delta::Summary } else { Delta::Diff };
                    let reply = serve.clone().answer_delta(peer.clone(), what, body).await;
                    if what == Delta::Summary {
                        // Asking means it may have changes too, as with the whole list.
                        serve.asked(&peer);
                    }
                    Ok(reply)
                }
                PATH_NOTICE => {
                    let Asker::Linked(peer) = asker else { bail!("not a linked device") };
                    Ok(serve.notice(&peer.to_string(), &body))
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

    /// What this end's class for the asker's link allows ([`cache_rns::Speed`]), on top of what [`Handler::request`] answers: the
    /// whole file list is not given over a Slow link (it waits for a faster one), and a page of differences is no bigger than the
    /// class carries. The asker is told so even if it is a build that does not check its own class.
    fn request_at(&self, asker: Asker, speed: cache_rns::Speed, path: &str, body: Vec<u8>) -> RnsFut<Result<Vec<u8>>> {
        let linked = matches!(asker, Asker::Linked(_));
        if linked && path == PATH_INDEX && speed == cache_rns::Speed::Slow {
            return Box::pin(async { Err(anyhow::Error::new(TooSlow)) });
        }
        let body = if linked && path == PATH_DIFF { cap_page(&body, self.serve.page_cap(speed_of(speed))) } else { body };
        self.request(asker, path, body)
    }

    #[cfg(feature = "test-hooks")]
    fn refuse_blobs(&self) -> bool {
        self.serve.test_refuse_blobs()
    }

    fn refused_over_cap(&self, peer: PublicKey, hash: Hash) {
        self.serve.refused_over_cap(&peer.to_string(), &hash.to_string());
    }

    fn blob_allowed(&self, peer: PublicKey, hash: Hash, speed: cache_rns::Speed) -> bool {
        self.serve.blob_allowed(&peer.to_string(), &hash.to_string(), speed_of(speed))
    }

    fn notify(&self, from: PublicKey, _body: Vec<u8>) {
        self.serve.asked(&from.to_string());
    }

    fn reachable(&self, peer: PublicKey) {
        self.serve.reachable(&peer.to_string());
    }

    fn link_closed(&self, peer: PublicKey, reason: &str, open_secs: Option<u64>, rtt_ms: Option<u64>) {
        self.serve.link_closed(&peer.to_string(), reason, open_secs, rtt_ms);
    }

    fn route_moved(&self, peer: PublicKey, now: &str, was: &str, from: cache_rns::RouteFrom) {
        self.serve.route_moved(&peer.to_string(), now, was, from.text());
    }

    fn blobs_ready(&self) -> bool {
        self.serve.blobs_ready()
    }

    fn served(&self, peer: PublicKey, hash: Hash, end: u64) {
        self.serve.served(&peer.to_string(), &hash.to_string(), end);
    }

    fn pair_linked(&self, peer: PublicKey, name: String, destination: cache_rns::DestinationHash, sig: Vec<u8>) {
        self.serve.nearby_linked(&peer.to_string(), &name, &cache_rns::dest_hex(&destination), &hex(&sig));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The engine's class and cache_rns's are two types (cache_rns is not built everywhere); they must say the same.
    #[test]
    fn the_two_classes_agree() {
        for (mine, theirs) in [(Speed::Slow, cache_rns::Speed::Slow), (Speed::Medium, cache_rns::Speed::Medium), (Speed::Fast, cache_rns::Speed::Fast)] {
            assert_eq!(speed_of(theirs), mine);
            assert_eq!(rns_speed_of(mine), theirs);
            assert_eq!(mine.as_str(), theirs.as_str());
            for size in [0, 1, 4096, 8 * 1024 + 1, 10 * 1024 * 1024, 10 * 1024 * 1024 + 1, 1 << 40] {
                assert_eq!(mine.carries_file(size), theirs.carries_file(size), "{mine:?} {size}");
            }
        }
        assert_eq!(crate::transport::TOO_SLOW_TEXT, cache_rns::speed::TOO_SLOW_TEXT);
    }

    #[test]
    fn a_page_is_held_to_the_cap_and_never_raised() {
        let body = serde_json::to_vec(&json!({"share": "s", "c": 1})).unwrap();
        let v: Value = serde_json::from_slice(&cap_page(&body, 4096)).unwrap();
        assert_eq!(v["max"], 4096);
        let body = serde_json::to_vec(&json!({"share": "s", "c": 1, "max": 1000})).unwrap();
        let v: Value = serde_json::from_slice(&cap_page(&body, 4096)).unwrap();
        assert_eq!(v["max"], 1000, "an asker may ask for less");
        let body = serde_json::to_vec(&json!({"share": "s", "c": 1, "max": 9_999_999})).unwrap();
        let v: Value = serde_json::from_slice(&cap_page(&body, 4096)).unwrap();
        assert_eq!(v["max"], 4096);
        assert_eq!(cap_page(b"not json", 4096), b"not json");
    }

    /// A Serve that must never be reached: an unknown path has to be refused before the engine is asked anything.
    struct Unreached;

    impl Serve for Unreached {
        fn pair_hello(&self, _: &str, _: &[u8]) -> Vec<u8> {
            panic!("pair_hello reached")
        }
        fn pair_short(self: Arc<Self>, _: Vec<u8>) -> BoxFut<'static, Vec<u8>> {
            panic!("pair_short reached")
        }
        fn answer(self: Arc<Self>, _: String, _: Ask) -> BoxFut<'static, Vec<u8>> {
            panic!("answer reached")
        }
        fn answer_delta(self: Arc<Self>, _: String, _: Delta, _: Vec<u8>) -> BoxFut<'static, Vec<u8>> {
            panic!("answer_delta reached")
        }
        fn asked(&self, _: &str) {
            panic!("asked reached")
        }
        fn nearby_linked(&self, _: &str, _: &str, _: &str, _: &str) {
            panic!("nearby_linked reached")
        }
    }

    /// The node hands the app Handler any path it has no store for (such as the blob path); the Handler must answer a path it
    /// does not know with an error, which cache_rns sends to the asker as an `error: ...` reply.
    #[tokio::test]
    async fn unknown_path_is_refused() {
        let serving = Serving { serve: Arc::new(Unreached) };
        let linked = Asker::Linked(SecretKey::generate().public());
        for asker in [linked, Asker::Unlinked] {
            for path in [blobs::BLOB_PATH, "/no/such/path", ""] {
                let r = serving.request(asker, path, b"body".to_vec()).await;
                let e = r.expect_err(&format!("path {path:?} must be refused"));
                assert_eq!(e.to_string(), "unknown path");
            }
        }
    }

    /// A Serve that answers a linked device's `cache.entries` with a marker.
    struct Lists;

    impl Serve for Lists {
        fn pair_hello(&self, _: &str, _: &[u8]) -> Vec<u8> {
            panic!("pair_hello reached")
        }
        fn pair_short(self: Arc<Self>, _: Vec<u8>) -> BoxFut<'static, Vec<u8>> {
            panic!("pair_short reached")
        }
        fn answer(self: Arc<Self>, _: String, ask: Ask) -> BoxFut<'static, Vec<u8>> {
            assert_eq!(ask, Ask::Entries);
            Box::pin(async { b"the list".to_vec() })
        }
        fn answer_delta(self: Arc<Self>, _: String, _: Delta, _: Vec<u8>) -> BoxFut<'static, Vec<u8>> {
            panic!("answer_delta reached")
        }
        fn asked(&self, _: &str) {
            panic!("asking for the entry points is not asking for the file list: no round is woken")
        }
        fn nearby_linked(&self, _: &str, _: &str, _: &str, _: &str) {
            panic!("nearby_linked reached")
        }
    }

    /// `cache.entries` is answered to a linked device only: a device that is not linked is refused before the engine is asked
    /// anything (the list holds passphrases).
    #[tokio::test]
    async fn the_entry_points_are_answered_only_to_a_linked_device() {
        let unreached = Serving { serve: Arc::new(Unreached) };
        let e = unreached.request(Asker::Unlinked, PATH_ENTRIES, b"ask".to_vec()).await.expect_err("an unlinked device is refused");
        assert_eq!(e.to_string(), "not a linked device");
        let lists = Serving { serve: Arc::new(Lists) };
        let linked = Asker::Linked(SecretKey::generate().public());
        assert_eq!(lists.request(linked, PATH_ENTRIES, b"ask".to_vec()).await.unwrap(), b"the list");
    }
}
