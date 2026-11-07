//! The service's side of the per-device library log (server/builder/LIBRARY-LOG.md).
//!
//! The server is one device, with the cache_sync identity kept in `<data>/sync`. It appends to `<library>/log/<device_id>.jsonl` (only it writes that file), reads every device's log
//! to decide which call number is free, and makes the local view `<library>/.local/docs.json` from the packs and the logs.
//!
//! - After a book is built, `place` and `assign` are appended (by `auto`), or `unsort` when the classifier was unsure.
//! - "Place it" and every move appends `place` (by `user`), `retire` of the old number and `assign` of a new one.
//! - A rename appends `title`.
//! - At publish, books the log has never seen (built before the log existed) are shelved, the call numbers kept in the library's
//!   books are refreshed from all the logs, and the view is made again. The view is also made again after a placement, a rename
//!   and a delete.
//!
//! A call number is resolved from the logs and shown as it is at that moment; the name of a filed PDF is made when the book is
//! filed or moved, so a number that later gains or loses a `.k` suffix (another device claimed the same number) does not rename it.

use super::*;
use cache_builder::log::{now_ms, read_logs, resolve, valid_device_id, Event, Kind, LogWriter, LOG_DIR};
use cache_builder::view::rebuild_view;
use std::collections::BTreeMap;

/// The folder of Cache on Linux's sync identity, `<data>/sync`: `identity.key` (the device's iroh key pair) lives here, and so will
/// anything else sync keeps for this device. It is the one place; the library log and any later sync use the same identity.
pub const SYNC_DIR: &str = "sync";

/// The device id used when the identity cannot be made or read (a full or read-only disk): one fixed name, so the log is still
/// written by one writer to one file.
const UNSYNCED_ID: &str = "unsynced";

/// This server's device id: the cache_sync identity in `<data>/sync` (made the first time, read back after that), as the EndpointId's
/// text (lower-case letters and digits). It names the library log, `log/<device_id>.jsonl`. A reinstall that loses the key starts a
/// new id and so a new log file; the old one stays and its events still count. The random `server-<hex>` id of earlier builds
/// (`<data>/build/device_id`) is no longer read or written; its log file is left alone.
pub(crate) fn load_device_id(data: &Path) -> String {
    match cache_sync::identity::load_or_create(&data.join(SYNC_DIR)) {
        Ok((_, id)) if valid_device_id(&id) => id,
        Ok((_, id)) => {
            eprintln!("cache: the sync identity {id:?} is not usable as a log name; using {UNSYNCED_ID}");
            UNSYNCED_ID.to_string()
        }
        Err(e) => {
            eprintln!("cache: could not load the sync identity ({e}); using {UNSYNCED_ID}");
            UNSYNCED_ID.to_string()
        }
    }
}

impl BuildService {
    fn log_dir(&self, lib: &str) -> PathBuf {
        self.live_dir(lib).join(LOG_DIR)
    }

    /// Never earlier than this device's own last event, so a clock set back cannot put a new event before an old one.
    fn next_at(&self, events: &[Event]) -> u64 {
        let last = events.iter().filter(|e| e.dev == self.device).map(|e| e.at).max().unwrap_or(0);
        now_ms().max(last)
    }

    /// Shelves books in this device's log. Each item is (doc, division or None for Unsorted, by). For a division: `place` when the
    /// book is not already on that shelf, `retire` of the number it held in another division, and `assign` of the next free number
    /// (1 + the highest ever assigned or retired there, counting every device's log). For Unsorted: `unsort` and `retire`. A book
    /// that is already where it should be, with its number, gets nothing. Returns each book's call number afterwards (an empty
    /// string in Unsorted).
    pub(crate) fn shelve_batch(&self, lib: &str, items: &[(String, Option<String>, By)]) -> Result<BTreeMap<String, String>, String> {
        let dir = self.log_dir(lib);
        let w = LogWriter::open(&dir, &self.device).map_err(|e| e.to_string())?;
        let set = read_logs(&dir).map_err(|e| e.to_string())?;
        let before = resolve(&set.events);
        let at = self.next_at(&set.events);
        let ev = |kind: Kind| Event::new(at, &self.device, kind);
        let mut next: BTreeMap<String, u32> = BTreeMap::new();
        let mut new: Vec<Event> = Vec::new();
        for (doc, division, by) in items {
            let cur = before.doc(doc);
            let cur_call = cur.and_then(|c| c.call.clone());
            match division {
                Some(d) => {
                    let on_shelf = cur.is_some_and(|c| c.shelf.as_deref() == Some(d.as_str()));
                    if on_shelf && cur_call.is_some() {
                        continue;
                    }
                    if !on_shelf {
                        new.push(ev(Kind::Place { doc: doc.clone(), div: d.clone(), by: *by }));
                    }
                    if let Some(c) = cur_call.as_ref().filter(|c| c.div != *d) {
                        new.push(ev(Kind::Retire { doc: doc.clone(), div: c.div.clone(), seq: c.seq }));
                    }
                    let n = next.entry(d.clone()).or_insert_with(|| before.next_seq(d));
                    let seq = *n;
                    *n += 1;
                    new.push(ev(Kind::Assign { doc: doc.clone(), div: d.clone(), seq }));
                }
                None => {
                    let unsorted = cur.is_some_and(|c| c.shelved && c.shelf.is_none());
                    if unsorted && cur_call.is_none() {
                        continue;
                    }
                    new.push(ev(Kind::Unsort { doc: doc.clone(), by: *by }));
                    if let Some(c) = &cur_call {
                        new.push(ev(Kind::Retire { doc: doc.clone(), div: c.div.clone(), seq: c.seq }));
                    }
                }
            }
        }
        w.append(&new).map_err(|e| e.to_string())?;
        let mut all = set.events;
        all.extend(new);
        let after = resolve(&all);
        Ok(items.iter().map(|(doc, _, _)| (doc.clone(), after.doc(doc).and_then(|d| d.call.as_ref()).map(|c| c.text.clone()).unwrap_or_default())).collect())
    }

    /// Appends a `title` event.
    pub(crate) fn log_title(&self, lib: &str, doc: &str, title: &str) -> Result<(), String> {
        let dir = self.log_dir(lib);
        let w = LogWriter::open(&dir, &self.device).map_err(|e| e.to_string())?;
        let set = read_logs(&dir).map_err(|e| e.to_string())?;
        let at = self.next_at(&set.events);
        w.append(&[Event::new(at, &self.device, Kind::Title { doc: doc.to_string(), title: title.to_string() })]).map_err(|e| e.to_string())
    }

    /// Shelves the books no log has placed yet (built before the log existed): by their division, `user` when a person placed them.
    fn shelve_missing(&self, lib: &str) -> Result<(), String> {
        let books: Vec<(String, Option<String>, bool)> = lock(&self.st)
            .libs
            .iter()
            .find(|l| l.id == lib)
            .map(|l| l.books.iter().map(|b| (b.doc_id.clone(), b.division.clone(), b.placed)).collect())
            .unwrap_or_default();
        if books.is_empty() {
            return Ok(());
        }
        let known = resolve(&read_logs(&self.log_dir(lib)).map_err(|e| e.to_string())?.events);
        let todo: Vec<(String, Option<String>, By)> = books
            .into_iter()
            .filter(|(doc, _, _)| !known.doc(doc).is_some_and(|d| d.shelved))
            .map(|(doc, div, placed)| (doc, div, if placed { By::User } else { By::Auto }))
            .collect();
        if todo.is_empty() {
            return Ok(());
        }
        self.shelve_batch(lib, &todo).map(|_| ())
    }

    /// Sets each book's `call_text` from all the logs; saves the library when any changed.
    fn refresh_calls(&self, lib: &str) -> Result<(), String> {
        let resolved = resolve(&read_logs(&self.log_dir(lib)).map_err(|e| e.to_string())?.events);
        let mut st = lock(&self.st);
        let Some(m) = st.libs.iter_mut().find(|l| l.id == lib) else { return Ok(()) };
        let mut changed = false;
        for b in m.books.iter_mut() {
            let want = resolved.doc(&b.doc_id).and_then(|d| d.call.as_ref()).map(|c| c.text.clone());
            if b.call_text != want {
                b.call_text = want;
                changed = true;
            }
        }
        if changed {
            let m = m.clone();
            self.save_meta(&m).map_err(|e| format!("saving the library: {e}"))?;
        }
        Ok(())
    }

    /// Makes `<library>/.local/docs.json` again from the packs and the logs. A failure is reported and goes no further: the view
    /// is made from files that are there, so the next change makes it again.
    pub(crate) fn rebuild_view_quietly(&self, lib: &str) {
        let packs = self.packs_dir(lib);
        if !packs.is_dir() {
            return;
        }
        if let Err(e) = rebuild_view(&self.live_dir(lib), &packs) {
            eprintln!("cache: writing the local view of {lib}: {e}");
        }
    }

    /// What publishing does for the log: shelve books it has never seen, refresh the call numbers, make the view again.
    pub(crate) fn catch_up(&self, lib: &str) {
        if let Err(e) = self.shelve_missing(lib) {
            eprintln!("cache: shelving the books of {lib}: {e}");
        }
        if let Err(e) = self.refresh_calls(lib) {
            eprintln!("cache: call numbers of {lib}: {e}");
        }
        self.rebuild_view_quietly(lib);
    }
}
