//! `cache_tool::places::PlaceSource` over the installed packs: what the navigate tool resolves `to`, `from` and `near`
//! names through, and where its `to_type` categories and "nearest place of a type" come from.

use crate::geo::haversine_km;
use crate::nearby::{installed_categories, MAX_KM};
use crate::pack::{PackSet, PlaceRow};
use crate::Geocoder;
use cache_tool::places::{GeocodeAnswer, GeocodeQuery, NearestQuery, PlaceMatch, PlaceSource};
use cache_tool::ToolError;
use std::sync::Arc;

pub struct PackPlaceSource {
    packs: Arc<PackSet>,
    geo: Arc<dyn Geocoder>,
}

impl PackPlaceSource {
    pub fn new(packs: Arc<PackSet>, geo: Arc<dyn Geocoder>) -> PackPlaceSource {
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
    if r.category.as_deref() == Some("emergency_room") {
        // An emergency-department listing that sits in an OSM hospital is tier 1; a listing on its own is tier 2.
        m.er_tier = Some(if r.source == "overture+osm" { 1 } else { 2 });
    }
    m
}

impl PlaceSource for PackPlaceSource {
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
        let mut found: Vec<(PlaceRow, f64)> = Vec::new();
        for p in &packs {
            found.extend(p.nearby(id, q.from.0, q.from.1, MAX_KM, q.limit.max(1) * 2).map_err(|e| ToolError::new(ToolError::INTERNAL, e.message))?);
        }
        found.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
        let mut kept: Vec<(PlaceRow, f64)> = Vec::new();
        for (r, km) in found {
            if !kept.iter().any(|(k, _)| k.source_id == r.source_id) {
                kept.push((r, km));
            }
            if kept.len() >= q.limit {
                break;
            }
        }
        let matches = kept
            .iter()
            .map(|(r, km)| {
                let mut m = from_row(r, title, Some(q.from));
                m.distance_km = Some(*km);
                m
            })
            .collect();
        Ok(GeocodeAnswer { matches, searched_within_km: Some(MAX_KM) })
    }
}
