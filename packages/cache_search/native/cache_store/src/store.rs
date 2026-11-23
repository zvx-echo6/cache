use std::{
    collections::{HashMap, HashSet},
    fs::{self, File, OpenOptions},
    io::{self, Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex, MutexGuard,
    },
    time::UNIX_EPOCH,
};

use bao_tree::{
    io::{
        outboard::PreOrderOutboard,
        sync::{decode_ranges, encode_ranges_validated, outboard as build_outboard, OutboardMut, ReadAt, WriteAt},
    },
    BaoTree, BlockSize, ChunkNum, ChunkRanges,
};
use rusqlite::{params, Connection, OptionalExtension};

use crate::{Error, Hash, Result, BLOCK_BYTES, INLINE_MAX};

mod migrate;
pub use migrate::MoveReport;

const BLOCK: BlockSize = BlockSize::from_chunk_log(4);
const SCHEMA_VERSION: i64 = 2;

/// A function that gives a set of hashes, called when the store needs the current set.
pub type SetFn = Arc<dyn Fn() -> HashSet<Hash> + Send + Sync>;

/// How the store is opened.
#[derive(Clone)]
pub struct Options {
    /// Hashes [`Store::gc`] must keep besides the tagged ones (the files being fetched). Called by `gc`; must not call the store.
    pub protect: Option<SetFn>,
    /// Hashes whose files an outside view reads in place (the iroh bridge). `gc` keeps them, and the store never deletes, moves
    /// out or rewrites their data files. Called by `gc` and by [`ExportMode::Move`]; must not call the store.
    pub lent: Option<SetFn>,
    /// Complete data up to this size is kept inline in the index. Default [`INLINE_MAX`].
    pub inline_max: u64,
}

impl Default for Options {
    fn default() -> Self {
        Options { protect: None, lent: None, inline_max: INLINE_MAX }
    }
}

/// How a file is taken into the store.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ImportMode {
    /// The store keeps its own copy.
    Copy,
    /// The store records the file in place and trusts it while its size and modification time are unchanged.
    Reference,
}

/// How a file leaves the store.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportMode {
    /// A plain copy.
    Copy,
    /// A copy-on-write clone where the file system has it, else a plain copy.
    ReflinkOrCopy,
    /// For owned data: the store's file itself is moved to the target and the entry then refers to it in place. Anything else
    /// (inline, external, or a file an outside view reads) is copied instead.
    Move,
}

/// What an export did.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ExportHow {
    Copied,
    Reflinked,
    Moved,
}

/// The result of an export.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Exported {
    pub size: u64,
    pub how: ExportHow,
}

/// What the store holds of a hash.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Status {
    /// The whole file, readable now.
    Complete { size: u64 },
    /// Some verified chunks of a file of `size` bytes.
    Partial { size: u64, have: ChunkRanges },
    /// Nothing usable (never held, swept, or an in-place file that changed or went away).
    Absent,
}

/// What a [`Store::gc`] removed.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct GcReport {
    pub entries: usize,
    pub files: usize,
    pub bytes: u64,
}

/// Keeps a hash from [`Store::gc`] while it is alive (the use of iroh-blobs' temp tag).
pub struct TempTag {
    inner: Arc<Inner>,
    hash: Hash,
}

impl TempTag {
    pub fn hash(&self) -> Hash {
        self.hash
    }
}

impl Drop for TempTag {
    fn drop(&mut self) {
        let mut t = self.inner.temps.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(n) = t.get_mut(&self.hash) {
            *n -= 1;
            if *n == 0 {
                t.remove(&self.hash);
            }
        }
    }
}

/// An import's result. Holds the hash against `gc` until dropped.
pub struct Added {
    pub hash: Hash,
    pub size: u64,
    tag: TempTag,
}

impl Added {
    pub fn hash(&self) -> Hash {
        self.hash
    }
    /// The hold on the hash, to keep past this value.
    pub fn into_temp_tag(self) -> TempTag {
        self.tag
    }
}

/// Where the tests make the store fail (feature `test-hooks`).
#[cfg(feature = "test-hooks")]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Fault {
    /// Fail after files are renamed into place and before the index commit.
    BeforeCommit,
    /// Kill the one-time move once this many entries have finished in this run.
    MoveAfterEntries(usize),
    /// Kill the move after entry n (0-based, in this run) is in the store and before its journal row.
    MoveBeforeJournal(usize),
    /// Kill the move after every entry and tag is in and before the old store is deleted.
    MoveBeforeCleanup,
}

struct Inner {
    dir: PathBuf,
    conn: Mutex<Connection>,
    opts: Options,
    temps: Mutex<HashMap<Hash, usize>>,
    seq: AtomicU64,
    closed: AtomicBool,
    #[cfg(feature = "test-hooks")]
    fault: Mutex<Option<Fault>>,
}

/// The file store. Cheap to clone; all clones share one index. Methods are blocking (file and SQLite work): async callers use
/// `spawn_blocking`.
#[derive(Clone)]
pub struct Store {
    inner: Arc<Inner>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Stamp {
    size: u64,
    mtime_ns: i64,
}

fn stamp_of(m: &fs::Metadata) -> Stamp {
    let mtime_ns = match m.modified() {
        Ok(t) => match t.duration_since(UNIX_EPOCH) {
            Ok(d) => d.as_nanos() as i64,
            Err(e) => -(e.duration().as_nanos() as i64),
        },
        Err(_) => 0,
    };
    Stamp { size: m.len(), mtime_ns }
}

struct Row {
    size: u64,
    partial: bool,
    /// For a partial entry: the last chunk group has verified, which is what proves the size. Until then the size is only what
    /// a sender said.
    size_verified: bool,
    inline: Option<Vec<u8>>,
    have: ChunkRanges,
}

enum Source {
    Inline(Vec<u8>),
    Owned(PathBuf),
    External(PathBuf),
}

/// Positioned reads over memory or a file.
enum Data {
    Mem(Vec<u8>),
    File(File),
}

impl ReadAt for Data {
    fn read_at(&self, pos: u64, buf: &mut [u8]) -> io::Result<usize> {
        match self {
            Data::Mem(v) => v.as_slice().read_at(pos, buf),
            Data::File(f) => f.read_at(pos, buf),
        }
    }
}

/// Removes files that were being written unless they were renamed into place.
#[derive(Default)]
struct Tmp(Vec<PathBuf>);

impl Tmp {
    fn add(&mut self, p: PathBuf) -> PathBuf {
        self.0.push(p.clone());
        p
    }
    fn placed(&mut self, p: &Path) {
        self.0.retain(|q| q != p);
    }
}

impl Drop for Tmp {
    fn drop(&mut self) {
        for p in &self.0 {
            let _ = fs::remove_file(p);
        }
    }
}

/// Copies what it reads into a file.
struct Tee<'a, R> {
    r: R,
    out: Option<&'a mut File>,
}

impl<R: Read> Read for Tee<'_, R> {
    fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
        let n = self.r.read(buf)?;
        if let Some(o) = self.out.as_mut() {
            o.write_all(&buf[..n])?;
        }
        Ok(n)
    }
}

/// An outboard that keeps nothing (trees of one chunk group have no nodes).
struct NoOutboard;

impl OutboardMut for NoOutboard {
    fn save(&mut self, _: bao_tree::TreeNode, _: &(bao_tree::blake3::Hash, bao_tree::blake3::Hash)) -> io::Result<()> {
        Ok(())
    }
    fn sync(&mut self) -> io::Result<()> {
        Ok(())
    }
}

/// A partial file being filled by `decode_ranges`: notes every verified leaf it is given.
struct Track {
    file: File,
    seen: Arc<Mutex<ChunkRanges>>,
    size: u64,
    last: Arc<AtomicBool>,
}

impl WriteAt for Track {
    fn write_at(&mut self, pos: u64, buf: &[u8]) -> io::Result<usize> {
        self.file.write_at(pos, buf)
    }
    fn write_all_at(&mut self, pos: u64, buf: &[u8]) -> io::Result<()> {
        self.file.write_all_at(pos, buf)?;
        if !buf.is_empty() {
            if pos + buf.len() as u64 == self.size {
                self.last.store(true, Ordering::SeqCst);
            }
            let r = ChunkRanges::from(ChunkNum(pos / 1024)..ChunkNum((pos + buf.len() as u64).div_ceil(1024)));
            let mut s = self.seen.lock().unwrap_or_else(|e| e.into_inner());
            *s = s.union(&r);
        }
        Ok(())
    }
    fn flush(&mut self) -> io::Result<()> {
        WriteAt::flush(&mut self.file)
    }
}

struct Prepared {
    hash: Hash,
    size: u64,
    data: Option<PathBuf>,
    obao: Option<PathBuf>,
    tmp: Tmp,
}

fn encode_have(r: &ChunkRanges) -> Vec<u8> {
    let b = r.boundaries();
    let mut v = Vec::with_capacity(b.len() * 8);
    for c in b {
        v.extend_from_slice(&c.0.to_le_bytes());
    }
    v
}

fn decode_have(b: &[u8]) -> ChunkRanges {
    let n: Vec<u64> = b.as_chunks::<8>().0.iter().map(|w| u64::from_le_bytes(*w)).collect();
    let mut r = ChunkRanges::empty();
    for p in n.as_chunks::<2>().0 {
        r = r.union(&ChunkRanges::from(ChunkNum(p[0])..ChunkNum(p[1])));
    }
    r
}

fn all_chunks(size: u64) -> ChunkRanges {
    ChunkRanges::from(ChunkNum(0)..BaoTree::new(size, BLOCK).chunks())
}

fn path_str(p: &Path) -> Result<&str> {
    p.to_str().ok_or_else(|| Error::Invalid(format!("the path is not valid UTF-8: {}", p.display())))
}

fn absolute(p: &Path) -> Result<PathBuf> {
    std::path::absolute(p).map_err(Error::from)
}

fn sync_dir(p: &Path) {
    #[cfg(unix)]
    if let Ok(d) = File::open(p) {
        let _ = d.sync_all();
    }
    #[cfg(not(unix))]
    let _ = p;
}

fn ignore_missing(r: io::Result<()>) -> io::Result<()> {
    match r {
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(()),
        other => other,
    }
}

impl Store {
    /// Opens (creating if needed) the store in `dir`, and empties its `tmp/` folder. One process should hold a store open.
    pub fn open(dir: &Path, opts: Options) -> Result<Store> {
        let dir = absolute(dir)?;
        fs::create_dir_all(dir.join("data"))?;
        let tmp = dir.join("tmp");
        let _ = fs::remove_dir_all(&tmp);
        fs::create_dir_all(&tmp)?;
        let conn = Connection::open(dir.join("index.sqlite"))?;
        conn.busy_timeout(std::time::Duration::from_secs(10))?;
        let _: String = conn.query_row("PRAGMA journal_mode=WAL", [], |r| r.get(0))?;
        conn.pragma_update(None, "synchronous", "FULL")?;
        let version: i64 = conn.query_row("PRAGMA user_version", [], |r| r.get(0))?;
        if version > SCHEMA_VERSION {
            return Err(Error::Invalid("this store was made by a newer version of Cache".into()));
        }
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS files(
                hash BLOB PRIMARY KEY, size INTEGER NOT NULL, state INTEGER NOT NULL, location INTEGER NOT NULL,
                inline_data BLOB, inline_outboard BLOB, have BLOB, size_verified INTEGER NOT NULL DEFAULT 1) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS external(
                hash BLOB NOT NULL, path TEXT NOT NULL, size INTEGER NOT NULL, mtime_ns INTEGER NOT NULL,
                PRIMARY KEY(hash, path)) WITHOUT ROWID;
             CREATE INDEX IF NOT EXISTS external_path ON external(path);
             CREATE TABLE IF NOT EXISTS tags(name BLOB PRIMARY KEY, hash BLOB NOT NULL) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS move_journal(hash BLOB PRIMARY KEY, outcome TEXT NOT NULL, bytes INTEGER NOT NULL) WITHOUT ROWID;
             CREATE TABLE IF NOT EXISTS move_state(key TEXT PRIMARY KEY, value INTEGER NOT NULL) WITHOUT ROWID;",
        )?;
        if version == 1 {
            // Version 1 had no record of whether a partial entry's size was proven.
            conn.execute_batch("ALTER TABLE files ADD COLUMN size_verified INTEGER NOT NULL DEFAULT 1; UPDATE files SET size_verified=0 WHERE state=1;")?;
        }
        conn.pragma_update(None, "user_version", SCHEMA_VERSION)?;
        Ok(Store {
            inner: Arc::new(Inner {
                dir,
                conn: Mutex::new(conn),
                opts,
                temps: Mutex::new(HashMap::new()),
                seq: AtomicU64::new(0),
                closed: AtomicBool::new(false),
                #[cfg(feature = "test-hooks")]
                fault: Mutex::new(None),
            }),
        })
    }

    /// Flushes the index. Later calls on any clone fail.
    pub fn shutdown(&self) -> Result<()> {
        let c = self.db()?;
        let _: (i64, i64, i64) = c.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?;
        self.inner.closed.store(true, Ordering::SeqCst);
        Ok(())
    }

    #[cfg(feature = "test-hooks")]
    #[doc(hidden)]
    pub fn set_fault(&self, f: Option<Fault>) {
        *self.inner.fault.lock().unwrap() = f;
    }

    fn db(&self) -> Result<MutexGuard<'_, Connection>> {
        if self.inner.closed.load(Ordering::SeqCst) {
            return Err(Error::Invalid("the store is shut down".into()));
        }
        Ok(self.inner.conn.lock().unwrap_or_else(|e| e.into_inner()))
    }

    fn blob_path(&self, h: &Hash, ext: &str) -> PathBuf {
        let hex = h.to_hex();
        self.inner.dir.join("data").join(&hex[..2]).join(format!("{hex}.{ext}"))
    }

    fn tmp_path(&self, what: &str) -> PathBuf {
        let n = self.inner.seq.fetch_add(1, Ordering::SeqCst);
        let t = std::time::SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
        self.inner.dir.join("tmp").join(format!("{}-{t}-{n}.{what}", std::process::id()))
    }

    /// The store's own data file for a complete owned entry, for an outside view to reference in place (see [`Options::lent`]).
    pub fn owned_data_path(&self, h: &Hash) -> Option<PathBuf> {
        let p = self.blob_path(h, "data");
        let c = self.db().ok()?;
        let row = load_row(&c, h).ok()??;
        (!row.partial && fs::metadata(&p).map(|m| m.len() == row.size).unwrap_or(false)).then_some(p)
    }

    fn hold(&self, h: Hash) -> TempTag {
        *self.inner.temps.lock().unwrap_or_else(|e| e.into_inner()).entry(h).or_insert(0) += 1;
        TempTag { inner: self.inner.clone(), hash: h }
    }

    fn set_of(f: &Option<SetFn>) -> HashSet<Hash> {
        f.as_ref().map(|f| f()).unwrap_or_default()
    }

    // ---------------------------------------------------------------------------------------------------------------- reading

    /// Where the complete data of `row` can be read now, if anywhere.
    fn source(&self, c: &Connection, h: &Hash, row: &Row) -> Result<Option<Source>> {
        if let Some(d) = &row.inline {
            return Ok(Some(Source::Inline(d.clone())));
        }
        let p = self.blob_path(h, "data");
        if fs::metadata(&p).map(|m| m.len() == row.size).unwrap_or(false) {
            return Ok(Some(Source::Owned(p)));
        }
        let mut q = c.prepare("SELECT path, size, mtime_ns FROM external WHERE hash=?1")?;
        let rows = q.query_map([h.as_bytes().as_slice()], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?)))?;
        for r in rows {
            let (path, size, mtime_ns) = r?;
            if let Ok(m) = fs::metadata(&path) {
                if stamp_of(&m) == (Stamp { size: size as u64, mtime_ns }) && size as u64 == row.size {
                    return Ok(Some(Source::External(PathBuf::from(path))));
                }
            }
        }
        Ok(None)
    }

    fn partial_files_ok(&self, h: &Hash, size: u64) -> bool {
        let tree = BaoTree::new(size, BLOCK);
        fs::metadata(self.blob_path(h, "part")).map(|m| m.len() == size).unwrap_or(false)
            && (tree.outboard_size() == 0 || fs::metadata(self.blob_path(h, "pobao")).map(|m| m.len() == tree.outboard_size()).unwrap_or(false))
    }

    /// What the store holds of `hash`. A changed in-place file is `Absent`; it is not re-hashed.
    pub fn status(&self, hash: &Hash) -> Result<Status> {
        let c = self.db()?;
        let Some(row) = load_row(&c, hash)? else { return Ok(Status::Absent) };
        if row.partial {
            // The size may still be a sender's claim (see `size_verified`); the held chunks are verified either way, so a fetch
            // can resume. A different size from a later piece replaces an unproven one.
            return Ok(if self.partial_files_ok(hash, row.size) {
                Status::Partial { size: row.size, have: row.have }
            } else {
                Status::Absent
            });
        }
        Ok(match self.source(&c, hash, &row)? {
            Some(_) => Status::Complete { size: row.size },
            None => Status::Absent,
        })
    }

    /// True when the whole file is readable.
    pub fn has(&self, hash: &Hash) -> Result<bool> {
        Ok(matches!(self.status(hash)?, Status::Complete { .. }))
    }

    /// The whole file in memory (for small files).
    pub fn get_bytes(&self, hash: &Hash) -> Result<Vec<u8>> {
        let (size, src) = self.complete_source(hash)?;
        let v = match src {
            Source::Inline(d) => d,
            Source::Owned(p) | Source::External(p) => fs::read(p)?,
        };
        if v.len() as u64 != size {
            return Err(Error::Missing(format!("{} changed while it was read", hash.fmt_short())));
        }
        Ok(v)
    }

    fn complete_source(&self, hash: &Hash) -> Result<(u64, Source)> {
        let c = self.db()?;
        let row = load_row(&c, hash)?.ok_or_else(|| Error::Missing(hash.to_hex()))?;
        if row.partial {
            return Err(Error::Missing(format!("{} is only partly held", hash.fmt_short())));
        }
        let src = self.source(&c, hash, &row)?.ok_or_else(|| Error::Missing(format!("{} (its file is gone or changed)", hash.fmt_short())))?;
        Ok((row.size, src))
    }

    // ---------------------------------------------------------------------------------------------------------------- tags

    /// Points `name` at `hash` (replacing any earlier value). Tagged hashes are kept from `gc`.
    pub fn set_tag(&self, name: &[u8], hash: &Hash) -> Result<()> {
        let c = self.db()?;
        c.execute("INSERT OR REPLACE INTO tags(name, hash) VALUES(?1, ?2)", params![name, hash.as_bytes().as_slice()])?;
        Ok(())
    }

    /// Removes a tag; true if there was one.
    pub fn delete_tag(&self, name: &[u8]) -> Result<bool> {
        let c = self.db()?;
        Ok(c.execute("DELETE FROM tags WHERE name=?1", params![name])? > 0)
    }

    /// The tags whose names start with `prefix`, in name order.
    pub fn tags_with_prefix(&self, prefix: &[u8]) -> Result<Vec<(Vec<u8>, Hash)>> {
        let c = self.db()?;
        let mut q = c.prepare("SELECT name, hash FROM tags WHERE name >= ?1 ORDER BY name")?;
        let mut rows = q.query(params![prefix])?;
        let mut out = Vec::new();
        while let Some(r) = rows.next()? {
            let name: Vec<u8> = r.get(0)?;
            if !name.starts_with(prefix) {
                break;
            }
            let h: Vec<u8> = r.get(1)?;
            out.push((name, hash_from_blob(&h)?));
        }
        Ok(out)
    }

    // --------------------------------------------------------------------------------------------------------------- import

    /// Takes the file at `path` into the store. See [`ImportMode`]. The result holds the hash against `gc` until dropped.
    pub fn add_path(&self, path: &Path, mode: ImportMode) -> Result<Added> {
        self.add_path_inner(path, mode, None)
    }

    /// As [`Store::add_path`], and sets `tag` to the hash in the same index transaction.
    pub fn add_path_tagged(&self, path: &Path, mode: ImportMode, tag: &[u8]) -> Result<Added> {
        self.add_path_inner(path, mode, Some(tag))
    }

    /// Adds bytes held in memory (kept as an owned copy, or inline when small).
    pub fn add_bytes(&self, data: &[u8]) -> Result<Added> {
        self.add_reader(data, data.len() as u64)
    }

    /// Adds `size` bytes read from `r` (an owned copy, or inline when small). If `r` fails part way, nothing is added.
    pub fn add_reader(&self, mut r: impl Read, size: u64) -> Result<Added> {
        if size <= self.inner.opts.inline_max {
            let mut v = vec![0u8; size as usize];
            r.read_exact(&mut v)?;
            return self.commit_inline(v, None);
        }
        let p = self.prepare(r, size, true)?;
        self.commit(p, None, None)
    }

    fn add_path_inner(&self, path: &Path, mode: ImportMode, tag: Option<&[u8]>) -> Result<Added> {
        let path = absolute(path)?;
        let before = fs::metadata(&path)?;
        if !before.is_file() {
            return Err(Error::Invalid(format!("not a file: {}", path.display())));
        }
        let stamp = stamp_of(&before);
        let changed = || Error::FileChanged(path.display().to_string());
        if stamp.size <= self.inner.opts.inline_max {
            let v = fs::read(&path)?;
            if stamp_of(&fs::metadata(&path)?) != stamp || v.len() as u64 != stamp.size {
                return Err(changed());
            }
            return self.commit_inline(v, tag);
        }
        let file = File::open(&path)?;
        let p = self.prepare(io::BufReader::with_capacity(BLOCK_BYTES as usize, file), stamp.size, mode == ImportMode::Copy)?;
        if stamp_of(&fs::metadata(&path)?) != stamp {
            return Err(changed());
        }
        let ext = (mode == ImportMode::Reference).then_some((path, stamp));
        self.commit(p, ext, tag)
    }

    /// One pass over the data: hash it, write the pre-order outboard, and (for an owned copy) the data, all to temp files.
    fn prepare(&self, reader: impl Read, size: u64, keep_data: bool) -> Result<Prepared> {
        let tree = BaoTree::new(size, BLOCK);
        let mut tmp = Tmp::default();
        let data_path = keep_data.then(|| tmp.add(self.tmp_path("data")));
        let mut data_file = match &data_path {
            Some(p) => Some(File::create(p)?),
            None => None,
        };
        let reader = Tee { r: reader, out: data_file.as_mut() };
        let (root, obao) = if tree.outboard_size() > 0 {
            let path = tmp.add(self.tmp_path("obao"));
            let mut ob = PreOrderOutboard { root: bao_tree::blake3::Hash::from_bytes([0; 32]), tree, data: File::create(&path)? };
            let root = build_outboard(reader, tree, &mut ob)?;
            ob.data.sync_all()?;
            (root, Some(path))
        } else {
            (build_outboard(reader, tree, NoOutboard)?, None)
        };
        if let Some(f) = data_file {
            f.sync_all()?;
        }
        Ok(Prepared { hash: Hash::from(root), size, data: data_path, obao, tmp })
    }

    fn commit_inline(&self, data: Vec<u8>, tag: Option<&[u8]>) -> Result<Added> {
        let hash = Hash::new(&data);
        let size = data.len() as u64;
        let mut c = self.db()?;
        let tx = c.transaction()?;
        let existing = load_row(&tx, &hash)?;
        let had_partial = existing.as_ref().map(|r| r.partial).unwrap_or(false);
        // An existing complete entry stays as it is (it may be owned, or referenced in place).
        let keep = match &existing {
            Some(r) if !r.partial => self.source(&tx, &hash, r)?.is_some(),
            _ => false,
        };
        if !keep {
            tx.execute(
                "INSERT OR REPLACE INTO files(hash, size, state, location, inline_data) VALUES(?1, ?2, 0, 0, ?3)",
                params![hash.as_bytes().as_slice(), size as i64, data],
            )?;
        }
        if let Some(t) = tag {
            tx.execute("INSERT OR REPLACE INTO tags(name, hash) VALUES(?1, ?2)", params![t, hash.as_bytes().as_slice()])?;
        }
        self.fail_point_commit()?;
        tx.commit()?;
        if had_partial && !keep {
            self.remove_partial_files(&hash);
        }
        Ok(Added { hash, size, tag: self.hold(hash) })
    }

    fn commit(&self, mut p: Prepared, ext: Option<(PathBuf, Stamp)>, tag: Option<&[u8]>) -> Result<Added> {
        let hash = p.hash;
        let mut c = self.db()?;
        let tx = c.transaction()?;
        let existing = load_row(&tx, &hash)?;
        let had_partial = existing.as_ref().map(|r| r.partial).unwrap_or(false);
        let owned_data = self.blob_path(&hash, "data");
        let owned_ok = matches!(&existing, Some(r) if !r.partial && fs::metadata(&owned_data).map(|m| m.len() == r.size).unwrap_or(false));
        let dir = owned_data.parent().expect("data path has a parent").to_path_buf();
        fs::create_dir_all(&dir)?;
        if let Some(src) = p.data.clone() {
            if !owned_ok {
                fs::rename(&src, &owned_data)?;
                p.tmp.placed(&src);
            }
        }
        if let Some(src) = p.obao.clone() {
            let dest = self.blob_path(&hash, "obao");
            if !dest.exists() || had_partial {
                fs::rename(&src, &dest)?;
                p.tmp.placed(&src);
            }
        }
        sync_dir(&dir);
        let owned_now = owned_ok || p.data.is_some();
        tx.execute(
            "INSERT OR REPLACE INTO files(hash, size, state, location) VALUES(?1, ?2, 0, ?3)",
            params![hash.as_bytes().as_slice(), p.size as i64, if owned_now { 1 } else { 2 }],
        )?;
        if let Some((path, stamp)) = &ext {
            record_external(&tx, &hash, path, *stamp)?;
        }
        if let Some(t) = tag {
            tx.execute("INSERT OR REPLACE INTO tags(name, hash) VALUES(?1, ?2)", params![t, hash.as_bytes().as_slice()])?;
        }
        self.fail_point_commit()?;
        tx.commit()?;
        if had_partial {
            self.remove_partial_files(&hash);
        }
        Ok(Added { hash, size: p.size, tag: self.hold(hash) })
    }

    /// Test hook: fails here when the tests asked for it, between the file renames and the index commit.
    fn fail_point_commit(&self) -> Result<()> {
        #[cfg(feature = "test-hooks")]
        if *self.inner.fault.lock().unwrap() == Some(Fault::BeforeCommit) {
            return Err(Error::Invalid("injected failure before the index commit".into()));
        }
        Ok(())
    }

    fn remove_partial_files(&self, h: &Hash) {
        for e in ["part", "pobao"] {
            let _ = fs::remove_file(self.blob_path(h, e));
        }
    }

    // --------------------------------------------------------------------------------------------------------------- export

    /// Writes the file to `target`, atomically (a temp file in the same folder, renamed into place). See [`ExportMode`].
    pub fn export(&self, hash: &Hash, target: &Path, mode: ExportMode) -> Result<Exported> {
        let target = absolute(target)?;
        let (size, src) = self.complete_source(hash)?;
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent)?;
        }
        if let (ExportMode::Move, Source::Owned(own)) = (mode, &src) {
            // A file an outside view reads is never moved out from under it.
            if !Self::set_of(&self.inner.opts.lent).contains(hash) && self.move_out(hash, own, &target, size)? {
                return Ok(Exported { size, how: ExportHow::Moved });
            }
        }
        let name = target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
        let n = self.inner.seq.fetch_add(1, Ordering::SeqCst);
        let tmp = target.with_file_name(format!(".{name}.cache-store-{}-{n}", std::process::id()));
        let mut guard = Tmp::default();
        guard.add(tmp.clone());
        let how = match &src {
            Source::Inline(d) => {
                let mut f = File::create(&tmp)?;
                f.write_all(d)?;
                f.sync_all()?;
                ExportHow::Copied
            }
            Source::Owned(p) | Source::External(p) => {
                if mode == ExportMode::Copy {
                    fs::copy(p, &tmp)?;
                    ExportHow::Copied
                } else if reflink_copy::reflink(p, &tmp).is_ok() {
                    ExportHow::Reflinked
                } else {
                    // Any refusal (no support, another file system, a permission the file system gives for it) is a plain copy.
                    let _ = fs::remove_file(&tmp);
                    fs::copy(p, &tmp)?;
                    ExportHow::Copied
                }
            }
        };
        if fs::metadata(&tmp)?.len() != size {
            return Err(Error::FileChanged(format!("{} while it was exported", hash.fmt_short())));
        }
        fs::rename(&tmp, &target)?;
        guard.placed(&tmp);
        if let Some(parent) = target.parent() {
            sync_dir(parent);
        }
        Ok(Exported { size, how })
    }

    /// Moves the owned data file to `target` and records it as an in-place file. The in-place row is written first, so a
    /// crash between the steps loses nothing: the data is found either at the old place or the new one.
    fn move_out(&self, hash: &Hash, own: &Path, target: &Path, size: u64) -> Result<bool> {
        let stamp = stamp_of(&fs::metadata(own)?);
        {
            let mut c = self.db()?;
            let tx = c.transaction()?;
            record_external(&tx, hash, target, stamp)?;
            tx.commit()?;
        }
        if fs::rename(own, target).is_err() {
            // Another file system, or a target that cannot be replaced: the caller copies instead.
            let c = self.db()?;
            c.execute("DELETE FROM external WHERE hash=?1 AND path=?2", params![hash.as_bytes().as_slice(), path_str(target)?])?;
            return Ok(false);
        }
        sync_dir(own.parent().unwrap_or(Path::new(".")));
        if let Some(p) = target.parent() {
            sync_dir(p);
        }
        let c = self.db()?;
        c.execute("UPDATE files SET location=2 WHERE hash=?1 AND size=?2", params![hash.as_bytes().as_slice(), size as i64])?;
        Ok(true)
    }

    // ------------------------------------------------------------------------------------------------------ verified pieces

    /// Writes the verified piece of `hash` covering `ranges`: the size (8 bytes, little endian), then the BLAKE3 nodes and data
    /// in pre-order, 16 KiB chunk groups. Works for a complete file, and for a partial one whose held chunks cover `ranges`.
    /// Every piece is checked against the hash on its way out.
    pub fn encode_ranges(&self, hash: &Hash, ranges: &ChunkRanges, mut out: impl Write) -> Result<()> {
        let (size, data, outboard) = {
            let c = self.db()?;
            let row = load_row(&c, hash)?.ok_or_else(|| Error::Missing(hash.to_hex()))?;
            if row.partial {
                if !self.partial_files_ok(hash, row.size) {
                    return Err(Error::Missing(format!("{} (partial files are gone)", hash.fmt_short())));
                }
                let want: ChunkRanges = ranges.intersection(&all_chunks(row.size));
                if !row.have.is_superset(&want) {
                    return Err(Error::Missing(format!("{} (not all of those chunks are held)", hash.fmt_short())));
                }
                (row.size, Data::File(File::open(self.blob_path(hash, "part"))?), self.open_outboard(hash, row.size, "pobao")?)
            } else {
                let src = self
                    .source(&c, hash, &row)?
                    .ok_or_else(|| Error::Missing(format!("{} (its file is gone or changed)", hash.fmt_short())))?;
                let data = match src {
                    Source::Inline(d) => Data::Mem(d),
                    Source::Owned(p) | Source::External(p) => Data::File(File::open(p)?),
                };
                (row.size, data, self.open_outboard(hash, row.size, "obao")?)
            }
        };
        out.write_all(&size.to_le_bytes())?;
        if size == 0 {
            return Ok(());
        }
        let ob = PreOrderOutboard { root: (*hash).into(), tree: BaoTree::new(size, BLOCK), data: outboard };
        encode_ranges_validated(data, ob, ranges, out).map_err(|e| Error::Verify(e.to_string()))
    }

    /// [`Store::encode_ranges`] into memory.
    pub fn encode_ranges_to_vec(&self, hash: &Hash, ranges: &ChunkRanges) -> Result<Vec<u8>> {
        let mut v = Vec::new();
        self.encode_ranges(hash, ranges, &mut v)?;
        Ok(v)
    }

    fn open_outboard(&self, hash: &Hash, size: u64, ext: &str) -> Result<Data> {
        if BaoTree::new(size, BLOCK).outboard_size() == 0 {
            return Ok(Data::Mem(Vec::new()));
        }
        File::open(self.blob_path(hash, ext))
            .map(Data::File)
            .map_err(|e| Error::Missing(format!("the outboard of {}: {e}", hash.fmt_short())))
    }

    /// Takes a verified piece (as [`Store::encode_ranges`] writes it) for `ranges`. Each leaf is checked against the hash before
    /// it is written; what verified stays, and the chunks are recorded as held, even if a later part of the piece fails (the
    /// error is returned). When every chunk is held the entry becomes a complete owned file.
    pub fn import_ranges(&self, hash: &Hash, ranges: &ChunkRanges, bytes: &[u8]) -> Result<()> {
        if bytes.len() < 8 {
            return Err(Error::Verify("the piece is too short".into()));
        }
        let size = u64::from_le_bytes(bytes[..8].try_into().expect("8 bytes"));
        let body = &bytes[8..];
        if size == 0 {
            if *hash != Hash::EMPTY {
                return Err(Error::Verify("a size of zero is not this hash's".into()));
            }
            return self.commit_inline(Vec::new(), None).map(|_| ());
        }
        let tree = BaoTree::new(size, BLOCK);
        let (part, pobao) = {
            let mut c = self.db()?;
            let tx = c.transaction()?;
            let existing = load_row(&tx, hash)?;
            let mut fresh = true;
            match &existing {
                Some(r) if !r.partial => {
                    if self.source(&tx, hash, r)?.is_some() {
                        return Ok(());
                    }
                }
                // A size that was never proven gives way to a different one: what is held starts over.
                Some(r) if r.size != size && !r.size_verified => {}
                Some(r) if r.size != size => return Err(Error::Verify("the size differs from the proven size of the partial file".into())),
                Some(r) if self.partial_files_ok(hash, size) => fresh = r.have.is_empty(),
                _ => {}
            }
            fs::create_dir_all(self.blob_path(hash, "part").parent().expect("a data file has a folder"))?;
            let open = |ext: &str| OpenOptions::new().read(true).write(true).create(true).truncate(false).open(self.blob_path(hash, ext));
            let (part, pobao) = (open("part")?, open("pobao")?);
            if fresh {
                part.set_len(0)?;
                pobao.set_len(0)?;
            }
            part.set_len(size)?;
            pobao.set_len(tree.outboard_size())?;
            if fresh || existing.is_none() {
                tx.execute(
                    "INSERT OR REPLACE INTO files(hash, size, state, location, have, size_verified) VALUES(?1, ?2, 1, 1, ?3, 0)",
                    params![hash.as_bytes().as_slice(), size as i64, encode_have(&ChunkRanges::empty())],
                )?;
            }
            tx.commit()?;
            (part, pobao)
        };
        let seen = Arc::new(Mutex::new(ChunkRanges::empty()));
        let part_sync = part.try_clone()?;
        let mut ob = PreOrderOutboard { root: (*hash).into(), tree, data: pobao };
        let last = Arc::new(AtomicBool::new(false));
        let res = decode_ranges(body, ranges, Track { file: part, seen: seen.clone(), size, last: last.clone() }, &mut ob);
        // What verified is flushed and recorded whether or not the rest did.
        part_sync.sync_all()?;
        ob.data.sync_all()?;
        let seen = seen.lock().unwrap_or_else(|e| e.into_inner()).clone();
        self.record_have(hash, size, &seen, last.load(Ordering::SeqCst))?;
        res.map_err(|e| Error::Verify(e.to_string()))
    }

    fn record_have(&self, hash: &Hash, size: u64, seen: &ChunkRanges, last_verified: bool) -> Result<()> {
        let mut c = self.db()?;
        let tx = c.transaction()?;
        let row = load_row(&tx, hash)?.ok_or_else(|| Error::Missing(format!("{} was swept while it was fetched", hash.fmt_short())))?;
        if !row.partial {
            return Ok(());
        }
        if row.size != size {
            // Another piece restarted the entry under a different size while this one was being written.
            return Err(Error::Verify("the size changed while the piece was written".into()));
        }
        let have = row.have.union(seen);
        let verified = row.size_verified || last_verified;
        if !(verified && have.is_superset(&all_chunks(size))) {
            tx.execute(
                "UPDATE files SET have=?2, size_verified=?3 WHERE hash=?1",
                params![hash.as_bytes().as_slice(), encode_have(&have), verified],
            )?;
            tx.commit()?;
            return Ok(());
        }
        // Every chunk is held and verified: the partial files become the complete entry.
        let (part, pobao) = (self.blob_path(hash, "part"), self.blob_path(hash, "pobao"));
        if size <= self.inner.opts.inline_max {
            let data = fs::read(&part)?;
            tx.execute(
                "UPDATE files SET state=0, location=0, inline_data=?2, have=NULL WHERE hash=?1",
                params![hash.as_bytes().as_slice(), data],
            )?;
            tx.commit()?;
            self.remove_partial_files(hash);
            return Ok(());
        }
        let (data, obao) = (self.blob_path(hash, "data"), self.blob_path(hash, "obao"));
        fs::rename(&part, &data)?;
        fs::rename(&pobao, &obao)?;
        sync_dir(data.parent().expect("parent"));
        self.fail_point_commit()?;
        tx.execute("UPDATE files SET state=0, location=1, have=NULL WHERE hash=?1", params![hash.as_bytes().as_slice()])?;
        tx.commit()?;
        Ok(())
    }

    // -------------------------------------------------------------------------------------------------------------------- gc

    /// Removes what nothing refers to. An entry is kept if a tag points at it, a [`TempTag`] holds it, or `protect` or `lent`
    /// names it. A removed owned entry loses its data and outboard files; a removed in-place entry loses only its index rows,
    /// never the person's file. Files in `data/` that no index row accounts for are removed too.
    pub fn gc(&self) -> Result<GcReport> {
        let mut c = self.db()?;
        let mut keep: HashSet<Hash> = Self::set_of(&self.inner.opts.protect);
        keep.extend(Self::set_of(&self.inner.opts.lent));
        keep.extend(self.inner.temps.lock().unwrap_or_else(|e| e.into_inner()).keys().copied());
        let tx = c.transaction()?;
        {
            let mut q = tx.prepare("SELECT hash FROM tags")?;
            for r in q.query_map([], |r| r.get::<_, Vec<u8>>(0))? {
                keep.insert(hash_from_blob(&r?)?);
            }
        }
        let mut live: HashMap<Hash, bool> = HashMap::new();
        let mut dead = Vec::new();
        {
            let mut q = tx.prepare("SELECT hash, state FROM files")?;
            for r in q.query_map([], |r| Ok((r.get::<_, Vec<u8>>(0)?, r.get::<_, i64>(1)?)))? {
                let (h, state) = r?;
                let h = hash_from_blob(&h)?;
                if keep.contains(&h) {
                    live.insert(h, state == 1);
                } else {
                    dead.push(h);
                }
            }
        }
        for h in &dead {
            tx.execute("DELETE FROM files WHERE hash=?1", [h.as_bytes().as_slice()])?;
            tx.execute("DELETE FROM external WHERE hash=?1", [h.as_bytes().as_slice()])?;
        }
        // Rows for hashes no longer in files (an in-place row that outlived its entry).
        tx.execute("DELETE FROM external WHERE hash NOT IN (SELECT hash FROM files)", [])?;
        tx.commit()?;

        let mut report = GcReport { entries: dead.len(), ..Default::default() };
        let mut remove = |p: &Path| -> Result<()> {
            if let Ok(m) = fs::metadata(p) {
                ignore_missing(fs::remove_file(p))?;
                report.files += 1;
                report.bytes += m.len();
            }
            Ok(())
        };
        for h in &dead {
            for e in ["data", "obao", "part", "pobao"] {
                remove(&self.blob_path(h, e))?;
            }
        }
        // Files no row accounts for: a crash between a rename and its commit, a partial that completed, an old partial.
        for shard in fs::read_dir(self.inner.dir.join("data"))? {
            let shard = shard?.path();
            if !shard.is_dir() {
                continue;
            }
            for f in fs::read_dir(&shard)? {
                let f = f?.path();
                let name = f.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                let wanted = name.rsplit_once('.').and_then(|(stem, ext)| {
                    let h: Hash = stem.parse().ok()?;
                    let partial = *live.get(&h)?;
                    Some(if partial { ext == "part" || ext == "pobao" } else { ext == "data" || ext == "obao" })
                });
                if wanted != Some(true) {
                    remove(&f)?;
                }
            }
        }
        Ok(report)
    }
}

fn hash_from_blob(b: &[u8]) -> Result<Hash> {
    let a: [u8; 32] = b.try_into().map_err(|_| Error::Invalid("a hash in the index is not 32 bytes".into()))?;
    Ok(Hash::from_bytes(a))
}

fn load_row(c: &Connection, h: &Hash) -> Result<Option<Row>> {
    Ok(c.query_row("SELECT size, state, inline_data, have, size_verified FROM files WHERE hash=?1", [h.as_bytes().as_slice()], |r| {
        let have: Option<Vec<u8>> = r.get(3)?;
        Ok(Row {
            size: r.get::<_, i64>(0)? as u64,
            partial: r.get::<_, i64>(1)? == 1,
            size_verified: r.get::<_, i64>(4)? != 0,
            inline: r.get(2)?,
            have: have.map(|b| decode_have(&b)).unwrap_or_else(ChunkRanges::empty),
        })
    })
    .optional()?)
}

/// Records that `path` holds `hash`'s content now (and no longer any other hash's).
fn record_external(tx: &rusqlite::Transaction<'_>, hash: &Hash, path: &Path, stamp: Stamp) -> Result<()> {
    let p = path_str(path)?;
    tx.execute("DELETE FROM external WHERE path=?1 AND hash<>?2", params![p, hash.as_bytes().as_slice()])?;
    tx.execute(
        "INSERT OR REPLACE INTO external(hash, path, size, mtime_ns) VALUES(?1, ?2, ?3, ?4)",
        params![hash.as_bytes().as_slice(), p, stamp.size as i64, stamp.mtime_ns],
    )?;
    Ok(())
}
