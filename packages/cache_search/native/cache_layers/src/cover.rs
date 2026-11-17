//! Which tiles an outline touches. An outline is one ring or several (a region in parts, and holes), read even-odd: a point is
//! inside when a ray from it crosses the rings an odd number of times, so parts that do not overlap make their union and a hole
//! is left out.
//!
//! A tile is in the outline's cover when its rectangle touches the outline: a vertex inside the rectangle, a corner inside the
//! outline, or an edge across a side (the test a download always made, tile by tile). Touching is inherited: a tile that does
//! not touch has no child that does, and a tile with no edge near it is wholly inside or wholly outside, as are its children.
//! So the cover is worked out zoom by zoom from the world tile down, carrying each tile's nearby edges, and only tiles on the
//! outline's line are tested. Testing every tile of the box against every edge took minutes for a state at z15.

use crate::core::tile_bbox;
use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::Arc;

/// The outline a download is asked for: `[[lon, lat], ...]` (one ring) or `[[[lon, lat], ...], ...]` (several rings).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(untagged)]
pub enum Polygon {
    Ring(Vec<[f64; 2]>),
    Rings(Vec<Vec<[f64; 2]>>),
}

impl Polygon {
    pub fn rings(&self) -> Vec<&[[f64; 2]]> {
        match self {
            Polygon::Ring(r) => vec![r.as_slice()],
            Polygon::Rings(rs) => rs.iter().map(|r| r.as_slice()).collect(),
        }
    }

    /// The box round every ring: [west, south, east, north]. Every ring needs at least 3 points.
    pub fn bounds(&self) -> Result<[f64; 4]> {
        let rings = self.rings();
        if rings.is_empty() || rings.iter().any(|r| r.len() < 3) {
            return Err(Error::bad_json("a polygon needs at least 3 points [lon, lat] in each ring"));
        }
        let (mut w, mut s, mut e, mut n) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
        for q in rings.iter().flat_map(|r| r.iter()) {
            w = w.min(q[0]);
            e = e.max(q[0]);
            s = s.min(q[1]);
            n = n.max(q[1]);
        }
        Ok([w, s, e, n])
    }
}

/// How a tile stands to the outline.
#[derive(Clone)]
enum Class {
    Out,
    In,
    /// It touches the outline and these edges come near it (their boxes overlap the tile's).
    Line(Arc<Vec<u32>>),
}

/// An outline's edges, ready to test tiles against.
pub struct Outline {
    /// (from, to) of every edge, ring after ring, `to` being the next point of the ring.
    edges: Vec<([f64; 2], [f64; 2])>,
    /// The edges by latitude band (each edge in every band its latitudes span): a point is only ever crossed by edges of its own
    /// band, so [Outline::contains] reads those and not every edge of the outline.
    bands: Vec<Vec<u32>>,
    /// How many edges [Outline::contains] looked at and how many times it was asked (the test of how much work a cover takes).
    looked: std::sync::atomic::AtomicU64,
    asked: std::sync::atomic::AtomicU64,
}

/// At most this many bands; fewer for an outline of few edges (a small outline costs no more to build than before).
const MAX_BANDS: usize = 1 << 14;

fn band_of(lat: f64, bands: usize) -> usize {
    (((lat + 90.0) / 180.0 * bands as f64).floor().max(0.0) as usize).min(bands - 1)
}

fn seg_hits(a: [f64; 2], b: [f64; 2], c: [f64; 2], d: [f64; 2]) -> bool {
    let cross = |o: [f64; 2], p: [f64; 2], q: [f64; 2]| (p[0] - o[0]) * (q[1] - o[1]) - (p[1] - o[1]) * (q[0] - o[0]);
    let (d1, d2, d3, d4) = (cross(c, d, a), cross(c, d, b), cross(a, b, c), cross(a, b, d));
    ((d1 > 0.0) != (d2 > 0.0)) && ((d3 > 0.0) != (d4 > 0.0))
}

fn overlaps(e: &([f64; 2], [f64; 2]), r: [f64; 4]) -> bool {
    let (a, b) = e;
    a[0].max(b[0]) >= r[0] && a[0].min(b[0]) <= r[2] && a[1].max(b[1]) >= r[1] && a[1].min(b[1]) <= r[3]
}

impl Outline {
    pub fn new(p: &Polygon) -> Outline {
        let mut edges = Vec::new();
        for r in p.rings() {
            for i in 0..r.len() {
                edges.push((r[i], r[(i + 1) % r.len()]));
            }
        }
        let n = (edges.len() / 16).clamp(1, MAX_BANDS);
        let mut bands: Vec<Vec<u32>> = vec![Vec::new(); n];
        for (i, (a, b)) in edges.iter().enumerate() {
            let (lo, hi) = (band_of(a[1].min(b[1]), n), band_of(a[1].max(b[1]), n));
            for band in &mut bands[lo..=hi] {
                band.push(i as u32);
            }
        }
        Outline { edges, bands, looked: Default::default(), asked: Default::default() }
    }

    /// Inside, even-odd over every ring (each edge is taken from its end to its start, as the test always read them).
    pub fn contains(&self, p: [f64; 2]) -> bool {
        use std::sync::atomic::Ordering::Relaxed;
        let mut inside = false;
        let near = &self.bands[band_of(p[1], self.bands.len())];
        self.asked.fetch_add(1, Relaxed);
        self.looked.fetch_add(near.len() as u64, Relaxed);
        for &i in near {
            let (b, a) = self.edges[i as usize];
            if (a[1] > p[1]) != (b[1] > p[1]) && p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0] {
                inside = !inside;
            }
        }
        inside
    }

    /// How rectangle `r` stands to the outline, given the edges near its parent (`near`; every edge for the world tile).
    fn classify(&self, r: [f64; 4], near: &[u32]) -> Class {
        let mine: Vec<u32> = near.iter().copied().filter(|&i| overlaps(&self.edges[i as usize], r)).collect();
        let corners = [[r[0], r[1]], [r[2], r[1]], [r[2], r[3]], [r[0], r[3]]];
        if mine.is_empty() {
            // nothing of the outline comes into the tile: wholly inside or wholly outside
            return if corners.iter().any(|c| self.contains(*c)) { Class::In } else { Class::Out };
        }
        let hits = mine.iter().any(|&i| {
            let (a, b) = self.edges[i as usize];
            (a[0] >= r[0] && a[0] <= r[2] && a[1] >= r[1] && a[1] <= r[3]) || (0..4).any(|k| seg_hits(a, b, corners[k], corners[(k + 1) % 4]))
        }) || corners.iter().any(|c| self.contains(*c));
        if hits {
            Class::Line(Arc::new(mine))
        } else {
            Class::Out
        }
    }

    fn all(&self) -> Vec<u32> {
        (0..self.edges.len() as u32).collect()
    }

    /// Every tile from `zmin` to `zmax` that touches the outline and that `keep` accepts, coarsest zoom first; at most `limit`.
    pub fn tiles(&self, zmin: u8, zmax: u8, limit: u64, keep: impl Fn(u8, u32, u32) -> bool) -> Result<Vec<(u8, u32, u32)>> {
        let mut out = Vec::new();
        let mut level: Vec<(u32, u32, Class)> = match self.classify(tile_bbox(0, 0, 0), &self.all()) {
            Class::Out => Vec::new(),
            c => vec![(0, 0, c)],
        };
        for z in 0..=zmax {
            if z >= zmin {
                for (x, y, _) in &level {
                    if keep(z, *x, *y) {
                        out.push((z, *x, *y));
                    }
                }
                if out.len() as u64 > limit {
                    return Err(Error::limit("that area at those zooms has far too many tiles to list; choose a smaller area or fewer zooms"));
                }
            }
            if z == zmax {
                break;
            }
            let mut next = Vec::with_capacity(level.len() * 4);
            for (x, y, c) in level {
                for (cx, cy) in [(2 * x, 2 * y), (2 * x + 1, 2 * y), (2 * x, 2 * y + 1), (2 * x + 1, 2 * y + 1)] {
                    let cc = match &c {
                        Class::In => Class::In,
                        Class::Line(near) => self.classify(tile_bbox(z + 1, cx, cy), near),
                        Class::Out => Class::Out,
                    };
                    if !matches!(cc, Class::Out) {
                        next.push((cx, cy, cc));
                    }
                }
                // a deeper zoom has at least as many tiles: stop before the list grows past the limit
                if next.len() as u64 > limit {
                    return Err(Error::limit("that area at those zooms has far too many tiles to list; choose a smaller area or fewer zooms"));
                }
            }
            level = next;
        }
        Ok(out)
    }

    /// Asks tile by tile whether a tile touches the outline, remembering the tiles above it.
    pub fn asker(&self) -> Asker<'_> {
        Asker { o: self, memo: HashMap::new() }
    }
}

pub struct Asker<'a> {
    o: &'a Outline,
    memo: HashMap<(u8, u32, u32), Class>,
}

impl Asker<'_> {
    fn class(&mut self, z: u8, x: u32, y: u32) -> Class {
        if let Some(c) = self.memo.get(&(z, x, y)) {
            return c.clone();
        }
        let c = if z == 0 {
            self.o.classify(tile_bbox(0, 0, 0), &self.o.all())
        } else {
            match self.class(z - 1, x >> 1, y >> 1) {
                Class::Line(near) => self.o.classify(tile_bbox(z, x, y), &near),
                c => c,
            }
        };
        self.memo.insert((z, x, y), c.clone());
        c
    }

    pub fn touches(&mut self, z: u8, x: u32, y: u32) -> bool {
        !matches!(self.class(z, x, y), Class::Out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The test as it was, tile by tile (one ring).
    fn old_hits(poly: &[[f64; 2]], r: [f64; 4]) -> bool {
        fn pip(p: [f64; 2], poly: &[[f64; 2]]) -> bool {
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
        let corners = [[r[0], r[1]], [r[2], r[1]], [r[2], r[3]], [r[0], r[3]]];
        if poly.iter().any(|p| p[0] >= r[0] && p[0] <= r[2] && p[1] >= r[1] && p[1] <= r[3]) {
            return true;
        }
        if corners.iter().any(|c| pip(*c, poly)) {
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

    fn brute(poly: &[[f64; 2]], zmin: u8, zmax: u8) -> Vec<(u8, u32, u32)> {
        let b = Polygon::Ring(poly.to_vec()).bounds().unwrap();
        let mut out = Vec::new();
        for z in zmin..=zmax {
            let (x0, x1, y0, y1) = crate::download::tile_range(b, z);
            for x in x0..=x1 {
                for y in y0..=y1 {
                    if old_hits(poly, tile_bbox(z, x as u32, y as u32)) {
                        out.push((z, x as u32, y as u32));
                    }
                }
            }
        }
        out
    }

    fn fast(p: &Polygon, zmin: u8, zmax: u8) -> Vec<(u8, u32, u32)> {
        let b = p.bounds().unwrap();
        let mut v = Outline::new(p)
            .tiles(zmin, zmax, u64::MAX, |z, x, y| {
                let (x0, x1, y0, y1) = crate::download::tile_range(b, z);
                (x0..=x1).contains(&(x as u64)) && (y0..=y1).contains(&(y as u64))
            })
            .unwrap();
        v.sort();
        v
    }

    #[test]
    fn the_cover_is_the_same_set_the_tile_by_tile_test_gives() {
        let shapes: Vec<Vec<[f64; 2]>> = vec![
            vec![[-114.0, 42.0], [-113.0, 42.0], [-113.5, 43.0]],
            // a concave outline with a notch, closed as GeoJSON closes its rings
            vec![[-117.0, 42.0], [-111.0, 42.0], [-111.0, 49.0], [-114.0, 45.0], [-117.0, 49.0], [-117.0, 42.0]],
            // edges along tile lines
            vec![[-112.5, 40.979898], [-112.148438, 40.979898], [-112.148438, 41.244772], [-112.5, 41.244772]],
        ];
        for s in &shapes {
            let mut want = brute(s, 0, 12);
            want.sort();
            assert_eq!(fast(&Polygon::Ring(s.clone()), 0, 12), want);
        }
        // the asker agrees with the list
        let p = Polygon::Ring(shapes[1].clone());
        let o = Outline::new(&p);
        let mut a = o.asker();
        let listed: std::collections::HashSet<_> = fast(&p, 8, 11).into_iter().collect();
        let (x0, x1, y0, y1) = crate::download::tile_range(p.bounds().unwrap(), 11);
        for x in x0..=x1 {
            for y in y0..=y1 {
                assert_eq!(a.touches(11, x as u32, y as u32), listed.contains(&(11, x as u32, y as u32)));
            }
        }
    }

    #[test]
    fn inside_is_read_from_the_edges_of_the_points_own_band_only() {
        // a ragged ring of many edges (a coast): the answer is the plain every-edge even-odd test's, and each answer reads a
        // small part of the edges (Germany's outline took minutes of this at z15, each corner test reading every edge)
        let n = 100_000usize;
        let ring: Vec<[f64; 2]> = (0..n)
            .map(|i| {
                let t = i as f64 / n as f64 * std::f64::consts::TAU;
                let r = 2.5 + 0.3 * (37.0 * t).sin() + 0.05 * (997.0 * t).sin();
                [10.0 + r * t.cos() * 1.4, 50.0 + r * t.sin()]
            })
            .collect();
        let o = Outline::new(&Polygon::Ring(ring.clone()));
        let plain = |p: [f64; 2]| {
            let mut inside = false;
            for i in 0..ring.len() {
                let (b, a) = (ring[i], ring[(i + 1) % ring.len()]);
                if (a[1] > p[1]) != (b[1] > p[1]) && p[0] < (b[0] - a[0]) * (p[1] - a[1]) / (b[1] - a[1]) + a[0] {
                    inside = !inside;
                }
            }
            inside
        };
        for i in 0..300 {
            let p = [4.0 + (i as f64 * 0.0371) % 12.0, 46.0 + (i as f64 * 0.0173) % 8.0];
            assert_eq!(o.contains(p), plain(p), "{p:?}");
        }
        use std::sync::atomic::Ordering::Relaxed;
        let (looked, asked) = (o.looked.load(Relaxed), o.asked.load(Relaxed));
        assert!(looked <= asked * (n as u64 / 20), "each answer read {} of {n} edges", looked / asked);
        // and a cover through the outline asks it far fewer edges than every edge each time
        let o2 = Outline::new(&Polygon::Ring(ring));
        let cover = o2.tiles(0, 9, u64::MAX, |_, _, _| true).unwrap();
        assert!(!cover.is_empty());
        let (looked, asked) = (o2.looked.load(Relaxed), o2.asked.load(Relaxed));
        assert!(looked <= asked * (n as u64 / 20), "each answer read {} of {n} edges", looked / asked.max(1));
    }

    #[test]
    fn parts_make_their_union_and_a_hole_is_left_out() {
        let west = vec![[-117.0, 42.0], [-115.0, 42.0], [-115.0, 44.0], [-117.0, 44.0]];
        let east = vec![[-113.0, 42.0], [-111.0, 42.0], [-111.0, 44.0], [-113.0, 44.0]];
        let both = Polygon::Rings(vec![west.clone(), east.clone()]);
        let (w, e, u) = (fast(&Polygon::Ring(west.clone()), 6, 10), fast(&Polygon::Ring(east.clone()), 6, 10), fast(&both, 6, 10));
        let mut union: Vec<_> = w.iter().chain(e.iter()).copied().collect();
        union.sort();
        union.dedup();
        assert_eq!(u, union);
        // the gap between the parts is not in the cover
        let gap = (10u8, ((-114.0 + 180.0) / 360.0 * 1024.0) as u32, 0u32);
        assert!(!u.iter().any(|t| t.0 == gap.0 && t.1 == gap.1));
        // a hole: the middle of a ring with a ring inside it
        let outer = vec![[-117.0, 42.0], [-111.0, 42.0], [-111.0, 48.0], [-117.0, 48.0]];
        let hole = vec![[-115.0, 44.0], [-113.0, 44.0], [-113.0, 46.0], [-115.0, 46.0]];
        let o = Outline::new(&Polygon::Rings(vec![outer, hole]));
        assert!(o.contains([-116.0, 43.0]) && !o.contains([-114.0, 45.0]));
        // one ring as a list of rings or as a ring: the same tiles
        assert_eq!(fast(&Polygon::Rings(vec![west.clone()]), 6, 10), w);
        let parsed: Polygon = serde_json::from_str("[[[-117,42],[-115,42],[-115,44]]]").unwrap();
        assert!(matches!(parsed, Polygon::Rings(_)));
        let parsed: Polygon = serde_json::from_str("[[-117,42],[-115,42],[-115,44]]").unwrap();
        assert!(matches!(parsed, Polygon::Ring(_)));
        assert!(Polygon::Rings(vec![]).bounds().is_err());
        assert!(Polygon::Rings(vec![west, vec![[0.0, 0.0], [1.0, 1.0]]]).bounds().is_err());
    }
}
