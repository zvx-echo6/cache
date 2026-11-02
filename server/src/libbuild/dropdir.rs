//! The drop folder: one folder on this device that works as a queue moved between folders.
//!
//! `<folder>/ingest/` is the queue. A file there is taken once its size and modification time have not changed for the settle time
//! (30 s). PDFs are queued for the chosen library and, when the book is done (or skipped as a duplicate), moved to `complete/`;
//! when it fails (or the PDF has no text layer), to `failed/` with `<name>.why.txt` saying why. A `.zim` is installed like an
//! upload and moved to `complete/`; a `.cache-library`, or a `.gz` that starts with the gzip magic, is put where an upload of a
//! library package goes (`incoming/`) and moved to `complete/`; anything else goes to `failed/` as "Not a file Cache can use".
//! Retry moves a failed file back to `ingest/`, where it joins the end of the queue. A file taken out of `ingest/` by hand simply
//! leaves the queue. Names that already exist in `complete/` or `failed/` get " (2)", " (3)" and so on.
//!
//! There is no file-watching crate in the lockfile, so the folder is looked at every 2 minutes (and 31 s later while a file is
//! still settling), and on "Check now". A missing folder (an unplugged disk) or no permission is shown in the status; the files
//! stay where they are and the next check tries again.

use super::{lock, Item, Origin, S};
use cache_builder::compress::Compression;
use crate::library::{now_rfc3339, random_hex, sanitize_name, ApiErr};
use crate::libbuild::BuildService;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

pub const NOT_USABLE: &str = "Not a file Cache can use";
const LIST_CAP: usize = 200;

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct DropSettings {
    pub folder: String,
    pub enabled: bool,
    #[serde(default)]
    pub library_id: Option<String>,
    /// How files from the folder are compressed when they are stored (off unless chosen).
    #[serde(default)]
    pub compression: Compression,
}

#[derive(Clone, Default)]
struct Status {
    last_check: Option<String>,
    found: usize,
    /// (code, message)
    error: Option<(String, String)>,
}

pub struct DropState {
    settings: Mutex<DropSettings>,
    status: Mutex<Status>,
    /// path -> (size, mtime seconds, when this size and time were first seen)
    seen: Mutex<HashMap<PathBuf, (u64, u64, Instant)>>,
    last_files: Mutex<Option<Value>>,
    scan_lock: Mutex<()>,
    wake: (Mutex<bool>, Condvar),
}

impl DropState {
    pub fn load(data: &Path) -> DropState {
        let default = DropSettings { folder: data.join("drop").to_string_lossy().into_owned(), enabled: false, library_id: None, compression: Compression::OFF };
        let settings = std::fs::read_to_string(data.join("build/drop.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or(default);
        DropState {
            settings: Mutex::new(settings),
            status: Mutex::new(Status::default()),
            seen: Mutex::new(HashMap::new()),
            last_files: Mutex::new(None),
            scan_lock: Mutex::new(()),
            wake: (Mutex::new(false), Condvar::new()),
        }
    }
}

fn ingest(root: &Path) -> PathBuf {
    root.join("ingest")
}

fn kind_code(e: &std::io::Error) -> (&'static str, String) {
    match e.kind() {
        std::io::ErrorKind::NotFound => ("missing", "The drop folder is missing".into()),
        std::io::ErrorKind::PermissionDenied => ("denied", "Cache can not read the drop folder".into()),
        _ => ("error", format!("The drop folder could not be used: {e}")),
    }
}

/// `name` made unique in `dir`: "book.pdf" -> "book (2).pdf" -> "book (3).pdf". A note file `<name>.why.txt` counts as taking the name.
pub fn unique_name(dir: &Path, name: &str) -> String {
    let taken = |n: &str| dir.join(n).exists() || dir.join(format!("{n}.why.txt")).exists();
    if !taken(name) {
        return name.to_string();
    }
    let (stem, ext) = match name.rfind('.') {
        Some(i) if i > 0 => (&name[..i], &name[i..]),
        _ => (name, ""),
    };
    let mut n = 2;
    loop {
        let cand = format!("{stem} ({n}){ext}");
        if !taken(&cand) {
            return cand;
        }
        n += 1;
    }
}

/// Move `src` into `dir` under a free name; the name it got.
pub(crate) fn move_unique(src: &Path, dir: &Path, name: &str) -> std::io::Result<String> {
    std::fs::create_dir_all(dir)?;
    let final_name = unique_name(dir, name);
    let dest = dir.join(&final_name);
    if std::fs::rename(src, &dest).is_err() {
        std::fs::copy(src, &dest)?;
        std::fs::remove_file(src)?;
    }
    Ok(final_name)
}

fn link_or_copy(src: &Path, dst: &Path) -> std::io::Result<()> {
    if std::fs::hard_link(src, dst).is_ok() {
        return Ok(());
    }
    std::fs::copy(src, dst).map(|_| ())
}

fn mtime_secs(m: &std::fs::Metadata) -> u64 {
    m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs())
}

struct Entry {
    name: String,
    /// Relative to the folder listed (the same as `name` unless the tree is walked).
    rel: String,
    path: PathBuf,
    size: u64,
    mtime: u64,
}

/// The visible files of a folder (not hidden, not notes), oldest first.
fn list_files(dir: &Path) -> std::io::Result<Vec<Entry>> {
    let mut out = vec![];
    for e in std::fs::read_dir(dir)? {
        let Ok(e) = e else { continue };
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name.ends_with(".why.txt") {
            continue;
        }
        let Ok(md) = e.metadata() else { continue };
        if !md.is_file() {
            continue;
        }
        out.push(Entry { rel: name.clone(), name, path: e.path(), size: md.len(), mtime: mtime_secs(&md) });
    }
    out.sort_by(|a, b| a.mtime.cmp(&b.mtime).then(a.name.cmp(&b.name)));
    Ok(out)
}

/// Every visible file under `dir` (`complete/` is a tree of class and division folders), oldest first; `rel` is the path below `dir`.
fn list_tree(dir: &Path) -> Vec<Entry> {
    fn walk(base: &Path, dir: &Path, out: &mut Vec<Entry>, depth: usize) {
        let Ok(rd) = std::fs::read_dir(dir) else { return };
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if name.starts_with('.') || name.ends_with(".why.txt") {
                continue;
            }
            let Ok(md) = e.metadata() else { continue };
            if md.is_dir() {
                if depth < 4 {
                    walk(base, &e.path(), out, depth + 1);
                }
            } else if md.is_file() {
                let rel = e.path().strip_prefix(base).map(|p| p.components().map(|c| c.as_os_str().to_string_lossy().into_owned()).collect::<Vec<_>>().join("/")).unwrap_or_else(|_| name.clone());
                out.push(Entry { name, rel, path: e.path(), size: md.len(), mtime: mtime_secs(&md) });
            }
        }
    }
    let mut out = vec![];
    walk(dir, dir, &mut out, 0);
    out.sort_by(|a, b| a.mtime.cmp(&b.mtime).then(a.rel.cmp(&b.rel)));
    out
}

fn has_gzip_magic(p: &Path) -> bool {
    use std::io::Read;
    let mut b = [0u8; 2];
    std::fs::File::open(p).and_then(|mut f| f.read_exact(&mut b)).is_ok() && b == [0x1f, 0x8b]
}

impl BuildService {
    pub(crate) fn drop_compression(&self) -> Compression {
        self.drop_settings().compression
    }

    fn drop_settings(&self) -> DropSettings {
        lock(&self.drop.settings).clone()
    }

    /// The drop folder's path.
    pub(crate) fn drop_folder(&self) -> String {
        self.drop_settings().folder
    }

    /// The library the drop folder fills has been deleted: PDFs wait until another is chosen.
    pub(crate) fn forget_drop_library(&self, id: &str) {
        let mut s = lock(&self.drop.settings);
        if s.library_id.as_deref() == Some(id) {
            s.library_id = None;
            let _ = super::write_json(&self.data.join("build/drop.json"), &*s);
        }
    }

    pub(crate) fn poke_drop(&self) {
        *lock(&self.drop.wake.0) = true;
        self.drop.wake.1.notify_all();
    }

    fn sleep_drop(&self, d: Duration) {
        let g = lock(&self.drop.wake.0);
        let (mut g, _) = self.drop.wake.1.wait_timeout_while(g, d, |p| !*p && !self.is_stopping()).unwrap_or_else(|e| e.into_inner());
        *g = false;
    }

    /// Make `ingest/`, `complete/` and `failed/` under the folder (the folder itself must exist).
    fn make_subfolders(root: &Path) -> std::io::Result<()> {
        for d in ["ingest", "complete", "failed"] {
            std::fs::create_dir_all(root.join(d))?;
        }
        Ok(())
    }

    /// `PUT /api/build/drop {folder?, enabled?, library_id?}`: any of the three; the rest stay.
    pub fn drop_put(&self, body: &[u8]) -> Result<Value, ApiErr> {
        let v: Value = serde_json::from_slice(body).map_err(|_| super::err(400, "bad_json", "the body is not JSON"))?;
        let mut s = self.drop_settings();
        if let Some(f) = v.get("folder") {
            let f = f.as_str().ok_or_else(|| super::err(400, "invalid", "\"folder\" is a path"))?.trim();
            let p = Path::new(f);
            if f.is_empty() || !p.is_absolute() || f.contains('\0') || p.components().any(|c| matches!(c, std::path::Component::ParentDir)) {
                return Err(super::err(400, "invalid", "The folder must be a full path on this device."));
            }
            s.folder = f.to_string();
        }
        if let Some(e) = v.get("enabled") {
            s.enabled = e.as_bool().ok_or_else(|| super::err(400, "invalid", "\"enabled\" is true or false"))?;
        }
        if let Some(l) = v.get("library_id") {
            match l.as_str() {
                None if l.is_null() => s.library_id = None,
                Some(id) if self.has_library(id) => s.library_id = Some(id.to_string()),
                Some(_) => return Err(super::err(404, "not_found", "no such library")),
                None => return Err(super::err(400, "invalid", "\"library_id\" is a library id or null")),
            }
        }
        if let Some(c) = v.get("compression") {
            s.compression = serde_json::from_value::<Compression>(c.clone())
                .ok()
                .and_then(|c| Compression::from_parts(c.level, c.preset.map(|p| p.name())).ok())
                .ok_or_else(|| super::err(400, "invalid", "\"compression\" is {\"level\": off|lossless|smaller_scans, \"preset\": high|balanced|smallest}"))?;
        }
        super::write_json(&self.data.join("build/drop.json"), &s).map_err(|e| super::err(500, "server_error", format!("could not save the settings: {e}")))?;
        *lock(&self.drop.settings) = s.clone();
        if s.enabled {
            // The person chose this folder, so it is made; a failure shows in the status at the next check.
            let root = PathBuf::from(&s.folder);
            let _ = std::fs::create_dir_all(&root).and_then(|_| BuildService::make_subfolders(&root));
        }
        self.poke_drop();
        Ok(self.drop_view())
    }

    /// `POST /api/build/drop/check`: look at the folder now.
    pub fn drop_check(self: &Arc<Self>) -> Value {
        self.scan();
        self.drop_view()
    }

    /// `POST /api/build/drop/retry {name}`: a file in `failed/` goes back to `ingest/`, to the end of the queue.
    pub fn drop_retry(self: &Arc<Self>, body: &[u8]) -> Result<Value, ApiErr> {
        let v: Value = serde_json::from_slice(body).map_err(|_| super::err(400, "bad_json", "the body is not JSON"))?;
        let name = v["name"].as_str().ok_or_else(|| super::err(400, "invalid", "\"name\" is required"))?;
        if name.contains(['/', '\\']) || name.starts_with('.') || name.is_empty() {
            return Err(super::err(400, "invalid_name", "That file name is not allowed."));
        }
        let root = PathBuf::from(self.drop_settings().folder);
        self.move_back(&root, name).map_err(|m| super::err(409, "cannot_retry", m))?;
        // the failed record of that file (if the queue still has one) is replaced by the new one the next check makes
        {
            let mut st = lock(&self.st);
            st.items.retain(|i| !(i.origin == Origin::Drop && i.moved_to.as_deref() == Some(name) && matches!(i.state, S::Failed | S::OcrNeeded)));
            self.save_queue_locked(&st);
        }
        self.poke_drop();
        Ok(self.drop_view())
    }

    /// `failed/<name>` -> `ingest/` (and its note file goes).
    fn move_back(&self, root: &Path, name: &str) -> Result<(), String> {
        let src = root.join("failed").join(name);
        if !src.is_file() {
            return Err("That file is not in failed/ any more.".into());
        }
        move_unique(&src, &ingest(root), name).map_err(|e| format!("Could not move the file back: {e}"))?;
        let _ = std::fs::remove_file(root.join("failed").join(format!("{name}.why.txt")));
        Ok(())
    }

    /// A failed book of the drop folder, tried again from the queue list.
    pub(crate) fn retry_drop_item(&self, it: &Item) -> Result<(), String> {
        let name = it.moved_to.clone().ok_or("That file is not in failed/ any more.")?;
        let root = Path::new(&it.path).parent().and_then(|p| p.parent()).map(Path::to_path_buf).ok_or("The drop folder is not known.")?;
        self.move_back(&root, &name)?;
        self.poke_drop();
        Ok(())
    }

    /// After a drop-folder book is done, skipped, failed or needs OCR: move its file out of `ingest/`. A built book's file is filed in
    /// `complete/` like its source copy (`<class>/<division>/<call number>  <title>.pdf`, such as `CDS 530-001  <title>.pdf`); a copy that was not kept goes to Removed.
    pub(crate) fn settle_drop_item(&self, id: &str) {
        let Some(it) = lock(&self.st).items.iter().find(|i| i.id == id).cloned() else { return };
        let src = PathBuf::from(&it.path);
        if !src.exists() {
            return;
        }
        let Some(root) = src.parent().and_then(|p| p.parent()).map(Path::to_path_buf) else { return };
        let result: std::io::Result<String> = match it.state {
            S::Done => {
                let filed = it.doc_id.as_deref().and_then(|d| self.book_of(&it.library_id, d));
                match filed {
                    Some(b) => {
                        let cls = self.classes();
                        let dir = root.join("complete").join(cls.folder_rel(b.division.as_deref()));
                        let name = super::classify::file_name(&b.call_number(), &b.title);
                        move_unique(&src, &dir, &name).map(|n| {
                            let rel = format!("{}/{}", cls.folder_rel(b.division.as_deref()).to_string_lossy().replace('\\', "/"), n);
                            self.note_drop_copy(&it.library_id, &b.doc_id, &dir.join(&n), &root);
                            rel
                        })
                    }
                    None => move_unique(&src, &root.join("complete"), &it.file_name),
                }
            }
            S::SkippedDuplicate => {
                let why = it.result.clone().unwrap_or_else(|| "Not kept".into());
                self.to_removed(&src, &it.file_name, &why, "drop", &it.library_id).map_err(std::io::Error::other).map(|_| String::new())
            }
            S::NeedsDecision => return,
            _ => {
                let reason = it.error.clone().unwrap_or_else(|| "The book could not be built.".into());
                move_unique(&src, &root.join("failed"), &it.file_name).inspect(|n| {
                    let _ = std::fs::write(root.join("failed").join(format!("{n}.why.txt")), format!("{reason}\n"));
                })
            }
        };
        let mut st = lock(&self.st);
        if let Some(x) = st.items.iter_mut().find(|i| i.id == id) {
            match result {
                Ok(n) if n.is_empty() => {}
                Ok(n) => x.moved_to = Some(n),
                Err(e) => {
                    x.state = S::Failed;
                    x.error = Some(format!("The file could not be moved out of ingest/: {e}"));
                }
            }
        }
        self.save_queue_locked(&st);
    }

    fn put_status(&self, error: Option<(String, String)>, found: usize) {
        let mut s = lock(&self.drop.status);
        s.last_check = Some(now_rfc3339());
        s.found = found;
        s.error = error;
    }

    /// Look at the folder once. True when a file is still settling (so the next look should come soon).
    pub fn scan(self: &Arc<Self>) -> bool {
        let _one = lock(&self.drop.scan_lock);
        let s = self.drop_settings();
        if !s.enabled {
            self.put_status(None, 0);
            return false;
        }
        let root = PathBuf::from(&s.folder);
        if !root.is_dir() {
            let code = if root.exists() { ("error", "The drop folder is not a folder".to_string()) } else { ("missing", "The drop folder is missing".to_string()) };
            self.put_status(Some((code.0.into(), code.1)), 0);
            return false;
        }
        if let Err(e) = BuildService::make_subfolders(&root) {
            let (c, m) = kind_code(&e);
            self.put_status(Some((c.into(), m)), 0);
            return false;
        }
        let entries = match list_files(&ingest(&root)) {
            Ok(v) => v,
            Err(e) => {
                let (c, m) = kind_code(&e);
                self.put_status(Some((c.into(), m)), 0);
                return false;
            }
        };
        // Books queued from ingest/ whose file was taken out by hand leave the queue.
        {
            let mut st = lock(&self.st);
            let ing = ingest(&root);
            let before = st.items.len();
            st.items.retain(|i| !(i.origin == Origin::Drop && i.state == S::Queued && Path::new(&i.path).parent() == Some(ing.as_path()) && !Path::new(&i.path).exists()));
            if st.items.len() != before {
                self.save_queue_locked(&st);
            }
        }
        // What the queue already knows: live books, and finished ones whose file is still here unchanged.
        let tracked: HashSet<String> = {
            let st = lock(&self.st);
            let mtimes: HashMap<&str, u64> = entries.iter().map(|e| (e.path.to_str().unwrap_or(""), e.mtime)).collect();
            st.items
                .iter()
                .filter(|i| i.origin == Origin::Drop)
                .filter(|i| i.state.live() || i.finished_epoch.is_some_and(|f| mtimes.get(i.path.as_str()).is_some_and(|m| *m <= f)))
                .map(|i| i.path.clone())
                .collect()
        };
        let now = Instant::now();
        let mut pending = false;
        let mut found = 0usize;
        let mut no_library = false;
        for e in &entries {
            if tracked.contains(e.path.to_str().unwrap_or("")) {
                continue;
            }
            let settled = {
                let mut seen = lock(&self.drop.seen);
                match seen.get(&e.path) {
                    Some((sz, mt, since)) if *sz == e.size && *mt == e.mtime => now.duration_since(*since) >= self.cfg.settle,
                    _ => {
                        seen.insert(e.path.clone(), (e.size, e.mtime, now));
                        self.cfg.settle.is_zero()
                    }
                }
            };
            if !settled {
                pending = true;
                continue;
            }
            let ext = Path::new(&e.name).extension().map(|x| x.to_string_lossy().to_lowercase()).unwrap_or_default();
            match ext.as_str() {
                "pdf" => {
                    let Some(lib) = s.library_id.clone().filter(|l| self.has_library(l)) else {
                        no_library = true;
                        continue;
                    };
                    let item = Item::new(random_hex(), lib, e.path.to_string_lossy().into_owned(), e.name.clone(), e.size, Origin::Drop);
                    // an older record of the same path (a file dropped again) goes
                    {
                        let mut st = lock(&self.st);
                        st.items.retain(|i| !(i.origin == Origin::Drop && i.path == item.path && !i.state.live()));
                    }
                    if self.enqueue(item).is_ok() {
                        found += 1;
                    }
                }
                "zim" | "cache-library" | "gz" => {
                    found += 1;
                    let r = self.drop_install(e, &ext);
                    self.file_away(&root, e, if ext == "zim" { "ZIM files" } else { "Library files" }, r);
                }
                _ => {
                    found += 1;
                    self.file_away(&root, e, "", Err(NOT_USABLE.to_string()));
                }
            }
        }
        lock(&self.drop.seen).retain(|p, _| p.exists());
        let error = no_library.then(|| ("no_library".to_string(), "Choose the library the PDFs go into".to_string()));
        self.put_status(error, found);
        self.poke();
        pending
    }

    /// Move a handled file to `complete/` (on Ok) or `failed/` with its note (on Err).
    fn file_away(&self, root: &Path, e: &Entry, sub: &str, r: Result<(), String>) {
        match r {
            Ok(()) => {
                if let Err(x) = move_unique(&e.path, &root.join("complete").join(sub), &e.name) {
                    eprintln!("cache-server: moving {} to complete/: {x}", e.name);
                }
            }
            Err(reason) => match move_unique(&e.path, &root.join("failed"), &e.name) {
                Ok(n) => {
                    let _ = std::fs::write(root.join("failed").join(format!("{n}.why.txt")), format!("{reason}\n"));
                }
                Err(x) => eprintln!("cache-server: moving {} to failed/: {x}", e.name),
            },
        }
    }

    /// Install a ZIM or library package from the drop folder the way an upload is installed. The file itself stays in `ingest/`
    /// (a hard link, or a copy across file systems, is what gets installed).
    fn drop_install(&self, e: &Entry, ext: &str) -> Result<(), String> {
        let tmp = self.data.join("tmp");
        std::fs::create_dir_all(&tmp).map_err(|x| format!("Could not make a work folder: {x}"))?;
        let part = tmp.join(format!("drop-{}.part", random_hex()));
        let result = (|| -> Result<(), String> {
            match ext {
                "zim" => {
                    let name = sanitize_name(&e.name, "zim")?;
                    link_or_copy(&e.path, &part).map_err(|x| format!("Could not read the file: {x}"))?;
                    self.lib.install_zim(&part, &name, None, None).map_err(|x| format!("Could not install the file: {x}"))?;
                    self.rescan();
                    Ok(())
                }
                _ => {
                    if ext == "gz" && !has_gzip_magic(&e.path) {
                        return Err(NOT_USABLE.to_string());
                    }
                    let name = sanitize_name(&e.name, "library")?;
                    link_or_copy(&e.path, &part).map_err(|x| format!("Could not read the file: {x}"))?;
                    self.lib.install_incoming(&part, &name).map_err(|x| format!("Could not install the file: {x}"))?;
                    Ok(())
                }
            }
        })();
        let _ = std::fs::remove_file(&part);
        result
    }

    // ---- the view

    fn files_view(&self, root: &Path) -> std::io::Result<(Vec<Value>, Value)> {
        let ing = list_files(&ingest(root))?;
        let complete = list_tree(&root.join("complete"));
        let failed = list_files(&root.join("failed")).unwrap_or_default();
        let st = lock(&self.st);
        let mut files: Vec<Value> = vec![];
        // ingest/: the queue order, then files not taken yet
        let mut in_queue: Vec<(&Item, &Entry)> = vec![];
        for it in st.items.iter().filter(|i| i.origin == Origin::Drop && i.state.live()) {
            if let Some(e) = ing.iter().find(|e| e.path.to_str() == Some(it.path.as_str())) {
                in_queue.push((it, e));
            }
        }
        let mut rank = 0;
        for (it, e) in &in_queue {
            rank += 1;
            let working = it.state.working();
            files.push(json!({
                "name": e.name, "folder": "ingest", "state": if working { "working" } else { "queued" }, "position": rank, "size": e.size,
                "progress": {"pages": it.pages, "pieces": it.pieces_done, "pieces_total": it.pieces_total, "ocr_pages": it.ocr_pages},
                "item_id": it.id, "reason": null, "can_retry": false,
            }));
        }
        for e in ing.iter().filter(|e| !in_queue.iter().any(|(_, q)| q.path == e.path)) {
            let stuck = st.items.iter().find(|i| i.origin == Origin::Drop && i.path.as_str() == e.path.to_str().unwrap_or("") && !i.state.live());
            let waiting = stuck.is_some_and(|i| i.state == S::NeedsDecision);
            files.push(json!({
                "name": e.name, "folder": "ingest", "state": if waiting { "needs_decision" } else if stuck.is_some() { "failed" } else { "new" },
                "position": null, "size": e.size, "progress": null, "item_id": stuck.map(|i| i.id.clone()),
                "reason": stuck.and_then(|i| if waiting { i.result.clone() } else { i.error.clone() }), "can_retry": false,
            }));
        }
        let cls = self.classes();
        for e in complete.iter().rev().take(LIST_CAP) {
            let item = st.items.iter().rev().find(|i| i.origin == Origin::Drop && i.moved_to.as_deref() == Some(e.rel.as_str()) && matches!(i.state, S::Done | S::SkippedDuplicate));
            let dup = item.filter(|i| i.state == S::SkippedDuplicate);
            let done = item.filter(|i| i.state == S::Done);
            let book = done.and_then(|i| i.doc_id.as_deref().and_then(|d| st.libs.iter().find(|l| l.id == i.library_id).and_then(|l| l.books.iter().find(|b| b.doc_id == d))));
            let (class, division) = book.and_then(|b| b.division.as_deref()).and_then(|d| cls.find(d)).map_or((None, None), |(c, d)| (Some(c.number.clone()), Some(d.number.clone())));
            let place = e.rel.rsplit_once('/').map(|(p, _)| p.to_string());
            files.push(json!({
                "name": e.name, "path": e.rel, "where": place, "folder": "complete", "state": if dup.is_some() { "duplicate" } else { "done" },
                "position": null, "size": e.size, "progress": null, "item_id": null, "can_retry": false,
                "reason": dup.map(|i| format!("Duplicate: the same content is already in {}", i.duplicate_of.clone().unwrap_or_default())).or_else(|| done.and_then(|i| i.result.clone())),
                "note": done.and_then(|i| i.note.clone()),
                "class": class, "division": division, "call_number": book.map(|b| b.call_number()).filter(|c| !c.is_empty()), "title": book.map(|b| b.title.clone()),
                "moved_from": book.and_then(|b| b.moved_from.clone()),
            }));
        }
        // Copies Cache did not keep (an exact copy, a worse copy) are in Removed; their results are shown here too.
        let removed: Vec<&Item> = st.items.iter().rev().filter(|i| i.origin == Origin::Drop && i.state == S::SkippedDuplicate && i.moved_to.is_none()).take(LIST_CAP).collect();
        for i in &removed {
            files.push(json!({
                "name": i.file_name, "folder": "removed", "state": "duplicate", "position": null, "size": i.size, "progress": null,
                "item_id": i.id, "reason": i.result, "can_retry": false,
            }));
        }
        for e in failed.iter().rev().take(LIST_CAP) {
            let why = std::fs::read_to_string(root.join("failed").join(format!("{}.why.txt", e.name))).ok().map(|t| t.trim().to_string());
            let unsupported = why.as_deref() == Some(NOT_USABLE);
            files.push(json!({
                "name": e.name, "folder": "failed", "state": if unsupported { "unsupported" } else { "failed" }, "position": null, "size": e.size,
                "progress": null, "item_id": null, "reason": why, "can_retry": !unsupported,
            }));
        }
        let counts = json!({"all": ing.len() + complete.len() + failed.len(), "queue": ing.len(), "complete": complete.len(), "failed": failed.len(), "removed": removed.len()});
        Ok((files, counts))
    }

    /// `GET /api/build/drop`.
    pub fn drop_view(&self) -> Value {
        let s = self.drop_settings();
        let status = lock(&self.drop.status).clone();
        let root = PathBuf::from(&s.folder);
        let mut stale = false;
        let (files, counts) = if !s.enabled || status.error.is_some() {
            match lock(&self.drop.last_files).clone() {
                Some(v) => {
                    stale = status.error.is_some();
                    (v["files"].clone(), v["counts"].clone())
                }
                None => (json!([]), json!({"all": 0, "queue": 0, "complete": 0, "failed": 0, "removed": 0})),
            }
        } else {
            match self.files_view(&root) {
                Ok((f, c)) => {
                    *lock(&self.drop.last_files) = Some(json!({"files": f, "counts": c}));
                    (Value::Array(f), c)
                }
                Err(_) => {
                    stale = true;
                    match lock(&self.drop.last_files).clone() {
                        Some(v) => (v["files"].clone(), v["counts"].clone()),
                        None => (json!([]), json!({"all": 0, "queue": 0, "complete": 0, "failed": 0, "removed": 0})),
                    }
                }
            }
        };
        let state = if !s.enabled {
            "off"
        } else if status.error.as_ref().is_some_and(|(c, _)| c != "no_library") {
            "error"
        } else {
            "ok"
        };
        json!({
            "settings": {"folder": s.folder, "enabled": s.enabled, "library_id": s.library_id, "library_title": s.library_id.as_deref().and_then(|l| self.lib_title(l)), "compression": s.compression},
            "status": {
                "state": state, "last_check": status.last_check, "found": status.found, "counts": counts,
                "error": status.error.as_ref().map(|(c, m)| json!({"code": c, "message": m})), "stale": stale,
            },
            "files": files,
        })
    }
}

/// The thread that looks at the folder.
pub(crate) fn start(svc: &Arc<BuildService>) {
    let me = svc.clone();
    std::thread::spawn(move || {
        while !me.is_stopping() {
            let pending = me.scan();
            let wait = if pending { me.cfg.settle + Duration::from_secs(1) } else { me.cfg.poll };
            me.sleep_drop(wait);
        }
    });
}
