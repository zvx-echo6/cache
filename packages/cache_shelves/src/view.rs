//! The view: `<bookshelves>/.local/view.json`, format 1. Deterministic JSON bytes: the same events and libraries always give the
//! same bytes (no clock, keys in a fixed order, books in `id` order). Never synced, never part of a search payload.
//!
//! ```json
//! {
//!   "format": 1,
//!   "built_from": {"libraries": {"recon": {"packs": 2, "unreadable": 0}}, "logs": {"phone-7.jsonl": 812}},
//!   "books": {
//!     "<id: the smallest copy key>": {
//!       "title": "Wilderness Medicine", "title_from": "log" | "seed" | "pack",
//!       "aka": ["Other pack title"],
//!       "reading": "<copy key>",
//!       "copies": [{"copy": "...", "locs": ["recon/wm"], "available": true, "title": "pack title" | null,
//!                   "own_call": {"div","seq","suffix","text"} | null,
//!                   "locations": [{"dev","folder_id","relpath","version","source_blake3"}]}],
//!       "shelf": "610" | null, "shelved": true, "by": "auto" | "user" | null,
//!       "call": {"div": "610", "seq": 1, "suffix": 0, "text": "CDS 610-001"} | null,
//!       "removed": false,
//!       "author": "Ann" | null, "edition": "7th edition" | null, "year": 2018 | null,
//!       "suggested": {"div": "610", "label": "Medicine" | null, "from": "seed" | "pack", "filed": true | false,
//!                     "suggestions": [{"div", "label", "score"}]  (only when the pack has them)} | null
//!     }
//!   },
//!   "retired": {"610": [5]},
//!   "next": {"610": 6},
//!   "folders": [{"dev","folder_id","label","mode"}]
//! }
//! ```

use crate::error::{Error, Result};
use crate::library::{load_library, HeaderReader, LibraryInput, LibraryRef};
use crate::resolve::{resolve, Call, Resolved};
use crate::store::{read_logs, write_atomic, LOCAL_DIR, LOG_DIR};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};

pub const VIEW_FILE: &str = "view.json";
pub const VIEW_FORMAT: u32 = 1;

fn call_json(c: &Option<Call>) -> Value {
    match c {
        Some(c) => json!({"div": c.div, "seq": c.seq, "suffix": c.suffix, "text": c.text}),
        None => Value::Null,
    }
}

/// The view as JSON. `logs` are the log files it was resolved from (name and size).
pub fn view_value(r: &Resolved, libs: &[LibraryInput], logs: &[(String, u64)]) -> Value {
    let mut books = Map::new();
    for b in &r.books {
        let copies: Vec<Value> = b
            .copies
            .iter()
            .map(|c| {
                json!({
                    "copy": c.copy,
                    "locs": c.locs,
                    "available": c.available(),
                    "title": c.title,
                    "own_call": call_json(&c.own_call),
                    "locations": c.locations.iter().map(|l| json!({"dev": l.dev, "folder_id": l.folder_id, "relpath": l.relpath, "version": l.version, "source_blake3": l.source_blake3})).collect::<Vec<_>>(),
                })
            })
            .collect();
        books.insert(
            b.id.clone(),
            json!({
                "title": b.title,
                "title_from": b.title_from.as_str(),
                "aka": b.aka,
                "reading": b.reading,
                "copies": copies,
                "shelf": b.shelf,
                "shelved": b.shelved,
                "by": b.by.map(|by| by.as_str()),
                "call": call_json(&b.call),
                "removed": b.removed,
                "author": b.author,
                "edition": b.edition,
                "year": b.year,
                "suggested": b.suggested.as_ref().map(|s| {
                    let mut o = json!({"div": s.div, "label": s.label, "from": s.from, "filed": s.filed});
                    if !s.top.is_empty() {
                        o["suggestions"] = json!(s.top.iter().map(|x| json!({"div": x.div, "label": x.label, "score": x.score})).collect::<Vec<_>>());
                    }
                    o
                }),
            }),
        );
    }
    let mut retired = Map::new();
    for (div, seqs) in &r.retired {
        retired.insert(div.clone(), json!(seqs.iter().collect::<Vec<_>>()));
    }
    let mut next = Map::new();
    for (div, n) in &r.next {
        next.insert(div.clone(), json!(n));
    }
    let mut libraries = Map::new();
    let mut sorted: Vec<&LibraryInput> = libs.iter().collect();
    sorted.sort_by(|a, b| a.library_id.cmp(&b.library_id));
    for l in sorted {
        libraries.insert(l.library_id.clone(), json!({"packs": l.copies.len(), "unreadable": l.unreadable}));
    }
    let mut files = Map::new();
    for (name, size) in logs {
        files.insert(name.clone(), json!(size));
    }
    json!({
        "format": VIEW_FORMAT,
        "built_from": {"libraries": Value::Object(libraries), "logs": Value::Object(files)},
        "books": Value::Object(books),
        "retired": Value::Object(retired),
        "next": Value::Object(next),
        "folders": r.folders.iter().map(|f| json!({"dev": f.dev, "folder_id": f.folder_id, "label": f.label, "mode": f.mode.as_str()})).collect::<Vec<_>>(),
    })
}

/// The view's bytes: pretty JSON and a final line break.
pub fn view_bytes(v: &Value) -> Result<Vec<u8>> {
    let mut s = serde_json::to_string_pretty(v).map_err(|e| Error::ctx("view.json", e))?;
    s.push('\n');
    Ok(s.into_bytes())
}

/// Writes `<bookshelves>/.local/view.json` atomically.
pub fn write_view(bookshelves_dir: &Path, v: &Value) -> Result<PathBuf> {
    let path = bookshelves_dir.join(LOCAL_DIR).join(VIEW_FILE);
    write_atomic(&path, &view_bytes(v)?)?;
    Ok(path)
}

/// Reads the logs in `<bookshelves>/log/` and the libraries, and resolves them to the view.
pub fn build_view(bookshelves_dir: &Path, libraries: &[LibraryRef], read_header: HeaderReader) -> Result<Value> {
    let logs = read_logs(&bookshelves_dir.join(LOG_DIR))?;
    let libs = libraries.iter().map(|l| load_library(l, read_header)).collect::<Result<Vec<_>>>()?;
    let resolved = resolve(&logs.events, &libs);
    Ok(view_value(&resolved, &libs, &logs.files))
}
