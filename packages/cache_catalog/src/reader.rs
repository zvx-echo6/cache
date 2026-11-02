//! The catalogue file: header, block indexes and lookups.

use crate::blake2b::blake2b_64;
use crate::lcc::{lcc_text, LccTable};
use crate::norm::{author_surname, isbn13, normalise_title};
use std::fmt;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::sync::Mutex;

/// The file format this reader understands.
pub const FORMAT_VERSION: u32 = 1;

const MAGIC: &[u8; 8] = b"CACHEBKC";
/// Largest header (it holds the conversion table) and largest uncompressed block the reader accepts.
const MAX_HEADER: usize = 16 << 20;
const MAX_BLOCK: usize = 16 << 20;

/// Why a catalogue file could not be opened or read.
#[derive(Debug)]
pub enum CatalogError {
    Io(std::io::Error),
    /// Not a catalogue file, or damaged.
    Corrupt(&'static str),
    /// A format version this reader does not know.
    Unsupported(u32),
}

impl fmt::Display for CatalogError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            CatalogError::Io(e) => write!(f, "catalogue i/o error: {e}"),
            CatalogError::Corrupt(m) => write!(f, "catalogue file is damaged: {m}"),
            CatalogError::Unsupported(v) => write!(f, "catalogue format {v} is not supported (this reader reads format {FORMAT_VERSION})"),
        }
    }
}

impl std::error::Error for CatalogError {}

impl From<std::io::Error> for CatalogError {
    fn from(e: std::io::Error) -> Self {
        CatalogError::Io(e)
    }
}

/// A book found in the catalogue.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Entry {
    /// Library of Congress class, such as "PS3558" (subclass letters and class number).
    pub lcc: String,
    /// The Cache division the file's embedded table gives for [`Entry::lcc`]; `None` when it has no rule or says "none".
    pub division: Option<String>,
    /// Clean title (cut at 100 characters).
    pub title: String,
    /// Author as the catalogue names them, often "Surname, Given"; empty when unknown.
    pub author: String,
    /// Year of the first edition seen, `None` when unknown.
    pub year: Option<u16>,
}

#[derive(Debug, Clone, Copy)]
struct Section {
    offset: u64,
    length: u64,
    n_blocks: usize,
}

struct Index {
    sec: Section,
    /// `(first key or first record id, block offset from the section start)` per block.
    entries: Vec<(u64, u64)>,
}

/// An open catalogue file.
pub struct Catalog {
    file: Mutex<File>,
    catalogue_date: u32,
    build_date: u32,
    hash_bits: u32,
    attribution: String,
    licence: String,
    table: LccTable,
    isbn: Index,
    hash: Index,
    meta: Index,
}

struct Cursor<'a> {
    b: &'a [u8],
    pos: usize,
}

impl<'a> Cursor<'a> {
    fn new(b: &'a [u8]) -> Self {
        Cursor { b, pos: 0 }
    }
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let end = self.pos.checked_add(n)?;
        let s = self.b.get(self.pos..end)?;
        self.pos = end;
        Some(s)
    }
    fn u8(&mut self) -> Option<u8> {
        self.take(1).map(|s| s[0])
    }
    fn u16(&mut self) -> Option<u16> {
        self.take(2).map(|s| u16::from_le_bytes([s[0], s[1]]))
    }
    fn u32(&mut self) -> Option<u32> {
        self.take(4).map(|s| u32::from_le_bytes([s[0], s[1], s[2], s[3]]))
    }
    fn u64(&mut self) -> Option<u64> {
        self.take(8).map(|s| {
            let mut w = [0u8; 8];
            w.copy_from_slice(s);
            u64::from_le_bytes(w)
        })
    }
    fn varint(&mut self) -> Option<u64> {
        let mut v = 0u64;
        let mut shift = 0u32;
        loop {
            let c = self.u8()?;
            if shift > 63 {
                return None;
            }
            v |= u64::from(c & 0x7f) << shift;
            if c & 0x80 == 0 {
                return Some(v);
            }
            shift += 7;
        }
    }
    fn string16(&mut self) -> Option<String> {
        let n = usize::from(self.u16()?);
        Some(String::from_utf8_lossy(self.take(n)?).into_owned())
    }
}

fn unzigzag(z: u64) -> i64 {
    if z & 1 == 0 {
        (z >> 1) as i64
    } else {
        -(((z + 1) >> 1) as i64)
    }
}

impl Catalog {
    /// Opens a catalogue file: reads the header and the block indexes, nothing else.
    pub fn open(path: impl AsRef<Path>) -> Result<Catalog, CatalogError> {
        let mut file = File::open(path)?;
        let file_len = file.metadata()?.len();
        let mut head = [0u8; 16];
        file.read_exact(&mut head)?;
        if &head[..8] != MAGIC {
            return Err(CatalogError::Corrupt("not a Cache book catalogue"));
        }
        let version = u32::from_le_bytes([head[8], head[9], head[10], head[11]]);
        if version != FORMAT_VERSION {
            return Err(CatalogError::Unsupported(version));
        }
        let header_len = u32::from_le_bytes([head[12], head[13], head[14], head[15]]) as usize;
        if header_len > MAX_HEADER || 16 + header_len as u64 > file_len {
            return Err(CatalogError::Corrupt("header length"));
        }
        let mut body = vec![0u8; header_len];
        file.read_exact(&mut body)?;
        let mut c = Cursor::new(&body);
        let catalogue_date = c.u32().ok_or(CatalogError::Corrupt("header"))?;
        let build_date = c.u32().ok_or(CatalogError::Corrupt("header"))?;
        let hash_bits = u32::from(c.u8().ok_or(CatalogError::Corrupt("header"))?);
        c.take(3).ok_or(CatalogError::Corrupt("header"))?;
        let attribution = c.string16().ok_or(CatalogError::Corrupt("header"))?;
        let licence = c.string16().ok_or(CatalogError::Corrupt("header"))?;
        let _source = c.string16().ok_or(CatalogError::Corrupt("header"))?;
        let table_len = c.u32().ok_or(CatalogError::Corrupt("header"))? as usize;
        let table_text = String::from_utf8_lossy(c.take(table_len).ok_or(CatalogError::Corrupt("header"))?).into_owned();
        if hash_bits == 0 || hash_bits > 64 {
            return Err(CatalogError::Corrupt("hash bits"));
        }
        let mut secs = Vec::with_capacity(3);
        for _ in 0..3 {
            let offset = c.u64().ok_or(CatalogError::Corrupt("header"))?;
            let length = c.u64().ok_or(CatalogError::Corrupt("header"))?;
            let _records = c.u64().ok_or(CatalogError::Corrupt("header"))?;
            let n_blocks = c.u32().ok_or(CatalogError::Corrupt("header"))? as usize;
            let _per_block = c.u32().ok_or(CatalogError::Corrupt("header"))?;
            if offset.checked_add(length).is_none_or(|end| end > file_len) || (n_blocks as u64) * 16 > length {
                return Err(CatalogError::Corrupt("section bounds"));
            }
            secs.push(Section { offset, length, n_blocks });
        }
        let mut load = |sec: Section| -> Result<Index, CatalogError> {
            let mut raw = vec![0u8; sec.n_blocks * 16];
            file.seek(SeekFrom::Start(sec.offset))?;
            file.read_exact(&mut raw)?;
            let mut c = Cursor::new(&raw);
            let mut entries = Vec::with_capacity(sec.n_blocks);
            for _ in 0..sec.n_blocks {
                let key = c.u64().ok_or(CatalogError::Corrupt("index"))?;
                let off = c.u64().ok_or(CatalogError::Corrupt("index"))?;
                if off > sec.length {
                    return Err(CatalogError::Corrupt("index offset"));
                }
                entries.push((key, off));
            }
            Ok(Index { sec, entries })
        };
        let isbn = load(secs[0])?;
        let hash = load(secs[1])?;
        let meta = load(secs[2])?;
        Ok(Catalog {
            file: Mutex::new(file),
            catalogue_date,
            build_date,
            hash_bits,
            attribution,
            licence,
            table: LccTable::parse(&table_text),
            isbn,
            hash,
            meta,
        })
    }

    /// "Book data from Open Library, openlibrary.org": show it wherever catalogue data is shown.
    pub fn attribution(&self) -> &str {
        &self.attribution
    }

    /// The licence note stored in the file header.
    pub fn licence(&self) -> &str {
        &self.licence
    }

    /// Date of the Open Library dump the file was built from, as YYYYMMDD.
    pub fn catalogue_date(&self) -> u32 {
        self.catalogue_date
    }

    /// Date the file was built, as YYYYMMDD.
    pub fn build_date(&self) -> u32 {
        self.build_date
    }

    /// The LCC to division table embedded in the file.
    pub fn lcc_table(&self) -> &LccTable {
        &self.table
    }

    /// Replaces the embedded table with a newer one (the tab-separated text), for entries returned from now on.
    pub fn set_lcc_table(&mut self, tsv: &str) {
        self.table = LccTable::parse(tsv);
    }

    /// The key a title lookup uses: the top `hash_bits` bits of the 64-bit BLAKE2b of "normalised title|surname".
    fn title_key(&self, normalised_title: &str, surname: &str) -> u64 {
        let d = blake2b_64(format!("{normalised_title}|{surname}").as_bytes());
        d >> (64 - self.hash_bits)
    }

    fn read_block(&self, idx: &Index, i: usize) -> Result<Vec<u8>, CatalogError> {
        let start = idx.entries[i].1;
        let end = if i + 1 < idx.entries.len() { idx.entries[i + 1].1 } else { idx.sec.length };
        if end < start {
            return Err(CatalogError::Corrupt("block bounds"));
        }
        let mut buf = vec![0u8; (end - start) as usize];
        {
            let mut f = self.file.lock().map_err(|_| CatalogError::Corrupt("file lock"))?;
            f.seek(SeekFrom::Start(idx.sec.offset + start))?;
            f.read_exact(&mut buf)?;
        }
        miniz_oxide::inflate::decompress_to_vec_with_limit(&buf, MAX_BLOCK).map_err(|_| CatalogError::Corrupt("block data"))
    }

    /// Finds `key` in a key section; returns the record's LCC key and metadata record id.
    fn find_key(&self, idx: &Index, key: u64) -> Result<Option<(u32, u64)>, CatalogError> {
        let after = idx.entries.partition_point(|e| e.0 <= key);
        if after == 0 {
            return Ok(None);
        }
        let first = idx.entries[after - 1].0;
        let raw = self.read_block(idx, after - 1)?;
        let mut c = Cursor::new(&raw);
        let n = c.u32().ok_or(CatalogError::Corrupt("key block"))? as usize;
        let mut hit = None;
        let mut k = first;
        for i in 0..n {
            k = k.checked_add(c.varint().ok_or(CatalogError::Corrupt("key block"))?).ok_or(CatalogError::Corrupt("key block"))?;
            if k == key {
                hit = Some(i);
            }
        }
        let Some(i) = hit else { return Ok(None) };
        let lcc_col = c.take(n * 4).ok_or(CatalogError::Corrupt("key block"))?;
        let code = u32::from_le_bytes([lcc_col[i * 4], lcc_col[i * 4 + 1], lcc_col[i * 4 + 2], lcc_col[i * 4 + 3]]);
        let mut mid = 0i64;
        for _ in 0..=i {
            mid += unzigzag(c.varint().ok_or(CatalogError::Corrupt("key block"))?);
        }
        if mid < 0 {
            return Err(CatalogError::Corrupt("record id"));
        }
        Ok(Some((code, mid as u64)))
    }

    fn read_meta(&self, id: u64) -> Result<(String, String, Option<u16>), CatalogError> {
        let after = self.meta.entries.partition_point(|e| e.0 <= id);
        if after == 0 {
            return Err(CatalogError::Corrupt("record id"));
        }
        let first = self.meta.entries[after - 1].0;
        let raw = self.read_block(&self.meta, after - 1)?;
        let mut c = Cursor::new(&raw);
        let n = u64::from(c.u32().ok_or(CatalogError::Corrupt("record block"))?);
        let want = id - first;
        if want >= n {
            return Err(CatalogError::Corrupt("record id"));
        }
        let mut author = String::new();
        for i in 0..=want {
            let tl = c.varint().ok_or(CatalogError::Corrupt("record block"))? as usize;
            let title = c.take(tl).ok_or(CatalogError::Corrupt("record block"))?;
            let al = c.varint().ok_or(CatalogError::Corrupt("record block"))? as usize;
            if al > 0 {
                author = String::from_utf8_lossy(c.take(al - 1).ok_or(CatalogError::Corrupt("record block"))?).into_owned();
            }
            let year = c.varint().ok_or(CatalogError::Corrupt("record block"))?;
            if i == want {
                let year = if year == 0 { None } else { u16::try_from(year).ok() };
                return Ok((String::from_utf8_lossy(title).into_owned(), author, year));
            }
        }
        Err(CatalogError::Corrupt("record block"))
    }

    fn entry(&self, hit: Option<(u32, u64)>) -> Result<Option<Entry>, CatalogError> {
        let Some((code, mid)) = hit else { return Ok(None) };
        let (title, author, year) = self.read_meta(mid)?;
        let lcc = lcc_text(code);
        let division = self.table.division(&lcc).map(str::to_string);
        Ok(Some(Entry { lcc, division, title, author, year }))
    }

    /// Like [`Catalog::lookup_isbn`], but a damaged file or a read error is an `Err` instead of a miss.
    pub fn try_lookup_isbn(&self, isbn: &str) -> Result<Option<Entry>, CatalogError> {
        let Some(digits) = isbn13(isbn) else { return Ok(None) };
        let Ok(key) = digits.parse::<u64>() else { return Ok(None) };
        self.entry(self.find_key(&self.isbn, key)?)
    }

    /// Like [`Catalog::lookup_title`], with errors reported.
    pub fn try_lookup_title(&self, normalised_title: &str, surname: &str) -> Result<Option<Entry>, CatalogError> {
        if normalised_title.is_empty() || surname.is_empty() {
            return Ok(None);
        }
        let key = self.title_key(normalised_title, surname);
        self.entry(self.find_key(&self.hash, key)?)
    }

    /// The book with this ISBN (ISBN-13 or ISBN-10, hyphens allowed), or `None` when the ISBN is invalid, not in the file, or
    /// the file cannot be read. Check the result with [`crate::accept_isbn_match`] before trusting it.
    pub fn lookup_isbn(&self, isbn13: &str) -> Option<Entry> {
        self.try_lookup_isbn(isbn13).ok().flatten()
    }

    /// The book with this normalised title ([`crate::normalise_title`]) and author surname ([`crate::author_surname`]).
    pub fn lookup_title(&self, normalised_title: &str, surname: &str) -> Option<Entry> {
        self.try_lookup_title(normalised_title, surname).ok().flatten()
    }

    /// [`Catalog::lookup_title`] after normalising a raw title and author name ("Tolkien, J. R. R." or "J. R. R. Tolkien").
    pub fn lookup_book(&self, title: &str, author: &str) -> Option<Entry> {
        self.lookup_title(&normalise_title(title), &author_surname(author))
    }
}
