//! Contour lines from Terrarium elevation tiles, as MVT.
//!
//! The approach is a port of maplibre-contour (https://github.com/onthegomap/maplibre-contour, BSD-3-Clause,
//! Copyright (c) 2023 Michael Barry and contributors), whose marching squares is adapted from d3-contour (ISC,
//! Copyright 2012-2023 Mike Bostock). Same steps: the tile plus its eight neighbours (so lines join across edges),
//! overzoom by splitting the parent tile above the DEM's maximum zoom, bilinear subsampling of small tiles, pixel
//! centres averaged onto the grid corners, one marching-squares pass for every threshold with fragments joined as
//! they close, and a 1-pixel buffer. Additions here: Douglas-Peucker simplification of every line, and the
//! feet-per-zoom interval table of Cache.

use crate::error::{Error, Result};
use std::collections::{BTreeMap, HashMap, VecDeque};
use std::io::Cursor;
use std::sync::Arc;

pub const FEET_PER_METER: f64 = 3.28084;
pub const EXTENT: i32 = 4096;
/// Douglas-Peucker tolerance in tile units (of 4096): a quarter of a 512-pixel DEM pixel.
pub const SIMPLIFY_TOLERANCE: f64 = 2.0;
const SUBSAMPLE_BELOW: usize = 100;
const MIN_VALID_M: f32 = -12000.0;
const MAX_VALID_M: f32 = 9000.0;

/// (minor, index) contour interval in feet for a zoom; `None` below the first zoom that has contours.
pub fn intervals(z: u8) -> Option<(i64, i64)> {
    Some(match z {
        0..=2 => return None,
        3 => (5000, 25000),
        4 => (2500, 10000),
        5 | 6 => (1000, 5000),
        7 | 8 => (500, 2500),
        9 => (250, 1000),
        10 | 11 => (200, 1000),
        12 | 13 => (100, 500),
        14 => (50, 200),
        _ => (20, 100),
    })
}

/// Elevations in metres, row-major; NaN where there is no valid value.
pub struct Grid {
    pub w: usize,
    pub h: usize,
    pub d: Vec<f32>,
}

impl Grid {
    pub fn get(&self, x: i64, y: i64) -> f32 {
        if x < 0 || y < 0 || x >= self.w as i64 || y >= self.h as i64 {
            f32::NAN
        } else {
            self.d[y as usize * self.w + x as usize]
        }
    }

    /// The `subx,suby` cell of a `(1<<subz)` square split of this grid.
    pub fn split(&self, subz: u32, subx: usize, suby: usize) -> Grid {
        if subz == 0 {
            return Grid { w: self.w, h: self.h, d: self.d.clone() };
        }
        let by = 1usize << subz;
        let (w, h) = (self.w / by, self.h / by);
        let (dx, dy) = (subx * self.w / by, suby * self.h / by);
        let mut d = Vec::with_capacity(w * h);
        for y in 0..h {
            for x in 0..w {
                d.push(self.get((x + dx) as i64, (y + dy) as i64));
            }
        }
        Grid { w, h, d }
    }
}

/// Decode a Terrarium PNG or WebP tile: metres = (R * 256 + G + B / 256) - 32768.
pub fn decode_terrarium(bytes: &[u8]) -> Result<Grid> {
    let (w, h, ch, px) = if bytes.len() > 12 && &bytes[0..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        let mut dec = image_webp::WebPDecoder::new(Cursor::new(bytes)).map_err(|e| Error::bad_response(format!("webp: {e}")))?;
        let (w, h) = dec.dimensions();
        let ch = if dec.has_alpha() { 4 } else { 3 };
        let mut buf = vec![0u8; dec.output_buffer_size().ok_or_else(|| Error::bad_response("webp: too large"))?];
        dec.read_image(&mut buf).map_err(|e| Error::bad_response(format!("webp: {e}")))?;
        (w as usize, h as usize, ch, buf)
    } else if bytes.len() > 8 && &bytes[1..4] == b"PNG" {
        let mut dec = png::Decoder::new(Cursor::new(bytes));
        dec.set_transformations(png::Transformations::EXPAND);
        let mut r = dec.read_info().map_err(|e| Error::bad_response(format!("png: {e}")))?;
        let mut buf = vec![0u8; r.output_buffer_size()];
        let info = r.next_frame(&mut buf).map_err(|e| Error::bad_response(format!("png: {e}")))?;
        let ch = match info.color_type {
            png::ColorType::Rgb => 3,
            png::ColorType::Rgba => 4,
            c => return Err(Error::bad_response(format!("a Terrarium tile must be RGB, not {c:?}"))),
        };
        if info.bit_depth != png::BitDepth::Eight {
            return Err(Error::bad_response("a Terrarium tile must be 8 bits per channel"));
        }
        (info.width as usize, info.height as usize, ch, buf)
    } else {
        return Err(Error::bad_response("an elevation tile is not PNG or WebP"));
    };
    let mut d = Vec::with_capacity(w * h);
    for i in 0..w * h {
        let (r, g, b) = (px[i * ch] as f32, px[i * ch + 1] as f32, px[i * ch + 2] as f32);
        let v = r * 256.0 + g + b / 256.0 - 32768.0;
        d.push(if (MIN_VALID_M..=MAX_VALID_M).contains(&v) { v } else { f32::NAN });
    }
    Ok(Grid { w, h, d })
}

/// A materialised grid with `buf` extra pixels around it that can be read.
struct View {
    w: usize,
    h: usize,
    buf: usize,
    d: Vec<f32>,
}

impl View {
    fn build(w: usize, h: usize, buf: usize, f: &dyn Fn(i64, i64) -> f32) -> View {
        let stride = w + 2 * buf;
        let mut d = Vec::with_capacity(stride * (h + 2 * buf));
        for y in -(buf as i64)..(h + buf) as i64 {
            for x in -(buf as i64)..(w + buf) as i64 {
                d.push(f(x, y));
            }
        }
        View { w, h, buf, d }
    }
    fn get(&self, x: i64, y: i64) -> f32 {
        let b = self.buf as i64;
        if x < -b || y < -b || x >= self.w as i64 + b || y >= self.h as i64 + b {
            return f32::NAN;
        }
        self.d[((y + b) as usize) * (self.w + 2 * self.buf) + (x + b) as usize]
    }
}

fn lerp(a: f32, b: f32, f: f32) -> f32 {
    if a.is_nan() {
        b
    } else if b.is_nan() {
        a
    } else {
        a + (b - a) * f
    }
}

/// Bilinear upscale by `factor`; values are taken at pixel centres.
fn subsample(src: &dyn Fn(i64, i64) -> f32, w: usize, h: usize, factor: usize) -> View {
    let sub = 0.5 - 1.0 / (2.0 * factor as f32);
    let f = move |x: i64, y: i64| -> f32 {
        let dx = x as f32 / factor as f32 - sub;
        let dy = y as f32 / factor as f32 - sub;
        let (ox, oy) = (dx.floor(), dy.floor());
        let (a, b) = (src(ox as i64, oy as i64), src(ox as i64 + 1, oy as i64));
        let (c, d) = (src(ox as i64, oy as i64 + 1), src(ox as i64 + 1, oy as i64 + 1));
        let (fx, fy) = (dx - ox, dy - oy);
        lerp(lerp(a, b, fx), lerp(c, d, fx), fy)
    };
    View::build(w * factor, h * factor, 2, &f)
}

type Line = Vec<(i32, i32)>;

struct Frag {
    start: i64,
    end: i64,
    pts: VecDeque<(i32, i32)>,
}

fn js_round(v: f64) -> i32 {
    (v + 0.5).floor() as i32
}

const CASES: [&[[(i32, i32); 2]]; 16] = [
    &[],
    &[[(1, 2), (0, 1)]],
    &[[(2, 1), (1, 2)]],
    &[[(2, 1), (0, 1)]],
    &[[(1, 0), (2, 1)]],
    &[[(1, 2), (0, 1)], [(1, 0), (2, 1)]],
    &[[(1, 0), (1, 2)]],
    &[[(1, 0), (0, 1)]],
    &[[(0, 1), (1, 0)]],
    &[[(1, 2), (1, 0)]],
    &[[(0, 1), (1, 0)], [(2, 1), (1, 2)]],
    &[[(2, 1), (1, 0)]],
    &[[(0, 1), (2, 1)]],
    &[[(1, 2), (2, 1)]],
    &[[(0, 1), (1, 2)]],
    &[],
];

/// Marching squares over every threshold (a multiple of `interval`) at once. Returns lines by threshold index `k`
/// (elevation = k * interval), in tile coordinates of `extent`.
fn isolines(interval: f64, t: &View, extent: i32, buffer: i64) -> BTreeMap<i64, Vec<Line>> {
    let mut out: BTreeMap<i64, Vec<Line>> = BTreeMap::new();
    let mult = extent as f64 / (t.w as f64 - 1.0);
    let width = t.w as i64;
    let mut frags: Vec<Frag> = Vec::new();
    let mut by_start: HashMap<i64, HashMap<i64, usize>> = HashMap::new();
    let mut by_end: HashMap<i64, HashMap<i64, usize>> = HashMap::new();
    let ratio = |a: f64, b: f64, c: f64| (b - a) / (c - a);
    let index = |x: i64, y: i64, p: (i32, i32)| -> i64 { (x * 2 + p.0 as i64) + (y * 2 + p.1 as i64) * (width + 1) * 2 };

    for r in (1 - buffer)..(t.h as i64 + buffer) {
        // one column left of the first cell, so the buffer reaches into the western neighbour too
        // (maplibre-contour starts at column 0 here, which makes its first cell degenerate)
        let mut trd = t.get(-buffer, r - 1) as f64;
        let mut brd = t.get(-buffer, r) as f64;
        let (mut min_r, mut max_r) = (trd.min(brd), trd.max(brd));
        for c in (1 - buffer)..(t.w as i64 + buffer) {
            let (tld, bld) = (trd, brd);
            trd = t.get(c, r - 1) as f64;
            brd = t.get(c, r) as f64;
            let (min_l, max_l) = (min_r, max_r);
            min_r = trd.min(brd);
            max_r = trd.max(brd);
            if tld.is_nan() || trd.is_nan() || brd.is_nan() || bld.is_nan() {
                continue;
            }
            let (min, max) = (min_l.min(min_r), max_l.max(max_r));
            let k0 = (min / interval).ceil() as i64;
            let k1 = (max / interval).floor() as i64;
            for k in k0..=k1 {
                let th = k as f64 * interval;
                let case = (if tld > th { 8 } else { 0 }) | (if trd > th { 4 } else { 0 }) | (if brd > th { 2 } else { 0 }) | (if bld > th { 1 } else { 0 });
                for seg in CASES[case] {
                    let (s, e) = (seg[0], seg[1]);
                    let interp = |p: (i32, i32)| -> (i32, i32) {
                        let (x, y) = if p.0 == 0 {
                            (mult * (c - 1) as f64, mult * (r as f64 - ratio(bld, th, tld)))
                        } else if p.0 == 2 {
                            (mult * c as f64, mult * (r as f64 - ratio(brd, th, trd)))
                        } else if p.1 == 0 {
                            (mult * (c as f64 - ratio(trd, th, tld)), mult * (r - 1) as f64)
                        } else {
                            (mult * (c as f64 - ratio(brd, th, bld)), mult * r as f64)
                        };
                        (js_round(x), js_round(y))
                    };
                    let (si, ei) = (index(c, r, s), index(c, r, e));
                    let bs = by_start.entry(k).or_default();
                    let be = by_end.entry(k).or_default();
                    if let Some(&f) = be.get(&si) {
                        be.remove(&si);
                        if let Some(&g) = bs.get(&ei) {
                            bs.remove(&ei);
                            if f == g {
                                // closing a ring
                                frags[f].pts.push_back(interp(e));
                                if !frags[f].pts.is_empty() {
                                    out.entry(k).or_default().push(frags[f].pts.iter().copied().collect());
                                }
                            } else {
                                // connecting two fragments
                                let gp = std::mem::take(&mut frags[g].pts);
                                let gend = frags[g].end;
                                frags[f].pts.extend(gp);
                                frags[f].end = gend;
                                be.insert(gend, f);
                            }
                        } else {
                            frags[f].pts.push_back(interp(e));
                            frags[f].end = ei;
                            be.insert(ei, f);
                        }
                    } else if let Some(&f) = bs.get(&ei) {
                        bs.remove(&ei);
                        frags[f].pts.push_front(interp(s));
                        frags[f].start = si;
                        bs.insert(si, f);
                    } else {
                        let mut pts = VecDeque::new();
                        pts.push_back(interp(s));
                        pts.push_back(interp(e));
                        frags.push(Frag { start: si, end: ei, pts });
                        let id = frags.len() - 1;
                        bs.insert(si, id);
                        be.insert(ei, id);
                    }
                }
            }
        }
    }
    for (k, m) in by_start {
        let mut ids: Vec<usize> = m.values().copied().collect();
        ids.sort_unstable();
        for id in ids {
            if frags[id].pts.len() >= 2 {
                out.entry(k).or_default().push(frags[id].pts.iter().copied().collect());
            }
        }
    }
    out
}

fn perp(p: (i32, i32), a: (i32, i32), b: (i32, i32)) -> f64 {
    let (dx, dy) = ((b.0 - a.0) as f64, (b.1 - a.1) as f64);
    let len2 = dx * dx + dy * dy;
    let (px, py) = ((p.0 - a.0) as f64, (p.1 - a.1) as f64);
    if len2 == 0.0 {
        return (px * px + py * py).sqrt();
    }
    let t = ((px * dx + py * dy) / len2).clamp(0.0, 1.0);
    let (cx, cy) = (dx * t - px, dy * t - py);
    (cx * cx + cy * cy).sqrt()
}

fn dp(pts: &[(i32, i32)], tol: f64, keep: &mut Vec<bool>, lo: usize, hi: usize) {
    let mut stack = vec![(lo, hi)];
    while let Some((lo, hi)) = stack.pop() {
        if hi <= lo + 1 {
            continue;
        }
        let (mut best, mut at) = (0.0, lo);
        for i in lo + 1..hi {
            let d = perp(pts[i], pts[lo], pts[hi]);
            if d > best {
                best = d;
                at = i;
            }
        }
        if best > tol {
            keep[at] = true;
            stack.push((lo, at));
            stack.push((at, hi));
        }
    }
}

/// Douglas-Peucker. A closed ring is split at its point farthest from the start so it keeps its shape.
pub fn simplify(line: &[(i32, i32)], tol: f64) -> Line {
    if line.len() < 3 {
        return line.to_vec();
    }
    let mut keep = vec![false; line.len()];
    keep[0] = true;
    keep[line.len() - 1] = true;
    if line[0] == line[line.len() - 1] && line.len() > 3 {
        let far = (1..line.len() - 1).max_by_key(|&i| {
            let (dx, dy) = ((line[i].0 - line[0].0) as i64, (line[i].1 - line[0].1) as i64);
            dx * dx + dy * dy
        });
        if let Some(m) = far {
            keep[m] = true;
            dp(line, tol, &mut keep, 0, m);
            dp(line, tol, &mut keep, m, line.len() - 1);
        }
    } else {
        dp(line, tol, &mut keep, 0, line.len() - 1);
    }
    let out: Line = line.iter().zip(keep).filter(|(_, k)| *k).map(|(p, _)| *p).collect();
    out
}

// ---- MVT encoding ----

fn varint(out: &mut Vec<u8>, mut v: u64) {
    while v >= 0x80 {
        out.push((v as u8 & 0x7f) | 0x80);
        v >>= 7;
    }
    out.push(v as u8);
}

fn zigzag(v: i64) -> u64 {
    ((v << 1) ^ (v >> 63)) as u64
}

fn field_bytes(out: &mut Vec<u8>, field: u32, data: &[u8]) {
    varint(out, ((field << 3) | 2) as u64);
    varint(out, data.len() as u64);
    out.extend_from_slice(data);
}

fn field_varint(out: &mut Vec<u8>, field: u32, v: u64) {
    varint(out, (field << 3) as u64);
    varint(out, v);
}

/// One MVT layer `contours` with a feature per elevation: properties `ele` (feet) and `level` (0 minor, 1 index).
pub fn encode_mvt(features: &BTreeMap<i64, Vec<Line>>, index_every: i64) -> Vec<u8> {
    let mut vals: Vec<i64> = Vec::new();
    let mut val_idx: HashMap<i64, u32> = HashMap::new();
    let mut feats: Vec<Vec<u8>> = Vec::new();
    for (&ele, lines) in features {
        let level = i64::from(index_every > 0 && ele % index_every == 0);
        let mut tags = Vec::new();
        for (key, v) in [(0u64, ele), (1u64, level)] {
            let vi = *val_idx.entry(v).or_insert_with(|| {
                vals.push(v);
                vals.len() as u32 - 1
            });
            varint(&mut tags, key);
            varint(&mut tags, vi as u64);
        }
        let mut geom = Vec::new();
        let (mut cx, mut cy) = (0i64, 0i64);
        for line in lines.iter().filter(|l| l.len() >= 2) {
            varint(&mut geom, 1 | (1 << 3));
            varint(&mut geom, zigzag(line[0].0 as i64 - cx));
            varint(&mut geom, zigzag(line[0].1 as i64 - cy));
            (cx, cy) = (line[0].0 as i64, line[0].1 as i64);
            varint(&mut geom, 2 | (((line.len() - 1) as u64) << 3));
            for p in &line[1..] {
                varint(&mut geom, zigzag(p.0 as i64 - cx));
                varint(&mut geom, zigzag(p.1 as i64 - cy));
                (cx, cy) = (p.0 as i64, p.1 as i64);
            }
        }
        if geom.is_empty() {
            continue;
        }
        let mut f = Vec::new();
        field_bytes(&mut f, 2, &tags);
        field_varint(&mut f, 3, 2);
        field_bytes(&mut f, 4, &geom);
        feats.push(f);
    }
    let mut layer = Vec::new();
    field_varint(&mut layer, 15, 2);
    field_bytes(&mut layer, 1, b"contours");
    for f in &feats {
        field_bytes(&mut layer, 2, f);
    }
    field_bytes(&mut layer, 3, b"ele");
    field_bytes(&mut layer, 3, b"level");
    for v in &vals {
        let mut b = Vec::new();
        field_varint(&mut b, 6, zigzag(*v));
        field_bytes(&mut layer, 4, &b);
    }
    field_varint(&mut layer, 5, EXTENT as u64);
    let mut tile = Vec::new();
    field_bytes(&mut tile, 3, &layer);
    tile
}

/// Fetches the decoded DEM tile `z/x/y` (z at most the DEM's maximum zoom); `None` where the DEM has no tile.
pub type DemFetch<'a> = &'a dyn Fn(u8, u32, u32) -> Result<Option<Arc<Grid>>>;

fn dem_at(z: u8, x: u32, y: u32, max_z: u8, fetch: DemFetch) -> Result<Option<Grid>> {
    if z <= max_z {
        return Ok(fetch(z, x, y)?.map(|g| Grid { w: g.w, h: g.h, d: g.d.clone() }));
    }
    let subz = (z - max_z) as u32;
    if subz > 4 {
        return Err(Error::bad_json("contours are not made above 4 zooms past the elevation's maximum zoom"));
    }
    let by = 1u32 << subz;
    Ok(fetch(max_z, x / by, y / by)?.map(|g| g.split(subz, (x % by) as usize, (y % by) as usize)))
}

/// The contour tile at `z/x/y` as MVT bytes, or `None` when the DEM has no tile there (or the zoom has no contours).
pub fn contour_tile(z: u8, x: u32, y: u32, dem_max_zoom: u8, fetch: DemFetch) -> Result<Option<Vec<u8>>> {
    let Some((minor, index)) = intervals(z) else { return Ok(None) };
    let max = 1i64 << z;
    let mut nb: Vec<Option<Grid>> = Vec::with_capacity(9);
    for iy in y as i64 - 1..=y as i64 + 1 {
        for ix in x as i64 - 1..=x as i64 + 1 {
            if iy < 0 || iy >= max {
                nb.push(None);
            } else {
                nb.push(dem_at(z, ((ix + max) % max) as u32, iy as u32, dem_max_zoom, fetch)?);
            }
        }
    }
    let Some(main) = &nb[4] else { return Ok(None) };
    let (w, h) = (main.w, main.h);
    let combined = |x: i64, y: i64| -> f32 {
        let (mut gi, mut x, mut y) = (0usize, x, y);
        if y < 0 {
            y += h as i64;
        } else if y < h as i64 {
            gi += 3;
        } else {
            y -= h as i64;
            gi += 6;
        }
        if x < 0 {
            x += w as i64;
        } else if x < w as i64 {
            gi += 1;
        } else {
            x -= w as i64;
            gi += 2;
        }
        match &nb[gi] {
            Some(g) => g.get(x, y),
            None => f32::NAN,
        }
    };
    let mut v = if w >= SUBSAMPLE_BELOW {
        View::build(w, h, 2, &combined)
    } else {
        let mut cur = subsample(&combined, w, h, 2);
        while cur.w < SUBSAMPLE_BELOW {
            let prev = cur;
            cur = subsample(&|x, y| prev.get(x, y), prev.w, prev.h, 2);
        }
        cur
    };
    // pixel centres -> grid corners (the average of the four around each corner), in feet
    let (vw, vh) = (v.w, v.h);
    let corners = {
        let src = &v;
        let f = |x: i64, y: i64| -> f32 {
            let (mut sum, mut n) = (0f64, 0u32);
            for nx in x - 1..x + 1 {
                for ny in y - 1..y + 1 {
                    let p = src.get(nx, ny);
                    if !p.is_nan() {
                        sum += p as f64;
                        n += 1;
                    }
                }
            }
            if n == 0 {
                f32::NAN
            } else {
                (sum / n as f64 * FEET_PER_METER) as f32
            }
        };
        View::build(vw + 1, vh + 1, 1, &f)
    };
    v.d.clear();
    let lines = isolines(minor as f64, &corners, EXTENT, 1);
    let mut simple: BTreeMap<i64, Vec<Line>> = BTreeMap::new();
    for (k, ls) in lines {
        let ls: Vec<Line> = ls.iter().map(|l| simplify(l, SIMPLIFY_TOLERANCE)).filter(|l| l.len() >= 2).collect();
        if !ls.is_empty() {
            simple.insert(k * minor, ls);
        }
    }
    if simple.is_empty() {
        return Ok(None);
    }
    Ok(Some(encode_mvt(&simple, index)))
}

// ---- decoding (for tests and tools that read contour tiles back) ----

/// A decoded contour tile: (ele, level, lines).
pub fn decode_mvt(b: &[u8]) -> Result<Vec<(i64, i64, Vec<Line>)>> {
    fn rv(b: &[u8], p: &mut usize) -> Result<u64> {
        let mut v = 0u64;
        let mut s = 0;
        loop {
            let c = *b.get(*p).ok_or_else(|| Error::bad_response("mvt cut short"))?;
            *p += 1;
            v |= ((c & 0x7f) as u64) << s;
            if c & 0x80 == 0 {
                return Ok(v);
            }
            s += 7;
        }
    }
    fn fields(b: &[u8]) -> Result<Vec<(u32, u64, &[u8])>> {
        let mut p = 0;
        let mut out = Vec::new();
        while p < b.len() {
            let k = rv(b, &mut p)?;
            match k & 7 {
                0 => out.push(((k >> 3) as u32, rv(b, &mut p)?, &b[0..0])),
                2 => {
                    let l = rv(b, &mut p)? as usize;
                    out.push(((k >> 3) as u32, 0, &b[p..p + l]));
                    p += l;
                }
                t => return Err(Error::bad_response(format!("mvt wire type {t}"))),
            }
        }
        Ok(out)
    }
    let unz = |v: u64| ((v >> 1) as i64) ^ -((v & 1) as i64);
    let mut res = Vec::new();
    for (f, _, layer) in fields(b)? {
        if f != 3 {
            continue;
        }
        let mut vals = Vec::new();
        let mut feats = Vec::new();
        for (lf, _, d) in fields(layer)? {
            match lf {
                4 => {
                    for (vf, vv, _) in fields(d)? {
                        if vf == 6 {
                            vals.push(unz(vv));
                        }
                    }
                }
                2 => feats.push(d),
                _ => {}
            }
        }
        for fd in feats {
            let (mut tags, mut geom) = (&b[0..0], &b[0..0]);
            for (ff, _, d) in fields(fd)? {
                if ff == 2 {
                    tags = d;
                } else if ff == 4 {
                    geom = d;
                }
            }
            let mut p = 0;
            let (mut ele, mut level) = (0, 0);
            while p < tags.len() {
                let k = rv(tags, &mut p)?;
                let v = rv(tags, &mut p)? as usize;
                if k == 0 {
                    ele = vals[v];
                } else {
                    level = vals[v];
                }
            }
            let mut lines: Vec<Line> = Vec::new();
            let (mut p, mut cx, mut cy) = (0usize, 0i64, 0i64);
            while p < geom.len() {
                let cmd = rv(geom, &mut p)?;
                let (id, count) = (cmd & 7, cmd >> 3);
                for _ in 0..count {
                    cx += unz(rv(geom, &mut p)?);
                    cy += unz(rv(geom, &mut p)?);
                    if id == 1 {
                        lines.push(vec![(cx as i32, cy as i32)]);
                    } else if let Some(l) = lines.last_mut() {
                        l.push((cx as i32, cy as i32));
                    }
                }
            }
            res.push((ele, level, lines));
        }
    }
    Ok(res)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A cone: elevation falls with distance from the centre of a 128x128 tile (so subsampling is skipped).
    fn cone(w: usize, peak_m: f32, slope_m_per_px: f32) -> Grid {
        let mut d = Vec::new();
        for y in 0..w {
            for x in 0..w {
                let (dx, dy) = (x as f32 - w as f32 / 2.0, y as f32 - w as f32 / 2.0);
                d.push(peak_m - slope_m_per_px * (dx * dx + dy * dy).sqrt());
            }
        }
        Grid { w, h: w, d }
    }

    #[test]
    fn interval_table() {
        assert_eq!(intervals(2), None);
        assert_eq!(intervals(3), Some((5000, 25000)));
        assert_eq!(intervals(6), Some((1000, 5000)));
        assert_eq!(intervals(11), Some((200, 1000)));
        assert_eq!(intervals(13), Some((100, 500)));
        assert_eq!(intervals(15), Some((20, 100)));
    }

    #[test]
    fn rings_close_and_lines_cross_tiles() {
        // one big cone sampled by 9 tiles of the same z: only the centre matters for a ring, a shifted one for edges
        let g = Arc::new(cone(128, 1000.0, 3.0));
        let fetch = |_z: u8, _x: u32, _y: u32| -> Result<Option<Arc<Grid>>> { Ok(Some(g.clone())) };
        let t = contour_tile(12, 5, 5, 12, &fetch).unwrap().unwrap();
        let feats = decode_mvt(&t).unwrap();
        assert!(!feats.is_empty());
        for (ele, level, lines) in &feats {
            assert_eq!(ele % 100, 0, "z12 minor interval is 100 ft");
            assert_eq!(*level, i64::from(ele % 500 == 0));
            assert!(lines.iter().all(|l| l.len() >= 2));
        }
        // each ring is closed
        let (_, _, lines) = &feats[feats.len() / 2];
        assert!(lines.iter().any(|l| l.first() == l.last()), "ring closes: {lines:?}");
    }

    #[test]
    fn plane_gives_straight_lines_that_meet_at_tile_edges() {
        // elevation rises west to east; the 3700 ft contour sits on the border between two 128-pixel tiles
        let val = |x: usize| 1127.81f32 + 0.9 * (x as f32 - 127.5);
        let left = Arc::new(Grid { w: 128, h: 128, d: (0..128 * 128).map(|i| val(i % 128)).collect() });
        let right = Arc::new(Grid { w: 128, h: 128, d: (0..128 * 128).map(|i| val(128 + i % 128)).collect() });
        let fetch = |z: u8, x: u32, _y: u32| -> Result<Option<Arc<Grid>>> {
            assert_eq!(z, 12);
            Ok(match x {
                0 => Some(left.clone()),
                1 => Some(right.clone()),
                _ => None,
            })
        };
        let a = decode_mvt(&contour_tile(12, 0, 0, 12, &fetch).unwrap().unwrap()).unwrap();
        let b = decode_mvt(&contour_tile(12, 1, 0, 12, &fetch).unwrap().unwrap()).unwrap();
        let xa: Vec<i32> = a.iter().find(|f| f.0 == 3700).expect("3700 in left").2.iter().flatten().map(|p| p.0).collect();
        let xb: Vec<i32> = b.iter().find(|f| f.0 == 3700).expect("3700 in right").2.iter().flatten().map(|p| p.0).collect();
        let (ma, mb) = (xa.iter().sum::<i32>() / xa.len() as i32, xb.iter().sum::<i32>() / xb.len() as i32);
        assert!((ma - EXTENT).abs() <= 4, "left tile line at x={ma}");
        assert!(mb.abs() <= 4, "right tile line at x={mb}");
        assert!(xa.iter().all(|x| (x - ma).abs() <= 3), "straight vertical line");
    }

    #[test]
    fn mvt_round_trip() {
        let mut m = BTreeMap::new();
        m.insert(4100, vec![vec![(0, 0), (10, 10), (20, 5)]]);
        m.insert(4500, vec![vec![(1, 1), (2, 2)], vec![(100, 100), (200, 100)]]);
        let back = decode_mvt(&encode_mvt(&m, 500)).unwrap();
        assert_eq!(back.len(), 2);
        assert_eq!((back[0].0, back[0].1), (4100, 0));
        assert_eq!((back[1].0, back[1].1), (4500, 1));
        assert_eq!(back[1].2.len(), 2);
        assert_eq!(back[0].2[0], vec![(0, 0), (10, 10), (20, 5)]);
    }

    #[test]
    fn simplify_keeps_corners_and_drops_collinear_points() {
        let l = vec![(0, 0), (5, 0), (10, 0), (10, 10), (10, 20)];
        assert_eq!(simplify(&l, 1.0), vec![(0, 0), (10, 0), (10, 20)]);
        let ring = vec![(0, 0), (10, 0), (10, 10), (0, 10), (0, 0)];
        assert_eq!(simplify(&ring, 1.0).len(), 5);
    }

    #[test]
    fn split_overzooms() {
        let g = Grid { w: 4, h: 4, d: (0..16).map(|i| i as f32).collect() };
        let s = g.split(1, 1, 0);
        assert_eq!((s.w, s.h), (2, 2));
        assert_eq!(s.d, vec![2.0, 3.0, 6.0, 7.0]);
    }

    #[test]
    fn terrarium_value() {
        // R=129 G=9 B=128: 129*256 + 9 + 0.5 - 32768 = 265.5 m
        let mut e = png::Encoder::new(Vec::new(), 1, 1);
        e.set_color(png::ColorType::Rgb);
        e.set_depth(png::BitDepth::Eight);
        let mut out = Vec::new();
        {
            let mut w = png::Encoder::new(&mut out, 1, 1);
            w.set_color(png::ColorType::Rgb);
            w.set_depth(png::BitDepth::Eight);
            let mut wr = w.write_header().unwrap();
            wr.write_image_data(&[129, 9, 128]).unwrap();
        }
        let g = decode_terrarium(&out).unwrap();
        assert!((g.d[0] - 265.5).abs() < 0.01, "{}", g.d[0]);
    }
}
