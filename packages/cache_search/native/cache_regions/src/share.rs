//! Sharing the region engine's data between linked devices, with one writer per synced file (see cache_places::share, and
//! cache_layers::share for the map layers).
//!
//! The live databases, `regions.sqlite` and `places/<build>.sqlite` (with their -wal), never sync. This device writes:
//! - `places-share/<build>/<device>.sqlite`: a snapshot of its merged places database ([`Inner::share_places`]), which every linked
//!   device searches beside its own, read-only.
//!
//! An older build's sync conflicts are taken back in when the engine opens ([`rescue_conflicts`]).
//!
//! The regions list itself (`regions-share/<device>.json`, and `regions-share/<device>.deletes.json`) is written and read by the
//! app, which keeps what each region holds (lib/regions/regions_share.dart).

use super::*;
use cache_places::share::{conflict_live_name, PLACES_SHARE_DIR};
use cache_places::share::{safe_device, share_id};

/// A database has to have been quiet this long before it is copied, so a download in progress is not copied over and over.
pub const QUIET: Duration = Duration::from_secs(20);

fn age_of(p: &Path) -> Option<Duration> {
    std::fs::metadata(p).ok()?.modified().ok()?.elapsed().ok()
}

fn stamp_of(p: &Path) -> String {
    std::fs::metadata(p)
        .ok()
        .map(|m| {
            let t = m.modified().ok().and_then(|t| t.duration_since(UNIX_EPOCH).ok()).map(|d| d.as_nanos()).unwrap_or(0);
            format!("{}:{t}", m.len())
        })
        .unwrap_or_default()
}

fn remove_db_files(db: &Path) {
    for ext in ["", "-wal", "-shm", "-journal"] {
        let _ = std::fs::remove_file(format!("{}{ext}", db.display()));
    }
}

fn is_database(p: &Path, table: &str) -> bool {
    let Ok(c) = Connection::open(p) else { return false };
    let ok = c.query_row("PRAGMA integrity_check", [], |r| r.get::<_, String>(0)).map(|s| s == "ok").unwrap_or(false);
    ok && c.query_row("SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=?1", [table], |r| r.get::<_, i64>(0)).map(|n| n > 0).unwrap_or(false)
}

/// The conflict copies in `dir` made beside `<stem>.sqlite`: (main databases, their logs).
fn conflict_copies(dir: &Path, live_name: &str) -> (Vec<PathBuf>, Vec<PathBuf>) {
    let (mut mains, mut logs) = (Vec::new(), Vec::new());
    for e in std::fs::read_dir(dir).into_iter().flatten().flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let Some(live) = conflict_live_name(&name) else { continue };
        if live == live_name {
            mains.push(e.path());
        } else if live.strip_prefix(live_name).is_some_and(|x| x == "-wal" || x == "-shm" || x == "-journal") {
            logs.push(e.path());
        }
    }
    mains.sort();
    (mains, logs)
}

/// The ids of the regions this device's app lists as its own with a part the core holds (`regions-app.json`, beside the regions folder
/// and never synced), or `None` when there is no such list (then nothing says which of two files is this device's).
fn own_region_ids(dir: &Path) -> Option<HashSet<String>> {
    let text = std::fs::read_to_string(dir.parent()?.join("regions-app.json")).ok()?;
    let v: Value = serde_json::from_str(&text).ok()?;
    let out: HashSet<String> =
        v["regions"].as_object()?.iter().filter(|(_, r)| r["routing"] == true || r["places"] == true).map(|(id, _)| id.clone()).collect();
    (!out.is_empty()).then_some(out)
}

fn region_ids(p: &Path) -> Option<HashSet<String>> {
    let c = Connection::open(p).ok()?;
    c.busy_timeout(Duration::from_secs(5)).ok()?;
    let mut q = c.prepare("SELECT id FROM regions").ok()?;
    let ids: HashSet<String> = q.query_map([], |r| r.get::<_, String>(0)).ok()?.collect::<std::result::Result<_, _>>().ok()?;
    drop(q);
    Some(ids)
}

/// Takes in what a sync conflict left in the regions folder. Before this version the live databases synced, and a device whose
/// database was replaced by another device's kept its own as `<name> (conflict, ...).sqlite`; conflict copies synced too, so a device
/// may also hold another device's. Nothing that is this device's own is dropped:
/// - `regions.sqlite`: which copies are this device's own, and whether the live file is, is told by the regions its app lists as its
///   own (`regions-app.json`). A copy that holds one is merged into the live file (regions, tile lists and stream records it lacks, by
///   id) and deleted; one that holds none is another device's, and is deleted. The live file is replaced by the first copy only when it
///   holds none of this device's regions. With no such list the live file stays and every copy is merged into it.
/// - `places/<build>.sqlite`: the database with the most tiles, the live file or a copy, is the live database; the others are deleted
///   (the regions that want a tile it lacks fetch it again). `places/CURRENT` and `places/<build>/common` conflict copies are deleted.
///
/// A copy that is not a whole database stays where it is, and drops nothing. A lone log (a conflict -wal with no database) is
/// deleted. Returns how many conflict files were dealt with.
pub fn rescue_conflicts(dir: &Path) -> usize {
    let mut n = 0;
    // regions.sqlite
    let (mains, logs) = conflict_copies(dir, "regions.sqlite");
    let own = own_region_ids(dir);
    let good: Vec<(PathBuf, HashSet<String>)> = mains.iter().filter(|p| is_database(p, "regions")).filter_map(|p| region_ids(p).map(|ids| (p.clone(), ids))).collect();
    let (mine, others): (Vec<_>, Vec<_>) = match &own {
        Some(o) => good.into_iter().partition(|(_, ids)| !ids.is_disjoint(o)),
        None => (good, Vec::new()),
    };
    for (p, _) in &others {
        remove_db_files(p);
        n += 1;
    }
    if !mine.is_empty() {
        let live = dir.join("regions.sqlite");
        let live_is_theirs = own.as_ref().is_some_and(|o| live.is_file() && region_ids(&live).is_some_and(|ids| ids.is_disjoint(o)));
        let mut rest: Vec<&(PathBuf, HashSet<String>)> = mine.iter().collect();
        if live_is_theirs || !live.is_file() {
            // the first copy becomes the live file
            let (first, _) = rest.remove(0);
            remove_db_files(&live);
            if std::fs::rename(first, &live).is_ok() {
                n += 1;
                for ext in ["-wal", "-shm", "-journal"] {
                    let _ = std::fs::remove_file(format!("{}{ext}", first.display()));
                }
            }
        }
        if let Ok(c) = Connection::open(&live) {
            for (other, _) in rest {
                if merge_regions(&c, other).is_ok() {
                    remove_db_files(other);
                    n += 1;
                }
            }
        }
    }
    for l in &logs {
        let main = l.to_string_lossy().rsplit_once(".sqlite-").map(|(a, _)| format!("{a}.sqlite")).unwrap_or_default();
        if !Path::new(&main).is_file() && std::fs::remove_file(l).is_ok() {
            n += 1;
        }
    }
    // places
    let places = dir.join("places");
    let mut builds: HashMap<String, Vec<PathBuf>> = HashMap::new();
    let mut loose: Vec<PathBuf> = Vec::new();
    for e in std::fs::read_dir(&places).into_iter().flatten().flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let Some(live) = conflict_live_name(&name) else { continue };
        if let Some(b) = live.strip_suffix(".sqlite") {
            builds.entry(b.to_string()).or_default().push(e.path());
        } else if live == "CURRENT" || live.ends_with(".sqlite-wal") || live.ends_with(".sqlite-shm") || live.ends_with(".sqlite-journal") {
            loose.push(e.path());
        }
    }
    for (build, mut copies) in builds {
        copies.sort();
        let live = places.join(format!("{build}.sqlite"));
        // the database with the most tiles, the live one or a copy
        let mut best: Option<(usize, PathBuf)> = merged_tile_count(&live).map(|c| (c, live.clone()));
        let mut whole = Vec::new();
        for p in &copies {
            if let Some(count) = merged_tile_count(p) {
                whole.push(p.clone());
                if best.as_ref().is_none_or(|(c, _)| count > *c) {
                    best = Some((count, p.clone()));
                }
            }
        }
        let Some((_, keep)) = best else { continue };
        if keep != live {
            remove_db_files(&live);
            if std::fs::rename(&keep, &live).is_err() {
                continue;
            }
            for ext in ["-wal", "-shm", "-journal"] {
                let _ = std::fs::remove_file(format!("{}{ext}", keep.display()));
            }
            n += 1;
        }
        for p in whole.iter().filter(|p| **p != keep) {
            remove_db_files(p);
            n += 1;
        }
    }
    for p in loose {
        let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        // a log is read with its database: one whose database is gone is no use to anyone; a CURRENT copy only names a build
        let main = name.rsplit_once(".sqlite-").map(|(a, _)| format!("{a}.sqlite"));
        if main.is_none_or(|m| !places.join(m).is_file()) && std::fs::remove_file(&p).is_ok() {
            n += 1;
        }
    }
    // the build's common file: each device fetches its own
    for e in std::fs::read_dir(&places).into_iter().flatten().flatten().filter(|e| e.path().is_dir()) {
        for f in std::fs::read_dir(e.path()).into_iter().flatten().flatten() {
            let name = f.file_name().to_string_lossy().into_owned();
            if conflict_live_name(&name).is_some_and(|l| l == "common.sqlite") && std::fs::remove_file(f.path()).is_ok() {
                n += 1;
            }
        }
    }
    n
}

/// How many tiles the merged places database at `p` holds, when it is a whole one.
fn merged_tile_count(p: &Path) -> Option<usize> {
    if !is_database(p, "tiles") {
        return None;
    }
    let c = Connection::open_with_flags(p, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY).ok()?;
    c.query_row("SELECT COUNT(*) FROM tiles", [], |r| r.get::<_, i64>(0)).ok().map(|n| n as usize)
}

/// Adds this device's other copy of regions.sqlite to `live`: regions (by id), their tile lists and the stream
/// records, each only when this one lacks it. The columns the copy has are the ones read (an older copy lacks the later ones).
fn merge_regions(live: &Connection, other: &Path) -> Result<()> {
    live.execute("ATTACH DATABASE ?1 AS o", [other.to_string_lossy().as_ref()])?;
    let r = (|| -> Result<()> {
        let cols = |t: &str, schema: &str| -> Result<Vec<String>> {
            let mut q = live.prepare(&format!("PRAGMA {schema}.table_info({t})"))?;
            let rows = q.query_map([], |r| r.get::<_, String>(1))?;
            Ok(rows.collect::<rusqlite::Result<_>>()?)
        };
        live.execute_batch("BEGIN")?;
        for (table, key) in [("regions", "id"), ("region_tiles2", "region"), ("stream2", "component")] {
            let (mine, theirs) = (cols(table, "main")?, cols(table, "o")?);
            let shared: Vec<&String> = mine.iter().filter(|c| theirs.contains(c)).collect();
            if shared.is_empty() || !shared.iter().any(|c| c.as_str() == key) {
                continue;
            }
            let list = shared.iter().map(|c| c.as_str()).collect::<Vec<_>>().join(",");
            live.execute(&format!("INSERT OR IGNORE INTO main.{table}({list}) SELECT {list} FROM o.{table}"), [])?;
        }
        live.execute_batch("COMMIT")?;
        Ok(())
    })();
    if r.is_err() {
        let _ = live.execute_batch("ROLLBACK");
    }
    let _ = live.execute_batch("DETACH DATABASE o");
    r
}

impl Inner {
    /// This device's name in the share.
    pub(crate) fn share_name(&self) -> String {
        share_id(&self.dir)
    }

    /// Writes this device's snapshot of its places database when it changed since the last one and has been quiet for `quiet`
    /// (`places-share/<build>/<device>.sqlite`). Snapshots of the device's other builds are removed. Returns whether one was written.
    pub(crate) fn share_places(&self, quiet: Duration) -> Result<bool> {
        let Some(p) = &self.places else { return Ok(false) };
        let Some(build) = self.st().p.build.clone() else { return Ok(false) };
        let live = p.db_file(&build);
        if !live.is_file() {
            return Ok(false);
        }
        let wal = PathBuf::from(format!("{}-wal", live.display()));
        for f in [&live, &wal] {
            if age_of(f).is_some_and(|a| a < quiet) {
                return Ok(false);
            }
        }
        let id = self.share_name();
        if !safe_device(&id) || !safe_device(&build.replace('.', "-")) {
            return Ok(false);
        }
        let root = self.dir.join(PLACES_SHARE_DIR);
        // snapshots of builds this device no longer uses
        for e in std::fs::read_dir(&root).into_iter().flatten().flatten() {
            if e.file_name().to_string_lossy() != build.as_str() {
                let _ = std::fs::remove_file(e.path().join(format!("{id}.sqlite")));
            }
        }
        let now = format!("{}|{}", stamp_of(&live), stamp_of(&wal));
        let dir = root.join(&build);
        let to = dir.join(format!("{id}.sqlite"));
        if to.is_file() {
            let had: Option<String> = Connection::open_with_flags(&to, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)
                .ok()
                .and_then(|c| c.query_row("SELECT value FROM meta WHERE key='share_src'", [], |r| r.get(0)).ok());
            if had.as_deref() == Some(now.as_str()) {
                return Ok(false);
            }
        }
        std::fs::create_dir_all(&dir)?;
        let tmp = dir.join(format!(".{id}.sqlite.tmp{}", std::process::id()));
        remove_db_files(&tmp);
        let made = (|| -> Result<()> {
            let src = Connection::open_with_flags(&live, rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY)?;
            src.busy_timeout(Duration::from_secs(30))?;
            src.execute("VACUUM INTO ?1", [tmp.to_string_lossy().as_ref()])?;
            drop(src);
            let c = Connection::open(&tmp)?;
            c.execute("INSERT OR REPLACE INTO meta(key, value) VALUES('share_src', ?1)", [&now])?;
            c.execute_batch("PRAGMA journal_mode = DELETE;")?;
            Ok(())
        })();
        if let Err(e) = made {
            remove_db_files(&tmp);
            return Err(e);
        }
        std::fs::rename(&tmp, &to)?;
        Ok(true)
    }
}
