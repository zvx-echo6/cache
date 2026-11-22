//! The service's side of the person's Bookshelves log (crate `cache_shelves`; server/builder/LIBRARY-LOG.md).
//!
//! The server is one device, with the cache_sync identity kept in `<data>/sync`. Its Bookshelves folder is `<data>/bookshelves/`:
//! `log/<device_id>.jsonl` (only this server writes that file; other devices' files sync in beside it), `.local/view.json` (the
//! resolved view, never synced) and `.local/migrated.json` (which old library logs were imported). Events are keyed by the copy
//! (`cache_shelves::library::copy_key`: the pack's `original_blake3`, else its `doc_id`) and carry `loc` = `<library_id>/<doc_id>`.
//! The libraries it resolves against are every library folder in `<data>/app/docs/libraries` (the ones it builds and the ones that
//! were installed), read through their `copies.jsonl`, else their packs. Seed logs (`log/builder-<id>.jsonl`) are read only as
//! suggestions, by `cache_shelves`.
//!
//! - At start-up the service makes each library's `copies.jsonl` again from its packs, then imports its OWN events from every
//!   library's old `log/<device_id>.jsonl` once (`cache_shelves::import`). Library logs are never written after that.
//! - After a book is built: same-book detection once for the new copy, against every copy the service can see, writes
//!   `same ... by:auto` for each match. A copy that joins a book already on a shelf takes that book's shelf and number; any other
//!   gets `place` and `assign` (by `auto`), or `unsort` when the classifier was unsure.
//! - A better file that replaces a book writes `same` (by `auto`, or by `user` when the person chose "Replace the older one"), so the
//!   new copy keeps the book's shelf and number; "Keep both" writes `notsame` by `user`.
//! - "Place it" and every move appends `place` (by `user`), `retire` of the old number and `assign` of a new one, against the copy
//!   that holds the book's number. A rename appends `title`.
//! - At publish, `copies.jsonl` is made again, books no event has shelved are shelved, the call numbers kept in the library's books
//!   are refreshed from the log, and the view is made again. The view is also made again after a placement, a rename and a delete.
//!
//! A call number is resolved from the log and shown as it is at that moment; the name of a filed PDF is made when the book is filed
//! or moved, so a number that later gains or loses a `.k` suffix (another device claimed the same number) does not rename it.

use super::*;
use cache_builder::bookshelves::{header_line, library_ref};
use cache_shelves::batch::find_pairs;
use cache_shelves::events::{valid_device_id, By, Event, How, Kind};
use cache_shelves::import::import_own;
use cache_shelves::library::{load_library, LibraryInput, LibraryRef, PackFacts, COPIES_FILE};
use cache_shelves::resolve::{resolve, Book as ShelfBook, Resolved};
use cache_shelves::store::{now_ms, read_logs, LogWriter, LOG_DIR};
use cache_shelves::view::{view_value, write_view};
use std::collections::{BTreeMap, BTreeSet};

/// The folder of Cache on Linux's sync identity, `<data>/sync`: `identity.key` (the device's iroh key pair) lives here, and so will
/// anything else sync keeps for this device. It is the one place; the Bookshelves log and any later sync use the same identity.
pub const SYNC_DIR: &str = "sync";

/// The person's Bookshelves folder, `<data>/bookshelves` (`log/`, `.local/`).
pub const BOOKSHELVES_DIR: &str = "bookshelves";

/// The device id used when the identity cannot be made or read (a full or read-only disk): one fixed name, so the log is still
/// written by one writer to one file.
const UNSYNCED_ID: &str = "unsynced";

/// This server's device id: the cache_sync identity in `<data>/sync` (made the first time, read back after that), as the EndpointId's
/// text (lower-case letters and digits). It names the Bookshelves log, `log/<device_id>.jsonl`. A reinstall that loses the key starts
/// a new id and so a new log file; the old one stays and its events still count. The random `server-<hex>` id of earlier builds
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

/// The two copies of a pair, smaller key first.
fn pair_key(a: &str, b: &str) -> (String, String) {
    if a <= b {
        (a.to_string(), b.to_string())
    } else {
        (b.to_string(), a.to_string())
    }
}

/// The Bookshelves log and the libraries, read and resolved.
pub(crate) struct Shelves {
    pub events: Vec<Event>,
    /// The log files (name and size).
    pub files: Vec<(String, u64)>,
    pub libs: Vec<LibraryInput>,
    pub resolved: Resolved,
}

impl Shelves {
    /// The copy key of `doc` in the library folder `dir`.
    pub fn copy_of(&self, dir: &Path, doc: &str) -> Option<String> {
        self.libs.iter().find(|l| l.dir == dir)?.copies.iter().find(|c| c.doc_id == doc).map(|c| c.copy.clone())
    }

    /// The book that holds `copy`.
    pub fn book(&self, copy: &str) -> Option<&ShelfBook> {
        self.resolved.book_of(copy)
    }

    /// Where a copy is found (`<library_id>/<doc_id>`, the first library that holds it), for an event's `loc`.
    pub fn loc(&self, copy: &str) -> Option<String> {
        self.libs.iter().find_map(|l| l.copies.iter().find(|c| c.copy == copy).map(|c| format!("{}/{}", l.library_id, c.doc_id)))
    }
}

/// A new copy that joined a book already on a shelf: that book's shelf, who shelved it, and its call number.
pub(crate) struct Joined {
    pub shelf: Option<String>,
    pub by: Option<By>,
    pub call: Option<String>,
}

impl BuildService {
    /// `<data>/bookshelves`.
    pub(crate) fn shelves_dir(&self) -> PathBuf {
        self.data.join(BOOKSHELVES_DIR)
    }

    /// Every library folder in `<data>/app/docs/libraries` (names starting with a dot are a swap or a delete in progress).
    pub(crate) fn library_refs(&self) -> Vec<LibraryRef> {
        let mut out: Vec<LibraryRef> = Vec::new();
        if let Ok(rd) = std::fs::read_dir(self.libs_dir()) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') || !e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                    continue;
                }
                out.push(library_ref(&e.path()));
            }
        }
        out.sort_by(|a, b| a.dir.cmp(&b.dir));
        out
    }

    /// The libraries, read. One that cannot be read adds nothing (it is reported) and does not stop the others.
    fn library_inputs(&self) -> Vec<(LibraryRef, LibraryInput)> {
        self.library_refs()
            .into_iter()
            .filter_map(|r| match load_library(&r, &header_line) {
                Ok(i) => Some((r, i)),
                Err(e) => {
                    eprintln!("cache: reading the library {} for the Bookshelves log: {e}", r.dir.display());
                    None
                }
            })
            .collect()
    }

    /// Reads the Bookshelves log and the libraries, and resolves them.
    pub(crate) fn shelves(&self) -> Result<Shelves, String> {
        let set = read_logs(&self.shelves_dir().join(LOG_DIR)).map_err(|e| e.to_string())?;
        let libs: Vec<LibraryInput> = self.library_inputs().into_iter().map(|(_, i)| i).collect();
        let resolved = resolve(&set.events, &libs);
        Ok(Shelves { events: set.events, files: set.files, libs, resolved })
    }

    /// Appends events to this device's Bookshelves log, all with one time (the writer never lets it go back before this device's
    /// last event). Returns them as written.
    fn append(&self, kinds: Vec<(Kind, Option<String>)>) -> Result<Vec<Event>, String> {
        if kinds.is_empty() {
            return Ok(Vec::new());
        }
        let w = LogWriter::open(&self.shelves_dir().join(LOG_DIR), &self.device).map_err(|e| e.to_string())?;
        let at = now_ms();
        let events: Vec<Event> = kinds
            .into_iter()
            .map(|(k, loc)| {
                let e = Event::new(at, &self.device, k);
                match loc {
                    Some(l) => e.with_loc(&l),
                    None => e,
                }
            })
            .collect();
        w.append(&events).map_err(|e| e.to_string())
    }

    /// The copy key of a pack, from its header.
    pub(crate) fn pack_copy(&self, lib: &str, doc: &str, version: u32) -> Option<String> {
        let line = header_line(&self.packs_dir(lib).join(cache_builder::pack::pack_file_name(doc, version))).ok()?;
        PackFacts::from_header_line(&line).ok().map(|f| f.copy)
    }

    /// Makes `<library>/copies.jsonl` again from the library's live packs (their headers), as `cache-build library` writes it.
    pub(crate) fn write_copies(&self, lib: &str) -> Result<(), String> {
        let packs = self.packs_dir(lib);
        // read through the packs only, never through the copies file being replaced
        let r = LibraryRef { library_id: lib.to_string(), dir: packs.clone(), packs_dir: Some(packs) };
        let input = load_library(&r, &header_line).map_err(|e| e.to_string())?;
        let live = self.live_dir(lib);
        std::fs::create_dir_all(&live).map_err(|e| format!("making {}: {e}", live.display()))?;
        write_bytes_atomic(&live.join(COPIES_FILE), cache_builder::library::copies_text(&input.copies).as_bytes()).map_err(|e| format!("writing {COPIES_FILE}: {e}"))?;
        self.write_catalogue(lib)
    }

    /// The library's catalogue and local view, made from its packs the way the one-shot builder makes them: `documents.tsv` (what a
    /// browser or a phone lists a library's books from; without it the library shows no books) and `.local/docs.json`, format 2
    /// (the book facts, compression and OCR among them).
    fn write_catalogue(&self, lib: &str) -> Result<(), String> {
        let (live, packs) = (self.live_dir(lib), self.packs_dir(lib));
        let headers = if packs.is_dir() { cache_builder::view::live_headers(&packs).map_err(|e| e.to_string())? } else { Default::default() };
        let mut tsv = String::from("doc_id\tversion\ttitle\tsource_blake3\tpieces\tpages\n");
        for h in headers.values() {
            let title: String = h.title.chars().map(|c| if matches!(c, '\t' | '\n' | '\r') { ' ' } else { c }).collect();
            tsv.push_str(&format!("{}\t{}\t{}\t{}\t{}\t{}\n", h.doc_id, h.doc_version, title, h.source.blake3, h.pieces, h.page_count));
        }
        write_bytes_atomic(&live.join(cache_builder::library::DOCUMENTS_FILE), tsv.as_bytes()).map_err(|e| format!("writing documents.tsv: {e}"))?;
        if !headers.is_empty() {
            cache_builder::view::rebuild_view(&live, &packs).map_err(|e| format!("writing .local/docs.json: {e}"))?;
        }
        Ok(())
    }

    /// Changes one book's line of `<library>/copies.jsonl`: its other versions' lines go, and the line of `version` (read from its
    /// pack) is added; `None` takes the book out. With no copies file yet, it is made from the packs.
    pub(crate) fn update_copies(&self, lib: &str, doc: &str, version: Option<u32>) -> Result<(), String> {
        let path = self.live_dir(lib).join(COPIES_FILE);
        let existing = match std::fs::read_to_string(&path) {
            Ok(t) => t,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return self.write_copies(lib),
            Err(e) => return Err(format!("reading {COPIES_FILE}: {e}")),
        };
        let kept: String = existing
            .lines()
            .filter(|l| !l.trim().is_empty())
            .filter(|l| PackFacts::from_copies_line(l).map(|f| f.doc_id != doc).unwrap_or(true))
            .map(|l| format!("{l}\n"))
            .collect();
        let text = match version {
            Some(v) => {
                let line = header_line(&self.packs_dir(lib).join(cache_builder::pack::pack_file_name(doc, v)))?;
                let facts = PackFacts::from_header_line(&line).map_err(|e| e.to_string())?;
                cache_ingest::files::copies_with(Some(kept.as_str()), &facts)
            }
            None => kept,
        };
        write_bytes_atomic(&path, text.as_bytes()).map_err(|e| format!("writing {COPIES_FILE}: {e}"))
    }

    /// At start-up: each built library's `copies.jsonl` made again from its packs, then this device's own events imported once from
    /// every library's old `log/<device_id>.jsonl` (`cache_shelves::import`, recorded in `.local/migrated.json`), and the view.
    pub(crate) fn import_library_logs(&self) {
        let ids: Vec<String> = lock(&self.st).libs.iter().map(|l| l.id.clone()).collect();
        for id in ids {
            if let Err(e) = self.write_copies(&id) {
                eprintln!("cache: making the copies file of {id}: {e}");
            }
        }
        match import_own(&self.shelves_dir(), &self.device, &self.library_inputs()) {
            Ok(r) if r.events > 0 => eprintln!("cache: imported {} events of this device's library logs into the Bookshelves log", r.events),
            Ok(_) => {}
            Err(e) => eprintln!("cache: importing the library logs into the Bookshelves log: {e}"),
        }
        self.rebuild_view_quietly();
    }

    /// Shelves books in this device's log. Each item is (doc, division or None for Unsorted, by). For a division: `place` when the
    /// book is not already on that shelf, `retire` of the number it held in another division, and `assign` of the next free number
    /// (1 + the highest ever assigned or retired there, counting every device's log), the last two against the copy that holds the
    /// book's number. For Unsorted: `unsort` and `retire`. A book that is already where it should be, with its number, gets nothing,
    /// and so does a book whose copy no library lists. Returns each book's call number afterwards (an empty string in Unsorted).
    pub(crate) fn shelve_batch(&self, lib: &str, items: &[(String, Option<String>, By)]) -> Result<BTreeMap<String, String>, String> {
        let Shelves { events, libs, resolved, .. } = self.shelves()?;
        let s = Shelves { events: Vec::new(), files: Vec::new(), libs, resolved };
        let dir = self.live_dir(lib);
        let mut next: BTreeMap<String, u32> = BTreeMap::new();
        let mut new: Vec<(Kind, Option<String>)> = Vec::new();
        let mut copies: BTreeMap<String, String> = BTreeMap::new();
        for (doc, division, by) in items {
            let Some(copy) = s.copy_of(&dir, doc) else {
                eprintln!("cache: {lib}/{doc} is not in the library's copies file; not shelved");
                continue;
            };
            copies.insert(doc.clone(), copy.clone());
            let loc = Some(format!("{lib}/{doc}"));
            let cur = s.book(&copy);
            let cur_call = cur.and_then(|b| b.call.clone());
            // the copy that holds the book's number (another copy of the book, after a merge or a replacement)
            let numbered = cur
                .zip(cur_call.as_ref())
                .and_then(|(b, call)| b.copies.iter().find(|c| c.own_call.as_ref().is_some_and(|o| o.div == call.div && o.seq == call.seq)))
                .map(|c| c.copy.clone())
                .unwrap_or_else(|| copy.clone());
            let numbered_loc = if numbered == copy { loc.clone() } else { s.loc(&numbered).or_else(|| loc.clone()) };
            match division {
                Some(d) => {
                    let on_shelf = cur.is_some_and(|b| b.shelf.as_deref() == Some(d.as_str()));
                    if on_shelf && cur_call.is_some() {
                        continue;
                    }
                    if !on_shelf {
                        new.push((Kind::Place { copy: copy.clone(), div: d.clone(), by: *by }, loc.clone()));
                    }
                    if let Some(c) = cur_call.as_ref().filter(|c| c.div != *d) {
                        new.push((Kind::Retire { copy: numbered.clone(), div: c.div.clone(), seq: c.seq }, numbered_loc.clone()));
                    }
                    let n = next.entry(d.clone()).or_insert_with(|| s.resolved.next_seq(d));
                    let seq = *n;
                    *n += 1;
                    new.push((Kind::Assign { copy: numbered.clone(), div: d.clone(), seq }, numbered_loc));
                }
                None => {
                    let unsorted = cur.is_some_and(|b| b.shelved && b.shelf.is_none());
                    if unsorted && cur_call.is_none() {
                        continue;
                    }
                    new.push((Kind::Unsort { copy: copy.clone(), by: *by }, loc.clone()));
                    if let Some(c) = &cur_call {
                        new.push((Kind::Retire { copy: numbered.clone(), div: c.div.clone(), seq: c.seq }, numbered_loc));
                    }
                }
            }
        }
        let written = self.append(new)?;
        let mut all = events;
        all.extend(written);
        let after = resolve(&all, &s.libs);
        Ok(items
            .iter()
            .filter_map(|(doc, _, _)| {
                let copy = copies.get(doc)?;
                Some((doc.clone(), after.book_of(copy).and_then(|b| b.call.as_ref()).map(|c| c.text.clone()).unwrap_or_default()))
            })
            .collect())
    }

    /// Appends a `title` event for the book's copy.
    pub(crate) fn log_title(&self, lib: &str, doc: &str, title: &str) -> Result<(), String> {
        let s = self.shelves()?;
        let copy = s.copy_of(&self.live_dir(lib), doc).ok_or_else(|| format!("{lib}/{doc} is not in the library's copies file"))?;
        self.append(vec![(Kind::Title { copy, title: title.to_string() }, Some(format!("{lib}/{doc}")))]).map(|_| ())
    }

    /// Says that the book `doc` of `lib` and the copy `other` are one book (`same`, by `by`) or two (`notsame` by the person, when
    /// `same` is `None`). Nothing is written when they are one copy.
    pub(crate) fn link_copies(&self, lib: &str, doc: &str, other: &str, same: Option<(By, How)>) -> Result<(), String> {
        let s = self.shelves()?;
        let copy = s.copy_of(&self.live_dir(lib), doc).ok_or_else(|| format!("{lib}/{doc} is not in the library's copies file"))?;
        if copy == other {
            return Ok(());
        }
        let kind = match same {
            Some((by, how)) => Kind::Same { copy, with: other.to_string(), by, how, score: None },
            None => Kind::NotSame { copy, with: other.to_string(), by: By::User },
        };
        self.append(vec![(kind, Some(format!("{lib}/{doc}")))]).map(|_| ())
    }

    /// Same-book detection, once, for the new copy of `doc` in `lib`: the batch form (`cache_shelves::batch`) against every copy the
    /// service can see, with the service's tuning. Each match whose pair has no `same` or `notsame` in the log yet is written as
    /// `same ... by:auto` with its `how` and `score`. When the copy then belongs to a book some event has shelved, that book's shelf
    /// and number are returned (the copy joins it and is not shelved again).
    pub(crate) fn detect_new_copy(&self, lib: &str, doc: &str) -> Result<Option<Joined>, String> {
        let s = self.shelves()?;
        let copy = s.copy_of(&self.live_dir(lib), doc).ok_or_else(|| format!("{lib}/{doc} is not in the library's copies file"))?;
        let all: Vec<cache_shelves::same::Facts> = s.libs.iter().flat_map(|l| l.copies.iter().map(|c| c.detect_facts())).collect();
        let checked: BTreeSet<String> = BTreeSet::from([copy.clone()]);
        let linked: BTreeSet<(String, String)> = s
            .events
            .iter()
            .filter_map(|e| match &e.kind {
                Kind::Same { copy, with, .. } | Kind::NotSame { copy, with, .. } => Some(pair_key(copy, with)),
                _ => None,
            })
            .collect();
        let new: Vec<(Kind, Option<String>)> = find_pairs(&all, Some(&checked), &BTreeSet::new(), &self.tuning())
            .into_iter()
            .filter(|p| !linked.contains(&pair_key(&p.copy, &p.with)))
            .map(|p| {
                let loc = s.loc(&p.copy);
                (Kind::Same { copy: p.copy, with: p.with, by: By::Auto, how: p.how, score: Some(p.score) }, loc)
            })
            .collect();
        let written = self.append(new)?;
        let resolved = if written.is_empty() {
            s.resolved
        } else {
            let mut all = s.events;
            all.extend(written);
            resolve(&all, &s.libs)
        };
        Ok(resolved.book_of(&copy).filter(|b| b.shelved).map(|b| Joined { shelf: b.shelf.clone(), by: b.by, call: b.call.as_ref().map(|c| c.text.clone()) }))
    }

    /// Shelves the books no event has shelved yet (built before the log existed, or whose events could not be written): by their
    /// division, `user` when a person placed them.
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
        let s = self.shelves()?;
        let dir = self.live_dir(lib);
        let todo: Vec<(String, Option<String>, By)> = books
            .into_iter()
            .filter(|(doc, _, _)| s.copy_of(&dir, doc).is_some_and(|c| !s.book(&c).is_some_and(|b| b.shelved)))
            .map(|(doc, div, placed)| (doc, div, if placed { By::User } else { By::Auto }))
            .collect();
        if todo.is_empty() {
            return Ok(());
        }
        self.shelve_batch(lib, &todo).map(|_| ())
    }

    /// Sets each book's `call_text` from the Bookshelves log; saves the library when any changed. A book whose copy no library
    /// lists keeps what it has.
    pub(crate) fn refresh_calls(&self, lib: &str) -> Result<(), String> {
        let s = self.shelves()?;
        let dir = self.live_dir(lib);
        let mut st = lock(&self.st);
        let Some(m) = st.libs.iter_mut().find(|l| l.id == lib) else { return Ok(()) };
        let mut changed = false;
        for b in m.books.iter_mut() {
            let Some(copy) = s.copy_of(&dir, &b.doc_id) else { continue };
            let want = s.book(&copy).and_then(|d| d.call.as_ref()).map(|c| c.text.clone());
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

    /// Makes `<data>/bookshelves/.local/view.json` again from the log and the libraries. A failure is reported and goes no further:
    /// the view is made from files that are there, so the next change makes it again.
    pub(crate) fn rebuild_view_quietly(&self) {
        let made = self.shelves().and_then(|s| write_view(&self.shelves_dir(), &view_value(&s.resolved, &s.libs, &s.files)).map_err(|e| e.to_string()));
        if let Err(e) = made {
            eprintln!("cache: writing the Bookshelves view: {e}");
        }
    }

    /// What publishing does for the log: the copies file made again, books it has never seen shelved, the call numbers refreshed,
    /// the view made again.
    pub(crate) fn catch_up(&self, lib: &str) {
        if let Err(e) = self.write_copies(lib) {
            eprintln!("cache: making the copies file of {lib}: {e}");
        }
        if let Err(e) = self.shelve_missing(lib) {
            eprintln!("cache: shelving the books of {lib}: {e}");
        }
        if let Err(e) = self.refresh_calls(lib) {
            eprintln!("cache: call numbers of {lib}: {e}");
        }
        self.rebuild_view_quietly();
    }
}
