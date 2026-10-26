//! GeoTIFF mosaic reader (WGS84 lon/lat rasters, PixelIsArea): the pure-Rust replacement for the
//! GDAL/VRT reads navi does. Nearest sampling only. A mosaic is a set of GeoTIFFs (a VRT of
//! non-overlapping tiles reads the same way; uncovered pixels are 0 = nodata).
use std::cell::RefCell;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufReader, Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use tiff::decoder::{Decoder, Limits};
use tiff::tags::Tag;

thread_local! {
    static FILES: RefCell<HashMap<PathBuf, File>> = RefCell::new(HashMap::new());
}

#[derive(Debug, Clone)]
pub struct TiffInfo {
    pub path: PathBuf,
    pub width: u32,
    pub height: u32,
    pub x0: f64, // west edge
    pub y0: f64, // north edge
    pub dx: f64, // degrees per pixel (east)
    pub dy: f64, // degrees per pixel (south, positive)
    pub chunk_w: u32,
    pub chunk_h: u32,
    pub tiled: bool,
    pub compression: u16,
    pub predictor: u16,
    pub offsets: Vec<u64>,
    pub counts: Vec<u64>,
}

/// Parses the header tags with the `tiff` crate; the pixel data is decoded below (the crate cannot
/// read palette-indexed images such as the WorldCover class tiles).
pub fn tiff_info(p: &Path) -> Result<TiffInfo, String> {
    let f = File::open(p).map_err(|e| format!("{}: {e}", p.display()))?;
    let mut d = Decoder::new(BufReader::with_capacity(1 << 20, f)).map_err(|e| format!("{}: {e}", p.display()))?.with_limits(Limits::unlimited());
    let (width, height) = d.dimensions().map_err(|e| e.to_string())?;
    let scale = d.get_tag_f64_vec(Tag::ModelPixelScaleTag).map_err(|e| format!("{}: no ModelPixelScale ({e})", p.display()))?;
    let tie = d.get_tag_f64_vec(Tag::ModelTiepointTag).map_err(|e| format!("{}: no ModelTiepoint ({e})", p.display()))?;
    if tie.len() < 6 {
        return Err("bad tiepoint".into());
    }
    let x0 = tie[3] - tie[0] * scale[0];
    let y0 = tie[4] + tie[1] * scale[1];
    let (cw, ch) = d.chunk_dimensions();
    let tiled = d.find_tag(Tag::TileOffsets).map_err(|e| e.to_string())?.is_some();
    let (ot, ct) = if tiled { (Tag::TileOffsets, Tag::TileByteCounts) } else { (Tag::StripOffsets, Tag::StripByteCounts) };
    let offsets = d.get_tag_u64_vec(ot).map_err(|e| format!("{}: {e}", p.display()))?;
    let counts = d.get_tag_u64_vec(ct).map_err(|e| format!("{}: {e}", p.display()))?;
    let compression = d.get_tag_u32(Tag::Compression).map_err(|e| e.to_string())? as u16;
    let predictor = d.find_tag(Tag::Predictor).ok().flatten().and_then(|v| v.into_u32().ok()).unwrap_or(1) as u16;
    let bits = d.find_tag(Tag::BitsPerSample).ok().flatten().and_then(|v| v.into_u32().ok()).unwrap_or(8);
    let spp = d.find_tag(Tag::SamplesPerPixel).ok().flatten().and_then(|v| v.into_u32().ok()).unwrap_or(1);
    if bits != 8 || spp != 1 {
        return Err(format!("{}: only 8-bit single-band rasters are supported", p.display()));
    }
    if !matches!(compression, 1 | 5 | 8 | 32946) || !matches!(predictor, 1 | 2) {
        return Err(format!("{}: unsupported compression {compression} / predictor {predictor}", p.display()));
    }
    Ok(TiffInfo { path: p.to_path_buf(), width, height, x0, y0, dx: scale[0], dy: scale[1], chunk_w: cw, chunk_h: ch, tiled, compression, predictor, offsets, counts })
}

/// Decode one chunk (tile or strip) to its full padded size: tiles are chunk_w x chunk_h, strips width x rows.
fn read_chunk(info: &TiffInfo, idx: usize) -> Result<(Vec<u8>, usize, usize), String> {
    let (iw, ih) = (info.width as usize, info.height as usize);
    let (cw, ch) = (info.chunk_w as usize, info.chunk_h as usize);
    let (w, h) = if info.tiled { (cw, ch) } else { (iw, ch.min(ih - (idx * ch).min(ih))) };
    let raw = FILES.with(|cell| -> Result<Vec<u8>, String> {
        let mut m = cell.borrow_mut();
        if !m.contains_key(&info.path) {
            m.insert(info.path.clone(), File::open(&info.path).map_err(|e| e.to_string())?);
        }
        let f = m.get_mut(&info.path).unwrap();
        f.seek(SeekFrom::Start(info.offsets[idx])).map_err(|e| e.to_string())?;
        let mut buf = vec![0u8; info.counts[idx] as usize];
        f.read_exact(&mut buf).map_err(|e| e.to_string())?;
        Ok(buf)
    })?;
    let mut data = match info.compression {
        1 => raw,
        8 | 32946 => {
            let mut out = Vec::with_capacity(w * h);
            flate2::read::ZlibDecoder::new(&raw[..]).read_to_end(&mut out).map_err(|e| format!("{}: deflate: {e}", info.path.display()))?;
            out
        }
        5 => weezl::decode::Decoder::with_tiff_size_switch(weezl::BitOrder::Msb, 8)
            .decode(&raw)
            .map_err(|e| format!("{}: lzw: {e}", info.path.display()))?,
        c => return Err(format!("compression {c}")),
    };
    if data.len() < w * h {
        data.resize(w * h, 0);
    }
    if info.predictor == 2 {
        for r in 0..h {
            let row = &mut data[r * w..(r + 1) * w];
            for c in 1..w {
                row[c] = row[c].wrapping_add(row[c - 1]);
            }
        }
    }
    Ok((data, w, h))
}

/// Read pixels [px0, px0+w) x [py0, py0+h) (clipped to the raster; outside = 0) of a u8 GeoTIFF.
pub fn read_window(info: &TiffInfo, px0: i64, py0: i64, w: usize, h: usize) -> Result<Vec<u8>, String> {
    let mut out = vec![0u8; w * h];
    let (iw, ih) = (info.width as i64, info.height as i64);
    let x_lo = px0.max(0);
    let x_hi = (px0 + w as i64).min(iw);
    let y_lo = py0.max(0);
    let y_hi = (py0 + h as i64).min(ih);
    if x_lo >= x_hi || y_lo >= y_hi {
        return Ok(out);
    }
    let (cw, ch) = (info.chunk_w as i64, info.chunk_h as i64);
    if info.tiled {
        let per_row = (iw + cw - 1) / cw;
        for cy in (y_lo / ch)..=((y_hi - 1) / ch) {
            for cx in (x_lo / cw)..=((x_hi - 1) / cw) {
                let (data, dw, _) = read_chunk(info, (cy * per_row + cx) as usize)?;
                let (gx0, gy0) = (cx * cw, cy * ch);
                for yy in gy0.max(y_lo)..(gy0 + ch).min(y_hi) {
                    for xx in gx0.max(x_lo)..(gx0 + cw).min(x_hi) {
                        out[((yy - py0) as usize) * w + (xx - px0) as usize] = data[((yy - gy0) as usize) * dw + (xx - gx0) as usize];
                    }
                }
            }
        }
    } else {
        for sy in (y_lo / ch)..=((y_hi - 1) / ch) {
            let (data, dw, dh) = read_chunk(info, sy as usize)?;
            let gy0 = sy * ch;
            for yy in gy0.max(y_lo)..(gy0 + dh as i64).min(y_hi) {
                for xx in x_lo..x_hi {
                    out[((yy - py0) as usize) * w + (xx - px0) as usize] = data[((yy - gy0) as usize) * dw + xx as usize];
                }
            }
        }
    }
    Ok(out)
}

/// A set of GeoTIFFs read as one raster.
pub struct Mosaic {
    pub files: Vec<TiffInfo>,
}

pub struct Patch<'a> {
    parts: Vec<(&'a TiffInfo, i64, i64, usize, usize, Vec<u8>)>,
}

impl Mosaic {
    pub fn open_files(paths: &[PathBuf]) -> Result<Mosaic, String> {
        let mut files = Vec::new();
        for p in paths {
            files.push(tiff_info(p)?);
        }
        Ok(Mosaic { files })
    }

    /// All `*.tif` in a directory.
    pub fn open_dir(dir: &Path) -> Result<Mosaic, String> {
        let mut paths: Vec<PathBuf> = std::fs::read_dir(dir)
            .map_err(|e| format!("{}: {e}", dir.display()))?
            .filter_map(|e| e.ok().map(|e| e.path()))
            .filter(|p| p.extension().map_or(false, |x| x.eq_ignore_ascii_case("tif")))
            .collect();
        paths.sort();
        Mosaic::open_files(&paths)
    }

    /// Load the part of the mosaic covering the lon/lat box into memory.
    pub fn patch(&self, west: f64, east: f64, south: f64, north: f64) -> Result<Patch<'_>, String> {
        let mut parts = Vec::new();
        for f in &self.files {
            let px0 = ((west - f.x0) / f.dx).floor() as i64 - 1;
            let px1 = ((east - f.x0) / f.dx).floor() as i64 + 2;
            let py0 = ((f.y0 - north) / f.dy).floor() as i64 - 1;
            let py1 = ((f.y0 - south) / f.dy).floor() as i64 + 2;
            if px1 <= 0 || py1 <= 0 || px0 >= f.width as i64 || py0 >= f.height as i64 {
                continue;
            }
            let (w, h) = ((px1 - px0) as usize, (py1 - py0) as usize);
            parts.push((f, px0, py0, w, h, read_window(f, px0, py0, w, h)?));
        }
        Ok(Patch { parts })
    }
}

impl Patch<'_> {
    /// Nearest sample at lon/lat (0 where no file covers it).
    #[inline]
    pub fn sample(&self, lon: f64, lat: f64) -> u8 {
        for (f, px0, py0, w, h, data) in &self.parts {
            let c = ((lon - f.x0) / f.dx).floor() as i64;
            let r = ((f.y0 - lat) / f.dy).floor() as i64;
            if c < 0 || r < 0 || c >= f.width as i64 || r >= f.height as i64 {
                continue;
            }
            let (lc, lr) = (c - px0, r - py0);
            if lc >= 0 && lr >= 0 && (lc as usize) < *w && (lr as usize) < *h {
                return data[lr as usize * w + lc as usize];
            }
        }
        0
    }
}
