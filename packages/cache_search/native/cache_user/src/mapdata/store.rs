//! The map layers and repeater lists of one user.sqlite (beside the saved places), and what the tools see of them.
//!
//! A layer has the id `y<n>` and a repeater list `l<n>`; their items are numbered from 1 in file order (a layer's pins,
//! lines and areas together; a list's merged repeaters, then the CHIRP rows no pin paired with). Addresses:
//! `layer:y<n>/<item>` and `repeater:l<n>/<item>`. "Used" (the order layers are offered in, most recent first) is the last
//! import, edit or visibility change. Visibility is map-only: hidden layers and lists still reach the assistant, and so do
//! private ones (private means left out of sync and sharing).

use super::repeater::{frequency_text, Repeater};
use super::{bad, collapse, file_kind, geojson, gpx, kml, chirp, slug, unique, utf8, Feature, FileKind, Geom, MAX_FILE_BYTES};
use crate::{Error, Result};
use cache_tool::user::{UserCategory, UserPoint, UserPoints};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

/// The most layers `nearby` offers.
pub const MAX_LAYER_CATEGORIES: usize = 10;
/// A layer category id is at most this long (`layer_` included).
pub const MAX_CATEGORY_ID: usize = 32;
const LAYER_PREFIX: &str = "layer_";
/// How long a layer point's notes may be in a `nearby` row.
pub const MAX_NOTES: usize = 200;

pub const REPEATER_NOTE: &str = "From the user's imported repeater list; check the settings before transmitting.";
pub const REPEATER_DETAILS: &str = "full page on RepeaterBook (opens in the browser; needs a connection)";

pub struct MapStore {
    path: PathBuf,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Layer,
    Repeaters,
}

impl Kind {
    fn db(self) -> &'static str {
        match self {
            Kind::Layer => "layer",
            Kind::Repeaters => "repeaters",
        }
    }
    fn prefix(self) -> char {
        match self {
            Kind::Layer => 'y',
            Kind::Repeaters => 'l',
        }
    }
}

/// One layer or list as stored.
#[derive(Clone, Debug)]
struct List {
    id: i64,
    kind: Kind,
    name: String,
    files: Vec<String>,
    private: bool,
    visible: bool,
}

impl List {
    fn sid(&self) -> String {
        format!("{}{}", self.kind.prefix(), self.id)
    }
}

enum Item {
    Shape(Feature),
    Repeater(Box<Repeater>),
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as i64).unwrap_or(0)
}

fn not_found(id: &str) -> Error {
    Error { code: "not_found", message: format!("no map layer or repeater list with id {id:?}") }
}

fn io(m: impl Into<String>) -> Error {
    Error { code: "io", message: m.into() }
}

/// "y3" / "l2" as (kind, number).
fn parse_id(id: &str) -> Option<(Kind, i64)> {
    let kind = match id.chars().next()? {
        'y' => Kind::Layer,
        'l' => Kind::Repeaters,
        _ => return None,
    };
    let n: i64 = id[1..].parse().ok().filter(|n| *n > 0)?;
    (id[1..] == n.to_string()).then_some((kind, n))
}

fn file_name(p: &str) -> String {
    Path::new(p).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| p.to_string())
}

fn read_file(p: &str) -> Result<Vec<u8>> {
    let meta = std::fs::metadata(p).map_err(|e| io(format!("{p}: {e}")))?;
    if meta.len() > MAX_FILE_BYTES {
        return Err(bad(format!("{}: larger than {} MB", file_name(p), MAX_FILE_BYTES >> 20)));
    }
    std::fs::read(p).map_err(|e| io(format!("{p}: {e}")))
}

/// What `points` shows of a layer point's notes: whitespace collapsed, cut to 200 characters.
pub fn notes_shown(notes: &str) -> Option<String> {
    let c = collapse(notes);
    let cut: String = c.chars().take(MAX_NOTES).collect();
    let cut = cut.trim_end().to_string();
    (!cut.is_empty()).then_some(cut)
}

impl MapStore {
    pub fn new(db_path: impl AsRef<Path>) -> MapStore {
        MapStore { path: db_path.as_ref().to_path_buf() }
    }

    fn db(&self) -> Result<Connection> {
        if let Some(dir) = self.path.parent() {
            if !dir.as_os_str().is_empty() {
                let _ = std::fs::create_dir_all(dir);
            }
        }
        let c = Connection::open(&self.path)?;
        c.busy_timeout(std::time::Duration::from_secs(5))?;
        c.execute_batch(
            "CREATE TABLE IF NOT EXISTS map_lists(
                id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, name TEXT NOT NULL, files TEXT NOT NULL,
                private INTEGER NOT NULL DEFAULT 0, visible INTEGER NOT NULL DEFAULT 1, used_at INTEGER NOT NULL,
                created_at INTEGER NOT NULL);
             CREATE TABLE IF NOT EXISTS map_items(
                list_id INTEGER NOT NULL REFERENCES map_lists(id) ON DELETE CASCADE, ord INTEGER NOT NULL,
                name TEXT NOT NULL, notes TEXT NOT NULL, geom TEXT NOT NULL, lat REAL, lon REAL, data TEXT,
                PRIMARY KEY(list_id, ord));",
        )?;
        Ok(c)
    }

    /// A strictly later "used" time than any stored one, so the order of two changes in one millisecond is kept.
    fn next_used(c: &Connection) -> Result<i64> {
        let max: Option<i64> = c.query_row("SELECT MAX(used_at) FROM map_lists", [], |r| r.get(0))?;
        Ok(now_ms().max(max.unwrap_or(0) + 1))
    }

    /// Every layer and list, most recently used first.
    fn lists(c: &Connection) -> Result<Vec<List>> {
        let mut st = c.prepare("SELECT id, kind, name, files, private, visible FROM map_lists ORDER BY used_at DESC, id DESC")?;
        let rows = st.query_map([], |r| {
            let kind: String = r.get(1)?;
            let files: String = r.get(3)?;
            Ok(List {
                id: r.get(0)?,
                kind: if kind == "layer" { Kind::Layer } else { Kind::Repeaters },
                name: r.get(2)?,
                files: serde_json::from_str(&files).unwrap_or_default(),
                private: r.get::<_, i64>(4)? != 0,
                visible: r.get::<_, i64>(5)? != 0,
            })
        })?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    fn items(c: &Connection, list: &List) -> Result<Vec<(u32, Item)>> {
        let mut st = c.prepare("SELECT ord, name, notes, geom, data FROM map_items WHERE list_id=?1 ORDER BY ord")?;
        let rows = st.query_map([list.id], |r| Ok((r.get::<_, u32>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?, r.get::<_, Option<String>>(4)?)))?;
        let mut out = Vec::new();
        for row in rows {
            let (ord, name, notes, geom, data) = row?;
            let item = match (list.kind, data) {
                (Kind::Repeaters, Some(d)) => Item::Repeater(Box::new(serde_json::from_str(&d).map_err(|e| io(format!("stored repeater: {e}")))?)),
                _ => Item::Shape(Feature { name, notes, geom: serde_json::from_str(&geom).map_err(|e| io(format!("stored shape: {e}")))? }),
            };
            out.push((ord, item));
        }
        Ok(out)
    }

    fn list_by_id(c: &Connection, id: &str) -> Result<List> {
        let (kind, n) = parse_id(id).ok_or_else(|| not_found(id))?;
        Self::lists(c)?.into_iter().find(|l| l.id == n && l.kind == kind).ok_or_else(|| not_found(id))
    }

    /// The `nearby` category id of every layer that has a point, most recently used first (all of them, not only the 10).
    fn layer_categories(c: &Connection) -> Result<Vec<(List, String)>> {
        let mut out: Vec<(List, String)> = Vec::new();
        let mut taken: Vec<String> = Vec::new();
        for l in Self::lists(c)?.into_iter().filter(|l| l.kind == Kind::Layer) {
            let points: i64 = c.query_row("SELECT COUNT(*) FROM map_items WHERE list_id=?1 AND lat IS NOT NULL", [l.id], |r| r.get(0))?;
            if points == 0 {
                continue;
            }
            let base = format!("{LAYER_PREFIX}{}", slug(&l.name, MAX_CATEGORY_ID - LAYER_PREFIX.len(), "layer"));
            let id = unique(&base, &taken, MAX_CATEGORY_ID);
            taken.push(id.clone());
            out.push((l, id));
        }
        Ok(out)
    }

    fn summary(c: &Connection, l: &List, extra: Option<(&str, Value)>) -> Result<Value> {
        let items = Self::items(c, l)?;
        let mut m = Map::new();
        m.insert("id".into(), json!(l.sid()));
        m.insert("kind".into(), json!(l.kind.db()));
        m.insert("name".into(), json!(l.name));
        m.insert("files".into(), json!(l.files));
        if l.kind == Kind::Layer {
            m.insert("private".into(), json!(l.private));
        }
        m.insert("visible".into(), json!(l.visible));
        match l.kind {
            Kind::Layer => {
                let n = |f: fn(&Geom) -> bool| items.iter().filter(|(_, i)| matches!(i, Item::Shape(s) if f(&s.geom))).count();
                m.insert("points".into(), json!(n(|g| matches!(g, Geom::Point(..)))));
                m.insert("lines".into(), json!(n(|g| matches!(g, Geom::Line(..)))));
                m.insert("areas".into(), json!(n(|g| matches!(g, Geom::Area(..)))));
                let cat = Self::layer_categories(c)?.into_iter().find(|(x, _)| x.id == l.id).map(|(_, id)| id);
                m.insert("category".into(), json!(cat));
            }
            Kind::Repeaters => {
                let reps: Vec<&Repeater> = items.iter().filter_map(|(_, i)| if let Item::Repeater(r) = i { Some(&**r) } else { None }).collect();
                m.insert("repeaters".into(), json!(reps.len()));
                m.insert("with_position".into(), json!(reps.iter().filter(|r| r.positioned().is_some()).count()));
                m.insert("merged".into(), json!(reps.iter().filter(|r| r.positioned().is_some() && r.chirp.is_some()).count()));
                m.insert("without_position".into(), json!(reps.iter().filter(|r| r.positioned().is_none()).count()));
            }
        }
        if let Some((k, v)) = extra {
            m.insert(k.into(), v);
        }
        Ok(Value::Object(m))
    }

    /// `cs_userlayers_import`: `{"kind":"layer"|"repeaters","paths":[...],"name"?,"private"?,"replace"?}`.
    ///
    /// A layer is one file (KML, KMZ, GPX, GeoJSON or a layer JSON); its name is `name`, else the file's own, else the file
    /// name without its extension; `private` is `private`, else the layer JSON's, else false. A repeater list is one or
    /// more KML and CHIRP CSV files, merged (repeater.rs); its name is `name`, else the first KML's file name, else the
    /// first CSV's. `replace`: first delete the layers or lists of this kind imported from the same file names.
    /// Returns the new layer or list as `cs_userlayers_list` shows it (a list also says how many pins were `skipped`).
    pub fn import(&self, json: &str) -> Result<String> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct In {
            kind: String,
            paths: Vec<String>,
            #[serde(default)]
            name: Option<String>,
            #[serde(default)]
            private: Option<bool>,
            #[serde(default)]
            replace: bool,
        }
        let a: In = serde_json::from_str(json).map_err(|e| bad(format!("import_json: {e}")))?;
        let kind = match a.kind.as_str() {
            "layer" => Kind::Layer,
            "repeaters" => Kind::Repeaters,
            k => return Err(bad(format!("kind {k:?}: must be \"layer\" or \"repeaters\""))),
        };
        if a.paths.is_empty() {
            return Err(bad("paths: at least one file"));
        }
        let given = a.name.as_deref().map(collapse).filter(|n| !n.is_empty());
        if given.as_ref().is_some_and(|n| n.chars().count() > 200) {
            return Err(bad("name must be at most 200 characters"));
        }
        let files: Vec<String> = a.paths.iter().map(|p| file_name(p)).collect();
        let (name, private, items, skipped): (String, bool, Vec<Item>, Option<usize>) = match kind {
            Kind::Layer => {
                if a.paths.len() != 1 {
                    return Err(bad("a layer is imported from one file"));
                }
                let bytes = read_file(&a.paths[0])?;
                let fk = file_kind(&files[0], &bytes).filter(|k| *k != FileKind::ChirpCsv).ok_or_else(|| bad(format!("{}: a layer is a .kml, .kmz, .gpx, .geojson or .json file", files[0])))?;
                let parsed = super::parse_layer(fk, &bytes).map_err(|e| bad(format!("{}: {}", files[0], e.message)))?;
                let stem = Path::new(&files[0]).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                let name = given.clone().or(parsed.name).unwrap_or_else(|| collapse(&stem));
                (name, a.private.or(parsed.private).unwrap_or(false), parsed.features.into_iter().map(Item::Shape).collect(), None)
            }
            Kind::Repeaters => {
                if a.private.is_some() {
                    return Err(bad("private: only for a layer"));
                }
                let (mut pins, mut rows, mut skipped) = (Vec::new(), Vec::new(), 0);
                let (mut first_kml, mut first_csv) = (None, None);
                for (p, f) in a.paths.iter().zip(&files) {
                    let bytes = read_file(p)?;
                    let at = |e: Error| bad(format!("{f}: {}", e.message));
                    match file_kind(f, &bytes) {
                        Some(FileKind::Kml) | Some(FileKind::Kmz) => {
                            let text = if file_kind(f, &bytes) == Some(FileKind::Kmz) { utf8(&super::zip::kml_of_kmz(&bytes).map_err(at)?, "KML in the KMZ").map_err(at)? } else { utf8(&bytes, "KML").map_err(at)? };
                            let (p, s) = kml::parse_repeaters(&text).map_err(at)?;
                            pins.extend(p);
                            skipped += s;
                            first_kml.get_or_insert(f.clone());
                        }
                        Some(FileKind::ChirpCsv) => {
                            rows.extend(chirp::parse(&utf8(&bytes, "CSV").map_err(at)?).map_err(at)?);
                            first_csv.get_or_insert(f.clone());
                        }
                        _ => return Err(bad(format!("{f}: a repeater list is a RepeaterBook-style .kml (or .kmz) or a CHIRP .csv"))),
                    }
                }
                let merged = super::repeater::merge(pins, rows);
                if merged.is_empty() {
                    return Err(bad("no repeaters in the imported files"));
                }
                let name = given.clone().or(first_kml).or(first_csv).unwrap_or_default();
                (name, false, merged.into_iter().map(|r| Item::Repeater(Box::new(r))).collect(), Some(skipped))
            }
        };
        let mut c = self.db()?;
        let tx = c.transaction()?;
        if a.replace {
            let same: Vec<i64> = Self::lists(&tx)?.into_iter().filter(|l| l.kind == kind && l.files == files).map(|l| l.id).collect();
            for id in same {
                tx.execute("DELETE FROM map_items WHERE list_id=?1", [id])?;
                tx.execute("DELETE FROM map_lists WHERE id=?1", [id])?;
            }
        }
        let used = Self::next_used(&tx)?;
        tx.execute(
            "INSERT INTO map_lists(kind,name,files,private,visible,used_at,created_at) VALUES(?1,?2,?3,?4,1,?5,?5)",
            params![kind.db(), name, serde_json::to_string(&files).expect("files"), private as i64, used],
        )?;
        let id = tx.last_insert_rowid();
        for (i, it) in items.iter().enumerate() {
            let ord = i as i64 + 1;
            match it {
                Item::Shape(f) => {
                    let (lat, lon) = match f.geom {
                        Geom::Point(la, lo) => (Some(la), Some(lo)),
                        _ => (None, None),
                    };
                    tx.execute(
                        "INSERT INTO map_items(list_id,ord,name,notes,geom,lat,lon,data) VALUES(?1,?2,?3,?4,?5,?6,?7,NULL)",
                        params![id, ord, f.name, f.notes, serde_json::to_string(&f.geom).expect("geom"), lat, lon],
                    )?;
                }
                Item::Repeater(r) => {
                    let geom = r.positioned().map(|(la, lo)| Geom::Point(la, lo));
                    tx.execute(
                        "INSERT INTO map_items(list_id,ord,name,notes,geom,lat,lon,data) VALUES(?1,?2,?3,'',?4,?5,?6,?7)",
                        params![id, ord, r.name, serde_json::to_string(&geom).expect("geom"), r.lat, r.lon, serde_json::to_string(&**r).expect("repeater")],
                    )?;
                }
            }
        }
        tx.commit()?;
        let l = Self::list_by_id(&c, &format!("{}{id}", kind.prefix()))?;
        Ok(Self::summary(&c, &l, skipped.map(|s| ("skipped", json!(s))))?.to_string())
    }

    /// `cs_userlayers_list`: `{"layers":[...],"repeater_lists":[...]}`, most recently used first.
    pub fn list_json(&self) -> Result<String> {
        let c = self.db()?;
        let (mut layers, mut reps) = (Vec::new(), Vec::new());
        for l in Self::lists(&c)? {
            let s = Self::summary(&c, &l, None)?;
            if l.kind == Kind::Layer { layers.push(s) } else { reps.push(s) }
        }
        Ok(json!({"layers": layers, "repeater_lists": reps}).to_string())
    }

    /// `cs_userlayer_get`: a layer as its layer JSON (a GeoJSON FeatureCollection with "id", "name" and "private"; each
    /// feature's "id" is its item number), or a repeater list with every repeater's settings for the map and its cards.
    pub fn get(&self, id: &str) -> Result<String> {
        let c = self.db()?;
        let l = Self::list_by_id(&c, id)?;
        let items = Self::items(&c, &l)?;
        let out = match l.kind {
            Kind::Layer => {
                let fs: Vec<(u32, &Feature)> = items.iter().filter_map(|(o, i)| if let Item::Shape(f) = i { Some((*o, f)) } else { None }).collect();
                let mut v = geojson::write(&l.name, l.private, &fs);
                if let Value::Object(m) = &mut v {
                    let mut o = Map::new();
                    o.insert("id".into(), json!(l.sid()));
                    o.extend(std::mem::take(m));
                    *m = o;
                }
                v
            }
            Kind::Repeaters => {
                let reps: Vec<Value> = items
                    .iter()
                    .filter_map(|(o, i)| if let Item::Repeater(r) = i { Some((o, r)) } else { None })
                    .map(|(o, r)| {
                        let mut m = Map::new();
                        m.insert("item".into(), json!(o));
                        m.insert("address".into(), json!(format!("repeater:{}/{o}", l.sid())));
                        m.insert("name".into(), json!(r.name));
                        m.insert("town".into(), json!(r.town));
                        m.insert("lat".into(), json!(r.lat));
                        m.insert("lon".into(), json!(r.lon));
                        for (k, v) in repeater_fields(r, &l.name) {
                            m.insert(k, v);
                        }
                        m.insert("details_link".into(), json!(r.link));
                        Value::Object(m)
                    })
                    .collect();
                json!({"id": l.sid(), "name": l.name, "repeaters": reps})
            }
        };
        Ok(out.to_string())
    }

    /// `cs_userlayer_set_visible`: `{"id","visible"}`. Shown on the map or not; counts as a use. Returns the summary.
    pub fn set_visible(&self, json: &str) -> Result<String> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct In {
            id: String,
            visible: bool,
        }
        let a: In = serde_json::from_str(json).map_err(|e| bad(format!("visible_json: {e}")))?;
        let c = self.db()?;
        let l = Self::list_by_id(&c, &a.id)?;
        let used = Self::next_used(&c)?;
        c.execute("UPDATE map_lists SET visible=?1, used_at=?2 WHERE id=?3", params![a.visible as i64, used, l.id])?;
        let l = Self::list_by_id(&c, &a.id)?;
        Ok(Self::summary(&c, &l, None)?.to_string())
    }

    /// `cs_userlayer_delete`: `{"deleted":"<id>"}`, or `not_found`.
    pub fn delete(&self, id: &str) -> Result<String> {
        let c = self.db()?;
        let l = Self::list_by_id(&c, id)?;
        c.execute("DELETE FROM map_items WHERE list_id=?1", [l.id])?;
        c.execute("DELETE FROM map_lists WHERE id=?1", [l.id])?;
        Ok(json!({"deleted": id}).to_string())
    }

    /// `cs_userlayer_export`: `{"id","format":"kml"|"gpx","path"}` writes the file (GPX for a layer only).
    /// Returns `{"id","format","path","bytes"}`.
    pub fn export(&self, json: &str) -> Result<String> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct In {
            id: String,
            format: String,
            path: String,
        }
        let a: In = serde_json::from_str(json).map_err(|e| bad(format!("export_json: {e}")))?;
        let c = self.db()?;
        let l = Self::list_by_id(&c, &a.id)?;
        let items = Self::items(&c, &l)?;
        let shapes = || items.iter().filter_map(|(_, i)| if let Item::Shape(f) = i { Some(f.clone()) } else { None }).collect::<Vec<_>>();
        let text = match (l.kind, a.format.as_str()) {
            (Kind::Layer, "kml") => kml::write_layer(&l.name, &shapes()),
            (Kind::Layer, "gpx") => gpx::write(&l.name, &shapes()),
            (Kind::Repeaters, "kml") => {
                let reps: Vec<Repeater> = items.iter().filter_map(|(_, i)| if let Item::Repeater(r) = i { Some((**r).clone()) } else { None }).collect();
                kml::write_repeaters(&l.name, &reps)
            }
            (Kind::Repeaters, "gpx") => return Err(bad("a repeater list exports as KML")),
            (_, f) => return Err(bad(format!("format {f:?}: must be \"kml\" or \"gpx\""))),
        };
        std::fs::write(&a.path, text.as_bytes()).map_err(|e| io(format!("{}: {e}", a.path)))?;
        Ok(json!({"id": a.id, "format": a.format, "path": a.path, "bytes": text.len()}).to_string())
    }
}

/// A repeater's settings as `nearby` shows them, after `direction`.
fn repeater_fields(r: &Repeater, list: &str) -> Vec<(String, Value)> {
    let mut v: Vec<(String, Value)> = vec![
        ("frequency".into(), json!(frequency_text(r.freq_hz))),
        ("offset".into(), json!(r.offset_text())),
        ("tone".into(), json!(r.tone_text())),
    ];
    if let Some(m) = &r.mode {
        v.push(("mode".into(), json!(m)));
    }
    if let Some(a) = r.on_air {
        v.push(("on_air".into(), json!(if a { "yes" } else { "no" })));
    }
    v.push(("list".into(), json!(list)));
    if r.link.is_some() {
        v.push(("details".into(), json!(REPEATER_DETAILS)));
    }
    v
}

impl MapStore {
    fn layer_point(l: &List, ord: u32, f: &Feature) -> Option<UserPoint> {
        let Geom::Point(lat, lon) = f.geom else { return None };
        let mut fields = Map::new();
        if let Some(n) = notes_shown(&f.notes) {
            fields.insert("notes".into(), json!(n));
        }
        let name = if f.name.trim().is_empty() { format!("{} point {ord}", l.name) } else { f.name.clone() };
        Some(UserPoint { address: format!("layer:{}/{ord}", l.sid()), name, kind: "layer_point".into(), kind_label: l.name.clone(), locality: None, lat, lon, fields })
    }

    fn try_categories(&self) -> Result<Vec<UserCategory>> {
        let c = self.db()?;
        let mut out = Vec::new();
        let any_rep: Option<i64> = c
            .query_row("SELECT 1 FROM map_items i JOIN map_lists l ON l.id=i.list_id WHERE l.kind='repeaters' AND i.lat IS NOT NULL LIMIT 1", [], |r| r.get(0))
            .optional()?;
        if any_rep.is_some() {
            out.push(UserCategory { id: "repeater".into(), description: "amateur radio repeaters from the user's imported lists".into(), plural: "repeaters".into() });
        }
        for (l, id) in Self::layer_categories(&c)?.into_iter().take(MAX_LAYER_CATEGORIES) {
            out.push(UserCategory { id, description: format!("{}: points in the user's own map layer", l.name), plural: format!("points of the layer {:?}", l.name) });
        }
        Ok(out)
    }

    fn try_points(&self, category: &str) -> Result<Option<Vec<UserPoint>>> {
        let c = self.db()?;
        if category == "repeater" {
            let mut out = Vec::new();
            for l in Self::lists(&c)?.into_iter().filter(|l| l.kind == Kind::Repeaters) {
                for (ord, it) in Self::items(&c, &l)? {
                    let Item::Repeater(r) = it else { continue };
                    let Some((lat, lon)) = r.positioned() else { continue };
                    out.push(UserPoint {
                        address: format!("repeater:{}/{ord}", l.sid()),
                        name: r.name.clone(),
                        kind: "repeater".into(),
                        kind_label: "Repeater".into(),
                        locality: r.town.clone(),
                        lat,
                        lon,
                        fields: repeater_fields(&r, &l.name).into_iter().collect(),
                    });
                }
            }
            return Ok((!out.is_empty()).then_some(out));
        }
        let Some((l, _)) = Self::layer_categories(&c)?.into_iter().take(MAX_LAYER_CATEGORIES).find(|(_, id)| id == category) else {
            return Ok(None);
        };
        let items = Self::items(&c, &l)?;
        Ok(Some(items.iter().filter_map(|(o, i)| if let Item::Shape(f) = i { Self::layer_point(&l, *o, f) } else { None }).collect()))
    }

    fn try_named(&self, name: &str) -> Result<Vec<UserPoint>> {
        let want = collapse(name).to_lowercase();
        if want.is_empty() {
            return Ok(Vec::new());
        }
        let c = self.db()?;
        let mut out = Vec::new();
        for l in Self::lists(&c)?.into_iter().filter(|l| l.kind == Kind::Layer) {
            for (o, it) in Self::items(&c, &l)? {
                if let Item::Shape(f) = &it {
                    if collapse(&f.name).to_lowercase() == want {
                        out.extend(Self::layer_point(&l, o, f));
                    }
                }
            }
        }
        Ok(out)
    }
}

impl UserPoints for MapStore {
    fn categories(&self) -> Vec<UserCategory> {
        self.try_categories().unwrap_or_default()
    }
    fn points(&self, category: &str) -> Option<Vec<UserPoint>> {
        self.try_points(category).ok().flatten()
    }
    fn named(&self, name: &str) -> Vec<UserPoint> {
        self.try_named(name).unwrap_or_default()
    }
    fn note(&self, kind: &str) -> Option<(&'static str, &'static str)> {
        (kind == "repeater").then_some(("repeater_note", REPEATER_NOTE))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Tmp(PathBuf);
    impl Tmp {
        fn new(name: &str) -> Tmp {
            let p = std::env::temp_dir().join(format!("cache-mapdata-{}-{name}", std::process::id()));
            let _ = std::fs::remove_dir_all(&p);
            std::fs::create_dir_all(&p).unwrap();
            Tmp(p)
        }
        fn store(&self) -> MapStore {
            MapStore::new(self.0.join("user.sqlite"))
        }
        fn path(&self, f: &str) -> String {
            self.0.join(f).to_string_lossy().into_owned()
        }
    }
    impl Drop for Tmp {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    pub(crate) fn fixture(f: &str) -> String {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(f).to_string_lossy().into_owned()
    }

    fn v(s: &str) -> Value {
        serde_json::from_str(s).unwrap()
    }

    fn import(s: &MapStore, a: Value) -> Result<Value> {
        s.import(&a.to_string()).map(|r| v(&r))
    }

    #[test]
    fn a_kml_and_a_chirp_csv_of_one_export_merge() {
        let t = Tmp::new("merge");
        let s = t.store();
        let r = import(&s, json!({"kind": "repeaters", "paths": [fixture("repeaters-fixture.kml"), fixture("repeaters-fixture.csv")]})).unwrap();
        assert_eq!(
            r.to_string(),
            r#"{"id":"l1","kind":"repeaters","name":"repeaters-fixture.kml","files":["repeaters-fixture.kml","repeaters-fixture.csv"],"visible":true,"repeaters":6,"with_position":5,"merged":4,"without_position":1,"skipped":0}"#
        );
        let pts = s.points("repeater").unwrap();
        assert_eq!(pts.len(), 5, "the unpaired CHIRP row has no position");
        let row = |i: usize| Value::Object(pts[i].fields.clone()).to_string();
        assert_eq!((pts[0].address.as_str(), pts[0].name.as_str(), pts[0].kind.as_str(), pts[0].kind_label.as_str(), pts[0].locality.as_deref()), ("repeater:l1/1", "TEST1", "repeater", "Repeater", Some("Burley")));
        assert_eq!(row(0), r#"{"frequency":"927.1625 MHz","offset":"-25 MHz","tone":"151.4 Hz to transmit","mode":"FM","on_air":"yes","list":"repeaters-fixture.kml","details":"full page on RepeaterBook (opens in the browser; needs a connection)"}"#);
        assert_eq!(row(1), r#"{"frequency":"449.200 MHz","offset":"-5 MHz","tone":"DCS 432","mode":"DMR","on_air":"yes","list":"repeaters-fixture.kml","details":"full page on RepeaterBook (opens in the browser; needs a connection)"}"#);
        assert_eq!(row(2), r#"{"frequency":"147.360 MHz","offset":"+600 kHz","tone":"100.0 Hz to transmit and receive","mode":"FM","on_air":"no","list":"repeaters-fixture.kml"}"#);
        assert_eq!(row(3), r#"{"frequency":"146.450 MHz","offset":"split: transmit 147.45 MHz","tone":"none","on_air":"yes","list":"repeaters-fixture.kml","details":"full page on RepeaterBook (opens in the browser; needs a connection)"}"#);
        // KML only: the sign without the amount, the tone without its use, no mode
        assert_eq!(row(4), r#"{"frequency":"145.230 MHz","offset":"- (amount not in the imported list)","tone":"88.5 Hz (use not stated in the imported list)","on_air":"yes","list":"repeaters-fixture.kml"}"#);
        assert_eq!(s.categories()[0], UserCategory { id: "repeater".into(), description: "amateur radio repeaters from the user's imported lists".into(), plural: "repeaters".into() });
        assert_eq!(s.note("repeater"), Some(("repeater_note", REPEATER_NOTE)));
        assert_eq!(s.note("layer_point"), None);
        // the map gets every repeater, the link included
        let g = v(&s.get("l1").unwrap());
        assert_eq!(g["repeaters"].as_array().unwrap().len(), 6);
        assert_eq!(g["repeaters"][0]["details_link"], "https://www.repeaterbook.com/repeaters/details.php?state_id=16&ID=90001");
        assert_eq!(g["repeaters"][5]["name"], "Albion");
        assert_eq!(g["repeaters"][5]["lat"], Value::Null);
    }

    #[test]
    fn either_file_alone_is_a_list() {
        let t = Tmp::new("alone");
        let s = t.store();
        let k = import(&s, json!({"kind": "repeaters", "paths": [fixture("repeaters-fixture.kml")]})).unwrap();
        assert_eq!((k["repeaters"].clone(), k["with_position"].clone(), k["merged"].clone()), (json!(5), json!(5), json!(0)));
        let c = import(&s, json!({"kind": "repeaters", "paths": [fixture("repeaters-fixture.csv")], "name": "Radio"})).unwrap();
        assert_eq!((c["id"].clone(), c["name"].clone(), c["with_position"].clone(), c["without_position"].clone()), (json!("l2"), json!("Radio"), json!(0), json!(5)));
        // a CHIRP-only list has nothing to show; the KML list still does
        assert_eq!(s.points("repeater").unwrap().len(), 5);
        s.delete("l1").unwrap();
        assert!(s.points("repeater").is_none());
        assert!(s.categories().is_empty());
    }

    /// The owner's own RepeaterBook export (218 repeaters, the KML and the CHIRP CSV in the same order). Not in the repository:
    /// set CACHE_REPEATER_SAMPLES to the folder holding repeaters_2610290107.kml and RB-chirp-2610290107.csv.
    #[test]
    #[ignore = "needs CACHE_REPEATER_SAMPLES"]
    fn the_sample_export_merges_all_218() {
        let dir = std::env::var("CACHE_REPEATER_SAMPLES").expect("CACHE_REPEATER_SAMPLES");
        let (kml, csv) = (format!("{dir}/repeaters_2610290107.kml"), format!("{dir}/RB-chirp-2610290107.csv"));
        let t = Tmp::new("sample");
        let s = t.store();
        let r = import(&s, json!({"kind": "repeaters", "paths": [kml, csv]})).unwrap();
        assert_eq!((r["repeaters"].clone(), r["with_position"].clone(), r["merged"].clone(), r["without_position"].clone(), r["skipped"].clone()), (json!(218), json!(218), json!(218), json!(0), json!(0)), "{r}");
        let pts = s.points("repeater").unwrap();
        let f = |i: usize, k: &str| pts[i].fields[k].as_str().unwrap().to_string();
        assert_eq!((f(0, "frequency"), f(0, "offset"), f(0, "tone"), f(0, "mode")), ("927.1625 MHz".into(), "-25 MHz".into(), "151.4 Hz to transmit".into(), "FM".into()));
        assert_eq!(pts[0].locality.as_deref(), Some("Cascade"));
        assert_eq!(f(2, "tone"), "DCS 432");
        assert_eq!((f(3, "tone"), pts[3].fields.get("mode")), ("none".into(), None), "CHIRP Mode Auto is left out");
        assert_eq!(f(3, "offset"), "-5 MHz");
        // the town with a comma and the town with a character reference pair too
        let town = |t: &str| pts.iter().filter(|p| p.locality.as_deref() == Some(t)).count();
        assert!(town("Pocatello, ID") >= 1 && town("Coeur d'Alene") >= 1);
        let split = pts.iter().find(|p| p.fields["offset"].as_str().unwrap().starts_with("split")).unwrap();
        assert_eq!(split.fields["offset"], "split: transmit 147.45 MHz");
        assert!(pts.iter().all(|p| p.fields["list"] == "repeaters_2610290107.kml"));
        // "On-air: Unknown" leaves on_air out
        let on_air = |w: Option<&str>| pts.iter().filter(|p| p.fields.get("on_air").and_then(Value::as_str) == w).count();
        assert_eq!((on_air(Some("yes")), on_air(Some("no")), on_air(None)), (187, 9, 22));
        // KML alone: every offset amount is missing, the CSV alone: nothing to show
        let k = import(&s, json!({"kind": "repeaters", "paths": [format!("{dir}/repeaters_2610290107.kml")]})).unwrap();
        assert_eq!(k["with_position"], 218);
        let c = import(&s, json!({"kind": "repeaters", "paths": [format!("{dir}/RB-chirp-2610290107.csv")]})).unwrap();
        assert_eq!((c["repeaters"].clone(), c["with_position"].clone()), (json!(218), json!(0)));
        // export and import again: the same repeaters
        let out = t.path("export.kml");
        s.export(&json!({"id": "l1", "format": "kml", "path": out}).to_string()).unwrap();
        let back = import(&s, json!({"kind": "repeaters", "paths": [out]})).unwrap();
        assert_eq!((back["repeaters"].clone(), back["merged"].clone()), (json!(218), json!(218)));
        let a = v(&s.get("l1").unwrap())["repeaters"].clone();
        let mut b = v(&s.get(back["id"].as_str().unwrap()).unwrap())["repeaters"].clone();
        for (x, y) in a.as_array().unwrap().iter().zip(b.as_array_mut().unwrap()) {
            y["address"] = x["address"].clone();
            y["list"] = x["list"].clone();
        }
        assert_eq!(a, b);
    }

    #[test]
    fn repeater_export_round_trip() {
        let t = Tmp::new("rexport");
        let s = t.store();
        import(&s, json!({"kind": "repeaters", "paths": [fixture("repeaters-fixture.kml"), fixture("repeaters-fixture.csv")]})).unwrap();
        let out = t.path("out.kml");
        let e = v(&s.export(&json!({"id": "l1", "format": "kml", "path": out}).to_string()).unwrap());
        assert_eq!(e["path"], out);
        let text = std::fs::read_to_string(&out).unwrap();
        assert!(text.contains("Offset: -25 MHz<br>") && text.contains("<Data name=\"offset_mhz\"><value>25.000000</value></Data>"), "{text}");
        let back = import(&s, json!({"kind": "repeaters", "paths": [out]})).unwrap();
        assert_eq!((back["repeaters"].clone(), back["merged"].clone()), (json!(5), json!(4)), "the row without a position is not a pin");
        let a: Vec<Value> = v(&s.get("l1").unwrap())["repeaters"].as_array().unwrap()[..5].to_vec();
        let b: Vec<Value> = v(&s.get("l2").unwrap())["repeaters"].as_array().unwrap().to_vec();
        for (x, y) in a.iter().zip(&b) {
            for k in ["name", "town", "lat", "lon", "frequency", "offset", "tone", "mode", "on_air", "details", "details_link"] {
                assert_eq!(x.get(k), y.get(k), "{k}");
            }
        }
        assert_eq!(s.export(&json!({"id": "l1", "format": "gpx", "path": out}).to_string()).unwrap_err().message, "a repeater list exports as KML");
    }

    #[test]
    fn layers_of_every_format() {
        let t = Tmp::new("layers");
        let s = t.store();
        let g = import(&s, json!({"kind": "layer", "paths": [fixture("rally-points.geojson")]})).unwrap();
        assert_eq!(g.to_string(), r#"{"id":"y1","kind":"layer","name":"Rally Points","files":["rally-points.geojson"],"private":true,"visible":true,"points":2,"lines":1,"areas":1,"category":"layer_rally_points"}"#);
        let k = import(&s, json!({"kind": "layer", "paths": [fixture("elk-camp.kml")]})).unwrap();
        assert_eq!((k["name"].clone(), k["private"].clone(), k["category"].clone()), (json!("Elk Camp"), json!(false), json!("layer_elk_camp")));
        let x = import(&s, json!({"kind": "layer", "paths": [fixture("trip.gpx")], "name": "My trip", "private": true})).unwrap();
        assert_eq!((x["name"].clone(), x["private"].clone(), x["points"].clone(), x["lines"].clone()), (json!("My trip"), json!(true), json!(1), json!(1)));
        // a KMZ: the KML inside, named after the file without its extension when the KML has no name
        let kmz = t.path("Hunt Units.kmz");
        std::fs::write(&kmz, super::super::zip::make(&[("doc.kml", br#"<kml><Placemark><name>Stand</name><Point><coordinates>-113.7,42.5</coordinates></Point></Placemark></kml>"#)])).unwrap();
        let z = import(&s, json!({"kind": "layer", "paths": [kmz]})).unwrap();
        assert_eq!((z["id"].clone(), z["name"].clone(), z["points"].clone(), z["category"].clone()), (json!("y4"), json!("Hunt Units"), json!(1), json!("layer_hunt_units")));
        // most recently used first; the description names the layer after its id
        let cats: Vec<(String, String)> = s.categories().into_iter().map(|c| (c.id, c.description)).collect();
        assert_eq!(cats[0], ("layer_hunt_units".to_string(), "Hunt Units: points in the user's own map layer".to_string()));
        assert_eq!(cats.iter().map(|c| c.0.as_str()).collect::<Vec<_>>(), ["layer_hunt_units", "layer_my_trip", "layer_elk_camp", "layer_rally_points"]);
        // hiding is map-only and counts as a use
        let h = v(&s.set_visible(r#"{"id":"y1","visible":false}"#).unwrap());
        assert_eq!(h["visible"], false);
        assert_eq!(s.categories()[0].id, "layer_rally_points");
        let l = v(&s.list_json().unwrap());
        assert_eq!(l["layers"][0]["id"], "y1");
        assert_eq!(l["repeater_lists"], json!([]));
        // layer points: notes collapsed and cut to 200 characters
        let pts = s.points("layer_rally_points").unwrap();
        assert_eq!(pts.len(), 2);
        assert_eq!(
            (pts[0].address.as_str(), pts[0].name.as_str(), pts[0].kind.as_str(), pts[0].kind_label.as_str(), pts[0].locality.clone()),
            ("layer:y1/1", "North gate", "layer_point", "Rally Points", None)
        );
        assert_eq!(Value::Object(pts[0].fields.clone()).to_string(), r#"{"notes":"Meet here at dawn. Bring water and the radio."}"#);
        assert!(pts[1].fields.is_empty());
        let elk = s.points("layer_elk_camp").unwrap();
        let n = elk[0].fields["notes"].as_str().unwrap();
        assert_eq!(n.chars().count(), 200);
        assert!(n.starts_with("Elk camp gate. The road past"));
        assert!(s.points("layer_nothing").is_none());
        // the map's layer JSON
        let j = v(&s.get("y1").unwrap());
        assert_eq!((j["id"].clone(), j["type"].clone(), j["private"].clone(), j["features"].as_array().unwrap().len()), (json!("y1"), json!("FeatureCollection"), json!(true), 4));
        assert_eq!(j["features"][3]["id"], 4);
    }

    #[test]
    fn layer_points_by_name() {
        let t = Tmp::new("named");
        let s = t.store();
        import(&s, json!({"kind": "layer", "paths": [fixture("rally-points.geojson")]})).unwrap();
        import(&s, json!({"kind": "layer", "paths": [fixture("elk-camp.kml")]})).unwrap();
        // the same name in two layers: the most recently used layer first
        let n: Vec<(String, String)> = s.named("  NORTH   Gate ").into_iter().map(|p| (p.address, p.kind_label)).collect();
        assert_eq!(n, [("layer:y2/1".to_string(), "Elk Camp".to_string()), ("layer:y1/1".to_string(), "Rally Points".to_string())]);
        s.set_visible(r#"{"id":"y1","visible":true}"#).unwrap();
        assert_eq!(s.named("north gate")[0].address, "layer:y1/1");
        assert!(s.named("Walk between").is_empty(), "lines are map-only");
        assert!(s.named("north").is_empty(), "exact names only");
        assert!(s.named("").is_empty());
    }

    #[test]
    fn layer_export_round_trip_kml_and_gpx() {
        let t = Tmp::new("lexport");
        let s = t.store();
        import(&s, json!({"kind": "layer", "paths": [fixture("rally-points.geojson")]})).unwrap();
        for (fmt, file) in [("kml", "rally.kml"), ("gpx", "rally.gpx")] {
            let out = t.path(file);
            s.export(&json!({"id": "y1", "format": fmt, "path": out}).to_string()).unwrap();
            let back = import(&s, json!({"kind": "layer", "paths": [out]})).unwrap();
            assert_eq!(back["name"], "Rally Points");
            let (a, b) = (v(&s.get("y1").unwrap()), v(&s.get(back["id"].as_str().unwrap()).unwrap()));
            let geoms = |x: &Value| x["features"].as_array().unwrap().iter().map(|f| (f["properties"]["name"].clone(), f["geometry"]["coordinates"].clone())).collect::<Vec<_>>();
            if fmt == "kml" {
                assert_eq!(geoms(&a), geoms(&b));
                assert_eq!(b["features"][0]["properties"]["notes"], "Meet here at dawn.\nBring water and the radio.");
            } else {
                // GPX has no areas: the area comes back as a closed line
                assert_eq!(geoms(&a)[..3], geoms(&b)[..3]);
                assert_eq!(b["features"][3]["geometry"]["type"], "LineString");
            }
        }
    }

    #[test]
    fn replace_and_delete() {
        let t = Tmp::new("replace");
        let s = t.store();
        import(&s, json!({"kind": "layer", "paths": [fixture("rally-points.geojson")]})).unwrap();
        let again = import(&s, json!({"kind": "layer", "paths": [fixture("rally-points.geojson")], "replace": true})).unwrap();
        assert_eq!(again["id"], "y2");
        assert_eq!(v(&s.list_json().unwrap())["layers"].as_array().unwrap().len(), 1);
        assert_eq!(s.delete("y2").unwrap(), r#"{"deleted":"y2"}"#);
        for id in ["y2", "l1", "x1", "y", "y01", ""] {
            assert_eq!(s.delete(id).unwrap_err().code, "not_found", "{id}");
        }
    }

    #[test]
    fn category_ids_are_unique_and_at_most_ten_are_offered() {
        let t = Tmp::new("ten");
        let s = t.store();
        for i in 0..12 {
            let name = if i < 2 { "A very long layer name that goes on and on".to_string() } else { format!("Layer {i}") };
            import(&s, json!({"kind": "layer", "paths": [fixture("trip.gpx")], "name": name})).unwrap();
        }
        // a layer with no points is never offered
        let f = t.path("lines.geojson");
        std::fs::write(&f, r#"{"type":"LineString","coordinates":[[-113,42],[-113.1,42.1]]}"#).unwrap();
        import(&s, json!({"kind": "layer", "paths": [f]})).unwrap();
        let cats = s.categories();
        assert_eq!(cats.len(), 10);
        assert_eq!(cats[0].id, "layer_layer_11");
        // the two long names are the oldest: past the ten, but their ids are still fixed by the same order
        let all: Vec<String> = MapStore::layer_categories(&s.db().unwrap()).unwrap().into_iter().map(|(_, id)| id).collect();
        assert_eq!(all[10..], ["layer_a_very_long_layer_name_tha".to_string(), "layer_a_very_long_layer_name_t_2".to_string()]);
        assert!(all.iter().all(|id| id.len() <= 32));
        assert!(s.points("layer_a_very_long_layer_name_tha").is_none(), "not offered");
    }

    #[test]
    fn malformed_imports() {
        let t = Tmp::new("bad");
        let s = t.store();
        let bad_file = t.path("broken.kml");
        std::fs::write(&bad_file, "<kml><Placemark>").unwrap();
        let txt = t.path("notes.txt");
        std::fs::write(&txt, "x").unwrap();
        for (a, code, msg) in [
            (json!({"kind": "layer", "paths": [bad_file]}), "bad_json", "broken.kml: KML: not readable XML"),
            (json!({"kind": "layer", "paths": [txt]}), "bad_json", "notes.txt: a layer is a .kml"),
            (json!({"kind": "layer", "paths": [fixture("repeaters-fixture.csv")]}), "bad_json", "a layer is a .kml"),
            (json!({"kind": "layer", "paths": [t.path("missing.kml")]}), "io", "missing.kml"),
            (json!({"kind": "layer", "paths": []}), "bad_json", "at least one file"),
            (json!({"kind": "layer", "paths": [fixture("trip.gpx"), fixture("elk-camp.kml")]}), "bad_json", "one file"),
            (json!({"kind": "pins", "paths": [fixture("trip.gpx")]}), "bad_json", "kind \"pins\""),
            (json!({"kind": "layer", "paths": [fixture("trip.gpx")], "colour": "red"}), "bad_json", "unknown field"),
            (json!({"kind": "repeaters", "paths": [fixture("trip.gpx")]}), "bad_json", "trip.gpx: a repeater list is"),
            (json!({"kind": "repeaters", "paths": [fixture("elk-camp.kml")]}), "bad_json", "no repeaters"),
            (json!({"kind": "repeaters", "paths": [fixture("repeaters-fixture.kml")], "private": true}), "bad_json", "only for a layer"),
        ] {
            let e = s.import(&a.to_string()).unwrap_err();
            assert_eq!(e.code, code, "{a}");
            assert!(e.message.contains(msg), "{a}: {}", e.message);
        }
        assert!(s.import("{").is_err());
        assert_eq!(v(&s.list_json().unwrap()), json!({"layers": [], "repeater_lists": []}));
        assert_eq!(s.set_visible(r#"{"id":"y9","visible":true}"#).unwrap_err().code, "not_found");
        assert_eq!(s.export(r#"{"id":"y9","format":"kml","path":"x"}"#).unwrap_err().code, "not_found");
    }
}
