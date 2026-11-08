//! The job's Bookshelves events, through `cache_shelves` in process: detect whether the new copy is a book that is already on the
//! shelves; if it is, write `same by:auto`; if not, `place` it (when the classifier is confident) and `assign` the next free
//! number. Nothing is written when the classifier has no confident answer: the book is then in Unsorted.

use crate::engine::Placement;
use crate::error::{Error, Result};
use cache_shelves::events::{By, Event, Kind};
use cache_shelves::library::{load_library, LibraryInput, LibraryRef, PackFacts};
use cache_shelves::same::{detect, Tuning};
use cache_shelves::store::{read_logs, LogWriter, LOG_DIR};
use cache_shelves::resolve;
use serde_json::{json, Value};
use std::io::BufRead;
use std::path::{Path, PathBuf};

/// The `bookshelves` object of the start call.
#[derive(Debug, Clone)]
pub struct Bookshelves {
    pub dir: PathBuf,
    pub dev: String,
}

/// What the job will write to the log, and what it reports.
#[derive(Debug, Clone, Default)]
pub struct Plan {
    pub events: Vec<Event>,
    /// `{"with","how","score"}` of each same-book match.
    pub same: Vec<Value>,
    /// The division placed and who placed it.
    pub shelf: Option<(String, &'static str)>,
}

/// The first line of a gzip pack (its header as JSON text).
fn header_line(path: &Path) -> std::result::Result<String, String> {
    let f = std::fs::File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut lines = std::io::BufReader::new(flate2::read::GzDecoder::new(f)).lines();
    match lines.next() {
        Some(Ok(l)) => Ok(l),
        Some(Err(e)) => Err(format!("{}: {e}", path.display())),
        None => Err(format!("{}: empty pack", path.display())),
    }
}

fn library_id(dir: &Path) -> String {
    std::fs::read_to_string(dir.join("cache-library.json"))
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v.get("library_id").and_then(Value::as_str).map(str::to_string))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default())
}

fn looks_like_library(dir: &Path) -> bool {
    dir.join("copies.jsonl").is_file() || dir.join("shard").join("copies.jsonl").is_file() || dir.join(crate::files::PACKS_DIR).is_dir()
}

/// The libraries whose copies are visible to the new book: the target library and the other libraries in the same folder (the
/// app keeps every library as a folder under one `libraries` folder). A folder with neither a copies file nor packs has nothing
/// to compare with.
pub fn visible_libraries(library_dir: &Path) -> Vec<LibraryRef> {
    let mut out = vec![LibraryRef::new(&library_id(library_dir), library_dir)];
    if let Some(parent) = library_dir.parent() {
        let mut siblings: Vec<PathBuf> = std::fs::read_dir(parent)
            .map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.path()).collect())
            .unwrap_or_default();
        siblings.sort();
        for p in siblings {
            let hidden = p.file_name().map(|n| n.to_string_lossy().starts_with('.')).unwrap_or(true);
            if p != library_dir && !hidden && p.is_dir() && looks_like_library(&p) {
                out.push(LibraryRef::new(&library_id(&p), &p));
            }
        }
    }
    out
}

fn load_all(refs: &[LibraryRef]) -> Vec<LibraryInput> {
    // a library that cannot be read adds nothing to compare with; it does not stop the book from being added
    refs.iter().filter_map(|l| load_library(l, &header_line).ok()).collect()
}

/// Decides the events for a new copy. `header_json` is the pack's header; `mean_vector` is the book's mean vector.
pub fn plan(bs: &Bookshelves, library_dir: &Path, header_json: &str, placement: Option<&Placement>, at: u64) -> Result<Plan> {
    let facts = PackFacts::from_header_line(header_json).map_err(|e| Error::bad_json(e.to_string()))?;
    let refs = visible_libraries(library_dir);
    let libs = load_all(&refs);
    let against: Vec<_> = libs.iter().flat_map(|l| l.copies.iter().map(|c| c.detect_facts())).collect();
    let found = detect(&facts.detect_facts(), &against, &Tuning::default());
    let mut plan = Plan::default();
    if !found.is_empty() {
        for f in &found {
            plan.events.push(Event::new(at, &bs.dev, Kind::Same { copy: facts.copy.clone(), with: f.with.clone(), by: By::Auto, how: f.how, score: Some(f.score) }));
            plan.same.push(json!({"with": f.with, "how": f.how.as_str(), "score": f.score}));
        }
        return Ok(plan);
    }
    if let Some(p) = placement {
        let logs = read_logs(&bs.dir.join(LOG_DIR)).map_err(|e| Error::io("reading the Bookshelves log", e))?;
        let resolved = resolve::resolve(&logs.events, &libs);
        let seq = resolved.next_seq(&p.div);
        plan.events.push(Event::new(at, &bs.dev, Kind::Place { copy: facts.copy.clone(), div: p.div.clone(), by: By::Auto }));
        plan.events.push(Event::new(at, &bs.dev, Kind::Assign { copy: facts.copy.clone(), div: p.div.clone(), seq }));
        plan.shelf = Some((p.div.clone(), "auto"));
    }
    Ok(plan)
}

/// Appends the planned events to this device's log.
pub fn write(bs: &Bookshelves, events: &[Event]) -> Result<()> {
    if events.is_empty() {
        return Ok(());
    }
    let w = LogWriter::open(&bs.dir.join(LOG_DIR), &bs.dev).map_err(|e| Error::new(crate::error::Code::Io, e.to_string()))?;
    w.append(events).map_err(|e| Error::new(crate::error::Code::Io, e.to_string()))?;
    Ok(())
}
