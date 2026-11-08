//! Kernel-owned index guard. Its sibling file is retained so replacing a build
//! directory cannot unlink a held lock and create a second lock inode.
//!
//! The lock belongs to the open file description, not to this handle. Any
//! process forked while the guard is open (by any thread, e.g. a
//! `Command::spawn` elsewhere in the app) shares that description until it
//! execs, so merely closing our handle would leave the lock held for that
//! window and the next `try_guard` would see `WouldBlock`. Dropping a
//! [`Guard`] therefore unlocks explicitly, which releases the lock for every
//! copy of the descriptor at once.
use std::fs::{File, OpenOptions};
use std::io;
use std::path::{Path, PathBuf};

pub(crate) fn guard_path(dir: &Path) -> io::Result<PathBuf> {
    let mut name = std::fs::canonicalize(dir)?.into_os_string();
    name.push(".cache-search-index.guard");
    Ok(PathBuf::from(name))
}

/// A held index guard; dropping it releases the lock even if a forked child
/// still shares the descriptor.
pub(crate) struct Guard(File);

impl Drop for Guard {
    fn drop(&mut self) {
        let _ = self.0.unlock();
    }
}

/// None means no guard exists yet (old index). A held guard returns WouldBlock.
pub(crate) fn try_guard(dir: &Path, create: bool) -> io::Result<Option<Guard>> {
    let path = match guard_path(dir) {
        Ok(path) => path,
        Err(e) if !create && e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    let file = match OpenOptions::new().read(true).write(true).create(create).truncate(false).open(path) {
        Ok(file) => file,
        Err(e) if !create && e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(e),
    };
    file.try_lock().map_err(io::Error::from)?;
    Ok(Some(Guard(file)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::{Child, Command};
    use std::time::{Duration, Instant};

    struct Scratch(PathBuf);
    impl Scratch {
        fn new(name: &str) -> Self {
            let root = std::env::temp_dir().join(format!("cache-guard-{name}-{}-{}", std::process::id(),
                std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()));
            std::fs::create_dir_all(root.join("index")).unwrap();
            Self(root)
        }
        fn index(&self) -> PathBuf { self.0.join("index") }
    }
    impl Drop for Scratch {
        fn drop(&mut self) { let _ = std::fs::remove_dir_all(&self.0); }
    }
    struct ChildOwner(Child);
    impl Drop for ChildOwner {
        fn drop(&mut self) { let _ = self.0.kill(); let _ = self.0.wait(); }
    }

    #[test]
    fn active_owner_is_exclusive_and_drop_releases() {
        let d = Scratch::new("exclusive");
        assert!(try_guard(&d.index(), false).unwrap().is_none());
        let guard = try_guard(&d.index(), true).unwrap().unwrap();
        assert_eq!(try_guard(&d.index(), true).unwrap_err().kind(), io::ErrorKind::WouldBlock);
        drop(guard);
        let next = try_guard(&d.index(), false).unwrap().unwrap();
        assert!(guard_path(&d.index()).unwrap().exists());
        drop(next);
    }

    /// The CI flake: a sibling test's `Command::spawn` forked while this guard
    /// was open, the child shared the locked description until exec, and the
    /// re-take after `drop` saw WouldBlock. A dup of the descriptor is exactly
    /// that child's copy, held open across the drop.
    #[test]
    fn drop_releases_while_a_forked_copy_is_still_open() {
        let d = Scratch::new("shared");
        let guard = try_guard(&d.index(), true).unwrap().unwrap();
        let forked_copy = guard.0.try_clone().unwrap();
        drop(guard);
        let next = try_guard(&d.index(), false).unwrap().unwrap();
        drop(next);
        drop(forked_copy);
    }

    #[test]
    fn child_holds_guard() {
        let Some(root) = std::env::var_os("CACHE_GUARD_CHILD_ROOT") else { return };
        let root = PathBuf::from(root);
        let _guard = try_guard(&root.join("index"), true).unwrap().unwrap();
        std::fs::write(root.join("ready"), b"held").unwrap();
        loop { std::thread::sleep(Duration::from_millis(100)); }
    }

    #[test]
    fn killed_owner_releases_immediately_and_preserves_checkpoint() {
        let d = Scratch::new("crash");
        let checkpoint = d.index().join("checkpoint");
        std::fs::write(&checkpoint, b"resume-at-20").unwrap();
        let module = module_path!().split_once("::").unwrap().1;
        let mut child = ChildOwner(Command::new(std::env::current_exe().unwrap())
            .arg("--exact").arg(format!("{module}::child_holds_guard"))
            .env("CACHE_GUARD_CHILD_ROOT", &d.0).spawn().unwrap());
        let until = Instant::now() + Duration::from_secs(20);
        while !d.0.join("ready").exists() {
            assert!(Instant::now() < until, "child never acquired guard");
            assert!(child.0.try_wait().unwrap().is_none(), "child exited early");
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(try_guard(&d.index(), false).unwrap_err().kind(), io::ErrorKind::WouldBlock);
        child.0.kill().unwrap();
        child.0.wait().unwrap();
        let recovered = try_guard(&d.index(), true).unwrap().unwrap();
        assert_eq!(std::fs::read(&checkpoint).unwrap(), b"resume-at-20");
        drop(recovered);
    }
}
