//! The ZIM keyword index (kind `zim`) and the library device keyword index (kind `library`) as syncable snapshots, and the
//! migration of the old index folders into them. The generic rules (manifest, verification, the pick, publishing) are in
//! `snapshot.rs`; this file is what these two kinds add.
//!
//! ```text
//! <indexes_dir>/zim/<zim uuid>/                 source id: the ZIM's lowercase UUID
//! <indexes_dir>/library/<library_id@version>/   source id: as cs_status reports it ("@version" only when the settings have one)
//!     .build/                                   the working index (resumable, never synced); also publish-<id>/ while sealing
//!     snap/<build-id>/                          published: Tantivy files and manifest.json (written last); never written again
//! ```
//!
//! Three things happen here:
//! - **Building**: `index_zim` / `index_library` with an `indexes_dir` build in `.build/` exactly as before and publish
//!   (`run_zim`, `run_library`).
//! - **Searching**: [`SnapSlot`] verifies and opens the picked snapshot on a background thread. Until it is ready the old index
//!   (`index_dir`) is used as before.
//! - **Sealing** (`index_seal` job, [`seal`]): an index in the old location becomes a snapshot by HARD-LINKING its files, so
//!   nothing is copied and nothing is merged; the old names are removed only after the first successful open from the snapshot
//!   ([`finish_seal`]).

use crate::error::{Error, ErrorCode, Result};
use crate::index::{
    self, read_meta, stemmer_for_language, BuildParams, IndexMeta, IndexState, Lock, Outcome, ANALYZER, INDEX_FORMAT,
    LIB_INDEX_FORMAT, LOCK_FILE, META_FILE,
};
use crate::snapshot::{self, Compat, FileEntry, Manifest, PickRule, Tokenizer, MANIFEST, META_LOCK, SNAP_DIR};
use crate::zimsrc::ZimSource;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

pub const KIND_ZIM: &str = "zim";
pub const KIND_LIBRARY: &str = "library";
/// The Tantivy version the files are written by (the manifest's `tantivy`).
pub const TANTIVY: &str = "0.27";
/// Files of an index folder that are not part of a snapshot (bookkeeping and locks).
const NOT_IN_SNAPSHOT: [&str; 5] =
    [LOCK_FILE, META_FILE, "cache_search_index.json.tmp", ".tantivy-writer.lock", META_LOCK];
/// What `seal` writes in `.build/` so the old names can be removed after the first open from the snapshot.
const SEAL_MARK: &str = "sealed.json";
/// How soon a source whose snapshot did not verify (maybe still arriving) is looked at again.
const RETRY: Duration = Duration::from_secs(15);

fn kind_format(kind: &str) -> u32 {
    if kind == KIND_LIBRARY {
        LIB_INDEX_FORMAT
    } else {
        INDEX_FORMAT
    }
}

fn tokenizer_known(name: &str) -> bool {
    name.strip_suffix("_stem").is_some_and(|code| stemmer_for_language(Some(code)).is_some())
}

fn compat_with(m: &Manifest, format: u32, en_only: bool) -> std::result::Result<(), String> {
    if m.format != format || m.tantivy != TANTIVY {
        return Err(format!("format {} tantivy {} is not read by this core", m.format, m.tantivy));
    }
    match &m.tokenizer {
        Some(t) if t.analyzer == ANALYZER && tokenizer_known(&t.name) && (!en_only || t.name == "en_stem") => Ok(()),
        other => Err(format!("tokenizer {:?} is not known", other.as_ref().map(|t| &t.name))),
    }
}

/// The compatibility check of kind `zim`.
pub fn compat_zim(m: &Manifest) -> std::result::Result<(), String> {
    compat_with(m, INDEX_FORMAT, false)
}

/// The compatibility check of kind `library`.
pub fn compat_library(m: &Manifest) -> std::result::Result<(), String> {
    compat_with(m, LIB_INDEX_FORMAT, true)
}

pub fn compat_of(kind: &str) -> Compat {
    if kind == KIND_LIBRARY {
        compat_library
    } else {
        compat_zim
    }
}

/// `<indexes_dir>/<kind>/<encoded source id>`.
pub fn dir_for(indexes_dir: &Path, kind: &str, source_id: &str) -> PathBuf {
    snapshot::source_dir(indexes_dir, kind, source_id)
}

/// A library's source id as `cs_status` reports it: `library_id`, with `@version` when its settings give one.
pub fn library_source_id(library_id: &str, version: Option<&str>) -> String {
    match version {
        Some(v) => format!("{library_id}@{v}"),
        None => library_id.to_string(),
    }
}

// ---------------------------------------------------------------------------------------------------------
// Which index folders are open (a rename-seal is only allowed for one that is not)

static OPEN: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

fn canon(p: &Path) -> PathBuf {
    std::fs::canonicalize(p).unwrap_or_else(|_| p.to_path_buf())
}

/// Held by an opened index (searching) for as long as it is open.
pub struct OpenGuard(PathBuf);

impl OpenGuard {
    pub fn new(dir: &Path) -> OpenGuard {
        let c = canon(dir);
        if let Ok(mut g) = OPEN.lock() {
            g.push(c.clone());
        }
        OpenGuard(c)
    }
}

impl Drop for OpenGuard {
    fn drop(&mut self) {
        if let Ok(mut g) = OPEN.lock() {
            if let Some(i) = g.iter().position(|p| *p == self.0) {
                g.remove(i);
            }
        }
    }
}

/// True when some handle in this process has an index in `dir` open.
pub fn is_open(dir: &Path) -> bool {
    let c = canon(dir);
    OPEN.lock().map(|g| g.contains(&c)).unwrap_or(false)
}

/// Old index folders under which hard links are refused (a test's stand-in for a volume that cannot link, such as Android's
/// shared storage): the seal then renames.
static NO_LINK_UNDER: Mutex<Vec<PathBuf>> = Mutex::new(Vec::new());

pub fn force_no_link_under(dir: &Path) {
    if let Ok(mut g) = NO_LINK_UNDER.lock() {
        g.push(canon(dir));
    }
}

fn link(from: &Path, to: &Path) -> std::io::Result<()> {
    let refused = NO_LINK_UNDER.lock().map(|g| g.iter().any(|d| canon(from).starts_with(d))).unwrap_or(false);
    if refused {
        return Err(std::io::Error::new(std::io::ErrorKind::PermissionDenied, "hard links are refused here"));
    }
    std::fs::hard_link(from, to)
}

// ---------------------------------------------------------------------------------------------------------
// Where the old index of a source is (so `index_seal` needs only the source id)

/// Keyed by the `indexes_dir` too: several handles in one process (tests, or an app with two profiles) can hold the same source
/// id with old indexes in different folders, and a seal must never be given another handle's folder.
type LegacyKey = (PathBuf, String, String);
static LEGACY: Mutex<Option<HashMap<LegacyKey, PathBuf>>> = Mutex::new(None);

fn legacy_key(indexes_dir: &Path, kind: &str, source_id: &str) -> LegacyKey {
    (canon(indexes_dir), kind.to_string(), source_id.to_string())
}

/// Remember that the handle's source `(kind, source_id)`, whose snapshots live under `indexes_dir`, keeps its old index in `dir`.
pub fn note_legacy(indexes_dir: &Path, kind: &str, source_id: &str, dir: &Path) {
    if let Ok(mut g) = LEGACY.lock() {
        g.get_or_insert_with(HashMap::new).insert(legacy_key(indexes_dir, kind, source_id), dir.to_path_buf());
    }
}

pub fn legacy_for(indexes_dir: &Path, source_id: &str) -> Option<PathBuf> {
    legacy_of(indexes_dir, KIND_LIBRARY, source_id)
}

fn legacy_of(indexes_dir: &Path, kind: &str, source_id: &str) -> Option<PathBuf> {
    LEGACY.lock().ok()?.as_ref()?.get(&legacy_key(indexes_dir, kind, source_id)).cloned()
}

// ---------------------------------------------------------------------------------------------------------
// Where hard links cannot be made

/// Written inside a library's old `index/` folder when links cannot be made there (Android's shared storage): the index is not
/// sealed into a snapshot, because a snapshot grows by hard-linking its files into the next generation. The marker is inside the
/// folder the library share leaves out, so it never syncs.
pub const NO_SEAL_MARK: &str = ".no-seal";

/// True when a hard link can be made inside `dir` (a probe: one empty file linked to another name, both removed).
pub fn links_work(dir: &Path) -> bool {
    let (a, b) = (dir.join(".link-probe-a"), dir.join(".link-probe-b"));
    let _ = std::fs::remove_file(&a);
    let _ = std::fs::remove_file(&b);
    let ok = std::fs::write(&a, b"").is_ok() && link(&a, &b).is_ok();
    let _ = std::fs::remove_file(&a);
    let _ = std::fs::remove_file(&b);
    ok
}

/// This index folder was found unsealable here ([`NO_SEAL_MARK`]): its status never offers a seal and no job is queued for it.
pub fn seal_blocked(legacy: &Path) -> bool {
    legacy.join(NO_SEAL_MARK).is_file()
}

// ---------------------------------------------------------------------------------------------------------
// Where a library's snapshots live

/// The folder beside a library's old index folder where its snapshots go when the app's indexes folder is on another volume
/// (`<library>/index` gives `<library>/index-snapshots`): a hard link or a rename cannot cross volumes, and a copy of an index
/// is not made. It holds the same layout as the indexes folder (`library/<id>/snap/...`) and never syncs.
pub fn local_root(legacy: &Path) -> PathBuf {
    let name = legacy.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "index".into());
    legacy.with_file_name(format!("{name}-snapshots"))
}

/// True when both paths are on one volume (a link or a rename between them can work). The nearest existing parent stands for a
/// path that is not made yet. Where this cannot be told the answer is yes, as it always was.
pub fn same_volume(a: &Path, b: &Path) -> bool {
    fn id(p: &Path) -> Option<String> {
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt;
            let mut q = Some(p);
            while let Some(d) = q {
                if let Ok(m) = std::fs::metadata(d) {
                    return Some(m.dev().to_string());
                }
                q = d.parent();
            }
            None
        }
        #[cfg(windows)]
        {
            // the drive (or share) the path starts with
            match p.components().next() {
                Some(std::path::Component::Prefix(x)) => Some(x.as_os_str().to_string_lossy().to_ascii_lowercase()),
                _ => None,
            }
        }
        #[cfg(not(any(unix, windows)))]
        {
            let _ = p;
            None
        }
    }
    match (id(a), id(b)) {
        (Some(x), Some(y)) => x == y,
        _ => true,
    }
}

/// The root a source's snapshots are under. Always `indexes_dir`, except for a library whose old index folder is on another
/// volume than `indexes_dir` and which has nothing in `indexes_dir` yet (no snapshot, no build): then [`local_root`] of that
/// folder, so sealing is a rename or a link on one volume. A library that already has snapshots in `indexes_dir` (an earlier
/// build put them there) keeps them where they are: nothing is moved or copied.
pub fn snap_root(indexes_dir: &Path, kind: &str, source_id: &str, legacy: Option<&Path>) -> PathBuf {
    snap_root_with(indexes_dir, kind, source_id, legacy, &same_volume)
}

pub fn snap_root_with(
    indexes_dir: &Path,
    kind: &str,
    source_id: &str,
    legacy: Option<&Path>,
    same: &dyn Fn(&Path, &Path) -> bool,
) -> PathBuf {
    let Some(legacy) = legacy.filter(|_| kind == KIND_LIBRARY) else { return indexes_dir.to_path_buf() };
    let sd = dir_for(indexes_dir, kind, source_id);
    if !snapshot::list(&sd).is_empty() || snapshot::build_dir(&sd).exists() || same(indexes_dir, legacy) {
        return indexes_dir.to_path_buf();
    }
    local_root(legacy)
}

/// A library that grows: one Add PDF writes to has a `copies.jsonl` (in the library folder, or in its shard folder). Its keyword
/// snapshot is extended by generations and picked by the highest ([`PickRule::HighestGeneration`]); every other library, and
/// every ZIM, is picked by the earliest as before. `library_path` is the library's source path (its shard folder or the library).
pub fn appendable_library(library_path: &Path) -> bool {
    library_path.join("copies.jsonl").is_file() || library_path.parent().is_some_and(|p| p.join("copies.jsonl").is_file())
}

pub fn pick_rule_for(library_path: &Path) -> PickRule {
    if appendable_library(library_path) {
        PickRule::HighestGeneration
    } else {
        PickRule::Earliest
    }
}

/// True while a Tantivy writer holds `<dir>/.tantivy-writer.lock` (it takes an exclusive `flock` on it, here probed without
/// waiting). Sealing must not run beside a writer. Always false where the probe is not available.
fn writer_live(dir: &Path) -> bool {
    #[cfg(unix)]
    {
        use std::os::unix::io::AsRawFd;
        let Ok(f) = std::fs::File::open(dir.join(".tantivy-writer.lock")) else { return false };
        // SAFETY: flock on a descriptor this function owns.
        unsafe {
            if libc::flock(f.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) != 0 {
                return std::io::Error::last_os_error().kind() == std::io::ErrorKind::WouldBlock;
            }
            libc::flock(f.as_raw_fd(), libc::LOCK_UN);
        }
    }
    #[cfg(not(unix))]
    let _ = dir;
    false
}

/// What identifies a file's content for sealing: inode (unix), size and modification time. A change between two looks means the
/// file was rewritten (Tantivy replaces `meta.json` by a rename).
#[derive(Debug, Clone, PartialEq, Eq)]
struct FileId {
    ino: u64,
    size: u64,
    mtime: Option<std::time::SystemTime>,
}

fn file_id(path: &Path) -> Option<FileId> {
    let m = std::fs::metadata(path).ok()?;
    #[cfg(unix)]
    let ino = {
        use std::os::unix::fs::MetadataExt;
        m.ino()
    };
    #[cfg(not(unix))]
    let ino = 0;
    Some(FileId { ino, size: m.len(), mtime: m.modified().ok() })
}

// ---------------------------------------------------------------------------------------------------------
// Searching: the picked snapshot, opened in the background

/// An opened snapshot.
pub struct SnapOpen<T> {
    pub name: String,
    pub manifest: Manifest,
    pub dir: PathBuf,
    pub index: T,
}

type Cell<T> = Arc<Mutex<Option<Option<Box<SnapOpen<T>>>>>>;

/// The snapshot of one source: found, verified (hashed) and opened on a background thread, and chosen again when the folder's
/// listing changes. Reads only.
pub struct SnapSlot<T> {
    kind: &'static str,
    opener: fn(&Path, &Manifest) -> Result<T>,
    ready: Option<Box<SnapOpen<T>>>,
    pending: Option<Cell<T>>,
    key: Option<(PathBuf, Vec<String>)>,
    tried: Option<Instant>,
    /// How the snapshot is chosen: the earliest (all but a library that grows), or the highest generation (one that does).
    rule: PickRule,
}

/// The folders under `snap/`, each marked when its manifest is there (so a snapshot whose manifest arrives later is looked at again).
fn listing_key(sd: &Path) -> Vec<String> {
    snapshot::list(sd)
        .into_iter()
        .map(|n| if sd.join(SNAP_DIR).join(&n).join(MANIFEST).is_file() { format!("{n}+") } else { n })
        .collect()
}

impl<T: Send + 'static> SnapSlot<T> {
    pub fn new(kind: &'static str, opener: fn(&Path, &Manifest) -> Result<T>) -> SnapSlot<T> {
        SnapSlot { kind, opener, ready: None, pending: None, key: None, tried: None, rule: PickRule::Earliest }
    }

    /// Choose by `rule` from now on (a library that grows takes its highest generation). A change makes the next look pick again.
    pub fn set_rule(&mut self, rule: PickRule) {
        if self.rule != rule {
            self.rule = rule;
            self.key = None;
        }
    }

    pub fn ready(&self) -> Option<&SnapOpen<T>> {
        self.ready.as_deref()
    }

    /// A pick is running and nothing is ready yet.
    pub fn opening(&self) -> bool {
        self.ready.is_none() && self.pending.is_some()
    }

    /// Look at the folder again: collect a finished open, and start a new pick when the listing changed (or a snapshot that did
    /// not verify is due another look). Returns the name of a snapshot that became ready by this call.
    pub fn refresh(&mut self, indexes_dir: Option<&Path>, source_id: &str) -> Option<String> {
        let mut became = None;
        if let Some(cell) = &self.pending {
            let got = cell.lock().ok().and_then(|mut g| g.take());
            if let Some(r) = got {
                self.pending = None;
                match r {
                    Some(o) => {
                        if self.ready.as_ref().map(|c| c.name == o.name).unwrap_or(false) {
                            // the same one again: keep the open one
                        } else {
                            became = Some(o.name.clone());
                            self.ready = Some(o);
                        }
                    }
                    None => self.ready = None,
                }
            }
        }
        let Some(root) = indexes_dir else {
            self.ready = None;
            self.pending = None;
            self.key = None;
            return became;
        };
        let sd = dir_for(root, self.kind, source_id);
        let listing = listing_key(&sd);
        let key = (sd.clone(), listing.clone());
        let changed = self.key.as_ref() != Some(&key);
        if changed && self.key.as_ref().map(|k| k.0 != sd).unwrap_or(false) {
            self.ready = None;
        }
        let due = !changed
            && self.ready.is_none()
            && self.pending.is_none()
            && !listing.is_empty()
            && self.tried.map(|t| t.elapsed() >= RETRY).unwrap_or(true);
        if (changed || due) && self.pending.is_none() {
            self.key = Some(key);
            if listing.is_empty() {
                self.ready = None;
                self.tried = None;
            } else {
                self.tried = Some(Instant::now());
                self.start(sd, source_id.to_string());
            }
        } else if changed {
            // a pick is still running for the old listing: look again once it has finished
            self.key = None;
        }
        became
    }

    fn start(&mut self, sd: PathBuf, source_id: String) {
        let cell: Cell<T> = Arc::new(Mutex::new(None));
        let (c, kind, opener, rule) = (cell.clone(), self.kind, self.opener, self.rule);
        let spawned = std::thread::Builder::new().name("cs-open-snapshot".into()).spawn(move || {
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                snapshot::pick_with(&sd, kind, &source_id, compat_of(kind), rule).and_then(|pk| {
                    let index = opener(&pk.dir, &pk.manifest).ok()?;
                    // local clean-up: usable duplicates and older ones go, the one in use and a rollback stay
                    snapshot::gc_local_with(&sd, kind, &source_id, compat_of(kind), &pk, rule);
                    Some(Box::new(SnapOpen { name: pk.name, manifest: pk.manifest, dir: pk.dir, index }))
                })
            }))
            .unwrap_or(None);
            if let Ok(mut g) = c.lock() {
                *g = Some(r);
            }
        });
        if spawned.is_ok() {
            self.pending = Some(cell);
        } else {
            self.ready = None;
        }
    }
}

/// A synthetic `IndexMeta` for a snapshot in use (so status code reads one shape).
pub fn meta_of(m: &Manifest, source_key: &str) -> IndexMeta {
    IndexMeta {
        index_format: m.format,
        tokenizer: m.tokenizer.as_ref().map(|t| t.name.clone()).unwrap_or_else(|| "en_stem".into()),
        zim_uuid: source_key.to_string(),
        state: "done".into(),
        next_entry: 0,
        total: 0,
    }
}

/// True while a job builds the source's index in `.build/`.
pub fn build_live(indexes_dir: &Path, kind: &str, source_id: &str) -> bool {
    index::lock_is_live(&snapshot::build_dir(&dir_for(indexes_dir, kind, source_id)))
}

// ---------------------------------------------------------------------------------------------------------
// Building and publishing

/// Remove what is left of a finished build: every file but the seal mark, then the folder when empty.
fn clear_build(build: &Path) {
    if let Ok(rd) = std::fs::read_dir(build) {
        for e in rd.flatten() {
            let n = e.file_name();
            if n == SEAL_MARK {
                continue;
            }
            let p = e.path();
            if e.file_type().map(|t| t.is_dir()).unwrap_or(false) {
                let _ = std::fs::remove_dir_all(&p);
            } else {
                let _ = std::fs::remove_file(&p);
            }
        }
    }
    let _ = std::fs::remove_dir(build);
}

fn manifest_for(kind: &str, source_id: &str, tokenizer: &str, extra: Map<String, Value>) -> Manifest {
    Manifest {
        kind: kind.to_string(),
        source_id: source_id.to_string(),
        format: kind_format(kind),
        tantivy: TANTIVY.to_string(),
        tokenizer: Some(Tokenizer { name: tokenizer.to_string(), analyzer: ANALYZER.to_string(), remove_long: 40 }),
        chunker: None,
        core: env!("CARGO_PKG_VERSION").to_string(),
        created: snapshot::iso_now(),
        extra,
        files: Vec::new(),
    }
}

/// Stage the finished build, write the manifest last and publish by one rename. `None` when cancelled (the build is as it was).
fn publish_build(
    sd: &Path,
    kind: &str,
    source_id: &str,
    tokenizer: &str,
    extra: Map<String, Value>,
    phase: &dyn Fn(&str, u64, u64),
    cancelled: &dyn Fn() -> bool,
) -> Result<Option<(String, u64)>> {
    let build = snapshot::build_dir(sd);
    let manifest = manifest_for(kind, source_id, tokenizer, extra);
    compat_of(kind)(&manifest).map_err(Error::unsupported)?;
    let Some(stage) = snapshot::stage(&build, &NOT_IN_SNAPSHOT, true, &|d, t| phase("manifest", d, t + 1), cancelled)?
    else {
        return Ok(None);
    };
    let (id, bytes) = (stage.build_id.clone(), stage.bytes);
    if cancelled() {
        snapshot::abort(&stage);
        return Ok(None);
    }
    phase("publish", 0, 1);
    snapshot::publish(sd, stage, manifest)?;
    clear_build(&build);
    phase("publish", 1, 1);
    Ok(Some((id, bytes)))
}

/// A snapshot of the source that this device can already use (a peer's, or an earlier build's): the job adopts it.
fn adopted(sd: &Path, kind: &str, source_id: &str) -> Option<String> {
    if snapshot::list(sd).is_empty() {
        return None;
    }
    snapshot::pick(sd, kind, source_id, compat_of(kind)).map(|p| p.name)
}

/// A job's phase report: (phase, done, total).
pub type PhaseFn<'a> = dyn Fn(&str, u64, u64) + 'a;
/// One build loop: (working folder, progress, cancelled, pace).
type BuildFn<'a> = dyn Fn(&Path, &dyn Fn(u64, u64), &dyn Fn() -> bool, &dyn Fn()) -> Result<Outcome> + 'a;

/// What a snapshot build reports to its job.
pub struct Hooks<'a> {
    pub progress: Box<dyn Fn(u64, u64) + 'a>,
    pub phase: Box<PhaseFn<'a>>,
    pub cancelled: Box<dyn Fn() -> bool + 'a>,
    /// Called between items of a build loop (duty.rs).
    pub pace: Box<dyn Fn() + 'a>,
    /// The cap on Tantivy writer threads (duty.rs).
    pub threads: Option<usize>,
    pub set_result: Box<dyn Fn(Value) + 'a>,
}

/// Build (or resume) the index in `.build/` and publish it, stopping early when a usable snapshot appears (synced from a peer).
fn run_build(
    sd: &Path,
    kind: &str,
    source_id: &str,
    default_tokenizer: &str,
    extra: Map<String, Value>,
    h: &Hooks,
    build_fn: &BuildFn,
) -> Result<Outcome> {
    let build = snapshot::build_dir(sd);
    if let Some(name) = adopted(sd, kind, source_id) {
        clear_build(&build);
        (h.set_result)(json!({"adopted": true, "snapshot": name}));
        return Ok(Outcome::Done);
    }
    let seen = listing_key(sd);
    let peer = std::cell::Cell::new(false);
    let cancelled = || {
        if (h.cancelled)() {
            return true;
        }
        let now = listing_key(sd);
        if now != seen && !now.is_empty() && adopted(sd, kind, source_id).is_some() {
            peer.set(true);
            return true;
        }
        false
    };
    let out = build_fn(&build, &*h.progress, &cancelled, &*h.pace)?;
    if out == Outcome::Cancelled {
        if peer.get() {
            if let Some(name) = adopted(sd, kind, source_id) {
                clear_build(&build);
                (h.set_result)(json!({"adopted": true, "snapshot": name}));
                return Ok(Outcome::Done);
            }
        }
        return Ok(Outcome::Cancelled);
    }
    // the tokenizer the build used (a resumed build keeps the one in its record)
    let tok = read_meta(&build).map(|m| m.tokenizer).unwrap_or_else(|| default_tokenizer.to_string());
    match publish_build(sd, kind, source_id, &tok, extra, &*h.phase, &*h.cancelled)? {
        Some((id, bytes)) => {
            (h.set_result)(json!({"adopted": false, "snapshot": id, "bytes": bytes}));
            Ok(Outcome::Done)
        }
        None => Ok(Outcome::Cancelled),
    }
}

/// `index_zim` with an `indexes_dir`: the caller holds the `Lock` on `.build/`.
pub fn run_zim(zim: &ZimSource, sd: &Path, heap_mb: usize, checkpoint: usize, h: &Hooks) -> Result<Outcome> {
    let mut extra = Map::new();
    extra.insert("zim_uuid".into(), json!(zim.id));
    run_build(
        sd,
        KIND_ZIM,
        &zim.id,
        index::tokenizer_name_for(zim.language.as_deref()),
        extra,
        h,
        &|build, progress, cancelled, pace| {
            index::build_zim_index(
                &BuildParams {
                    zim,
                    index_dir: build,
                    heap_mb,
                    checkpoint_articles: checkpoint,
                    threads: h.threads,
                    pace: Some(pace),
                },
                progress,
                cancelled,
            )
        },
    )
}

/// `index_library` with an `indexes_dir`: the caller holds the `Lock` on `.build/`.
pub fn run_library(
    p: &crate::libindex::LibBuildParams,
    sd: &Path,
    source_id: &str,
    library_id: &str,
    version: Option<&str>,
    h: &Hooks,
) -> Result<Outcome> {
    let mut extra = Map::new();
    extra.insert("library_id".into(), json!(library_id));
    if let Some(v) = version {
        extra.insert("version".into(), json!(v));
    }
    run_build(sd, KIND_LIBRARY, source_id, crate::libindex::TOKENIZER, extra, h, &|build, progress, cancelled, pace| {
        crate::libindex::build_library_index(
            &crate::libindex::LibBuildParams {
                library_path: p.library_path,
                settings: p.settings,
                index_dir: build,
                heap_mb: p.heap_mb,
                checkpoint_docs: p.checkpoint_docs,
                threads: h.threads,
                pace: Some(pace),
            },
            progress,
            cancelled,
        )
    })
}

// ---------------------------------------------------------------------------------------------------------
// Sealing

#[derive(Serialize, Deserialize)]
struct SealMark {
    snapshot: String,
    legacy_dir: String,
    names: Vec<String>,
}

/// After the first successful open from snapshot `opened`: remove the old names of an index that `seal` hard-linked into it. A
/// no-op for any other snapshot and for sources that were never sealed here. Returns true when something was removed.
pub fn finish_seal(sd: &Path, opened: &str) -> bool {
    let mark_path = snapshot::build_dir(sd).join(SEAL_MARK);
    let Ok(text) = std::fs::read_to_string(&mark_path) else { return false };
    let Ok(mark) = serde_json::from_str::<SealMark>(&text) else { return false };
    if mark.snapshot != opened {
        return false;
    }
    let legacy = PathBuf::from(&mark.legacy_dir);
    if index::lock_is_live(&legacy) {
        return false;
    }
    let mut ok = true;
    // the sidecar goes first: without it the old folder no longer reads as an index
    for n in std::iter::once(META_FILE.to_string()).chain(mark.names.iter().cloned()) {
        match std::fs::remove_file(legacy.join(&n)) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(_) => ok = false,
        }
    }
    for n in NOT_IN_SNAPSHOT {
        let _ = std::fs::remove_file(legacy.join(n));
    }
    let _ = std::fs::remove_dir(&legacy);
    if ok {
        let _ = std::fs::remove_file(&mark_path);
        let _ = std::fs::remove_dir(snapshot::build_dir(sd));
    }
    ok
}

/// What `index_seal` was asked.
pub struct SealRequest {
    pub kind: &'static str,
    pub source_id: String,
    pub sd: PathBuf,
    pub legacy: PathBuf,
    /// Held for the job's lifetime: `.build/` of the source.
    pub lock: Option<Lock>,
}

/// Parse and check an `index_seal` request: `{"indexes_dir","kind","source_id","index_dir"?}`. `index_dir` names the old index
/// folder; without it the one a handle's source config gave is used. `busy` while the source is being built.
pub fn prepare_seal(params_json: &str) -> Result<SealRequest> {
    #[derive(Deserialize)]
    struct P {
        indexes_dir: String,
        kind: String,
        source_id: String,
        #[serde(default)]
        index_dir: Option<String>,
    }
    let p: P = serde_json::from_str(params_json)?;
    let kind = match p.kind.as_str() {
        KIND_ZIM => KIND_ZIM,
        KIND_LIBRARY => KIND_LIBRARY,
        other => return Err(Error::bad_json(format!("kind must be \"zim\" or \"library\", not {other:?}"))),
    };
    if p.indexes_dir.is_empty() || p.source_id.is_empty() {
        return Err(Error::bad_json("indexes_dir and source_id must not be empty"));
    }
    let source_id = if kind == KIND_ZIM { p.source_id.to_ascii_lowercase() } else { p.source_id };
    let legacy = p
        .index_dir
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .or_else(|| legacy_of(Path::new(&p.indexes_dir), kind, &source_id))
        .ok_or_else(|| Error::not_found(format!("no old index is known for {kind} {source_id}")))?;
    if kind == KIND_LIBRARY && legacy.is_dir() && !seal_blocked(&legacy) && !links_work(&legacy) {
        // links are refused on this volume: remembered in the folder, so the app is told once and never asks again
        let _ = std::fs::write(legacy.join(NO_SEAL_MARK), b"hard links cannot be made here\n");
        return Err(Error::unsupported(format!("{} is on a volume that cannot hard-link; it stays where it is", legacy.display())));
    }
    if kind == KIND_LIBRARY && seal_blocked(&legacy) {
        return Err(Error::unsupported(format!("{} cannot be sealed here", legacy.display())));
    }
    let root = snap_root(Path::new(&p.indexes_dir), kind, &source_id, Some(&legacy));
    let sd = dir_for(&root, kind, &source_id);
    let lock = Lock::acquire(&snapshot::build_dir(&sd))?;
    Ok(SealRequest { kind, source_id, sd, legacy, lock: Some(lock) })
}

enum Placed {
    Linked,
    Moved,
}

/// Seal the old index into a snapshot (see the module comment). `Done` with `{"adopted":true,"snapshot"}` when a usable snapshot
/// already exists; `{"adopted":false,"snapshot","files","bytes","method":"link"|"rename"}` after sealing.
pub fn seal(req: &SealRequest, h: &Hooks) -> Result<Outcome> {
    let (kind, sid, sd, legacy) = (req.kind, req.source_id.as_str(), req.sd.as_path(), req.legacy.as_path());
    if let Some(name) = adopted(sd, kind, sid) {
        (h.set_result)(json!({"adopted": true, "snapshot": name}));
        return Ok(Outcome::Done);
    }
    // the old index must be a finished one of this format and this source
    let format = kind_format(kind);
    if index::lock_is_live(legacy) || writer_live(legacy) {
        return Err(Error::busy(format!("{} is being indexed", legacy.display())));
    }
    let meta = read_meta(legacy)
        .ok_or_else(|| Error::new(ErrorCode::IndexMissing, format!("{} holds no index", legacy.display())))?;
    let belongs = if kind == KIND_ZIM {
        meta.zim_uuid.eq_ignore_ascii_case(sid)
    } else {
        meta.zim_uuid
            .strip_prefix("lib:")
            .is_some_and(|id| sid == id || sid.strip_prefix(id).is_some_and(|r| r.starts_with('@')))
    };
    if !belongs {
        return Err(Error::new(
            ErrorCode::IndexMissing,
            format!("{} is the index of another source", legacy.display()),
        ));
    }
    match index::index_state_for(Some(legacy), &meta.zim_uuid, format) {
        IndexState::Done(_) => {}
        IndexState::Building => return Err(Error::busy(format!("{} is being indexed", legacy.display()))),
        IndexState::Missing => {
            return Err(Error::new(ErrorCode::IndexMissing, format!("{} holds no index", legacy.display())))
        }
        IndexState::Stale | IndexState::Incomplete => {
            return Err(Error::new(
                ErrorCode::IndexStale,
                format!("the index in {} is not finished or is of another format; build it again", legacy.display()),
            ))
        }
    }
    if !legacy.join("meta.json").is_file() {
        return Err(Error::new(ErrorCode::IndexMissing, format!("{} holds no index files", legacy.display())));
    }
    let mut extra = Map::new();
    if kind == KIND_ZIM {
        extra.insert("zim_uuid".into(), json!(sid));
    } else if let Some(id) = meta.zim_uuid.strip_prefix("lib:") {
        extra.insert("library_id".into(), json!(id));
        if let Some(v) = sid.strip_prefix(id).and_then(|r| r.strip_prefix('@')) {
            extra.insert("version".into(), json!(v));
        }
    }
    extra.insert("sealed".into(), json!(true));
    let mut manifest = manifest_for(kind, sid, &meta.tokenizer, extra);
    compat_of(kind)(&manifest).map_err(|why| Error::new(ErrorCode::IndexStale, why))?;

    let mut names: Vec<String> = std::fs::read_dir(legacy)
        .map_err(|e| Error::io(format!("{}: {e}", legacy.display())))?
        .flatten()
        .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| !NOT_IN_SNAPSHOT.contains(&n.as_str()) && n != MANIFEST)
        .collect();
    names.sort();

    let build = snapshot::build_dir(sd);
    let build_id = snapshot::new_build_id();
    let stage = build.join(format!("publish-{build_id}"));
    std::fs::create_dir_all(&stage).map_err(|e| Error::io(format!("{}: {e}", stage.display())))?;
    // what every file looked like before it was linked: a rewrite while sealing (a writer or a merge still finishing) shows as a change
    let before: Vec<Option<FileId>> = names.iter().map(|n| file_id(&legacy.join(n))).collect();
    let mut placed: Vec<(String, Placed)> = Vec::new();
    let undo = |placed: &[(String, Placed)]| {
        for (n, how) in placed {
            match how {
                Placed::Linked => {
                    let _ = std::fs::remove_file(stage.join(n));
                }
                Placed::Moved => {
                    let _ = std::fs::rename(stage.join(n), legacy.join(n));
                }
            }
        }
        let _ = std::fs::remove_dir_all(&stage);
        let _ = std::fs::remove_file(build.join(SEAL_MARK));
        let _ = std::fs::remove_dir(&build);
    };

    // 1. link (or, when links are not possible and nobody has the index open, move)
    let total = names.len() as u64;
    (h.phase)("link", 0, total);
    for (k, n) in names.iter().enumerate() {
        if (h.cancelled)() {
            undo(&placed);
            return Ok(Outcome::Cancelled);
        }
        let to = stage.join(n);
        match link(&legacy.join(n), &to) {
            Ok(()) => placed.push((n.clone(), Placed::Linked)),
            Err(link_err) => {
                if is_open(legacy) {
                    undo(&placed);
                    return Err(Error::busy(format!(
                        "{} is open and cannot be hard-linked ({link_err}); try again later",
                        legacy.display()
                    )));
                }
                match std::fs::rename(legacy.join(n), &to) {
                    Ok(()) => placed.push((n.clone(), Placed::Moved)),
                    Err(e) => {
                        undo(&placed);
                        return Err(Error::io(format!("{n}: {link_err}; {e}")));
                    }
                }
            }
        }
        (h.phase)("link", k as u64 + 1, total);
    }

    // 2. hash what the manifest lists
    let mut run = || -> Result<Option<(Vec<FileEntry>, u64)>> {
        (h.phase)("verify", 0, total);
        let (mut files, mut bytes) = (Vec::new(), 0u64);
        for (k, n) in names.iter().enumerate() {
            if (h.cancelled)() {
                return Ok(None);
            }
            let (sha256, size) = snapshot::hash_file(&stage.join(n))?;
            bytes += size;
            files.push(FileEntry { path: n.clone(), size, sha256 });
            (h.phase)("verify", k as u64 + 1, total);
        }
        std::fs::write(stage.join(META_LOCK), b"").map_err(|e| Error::io(format!("{}: {e}", stage.display())))?;
        // 3. the manifest, last
        (h.phase)("manifest", 0, 1);
        manifest.files = files.clone();
        let text = serde_json::to_string_pretty(&manifest).map_err(|e| Error::internal(e.to_string()))?;
        let tmp = stage.join(format!("{MANIFEST}.tmp"));
        std::fs::write(&tmp, text).map_err(|e| Error::io(format!("{}: {e}", tmp.display())))?;
        std::fs::rename(&tmp, stage.join(MANIFEST)).map_err(|e| Error::io(format!("{}: {e}", stage.display())))?;
        (h.phase)("manifest", 1, 1);
        Ok(Some((files, bytes)))
    };
    let (files, bytes) = match run() {
        Ok(Some(x)) => x,
        Ok(None) => {
            undo(&placed);
            return Ok(Outcome::Cancelled);
        }
        Err(e) => {
            undo(&placed);
            return Err(e);
        }
    };
    if (h.cancelled)() {
        undo(&placed);
        return Ok(Outcome::Cancelled);
    }
    // the old files must be what they were when linked: unchanged, and the same files as the snapshot's (same inode)
    for ((n, how), was) in placed.iter().zip(&before) {
        if matches!(how, Placed::Linked) {
            let (now, linked) = (file_id(&legacy.join(n)), file_id(&stage.join(n)));
            #[cfg(unix)]
            let same_file = now.as_ref().map(|f| f.ino) == linked.as_ref().map(|f| f.ino);
            #[cfg(not(unix))]
            let same_file = now.as_ref().map(|f| f.size) == linked.as_ref().map(|f| f.size);
            if now != *was || !same_file {
                undo(&placed);
                return Err(Error::busy(format!(
                    "{n} in {} changed while it was being sealed; try again later",
                    legacy.display()
                )));
            }
        }
    }

    // 4. publish: the mark first (so a crash right after still finds the old names), then one rename
    (h.phase)("publish", 0, 1);
    let moved = placed.iter().any(|(_, p)| matches!(p, Placed::Moved));
    if !moved {
        let mark = SealMark {
            snapshot: build_id.clone(),
            legacy_dir: legacy.to_string_lossy().into_owned(),
            names: names.clone(),
        };
        let text = serde_json::to_string(&mark).map_err(|e| Error::internal(e.to_string()))?;
        if let Err(e) = std::fs::write(build.join(SEAL_MARK), text) {
            undo(&placed);
            return Err(Error::io(format!("{}: {e}", build.display())));
        }
    }
    let target = sd.join(SNAP_DIR).join(&build_id);
    let renamed = std::fs::create_dir_all(sd.join(SNAP_DIR)).and_then(|_| std::fs::rename(&stage, &target));
    if let Err(e) = renamed {
        undo(&placed);
        return Err(Error::new(ErrorCode::Io, format!("publishing {}: {e}", target.display())));
    }
    if moved {
        // the old folder no longer holds the index: drop what is left of it now
        let _ = std::fs::remove_file(legacy.join(META_FILE));
        for n in NOT_IN_SNAPSHOT {
            let _ = std::fs::remove_file(legacy.join(n));
        }
        let _ = std::fs::remove_dir(legacy);
        clear_build(&build);
    } else {
        let _ = std::fs::remove_dir(&build);
    }
    (h.phase)("publish", 1, 1);
    (h.set_result)(json!({
        "adopted": false, "snapshot": build_id, "files": files.len(), "bytes": bytes,
        "method": if moved { "rename" } else { "link" },
    }));
    Ok(Outcome::Done)
}


// ---------------------------------------------------------------------------------------------------------
// Growing a library's snapshot (extension by generations)

/// What `index_extend` needs.
pub struct ExtendRequest<'a> {
    pub library_path: &'a Path,
    pub settings: Option<&'a Value>,
    pub sd: &'a Path,
    pub source_id: &'a str,
    pub library_id: &'a str,
    pub version: Option<&'a str>,
    pub heap_mb: usize,
    pub checkpoint_docs: usize,
}

fn stat_of(p: &Path) -> Option<(u64, Option<std::time::SystemTime>)> {
    let m = std::fs::metadata(p).ok()?;
    Some((m.len(), m.modified().ok()))
}

/// Bring the library's newest snapshot up to date with its shard: the new snapshot is the old one's files (HARD-LINKED, so nothing is
/// copied) plus ONE new segment holding the points the snapshot lacks, with a new `meta.json`, manifest and hashes, as generation
/// g+1 of the same source. Only the new files are hashed (a linked file that is unchanged keeps the hash the old manifest gave it).
/// A source with no usable snapshot is built whole. When links cannot be made, or extending fails, the library is built whole as
/// generation g+1 (the fallback). `Done` with `{"extended":true,"generation","added","files","reused","snapshot"}`, `{"unchanged":true}`
/// when the snapshot already has every point, or `{"built":true,...}` for a whole build.
pub fn extend_library(r: &ExtendRequest, h: &Hooks) -> Result<Outcome> {
    let (sd, sid) = (r.sd, r.source_id);
    let build = snapshot::build_dir(sd);
    let Some(base) = snapshot::pick_with(sd, KIND_LIBRARY, sid, compat_library, PickRule::HighestGeneration) else {
        // nothing usable to grow: the usual whole build
        let p = crate::libindex::LibBuildParams {
            library_path: r.library_path,
            settings: r.settings,
            index_dir: sd,
            heap_mb: r.heap_mb,
            checkpoint_docs: r.checkpoint_docs,
            threads: h.threads,
            pace: None,
        };
        return run_library(&p, sd, sid, r.library_id, r.version, h);
    };
    let generation = snapshot::generation_of(&base.manifest);
    match extend_from(r, h, &base, generation) {
        Ok(out) => Ok(out),
        Err(e) if e.code == ErrorCode::Cancelled => Ok(Outcome::Cancelled),
        Err(e) => {
            // the fallback: a whole build, published as the next generation
            std::fs::create_dir_all(&build).map_err(|e| Error::io(format!("{}: {e}", build.display())))?;
            (h.phase)("rebuild", 0, 1);
            let mut extra = Map::new();
            extra.insert("library_id".into(), json!(r.library_id));
            if let Some(v) = r.version {
                extra.insert("version".into(), json!(v));
            }
            extra.insert("generation".into(), json!(generation + 1));
            let out = crate::libindex::build_library_index(
                &crate::libindex::LibBuildParams {
                    library_path: r.library_path,
                    settings: r.settings,
                    index_dir: &build,
                    heap_mb: r.heap_mb,
                    checkpoint_docs: r.checkpoint_docs,
                    threads: h.threads,
                    pace: None,
                },
                &*h.progress,
                &*h.cancelled,
            )?;
            if out == Outcome::Cancelled {
                return Ok(out);
            }
            match publish_build(sd, KIND_LIBRARY, sid, crate::libindex::TOKENIZER, extra, &*h.phase, &*h.cancelled)? {
                Some((id, _)) => {
                    (h.set_result)(json!({"built": true, "generation": generation + 1, "snapshot": id, "because": e.message}));
                    Ok(Outcome::Done)
                }
                None => Ok(Outcome::Cancelled),
            }
        }
    }
}

fn extend_from(r: &ExtendRequest, h: &Hooks, base: &snapshot::Picked, generation: u64) -> Result<Outcome> {
    let sd = r.sd;
    let build = snapshot::build_dir(sd);
    let tokenizer = base.manifest.tokenizer.as_ref().map(|t| t.name.clone()).unwrap_or_else(|| crate::libindex::TOKENIZER.into());
    // 1. what the shard has that the snapshot lacks
    (h.phase)("scan", 0, 1);
    let opened = crate::libindex::LibOpenIndex::open(&base.dir, &tokenizer)?;
    let Some((missing, points)) =
        crate::libindex::missing_documents(r.library_path, r.settings, &opened, &*h.progress, &*h.cancelled, &*h.pace)?
    else {
        return Err(Error::new(ErrorCode::Cancelled, "cancelled"));
    };
    let recorded = base.manifest.extra.get("points").and_then(|p| p.as_u64());
    if missing.is_empty() && recorded == Some(points) {
        (h.set_result)(json!({"unchanged": true, "generation": generation, "snapshot": base.name}));
        return Ok(Outcome::Done);
    }
    drop(opened);
    // 2. the new snapshot's folder: the old files, linked
    let build_id = snapshot::new_build_id();
    let stage = build.join(format!("publish-{build_id}"));
    let _ = std::fs::remove_dir_all(&stage);
    std::fs::create_dir_all(&stage).map_err(|e| Error::io(format!("{}: {e}", stage.display())))?;
    let undo = || {
        let _ = std::fs::remove_dir_all(&stage);
        let _ = std::fs::remove_dir(&build);
    };
    let cleaned = (|| -> Result<(Vec<FileEntry>, u64, usize, usize)> {
        let mut linked: Vec<String> = Vec::new();
        (h.phase)("link", 0, base.manifest.files.len() as u64);
        for f in &base.manifest.files {
            if NOT_IN_SNAPSHOT.contains(&f.path.as_str()) {
                continue;
            }
            link(&base.dir.join(&f.path), &stage.join(&f.path))
                .map_err(|e| Error::io(format!("{}: cannot link into the next generation: {e}", f.path)))?;
            linked.push(f.path.clone());
        }
        // 3. one new segment holding the missing points (no merge; Tantivy adds files and replaces meta.json by a rename)
        (h.phase)("append", 0, missing.len() as u64);
        let segments_before = crate::libindex::append_segment(&stage, &tokenizer, &missing, h.threads.unwrap_or(1), r.heap_mb)?;
        let _ = std::fs::remove_file(stage.join(".tantivy-writer.lock"));
        // 4. hashes: a linked file that is still the old one keeps its hash; everything else is hashed
        let old: HashMap<&str, &FileEntry> = base.manifest.files.iter().map(|f| (f.path.as_str(), f)).collect();
        let mut names: Vec<String> = std::fs::read_dir(&stage)
            .map_err(|e| Error::io(format!("{}: {e}", stage.display())))?
            .flatten()
            .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| !NOT_IN_SNAPSHOT.contains(&n.as_str()) && n != MANIFEST && !n.ends_with(".tmp"))
            .collect();
        names.sort();
        let total = names.len() as u64;
        (h.phase)("verify", 0, total);
        let (mut files, mut bytes, mut reused) = (Vec::new(), 0u64, 0usize);
        for (k, n) in names.iter().enumerate() {
            if (h.cancelled)() {
                return Err(Error::new(ErrorCode::Cancelled, "cancelled"));
            }
            let same = old.get(n.as_str()).filter(|o| {
                linked.contains(n) && stat_of(&stage.join(n)) == stat_of(&base.dir.join(n)) && stat_of(&stage.join(n)).map(|s| s.0) == Some(o.size)
            });
            let entry = match same {
                Some(o) => {
                    reused += 1;
                    (*o).clone()
                }
                None => {
                    let (sha256, size) = snapshot::hash_file(&stage.join(n))?;
                    FileEntry { path: n.clone(), size, sha256 }
                }
            };
            bytes += entry.size;
            files.push(entry);
            (h.phase)("verify", k as u64 + 1, total);
        }
        std::fs::write(stage.join(META_LOCK), b"").map_err(|e| Error::io(format!("{}: {e}", stage.display())))?;
        Ok((files, bytes, reused, segments_before))
    })();
    let (files, bytes, reused, _segments_before) = match cleaned {
        Ok(x) => x,
        Err(e) => {
            undo();
            return Err(e);
        }
    };
    if (h.cancelled)() {
        undo();
        return Ok(Outcome::Cancelled);
    }
    // 5. the manifest: the old one's facts, one generation more, the points it covers; published by one rename
    let mut manifest = base.manifest.clone();
    manifest.created = snapshot::iso_now();
    manifest.extra.insert("generation".into(), json!(generation + 1));
    manifest.extra.insert("points".into(), json!(points));
    let st = snapshot::Stage::prepared(&build, build_id.clone(), stage.clone(), files.clone(), bytes);
    (h.phase)("publish", 0, 1);
    if let Err(e) = snapshot::publish(sd, st, manifest) {
        undo();
        return Err(e.into());
    }
    let _ = std::fs::remove_dir(&build);
    (h.phase)("publish", 1, 1);
    (h.set_result)(json!({
        "extended": true, "generation": generation + 1, "added": missing.len(), "files": files.len(), "reused": reused,
        "snapshot": build_id, "from": base.name,
    }));
    Ok(Outcome::Done)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn library_source_ids_follow_status() {
        assert_eq!(library_source_id("lib", Some("3")), "lib@3");
        assert_eq!(library_source_id("lib", None), "lib");
    }

    #[test]
    fn compat_checks_format_tantivy_and_tokenizer() {
        let mut m = manifest_for(KIND_ZIM, "u", "fr_stem", Map::new());
        assert!(compat_zim(&m).is_ok());
        assert!(compat_library(&m).is_err(), "a library index is English-only and has its own format");
        m.tantivy = "0.99".into();
        assert!(compat_zim(&m).is_err());
        let l = manifest_for(KIND_LIBRARY, "l@1", "en_stem", Map::new());
        assert!(compat_library(&l).is_ok() && compat_zim(&l).is_err());
    }

    #[test]
    fn a_file_replaced_by_a_rename_has_another_identity_and_a_live_writer_is_seen() {
        let d = std::env::temp_dir().join(format!("cs-idxsnap-id-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let f = d.join("meta.json");
        std::fs::write(&f, b"{}").unwrap();
        let a = file_id(&f).unwrap();
        assert_eq!(file_id(&f).unwrap(), a);
        // Tantivy rewrites meta.json by writing a new file and renaming it over the old one
        std::fs::write(d.join("meta.json.tmp"), b"{}").unwrap();
        std::fs::rename(d.join("meta.json.tmp"), &f).unwrap();
        #[cfg(unix)]
        assert_ne!(file_id(&f).unwrap().ino, a.ino);
        assert!(!writer_live(&d));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn legacy_folders_are_looked_up_per_indexes_dir() {
        let (a, b) = (Path::new("/nonexistent/idx-a"), Path::new("/nonexistent/idx-b"));
        note_legacy(a, "zim", "u", Path::new("/old/a"));
        note_legacy(b, "zim", "u", Path::new("/old/b"));
        assert_eq!(legacy_of(a, "zim", "u").unwrap(), Path::new("/old/a"));
        assert_eq!(legacy_of(b, "zim", "u").unwrap(), Path::new("/old/b"));
        assert!(legacy_of(a, "library", "u").is_none());
    }

    #[test]
    fn open_guard_counts_opens() {
        let d = std::env::temp_dir().join(format!("cs-idxsnap-open-{}", std::process::id()));
        std::fs::create_dir_all(&d).unwrap();
        assert!(!is_open(&d));
        let g = OpenGuard::new(&d);
        assert!(is_open(&d));
        drop(g);
        assert!(!is_open(&d));
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_librarys_snapshots_go_beside_its_old_index_only_when_the_indexes_folder_is_on_another_volume() {
        let d = std::env::temp_dir().join(format!("cs-idxsnap-root-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let (idx, old) = (d.join("indexes"), d.join("lib").join("index"));
        std::fs::create_dir_all(&idx).unwrap();
        let (other, same): (&dyn Fn(&Path, &Path) -> bool, &dyn Fn(&Path, &Path) -> bool) = (&|_, _| false, &|_, _| true);
        // another volume, nothing in the indexes folder yet: beside the old index
        let local = snap_root_with(&idx, KIND_LIBRARY, "l@1", Some(&old), other);
        assert_eq!(local, d.join("lib").join("index-snapshots"));
        // one volume: the indexes folder, as before
        assert_eq!(snap_root_with(&idx, KIND_LIBRARY, "l@1", Some(&old), same), idx);
        // a ZIM, and a library with no old index, never move
        assert_eq!(snap_root_with(&idx, KIND_ZIM, "u", Some(&old), other), idx);
        assert_eq!(snap_root_with(&idx, KIND_LIBRARY, "l@1", None, other), idx);
        // snapshots an earlier build left in the indexes folder keep it: nothing moves, nothing is copied
        let sd = dir_for(&idx, KIND_LIBRARY, "l@1");
        std::fs::create_dir_all(sd.join(SNAP_DIR).join("b1")).unwrap();
        assert_eq!(snap_root_with(&idx, KIND_LIBRARY, "l@1", Some(&old), other), idx);
        // another library of the same indexes folder is not held by that
        assert_eq!(snap_root_with(&idx, KIND_LIBRARY, "l@2", Some(&old), other), local);
        let _ = std::fs::remove_dir_all(&d);
    }
}
