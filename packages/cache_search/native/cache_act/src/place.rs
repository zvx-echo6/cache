//! A `place` field: resolved the way `navigate` resolves `to` (docs/ACTIONS.md): "lat,lon" text, then a saved place by key or
//! name, then the places pack. What the user sees on the confirm card is built here too.

use cache_tool::places::parse_latlon;
use cache_tool::ToolCtx;
use serde_json::{json, Map, Value};

#[derive(Clone, Debug, PartialEq)]
pub struct Point {
    pub lat: f64,
    pub lon: f64,
    /// The saved place's name or the pack's display name; none for bare coordinates.
    pub name: Option<String>,
    /// The saved place's label ("home"), when it has one.
    pub label: Option<String>,
}

impl Point {
    /// `{"lat","lon","name"?,"label"?}`, the machine values at full precision.
    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("lat".into(), json!(self.lat));
        m.insert("lon".into(), json!(self.lon));
        if let Some(n) = &self.name {
            m.insert("name".into(), json!(n));
        }
        if let Some(l) = &self.label {
            m.insert("label".into(), json!(l));
        }
        Value::Object(m)
    }

    /// What the card shows: `44.21000, -114.93000 (12 mi NE of Stanley)` for coordinates (just the coordinates when no places
    /// data names a town near them), `Elk camp (44.21000, -114.93000)` for a named place.
    pub fn display(&self, ctx: &ToolCtx) -> String {
        let coords = format!("{:.5}, {:.5}", self.lat, self.lon);
        match &self.name {
            Some(n) => format!("{n} ({coords})"),
            None => match ctx.geocoder.and_then(|g| g.describe_point(self.lat, self.lon)) {
                Some(rel) => format!("{coords} ({rel})"),
                None => coords,
            },
        }
    }
}

/// `None` when nothing fits. The phone's fix, when there is one, is the point to prefer when several places share the name.
pub fn resolve(ctx: &ToolCtx, text: &str) -> Option<Point> {
    let text = text.trim();
    if text.is_empty() {
        return None;
    }
    if let Some((lat, lon)) = parse_latlon(text) {
        return Some(Point { lat, lon, name: None, label: None });
    }
    if let Some(p) = ctx.places.resolve(text) {
        return Some(Point { lat: p.lat, lon: p.lon, name: Some(p.name), label: p.label });
    }
    let near = ctx.location.map(|l| (l.lat, l.lon));
    let r = ctx.geocoder?.resolve_full(text, near)?;
    Some(Point { lat: r.lat, lon: r.lon, name: Some(r.name), label: None })
}
