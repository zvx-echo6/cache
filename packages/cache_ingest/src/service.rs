//! The four calls as JSON in, JSON out: start, step, ocr, cancel. A [`Service`] holds the jobs of a process; the core keeps one and
//! the tests make their own with fakes.
//!
//! The service also frees the embedding model when no job needs it (it is large: on a phone a second copy beside the app's own
//! pushes the device into swap): when a job ends (done, failed or cancelled) and no other live job uses the same embedder, and,
//! from one small timer thread, when every job using it has had no call for its `opts.embed_idle_ms`. The next embed loads it
//! again.

use crate::engine::{Embedder, EnvProvider};
use crate::error::{Error, Result};
use crate::job::Job;
use crate::params::Params;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, PoisonError, Weak};
use std::time::{Duration, Instant};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

struct Slot {
    /// The job folder, absolute: one job per folder.
    key: PathBuf,
    cancel: AtomicBool,
    job: Mutex<Option<Job>>,
    /// The job's embedder (shared with the other jobs on the same engines).
    embedder: Arc<dyn Embedder>,
    /// `opts.embed_idle_ms`.
    idle: Duration,
    /// Whether a call is running, when the last one ended, or that nothing is to be freed for the job (it is done or failed, or the
    /// embedder was released for idleness and nothing has been asked of the job since).
    use_: Mutex<Use>,
}

#[derive(Clone, Copy, PartialEq)]
enum Use {
    /// A call is running.
    Busy,
    /// The last call ended then.
    Since(Instant),
    /// Nothing to free for this job.
    Idle,
}

fn same(a: &Arc<dyn Embedder>, b: &Arc<dyn Embedder>) -> bool {
    std::ptr::addr_eq(Arc::as_ptr(a), Arc::as_ptr(b))
}

type Jobs = Mutex<HashMap<u64, Arc<Slot>>>;

/// The idle timer's wake-up: `(stop, kick)`, kick meaning a deadline may have moved closer.
#[derive(Default)]
struct Timer {
    state: Mutex<(bool, bool)>,
    cv: Condvar,
}

pub struct Service {
    provider: EnvProvider,
    jobs: Arc<Jobs>,
    /// The job folders in use, taken before a job starts and released when it ends.
    dirs: Mutex<HashSet<PathBuf>>,
    next: AtomicU64,
    timer: Arc<Timer>,
    timer_started: AtomicBool,
}

impl Drop for Service {
    fn drop(&mut self) {
        let mut g = lock(&self.timer.state);
        g.0 = true;
        self.timer.cv.notify_all();
    }
}

/// Releases each embedder whose every job has been idle for its timeout. Returns how long until the next one is due.
fn reap(jobs: &Jobs, now: Instant) -> Option<Duration> {
    let slots: Vec<Arc<Slot>> = lock(jobs).values().cloned().collect();
    let mut next: Option<Duration> = None;
    let mut done: Vec<usize> = Vec::new();
    for (i, s) in slots.iter().enumerate() {
        if done.contains(&i) {
            continue;
        }
        // every job on this embedder: it is freed only when none of them is busy or still within its timeout
        let group: Vec<usize> = (0..slots.len()).filter(|&j| same(&slots[j].embedder, &s.embedder)).collect();
        done.extend(&group);
        let mut armed = Vec::new();
        let mut wait: Option<Duration> = None;
        for &j in &group {
            match *lock(&slots[j].use_) {
                Use::Idle => {}
                Use::Busy => wait = Some(wait.map_or(slots[j].idle, |w: Duration| w.max(slots[j].idle))),
                Use::Since(t) => {
                    armed.push(j);
                    let left = (t + slots[j].idle).saturating_duration_since(now);
                    if !left.is_zero() {
                        wait = Some(wait.map_or(left, |w: Duration| w.max(left)));
                    }
                }
            }
        }
        match wait {
            Some(w) => next = Some(next.map_or(w, |n: Duration| n.min(w))),
            None if !armed.is_empty() => {
                s.embedder.release();
                for j in armed {
                    let mut u = lock(&slots[j].use_);
                    // a call that began meanwhile keeps its state; it reloads the model if it needs it
                    if matches!(*u, Use::Since(_)) {
                        *u = Use::Idle;
                    }
                }
            }
            None => {}
        }
    }
    next
}

fn timer_loop(jobs: Weak<Jobs>, timer: Arc<Timer>) {
    loop {
        let wait = match jobs.upgrade() {
            Some(j) => reap(&j, Instant::now()),
            None => return,
        };
        let mut g = lock(&timer.state);
        if g.0 {
            return;
        }
        if !g.1 {
            // nothing armed: wait for a call to kick it (the hour is only a safety net)
            let d = wait.unwrap_or(Duration::from_secs(3600));
            g = timer.cv.wait_timeout_while(g, d, |st| !st.0 && !st.1).unwrap_or_else(PoisonError::into_inner).0;
            if g.0 {
                return;
            }
        }
        g.1 = false;
    }
}

/// Marks a call to a job: `Busy` while it runs, and after it the time it ended (or `Idle` when the job no longer embeds).
struct CallGuard<'a> {
    svc: &'a Service,
    slot: Arc<Slot>,
    ended: bool,
}

impl Drop for CallGuard<'_> {
    fn drop(&mut self) {
        *lock(&self.slot.use_) = if self.ended { Use::Idle } else { Use::Since(Instant::now()) };
        self.svc.kick();
    }
}

fn parse(json: &str) -> Result<Value> {
    serde_json::from_str(json).map_err(|e| Error::bad_json(format!("the request is not JSON: {e}")))
}

fn job_id(v: &Value) -> Result<u64> {
    v.get("job").and_then(Value::as_u64).ok_or_else(|| Error::bad_json("\"job\" is missing"))
}

impl Service {
    pub fn new(provider: EnvProvider) -> Service {
        Service {
            provider,
            jobs: Arc::new(Mutex::new(HashMap::new())),
            dirs: Mutex::new(HashSet::new()),
            next: AtomicU64::new(1),
            timer: Arc::new(Timer::default()),
            timer_started: AtomicBool::new(false),
        }
    }

    /// Wakes the idle timer (starting it the first time).
    fn kick(&self) {
        if !self.timer_started.swap(true, Ordering::SeqCst) {
            let (jobs, timer) = (Arc::downgrade(&self.jobs), self.timer.clone());
            let spawned = std::thread::Builder::new().name("cache-ingest-idle".to_string()).spawn(move || timer_loop(jobs, timer));
            if spawned.is_err() {
                // no timer: the model is still freed when the jobs end
                self.timer_started.store(false, Ordering::SeqCst);
            }
        }
        let mut g = lock(&self.timer.state);
        g.1 = true;
        self.timer.cv.notify_all();
    }

    fn begin_call(&self, slot: &Arc<Slot>) -> CallGuard<'_> {
        *lock(&slot.use_) = Use::Busy;
        CallGuard { svc: self, slot: slot.clone(), ended: false }
    }

    /// The job has ended (done, failed or cancelled): its embedder is released unless another live job uses it.
    fn release_after(&self, slot: &Slot) {
        *lock(&slot.use_) = Use::Idle;
        let others = lock(&self.jobs).values().any(|o| !std::ptr::eq(&**o, slot) && same(&o.embedder, &slot.embedder) && *lock(&o.use_) != Use::Idle);
        if !others {
            slot.embedder.release();
        }
    }

    fn slot(&self, id: u64) -> Result<Arc<Slot>> {
        lock(&self.jobs).get(&id).cloned().ok_or_else(|| Error::not_found(format!("no ingest job {id} (it was never started, was cancelled, or is already done)")))
    }

    fn forget(&self, id: u64) {
        if let Some(slot) = lock(&self.jobs).remove(&id) {
            lock(&self.dirs).remove(&slot.key);
        }
    }

    /// `cs_ingest_start`.
    pub fn start(&self, params_json: &str) -> Result<String> {
        let v = parse(params_json)?;
        let params = Params::parse(&v)?;
        let key = std::path::absolute(&params.job_dir).unwrap_or_else(|_| params.job_dir.clone());
        // one job per job_dir: the folder is taken here, before anything else, and released when the job ends or fails to start
        if !lock(&self.dirs).insert(key.clone()) {
            return Err(Error::busy("a job already uses this job_dir"));
        }
        let idle = Duration::from_millis(params.opts.embed_idle_ms);
        let started = (|| {
            let env = (self.provider)(v.get("engines").unwrap_or(&Value::Null))?;
            let embedder = env.embedder.clone();
            Job::start(params, env).map(|(j, r)| (j, r, embedder))
        })();
        let (job, resumed, embedder) = match started {
            Ok(x) => x,
            Err(e) => {
                lock(&self.dirs).remove(&key);
                return Err(e);
            }
        };
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        let out = json!({"job": id, "resumed": resumed, "copy": job.copy(), "pages": job.page_count()});
        let slot = Arc::new(Slot { key, cancel: AtomicBool::new(false), job: Mutex::new(Some(job)), embedder, idle, use_: Mutex::new(Use::Since(Instant::now())) });
        lock(&self.jobs).insert(id, slot);
        self.kick();
        Ok(out.to_string())
    }

    /// `cs_ingest_step`.
    pub fn step(&self, params_json: &str) -> Result<String> {
        let v = parse(params_json)?;
        let id = job_id(&v)?;
        let budget = match v.get("budget_ms") {
            None | Some(Value::Null) => 500,
            Some(b) => b.as_u64().ok_or_else(|| Error::bad_json("budget_ms must be a whole number"))?,
        };
        let slot = self.slot(id)?;
        let mut call = self.begin_call(&slot);
        let mut g = lock(&slot.job);
        let Some(job) = g.as_mut() else { return Err(Error::not_found(format!("no ingest job {id} (it was never started, was cancelled, or is already done)"))) };
        let status = job.step(budget, &slot.cancel)?;
        if status["state"] == "done" {
            job.remove_dir();
            *g = None;
            drop(g);
            self.forget(id);
            call.ended = true;
            self.release_after(&slot);
        } else if status["state"] == "failed" {
            drop(g);
            call.ended = true;
            self.release_after(&slot);
        }
        Ok(status.to_string())
    }

    /// `cs_ingest_ocr`.
    pub fn ocr(&self, params_json: &str) -> Result<String> {
        let v = parse(params_json)?;
        let id = job_id(&v)?;
        let engine = v.get("engine").and_then(Value::as_str).unwrap_or("").to_string();
        let version = v.get("version").and_then(Value::as_str).unwrap_or("").to_string();
        let list = v.get("pages").and_then(Value::as_array).ok_or_else(|| Error::bad_json("\"pages\" is missing"))?;
        let mut pages = Vec::with_capacity(list.len());
        for p in list {
            let page = p.get("page").and_then(Value::as_u64).ok_or_else(|| Error::bad_json("each page needs a \"page\" number"))? as usize;
            let text = match p.get("text") {
                Some(Value::String(t)) => t.clone(),
                _ => return Err(Error::bad_json("each page needs \"text\" (empty for a blank page)")),
            };
            let conf = match p.get("confidence") {
                None | Some(Value::Null) => None,
                Some(c) => Some(c.as_f64().ok_or_else(|| Error::bad_json("confidence must be a number"))? as f32),
            };
            pages.push((page, text, conf));
        }
        let slot = self.slot(id)?;
        let _call = self.begin_call(&slot);
        let mut g = lock(&slot.job);
        let Some(job) = g.as_mut() else { return Err(Error::not_found(format!("no ingest job {id} (it was never started, was cancelled, or is already done)"))) };
        Ok(job.accept_ocr(&engine, &version, &pages)?.to_string())
    }

    /// `cs_ingest_cancel`. `{"cancelled":true}` only when nothing was added to the library. A cancel that lost the race to the
    /// end of the write gets `{"cancelled":false,"done":true}`, and a job whose book is already in the library but that failed
    /// afterwards (the Bookshelves events) is kept, with `{"cancelled":false,"done":false,"committed":true}`: step it again.
    pub fn cancel(&self, params_json: &str) -> Result<String> {
        let v = parse(params_json)?;
        let id = job_id(&v)?;
        let slot = self.slot(id)?;
        // a step in progress stops at its next unit; the job lock is free then
        slot.cancel.store(true, Ordering::SeqCst);
        let mut g = lock(&slot.job);
        let Some(job) = g.as_ref() else {
            return Ok(json!({"cancelled": false, "done": true}).to_string());
        };
        if job.committed() {
            slot.cancel.store(false, Ordering::SeqCst);
            return Ok(json!({"cancelled": false, "done": false, "committed": true}).to_string());
        }
        if let Some(job) = g.take() {
            job.remove_dir();
        }
        drop(g);
        self.forget(id);
        self.release_after(&slot);
        Ok(json!({"cancelled": true}).to_string())
    }
}
