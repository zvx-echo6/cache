//! PMTiles v3: reader over a local file or HTTP range reads, and a writer.

use crate::error::{io_at, Error, Result};
use flate2::read::GzDecoder;
use flate2::write::GzEncoder;
use flate2::Compression;
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

pub const HEADER_LEN: usize = 127;

pub const COMP_NONE: u8 = 1;
pub const COMP_GZIP: u8 = 2;
pub const TYPE_MVT: u8 = 1;
pub const TYPE_PNG: u8 = 2;
pub const TYPE_JPEG: u8 = 3;
pub const TYPE_WEBP: u8 = 4;

// ---- tile ids (Hilbert curve) ----

fn rotate(n: u64, x: &mut u64, y: &mut u64, rx: u64, ry: u64) {
    if ry == 0 {
        if rx == 1 {
            *x = n - 1 - *x;
            *y = n - 1 - *y;
        }
        std::mem::swap(x, y);
    }
}

pub fn zxy_to_id(z: u8, x: u32, y: u32) -> u64 {
    let acc: u64 = ((1u64 << (2 * z as u32)) - 1) / 3;
    let n: u64 = 1u64 << z;
    let (mut tx, mut ty) = (x as u64, y as u64);
    let mut d: u64 = 0;
    let mut s = n / 2;
    while s > 0 {
        let rx = u64::from(tx & s > 0);
        let ry = u64::from(ty & s > 0);
        d += s * s * ((3 * rx) ^ ry);
        rotate(n, &mut tx, &mut ty, rx, ry);
        s /= 2;
    }
    acc + d
}

pub fn id_to_zxy(id: u64) -> (u8, u32, u32) {
    let mut z: u8 = 0;
    let mut acc: u64 = 0;
    loop {
        let num = 1u64 << (2 * z as u32);
        if id < acc + num {
            break;
        }
        acc += num;
        z += 1;
    }
    let n: u64 = 1u64 << z;
    let mut t = id - acc;
    let (mut x, mut y) = (0u64, 0u64);
    let mut s = 1u64;
    while s < n {
        let rx = 1 & (t / 2);
        let ry = 1 & (t ^ rx);
        rotate(s, &mut x, &mut y, rx, ry);
        x += s * rx;
        y += s * ry;
        t /= 4;
        s *= 2;
    }
    (z, x as u32, y as u32)
}

// ---- header ----

#[derive(Debug, Clone, PartialEq, Default)]
pub struct Header {
    pub root_offset: u64,
    pub root_len: u64,
    pub meta_offset: u64,
    pub meta_len: u64,
    pub leaf_offset: u64,
    pub leaf_len: u64,
    pub data_offset: u64,
    pub data_len: u64,
    pub addressed_tiles: u64,
    pub tile_entries: u64,
    pub tile_contents: u64,
    pub clustered: bool,
    pub internal_compression: u8,
    pub tile_compression: u8,
    pub tile_type: u8,
    pub min_zoom: u8,
    pub max_zoom: u8,
    /// degrees: west, south, east, north
    pub bounds: [f64; 4],
    pub center_zoom: u8,
    pub center: [f64; 2],
}

fn u64_at(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
}
fn i32_at(b: &[u8], o: usize) -> i32 {
    i32::from_le_bytes(b[o..o + 4].try_into().unwrap())
}

impl Header {
    pub fn parse(b: &[u8]) -> Result<Header> {
        if b.len() < HEADER_LEN || &b[0..7] != b"PMTiles" {
            return Err(Error::bad_response("not a PMTiles file"));
        }
        if b[7] != 3 {
            return Err(Error::unsupported(format!("PMTiles version {} (only 3)", b[7])));
        }
        let e7 = |o| i32_at(b, o) as f64 / 1e7;
        Ok(Header {
            root_offset: u64_at(b, 8),
            root_len: u64_at(b, 16),
            meta_offset: u64_at(b, 24),
            meta_len: u64_at(b, 32),
            leaf_offset: u64_at(b, 40),
            leaf_len: u64_at(b, 48),
            data_offset: u64_at(b, 56),
            data_len: u64_at(b, 64),
            addressed_tiles: u64_at(b, 72),
            tile_entries: u64_at(b, 80),
            tile_contents: u64_at(b, 88),
            clustered: b[96] == 1,
            internal_compression: b[97],
            tile_compression: b[98],
            tile_type: b[99],
            min_zoom: b[100],
            max_zoom: b[101],
            bounds: [e7(102), e7(106), e7(110), e7(114)],
            center_zoom: b[118],
            center: [e7(119), e7(123)],
        })
    }

    pub fn serialize(&self) -> Vec<u8> {
        let mut b = vec![0u8; HEADER_LEN];
        b[0..7].copy_from_slice(b"PMTiles");
        b[7] = 3;
        for (i, v) in [
            self.root_offset,
            self.root_len,
            self.meta_offset,
            self.meta_len,
            self.leaf_offset,
            self.leaf_len,
            self.data_offset,
            self.data_len,
            self.addressed_tiles,
            self.tile_entries,
            self.tile_contents,
        ]
        .iter()
        .enumerate()
        {
            b[8 + i * 8..16 + i * 8].copy_from_slice(&v.to_le_bytes());
        }
        b[96] = u8::from(self.clustered);
        b[97] = self.internal_compression;
        b[98] = self.tile_compression;
        b[99] = self.tile_type;
        b[100] = self.min_zoom;
        b[101] = self.max_zoom;
        for (i, v) in self.bounds.iter().enumerate() {
            b[102 + i * 4..106 + i * 4].copy_from_slice(&((v * 1e7).round() as i32).to_le_bytes());
        }
        b[118] = self.center_zoom;
        b[119..123].copy_from_slice(&((self.center[0] * 1e7).round() as i32).to_le_bytes());
        b[123..127].copy_from_slice(&((self.center[1] * 1e7).round() as i32).to_le_bytes());
        b
    }
}

// ---- directories ----

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Entry {
    pub tile_id: u64,
    pub offset: u64,
    pub length: u32,
    /// 0 for a pointer to a leaf directory
    pub run_length: u32,
}

fn read_varint(b: &[u8], p: &mut usize) -> Result<u64> {
    let mut v: u64 = 0;
    let mut shift = 0;
    loop {
        let byte = *b.get(*p).ok_or_else(|| Error::bad_response("PMTiles directory is cut short"))?;
        *p += 1;
        v |= ((byte & 0x7f) as u64) << shift;
        if byte & 0x80 == 0 {
            return Ok(v);
        }
        shift += 7;
        if shift > 63 {
            return Err(Error::bad_response("bad varint in PMTiles directory"));
        }
    }
}

fn put_varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8 & 0x7f) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

pub fn decompress(data: &[u8], comp: u8) -> Result<Vec<u8>> {
    match comp {
        COMP_NONE | 0 => Ok(data.to_vec()),
        COMP_GZIP => {
            let mut out = Vec::new();
            GzDecoder::new(data).read_to_end(&mut out).map_err(|e| Error::bad_response(format!("gzip: {e}")))?;
            Ok(out)
        }
        c => Err(Error::unsupported(format!("PMTiles compression {c} (only none and gzip)"))),
    }
}

pub fn gzip(data: &[u8]) -> Vec<u8> {
    let mut e = GzEncoder::new(Vec::new(), Compression::new(6));
    let _ = e.write_all(data);
    e.finish().unwrap_or_default()
}

pub fn is_gzip(b: &[u8]) -> bool {
    b.len() > 2 && b[0] == 0x1f && b[1] == 0x8b
}

pub fn parse_dir(raw: &[u8]) -> Result<Vec<Entry>> {
    let mut p = 0;
    let n = read_varint(raw, &mut p)? as usize;
    if n > 50_000_000 {
        return Err(Error::bad_response("PMTiles directory too large"));
    }
    let mut es = vec![Entry { tile_id: 0, offset: 0, length: 0, run_length: 0 }; n];
    let mut last = 0u64;
    for e in es.iter_mut() {
        last += read_varint(raw, &mut p)?;
        e.tile_id = last;
    }
    for e in es.iter_mut() {
        e.run_length = read_varint(raw, &mut p)? as u32;
    }
    for e in es.iter_mut() {
        e.length = read_varint(raw, &mut p)? as u32;
    }
    for i in 0..n {
        let v = read_varint(raw, &mut p)?;
        es[i].offset = if v == 0 && i > 0 { es[i - 1].offset + es[i - 1].length as u64 } else { v.saturating_sub(1) };
    }
    Ok(es)
}

pub fn serialize_dir(es: &[Entry]) -> Vec<u8> {
    let mut out = Vec::new();
    put_varint(&mut out, es.len() as u64);
    let mut last = 0;
    for e in es {
        put_varint(&mut out, e.tile_id - last);
        last = e.tile_id;
    }
    for e in es {
        put_varint(&mut out, e.run_length as u64);
    }
    for e in es {
        put_varint(&mut out, e.length as u64);
    }
    for (i, e) in es.iter().enumerate() {
        if i > 0 && e.offset == es[i - 1].offset + es[i - 1].length as u64 {
            put_varint(&mut out, 0);
        } else {
            put_varint(&mut out, e.offset + 1);
        }
    }
    out
}

/// The entry covering `id` (a tile entry whose run holds it, or the leaf pointer to follow).
pub fn find(es: &[Entry], id: u64) -> Option<Entry> {
    let i = es.partition_point(|e| e.tile_id <= id);
    if i == 0 {
        return None;
    }
    let e = es[i - 1];
    if e.run_length == 0 {
        return Some(e);
    }
    if id < e.tile_id + e.run_length as u64 {
        Some(e)
    } else {
        None
    }
}

// ---- reader ----

pub trait RangeSource: Send + Sync {
    fn read(&self, offset: u64, len: u64) -> Result<Vec<u8>>;
    /// Several ranges at once (a source may overlap them); the default reads them one by one.
    fn read_many(&self, ranges: &[(u64, u64)]) -> Result<Vec<Vec<u8>>> {
        ranges.iter().map(|&(o, l)| self.read(o, l)).collect()
    }
}

pub struct FileSource(pub PathBuf);

impl RangeSource for FileSource {
    fn read(&self, offset: u64, len: u64) -> Result<Vec<u8>> {
        let mut f = std::fs::File::open(&self.0).map_err(|e| io_at("opening", &self.0, e))?;
        f.seek(SeekFrom::Start(offset)).map_err(|e| io_at("reading", &self.0, e))?;
        let mut buf = Vec::new();
        f.take(len).read_to_end(&mut buf).map_err(|e| io_at("reading", &self.0, e))?;
        Ok(buf)
    }
}

pub struct HttpSource {
    pub url: String,
    pub gate: Arc<crate::http::Gate>,
}

impl RangeSource for HttpSource {
    fn read(&self, offset: u64, len: u64) -> Result<Vec<u8>> {
        let r = crate::http::get(&self.url, Some((offset, len)), Some(&self.gate))?;
        if r.status != 200 {
            return Err(Error::fetch_failed(format!("HTTP {} reading {}", r.status, self.url)));
        }
        Ok(r.body)
    }

    /// One thread per range; the layer's gate keeps the requests in flight within its parallel limit.
    fn read_many(&self, ranges: &[(u64, u64)]) -> Result<Vec<Vec<u8>>> {
        if ranges.len() <= 1 {
            return ranges.iter().map(|&(o, l)| self.read(o, l)).collect();
        }
        let results: Vec<Result<Vec<u8>>> = std::thread::scope(|sc| {
            let hs: Vec<_> = ranges.iter().map(|&(o, l)| sc.spawn(move || self.read(o, l))).collect();
            hs.into_iter().map(|h| h.join().unwrap_or_else(|_| Err(Error::internal("panic in a range read")))).collect()
        });
        results.into_iter().collect()
    }
}

pub struct Reader {
    src: Box<dyn RangeSource>,
    pub header: Header,
    root: Vec<Entry>,
    leaves: Mutex<HashMap<u64, Arc<Vec<Entry>>>>,
}

impl Reader {
    pub fn open(src: Box<dyn RangeSource>) -> Result<Reader> {
        let first = src.read(0, 16384)?;
        let header = Header::parse(&first)?;
        let root_raw = if (header.root_offset + header.root_len) as usize <= first.len() {
            first[header.root_offset as usize..(header.root_offset + header.root_len) as usize].to_vec()
        } else {
            src.read(header.root_offset, header.root_len)?
        };
        let root = parse_dir(&decompress(&root_raw, header.internal_compression)?)?;
        Ok(Reader { src, header, root, leaves: Mutex::new(HashMap::new()) })
    }

    pub fn open_file(path: &Path) -> Result<Reader> {
        Reader::open(Box::new(FileSource(path.to_path_buf())))
    }

    pub fn metadata(&self) -> Result<serde_json::Value> {
        if self.header.meta_len == 0 {
            return Ok(serde_json::json!({}));
        }
        let raw = self.src.read(self.header.meta_offset, self.header.meta_len)?;
        let t = decompress(&raw, self.header.internal_compression)?;
        Ok(serde_json::from_slice(&t).unwrap_or(serde_json::json!({})))
    }

    fn leaf(&self, e: &Entry) -> Result<Arc<Vec<Entry>>> {
        if let Some(l) = self.leaves.lock().map_err(|_| Error::internal("poisoned"))?.get(&e.offset) {
            return Ok(l.clone());
        }
        let raw = self.src.read(self.header.leaf_offset + e.offset, e.length as u64)?;
        let l = Arc::new(parse_dir(&decompress(&raw, self.header.internal_compression)?)?);
        let mut g = self.leaves.lock().map_err(|_| Error::internal("poisoned"))?;
        if g.len() > 256 {
            g.clear();
        }
        g.insert(e.offset, l.clone());
        Ok(l)
    }

    /// Where the tile's bytes are (offset within the tile data, length), or None when the archive has no such tile.
    pub fn lookup(&self, id: u64) -> Result<Option<(u64, u32)>> {
        let mut dir: Arc<Vec<Entry>> = Arc::new(Vec::new());
        let mut cur: &[Entry] = &self.root;
        for _ in 0..4 {
            match find(cur, id) {
                None => return Ok(None),
                Some(e) if e.run_length > 0 => return Ok(Some((e.offset, e.length))),
                Some(e) => {
                    dir = self.leaf(&e)?;
                    cur = &dir;
                }
            }
        }
        let _ = dir;
        Err(Error::bad_response("PMTiles directories nest too deep"))
    }

    pub fn read_range(&self, offset: u64, len: u64) -> Result<Vec<u8>> {
        self.src.read(self.header.data_offset + offset, len)
    }

    /// The stored bytes of a tile (compressed as `header.tile_compression` says).
    pub fn get_raw(&self, z: u8, x: u32, y: u32) -> Result<Option<Vec<u8>>> {
        if z < self.header.min_zoom || z > self.header.max_zoom {
            return Ok(None);
        }
        match self.lookup(zxy_to_id(z, x, y))? {
            None => Ok(None),
            Some((o, l)) => Ok(Some(self.read_range(o, l as u64)?)),
        }
    }

    /// Fetch many (offset,len) tile ranges, merging neighbours into fewer reads. Result order matches input.
    pub fn read_ranges(&self, want: &[(u64, u32)]) -> Result<Vec<Vec<u8>>> {
        let mut order: Vec<usize> = (0..want.len()).collect();
        order.sort_by_key(|&i| want[i].0);
        let mut groups: Vec<(u64, u64, Vec<usize>)> = Vec::new();
        for i in order {
            let (o, l) = (want[i].0, want[i].1 as u64);
            match groups.last_mut() {
                Some(g) if o <= g.0 + g.1 + 65_536 && (o + l).max(g.0 + g.1) - g.0 <= 4 * 1024 * 1024 => {
                    g.1 = (o + l).max(g.0 + g.1) - g.0;
                    g.2.push(i);
                }
                _ => groups.push((o, l, vec![i])),
            }
        }
        let ranges: Vec<(u64, u64)> = groups.iter().map(|g| (self.header.data_offset + g.0, g.1)).collect();
        let bufs = self.src.read_many(&ranges)?;
        let mut out = vec![Vec::new(); want.len()];
        for (g, buf) in groups.iter().zip(bufs) {
            for &i in &g.2 {
                let s = (want[i].0 - g.0) as usize;
                let e = s + want[i].1 as usize;
                if e > buf.len() {
                    return Err(Error::bad_response("short read from the PMTiles archive"));
                }
                out[i] = buf[s..e].to_vec();
            }
        }
        Ok(out)
    }

    /// Every addressed tile id, in order (walks all directories; for local archives).
    pub fn all_tiles(&self) -> Result<Vec<(u64, u64, u32)>> {
        let mut out = Vec::new();
        fn walk(r: &Reader, es: &[Entry], out: &mut Vec<(u64, u64, u32)>) -> Result<()> {
            for e in es {
                if e.run_length == 0 {
                    let l = r.leaf(e)?;
                    walk(r, &l, out)?;
                } else {
                    for k in 0..e.run_length as u64 {
                        out.push((e.tile_id + k, e.offset, e.length));
                    }
                }
            }
            Ok(())
        }
        walk(self, &self.root, &mut out)?;
        Ok(out)
    }
}

// ---- writer ----

/// Builds an archive in `<final>.part`-style file: 127 bytes are reserved for the header, tile data is appended, and
/// `finish` writes the directories, the metadata and the header after it.
pub struct Writer {
    file: std::fs::File,
    path: PathBuf,
    pub pos: u64,
}

impl Writer {
    pub fn create(path: &Path) -> Result<Writer> {
        let mut file = std::fs::File::create(path).map_err(|e| io_at("creating", path, e))?;
        file.write_all(&[0u8; HEADER_LEN]).map_err(|e| io_at("writing", path, e))?;
        Ok(Writer { file, path: path.to_path_buf(), pos: HEADER_LEN as u64 })
    }

    /// Reopen a partly written file, keeping its first `len` bytes (resume).
    pub fn reopen(path: &Path, len: u64) -> Result<Writer> {
        let file = std::fs::OpenOptions::new().write(true).open(path).map_err(|e| io_at("opening", path, e))?;
        file.set_len(len).map_err(|e| io_at("truncating", path, e))?;
        let mut w = Writer { file, path: path.to_path_buf(), pos: len };
        w.file.seek(SeekFrom::Start(len)).map_err(|e| io_at("seeking", path, e))?;
        Ok(w)
    }

    pub fn append(&mut self, data: &[u8]) -> Result<u64> {
        let at = self.pos - HEADER_LEN as u64;
        self.file.write_all(data).map_err(|e| io_at("writing", &self.path, e))?;
        self.pos += data.len() as u64;
        Ok(at)
    }

    pub fn flush(&mut self) -> Result<()> {
        self.file.flush().map_err(|e| io_at("writing", &self.path, e))?;
        self.file.sync_data().map_err(|e| io_at("syncing", &self.path, e))
    }

    /// `tiles`: (tile id, offset, length) sorted by id; equal consecutive (offset, length) become runs.
    pub fn finish(mut self, mut h: Header, tiles: &[(u64, u64, u32)], metadata: &serde_json::Value) -> Result<u64> {
        let data_len = self.pos - HEADER_LEN as u64;
        let mut entries: Vec<Entry> = Vec::new();
        let mut contents = 0u64;
        let mut seen: std::collections::HashSet<(u64, u32)> = Default::default();
        for &(id, off, len) in tiles {
            if seen.insert((off, len)) {
                contents += 1;
            }
            if let Some(last) = entries.last_mut() {
                if last.offset == off && last.length == len && last.tile_id + last.run_length as u64 == id {
                    last.run_length += 1;
                    continue;
                }
            }
            entries.push(Entry { tile_id: id, offset: off, length: len, run_length: 1 });
        }
        let (root, leaves) = build_dirs(&entries);
        let meta = gzip(metadata.to_string().as_bytes());
        h.data_offset = HEADER_LEN as u64;
        h.data_len = data_len;
        h.root_offset = HEADER_LEN as u64 + data_len;
        h.root_len = root.len() as u64;
        h.meta_offset = h.root_offset + h.root_len;
        h.meta_len = meta.len() as u64;
        h.leaf_offset = h.meta_offset + h.meta_len;
        h.leaf_len = leaves.len() as u64;
        h.addressed_tiles = tiles.len() as u64;
        h.tile_entries = entries.len() as u64;
        h.tile_contents = contents;
        h.clustered = true;
        h.internal_compression = COMP_GZIP;
        let p = self.path.clone();
        let w = |e: std::io::Error| io_at("writing", &p, e);
        self.file.write_all(&root).map_err(w)?;
        self.file.write_all(&meta).map_err(w)?;
        self.file.write_all(&leaves).map_err(w)?;
        self.file.seek(SeekFrom::Start(0)).map_err(w)?;
        self.file.write_all(&h.serialize()).map_err(w)?;
        self.file.sync_all().map_err(w)?;
        Ok(h.leaf_offset + h.leaf_len)
    }
}

/// Root directory (compressed, within 16384 - 127 bytes) and the concatenated leaf directories.
fn build_dirs(entries: &[Entry]) -> (Vec<u8>, Vec<u8>) {
    let root = gzip(&serialize_dir(entries));
    if root.len() <= 16384 - HEADER_LEN {
        return (root, Vec::new());
    }
    let mut leaf_size = 4096usize;
    loop {
        let mut leaves = Vec::new();
        let mut ptrs = Vec::new();
        for chunk in entries.chunks(leaf_size) {
            let c = gzip(&serialize_dir(chunk));
            ptrs.push(Entry { tile_id: chunk[0].tile_id, offset: leaves.len() as u64, length: c.len() as u32, run_length: 0 });
            leaves.extend_from_slice(&c);
        }
        let r = gzip(&serialize_dir(&ptrs));
        if r.len() <= 16384 - HEADER_LEN {
            return (r, leaves);
        }
        leaf_size *= 2;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tile_ids_match_the_spec() {
        assert_eq!(zxy_to_id(0, 0, 0), 0);
        assert_eq!(zxy_to_id(1, 0, 0), 1);
        assert_eq!(zxy_to_id(1, 0, 1), 2);
        assert_eq!(zxy_to_id(1, 1, 1), 3);
        assert_eq!(zxy_to_id(1, 1, 0), 4);
        assert_eq!(zxy_to_id(2, 0, 0), 5);
    }

    #[test]
    fn tile_id_round_trip() {
        for z in 0..=14u8 {
            let n = 1u32 << z;
            for &(x, y) in &[(0, 0), (n - 1, 0), (0, n - 1), (n - 1, n - 1), (n / 3, n / 2), (n / 2, n / 5)] {
                let id = zxy_to_id(z, x, y);
                assert_eq!(id_to_zxy(id), (z, x, y), "z{z}");
            }
        }
    }

    #[test]
    fn header_round_trip() {
        let h = Header { root_offset: 127, root_len: 5, data_offset: 200, data_len: 9, tile_type: TYPE_MVT, max_zoom: 14, bounds: [-113.9, 42.4, -113.7, 42.6], clustered: true, ..Default::default() };
        let p = Header::parse(&h.serialize()).unwrap();
        assert_eq!(p.root_offset, 127);
        assert!((p.bounds[0] + 113.9).abs() < 1e-6);
        assert_eq!(p.max_zoom, 14);
    }

    #[test]
    fn dir_round_trip_and_find() {
        let es = vec![
            Entry { tile_id: 3, offset: 0, length: 10, run_length: 1 },
            Entry { tile_id: 5, offset: 10, length: 7, run_length: 3 },
            Entry { tile_id: 20, offset: 100, length: 4, run_length: 0 },
        ];
        assert_eq!(parse_dir(&serialize_dir(&es)).unwrap(), es);
        assert!(find(&es, 2).is_none());
        assert_eq!(find(&es, 6).unwrap().offset, 10);
        assert!(find(&es, 8).is_none());
        assert_eq!(find(&es, 25).unwrap().run_length, 0);
    }

    #[test]
    fn write_then_read_with_leaves() {
        let dir = std::env::temp_dir().join(format!("cl-pm-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("t.pmtiles");
        let mut w = Writer::create(&path).unwrap();
        let mut tiles = Vec::new();
        // enough distinct tiles to force leaf directories
        let n = 20000u64;
        for id in 0..n {
            let data = format!("tile-{id}-{}", "x".repeat((id % 7) as usize)).into_bytes();
            let off = w.append(&data).unwrap();
            // an irregular gap, so the offsets cannot be run-length packed
            w.append(&vec![0u8; ((id * 7919) % 13) as usize]).unwrap();
            tiles.push((id, off, data.len() as u32));
        }
        let h = Header { tile_type: TYPE_PNG, tile_compression: COMP_NONE, max_zoom: 9, ..Default::default() };
        w.finish(h, &tiles, &serde_json::json!({"name":"t"})).unwrap();
        let r = Reader::open_file(&path).unwrap();
        assert!(r.header.leaf_len > 0, "expected leaf directories");
        assert_eq!(r.header.addressed_tiles, n);
        for id in [0u64, 1, 4095, 4096, 19999] {
            let (z, x, y) = id_to_zxy(id);
            let t = r.get_raw(z, x, y).unwrap().unwrap();
            assert!(String::from_utf8(t).unwrap().starts_with(&format!("tile-{id}-")));
        }
        assert!(r.lookup(n + 10).unwrap().is_none());
        assert_eq!(r.metadata().unwrap()["name"], "t");
        assert_eq!(r.all_tiles().unwrap().len() as u64, n);
        std::fs::remove_dir_all(&dir).unwrap();
    }
}
