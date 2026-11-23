//! Reticulum for Cache (1.2 spike, not shipped): one Reticulum node per device, on Prns.
//!
//! - **Identity.** A device's Reticulum identity is derived from its iroh secret key, so there is nothing new to keep or back
//!   up, and reinstalling with the same key gives the same Reticulum address.
//! - **Vouching.** A device announces its destination with a signature by its iroh key over that destination. Only a device
//!   that already holds the key in its link list can check it, so the announce tells no one else which Cache device it is.
//! - **Requests.** Cache's requests (pairing, the index, secrets) are Reticulum link requests on paths the caller names.
//!   A request is answered only for a requester that identified itself on the link with the identity of a linked device,
//!   except on the paths the caller marks as open (pairing).
//! - **Notify.** "Something changed" goes over the link's Channel, which is acknowledged and ordered. Raw link packets are
//!   never used: they are not proven by the side that opened a link and are not retried (trial R1).

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{anyhow, bail, Context, Result};
use iroh::{PublicKey, SecretKey, Signature};
use personal_rns::identity::IdentityHash;
use personal_rns::prelude::*;
use personal_rns::routing::announce::emit::AnnounceAppDataBytes;
use personal_rns::routing::links::channel::MessageType;
use personal_rns::routing::links::LinkId;
use personal_rns::routing::request_handlers::{RequestPathHash, RequestPolicy};
use tokio::sync::mpsc;

pub mod blobs;
#[cfg(feature = "rnode")]
pub mod rnode;
#[cfg(feature = "rnode")]
pub mod standin;
pub mod pair_core;

/// Cache's Reticulum destination name: `cache.sync.v1`.
pub const APP_NAME: &str = "cache";
pub const ASPECTS: &[&str] = &["sync", "v1"];
/// The Channel message type for notifications (below 0xf000, which RNS reserves).
pub const NOTIFY_TYPE: MessageType = MessageType(0x0C01);

const IDENTITY_CONTEXT: &str =
    "cache_rns 2026-11-14 reticulum identity from the iroh device key v1";
const VOUCH_PREFIX: &[u8] = b"cache_rns vouch v1";
const ANNOUNCE_EVERY: Duration = Duration::from_secs(30);

/// The 64-byte Reticulum identity secret (X25519 then Ed25519, RNS's layout) for a device's iroh key.
pub fn identity_secret_for(device: &SecretKey) -> [u8; 64] {
    let mut out = [0u8; 64];
    blake3::Hasher::new_derive_key(IDENTITY_CONTEXT)
        .update(&device.to_bytes())
        .finalize_xof()
        .fill(&mut out);
    out
}

fn vouch_message(destination: &DestinationHash) -> Vec<u8> {
    let mut m = VOUCH_PREFIX.to_vec();
    m.extend_from_slice(destination.as_bytes());
    m
}

/// The announce data: the device key's signature over this destination.
pub fn vouch(device: &SecretKey, destination: &DestinationHash) -> [u8; 64] {
    device.sign(&vouch_message(destination)).to_bytes()
}

/// Whether `app_data` is `peer`'s vouch for `destination`.
pub fn check_vouch(peer: &PublicKey, destination: &DestinationHash, app_data: &[u8]) -> bool {
    let Ok(bytes) = <[u8; 64]>::try_from(app_data) else {
        return false;
    };
    peer.verify(&vouch_message(destination), &Signature::from_bytes(&bytes))
        .is_ok()
}

/// One network attachment.
#[derive(Debug, Clone)]
pub enum Iface {
    /// Accept TCP connections on this address (a hub, or a fixed-address peer).
    TcpListen(String),
    /// Connect to a TCP listener at this address.
    TcpConnect(String),
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
}

pub struct Config {
    pub device: SecretKey,
    pub interfaces: Vec<Iface>,
    /// Linked devices.
    pub peers: Vec<PublicKey>,
    /// Paths this device answers.
    pub paths: Vec<String>,
    /// Of those, the ones an unlinked device may ask (pairing).
    pub open_paths: Vec<String>,
    /// The largest request or response, in bytes.
    pub max_bytes: u64,
    /// Cache's blob store: when set, linked devices may fetch verified windows of its blobs ([`blobs`]).
    pub blobs: Option<iroh_blobs::api::Store>,
}

#[derive(Default)]
struct State {
    peers: HashSet<[u8; 32]>,
    /// Linked device -> its vouched destination.
    destination_of: HashMap<[u8; 32], DestinationHash>,
    /// Reticulum identity -> linked device.
    device_of_identity: HashMap<[u8; 16], PublicKey>,
    /// Link -> the identity the other end proved on it.
    identity_on_link: HashMap<LinkId, IdentityHash>,
    /// Our open link to each device.
    link_to: HashMap<[u8; 32], LinkId>,
}

enum Ev {
    Announce {
        destination: DestinationHash,
        app_data: Vec<u8>,
    },
    Identified {
        link: LinkId,
        identity: IdentityHash,
    },
    Closed {
        link: LinkId,
    },
    Request {
        token: RespondToken,
        requester: Option<IdentityHash>,
        path: RequestPathHash,
        data: Vec<u8>,
    },
    Notify {
        link: LinkId,
        data: Vec<u8>,
    },
}

pub struct RnsNode {
    handle: PrnsNodeHandle,
    me: DestinationHash,
    my_identity: IdentityHash,
    app_data: AnnounceAppDataBytes,
    /// The node's RNode interfaces (slow carriers), as Prns numbered them.
    #[cfg(feature = "rnode")]
    rnode_ifaces: Arc<Mutex<Vec<personal_rns::interfaces::InterfaceId>>>,
    state: Arc<Mutex<State>>,
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
        let (tx, mut rx) = mpsc::unbounded_channel::<Ev>();
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
                        pre_configured_destinations: [destination],
                        app_state: personal_rns::runtime::NoRemoteControlHostControls,
                        storage: GrowableHeap,
                        request_endpoints: request_endpoints![],
                        on_event: move |event, _state| {
                            let ev = match event {
                                PrnsEvent::Diagnostic(Diagnostic::AnnounceHeard {
                                    destination,
                                    app_data,
                                    ..
                                }) => Ev::Announce {
                                    destination,
                                    app_data: app_data.to_vec(),
                                },
                                PrnsEvent::Diagnostic(Diagnostic::PeerIdentified {
                                    link_id,
                                    identity,
                                }) => Ev::Identified {
                                    link: link_id,
                                    identity,
                                },
                                PrnsEvent::Diagnostic(Diagnostic::LinkClosed {
                                    link_id, ..
                                }) => Ev::Closed { link: link_id },
                                PrnsEvent::Message(Message::Request {
                                    link_id,
                                    request_id,
                                    requester,
                                    path_hash,
                                    rtt,
                                    data,
                                    ..
                                }) => Ev::Request {
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
                                _ => return,
                            };
                            let _ = tx.send(ev);
                        },
                        interfaces: move |node: &PrnsNodeHandle| {
                            for a in &clients {
                                node.attach(TcpClientInterface::new(a.clone()));
                            }
                        },
                        persistence: NoPersistence,
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
        if cfg.blobs.is_some() {
            all_paths.push(blobs::BLOB_PATH.to_string());
        }
        let store = cfg.blobs.clone();
        for p in &all_paths {
            let policy = if open.contains(p) {
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
        let my_identity = personal_rns::identity::PrivateIdentityMaterial::from_bytes(
            identity_secret_for(&cfg.device),
        )
        .identity_hash();

        let state = Arc::new(Mutex::new(State {
            peers: cfg.peers.iter().map(|p| *p.as_bytes()).collect(),
            ..Default::default()
        }));

        // Events: vouched announces, identities on links, requests, notifications.
        {
            let state = state.clone();
            let handle = handle.clone();
            tasks.push(tokio::spawn(async move {
                while let Some(ev) = rx.recv().await {
                    match ev {
                        Ev::Announce {
                            destination,
                            app_data,
                        } => {
                            if destination == me {
                                continue;
                            }
                            let peers: Vec<[u8; 32]> =
                                state.lock().unwrap().peers.iter().copied().collect();
                            let Some(peer) = peers
                                .iter()
                                .filter_map(|b| PublicKey::from_bytes(b).ok())
                                .find(|p| check_vouch(p, &destination, &app_data))
                            else {
                                continue;
                            };
                            let identity = handle.destination_identity_hash(destination).await;
                            let mut s = state.lock().unwrap();
                            s.destination_of.insert(*peer.as_bytes(), destination);
                            if let Some(id) = identity {
                                s.device_of_identity.insert(*id.as_bytes(), peer);
                            }
                        }
                        Ev::Identified { link, identity } => {
                            state
                                .lock()
                                .unwrap()
                                .identity_on_link
                                .insert(link, identity);
                        }
                        Ev::Closed { link } => {
                            let mut s = state.lock().unwrap();
                            s.identity_on_link.remove(&link);
                            s.link_to.retain(|_, l| *l != link);
                        }
                        Ev::Request {
                            token,
                            requester,
                            path,
                            data,
                        } => {
                            let Some(name) = paths
                                .iter()
                                .find(|(h, _)| *h == path)
                                .map(|(_, n)| n.clone())
                            else {
                                continue;
                            };
                            let asker = {
                                let s = state.lock().unwrap();
                                let id = requester
                                    .or_else(|| s.identity_on_link.get(&token.link_id).copied());
                                id.and_then(|i| s.device_of_identity.get(i.as_bytes()).copied())
                                    .filter(|p| s.peers.contains(p.as_bytes()))
                                    .map(Asker::Linked)
                                    .unwrap_or(Asker::Unlinked)
                            };
                            if asker == Asker::Unlinked && !open.contains(&name) {
                                // Not linked, and not an open path: no answer at all, as the iroh gate refuses the connection.
                                continue;
                            }
                            if name == blobs::BLOB_PATH {
                                // Built in: only for linked devices (the path is never open).
                                let (Some(store), Asker::Linked(_)) = (store.clone(), asker) else {
                                    continue;
                                };
                                let handle = handle.clone();
                                tokio::spawn(async move {
                                    let reply = blobs::serve_window(&store, &data).await;
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
                                s.identity_on_link
                                    .get(&link)
                                    .and_then(|i| s.device_of_identity.get(i.as_bytes()).copied())
                                    .filter(|p| s.peers.contains(p.as_bytes()))
                            };
                            if let Some(from) = from {
                                handler.notify(from, data);
                            }
                        }
                    }
                }
            }));
        }

        // Announces: at start, then every 30 s.
        {
            let handle = handle.clone();
            let app_data = announce_data(&cfg.device, &me)?;
            tasks.push(tokio::spawn(async move {
                let mut tick = tokio::time::interval(ANNOUNCE_EVERY);
                loop {
                    tick.tick().await;
                    let _ = handle
                        .announce_now(AnnounceNow {
                            destination: me,
                            target: AnnounceTarget::AllInterfaces,
                            app_data: AnnounceAppData::Data(app_data.clone()),
                        })
                        .await;
                }
            }));
        }

        let app_data = announce_data(&cfg.device, &me)?;
        Ok(RnsNode {
            handle,
            me,
            my_identity,
            app_data,
            #[cfg(feature = "rnode")]
            rnode_ifaces: rnode_ids,
            state,
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

    /// Replaces the list of linked devices.
    pub fn set_peers(&self, peers: &[PublicKey]) {
        let mut s = self.state.lock().unwrap();
        s.peers = peers.iter().map(|p| *p.as_bytes()).collect();
        let keep = s.peers.clone();
        s.destination_of.retain(|k, _| keep.contains(k));
        s.device_of_identity
            .retain(|_, p| keep.contains(p.as_bytes()));
        s.link_to.retain(|k, _| keep.contains(k));
    }

    /// Whether a vouched announce from `peer` has been heard.
    pub fn knows(&self, peer: &PublicKey) -> bool {
        self.state
            .lock()
            .unwrap()
            .destination_of
            .contains_key(peer.as_bytes())
    }

    /// Announces now (for example after a network change).
    pub async fn announce(&self) -> Result<()> {
        self.handle
            .announce_now(AnnounceNow {
                destination: self.me,
                target: AnnounceTarget::AllInterfaces,
                app_data: AnnounceAppData::Data(self.app_data.clone()),
            })
            .await
            .map_err(|e| anyhow!("{e:?}"))
    }

    async fn link_to(&self, peer: &PublicKey) -> Result<LinkId> {
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
            .ok_or_else(|| anyhow!("not reachable over Reticulum (no announce heard)"))?;
        let link = self
            .handle
            .establish_link(destination)
            .await
            .map_err(|e| anyhow!("not reachable: {e:?}"))?;
        self.handle
            .identify(link, self.my_identity)
            .await
            .map_err(|e| anyhow!("could not identify on the link: {e:?}"))?;
        self.state
            .lock()
            .unwrap()
            .link_to
            .insert(*peer.as_bytes(), link);
        Ok(link)
    }

    fn forget_link(&self, peer: &PublicKey) {
        self.state.lock().unwrap().link_to.remove(peer.as_bytes());
    }

    /// Asks a linked device on `path`.
    pub async fn request(
        &self,
        peer: &PublicKey,
        path: &str,
        body: &[u8],
        timeout: Duration,
    ) -> Result<Vec<u8>> {
        let link = self.link_to(peer).await?;
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
            Ok(Ok((reply, _rtt))) => unpack_bin(reply),
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
        let link = self.link_to(peer).await?;
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

fn announce_data(device: &SecretKey, me: &DestinationHash) -> Result<AnnounceAppDataBytes> {
    AnnounceAppDataBytes::from_slice(&vouch(device, me))
        .map_err(|_| anyhow!("the vouch does not fit in an announce"))
}

/// Responses travel as a msgpack value, as RNS packs them; `respond_bytes` sends a msgpack bin. Unwraps it.
fn unpack_bin(packed: Vec<u8>) -> Result<Vec<u8>> {
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
