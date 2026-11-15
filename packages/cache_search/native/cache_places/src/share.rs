//! The places a device shares with its linked devices, with one writer per synced file.
//!
//! The merged places database (`regions/places/<build>.sqlite` with its -wal) is written by its own device only and never syncs.
//! Each device shares a snapshot of its own under its own name, `regions/places-share/<build>/<device>.sqlite` (a whole database,
//! written under a hidden name and renamed into place), and searches its own database and every peer's snapshot as extra packs,
//! read-only ([`crate::PackSet::current`]). The device's name is `regions/.share-id` (a name starting with "." never syncs).

use std::hash::{Hash, Hasher};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

/// The folder of the shared snapshots, beside `places/` in the regions folder.
pub const PLACES_SHARE_DIR: &str = "places-share";

/// The file that holds this device's share name (hidden, so it never syncs).
pub const SHARE_ID_FILE: &str = ".share-id";

/// A device name as a file name: letters, digits, `-`, `_`; nothing that leaves the folder.
pub fn safe_device(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}

/// This device's share name in `dir` (the regions folder), made on first use.
pub fn share_id(dir: &Path) -> String {
    if let Some(id) = read_share_id(dir) {
        return id;
    }
    let nanos = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let word = |salt: u8| {
        let mut h = std::collections::hash_map::DefaultHasher::new();
        (salt, nanos, std::process::id(), dir).hash(&mut h);
        h.finish()
    };
    let id = format!("{:016x}{:04x}", word(1), word(2) & 0xffff);
    let _ = std::fs::create_dir_all(dir);
    let _ = std::fs::write(dir.join(SHARE_ID_FILE), &id);
    id
}

/// The share name already made in `dir`, if any.
pub fn read_share_id(dir: &Path) -> Option<String> {
    let t = std::fs::read_to_string(dir.join(SHARE_ID_FILE)).ok()?;
    let t = t.trim();
    safe_device(t).then(|| t.to_string())
}

/// The peers' snapshots of `build`'s places database: every `<regions>/places-share/<build>/<device>.sqlite` but this device's own,
/// as a plain file name (a sync conflict copy, a hidden temporary file or anything else is never read), in device order.
pub fn peer_files(regions_dir: &Path, build: &str) -> Vec<PathBuf> {
    let own = read_share_id(regions_dir);
    let Ok(rd) = std::fs::read_dir(regions_dir.join(PLACES_SHARE_DIR).join(build)) else { return Vec::new() };
    let mut v: Vec<PathBuf> = rd
        .flatten()
        .filter_map(|e| {
            let name = e.file_name().to_string_lossy().into_owned();
            let dev = name.strip_suffix(".sqlite")?;
            (safe_device(dev) && Some(dev) != own.as_deref() && e.path().is_file()).then(|| e.path())
        })
        .collect();
    v.sort();
    v
}

/// The newest build with a peer snapshot (by name), for a device that has no places build of its own yet.
pub fn newest_shared_build(regions_dir: &Path) -> Option<String> {
    let rd = std::fs::read_dir(regions_dir.join(PLACES_SHARE_DIR)).ok()?;
    let mut builds: Vec<String> = rd.flatten().filter(|e| e.path().is_dir()).map(|e| e.file_name().to_string_lossy().into_owned()).filter(|b| safe_device(b.replace('.', "-").as_str())).collect();
    builds.sort();
    builds.pop()
}

/// The name of the live file a sync conflict copy was made beside, when `name` is one: cache_sync names the local copy of a file
/// both devices changed `<stem> (conflict, <device>, <YYYY-MM-DD HHMM>[ UTC])<ext>`, so `regions (conflict, A, 2026-11-14 1929 UTC).sqlite`
/// is `regions.sqlite`. Anything else (a title that merely has brackets in it) is not one.
pub fn conflict_live_name(name: &str) -> Option<String> {
    let start = name.find(" (conflict, ")?;
    let rest = &name[start + " (conflict, ".len()..];
    let close = rest.find(')')?;
    let inner = &rest[..close];
    let after = &rest[close + 1..];
    let (device, stamp) = inner.rsplit_once(", ")?;
    if device.is_empty() || device.contains('(') {
        return None;
    }
    let stamp = stamp.strip_suffix(" UTC").unwrap_or(stamp);
    let b = stamp.as_bytes();
    let digits = |r: std::ops::Range<usize>| r.into_iter().all(|i| b[i].is_ascii_digit());
    let stamp_ok = b.len() == 15 && digits(0..4) && b[4] == b'-' && digits(5..7) && b[7] == b'-' && digits(8..10) && b[10] == b' ' && digits(11..15);
    if !stamp_ok || (!after.is_empty() && !after.starts_with('.')) || after.contains('/') {
        return None;
    }
    let stem = &name[..start];
    if stem.is_empty() {
        return None;
    }
    Some(format!("{stem}{after}"))
}
