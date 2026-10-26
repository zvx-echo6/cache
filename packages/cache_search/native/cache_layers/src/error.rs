//! Errors with the core's stable codes (`bad_json`, `not_found`, `io`, `not_configured`, `fetch_failed`,
//! `bad_response`, `busy`, `unsupported`, `no_space`, `cancelled`, `limit_exceeded`, `offline`, `upstream_timeout`, `internal`).

#[derive(Debug, Clone)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
    /// `(needed, available)` bytes for `no_space`.
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
    pub fn internal(m: impl Into<String>) -> Error {
        Error::new("internal", m)
    }
    pub fn fetch_failed(m: impl Into<String>) -> Error {
        Error::new("fetch_failed", m)
    }
    pub fn bad_response(m: impl Into<String>) -> Error {
        Error::new("bad_response", m)
    }
    pub fn unsupported(m: impl Into<String>) -> Error {
        Error::new("unsupported", m)
    }
    pub fn busy(m: impl Into<String>) -> Error {
        Error::new("busy", m)
    }
    /// An upstream request or a wait for a free connection of its layer ran out of time (the tile server answers a miss).
    pub fn upstream_timeout(m: impl Into<String>) -> Error {
        Error::new("upstream_timeout", m)
    }
    /// Raised under `http::Policy::LocalOnly` where the answer needs the network.
    pub fn needs_upstream() -> Error {
        Error::new("needs_upstream", "needs the network")
    }
    pub fn limit(m: impl Into<String>) -> Error {
        Error::new("limit_exceeded", m)
    }
    /// The layer or action needs a connection and there is none (or the app said it is offline).
    pub fn offline(m: impl Into<String>) -> Error {
        Error::new("offline", m)
    }
    pub fn no_space(m: impl Into<String>, needed: u64, available: u64) -> Error {
        Error { code: "no_space", message: m.into(), space: Some((needed, available)) }
    }
    pub fn http_status(&self) -> u16 {
        match self.code {
            "bad_json" => 400,
            "not_found" => 404,
            "offline" => 503,
            "fetch_failed" | "bad_response" => 502,
            "upstream_timeout" => 504,
            _ => 500,
        }
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Self {
        Error::io(format!("sqlite: {e}"))
    }
}

impl From<serde_json::Error> for Error {
    fn from(e: serde_json::Error) -> Self {
        Error::bad_json(e.to_string())
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Error::io(e.to_string())
    }
}

pub fn io_at(what: &str, p: &std::path::Path, e: std::io::Error) -> Error {
    Error::io(format!("{what} {}: {e}", p.display()))
}

/// Bytes available to the caller on the volume holding `path`.
#[cfg(unix)]
pub fn available_bytes(path: &std::path::Path) -> Result<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|_| Error::bad_json("path contains a NUL byte"))?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: valid C string and writable statvfs.
    if unsafe { libc::statvfs(c.as_ptr(), &mut st) } != 0 {
        return Err(io_at("reading the free space of", path, std::io::Error::last_os_error()));
    }
    Ok((st.f_bavail as u64).saturating_mul(st.f_frsize as u64))
}

#[cfg(windows)]
pub fn available_bytes(path: &std::path::Path) -> Result<u64> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
    wide.push(0);
    let mut free: u64 = 0;
    // SAFETY: valid NUL-terminated UTF-16 path and writable u64.
    let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut free, std::ptr::null_mut(), std::ptr::null_mut()) };
    if ok == 0 {
        return Err(io_at("reading the free space of", path, std::io::Error::last_os_error()));
    }
    Ok(free)
}

#[cfg(not(any(unix, windows)))]
pub fn available_bytes(path: &std::path::Path) -> Result<u64> {
    Err(Error::io(format!("free-space check unsupported for {}", path.display())))
}
