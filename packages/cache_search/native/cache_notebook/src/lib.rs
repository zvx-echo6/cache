//! Notebooks (docs: specs/notebook.md, and the project decision of 2026-10-30 that made them plural): the user keeps several
//! notebooks in one notebook.sqlite, each made of one kind of entry. An entry can have a title, text, a date, a place, photos,
//! attached files and fields. A notebook's template (`journal`, `log`, `notes`, `places`) only sets its starting shape and how
//! the app lists it; its definition is data (a name, fields of six types, how often it is due), and its entries hold values by
//! the field's stable id (`fid`), so a label can be renamed without touching them. A Journal notebook is made the first time
//! the database is opened. Photos and attached files are files the app writes under `media_dir` (`photos/`, `thumbs/`,
//! `files/`); the store keeps their ids and deletes the files with what they belong to.
//!
//! Private (project decision, 2026-10-29) is a stored flag: it decides what sharing, sync and export leave out by default.
//! Nothing here encrypts or hides it; private rows are searched like the rest.
//!
//! Every call is `call(op, args_json)` and answers JSON; the ops are listed in `cache_search.h` under `cs_notebook`.

mod def;
mod store;
mod time;

pub use def::{validate_due_every, NotebookDef};
pub use store::{PlacePoint, PlacesBook};
use serde::Deserialize;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// An error with one of the core's stable codes (`bad_json`, `not_found`, `io`).
#[derive(Debug, Clone)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub(crate) fn bad(m: impl Into<String>) -> Error {
        Error { code: "bad_json", message: m.into() }
    }
    pub(crate) fn not_found(m: impl Into<String>) -> Error {
        Error { code: "not_found", message: m.into() }
    }
}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error { code: "io", message: format!("sqlite: {e}") }
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::bad(e.to_string())
    }
}

/// The `notebook` section of the `cs_open` config.
#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NotebookCfg {
    /// `.../notebook/notebook.sqlite`
    pub db_path: String,
    /// `.../notebook`: photos in `photos/<id>.jpg`, thumbnails in `thumbs/<id>.jpg`, attached files in `files/<id>`.
    pub media_dir: String,
}

/// One notebook.sqlite. The database is opened on the first call, so a damaged or unreadable file is an error of that call
/// (the app shows "Notebook could not open" with Try again) and not of `cs_open`.
pub struct Notebook {
    cfg: NotebookCfg,
    conn: Mutex<Option<rusqlite::Connection>>,
}

impl Notebook {
    pub fn new(cfg: NotebookCfg) -> Notebook {
        Notebook { cfg, conn: Mutex::new(None) }
    }

    pub fn cfg(&self) -> &NotebookCfg {
        &self.cfg
    }

    fn media_dir(&self) -> PathBuf {
        PathBuf::from(&self.cfg.media_dir)
    }

    /// Runs `f` on the open database (opening it the first time).
    fn with_conn<T>(&self, f: impl FnOnce(&mut rusqlite::Connection) -> Result<T>) -> Result<T> {
        let mut guard = self.conn.lock().unwrap_or_else(|e| e.into_inner());
        if guard.is_none() {
            *guard = Some(store::open(Path::new(&self.cfg.db_path))?);
        }
        f(guard.as_mut().expect("opened above"))
    }

    /// The notebooks made from the Places template, oldest first, each with its entries that have a place (oldest first):
    /// what the core keeps in step with the saved places (the saved-places notebook) and the map layers (the others).
    pub fn places_books(&self) -> Result<Vec<PlacesBook>> {
        self.with_conn(|c| store::places_books(c))
    }

    /// The saved-places notebook's id, made the first time (see the `saved_places` op).
    pub fn saved_places_id(&self) -> Result<String> {
        self.with_conn(|c| {
            let n = store::saved_places(c, &serde_json::json!({}))?;
            Ok(n["id"].as_str().unwrap_or_default().to_string())
        })
    }

    /// Runs `op` with `args_json` (an object; empty or absent = `{}`).
    pub fn call(&self, op: &str, args_json: Option<&str>) -> Result<String> {
        let args: serde_json::Value = match args_json.map(str::trim).filter(|a| !a.is_empty()) {
            Some(a) => serde_json::from_str(a)?,
            None => serde_json::json!({}),
        };
        if !args.is_object() {
            return Err(Error::bad("args must be a JSON object"));
        }
        let media = self.media_dir();
        let out = self.with_conn(|c| Ok(match op {
            "notebooks" => store::notebooks(c, &args)?,
            "notebook" => store::notebook_get(c, &args)?,
            "notebook_save" => store::notebook_save(c, &args)?,
            "notebook_delete" => store::notebook_delete(c, &media, &args)?,
            "entries" => store::entries(c, &args)?,
            "entry" => store::entry_get(c, &args)?,
            "entry_save" => store::entry_save(c, &media, &args)?,
            "entry_delete" => store::entry_delete(c, &media, &args)?,
            "search" => store::search(c, &args)?,
            "pins" => store::pins(c, &args)?,
            "saved_places" => store::saved_places(c, &args)?,
            _ => return Err(Error { code: "unsupported", message: format!("unknown notebook op {op:?}") }),
        }))?;
        Ok(out.to_string())
    }
}

#[cfg(test)]
mod tests;
