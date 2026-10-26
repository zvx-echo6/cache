//! Reading a places.sqlite pack: its metadata, category table, nearby queries and the lookups the geocoder uses.

use crate::geo::{bbox_around, haversine_km};
use crate::schema::FORMAT_VERSION;
use rusqlite::{params, Connection, OpenFlags, OptionalExtension};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
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

#[derive(Debug, Clone, PartialEq)]
pub struct PlaceRow {
    pub id: i64,
    pub name: Option<String>,
    pub category: Option<String>,
    pub kind: Option<String>,
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
}

#[derive(Debug, Clone)]
pub struct StateRow {
    pub code: String,
    pub name: String,
}

const PLACE_COLS: &str = "p.id, p.name, p.category, p.kind, p.lat, p.lon, p.street, p.locality, p.county, p.state, p.country, p.phone, p.hours, p.website, p.source, p.source_id, p.confidence";
const LOC_COLS: &str = "l.id, l.name, l.kind, l.lat, l.lon, l.population, l.county, l.state, l.country, l.source_id";

fn place_row(r: &rusqlite::Row) -> rusqlite::Result<PlaceRow> {
    Ok(PlaceRow {
        id: r.get(0)?,
        name: r.get(1)?,
        category: r.get(2)?,
        kind: r.get(3)?,
        lat: r.get(4)?,
        lon: r.get(5)?,
        street: r.get(6)?,
        locality: r.get(7)?,
        county: r.get(8)?,
        state: r.get(9)?,
        country: r.get(10)?,
        phone: r.get(11)?,
        hours: r.get(12)?,
        website: r.get(13)?,
        source: r.get(14)?,
        source_id: r.get(15)?,
        confidence: r.get(16)?,
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
    })
}

/// One open pack.
pub struct Pack {
    pub path: PathBuf,
    pub meta: Meta,
    pub categories: Vec<Category>,
    pub states: Vec<StateRow>,
    /// Source ids of hospitals that an emergency room row was matched to.
    pub matched: HashSet<String>,
    conn: Mutex<Connection>,
    stamp: (u64, u64),
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
        if version != FORMAT_VERSION {
            return Err(Error { message: format!("{}: pack format {version} is not supported (expected {FORMAT_VERSION})", path.display()) });
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
        let matched = {
            let mut st = conn.prepare("SELECT matched_source_id FROM places WHERE matched_source_id IS NOT NULL")?;
            let rows = st.query_map([], |r| r.get::<_, String>(0))?;
            rows.collect::<rusqlite::Result<HashSet<_>>>()?
        };
        Ok(Pack { path: path.to_path_buf(), meta, categories, states, matched, conn: Mutex::new(conn), stamp: file_stamp(path) })
    }

    fn conn(&self) -> std::sync::MutexGuard<'_, Connection> {
        self.conn.lock().unwrap_or_else(|e| e.into_inner())
    }

    pub fn category(&self, id: &str) -> Option<&Category> {
        self.categories.iter().find(|c| c.id == id)
    }

    /// The nearest `limit` places of a category within `max_km`, nearest first, with their distance in km. The search
    /// widens in rings so a nearby hit never scans the whole region.
    pub fn nearby(&self, category: &str, lat: f64, lon: f64, max_km: f64, limit: usize) -> Result<Vec<(PlaceRow, f64)>> {
        let conn = self.conn();
        let mut st = conn.prepare(&format!(
            "SELECT {PLACE_COLS} FROM places_rt r JOIN places p ON p.id = r.id \
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
        Ok(out)
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
        Ok(conn.query_row(&format!("SELECT {PLACE_COLS} FROM places p WHERE p.id = ?1"), params![id], place_row).optional()?)
    }

    pub fn locality(&self, id: i64) -> Result<Option<LocalityRow>> {
        let conn = self.conn();
        Ok(conn.query_row(&format!("SELECT {LOC_COLS} FROM localities l WHERE l.id = ?1"), params![id], locality_row).optional()?)
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

/// The packs named in the config. Files are opened on demand and reopened when they change on disk, so a pack that
/// finishes downloading after the app started is picked up without reopening the handle.
pub struct PackSet {
    paths: Vec<PathBuf>,
    open: Mutex<Vec<Option<Arc<Pack>>>>,
}

impl PackSet {
    pub fn new(paths: Vec<PathBuf>) -> PackSet {
        let n = paths.len();
        PackSet { paths, open: Mutex::new(vec![None; n]) }
    }

    /// The packs that exist and open, in config order.
    pub fn current(&self) -> Vec<Arc<Pack>> {
        let mut slots = self.open.lock().unwrap_or_else(|e| e.into_inner());
        let mut out = Vec::new();
        for (i, path) in self.paths.iter().enumerate() {
            if !path.is_file() {
                slots[i] = None;
                continue;
            }
            let fresh = matches!(&slots[i], Some(p) if p.stamp == file_stamp(path));
            if !fresh {
                slots[i] = Pack::open(path).ok().map(Arc::new);
            }
            if let Some(p) = &slots[i] {
                out.push(p.clone());
            }
        }
        out
    }
}
