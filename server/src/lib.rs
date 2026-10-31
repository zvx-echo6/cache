//! Cache Server: the browser app and the core's search and read calls behind one port and one password.
//!
//! The core is the same `cache_search` library the `cs` command uses, reached through `cache_search_cli::engine::Core`.
//! Everything else here is the web side: sign-in (`auth`), the routes (`http`), the files of the browser app (`webfiles`),
//! the certificate (`tls`) and the core's open config (`config`).

pub mod auth;
pub mod config;
pub mod http;
pub mod tls;
pub mod webfiles;

use std::io::Write;
use std::path::Path;

/// Write `data` to `path` so that only the owner can read it (mode 0600 on Unix). The file is written beside the target
/// and renamed over it, so a crash never leaves half a file.
pub fn write_private(path: &Path, data: &[u8]) -> std::io::Result<()> {
    let tmp = path.with_extension("tmp");
    let mut opts = std::fs::OpenOptions::new();
    opts.write(true).create(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        opts.mode(0o600);
    }
    {
        let mut f = opts.open(&tmp)?;
        f.write_all(data)?;
        f.sync_all()?;
    }
    std::fs::rename(&tmp, path)
}

/// A scratch folder for tests, removed when dropped.
#[cfg(test)]
pub(crate) struct TempDir(pub std::path::PathBuf);

#[cfg(test)]
impl TempDir {
    pub fn new(tag: &str) -> TempDir {
        use std::sync::atomic::{AtomicU32, Ordering};
        static N: AtomicU32 = AtomicU32::new(0);
        let p = std::env::temp_dir().join(format!("cache-server-test-{}-{}-{tag}", std::process::id(), N.fetch_add(1, Ordering::Relaxed)));
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }
}

#[cfg(test)]
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
