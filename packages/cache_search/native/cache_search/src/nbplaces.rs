//! Places notebooks and the user's map data as one store (`cs_notebook` beside `cs_place_*` and `cs_userlayer*`).
//!
//! - The saved places (cache_user's `places`, what `act` places.list and places.save and every place name resolve against)
//!   are the entries of one Places notebook, the saved-places notebook: an entry is a saved place, its place's `key` the saved
//!   place's key. Saving or deleting such an entry saves or deletes the saved place; a place saved or deleted through
//!   `cs_place_save` / `cs_place_delete` (the map's place card, the assistant's places.save) makes, updates or deletes its entry.
//!   When the two disagree otherwise (the first open after an update, or a crash between the two writes), the entry wins: it
//!   holds what the user wrote (notes, photos), and a saved place with no entry gets one.
//! - Every other Places notebook is a map layer of cache_user's mapdata, named after the notebook, kept in step after each
//!   change (`MapStore::sync_notebook_layers`). The tools see those places exactly as they see an imported layer's points.
//! - `import` reads a map layer file (KML, KMZ, GPX, GeoJSON, layer JSON) into a Places notebook: its points become entries,
//!   its lines and areas stay with the notebook's layer.

use crate::error::{Error, ErrorCode, Result};
use crate::ext::Ext;
use cache_user::mapdata::{self, Feature, Geom, NotebookLayer, NotebookPoint};
use serde_json::{json, Map, Value};
use std::sync::atomic::Ordering;

/// The ops that change notebooks or entries (after them the map layers are brought in step).
const CHANGES: [&str; 5] = ["notebook_save", "notebook_delete", "entry_save", "entry_delete", "import"];

fn nb_err(e: cache_notebook::Error) -> Error {
    Error::new(ErrorCode::from_str_code(e.code), e.message)
}

fn user_err(e: cache_user::Error) -> Error {
    Error::new(ErrorCode::from_str_code(e.code), e.message)
}

fn parse(text: &str) -> Result<Value> {
    serde_json::from_str(text).map_err(|e| Error::internal(format!("notebook answer: {e}")))
}

/// Unix seconds as `YYYY-MM-DDTHH:MM:SSZ` (the "When" of entries the core makes itself).
fn iso_utc(secs: i64) -> String {
    let days = secs.div_euclid(86_400);
    let rem = secs.rem_euclid(86_400);
    // civil from days (proleptic Gregorian)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + i64::from(m <= 2);
    format!("{y:04}-{m:02}-{d:02}T{:02}:{:02}:{:02}Z", rem / 3600, rem % 3600 / 60, rem % 60)
}

fn now_iso() -> String {
    iso_utc(std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0))
}

/// A saved place's name from an entry: its title, else its place's label, else "Place" (a saved place always has a name).
fn place_name(title: Option<&str>, label: Option<&str>) -> String {
    let pick = |s: Option<&str>| s.map(mapdata::collapse).filter(|s| !s.is_empty());
    let n = pick(title).or_else(|| pick(label)).unwrap_or_else(|| "Place".to_string());
    n.chars().take(200).collect()
}

/// The arguments of `entry_save` that rewrite `entry` (an entry as `entry` answers it) unchanged.
fn resave_args(entry: &Value) -> Value {
    let mut m = Map::new();
    for k in ["id", "notebook_id", "occurred_at", "title", "body", "values", "place", "photos", "files", "draft", "private", "props"] {
        if let Some(v) = entry.get(k) {
            m.insert(k.into(), v.clone());
        }
    }
    Value::Object(m)
}

impl Ext {
    fn nb(&self) -> Result<&cache_notebook::Notebook> {
        self.notebook
            .as_ref()
            .ok_or_else(|| Error::new(ErrorCode::NotConfigured, "Notebooks need \"notebook\": {\"db_path\", \"media_dir\"} in the cs_open config"))
    }

    fn nb_call(&self, op: &str, args: &Value) -> Result<Value> {
        parse(&self.nb()?.call(op, Some(&args.to_string())).map_err(nb_err)?)
    }

    /// `cs_notebook`: one op of Notebooks (cache_search.h lists them), with the saved places and the map layers kept in step.
    pub fn notebook(&self, op: &str, args_json: Option<&str>) -> Result<String> {
        let nb = self.nb()?;
        if !self.places_synced.swap(true, Ordering::SeqCst) {
            if let Err(e) = self.sync_places() {
                self.places_synced.store(false, Ordering::SeqCst);
                eprintln!("cache_search: saved places and notebooks not in step yet: {}", e.message);
            }
        }
        let out = match op {
            "entry_save" | "entry_delete" | "import" => {
                let args: Value = match args_json.map(str::trim).filter(|a| !a.is_empty()) {
                    Some(a) => serde_json::from_str(a).map_err(|e| Error::bad_json(format!("args: {e}")))?,
                    None => json!({}),
                };
                if !args.is_object() {
                    return Err(Error::bad_json("args must be a JSON object"));
                }
                match op {
                    "entry_save" => self.entry_save(&args)?.to_string(),
                    "entry_delete" => self.entry_delete(&args)?.to_string(),
                    _ => self.import(&args)?.to_string(),
                }
            }
            _ => nb.call(op, args_json).map_err(nb_err)?,
        };
        if CHANGES.contains(&op) {
            if let Err(e) = self.sync_layers() {
                eprintln!("cache_search: notebook map layers not in step: {}", e.message);
            }
        }
        Ok(out)
    }

    fn saved_id(&self) -> Result<String> {
        self.nb()?.saved_places_id().map_err(nb_err)
    }

    /// `entry_save`, and for the saved-places notebook the saved place first (an entry that is not a draft must have a place).
    fn entry_save(&self, args: &Value) -> Result<Value> {
        let (Some(user), Some(nb_id)) = (self.user.as_ref(), args.get("notebook_id").and_then(Value::as_str)) else {
            return self.nb_call("entry_save", args);
        };
        if nb_id != self.saved_id()? || args.get("draft").and_then(Value::as_bool) == Some(true) {
            return self.nb_call("entry_save", args);
        }
        let place = args.get("place").filter(|p| p.is_object()).ok_or_else(|| Error::bad_json("a saved place needs its place (lat and lon)"))?;
        let (Some(lat), Some(lon)) = (place.get("lat").and_then(Value::as_f64), place.get("lon").and_then(Value::as_f64)) else {
            return Err(Error::bad_json("place: lat and lon are required"));
        };
        let label = place.get("label").and_then(Value::as_str);
        // The key the entry had (a moved pin comes back without it), else the one it names when that saved place exists.
        let old = match args.get("id").and_then(Value::as_str) {
            Some(id) => self.nb_call("entry", &json!({"id": id})).ok(),
            None => None,
        };
        let known: Vec<String> = user.all().map_err(user_err)?.into_iter().map(|p| p.key).collect();
        let key = old
            .as_ref()
            .and_then(|e| e["place"]["key"].as_str())
            .or_else(|| place.get("key").and_then(Value::as_str))
            .filter(|k| known.iter().any(|x| x.as_str() == *k))
            .map(str::to_string);
        let mut save = json!({"name": place_name(args.get("title").and_then(Value::as_str), label), "lat": lat, "lon": lon});
        if let Some(k) = &key {
            save["key"] = json!(k);
        }
        if let Some(l) = label.filter(|l| !l.trim().is_empty()) {
            save["label"] = json!(l);
        }
        let saved = parse(&user.save(&save.to_string()).map_err(user_err)?)?;
        let new_key = saved["key"].as_str().unwrap_or_default().to_string();
        let mut a = args.clone();
        a["place"]["key"] = json!(new_key);
        match self.nb_call("entry_save", &a) {
            Ok(e) => Ok(e),
            Err(e) => {
                if key.is_none() {
                    let _ = user.delete(&new_key);
                }
                Err(e)
            }
        }
    }

    /// `entry_delete`; an entry of the saved-places notebook takes its saved place (and the live data kept for it) along.
    fn entry_delete(&self, args: &Value) -> Result<Value> {
        let before = args.get("id").and_then(Value::as_str).and_then(|id| self.nb_call("entry", &json!({"id": id})).ok());
        let out = self.nb_call("entry_delete", args)?;
        if let (Some(e), Some(user)) = (before, self.user.as_ref()) {
            if e["notebook_id"].as_str() == Some(self.saved_id()?.as_str()) {
                if let Some(k) = e["place"]["key"].as_str() {
                    if user.delete(k).is_ok() {
                        if let Some(l) = &self.live {
                            l.forget_place(k);
                        }
                    }
                }
            }
        }
        Ok(out)
    }

    /// Brings the saved places and the saved-places notebook in step (the entry wins; a saved place without an entry gets one),
    /// then the map layers.
    pub(crate) fn sync_places(&self) -> Result<()> {
        if let Some(user) = &self.user {
            let id = self.saved_id()?;
            let books = self.nb()?.places_books().map_err(nb_err)?;
            let saved: Vec<_> = books.into_iter().find(|b| b.id == id).map(|b| b.points).unwrap_or_default();
            let places = user.all().map_err(user_err)?;
            for p in &saved {
                let row = p.key.as_ref().and_then(|k| places.iter().find(|x| &x.key == k));
                let name = place_name(p.title.as_deref(), p.label.as_deref());
                let label = p.label.clone().filter(|l| !l.trim().is_empty());
                let same = row.is_some_and(|r| r.name == name && r.lat == p.lat && r.lon == p.lon && r.label == label);
                if same {
                    continue;
                }
                let mut save = json!({"name": name, "lat": p.lat, "lon": p.lon});
                if let Some(k) = &p.key {
                    save["key"] = json!(k);
                }
                if let Some(l) = &label {
                    save["label"] = json!(l);
                }
                let out = parse(&user.save(&save.to_string()).map_err(user_err)?)?;
                if p.key.as_deref() != out["key"].as_str() {
                    let mut e = resave_args(&self.nb_call("entry", &json!({"id": p.entry_id}))?);
                    e["place"]["key"] = out["key"].clone();
                    self.nb_call("entry_save", &e)?;
                }
            }
            for p in places.iter().filter(|p| !saved.iter().any(|e| e.key.as_deref() == Some(p.key.as_str()))) {
                self.entry_for_place(&id, &p.key, &p.name, p.lat, p.lon, p.label.as_deref())?;
            }
        }
        self.sync_layers()
    }

    /// Makes the entry of a saved place, or gives an existing one the place's name and position (its notes and photos stay).
    fn entry_for_place(&self, nb_id: &str, key: &str, name: &str, lat: f64, lon: f64, label: Option<&str>) -> Result<()> {
        let books = self.nb()?.places_books().map_err(nb_err)?;
        let existing = books.iter().find(|b| b.id == nb_id).and_then(|b| b.points.iter().find(|p| p.key.as_deref() == Some(key)));
        let mut place = json!({"lat": lat, "lon": lon, "key": key});
        if let Some(l) = label {
            place["label"] = json!(l);
        }
        let args = match existing {
            Some(p) => {
                let mut e = resave_args(&self.nb_call("entry", &json!({"id": p.entry_id}))?);
                e["title"] = json!(name);
                e["place"] = place;
                e
            }
            None => json!({"notebook_id": nb_id, "occurred_at": now_iso(), "title": name, "place": place}),
        };
        self.nb_call("entry_save", &args)?;
        Ok(())
    }

    /// After `cs_place_save`: the saved place's entry follows it.
    pub(crate) fn place_saved(&self, saved_json: &str) {
        if self.notebook.is_none() {
            return;
        }
        let r = (|| -> Result<()> {
            let p = parse(saved_json)?;
            let id = self.saved_id()?;
            let key = p["key"].as_str().unwrap_or_default();
            self.entry_for_place(&id, key, p["name"].as_str().unwrap_or("Place"), p["lat"].as_f64().unwrap_or(0.0), p["lon"].as_f64().unwrap_or(0.0), p["label"].as_str())
        })();
        if let Err(e) = r {
            eprintln!("cache_search: the saved place's notebook entry was not updated: {}", e.message);
        }
    }

    /// After `cs_place_delete`: the saved place's entry goes too.
    pub(crate) fn place_deleted(&self, key: &str) {
        if self.notebook.is_none() {
            return;
        }
        let r = (|| -> Result<()> {
            let id = self.saved_id()?;
            let books = self.nb()?.places_books().map_err(nb_err)?;
            if let Some(p) = books.iter().find(|b| b.id == id).and_then(|b| b.points.iter().find(|p| p.key.as_deref() == Some(key))) {
                self.nb_call("entry_delete", &json!({"id": p.entry_id}))?;
            }
            Ok(())
        })();
        if let Err(e) = r {
            eprintln!("cache_search: the saved place's notebook entry was not deleted: {}", e.message);
        }
    }

    /// Every Places notebook but the saved places' as a map layer.
    fn sync_layers(&self) -> Result<()> {
        let (Some(map), Some(nb)) = (self.map_data.as_deref(), self.notebook.as_ref()) else { return Ok(()) };
        let books = nb.places_books().map_err(nb_err)?;
        let layers: Vec<NotebookLayer> = books
            .into_iter()
            .filter(|b| !b.saved)
            .map(|b| NotebookLayer {
                notebook_id: b.id,
                name: b.name,
                private: b.private,
                visible: b.map,
                points: b
                    .points
                    .into_iter()
                    .map(|p| NotebookPoint { name: p.title.unwrap_or_default(), notes: p.body.unwrap_or_default(), lat: p.lat, lon: p.lon })
                    .collect(),
            })
            .collect();
        map.sync_notebook_layers(&layers).map_err(user_err)
    }

    /// `import`: `{"path", "notebook_id"?, "name"?, "now"?}`. Reads a map layer file into a Places notebook (`notebook_id`, else a
    /// new one named `name`, else the file's own name for the layer, else the file name; " 2", " 3" when taken): each point
    /// becomes an entry (its name the title, its notes the text), lines and areas stay with the notebook's map layer.
    /// `now` is the entries' "When" (local ISO 8601 with offset; default now in UTC). Returns
    /// `{"notebook", "places", "lines", "areas", "skipped"}` (skipped: lines and areas a notebook without a layer cannot keep).
    fn import(&self, args: &Value) -> Result<Value> {
        for k in args.as_object().into_iter().flat_map(|o| o.keys()) {
            if !["path", "notebook_id", "name", "now"].contains(&k.as_str()) {
                return Err(Error::bad_json(format!("{k}: not allowed")));
            }
        }
        let path = args.get("path").and_then(Value::as_str).ok_or_else(|| Error::bad_json("path is missing"))?;
        let file = std::path::Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| path.to_string());
        let meta = std::fs::metadata(path).map_err(|e| Error::io(format!("{path}: {e}")))?;
        if meta.len() > mapdata::MAX_FILE_BYTES {
            return Err(Error::bad_json(format!("{file}: larger than {} MB", mapdata::MAX_FILE_BYTES >> 20)));
        }
        let bytes = std::fs::read(path).map_err(|e| Error::io(format!("{path}: {e}")))?;
        let kind = mapdata::file_kind(&file, &bytes)
            .filter(|k| *k != mapdata::FileKind::ChirpCsv)
            .ok_or_else(|| Error::bad_json(format!("{file}: places come from a .kml, .kmz, .gpx, .geojson or .json file")))?;
        let parsed = mapdata::parse_layer(kind, &bytes).map_err(|e| Error::bad_json(format!("{file}: {}", e.message)))?;
        let when = args.get("now").and_then(Value::as_str).map(str::to_string).unwrap_or_else(now_iso);
        let nb_id = match args.get("notebook_id").and_then(Value::as_str) {
            Some(id) => {
                let n = self.nb_call("notebook", &json!({"id": id}))?;
                if n["template"] != "places" {
                    return Err(Error::bad_json("places are imported into a Places notebook"));
                }
                id.to_string()
            }
            None => {
                let stem = std::path::Path::new(&file).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                let given = args.get("name").and_then(Value::as_str).map(mapdata::collapse).filter(|n| !n.is_empty());
                let base: String = given.or(parsed.name.clone().map(|n| mapdata::collapse(&n)).filter(|n| !n.is_empty())).unwrap_or_else(|| mapdata::collapse(&stem)).chars().take(70).collect();
                let base = if base.is_empty() { "Imported places".to_string() } else { base };
                let all = self.nb_call("notebooks", &json!({}))?;
                let taken: Vec<String> = all["notebooks"].as_array().into_iter().flatten().filter_map(|n| n["def"]["name"].as_str()).map(str::to_lowercase).collect();
                let (mut name, mut i) = (base.clone(), 2);
                while taken.contains(&name.to_lowercase()) {
                    name = format!("{base} {i}");
                    i += 1;
                }
                let def = json!({"name": name, "due_every": null, "shape": {"sort": "distance"}, "fields": []});
                let n = self.nb_call("notebook_save", &json!({"template": "places", "def": def, "private": parsed.private.unwrap_or(false)}))?;
                n["id"].as_str().unwrap_or_default().to_string()
            }
        };
        let mut places = 0;
        let mut shapes: Vec<Feature> = Vec::new();
        for f in parsed.features {
            match f.geom {
                Geom::Point(lat, lon) => {
                    let title: String = mapdata::collapse(&f.name).chars().take(200).collect();
                    let notes: String = f.notes.chars().take(100_000).collect();
                    let mut e = json!({"notebook_id": nb_id, "occurred_at": when, "place": {"lat": lat, "lon": lon}});
                    if !title.is_empty() {
                        e["title"] = json!(title);
                    }
                    if !notes.trim().is_empty() {
                        e["body"] = json!(notes);
                    }
                    self.entry_save(&e)?;
                    places += 1;
                }
                _ => shapes.push(f),
            }
        }
        self.sync_layers()?;
        let (lines, areas) = (
            shapes.iter().filter(|f| matches!(f.geom, Geom::Line(..))).count(),
            shapes.iter().filter(|f| matches!(f.geom, Geom::Area(..))).count(),
        );
        let kept = match self.map_data.as_deref() {
            Some(m) => m.add_notebook_shapes(&nb_id, &shapes).map_err(user_err)?,
            None => 0,
        };
        let notebook = self.nb_call("notebook", &json!({"id": nb_id}))?;
        Ok(json!({"notebook": notebook, "places": places, "lines": lines, "areas": areas, "skipped": shapes.len() - kept}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn utc_times() {
        assert_eq!(iso_utc(0), "1970-01-01T00:00:00Z");
        assert_eq!(iso_utc(1_793_318_400), "2026-10-30T00:00:00Z");
        assert_eq!(iso_utc(951_782_400 + 3661), "2000-02-29T01:01:01Z");
    }

    #[test]
    fn names_of_saved_places() {
        assert_eq!(place_name(Some("  Home  base "), None), "Home base");
        assert_eq!(place_name(None, Some("12 Main St")), "12 Main St");
        assert_eq!(place_name(Some(" "), None), "Place");
    }
}
