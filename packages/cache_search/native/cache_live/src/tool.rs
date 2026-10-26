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
//!
//! When there is no fresh data for the place and the host's `LiveFetcher` allows the source, the tool downloads once for the place
//! asked about (`fetch_for`: the same fetch and quotas as `cs_live_fetch`, never for a source without its key) and answers from the
//! stored row. Without a fetcher, or when it denies the source, nothing is downloaded.

use crate::map::{age_words, date_of, minute_of, stamp};
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

    /// The stored data to answer from: the nearest place with data that has not expired (the asked place's own row whatever the
    /// distance, others within `live_radius_km`); when all have expired, the nearest. The error says why nothing can be used.
    fn pick(&self, c: &rusqlite::Connection, l: &crate::Loaded, asked: &Asked, now: i64) -> Result<(Place, f64, crate::View), ToolError> {
        let radius = self.live.cfg.live_radius_km;
        let stored = self.live.locations(c, &l.def.id, asked.lat, asked.lon).map_err(|e| err(ToolError::INTERNAL, e.message))?;
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
            let Some(v) = self.live.view(c, l, &u.0, now).map_err(|e| err(ToolError::INTERNAL, e.message))? else { continue };
            let fresh = !v.expired;
            if chosen.is_none() || fresh {
                chosen = Some((u, v));
            }
            if fresh {
                break;
            }
        }
        match chosen {
            Some((u, v)) => Ok((u.0.clone(), u.1, v)),
            None => Err(err(ToolError::NO_DATA, format!("no {} data has been downloaded for {}", l.def.id, asked.name))),
        }
    }

    /// The on-demand fetch: one download for the place asked about, through the same path and quotas as `cs_live_fetch`, stored
    /// under the place's key (a saved place's own, else the position rounded to 0.01 degrees so nearby asks share a row, which is
    /// pruned like the phone's other positions). A source that needs a key the host does not hold is never fetched. Nothing in the
    /// error holds the key (the fetch scrubs it).
    fn fetch_for(&self, ctx: &ToolCtx, key: Option<String>, l: &crate::Loaded, asked: &Asked) -> Result<(), ToolError> {
        let needs_key = l.def.api_key.as_ref().map(|k| k.required).unwrap_or(false) || l.def.basic_auth.as_ref().map(|b| b.required).unwrap_or(false);
        if needs_key && key.as_deref().map(str::is_empty).unwrap_or(true) {
            return Err(err(ToolError::KEY_MISSING, format!("{} needs an API key, and none is set on this phone", l.def.id)));
        }
        let mut place = Map::new();
        place.insert("key".into(), json!(asked.key.clone().unwrap_or_else(|| here_key(asked.lat, asked.lon))));
        place.insert("name".into(), json!(asked.name));
        place.insert("lat".into(), json!(asked.lat));
        place.insert("lon".into(), json!(asked.lon));
        if let Some(f) = &asked.facts {
            for (k, v) in [("state", &f.state), ("state_name", &f.state_name), ("county", &f.county), ("country", &f.country)] {
                if let Some(v) = v.as_ref().filter(|v| !v.trim().is_empty()) {
                    place.insert(k.into(), json!(v));
                }
            }
        }
        let mut req = Map::new();
        req.insert("source".into(), json!(l.def.id));
        req.insert("place".into(), Value::Object(place));
        req.insert("now".into(), json!(ctx.now));
        if let Some(k) = key.filter(|k| !k.is_empty()) {
            req.insert("api_key".into(), json!(k));
        }
        self.live.fetch(&Value::Object(req).to_string(), ctx.places).map(|_| ()).map_err(|e| {
            let code = match e.code {
                "fetch_failed" => ToolError::FETCH_FAILED,
                "quota" => ToolError::QUOTA,
                "key_missing" => ToolError::KEY_MISSING,
                "bad_response" => ToolError::BAD_RESPONSE,
                _ => ToolError::INTERNAL,
            };
            err(code, e.message)
        })
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
    /// What the places pack knows about a geocoded place (state, county, country), carried into an on-demand fetch.
    facts: Option<cache_tool::places::ResolvedPlace>,
}

/// Whole km for the model (at least 1).
fn km_words(km: f64) -> i64 {
    (km.round() as i64).max(1)
}

fn resolve_asked(ctx: &ToolCtx, text: Option<&str>) -> Result<Asked, ToolError> {
    match text {
        Some(name) => {
            if let Some(p) = ctx.places.resolve(name) {
                return Ok(Asked { name: p.name, lat: p.lat, lon: p.lon, key: Some(p.key), facts: None });
            }
            if let Some((lat, lon)) = parse_latlon(name) {
                return Ok(Asked { name: name.trim().to_string(), lat, lon, key: None, facts: None });
            }
            let near = ctx.location.map(|l| (l.lat, l.lon));
            match ctx.geocoder {
                Some(g) => g
                    .resolve_full(name, near)
                    .map(|p| Asked { name: p.name.clone(), lat: p.lat, lon: p.lon, key: None, facts: Some(p) })
                    .ok_or_else(|| err("geocode_empty", format!("no place called {:?} was found", name.trim()))),
                None => Err(err("geocode_empty", format!("no saved place called {:?}", name.trim()))),
            }
        }
        None => match ctx.location {
            Some(loc) => Ok(Asked { name: "current location".into(), lat: loc.lat, lon: loc.lon, key: Some(here_key(loc.lat, loc.lon)), facts: None }),
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
        // the stored data for the place; when there is none that is fresh, one on-demand fetch if the host allows it
        let mut picked = self.pick(&c, &l, &asked, now);
        let mut refresh_failed: Option<ToolError> = None;
        if picked.as_ref().map(|p| p.2.expired).unwrap_or(true) {
            if let Some(f) = ctx.live_fetcher.filter(|f| f.can_fetch(&l.def.id)) {
                if let Err(e) = self.fetch_for(ctx, f.key_for(&l.def.id), &l, &asked) {
                    refresh_failed = Some(e);
                }
                picked = self.pick(&c, &l, &asked, now);
            }
        }
        let (place, km, v) = match picked {
            Ok(p) => p,
            // nothing stored and the fetch failed: the fetch's own reason is the more useful one
            Err(e) => return Err(refresh_failed.unwrap_or(e)),
        };
        let own = asked.key.as_deref() == Some(place.key.as_str());
        let shown = if own { asked.name.clone() } else { place.name.clone() };
        let off = v.zone();
        if v.expired {
            let mut e = err(ToolError::EXPIRED, format!("{} data expired {}", l.def.id, date_of(v.row.valid_until, &off)));
            if let Some(r) = refresh_failed {
                e = e.with("refresh_failed", r.code);
            }
            return Err(e);
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
        let mut items = items;
        let none = items.is_empty();
        if none {
            // nothing to report is still something to cite: one numbered entry, in an item's shape, saying so
            let label = l.def.none_label.as_deref().filter(|s| !s.trim().is_empty()).unwrap_or(&l.def.title);
            let mut f = Map::new();
            f.insert("Status".into(), json!("none active"));
            f.insert("Checked".into(), json!(minute_of(v.row.fetched_at, &off)));
            f.insert("Age".into(), json!(age_words(v.age_secs())));
            let mut m = Map::new();
            m.insert("address".into(), json!(address(&l.def.id, &place.key, "none")));
            m.insert("label".into(), json!(label));
            m.insert("time".into(), json!(stamp(v.row.fetched_at, &off)));
            m.insert("fields".into(), Value::Object(f));
            m.insert("none_active".into(), json!(true));
            items.push(Value::Object(m));
        }
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
