//! Read-only scanner primitives for approved linked PDF folders.
//!
//! This module stores no absolute paths and makes no library or event-log decisions.
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    fs::{self, File, OpenOptions},
    io::{self, Read, Seek, SeekFrom},
    path::{Component, Path, PathBuf},
    time::UNIX_EPOCH,
};
#[cfg(unix)]
use std::{
    ffi::CString,
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::ffi::OsStrExt,
    },
};

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct FileState {
    pub length: u64,
    pub mtime_ms: u64,
    pub first_observed_ms: u64,
    pub blake3: Option<String>,
}
pub type ScanState = BTreeMap<String, FileState>;
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PdfCandidate {
    pub relpath: String,
    pub length: u64,
    pub mtime_ms: u64,
    pub first_observed_ms: u64,
    pub blake3: String,
}
#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct RootIssue {
    pub code: String,
    pub path: String,
    pub message: String,
}
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ScanError {
    pub relpath: String,
    pub code: String,
    pub message: String,
}
#[derive(Clone, Debug)]
pub struct ScanResult {
    pub state: ScanState,
    pub candidates: Vec<PdfCandidate>,
    pub errors: Vec<ScanError>,
    pub unavailable: bool,
    pub complete: bool,
    pub inaccessible_prefixes: Vec<String>,
}

fn valid_relative(path: &Path) -> bool {
    !path.as_os_str().is_empty() && path.components().all(|c| matches!(c, Component::Normal(_)))
}
fn hidden(path: &Path) -> bool {
    path.components()
        .any(|c| matches!(c, Component::Normal(s) if s.to_string_lossy().starts_with('.')))
}
fn excluded(path: &Path, exclusions: &[PathBuf]) -> bool {
    exclusions.iter().any(|e| path == e || path.starts_with(e))
}
fn retained(previous: &ScanState, exclusions: &[PathBuf]) -> ScanState {
    previous
        .iter()
        .filter(|(k, _)| {
            let p = Path::new(k.as_str());
            valid_relative(p) && !hidden(p) && !excluded(p, exclusions)
        })
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect()
}
fn millis(meta: &fs::Metadata) -> u64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis().min(u64::MAX as u128) as u64)
        .unwrap_or(0)
}
fn fingerprint(meta: &fs::Metadata) -> (u64, u64) {
    (meta.len(), millis(meta))
}
// After the canonical root descriptor is acquired, every descendant is opened relative to a
// held directory descriptor. O_NOFOLLOW rejects symlink components and pathname renames cannot
// redirect hashing or serving. Acquiring the root descriptor itself still relies on the registered
// canonical root path not being adversarially replaced at that instant.
#[cfg(unix)]
fn open_beneath(root: &Path, relative: &Path) -> io::Result<File> {
    if !valid_relative(relative) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid relative source path"));
    }
    let canonical = fs::canonicalize(root)?;
    if canonical != root {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "registered root is not canonical"));
    }
    let mut options = OpenOptions::new();
    options.read(true);
    use std::os::unix::fs::OpenOptionsExt;
    options.custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC);
    let mut current = options.open(&canonical)?;
    let components: Vec<_> = relative.components().collect();
    for (i, component) in components.iter().enumerate() {
        let Component::Normal(part) = component else {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid relative source path"));
        };
        let name = CString::new(part.as_bytes()).map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in path component"))?;
        let final_component = i + 1 == components.len();
        let flags =
            libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK | if final_component { 0 } else { libc::O_DIRECTORY };
        // SAFETY: parent fd is owned and live; name is NUL-terminated; no create/write flags.
        let fd = unsafe { libc::openat(current.as_raw_fd(), name.as_ptr(), flags) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: successful openat returned a fresh owned descriptor, transferred exactly once.
        current = unsafe { File::from_raw_fd(fd) };
        if !final_component && !current.metadata()?.is_dir() {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "source parent is not a directory"));
        }
    }
    Ok(current)
}

#[cfg(not(unix))]
fn open_beneath(root: &Path, relative: &Path) -> io::Result<File> {
    if !valid_relative(relative) {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid relative source path"));
    }
    let canonical_root = fs::canonicalize(root)?;
    if canonical_root != root {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "registered root is not canonical"));
    }
    let mut path = canonical_root.clone();
    for component in relative.components() {
        let Component::Normal(part) = component else {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "invalid relative source path"));
        };
        path.push(part);
        if fs::symlink_metadata(&path)?.file_type().is_symlink() {
            return Err(io::Error::new(io::ErrorKind::PermissionDenied, "symlink component rejected"));
        }
    }
    let canonical = fs::canonicalize(&path)?;
    if !canonical.starts_with(&canonical_root) {
        return Err(io::Error::new(io::ErrorKind::PermissionDenied, "source escaped registered root"));
    }
    File::open(canonical)
}

type Fingerprint = (u64, u64);
type HashedFile = (String, Fingerprint, Fingerprint);

fn hash_opened(file: &mut File) -> io::Result<HashedFile> {
    hash_opened_progress(file, |_| {})
}
fn hash_opened_progress(file: &mut File, mut on_bytes: impl FnMut(u64)) -> io::Result<HashedFile> {
    let before = file.metadata()?;
    if !before.is_file() {
        return Err(io::Error::new(io::ErrorKind::InvalidInput, "source is not a regular file"));
    }
    let mut h = blake3::Hasher::new();
    let mut buf = [0u8; 65536];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
        on_bytes(n as u64);
    }
    let hash = h.finalize().to_hex().to_string();
    let after = file.metadata()?;
    Ok((hash, fingerprint(&before), fingerprint(&after)))
}
fn issue_code(kind: io::ErrorKind) -> &'static str {
    match kind {
        io::ErrorKind::NotFound => "not_found",
        io::ErrorKind::PermissionDenied => "permission_denied",
        io::ErrorKind::InvalidInput => "invalid_path",
        io::ErrorKind::InvalidData => "invalid_state",
        _ => "io_error",
    }
}
/// A per-file problem as the browser is told it: the reason code, and one fixed sentence for that reason (the wording the
/// browser already uses for the code). The operating system's own error text goes to the log only.
fn scan_issue(relpath: String, error: &io::Error) -> ScanError {
    eprintln!("cache: linked folder: {relpath}: {error}");
    let code = issue_code(error.kind());
    ScanError {
        relpath,
        code: code.into(),
        message: reason_text(code).into(),
    }
}
fn reason_text(code: &str) -> &'static str {
    match code {
        "permission_denied" => "Cache cannot read this folder. Restore access and try again.",
        "not_found" => "The linked folder or file is no longer available.",
        "invalid_path" => "The folder path could not be used. Check it and try again.",
        "invalid_state" => "This folder cannot be checked right now. Refresh and try again.",
        _ => "Cache could not read a file. Check access and try again.",
    }
}
fn hash_beneath_progress(root: &Path, relative: &Path, on_bytes: impl FnMut(u64)) -> io::Result<HashedFile> {
    hash_opened_progress(&mut open_beneath(root, relative)?, on_bytes)
}

/// Scan a canonical registered directory. Exclusions must be nonempty relative component paths.
pub fn scan_linked_root(root: &Path, exclusions: &[PathBuf], previous: &ScanState, now_ms: u64, settle_ms: u64) -> ScanResult {
    scan_linked_root_with_progress(root, exclusions, previous, now_ms, settle_ms, |_, _, _, _, _| {})
}
pub fn scan_linked_root_with_progress<F>(
    root: &Path,
    exclusions: &[PathBuf],
    previous: &ScanState,
    now_ms: u64,
    settle_ms: u64,
    mut progress: F,
) -> ScanResult
where
    F: FnMut(usize, usize, u64, usize, &ScanState),
{
    let mut seen = 0usize;
    let mut hashed = 0usize;
    let mut bytes_hashed = 0u64;
    let mut settling_count = 0usize;
    let mut result = ScanResult {
        state: ScanState::new(),
        candidates: vec![],
        errors: vec![],
        unavailable: false,
        complete: true,
        inaccessible_prefixes: vec![],
    };
    if exclusions.iter().any(|path| !valid_relative(path)) {
        result.unavailable = true;
        result.complete = false;
        result.errors.push(ScanError {
            relpath: String::new(),
            code: "invalid_exclusion".into(),
            message: "invalid exclusion path".into(),
        });
        result.state = retained(previous, exclusions);
        return result;
    }
    let checked_root = fs::canonicalize(root).and_then(|canonical| {
        if canonical != root || !fs::metadata(&canonical)?.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "registered root unavailable or not canonical",
            ));
        }
        Ok(canonical)
    });
    let canonical = match checked_root {
        Ok(path) => path,
        Err(error) => {
            result.unavailable = true;
            result.complete = false;
            result.errors.push(scan_issue(String::new(), &error));
            result.state = retained(previous, exclusions);
            return result;
        }
    };
    let mut stack = vec![(PathBuf::new(), canonical.clone())];
    while let Some((relative, absolute)) = stack.pop() {
        let key = relative.to_string_lossy().replace('\\', "/");
        let safe = fs::symlink_metadata(&absolute)
            .map(|metadata| metadata.is_dir() && !metadata.file_type().is_symlink())
            .unwrap_or(false)
            && fs::canonicalize(&absolute)
                .map(|path| path.starts_with(&canonical))
                .unwrap_or(false);
        if !safe {
            result.complete = false;
            result.inaccessible_prefixes.push(key.clone());
            result.errors.push(ScanError {
                relpath: key,
                code: "unsafe_path".into(),
                message: "directory changed or escaped registered root".into(),
            });
            continue;
        }
        let entries = match fs::read_dir(&absolute) {
            Ok(entries) => entries,
            Err(error) => {
                result.complete = false;
                result.inaccessible_prefixes.push(key.clone());
                result.errors.push(scan_issue(key, &error));
                continue;
            }
        };
        for entry in entries {
            let entry = match entry {
                Ok(entry) => entry,
                Err(error) => {
                    result.complete = false;
                    result.inaccessible_prefixes.push(key.clone());
                    result.errors.push(scan_issue(key.clone(), &error));
                    continue;
                }
            };
            let name = entry.file_name();
            let child = relative.join(&name);
            if hidden(&child) || excluded(&child, exclusions) {
                continue;
            }
            let child_s = match child.to_str() {
                Some(path) => path.replace('\\', "/"),
                None => {
                    result.complete = false;
                    result.inaccessible_prefixes.push(key.clone());
                    result.errors.push(ScanError {
                        relpath: key.clone(),
                        code: "path_encoding".into(),
                        message: "non-UTF-8 path skipped".into(),
                    });
                    continue;
                }
            };
            let metadata = match fs::symlink_metadata(entry.path()) {
                Ok(metadata) => metadata,
                Err(error) => {
                    result.complete = false;
                    result.inaccessible_prefixes.push(child_s.clone());
                    result.errors.push(scan_issue(child_s, &error));
                    continue;
                }
            };
            if metadata.file_type().is_symlink() {
                continue;
            }
            if metadata.is_dir() {
                stack.push((child, entry.path()));
                continue;
            }
            if !metadata.is_file() || !name.to_string_lossy().to_ascii_lowercase().ends_with(".pdf") {
                continue;
            }
            let (length, mtime_ms) = fingerprint(&metadata);
            let old = previous.get(&child_s);
            let (first_observed_ms, hash) = match old {
                Some(state) if state.length == length && state.mtime_ms == mtime_ms => (state.first_observed_ms, state.blake3.clone()),
                _ => (now_ms, None),
            };
            let mut state = FileState {
                length,
                mtime_ms,
                first_observed_ms,
                blake3: hash,
            };
            if state.blake3.is_none() && now_ms.saturating_sub(first_observed_ms) >= settle_ms {
                hashed += 1;
                let mut file_bytes = 0u64;
                match hash_beneath_progress(&canonical, &child, |chunk| {
                    file_bytes = file_bytes.saturating_add(chunk);
                    progress(
                        seen + 1,
                        hashed,
                        bytes_hashed.saturating_add(file_bytes),
                        settling_count,
                        &result.state,
                    );
                }) {
                    Ok((hash, before, after)) if before == (length, mtime_ms) && after == (length, mtime_ms) => {
                        state.blake3 = Some(hash);
                    }
                    Ok(_) => {
                        state.first_observed_ms = now_ms;
                        result.errors.push(ScanError {
                            relpath: child_s.clone(),
                            code: "file_changing".into(),
                            message: "file changed while hashing; pending".into(),
                        });
                    }
                    Err(error) => {
                        result.complete = false;
                        result.inaccessible_prefixes.push(child_s.clone());
                        result.errors.push(scan_issue(child_s.clone(), &error));
                        if let Some(old) = old {
                            state = old.clone();
                        }
                    }
                }
                bytes_hashed = bytes_hashed.saturating_add(file_bytes);
            }
            if let Some(hash) = &state.blake3 {
                if !result.inaccessible_prefixes.iter().any(|prefix| prefix == &child_s) {
                    result.candidates.push(PdfCandidate {
                        relpath: child_s.clone(),
                        length,
                        mtime_ms,
                        first_observed_ms,
                        blake3: hash.clone(),
                    });
                }
            } else if now_ms.saturating_sub(state.first_observed_ms) < settle_ms {
                settling_count += 1;
            }
            result.state.insert(child_s, state);
            seen += 1;
            progress(seen, hashed, bytes_hashed, settling_count, &result.state);
        }
    }
    // Preserve prior records beneath unreadable prefixes; a partial walk cannot confirm absence there.
    for (key, value) in previous {
        let path = Path::new(key);
        if !valid_relative(path) || hidden(path) || excluded(path, exclusions) {
            continue;
        }
        if result
            .inaccessible_prefixes
            .iter()
            .any(|prefix| prefix.is_empty() || key == prefix || key.starts_with(&(prefix.clone() + "/")))
        {
            result.state.entry(key.clone()).or_insert_with(|| value.clone());
        }
    }
    result.candidates.sort_by(|a, b| a.relpath.cmp(&b.relpath));
    result.inaccessible_prefixes.sort();
    result.inaccessible_prefixes.dedup();
    result
}

/// Read a linked original once, in place, for the builder. It is opened beneath the registered root (no symlinks), read
/// through that one handle, and refused unless its size and modified time are the same before and after the read and its BLAKE3
/// is the one the check recorded. A file still being written, or changed since it was checked, returns an error: the caller
/// drops the result and the next automatic check tries again once the file is stable. Nothing is ever written.
pub fn read_stable(root: &Path, relative: &str, expected_blake3: &str) -> Result<Vec<u8>, String> {
    let mut file = open_beneath(root, Path::new(relative)).map_err(|e| format!("could not open the file: {e}"))?;
    let before = file.metadata().map_err(|e| e.to_string())?;
    if !before.is_file() {
        return Err("source is not a regular file".into());
    }
    let mut bytes = Vec::with_capacity(before.len().min(1 << 30) as usize);
    file.read_to_end(&mut bytes).map_err(|e| format!("could not read the file: {e}"))?;
    let after = file.metadata().map_err(|e| e.to_string())?;
    if fingerprint(&before) != fingerprint(&after) || bytes.len() as u64 != before.len() {
        return Err("the file changed while it was read".into());
    }
    if blake3::hash(&bytes).to_hex().to_string() != expected_blake3.to_ascii_lowercase() {
        return Err("the file is not the one that was checked".into());
    }
    Ok(bytes)
}

/// Open and validate a stored source immediately before use. Returns the same read-only handle
/// whose contents were hashed; callers must serve from this handle, never reopen its pathname.
/// Unix opens components relative to held descriptors with O_NOFOLLOW. The non-Unix fallback
/// checks paths but cannot guarantee safety against concurrent replacement races.
/// Hidden and excluded-path policy belongs to the caller that owns the folder registration.
pub fn read_only_source_path(root: &Path, relative: &str, expected_blake3: &str) -> Result<File, String> {
    let rel = Path::new(relative);
    if !valid_relative(rel) {
        return Err("invalid relative source path".into());
    }
    let canonical_root = fs::canonicalize(root).map_err(|e| format!("registered root unavailable: {e}"))?;
    if canonical_root != root || !fs::metadata(root).map_err(|e| e.to_string())?.is_dir() {
        return Err("registered root is not canonical".into());
    }
    let expected = expected_blake3.to_ascii_lowercase();
    if expected.len() != 64 || !expected.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err("invalid expected BLAKE3".into());
    }
    let mut file = open_beneath(&canonical_root, rel).map_err(|e| format!("could not open source beneath root: {e}"))?;
    let (actual, before, after) = hash_opened(&mut file).map_err(|e| format!("could not verify source: {e}"))?;
    if before != after || actual != expected {
        return Err("source changed or hash does not match".into());
    }
    file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
    Ok(file)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        fs,
        time::{SystemTime, UNIX_EPOCH},
    };
    struct Temp(PathBuf);
    impl Temp {
        fn new() -> Self {
            let p = std::env::temp_dir().join(format!(
                "cache-linked-{}-{}",
                std::process::id(),
                SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()
            ));
            fs::create_dir_all(&p).unwrap();
            Self(p)
        }
    }
    impl Drop for Temp {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn setup() -> (Temp, PathBuf) {
        let t = Temp::new();
        let root = fs::canonicalize(&t.0).unwrap();
        (t, root)
    }
    #[test]
    fn read_only_and_quiet_reuse() {
        let (_t, root) = setup();
        fs::write(root.join("a.PDF"), b"abc").unwrap();
        let a = scan_linked_root(&root, &[], &ScanState::new(), 1, 0);
        let meta = fs::metadata(root.join("a.PDF")).unwrap();
        assert!(a.candidates.len() == 1);
        assert_eq!(fs::metadata(root.join("a.PDF")).unwrap().len(), meta.len());
        let mut opened = read_only_source_path(&root, "a.PDF", &a.candidates[0].blake3).unwrap();
        let mut bytes = Vec::new();
        opened.read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes, b"abc");
        let b = scan_linked_root(&root, &[], &a.state, 99, 500);
        assert_eq!(a.candidates[0].blake3, b.candidates[0].blake3);
        assert_eq!(a.state["a.PDF"].first_observed_ms, b.state["a.PDF"].first_observed_ms);
    }
    #[test]
    fn settle_change_rename_duplicate_and_unavailable() {
        let (_t, root) = setup();
        fs::write(root.join("a.pdf"), b"old").unwrap();
        let mut s = scan_linked_root(&root, &[], &ScanState::new(), 10, 100);
        assert!(s.candidates.is_empty());
        s = scan_linked_root(&root, &[], &s.state, 111, 100);
        assert_eq!(s.candidates.len(), 1);
        fs::write(root.join("a.pdf"), b"new! ").unwrap();
        let changed = scan_linked_root(&root, &[], &s.state, 200, 100);
        assert!(changed.candidates.is_empty());
        let settled = scan_linked_root(&root, &[], &changed.state, 301, 100);
        assert_eq!(settled.candidates.len(), 1);
        fs::rename(root.join("a.pdf"), root.join("b.pdf")).unwrap();
        let renamed = scan_linked_root(&root, &[], &settled.state, 400, 0);
        assert_eq!(renamed.candidates.len(), 1);
        assert_eq!(renamed.candidates[0].blake3, settled.candidates[0].blake3);
        fs::write(root.join("c.pdf"), b"new! ").unwrap();
        let dup = scan_linked_root(&root, &[], &renamed.state, 500, 0);
        assert_eq!(
            dup.candidates.iter().filter(|c| c.blake3 == renamed.candidates[0].blake3).count(),
            2
        );
        let gone = root.join("missing");
        let unavailable = scan_linked_root(&gone, &[], &dup.state, 600, 0);
        assert!(unavailable.unavailable);
        assert_eq!(unavailable.state, dup.state);
    }
    #[test]
    fn a_failed_read_is_reported_by_reason_not_in_the_operating_systems_words() {
        let (_t, root) = setup();
        let gone = root.join("missing");
        let r = scan_linked_root(&gone, &[], &ScanState::new(), 1, 0);
        let e = &r.errors[0];
        assert_eq!(e.code, "not_found");
        assert_eq!(e.message, "The linked folder or file is no longer available.");
        assert!(!e.message.contains("os error") && !e.message.contains("No such file"));
    }
    #[test]
    fn read_stable_returns_the_bytes_only_for_the_file_that_was_checked_and_never_writes() {
        let (_t, root) = setup();
        fs::write(root.join("a.pdf"), b"the whole file").unwrap();
        let meta = fs::metadata(root.join("a.pdf")).unwrap();
        let hash = blake3::hash(b"the whole file").to_hex().to_string();
        assert_eq!(read_stable(&root, "a.pdf", &hash).unwrap(), b"the whole file");
        assert!(
            read_stable(&root, "a.pdf", blake3::hash(b"other").to_hex().as_ref()).is_err(),
            "changed since it was checked"
        );
        assert!(read_stable(&root, "missing.pdf", &hash).is_err());
        assert!(read_stable(&root, "../a.pdf", &hash).is_err());
        let after = fs::metadata(root.join("a.pdf")).unwrap();
        assert_eq!((meta.len(), meta.modified().unwrap()), (after.len(), after.modified().unwrap()));
    }
    #[test]
    fn a_file_that_changes_while_it_is_read_is_dropped_and_waits_again() {
        use std::io::Write as _;
        let (_t, root) = setup();
        let path = root.join("big.pdf");
        fs::write(&path, vec![1u8; 300_000]).unwrap();
        let first = scan_linked_root(&root, &[], &ScanState::new(), 10, 100);
        assert!(first.candidates.is_empty());
        // the copy grows after the first chunk has been read
        let mut grew = false;
        let second = scan_linked_root_with_progress(&root, &[], &first.state, 200, 100, |_, _, _, _, _| {
            if !grew {
                grew = true;
                OpenOptions::new().append(true).open(&path).unwrap().write_all(b"more").unwrap();
            }
        });
        assert!(second.candidates.is_empty(), "a half-read result is dropped");
        assert!(second.errors.iter().any(|e| e.code == "file_changing"));
        assert!(second.state["big.pdf"].blake3.is_none());
        // it is seen with its new size, and read only once that has stayed the same for the settle delay
        let third = scan_linked_root(&root, &[], &second.state, 250, 100);
        assert!(third.candidates.is_empty());
        let fourth = scan_linked_root(&root, &[], &third.state, 400, 100);
        assert_eq!(fourth.candidates.len(), 1);
        assert_eq!(
            fourth.candidates[0].blake3,
            blake3::hash(&fs::read(&path).unwrap()).to_hex().to_string()
        );
    }
    #[cfg(unix)]
    #[test]
    fn opener_rejects_symlink_ancestor_and_handle_survives_rename() {
        use std::os::unix::fs::symlink;
        let (_t, root) = setup();
        fs::create_dir_all(root.join("dir")).unwrap();
        fs::write(root.join("dir/file.pdf"), b"original").unwrap();
        let hash = blake3::hash(b"original").to_hex().to_string();
        let mut opened = read_only_source_path(&root, "dir/file.pdf", &hash).unwrap();
        fs::rename(root.join("dir"), root.join("moved")).unwrap();
        fs::create_dir_all(root.join("dir")).unwrap();
        fs::write(root.join("dir/file.pdf"), b"replacement").unwrap();
        let mut bytes = Vec::new();
        opened.read_to_end(&mut bytes).unwrap();
        assert_eq!(bytes, b"original");
        let outside = Temp::new();
        fs::create_dir_all(outside.0.join("nested")).unwrap();
        fs::write(outside.0.join("nested/out.pdf"), b"outside").unwrap();
        symlink(outside.0.join("nested"), root.join("escape")).unwrap();
        let outside_hash = blake3::hash(b"outside").to_hex().to_string();
        assert!(read_only_source_path(&root, "escape/out.pdf", &outside_hash).is_err());
    }
    #[cfg(unix)]
    #[test]
    fn excludes_hidden_and_symlinks_and_resolver_rejects_traversal() {
        use std::os::unix::fs::symlink;
        let (_t, root) = setup();
        fs::create_dir_all(root.join("skip")).unwrap();
        fs::create_dir_all(root.join(".hidden")).unwrap();
        fs::write(root.join("skip/x.pdf"), b"x").unwrap();
        fs::write(root.join(".hidden/y.pdf"), b"y").unwrap();
        let outside = Temp::new();
        fs::write(outside.0.join("z.pdf"), b"z").unwrap();
        symlink(&outside.0, root.join("link")).unwrap();
        let r = scan_linked_root(&root, &[PathBuf::from("skip")], &ScanState::new(), 1, 0);
        assert!(r.state.is_empty());
        assert!(read_only_source_path(&root, "../z.pdf", &"00".repeat(32)).is_err());
    }
}
