//! The events of the Bookshelves log (`<app support>/bookshelves/log/<device_id>.jsonl`). See server/builder/LIBRARY-LOG.md.
//!
//! One event per line, UTF-8, `\n` after every line. Every event has `v` (1), `at` (UTC milliseconds), `dev` (the writing device)
//! and `ev` (the name). The content key is `copy` (the pack's `original_blake3`, else its `doc_id`); an event may carry `loc`
//! (`<library_id>/<doc_id>`) for readability and lookup. A reader skips a line it does not take: not JSON (a torn line), another
//! `v`, an event it does not know, a missing field. Unknown extra keys are ignored.

use serde_json::{json, Map, Value};

/// The `v` of every event.
pub const LOG_VERSION: u64 = 1;
/// The prefix of the call number.
pub const CALL_PREFIX: &str = "CDS";

/// Who made a decision: the sorter or the same-book detector (`auto`), or a person (`user`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
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

    pub fn parse(s: &str) -> Option<By> {
        match s {
            "auto" => Some(By::Auto),
            "user" => Some(By::User),
            _ => None,
        }
    }
}

/// How two copies were found to be one book.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum How {
    /// The same file content hash.
    Blake3,
    /// The text fingerprint and the mean meaning vector agreed.
    Text,
    /// A person said so.
    User,
}

impl How {
    pub fn as_str(self) -> &'static str {
        match self {
            How::Blake3 => "blake3",
            How::Text => "text",
            How::User => "user",
        }
    }

    pub fn parse(s: &str) -> Option<How> {
        match s {
            "blake3" => Some(How::Blake3),
            "text" => Some(How::Text),
            "user" => Some(How::User),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum FolderMode {
    Keep,
    Cds,
    Both,
}

impl FolderMode {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Keep => "keep",
            Self::Cds => "cds",
            Self::Both => "both",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "keep" => Some(Self::Keep),
            "cds" => Some(Self::Cds),
            "both" => Some(Self::Both),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum Kind {
    /// The book that holds `copy` goes on the shelf of division `div`.
    Place { copy: String, div: String, by: By },
    /// The book goes to Unsorted.
    Unsort { copy: String, by: By },
    /// `copy` takes call number `seq` in `div`.
    Assign { copy: String, div: String, seq: u32 },
    /// `copy` gives up call number `seq` in `div` (never used again).
    Retire { copy: String, div: String, seq: u32 },
    Title { copy: String, title: String },
    /// Hides the book on every device of the person; deletes no files.
    Remove { copy: String },
    Restore { copy: String },
    /// The two copies are one book.
    Same { copy: String, with: String, by: By, how: How, score: Option<f64> },
    /// The two copies are different books ("Not the same book").
    NotSame { copy: String, with: String, by: By },
    /// Use this copy for reading its book.
    Prefer { copy: String },
    /// A device-local linked folder. This event deliberately has no copy.
    Folder { folder_id: String, label: String, mode: FolderMode },
    /// A copy is present at a relative path in a linked folder.
    Locate { copy: String, folder_id: String, relpath: String, version: Option<u32>, source_blake3: Option<String> },
    /// A copy is no longer present at a relative path in a linked folder.
    Unlocate { copy: String, folder_id: String, relpath: String },
}

impl Kind {
    /// The copy the event is about (`None` for `folder`).
    pub fn copy(&self) -> Option<&str> {
        match self {
            Kind::Place { copy, .. }
            | Kind::Unsort { copy, .. }
            | Kind::Assign { copy, .. }
            | Kind::Retire { copy, .. }
            | Kind::Title { copy, .. }
            | Kind::Remove { copy }
            | Kind::Restore { copy }
            | Kind::Same { copy, .. }
            | Kind::NotSame { copy, .. }
            | Kind::Prefer { copy }
            | Kind::Locate { copy, .. }
            | Kind::Unlocate { copy, .. } => Some(copy),
            Kind::Folder { .. } => None,
        }
    }

    pub fn copy_mut(&mut self) -> Option<&mut String> {
        match self {
            Kind::Place { copy, .. }
            | Kind::Unsort { copy, .. }
            | Kind::Assign { copy, .. }
            | Kind::Retire { copy, .. }
            | Kind::Title { copy, .. }
            | Kind::Remove { copy }
            | Kind::Restore { copy }
            | Kind::Same { copy, .. }
            | Kind::NotSame { copy, .. }
            | Kind::Prefer { copy }
            | Kind::Locate { copy, .. }
            | Kind::Unlocate { copy, .. } => Some(copy),
            Kind::Folder { .. } => None,
        }
    }

    pub fn name(&self) -> &'static str {
        match self {
            Kind::Place { .. } => "place",
            Kind::Unsort { .. } => "unsort",
            Kind::Assign { .. } => "assign",
            Kind::Retire { .. } => "retire",
            Kind::Title { .. } => "title",
            Kind::Remove { .. } => "remove",
            Kind::Restore { .. } => "restore",
            Kind::Same { .. } => "same",
            Kind::NotSame { .. } => "notsame",
            Kind::Prefer { .. } => "prefer",
            Kind::Folder { .. } => "folder",
            Kind::Locate { .. } => "locate",
            Kind::Unlocate { .. } => "unlocate",
        }
    }
}

/// One line of a log: when (UTC milliseconds), who wrote it, what happened, and optionally where the copy was found.
#[derive(Debug, Clone, PartialEq)]
pub struct Event {
    pub at: u64,
    pub dev: String,
    /// `<library_id>/<doc_id>`: where the copy was found when the event was written. Never the key.
    pub loc: Option<String>,
    pub kind: Kind,
}

impl Event {
    pub fn new(at: u64, dev: &str, kind: Kind) -> Event {
        Event { at, dev: dev.to_string(), loc: None, kind }
    }

    pub fn with_loc(mut self, loc: &str) -> Event {
        self.loc = Some(loc.to_string());
        self
    }

    /// The JSON line (no line break): `{"v":1,"at":...,"dev":"...","ev":"place","copy":"...",...}`.
    pub fn to_line(&self) -> String {
        let mut m = Map::new();
        m.insert("v".into(), json!(LOG_VERSION));
        m.insert("at".into(), json!(self.at));
        m.insert("dev".into(), json!(self.dev));
        m.insert("ev".into(), json!(self.kind.name()));
        if let Some(copy) = self.kind.copy() {
            m.insert("copy".into(), json!(copy));
        }
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
            Kind::Same { with, by, how, score, .. } => {
                m.insert("with".into(), json!(with));
                m.insert("by".into(), json!(by.as_str()));
                m.insert("how".into(), json!(how.as_str()));
                if let Some(s) = score {
                    m.insert("score".into(), json!(s));
                }
            }
            Kind::NotSame { with, by, .. } => {
                m.insert("with".into(), json!(with));
                m.insert("by".into(), json!(by.as_str()));
            }
            Kind::Folder { folder_id, label, mode } => {
                m.insert("folder_id".into(), json!(folder_id));
                m.insert("label".into(), json!(label));
                m.insert("mode".into(), json!(mode.as_str()));
            }
            Kind::Locate { folder_id, relpath, version, source_blake3, .. } => {
                m.insert("folder_id".into(), json!(folder_id));
                m.insert("relpath".into(), json!(relpath));
                if let Some(v) = version {
                    m.insert("version".into(), json!(v));
                }
                if let Some(h) = source_blake3 {
                    m.insert("source_blake3".into(), json!(h));
                }
            }
            Kind::Unlocate { folder_id, relpath, .. } => {
                m.insert("folder_id".into(), json!(folder_id));
                m.insert("relpath".into(), json!(relpath));
            }
            Kind::Remove { .. } | Kind::Restore { .. } | Kind::Prefer { .. } => {}
        }
        if let Some(loc) = &self.loc {
            m.insert("loc".into(), json!(loc));
        }
        Value::Object(m).to_string()
    }

    /// Reads one line of the Bookshelves log. `None` for anything this reader does not take (a torn line, another `v`, an event it
    /// does not know, a missing field). A reader skips such a line and goes on.
    pub fn from_line(line: &str) -> Option<Event> {
        let v: Value = serde_json::from_str(line.trim()).ok()?;
        Event::from_value(&v)
    }

    /// Reads one event from a parsed JSON object (the line's shape).
    pub fn from_value(v: &Value) -> Option<Event> {
        parse(v, "copy", false)
    }

    /// Reads one line of an old library log or a seed log (`doc` in place of `copy`; only the events those logs have). The
    /// result's `copy` holds the `doc_id`, to be mapped by the caller.
    pub fn from_legacy_line(line: &str) -> Option<Event> {
        let v: Value = serde_json::from_str(line.trim()).ok()?;
        parse(&v, "doc", true)
    }
}

fn parse(v: &Value, key: &str, legacy: bool) -> Option<Event> {
    if v.get("v")?.as_u64()? != LOG_VERSION {
        return None;
    }
    let at = v.get("at")?.as_u64()?;
    let dev = v.get("dev")?.as_str()?.to_string();
    if dev.is_empty() {
        return None;
    }
    let text = |k: &str| v.get(k).and_then(Value::as_str).map(str::to_string);
    let copy = || text(key).filter(|d| !d.is_empty());
    let seq = || v.get("seq").and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok());
    let folder_id = || text("folder_id").filter(|s| !s.is_empty());
    let relpath = || text("relpath").filter(|s| valid_relpath(s));
    let by = || By::parse(&text("by")?);
    let kind = match v.get("ev")?.as_str()? {
        "place" => Kind::Place { copy: copy()?, div: text("div")?, by: by()? },
        "unsort" => Kind::Unsort { copy: copy()?, by: by()? },
        "assign" => Kind::Assign { copy: copy()?, div: text("div")?, seq: seq()? },
        "retire" => Kind::Retire { copy: copy()?, div: text("div")?, seq: seq()? },
        "title" => Kind::Title { copy: copy()?, title: text("title")? },
        "remove" => Kind::Remove { copy: copy()? },
        "restore" => Kind::Restore { copy: copy()? },
        "same" if !legacy => {
            let (c, with) = (copy()?, text("with").filter(|w| !w.is_empty())?);
            if c == with {
                return None;
            }
            Kind::Same { copy: c, with, by: by()?, how: How::parse(&text("how")?)?, score: v.get("score").and_then(Value::as_f64) }
        }
        "notsame" if !legacy => {
            let (c, with) = (copy()?, text("with").filter(|w| !w.is_empty())?);
            if c == with {
                return None;
            }
            Kind::NotSame { copy: c, with, by: by()? }
        }
        "prefer" if !legacy => Kind::Prefer { copy: copy()? },
        "folder" => Kind::Folder { folder_id: folder_id()?, label: text("label")?, mode: FolderMode::parse(&text("mode")?)? },
        "locate" => {
            let version = v.get("version").and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok());
            let source_blake3 = text("source_blake3").filter(|h| valid_blake3(h));
            if v.get("version").is_some() && version.is_none() || v.get("source_blake3").is_some() && source_blake3.is_none() {
                return None;
            }
            Kind::Locate { copy: copy()?, folder_id: folder_id()?, relpath: relpath()?, version, source_blake3 }
        }
        "unlocate" => Kind::Unlocate { copy: copy()?, folder_id: folder_id()?, relpath: relpath()? },
        _ => return None,
    };
    let loc = if legacy { None } else { text("loc").filter(|l| !l.is_empty()) };
    Some(Event { at, dev, loc, kind })
}

fn valid_blake3(h: &str) -> bool {
    h.len() == 64 && h.bytes().all(|b| b.is_ascii_hexdigit())
}

/// A portable normalized relative path using `/` separators. Absolute roots, traversal, drive/ADS syntax, empty components and
/// backslashes are rejected before a location can enter a synced log.
pub fn valid_relpath(path: &str) -> bool {
    !path.is_empty()
        && !path.starts_with('/')
        && !path.contains('\\')
        && !path.contains(':')
        && !path.chars().any(|c| c.is_control())
        && path.split('/').all(|part| !part.is_empty() && part != "." && part != "..")
}

/// A device id is used in a file name: letters, digits, `.`, `_` and `-`, at most 64, not starting with a dot.
pub fn valid_device_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && !id.starts_with('.') && id.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-'))
}

/// Why an event cannot be written, or `None` when it can.
pub fn check_for_write(e: &Event) -> Option<&'static str> {
    if e.kind.copy().is_some_and(str::is_empty) {
        return Some("an event needs a copy");
    }
    match &e.kind {
        Kind::Locate { folder_id, relpath, source_blake3, .. } => {
            if folder_id.is_empty() || !valid_relpath(relpath) || source_blake3.as_ref().is_some_and(|h| !valid_blake3(h)) {
                return Some("invalid linked-folder location; paths must be safe relative paths");
            }
        }
        Kind::Unlocate { folder_id, relpath, .. } => {
            if folder_id.is_empty() || !valid_relpath(relpath) {
                return Some("invalid linked-folder location; paths must be safe relative paths");
            }
        }
        Kind::Folder { folder_id, .. } if folder_id.is_empty() => return Some("linked-folder id must not be empty"),
        Kind::Same { copy, with, .. } | Kind::NotSame { copy, with, .. } if copy == with || with.is_empty() => {
            return Some("a same or notsame event needs two different copies");
        }
        Kind::Place { div, .. } | Kind::Assign { div, .. } | Kind::Retire { div, .. } if div.is_empty() => return Some("a division must not be empty"),
        _ => {}
    }
    None
}
