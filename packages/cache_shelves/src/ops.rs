//! The core ops, JSON in and JSON out. `cache_search` exports them as `cs_shelves_detect`, `cs_shelves_append`,
//! `cs_shelves_resolve` and `cs_shelves_import`; the Dart dispatcher names them `shelvesDetect`, `shelvesAppend`,
//! `shelvesResolve` and `shelvesImport`. See cache_search.h for the signatures.

use crate::error::{Error, Result};
use crate::events::Event;
use crate::import::import_own;
use crate::library::{load_library, HeaderReader, LibraryInput, LibraryRef};
use crate::same::detect_json;
use crate::store::{now_ms, LogWriter, LOG_DIR};
use crate::view::build_view;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

fn parse(args: &str) -> Result<Value> {
    serde_json::from_str(args).map_err(|e| Error::ctx("the request is not JSON", e))
}

fn text<'a>(v: &'a Value, k: &str) -> Result<&'a str> {
    v.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).ok_or_else(|| Error::new(format!("\"{k}\" is missing")))
}

fn libraries(v: &Value) -> Result<Vec<LibraryRef>> {
    let list = v.get("libraries").and_then(Value::as_array).ok_or_else(|| Error::new("\"libraries\" is missing"))?;
    list.iter()
        .map(|l| {
            Ok(LibraryRef {
                library_id: text(l, "library_id")?.to_string(),
                dir: PathBuf::from(text(l, "dir")?),
                packs_dir: l.get("packs_dir").and_then(Value::as_str).filter(|p| !p.is_empty()).map(PathBuf::from),
            })
        })
        .collect()
}

/// `shelvesDetect`: `{"copy": facts, "against": [facts], "tuning"?}` to `[{"with","how","score"}]`.
pub fn detect(args: &str) -> Result<String> {
    Ok(detect_json(&parse(args)?)?.to_string())
}

/// `shelvesAppend`: `{"dir": <bookshelves folder>, "dev", "events": [event]}` to `{"written": n, "last_at": ms}`. An event is
/// a log line's object; `v`, `at` and `dev` may be left out (`at` is then now, and `dev` is the request's). The writer holds a
/// clock set back at the device's last `at`.
pub fn append(args: &str) -> Result<String> {
    let v = parse(args)?;
    let (dir, dev) = (text(&v, "dir")?, text(&v, "dev")?);
    let list = v.get("events").and_then(Value::as_array).ok_or_else(|| Error::new("\"events\" is missing"))?;
    let now = now_ms();
    let mut events = Vec::with_capacity(list.len());
    for (i, e) in list.iter().enumerate() {
        let mut o = e.as_object().cloned().ok_or_else(|| Error::new(format!("event {i} is not an object")))?;
        o.entry("v").or_insert(json!(1));
        o.entry("at").or_insert(json!(now));
        o.entry("dev").or_insert(json!(dev));
        events.push(Event::from_value(&Value::Object(o)).ok_or_else(|| Error::new(format!("event {i} is not a Bookshelves event")))?);
    }
    let written = LogWriter::open(&Path::new(dir).join(LOG_DIR), dev)?.append(&events)?;
    Ok(json!({"written": written.len(), "last_at": written.last().map(|e| e.at)}).to_string())
}

/// `shelvesResolve`: `{"dir", "libraries": [{"library_id", "dir", "packs_dir"?}]}` to the view (view.rs).
pub fn resolve_view(args: &str, read_header: HeaderReader) -> Result<String> {
    let v = parse(args)?;
    let view = build_view(Path::new(text(&v, "dir")?), &libraries(&v)?, read_header)?;
    Ok(view.to_string())
}

/// `shelvesImport`: `{"dir", "dev", "libraries": [...]}` to `{"events", "files": [...]}` (import.rs).
pub fn import(args: &str, read_header: HeaderReader) -> Result<String> {
    let v = parse(args)?;
    let loaded = libraries(&v)?.into_iter().map(|l| load_library(&l, read_header).map(|i: LibraryInput| (l, i))).collect::<Result<Vec<_>>>()?;
    Ok(import_own(Path::new(text(&v, "dir")?), text(&v, "dev")?, &loaded)?.to_json().to_string())
}
