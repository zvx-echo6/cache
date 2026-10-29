//! The `locate` tool (docs/TOOLS.md): where a place is, or where the phone is now. With a GPS fix it works without any
//! pack (coordinates and formats only); the nearest town and place names need a pack.

use crate::coord::{plus_code, usng};
use crate::geo::{dms, km_to_mi, round_to};
use crate::{resolve_center, Geocoder, PackSet};
use cache_tool::user::UserPointsSlot;
use cache_tool::{Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Map, Value};
use std::sync::Arc;

pub struct LocateTool {
    packs: Arc<PackSet>,
    geo: Arc<dyn Geocoder>,
    user: UserPointsSlot,
}

impl LocateTool {
    pub fn new(packs: Arc<PackSet>, geo: Arc<dyn Geocoder>) -> LocateTool {
        LocateTool { packs, geo, user: UserPointsSlot::default() }
    }

    /// The user's map layers: `place` matches a layer point by its exact name before the places search.
    pub fn with_user(mut self, user: UserPointsSlot) -> LocateTool {
        self.user = user;
        self
    }
}

fn err(code: &str, detail: impl Into<String>) -> ToolError {
    ToolError::new(code, detail)
}

impl Tool for LocateTool {
    fn name(&self) -> &'static str {
        "locate"
    }

    /// Always available: the phone's own position needs no data.
    fn schema(&self) -> Option<Value> {
        Some(json!({"type": "function", "function": {
            "name": "locate",
            "description": "Where a place is (or where the phone is now): coordinates and the nearest town. Use for \"where am I\" or \"what are the coordinates of X\".",
            "parameters": {"type": "object", "properties": {
                "place": {"type": "string", "minLength": 1, "maxLength": 300,
                          "description": "Place name. Omit for the phone's current location."},
                "near": {"type": "string", "minLength": 1, "maxLength": 200}},
                "required": [], "additionalProperties": false}}}))
    }

    fn run(&self, ctx: &ToolCtx, args: &Value) -> Result<ToolOutput, ToolError> {
        let obj = args.as_object().ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "arguments must be an object"))?;
        let get = |k: &str| -> Result<Option<&str>, ToolError> {
            match obj.get(k) {
                None => Ok(None),
                Some(Value::String(s)) if !s.trim().is_empty() => Ok(Some(s.as_str())),
                Some(_) => Err(err(ToolError::BAD_ARGUMENTS, format!("{k:?} must be a non-empty string"))),
            }
        };
        let (place, near) = (get("place")?, get("near")?);

        // Where: the phone, a saved place, or the best geocoder match (biased toward `near`, else toward the phone).
        let mut kind: Option<(String, String)> = None;
        let (lat, lon, place_name, address, current) = match place {
            None => {
                let c = resolve_center(ctx, &self.packs, &*self.geo, None)?;
                (c.lat, c.lon, c.label, format!("loc:{:.4},{:.4}", c.lat, c.lon), true)
            }
            Some(name) => {
                let layer_point = cache_tool::user::current(&self.user).and_then(|u| u.named(name).into_iter().next());
                if let Some(p) = ctx.places.resolve(name) {
                    (p.lat, p.lon, p.name, format!("loc:{:.4},{:.4}", p.lat, p.lon), false)
                } else if let Some(p) = layer_point {
                    kind = Some((p.kind, p.kind_label));
                    (p.lat, p.lon, p.name, p.address, false)
                } else {
                    if self.packs.current().is_empty() {
                        return Err(err(ToolError::NOT_SET_UP, "no places data is installed, so a place name cannot be looked up"));
                    }
                    let bias = match near {
                        Some(n) => resolve_center(ctx, &self.packs, &*self.geo, Some(n)).ok().map(|c| (c.lat, c.lon)),
                        None => ctx.location.map(|l| (l.lat, l.lon)),
                    };
                    let query = match near {
                        Some(n) if !name.contains(',') => format!("{name}, {n}"),
                        _ => name.to_string(),
                    };
                    let hit = self
                        .geo
                        .forward(&query, bias, 1)
                        .into_iter()
                        .next()
                        .or_else(|| self.geo.forward(name, bias, 1).into_iter().next())
                        .ok_or_else(|| err("geocode_empty", format!("no place matches {:?}", name.trim())).with("query", name.trim()))?;
                    kind = hit.kind_id.clone().zip(hit.kind_label.clone());
                    (hit.lat, hit.lon, hit.label, hit.address, false)
                }
            }
        };

        let mut out = Map::new();
        out.insert("address".into(), json!(address));
        out.insert("place_name".into(), json!(place_name));
        if let Some((id, label)) = kind {
            out.insert("kind".into(), json!(id));
            out.insert("kind_label".into(), json!(label));
        }
        out.insert("lat".into(), json!(round_to(lat, 5)));
        out.insert("lon".into(), json!(round_to(lon, 5)));
        out.insert("lat_lon_dms".into(), json!(dms(lat, lon)));
        if let Some(n) = self.geo.reverse(lat, lon) {
            out.insert("nearest_town".into(), json!(n.label));
            out.insert("distance_to_town_mi".into(), json!(round_to(km_to_mi(n.km), 1)));
        }
        if current {
            if let Some(l) = ctx.location {
                if let Some(a) = l.accuracy_m {
                    out.insert("accuracy_m".into(), json!(a.round() as i64));
                }
                out.insert("fixed_at".into(), json!(l.fixed_at));
            }
        }
        if let Some(u) = usng(lat, lon) {
            out.insert("usng".into(), json!(u));
        }
        if let Some(p) = plus_code(lat, lon) {
            out.insert("plus_code".into(), json!(p));
        }
        Ok(ToolOutput::Json(Value::Object(out)))
    }
}
