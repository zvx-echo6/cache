//! The tables of notebook.sqlite and the ops on them. Ops answer `serde_json::Value`s whose field order is the one
//! cache_search.h documents.

use crate::def::NotebookDef;
use crate::time::parse_when;
use crate::{Error, Result};
use rusqlite::{params, Connection, OptionalExtension, Row};
use serde_json::{json, Map, Value};
use std::path::Path;

const SCHEMA_VERSION: &str = "2";
const DEFAULT_LIMIT: i64 = 1000;
const MAX_TITLE: usize = 200;
const MAX_TEXT: usize = 100_000;
const MAX_VALUE_TEXT: usize = 2000;
const MAX_ATTACHED: usize = 30;

/// A template id (`journal`, `log`, `notes`, `places`, or one the user made): letters, digits, `_`, `.` and `-`. Templates are
/// data (the app's notebook-templates.json); the store keeps the id and the definition made from it, and knows nothing of what
/// any template means.
fn valid_template(s: &str) -> bool {
    !s.is_empty() && s.len() <= 60 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
}

pub fn open(path: &Path) -> Result<Connection> {
    if let Some(dir) = path.parent() {
        if !dir.as_os_str().is_empty() {
            std::fs::create_dir_all(dir).map_err(|e| Error { code: "io", message: format!("{}: {e}", dir.display()) })?;
        }
    }
    let c = Connection::open(path)?;
    c.busy_timeout(std::time::Duration::from_secs(5))?;
    // secure_delete: a deleted entry's text is overwritten in the file, not only unlinked from it.
    c.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA secure_delete = ON;
         CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
         CREATE TABLE IF NOT EXISTS notebooks(
             id TEXT PRIMARY KEY, template TEXT NOT NULL, private INTEGER NOT NULL DEFAULT 0, map INTEGER NOT NULL DEFAULT 0,
             def_json TEXT NOT NULL, template_ref TEXT, last_used INTEGER, created INTEGER NOT NULL, updated INTEGER NOT NULL,
             rev INTEGER NOT NULL);
         CREATE TABLE IF NOT EXISTS entries(
             id TEXT PRIMARY KEY, notebook_id TEXT NOT NULL,
             occurred_at TEXT NOT NULL, occurred_day TEXT NOT NULL, occurred_ts INTEGER NOT NULL,
             created INTEGER NOT NULL, updated INTEGER NOT NULL, rev INTEGER NOT NULL,
             draft INTEGER NOT NULL DEFAULT 0, private INTEGER NOT NULL DEFAULT 0,
             title TEXT, body TEXT, values_json TEXT, lat REAL, lon REAL, place_label TEXT, place_key TEXT, extra_props TEXT,
             app_props TEXT);
         CREATE INDEX IF NOT EXISTS entries_by_notebook ON entries(notebook_id, occurred_ts);
         CREATE TABLE IF NOT EXISTS attachments(
             id TEXT PRIMARY KEY, entry_id TEXT NOT NULL, kind TEXT NOT NULL CHECK (kind IN ('photo','file')), field_id TEXT,
             ord INTEGER NOT NULL, name TEXT, mime TEXT, width INTEGER, height INTEGER, bytes INTEGER, created INTEGER NOT NULL);
         CREATE INDEX IF NOT EXISTS attachments_by_entry ON attachments(entry_id, ord);
         CREATE VIRTUAL TABLE IF NOT EXISTS entries_fts USING fts5(title, body, values_text, place_label, notebook_name, file_names,
             tokenize = 'porter unicode61 remove_diacritics 2');",
    )?;
    let have: Option<String> = c.query_row("SELECT value FROM meta WHERE key='schema_version'", [], |r| r.get(0)).optional()?;
    match have.as_deref() {
        None => {
            c.execute("INSERT INTO meta(key,value) VALUES('schema_version',?1)", [SCHEMA_VERSION])?;
        }
        Some(SCHEMA_VERSION) => {}
        // 1 -> 2: an entry's app properties (a place's marker colour and its map switch).
        Some("1") => {
            let tx = c.unchecked_transaction()?;
            let has: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM pragma_table_info('entries') WHERE name='app_props')", [], |r| r.get(0))?;
            if !has {
                tx.execute_batch("ALTER TABLE entries ADD COLUMN app_props TEXT;")?;
            }
            tx.execute("UPDATE meta SET value=?1 WHERE key='schema_version'", [SCHEMA_VERSION])?;
            tx.commit()?;
        }
        Some(v) => return Err(Error { code: "unsupported", message: format!("notebook.sqlite has schema {v}; this Cache knows {SCHEMA_VERSION}") }),
    }
    // The Journal exists by default: made once, so a user who deletes it keeps it deleted.
    let made: Option<String> = c.query_row("SELECT value FROM meta WHERE key='journal_made'", [], |r| r.get(0)).optional()?;
    if made.is_none() {
        let now = now_ms();
        let def = json!({"name": "Journal", "due_every": null, "fields": []}).to_string();
        c.execute(
            "INSERT INTO notebooks(id,template,private,map,def_json,template_ref,last_used,created,updated,rev)
             VALUES(?1,'journal',0,1,?2,NULL,NULL,?3,?3,1)",
            params![new_id(), def, now],
        )?;
        c.execute("INSERT INTO meta(key,value) VALUES('journal_made','1')", [])?;
    }
    Ok(c)
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

/// Entry, notebook and attachment ids: UUIDs as Cache makes them, or another id of letters, digits and `-` (an entry restored
/// from sync).
fn valid_id(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
}

fn str_arg<'a>(args: &'a Value, key: &str) -> Result<&'a str> {
    args.get(key).and_then(Value::as_str).ok_or_else(|| Error::bad(format!("{key} is missing")))
}

fn opt_text(args: &Value, key: &str, max: usize) -> Result<Option<String>> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(s)) => {
            if s.chars().count() > max {
                return Err(Error::bad(format!("{key} is longer than {max} characters")));
            }
            Ok((!s.trim().is_empty()).then(|| s.clone()))
        }
        Some(_) => Err(Error::bad(format!("{key} must be text"))),
    }
}

fn opt_bool(args: &Value, key: &str) -> Result<Option<bool>> {
    match args.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Bool(b)) => Ok(Some(*b)),
        Some(_) => Err(Error::bad(format!("{key} must be true or false"))),
    }
}

fn check_keys(args: &Value, allowed: &[&str]) -> Result<()> {
    for k in args.as_object().into_iter().flat_map(|o| o.keys()) {
        if !allowed.contains(&k.as_str()) {
            return Err(Error::bad(format!("{k}: not allowed")));
        }
    }
    Ok(())
}

fn limit_arg(args: &Value, default: i64) -> Result<i64> {
    match args.get("limit") {
        None | Some(Value::Null) => Ok(default),
        Some(v) => v.as_i64().filter(|n| *n > 0).ok_or_else(|| Error::bad("limit must be a positive whole number")),
    }
}

fn ids_of(c: &Connection, sql: &str, p: &[&dyn rusqlite::ToSql]) -> Result<Vec<String>> {
    let mut st = c.prepare(sql)?;
    let r = st.query_map(p, |r| r.get(0))?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(r)
}

/// A place: `{"lat","lon","label"?,"key"?}` (key = a saved place's key).
#[derive(Debug, Clone, PartialEq)]
struct Place {
    lat: f64,
    lon: f64,
    label: Option<String>,
    key: Option<String>,
}

impl Place {
    fn parse(v: &Value, what: &str) -> Result<Option<Place>> {
        if v.is_null() {
            return Ok(None);
        }
        let o = v.as_object().ok_or_else(|| Error::bad(format!("{what} must be {{\"lat\",\"lon\",\"label\"?,\"key\"?}}")))?;
        for k in o.keys() {
            if !["lat", "lon", "label", "key"].contains(&k.as_str()) {
                return Err(Error::bad(format!("{what}.{k}: not allowed")));
            }
        }
        let lat = o.get("lat").and_then(Value::as_f64).ok_or_else(|| Error::bad(format!("{what}.lat is missing")))?;
        let lon = o.get("lon").and_then(Value::as_f64).ok_or_else(|| Error::bad(format!("{what}.lon is missing")))?;
        if !(lat.is_finite() && lon.is_finite() && (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon)) {
            return Err(Error::bad(format!("{what}: lat/lon out of range: {lat}, {lon}")));
        }
        let text = |k: &str| -> Result<Option<String>> {
            match o.get(k) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(s)) if s.chars().count() <= 200 => Ok((!s.trim().is_empty()).then(|| s.trim().to_string())),
                Some(_) => Err(Error::bad(format!("{what}.{k} must be text of at most 200 characters"))),
            }
        };
        Ok(Some(Place { lat, lon, label: text("label")?, key: text("key")? }))
    }

    fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("lat".into(), json!(self.lat));
        m.insert("lon".into(), json!(self.lon));
        if let Some(l) = &self.label {
            m.insert("label".into(), json!(l));
        }
        if let Some(k) = &self.key {
            m.insert("key".into(), json!(k));
        }
        Value::Object(m)
    }
}

/// A photo (`media_dir/photos/<id>.jpg`, thumbnail `thumbs/<id>.jpg`) or an attached file (`media_dir/files/<id>`, its own
/// name kept here) that the app wrote before saving the entry that names it.
#[derive(Debug, Clone)]
struct Attached {
    id: String,
    name: Option<String>,
    mime: Option<String>,
    width: Option<i64>,
    height: Option<i64>,
    bytes: Option<i64>,
}

impl Attached {
    fn parse(v: &Value, file: bool) -> Result<Attached> {
        let id = v
            .get("id")
            .and_then(Value::as_str)
            .filter(|s| valid_id(s))
            .ok_or_else(|| Error::bad("a photo or file needs an id of letters, digits and -"))?;
        let n = |k: &str| v.get(k).and_then(Value::as_i64);
        let t = |k: &str| v.get(k).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty() && s.chars().count() <= 200).map(str::to_string);
        let name = t("name");
        if file && name.is_none() {
            return Err(Error::bad("an attached file needs its name"));
        }
        Ok(Attached { id: id.to_string(), name, mime: t("mime"), width: n("width"), height: n("height"), bytes: n("bytes") })
    }

    fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("id".into(), json!(self.id));
        for (k, v) in [("name", &self.name), ("mime", &self.mime)] {
            if let Some(v) = v {
                m.insert(k.into(), json!(v));
            }
        }
        for (k, v) in [("width", self.width), ("height", self.height), ("bytes", self.bytes)] {
            if let Some(v) = v {
                m.insert(k.into(), json!(v));
            }
        }
        Value::Object(m)
    }
}

/// Deletes the files of attachments: `(id, kind)`.
fn delete_files(media: &Path, gone: &[(String, String)]) {
    for (id, kind) in gone {
        if !valid_id(id) {
            continue;
        }
        if kind == "file" {
            let _ = std::fs::remove_file(media.join("files").join(id));
        } else {
            let _ = std::fs::remove_file(media.join("photos").join(format!("{id}.jpg")));
            let _ = std::fs::remove_file(media.join("thumbs").join(format!("{id}.jpg")));
        }
    }
}

fn attached_of(c: &Connection, sql_where: &str, arg: &str) -> Result<Vec<(String, String)>> {
    let mut st = c.prepare(&format!("SELECT id, kind FROM attachments WHERE {sql_where}"))?;
    let r = st.query_map([arg], |r| Ok((r.get(0)?, r.get(1)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(r)
}

/// An entry's app properties: `{"color"?: "<name>", "on_map"?: bool}`. A place's marker colour (a name the app knows, letters
/// only) and whether it is shown on the map (absent = shown). Not exported to other apps' properties.
fn parse_props(v: Option<&Value>) -> Result<Option<String>> {
    let Some(v) = v.filter(|v| !v.is_null()) else { return Ok(None) };
    let o = v.as_object().ok_or_else(|| Error::bad("props must be an object"))?;
    for (k, x) in o {
        let ok = match k.as_str() {
            "color" => x.as_str().is_some_and(|s| !s.is_empty() && s.len() <= 20 && s.bytes().all(|b| b.is_ascii_lowercase())),
            "on_map" => x.is_boolean(),
            _ => return Err(Error::bad(format!("props.{k}: not allowed"))),
        };
        if !ok {
            return Err(Error::bad(format!("props.{k}: {x} is not allowed")));
        }
    }
    Ok((!o.is_empty()).then(|| v.to_string()))
}

// ---- notebooks ----

struct NotebookRow {
    id: String,
    template: String,
    private: bool,
    map: bool,
    def: NotebookDef,
    template_ref: Option<String>,
    last_used: Option<i64>,
    created: i64,
    updated: i64,
    rev: i64,
}

const NB_COLS: &str = "id, template, private, map, def_json, template_ref, last_used, created, updated, rev";

fn nb_row(r: &Row) -> rusqlite::Result<(NotebookRow, String)> {
    Ok((
        NotebookRow {
            id: r.get(0)?,
            template: r.get(1)?,
            private: r.get::<_, i64>(2)? != 0,
            map: r.get::<_, i64>(3)? != 0,
            def: NotebookDef { meta: vec![], name: String::new(), due_every: None, shape: Map::new(), fields: vec![] },
            template_ref: r.get(5)?,
            last_used: r.get(6)?,
            created: r.get(7)?,
            updated: r.get(8)?,
            rev: r.get(9)?,
        },
        r.get(4)?,
    ))
}

fn finish((mut row, def): (NotebookRow, String)) -> Result<NotebookRow> {
    row.def = NotebookDef::from_stored(&def)?;
    Ok(row)
}

fn load_notebook(c: &Connection, id: &str) -> Result<Option<NotebookRow>> {
    let r = c.query_row(&format!("SELECT {NB_COLS} FROM notebooks WHERE id=?1"), [id], nb_row).optional()?;
    r.map(finish).transpose()
}

fn all_notebooks(c: &Connection) -> Result<Vec<NotebookRow>> {
    let mut st = c.prepare(&format!("SELECT {NB_COLS} FROM notebooks ORDER BY last_used DESC NULLS LAST, created DESC, rowid DESC"))?;
    let rows = st.query_map([], nb_row)?.collect::<rusqlite::Result<Vec<_>>>()?;
    rows.into_iter().map(finish).collect()
}

fn notebook_json(c: &Connection, n: &NotebookRow) -> Result<Value> {
    let count: i64 = c.query_row("SELECT COUNT(*) FROM entries WHERE notebook_id=?1 AND draft=0", [&n.id], |r| r.get(0))?;
    let files: i64 = c.query_row(
        "SELECT COUNT(*) FROM attachments a JOIN entries e ON e.id = a.entry_id WHERE e.notebook_id=?1 AND e.draft=0 AND a.kind='file'",
        [&n.id],
        |r| r.get(0),
    )?;
    let places: i64 = c.query_row("SELECT COUNT(*) FROM entries WHERE notebook_id=?1 AND draft=0 AND lat IS NOT NULL", [&n.id], |r| r.get(0))?;
    let last: Option<String> = c
        .query_row(
            "SELECT id FROM entries WHERE notebook_id=?1 AND draft=0 ORDER BY occurred_ts DESC, created DESC LIMIT 1",
            [&n.id],
            |r| r.get(0),
        )
        .optional()?;
    let last = match last {
        Some(id) => entry_json(c, &id)?.unwrap_or(Value::Null),
        None => Value::Null,
    };
    let mut m = Map::new();
    m.insert("id".into(), json!(n.id));
    m.insert("template".into(), json!(n.template));
    m.insert("def".into(), n.def.to_json());
    m.insert("private".into(), json!(n.private));
    m.insert("map".into(), json!(n.map));
    m.insert("template_ref".into(), json!(n.template_ref));
    m.insert("created".into(), json!(n.created));
    m.insert("updated".into(), json!(n.updated));
    m.insert("last_used".into(), json!(n.last_used));
    m.insert("rev".into(), json!(n.rev));
    m.insert("entries".into(), json!(count));
    m.insert("files".into(), json!(files));
    m.insert("places".into(), json!(places));
    m.insert("last_entry".into(), last);
    if saved_places_id(c)?.as_deref() == Some(n.id.as_str()) {
        m.insert("saved_places".into(), json!(true));
    }
    Ok(Value::Object(m))
}

/// The id of the notebook that holds the saved places, once it is made.
pub fn saved_places_id(c: &Connection) -> Result<Option<String>> {
    let id: Option<String> = c.query_row("SELECT value FROM meta WHERE key='saved_places_notebook'", [], |r| r.get(0)).optional()?;
    Ok(match id {
        Some(id) if load_notebook(c, &id)?.is_some() => Some(id),
        _ => None,
    })
}

/// `saved_places`: `{}`. The Places notebook that holds the saved places (each entry is one saved place), made the first time
/// (named "Places", or "Saved places" when another notebook has that name). Returns the notebook.
pub fn saved_places(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &[])?;
    let id = match saved_places_id(c)? {
        Some(id) => id,
        None => {
            let taken: Vec<String> = all_notebooks(c)?.iter().map(|n| n.def.name.to_lowercase()).collect();
            let name = if taken.iter().any(|n| n == "places") { "Saved places" } else { "Places" };
            let id = new_id();
            let now = now_ms();
            let def = json!({"name": name, "due_every": null, "shape": {"sort": "distance"}, "fields": []}).to_string();
            let tx = c.transaction()?;
            tx.execute(
                "INSERT INTO notebooks(id,template,private,map,def_json,template_ref,last_used,created,updated,rev)
                 VALUES(?1,'places',0,1,?2,NULL,NULL,?3,?3,1)",
                params![id, def, now],
            )?;
            tx.execute("INSERT OR REPLACE INTO meta(key,value) VALUES('saved_places_notebook',?1)", [&id])?;
            tx.commit()?;
            id
        }
    };
    let n = load_notebook(c, &id)?.expect("made above");
    notebook_json(c, &n)
}

/// One entry with a place of a Places notebook, for the map layers and the saved places (see `places_books`).
#[derive(Debug, Clone, PartialEq)]
pub struct PlacePoint {
    pub entry_id: String,
    pub title: Option<String>,
    pub body: Option<String>,
    pub lat: f64,
    pub lon: f64,
    pub label: Option<String>,
    pub key: Option<String>,
}

/// A notebook made from the Places template, with its entries that have a place (not drafts), oldest first.
#[derive(Debug, Clone, PartialEq)]
pub struct PlacesBook {
    pub id: String,
    pub name: String,
    pub private: bool,
    pub map: bool,
    /// The notebook of the saved places.
    pub saved: bool,
    pub points: Vec<PlacePoint>,
}

pub fn places_books(c: &Connection) -> Result<Vec<PlacesBook>> {
    let saved = saved_places_id(c)?;
    let mut out = Vec::new();
    let mut books: Vec<NotebookRow> = all_notebooks(c)?.into_iter().filter(|n| n.template == "places").collect();
    books.sort_by_key(|n| n.created);
    for n in books {
        let mut st = c.prepare(
            "SELECT id, title, body, lat, lon, place_label, place_key FROM entries
             WHERE notebook_id=?1 AND draft=0 AND lat IS NOT NULL AND lon IS NOT NULL ORDER BY created, rowid",
        )?;
        let points = st
            .query_map([&n.id], |r| {
                Ok(PlacePoint { entry_id: r.get(0)?, title: r.get(1)?, body: r.get(2)?, lat: r.get(3)?, lon: r.get(4)?, label: r.get(5)?, key: r.get(6)? })
            })?
            .collect::<rusqlite::Result<Vec<_>>>()?;
        out.push(PlacesBook { saved: saved.as_deref() == Some(n.id.as_str()), id: n.id, name: n.def.name, private: n.private, map: n.map, points });
    }
    Ok(out)
}

/// `notebooks`: every notebook, most recently used first (then newest made).
pub fn notebooks(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &[])?;
    let all = all_notebooks(c)?;
    let list = all.iter().map(|n| notebook_json(c, n)).collect::<Result<Vec<_>>>()?;
    Ok(json!({"notebooks": list}))
}

pub fn notebook_get(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &["id"])?;
    let id = str_arg(args, "id")?;
    let n = load_notebook(c, id)?.ok_or_else(|| Error::not_found(format!("no notebook with id {id:?}")))?;
    notebook_json(c, &n)
}

fn field_has_values(c: &Connection, nb: &str, fid: &str) -> Result<bool> {
    let n: i64 = c.query_row(
        "SELECT COUNT(*) FROM entries WHERE notebook_id=?1 AND values_json IS NOT NULL AND json_extract(values_json, '$.' || ?2) IS NOT NULL",
        params![nb, fid],
        |r| r.get(0),
    )?;
    Ok(n > 0)
}

/// `notebook_save`: `{"id"?, "template"?, "def", "private"?, "map"?, "template_ref"?}`. Makes a notebook (no id, or an id not yet
/// used; `template` is then required) or replaces one's definition and switches (see `NotebookDef::merge`); a switch left out
/// keeps its value. Names are unique, ignoring case.
pub fn notebook_save(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &["id", "template", "def", "private", "map", "template_ref"])?;
    let given = NotebookDef::parse(args.get("def").ok_or_else(|| Error::bad("def is missing"))?)?;
    let template = match args.get("template") {
        None | Some(Value::Null) => None,
        Some(Value::String(t)) if valid_template(t) => Some(t.clone()),
        Some(t) => return Err(Error::bad(format!("template {t} must be letters, digits, _ . and -"))),
    };
    let private = opt_bool(args, "private")?;
    let map = opt_bool(args, "map")?;
    let template_ref = opt_text(args, "template_ref", 200)?;
    let id = match args.get("id") {
        None | Some(Value::Null) => new_id(),
        Some(Value::String(s)) if valid_id(s) => s.clone(),
        Some(_) => return Err(Error::bad("id must be letters, digits and -")),
    };
    let tx = c.transaction()?;
    let old = load_notebook(&tx, &id)?;
    let lower = given.name.to_lowercase();
    for other in all_notebooks(&tx)? {
        if other.id != id && other.def.name.to_lowercase() == lower {
            return Err(Error::bad(format!("a notebook named {:?} already exists", other.def.name)));
        }
    }
    let has_entries: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM entries WHERE notebook_id=?1)", [&id], |r| r.get(0))?;
    let mut probe_err = None;
    let def = given.merge(old.as_ref().map(|o| &o.def), has_entries, |fid| match field_has_values(&tx, &id, fid) {
        Ok(b) => b,
        Err(e) => {
            probe_err = Some(e);
            true
        }
    })?;
    if let Some(e) = probe_err {
        return Err(e);
    }
    let now = now_ms();
    let def_text = def.to_json().to_string();
    match &old {
        None => {
            let template = template.ok_or_else(|| Error::bad("a new notebook needs its template"))?;
            // On the map unless switched off (the app shows the switch once entries have places).
            let map = map.unwrap_or(true);
            tx.execute(
                "INSERT INTO notebooks(id,template,private,map,def_json,template_ref,last_used,created,updated,rev)
                 VALUES(?1,?2,?3,?4,?5,?6,NULL,?7,?7,1)",
                params![id, template, private.unwrap_or(false) as i64, map as i64, def_text, template_ref, now],
            )?;
        }
        Some(o) => {
            // A notebook keeps the template it came from unless the app names another.
            tx.execute(
                "UPDATE notebooks SET template=?2, private=?3, map=?4, def_json=?5, template_ref=?6, updated=?7, rev=rev+1 WHERE id=?1",
                params![
                    id,
                    template.unwrap_or_else(|| o.template.clone()),
                    private.unwrap_or(o.private) as i64,
                    map.unwrap_or(o.map) as i64,
                    def_text,
                    template_ref.or_else(|| o.template_ref.clone()),
                    now
                ],
            )?;
            for e in ids_of(&tx, "SELECT id FROM entries WHERE notebook_id=?1", &[&id])? {
                index_entry(&tx, &e)?;
            }
        }
    }
    let n = load_notebook(&tx, &id)?.expect("saved above");
    let out = notebook_json(&tx, &n)?;
    tx.commit()?;
    Ok(out)
}

/// `notebook_delete`: `{"id"}`. The notebook, its entries and their photos and files. `{"deleted":"<id>","entries":n}`.
pub fn notebook_delete(c: &mut Connection, media: &Path, args: &Value) -> Result<Value> {
    check_keys(args, &["id"])?;
    let id = str_arg(args, "id")?;
    let tx = c.transaction()?;
    if load_notebook(&tx, id)?.is_none() {
        return Err(Error::not_found(format!("no notebook with id {id:?}")));
    }
    if saved_places_id(&tx)?.as_deref() == Some(id) {
        return Err(Error::bad("the Places notebook holds the saved places and is not deleted; delete its places instead"));
    }
    let gone = attached_of(&tx, "entry_id IN (SELECT id FROM entries WHERE notebook_id=?1)", id)?;
    tx.execute("DELETE FROM entries_fts WHERE rowid IN (SELECT rowid FROM entries WHERE notebook_id=?1)", [id])?;
    tx.execute("DELETE FROM attachments WHERE entry_id IN (SELECT id FROM entries WHERE notebook_id=?1)", [id])?;
    let n = tx.execute("DELETE FROM entries WHERE notebook_id=?1", [id])?;
    tx.execute("DELETE FROM notebooks WHERE id=?1", [id])?;
    tx.commit()?;
    delete_files(media, &gone);
    Ok(json!({"deleted": id, "entries": n}))
}

// ---- entries ----

const ENTRY_COLS: &str = "e.id, e.notebook_id, e.occurred_at, e.draft, e.private OR n.private, e.title, e.body, e.values_json, e.lat, e.lon,
    e.place_label, e.place_key, e.created, e.updated, e.rev, e.app_props";

fn attached_list(c: &Connection, entry_id: &str, kind: &str) -> Result<Vec<Attached>> {
    let mut st = c.prepare(
        "SELECT id, name, mime, width, height, bytes FROM attachments WHERE entry_id=?1 AND kind=?2 AND field_id IS NULL ORDER BY ord",
    )?;
    let r = st
        .query_map(params![entry_id, kind], |r| {
            Ok(Attached { id: r.get(0)?, name: r.get(1)?, mime: r.get(2)?, width: r.get(3)?, height: r.get(4)?, bytes: r.get(5)? })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(r)
}

fn entry_json(c: &Connection, id: &str) -> Result<Option<Value>> {
    let row = c
        .query_row(&format!("SELECT {ENTRY_COLS} FROM entries e JOIN notebooks n ON n.id = e.notebook_id WHERE e.id=?1"), [id], |r| {
            let mut m = Map::new();
            m.insert("id".into(), json!(r.get::<_, String>(0)?));
            m.insert("notebook_id".into(), json!(r.get::<_, String>(1)?));
            m.insert("occurred_at".into(), json!(r.get::<_, String>(2)?));
            if let Some(t) = r.get::<_, Option<String>>(5)? {
                m.insert("title".into(), json!(t));
            }
            if let Some(b) = r.get::<_, Option<String>>(6)? {
                m.insert("body".into(), json!(b));
            }
            let values: Option<String> = r.get(7)?;
            m.insert("values".into(), values.and_then(|v| serde_json::from_str::<Value>(&v).ok()).unwrap_or_else(|| json!({})));
            if let (Some(lat), Some(lon)) = (r.get::<_, Option<f64>>(8)?, r.get::<_, Option<f64>>(9)?) {
                m.insert("place".into(), Place { lat, lon, label: r.get(10)?, key: r.get(11)? }.to_json());
            }
            let props: Option<String> = r.get(15)?;
            let tail = json!({
                "draft": r.get::<_, i64>(3)? != 0,
                "private": r.get::<_, i64>(4)? != 0,
                "created": r.get::<_, i64>(12)?,
                "updated": r.get::<_, i64>(13)?,
                "rev": r.get::<_, i64>(14)?,
            });
            Ok((m, tail, props))
        })
        .optional()?;
    let Some((mut m, tail, props)) = row else { return Ok(None) };
    m.insert("photos".into(), Value::Array(attached_list(c, id, "photo")?.iter().map(Attached::to_json).collect()));
    m.insert("files".into(), Value::Array(attached_list(c, id, "file")?.iter().map(Attached::to_json).collect()));
    if let Some(p) = props.and_then(|p| serde_json::from_str::<Value>(&p).ok()) {
        m.insert("props".into(), p);
    }
    for (k, v) in tail.as_object().expect("object") {
        m.insert(k.clone(), v.clone());
    }
    Ok(Some(Value::Object(m)))
}

fn entry_list(c: &Connection, sql: &str, p: &[&dyn rusqlite::ToSql]) -> Result<Vec<Value>> {
    ids_of(c, sql, p)?.iter().filter_map(|id| entry_json(c, id).transpose()).collect()
}

/// `entries`: `{"notebook_id","limit"?}`. Newest first; drafts included (marked `"draft":true`).
pub fn entries(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &["notebook_id", "limit"])?;
    let limit = limit_arg(args, DEFAULT_LIMIT)?;
    let nb = str_arg(args, "notebook_id")?;
    if load_notebook(c, nb)?.is_none() {
        return Err(Error::not_found(format!("no notebook with id {nb:?}")));
    }
    let list = entry_list(c, "SELECT id FROM entries WHERE notebook_id=?1 ORDER BY occurred_ts DESC, created DESC LIMIT ?2", &[&nb, &limit])?;
    Ok(json!({"entries": list}))
}

pub fn entry_get(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &["id"])?;
    let id = str_arg(args, "id")?;
    entry_json(c, id)?.ok_or_else(|| Error::not_found(format!("no entry with id {id:?}")))
}

/// A number as the user typed it: whole numbers without ".0".
fn number_text(v: &Value) -> String {
    match v.as_f64() {
        Some(f) if f.fract() == 0.0 && f.abs() < 1e15 => format!("{}", f as i64),
        _ => v.to_string(),
    }
}

/// The searchable text of an entry's values, with the field labels: "Run time 20 min; Under load yes; Fuel level Full".
fn values_text(def: &NotebookDef, values: &Map<String, Value>) -> String {
    let mut parts = Vec::new();
    for f in &def.fields {
        let Some(v) = values.get(&f.fid) else { continue };
        let text = match f.kind.as_str() {
            "number" => match &f.unit {
                Some(u) => format!("{} {u}", number_text(v)),
                None => number_text(v),
            },
            "yes_no" => (if v.as_bool() == Some(true) { "yes" } else { "no" }).to_string(),
            "text" | "choice" => v.as_str().unwrap_or("").to_string(),
            "place" => v.get("label").and_then(Value::as_str).unwrap_or("").to_string(),
            _ => continue,
        };
        if !text.is_empty() {
            parts.push(format!("{} {text}", f.label));
        }
    }
    parts.join("; ")
}

/// An entry's values against its notebook's fields (by fid): number, true/false, text, a place, or a list of photo ids.
fn check_values(def: &NotebookDef, v: &Value) -> Result<Map<String, Value>> {
    let Some(o) = v.as_object() else {
        return if v.is_null() { Ok(Map::new()) } else { Err(Error::bad("values must be an object of field id to value")) };
    };
    for k in o.keys() {
        if def.field(k).is_none() {
            return Err(Error::bad(format!("the notebook has no field {k:?}")));
        }
    }
    let mut out = Map::new();
    for f in &def.fields {
        let Some(x) = o.get(&f.fid) else { continue };
        if x.is_null() || x.as_str().is_some_and(|s| s.trim().is_empty()) {
            continue;
        }
        let ok = match f.kind.as_str() {
            "number" => x.as_f64().is_some_and(f64::is_finite),
            "yes_no" => x.is_boolean(),
            "text" | "choice" => x.as_str().is_some_and(|s| s.chars().count() <= MAX_VALUE_TEXT),
            "place" => Place::parse(x, &f.label).is_ok(),
            "photo" => x.as_array().is_some_and(|a| a.len() <= MAX_ATTACHED && a.iter().all(|p| p.as_str().is_some_and(valid_id))),
            _ => false,
        };
        if !ok {
            return Err(Error::bad(format!("{}: {x} is not a {} value", f.label, f.kind)));
        }
        let x = if f.kind == "place" { Place::parse(x, &f.label)?.map(|p| p.to_json()).unwrap_or(Value::Null) } else { x.clone() };
        out.insert(f.fid.clone(), x);
    }
    Ok(out)
}

fn index_entry(c: &Connection, id: &str) -> Result<()> {
    type IndexRow = (i64, String, Option<String>, Option<String>, Option<String>, Option<String>, bool);
    let row: Option<IndexRow> = c
        .query_row("SELECT rowid, notebook_id, title, body, values_json, place_label, draft FROM entries WHERE id=?1", [id], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get::<_, i64>(6)? != 0))
        })
        .optional()?;
    let Some((rowid, nb, title, body, values, place, draft)) = row else { return Ok(()) };
    c.execute("DELETE FROM entries_fts WHERE rowid=?1", [rowid])?;
    if draft {
        return Ok(());
    }
    let (name, vtext) = match load_notebook(c, &nb)? {
        Some(n) => {
            let vals = values.and_then(|v| serde_json::from_str::<Value>(&v).ok()).and_then(|v| v.as_object().cloned()).unwrap_or_default();
            (Some(n.def.name.clone()), values_text(&n.def, &vals))
        }
        None => (None, String::new()),
    };
    let files = ids_of(c, "SELECT COALESCE(name,'') FROM attachments WHERE entry_id=?1 AND kind='file' ORDER BY ord", &[&id])?;
    c.execute(
        "INSERT INTO entries_fts(rowid, title, body, values_text, place_label, notebook_name, file_names) VALUES(?1,?2,?3,?4,?5,?6,?7)",
        params![rowid, title, body, vtext, place, name, files.join(" ")],
    )?;
    Ok(())
}

/// `entry_save`: the whole entry (see cache_search.h). Without an id, or with one not yet used, a new entry; else it replaces
/// that entry (rev + 1). An entry of a private notebook is private. Saving an entry that is not a draft makes its notebook the
/// most recently used. Photos and files the entry no longer has are deleted from `media_dir`.
pub fn entry_save(c: &mut Connection, media: &Path, args: &Value) -> Result<Value> {
    check_keys(args, &["id", "notebook_id", "occurred_at", "title", "body", "values", "place", "photos", "files", "draft", "private", "props"])?;
    let id = match args.get("id") {
        None | Some(Value::Null) => new_id(),
        Some(Value::String(s)) if valid_id(s) => s.clone(),
        Some(_) => return Err(Error::bad("id must be letters, digits and -")),
    };
    let nb_id = str_arg(args, "notebook_id")?;
    let occurred_at = str_arg(args, "occurred_at")?;
    let (day, ts) = parse_when(occurred_at)?;
    let title = opt_text(args, "title", MAX_TITLE)?;
    let body = opt_text(args, "body", MAX_TEXT)?;
    let place = Place::parse(args.get("place").unwrap_or(&Value::Null), "place")?;
    let draft = opt_bool(args, "draft")?.unwrap_or(false);
    let private = opt_bool(args, "private")?.unwrap_or(false);
    let list = |key: &str, file: bool| -> Result<Vec<Attached>> {
        match args.get(key) {
            None | Some(Value::Null) => Ok(vec![]),
            Some(Value::Array(a)) if a.len() <= MAX_ATTACHED => a.iter().map(|v| Attached::parse(v, file)).collect(),
            Some(_) => Err(Error::bad(format!("{key} must be a list of at most {MAX_ATTACHED}"))),
        }
    };
    let photos = list("photos", false)?;
    let files = list("files", true)?;
    let props = parse_props(args.get("props"))?;

    let tx = c.transaction()?;
    let nb = load_notebook(&tx, nb_id)?.ok_or_else(|| Error::not_found(format!("no notebook with id {nb_id:?}")))?;
    let values = check_values(&nb.def, args.get("values").unwrap_or(&Value::Null))?;
    let mut field_photos: Vec<(String, String)> = Vec::new();
    for f in nb.def.fields.iter().filter(|f| f.kind == "photo") {
        for p in values.get(&f.fid).and_then(Value::as_array).into_iter().flatten() {
            field_photos.push((f.fid.clone(), p.as_str().unwrap_or_default().to_string()));
        }
    }
    let values_text = (!values.is_empty()).then(|| Value::Object(values).to_string());
    let exists: bool = tx.query_row("SELECT EXISTS(SELECT 1 FROM entries WHERE id=?1)", [&id], |r| r.get(0))?;
    let old_attached = attached_of(&tx, "entry_id=?1", &id)?;
    let now = now_ms();
    let (lat, lon, label, key) = match &place {
        Some(p) => (Some(p.lat), Some(p.lon), p.label.clone(), p.key.clone()),
        None => (None, None, None, None),
    };
    if exists {
        tx.execute(
            "UPDATE entries SET notebook_id=?2, occurred_at=?3, occurred_day=?4, occurred_ts=?5, updated=?6, rev=rev+1, draft=?7,
             private=?8, title=?9, body=?10, values_json=?11, lat=?12, lon=?13, place_label=?14, place_key=?15, app_props=?16 WHERE id=?1",
            params![id, nb_id, occurred_at, day, ts, now, draft as i64, private as i64, title, body, values_text, lat, lon, label, key, props],
        )?;
    } else {
        tx.execute(
            "INSERT INTO entries(id,notebook_id,occurred_at,occurred_day,occurred_ts,created,updated,rev,draft,private,title,body,
             values_json,lat,lon,place_label,place_key,app_props) VALUES(?1,?2,?3,?4,?5,?6,?6,1,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16)",
            params![id, nb_id, occurred_at, day, ts, now, draft as i64, private as i64, title, body, values_text, lat, lon, label, key, props],
        )?;
    }
    tx.execute("DELETE FROM attachments WHERE entry_id=?1", [&id])?;
    let mut kept: Vec<String> = Vec::new();
    {
        let mut add = |a: &Attached, kind: &str, field: Option<&str>, ord: usize| -> Result<()> {
            tx.execute(
                "INSERT OR REPLACE INTO attachments(id,entry_id,kind,field_id,ord,name,mime,width,height,bytes,created)
                 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
                params![a.id, id, kind, field, ord as i64, a.name, a.mime, a.width, a.height, a.bytes, now],
            )?;
            kept.push(a.id.clone());
            Ok(())
        };
        for (ord, p) in photos.iter().enumerate() {
            add(p, "photo", None, ord)?;
        }
        for (ord, f) in files.iter().enumerate() {
            add(f, "file", None, ord)?;
        }
        for (ord, (fid, pid)) in field_photos.iter().enumerate() {
            let a = Attached { id: pid.clone(), name: None, mime: None, width: None, height: None, bytes: None };
            add(&a, "photo", Some(fid), ord)?;
        }
    }
    index_entry(&tx, &id)?;
    if !draft {
        tx.execute("UPDATE notebooks SET last_used=?2 WHERE id=?1", params![nb_id, now])?;
    }
    let out = entry_json(&tx, &id)?.expect("saved above");
    tx.commit()?;
    let gone: Vec<(String, String)> = old_attached.into_iter().filter(|(a, _)| !kept.contains(a)).collect();
    delete_files(media, &gone);
    Ok(out)
}

/// `entry_delete`: `{"id"}`. The entry and its photos and files. `{"deleted":"<id>"}`.
pub fn entry_delete(c: &mut Connection, media: &Path, args: &Value) -> Result<Value> {
    check_keys(args, &["id"])?;
    let id = str_arg(args, "id")?;
    let tx = c.transaction()?;
    let rowid: Option<i64> = tx.query_row("SELECT rowid FROM entries WHERE id=?1", [id], |r| r.get(0)).optional()?;
    let Some(rowid) = rowid else { return Err(Error::not_found(format!("no entry with id {id:?}"))) };
    let gone = attached_of(&tx, "entry_id=?1", id)?;
    tx.execute("DELETE FROM entries_fts WHERE rowid=?1", [rowid])?;
    tx.execute("DELETE FROM attachments WHERE entry_id=?1", [id])?;
    tx.execute("DELETE FROM entries WHERE id=?1", [id])?;
    tx.commit()?;
    delete_files(media, &gone);
    Ok(json!({"deleted": id}))
}

/// The FTS5 query for what the user typed: each word quoted (so nothing they type is FTS syntax), all words required, the
/// last one also as a prefix (search as you type).
fn fts_query(q: &str) -> Option<String> {
    let words: Vec<String> = q.split(|ch: char| !ch.is_alphanumeric()).filter(|w| !w.is_empty()).map(|w| format!("\"{w}\"")).collect();
    let (last, rest) = words.split_last()?;
    let mut parts: Vec<String> = rest.to_vec();
    parts.push(format!("{last}*"));
    Some(parts.join(" "))
}

/// `search`: `{"query","notebook_id"?,"limit"?}` over titles, text, values (with their labels), places, file names and notebook
/// names. Best match first, then newest. Each hit: `{"entry","notebook","snippet"}`; the snippet marks matched words with
/// U+0002 ... U+0003.
pub fn search(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &["query", "notebook_id", "limit"])?;
    let q = str_arg(args, "query")?;
    let limit = limit_arg(args, 50)?;
    let only = args.get("notebook_id").and_then(Value::as_str);
    let Some(m) = fts_query(q) else { return Ok(json!({"hits": []})) };
    type Hit = (String, String, String);
    let rows: Vec<Hit> = {
        let mut st = c.prepare(
            "SELECT e.id, n.def_json, snippet(entries_fts, -1, char(2), char(3), '…', 12)
             FROM entries_fts JOIN entries e ON e.rowid = entries_fts.rowid JOIN notebooks n ON n.id = e.notebook_id
             WHERE entries_fts MATCH ?1 AND (?2 IS NULL OR e.notebook_id = ?2) ORDER BY bm25(entries_fts), e.occurred_ts DESC LIMIT ?3",
        )?;
        let r = st.query_map(params![m, only, limit], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?.collect::<rusqlite::Result<Vec<_>>>()?;
        r
    };
    let mut hits = Vec::new();
    for (id, def, snippet) in rows {
        let Some(entry) = entry_json(c, &id)? else { continue };
        let name = NotebookDef::from_stored(&def).map(|d| d.name).unwrap_or_default();
        hits.push(json!({"entry": entry, "notebook": name, "snippet": snippet}));
    }
    Ok(json!({"hits": hits}))
}

/// `pins`: `{"notebook_id"?}`: the entries with a place (not drafts, not switched off the map by `props.on_map`) of the
/// notebooks shown on the map (or of that one notebook), newest first: `{"entries":[...]}`.
pub fn pins(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &["notebook_id"])?;
    let list = match args.get("notebook_id").and_then(Value::as_str) {
        Some(nb) => entry_list(
            c,
            "SELECT id FROM entries WHERE notebook_id=?1 AND draft=0 AND lat IS NOT NULL AND COALESCE(json_extract(app_props, '$.on_map'), 1) != 0
             ORDER BY occurred_ts DESC, created DESC",
            &[&nb],
        )?,
        None => entry_list(
            c,
            "SELECT e.id FROM entries e JOIN notebooks n ON n.id = e.notebook_id WHERE n.map=1 AND e.draft=0 AND e.lat IS NOT NULL
             AND COALESCE(json_extract(e.app_props, '$.on_map'), 1) != 0 ORDER BY e.occurred_ts DESC, e.created DESC",
            &[],
        )?,
    };
    Ok(json!({"entries": list}))
}
