//! B7a: two devices whose only carrier is a stand-in RNode on a simulated LoRa channel (no radio anywhere).

use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::time::{Duration, Instant};

use anyhow::Result;
use cache_rns::rnode::{RNodePort, Radio};
use cache_rns::standin::Air;
use cache_rns::{Asker, BoxFut, Config, Handler, Iface, RnsNode};
use iroh::{PublicKey, SecretKey};

#[derive(Default)]
struct Echo {
    notes: std::sync::Mutex<Vec<Vec<u8>>>,
}
impl Handler for Echo {
    fn request(&self, asker: Asker, path: &str, body: Vec<u8>) -> BoxFut<Result<Vec<u8>>> {
        let linked = matches!(asker, Asker::Linked(_));
        let path = path.to_string();
        Box::pin(async move { Ok(format!("{path} linked={linked} {}", body.len()).into_bytes()) })
    }
    fn notify(&self, _: PublicKey, body: Vec<u8>) {
        self.notes.lock().unwrap().push(body);
    }
}

/// A common 915 MHz setting: 125 kHz, SF8, CR 4/5 (about 3.1 kbit/s).
fn us915(sf: u8) -> Radio {
    Radio {
        frequency_hz: 914_875_000,
        bandwidth_hz: 125_000,
        spreading_factor: sf,
        coding_rate: 5,
        tx_power_dbm: 7,
        airtime_short_percent: None,
        airtime_long_percent: None,
    }
}

fn cfg(k: &SecretKey, host: &str, radio: Radio, peers: Vec<PublicKey>) -> Config {
    Config {
        device: k.clone(),
        interfaces: vec![Iface::RNode { name: "Radio".into(), port: RNodePort::Tcp(host.into()), radio }],
        peers,
        paths: vec!["/cache/hello".into()],
        open_paths: vec![],
        max_bytes: 1024 * 1024,
        blobs: None,
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
#[ignore = "Prns v0.3.8-hotfix.1 stale-tail bug: HeapFrameSlot::fill (prns-runtime manifold/grant_lane.rs) never truncates; fix is bytes.truncate(frame.len()); RNode is out of the first rollout"]
async fn two_devices_over_a_standin_lora_channel() {
    let air = Air::new();
    let sa = air.standin("127.0.0.11").await.unwrap();
    let sb = air.standin("127.0.0.12").await.unwrap();
    let sc = air.standin("127.0.0.13").await.unwrap();
    let (ka, kb, kc) = (SecretKey::generate(), SecretKey::generate(), SecretKey::generate());
    let ha = Arc::new(Echo::default());
    let a = RnsNode::start(cfg(&ka, "127.0.0.11", us915(8), vec![kb.public(), kc.public()]), ha.clone()).await.unwrap();
    let b = RnsNode::start(cfg(&kb, "127.0.0.12", us915(8), vec![ka.public()]), Arc::new(Echo::default())).await.unwrap();
    // C is linked with A but tuned to another spreading factor: it must hear nothing.
    let c = RnsNode::start(cfg(&kc, "127.0.0.13", us915(9), vec![ka.public()]), Arc::new(Echo::default())).await.unwrap();

    let t = Instant::now();
    while !(b.knows(&ka.public()) && a.knows(&kb.public())) {
        assert!(t.elapsed() < Duration::from_secs(90), "A and B hear each other over the stand-in LoRa within 90 s");
        let _ = a.announce().await;
        let _ = b.announce().await;
        let _ = c.announce().await;
        tokio::time::sleep(Duration::from_secs(3)).await;
    }
    println!("RESULT rnode_discovery secs={:.1} rnodes_up a={} b={}", t.elapsed().as_secs_f64(), a.rnode_count(), b.rnode_count());
    assert!(sa.stats.bring_ups.load(Ordering::Relaxed) >= 1, "Prns brought the stand-in up");

    let t = Instant::now();
    let r = b.request(&ka.public(), "/cache/hello", b"over lora", Duration::from_secs(60)).await.unwrap();
    assert_eq!(String::from_utf8(r).unwrap(), "/cache/hello linked=true 9");
    println!("RESULT rnode_request_secs={:.2}", t.elapsed().as_secs_f64());

    let t = Instant::now();
    b.notify(&ka.public(), b"folder F is at 42").await.unwrap();
    while ha.notes.lock().unwrap().is_empty() {
        assert!(t.elapsed() < Duration::from_secs(60), "the notify arrives over the stand-in LoRa");
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    println!("RESULT rnode_notify_secs={:.2}", t.elapsed().as_secs_f64());

    assert!(!c.knows(&ka.public()) && !a.knows(&kc.public()), "a radio on another spreading factor hears nothing");
    for (n, s) in [("A", &sa), ("B", &sb), ("C", &sc)] {
        println!(
            "RESULT standin {n} frames_sent={} bytes_sent={} airtime_ms={} frames_received={}",
            s.stats.frames_sent.load(Ordering::Relaxed),
            s.stats.bytes_sent.load(Ordering::Relaxed),
            s.stats.airtime_ms.load(Ordering::Relaxed),
            s.stats.frames_received.load(Ordering::Relaxed)
        );
    }
    assert_eq!(sc.stats.frames_received.load(Ordering::Relaxed), 0);
    a.stop();
    b.stop();
    c.stop();
}
