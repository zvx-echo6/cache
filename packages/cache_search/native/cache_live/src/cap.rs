//! CAP 1.2 `<area>` blocks (OASIS Common Alerting Protocol, section 3.2.4) read from the response tree: their polygons and
//! circles as one GeoJSON geometry, and their geocodes. Used by an item's `cap_area` (definition format 3). Any CAP feed works
//! the same way (FEMA IPAWS, other countries' alerting authorities): nothing here knows a provider.
//!
//! The XML reader gives an element's text as a string (or `#text` beside attributes) and a repeated element as a list, so an
//! area, a polygon, a circle and a geocode may each be one value or a list of them. CAP writes coordinates as WGS 84 "lat,lon"
//! pairs separated by spaces; GeoJSON wants (lon, lat). A shape whose coordinates cannot be read is left out, never the item.

use serde_json::{json, Value};

/// Points used for a CAP circle.
const CIRCLE_POINTS: usize = 32;

/// One value or a list of them, as a list.
fn many(v: Option<&Value>) -> Vec<&Value> {
    match v {
        None | Some(Value::Null) => vec![],
        Some(Value::Array(a)) => a.iter().collect(),
        Some(x) => vec![x],
    }
}

/// An element's text (a string, or `#text` next to attributes).
fn text(v: &Value) -> Option<&str> {
    match v {
        Value::String(s) => Some(s.as_str()),
        Value::Object(o) => o.get("#text").and_then(Value::as_str),
        _ => None,
    }
}

fn pair(p: &str) -> Option<(f64, f64)> {
    let (a, b) = p.split_once(',')?;
    let (lat, lon): (f64, f64) = (a.trim().parse().ok()?, b.trim().parse().ok()?);
    (lat.is_finite() && lon.is_finite() && lat.abs() <= 90.0 && lon.abs() <= 180.0).then_some((lat, lon))
}

/// A CAP polygon ("lat,lon lat,lon ..."; the first pair repeated at the end) as a GeoJSON Polygon. At least three distinct
/// points; a ring that is not closed is closed. Any pair that cannot be read drops the polygon.
pub fn polygon(s: &str) -> Option<Value> {
    let pts: Vec<(f64, f64)> = s.split_whitespace().map(pair).collect::<Option<_>>()?;
    let mut ring: Vec<[f64; 2]> = pts.iter().map(|&(lat, lon)| [lon, lat]).collect();
    if ring.first() != ring.last() {
        ring.push(ring[0]);
    }
    if ring.len() < 4 {
        return None;
    }
    Some(json!({"type": "Polygon", "coordinates": [ring]}))
}

/// A CAP circle ("lat,lon radius" with the radius in km) as a GeoJSON Polygon of 32 points; radius 0 is the point itself.
pub fn circle(s: &str) -> Option<Value> {
    let mut it = s.split_whitespace();
    let (lat, lon) = pair(it.next()?)?;
    let r: f64 = it.next()?.parse().ok()?;
    if it.next().is_some() || !r.is_finite() || r < 0.0 {
        return None;
    }
    if r == 0.0 {
        return Some(json!({"type": "Point", "coordinates": [lon, lat]}));
    }
    // a small circle on the sphere, drawn from its centre (exact enough for the sizes of alert areas)
    let d = r / 6371.0088;
    let (p1, l1) = (lat.to_radians(), lon.to_radians());
    let mut ring: Vec<[f64; 2]> = (0..CIRCLE_POINTS)
        .map(|i| {
            let b = (i as f64) * std::f64::consts::TAU / CIRCLE_POINTS as f64;
            let p2 = (p1.sin() * d.cos() + p1.cos() * d.sin() * b.cos()).asin();
            let l2 = l1 + (b.sin() * d.sin() * p1.cos()).atan2(d.cos() - p1.sin() * p2.sin());
            [((l2.to_degrees() + 540.0) % 360.0) - 180.0, p2.to_degrees()]
        })
        .collect();
    ring.push(ring[0]);
    Some(json!({"type": "Polygon", "coordinates": [ring]}))
}

/// What the `<area>` blocks at a value give: one geometry (a GeometryCollection of every polygon and circle that could be read,
/// `None` when there is none) and the geocodes as (valueName, value).
pub struct CapArea {
    pub geometry: Option<Value>,
    pub codes: Vec<(String, String)>,
}

/// Reads an `<area>` block or a list of them.
pub fn read(areas: &Value) -> CapArea {
    let mut shapes = Vec::new();
    let mut codes = Vec::new();
    for a in many(Some(areas)) {
        for p in many(a.get("polygon")).into_iter().filter_map(text) {
            shapes.extend(polygon(p));
        }
        for c in many(a.get("circle")).into_iter().filter_map(text) {
            shapes.extend(circle(c));
        }
        for g in many(a.get("geocode")) {
            let (Some(n), Some(v)) = (g.get("valueName").and_then(text), g.get("value").and_then(text)) else { continue };
            if !n.trim().is_empty() && !v.trim().is_empty() {
                codes.push((n.trim().to_string(), v.trim().to_string()));
            }
        }
    }
    let geometry = (!shapes.is_empty()).then(|| json!({"type": "GeometryCollection", "geometries": shapes}));
    CapArea { geometry, codes }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::geo;

    #[test]
    fn polygons_are_turned_to_lon_lat_and_closed() {
        let p = polygon("48.9192,-116.4488 48.9210,-116.3039 48.8190,-116.2298 48.9192,-116.4488").unwrap();
        assert_eq!(p["coordinates"][0][0], json!([-116.4488, 48.9192]));
        assert_eq!(p["coordinates"][0].as_array().unwrap().len(), 4);
        // not closed: closed here
        let q = polygon("1,1 1,2 2,2").unwrap();
        assert_eq!(q["coordinates"][0].as_array().unwrap().len(), 4);
        assert_eq!(q["coordinates"][0][3], json!([1.0, 1.0]));
        // too few points, a bad pair, out of range: no polygon
        assert!(polygon("1,1 2,2").is_none());
        assert!(polygon("1,1 1,x 2,2 1,1").is_none());
        assert!(polygon("91,1 1,2 2,2 91,1").is_none());
        assert!(polygon("").is_none());
    }

    #[test]
    fn circles_have_their_radius() {
        let c = circle("43.6150,-116.2023 10").unwrap();
        let ring = c["coordinates"][0].as_array().unwrap();
        assert_eq!(ring.len(), CIRCLE_POINTS + 1);
        for pt in ring {
            let km = geo::haversine_km(43.615, -116.2023, pt[1].as_f64().unwrap(), pt[0].as_f64().unwrap());
            assert!((km - 10.0).abs() < 0.01, "{km}");
        }
        assert!(geo::nearest(&c, 43.65, -116.2).unwrap().inside);
        assert!(!geo::nearest(&c, 43.80, -116.2).unwrap().inside);
        assert_eq!(circle("43.6,-116.2 0").unwrap()["type"], "Point");
        assert!(circle("43.6,-116.2").is_none());
        assert!(circle("43.6,-116.2 -1").is_none());
        assert!(circle("43.6;-116.2 5").is_none());
    }

    #[test]
    fn areas_one_or_many_with_their_geocodes() {
        // one area, one polygon, one geocode (the XML reader's shape for single elements)
        let one = json!({"areaDesc": "Boundary County", "polygon": "48.9,-116.4 48.9,-116.3 48.8,-116.2 48.9,-116.4",
                          "geocode": {"valueName": "SAME", "value": "016021"}});
        let a = read(&one);
        assert_eq!(a.geometry.as_ref().unwrap()["geometries"].as_array().unwrap().len(), 1);
        assert_eq!(a.codes, vec![("SAME".to_string(), "016021".to_string())]);
        // several areas: a bad polygon is dropped, the circle and the rest stay; several geocodes
        let many = json!([
            {"areaDesc": "A", "polygon": ["1,1 1,2 2,2 1,1", "1,1 nope 2,2 1,1"], "geocode": [{"valueName": "SAME", "value": "016001"}, {"valueName": "UGC", "value": "IDZ012"}]},
            {"areaDesc": "B", "circle": "43.6,-116.2 5"},
            {"areaDesc": "C (codes only)", "geocode": {"valueName": "SAME", "value": " 016027 "}}
        ]);
        let b = read(&many);
        assert_eq!(b.geometry.as_ref().unwrap()["geometries"].as_array().unwrap().len(), 2);
        assert_eq!(b.codes.len(), 3);
        assert_eq!(b.codes[2].1, "016027");
        // nothing to draw: no geometry
        let none = read(&json!({"areaDesc": "Statewide", "geocode": {"valueName": "SAME", "value": "016000"}}));
        assert!(none.geometry.is_none() && none.codes.len() == 1);
        assert!(read(&Value::Null).geometry.is_none());
    }
}
