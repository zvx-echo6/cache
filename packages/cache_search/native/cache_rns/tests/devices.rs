//! Three real Prns nodes in one process over loopback TCP: A listens; B (linked both ways) and C (unlinked) connect.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use cache_rns::{
    check_vouch, destination_for, identity_hash_for, identity_secret_for, vouch, Asker, BoxFut,
    Config, Handler, Iface, RnsNode, Via,
};
use iroh::{PublicKey, SecretKey};

const BIG: usize = 8 * 1024 * 1024;

#[derive(Default)]
struct Rec {
    notes: Mutex<Vec<(PublicKey, Vec<u8>)>>,
}

impl Handler for Rec {
    fn request(&self, asker: Asker, path: &str, body: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        let path = path.to_string();
        Box::pin(async move {
            if path == "/cache/big" {
                return Ok((0..BIG).map(|i| (i % 251) as u8).collect());
            }
            let who = match asker {
                Asker::Linked(p) => format!("linked:{}", p.fmt_short()),
                Asker::Unlinked => "unlinked".to_string(),
            };
            Ok(format!("{path} {who} {}", body.len()).into_bytes())
        })
    }
    fn notify(&self, from: PublicKey, body: Vec<u8>) {
        self.notes.lock().unwrap().push((from, body));
    }
}

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// A linked device as `Config` lists it: its key and its stored Reticulum destination.
fn peer(k: &SecretKey) -> (PublicKey, Option<personal_rns::prelude::DestinationHash>) {
    (k.public(), Some(destination_for(k).unwrap()))
}

fn cfg(device: &SecretKey, iface: Iface, peers: Vec<&SecretKey>) -> Config {
    Config {
        device: device.clone(),
        interfaces: vec![iface],
        peers: peers.into_iter().map(peer).collect(),
        wifi_group: None,
        paths: vec![
            "/cache/index".into(),
            "/cache/pair".into(),
            "/cache/big".into(),
        ],
        open_paths: vec!["/cache/pair".into()],
        max_bytes: 64 * 1024 * 1024,
        blobs: None,
        pair_local_tcp: false,
    }
}

async fn until(
    what: &str,
    secs: u64,
    mut f: impl FnMut() -> bool,
    mut kick: impl FnMut() -> BoxFut<()>,
) {
    let end = Instant::now() + Duration::from_secs(secs);
    while !f() {
        assert!(Instant::now() < end, "{what} within {secs} s");
        kick().await;
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

#[test]
fn identity_is_derived_and_vouched() {
    let a = SecretKey::generate();
    let b = SecretKey::generate();
    assert_eq!(
        identity_secret_for(&a),
        identity_secret_for(&a),
        "same device key, same identity"
    );
    assert_ne!(identity_secret_for(&a), identity_secret_for(&b));
    // The vouch (the hello's signature) is over the Reticulum identity the link proved.
    let id = identity_hash_for(&a);
    let other = identity_hash_for(&b);
    assert_ne!(id, other);
    let v = vouch(&a, &id);
    assert!(check_vouch(&a.public(), &id, &v));
    assert!(
        !check_vouch(&b.public(), &id, &v),
        "another device's key does not accept it"
    );
    assert!(
        !check_vouch(&a.public(), &other, &v),
        "a vouch for another identity is refused"
    );
    assert!(!check_vouch(&a.public(), &id, &v[..63]));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn linked_unlinked_notify_and_big() {
    let (ka, kb, kc) = (
        SecretKey::generate(),
        SecretKey::generate(),
        SecretKey::generate(),
    );
    let port = free_port();
    let ra = Arc::new(Rec::default());
    let a = Arc::new(
        RnsNode::start(
            cfg(
                &ka,
                Iface::TcpListen(format!("127.0.0.1:{port}")),
                vec![&kb],
            ),
            ra.clone(),
        )
        .await
        .unwrap(),
    );
    let b = Arc::new(
        RnsNode::start(
            cfg(
                &kb,
                Iface::TcpConnect(format!("127.0.0.1:{port}")),
                vec![&ka],
            ),
            Arc::new(Rec::default()),
        )
        .await
        .unwrap(),
    );
    // C believes A is linked; A does not list C.
    let c = Arc::new(
        RnsNode::start(
            cfg(
                &kc,
                Iface::TcpConnect(format!("127.0.0.1:{port}")),
                vec![&ka],
            ),
            Arc::new(Rec::default()),
        )
        .await
        .unwrap(),
    );

    let (a2, b2, c2) = (a.clone(), b.clone(), c.clone());
    until(
        "B and C hear A, A hears B",
        20,
        || b.reachable(&ka.public()) && c.reachable(&ka.public()) && a.reachable(&kb.public()),
        move || {
            let (a2, b2, c2) = (a2.clone(), b2.clone(), c2.clone());
            Box::pin(async move {
                let _ = a2.announce().await;
                let _ = b2.announce().await;
                let _ = c2.announce().await;
            })
        },
    )
    .await;
    assert!(
        !a.reachable(&kc.public()),
        "A has no destination stored for C, so C's announce marks nothing"
    );

    // A linked device is answered, and as itself.
    let t = Instant::now();
    let r = b
        .request(
            &ka.public(),
            "/cache/index",
            b"hello",
            Duration::from_secs(10),
        )
        .await
        .unwrap();
    let r = String::from_utf8(r).unwrap();
    assert_eq!(
        r,
        format!("/cache/index linked:{} 5", kb.public().fmt_short())
    );
    println!("linked request answered in {} ms", t.elapsed().as_millis());

    // An unlinked device gets no answer on a closed path.
    let r = c
        .request(
            &ka.public(),
            "/cache/index",
            b"hello",
            Duration::from_secs(5),
        )
        .await;
    assert!(
        r.is_err(),
        "C must not be answered on /cache/index, got {r:?}"
    );

    // ... but is answered, as unlinked, on the open pairing path.
    let r = c
        .request_unlinked(
            a.destination(),
            "/cache/pair",
            b"code",
            Duration::from_secs(10),
        )
        .await
        .unwrap();
    assert_eq!(String::from_utf8(r).unwrap(), "/cache/pair unlinked 4");

    // Notify arrives, from B.
    b.notify(&ka.public(), b"changed").await.unwrap();
    until(
        "A gets the notify",
        10,
        || !ra.notes.lock().unwrap().is_empty(),
        || Box::pin(async {}),
    )
    .await;
    let n = ra.notes.lock().unwrap()[0].clone();
    assert_eq!(n, (kb.public(), b"changed".to_vec()));

    // A large answer (the index can be big) comes back whole.
    let t = Instant::now();
    let r = b
        .request(&ka.public(), "/cache/big", b"", Duration::from_secs(60))
        .await
        .unwrap();
    assert_eq!(r.len(), BIG);
    assert!(r.iter().enumerate().all(|(i, x)| *x == (i % 251) as u8));
    println!("8 MiB answer in {} ms", t.elapsed().as_millis());

    // Unlinking B on A: B is no longer answered.
    a.set_peers(&[]);
    let r = b
        .request(
            &ka.public(),
            "/cache/index",
            b"again",
            Duration::from_secs(5),
        )
        .await;
    assert!(r.is_err(), "B was unlinked on A, got {r:?}");
}

// ---- The hello gate, with a raw Prns node that sends whatever it likes ----

mod raw {
    use super::*;
    use personal_rns::prelude::*;
    use personal_rns::routing::links::LinkId;
    use personal_rns::routing::request_handlers::RequestPathHash;

    /// Announces a raw node heard: destination and app data.
    pub type Heard = Arc<Mutex<Vec<(DestinationHash, Vec<u8>)>>>;

    pub struct Raw {
        pub handle: PrnsNodeHandle,
        pub identity: personal_rns::identity::IdentityHash,
        pub heard: Heard,
        _stop: tokio::sync::oneshot::Sender<()>,
    }

    /// A Reticulum node whose identity is the one derived from `key`, connected to `127.0.0.1:port`.
    pub fn start(key: &SecretKey, port: u16) -> Raw {
        let heard: Heard = Arc::default();
        let h2 = heard.clone();
        let secret = identity_secret_for(key);
        let (tx, rx) = std::sync::mpsc::channel();
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
                        app_name: "cache",
                        aspects: &["sync", "v1"],
                        identity: Zeroizing::new(secret),
                        announce_app_data: b"",
                        proof: ProofStrategy::ProveAll,
                        link_requests: LinkRequestPolicy::AcceptAll,
                        ratchet: RatchetPolicy::NoRatchets,
                        request_endpoints: ServeMyRequestEndpoints::No,
                    };
                    let node = PrnsNode::new(PrnsNodeRecipe {
                        transport_identity: None,
                        remote_control: RemoteControlService::Unavailable.into(),
                        pre_configured_destinations: [destination],
                        app_state: personal_rns::runtime::NoRemoteControlHostControls,
                        storage: GrowableHeap,
                        request_endpoints: request_endpoints![],
                        on_event: move |event, _state| {
                            if let PrnsEvent::Diagnostic(Diagnostic::AnnounceHeard {
                                destination,
                                app_data,
                                ..
                            }) = event
                            {
                                h2.lock().unwrap().push((destination, app_data.to_vec()));
                            }
                        },
                        interfaces: move |node: &PrnsNodeHandle| {
                            node.attach(TcpClientInterface::new(format!("127.0.0.1:{port}")));
                        },
                        persistence: NoPersistence,
                    });
                    tx.send(node.handle()).unwrap();
                    tokio::select! {
                        _ = node.run() => {}
                        _ = stop_rx => {}
                    }
                });
            })
            .unwrap();
        Raw {
            handle: rx.recv().unwrap(),
            identity: identity_hash_for(key),
            heard,
            _stop: stop_tx,
        }
    }

    fn exact(t: Duration) -> personal_rns::engine::RequestResponseTimeout {
        personal_rns::engine::RequestResponseTimeout::Exact(personal_rns::units::DurationMillis(
            t.as_millis() as u64,
        ))
    }

    /// A transport node standing in for rnsd: listens on `listen` (for A) and connects to `connect` (B's listener),
    /// with Reticulum transport on. It has no direct role in Cache's traffic.
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

    impl Raw {
        pub fn heard_from(&self, d: DestinationHash) -> Option<Vec<u8>> {
            self.heard.lock().unwrap().iter().find(|(x, _)| *x == d).map(|(_, a)| a.clone())
        }
        /// Opens a link to `dest` and identifies on it with this node's identity.
        pub async fn link(&self, dest: DestinationHash) -> LinkId {
            let link = self.handle.establish_link(dest).await.expect("link");
            self.handle.identify(link, self.identity).await.expect("identify");
            link
        }
        /// Whether the request was answered within `secs`.
        pub async fn ask(&self, link: LinkId, path: &str, body: &[u8], secs: u64) -> bool {
            matches!(
                tokio::time::timeout(
                    Duration::from_secs(secs + 1),
                    self.handle.request_with_response_timeout(
                        link,
                        RequestPathHash::of(path),
                        body,
                        exact(Duration::from_secs(secs)),
                    ),
                )
                .await,
                Ok(Ok(_))
            )
        }
        /// The answer's bytes (as sent: a msgpack byte string), or None when it was not answered within `secs`.
        pub async fn reply(&self, link: LinkId, path: &str, body: &[u8], secs: u64) -> Option<Vec<u8>> {
            match tokio::time::timeout(
                Duration::from_secs(secs + 1),
                self.handle.request_with_response_timeout(link, RequestPathHash::of(path), body, exact(Duration::from_secs(secs))),
            )
            .await
            {
                Ok(Ok((r, _))) => Some(r.to_vec()),
                _ => None,
            }
        }
        pub async fn notify(&self, link: LinkId, body: &[u8]) {
            let _ = self.handle.send_channel_message(link, cache_rns::NOTIFY_TYPE, body).await;
        }
    }
}

/// The hello body a device sends: its key, then its vouch for `identity`.
fn hello(device: &SecretKey, signer: &SecretKey, identity: &personal_rns::identity::IdentityHash) -> Vec<u8> {
    let mut b = device.public().as_bytes().to_vec();
    b.extend_from_slice(&vouch(signer, identity));
    b
}

struct Gate {
    ka: SecretKey,
    kb: SecretKey,
    port: u16,
    rec: Arc<Rec>,
    a: RnsNode,
    _dir: tempfile::TempDir,
}

/// A: listens, lists B only, has a blob store and the usual paths.
async fn gate() -> Gate {
    let (ka, kb) = (SecretKey::generate(), SecretKey::generate());
    let port = free_port();
    let dir = tempfile::tempdir().unwrap();
    let store = iroh_blobs::store::fs::FsStore::load(dir.path().join("blobs")).await.unwrap();
    let rec = Arc::new(Rec::default());
    let mut c = cfg(&ka, Iface::TcpListen(format!("127.0.0.1:{port}")), vec![&kb]);
    c.blobs = Some((*store).clone());
    let a = RnsNode::start(c, rec.clone()).await.unwrap();
    Gate { ka, kb, port, rec, a, _dir: dir }
}

impl Gate {
    /// A raw node with the identity of `key` that has heard A.
    async fn client(&self, key: &SecretKey) -> raw::Raw {
        let r = raw::start(key, self.port);
        let dest = destination_for(&self.ka).unwrap();
        let end = Instant::now() + Duration::from_secs(20);
        while r.heard_from(dest).is_none() {
            assert!(Instant::now() < end, "the raw node hears A within 20 s");
            let _ = self.a.announce().await;
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        r
    }
    fn dest(&self) -> personal_rns::prelude::DestinationHash {
        destination_for(&self.ka).unwrap()
    }
}

const NOT_ANSWERED: u64 = 3;

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn announce_app_data_is_empty() {
    let g = gate().await;
    let r = g.client(&SecretKey::generate()).await;
    assert_eq!(
        r.heard_from(g.dest()).unwrap(),
        Vec::<u8>::new(),
        "an announce carries no app data: no name, no signature"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hello_naming_a_non_peer_gets_nothing() {
    let g = gate().await;
    let kx = SecretKey::generate();
    let r = g.client(&kx).await;
    let link = r.link(g.dest()).await;
    // A valid hello, for a device A does not list.
    let h = hello(&kx, &kx, &r.identity);
    assert!(!r.ask(link, cache_rns::HELLO_PATH, &h, NOT_ANSWERED).await, "no answer to the hello");
    assert!(!r.ask(link, "/cache/index", b"x", NOT_ANSWERED).await, "no answer on /cache/index");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hello_with_a_wrong_signature_gets_nothing() {
    let g = gate().await;
    // B's identity and key, but the signature is another device's.
    let r = g.client(&g.kb).await;
    let link = r.link(g.dest()).await;
    let h = hello(&g.kb, &SecretKey::generate(), &r.identity);
    assert!(!r.ask(link, cache_rns::HELLO_PATH, &h, NOT_ANSWERED).await);
    assert!(!r.ask(link, "/cache/index", b"x", NOT_ANSWERED).await);
    // B's own hello, replayed on a link that proved some other identity, is refused too.
    let kx = SecretKey::generate();
    let rx = g.client(&kx).await;
    let link = rx.link(g.dest()).await;
    let h = hello(&g.kb, &g.kb, &identity_hash_for(&g.kb));
    assert!(!rx.ask(link, cache_rns::HELLO_PATH, &h, NOT_ANSWERED).await);
    assert!(!rx.ask(link, "/cache/index", b"x", NOT_ANSWERED).await);
    // A truncated hello is nothing.
    let r = g.client(&g.kb).await;
    let link = r.link(g.dest()).await;
    let h = hello(&g.kb, &g.kb, &r.identity);
    assert!(!r.ask(link, cache_rns::HELLO_PATH, &h[..90], NOT_ANSWERED).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn no_hello_means_nothing() {
    let g = gate().await;
    // B's identity, linked and identified, but no hello.
    let r = g.client(&g.kb).await;
    let link = r.link(g.dest()).await;
    let blob_want = vec![0u8; 48];
    assert!(!r.ask(link, "/cache/index", b"x", NOT_ANSWERED).await, "index refused");
    assert!(!r.ask(link, cache_rns::blobs::BLOB_PATH, &blob_want, NOT_ANSWERED).await, "blobs refused");
    r.notify(link, b"changed").await;
    tokio::time::sleep(Duration::from_secs(2)).await;
    assert!(g.rec.notes.lock().unwrap().is_empty(), "notify refused");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_correct_hello_opens_everything() {
    let g = gate().await;
    let r = g.client(&g.kb).await;
    let link = r.link(g.dest()).await;
    let h = hello(&g.kb, &g.kb, &r.identity);
    assert!(r.ask(link, cache_rns::HELLO_PATH, &h, 10).await, "the hello is answered");
    assert!(r.ask(link, "/cache/index", b"x", 10).await, "index answered");
    assert!(r.ask(link, cache_rns::blobs::BLOB_PATH, &[0u8; 48], 10).await, "blobs answered");
    r.notify(link, b"changed").await;
    let end = Instant::now() + Duration::from_secs(10);
    while g.rec.notes.lock().unwrap().is_empty() {
        assert!(Instant::now() < end, "notify arrives");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    assert_eq!(g.rec.notes.lock().unwrap()[0], (g.kb.public(), b"changed".to_vec()));
}

/// A msgpack byte string, as an answer travels.
fn bin(b: &[u8]) -> Vec<u8> {
    let mut v = vec![0xc4, b.len() as u8];
    v.extend_from_slice(b);
    v
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn hello_of_a_former_device_is_told_not_linked() {
    let g = gate().await;
    // Linked: "ok".
    let r = g.client(&g.kb).await;
    let link = r.link(g.dest()).await;
    let h = hello(&g.kb, &g.kb, &r.identity);
    assert_eq!(r.reply(link, cache_rns::HELLO_PATH, &h, 10).await, Some(bin(b"ok")), "a linked device gets ok");
    // Unlinked (and remembered as a former device): "not linked", and nothing else is opened.
    g.a.set_peers(&[]);
    g.a.set_former(&[g.kb.public()]);
    let r = g.client(&g.kb).await;
    let link = r.link(g.dest()).await;
    let h = hello(&g.kb, &g.kb, &r.identity);
    assert_eq!(r.reply(link, cache_rns::HELLO_PATH, &h, 10).await, Some(bin(b"not linked")));
    assert!(!r.ask(link, "/cache/index", b"x", NOT_ANSWERED).await, "no answer on /cache/index after not linked");
    // A bad signature from the former device still gets nothing.
    let r = g.client(&g.kb).await;
    let link = r.link(g.dest()).await;
    let h = hello(&g.kb, &SecretKey::generate(), &r.identity);
    assert_eq!(r.reply(link, cache_rns::HELLO_PATH, &h, NOT_ANSWERED).await, None, "a bad signature gets no answer");
    // A truncated hello gets nothing.
    let r = g.client(&g.kb).await;
    let link = r.link(g.dest()).await;
    let h = hello(&g.kb, &g.kb, &r.identity);
    assert_eq!(r.reply(link, cache_rns::HELLO_PATH, &h[..90], NOT_ANSWERED).await, None, "a short hello gets no answer");
    // A stranger with a valid signature over its own key gets nothing.
    let kx = SecretKey::generate();
    let r = g.client(&kx).await;
    let link = r.link(g.dest()).await;
    let h = hello(&kx, &kx, &r.identity);
    assert_eq!(r.reply(link, cache_rns::HELLO_PATH, &h, NOT_ANSWERED).await, None, "a stranger gets no answer");
    // Linked again: "ok" again.
    g.a.set_peers(&[(g.kb.public(), Some(destination_for(&g.kb).unwrap()))]);
    g.a.set_former(&[]);
    let r = g.client(&g.kb).await;
    let link = r.link(g.dest()).await;
    let h = hello(&g.kb, &g.kb, &r.identity);
    assert_eq!(r.reply(link, cache_rns::HELLO_PATH, &h, 10).await, Some(bin(b"ok")));
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_request_to_a_device_that_unlinked_it_fails_as_not_linked() {
    let (ka, kb) = (SecretKey::generate(), SecretKey::generate());
    let port = free_port();
    let a = Arc::new(RnsNode::start(cfg(&ka, Iface::TcpListen(format!("127.0.0.1:{port}")), vec![]), Arc::new(Rec::default())).await.unwrap());
    let b = Arc::new(RnsNode::start(cfg(&kb, Iface::TcpConnect(format!("127.0.0.1:{port}")), vec![&ka]), Arc::new(Rec::default())).await.unwrap());
    let (a2, b2) = (a.clone(), b.clone());
    until(
        "B hears A",
        20,
        || b.reachable(&ka.public()),
        move || {
            let (a2, b2) = (a2.clone(), b2.clone());
            Box::pin(async move {
                let _ = a2.announce().await;
                let _ = b2.announce().await;
            })
        },
    )
    .await;
    // A has never linked B: the request gets no answer, and is not "not linked".
    let e = b.request(&ka.public(), "/cache/index", b"x", Duration::from_secs(3)).await.unwrap_err();
    assert!(!cache_rns::is_not_linked(&e), "a stranger is not told: {e:#}");
    // A used to be linked with B.
    a.set_former(&[kb.public()]);
    let e = b.request(&ka.public(), "/cache/index", b"x", Duration::from_secs(5)).await.unwrap_err();
    assert!(cache_rns::is_not_linked(&e), "told not linked: {e:#}");
}

// ---- Wi-Fi auto discovery ----

/// Two nodes on this host, each with only `Iface::WifiAuto` and no address anywhere, find each other and talk.
/// It uses Prns's fixed discovery and rendezvous ports and the host's network interface, so it is not run by default:
/// `cargo test -p cache_rns --test devices -- --ignored wifi_auto`. (Run by hand on cache-build-1, 2026-11-23.)
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "needs a real NIC with link-local multicast; run by hand with --ignored"]
async fn wifi_auto_finds_the_peer_with_no_address() {
    let (ka, kb) = (SecretKey::generate(), SecretKey::generate());
    let a = Arc::new(
        RnsNode::start(cfg(&ka, Iface::WifiAuto, vec![&kb]), Arc::new(Rec::default())).await.unwrap(),
    );
    let b = Arc::new(
        RnsNode::start(cfg(&kb, Iface::WifiAuto, vec![&ka]), Arc::new(Rec::default())).await.unwrap(),
    );
    println!("A's Wi-Fi addresses: {:?}", a.wifi_local_addresses());
    let (a2, b2) = (a.clone(), b.clone());
    until(
        "A and B hear each other over Wi-Fi auto",
        60,
        || a.reachable(&kb.public()) && b.reachable(&ka.public()),
        move || {
            let (a2, b2) = (a2.clone(), b2.clone());
            Box::pin(async move {
                let _ = a2.announce().await;
                let _ = b2.announce().await;
            })
        },
    )
    .await;
    // On ONE host Prns joins the two nodes through its loopback TCP rendezvous (the interfaces are TcpClient and
    // TcpServerPeer), so the route is not reported as Wi-Fi here; across two machines it is a WifiPeer.
    println!(
        "members: A {} B {}; route kinds: A->B {:?}, B->A {:?}",
        a.wifi_members(),
        b.wifi_members(),
        a.via(&kb.public()),
        b.via(&ka.public())
    );
    assert!(a.wifi_members() > 0 && b.wifi_members() > 0);
    let r = b
        .request(&ka.public(), "/cache/index", b"hi", Duration::from_secs(20))
        .await
        .unwrap();
    assert_eq!(
        String::from_utf8(r).unwrap(),
        format!("/cache/index linked:{} 2", kb.public().fmt_short())
    );
}

// ---- Standard transport: A reaches B only through a transport node ----

/// A connects to a transport node (standing in for rnsd), which connects to B. There is no A-to-B connection. A reaches
/// B with the hello, a request and a notify, and learns B's route from announces or a standard path request.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn routed_through_a_transport_node() {
    let (ka, kb) = (SecretKey::generate(), SecretKey::generate());
    let (port_b, port_mid) = (free_port(), free_port());
    let rb = Arc::new(Rec::default());
    let b = Arc::new(
        RnsNode::start(cfg(&kb, Iface::TcpListen(format!("127.0.0.1:{port_b}")), vec![&ka]), rb.clone())
            .await
            .unwrap(),
    );
    let _mid = raw::transport(port_mid, port_b);
    let a = Arc::new(
        RnsNode::start(
            cfg(&ka, Iface::TcpConnect(format!("127.0.0.1:{port_mid}")), vec![&kb]),
            Arc::new(Rec::default()),
        )
        .await
        .unwrap(),
    );
    let (a2, b2) = (a.clone(), b.clone());
    until(
        "A has a route to B through the transport node",
        30,
        || a.reachable(&kb.public()),
        move || {
            let (a2, b2) = (a2.clone(), b2.clone());
            Box::pin(async move {
                let _ = a2.announce().await;
                let _ = b2.announce().await;
            })
        },
    )
    .await;
    assert_eq!(a.via(&kb.public()), Some(Via::Other));
    let r = a
        .request(&kb.public(), "/cache/index", b"routed", Duration::from_secs(20))
        .await
        .unwrap();
    assert_eq!(
        String::from_utf8(r).unwrap(),
        format!("/cache/index linked:{} 6", ka.public().fmt_short())
    );
    a.notify(&kb.public(), b"changed").await.unwrap();
    until(
        "B gets the notify",
        10,
        || !rb.notes.lock().unwrap().is_empty(),
        || Box::pin(async {}),
    )
    .await;
    assert_eq!(rb.notes.lock().unwrap()[0], (ka.public(), b"changed".to_vec()));
}
