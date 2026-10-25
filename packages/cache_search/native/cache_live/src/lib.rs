//! The live data engine: online data the app downloads while it can and uses offline until it expires.
//!
//! One general engine; a source is a definition file (data, never code), see `def.rs` and DESIGN.md. The core has no
//! scheduler: the app (or the CLI) calls `Live::fetch`. What is downloaded is stored in live.sqlite, one row per
//! (source id, place key), and read back by `Live::get` (the app's screens) and by the `live_data` tool
//! (`LiveDataTool`): both come from the same stored row through the same code (`Live::view`).
//! Nothing here reads the system clock unless the caller gives no time: every call takes `now`.

pub mod def;
pub mod fetch;
pub mod geo;
pub mod map;
pub mod tool;
pub mod tz;

use cache_tool::SavedPlaces;
use chrono::DateTime;
use def::SourceDef;
use map::{age_words, stamp, Item};
use tz::Zone;
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::Path;

pub use tool::LiveDataTool;

/// An error with one of the core's stable codes (`bad_json`, `not_found`, `io`, `not_configured`, `bad_response`,
/// `fetch_failed`, `quota`, `key_missing`, `internal`).
#[derive(Debug, Clone)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(code: &'static str, m: impl Into<String>) -> Error {
        Error { code, message: m.into() }
    }
    pub fn bad_json(m: impl Into<String>) -> Error {
        Error::new("bad_json", m)
    }
    pub fn not_found(m: impl Into<String>) -> Error {
        Error::new("not_found", m)
    }
    pub fn internal(m: impl Into<String>) -> Error {
        Error::new("internal", m)
    }
    pub fn bad_response(m: impl Into<String>) -> Error {
        Error::new("bad_response", m)
    }
    pub fn fetch_failed(m: impl Into<String>) -> Error {
        Error::new("fetch_failed", m)
    }
    pub fn quota(m: impl Into<String>) -> Error {
        Error::new("quota", m)
    }
    pub fn key_missing(m: impl Into<String>) -> Error {
        Error::new("key_missing", m)
    }
}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error::new("io", format!("sqlite: {e}"))
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::bad_json(e.to_string())
    }
}

/// The `live` section of the `cs_open` config.
#[derive(Debug, Clone, Deserialize)]
pub struct LiveCfg {
    pub db_path: String,
    pub sources_dir: String,
}

/// A place live data is fetched for. `key` is part of every item address, so it has no `/`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Place {
    pub key: String,
    pub name: String,
    pub lat: f64,
    pub lon: f64,
}

/// The key for "where the phone is": the position rounded to 2 decimals (about 1 km), so data downloaded a little
/// way from here is still the data for here. The `live_data` tool uses this key for the phone's location, so the
/// app fetches for the current position with `{"key": here_key(lat, lon), "name": "current location", lat, lon}`.
pub fn here_key(lat: f64, lon: f64) -> String {
    format!("at:{:.2},{:.2}", lat, lon)
}

pub fn valid_key(k: &str) -> bool {
    !k.is_empty() && k.len() <= 100 && k.chars().all(|c| c.is_ascii_alphanumeric() || "_-.:,+".contains(c))
}

/// Unix seconds from an ISO 8601 time with offset, or the system clock when none is given.
pub fn now_from(iso: Option<&str>) -> Result<i64> {
    match iso {
        Some(s) => DateTime::parse_from_rfc3339(s.trim())
            .map(|d| d.timestamp())
            .map_err(|_| Error::bad_json(format!("now {s:?} is not an ISO 8601 time with an offset"))),
        None => Ok(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)),
    }
}

/// The system clock as ISO 8601 (UTC), for callers that have no better "now" (the CLI).
pub fn system_now_iso() -> String {
    let t = now_from(None).unwrap_or(0);
    DateTime::from_timestamp(t, 0).map(|d| d.format("%Y-%m-%dT%H:%M:%S+00:00").to_string()).unwrap_or_default()
}

/// A place from a request: a string is a saved place (key or name); an object is `{key,name,lat,lon}` as given.
pub fn place_from(v: Option<&Value>, places: &dyn SavedPlaces) -> Result<Place> {
    match v {
        Some(Value::String(s)) => places
            .resolve(s)
            .map(|p| Place { key: p.key, name: p.name, lat: p.lat, lon: p.lon })
            .ok_or_else(|| Error::not_found(format!("no saved place called {:?}", s.trim()))),
        Some(o @ Value::Object(_)) => {
            let p: Place = serde_json::from_value(o.clone()).map_err(|e| Error::bad_json(format!("place: {e}")))?;
            if !(p.lat.is_finite() && p.lon.is_finite() && p.lat.abs() <= 90.0 && p.lon.abs() <= 180.0) {
                return Err(Error::bad_json("place lat/lon out of range"));
            }
            if !valid_key(&p.key) {
                return Err(Error::bad_json(format!("invalid place key {:?}", p.key)));
            }
            Ok(p)
        }
        _ => Err(Error::bad_json("\"place\" (a saved place name or {key,name,lat,lon}) is required")),
    }
}

/// An installed definition plus a hash of its file (a changed file re-maps stored responses).
pub struct Loaded {
    pub def: SourceDef,
    pub hash: String,
}

fn fnv(bytes: &[u8]) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

fn open_db(path: &Path) -> Result<Connection> {
    if let Some(dir) = path.parent() {
        if !dir.as_os_str().is_empty() {
            let _ = std::fs::create_dir_all(dir);
        }
    }
    let c = Connection::open(path)?;
    c.busy_timeout(std::time::Duration::from_secs(5))?;
    c.execute_batch(
        "CREATE TABLE IF NOT EXISTS live_fetch(
            source TEXT NOT NULL, place_key TEXT NOT NULL, place_name TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL,
            fetched_at INTEGER NOT NULL, valid_until INTEGER NOT NULL, utc_offset INTEGER, tz TEXT, not_covered_after TEXT,
            def_hash TEXT NOT NULL, items_json TEXT NOT NULL, raw TEXT NOT NULL,
            PRIMARY KEY(source, place_key));
         CREATE TABLE IF NOT EXISTS live_error(
            source TEXT NOT NULL, place_key TEXT NOT NULL, at INTEGER NOT NULL, code TEXT NOT NULL, message TEXT NOT NULL,
            PRIMARY KEY(source, place_key));
         CREATE TABLE IF NOT EXISTS live_log(source TEXT NOT NULL, at INTEGER NOT NULL);
         CREATE INDEX IF NOT EXISTS live_log_at ON live_log(source, at);",
    )?;
    // a database made before the tz column existed
    let _ = c.execute("ALTER TABLE live_fetch ADD COLUMN tz TEXT", []);
    Ok(c)
}

/// One stored fetch.
pub struct Row {
    pub place: Place,
    pub fetched_at: i64,
    pub valid_until: i64,
    /// A fixed offset the response gave (seconds); None when the zone is named or UTC.
    pub utc_offset: Option<i32>,
    /// The IANA zone name (`America/Boise`), from the response or the offline lookup.
    pub tz: Option<String>,
    pub not_covered_after: Option<String>,
    pub def_hash: String,
    pub items: Vec<Item>,
    pub raw: String,
}

pub(crate) fn load_row(c: &Connection, source: &str, key: &str) -> Result<Option<Row>> {
    #[allow(clippy::type_complexity)]
    let r = c
        .query_row(
            "SELECT place_name,lat,lon,fetched_at,valid_until,utc_offset,not_covered_after,def_hash,items_json,raw,tz
             FROM live_fetch WHERE source=?1 AND place_key=?2",
            params![source, key],
            |r| {
                Ok((
                    Place { key: key.to_string(), name: r.get(0)?, lat: r.get(1)?, lon: r.get(2)? },
                    r.get::<_, i64>(3)?,
                    r.get::<_, i64>(4)?,
                    r.get::<_, Option<i32>>(5)?,
                    r.get::<_, Option<String>>(6)?,
                    r.get::<_, String>(7)?,
                    r.get::<_, String>(8)?,
                    r.get::<_, String>(9)?,
                    r.get::<_, Option<String>>(10)?,
                ))
            },
        )
        .optional()?;
    let Some((place, fetched_at, valid_until, utc_offset, not_covered_after, def_hash, items, raw, tz)) = r else {
        return Ok(None);
    };
    let items: Vec<Item> = serde_json::from_str(&items).map_err(|e| Error::internal(format!("stored items: {e}")))?;
    Ok(Some(Row { place, fetched_at, valid_until, utc_offset, tz, not_covered_after, def_hash, items, raw }))
}

pub(crate) fn save_row(c: &Connection, source: &str, row: &Row) -> Result<()> {
    c.execute(
        "INSERT INTO live_fetch(source,place_key,place_name,lat,lon,fetched_at,valid_until,utc_offset,not_covered_after,def_hash,items_json,raw,tz)
         VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
         ON CONFLICT(source,place_key) DO UPDATE SET place_name=?3,lat=?4,lon=?5,fetched_at=?6,valid_until=?7,
            utc_offset=?8,not_covered_after=?9,def_hash=?10,items_json=?11,raw=?12,tz=?13",
        params![
            source,
            row.place.key,
            row.place.name,
            row.place.lat,
            row.place.lon,
            row.fetched_at,
            row.valid_until,
            row.utc_offset,
            row.not_covered_after,
            row.def_hash,
            serde_json::to_string(&row.items)?,
            row.raw,
            row.tz
        ],
    )?;
    Ok(())
}

impl Row {
    pub fn zone(&self) -> Zone {
        self.tz.as_deref().and_then(Zone::from_name).or(self.utc_offset.map(Zone::Fixed)).unwrap_or(Zone::UTC)
    }

    /// Store a zone: a named zone by name, a fixed one by its offset.
    pub fn set_zone(&mut self, z: Zone) {
        self.tz = z.name().map(str::to_string);
        self.utc_offset = if let Zone::Fixed(s) = z { if s != 0 { Some(s) } else { None } } else { None };
    }
}

/// A stored fetch ready to show: the row plus what time makes of it.
pub struct View {
    pub row: Row,
    pub now: i64,
    pub expired: bool,
    /// Items that have not ended.
    pub items: Vec<Item>,
    pub last_error: Option<LastError>,
}

#[derive(Debug, Clone, Serialize)]
pub struct LastError {
    pub code: String,
    pub message: String,
    pub at: String,
}

impl View {
    /// The place's zone (see `tz.rs`).
    pub fn zone(&self) -> Zone {
        self.row.zone()
    }
    pub fn age_secs(&self) -> i64 {
        (self.now - self.row.fetched_at).max(0)
    }
}

/// `live:<source>/<place-key>/<item-key>`: the address of one item, which the tool framework numbers.
pub fn address(source: &str, place_key: &str, item_key: &str) -> String {
    format!("live:{source}/{place_key}/{item_key}")
}

// ---- the JSON the app's screens get (cs_live_get / cs_live_fetch) ----

#[derive(Serialize)]
struct SourceOut<'a> {
    id: &'a str,
    title: &'a str,
    provider: &'a str,
    description: &'a str,
    attribution: Option<&'a str>,
}

#[derive(Serialize)]
struct GetItem {
    address: String,
    label: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    time: Option<String>,
    fields: map::Fields,
    #[serde(skip_serializing_if = "Option::is_none")]
    point: Option<map::Point>,
    #[serde(skip_serializing_if = "Option::is_none")]
    area: Option<Value>,
}

#[derive(Serialize)]
struct GetOut<'a> {
    source: SourceOut<'a>,
    place: &'a Place,
    #[serde(skip_serializing_if = "Option::is_none")]
    fetched: Option<bool>,
    fetched_at: String,
    valid_until: String,
    age: String,
    age_seconds: i64,
    expired: bool,
    not_covered_after: Option<&'a str>,
    last_error: Option<&'a LastError>,
    items: Vec<GetItem>,
}

/// The live data engine of one `cs_open` handle.
pub struct Live {
    pub cfg: LiveCfg,
}

impl Live {
    pub fn new(cfg: LiveCfg) -> Live {
        Live { cfg }
    }

    pub(crate) fn db(&self) -> Result<Connection> {
        open_db(Path::new(&self.cfg.db_path))
    }

    /// The installed definitions (sorted by id) and the files that could not be read.
    pub fn defs(&self) -> (Vec<Loaded>, Vec<(String, String)>) {
        let mut files: Vec<_> = match std::fs::read_dir(&self.cfg.sources_dir) {
            Ok(rd) => rd.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.extension().map(|x| x == "json").unwrap_or(false)).collect(),
            Err(_) => Vec::new(),
        };
        files.sort();
        let (mut ok, mut errs): (Vec<Loaded>, Vec<(String, String)>) = (Vec::new(), Vec::new());
        for f in files {
            let name = f.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
            let text = match std::fs::read_to_string(&f) {
                Ok(t) => t,
                Err(e) => {
                    errs.push((name, format!("reading: {e}")));
                    continue;
                }
            };
            match SourceDef::parse(&text) {
                Ok(d) if ok.iter().any(|l| l.def.id == d.id) => errs.push((name, format!("duplicate source id {:?}", d.id))),
                Ok(d) => ok.push(Loaded { hash: fnv(text.as_bytes()), def: d }),
                Err(e) => errs.push((name, e.message)),
            }
        }
        ok.sort_by(|a, b| a.def.id.cmp(&b.def.id));
        (ok, errs)
    }

    pub fn def(&self, id: &str) -> Option<Loaded> {
        self.defs().0.into_iter().find(|l| l.def.id == id)
    }

    /// `{"sources":[...],"errors":[{"file","message"}]}`: what the app needs to list sources and ask for keys.
    pub fn sources_json(&self) -> String {
        let (defs, errs) = self.defs();
        let sources: Vec<Value> = defs
            .iter()
            .map(|l| {
                let d = &l.def;
                serde_json::json!({
                    "id": d.id, "title": d.title, "provider": d.provider, "description": d.description,
                    "attribution": d.attribution, "refresh_minutes": d.refresh_minutes,
                    "api_key": d.api_key.as_ref().map(|k| serde_json::json!({"alias": k.alias, "required": k.required})),
                    "quota": {"per_minute": d.quota.per_minute, "per_day": d.quota.per_day, "per_month": d.quota.per_month},
                })
            })
            .collect();
        let errors: Vec<Value> = errs.iter().map(|(f, m)| serde_json::json!({"file": f, "message": m})).collect();
        serde_json::json!({"sources": sources, "errors": errors}).to_string()
    }

    /// Delete everything stored for a place (when the saved place is deleted).
    pub fn forget_place(&self, key: &str) {
        if let Ok(c) = self.db() {
            let _ = c.execute("DELETE FROM live_fetch WHERE place_key=?1", [key]);
            let _ = c.execute("DELETE FROM live_error WHERE place_key=?1", [key]);
        }
    }

    /// The stored data for (source, place) at time `now`, re-mapped from the stored response if the definition
    /// changed. `None` when nothing was ever downloaded for it.
    pub fn view(&self, c: &Connection, l: &Loaded, place: &Place, now: i64) -> Result<Option<View>> {
        let Some(mut row) = load_row(c, &l.def.id, &place.key)? else { return Ok(None) };
        if row.def_hash != l.hash {
            let root: Value = serde_json::from_str(&row.raw).map_err(|e| Error::bad_response(format!("stored response: {e}")))?;
            let m = map::map_response(&l.def, &root, row.fetched_at, row.place.lat, row.place.lon)?;
            row.items = m.items;
            row.set_zone(m.zone);
            row.valid_until = m.valid_until;
            row.not_covered_after = m.not_covered_after;
            row.def_hash = l.hash.clone();
            save_row(c, &l.def.id, &row)?;
        }
        let items = row.items.iter().filter(|i| i.ends.map(|e| e > now).unwrap_or(true)).cloned().collect();
        let last_error = c
            .query_row("SELECT at,code,message FROM live_error WHERE source=?1 AND place_key=?2", params![l.def.id, place.key], |r| {
                Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?))
            })
            .optional()?
            .map(|(at, code, message)| LastError { code, message, at: stamp(at, &row.zone()) });
        Ok(Some(View { now, expired: now > row.valid_until, row, items, last_error }))
    }

    fn view_json(&self, l: &Loaded, v: &View, fetched: Option<bool>) -> Result<String> {
        let d = &l.def;
        let off = v.zone();
        let out = GetOut {
            source: SourceOut { id: &d.id, title: &d.title, provider: &d.provider, description: &d.description, attribution: d.attribution.as_deref() },
            place: &v.row.place,
            fetched,
            fetched_at: stamp(v.row.fetched_at, &off),
            valid_until: stamp(v.row.valid_until, &off),
            age: age_words(v.age_secs()),
            age_seconds: v.age_secs(),
            expired: v.expired,
            not_covered_after: v.row.not_covered_after.as_deref(),
            last_error: v.last_error.as_ref(),
            items: v
                .items
                .iter()
                .map(|i| GetItem {
                    address: address(&d.id, &v.row.place.key, &i.key),
                    label: i.label.clone(),
                    time: i.time.clone(),
                    fields: i.fields.clone(),
                    point: i.point.clone(),
                    area: i.area.clone(),
                })
                .collect(),
        };
        Ok(serde_json::to_string(&out)?)
    }

    /// `cs_live_get`: `{source, place, now?}`. The stored data with its age and expiry, expired or not (the app's
    /// screens show "as of"); `not_found` when nothing was ever downloaded. `now` is ISO 8601 with an offset
    /// (default: the system clock). Every item carries an `address`.
    pub fn get(&self, req_json: &str, places: &dyn SavedPlaces) -> Result<String> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Req {
            source: String,
            #[serde(default)]
            place: Option<Value>,
            #[serde(default)]
            now: Option<String>,
        }
        let r: Req = serde_json::from_str(req_json).map_err(|e| Error::bad_json(format!("request_json: {e}")))?;
        let now = now_from(r.now.as_deref())?;
        let l = self.def(&r.source).ok_or_else(|| Error::not_found(format!("no live source {:?}", r.source)))?;
        let place = place_from(r.place.as_ref(), places)?;
        let c = self.db()?;
        match self.view(&c, &l, &place, now)? {
            Some(v) => self.view_json(&l, &v, None),
            None => Err(Error::not_found(format!("no {} data has been downloaded for {}", l.def.id, place.name))),
        }
    }
}
