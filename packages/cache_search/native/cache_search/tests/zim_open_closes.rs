//! `ZimSource::open` must leave nothing of the `zim` crate's reader open once it returns. With libzim built in, the source only
//! reads what it needs from that reader (header, title, language, index sizes) and drops it, so that a phone opening many ZIMs
//! does not hold one extra mapping per ZIM next to libzim's own archive (DESIGN.md "Memory budget").
//!
//! The check is on the file itself, with no hook in the product: on Windows an exclusive open (share mode 0) fails while any
//! handle or mapped view of the file exists; elsewhere the process's open files and mappings are searched for the path
//! (`/proc/self/fd`, `/proc/self/maps`). The check is proven first on the crate's own reader (held: it must see it), then
//! on `ZimSource::open`, for every ZIM in the folder one after the other with the earlier sources still alive.
//!
//! Runs only when CS_TEST_ZIM_DIR is set (any folder with ZIMs; CS_OPEN_MAX_MB, default 4096, skips larger files)
//! and in a build with libzim (the `xapian` feature on Windows or Android).

#![cfg(zimx)]

use cache_search::zimsrc::ZimSource;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

/// Both tests look at the same files from one process, and "held" is process-wide: they must not run at the same time.
static ONE_AT_A_TIME: Mutex<()> = Mutex::new(());

/// Is anything in this process still holding `path` open or mapped?
#[cfg(windows)]
fn held(path: &Path) -> bool {
    use std::os::windows::fs::OpenOptionsExt;
    std::fs::OpenOptions::new().read(true).share_mode(0).open(path).is_err()
}

#[cfg(unix)]
fn held(path: &Path) -> bool {
    let want = std::fs::canonicalize(path).unwrap();
    let open = std::fs::read_dir("/proc/self/fd")
        .unwrap()
        .filter_map(|e| e.ok())
        .filter_map(|e| std::fs::read_link(e.path()).ok())
        .any(|l| l == want);
    let mapped = std::fs::read_to_string("/proc/self/maps").unwrap_or_default().lines().any(|l| l.ends_with(want.to_string_lossy().as_ref()));
    open || mapped
}

fn zims() -> Vec<PathBuf> {
    let Some(dir) = std::env::var("CS_TEST_ZIM_DIR").ok().filter(|s| !s.is_empty()) else { return Vec::new() };
    let max: u64 = std::env::var("CS_OPEN_MAX_MB").ok().and_then(|v| v.parse().ok()).unwrap_or(4096) * 1024 * 1024;
    let mut v: Vec<PathBuf> = std::fs::read_dir(dir)
        .unwrap()
        .filter_map(|e| e.ok())
        .map(|e| e.path())
        .filter(|p| p.extension().map(|x| x == "zim").unwrap_or(false) && std::fs::metadata(p).map(|m| m.len() <= max).unwrap_or(false))
        .collect();
    v.sort();
    v
}

#[test]
fn the_check_sees_a_held_reader() {
    let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    let all = zims();
    let Some(p) = all.first() else {
        eprintln!("CS_TEST_ZIM_DIR not set (or empty): skipping");
        return;
    };
    assert!(!held(p), "{} is held before the test starts", p.display());
    let reader = zim::Zim::new(p).expect("open with the crate reader");
    assert!(held(p), "the check does not see the crate's reader on {}", p.display());
    drop(reader);
    assert!(!held(p), "the crate's reader left {} held after it was dropped", p.display());
}

#[test]
fn open_leaves_nothing_of_the_zim_crate_open() {
    let _one = ONE_AT_A_TIME.lock().unwrap_or_else(|e| e.into_inner());
    let all = zims();
    if all.is_empty() {
        eprintln!("CS_TEST_ZIM_DIR not set (or empty): skipping");
        return;
    }
    assert!(ZimSource::open(&all[0]).is_ok());
    let mut alive: Vec<ZimSource> = Vec::new();
    for p in &all {
        assert!(!held(p), "{} is held before it is opened", p.display());
        let src = ZimSource::open(p).unwrap_or_else(|e| panic!("{}: {}", p.display(), e.message));
        // the brief read of the header and the index sizes is over: the file is free again before the next ZIM opens
        assert!(!held(p), "ZimSource::open left {} open or mapped", p.display());
        alive.push(src);
        // and the sources opened earlier are still free
        for q in all.iter().take(alive.len()) {
            assert!(!held(q), "{} became held while opening {}", q.display(), p.display());
        }
    }
    eprintln!("open_leaves_nothing_of_the_zim_crate_open: {} ZIMs, none held after open", all.len());
    // the crate reader is only opened (and then kept) on demand, for the Tantivy index build
    let first = &alive[0];
    first.zim().expect("on-demand reader");
    assert!(held(&all[0]), "zim() should hold the reader it opens");
}
