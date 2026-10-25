//! Long jobs: `index_zim` and `index_library` run on their own threads and are polled.

use crate::error::{Error, Result};
use crate::index::{self, BuildParams, Lock, Outcome};
use crate::libindex::{self, LibBuildParams};
use crate::library::LibrarySettings;
use crate::zimsrc::ZimSource;
use serde::Deserialize;
use serde_json::{json, Value};
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
enum State {
    Running,
    Done,
    Cancelled,
    Failed,
}

impl State {
    fn as_str(self) -> &'static str {
        match self {
            State::Running => "running",
            State::Done => "done",
            State::Cancelled => "cancelled",
            State::Failed => "failed",
        }
    }
}

struct Shared {
    cancel: AtomicBool,
    done: AtomicU64,
    total: AtomicU64,
    state: Mutex<(State, Option<Error>)>,
}

impl Shared {
    fn set_progress(&self, d: u64, t: u64) {
        self.done.store(d, Ordering::SeqCst);
        self.total.store(t, Ordering::SeqCst);
    }
}

pub struct Job {
    shared: Arc<Shared>,
    thread: Option<JoinHandle<()>>,
}

#[derive(Deserialize)]
struct IndexZimParams {
    zim_path: String,
    index_dir: String,
    #[serde(default = "default_heap")]
    heap_mb: usize,
    /// Not in the header: articles per checkpoint (default 2000). Tests use a small value.
    #[serde(default = "default_checkpoint")]
    checkpoint_articles: usize,
}

#[derive(Deserialize)]
struct IndexLibraryParams {
    library_path: String,
    index_dir: String,
    #[serde(default = "default_heap")]
    heap_mb: usize,
    /// The library's settings object, as in `cs_open`; guessed from the payload when absent. It must be the
    /// same settings the handle opens the library with (the index is tied to the settings' `library_id`).
    #[serde(default)]
    settings: Option<Value>,
    /// Not in the header: documents per checkpoint (default 200,000). Tests use a small value.
    #[serde(default = "default_lib_checkpoint")]
    checkpoint_docs: usize,
}

fn default_lib_checkpoint() -> usize {
    libindex::DEFAULT_CHECKPOINT_DOCS
}

fn default_heap() -> usize {
    200
}
fn default_checkpoint() -> usize {
    index::DEFAULT_CHECKPOINT
}

impl Job {
    /// Start a job. Parameter errors, an unreadable ZIM and a busy `index_dir` are reported here (the call
    /// returns an error and no job exists); errors during the build make the job `failed`.
    pub fn start(kind: &str, params_json: &str) -> Result<Job> {
        match kind {
            "index_zim" => Self::start_index_zim(params_json),
            "index_library" => Self::start_index_library(params_json),
            "index_pack" => Err(Error::unsupported("index_pack is not supported yet")),
            other => Err(Error::bad_json(format!("unknown job kind {other:?}"))),
        }
    }

    fn start_index_zim(params_json: &str) -> Result<Job> {
        let p: IndexZimParams = serde_json::from_str(params_json)?;
        if p.zim_path.is_empty() || p.index_dir.is_empty() {
            return Err(Error::bad_json("zim_path and index_dir must not be empty"));
        }
        let zim = ZimSource::open(std::path::Path::new(&p.zim_path))?;
        let dir = PathBuf::from(&p.index_dir);
        let lock = Lock::acquire(&dir)?;
        let total = zim.entry_count();
        let heap_mb = p.heap_mb;
        let checkpoint = p.checkpoint_articles;
        Self::spawn("cs-index-zim", lock, total, move |sh| {
            index::build_zim_index(
                &BuildParams { zim: &zim, index_dir: &dir, heap_mb, checkpoint_articles: checkpoint },
                &|d, t| sh.set_progress(d, t),
                &|| sh.cancel.load(Ordering::SeqCst),
            )
        })
    }

    fn start_index_library(params_json: &str) -> Result<Job> {
        let p: IndexLibraryParams = serde_json::from_str(params_json)?;
        if p.library_path.is_empty() || p.index_dir.is_empty() {
            return Err(Error::bad_json("library_path and index_dir must not be empty"));
        }
        // a bad settings object and a missing folder are reported here; opening the (possibly huge) shard
        // happens on the job's thread
        if let Some(s) = &p.settings {
            LibrarySettings::parse(s)?;
        }
        let lib_path = PathBuf::from(&p.library_path);
        if !lib_path.is_dir() {
            return Err(Error::not_found(format!("library folder {} not found", lib_path.display())));
        }
        let dir = PathBuf::from(&p.index_dir);
        let lock = Lock::acquire(&dir)?;
        let (heap_mb, checkpoint, settings) = (p.heap_mb, p.checkpoint_docs, p.settings);
        Self::spawn("cs-index-library", lock, 0, move |sh| {
            libindex::build_library_index(
                &LibBuildParams {
                    library_path: &lib_path,
                    settings: settings.as_ref(),
                    index_dir: &dir,
                    heap_mb,
                    checkpoint_docs: checkpoint,
                },
                &|d, t| sh.set_progress(d, t),
                &|| sh.cancel.load(Ordering::SeqCst),
            )
        })
    }

    /// Run `work` on a new thread holding the build `lock`; the job's state follows its result.
    fn spawn(
        name: &str,
        lock: Lock,
        total: u64,
        work: impl FnOnce(&Shared) -> Result<Outcome> + Send + 'static,
    ) -> Result<Job> {
        let shared = Arc::new(Shared {
            cancel: AtomicBool::new(false),
            done: AtomicU64::new(0),
            total: AtomicU64::new(total),
            state: Mutex::new((State::Running, None)),
        });
        let sh = shared.clone();
        let th = std::thread::Builder::new()
            .name(name.into())
            .spawn(move || {
                let lock = lock;
                let r = catch_unwind(AssertUnwindSafe(|| work(&sh)));
                let st = match r {
                    Ok(Ok(Outcome::Done)) => (State::Done, None),
                    Ok(Ok(Outcome::Cancelled)) => (State::Cancelled, None),
                    Ok(Err(e)) => (State::Failed, Some(e)),
                    Err(p) => {
                        let msg = p
                            .downcast_ref::<&str>()
                            .map(|s| s.to_string())
                            .or_else(|| p.downcast_ref::<String>().cloned())
                            .unwrap_or_else(|| "panic".into());
                        (State::Failed, Some(Error::internal(format!("panic: {msg}"))))
                    }
                };
                // release the build lock before the state flips, so a poller that sees a finished job also
                // sees the source as no longer building
                drop(lock);
                if let Ok(mut g) = sh.state.lock() {
                    *g = st;
                }
            })
            .map_err(|e| Error::internal(format!("cannot start thread: {e}")))?;
        Ok(Job { shared, thread: Some(th) })
    }

    pub fn progress_json(&self) -> String {
        let (st, err) = self.shared.state.lock().map(|g| g.clone()).unwrap_or((State::Failed, Some(Error::internal("poisoned"))));
        let err_v = match &err {
            Some(e) => json!({"code": e.code.as_str(), "message": e.message}),
            None => serde_json::Value::Null,
        };
        json!({
            "state": st.as_str(),
            "done": self.shared.done.load(Ordering::SeqCst),
            "total": self.shared.total.load(Ordering::SeqCst),
            "error": err_v,
        })
        .to_string()
    }

    pub fn cancel(&self) {
        self.shared.cancel.store(true, Ordering::SeqCst);
    }
}

impl Drop for Job {
    /// Freeing a running job cancels it and waits for its next checkpoint.
    fn drop(&mut self) {
        self.shared.cancel.store(true, Ordering::SeqCst);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

