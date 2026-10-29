//! Route summaries for the assistant, with canonical citation addresses and matched-place evidence.
//! Full geometry and maneuvers stay in the retained Maps snapshot, outside the model context.

use crate::resolve::Resolved;
use cache_offroad::directions::Directions;
use cache_offroad::offroad_legs::{bearing_deg, cardinal, round_py, Step, KM_TO_MI};
use cache_tool::ToolError;
use serde_json::{json, Map, Value};

/// AIDA's OFFROAD_NOTE, with the grid size corrected: AIDA says ~30 m, but the router's grid is the global z12 pixel grid
/// (2^21 pixels around the world: 19 m at the equator, 13-15 m across the continental US).
const OFFROAD_NOTE: &str = "Off-road legs are straight lines between turn points over a ~15 m elevation grid with no path on the ground; follow legs run along the mapped road, track or trail they name.";

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
/// terrain, prefixed with how it is travelled (except walking legs on a walking or off-road foot trip).
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
        Some(t) if !(t == "foot" && (trip_mode == "walk" || trip_mode == "offroad_foot")) => format!("{}: {text}", travel_phrase(t)),
        _ => text,
    }
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
        m.insert("emergency_department_confirmed".into(), json!(t == 1));
        if t != 1 {
            m.insert("note".into(), json!("Hospital fallback: an emergency department is not confirmed in the installed data. Do not describe this as a confirmed emergency room."));
        }
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
    m.insert("lat".into(), json!(round_py(r.lat, 5)));
    m.insert("lon".into(), json!(round_py(r.lon, 5)));
    Value::Object(m)
}

/// The 8-point compass direction of a bearing in degrees, as one lower-case word (45 degree sectors centred on each point).
fn direction_word(bearing: f64) -> &'static str {
    match cardinal(bearing) {
        "N" => "north",
        "NE" => "northeast",
        "E" => "east",
        "SE" => "southeast",
        "S" => "south",
        "SW" => "southwest",
        "W" => "west",
        _ => "northwest",
    }
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
    o.insert("direction_from_start".into(), json!(direction_word(bearing_deg((from.lat, from.lon), (to.lat, to.lon)))));
    o.insert("major_roads".into(), Value::Array(major_roads(d)));
    // Traffic on the route: {"delay_min", "as_of", "source", "slow_sections": [{"name", "delay_min"}]}, or null when there is no
    // traffic data (no traffic source wired yet, no key, offline). Always null for now (project decision, 2026-10-29).
    o.insert("traffic".into(), Value::Null);
    if d.steps.iter().any(is_offroad) {
        o.insert("offroad_mi".into(), json!(offroad_mi(d)));
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

/// The off-road part of the route in miles, rounded once from the legs' metres the way the route's own distance_mi is
/// (summing each leg's rounded miles drifts), and never more than distance_mi.
fn offroad_mi(d: &Directions) -> f64 {
    let m: f64 = d.steps.iter().filter(|s| is_offroad(s)).map(|s| s.distance_m.map_or(s.distance_km * 1000.0, |m| m as f64)).sum();
    round_py(m / 1000.0 * KM_TO_MI, 2).min(d.distance_mi)
}

/// The route's longest roads; each is rounded on its own, so they are capped to add up to no more than distance_km.
fn major_roads(d: &Directions) -> Vec<Value> {
    let mut left = d.distance_km;
    d.major_roads
        .iter()
        .map(|(n, k)| {
            let k = k.min(left).max(0.0);
            left = round_py(left - k, 2);
            json!({"name": n, "distance_km": k})
        })
        .collect()
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
    fn the_note_names_the_routers_grid_size() {
        assert!(OFFROAD_NOTE.contains("~15 m elevation grid"));
        // the query grid's cell size across the continental US (Gulf coast to the Canadian border)
        for lat in [26.0, 36.0, 44.0, 48.5] {
            let m = cache_offroad::grid::GridMeta::from_bbox(lat, lat + 0.05, -114.05, -114.0);
            assert!((12.0..=17.5).contains(&m.cell_size_m), "{lat}: {}", m.cell_size_m);
        }
    }

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

    pub(super) fn step(i: usize, kind: &str) -> Step {
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
        assert_eq!(step_text(&s, "offroad_foot"), "Follow the trail N 0.1 mi, flat (-5 m)");
        assert_eq!(step_text(&s, "offroad_vehicle"), "On foot: Follow the trail N 0.1 mi, flat (-5 m)");
        assert_eq!(step_text(&s, "drive"), "On foot: Follow the trail N 0.1 mi, flat (-5 m)");
        s.distance_mi = 5.0;
        assert!(step_text(&s, "walk").contains("5.0 mi"));
    }
}

#[cfg(test)]
mod direction_tests {
    use super::*;
    use cache_offroad::directions::{EndInfo, TravelMode};

    #[test]
    fn bearing_words_and_sector_boundaries() {
        for (deg, word) in [
            (0.0, "north"),
            (45.0, "northeast"),
            (90.0, "east"),
            (135.0, "southeast"),
            (180.0, "south"),
            (225.0, "southwest"),
            (270.0, "west"),
            (315.0, "northwest"),
            (22.4, "north"),
            (22.6, "northeast"),
            (67.4, "northeast"),
            (67.6, "east"),
            (337.4, "northwest"),
            (337.6, "north"),
            (359.9, "north"),
        ] {
            assert_eq!(direction_word(deg), word, "{deg}");
        }
    }

    #[test]
    fn boise_to_nampa_is_west() {
        assert_eq!(direction_word(bearing_deg((43.6150, -116.2023), (43.5407, -116.5635))), "west");
    }

    fn directions(distance_km: f64, distance_mi: f64, major_roads: Vec<(String, f64)>, steps: Vec<Step>) -> Directions {
        Directions {
            ok: true,
            route_id: "r1".into(),
            mode: TravelMode::Drive,
            from: Some(EndInfo { lat: 43.615, lon: -116.2023, snap_distance_m: 3 }),
            to: Some(EndInfo { lat: 43.5407, lon: -116.5635, snap_distance_m: 4 }),
            distance_km,
            distance_mi,
            duration_s: 1500,
            major_roads,
            steps,
            shape: String::new(),
            routing: "offroad".into(),
            leg_params: (0.0, 0.0, 0.0),
            warnings: vec![],
            errors: vec![],
        }
    }

    #[test]
    fn parts_never_round_past_the_total() {
        // three 1006 m legs: each rounds to 0.63 mi (1.89 summed), while the 3018 m route is 1.88 mi
        let leg = |i: usize| {
            let mut s = super::step_tests::step(i, "offroad");
            s.distance_m = Some(1006);
            s.distance_km = 1.01;
            s.distance_mi = 0.63;
            s
        };
        let d = directions(3.02, 1.88, vec![("A".into(), 0.51), ("B".into(), 0.5), ("C".into(), 0.02)], vec![leg(0), leg(1), leg(2)]);
        assert!(d.steps.iter().map(|s| s.distance_mi).sum::<f64>() > 1.885);
        assert_eq!(offroad_mi(&d), 1.88);
        // legs whose whole metres come to a hair over the total are capped at it
        let d = directions(3.02, 1.87, vec![], d.steps);
        assert_eq!(offroad_mi(&d), 1.87);
        // major roads rounded one by one (1.03 km summed) are capped to add up to the 1.0 km route
        let d = directions(1.0, 0.62, vec![("A".into(), 0.51), ("B".into(), 0.5), ("C".into(), 0.02)], vec![]);
        let k: Vec<f64> = major_roads(&d).iter().map(|m| m["distance_km"].as_f64().unwrap()).collect();
        assert_eq!(k, [0.51, 0.49, 0.0]);
        let from = Resolved::point("A".into(), 43.6150, -116.2023);
        let x = Extras { location_bias: None, others: vec![], nearest_search: None, region: ("idaho".into(), "1 day old".into()), synth_warnings: false, snap_m: 100.0 };
        let mut d = directions(3.02, 1.88, vec![], vec![leg(0), leg(1), leg(2)]);
        d.steps.push(super::step_tests::step(3, "road"));
        assert_eq!(result(&d, &from, &from, "offroad_foot", x)["offroad_mi"], 1.88);
    }

    #[test]
    fn result_carries_direction_and_end_coordinates() {
        let d = Directions {
            ok: true,
            route_id: "r1".into(),
            mode: TravelMode::Drive,
            from: Some(EndInfo { lat: 43.615, lon: -116.2023, snap_distance_m: 3 }),
            to: Some(EndInfo { lat: 43.5407, lon: -116.5635, snap_distance_m: 4 }),
            distance_km: 30.0,
            distance_mi: 18.6,
            duration_s: 1500,
            major_roads: vec![],
            steps: vec![],
            shape: String::new(),
            routing: "road".into(),
            leg_params: (0.0, 0.0, 0.0),
            warnings: vec![],
            errors: vec![],
        };
        let from = Resolved::point("Boise".into(), 43.6150, -116.2023);
        let to = Resolved::point("Nampa".into(), 43.5407, -116.5635);
        let x = Extras { location_bias: None, others: vec![], nearest_search: None, region: ("idaho".into(), "1 day old".into()), synth_warnings: false, snap_m: 100.0 };
        let r = result(&d, &from, &to, "drive", x);
        assert_eq!(r["direction_from_start"], "west");
        assert_eq!(r["from_matched"]["lat"], 43.615);
        assert_eq!(r["from_matched"]["lon"], -116.2023);
        assert_eq!(r["to_matched"]["lat"], 43.5407);
        assert_eq!(r["to_matched"]["lon"], -116.5635);
        // place() and candidate() stay without coordinates
        assert!(place(&to).get("lat").is_none());
        assert!(candidate(&to, None).get("lon").is_none());
    }
}

#[cfg(test)]
mod er_tests {
    use super::*;
    #[test]
    fn hospital_fallback_is_qualified_for_destination_and_alternatives() {
        let mut m = cache_tool::places::PlaceMatch::new("Hospital", 43.0, -116.0);
        m.er_tier = Some(3);
        let r = Resolved::from_match(m.clone());
        assert_eq!(end_json(&r, None)["emergency_department_confirmed"], false);
        assert!(candidate(&r, Some(Some(2.0)))["note"].as_str().unwrap().contains("not confirmed"));
        m.er_tier = Some(1);
        let r = Resolved::from_match(m);
        assert_eq!(candidate(&r, None)["emergency_department_confirmed"], true);
        assert!(candidate(&r, None).get("note").is_none());
    }
}
