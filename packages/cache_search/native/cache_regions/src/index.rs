//! What the routing server publishes: `current.json` (which build is current, and where its index is) and the index of a
//! build, one line per tile that has roads: `<path>\t<bytes>\t<sha256 of the tile>\t<gzip bytes>`.

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
        if self.index.is_empty() || self.index.starts_with('/') || self.index.contains("..") || self.index.contains('\\') || self.index.contains("://") {
            return Err(format!("current.json names an index Cache cannot use: {:?}", self.index));
        }
        if self.index_sha256.len() != 64 || !self.index_sha256.bytes().all(|c| c.is_ascii_hexdigit()) {
            return Err("current.json has no valid index_sha256".into());
        }
        Ok(())
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
        let mut out: Vec<TileRef> = (0..3u8).flat_map(|l| shape.tiles(l).into_iter().filter_map(move |id| self.get(l, id).cloned())).collect();
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
        };
        assert!(c.check().is_ok());
        c.build = "../x".into();
        assert!(c.check().is_err());
        c.build = "na".into();
        c.index = "https://elsewhere/index.tsv.gz".into();
        assert!(c.check().is_err());
    }
}
