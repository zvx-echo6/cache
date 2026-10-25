//! The tool's result and error shapes (docs/TOOLS.md, "navigate").

use crate::resolve::Resolved;
use crate::ModeArg;
use cache_offroad::directions::Directions;
use cache_offroad::offroad_legs::Step;
use cache_offroad::valhalla::Valhalla;
use cache_tool::places::PlaceMatch;
use cache_tool::ToolError;
use serde_json::{json, Map, Value};

/// Steps shown to the model (the context is 8,192 tokens); `steps_truncated` and `steps_omitted` say what was left out.
pub const MAX_STEPS: usize = 15;

const OFFROAD_NOTE: &str = "Part of this route leaves the road network. Off-road legs are estimated from terrain and elevation data, not from marked roads or trails; check conditions and land access before going.";

/// "25 minutes old", "1 day old": the age in plain words, rounded down.
pub fn age_words(secs: i64) -> String {
    let secs = secs.max(0);
    let plural = |n: i64, unit: &str| format!("{n} {unit}{} old", if n == 1 { "" } else { "s" });
    if secs < 60 {
        "less than a minute old".into()
    } else if secs < 3600 {
        plural(secs / 60, "minute")
    } else if secs < 86400 {
        plural(secs / 3600, "hour")
    } else {
        plural(secs / 86400, "day")
    }
}

fn round(x: f64, places: i32) -> f64 {
    let k = 10f64.powi(places);
    (x * k).round() / k
}

/// Miles to one decimal; two for the short ones, so a 0.04 mile step does not read 0.0.
fn mi(x: f64) -> f64 {
    if x >= 0.1 || x == 0.0 {
        round(x, 1)
    } else {
        round(x, 2)
    }
}

fn card_word(c: &str) -> &str {
    match c {
        "N" => "north",
        "NE" => "northeast",
        "E" => "east",
        "SE" => "southeast",
        "S" => "south",
        "SW" => "southwest",
        "W" => "west",
        "NW" => "northwest",
        other => other,
    }
}

/// (verb, -ing form) for one of the router's travel modes.
fn verbs(travel: &str) -> (&'static str, &'static str) {
    match travel {
        "foot" => ("Walk", "walking"),
        "2w" => ("Ride", "riding"),
        _ => ("Drive", "driving"),
    }
}

fn words(s: &str) -> String {
    s.replace('_', " ")
}

/// A sentence for an off-road step (the router gives fields, not text).
fn offroad_instruction(s: &Step, miles: f64) -> String {
    let travel = s.mode.as_deref().unwrap_or("foot");
    let (verb, ing) = verbs(travel);
    let dir = s.cardinal.as_deref().map(card_word).unwrap_or("onward");
    if s.kind == "offroad_follow" {
        let (kind, name) = s.follow.as_ref().map(|f| (f.trail_kind.as_str(), f.name.as_deref())).unwrap_or(("trail", None));
        return match name {
            Some(n) => format!("Follow {n} {dir} for {miles} mi"),
            None => format!("Follow the {kind} {dir} for {miles} mi"),
        };
    }
    if s.type_ == "mode_change" {
        return format!("Change to {ing} here");
    }
    let mut t = format!("{verb} {dir} for {miles} mi");
    if let Some(terr) = s.terrain.as_deref() {
        t.push_str(&format!(" across {}", words(terr)));
    }
    let mut extra: Vec<String> = Vec::new();
    if let Some(g) = s.grade_class.as_deref() {
        if g != "flat" {
            extra.push(words(g));
        }
    }
    if let Some(g) = s.elev_gain_m.filter(|g| *g > 0) {
        extra.push(format!("climbing {g} m"));
    }
    if let Some(l) = s.elev_loss_m.filter(|l| *l > 0) {
        extra.push(format!("descending {l} m"));
    }
    if !extra.is_empty() {
        t.push_str(&format!(" ({})", extra.join(", ")));
    }
    t
}

fn step_json(s: &Step) -> Value {
    let miles = mi(s.distance_m.map(|m| m as f64 / 1000.0 * 0.621371).unwrap_or(s.distance_mi));
    let mut m = Map::new();
    m.insert("index".into(), json!(s.index));
    m.insert("kind".into(), json!(s.kind));
    m.insert("street_names".into(), json!(s.street_names));
    m.insert("distance_mi".into(), json!(miles));
    m.insert("cardinal".into(), json!(s.cardinal));
    let instruction = match (&s.instruction, s.kind.as_str()) {
        (Some(i), _) if s.kind == "road" => i.clone(),
        _ => offroad_instruction(s, miles),
    };
    m.insert("instruction".into(), json!(instruction));
    if s.kind != "road" {
        m.insert("travel".into(), json!(s.mode));
        m.insert("grade_class".into(), json!(s.grade_class));
        m.insert("elev_gain_m".into(), json!(s.elev_gain_m));
        m.insert("elev_loss_m".into(), json!(s.elev_loss_m));
        m.insert("terrain".into(), json!(s.terrain));
        if let Some(f) = &s.follow {
            m.insert("follow".into(), json!({"trail_kind": f.trail_kind, "name": f.name}));
        }
    }
    Value::Object(m)
}

fn matched(r: &Resolved, full: bool) -> Value {
    let mut m = Map::new();
    m.insert("place_name".into(), json!(r.name));
    if full {
        for (k, v) in [("kind", &r.kind), ("street", &r.street), ("locality", &r.locality), ("state", &r.state)] {
            if let Some(v) = v {
                m.insert(k.into(), json!(v));
            }
        }
    }
    m.insert("lat".into(), json!(round(r.lat, 5)));
    m.insert("lon".into(), json!(round(r.lon, 5)));
    Value::Object(m)
}

/// One entry of `other_destination_candidates`.
pub fn candidate(m: &PlaceMatch, minutes: Option<f64>, mode: ModeArg) -> Value {
    let mut o = Map::new();
    o.insert("place_name".into(), json!(m.place_name));
    if let Some(l) = &m.locality {
        o.insert("locality".into(), json!(l));
    }
    if let Some(s) = &m.state {
        o.insert("state".into(), json!(s));
    }
    if let Some(t) = minutes {
        o.insert(format!("{}_min", mode.travel().name()), json!(round(t, 1)));
    }
    Value::Object(o)
}

#[allow(clippy::too_many_arguments)]
pub fn result(
    d: &Directions,
    from: &Resolved,
    to: &Resolved,
    mode: ModeArg,
    location_bias: &str,
    others: Vec<Value>,
    nearest_search: Option<Value>,
    region: (String, String),
    gap_warnings: bool,
    snap_m: f64,
) -> Value {
    let mut o = Map::new();
    // the framework numbers this object: "address" becomes "n" (and "ok":true goes in front)
    o.insert("address".into(), json!(format!("nav:{}", d.route_id)));
    o.insert("mode".into(), json!(mode.name()));
    o.insert("location_bias".into(), json!(location_bias));
    o.insert("from_matched".into(), matched(from, false));
    o.insert("to_matched".into(), matched(to, true));
    if !others.is_empty() {
        o.insert("other_destination_candidates".into(), Value::Array(others));
    }
    if let Some(n) = nearest_search {
        o.insert("nearest_search".into(), n);
    }
    o.insert("distance_mi".into(), json!(mi(d.distance_mi)));
    o.insert("distance_km".into(), json!(round(d.distance_km, 1)));
    o.insert("duration_minutes".into(), json!(round(d.duration_s as f64 / 60.0, 1)));
    o.insert("major_roads".into(), json!(d.major_roads.iter().map(|(n, _)| n.clone()).collect::<Vec<_>>()));
    o.insert("step_count".into(), json!(d.steps.len()));
    o.insert("steps".into(), Value::Array(d.steps.iter().take(MAX_STEPS).map(step_json).collect()));
    o.insert("steps_truncated".into(), json!(d.steps.len() > MAX_STEPS));
    o.insert("steps_omitted".into(), json!(d.steps.len().saturating_sub(MAX_STEPS)));
    let offroad_km: f64 = d.steps.iter().filter(|s| s.kind != "road").map(|s| s.distance_m.map(|m| m as f64 / 1000.0).unwrap_or(s.distance_km)).sum();
    if offroad_km > 0.0 {
        o.insert("offroad_mi".into(), json!(mi(offroad_km * 0.621371)));
        o.insert("offroad_note".into(), json!(OFFROAD_NOTE));
    }
    let mut warnings: Vec<Value> = Vec::new();
    if gap_warnings {
        // no off-road data: an end away from the road network is only reported
        for e in [&d.from, &d.to].into_iter().flatten() {
            if e.snap_distance_m as f64 > snap_m {
                warnings.push(json!({"code": "offroad_unavailable", "gap_m": e.snap_distance_m}));
            }
        }
    } else {
        for w in &d.warnings {
            warnings.push(json!({"code": "offroad_unavailable", "gap_m": w.gap_m}));
        }
    }
    if !warnings.is_empty() {
        o.insert("warnings".into(), Value::Array(warnings));
    }
    o.insert("map_region".into(), json!(region.0));
    o.insert("map_region_age".into(), json!(region.1));
    Value::Object(o)
}

/// A failed route as the tool's error. A trip that starts or ends where no map is installed is `not_set_up`.
pub fn route_error(d: &Directions, valhalla: &dyn Valhalla, from: (f64, f64), to: (f64, f64), mode: ModeArg) -> ToolError {
    let e = d.errors.first();
    let (code, message) = e.map(|e| (e.code.as_str(), e.message.as_str())).unwrap_or(("internal", "the route failed"));
    if code == "out_of_coverage" {
        return ToolError::new(ToolError::NOT_SET_UP, "no installed map region covers this trip");
    }
    if matches!(code, "no_route" | "too_far") && !matches!(mode, ModeArg::OffroadVehicle | ModeArg::OffroadFoot) {
        let costing = mode.travel().costing();
        for (end, p) in [("start", from), ("destination", to)] {
            if valhalla.locate(p.0, p.1, costing).is_none() {
                return ToolError::new(ToolError::NOT_SET_UP, format!("no installed map region covers the {end}"));
            }
        }
    }
    ToolError::new("route_failed", message).with("reason", code)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn miles_and_ages() {
        assert_eq!(mi(0.3), 0.3);
        assert_eq!(mi(0.04), 0.04);
        assert_eq!(mi(131.37), 131.4);
        assert_eq!(age_words(12 * 86400 + 5), "12 days old");
        assert_eq!(age_words(86400), "1 day old");
    }
}
