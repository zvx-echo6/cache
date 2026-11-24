//! The one-time move of an iroh-blobs 0.103.1 store (`blobs/`) into this store.
//!
//! Every complete file is re-hashed before it counts as moved (the same pass writes its outboard fresh, so no old outboard is
//! trusted). Owned data files are renamed into the new layout, inline data goes into the index, in-place files are recorded where
//! they are, tags are recorded. A file that fails the re-hash is reported and left out. Partial downloads are not moved.
//!
//! `move_journal` has one row per finished entry, so a move that is killed resumes where it stopped and never doubles or loses an
//! entry. The old folder goes only after every entry is accounted for, and the database goes last.

use std::{
    fs::{self, File},
    io::BufReader,
    path::Path,
};

use rusqlite::params;

use super::{stamp_of, Stamp, Store};
use crate::{
    old_store::{DataLocation, EntryState, OldDb},
    Error, Hash, Result,
};

/// What the move did.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct MoveReport {
    /// Complete files moved, by kind.
    pub inline: usize,
    pub owned: usize,
    pub external: usize,
    /// Bytes of complete files moved.
    pub bytes: u64,
    /// Partial downloads dropped (they are fetched again).
    pub partials_dropped: usize,
    /// Tags recorded, and tags left out because their file is not in the store.
    pub tags: usize,
    pub tags_dropped: usize,
    /// Files that were not moved, and why: a re-hash that gave another id, a missing or changed file.
    pub failed: Vec<MoveFailure>,
    /// The database was not closed cleanly and a repaired copy of it was read.
    pub repaired: bool,
    /// Every tag that was not kept, with why.
    pub dropped_tags: Vec<DroppedTag>,
}

/// A tag the move did not carry over.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct DroppedTag {
    pub name: Vec<u8>,
    pub hash: Hash,
    /// Why: the old store has no entry for the hash (an orphan), the entry was a partial download, or its file was left out
    /// (with the reason).
    pub reason: String,
}

/// A file the move left out.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct MoveFailure {
    pub hash: Hash,
    /// `owned`, `inline`, `external` or `unknown` (the old entry could not be read).
    pub kind: String,
    pub reason: String,
}

impl MoveReport {
    /// What to log: one line per file left out (id, kind, reason), then one total line.
    pub fn log_lines(&self) -> Vec<String> {
        let mut v: Vec<String> =
            self.failed.iter().map(|f| format!("store move: left out {} ({}): {}", f.hash, f.kind, f.reason)).collect();
        v.extend(
            self.dropped_tags.iter().map(|t| format!("store move: dropped tag {} -> {}: {}", String::from_utf8_lossy(&t.name), t.hash, t.reason)),
        );
        v.push(format!(
            "store move: done. moved {} files ({} bytes): {} inline, {} owned, {} in place; {} partial downloads dropped; {} tags kept, {} dropped; {} left out{}",
            self.inline + self.owned + self.external,
            self.bytes,
            self.inline,
            self.owned,
            self.external,
            self.partials_dropped,
            self.tags,
            self.tags_dropped,
            self.failed.len(),
            if self.repaired { "; the old database was repaired from a copy" } else { "" }
        ));
        v
    }
}

enum Outcome {
    Inline(u64),
    Owned(u64),
    External(u64),
    Partial,
    Failed(String),
}

impl Outcome {
    fn text(&self) -> String {
        match self {
            Outcome::Inline(_) => "inline".into(),
            Outcome::Owned(_) => "owned".into(),
            Outcome::External(_) => "external".into(),
            Outcome::Partial => "partial".into(),
            Outcome::Failed(why) => format!("failed: {why}"),
        }
    }
    fn bytes(&self) -> u64 {
        match self {
            Outcome::Inline(n) | Outcome::Owned(n) | Outcome::External(n) => *n,
            _ => 0,
        }
    }
}

impl Store {
    /// True if `old_dir` (the old store's folder, holding `blobs.db`) still has a store to move.
    pub fn has_old_store(old_dir: &Path) -> bool {
        old_dir.join("blobs.db").exists()
    }

    /// Moves the old store in `old_dir` into this one, calling `progress(done, total)` in bytes of complete files as it goes.
    /// Returns `None` when there is no old store. Safe to call again after a kill: it resumes. Blocking; run it in the
    /// background and have sync wait for it.
    pub fn move_old_store(&self, old_dir: &Path, progress: &mut dyn FnMut(u64, u64)) -> Result<Option<MoveReport>> {
        let db_path = old_dir.join("blobs.db");
        if !db_path.exists() {
            // A move that was killed after the database went: nothing is left to do but the journal.
            self.db()?.execute_batch("DELETE FROM move_journal; DELETE FROM move_state; DELETE FROM move_tag_drops;")?;
            return Ok(None);
        }
        let old = OldDb::open(&db_path, &self.inner.dir.join("tmp").join("old-blobs-repair.db"))?;
        let (entries, tags) = old.list()?;
        let total: u64 = entries
            .iter()
            .filter_map(|e| match &e.state {
                Some(EntryState::Complete { data_location, .. }) => Some(match data_location {
                    DataLocation::Owned(n) | DataLocation::External(_, n) => *n,
                    DataLocation::Inline(()) => old.inline_data(&e.hash).ok().flatten().map(|d| d.len() as u64).unwrap_or(0),
                }),
                _ => None,
            })
            .sum();

        let mut done = 0u64;
        let mut this_run = 0usize;
        progress(0, total);
        for e in &entries {
            let hash = Hash::from_bytes(e.hash);
            let journaled: Option<(String, i64)> = {
                let c = self.db()?;
                c.query_row("SELECT outcome, bytes FROM move_journal WHERE hash=?1", [hash.as_bytes().as_slice()], |r| Ok((r.get(0)?, r.get(1)?)))
                    .map(Some)
                    .or_else(|e| if matches!(e, rusqlite::Error::QueryReturnedNoRows) { Ok(None) } else { Err(e) })?
            };
            if let Some((_, bytes)) = journaled {
                done += bytes as u64;
                progress(done, total);
                continue;
            }
            self.move_fault_before_entry(this_run)?;
            let outcome = match &e.state {
                None => Outcome::Failed("unknown: the entry in the old database could not be read".into()),
                Some(EntryState::Partial { .. }) => Outcome::Partial,
                Some(EntryState::Complete { data_location, .. }) => self.move_entry(old_dir, &old, &hash, data_location)?,
            };
            self.move_fault_before_journal(this_run)?;
            self.db()?.execute(
                "INSERT OR REPLACE INTO move_journal(hash, outcome, bytes) VALUES(?1, ?2, ?3)",
                params![hash.as_bytes().as_slice(), outcome.text(), outcome.bytes() as i64],
            )?;
            done += outcome.bytes();
            this_run += 1;
            progress(done, total);
        }

        // Tags, once: those whose file is in the store now.
        let tags_done: Option<i64> =
            self.db()?.query_row("SELECT value FROM move_state WHERE key='tags'", [], |r| r.get(0)).map(Some).or_else(|e| {
                if matches!(e, rusqlite::Error::QueryReturnedNoRows) {
                    Ok(None)
                } else {
                    Err(e)
                }
            })?;
        if tags_done.is_none() {
            let mut kept = Vec::new();
            let mut dropped: Vec<(&Vec<u8>, Hash, String)> = Vec::new();
            for (name, h) in &tags {
                let h = Hash::from_bytes(*h);
                if self.has(&h)? {
                    kept.push((name, h));
                    continue;
                }
                let outcome: Option<String> = {
                    let c = self.db()?;
                    c.query_row("SELECT outcome FROM move_journal WHERE hash=?1", [h.as_bytes().as_slice()], |r| r.get(0))
                        .map(Some)
                        .or_else(|e| if matches!(e, rusqlite::Error::QueryReturnedNoRows) { Ok(None) } else { Err(e) })?
                };
                let reason = match outcome.as_deref() {
                    None => "orphan: the old store has no entry for this hash".to_string(),
                    Some("partial") => "it belonged to a partial download, which is not moved".to_string(),
                    Some(o) if o.starts_with("failed: ") => format!("its file was left out ({})", o.trim_start_matches("failed: ")),
                    Some(o) => format!("the file is not in the store ({o})"),
                };
                dropped.push((name, h, reason));
            }
            let mut c = self.db()?;
            let tx = c.transaction()?;
            for (name, h, reason) in &dropped {
                tx.execute(
                    "INSERT OR REPLACE INTO move_tag_drops(name, hash, reason) VALUES(?1, ?2, ?3)",
                    params![name, h.as_bytes().as_slice(), reason],
                )?;
            }
            for (name, h) in &kept {
                tx.execute("INSERT OR REPLACE INTO tags(name, hash) VALUES(?1, ?2)", params![name, h.as_bytes().as_slice()])?;
            }
            tx.execute("INSERT OR REPLACE INTO move_state(key, value) VALUES('tags', ?1)", params![kept.len() as i64])?;
            tx.commit()?;
        }
        self.move_fault_before_cleanup()?;

        let report = self.move_report(tags.len(), old.was_repaired())?;
        drop(old);
        // Every entry is in. The files go first and the database last, so a kill in between still finds the journal.
        for sub in ["data", "temp"] {
            let d = old_dir.join(sub);
            if d.is_dir() {
                fs::remove_dir_all(&d)?;
            }
        }
        fs::remove_file(&db_path)?;
        let _ = fs::remove_dir(old_dir);
        self.db()?.execute_batch("DELETE FROM move_journal; DELETE FROM move_state; DELETE FROM move_tag_drops;")?;
        progress(total, total);
        Ok(Some(report))
    }

    fn move_report(&self, tags_in_old: usize, repaired: bool) -> Result<MoveReport> {
        let c = self.db()?;
        let mut r = MoveReport { repaired, ..Default::default() };
        let mut q = c.prepare("SELECT hash, outcome, bytes FROM move_journal")?;
        for row in q.query_map([], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?)))? {
            let (h, outcome, bytes) = row?;
            match outcome.as_str() {
                "inline" => r.inline += 1,
                "owned" => r.owned += 1,
                "external" => r.external += 1,
                "partial" => r.partials_dropped += 1,
                other => {
                    let a: [u8; 32] = h.as_slice().try_into().map_err(|_| Error::Invalid("a journal hash is not 32 bytes".into()))?;
                    let (kind, reason) = other.trim_start_matches("failed: ").split_once(": ").unwrap_or(("unknown", other));
                    r.failed.push(MoveFailure { hash: Hash::from_bytes(a), kind: kind.to_string(), reason: reason.to_string() });
                }
            }
            r.bytes += bytes as u64;
        }
        r.tags = c.query_row("SELECT value FROM move_state WHERE key='tags'", [], |r| r.get::<_, i64>(0)).unwrap_or(0) as usize;
        r.tags_dropped = tags_in_old.saturating_sub(r.tags);
        r.failed.sort();
        let mut q = c.prepare("SELECT name, hash, reason FROM move_tag_drops")?;
        for row in q.query_map([], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, Vec<u8>>(1)?, r.get::<_, String>(2)?)))? {
            let (name, h, reason) = row?;
            let a: [u8; 32] = h.as_slice().try_into().map_err(|_| Error::Invalid("a dropped tag's hash is not 32 bytes".into()))?;
            r.dropped_tags.push(DroppedTag { name, hash: Hash::from_bytes(a), reason });
        }
        r.dropped_tags.sort();
        Ok(r)
    }

    /// One complete entry. A problem with the file is an outcome; a problem with the new store is an error that stops the move.
    fn move_entry(&self, old_dir: &Path, old: &OldDb, hash: &Hash, loc: &DataLocation<(), u64>) -> Result<Outcome> {
        let kind = match loc {
            DataLocation::Inline(()) => "inline",
            DataLocation::Owned(_) => "owned",
            DataLocation::External(..) => "external",
        };
        let failed = |m: &str| Ok(Outcome::Failed(format!("{kind}: {m}")));
        match loc {
            DataLocation::Inline(()) => {
                let Some(data) = old.inline_data(hash.as_bytes())? else { return failed("the inline data is missing") };
                if Hash::new(&data) != *hash {
                    return failed("the inline data does not hash to its id");
                }
                let size = data.len() as u64;
                self.commit_inline(data, None)?;
                Ok(Outcome::Inline(size))
            }
            DataLocation::Owned(size) => {
                let src = old_dir.join("data").join(format!("{}.data", hash.to_hex()));
                match fs::metadata(&src) {
                    Ok(m) if m.len() == *size => {}
                    // Killed after the rename and before the journal: the file is in the new store already (it was re-hashed first).
                    _ if self.has(hash)? => return Ok(Outcome::Owned(*size)),
                    Ok(_) => return failed("the data file has the wrong size"),
                    Err(_) => return failed("the data file is missing"),
                }
                if *size <= self.inner.opts.inline_max {
                    let data = fs::read(&src)?;
                    if Hash::new(&data) != *hash {
                        return failed("the data does not hash to its id");
                    }
                    self.commit_inline(data, None)?;
                    return Ok(Outcome::Owned(*size));
                }
                let Ok(file) = File::open(&src) else { return failed("the data file cannot be opened") };
                let Ok(mut p) = self.prepare(BufReader::with_capacity(crate::BLOCK_BYTES as usize, file), *size, false) else {
                    return failed("the data file cannot be read");
                };
                if p.hash != *hash {
                    return failed("the data does not hash to its id");
                }
                p.data = Some(src.clone());
                match self.commit(p, None, None) {
                    Ok(_) => {}
                    Err(Error::Io(_)) => {
                        // The rename did not work (another file system): copy instead.
                        let file = File::open(&src)?;
                        let p = self.prepare(BufReader::new(file), *size, true)?;
                        if p.hash != *hash {
                            return failed("the data does not hash to its id");
                        }
                        self.commit(p, None, None)?;
                    }
                    Err(e) => return Err(e),
                }
                Ok(Outcome::Owned(*size))
            }
            DataLocation::External(paths, size) => {
                for path in paths {
                    let Ok(before) = fs::metadata(path) else { continue };
                    if !before.is_file() || before.len() != *size {
                        continue;
                    }
                    let stamp: Stamp = stamp_of(&before);
                    let Ok(file) = File::open(path) else { continue };
                    let Ok(p) = self.prepare(BufReader::with_capacity(crate::BLOCK_BYTES as usize, file), *size, false) else { continue };
                    if p.hash != *hash || fs::metadata(path).ok().map(|m| stamp_of(&m)) != Some(stamp) {
                        continue;
                    }
                    if *size <= self.inner.opts.inline_max {
                        let data = fs::read(path)?;
                        self.commit_inline(data, None)?;
                    } else {
                        self.commit(p, Some((path.clone(), stamp)), None)?;
                    }
                    return Ok(Outcome::External(*size));
                }
                failed("the file is gone, changed, or does not hash to its id")
            }
        }
    }

    // Test hooks: kill the move between entries, or between an entry's files and its journal row.
    fn move_fault_before_entry(&self, _n: usize) -> Result<()> {
        #[cfg(feature = "test-hooks")]
        if *self.inner.fault.lock().unwrap() == Some(super::Fault::MoveAfterEntries(_n)) {
            return Err(Error::Invalid(format!("injected kill after {_n} entries")));
        }
        Ok(())
    }

    fn move_fault_before_journal(&self, _n: usize) -> Result<()> {
        #[cfg(feature = "test-hooks")]
        if *self.inner.fault.lock().unwrap() == Some(super::Fault::MoveBeforeJournal(_n)) {
            return Err(Error::Invalid(format!("injected kill before the journal row of entry {_n}")));
        }
        Ok(())
    }

    fn move_fault_before_cleanup(&self) -> Result<()> {
        #[cfg(feature = "test-hooks")]
        if *self.inner.fault.lock().unwrap() == Some(super::Fault::MoveBeforeCleanup) {
            return Err(Error::Invalid("injected kill before the old store is deleted".into()));
        }
        Ok(())
    }
}
