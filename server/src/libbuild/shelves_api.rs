//! What the browser's Library reads and writes of the Bookshelves log (`/api/build/bookshelves...`, server/BUILD-API.md
//! "Bookshelves in the browser").
//!
//! The browser has no files of its own: the shelves it shows are this server's view of the person's Bookshelves log
//! (`<data>/bookshelves/`, see `booklog.rs`), and every change it makes is appended to this server's own file of that log, `log/<device>.jsonl`,
//! the one the server already writes. Only one process writes that file, so nothing here lets the browser write a log of its own.
//!
//! - [`BuildService::bookshelves_view`]: the server's device id and the resolved view (the same JSON `cs_shelves_resolve` gives
//!   a phone, `.local/view.json`).
//! - [`BuildService::bookshelves_facts`]: the first line of each book's newest pack (a phone reads these from its packs itself),
//!   without the bulky `samebook` block.
//! - [`BuildService::bookshelves_stamp`]: a short text that changes when the logs or a library's books change, so a page asks for
//!   the rest only when it must.
//! - [`BuildService::bookshelves_events`]: the events a book page writes. A book this server built is shelved the way its own
//!   "Place it" does (files move, the call number follows, the number is the server's next free one); a rename goes through the
//!   book's rename. Everything else is appended to the log as it came.

use super::*;
use cache_builder::bookshelves::header_line;
use cache_shelves::events::{check_for_write, Event, Kind};
use cache_shelves::library::COPIES_FILE;
use cache_shelves::store::{now_ms, LogWriter, LOG_DIR};
use cache_shelves::view::view_value;
use std::collections::BTreeMap;

/// The events a book page writes (`CdsShelfSource` in the app); anything else is refused.
const BOOK_EVENTS: [&str; 10] = ["place", "unsort", "assign", "retire", "title", "remove", "restore", "same", "notsame", "prefer"];

/// The most events one call takes (Place all best guesses on a big library is two or three per book).
const MAX_EVENTS: usize = 5000;

impl BuildService {
    /// A text that differs whenever a Bookshelves log file, a library's catalogue (`documents.tsv`, `copies.jsonl`) or its packs
    /// folder changes (name, size and time of each).
    pub(crate) fn shelves_stamp(&self) -> String {
        fn mark(out: &mut String, p: &Path) {
            if let Ok(m) = std::fs::metadata(p) {
                let t = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_millis()).unwrap_or(0);
                let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                out.push_str(&format!("{name}:{}:{t};", m.len()));
            }
        }
        let mut out = String::new();
        if let Ok(rd) = std::fs::read_dir(self.shelves_dir().join(LOG_DIR)) {
            let mut files: Vec<PathBuf> = rd.flatten().map(|e| e.path()).collect();
            files.sort();
            for p in &files {
                mark(&mut out, p);
            }
        }
        out.push('|');
        for r in self.library_refs() {
            out.push_str(&r.library_id);
            out.push(':');
            mark(&mut out, &r.dir.join(COPIES_FILE));
            mark(&mut out, &r.dir.join("documents.tsv"));
            mark(&mut out, &r.packs());
            // a linked file found or lost at a check changes which books are on this device
            mark(&mut out, &r.dir.join(".local").join("linked-registry.json"));
            out.push('/');
        }
        out
    }

    /// `GET /api/build/bookshelves`: `{device, stamp, view}`. `device` is this server's id in the Bookshelves log (the cache_sync
    /// identity in `<data>/sync`); `view` is the view of LIBRARY-LOG.md, format 1.
    pub fn bookshelves_view(&self) -> Result<Value, ApiErr> {
        let s = self.shelves().map_err(|e| err(500, "server_error", e))?;
        Ok(json!({"device": self.device, "stamp": self.shelves_stamp(), "view": view_value(&s.resolved, &s.libs, &s.files)}))
    }

    /// `GET /api/build/bookshelves/stamp`: `{stamp}`.
    pub fn bookshelves_stamp(&self) -> Value {
        json!({"stamp": self.shelves_stamp()})
    }

    /// `GET /api/build/bookshelves/facts`: `{libraries: {<library_id>: {<doc_id>: <the header of its newest pack, without
    /// samebook>}}}`. A library with no packs (a downloaded `.cache-library`) has none.
    pub fn bookshelves_facts(&self) -> Result<Value, ApiErr> {
        let mut libs = serde_json::Map::new();
        for r in self.library_refs() {
            let mut newest: BTreeMap<String, (u32, PathBuf)> = BTreeMap::new();
            if let Ok(rd) = std::fs::read_dir(r.packs()) {
                for e in rd.flatten() {
                    let name = e.file_name().to_string_lossy().into_owned();
                    let Some(stem) = name.strip_suffix(".cdoc") else { continue };
                    let Some((doc, ver)) = stem.rsplit_once('@') else { continue };
                    let Ok(v) = ver.parse::<u32>() else { continue };
                    if newest.get(doc).is_none_or(|(cur, _)| *cur < v) {
                        newest.insert(doc.to_string(), (v, e.path()));
                    }
                }
            }
            // this device's own fact, never part of a pack: is the book's PDF on this device (a filed copy, or a linked file that was
            // present at the last check)? Only for a library this server builds.
            let built: Option<BTreeMap<String, Book>> = lock(&self.st).libs.iter().find(|l| l.id == r.library_id).map(|l| l.books.iter().map(|b| (b.doc_id.clone(), b.clone())).collect());
            let presence = self.linked_presence(&r.library_id);
            let mut docs = serde_json::Map::new();
            for (doc, (_, path)) in newest {
                let Ok(line) = header_line(&path) else { continue };
                let Ok(Value::Object(mut h)) = serde_json::from_str::<Value>(line.trim()) else { continue };
                h.remove("samebook");
                if let Some(b) = built.as_ref().and_then(|m| m.get(&doc)) {
                    h.insert("on_device".into(), json!(self.pdf_on_device(&r.library_id, b, &presence)));
                }
                docs.insert(doc, Value::Object(h));
            }
            libs.insert(r.library_id.clone(), Value::Object(docs));
        }
        Ok(json!({"libraries": libs}))
    }

    /// `POST /api/build/bookshelves/events {"events": [event]}`: the events a book page writes, as a log line's object (`v` and `dev` are
    /// the server's; `at` is now when left out). See the module's notes for what is done with them. 400 for an event the Library
    /// does not write, one that is not valid, or a division that does not exist (nothing is written then).
    pub fn bookshelves_events(&self, body: &[u8]) -> Result<Value, ApiErr> {
        let v: Value = serde_json::from_slice(body).map_err(|_| err(400, "bad_json", "the body is not JSON"))?;
        let list = v
            .get("events")
            .and_then(Value::as_array)
            .filter(|l| !l.is_empty() && l.len() <= MAX_EVENTS)
            .ok_or_else(|| err(400, "invalid", "\"events\" is a list of 1 to 5000 Bookshelves events"))?;
        let now = now_ms();
        let mut events: Vec<Event> = Vec::with_capacity(list.len());
        for (i, e) in list.iter().enumerate() {
            let mut o = e.as_object().cloned().ok_or_else(|| err(400, "invalid", format!("event {i} is not an object")))?;
            let name = o.get("ev").and_then(Value::as_str).unwrap_or_default().to_string();
            if !BOOK_EVENTS.contains(&name.as_str()) {
                return Err(err(400, "invalid", format!("event {i} is not one the Library writes")));
            }
            o.insert("v".into(), json!(1));
            o.entry("at").or_insert(json!(now));
            o.insert("dev".into(), json!(self.device));
            let ev = Event::from_value(&Value::Object(o)).ok_or_else(|| err(400, "invalid", format!("event {i} is not a Bookshelves event")))?;
            if let Some(why) = check_for_write(&ev) {
                return Err(err(400, "invalid", why));
            }
            events.push(ev);
        }
        let mut titles: Vec<(String, String, String)> = Vec::new();
        let (mut moved, mut written) = (0usize, 0usize);
        {
            let _g = lock(&self.ops);
            let s = self.shelves().map_err(|e| err(500, "server_error", e))?;
            // the copies of the books this server built, and where each is
            let built: Vec<String> = lock(&self.st).libs.iter().map(|l| l.id.clone()).collect();
            let mut owner: BTreeMap<String, (String, String)> = BTreeMap::new();
            for id in &built {
                let dir = self.live_dir(id);
                if let Some(l) = s.libs.iter().find(|l| l.dir == dir) {
                    for c in &l.copies {
                        owner.insert(c.copy.clone(), (id.clone(), c.doc_id.clone()));
                    }
                }
            }
            let cls = self.classes();
            let mut moves: Vec<(String, String, Option<String>)> = Vec::new();
            let mut raw: Vec<Event> = Vec::new();
            for e in events {
                let own = e.kind.copy().and_then(|c| owner.get(c)).cloned();
                let mut keep = false;
                match (&e.kind, &own) {
                    (Kind::Place { div, .. }, Some((l, d))) => {
                        if !cls.find(div).is_some_and(|(_, x)| x.assigned()) {
                            return Err(err(400, "invalid", "There is no such division."));
                        }
                        moves.push((l.clone(), d.clone(), Some(div.clone())));
                    }
                    (Kind::Unsort { .. }, Some((l, d))) => moves.push((l.clone(), d.clone(), None)),
                    // the server numbers a book itself when it shelves it
                    (Kind::Assign { .. } | Kind::Retire { .. }, Some(_)) => {}
                    (Kind::Title { title, .. }, Some((l, d))) => titles.push((l.clone(), d.clone(), title.clone())),
                    _ => keep = true,
                }
                if keep {
                    raw.push(e);
                }
            }
            for (l, d, div) in &moves {
                self.refile(l, d, div.clone(), true).map_err(|e| err(500, "server_error", e))?;
                moved += 1;
            }
            if !raw.is_empty() {
                let w = LogWriter::open(&self.shelves_dir().join(LOG_DIR), &self.device).map_err(|e| err(500, "server_error", e.to_string()))?;
                written = w.append(&raw).map_err(|e| err(500, "server_error", e.to_string()))?.len();
                for id in &built {
                    if let Err(e) = self.refresh_calls(id) {
                        eprintln!("cache: call numbers of {id}: {e}");
                    }
                }
            }
        }
        for (l, d, t) in &titles {
            self.rename_book(l, d, json!({"title": t}).to_string().as_bytes())?;
        }
        self.rebuild_view_quietly();
        Ok(json!({"written": written, "moved": moved, "titled": titles.len(), "stamp": self.shelves_stamp()}))
    }
}
