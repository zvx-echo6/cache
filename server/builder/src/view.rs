//! The local view: `<library>/.local/docs.json`, format 2. See LIBRARY-LOG.md.
//!
//! It is rebuilt from the packs (the facts) and all the logs (the changes), never synced, and never part of a search payload.
//! The same packs and logs always give the same bytes.

use crate::compress::CompressionOutcome;
use crate::error::{Error, Result};
use crate::library::list_packs;
use crate::log::{read_logs, resolve, LogSet, Resolved, LOG_DIR};
use crate::pack::{read_header, Header, OcrInfo, Suggested};
use serde_json::{json, Map, Value};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The local folder, at the library root. It is never synced (a name starting with a dot).
pub const LOCAL_DIR: &str = ".local";
pub const VIEW_FILE: &str = "docs.json";
pub const VIEW_FORMAT: u32 = 2;

/// What a pack says about a book (revision 4 `book`; revision 2 and 3 packs are mapped), plus what a rebuild changed.
#[derive(Debug, Clone, PartialEq)]
pub struct BookFacts {
    /// The pack's title.
    pub title: String,
    /// The title before it was replaced, when it was.
    pub source_title: Option<String>,
    /// A title a rebuild's titles file gave. The seed log records it as a `title` event, so the view can be made again.
    pub title_override: Option<String>,
    pub suggested: Option<Suggested>,
    pub compression: Option<CompressionOutcome>,
    pub ocr: Option<OcrInfo>,
}

impl BookFacts {
    pub fn new(title: &str, suggested: Option<Suggested>) -> BookFacts {
        BookFacts { title: title.to_string(), source_title: None, title_override: None, suggested, compression: None, ocr: None }
    }

    pub fn from_header(h: &Header) -> BookFacts {
        let b = h.book.as_ref();
        BookFacts {
            title: h.book_title().to_string(),
            source_title: b.and_then(|b| b.source_title.clone()),
            title_override: None,
            suggested: h.suggested(),
            compression: b.and_then(|b| b.compression.clone()),
            ocr: b.and_then(|b| b.ocr.clone()),
        }
    }

    /// The title the library uses before any `title` event: the override, else the pack's.
    pub fn effective_title(&self) -> &str {
        self.title_override.as_deref().unwrap_or(&self.title)
    }
}

fn opt<T: serde::Serialize>(v: &Option<T>) -> Value {
    v.as_ref().and_then(|x| serde_json::to_value(x).ok()).unwrap_or(Value::Null)
}

/// The view as JSON. `facts` has one entry per book of the library; `files` are the logs it was resolved from (name and size).
pub fn view_value(facts: &BTreeMap<String, BookFacts>, resolved: &Resolved, files: &[(String, u64)]) -> Value {
    let mut docs = Map::new();
    for (id, f) in facts {
        let state = resolved.doc(id).cloned().unwrap_or_default();
        let call = match &state.call {
            Some(c) => json!({"div": c.div, "seq": c.seq, "suffix": c.suffix, "text": c.text}),
            None => Value::Null,
        };
        docs.insert(
            id.clone(),
            json!({
                "title": state.title.clone().unwrap_or_else(|| f.effective_title().to_string()),
                "source_title": f.source_title,
                "shelf": state.shelf,
                "call": call,
                "suggested": opt(&f.suggested),
                "removed": state.removed,
                "compression": opt(&f.compression),
                "ocr": opt(&f.ocr),
            }),
        );
    }
    let mut retired = Map::new();
    for (div, seqs) in &resolved.retired {
        retired.insert(div.clone(), json!(seqs.iter().collect::<Vec<_>>()));
    }
    let mut logs = Map::new();
    for (name, size) in files {
        logs.insert(name.clone(), json!(size));
    }
    json!({
        "format": VIEW_FORMAT,
        "built_from": {"packs": facts.len(), "logs": Value::Object(logs)},
        "docs": Value::Object(docs),
        "retired": Value::Object(retired),
    })
}

/// The view's bytes: pretty JSON and a final line break.
pub fn view_bytes(v: &Value) -> Result<Vec<u8>> {
    let mut s = serde_json::to_string_pretty(v).map_err(|e| Error::ctx("docs.json", e))?;
    s.push('\n');
    Ok(s.into_bytes())
}

/// Writes `<library>/.local/docs.json` atomically: a temporary file in the same folder, flushed to disk, then renamed over the
/// name, so a reader sees the old view or the new one.
pub fn write_view(library_dir: &Path, v: &Value) -> Result<PathBuf> {
    let dir = library_dir.join(LOCAL_DIR);
    std::fs::create_dir_all(&dir).map_err(|e| Error::ctx(&format!("creating {}", dir.display()), e))?;
    let bytes = view_bytes(v)?;
    let path = dir.join(VIEW_FILE);
    let tmp = dir.join(format!(".{VIEW_FILE}.tmp"));
    let write = || -> std::io::Result<()> {
        use std::io::Write;
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(&bytes)?;
        f.sync_all()?;
        std::fs::rename(&tmp, &path)
    };
    write().map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        Error::ctx(&format!("writing {}", path.display()), e)
    })?;
    Ok(path)
}

/// The header of the live pack (the highest version) of each book in `packs_dir`, read without the vectors.
pub fn live_headers(packs_dir: &Path) -> Result<BTreeMap<String, Header>> {
    let mut best: BTreeMap<String, Header> = BTreeMap::new();
    for p in list_packs(packs_dir)? {
        let h = read_header(&p)?;
        if best.get(&h.doc_id).is_none_or(|b| b.doc_version < h.doc_version) {
            best.insert(h.doc_id.clone(), h);
        }
    }
    Ok(best)
}

/// What a rebuild did.
#[derive(Debug, Clone)]
pub struct ViewReport {
    pub path: PathBuf,
    pub books: usize,
    pub log_files: usize,
    /// Log lines that were not events (a torn last line, an unknown event).
    pub skipped: usize,
}

/// Rebuilds `<library_dir>/.local/docs.json` from the packs in `packs_dir` and every log in `<library_dir>/log/`.
pub fn rebuild_view(library_dir: &Path, packs_dir: &Path) -> Result<ViewReport> {
    let headers = live_headers(packs_dir)?;
    let facts: BTreeMap<String, BookFacts> = headers.iter().map(|(id, h)| (id.clone(), BookFacts::from_header(h))).collect();
    let logs: LogSet = read_logs(&library_dir.join(LOG_DIR))?;
    let resolved = resolve(&logs.events);
    let path = write_view(library_dir, &view_value(&facts, &resolved, &logs.files))?;
    Ok(ViewReport { path, books: facts.len(), log_files: logs.files.len(), skipped: logs.skipped })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::log::{By, Event, Kind};

    fn facts() -> BTreeMap<String, BookFacts> {
        let mut m = BTreeMap::new();
        let mut a = BookFacts::new("Well Water", Some(Suggested { div: "210".into(), label: "Water".into(), score: Some(0.875), classifier_version: Some(3), source: "classifier".into(), second_div: Some("220".into()) }));
        a.compression = Some(CompressionOutcome {
            original_size: 9000,
            stored_size: 4000,
            level: "smaller_scans".into(),
            preset: Some("balanced".into()),
            kept_original: false,
            kept_reason: None,
            psnr_min: Some(41.5),
        });
        a.ocr = Some(OcrInfo { engine: "doctr".into(), version: "1.1.0".into(), pages_ocrd: 12 });
        m.insert("a".to_string(), a);
        m.insert("b".to_string(), BookFacts::new("Stone", None));
        m
    }

    fn events() -> Vec<Event> {
        vec![
            Event::new(10, "d1", Kind::Place { doc: "a".into(), div: "210".into(), by: By::Auto }),
            Event::new(11, "d1", Kind::Assign { doc: "a".into(), div: "210".into(), seq: 1 }),
            Event::new(12, "d1", Kind::Title { doc: "a".into(), title: "The Well Water Handbook".into() }),
            Event::new(13, "d1", Kind::Place { doc: "gone".into(), div: "210".into(), by: By::Auto }),
            Event::new(14, "d1", Kind::Assign { doc: "gone".into(), div: "210".into(), seq: 5 }),
            Event::new(15, "d1", Kind::Retire { doc: "gone".into(), div: "210".into(), seq: 5 }),
        ]
    }

    #[test]
    fn the_view_has_the_documented_shape() {
        let r = resolve(&events());
        let v = view_value(&facts(), &r, &[("d1.jsonl".to_string(), 123)]);
        assert_eq!(v["format"], json!(2));
        assert_eq!(v["built_from"], json!({"packs": 2, "logs": {"d1.jsonl": 123}}));
        let a = &v["docs"]["a"];
        assert_eq!(a["title"], json!("The Well Water Handbook"));
        assert_eq!(a["source_title"], Value::Null);
        assert_eq!(a["shelf"], json!("210"));
        assert_eq!(a["call"], json!({"div": "210", "seq": 1, "suffix": 0, "text": "CDS 210-001"}));
        assert_eq!(a["suggested"]["div"], json!("210"));
        assert_eq!(a["suggested"]["second_div"], json!("220"));
        assert_eq!(a["removed"], json!(false));
        assert_eq!(a["compression"]["stored_size"], json!(4000));
        assert_eq!(a["ocr"], json!({"engine": "doctr", "version": "1.1.0", "pages_ocrd": 12}));
        // a book no event mentions: its pack title, no shelf, no number, every key present
        let b = &v["docs"]["b"];
        assert_eq!((b["title"].clone(), b["shelf"].clone(), b["call"].clone(), b["suggested"].clone()), (json!("Stone"), Value::Null, Value::Null, Value::Null));
        for k in ["title", "source_title", "shelf", "call", "suggested", "removed", "compression", "ocr"] {
            assert!(b.as_object().unwrap().contains_key(k), "{k}");
        }
        // a book with events but no pack is not in the view; its retired number is
        assert!(v["docs"].get("gone").is_none());
        assert_eq!(v["retired"], json!({"210": [5]}));
        assert_eq!(v["docs"].as_object().unwrap().keys().cloned().collect::<Vec<_>>(), ["a", "b"]);
    }

    #[test]
    fn the_same_inputs_give_the_same_bytes_and_the_write_is_atomic() {
        let r = resolve(&events());
        let v = view_value(&facts(), &r, &[]);
        assert_eq!(view_bytes(&v).unwrap(), view_bytes(&view_value(&facts(), &resolve(&events()), &[])).unwrap());
        let tmp = tempfile::tempdir().unwrap();
        let p = write_view(tmp.path(), &v).unwrap();
        assert_eq!(p, tmp.path().join(".local").join("docs.json"));
        assert_eq!(std::fs::read(&p).unwrap(), view_bytes(&v).unwrap());
        write_view(tmp.path(), &v).unwrap();
        assert!(std::fs::read_dir(tmp.path().join(".local")).unwrap().all(|e| !e.unwrap().file_name().to_string_lossy().ends_with(".tmp")));
    }
}
