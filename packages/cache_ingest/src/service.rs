//! The four calls as JSON in, JSON out: start, step, ocr, cancel. A [`Service`] holds the jobs of a process; the core keeps one and
//! the tests make their own with fakes.

use crate::engine::EnvProvider;
use crate::error::{Error, Result};
use crate::job::Job;
use crate::params::Params;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(PoisonError::into_inner)
}

struct Slot {
    /// The job folder, absolute: one job per folder.
    key: PathBuf,
    cancel: AtomicBool,
    job: Mutex<Option<Job>>,
}

pub struct Service {
    provider: EnvProvider,
    jobs: Mutex<HashMap<u64, Arc<Slot>>>,
    /// The job folders in use, taken before a job starts and released when it ends.
    dirs: Mutex<HashSet<PathBuf>>,
    next: AtomicU64,
}

fn parse(json: &str) -> Result<Value> {
    serde_json::from_str(json).map_err(|e| Error::bad_json(format!("the request is not JSON: {e}")))
}

fn job_id(v: &Value) -> Result<u64> {
    v.get("job").and_then(Value::as_u64).ok_or_else(|| Error::bad_json("\"job\" is missing"))
}

impl Service {
    pub fn new(provider: EnvProvider) -> Service {
        Service { provider, jobs: Mutex::new(HashMap::new()), dirs: Mutex::new(HashSet::new()), next: AtomicU64::new(1) }
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
        let started = (|| {
            let env = (self.provider)(v.get("engines").unwrap_or(&Value::Null))?;
            Job::start(params, env)
        })();
        let (job, resumed) = match started {
            Ok(x) => x,
            Err(e) => {
                lock(&self.dirs).remove(&key);
                return Err(e);
            }
        };
        let id = self.next.fetch_add(1, Ordering::SeqCst);
        let out = json!({"job": id, "resumed": resumed, "copy": job.copy(), "pages": job.page_count()});
        lock(&self.jobs).insert(id, Arc::new(Slot { key, cancel: AtomicBool::new(false), job: Mutex::new(Some(job)) }));
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
        let mut g = lock(&slot.job);
        let Some(job) = g.as_mut() else { return Err(Error::not_found(format!("no ingest job {id} (it was never started, was cancelled, or is already done)"))) };
        let status = job.step(budget, &slot.cancel)?;
        if status["state"] == "done" {
            job.remove_dir();
            *g = None;
            drop(g);
            self.forget(id);
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
        Ok(json!({"cancelled": true}).to_string())
    }
}
