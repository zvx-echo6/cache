//! Automatic checks of linked folders.
//!
//! Two triggers start the same background check job the "Check now" button starts (`linked_api::start_with`):
//!
//! - **Notifications** on local disks (inotify through [`super::linked_watch`]): a change to a PDF or a folder marks that folder
//!   "dirty"; once it has been quiet for `quiet_ms` one check runs for it. Events that arrive meanwhile coalesce into that one check.
//! - **An hourly rescan** of every linked folder, for network shares and anywhere notifications do not work (and to catch up on
//!   anything missed). If inotify is unavailable or its watch limit is hit, a folder simply stays on the hourly rescan.
//!
//! **The settle rule.** A file is read (hashed) only once its size and modified time have been unchanged for `settle_ms` (10 s
//! for automatic checks), as seen by two checks at least that far apart. The scanner records when it first saw a file's current
//! size and time; any change starts the clock again. If a file's size or time changes between the start and the end of reading it,
//! that result is dropped and the file waits again. When a check leaves files still settling, the scheduler comes back after the
//! delay (a follow-up check); the check job itself never waits. A big copy that takes minutes keeps changing, so it keeps being
//! put off and is read only once the copy has been still for `settle_ms`.
//!
//! The scheduler never writes in a linked folder, never checks a paused folder, never starts a second check while one runs for the
//! library, and rebuilds its watches from the saved registry when the server starts.
use super::{
    linked_api,
    linked_registry::LinkedRegistry,
    linked_watch::{self, Notifier, TreeOutcome},
    BuildService,
};
use std::{
    collections::{BTreeSet, HashMap},
    path::PathBuf,
    sync::Arc,
    thread,
    time::{Instant, SystemTime},
};

#[derive(Clone, Copy, Debug)]
pub struct AutoConfig {
    /// A file is read only after its size and modified time have been stable this long.
    pub settle_ms: u64,
    /// After the last change to a folder, wait this long before checking it (events in between coalesce).
    pub quiet_ms: u64,
    /// How often every folder is rescanned, whether or not notifications arrived.
    pub rescan_ms: u64,
    /// How long one wait for notifications lasts (also how fast the scheduler reacts).
    pub poll_ms: i32,
    /// How often the list of linked folders is read again.
    pub sync_ms: u64,
    /// After a check could not start, wait this long.
    pub retry_ms: u64,
}

impl Default for AutoConfig {
    fn default() -> Self {
        AutoConfig { settle_ms: 10_000, quiet_ms: 2_000, rescan_ms: 3_600_000, poll_ms: 1_000, sync_ms: 30_000, retry_ms: 30_000 }
    }
}

/// When one folder is next due a check. Times are milliseconds on the scheduler's own clock.
#[derive(Clone, Debug)]
pub struct Plan {
    dirty: bool,
    last_event: u64,
    next_rescan: u64,
    follow_up: Option<u64>,
    retry_at: u64,
}

impl Plan {
    pub fn new(now: u64, cfg: &AutoConfig) -> Plan {
        Plan { dirty: false, last_event: now, next_rescan: now + cfg.rescan_ms, follow_up: None, retry_at: 0 }
    }
    /// Something changed in the folder.
    pub fn changed(&mut self, now: u64) {
        self.dirty = true;
        self.last_event = now;
    }
    pub fn rescan_due(&self, now: u64) -> bool {
        now >= self.next_rescan
    }
    /// Is a check due? A paused folder is never due (its dirty mark is kept, so it is checked once resumed), and neither is one
    /// while a check is running.
    pub fn due(&self, now: u64, cfg: &AutoConfig, paused: bool, busy: bool) -> bool {
        if paused || busy || now < self.retry_at {
            return false;
        }
        (self.dirty && now.saturating_sub(self.last_event) >= cfg.quiet_ms)
            || self.follow_up.is_some_and(|at| now >= at)
            || self.rescan_due(now)
    }
    /// A check was started: everything seen so far is covered by it (later events set the mark again).
    pub fn started(&mut self, now: u64, cfg: &AutoConfig) {
        self.dirty = false;
        self.follow_up = None;
        self.next_rescan = now + cfg.rescan_ms;
    }
    /// A check ended. If files were still settling, come back once the settle delay has passed.
    pub fn finished(&mut self, now: u64, cfg: &AutoConfig, still_settling: bool) {
        self.follow_up = still_settling.then_some(now + cfg.settle_ms + 250);
    }
    pub fn could_not_start(&mut self, now: u64, cfg: &AutoConfig) {
        self.retry_at = now + cfg.retry_ms;
    }
}

struct RootAuto {
    path: PathBuf,
    exclusions: Vec<PathBuf>,
    plan: Plan,
    /// Are notifications in place for this folder? If not, only the rescan checks it.
    watched: bool,
    /// Pause as saved in the registry (the runtime control, when present, overrides it).
    saved_paused: bool,
}

struct LibAuto {
    target: PathBuf,
    roots: HashMap<String, RootAuto>,
    /// The check this scheduler started: (folder id, job id).
    running: Option<(String, String)>,
    /// Size and modified time of the saved registry when it was last read (it is read again only when they change).
    stamp: Option<(SystemTime, u64)>,
}

pub struct Auto {
    cfg: AutoConfig,
    clock: Instant,
    notifier: Box<dyn Notifier>,
    libs: HashMap<String, LibAuto>,
    last_sync: Option<u64>,
    booted: bool,
    /// How many checks this scheduler has started (for tests).
    pub jobs_started: usize,
}

/// The notifier's name for a folder: library and folder ids together (ids never contain a colon).
fn key(lib: &str, root: &str) -> String {
    format!("{lib}:{root}")
}

impl Auto {
    pub fn new(cfg: AutoConfig, notifier: Box<dyn Notifier>) -> Auto {
        Auto { cfg, clock: Instant::now(), notifier, libs: HashMap::new(), last_sync: None, booted: false, jobs_started: 0 }
    }

    fn now(&self) -> u64 {
        self.clock.elapsed().as_millis() as u64
    }

    /// Are notifications in place for this folder? (`None` when the folder is not known.)
    pub fn is_watched(&self, lib: &str, root: &str) -> Option<bool> {
        self.libs.get(lib)?.roots.get(root).map(|r| r.watched)
    }

    fn watch(notifier: &mut dyn Notifier, lib: &str, id: &str, root: &RootAuto) -> bool {
        match notifier.watch_root(&key(lib, id), &root.path, &root.exclusions) {
            TreeOutcome::Watching { dirs } => dirs > 0,
            TreeOutcome::LimitReached { dirs } => {
                eprintln!(
                    "cache: linked folder {id} in library {lib}: the inotify watch limit was reached after {dirs} folders \
                     (fs.inotify.max_user_watches); it is checked by the hourly rescan instead"
                );
                false
            }
            TreeOutcome::Unsupported(why) => {
                eprintln!("cache: linked folder {id} in library {lib}: no change notifications ({why}); it is checked by the hourly rescan");
                false
            }
        }
    }

    /// Read the saved registries: new folders get watches, removed ones lose them, a changed path or exclusion list is watched afresh.
    fn sync(&mut self, svc: &BuildService, now: u64) {
        let libs_dir = svc.data.join("app/docs/libraries");
        let mut names: BTreeSet<String> = BTreeSet::new();
        if let Ok(read) = std::fs::read_dir(&libs_dir) {
            for entry in read.flatten() {
                let name = entry.file_name().to_string_lossy().into_owned();
                if entry.path().join(".local/linked-registry.json").is_file() {
                    names.insert(name);
                }
            }
        }
        let booted = self.booted;
        let cfg = self.cfg;
        let Auto { notifier, libs, .. } = self;
        let gone: Vec<String> = libs.keys().filter(|name| !names.contains(*name)).cloned().collect();
        for name in gone {
            if let Some(lib) = libs.remove(&name) {
                for id in lib.roots.keys() {
                    notifier.forget_root(&key(&name, id));
                }
            }
        }
        for name in names {
            let Ok(target) = linked_api::library_path(&svc.data, &name) else { continue };
            let stamp = std::fs::metadata(target.join(".local/linked-registry.json")).and_then(|m| m.modified().map(|t| (t, m.len()))).ok();
            if libs.get(&name).is_some_and(|lib| lib.stamp.is_some() && lib.stamp == stamp) {
                continue; // unchanged since it was last read
            }
            let Ok(data) = LinkedRegistry::read_saved(&target.join(".local")) else { continue };
            let lib = libs.entry(name.clone()).or_insert_with(|| LibAuto { target: target.clone(), roots: HashMap::new(), running: None, stamp: None });
            lib.target = target;
            lib.stamp = stamp;
            let wanted: BTreeSet<&str> = data.roots.iter().map(|r| r.id.as_str()).collect();
            lib.roots.retain(|id, _| {
                let keep = wanted.contains(id.as_str());
                if !keep {
                    notifier.forget_root(&key(&name, id));
                }
                keep
            });
            for root in &data.roots {
                if let Some(existing) = lib.roots.get_mut(&root.id) {
                    if existing.path == root.path && existing.exclusions == root.exclusions {
                        existing.saved_paused = root.paused;
                        continue;
                    }
                }
                let mut fresh = RootAuto {
                    path: root.path.clone(),
                    exclusions: root.exclusions.clone(),
                    plan: Plan::new(now, &cfg),
                    watched: false,
                    saved_paused: root.paused,
                };
                fresh.watched = Auto::watch(notifier.as_mut(), &name, &root.id, &fresh);
                // After a restart, anything may have changed while the server was down: check once.
                if !booted && !root.state.is_empty() {
                    fresh.plan.changed(now);
                }
                lib.roots.insert(root.id.clone(), fresh);
            }
        }
        self.booted = true;
    }

    /// One turn: refresh the folder list now and then, wait for changes (up to `poll_ms`), and start what is due.
    pub fn tick(&mut self, svc: &Arc<BuildService>) {
        let now = self.now();
        if self.last_sync.is_none_or(|at| now.saturating_sub(at) >= self.cfg.sync_ms) {
            self.sync(svc, now);
            self.last_sync = Some(self.now());
        }
        let changes = self.notifier.wait(self.cfg.poll_ms);
        let now = self.now();
        let cfg = self.cfg;
        let Auto { notifier, libs, jobs_started, .. } = self;
        for change in changes {
            if let Some((lib, root)) = change.root_id.split_once(':') {
                if let Some(r) = libs.get_mut(lib).and_then(|l| l.roots.get_mut(root)) {
                    r.plan.changed(now);
                }
            }
        }
        for (name, lib) in libs.iter_mut() {
            // A folder that lost its watches while following new subfolders (the limit) is rescan-only from now on.
            for (id, r) in lib.roots.iter_mut() {
                if r.watched && !notifier.watching(&key(name, id)) {
                    r.watched = false;
                    r.plan.changed(now);
                    eprintln!(
                        "cache: linked folder {id} in library {name}: the inotify watch limit was reached; it is checked by the hourly rescan instead"
                    );
                }
            }
            let sidecar = lib.target.join(".local");
            let rt = linked_api::runtime(&sidecar);
            let (active, latest, controls) = {
                let state = rt.lock().unwrap_or_else(|e| e.into_inner());
                (state.active.is_some(), state.latest.clone(), state.controls.clone())
            };
            if active {
                continue; // one check at a time per library, ours or the person's
            }
            if let Some((root, job_id)) = lib.running.take() {
                if let Some(done) = latest.filter(|job| job.job_id == job_id) {
                    if done.state == "failed" {
                        eprintln!("cache: automatic check of linked folder {root} in library {name} failed: {:?}", done.error);
                    }
                    let settling = done.roots.iter().any(|row| {
                        row["root_id"].as_str() == Some(root.as_str()) && row["settling_file_count"].as_u64().unwrap_or(0) > 0
                    });
                    if let Some(r) = lib.roots.get_mut(&root) {
                        r.plan.finished(now, &cfg, settling);
                    }
                }
            }
            let mut ids: Vec<String> = lib.roots.keys().cloned().collect();
            ids.sort();
            for id in ids {
                let Some(r) = lib.roots.get_mut(&id) else { continue };
                let paused = controls.get(&id).copied().unwrap_or(r.saved_paused);
                if !r.plan.due(now, &cfg, paused, false) {
                    continue;
                }
                if !r.watched && r.plan.rescan_due(now) {
                    // The rescan is also the moment to try for watches again (a drive that came back, a freed-up limit).
                    r.watched = Auto::watch(notifier.as_mut(), name, &id, r);
                }
                match linked_api::start_with(svc, &lib.target, Some(id.clone()), None, Some(cfg.settle_ms)) {
                    Ok(job) => {
                        r.plan.started(now, &cfg);
                        lib.running = Some((id, job.job_id));
                        *jobs_started += 1;
                        break;
                    }
                    Err(e) => {
                        eprintln!("cache: automatic check of linked folder {id} in library {name} did not start: {}", e.message);
                        r.plan.could_not_start(now, &cfg);
                    }
                }
            }
        }
    }
}

/// Start the scheduler thread (with the build service's other threads). It ends when the service is stopped.
pub fn start(svc: &Arc<BuildService>) {
    let svc = svc.clone();
    let spawned = thread::Builder::new().name("linked-folder-auto".into()).spawn(move || {
        let mut auto = Auto::new(AutoConfig::default(), linked_watch::system_notifier());
        while !svc.is_stopping() {
            auto.tick(&svc);
        }
    });
    if let Err(e) = spawned {
        eprintln!("cache: automatic linked-folder checks could not start: {e}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        libbuild::{
            linked_registry::RegistryData,
            tests::rig_with,
            BuildConfig,
        },
        TempDir,
    };
    use serde_json::json;
    use std::{
        collections::BTreeMap,
        fs,
        io::Write,
        path::Path,
        time::{Duration, SystemTime},
    };

    fn cfg_fast() -> AutoConfig {
        AutoConfig { settle_ms: 300, quiet_ms: 100, rescan_ms: 3_600_000, poll_ms: 50, sync_ms: 100, retry_ms: 100 }
    }

    /// A library with a linked folder, and a scheduler that is not running (the tests turn it by hand).
    struct Rig {
        _data: TempDir,
        svc: Arc<BuildService>,
        target: PathBuf,
        source: PathBuf,
    }

    impl Rig {
        fn new(documents: &str) -> Rig {
            let data = TempDir::new("linked-auto");
            let config = BuildConfig {
                settle: Duration::from_millis(1),
                poll: Duration::from_secs(3600),
                publish_every: Duration::from_secs(3600),
                on_rescan: None,
            };
            let (svc, _) = rig_with(&data, config);
            let target = svc.data.join("app/docs/libraries/example");
            fs::create_dir_all(&target).unwrap();
            fs::write(target.join("cache-library.json"), b"{}").unwrap();
            fs::write(target.join("documents.tsv"), documents).unwrap();
            let source = data.0.join("source");
            fs::create_dir_all(&source).unwrap();
            let target = target.canonicalize().unwrap();
            let mut registry = LinkedRegistry::open(&target.join(".local"), &target).unwrap();
            registry.register_root("root-a", "Folder".into(), &source, vec![]).unwrap();
            let source = source.canonicalize().unwrap();
            Rig { _data: data, svc, target, source }
        }
        fn saved(&self) -> RegistryData {
            LinkedRegistry::read_saved(&self.target.join(".local")).unwrap()
        }
        fn auto(&self, cfg: AutoConfig) -> Auto {
            Auto::new(cfg, linked_watch::system_notifier())
        }
        fn pump(&self, auto: &mut Auto, seconds: u64, mut done: impl FnMut(&Rig) -> bool) -> bool {
            let end = Instant::now() + Duration::from_secs(seconds);
            while Instant::now() < end {
                auto.tick(&self.svc);
                if done(self) {
                    return true;
                }
            }
            false
        }
        fn run_for(&self, auto: &mut Auto, millis: u64) {
            let end = Instant::now() + Duration::from_millis(millis);
            while Instant::now() < end {
                auto.tick(&self.svc);
            }
        }
        /// Is there a book with this document id, found at this path in the folder?
        fn book_at(&self, relpath: &str) -> Option<crate::libbuild::linked_registry::LinkedBook> {
            self.saved().books.into_iter().find(|b| b.locations.iter().any(|l| l.relative_path == relpath && l.available))
        }
    }

    fn pdf_bytes(tag: &str) -> Vec<u8> {
        format!("%PDF-1.4 test document {tag} {}", "x".repeat(4096)).into_bytes()
    }

    fn row(doc: &str, bytes: &[u8]) -> String {
        format!("{doc}\t1\tTitle {doc}\t{}\t1\t1\n", blake3::hash(bytes).to_hex())
    }

    type Snapshot = BTreeMap<String, (String, u64, SystemTime)>;
    fn snapshot(root: &Path) -> Snapshot {
        let mut out = Snapshot::new();
        let mut stack = vec![root.to_path_buf()];
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(&dir).unwrap().flatten() {
                let path = entry.path();
                let meta = fs::metadata(&path).unwrap();
                if meta.is_dir() {
                    stack.push(path);
                } else {
                    let rel = path.strip_prefix(root).unwrap().to_string_lossy().into_owned();
                    out.insert(rel, (blake3::hash(&fs::read(&path).unwrap()).to_hex().to_string(), meta.len(), meta.modified().unwrap()));
                }
            }
        }
        out
    }

    // ---- scheduling rules, with no files and no clock

    #[test]
    fn events_coalesce_into_one_check_after_the_folder_is_quiet() {
        let cfg = cfg_fast();
        let mut plan = Plan::new(0, &cfg);
        assert!(!plan.due(10, &cfg, false, false));
        for t in [1000, 1030, 1060, 1090] {
            plan.changed(t);
            assert!(!plan.due(t, &cfg, false, false), "not while changes keep arriving");
        }
        assert!(!plan.due(1150, &cfg, false, false));
        assert!(plan.due(1190, &cfg, false, false));
        plan.started(1190, &cfg);
        assert!(!plan.due(1200, &cfg, false, false), "one check covered every event");
        plan.changed(1300);
        assert!(!plan.due(1300, &cfg, false, true), "never while a check runs");
        assert!(plan.due(1400, &cfg, false, false));
    }

    #[test]
    fn a_paused_folder_is_never_due_but_is_checked_once_resumed() {
        let cfg = cfg_fast();
        let mut plan = Plan::new(0, &cfg);
        plan.changed(100);
        assert!(!plan.due(10_000, &cfg, true, false));
        assert!(!plan.due(cfg.rescan_ms + 1, &cfg, true, false), "not even the hourly rescan");
        assert!(plan.due(10_000, &cfg, false, false), "the change is not forgotten");
    }

    #[test]
    fn every_folder_is_rescanned_each_hour_and_settling_files_get_a_follow_up() {
        let cfg = AutoConfig { rescan_ms: 3_600_000, ..cfg_fast() };
        let mut plan = Plan::new(0, &cfg);
        assert!(!plan.due(3_599_999, &cfg, false, false));
        assert!(plan.due(3_600_000, &cfg, false, false));
        plan.started(3_600_000, &cfg);
        assert!(!plan.due(3_600_001, &cfg, false, false));
        plan.finished(3_600_100, &cfg, true);
        assert!(!plan.due(3_600_100 + cfg.settle_ms, &cfg, false, false), "the delay must have fully passed");
        assert!(plan.due(3_600_100 + cfg.settle_ms + 250, &cfg, false, false));
        plan.started(3_700_000, &cfg);
        plan.finished(3_700_100, &cfg, false);
        assert!(!plan.due(3_800_000, &cfg, false, false));
        let mut failing = Plan::new(0, &cfg);
        failing.changed(0);
        failing.could_not_start(500, &cfg);
        assert!(!failing.due(550, &cfg, false, false));
        assert!(failing.due(700, &cfg, false, false));
    }

    // ---- the whole thing, on real folders

    #[test]
    fn a_new_pdf_is_found_and_matched_without_pressing_check() {
        let bytes = pdf_bytes("one");
        let rig = Rig::new(&row("doc-one", &bytes));
        let mut auto = rig.auto(cfg_fast());
        rig.run_for(&mut auto, 300); // watches are in place
        fs::write(rig.source.join("new.pdf"), &bytes).unwrap();
        fs::write(rig.source.join("not-in-catalog.pdf"), pdf_bytes("unknown")).unwrap();
        let written = snapshot(&rig.source);
        assert!(rig.pump(&mut auto, 20, |r| r.book_at("new.pdf").is_some_and(|b| b.doc_id.as_deref() == Some("doc-one") && !b.pending_indexing)));
        // the PDF the library does not know yet is recorded, still waiting to be indexed, never half-way
        assert!(rig.pump(&mut auto, 20, |r| r.book_at("not-in-catalog.pdf").is_some_and(|b| b.doc_id.is_none() && b.pending_indexing)));
        // an imported library only matches: the unknown PDF is not queued for building, and the library says so
        assert!(super::super::lock(&rig.svc.st).items.is_empty());
        let caps = linked_api::request(&rig.svc, "GET", "example", &[], b"").unwrap();
        assert_eq!(caps["capabilities"]["index_new_pdfs"], json!(false));
        // no check button, no manual job: the scheduler started the checks
        assert!(auto.jobs_started >= 1);
        // originals: same bytes, sizes and times as when they were written, and nothing else appeared in the folder
        assert_eq!(snapshot(&rig.source), written);
        assert_eq!(fs::read_dir(&rig.source).unwrap().count(), 2);
    }

    #[test]
    fn a_burst_of_new_files_is_one_check_not_one_per_event() {
        let rig = Rig::new("");
        let mut auto = rig.auto(cfg_fast());
        rig.run_for(&mut auto, 300);
        for i in 0..5 {
            fs::write(rig.source.join(format!("f{i}.pdf")), pdf_bytes(&format!("burst {i}"))).unwrap();
        }
        assert!(rig.pump(&mut auto, 20, |r| r.saved().books.len() == 5));
        assert!(auto.jobs_started <= 3, "{} checks for one burst", auto.jobs_started);
    }

    #[test]
    fn a_file_still_growing_is_not_read_until_it_is_stable() {
        let full = pdf_bytes("growing").repeat(8);
        let rig = Rig::new(&row("doc-grow", &full));
        let mut auto = rig.auto(cfg_fast());
        rig.run_for(&mut auto, 300);
        let path = rig.source.join("copy.pdf");
        let chunk = full.len() / 8;
        let writer_path = path.clone();
        let content = full.clone();
        let writer = thread::spawn(move || {
            let mut f = fs::OpenOptions::new().create(true).append(true).open(&writer_path).unwrap();
            for part in content.chunks(chunk) {
                f.write_all(part).unwrap();
                f.flush().unwrap();
                thread::sleep(Duration::from_millis(120));
            }
        });
        let mut seen_hashes: BTreeSet<String> = BTreeSet::new();
        let mut during = 0;
        while !writer.is_finished() {
            auto.tick(&rig.svc);
            for b in rig.saved().books {
                seen_hashes.insert(b.blake3);
                during += 1;
            }
        }
        writer.join().unwrap();
        assert_eq!(during, 0, "nothing was read while the copy was still changing");
        assert!(rig.pump(&mut auto, 20, |r| r.book_at("copy.pdf").is_some_and(|b| b.doc_id.as_deref() == Some("doc-grow"))));
        for b in rig.saved().books {
            seen_hashes.insert(b.blake3);
        }
        assert_eq!(seen_hashes, BTreeSet::from([blake3::hash(&full).to_hex().to_string()]), "only ever the whole file");
        assert_eq!(fs::read(&path).unwrap(), full);
    }

    #[test]
    fn a_moved_file_keeps_its_book_and_is_not_indexed_again() {
        let bytes = pdf_bytes("moving");
        let rig = Rig::new(&row("doc-move", &bytes));
        let mut auto = rig.auto(cfg_fast());
        rig.run_for(&mut auto, 300);
        fs::create_dir_all(rig.source.join("a")).unwrap();
        fs::create_dir_all(rig.source.join("b")).unwrap();
        fs::write(rig.source.join("a/old.pdf"), &bytes).unwrap();
        assert!(rig.pump(&mut auto, 20, |r| r.book_at("a/old.pdf").is_some()));
        let original = snapshot(&rig.source)["a/old.pdf"].clone();
        fs::rename(rig.source.join("a/old.pdf"), rig.source.join("b/new.pdf")).unwrap();
        assert!(rig.pump(&mut auto, 20, |r| r.book_at("b/new.pdf").is_some()));
        let saved = rig.saved();
        assert_eq!(saved.books.len(), 1, "the same book, not a second one");
        let book = &saved.books[0];
        assert_eq!((book.doc_id.as_deref(), book.pending_indexing), (Some("doc-move"), false));
        assert_eq!(book.locations.len(), 1, "the old place is replaced, not kept as a ghost");
        assert_eq!(book.locations[0].relative_path, "b/new.pdf");
        assert!(super::super::lock(&rig.svc.st).items.is_empty(), "nothing was queued to be built again");
        assert_eq!(snapshot(&rig.source)["b/new.pdf"], original, "same bytes, size and modified time");
    }

    #[test]
    fn a_deleted_file_stays_in_the_library_as_not_available() {
        let bytes = pdf_bytes("deleted");
        let documents = row("doc-gone", &bytes);
        let rig = Rig::new(&documents);
        let mut auto = rig.auto(cfg_fast());
        rig.run_for(&mut auto, 300);
        fs::write(rig.source.join("gone.pdf"), &bytes).unwrap();
        assert!(rig.pump(&mut auto, 20, |r| r.book_at("gone.pdf").is_some()));
        fs::remove_file(rig.source.join("gone.pdf")).unwrap();
        assert!(rig.pump(&mut auto, 20, |r| {
            let s = r.saved();
            s.books.len() == 1 && s.books[0].locations.iter().all(|l| !l.available)
        }));
        let book = &rig.saved().books[0];
        assert_eq!((book.doc_id.as_deref(), book.pending_indexing), (Some("doc-gone"), false), "its searchable identity is kept");
        assert_eq!(book.locations.len(), 1);
        assert_eq!(fs::read_to_string(rig.target.join("documents.tsv")).unwrap(), documents, "the library's records are untouched");
        assert!(!rig.target.join("packs").exists());
    }

    #[test]
    fn pause_stops_automatic_checks_until_resumed() {
        let bytes = pdf_bytes("paused");
        let rig = Rig::new(&row("doc-pause", &bytes));
        let mut auto = rig.auto(cfg_fast());
        rig.run_for(&mut auto, 300);
        linked_api::request(&rig.svc, "POST", "example", &["root-a".into(), "pause".into()], b"").unwrap();
        fs::write(rig.source.join("later.pdf"), &bytes).unwrap();
        rig.run_for(&mut auto, 2_000); // several quiet and settle periods
        assert_eq!(auto.jobs_started, 0, "no automatic check while paused");
        assert!(rig.saved().books.is_empty());
        linked_api::request(&rig.svc, "POST", "example", &["root-a".into(), "resume".into()], b"").unwrap();
        assert!(rig.pump(&mut auto, 20, |r| r.book_at("later.pdf").is_some()), "checked once resumed");
        assert!(auto.jobs_started >= 1);
    }

    /// A notifier whose watch table is already full.
    struct Full;
    impl Notifier for Full {
        fn watch_root(&mut self, _: &str, _: &std::path::Path, _: &[PathBuf]) -> TreeOutcome {
            TreeOutcome::LimitReached { dirs: 8 }
        }
        fn forget_root(&mut self, _: &str) {}
        fn wait(&mut self, timeout_ms: i32) -> Vec<linked_watch::Change> {
            thread::sleep(Duration::from_millis(timeout_ms as u64));
            vec![]
        }
        fn watching(&self, _: &str) -> bool {
            false
        }
    }

    #[test]
    fn when_the_watch_limit_is_hit_the_folder_falls_back_to_the_rescan() {
        let bytes = pdf_bytes("limit");
        let rig = Rig::new(&row("doc-limit", &bytes));
        let cfg = AutoConfig { rescan_ms: 600, ..cfg_fast() };
        let mut auto = Auto::new(cfg, Box::new(Full));
        rig.run_for(&mut auto, 200);
        assert_eq!(auto.is_watched("example", "root-a"), Some(false), "no watches, but the folder is still tracked");
        fs::write(rig.source.join("found-by-rescan.pdf"), &bytes).unwrap();
        assert!(rig.pump(&mut auto, 20, |r| r.book_at("found-by-rescan.pdf").is_some_and(|b| b.doc_id.as_deref() == Some("doc-limit"))));
        let status = linked_api::request(&rig.svc, "GET", "example", &["checks".into()], b"").unwrap();
        assert_ne!(status["latest"]["state"], json!("failed"), "the folder did not fail");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn watches_are_rebuilt_at_server_start_and_missed_changes_are_caught_up() {
        let (one, two) = (pdf_bytes("first"), pdf_bytes("second"));
        let documents = format!("{}{}", row("doc-1", &one), row("doc-2", &two));
        let rig = Rig::new(&documents);
        let cfg = cfg_fast();
        let mut auto = rig.auto(cfg);
        rig.run_for(&mut auto, 300);
        fs::write(rig.source.join("one.pdf"), &one).unwrap();
        assert!(rig.pump(&mut auto, 20, |r| r.book_at("one.pdf").is_some()));
        drop(auto); // the server stops
        fs::write(rig.source.join("two.pdf"), &two).unwrap(); // ...a file arrives while it is down
        let mut restarted = rig.auto(cfg);
        rig.run_for(&mut restarted, 300);
        assert_eq!(restarted.is_watched("example", "root-a"), Some(true), "watches were made again from the saved registry");
        assert!(rig.pump(&mut restarted, 20, |r| r.book_at("two.pdf").is_some()), "the change made while down is caught up");
        // and the new watches work: a third file is seen by notification alone (the rescan is an hour away)
        let three = pdf_bytes("third");
        fs::write(rig.source.join("three.pdf"), &three).unwrap();
        assert!(rig.pump(&mut restarted, 20, |r| r.book_at("three.pdf").is_some()));
    }
}
