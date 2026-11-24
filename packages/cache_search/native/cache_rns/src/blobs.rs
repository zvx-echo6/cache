//! Verified file fetch over Reticulum, into Cache's own file store ([`cache_store`]).
//!
//! The transfer carries exactly what iroh carried: the bao encoding of a range of the blob (an 8-byte size, then the data plus
//! the tree nodes that prove it, 16 KiB chunk groups), checked against the BLAKE3 hash and stored by
//! [`Store::import_ranges`]. So verification, the store, and resume after a break are the store's own: a fetch asks only for
//! the windows the store does not hold yet. The windows a device serves are whatever ranges the asker names.
//!
//! A window is 16 MiB (16,384 BLAKE3 chunks of 1 KiB). One window is one request and its answer on the link, so only one
//! window is held in memory at a time, and a dropped link loses at most the window in flight.

use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use cache_store::{ChunkNum, ChunkRanges, Hash, Status, Store};
use iroh::PublicKey;

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

pub(crate) fn not_ready() -> Vec<u8> {
    vec![NOT_READY]
}

pub(crate) fn encode_want(hash: &Hash, start: u64, end: u64) -> Vec<u8> {
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

/// The serving side: answers a window request from a linked device.
pub(crate) async fn serve_window(store: &Store, body: &[u8]) -> Vec<u8> {
    let Some((hash, start, end)) = decode_want(body) else { return vec![REFUSED] };
    if end <= start || end - start > WINDOW_CHUNKS {
        return vec![REFUSED];
    }
    let store = store.clone();
    let served = tokio::task::spawn_blocking(move || {
        if !store.has(&hash).unwrap_or(false) {
            return None;
        }
        let mut v = vec![OK];
        store.encode_ranges(&hash, &ChunkRanges::from(ChunkNum(start)..ChunkNum(end)), &mut v).ok()?;
        Some(v)
    })
    .await;
    match served {
        Ok(Some(v)) => v,
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

fn window(k: u64) -> ChunkRanges {
    ChunkRanges::from(ChunkNum(k * WINDOW_CHUNKS)..ChunkNum((k + 1) * WINDOW_CHUNKS))
}

/// Fetches `hash` from a linked device into `store`, skipping what the store already holds.
/// `progress` is called after each window. A failure leaves every verified window in the store, so calling again resumes.
pub async fn fetch(
    node: &RnsNode,
    peer: &PublicKey,
    store: &Store,
    hash: Hash,
    window_timeout: Duration,
    mut progress: impl FnMut(&Fetched),
) -> Result<Fetched> {
    let mut held = held(store, hash).await?;
    let mut f = Fetched { size: held.0, ..Default::default() };
    if held.1 {
        f.have = f.size;
        return Ok(f);
    }
    let mut k = 0u64;
    loop {
        let start = k * WINDOW_CHUNKS;
        if f.size > 0 && start * CHUNK >= f.size {
            break;
        }
        // Resume: skip a window the store already holds whole (only once the size is known).
        if f.size > 0 {
            let last = f.size.div_ceil(CHUNK);
            let wanted = ChunkRanges::from(ChunkNum(start)..ChunkNum(((k + 1) * WINDOW_CHUNKS).min(last)));
            if held.2.is_superset(&wanted) {
                f.skipped += 1;
                // A resumed fetch says at once how much it already holds.
                f.have = ((k + 1) * WINDOW_CHUNKS * CHUNK).min(f.size);
                progress(&f);
                k += 1;
                continue;
            }
        }
        let reply = node
            .request(peer, BLOB_PATH, &encode_want(&hash, start, start + WINDOW_CHUNKS), window_timeout)
            .await?;
        match reply.first() {
            Some(&OK) => {}
            Some(&MISSING) => bail!("the other device does not have this file"),
            Some(&NOT_READY) => bail!("the other device is not ready to send files yet (its file store is being updated)"),
            _ => bail!("the other device refused the request"),
        }
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
        tokio::task::spawn_blocking(move || st.import_ranges(&hash, &window(k), &bytes[1..]))
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
        f.have = ((k + 1) * WINDOW_CHUNKS * CHUNK).min(f.size);
        progress(&f);
        k += 1;
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
