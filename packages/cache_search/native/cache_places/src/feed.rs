//! Places that arrive while the core is open (docs/PLACES-TILES.md): the feed the search host plugs in (the regions
//! engine, which fetches and merges places tiles), and what a search says about the places on the phone
//! (`places` and `warning_code` in the `cs_map_search` answer).

use crate::pack::Pack;
use crate::schema::{tile_id_l1, MERGED_FORMAT_VERSION};
use rusqlite::params;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;

/// What fetching the places tiles around a point did (the regions engine's `stream` answer for places).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct PrepareAnswer {
    /// Tiles fetched and merged during the call.
    pub fetched: u32,
    /// Tiles still on their way when the call stopped waiting.
    pub pending: u32,
    /// Tiles that could not be fetched.
    pub missing: u32,
    /// False when nothing could be fetched at all (offline, the network off, no places build).
    pub ok: bool,
}

/// Plugged into the places core by the search host: fetches the tiles around a point before a search, and counts the
/// changes to the places on the phone (every merge, removal and build switch).
pub trait PlacesFeed: Send + Sync {
    /// Fetches the places tiles around (`lat`, `lon`) that are not on the phone, waiting at most `wait`.
    fn prepare(&self, lat: f64, lon: f64, wait: Duration) -> PrepareAnswer;
    /// Goes up by one on every change to the places on the phone.
    fn generation(&self) -> u64;
}

/// A merged database with at least one tile, or any single-region pack.
pub(crate) fn has_data(p: &Pack) -> bool {
    if p.format != MERGED_FORMAT_VERSION {
        return true;
    }
    p.conn().query_row("SELECT EXISTS (SELECT 1 FROM tiles)", [], |r| r.get::<_, bool>(0)).unwrap_or(false)
}

/// The pack holds the point: a single-region pack by its box, the merged database by its tiles.
pub(crate) fn holds(p: &Pack, lat: f64, lon: f64) -> bool {
    if p.format != MERGED_FORMAT_VERSION {
        return p.meta.contains(lat, lon);
    }
    let tile = tile_id_l1(lat, lon);
    p.conn().query_row("SELECT EXISTS (SELECT 1 FROM tiles WHERE tile = ?1)", params![tile], |r| r.get::<_, bool>(0)).unwrap_or(false)
}

/// The `places` object of a search answer (`installed`, `covers`, `pending`) and its `warning_code`: `fetching` while a
/// tile is on its way, `no_places` when nothing is on the phone and nothing could be fetched, `not_here` when nothing on
/// the phone holds the search centre and nothing could be fetched; None when there is nothing to say. `prepared` is what
/// the feed said before the search (None when it was not asked: no feed, or the network may not be used). Without a
/// centre, what is installed counts as covering.
pub fn places_state(packs: &[Arc<Pack>], centre: Option<(f64, f64)>, prepared: Option<&PrepareAnswer>) -> (Value, Option<&'static str>) {
    let installed = packs.iter().any(|p| has_data(p));
    let covers = match centre {
        Some((la, lo)) => packs.iter().any(|p| has_data(p) && holds(p, la, lo)),
        None => installed,
    };
    let pending = prepared.map(|a| a.pending).unwrap_or(0);
    let fetched_all = prepared.is_some_and(|a| a.ok && a.missing == 0);
    let code = if pending > 0 {
        Some("fetching")
    } else if !installed && !fetched_all {
        Some("no_places")
    } else if installed && !covers && !fetched_all {
        Some("not_here")
    } else {
        None
    };
    (json!({"installed": installed, "covers": covers, "pending": pending}), code)
}
