//! The job's Bookshelves events, through `cache_shelves` in process: detect whether the new copy is a book that is already on the
//! shelves; if it is, write `same by:auto`; if not, `place` it (when the classifier is confident) and `assign` the next free
//! number. Nothing is written when the classifier has no confident answer: the book is then in Unsorted.

use crate::engine::Filing;
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
    /// The libraries to compare with besides the target library; `None`: the target library only.
    pub libraries: Option<Vec<LibraryRef>>,
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

/// The libraries whose copies the new book is compared with: the target library, and the `bookshelves.libraries` the app named.
pub fn visible_libraries(library_dir: &Path, listed: Option<&[LibraryRef]>) -> Vec<LibraryRef> {
    let mut out = vec![LibraryRef::new(&library_id(library_dir), library_dir)];
    for l in listed.unwrap_or(&[]) {
        if l.dir != library_dir {
            out.push(l.clone());
        }
    }
    out
}

fn load_all(refs: &[LibraryRef]) -> Vec<LibraryInput> {
    // a library that cannot be read adds nothing to compare with; it does not stop the book from being added
    refs.iter().filter_map(|l| load_library(l, &header_line).ok()).collect()
}

fn found_of(bs: &Bookshelves, library_dir: &Path, header_json: &str) -> Result<(PackFacts, Vec<LibraryInput>, Vec<cache_shelves::same::Found>)> {
    let facts = PackFacts::from_header_line(header_json).map_err(|e| Error::bad_json(e.to_string()))?;
    let refs = visible_libraries(library_dir, bs.libraries.as_deref());
    let libs = load_all(&refs);
    let against: Vec<_> = libs.iter().flat_map(|l| l.copies.iter().map(|c| c.detect_facts())).collect();
    let found = detect(&facts.detect_facts(), &against, &Tuning::default());
    Ok((facts, libs, found))
}

/// Whether the book is a copy of one already on the shelves (the same-book detection). A book that is skips filing.
pub fn has_same(bs: &Bookshelves, library_dir: &Path, header_json: &str) -> Result<bool> {
    Ok(!found_of(bs, library_dir, header_json)?.2.is_empty())
}

/// Decides the events for a new copy. `header_json` is the pack's header. `filing` is the sorter's verdict (`None` when the book is a
/// same-book match, which is not filed, or the sorter gave no guess).
pub fn plan(bs: &Bookshelves, library_dir: &Path, header_json: &str, filing: Option<&Filing>, at: u64) -> Result<Plan> {
    let (facts, libs, found) = found_of(bs, library_dir, header_json)?;
    let mut plan = Plan::default();
    if !found.is_empty() {
        for f in &found {
            plan.events.push(Event::new(at, &bs.dev, Kind::Same { copy: facts.copy.clone(), with: f.with.clone(), by: By::Auto, how: f.how, score: Some(f.score) }));
            plan.same.push(json!({"with": f.with, "how": f.how.as_str(), "score": f.score}));
        }
        return Ok(plan);
    }
    if let Some(p) = filing.filter(|f| f.filed) {
        let div = &p.suggested.div;
        let logs = read_logs(&bs.dir.join(LOG_DIR)).map_err(|e| Error::io("reading the Bookshelves log", e))?;
        let resolved = resolve::resolve(&logs.events, &libs);
        let seq = resolved.next_seq(div);
        plan.events.push(Event::new(at, &bs.dev, Kind::Place { copy: facts.copy.clone(), div: div.clone(), by: By::Auto }));
        plan.events.push(Event::new(at, &bs.dev, Kind::Assign { copy: facts.copy.clone(), div: div.clone(), seq }));
        plan.shelf = Some((div.clone(), "auto"));
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

/// What this device's log already holds for the copy: its `same` events and its `place`. Events are owed to the log only when there
/// are none (a crash or a write error after the library was written leaves the book there without them; the next try writes them).
pub fn existing(bs: &Bookshelves, copy: &str) -> Result<Plan> {
    let logs = read_logs(&bs.dir.join(LOG_DIR)).map_err(|e| Error::io("reading the Bookshelves log", e))?;
    let mut plan = Plan::default();
    for e in logs.events.into_iter().filter(|e| e.dev == bs.dev && e.kind.copy() == Some(copy)) {
        match &e.kind {
            Kind::Same { with, how, score, .. } => plan.same.push(json!({"with": with, "how": how.as_str(), "score": score})),
            Kind::Place { div, by, .. } => plan.shelf = Some((div.clone(), by.as_str())),
            _ => {}
        }
        plan.events.push(e);
    }
    Ok(plan)
}
