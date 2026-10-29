//! Area downloads into the layer's merged tile store (see store.rs): plan (dry run), download, resume, update, delete.
//!
//! Areas overlap, so a tile is stored once. A download fetches only the tiles of its area that are not already on the
//! device; a delete removes only the tiles no other area covers. The tiles an area needs are computed from its shape
//! (polygon or box, zoom range), never stored per area. An unfinished download is an area in state "partial": the
//! tiles already stored stay, and starting the same request again fetches the rest. An update fetches the tiles whose
//! version is older than the layer's into a staging table and swaps them in, with the area's new version, in one
//! transaction when all are there.

use crate::core::{now_secs, tile_bbox, Inner};
use crate::def::{LayerDef, Source, Transform};
use crate::error::{available_bytes, Error, Result};
use crate::pmtiles::{self, zxy_to_id};
use crate::store::{Store, Table};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::Mutex;

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
    #[serde(default)]
    pub polygon: Option<Vec<[f64; 2]>>,
    #[serde(default)]
    pub minzoom: Option<u8>,
    #[serde(default)]
    pub maxzoom: Option<u8>,
    /// Re-download an existing area (same shape and zooms) at the layer's newest version.
    #[serde(default)]
    pub update: bool,
}

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

fn point_in_poly(p: [f64; 2], poly: &[[f64; 2]]) -> bool {
    let mut inside = false;
    let mut j = poly.len() - 1;
    for i in 0..poly.len() {
        let (a, b) = (poly[i], poly[j]);
        if (a[1] > p[1]) != (b[1] > p[1]) && p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0] {
            inside = !inside;
        }
        j = i;
    }
    inside
}

fn seg_hits(a: [f64; 2], b: [f64; 2], c: [f64; 2], d: [f64; 2]) -> bool {
    let cross = |o: [f64; 2], p: [f64; 2], q: [f64; 2]| (p[0] - o[0]) * (q[1] - o[1]) - (p[1] - o[1]) * (q[0] - o[0]);
    let (d1, d2, d3, d4) = (cross(c, d, a), cross(c, d, b), cross(a, b, c), cross(a, b, d));
    ((d1 > 0.0) != (d2 > 0.0)) && ((d3 > 0.0) != (d4 > 0.0))
}

fn poly_hits_rect(poly: &[[f64; 2]], r: [f64; 4]) -> bool {
    let corners = [[r[0], r[1]], [r[2], r[1]], [r[2], r[3]], [r[0], r[3]]];
    if poly.iter().any(|p| p[0] >= r[0] && p[0] <= r[2] && p[1] >= r[1] && p[1] <= r[3]) {
        return true;
    }
    if corners.iter().any(|c| point_in_poly(*c, poly)) {
        return true;
    }
    for i in 0..poly.len() {
        let (a, b) = (poly[i], poly[(i + 1) % poly.len()]);
        for k in 0..4 {
            if seg_hits(a, b, corners[k], corners[(k + 1) % 4]) {
                return true;
            }
        }
    }
    false
}

impl AreaReq {
    pub fn parse(json: &str) -> Result<AreaReq> {
        serde_json::from_str(json).map_err(|e| Error::bad_json(format!("download request: {e}")))
    }

    /// The bounding box of the request (of the polygon when given).
    pub fn bounds(&self) -> Result<[f64; 4]> {
        let b = match (&self.polygon, &self.bbox) {
            (Some(p), _) => {
                if p.len() < 3 {
                    return Err(Error::bad_json("a polygon needs at least 3 points [lon, lat]"));
                }
                let (mut w, mut s, mut e, mut n) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
                for q in p {
                    w = w.min(q[0]);
                    e = e.max(q[0]);
                    s = s.min(q[1]);
                    n = n.max(q[1]);
                }
                [w, s, e, n]
            }
            (None, Some(b)) => *b,
            _ => return Err(Error::bad_json("a download needs \"bbox\" [west, south, east, north] or \"polygon\" [[lon, lat], ...]")),
        };
        if !(b.iter().all(|v| v.is_finite()) && b[0] >= -180.0 && b[2] <= 180.0 && b[1] >= -90.0 && b[3] <= 90.0 && b[0] < b[2] && b[1] < b[3]) {
            return Err(Error::bad_json("the area is not valid: [west, south, east, north] in degrees, west < east, south < north"));
        }
        Ok(b)
    }

    /// Every tile of the area in the zoom range, in PMTiles tile id order.
    pub fn tiles(&self, zmin: u8, zmax: u8) -> Result<Vec<(u64, u8, u32, u32)>> {
        let b = self.bounds()?;
        let mut out: Vec<(u64, u8, u32, u32)> = Vec::new();
        for z in zmin..=zmax {
            let (x0, x1, y0, y1) = tile_range(b, z);
            if (x1 - x0 + 1).saturating_mul(y1 - y0 + 1).saturating_add(out.len() as u64) > MAX_ENUMERATED {
                return Err(Error::limit("that area at those zooms has far too many tiles to list; choose a smaller area or fewer zooms"));
            }
            for x in x0..=x1 {
                for y in y0..=y1 {
                    if let Some(p) = &self.polygon {
                        if !poly_hits_rect(p, tile_bbox(z, x as u32, y as u32)) {
                            continue;
                        }
                    }
                    out.push((zxy_to_id(z, x as u32, y as u32), z, x as u32, y as u32));
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
        if let Some(p) = &self.polygon {
            for q in p {
                h.update(format!("{:.4},{:.4};", q[0], q[1]));
            }
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
    pub polygon: Option<Vec<[f64; 2]>>,
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

    pub fn covers(&self, z: u8, x: u32, y: u32) -> bool {
        if z < self.minzoom || z > self.maxzoom {
            return false;
        }
        let (x0, x1, y0, y1) = tile_range(self.bbox, z);
        let (x, y) = (x as u64, y as u64);
        if x < x0 || x > x1 || y < y0 || y > y1 {
            return false;
        }
        match &self.polygon {
            Some(p) => poly_hits_rect(p, tile_bbox(z, x as u32, y as u32)),
            None => true,
        }
    }

    pub fn tiles(&self) -> Result<Vec<(u64, u8, u32, u32)>> {
        AreaReq { layer: String::new(), name: None, area: None, bbox: Some(self.bbox), polygon: self.polygon.clone(), minzoom: None, maxzoom: None, update: false }.tiles(self.minzoom, self.maxzoom)
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
    mode: &'static str,
    existing: Option<(String, Value)>,
}

impl Inner {
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
        let mut need = Vec::new();
        for t in &cover {
            let have = match &store {
                Some(s) => s.info(t.1, t.2, t.3)?,
                None => None,
            };
            let wanted = match (&have, mode) {
                (None, _) => true,
                (Some((_, v)), "update") => *v != newest,
                _ => false,
            };
            if wanted {
                need.push(*t);
            }
        }
        Ok(Prepared { req, base, dl, src, zmin, zmax, area, cover, need, mode, existing })
    }

    /// The dry run: how many tiles the area covers, how many of them are not on the device yet, and what fetching
    /// those would cost; whether it fits the layer's limits and the free space.
    pub fn plan(&self, req: &AreaReq) -> Result<Value> {
        self.plan_inner(req).map(|(v, _)| v)
    }

    fn plan_inner(&self, req: &AreaReq) -> Result<(Value, Prepared)> {
        let p = self.prepare(req)?;
        let store = self.store_read(&p.base.id);
        let mut per_zoom: BTreeMap<u8, u64> = BTreeMap::new();
        for t in &p.cover {
            *per_zoom.entry(t.1).or_default() += 1;
        }
        let (mut already, mut already_bytes) = (0u64, 0u64);
        if let Some(s) = &store {
            let needset: std::collections::HashSet<u64> = p.need.iter().map(|t| t.0).collect();
            for t in &p.cover {
                if !needset.contains(&t.0) {
                    if let Some((n, _)) = s.info(t.1, t.2, t.3)? {
                        already += 1;
                        already_bytes += n;
                    }
                }
            }
        }
        let n = p.need.len() as u64;
        let (est, method, present) = if p.need.is_empty() {
            (0, "none".to_string(), Some(0))
        } else if !self.is_online() {
            return Err(Error::offline("the size of a download is read from the source, which needs a connection"));
        } else if p.src.kind == "pmtiles" {
            let r = self.remote_pmtiles(&p.dl, &p.src.url)?;
            let (mut bytes, mut have) = (0u64, 0u64);
            for t in &p.need {
                if let Some((_, l)) = r.lookup(t.0)? {
                    bytes += l as u64;
                    have += 1;
                }
            }
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
            if with > 0 {
                mean.insert(*z, bytes / with);
            }
            all_bytes += bytes;
            all_with += with;
        }
        let overall = if all_with > 0 { all_bytes / all_with } else { 0 };
        let est = by_zoom.iter().map(|(z, tiles)| tiles.len() as u64 * mean.get(z).copied().unwrap_or(overall)).sum();
        Ok((est, fetched))
    }

    /// Statistics of what an area covers once downloaded: tiles with data and their bytes (shared tiles included).
    fn cover_stats(&self, store: &Store, cover: &[(u64, u8, u32, u32)]) -> Result<(u64, u64)> {
        let (mut present, mut bytes) = (0u64, 0u64);
        for t in cover {
            if let Some((n, _)) = store.info(t.1, t.2, t.3)? {
                if n > 0 {
                    present += 1;
                    bytes += n;
                }
            }
        }
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
        let reader = if p.src.kind == "pmtiles" { Some(self.remote_pmtiles(&p.dl, &p.src.url)?) } else { None };
        let table = if updating { Table::Staging } else { Table::Tiles };
        if updating {
            store.staging_keep_only(&ver)?;
        }
        // staged tiles of this version from an interrupted update are kept
        let todo: Vec<(u64, u8, u32, u32)> = if updating { p.need.iter().filter(|t| !store.staging_has(t.1, t.2, t.3, &ver).unwrap_or(false)).copied().collect() } else { p.need.clone() };
        let skipped = total - todo.len() as u64;
        let batch = if reader.is_some() { 256 } else { 48 };
        let workers = p.base.max_parallel().clamp(1, 8);
        let (mut done, mut run_bytes) = (skipped, 0u64);
        let mut inserted: Vec<(u8, u32, u32)> = Vec::new();
        progress(done, total, json!({"bytes": 0}));
        let mut at = 0usize;
        while at < todo.len() {
            if cancelled() {
                return Ok(Done::Cancelled);
            }
            let chunk = &todo[at..(at + batch).min(todo.len())];
            let fetched: Vec<Option<Vec<u8>>> = if let Some(r) = &reader {
                let found: Vec<Option<(u64, u32)>> = chunk.iter().map(|t| r.lookup(t.0)).collect::<Result<_>>()?;
                let want: Vec<(u64, u32)> = found.iter().flatten().copied().collect();
                let mut got = r.read_ranges(&want)?.into_iter();
                found.iter().map(|f| f.map(|_| got.next().unwrap_or_default())).collect()
            } else {
                match self.fetch_chunk(&p.dl, chunk, workers, cancelled) {
                    Ok(v) => v,
                    Err(e) if e.code == "cancelled" => return Ok(Done::Cancelled),
                    Err(e) => return Err(e),
                }
            };
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
            at += chunk.len();
            done += chunk.len() as u64;
            progress(done, total, json!({"bytes": run_bytes}));
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
                let cover = Shape::from_meta(&meta).map(|s| s.tiles()).transpose()?.unwrap_or_default();
                let (mut gone, mut kept) = (Vec::new(), 0u64);
                for t in &cover {
                    if store.info(t.1, t.2, t.3)?.is_none() {
                        continue;
                    }
                    if others.iter().any(|s| s.covers(t.1, t.2, t.3)) {
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
