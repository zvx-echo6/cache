//! Linked folders seen from the books: where a book's original is, whether it counts as on this device, what each folder holds, and
//! forgetting a book whose file is gone. Everything here reads the saved registry (the last check); only `forget` writes, and never
//! a file in a linked folder.
use super::{
    linked_api::{error, io_error},
    linked_registry::{LinkedRegistry, RegistryData},
    Book, BuildService,
};
use crate::library::ApiErr;
use serde_json::{json, Value};
use std::{
    collections::{BTreeSet, HashSet},
    path::{Component, Path, PathBuf},
};

/// A path inside a linked folder: not empty, and every part a plain name (no `..`, no root, no prefix).
fn inside(relative: &str) -> bool {
    !relative.is_empty() && Path::new(relative).components().all(|c| matches!(c, Component::Normal(_)))
}

fn canonical_or_self(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

/// Which books of a library have a linked file that the last check found present.
pub(crate) struct LinkedPresence {
    docs: HashSet<String>,
    hashes: HashSet<String>,
}

impl LinkedPresence {
    /// Does a linked file hold this book? By the document the check matched, or by the hash of the stored file or of the file as it
    /// arrived (a book built from a linked file has not been matched by a check yet).
    pub(crate) fn has(&self, b: &Book) -> bool {
        self.docs.contains(&b.doc_id) || self.hashes.contains(&b.blake3) || b.original_blake3.as_ref().is_some_and(|h| self.hashes.contains(h))
    }
}

impl BuildService {
    fn linked_saved(&self, lib: &str) -> RegistryData {
        LinkedRegistry::read_saved(&self.live_dir(lib).join(".local")).unwrap_or_default()
    }

    /// The books of `lib` whose linked file was present at the last check. Read once, then asked for each book.
    pub(crate) fn linked_presence(&self, lib: &str) -> LinkedPresence {
        let mut p = LinkedPresence { docs: HashSet::new(), hashes: HashSet::new() };
        for book in self.linked_saved(lib).books.iter().filter(|b| b.locations.iter().any(|l| l.available && inside(&l.relative_path))) {
            p.hashes.insert(book.blake3.clone());
            if let Some(d) = &book.doc_id {
                p.docs.insert(d.clone());
            }
        }
        p
    }

    /// Is this book's PDF on this device: the filed copy is there, or a linked file holds it and was present at the last check. A
    /// linked book has no filed copy (its `source_rel` stays empty), so the second is the only way it counts.
    pub(crate) fn pdf_on_device(&self, lib: &str, b: &Book, presence: &LinkedPresence) -> bool {
        self.source_of(lib, b).is_file() || presence.has(b)
    }

    /// Every linked folder of every library: the library id and the folder's saved registry entry.
    fn linked_folders(&self) -> Vec<(String, RegistryData)> {
        self.library_refs().into_iter().map(|r| {
            let data = self.linked_saved(&r.library_id);
            (r.library_id, data)
        }).filter(|(_, d)| !d.roots.is_empty()).collect()
    }

    /// Does this path overlap a linked folder (the same, inside it, or around it)? The drop folder must never.
    pub(crate) fn overlaps_linked_folder(&self, folder: &Path) -> bool {
        let f = canonical_or_self(folder);
        self.linked_folders().iter().flat_map(|(_, d)| d.roots.iter()).any(|r| {
            let r = canonical_or_self(&r.path);
            f.starts_with(&r) || r.starts_with(&f)
        })
    }
}

/// `GET /api/linked-folders/<library>/books/<doc>`: where a book's original is. Each place is a linked folder (its label), the path
/// inside it, whether the last check found the file, why not, and when it was last seen. Never a path outside a linked folder: only
/// folders still registered, and only paths of plain names inside them, are listed (and never the folder's own location).
pub(super) fn places(service: &BuildService, lib: &str, doc: &str) -> Result<Value, ApiErr> {
    let data = service.linked_saved(lib);
    let book = service.book_of(lib, doc);
    let held = |h: &str| book.as_ref().is_some_and(|b| b.blake3 == h || b.original_blake3.as_deref() == Some(h));
    let matched: Vec<_> = data.books.iter().filter(|b| b.doc_id.as_deref() == Some(doc) || held(&b.blake3)).collect();
    if book.is_none() && matched.is_empty() {
        return Err(error(404, "no such book"));
    }
    let mut out: Vec<(String, String, Value)> = vec![];
    for b in matched {
        for l in &b.locations {
            let Some(root) = data.roots.iter().find(|r| r.id == l.root_id) else { continue };
            if !inside(&l.relative_path) {
                continue;
            }
            out.push((root.label.clone(), l.relative_path.clone(), json!({
                "folder_id": root.id, "folder": root.label, "path": l.relative_path,
                "present": l.available, "reason": l.reason, "last_seen_ms": l.last_seen_ms,
            })));
        }
    }
    out.sort_by(|a, b| (&a.0, &a.1).cmp(&(&b.0, &b.1)));
    Ok(json!({"library": lib, "id": doc, "places": out.into_iter().map(|p| p.2).collect::<Vec<_>>()}))
}

/// `GET /api/linked-folders/storage`: what each linked folder holds, across all libraries. `books` is the number of its places that
/// are present and hold a book of the library; `bytes` is the total size of those files from the sizes the last check recorded.
/// Nothing is scanned. These are the person's own files, read in place: not part of Cache's storage.
pub(super) fn storage(service: &BuildService) -> Value {
    let mut folders = vec![];
    for (lib, data) in service.linked_folders() {
        // a library Cache builds has its own list of books; a book it holds counts before the next check has matched it
        let known: HashSet<String> = service.linked_catalog(&lib).map(|v| v.into_iter().map(|(h, ..)| h).collect()).unwrap_or_default();
        for root in &data.roots {
            let (mut books, mut bytes) = (0u64, 0u64);
            for book in data.books.iter().filter(|b| b.doc_id.is_some() || known.contains(&b.blake3)) {
                for l in book.locations.iter().filter(|l| l.root_id == root.id && l.available && inside(&l.relative_path)) {
                    books += 1;
                    bytes = bytes.saturating_add(root.state.get(&l.relative_path).map_or(0, |s| s.length));
                }
            }
            folders.push(json!({"library": lib, "library_title": service.lib_title(&lib), "folder_id": root.id, "label": root.label, "books": books, "bytes": bytes}));
        }
    }
    json!({"folders": folders})
}

/// "Forget this book": for a book whose linked file is missing. The book leaves the library and its hash is recorded for good, so
/// the automatic checks never add it back. Refused (409) while a linked file is present, and for a book that is not held by a linked
/// file only or that has a copy kept on this device. The caller holds the library's operation lock with no check running. Nothing in
/// a linked folder is touched.
pub(super) fn forget(service: &BuildService, lib: &str, target: &Path, doc: &str) -> Result<Value, ApiErr> {
    let book = service.book_of(lib, doc).ok_or_else(|| error(404, "no such book"))?;
    let mut registry = LinkedRegistry::open(&target.join(".local"), target).map_err(io_error)?;
    let places: Vec<_> = registry.local_config().books.iter()
        .filter(|b| b.doc_id.as_deref() == Some(doc) || b.blake3 == book.blake3 || book.original_blake3.as_deref() == Some(b.blake3.as_str()))
        .cloned().collect();
    if places.iter().all(|b| b.locations.is_empty()) {
        return Err(error(409, "this book has no linked file"));
    }
    if places.iter().any(|b| b.locations.iter().any(|l| l.available)) {
        return Err(error(409, "the linked file is present"));
    }
    if service.source_of(lib, &book).is_file() {
        return Err(error(409, "this book is kept on this device"));
    }
    let mut hashes: Vec<String> = places.iter().map(|b| b.blake3.clone()).collect();
    hashes.extend(places.iter().flat_map(|b| b.locations.iter().map(|l| l.blake3.clone())));
    service.delete_book(lib, doc)?; // records the book's own hashes as deleted
    service.remember_deleted(lib, &hashes);
    let set: BTreeSet<String> = hashes.into_iter().collect();
    registry.forget_books(&set).map_err(io_error)?;
    Ok(json!({"forgotten": true, "id": doc}))
}
