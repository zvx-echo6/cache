//! Distance and direction from a place to a GeoJSON area (alerts): 0 and "inside" when the place is within it, else the
//! distance to the nearest point of its boundary and the compass direction of that point.

use serde_json::Value;

const EARTH_KM: f64 = 6371.0088;

pub struct Near {
    pub inside: bool,
    pub km: f64,
    /// Initial bearing from the place to the nearest point, degrees clockwise from north.
    pub bearing: f64,
}

type Ring = Vec<(f64, f64)>; // (lon, lat)

fn rings_of(coords: &Value) -> Vec<Ring> {
    coords
        .as_array()
        .map(|rs| {
            rs.iter()
                .map(|r| {
                    r.as_array()
                        .map(|pts| pts.iter().filter_map(|p| Some((p.get(0)?.as_f64()?, p.get(1)?.as_f64()?))).collect::<Ring>())
                        .unwrap_or_default()
                })
                .filter(|r| r.len() >= 3)
                .collect()
        })
        .unwrap_or_default()
}

/// Each polygon is its list of rings, the first the outer boundary, the rest holes.
fn polygons(g: &Value, out: &mut Vec<Vec<Ring>>) {
    match g.get("type").and_then(Value::as_str) {
        Some("Polygon") => out.push(rings_of(&g["coordinates"])),
        Some("MultiPolygon") => {
            if let Some(ps) = g["coordinates"].as_array() {
                for p in ps {
                    out.push(rings_of(p));
                }
            }
        }
        Some("GeometryCollection") => {
            if let Some(gs) = g["geometries"].as_array() {
                for x in gs {
                    polygons(x, out);
                }
            }
        }
        _ => {}
    }
}

fn in_ring(r: &Ring, lon: f64, lat: f64) -> bool {
    let mut inside = false;
    let mut j = r.len() - 1;
    for i in 0..r.len() {
        let (xi, yi) = r[i];
        let (xj, yj) = r[j];
        if (yi > lat) != (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi {
            inside = !inside;
        }
        j = i;
    }
    inside
}

fn haversine_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let (p1, p2) = (lat1.to_radians(), lat2.to_radians());
    let dl = (lon2 - lon1).to_radians();
    let a = ((p2 - p1) / 2.0).sin().powi(2) + p1.cos() * p2.cos() * (dl / 2.0).sin().powi(2);
    2.0 * EARTH_KM * a.sqrt().asin()
}

fn bearing_deg(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let (p1, p2) = (lat1.to_radians(), lat2.to_radians());
    let dl = (lon2 - lon1).to_radians();
    let y = dl.sin() * p2.cos();
    let x = p1.cos() * p2.sin() - p1.sin() * p2.cos() * dl.cos();
    y.atan2(x).to_degrees().rem_euclid(360.0)
}

fn wrap(dlon: f64) -> f64 {
    (dlon + 180.0).rem_euclid(360.0) - 180.0
}

/// The nearest point of the boundary, found on a flat map centred on the place (exact enough for the sizes of alert
/// areas), then measured on the sphere.
fn nearest_on_ring(r: &Ring, lat0: f64, lon0: f64, best: &mut Option<(f64, f64, f64)>) {
    let k = lat0.to_radians().cos().max(1e-6);
    let xy = |p: &(f64, f64)| (wrap(p.0 - lon0) * k, p.1 - lat0);
    for i in 0..r.len() {
        let (a, b) = (xy(&r[i]), xy(&r[(i + 1) % r.len()]));
        let (dx, dy) = (b.0 - a.0, b.1 - a.1);
        let len2 = dx * dx + dy * dy;
        let t = if len2 == 0.0 { 0.0 } else { (-(a.0 * dx + a.1 * dy) / len2).clamp(0.0, 1.0) };
        let (px, py) = (a.0 + t * dx, a.1 + t * dy);
        let (plat, plon) = (lat0 + py, lon0 + px / k);
        let d = haversine_km(lat0, lon0, plat, plon);
        if best.map(|b| d < b.0).unwrap_or(true) {
            *best = Some((d, plat, plon));
        }
    }
}

/// `None` when the value has no polygon.
pub fn nearest(geometry: &Value, lat: f64, lon: f64) -> Option<Near> {
    let mut polys = Vec::new();
    polygons(geometry, &mut polys);
    polys.retain(|p| !p.is_empty());
    if polys.is_empty() {
        return None;
    }
    for p in &polys {
        if in_ring(&p[0], lon, lat) && !p[1..].iter().any(|h| in_ring(h, lon, lat)) {
            return Some(Near { inside: true, km: 0.0, bearing: 0.0 });
        }
    }
    let mut best = None;
    for p in &polys {
        for r in p {
            nearest_on_ring(r, lat, lon, &mut best);
        }
    }
    let (km, plat, plon) = best?;
    Some(Near { inside: false, km, bearing: bearing_deg(lat, lon, plat, plon) })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn square(s: f64, w: f64, n: f64, e: f64) -> Value {
        json!({"type":"Polygon","coordinates":[[[w,s],[e,s],[e,n],[w,n],[w,s]]]})
    }

    #[test]
    fn inside_outside_and_direction() {
        let g = square(42.4, -113.9, 42.7, -113.6);
        assert!(nearest(&g, 42.536, -113.792).unwrap().inside);
        // north of the place: the nearest point is straight north
        let n = nearest(&square(42.7, -113.9, 42.8, -113.7), 42.536, -113.792).unwrap();
        assert!(!n.inside);
        assert!((n.km - 18.24).abs() < 0.1, "{}", n.km);
        assert!(n.bearing < 1.0 || n.bearing > 359.0, "{}", n.bearing);
        // east
        let e = nearest(&square(42.4, -113.0, 42.7, -112.9), 42.536, -113.792).unwrap();
        assert!((e.bearing - 90.0).abs() < 2.0, "{}", e.bearing);
        // a hole: inside the hole is outside the area
        let holed = json!({"type":"Polygon","coordinates":[
            [[-114.0,42.0],[-113.0,42.0],[-113.0,43.0],[-114.0,43.0],[-114.0,42.0]],
            [[-113.9,42.5],[-113.7,42.5],[-113.7,42.6],[-113.9,42.6],[-113.9,42.5]]]});
        let h = nearest(&holed, 42.55, -113.8).unwrap();
        assert!(!h.inside && h.km < 6.0);
        assert!(nearest(&holed, 42.2, -113.5).unwrap().inside);
        // multipolygon, collection, and things that are not areas
        let mp = json!({"type":"MultiPolygon","coordinates":[[[[-10.0,0.0],[-9.0,0.0],[-9.0,1.0],[-10.0,0.0]]],[[[-113.9,42.4],[-113.6,42.4],[-113.6,42.7],[-113.9,42.4]]]]});
        assert!(nearest(&mp, 42.5, -113.7).unwrap().inside);
        assert!(nearest(&json!({"type":"GeometryCollection","geometries":[square(42.7, -113.9, 42.8, -113.7)]}), 42.536, -113.792).is_some());
        assert!(nearest(&json!({"type":"Point","coordinates":[1,2]}), 0.0, 0.0).is_none());
        assert!(nearest(&Value::Null, 0.0, 0.0).is_none());
    }
}
