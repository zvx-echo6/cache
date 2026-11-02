//! Syncable index snapshots, for every kind of index (ZIM PDFs now; ZIM, library, regions and places follow).
//!
//! An index is a result, not a cache: it syncs to any device that holds the same source. So it is published as an immutable
//! snapshot that can be copied between devices as plain files, and it is used only when it is complete and compatible.
//!
//! ```text
//! <indexes_dir>/<kind>/<source id>/        kind: zim-pdf | zim | library | region | places | ...; source id: percent-encoded
//!     .build/                              the writable working folder (never synced; locks live here only)
//!         publish-<build-id>/              a snapshot being staged (renamed to snap/<build-id>/ in one step)
//!     snap/<build-id>/                     published: the index files and manifest.json (written last); never written again
//! ```
//!
//! The steps of a build, in order (every kind uses the same ones): build in [`build_dir`]; [`stage`] copies the finished
//! files into a temporary folder and hashes them; [`publish`] writes `manifest.json` last and renames the folder to
//! `snap/<build-id>/`. A device that reads [`pick`] sees only complete snapshots: a folder without a manifest, with a file
//! missing or with a hash that does not match is not used (a partly synced snapshot is ignored until it is complete).
//!
//! Rules: a snapshot is usable when its manifest is there and names this kind and source id, [`Compat`] (the kind's own
//! check of format, tantivy version, tokenizer, chunker) accepts it, and every listed file has the listed size and sha256.
//! Of several usable snapshots every device takes the earliest `created`, then the lowest build id. [`gc`] removes the
//! usable ones that are neither the one in use nor the newest usable one older than it (kept as a rollback), and only on
//! this device: deletions under `snap/` never sync.
//!
//! Tantivy's reader creates `.tantivy-meta.lock` when an index is opened. [`stage`] puts an empty one in every snapshot, so
//! opening a published snapshot never writes into it; it is not listed in the manifest.

use crate::error::{Error, ErrorCode, Result};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use sha2::{Digest, Sha256};
use std::path::{Path, PathBuf};
use std::time::SystemTime;

pub const BUILD_DIR: &str = ".build";
pub const SNAP_DIR: &str = "snap";
pub const MANIFEST: &str = "manifest.json";
/// The empty file Tantivy's reader would create on open; in every snapshot, outside the manifest.
pub const META_LOCK: &str = ".tantivy-meta.lock";

// ---------------------------------------------------------------------------------------------------------
// Layout

/// A source id as one folder name: every byte except letters, digits and `._@-` is written `%XX`, and a leading `.` too (so
/// the name is never hidden, `.` or `..`). Reversible with [`decode_source_id`].
pub fn encode_source_id(id: &str) -> String {
    let mut s = String::with_capacity(id.len());
    for (i, b) in id.bytes().enumerate() {
        let plain = b.is_ascii_alphanumeric() || matches!(b, b'_' | b'@' | b'-') || (b == b'.' && i > 0);
        if plain {
            s.push(b as char);
        } else {
            s.push_str(&format!("%{b:02X}"));
        }
    }
    s
}

/// The source id a folder name stands for (`None` when it is not a name [`encode_source_id`] makes).
pub fn decode_source_id(name: &str) -> Option<String> {
    let b = name.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            out.push(u8::from_str_radix(name.get(i + 1..i + 3)?, 16).ok()?);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// `<indexes_dir>/<kind>/<encoded source id>`.
pub fn source_dir(indexes_dir: &Path, kind: &str, source_id: &str) -> PathBuf {
    indexes_dir.join(kind).join(encode_source_id(source_id))
}

pub fn build_dir(source_dir: &Path) -> PathBuf {
    source_dir.join(BUILD_DIR)
}

// ---------------------------------------------------------------------------------------------------------
// Manifest

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Tokenizer {
    pub name: String,
    pub analyzer: String,
    pub remove_long: u32,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FileEntry {
    pub path: String,
    pub size: u64,
    pub sha256: String,
}

/// `manifest.json`. `extra` holds the kind's own facts (for `zim-pdf`: zim_uuid, zim_name, pdfs, pieces, skipped).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Manifest {
    pub kind: String,
    pub source_id: String,
    /// The kind's index format version.
    pub format: u32,
    pub tantivy: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tokenizer: Option<Tokenizer>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub chunker: Option<u32>,
    /// The core build that wrote it.
    pub core: String,
    /// ISO 8601 UTC, e.g. `2026-11-02T12:00:00Z`.
    pub created: String,
    #[serde(flatten)]
    pub extra: Map<String, Value>,
    pub files: Vec<FileEntry>,
}

/// A kind's check that this core reads the snapshot (format, tantivy version, tokenizer, chunker...): `Err(why)` when not.
pub type Compat = fn(&Manifest) -> std::result::Result<(), String>;

/// Hex sha256 and size of a file.
pub fn hash_file(path: &Path) -> Result<(String, u64)> {
    use std::io::Read;
    let mut f = std::fs::File::open(path).map_err(|e| Error::io(format!("{}: {e}", path.display())))?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    let mut n = 0u64;
    loop {
        let k = f.read(&mut buf).map_err(|e| Error::io(format!("{}: {e}", path.display())))?;
        if k == 0 {
            break;
        }
        h.update(&buf[..k]);
        n += k as u64;
    }
    Ok((h.finalize().iter().map(|b| format!("{b:02x}")).collect(), n))
}

/// Read and check a snapshot folder (see the module comment). `Err` says why it is not usable. Reads only.
pub fn verify(snap: &Path, kind: &str, source_id: &str, compat: Compat) -> Result<Manifest> {
    let mpath = snap.join(MANIFEST);
    let bytes = std::fs::read(&mpath).map_err(|e| Error::io(format!("{}: {e}", mpath.display())))?;
    let m: Manifest =
        serde_json::from_slice(&bytes).map_err(|e| Error::bad_json(format!("{}: {e}", mpath.display())))?;
    if m.kind != kind || m.source_id != source_id {
        return Err(Error::bad_json(format!("{}: is the {} snapshot of {}", mpath.display(), m.kind, m.source_id)));
    }
    compat(&m).map_err(|why| Error::unsupported(format!("{}: {why}", snap.display())))?;
    for f in &m.files {
        if f.path.is_empty() || f.path.contains('/') || f.path.contains('\\') || f.path == "." || f.path == ".." {
            return Err(Error::bad_json(format!("{}: bad file name {:?}", mpath.display(), f.path)));
        }
        let (sha, size) = hash_file(&snap.join(&f.path))?;
        if size != f.size || sha != f.sha256 {
            return Err(Error::io(format!("{}: {} does not match its manifest", snap.display(), f.path)));
        }
    }
    Ok(m)
}

/// The folder names under `snap/`, sorted.
pub fn list(source_dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(source_dir.join(SNAP_DIR))
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

/// The snapshot chosen for a source.
pub struct Picked {
    pub name: String,
    pub dir: PathBuf,
    pub manifest: Manifest,
    /// Every usable snapshot of the source as (created, name), earliest first (the chosen one is the first).
    pub usable: Vec<(String, String)>,
}

/// The snapshot every device uses for the source: of the usable ones, the earliest `created`, then the lowest build id.
/// Verifies (hashes) every candidate, so call it off the main thread.
pub fn pick(source_dir: &Path, kind: &str, source_id: &str, compat: Compat) -> Option<Picked> {
    let mut usable: Vec<(String, String, Manifest)> = Vec::new();
    for name in list(source_dir) {
        if let Ok(m) = verify(&source_dir.join(SNAP_DIR).join(&name), kind, source_id, compat) {
            usable.push((m.created.clone(), name, m));
        }
    }
    usable.sort_by(|a, b| (&a.0, &a.1).cmp(&(&b.0, &b.1)));
    let list: Vec<(String, String)> = usable.iter().map(|(c, n, _)| (c.clone(), n.clone())).collect();
    usable.into_iter().next().map(|(_, name, m)| Picked {
        dir: source_dir.join(SNAP_DIR).join(&name),
        name,
        manifest: m,
        usable: list,
    })
}

/// Remove, on this device only, the usable snapshots that are neither the one in use nor the newest usable one older than it
/// (kept as a rollback: an older core may still need it). Snapshots that are not usable here are left alone (another core
/// may read them). Returns the names removed.
pub fn gc(source_dir: &Path, picked: &Picked) -> Vec<String> {
    let in_use = picked.usable.iter().position(|(_, n)| *n == picked.name).unwrap_or(0);
    let previous = in_use.checked_sub(1);
    let mut removed = Vec::new();
    for (k, (_, name)) in picked.usable.iter().enumerate() {
        if k == in_use || Some(k) == previous {
            continue;
        }
        if std::fs::remove_dir_all(source_dir.join(SNAP_DIR).join(name)).is_ok() {
            removed.push(name.clone());
        }
    }
    removed
}

// ---------------------------------------------------------------------------------------------------------
// Publishing

/// A new build id: sortable (UTC time first), unlikely to repeat across devices.
pub fn new_build_id() -> String {
    let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default();
    let (y, mo, d, h, mi, s) = civil(now.as_secs());
    let salt = (now.subsec_nanos() as u64).wrapping_mul(0x9E37_79B9_7F4A_7C15) ^ ((std::process::id() as u64) << 20);
    format!("{y:04}{mo:02}{d:02}T{h:02}{mi:02}{s:02}Z-{:06x}", (salt >> 8) & 0xFF_FFFF)
}

/// The current UTC time as `2026-11-02T12:00:00Z`.
pub fn iso_now() -> String {
    let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).unwrap_or_default().as_secs();
    let (y, mo, d, h, mi, s) = civil(now);
    format!("{y:04}-{mo:02}-{d:02}T{h:02}:{mi:02}:{s:02}Z")
}

/// (year, month, day, hour, minute, second) of a Unix time in UTC.
fn civil(t: u64) -> (i64, u32, u32, u32, u32, u32) {
    let days = (t / 86400) as i64;
    let rem = t % 86400;
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d, (rem / 3600) as u32, (rem % 3600 / 60) as u32, (rem % 60) as u32)
}

/// A snapshot being written: its files are moved in and hashed, `manifest.json` is not there yet.
pub struct Stage {
    pub build_id: String,
    pub dir: PathBuf,
    pub files: Vec<FileEntry>,
    pub bytes: u64,
    /// Where the files came from, to put them back if the stage is aborted.
    from: PathBuf,
}

/// MOVE the files of the finished `build` folder, except those in `exclude` (locks, bookkeeping), into
/// `<build>/publish-<build id>/` (inside the working folder, so sync never sees it; a rename on the same file system, so
/// nothing is copied) and hash them as they are read. `progress(done, total)` after each file; `cancelled()` before each one:
/// when it is true, or on an error, the files are put back (the build stays as it was) and `None` comes back. Also puts the
/// empty [`META_LOCK`] in.
pub fn stage(
    build: &Path,
    exclude: &[&str],
    progress: &dyn Fn(u64, u64),
    cancelled: &dyn Fn() -> bool,
) -> Result<Option<Stage>> {
    let build_id = new_build_id();
    let dir = build.join(format!("publish-{build_id}"));
    let mut moved: Vec<String> = Vec::new();
    let put_back = |moved: &[String]| {
        for n in moved {
            let _ = std::fs::rename(dir.join(n), build.join(n));
        }
        let _ = std::fs::remove_dir_all(&dir);
    };
    let mut run = || -> Result<Option<(Vec<FileEntry>, u64)>> {
        std::fs::create_dir_all(&dir).map_err(|e| Error::io(format!("{}: {e}", dir.display())))?;
        let mut names: Vec<String> = std::fs::read_dir(build)
            .map_err(|e| Error::io(format!("{}: {e}", build.display())))?
            .flatten()
            .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
            .map(|e| e.file_name().to_string_lossy().into_owned())
            .filter(|n| !exclude.contains(&n.as_str()) && n != META_LOCK && n != MANIFEST)
            .collect();
        names.sort();
        let total = names.len() as u64;
        progress(0, total);
        let (mut files, mut bytes) = (Vec::new(), 0u64);
        for (k, n) in names.iter().enumerate() {
            if cancelled() {
                return Ok(None);
            }
            std::fs::rename(build.join(n), dir.join(n)).map_err(|e| Error::io(format!("{n}: {e}")))?;
            moved.push(n.clone());
            let (sha256, size) = hash_file(&dir.join(n))?;
            bytes += size;
            files.push(FileEntry { path: n.clone(), size, sha256 });
            progress(k as u64 + 1, total);
        }
        std::fs::write(dir.join(META_LOCK), b"").map_err(|e| Error::io(format!("{}: {e}", dir.display())))?;
        Ok(Some((files, bytes)))
    };
    let result = run();
    match result {
        Ok(Some((files, bytes))) => Ok(Some(Stage { build_id, dir, files, bytes, from: build.to_path_buf() })),
        Ok(None) => {
            put_back(&moved);
            Ok(None)
        }
        Err(e) => {
            put_back(&moved);
            Err(e)
        }
    }
}

/// Give up a staged snapshot that will not be published: its files go back to the working folder, which stays resumable.
pub fn abort(stage: &Stage) {
    if let Ok(rd) = std::fs::read_dir(&stage.dir) {
        for e in rd.flatten() {
            let n = e.file_name();
            if n != META_LOCK && !n.to_string_lossy().starts_with(MANIFEST) {
                let _ = std::fs::rename(e.path(), stage.from.join(n));
            }
        }
    }
    let _ = std::fs::remove_dir_all(&stage.dir);
}

/// Write `manifest.json` (last, with the staged files) and publish the stage as `snap/<build id>/` by one rename. The caller
/// sets the manifest's own fields; `files` and `created` are set here when empty. On any failure the stage is removed.
pub fn publish(source_dir: &Path, stage: Stage, mut manifest: Manifest) -> Result<PathBuf> {
    manifest.files = stage.files.clone();
    if manifest.created.is_empty() {
        manifest.created = iso_now();
    }
    let target = source_dir.join(SNAP_DIR).join(&stage.build_id);
    let run = || -> Result<()> {
        let text = serde_json::to_string_pretty(&manifest).map_err(|e| Error::internal(e.to_string()))?;
        let tmp = stage.dir.join(format!("{MANIFEST}.tmp"));
        std::fs::write(&tmp, text).map_err(|e| Error::io(format!("{}: {e}", tmp.display())))?;
        std::fs::rename(&tmp, stage.dir.join(MANIFEST))
            .map_err(|e| Error::io(format!("{}: {e}", stage.dir.display())))?;
        std::fs::create_dir_all(source_dir.join(SNAP_DIR))
            .map_err(|e| Error::io(format!("{}: {e}", source_dir.display())))?;
        std::fs::rename(&stage.dir, &target)
            .map_err(|e| Error::new(ErrorCode::Io, format!("publishing {}: {e}", target.display())))
    };
    match run() {
        Ok(()) => Ok(target),
        Err(e) => {
            abort(&stage);
            Err(e)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_ids_are_one_folder_segment() {
        for id in ["0badc0de-0000-4000-8000-00000000cafe", "my-lib@3", "a/b\\c:d e%f", ".hidden", "..", "ünï", "x.y"]
        {
            let e = encode_source_id(id);
            assert!(
                !e.is_empty() && !e.contains('/') && !e.contains('\\') && !e.contains(':') && !e.starts_with('.'),
                "{e}"
            );
            assert_eq!(decode_source_id(&e).as_deref(), Some(id));
        }
        assert_eq!(encode_source_id("my-lib@3"), "my-lib@3");
        assert_eq!(encode_source_id("a/b"), "a%2Fb");
        assert_eq!(encode_source_id(".."), "%2E.");
    }

    #[test]
    fn stage_moves_files_and_an_aborted_stage_puts_them_back() {
        let root = std::env::temp_dir().join(format!("cs-snapshot-stage-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        let build = root.join(BUILD_DIR);
        std::fs::create_dir_all(&build).unwrap();
        std::fs::write(build.join("meta.json"), b"{}").unwrap();
        std::fs::write(build.join("a.idx"), b"abc").unwrap();
        std::fs::write(build.join("lock"), b"x").unwrap();
        let st = stage(&build, &["lock"], &|_, _| {}, &|| false).unwrap().unwrap();
        // moved, not copied: the build no longer holds them; the stage does, hashed, plus the empty meta lock
        assert!(!build.join("a.idx").exists() && build.join("lock").exists());
        assert_eq!(st.files.iter().map(|f| f.path.as_str()).collect::<Vec<_>>(), ["a.idx", "meta.json"]);
        assert_eq!(std::fs::metadata(st.dir.join(META_LOCK)).unwrap().len(), 0);
        abort(&st);
        assert!(build.join("a.idx").exists() && build.join("meta.json").exists() && !st.dir.exists());
        // cancelled part way: whatever was moved is put back
        let n = std::cell::Cell::new(0);
        let none = stage(&build, &["lock"], &|_, _| {}, &|| {
            n.set(n.get() + 1);
            n.get() > 1
        })
        .unwrap();
        assert!(none.is_none() && build.join("a.idx").exists() && build.join("meta.json").exists());
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn build_ids_sort_by_time() {
        let a = new_build_id();
        assert_eq!(a.len(), "20261102T120000Z-abcdef".len());
        assert_eq!(civil(0), (1970, 1, 1, 0, 0, 0));
        assert_eq!(civil(1_700_000_000), (2023, 11, 14, 22, 13, 20));
    }
}
