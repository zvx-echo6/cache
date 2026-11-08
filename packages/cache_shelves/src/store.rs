//! Writing and reading the Bookshelves log's files: one file per device, `<bookshelves>/log/<device_id>.jsonl`.
//!
//! Nothing that syncs ever has two writers, so each device appends only to its own file and every device resolves the same answer
//! from all the files.

use crate::error::{Error, Result};
use crate::events::{check_for_write, valid_device_id, Event};
use std::io::Write;
use std::path::{Path, PathBuf};

/// The folder of the logs, inside the Bookshelves folder.
pub const LOG_DIR: &str = "log";
pub const LOG_EXT: &str = "jsonl";
/// The local folder (never synced; a name starting with a dot): the view and the migration record.
pub const LOCAL_DIR: &str = ".local";

/// Milliseconds since 1970 on the system clock.
pub fn now_ms() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// The writer of one device's log. One writer per file: it refuses events from another device.
#[derive(Debug, Clone)]
pub struct LogWriter {
    path: PathBuf,
    dev: String,
}

impl LogWriter {
    /// The log of `dev` in `dir` (the Bookshelves `log/` folder, made when missing).
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

    /// Appends the events as lines, all in one write, and flushes them to disk. Returns the events as written.
    ///
    /// - A clock set back is held: no event gets an `at` earlier than this device's own last one in the file (or than the event
    ///   before it in the batch).
    /// - If the file ends in a torn line (no line break), that line is closed first so the new lines are not glued to it.
    /// - Events that fail the write checks (a bad linked-folder path, a copy linked with itself) are refused, and nothing is written.
    pub fn append(&self, events: &[Event]) -> Result<Vec<Event>> {
        self.append_with(events, true)
    }

    /// Like [`LogWriter::append`] but keeps every event's `at` as given (no clock hold). For the one-time import of old events,
    /// whose order comes from (`at`, `dev`, position), not from where they sit in the file.
    pub fn append_unclamped(&self, events: &[Event]) -> Result<Vec<Event>> {
        self.append_with(events, false)
    }

    fn append_with(&self, events: &[Event], hold_clock: bool) -> Result<Vec<Event>> {
        if events.is_empty() {
            return Ok(Vec::new());
        }
        for e in events {
            if e.dev != self.dev {
                return Err(Error::new(format!("the log of {} takes no events from {}", self.dev, e.dev)));
            }
            if let Some(why) = check_for_write(e) {
                return Err(Error::new(why));
            }
        }
        let ctx = |e: std::io::Error| Error::ctx(&format!("writing {}", self.path.display()), e);
        let existing = match std::fs::read(&self.path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Vec::new(),
            Err(e) => return Err(ctx(e)),
        };
        let (own, _) = parse_log(&String::from_utf8_lossy(&existing));
        let mut last = own.iter().filter(|e| e.dev == self.dev).map(|e| e.at).max().unwrap_or(0);
        let mut written = Vec::with_capacity(events.len());
        let mut buf = String::new();
        if !existing.is_empty() && existing.last() != Some(&b'\n') {
            buf.push('\n');
        }
        for e in events {
            let mut e = e.clone();
            if hold_clock {
                e.at = e.at.max(last);
            }
            last = e.at;
            buf.push_str(&e.to_line());
            buf.push('\n');
            written.push(e);
        }
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(&self.path).map_err(ctx)?;
        f.write_all(buf.as_bytes()).map_err(ctx)?;
        f.sync_data().map_err(ctx)?;
        Ok(written)
    }
}

/// Every event of every log in a folder.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct LogSet {
    /// In file-name order, then line order.
    pub events: Vec<Event>,
    /// Each log file's name and size in bytes.
    pub files: Vec<(String, u64)>,
    /// Lines that were not events (a torn last line, an unknown event or version).
    pub skipped: usize,
}

fn parse_with(text: &str, f: impl Fn(&str) -> Option<Event>) -> (Vec<Event>, usize) {
    let mut events = Vec::new();
    let mut skipped = 0;
    for line in text.split('\n') {
        if line.trim().is_empty() {
            continue;
        }
        match f(line) {
            Some(e) => events.push(e),
            None => skipped += 1,
        }
    }
    (events, skipped)
}

/// The events in `text`, and how many lines were skipped. A torn last line (cut off by a crash) is skipped like any other line
/// that is not an event.
pub fn parse_log(text: &str) -> (Vec<Event>, usize) {
    parse_with(text, Event::from_line)
}

/// The same for an old library log or a seed log (`doc` in place of `copy`).
pub fn parse_legacy_log(text: &str) -> (Vec<Event>, usize) {
    parse_with(text, Event::from_legacy_line)
}

/// The names of the `*.jsonl` files in `dir`, sorted (none when the folder is missing).
pub fn log_file_names(dir: &Path) -> Result<Vec<String>> {
    let rd = match std::fs::read_dir(dir) {
        Ok(rd) => rd,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(e) => return Err(Error::ctx(&format!("reading {}", dir.display()), e)),
    };
    let mut names: Vec<String> = rd
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !n.starts_with('.') && n.ends_with(&format!(".{LOG_EXT}")))
        .collect();
    names.sort();
    Ok(names)
}

/// Reads every `*.jsonl` in `dir` (none when the folder is missing).
pub fn read_logs(dir: &Path) -> Result<LogSet> {
    let mut set = LogSet::default();
    for name in log_file_names(dir)? {
        let bytes = std::fs::read(dir.join(&name)).map_err(|e| Error::ctx(&format!("reading {name}"), e))?;
        let (events, skipped) = parse_log(&String::from_utf8_lossy(&bytes));
        set.events.extend(events);
        set.skipped += skipped;
        set.files.push((name, bytes.len() as u64));
    }
    Ok(set)
}

/// Writes `bytes` to `path` atomically: a temporary file in the same folder, flushed to disk, then renamed over the name.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().ok_or_else(|| Error::new("no folder"))?;
    std::fs::create_dir_all(dir).map_err(|e| Error::ctx(&format!("creating {}", dir.display()), e))?;
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.tmp"));
    let write = || -> std::io::Result<()> {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        std::fs::rename(&tmp, path)
    };
    write().map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        Error::ctx(&format!("writing {}", path.display()), e)
    })
}
