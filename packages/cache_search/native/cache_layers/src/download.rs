//! Area downloads into the layer's merged tile store (see store.rs): plan (dry run), download, resume, update, delete.
//!
//! Areas overlap, so a tile is stored once. A download fetches only the tiles of its area that are not already on the
//! device; a delete removes only the tiles no other area covers. The tiles an area needs are computed from its shape
//! (polygon or box, zoom range), never stored per area. An unfinished download is an area in state "partial": the
//! tiles already stored stay, and starting the same request again fetches the rest. An update fetches the tiles whose
//! version is older than the layer's into a staging table and swaps them in, with the area's new version, in one
//! transaction when all are there.

use crate::core::{now_secs, Inner};
use crate::cover::{Outline, Polygon};
use crate::def::{LayerDef, Source, Transform};
use crate::error::{available_bytes, Error, Result};
use crate::pmtiles::{self, zxy_to_id, Reader};
use crate::store::{Held, Store, Table};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, VecDeque};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{mpsc, Mutex};
use std::time::Duration;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AreaReq {
    pub layer: String,
    #[serde(default)]
    pub name: Option<String>,
    /// An existing area to update or resume; otherwise the id comes from the request.
    #[serde(default)]
    pub area: Option<String>,
    #[serde(default)]
    pub bbox: Option<[f64; 4]>,
    /// The outline: one ring `[[lon, lat], ...]`, or several `[[[lon, lat], ...], ...]` (a region in parts, holes), read
    /// even-odd (see cover.rs). Only the tiles it touches are downloaded.
    #[serde(default)]
    pub polygon: Option<Polygon>,
    #[serde(default)]
    pub minzoom: Option<u8>,
    #[serde(default)]
    pub maxzoom: Option<u8>,
    /// Re-download an existing area (same shape and zooms) at the layer's newest version.
    #[serde(default)]
    pub update: bool,
    /// `[lat, lon]`: the tiles are fetched from here outwards (the phone's position, else the area's centre), each zoom from
    /// the coarsest, so what is near is on the phone first. Not part of the area's shape.
    #[serde(default)]
    pub near: Option<[f64; 2]>,
}

/// `tiles` (`(id, z, x, y)`) by zoom, coarsest first, then by distance from `near` (`[lat, lon]`); stable, so tiles at the
/// same distance keep their order.
pub fn order_from(tiles: &mut [(u64, u8, u32, u32)], near: [f64; 2]) {
    let [lat, lon] = near;
    if !lat.is_finite() || !lon.is_finite() {
        return;
    }
    tiles.sort_by(|a, b| {
        let d = |t: &(u64, u8, u32, u32)| {
            let (cx, cy) = (lon_to_x(lon, t.1), lat_to_y(lat, t.1));
            let (dx, dy) = (t.2 as f64 + 0.5 - cx, t.3 as f64 + 0.5 - cy);
            dx * dx + dy * dy
        };
        a.1.cmp(&b.1).then(d(a).total_cmp(&d(b)))
    });
}

/// The zoom whose tiles are a PMTiles download's blocks (about 39 km across): see [`order_blocks_from`].
const BLOCK_ZOOM: u8 = 10;

/// The order a download from a PMTiles archive fetches its tiles in: the zooms up to [`BLOCK_ZOOM`] first (few tiles), from
/// the near point outwards; then block by block (each tile's ancestor at [`BLOCK_ZOOM`]), nearest block first, and inside a
/// block in tile id order. Tile ids follow the archive's Hilbert order, so the tiles of a block lie side by side in the file
/// and merge into a few large range reads. [`order_from`] (each zoom from the near point outwards, tile by tile) scattered
/// every batch across the archive: Idaho's map took one request for every few tiles.
pub fn order_blocks_from(tiles: &mut [(u64, u8, u32, u32)], near: Option<[f64; 2]>) {
    let (cx, cy) = match near {
        Some([lat, lon]) if lat.is_finite() && lon.is_finite() => (lon_to_x(lon, BLOCK_ZOOM), lat_to_y(lat, BLOCK_ZOOM)),
        _ => (f64::NAN, f64::NAN),
    };
    let dist = |z: u8, x: u32, y: u32| -> f64 {
        if cx.is_nan() {
            return 0.0;
        }
        // the tile's centre in BLOCK_ZOOM tile units
        let s = (1u64 << BLOCK_ZOOM) as f64 / (1u64 << z) as f64;
        let (tx, ty) = ((x as f64 + 0.5) * s, (y as f64 + 0.5) * s);
        (tx - cx).powi(2) + (ty - cy).powi(2)
    };
    tiles.sort_by(|a, b| {
        let key = |t: &(u64, u8, u32, u32)| {
            if t.1 <= BLOCK_ZOOM {
                (0u8, t.1, dist(t.1, t.2, t.3), 0u32, 0u32)
            } else {
                let k = t.1 - BLOCK_ZOOM;
                let (bx, by) = (t.2 >> k, t.3 >> k);
                (1u8, 0, dist(BLOCK_ZOOM, bx, by), bx, by)
            }
        };
        let (ka, kb) = (key(a), key(b));
        ka.0.cmp(&kb.0)
            .then(ka.1.cmp(&kb.1))
            .then(ka.2.total_cmp(&kb.2))
            .then(ka.3.cmp(&kb.3))
            .then(ka.4.cmp(&kb.4))
            .then(a.0.cmp(&b.0))
    });
}

/// Tiles a PMTiles download stores per batch (one transaction, one progress report).
const PMTILES_BATCH: usize = 1024;

/// How far a PMTiles download reads ahead of the batch it stores next: at most this many batches and this many bytes of merged
/// reads behind it, so the next batch's reads are in flight while this one's slowest read is still arriving.
const AHEAD_BATCHES: usize = 3;
const AHEAD_BYTES: u64 = 32 * 1024 * 1024;

/// Tiles a plan locates in the archive's directory per round: the directory pages they need are fetched in parallel first.
const LOCATE_CHUNK: usize = 262_144;

const MAX_ENUMERATED: u64 = 6_000_000;

/// The most tiles a size estimate fetches at one zoom, and in all (see `sample_estimate`).
const SAMPLES_PER_ZOOM: usize = 4;
const SAMPLE_BUDGET: usize = 16;

pub enum Done {
    Finished,
    Cancelled,
}

fn lon_to_x(lon: f64, z: u8) -> f64 {
    (lon + 180.0) / 360.0 * (1u64 << z) as f64
}
fn lat_to_y(lat: f64, z: u8) -> f64 {
    let lat = lat.clamp(-85.0511287, 85.0511287).to_radians();
    (1.0 - (lat.tan() + 1.0 / lat.cos()).ln() / std::f64::consts::PI) / 2.0 * (1u64 << z) as f64
}

/// The box of tiles (x0, x1, y0, y1) at a zoom that a bounding box touches.
pub fn tile_range(b: [f64; 4], z: u8) -> (u64, u64, u64, u64) {
    let n = 1u64 << z;
    let x0 = lon_to_x(b[0], z).floor().max(0.0) as u64;
    let x1 = (lon_to_x(b[2], z).ceil() as u64).saturating_sub(1).min(n - 1).max(x0);
    let y0 = lat_to_y(b[3], z).floor().max(0.0) as u64;
    let y1 = (lat_to_y(b[1], z).ceil() as u64).saturating_sub(1).min(n - 1).max(y0);
    (x0, x1, y0, y1)
}

impl AreaReq {
    pub fn parse(json: &str) -> Result<AreaReq> {
        serde_json::from_str(json).map_err(|e| Error::bad_json(format!("download request: {e}")))
    }

    /// The bounding box of the request (of the polygon when given).
    pub fn bounds(&self) -> Result<[f64; 4]> {
        let b = match (&self.polygon, &self.bbox) {
            (Some(p), _) => p.bounds()?,
            (None, Some(b)) => *b,
            _ => return Err(Error::bad_json("a download needs \"bbox\" [west, south, east, north] or \"polygon\" [[lon, lat], ...]")),
        };
        if !(b.iter().all(|v| v.is_finite()) && b[0] >= -180.0 && b[2] <= 180.0 && b[1] >= -90.0 && b[3] <= 90.0 && b[0] < b[2] && b[1] < b[3]) {
            return Err(Error::bad_json("the area is not valid: [west, south, east, north] in degrees, west < east, south < north"));
        }
        Ok(b)
    }

    /// Every tile of the area in the zoom range, in PMTiles tile id order: of the box, or of the box that the outline touches.
    pub fn tiles(&self, zmin: u8, zmax: u8) -> Result<Vec<(u64, u8, u32, u32)>> {
        let b = self.bounds()?;
        let mut out: Vec<(u64, u8, u32, u32)> = Vec::new();
        if let Some(p) = &self.polygon {
            let ranges: Vec<(u64, u64, u64, u64)> = (0..=zmax).map(|z| tile_range(b, z)).collect();
            let keep = |z: u8, x: u32, y: u32| {
                let (x0, x1, y0, y1) = ranges[z as usize];
                (x0..=x1).contains(&(x as u64)) && (y0..=y1).contains(&(y as u64))
            };
            out = Outline::new(p).tiles(zmin, zmax, MAX_ENUMERATED, keep)?.into_iter().map(|(z, x, y)| (zxy_to_id(z, x, y), z, x, y)).collect();
        } else {
            for z in zmin..=zmax {
                let (x0, x1, y0, y1) = tile_range(b, z);
                if (x1 - x0 + 1).saturating_mul(y1 - y0 + 1).saturating_add(out.len() as u64) > MAX_ENUMERATED {
                    return Err(Error::limit("that area at those zooms has far too many tiles to list; choose a smaller area or fewer zooms"));
                }
                for x in x0..=x1 {
                    for y in y0..=y1 {
                        out.push((zxy_to_id(z, x as u32, y as u32), z, x as u32, y as u32));
                    }
                }
            }
        }
        out.sort_unstable();
        Ok(out)
    }

    pub fn area_id(&self) -> Result<String> {
        if let Some(a) = &self.area {
            if !crate::def::valid_id(a) {
                return Err(Error::bad_json("area must be 1-64 characters: a-z, 0-9, - and _"));
            }
            return Ok(a.clone());
        }
        let mut h = Sha256::new();
        let b = self.bounds()?;
        for v in b {
            h.update(format!("{v:.4},"));
        }
        match &self.polygon {
            Some(Polygon::Ring(p)) => {
                for q in p {
                    h.update(format!("{:.4},{:.4};", q[0], q[1]));
                }
            }
            Some(Polygon::Rings(rs)) => {
                for r in rs {
                    for q in r {
                        h.update(format!("{:.4},{:.4};", q[0], q[1]));
                    }
                    h.update("|");
                }
            }
            None => {}
        }
        h.update(format!("z{}-{}", self.minzoom.unwrap_or(0), self.maxzoom.unwrap_or(0)));
        let d = h.finalize();
        Ok(format!("a-{}", d[..5].iter().map(|b| format!("{b:02x}")).collect::<String>()))
    }
}

fn type_of(fmt: Option<&str>) -> Option<u8> {
    match fmt? {
        "mvt" => Some(pmtiles::TYPE_MVT),
        "png" => Some(pmtiles::TYPE_PNG),
        "jpg" => Some(pmtiles::TYPE_JPEG),
        "webp" => Some(pmtiles::TYPE_WEBP),
        _ => None,
    }
}

/// What an area covers: a box or polygon and a zoom range. Which tiles that is, is computed, never stored.
#[derive(Debug, Clone, PartialEq)]
pub struct Shape {
    pub bbox: [f64; 4],
    pub polygon: Option<Polygon>,
    pub minzoom: u8,
    pub maxzoom: u8,
}

impl Shape {
    pub fn from_meta(m: &Value) -> Option<Shape> {
        let b = m["bbox"].as_array()?;
        if b.len() != 4 {
            return None;
        }
        let f = |i: usize| b[i].as_f64();
        Some(Shape {
            bbox: [f(0)?, f(1)?, f(2)?, f(3)?],
            polygon: serde_json::from_value(m["polygon"].clone()).ok().flatten(),
            minzoom: m["minzoom"].as_u64()? as u8,
            maxzoom: m["maxzoom"].as_u64()? as u8,
        })
    }

    /// Whether the tile is in the area's zooms and box (the outline aside: see [`Shape::covers`]).
    fn in_box(&self, z: u8, x: u32, y: u32) -> bool {
        if z < self.minzoom || z > self.maxzoom {
            return false;
        }
        let (x0, x1, y0, y1) = tile_range(self.bbox, z);
        (x0..=x1).contains(&(x as u64)) && (y0..=y1).contains(&(y as u64))
    }

    pub fn covers(&self, z: u8, x: u32, y: u32) -> bool {
        self.in_box(z, x, y) && self.polygon.as_ref().map(|p| Outline::new(p).asker().touches(z, x, y)).unwrap_or(true)
    }

    pub fn tiles(&self) -> Result<Vec<(u64, u8, u32, u32)>> {
        AreaReq { layer: String::new(), name: None, area: None, bbox: Some(self.bbox), polygon: self.polygon.clone(), minzoom: None, maxzoom: None, update: false, near: None }.tiles(self.minzoom, self.maxzoom)
    }
}

fn gzip_if_mvt(mut d: Vec<u8>, gzip_mvt: bool) -> Vec<u8> {
    if gzip_mvt && !pmtiles::is_gzip(&d) {
        d = pmtiles::gzip(&d);
    }
    d
}

struct Prepared {
    req: AreaReq,
    base: LayerDef,
    dl: LayerDef,
    src: Source,
    zmin: u8,
    zmax: u8,
    area: String,
    cover: Vec<(u64, u8, u32, u32)>,
    need: Vec<(u64, u8, u32, u32)>,
    /// Tiles of the cover already on the device (at the layer's version, for an update), and their bytes.
    already: (u64, u64),
    /// For a PMTiles source: where each tile of `need` is in the archive (offset and length in the tile data), or `None` when
    /// the archive has no such tile. Found once, by the plan; the download reads by it and looks nothing up again.
    located: Option<Vec<Option<(u64, u32)>>>,
    mode: &'static str,
    existing: Option<(String, Value)>,
}

/// The tiles of `tiles` (in tile id order, so zoom by zoom) a zoom at a time, with the box they span at that zoom.
/// One zoom's tiles: the zoom, the x and y spans, the tiles.
type ZoomRun<'a> = (u8, (u32, u32), (u32, u32), &'a [Tile]);

fn by_zoom(tiles: &[Tile]) -> impl Iterator<Item = ZoomRun<'_>> {
    tiles.chunk_by(|a, b| a.1 == b.1).map(|run| {
        let (mut x0, mut x1, mut y0, mut y1) = (u32::MAX, 0, u32::MAX, 0);
        for t in run {
            x0 = x0.min(t.2);
            x1 = x1.max(t.2);
            y0 = y0.min(t.3);
            y1 = y1.max(t.3);
        }
        (run[0].1, (x0, x1), (y0, y1), run)
    })
}

/// What the store holds of `tiles`, one range query per zoom: `each(tile, (bytes, at version ver) or None)`.
fn each_held(store: Option<&Store>, table: Table, tiles: &[(u64, u8, u32, u32)], ver: &str, mut each: impl FnMut(&(u64, u8, u32, u32), Option<(u64, bool)>)) -> Result<()> {
    for (z, xs, ys, run) in by_zoom(tiles) {
        let held: Held = match store {
            Some(s) => s.held(table, z, xs, ys, ver)?,
            None => Held::new(),
        };
        for t in run {
            each(t, held.get(&(t.2, t.3)).copied());
        }
    }
    Ok(())
}

/// Where each of `tiles` is in the archive. The directory pages they need are fetched in parallel, a large slice of tiles at a
/// time, before the lookups, which then read memory only.
fn locate(r: &Reader, tiles: &[(u64, u8, u32, u32)]) -> Result<Vec<Option<(u64, u32)>>> {
    let mut out = Vec::with_capacity(tiles.len());
    for chunk in tiles.chunks(LOCATE_CHUNK) {
        r.prefetch_leaves(&chunk.iter().map(|t| t.0).collect::<Vec<_>>())?;
        for t in chunk {
            out.push(r.lookup(t.0)?);
        }
    }
    Ok(out)
}

/// One batch of a PMTiles download on its way: its merged reads, and those that have arrived.
struct InFlight {
    start: usize,
    end: usize,
    want: Vec<(u64, u32)>,
    /// for each tile of the batch, its place in `want` (None: the archive has no such tile)
    slot: Vec<Option<usize>>,
    groups: Vec<pmtiles::Group>,
    bufs: Vec<Option<Vec<u8>>>,
    left: usize,
    bytes: u64,
}

/// Sets the flag when dropped: the readers stop taking work however the download ends.
struct StopOnDrop<'a>(&'a AtomicBool);
impl Drop for StopOnDrop<'_> {
    fn drop(&mut self) {
        self.0.store(true, Ordering::SeqCst);
    }
}

type Tile = (u64, u8, u32, u32);
type Commit<'a> = dyn FnMut(&[Tile], Vec<Option<Vec<u8>>>) -> Result<()> + 'a;

impl Inner {
    /// An update or resume request (`"area"` and no shape) with the stored area's shape, zooms and name filled in; any other
    /// request as it is. A job checks the shape of what it is asked before it starts, so it takes the request through here.
    pub fn resolve_request(&self, req: &AreaReq) -> Result<AreaReq> {
        self.resolve_req(req)
    }

    /// Fill in an update or resume from the area's stored request.
    fn resolve_req(&self, req: &AreaReq) -> Result<AreaReq> {
        let mut r = req.clone();
        if r.update || (r.bbox.is_none() && r.polygon.is_none()) {
            let area = r.area.clone().ok_or_else(|| Error::bad_json("an update or resume needs \"area\""))?;
            let base = self.base_of(&r.layer)?;
            let (_, m) = self
                .store_read(&base.id)
                .and_then(|s| s.area(&area).ok().flatten())
                .ok_or_else(|| Error::not_found(format!("no area {area:?} of layer {:?}", r.layer)))?;
            if r.bbox.is_none() && r.polygon.is_none() {
                r.polygon = serde_json::from_value(m["polygon"].clone()).ok().flatten();
                r.bbox = serde_json::from_value(m["bbox"].clone()).ok();
            }
            r.minzoom = r.minzoom.or(m["minzoom"].as_u64().map(|v| v as u8));
            r.maxzoom = r.maxzoom.or(m["maxzoom"].as_u64().map(|v| v as u8));
            r.name = r.name.or(m["name"].as_str().map(String::from));
        }
        Ok(r)
    }

    fn zoom_span(&self, src: &Source, r: &AreaReq) -> Result<(u8, u8)> {
        let lo = r.minzoom.unwrap_or(0).max(src.minzoom.unwrap_or(0));
        let hi = r.maxzoom.unwrap_or(src.maxzoom.unwrap_or(14)).min(src.maxzoom.unwrap_or(24));
        if lo > hi {
            return Err(Error::bad_json(format!("zoom range {}-{} is outside what the layer has ({}-{})", r.minzoom.unwrap_or(0), r.maxzoom.unwrap_or(0), src.minzoom.unwrap_or(0), src.maxzoom.unwrap_or(24))));
        }
        Ok((lo, hi))
    }

    fn download_def(base: &LayerDef) -> Result<LayerDef> {
        let mut d = base.clone();
        d.source = Some(base.download_source().cloned().ok_or_else(|| Error::bad_json("the layer has no source"))?);
        Ok(d)
    }

    /// Work out what a request needs: the cover of the area, and which of those tiles are not yet on the device.
    fn prepare(&self, req: &AreaReq) -> Result<Prepared> {
        let req = self.resolve_req(req)?;
        let base = self.base_of(&req.layer)?;
        if base.transform == Transform::OnlineOnly || !base.offline_allowed() {
            return Err(Error::offline(format!("{} cannot be downloaded: it needs a connection", base.title)));
        }
        let dl = Self::download_def(&base)?;
        let src = dl.source.clone().unwrap();
        let (zmin, zmax) = self.zoom_span(&src, &req)?;
        let cover = req.tiles(zmin, zmax)?;
        let area = req.area_id()?;
        let store = self.store_read(&base.id);
        let existing = store.as_ref().and_then(|s| s.area(&area).ok().flatten());
        let shape = Shape { bbox: req.bounds()?, polygon: req.polygon.clone(), minzoom: zmin, maxzoom: zmax };
        let mut mode = "new";
        if let Some((state, meta)) = &existing {
            if Shape::from_meta(meta).as_ref() != Some(&shape) {
                return Err(Error::bad_json(format!("the area id {area:?} is already used for a different shape or zoom range; delete it or choose another id")));
            }
            mode = if req.update { "update" } else if state == "partial" { "resume" } else { "extend" };
        } else if req.update {
            return Err(Error::not_found(format!("no area {area:?} to update")));
        }
        let newest = base.version().to_string();
        // one range query of the store per zoom, not one query per tile
        let (mut need, mut already) = (Vec::new(), (0u64, 0u64));
        each_held(store.as_deref(), Table::Tiles, &cover, &newest, |t, have| match (have, mode) {
            (None, _) | (Some((_, false)), "update") => need.push(*t),
            (Some((n, _)), _) => {
                already.0 += 1;
                already.1 += n;
            }
        })?;
        Ok(Prepared { req, base, dl, src, zmin, zmax, area, cover, need, already, located: None, mode, existing })
    }

    /// The dry run: how many tiles the area covers, how many of them are not on the device yet, and what fetching
    /// those would cost; whether it fits the layer's limits and the free space.
    pub fn plan(&self, req: &AreaReq) -> Result<Value> {
        self.plan_inner(req).map(|(v, _)| v)
    }

    fn plan_inner(&self, req: &AreaReq) -> Result<(Value, Prepared)> {
        let mut p = self.prepare(req)?;
        let mut per_zoom: BTreeMap<u8, u64> = BTreeMap::new();
        for t in &p.cover {
            *per_zoom.entry(t.1).or_default() += 1;
        }
        let (already, already_bytes) = p.already;
        let n = p.need.len() as u64;
        let (est, method, present) = if p.need.is_empty() {
            (0, "none".to_string(), Some(0))
        } else if !self.is_online() {
            return Err(Error::offline("the size of a download is read from the source, which needs a connection"));
        } else if p.src.kind == "pmtiles" {
            // The download's own reader (its own limit of requests in flight, not the map's), whose directory pages every engine
            // of the process shares: the job that follows reads none of them again.
            let r = self.download_pmtiles(&p.dl, &p.src.url)?;
            let located = locate(&r, &p.need)?;
            let (mut bytes, mut have) = (0u64, 0u64);
            for (_, l) in located.iter().flatten() {
                bytes += *l as u64;
                have += 1;
            }
            p.located = Some(located);
            (bytes, "directory".to_string(), Some(have))
        } else {
            let (est, k) = self.sample_estimate(&p)?;
            (est, format!("sample of {k} tiles"), None)
        };
        let mut problems: Vec<Value> = Vec::new();
        let o = p.base.offline.as_ref();
        if let Some(m) = o.and_then(|o| o.max_tiles_per_download) {
            if n > m {
                problems.push(json!({"code": "limit_exceeded", "message": format!("{n} tiles to download is above this layer's limit of {m} per download")}));
            }
        }
        if let Some(m) = o.and_then(|o| o.max_bytes_per_download) {
            if est > m {
                problems.push(json!({"code": "limit_exceeded", "message": format!("about {est} bytes to download is above this layer's limit of {m} per download")}));
            }
        }
        let probe: PathBuf = if self.dir.join("store").exists() { self.dir.join("store") } else { self.dir.clone() };
        let free = available_bytes(&probe).ok();
        let needed = est + est / 10 + 8 * 1024 * 1024;
        if let Some(f) = free {
            if needed > f {
                problems.push(json!({"code": "no_space", "message": format!("needs about {needed} bytes free, {f} available"), "needed": needed, "available": f}));
            }
        }
        let v = json!({
            "layer": p.req.layer,
            "download_layer": p.base.id,
            "area": p.area,
            "mode": p.mode,
            "tiles": p.cover.len(),
            "tiles_to_download": n,
            "tiles_already": already,
            "already_bytes": already_bytes,
            "tiles_present": present,
            "per_zoom": per_zoom,
            "minzoom": p.zmin,
            "maxzoom": p.zmax,
            "estimated_bytes": est,
            "estimate_method": method,
            "limits": {
                "max_tiles_per_download": o.and_then(|o| o.max_tiles_per_download),
                "max_bytes_per_download": o.and_then(|o| o.max_bytes_per_download),
                "max_parallel": p.base.max_parallel(),
            },
            "free_bytes": free,
            "version": p.base.version(),
            "exists": p.existing.as_ref().map(|e| e.0 == "complete").unwrap_or(false),
            "resumable": p.existing.as_ref().map(|e| e.0 == "partial").unwrap_or(false),
            "ok_to_start": problems.is_empty(),
            "problems": problems,
        });
        Ok((v, p))
    }

    /// The size of the tiles to fetch from a sample of them, for a source with no directory to read sizes from. Every zoom is
    /// sampled (one tile each first, then more at the deepest zooms, which hold most of the tiles), evenly spaced along that
    /// zoom's tiles, at most [SAMPLES_PER_ZOOM] a zoom and [SAMPLE_BUDGET] in all. A zoom's tiles count as the mean of its
    /// sampled tiles that have data; a tile the source has nothing for (sea, an empty corner) is left out of the mean, so it
    /// does not pull the estimate down. A zoom with no sampled data uses the mean of all of them. Returns the bytes and the
    /// number of tiles fetched.
    fn sample_estimate(&self, p: &Prepared) -> Result<(u64, usize)> {
        let mut by_zoom: BTreeMap<u8, Vec<(u8, u32, u32)>> = BTreeMap::new();
        for t in &p.need {
            by_zoom.entry(t.1).or_default().push((t.1, t.2, t.3));
        }
        // How many tiles to sample at each zoom, deepest first.
        let mut take: BTreeMap<u8, usize> = BTreeMap::new();
        let mut budget = SAMPLE_BUDGET;
        for round in 0..SAMPLES_PER_ZOOM {
            for (z, tiles) in by_zoom.iter().rev() {
                if budget > 0 && tiles.len() > round {
                    *take.entry(*z).or_default() += 1;
                    budget -= 1;
                }
            }
        }
        let (mut mean, mut all_bytes, mut all_with, mut fetched) = (BTreeMap::new(), 0u64, 0u64, 0usize);
        for (z, k) in &take {
            let tiles = &by_zoom[z];
            let (mut bytes, mut with) = (0u64, 0u64);
            for i in 0..*k {
                // Evenly spaced, the middle one when there is one.
                let idx = if *k == 1 { tiles.len() / 2 } else { i * (tiles.len() - 1) / (k - 1) };
                let (tz, x, y) = tiles[idx];
                fetched += 1;
                if let Some(b) = self.fetch_source(&p.dl, tz, x, y)? {
                    if !b.is_empty() {
                        bytes += b.len() as u64;
                        with += 1;
                    }
                }
            }
            if let Some(m) = bytes.checked_div(with) {
                mean.insert(*z, m);
            }
            all_bytes += bytes;
            all_with += with;
        }
        let overall = all_bytes.checked_div(all_with).unwrap_or(0);
        let est = by_zoom.iter().map(|(z, tiles)| tiles.len() as u64 * mean.get(z).copied().unwrap_or(overall)).sum();
        Ok((est, fetched))
    }

    /// Statistics of what an area covers once downloaded: tiles with data and their bytes (shared tiles included).
    fn cover_stats(&self, store: &Store, cover: &[(u64, u8, u32, u32)]) -> Result<(u64, u64)> {
        let (mut present, mut bytes) = (0u64, 0u64);
        each_held(Some(store), Table::Tiles, cover, "", |_, have| {
            if let Some((n, _)) = have {
                if n > 0 {
                    present += 1;
                    bytes += n;
                }
            }
        })?;
        Ok((present, bytes))
    }

    /// Run a download, resume or update to the end (or cancellation). `progress(done, total, detail)` is called after
    /// each batch; `total` counts the tiles that had to be fetched, not the tiles already on the device.
    pub fn run_download(&self, req: &AreaReq, progress: &dyn Fn(u64, u64, Value), cancelled: &(dyn Fn() -> bool + Sync)) -> Result<Done> {
        let (plan, p) = self.plan_inner(req)?;
        if let Some(pr) = plan["problems"].as_array().and_then(|a| a.first()) {
            return Err(match pr["code"].as_str() {
                Some("no_space") => Error::no_space(pr["message"].as_str().unwrap_or(""), pr["needed"].as_u64().unwrap_or(0), pr["available"].as_u64().unwrap_or(0)),
                _ => Error::limit(pr["message"].as_str().unwrap_or("over a limit")),
            });
        }
        let store = self.store_create(&p.base.id)?;
        let ver = p.base.version().to_string();
        let bounds = p.req.bounds()?;
        let name = p.req.name.clone().or_else(|| p.existing.as_ref().and_then(|e| e.1["name"].as_str().map(String::from))).unwrap_or_else(|| p.area.clone());
        let mut meta = json!({
            "id": p.area, "name": name, "layer": p.base.id, "bbox": bounds, "polygon": p.req.polygon, "minzoom": p.zmin, "maxzoom": p.zmax,
            "version": p.existing.as_ref().and_then(|e| e.1["version"].as_str().map(String::from)).unwrap_or_else(|| ver.clone()),
            "tiles_requested": p.cover.len(), "source": p.src.url,
        });
        if let Some((_, old)) = &p.existing {
            meta["created"] = old["created"].clone();
        }
        let updating = p.mode == "update";
        if p.existing.is_none() {
            store.put_area(&p.area, "partial", &meta)?;
        }
        let total = p.need.len() as u64;
        let max_bytes = p.base.offline.as_ref().and_then(|o| o.max_bytes_per_download);
        let gzip_mvt = p.src.kind != "pmtiles" && (type_of(p.src.format()) == Some(pmtiles::TYPE_MVT) || p.src.format().is_none() && p.base.kind == crate::def::Kind::Vector);
        let reader = if p.src.kind == "pmtiles" { Some(self.download_pmtiles(&p.dl, &p.src.url)?) } else { None };
        let table = if updating { Table::Staging } else { Table::Tiles };
        if updating {
            store.staging_keep_only(&ver)?;
        }
        // staged tiles of this version from an interrupted update are kept
        let mut todo: Vec<(u64, u8, u32, u32)> = if updating {
            let mut left = Vec::with_capacity(p.need.len());
            each_held(Some(&*store), Table::Staging, &p.need, &ver, |t, staged| {
                if !matches!(staged, Some((_, true))) {
                    left.push(*t);
                }
            })?;
            left
        } else {
            p.need.clone()
        };
        if reader.is_some() {
            order_blocks_from(&mut todo, req.near);
        } else if let Some(near) = req.near {
            order_from(&mut todo, near);
        }
        let skipped = total - todo.len() as u64;
        let (mut done, mut run_bytes) = (skipped, 0u64);
        let mut inserted: Vec<(u8, u32, u32)> = Vec::new();
        progress(done, total, json!({"bytes": 0}));
        let mut commit = |chunk: &[Tile], fetched: Vec<Option<Vec<u8>>>| -> Result<()> {
            let rows: Vec<(u8, u32, u32, Vec<u8>)> = chunk.iter().zip(fetched).map(|(t, d)| (t.1, t.2, t.3, gzip_if_mvt(d.unwrap_or_default(), gzip_mvt))).collect();
            run_bytes += rows.iter().map(|r| r.3.len() as u64).sum::<u64>();
            if let Some(m) = max_bytes {
                if run_bytes > m {
                    // undo this run: the tiles it added go, and an area it created goes with them
                    if !updating {
                        let _ = store.delete_tiles(&inserted);
                        if p.existing.is_none() {
                            let _ = store.remove_area(&p.area);
                        }
                    } else {
                        let _ = store.staging_clear();
                    }
                    store.compact();
                    return Err(Error::limit(format!("the download grew past this layer's limit of {m} bytes and was stopped")));
                }
            }
            store.put_batch(table, &rows, &ver)?;
            if !updating {
                inserted.extend(rows.iter().map(|r| (r.0, r.1, r.2)));
            }
            done += chunk.len() as u64;
            progress(done, total, json!({"bytes": run_bytes}));
            Ok(())
        };
        let outcome = if let Some(r) = &reader {
            let located = p.located.as_deref().unwrap_or(&[]);
            let need = &p.need;
            let at = |id: u64| need.binary_search_by_key(&id, |t| t.0).ok().and_then(|i| located.get(i).copied().flatten());
            self.fetch_pmtiles(r, &todo, &at, p.base.pmtiles_download_parallel().clamp(1, 64), cancelled, &mut commit)?
        } else {
            let workers = p.base.max_parallel().clamp(1, 8);
            let mut at = 0usize;
            let mut outcome = Done::Finished;
            while at < todo.len() {
                if cancelled() {
                    outcome = Done::Cancelled;
                    break;
                }
                let chunk = &todo[at..(at + 48).min(todo.len())];
                let fetched = match self.fetch_chunk(&p.dl, chunk, workers, cancelled) {
                    Ok(v) => v,
                    Err(e) if e.code == "cancelled" => {
                        outcome = Done::Cancelled;
                        break;
                    }
                    Err(e) => return Err(e),
                };
                commit(chunk, fetched)?;
                at += chunk.len();
            }
            outcome
        };
        if let Done::Cancelled = outcome {
            return Ok(Done::Cancelled);
        }
        // finished
        if updating {
            meta["version"] = json!(ver);
            meta["created"] = json!(now_secs());
            store.apply_staging(&p.area, &meta)?;
        }
        let (present, bytes) = self.cover_stats(&store, &p.cover)?;
        meta["tiles_present"] = json!(present);
        meta["bytes"] = json!(bytes);
        if meta["created"].is_null() || p.mode == "new" || p.mode == "resume" {
            meta["created"] = json!(now_secs());
        }
        store.put_area(&p.area, "complete", &meta)?;
        progress(total, total, json!({"bytes": run_bytes}));
        Ok(Done::Finished)
    }

    /// Reads `todo` from the archive and hands it to `commit` a batch at a time, in order. The merged reads of the next batches
    /// are kept in flight ([AHEAD_BATCHES], [AHEAD_BYTES]) while a batch waits for its last read, so one slow read no longer
    /// holds up the next batch: `workers` readers take the reads in order (nearest first) and the gate keeps the requests in
    /// flight to the layer's limit. `at(tile id)` is where the plan found the tile.
    fn fetch_pmtiles(&self, r: &Reader, todo: &[Tile], at: &dyn Fn(u64) -> Option<(u64, u32)>, workers: usize, cancelled: &(dyn Fn() -> bool + Sync), commit: &mut Commit<'_>) -> Result<Done> {
        if todo.is_empty() {
            return Ok(Done::Finished);
        }
        let stop = AtomicBool::new(false);
        let (work_tx, work_rx) = mpsc::channel::<(usize, usize, u64, u64)>();
        let work_rx = Mutex::new(work_rx);
        let (got_tx, got_rx) = mpsc::channel::<(usize, usize, Result<Vec<u8>>)>();
        let pol = crate::http::policy();
        std::thread::scope(|sc| {
            for _ in 0..workers {
                let (got_tx, work_rx, stop) = (got_tx.clone(), &work_rx, &stop);
                sc.spawn(move || {
                    crate::http::with_policy(pol, || loop {
                        let next = match work_rx.lock() {
                            Ok(g) => g.recv(),
                            Err(_) => break,
                        };
                        let Ok((b, g, offset, len)) = next else { break };
                        if stop.load(Ordering::SeqCst) {
                            continue;
                        }
                        let read = r.read_range(offset, len);
                        if got_tx.send((b, g, read)).is_err() {
                            break;
                        }
                    })
                });
            }
            drop(got_tx);
            Self::pipeline(todo, at, cancelled, commit, work_tx, got_rx, &stop)
        })
    }

    /// The storing side of [`Inner::fetch_pmtiles`]: queues the reads of the batches ahead, collects what arrives, and commits
    /// the oldest batch as soon as all of it is here.
    fn pipeline(
        todo: &[Tile],
        at: &dyn Fn(u64) -> Option<(u64, u32)>,
        cancelled: &(dyn Fn() -> bool + Sync),
        commit: &mut Commit<'_>,
        work: mpsc::Sender<(usize, usize, u64, u64)>,
        got: mpsc::Receiver<(usize, usize, Result<Vec<u8>>)>,
        stop: &AtomicBool,
    ) -> Result<Done> {
        let _stop = StopOnDrop(stop);
        let nbatches = todo.len().div_ceil(PMTILES_BATCH);
        let mut pending: VecDeque<InFlight> = VecDeque::new();
        let (mut queued, mut first, mut ahead) = (0usize, 0usize, 0u64);
        loop {
            if cancelled() {
                return Ok(Done::Cancelled);
            }
            while queued < nbatches && (pending.is_empty() || (pending.len() <= AHEAD_BATCHES && ahead < AHEAD_BYTES)) {
                let (start, end) = (queued * PMTILES_BATCH, ((queued + 1) * PMTILES_BATCH).min(todo.len()));
                let (mut want, mut slot) = (Vec::new(), Vec::with_capacity(end - start));
                for t in &todo[start..end] {
                    slot.push(at(t.0).map(|l| {
                        want.push(l);
                        want.len() - 1
                    }));
                }
                let groups = pmtiles::groups(&want);
                let bytes: u64 = groups.iter().map(|g| g.len).sum();
                for (gi, g) in groups.iter().enumerate() {
                    work.send((queued, gi, g.offset, g.len)).map_err(|_| Error::internal("the download's readers stopped"))?;
                }
                if !pending.is_empty() {
                    ahead += bytes;
                }
                pending.push_back(InFlight { start, end, want, slot, left: groups.len(), bufs: vec![None; groups.len()], groups, bytes });
                queued += 1;
            }
            let Some(front) = pending.front() else { return Ok(Done::Finished) };
            if front.left == 0 {
                let f = pending.pop_front().expect("a batch");
                let mut data = vec![Vec::new(); f.want.len()];
                for (g, buf) in f.groups.iter().zip(f.bufs) {
                    pmtiles::split_group(g, &buf.unwrap_or_default(), &f.want, &mut data)?;
                }
                let fetched: Vec<Option<Vec<u8>>> = f.slot.iter().map(|s| s.map(|i| std::mem::take(&mut data[i]))).collect();
                commit(&todo[f.start..f.end], fetched)?;
                first += 1;
                if let Some(nf) = pending.front() {
                    ahead -= nf.bytes;
                }
                continue;
            }
            match got.recv_timeout(Duration::from_millis(250)) {
                Ok((b, g, read)) => {
                    let p = &mut pending[b - first];
                    p.bufs[g] = Some(read?);
                    p.left -= 1;
                }
                Err(mpsc::RecvTimeoutError::Timeout) => {}
                Err(mpsc::RecvTimeoutError::Disconnected) => return Err(Error::internal("the download's readers stopped")),
            }
        }
    }

    fn fetch_chunk(&self, dl: &LayerDef, chunk: &[(u64, u8, u32, u32)], workers: usize, cancelled: &(dyn Fn() -> bool + Sync)) -> Result<Vec<Option<Vec<u8>>>> {
        let next = AtomicUsize::new(0);
        let stop = AtomicBool::new(false);
        let out: Mutex<Vec<Option<Option<Vec<u8>>>>> = Mutex::new(vec![None; chunk.len()]);
        let first_err: Mutex<Option<Error>> = Mutex::new(None);
        std::thread::scope(|sc| {
            for _ in 0..workers.min(chunk.len()) {
                sc.spawn(|| loop {
                    if stop.load(Ordering::Relaxed) || cancelled() {
                        break;
                    }
                    let i = next.fetch_add(1, Ordering::Relaxed);
                    if i >= chunk.len() {
                        break;
                    }
                    let (_, z, x, y) = chunk[i];
                    match self.fetch_source(dl, z, x, y) {
                        Ok(v) => {
                            if let Ok(mut o) = out.lock() {
                                o[i] = Some(v);
                            }
                        }
                        Err(e) => {
                            stop.store(true, Ordering::Relaxed);
                            if let Ok(mut f) = first_err.lock() {
                                f.get_or_insert(e);
                            }
                            break;
                        }
                    }
                });
            }
        });
        if let Some(e) = first_err.into_inner().ok().flatten() {
            return Err(e);
        }
        let v = out.into_inner().map_err(|_| Error::internal("poisoned"))?;
        if v.iter().any(|x| x.is_none()) {
            // cancelled part way: nothing from this batch is kept (it is fetched again on resume)
            return Err(Error::new("cancelled", "cancelled"));
        }
        Ok(v.into_iter().map(|x| x.unwrap()).collect())
    }

    /// Delete one area (only the tiles no other area covers go), or every area of the layer and all its tiles.
    pub fn delete_areas(&self, layer: &str, area: Option<&str>) -> Result<Value> {
        let base = self.base_of(layer)?;
        let store = self.store_read(&base.id);
        let Some(store) = store else {
            return match area {
                Some(a) => Err(Error::not_found(format!("no area {a:?} of layer {layer:?}"))),
                None => Ok(json!({"layer": base.id, "removed": [], "tiles_removed": 0, "tiles_kept": 0, "freed_bytes": 0})),
            };
        };
        let before = std::fs::metadata(self.store_path(&base.id)).map(|m| m.len()).unwrap_or(0);
        let (removed, tiles_removed, kept, freed) = match area {
            None => {
                let ids: Vec<String> = store.areas()?.into_iter().map(|a| a.0).collect();
                let n = store.tile_count();
                let freed = store.clear_all()?;
                (ids, n, 0u64, freed)
            }
            Some(a) => {
                let (_, meta) = store.area(a)?.ok_or_else(|| Error::not_found(format!("no area {a:?} of layer {layer:?}")))?;
                store.remove_area(a)?;
                let others: Vec<Shape> = store.areas()?.iter().filter_map(|x| Shape::from_meta(&x.2)).collect();
                // each outline made ready once, and asked tile by tile with what it found for the tiles above
                let outlines: Vec<Option<Outline>> = others.iter().map(|s| s.polygon.as_ref().map(Outline::new)).collect();
                let mut askers: Vec<_> = outlines.iter().map(|o| o.as_ref().map(|o| o.asker())).collect();
                let cover = Shape::from_meta(&meta).map(|s| s.tiles()).transpose()?.unwrap_or_default();
                let (mut gone, mut kept) = (Vec::new(), 0u64);
                for t in &cover {
                    if store.info(t.1, t.2, t.3)?.is_none() {
                        continue;
                    }
                    if others.iter().zip(askers.iter_mut()).any(|(s, a)| s.in_box(t.1, t.2, t.3) && a.as_mut().map(|a| a.touches(t.1, t.2, t.3)).unwrap_or(true)) {
                        kept += 1;
                    } else {
                        gone.push((t.1, t.2, t.3));
                    }
                }
                let freed = store.delete_tiles(&gone)?;
                (vec![a.to_string()], gone.len() as u64, kept, freed)
            }
        };
        store.compact();
        let after = std::fs::metadata(self.store_path(&base.id)).map(|m| m.len()).unwrap_or(0);
        Ok(json!({"layer": base.id, "removed": removed, "tiles_removed": tiles_removed, "tiles_kept": kept, "freed_bytes": freed, "file_bytes_before": before, "file_bytes_after": after}))
    }
}

#[cfg(test)]
mod near_tests {
    use super::*;

    #[test]
    fn a_pmtiles_download_goes_block_by_block_from_near_outwards_in_tile_id_order() {
        let req: AreaReq = serde_json::from_str(r#"{"layer":"x","bbox":[-115.5,42.0,-113.0,44.0],"minzoom":8,"maxzoom":13,"near":[42.56,-114.46]}"#).unwrap();
        let mut tiles = req.tiles(8, 13).unwrap();
        let mut sorted = tiles.clone();
        sorted.sort();
        order_blocks_from(&mut tiles, req.near);
        let mut again = tiles.clone();
        again.sort();
        assert_eq!(again, sorted, "the same tiles, only reordered");
        // the zooms up to the block zoom come first
        let first_deep = tiles.iter().position(|t| t.1 > BLOCK_ZOOM).unwrap();
        assert!(tiles[..first_deep].iter().all(|t| t.1 <= BLOCK_ZOOM));
        assert!(tiles[first_deep..].iter().all(|t| t.1 > BLOCK_ZOOM));
        // the first block holds the near point, and each block's tiles are together, in tile id order
        let block = |t: &(u64, u8, u32, u32)| (t.2 >> (t.1 - BLOCK_ZOOM), t.3 >> (t.1 - BLOCK_ZOOM));
        let deep = &tiles[first_deep..];
        assert_eq!(block(&deep[0]), (lon_to_x(-114.46, BLOCK_ZOOM).floor() as u32, lat_to_y(42.56, BLOCK_ZOOM).floor() as u32));
        let mut seen = std::collections::HashSet::new();
        for w in deep.windows(2) {
            if block(&w[0]) == block(&w[1]) {
                assert!(w[0].0 < w[1].0, "tile id order inside a block");
            } else {
                assert!(seen.insert(block(&w[0])), "a block's tiles are never split");
            }
        }
        // a 1024-tile batch of the old order spread across the archive; one of the new order covers few blocks
        let blocks_in_first_batch: std::collections::HashSet<_> = deep.iter().take(PMTILES_BATCH).map(block).collect();
        let mut old = sorted.clone();
        order_from(&mut old, req.near.unwrap());
        let old_blocks: std::collections::HashSet<_> = old.iter().filter(|t| t.1 > BLOCK_ZOOM).take(PMTILES_BATCH).map(block).collect();
        // z11 to z13 is 84 tiles a block: a batch spans about 13 blocks, where the old order's spanned every block in reach
        assert!(blocks_in_first_batch.len() <= PMTILES_BATCH / 84 + 1, "{} blocks", blocks_in_first_batch.len());
        assert!(blocks_in_first_batch.len() * 4 < old_blocks.len(), "new {} blocks, old {}", blocks_in_first_batch.len(), old_blocks.len());
        // with no near point the order is still block by block
        let mut plain = req.tiles(8, 13).unwrap();
        order_blocks_from(&mut plain, None);
        assert_eq!(plain.len(), sorted.len());
    }

    #[test]
    fn a_download_keeps_more_range_requests_in_flight_unless_the_definition_says_fewer() {
        let mut d: LayerDef = serde_json::from_value(serde_json::json!({"format":1,"id":"b","title":"B","kind":"vector","transform":"as_is","source":{"type":"pmtiles","url":"https://example.org/a.pmtiles"},"offline":{"allowed":true}})).unwrap();
        assert_eq!(d.pmtiles_download_parallel(), crate::def::PMTILES_DOWNLOAD_PARALLEL);
        assert_eq!(d.max_parallel(), 4, "the map's own fetches keep their limit");
        d.offline.as_mut().unwrap().max_parallel = Some(4);
        assert_eq!(d.pmtiles_download_parallel(), 4);
    }

    #[test]
    fn tiles_come_by_zoom_then_from_near_outwards() {
        let req: AreaReq = serde_json::from_str(r#"{"layer":"x","bbox":[-114.62,42.49,-113.93,42.85],"minzoom":10,"maxzoom":12,"near":[42.75,-113.95]}"#).unwrap();
        let mut tiles = req.tiles(10, 12).unwrap();
        let before = tiles.len();
        order_from(&mut tiles, req.near.unwrap());
        assert_eq!(tiles.len(), before);
        // coarsest zoom first
        assert!(tiles.windows(2).all(|w| w[0].1 <= w[1].1));
        // within a zoom, the first tile holds the near point and distances never shrink
        let z12: Vec<_> = tiles.iter().filter(|t| t.1 == 12).collect();
        let (nx, ny) = (lon_to_x(-113.95, 12).floor() as u32, lat_to_y(42.75, 12).floor() as u32);
        assert_eq!((z12[0].2, z12[0].3), (nx, ny));
        let d = |t: &(u64, u8, u32, u32)| (t.2 as f64 + 0.5 - lon_to_x(-113.95, 12)).powi(2) + (t.3 as f64 + 0.5 - lat_to_y(42.75, 12)).powi(2);
        assert!(z12.windows(2).all(|w| d(w[0]) <= d(w[1])));
        // "near" is not part of the shape: a request without it covers the same tiles
        let plain: AreaReq = serde_json::from_str(r#"{"layer":"x","bbox":[-114.62,42.49,-113.93,42.85]}"#).unwrap();
        assert_eq!(plain.near, None);
        assert_eq!(plain.tiles(10, 12).unwrap().len(), before);
    }
}
