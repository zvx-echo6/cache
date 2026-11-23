//! Cache's own file store (step 6a of the Reticulum plan), replacing iroh-blobs.
//!
//! Files are addressed by their BLAKE3 hash, the same ids as before. The store is built directly on `bao-tree`, so the verified
//! pieces ("windows") it serves and accepts are byte for byte what iroh-blobs serves and accepts: an 8-byte little-endian size,
//! then the BLAKE3 tree nodes and data of the asked chunk ranges in pre-order, in 16 KiB chunk groups. Nothing here depends on
//! iroh; `iroh-blobs` is a dev-dependency used only by the cross-check tests.
//!
//! # Layout, under the directory given to [`Store::open`]
//!
//! - `index.sqlite`: `files` (hash, size, state, location, inline data, have), `external` (hash, path, size, mtime), `tags`.
//! - `data/<aa>/<hash>.data` and `.obao`: owned complete files above the inline limit and their pre-order outboards.
//!   `.part` and `.pobao` are a partial entry's sparse data and outboard; the `have` column says which chunks are verified.
//! - `tmp/`: files being written. Emptied when the store opens.
//!
//! # Kinds of entry
//!
//! - **Inline**: complete data of at most [`INLINE_MAX`] bytes (the iroh-blobs default), kept in the index.
//! - **Owned**: a copy the store keeps in `data/`.
//! - **External**: the person's own file, referenced in place and trusted while its size and modification time are unchanged.
//!   A changed file is reported [`Status::Absent`] and is not re-hashed here; the caller's folder scan re-adds it.
//!
//! # Crash safety
//!
//! Every file is written to a temporary file, flushed, and renamed into place. Every index change is one SQLite transaction. The
//! rename comes before the commit, so a crash leaves the old state plus, at worst, an unreferenced file that [`Store::gc`] sweeps.
//!
//! # Outside views
//!
//! The iroh bridge (stage 3) serves files from a small iroh-blobs store that references this store's data files in place. So
//! [`Options::lent`] names the hashes such a view reads: the store never deletes, moves out or rewrites their files, and
//! [`Options::protect`] names hashes to keep from [`Store::gc`] (the ones being fetched).

mod error;
mod hash;
#[cfg(feature = "test-hooks")]
#[doc(hidden)]
pub mod old_store;
#[cfg(not(feature = "test-hooks"))]
mod old_store;
mod store;

pub use bao_tree::{ChunkNum, ChunkRanges};
pub use error::{Error, Result};
pub use hash::{Hash, ParseHashError};
#[cfg(feature = "test-hooks")]
pub use store::Fault;
pub use store::{Added, MoveFailure, MoveReport, ExportHow, ExportMode, Exported, GcReport, ImportMode, Options, SetFn, Status, Store, TempTag};

/// Complete data up to this many bytes is kept inline in the index (the iroh-blobs default, 16 KiB).
pub const INLINE_MAX: u64 = 16 * 1024;

/// The chunk-group size: 2^4 chunks of 1 KiB, as iroh-blobs and `cache_rns` use.
pub const BLOCK_BYTES: u64 = 16 * 1024;
