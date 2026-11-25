//! Reticulum for Cache (1.2 spike, not shipped): one Reticulum node per device, on Prns.
//!
//! - **Identity.** A device's Reticulum identity is derived from its iroh secret key, so there is nothing new to keep or back
//!   up, and reinstalling with the same key gives the same Reticulum address.
//! - **Empty announces.** A device's announce carries no app data: no name and no signature (owner, 2026-11-22). Each linked
//!   device is stored with its Reticulum destination; hearing an announce only marks that destination reachable, and on what.
//! - **The hello.** The device key's signature moved from the announce into the first message inside a link: right after it
//!   identifies, the opener sends `/cache/hello` with its device key and a signature over its Reticulum identity. Nothing
//!   else is answered on a link until a hello from a linked device has checked out.
//! - **Requests.** Cache's requests (pairing, the index, secrets) are Reticulum link requests on paths the caller names.
//!   A request is answered only on a hello-verified link, except on the paths the caller marks as open (pairing).
//! - **Notify.** "Something changed" goes over the link's Channel, which is acknowledged and ordered. Raw link packets are
//!   never used: they are not proven by the side that opened a link and are not retried (trial R1).

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use iroh::{PublicKey, SecretKey, Signature};
use personal_rns::engine::LinkClosedReason;
use personal_rns::interfaces::{ConnectionState, IfacContext, IfacSize, InterfaceId};
use personal_rns::identity::IdentityHash;
use personal_rns::prelude::*;
/// The wiping string an [`EntryPoint`]'s passphrase is held in.
pub use personal_rns::prelude::Zeroizing;
use personal_rns::wifi_auto::AutoWifiStatus;
use personal_rns::routing::links::channel::MessageType;
use personal_rns::routing::links::LinkId;
use personal_rns::routing::request_handlers::{RequestPathHash, RequestPolicy};
use tokio::sync::mpsc;

pub use personal_rns::prelude::DestinationHash;

pub mod blobs;
#[cfg(feature = "rnode")]
pub mod rnode;
#[cfg(feature = "rnode")]
pub mod standin;
pub mod pair_core;
pub mod nearby;
pub use nearby::{NearbyDevice, PairSelf, PairStatus};

/// Cache's Reticulum destination name: `cache.sync.v1`.
pub const APP_NAME: &str = "cache";
pub const ASPECTS: &[&str] = &["sync", "v1"];
/// The Channel message type for notifications (below 0xf000, which RNS reserves).
pub const NOTIFY_TYPE: MessageType = MessageType(0x0C01);

const IDENTITY_CONTEXT: &str =
    "cache_rns 2026-11-14 reticulum identity from the iroh device key v1";
const VOUCH_PREFIX: &[u8] = b"cache_rns vouch v2: hello on a link, signed over the Reticulum identity";
/// The always-open path for the first message on a link ([`hello`]).
pub const HELLO_PATH: &str = "/cache/hello";

/// What a device answers to the hello of a device it used to be linked with and is not linked with now.
pub const NOT_LINKED: &[u8] = b"not linked";

/// The text of the error a request fails with when the hello was answered [`NOT_LINKED`]: the caller looks for it
/// (see [`is_not_linked`]).
const NOT_LINKED_ERROR: &str = "the other device says this device is not linked";

/// Whether `e` is the failure of a hello the other device answered "not linked".
pub fn is_not_linked(e: &anyhow::Error) -> bool {
    e.chain().any(|c| c.to_string() == NOT_LINKED_ERROR)
}
const ANNOUNCE_EVERY: Duration = Duration::from_secs(30);
const PATH_EVERY: Duration = Duration::from_secs(5);
/// While connected, an entry point is announced on once every this long (and once when it connects), so a path survives an rnsd restart.
pub const ENTRY_ANNOUNCE_EVERY: Duration = Duration::from_secs(6 * 60 * 60);
/// An entry point that is not connected for this long is [`EntryState::NotAnswering`].
pub const NOT_ANSWERING_AFTER: Duration = Duration::from_secs(20);
/// An entry point connected this long with bytes arriving but no valid frame is [`EntryState::Mismatch`].
pub const MISMATCH_AFTER: Duration = Duration::from_secs(30);
/// How often entry points are looked at.
const ENTRY_POLL: Duration = Duration::from_secs(1);
/// A linked device whose announce is heard again after this long without one (three of its announces missed) is reachable again.
pub const REACHABLE_GAP: Duration = Duration::from_secs(95);

/// The 64-byte Reticulum identity secret (X25519 then Ed25519, RNS's layout) for a device's iroh key.
pub fn identity_secret_for(device: &SecretKey) -> [u8; 64] {
    let mut out = [0u8; 64];
    blake3::Hasher::new_derive_key(IDENTITY_CONTEXT)
        .update(&device.to_bytes())
        .finalize_xof()
        .fill(&mut out);
    out
}

fn vouch_message(identity: &IdentityHash) -> Vec<u8> {
    let mut m = VOUCH_PREFIX.to_vec();
    m.extend_from_slice(identity.as_bytes());
    m
}

/// The device key's signature over the Reticulum identity a link proved (the hello's proof).
pub fn vouch(device: &SecretKey, identity: &IdentityHash) -> [u8; 64] {
    device.sign(&vouch_message(identity)).to_bytes()
}

/// Whether `sig` is `peer`'s vouch for `identity`.
pub fn check_vouch(peer: &PublicKey, identity: &IdentityHash, sig: &[u8]) -> bool {
    let Ok(bytes) = <[u8; 64]>::try_from(sig) else {
        return false;
    };
    peer.verify(&vouch_message(identity), &Signature::from_bytes(&bytes))
        .is_ok()
}

const DEST_VOUCH_PREFIX: &[u8] = b"cache_rns vouch v2: link, signed over the Reticulum destination";

fn dest_vouch_message(destination: &DestinationHash) -> Vec<u8> {
    let mut m = DEST_VOUCH_PREFIX.to_vec();
    m.extend_from_slice(destination.as_bytes());
    m
}

/// The device key's signature over its Reticulum destination: what a link code, a pairing and an index carry, so a device
/// that knows only the destination (not the secret behind it) can check that the destination is the device's own. A
/// destination is a hash of the identity, so this binds the device key to the identity the same way [`vouch`] does.
pub fn vouch_destination(device: &SecretKey, destination: &DestinationHash) -> [u8; 64] {
    device.sign(&dest_vouch_message(destination)).to_bytes()
}

/// Whether `sig` is `peer`'s vouch for `destination` ([`vouch_destination`]).
pub fn check_vouch_destination(peer: &PublicKey, destination: &DestinationHash, sig: &[u8]) -> bool {
    let Ok(bytes) = <[u8; 64]>::try_from(sig) else {
        return false;
    };
    peer.verify(&dest_vouch_message(destination), &Signature::from_bytes(&bytes))
        .is_ok()
}

/// A destination as 32 lowercase hex characters (what sync.json and link codes hold).
pub fn dest_hex(d: &DestinationHash) -> String {
    d.as_bytes().iter().map(|b| format!("{b:02x}")).collect()
}

/// The destination of 32 hex characters (either case), if it is one.
pub fn dest_from_hex(s: &str) -> Option<DestinationHash> {
    if s.len() != 32 || !s.is_ascii() {
        return None;
    }
    let mut out = [0u8; 16];
    for (i, b) in out.iter_mut().enumerate() {
        *b = u8::from_str_radix(&s[2 * i..2 * i + 2], 16).ok()?;
    }
    Some(DestinationHash::new(out))
}

/// The hello body: the device's public key then its vouch (32 + 64 bytes).
fn hello_body(device: &SecretKey, identity: &IdentityHash) -> Vec<u8> {
    let mut b = device.public().as_bytes().to_vec();
    b.extend_from_slice(&vouch(device, identity));
    b
}

fn parse_hello(body: &[u8]) -> Option<(PublicKey, [u8; 64])> {
    if body.len() != 96 {
        return None;
    }
    let key = PublicKey::from_bytes(<&[u8; 32]>::try_from(&body[..32]).ok()?).ok()?;
    let sig = <[u8; 64]>::try_from(&body[32..]).ok()?;
    Some((key, sig))
}

/// The Reticulum identity hash of a device (derived from its iroh key).
pub fn identity_hash_for(device: &SecretKey) -> IdentityHash {
    personal_rns::identity::PrivateIdentityMaterial::from_bytes(identity_secret_for(device))
        .identity_hash()
}

/// The Reticulum destination of a device (what its linked devices store, and what a link code carries).
pub fn destination_for(device: &SecretKey) -> Result<DestinationHash> {
    let d = PreConfiguredDestination::Single {
        resource_strategy: ResourceStrategy::AcceptNone,
        maximum_request_bytes: Default::default(),
        app_name: APP_NAME,
        aspects: ASPECTS,
        identity: Zeroizing::new(identity_secret_for(device)),
        announce_app_data: b"",
        proof: ProofStrategy::ProveAll,
        link_requests: LinkRequestPolicy::AcceptAll,
        ratchet: RatchetPolicy::NoRatchets,
        request_endpoints: ServeMyRequestEndpoints::No,
    };
    d.destination_hash()
        .map_err(|e| anyhow!("bad destination name: {e:?}"))
}

/// How a heard announce reached us.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Via {
    /// Over Wi-Fi/LAN discovery (auto Wi-Fi, or one of its peers).
    Wifi,
    /// Through the entry point (an rnsd the person entered) with this id ([`EntryPoint::id`]).
    Entry(String),
    /// Over anything else (TCP, hubs, radio).
    Other,
}

/// An entry point: an rnsd the person entered (an address and port, and for a private one its IFAC network name and passphrase).
/// Cache connects to it as a TCP client, never relays for others (transport stays off), and announces on it only when it connects.
#[derive(Clone)]
pub struct EntryPoint {
    /// The entry's own id (16 random bytes in hex, made by whoever stores the list); the key every change is matched by.
    pub id: String,
    pub host: String,
    pub port: u16,
    /// The IFAC network name. `None` or empty is no name.
    pub network_name: Option<String>,
    /// The IFAC passphrase. `None` or empty is no passphrase. Wiped when dropped.
    pub passphrase: Option<Zeroizing<String>>,
    /// Switched on. Off keeps the settings but is not connected.
    pub on: bool,
}

impl std::fmt::Debug for EntryPoint {
    // Never the passphrase (this is what a log line or a failed assert would print).
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("EntryPoint")
            .field("id", &self.id)
            .field("host", &self.host)
            .field("port", &self.port)
            .field("network_name", &self.network_name)
            .field("has_passphrase", &self.passphrase.as_ref().is_some_and(|p| !p.is_empty()))
            .field("on", &self.on)
            .finish()
    }
}

/// Where an entry point stands ([`RnsNode::entry_status`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EntryState {
    /// Switched off (the settings are kept).
    Off,
    /// Not connected yet, or lost for less than [`NOT_ANSWERING_AFTER`].
    Connecting,
    /// Connected and at least one valid frame has arrived on it.
    Connected,
    /// Reconnecting, failed or disconnected for more than [`NOT_ANSWERING_AFTER`].
    NotAnswering,
    /// Inferred, not read: connected, bytes arrive, but none has been a valid frame for [`MISMATCH_AFTER`]. The network name or
    /// passphrase most likely does not match (Prns drops a frame that fails IFAC without a counter or event; see the plan, decision 2).
    Mismatch,
    /// Connected, but nothing at all has been heard yet: a quiet rnsd, or one that answers a wrong passphrase with silence.
    /// Cache cannot tell which.
    NothingHeard,
}

/// One network attachment.
#[derive(Debug, Clone)]
pub enum Iface {
    /// Accept TCP connections on this address (a hub, or a fixed-address peer).
    TcpListen(String),
    /// Connect to a TCP listener at this address.
    TcpConnect(String),
    /// Wi-Fi/LAN auto-discovery (Prns's `AutoWifi`): finds other devices on the local network with no address typed.
    /// Which discovery group it uses is [`Config::wifi_group`].
    WifiAuto,
    /// An entry point the person entered (an rnsd). Attached at start like any other; the list can change later with
    /// [`RnsNode::set_entry_points`], which never restarts the node.
    Entry(EntryPoint),
    #[cfg(feature = "rnode")]
    /// An RNode (LoRa), by a name for the interface, where it is, and its radio settings ([`rnode`]).
    RNode { name: String, port: rnode::RNodePort, radio: rnode::Radio },
}

/// Who is asking.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Asker {
    /// A linked device, proven by its identity on the link.
    Linked(PublicKey),
    /// Not a linked device (only seen on open paths).
    Unlinked,
}

pub type BoxFut<T> = Pin<Box<dyn Future<Output = T> + Send>>;

/// The caller's side: answers requests and takes notifications.
pub trait Handler: Send + Sync + 'static {
    fn request(&self, asker: Asker, path: &str, body: Vec<u8>) -> BoxFut<Result<Vec<u8>>>;
    fn notify(&self, from: PublicKey, body: Vec<u8>);
    /// A linked device is reachable again: its announce was heard after a stretch with none (more than [`REACHABLE_GAP`]), after a
    /// link to it closed or a request to it failed, or for the first time. Called from the node's event task: do not block.
    fn reachable(&self, _peer: PublicKey) {}
    /// A link to or from a linked device closed: why (`reason`), how long it had been open, and the round trip time measured
    /// when it opened (when known). Called from the node's event task: do not block. Prns's event carries nothing more.
    fn link_closed(&self, _peer: PublicKey, _reason: &str, _open_secs: Option<u64>, _rtt_ms: Option<u64>) {}
    /// Whether the file store may be served yet (false while it is being moved to a new format). While false, a window request
    /// is answered "not ready" (a temporary failure for the asker), never "missing". Called per request; do not block.
    fn blobs_ready(&self) -> bool {
        true
    }
    /// A linked device asked for a window of a blob: the blob's hash and the byte just past the last one the window covers. Called
    /// when the request arrives and again when the answer has been made; do not block.
    fn served(&self, _peer: PublicKey, _hash: cache_store::Hash, _end: u64) {}
    /// Both people confirmed a Nearby link and the other device's signature over its destination checked out: keep it
    /// (device key, name, Reticulum destination, and the device key's signature over it).
    fn pair_linked(&self, _peer: PublicKey, _name: String, _destination: DestinationHash, _sig: Vec<u8>) {}
}

pub struct Config {
    pub device: SecretKey,
    pub interfaces: Vec<Iface>,
    /// Linked devices, each with its Reticulum destination when known (given when linking, over iroh or by the link code).
    pub peers: Vec<(PublicKey, Option<DestinationHash>)>,
    /// The Wi-Fi auto discovery group: `None` is Prns's default group.
    pub wifi_group: Option<Vec<u8>>,
    /// Paths this device answers.
    pub paths: Vec<String>,
    /// Of those, the ones an unlinked device may ask (pairing).
    pub open_paths: Vec<String>,
    /// The largest request or response, in bytes.
    pub max_bytes: u64,
    /// Cache's blob store: when set, linked devices may fetch verified windows of its blobs ([`blobs`]).
    pub blobs: Option<cache_store::Store>,
    /// For tests only, off in production: pairing announces are only ever sent on, and listed from, local Wi-Fi/LAN
    /// interfaces; with this on, TCP interfaces count as local so a loopback test can run.
    pub pair_local_tcp: bool,
}

#[derive(Default)]
struct State {
    peers: HashSet<[u8; 32]>,
    /// Devices that used to be linked and are not now: their signed hello is answered "not linked".
    former: HashSet<[u8; 32]>,
    /// Linked device -> its stored destination.
    destination_of: HashMap<[u8; 32], DestinationHash>,
    /// Linked devices whose announce has been heard, and how.
    heard: HashMap<[u8; 32], Via>,
    /// Link -> the identity the other end proved on it.
    identity_on_link: HashMap<LinkId, IdentityHash>,
    /// Link -> the linked device whose hello checked out on it, and the identity that hello was for.
    verified: HashMap<LinkId, ([u8; 32], IdentityHash)>,
    /// Our open link to each device.
    link_to: HashMap<[u8; 32], LinkId>,
    /// When each linked device's announce was last heard.
    last_announce: HashMap<[u8; 32], std::time::Instant>,
    /// Linked devices a link to which closed, or a request to which failed, since their announce was last heard: the next
    /// announce says they are reachable again ([`Handler::reachable`]).
    down: HashSet<[u8; 32]>,
    /// Link -> when it was seen first and the round trip time it opened with (for the line that says why it closed).
    link_info: HashMap<LinkId, (std::time::Instant, Option<u64>)>,
    /// The entry points known to the node (on or off), by id.
    entries: HashMap<String, Slot>,
    /// The interface of each attached entry point, back to its id.
    iface_entry: HashMap<InterfaceId, String>,
}

enum Ev {
    Announce {
        destination: DestinationHash,
        via: Via,
        /// The interface the announce came in on.
        iface: InterfaceId,
    },
    Identified {
        link: LinkId,
        identity: IdentityHash,
    },
    Closed {
        link: LinkId,
        reason: &'static str,
    },
    Established {
        link: LinkId,
        rtt_ms: u64,
    },
    Request {
        token: RespondToken,
        destination: DestinationHash,
        requester: Option<IdentityHash>,
        path: RequestPathHash,
        data: Vec<u8>,
    },
    Notify {
        link: LinkId,
        data: Vec<u8>,
    },
    PairAnnounce {
        destination: DestinationHash,
        local: bool,
        hops: u8,
    },
    Pair {
        link: LinkId,
        data: Vec<u8>,
    },
}

pub struct RnsNode {
    handle: PrnsNodeHandle,
    me: DestinationHash,
    my_identity: IdentityHash,
    device: SecretKey,
    /// Wi-Fi auto discovery's handle, when attached.
    wifi: Option<AutoWifiStatus>,
    /// Nearby linking.
    nearby: Arc<nearby::Nearby>,
    /// The linked devices' stored destinations, as Nearby needs them (their announces are not pairing announces).
    peers_dest: Arc<Mutex<Vec<DestinationHash>>>,
    /// The node's RNode interfaces (slow carriers), as Prns numbered them.
    #[cfg(feature = "rnode")]
    rnode_ifaces: Arc<Mutex<Vec<personal_rns::interfaces::InterfaceId>>>,
    state: Arc<Mutex<State>>,
    /// Random per node: keys the fingerprint of an entry point's settings, so a changed passphrase is noticed without keeping it.
    entry_salt: [u8; 32],
    /// How long without an announce makes a linked device reachable again, in ms ([`REACHABLE_GAP`] unless a test changed it).
    reach_gap_ms: Arc<std::sync::atomic::AtomicU64>,
    tasks: Vec<tokio::task::JoinHandle<()>>,
    stop: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
}

impl RnsNode {
    /// Starts the node on the current tokio runtime.
    pub async fn start(cfg: Config, handler: Arc<dyn Handler>) -> Result<RnsNode> {
        let identity = Zeroizing::new(identity_secret_for(&cfg.device));
        let destination = PreConfiguredDestination::Single {
            resource_strategy: ResourceStrategy::Accept {
                max_uncompressed_bytes: cfg.max_bytes,
                accept_compressed: true,
            },
            maximum_request_bytes: Default::default(),
            app_name: APP_NAME,
            aspects: ASPECTS,
            identity,
            announce_app_data: b"",
            proof: ProofStrategy::ProveAll,
            link_requests: LinkRequestPolicy::AcceptAll,
            ratchet: RatchetPolicy::NoRatchets,
            // No static endpoints: the paths are registered at run time and answered from events.
            request_endpoints: ServeMyRequestEndpoints::No,
        };
        let me = destination
            .destination_hash()
            .map_err(|e| anyhow!("bad destination name: {e:?}"))?;
        // The pairing pool (Nearby linking): random identities, never derived from the device key, each a destination
        // `cache.pair.v1` with empty announce data. Prns registers destinations only at start, so they are made here.
        let mut destinations = vec![destination];
        let mut pool: Vec<DestinationHash> = Vec::new();
        for _ in 0..nearby::POOL_SIZE {
            let mut secret = [0u8; 64];
            rand::Rng::fill_bytes(&mut rand::rng(), &mut secret);
            let d = PreConfiguredDestination::Single {
                resource_strategy: ResourceStrategy::AcceptNone,
                maximum_request_bytes: Default::default(),
                app_name: APP_NAME,
                aspects: nearby::PAIR_ASPECTS,
                identity: Zeroizing::new(secret),
                announce_app_data: b"",
                proof: ProofStrategy::ProveAll,
                link_requests: LinkRequestPolicy::AcceptAll,
                ratchet: RatchetPolicy::NoRatchets,
                request_endpoints: ServeMyRequestEndpoints::No,
            };
            zeroize::Zeroize::zeroize(&mut secret);
            pool.push(d.destination_hash().map_err(|e| anyhow!("bad pairing destination name: {e:?}"))?);
            destinations.push(d);
        }
        let (tx, mut rx) = mpsc::unbounded_channel::<Ev>();
        let observer_tx = tx.clone();
        let clients: Vec<String> = cfg
            .interfaces
            .iter()
            .filter_map(|i| {
                if let Iface::TcpConnect(a) = i {
                    Some(a.clone())
                } else {
                    None
                }
            })
            .collect();
        // RNodes: planned from RNS-style entries, so Prns's own bring-up, radio validation and reconnects are used.
        #[cfg(feature = "rnode")]
        let rnode_plan = {
        let mut rnode_text = String::new();
        for i in &cfg.interfaces {
            if let Iface::RNode { name, port, radio } = i {
                rnode_text.push_str(&rnode::config_entry(name, port, radio)?);
            }
        }
        if rnode_text.is_empty() {
            None
        } else {
            let report = prns_config::parse_and_plan(&format!("[interfaces]\n{rnode_text}"))
                .map_err(|e| anyhow!("the RNode settings are not valid: {e:?}"))?;
            Some(report.value)
        }
        };
        #[cfg(feature = "rnode")]
        let rnode_ids: Arc<Mutex<Vec<personal_rns::interfaces::InterfaceId>>> = Arc::default();
        #[cfg(feature = "rnode")]
        let rnode_ids_thread = rnode_ids.clone();
        let wifi_auto = cfg
            .interfaces
            .iter()
            .any(|i| matches!(i, Iface::WifiAuto))
            .then(AutoWifi::new);
        let wifi_status = wifi_auto.as_ref().map(|w| w.status());
        if let (Some(status), Some(group)) = (&wifi_status, &cfg.wifi_group) {
            if !status.set_group_id(group) {
                bail!("the Wi-Fi discovery group is not valid");
            }
        }
        let listens: Vec<String> = cfg
            .interfaces
            .iter()
            .filter_map(|i| {
                if let Iface::TcpListen(a) = i {
                    Some(a.clone())
                } else {
                    None
                }
            })
            .collect();
        // Prns's run loop is not Send, so the node lives on its own thread with a single-threaded runtime; its handle is
        // thread-safe and is all the rest of this crate uses. The listeners are bound there too, on the node's own reactor.
        let (ready_tx, ready_rx) = tokio::sync::oneshot::channel::<Result<PrnsNodeHandle>>();
        let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
        std::thread::Builder::new()
            .name("cache-rns".into())
            // Prns's futures are large: the default 2 MiB stack overflows in debug builds (found 2026-11-22), so give it margin.
            .stack_size(32 * 1024 * 1024)
            .spawn(move || {
                let rt = match tokio::runtime::Builder::new_current_thread()
                    .enable_all()
                    .build()
                {
                    Ok(rt) => rt,
                    Err(e) => {
                        let _ =
                            ready_tx.send(Err(anyhow!("no runtime for the Reticulum node: {e}")));
                        return;
                    }
                };
                let local = tokio::task::LocalSet::new();
                local.block_on(&rt, async move {
                    let node = PrnsNode::new(PrnsNodeRecipe {
                        transport_identity: None,
                        remote_control: RemoteControlService::Unavailable.into(),
                        pre_configured_destinations: destinations,
                        app_state: personal_rns::runtime::NoRemoteControlHostControls,
                        storage: GrowableHeap,
                        request_endpoints: request_endpoints![],
                        on_event: move |event, _state| {
                            let ev = match event {
                                PrnsEvent::Diagnostic(Diagnostic::AnnounceHeard {
                                    destination,
                                    source_interface,
                                    ..
                                }) => Ev::Announce {
                                    destination,
                                    iface: source_interface,
                                    via: match source_interface.kind() {
                                        Some(InterfaceKind::AutoWifi | InterfaceKind::WifiPeer) => Via::Wifi,
                                        _ => Via::Other,
                                    },
                                },
                                PrnsEvent::Diagnostic(Diagnostic::PeerIdentified {
                                    link_id,
                                    identity,
                                }) => Ev::Identified {
                                    link: link_id,
                                    identity,
                                },
                                PrnsEvent::Diagnostic(Diagnostic::LinkClosed { link_id, reason }) => Ev::Closed {
                                    link: link_id,
                                    reason: match reason {
                                        LinkClosedReason::Timeout => "timeout (nothing heard on it for too long)",
                                        LinkClosedReason::PeerClosed => "closed by the other device",
                                        LinkClosedReason::LocallyClosed => "closed on this device",
                                        _ => "closed (bad round trip message)",
                                    },
                                },
                                PrnsEvent::Diagnostic(Diagnostic::LinkEstablished(e)) => Ev::Established {
                                    link: e.link_id,
                                    rtt_ms: e.rtt_millis,
                                },
                                PrnsEvent::Message(Message::Request {
                                    destination: request_destination,
                                    link_id,
                                    request_id,
                                    requester,
                                    path_hash,
                                    rtt,
                                    data,
                                    ..
                                }) => Ev::Request {
                                    destination: request_destination,
                                    token: RespondToken {
                                        link_id,
                                        request_id,
                                        rtt,
                                    },
                                    requester,
                                    path: path_hash,
                                    data: data.to_vec(),
                                },
                                PrnsEvent::Message(Message::ChannelMessage {
                                    link_id,
                                    message_type,
                                    data,
                                }) if message_type == NOTIFY_TYPE => Ev::Notify {
                                    link: link_id,
                                    data: data.to_vec(),
                                },
                                PrnsEvent::Message(Message::ChannelMessage {
                                    link_id,
                                    message_type,
                                    data,
                                }) if message_type == nearby::PAIR_TYPE => Ev::Pair {
                                    link: link_id,
                                    data: data.to_vec(),
                                },
                                _ => return,
                            };
                            let _ = tx.send(ev);
                        },
                        interfaces: move |node: &PrnsNodeHandle| {
                            for a in &clients {
                                node.attach(TcpClientInterface::new(a.clone()));
                            }
                            if let Some(w) = wifi_auto {
                                node.attach(w);
                            }
                        },
                        persistence: NoPersistence,
                    })
                    // A validated announce, with the identity it was made by: a `cache.pair.v1` destination is recognised
                    // by recomputing its hash from that identity, so nothing is contacted until it matches.
                    .with_accepted_announce_observer(move |obs| {
                        let is_pair = personal_rns::routing::announce::derive_single_destination_hash(
                            &obs.announced_identity,
                            APP_NAME,
                            nearby::PAIR_ASPECTS,
                        )
                        .is_ok_and(|d| d == obs.destination);
                        if is_pair {
                            let _ = observer_tx.send(Ev::PairAnnounce {
                                destination: obs.destination,
                                local: matches!(obs.source_interface.kind(), Some(InterfaceKind::AutoWifi | InterfaceKind::WifiPeer)),
                                hops: obs.hops.0,
                            });
                        }
                    });
                    let handle = node.handle();
                    let mut guards = Vec::new();
                    for a in &listens {
                        match TcpServer::bind(a.as_str()).await {
                            Ok(s) => guards.push(handle.supervise(s)),
                            Err(e) => {
                                let _ = ready_tx.send(Err(anyhow!("cannot listen on {a}: {e}")));
                                return;
                            }
                        }
                    }
                    #[cfg(feature = "rnode")]
                    let mut rnode_attachments = None;
                    #[cfg(feature = "rnode")]
                    if let Some(plan) = &rnode_plan {
                        let ids = rnode_ids_thread.clone();
                        rnode_attachments = Some(
                            personal_rns::from_plan::attach_plan(&handle, plan, &mut |outcome| match outcome {
                                personal_rns::from_plan::PlanOutcome::Up { id, .. } => ids.lock().unwrap().push(id),
                                personal_rns::from_plan::PlanOutcome::Failed { error, .. } => {
                                    eprintln!("cache_rns: an RNode interface did not start: {error}")
                                }
                            })
                            .await,
                        );
                    }
                    let _ = ready_tx.send(Ok(handle));
                    tokio::select! {
                        r = node.run() => {
                            if let Err(e) = r {
                                eprintln!("cache_rns: the node stopped: {e:?}");
                            }
                        }
                        _ = stop_rx => {}
                    }
                    drop(guards);
                    #[cfg(feature = "rnode")]
                    drop(rnode_attachments);
                });
            })
            .context("cannot start the Reticulum thread")?;
        let handle = ready_rx
            .await
            .map_err(|_| anyhow!("the Reticulum thread ended at start"))??;
        let mut tasks: Vec<tokio::task::JoinHandle<()>> = Vec::new();

        let open: HashSet<String> = cfg.open_paths.iter().cloned().collect();
        let mut paths: Vec<(RequestPathHash, String)> = Vec::new();
        let mut all_paths = cfg.paths.clone();
        all_paths.push(HELLO_PATH.to_string());
        if cfg.blobs.is_some() {
            all_paths.push(blobs::BLOB_PATH.to_string());
        }
        let store = cfg.blobs.clone();
        for p in &all_paths {
            let policy = if open.contains(p) || p == HELLO_PATH {
                RequestPolicy::AllowAll
            } else {
                RequestPolicy::RequireIdentified
            };
            handle
                .register_request_path(me, p, policy)
                .await
                .map_err(|e| anyhow!("cannot register {p}: {e:?}"))?;
            paths.push((RequestPathHash::of(p), p.clone()));
        }
        let my_identity = identity_hash_for(&cfg.device);

        let peers_dest: Arc<Mutex<Vec<DestinationHash>>> =
            Arc::new(Mutex::new(cfg.peers.iter().filter_map(|(_, d)| *d).collect()));
        let nearby = nearby::Nearby::new(
            handle.clone(),
            cfg.device.clone(),
            me,
            handler.clone(),
            wifi_status.clone(),
            cfg.pair_local_tcp,
            pool,
            peers_dest.clone(),
        );
        tasks.push(nearby.start_tick());

        let state = Arc::new(Mutex::new(State {
            peers: cfg.peers.iter().map(|(p, _)| *p.as_bytes()).collect(),
            destination_of: cfg
                .peers
                .iter()
                .filter_map(|(p, d)| d.map(|d| (*p.as_bytes(), d)))
                .collect(),
            ..Default::default()
        }));

        let reach_gap_ms = Arc::new(std::sync::atomic::AtomicU64::new(REACHABLE_GAP.as_millis() as u64));
        // Events: heard announces, identities on links, hellos, requests, notifications.
        {
            let reach_gap_ms = reach_gap_ms.clone();
            let state = state.clone();
            let handle = handle.clone();
            let nearby = nearby.clone();
            tasks.push(tokio::spawn(async move {
                while let Some(ev) = rx.recv().await {
                    match ev {
                        Ev::Announce { destination, via, iface } => {
                            // A frame that passed the interface's IFAC check and parsed as an announce: on an entry point that is
                            // the proof the network name and passphrase match.
                            let via = {
                                let mut s = state.lock().unwrap();
                                match s.iface_entry.get(&iface).cloned() {
                                    Some(id) => {
                                        if let Some(slot) = s.entries.get_mut(&id) {
                                            slot.t.valid = true;
                                        }
                                        Via::Entry(id)
                                    }
                                    None => via,
                                }
                            };
                            if destination == me {
                                continue;
                            }
                            // An announce proves nothing about who sent it (it is empty): it only says a stored
                            // destination can be reached, and on what.
                            let mut s = state.lock().unwrap();
                            let hit = s
                                .destination_of
                                .iter()
                                .find(|(_, d)| **d == destination)
                                .map(|(k, _)| *k);
                            let mut again = None;
                            if let Some(k) = hit {
                                // A device heard for the first time is not "again": the round every device makes at its start, and the
                                // notices, cover it (and a round at that instant can ask before the link can be made).
                                s.heard.insert(k, via);
                                let now = std::time::Instant::now();
                                let late = s.last_announce.insert(k, now).is_some_and(|t| now.duration_since(t).as_millis() as u64 > reach_gap_ms.load(std::sync::atomic::Ordering::Relaxed));
                                let was_down = s.down.remove(&k);
                                if late || was_down {
                                    again = Some(k);
                                }
                            }
                            drop(s);
                            if let Some(k) = again.and_then(|k| PublicKey::from_bytes(&k).ok()) {
                                handler.reachable(k);
                            }
                        }
                        Ev::Identified { link, identity } => {
                            state
                                .lock()
                                .unwrap()
                                .identity_on_link
                                .insert(link, identity);
                        }
                        Ev::PairAnnounce { destination, local, hops } => nearby.on_announce(destination, local, hops),
                        Ev::Pair { link, data } => nearby.on_message(link, &data),
                        Ev::Established { link, rtt_ms } => {
                            state
                                .lock()
                                .unwrap()
                                .link_info
                                .entry(link)
                                .and_modify(|i| i.1 = Some(rtt_ms))
                                .or_insert((std::time::Instant::now(), Some(rtt_ms)));
                        }
                        Ev::Closed { link, reason } => {
                            nearby.on_link_closed(link);
                            let mut s = state.lock().unwrap();
                            // Which linked device it was (an unlinked or unknown one is not logged), and how long it was open.
                            let who = s
                                .link_to
                                .iter()
                                .find(|(_, l)| **l == link)
                                .map(|(k, _)| *k)
                                .or_else(|| s.verified.get(&link).map(|(k, _)| *k));
                            let info = s.link_info.remove(&link);
                            s.identity_on_link.remove(&link);
                            if let Some((d, _)) = s.verified.remove(&link) {
                                s.down.insert(d);
                            }
                            let gone: Vec<[u8; 32]> = s.link_to.iter().filter(|(_, l)| **l == link).map(|(k, _)| *k).collect();
                            s.down.extend(gone);
                            s.link_to.retain(|_, l| *l != link);
                            drop(s);
                            if let Some(k) = who.and_then(|k| PublicKey::from_bytes(&k).ok()) {
                                handler.link_closed(k, reason, info.map(|(t, _)| t.elapsed().as_secs()), info.and_then(|(_, r)| r));
                            }
                        }
                        Ev::Request {
                            token,
                            destination,
                            requester,
                            path,
                            data,
                        } => {
                            if nearby.owns(destination) {
                                nearby.on_request(token, destination, path, data);
                                continue;
                            }
                            let Some(name) = paths
                                .iter()
                                .find(|(h, _)| *h == path)
                                .map(|(_, n)| n.clone())
                            else {
                                continue;
                            };
                            let identity = {
                                let s = state.lock().unwrap();
                                requester.or_else(|| s.identity_on_link.get(&token.link_id).copied())
                            };
                            if name == HELLO_PATH {
                                // The first message on a link: the device key and its signature over the identity the
                                // link proved. Anything that does not check out gets no answer at all.
                                // The one exception: a device that used to be linked and whose hello is signed correctly
                                // is told "not linked" (so it can learn it was unlinked).
                                let reply = identity.and_then(|id| {
                                    let (device, sig) = parse_hello(&data)?;
                                    let mut s = state.lock().unwrap();
                                    if !check_vouch(&device, &id, &sig) {
                                        return None;
                                    }
                                    if s.peers.contains(device.as_bytes()) {
                                        s.verified.insert(token.link_id, (*device.as_bytes(), id));
                                        Some(&b"ok"[..])
                                    } else if s.former.contains(device.as_bytes()) {
                                        Some(NOT_LINKED)
                                    } else {
                                        None
                                    }
                                });
                                if let Some(reply) = reply {
                                    let _ = handle.respond_bytes(token, reply);
                                }
                                continue;
                            }
                            let asker = {
                                let s = state.lock().unwrap();
                                verified_device(&s, &token.link_id, identity)
                                    .map(Asker::Linked)
                                    .unwrap_or(Asker::Unlinked)
                            };
                            if asker == Asker::Unlinked && !open.contains(&name) {
                                // A device whose hello verified on this link but that has since been unlinked is told
                                // "not linked" (its link predates the unlink, so no new hello will come).
                                let former = {
                                    let s = state.lock().unwrap();
                                    verified_former_device(&s, &token.link_id, identity)
                                };
                                if former {
                                    let _ = handle.respond_bytes(token, NOT_LINKED);
                                }
                                // Otherwise no hello from a linked device, and not an open path: no answer at all, as the
                                // iroh gate refuses the connection.
                                continue;
                            }
                            if name == blobs::BLOB_PATH && store.is_some() {
                                // Built in: only for linked devices (the path is never open). With no store given the path
                                // goes to the handler like any other (the interop test serves it with the pre-6a code).
                                let (Some(store), Asker::Linked(_)) = (store.clone(), asker) else {
                                    continue;
                                };
                                let handle = handle.clone();
                                let (handler, from) = (handler.clone(), match asker {
                                    Asker::Linked(p) => p,
                                    Asker::Unlinked => continue,
                                });
                                tokio::spawn(async move {
                                    if !handler.blobs_ready() {
                                        let _ = handle.respond_owned_bytes(token, blobs::not_ready());
                                        return;
                                    }
                                    let want = blobs::decode_want(&data);
                                    if let Some((hash, _, end)) = want {
                                        handler.served(from, hash, end.saturating_mul(blobs::CHUNK));
                                    }
                                    let reply = blobs::serve_window(&store, &data).await;
                                    if let Some((hash, _, end)) = want {
                                        handler.served(from, hash, end.saturating_mul(blobs::CHUNK));
                                    }
                                    let _ = handle.respond_owned_bytes(token, reply);
                                });
                                continue;
                            }
                            let handler = handler.clone();
                            let handle = handle.clone();
                            tokio::spawn(async move {
                                let reply = match handler.request(asker, &name, data).await {
                                    Ok(r) => r,
                                    Err(e) => format!("error: {e}").into_bytes(),
                                };
                                let _ = handle.respond_bytes(token, &reply);
                            });
                        }
                        Ev::Notify { link, data } => {
                            let from = {
                                let s = state.lock().unwrap();
                                let id = s.identity_on_link.get(&link).copied();
                                verified_device(&s, &link, id)
                            };
                            if let Some(from) = from {
                                handler.notify(from, data);
                            }
                        }
                    }
                }
            }));
        }

        // Paths: a stored destination with no path yet gets a standard path request (so a routed destination, behind
        // ordinary transport nodes, is reachable without its announce having reached us directly).
        {
            let handle = handle.clone();
            let state = state.clone();
            tasks.push(tokio::spawn(async move {
                let mut tick = tokio::time::interval(PATH_EVERY);
                loop {
                    tick.tick().await;
                    let missing: Vec<([u8; 32], DestinationHash)> = {
                        let s = state.lock().unwrap();
                        s.destination_of
                            .iter()
                            .filter(|(k, _)| !s.heard.contains_key(*k))
                            .map(|(k, d)| (*k, *d))
                            .collect()
                    };
                    for (k, d) in missing {
                        find_path(&handle, &state, k, d).await;
                    }
                }
            }));
        }

        // Announces (empty app data): at start, then every 30 s, on every interface that is not an entry point (Wi-Fi, and
        // the carriers tests attach). An entry point is announced on once when it connects, then every 6 h ([`entry_monitor`]).
        {
            let handle = handle.clone();
            let state = state.clone();
            tasks.push(tokio::spawn(async move {
                let mut tick = tokio::time::interval(ANNOUNCE_EVERY);
                loop {
                    tick.tick().await;
                    announce_off_entries(&handle, &state, me).await;
                }
            }));
        }

        // The entry points given at start; later changes come through `set_entry_points`.
        let entry_salt: [u8; 32] = rand::random();
        let first: Vec<EntryPoint> = cfg
            .interfaces
            .iter()
            .filter_map(|i| if let Iface::Entry(e) = i { Some(e.clone()) } else { None })
            .collect();
        if !first.is_empty() {
            apply_entries(&handle, &state, &entry_salt, &first);
        }
        // Entry point status, the announce when one connects, and the path requests that follow.
        {
            let handle = handle.clone();
            let state = state.clone();
            tasks.push(tokio::spawn(entry_monitor(handle, state, me)));
        }

        Ok(RnsNode {
            handle,
            me,
            my_identity,
            device: cfg.device.clone(),
            wifi: wifi_status,
            #[cfg(feature = "rnode")]
            rnode_ifaces: rnode_ids,
            nearby,
            peers_dest,
            state,
            entry_salt,
            reach_gap_ms,
            tasks,
            stop: Mutex::new(Some(stop_tx)),
        })
    }

    /// How many RNode interfaces came up.
    #[cfg(feature = "rnode")]
    pub fn rnode_count(&self) -> usize {
        self.rnode_ifaces.lock().unwrap().len()
    }

    pub fn destination(&self) -> DestinationHash {
        self.me
    }

    /// Replaces the list of linked devices (each with its stored destination, when known).
    pub fn set_peers(&self, peers: &[(PublicKey, Option<DestinationHash>)]) {
        let mut s = self.state.lock().unwrap();
        s.peers = peers.iter().map(|(p, _)| *p.as_bytes()).collect();
        let keep = s.peers.clone();
        // A destination already stored stays when the caller does not know it (None); a changed one is not heard yet.
        for (p, d) in peers {
            if let Some(d) = d {
                if s.destination_of.insert(*p.as_bytes(), *d) != Some(*d) {
                    s.heard.remove(p.as_bytes());
                }
            }
        }
        s.destination_of.retain(|k, _| keep.contains(k));
        *self.peers_dest.lock().unwrap() = s.destination_of.values().copied().collect();
        s.heard.retain(|k, _| keep.contains(k));
        // `verified` is kept: `verified_device` checks the peer list, and an unlinked device's open link must still be
        // recognised (to answer it "not linked") until `set_former` says whether it is remembered.
        s.link_to.retain(|k, _| keep.contains(k));
    }

    /// Tests only: how long without an announce makes a linked device reachable again.
    pub fn set_reach_gap(&self, d: Duration) {
        self.reach_gap_ms.store(d.as_millis() as u64, std::sync::atomic::Ordering::Relaxed);
    }

    /// Replaces the list of devices that used to be linked (not linked now): a signed hello from one is answered "not linked".
    pub fn set_former(&self, former: &[PublicKey]) {
        let mut s = self.state.lock().unwrap();
        s.former = former.iter().map(|p| *p.as_bytes()).collect();
        let (peers, former) = (s.peers.clone(), s.former.clone());
        s.verified.retain(|_, (d, _)| peers.contains(d) || former.contains(d));
    }

    /// Whether a path to `peer`'s stored destination is known: its announce was heard (from any number of hops away), or a
    /// standard path request for it was answered.
    pub fn reachable(&self, peer: &PublicKey) -> bool {
        self.state.lock().unwrap().heard.contains_key(peer.as_bytes())
    }

    /// Sends a standard path request for `peer`'s stored destination now (without waiting for the next periodic one) and says
    /// whether a path is known after it. False when no destination is stored.
    pub async fn find_path_to(&self, peer: &PublicKey) -> bool {
        let destination = self.state.lock().unwrap().destination_of.get(peer.as_bytes()).copied();
        let Some(destination) = destination else { return false };
        if self.reachable(peer) {
            return true;
        }
        find_path(&self.handle, &self.state, *peer.as_bytes(), destination).await
    }

    /// Sends a standard path request for a destination that is not a stored device (the destination a short link code names)
    /// and says whether a path is known after it: `wait` is how long a routed answer may take.
    pub async fn find_path_dest(&self, destination: DestinationHash, wait: Duration) -> bool {
        matches!(tokio::time::timeout(wait, self.handle.request_path(destination)).await, Ok(Ok(_)))
    }

    /// What `peer`'s route comes in on (its first hop's interface): [`Via::Wifi`] only for Wi-Fi auto interfaces.
    pub fn via(&self, peer: &PublicKey) -> Option<Via> {
        self.state.lock().unwrap().heard.get(peer.as_bytes()).cloned()
    }

    /// Announces now (for example after a network change), on every interface but the entry points ([`entry_monitor`] announces
    /// on those when they connect). The app data is empty.
    pub async fn announce(&self) -> Result<()> {
        announce_off_entries(&self.handle, &self.state, self.me).await;
        Ok(())
    }

    /// Makes the entry points the ones listed, by id, on the running node (it is never restarted): a new entry that is on, or
    /// one newly switched on, is attached; one switched off or removed is detached and its routes dropped (`forget_interface`);
    /// an edited one is detached and attached again. Each is keyed with its IFAC network name and passphrase (either may be
    /// empty). The passphrase copies made here are wiped once the key is derived, and only a salted hash of the settings is
    /// kept to notice an edit.
    pub fn set_entry_points(&self, entries: &[EntryPoint]) {
        apply_entries(&self.handle, &self.state, &self.entry_salt, entries);
    }

    /// Where each entry point stands, by id, with when that was checked (ms since the Unix epoch): sorted by id.
    pub fn entry_status(&self) -> Vec<(String, EntryState, u64)> {
        observe_entries(&self.handle, &self.state);
        let now = std::time::Instant::now();
        let checked = unix_ms();
        let s = self.state.lock().unwrap();
        let mut out: Vec<(String, EntryState, u64)> =
            s.entries.iter().map(|(id, slot)| (id.clone(), judge(slot, now), checked)).collect();
        out.sort_by(|a, b| a.0.cmp(&b.0));
        out
    }

    /// Wi-Fi auto discovery's current members (interfaces to other devices found on the local network).
    pub fn wifi_members(&self) -> usize {
        self.wifi.as_ref().map_or(0, |w| w.members().len())
    }

    /// The local addresses Wi-Fi auto discovery is using.
    pub fn wifi_local_addresses(&self) -> Vec<(std::net::IpAddr, u32)> {
        self.wifi.as_ref().map(|w| w.local_addresses()).unwrap_or_default()
    }

    /// Turns Wi-Fi auto discovery on or off (when attached).
    pub fn set_wifi_enabled(&self, on: bool) {
        if let Some(w) = &self.wifi {
            if on {
                w.enable()
            } else {
                w.disable()
            }
        }
    }

    async fn link_to(&self, peer: &PublicKey, timeout: Duration) -> Result<LinkId> {
        let (existing, destination) = {
            let s = self.state.lock().unwrap();
            if !s.peers.contains(peer.as_bytes()) {
                bail!("not a linked device");
            }
            (
                s.link_to.get(peer.as_bytes()).copied(),
                s.destination_of.get(peer.as_bytes()).copied(),
            )
        };
        if let Some(l) = existing {
            return Ok(l);
        }
        let destination = destination
            .ok_or_else(|| anyhow!("no Reticulum destination stored for this device"))?;
        if !self.reachable(peer) {
            find_path(&self.handle, &self.state, *peer.as_bytes(), destination).await;
        }
        let link = self
            .handle
            .establish_link(destination)
            .await
            .map_err(|e| anyhow!("not reachable: {e:?}"))?;
        self.handle
            .identify(link, self.my_identity)
            .await
            .map_err(|e| anyhow!("could not identify on the link: {e:?}"))?;
        if let Err(e) = self.hello(link, timeout).await {
            let _ = self.handle.close_link(link);
            return Err(e);
        }
        {
            let mut s = self.state.lock().unwrap();
            s.link_to.insert(*peer.as_bytes(), link);
            // The other end of a link is told its round trip time when it is up; this end only knows when it opened.
            s.link_info.entry(link).or_insert((std::time::Instant::now(), None));
        }
        Ok(link)
    }

    /// The first message on a link: who we are (device key), signed over the identity the link proved.
    async fn hello(&self, link: LinkId, timeout: Duration) -> Result<()> {
        let body = hello_body(&self.device, &self.my_identity);
        let r = tokio::time::timeout(
            timeout + Duration::from_secs(1),
            self.handle.request_with_response_timeout(
                link,
                RequestPathHash::of(HELLO_PATH),
                &body,
                exact(timeout),
            ),
        )
        .await;
        match r {
            Ok(Ok((reply, _))) if unpack_bin(reply.clone()).is_ok_and(|b| b == b"ok") => Ok(()),
            Ok(Ok((reply, _))) if unpack_bin(reply.clone()).is_ok_and(|b| b == NOT_LINKED) => bail!(NOT_LINKED_ERROR),
            Ok(Ok(_)) => bail!("the other device did not accept the hello"),
            Ok(Err(e)) => bail!("no answer to the hello: {e:?}"),
            Err(_) => bail!("the hello timed out"),
        }
    }

    fn forget_link(&self, peer: &PublicKey) {
        let mut s = self.state.lock().unwrap();
        s.link_to.remove(peer.as_bytes());
        s.down.insert(*peer.as_bytes());
    }

    /// Asks a linked device on `path`.
    pub async fn request(
        &self,
        peer: &PublicKey,
        path: &str,
        body: &[u8],
        timeout: Duration,
    ) -> Result<Vec<u8>> {
        let link = self.link_to(peer, timeout).await?;
        let r = tokio::time::timeout(
            timeout + Duration::from_secs(1),
            self.handle.request_with_response_timeout(
                link,
                RequestPathHash::of(path),
                body,
                exact(timeout),
            ),
        )
        .await;
        match r {
            Ok(Ok((reply, _rtt))) => {
                let body = unpack_bin(reply)?;
                if body == NOT_LINKED {
                    bail!(NOT_LINKED_ERROR);
                }
                Ok(body)
            }
            Ok(Err(e)) => {
                self.forget_link(peer);
                Err(anyhow!("the request failed: {e:?}"))
            }
            Err(_) => {
                self.forget_link(peer);
                Err(anyhow!("timed out"))
            }
        }
    }

    /// Asks a device that is not linked yet (pairing), at a destination it gave out of band (the link code).
    pub async fn request_unlinked(
        &self,
        destination: DestinationHash,
        path: &str,
        body: &[u8],
        timeout: Duration,
    ) -> Result<Vec<u8>> {
        let link = self
            .handle
            .establish_link(destination)
            .await
            .map_err(|e| anyhow!("not reachable: {e:?}"))?;
        self.handle
            .identify(link, self.my_identity)
            .await
            .map_err(|e| anyhow!("could not identify: {e:?}"))?;
        // The hello of a device the other end does not list is not answered, and pairing does not need it: send it and
        // do not wait.
        {
            let handle = self.handle.clone();
            let body = hello_body(&self.device, &self.my_identity);
            tokio::spawn(async move {
                let _ = handle
                    .request_with_response_timeout(link, RequestPathHash::of(HELLO_PATH), &body, exact(Duration::from_secs(5)))
                    .await;
            });
        }
        let r = tokio::time::timeout(
            timeout + Duration::from_secs(1),
            self.handle.request_with_response_timeout(
                link,
                RequestPathHash::of(path),
                body,
                exact(timeout),
            ),
        )
        .await;
        let _ = self.handle.close_link(link);
        match r {
            Ok(Ok((reply, _))) => unpack_bin(reply),
            Ok(Err(e)) => Err(anyhow!("the request failed: {e:?}")),
            Err(_) => Err(anyhow!("timed out")),
        }
    }

    /// Tells a linked device something changed (acknowledged, in order).
    pub async fn notify(&self, peer: &PublicKey, body: &[u8]) -> Result<()> {
        let link = self.link_to(peer, Duration::from_secs(10)).await?;
        match self
            .handle
            .send_channel_message(link, NOTIFY_TYPE, body)
            .await
        {
            Ok(_) => Ok(()),
            Err(e) => {
                self.forget_link(peer);
                Err(anyhow!("not delivered: {e:?}"))
            }
        }
    }

    /// Nearby linking: the page opened. Takes an unused pairing address and answers for it ([`nearby`]).
    pub async fn pair_open(&self, me: PairSelf) -> Result<()> {
        self.nearby.open(me).await
    }

    /// Nearby linking: the page closed. Stops announcing and answering; nothing in progress is kept.
    pub async fn pair_close(&self) {
        self.nearby.close().await
    }

    /// Nearby linking: the devices heard nearby that gave their name, while our page is open.
    pub fn pair_list(&self) -> Vec<NearbyDevice> {
        self.nearby.list()
    }

    /// Nearby linking: Link was tapped on the device `id` of [`RnsNode::pair_list`].
    pub async fn pair_link(&self, id: &str, me: PairSelf) -> Result<()> {
        self.nearby.link(id, me).await
    }

    /// Nearby linking: where it stands.
    pub fn pair_status(&self) -> PairStatus {
        self.nearby.status()
    }

    /// Nearby linking: Link (`true`) or Cancel on the words.
    pub async fn pair_answer(&self, ok: bool) -> Result<()> {
        self.nearby.answer(ok).await
    }

    /// The Nearby state itself (tests: the pool, the clock, who was heard).
    pub fn nearby(&self) -> &Arc<nearby::Nearby> {
        &self.nearby
    }

    /// Stops the node and its thread.
    pub fn stop(&self) {
        for t in &self.tasks {
            t.abort();
        }
        if let Some(s) = self.stop.lock().unwrap().take() {
            let _ = s.send(());
        }
    }
}

/// A standard Reticulum path request for a stored destination; a returned path makes it reachable (over whatever
/// transport nodes carry it: nothing here needs a direct neighbour). The interface it came in on is learned from the
/// announce that answers, so until then it counts as [`Via::Other`].
async fn find_path(
    handle: &PrnsNodeHandle,
    state: &Arc<Mutex<State>>,
    peer: [u8; 32],
    destination: DestinationHash,
) -> bool {
    match tokio::time::timeout(Duration::from_secs(10), handle.request_path(destination)).await {
        Ok(Ok(_)) => {
            state.lock().unwrap().heard.entry(peer).or_insert(Via::Other);
            true
        }
        _ => false,
    }
}

/// The linked device whose hello checked out on `link`, if it still does: the identity on the link is the one the hello
/// was for, and the device is still in the list.
fn verified_device(s: &State, link: &LinkId, identity: Option<IdentityHash>) -> Option<PublicKey> {
    let (device, hello_id) = s.verified.get(link)?;
    if identity != Some(*hello_id) || !s.peers.contains(device) {
        return None;
    }
    PublicKey::from_bytes(device).ok()
}

/// True when the hello on `link` verified a device that is no longer linked but is in the former set.
fn verified_former_device(s: &State, link: &LinkId, identity: Option<IdentityHash>) -> bool {
    let Some((device, hello_id)) = s.verified.get(link) else {
        return false;
    };
    identity == Some(*hello_id) && !s.peers.contains(device) && s.former.contains(device)
}

/// Responses travel as a msgpack value, as RNS packs them; `respond_bytes` sends a msgpack bin. Unwraps it.
pub(crate) fn unpack_bin(packed: Vec<u8>) -> Result<Vec<u8>> {
    let (len, head) = match packed.first() {
        Some(0xc4) if packed.len() >= 2 => (packed[1] as usize, 2),
        Some(0xc5) if packed.len() >= 3 => (u16::from_be_bytes([packed[1], packed[2]]) as usize, 3),
        Some(0xc6) if packed.len() >= 5 => (
            u32::from_be_bytes([packed[1], packed[2], packed[3], packed[4]]) as usize,
            5,
        ),
        _ => bail!("the answer is not a byte string"),
    };
    if packed.len() != head + len {
        bail!("the answer's length does not match");
    }
    let mut v = packed;
    v.drain(..head);
    Ok(v)
}

fn exact(t: Duration) -> personal_rns::engine::RequestResponseTimeout {
    personal_rns::engine::RequestResponseTimeout::Exact(personal_rns::units::DurationMillis(
        t.as_millis() as u64,
    ))
}

/// What the node keeps of one entry point.
struct Slot {
    /// A salted hash of (host, port, network name, passphrase): an edit is a different fingerprint.
    fp: [u8; 32],
    on: bool,
    /// Its interface while attached.
    iid: Option<InterfaceId>,
    t: Tracker,
}

#[derive(Default)]
struct Tracker {
    attached_at: Option<std::time::Instant>,
    /// The interface's connection state when last looked at.
    conn: Option<ConnectionState>,
    /// Since when it has not been Connected (first seen, from attach on).
    not_connected_since: Option<std::time::Instant>,
    connected_since: Option<std::time::Instant>,
    /// Receive counter when this connection was first seen up, and now.
    rx_base: u64,
    rx_now: u64,
    /// A valid frame has arrived on this attachment (it passed IFAC and parsed: an announce was heard, or a route or link exists).
    valid: bool,
    announced_at: Option<std::time::Instant>,
    /// Became Connected since the monitor last ran: announce once on it and ask for paths.
    up_pending: bool,
    /// Connected and [`ENTRY_ANNOUNCE_EVERY`] has passed since the last announce on it.
    due_pending: bool,
}

fn unix_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

fn judge(slot: &Slot, now: std::time::Instant) -> EntryState {
    if !slot.on || slot.iid.is_none() {
        return EntryState::Off;
    }
    let t = &slot.t;
    match t.conn {
        Some(ConnectionState::Connected | ConnectionState::Degraded) => {
            if t.valid {
                EntryState::Connected
            } else if t.rx_now > t.rx_base
                && t.connected_since.is_some_and(|c| now.duration_since(c) >= MISMATCH_AFTER)
            {
                EntryState::Mismatch
            } else {
                EntryState::NothingHeard
            }
        }
        Some(ConnectionState::Disabled) => EntryState::Off,
        _ => {
            let since = t.not_connected_since.or(t.attached_at);
            if since.is_some_and(|c| now.duration_since(c) > NOT_ANSWERING_AFTER) {
                EntryState::NotAnswering
            } else {
                EntryState::Connecting
            }
        }
    }
}

/// Looks at every attached entry point's interface once and updates what is known of it.
fn observe_entries(handle: &PrnsNodeHandle, state: &Arc<Mutex<State>>) {
    if state.lock().unwrap().entries.values().all(|s| s.iid.is_none()) {
        return;
    }
    let snaps = handle.interfaces();
    let now = std::time::Instant::now();
    let mut s = state.lock().unwrap();
    for slot in s.entries.values_mut() {
        let Some(iid) = slot.iid else { continue };
        let Some(sn) = snaps.iter().find(|x| x.id == iid) else { continue };
        let t = &mut slot.t;
        let was_connected = matches!(t.conn, Some(ConnectionState::Connected));
        let connected = matches!(sn.connection, ConnectionState::Connected);
        t.conn = Some(sn.connection);
        t.rx_now = sn.rx_bytes;
        if sn.destinations > 0 || sn.links > 0 {
            t.valid = true;
        }
        if connected {
            t.not_connected_since = None;
            if !was_connected {
                t.connected_since = Some(now);
                t.rx_base = sn.rx_bytes;
                t.up_pending = true;
                t.announced_at = Some(now);
            } else if t.announced_at.is_some_and(|a| now.duration_since(a) >= ENTRY_ANNOUNCE_EVERY) {
                t.due_pending = true;
                t.announced_at = Some(now);
            }
        } else {
            t.connected_since = None;
            if t.not_connected_since.is_none() {
                t.not_connected_since = Some(now);
            }
        }
    }
}

/// Entry points: looks at them every second; when one has connected, announces on it once and sends path requests for every stored
/// linked device; announces on a connected one again every [`ENTRY_ANNOUNCE_EVERY`].
async fn entry_monitor(handle: PrnsNodeHandle, state: Arc<Mutex<State>>, me: DestinationHash) {
    let mut tick = tokio::time::interval(ENTRY_POLL);
    loop {
        tick.tick().await;
        observe_entries(&handle, &state);
        let (announce, connected, dests) = {
            let mut s = state.lock().unwrap();
            let mut announce = Vec::new();
            let mut connected = false;
            for slot in s.entries.values_mut() {
                let Some(iid) = slot.iid else { continue };
                if slot.t.up_pending {
                    slot.t.up_pending = false;
                    slot.t.due_pending = false;
                    announce.push(iid);
                    connected = true;
                } else if slot.t.due_pending {
                    slot.t.due_pending = false;
                    announce.push(iid);
                }
            }
            let dests: Vec<([u8; 32], DestinationHash)> =
                s.destination_of.iter().map(|(k, d)| (*k, *d)).collect();
            (announce, connected, dests)
        };
        for iid in announce {
            let _ = handle
                .announce_now(AnnounceNow {
                    destination: me,
                    target: AnnounceTarget::Interface(iid),
                    app_data: AnnounceAppData::Data(Default::default()),
                })
                .await;
        }
        if connected {
            // Every stored linked device, at once (the periodic loop asks only for the ones not heard yet).
            for (k, d) in dests {
                let (handle, state) = (handle.clone(), state.clone());
                tokio::spawn(async move {
                    find_path(&handle, &state, k, d).await;
                });
            }
        }
    }
}

/// The periodic announce: on every interface except the entry points.
async fn announce_off_entries(handle: &PrnsNodeHandle, state: &Arc<Mutex<State>>, me: DestinationHash) {
    let ids: Vec<InterfaceId> = {
        let s = state.lock().unwrap();
        handle
            .interfaces()
            .iter()
            .map(|x| x.id)
            .filter(|id| !s.iface_entry.contains_key(id))
            .collect()
    };
    for id in ids {
        let _ = handle
            .announce_now(AnnounceNow {
                destination: me,
                target: AnnounceTarget::Interface(id),
                app_data: AnnounceAppData::Data(Default::default()),
            })
            .await;
    }
}

fn fingerprint(salt: &[u8; 32], e: &EntryPoint) -> [u8; 32] {
    let mut h = blake3::Hasher::new_keyed(salt);
    let field = |h: &mut blake3::Hasher, b: &[u8]| {
        h.update(&(b.len() as u64).to_le_bytes());
        h.update(b);
    };
    field(&mut h, e.host.as_bytes());
    field(&mut h, &e.port.to_le_bytes());
    field(&mut h, e.network_name.as_deref().unwrap_or("").as_bytes());
    field(&mut h, e.passphrase.as_ref().map_or("", |p| p.as_str()).as_bytes());
    *h.finalize().as_bytes()
}

/// Detaches an entry point's interface (dropping its routes at once) and forgets what was heard through it.
fn detach_entry(handle: &PrnsNodeHandle, s: &mut State, id: &str) {
    let Some(slot) = s.entries.get_mut(id) else { return };
    if let Some(iid) = slot.iid.take() {
        handle.forget_interface(iid);
        s.iface_entry.remove(&iid);
    }
    let me = Via::Entry(id.to_string());
    s.heard.retain(|_, v| *v != me);
}

fn attach_entry(handle: &PrnsNodeHandle, s: &mut State, e: &EntryPoint) {
    let host = if e.host.contains(':') && !e.host.starts_with('[') { format!("[{}]", e.host) } else { e.host.clone() };
    let client = TcpClientInterface::new(format!("{host}:{}", e.port));
    let name = e.network_name.clone().filter(|n| !n.is_empty());
    let pass = e.passphrase.clone().filter(|p| !p.is_empty());
    // WIDE, as Prns's config gives a TCP client and RNS's TCP default. The copy of the passphrase is wiped as it goes out of scope.
    let ifac = IfacContext::derive(name.as_deref(), pass.as_ref().map(|p| p.as_str()), IfacSize::WIDE);
    drop(pass);
    let attached = match ifac {
        Some(ifac) => handle.attach_with_ifac_name(client, ifac, name),
        None => handle.attach(client),
    };
    let iid = attached.id();
    if let Some(slot) = s.entries.get_mut(&e.id) {
        slot.iid = Some(iid);
        slot.t = Tracker { attached_at: Some(std::time::Instant::now()), ..Default::default() };
    }
    s.iface_entry.insert(iid, e.id.clone());
}

fn apply_entries(handle: &PrnsNodeHandle, state: &Arc<Mutex<State>>, salt: &[u8; 32], entries: &[EntryPoint]) {
    let mut s = state.lock().unwrap();
    let want: HashSet<&str> = entries.iter().map(|e| e.id.as_str()).collect();
    let gone: Vec<String> = s.entries.keys().filter(|k| !want.contains(k.as_str())).cloned().collect();
    for id in gone {
        detach_entry(handle, &mut s, &id);
        s.entries.remove(&id);
    }
    for e in entries {
        let fp = fingerprint(salt, e);
        // Already as wanted: same settings, and attached exactly when it is on.
        if s.entries.get(&e.id).is_some_and(|sl| sl.fp == fp && sl.iid.is_some() == e.on) {
            continue;
        }
        detach_entry(handle, &mut s, &e.id);
        s.entries.insert(e.id.clone(), Slot { fp, on: e.on, iid: None, t: Tracker::default() });
        if e.on {
            attach_entry(handle, &mut s, e);
        }
    }
}
