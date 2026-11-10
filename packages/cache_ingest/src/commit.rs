//! The journaled commit of a book into a library. Every output is staged first as a complete file or folder beside its final place;
//! then a journal listing the renames is written to `<library>/.local/ingest-commit.json`, the renames are made, and the journal is
//! deleted last. A kill at any point leaves either no journal (nothing changed) or a journal that [`recover`] rolls forward, always
//! to the same result: for each entry, a staged item still there is swapped in (the old one first moved to its backup name), and an
//! item already swapped is left alone. A runtime failure rolls the finished renames back.

use crate::engine::Staged;
use crate::error::{Error, Result};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

pub const JOURNAL: &str = ".local/ingest-commit.json";

/// One output of the commit, with paths relative to the library folder.
#[derive(Debug, Clone, PartialEq)]
pub struct Step {
    /// Where it ends up.
    pub target: String,
    /// The complete staged copy that is renamed to `target`; `None` removes `target` (moved to `old`).
    pub stage: Option<String>,
    /// Where the previous `target` waits until the commit is finished.
    pub old: String,
}

/// The backup name of a file: hidden, beside it.
pub fn old_name_of_file(rel: &str) -> String {
    match rel.rsplit_once('/') {
        Some((d, n)) => format!("{d}/.{n}.cs-old"),
        None => format!(".{rel}.cs-old"),
    }
}

pub fn pending(lib: &Path) -> bool {
    lib.join(JOURNAL).is_file()
}

fn remove_any(p: &Path) {
    if p.is_dir() {
        let _ = std::fs::remove_dir_all(p);
    } else {
        let _ = std::fs::remove_file(p);
    }
}

/// Stops a simulated kill after a number of renames (tests); `None` never stops.
struct Killer(Option<usize>);

impl Killer {
    /// Asked before each rename; `false` means the process is "killed" here.
    fn allow(&mut self) -> bool {
        match &mut self.0 {
            None => true,
            Some(0) => false,
            Some(n) => {
                *n -= 1;
                true
            }
        }
    }
}

/// Renames unless killed; `Ok(false)` when killed.
fn mv(a: &Path, b: &Path, k: &mut Killer) -> std::io::Result<bool> {
    if !k.allow() {
        return Ok(false);
    }
    std::fs::rename(a, b)?;
    Ok(true)
}

fn forward_one(lib: &Path, s: &Step, k: &mut Killer) -> std::io::Result<bool> {
    let (t, o) = (lib.join(&s.target), lib.join(&s.old));
    match &s.stage {
        Some(st) => {
            let sp = lib.join(st);
            if sp.exists() {
                if t.exists() && !o.exists() && !mv(&t, &o, k)? {
                    return Ok(false);
                }
                if !mv(&sp, &t, k)? {
                    return Ok(false);
                }
            }
        }
        None => {
            if t.exists() && !o.exists() && !mv(&t, &o, k)? {
                return Ok(false);
            }
        }
    }
    Ok(true)
}

fn roll_forward(lib: &Path, steps: &[Step], k: &mut Killer) -> std::io::Result<bool> {
    for s in steps {
        if !forward_one(lib, s, k)? {
            return Ok(false);
        }
    }
    Ok(true)
}

fn roll_back(lib: &Path, steps: &[Step]) -> std::io::Result<()> {
    let mut k = Killer(None);
    for s in steps.iter().rev() {
        let (t, o) = (lib.join(&s.target), lib.join(&s.old));
        match &s.stage {
            Some(st) => {
                let sp = lib.join(st);
                if !sp.exists() {
                    if t.exists() {
                        mv(&t, &sp, &mut k)?;
                    }
                    if o.exists() {
                        mv(&o, &t, &mut k)?;
                    }
                }
            }
            None => {
                if o.exists() && !t.exists() {
                    mv(&o, &t, &mut k)?;
                }
            }
        }
    }
    Ok(())
}

fn finish(lib: &Path, steps: &[Step]) {
    for s in steps {
        remove_any(&lib.join(&s.old));
    }
    let _ = std::fs::remove_file(lib.join(JOURNAL));
}

fn write_journal(lib: &Path, steps: &[Step]) -> Result<()> {
    let v = json!({"v": 1, "steps": steps.iter().map(|s| json!({"target": s.target, "stage": s.stage, "old": s.old})).collect::<Vec<_>>()});
    let path: PathBuf = lib.join(JOURNAL);
    let tmp = crate::files::write_tmp(&path, v.to_string().as_bytes())?;
    std::fs::rename(&tmp, &path).map_err(|e| Error::io("writing the commit journal", e))
}

/// Makes the commit. `Ok(false)` only when `stop_after` simulated a kill (the journal is left as a kill would leave it).
pub fn run_with(lib: &Path, steps: &[Step], staged: &mut dyn Staged, stop_after: Option<usize>) -> Result<bool> {
    for s in steps {
        remove_any(&lib.join(&s.old));
    }
    write_journal(lib, steps)?;
    let mut k = Killer(stop_after);
    match roll_forward(lib, steps, &mut k) {
        Ok(true) => {}
        Ok(false) => return Ok(false),
        Err(e) => {
            staged.before_rollback();
            if roll_back(lib, steps).is_ok() {
                let _ = std::fs::remove_file(lib.join(JOURNAL));
            }
            return Err(Error::io("committing the book", e));
        }
    }
    if let Err(e) = staged.verify() {
        staged.before_rollback();
        if roll_back(lib, steps).is_ok() {
            let _ = std::fs::remove_file(lib.join(JOURNAL));
        }
        return Err(e);
    }
    finish(lib, steps);
    Ok(true)
}

pub fn run(lib: &Path, steps: &[Step], staged: &mut dyn Staged) -> Result<()> {
    run_with(lib, steps, staged, None).map(|_| ())
}

/// Finishes a commit a kill interrupted: rolls it forward. Returns whether there was a journal.
pub fn recover(lib: &Path) -> Result<bool> {
    let path = lib.join(JOURNAL);
    let Ok(text) = std::fs::read_to_string(&path) else { return Ok(false) };
    let v: Value = serde_json::from_str(&text).map_err(|e| Error::io("the commit journal", e))?;
    let steps: Vec<Step> = v["steps"]
        .as_array()
        .ok_or_else(|| Error::io("the commit journal", "no steps"))?
        .iter()
        .map(|s| Step { target: s["target"].as_str().unwrap_or("").to_string(), stage: s["stage"].as_str().map(str::to_string), old: s["old"].as_str().unwrap_or("").to_string() })
        .collect();
    if steps.iter().any(|s| s.target.is_empty() || s.old.is_empty() || s.target.contains("..") || s.stage.as_deref().is_some_and(|x| x.contains(".."))) {
        return Err(Error::io("the commit journal", "a path is not inside the library"));
    }
    roll_forward(lib, &steps, &mut Killer(None)).map_err(|e| Error::io("finishing an interrupted commit", e))?;
    finish(lib, &steps);
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::engine::Swap;

    struct Dummy;
    impl Staged for Dummy {
        fn plan(&self) -> Vec<Swap> {
            Vec::new()
        }
        fn verify(&mut self) -> Result<()> {
            Ok(())
        }
        fn before_rollback(&mut self) {}
    }

    fn setup(root: &Path) -> Vec<Step> {
        let w = |p: &str, c: &str| {
            let p = root.join(p);
            std::fs::create_dir_all(p.parent().unwrap()).unwrap();
            std::fs::write(p, c).unwrap();
        };
        w("shard/seg", "old shard");
        w("shard.cs-stage/seg", "new shard");
        w("index/i", "old index");
        w("copies.jsonl", "old copies");
        w(".copies.jsonl.ingest.tmp", "new copies");
        w("packs/.b.cdoc.ingest.tmp", "new pack");
        w("SHA256SUMS", "old sums");
        w(".SHA256SUMS.ingest.tmp", "new sums");
        vec![
            Step { target: "shard".into(), stage: Some("shard.cs-stage".into()), old: "shard.cs-old".into() },
            Step { target: "index".into(), stage: None, old: "index.cs-old".into() },
            Step { target: "packs/b.cdoc".into(), stage: Some("packs/.b.cdoc.ingest.tmp".into()), old: old_name_of_file("packs/b.cdoc") },
            Step { target: "copies.jsonl".into(), stage: Some(".copies.jsonl.ingest.tmp".into()), old: old_name_of_file("copies.jsonl") },
            Step { target: "SHA256SUMS".into(), stage: Some(".SHA256SUMS.ingest.tmp".into()), old: old_name_of_file("SHA256SUMS") },
        ]
    }

    fn check_final(root: &Path) {
        let r = |p: &str| std::fs::read_to_string(root.join(p)).unwrap();
        assert_eq!(r("shard/seg"), "new shard");
        assert!(!root.join("index").exists());
        assert_eq!(r("packs/b.cdoc"), "new pack");
        assert_eq!(r("copies.jsonl"), "new copies");
        assert_eq!(r("SHA256SUMS"), "new sums");
        for gone in ["shard.cs-stage", "shard.cs-old", "index.cs-old", ".copies.jsonl.cs-old", ".SHA256SUMS.cs-old", ".copies.jsonl.ingest.tmp", "packs/.b.cdoc.ingest.tmp"] {
            assert!(!root.join(gone).exists(), "{gone} is left");
        }
        assert!(!pending(root));
    }

    #[test]
    fn an_uninterrupted_commit_swaps_everything_and_leaves_no_journal() {
        let d = tempfile::tempdir().unwrap();
        let steps = setup(d.path());
        run(d.path(), &steps, &mut Dummy).unwrap();
        check_final(d.path());
    }

    #[test]
    fn a_kill_after_any_rename_rolls_forward_to_the_same_result() {
        // renames of an uninterrupted run: shard 2, index 1, pack 1, copies 2, sums 2 = 8
        for kill_after in 0..=8usize {
            let d = tempfile::tempdir().unwrap();
            let steps = setup(d.path());
            let done = run_with(d.path(), &steps, &mut Dummy, Some(kill_after)).unwrap();
            if kill_after < 8 {
                assert!(!done, "killed after {kill_after}");
                assert!(pending(d.path()), "the journal is there after a kill at {kill_after}");
            }
            // a restart: the journal is rolled forward (and rolling forward twice changes nothing)
            assert_eq!(recover(d.path()).unwrap(), kill_after < 8, "kill_after {kill_after}");
            assert!(!recover(d.path()).unwrap());
            check_final(d.path());
        }
    }

    #[test]
    fn a_failed_verify_puts_everything_back() {
        struct Fails;
        impl Staged for Fails {
            fn plan(&self) -> Vec<Swap> {
                Vec::new()
            }
            fn verify(&mut self) -> Result<()> {
                Err(Error::io("opening", "no"))
            }
            fn before_rollback(&mut self) {}
        }
        let d = tempfile::tempdir().unwrap();
        let steps = setup(d.path());
        assert!(run(d.path(), &steps, &mut Fails).is_err());
        let r = |p: &str| std::fs::read_to_string(d.path().join(p)).unwrap();
        assert_eq!((r("shard/seg"), r("index/i"), r("copies.jsonl"), r("SHA256SUMS")), ("old shard".into(), "old index".into(), "old copies".into(), "old sums".into()));
        assert!(!d.path().join("packs/b.cdoc").exists());
        assert!(d.path().join("shard.cs-stage/seg").exists(), "the staged copy is back for the caller to remove");
        assert!(!pending(d.path()));
    }
}
