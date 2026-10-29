//! Reading a places.sqlite pack: its metadata, category table, nearby queries and the lookups the geocoder uses.

use crate::geo::{bbox_around, haversine_km};
use crate::schema::{FORMAT_VERSION, MERGED_FORMAT_VERSION, MIN_FORMAT_VERSION};
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::SystemTime;

#[derive(Debug, Clone)]
pub struct Error {
    pub message: String,
}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error { message: format!("sqlite: {e}") }
    }
}

pub type Result<T> = std::result::Result<T, Error>;

#[derive(Debug, Clone)]
pub struct Meta {
    pub region_id: String,
    pub region_name: String,
    /// ISO 8601 with offset: when the pack was built.
    pub built_at: String,
    pub min_lat: f64,
    pub min_lon: f64,
    pub max_lat: f64,
    pub max_lon: f64,
}

impl Meta {
    pub fn contains(&self, lat: f64, lon: f64) -> bool {
        lat >= self.min_lat && lat <= self.max_lat && lon >= self.min_lon && lon <= self.max_lon
    }

    pub fn area(&self) -> f64 {
        (self.max_lat - self.min_lat) * (self.max_lon - self.min_lon)
    }
}

#[derive(Debug, Clone)]
pub struct Category {
    pub id: String,
    pub title: String,
    pub description: String,
    pub place_count: i64,
    /// The rules JSON the builder stored.
    pub rules: String,
}

/// A category that also offers places of another category, after its own (emergency rooms: hospitals that probably have one).
#[derive(Debug, Clone)]
pub struct Fallback {
    pub category: String,
    pub primary_tier: String,
    pub tier: String,
    pub note: Option<String>,
    /// A fallback place ranks ahead of a primary one only when it is nearer by at least this many km.
    pub advantage_km: f64,
}

impl Category {
    pub fn fallback(&self) -> Option<Fallback> {
        let v: serde_json::Value = serde_json::from_str(&self.rules).ok()?;
        let r = v.as_array()?.iter().find(|r| r["source"] == "category")?;
        Some(Fallback {
            category: r["category"].as_str()?.to_string(),
            primary_tier: r["primary_tier"].as_str().unwrap_or("confirmed").to_string(),
            tier: r["tier"].as_str()?.to_string(),
            note: r["note"].as_str().map(str::to_string),
            advantage_km: r["beats_primary_only_if_nearer_by_mi"].as_f64().unwrap_or(0.0) * crate::geo::KM_PER_MI,
        })
    }
}

/// One kind of place a format 2 pack knows (`kinds` table).
#[derive(Debug, Clone, PartialEq)]
pub struct KindInfo {
    /// The stable machine id: `drinking_water`, `picnic_shelter`.
    pub id: String,
    /// How a person says it: "Drinking water tap".
    pub label: String,
    /// One line on what the kind is.
    pub description: String,
    /// The starter category it belongs to; None for kinds that are only here for the geocoder.
    pub category: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PlaceRow {
    pub id: i64,
    pub name: Option<String>,
    pub category: Option<String>,
    pub kind: Option<String>,
    /// What kind of place it is (the `kinds` table id); None in a format 1 pack.
    pub kind_id: Option<String>,
    pub lat: f64,
    pub lon: f64,
    pub street: Option<String>,
    pub locality: Option<String>,
    pub county: Option<String>,
    pub state: Option<String>,
    pub country: Option<String>,
    pub phone: Option<String>,
    pub hours: Option<String>,
    pub website: Option<String>,
    pub source: String,
    pub source_id: String,
    pub confidence: Option<f64>,
    pub wikidata_id: Option<String>,
    pub wikipedia_title: Option<String>,
    /// The article's first paragraph (under 500 characters), when the wiki step matched one by ID.
    pub summary: Option<String>,
    /// Where a route to the place goes (an airport's passenger terminal, a main entrance, a park's parking), when the
    /// builder found one; None: the place's own point. A pack built before arrival points has none.
    pub arrival: Option<(f64, f64)>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LocalityRow {
    pub id: i64,
    pub name: String,
    pub kind: String,
    pub lat: f64,
    pub lon: f64,
    pub population: Option<i64>,
    pub county: Option<String>,
    pub state: Option<String>,
    pub country: Option<String>,
    pub source_id: String,
    pub wikipedia_title: Option<String>,
    pub summary: Option<String>,
}

#[derive(Debug, Clone)]
pub struct StateRow {
    pub code: String,
    pub name: String,
}

/// The columns of a place row, in `place_row`'s order. `kind_id` is column 4 (a format 1 pack has none: see `Pack::place_cols`).
const PLACE_COLS: &str = "p.id, p.name, p.category, p.kind, p.kind_id, p.lat, p.lon, p.street, p.locality, p.county, p.state, p.country, p.phone, p.hours, p.website, p.source, p.source_id, p.confidence, p.wikidata_id, p.wikipedia_title, p.summary, p.arrival_lat, p.arrival_lon";
const LOC_COLS: &str = "l.id, l.name, l.kind, l.lat, l.lon, l.population, l.county, l.state, l.country, l.source_id, l.wikipedia_title, l.summary";

fn place_row(r: &rusqlite::Row) -> rusqlite::Result<PlaceRow> {
    Ok(PlaceRow {
        id: r.get(0)?,
        name: r.get(1)?,
        category: r.get(2)?,
        kind: r.get(3)?,
        kind_id: r.get(4)?,
        lat: r.get(5)?,
        lon: r.get(6)?,
        street: r.get(7)?,
        locality: r.get(8)?,
        county: r.get(9)?,
        state: r.get(10)?,
        country: r.get(11)?,
        phone: r.get(12)?,
        hours: r.get(13)?,
        website: r.get(14)?,
        source: r.get(15)?,
        source_id: r.get(16)?,
        confidence: r.get(17)?,
        wikidata_id: r.get(18)?,
        wikipedia_title: r.get(19)?,
        summary: r.get(20)?,
        arrival: match (r.get::<_, Option<f64>>(21)?, r.get::<_, Option<f64>>(22)?) {
            (Some(la), Some(lo)) => Some((la, lo)),
            _ => None,
        },
    })
}

fn locality_row(r: &rusqlite::Row) -> rusqlite::Result<LocalityRow> {
    Ok(LocalityRow {
        id: r.get(0)?,
        name: r.get(1)?,
        kind: r.get(2)?,
        lat: r.get(3)?,
        lon: r.get(4)?,
        population: r.get(5)?,
        county: r.get(6)?,
        state: r.get(7)?,
        country: r.get(8)?,
        source_id: r.get(9)?,
        wikipedia_title: r.get(10)?,
        summary: r.get(11)?,
    })
}

/// One open pack.
pub struct Pack {
    pub path: PathBuf,
    pub meta: Meta,
    pub categories: Vec<Category>,
    pub states: Vec<StateRow>,
    /// The format 2 `kinds` table (empty for a format 1 pack).
    pub kinds: Vec<KindInfo>,
    /// The pack's format version.
    pub format: u32,
    /// The places table has the arrival columns (packs and databases built after they were added).
    arrival: bool,
    /// Source ids of hospitals that an emergency room row was matched to.
    pub matched: HashSet<String>,
    /// The merged database's level 1 tiles (its `tiles` table); None for a single-region pack.
    tiles: Option<HashSet<u32>>,
    conn: Mutex<Connection>,
    stamp: (u64, u64),
    /// `PRAGMA data_version` when the tables above were read: another connection's commit (a tile merged) changes it.
    data_version: i64,
}

fn file_stamp(path: &Path) -> (u64, u64) {
    match std::fs::metadata(path) {
        Ok(m) => {
            let t = m.modified().ok().and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok()).map(|d| d.as_secs()).unwrap_or(0);
            (m.len(), t)
        }
        Err(_) => (0, 0),
    }
}

impl Pack {
    pub fn open(path: &Path) -> Result<Pack> {
        let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        let get = |k: &str| -> Result<Option<String>> {
            Ok(conn.query_row("SELECT value FROM meta WHERE key = ?1", params![k], |r| r.get::<_, String>(0)).optional()?)
        };
        let need = |k: &str| get(k)?.ok_or_else(|| Error { message: format!("{}: meta {k} is missing", path.display()) });
        let version: u32 = need("format_version")?.parse().unwrap_or(0);
        if !(MIN_FORMAT_VERSION..=FORMAT_VERSION).contains(&version) && version != MERGED_FORMAT_VERSION {
            return Err(Error {
                message: format!("{}: pack format {version} is not supported (this reader reads {MIN_FORMAT_VERSION} to {MERGED_FORMAT_VERSION})", path.display()),
            });
        }
        let num = |k: &str| -> Result<f64> { need(k)?.parse::<f64>().map_err(|_| Error { message: format!("meta {k} is not a number") }) };
        let meta = Meta {
            region_id: need("region_id")?,
            region_name: need("region_name")?,
            built_at: need("built_at")?,
            min_lat: num("min_lat")?,
            min_lon: num("min_lon")?,
            max_lat: num("max_lat")?,
            max_lon: num("max_lon")?,
        };
        let categories = {
            let mut st = conn.prepare("SELECT id, title, description, place_count, rules FROM categories ORDER BY sort, id")?;
            let rows = st.query_map([], |r| Ok(Category { id: r.get(0)?, title: r.get(1)?, description: r.get(2)?, place_count: r.get(3)?, rules: r.get(4)? }))?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        let states = {
            let mut st = conn.prepare("SELECT code, name FROM states ORDER BY code")?;
            let rows = st.query_map([], |r| Ok(StateRow { code: r.get(0)?, name: r.get(1)? }))?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        let kinds = if version >= 2 {
            let mut st = conn.prepare("SELECT id, label, description, category FROM kinds ORDER BY sort, id")?;
            let rows = st.query_map([], |r| Ok(KindInfo { id: r.get(0)?, label: r.get(1)?, description: r.get(2)?, category: r.get(3)? }))?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        } else {
            Vec::new()
        };
        let matched = {
            let mut st = conn.prepare("SELECT matched_source_id FROM places WHERE matched_source_id IS NOT NULL")?;
            let rows = st.query_map([], |r| r.get::<_, String>(0))?;
            rows.collect::<rusqlite::Result<HashSet<_>>>()?
        };
        let arrival = crate::merged::has_column(&conn, "main", "places", "arrival_lat")?;
        let data_version: i64 = conn.query_row("PRAGMA data_version", [], |r| r.get(0))?;
        let tiles = if version >= MERGED_FORMAT_VERSION {
            let mut st = conn.prepare("SELECT tile FROM tiles")?;
            let rows = st.query_map([], |r| r.get::<_, i64>(0))?;
            Some(rows.map(|t| t.map(|t| t as u32)).collect::<rusqlite::Result<HashSet<_>>>()?)
        } else {
            None
        };
        Ok(Pack {
            path: path.to_path_buf(),
            meta,
            categories,
            states,
            kinds,
            format: version,
            arrival,
            matched,
            tiles,
            conn: Mutex::new(conn),
            stamp: file_stamp(path),
            data_version,
        })
    }

    /// The phone's merged database (format 3), not a single-region pack.
    pub fn is_merged(&self) -> bool {
        self.tiles.is_some()
    }

    /// Whether the pack has places data at this point: a single-region pack by its box, the merged database by whether the
    /// level 1 tile there is merged in.
    pub fn covers(&self, lat: f64, lon: f64) -> bool {
        match &self.tiles {
            Some(t) => t.contains(&crate::schema::tile_id_l1(lat, lon)),
            None => self.meta.contains(lat, lon),
        }
    }

    /// The merged database's tiles (empty for a single-region pack).
    pub fn tiles(&self) -> HashSet<u32> {
        self.tiles.clone().unwrap_or_default()
    }

    /// Whether another connection changed the file since this pack read its tables.
    fn changed(&self) -> bool {
        let now: Option<i64> = self.conn().query_row("PRAGMA data_version", [], |r| r.get(0)).ok();
        now != Some(self.data_version)
    }

    pub(crate) fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn category(&self, id: &str) -> Option<&Category> {
        self.categories.iter().find(|c| c.id == id)
    }

    /// A kind of place by its id (format 2 packs).
    pub fn kind(&self, id: &str) -> Option<&KindInfo> {
        self.kinds.iter().find(|k| k.id == id)
    }

    /// The place columns for this pack's format: a format 1 pack has no `kind_id`, which then reads as NULL, and a pack built
    /// before arrival points has no arrival columns.
    fn place_cols(&self) -> String {
        let cols = if self.format >= 2 { PLACE_COLS.to_string() } else { PLACE_COLS.replace("p.kind_id", "NULL") };
        if self.arrival { cols } else { cols.replace("p.arrival_lat, p.arrival_lon", "NULL, NULL") }
    }

    /// The nearest `limit` places of a category within `max_km`, nearest first, with their distance in km. The search
    /// widens in rings so a nearby hit never scans the whole region.
    pub fn nearby(&self, category: &str, lat: f64, lon: f64, max_km: f64, limit: usize) -> Result<Vec<(PlaceRow, f64)>> {
        let conn = self.conn();
        let cols = self.place_cols();
        let mut st = conn.prepare(&format!(
            "SELECT {cols} FROM places_rt r JOIN places p ON p.id = r.id \
             WHERE r.max_lat >= ?1 AND r.min_lat <= ?2 AND r.max_lon >= ?3 AND r.min_lon <= ?4 AND p.category = ?5"
        ))?;
        let mut radius = 10.0f64;
        loop {
            let radius_now = radius.min(max_km);
            let (a, b, c, d) = bbox_around(lat, lon, radius_now);
            let rows = st.query_map(params![a, b, c, d, category], place_row)?;
            let mut hits: Vec<(PlaceRow, f64)> = Vec::new();
            for r in rows {
                let r = r?;
                let km = haversine_km(lat, lon, r.lat, r.lon);
                if km <= radius_now {
                    hits.push((r, km));
                }
            }
            if hits.len() >= limit || radius_now >= max_km {
                hits.sort_by(|x, y| x.1.partial_cmp(&y.1).unwrap_or(std::cmp::Ordering::Equal));
                hits.truncate(limit);
                return Ok(hits);
            }
            radius *= 3.0;
        }
    }

    /// The nearest `limit` places of any of these kinds (`kind_id`) within `max_km`, nearest first, with their distance in
    /// km; widened in rings like `nearby`.
    pub fn nearby_kind(&self, kinds: &[String], lat: f64, lon: f64, max_km: f64, limit: usize) -> Result<Vec<(PlaceRow, f64)>> {
        if kinds.is_empty() || self.format < 2 || limit == 0 {
            return Ok(Vec::new());
        }
        let conn = self.conn();
        let cols = self.place_cols();
        let marks = (0..kinds.len()).map(|i| format!("?{}", i + 5)).collect::<Vec<_>>().join(", ");
        let mut st = conn.prepare(&format!(
            "SELECT {cols} FROM places_rt r JOIN places p ON p.id = r.id \
             WHERE r.max_lat >= ?1 AND r.min_lat <= ?2 AND r.max_lon >= ?3 AND r.min_lon <= ?4 AND p.kind_id IN ({marks})"
        ))?;
        let mut radius = 10.0f64;
        loop {
            let radius_now = radius.min(max_km);
            let (a, b, c, d) = bbox_around(lat, lon, radius_now);
            let mut args: Vec<rusqlite::types::Value> = vec![a.into(), b.into(), c.into(), d.into()];
            args.extend(kinds.iter().map(|k| rusqlite::types::Value::from(k.clone())));
            let rows = st.query_map(rusqlite::params_from_iter(args), place_row)?;
            let mut hits: Vec<(PlaceRow, f64)> = Vec::new();
            for r in rows {
                let r = r?;
                let km = haversine_km(lat, lon, r.lat, r.lon);
                if km <= radius_now {
                    hits.push((r, km));
                }
            }
            if hits.len() >= limit || radius_now >= max_km {
                hits.sort_by(|x, y| x.1.partial_cmp(&y.1).unwrap_or(std::cmp::Ordering::Equal));
                hits.truncate(limit);
                return Ok(hits);
            }
            radius *= 3.0;
        }
    }

    /// How many places of a kind the pack has (0 for a kind it does not know, or a format 1 pack).
    pub fn kind_place_count(&self, id: &str) -> i64 {
        if self.format < 2 {
            return 0;
        }
        let conn = self.conn();
        conn.query_row("SELECT place_count FROM kinds WHERE id = ?1", params![id], |r| r.get::<_, i64>(0)).optional().ok().flatten().unwrap_or(0)
    }

    /// Localities within `radius_km`, unsorted, with their distance.
    pub fn localities_near(&self, lat: f64, lon: f64, radius_km: f64) -> Result<Vec<(LocalityRow, f64)>> {
        let conn = self.conn();
        let (a, b, c, d) = bbox_around(lat, lon, radius_km);
        let mut st = conn.prepare(&format!(
            "SELECT {LOC_COLS} FROM localities_rt r JOIN localities l ON l.id = r.id \
             WHERE r.max_lat >= ?1 AND r.min_lat <= ?2 AND r.max_lon >= ?3 AND r.min_lon <= ?4"
        ))?;
        let rows = st.query_map(params![a, b, c, d], locality_row)?;
        let mut out = Vec::new();
        for r in rows {
            let r = r?;
            let km = haversine_km(lat, lon, r.lat, r.lon);
            if km <= radius_km {
                out.push((r, km));
            }
        }
        // The merged database: towns just beyond the tiles on the phone, from the tiles that carry them, while the town's own
        // tile is not here. They have no row of their own, so their ids are negative (the context row's, negated).
        if let Some(tiles) = &self.tiles {
            let mut seen: HashSet<String> = out.iter().map(|(l, _)| l.source_id.clone()).collect();
            let mut st = conn.prepare(
                "SELECT id, name, kind, lat, lon, population, state, country, source_id FROM localities_ctx \
                 WHERE lat BETWEEN ?1 AND ?2 AND lon BETWEEN ?3 AND ?4",
            )?;
            let rows = st.query_map(params![a, b, c, d], |r| {
                Ok(LocalityRow {
                    id: -r.get::<_, i64>(0)?,
                    name: r.get(1)?,
                    kind: r.get(2)?,
                    lat: r.get(3)?,
                    lon: r.get(4)?,
                    population: r.get(5)?,
                    county: None,
                    state: r.get(6)?,
                    country: r.get(7)?,
                    source_id: r.get(8)?,
                    wikipedia_title: None,
                    summary: None,
                })
            })?;
            for r in rows {
                let r = r?;
                if tiles.contains(&crate::schema::tile_id_l1(r.lat, r.lon)) || !seen.insert(r.source_id.clone()) {
                    continue;
                }
                let km = haversine_km(lat, lon, r.lat, r.lon);
                if km <= radius_km {
                    out.push((r, km));
                }
            }
        }
        Ok(out)
    }

    /// `(id, name)` of every locality in the pack (towns, cities, villages, hamlets), for matching a misspelt name.
    pub fn locality_names(&self) -> Result<Vec<(i64, String)>> {
        let conn = self.conn();
        let mut st = conn.prepare("SELECT id, name FROM localities")?;
        let rows = st.query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    /// Full-text matches in the places index: (id, bm25 score where lower is better). `fts` is an FTS5 MATCH expression.
    pub fn fts_places(&self, fts: &str, limit: usize) -> Result<Vec<(i64, f64)>> {
        let conn = self.conn();
        let mut st = conn.prepare("SELECT rowid, bm25(places_fts, 10.0, 2.0) FROM places_fts WHERE places_fts MATCH ?1 ORDER BY 2 LIMIT ?2")?;
        let rows = st.query_map(params![fts, limit as i64], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn fts_localities(&self, fts: &str, limit: usize) -> Result<Vec<(i64, f64)>> {
        let conn = self.conn();
        let mut st = conn.prepare("SELECT rowid, bm25(localities_fts, 10.0, 2.0) FROM localities_fts WHERE localities_fts MATCH ?1 ORDER BY 2 LIMIT ?2")?;
        let rows = st.query_map(params![fts, limit as i64], |r| Ok((r.get(0)?, r.get(1)?)))?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn place(&self, id: i64) -> Result<Option<PlaceRow>> {
        let conn = self.conn();
        let cols = self.place_cols();
        Ok(conn.query_row(&format!("SELECT {cols} FROM places p WHERE p.id = ?1"), params![id], place_row).optional()?)
    }

    pub fn locality(&self, id: i64) -> Result<Option<LocalityRow>> {
        let conn = self.conn();
        Ok(conn.query_row(&format!("SELECT {LOC_COLS} FROM localities l WHERE l.id = ?1"), params![id], locality_row).optional()?)
    }

    /// A place by the id a map result carries (`place:<source_id>` without the prefix).
    pub fn place_by_source_id(&self, source_id: &str) -> Result<Option<PlaceRow>> {
        let conn = self.conn();
        let cols = self.place_cols();
        Ok(conn.query_row(&format!("SELECT {cols} FROM places p WHERE p.source_id = ?1 LIMIT 1"), params![source_id], place_row).optional()?)
    }

    pub fn locality_by_source_id(&self, source_id: &str) -> Result<Option<LocalityRow>> {
        let conn = self.conn();
        Ok(conn.query_row(&format!("SELECT {LOC_COLS} FROM localities l WHERE l.source_id = ?1 LIMIT 1"), params![source_id], locality_row).optional()?)
    }

    /// The model id the pack's vectors were made with, and their length; None for a pack that was never embedded.
    pub fn embedding(&self) -> Option<(String, usize)> {
        let conn = self.conn();
        let get = |k: &str| conn.query_row("SELECT value FROM meta WHERE key = ?1", params![k], |r| r.get::<_, String>(0)).optional().ok().flatten();
        let model = get("embed_model")?;
        let dims = get("embed_dims")?.parse::<usize>().ok()?;
        let has: bool = conn.query_row("SELECT count(*) FROM sqlite_master WHERE name = 'vectors'", [], |r| r.get::<_, i64>(0)).ok()? > 0;
        if has && dims > 0 { Some((model, dims)) } else { None }
    }

    /// The cosine of `query` (L2-normalised) with every stored vector of `kind` ("category", "place" or "locality"), best
    /// `top` first as (ref, cosine).
    pub fn vector_scan(&self, kind: &str, query: &[f32], top: usize) -> Result<Vec<(String, f32)>> {
        let conn = self.conn();
        let mut st = conn.prepare("SELECT ref, vec FROM vectors WHERE kind = ?1")?;
        let mut rows = st.query(params![kind])?;
        let mut best: Vec<(String, f32)> = Vec::new();
        while let Some(r) = rows.next()? {
            let blob: Vec<u8> = r.get(1)?;
            let Some(c) = crate::schema::dot_packed(&blob, query) else { continue };
            if best.len() < top || c > best[best.len() - 1].1 {
                let id: String = r.get(0)?;
                let at = best.iter().position(|(_, x)| c > *x).unwrap_or(best.len());
                best.insert(at, (id, c));
                best.truncate(top);
            }
        }
        Ok(best)
    }

    /// The alternative names of a place or locality, joined by spaces (the FTS alt_names column).
    pub fn alt_names(&self, locality: bool, id: i64) -> Result<String> {
        let conn = self.conn();
        let table = if locality { "localities_fts" } else { "places_fts" };
        Ok(conn
            .query_row(&format!("SELECT alt_names FROM {table} WHERE rowid = ?1"), params![id], |r| r.get::<_, Option<String>>(0))
            .optional()?
            .flatten()
            .unwrap_or_default())
    }
}

/// The phone's merged database (when the config names its folder) and the single-region packs named in the config. Files
/// are opened on demand and reopened when they change on disk, so a pack that finishes downloading after the app started is
/// picked up without reopening the handle; a tile merged into the merged database is seen by the next `current()`.
pub struct PackSet {
    legacy: Mutex<Legacy>,
    /// The folder of `CURRENT` and the merged databases (`regions/places`): from the config, else the regions engine's.
    merged_dir: RwLock<Option<PathBuf>>,
    merged: Mutex<Merged>,
}

struct Legacy {
    paths: Vec<PathBuf>,
    open: Vec<Option<Arc<Pack>>>,
}

#[derive(Default)]
struct Merged {
    /// `CURRENT`'s (len, mtime in ns) when it was last read, and the database it named.
    stamp: Option<(u64, u128)>,
    db: Option<PathBuf>,
    pack: Option<Arc<Pack>>,
}

fn fine_stamp(path: &Path) -> Option<(u64, u128)> {
    let m = std::fs::metadata(path).ok()?;
    let t = m.modified().ok().and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok()).map(|d| d.as_nanos()).unwrap_or(0);
    Some((m.len(), t))
}

impl PackSet {
    pub fn new(paths: Vec<PathBuf>, merged_dir: Option<PathBuf>) -> PackSet {
        let n = paths.len();
        PackSet { legacy: Mutex::new(Legacy { paths, open: vec![None; n] }), merged_dir: RwLock::new(merged_dir), merged: Mutex::new(Merged::default()) }
    }

    /// Replaces the single-region packs (the app's refresh), and makes the next `current()` check everything again.
    pub fn set_legacy(&self, paths: Vec<PathBuf>) {
        let n = paths.len();
        *self.legacy.lock().unwrap_or_else(|e| e.into_inner()) = Legacy { paths, open: vec![None; n] };
        self.recheck();
    }

    /// The next `current()` reads `CURRENT` again and reopens every pack.
    pub fn recheck(&self) {
        *self.merged.lock().unwrap_or_else(|e| e.into_inner()) = Merged::default();
        let mut l = self.legacy.lock().unwrap_or_else(|e| e.into_inner());
        l.open.iter_mut().for_each(|o| *o = None);
    }

    /// The single-region packs named, in config order (whether or not they exist).
    pub fn legacy_paths(&self) -> Vec<PathBuf> {
        self.legacy.lock().unwrap_or_else(|e| e.into_inner()).paths.clone()
    }

    pub fn merged_dir(&self) -> Option<PathBuf> {
        self.merged_dir.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Uses `dir` as the merged database's folder when none was configured (the regions engine's, plugged in by the host).
    /// Returns whether it was taken.
    pub fn default_merged_dir(&self, dir: PathBuf) -> bool {
        let mut d = self.merged_dir.write().unwrap_or_else(|e| e.into_inner());
        if d.is_some() {
            return false;
        }
        *d = Some(dir);
        drop(d);
        self.recheck();
        true
    }

    /// The merged database, if there is one: the one `CURRENT` names, reread when another connection changed it.
    fn merged(&self) -> Option<Arc<Pack>> {
        let dir = self.merged_dir()?;
        let mut m = self.merged.lock().unwrap_or_else(|e| e.into_inner());
        let current = dir.join("CURRENT");
        let stamp = fine_stamp(&current);
        if stamp.is_none() {
            *m = Merged::default();
            return None;
        }
        if stamp != m.stamp {
            let build = std::fs::read_to_string(&current).ok().map(|s| s.trim().to_string()).filter(|b| safe_name(b));
            m.stamp = stamp;
            m.db = build.map(|b| dir.join(format!("{b}.sqlite")));
        }
        let db = m.db.clone()?;
        let fresh = matches!(&m.pack, Some(p) if p.path == db && !p.changed());
        if !fresh {
            m.pack = if db.is_file() { Pack::open(&db).ok().map(Arc::new) } else { None };
        }
        m.pack.clone()
    }

    /// The packs that exist and open: the merged database first, then the single-region packs in config order.
    pub fn current(&self) -> Vec<Arc<Pack>> {
        let mut out: Vec<Arc<Pack>> = self.merged().into_iter().collect();
        let mut l = self.legacy.lock().unwrap_or_else(|e| e.into_inner());
        let Legacy { paths, open } = &mut *l;
        for (i, path) in paths.iter().enumerate() {
            if !path.is_file() {
                open[i] = None;
                continue;
            }
            let fresh = matches!(&open[i], Some(p) if p.stamp == file_stamp(path));
            if !fresh {
                open[i] = Pack::open(path).ok().map(Arc::new);
            }
            if let Some(p) = &open[i] {
                out.push(p.clone());
            }
        }
        out
    }
}

/// A build name as `CURRENT` holds it: a plain file name, nothing that leaves the folder.
fn safe_name(b: &str) -> bool {
    !b.is_empty() && b.len() <= 64 && !b.starts_with('.') && b.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_' || c == b'.')
}
