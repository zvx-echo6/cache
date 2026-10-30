//! Distance and direction from a place to a GeoJSON geometry (a point, a line or an area): "inside" when the place is
//! within an area, else the distance to the nearest point of the geometry and the compass direction of that point.

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

/// Great-circle distance between two points, km.
pub fn haversine_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let (p1, p2) = (lat1.to_radians(), lat2.to_radians());
    let dl = (lon2 - lon1).to_radians();
    let a = ((p2 - p1) / 2.0).sin().powi(2) + p1.cos() * p2.cos() * (dl / 2.0).sin().powi(2);
    2.0 * EARTH_KM * a.sqrt().min(1.0).asin()
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

/// The nearest point of an open path (a line), same flat-map method as the rings.
fn nearest_on_path(pts: &[(f64, f64)], lat0: f64, lon0: f64, best: &mut Option<(f64, f64, f64)>) {
    if pts.len() == 1 {
        let d = haversine_km(lat0, lon0, pts[0].1, pts[0].0);
        if best.map(|b| d < b.0).unwrap_or(true) {
            *best = Some((d, pts[0].1, pts[0].0));
        }
        return;
    }
    let k = lat0.to_radians().cos().max(1e-6);
    let xy = |p: &(f64, f64)| (wrap(p.0 - lon0) * k, p.1 - lat0);
    for w in pts.windows(2) {
        let (a, b) = (xy(&w[0]), xy(&w[1]));
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

fn coord(p: &Value) -> Option<(f64, f64)> {
    Some((p.get(0)?.as_f64()?, p.get(1)?.as_f64()?))
}

fn path_of(coords: &Value) -> Vec<(f64, f64)> {
    coords.as_array().map(|a| a.iter().filter_map(coord).collect()).unwrap_or_default()
}

/// Points and lines found in a geometry (everything that is not a polygon).
fn paths(g: &Value, out: &mut Vec<Vec<(f64, f64)>>) {
    match g.get("type").and_then(Value::as_str) {
        Some("Point") => out.extend(coord(&g["coordinates"]).map(|c| vec![c])),
        Some("MultiPoint") => out.extend(path_of(&g["coordinates"]).into_iter().map(|c| vec![c])),
        Some("LineString") => out.push(path_of(&g["coordinates"])),
        Some("MultiLineString") => {
            if let Some(ls) = g["coordinates"].as_array() {
                out.extend(ls.iter().map(path_of));
            }
        }
        Some("GeometryCollection") => {
            if let Some(gs) = g["geometries"].as_array() {
                for x in gs {
                    paths(x, out);
                }
            }
        }
        Some("Feature") => paths(&g["geometry"], out),
        Some("FeatureCollection") => {
            if let Some(fs) = g["features"].as_array() {
                for f in fs {
                    paths(&f["geometry"], out);
                }
            }
        }
        _ => {}
    }
}

/// Distance and direction to a point given directly.
pub fn to_point(lat: f64, lon: f64, plat: f64, plon: f64) -> Near {
    Near { inside: false, km: haversine_km(lat, lon, plat, plon), bearing: bearing_deg(lat, lon, plat, plon) }
}

/// The nearest part of any GeoJSON geometry (Point, LineString, Polygon, their Multi forms, collections, a Feature
/// or a FeatureCollection). `None` when the value has no geometry.
pub fn nearest(geometry: &Value, lat: f64, lon: f64) -> Option<Near> {
    let mut polys = Vec::new();
    polygons(geometry, &mut polys);
    // polygons() does not look inside features: unwrap them here
    match geometry.get("type").and_then(Value::as_str) {
        Some("Feature") => return nearest(&geometry["geometry"], lat, lon),
        Some("FeatureCollection") => {
            let all: Vec<Near> = geometry["features"].as_array()?.iter().filter_map(|f| nearest(&f["geometry"], lat, lon)).collect();
            return all.into_iter().min_by(|a, b| (if a.inside { 0.0 } else { a.km }).partial_cmp(&(if b.inside { 0.0 } else { b.km })).unwrap_or(std::cmp::Ordering::Equal));
        }
        _ => {}
    }
    polys.retain(|p| !p.is_empty());
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
    let mut ps = Vec::new();
    paths(geometry, &mut ps);
    for p in ps.iter().filter(|p| !p.is_empty()) {
        nearest_on_path(p, lat, lon, &mut best);
    }
    let (km, plat, plon) = best?;
    Some(Near { inside: false, km, bearing: bearing_deg(lat, lon, plat, plon) })
}

/// The polygons (outer ring first, then holes) and the loose points of a geometry, for [`intersects`].
fn parts(g: &Value) -> (Vec<Vec<Ring>>, Vec<(f64, f64)>) {
    let g = match g.get("type").and_then(Value::as_str) {
        Some("Feature") => &g["geometry"],
        _ => g,
    };
    let mut polys = Vec::new();
    polygons(g, &mut polys);
    polys.retain(|p| !p.is_empty());
    let mut ps = Vec::new();
    paths(g, &mut ps);
    (polys, ps.into_iter().flatten().collect())
}

fn in_polygon(p: &[Ring], lon: f64, lat: f64) -> bool {
    in_ring(&p[0], lon, lat) && !p[1..].iter().any(|h| in_ring(h, lon, lat))
}

/// Whether segments a-b and c-d cross or touch (lon, lat treated as flat: alert areas are small).
fn segments_meet(a: (f64, f64), b: (f64, f64), c: (f64, f64), d: (f64, f64)) -> bool {
    let cross = |o: (f64, f64), p: (f64, f64), q: (f64, f64)| (p.0 - o.0) * (q.1 - o.1) - (p.1 - o.1) * (q.0 - o.0);
    let on = |o: (f64, f64), p: (f64, f64), q: (f64, f64)| q.0 >= o.0.min(p.0) && q.0 <= o.0.max(p.0) && q.1 >= o.1.min(p.1) && q.1 <= o.1.max(p.1);
    let (d1, d2, d3, d4) = (cross(c, d, a), cross(c, d, b), cross(a, b, c), cross(a, b, d));
    if ((d1 > 0.0 && d2 < 0.0) || (d1 < 0.0 && d2 > 0.0)) && ((d3 > 0.0 && d4 < 0.0) || (d3 < 0.0 && d4 > 0.0)) {
        return true;
    }
    (d1 == 0.0 && on(c, d, a)) || (d2 == 0.0 && on(c, d, b)) || (d3 == 0.0 && on(a, b, c)) || (d4 == 0.0 && on(a, b, d))
}

fn rings_meet(r: &Ring, s: &Ring) -> bool {
    (0..r.len()).any(|i| (0..s.len()).any(|j| segments_meet(r[i], r[(i + 1) % r.len()], s[j], s[(j + 1) % s.len()])))
}

fn polygons_meet(p: &[Ring], q: &[Ring]) -> bool {
    p.iter().any(|r| q.iter().any(|s| rings_meet(r, s)))
        || p[0].iter().any(|&(x, y)| in_polygon(q, x, y))
        || q[0].iter().any(|&(x, y)| in_polygon(p, x, y))
}

/// Whether two GeoJSON geometries share any point: an area overlaps or touches the other, contains one of its points, or (two
/// points) they are the same point. Holes are respected. Lines count by their points only.
pub fn intersects(a: &Value, b: &Value) -> bool {
    let (pa, xa) = parts(a);
    let (pb, xb) = parts(b);
    pa.iter().any(|p| pb.iter().any(|q| polygons_meet(p, q)))
        || xa.iter().any(|&(x, y)| pb.iter().any(|q| in_polygon(q, x, y)))
        || xb.iter().any(|&(x, y)| pa.iter().any(|p| in_polygon(p, x, y)))
        || xa.iter().any(|u| xb.contains(u))
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
        assert!(nearest(&json!({"type":"Point","coordinates":[1,2]}), 0.0, 0.0).is_some());
        assert!(nearest(&json!({"type":"Nope"}), 0.0, 0.0).is_none());
        let line = nearest(&json!({"type":"LineString","coordinates":[[-113.0,42.0],[-113.0,43.0]]}), 42.5, -113.792).unwrap();
        assert!((line.bearing - 90.0).abs() < 1.0 && line.km > 50.0 && line.km < 70.0, "{} {}", line.km, line.bearing);
        assert!(nearest(&Value::Null, 0.0, 0.0).is_none());
    }

    #[test]
    fn areas_that_overlap_touch_contain_or_miss() {
        let a = square(42.0, -114.0, 43.0, -113.0);
        assert!(intersects(&a, &square(42.5, -113.5, 43.5, -112.5)), "crossing edges");
        assert!(intersects(&a, &square(42.2, -113.8, 42.4, -113.6)), "one inside the other");
        assert!(intersects(&square(42.2, -113.8, 42.4, -113.6), &a), "the other way round");
        assert!(intersects(&a, &square(43.0, -114.0, 44.0, -113.0)), "a shared edge");
        assert!(!intersects(&a, &square(44.0, -114.0, 45.0, -113.0)), "apart");
        assert!(intersects(&a, &json!({"type":"Point","coordinates":[-113.5,42.5]})));
        assert!(!intersects(&a, &json!({"type":"Point","coordinates":[-110.0,42.5]})));
        // inside a hole is not inside the area
        let holed = json!({"type":"Polygon","coordinates":[
            [[-114.0,42.0],[-113.0,42.0],[-113.0,43.0],[-114.0,43.0],[-114.0,42.0]],
            [[-113.9,42.1],[-113.1,42.1],[-113.1,42.9],[-113.9,42.9],[-113.9,42.1]]]});
        assert!(!intersects(&holed, &square(42.4, -113.6, 42.6, -113.4)));
        assert!(intersects(&json!({"type":"GeometryCollection","geometries":[square(10.0, 10.0, 11.0, 11.0), a.clone()]}), &square(42.9, -113.1, 43.2, -112.8)));
        assert!(intersects(&json!({"type":"Feature","geometry":a}), &json!({"type":"MultiPolygon","coordinates":[[[[-113.5,42.5],[-113.4,42.5],[-113.4,42.6],[-113.5,42.5]]]]})));
    }
}
