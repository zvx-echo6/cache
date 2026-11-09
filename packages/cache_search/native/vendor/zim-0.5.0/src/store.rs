use std::collections::VecDeque;
use std::ops::Deref;
use std::sync::{Arc, Mutex};
use std::cmp::Ordering;
use std::fs::File;
use std::path::{Path, PathBuf};

use memmap::{Mmap, MmapOptions};

use crate::errors::{Error, Result};

/// A ZIM archive's bytes, which may be spread over several chunk files.
///
/// Archives too large for the target filesystem are split into chunks named `foobar.zimaa`,
/// `foobar.zimab`, and so on. Every offset in the format addresses the concatenation of those
/// chunks, so this presents them as a single address space.
pub struct Store {
    parts: Vec<Part>,
    len: u64,
}

/// A view keeps its mapping alive independently of the small lookup cache.
/// Returning a borrowed slice from a replaceable mapping would be unsound.
pub enum Bytes<'a> {
    Borrowed(&'a [u8]),
    Owned(Vec<u8>),
    Window(Arc<Mmap>, usize, usize),
}

impl Deref for Bytes<'_> {
    type Target = [u8];
    fn deref(&self) -> &[u8] {
        match self {
            Self::Borrowed(bytes) => bytes,
            Self::Owned(bytes) => bytes,
            Self::Window(map, from, to) => &map[*from..*to],
        }
    }
}

impl AsRef<[u8]> for Bytes<'_> {
    fn as_ref(&self) -> &[u8] { self }
}

// Pointer tables and directory entries usually advance through two separate
// regions. Keep two small windows; payload views own their own mapping lease.
const WINDOW_BYTES: u64 = 1024 * 1024;
const CACHE_WINDOWS: usize = 2;

struct Window {
    start: u64,
    map: Arc<Mmap>,
}

struct Part {
    start: u64,
    len: u64,
    file: File,
    map: Option<Mmap>,
    windows: Mutex<VecDeque<Window>>,
}

impl Part {
    fn end(&self) -> u64 { self.start + self.len }

    fn bytes(&self, from: u64, to: u64) -> Result<Bytes<'_>> {
        if to < from || to > self.len { return Err(Error::OutOfBounds); }
        if let Some(map) = &self.map {
            return Ok(Bytes::Borrowed(&map[usize::try_from(from)?..usize::try_from(to)?]));
        }
        let mut windows = self.windows.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(i) = windows.iter().position(|w|
            from >= w.start && to <= w.start + w.map.len() as u64
        ) {
            let window = windows.remove(i).unwrap();
            let bytes = Bytes::Window(window.map.clone(),
                usize::try_from(from - window.start)?, usize::try_from(to - window.start)?);
            windows.push_front(window);
            return Ok(bytes);
        }
        let start = from / WINDOW_BYTES * WINDOW_BYTES;
        // Cover the next block too. Otherwise each successive small slice that
        // crosses a block boundary extends the mapping by a few bytes.
        let len = (WINDOW_BYTES * 2).max(to - start).min(self.len - start);
        let map = Arc::new(unsafe {
            MmapOptions::new().offset(start).len(usize::try_from(len)?).map(&self.file)?
        });
        let bytes = Bytes::Window(map.clone(), usize::try_from(from-start)?, usize::try_from(to-start)?);
        // Large payloads stay alive only while their caller needs them.
        if len <= WINDOW_BYTES * 2 {
            windows.push_front(Window { start, map });
            windows.truncate(CACHE_WINDOWS);
        }
        Ok(bytes)
    }
}

impl Store {
    /// Opens an archive, falling back to its chunk files when `path` itself does not exist.
    ///
    /// A whole archive takes precedence over chunks of the same name. `path` may also name the
    /// first chunk directly, as `foobar.zimaa`.
    pub fn open(path: &Path) -> Result<Store> {
        Store::open_with(path, false)
    }

    /// Opens an archive through bounded mapping windows on every platform (as iOS always does), never one mapping of the whole
    /// file. A pass over the whole directory then keeps a few MiB mapped: through a whole-file mapping every page it reads stays
    /// in the process's resident memory (2.2 GB for the 30 M entries of a full Wikipedia, build 46).
    pub fn open_windowed(path: &Path) -> Result<Store> {
        Store::open_with(path, true)
    }

    fn open_with(path: &Path, windowed: bool) -> Result<Store> {
        // A path naming the first chunk always means the chunked archive - that file exists, but
        // opening it on its own would yield only the archive's first slice.
        let base = chunk_base(path);
        let names_first_chunk = base != path;

        if !names_first_chunk && path.is_file() {
            return Store::from_maps(vec![map_file(path, windowed)?]);
        }

        let mut maps = Vec::new();
        for suffix in chunk_suffixes() {
            let mut name = base.clone().into_os_string();
            name.push(suffix);

            let chunk = PathBuf::from(name);
            if !chunk.is_file() {
                // Chunks are consecutive, so the first gap is the end of the archive.
                break;
            }

            maps.push(map_file(&chunk, windowed)?);
        }

        if maps.is_empty() {
            // Nothing under either name: surface the error for what the caller actually asked for.
            File::open(path)?;
            return Err(Error::OutOfBounds);
        }

        Store::from_maps(maps)
    }

    fn from_maps(maps: Vec<Part>) -> Result<Store> {
        let mut parts = Vec::with_capacity(maps.len());
        let mut len = 0u64;

        for mut part in maps {
            // An empty chunk would occupy an empty range, which no offset can land in.
            if part.len == 0 {
                continue;
            }

            part.start = len;
            len = len.checked_add(part.len).ok_or(Error::OutOfBounds)?;
            parts.push(part);
        }

        if parts.is_empty() {
            return Err(Error::InvalidHeader("archive is empty"));
        }

        Ok(Store { parts, len })
    }

    /// Total size of the archive, across all chunks.
    pub fn len(&self) -> u64 {
        self.len
    }

    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Returns `len` bytes starting at `start`.
    ///
    /// Borrows straight from the mapping when the range lies within one chunk - which is always
    /// the case for a single-file archive. A range straddling a chunk boundary has no contiguous
    /// backing, so it is copied instead.
    pub fn slice(&self, start: u64, len: u64) -> Result<Bytes<'_>> {
        let end = start.checked_add(len).ok_or(Error::OutOfBounds)?;
        if end > self.len {
            return Err(Error::OutOfBounds);
        }

        if len == 0 { return Ok(Bytes::Borrowed(&[])); }
        let idx = self.part_containing(start)?;
        let part = &self.parts[idx];

        if end <= part.end() {
            return part.bytes(start - part.start, end - part.start);
        }

        let mut out = Vec::with_capacity(usize::try_from(len)?);
        let mut pos = start;

        for part in &self.parts[idx..] {
            if pos >= end {
                break;
            }

            let from = pos - part.start;
            let to = end.min(part.end()) - part.start;
            out.extend_from_slice(&part.bytes(from, to)?);
            pos = part.end();
        }

        Ok(Bytes::Owned(out))
    }

    /// Returns up to `len` bytes starting at `start`, stopping at the end of the archive.
    ///
    /// Used where the length of a structure is not known up front and is instead determined by
    /// parsing it.
    pub fn slice_upto(&self, start: u64, len: u64) -> Result<Bytes<'_>> {
        if start > self.len {
            return Err(Error::OutOfBounds);
        }

        self.slice(start, len.min(self.len - start))
    }

    /// Reads `start..end` as a stream, without materialising it.
    ///
    /// Used for compressed cluster payloads, which are fed straight to a decoder - a cluster can
    /// be tens of megabytes, and copying it in order to decompress it would defeat the mapping.
    pub fn reader(&self, start: u64, end: u64) -> StoreReader<'_> {
        StoreReader {
            store: self,
            pos: start,
            end: end.min(self.len),
        }
    }

    /// Bounded views covering the prefix, released by the iterator's caller.
    pub fn prefix_chunks(&self, upto: u64) -> impl Iterator<Item = Result<Bytes<'_>>> {
        let upto = upto.min(self.len);
        (0..upto).step_by(WINDOW_BYTES as usize)
            .map(move |start| self.slice(start, WINDOW_BYTES.min(upto - start)))
    }

    fn part_containing(&self, offset: u64) -> Result<usize> {
        self.parts
            .binary_search_by(|part| {
                if offset < part.start {
                    Ordering::Greater
                } else if offset >= part.end() {
                    Ordering::Less
                } else {
                    Ordering::Equal
                }
            })
            .map_err(|_| Error::OutOfBounds)
    }
}

/// Streams a byte range of the archive, crossing chunk boundaries as needed.
pub struct StoreReader<'a> {
    store: &'a Store,
    pos: u64,
    end: u64,
}

impl std::io::Read for StoreReader<'_> {
    fn read(&mut self, buf: &mut [u8]) -> std::io::Result<usize> {
        if self.pos >= self.end || buf.is_empty() {
            return Ok(0);
        }

        let idx = self
            .store
            .part_containing(self.pos)
            .map_err(|_| std::io::Error::from(std::io::ErrorKind::UnexpectedEof))?;
        let part = &self.store.parts[idx];

        // One part per call; `Read` is free to return a short read, and the caller loops.
        let available = self.end.min(part.end()) - self.pos;
        let len = available.min(buf.len() as u64) as usize;
        let from = self.pos - part.start;
        let bytes = part.bytes(from, from + len as u64)
            .map_err(|e| std::io::Error::new(std::io::ErrorKind::Other, e.to_string()))?;
        buf[..len].copy_from_slice(&bytes);
        self.pos += len as u64;

        Ok(len)
    }
}

/// The base name chunks are built from.
///
/// `path` may name the first chunk rather than the archive, in which case the two-letter suffix
/// is stripped back off.
fn chunk_base(path: &Path) -> PathBuf {
    match path.to_str() {
        Some(name) if name.ends_with(".zimaa") => PathBuf::from(&name[..name.len() - 2]),
        _ => path.to_path_buf(),
    }
}

/// `aa`, `ab`, ... `zz`, in the order chunks are numbered.
fn chunk_suffixes() -> impl Iterator<Item = String> {
    (b'a'..=b'z').flat_map(|first| {
        (b'a'..=b'z').map(move |second| format!("{}{}", first as char, second as char))
    })
}

fn map_file(path: &Path, windowed: bool) -> Result<Part> {
    let file = File::open(path)?;
    let len = file.metadata()?.len();
    // iOS has a much smaller virtual address budget than desktop systems.
    // Also use windows if a desktop cannot reserve a full-file mapping.
    let map = if len == 0 || windowed || cfg!(any(target_os = "ios", feature = "windowed-mmap")) {
        None
    } else {
        unsafe { Mmap::map(&file) }.ok()
    };
    Ok(Part { start: 0, len, file, map, windows: Mutex::new(VecDeque::new()) })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunk_suffixes_are_ordered_and_complete() {
        let suffixes: Vec<String> = chunk_suffixes().collect();

        assert_eq!(suffixes.len(), 26 * 26);
        assert_eq!(suffixes[0], "aa");
        assert_eq!(suffixes[1], "ab");
        assert_eq!(suffixes[26], "ba");
        assert_eq!(suffixes[26 * 26 - 1], "zz");
    }

    #[test]
    fn chunk_base_strips_a_first_chunk_name() {
        // Both spellings must resolve to the same set of chunks.
        assert_eq!(chunk_base(Path::new("foo.zimaa")), PathBuf::from("foo.zim"));
        assert_eq!(chunk_base(Path::new("foo.zim")), PathBuf::from("foo.zim"));
    }
}

#[cfg(test)]
mod window_tests {
    use super::*;
    use std::io::{Read, Write};
    use std::sync::atomic::{AtomicU64, Ordering as AtomicOrdering};
    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Temp(PathBuf);
    impl Drop for Temp { fn drop(&mut self) { let _ = std::fs::remove_file(&self.0); } }
    fn file(bytes: &[u8]) -> Temp {
        let path = std::env::temp_dir().join(format!("zim-window-{}-{}",
            std::process::id(), NEXT.fetch_add(1, AtomicOrdering::Relaxed)));
        let mut file = File::create(&path).unwrap();
        file.write_all(bytes).unwrap();
        Temp(path)
    }
    fn windowed(path: &Path) -> Store {
        let file = File::open(path).unwrap();
        let len = file.metadata().unwrap().len();
        Store::from_maps(vec![Part { start: 0, len, file, map: None,
            windows: Mutex::new(VecDeque::new()) }]).unwrap()
    }
    #[test]
    fn window_lease_survives_cache_eviction_and_parallel_reads() {
        let bytes: Vec<u8> = (0..WINDOW_BYTES * 5).map(|i| (i % 251) as u8).collect();
        let tmp = file(&bytes);
        let store = windowed(&tmp.0);
        let held = store.slice(7, 90).unwrap();
        for i in 1..5 { assert_eq!(&*store.slice(i * WINDOW_BYTES, 90).unwrap(),
            &bytes[(i * WINDOW_BYTES) as usize..(i * WINDOW_BYTES) as usize + 90]); }
        assert_eq!(&*held, &bytes[7..97]);
        std::thread::scope(|scope| {
            for block in 0..5 { let store = &store; let bytes = &bytes;
                scope.spawn(move || { let at = block * WINDOW_BYTES + 9;
                    for _ in 0..30 { assert_eq!(&*store.slice(at, 70).unwrap(),
                        &bytes[at as usize..at as usize + 70]); } });
            }
        });
        assert!(store.parts[0].windows.lock().unwrap().len() <= CACHE_WINDOWS);
        assert!(store.parts[0].windows.lock().unwrap().iter().all(|w| w.map.len() as u64 <= WINDOW_BYTES * 2));
    }
    #[test]
    fn successive_boundary_reads_reuse_the_same_window() {
        let tmp = file(&vec![7; (WINDOW_BYTES * 3) as usize]);
        let store = windowed(&tmp.0);
        let a = store.slice(WINDOW_BYTES - 256, 512).unwrap();
        let b = store.slice(WINDOW_BYTES - 128, 512).unwrap();
        match (a,b) {
            (Bytes::Window(a,_,_),Bytes::Window(b,_,_)) => assert!(Arc::ptr_eq(&a,&b)),
            _ => panic!("expected reference-counted mapping windows"),
        }
    }

    #[test]
    fn window_boundaries_eof_streaming_and_checksum_prefix() {
        let bytes: Vec<u8> = (0..WINDOW_BYTES * 3 + 97).map(|i| (i % 239) as u8).collect();
        let tmp = file(&bytes); let store = windowed(&tmp.0);
        let start = WINDOW_BYTES - 29;
        assert_eq!(&*store.slice(start, 102).unwrap(), &bytes[start as usize..start as usize+102]);
        assert!(store.slice(store.len(), 0).unwrap().is_empty());
        assert!(store.slice(store.len()-1, 2).is_err());
        assert!(store.slice(u64::MAX, 2).is_err());
        let mut out = Vec::new(); store.reader(start, store.len()).read_to_end(&mut out).unwrap();
        assert_eq!(out, bytes[start as usize..]);
        let prefix: Vec<u8> = store.prefix_chunks(store.len()-17)
            .flat_map(|b| b.unwrap().to_vec()).collect();
        assert_eq!(prefix, bytes[..bytes.len()-17]);
    }
    #[test]
    fn windowed_reads_cross_archive_parts() {
        let a = file(b"abcdef"); let b = file(b"ghijk");
        let mut parts = Vec::new();
        for path in [&a.0,&b.0] { let file = File::open(path).unwrap();
            parts.push(Part { start: 0, len: file.metadata().unwrap().len(), file, map: None,
                windows: Mutex::new(VecDeque::new()) }); }
        let store = Store::from_maps(parts).unwrap();
        assert_eq!(&*store.slice(3, 6).unwrap(), b"defghi");
        let mut out = Vec::new(); store.reader(4, 10).read_to_end(&mut out).unwrap();
        assert_eq!(out, b"efghij");
    }
}
