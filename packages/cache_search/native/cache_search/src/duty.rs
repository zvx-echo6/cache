//! Pacing of background jobs ("duty"): how much of the time a job may work, whether it is paused, how many Tantivy writer threads it
//! may use, and a self back-off for a device that slows down under load (heat).
//!
//! Every job has one [`Throttle`]. The job's loops call [`Throttle::tick`] between items (files, articles, batches); it sleeps
//! `idle_ms` after each `work_ms` of work, blocks while the job is paused, and returns at once on cancel. Waiting never holds a
//! lock anyone else needs: the only lock is the throttle's own, and it is released while waiting (a condition variable wakes the
//! wait when the duty changes, the job is resumed or cancelled).
//!
//! The duty the app sets (`cs_job_start` "duty", `cs_job_set`) is the *app's duty*. The *effective* duty is the app's plus the
//! self back-off: the job keeps a baseline of its time per item (the first [`BASELINE_ITEMS`] items); when recent items take more
//! than twice the baseline for a sustained stretch (a sign of thermal throttling) it adds idle time on top of the app's
//! `idle_ms` (doubling it, up to [`MAX_EXTRA_IDLE_MS`]) and takes it back as the times recover. The back-off only ever makes the
//! job slower than the app's duty, never faster; every `cs_job_set` resets what it added; `"auto": false` switches it off.

use crate::error::{Error, Result};
use serde_json::{json, Value};
use std::sync::{Condvar, Mutex, MutexGuard};
use std::time::{Duration, Instant};

/// Default duty of the index jobs: work 200 ms, then idle 200 ms, one Tantivy writer thread. A caller that wants full speed passes
/// `"duty": {"work_ms": 0}`.
pub const DEFAULT_WORK_MS: u64 = 200;
pub const DEFAULT_IDLE_MS: u64 = 200;
pub const DEFAULT_THREADS: usize = 1;
/// Items that make the baseline of the time per item.
pub const BASELINE_ITEMS: u32 = 16;
/// Consecutive items (smoothed) over twice (or back under 1.5 times) the baseline that count as sustained.
pub const SUSTAIN_ITEMS: u32 = 16;
/// The most idle time the self back-off adds on top of the app's `idle_ms`.
pub const MAX_EXTRA_IDLE_MS: u64 = 4000;
/// How often a wait looks at cancel and pause even without being woken.
const SLICE: Duration = Duration::from_millis(50);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Duty {
    /// Milliseconds of work between idle periods; 0 means unthrottled (no idle).
    pub work_ms: u64,
    pub idle_ms: u64,
    /// Cap on Tantivy writer threads; `None` leaves the job's own choice.
    pub threads: Option<usize>,
}

impl Duty {
    /// The default of the index jobs.
    pub const GENTLE: Duty =
        Duty { work_ms: DEFAULT_WORK_MS, idle_ms: DEFAULT_IDLE_MS, threads: Some(DEFAULT_THREADS) };
    /// No throttling (the default of every other job kind).
    pub const FULL: Duty = Duty { work_ms: 0, idle_ms: 0, threads: None };

    fn to_json(self) -> Value {
        json!({"work_ms": self.work_ms, "idle_ms": self.idle_ms, "threads": self.threads})
    }

    /// `base` with the fields of a JSON object replaced.
    fn merged(base: Duty, v: &Value) -> Result<Duty> {
        let num = |k: &str| -> Result<Option<u64>> {
            match v.get(k) {
                None | Some(Value::Null) => Ok(None),
                Some(x) => {
                    x.as_u64().map(Some).ok_or_else(|| Error::bad_json(format!("duty.{k} must be a whole number")))
                }
            }
        };
        let mut d = base;
        if let Some(w) = num("work_ms")? {
            d.work_ms = w;
        }
        if let Some(i) = num("idle_ms")? {
            d.idle_ms = i;
        }
        match v.get("threads") {
            None => {}
            Some(Value::Null) => d.threads = None,
            Some(x) => match x.as_u64() {
                Some(n) if n >= 1 => d.threads = Some(n as usize),
                _ => return Err(Error::bad_json("duty.threads must be a whole number of at least 1")),
            },
        }
        Ok(d)
    }
}

/// The `"duty"` of a `cs_job_start` request, applied over `default`.
pub fn from_params(params_json: &str, default: Duty) -> Result<Duty> {
    let v: Value = serde_json::from_str(params_json)?;
    match v.get("duty") {
        None | Some(Value::Null) => Ok(default),
        Some(d) if d.is_object() => Duty::merged(default, d),
        Some(_) => Err(Error::bad_json("duty must be an object")),
    }
}

struct St {
    duty: Duty,
    paused: bool,
    auto: bool,
    /// Idle the self back-off adds to `duty.idle_ms`.
    extra_idle_ms: u64,
    /// When the current item started (the last tick, or the end of the last wait).
    last: Instant,
    /// Work since the last idle period.
    work_acc: Duration,
    base_n: u32,
    base_sum: f64,
    base: Option<f64>,
    ema: f64,
    slow: u32,
    fast: u32,
}

impl St {
    fn effective(&self) -> Duty {
        Duty { idle_ms: self.duty.idle_ms.saturating_add(self.extra_idle_ms), ..self.duty }
    }

    /// Learn from one item's time (seconds): the baseline first, then the back-off. Never touches `duty`, only `extra_idle_ms`.
    fn observe(&mut self, item: f64) {
        let Some(base) = self.base else {
            self.base_n += 1;
            self.base_sum += item;
            if self.base_n >= BASELINE_ITEMS {
                let b = (self.base_sum / self.base_n as f64).max(1e-6);
                self.base = Some(b);
                self.ema = b;
            }
            return;
        };
        self.ema = 0.8 * self.ema + 0.2 * item;
        if !self.auto || self.duty.work_ms == 0 {
            self.slow = 0;
            self.fast = 0;
            return;
        }
        if self.ema > 2.0 * base {
            self.fast = 0;
            self.slow += 1;
            if self.slow >= SUSTAIN_ITEMS {
                self.slow = 0;
                self.extra_idle_ms = if self.extra_idle_ms == 0 {
                    self.duty.idle_ms.max(50)
                } else {
                    self.extra_idle_ms.saturating_mul(2)
                }
                .min(MAX_EXTRA_IDLE_MS);
            }
        } else if self.ema < 1.5 * base {
            self.slow = 0;
            self.fast += 1;
            if self.fast >= SUSTAIN_ITEMS {
                self.fast = 0;
                self.extra_idle_ms = if self.extra_idle_ms <= 50 { 0 } else { self.extra_idle_ms / 2 };
            }
        } else {
            self.slow = 0;
            self.fast = 0;
        }
    }
}

/// The pacing of one job.
pub struct Throttle {
    st: Mutex<St>,
    cv: Condvar,
}

impl Throttle {
    pub fn new(duty: Duty) -> Throttle {
        Throttle {
            st: Mutex::new(St {
                duty,
                paused: false,
                auto: true,
                extra_idle_ms: 0,
                last: Instant::now(),
                work_acc: Duration::ZERO,
                base_n: 0,
                base_sum: 0.0,
                base: None,
                ema: 0.0,
                slow: 0,
                fast: 0,
            }),
            cv: Condvar::new(),
        }
    }

    fn lock(&self) -> MutexGuard<'_, St> {
        self.st.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Wake whoever waits (cancel, a changed duty, resume).
    pub fn wake(&self) {
        self.cv.notify_all();
    }

    /// The Tantivy writer threads this job may use (`None`: the job's own choice).
    pub fn threads(&self) -> Option<usize> {
        self.lock().duty.threads
    }

    /// Change the duty of a running job: `{"work_ms"?, "idle_ms"?, "threads"?, "paused"?, "auto"?}`. What is left out stays. Resets
    /// the idle the self back-off added, so the newest setting always wins. Returns the new state.
    pub fn set(&self, v: &Value) -> Result<Value> {
        if !v.is_object() {
            return Err(Error::bad_json("cs_job_set takes a JSON object"));
        }
        let mut g = self.lock();
        let duty = Duty::merged(g.duty, v)?;
        let paused = match v.get("paused") {
            None | Some(Value::Null) => g.paused,
            Some(x) => x.as_bool().ok_or_else(|| Error::bad_json("paused must be true or false"))?,
        };
        let auto = match v.get("auto") {
            None | Some(Value::Null) => g.auto,
            Some(x) => x.as_bool().ok_or_else(|| Error::bad_json("auto must be true or false"))?,
        };
        g.duty = duty;
        g.paused = paused;
        g.auto = auto;
        g.extra_idle_ms = 0;
        g.slow = 0;
        g.fast = 0;
        let out = Self::state_of(&g);
        drop(g);
        self.cv.notify_all();
        Ok(out)
    }

    fn state_of(g: &St) -> Value {
        json!({"duty": g.duty.to_json(), "effective": g.effective().to_json(), "auto": g.auto, "paused": g.paused})
    }

    /// `{"duty" (the app's), "effective" (with the back-off), "auto", "paused"}`.
    pub fn state_json(&self) -> Value {
        Self::state_of(&self.lock())
    }

    /// The effective duty now.
    pub fn effective(&self) -> Duty {
        self.lock().effective()
    }

    /// Between two items: learn the last item's time, then pause or idle as the duty says. Returns at once when `cancelled()`.
    /// Waits wake promptly on [`Throttle::wake`] and look at `cancelled` at least every 50 ms.
    pub fn tick(&self, cancelled: &dyn Fn() -> bool) {
        let mut g = self.lock();
        let now = Instant::now();
        let item = now.saturating_duration_since(g.last);
        g.observe(item.as_secs_f64());
        g.work_acc += item;
        let mut idle_from: Option<Instant> = None;
        loop {
            if cancelled() {
                break;
            }
            if g.paused {
                idle_from = None;
                g = self.cv.wait_timeout(g, SLICE).unwrap_or_else(|e| e.into_inner()).0;
                continue;
            }
            let eff = g.effective();
            if eff.work_ms == 0 {
                break;
            }
            if idle_from.is_none() {
                if g.work_acc < Duration::from_millis(eff.work_ms) {
                    break;
                }
                idle_from = Some(Instant::now());
            }
            let waited = idle_from.map(|t| t.elapsed()).unwrap_or_default();
            let want = Duration::from_millis(eff.idle_ms);
            if waited >= want {
                break;
            }
            g = self.cv.wait_timeout(g, (want - waited).min(SLICE)).unwrap_or_else(|e| e.into_inner()).0;
        }
        if idle_from.is_some() {
            g.work_acc = Duration::ZERO;
        }
        g.last = Instant::now();
    }
}

/// Lower the calling thread's OS priority (nice 10) where the platform allows: Linux and Android (`setpriority` on the thread id).
/// Other platforms: no change (a no-op).
pub fn lower_thread_priority() {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    unsafe {
        let tid = libc::syscall(libc::SYS_gettid) as libc::id_t;
        libc::setpriority(libc::PRIO_PROCESS, tid, 10);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn st(duty: Duty) -> St {
        let t = Throttle::new(duty);
        t.st.into_inner().unwrap()
    }

    fn warm(s: &mut St, secs: f64) {
        for _ in 0..BASELINE_ITEMS {
            s.observe(secs);
        }
        assert!(s.base.is_some());
    }

    #[test]
    fn back_off_adds_idle_when_items_stay_slow_and_gives_it_back() {
        let mut s = st(Duty { work_ms: 100, idle_ms: 100, threads: Some(1) });
        warm(&mut s, 0.01);
        assert_eq!(s.effective().idle_ms, 100);
        // sustained 3x the baseline: idle doubles (extra = idle), then doubles again
        for _ in 0..200 {
            s.observe(0.03);
        }
        let slow = s.effective().idle_ms;
        assert!(slow >= 200, "{slow}");
        assert!(s.extra_idle_ms <= MAX_EXTRA_IDLE_MS);
        for _ in 0..2000 {
            s.observe(0.03);
        }
        assert_eq!(s.extra_idle_ms, MAX_EXTRA_IDLE_MS, "capped");
        // recovered times: it comes back to the app's duty
        for _ in 0..2000 {
            s.observe(0.01);
        }
        assert_eq!(s.effective().idle_ms, 100);
    }

    #[test]
    fn back_off_is_never_faster_than_the_apps_duty() {
        let mut s = st(Duty { work_ms: 100, idle_ms: 100, threads: None });
        warm(&mut s, 0.01);
        for i in 0..5000u32 {
            // fast, slow and wild items alike
            s.observe(match i % 7 {
                0 => 0.0001,
                1 => 0.5,
                2 => 0.02,
                _ => 0.01,
            });
            let e = s.effective();
            assert!(e.idle_ms >= s.duty.idle_ms && e.work_ms == s.duty.work_ms && e.threads == s.duty.threads);
        }
        // off: nothing is added
        let mut s = st(Duty { work_ms: 100, idle_ms: 100, threads: None });
        s.auto = false;
        warm(&mut s, 0.01);
        for _ in 0..500 {
            s.observe(1.0);
        }
        assert_eq!(s.extra_idle_ms, 0);
        // unthrottled: nothing is added either
        let mut s = st(Duty::FULL);
        warm(&mut s, 0.01);
        for _ in 0..500 {
            s.observe(1.0);
        }
        assert_eq!(s.effective(), Duty::FULL);
    }

    #[test]
    fn every_set_resets_the_added_idle_and_the_app_wins() {
        let t = Throttle::new(Duty { work_ms: 100, idle_ms: 100, threads: Some(1) });
        {
            let mut g = t.lock();
            warm(&mut g, 0.01);
            for _ in 0..200 {
                g.observe(0.05);
            }
            assert!(g.extra_idle_ms > 0);
        }
        assert!(t.effective().idle_ms > 100);
        let v = t.set(&json!({"threads": 2})).unwrap();
        assert_eq!(v["effective"], v["duty"], "the added idle is gone: {v}");
        assert_eq!(t.effective(), Duty { work_ms: 100, idle_ms: 100, threads: Some(2) });
        // auto off: the back-off stays off however slow the items get
        t.set(&json!({"auto": false})).unwrap();
        {
            let mut g = t.lock();
            for _ in 0..500 {
                g.observe(1.0);
            }
        }
        assert_eq!(t.effective().idle_ms, 100);
        assert_eq!(t.set(&json!({"auto": true})).unwrap()["auto"], true);
    }

    #[test]
    fn duty_params_merge_over_the_default() {
        let d = from_params(r#"{"duty":{"work_ms":0}}"#, Duty::GENTLE).unwrap();
        assert_eq!((d.work_ms, d.idle_ms, d.threads), (0, DEFAULT_IDLE_MS, Some(1)));
        assert_eq!(from_params("{}", Duty::GENTLE).unwrap(), Duty::GENTLE);
        assert_eq!(
            from_params(r#"{"duty":{"work_ms":50,"idle_ms":10,"threads":2}}"#, Duty::FULL).unwrap().threads,
            Some(2)
        );
        assert!(from_params(r#"{"duty":{"threads":0}}"#, Duty::GENTLE).is_err());
        assert!(from_params(r#"{"duty":{"work_ms":-1}}"#, Duty::GENTLE).is_err());
        assert!(from_params(r#"{"duty":5}"#, Duty::GENTLE).is_err());
    }
}
