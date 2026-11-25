//! Step 4 proofs (e), (f) and (h) against the real test rnsds on cache-build-1 (the plan's "Against the two test rnsds"), with
//! `~/rns4/probe.py` (standard RNS 1.6, public API only) as the reference client. Every test is `#[ignore]`d: it starts no rnsd
//! itself (`~/rns4/run.sh start hub1|hub2|hub2-chained` first) and is run by hand ON cache-build-1, because the IFAC network names
//! and passphrases are read from `~/rns4/test-ifac.env` here (and by the probe) and never printed, logged or put on a command line.
//!
//! - (e): `cargo test -p cache_rns --test real_rnsd_proofs -- --ignored --nocapture --test-threads=1 proof_e` (hub1 running)
//! - (f): `... proof_f` (hub1 and hub2 running, not joined)
//! - (h): `... proof_h` (hub1 and hub2-chained running; hub2 stopped)

use std::io::{BufRead, BufReader};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::Result;
use cache_rns::{
    dest_hex, Asker, BoxFut, Config, EntryPoint, Handler, Iface, RnsNode, Via,
};
use iroh::{PublicKey, SecretKey};
use personal_rns::prelude::*;

/// A handler that counts what reaches the app: a request from a device that is not linked must never get here.
#[derive(Default)]
struct Rec {
    requests: AtomicUsize,
}
impl Handler for Rec {
    fn request(&self, _: Asker, _: &str, body: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        self.requests.fetch_add(1, Ordering::SeqCst);
        Box::pin(async move { Ok(body) })
    }
    fn notify(&self, _: PublicKey, _: Vec<u8>) {}
    fn link_closed(&self, _: PublicKey, _: &str, _: Option<u64>, _: Option<u64>) {}
}

fn home() -> String {
    std::env::var("HOME").unwrap()
}

/// `(host, port, network name, passphrase)` of `hub` ("HUB1" or "HUB2"), read from test-ifac.env here and nowhere else.
fn hub(which: &str) -> (String, u16, String, String) {
    let text = std::fs::read_to_string(format!("{}/rns4/test-ifac.env", home())).unwrap();
    let get = |k: &str| -> String {
        text.lines()
            .find_map(|l| l.strip_prefix(&format!("{which}_{k}=")))
            .unwrap_or_else(|| panic!("{which}_{k} is not in test-ifac.env"))
            .trim()
            .trim_matches('"')
            .to_string()
    };
    let addr = get("ADDR");
    let (host, port) = addr.rsplit_once(':').expect("ADDR is host:port");
    (host.to_string(), port.parse().unwrap(), get("NAME"), get("PASS"))
}

fn entry(id: &str, which: &str) -> EntryPoint {
    let (host, port, name, pass) = hub(which);
    EntryPoint {
        id: id.to_string(),
        host,
        port,
        network_name: Some(name),
        passphrase: Some(Zeroizing::new(pass)),
        on: true,
    }
}

async fn start(device: &SecretKey, interfaces: Vec<Iface>) -> (RnsNode, Arc<Rec>) {
    let rec = Arc::new(Rec::default());
    let cfg = Config {
        device: device.clone(),
        interfaces,
        peers: vec![],
        wifi_group: None,
        paths: vec!["/x".to_string()],
        open_paths: vec![],
        max_bytes: 64 * 1024 * 1024,
        blobs: None,
        pair_local_tcp: false,
    };
    (RnsNode::start(cfg, rec.clone()).await.unwrap(), rec)
}

async fn until(what: &str, secs: u64, mut f: impl FnMut() -> bool) {
    let t = Instant::now();
    while !f() {
        assert!(t.elapsed() < Duration::from_secs(secs), "{what} within {secs} s");
        tokio::time::sleep(Duration::from_millis(200)).await;
    }
    println!("[{:6.1}s] {what}", T0.get().map(|t| t.elapsed().as_secs_f64()).unwrap_or(0.0));
}

static T0: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

fn say(what: &str) {
    println!("[{:6.1}s] {what}", T0.get_or_init(Instant::now).elapsed().as_secs_f64());
}

/// `probe.py` as a child: its output lines are kept with the time they arrived. Killed when dropped.
struct Probe {
    child: Child,
    lines: Arc<Mutex<Vec<(f64, String)>>>,
    name: String,
}

impl Probe {
    fn start(name: &str, hub: &str, mode: &[&str]) -> Probe {
        let cfg = format!("{}/rns4/probes/{name}", home());
        let mut child = Command::new(format!("{}/rns4/venv/bin/python", home()))
            .arg(format!("{}/rns4/probe.py", home()))
            .args(["--config", &cfg, "--hub", hub])
            .args(mode)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .expect("start probe.py");
        let lines: Arc<Mutex<Vec<(f64, String)>>> = Arc::default();
        let (l2, out, n2) = (lines.clone(), child.stdout.take().unwrap(), name.to_string());
        let t0 = *T0.get_or_init(Instant::now);
        std::thread::spawn(move || {
            for line in BufReader::new(out).lines().map_while(|l| l.ok()) {
                let at = t0.elapsed().as_secs_f64();
                println!("[{at:6.1}s] probe {n2}: {line}");
                l2.lock().unwrap().push((at, line));
            }
        });
        Probe { child, lines, name: name.to_string() }
    }

    fn lines_with(&self, prefix: &str) -> Vec<String> {
        self.lines.lock().unwrap().iter().filter(|(_, l)| l.starts_with(prefix)).map(|(_, l)| l.clone()).collect()
    }

    async fn wait_for(&self, prefix: &str, secs: u64) -> Option<String> {
        let t = Instant::now();
        while t.elapsed() < Duration::from_secs(secs) {
            if let Some(l) = self.lines_with(prefix).into_iter().next() {
                return Some(l);
            }
            tokio::time::sleep(Duration::from_millis(200)).await;
        }
        None
    }
}

impl Drop for Probe {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        say(&format!("probe {} stopped", self.name));
    }
}

fn dest_of(ready: &str) -> DestinationHash {
    cache_rns::dest_from_hex(ready.split_whitespace().nth(1).expect("READY <hex>")).expect("a destination")
}

/// The probe's `find` result must show: a link opened, and neither request was answered (Cache says nothing to a device that is
/// not linked, and its app handler never saw either).
fn assert_refused_as_unlinked(find: &Probe, rec: &Rec) {
    assert!(!find.lines_with("LINK active").is_empty(), "the probe's link to Cache did not open: {:?}", find.lines.lock().unwrap());
    let nos = find.lines_with("REQUEST").into_iter().filter(|l| l.ends_with("no-answer")).count();
    assert_eq!(nos, 2, "both requests from the unlinked probe go unanswered: {:?}", find.lines_with("REQUEST"));
    assert_eq!(rec.requests.load(Ordering::SeqCst), 0, "Cache's app handler saw a request from a device that is not linked");
}

/// (e) IFAC interop with standard RNS.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn proof_e_ifac_interop_with_standard_rns() {
    say("proof (e) starts");
    let listen = Probe::start("e-listen", "hub1", &["listen"]);
    let ready = listen.wait_for("READY", 60).await.expect("the probe is on hub1 and announced");
    let probe_dest = dest_of(&ready);

    let k = SecretKey::generate();
    let (a, rec) = start(&k, vec![Iface::Entry(entry("e1", "HUB1"))]).await;
    let cache_dest = a.destination();
    say(&format!("Cache destination {}", dest_hex(&cache_dest)));
    until("Cache entry connected", 60, || {
        a.entry_status().iter().any(|(i, s, _)| i == "e1" && *s == cache_rns::EntryState::Connected)
    })
    .await;

    // Cache hears the probe's announce: its path request for the probe's destination is answered, through the entry.
    assert!(a.find_path_dest(probe_dest, Duration::from_secs(30)).await, "Cache found a path to the probe");
    say("Cache has a path to the probe's destination");
    assert_eq!(a.route_via(probe_dest).await, Some(Via::Entry("e1".to_string())));

    // The probe hears Cache's announce (sent once when the entry connected).
    let want = dest_hex(&cache_dest);
    let t = Instant::now();
    loop {
        if listen.lines_with("HEARD").iter().any(|l| l.contains(&want)) {
            break;
        }
        assert!(t.elapsed() < Duration::from_secs(60), "the probe never heard Cache's announce; heard {:?}", listen.lines_with("HEARD"));
        tokio::time::sleep(Duration::from_millis(250)).await;
    }
    say("the probe heard Cache's announce");

    // A second reference client finds Cache and opens a link; Cache says nothing to it (not linked).
    let find = Probe::start("e-find", "hub1", &["find", &want, "--wait", "60"]);
    find.wait_for("DONE", 120).await.expect("the find probe finished");
    assert!(!find.lines_with("PATH").is_empty(), "no path to Cache: {:?}", find.lines.lock().unwrap());
    assert_refused_as_unlinked(&find, &rec);
    say("proof (e): both heard, link opened, requests refused as unlinked");
    a.stop();
}

/// (f) No relaying: Cache is on hub1 and hub2 (not joined); the listener is only on hub2, the finder only on hub1.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn proof_f_no_relaying() {
    say("proof (f) starts");
    let listen = Probe::start("f-listen", "hub2", &["listen"]);
    let ready = listen.wait_for("READY", 60).await.expect("the probe is on hub2 and announced");
    let probe_dest = dest_of(&ready);

    let k = SecretKey::generate();
    let (a, rec) = start(&k, vec![Iface::Entry(entry("e1", "HUB1")), Iface::Entry(entry("e2", "HUB2"))]).await;
    let cache_dest = dest_hex(&a.destination());
    // hub1 has no traffic of its own here (no probe on it), so Cache can only say "connected, nothing heard yet" for e1; e2 hears
    // the listener's announces and is Connected.
    until("both entries connected (e1 may say nothing heard yet, on a quiet rnsd)", 60, || {
        let s = a.entry_status();
        let ok = |id: &str, want: &[cache_rns::EntryState]| s.iter().any(|(i, st, _)| i == id && want.contains(st));
        ok("e1", &[cache_rns::EntryState::Connected, cache_rns::EntryState::NothingHeard]) && ok("e2", &[cache_rns::EntryState::Connected])
    })
    .await;
    println!("entry states: {:?}", a.entry_status().iter().map(|(i, s, _)| (i.clone(), *s)).collect::<Vec<_>>());
    // Cache itself does hear the hub2 listener (so the negative below is not just "nothing was connected").
    assert!(a.find_path_dest(probe_dest, Duration::from_secs(30)).await, "Cache found a path to the hub2 listener");
    assert_eq!(a.route_via(probe_dest).await, Some(Via::Entry("e2".to_string())));
    say("Cache holds a path to the hub2 listener, through e2");

    // Control: a finder on hub1 does find Cache itself (Cache is on hub1), so the finder and hub1 work.
    let ctl = Probe::start("f-control", "hub1", &["find", &cache_dest, "--wait", "40"]);
    ctl.wait_for("DONE", 120).await.expect("the control finished");
    assert!(!ctl.lines_with("PATH").is_empty(), "control: the hub1 finder finds Cache");
    assert_refused_as_unlinked(&ctl, &rec);
    say("control done: the hub1 finder finds Cache and its link opens (refused at the app level)");
    drop(ctl);

    // The proof: a finder on hub1 asks for the hub2 listener. Cache is on both hubs but does not relay.
    let find = Probe::start("f-find", "hub1", &["find", &dest_hex(&probe_dest), "--wait", "45"]);
    find.wait_for("DONE", 120).await.expect("the finder finished");
    assert!(!find.lines_with("NOPATH").is_empty(), "the hub1 finder found a path it must not have: {:?}", find.lines.lock().unwrap());
    assert!(find.lines_with("PATH").is_empty() && find.lines_with("LINK").is_empty());
    assert!(listen.lines_with("LINK_UP").is_empty(), "a link reached the hub2 listener: {:?}", listen.lines_with("LINK_UP"));
    say("proof (f): the hub1 finder got no path to the hub2 listener; no link opened through Cache");
    a.stop();
}

/// (h) Reference interop through the chain (hub1 and hub2-chained running, hub2 stopped): a finder on hub2-chained finds a Cache
/// node that is on hub1 only, and reports the hop count RNS gives.
#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore]
async fn proof_h_reference_interop_through_the_chain() {
    say("proof (h) starts");
    let k = SecretKey::generate();
    let (a, rec) = start(&k, vec![Iface::Entry(entry("e1", "HUB1"))]).await;
    let cache_dest = dest_hex(&a.destination());
    say(&format!("Cache destination {cache_dest} (on hub1 only)"));
    until("Cache entry connected", 60, || {
        a.entry_status().iter().any(|(i, s, _)| i == "e1" && *s == cache_rns::EntryState::Connected)
    })
    .await;
    tokio::time::sleep(Duration::from_secs(3)).await;
    let find = Probe::start("h-find", "hub2", &["find", &cache_dest, "--wait", "60"]);
    find.wait_for("DONE", 150).await.expect("the finder finished");
    assert!(!find.lines_with("PATH").is_empty(), "no path through the chain: {:?}", find.lines.lock().unwrap());
    assert_refused_as_unlinked(&find, &rec);
    say(&format!("proof (h): {:?}", find.lines_with("PATH")));
    a.stop();
}
