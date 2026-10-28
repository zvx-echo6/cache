//! The `routing` section of the `cs_open` config:
//! `{"valhalla": {"tiles": ".../tiles.tar", "shim": ".../valhalla_shim.dll", "region": "Idaho"},
//!   "offroad": {"pack": ".../offroad.sqlite", "elevation": ".../elevation.pmtiles", "max_cells": 8000000}}`.
//! `tiles` may also be a folder of tiles (`<level>/<aaa>/<bbb>/<ccc>.gph`, the downloaded regions), and may be left out when
//! the regions engine says which folder (the `regions` section of the `cs_open` config); `region` then names what is there.
//! `region` and `max_cells` are optional. Without `valhalla` (or while its files are missing) the tool is not offered;
//! without `offroad` (or while either file is missing) road routing works and an off-road request is `not_set_up`.

use serde::Deserialize;
use std::path::Path;

#[derive(Clone, Debug, Default, Deserialize)]
pub struct NavigateCfg {
    #[serde(default)]
    pub valhalla: Option<ValhallaCfg>,
    #[serde(default)]
    pub offroad: Option<OffroadCfg>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct ValhallaCfg {
    /// The Valhalla tile extract (`tiles.tar`) of the installed map region, or a folder of tiles. Empty: the folder the
    /// regions engine gives (see `TileStream::tile_dir`).
    #[serde(default)]
    pub tiles: String,
    /// The shim library (`valhalla_shim.dll`, `libvalhalla_shim.so`).
    pub shim: String,
    /// The region's name for `map_region`; default: the folder a tiles.tar belongs to ("packs/idaho/valhalla/tiles.tar" is
    /// "Idaho"), nothing for a folder of tiles.
    #[serde(default)]
    pub region: Option<String>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct OffroadCfg {
    pub pack: String,
    pub elevation: String,
    /// Cell cap of one off-road search (default 20 million; the phone is about 8 million).
    #[serde(default)]
    pub max_cells: Option<usize>,
}

/// "…/idaho/valhalla/tiles.tar" is "Idaho"; "…/north-idaho/tiles.tar" is "North Idaho".
pub fn region_from_path(tiles: &str) -> String {
    let dir = Path::new(tiles).parent();
    let dir = match dir {
        Some(d) if d.file_name().map(|n| n == "valhalla").unwrap_or(false) => d.parent(),
        d => d,
    };
    let name = dir.and_then(|d| d.file_name()).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    name.split(|c| c == '-' || c == '_' || c == ' ')
        .filter(|w| !w.is_empty())
        .map(|w| {
            let mut c = w.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn region_names() {
        assert_eq!(region_from_path("E:/cache-data/packs/idaho/valhalla/tiles.tar"), "Idaho");
        assert_eq!(region_from_path("/data/maps/north-idaho/tiles.tar"), "North Idaho");
    }
}
