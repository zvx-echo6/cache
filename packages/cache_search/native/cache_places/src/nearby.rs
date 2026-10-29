//! The `nearby` tool (docs/TOOLS.md): the nearest places of one kind, ranked by straight-line distance.
//!
//! The category enum and the one-line description of each category are filled at run time from the category tables
//! of the installed packs, so `schema()` is None until a pack with places is installed.

use crate::geo::{bearing_deg, compass8, haversine_km, km_to_mi, round_to};
use crate::kind::shown;
use crate::feed::{FeedSlot, TOOL_PREPARE_WAIT};
use crate::pack::{Pack, PackSet, PlaceRow};
use crate::{age_words, resolve_center, Geocoder};
use cache_tool::hours::{hours_note, open_status};
use cache_tool::{Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Map, Value};
use std::sync::Arc;

/// How far a search reaches. The nearest hospital may be a long way off in the backcountry; a far answer beats none.
pub const MAX_KM: f64 = 300.0;
const DEFAULT_LIMIT: usize = 5;

pub struct NearbyTool {
    packs: Arc<PackSet>,
    geo: Arc<dyn Geocoder>,
    feed: FeedSlot,
}

impl NearbyTool {
    pub fn new(packs: Arc<PackSet>, geo: Arc<dyn Geocoder>) -> NearbyTool {
        NearbyTool { packs, geo, feed: FeedSlot::default() }
    }

    /// The feed that fetches the places tiles around the centre before a search (the places core's).
    pub fn with_feed(mut self, feed: FeedSlot) -> NearbyTool {
        self.feed = feed;
        self
    }
}

/// (id, title, description) of every category that has places in at least one installed pack, in first-pack order.
pub(crate) fn installed_categories(packs: &[Arc<Pack>]) -> Vec<(String, String, String)> {
    let mut out: Vec<(String, String, String)> = Vec::new();
    for p in packs {
        for c in &p.categories {
            let offered = c.place_count > 0
                || c.fallback().is_some_and(|f| p.category(&f.category).is_some_and(|h| h.place_count > 0));
            if offered && !out.iter().any(|(id, _, _)| *id == c.id) {
                out.push((c.id.clone(), c.title.clone(), c.description.clone()));
            }
        }
    }
    out
}

/// One result of a category search.
pub(crate) struct Ranked {
    pub row: PlaceRow,
    pub km: f64,
    /// For categories with a fallback (emergency rooms): "confirmed" or "likely".
    pub tier: Option<String>,
    pub note: Option<String>,
}

/// The nearest places of a category across the packs, nearest first, deduplicated. A category with a fallback rule
/// (emergency_room: hospitals that probably have one) lists its own places as the primary tier, then the fallback
/// category's places (minus hospitals an emergency room row already stands for). They rank by distance, but a
/// fallback place goes ahead of a primary one only when it is nearer by the rule's margin (10 miles).
pub(crate) fn ranked(packs: &[Arc<Pack>], category: &str, lat: f64, lon: f64, limit: usize) -> Result<Vec<Ranked>, String> {
    let gather = |cat: &str, want: usize| -> Result<Vec<(PlaceRow, f64)>, String> {
        let mut found: Vec<(PlaceRow, f64)> = Vec::new();
        for p in packs {
            found.extend(p.nearby(cat, lat, lon, MAX_KM, want).map_err(|e| e.message)?);
        }
        found.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
        let mut kept: Vec<(PlaceRow, f64)> = Vec::new();
        for (r, km) in found {
            let dup = kept.iter().any(|(k, _)| {
                k.source_id == r.source_id
                    || (k.name.as_deref().map(norm) == r.name.as_deref().map(norm) && haversine_km(k.lat, k.lon, r.lat, r.lon) < 0.15)
            });
            if !dup {
                kept.push((r, km));
            }
        }
        Ok(kept)
    };
    let fallback = packs.iter().find_map(|p| p.category(category).and_then(|c| c.fallback()));
    let Some(f) = fallback else {
        return Ok(gather(category, limit * 3)?
            .into_iter()
            .take(limit)
            .map(|(row, km)| Ranked { row, km, tier: None, note: None })
            .collect());
    };
    let mut primary: std::collections::VecDeque<(PlaceRow, f64)> = gather(category, limit * 3)?.into();
    let mut likely: std::collections::VecDeque<(PlaceRow, f64)> = gather(&f.category, limit * 6)?
        .into_iter()
        .filter(|(r, _)| !packs.iter().any(|p| p.matched.contains(&r.source_id)))
        .collect();
    let mut out = Vec::new();
    while out.len() < limit {
        let take_likely = match (primary.front(), likely.front()) {
            (None, None) => break,
            (Some(_), None) => false,
            (None, Some(_)) => true,
            (Some(p), Some(l)) => l.1 + f.advantage_km < p.1,
        };
        let (row, km) = if take_likely { likely.pop_front() } else { primary.pop_front() }.expect("checked above");
        let (tier, note) = if take_likely { (f.tier.clone(), f.note.clone()) } else { (f.primary_tier.clone(), None) };
        out.push(Ranked { row, km, tier: Some(tier), note });
    }
    Ok(out)
}

fn err(code: &str, detail: impl Into<String>) -> ToolError {
    ToolError::new(code, detail)
}

fn norm(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(|c| c.to_lowercase()).collect()
}

impl Tool for NearbyTool {
    fn name(&self) -> &'static str {
        "nearby"
    }

    fn schema(&self) -> Option<Value> {
        let cats = installed_categories(&self.packs.current());
        if cats.is_empty() {
            return None;
        }
        let ids: Vec<&str> = cats.iter().map(|(id, _, _)| id.as_str()).collect();
        let list: Vec<String> = cats.iter().map(|(id, _, d)| format!("{id} = {}", d.trim().trim_end_matches('.'))).collect();
        Some(json!({"type": "function", "function": {
            "name": "nearby",
            "description": "List the nearest places of one kind, without directions. Use navigate instead when the person wants to go there.",
            "parameters": {"type": "object", "properties": {
                "category": {"type": "string", "enum": ids, "description": format!("Kind of place. {}.", list.join("; "))},
                "near": {"type": "string", "minLength": 1, "maxLength": 200,
                         "description": "Town and state, or a place name. Omit to search around the phone's current location."},
                "limit": {"type": "integer", "minimum": 1, "maximum": 10, "default": 5}},
                "required": ["category"], "additionalProperties": false}}}))
    }

    fn run(&self, ctx: &ToolCtx, args: &Value) -> Result<ToolOutput, ToolError> {
        let obj = args.as_object().ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "arguments must be an object"))?;
        let category = obj
            .get("category")
            .and_then(Value::as_str)
            .ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "\"category\" (string) is required"))?;
        let near = match obj.get("near") {
            None => None,
            Some(Value::String(s)) if !s.trim().is_empty() => Some(s.as_str()),
            Some(_) => return Err(err(ToolError::BAD_ARGUMENTS, "\"near\" must be a non-empty string")),
        };
        let limit = match obj.get("limit") {
            None => DEFAULT_LIMIT,
            Some(v) => v.as_u64().filter(|n| (1..=10).contains(n)).ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "\"limit\" must be 1 to 10"))? as usize,
        };

        // The places tiles around the centre first, when the host plugged in a feed (it fetches only online).
        if self.feed.get().is_some() {
            if let Ok(c) = resolve_center(ctx, &self.packs, &*self.geo, near) {
                self.feed.prepare(c.lat, c.lon, TOOL_PREPARE_WAIT);
            }
        }
        let packs = self.packs.current();
        let cats = installed_categories(&packs);
        if cats.is_empty() {
            return Err(err(ToolError::NOT_SET_UP, "no places data is installed"));
        }
        let Some((cat_id, cat_title, _)) = cats.iter().find(|(id, _, _)| id == category) else {
            return Err(err(ToolError::BAD_ARGUMENTS, format!("category: no places of kind {category:?} are installed")));
        };

        let center = resolve_center(ctx, &self.packs, &*self.geo, near)?;
        let covering = packs.iter().filter(|p| p.covers(center.lat, center.lon)).min_by(|a, b| {
            a.meta.area().partial_cmp(&b.meta.area()).unwrap_or(std::cmp::Ordering::Equal)
        });
        let Some(region) = covering else {
            return Err(err(ToolError::NOT_SET_UP, format!("no installed map region covers {}", center.label)));
        };

        let kept = ranked(&packs, cat_id, center.lat, center.lon, limit).map_err(|e| err(ToolError::INTERNAL, e))?;
        if kept.is_empty() {
            return Err(err("nearby_empty", format!("no {} within {} km of {}", cat_title.to_lowercase(), MAX_KM as u32, center.label))
                .with("category", category)
                .with("searched_within_km", MAX_KM as u32));
        }

        let places: Vec<Value> = kept
            .iter()
            .map(|Ranked { row: r, km, tier, note }| {
                let mut m = Map::new();
                m.insert("address".into(), json!(format!("place:{}", r.source_id)));
                // An unnamed place is called by its kind ("Drinking water tap", "Picnic shelter"), never by a bare generic word. In a
                // pack without kinds it is called by its own category ("Hospital" for a likely emergency room), else the one asked for.
                let own_title = r.category.as_deref().and_then(|c| packs.iter().find_map(|p| p.category(c)).map(|c| c.title.clone()));
                let shown = shown(&packs, r, &own_title.unwrap_or_else(|| cat_title.clone()));
                m.insert("name".into(), json!(shown.name));
                shown.put_kind(&mut m);
                for (k, v) in [("street", &r.street), ("locality", &r.locality), ("state", &r.state)] {
                    if let Some(v) = v {
                        m.insert(k.into(), json!(v));
                    }
                }
                m.insert("distance_mi".into(), json!(round_to(km_to_mi(*km), 1)));
                m.insert("direction".into(), json!(compass8(bearing_deg(center.lat, center.lon, r.lat, r.lon))));
                for (k, v) in [("phone", &r.phone), ("website", &r.website), ("hours", &r.hours)] {
                    if let Some(v) = v {
                        m.insert(k.into(), json!(v));
                    }
                }
                m.insert("open_status".into(), json!(open_status(r.hours.as_deref(), ctx.now)));
                for (k, v) in [("er_tier", tier), ("note", note)] {
                    if let Some(v) = v {
                        m.insert(k.into(), json!(v));
                    }
                }
                Value::Object(m)
            })
            .collect();

        let age = age_words(ctx.now, &region.meta.built_at);
        let mut out = Map::new();
        out.insert("category".into(), json!(category));
        out.insert("center".into(), json!(center.label));
        out.insert("ranked_by".into(), json!("distance"));
        out.insert("places".into(), Value::Array(places));
        if kept.iter().any(|k| k.row.hours.is_some()) {
            out.insert("hours_note".into(), json!(hours_note(age.as_deref())));
        }
        out.insert("map_region".into(), json!(region.meta.region_name));
        if let Some(age) = age {
            out.insert("map_region_age".into(), json!(age));
        }
        Ok(ToolOutput::Json(Value::Object(out)))
    }
}
