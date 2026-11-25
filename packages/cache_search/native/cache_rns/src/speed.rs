//! Speed classes (design 2b, "One address: how the link's speed decides what is sent").
//!
//! Each end puts a linked device's link in a class: Fast (LAN, Wi-Fi, hotspot, internet to a hub), Medium (Bluetooth) or Slow
//! (LoRa, packet radio, or any relay through one). The asking end asks only for what its class allows; the answering end checks
//! its own judgment and refuses what its class does not allow. The slower of the two wins.
//!
//! What a class is made from (Prns hands the app the link's round trip time on both ends, the route's first-hop interface and
//! its nominal bitrate, and Cache measures transfers itself; see 2b):
//! - Before any measurement, at link setup, the round trip time and the first-hop bitrate set the class; the slower guess wins.
//! - Then a 10 second moving rate measured from transfers (a window of a file) joins them.
//! - On an idle link the next small request's time is the measurement: [`Speeds::probe_due`] says when, [`Speeds::note_probe`]
//!   takes it.
//!
//! Policy only: nothing here is on the wire except the refusal byte of [`crate::blobs`] and the refusal text below.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use iroh::PublicKey;

/// Fast: a round trip time under this (and a measured rate over [`FAST_RATE`]).
pub const FAST_RTT_MS: u64 = 300;
/// Medium: a round trip time under this (and a measured rate of at least [`MEDIUM_RATE`]); at or over it, Slow.
pub const MEDIUM_RTT_MS: u64 = 1500;
/// Fast: a measured rate over 1 MB/s (bytes a second).
pub const FAST_RATE: f64 = 1_000_000.0;
/// Medium: a measured rate of at least 20 KB/s; under it, Slow.
pub const MEDIUM_RATE: f64 = 20_000.0;
/// A first-hop interface under 100 kbit/s is Slow.
pub const SLOW_FIRST_HOP_BPS: u64 = 100_000;
/// The moving rate looks back this far.
pub const RATE_WINDOW: Duration = Duration::from_secs(10);
/// A transfer under this says nothing of a rate (a small request is quick or slow by its round trip, not by the link's rate).
pub const MIN_RATE_BYTES: u64 = 512 * 1024;
/// How long a link may go without a measurement before the next request is preceded by a small one.
pub const PROBE_EVERY: Duration = Duration::from_secs(10);
/// The largest file a Medium link carries.
pub const MEDIUM_MAX_FILE: u64 = 10 * 1024 * 1024;
/// The window of a file on a Fast link: 16 MiB of 1 KiB chunks.
pub const FAST_WINDOW_CHUNKS: u64 = 16 * 1024;
/// The window of a file on a Medium link: 1 MiB.
pub const MEDIUM_WINDOW_CHUNKS: u64 = 1024;

/// What an answering end says (as the text of a failed request) when its class for the asking device does not allow what was
/// asked: the asker reads it as a refusal, not as a broken answer ([`is_refusal`]).
pub const TOO_SLOW_TEXT: &str = "the connection is too slow for this";

/// Whether `reply` is the answer of a request refused for speed.
pub fn is_refusal(reply: &[u8]) -> bool {
    reply == format!("error: {TOO_SLOW_TEXT}").as_bytes()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
pub enum Speed {
    Slow,
    Medium,
    Fast,
}

impl Speed {
    pub fn as_str(self) -> &'static str {
        match self {
            Speed::Slow => "slow",
            Speed::Medium => "medium",
            Speed::Fast => "fast",
        }
    }

    /// The window a file travels in: none on Slow (no file goes).
    pub fn window_chunks(self) -> Option<u64> {
        match self {
            Speed::Fast => Some(FAST_WINDOW_CHUNKS),
            Speed::Medium => Some(MEDIUM_WINDOW_CHUNKS),
            Speed::Slow => None,
        }
    }

    /// The largest file this class carries: any on Fast, 10 MiB on Medium, none on Slow (files only by the 8 KB inline cap,
    /// which a later step adds).
    pub fn max_file(self) -> Option<u64> {
        match self {
            Speed::Fast => None,
            Speed::Medium => Some(MEDIUM_MAX_FILE),
            Speed::Slow => Some(0),
        }
    }

    /// A file of `size` bytes may go over a link of this class.
    pub fn carries_file(self, size: u64) -> bool {
        self.max_file().is_none_or(|m| size <= m)
    }
}

/// The class a link's numbers give. `rate` is a measured rate in bytes a second, `first_hop_bps` the first-hop interface's
/// nominal bitrate. A number that is not known says nothing; with none known the class is Fast (the class of a path nothing
/// is known against: iroh's, and a link not yet measured).
pub fn classify(rtt_ms: Option<u64>, rate: Option<f64>, first_hop_bps: Option<u64>) -> Speed {
    let mut c = Speed::Fast;
    if let Some(r) = rtt_ms {
        c = c.min(if r < FAST_RTT_MS {
            Speed::Fast
        } else if r < MEDIUM_RTT_MS {
            Speed::Medium
        } else {
            Speed::Slow
        });
    }
    if let Some(r) = rate {
        c = c.min(if r > FAST_RATE {
            Speed::Fast
        } else if r >= MEDIUM_RATE {
            Speed::Medium
        } else {
            Speed::Slow
        });
    }
    if first_hop_bps.is_some_and(|b| b < SLOW_FIRST_HOP_BPS) {
        c = Speed::Slow;
    }
    c
}

#[derive(Default)]
struct PeerSpeed {
    /// The round trip time of the link this device opened, or of the latest small request: the later one counts.
    rtt: Option<u64>,
    /// The round trip time of the newest link the other device opened to this one.
    accepted: Option<u64>,
    /// The nominal bitrate of the interface the route leaves by.
    hop: Option<u64>,
    /// Transfers (when they ended, bytes, how long they took), newest last.
    transfers: VecDeque<(Instant, u64, Duration)>,
    /// The other device refused something as too slow: Slow until this device measures again.
    refused: bool,
    /// When this link was last measured (opened, probed or carried a transfer).
    measured: Option<Instant>,
}

impl PeerSpeed {
    /// The moving rate over the last [`RATE_WINDOW`], in bytes a second.
    fn rate(&self) -> Option<f64> {
        let now = Instant::now();
        let (mut bytes, mut secs) = (0u64, 0f64);
        for (end, b, d) in &self.transfers {
            if now.duration_since(*end) <= RATE_WINDOW {
                bytes += b;
                secs += d.as_secs_f64();
            }
        }
        (bytes > 0 && secs > 0.0).then(|| bytes as f64 / secs)
    }
}

/// What a device knows of each linked device's link speed.
pub struct Speeds {
    peers: Mutex<HashMap<[u8; 32], PeerSpeed>>,
    probe_every: Mutex<Duration>,
}

impl Speeds {
    pub fn new() -> Arc<Speeds> {
        Arc::new(Speeds { peers: Mutex::new(HashMap::new()), probe_every: Mutex::new(PROBE_EVERY) })
    }

    fn with<R>(&self, peer: &PublicKey, f: impl FnOnce(&mut PeerSpeed) -> R) -> R {
        let mut m = self.peers.lock().unwrap();
        f(m.entry(*peer.as_bytes()).or_default())
    }

    /// A link this device opened is up, with this round trip time. Anything held against the link from before is dropped.
    pub fn set_opened_rtt(&self, peer: &PublicKey, ms: u64) {
        self.with(peer, |p| {
            p.rtt = Some(ms);
            p.refused = false;
            p.measured = Some(Instant::now());
        });
    }

    /// A link the other device opened is up on this end, with the round trip time Reticulum measured when it came up.
    pub fn set_accepted_rtt(&self, peer: &PublicKey, ms: u64) {
        self.with(peer, |p| p.accepted = Some(ms));
    }

    /// The nominal bitrate of the interface the route to `peer` leaves by (its first hop).
    pub fn set_first_hop(&self, peer: &PublicKey, bps: Option<u64>) {
        self.with(peer, |p| p.hop = bps);
    }

    /// The time a small request took on an idle link: the newer measurement of its round trip time.
    pub fn note_probe(&self, peer: &PublicKey, ms: u64) {
        self.with(peer, |p| {
            p.rtt = Some(ms);
            p.refused = false;
            p.measured = Some(Instant::now());
        });
    }

    /// A transfer of `bytes` took `elapsed` (a window of a file). Under [`MIN_RATE_BYTES`] it says nothing of a rate.
    pub fn note_transfer(&self, peer: &PublicKey, bytes: u64, elapsed: Duration) {
        self.with(peer, |p| {
            let now = Instant::now();
            p.measured = Some(now);
            if bytes < MIN_RATE_BYTES {
                return;
            }
            p.transfers.retain(|(end, _, _)| now.duration_since(*end) <= RATE_WINDOW);
            p.transfers.push_back((now, bytes, elapsed.max(Duration::from_millis(1))));
        });
    }

    /// The other device answered a request as too slow: its judgment of the link is Slow, and the slower wins until this
    /// device has measured the link again (a new link or a probe).
    pub fn note_refused(&self, peer: &PublicKey) {
        self.with(peer, |p| p.refused = true);
    }

    /// The class for what this device asks of `peer`: from the link it opened (or, with none, the one `peer` opened), the first
    /// hop, and the measured rate; Slow while `peer` has refused as too slow.
    pub fn ask_speed(&self, peer: &PublicKey) -> Speed {
        self.with(peer, |p| {
            let s = classify(p.rtt.or(p.accepted), p.rate(), p.hop);
            if p.refused {
                Speed::Slow
            } else {
                s
            }
        })
    }

    /// The class for what this device answers `peer`: from the link `peer` opened (or, with none, the one this device opened)
    /// and the first hop. This end sees no rate of its own, so a rate is not part of it.
    pub fn serve_speed(&self, peer: &PublicKey) -> Speed {
        self.with(peer, |p| classify(p.accepted.or(p.rtt), None, p.hop))
    }

    /// The link to `peer` has gone without a measurement for [`Speeds::set_probe_every`]: a small request should come first.
    pub fn probe_due(&self, peer: &PublicKey) -> bool {
        let every = *self.probe_every.lock().unwrap();
        self.with(peer, |p| p.measured.is_some_and(|t| t.elapsed() >= every))
    }

    /// How long a link may go without a measurement (tests make it short).
    pub fn set_probe_every(&self, d: Duration) {
        *self.probe_every.lock().unwrap() = d;
    }
}
