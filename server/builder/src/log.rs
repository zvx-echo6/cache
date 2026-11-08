//! The per-device library log: `<library>/log/<device_id>.jsonl`. See LIBRARY-LOG.md.
//!
//! Nothing that syncs ever has two writers, so each device appends only to its own file and every device resolves the same
//! answer from all the files. [`LogWriter`] appends; [`read_logs`] reads every file; [`resolve`] is a pure function of the events.

use crate::error::{Error, Result};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// The folder of the logs, at the library root.
pub const LOG_DIR: &str = "log";
pub const LOG_EXT: &str = "jsonl";
/// The `v` of every event.
pub const LOG_VERSION: u64 = 1;
/// The prefix of the call number.
pub const CALL_PREFIX: &str = "CDS";

/// Who made a placement: the sorter or a label (`auto`), or a person (`user`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum By {
    Auto,
    User,
}

impl By {
    pub fn as_str(self) -> &'static str {
        match self {
            By::Auto => "auto",
            By::User => "user",
        }
    }

    fn parse(s: &str) -> Option<By> {
        match s {
            "auto" => Some(By::Auto),
            "user" => Some(By::User),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FolderMode { Keep, Cds, Both }

impl FolderMode {
    fn as_str(self) -> &'static str { match self { Self::Keep => "keep", Self::Cds => "cds", Self::Both => "both" } }
    fn parse(s: &str) -> Option<Self> { match s { "keep" => Some(Self::Keep), "cds" => Some(Self::Cds), "both" => Some(Self::Both), _ => None } }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Kind {
    /// The book goes on the shelf of division `div`.
    Place { doc: String, div: String, by: By },
    /// The book goes to Unsorted.
    Unsort { doc: String, by: By },
    /// The book takes call number `seq` in `div`.
    Assign { doc: String, div: String, seq: u32 },
    /// The book gives up call number `seq` in `div` (never used again).
    Retire { doc: String, div: String, seq: u32 },
    Title { doc: String, title: String },
    /// Hides the book on every device; deletes no files.
    Remove { doc: String },
    Restore { doc: String },
    /// Optional book facts (author, edition, year) from a source: the seed log writes them from a titles file. `copy` (the
    /// book's `original_blake3`) and `loc` (`<library_id>/<doc_id>`) are informational; resolution keys on `doc`.
    Facts { doc: String, copy: Option<String>, loc: Option<String>, fields: cache_shelves::events::FactFields },
    /// A device-local linked folder. This event deliberately has no document id.
    Folder { folder_id: String, label: String, mode: FolderMode },
    /// A document is present at a relative path in a linked folder.
    Locate { doc: String, folder_id: String, relpath: String, version: Option<u32>, source_blake3: Option<String> },
    /// A document is no longer present at a relative path in a linked folder.
    Unlocate { doc: String, folder_id: String, relpath: String },
}

impl Kind {
    pub fn doc(&self) -> Option<&str> {
        match self {
            Kind::Place { doc, .. } | Kind::Unsort { doc, .. } | Kind::Assign { doc, .. } | Kind::Retire { doc, .. } | Kind::Title { doc, .. } | Kind::Remove { doc } | Kind::Restore { doc } | Kind::Facts { doc, .. } | Kind::Locate { doc, .. } | Kind::Unlocate { doc, .. } => Some(doc),
            Kind::Folder { .. } => None,
        }
    }
}

/// One line of a log: when (UTC milliseconds), who wrote it, and what happened.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Event {
    pub at: u64,
    pub dev: String,
    pub kind: Kind,
}

impl Event {
    pub fn new(at: u64, dev: &str, kind: Kind) -> Event {
        Event { at, dev: dev.to_string(), kind }
    }

    /// The JSON line (no line break): `{"v":1,"at":...,"dev":"...","ev":"place","doc":"...",...}`.
    pub fn to_line(&self) -> String {
        let mut m = Map::new();
        m.insert("v".into(), json!(LOG_VERSION));
        m.insert("at".into(), json!(self.at));
        m.insert("dev".into(), json!(self.dev));
        let ev = match &self.kind {
            Kind::Place { .. } => "place",
            Kind::Unsort { .. } => "unsort",
            Kind::Assign { .. } => "assign",
            Kind::Retire { .. } => "retire",
            Kind::Title { .. } => "title",
            Kind::Remove { .. } => "remove",
            Kind::Restore { .. } => "restore",
            Kind::Facts { .. } => "facts",
            Kind::Folder { .. } => "folder",
            Kind::Locate { .. } => "locate",
            Kind::Unlocate { .. } => "unlocate",
        };
        m.insert("ev".into(), json!(ev));
        if let Some(doc) = self.kind.doc() { m.insert("doc".into(), json!(doc)); }
        match &self.kind {
            Kind::Place { div, by, .. } => {
                m.insert("div".into(), json!(div));
                m.insert("by".into(), json!(by.as_str()));
            }
            Kind::Unsort { by, .. } => {
                m.insert("by".into(), json!(by.as_str()));
            }
            Kind::Assign { div, seq, .. } | Kind::Retire { div, seq, .. } => {
                m.insert("div".into(), json!(div));
                m.insert("seq".into(), json!(seq));
            }
            Kind::Title { title, .. } => {
                m.insert("title".into(), json!(title));
            }
            Kind::Folder { folder_id, label, mode } => {
                m.insert("folder_id".into(), json!(folder_id));
                m.insert("label".into(), json!(label));
                m.insert("mode".into(), json!(mode.as_str()));
            }
            Kind::Locate { folder_id, relpath, version, source_blake3, .. } => {
                m.insert("folder_id".into(), json!(folder_id));
                m.insert("relpath".into(), json!(relpath));
                if let Some(v) = version { m.insert("version".into(), json!(v)); }
                if let Some(h) = source_blake3 { m.insert("source_blake3".into(), json!(h)); }
            }
            Kind::Unlocate { folder_id, relpath, .. } => {
                m.insert("folder_id".into(), json!(folder_id));
                m.insert("relpath".into(), json!(relpath));
            }
            Kind::Facts { copy, loc, fields, .. } => {
                if let Some(c) = copy {
                    m.insert("copy".into(), json!(c));
                }
                if let Some(l) = loc {
                    m.insert("loc".into(), json!(l));
                }
                if let Some(a) = &fields.author {
                    m.insert("author".into(), json!(a));
                }
                if let Some(e) = &fields.edition {
                    m.insert("edition".into(), json!(e));
                }
                if let Some(y) = fields.year {
                    m.insert("year".into(), json!(y));
                }
            }
            Kind::Remove { .. } | Kind::Restore { .. } => {}
        }
        Value::Object(m).to_string()
    }

    /// Reads one line. `None` for anything this reader does not take: not JSON (a torn line), another `v`, an event it does not
    /// know, or a missing field. A reader skips such a line and goes on.
    pub fn from_line(line: &str) -> Option<Event> {
        let v: Value = serde_json::from_str(line.trim()).ok()?;
        if v.get("v")?.as_u64()? != LOG_VERSION {
            return None;
        }
        let at = v.get("at")?.as_u64()?;
        let dev = v.get("dev")?.as_str()?.to_string();
        if dev.is_empty() {
            return None;
        }
        let text = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
        let doc = || text("doc").filter(|d| !d.is_empty());
        let seq = || v.get("seq").and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok());
        let folder_id = || text("folder_id").filter(|s| !s.is_empty());
        let relpath = || text("relpath").filter(|s| valid_relpath(s));
        let kind = match v.get("ev")?.as_str()? {
            "place" => Kind::Place { doc: doc()?, div: text("div")?, by: By::parse(&text("by")?)? },
            "unsort" => Kind::Unsort { doc: doc()?, by: By::parse(&text("by")?)? },
            "assign" => Kind::Assign { doc: doc()?, div: text("div")?, seq: seq()? },
            "retire" => Kind::Retire { doc: doc()?, div: text("div")?, seq: seq()? },
            "title" => Kind::Title { doc: doc()?, title: text("title")? },
            "remove" => Kind::Remove { doc: doc()? },
            "restore" => Kind::Restore { doc: doc()? },
            "facts" => {
                let fields = cache_shelves::events::FactFields::from_value(&v);
                if fields.is_empty() {
                    return None;
                }
                Kind::Facts { doc: doc()?, copy: text("copy").filter(|c| !c.is_empty()), loc: text("loc").filter(|l| !l.is_empty()), fields }
            }
            "folder" => Kind::Folder { folder_id: folder_id()?, label: text("label")?, mode: FolderMode::parse(&text("mode")?)? },
            "locate" => {
                let version = v.get("version").and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok());
                let source_blake3 = text("source_blake3").filter(|h| h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit()));
                if v.get("version").is_some() && version.is_none() || v.get("source_blake3").is_some() && source_blake3.is_none() { return None; }
                Kind::Locate { doc: doc()?, folder_id: folder_id()?, relpath: relpath()?, version, source_blake3 }
            }
            "unlocate" => Kind::Unlocate { doc: doc()?, folder_id: folder_id()?, relpath: relpath()? },
            _ => return None,
        };
        Some(Event { at, dev, kind })
    }
}

/// A portable normalized relative path using `/` separators. Absolute roots, traversal, drive/ADS syntax,
/// empty components, and backslashes are rejected before a location can enter a synced log.
pub fn valid_relpath(path: &str) -> bool {
    !path.is_empty() && !path.starts_with('/') && !path.contains('\\') && !path.contains(':') &&
        !path.chars().any(|c| c.is_control()) && path.split('/').all(|part| !part.is_empty() && part != "." && part != "..")
}

/// A device id is used in a file name: letters, digits, `.`, `_` and `-`, at most 64, not starting with a dot.
pub fn valid_device_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && !id.starts_with('.') && id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// The writer of one device's log. One writer per file: it refuses events from another device.
#[derive(Debug, Clone)]
pub struct LogWriter {
    path: PathBuf,
    dev: String,
}

impl LogWriter {
    /// The log of `dev` in `dir` (the library's `log/` folder, made when missing).
    pub fn open(dir: &Path, dev: &str) -> Result<LogWriter> {
        if !valid_device_id(dev) {
            return Err(Error::new(format!("invalid device id {dev:?}: use letters, digits, '.', '_' and '-'")));
        }
        std::fs::create_dir_all(dir).map_err(|e| Error::ctx(&format!("creating {}", dir.display()), e))?;
        Ok(LogWriter { path: dir.join(format!("{dev}.{LOG_EXT}")), dev: dev.to_string() })
    }

    pub fn dev(&self) -> &str {
        &self.dev
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    /// Appends the events as lines, all in one write, and flushes them to disk. If the file ends in a torn line (no line break),
    /// that line is closed first so the new lines are not glued to it.
    pub fn append(&self, events: &[Event]) -> Result<()> {
        if events.is_empty() {
            return Ok(());
        }
        if let Some(e) = events.iter().find(|e| e.dev != self.dev) {
            return Err(Error::new(format!("the log of {} takes no events from {}", self.dev, e.dev)));
        }
        for e in events {
            match &e.kind {
                Kind::Locate { doc, folder_id, relpath, source_blake3, .. } => {
                    if doc.is_empty() || folder_id.is_empty() || !valid_relpath(relpath) || source_blake3.as_ref().is_some_and(|h| h.len() != 64 || !h.bytes().all(|b| b.is_ascii_hexdigit())) {
                        return Err(Error::new("invalid linked-folder location; paths must be safe relative paths"));
                    }
                }
                Kind::Unlocate { doc, folder_id, relpath } => {
                    if doc.is_empty() || folder_id.is_empty() || !valid_relpath(relpath) {
                        return Err(Error::new("invalid linked-folder location; paths must be safe relative paths"));
                    }
                }
                Kind::Folder { folder_id, .. } if folder_id.is_empty() => return Err(Error::new("linked-folder id must not be empty")),
                _ => {}
            }
        }
        let mut buf = String::new();
        for e in events {
            buf.push_str(&e.to_line());
            buf.push('\n');
        }
        let ctx = |e: std::io::Error| Error::ctx(&format!("writing {}", self.path.display()), e);
        let mut f = std::fs::OpenOptions::new().create(true).read(true).append(true).open(&self.path).map_err(ctx)?;
        let len = f.metadata().map_err(ctx)?.len();
        if len > 0 {
            f.seek(SeekFrom::End(-1)).map_err(ctx)?;
            let mut last = [0u8; 1];
            f.read_exact(&mut last).map_err(ctx)?;
            if last[0] != b'\n' {
                buf.insert(0, '\n');
            }
        }
        f.write_all(buf.as_bytes()).map_err(ctx)?;
        f.sync_data().map_err(ctx)
    }
}

/// Every event of every log in a folder.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LogSet {
    /// In file-name order, then line order.
    pub events: Vec<Event>,
    /// Each log file's name and size in bytes.
    pub files: Vec<(String, u64)>,
    /// Lines that were not events (a torn last line, an unknown event or version).
    pub skipped: usize,
}

/// The events in `text`, and how many lines were skipped. A torn last line (cut off by a crash) is skipped like any other
/// line that is not an event.
pub fn parse_log(text: &str) -> (Vec<Event>, usize) {
    let mut events = Vec::new();
    let mut skipped = 0;
    for line in text.split('\n') {
        if line.trim().is_empty() {
            continue;
        }
        match Event::from_line(line) {
            Some(e) => events.push(e),
            None => skipped += 1,
        }
    }
    (events, skipped)
}

/// Reads every `*.jsonl` in `dir` (none when the folder is missing).
pub fn read_logs(dir: &Path) -> Result<LogSet> {
    let mut set = LogSet::default();
    let rd = match std::fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(set),
        Err(e) => return Err(Error::ctx(&format!("reading {}", dir.display()), e)),
    };
    let mut names: Vec<String> = rd
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.starts_with('.') && n.ends_with(&format!(".{LOG_EXT}")))
        .collect();
    names.sort();
    for name in names {
        let bytes = std::fs::read(dir.join(&name)).map_err(|e| Error::ctx(&format!("reading {name}"), e))?;
        let (events, skipped) = parse_log(&String::from_utf8_lossy(&bytes));
        set.events.extend(events);
        set.skipped += skipped;
        set.files.push((name, bytes.len() as u64));
    }
    Ok(set)
}

// ---------------------------------------------------------------------------------------------------------- resolution

/// A call number: `CDS 210-002`, or `CDS 210-002.1` for the second claim on the number.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Call {
    pub div: String,
    pub seq: u32,
    /// 0 for the first claim on (div, seq); k for the k-th later one.
    pub suffix: u32,
    pub text: String,
}

/// `CDS ` + div + `-` + the sequence in 3 digits (wider past 999) + `.k` when `suffix` is above 0.
pub fn call_text(div: &str, seq: u32, suffix: u32) -> String {
    if suffix > 0 {
        format!("{CALL_PREFIX} {div}-{seq:03}.{suffix}")
    } else {
        format!("{CALL_PREFIX} {div}-{seq:03}")
    }
}

/// What the logs say about one book.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DocState {
    /// The division of the latest `place` (`Some`) or `unsort` (`None`); `None` also for a book no event has placed.
    pub shelf: Option<String>,
    /// Some event has placed or unsorted it.
    pub shelved: bool,
    /// Who made the latest placement.
    pub by: Option<By>,
    /// The latest `title` event.
    pub title: Option<String>,
    pub removed: bool,
    /// The call number; none in Unsorted.
    pub call: Option<Call>,
}

/// The same answer on every device, from all the events.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FolderState { pub label: String, pub mode: FolderMode }

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Location {
    pub dev: String, pub folder_id: String, pub relpath: String,
    pub version: Option<u32>, pub source_blake3: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Resolved {
    /// Only books some event mentions.
    pub docs: BTreeMap<String, DocState>,
    /// Latest folder metadata, keyed by (device id, folder id). Paths/URIs are never stored here.
    pub folders: BTreeMap<(String, String), FolderState>,
    /// Active source locations per document, sorted by device, folder and relative path.
    pub locations: BTreeMap<String, Vec<Location>>,
    /// For each division, the numbers that were retired.
    pub retired: BTreeMap<String, BTreeSet<u32>>,
    /// For each division, the highest number ever assigned or retired.
    pub max_seq: BTreeMap<String, u32>,
}

impl Resolved {
    /// The next free number in a division: 1 + the highest ever assigned or retired there.
    pub fn next_seq(&self, div: &str) -> u32 {
        self.max_seq.get(div).map_or(1, |m| m + 1)
    }

    pub fn doc(&self, doc: &str) -> Option<&DocState> {
        self.docs.get(doc)
    }
}

/// Order of events: (at, dev), then position, so two events of one device at the same millisecond keep their file order.
type Stamp = (u64, String, usize);

type LocationEventMap = BTreeMap<(String, String, String, String), (Stamp, Option<Location>)>;

/// Resolves the events (in any order of devices; the result does not depend on it, except that two events of one device with the
/// same `at` count in the order given).
///
/// - Shelf: the latest `place` or `unsort` by (at, dev).
/// - Title: the latest `title` by (at, dev). Removed: the latest of `remove` and `restore`.
/// - Call number: a book holds its latest `assign` that no `retire` of the same book, division and number cancels, if that
///   number is in the division of its shelf. All assigns ever made for a (division, number), retired ones included, are ranked
///   by (at, doc); rank 0 shows the plain number and rank k adds `.k`. Ranks are fixed: they do not move when an earlier holder
///   retires its number.
pub fn resolve(events: &[Event]) -> Resolved {
    let mut r = Resolved::default();
    let mut shelf: BTreeMap<&str, (Stamp, Option<&str>, By)> = BTreeMap::new();
    let mut title: BTreeMap<&str, (Stamp, &str)> = BTreeMap::new();
    let mut removed: BTreeMap<&str, (Stamp, bool)> = BTreeMap::new();
    let mut folder_events: BTreeMap<(String, String), (Stamp, FolderState)> = BTreeMap::new();
    let mut location_events: LocationEventMap = BTreeMap::new();
    // every assign: (div, seq) -> [(at, doc)]
    let mut claims: BTreeMap<(&str, u32), BTreeSet<(u64, &str)>> = BTreeMap::new();
    // each book's assigns, and the retired (doc, div, seq)
    let mut assigns: BTreeMap<&str, Vec<(Stamp, &str, u32)>> = BTreeMap::new();
    let mut retires: BTreeSet<(&str, &str, u32)> = BTreeSet::new();
    let bump = |max: &mut BTreeMap<String, u32>, div: &str, seq: u32| {
        let m = max.entry(div.to_string()).or_insert(0);
        if seq > *m {
            *m = seq;
        }
    };
    for (i, e) in events.iter().enumerate() {
        let stamp: Stamp = (e.at, e.dev.clone(), i);
        let doc = e.kind.doc();
        if let Some(doc) = doc { let _ = r.docs.entry(doc.to_string()).or_default(); }
        match &e.kind {
            Kind::Place { doc, div, by } => {
                if shelf.get(doc.as_str()).is_none_or(|(s, _, _)| *s < stamp) {
                    shelf.insert(doc.as_str(), (stamp, Some(div.as_str()), *by));
                }
            }
            Kind::Unsort { doc, by } => {
                if shelf.get(doc.as_str()).is_none_or(|(s, _, _)| *s < stamp) {
                    shelf.insert(doc.as_str(), (stamp, None, *by));
                }
            }
            Kind::Assign { doc, div, seq } => {
                bump(&mut r.max_seq, div, *seq);
                claims.entry((div.as_str(), *seq)).or_default().insert((e.at, doc));
                assigns.entry(doc).or_default().push((stamp, div.as_str(), *seq));
            }
            Kind::Retire { doc, div, seq } => {
                bump(&mut r.max_seq, div, *seq);
                r.retired.entry(div.clone()).or_default().insert(*seq);
                retires.insert((doc, div.as_str(), *seq));
            }
            Kind::Title { doc, title: t } => {
                if title.get(doc.as_str()).is_none_or(|(s, _)| *s < stamp) {
                    title.insert(doc.as_str(), (stamp, t.as_str()));
                }
            }
            Kind::Remove { doc } => {
                if removed.get(doc.as_str()).is_none_or(|(s, _)| *s < stamp) {
                    removed.insert(doc, (stamp, true));
                }
            }
            Kind::Restore { doc } => {
                if removed.get(doc.as_str()).is_none_or(|(s, _)| *s < stamp) {
                    removed.insert(doc, (stamp, false));
                }
            }
            Kind::Facts { .. } => {}
            Kind::Folder { folder_id, label, mode } => {
                let key = (e.dev.clone(), folder_id.clone());
                if folder_events.get(&key).is_none_or(|(s, _)| *s < stamp) {
                    folder_events.insert(key, (stamp, FolderState { label: label.clone(), mode: *mode }));
                }
            }
            Kind::Locate { doc, folder_id, relpath, version, source_blake3 } => {
                let key = (e.dev.clone(), folder_id.clone(), doc.clone(), relpath.clone());
                if location_events.get(&key).is_none_or(|(s, _)| *s < stamp) {
                    location_events.insert(key, (stamp, Some(Location { dev: e.dev.clone(), folder_id: folder_id.clone(), relpath: relpath.clone(), version: *version, source_blake3: source_blake3.clone() })));
                }
            }
            Kind::Unlocate { doc, folder_id, relpath } => {
                let key = (e.dev.clone(), folder_id.clone(), doc.clone(), relpath.clone());
                if location_events.get(&key).is_none_or(|(s, _)| *s < stamp) { location_events.insert(key, (stamp, None)); }
            }
        }
    }
    for ((dev, folder_id), (_, folder)) in folder_events { r.folders.insert((dev, folder_id), folder); }
    for ((dev, folder_id, doc, relpath), (_, location)) in location_events {
        if let Some(location) = location { r.locations.entry(doc).or_default().push(location); }
        let _ = (dev, folder_id, relpath);
    }
    // BTreeMap iteration already fixes folder/path order; availability is device-local and intentionally absent.
    for (doc, st) in r.docs.iter_mut() {
        let doc = doc.as_str();
        if let Some((_, div, by)) = shelf.get(doc) {
            st.shelved = true;
            st.shelf = div.map(str::to_string);
            st.by = Some(*by);
        }
        st.title = title.get(doc).map(|(_, t)| t.to_string());
        st.removed = removed.get(doc).is_some_and(|(_, x)| *x);
        let Some(div) = st.shelf.as_deref() else { continue };
        // the latest assign of this book that was not retired
        let held = assigns.get(doc).and_then(|v| v.iter().filter(|(_, d, s)| !retires.contains(&(doc, *d, *s))).max_by(|a, b| a.0.cmp(&b.0)));
        if let Some((_, d, seq)) = held {
            if *d == div {
                // rank among all claims on (div, seq); a book that assigned the same number twice counts once
                let rank = claims.get(&(div, *seq)).and_then(|c| c.iter().position(|(_, who)| *who == doc)).unwrap_or(0) as u32;
                st.call = Some(Call { div: div.to_string(), seq: *seq, suffix: rank, text: call_text(div, *seq, rank) });
            }
        }
    }
    r
}

/// A training correction: a person put a book in a division other than the one suggested for it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Correction {
    pub doc: String,
    /// The suggested division (`None`: nothing was suggested).
    pub from: Option<String>,
    pub to: String,
    pub at: u64,
    pub dev: String,
}

/// The user `place` events whose division differs from the book's suggested division, in the order of the events. `suggested`
/// gives a book's suggested division.
pub fn corrections(events: &[Event], suggested: &dyn Fn(&str) -> Option<String>) -> Vec<Correction> {
    events
        .iter()
        .filter_map(|e| match &e.kind {
            Kind::Place { doc, div, by: By::User } => {
                let from = suggested(doc);
                (from.as_deref() != Some(div.as_str())).then(|| Correction { doc: doc.clone(), from, to: div.clone(), at: e.at, dev: e.dev.clone() })
            }
            _ => None,
        })
        .collect()
}

/// `YYYY-MM-DDTHH:MM:SSZ` (UTC, optional `.mmm` before the Z) to milliseconds since 1970; also a plain whole number of milliseconds.
pub fn parse_utc_ms(s: &str) -> Option<u64> {
    let s = s.trim();
    if !s.is_empty() && s.bytes().all(|c| c.is_ascii_digit()) {
        return s.parse().ok();
    }
    let s = s.strip_suffix('Z')?;
    let (date, time) = s.split_once('T')?;
    let mut d = date.split('-');
    let (y, m, day): (i64, i64, i64) = (d.next()?.parse().ok()?, d.next()?.parse().ok()?, d.next()?.parse().ok()?);
    if d.next().is_some() || !(1..=12).contains(&m) || !(1..=31).contains(&day) {
        return None;
    }
    let (hms, frac) = match time.split_once('.') {
        Some((a, b)) => (a, Some(b)),
        None => (time, None),
    };
    let mut t = hms.split(':');
    let (hh, mm, ss): (u64, u64, u64) = (t.next()?.parse().ok()?, t.next()?.parse().ok()?, t.next()?.parse().ok()?);
    if t.next().is_some() || hh > 23 || mm > 59 || ss > 60 {
        return None;
    }
    let ms: u64 = match frac {
        Some(f) if !f.is_empty() && f.len() <= 3 && f.bytes().all(|c| c.is_ascii_digit()) => format!("{f:0<3}").parse().ok()?,
        Some(_) => return None,
        None => 0,
    };
    // days from civil (Howard Hinnant)
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y.rem_euclid(400);
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    let secs = u64::try_from(days).ok()? * 86400 + hh * 3600 + mm * 60 + ss;
    Some(secs * 1000 + ms)
}

/// Milliseconds since 1970 on the system clock.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(at: u64, dev: &str, kind: Kind) -> Event {
        Event::new(at, dev, kind)
    }
    fn place(doc: &str, div: &str) -> Kind {
        Kind::Place { doc: doc.into(), div: div.into(), by: By::Auto }
    }
    fn user_place(doc: &str, div: &str) -> Kind {
        Kind::Place { doc: doc.into(), div: div.into(), by: By::User }
    }
    fn assign(doc: &str, div: &str, seq: u32) -> Kind {
        Kind::Assign { doc: doc.into(), div: div.into(), seq }
    }
    fn retire(doc: &str, div: &str, seq: u32) -> Kind {
        Kind::Retire { doc: doc.into(), div: div.into(), seq }
    }
    fn call(r: &Resolved, doc: &str) -> Option<String> {
        r.doc(doc).and_then(|d| d.call.as_ref()).map(|c| c.text.clone())
    }

    #[test]
    fn lines_round_trip_and_have_the_documented_shape() {
        let all = [
            ev(1793600000000, "builder-recon", place("b3f1", "210")),
            ev(1793600000001, "builder-recon", assign("b3f1", "210", 1)),
            ev(1793600000002, "phone-7", Kind::Unsort { doc: "b3f1".into(), by: By::User }),
            ev(1793600000003, "phone-7", retire("b3f1", "210", 1)),
            ev(1793600000004, "phone-7", Kind::Title { doc: "b3f1".into(), title: "Well \"Water\" Handbook".into() }),
            ev(1793600000005, "phone-7", Kind::Remove { doc: "b3f1".into() }),
            ev(1793600000006, "phone-7", Kind::Restore { doc: "b3f1".into() }),
        ];
        for e in &all {
            assert_eq!(Event::from_line(&e.to_line()).as_ref(), Some(e), "{}", e.to_line());
        }
        assert_eq!(all[0].to_line(), r#"{"v":1,"at":1793600000000,"dev":"builder-recon","ev":"place","doc":"b3f1","div":"210","by":"auto"}"#);
        assert_eq!(all[1].to_line(), r#"{"v":1,"at":1793600000001,"dev":"builder-recon","ev":"assign","doc":"b3f1","div":"210","seq":1}"#);
        assert_eq!(all[2].to_line(), r#"{"v":1,"at":1793600000002,"dev":"phone-7","ev":"unsort","doc":"b3f1","by":"user"}"#);
        assert_eq!(all[3].to_line(), r#"{"v":1,"at":1793600000003,"dev":"phone-7","ev":"retire","doc":"b3f1","div":"210","seq":1}"#);
        assert_eq!(all[5].to_line(), r#"{"v":1,"at":1793600000005,"dev":"phone-7","ev":"remove","doc":"b3f1"}"#);
    }

    #[test]
    fn lines_a_reader_does_not_take_are_skipped() {
        assert!(Event::from_line("").is_none());
        assert!(Event::from_line(r#"{"v":2,"at":1,"dev":"d","ev":"place","doc":"x","div":"210","by":"auto"}"#).is_none());
        assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"explode","doc":"x"}"#).is_none());
        assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"place","doc":"x","div":"210","by":"robot"}"#).is_none());
        assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"assign","doc":"x","div":"210"}"#).is_none());
        // unknown extra keys are fine
        assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"remove","doc":"x","note":"later"}"#).is_some());
    }

    #[test]
    fn reserved_and_future_events_do_not_hide_known_events_or_change_resolution() {
        let expected = vec![
            ev(1, "d1", place("x", "210")),
            ev(2, "d1", assign("x", "210", 1)),
            ev(10, "d1", Kind::Title { doc: "x".into(), title: "Water handbook".into() }),
        ];
        let mut text = format!("{}\n{}\n", expected[0].to_line(), expected[1].to_line());
        for name in ["folder", "locate", "unlocate", "future_event"] {
            let event = serde_json::json!({"v": 1, "at": 3, "dev": "d1", "ev": name, "doc": "x", "future": true});
            text.push_str(&event.to_string());
            text.push('\n');
        }
        text.push_str(&expected[2].to_line());
        text.push('\n');

        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("log");
        std::fs::create_dir(&dir).unwrap();
        std::fs::write(dir.join("d1.jsonl"), text).unwrap();
        let set = read_logs(&dir).unwrap();
        assert_eq!(set.skipped, 4);
        assert_eq!(set.events, expected);
        let resolved = resolve(&set.events);
        assert_eq!(call(&resolved, "x").as_deref(), Some("CDS 210-001"));
        assert_eq!(resolved.doc("x").unwrap().title.as_deref(), Some("Water handbook"));
    }

    #[test]
    fn a_torn_last_line_is_skipped_and_the_next_append_does_not_glue_to_it() {
        let a = ev(1, "d1", place("x", "210")).to_line();
        let b = ev(2, "d1", assign("x", "210", 1)).to_line();
        let torn = &b[..b.len() - 9];
        let (events, skipped) = parse_log(&format!("{a}\n{torn}"));
        assert_eq!((events.len(), skipped), (1, 1));
        // on disk: the writer closes the torn line first, so the new event is read
        let tmp = tempfile::tempdir().unwrap();
        let w = LogWriter::open(&tmp.path().join("log"), "d1").unwrap();
        std::fs::write(w.path(), format!("{a}\n{torn}")).unwrap();
        w.append(&[ev(3, "d1", Kind::Remove { doc: "x".into() })]).unwrap();
        let set = read_logs(&tmp.path().join("log")).unwrap();
        assert_eq!(set.events.len(), 2);
        assert_eq!(set.skipped, 1);
        assert_eq!(set.events[1].kind, Kind::Remove { doc: "x".into() });
        // resolution works on what survived
        assert!(resolve(&set.events).doc("x").unwrap().removed);
    }

    #[test]
    fn append_adds_whole_lines_to_its_own_file_only() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("log");
        let w = LogWriter::open(&dir, "phone-1").unwrap();
        w.append(&[ev(1, "phone-1", place("a", "210")), ev(2, "phone-1", assign("a", "210", 1))]).unwrap();
        w.append(&[ev(3, "phone-1", Kind::Remove { doc: "a".into() })]).unwrap();
        let text = std::fs::read_to_string(dir.join("phone-1.jsonl")).unwrap();
        assert_eq!(text.lines().count(), 3);
        assert!(text.ends_with('\n'));
        // one writer per file
        assert!(w.append(&[ev(4, "phone-2", Kind::Remove { doc: "a".into() })]).is_err());
        assert!(LogWriter::open(&dir, "../evil").is_err());
        assert!(LogWriter::open(&dir, ".hidden").is_err());
        // every log in the folder is read, in file-name order; other files are ignored
        let w2 = LogWriter::open(&dir, "builder-x").unwrap();
        w2.append(&[ev(9, "builder-x", place("b", "320"))]).unwrap();
        std::fs::write(dir.join("notes.txt"), "not a log").unwrap();
        std::fs::write(dir.join(".phone-3.jsonl"), "{}").unwrap();
        let set = read_logs(&dir).unwrap();
        assert_eq!(set.files.iter().map(|f| f.0.as_str()).collect::<Vec<_>>(), ["builder-x.jsonl", "phone-1.jsonl"]);
        assert_eq!(set.events.len(), 4);
        assert!(read_logs(&tmp.path().join("nothing")).unwrap().events.is_empty());
    }

    #[test]
    fn a_book_is_shelved_numbered_and_unsorted() {
        let e = vec![
            ev(10, "d1", place("a", "210")),
            ev(11, "d1", assign("a", "210", 1)),
            ev(12, "d1", place("b", "210")),
            ev(13, "d1", assign("b", "210", 2)),
            ev(14, "d1", Kind::Unsort { doc: "c".into(), by: By::Auto }),
        ];
        let r = resolve(&e);
        assert_eq!(call(&r, "a").as_deref(), Some("CDS 210-001"));
        assert_eq!(call(&r, "b").as_deref(), Some("CDS 210-002"));
        let c = r.doc("c").unwrap();
        assert!(c.shelved && c.shelf.is_none() && c.call.is_none());
        assert_eq!(r.next_seq("210"), 3);
        assert_eq!(r.next_seq("320"), 1);
        // a book no event places is not shelved
        assert!(!resolve(&[ev(1, "d1", Kind::Title { doc: "z".into(), title: "T".into() })]).doc("z").unwrap().shelved);
    }

    #[test]
    fn two_devices_claiming_one_number_show_210_002_and_210_002_1() {
        // both read 210-001 as the highest and each took 002; the earlier claim holds the plain number
        let e = vec![
            ev(100, "phone", place("p", "210")),
            ev(101, "phone", assign("p", "210", 2)),
            ev(200, "server", place("s", "210")),
            ev(201, "server", assign("s", "210", 2)),
        ];
        let r = resolve(&e);
        assert_eq!(call(&r, "p").as_deref(), Some("CDS 210-002"));
        assert_eq!(call(&r, "s").as_deref(), Some("CDS 210-002.1"));
        let mut rev = e.clone();
        rev.reverse();
        let r2 = resolve(&rev);
        assert_eq!(call(&r2, "p"), call(&r, "p"));
        assert_eq!(call(&r2, "s"), call(&r, "s"));
        assert_eq!(r.doc("s").unwrap().call.as_ref().map(|c| (c.seq, c.suffix)), Some((2, 1)));
        // the next free number is still after the highest
        assert_eq!(r.next_seq("210"), 3);
    }

    #[test]
    fn retiring_rank_zero_leaves_the_others_where_they_are() {
        let e = vec![
            ev(100, "phone", place("p", "210")),
            ev(101, "phone", assign("p", "210", 2)),
            ev(200, "server", place("s", "210")),
            ev(201, "server", assign("s", "210", 2)),
            // p moves away: retire 210-002, place and assign in 320
            ev(300, "phone", user_place("p", "320")),
            ev(301, "phone", retire("p", "210", 2)),
            ev(302, "phone", assign("p", "320", 1)),
        ];
        let r = resolve(&e);
        assert_eq!(call(&r, "s").as_deref(), Some("CDS 210-002.1"), "rank 1 keeps its suffix");
        assert_eq!(call(&r, "p").as_deref(), Some("CDS 320-001"));
        assert_eq!(r.retired["210"].iter().copied().collect::<Vec<_>>(), [2]);
        assert_eq!(r.next_seq("210"), 3, "a retired number is never reused");
    }

    #[test]
    fn three_way_ties_on_at_are_resolved_by_doc() {
        let e = vec![
            ev(500, "d3", assign("zeta", "440", 7)),
            ev(500, "d1", assign("alpha", "440", 7)),
            ev(500, "d2", assign("mid", "440", 7)),
            ev(1, "d3", place("zeta", "440")),
            ev(1, "d1", place("alpha", "440")),
            ev(1, "d2", place("mid", "440")),
        ];
        let r = resolve(&e);
        assert_eq!(call(&r, "alpha").as_deref(), Some("CDS 440-007"));
        assert_eq!(call(&r, "mid").as_deref(), Some("CDS 440-007.1"));
        assert_eq!(call(&r, "zeta").as_deref(), Some("CDS 440-007.2"));
        let mut rev = e;
        rev.reverse();
        assert_eq!(resolve(&rev).docs.iter().map(|(k, v)| (k.clone(), v.call.clone())).collect::<Vec<_>>(), r.docs.iter().map(|(k, v)| (k.clone(), v.call.clone())).collect::<Vec<_>>());
    }

    #[test]
    fn a_tie_on_at_for_the_shelf_goes_to_the_later_device_id() {
        let e = vec![ev(50, "phone-a", user_place("x", "210")), ev(50, "phone-b", user_place("x", "320"))];
        assert_eq!(resolve(&e).doc("x").unwrap().shelf.as_deref(), Some("320"));
        let mut rev = e;
        rev.reverse();
        assert_eq!(resolve(&rev).doc("x").unwrap().shelf.as_deref(), Some("320"));
        // two events of one device at one millisecond keep the order they were written in
        let same = vec![ev(7, "d", place("y", "210")), ev(7, "d", place("y", "320"))];
        assert_eq!(resolve(&same).doc("y").unwrap().shelf.as_deref(), Some("320"));
    }

    #[test]
    fn a_move_retires_the_number_and_it_is_never_reused() {
        let e = vec![
            ev(1, "d", place("a", "210")),
            ev(2, "d", assign("a", "210", 1)),
            ev(3, "d", place("b", "210")),
            ev(4, "d", assign("b", "210", 2)),
            ev(10, "d", user_place("b", "320")),
            ev(11, "d", retire("b", "210", 2)),
            ev(12, "d", assign("b", "320", 1)),
        ];
        let r = resolve(&e);
        assert_eq!(call(&r, "b").as_deref(), Some("CDS 320-001"));
        assert_eq!(r.next_seq("210"), 3);
        // a book arriving in 210 later takes 3, not the retired 2
        let mut more = e.clone();
        more.push(ev(20, "d", place("c", "210")));
        more.push(ev(21, "d", assign("c", "210", resolve(&e).next_seq("210"))));
        assert_eq!(call(&resolve(&more), "c").as_deref(), Some("CDS 210-003"));
        // moving back takes a new number as well
        more.push(ev(30, "d", user_place("b", "210")));
        more.push(ev(31, "d", retire("b", "320", 1)));
        more.push(ev(32, "d", assign("b", "210", resolve(&more).next_seq("210"))));
        assert_eq!(call(&resolve(&more), "b").as_deref(), Some("CDS 210-004"));
    }

    #[test]
    fn nothing_renumbers_a_losing_assign_just_gets_a_suffix() {
        // one device resolves a clash without writing anything: the events are the same before and after
        let e = vec![ev(1, "a", place("x", "110")), ev(2, "a", assign("x", "110", 1)), ev(1, "b", place("y", "110")), ev(2, "b", assign("y", "110", 1))];
        let r = resolve(&e);
        assert_eq!((call(&r, "x").as_deref(), call(&r, "y").as_deref()), (Some("CDS 110-001"), Some("CDS 110-001.1")));
        assert_eq!(r.next_seq("110"), 2);
    }

    #[test]
    fn an_earlier_assign_arriving_late_shifts_the_ranks_once() {
        let first = vec![ev(100, "a", place("x", "110")), ev(101, "a", assign("x", "110", 5)), ev(200, "b", place("y", "110")), ev(201, "b", assign("y", "110", 5))];
        assert_eq!(call(&resolve(&first), "x").as_deref(), Some("CDS 110-005"));
        let mut late = first.clone();
        late.push(ev(50, "c", place("w", "110")));
        late.push(ev(51, "c", assign("w", "110", 5)));
        let r = resolve(&late);
        assert_eq!((call(&r, "w").as_deref(), call(&r, "x").as_deref(), call(&r, "y").as_deref()), (Some("CDS 110-005"), Some("CDS 110-005.1"), Some("CDS 110-005.2")));
    }

    #[test]
    fn numbers_are_padded_to_three_digits_and_grow_past_999() {
        assert_eq!(call_text("210", 1, 0), "CDS 210-001");
        assert_eq!(call_text("210", 999, 0), "CDS 210-999");
        assert_eq!(call_text("210", 1000, 0), "CDS 210-1000");
        assert_eq!(call_text("210", 1000, 2), "CDS 210-1000.2");
        let e = vec![
            ev(1, "d", place("a", "210")),
            ev(2, "d", assign("a", "210", 999)),
            ev(3, "d", place("b", "210")),
            ev(4, "d", assign("b", "210", 1000)),
            ev(5, "e", place("c", "210")),
            ev(6, "e", assign("c", "210", 1000)),
        ];
        let r = resolve(&e);
        assert_eq!(call(&r, "a").as_deref(), Some("CDS 210-999"));
        assert_eq!(call(&r, "b").as_deref(), Some("CDS 210-1000"));
        assert_eq!(call(&r, "c").as_deref(), Some("CDS 210-1000.1"));
        assert_eq!(r.next_seq("210"), 1001);
    }

    #[test]
    fn unsort_clears_the_number_and_a_later_place_wins_again() {
        let e = vec![
            ev(1, "d", place("a", "210")),
            ev(2, "d", assign("a", "210", 1)),
            ev(5, "d", Kind::Unsort { doc: "a".into(), by: By::User }),
            ev(6, "d", retire("a", "210", 1)),
        ];
        let r = resolve(&e);
        let a = r.doc("a").unwrap();
        assert!(a.shelved && a.shelf.is_none() && a.call.is_none());
        assert_eq!(a.by, Some(By::User));
        let mut again = e;
        again.push(ev(9, "d", user_place("a", "210")));
        again.push(ev(10, "d", assign("a", "210", 2)));
        assert_eq!(call(&resolve(&again), "a").as_deref(), Some("CDS 210-002"));
    }

    #[test]
    fn the_latest_title_wins_and_remove_and_restore_toggle() {
        let e = vec![
            ev(1, "a", Kind::Title { doc: "x".into(), title: "First".into() }),
            ev(3, "b", Kind::Title { doc: "x".into(), title: "Third".into() }),
            ev(2, "c", Kind::Title { doc: "x".into(), title: "Second".into() }),
            ev(10, "a", Kind::Remove { doc: "x".into() }),
        ];
        let r = resolve(&e);
        assert_eq!(r.doc("x").unwrap().title.as_deref(), Some("Third"));
        assert!(r.doc("x").unwrap().removed);
        let mut back = e.clone();
        back.push(ev(11, "b", Kind::Restore { doc: "x".into() }));
        assert!(!resolve(&back).doc("x").unwrap().removed);
        back.push(ev(12, "a", Kind::Remove { doc: "x".into() }));
        assert!(resolve(&back).doc("x").unwrap().removed);
        // an older restore does not undo a newer remove
        let old_restore = vec![ev(20, "a", Kind::Remove { doc: "x".into() }), ev(5, "b", Kind::Restore { doc: "x".into() })];
        assert!(resolve(&old_restore).doc("x").unwrap().removed);
    }

    #[test]
    fn corrections_are_user_places_that_differ_from_the_suggestion() {
        let e = vec![
            ev(1, "b", place("a", "210")),
            ev(2, "p", user_place("a", "320")),
            ev(3, "p", user_place("b", "440")),
            ev(4, "p", user_place("c", "100")),
            ev(5, "p", Kind::Unsort { doc: "d".into(), by: By::User }),
        ];
        let suggested = |d: &str| match d {
            "a" => Some("210".to_string()),
            "b" => Some("440".to_string()),
            _ => None,
        };
        let c = corrections(&e, &suggested);
        assert_eq!(c.iter().map(|c| (c.doc.as_str(), c.from.as_deref(), c.to.as_str())).collect::<Vec<_>>(), [("a", Some("210"), "320"), ("c", None, "100")]);
    }

    #[test]
    fn old_events_keep_their_wire_shape_and_folder_events_have_no_doc() {
        let old = r#"{"v":1,"at":7,"dev":"d","ev":"remove","doc":"book"}"#;
        let old_event = Event::from_line(old).unwrap();
        assert_eq!(old_event.kind, Kind::Remove { doc: "book".into() });
        assert_eq!(serde_json::from_str::<Value>(&old_event.to_line()).unwrap()["v"], 1);
        let folder = Event::new(8, "d", Kind::Folder { folder_id: "f".into(), label: "Books".into(), mode: FolderMode::Keep });
        let line = folder.to_line();
        assert!(serde_json::from_str::<Value>(&line).unwrap().get("doc").is_none());
        assert_eq!(Event::from_line(&line), Some(folder));
    }

    #[test]
    fn location_duplicates_moves_and_unlocates_resolve_by_stamp() {
        let locate = |at, path: &str| ev(at, "device", Kind::Locate { doc: "b3".into(), folder_id: "f".into(), relpath: path.into(), version: Some(2), source_blake3: Some("a".repeat(64)) });
        let events = vec![locate(1, "old/book.pdf"), locate(2, "new/book.pdf"), ev(3, "device", Kind::Unlocate { doc: "b3".into(), folder_id: "f".into(), relpath: "old/book.pdf".into() }), locate(4, "new/book.pdf")];
        let a = resolve(&events); let mut reversed = events.clone(); reversed.reverse(); let b = resolve(&reversed);
        assert_eq!(a.locations, b.locations);
        assert_eq!(a.locations["b3"].len(), 1);
        assert_eq!(a.locations["b3"][0].relpath, "new/book.pdf");
        let mut gone = events; gone.push(ev(5, "device", Kind::Unlocate { doc: "b3".into(), folder_id: "f".into(), relpath: "new/book.pdf".into() }));
        assert!(!resolve(&gone).locations.contains_key("b3"));
        assert!(!resolve(&gone).docs.contains_key(""));
    }

    #[test]
    fn unsafe_relative_paths_are_rejected_and_absolute_roots_never_serialize() {
        for path in ["", "/etc/passwd", "C:/Users/a.pdf", r"\\server\share\a.pdf", "../secret", "a/../../secret", r"a\b.pdf", "./a.pdf", "a//b.pdf"] { assert!(!valid_relpath(path), "accepted {path:?}"); }
        assert!(valid_relpath("Books/Firearms/Gunsmithing.pdf"));
        assert!(Event::from_line(r#"{"v":1,"at":1,"dev":"d","ev":"locate","doc":"x","folder_id":"f","relpath":"C:/secret.pdf"}"#).is_none());
        let tmp = tempfile::tempdir().unwrap();
        let writer = LogWriter::open(&tmp.path().join("log"), "d").unwrap();
        let invalid = Kind::Locate { doc: "x".into(), folder_id: "f".into(), relpath: "C:/secret.pdf".into(), version: None, source_blake3: None };
        assert!(writer.append(&[ev(1, "d", invalid)]).is_err());
    }

    #[test]
    fn utc_times_parse_to_milliseconds() {
        assert_eq!(parse_utc_ms("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_utc_ms("2000-03-01T00:00:00Z"), Some(951868800000));
        assert_eq!(parse_utc_ms("2026-11-02T12:34:56.789Z"), Some(1793622896789));
        assert_eq!(parse_utc_ms("1793600000000"), Some(1793600000000));
        assert_eq!(parse_utc_ms("2026-13-02T00:00:00Z"), None);
        assert_eq!(parse_utc_ms("yesterday"), None);
        assert_eq!(parse_utc_ms(""), None);
    }
}
