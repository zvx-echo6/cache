//! State and country of a point, from the admin boundaries in navi's admins.sqlite (Valhalla's admin database:
//! countries at level 2, states and provinces at level 4, geometry as SpatiaLite blobs). The blobs are decoded here, so
//! SpatiaLite itself is not needed.

use rusqlite::{Connection, OpenFlags};
use std::collections::HashMap;
use std::path::Path;

type Pt = (f64, f64); // (lon, lat)

struct Ring {
    pts: Vec<Pt>,
    /// Edges bucketed by latitude band, so a point only tests the edges that cross its row.
    bands: Vec<Vec<u32>>,
    min_lat: f64,
    band_h: f64,
}

impl Ring {
    fn new(pts: Vec<Pt>) -> Ring {
        let (mut lo, mut hi) = (f64::MAX, f64::MIN);
        for p in &pts {
            lo = lo.min(p.1);
            hi = hi.max(p.1);
        }
        let n_bands = 256usize;
        let band_h = ((hi - lo) / n_bands as f64).max(1e-9);
        let mut bands = vec![Vec::new(); n_bands];
        for i in 0..pts.len() {
            let (a, b) = (pts[i], pts[(i + 1) % pts.len()]);
            let (y0, y1) = (a.1.min(b.1), a.1.max(b.1));
            let b0 = (((y0 - lo) / band_h) as usize).min(n_bands - 1);
            let b1 = (((y1 - lo) / band_h) as usize).min(n_bands - 1);
            for band in &mut bands[b0..=b1] {
                band.push(i as u32);
            }
        }
        Ring { pts, bands, min_lat: lo, band_h }
    }

    fn contains(&self, lon: f64, lat: f64) -> bool {
        let b = ((lat - self.min_lat) / self.band_h).floor();
        if b < 0.0 || b as usize >= self.bands.len() {
            return false;
        }
        let mut inside = false;
        for &i in &self.bands[b as usize] {
            let (a, c) = (self.pts[i as usize], self.pts[(i as usize + 1) % self.pts.len()]);
            if (a.1 > lat) != (c.1 > lat) && lon < (c.0 - a.0) * (lat - a.1) / (c.1 - a.1) + a.0 {
                inside = !inside;
            }
        }
        inside
    }
}

struct Poly {
    outer: Ring,
    holes: Vec<Ring>,
}

pub struct Region {
    pub code: String,
    pub name: String,
    /// min_lon, min_lat, max_lon, max_lat from the blob header.
    pub mbr: [f64; 4],
    polys: Vec<Poly>,
}

impl Region {
    fn contains(&self, lat: f64, lon: f64) -> bool {
        if lon < self.mbr[0] || lon > self.mbr[2] || lat < self.mbr[1] || lat > self.mbr[3] {
            return false;
        }
        self.polys.iter().any(|p| p.outer.contains(lon, lat) && !p.holes.iter().any(|h| h.contains(lon, lat)))
    }
}

struct Rd<'a> {
    b: &'a [u8],
    i: usize,
}

impl Rd<'_> {
    fn u32(&mut self) -> Option<u32> {
        let v = u32::from_le_bytes(self.b.get(self.i..self.i + 4)?.try_into().ok()?);
        self.i += 4;
        Some(v)
    }
    fn f64(&mut self) -> Option<f64> {
        let v = f64::from_le_bytes(self.b.get(self.i..self.i + 8)?.try_into().ok()?);
        self.i += 8;
        Some(v)
    }
    fn u8(&mut self) -> Option<u8> {
        let v = *self.b.get(self.i)?;
        self.i += 1;
        Some(v)
    }
}

fn read_polygon(r: &mut Rd) -> Option<Poly> {
    let n_rings = r.u32()?;
    let mut rings = Vec::new();
    for _ in 0..n_rings {
        let n = r.u32()? as usize;
        let mut pts = Vec::with_capacity(n);
        for _ in 0..n {
            pts.push((r.f64()?, r.f64()?));
        }
        if pts.len() >= 3 {
            rings.push(Ring::new(pts));
        }
    }
    let mut it = rings.into_iter();
    let outer = it.next()?;
    Some(Poly { outer, holes: it.collect() })
}

/// Decodes a SpatiaLite POLYGON or MULTIPOLYGON blob (little endian, not compressed): (mbr, polygons).
fn decode(blob: &[u8]) -> Option<([f64; 4], Vec<Poly>)> {
    if blob.len() < 44 || blob[0] != 0 || blob[1] != 1 || blob[38] != 0x7c {
        return None;
    }
    let mut r = Rd { b: blob, i: 6 };
    let mbr = [r.f64()?, r.f64()?, r.f64()?, r.f64()?];
    r.i = 39;
    let class = r.u32()?;
    let mut polys = Vec::new();
    match class {
        3 => polys.push(read_polygon(&mut r)?),
        6 => {
            for _ in 0..r.u32()? {
                if r.u8()? != 0x69 || r.u32()? != 3 {
                    return None;
                }
                polys.push(read_polygon(&mut r)?);
            }
        }
        _ => return None,
    }
    Some((mbr, polys))
}

pub struct Admins {
    states: Vec<Region>,
    countries: Vec<Region>,
    /// state index -> country code, found once per state.
    country_of_state: HashMap<usize, Option<String>>,
}

impl Admins {
    pub fn load(path: &Path) -> Result<Admins, String> {
        let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| format!("{}: {e}", path.display()))?;
        let mut st = c
            .prepare("SELECT admin_level, COALESCE(iso_code, ''), name, geom FROM admins WHERE admin_level IN (2, 4)")
            .map_err(|e| e.to_string())?;
        let rows = st
            .query_map([], |r| Ok((r.get::<_, i64>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, Vec<u8>>(3)?)))
            .map_err(|e| e.to_string())?;
        let (mut states, mut countries) = (Vec::new(), Vec::new());
        for row in rows {
            let (level, code, name, blob) = row.map_err(|e| e.to_string())?;
            if code.is_empty() {
                continue;
            }
            let Some((mbr, polys)) = decode(&blob) else { continue };
            let region = Region { code, name, mbr, polys };
            if level == 4 { states.push(region) } else { countries.push(region) }
        }
        if states.is_empty() {
            return Err(format!("{}: no state boundaries found", path.display()));
        }
        Ok(Admins { states, countries, country_of_state: HashMap::new() })
    }

    /// The state (code, name) containing the point, with its country code.
    pub fn locate(&mut self, lat: f64, lon: f64) -> (Option<(String, String)>, Option<String>) {
        if let Some(i) = self.states.iter().position(|s| s.contains(lat, lon)) {
            let country = match self.country_of_state.get(&i) {
                Some(c) => c.clone(),
                None => {
                    let c = self.countries.iter().find(|c| c.contains(lat, lon)).map(|c| c.code.clone());
                    self.country_of_state.insert(i, c.clone());
                    c
                }
            };
            let s = &self.states[i];
            return (Some((s.code.clone(), s.name.clone())), country);
        }
        (None, self.countries.iter().find(|c| c.contains(lat, lon)).map(|c| c.code.clone()))
    }

    pub fn state_code(&self, name: &str) -> Option<String> {
        self.states.iter().find(|s| s.name.eq_ignore_ascii_case(name)).map(|s| s.code.clone())
    }

    /// The bounding box (min_lat, min_lon, max_lat, max_lon) of the state with this name.
    pub fn bbox_of_state(&self, name: &str) -> Option<(f64, f64, f64, f64)> {
        self.states.iter().find(|s| s.name.eq_ignore_ascii_case(name)).map(|s| (s.mbr[1], s.mbr[0], s.mbr[3], s.mbr[2]))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ring_with_bands() {
        let r = Ring::new(vec![(0.0, 0.0), (10.0, 0.0), (10.0, 10.0), (0.0, 10.0)]);
        assert!(r.contains(5.0, 5.0));
        assert!(!r.contains(11.0, 5.0));
        assert!(!r.contains(5.0, 11.0));
        assert!(!r.contains(5.0, -1.0));
    }
}
