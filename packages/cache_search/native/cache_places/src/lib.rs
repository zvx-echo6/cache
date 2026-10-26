//! cache_places: Cache's places data. The `places.sqlite` pack format (`schema`, read by `pack`), the offline geocoder
//! (`geocoder`), the coordinate formats (`coord`) and the two tools built on them: `nearby` and `locate`.
//!
//! The host registers both tools with `tools(&PlacesCfg)` when its config has a `places` section:
//! `{"packs": ["/path/places.sqlite", ...]}`. Packs are opened on demand, so a pack downloaded later is picked up
//! without reopening the handle, and `nearby` leaves itself out of the tool schemas while no pack is installed.

pub mod coord;
pub mod embedpack;
pub mod fixture;
pub mod geo;
pub mod geocoder;
pub mod kind;
pub mod locate;
pub mod map;
pub mod nearby;
pub mod pack;
pub mod source;
pub mod schema;

pub use geocoder::{GeoHit, Geocoder, HitKind, Nearest, PackGeocoder};
pub use locate::LocateTool;
pub use map::PlacesCore;
pub use nearby::NearbyTool;
pub use pack::{Pack, PackSet};
pub use source::PackPlaceSource;

use cache_tool::{Tool, ToolCtx, ToolError};
use chrono::DateTime;
use serde::Deserialize;
use std::sync::Arc;

/// The `places` section of the `cs_open` config.
#[derive(Debug, Clone, Deserialize)]
pub struct PlacesCfg {
    pub packs: Vec<String>,
}

/// `nearby` and `locate`, sharing one set of packs and one geocoder.
pub fn tools(cfg: &PlacesCfg) -> Vec<Box<dyn Tool>> {
    tools_and_source(cfg).0
}

/// The same tools plus the `PlaceSource` the navigate tool resolves names and `to_type` through, over the same packs.
pub fn tools_and_source(cfg: &PlacesCfg) -> (Vec<Box<dyn Tool>>, Arc<dyn cache_tool::places::PlaceSource>) {
    let (_, tools, source) = core_tools_and_source(cfg);
    (tools, source)
}

/// `tools_and_source` plus the [`PlacesCore`] the map's search box (`cs_map_search`) runs on, over the same packs and geocoder.
pub fn core_tools_and_source(cfg: &PlacesCfg) -> (Arc<PlacesCore>, Vec<Box<dyn Tool>>, Arc<dyn cache_tool::places::PlaceSource>) {
    let core = Arc::new(PlacesCore::new(cfg));
    let (packs, geo) = (core.packs.clone(), core.geo.clone());
    let tools: Vec<Box<dyn Tool>> = vec![Box::new(NearbyTool::new(packs.clone(), geo.clone())), Box::new(LocateTool::new(packs.clone(), geo.clone()))];
    (core, tools, Arc::new(PackPlaceSource::new(packs, geo)))
}

/// "12 days old" for a pack built at `built_at`, as of `now` (both ISO 8601 with offset); None when either is unreadable.
pub fn age_words(now: &str, built_at: &str) -> Option<String> {
    let secs = (DateTime::parse_from_rfc3339(now.trim()).ok()?.timestamp() - DateTime::parse_from_rfc3339(built_at.trim()).ok()?.timestamp()).max(0);
    let plural = |n: i64, unit: &str| format!("{n} {unit}{} old", if n == 1 { "" } else { "s" });
    Some(if secs < 60 {
        "less than a minute old".into()
    } else if secs < 3600 {
        plural(secs / 60, "minute")
    } else if secs < 86400 {
        plural(secs / 3600, "hour")
    } else {
        plural(secs / 86400, "day")
    })
}

/// Where a tool's question is centred: a saved place, a place the geocoder finds, or the phone's location.
pub(crate) struct Center {
    pub lat: f64,
    pub lon: f64,
    /// "current location", the saved place's name, or the geocoder's label.
    pub label: String,
}

pub(crate) fn resolve_center(ctx: &ToolCtx, packs: &PackSet, geo: &dyn Geocoder, near: Option<&str>) -> Result<Center, ToolError> {
    match near {
        Some(name) => {
            if let Some(p) = ctx.places.resolve(name) {
                return Ok(Center { lat: p.lat, lon: p.lon, label: p.name });
            }
            if packs.current().is_empty() {
                return Err(ToolError::new(ToolError::NOT_SET_UP, "no places data is installed, so a place name cannot be looked up"));
            }
            let bias = ctx.location.map(|l| (l.lat, l.lon));
            match geo.forward(name, bias, 1).into_iter().next() {
                Some(h) => Ok(Center { lat: h.lat, lon: h.lon, label: h.label }),
                None => Err(ToolError::new("geocode_empty", format!("no place matches {:?}", name.trim())).with("query", name.trim())),
            }
        }
        None => match ctx.location {
            Some(l) => Ok(Center { lat: l.lat, lon: l.lon, label: "current location".into() }),
            None => Err(ToolError::new(ToolError::NO_LOCATION, "no place was given and the phone's location is not known")),
        },
    }
}
