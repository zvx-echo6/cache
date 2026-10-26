//! Layer definitions (format 1): data, never code. See DESIGN-LAYERS.md.

use crate::error::{Error, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const FORMAT: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum Kind {
    #[serde(rename = "vector")]
    Vector,
    #[serde(rename = "raster")]
    Raster,
    #[serde(rename = "elevation")]
    Elevation,
    #[serde(rename = "online-raster")]
    OnlineRaster,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Transform {
    AsIs,
    Hillshade,
    Contours,
    RasterWindow,
    OnlineOnly,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Source {
    /// "pmtiles" | "xyz" | "tilejson" | "cog"
    #[serde(rename = "type")]
    pub kind: String,
    pub url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub minzoom: Option<u8>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub maxzoom: Option<u8>,
    /// Elevation tiles only: "terrarium".
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub encoding: Option<String>,
    /// "mvt" | "png" | "webp" | "jpg"
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tile_format: Option<String>,
    /// Pixels per raster tile (256 if absent).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tile_size: Option<u32>,
    /// cog only: the size in degrees of the grid of files `{lat}`/`{lon}` name (3 if absent).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub grid_deg: Option<f64>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Coverage {
    /// [west, south, east, north]
    pub bbox: Option<[f64; 4]>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Offline {
    #[serde(default = "yes")]
    pub allowed: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_tiles_per_download: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_bytes_per_download: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub max_parallel: Option<u32>,
    /// Where area downloads read from, when that is not `source` (a layer that streams from a tile endpoint but is
    /// downloaded from a PMTiles archive, as Mapterhorn is).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Default)]
pub struct Update {
    #[serde(default)]
    pub version: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub check_url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub interval_days: Option<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct LayerDef {
    pub format: u32,
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub description: String,
    pub kind: Kind,
    pub transform: Transform,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub derived_from: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub source: Option<Source>,
    #[serde(default)]
    pub attribution: String,
    #[serde(default)]
    pub license: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub coverage: Option<Coverage>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offline: Option<Offline>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update: Option<Update>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub style_hints: Option<Value>,
    /// The tile schema a vector layer uses ("protomaps-v4", "openmaptiles", ...). Passed through to the app, which
    /// picks the style for it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layout: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub recipe: Option<String>,
    /// False: the catalogue lists the layer but the app leaves it off until the user turns it on.
    #[serde(default = "yes")]
    pub enabled_by_default: bool,
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 64 && id.chars().next().map(|c| c.is_ascii_lowercase() || c.is_ascii_digit()).unwrap_or(false)
        && id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-' || c == '_')
}

/// https always; plain http only to this machine (tests and a user's own server on the device).
pub fn url_ok(url: &str) -> bool {
    if url.starts_with("https://") {
        return true;
    }
    if let Some(r) = url.strip_prefix("http://") {
        let host = r.split(['/', '?', '#']).next().unwrap_or("");
        let host = host.rsplit('@').next().unwrap_or("");
        let host = if host.starts_with('[') { host.split(']').next().unwrap_or("").trim_start_matches('[') } else { host.split(':').next().unwrap_or("") };
        return host == "127.0.0.1" || host == "localhost" || host == "::1";
    }
    false
}

pub fn norm_format(f: &str) -> Option<&'static str> {
    match f.to_ascii_lowercase().as_str() {
        "mvt" | "pbf" => Some("mvt"),
        "png" => Some("png"),
        "webp" => Some("webp"),
        "jpg" | "jpeg" => Some("jpg"),
        _ => None,
    }
}

impl Source {
    pub fn format(&self) -> Option<&'static str> {
        self.tile_format.as_deref().and_then(norm_format)
    }
}

impl LayerDef {
    /// Parse and validate. All problems are reported together.
    pub fn parse(json: &str) -> Result<LayerDef> {
        let v: Value = serde_json::from_str(json).map_err(|e| Error::bad_json(format!("layer definition: {e}")))?;
        LayerDef::from_value(&v)
    }

    pub fn from_value(v: &Value) -> Result<LayerDef> {
        let d: LayerDef = serde_json::from_value(v.clone()).map_err(|e| Error::bad_json(format!("layer definition: {e}")))?;
        let problems = d.problems();
        if problems.is_empty() {
            Ok(d)
        } else {
            Err(Error::bad_json(format!("layer definition {:?}: {}", d.id, problems.join("; "))))
        }
    }

    pub fn problems(&self) -> Vec<String> {
        let mut p: Vec<String> = Vec::new();
        if self.format != FORMAT {
            p.push(format!("format must be {FORMAT}"));
        }
        if !valid_id(&self.id) {
            p.push("id must be 1-64 characters: a-z, 0-9, - and _".into());
        }
        if self.title.trim().is_empty() {
            p.push("title is required".into());
        }
        let allowed_kinds: &[Kind] = match self.transform {
            Transform::AsIs => &[Kind::Vector, Kind::Raster, Kind::Elevation],
            Transform::Hillshade => &[Kind::Elevation],
            Transform::Contours => &[Kind::Vector],
            Transform::RasterWindow => &[Kind::Raster],
            Transform::OnlineOnly => &[Kind::OnlineRaster, Kind::Vector, Kind::Raster],
        };
        if !allowed_kinds.contains(&self.kind) {
            p.push(format!("kind {:?} does not go with transform {:?}", self.kind, self.transform));
        }
        let derived = matches!(self.transform, Transform::Hillshade | Transform::Contours);
        match (&self.derived_from, derived) {
            (None, true) => p.push("derived_from (an elevation layer id) is required for hillshade and contours".into()),
            (Some(_), false) => p.push("derived_from is only for hillshade and contours".into()),
            (Some(d), true) if !valid_id(d) => p.push("derived_from is not a valid layer id".into()),
            _ => {}
        }
        if derived && self.source.is_some() {
            p.push("a derived layer has no source of its own".into());
        }
        if !derived && self.source.is_none() {
            p.push("source is required".into());
        }
        if let Some(s) = &self.source {
            self.check_source(s, "source", &mut p);
        }
        if let Some(o) = &self.offline {
            if let Some(s) = &o.source {
                self.check_source(s, "offline.source", &mut p);
            }
            for (n, v) in [("max_tiles_per_download", o.max_tiles_per_download), ("max_bytes_per_download", o.max_bytes_per_download)] {
                if v == Some(0) {
                    p.push(format!("offline.{n} must be above 0"));
                }
            }
            if o.max_parallel == Some(0) || o.max_parallel.map(|n| n > 32).unwrap_or(false) {
                p.push("offline.max_parallel must be 1 to 32".into());
            }
            if self.transform == Transform::OnlineOnly && o.allowed {
                p.push("an online_only layer cannot allow offline downloads".into());
            }
        }
        if let Some(c) = &self.coverage {
            if let Some(b) = c.bbox {
                if !(b.iter().all(|x| x.is_finite()) && b[0] >= -180.0 && b[2] <= 180.0 && b[1] >= -90.0 && b[3] <= 90.0 && b[1] < b[3]) {
                    p.push("coverage.bbox must be [west, south, east, north] in degrees".into());
                }
            }
        }
        if let Some(u) = &self.update {
            if let Some(c) = &u.check_url {
                if !url_ok(c) {
                    p.push("update.check_url must be https".into());
                }
            }
        }
        p
    }

    fn check_source(&self, s: &Source, at: &str, p: &mut Vec<String>) {
        if !url_ok(&s.url) {
            p.push(format!("{at}.url must be https (http only to this machine)"));
        }
        let types: &[&str] = match self.transform {
            Transform::AsIs => &["pmtiles", "xyz", "tilejson"],
            Transform::RasterWindow => &["cog"],
            Transform::OnlineOnly => &["xyz", "tilejson"],
            _ => &[],
        };
        // offline.source may be a PMTiles archive for any streamed layer
        let ok = types.contains(&s.kind.as_str()) || (at == "offline.source" && s.kind == "pmtiles");
        if !ok {
            p.push(format!("{at}.type {:?} does not go with transform {:?}", s.kind, self.transform));
        }
        if s.kind == "xyz" {
            for h in ["{z}", "{x}", "{y}"] {
                if !s.url.contains(h) {
                    p.push(format!("{at}.url needs {h}"));
                }
            }
        }
        if s.kind == "cog" && !(s.url.contains("{lat}") && s.url.contains("{lon}")) {
            p.push(format!("{at}.url needs {{lat}} and {{lon}} (the grid cell names, like N42 and W114)"));
        }
        if let (Some(a), Some(b)) = (s.minzoom, s.maxzoom) {
            if a > b {
                p.push(format!("{at}.minzoom is above maxzoom"));
            }
        }
        if s.maxzoom.map(|z| z > 24).unwrap_or(false) {
            p.push(format!("{at}.maxzoom is above 24"));
        }
        if let Some(f) = &s.tile_format {
            if norm_format(f).is_none() {
                p.push(format!("{at}.tile_format {f:?} is not mvt, png, webp or jpg"));
            }
        }
        if self.kind == Kind::Elevation && s.encoding.as_deref() != Some("terrarium") && at == "source" {
            p.push("an elevation layer needs source.encoding \"terrarium\"".into());
        }
        if s.kind == "cog" && s.grid_deg.map(|g| !(g > 0.0 && g <= 90.0)).unwrap_or(false) {
            p.push(format!("{at}.grid_deg must be above 0"));
        }
    }

    pub fn offline_allowed(&self) -> bool {
        if self.transform == Transform::OnlineOnly {
            return false;
        }
        self.offline.as_ref().map(|o| o.allowed).unwrap_or(true)
    }

    pub fn max_parallel(&self) -> usize {
        self.offline.as_ref().and_then(|o| o.max_parallel).unwrap_or(4) as usize
    }

    pub fn version(&self) -> &str {
        self.update.as_ref().map(|u| u.version.as_str()).unwrap_or("")
    }

    /// The source area downloads read from.
    pub fn download_source(&self) -> Option<&Source> {
        self.offline.as_ref().and_then(|o| o.source.as_ref()).or(self.source.as_ref())
    }

    pub fn tile_mime(&self) -> &'static str {
        let f = self.source.as_ref().and_then(|s| s.format());
        match (self.transform, f) {
            (Transform::Contours, _) => "application/x-protobuf",
            (Transform::RasterWindow, _) => "image/png",
            (_, Some("mvt")) => "application/x-protobuf",
            (_, Some("png")) => "image/png",
            (_, Some("webp")) => "image/webp",
            (_, Some("jpg")) => "image/jpeg",
            _ => "application/octet-stream",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const GOOD: &str = r#"{"format":1,"id":"base","title":"Base","kind":"vector","transform":"as_is",
      "source":{"type":"tilejson","url":"https://tiles.example.org/planet","minzoom":0,"maxzoom":14,"tile_format":"mvt"},
      "attribution":"x","license":"ODbL","offline":{"allowed":true,"max_tiles_per_download":3000}}"#;

    #[test]
    fn good_definition_parses() {
        let d = LayerDef::parse(GOOD).unwrap();
        assert_eq!(d.id, "base");
        assert!(d.enabled_by_default);
        assert_eq!(d.max_parallel(), 4);
        assert!(d.offline_allowed());
    }

    #[test]
    fn problems_are_all_reported() {
        let bad = GOOD.replace("\"id\":\"base\"", "\"id\":\"Bad Id\"").replace("https://tiles", "ftp://tiles").replace("\"mvt\"", "\"gif\"");
        let e = LayerDef::parse(&bad).unwrap_err();
        assert_eq!(e.code, "bad_json");
        assert!(e.message.contains("id must be") && e.message.contains("https") && e.message.contains("gif"), "{}", e.message);
    }

    #[test]
    fn derived_rules() {
        let h = r#"{"format":1,"id":"hs","title":"H","kind":"elevation","transform":"hillshade","derived_from":"dem"}"#;
        assert!(LayerDef::parse(h).is_ok());
        let h2 = h.replace(r#","derived_from":"dem""#, "");
        assert!(LayerDef::parse(&h2).unwrap_err().message.contains("derived_from"));
        let o = r#"{"format":1,"id":"sat","title":"S","kind":"online-raster","transform":"online_only",
           "source":{"type":"xyz","url":"https://x/{z}/{y}/{x}"},"offline":{"allowed":true}}"#;
        assert!(LayerDef::parse(o).unwrap_err().message.contains("online_only"));
        let o2 = o.replace(r#","offline":{"allowed":true}"#, "");
        let d = LayerDef::parse(&o2).unwrap();
        assert!(!d.offline_allowed());
    }

    #[test]
    fn urls() {
        assert!(url_ok("http://127.0.0.1:1/x") && url_ok("https://a/b") && !url_ok("http://a.com") && !url_ok("http://127.0.0.1.evil.com/"));
    }
}
