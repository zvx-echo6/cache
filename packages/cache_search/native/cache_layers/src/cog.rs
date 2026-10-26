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
    blocks: Mutex<HashMap<(usize, usize), Arc<Vec<u8>>>>,
}

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
        16 | 17 | 18 => 8,
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

    fn block(&self, level: usize, idx: usize) -> Result<Arc<Vec<u8>>> {
        if let Some(b) = self.blocks.lock().map_err(|_| Error::internal("poisoned"))?.get(&(level, idx)) {
            return Ok(b.clone());
        }
        let f = &self.ifds[level];
        let (off, len) = (f.offsets[idx], f.counts[idx]);
        let raw = if len == 0 { Vec::new() } else { self.src.read(off, len)? };
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

    /// The value at a position, or 0 (no data) outside the file.
    pub fn sample(&self, level: usize, lon: f64, lat: f64) -> Result<u8> {
        let f = &self.ifds[level];
        let (cx, cy) = ((lon - self.lon0) / f.dx, (self.lat0 - lat) / f.dy);
        if cx < 0.0 || cy < 0.0 || cx >= f.w as f64 || cy >= f.h as f64 {
            return Ok(0);
        }
        let (col, row) = (cx as u64, cy as u64);
        let across = f.w.div_ceil(f.tw);
        let idx = ((row / f.th) * across + col / f.tw) as usize;
        if idx >= f.offsets.len() {
            return Ok(0);
        }
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
    files: Mutex<HashMap<(i32, i32), Option<Arc<CogFile>>>>,
    local: Option<Box<dyn Fn(&str) -> Box<dyn RangeSource> + Send + Sync>>,
}

pub fn cell_name(lat_cell: i32, lon_cell: i32, grid: f64) -> (String, String) {
    let (lat, lon) = ((lat_cell as f64 * grid).round() as i32, (lon_cell as f64 * grid).round() as i32);
    (format!("{}{:02}", if lat >= 0 { 'N' } else { 'S' }, lat.abs()), format!("{}{:03}", if lon >= 0 { 'E' } else { 'W' }, lon.abs()))
}

impl CogSet {
    pub fn new(template: &str, grid_deg: f64, gate: Arc<crate::http::Gate>) -> CogSet {
        CogSet { template: template.to_string(), grid: grid_deg, gate, files: Mutex::new(HashMap::new()), local: None }
    }

    /// Test hook: open files through `f(url)` instead of HTTP.
    pub fn with_opener(mut self, f: Box<dyn Fn(&str) -> Box<dyn RangeSource> + Send + Sync>) -> CogSet {
        self.local = Some(f);
        self
    }

    fn file(&self, lat: f64, lon: f64) -> Result<Option<Arc<CogFile>>> {
        let key = ((lat / self.grid).floor() as i32, (lon / self.grid).floor() as i32);
        if let Some(f) = self.files.lock().map_err(|_| Error::internal("poisoned"))?.get(&key) {
            return Ok(f.clone());
        }
        let (la, lo) = cell_name(key.0, key.1, self.grid);
        let url = self.template.replace("{lat}", &la).replace("{lon}", &lo);
        let src: Box<dyn RangeSource> = match &self.local {
            Some(f) => f(&url),
            None => Box::new(crate::pmtiles::HttpSource { url: url.clone(), gate: self.gate.clone() }),
        };
        let opened = match CogFile::open(src) {
            Ok(f) => Some(Arc::new(f)),
            // a cell with no file (open sea) answers 404/403
            Err(e) if e.code == "fetch_failed" && (e.message.contains("HTTP 404") || e.message.contains("HTTP 403")) => None,
            Err(e) => return Err(e),
        };
        self.files.lock().map_err(|_| Error::internal("poisoned"))?.insert(key, opened.clone());
        Ok(opened)
    }

    pub fn palette(&self) -> Option<Vec<u8>> {
        self.files.lock().ok()?.values().flatten().find_map(|f| f.palette.clone())
    }

    /// An indexed PNG of the Web Mercator tile, or `None` when every pixel is no-data.
    pub fn render_tile(&self, z: u8, x: u32, y: u32, size: u32) -> Result<Option<Vec<u8>>> {
        let n = (1u64 << z) as f64;
        let deg_per_px = 360.0 / (n * size as f64);
        let mut px = vec![0u8; (size * size) as usize];
        let mut any = false;
        let mut cur: Option<(i32, i32, Option<Arc<CogFile>>, usize)> = None;
        for py in 0..size {
            let ty = (y as f64 + (py as f64 + 0.5) / size as f64) / n;
            let lat = (std::f64::consts::PI * (1.0 - 2.0 * ty)).sinh().atan().to_degrees();
            for pxl in 0..size {
                let lon = (x as f64 + (pxl as f64 + 0.5) / size as f64) / n * 360.0 - 180.0;
                let key = ((lat / self.grid).floor() as i32, (lon / self.grid).floor() as i32);
                if cur.as_ref().map(|c| (c.0, c.1) != key).unwrap_or(true) {
                    let f = self.file(lat, lon)?;
                    let lvl = f.as_ref().map(|f| f.level_for(deg_per_px)).unwrap_or(0);
                    cur = Some((key.0, key.1, f, lvl));
                }
                let c = cur.as_ref().unwrap();
                if let Some(f) = &c.2 {
                    let v = f.sample(c.3, lon, lat)?;
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
                ent(324, 4, ((w / 8) * (w / 8)) as u32, o as u32),
                ent(325, 4, ((w / 8) * (w / 8)) as u32, c as u32),
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
}
