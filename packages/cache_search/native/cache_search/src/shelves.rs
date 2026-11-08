//! The Bookshelves log's core ops (logic in the `cache_shelves` crate). They are handle-less: the arguments say which folders to
//! read and write. A pack is gzip-compressed JSON Lines whose first line is its header; `cache_shelves` links no gzip code, so
//! this module reads that line with the flate2 this crate already has.

use crate::error::{Error, Result};
use std::io::BufRead;
use std::path::Path;

/// The first line of a pack (its header, as JSON text).
fn header_line(path: &Path) -> std::result::Result<String, String> {
    let f = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut lines = std::io::BufReader::new(flate2::read::GzDecoder::new(f)).lines();
    match lines.next() {
        Some(Ok(l)) => Ok(l),
        Some(Err(e)) => Err(format!("{}: {e}", path.display())),
        None => Err(format!("{}: empty pack", path.display())),
    }
}

fn err(e: cache_shelves::Error) -> Error {
    // the crate's errors are bad requests (missing keys, bad events) or file problems; its messages say which
    if e.0.starts_with("reading ") || e.0.starts_with("writing ") || e.0.starts_with("creating ") {
        Error::io(e.0)
    } else {
        Error::bad_json(e.0)
    }
}

/// `shelvesDetect`. Single copy: `{"copy": facts, "against": [facts], "tuning"?}` -> `[{"with","how","score"}]` (pure). Batch, when
/// the request has "libraries": `{"libraries","copies"?,"known"?,"tuning"?}` -> `[{"copy","with","how","score"}]`.
pub fn detect(args: &str) -> Result<String> {
    cache_shelves::ops::detect(args, &header_line).map_err(err)
}

/// `shelvesAppend`: `{"dir","dev","events":[...]}` -> `{"written","last_at"}`.
pub fn append(args: &str) -> Result<String> {
    cache_shelves::ops::append(args).map_err(err)
}

/// `shelvesResolve`: `{"dir","libraries":[{"library_id","dir","packs_dir"?}]}` -> the view (format 1).
pub fn resolve(args: &str) -> Result<String> {
    cache_shelves::ops::resolve_view(args, &header_line).map_err(err)
}

/// `shelvesImport`: `{"dir","dev","libraries":[...]}` -> `{"events","files":[...]}`.
pub fn import(args: &str) -> Result<String> {
    cache_shelves::ops::import(args, &header_line).map_err(err)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};
    use std::io::Write;

    #[test]
    fn the_ops_read_gzip_packs_and_write_the_log() {
        let root = std::env::temp_dir().join(format!("cache_search_shelves_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let packs = root.join("lib").join("packs");
        std::fs::create_dir_all(&packs).unwrap();
        let header = json!({"cdoc": 1, "doc_id": "wm", "doc_version": 1, "title": "Wilderness Medicine", "source": {"blake3": "s"}, "book": {"title": "Wilderness Medicine", "original_blake3": "WM"}});
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        writeln!(gz, "{header}").unwrap();
        writeln!(gz, "{{\"i\":0}}").unwrap();
        std::fs::write(packs.join("wm@1.cdoc"), gz.finish().unwrap()).unwrap();
        let dir = root.join("bookshelves");
        let libs = json!([{"library_id": "L", "dir": root.join("lib")}]);
        let out: Value = serde_json::from_str(
            &append(&json!({"dir": dir, "dev": "phone-1", "events": [{"ev": "place", "copy": "WM", "div": "610", "by": "auto"}, {"ev": "assign", "copy": "WM", "div": "610", "seq": 1}]}).to_string()).unwrap(),
        )
        .unwrap();
        assert_eq!(out["written"], 2);
        let view: Value = serde_json::from_str(&resolve(&json!({"dir": dir, "libraries": libs}).to_string()).unwrap()).unwrap();
        assert_eq!(view["books"]["WM"]["call"]["text"], "CDS 610-001");
        assert_eq!(view["books"]["WM"]["title"], "Wilderness Medicine");
        // resolve also wrote the view file, and the batch detect reads the gzip packs
        assert!(dir.join(".local").join("view.json").is_file());
        let batch: Value = serde_json::from_str(&detect(&json!({"libraries": libs}).to_string()).unwrap()).unwrap();
        assert_eq!(batch, json!([]));
        assert!(append("{}").is_err());
        assert!(detect("not json").is_err());
        let _ = std::fs::remove_dir_all(&root);
    }
}
