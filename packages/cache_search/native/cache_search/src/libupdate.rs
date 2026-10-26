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
//!   read-write `EdgeShard::load`, which it returns. It is not atomic, and it writes into files that already
//!   exist. So `update_library` never runs it on the library: it runs it on a REAL copy of the library (no hard
//!   links: the merge's `fs_extra::dir::move_dir` and the load both write into existing inodes, which links would
//!   share with the original; DESIGN.md, Libraries / Updates; the `hard_link_staging_*` tests in
//!   tests/update_ffi.rs measure it) and swaps the copy in with two renames. See [`apply_update`].
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

/// Steps of an `update_library` job, as `done`/`total` progress: closed, snapshot unpacked and checked, the
/// staging copy updated (copied, snapshot applied, `segments_manifest.json` rewritten), swapped in, library
/// opened once at its final path (checked).
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
    library::check_not_damaged(&library, false)?;
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
    // a damaged library (a segment whose files are gone) is refused before anything is closed or written
    library::check_not_damaged(&req.library, true)?;
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

/// Test hooks of an `update_library` job (none of them is in the header).
#[derive(Default, Clone, Debug)]
pub struct TestHooks {
    /// Sleep this long, cancellably, before the staging copy.
    pub hold_ms: u64,
    /// While this file exists, wait (at most two minutes, not cancellable) after the staging copy is updated and
    /// before the swap.
    pub hold_swap_file: Option<String>,
    /// Use this instead of what statvfs says is available.
    pub fake_available_bytes: Option<u64>,
    /// Fail at a named point: "after_copy", "before_swap" or "after_swap".
    pub fail_at: Option<String>,
}

impl TestHooks {
    fn inject(&self, point: &str) -> Result<()> {
        if self.fail_at.as_deref() == Some(point) {
            return Err(Error::internal(format!("injected failure {point}")));
        }
        Ok(())
    }
}

/// A checked `update_library` request.
pub struct UpdateRequest {
    pub library: PathBuf,
    pub snapshot: PathBuf,
    pub current: SnapshotManifest,
    pub hooks: TestHooks,
}

/// Check the job parameters without touching the library: the three paths exist, the manifest parses, and it
/// describes exactly the segments that are on disk (a wrong manifest would make the merge delete or keep the
/// wrong segments).
pub fn prepare(library_path: &str, snapshot_path: &str, manifest_path: &str, hooks: TestHooks) -> Result<UpdateRequest> {
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
    library::check_not_damaged(&library, false)?;
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
    Ok(UpdateRequest { library, snapshot, current, hooks })
}

/// Removes a folder when dropped.
struct RemoveDir(PathBuf);

impl Drop for RemoveDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn sibling(library: &Path, suffix: &str) -> Result<PathBuf> {
    let name = library.file_name().ok_or_else(|| Error::bad_json("library_path has no folder name"))?;
    let parent = library.parent().filter(|p| !p.as_os_str().is_empty()).unwrap_or_else(|| Path::new("."));
    Ok(parent.join(format!("{}{suffix}", name.to_string_lossy())))
}

/// Where the snapshot is unpacked: a sibling of the library folder (the merge moves files, so it must be on the
/// same file system).
fn unpack_dir(library: &Path) -> Result<PathBuf> {
    sibling(library, ".cs-update-tmp")
}

/// Suffix of the staging folder: the real copy of the library that the update is applied to.
pub const STAGE_SUFFIX: &str = ".cs-stage";
/// Suffix of the folder the old library is renamed to during the swap.
pub const OLD_SUFFIX: &str = ".cs-old";

/// The staging folder beside a library: `<library>.cs-stage`.
pub fn stage_path(library: &Path) -> Result<PathBuf> {
    sibling(library, STAGE_SUFFIX)
}

/// The folder the old library is parked in during the swap: `<library>.cs-old`.
pub fn old_path(library: &Path) -> Result<PathBuf> {
    sibling(library, OLD_SUFFIX)
}

// ---------------------------------------------------------------------------------------------------------
// Free space

/// The smallest safety margin of the free-space check: 256 MiB.
pub const MARGIN_MIN_BYTES: u64 = 256 * 1024 * 1024;
/// The margin as a share of the library size: 5 percent. The margin is the larger of this and
/// [`MARGIN_MIN_BYTES`]. It covers the filesystem's own overhead (directories, partly used blocks), the files the
/// load adds, and other writers on the same disk.
pub const MARGIN_PERCENT: u64 = 5;

/// `max(5% of the library size, 256 MiB)`.
pub fn margin_for(library_bytes: u64) -> u64 {
    (library_bytes / 100 * MARGIN_PERCENT).max(MARGIN_MIN_BYTES)
}

/// The sum of the file sizes under `dir` (symbolic links are not followed; a link counts by its own size).
pub fn tree_size(dir: &Path) -> Result<u64> {
    let mut total = 0u64;
    let rd = std::fs::read_dir(dir).map_err(|e| op(&format!("reading {}", dir.display()), e))?;
    for ent in rd {
        let ent = ent.map_err(|e| op(&format!("reading {}", dir.display()), e))?;
        let md = ent.metadata().map_err(|e| op(&format!("reading {}", ent.path().display()), e))?;
        if md.is_dir() {
            total += tree_size(&ent.path())?;
        } else {
            total += md.len();
        }
    }
    Ok(total)
}

/// Bytes available to an unprivileged writer on the file system that holds `path` (unix: `statvfs`, `f_bavail`
/// blocks of `f_frsize` bytes).
#[cfg(unix)]
pub fn available_bytes(path: &Path) -> Result<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|_| Error::bad_json("path contains a NUL byte"))?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is a valid NUL-terminated path and `st` a valid, writable statvfs.
    let rc = unsafe { libc::statvfs(c.as_ptr(), &mut st) };
    if rc != 0 {
        return Err(op(&format!("reading the free space of {}", path.display()), std::io::Error::last_os_error()));
    }
    Ok((st.f_bavail as u64).saturating_mul(st.f_frsize as u64))
}

/// Bytes available to the calling user on the volume that holds `path` (Windows: `GetDiskFreeSpaceExW`, which
/// honours per-user quotas).
#[cfg(windows)]
pub fn available_bytes(path: &Path) -> Result<u64> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
    if wide.contains(&0) {
        return Err(Error::bad_json("path contains a NUL byte"));
    }
    wide.push(0);
    let mut free_to_caller: u64 = 0;
    // SAFETY: `wide` is a valid NUL-terminated UTF-16 path and `free_to_caller` a valid, writable u64; the two
    // optional out-pointers are null, which the API allows.
    let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut free_to_caller, std::ptr::null_mut(), std::ptr::null_mut()) };
    if ok == 0 {
        return Err(op(&format!("reading the free space of {}", path.display()), std::io::Error::last_os_error()));
    }
    Ok(free_to_caller)
}

/// Other platforms have no free-space check.
#[cfg(not(any(unix, windows)))]
pub fn available_bytes(path: &Path) -> Result<u64> {
    Err(op(
        &format!("reading the free space of {}", path.display()),
        std::io::Error::new(std::io::ErrorKind::Unsupported, "free-space check is not supported on this platform"),
    ))
}

/// The free-space check of an update: needed = library size + partial snapshot size + margin must fit in what
/// is available on the library's file system. Creates and changes nothing. Fails with `no_space`.
fn check_space(req: &UpdateRequest) -> Result<()> {
    let lib_bytes = tree_size(&req.library)?;
    let snap_bytes = std::fs::metadata(&req.snapshot).map_err(|e| op(&format!("reading {}", req.snapshot.display()), e))?.len();
    let margin = margin_for(lib_bytes);
    let needed = lib_bytes.saturating_add(snap_bytes).saturating_add(margin);
    let available = match req.hooks.fake_available_bytes {
        Some(n) => n,
        None => available_bytes(&req.library)?,
    };
    if needed > available {
        return Err(Error::no_space(
            format!(
                "not enough free space to update {}: {needed} bytes needed (library {lib_bytes} + snapshot {snap_bytes} + margin {margin}), {available} available",
                req.library.display()
            ),
            needed,
            available,
        ));
    }
    Ok(())
}

// ---------------------------------------------------------------------------------------------------------
// The staging copy

/// A real copy of the directory tree `src` at `dst` (which must not exist): every file is read and written to a
/// new file, so nothing is shared with the original (no hard links, no reflinks asked for). Returns the bytes
/// copied. Only regular files and folders are copied: anything else (a symbolic link) is `unsupported`, because
/// a shard folder has none. On an error the partial copy is left for the caller to delete.
pub fn copy_tree(src: &Path, dst: &Path) -> Result<u64> {
    std::fs::create_dir(dst).map_err(|e| op(&format!("creating {}", dst.display()), e))?;
    let mut total = 0u64;
    let rd = std::fs::read_dir(src).map_err(|e| op(&format!("reading {}", src.display()), e))?;
    for ent in rd {
        let ent = ent.map_err(|e| op(&format!("reading {}", src.display()), e))?;
        let from = ent.path();
        let to = dst.join(ent.file_name());
        let ft = ent.file_type().map_err(|e| op(&format!("reading {}", from.display()), e))?;
        if ft.is_dir() {
            total += copy_tree(&from, &to)?;
        } else if ft.is_file() {
            total += std::fs::copy(&from, &to).map_err(|e| op(&format!("copying {}", from.display()), e))?;
        } else {
            return Err(Error::unsupported(format!("{} is not a regular file or folder: cannot copy it", from.display())));
        }
    }
    Ok(total)
}

/// Flush every file and folder under `dir` to disk, so the renames that follow cannot make a half-written copy
/// the library after a crash.
fn sync_tree(dir: &Path) -> Result<()> {
    let rd = std::fs::read_dir(dir).map_err(|e| op(&format!("reading {}", dir.display()), e))?;
    for ent in rd {
        let ent = ent.map_err(|e| op(&format!("reading {}", dir.display()), e))?;
        let p = ent.path();
        if ent.file_type().map_err(|e| op(&format!("reading {}", p.display()), e))?.is_dir() {
            sync_tree(&p)?;
        } else {
            sync_file(&p).map_err(|e| op(&format!("flushing {}", p.display()), e))?;
        }
    }
    sync_dir(dir)
}

/// Flush one file. Windows needs write access for `FlushFileBuffers`, so the file is opened for writing there
/// (without truncating or changing it); unix flushes a read-only descriptor fine.
fn sync_file(path: &Path) -> std::io::Result<()> {
    #[cfg(windows)]
    let f = std::fs::OpenOptions::new().write(true).open(path)?;
    #[cfg(not(windows))]
    let f = std::fs::File::open(path)?;
    f.sync_all()
}

/// Flush a folder's entries (renames and creations in it). Windows cannot open a folder as a file and NTFS
/// journals its metadata, so there it does nothing.
#[cfg(not(windows))]
fn sync_dir(dir: &Path) -> Result<()> {
    std::fs::File::open(dir).and_then(|f| f.sync_all()).map_err(|e| op(&format!("flushing {}", dir.display()), e))
}

#[cfg(windows)]
fn sync_dir(_dir: &Path) -> Result<()> {
    Ok(())
}

// ---------------------------------------------------------------------------------------------------------
// Crash leftovers

/// Whether the library folder is complete, as far as the code can check. All of:
/// 1. `segments_manifest.json` is a file holding a JSON object that lists at least one segment;
/// 2. every segment it lists is a folder under `segments/`;
/// 3. the library opens read-only (the open that search uses, with the cheap scroll profile; it is not counted by
///    `shard_open_count` and it keeps nothing open) and the open finds every listed segment (the open drops a
///    segment whose files are gone without an error, so the count is compared).
/// It cannot tell a library with the right contents from one with other contents; only that it is whole enough to
/// be opened.
pub fn library_is_complete(library: &Path) -> bool {
    let Some(l) = library::manifest_listed(library) else { return false };
    l.count > 0 && l.present == l.count && library::opens_read_only(library).is_ok_and(|n| n == l.count)
}

/// Whether a staging folder or an old-library folder sits beside the library (a cheap look, no reading).
pub fn has_leftovers(library: &Path) -> bool {
    [stage_path(library), old_path(library)].into_iter().flatten().any(|p| std::fs::symlink_metadata(p).is_ok())
}

/// Put right what a crash during an update can leave beside the library, and report what was done. Rules:
/// - a leftover `<library>.cs-stage` is always deleted (it is a copy the update had not swapped in);
/// - `<library>.cs-old` with a complete `library` (see [`library_is_complete`]): the swap finished, so
///   `.cs-old` is deleted;
/// - `<library>.cs-old` and no `library` (a crash between the two renames): `.cs-old` is renamed back to `library`;
/// - `<library>.cs-old` with a `library` that is not complete (the swap finished but the new library is
///   unusable): `library` is deleted and `.cs-old` renamed back.
/// The caller must own the library (no open handle in this process, no update running); this cannot know about
/// other processes.
pub fn recover_leftovers(library: &Path) -> Result<Vec<String>> {
    let mut done = Vec::new();
    let (stage, old) = (stage_path(library)?, old_path(library)?);
    if std::fs::symlink_metadata(&stage).is_ok() {
        std::fs::remove_dir_all(&stage).map_err(|e| op(&format!("deleting {}", stage.display()), e))?;
        done.push(format!("deleted {}", stage.display()));
    }
    if std::fs::symlink_metadata(&old).is_ok() {
        if library.is_dir() {
            if library_is_complete(library) {
                std::fs::remove_dir_all(&old).map_err(|e| op(&format!("deleting {}", old.display()), e))?;
                done.push(format!("deleted {}", old.display()));
            } else {
                std::fs::remove_dir_all(library).map_err(|e| op(&format!("deleting {}", library.display()), e))?;
                std::fs::rename(&old, library).map_err(|e| op(&format!("restoring {}", library.display()), e))?;
                done.push(format!("{} was not complete: restored it from {}", library.display(), old.display()));
            }
        } else {
            std::fs::rename(&old, library).map_err(|e| op(&format!("restoring {}", library.display()), e))?;
            done.push(format!("restored {} from {}", library.display(), old.display()));
        }
        if let Some(parent) = library.parent().filter(|p| !p.as_os_str().is_empty()) {
            let _ = sync_dir(parent);
        }
    }
    Ok(done)
}

/// [`recover_leftovers`] when there is anything to recover, with the library marked as updating meanwhile
/// (nothing in this process opens it). Does nothing when the library is busy (an update or an index build owns
/// it) or when there are no leftovers.
pub fn recover_if_leftovers(library: &Path) -> Result<()> {
    if library.as_os_str().is_empty() || !has_leftovers(library) {
        return Ok(());
    }
    let entry = libreg::entry_for(library);
    // leftovers beside a library that a handle has open can only come from an update that is running, and
    // that holds the update mark, so `begin_update` refuses here
    let Ok(_guard) = entry.begin_update() else { return Ok(()) };
    recover_leftovers(library).map(|_| ())
}

// ---------------------------------------------------------------------------------------------------------
// The job

/// Run the update on a library the caller has marked as updating (it holds the `UpdateGuard`).
///
/// The library is never written to by the merge. The update is applied to a REAL copy of it and swapped in:
///
/// 0. space check: library size + snapshot size + margin must fit on the library's file system, else `no_space`
///    (nothing has been created or changed);
/// 1. close: wait for background opens, take the shard out of every open handle's cell;
/// 2. unpack the snapshot next to the library and check it is a partial snapshot;
/// 3. copy the library to `<library>.cs-stage` (same parent, so the swap is a rename), apply the snapshot to the
///    copy with `recover_partial_snapshot`, rewrite its `segments_manifest.json`, flush it to disk;
/// 4. swap: rename `library` to `<library>.cs-old`, rename the copy to `library`;
/// 5. open `library` read-only once: that checks it opens, and the opened shard is handed to every handle that
///    had the library open (no second open). Then `<library>.cs-old` is deleted (best effort; a leftover is
///    removed by [`recover_leftovers`]).
///
/// Cancelling is honoured before step 3 starts and then ignored. Until the swap the library is not touched:
/// any failure before it deletes the copy and the unpack folder and leaves the library as it was (the handles
/// open it again). If the open in step 5 fails, the swap is undone (the new library is deleted, the old one
/// renamed back) and the job fails.
///
/// Why step 5 opens the library AFTER the swap and not the copy before it: a `ReadOnlyEdgeShard` keeps the path
/// it was opened with (`ReadOnlyEdgeShard::path`, `LocalSegmentEnumerator`, and every `ReadOnlySegment` keeps its
/// `segment_path`, which `live_reload` and `config_reload` reopen files by). A shard opened at
/// `<library>.cs-stage` would keep reporting and re-resolving that name after the rename. Opened at the final
/// path it is correct whatever happens to the stage name. Open files and mmaps would survive the rename, but the
/// stored paths would not, and the Edge API does not document which operations use them.
pub fn apply_update(
    req: &UpdateRequest,
    entry: &LibEntry,
    progress: &dyn Fn(u64, u64),
    cancelled: &dyn Fn() -> bool,
) -> Result<Outcome> {
    ensure_init();
    // a damaged library (a segment whose files are gone) is refused before anything is closed or written
    library::check_not_damaged(&req.library, true)?;
    progress(0, STEPS);
    // 0: before anything is closed or created
    check_space(req)?;
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
    if !hold(req.hooks.hold_ms, cancelled) {
        return Ok(Outcome::Cancelled);
    }
    // 3: no cancelling from here. The copy is deleted on any failure (and a stale one from a crash first).
    let stage = stage_path(&req.library)?;
    let old = old_path(&req.library)?;
    let _ = std::fs::remove_dir_all(&stage);
    let _stage_cleanup = RemoveDir(stage.clone());
    copy_tree(&req.library, &stage)?;
    req.hooks.inject("after_copy")?;
    let shard = EdgeShard::recover_partial_snapshot(&stage, &req.current, &tmp, &snapshot_manifest)
        .map_err(|e| op("applying the partial snapshot", e))?;
    // recover_partial_snapshot returns the shard it loaded read-write; it is closed (and flushed) here
    drop(shard);
    write_segments_manifest(&stage)?;
    sync_tree(&stage)?;
    progress(3, STEPS);
    // test hook: a pause with the copy ready and the library untouched
    if let Some(f) = &req.hooks.hold_swap_file {
        let t0 = std::time::Instant::now();
        while Path::new(f).exists() && t0.elapsed() < Duration::from_secs(120) {
            std::thread::sleep(Duration::from_millis(10));
        }
    }
    req.hooks.inject("before_swap")?;
    // 4: the swap. The library is not changed until the first rename succeeds.
    let _ = std::fs::remove_dir_all(&old);
    std::fs::rename(&req.library, &old).map_err(|e| op("swapping: moving the library aside", e))?;
    if let Err(e) = std::fs::rename(&stage, &req.library) {
        let back = std::fs::rename(&old, &req.library);
        return Err(op(
            &format!("swapping: moving the copy into place (library {})", if back.is_ok() { "restored" } else { "NOT restored: it is in the .cs-old folder" }),
            e,
        ));
    }
    if let Some(parent) = req.library.parent().filter(|p| !p.as_os_str().is_empty()) {
        let _ = sync_dir(parent);
    }
    progress(4, STEPS);
    // 5: the one read-only open, at the final path; it is the check and the shard the handles get
    let opened = req.hooks.inject("after_swap").and_then(|_| hand_back_open(&req.library, entry));
    if let Err(e) = opened {
        // undo the swap: the new library goes to the staging name (deleted by `_stage_cleanup`), the old one comes back
        let undone = std::fs::rename(&req.library, &stage).and_then(|_| std::fs::rename(&old, &req.library));
        return Err(match undone {
            Ok(()) => Error::new(e.code, format!("{}; the update was undone and the library is as it was", e.message)),
            Err(u) => Error::io(format!("{}; undoing the swap failed ({u}): the old library is in {}", e.message, old.display())),
        });
    }
    // the swap is good: the old library goes (best effort; a failure leaves a .cs-old that the next open or update deletes)
    let _ = std::fs::remove_dir_all(&old);
    progress(5, STEPS);
    Ok(Outcome::Done)
}
