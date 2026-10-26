//! The tool's result and error shapes: AIDA's navigate contract (nav_runtime.py `navigate()`), field for field, plus
//! `address` (numbering) and `map_region` / `map_region_age` (Cache's own; AIDA's `pins` and `bridge` do not apply).

use crate::resolve::Resolved;
use cache_offroad::directions::Directions;
use cache_offroad::offroad_legs::{round_py, Step};
use cache_tool::ToolError;
use serde_json::{json, Map, Value};

/// Steps shown to the model: AIDA's NAVIGATE_MAX_DIRECTIONS.
pub const MAX_STEPS: usize = 12;

/// AIDA's OFFROAD_NOTE, verbatim.
const OFFROAD_NOTE: &str = "Off-road legs are straight lines between turn points over a ~30 m elevation grid with no path on the ground; follow legs run along the mapped road, track or trail they name.";

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

/// A number as Python prints a float (5.0, not 5).
fn py(x: f64) -> String {
    if x.fract() == 0.0 {
        format!("{x:.1}")
    } else {
        format!("{x}")
    }
}

fn is_offroad(s: &Step) -> bool {
    s.kind == "offroad" || s.kind == "offroad_follow"
}

fn terrain(s: &Step) -> Option<String> {
    s.terrain.as_deref().filter(|t| !t.is_empty() && *t != "unknown").map(|t| t.replace('_', " "))
}

fn travel_phrase(t: &str) -> String {
    match t {
        "foot" => "On foot".into(),
        "2w" => "By dirt bike or mountain bike".into(),
        "4w" => "By ATV".into(),
        "vehicle" => "High-clearance 4x4 only".into(),
        other => format!("By {other}"),
    }
}

/// AIDA's `_step_text`: navi's instruction, or for an off-road step what to follow, heading, length, slope, climb and
/// terrain, prefixed with how it is travelled (except walking legs on a walking trip).
pub(crate) fn step_text(s: &Step, trip_mode: &str) -> String {
    if let Some(i) = s.instruction.as_deref().filter(|i| !i.is_empty()) {
        return i.to_string();
    }
    if !is_offroad(s) {
        return s.type_.replace('_', " ");
    }
    let cardinal = s.cardinal.as_deref().unwrap_or("");
    let mut text = if s.kind == "offroad_follow" {
        let f = s.follow.as_ref();
        let what = match f.and_then(|f| f.name.clone()) {
            Some(n) => n,
            None => format!("the {}", f.map(|f| f.trail_kind.as_str()).filter(|k| !k.is_empty()).unwrap_or("trail")),
        };
        format!("Follow {what} {cardinal} {} mi", py(s.distance_mi))
    } else {
        format!("Off-road {cardinal} {} mi", py(s.distance_mi))
    }
    .replace("  ", " ");
    if let Some(g) = s.grade_class.as_deref().filter(|g| !g.is_empty()) {
        text.push_str(&format!(", {}", g.replace('_', " ")));
    }
    if let Some(t) = terrain(s) {
        text.push_str(&format!(", {t}"));
    }
    let climb: Vec<String> = [
        s.elev_gain_m.filter(|g| *g != 0).map(|g| format!("+{g} m")),
        s.elev_loss_m.filter(|l| *l != 0).map(|l| format!("-{l} m")),
    ]
    .into_iter()
    .flatten()
    .collect();
    if !climb.is_empty() {
        text.push_str(&format!(" ({})", climb.join(" ")));
    }
    match s.mode.as_deref() {
        Some(t) if !(t == "foot" && trip_mode == "walk") => format!("{}: {text}", travel_phrase(t)),
        _ => text,
    }
}

/// AIDA's `_model_steps`: over the cap, every off-road step is kept (the last MAX_STEPS of them if they alone exceed it)
/// and the first road steps fill the rest, in route order. Returns the kept indices and the omitted counts.
fn model_steps(steps: &[Step]) -> (Vec<usize>, Vec<(&'static str, usize)>) {
    if steps.len() <= MAX_STEPS {
        return ((0..steps.len()).collect(), vec![]);
    }
    let off: Vec<usize> = (0..steps.len()).filter(|&i| is_offroad(&steps[i])).collect();
    let mut keep: Vec<usize> = off[off.len().saturating_sub(MAX_STEPS)..].to_vec();
    let room = MAX_STEPS - keep.len();
    keep.extend((0..steps.len()).filter(|&i| !is_offroad(&steps[i])).take(room));
    keep.sort();
    let kept_off = keep.iter().filter(|&&i| is_offroad(&steps[i])).count();
    let mut omitted = vec![("road_steps_omitted", (steps.len() - off.len()) - (keep.len() - kept_off))];
    if off.len() > kept_off {
        omitted.push(("offroad_steps_omitted", off.len() - kept_off));
    }
    (keep, omitted)
}

fn step_json(s: &Step, trip_mode: &str) -> Value {
    let mut m = Map::new();
    m.insert("index".into(), json!(s.index));
    m.insert("kind".into(), json!(s.kind));
    m.insert("type".into(), json!(s.type_));
    m.insert("street_names".into(), json!(s.street_names));
    m.insert("distance_mi".into(), json!(s.distance_mi));
    m.insert("cardinal".into(), json!(s.cardinal));
    m.insert("instruction".into(), json!(step_text(s, trip_mode)));
    if is_offroad(s) {
        m.insert("travel".into(), json!(s.mode));
        m.insert("grade_class".into(), json!(s.grade_class));
        m.insert("elev_gain_m".into(), json!(s.elev_gain_m));
        m.insert("elev_loss_m".into(), json!(s.elev_loss_m));
        if let Some(t) = terrain(s) {
            m.insert("terrain".into(), json!(t));
        }
        if let Some(f) = &s.follow {
            m.insert("follow".into(), json!({"name": f.name, "trail_kind": f.trail_kind}));
        }
    }
    Value::Object(m)
}

/// AIDA's `_place`: place_name, kind, street, locality, county, state, distance_km, and er_tier when the source has one.
pub fn place(r: &Resolved) -> Map<String, Value> {
    let mut m = Map::new();
    m.insert("place_name".into(), json!(r.name));
    m.insert("kind".into(), json!(r.kind));
    m.insert("street".into(), json!(r.street));
    m.insert("locality".into(), json!(r.locality));
    m.insert("county".into(), json!(r.county));
    m.insert("state".into(), json!(r.state));
    m.insert("distance_km".into(), json!(r.distance_km));
    if let Some(t) = r.er_tier {
        m.insert("er_tier".into(), json!(t));
    }
    m
}

/// One entry of `other_destination_candidates`; `drive_min` on a nearest-place search.
pub fn candidate(r: &Resolved, drive_min: Option<Option<f64>>) -> Value {
    let mut m = place(r);
    if let Some(t) = drive_min {
        m.insert("drive_min".into(), json!(t.map(|t| round_py(t, 1))));
    }
    Value::Object(m)
}

/// A place of the result's `from_matched` / `to_matched`: `_place` plus `near` and `snap_distance_m`. Cache has no
/// reverse geocoder, so `near` (navi's description of the end) is null.
fn end_json(r: &Resolved, snap_m: Option<i64>) -> Value {
    let mut m = place(r);
    m.insert("near".into(), Value::Null);
    m.insert("snap_distance_m".into(), json!(snap_m));
    Value::Object(m)
}

pub struct Extras {
    pub location_bias: Option<String>,
    pub others: Vec<Value>,
    pub nearest_search: Option<Value>,
    pub region: (String, String),
    /// No off-road data: an end away from the road network is only reported as a warning.
    pub synth_warnings: bool,
    pub snap_m: f64,
}

pub fn result(d: &Directions, from: &Resolved, to: &Resolved, mode: &str, x: Extras) -> Value {
    let mut o = Map::new();
    // the framework numbers this object: "address" becomes "n" (and "ok":true goes in front)
    o.insert("address".into(), json!(format!("nav:{}", d.route_id)));
    o.insert("mode".into(), json!(mode));
    o.insert("location_bias".into(), json!(x.location_bias));
    o.insert("route_id".into(), json!(d.route_id));
    o.insert("from_matched".into(), end_json(from, d.from.as_ref().map(|e| e.snap_distance_m)));
    o.insert("to_matched".into(), end_json(to, d.to.as_ref().map(|e| e.snap_distance_m)));
    o.insert("other_destination_candidates".into(), Value::Array(x.others));
    if let Some(n) = x.nearest_search {
        o.insert("nearest_search".into(), n);
    }
    o.insert("distance_mi".into(), json!(d.distance_mi));
    o.insert("distance_km".into(), json!(d.distance_km));
    o.insert("duration_minutes".into(), json!(round_py(d.duration_s as f64 / 60.0, 1)));
    o.insert("major_roads".into(), Value::Array(d.major_roads.iter().map(|(n, k)| json!({"name": n, "distance_km": k})).collect()));
    o.insert("step_count".into(), json!(d.steps.len()));
    let (keep, omitted) = model_steps(&d.steps);
    o.insert("steps".into(), Value::Array(keep.iter().map(|&i| step_json(&d.steps[i], mode)).collect()));
    o.insert("steps_truncated".into(), json!(d.steps.len() > MAX_STEPS));
    for (k, n) in omitted {
        o.insert(k.into(), json!(n));
    }
    let offroad_mi: f64 = d.steps.iter().filter(|s| is_offroad(s)).map(|s| s.distance_mi).sum();
    if d.steps.iter().any(is_offroad) {
        o.insert("offroad_mi".into(), json!(round_py(offroad_mi, 2)));
        o.insert("offroad_note".into(), json!(OFFROAD_NOTE));
    }
    let warnings = warnings(d, !x.synth_warnings, x.snap_m);
    if !warnings.is_empty() {
        o.insert("warnings".into(), Value::Array(warnings));
    }
    o.insert("map_region".into(), json!(x.region.0));
    o.insert("map_region_age".into(), json!(x.region.1));
    Value::Object(o)
}

/// The `offroad_unavailable` warnings of a route: an end away from the road network that got no off-road leg. With off-road
/// data the router says so itself; without it the gap is read from how far each end snapped to the road.
pub fn warnings(d: &Directions, have_offroad: bool, snap_m: f64) -> Vec<Value> {
    let mut warnings: Vec<Value> = Vec::new();
    if !have_offroad {
        let pts = cache_offroad::directions::shape_points(d);
        for (end, e, p) in [("from", &d.from, pts.first()), ("to", &d.to, pts.last())] {
            if let (Some(e), Some(p)) = (e, p) {
                if e.snap_distance_m as f64 > snap_m {
                    warnings.push(json!({"code": "offroad_unavailable", "end": end, "road_point": {"lat": round_py(p.0, 6), "lon": round_py(p.1, 6)}, "gap_m": e.snap_distance_m}));
                }
            }
        }
    } else {
        for w in &d.warnings {
            warnings.push(json!({"code": "offroad_unavailable", "end": w.end, "road_point": {"lat": round_py(w.road_point.0, 6), "lon": round_py(w.road_point.1, 6)}, "gap_m": w.gap_m}));
        }
    }
    warnings
}

/// AIDA's `{from_matched, to_matched}` that ride beside an error.
pub fn with_ends(e: ToolError, from: &Resolved, to: Option<&Resolved>) -> ToolError {
    let e = e.with_top("from_matched", Value::Object(place(from)));
    match to {
        Some(t) => e.with_top("to_matched", Value::Object(place(t))),
        None => e,
    }
}

/// A failed route: the router's own code is the error type (no_route, too_far, out_of_coverage, route_too_long,
/// upstream_timeout, internal), its message the detail, with both matched places beside it.
pub fn route_error(d: &Directions, from: &Resolved, to: &Resolved) -> ToolError {
    let (code, message) = d.errors.first().map(|e| (e.code.as_str(), e.message.as_str())).unwrap_or(("internal", ""));
    with_ends(ToolError::new(code, message), from, Some(to))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn python_floats_and_ages() {
        assert_eq!(py(5.0), "5.0");
        assert_eq!(py(0.08), "0.08");
        assert_eq!(age_words(12 * 86400 + 5), "12 days old");
        assert_eq!(age_words(86400), "1 day old");
    }
}

#[cfg(test)]
mod step_tests {
    use super::*;
    use cache_offroad::offroad_legs::Step;

    fn step(i: usize, kind: &str) -> Step {
        Step {
            index: i,
            kind: kind.into(),
            type_: "x".into(),
            mode: None,
            street_names: vec![],
            distance_m: None,
            distance_km: 0.0,
            distance_mi: 0.1,
            duration_s: 0,
            bearing_deg: None,
            cardinal: Some("N".into()),
            elev_gain_m: None,
            elev_loss_m: None,
            grade_class: None,
            terrain: None,
            start: (0.0, 0.0),
            end: (0.0, 0.0),
            instruction: None,
            follow: None,
        }
    }

    /// The recorded AIDA result with 30 steps: 4 road and 26 off-road gave 12 shown, road_steps_omitted 4, offroad_steps_omitted 14.
    #[test]
    fn omitted_counts_follow_aida() {
        let mut steps: Vec<Step> = (0..4).map(|i| step(i, "road")).collect();
        steps.extend((4..30).map(|i| step(i, "offroad")));
        let (keep, omitted) = model_steps(&steps);
        assert_eq!(keep, (18..30).collect::<Vec<_>>());
        assert_eq!(omitted, vec![("road_steps_omitted", 4), ("offroad_steps_omitted", 14)]);
        // room left: the first road steps fill it, in route order
        let mut steps: Vec<Step> = (0..10).map(|i| step(i, "road")).collect();
        steps.extend((10..14).map(|i| step(i, "offroad")));
        let (keep, omitted) = model_steps(&steps);
        assert_eq!(keep, vec![0, 1, 2, 3, 4, 5, 6, 7, 10, 11, 12, 13]);
        assert_eq!(omitted, vec![("road_steps_omitted", 2)]);
        // at or under the cap nothing is omitted
        assert!(model_steps(&steps[..12]).1.is_empty());
    }

    #[test]
    fn offroad_text_is_aidas() {
        let mut s = step(0, "offroad");
        s.mode = Some("4w".into());
        s.cardinal = Some("NE".into());
        s.distance_mi = 0.08;
        s.grade_class = Some("flat".into());
        s.terrain = Some("tree_cover".into());
        s.elev_gain_m = Some(1);
        s.elev_loss_m = Some(2);
        assert_eq!(step_text(&s, "drive"), "By ATV: Off-road NE 0.08 mi, flat, tree cover (+1 m -2 m)");
        s.kind = "offroad_follow".into();
        s.follow = Some(cache_offroad::offroad_legs::Follow { trail_kind: "road".into(), name: Some("Skyline Road".into()) });
        s.cardinal = Some("N".into());
        s.distance_mi = 0.1;
        s.elev_gain_m = Some(0);
        s.elev_loss_m = Some(5);
        s.terrain = Some("unknown".into());
        assert_eq!(step_text(&s, "drive"), "By ATV: Follow Skyline Road N 0.1 mi, flat (-5 m)");
        // walking legs on a walking trip carry no prefix; a follow with no name says which kind
        s.mode = Some("foot".into());
        s.follow = Some(cache_offroad::offroad_legs::Follow { trail_kind: "trail".into(), name: None });
        assert_eq!(step_text(&s, "walk"), "Follow the trail N 0.1 mi, flat (-5 m)");
        assert_eq!(step_text(&s, "drive"), "On foot: Follow the trail N 0.1 mi, flat (-5 m)");
        let j = step_json(&s, "walk");
        assert!(j.get("terrain").is_none());
        assert_eq!(j["follow"], json!({"name": null, "trail_kind": "trail"}));
        s.distance_mi = 5.0;
        assert!(step_text(&s, "walk").contains("5.0 mi"));
    }
}
