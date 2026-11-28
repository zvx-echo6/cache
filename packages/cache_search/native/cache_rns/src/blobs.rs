//! Verified file fetch over Reticulum, into Cache's own file store ([`cache_store`]).
//!
//! The transfer carries exactly what iroh carried: the bao encoding of a range of the blob (an 8-byte size, then the data plus
//! the tree nodes that prove it, 16 KiB chunk groups), checked against the BLAKE3 hash and stored by
//! [`Store::import_ranges`]. So verification, the store, and resume after a break are the store's own: a fetch asks only for
//! the windows the store does not hold yet. The windows a device serves are whatever ranges the asker names.
//!
//! A window is 16 MiB (16,384 BLAKE3 chunks of 1 KiB) on a Fast link and 1 MiB on a Medium one; a Slow link carries no file
//! (design 2b, [`crate::speed`]). One window is one request and its answer on the link, so only one window is held in memory
//! at a time, and a dropped link loses at most the window in flight. Both ends check the link's class: the asking end does not
//! ask for what its class forbids, and the answering end refuses it with [`TOO_SLOW`] even when the asker does ask.

use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use cache_store::{ChunkNum, ChunkRanges, Hash, Status, Store};
use iroh::PublicKey;

use crate::speed::{takes_too_long, Speed, WindowWatch};
use crate::RnsNode;

/// The request path for a window of a blob.
pub const BLOB_PATH: &str = "/cache/blob/window";
/// 16 MiB of 1 KiB chunks.
pub const WINDOW_CHUNKS: u64 = 16 * 1024;
pub(crate) const CHUNK: u64 = 1024;

const OK: u8 = 0;
const MISSING: u8 = 1;
const REFUSED: u8 = 2;
/// The file store is not ready to serve yet (being moved to a new format): the asker tries again later.
const NOT_READY: u8 = 3;
/// The answering end's class for this link does not allow what was asked (a window of that size, or of that file). An older
/// asker reads any byte it does not know as "refused", as it does [`NOT_READY`].
pub const TOO_SLOW: u8 = 4;
/// The file is bigger than the cap of the entry point the asker's route comes in through. An older asker reads any byte it does
/// not know as "refused", as it does [`NOT_READY`] and, before it, [`TOO_SLOW`].
pub const OVER_CAP: u8 = 5;

/// A fetch that did not go, or stopped, because the link is too slow for it (either end's judgment). Not a failure: the file
/// stays wanted and is fetched when a faster link is up.
#[derive(Debug)]
pub struct TooSlow(pub String);

impl std::fmt::Display for TooSlow {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for TooSlow {}

/// Whether `e` is a [`TooSlow`].
pub fn is_too_slow(e: &anyhow::Error) -> bool {
    e.chain().any(|c| c.downcast_ref::<TooSlow>().is_some())
}

/// A fetch that did not go because the file is bigger than the cap of the entry point the link goes through (the other end's
/// judgment). Not a failure: the file stays wanted and goes when the route is no longer through that entry (or the cap is raised).
#[derive(Debug)]
pub struct OverCap(pub String);

impl std::fmt::Display for OverCap {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for OverCap {}

/// Whether `e` is an [`OverCap`].
pub fn is_over_cap(e: &anyhow::Error) -> bool {
    e.chain().any(|c| c.downcast_ref::<OverCap>().is_some())
}

fn too_slow(why: &str) -> anyhow::Error {
    anyhow::Error::new(TooSlow(why.to_string()))
}

pub(crate) fn not_ready() -> Vec<u8> {
    vec![NOT_READY]
}

pub fn encode_want(hash: &Hash, start: u64, end: u64) -> Vec<u8> {
    let mut v = hash.as_bytes().to_vec();
    v.extend_from_slice(&start.to_be_bytes());
    v.extend_from_slice(&end.to_be_bytes());
    v
}

pub(crate) fn decode_want(b: &[u8]) -> Option<(Hash, u64, u64)> {
    if b.len() != 48 {
        return None;
    }
    let hash = Hash::from_bytes(b[..32].try_into().ok()?);
    let start = u64::from_be_bytes(b[32..40].try_into().ok()?);
    let end = u64::from_be_bytes(b[40..48].try_into().ok()?);
    Some((hash, start, end))
}

/// The serving side: answers a window request from a linked device, for the class `speed` this end judges the link to be.
///
/// `cap` is the most a file may be for the route the asker comes in by (an entry point's cap; none: no cap): a bigger file is
/// answered [`OVER_CAP`].
pub(crate) async fn serve_window(store: &Store, body: &[u8], speed: Speed, cap: Option<u64>) -> Vec<u8> {
    let Some((hash, start, end)) = decode_want(body) else { return vec![REFUSED] };
    if end <= start || end - start > WINDOW_CHUNKS {
        return vec![REFUSED];
    }
    // A window bigger than the class carries, or any window on a Slow link, is not served.
    if speed.window_chunks().is_none_or(|w| end - start > w) {
        return vec![TOO_SLOW];
    }
    let store = store.clone();
    let served = tokio::task::spawn_blocking(move || {
        match store.status(&hash) {
            Ok(Status::Complete { size }) => {
                if !speed.carries_file(size) {
                    return Err(TOO_SLOW);
                }
                if cap.is_some_and(|c| size > c) {
                    return Err(OVER_CAP);
                }
            }
            _ => return Err(MISSING),
        }
        let mut v = vec![OK];
        store.encode_ranges(&hash, &ChunkRanges::from(ChunkNum(start)..ChunkNum(end)), &mut v).map_err(|_| MISSING)?;
        Ok(v)
    })
    .await;
    match served {
        Ok(Ok(v)) => v,
        Ok(Err(b)) => vec![b],
        _ => vec![MISSING],
    }
}

/// Progress of one fetch.
#[derive(Debug, Clone, Copy, Default)]
pub struct Fetched {
    /// The blob's size, once known.
    pub size: u64,
    /// Bytes now held (verified) in the store.
    pub have: u64,
    /// Windows fetched in this call.
    pub windows: u64,
    /// Windows skipped because the store already held them (resume).
    pub skipped: u64,
}

fn window(start: u64, len: u64) -> ChunkRanges {
    ChunkRanges::from(ChunkNum(start)..ChunkNum(start + len))
}

/// Fetches `hash` from a linked device into `store`, skipping what the store already holds.
/// `progress` is called after each window. A failure leaves every verified window in the store, so calling again resumes.
///
/// The window follows the link's class ([`crate::speed`]), read before each window: 16 MiB on Fast, 1 MiB on Medium. On Slow, or
/// when the file is more than the class carries, nothing is asked and the failure is a [`TooSlow`] ([`is_too_slow`]): the file
/// stays wanted. Each window's time feeds the link's measured rate.
pub async fn fetch(
    node: &RnsNode,
    peer: &PublicKey,
    store: &Store,
    hash: Hash,
    window_timeout: Duration,
    mut progress: impl FnMut(&Fetched),
) -> Result<Fetched> {
    let speeds = node.speeds();
    let mut held = held(store, hash).await?;
    let mut f = Fetched { size: held.0, ..Default::default() };
    if held.1 {
        f.have = f.size;
        return Ok(f);
    }
    // The next chunk wanted.
    let mut at = 0u64;
    let mut watch = WindowWatch::default();
    // The answering end may hold an old round trip time for this link: one refusal is taken for that and the link is made again.
    let mut relinked = false;
    loop {
        if f.size > 0 && at * CHUNK >= f.size {
            break;
        }
        let class = speeds.ask_speed(peer);
        let Some(len) = class.window_chunks() else {
            return Err(too_slow("the connection is too slow to carry files"));
        };
        if f.size > 0 && !class.carries_file(f.size) {
            return Err(too_slow("this file is too big for the connection"));
        }
        // Resume: skip a window the store already holds whole (only once the size is known).
        if f.size > 0 {
            let last = f.size.div_ceil(CHUNK);
            let wanted = window(at, len.min(last.saturating_sub(at)));
            if held.2.is_superset(&wanted) {
                f.skipped += 1;
                // A resumed fetch says at once how much it already holds.
                at += len;
                f.have = (at * CHUNK).min(f.size);
                progress(&f);
                continue;
            }
        }
        // Design 2b, "when a link's speed changes mid-transfer": a window that would take over the budget (a minute) at the rate
        // measured so far is not started, and one that is not done by then is given up. Either way the file waits for a faster
        // link, and the windows already verified stay in the store.
        let budget = speeds.window_budget();
        if speeds.rate(peer).is_some_and(|r| takes_too_long(len.min(f.size.div_ceil(CHUNK).saturating_sub(at).max(1)) * CHUNK, r, budget)) {
            return Err(too_slow("finishing the next window would take over a minute at this speed"));
        }
        let asked = std::time::Instant::now();
        let reply = match node.request(peer, BLOB_PATH, &encode_want(&hash, at, at + len), window_timeout.min(budget)).await {
            Ok(r) => r,
            Err(_) if asked.elapsed() >= budget => {
                // Not done in the budget: at best the window's size over the budget, which the rate now says (and a probe cannot).
                speeds.note_transfer(peer, len * CHUNK, budget);
                return Err(too_slow("the window was not done within a minute, the connection is too slow"));
            }
            Err(e) => return Err(e),
        };
        match reply.first() {
            Some(&OK) => {}
            Some(&MISSING) => bail!("the other device does not have this file"),
            Some(&NOT_READY) => bail!("the other device is not ready to send files yet (its file store is being updated)"),
            Some(&TOO_SLOW) if !relinked && class != Speed::Slow => {
                // This end judged the link good enough for what it asked and the other end did not: the other end's judgment may
                // be the round trip time the link came up with (it measures nothing newer). A new link tells it the current one.
                relinked = true;
                node.relink_own(peer);
                continue;
            }
            Some(&TOO_SLOW) => {
                // The other end's judgment is Slow (or this file or window is more than its class carries): the slower wins.
                speeds.note_refused(peer);
                return Err(too_slow("the other device says the connection is too slow for this file"));
            }
            Some(&OVER_CAP) => return Err(anyhow::Error::new(OverCap("this file is bigger than the other device takes through this connection".into()))),
            _ => bail!("the other device refused the request"),
        }
        speeds.note_transfer(peer, reply.len() as u64, asked.elapsed());
        // Two windows in a row under the floor of the class they were asked in: cancel to waiting (after this one is stored).
        let slow_for_class = watch.done(class, reply.len() as u64, asked.elapsed());
        let bao = &reply[1..];
        if bao.len() < 8 {
            bail!("the answer is too short");
        }
        let size = u64::from_le_bytes(bao[..8].try_into().expect("8 bytes"));
        // A size that differs from the stored partial's is for the store to judge: it replaces a size nobody has proven yet (the
        // last chunk group has not verified) and refuses one it has.
        let changed = f.size != 0 && size != f.size;
        if f.size == 0 || changed {
            f.size = size;
        }
        let (st, bytes) = (store.clone(), reply);
        tokio::task::spawn_blocking(move || st.import_ranges(&hash, &window(at, len), &bytes[1..]))
            .await
            .map_err(|e| anyhow!("{e}"))?
            .map_err(|e| anyhow!("the data did not verify against the hash: {e}"))?;
        if changed {
            held = self::held(store, hash).await?;
            if held.1 {
                break;
            }
        }
        f.windows += 1;
        at += len;
        f.have = (at * CHUNK).min(f.size);
        progress(&f);
        if slow_for_class && f.have < f.size {
            return Err(too_slow("the connection stayed under this class's speed for two windows"));
        }
    }
    let done = self::held(store, hash).await?;
    if !done.1 {
        bail!("the file is not complete after the last window");
    }
    f.have = f.size;
    Ok(f)
}

/// What the store holds of `hash`: its size (0 if unknown), whether it is complete, and the chunks held.
async fn held(store: &Store, hash: Hash) -> Result<(u64, bool, ChunkRanges)> {
    let st = store.clone();
    let status = tokio::task::spawn_blocking(move || st.status(&hash))
        .await
        .map_err(|e| anyhow!("{e}"))?
        .map_err(|e| anyhow!("cannot read the store: {e}"))?;
    Ok(match status {
        Status::Complete { size } => (size, true, ChunkRanges::all()),
        Status::Partial { size, have } => (size, false, have),
        Status::Absent => (0, false, ChunkRanges::empty()),
    })
}
