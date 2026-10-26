//! The `live_data` tool: one generic tool for every live source (docs/TOOLS.md, "live_data").
//!
//! `schema()` is built at run time from the installed definitions (the `source` enum and each source's one-line
//! description); `run()` reads the stored data with the same code the app's screens use (`Live::view`) and returns
//! TOOLS.md's shape with an `"address"` on each item where the model sees `"n"`: the tool framework numbers the
//! addresses and adds `"ok": true`. Age and expiry are computed from `ctx.now`, never from the system clock, so
//! captures reproduce.
//!
//! The place asked about is a saved place, "lat,lon" text, a name the places pack's geocoder resolves (`ctx.geocoder`: the
//! same resolver `navigate` and `locate` use, so "Island Park, Idaho", "island park" and a misspelling find one town), or the
//! phone's position when none is given. The data is that of the nearest place it was downloaded for within
//! `live_radius_km`; the result says which place that was and how far it is from the one asked about.

use crate::map::{age_words, date_of, stamp};
use crate::{address, here_key, now_from, Live, LiveCfg, Place};
use cache_tool::places::parse_latlon;
use cache_tool::{Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Map, Value};

/// At most this many items go to the model (the context is 8,192 tokens); `more` says how many were left out.
pub const MAX_ITEMS: usize = 12;

pub struct LiveDataTool {
    live: Live,
}

impl LiveDataTool {
    pub fn new(cfg: LiveCfg) -> LiveDataTool {
        LiveDataTool { live: Live::new(cfg) }
    }

    pub fn live(&self) -> &Live {
        &self.live
    }
}

fn err(code: &str, detail: impl Into<String>) -> ToolError {
    ToolError::new(code, detail)
}

/// Data for a place closer than this to the one asked about is "the same place": nothing extra is said.
const SAME_PLACE_KM: f64 = 1.0;

/// The place a question is about.
struct Asked {
    name: String,
    lat: f64,
    lon: f64,
    /// The saved place's key, or the phone-position key: data stored under it is taken whatever the distance.
    key: Option<String>,
}

/// Whole km for the model (at least 1).
fn km_words(km: f64) -> i64 {
    (km.round() as i64).max(1)
}

fn resolve_asked(ctx: &ToolCtx, text: Option<&str>) -> Result<Asked, ToolError> {
    match text {
        Some(name) => {
            if let Some(p) = ctx.places.resolve(name) {
                return Ok(Asked { name: p.name, lat: p.lat, lon: p.lon, key: Some(p.key) });
            }
            if let Some((lat, lon)) = parse_latlon(name) {
                return Ok(Asked { name: name.trim().to_string(), lat, lon, key: None });
            }
            let near = ctx.location.map(|l| (l.lat, l.lon));
            match ctx.geocoder {
                Some(g) => g
                    .resolve(name, near)
                    .map(|(name, lat, lon)| Asked { name, lat, lon, key: None })
                    .ok_or_else(|| err("geocode_empty", format!("no place called {:?} was found", name.trim()))),
                None => Err(err("geocode_empty", format!("no saved place called {:?}", name.trim()))),
            }
        }
        None => match ctx.location {
            Some(loc) => Ok(Asked { name: "current location".into(), lat: loc.lat, lon: loc.lon, key: Some(here_key(loc.lat, loc.lon)) }),
            None => Err(err(ToolError::NO_LOCATION, "no place was given and the phone's location is not known")),
        },
    }
}

impl Tool for LiveDataTool {
    fn name(&self) -> &'static str {
        "live_data"
    }

    /// `None` when no source definition is installed.
    fn schema(&self) -> Option<Value> {
        let (defs, _) = self.live.defs();
        if defs.is_empty() {
            return None;
        }
        let list: Vec<String> = defs.iter().map(|l| format!("{} = {}", l.def.id, l.def.description.trim().trim_end_matches('.'))).collect();
        let ids: Vec<&str> = defs.iter().map(|l| l.def.id.as_str()).collect();
        Some(json!({"type": "function", "function": {
            "name": "live_data",
            "description": format!(
                "Downloaded live data for a place. Data is downloaded while online and expires. Sources on this phone: {}.",
                list.join("; ")
            ),
            "parameters": {"type": "object", "properties": {
                "source": {"type": "string", "enum": ids, "description": "Which source to read."},
                "place": {"type": "string", "minLength": 1, "maxLength": 200,
                          "description": "A saved place or town. Omit for the phone's current location."}},
                "required": ["source"], "additionalProperties": false}}}))
    }

    fn run(&self, ctx: &ToolCtx, args: &Value) -> Result<ToolOutput, ToolError> {
        let obj = args.as_object().ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "arguments must be an object"))?;
        if let Some(k) = obj.keys().find(|k| *k != "source" && *k != "place") {
            return Err(err(ToolError::BAD_ARGUMENTS, format!("unknown argument {k:?}")));
        }
        let source = obj
            .get("source")
            .and_then(Value::as_str)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "\"source\" (string) is required"))?;
        let place_arg = match obj.get("place") {
            None => None,
            Some(Value::String(s)) if !s.trim().is_empty() && s.chars().count() <= 200 => Some(s.as_str()),
            Some(_) => return Err(err(ToolError::BAD_ARGUMENTS, "\"place\" must be a string of 1 to 200 characters")),
        };
        let now = now_from(Some(ctx.now)).map_err(|e| err(ToolError::INTERNAL, e.message))?;

        let (defs, _) = self.live.defs();
        if defs.is_empty() {
            return Err(err(ToolError::NOT_SET_UP, "no live data sources are installed"));
        }
        let Some(l) = defs.into_iter().find(|l| l.def.id == source) else {
            return Err(err(ToolError::UNKNOWN_SOURCE, format!("no live source called {source:?}")));
        };
        let asked = resolve_asked(ctx, place_arg)?;
        let c = self.live.db().map_err(|e| err(ToolError::INTERNAL, e.message))?;
        let radius = self.live.cfg.live_radius_km;
        let stored = self.live.locations(&c, &l.def.id, asked.lat, asked.lon).map_err(|e| err(ToolError::INTERNAL, e.message))?;
        // the places data was downloaded for: the asked place's own row whatever the distance, the others within the radius
        let usable: Vec<&(Place, f64)> =
            stored.iter().filter(|(p, km)| *km <= radius || asked.key.as_deref() == Some(p.key.as_str())).collect();
        if usable.is_empty() {
            return Err(match stored.first() {
                None => err(ToolError::NO_DATA, format!("no {} data has been downloaded for {}", l.def.id, asked.name)),
                Some((p, km)) => err(
                    ToolError::NO_DATA,
                    format!(
                        "no {} data within {} km of {}; the nearest place with data is {}, {} km away",
                        l.def.id,
                        radius,
                        asked.name,
                        p.name,
                        km_words(*km)
                    ),
                ),
            });
        }
        // the nearest whose data has not expired; when all have, the nearest (and the expired error says so)
        let mut chosen: Option<(&(Place, f64), crate::View)> = None;
        for u in &usable {
            let Some(v) = self.live.view(&c, &l, &u.0, now).map_err(|e| err(ToolError::INTERNAL, e.message))? else { continue };
            let fresh = !v.expired;
            if chosen.is_none() || fresh {
                chosen = Some((u, v));
            }
            if fresh {
                break;
            }
        }
        let Some((&(ref place, km), v)) = chosen else {
            return Err(err(ToolError::NO_DATA, format!("no {} data has been downloaded for {}", l.def.id, asked.name)));
        };
        let own = asked.key.as_deref() == Some(place.key.as_str());
        let shown = if own { asked.name.clone() } else { place.name.clone() };
        let off = v.zone();
        if v.expired {
            return Err(err(ToolError::EXPIRED, format!("{} data expired {}", l.def.id, date_of(v.row.valid_until, &off))));
        }
        let more = v.items.len().saturating_sub(MAX_ITEMS);
        let items: Vec<Value> = v
            .items
            .iter()
            .take(MAX_ITEMS)
            .map(|i| {
                let mut m = Map::new();
                m.insert("address".into(), json!(address(&l.def.id, &place.key, &i.key)));
                m.insert("label".into(), json!(i.label));
                if let Some(t) = &i.time {
                    m.insert("time".into(), json!(t));
                }
                let mut f = Map::new();
                for (k, x) in &i.fields.0 {
                    f.insert(k.clone(), json!(x));
                }
                m.insert("fields".into(), Value::Object(f));
                Value::Object(m)
            })
            .collect();
        let mut out = Map::new();
        out.insert("source".into(), json!({"id": l.def.id, "title": l.def.title, "provider": l.def.provider}));
        out.insert("place".into(), json!(shown));
        if !own && km >= SAME_PLACE_KM {
            // the data is for another place than the one asked about: say which, and how far apart they are
            out.insert("asked_place".into(), json!(asked.name));
            out.insert("distance_from_asked_km".into(), json!(km_words(km)));
        }
        out.insert("fetched_at".into(), json!(stamp(v.row.fetched_at, &off)));
        out.insert("valid_until".into(), json!(stamp(v.row.valid_until, &off)));
        out.insert("age".into(), json!(age_words(v.age_secs())));
        out.insert("expired".into(), json!(false));
        let none = items.is_empty();
        out.insert("items".into(), Value::Array(items));
        if more > 0 {
            out.insert("more".into(), json!(more));
        }
        if none {
            out.insert("none".into(), json!(true));
        }
        if let Some(n) = &v.row.not_covered_after {
            out.insert("not_covered_after".into(), json!(n));
        }
        Ok(ToolOutput::Json(Value::Object(out)))
    }
}
