//! The filing side of the build service: the classes view, books by division, placing a book by hand, classifying books that were
//! not classified at build time, and the choice for a possible new edition.

use super::*;
use cache_builder::fingerprint::class_vector;
use classify::{Classes, Verdict};

pub(crate) fn decision_view(d: &Decision) -> Value {
    let side = |s: &Side| json!({"pages": s.pages, "text_pages": s.text_pages, "year": s.year, "size": s.size, "ppi": s.ppi});
    json!({
        "other_doc_id": d.other_doc_id, "old_title": d.other_title, "new_title": d.new_title,
        "new": side(&d.new), "old": side(&d.old),
        "summary": {
            "pages": {"new": d.new.pages, "old": d.old.pages},
            "text_pages": {"new": d.new.text_pages, "old": d.old.text_pages},
            "year": {"new": d.new.year, "old": d.old.year},
        },
        "jaccard": d.jaccard, "cosine": d.cosine,
        "actions": ["keep_both", "replace_older"],
    })
}

fn division_label(cls: &Classes, division: Option<&str>) -> String {
    match division.and_then(|d| cls.find(d)) {
        Some((_, d)) => format!("{} {}", d.number, d.name),
        None => classify::UNSORTED.to_string(),
    }
}

impl BuildService {
    /// One book as the API shows it.
    fn book_json(&self, cls: &Classes, b: &Book, replacing: bool) -> Value {
        let found = b.division.as_deref().and_then(|d| cls.find(d));
        let suggestions: Vec<Value> = b
            .suggestions
            .iter()
            .map(|s| {
                let f = cls.find(&s.division);
                json!({"division": s.division, "name": f.map(|(_, d)| d.name.clone()), "class": f.map(|(c, _)| c.number.clone()), "score": s.score})
            })
            .collect();
        json!({
            "id": b.doc_id, "doc_version": b.doc_version, "title": b.title, "pages": b.pages, "passages": b.pieces,
            "ocr_pages": b.ocr_pages, "partial": if b.ocr_pages > 0 { Some(format!("partial: {} pages need OCR", b.ocr_pages)) } else { None },
            "file_name": b.file_name, "size": b.size, "added_at": b.added_at, "status": if replacing { "replacing" } else { "ready" },
            "text_pages": b.quality().text_pages, "year": b.year, "ppi": b.ppi,
            "class": found.map(|(c, _)| c.number.clone()), "class_name": found.map(|(c, _)| c.name.clone()),
            "division": found.map(|(_, d)| d.number.clone()), "division_name": found.map(|(_, d)| d.name.clone()),
            "call_number": b.call_number(), "unsorted": found.is_none(),
            "suggestions": suggestions,
            "unsure_reason": if found.is_none() { b.unsure.as_deref().map(classify::unsure_message) } else { None },
            "placed_by_hand": b.placed, "moved_from": b.moved_from,
            "filed_in": b.source_rel.as_deref().and_then(|r| r.rsplit_once('/')).map(|(d, _)| d),
        })
    }

    /// `GET /api/build/libraries/{id}/books?division=&class=&sort=`. `division` is a number or `unsorted`; `sort` is `title`
    /// (the default) or `call`, which lists Unsorted first and then by call number.
    pub fn books_q(&self, id: &str, query: &str) -> Result<Value, ApiErr> {
        let division = crate::fetch::query_param(query, "division");
        let class = crate::fetch::query_param(query, "class");
        let by_call = crate::fetch::query_param(query, "sort").as_deref() == Some("call");
        let cls = self.classes();
        let st = lock(&self.st);
        let m = st.libs.iter().find(|l| l.id == id).ok_or_else(|| err(404, "not_found", "no such library"))?;
        let in_class: Option<Vec<&str>> = class.as_deref().map(|c| cls.find_class(c).map(|k| k.divisions.iter().map(|d| d.number.as_str()).collect()).unwrap_or_default());
        let mut books: Vec<&Book> = m
            .books
            .iter()
            .filter(|b| match division.as_deref() {
                Some("unsorted") => cls.find(b.division.as_deref().unwrap_or("")).is_none(),
                Some(d) => b.division.as_deref() == Some(d),
                None => true,
            })
            .filter(|b| in_class.as_ref().is_none_or(|v| b.division.as_deref().is_some_and(|d| v.contains(&d))))
            .collect();
        if by_call {
            books.sort_by(|a, b| {
                let key = |x: &Book| (x.division.is_some(), x.division.clone().unwrap_or_default(), x.call_number().to_lowercase(), x.title.to_lowercase());
                key(a).cmp(&key(b)).then(a.doc_id.cmp(&b.doc_id))
            });
        } else {
            books.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()).then(a.doc_id.cmp(&b.doc_id)));
        }
        Ok(Value::Array(
            books
                .into_iter()
                .map(|b| {
                    let replacing = st.items.iter().any(|i| i.library_id == id && i.state.live() && i.replace.as_deref() == Some(&b.doc_id));
                    self.book_json(&cls, b, replacing)
                })
                .collect(),
        ))
    }

    /// `GET /api/build/classes[?library_id=]`: the classes, and for each library the number of books in every class and division,
    /// with the books in Unsorted.
    pub fn classes_view(&self, library_id: Option<&str>) -> Result<Value, ApiErr> {
        let cls = self.classes();
        let st = lock(&self.st);
        if let Some(l) = library_id {
            if !st.libs.iter().any(|m| m.id == l) {
                return Err(err(404, "not_found", "no such library"));
            }
        }
        let libs: Vec<&LibMeta> = st.libs.iter().filter(|m| library_id.is_none_or(|l| m.id == l)).collect();
        let count_div = |d: &str| libs.iter().map(|m| m.books.iter().filter(|b| b.division.as_deref() == Some(d)).count()).sum::<usize>();
        let known = |b: &Book| b.division.as_deref().and_then(|d| cls.find(d)).is_some();
        let classes: Vec<Value> = cls
            .classes
            .iter()
            .map(|c| {
                let divs: Vec<Value> = c
                    .divisions
                    .iter()
                    .map(|d| json!({"number": d.number, "name": d.name, "description": d.description, "assigned": d.assigned(), "count": count_div(&d.number)}))
                    .collect();
                json!({"number": c.number, "name": c.name, "count": c.divisions.iter().map(|d| count_div(&d.number)).sum::<usize>(), "divisions": divs})
            })
            .collect();
        let libraries: Vec<Value> = libs
            .iter()
            .map(|m| {
                let mut divisions = serde_json::Map::new();
                let mut by_class = serde_json::Map::new();
                for c in &cls.classes {
                    let mut total = 0;
                    for d in &c.divisions {
                        let n = m.books.iter().filter(|b| b.division.as_deref() == Some(d.number.as_str())).count();
                        total += n;
                        divisions.insert(d.number.clone(), json!(n));
                    }
                    by_class.insert(c.number.clone(), json!(total));
                }
                json!({"id": m.id, "title": m.title, "books": m.books.len(), "unsorted": m.books.iter().filter(|b| !known(b)).count(), "classes": by_class, "divisions": divisions})
            })
            .collect();
        Ok(json!({
            "classes": classes,
            "unsorted": {"name": classify::UNSORTED, "count": libs.iter().map(|m| m.books.iter().filter(|b| !known(b)).count()).sum::<usize>()},
            "libraries": libraries,
            "settings": {"unsure_below": cls.unsure_below, "min_margin": cls.min_margin},
        }))
    }

    /// Remember where a book's file went in the drop folder's `complete/`, so that placing the book moves it too.
    pub(crate) fn note_drop_copy(&self, lib: &str, doc: &str, path: &Path, root: &Path) {
        let _ = self.update_book(lib, doc, |b| {
            b.drop_copy = Some(path.to_string_lossy().into_owned());
            b.drop_root = Some(root.to_string_lossy().into_owned());
        });
    }

    /// Change a book's recorded fields and save the library's file.
    fn update_book(&self, lib: &str, doc: &str, f: impl FnOnce(&mut Book)) -> Result<(), String> {
        let mut st = lock(&self.st);
        let m = st.libs.iter_mut().find(|l| l.id == lib).ok_or("no such library")?;
        let b = m.books.iter_mut().find(|b| b.doc_id == doc).ok_or("no such book")?;
        f(b);
        let m = m.clone();
        self.save_meta(&m).map_err(|e| format!("saving the library: {e}"))
    }

    /// Move a book's files to `division` (None is Unsorted) and record it. The caller holds `ops`.
    fn refile(&self, lib: &str, doc: &str, division: Option<String>, by_hand: bool) -> Result<(), String> {
        let cls = self.classes();
        let book = self.book_of(lib, doc).ok_or("no such book")?;
        let division = division.filter(|d| cls.find(d).is_some_and(|(_, x)| x.assigned()));
        if book.division == division {
            if by_hand && !book.placed {
                return self.update_book(lib, doc, |b| b.placed = true);
            }
            return Ok(());
        }
        let folder = cls.folder_rel(division.as_deref());
        let folder_s = folder.to_string_lossy().replace('\\', "/");
        let mut b2 = book.clone();
        b2.division = division.clone();
        if by_hand {
            b2.placed = true;
            b2.moved_from = Some(division_label(&cls, book.division.as_deref()));
        }
        let name = classify::file_name(&b2.call_number(), &b2.title);
        let src = self.source_of(lib, &book);
        if src.is_file() {
            let n = dropdir::move_unique(&src, &self.sources_root(lib).join(&folder), &name).map_err(|e| format!("moving the PDF: {e}"))?;
            b2.source_rel = Some(format!("{folder_s}/{n}"));
        }
        let mut moved_rel: Option<String> = None;
        if let (Some(c), Some(r)) = (&book.drop_copy, &book.drop_root) {
            let c = PathBuf::from(c);
            if c.is_file() {
                let dir = PathBuf::from(r).join("complete").join(&folder);
                let n = dropdir::move_unique(&c, &dir, &name).map_err(|e| format!("moving the file in complete/: {e}"))?;
                b2.drop_copy = Some(dir.join(&n).to_string_lossy().into_owned());
                moved_rel = Some(format!("{folder_s}/{n}"));
            }
        }
        {
            let mut st = lock(&self.st);
            if let Some(m) = st.libs.iter_mut().find(|l| l.id == lib) {
                if let Some(b) = m.books.iter_mut().find(|b| b.doc_id == doc) {
                    *b = b2;
                }
                let m = m.clone();
                self.save_meta(&m).map_err(|e| format!("saving the library: {e}"))?;
            }
            if let Some(rel) = moved_rel {
                for it in st.items.iter_mut().filter(|i| i.library_id == lib && i.doc_id.as_deref() == Some(doc) && i.moved_to.is_some() && i.state == S::Done) {
                    it.moved_to = Some(rel.clone());
                    it.division = division.clone();
                    it.call_number = Some(self.book_call(&book, division.as_deref()));
                }
                self.save_queue_locked(&st);
            }
        }
        Ok(())
    }

    fn book_call(&self, b: &Book, division: Option<&str>) -> String {
        let mut x = b.clone();
        x.division = division.map(str::to_string);
        x.call_number()
    }

    /// `POST /api/build/libraries/{id}/books/{doc}/place {"division": "530"}` (`"unsorted"` or null puts it back in Unsorted): the
    /// files move and the call number takes the new division.
    pub fn place_book(&self, lib: &str, doc: &str, body: &[u8]) -> Result<Value, ApiErr> {
        let v: Value = serde_json::from_slice(body).map_err(|_| err(400, "bad_json", "the body is not JSON"))?;
        let division = match v.get("division") {
            Some(Value::Null) => None,
            Some(Value::String(s)) if s == "unsorted" => None,
            Some(Value::String(s)) => Some(s.clone()),
            _ => return Err(err(400, "invalid", "\"division\" is a division number, \"unsorted\" or null")),
        };
        let cls = self.classes();
        if let Some(d) = &division {
            if !cls.find(d).is_some_and(|(_, x)| x.assigned()) {
                return Err(err(400, "invalid", "There is no such division."));
            }
        }
        let _g = lock(&self.ops);
        if self.book_of(lib, doc).is_none() {
            return Err(err(404, "not_found", "no such book"));
        }
        self.refile(lib, doc, division, true).map_err(|e| err(500, "server_error", e))?;
        let b = self.book_of(lib, doc).ok_or_else(|| err(404, "not_found", "no such book"))?;
        Ok(self.book_json(&cls, &b, false))
    }

    /// Record the classifier's verdict for a book and move its files if the division changed. Books placed by hand are left alone.
    fn apply_verdict(&self, lib: &str, doc: &str, v: &Verdict) -> Result<bool, String> {
        let _g = lock(&self.ops);
        let Some(book) = self.book_of(lib, doc) else { return Ok(false) };
        if book.placed {
            return Ok(false);
        }
        let (top, unsure) = (v.top.clone(), v.unsure.clone());
        self.update_book(lib, doc, |b| {
            b.suggestions = top;
            b.unsure = unsure;
            b.classified = true;
        })?;
        let before = book.division.clone();
        self.refile(lib, doc, v.division.clone(), false)?;
        Ok(before != self.book_of(lib, doc).and_then(|b| b.division))
    }

    fn verdict_for(&self, lib: &str, b: &Book, cls_vecs: &(Arc<Classes>, Arc<ClassVectors>)) -> Result<Verdict, String> {
        let pack = read_pack(&self.packs_dir(lib).join(cache_builder::pack::pack_file_name(&b.doc_id, b.doc_version))).map_err(|e| e.to_string())?;
        Ok(classify::classify(&class_vector(&pack.pieces), &cls_vecs.1, &cls_vecs.0))
    }

    /// `POST /api/build/classes/reclassify {"library_id"?, "scope"?: "all"|"unsorted"}`: look at the books again (after the classes were
    /// edited). Books the person placed are left where they are.
    pub fn reclassify(&self, body: &[u8]) -> Result<Value, ApiErr> {
        let v: Value = if body.is_empty() { json!({}) } else { serde_json::from_slice(body).map_err(|_| err(400, "bad_json", "the body is not JSON"))? };
        let library = v["library_id"].as_str().map(str::to_string);
        let only_unsorted = v["scope"].as_str() == Some("unsorted");
        let vecs = self.class_vectors().map_err(|m| err(409, "model_missing", format!("The search model is not ready: {m}")))?;
        let todo: Vec<(String, Book)> = lock(&self.st)
            .libs
            .iter()
            .filter(|l| library.as_deref().is_none_or(|x| x == l.id))
            .flat_map(|l| l.books.iter().filter(|b| !b.placed && (!only_unsorted || b.division.is_none())).map(|b| (l.id.clone(), b.clone())))
            .collect();
        let (mut checked, mut moved, mut failed) = (0, 0, 0);
        for (lib, b) in &todo {
            match self.verdict_for(lib, b, &vecs).and_then(|vd| self.apply_verdict(lib, &b.doc_id, &vd)) {
                Ok(m) => {
                    checked += 1;
                    moved += usize::from(m);
                }
                Err(e) => {
                    eprintln!("cache-server: classifying {}: {e}", b.doc_id);
                    failed += 1;
                }
            }
        }
        Ok(json!({"checked": checked, "moved": moved, "failed": failed}))
    }

    /// Work done when the queue is idle: the daily purge of Removed, and filing one book that was never classified (books built
    /// before filing existed, or while the model was missing).
    pub(crate) fn maintenance(&self) {
        {
            let mut last = lock(&self.last_maintenance);
            if last.elapsed() >= Duration::from_secs(24 * 3600) {
                *last = Instant::now();
                drop(last);
                self.purge_removed(epoch());
            }
        }
        if lock(&self.classify_retry).is_some_and(|t| Instant::now() < t) || self.embed.ready().is_err() {
            return;
        }
        let next: Option<(String, Book)> = lock(&self.st).libs.iter().find_map(|l| l.books.iter().find(|b| !b.classified && !b.placed).map(|b| (l.id.clone(), b.clone())));
        let Some((lib, b)) = next else { return };
        let done = self.class_vectors().and_then(|vecs| self.verdict_for(&lib, &b, &vecs)).and_then(|vd| self.apply_verdict(&lib, &b.doc_id, &vd));
        if let Err(e) = done {
            eprintln!("cache-server: classifying {}: {e}", b.doc_id);
            let _ = self.update_book(&lib, &b.doc_id, |x| x.classified = true);
            *lock(&self.classify_retry) = Some(Instant::now() + Duration::from_secs(60));
        }
    }

    /// `POST /api/build/queue/{id}/decide {"action": "keep_both"|"replace_older"}` for a book in `needs_decision`.
    pub fn decide(&self, id: &str, body: &[u8]) -> Result<Value, ApiErr> {
        let v: Value = serde_json::from_slice(body).map_err(|_| err(400, "bad_json", "the body is not JSON"))?;
        let action = v["action"].as_str().unwrap_or_default();
        if !matches!(action, "keep_both" | "replace_older") {
            return Err(err(400, "invalid", "\"action\" is keep_both or replace_older"));
        }
        {
            let mut st = lock(&self.st);
            let idx = st.items.iter().position(|i| i.id == id).ok_or_else(|| err(404, "not_found", "no such book in the queue"))?;
            if st.items[idx].state != S::NeedsDecision {
                return Err(err(409, "not_waiting", "That book is not waiting for a choice."));
            }
            if action == "replace_older" {
                let other = st.items[idx].decision.as_ref().map(|d| d.other_doc_id.clone()).unwrap_or_default();
                let lib = st.items[idx].library_id.clone();
                if !st.libs.iter().any(|l| l.id == lib && l.books.iter().any(|b| b.doc_id == other)) {
                    return Err(err(409, "gone", "The older book is no longer in this library."));
                }
            }
            let mut it = st.items.remove(idx);
            it.state = S::Queued;
            it.force = Some(action.to_string());
            it.error = None;
            it.result = None;
            it.started_at = None;
            it.finished_at = None;
            it.finished_epoch = None;
            // Replacing the older one goes first, right after the book being worked on; keeping both keeps its place.
            let at = if action == "replace_older" { st.items.iter().position(|i| i.state == S::Queued).unwrap_or(st.items.len()) } else { idx.min(st.items.len()) };
            st.items.insert(at, it);
            self.save_queue_locked(&st);
        }
        self.poke();
        Ok(self.queue())
    }
}
