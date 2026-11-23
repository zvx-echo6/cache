// Reads the database of an iroh-blobs 0.103.1 file store (`blobs/blobs.db`, a redb 4 database) without iroh.
//
// The entry-state types below are copied from iroh-blobs 0.103.1, src/store/fs/entry_state.rs, and the table names and key and
// value encodings from src/store/fs/meta/tables.rs, src/hash.rs and src/store/util.rs. Their copyright notice is kept:
//
//   Copyright 2023 N0, INC.
//
//   Licensed under either of the Apache License, Version 2.0 (http://www.apache.org/licenses/LICENSE-2.0) or the MIT license
//   (http://opensource.org/licenses/MIT), at your option. (MIT OR Apache-2.0)
//
// Only what reading needs is kept: no union, no formatting, no writing. redb checks each table's key and value type names, so the
// names below are exactly iroh-blobs'.

use std::{
    fs,
    path::{Path, PathBuf},
};

use redb::{Database, Key, ReadOnlyDatabase, ReadableDatabase, ReadableTable, TableDefinition, TypeName, Value};
use serde::{Deserialize, Serialize};

use crate::{Error, Result};

/// Location of the data.
#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum DataLocation<I = (), E = ()> {
    /// Data is in the inline_data table.
    Inline(I),
    /// Data is in the canonical location in the data directory.
    Owned(E),
    /// Data is in several external locations.
    External(Vec<PathBuf>, E),
}

/// Location of the outboard.
#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum OutboardLocation<I = ()> {
    /// Outboard is in the inline_outboard table.
    Inline(I),
    /// Outboard is in the canonical location in the data directory.
    Owned,
    /// Outboard is not needed.
    NotNeeded,
}

/// The information about an entry that iroh-blobs keeps in its entry table.
#[derive(Debug, Serialize, Deserialize, PartialEq, Eq)]
pub enum EntryState<I = ()> {
    /// The whole entry; the size is known.
    Complete { data_location: DataLocation<I, u64>, outboard_location: OutboardLocation<I> },
    /// Some of it. Never moved.
    Partial { size: Option<u64> },
}

#[derive(Debug, Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
enum BlobFormat {
    Raw,
    HashSeq,
}

#[derive(Debug, Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
struct HashAndFormat {
    hash: [u8; 32],
    format: BlobFormat,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct OldHash([u8; 32]);

impl Value for OldHash {
    type SelfType<'a> = OldHash;
    type AsBytes<'a> = &'a [u8; 32];
    fn fixed_width() -> Option<usize> {
        Some(32)
    }
    fn from_bytes<'a>(data: &'a [u8]) -> OldHash
    where
        Self: 'a,
    {
        OldHash(data.try_into().expect("a hash key is 32 bytes"))
    }
    fn as_bytes<'a, 'b: 'a>(value: &'a OldHash) -> &'a [u8; 32] {
        &value.0
    }
    fn type_name() -> TypeName {
        TypeName::new("iroh_blobs::Hash")
    }
}

impl Key for OldHash {
    fn compare(a: &[u8], b: &[u8]) -> std::cmp::Ordering {
        a.cmp(b)
    }
}

#[derive(Debug)]
struct OldTag(Vec<u8>);

impl Value for OldTag {
    type SelfType<'a> = OldTag;
    type AsBytes<'a> = &'a [u8];
    fn fixed_width() -> Option<usize> {
        None
    }
    fn from_bytes<'a>(data: &'a [u8]) -> OldTag
    where
        Self: 'a,
    {
        OldTag(data.to_vec())
    }
    fn as_bytes<'a, 'b: 'a>(value: &'a OldTag) -> &'a [u8] {
        &value.0
    }
    fn type_name() -> TypeName {
        TypeName::new("Tag")
    }
}

impl Key for OldTag {
    fn compare(a: &[u8], b: &[u8]) -> std::cmp::Ordering {
        a.cmp(b)
    }
}

impl Value for HashAndFormat {
    type SelfType<'a> = Option<HashAndFormat>;
    type AsBytes<'a> = Vec<u8>;
    fn fixed_width() -> Option<usize> {
        Some(33)
    }
    fn from_bytes<'a>(data: &'a [u8]) -> Option<HashAndFormat>
    where
        Self: 'a,
    {
        postcard::from_bytes(data).ok()
    }
    fn as_bytes<'a, 'b: 'a>(value: &'a Option<HashAndFormat>) -> Vec<u8> {
        match value {
            Some(v) => postcard::to_allocvec(v).unwrap_or_default(),
            None => Vec::new(),
        }
    }
    fn type_name() -> TypeName {
        TypeName::new("iroh_blobs::HashAndFormat")
    }
}

/// The entry table's values; a value that does not decode reads as `None` (the entry is then reported, not moved).
#[derive(Debug)]
struct EntryValue;

impl Value for EntryValue {
    type SelfType<'a> = Option<EntryState>;
    type AsBytes<'a> = Vec<u8>;
    fn fixed_width() -> Option<usize> {
        None
    }
    fn from_bytes<'a>(data: &'a [u8]) -> Option<EntryState>
    where
        Self: 'a,
    {
        postcard::from_bytes(data).ok()
    }
    fn as_bytes<'a, 'b: 'a>(value: &'a Option<EntryState>) -> Vec<u8> {
        match value {
            Some(v) => postcard::to_allocvec(v).unwrap_or_default(),
            None => Vec::new(),
        }
    }
    fn type_name() -> TypeName {
        TypeName::new("EntryState")
    }
}

const BLOBS_TABLE: TableDefinition<OldHash, EntryValue> = TableDefinition::new("blobs-0");
const TAGS_TABLE: TableDefinition<OldTag, HashAndFormat> = TableDefinition::new("tags-0");
const INLINE_DATA_TABLE: TableDefinition<OldHash, &[u8]> = TableDefinition::new("inline-data-0");

/// One entry of the old entry table.
pub struct OldEntry {
    pub hash: [u8; 32],
    /// `None`: the value did not decode.
    pub state: Option<EntryState>,
}

/// An old store's database, open for reading.
pub struct OldDb {
    handle: Handle,
}

enum Handle {
    ReadOnly(ReadOnlyDatabase),
    /// A repaired copy of a database that was not closed cleanly; deleted when this is dropped.
    Copy(Option<Database>, PathBuf),
}

impl Drop for OldDb {
    fn drop(&mut self) {
        if let Handle::Copy(db, path) = &mut self.handle {
            drop(db.take());
            let _ = fs::remove_file(&*path);
        }
    }
}

fn db_err(e: impl std::fmt::Display) -> Error {
    Error::Invalid(format!("the old store's database could not be read: {e}"))
}

impl OldDb {
    /// Opens `path` read-only. If it was not closed cleanly (a read-only open cannot repair), a copy is made at `scratch` and
    /// repaired and read instead: the original is never written.
    pub fn open(path: &Path, scratch: &Path) -> Result<OldDb> {
        match ReadOnlyDatabase::open(path) {
            Ok(db) => Ok(OldDb { handle: Handle::ReadOnly(db) }),
            Err(first) => {
                let _ = fs::remove_file(scratch);
                fs::copy(path, scratch)?;
                match Database::open(scratch) {
                    Ok(db) => Ok(OldDb { handle: Handle::Copy(Some(db), scratch.to_path_buf()) }),
                    Err(second) => {
                        let _ = fs::remove_file(scratch);
                        Err(db_err(format!("{first}; and repairing a copy failed: {second}")))
                    }
                }
            }
        }
    }

    /// True if this is a repaired copy.
    pub fn was_repaired(&self) -> bool {
        matches!(self.handle, Handle::Copy(..))
    }

    fn read(&self) -> Result<redb::ReadTransaction> {
        match &self.handle {
            Handle::ReadOnly(db) => db.begin_read(),
            Handle::Copy(db, _) => db.as_ref().expect("open until dropped").begin_read(),
        }
        .map_err(db_err)
    }

    /// Every entry and every tag (name, hash). A tag whose value does not decode, or that is not for a raw blob, is left out.
    #[allow(clippy::type_complexity)]
    pub fn list(&self) -> Result<(Vec<OldEntry>, Vec<(Vec<u8>, [u8; 32])>)> {
        let tx = self.read()?;
        let mut entries = Vec::new();
        match tx.open_table(BLOBS_TABLE) {
            Ok(t) => {
                for r in t.iter().map_err(db_err)? {
                    let (k, v) = r.map_err(db_err)?;
                    entries.push(OldEntry { hash: k.value().0, state: v.value() });
                }
            }
            Err(redb::TableError::TableDoesNotExist(_)) => {}
            Err(e) => return Err(db_err(e)),
        }
        let mut tags = Vec::new();
        match tx.open_table(TAGS_TABLE) {
            Ok(t) => {
                for r in t.iter().map_err(db_err)? {
                    let (k, v) = r.map_err(db_err)?;
                    if let Some(h) = v.value() {
                        if h.format == BlobFormat::Raw {
                            tags.push((k.value().0, h.hash));
                        }
                    }
                }
            }
            Err(redb::TableError::TableDoesNotExist(_)) => {}
            Err(e) => return Err(db_err(e)),
        }
        Ok((entries, tags))
    }

    /// The inline data of one entry.
    pub fn inline_data(&self, hash: &[u8; 32]) -> Result<Option<Vec<u8>>> {
        let tx = self.read()?;
        match tx.open_table(INLINE_DATA_TABLE) {
            Ok(t) => Ok(t.get(OldHash(*hash)).map_err(db_err)?.map(|v| v.value().to_vec())),
            Err(redb::TableError::TableDoesNotExist(_)) => Ok(None),
            Err(e) => Err(db_err(e)),
        }
    }
}

/// Test support: rewrites the start of every external path in an old database (`from` to `to`), so a fixture can be moved
/// between machines. Also renames the hash keys of nothing; only external paths change.
#[cfg(feature = "test-hooks")]
#[doc(hidden)]
pub fn rewrite_external_prefix(db_path: &Path, from: &Path, to: &Path) -> Result<usize> {
    let db = Database::open(db_path).map_err(db_err)?;
    let tx = db.begin_write().map_err(db_err)?;
    let mut changed = 0;
    {
        let mut t = tx.open_table(BLOBS_TABLE).map_err(db_err)?;
        let mut updates: std::collections::HashMap<[u8; 32], EntryState> = std::collections::HashMap::new();
        for r in t.iter().map_err(db_err)? {
            let (k, v) = r.map_err(db_err)?;
            if let Some(EntryState::Complete { data_location: DataLocation::External(paths, size), outboard_location }) = v.value() {
                let paths = paths.into_iter().map(|p| if let Ok(rest) = p.strip_prefix(from) { to.join(rest) } else { p }).collect();
                updates.insert(k.value().0, EntryState::Complete { data_location: DataLocation::External(paths, size), outboard_location });
            }
        }
        for (k, v) in updates {
            t.insert(OldHash(k), Some(v)).map_err(db_err)?;
            changed += 1;
        }
    }
    tx.commit().map_err(db_err)?;
    Ok(changed)
}
