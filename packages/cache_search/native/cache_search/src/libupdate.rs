//! Library updates: the snapshot manifest of a library (what a Qdrant server needs to cut a partial snapshot for
//! it), the `library_manifest` job body (the same manifest, written to a file, with the library closed in every
//! handle meanwhile) and the `update_library` job body (apply a partial snapshot to the shard folder).
//!
//! Both jobs end the same way: one read-only open of the library, which is the check that it opens and whose
//! shard is handed to the handles that had the library open (see `libreg`); there is no second open.
//!
//! Facts from the Qdrant sources at the pinned rev (see DESIGN.md, Libraries / Updates):
//! - `EdgeShard::snapshot_manifest` exists only on the read-write `EdgeShard`; `ReadOnlyEdgeShard` has none.
//!   `EdgeShard::load` is a write: it saves `edge_config.json`, replays the WAL and may create an appendable
//!   segment. So [`library_manifest`] refuses to run while the library is open in this process; the
//!   `library_manifest` job closes the library first, as `update_library` does.
//! - `EdgeShard::recover_partial_snapshot(shard_path, current_manifest, unpacked_dir, snapshot_manifest)` takes
//!   the snapshot UNPACKED (not the archive), merges it into `shard_path` by moving files, and finishes with a
//!   read-write `EdgeShard::load`, which it returns. It is not atomic. Making it atomic with a hard-link staging
//!   copy was evaluated and NOT shipped: the merge (fs_extra's `move_dir`) and the load both write into existing
//!   inodes, which hard links would share with the original (DESIGN.md, Libraries / Updates; the
//!   `hard_link_staging_*` tests in tests/update_ffi.rs measure it).
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
    let (json, n) = load_manifest_json(library)?;
    write_segments_manifest(library)?;
    Ok((json, n))
}

/// The read-write load and the manifest as JSON (no checks, no guard: the caller owns the library).
fn load_manifest_json(library: &Path) -> Result<(String, usize)> {
    let shard = EdgeShard::load(library, None).map_err(|e| op("loading the shard", e))?;
    let manifest = shard.snapshot_manifest().map_err(|e| op("reading the snapshot manifest", e))?;
    drop(shard);
    // With sorted keys: the manifest holds hash maps, whose order changes from run to run, and the same library
    // should give the same bytes every time.
    let value = serde_json::to_value(&manifest).map_err(|e| Error::internal(format!("serialising the manifest: {e}")))?;
    let json = serde_json::to_string(&sort_keys(value)).map_err(|e| Error::internal(format!("serialising the manifest: {e}")))?;
    Ok((json, manifest.len()))
}

/// The same JSON with every object's keys in sorted order (rebuilt in order, so it holds whether or not
/// `serde_json` keeps insertion order).
fn sort_keys(v: serde_json::Value) -> serde_json::Value {
    use serde_json::Value;
    match v {
        Value::Object(m) => {
            let mut entries: Vec<(String, Value)> = m.into_iter().collect();
            entries.sort_by(|a, b| a.0.cmp(&b.0));
            Value::Object(entries.into_iter().map(|(k, v)| (k, sort_keys(v))).collect())
        }
        Value::Array(a) => Value::Array(a.into_iter().map(sort_keys).collect()),
        other => other,
    }
}

/// Steps of a `library_manifest` job, as `done`/`total` progress: closed, shard loaded and manifest computed,
/// manifest written to `out_path`, `segments_manifest.json` rewritten, library reopened (checked).
pub const MANIFEST_STEPS: u64 = 5;

/// A checked `library_manifest` request.
pub struct ManifestRequest {
    pub library: PathBuf,
    pub out: PathBuf,
    /// Test hook (not in the header): sleep this long, cancellably, before the read-write load.
    pub hold_ms: u64,
}

/// Check the job parameters without touching the library: the library folder has segments, `out_path` is a
/// file path whose folder exists and which is not inside the library folder.
pub fn prepare_manifest(library_path: &str, out_path: &str, hold_ms: u64) -> Result<ManifestRequest> {
    if library_path.is_empty() || out_path.is_empty() {
        return Err(Error::bad_json("library_path and out_path must not be empty"));
    }
    let library = PathBuf::from(library_path);
    if !library.is_dir() {
        return Err(Error::not_found(format!("library folder {} not found", library.display())));
    }
    segment_dirs(&library)?;
    let out = PathBuf::from(out_path);
    if out.is_dir() {
        return Err(Error::bad_json(format!("out_path {} is a folder", out.display())));
    }
    let parent = out.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    let parent = std::fs::canonicalize(parent)
        .map_err(|_| Error::not_found(format!("the folder of out_path {} does not exist", out.display())))?;
    let lib_canon = std::fs::canonicalize(&library).map_err(|e| op("resolving library_path", e))?;
    if parent.starts_with(&lib_canon) {
        return Err(Error::bad_json("out_path must not be inside the library folder"));
    }
    Ok(ManifestRequest { library, out, hold_ms })
}

/// Run a `library_manifest` job on a library the caller has marked as updating.
///
/// Like [`apply_update`] it closes the library in every handle first, so search skips it meanwhile, then does
/// what [`library_manifest`] does (the read-write load, which writes to the folder), writes the JSON to the
/// out file (a temporary file next to it, renamed), rewrites `segments_manifest.json`, and opens the library
/// read-only once, handing that shard to the handles. Cancelling is honoured before the read-write load starts
/// and then ignored (the library is reopened unchanged in the first case).
pub fn apply_manifest(
    req: &ManifestRequest,
    entry: &LibEntry,
    progress: &dyn Fn(u64, u64),
    cancelled: &dyn Fn() -> bool,
) -> Result<Outcome> {
    ensure_init();
    progress(0, MANIFEST_STEPS);
    if !entry.close_all(cancelled)? || cancelled() {
        return Ok(Outcome::Cancelled);
    }
    progress(1, MANIFEST_STEPS);
    if !hold(req.hold_ms, cancelled) {
        return Ok(Outcome::Cancelled);
    }
    let (json, _n) = load_manifest_json(&req.library)?;
    progress(2, MANIFEST_STEPS);
    let name = req.out.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = req.out.with_file_name(format!(".{name}.{}.tmp", std::process::id()));
    std::fs::write(&tmp, json.as_bytes()).map_err(|e| op(&format!("writing {}", tmp.display()), e))?;
    if let Err(e) = std::fs::rename(&tmp, &req.out) {
        let _ = std::fs::remove_file(&tmp);
        return Err(op(&format!("writing {}", req.out.display()), e));
    }
    progress(3, MANIFEST_STEPS);
    write_segments_manifest(&req.library)?;
    progress(4, MANIFEST_STEPS);
    hand_back_open(&req.library, entry)?;
    progress(5, MANIFEST_STEPS);
    Ok(Outcome::Done)
}

/// Open the library read-only once and hand that shard to every handle's cell the job closed (see `libreg`).
/// This open is the job's check that the library opens; there is no second open.
fn hand_back_open(library: &Path, entry: &LibEntry) -> Result<()> {
    let shard = library::open_shard_for_handoff(library, &entry.vectors())?;
    entry.hand_back(&shard);
    Ok(())
}

/// Test hook: wait `ms`, cancellably. `false` when cancelled (also checked once after the wait).
fn hold(ms: u64, cancelled: &dyn Fn() -> bool) -> bool {
    let mut waited = 0;
    while waited < ms {
        if cancelled() {
            return false;
        }
        std::thread::sleep(Duration::from_millis(10));
        waited += 10;
    }
    !cancelled()
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
    if !hold(req.hold_ms, cancelled) {
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
