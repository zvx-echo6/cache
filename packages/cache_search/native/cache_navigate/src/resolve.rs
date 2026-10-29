//! Names to coordinates: "lat,lon" text, the user's saved places, a point of the user's map layers by its exact name, then the
//! places pack.

use cache_offroad::navigate::Waypoint;
use cache_tool::places::{GeocodeQuery, PlaceDetails, PlaceMatch, PlaceSource};
use cache_tool::user::{UserPoint, UserPoints};
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
    /// A layer point's layer name (`kind` "layer_point").
    pub kind_label: Option<String>,
    pub street: Option<String>,
    pub locality: Option<String>,
    pub county: Option<String>,
    pub state: Option<String>,
    pub distance_km: Option<f64>,
    pub er_tier: Option<i64>,
    pub osm: Option<String>,
    /// Phone, website and hours, for a place from the places data only.
    pub details: Option<PlaceDetails>,
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
            kind_label: None,
            street: None,
            locality: None,
            county: None,
            state: None,
            distance_km: None,
            er_tier: None,
            osm: None,
            details: None,
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
            kind_label: m.kind_label,
            street: m.street,
            locality: m.locality,
            county: m.county,
            state: m.state,
            distance_km: m.distance_km,
            er_tier: m.er_tier,
            osm: m.osm_category,
            details: m.details,
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
    pub user: Option<Arc<dyn UserPoints>>,
}

impl Resolver<'_, '_> {
    /// A layer point as a matched place: its layer as `kind_label`, the nearest town as `locality`.
    fn layer_match(&self, p: UserPoint, bias: Option<(f64, f64)>) -> PlaceMatch {
        let mut m = PlaceMatch::new(p.name, p.lat, p.lon);
        m.kind = Some(p.kind);
        m.kind_label = Some(p.kind_label);
        m.locality = p.locality.or_else(|| self.source.as_ref().and_then(|s| s.geocoder()).and_then(|g| g.nearest_town(p.lat, p.lon)));
        m.distance_km = bias.map(|(la, lo)| cache_offroad::grid::haversine_m(la, lo, p.lat, p.lon) / 1000.0);
        m
    }

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
        // a point of the user's map layers by its exact name; the same name in other layers goes to the other candidates
        let points = self.user.as_ref().map(|u| u.named(text)).unwrap_or_default();
        if !points.is_empty() {
            let mut it = points.into_iter().map(|p| self.layer_match(p, bias));
            let mut r = Resolved::from_match(it.next().expect("not empty"));
            if with_others {
                r.others = it.collect();
            }
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
