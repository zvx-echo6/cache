//! `places_pack harvest`: the first step of a tiled build (docs/PLACES-TILES.md). Reads the sources once (an OSM extract
//! and the Overture CSV), applies the category and kind rules as `build` does, and writes every `Raw` place and
//! `RawLocality` to `harvest.sqlite`, by level 1 tile, as it goes, so a continent never sits in memory at once.
//!
//! ```sql
//! raw(what TEXT ('place' | 'locality' | 'anchor'), source TEXT, tile INTEGER, lat REAL, lon REAL, json TEXT)   -- index on tile
//! meta(key, value)                                                                      -- sources, rules, counts
//! ```
//!
//! The rowid order is the read order, and the later steps load rows in that order, so every block sees the same order
//! for the rows it shares with a neighbour (merges and dedupes are decided the same way on both sides of an edge).

use crate::model::{source_name, Anchor, Harvest, PlaceSource, Raw, RawLocality};
use crate::rules::Rules;
use cache_places::schema::tile_id_l1;
use rusqlite::{params, Connection};
use std::cell::RefCell;
use std::path::Path;
use std::rc::Rc;

pub const HARVEST_SQL: &str = r#"
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE raw (what TEXT NOT NULL, source TEXT NOT NULL, tile INTEGER NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, json TEXT NOT NULL);
"#;

pub struct HarvestReport {
    pub places: usize,
    pub localities: usize,
    pub sources: Vec<String>,
}

pub(crate) fn write(c: &Connection, places: Vec<Raw>, locs: Vec<RawLocality>, anchors: Vec<Anchor>) -> Result<(), String> {
    let tx = c.unchecked_transaction().map_err(|e| e.to_string())?;
    {
        let mut st = tx.prepare_cached("INSERT INTO raw(what, source, tile, lat, lon, json) VALUES (?1, ?2, ?3, ?4, ?5, ?6)").map_err(|e| e.to_string())?;
        for p in places {
            // An OSM way whose nodes were all outside the extract has no centre.
            if !p.lat.is_finite() || !p.lon.is_finite() {
                continue;
            }
            let j = serde_json::to_string(&p).map_err(|e| e.to_string())?;
            st.execute(params!["place", p.source, tile_id_l1(p.lat, p.lon), p.lat, p.lon, j]).map_err(|e| e.to_string())?;
        }
        for l in locs {
            let j = serde_json::to_string(&l).map_err(|e| e.to_string())?;
            st.execute(params!["locality", "osm", tile_id_l1(l.lat, l.lon), l.lat, l.lon, j]).map_err(|e| e.to_string())?;
        }
        for a in anchors {
            let j = serde_json::to_string(&a).map_err(|e| e.to_string())?;
            st.execute(params!["anchor", "osm", tile_id_l1(a.lat, a.lon), a.lat, a.lon, j]).map_err(|e| e.to_string())?;
        }
    }
    tx.commit().map_err(|e| e.to_string())
}

/// Reads `sources` into a new `out` (replacing any file there). `include_general` false keeps only category places.
pub fn harvest(rules: &Rules, rules_json: &str, sources: &mut [Box<dyn PlaceSource>], include_general: bool, out: &Path) -> Result<HarvestReport, String> {
    let _ = std::fs::remove_file(out);
    let c = Connection::open(out).map_err(|e| format!("{}: {e}", out.display()))?;
    c.execute_batch("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;").map_err(|e| e.to_string())?;
    c.execute_batch(HARVEST_SQL).map_err(|e| e.to_string())?;
    let c = Rc::new(RefCell::new(c));
    let sink_conn = Rc::clone(&c);
    let mut h = Harvest::with_sink(Box::new(move |mut p, l, a| {
        if !include_general {
            p.retain(|r| r.category.is_some());
        }
        write(&sink_conn.borrow(), p, l, a)
    }));
    let mut described = Vec::new();
    for s in sources.iter_mut() {
        eprintln!("reading {}", s.describe());
        let before = (h.n_places(), h.n_localities());
        s.read(rules, &mut h)?;
        h.flush();
        eprintln!("  {} places, {} localities", h.n_places() - before.0, h.n_localities() - before.1);
        described.push(s.describe());
    }
    h.finish()?;
    drop(h);
    let c = c.borrow();
    c.execute_batch("CREATE INDEX raw_tile ON raw(tile);").map_err(|e| e.to_string())?;
    let n = |what: &str| c.query_row("SELECT COUNT(*) FROM raw WHERE what = ?1", [what], |r| r.get::<_, i64>(0)).unwrap_or(0) as usize;
    let (places, localities) = (n("place"), n("locality"));
    for (k, v) in [
        ("sources", described.join("; ")),
        ("builder_rules", rules_json.to_string()),
        ("include_general", include_general.to_string()),
        ("places", places.to_string()),
        ("localities", localities.to_string()),
        ("anchors", n("anchor").to_string()),
        ("harvested_at", chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%:z").to_string()),
    ] {
        c.execute("INSERT INTO meta(key, value) VALUES (?1, ?2)", params![k, v]).map_err(|e| e.to_string())?;
    }
    Ok(HarvestReport { places, localities, sources: described })
}

/// The harvested places, towns and arrival anchors whose points are inside [west, south, east, north) (the halo included),
/// in read order. A harvest made before arrival anchors has none.
pub fn load(c: &Connection, rect: [f64; 4]) -> Result<(Vec<Raw>, Vec<RawLocality>, Vec<Anchor>), String> {
    let [w, s, e, n] = rect;
    // The tiles the box touches, for the index; the box itself then filters exactly.
    let (t0, t1) = (tile_id_l1(s, w), tile_id_l1(n - 1e-9, e - 1e-9));
    let (c0, c1) = (t0 % 360, t1 % 360);
    let mut tiles = Vec::new();
    for row in t0 / 360..=t1 / 360 {
        for col in c0..=c1 {
            tiles.push((row * 360 + col).to_string());
        }
    }
    let sql = format!(
        "SELECT what, source, json FROM raw WHERE tile IN ({}) AND lat >= ?1 AND lat < ?2 AND lon >= ?3 AND lon < ?4 ORDER BY rowid",
        tiles.join(",")
    );
    let mut st = c.prepare(&sql).map_err(|e| e.to_string())?;
    let mut rows = st.query(params![s, n, w, e]).map_err(|e| e.to_string())?;
    let (mut places, mut locs, mut anchors) = (Vec::new(), Vec::new(), Vec::new());
    while let Some(r) = rows.next().map_err(|e| e.to_string())? {
        let what: String = r.get(0).map_err(|e| e.to_string())?;
        let source: String = r.get(1).map_err(|e| e.to_string())?;
        let json: String = r.get(2).map_err(|e| e.to_string())?;
        if what == "place" {
            let mut p = serde_json::from_str::<Raw>(&json).map_err(|e| format!("harvest row: {e}"))?;
            p.source = source_name(&source).ok_or_else(|| format!("harvest row: unknown source {source:?}"))?;
            places.push(p);
        } else if what == "anchor" {
            anchors.push(serde_json::from_str::<Anchor>(&json).map_err(|e| format!("harvest row: {e}"))?);
        } else {
            locs.push(serde_json::from_str::<RawLocality>(&json).map_err(|e| format!("harvest row: {e}"))?);
        }
    }
    Ok((places, locs, anchors))
}

/// The level 1 tiles that have any harvested place or town.
pub fn tiles(c: &Connection) -> Result<Vec<u32>, String> {
    let mut st = c.prepare("SELECT DISTINCT tile FROM raw WHERE what <> 'anchor' ORDER BY tile").map_err(|e| e.to_string())?;
    let v = st.query_map([], |r| r.get::<_, u32>(0)).map_err(|e| e.to_string())?.collect::<Result<Vec<_>, _>>().map_err(|e| e.to_string())?;
    Ok(v)
}
