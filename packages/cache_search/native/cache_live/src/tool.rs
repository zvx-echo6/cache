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
//! When there is no fresh data for the place (none stored, or expired) and the host's `LiveFetcher` allows the source, the tool
//! downloads once for the place asked about (`fetch_for`: the same fetch and quotas as `cs_live_fetch`, never for a source without
//! its key) and answers from the stored row. Without a fetcher, or when it denies the source, nothing is downloaded. Data past its
//! refresh interval but still valid is never downloaded during the call: the background refresh handles it. When data due for a
//! refresh was not refreshed, the result says why in `not_refreshed` (`not_refreshed_words`): the host's reason for denying the
//! fetch, or (expired or missing data only) the failed download's.
//!
//! `when` narrows the items to one period (`Period`): the tool, not the model, turns "tomorrow" or "friday" into the place's local
//! dates. Items in effect now (current conditions, an alert already running) always stay; dated items stay when they overlap the
//! period. A period the saved data does not reach is one numbered item saying so, never an empty list.

use crate::map::{age_words, date_of, minute_of, stamp};
use crate::tz::Zone;
use crate::{address, here_key, now_from, Live, LiveCfg, Place};
use chrono::{DateTime, Datelike, Duration, NaiveDate, NaiveDateTime, NaiveTime, Timelike, Weekday};
use cache_tool::places::parse_latlon;
use cache_tool::{NotAllowed, Tool, ToolCtx, ToolError, ToolOutput};
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

/// live_data's `not_refreshed`: why data that was due for a refresh was not refreshed. No address, status code or error text.
fn not_refreshed_words(why: Result<NotAllowed, &str>) -> String {
    match why {
        Ok(NotAllowed::SwitchedOff) => "this source is switched off".into(),
        Ok(NotAllowed::Offline) => "no connection".into(),
        Ok(NotAllowed::MeteredOff) => "mobile data updates are off".into(),
        Err(code) => format!(
            "refresh failed: {}",
            match code {
                ToolError::QUOTA => "daily limit reached",
                ToolError::KEY_MISSING => "API key missing",
                ToolError::BAD_RESPONSE => "the source sent bad data",
                // fetch_failed, and any other failure of the download
                _ => "couldn't reach the source",
            }
        ),
    }
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

/// The most days `when: "next_days"` takes (the forecast holds 16).
pub const MAX_DAYS: i64 = 16;

/// The period `when` asks about, as instants [`from`, `to`) in the place's zone.
struct Period {
    from: i64,
    to: i64,
    /// The first local day of the period, for the "no forecast" item.
    day: NaiveDate,
    /// The period is over (a date before today).
    past: bool,
}

const WHEN_VALUES: &str = "today, tonight, tomorrow, a weekday name, a date YYYY-MM-DD, or next_days";

fn local_midnight(zone: &Zone, d: NaiveDate) -> i64 {
    local_at(zone, d, 0, 0)
}

fn local_at(zone: &Zone, d: NaiveDate, h: u32, m: u32) -> i64 {
    let n = d.and_time(NaiveTime::from_hms_opt(h, m, 0).expect("valid time"));
    // A wall-clock time skipped by daylight saving falls an hour later.
    zone.local(&n).or_else(|| zone.local(&(n + Duration::hours(1)))).map(|t| t.timestamp()).unwrap_or_else(|| n.and_utc().timestamp())
}

/// `when` (and `days`) as a period around `now` in `zone`.
fn period(when: &str, days: Option<i64>, now: i64, zone: &Zone) -> Result<Period, ToolError> {
    let local = DateTime::from_timestamp(now, 0).map(|d| d.with_timezone(&zone.offset_at(now)).naive_local()).unwrap_or_default();
    let today = local.date();
    let day_of = |d: NaiveDate| Period { from: local_midnight(zone, d).max(now), to: local_midnight(zone, d + Duration::days(1)), day: d, past: d < today };
    let w = when.trim().to_lowercase();
    if days.is_some() && w != "next_days" {
        return Err(err(ToolError::BAD_ARGUMENTS, "\"days\" goes with when=\"next_days\""));
    }
    Ok(match w.as_str() {
        "today" => day_of(today),
        "tomorrow" => day_of(today + Duration::days(1)),
        // the night ahead, 18:00 (or now, if later) to 07:00; before 07:00, the rest of the night in progress
        "tonight" if local.hour() < 7 => Period { from: now, to: local_at(zone, today, 7, 0), day: today, past: false },
        "tonight" => Period {
            from: local_at(zone, today, 18, 0).max(now),
            to: local_at(zone, today + Duration::days(1), 7, 0),
            day: today,
            past: false,
        },
        "next_days" => {
            let n = days.unwrap_or(MAX_DAYS);
            Period { from: now, to: local_midnight(zone, today + Duration::days(n)), day: today, past: false }
        }
        _ => {
            if let Ok(wd) = w.parse::<Weekday>() {
                // the next time that day comes; today's own name is today
                let ahead = (7 + wd.num_days_from_monday() as i64 - today.weekday().num_days_from_monday() as i64) % 7;
                day_of(today + Duration::days(ahead))
            } else if let Ok(d) = NaiveDate::parse_from_str(&w, "%Y-%m-%d") {
                day_of(d)
            } else {
                return Err(err(ToolError::BAD_ARGUMENTS, format!("\"when\" must be one of: {WHEN_VALUES}")));
            }
        }
    })
}

/// When an item starts and ends, and whether it is a dated period (a forecast day) rather than a moment (current conditions,
/// an alert's onset). `None` when its time cannot be read: such an item is always kept.
fn item_span(i: &crate::map::Item, zone: &Zone) -> Option<(i64, Option<i64>, bool)> {
    let t = i.time.as_deref()?.trim();
    if let Ok(d) = NaiveDate::parse_from_str(t, "%Y-%m-%d") {
        return Some((local_midnight(zone, d), i.ends, true));
    }
    for f in ["%Y-%m-%dT%H:%M:%S%:z", "%Y-%m-%dT%H:%M%:z", "%Y-%m-%dT%H:%M:%S%.f%:z"] {
        if let Ok(d) = DateTime::parse_from_str(t, f) {
            return Some((d.timestamp(), i.ends, false));
        }
    }
    for f in ["%Y-%m-%dT%H:%M:%S", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M"] {
        if let Ok(n) = NaiveDateTime::parse_from_str(t, f) {
            return Some((zone.local(&n)?.timestamp(), i.ends, false));
        }
    }
    None
}

/// Whether an item belongs in the answer for `p`.
fn in_period(i: &crate::map::Item, p: &Period, now: i64, zone: &Zone) -> bool {
    match item_span(i, zone) {
        None => true,
        // in effect now: kept whatever the period, as the Now item carries the data's present
        Some((start, _, false)) if start <= now => true,
        Some((start, end, _)) => start < p.to && end.unwrap_or(i64::MAX) > p.from,
    }
}

/// Whether a timed item (not a whole day) covers all of `p`.
fn spans(i: &crate::map::Item, p: &Period, zone: &Zone) -> bool {
    matches!(item_span(i, zone), Some((start, Some(end), false)) if start <= p.from && end >= p.to)
}

/// "Fri Nov 14": a local day as the labels write it.
fn day_words(d: NaiveDate) -> String {
    d.format("%a %b %-d").to_string()
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
                "Downloaded live data for a place. Data is downloaded while online and expires. Sources on this phone: {}. \
                 Set when to read one period: {WHEN_VALUES} (with days).",
                list.join("; ")
            ),
            "parameters": {"type": "object", "properties": {
                "source": {"type": "string", "enum": ids, "description": "Which source to read."},
                "place": {"type": "string", "minLength": 1, "maxLength": 200,
                          "description": "A saved place or town. Omit for the phone's current location."},
                "when": {"type": "string", "minLength": 1, "maxLength": 20,
                         "description": "Which period. Omit for everything saved."},
                "days": {"type": "integer", "minimum": 1, "maximum": MAX_DAYS,
                         "description": "With when=next_days: how many days, today included."}},
                "required": ["source"], "additionalProperties": false}}}))
    }

    fn run(&self, ctx: &ToolCtx, args: &Value) -> Result<ToolOutput, ToolError> {
        let obj = args.as_object().ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "arguments must be an object"))?;
        if let Some(k) = obj.keys().find(|k| !matches!(k.as_str(), "source" | "place" | "when" | "days")) {
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
        let when = match obj.get("when") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) if !s.trim().is_empty() && s.chars().count() <= 20 => Some(s.as_str()),
            Some(_) => return Err(err(ToolError::BAD_ARGUMENTS, format!("\"when\" must be one of: {WHEN_VALUES}"))),
        };
        let days = match obj.get("days") {
            None | Some(Value::Null) => None,
            Some(v) => match v.as_i64() {
                Some(n) if (1..=MAX_DAYS).contains(&n) => Some(n),
                _ => return Err(err(ToolError::BAD_ARGUMENTS, format!("\"days\" must be a whole number from 1 to {MAX_DAYS}"))),
            },
        };
        if days.is_some() && when.is_none() {
            return Err(err(ToolError::BAD_ARGUMENTS, "\"days\" goes with when=\"next_days\""));
        }
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
        // the stored data for the place; when there is none that is fresh, one on-demand fetch if the host allows it. Data past
        // its refresh interval but still valid is left to the background refresh. When due data is not refreshed, the reason
        // (`not_refreshed`): what blocks the refresh, or for expired or missing data the failed download's.
        let mut picked = self.pick(&c, &l, &asked, now);
        let refresh_secs = l.def.refresh_minutes as i64 * 60;
        let unusable = picked.as_ref().map(|p| p.2.expired).unwrap_or(true);
        let due = unusable || picked.as_ref().map(|p| now >= p.2.row.fetched_at + refresh_secs).unwrap_or(true);
        let mut not_refreshed: Option<String> = None;
        if let Some(f) = ctx.live_fetcher.filter(|_| due) {
            if !f.can_fetch(&l.def.id) {
                not_refreshed = f.not_allowed(&l.def.id).map(|n| not_refreshed_words(Ok(n)));
            } else if unusable {
                let got = match f.stand_in_failure(&l.def.id) {
                    Some(code) => Err(err(code, "")),
                    None => self.fetch_for(ctx, f.key_for(&l.def.id), &l, &asked),
                };
                if let Err(e) = got {
                    not_refreshed = Some(not_refreshed_words(Err(&e.code)));
                }
                picked = self.pick(&c, &l, &asked, now);
            }
        }
        let with_reason = |e: ToolError| match &not_refreshed {
            Some(r) => e.with_top("not_refreshed", r.as_str()),
            None => e,
        };
        let (place, km, v) = match picked {
            Ok(p) => p,
            // nothing stored: the no_data error, with the reason it was not refreshed
            Err(e) => return Err(with_reason(e)),
        };
        let own = asked.key.as_deref() == Some(place.key.as_str());
        let shown = if own { asked.name.clone() } else { place.name.clone() };
        let off = v.zone();
        if v.expired {
            // a failed refresh is said by not_refreshed alone (it replaced the error's refresh_failed code)
            return Err(with_reason(err(ToolError::EXPIRED, format!("{} data expired {}", l.def.id, date_of(v.row.valid_until, &off)))));
        }
        let period = when.map(|w| period(w, days, now, &off)).transpose()?;
        let chosen: Vec<&crate::map::Item> = match &period {
            Some(p) => {
                let mut c: Vec<_> = v.items.iter().filter(|i| in_period(i, p, now, &off)).collect();
                // An item made for the period itself (the night ahead) answers it: whole days that only overlap it go.
                if c.iter().any(|i| spans(i, p, &off)) {
                    c.retain(|i| !matches!(item_span(i, &off), Some((_, _, true))));
                }
                c
            }
            None => v.items.iter().collect(),
        };
        let more = chosen.len().saturating_sub(MAX_ITEMS);
        let items: Vec<Value> = chosen
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
        // A period the saved data does not cover (a forecast that ends sooner, or a day that is over): said as an item.
        if let Some(p) = &period {
            let beyond = v.row.not_covered_after.is_some() && p.from >= v.row.valid_until;
            if p.past || beyond {
                let mut f = Map::new();
                if p.past {
                    f.insert("Status".into(), json!("that day is over"));
                } else {
                    f.insert("Status".into(), json!("not in the saved data"));
                    f.insert("Saved data runs to".into(), json!(date_of(v.row.valid_until - 1, &off)));
                }
                let mut m = Map::new();
                m.insert("address".into(), json!(address(&l.def.id, &place.key, "none")));
                m.insert("label".into(), json!(format!("No {} for {} in the saved data", l.def.title.to_lowercase(), day_words(p.day))));
                m.insert("fields".into(), Value::Object(f));
                m.insert("not_covered".into(), json!(true));
                items.push(Value::Object(m));
            }
        }
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
        if let Some(r) = &not_refreshed {
            out.insert("not_refreshed".into(), json!(r));
        }
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
