//! Elevation source. The off-road pack holds no elevation: the app downloads elevation for an area from
//! Mapterhorn (Terrarium-encoded WebP, 512 px tiles, z12) as a local PMTiles file, and the same file drives
//! hillshade and contours. The router reads it through [`ElevationSource`]. Cells are the global z12 pixel
//! grid, exactly as before: elevation (row, col) = z12 tile (col/512, row/512) pixel (row%512, col%512),
//! decoded with navi's float32 Terrarium formula.
use crate::pmtiles::PmTiles;
use rayon::prelude::*;
use std::collections::VecDeque;
use std::io::Cursor;
use std::path::Path;
use std::sync::{Arc, Mutex};

pub const TILE: i64 = 512;
pub const ZOOM: u8 = 12;

#[derive(Debug, thiserror::Error)]
pub enum ElevError {
    #[error("elevation: {0}")]
    Msg(String),
}

/// Terrarium decode, same f32 operations as navi's `terrarium_decode`: (R*256 + G + B/256) - 32768.
#[inline]
pub fn terrarium_f32(q: u32) -> f32 {
    let r = ((q >> 16) & 255) as f32;
    let g = ((q >> 8) & 255) as f32;
    let b = (q & 255) as f32;
    (r * 256.0 + g + b / 256.0) - 32768.0
}

pub trait ElevationSource: Send + Sync {
    /// Elevation (m) window in global z12 pixel coordinates; NaN where there is no tile.
    fn read_elevation(&self, row0: i64, col0: i64, rows: usize, cols: usize) -> Result<Vec<f32>, ElevError>;
}

/// Decode one Terrarium WebP tile (lossless required) to 24-bit packed values (R<<16|G<<8|B).
pub fn decode_terrarium_webp(bytes: &[u8]) -> Result<Vec<u32>, ElevError> {
    let e = |x: String| ElevError::Msg(x);
    let mut dec = image_webp::WebPDecoder::new(Cursor::new(bytes)).map_err(|x| e(x.to_string()))?;
    if dec.is_lossy() {
        return Err(e("Terrarium tile is lossy WebP: elevation would not be exact".into()));
    }
    let (w, h) = dec.dimensions();
    if (w as i64, h as i64) != (TILE, TILE) {
        return Err(e(format!("unexpected elevation tile size {w}x{h}")));
    }
    let mut buf = vec![0u8; dec.output_buffer_size().ok_or_else(|| e("no buffer size".into()))?];
    dec.read_image(&mut buf).map_err(|x| e(x.to_string()))?;
    let ch = if dec.has_alpha() { 4 } else { 3 };
    Ok((0..(w * h) as usize).map(|i| ((buf[i * ch] as u32) << 16) | ((buf[i * ch + 1] as u32) << 8) | buf[i * ch + 2] as u32).collect())
}

/// Where z12 elevation tiles come from: the Mapterhorn tile at (x, y) as its bytes (lossless Terrarium WebP, uncompressed),
/// `None` where there is none.
pub trait ElevationTiles: Send + Sync {
    fn z12(&self, x: u64, y: u64) -> Result<Option<Vec<u8>>, String>;
}

impl ElevationTiles for PmTiles {
    fn z12(&self, x: u64, y: u64) -> Result<Option<Vec<u8>>, String> {
        self.get_decompressed(ZOOM, x, y)
    }
}

/// A decoded elevation tile's place: (x, y).
type TileKey = (i64, i64);

/// Elevation from z12 Mapterhorn-format tiles (512 px, Terrarium WebP), wherever they are kept: a local PMTiles file
/// ([`PmtilesElevation`]) or the map layer engine's elevation layer (cache_search). The tiles decode the same way from either.
pub struct TileElevation<T> {
    tiles: T,
    cache: Mutex<VecDeque<(TileKey, Arc<Vec<f32>>)>>,
}

impl<T: ElevationTiles> TileElevation<T> {
    pub fn new(tiles: T) -> TileElevation<T> {
        TileElevation { tiles, cache: Mutex::new(VecDeque::new()) }
    }

    fn tile(&self, tx: i64, ty: i64) -> Result<Option<Arc<Vec<f32>>>, ElevError> {
        if tx < 0 || ty < 0 || tx >= (1 << ZOOM) || ty >= (1 << ZOOM) {
            return Ok(None);
        }
        if let Some((_, t)) = self.cache.lock().unwrap().iter().find(|(k, _)| *k == (tx, ty)) {
            return Ok(Some(t.clone()));
        }
        let Some(bytes) = self.tiles.z12(tx as u64, ty as u64).map_err(ElevError::Msg)? else { return Ok(None) };
        let q = decode_terrarium_webp(&bytes)?;
        let t = Arc::new(q.iter().map(|&v| terrarium_f32(v)).collect::<Vec<f32>>());
        let mut c = self.cache.lock().unwrap();
        c.push_back(((tx, ty), t.clone()));
        while c.len() > 8 {
            c.pop_front();
        }
        Ok(Some(t))
    }
}

/// Elevation from a local PMTiles file of Mapterhorn-format tiles (z12, 512 px, Terrarium WebP): desktop tests and the CLI.
pub struct PmtilesElevation(TileElevation<PmTiles>);

impl PmtilesElevation {
    pub fn open(path: &Path) -> Result<PmtilesElevation, ElevError> {
        let pm = PmTiles::open(path).map_err(ElevError::Msg)?;
        if pm.tile_type != 4 {
            return Err(ElevError::Msg(format!("{}: tile type {} is not WebP", path.display(), pm.tile_type)));
        }
        Ok(PmtilesElevation(TileElevation::new(pm)))
    }

    pub fn tile_count(&self) -> usize {
        self.0.tiles.tile_count()
    }
}

impl ElevationSource for PmtilesElevation {
    fn read_elevation(&self, row0: i64, col0: i64, rows: usize, cols: usize) -> Result<Vec<f32>, ElevError> {
        self.0.read_elevation(row0, col0, rows, cols)
    }
}

impl<T: ElevationTiles> ElevationSource for TileElevation<T> {
    fn read_elevation(&self, row0: i64, col0: i64, rows: usize, cols: usize) -> Result<Vec<f32>, ElevError> {
        let mut out = vec![f32::NAN; rows * cols];
        if rows == 0 || cols == 0 {
            return Ok(out);
        }
        let (r1, c1) = (row0 + rows as i64, col0 + cols as i64);
        if rows * cols <= 64 {
            // point-style reads (terrain-flat probe): through the small tile cache
            for gr in row0..r1 {
                for gc in col0..c1 {
                    if let Some(t) = self.tile(gc.div_euclid(TILE), gr.div_euclid(TILE))? {
                        out[((gr - row0) as usize) * cols + (gc - col0) as usize] = t[(gr.rem_euclid(TILE) * TILE + gc.rem_euclid(TILE)) as usize];
                    }
                }
            }
            return Ok(out);
        }
        let (ty0, ty1) = (row0.div_euclid(TILE), (r1 - 1).div_euclid(TILE));
        let (tx0, tx1) = (col0.div_euclid(TILE), (c1 - 1).div_euclid(TILE));
        let keys: Vec<(i64, i64)> = (ty0..=ty1).flat_map(|ty| (tx0..=tx1).map(move |tx| (tx, ty))).collect();
        // bytes -> f32 tiles in parallel (not through the 8-tile cache, which is for point reads)
        let tiles: Vec<(i64, i64, Option<Vec<f32>>)> = keys
            .into_par_iter()
            .map(|(tx, ty)| -> Result<_, ElevError> {
                let Some(bytes) = self.tiles.z12(tx as u64, ty as u64).map_err(ElevError::Msg)? else {
                    return Ok((tx, ty, None));
                };
                let q = decode_terrarium_webp(&bytes)?;
                Ok((tx, ty, Some(q.iter().map(|&v| terrarium_f32(v)).collect())))
            })
            .collect::<Result<Vec<_>, _>>()?;
        let w = TILE as usize;
        for (tx, ty, t) in tiles {
            let Some(t) = t else { continue };
            let (gr0, gc0) = (ty * TILE, tx * TILE);
            let (rs, re) = (gr0.max(row0), (gr0 + TILE).min(r1));
            let (cs, ce) = (gc0.max(col0), (gc0 + TILE).min(c1));
            for gr in rs..re {
                let src = ((gr - gr0) as usize) * w + (cs - gc0) as usize;
                let dst = ((gr - row0) as usize) * cols + (cs - col0) as usize;
                let n = (ce - cs) as usize;
                out[dst..dst + n].copy_from_slice(&t[src..src + n]);
            }
        }
        Ok(out)
    }
}
