//! Cache's video connector: generic PeerTube instances through PeerTube's official REST API only (no scraping).
//!
//! What lives here: the list of instances the user added, browse and search (channels, videos, details), login through
//! the documented OAuth flow, offline downloads (resumable, one file per video plus thumbnail, captions and a manifest),
//! and link resolution for citations (a video link or uuid plus a time -> a local file if downloaded, else a stream).
//!
//! Tokens are never stored by this crate: the app keeps them in its secure storage and passes the access token in each
//! request (`"token"`); login and refresh return the tokens to the caller. Every call takes and returns JSON, in the shape
//! `cache_search.h` documents, so the C ABI, the CLI and `cs serve` are thin wrappers over the same functions.

pub mod api;
pub mod dl;
pub mod http;
pub mod model;
pub mod resolve;
pub mod store;

use serde::Deserialize;
use std::path::PathBuf;

/// An error with one of the core's stable codes: `bad_json`, `not_found`, `io`, `unsupported`, `no_space`, `damaged`,
/// `fetch_failed`, `bad_response`, `quota`, `auth_failed`, `otp_required`, `cancelled`, `internal`.
#[derive(Debug, Clone)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
    /// `(needed, available)` bytes, for `no_space` only.
    pub space: Option<(u64, u64)>,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(code: &'static str, m: impl Into<String>) -> Error {
        Error { code, message: m.into(), space: None }
    }
    pub fn bad_json(m: impl Into<String>) -> Error {
        Error::new("bad_json", m)
    }
    pub fn not_found(m: impl Into<String>) -> Error {
        Error::new("not_found", m)
    }
    pub fn io(m: impl Into<String>) -> Error {
        Error::new("io", m)
    }
    pub fn unsupported(m: impl Into<String>) -> Error {
        Error::new("unsupported", m)
    }
    pub fn fetch_failed(m: impl Into<String>) -> Error {
        Error::new("fetch_failed", m)
    }
    pub fn bad_response(m: impl Into<String>) -> Error {
        Error::new("bad_response", m)
    }
    pub fn auth_failed(m: impl Into<String>) -> Error {
        Error::new("auth_failed", m)
    }
    pub fn internal(m: impl Into<String>) -> Error {
        Error::new("internal", m)
    }
    pub fn no_space(m: impl Into<String>, needed: u64, available: u64) -> Error {
        Error { code: "no_space", message: m.into(), space: Some((needed, available)) }
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::bad_json(e.to_string())
    }
}

/// The `video` section of the `cs_open` config: `{"dir": ".../videos"}`. The folder holds `instances.json` and
/// `downloads/<instance>/<video uuid>/`.
#[derive(Debug, Clone, Deserialize)]
pub struct VideoCfg {
    pub dir: String,
}

/// The User-Agent of every request. Generic on purpose; it never names a person.
pub fn user_agent() -> String {
    format!("Cache/{}", env!("CARGO_PKG_VERSION"))
}

/// What a download job ended as.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Done,
    Cancelled,
}

/// The video connector on one folder. Cheap to clone; keeps no state in memory (everything is on disk).
#[derive(Debug, Clone)]
pub struct Video {
    pub(crate) dir: PathBuf,
}

impl Video {
    pub fn new(cfg: &VideoCfg) -> Video {
        Video { dir: PathBuf::from(&cfg.dir) }
    }
}

/// The system clock as ISO 8601 UTC, to the millisecond.
pub fn now_iso() -> String {
    // milliseconds, so two downloads in the same second still list newest first
    let d = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    chrono::DateTime::from_timestamp(d.as_secs() as i64, d.subsec_nanos()).map(|d| d.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string()).unwrap_or_default()
}
