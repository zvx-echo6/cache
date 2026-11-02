//! Cloud-optimised GeoTIFF windows: read only the blocks a tile needs with HTTP range reads and render them as
//! indexed PNG tiles (so land-cover class values survive). Supports what ESA WorldCover uses: classic TIFF, tiled,
//! 8-bit single band, palette or grey, no compression or Deflate (optionally with the horizontal predictor),
//! EPSG:4326 pixel grid (pixel scale + tie point) and internal overviews.

use crate::error::{Error, Result};
use crate::pmtiles::RangeSource;
use flate2::read::ZlibDecoder;
use std::collections::HashMap;
use std::io::Read;
use std::sync::{Arc, Mutex};

struct Ifd {
    w: u64,
    h: u64,
    tw: u64,
    th: u64,
    offsets: Vec<u64>,
    counts: Vec<u64>,
    compression: u16,
    predictor: u16,
    /// degrees per pixel (derived from the first IFD for overviews)
    dx: f64,
    dy: f64,
}

pub struct CogFile {
    src: Box<dyn RangeSource>,
    ifds: Vec<Ifd>,
    lon0: f64,
    lat0: f64,
    pub palette: Option<Vec<u8>>, // 256 * RGB
    blocks: Mutex<BlockCache>,
}

/// Decoded blocks by (level, block index).
type BlockCache = HashMap<(usize, usize), Arc<Vec<u8>>>;
/// The files opened so far, by grid cell.
type Slots = HashMap<(i32, i32), Arc<Mutex<Slot>>>;
/// Opens a file by its address (the test hook in place of HTTP).
type Opener = Box<dyn Fn(&str) -> Box<dyn RangeSource> + Send + Sync>;
/// The files a tile touches, by grid cell: the file, the level read and the blocks needed.
type Touched = HashMap<(i32, i32), (Arc<CogFile>, usize, std::collections::HashSet<usize>)>;

struct Rd<'a> {
    b: &'a [u8],
    le: bool,
}

impl Rd<'_> {
    fn u16(&self, o: usize) -> u16 {
        let a = [self.b[o], self.b[o + 1]];
        if self.le { u16::from_le_bytes(a) } else { u16::from_be_bytes(a) }
    }
    fn u32(&self, o: usize) -> u32 {
        let a = self.b[o..o + 4].try_into().unwrap();
        if self.le { u32::from_le_bytes(a) } else { u32::from_be_bytes(a) }
    }
    fn f64(&self, o: usize) -> f64 {
        let a = self.b[o..o + 8].try_into().unwrap();
        if self.le { f64::from_le_bytes(a) } else { f64::from_be_bytes(a) }
    }
}

struct Entry {
    tag: u16,
    typ: u16,
    count: usize,
    /// the 4 value/offset bytes
    raw: [u8; 4],
}

fn type_size(t: u16) -> usize {
    match t {
        1 | 2 | 6 | 7 => 1,
        3 | 8 => 2,
        4 | 9 | 11 => 4,
        5 | 10 | 12 => 8,
        16..=18 => 8,
        _ => 1,
    }
}

impl CogFile {
    pub fn open(src: Box<dyn RangeSource>) -> Result<CogFile> {
        let head = src.read(0, 32768)?;
        if head.len() < 8 {
            return Err(Error::bad_response("not a TIFF"));
        }
        let le = match &head[0..2] {
            b"II" => true,
            b"MM" => false,
            _ => return Err(Error::bad_response("not a TIFF")),
        };
        let rd = Rd { b: &head, le };
        if rd.u16(2) != 42 {
            return Err(Error::unsupported("BigTIFF is not supported"));
        }
        let mut next = rd.u32(4) as u64;
        let mut ifds: Vec<Ifd> = Vec::new();
        let (mut lon0, mut lat0, mut dx0, mut dy0, mut w0) = (0.0, 0.0, 0.0, 0.0, 1u64);
        let mut palette = None;
        // read helper: bytes at an absolute offset, from the head buffer when possible
        let at = |off: u64, len: usize| -> Result<Vec<u8>> {
            if (off as usize) + len <= head.len() {
                Ok(head[off as usize..off as usize + len].to_vec())
            } else {
                src.read(off, len as u64)
            }
        };
        while next != 0 && ifds.len() < 16 {
            let n = {
                let c = at(next, 2)?;
                Rd { b: &c, le }.u16(0) as usize
            };
            let tbl = at(next + 2, n * 12 + 4)?;
            let r = Rd { b: &tbl, le };
            let mut entries = Vec::new();
            for i in 0..n {
                let o = i * 12;
                entries.push(Entry { tag: r.u16(o), typ: r.u16(o + 2), count: r.u32(o + 4) as usize, raw: tbl[o + 8..o + 12].try_into().unwrap() });
            }
            next = r.u32(n * 12) as u64;
            let data = |e: &Entry| -> Result<Vec<u8>> {
                let total = type_size(e.typ) * e.count;
                if total <= 4 {
                    Ok(e.raw[..total].to_vec())
                } else {
                    let off = Rd { b: &e.raw, le }.u32(0) as u64;
                    at(off, total)
                }
            };
            let nums = |e: &Entry| -> Result<Vec<u64>> {
                let d = data(e)?;
                let rr = Rd { b: &d, le };
                Ok((0..e.count)
                    .map(|i| match e.typ {
                        3 => rr.u16(i * 2) as u64,
                        4 => rr.u32(i * 4) as u64,
                        _ => d[i] as u64,
                    })
                    .collect())
            };
            let (mut w, mut h, mut tw, mut th, mut bits, mut comp, mut pred, mut samples) = (0, 0, 0, 0, 8, 1, 1, 1);
            let (mut offsets, mut counts) = (Vec::new(), Vec::new());
            let mut photo = 1;
            let mut geo: Option<(f64, f64, f64, f64)> = None;
            let (mut scale, mut tie) = (None, None);
            let mut cmap = None;
            for e in &entries {
                match e.tag {
                    256 => w = nums(e)?[0],
                    257 => h = nums(e)?[0],
                    258 => bits = nums(e)?[0],
                    259 => comp = nums(e)?[0] as u16,
                    262 => photo = nums(e)?[0],
                    277 => samples = nums(e)?[0],
                    317 => pred = nums(e)?[0] as u16,
                    322 => tw = nums(e)?[0],
                    323 => th = nums(e)?[0],
                    324 => offsets = nums(e)?,
                    325 => counts = nums(e)?,
                    33550 => {
                        let d = data(e)?;
                        let rr = Rd { b: &d, le };
                        scale = Some((rr.f64(0), rr.f64(8)));
                    }
                    33922 => {
                        let d = data(e)?;
                        let rr = Rd { b: &d, le };
                        tie = Some((rr.f64(24), rr.f64(32)));
                    }
                    320 => {
                        let v = nums(e)?;
                        if v.len() >= 768 {
                            let mut p = Vec::with_capacity(768);
                            for i in 0..256 {
                                p.push((v[i] >> 8) as u8);
                                p.push((v[256 + i] >> 8) as u8);
                                p.push((v[512 + i] >> 8) as u8);
                            }
                            cmap = Some(p);
                        }
                    }
                    _ => {}
                }
            }
            let _ = photo;
            if let (Some((sx, sy)), Some((ox, oy))) = (scale, tie) {
                geo = Some((ox, oy, sx, sy));
            }
            if bits != 8 || samples != 1 {
                return Err(Error::unsupported("only 8-bit single-band GeoTIFFs are supported"));
            }
            if !matches!(comp, 1 | 8 | 32946) {
                return Err(Error::unsupported(format!("TIFF compression {comp} (only none and Deflate)")));
            }
            if tw == 0 || th == 0 || offsets.is_empty() || offsets.len() != counts.len() {
                return Err(Error::unsupported("only tiled GeoTIFFs are supported"));
            }
            let (dx, dy);
            if ifds.is_empty() {
                let (ox, oy, sx, sy) = geo.ok_or_else(|| Error::unsupported("no georeferencing (pixel scale and tie point)"))?;
                (lon0, lat0, dx0, dy0, w0) = (ox, oy, sx, sy, w);
                dx = sx;
                dy = sy;
                palette = cmap;
            } else {
                dx = dx0 * w0 as f64 / w as f64;
                dy = dy0 * w0 as f64 / w as f64;
            }
            ifds.push(Ifd { w, h, tw, th, offsets, counts, compression: comp, predictor: pred, dx, dy });
        }
        if ifds.is_empty() {
            return Err(Error::bad_response("no image in the TIFF"));
        }
        Ok(CogFile { src, ifds, lon0, lat0, palette, blocks: Mutex::new(HashMap::new()) })
    }

    pub fn bounds(&self) -> [f64; 4] {
        let f = &self.ifds[0];
        [self.lon0, self.lat0 - f.h as f64 * f.dy, self.lon0 + f.w as f64 * f.dx, self.lat0]
    }

    /// The coarsest image whose pixels are no bigger than `deg_per_pixel`.
    pub fn level_for(&self, deg_per_pixel: f64) -> usize {
        let mut best = 0;
        for (i, f) in self.ifds.iter().enumerate() {
            if f.dx <= deg_per_pixel * 1.0001 {
                best = i;
            }
        }
        best
    }

    fn cached_block(&self, level: usize, idx: usize) -> Result<Option<Arc<Vec<u8>>>> {
        Ok(self.blocks.lock().map_err(|_| Error::internal("poisoned"))?.get(&(level, idx)).cloned())
    }

    /// Decode the stored bytes of a block (inflate, undo the predictor) and remember it.
    fn decode_block(&self, level: usize, idx: usize, raw: Vec<u8>) -> Result<Arc<Vec<u8>>> {
        let f = &self.ifds[level];
        let len = f.counts[idx];
        let expect = (f.tw * f.th) as usize;
        let mut px = if len == 0 {
            vec![0u8; expect]
        } else if f.compression == 1 {
            raw
        } else {
            let mut out = Vec::with_capacity(expect);
            ZlibDecoder::new(&raw[..]).read_to_end(&mut out).map_err(|e| Error::bad_response(format!("TIFF block: {e}")))?;
            out
        };
        if px.len() < expect {
            px.resize(expect, 0);
        }
        if f.predictor == 2 {
            for row in px.chunks_mut(f.tw as usize) {
                for i in 1..row.len() {
                    row[i] = row[i].wrapping_add(row[i - 1]);
                }
            }
        }
        let b = Arc::new(px);
        let mut g = self.blocks.lock().map_err(|_| Error::internal("poisoned"))?;
        if g.len() >= 48 {
            g.clear();
        }
        g.insert((level, idx), b.clone());
        Ok(b)
    }

    fn block(&self, level: usize, idx: usize) -> Result<Arc<Vec<u8>>> {
        if let Some(b) = self.cached_block(level, idx)? {
            return Ok(b);
        }
        let f = &self.ifds[level];
        let (off, len) = (f.offsets[idx], f.counts[idx]);
        let raw = if len == 0 { Vec::new() } else { self.src.read(off, len)? };
        self.decode_block(level, idx, raw)
    }

    /// The index of the block holding a position, or None outside the file.
    pub fn block_at(&self, level: usize, lon: f64, lat: f64) -> Option<usize> {
        let f = &self.ifds[level];
        let (cx, cy) = ((lon - self.lon0) / f.dx, (self.lat0 - lat) / f.dy);
        if cx < 0.0 || cy < 0.0 || cx >= f.w as f64 || cy >= f.h as f64 {
            return None;
        }
        let (col, row) = (cx as u64, cy as u64);
        let across = f.w.div_ceil(f.tw);
        let idx = ((row / f.th) * across + col / f.tw) as usize;
        (idx < f.offsets.len()).then_some(idx)
    }

    /// Read the blocks a tile needs that are not in memory yet, using as few range reads as the file layout allows:
    /// blocks that lie close together in the file (within 64 KiB, up to 8 MiB in all) come in one read.
    pub fn prefetch(&self, level: usize, idxs: &[usize]) -> Result<()> {
        const GAP: u64 = 64 * 1024;
        const MAX_SPAN: u64 = 8 * 1024 * 1024;
        let f = &self.ifds[level];
        let mut need: Vec<usize> = Vec::new();
        for &i in idxs {
            if i < f.offsets.len() && f.counts[i] > 0 && !need.contains(&i) && self.cached_block(level, i)?.is_none() {
                need.push(i);
            }
        }
        need.sort_by_key(|&i| f.offsets[i]);
        // (start, end, blocks)
        let mut groups: Vec<(u64, u64, Vec<usize>)> = Vec::new();
        for i in need {
            let (o, e) = (f.offsets[i], f.offsets[i] + f.counts[i]);
            match groups.last_mut() {
                Some(g) if o <= g.1 + GAP && e.max(g.1) - g.0 <= MAX_SPAN => {
                    g.1 = g.1.max(e);
                    g.2.push(i);
                }
                _ => groups.push((o, e, vec![i])),
            }
        }
        if groups.is_empty() {
            return Ok(());
        }
        let ranges: Vec<(u64, u64)> = groups.iter().map(|g| (g.0, g.1 - g.0)).collect();
        let data = self.src.read_many(&ranges)?;
        for (g, d) in groups.iter().zip(data) {
            for &i in &g.2 {
                let (s, e) = ((f.offsets[i] - g.0) as usize, (f.offsets[i] + f.counts[i] - g.0) as usize);
                if e > d.len() {
                    return Err(Error::bad_response("short read of a TIFF block"));
                }
                self.decode_block(level, i, d[s..e].to_vec())?;
            }
        }
        Ok(())
    }

    /// The value at a position, or 0 (no data) outside the file.
    pub fn sample(&self, level: usize, lon: f64, lat: f64) -> Result<u8> {
        let Some(idx) = self.block_at(level, lon, lat) else { return Ok(0) };
        let f = &self.ifds[level];
        let (col, row) = (((lon - self.lon0) / f.dx) as u64, ((self.lat0 - lat) / f.dy) as u64);
        let b = self.block(level, idx)?;
        Ok(b[((row % f.th) * f.tw + col % f.tw) as usize])
    }
}

/// A grid of COG files named by a URL template with `{lat}` and `{lon}` (the south-west corner of the cell,
/// like `N42` and `W114`).
pub struct CogSet {
    template: String,
    grid: f64,
    gate: Arc<crate::http::Gate>,
    files: Mutex<Slots>,
    local: Option<Opener>,
}

/// What is known of one cell's file. The header and tile index of a file are read once (by one caller; the others
/// wait for it) and kept; a cell with no file is remembered; a failed read is remembered briefly so a dead source is
/// not asked again for every tile.
enum Slot {
    Unopened,
    Open(Option<Arc<CogFile>>),
    Failed(std::time::Instant, Error),
}

const FAILED_OPEN_MEMORY: std::time::Duration = std::time::Duration::from_secs(20);

pub fn cell_name(lat_cell: i32, lon_cell: i32, grid: f64) -> (String, String) {
    let (lat, lon) = ((lat_cell as f64 * grid).round() as i32, (lon_cell as f64 * grid).round() as i32);
    (format!("{}{:02}", if lat >= 0 { 'N' } else { 'S' }, lat.abs()), format!("{}{:03}", if lon >= 0 { 'E' } else { 'W' }, lon.abs()))
}

impl CogSet {
    pub fn new(template: &str, grid_deg: f64, gate: Arc<crate::http::Gate>) -> CogSet {
        CogSet { template: template.to_string(), grid: grid_deg, gate, files: Mutex::new(HashMap::new()), local: None }
    }

    /// Test hook: open files through `f(url)` instead of HTTP.
    pub fn with_opener(mut self, f: Opener) -> CogSet {
        self.local = Some(f);
        self
    }

    fn file(&self, lat: f64, lon: f64) -> Result<Option<Arc<CogFile>>> {
        let key = ((lat / self.grid).floor() as i32, (lon / self.grid).floor() as i32);
        let slot = self.files.lock().map_err(|_| Error::internal("poisoned"))?.entry(key).or_insert_with(|| Arc::new(Mutex::new(Slot::Unopened))).clone();
        let mut slot = slot.lock().unwrap_or_else(|e| e.into_inner());
        match &*slot {
            Slot::Open(f) => return Ok(f.clone()),
            Slot::Failed(at, e) if at.elapsed() < FAILED_OPEN_MEMORY => return Err(e.clone()),
            _ => {}
        }
        let (la, lo) = cell_name(key.0, key.1, self.grid);
        let url = self.template.replace("{lat}", &la).replace("{lon}", &lo);
        let src: Box<dyn RangeSource> = match &self.local {
            Some(f) => f(&url),
            None => Box::new(crate::pmtiles::HttpSource { url: url.clone(), gate: self.gate.clone() }),
        };
        match CogFile::open(src) {
            Ok(f) => {
                let f = Some(Arc::new(f));
                *slot = Slot::Open(f.clone());
                Ok(f)
            }
            // a cell with no file (open sea) answers 404/403
            Err(e) if e.code == "fetch_failed" && (e.message.contains("HTTP 404") || e.message.contains("HTTP 403")) => {
                *slot = Slot::Open(None);
                Ok(None)
            }
            Err(e) => {
                *slot = Slot::Failed(std::time::Instant::now(), e.clone());
                Err(e)
            }
        }
    }

    pub fn palette(&self) -> Option<Vec<u8>> {
        let slots: Vec<Arc<Mutex<Slot>>> = self.files.lock().ok()?.values().cloned().collect();
        slots.iter().find_map(|s| match &*s.try_lock().ok()? {
            Slot::Open(Some(f)) => f.palette.clone(),
            _ => None,
        })
    }

    /// An indexed PNG of the Web Mercator tile, or `None` when every pixel is no-data.
    pub fn render_tile(&self, z: u8, x: u32, y: u32, size: u32) -> Result<Option<Vec<u8>>> {
        let n = (1u64 << z) as f64;
        let deg_per_px = 360.0 / (n * size as f64);
        let lat_of = |py: u32| {
            let ty = (y as f64 + (py as f64 + 0.5) / size as f64) / n;
            (std::f64::consts::PI * (1.0 - 2.0 * ty)).sinh().atan().to_degrees()
        };
        let lon_of = |pxl: u32| (x as f64 + (pxl as f64 + 0.5) / size as f64) / n * 360.0 - 180.0;
        // Pass 1: which files and which of their blocks does the tile touch? Read them all together first, so a tile
        // costs one range read per file (more only if its blocks are far apart in the file), not one per block.
        let mut touched: Touched = HashMap::new();
        let mut cur: Option<(i32, i32)> = None;
        for py in 0..size {
            let lat = lat_of(py);
            for pxl in 0..size {
                let lon = lon_of(pxl);
                let key = ((lat / self.grid).floor() as i32, (lon / self.grid).floor() as i32);
                if cur != Some(key) {
                    cur = Some(key);
                    if let std::collections::hash_map::Entry::Vacant(e) = touched.entry(key) {
                        if let Some(f) = self.file(lat, lon)? {
                            let lvl = f.level_for(deg_per_px);
                            e.insert((f, lvl, Default::default()));
                        }
                    }
                }
                if let Some((f, lvl, idxs)) = touched.get_mut(&key) {
                    if let Some(i) = f.block_at(*lvl, lon, lat) {
                        idxs.insert(i);
                    }
                }
            }
        }
        for (f, lvl, idxs) in touched.values() {
            f.prefetch(*lvl, &idxs.iter().copied().collect::<Vec<_>>())?;
        }
        // Pass 2: the pixels.
        let mut px = vec![0u8; (size * size) as usize];
        let mut any = false;
        for py in 0..size {
            let lat = lat_of(py);
            for pxl in 0..size {
                let lon = lon_of(pxl);
                let key = ((lat / self.grid).floor() as i32, (lon / self.grid).floor() as i32);
                if let Some((f, lvl, _)) = touched.get(&key) {
                    let v = f.sample(*lvl, lon, lat)?;
                    if v != 0 {
                        any = true;
                    }
                    px[(py * size + pxl) as usize] = v;
                }
            }
        }
        if !any {
            return Ok(None);
        }
        Ok(Some(encode_indexed_png(&px, size, self.palette())?))
    }
}

pub fn encode_indexed_png(px: &[u8], size: u32, palette: Option<Vec<u8>>) -> Result<Vec<u8>> {
    let pal = palette.unwrap_or_else(|| (0..256u32).flat_map(|i| [i as u8, i as u8, i as u8]).collect());
    let mut out = Vec::new();
    {
        let mut e = png::Encoder::new(&mut out, size, size);
        e.set_color(png::ColorType::Indexed);
        e.set_depth(png::BitDepth::Eight);
        e.set_palette(pal);
        e.set_trns(vec![0u8]);
        let mut w = e.write_header().map_err(|e| Error::internal(format!("png: {e}")))?;
        w.write_image_data(px).map_err(|e| Error::internal(format!("png: {e}")))?;
    }
    Ok(out)
}

/// The class values (palette indices) of an indexed PNG tile written by `encode_indexed_png`.
pub fn decode_indexed_png(bytes: &[u8]) -> Result<(u32, u32, Vec<u8>)> {
    let dec = png::Decoder::new(std::io::Cursor::new(bytes));
    let mut r = dec.read_info().map_err(|e| Error::bad_response(format!("png: {e}")))?;
    let mut buf = vec![0u8; r.output_buffer_size()];
    let info = r.next_frame(&mut buf).map_err(|e| Error::bad_response(format!("png: {e}")))?;
    if info.color_type != png::ColorType::Indexed || info.bit_depth != png::BitDepth::Eight {
        return Err(Error::bad_response("a land-cover tile must be an 8-bit indexed PNG"));
    }
    buf.truncate(info.buffer_size());
    Ok((info.width, info.height, buf))
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::write::ZlibEncoder;
    use flate2::Compression;
    use std::io::Write;

    struct Mem(Vec<u8>);
    impl RangeSource for Mem {
        fn read(&self, o: u64, l: u64) -> Result<Vec<u8>> {
            let s = (o as usize).min(self.0.len());
            let e = ((o + l) as usize).min(self.0.len());
            Ok(self.0[s..e].to_vec())
        }
    }

    /// A 3x3 degree cell N42W114 as a 2x2-block (block 8x8) deflate TIFF of 16x16 pixels, plus a half-size overview.
    fn tiff() -> Vec<u8> {
        fn blocks(w: usize, f: impl Fn(usize, usize) -> u8) -> Vec<Vec<u8>> {
            let mut v = Vec::new();
            for by in 0..w / 8 {
                for bx in 0..w / 8 {
                    let mut raw = Vec::new();
                    for y in 0..8 {
                        for x in 0..8 {
                            raw.push(f(bx * 8 + x, by * 8 + y));
                        }
                    }
                    let mut e = ZlibEncoder::new(Vec::new(), Compression::default());
                    e.write_all(&raw).unwrap();
                    v.push(e.finish().unwrap());
                }
            }
            v
        }
        let full = blocks(16, |x, _| if x < 10 { 10 } else { 40 });
        let over = blocks(8, |x, _| if x < 5 { 10 } else { 40 });
        let mut out = vec![b'I', b'I', 42, 0, 8, 0, 0, 0];
        // layout: header(8) | ifd0 | ifd1 | extra arrays | blocks
        let ifd_len = |n: usize| 2 + n * 12 + 4;
        let n0 = 14;
        let n1 = 11;
        let ifd0 = 8usize;
        let ifd1 = ifd0 + ifd_len(n0);
        let ex_base = ifd1 + ifd_len(n1);
        let mut put: Vec<u8> = Vec::new();
        let alloc = |bytes: &[u8], put: &mut Vec<u8>| -> usize {
            let o = ex_base + put.len();
            put.extend_from_slice(bytes);
            o
        };
        let scale = alloc(&[3.0f64 / 16.0, 3.0 / 16.0, 0.0].iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<_>>(), &mut put);
        let tie = alloc(&[0.0f64, 0.0, 0.0, -114.0, 45.0, 0.0].iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<_>>(), &mut put);
        let mut cm = vec![0u8; 768 * 2];
        for (i, col) in [(10usize, [0x00u16, 0x64, 0x00]), (40, [0xf0, 0x96, 0x32])] {
            cm[i * 2..i * 2 + 2].copy_from_slice(&(col[0] << 8).to_le_bytes());
            cm[(256 + i) * 2..(256 + i) * 2 + 2].copy_from_slice(&(col[1] << 8).to_le_bytes());
            cm[(512 + i) * 2..(512 + i) * 2 + 2].copy_from_slice(&(col[2] << 8).to_le_bytes());
        }
        let cmap = alloc(&cm, &mut put);
        let total_blocks = full.len() + over.len();
        let _ = total_blocks;
        let data_start = ex_base + put.len() + 32; // the two offset/count arrays below (the overview's one block is inline)
        let mut offs = Vec::new();
        let mut cur = data_start;
        let mut all = Vec::new();
        for b in full.iter().chain(over.iter()) {
            offs.push((cur, b.len()));
            cur += b.len();
            all.extend_from_slice(b);
        }
        let arr = |v: &[(usize, usize)], which: usize| -> Vec<u8> { v.iter().flat_map(|p| ((if which == 0 { p.0 } else { p.1 }) as u32).to_le_bytes()).collect() };
        let o_full = alloc(&arr(&offs[..4], 0), &mut put);
        let c_full = alloc(&arr(&offs[..4], 1), &mut put);
        let (o_over, c_over) = (offs[4].0, offs[4].1);
        assert_eq!(ex_base + put.len(), data_start);
        let ent = |tag: u16, typ: u16, count: u32, val: u32| -> Vec<u8> {
            let mut e = Vec::new();
            e.extend_from_slice(&tag.to_le_bytes());
            e.extend_from_slice(&typ.to_le_bytes());
            e.extend_from_slice(&count.to_le_bytes());
            e.extend_from_slice(&val.to_le_bytes());
            e
        };
        let ifd = |w: u32, with_geo: bool, o: usize, c: usize, next: usize, nent: usize| -> Vec<u8> {
            let mut e: Vec<Vec<u8>> = vec![
                ent(256, 3, 1, w),
                ent(257, 3, 1, w),
                ent(258, 3, 1, 8),
                ent(259, 3, 1, 8),
                ent(262, 3, 1, 3),
                ent(277, 3, 1, 1),
                ent(322, 3, 1, 8),
                ent(323, 3, 1, 8),
                ent(324, 4, (w / 8) * (w / 8), o as u32),
                ent(325, 4, (w / 8) * (w / 8), c as u32),
                ent(320, 3, 768, cmap as u32),
            ];
            if with_geo {
                e.push(ent(33550, 12, 3, scale as u32));
                e.push(ent(33922, 12, 6, tie as u32));
                e.push(ent(317, 3, 1, 1));
            }
            e.sort_by_key(|x| u16::from_le_bytes([x[0], x[1]]));
            assert_eq!(e.len(), nent);
            let mut b = (nent as u16).to_le_bytes().to_vec();
            for x in e {
                b.extend(x);
            }
            b.extend((next as u32).to_le_bytes());
            b
        };
        out.extend(ifd(16, true, o_full, c_full, ifd1, n0));
        out.extend(ifd(8, false, o_over, c_over, 0, n1));
        assert_eq!(out.len(), ex_base);
        out.extend(put);
        out.extend(all);
        out
    }

    #[test]
    fn reads_levels_and_values() {
        let f = CogFile::open(Box::new(Mem(tiff()))).unwrap();
        assert_eq!(f.ifds.len(), 2);
        
        assert_eq!(f.bounds(), [-114.0, 42.0, -111.0, 45.0]);
        // left half is class 10, right half class 40 (full res and overview)
        assert_eq!(f.sample(0, -113.9, 43.0).unwrap(), 10);
        assert_eq!(f.sample(0, -111.1, 43.0).unwrap(), 40);
        assert_eq!(f.sample(1, -113.9, 44.0).unwrap(), 10);
        assert_eq!(f.sample(0, -120.0, 43.0).unwrap(), 0);
        assert_eq!(f.level_for(3.0 / 16.0), 0);
        assert_eq!(f.level_for(3.0 / 8.0), 1);
        assert_eq!(f.palette.as_ref().unwrap()[40 * 3], 0xf0);
    }

    struct Missing;
    impl RangeSource for Missing {
        fn read(&self, _o: u64, _l: u64) -> Result<Vec<u8>> {
            Err(Error::fetch_failed("HTTP 404 reading the file"))
        }
    }

    #[test]
    fn tile_is_an_indexed_png_with_the_classes() {
        let bytes = tiff();
        let set = CogSet::new("mem://{lat}/{lon}", 3.0, crate::http::gate_for("test-cog", 2)).with_opener(Box::new(move |url| {
            if url == "mem://N42/W114" {
                Box::new(Mem(bytes.clone()))
            } else {
                Box::new(Missing)
            }
        }));
        // z6 x=12 y=23 spans lon -112.5..-106.9 and lat 41.0..44.8: the file's two classes (the split is at -112.1), and empty ground around it
        let png = set.render_tile(6, 12, 23, 64).unwrap().unwrap();
        let (w, h, px) = decode_indexed_png(&png).unwrap();
        assert_eq!((w, h), (64, 64));
        assert!(px.contains(&10) && px.contains(&40) && px.contains(&0));
        // a tile far from any file is empty
        assert!(set.render_tile(6, 40, 23, 64).unwrap().is_none());
        assert_eq!(cell_name(14, -38, 3.0), ("N42".into(), "W114".into()));
        assert_eq!(cell_name(-1, 0, 3.0), ("S03".into(), "E000".into()));
    }

    /// A source that logs every read.
    struct Counting(Vec<u8>, Arc<Mutex<Vec<(u64, u64)>>>);
    impl RangeSource for Counting {
        fn read(&self, o: u64, l: u64) -> Result<Vec<u8>> {
            self.1.lock().unwrap().push((o, l));
            Mem(self.0.clone()).read(o, l)
        }
    }

    /// The Web Mercator tile holding a position.
    fn tile_of(z: u8, lon: f64, lat: f64) -> (u32, u32) {
        let n = (1u64 << z) as f64;
        let x = ((lon + 180.0) / 360.0 * n).floor() as u32;
        let y = ((1.0 - lat.to_radians().tan().asinh() / std::f64::consts::PI) / 2.0 * n).floor() as u32;
        (x, y)
    }

    #[test]
    fn the_header_is_read_once_and_a_tile_is_one_range_read() {
        let log = Arc::new(Mutex::new(Vec::new()));
        let (bytes, l2) = (tiff(), log.clone());
        let set = CogSet::new("mem://{lat}/{lon}", 3.0, crate::http::gate_for("test-cog-hdr", 2)).with_opener(Box::new(move |url| if url == "mem://N42/W114" { Box::new(Counting(bytes.clone(), l2.clone())) } else { Box::new(Missing) }));
        let is_header = |r: &(u64, u64)| r.0 == 0 && r.1 == 32768;
        // a tile inside one block (the file's 16x16 pixels are 8x8 blocks): the header read, then one range read
        let (x, y) = tile_of(9, -113.3, 44.2);
        assert!(set.render_tile(9, x, y, 64).unwrap().is_some());
        let first = log.lock().unwrap().clone();
        assert_eq!(first.iter().filter(|r| is_header(r)).count(), 1, "{first:?}");
        assert_eq!(first.len(), 2, "header + one block: {first:?}");
        // another block of the same file: no header read again, one range read
        log.lock().unwrap().clear();
        let (x, y) = tile_of(9, -111.5, 42.8);
        assert!(set.render_tile(9, x, y, 64).unwrap().is_some());
        let second = log.lock().unwrap().clone();
        assert_eq!(second.len(), 1, "one range read and no header read: {second:?}");
        assert!(!is_header(&second[0]));
        // a tile over all four blocks: still one read (the blocks are next to each other in the file)
        log.lock().unwrap().clear();
        assert!(set.render_tile(6, 12, 23, 64).unwrap().is_some());
        let third = log.lock().unwrap().clone();
        assert!(third.len() <= 1 && third.iter().all(|r| !is_header(r)), "{third:?}");
        // the same tile again: from memory, nothing read
        log.lock().unwrap().clear();
        assert!(set.render_tile(6, 12, 23, 64).unwrap().is_some());
        assert!(log.lock().unwrap().is_empty());
    }

    #[test]
    fn concurrent_first_requests_share_one_header_read_and_a_dead_source_is_not_asked_every_time() {
        let log = Arc::new(Mutex::new(Vec::new()));
        let (bytes, l2) = (tiff(), log.clone());
        let set = Arc::new(CogSet::new("mem://{lat}/{lon}", 3.0, crate::http::gate_for("test-cog-hdr2", 2)).with_opener(Box::new(move |url| if url == "mem://N42/W114" { Box::new(Counting(bytes.clone(), l2.clone())) } else { Box::new(Missing) })));
        let hs: Vec<_> = (0..6)
            .map(|_| {
                let set = set.clone();
                std::thread::spawn(move || {
                    let (x, y) = tile_of(9, -113.3, 44.2);
                    set.render_tile(9, x, y, 64).unwrap().is_some()
                })
            })
            .collect();
        assert!(hs.into_iter().all(|h| h.join().unwrap()));
        assert_eq!(log.lock().unwrap().iter().filter(|r| r.0 == 0 && r.1 == 32768).count(), 1, "one header read for six simultaneous tiles");

        struct Dead(Arc<Mutex<usize>>);
        impl RangeSource for Dead {
            fn read(&self, _o: u64, _l: u64) -> Result<Vec<u8>> {
                *self.0.lock().unwrap() += 1;
                Err(Error::upstream_timeout("timed out"))
            }
        }
        let n = Arc::new(Mutex::new(0));
        let n2 = n.clone();
        let dead = CogSet::new("mem://{lat}/{lon}", 3.0, crate::http::gate_for("test-cog-hdr3", 2)).with_opener(Box::new(move |_| Box::new(Dead(n2.clone()))));
        for _ in 0..5 {
            assert_eq!(dead.render_tile(6, 12, 23, 16).unwrap_err().code, "upstream_timeout");
        }
        assert_eq!(*n.lock().unwrap(), 1, "the failed header read is remembered for a while");
    }
}
