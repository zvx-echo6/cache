//! Names to coordinates: "lat,lon" text, the user's saved places, then the places pack.

use cache_offroad::navigate::Waypoint;
use cache_tool::places::{GeocodeQuery, PlaceMatch, PlaceSource};
use cache_tool::{ToolCtx, ToolError};
use serde_json::Value;
use std::sync::Arc;

/// A start or destination as the tool resolved it (AIDA's `_place` fields; what the source does not know is None).
#[derive(Clone, Debug)]
pub(crate) struct Resolved {
    pub name: String,
    pub lat: f64,
    pub lon: f64,
    pub kind: Option<String>,
    pub street: Option<String>,
    pub locality: Option<String>,
    pub county: Option<String>,
    pub state: Option<String>,
    pub distance_km: Option<f64>,
    pub er_tier: Option<i64>,
    pub osm: Option<String>,
    /// Where a route to the place goes, when the places data says it is not the place's point.
    pub arrival: Option<(f64, f64)>,
    /// Other matches the places pack found for the same text.
    pub others: Vec<PlaceMatch>,
}

impl Resolved {
    pub fn point(name: String, lat: f64, lon: f64) -> Resolved {
        Resolved {
            name,
            lat,
            lon,
            kind: None,
            street: None,
            locality: None,
            county: None,
            state: None,
            distance_km: None,
            er_tier: None,
            osm: None,
            arrival: None,
            others: vec![],
        }
    }
    /// AIDA's "sender node position", on the phone: the GPS fix.
    pub fn here(lat: f64, lon: f64) -> Resolved {
        Resolved::point("current location".into(), lat, lon)
    }
    pub fn from_match(m: PlaceMatch) -> Resolved {
        Resolved {
            name: m.place_name,
            lat: m.lat,
            lon: m.lon,
            kind: m.kind,
            street: m.street,
            locality: m.locality,
            county: m.county,
            state: m.state,
            distance_km: m.distance_km,
            er_tier: m.er_tier,
            osm: m.osm_category,
            arrival: m.arrival,
            others: vec![],
        }
    }
    pub fn waypoint(&self) -> Waypoint {
        match &self.osm {
            Some(c) => Waypoint::place_with_category(&self.name, self.lat, self.lon, c),
            None => Waypoint::place(&self.name, self.lat, self.lon),
        }
        .with_arrival(self.arrival)
    }
}

pub use cache_tool::places::parse_latlon;

pub(crate) struct Resolver<'a, 'c> {
    pub ctx: &'a ToolCtx<'c>,
    pub source: Option<Arc<dyn PlaceSource>>,
}

impl Resolver<'_, '_> {
    fn exact(&self, text: &str) -> Option<Resolved> {
        if let Some((lat, lon)) = parse_latlon(text) {
            return Some(Resolved::point(text.trim().to_string(), lat, lon));
        }
        self.ctx.places.resolve(text).map(|p| Resolved::point(p.name, p.lat, p.lon))
    }

    /// The town the trip is in (`near`): coordinates, a saved place, or the places pack's first match.
    pub fn near_point(&self, text: &str) -> Option<Resolved> {
        if let Some(r) = self.exact(text) {
            return Some(r);
        }
        let src = self.source.as_ref()?;
        let ans = src.geocode(&GeocodeQuery { text, near: None, bias: None, limit: 1 }).ok()?;
        ans.matches.into_iter().next().map(Resolved::from_match)
    }

    /// A place by name. `which` is "from" or "to" for the error. Nothing found is `geocode_empty` (AIDA's fields: which,
    /// query, searched_within_km; no detail).
    pub fn named(&self, text: &str, which: &str, near: Option<&str>, bias: Option<(f64, f64)>, with_others: bool) -> Result<Resolved, ToolError> {
        if let Some(r) = self.exact(text) {
            return Ok(r);
        }
        let mut searched = None;
        if let Some(src) = &self.source {
            let ans = src.geocode(&GeocodeQuery { text, near, bias, limit: 4 })?;
            searched = ans.searched_within_km;
            let mut it = ans.matches.into_iter();
            if let Some(first) = it.next() {
                let mut r = Resolved::from_match(first);
                if with_others {
                    r.others = it.collect();
                }
                return Ok(r);
            }
        }
        Err(ToolError::new("geocode_empty", "")
            .with("which", which)
            .with("query", text)
            .with("searched_within_km", searched.map(Value::from).unwrap_or(Value::Null)))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn latlon_text() {
        assert_eq!(parse_latlon("44.0543,-115.4237"), Some((44.0543, -115.4237)));
        assert_eq!(parse_latlon(" 42.536 , -113.792 "), Some((42.536, -113.792)));
        assert_eq!(parse_latlon("42.536 -113.792"), Some((42.536, -113.792)));
        assert_eq!(parse_latlon("Burley, Idaho"), None);
        assert_eq!(parse_latlon("91,0"), None);
        assert_eq!(parse_latlon("1,2,3"), None);
    }
}
