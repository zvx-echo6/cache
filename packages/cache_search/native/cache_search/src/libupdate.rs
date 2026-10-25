//! Library updates: the snapshot manifest of a library (what a Qdrant server needs to cut a partial snapshot for
//! it) and the `update_library` job body (apply a partial snapshot to the shard folder).
//!
//! The job ends with one read-only open of the library, which is the check that it opens and whose shard is handed
//! to the handles that had the library open (see `libreg`); there is no second open.
//!
//! Facts from the Qdrant sources at the pinned rev (see DESIGN.md, Libraries / Updates):
//! - `EdgeShard::snapshot_manifest` exists only on the read-write `EdgeShard`; `ReadOnlyEdgeShard` has none.
//!   `EdgeShard::load` is a write: it saves `edge_config.json`, replays the WAL and may create an appendable
//!   segment. So [`library_manifest`] refuses to run while the library is open in this process.
//! - `EdgeShard::recover_partial_snapshot(shard_path, current_manifest, unpacked_dir, snapshot_manifest)` takes
//!   the snapshot UNPACKED (not the archive), merges it into `shard_path` by moving files, and finishes with a
//!   read-write `EdgeShard::load`, which it returns. It is not atomic.
//! - `current_manifest` is the manifest the snapshot was cut against, which is the library's own manifest at
//!   that time; the job reads it from `snapshot_manifest_path`. `snapshot_manifest` comes from the unpacked
//!   snapshot itself (`SnapshotManifest::load_from_snapshot`).

use crate::error::{Error, ErrorCode, Result};
use crate::index::Outcome;
use crate::libreg::{self, LibEntry};
use crate::library::{self, ensure_init, write_segments_manifest};
use edge::EdgeShard;
use shard::snapshots::snapshot_manifest::{RecoveryType, SnapshotManifest};
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Steps of an `update_library` job, as `done`/`total` progress: closed, snapshot unpacked and checked, applied,
/// `segments_manifest.json` rewritten, library reopened (checked).
pub const STEPS: u64 = 5;

fn busy(m: &str) -> Error {
    Error::new(ErrorCode::Busy, m)
}

fn op(what: &str, e: impl std::fmt::Display) -> Error {
    Error::io(format!("{what}: {e}"))
}

/// The segment folder names under `<library>/segments` (hidden entries left out).
fn segment_dirs(library: &Path) -> Result<BTreeSet<String>> {
    let dir = library.join("segments");
    let rd = std::fs::read_dir(&dir).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            Error::not_found(format!("{} has no segments directory", library.display()))
        } else {
            op(&format!("reading {}", dir.display()), e)
        }
    })?;
    let mut out = BTreeSet::new();
    for ent in rd {
        let ent = ent.map_err(|e| op("reading segments", e))?;
        let name = ent.file_name().to_string_lossy().into_owned();
        if !name.starts_with('.') && ent.path().is_dir() {
            out.insert(name);
        }
    }
    Ok(out)
}

/// The library's snapshot manifest as JSON text (the body of `POST .../snapshot/partial/create`) and the number
/// of segments in it.
///
/// This opens the folder with the READ-WRITE `EdgeShard`, which writes to it (see the module comment), so it must
/// only run while the library is closed. It refuses (`busy`) when the library is open, being opened, being
/// indexed or being updated in this process; it cannot know about other processes. Afterwards it rewrites
/// `segments_manifest.json` so the file matches the segments on disk (the load may have added an empty
/// appendable segment).
pub fn library_manifest(library: &Path) -> Result<(String, usize)> {
    ensure_init();
    if !library.is_dir() {
        return Err(Error::not_found(format!("library folder {} not found", library.display())));
    }
    segment_dirs(library)?;
    let entry = libreg::entry_for(library);
    // While this guard exists nothing in this process can open the library or start an index build.
    let _guard = entry.begin_update()?;
    if entry.open_shards() {
        return Err(busy("the library is open; the manifest needs a read-write load, which only runs while it is closed"));
    }
    let shard = EdgeShard::load(library, None).map_err(|e| op("loading the shard", e))?;
    let manifest = shard.snapshot_manifest().map_err(|e| op("reading the snapshot manifest", e))?;
    drop(shard);
    let json = serde_json::to_string(&manifest).map_err(|e| Error::internal(format!("serialising the manifest: {e}")))?;
    write_segments_manifest(library)?;
    Ok((json, manifest.len()))
}

/// Open the library read-only once and hand that shard to every handle's cell the job closed (see `libreg`).
/// This open is the job's check that the library opens; there is no second open.
fn hand_back_open(library: &Path, entry: &LibEntry) -> Result<()> {
    let shard = library::open_shard_for_handoff(library, &entry.vectors())?;
    entry.hand_back(&shard);
    Ok(())
}

/// A checked `update_library` request.
pub struct UpdateRequest {
    pub library: PathBuf,
    pub snapshot: PathBuf,
    pub current: SnapshotManifest,
    /// Test hook (not in the header): sleep this long, cancellably, before the apply step.
    pub hold_ms: u64,
}

/// Check the job parameters without touching the library: the three paths exist, the manifest parses, and it
/// describes exactly the segments that are on disk (a wrong manifest would make the merge delete or keep the
/// wrong segments).
pub fn prepare(library_path: &str, snapshot_path: &str, manifest_path: &str, hold_ms: u64) -> Result<UpdateRequest> {
    if library_path.is_empty() || snapshot_path.is_empty() || manifest_path.is_empty() {
        return Err(Error::bad_json("library_path, snapshot_path and snapshot_manifest_path must not be empty"));
    }
    let library = PathBuf::from(library_path);
    if !library.is_dir() {
        return Err(Error::not_found(format!("library folder {} not found", library.display())));
    }
    let snapshot = PathBuf::from(snapshot_path);
    if !snapshot.is_file() {
        return Err(Error::not_found(format!("snapshot file {} not found", snapshot.display())));
    }
    let mpath = PathBuf::from(manifest_path);
    let text = std::fs::read(&mpath).map_err(|e| {
        if e.kind() == std::io::ErrorKind::NotFound {
            Error::not_found(format!("manifest file {} not found", mpath.display()))
        } else {
            op(&format!("reading {}", mpath.display()), e)
        }
    })?;
    let current: SnapshotManifest = serde_json::from_slice(&text)
        .map_err(|e| Error::bad_json(format!("{} is not a snapshot manifest: {e}", mpath.display())))?;
    if current.is_empty() {
        return Err(Error::bad_json(format!("{} lists no segments", mpath.display())));
    }
    let listed: BTreeSet<String> = current.iter().map(|(id, _)| id.clone()).collect();
    let on_disk = segment_dirs(&library)?;
    if listed != on_disk {
        let missing: Vec<&String> = listed.difference(&on_disk).collect();
        let extra: Vec<&String> = on_disk.difference(&listed).collect();
        return Err(Error::bad_json(format!(
            "{} does not describe the library: segments in the manifest but not on disk {missing:?}, on disk but not in the manifest {extra:?}",
            mpath.display()
        )));
    }
    Ok(UpdateRequest { library, snapshot, current, hold_ms })
}

/// Removes a folder when dropped.
struct RemoveDir(PathBuf);

impl Drop for RemoveDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Where the snapshot is unpacked: a sibling of the library folder (the merge moves files, so it must be on the
/// same file system).
fn unpack_dir(library: &Path) -> Result<PathBuf> {
    let name = library.file_name().ok_or_else(|| Error::bad_json("library_path has no folder name"))?;
    let parent = library.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    Ok(parent.join(format!("{}.cs-update-tmp", name.to_string_lossy())))
}

/// Run the update on a library the caller has marked as updating (it holds the `UpdateGuard`).
///
/// Steps (progress `done` counts them, `total` is [`STEPS`]):
/// 1. close: wait for background opens, take the shard out of every open handle's cell;
/// 2. unpack the snapshot next to the library and check it is a partial snapshot;
/// 3. apply it with `recover_partial_snapshot` (after this point there is no cancelling);
/// 4. rewrite `segments_manifest.json` from the segments on disk;
/// 5. open the library read-only once: that checks it opens, and the opened shard is handed to every handle that
///    had the library open (no second open).
///
/// Cancelling is honoured before step 3 starts and then ignored. Nothing here changes the library before step 3.
/// A failure in step 3 or later can leave the folder half-merged (Qdrant's merge is not atomic); the remedy is a
/// full replace from a full snapshot.
pub fn apply_update(
    req: &UpdateRequest,
    entry: &LibEntry,
    progress: &dyn Fn(u64, u64),
    cancelled: &dyn Fn() -> bool,
) -> Result<Outcome> {
    ensure_init();
    progress(0, STEPS);
    // 1
    if !entry.close_all(cancelled)? || cancelled() {
        return Ok(Outcome::Cancelled);
    }
    progress(1, STEPS);
    // 2
    let tmp = unpack_dir(&req.library)?;
    let _ = std::fs::remove_dir_all(&tmp);
    let _cleanup = RemoveDir(tmp.clone());
    std::fs::create_dir_all(&tmp).map_err(|e| op(&format!("creating {}", tmp.display()), e))?;
    EdgeShard::unpack_snapshot(&req.snapshot, &tmp).map_err(|e| op("unpacking the snapshot", e))?;
    let snapshot_manifest = SnapshotManifest::load_from_snapshot(&tmp, Some(RecoveryType::Partial))
        .map_err(|e| Error::unsupported(format!("not a usable partial snapshot: {e}")))?;
    if snapshot_manifest.is_empty() {
        return Err(Error::unsupported("the snapshot has no segments: it is not a partial snapshot"));
    }
    // the merge moves the WAL folder; a snapshot without one would fail half-way
    if !tmp.join("wal").is_dir() {
        return Err(Error::unsupported("not a usable partial snapshot: it has no wal folder"));
    }
    progress(2, STEPS);
    // test hook: a pause before the point of no return
    let mut waited = 0;
    while waited < req.hold_ms {
        if cancelled() {
            return Ok(Outcome::Cancelled);
        }
        std::thread::sleep(Duration::from_millis(10));
        waited += 10;
    }
    if cancelled() {
        return Ok(Outcome::Cancelled);
    }
    // 3: no cancelling from here
    let shard = EdgeShard::recover_partial_snapshot(&req.library, &req.current, &tmp, &snapshot_manifest)
        .map_err(|e| op("applying the partial snapshot", e))?;
    // recover_partial_snapshot returns the shard it loaded read-write; it is closed (and flushed) here
    drop(shard);
    progress(3, STEPS);
    // 4
    write_segments_manifest(&req.library)?;
    progress(4, STEPS);
    // 5: the one read-only open; it is the check and the shard the handles get
    hand_back_open(&req.library, entry)?;
    progress(5, STEPS);
    Ok(Outcome::Done)
}
