//! The core ops, JSON in and JSON out. `cache_search` exports them as `cs_shelves_detect`, `cs_shelves_append`,
//! `cs_shelves_resolve` and `cs_shelves_import`; the Dart dispatcher names them `shelvesDetect`, `shelvesAppend`,
//! `shelvesResolve` and `shelvesImport`. See cache_search.h for the signatures.

use crate::error::{Error, Result};
use crate::events::Event;
use crate::batch::find_pairs;
use crate::import::import_own;
use crate::library::{load_library, HeaderReader, LibraryInput, LibraryRef};
use crate::same::{detect_json, tuning_of, Facts};
use crate::store::{now_ms, LogWriter, LOG_DIR};
use crate::view::{build_view, write_view};
use serde_json::{json, Value};
use std::collections::BTreeSet;
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

/// `shelvesDetect`, in two forms.
///
/// Single copy: `{"copy": facts, "against": [facts], "tuning"?}` to `[{"with","how","score"}]`. Pure; reads nothing.
///
/// Batch (when the request has `"libraries"`): `{"libraries": [{"library_id","dir","packs_dir"?}], "copies"?: [copy keys to check,
/// default all], "known"?: [copy keys already detected], "tuning"?}` to `[{"copy","with","how","score"}]`. It reads the features
/// itself (each library's `copies.jsonl`, else its packs), and returns every match between a checked copy and any other visible
/// copy, checked ones included. Each unordered pair appears once with `copy` the greater key, sorted by (`copy`, `with`). A pair
/// with both copies in `known` is skipped.
pub fn detect(args: &str, read_header: HeaderReader) -> Result<String> {
    let v = parse(args)?;
    if v.get("libraries").is_some() {
        return Ok(detect_batch(&v, read_header)?.to_string());
    }
    Ok(detect_json(&v)?.to_string())
}

fn key_set(v: &Value, k: &str) -> Result<Option<BTreeSet<String>>> {
    match v.get(k) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::Array(a)) => a
            .iter()
            .map(|x| x.as_str().map(str::to_string).ok_or_else(|| Error::new(format!("\"{k}\" holds a value that is not a copy key"))))
            .collect::<Result<BTreeSet<_>>>()
            .map(Some),
        Some(_) => Err(Error::new(format!("\"{k}\" is a list of copy keys"))),
    }
}

/// The batch form of `shelvesDetect`.
pub fn detect_batch(v: &Value, read_header: HeaderReader) -> Result<Value> {
    let mut refs = libraries(v)?;
    refs.sort_by(|a, b| a.library_id.cmp(&b.library_id));
    let checked = key_set(v, "copies")?;
    let known = key_set(v, "known")?.unwrap_or_default();
    let mut all: Vec<Facts> = Vec::new();
    for l in &refs {
        all.extend(load_library(l, read_header)?.copies.iter().map(|c| c.detect_facts()));
    }
    let pairs = find_pairs(&all, checked.as_ref(), &known, &tuning_of(v)?);
    Ok(Value::Array(pairs.into_iter().map(|p| json!({"copy": p.copy, "with": p.with, "how": p.how.as_str(), "score": p.score})).collect()))
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

/// `shelvesResolve`: `{"dir", "libraries": [{"library_id", "dir", "packs_dir"?}]}` to the view (view.rs). The view is also written to
/// `<dir>/.local/view.json`, atomically (a temporary file in the same folder, flushed, renamed over the name), before it is
/// returned; a write that fails fails the call.
pub fn resolve_view(args: &str, read_header: HeaderReader) -> Result<String> {
    let v = parse(args)?;
    let dir = Path::new(text(&v, "dir")?);
    let view = build_view(dir, &libraries(&v)?, read_header)?;
    write_view(dir, &view)?;
    Ok(view.to_string())
}

/// `shelvesImport`: `{"dir", "dev", "libraries": [...]}` to `{"events", "files": [...]}` (import.rs).
pub fn import(args: &str, read_header: HeaderReader) -> Result<String> {
    let v = parse(args)?;
    let loaded = libraries(&v)?.into_iter().map(|l| load_library(&l, read_header).map(|i: LibraryInput| (l, i))).collect::<Result<Vec<_>>>()?;
    Ok(import_own(Path::new(text(&v, "dir")?), text(&v, "dev")?, &loaded)?.to_json().to_string())
}
