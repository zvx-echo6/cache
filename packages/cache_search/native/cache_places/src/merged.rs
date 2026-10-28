//! The merged places database on the phone (`regions/places/<build>.sqlite`, schema `MERGED_SCHEMA`, format 3): the
//! regions engine is its one writer and merges each places tile into it as the tile arrives; `Pack` reads it like any
//! other pack. See docs/PLACES-TILES.md.
//!
//! These are the fixed signatures the regions engine and the readers build against. The bodies are not written yet: each
//! returns an error saying so, and nothing touches a file.

use crate::pack::{Error, Result};
use rusqlite::Connection;
use std::collections::HashSet;
use std::path::Path;

/// What one `merge_tile` put in.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct MergeReport {
    /// The level 1 tile id.
    pub tile: u32,
    /// The tile was already merged and was replaced.
    pub replaced: bool,
    pub places: u64,
    pub localities: u64,
    pub localities_ctx: u64,
    /// `addr_streets` rows, and the house numbers in them.
    pub streets: u64,
    pub addresses: u64,
    pub vectors: u64,
}

fn not_yet(what: &str) -> Error {
    Error { message: format!("merged::{what} is not implemented yet") }
}

/// A new merged database at `db` from the build's common file (meta, categories, kinds, states, category and kind
/// vectors), with no tiles. WAL mode, auto_vacuum = INCREMENTAL. Fails if `db` exists or the common file's tile_schema is
/// not `TILE_SCHEMA`.
pub fn create(db: &Path, common: &Path) -> Result<Connection> {
    let _ = (db, common);
    Err(not_yet("create"))
}

/// Merges the (uncompressed) tile file `shard` as level 1 tile `tile`, in one transaction: a tile already there is removed
/// first, so merging is idempotent. A tile whose tile_schema, build or tile id disagrees is refused and nothing changes.
/// `sha256` and `bytes` are the index's, recorded in `tiles`. The shard file is deleted after the commit.
pub fn merge_tile(c: &mut Connection, tile: u32, shard: &Path, sha256: &str, bytes: u64) -> Result<MergeReport> {
    let _ = (c, tile, shard, sha256, bytes);
    Err(not_yet("merge_tile"))
}

/// Removes every row of `tile` (one id range: FTS, R-tree, base, context, address and vector rows, its tile_counts and
/// its `tiles` row) and recomputes the place counts, in one transaction. A tile that is not there is not an error.
pub fn remove_tile(c: &mut Connection, tile: u32) -> Result<()> {
    let _ = (c, tile);
    Err(not_yet("remove_tile"))
}

/// The level 1 tiles merged in (the `tiles` table): what the phone has.
pub fn tiles(c: &Connection) -> Result<HashSet<u32>> {
    let _ = c;
    Err(not_yet("tiles"))
}

/// Sets meta `region_name` (the downloaded regions' names, joined by the engine).
pub fn set_regions(c: &Connection, names: &str) -> Result<()> {
    let _ = (c, names);
    Err(not_yet("set_regions"))
}

/// Housekeeping between merges: FTS 'optimize' once 8 or more tiles were merged since the last one, then
/// incremental_vacuum.
pub fn maintain(c: &Connection) -> Result<()> {
    let _ = c;
    Err(not_yet("maintain"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_stubs_say_so() {
        let mut c = Connection::open_in_memory().unwrap();
        let p = Path::new("does-not-exist.sqlite");
        assert!(create(p, p).unwrap_err().message.contains("not implemented"));
        assert!(!p.exists());
        assert!(merge_tile(&mut c, 1, p, "", 0).is_err());
        assert!(remove_tile(&mut c, 1).is_err());
        assert!(tiles(&c).is_err() && set_regions(&c, "x").is_err() && maintain(&c).is_err());
    }
}
