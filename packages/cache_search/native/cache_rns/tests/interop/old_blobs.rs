// The pre-6a window code, kept for the interop test (tests/interop.rs).
//
// This is cache_rns/src/blobs.rs exactly as it stands on origin/main at 04a030e7 (last changed in 509db283), which serves and
// fetches windows through iroh-blobs 0.103.1's store (has, export_bao, import_bao_bytes, observe). The one edit is
// "use crate::RnsNode;" -> "use cache_rns::RnsNode;", because this file now lives in a test crate. iroh-blobs is a
// dev-dependency only, and this file goes with iroh at step 6b.

//! Verified file fetch over Reticulum, into Cache's own iroh-blobs store.
//!
//! The transfer carries exactly what iroh carries today: iroh-blobs' bao encoding of a range of the blob (the data plus the
//! tree nodes that prove it), checked against the BLAKE3 hash and stored by `import_bao_bytes`. So verification, the store,
//! and resume after a break are iroh-blobs' own: a fetch asks only for the windows the store does not hold yet.
//!
//! A window is 16 MiB (16,384 BLAKE3 chunks of 1 KiB). One window is one request and its answer on the link, so only one
//! window is held in memory at a time, and a dropped link loses at most the window in flight.

use std::time::Duration;

use anyhow::{anyhow, bail, Result};
use bao_tree::ChunkNum;
use iroh::PublicKey;
use iroh_blobs::api::Store;
use iroh_blobs::protocol::ChunkRanges;
use iroh_blobs::Hash;

use cache_rns::RnsNode;

/// The request path for a window of a blob.
pub const BLOB_PATH: &str = "/cache/blob/window";
/// 16 MiB of 1 KiB chunks.
pub const WINDOW_CHUNKS: u64 = 16 * 1024;
const CHUNK: u64 = 1024;

const OK: u8 = 0;
const MISSING: u8 = 1;
const REFUSED: u8 = 2;

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
    match store.has(hash).await {
        Ok(true) => {}
        _ => return vec![MISSING],
    }
    match store.export_bao(hash, ChunkRanges::from(ChunkNum(start)..ChunkNum(end))).bao_to_vec().await {
        Ok(bao) => {
            let mut v = Vec::with_capacity(bao.len() + 1);
            v.push(OK);
            v.extend_from_slice(&bao);
            v
        }
        Err(_) => vec![MISSING],
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
    let have = store.observe(hash).await.map_err(|e| anyhow!("cannot read the store: {e}"))?;
    let mut f = Fetched { size: have.size(), ..Default::default() };
    if have.is_complete() {
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
            if have.ranges.is_superset(&wanted) {
                f.skipped += 1;
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
            _ => bail!("the other device refused the request"),
        }
        let bao = &reply[1..];
        if bao.len() < 8 {
            bail!("the answer is too short");
        }
        let size = u64::from_le_bytes(bao[..8].try_into().expect("8 bytes"));
        if f.size == 0 {
            f.size = size;
        } else if size != f.size {
            bail!("the other device reports a different size");
        }
        store
            .import_bao_bytes(hash, window(k), bytes::Bytes::copy_from_slice(bao))
            .await
            .map_err(|e| anyhow!("the data did not verify against the hash: {e}"))?;
        f.windows += 1;
        f.have = ((k + 1) * WINDOW_CHUNKS * CHUNK).min(f.size);
        progress(&f);
        k += 1;
    }
    let done = store.observe(hash).await.map_err(|e| anyhow!("cannot read the store: {e}"))?;
    if !done.is_complete() {
        bail!("the file is not complete after the last window");
    }
    f.have = f.size;
    Ok(f)
}
