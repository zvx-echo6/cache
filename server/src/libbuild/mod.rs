//! The library builder service: books from PDFs, one at a time, in the background, into libraries the core searches.
//!
//! What lives where (everything is inside `<data>`):
//!
//! - `app/docs/libraries/<library_id>/` is a normal library the core opens (`shard/` and `cache-library.json`, so the helper's scan
//!   and index jobs treat it like any other) plus `packs/`: one `<doc_id>@<version>.cdoc` per book (see
//!   server/builder/PACK-FORMAT.md). The packs are the truth; the shard can always be made again from them.
//! - `app/docs/sources/<library_id>/<doc_id>.pdf` is the original PDF of every built book (see [`BuildService::source_path`]).
//! - `build/queue.json` is the queue, `build/libs/<library_id>.json` the books of each library, `build/drop.json` the drop folder
//!   settings, `build/pending/` the uploads waiting to be built, `build/work/<library_id>/shard/` the library's own read-write
//!   copy of the shard.
//!
//! **Swap safety.** The core only ever opens `libraries/<id>/shard`. A book is added to (or deleted from) the *work shard*, which
//! the core never sees, and the books are then published: the whole work shard is copied (every file synced, segments manifest
//! written, checked with the core's own library check) to `libraries/<id>/.shard.new.tmp`, renamed to `.shard.new` (so that name
//! only ever holds a finished copy), and then swapped in:
//!
//!  1. `shard/` -> `.shard.old` and `index/` -> `.index.old` (the old keyword index belongs to the old shard);
//!  2. the core is told to rescan (it lets go of the library);
//!  3. `cache-library.json` is rewritten, then `.shard.new` -> `shard/`;
//!  4. the core is told to rescan (it opens the new shard and the helper starts its keyword index job);
//!  5. `.shard.old` and `.index.old` are deleted.
//!
//! The name `shard/` therefore only ever holds a complete old shard or a complete new one. A crash between the steps is repaired at
//! the next start ([`BuildService::recover`]): no `shard/` and a `.shard.new` means step 3 goes on; no `shard/` and a `.shard.old`
//! means the old one is put back; leftovers are deleted. The keyword index is rebuilt by the helper after every swap (there is no
//! incremental keyword index yet), so a library is searchable by meaning at once and by keyword when that job ends.
//!
//! **The queue** is `queue.json`, written atomically at every change of state. One book at a time. A book that was being built when
//! the server stopped starts again from scratch. Pause finishes the current book and then holds; Stop drops the books still
//! waiting. A book is judged a duplicate by the BLAKE3 of its PDF within its library. Pages without a text layer are skipped and
//! counted ("partial: N pages need OCR"); a PDF with no text layer at all is `ocr_needed`, never `failed`.

use crate::embed::EmbedService;
use crate::library::{free_bytes, now_rfc3339, random_hex, sanitize_name, ApiErr, Library};
use cache_builder::incremental::{publish_copy, rebuild_from_packs, WorkShard};
use cache_builder::pack::{read_pack, write_pack, Pack};
use cache_builder::{build_pack_with, BuildOptions, Embedder, Progress};
use http_body_util::BodyExt;
use hyper::body::{Body, Bytes};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

pub mod dropdir;
#[cfg(test)]
pub(crate) mod testpdf;
#[cfg(test)]
pub(crate) mod tests;

/// Free space kept back when an upload is accepted, beyond the file itself.
const UPLOAD_HEADROOM: u64 = 256 << 20;
/// Finished items kept in the queue list.
const KEEP_FINISHED: usize = 1000;
const WAITING_FOR_MODEL: &str = "waiting for the search model";

fn err(status: u16, code: &'static str, message: impl Into<String>) -> ApiErr {
    ApiErr { status, code, message: message.into() }
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn epoch() -> u64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

// ---- the embedder seam

/// Why vectors could not be made.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EmbedErr {
    /// The search model is not ready yet: the book goes back to the queue and building waits.
    Waiting(String),
    Failed(String),
}

/// What the builder needs from the embedder: [`EmbedService`] on a real device, a fake in tests.
pub trait Embed: Send + Sync {
    /// Ok when vectors can be made now; otherwise why not (and a model download is started when that is what is missing).
    fn ready(&self) -> Result<(), String>;
    fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedErr>;
    /// Recorded in packs.
    fn name(&self) -> String;
}

impl Embed for Arc<EmbedService> {
    fn ready(&self) -> Result<(), String> {
        self.ready_reason()
    }
    fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbedErr> {
        match self.embed_batch(texts) {
            Ok(v) => Ok(v),
            Err(e) if e.code == "model_missing" => Err(EmbedErr::Waiting(WAITING_FOR_MODEL.into())),
            Err(e) => Err(EmbedErr::Failed(e.message)),
        }
    }
    fn name(&self) -> String {
        self.model_id().to_string()
    }
}

/// Lets the builder crate's synchronous `Embedder` call an [`Embed`], keeping the error for the caller.
struct Adapter<'a> {
    embed: &'a dyn Embed,
    error: Mutex<Option<EmbedErr>>,
}

impl Embedder for Adapter<'_> {
    fn embed_batch(&self, texts: &[String]) -> Vec<Vec<f32>> {
        match self.embed.embed(texts) {
            Ok(v) => v,
            Err(e) => {
                *lock(&self.error) = Some(e);
                Vec::new()
            }
        }
    }
    fn name(&self) -> String {
        self.embed.name()
    }
}

// ---- configuration

#[derive(Clone)]
pub struct BuildConfig {
    /// How long a file in the drop folder must keep its size before it is taken (30 s).
    pub settle: Duration,
    /// How often the drop folder is looked at (2 minutes: there is no file-watching crate in the lockfile).
    pub poll: Duration,
    /// While books keep arriving, a library is published at most this often (otherwise when its queue is empty or paused).
    pub publish_every: Duration,
    /// Test hook: called at every request to the core to rescan.
    pub on_rescan: Option<Arc<dyn Fn() + Send + Sync>>,
}

impl Default for BuildConfig {
    fn default() -> Self {
        BuildConfig { settle: Duration::from_secs(30), poll: Duration::from_secs(120), publish_every: Duration::from_secs(300), on_rescan: None }
    }
}

// ---- persisted data

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum S {
    Queued,
    Reading,
    OcrNeeded,
    Building,
    Done,
    SkippedDuplicate,
    Failed,
}

impl S {
    /// Waiting or being worked on.
    fn live(self) -> bool {
        matches!(self, S::Queued | S::Reading | S::Building)
    }
    fn working(self) -> bool {
        matches!(self, S::Reading | S::Building)
    }
}

#[derive(Clone, Copy, PartialEq, Eq, Debug, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Origin {
    Upload,
    Drop,
}

/// One book in the queue, as it is kept in `queue.json`.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Item {
    pub id: String,
    pub library_id: String,
    /// The PDF: `build/pending/<id>.pdf` for an upload, the file in `ingest/` for the drop folder.
    pub path: String,
    pub file_name: String,
    pub size: u64,
    pub origin: Origin,
    /// A title chosen by the person; otherwise the PDF's own, else the file name.
    #[serde(default)]
    pub title: Option<String>,
    /// The book this one replaces (a new edition): same `doc_id`, `doc_version + 1`.
    #[serde(default)]
    pub replace: Option<String>,
    pub state: S,
    #[serde(default)]
    pub pages: Option<u32>,
    #[serde(default)]
    pub pieces_done: u32,
    #[serde(default)]
    pub pieces_total: Option<u32>,
    #[serde(default)]
    pub ocr_pages: u32,
    #[serde(default)]
    pub error: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub doc_id: Option<String>,
    /// For a duplicate: the title of the book that has the same content.
    #[serde(default)]
    pub duplicate_of: Option<String>,
    /// For a drop-folder file that has been moved out of `ingest/`: its name in `complete/` or `failed/`.
    #[serde(default)]
    pub moved_to: Option<String>,
    pub created_at: String,
    #[serde(default)]
    pub started_at: Option<String>,
    #[serde(default)]
    pub finished_at: Option<String>,
    #[serde(default)]
    pub finished_epoch: Option<u64>,
}

impl Item {
    /// A book waiting in the queue.
    pub(crate) fn new(id: String, library_id: String, path: String, file_name: String, size: u64, origin: Origin) -> Item {
        Item {
            id,
            library_id,
            path,
            file_name,
            size,
            origin,
            title: None,
            replace: None,
            state: S::Queued,
            pages: None,
            pieces_done: 0,
            pieces_total: None,
            ocr_pages: 0,
            error: None,
            note: None,
            doc_id: None,
            duplicate_of: None,
            moved_to: None,
            created_at: now_rfc3339(),
            started_at: None,
            finished_at: None,
            finished_epoch: None,
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Book {
    pub doc_id: String,
    pub doc_version: u32,
    pub title: String,
    pub pages: u32,
    pub pieces: u32,
    pub ocr_pages: u32,
    pub blake3: String,
    pub size: u64,
    pub file_name: String,
    pub added_at: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct PendingDelete {
    pub doc_id: String,
    pub doc_version: u32,
    pub pieces: u32,
}

/// One built library: what `build/libs/<id>.json` holds.
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct LibMeta {
    pub id: String,
    pub title: String,
    pub created_at: String,
    #[serde(default)]
    pub books: Vec<Book>,
    /// Points to delete from the work shard (written with the change that made them stale, so a crash cannot lose them).
    #[serde(default)]
    pub pending_deletes: Vec<PendingDelete>,
    /// The work shard has changes the core's copy does not.
    #[serde(default)]
    pub dirty: bool,
    #[serde(default)]
    pub published_at: Option<String>,
    #[serde(default)]
    pub publish_seq: u32,
    #[serde(default)]
    pub publish_error: Option<String>,
}

#[derive(Serialize, Deserialize, Default)]
struct QueueFile {
    #[serde(default)]
    paused: bool,
    #[serde(default)]
    items: Vec<Item>,
}

pub(crate) struct State {
    pub paused: bool,
    pub items: Vec<Item>,
    pub libs: Vec<LibMeta>,
    /// Why building cannot start (the search model is not ready), shown with the queue.
    pub blocked: Option<String>,
    built_pieces: u64,
    built_secs: f64,
    last_publish: HashMap<String, Instant>,
    retry_after: HashMap<String, Instant>,
}

pub enum Run {
    /// A book was handled.
    Ran,
    /// Nothing to do (empty, or paused).
    Idle,
    /// Books are waiting but cannot be built yet.
    Blocked,
}

pub struct BuildService {
    pub(crate) data: PathBuf,
    pub(crate) lib: Arc<Library>,
    embed: Arc<dyn Embed>,
    pub(crate) cfg: BuildConfig,
    pub(crate) st: Mutex<State>,
    /// Held while pack files, work shards and the library folders change, and during a publish.
    ops: Mutex<()>,
    wake: (Mutex<bool>, Condvar),
    rt: Mutex<Option<tokio::runtime::Handle>>,
    pub(crate) drop: dropdir::DropState,
    stopping: AtomicBool,
}

fn write_json(path: &Path, v: &impl Serialize) -> std::io::Result<()> {
    let text = serde_json::to_string_pretty(v).map_err(std::io::Error::other)?;
    crate::write_private(path, text.as_bytes())
}

fn write_bytes_atomic(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let name = path.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
    let tmp = path.with_file_name(format!(".{name}.tmp"));
    {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, path).inspect_err(|_| {
        let _ = std::fs::remove_file(&tmp);
    })
}

/// A library id from its title: lowercase letters and digits joined by '-', then a short random suffix.
fn make_library_id(title: &str) -> String {
    let mut slug = String::new();
    for c in title.chars() {
        if c.is_ascii_alphanumeric() {
            slug.push(c.to_ascii_lowercase());
        } else if !slug.ends_with('-') && !slug.is_empty() {
            slug.push('-');
        }
    }
    let slug = slug.trim_matches('-');
    let slug: String = slug.chars().take(40).collect();
    let slug = slug.trim_matches('-');
    let suffix = &random_hex()[..6];
    if slug.is_empty() {
        format!("library-{suffix}")
    } else {
        format!("{slug}-{suffix}")
    }
}


fn friendly_error(raw: &str) -> String {
    if raw.contains("encrypted") || raw.contains("password") {
        "This PDF is protected with a password. Remove the password and add it again, or retry.".into()
    } else if ["opening the PDF", "reading the PDF", "counting pages", "loading a page", "page size", "reading page text"].iter().any(|p| raw.starts_with(p)) {
        "The file is damaged and could not be opened.".into()
    } else {
        raw.to_string()
    }
}

fn is_disk_full(e: &std::io::Error) -> bool {
    matches!(e.raw_os_error(), Some(28) | Some(112))
}

impl BuildService {
    /// Open the service on `data`: read the queue and the libraries, put interrupted books back in the queue, and finish any
    /// library swap a crash cut short. No thread is started (see [`BuildService::start`]).
    pub fn new(data: PathBuf, lib: Arc<Library>, embed: Arc<dyn Embed>, cfg: BuildConfig) -> Arc<BuildService> {
        for d in ["build/libs", "build/pending", "build/work", "app/docs/libraries", "app/docs/sources"] {
            let _ = std::fs::create_dir_all(data.join(d));
        }
        let q: QueueFile = std::fs::read_to_string(data.join("build/queue.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
        let mut libs: Vec<LibMeta> = vec![];
        if let Ok(rd) = std::fs::read_dir(data.join("build/libs")) {
            for e in rd.flatten() {
                if e.path().extension().is_some_and(|x| x == "json") {
                    if let Some(m) = std::fs::read_to_string(e.path()).ok().and_then(|t| serde_json::from_str::<LibMeta>(&t).ok()) {
                        libs.push(m);
                    }
                }
            }
        }
        libs.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));
        let mut items = q.items;
        for it in &mut items {
            if it.state.working() {
                it.state = S::Queued;
                it.pages = None;
                it.pieces_done = 0;
                it.pieces_total = None;
                it.ocr_pages = 0;
            }
        }
        let drop = dropdir::DropState::load(&data);
        // The clock for "publish at most every so often" starts now for every library.
        let last_publish: HashMap<String, Instant> = libs.iter().map(|l| (l.id.clone(), Instant::now())).collect();
        let svc = Arc::new(BuildService {
            data,
            lib,
            embed,
            cfg,
            st: Mutex::new(State {
                paused: q.paused,
                items,
                libs,
                blocked: None,
                built_pieces: 0,
                built_secs: 0.0,
                last_publish,
                retry_after: HashMap::new(),
            }),
            ops: Mutex::new(()),
            wake: (Mutex::new(false), Condvar::new()),
            rt: Mutex::new(tokio::runtime::Handle::try_current().ok()),
            drop,
            stopping: AtomicBool::new(false),
        });
        svc.recover();
        svc.save_queue();
        svc
    }

    /// Start the build thread and the drop-folder thread.
    pub fn start(self: &Arc<Self>) {
        let me = self.clone();
        std::thread::spawn(move || me.worker_loop());
        dropdir::start(self);
    }

    /// Ask the threads to end (used by tests and at shutdown).
    pub fn shutdown(&self) {
        self.stopping.store(true, Ordering::Relaxed);
        self.poke();
    }

    pub(crate) fn is_stopping(&self) -> bool {
        self.stopping.load(Ordering::Relaxed)
    }

    pub(crate) fn poke(&self) {
        *lock(&self.wake.0) = true;
        self.wake.1.notify_all();
    }

    /// Sleep until poked or `d` has passed.
    pub(crate) fn sleep(&self, d: Duration) {
        let g = lock(&self.wake.0);
        let (mut g, _) = self.wake.1.wait_timeout_while(g, d, |poked| !*poked && !self.is_stopping()).unwrap_or_else(|e| e.into_inner());
        *g = false;
    }

    // ---- paths

    fn libs_dir(&self) -> PathBuf {
        self.data.join("app/docs/libraries")
    }

    pub fn live_dir(&self, lib: &str) -> PathBuf {
        self.libs_dir().join(lib)
    }

    pub fn packs_dir(&self, lib: &str) -> PathBuf {
        self.live_dir(lib).join("packs")
    }

    fn work_dir(&self, lib: &str) -> PathBuf {
        self.data.join("build/work").join(lib).join("shard")
    }

    fn meta_path(&self, lib: &str) -> PathBuf {
        self.data.join("build/libs").join(format!("{lib}.json"))
    }

    fn pending_dir(&self) -> PathBuf {
        self.data.join("build/pending")
    }

    /// Where the original PDF of a book is kept. Everything that reads or writes a source copy goes through this one function,
    /// so filing the PDFs by subject later changes only this.
    pub fn source_path(&self, lib: &str, doc_id: &str) -> PathBuf {
        self.data.join("app/docs/sources").join(lib).join(format!("{doc_id}.pdf"))
    }

    // ---- persistence

    pub(crate) fn save_queue(&self) {
        let st = lock(&self.st);
        self.save_queue_locked(&st);
    }

    pub(crate) fn save_queue_locked(&self, st: &State) {
        let q = QueueFile { paused: st.paused, items: st.items.clone() };
        if let Err(e) = write_json(&self.data.join("build/queue.json"), &q) {
            eprintln!("cache-server: writing queue.json: {e}");
        }
    }

    fn save_meta(&self, m: &LibMeta) -> std::io::Result<()> {
        write_json(&self.meta_path(&m.id), m)
    }

    /// Keep the most recent finished items only (and throw away the uploads of the ones that go).
    fn prune(&self, st: &mut State) {
        let finished = st.items.iter().filter(|i| !i.state.live()).count();
        if finished <= KEEP_FINISHED {
            return;
        }
        let mut drop_n = finished - KEEP_FINISHED;
        let pending = self.pending_dir();
        st.items.retain(|i| {
            if drop_n > 0 && !i.state.live() {
                drop_n -= 1;
                if i.origin == Origin::Upload {
                    let _ = std::fs::remove_file(pending.join(format!("{}.pdf", i.id)));
                }
                return false;
            }
            true
        });
    }

    // ---- the core

    /// Tell the core to read the library folders again.
    fn rescan(&self) {
        if let Some(f) = &self.cfg.on_rescan {
            f();
        }
        if !self.lib.has_helper() {
            return;
        }
        let h = lock(&self.rt).clone();
        if let Some(h) = h {
            if let Err(e) = h.block_on(self.lib.rescan()) {
                eprintln!("cache-server: rescan after a library change failed: {e}");
            }
        }
    }

    // ---- recovery

    /// Repair what a crash left: library swaps cut short, and work done on a shard that was not yet published.
    fn recover(&self) {
        let ids: Vec<String> = lock(&self.st).libs.iter().map(|l| l.id.clone()).collect();
        for id in ids {
            let live = self.live_dir(&id);
            let (shard, new, old) = (live.join("shard"), live.join(".shard.new"), live.join(".shard.old"));
            if !shard.exists() {
                if new.is_dir() {
                    let _ = std::fs::rename(&new, &shard);
                } else if old.is_dir() {
                    let _ = std::fs::rename(&old, &shard);
                    if live.join(".index.old").is_dir() {
                        let _ = std::fs::rename(live.join(".index.old"), live.join("index"));
                    }
                }
            }
            if shard.exists() {
                for left in [".shard.old", ".index.old", ".shard.new", ".shard.new.tmp"] {
                    let _ = std::fs::remove_dir_all(live.join(left));
                }
            } else {
                let _ = std::fs::remove_dir_all(live.join(".shard.new.tmp"));
            }
        }
    }

    // ---- the worker

    fn worker_loop(self: Arc<Self>) {
        while !self.is_stopping() {
            match self.run_one() {
                Run::Ran => {}
                Run::Idle | Run::Blocked => self.sleep(Duration::from_secs(2)),
            }
        }
    }

    /// Handle the next waiting book, if any. The build thread calls this in a loop; tests call it directly.
    pub fn run_one(self: &Arc<Self>) -> Run {
        let picked = {
            let st = lock(&self.st);
            if st.paused {
                None
            } else {
                st.items.iter().position(|i| i.state == S::Queued)
            }
        };
        let Some(_) = picked else {
            self.publish_due();
            return Run::Idle;
        };
        if let Err(why) = self.embed.ready() {
            lock(&self.st).blocked = Some(why);
            self.publish_due();
            return Run::Blocked;
        }
        let item = {
            let mut st = lock(&self.st);
            st.blocked = None;
            // The queue may have changed while the model was checked.
            let Some(idx) = st.items.iter().position(|i| i.state == S::Queued) else { return Run::Idle };
            if st.paused {
                return Run::Idle;
            }
            let it = &mut st.items[idx];
            it.state = S::Reading;
            it.started_at = Some(now_rfc3339());
            it.error = None;
            let item = it.clone();
            self.save_queue_locked(&st);
            item
        };
        let started = Instant::now();
        let outcome = self.process(&item);
        self.finish(&item, outcome, started);
        self.publish_due();
        Run::Ran
    }

    fn update_item(&self, id: &str, f: impl FnOnce(&mut Item)) {
        let mut st = lock(&self.st);
        if let Some(it) = st.items.iter_mut().find(|i| i.id == id) {
            f(it);
        }
    }

    /// Read, check, extract, embed and store one book.
    fn process(&self, item: &Item) -> Outcome {
        let bytes = match std::fs::read(&item.path) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound && item.origin == Origin::Drop => return Outcome::Gone,
            Err(e) => return Outcome::Failed(format!("The file could not be read: {e}")),
        };
        let hash = blake3::hash(&bytes).to_hex().to_string();
        let (known, replacing) = {
            let st = lock(&self.st);
            let Some(m) = st.libs.iter().find(|l| l.id == item.library_id) else { return Outcome::Failed("That library no longer exists.".into()) };
            let dup = m.books.iter().find(|b| b.blake3 == hash).map(|b| b.title.clone());
            let old = item.replace.as_ref().and_then(|d| m.books.iter().find(|b| &b.doc_id == d).cloned());
            (dup, old)
        };
        if let Some(of) = known {
            return Outcome::Duplicate(of);
        }
        if item.replace.is_some() && replacing.is_none() {
            return Outcome::Failed("The book to replace is no longer in this library.".into());
        }
        let mut opts = BuildOptions::new(&item.file_name, &now_rfc3339());
        opts.title = item.title.clone().or_else(|| replacing.as_ref().map(|b| b.title.clone()));
        if let Some(old) = &replacing {
            opts.doc_id = Some(old.doc_id.clone());
            opts.doc_version = old.doc_version + 1;
        }
        let adapter = Adapter { embed: self.embed.as_ref(), error: Mutex::new(None) };
        let mut seen_text: Option<(usize, usize)> = None;
        let id = item.id.clone();
        let result = build_pack_with(&bytes, &opts, &adapter, &mut |p| match p {
            Progress::Extracted { pages, pieces, ocr_pages } => {
                seen_text = Some((pieces, ocr_pages));
                self.update_item(&id, |it| {
                    it.state = S::Building;
                    it.pages = Some(pages as u32);
                    it.pieces_total = Some(pieces as u32);
                    it.ocr_pages = ocr_pages as u32;
                });
            }
            Progress::Embedded { done, .. } => self.update_item(&id, |it| it.pieces_done = done as u32),
        });
        match result {
            Ok((pack, _)) => match self.store_book(item, &bytes, &pack, &hash, replacing.as_ref()) {
                Ok(()) => Outcome::Built(Box::new(pack)),
                Err(m) => Outcome::Failed(m),
            },
            Err(e) => {
                if let Some(EmbedErr::Waiting(w)) = lock(&adapter.error).clone() {
                    return Outcome::Waiting(w);
                }
                if let Some(EmbedErr::Failed(m)) = lock(&adapter.error).clone() {
                    return Outcome::Failed(m);
                }
                match seen_text {
                    Some((0, ocr)) if ocr > 0 => Outcome::OcrNeeded(format!("No text was found and the pages could not be read as images. {ocr} page(s) need OCR, which Cache cannot do yet.")),
                    _ => Outcome::Failed(friendly_error(&e.0)),
                }
            }
        }
    }

    fn open_work(&self, lib: &str) -> Result<WorkShard, String> {
        let work = self.work_dir(lib);
        let has_books = lock(&self.st).libs.iter().find(|l| l.id == lib).is_some_and(|l| !l.books.is_empty());
        if !work.join("segments").is_dir() && has_books {
            rebuild_from_packs(&self.packs_dir(lib), &work).map_err(|e| format!("making the library's search data again: {e}"))?;
        }
        match WorkShard::open(&work) {
            Ok(w) => Ok(w),
            Err(first) => {
                rebuild_from_packs(&self.packs_dir(lib), &work).map_err(|e| format!("{first}; making it again: {e}"))?;
                WorkShard::open(&work).map_err(|e| e.to_string())
            }
        }
    }

    /// Write the pack, keep the PDF, put the pieces in the work shard and record the book.
    fn store_book(&self, item: &Item, pdf: &[u8], pack: &Pack, hash: &str, replacing: Option<&Book>) -> Result<(), String> {
        let _g = lock(&self.ops);
        let io = |what: &str, e: std::io::Error| {
            if is_disk_full(&e) {
                "Not enough space on this device.".to_string()
            } else {
                format!("{what}: {e}")
            }
        };
        let h = &pack.header;
        write_pack(pack, &self.packs_dir(&item.library_id)).map_err(|e| e.to_string())?;
        let src = self.source_path(&item.library_id, &h.doc_id);
        std::fs::create_dir_all(src.parent().unwrap_or(Path::new("."))).map_err(|e| io("keeping the PDF", e))?;
        write_bytes_atomic(&src, pdf).map_err(|e| io("keeping the PDF", e))?;
        {
            let w = self.open_work(&item.library_id)?;
            w.upsert_pack(pack).map_err(|e| e.to_string())?;
            w.flush().map_err(|e| e.to_string())?;
        }
        let book = Book {
            doc_id: h.doc_id.clone(),
            doc_version: h.doc_version,
            title: h.title.clone(),
            pages: h.page_count as u32,
            pieces: h.pieces as u32,
            ocr_pages: h.ocr_pages.len() as u32,
            blake3: hash.to_string(),
            size: pdf.len() as u64,
            file_name: item.file_name.clone(),
            added_at: now_rfc3339(),
        };
        let old_pack = replacing.map(|o| self.packs_dir(&item.library_id).join(cache_builder::pack::pack_file_name(&o.doc_id, o.doc_version)));
        {
            let mut st = lock(&self.st);
            let Some(m) = st.libs.iter_mut().find(|l| l.id == item.library_id) else { return Err("That library no longer exists.".into()) };
            if let Some(o) = replacing {
                m.books.retain(|b| b.doc_id != o.doc_id);
                m.pending_deletes.push(PendingDelete { doc_id: o.doc_id.clone(), doc_version: o.doc_version, pieces: o.pieces });
            }
            m.books.retain(|b| b.doc_id != book.doc_id);
            m.books.push(book);
            m.dirty = true;
            let m = m.clone();
            self.save_meta(&m).map_err(|e| io("saving the library", e))?;
        }
        if let Some(p) = old_pack {
            let _ = std::fs::remove_file(p);
        }
        self.apply_pending_deletes(&item.library_id);
        Ok(())
    }

    /// Delete the points listed in the library's `pending_deletes` from the work shard. Holds `ops` (the caller does).
    fn apply_pending_deletes(&self, lib: &str) {
        let pending = lock(&self.st).libs.iter().find(|l| l.id == lib).map(|l| l.pending_deletes.clone()).unwrap_or_default();
        if pending.is_empty() {
            return;
        }
        let done = (|| -> Result<(), String> {
            let w = self.open_work(lib)?;
            for p in &pending {
                w.delete_doc(&p.doc_id, p.doc_version, p.pieces as usize).map_err(|e| e.to_string())?;
            }
            w.flush().map_err(|e| e.to_string())
        })();
        match done {
            Ok(()) => {
                let mut st = lock(&self.st);
                if let Some(m) = st.libs.iter_mut().find(|l| l.id == lib) {
                    m.pending_deletes.retain(|p| !pending.iter().any(|q| q.doc_id == p.doc_id && q.doc_version == p.doc_version));
                    let m = m.clone();
                    let _ = self.save_meta(&m);
                }
            }
            Err(e) => eprintln!("cache-server: deleting old points of {lib}: {e}"),
        }
    }

    fn finish(&self, item: &Item, outcome: Outcome, started: Instant) {
        enum Next {
            Keep,
            Remove,
        }
        let mut next = Next::Keep;
        {
            let mut st = lock(&self.st);
            let secs = started.elapsed().as_secs_f64();
            let mut built = 0u64;
            if let Some(it) = st.items.iter_mut().find(|i| i.id == item.id) {
                it.finished_at = Some(now_rfc3339());
                it.finished_epoch = Some(epoch());
                match &outcome {
                    Outcome::Built(pack) => {
                        it.state = S::Done;
                        it.doc_id = Some(pack.header.doc_id.clone());
                        it.pages = Some(pack.header.page_count as u32);
                        it.pieces_total = Some(pack.header.pieces as u32);
                        it.pieces_done = pack.header.pieces as u32;
                        it.ocr_pages = pack.header.ocr_pages.len() as u32;
                        if !pack.header.ocr_pages.is_empty() {
                            it.note = Some(format!("partial: {} pages need OCR", pack.header.ocr_pages.len()));
                        }
                        built = pack.header.pieces as u64;
                    }
                    Outcome::Duplicate(of) => {
                        it.state = S::SkippedDuplicate;
                        it.duplicate_of = Some(of.clone());
                    }
                    Outcome::OcrNeeded(m) => {
                        it.state = S::OcrNeeded;
                        it.error = Some(m.clone());
                    }
                    Outcome::Failed(m) => {
                        it.state = S::Failed;
                        it.error = Some(m.clone());
                    }
                    Outcome::Waiting(_) => {
                        it.state = S::Queued;
                        it.started_at = None;
                        it.finished_at = None;
                        it.finished_epoch = None;
                        it.pages = None;
                        it.pieces_done = 0;
                        it.pieces_total = None;
                        it.ocr_pages = 0;
                    }
                    Outcome::Gone => next = Next::Remove,
                }
            }
            if let Outcome::Waiting(w) = &outcome {
                st.blocked = Some(w.clone());
            }
            if built > 0 {
                st.built_pieces += built;
                st.built_secs += secs;
            }
            if matches!(next, Next::Remove) {
                st.items.retain(|i| i.id != item.id);
            }
            self.prune(&mut st);
            self.save_queue_locked(&st);
        }
        // The upload has been kept as a source copy (or is not wanted): its staging file goes. A failed one stays for a retry.
        if item.origin == Origin::Upload && matches!(outcome, Outcome::Built(_) | Outcome::Duplicate(_)) {
            let _ = std::fs::remove_file(&item.path);
        }
        if item.origin == Origin::Drop && !matches!(outcome, Outcome::Waiting(_) | Outcome::Gone) {
            self.settle_drop_item(&item.id);
        }
    }

    // ---- publishing

    /// Publish every library whose changes are due.
    fn publish_due(&self) {
        let due: Vec<String> = {
            let st = lock(&self.st);
            let now = Instant::now();
            st.libs
                .iter()
                .filter(|l| l.dirty || !l.pending_deletes.is_empty())
                .filter(|l| st.retry_after.get(&l.id).is_none_or(|t| now >= *t))
                .filter(|l| {
                    let busy = !st.paused && st.items.iter().any(|i| i.library_id == l.id && i.state.live());
                    !busy || st.last_publish.get(&l.id).is_none_or(|t| t.elapsed() >= self.cfg.publish_every)
                })
                .map(|l| l.id.clone())
                .collect()
        };
        for id in due {
            if let Err(e) = self.publish(&id) {
                eprintln!("cache-server: publishing library {id}: {e}");
                let mut st = lock(&self.st);
                st.retry_after.insert(id.clone(), Instant::now() + self.cfg.publish_every);
                if let Some(m) = st.libs.iter_mut().find(|l| l.id == id) {
                    m.publish_error = Some(e);
                    let m = m.clone();
                    let _ = self.save_meta(&m);
                }
            }
        }
    }

    /// Make the core's copy of a library match the work shard. See the module notes for the swap.
    pub fn publish(&self, id: &str) -> Result<(), String> {
        let _g = lock(&self.ops);
        let Some(meta) = lock(&self.st).libs.iter().find(|l| l.id == id).cloned() else { return Err("no such library".into()) };
        self.apply_pending_deletes(id);
        let live = self.live_dir(id);
        std::fs::create_dir_all(&live).map_err(|e| format!("making {}: {e}", live.display()))?;
        let (shard, index) = (live.join("shard"), live.join("index"));
        let (new, newtmp, old, oldindex) = (live.join(".shard.new"), live.join(".shard.new.tmp"), live.join(".shard.old"), live.join(".index.old"));
        let settings_path = live.join(cache_builder::library::SETTINGS_FILE);
        let seq = meta.publish_seq + 1;
        let io = |what: &str, e: std::io::Error| format!("{what}: {e}");
        if meta.books.is_empty() {
            // Nothing to search: the library leaves the core until a book is added.
            if shard.exists() {
                std::fs::rename(&shard, &old).map_err(|e| io("taking the shard away", e))?;
                if index.exists() {
                    let _ = std::fs::rename(&index, &oldindex);
                }
                let _ = std::fs::remove_file(&settings_path);
                self.rescan();
                let _ = std::fs::remove_dir_all(&old);
                let _ = std::fs::remove_dir_all(&oldindex);
            }
        } else {
            for d in [&new, &newtmp, &old, &oldindex] {
                let _ = std::fs::remove_dir_all(d);
            }
            // Close the work shard (it is not held open between operations) and copy it.
            publish_copy(&self.work_dir(id), &newtmp).map_err(|e| e.to_string())?;
            std::fs::rename(&newtmp, &new).map_err(|e| io("finishing the copy", e))?;
            let had_old = shard.exists();
            if had_old {
                std::fs::rename(&shard, &old).map_err(|e| io("moving the old shard away", e))?;
                if index.exists() {
                    let _ = std::fs::rename(&index, &oldindex);
                }
                self.rescan();
            }
            let settings = cache_builder::incremental::library_settings_json(id, &meta.title, &seq.to_string());
            write_bytes_atomic(&settings_path, settings.as_bytes()).map_err(|e| io("writing cache-library.json", e))?;
            if let Err(e) = std::fs::rename(&new, &shard) {
                // Put the old one back so the library is never left without a shard.
                if had_old {
                    let _ = std::fs::rename(&old, &shard);
                    if oldindex.exists() {
                        let _ = std::fs::rename(&oldindex, &index);
                    }
                    self.rescan();
                }
                return Err(io("putting the new shard in place", e));
            }
            self.rescan();
            let _ = std::fs::remove_dir_all(&old);
            let _ = std::fs::remove_dir_all(&oldindex);
        }
        let mut st = lock(&self.st);
        st.last_publish.insert(id.to_string(), Instant::now());
        st.retry_after.remove(id);
        if let Some(m) = st.libs.iter_mut().find(|l| l.id == id) {
            m.dirty = false;
            m.published_at = Some(now_rfc3339());
            m.publish_seq = seq;
            m.publish_error = None;
            let m = m.clone();
            self.save_meta(&m).map_err(|e| io("saving the library", e))?;
        }
        Ok(())
    }

    // ---- views

    fn lib_view(&self, st: &State, m: &LibMeta) -> Value {
        let live = st.items.iter().filter(|i| i.library_id == m.id && i.state.live()).count();
        let building = st.items.iter().any(|i| i.library_id == m.id && i.state.working());
        json!({
            "id": m.id, "title": m.title, "books": m.books.len(), "passages": m.books.iter().map(|b| b.pieces as u64).sum::<u64>(),
            "pages": m.books.iter().map(|b| b.pages as u64).sum::<u64>(), "created_at": m.created_at,
            "published": self.live_dir(&m.id).join("shard").is_dir(), "dirty": m.dirty, "waiting": live, "building": building,
            "publish_error": m.publish_error,
        })
    }

    /// `GET /api/build/libraries`.
    pub fn libraries(&self) -> Value {
        let st = lock(&self.st);
        Value::Array(st.libs.iter().map(|m| self.lib_view(&st, m)).collect())
    }

    fn item_view(it: &Item, position: Option<usize>) -> Value {
        json!({
            "id": it.id, "library_id": it.library_id, "file_name": it.file_name, "title": it.title, "state": it.state, "size": it.size,
            "progress": {"pages": it.pages, "pieces": it.pieces_done, "pieces_total": it.pieces_total, "ocr_pages": it.ocr_pages},
            "error": it.error, "note": it.note, "replace": it.replace, "doc_id": it.doc_id, "duplicate_of": it.duplicate_of,
            "drop": it.origin == Origin::Drop, "position": position, "created_at": it.created_at, "started_at": it.started_at,
            "finished_at": it.finished_at,
        })
    }

    /// The time left as a range, in seconds: from the pieces per second seen so far, and the size of the books still waiting.
    fn eta(&self, st: &State) -> Option<(u64, u64)> {
        if st.paused || st.built_secs < 1.0 || st.built_pieces == 0 {
            return None;
        }
        let rate = st.built_pieces as f64 / st.built_secs;
        let (mut pieces_sum, mut bytes_sum) = (0u64, 0u64);
        for m in &st.libs {
            for b in &m.books {
                pieces_sum += b.pieces as u64;
                bytes_sum += b.size;
            }
        }
        let per_byte = if bytes_sum > 0 { pieces_sum as f64 / bytes_sum as f64 } else { 0.0 };
        let mut remaining = 0f64;
        let mut any = false;
        for it in st.items.iter().filter(|i| i.state.live()) {
            any = true;
            match (it.state, it.pieces_total) {
                (S::Building, Some(t)) => remaining += t.saturating_sub(it.pieces_done) as f64,
                _ => remaining += it.size as f64 * per_byte,
            }
        }
        if !any || remaining <= 0.0 {
            return None;
        }
        let mid = remaining / rate;
        Some(((mid * 0.7) as u64, (mid * 1.4).ceil() as u64))
    }

    /// `GET /api/build/queue`.
    pub fn queue(&self) -> Value {
        let st = lock(&self.st);
        let mut pos = 0usize;
        let items: Vec<Value> = st
            .items
            .iter()
            .map(|it| {
                let p = if it.state == S::Queued {
                    pos += 1;
                    Some(pos)
                } else {
                    None
                };
                BuildService::item_view(it, p)
            })
            .collect();
        let n = |f: &dyn Fn(&Item) -> bool| st.items.iter().filter(|i| f(i)).count();
        let (low, high) = self.eta(&st).map_or((None, None), |(a, b)| (Some(a), Some(b)));
        let rate = if st.built_secs >= 1.0 && st.built_pieces > 0 { Some(st.built_pieces as f64 / st.built_secs) } else { None };
        json!({
            "paused": st.paused,
            "blocked": if st.items.iter().any(|i| i.state == S::Queued) { st.blocked.clone() } else { None },
            "counts": {
                "total": st.items.len(), "waiting": n(&|i| i.state == S::Queued), "working": n(&|i| i.state.working()),
                "done": n(&|i| i.state == S::Done), "skipped": n(&|i| i.state == S::SkippedDuplicate),
                "failed": n(&|i| i.state == S::Failed), "ocr_needed": n(&|i| i.state == S::OcrNeeded),
            },
            "eta": {"low_seconds": low, "high_seconds": high},
            "pieces_per_second": rate,
            "items": items,
        })
    }

    // ---- queue controls

    pub fn pause(&self) -> Value {
        lock(&self.st).paused = true;
        self.save_queue();
        self.queue()
    }

    pub fn resume(&self) -> Value {
        lock(&self.st).paused = false;
        self.save_queue();
        self.poke();
        self.queue()
    }

    /// Drop the books still waiting. The one being built finishes.
    pub fn stop(&self) -> Value {
        let removed = {
            let mut st = lock(&self.st);
            let mut gone = vec![];
            st.items.retain(|i| {
                if i.state == S::Queued {
                    gone.push(i.clone());
                    false
                } else {
                    true
                }
            });
            self.save_queue_locked(&st);
            gone
        };
        for it in &removed {
            if it.origin == Origin::Upload {
                let _ = std::fs::remove_file(&it.path);
            }
        }
        let mut v = self.queue();
        v["removed"] = json!(removed.len());
        v
    }

    /// `POST /api/build/queue/{id}/retry`: a failed (or OCR-needed) book goes to the end of the queue. A drop-folder file goes back
    /// to `ingest/`.
    pub fn retry(&self, id: &str) -> Result<Value, ApiErr> {
        let it = {
            let st = lock(&self.st);
            st.items.iter().find(|i| i.id == id).cloned().ok_or_else(|| err(404, "not_found", "no such book in the queue"))?
        };
        if !matches!(it.state, S::Failed | S::OcrNeeded) {
            return Err(err(409, "not_failed", "Only a book that did not build can be tried again."));
        }
        if it.origin == Origin::Drop {
            self.retry_drop_item(&it).map_err(|m| err(409, "cannot_retry", m))?;
            lock(&self.st).items.retain(|i| i.id != id);
        } else {
            let mut st = lock(&self.st);
            if let Some(idx) = st.items.iter().position(|i| i.id == id) {
                let mut x = st.items.remove(idx);
                x.state = S::Queued;
                x.error = None;
                x.note = None;
                x.pages = None;
                x.pieces_done = 0;
                x.pieces_total = None;
                x.ocr_pages = 0;
                x.started_at = None;
                x.finished_at = None;
                x.finished_epoch = None;
                st.items.push(x);
            }
        }
        self.save_queue();
        self.poke();
        Ok(self.queue())
    }

    /// `DELETE /api/build/queue/{id}`: take a book off the list (Dismiss, or cancel a waiting one). One being built cannot be.
    pub fn dismiss(&self, id: &str) -> Result<Value, ApiErr> {
        let it = {
            let mut st = lock(&self.st);
            let idx = st.items.iter().position(|i| i.id == id).ok_or_else(|| err(404, "not_found", "no such book in the queue"))?;
            if st.items[idx].state.working() {
                return Err(err(409, "busy", "That book is being built right now."));
            }
            let it = st.items.remove(idx);
            self.save_queue_locked(&st);
            it
        };
        if it.origin == Origin::Upload {
            let _ = std::fs::remove_file(&it.path);
        }
        Ok(self.queue())
    }

    // ---- libraries

    fn clean_title(raw: &str) -> Result<String, ApiErr> {
        let t = raw.trim();
        if t.is_empty() {
            return Err(err(400, "invalid", "A name is needed."));
        }
        if t.chars().count() > 120 || t.chars().any(|c| c.is_control()) {
            return Err(err(400, "invalid", "That name is too long or has characters that are not allowed."));
        }
        Ok(t.to_string())
    }

    fn body_title(body: &[u8]) -> Result<String, ApiErr> {
        let v: Value = serde_json::from_slice(body).map_err(|_| err(400, "bad_json", "the body is not JSON"))?;
        BuildService::clean_title(v["title"].as_str().ok_or_else(|| err(400, "invalid", "\"title\" is required"))?)
    }

    /// `POST /api/build/libraries {title}`.
    pub fn create_library(&self, body: &[u8]) -> Result<Value, ApiErr> {
        let title = BuildService::body_title(body)?;
        let mut st = lock(&self.st);
        if st.libs.iter().any(|l| l.title.to_lowercase() == title.to_lowercase()) {
            return Err(err(409, "name_taken", format!("You already have a library called \"{title}\". Choose another name, or add to it.")));
        }
        let mut id = make_library_id(&title);
        while st.libs.iter().any(|l| l.id == id) || self.live_dir(&id).exists() {
            id = make_library_id(&title);
        }
        let m = LibMeta { id, title, created_at: now_rfc3339(), books: vec![], pending_deletes: vec![], dirty: false, published_at: None, publish_seq: 0, publish_error: None };
        self.save_meta(&m).map_err(|e| err(500, "server_error", format!("could not save the library: {e}")))?;
        let _ = std::fs::create_dir_all(self.packs_dir(&m.id));
        let v = self.lib_view(&st, &m);
        st.last_publish.insert(m.id.clone(), Instant::now());
        st.libs.push(m);
        Ok(v)
    }

    /// `PATCH /api/build/libraries/{id} {title}`.
    pub fn rename_library(&self, id: &str, body: &[u8]) -> Result<Value, ApiErr> {
        let title = BuildService::body_title(body)?;
        let _g = lock(&self.ops);
        let view = {
            let mut st = lock(&self.st);
            if st.libs.iter().any(|l| l.id != id && l.title.to_lowercase() == title.to_lowercase()) {
                return Err(err(409, "name_taken", format!("You already have a library called \"{title}\". Choose another name, or add to it.")));
            }
            let m = st.libs.iter_mut().find(|l| l.id == id).ok_or_else(|| err(404, "not_found", "no such library"))?;
            m.title = title.clone();
            let m = m.clone();
            self.save_meta(&m).map_err(|e| err(500, "server_error", format!("could not save the library: {e}")))?;
            self.lib_view(&st, &m)
        };
        // The published settings name the library too: rewrite them (a title only) and have the core read them again.
        let settings_path = self.live_dir(id).join(cache_builder::library::SETTINGS_FILE);
        if settings_path.is_file() && self.live_dir(id).join("shard").is_dir() {
            let seq = lock(&self.st).libs.iter().find(|l| l.id == id).map_or(1, |l| l.publish_seq);
            let settings = cache_builder::incremental::library_settings_json(id, &title, &seq.to_string());
            write_bytes_atomic(&settings_path, settings.as_bytes()).map_err(|e| err(500, "server_error", format!("could not write the library settings: {e}")))?;
            self.rescan();
        }
        Ok(view)
    }

    /// `DELETE /api/build/libraries/{id}`: the books, the packs, the PDF copies and the search data.
    pub fn delete_library(&self, id: &str) -> Result<Value, ApiErr> {
        let _g = lock(&self.ops);
        let removed = {
            let mut st = lock(&self.st);
            if !st.libs.iter().any(|l| l.id == id) {
                return Err(err(404, "not_found", "no such library"));
            }
            if st.items.iter().any(|i| i.library_id == id && i.state.working()) {
                return Err(err(409, "busy", "A book of this library is being built right now. Stop building first."));
            }
            let mut gone = vec![];
            st.items.retain(|i| {
                if i.library_id == id {
                    gone.push(i.clone());
                    false
                } else {
                    true
                }
            });
            st.libs.retain(|l| l.id != id);
            st.last_publish.remove(id);
            self.save_queue_locked(&st);
            gone
        };
        for it in removed.iter().filter(|i| i.origin == Origin::Upload) {
            let _ = std::fs::remove_file(&it.path);
        }
        let _ = std::fs::remove_file(self.meta_path(id));
        self.forget_drop_library(id);
        // Out of the core's sight first (a rename), then deleted.
        let live = self.live_dir(id);
        let gone = self.libs_dir().join(format!(".{id}.deleted"));
        if std::fs::rename(&live, &gone).is_ok() {
            self.rescan();
            let _ = std::fs::remove_dir_all(&gone);
        }
        let _ = std::fs::remove_dir_all(self.data.join("build/work").join(id));
        let _ = std::fs::remove_dir_all(self.source_path(id, "x").parent().unwrap_or(Path::new("/nonexistent-cache-path")));
        Ok(json!({"removed": true, "id": id}))
    }

    /// `GET /api/build/libraries/{id}/books`.
    pub fn books(&self, id: &str) -> Result<Value, ApiErr> {
        let st = lock(&self.st);
        let m = st.libs.iter().find(|l| l.id == id).ok_or_else(|| err(404, "not_found", "no such library"))?;
        let mut books: Vec<&Book> = m.books.iter().collect();
        books.sort_by(|a, b| a.title.to_lowercase().cmp(&b.title.to_lowercase()).then(a.doc_id.cmp(&b.doc_id)));
        Ok(Value::Array(
            books
                .into_iter()
                .map(|b| {
                    let replacing = st.items.iter().any(|i| i.library_id == id && i.state.live() && i.replace.as_deref() == Some(&b.doc_id));
                    json!({
                        "id": b.doc_id, "doc_version": b.doc_version, "title": b.title, "pages": b.pages, "passages": b.pieces,
                        "ocr_pages": b.ocr_pages, "partial": if b.ocr_pages > 0 { Some(format!("partial: {} pages need OCR", b.ocr_pages)) } else { None },
                        "file_name": b.file_name, "size": b.size, "added_at": b.added_at, "status": if replacing { "replacing" } else { "ready" },
                    })
                })
                .collect(),
        ))
    }

    /// `PATCH /api/build/libraries/{id}/books/{doc}` {title}: only the title changes. The vectors are not made again; the book's pack
    /// and its points are rewritten with the new title.
    pub fn rename_book(&self, id: &str, doc: &str, body: &[u8]) -> Result<Value, ApiErr> {
        let title = BuildService::body_title(body)?;
        let _g = lock(&self.ops);
        let book = lock(&self.st)
            .libs
            .iter()
            .find(|l| l.id == id)
            .ok_or_else(|| err(404, "not_found", "no such library"))?
            .books
            .iter()
            .find(|b| b.doc_id == doc)
            .cloned()
            .ok_or_else(|| err(404, "not_found", "no such book"))?;
        let pack_path = self.packs_dir(id).join(cache_builder::pack::pack_file_name(&book.doc_id, book.doc_version));
        let mut pack = read_pack(&pack_path).map_err(|e| err(500, "server_error", e.to_string()))?;
        pack.header.title = title.clone();
        write_pack(&pack, &self.packs_dir(id)).map_err(|e| err(500, "server_error", e.to_string()))?;
        {
            let w = self.open_work(id).map_err(|e| err(500, "server_error", e))?;
            w.upsert_pack(&pack).map_err(|e| err(500, "server_error", e.to_string()))?;
            w.flush().map_err(|e| err(500, "server_error", e.to_string()))?;
        }
        {
            let mut st = lock(&self.st);
            if let Some(m) = st.libs.iter_mut().find(|l| l.id == id) {
                if let Some(b) = m.books.iter_mut().find(|b| b.doc_id == doc) {
                    b.title = title.clone();
                }
                m.dirty = true;
                let m = m.clone();
                self.save_meta(&m).map_err(|e| err(500, "server_error", format!("could not save the library: {e}")))?;
            }
        }
        self.poke();
        Ok(json!({"id": doc, "title": title}))
    }

    /// `DELETE /api/build/libraries/{id}/books/{doc}`: the book's points, pack and PDF copy. The PDF the person gave is untouched.
    pub fn delete_book(&self, id: &str, doc: &str) -> Result<Value, ApiErr> {
        let _g = lock(&self.ops);
        {
            let mut st = lock(&self.st);
            if st.items.iter().any(|i| i.library_id == id && i.state.working() && i.replace.as_deref() == Some(doc)) {
                return Err(err(409, "busy", "This book is being replaced right now."));
            }
            let m = st.libs.iter_mut().find(|l| l.id == id).ok_or_else(|| err(404, "not_found", "no such library"))?;
            let b = m.books.iter().find(|b| b.doc_id == doc).cloned().ok_or_else(|| err(404, "not_found", "no such book"))?;
            m.books.retain(|x| x.doc_id != doc);
            m.pending_deletes.push(PendingDelete { doc_id: b.doc_id.clone(), doc_version: b.doc_version, pieces: b.pieces });
            m.dirty = true;
            let m = m.clone();
            self.save_meta(&m).map_err(|e| err(500, "server_error", format!("could not save the library: {e}")))?;
            let _ = std::fs::remove_file(self.packs_dir(id).join(cache_builder::pack::pack_file_name(&b.doc_id, b.doc_version)));
            let _ = std::fs::remove_file(self.source_path(id, &b.doc_id));
            // a replacement waiting for this book has nothing to replace any more
            for it in st.items.iter_mut().filter(|i| i.library_id == id && i.state == S::Queued && i.replace.as_deref() == Some(doc)) {
                it.replace = None;
            }
            self.save_queue_locked(&st);
        }
        self.apply_pending_deletes(id);
        self.poke();
        Ok(json!({"removed": true, "id": doc}))
    }

    // ---- uploads

    /// `POST /api/build/upload?library_id=&name=` and `POST /api/build/libraries/{id}/books/{doc}/replace?name=`: stream the PDF to
    /// `build/pending/` and queue it. `content_length` is the request's Content-Length; the body is never held in memory.
    pub async fn upload<B>(self: &Arc<Self>, library_id: &str, replace: Option<&str>, query: &str, content_length: Option<u64>, mut body: B) -> Result<Value, ApiErr>
    where
        B: Body<Data = Bytes> + Unpin,
        B::Error: std::fmt::Display,
    {
        use tokio::io::AsyncWriteExt;
        let library_id = if library_id.is_empty() { crate::fetch::query_param(query, "library_id").unwrap_or_default() } else { library_id.to_string() };
        {
            let st = lock(&self.st);
            let m = st.libs.iter().find(|l| l.id == library_id).ok_or_else(|| err(404, "not_found", "no such library"))?;
            if let Some(d) = replace {
                if !m.books.iter().any(|b| b.doc_id == d) {
                    return Err(err(404, "not_found", "no such book"));
                }
            }
        }
        let name = crate::fetch::query_param(query, "name").ok_or_else(|| err(400, "invalid_name", "A file name is needed."))?;
        let name = sanitize_name(&name, "pdf").map_err(|m| err(400, "invalid_name", m))?;
        let len = content_length.ok_or_else(|| err(411, "length_required", "The upload needs a Content-Length."))?;
        let dir = self.pending_dir();
        std::fs::create_dir_all(&dir).map_err(|e| err(500, "server_error", format!("could not make the upload folder: {e}")))?;
        if let Some(avail) = free_bytes(&dir) {
            if avail < len.saturating_add(UPLOAD_HEADROOM) {
                return Err(err(507, "no_space", format!("Not enough space on this device: {} MB needed, {} MB free.", len >> 20, avail >> 20)));
            }
        }
        let id = random_hex();
        let path = dir.join(format!("{id}.pdf"));
        let part = dir.join(format!(".{id}.part"));
        struct Guard(Option<PathBuf>);
        impl Drop for Guard {
            fn drop(&mut self) {
                if let Some(p) = self.0.take() {
                    let _ = std::fs::remove_file(p);
                }
            }
        }
        let mut guard = Guard(Some(part.clone()));
        let write_err = |e: std::io::Error| {
            if is_disk_full(&e) {
                err(507, "no_space", "This device ran out of space during the upload.")
            } else {
                err(500, "server_error", format!("could not write the upload: {e}"))
            }
        };
        let mut f = tokio::fs::File::create(&part).await.map_err(write_err)?;
        let mut got: u64 = 0;
        let mut head: Vec<u8> = Vec::new();
        while let Some(frame) = body.frame().await {
            let frame = frame.map_err(|e| err(400, "upload_interrupted", format!("the upload was cut off: {e}")))?;
            if let Ok(data) = frame.into_data() {
                got += data.len() as u64;
                if got > len {
                    return Err(err(400, "invalid", "the body is longer than its Content-Length"));
                }
                if head.len() < 1024 {
                    head.extend_from_slice(&data[..data.len().min(1024 - head.len())]);
                }
                f.write_all(&data).await.map_err(write_err)?;
            }
        }
        if got != len {
            return Err(err(400, "upload_interrupted", "the upload ended before its Content-Length"));
        }
        if !head.windows(5).any(|w| w == b"%PDF-") {
            return Err(err(400, "not_pdf", "That file is not a PDF."));
        }
        f.flush().await.map_err(write_err)?;
        f.sync_all().await.map_err(write_err)?;
        drop(f);
        tokio::fs::rename(&part, &path).await.map_err(write_err)?;
        guard.0 = Some(path.clone());
        let mut item = Item::new(id.clone(), library_id.clone(), path.to_string_lossy().into_owned(), name, got, Origin::Upload);
        item.replace = replace.map(str::to_string);
        let view = self.enqueue(item)?;
        guard.0 = None;
        Ok(view)
    }

    /// Put a book at the end of the queue.
    pub(crate) fn enqueue(&self, item: Item) -> Result<Value, ApiErr> {
        let mut st = lock(&self.st);
        if !st.libs.iter().any(|l| l.id == item.library_id) {
            return Err(err(404, "not_found", "no such library"));
        }
        let pos = st.items.iter().filter(|i| i.state == S::Queued).count() + 1;
        let v = BuildService::item_view(&item, Some(pos));
        st.items.push(item);
        self.save_queue_locked(&st);
        drop(st);
        self.poke();
        Ok(v)
    }

    pub(crate) fn has_library(&self, id: &str) -> bool {
        lock(&self.st).libs.iter().any(|l| l.id == id)
    }

    pub(crate) fn lib_title(&self, id: &str) -> Option<String> {
        lock(&self.st).libs.iter().find(|l| l.id == id).map(|l| l.title.clone())
    }
}

enum Outcome {
    Built(Box<Pack>),
    Duplicate(String),
    OcrNeeded(String),
    Failed(String),
    /// The search model went away: back to the queue.
    Waiting(String),
    /// A drop-folder file that was taken out of `ingest/` by hand.
    Gone,
}
