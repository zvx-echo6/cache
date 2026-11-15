//! Sharing the downloaded map layers between linked devices, with one writer per synced file.
//!
//! The live stores (`store/<layer>.sqlite` with its -wal) are never synced: each is written by its own device only. What a device
//! shares is a snapshot of its own store under its own name, `store-share/<layer>/<device>.sqlite` (written whole, then renamed
//! into place), and a record of the areas it deleted, `store-share/<device>.deletes.json`. A device reads its own store and every
//! peer's snapshot, read-only and never merged into one file (a map of a state would otherwise be on the disk three times):
//! tiles and the list of areas are the union, this device's own first.
//!
//! A delete travels as a record in the deleting device's shared folder (layer, area, time). Every device applies it to its own
//! store and ignores a peer's copy of that area; a download made after the delete is newer than it and wins.
//!
//! The device's name here is `<layers dir>/.share-id`, made once (a name starting with "." never syncs).

use crate::core::{now_secs, AreaInfo, Inner};
use crate::error::{Error, Result};
use crate::store::Store;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, SystemTime};

/// The folder of the shared snapshots and delete records, inside the layers folder.
pub const SHARE_DIR: &str = "store-share";

/// The file that holds this device's share name (hidden, so it never syncs).
pub const SHARE_ID_FILE: &str = ".share-id";

/// A store has to have been quiet this long before it is exported, so a download in progress is not copied over and over.
pub const QUIET: Duration = Duration::from_secs(20);

/// The name of the live file a sync conflict copy was made beside, when `name` is one: cache_sync names the local copy of a file
/// both devices changed `<stem> (conflict, <device>, <YYYY-MM-DD HHMM>[ UTC])<ext>`, so `basemap (conflict, A, 2026-11-14 1929 UTC).sqlite`
/// is `basemap.sqlite`. Anything else (a title that merely has brackets in it) is not one.
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

/// This device's share name in `dir` (made on first use).
pub fn share_id(dir: &Path) -> String {
    let f = dir.join(SHARE_ID_FILE);
    if let Ok(t) = std::fs::read_to_string(&f) {
        let t = t.trim();
        if safe_device(t) {
            return t.to_string();
        }
    }
    let nanos = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let mut h = Sha256::new();
    h.update(nanos.to_le_bytes());
    h.update(std::process::id().to_le_bytes());
    h.update(dir.to_string_lossy().as_bytes());
    let id: String = h.finalize().iter().take(10).map(|b| format!("{b:02x}")).collect();
    let _ = std::fs::create_dir_all(dir);
    let _ = std::fs::write(&f, &id);
    id
}

/// A device name as a file name: letters, digits, `-`, `_`; nothing that leaves the folder.
fn safe_device(s: &str) -> bool {
    !s.is_empty() && s.len() <= 64 && s.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
}

type Stamp = (u64, u128);

fn stamp_of(p: &Path) -> Option<Stamp> {
    let m = std::fs::metadata(p).ok()?;
    let t = m.modified().ok().and_then(|t| t.duration_since(SystemTime::UNIX_EPOCH).ok()).map(|d| d.as_nanos()).unwrap_or(0);
    Some((m.len(), t))
}

fn age_of(p: &Path) -> Option<Duration> {
    std::fs::metadata(p).ok()?.modified().ok()?.elapsed().ok()
}

/// One area deleted on a device: (layer, area id, seconds).
#[derive(Debug, Clone, PartialEq)]
pub struct Deleted {
    pub layer: String,
    pub area: String,
    pub at: i64,
}

fn read_deletes(p: &Path) -> Vec<Deleted> {
    let Some(v) = std::fs::read_to_string(p).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) else { return Vec::new() };
    v["deletes"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|d| Some(Deleted { layer: d["layer"].as_str()?.to_string(), area: d["area"].as_str()?.to_string(), at: d["at"].as_i64()? }))
                .collect()
        })
        .unwrap_or_default()
}

/// Writes `bytes` to a hidden temporary file beside `path` and renames it into place (so a peer never sees half of it, and the
/// temporary name never syncs).
fn write_whole(path: &Path, bytes: &[u8]) -> Result<()> {
    let dir = path.parent().ok_or_else(|| Error::io("no folder"))?;
    std::fs::create_dir_all(dir).map_err(|e| Error::io(format!("creating {}: {e}", dir.display())))?;
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = dir.join(format!(".{name}.tmp{}", std::process::id()));
    std::fs::write(&tmp, bytes).map_err(|e| Error::io(format!("writing {}: {e}", tmp.display())))?;
    std::fs::rename(&tmp, path).map_err(|e| Error::io(format!("renaming to {}: {e}", path.display())))
}

/// What one pass of [`Inner::maintain_share`] did.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct Maintained {
    pub rescued: usize,
    pub deleted: usize,
    pub exported: usize,
}

/// A peer's shared store, opened once and reopened when the file is replaced.
pub struct PeerStore {
    pub device: String,
    pub store: Arc<Store>,
}

#[derive(Default)]
pub struct PeerCache {
    open: HashMap<PathBuf, (Stamp, Arc<Store>)>,
}

impl Inner {
    /// This device's share name.
    pub fn share_id(&self) -> &str {
        &self.share_id
    }

    pub fn share_root(&self) -> PathBuf {
        self.dir.join(SHARE_DIR)
    }

    /// Where this device's snapshot of `layer`'s store is shared.
    pub fn export_path(&self, layer: &str) -> PathBuf {
        self.share_root().join(layer).join(format!("{}.sqlite", self.share_id))
    }

    fn deletes_path(&self, device: &str) -> PathBuf {
        self.share_root().join(format!("{device}.deletes.json"))
    }

    /// The peers' shared stores of `layer`, in device order: every `store-share/<layer>/<device>.sqlite` but this device's own,
    /// as a plain file name (a sync conflict copy, a temporary file or anything else is never read).
    pub fn peer_stores(&self, layer: &str) -> Vec<PeerStore> {
        let dir = self.share_root().join(layer);
        let Ok(rd) = std::fs::read_dir(&dir) else { return Vec::new() };
        let mut files: Vec<(String, PathBuf)> = rd
            .flatten()
            .filter_map(|e| {
                let name = e.file_name().to_string_lossy().into_owned();
                let dev = name.strip_suffix(".sqlite")?;
                (safe_device(dev) && dev != self.share_id && e.path().is_file()).then(|| (dev.to_string(), e.path()))
            })
            .collect();
        files.sort();
        let mut out = Vec::new();
        let Ok(mut cache) = self.peers.lock() else { return out };
        for (device, path) in files {
            let Some(stamp) = stamp_of(&path) else { continue };
            let fresh = matches!(cache.open.get(&path), Some((s, _)) if *s == stamp);
            if !fresh {
                match Store::open_peer(&path) {
                    Ok(s) => {
                        cache.open.insert(path.clone(), (stamp, Arc::new(s)));
                    }
                    Err(_) => {
                        cache.open.remove(&path);
                        continue;
                    }
                }
            }
            if let Some((_, s)) = cache.open.get(&path) {
                out.push(PeerStore { device, store: s.clone() });
            }
        }
        out
    }

    /// Every delete record the peers shared (this device's own is not included).
    pub fn peer_deletes(&self) -> Vec<Deleted> {
        let Ok(rd) = std::fs::read_dir(self.share_root()) else { return Vec::new() };
        let mut out = Vec::new();
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            let Some(dev) = name.strip_suffix(".deletes.json") else { continue };
            if !safe_device(dev) || dev == self.share_id {
                continue;
            }
            out.extend(read_deletes(&e.path()));
        }
        out
    }

    /// Notes that this device deleted `area` of `layer` now, in its shared folder, so every linked device deletes it too.
    pub fn record_delete(&self, layer: &str, area: &str) -> Result<()> {
        let p = self.deletes_path(&self.share_id);
        let mut all = read_deletes(&p);
        let at = now_secs();
        all.retain(|d| !(d.layer == layer && d.area == area));
        all.push(Deleted { layer: layer.to_string(), area: area.to_string(), at });
        let v = json!({"deletes": all.iter().map(|d| json!({"layer": d.layer, "area": d.area, "at": d.at})).collect::<Vec<_>>()});
        write_whole(&p, v.to_string().as_bytes())
    }

    /// Whether a peer's delete record ends this area (the area was made at or before the delete).
    pub fn deleted_by_peer(deletes: &[Deleted], layer: &str, area: &str, created: i64) -> bool {
        deletes.iter().any(|d| d.layer == layer && d.area == area && d.at >= created)
    }

    /// The areas of the peers' shared stores that this device does not hold itself and no peer has deleted since, each once
    /// (the first device's), marked with `meta.shared_from` (the device's name).
    pub fn peer_areas(&self, layer: &str, own: &HashSet<String>) -> Vec<AreaInfo> {
        let deletes = self.peer_deletes();
        let own_deletes = read_deletes(&self.deletes_path(&self.share_id));
        let mut seen: HashSet<String> = own.clone();
        let mut out = Vec::new();
        for p in self.peer_stores(layer) {
            for (id, state, mut meta) in p.store.areas().unwrap_or_default() {
                let created = meta["created"].as_i64().unwrap_or(0);
                if seen.contains(&id) || Inner::deleted_by_peer(&deletes, layer, &id, created) || Inner::deleted_by_peer(&own_deletes, layer, &id, created) {
                    continue;
                }
                seen.insert(id.clone());
                meta["shared_from"] = json!(p.device);
                let b = &meta["bbox"];
                let bbox = [b[0].as_f64().unwrap_or(-180.0), b[1].as_f64().unwrap_or(-90.0), b[2].as_f64().unwrap_or(180.0), b[3].as_f64().unwrap_or(90.0)];
                out.push(AreaInfo { id, state, bbox, minzoom: meta["minzoom"].as_u64().unwrap_or(0) as u8, maxzoom: meta["maxzoom"].as_u64().unwrap_or(22) as u8, meta });
            }
        }
        out
    }

    /// Applies the peers' deletes to this device's own stores: an area made at or before a delete is removed (its tiles no other area
    /// covers go with it). Writes no record of its own: the delete is already in the peer's folder, and its time stays the time it
    /// was made. Returns how many areas went.
    pub fn apply_peer_deletes(&self) -> usize {
        let deletes = self.peer_deletes();
        let mut n = 0;
        for d in deletes {
            let Some(store) = self.store_read(&d.layer) else { continue };
            let Ok(Some((_, meta))) = store.area(&d.area) else { continue };
            if meta["created"].as_i64().unwrap_or(0) > d.at {
                continue;
            }
            if self.delete_areas_inner(&d.layer, Some(&d.area)).is_ok() {
                n += 1;
            }
        }
        n
    }

    /// Writes this device's snapshot of `layer` when its store changed since the last one and has been quiet for `quiet`.
    /// Returns whether one was written.
    pub fn export_share(&self, layer: &str, quiet: Duration) -> Result<bool> {
        let live = self.store_path(layer);
        if !live.is_file() {
            return Ok(false);
        }
        // fold the log into the file first, so the snapshot and the stamp describe one state
        if let Some(st) = self.store_read(layer) {
            st.checkpoint();
        }
        let wal = PathBuf::from(format!("{}-wal", live.display()));
        for f in [&live, &wal] {
            if age_of(f).is_some_and(|a| a < quiet) {
                return Ok(false);
            }
        }
        let stamp = |f: &Path| stamp_of(f).map(|(l, t)| format!("{l}:{t}")).unwrap_or_default();
        let now = format!("{}|{}", stamp(&live), stamp(&wal));
        let to = self.export_path(layer);
        if to.is_file() {
            let c = rusqlite::Connection::open_with_flags(&to, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY);
            let had: Option<String> = c.ok().and_then(|c| c.query_row("SELECT value FROM share WHERE key='src'", [], |r| r.get(0)).ok());
            if had.as_deref() == Some(now.as_str()) {
                return Ok(false);
            }
        }
        let dir = to.parent().ok_or_else(|| Error::io("no folder"))?;
        std::fs::create_dir_all(dir).map_err(|e| Error::io(format!("creating {}: {e}", dir.display())))?;
        let tmp = dir.join(format!(".{}.sqlite.tmp{}", self.share_id, std::process::id()));
        for ext in ["", "-journal", "-wal", "-shm"] {
            let _ = std::fs::remove_file(format!("{}{ext}", tmp.display()));
        }
        let made = Store::export_to(&live, &tmp, &now);
        if let Err(e) = made {
            let _ = std::fs::remove_file(&tmp);
            return Err(e);
        }
        std::fs::rename(&tmp, &to).map_err(|e| Error::io(format!("renaming to {}: {e}", to.display())))?;
        Ok(true)
    }

    /// Takes in what a sync conflict left in `store/`. Before this version the live stores synced, and a device whose store was
    /// replaced by another device's kept its own as `<layer> (conflict, ...).sqlite`: that copy is this device's own data, a whole
    /// store. It is merged into the live store (tiles it lacks, areas by id) and deleted; the live file that came from the other
    /// device is dropped first, since that device's own snapshot arrives by the share. A copy that fails the integrity check stays
    /// where it is (and nothing is dropped for it). A lone conflict -wal or -shm (a log without its database) is deleted.
    /// Returns how many conflict files were dealt with.
    pub fn rescue_conflicts(&self) -> usize {
        let dir = self.dir.join("store");
        let Ok(rd) = std::fs::read_dir(&dir) else { return 0 };
        let mut mains: HashMap<String, Vec<PathBuf>> = HashMap::new();
        let mut logs: Vec<(PathBuf, String)> = Vec::new();
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            let Some(live) = conflict_live_name(&name) else { continue };
            if let Some(layer) = live.strip_suffix(".sqlite") {
                mains.entry(layer.to_string()).or_default().push(e.path());
            } else if live.ends_with(".sqlite-wal") || live.ends_with(".sqlite-shm") || live.ends_with(".sqlite-journal") {
                logs.push((e.path(), name));
            }
        }
        let mut n = 0;
        for (layer, mut copies) in mains {
            copies.sort();
            // the ones that are whole databases
            let good: Vec<PathBuf> = copies.into_iter().filter(|p| integrity_ok(p)).collect();
            if good.is_empty() {
                continue;
            }
            // the live file is the other device's: drop it (and the handle on it), the copies become the live store
            if let Ok(mut g) = self.stores.lock() {
                g.remove(&layer);
            }
            let live = self.store_path(&layer);
            for ext in ["", "-wal", "-shm", "-journal"] {
                let _ = std::fs::remove_file(format!("{}{ext}", live.display()));
            }
            let Ok(store) = self.store_create(&layer) else { continue };
            for p in good {
                if store.merge_from(&p).is_ok() {
                    for ext in ["", "-wal", "-shm", "-journal"] {
                        let _ = std::fs::remove_file(format!("{}{ext}", p.display()));
                    }
                    n += 1;
                }
            }
        }
        for (p, name) in logs {
            // a log is read with its database (same name up to the extension); one whose database is gone is no use to anyone
            let main = name.rsplit_once(".sqlite-").map(|(a, _)| format!("{a}.sqlite")).unwrap_or_default();
            if !dir.join(&main).is_file() && std::fs::remove_file(&p).is_ok() {
                n += 1;
            }
        }
        n
    }

    /// One pass of everything the share needs: conflict copies taken in, peers' deletes applied, own snapshots written.
    pub fn maintain_share(&self, quiet: Duration) -> Maintained {
        let rescued = self.rescue_conflicts();
        let deleted = self.apply_peer_deletes();
        let mut exported = 0;
        let layers: Vec<String> = std::fs::read_dir(self.dir.join("store"))
            .map(|rd| {
                rd.flatten()
                    .filter_map(|e| e.file_name().to_string_lossy().strip_suffix(".sqlite").map(str::to_string))
                    .filter(|l| safe_device(l))
                    .collect()
            })
            .unwrap_or_default();
        for l in layers {
            if matches!(self.export_share(&l, quiet), Ok(true)) {
                exported += 1;
            }
        }
        Maintained { rescued, deleted, exported }
    }
}

fn integrity_ok(p: &Path) -> bool {
    let Ok(c) = rusqlite::Connection::open(p) else { return false };
    c.query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0)).map(|s| s == "ok").unwrap_or(false)
}
