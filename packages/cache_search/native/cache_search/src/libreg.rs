//! A process-wide registry of library folders: who has one open, and whether an `update_library` job owns it.
//!
//! The C ABI starts jobs without a handle (`cs_job_start(kind, params)`), and a handle is used from one thread
//! only, so a job cannot reach into a handle. They meet here instead, keyed by the library's (canonical) path:
//!
//! - every open library keeps its shard in a [`ShardCell`], registered under its path;
//! - an update job marks the path `updating` (new opens and searches then refuse it), waits for opens that are
//!   still running, and takes the shard out of every registered cell (that is the "close"): a search that is
//!   using a shard finishes first, because the cell is a mutex;
//! - at the end the job opens the library once, read-only (this is also its check that the library opens), and
//!   hands that one shard (an `Arc`, shared) back to every cell it closed; a handle that finds its cell filled
//!   again just refreshes its numbers and does not open the library a second time. Only when there is nothing
//!   to hand back (the job failed or was cancelled after the close) does a handle reopen the library from disk;
//! - when the job ends, `generation` goes up and `updating` goes down; a handle that sees a newer generation than
//!   the one its library was opened at looks at its cell as above.
//!
//! A cell must stay alive for the handle to get the shard back, so a handle that drops its slot because of an
//! update keeps the cell (`OpeningLib::held`).
//!
//! An `index_library` job holds a [`BuildToken`] for as long as it runs; an update refuses to start while one
//! exists, and an index build refuses to start during an update.

use crate::error::{Error, ErrorCode, Result};
use crate::library::Shard;
use std::collections::{BTreeSet, HashMap};
use std::ops::Deref;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, MutexGuard, OnceLock, PoisonError, Weak};
use std::time::{Duration, Instant};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

/// An open library's shard. Taken out (`None`) while an update job owns the library. The shard is shared: after
/// an update every handle's cell holds the same opened shard.
pub struct ShardCell {
    shard: Mutex<Option<Arc<Shard>>>,
    /// The vector name the handle searches this library with (it decides which parts of the shard are warmed).
    vector: String,
}

/// The shard, held locked: the update job cannot close the library while a guard exists.
pub struct ShardGuard<'a>(MutexGuard<'a, Option<Arc<Shard>>>);

impl Deref for ShardGuard<'_> {
    type Target = Shard;
    fn deref(&self) -> &Shard {
        self.0.as_ref().expect("a ShardGuard exists only for an open shard")
    }
}

impl ShardCell {
    pub fn new(shard: Arc<Shard>, vector: String) -> ShardCell {
        ShardCell { shard: Mutex::new(Some(shard)), vector }
    }

    /// The shard, or `busy` when the library has been closed for an update.
    pub fn get(&self) -> Result<ShardGuard<'_>> {
        let g = lock(&self.shard);
        if g.is_none() {
            return Err(Error::new(ErrorCode::Busy, "the library is being updated"));
        }
        Ok(ShardGuard(g))
    }

    fn close(&self) {
        let old = lock(&self.shard).take();
        drop(old);
    }

    /// Put the shard an update opened into the (closed) cell.
    fn fill(&self, shard: Arc<Shard>) {
        *lock(&self.shard) = Some(shard);
    }

    pub fn is_open(&self) -> bool {
        lock(&self.shard).is_some()
    }
}

#[derive(Default)]
struct EntryState {
    updating: bool,
    /// `index_library` jobs running on this library.
    builders: usize,
    /// Background opens running on this library.
    opens: usize,
    /// Goes up every time an update job ends (successfully or not): the files may have changed.
    generation: u64,
    cells: Vec<Weak<ShardCell>>,
}

/// What the process knows about one library folder.
pub struct LibEntry {
    state: Mutex<EntryState>,
}

fn registry() -> &'static Mutex<HashMap<PathBuf, Arc<LibEntry>>> {
    static R: OnceLock<Mutex<HashMap<PathBuf, Arc<LibEntry>>>> = OnceLock::new();
    R.get_or_init(|| Mutex::new(HashMap::new()))
}

/// The entry for a library folder. The key is the canonical path when the folder exists, else the path as given.
pub fn entry_for(path: &Path) -> Arc<LibEntry> {
    let key = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let mut r = lock(registry());
    r.entry(key).or_insert_with(|| Arc::new(LibEntry { state: Mutex::new(EntryState::default()) })).clone()
}

/// Held by a background open; the update job waits until none are left.
pub struct OpenToken(Arc<LibEntry>);

impl Drop for OpenToken {
    fn drop(&mut self) {
        lock(&self.0.state).opens -= 1;
    }
}

/// Held by an `index_library` job for its whole run.
pub struct BuildToken(Arc<LibEntry>);

impl Drop for BuildToken {
    fn drop(&mut self) {
        lock(&self.0.state).builders -= 1;
    }
}

/// Held by an `update_library` job for its whole run. Dropping it ends the update: the library is no longer
/// `updating` and its generation goes up.
pub struct UpdateGuard(Arc<LibEntry>);

impl Drop for UpdateGuard {
    fn drop(&mut self) {
        let mut s = lock(&self.0.state);
        s.updating = false;
        s.generation += 1;
    }
}

/// How long an update waits for background opens of the same library to finish.
const OPEN_WAIT: Duration = Duration::from_secs(15 * 60);

impl LibEntry {
    pub fn updating(&self) -> bool {
        lock(&self.state).updating
    }

    pub fn generation(&self) -> u64 {
        lock(&self.state).generation
    }

    /// `None` while an update owns the library: nothing may open it then.
    pub fn begin_open(self: &Arc<Self>) -> Option<OpenToken> {
        let mut s = lock(&self.state);
        if s.updating {
            return None;
        }
        s.opens += 1;
        Some(OpenToken(self.clone()))
    }

    /// `busy` while an update owns the library.
    pub fn begin_build(self: &Arc<Self>) -> Result<BuildToken> {
        let mut s = lock(&self.state);
        if s.updating {
            return Err(Error::new(ErrorCode::Busy, "the library is being updated"));
        }
        s.builders += 1;
        Ok(BuildToken(self.clone()))
    }

    /// Mark the library as updating. `busy` if an update is already running or an index build is using it.
    pub fn begin_update(self: &Arc<Self>) -> Result<UpdateGuard> {
        let mut s = lock(&self.state);
        if s.updating {
            return Err(Error::new(ErrorCode::Busy, "the library is already being updated"));
        }
        if s.builders > 0 {
            return Err(Error::new(ErrorCode::Busy, "an index build is using the library"));
        }
        s.updating = true;
        Ok(UpdateGuard(self.clone()))
    }

    pub fn register(&self, cell: &Arc<ShardCell>) {
        let mut s = lock(&self.state);
        s.cells.retain(|w| w.strong_count() > 0);
        s.cells.push(Arc::downgrade(cell));
    }

    /// Whether a shard of this library is open in this process, or being opened.
    pub fn open_shards(&self) -> bool {
        let s = lock(&self.state);
        s.opens > 0 || s.cells.iter().filter_map(Weak::upgrade).any(|c| c.is_open())
    }

    /// The vector names the registered cells search with (the shard an update opens is warmed for all of them).
    pub fn vectors(&self) -> BTreeSet<String> {
        let s = lock(&self.state);
        s.cells.iter().filter_map(Weak::upgrade).map(|c| c.vector.clone()).collect()
    }

    /// Hand the shard an update opened to every registered cell that is closed. Returns how many got it.
    pub fn hand_back(&self, shard: &Arc<Shard>) -> usize {
        let cells: Vec<Arc<ShardCell>> = {
            let s = lock(&self.state);
            s.cells.iter().filter_map(Weak::upgrade).collect()
        };
        let mut n = 0;
        for c in cells {
            if !c.is_open() {
                c.fill(shard.clone());
                n += 1;
            }
        }
        n
    }

    /// Close the library for the update: wait for background opens to finish, then take the shard out of every
    /// registered cell (waiting for a search that is using it). Returns `false` when `cancelled` turned true
    /// first; nothing is closed in that case that a reopen would not restore.
    pub fn close_all(&self, cancelled: &dyn Fn() -> bool) -> Result<bool> {
        let start = Instant::now();
        loop {
            if lock(&self.state).opens == 0 {
                break;
            }
            if cancelled() {
                return Ok(false);
            }
            if start.elapsed() > OPEN_WAIT {
                return Err(Error::new(ErrorCode::Busy, "a background open of the library did not finish"));
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let cells: Vec<Arc<ShardCell>> = {
            let mut s = lock(&self.state);
            s.cells.retain(|w| w.strong_count() > 0);
            s.cells.iter().filter_map(Weak::upgrade).collect()
        };
        for c in cells {
            c.close();
        }
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};

    #[test]
    fn update_build_and_open_rules() {
        let e = entry_for(Path::new("/nonexistent/libreg-test-rules"));
        let b = e.begin_build().unwrap();
        assert_eq!(e.begin_update().err().unwrap().code, ErrorCode::Busy, "an index build blocks an update");
        drop(b);
        let gen = e.generation();
        let u = e.begin_update().unwrap();
        assert!(e.updating());
        assert_eq!(e.begin_update().err().unwrap().code, ErrorCode::Busy);
        assert_eq!(e.begin_build().err().unwrap().code, ErrorCode::Busy, "an update blocks an index build");
        assert!(e.begin_open().is_none(), "nothing opens the library during an update");
        drop(u);
        assert!(!e.updating());
        assert_eq!(e.generation(), gen + 1, "the generation goes up when an update ends");
        assert!(e.begin_open().is_some());
        // the same folder reached by another spelling is the same entry
        assert!(Arc::ptr_eq(&e, &entry_for(Path::new("/nonexistent/libreg-test-rules"))));
    }

    #[test]
    fn close_waits_for_opens_and_honours_cancel() {
        let e = entry_for(Path::new("/nonexistent/libreg-test-close"));
        let t = e.begin_open().unwrap();
        let cancel = AtomicBool::new(false);
        let e2 = e.clone();
        let th = std::thread::spawn(move || e2.close_all(&|| false));
        std::thread::sleep(Duration::from_millis(60));
        assert!(!th.is_finished(), "close_all waits for the running open");
        drop(t);
        assert!(th.join().unwrap().unwrap());
        // with an open still running, cancelling stops the wait
        let t = e.begin_open().unwrap();
        cancel.store(true, Ordering::SeqCst);
        assert!(!e.close_all(&|| cancel.load(Ordering::SeqCst)).unwrap());
        drop(t);
    }
}
