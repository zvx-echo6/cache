//! `cache_tool::places::PlaceSource` over the installed packs: what the navigate tool resolves `to`, `from` and `near`
//! names through, and where its `to_type` categories and "nearest place of a type" come from.

use crate::geo::haversine_km;
use crate::nearby::{installed_categories, ranked, MAX_KM};
use crate::pack::{PackSet, PlaceRow};
use crate::Geocoder as PackGeo;
use cache_tool::places::{Geocoder, GeocodeAnswer, GeocodeQuery, NearestQuery, PlaceMatch, PlaceSource};
use cache_tool::ToolError;
use std::sync::Arc;

pub struct PackPlaceSource {
    packs: Arc<PackSet>,
    geo: Arc<dyn PackGeo>,
}

impl PackPlaceSource {
    pub fn new(packs: Arc<PackSet>, geo: Arc<dyn PackGeo>) -> PackPlaceSource {
        PackPlaceSource { packs, geo }
    }
}

fn from_row(r: &PlaceRow, title: &str, from: Option<(f64, f64)>) -> PlaceMatch {
    let mut m = PlaceMatch::new(r.name.clone().unwrap_or_else(|| title.to_string()), r.lat, r.lon);
    m.kind = r.category.clone().or_else(|| r.kind.clone());
    m.street = r.street.clone();
    m.locality = r.locality.clone();
    m.county = r.county.clone();
    m.state = r.state.clone();
    m.distance_km = from.map(|(la, lo)| haversine_km(la, lo, r.lat, r.lon));
    m.osm_category = crate::geocoder::osm_category(r);
    m
}

impl Geocoder for PackPlaceSource {
    /// The pack's best match for the text: the same `forward` that `navigate` and `locate` use, which also takes a town with a
    /// typing slip in it when nothing fits the name well.
    fn resolve(&self, text: &str, near: Option<(f64, f64)>) -> Option<(String, f64, f64)> {
        let text = text.trim();
        if text.is_empty() || self.packs.current().is_empty() {
            return None;
        }
        let hit = self.geo.forward(text, near, 1).into_iter().next()?;
        Some((hit.label, hit.lat, hit.lon))
    }
}

impl PlaceSource for PackPlaceSource {
    fn geocoder(&self) -> Option<&dyn cache_tool::places::Geocoder> {
        Some(self)
    }

    fn categories(&self) -> Option<Vec<String>> {
        let cats = installed_categories(&self.packs.current());
        if cats.is_empty() {
            None
        } else {
            Some(cats.into_iter().map(|(id, _, _)| id).collect())
        }
    }

    fn geocode(&self, q: &GeocodeQuery) -> Result<GeocodeAnswer, ToolError> {
        if self.packs.current().is_empty() {
            return Err(ToolError::new(ToolError::NOT_SET_UP, "no places data is installed"));
        }
        let text = q.text.trim();
        let mut hits = match q.near.map(str::trim).filter(|n| !n.is_empty()) {
            Some(n) if !text.contains(',') => self.geo.forward(&format!("{text}, {n}"), q.bias, q.limit.max(1)),
            _ => Vec::new(),
        };
        if hits.is_empty() {
            hits = self.geo.forward(text, q.bias, q.limit.max(1));
        }
        let matches = hits
            .into_iter()
            .map(|h| {
                let mut m = PlaceMatch::new(h.name, h.lat, h.lon);
                m.kind = h.what;
                m.street = h.street;
                m.locality = h.locality;
                m.county = h.county;
                m.state = h.state;
                m.osm_category = h.osm_category;
                m.distance_km = q.bias.map(|(la, lo)| haversine_km(la, lo, h.lat, h.lon));
                m
            })
            .collect();
        Ok(GeocodeAnswer { matches, searched_within_km: None })
    }

    fn nearest(&self, q: &NearestQuery) -> Result<GeocodeAnswer, ToolError> {
        let packs = self.packs.current();
        let cats = installed_categories(&packs);
        if cats.is_empty() {
            return Err(ToolError::new(ToolError::NOT_SET_UP, "no places data is installed"));
        }
        let Some((id, title, _)) = cats.iter().find(|(id, _, _)| id == q.category) else {
            return Ok(GeocodeAnswer { matches: Vec::new(), searched_within_km: Some(MAX_KM) });
        };
        let ranked = ranked(&packs, id, q.from.0, q.from.1, q.limit.max(1)).map_err(|e| ToolError::new(ToolError::INTERNAL, e))?;
        let matches = ranked
            .iter()
            .map(|r| {
                let mut m = from_row(&r.row, title, Some(q.from));
                m.distance_km = Some(r.km);
                // navi's tiers: 1 = a hospital with an emergency department listing (confirmed), 3 = a hospital without one (likely).
                m.er_tier = match r.tier.as_deref() {
                    Some("confirmed") => Some(1),
                    Some("likely") => Some(3),
                    _ => None,
                };
                m
            })
            .collect();
        Ok(GeocodeAnswer { matches, searched_within_km: Some(MAX_KM) })
    }
}
