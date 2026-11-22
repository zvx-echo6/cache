//! A stand-in RNode for tests: it speaks the RNode host protocol over TCP (RNS's RNode-over-TCP, port 7633) and never
//! touches a radio. Several stand-ins share one simulated "air":
//! - half duplex: one frame on the air at a time, the rest wait their turn;
//! - each frame takes its airtime at the radio's LoRa bit rate before it arrives;
//! - a frame reaches only the stand-ins on the same frequency, bandwidth, spreading factor and coding rate;
//! - the airtime each stand-in used is counted.
//!
//! The bring-up answers are what RNode firmware sends: detect, firmware 1.52, platform and MCU, and every radio setting
//! echoed back, so Prns's validation passes exactly as with a real RNode.

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::{broadcast, Mutex};

use crate::rnode::lora_bitrate_bps;

const FEND: u8 = 0xC0;
const FESC: u8 = 0xDB;
const TFEND: u8 = 0xDC;
const TFESC: u8 = 0xDD;

const CMD_DATA: u8 = 0x00;
const CMD_FREQUENCY: u8 = 0x01;
const CMD_BANDWIDTH: u8 = 0x02;
const CMD_TXPOWER: u8 = 0x03;
const CMD_SF: u8 = 0x04;
const CMD_CR: u8 = 0x05;
const CMD_RADIO_STATE: u8 = 0x06;
const CMD_DETECT: u8 = 0x08;
const CMD_ST_ALOCK: u8 = 0x0B;
const CMD_LT_ALOCK: u8 = 0x0C;
const CMD_READY: u8 = 0x0F;
const CMD_PLATFORM: u8 = 0x48;
const CMD_MCU: u8 = 0x49;
const CMD_FW_VERSION: u8 = 0x50;
const DETECT_REQ: u8 = 0x73;
const DETECT_RESP: u8 = 0x46;

/// LoRa's per-frame overhead in this model: preamble and header, as bytes of airtime (an approximation).
const FRAME_OVERHEAD_BYTES: usize = 12;

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Tuning {
    frequency: u32,
    bandwidth: u32,
    sf: u8,
    cr: u8,
    on: bool,
}

#[derive(Clone, Debug)]
struct OnAir {
    from: u64,
    tuning: Tuning,
    frame: Vec<u8>,
}

/// The shared simulated air.
#[derive(Clone)]
pub struct Air {
    tx: broadcast::Sender<OnAir>,
    channel: Arc<Mutex<()>>,
    next_id: Arc<AtomicU64>,
}

impl Default for Air {
    fn default() -> Self {
        Self::new()
    }
}

impl Air {
    pub fn new() -> Air {
        let (tx, _) = broadcast::channel(1024);
        Air { tx, channel: Arc::new(Mutex::new(())), next_id: Arc::new(AtomicU64::new(1)) }
    }

    /// Starts a stand-in RNode listening on `host:7633` (use a distinct loopback address per stand-in, e.g. 127.0.0.11).
    pub async fn standin(&self, host: &str) -> Result<StandIn> {
        let listener = TcpListener::bind((host, 7633)).await.with_context(|| format!("cannot listen on {host}:7633"))?;
        let id = self.next_id.fetch_add(1, Ordering::Relaxed);
        let stats = Arc::new(Stats::default());
        let air = self.clone();
        let st = stats.clone();
        let task = tokio::spawn(async move {
            loop {
                let Ok((sock, _)) = listener.accept().await else { return };
                let _ = sock.set_nodelay(true);
                // One host at a time, as with a real radio; a new connection replaces the old one.
                serve(sock, id, air.clone(), st.clone()).await;
            }
        });
        Ok(StandIn { stats, task })
    }
}

/// What one stand-in counted.
#[derive(Default, Debug)]
pub struct Stats {
    pub frames_sent: AtomicU64,
    pub bytes_sent: AtomicU64,
    pub airtime_ms: AtomicU64,
    pub frames_received: AtomicU64,
    pub bring_ups: AtomicU64,
}

pub struct StandIn {
    pub stats: Arc<Stats>,
    task: tokio::task::JoinHandle<()>,
}

impl Drop for StandIn {
    fn drop(&mut self) {
        self.task.abort();
    }
}

fn encode(cmd: u8, payload: &[u8]) -> Vec<u8> {
    let mut v = Vec::with_capacity(payload.len() + 4);
    v.push(FEND);
    v.push(cmd);
    for &b in payload {
        match b {
            FEND => v.extend_from_slice(&[FESC, TFEND]),
            FESC => v.extend_from_slice(&[FESC, TFESC]),
            _ => v.push(b),
        }
    }
    v.push(FEND);
    v
}

fn be_u32(p: &[u8]) -> u32 {
    let mut b = [0u8; 4];
    let n = p.len().min(4);
    b[4 - n..].copy_from_slice(&p[p.len() - n..]);
    u32::from_be_bytes(b)
}

async fn serve(sock: tokio::net::TcpStream, id: u64, air: Air, stats: Arc<Stats>) {
    let (mut rd, wr) = sock.into_split();
    let wr = Arc::new(Mutex::new(wr));
    let tuning = Arc::new(Mutex::new(Tuning::default()));

    // Frames from the air, to this host.
    let mut rx = air.tx.subscribe();
    let (wr2, tun2, st2) = (wr.clone(), tuning.clone(), stats.clone());
    let listen = tokio::spawn(async move {
        while let Ok(f) = rx.recv().await {
            let mine = *tun2.lock().await;
            if f.from == id || !mine.on || !same_channel(&mine, &f.tuning) {
                continue;
            }
            st2.frames_received.fetch_add(1, Ordering::Relaxed);
            if wr2.lock().await.write_all(&encode(CMD_DATA, &f.frame)).await.is_err() {
                return;
            }
        }
    });

    let mut frame = Vec::new();
    let mut in_frame = false;
    let mut escape = false;
    let mut buf = [0u8; 4096];
    'outer: loop {
        let n = match rd.read(&mut buf).await {
            Ok(0) | Err(_) => break,
            Ok(n) => n,
        };
        for &b in &buf[..n] {
            if b == FEND {
                if in_frame && !frame.is_empty() {
                    let f = std::mem::take(&mut frame);
                    if !handle(&f, id, &air, &wr, &tuning, &stats).await {
                        break 'outer;
                    }
                }
                in_frame = true;
                frame.clear();
                continue;
            }
            if !in_frame {
                continue;
            }
            if escape {
                frame.push(match b {
                    TFEND => FEND,
                    TFESC => FESC,
                    x => x,
                });
                escape = false;
            } else if b == FESC {
                escape = true;
            } else {
                frame.push(b);
            }
        }
    }
    listen.abort();
}

fn same_channel(a: &Tuning, b: &Tuning) -> bool {
    a.frequency == b.frequency && a.bandwidth == b.bandwidth && a.sf == b.sf && a.cr == b.cr
}

/// One frame from the host. False when the host is gone.
async fn handle(
    f: &[u8],
    id: u64,
    air: &Air,
    wr: &Arc<Mutex<tokio::net::tcp::OwnedWriteHalf>>,
    tuning: &Arc<Mutex<Tuning>>,
    stats: &Arc<Stats>,
) -> bool {
    let (cmd, p) = (f[0], &f[1..]);
    let reply: Option<Vec<u8>> = match cmd {
        CMD_DETECT if p.first() == Some(&DETECT_REQ) => {
            stats.bring_ups.fetch_add(1, Ordering::Relaxed);
            Some(encode(CMD_DETECT, &[DETECT_RESP]))
        }
        CMD_FW_VERSION => Some(encode(CMD_FW_VERSION, &[1, 52])),
        CMD_PLATFORM => Some(encode(CMD_PLATFORM, &[0x80])),
        CMD_MCU => Some(encode(CMD_MCU, &[0x81])),
        CMD_FREQUENCY | CMD_BANDWIDTH | CMD_TXPOWER | CMD_SF | CMD_CR | CMD_RADIO_STATE | CMD_ST_ALOCK | CMD_LT_ALOCK => {
            let mut t = tuning.lock().await;
            match cmd {
                CMD_FREQUENCY => t.frequency = be_u32(p),
                CMD_BANDWIDTH => t.bandwidth = be_u32(p),
                CMD_SF => t.sf = p.first().copied().unwrap_or(0),
                CMD_CR => t.cr = p.first().copied().unwrap_or(0),
                CMD_RADIO_STATE => t.on = p.first() == Some(&1),
                _ => {}
            }
            Some(encode(cmd, p))
        }
        CMD_DATA => {
            let t = *tuning.lock().await;
            if t.on && t.bandwidth > 0 && t.sf > 0 && t.cr > 0 {
                let bitrate = lora_bitrate_bps(t.sf, t.cr, t.bandwidth).max(1);
                let airtime = Duration::from_secs_f64(((p.len() + FRAME_OVERHEAD_BYTES) * 8) as f64 / f64::from(bitrate));
                {
                    // Half duplex: the frame owns the air while it is sent.
                    let _on_air = air.channel.lock().await;
                    tokio::time::sleep(airtime).await;
                    let _ = air.tx.send(OnAir { from: id, tuning: t, frame: p.to_vec() });
                }
                stats.frames_sent.fetch_add(1, Ordering::Relaxed);
                stats.bytes_sent.fetch_add(p.len() as u64, Ordering::Relaxed);
                stats.airtime_ms.fetch_add(airtime.as_millis() as u64, Ordering::Relaxed);
                Some(encode(CMD_READY, &[0x01]))
            } else {
                None
            }
        }
        _ => None,
    };
    if let Some(r) = reply {
        if wr.lock().await.write_all(&r).await.is_err() {
            return false;
        }
    }
    true
}
