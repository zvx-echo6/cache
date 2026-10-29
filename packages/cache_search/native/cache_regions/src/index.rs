//! What the server publishes: `current.json` (which build is current, and where its index is) and the index of a build, one
//! line per tile: `<path>\t<bytes>\t<sha256 of the tile>\t<gzip bytes>`. Routing (`routing/`) and places (`places/`, with
//! its common file; docs/PLACES-TILES.md) publish the same way.

use crate::geo;
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// `current.json`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Current {
    pub format: u32,
    pub build: String,
    #[serde(default)]
    pub valhalla: Option<String>,
    #[serde(default)]
    pub source: Option<String>,
    #[serde(default)]
    pub tiles: u64,
    #[serde(default)]
    pub bytes: u64,
    #[serde(default)]
    pub gz_bytes: u64,
    /// The index, relative to the base address ("na-2026-10-18/index.tsv.gz").
    pub index: String,
    /// SHA-256 of the index file as published (the gzip file).
    pub index_sha256: String,
    /// "places" for places; absent for routing (whose current.json predates the field).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub component: Option<String>,
    /// The layout of a places build's tiles and common file (`cache_places::schema::TILE_SCHEMA`).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tile_schema: Option<u32>,
    /// The tile levels published (places: [1]; routing, absent: 0 to 2).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub levels: Option<Vec<u8>>,
    /// Places: the build's common file, relative to the base address, and its SHA-256 (of the unpacked file) and sizes.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub common: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub common_sha256: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub common_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub common_gz_bytes: Option<u64>,
}

/// A places build's common file, as current.json names it.
#[derive(Debug, Clone, PartialEq)]
pub struct CommonRef {
    pub path: String,
    pub sha256: String,
    pub bytes: u64,
    pub gz: u64,
}

fn hex64(s: &str) -> bool {
    s.len() == 64 && s.bytes().all(|c| c.is_ascii_hexdigit())
}

/// A path under the base address: not absolute, no way up, no other host.
fn safe_rel(p: &str) -> bool {
    !(p.is_empty() || p.starts_with('/') || p.contains("..") || p.contains('\\') || p.contains("://"))
}

impl Current {
    /// Checks what a server sent before anything is built from it: a build name that is safe as a folder name, an index path
    /// with no way out of the base address.
    pub fn check(&self) -> Result<(), String> {
        if self.format != 1 {
            return Err(format!("current.json is format {}, this version of Cache reads format 1", self.format));
        }
        if !safe_build(&self.build) {
            return Err(format!("current.json names a build Cache cannot use: {:?}", self.build));
        }
        if !safe_rel(&self.index) {
            return Err(format!("current.json names an index Cache cannot use: {:?}", self.index));
        }
        if !hex64(&self.index_sha256) {
            return Err("current.json has no valid index_sha256".into());
        }
        Ok(())
    }

    /// `check`, for a routing current.json: one that says it is another component's is refused.
    pub fn check_routing(&self) -> Result<(), String> {
        self.check()?;
        match self.component.as_deref() {
            None | Some("routing") => Ok(()),
            Some(other) => Err(format!("the routing address publishes {other:?}, not routing")),
        }
    }

    /// `check`, for a places current.json: the component, a tile layout this version reads, and the common file. Returns the
    /// common file.
    pub fn check_places(&self, tile_schema: u32) -> Result<CommonRef, String> {
        self.check()?;
        if self.component.as_deref() != Some("places") {
            return Err(format!("the places address publishes {:?}, not places", self.component.as_deref().unwrap_or("routing")));
        }
        if self.tile_schema != Some(tile_schema) {
            return Err(format!("update Cache to use this data: the places are in layout {:?}, this version reads {tile_schema}", self.tile_schema));
        }
        if self.levels.as_ref().is_some_and(|l| !l.contains(&1)) {
            return Err(format!("the places build has no level 1 tiles ({:?})", self.levels));
        }
        let path = self.common.clone().filter(|p| safe_rel(p)).ok_or_else(|| format!("current.json names a common file Cache cannot use: {:?}", self.common))?;
        let sha256 = self.common_sha256.clone().map(|s| s.to_ascii_lowercase()).filter(|s| hex64(s)).ok_or("current.json has no valid common_sha256")?;
        Ok(CommonRef { path, sha256, bytes: self.common_bytes.unwrap_or(0), gz: self.common_gz_bytes.unwrap_or(0) })
    }
}

/// A build name becomes a folder name: letters, digits, '-', '_' and '.', not starting with '.'.
pub fn safe_build(b: &str) -> bool {
    !b.is_empty() && b.len() <= 64 && !b.starts_with('.') && b.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_' || c == b'.')
}

/// One tile of a build.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TileRef {
    /// "2/000/818/660": the address under the build (with ".gph.gz") and the file under the tile folder (with ".gph").
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
    pub gz: u64,
}

/// The index of one build: its tiles by (level, id). A tile that is not here has no roads.
#[derive(Debug, Default)]
pub struct Index {
    pub build: String,
    tiles: HashMap<(u8, u64), TileRef>,
}

impl Index {
    /// The index text (the unpacked `index.tsv.gz`). A line that is not a tile is an error: the file is not what it should be.
    pub fn parse(build: &str, text: &str) -> Result<Index, String> {
        let mut tiles = HashMap::new();
        for (n, line) in text.lines().enumerate() {
            let line = line.trim_end_matches('\r');
            if line.is_empty() {
                continue;
            }
            let bad = || format!("line {} of the index of {build} is not a tile: {line:?}", n + 1);
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() < 4 {
                return Err(bad());
            }
            let key = geo::parse_tile_path(f[0]).ok_or_else(bad)?;
            let bytes: u64 = f[1].parse().map_err(|_| bad())?;
            let gz: u64 = f[3].parse().map_err(|_| bad())?;
            let sha = f[2].to_ascii_lowercase();
            if sha.len() != 64 || !sha.bytes().all(|c| c.is_ascii_hexdigit()) {
                return Err(bad());
            }
            tiles.insert(key, TileRef { path: f[0].to_string(), bytes, sha256: sha, gz });
        }
        Ok(Index { build: build.to_string(), tiles })
    }

    pub fn get(&self, level: u8, id: u64) -> Option<&TileRef> {
        self.tiles.get(&(level, id))
    }

    pub fn len(&self) -> usize {
        self.tiles.len()
    }

    pub fn is_empty(&self) -> bool {
        self.tiles.is_empty()
    }

    /// The tiles of this build an outline needs: every level's tiles it overlaps that have roads, by path.
    pub fn tiles_for(&self, shape: &geo::Shape) -> Vec<TileRef> {
        let mut out: Vec<TileRef> = Vec::new();
        for l in 0..3u8 {
            out.extend(shape.tiles(l).into_iter().filter_map(|id| self.get(l, id).cloned()));
        }
        out.sort_by(|a, b| a.path.cmp(&b.path));
        out
    }

    /// The tiles of one level an outline overlaps that are in the index, by path (places: level 1).
    pub fn tiles_for_level(&self, shape: &geo::Shape, level: u8) -> Vec<TileRef> {
        let mut out: Vec<TileRef> = shape.tiles(level).into_iter().filter_map(|id| self.get(level, id).cloned()).collect();
        out.sort_by(|a, b| a.path.cmp(&b.path));
        out
    }

    /// The tiles of one level within `deg` of any of `points` ([lat, lon]) that are in the index, by path.
    pub fn tiles_near_level(&self, points: &[(f64, f64)], level: u8, deg: f64) -> Vec<TileRef> {
        let mut ids: Vec<u64> = Vec::new();
        for &(lat, lon) in points.iter().filter(|(a, o)| a.is_finite() && o.is_finite()) {
            ids.extend(geo::tiles_in_box(level, [lon - deg, lat - deg, lon + deg, lat + deg]));
        }
        ids.sort_unstable();
        ids.dedup();
        let mut out: Vec<TileRef> = ids.into_iter().filter_map(|id| self.get(level, id).cloned()).collect();
        out.sort_by(|a, b| a.path.cmp(&b.path));
        out
    }

    /// The tiles a route through `points` ([lat, lon]) is likely to need: level 0 and 1 over the points' box widened by
    /// `box_deg`, level 2 within `near_deg` of each point.
    pub fn tiles_near(&self, points: &[(f64, f64)], box_deg: f64, near_deg: f64) -> Vec<TileRef> {
        let pts: Vec<(f64, f64)> = points.iter().copied().filter(|(a, o)| a.is_finite() && o.is_finite()).collect();
        if pts.is_empty() {
            return Vec::new();
        }
        let (mut w, mut s, mut e, mut n) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
        for &(lat, lon) in &pts {
            w = w.min(lon);
            e = e.max(lon);
            s = s.min(lat);
            n = n.max(lat);
        }
        let wide = [w - box_deg, s - box_deg, e + box_deg, n + box_deg];
        let mut keys: Vec<(u8, u64)> = Vec::new();
        for l in 0..2u8 {
            keys.extend(geo::tiles_in_box(l, wide).into_iter().map(|id| (l, id)));
        }
        for &(lat, lon) in &pts {
            keys.extend(geo::tiles_in_box(2, [lon - near_deg, lat - near_deg, lon + near_deg, lat + near_deg]).into_iter().map(|id| (2, id)));
        }
        keys.sort_unstable();
        keys.dedup();
        let mut out: Vec<TileRef> = keys.into_iter().filter_map(|(l, id)| self.get(l, id).cloned()).collect();
        out.sort_by(|a, b| a.path.cmp(&b.path));
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const H: &str = "0000000000000000000000000000000000000000000000000000000000000000";

    #[test]
    fn index_lines() {
        let text = format!("0/002/986\t10\t{H}\t8\n2/000/763/464\t20\t{H}\t9\n");
        let i = Index::parse("b1", &text).unwrap();
        assert_eq!(i.len(), 2);
        assert_eq!(i.get(2, 763464).unwrap().bytes, 20);
        assert_eq!(i.get(2, 763464).unwrap().gz, 9);
        assert!(i.get(1, 47586).is_none());
        assert!(Index::parse("b1", "2/000/763/464\t20\n").is_err());
        assert!(Index::parse("b1", &format!("../etc\t20\t{H}\t9\n")).is_err());
    }

    #[test]
    fn current_is_checked() {
        let mut c = Current {
            format: 1,
            build: "na-2026-10-18".into(),
            valhalla: None,
            source: None,
            tiles: 0,
            bytes: 0,
            gz_bytes: 0,
            index: "na-2026-10-18/index.tsv.gz".into(),
            index_sha256: H.into(),
            component: None,
            tile_schema: None,
            levels: None,
            common: None,
            common_sha256: None,
            common_bytes: None,
            common_gz_bytes: None,
        };
        assert!(c.check().is_ok() && c.check_routing().is_ok());
        assert!(c.check_places(1).is_err(), "a routing current.json is not places");
        let mut p = c.clone();
        p.component = Some("places".into());
        p.tile_schema = Some(1);
        p.common = Some("na-2026-10-18/common.sqlite.gz".into());
        p.common_sha256 = Some(H.into());
        p.common_gz_bytes = Some(7);
        assert_eq!(p.check_places(1).unwrap(), CommonRef { path: "na-2026-10-18/common.sqlite.gz".into(), sha256: H.into(), bytes: 0, gz: 7 });
        assert!(p.check_routing().is_err());
        assert!(p.check_places(2).unwrap_err().starts_with("update Cache"));
        p.common = Some("../common.sqlite.gz".into());
        assert!(p.check_places(1).is_err());
        // Read back without the places fields, a routing current.json is as it was.
        let text = serde_json::to_string(&c).unwrap();
        assert!(!text.contains("component") && !text.contains("common"), "{text}");
        c.build = "../x".into();
        assert!(c.check().is_err());
        c.build = "na".into();
        c.index = "https://elsewhere/index.tsv.gz".into();
        assert!(c.check().is_err());
    }
}
