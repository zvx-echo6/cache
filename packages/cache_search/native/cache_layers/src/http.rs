//! HTTP to tile sources: an app User-Agent, retries with backoff, byte-range reads and a per-layer limit on
//! parallel requests (shared by the tile server and download jobs of the process).

use crate::error::{Error, Result};
use std::collections::HashMap;
use std::io::Read;
use std::sync::atomic::{AtomicI64, Ordering};
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
    let _permit = gate.map(|g| g.acquire());
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
