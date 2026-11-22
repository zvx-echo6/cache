//! Change notification for linked folders: raw Linux inotify through libc (already a dependency).
//!
//! Read-only: a watch only listens. Nothing here writes, renames or touches anything in the person's folders.
//! The module tells the scheduler "something that may matter changed in folder X"; it reads no file and decides nothing else.
//! Where inotify is unavailable, or its watch limit is reached, the scheduler falls back to the hourly rescan.
use std::{
    io,
    path::{Component, Path, PathBuf},
};

/// A change in one linked folder that may need a check.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Change {
    pub root_id: String,
}

/// What came of putting watches on one folder's tree.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum TreeOutcome {
    /// Every readable subfolder is watched.
    Watching { dirs: usize },
    /// The kernel's watch limit (`max_user_watches`) or a related resource limit was hit. The folder's watches are dropped,
    /// and the scheduler relies on the hourly rescan for it.
    LimitReached { dirs: usize },
    /// No notifications at all on this system (not Linux, or inotify could not start).
    Unsupported(String),
}

/// Listens for changes. One value serves every linked folder.
pub trait Notifier: Send {
    /// Watch the whole tree below `root` (recursively), skipping hidden and excluded folders and symbolic links. Safe to call
    /// again for the same folder: its earlier watches are replaced.
    fn watch_root(&mut self, root_id: &str, root: &Path, exclusions: &[PathBuf]) -> TreeOutcome;
    /// Stop watching a folder.
    fn forget_root(&mut self, root_id: &str);
    /// Wait up to `timeout_ms` for changes; returns the folders that changed (each at most once). New subfolders are watched
    /// before this returns.
    fn wait(&mut self, timeout_ms: i32) -> Vec<Change>;
    /// Is this folder watched right now? False if it was never watched, or if a limit was hit while following new subfolders.
    fn watching(&self, root_id: &str) -> bool;
}

/// Is this the kernel saying "no more watches" (or no more of a related resource)?
pub fn is_limit(error: &io::Error) -> bool {
    error.raw_os_error().is_some_and(limit_code)
}

#[cfg(unix)]
fn limit_code(code: i32) -> bool {
    code == libc::ENOSPC || code == libc::ENOMEM || code == libc::EMFILE || code == libc::ENFILE
}

#[cfg(not(unix))]
fn limit_code(_: i32) -> bool {
    false
}

fn hidden_rel(path: &Path) -> bool {
    path.components().any(|c| matches!(c, Component::Normal(s) if s.to_string_lossy().starts_with('.')))
}

fn excluded_rel(path: &Path, exclusions: &[PathBuf]) -> bool {
    exclusions.iter().any(|e| path == e || path.starts_with(e))
}

/// Walk the folders under `start` (inside `base`), calling `add` once for each folder to watch. Hidden folders, excluded
/// folders and symbolic links are skipped, as the scanner skips them. An error from `add` that is a limit stops the walk
/// (`LimitReached`); any other error skips that one folder.
pub fn walk_tree(
    base: &Path,
    start: &Path,
    exclusions: &[PathBuf],
    add: &mut dyn FnMut(&Path) -> io::Result<()>,
) -> TreeOutcome {
    let mut stack = vec![start.to_path_buf()];
    let mut dirs = 0usize;
    while let Some(dir) = stack.pop() {
        let rel = dir.strip_prefix(base).unwrap_or(&dir).to_path_buf();
        if !rel.as_os_str().is_empty() && (hidden_rel(&rel) || excluded_rel(&rel, exclusions)) {
            continue;
        }
        match std::fs::symlink_metadata(&dir) {
            Ok(meta) if meta.is_dir() && !meta.file_type().is_symlink() => {}
            _ => continue,
        }
        match add(&dir) {
            Ok(()) => dirs += 1,
            Err(error) if is_limit(&error) => return TreeOutcome::LimitReached { dirs },
            Err(_) => {}
        }
        if let Ok(entries) = std::fs::read_dir(&dir) {
            for entry in entries.flatten() {
                stack.push(entry.path());
            }
        }
    }
    TreeOutcome::Watching { dirs }
}

/// No notifications: the hourly rescan does all the work.
pub struct NoNotify(pub String);

impl Notifier for NoNotify {
    fn watch_root(&mut self, _: &str, _: &Path, _: &[PathBuf]) -> TreeOutcome {
        TreeOutcome::Unsupported(self.0.clone())
    }
    fn forget_root(&mut self, _: &str) {}
    fn wait(&mut self, timeout_ms: i32) -> Vec<Change> {
        std::thread::sleep(std::time::Duration::from_millis(timeout_ms.max(0) as u64));
        vec![]
    }
    fn watching(&self, _: &str) -> bool {
        false
    }
}

/// The notifier for this system: inotify on Linux, else (or if inotify cannot start) one that reports "unsupported".
pub fn system_notifier() -> Box<dyn Notifier> {
    system_notifier_for_this_os()
}

#[cfg(target_os = "linux")]
fn system_notifier_for_this_os() -> Box<dyn Notifier> {
    match linux::Inotify::new() {
        Ok(n) => Box::new(n),
        Err(e) => {
            eprintln!("cache: linked folders: inotify is not available ({e}); using the hourly rescan only");
            Box::new(NoNotify(e.to_string()))
        }
    }
}

#[cfg(not(target_os = "linux"))]
fn system_notifier_for_this_os() -> Box<dyn Notifier> {
    Box::new(NoNotify("file-system notifications are only used on Linux".into()))
}

#[cfg(target_os = "linux")]
pub mod linux {
    use super::*;
    use std::{
        collections::{BTreeSet, HashMap},
        ffi::CString,
        os::unix::ffi::{OsStrExt, OsStringExt},
    };

    /// Everything that can change what a check would find: files made, finished, moved, removed or touched, and folders moved or removed.
    const MASK: u32 = libc::IN_CREATE
        | libc::IN_CLOSE_WRITE
        | libc::IN_MODIFY
        | libc::IN_ATTRIB
        | libc::IN_MOVED_FROM
        | libc::IN_MOVED_TO
        | libc::IN_DELETE
        | libc::IN_DELETE_SELF
        | libc::IN_MOVE_SELF
        | libc::IN_ONLYDIR
        | libc::IN_DONT_FOLLOW;

    /// A linked folder's tree, for new subfolders.
    struct Root {
        path: PathBuf,
        exclusions: Vec<PathBuf>,
    }

    pub struct Inotify {
        fd: libc::c_int,
        /// Watch descriptor -> (folder id, the watched directory).
        wds: HashMap<i32, (String, PathBuf)>,
        roots: HashMap<String, Root>,
    }

    impl Inotify {
        pub fn new() -> io::Result<Inotify> {
            // SAFETY: plain syscall with constant flags; a negative result is an error, otherwise we own the descriptor.
            let fd = unsafe { libc::inotify_init1(libc::IN_NONBLOCK | libc::IN_CLOEXEC) };
            if fd < 0 {
                return Err(io::Error::last_os_error());
            }
            Ok(Inotify { fd, wds: HashMap::new(), roots: HashMap::new() })
        }

        fn add_dir(&mut self, root_id: &str, dir: &Path) -> io::Result<()> {
            let c = CString::new(dir.as_os_str().as_bytes())
                .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "NUL in path"))?;
            // SAFETY: the descriptor is ours and live, the path is NUL-terminated and outlives the call.
            let wd = unsafe { libc::inotify_add_watch(self.fd, c.as_ptr(), MASK) };
            if wd < 0 {
                return Err(io::Error::last_os_error());
            }
            self.wds.insert(wd, (root_id.to_string(), dir.to_path_buf()));
            Ok(())
        }

        fn add_tree(&mut self, root_id: &str, base: &Path, start: &Path, exclusions: &[PathBuf]) -> TreeOutcome {
            let id = root_id.to_string();
            walk_tree(base, start, exclusions, &mut |dir| self.add_dir(&id, dir))
        }

        /// How many directories are watched for a folder (for tests and logs).
        pub fn watch_count(&self, root_id: &str) -> usize {
            self.wds.values().filter(|(id, _)| id == root_id).count()
        }
    }

    impl Drop for Inotify {
        fn drop(&mut self) {
            // SAFETY: the descriptor is ours and closed once; closing also drops every watch.
            unsafe { libc::close(self.fd) };
        }
    }

    impl Notifier for Inotify {
        fn watch_root(&mut self, root_id: &str, root: &Path, exclusions: &[PathBuf]) -> TreeOutcome {
            self.forget_root(root_id);
            self.roots.insert(root_id.to_string(), Root { path: root.to_path_buf(), exclusions: exclusions.to_vec() });
            let outcome = self.add_tree(root_id, root, root, exclusions);
            if matches!(outcome, TreeOutcome::LimitReached { .. }) {
                // Half a tree is worse than none: free the watches, the hourly rescan covers this folder.
                self.forget_root(root_id);
            }
            outcome
        }

        fn forget_root(&mut self, root_id: &str) {
            let gone: Vec<i32> = self.wds.iter().filter(|(_, (id, _))| id == root_id).map(|(wd, _)| *wd).collect();
            for wd in gone {
                // SAFETY: the descriptor is ours; an already-removed watch just returns an error we do not need.
                unsafe { libc::inotify_rm_watch(self.fd, wd) };
                self.wds.remove(&wd);
            }
            self.roots.remove(root_id);
        }

        fn wait(&mut self, timeout_ms: i32) -> Vec<Change> {
            let mut pfd = libc::pollfd { fd: self.fd, events: libc::POLLIN, revents: 0 };
            // SAFETY: one valid pollfd, count 1.
            let ready = unsafe { libc::poll(&mut pfd, 1, timeout_ms) };
            if ready <= 0 {
                return vec![];
            }
            let mut changed: BTreeSet<String> = BTreeSet::new();
            let mut new_dirs: Vec<(String, PathBuf)> = vec![];
            let mut buf = vec![0u8; 64 * 1024];
            loop {
                // SAFETY: the buffer is valid for its length; the descriptor is ours.
                let n = unsafe { libc::read(self.fd, buf.as_mut_ptr() as *mut libc::c_void, buf.len()) };
                if n < 0 {
                    if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                        continue;
                    }
                    break; // EAGAIN: drained
                }
                if n == 0 {
                    break;
                }
                let n = n as usize;
                let mut off = 0usize;
                while off + 16 <= n {
                    let wd = i32::from_ne_bytes(buf[off..off + 4].try_into().unwrap());
                    let mask = u32::from_ne_bytes(buf[off + 4..off + 8].try_into().unwrap());
                    let len = u32::from_ne_bytes(buf[off + 12..off + 16].try_into().unwrap()) as usize;
                    let end = off + 16 + len;
                    if end > n {
                        break;
                    }
                    let raw = &buf[off + 16..end];
                    let name_bytes = raw.split(|b| *b == 0).next().unwrap_or(&[]).to_vec();
                    off = end;
                    if mask & libc::IN_Q_OVERFLOW != 0 {
                        // Events were lost: every folder needs a look.
                        changed.extend(self.roots.keys().cloned());
                        continue;
                    }
                    if mask & libc::IN_IGNORED != 0 {
                        self.wds.remove(&wd);
                        continue;
                    }
                    let Some((root_id, dir)) = self.wds.get(&wd).cloned() else { continue };
                    let is_dir = mask & libc::IN_ISDIR != 0;
                    if name_bytes.is_empty() {
                        // The watched folder itself was removed, moved or unmounted.
                        changed.insert(root_id);
                        continue;
                    }
                    let name = std::ffi::OsString::from_vec(name_bytes);
                    let name_s = name.to_string_lossy().to_ascii_lowercase();
                    if name_s.starts_with('.') {
                        continue;
                    }
                    if is_dir {
                        if mask & (libc::IN_CREATE | libc::IN_MOVED_TO) != 0 {
                            new_dirs.push((root_id.clone(), dir.join(&name)));
                        }
                        changed.insert(root_id);
                    } else if name_s.ends_with(".pdf") {
                        changed.insert(root_id);
                    }
                }
            }
            // A folder made or moved in: watch it (and what is already inside it). The check that follows sees any file that
            // landed before the watch did.
            for (root_id, dir) in new_dirs {
                let Some(root) = self.roots.get(&root_id) else { continue };
                let (base, exclusions) = (root.path.clone(), root.exclusions.clone());
                if let TreeOutcome::LimitReached { .. } = self.add_tree(&root_id, &base, &dir, &exclusions) {
                    // Out of watches mid-run: this folder falls back to the hourly rescan. The scheduler notices through
                    // `watching()`, logs it, and keeps checking the folder by rescan.
                    self.forget_root(&root_id);
                    changed.insert(root_id);
                }
            }
            changed.into_iter().map(|root_id| Change { root_id }).collect()
        }

        fn watching(&self, root_id: &str) -> bool {
            self.roots.contains_key(root_id)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    fn temp(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!(
            "linked-watch-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        fs::create_dir_all(&p).unwrap();
        fs::canonicalize(p).unwrap()
    }

    #[test]
    fn the_walk_watches_every_visible_folder_and_skips_hidden_excluded_and_links() {
        let root = temp("walk");
        for d in ["a/b", "c", ".hidden/x", "skip/inner"] {
            fs::create_dir_all(root.join(d)).unwrap();
        }
        #[cfg(unix)]
        std::os::unix::fs::symlink(root.join("c"), root.join("link")).unwrap();
        let mut seen = vec![];
        let outcome = walk_tree(&root, &root, &[PathBuf::from("skip")], &mut |d| {
            seen.push(d.strip_prefix(&root).unwrap().to_string_lossy().into_owned());
            Ok(())
        });
        seen.sort();
        assert_eq!(seen, vec!["", "a", "a/b", "c"]);
        assert_eq!(outcome, TreeOutcome::Watching { dirs: 4 });
        let _ = fs::remove_dir_all(root);
    }

    #[cfg(unix)]
    #[test]
    fn a_full_watch_table_is_reported_as_the_limit_and_other_errors_skip_one_folder() {
        let root = temp("limit");
        for d in ["a", "b", "c"] {
            fs::create_dir_all(root.join(d)).unwrap();
        }
        let mut calls = 0;
        let outcome = walk_tree(&root, &root, &[], &mut |_| {
            calls += 1;
            if calls > 2 {
                Err(io::Error::from_raw_os_error(libc::ENOSPC))
            } else {
                Ok(())
            }
        });
        assert_eq!(outcome, TreeOutcome::LimitReached { dirs: 2 });
        assert!(is_limit(&io::Error::from_raw_os_error(libc::ENOSPC)));
        assert!(!is_limit(&io::Error::from_raw_os_error(libc::EACCES)));
        // a folder we may not watch is skipped; the rest are still watched
        let mut n = 0;
        let outcome = walk_tree(&root, &root, &[], &mut |_| {
            n += 1;
            if n == 2 {
                Err(io::Error::from_raw_os_error(libc::EACCES))
            } else {
                Ok(())
            }
        });
        assert_eq!(outcome, TreeOutcome::Watching { dirs: 3 });
        let _ = fs::remove_dir_all(root);
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn inotify_reports_new_pdfs_and_follows_new_subfolders_but_ignores_other_files() {
        let root = temp("real");
        fs::create_dir_all(root.join("sub")).unwrap();
        let mut n = linux::Inotify::new().unwrap();
        assert_eq!(n.watch_root("r", &root, &[]), TreeOutcome::Watching { dirs: 2 });
        assert!(n.wait(50).is_empty());
        fs::write(root.join("notes.txt"), b"x").unwrap();
        assert!(n.wait(100).is_empty(), "a text file is not a change that matters");
        fs::write(root.join("sub/a.pdf"), b"x").unwrap();
        assert_eq!(n.wait(1000), vec![Change { root_id: "r".into() }]);
        // a new subfolder is watched, so a file made in it later is seen
        fs::create_dir_all(root.join("later/deeper")).unwrap();
        for _ in 0..30 {
            let _ = n.wait(100);
            if n.watch_count("r") == 4 {
                break;
            }
        }
        assert_eq!(n.watch_count("r"), 4);
        let mut got = vec![];
        for _ in 0..3 {
            let _ = n.wait(100); // settle any events from the folders made above
        }
        fs::write(root.join("later/deeper/b.PDF"), b"y").unwrap();
        for _ in 0..30 {
            got = n.wait(100);
            if !got.is_empty() {
                break;
            }
        }
        assert_eq!(got, vec![Change { root_id: "r".into() }]);
        // hidden folders are not watched
        fs::create_dir_all(root.join(".cache")).unwrap();
        let _ = n.wait(100);
        assert_eq!(n.watch_count("r"), 4);
        n.forget_root("r");
        assert_eq!(n.watch_count("r"), 0);
        let _ = fs::remove_dir_all(root);
    }
}
