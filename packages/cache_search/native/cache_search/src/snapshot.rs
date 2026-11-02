//! Syncable index snapshots. The kind-neutral core lives in the `cache_snapshot` crate (shared with `cache_regions`, which
//! `cache_search` depends on); it is re-exported here so `crate::snapshot::...` stays as it was.

pub use cache_snapshot::*;
