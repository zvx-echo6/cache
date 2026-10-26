//! HTTP to tile sources: an app User-Agent, retries with backoff, byte-range reads and a per-layer limit on
//! parallel requests (shared by the tile server and download jobs of the process).

use crate::error::{Error, Result};
use std::cell::Cell;
use std::collections::HashMap;
use std::io::Read;
use std::sync::atomic::{AtomicI64, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, OnceLock};
use std::time::{Duration, Instant};

pub fn user_agent() -> String {
    format!("Cache/{}", env!("CARGO_PKG_VERSION"))
}

/// Counting semaphore.
pub struct Gate {
    state: Mutex<(usize, usize)>, // (in flight, limit)
    cv: Condvar,
}

pub struct Permit(Arc<Gate>);

/// How the HTTP calls made on this thread behave. The default (`Normal`) is for downloads and catalogue refreshes:
/// retries with backoff and long timeouts. The tile server sets the other two on its own threads.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Policy {
    Normal,
    /// No network at all: a call that would need it fails at once with the `needs_upstream` error. Used by the tile
    /// server to answer from local storage without ever waiting behind an upstream fetch.
    LocalOnly,
    /// A map is waiting: one attempt, no retries, at most this long for the permit and for the request itself;
    /// failure to meet it is an `upstream_timeout` error (the tile server turns it into a clean miss).
    Interactive(Duration),
}

thread_local! {
    static POLICY: Cell<Policy> = const { Cell::new(Policy::Normal) };
}

pub fn policy() -> Policy {
    POLICY.with(|p| p.get())
}

/// Run `f` with `p` as this thread's policy (restored afterwards, also on a panic).
pub fn with_policy<T>(p: Policy, f: impl FnOnce() -> T) -> T {
    struct Restore(Policy);
    impl Drop for Restore {
        fn drop(&mut self) {
            POLICY.with(|c| c.set(self.0));
        }
    }
    let _r = Restore(POLICY.with(|c| c.replace(p)));
    f()
}

static UPSTREAM_TIMEOUT_MS: AtomicU64 = AtomicU64::new(10_000);

/// The longest the tile server waits for one upstream request (and for a free slot of its layer): 10 s.
pub fn upstream_timeout() -> Duration {
    Duration::from_millis(UPSTREAM_TIMEOUT_MS.load(Ordering::Relaxed))
}

pub fn set_upstream_timeout(d: Duration) {
    UPSTREAM_TIMEOUT_MS.store(d.as_millis().max(1) as u64, Ordering::Relaxed);
}

impl Gate {
    fn new(limit: usize) -> Arc<Gate> {
        Arc::new(Gate { state: Mutex::new((0, limit.max(1))), cv: Condvar::new() })
    }
    pub fn acquire(self: &Arc<Gate>) -> Permit {
        let mut g = self.state.lock().unwrap_or_else(|e| e.into_inner());
        while g.0 >= g.1 {
            g = self.cv.wait(g).unwrap_or_else(|e| e.into_inner());
        }
        g.0 += 1;
        Permit(self.clone())
    }
    /// Like `acquire`, but gives up after `wait` (None).
    pub fn acquire_timeout(self: &Arc<Gate>, wait: Duration) -> Option<Permit> {
        let deadline = Instant::now() + wait;
        let mut g = self.state.lock().unwrap_or_else(|e| e.into_inner());
        while g.0 >= g.1 {
            let left = deadline.checked_duration_since(Instant::now())?;
            g = self.cv.wait_timeout(g, left).unwrap_or_else(|e| e.into_inner()).0;
        }
        g.0 += 1;
        Some(Permit(self.clone()))
    }
}

impl Drop for Permit {
    fn drop(&mut self) {
        if let Ok(mut g) = self.0.state.lock() {
            g.0 = g.0.saturating_sub(1);
        }
        self.0.cv.notify_one();
    }
}

static GATES: OnceLock<Mutex<HashMap<String, Arc<Gate>>>> = OnceLock::new();

/// The process-wide gate of a layer; the limit is updated when a definition changes it.
pub fn gate_for(layer: &str, limit: usize) -> Arc<Gate> {
    let m = GATES.get_or_init(Default::default);
    let mut m = m.lock().unwrap_or_else(|e| e.into_inner());
    let g = m.entry(layer.to_string()).or_insert_with(|| Gate::new(limit));
    if let Ok(mut s) = g.state.lock() {
        s.1 = limit.max(1);
    }
    g.clone()
}

pub struct Response {
    pub status: u16,
    pub body: Vec<u8>,
}

/// Unix seconds until which connection-level failures are not retried (the device is probably offline).
static DOWN_UNTIL: AtomicI64 = AtomicI64::new(0);

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub fn network_seems_down() -> bool {
    DOWN_UNTIL.load(Ordering::Relaxed) > now()
}

pub fn mark_network_up() {
    DOWN_UNTIL.store(0, Ordering::Relaxed);
}

fn agent() -> &'static ureq::Agent {
    static A: OnceLock<ureq::Agent> = OnceLock::new();
    A.get_or_init(|| {
        ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(8))
            .timeout(Duration::from_secs(60))
            .user_agent(&user_agent())
            .max_idle_connections_per_host(8)
            .build()
    })
}

const MAX_BODY: u64 = 256 * 1024 * 1024;

/// GET `url`, or a byte range `[start, start+len)` of it. 404/403/204 come back as a `Response` with that status
/// (a missing tile is not an error). 429 and 5xx are retried with backoff (honouring Retry-After), as are
/// timeouts; a failure to connect is retried once and then makes later calls fail at once for 15 seconds.
pub fn get(url: &str, range: Option<(u64, u64)>, gate: Option<&Arc<Gate>>) -> Result<Response> {
    if !crate::def::url_ok(url) {
        return Err(Error::bad_json(format!("{url} is not an https address")));
    }
    if network_seems_down() {
        return Err(Error::fetch_failed("no connection"));
    }
    let pol = policy();
    let started = Instant::now();
    let _permit = match (gate, pol) {
        (_, Policy::LocalOnly) => return Err(Error::needs_upstream()),
        (Some(g), Policy::Interactive(t)) => Some(g.acquire_timeout(t).ok_or_else(|| Error::upstream_timeout(format!("timed out waiting for a free connection to {url}")))?),
        (Some(g), _) => Some(g.acquire()),
        (None, _) => None,
    };
    if let Policy::Interactive(t) = pol {
        return get_once(url, range, t.saturating_sub(started.elapsed()).max(Duration::from_millis(1)));
    }
    let mut delay = Duration::from_millis(400);
    let mut last = String::new();
    let mut connect_failures = 0;
    for attempt in 0..4 {
        if attempt > 0 {
            std::thread::sleep(delay);
            delay *= 2;
        }
        let mut req = agent().get(url);
        if let Some((s, l)) = range {
            req = req.set("Range", &format!("bytes={}-{}", s, s + l.max(1) - 1));
        }
        match req.call() {
            Ok(resp) => {
                mark_network_up();
                let status = resp.status();
                let mut body = Vec::new();
                resp.into_reader().take(MAX_BODY).read_to_end(&mut body).map_err(|e| Error::fetch_failed(format!("reading {url}: {e}")))?;
                if let Some((s, l)) = range {
                    if status == 200 && s > 0 {
                        // the server ignored the range and sent everything
                        let (s, e) = (s as usize, ((s + l) as usize).min(body.len()));
                        if s > body.len() {
                            return Err(Error::bad_response("range beyond the end of the file"));
                        }
                        body = body[s..e].to_vec();
                    } else if status == 200 && body.len() as u64 > l {
                        body.truncate(l as usize);
                    }
                }
                return Ok(Response { status: if status == 206 { 200 } else { status }, body });
            }
            Err(ureq::Error::Status(code, resp)) => {
                mark_network_up();
                if matches!(code, 404 | 403 | 410 | 204 | 416) {
                    return Ok(Response { status: code, body: Vec::new() });
                }
                last = format!("HTTP {code} from {url}");
                if code == 429 || code >= 500 {
                    if let Some(s) = resp.header("Retry-After").and_then(|v| v.trim().parse::<u64>().ok()) {
                        delay = Duration::from_secs(s.min(10));
                    }
                    continue;
                }
                return Err(Error::fetch_failed(last));
            }
            Err(ureq::Error::Transport(t)) => {
                last = format!("{:?}: {} ({url})", t.kind(), t.message().unwrap_or(""));
                if matches!(t.kind(), ureq::ErrorKind::Dns | ureq::ErrorKind::ConnectionFailed) {
                    connect_failures += 1;
                    if connect_failures >= 2 {
                        DOWN_UNTIL.store(now() + 15, Ordering::Relaxed);
                        break;
                    }
                }
            }
        }
    }
    Err(Error::fetch_failed(last))
}

fn finish_range(status: u16, mut body: Vec<u8>, range: Option<(u64, u64)>) -> Result<Response> {
    if let Some((s, l)) = range {
        if status == 200 && s > 0 {
            // the server ignored the range and sent everything
            let (s, e) = (s as usize, ((s + l) as usize).min(body.len()));
            if s > body.len() {
                return Err(Error::bad_response("range beyond the end of the file"));
            }
            body = body[s..e].to_vec();
        } else if status == 200 && body.len() as u64 > l {
            body.truncate(l as usize);
        }
    }
    Ok(Response { status: if status == 206 { 200 } else { status }, body })
}

/// One attempt with `timeout` for the whole request (connecting, sending and reading). No retries: a failure is
/// reported at once so the caller can answer and let the map ask again later.
fn get_once(url: &str, range: Option<(u64, u64)>, timeout: Duration) -> Result<Response> {
    let mut req = agent().get(url).timeout(timeout);
    if let Some((s, l)) = range {
        req = req.set("Range", &format!("bytes={}-{}", s, s + l.max(1) - 1));
    }
    // The wording differs between systems (Windows says "did not properly respond"), so look at the error kind.
    fn io_timeout(e: &std::io::Error) -> bool {
        matches!(e.kind(), std::io::ErrorKind::TimedOut | std::io::ErrorKind::WouldBlock) || matches!(e.raw_os_error(), Some(10060 | 10035 | 110 | 11))
    }
    fn chain_timeout(e: &(dyn std::error::Error + 'static)) -> bool {
        let mut cur = Some(e);
        while let Some(c) = cur {
            if c.downcast_ref::<std::io::Error>().map(io_timeout).unwrap_or(false) {
                return true;
            }
            cur = c.source();
        }
        false
    }
    let timed_out = |m: &str| m.to_lowercase().contains("timed out") || m.to_lowercase().contains("timeout");
    match req.call() {
        Ok(resp) => {
            mark_network_up();
            let status = resp.status();
            let mut body = Vec::new();
            if let Err(e) = resp.into_reader().take(MAX_BODY).read_to_end(&mut body) {
                let m = format!("reading {url}: {e}");
                return Err(if io_timeout(&e) || timed_out(&m) { Error::upstream_timeout(m) } else { Error::fetch_failed(m) });
            }
            finish_range(status, body, range)
        }
        Err(ureq::Error::Status(code, _)) => {
            mark_network_up();
            if matches!(code, 404 | 403 | 410 | 204 | 416) {
                return Ok(Response { status: code, body: Vec::new() });
            }
            Err(Error::fetch_failed(format!("HTTP {code} from {url}")))
        }
        Err(ureq::Error::Transport(t)) => {
            let m = format!("{:?}: {} ({url})", t.kind(), t.message().unwrap_or(&t.to_string()));
            Err(if chain_timeout(&t) || timed_out(&m) { Error::upstream_timeout(m) } else { Error::fetch_failed(m) })
        }
    }
}

pub fn get_ok(url: &str, gate: Option<&Arc<Gate>>) -> Result<Vec<u8>> {
    let r = get(url, None, gate)?;
    if r.status != 200 {
        return Err(Error::fetch_failed(format!("HTTP {} from {url}", r.status)));
    }
    Ok(r.body)
}

/// Time a closure (for the report).
pub fn timed<T>(f: impl FnOnce() -> T) -> (T, Duration) {
    let t = Instant::now();
    let v = f();
    (v, t.elapsed())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_full_gate_times_out_instead_of_waiting_for_ever() {
        let g = gate_for("test-gate-timeout", 1);
        let held = g.acquire();
        let t = Instant::now();
        assert!(g.acquire_timeout(Duration::from_millis(150)).is_none());
        assert!(t.elapsed() >= Duration::from_millis(140) && t.elapsed() < Duration::from_secs(2));
        drop(held);
        assert!(g.acquire_timeout(Duration::from_millis(150)).is_some());
    }

    #[test]
    fn local_only_never_touches_the_network() {
        let r = with_policy(Policy::LocalOnly, || get("http://127.0.0.1:1/x", None, None));
        assert_eq!(r.err().map(|e| e.code), Some("needs_upstream"));
        assert_eq!(policy(), Policy::Normal, "restored");
    }
}
