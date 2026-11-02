//! Valhalla's tiling and which of its tiles a region's outline touches.
//!
//! Valhalla cuts the world box (-180, -90)..(180, 90) into three levels of square tiles: level 0 is 4 degrees, level 1 is 1
//! degree, level 2 is 0.25 degrees (valhalla/baldr/tilehierarchy.cc). A tile's id is row * columns + column, counted from the
//! south-west corner, and its file is `<level>/<id>.gph` with the id zero padded to the digits of the level's largest id,
//! rounded up to a multiple of 3, and split in groups of 3 (level 2 id 818660 is `2/000/818/660.gph`).
//!
//! A region is a GeoJSON Polygon or MultiPolygon (lon/lat, holes allowed). A tile belongs to it when its cell and the outline
//! overlap: an edge of the outline passes through the cell (which also covers an outline vertex inside the cell, and an
//! outline smaller than one cell), or the cell lies wholly inside the outline and outside its holes. An outline that only
//! runs along a cell's side does not take the cell beyond it.

use serde_json::Value;

/// Tile size of each level, in degrees.
pub const LEVEL_SIZE: [f64; 3] = [4.0, 1.0, 0.25];

pub fn columns(level: u8) -> u64 {
    (360.0 / LEVEL_SIZE[level as usize]).round() as u64
}

pub fn rows(level: u8) -> u64 {
    (180.0 / LEVEL_SIZE[level as usize]).round() as u64
}

/// The id of the tile of `level` that holds the point (longitudes and latitudes outside the world are clamped to its edge).
pub fn tile_id(level: u8, lon: f64, lat: f64) -> u64 {
    let (col, row) = (col_of(level, lon), row_of(level, lat));
    row * columns(level) + col
}

fn col_of(level: u8, lon: f64) -> u64 {
    let s = LEVEL_SIZE[level as usize];
    let c = ((lon.clamp(-180.0, 180.0) + 180.0) / s).floor();
    (c.max(0.0) as u64).min(columns(level) - 1)
}

fn row_of(level: u8, lat: f64) -> u64 {
    let s = LEVEL_SIZE[level as usize];
    let r = ((lat.clamp(-90.0, 90.0) + 90.0) / s).floor();
    (r.max(0.0) as u64).min(rows(level) - 1)
}

/// The cell of a tile: [west, south, east, north].
pub fn tile_rect(level: u8, id: u64) -> [f64; 4] {
    let s = LEVEL_SIZE[level as usize];
    let (col, row) = (id % columns(level), id / columns(level));
    let (w, so) = (-180.0 + col as f64 * s, -90.0 + row as f64 * s);
    [w, so, w + s, so + s]
}

/// The tile's path as Valhalla lays out a tile folder, without the `.gph` (the form the published index uses).
pub fn tile_path(level: u8, id: u64) -> String {
    let max = columns(level) * rows(level) - 1;
    let width = max.to_string().len().div_ceil(3) * 3;
    let digits = format!("{id:0width$}");
    let mut out = level.to_string();
    for g in digits.as_bytes().chunks(3) {
        out.push('/');
        out.push_str(std::str::from_utf8(g).unwrap_or(""));
    }
    out
}

/// "2/000/818/660" (or with ".gph") is (2, 818660); anything else is None.
pub fn parse_tile_path(p: &str) -> Option<(u8, u64)> {
    let stem = p.strip_suffix(".gph").unwrap_or(p);
    let mut parts = stem.split('/');
    let level: u8 = parts.next()?.parse().ok()?;
    if level > 2 {
        return None;
    }
    let mut digits = String::new();
    for g in parts {
        if g.is_empty() || !g.bytes().all(|c| c.is_ascii_digit()) {
            return None;
        }
        digits.push_str(g);
    }
    if digits.is_empty() {
        return None;
    }
    let id: u64 = digits.parse().ok()?;
    (id < columns(level) * rows(level)).then_some((level, id))
}

/// Every tile of `level` whose cell touches the box [west, south, east, north] (clamped to the world; nothing for a box that
/// is not finite or is upside down).
pub fn tiles_in_box(level: u8, b: [f64; 4]) -> Vec<u64> {
    if !b.iter().all(|v| v.is_finite()) || b[0] > b[2] || b[1] > b[3] {
        return Vec::new();
    }
    let (c0, c1) = (col_of(level, b[0]), col_of(level, b[2]));
    let (r0, r1) = (row_of(level, b[1]), row_of(level, b[3]));
    let n = columns(level);
    let mut out = Vec::new();
    for r in r0..=r1 {
        for c in c0..=c1 {
            out.push(r * n + c);
        }
    }
    out
}

/// One polygon: its outer ring first, then its holes. Rings are lists of [lon, lat].
#[derive(Debug, Clone)]
struct Poly {
    rings: Vec<Vec<[f64; 2]>>,
    bbox: [f64; 4],
}

/// A region's outline: one or more polygons.
#[derive(Debug, Clone)]
pub struct Shape {
    polys: Vec<Poly>,
}

fn ring_of(v: &Value) -> Vec<[f64; 2]> {
    let mut r: Vec<[f64; 2]> = v
        .as_array()
        .map(|pts| {
            pts.iter()
                .filter_map(|p| Some([p.get(0)?.as_f64()?, p.get(1)?.as_f64()?]))
                .filter(|p| p[0].is_finite() && p[1].is_finite())
                .collect()
        })
        .unwrap_or_default();
    // GeoJSON repeats the first point at the end; the edges below close the ring themselves.
    if r.len() > 1 && r.first() == r.last() {
        r.pop();
    }
    r
}

fn poly_of(v: &Value) -> Option<Poly> {
    let rings: Vec<Vec<[f64; 2]>> = v.as_array()?.iter().map(ring_of).filter(|r| r.len() >= 3).collect();
    // Without its outer ring a polygon is nothing (its holes alone are not an area).
    if rings.is_empty() || v.as_array()?.first().map(ring_of).map(|r| r.len() < 3).unwrap_or(true) {
        return None;
    }
    let (mut w, mut s, mut e, mut n) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for p in &rings[0] {
        w = w.min(p[0]);
        e = e.max(p[0]);
        s = s.min(p[1]);
        n = n.max(p[1]);
    }
    Some(Poly { rings, bbox: [w, s, e, n] })
}

impl Shape {
    /// A GeoJSON Feature, FeatureCollection, Polygon or MultiPolygon (or the same as JSON text).
    pub fn parse(v: &Value) -> Result<Shape, String> {
        if let Some(s) = v.as_str() {
            let v: Value = serde_json::from_str(s).map_err(|e| format!("geometry is not valid JSON: {e}"))?;
            return Shape::parse(&v);
        }
        let mut polys = Vec::new();
        collect(v, &mut polys, 0)?;
        if polys.is_empty() {
            return Err("geometry has no polygon with at least 3 points".into());
        }
        Ok(Shape { polys })
    }

    /// The box around every polygon: [west, south, east, north].
    pub fn bbox(&self) -> [f64; 4] {
        let mut b = [f64::MAX, f64::MAX, f64::MIN, f64::MIN];
        for p in &self.polys {
            b = [b[0].min(p.bbox[0]), b[1].min(p.bbox[1]), b[2].max(p.bbox[2]), b[3].max(p.bbox[3])];
        }
        b
    }

    /// Whether the cell [west, south, east, north] and the outline overlap.
    pub fn touches(&self, r: [f64; 4]) -> bool {
        self.polys.iter().any(|p| {
            let edges: Vec<([f64; 2], [f64; 2])> = edges(p).collect();
            poly_touches(&edges, p.bbox, r)
        })
    }

    /// Every tile of `level` the outline touches, in id order.
    pub fn tiles(&self, level: u8) -> Vec<u64> {
        let mut out = std::collections::BTreeSet::new();
        let s = LEVEL_SIZE[level as usize];
        let n = columns(level);
        for p in &self.polys {
            let b = p.bbox;
            let (c0, c1) = (col_of(level, b[0]), col_of(level, b[2]));
            let (r0, r1) = (row_of(level, b[1]), row_of(level, b[3]));
            let all: Vec<([f64; 2], [f64; 2])> = edges(p).collect();
            for row in r0..=r1 {
                // Only the edges that reach this row of cells can cross one of its cells, or cross the ray from a cell's centre.
                let (ys, yn) = (-90.0 + row as f64 * s, -90.0 + (row + 1) as f64 * s);
                let band: Vec<([f64; 2], [f64; 2])> = all.iter().copied().filter(|(a, b)| a[1].max(b[1]) >= ys && a[1].min(b[1]) <= yn).collect();
                for col in c0..=c1 {
                    let id = row * n + col;
                    if poly_touches(&band, p.bbox, tile_rect(level, id)) {
                        out.insert(id);
                    }
                }
            }
        }
        out.into_iter().collect()
    }
}

fn collect(v: &Value, out: &mut Vec<Poly>, depth: usize) -> Result<(), String> {
    if depth > 4 {
        return Err("geometry is nested too deeply".into());
    }
    match v.get("type").and_then(|t| t.as_str()) {
        Some("Feature") => collect(v.get("geometry").ok_or("the Feature has no geometry")?, out, depth + 1),
        Some("FeatureCollection") => {
            for f in v.get("features").and_then(|f| f.as_array()).ok_or("the FeatureCollection has no features")? {
                collect(f, out, depth + 1)?;
            }
            Ok(())
        }
        Some("Polygon") => {
            out.extend(v.get("coordinates").and_then(poly_of));
            Ok(())
        }
        Some("MultiPolygon") => {
            for p in v.get("coordinates").and_then(|c| c.as_array()).ok_or("the MultiPolygon has no coordinates")? {
                out.extend(poly_of(p));
            }
            Ok(())
        }
        Some(t) => Err(format!("geometry must be a Polygon or MultiPolygon, not {t}")),
        None => Err("geometry must be a GeoJSON Feature, Polygon or MultiPolygon".into()),
    }
}

fn edges(p: &Poly) -> impl Iterator<Item = ([f64; 2], [f64; 2])> + '_ {
    p.rings.iter().flat_map(|r| (0..r.len()).map(move |i| (r[i], r[(i + 1) % r.len()])))
}

/// How far a cell is shrunk before the test, so that an edge lying on a cell's side (a box drawn on whole degrees) belongs to
/// the cell on its inner side only.
const EDGE_EPS: f64 = 1e-9;

/// `edges`: every edge of the polygon's rings that can matter for the cell `r` (all of them, or those reaching its row).
fn poly_touches(edges: &[([f64; 2], [f64; 2])], bbox: [f64; 4], r: [f64; 4]) -> bool {
    let r = [r[0] + EDGE_EPS, r[1] + EDGE_EPS, r[2] - EDGE_EPS, r[3] - EDGE_EPS];
    if bbox[0] > r[2] || bbox[2] < r[0] || bbox[1] > r[3] || bbox[3] < r[1] {
        return false;
    }
    if edges.iter().any(|(a, b)| seg_touches_rect(*a, *b, r)) {
        return true;
    }
    // No edge comes near the cell, so it is wholly inside or wholly outside: its centre says which. Even-odd over every ring
    // counts a point in a hole as outside.
    let c = [(r[0] + r[2]) / 2.0, (r[1] + r[3]) / 2.0];
    let mut inside = false;
    for (a, b) in edges {
        if (a[1] > c[1]) != (b[1] > c[1]) && c[0] < (b[0] - a[0]) * (c[1] - a[1]) / (b[1] - a[1]) + a[0] {
            inside = !inside;
        }
    }
    inside
}

/// Whether any part of the segment a-b lies in the closed rectangle (Liang-Barsky clipping).
fn seg_touches_rect(a: [f64; 2], b: [f64; 2], r: [f64; 4]) -> bool {
    let (dx, dy) = (b[0] - a[0], b[1] - a[1]);
    let (mut t0, mut t1) = (0.0f64, 1.0f64);
    for (p, q) in [(-dx, a[0] - r[0]), (dx, r[2] - a[0]), (-dy, a[1] - r[1]), (dy, r[3] - a[1])] {
        if p == 0.0 {
            // Parallel to this side: outside it means outside the rectangle.
            if q < 0.0 {
                return false;
            }
        } else {
            let t = q / p;
            if p < 0.0 {
                if t > t1 {
                    return false;
                }
                t0 = t0.max(t);
            } else {
                if t < t0 {
                    return false;
                }
                t1 = t1.min(t);
            }
        }
    }
    t0 <= t1
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn shape(v: Value) -> Shape {
        Shape::parse(&v).unwrap()
    }

    fn rect_poly(w: f64, s: f64, e: f64, n: f64) -> Value {
        json!([[[w, s], [e, s], [e, n], [w, n], [w, s]]])
    }

    #[test]
    fn paths_are_valhallas() {
        assert_eq!(tile_path(2, 818660), "2/000/818/660");
        assert_eq!(tile_path(1, 47586), "1/047/586");
        assert_eq!(tile_path(0, 2986), "0/002/986");
        assert_eq!(parse_tile_path("2/000/818/660"), Some((2, 818660)));
        assert_eq!(parse_tile_path("2/000/818/660.gph"), Some((2, 818660)));
        assert_eq!(parse_tile_path("3/000/818/660"), None);
        assert_eq!(parse_tile_path("2/000/../660"), None);
        assert_eq!(parse_tile_path("2/999/999/999"), None, "beyond the level's last tile");
        // Burley, Idaho, at each level.
        assert_eq!(tile_id(2, -113.79, 42.54), 530 * 1440 + 264);
        assert_eq!(tile_id(1, -113.79, 42.54), 132 * 360 + 66);
        assert_eq!(tile_id(0, -113.79, 42.54), 33 * 90 + 16);
        assert_eq!(tile_rect(2, 530 * 1440 + 264), [-114.0, 42.5, -113.75, 42.75]);
    }

    #[test]
    fn an_idaho_like_outline() {
        // Idaho's rough outline: the panhandle in the north, the wide south.
        let idaho = shape(json!({"type": "Feature", "properties": {}, "geometry": {"type": "Polygon", "coordinates": [[
            [-117.24, 44.30], [-117.03, 48.99], [-116.05, 49.00], [-116.05, 47.98], [-115.72, 47.42], [-114.36, 46.67],
            [-114.32, 45.47], [-113.45, 44.86], [-112.84, 44.38], [-111.05, 44.48], [-111.05, 42.00], [-117.03, 42.00],
            [-117.24, 44.30]]]}}));
        let l0 = idaho.tiles(0);
        let l1 = idaho.tiles(1);
        let l2 = idaho.tiles(2);
        // Boise, Burley and Coeur d'Alene are in; Missoula (Montana, east of the panhandle) and Salt Lake City are not.
        for (lon, lat) in [(-116.20, 43.61), (-113.79, 42.54), (-116.78, 47.68)] {
            assert!(l2.contains(&tile_id(2, lon, lat)), "{lon},{lat}");
            assert!(l1.contains(&tile_id(1, lon, lat)), "{lon},{lat}");
            assert!(l0.contains(&tile_id(0, lon, lat)), "{lon},{lat}");
        }
        for (lon, lat) in [(-113.99, 46.87), (-111.89, 40.76)] {
            assert!(!l2.contains(&tile_id(2, lon, lat)), "{lon},{lat}");
        }
        // Inside the bounding box but outside the panhandle (north-east corner): not a tile of Idaho.
        assert!(!l2.contains(&tile_id(2, -111.5, 48.5)));
        // A tile wholly inside, touched by no edge.
        assert!(l2.contains(&tile_id(2, -114.6, 43.4)));
        // The whole state is some 430 level 2 tiles of the 725 in its box.
        let b = idaho.bbox();
        assert_eq!(tiles_in_box(2, b).len(), 725);
        assert!(l2.len() > 400 && l2.len() < 470, "{}", l2.len());
        assert!(l1.len() > 30 && l1.len() < 45 && l0.len() <= 6, "{} {}", l1.len(), l0.len());
    }

    #[test]
    fn an_outline_smaller_than_one_tile() {
        let s = shape(json!({"type": "Polygon", "coordinates": rect_poly(-113.95, 42.55, -113.80, 42.65)}));
        assert_eq!(s.tiles(2), vec![530 * 1440 + 264]);
        assert_eq!(s.tiles(1), vec![132 * 360 + 66]);
        assert_eq!(s.tiles(0), vec![33 * 90 + 16]);
        // A triangle inside one cell, none of whose edges meets the cell's sides.
        let t = shape(json!({"type": "Polygon", "coordinates": [[[-113.9, 42.6], [-113.85, 42.6], [-113.87, 42.62]]]}));
        assert_eq!(t.tiles(2), vec![530 * 1440 + 264]);
    }

    #[test]
    fn a_multipolygon_is_both_parts_and_not_the_gap() {
        let mut coords = vec![rect_poly(-113.95, 42.55, -113.80, 42.65)];
        coords.push(rect_poly(-100.20, 40.05, -100.10, 40.15));
        let s = shape(json!({"type": "MultiPolygon", "coordinates": coords}));
        let l2 = s.tiles(2);
        assert_eq!(l2.len(), 2);
        assert!(l2.contains(&tile_id(2, -113.9, 42.6)) && l2.contains(&tile_id(2, -100.15, 40.1)));
        assert!(!l2.contains(&tile_id(2, -107.0, 41.0)));
    }

    #[test]
    fn holes_are_left_out() {
        // A 2 degree square on whole degrees with a 0.8 degree hole in the middle: the level 2 tiles wholly in the hole are
        // not the region's.
        let s = shape(json!({"type": "Polygon", "coordinates": [
            [[-115.0, 42.0], [-113.0, 42.0], [-113.0, 44.0], [-115.0, 44.0], [-115.0, 42.0]],
            [[-114.4, 42.6], [-113.6, 42.6], [-113.6, 43.4], [-114.4, 43.4], [-114.4, 42.6]]]}));
        let l2 = s.tiles(2);
        assert!(!l2.contains(&tile_id(2, -114.1, 43.1)), "inside the hole");
        assert!(l2.contains(&tile_id(2, -114.9, 43.1)), "in the ring around it");
        assert!(l2.contains(&tile_id(2, -114.3, 43.1)), "the hole's edge passes through");
        // The outer edges lie on tile sides: 8 x 8 tiles, none beyond them, less the 2 x 2 wholly inside the hole.
        assert_eq!(l2.len(), 64 - 4);
        assert!(!l2.contains(&tile_id(2, -112.9, 43.1)) && !l2.contains(&tile_id(2, -115.1, 43.1)));
        assert!(!s.touches([-114.2, 42.8, -113.8, 43.2]));
        assert!(s.touches([-116.0, 42.8, -114.8, 43.2]));
    }

    #[test]
    fn the_antimeridian_and_bad_input_do_not_panic() {
        let s = shape(json!({"type": "Polygon", "coordinates": rect_poly(179.5, 50.0, 181.0, 51.0)}));
        assert!(!s.tiles(2).is_empty());
        let w = shape(json!({"type": "Polygon", "coordinates": rect_poly(-181.0, -91.0, -179.0, -89.0)}));
        assert!(!w.tiles(0).is_empty());
        assert!(Shape::parse(&json!({"type": "Point", "coordinates": [1, 2]})).is_err());
        assert!(Shape::parse(&json!({"type": "Polygon", "coordinates": [[[1, 2], [3, 4]]]})).is_err());
        assert!(Shape::parse(&json!("not json")).is_err());
        let text = json!({"type": "Polygon", "coordinates": rect_poly(-113.95, 42.55, -113.80, 42.65)}).to_string();
        assert_eq!(Shape::parse(&json!(text)).unwrap().tiles(2).len(), 1);
        assert!(tiles_in_box(2, [f64::NAN, 0.0, 1.0, 1.0]).is_empty());
    }
}
