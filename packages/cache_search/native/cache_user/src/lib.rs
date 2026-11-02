//! Saved places, stored in user.sqlite. Tools and live data resolve a place name against these first. The user's map layers
//! and imported repeater lists live in the same file (`mapdata`).

pub mod mapdata;

use cache_tool::{SavedPlace, SavedPlaces};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};

/// An error with one of the core's stable codes (`bad_json`, `not_found`, `io`).
#[derive(Debug, Clone)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    fn bad(m: impl Into<String>) -> Error {
        Error { code: "bad_json", message: m.into() }
    }
}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error { code: "io", message: format!("sqlite: {e}") }
    }
}

/// A place key is used inside addresses (`live:<source>/<place-key>/<item-key>`), so it has no `/`.
pub fn valid_key(k: &str) -> bool {
    !k.is_empty() && k.len() <= 100 && k.chars().all(|c| c.is_ascii_alphanumeric() || "_-.:,+".contains(c))
}

pub fn check_coords(lat: f64, lon: f64) -> Result<()> {
    if !(lat.is_finite() && lon.is_finite() && (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon)) {
        return Err(Error::bad(format!("lat/lon out of range: {lat}, {lon}")));
    }
    Ok(())
}

/// The saved places of one user.sqlite.
pub struct UserStore {
    path: PathBuf,
}

#[derive(Serialize)]
struct PlaceOut<'a> {
    key: &'a str,
    name: &'a str,
    lat: f64,
    lon: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    label: &'a Option<String>,
}

fn out_json(p: &SavedPlace) -> serde_json::Value {
    serde_json::to_value(PlaceOut { key: &p.key, name: &p.name, lat: p.lat, lon: p.lon, label: &p.label }).expect("place json")
}

fn slug(name: &str) -> String {
    let mut s = String::new();
    for ch in name.trim().chars() {
        if ch.is_ascii_alphanumeric() {
            s.push(ch.to_ascii_lowercase());
        } else if !s.ends_with('-') && !s.is_empty() {
            s.push('-');
        }
    }
    let s = s.trim_end_matches('-').to_string();
    if s.is_empty() { "place".into() } else { s.chars().take(60).collect() }
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

impl UserStore {
    pub fn new(db_path: impl AsRef<Path>) -> UserStore {
        UserStore { path: db_path.as_ref().to_path_buf() }
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
            "CREATE TABLE IF NOT EXISTS places(
                key TEXT PRIMARY KEY, name TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, label TEXT,
                created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL);",
        )?;
        Ok(c)
    }

    pub fn all(&self) -> Result<Vec<SavedPlace>> {
        let c = self.db()?;
        let mut st = c.prepare("SELECT key,name,lat,lon,label FROM places ORDER BY created_at, rowid")?;
        let rows = st.query_map([], |r| Ok(SavedPlace { key: r.get(0)?, name: r.get(1)?, lat: r.get(2)?, lon: r.get(3)?, label: r.get(4)? }))?;
        Ok(rows.collect::<std::result::Result<Vec<_>, _>>()?)
    }

    /// `cs_places_list`: `{"places":[{"key","name","lat","lon","label"?}]}`, oldest first.
    pub fn list_json(&self) -> Result<String> {
        let v: Vec<_> = self.all()?.iter().map(out_json).collect();
        Ok(serde_json::json!({"places": v}).to_string())
    }

    /// `cs_place_save`: `{key?, name, lat, lon, label?}`. Inserts, or updates when the key exists. Without a key one is
    /// made from the name (`home`, `home-2`, ...). Returns the saved place.
    pub fn save(&self, json: &str) -> Result<String> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct In {
            #[serde(default)]
            key: Option<String>,
            name: String,
            lat: f64,
            lon: f64,
            #[serde(default)]
            label: Option<String>,
        }
        let p: In = serde_json::from_str(json).map_err(|e| Error::bad(format!("place_json: {e}")))?;
        check_coords(p.lat, p.lon)?;
        let name = p.name.split_whitespace().collect::<Vec<_>>().join(" ");
        if name.is_empty() || name.chars().count() > 200 {
            return Err(Error::bad("name must be 1 to 200 characters"));
        }
        let label = p.label.map(|l| l.split_whitespace().collect::<Vec<_>>().join(" ")).filter(|l| !l.is_empty());
        let c = self.db()?;
        let key = match p.key {
            Some(k) => {
                if !valid_key(&k) {
                    return Err(Error::bad(format!("invalid key {k:?}: letters, digits and _ - . : , + only")));
                }
                k
            }
            None => {
                let base = slug(&name);
                let (mut k, mut n) = (base.clone(), 2);
                while c.query_row("SELECT 1 FROM places WHERE key=?1", [&k], |_| Ok(())).optional()?.is_some() {
                    k = format!("{base}-{n}");
                    n += 1;
                }
                k
            }
        };
        c.execute(
            "INSERT INTO places(key,name,lat,lon,label,created_at,updated_at) VALUES(?1,?2,?3,?4,?5,?6,?6)
             ON CONFLICT(key) DO UPDATE SET name=?2, lat=?3, lon=?4, label=?5, updated_at=?6",
            params![key, name, p.lat, p.lon, label, now()],
        )?;
        Ok(out_json(&SavedPlace { key, name, lat: p.lat, lon: p.lon, label }).to_string())
    }

    /// `cs_place_delete`: `{"deleted":"<key>"}`, or `not_found`.
    pub fn delete(&self, key: &str) -> Result<String> {
        let n = self.db()?.execute("DELETE FROM places WHERE key=?1", [key])?;
        if n == 0 {
            return Err(Error { code: "not_found", message: format!("no saved place with key {key:?}") });
        }
        Ok(serde_json::json!({"deleted": key}).to_string())
    }
}

impl SavedPlaces for UserStore {
    /// By key first, then by name (case-insensitive, whitespace trimmed).
    fn resolve(&self, name: &str) -> Option<SavedPlace> {
        let t = name.trim();
        let all = self.all().ok()?;
        if let Some(p) = all.iter().find(|p| p.key == t) {
            return Some(p.clone());
        }
        let lower = t.to_lowercase();
        all.into_iter().find(|p| p.name.to_lowercase() == lower)
    }

    fn list(&self) -> Vec<SavedPlace> {
        self.all().unwrap_or_default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store(name: &str) -> (UserStore, PathBuf) {
        let p = std::env::temp_dir().join(format!("cache-user-test-{}-{}.sqlite", std::process::id(), name));
        let _ = std::fs::remove_file(&p);
        (UserStore::new(&p), p)
    }

    #[test]
    fn slugs_and_keys() {
        assert_eq!(slug("Home"), "home");
        assert_eq!(slug("  Mom & Dad's  cabin "), "mom-dad-s-cabin");
        assert_eq!(slug("!!!"), "place");
        assert!(valid_key("at:42.54,-113.79"));
        assert!(!valid_key("a/b"));
        assert!(!valid_key(""));
    }

    #[test]
    fn save_list_resolve_delete() {
        let (s, p) = store("crud");
        assert_eq!(s.list_json().unwrap(), r#"{"places":[]}"#);
        let a: serde_json::Value = serde_json::from_str(&s.save(r#"{"name":"Home","lat":42.536,"lon":-113.792}"#).unwrap()).unwrap();
        assert_eq!(a["key"], "home");
        let b: serde_json::Value = serde_json::from_str(&s.save(r#"{"name":"Home","lat":1,"lon":2,"label":"cabin"}"#).unwrap()).unwrap();
        assert_eq!(b["key"], "home-2");
        assert_eq!(b["label"], "cabin");
        // update by key
        s.save(r#"{"key":"home","name":"Home base","lat":43,"lon":-114}"#).unwrap();
        let l = s.all().unwrap();
        assert_eq!(l.len(), 2);
        assert_eq!((l[0].name.as_str(), l[0].lat), ("Home base", 43.0));
        assert_eq!(s.resolve("home").unwrap().key, "home");
        assert_eq!(s.resolve("  HOME BASE ").unwrap().key, "home");
        assert!(s.resolve("nowhere").is_none());
        assert_eq!(s.list().len(), 2);
        assert_eq!(s.delete("home").unwrap(), r#"{"deleted":"home"}"#);
        assert_eq!(s.delete("home").unwrap_err().code, "not_found");
        // order of fields in the output
        assert_eq!(b.as_object().unwrap().keys().collect::<Vec<_>>(), ["key", "name", "lat", "lon", "label"]);
        let _ = std::fs::remove_file(p);
    }

    #[test]
    fn bad_input() {
        let (s, p) = store("bad");
        for bad in [r#"{"name":"","lat":1,"lon":2}"#, r#"{"name":"x","lat":91,"lon":2}"#, r#"{"name":"x","lat":1}"#, r#"{"name":"x","lat":1,"lon":2,"key":"a/b"}"#, r#"{"name":"x","lat":1,"lon":2,"zzz":1}"#, "{"] {
            assert_eq!(s.save(bad).unwrap_err().code, "bad_json", "{bad}");
        }
        let _ = std::fs::remove_file(p);
    }
}
