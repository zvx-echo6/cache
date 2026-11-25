//! Whether Cache on Linux should ask the person to run the installer again: the release runs as the person who installed it
//! (its unit carries `X-Cache-RunsAs=person`), `/etc/cache-app/person` names that person, but this process runs as the fallback
//! `cache` account, because the drop-in `cache.service.d/person.conf` that names the person is missing (for example after an
//! update with an older release's install.sh). Cache then cannot open the person's folders. Worked out once at start; the browser
//! reads it from `GET /api/version` (`run_installer_again`) and shows a card at the top of Settings until the next start as the
//! person. An older release (no marker) runs as `cache` on purpose, so it never asks.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};

/// The marker line of a release whose unit runs it as the person (systemd ignores keys that start with `X-`).
pub const MARKER: &str = "X-Cache-RunsAs=person";

/// The fallback account the release's unit names when the drop-in is missing.
pub const FALLBACK_USER: &str = "cache";

/// Where the record and the unit are read from; the tests point them at temp files.
#[derive(Debug, Clone)]
pub struct Paths {
    /// `/etc/cache-app/person`, written by install.sh: the person Cache is for.
    pub record: PathBuf,
    /// The unit files to look for the marker in, the first one that exists decides: the running release's own `cache.service`
    /// (next to the program, `/opt/cache-app/releases/<version>/cache.service`), then the installed `/etc/systemd/system/cache.service`.
    pub units: Vec<PathBuf>,
}

impl Paths {
    /// The real places, for the program at `exe` (normally `std::env::current_exe()`).
    pub fn system(exe: Option<&Path>) -> Paths {
        let mut units = Vec::new();
        if let Some(dir) = exe.and_then(|e| std::fs::canonicalize(e).ok()).and_then(|e| e.parent().map(Path::to_path_buf)) {
            units.push(dir.join("cache.service"));
        }
        units.push(PathBuf::from("/etc/systemd/system/cache.service"));
        Paths { record: PathBuf::from("/etc/cache-app/person"), units }
    }
}

/// True when the card should show: `running` is the account this process runs as (None when it cannot be named).
pub fn needs_installer(running: Option<&str>, paths: &Paths) -> bool {
    let _ = (running, paths);
    false
}

/// The name of the account this process runs as (its effective uid), through the system's account database; None when it has none.
pub fn running_user() -> Option<String> {
    None
}

static NEEDED: AtomicBool = AtomicBool::new(false);

/// Set once at start by `cache serve`.
pub fn set_needed(v: bool) {
    NEEDED.store(v, Ordering::Relaxed);
}

/// What `GET /api/version` reports as `run_installer_again`.
pub fn needed() -> bool {
    NEEDED.load(Ordering::Relaxed)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;

    const UNIT_NEW: &str = "[Unit]\nDescription=Cache for Linux\n\n[Service]\nUser=cache\nGroup=cache\nX-Cache-RunsAs=person\nExecStart=/opt/cache-app/current/cache serve\n";
    const UNIT_OLD: &str = "[Unit]\nDescription=Cache for Linux\n\n[Service]\nUser=cache\nGroup=cache\nExecStart=/opt/cache-app/current/cache serve\n";

    /// A record holding `record` (None: no record file) and one release unit `unit` (None: no unit file), plus the installed unit.
    fn rig(d: &TempDir, record: Option<&str>, release_unit: Option<&str>, installed_unit: Option<&str>) -> Paths {
        let record_path = d.0.join("etc-cache-app/person");
        if let Some(r) = record {
            std::fs::create_dir_all(record_path.parent().unwrap()).unwrap();
            std::fs::write(&record_path, r).unwrap();
        }
        let release = d.0.join("release/cache.service");
        if let Some(u) = release_unit {
            std::fs::create_dir_all(release.parent().unwrap()).unwrap();
            std::fs::write(&release, u).unwrap();
        }
        let installed = d.0.join("systemd/cache.service");
        if let Some(u) = installed_unit {
            std::fs::create_dir_all(installed.parent().unwrap()).unwrap();
            std::fs::write(&installed, u).unwrap();
        }
        Paths { record: record_path, units: vec![release, installed] }
    }

    #[test]
    fn shows_when_running_as_cache_with_the_marker_and_a_record() {
        let d = TempDir::new("runs-as-shows");
        let p = rig(&d, Some("alice\n"), Some(UNIT_NEW), Some(UNIT_NEW));
        assert!(needs_installer(Some("cache"), &p));
    }

    #[test]
    fn shows_when_only_the_installed_unit_is_there() {
        let d = TempDir::new("runs-as-installed");
        let p = rig(&d, Some("alice"), None, Some(UNIT_NEW));
        assert!(needs_installer(Some("cache"), &p));
    }

    #[test]
    fn not_when_running_as_the_recorded_person() {
        let d = TempDir::new("runs-as-person");
        let p = rig(&d, Some("alice\n"), Some(UNIT_NEW), Some(UNIT_NEW));
        assert!(!needs_installer(Some("alice"), &p));
    }

    #[test]
    fn not_without_a_record() {
        let d = TempDir::new("runs-as-norecord");
        let p = rig(&d, None, Some(UNIT_NEW), Some(UNIT_NEW));
        assert!(!needs_installer(Some("cache"), &p));
        let d2 = TempDir::new("runs-as-emptyrecord");
        let p2 = rig(&d2, Some("  \n"), Some(UNIT_NEW), Some(UNIT_NEW));
        assert!(!needs_installer(Some("cache"), &p2));
    }

    #[test]
    fn not_when_the_record_names_the_cache_account() {
        let d = TempDir::new("runs-as-recordcache");
        let p = rig(&d, Some("cache\n"), Some(UNIT_NEW), Some(UNIT_NEW));
        assert!(!needs_installer(Some("cache"), &p));
    }

    #[test]
    fn not_for_an_older_release_without_the_marker() {
        let d = TempDir::new("runs-as-old");
        let p = rig(&d, Some("alice\n"), Some(UNIT_OLD), Some(UNIT_OLD));
        assert!(!needs_installer(Some("cache"), &p));
    }

    #[test]
    fn the_running_release_decides_over_the_installed_unit() {
        // the release that is running has no marker (an older release): it runs as cache on purpose
        let d = TempDir::new("runs-as-release-first");
        let p = rig(&d, Some("alice\n"), Some(UNIT_OLD), Some(UNIT_NEW));
        assert!(!needs_installer(Some("cache"), &p));
    }

    #[test]
    fn not_without_any_unit_file() {
        let d = TempDir::new("runs-as-nounit");
        let p = rig(&d, Some("alice\n"), None, None);
        assert!(!needs_installer(Some("cache"), &p));
    }

    #[test]
    fn not_when_the_running_account_cannot_be_named() {
        let d = TempDir::new("runs-as-noname");
        let p = rig(&d, Some("alice\n"), Some(UNIT_NEW), Some(UNIT_NEW));
        assert!(!needs_installer(None, &p));
    }

    #[test]
    fn not_when_running_as_someone_other_than_cache() {
        // a hand-over half done (drop-in for bob, record still alice) is not the missing drop-in; the installer says what to do then
        let d = TempDir::new("runs-as-other");
        let p = rig(&d, Some("alice\n"), Some(UNIT_NEW), Some(UNIT_NEW));
        assert!(!needs_installer(Some("bob"), &p));
    }

    #[test]
    fn the_running_user_is_named() {
        // the test runs as some account the system can name
        assert!(running_user().is_some_and(|n| !n.is_empty()));
    }

    #[test]
    fn system_paths_put_the_release_unit_first() {
        let d = TempDir::new("runs-as-system");
        let exe = d.0.join("cache");
        std::fs::write(&exe, b"").unwrap();
        let p = Paths::system(Some(&exe));
        assert_eq!(p.record, PathBuf::from("/etc/cache-app/person"));
        assert_eq!(p.units, vec![std::fs::canonicalize(&d.0).unwrap().join("cache.service"), PathBuf::from("/etc/systemd/system/cache.service")]);
    }
}
