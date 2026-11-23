//! Nearby linking over Reticulum (1.2, T4b): the transport half of [`crate::pair_core`].
//!
//! Everything here is standard Reticulum: an announce, a link, a request and Channel messages. Only DISCOVERY is local
//! (owner, 2026-11-22): a pairing destination is announced on local Wi-Fi/LAN interfaces only, never on a hub. After
//! discovery it is an ordinary link to that destination.
//!
//! - **The pool.** At node start the node registers [`POOL_SIZE`] random identities as destinations `cache.pair.v1`. They
//!   are never derived from the device key and their announces carry no app data. A page ([`Nearby::open`]) takes the next
//!   unused one and registers its two request paths; closing the page (or 15 minutes) unregisters them, and the member is
//!   never used again. Prns cannot register a destination once the node runs, so a used-up pool is rebuilt when the node
//!   next starts.
//! - **Listing.** Prns does not say which aspect an announce was for, so a `cache.pair.v1` announce cannot be told from
//!   any other announce. While our own page is open, an unknown destination heard on a local interface is asked
//!   `/cache/pair/name` over a short link; only one that answers is listed, with the name and kind it gave.
//! - **Linking.** The initiator opens a link to the other device's pairing destination, asks `/cache/pair/start`, and then
//!   [`crate::pair_core`] runs as Channel messages of type [`PAIR_TYPE`] on that link. Nothing is stored until both
//!   people have confirmed and the other side's signature over its permanent destination has checked out.
//! - **The pairing links never identify.** Our permanent Reticulum identity is sent only inside the exchange, after the
//!   commitment, as the design says.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use iroh::{PublicKey, SecretKey};
use personal_rns::interfaces::InterfaceStatus;
use personal_rns::prelude::*;
use personal_rns::routing::links::channel::MessageType;
use personal_rns::routing::links::LinkId;
use personal_rns::routing::request_handlers::{RequestPathHash, RequestPolicy};
use tokio::sync::mpsc;

/// A destination as a map key (Prns's type is not hashable).
type Key = [u8; 16];

fn key(d: &DestinationHash) -> Key {
    let mut k = [0u8; 16];
    k.copy_from_slice(d.as_bytes());
    k
}

use crate::pair_core::{self, Identity, Initiator, LinkState, PairError, PendingLink, RequestGuard, Responder};
use crate::{check_vouch_destination, dest_from_hex, dest_hex, vouch_destination, Handler};

/// The pairing destination's aspects, beside the app name `cache`: `cache.pair.v1`.
pub const PAIR_ASPECTS: &[&str] = &["pair", "v1"];
/// How many pairing addresses a node holds (each page uses one, and a member is never reused).
pub const POOL_SIZE: usize = 6;
/// Asked on a short link: answers `{name, kind}` while that destination's page is open.
pub const NAME_PATH: &str = "/cache/pair/name";
/// Asked on the pairing link before the exchange: answers `ok`, or `busy`.
pub const START_PATH: &str = "/cache/pair/start";
/// The Channel message type of the exchange (beside [`crate::NOTIFY_TYPE`]).
pub const PAIR_TYPE: MessageType = MessageType(0x0C02);

const PAGE_MS: u64 = 15 * 60 * 1000;
const ANNOUNCE_MS: u64 = 5_000;
const HEARD_TTL_MS: u64 = 20_000;
const TICK: Duration = Duration::from_millis(200);
const LINK_WAIT: Duration = Duration::from_secs(20);
const ASK_WAIT: Duration = Duration::from_secs(8);
/// Pairing announces heard from further than the next device are not listed (a transport node on the same Wi-Fi may
/// forward them, as standard RNS does).
const MAX_HOPS: u8 = 1;

/// This device's name and kind, as it tells a device that asks (the engine's, when a page opens or Link is tapped).
#[derive(Clone, Debug, Default)]
pub struct PairSelf {
    pub name: String,
    /// `phone`, `tablet` or `computer`; none when not set.
    pub kind: Option<String>,
}

/// A device heard nearby and asked for its name.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NearbyDevice {
    /// The pairing destination, 32 hex characters.
    pub id: String,
    pub name: Option<String>,
    pub kind: Option<String>,
}

/// Where a Nearby link stands (what the app shows).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PairStatus {
    /// `idle`, `incoming`, `exchanging`, `words`, `waiting`, `linked` or `dropped`.
    pub state: &'static str,
    pub name: Option<String>,
    pub kind: Option<String>,
    pub words: Option<[String; 3]>,
    /// `cancelled`, `timeout`, `mismatch` or `busy`, when dropped.
    pub reason: Option<&'static str>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Reason {
    Cancelled,
    Timeout,
    Mismatch,
    Busy,
}

impl Reason {
    fn word(self) -> &'static str {
        match self {
            Reason::Cancelled => "cancelled",
            Reason::Timeout => "timeout",
            Reason::Mismatch => "mismatch",
            Reason::Busy => "busy",
        }
    }
}

fn reason_of(e: &PairError) -> Reason {
    match e {
        PairError::Cancelled | PairError::Finished => Reason::Cancelled,
        PairError::Timeout => Reason::Timeout,
        _ => Reason::Mismatch,
    }
}

enum Last {
    Idle,
    Linked { name: String, kind: Option<String> },
    Dropped { reason: Reason, name: Option<String>, kind: Option<String> },
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Stage {
    /// Responder: the request is in, the exchange is running.
    Incoming,
    /// Initiator: connecting and exchanging.
    Exchanging,
    /// Both have the words.
    Words,
    /// This person confirmed; the other has not yet.
    Waiting,
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Role {
    Initiator,
    Responder,
}

enum Hs {
    /// Initiator before the other side said `ok` to the start request.
    Starting,
    Init(Initiator),
    Resp(Responder),
    Pending(PendingLink),
}

enum Out {
    Msg(Vec<u8>),
    /// After everything before it was delivered, close the link.
    Close,
}

struct Session {
    gen: u64,
    role: Role,
    stage: Stage,
    hs: Hs,
    link: Option<LinkId>,
    outbox: Option<mpsc::UnboundedSender<Out>>,
    name: Option<String>,
    kind: Option<String>,
}

struct Page {
    dest: DestinationHash,
    opened_ms: u64,
    next_announce_ms: u64,
}

struct Heard {
    last_ms: u64,
    named: Option<(Option<String>, Option<String>)>,
    asking: bool,
}

#[derive(Default)]
struct Backoff {
    failures: u32,
    next_ms: u64,
}

struct Inner {
    /// Index of the next pool member never used.
    next_free: usize,
    page: Option<Page>,
    me: PairSelf,
    heard: HashMap<Key, Heard>,
    backoff: HashMap<Key, Backoff>,
    session: Option<Session>,
    gen: u64,
    last: Last,
    guard: RequestGuard,
    announces_heard: HashMap<Key, u64>,
}

/// The Nearby state of one node.
pub struct Nearby {
    handle: PrnsNodeHandle,
    device: SecretKey,
    me: DestinationHash,
    handler: Arc<dyn Handler>,
    wifi: Option<personal_rns::wifi_auto::AutoWifiStatus>,
    /// For tests: TCP interfaces count as local (loopback tests have no Wi-Fi). Off in production.
    local_tcp: bool,
    pool: Vec<DestinationHash>,
    peers_dest: Arc<Mutex<Vec<DestinationHash>>>,
    base: Instant,
    skew: AtomicU64,
    inner: Mutex<Inner>,
}

impl Nearby {
    #[allow(clippy::too_many_arguments)]
    pub(crate) fn new(
        handle: PrnsNodeHandle,
        device: SecretKey,
        me: DestinationHash,
        handler: Arc<dyn Handler>,
        wifi: Option<personal_rns::wifi_auto::AutoWifiStatus>,
        local_tcp: bool,
        pool: Vec<DestinationHash>,
        peers_dest: Arc<Mutex<Vec<DestinationHash>>>,
    ) -> Arc<Nearby> {
        Arc::new(Nearby {
            handle,
            device,
            me,
            handler,
            wifi,
            local_tcp,
            pool,
            peers_dest,
            base: Instant::now(),
            skew: AtomicU64::new(0),
            inner: Mutex::new(Inner {
                next_free: 0,
                page: None,
                me: PairSelf::default(),
                heard: HashMap::new(),
                backoff: HashMap::new(),
                session: None,
                gen: 0,
                last: Last::Idle,
                guard: RequestGuard::new(),
                announces_heard: HashMap::new(),
            }),
        })
    }

    /// Milliseconds on this node's clock (real time plus whatever a test skewed it by).
    fn now(&self) -> u64 {
        self.base.elapsed().as_millis() as u64 + self.skew.load(Ordering::Relaxed)
    }

    /// Moves this node's clock forward (tests only: the 60 second and one minute waits).
    pub fn skew_clock(&self, ms: u64) {
        self.skew.fetch_add(ms, Ordering::Relaxed);
    }

    /// The pool's destinations (tests).
    pub fn pool(&self) -> Vec<DestinationHash> {
        self.pool.clone()
    }

    pub(crate) fn owns(&self, d: DestinationHash) -> bool {
        self.pool.contains(&d)
    }

    /// The destination being announced now, while a page is open.
    pub fn active(&self) -> Option<DestinationHash> {
        self.inner.lock().unwrap().page.as_ref().map(|p| p.dest)
    }

    /// How many announces for `dest` this node has heard (tests: an announce that stopped is not heard again).
    pub fn announces_heard(&self, dest: &DestinationHash) -> u64 {
        self.inner.lock().unwrap().announces_heard.get(&key(dest)).copied().unwrap_or(0)
    }

    fn own_identity(&self, me: &PairSelf) -> Identity {
        Identity {
            device_key: *self.device.public().as_bytes(),
            rns_dest: self.me.as_bytes().to_vec(),
            rns_sig: vouch_destination(&self.device, &self.me).to_vec(),
            name: me.name.clone(),
        }
    }

    // ---- the page ----

    /// The person opened "Show my link code": takes an unused pairing address and answers for it. Opening again while a page
    /// is open changes nothing.
    pub async fn open(self: &Arc<Self>, me: PairSelf) -> Result<()> {
        let dest = {
            let mut i = self.inner.lock().unwrap();
            i.me = me;
            if i.page.is_some() {
                return Ok(());
            }
            if i.next_free >= self.pool.len() {
                bail!("no pairing address is left on this run: restart Cache to link more devices nearby");
            }
            let m = i.next_free;
            i.next_free += 1;
            self.pool[m]
        };
        for p in [NAME_PATH, START_PATH] {
            self.handle
                .register_request_path(dest, p, RequestPolicy::AllowAll)
                .await
                .map_err(|e| anyhow!("cannot answer for the pairing address: {e:?}"))?;
        }
        let now = self.now();
        {
            let mut i = self.inner.lock().unwrap();
            i.page = Some(Page { dest, opened_ms: now, next_announce_ms: now });
            i.last = Last::Idle;
            i.heard.clear();
        }
        let this = self.clone();
        tokio::spawn(async move { this.announce(dest).await });
        Ok(())
    }

    /// The page closed: stop announcing, stop answering, drop anything in progress. The pairing address is never used again.
    pub async fn close(self: &Arc<Self>) {
        self.end_page(Some(Reason::Cancelled)).await;
    }

    /// Ends the page (and the session, if any, with `why`). `None` keeps the last result as it is.
    async fn end_page(self: &Arc<Self>, why: Option<Reason>) {
        let (page, out) = {
            let mut i = self.inner.lock().unwrap();
            let page = i.page.take();
            i.heard.clear();
            let mut out = None;
            if let Some(why) = why {
                if i.session.is_some() {
                    out = self.drop_locked(&mut i, why, true, false);
                } else if !matches!(i.last, Last::Linked { .. }) {
                    i.last = Last::Idle;
                }
            }
            (page, out)
        };
        if let Some(f) = out {
            f.run(&self.handle);
        }
        if let Some(p) = page {
            for path in [NAME_PATH, START_PATH] {
                let _ = self.handle.unregister_request_path(p.dest, path).await;
            }
        }
    }

    async fn announce(&self, dest: DestinationHash) {
        // Local interfaces only. A Wi-Fi auto interface is a fleet of peer lanes: Prns fans an interface-targeted
        // announce out to the one lane it names, so each member is named in turn.
        let targets: Vec<AnnounceTarget> = if self.local_tcp {
            vec![AnnounceTarget::AllInterfaces]
        } else if let Some(w) = &self.wifi {
            w.members()
                .iter()
                .map(|m| m.id())
                .filter(|id| matches!(id.kind(), Some(InterfaceKind::AutoWifi | InterfaceKind::WifiPeer)))
                .map(AnnounceTarget::Interface)
                .collect()
        } else {
            Vec::new()
        };
        for target in targets {
            let _ = self
                .handle
                .announce_now(AnnounceNow { destination: dest, target, app_data: AnnounceAppData::Data(Default::default()) })
                .await;
        }
    }

    /// Announces the pool member at `index` although no page is open (tests: a node that never opened its page must still
    /// say nothing when asked).
    pub async fn announce_unopened(&self, index: usize) {
        if let Some(d) = self.pool.get(index) {
            self.announce(*d).await;
        }
    }

    // ---- hearing ----

    pub(crate) fn on_announce(&self, dest: DestinationHash, local: bool, hops: u8) {
        if dest == self.me || self.pool.contains(&dest) {
            return;
        }
        let mut i = self.inner.lock().unwrap();
        if i.announces_heard.len() < 512 || i.announces_heard.contains_key(&key(&dest)) {
            *i.announces_heard.entry(key(&dest)).or_default() += 1;
        }
        let local = local || self.local_tcp;
        if !local || hops > MAX_HOPS || i.page.is_none() || self.peers_dest.lock().unwrap().contains(&dest) {
            return;
        }
        let now = self.now();
        i.heard.entry(key(&dest)).or_insert(Heard { last_ms: now, named: None, asking: false }).last_ms = now;
    }

    /// The devices heard nearby that answered for their name, while our own page is open.
    pub fn list(&self) -> Vec<NearbyDevice> {
        let i = self.inner.lock().unwrap();
        if i.page.is_none() {
            return Vec::new();
        }
        let mut v: Vec<NearbyDevice> = i
            .heard
            .iter()
            .filter_map(|(d, h)| {
                let (name, kind) = h.named.clone()?;
                Some(NearbyDevice { id: dest_hex(&DestinationHash::new(*d)), name, kind })
            })
            .collect();
        v.sort_by(|a, b| a.id.cmp(&b.id));
        v
    }

    /// A short link to a pairing destination and one request on it. Nothing identifies us on it.
    pub async fn ask(&self, dest: DestinationHash, path: &str, body: &[u8], timeout: Duration) -> Result<Vec<u8>> {
        let link = tokio::time::timeout(LINK_WAIT, self.handle.establish_link(dest))
            .await
            .map_err(|_| anyhow!("not reachable"))?
            .map_err(|e| anyhow!("not reachable: {e:?}"))?;
        let r = tokio::time::timeout(
            timeout + Duration::from_secs(1),
            self.handle.request_with_response_timeout(link, RequestPathHash::of(path), body, exact(timeout)),
        )
        .await;
        let _ = self.handle.close_link(link);
        match r {
            Ok(Ok((reply, _))) => crate::unpack_bin(reply),
            Ok(Err(e)) => Err(anyhow!("the request failed: {e:?}")),
            Err(_) => Err(anyhow!("timed out")),
        }
    }

    async fn ask_name(self: Arc<Self>, dest: DestinationHash) {
        let r = self.ask(dest, NAME_PATH, b"", ASK_WAIT).await.ok().and_then(|b| serde_json::from_slice::<serde_json::Value>(&b).ok());
        let now = self.now();
        let mut i = self.inner.lock().unwrap();
        match r {
            Some(v) if v.get("name").is_some() || v.get("kind").is_some() => {
                let text = |k: &str| v.get(k).and_then(|x| x.as_str()).filter(|s| !s.is_empty()).map(|s| s.to_string());
                let named = (text("name"), text("kind"));
                if let Some(h) = i.heard.get_mut(&key(&dest)) {
                    h.named = Some(named);
                    h.asking = false;
                }
                i.backoff.remove(&key(&dest));
            }
            _ => {
                if let Some(h) = i.heard.get_mut(&key(&dest)) {
                    h.asking = false;
                }
                // Not a pairing address (or its page is shut): ask again later, less and less often.
                let b = i.backoff.entry(key(&dest)).or_default();
                b.failures += 1;
                b.next_ms = now + (5_000u64 << b.failures.min(6)).min(300_000);
            }
        }
    }

    // ---- the tick ----

    pub(crate) fn start_tick(self: &Arc<Self>) -> tokio::task::JoinHandle<()> {
        let this = self.clone();
        tokio::spawn(async move {
            let mut tick = tokio::time::interval(TICK);
            loop {
                tick.tick().await;
                this.tick().await;
            }
        })
    }

    async fn tick(self: &Arc<Self>) {
        let now = self.now();
        let mut expire_page = false;
        let mut announce = None;
        let mut asks = Vec::new();
        let mut out = None;
        {
            let mut i = self.inner.lock().unwrap();
            if let Some(p) = &mut i.page {
                if now.saturating_sub(p.opened_ms) >= PAGE_MS {
                    expire_page = true;
                } else if now >= p.next_announce_ms {
                    p.next_announce_ms = now + ANNOUNCE_MS;
                    announce = Some(p.dest);
                }
            }
            // The exchange's own clocks (the handshake and the 60 seconds to answer).
            let timed_out = match i.session.as_mut().map(|s| &mut s.hs) {
                Some(Hs::Init(h)) => h.expired(now),
                Some(Hs::Resp(h)) => h.expired(now),
                Some(Hs::Pending(p)) => matches!(p.poll(now), LinkState::Dropped(PairError::Timeout)),
                _ => false,
            };
            if timed_out {
                out = self.drop_locked(&mut i, Reason::Timeout, true, true);
            }
            i.heard.retain(|_, h| now.saturating_sub(h.last_ms) < HEARD_TTL_MS);
            i.backoff.retain(|_, b| now < b.next_ms + 600_000);
            let backoff: HashMap<Key, u64> = i.backoff.iter().map(|(d, b)| (*d, b.next_ms)).collect();
            for (d, h) in i.heard.iter_mut() {
                if h.named.is_none() && !h.asking && backoff.get(d).is_none_or(|n| now >= *n) {
                    h.asking = true;
                    asks.push(DestinationHash::new(*d));
                }
            }
        }
        if let Some(f) = out {
            f.run(&self.handle);
        }
        if expire_page {
            self.end_page(Some(Reason::Cancelled)).await;
            return;
        }
        if let Some(d) = announce {
            self.announce(d).await;
        }
        for d in asks {
            tokio::spawn(self.clone().ask_name(d));
        }
    }

    // ---- requests to a pairing destination ----

    pub(crate) fn on_request(self: &Arc<Self>, token: RespondToken, destination: DestinationHash, path: RequestPathHash, data: Vec<u8>) {
        let now = self.now();
        let mut i = self.inner.lock().unwrap();
        // Only while the page for this very destination is open: nothing otherwise (the paths are not registered either).
        let Some(page) = &i.page else { return };
        if page.dest != destination {
            return;
        }
        if path == RequestPathHash::of(NAME_PATH) {
            let reply = serde_json::json!({"name": i.me.name, "kind": i.me.kind});
            let _ = self.handle.respond_bytes(token, reply.to_string().as_bytes());
            return;
        }
        if path != RequestPathHash::of(START_PATH) {
            return;
        }
        // Three refused or unanswered requests: new ones are turned away for a minute, and say so.
        if !i.guard.allow(now) || i.session.is_some() {
            let _ = self.handle.respond_bytes(token, b"busy");
            return;
        }
        let kind = serde_json::from_slice::<serde_json::Value>(&data)
            .ok()
            .and_then(|v| v.get("kind").and_then(|k| k.as_str().map(|s| s.to_string())))
            .filter(|k| matches!(k.as_str(), "phone" | "tablet" | "computer"));
        i.gen += 1;
        let gen = i.gen;
        let own = self.own_identity(&i.me);
        i.session = Some(Session {
            gen,
            role: Role::Responder,
            stage: Stage::Incoming,
            hs: Hs::Resp(Responder::new(own, now)),
            link: Some(token.link_id),
            outbox: Some(self.spawn_outbox(token.link_id)),
            name: None,
            kind,
        });
        let _ = self.handle.respond_bytes(token, b"ok");
    }

    pub(crate) fn on_link_closed(self: &Arc<Self>, link: LinkId) {
        let out = {
            let mut i = self.inner.lock().unwrap();
            if i.session.as_ref().and_then(|s| s.link) == Some(link) {
                // The other end went away: nothing is kept.
                self.drop_locked(&mut i, Reason::Cancelled, false, false)
            } else {
                None
            }
        };
        if let Some(f) = out {
            f.run(&self.handle);
        }
    }

    // ---- the exchange ----

    /// Messages out, in order, each one delivered before the next; then (if asked) the link closes.
    fn spawn_outbox(&self, link: LinkId) -> mpsc::UnboundedSender<Out> {
        let (tx, mut rx) = mpsc::unbounded_channel::<Out>();
        let handle = self.handle.clone();
        tokio::spawn(async move {
            while let Some(o) = rx.recv().await {
                match o {
                    Out::Msg(bytes) => {
                        let _ = handle.send_channel_message(link, PAIR_TYPE, &bytes).await;
                    }
                    Out::Close => {
                        handle.close_link(link);
                        break;
                    }
                }
            }
        });
        tx
    }

    /// Ends the session as dropped, with nothing kept. Returns what is left to do outside the lock.
    fn drop_locked(&self, i: &mut Inner, why: Reason, tell_other: bool, strike: bool) -> Option<After> {
        let s = i.session.take()?;
        let now = self.now();
        if s.role == Role::Responder && strike {
            // A refused (cancelled, mismatched) or unanswered (timed out) incoming request.
            i.guard.record_strike(now);
        }
        let name = match &s.hs {
            Hs::Pending(p) => Some(p.peer().name.clone()),
            _ => s.name.clone(),
        };
        i.last = Last::Dropped { reason: why, name, kind: s.kind.clone() };
        if let Some(tx) = &s.outbox {
            if tell_other {
                let _ = tx.send(Out::Msg(pair_core::Message::Cancel.encode()));
            }
            let _ = tx.send(Out::Close);
            None
        } else {
            s.link.map(After::Close)
        }
    }

    /// A pairing message came in on `link`.
    pub(crate) fn on_message(self: &Arc<Self>, link: LinkId, data: &[u8]) {
        let now = self.now();
        let mut finish = false;
        let out = {
            let mut i = self.inner.lock().unwrap();
            let Some(s) = i.session.as_mut() else { return };
            if s.link != Some(link) {
                return;
            }
            let hs = std::mem::replace(&mut s.hs, Hs::Starting);
            let mut err: Option<PairError> = None;
            match hs {
                Hs::Init(mut h) => match h.on_message(data, now) {
                    Ok(step) => {
                        if let (Some(r), Some(tx)) = (step.reply, &s.outbox) {
                            let _ = tx.send(Out::Msg(r));
                        }
                        match step.pending {
                            Some(p) => {
                                s.name = Some(p.peer().name.clone());
                                s.stage = Stage::Words;
                                s.hs = Hs::Pending(p);
                            }
                            None => s.hs = Hs::Init(h),
                        }
                    }
                    Err(e) => err = Some(e),
                },
                Hs::Resp(mut h) => match h.on_message(data, now) {
                    Ok(step) => {
                        if let (Some(r), Some(tx)) = (step.reply, &s.outbox) {
                            let _ = tx.send(Out::Msg(r));
                        }
                        match step.pending {
                            Some(p) => {
                                s.name = Some(p.peer().name.clone());
                                s.stage = Stage::Words;
                                s.hs = Hs::Pending(p);
                            }
                            None => s.hs = Hs::Resp(h),
                        }
                    }
                    Err(e) => err = Some(e),
                },
                Hs::Pending(mut p) => match p.on_message(data, now) {
                    Ok(LinkState::Confirmed) => {
                        s.hs = Hs::Pending(p);
                        finish = true;
                    }
                    Ok(_) => s.hs = Hs::Pending(p),
                    Err(e) => err = Some(e),
                },
                Hs::Starting => {
                    s.hs = Hs::Starting;
                }
            }
            match err {
                Some(e) => {
                    // The other side cancelled, or sent something that does not belong: nothing is kept.
                    let tell = !matches!(e, PairError::Cancelled);
                    self.drop_locked(&mut i, reason_of(&e), tell, true)
                }
                None => None,
            }
        };
        if let Some(f) = out {
            f.run(&self.handle);
        }
        if finish {
            self.finish();
        }
    }

    /// Both people confirmed: check the other side's signature over its permanent destination, then hand it over to be kept.
    fn finish(self: &Arc<Self>) {
        let peer = {
            let mut i = self.inner.lock().unwrap();
            let Some(s) = i.session.take() else { return };
            let kind = s.kind.clone();
            let Hs::Pending(p) = s.hs else { return };
            let confirmed = match p.into_confirmed() {
                Ok(c) => c,
                Err(_) => return,
            };
            let peer = &confirmed.peer;
            let key = PublicKey::from_bytes(&peer.device_key).ok();
            let dest = <[u8; 16]>::try_from(peer.rns_dest.as_slice()).ok().map(DestinationHash::new);
            let good = match (key, dest) {
                (Some(k), Some(d)) => k != self.device.public() && check_vouch_destination(&k, &d, &peer.rns_sig),
                _ => false,
            };
            let tx = s.outbox.clone();
            match (good, key, dest) {
                (true, Some(k), Some(d)) => {
                    i.guard.record_success();
                    i.last = Last::Linked { name: peer.name.clone(), kind };
                    if let Some(tx) = &tx {
                        let _ = tx.send(Out::Close);
                    } else if let Some(l) = s.link {
                        self.handle.close_link(l);
                    }
                    Some((k, peer.name.clone(), d, peer.rns_sig.clone()))
                }
                _ => {
                    i.last = Last::Dropped { reason: Reason::Mismatch, name: Some(peer.name.clone()), kind };
                    if let Some(tx) = &tx {
                        let _ = tx.send(Out::Msg(pair_core::Message::Cancel.encode()));
                        let _ = tx.send(Out::Close);
                    }
                    None
                }
            }
        };
        if let Some((key, name, dest, sig)) = peer {
            self.handler.pair_linked(key, name, dest, sig);
            // The pairing address is used up: stop announcing it and answering for it.
            let this = self.clone();
            tokio::spawn(async move { this.end_page(None).await });
        }
    }

    /// The person tapped Link (`ok`) or Cancel on the words.
    pub async fn answer(self: &Arc<Self>, ok: bool) -> Result<()> {
        let now = self.now();
        let mut finish = false;
        let out = {
            let mut i = self.inner.lock().unwrap();
            let Some(s) = i.session.as_mut() else { bail!("there is nothing to answer") };
            match (&mut s.hs, ok) {
                (Hs::Pending(p), true) => {
                    if s.stage == Stage::Waiting {
                        return Ok(());
                    }
                    match p.confirm(now) {
                        Ok(bytes) => {
                            if let Some(tx) = &s.outbox {
                                let _ = tx.send(Out::Msg(bytes));
                            }
                            s.stage = Stage::Waiting;
                            finish = matches!(p.poll(now), LinkState::Confirmed);
                            None
                        }
                        Err(e) => self.drop_locked(&mut i, reason_of(&e), true, false),
                    }
                }
                (_, true) => bail!("the words are not ready yet"),
                (_, false) => {
                    // A refusal: the other side is told, and nothing is kept.
                    self.drop_locked(&mut i, Reason::Cancelled, true, true)
                }
            }
        };
        if let Some(f) = out {
            f.run(&self.handle);
        }
        if finish {
            self.finish();
        }
        Ok(())
    }

    /// The person tapped Link on a device in the list: open the link and run the exchange as the initiator.
    pub async fn link(self: &Arc<Self>, id: &str, me: PairSelf) -> Result<()> {
        let dest = dest_from_hex(id).ok_or_else(|| anyhow!("that is not a nearby device"))?;
        let (gen, name, kind) = {
            let mut i = self.inner.lock().unwrap();
            if i.page.is_none() {
                bail!("open the link code page first");
            }
            if i.session.is_some() {
                bail!("a link is already in progress");
            }
            let named = i.heard.get(&key(&dest)).and_then(|h| h.named.clone());
            i.me = me.clone();
            i.gen += 1;
            let gen = i.gen;
            let (name, kind) = named.unwrap_or((None, None));
            i.last = Last::Idle;
            i.session = Some(Session {
                gen,
                role: Role::Initiator,
                stage: Stage::Exchanging,
                hs: Hs::Starting,
                link: None,
                outbox: None,
                name: name.clone(),
                kind: kind.clone(),
            });
            (gen, name, kind)
        };
        let _ = (name, kind);
        let this = self.clone();
        tokio::spawn(async move { this.run_initiator(gen, dest, me).await });
        Ok(())
    }

    async fn run_initiator(self: Arc<Self>, gen: u64, dest: DestinationHash, me: PairSelf) {
        let current = |this: &Nearby| this.inner.lock().unwrap().session.as_ref().is_some_and(|s| s.gen == gen);
        let fail = |this: &Arc<Nearby>, why: Reason| {
            let out = {
                let mut i = this.inner.lock().unwrap();
                if i.session.as_ref().is_some_and(|s| s.gen == gen) {
                    this.drop_locked(&mut i, why, false, false)
                } else {
                    None
                }
            };
            if let Some(f) = out {
                f.run(&this.handle);
            }
        };
        let link = match tokio::time::timeout(LINK_WAIT, self.handle.establish_link(dest)).await {
            Ok(Ok(l)) => l,
            _ => return fail(&self, Reason::Timeout),
        };
        {
            let mut i = self.inner.lock().unwrap();
            match i.session.as_mut() {
                Some(s) if s.gen == gen => {
                    s.link = Some(link);
                    s.outbox = Some(self.spawn_outbox(link));
                }
                _ => {
                    self.handle.close_link(link);
                    return;
                }
            }
        }
        let body = serde_json::json!({"kind": me.kind}).to_string();
        let r = tokio::time::timeout(
            ASK_WAIT + Duration::from_secs(1),
            self.handle.request_with_response_timeout(link, RequestPathHash::of(START_PATH), body.as_bytes(), exact(ASK_WAIT)),
        )
        .await;
        if !current(&self) {
            return;
        }
        let reply = match r {
            Ok(Ok((reply, _))) => crate::unpack_bin(reply).ok(),
            _ => None,
        };
        match reply.as_deref() {
            Some(b"ok") => {}
            Some(b"busy") => return fail(&self, Reason::Busy),
            _ => return fail(&self, Reason::Timeout),
        }
        let now = self.now();
        let mut i = self.inner.lock().unwrap();
        let own = self.own_identity(&me);
        if let Some(s) = i.session.as_mut().filter(|s| s.gen == gen) {
            let (init, commit) = Initiator::start(own, now);
            s.hs = Hs::Init(init);
            if let Some(tx) = &s.outbox {
                let _ = tx.send(Out::Msg(commit));
            }
        }
    }

    /// Where the Nearby link stands.
    pub fn status(&self) -> PairStatus {
        let i = self.inner.lock().unwrap();
        let Some(s) = i.session.as_ref() else {
            return match &i.last {
                Last::Idle => PairStatus { state: "idle", name: None, kind: None, words: None, reason: None },
                Last::Linked { name, kind } => PairStatus { state: "linked", name: Some(name.clone()), kind: kind.clone(), words: None, reason: None },
                Last::Dropped { reason, name, kind } => {
                    PairStatus { state: "dropped", name: name.clone(), kind: kind.clone(), words: None, reason: Some(reason.word()) }
                }
            };
        };
        let state = match (s.role, s.stage) {
            (Role::Responder, Stage::Incoming) => "incoming",
            (_, Stage::Incoming | Stage::Exchanging) => "exchanging",
            (_, Stage::Words) => "words",
            (_, Stage::Waiting) => "waiting",
        };
        let words = match &s.hs {
            Hs::Pending(p) => Some(p.words().map(|w| w.to_string())),
            _ => None,
        };
        PairStatus { state, name: s.name.clone(), kind: s.kind.clone(), words, reason: None }
    }
}

/// What a session's end leaves to do once the lock is released.
enum After {
    Close(LinkId),
}

impl After {
    fn run(self, handle: &PrnsNodeHandle) {
        match self {
            After::Close(l) => {
                handle.close_link(l);
            }
        }
    }
}

fn exact(t: Duration) -> personal_rns::engine::RequestResponseTimeout {
    personal_rns::engine::RequestResponseTimeout::Exact(personal_rns::units::DurationMillis(t.as_millis() as u64))
}
