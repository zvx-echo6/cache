//! Entry points (step 4): rnsds the person enters, added, switched off, edited and removed on the running node, with stand-in
//! rnsds (Prns transport nodes keyed with IFAC, on loopback) in place of the real thing. The real rnsd run is the `#[ignore]`d
//! test at the end, run by hand on cache-build-1.

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use cache_rns::{
    destination_for, Asker, BoxFut, Config, EntryPoint, EntryState, Handler, Iface, RnsNode, Via,
};
use iroh::{PublicKey, SecretKey};
use personal_rns::interfaces::{IfacContext, IfacSize};
use personal_rns::prelude::*;

fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port()
}

#[derive(Default)]
struct Rec {
    closed: Mutex<Vec<PublicKey>>,
}
impl Handler for Rec {
    fn request(&self, _: Asker, _: &str, body: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        Box::pin(async move { Ok(body) })
    }
    fn notify(&self, _: PublicKey, _: Vec<u8>) {}
    fn link_closed(&self, peer: PublicKey, _: &str, _: Option<u64>, _: Option<u64>) {
        self.closed.lock().unwrap().push(peer);
    }
}

fn peer(k: &SecretKey) -> (PublicKey, Option<DestinationHash>) {
    (k.public(), Some(destination_for(k).unwrap()))
}

fn config(device: &SecretKey, interfaces: Vec<Iface>, peers: Vec<&SecretKey>) -> Config {
    Config {
        device: device.clone(),
        interfaces,
        peers: peers.into_iter().map(peer).collect(),
        wifi_group: None,
        paths: vec!["/x".to_string()],
        open_paths: vec![],
        max_bytes: 64 * 1024 * 1024,
        blobs: None,
        pair_local_tcp: false,
    }
}

fn entry(id: &str, port: u16, name: Option<&str>, pass: Option<&str>, on: bool) -> EntryPoint {
    EntryPoint {
        id: id.to_string(),
        host: "127.0.0.1".to_string(),
        port,
        network_name: name.map(str::to_string),
        passphrase: pass.map(|p| Zeroizing::new(p.to_string())),
        on,
    }
}

async fn start(device: &SecretKey, interfaces: Vec<Iface>, peers: Vec<&SecretKey>) -> (RnsNode, Arc<Rec>) {
    let rec = Arc::new(Rec::default());
    let n = RnsNode::start(config(device, interfaces, peers), rec.clone()).await.unwrap();
    (n, rec)
}

/// A stand-in for an rnsd: a Prns node with transport on, the announces it hears recorded.
struct StandIn {
    heard: Arc<Mutex<Vec<DestinationHash>>>,
    stop: Option<tokio::sync::oneshot::Sender<()>>,
}

impl StandIn {
    /// A TCP server on `port`, keyed with IFAC `(name, passphrase)` when given; `chatty` makes it announce a destination of its own
    /// every second (so bytes keep arriving on a client's connection, as on an rnsd with traffic).
    fn server(port: u16, ifac: Option<(&str, &str)>, chatty: bool) -> StandIn {
        Self::spawn(Some(port), ifac.map(|(n, p)| (n.to_string(), p.to_string())), None, chatty)
    }

    /// A plain TCP client of `connect`, standing in for a device on a local network.
    fn client(connect: u16) -> StandIn {
        Self::spawn(None, None, Some(connect), false)
    }

    fn spawn(listen: Option<u16>, ifac: Option<(String, String)>, connect: Option<u16>, chatty: bool) -> StandIn {
        let heard: Arc<Mutex<Vec<DestinationHash>>> = Arc::default();
        let h2 = heard.clone();
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
                        transport_identity: listen.map(|_| try_generate_identity_secret().unwrap()),
                        remote_control: RemoteControlService::Unavailable.into(),
                        pre_configured_destinations: [destination],
                        app_state: personal_rns::runtime::NoRemoteControlHostControls,
                        storage: GrowableHeap,
                        request_endpoints: request_endpoints![],
                        on_event: move |event, _state| {
                            if let PrnsEvent::Diagnostic(Diagnostic::AnnounceHeard { destination, .. }) = event {
                                h2.lock().unwrap().push(destination);
                            }
                        },
                        interfaces: move |node: &PrnsNodeHandle| {
                            if let Some(p) = connect {
                                node.attach(TcpClientInterface::new(format!("127.0.0.1:{p}")));
                            }
                        },
                        persistence: NoPersistence,
                    });
                    let handle = node.handle();
                    let _guard = if let Some(p) = listen {
                        let server = TcpServer::bind(format!("127.0.0.1:{p}")).await.unwrap();
                        Some(match ifac {
                            Some((n, k)) => {
                                let ctx = IfacContext::derive(Some(&n), Some(&k), IfacSize::WIDE).unwrap();
                                handle.supervise_with_ifac_name(server, ctx, Some(n))
                            }
                            None => handle.supervise(server),
                        })
                    } else {
                        None
                    };
                    if chatty {
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
                    }
                    ready_tx.send(()).unwrap();
                    tokio::select! {
                        _ = node.run() => {}
                        _ = stop_rx => {}
                    }
                });
            })
            .unwrap();
        ready_rx.recv().unwrap();
        StandIn { heard, stop: Some(stop_tx) }
    }

    /// How many times this stand-in heard an announce of `d`.
    fn heard_of(&self, d: DestinationHash) -> usize {
        self.heard.lock().unwrap().iter().filter(|x| **x == d).count()
    }

    fn stop(&mut self) {
        if let Some(s) = self.stop.take() {
            let _ = s.send(());
        }
    }
}

async fn until(what: &str, secs: u64, mut f: impl FnMut() -> bool) {
    let end = Instant::now() + Duration::from_secs(secs);
    while !f() {
        assert!(Instant::now() < end, "{what} within {secs} s");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
}

fn state_of(n: &RnsNode, id: &str) -> Option<EntryState> {
    n.entry_status().into_iter().find(|(i, _, _)| i == id).map(|(_, s, _)| s)
}

const NAME1: &str = "cache-test-one";
const PASS1: &str = "pass-one-test-value";
const NAME2: &str = "cache-test-two";
const PASS2: &str = "pass-two-test-value";

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn entry_points_attach_off_edit_remove_without_a_restart() {
    let (p1, p2, p3) = (free_port(), free_port(), free_port());
    let (_s1, _s2, _s3) = (
        StandIn::server(p1, Some((NAME1, PASS1)), true),
        StandIn::server(p2, Some((NAME2, PASS2)), true),
        StandIn::server(p3, None, false),
    );
    let (ka, kb, kc) = (SecretKey::generate(), SecretKey::generate(), SecretKey::generate());
    // A is the node under test: on S3 from the start (an interface the entry changes must not touch) and linked to B and C.
    let (a, ra) = start(&ka, vec![Iface::TcpConnect(format!("127.0.0.1:{p3}"))], vec![&kb, &kc]).await;
    // B reaches S1 as an entry point given at start; C is on S3 like A.
    let (_b, _) = start(&kb, vec![Iface::Entry(entry("b1", p1, Some(NAME1), Some(PASS1), true))], vec![&ka]).await;
    let (_c, _) = start(&kc, vec![Iface::TcpConnect(format!("127.0.0.1:{p3}"))], vec![&ka]).await;
    let me = a.destination();
    assert!(a.entry_status().is_empty());

    // The unrelated interface works, and a link over it is made now: it must survive every change below.
    until("A hears C on S3", 40, || a.reachable(&kc.public())).await;
    assert_eq!(a.request(&kc.public(), "/x", b"one", Duration::from_secs(20)).await.unwrap(), b"one");

    // Add: attached, connected, and B is found through it.
    a.set_entry_points(&[entry("e1", p1, Some(NAME1), Some(PASS1), true)]);
    until("e1 connected", 30, || state_of(&a, "e1") == Some(EntryState::Connected)).await;
    until("A finds B through e1", 40, || a.via(&kb.public()) == Some(Via::Entry("e1".to_string()))).await;
    assert_eq!(a.request(&kb.public(), "/x", b"two", Duration::from_secs(20)).await.unwrap(), b"two");

    // Off: forgotten with its routes, nothing is reached through it, the entry keeps its place in the list.
    a.set_entry_points(&[entry("e1", p1, Some(NAME1), Some(PASS1), false)]);
    assert_eq!(state_of(&a, "e1"), Some(EntryState::Off));
    assert_eq!(a.via(&kb.public()), None, "what was heard through the entry is forgotten at once");
    assert!(!a.reachable(&kb.public()));
    assert_eq!(a.request(&kc.public(), "/x", b"three", Duration::from_secs(20)).await.unwrap(), b"three");

    // On again: the path requests sent on connect bring B back (B's announces no longer go out on its entry but once).
    a.set_entry_points(&[entry("e1", p1, Some(NAME1), Some(PASS1), true)]);
    until("e1 connected again", 30, || state_of(&a, "e1") == Some(EntryState::Connected)).await;
    until("B found again through e1", 40, || a.via(&kb.public()) == Some(Via::Entry("e1".to_string()))).await;

    // The same list again changes nothing.
    a.set_entry_points(&[entry("e1", p1, Some(NAME1), Some(PASS1), true)]);
    assert_eq!(state_of(&a, "e1"), Some(EntryState::Connected));

    // Edit: another rnsd and key; B is not on it, so it is no longer reachable through the entry.
    a.set_entry_points(&[entry("e1", p2, Some(NAME2), Some(PASS2), true)]);
    assert_eq!(a.via(&kb.public()), None);
    until("e1 connected to the other rnsd", 30, || state_of(&a, "e1") == Some(EntryState::Connected)).await;
    assert_eq!(a.request(&kc.public(), "/x", b"four", Duration::from_secs(20)).await.unwrap(), b"four");

    // Remove: gone from the list.
    a.set_entry_points(&[]);
    assert!(a.entry_status().is_empty());
    assert_eq!(a.request(&kc.public(), "/x", b"five", Duration::from_secs(20)).await.unwrap(), b"five");

    // No node restart in any of it: the node is the same and its link to C over the untouched interface never closed.
    assert_eq!(a.destination(), me);
    assert!(
        ra.closed.lock().unwrap().iter().all(|p| *p != kc.public()),
        "the link to C was never closed"
    );
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn the_periodic_announce_skips_entries_and_the_connect_announce_goes_to_one() {
    let (p1, p2, p3, pa) = (free_port(), free_port(), free_port(), free_port());
    let (s1, s2, s3) = (
        StandIn::server(p1, Some((NAME1, PASS1)), false),
        StandIn::server(p2, Some((NAME2, PASS2)), false),
        StandIn::server(p3, None, false),
    );
    let ka = SecretKey::generate();
    // A has a "Wi-Fi" interface (a TCP listener with a plain client on it, as a device on the local network) and two entries.
    let (a, _) = start(&ka, vec![Iface::TcpListen(format!("127.0.0.1:{pa}"))], vec![]).await;
    let wifi = StandIn::client(pa);
    let me = a.destination();
    a.set_entry_points(&[
        entry("e1", p1, Some(NAME1), Some(PASS1), true),
        entry("e2", p2, Some(NAME2), Some(PASS2), true),
    ]);
    until("e1 and e2 each heard the connect announce", 30, || s1.heard_of(me) >= 1 && s2.heard_of(me) >= 1).await;
    // The periodic announce (every 30 s, and now) goes to the local interface only.
    until("the local interface heard A", 45, || wifi.heard_of(me) >= 1).await;
    // An explicit announce (after a network change) skips the entries too. (The local side may drop a repeat inside its announce
    // rate limit, so only the entries are checked after it.)
    a.announce().await.unwrap();
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(s1.heard_of(me), 1, "e1 heard A once (when it connected), not the periodic ones");
    assert_eq!(s2.heard_of(me), 1, "e2 heard A once");

    // A third entry coming up is announced on alone, once.
    a.set_entry_points(&[
        entry("e1", p1, Some(NAME1), Some(PASS1), true),
        entry("e2", p2, Some(NAME2), Some(PASS2), true),
        entry("e3", p3, None, None, true),
    ]);
    until("e3 heard the connect announce", 30, || s3.heard_of(me) >= 1).await;
    tokio::time::sleep(Duration::from_secs(3)).await;
    assert_eq!(s3.heard_of(me), 1);
    assert_eq!(s1.heard_of(me), 1, "the entries that did not change are not announced on again");
    assert_eq!(s2.heard_of(me), 1);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn an_entry_that_stops_answering_is_not_answering_after_20_seconds() {
    let p1 = free_port();
    let mut s1 = StandIn::server(p1, Some((NAME1, PASS1)), true);
    let ka = SecretKey::generate();
    let (a, _) = start(&ka, vec![], vec![]).await;
    a.set_entry_points(&[entry("e1", p1, Some(NAME1), Some(PASS1), true)]);
    until("e1 connected", 30, || state_of(&a, "e1") == Some(EntryState::Connected)).await;
    let (_, _, checked) = a.entry_status().remove(0);
    assert!(checked > 0, "each state comes with when it was checked");
    s1.stop();
    let stopped = Instant::now();
    until("e1 not answering", 90, || state_of(&a, "e1") == Some(EntryState::NotAnswering)).await;
    assert!(stopped.elapsed() >= Duration::from_secs(19), "not before 20 s without it: {:?}", stopped.elapsed());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_wrong_passphrase_is_inferred_and_finds_no_path() {
    let p1 = free_port();
    // The rnsd has traffic (it announces a destination of its own every second), so bytes arrive on every client's connection.
    let _s1 = StandIn::server(p1, Some((NAME1, PASS1)), true);
    let (kg, kb) = (SecretKey::generate(), SecretKey::generate());
    // B is right and heard; G has the wrong passphrase.
    let (_b, _) = start(&kb, vec![Iface::Entry(entry("b1", p1, Some(NAME1), Some(PASS1), true))], vec![&kg]).await;
    let (g, _) = start(&kg, vec![Iface::Entry(entry("g1", p1, Some(NAME1), Some("not-the-passphrase"), true))], vec![&kb]).await;
    // Not decided yet at first: connected, nothing valid heard.
    until("g1 connected and nothing valid heard", 20, || {
        matches!(state_of(&g, "g1"), Some(EntryState::NothingHeard))
    })
    .await;
    until("g1 inferred as not matching", 60, || state_of(&g, "g1") == Some(EntryState::Mismatch)).await;
    assert!(!g.reachable(&kb.public()), "no path through a wrong passphrase");
    assert!(!g.find_path_to(&kb.public()).await);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_silent_rnsd_is_connected_with_nothing_heard_yet() {
    let p1 = free_port();
    let _s1 = StandIn::server(p1, Some((NAME1, PASS1)), false);
    let ka = SecretKey::generate();
    let (a, _) = start(&ka, vec![], vec![]).await;
    a.set_entry_points(&[entry("e1", p1, Some(NAME1), Some(PASS1), true)]);
    until("e1 nothing heard", 20, || state_of(&a, "e1") == Some(EntryState::NothingHeard)).await;
    tokio::time::sleep(Duration::from_secs(35)).await;
    // Nothing ever arrived, so it is not "doesn't match" and not Connected: it can't be told.
    assert_eq!(state_of(&a, "e1"), Some(EntryState::NothingHeard));
}

/// The real test rnsd on cache-build-1 (`~/rns4/run.sh start hub1` first; it starts nothing itself). The address, network name and
/// passphrase are read from `~/rns4/test-ifac.env` here and never printed. Run on that box:
/// `cargo test -p cache_rns --test entry_points -- --ignored --nocapture real_rnsd_hub1`
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn real_rnsd_hub1() {
    let text = std::fs::read_to_string(format!("{}/rns4/test-ifac.env", std::env::var("HOME").unwrap())).unwrap();
    let get = |k: &str| -> String {
        text.lines()
            .find_map(|l| l.strip_prefix(&format!("{k}=")))
            .unwrap_or_else(|| panic!("{k} is not in test-ifac.env"))
            .trim()
            .trim_matches('"')
            .to_string()
    };
    let addr = get("HUB1_ADDR");
    let (host, port) = addr.rsplit_once(':').expect("HUB1_ADDR is host:port");
    let (host, port): (String, u16) = (host.to_string(), port.parse().unwrap());
    let (name, pass) = (get("HUB1_NAME"), get("HUB1_PASS"));
    let mk = |id: &str, pass: &str| EntryPoint {
        id: id.to_string(),
        host: host.clone(),
        port,
        network_name: Some(name.clone()),
        passphrase: Some(Zeroizing::new(pass.to_string())),
        on: true,
    };
    let (ka, kb, kw) = (SecretKey::generate(), SecretKey::generate(), SecretKey::generate());
    let (a, _) = start(&ka, vec![Iface::Entry(mk("a1", &pass))], vec![&kb, &kw]).await;
    let (b, _) = start(&kb, vec![Iface::Entry(mk("b1", &pass))], vec![&ka, &kw]).await;
    // W has the wrong passphrase.
    let (w, _) = start(&kw, vec![Iface::Entry(mk("w1", "not-the-passphrase"))], vec![&ka, &kb]).await;
    until("a and b connected", 60, || {
        state_of(&a, "a1") == Some(EntryState::Connected) && state_of(&b, "b1") == Some(EntryState::Connected)
    })
    .await;
    until("a and b find each other", 60, || a.reachable(&kb.public()) && b.reachable(&ka.public())).await;
    assert_eq!(a.via(&kb.public()), Some(Via::Entry("a1".to_string())));
    assert_eq!(b.via(&ka.public()), Some(Via::Entry("b1".to_string())));
    println!("a: {:?}", a.entry_status().iter().map(|(i, s, _)| (i.clone(), *s)).collect::<Vec<_>>());
    println!("b: {:?}", b.entry_status().iter().map(|(i, s, _)| (i.clone(), *s)).collect::<Vec<_>>());
    // The wrong passphrase: no path, and the state says so (inferred when bytes arrive, "nothing heard yet" when none do).
    until("w settles", 60, || {
        matches!(state_of(&w, "w1"), Some(EntryState::Mismatch | EntryState::NothingHeard))
    })
    .await;
    tokio::time::sleep(Duration::from_secs(35)).await;
    println!("w (wrong passphrase): {:?}", w.entry_status().iter().map(|(i, s, _)| (i.clone(), *s)).collect::<Vec<_>>());
    assert!(!w.reachable(&ka.public()) && !w.reachable(&kb.public()), "no path through a wrong passphrase");
    assert_ne!(state_of(&w, "w1"), Some(EntryState::Connected));
}
