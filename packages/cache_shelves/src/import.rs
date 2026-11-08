//! The import of a device's OWN old library-log events into its Bookshelves log, once.
//!
//! On first run a device reads `<library>/log/<own id>.jsonl` of every library it holds, maps each event's `doc` to the copy key
//! through that library's packs (`original_blake3`, else the `doc_id`), appends the events to `bookshelves/log/<own id>.jsonl`
//! with `loc` set to `<library_id>/<doc_id>`, and records the file and its size in `bookshelves/.local/migrated.json`. Other
//! devices' library logs are ignored (they import their own), and so is the seed log. After the import, library logs are not
//! written again.

use crate::error::{Error, Result};
use crate::events::{valid_device_id, Event};
use crate::library::{LibraryInput, LibraryRef};
use crate::store::{parse_legacy_log, parse_log, write_atomic, LogWriter, LOCAL_DIR, LOG_DIR, LOG_EXT};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::path::Path;

pub const MIGRATED_FILE: &str = "migrated.json";

/// One library log looked at.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportedFile {
    pub library_id: String,
    pub file: String,
    pub size: u64,
    /// Events written to the Bookshelves log.
    pub events: usize,
    /// Events whose `doc` has no pack in the library (not imported).
    pub unmapped: usize,
    /// The file was recorded as imported before, and was left alone.
    pub already: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ImportReport {
    pub files: Vec<ImportedFile>,
    pub events: usize,
}

impl ImportReport {
    pub fn to_json(&self) -> Value {
        json!({
            "events": self.events,
            "files": self.files.iter().map(|f| json!({"library_id": f.library_id, "file": f.file, "size": f.size, "events": f.events, "unmapped": f.unmapped, "already": f.already})).collect::<Vec<_>>(),
        })
    }
}

/// Imports `dev`'s own events from the libraries (given with their loaded packs, in any order).
pub fn import_own(bookshelves_dir: &Path, dev: &str, libs: &[(LibraryRef, LibraryInput)]) -> Result<ImportReport> {
    if !valid_device_id(dev) {
        return Err(Error::new(format!("invalid device id {dev:?}")));
    }
    let migrated_path = bookshelves_dir.join(LOCAL_DIR).join(MIGRATED_FILE);
    let mut migrated: Map<String, Value> = match std::fs::read(&migrated_path) {
        Ok(b) => serde_json::from_slice::<Value>(&b).ok().and_then(|v| v.get("files").and_then(Value::as_object).cloned()).unwrap_or_default(),
        Err(_) => Map::new(),
    };
    // events already in this device's log (an earlier import that did not get to write migrated.json) are not written again
    let own_path = bookshelves_dir.join(LOG_DIR).join(format!("{dev}.{LOG_EXT}"));
    let present: Vec<Event> = match std::fs::read(&own_path) {
        Ok(b) => parse_log(&String::from_utf8_lossy(&b)).0,
        Err(_) => Vec::new(),
    };
    let mut order: Vec<&(LibraryRef, LibraryInput)> = libs.iter().collect();
    order.sort_by(|a, b| a.0.library_id.cmp(&b.0.library_id));
    let mut report = ImportReport::default();
    let mut to_write: Vec<Event> = Vec::new();
    let mut fresh: Vec<(String, u64, usize, usize)> = Vec::new();
    for (lref, lib) in order {
        let file = format!("{dev}.{LOG_EXT}");
        let path = lref.dir.join(LOG_DIR).join(&file);
        let bytes = match std::fs::read(&path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Err(e) => return Err(Error::ctx(&format!("reading {}", path.display()), e)),
        };
        let size = bytes.len() as u64;
        let record_key = format!("{}/{file}", lref.library_id);
        if migrated.contains_key(&record_key) {
            report.files.push(ImportedFile { library_id: lref.library_id.clone(), file, size, events: 0, unmapped: 0, already: true });
            continue;
        }
        let map: BTreeMap<&str, &str> = lib.copies.iter().map(|p| (p.doc_id.as_str(), p.copy.as_str())).collect();
        let (events, _) = parse_legacy_log(&String::from_utf8_lossy(&bytes));
        let (mut kept, mut unmapped) = (0, 0);
        for mut e in events {
            if e.dev != dev {
                continue;
            }
            if let Some(doc) = e.kind.copy().map(str::to_string) {
                let Some(copy) = map.get(doc.as_str()) else {
                    unmapped += 1;
                    continue;
                };
                if let Some(c) = e.kind.copy_mut() {
                    *c = (*copy).to_string();
                }
                e.loc = Some(format!("{}/{doc}", lref.library_id));
            }
            if present.contains(&e) || to_write.contains(&e) {
                continue;
            }
            kept += 1;
            to_write.push(e);
        }
        // a file with unmapped events stays eligible: a later import maps them once their pack is here
        if unmapped == 0 {
            fresh.push((record_key, size, kept, unmapped));
        }
        report.files.push(ImportedFile { library_id: lref.library_id.clone(), file, size, events: kept, unmapped, already: false });
    }
    // oldest first; ties keep the library and line order
    to_write.sort_by_key(|e| e.at);
    let events = to_write;
    if !events.is_empty() {
        LogWriter::open(&bookshelves_dir.join(LOG_DIR), dev)?.append_unclamped(&events)?;
    }
    report.events = events.len();
    if !fresh.is_empty() {
        for (key, size, kept, unmapped) in fresh {
            migrated.insert(key, json!({"size": size, "events": kept, "unmapped": unmapped}));
        }
        let rec = serde_json::to_string_pretty(&json!({"format": 1, "files": Value::Object(migrated)})).map_err(|e| Error::ctx("migrated.json", e))?;
        write_atomic(&migrated_path, format!("{rec}\n").as_bytes())?;
    }
    Ok(report)
}
