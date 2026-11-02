//! The hook for off-road routing: elevation and land-cover cells for a bounding box, read from the layers the user
//! has downloaded (never from the network). `cache_offroad` depends on the `TerrainSource` trait, not on this
//! implementation, so tests there can use a fake.
//!
//! Grids are row-major with the north row first. A cell's value is taken at its centre: elevation by bilinear
//! interpolation of the DEM, land cover by nearest pixel (class values are the source's own, 0 = no data).

use crate::cog::decode_indexed_png;
use crate::contour::{decode_terrarium, Grid as Dem};
use crate::core::Inner;
use crate::error::{Error, Result};
use std::collections::HashMap;
use std::sync::Arc;

#[derive(Debug, Clone, PartialEq)]
pub struct CellGrid<T> {
    /// [west, south, east, north] of the grid
    pub bbox: [f64; 4],
    pub cols: usize,
    pub rows: usize,
    /// metres per cell as asked for
    pub cell_m: f64,
    /// the zoom the cells were read at (the tile pyramid level), so callers can see the true source resolution
    pub source_zoom: u8,
    pub data: Vec<T>,
}

impl<T: Copy> CellGrid<T> {
    /// The value at a longitude and latitude, if inside the grid.
    pub fn at(&self, lon: f64, lat: f64) -> Option<T> {
        if lon < self.bbox[0] || lon >= self.bbox[2] || lat <= self.bbox[1] || lat > self.bbox[3] {
            return None;
        }
        let c = ((lon - self.bbox[0]) / (self.bbox[2] - self.bbox[0]) * self.cols as f64) as usize;
        let r = ((self.bbox[3] - lat) / (self.bbox[3] - self.bbox[1]) * self.rows as f64) as usize;
        self.data.get(r.min(self.rows - 1) * self.cols + c.min(self.cols - 1)).copied()
    }
}

/// What downloaded areas cover, per kind of data.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Coverage {
    pub elevation: Vec<[f64; 4]>,
    pub land_cover: Vec<[f64; 4]>,
}

pub trait TerrainSource {
    /// Elevation in metres (NaN where there is no data), `cell_m` metres per cell. Fails with `not_found` when no
    /// downloaded elevation covers any of the box.
    fn elevation_m(&self, bbox: [f64; 4], cell_m: f64) -> Result<CellGrid<f32>>;
    /// Land-cover class per cell (0 where there is no data).
    fn land_cover(&self, bbox: [f64; 4], cell_m: f64) -> Result<CellGrid<u8>>;
    fn coverage(&self) -> Coverage;
}

/// `TerrainSource` over the downloaded PMTiles of an elevation layer and a land-cover layer.
pub struct DownloadedTerrain {
    inner: Arc<Inner>,
    elevation_layer: String,
    land_cover_layer: Option<String>,
}

impl DownloadedTerrain {
    pub fn new(inner: Arc<Inner>, elevation_layer: &str, land_cover_layer: Option<&str>) -> DownloadedTerrain {
        DownloadedTerrain { inner, elevation_layer: elevation_layer.to_string(), land_cover_layer: land_cover_layer.map(String::from) }
    }

    fn dims(bbox: [f64; 4], cell_m: f64) -> Result<(usize, usize)> {
        if cell_m.is_nan() || cell_m <= 0.0 || bbox[0] >= bbox[2] || bbox[1] >= bbox[3] {
            return Err(Error::bad_json("a box [west, south, east, north] and a cell size above 0 are needed"));
        }
        let mid = ((bbox[1] + bbox[3]) / 2.0).to_radians();
        let w_m = (bbox[2] - bbox[0]) * 111_320.0 * mid.cos();
        let h_m = (bbox[3] - bbox[1]) * 110_540.0;
        let (c, r) = ((w_m / cell_m).ceil().max(1.0) as usize, (h_m / cell_m).ceil().max(1.0) as usize);
        if c.saturating_mul(r) > 100_000_000 {
            return Err(Error::limit("that box has too many cells; ask for a smaller box or bigger cells"));
        }
        Ok((c, r))
    }

    /// The highest zoom, at most `max_z`, whose pixels are no bigger than `cell_m` (or `max_z`).
    fn pick_zoom(lat: f64, tile_px: f64, cell_m: f64, max_z: u8) -> u8 {
        for z in 0..=max_z {
            let m_per_px = 156_543.033_92 * lat.to_radians().cos() / (1u64 << z) as f64 * 256.0 / tile_px;
            if m_per_px <= cell_m {
                return z;
            }
        }
        max_z
    }

    fn layer_zoom_limit(&self, layer: &str) -> Result<(u8, f64)> {
        let areas = self.inner.areas(&self.inner.base_of(layer)?.id);
        let z = areas.iter().map(|a| a.maxzoom).max().ok_or_else(|| Error::not_found(format!("nothing is downloaded for {layer:?}")))?;
        let tp = self.inner.base_of(layer)?.source.and_then(|s| s.tile_size).unwrap_or(256) as f64;
        Ok((z, tp))
    }

    fn sample<T: Copy>(
        &self,
        layer: &str,
        bbox: [f64; 4],
        cell_m: f64,
        empty: T,
        decode_tile: &dyn Fn(&[u8]) -> Result<Arc<Dem>>,
        pick: &dyn Fn(&Dem, f64, f64) -> T,
    ) -> Result<CellGrid<T>> {
        let base = self.inner.base_of(layer)?;
        let (maxz, tile_px) = self.layer_zoom_limit(layer)?;
        let (cols, rows) = Self::dims(bbox, cell_m)?;
        let mid_lat = (bbox[1] + bbox[3]) / 2.0;
        let z = Self::pick_zoom(mid_lat, tile_px, cell_m, maxz);
        let n = (1u64 << z) as f64;
        let mut cache: HashMap<(u32, u32), Option<Arc<Dem>>> = HashMap::new();
        let mut data = Vec::with_capacity(cols * rows);
        let mut any = false;
        for r in 0..rows {
            let lat = bbox[3] - (r as f64 + 0.5) / rows as f64 * (bbox[3] - bbox[1]);
            let ty = (1.0 - (lat.to_radians().tan() + 1.0 / lat.to_radians().cos()).ln() / std::f64::consts::PI) / 2.0 * n;
            for c in 0..cols {
                let lon = bbox[0] + (c as f64 + 0.5) / cols as f64 * (bbox[2] - bbox[0]);
                let tx = (lon + 180.0) / 360.0 * n;
                let (xi, yi) = (tx.floor().clamp(0.0, n - 1.0) as u32, ty.floor().clamp(0.0, n - 1.0) as u32);
                if let std::collections::hash_map::Entry::Vacant(e) = cache.entry((xi, yi)) {
                    let t = match self.inner.downloaded_tile(&base, z, xi, yi)? {
                        Some(b) => Some(decode_tile(&b)?),
                        None => None,
                    };
                    e.insert(t);
                }
                match cache.get(&(xi, yi)).and_then(|t| t.as_ref()) {
                    Some(t) => {
                        any = true;
                        data.push(pick(t, (tx - xi as f64) * t.w as f64, (ty - yi as f64) * t.h as f64));
                    }
                    None => data.push(empty),
                }
            }
        }
        if !any {
            return Err(Error::not_found(format!("no downloaded {layer:?} tiles cover that box")));
        }
        Ok(CellGrid { bbox, cols, rows, cell_m, source_zoom: z, data })
    }
}

impl TerrainSource for DownloadedTerrain {
    fn elevation_m(&self, bbox: [f64; 4], cell_m: f64) -> Result<CellGrid<f32>> {
        self.sample(
            &self.elevation_layer,
            bbox,
            cell_m,
            f32::NAN,
            &|b| Ok(Arc::new(decode_terrarium(b)?)),
            &|d, px, py| {
                // bilinear between pixel centres
                let (fx, fy) = (px - 0.5, py - 0.5);
                let (x0, y0) = (fx.floor(), fy.floor());
                let (tx, ty) = ((fx - x0) as f32, (fy - y0) as f32);
                let g = |dx: f64, dy: f64| d.get((x0 + dx) as i64, (y0 + dy) as i64);
                let v = [g(0.0, 0.0), g(1.0, 0.0), g(0.0, 1.0), g(1.0, 1.0)];
                let (mut sum, mut wsum) = (0.0f32, 0.0f32);
                for (val, w) in v.iter().zip([(1.0 - tx) * (1.0 - ty), tx * (1.0 - ty), (1.0 - tx) * ty, tx * ty]) {
                    if !val.is_nan() {
                        sum += val * w;
                        wsum += w;
                    }
                }
                if wsum > 0.0 { sum / wsum } else { f32::NAN }
            },
        )
    }

    fn land_cover(&self, bbox: [f64; 4], cell_m: f64) -> Result<CellGrid<u8>> {
        let layer = self.land_cover_layer.as_deref().ok_or_else(|| Error::not_found("no land-cover layer is set"))?;
        self.sample(
            layer,
            bbox,
            cell_m,
            0u8,
            &|b| {
                let (w, h, px) = decode_indexed_png(b)?;
                Ok(Arc::new(Dem { w: w as usize, h: h as usize, d: px.into_iter().map(|v| v as f32).collect() }))
            },
            &|d, px, py| d.get(px.floor() as i64, py.floor() as i64).max(0.0) as u8,
        )
    }

    fn coverage(&self) -> Coverage {
        let of = |layer: &str| -> Vec<[f64; 4]> {
            self.inner.base_of(layer).map(|b| self.inner.areas(&b.id).iter().map(|a| a.bbox).collect()).unwrap_or_default()
        };
        Coverage { elevation: of(&self.elevation_layer), land_cover: self.land_cover_layer.as_deref().map(of).unwrap_or_default() }
    }
}
