//! The builder's side of the Bookshelves log (crates `cache_shelves`): reading a library's pack headers, and
//! `cache-build view --bookshelves <dir> --library <dir>...`. The log, its resolution and the view format are in the shared crate
//! and LIBRARY-LOG.md.

use crate::error::{Error, Result};
use cache_shelves::library::LibraryRef;
use serde_json::Value;
use std::io::BufRead;
use std::path::{Path, PathBuf};

/// The first line of a pack: its header, as JSON text.
pub fn header_line(path: &Path) -> std::result::Result<String, String> {
    let f = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    match std::io::BufReader::new(flate2::read::GzDecoder::new(f)).lines().next() {
        Some(Ok(l)) => Ok(l),
        Some(Err(e)) => Err(format!("{}: {e}", path.display())),
        None => Err(format!("{}: empty pack", path.display())),
    }
}

/// A library folder as the Bookshelves log names it: the id in its `cache-library.json`, else the folder's name.
pub fn library_ref(dir: &Path) -> LibraryRef {
    let id = std::fs::read(dir.join(crate::library::SETTINGS_FILE))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok())
        .and_then(|v| v.get("library_id").and_then(Value::as_str).map(str::to_string))
        .filter(|s| !s.is_empty())
        .or_else(|| dir.file_name().map(|n| n.to_string_lossy().into_owned()))
        .unwrap_or_else(|| "library".to_string());
    LibraryRef::new(&id, dir)
}

/// What `cache-build view --bookshelves` did.
#[derive(Debug, Clone)]
pub struct BookshelvesReport {
    pub path: PathBuf,
    pub books: usize,
    pub log_files: usize,
}

/// Resolves the Bookshelves log in `<bookshelves>/log/` against the libraries and writes `<bookshelves>/.local/view.json`.
pub fn rebuild_bookshelves_view(bookshelves: &Path, libraries: &[PathBuf]) -> Result<BookshelvesReport> {
    let refs: Vec<LibraryRef> = libraries.iter().map(|d| library_ref(d)).collect();
    let view = cache_shelves::view::build_view(bookshelves, &refs, &header_line).map_err(|e| Error::new(e.0))?;
    let path = cache_shelves::view::write_view(bookshelves, &view).map_err(|e| Error::new(e.0))?;
    let books = view["books"].as_object().map_or(0, |b| b.len());
    let log_files = view["built_from"]["logs"].as_object().map_or(0, |b| b.len());
    Ok(BookshelvesReport { path, books, log_files })
}
