//! Sharing the region engine's data between linked devices, with one writer per synced file (see cache_places::share, and
//! cache_layers::share for the map layers).
//!
//! The live databases, `regions.sqlite` and `places/<build>.sqlite` (with their -wal), never sync. This device writes:
//! - `places-share/<build>/<device>.sqlite`: a snapshot of its merged places database ([`Inner::share_places`]), which every linked
//!   device searches beside its own, read-only;
//! and an older build's sync conflicts are taken back in when the engine opens ([`rescue_conflicts`]).
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

/// Takes in what a sync conflict left in the regions folder. Before this version the live databases synced, and a device whose
/// database was replaced by another device's kept its own as `<name> (conflict, ...).sqlite`: that copy is this device's own data.
/// - `regions.sqlite`: the live file is the other device's, so it is dropped; the first whole copy becomes the live file and the
///   others' regions, tile lists and stream records are merged into it (by id; insert or ignore).
/// - `places/<build>.sqlite`: the live file is dropped and the copy with the most tiles becomes the live file. Another copy is
///   deleted; its tiles that this one lacks are fetched again by the regions that want them.
///   `places/CURRENT` and `places/<build>/common` conflict copies are deleted (the files themselves are the device's own again).
/// A copy that is not a whole database stays where it is, and drops nothing. A lone log (a conflict -wal with no database) is
/// deleted. Returns how many conflict files were dealt with.
pub fn rescue_conflicts(dir: &Path) -> usize {
    let mut n = 0;
    // regions.sqlite
    let (mains, logs) = conflict_copies(dir, "regions.sqlite");
    let good: Vec<PathBuf> = mains.iter().filter(|p| is_database(p, "regions")).cloned().collect();
    if let Some(first) = good.first() {
        let live = dir.join("regions.sqlite");
        remove_db_files(&live);
        if std::fs::rename(first, &live).is_ok() {
            n += 1;
            for ext in ["-wal", "-shm", "-journal"] {
                let _ = std::fs::remove_file(format!("{}{ext}", first.display()));
            }
            if let Ok(c) = Connection::open(&live) {
                for other in &good[1..] {
                    if merge_regions(&c, other).is_ok() {
                        remove_db_files(other);
                        n += 1;
                    }
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
        // the copy that holds the most tiles
        let mut best: Option<(usize, PathBuf)> = None;
        for p in &copies {
            if let Some(count) = merged_tile_count(p) {
                if best.as_ref().is_none_or(|(c, _)| count > *c) {
                    best = Some((count, p.clone()));
                }
            }
        }
        let Some((_, keep)) = best else { continue };
        let live = places.join(format!("{build}.sqlite"));
        remove_db_files(&live);
        if std::fs::rename(&keep, &live).is_ok() {
            n += 1;
            for ext in ["-wal", "-shm", "-journal"] {
                let _ = std::fs::remove_file(format!("{}{ext}", keep.display()));
            }
            for p in copies.iter().filter(|p| **p != keep && merged_tile_count(p).is_some()) {
                remove_db_files(p);
                n += 1;
            }
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
