//! Transition-cell sourcing for the unified search. Port of navi `transitions.py`: parking,
//! trailheads, road termini (and surface change via the `Valhalla` trait), the per-type
//! "closest 15 within 5 km of the endpoint line" cap, and lat/lon -> cell mapping.
use crate::cost::*;
use crate::grid::GridMeta;
use crate::pack::{line_box, near_line, PackSource, PointRec};
use crate::valhalla::Valhalla;
use std::collections::HashSet;

pub const CAP_PER_TYPE: usize = 15;
pub const CAP_RADIUS_M: f64 = 5000.0;
const EARTH_R_M: f64 = 6_371_000.0;

/// (lat, lon, from_mode, to_mode, cost_s)
pub type Tup = (f64, f64, usize, usize, f64);
/// (row, col, from_mode, to_mode, cost_s)
pub type Cell = (i64, i64, usize, usize, f64);

fn bidir(lat: f64, lon: f64, pairs: &[(Mode, Mode)], cost: f64, out: &mut Vec<Tup>) {
    for &(a, b) in pairs {
        out.push((lat, lon, a.idx(), b.idx(), cost));
        out.push((lat, lon, b.idx(), a.idx(), cost));
    }
}

fn bearing(p1: f64, l1: f64, p2: f64, l2: f64) -> f64 {
    ((l2 - l1).sin() * p2.cos()).atan2(p1.cos() * p2.sin() - p1.sin() * p2.cos() * (l2 - l1).cos())
}

/// Great-circle perpendicular distance (m) from a point to the line through the two endpoints.
pub fn cross_track_distance_m(lat: f64, lon: f64, line: ((f64, f64), (f64, f64))) -> f64 {
    let ((lat1, lon1), (lat2, lon2)) = line;
    let (p1, l1) = (lat1.to_radians(), lon1.to_radians());
    let (p3, l3) = (lat.to_radians(), lon.to_radians());
    let h = ((p3 - p1) / 2.0).sin().powi(2) + p1.cos() * p3.cos() * ((l3 - l1) / 2.0).sin().powi(2);
    let d13 = 2.0 * h.sqrt().min(1.0).asin();
    if lat1 == lat2 && lon1 == lon2 {
        return d13 * EARTH_R_M;
    }
    let dth = bearing(p1, l1, p3, l3) - bearing(p1, l1, lat2.to_radians(), lon2.to_radians());
    (d13.sin() * dth.sin()).clamp(-1.0, 1.0).asin().abs() * EARTH_R_M
}

/// Cap one type: group by (lat, lon), keep the closest `CAP_PER_TYPE` points within `CAP_RADIUS_M` of
/// the line, flatten. `line == None` leaves the list uncapped.
pub fn cap_candidates(raw: Vec<Tup>, line: Option<((f64, f64), (f64, f64))>) -> Vec<Tup> {
    let Some(line) = line else { return raw };
    if raw.is_empty() {
        return raw;
    }
    let mut uniq: Vec<(u64, u64)> = Vec::new();
    let mut seen = HashSet::new();
    for t in &raw {
        let k = (t.0.to_bits(), t.1.to_bits());
        if seen.insert(k) {
            uniq.push(k);
        }
    }
    let mut scored: Vec<(f64, (u64, u64))> = uniq
        .into_iter()
        .map(|k| (cross_track_distance_m(f64::from_bits(k.0), f64::from_bits(k.1), line), k))
        .filter(|(d, _)| *d <= CAP_RADIUS_M)
        .collect();
    scored.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap().then(a.1.cmp(&b.1)));
    scored.truncate(CAP_PER_TYPE);
    let keep: HashSet<(u64, u64)> = scored.into_iter().map(|(_, k)| k).collect();
    raw.into_iter().filter(|t| keep.contains(&(t.0.to_bits(), t.1.to_bits()))).collect()
}

fn blocked(access: &str) -> bool {
    matches!(access, "private" | "no" | "permit")
}

pub fn parking_transitions(
    pack: &dyn PackSource, line: ((f64, f64), (f64, f64)), buffer_m: f64,
) -> Result<Vec<Tup>, String> {
    let (a, b) = line;
    let (min_lon, max_lon, min_lat, max_lat) = line_box(a, b, buffer_m);
    let cands: Vec<PointRec> = pack.parking_in_box(min_lon, max_lon, min_lat, max_lat).map_err(|e| e.to_string())?;
    let pairs = [(Mode::Foot, Mode::Vehicle), (Mode::Foot, Mode::FourW), (Mode::Foot, Mode::TwoW)];
    let mut out = Vec::new();
    for p in near_line(cands, a, b, buffer_m) {
        if blocked(&p.access) {
            continue;
        }
        bidir(p.lat, p.lon, &pairs, TRANSITION_COST_PARKING_S, &mut out);
    }
    Ok(out)
}

pub fn trailhead_transitions(
    pack: &dyn PackSource, line: ((f64, f64), (f64, f64)), buffer_m: f64,
) -> Result<Vec<Tup>, String> {
    let (a, b) = line;
    let (min_lon, max_lon, min_lat, max_lat) = line_box(a, b, buffer_m);
    let cands = pack.trailheads_in_box(min_lon, max_lon, min_lat, max_lat).map_err(|e| e.to_string())?;
    let pairs = [(Mode::Foot, Mode::FourW), (Mode::Foot, Mode::TwoW)];
    let mut out = Vec::new();
    for p in near_line(cands, a, b, buffer_m) {
        bidir(p.lat, p.lon, &pairs, TRANSITION_COST_TRAILHEAD_S, &mut out);
    }
    Ok(out)
}

/// Road-terminus switches from the trail raster: a road(5)/track(15) cell with an off-network
/// (value 0, finite elevation) 8-neighbour. Out-of-bounds neighbours count as on-network.
pub fn road_terminus_transitions(
    meta: &GridMeta, trail_grid: &[u8], elevation: Option<&[f32]>,
) -> Vec<Tup> {
    let (rows, cols) = (meta.rows, meta.cols);
    let offnet = |i: usize| trail_grid[i] == 0 && elevation.is_none_or(|e| e[i].is_finite());
    let mut out = Vec::new();
    let pairs = [(Mode::Foot, Mode::Vehicle)];
    for r in 0..rows {
        for c in 0..cols {
            let t = trail_grid[r * cols + c];
            if t != 5 && t != 15 {
                continue;
            }
            let mut has = false;
            'n: for dr in -1i64..=1 {
                for dc in -1i64..=1 {
                    let (nr, nc) = (r as i64 + dr, c as i64 + dc);
                    if nr < 0 || nc < 0 || nr >= rows as i64 || nc >= cols as i64 {
                        continue;
                    }
                    if offnet(nr as usize * cols + nc as usize) {
                        has = true;
                        break 'n;
                    }
                }
            }
            if has {
                let (lat, lon) = meta.pixel_to_latlon(r as i64, c as i64);
                bidir(lat, lon, &pairs, TRANSITION_COST_ROAD_TERMINUS_S, &mut out);
            }
        }
    }
    out
}

pub fn surface_change_transitions(valhalla: &dyn Valhalla, line: ((f64, f64), (f64, f64))) -> Vec<Tup> {
    let shape = crate::surface::get_route_shape(valhalla, line.0, line.1);
    let pairs = [(Mode::Vehicle, Mode::FourW), (Mode::FourW, Mode::TwoW)];
    let mut out = Vec::new();
    if !shape.is_empty() {
        for (lat, lon, _f, _t) in crate::surface::get_surface_change_candidates(valhalla, &shape) {
            bidir(lat, lon, &pairs, TRANSITION_COST_SURFACE_CHANGE_S, &mut out);
        }
    }
    out
}

/// All transition cells for one search (`gather_transition_cells`).
pub fn gather_transition_cells(
    meta: &GridMeta, pack: &dyn PackSource, valhalla: &dyn Valhalla,
    endpoint_line: Option<((f64, f64), (f64, f64))>, trail_grid: Option<&[u8]>, elevation: Option<&[f32]>,
    buffer_m: f64,
) -> Result<Vec<Cell>, String> {
    let mut per_type: Vec<Vec<Tup>> = Vec::new();
    if let Some(line) = endpoint_line {
        per_type.push(cap_candidates(parking_transitions(pack, line, buffer_m)?, endpoint_line));
        per_type.push(cap_candidates(trailhead_transitions(pack, line, buffer_m)?, endpoint_line));
    }
    if let Some(tg) = trail_grid {
        per_type.push(cap_candidates(road_terminus_transitions(meta, tg, elevation), endpoint_line));
    }
    if let Some(line) = endpoint_line {
        per_type.push(cap_candidates(surface_change_transitions(valhalla, line), endpoint_line));
    }
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for raw in per_type {
        for (lat, lon, fm, tm, cost) in raw {
            let (row, col) = meta.latlon_to_pixel_eps(lat, lon);
            if !(0 <= row && row < meta.rows as i64 && 0 <= col && col < meta.cols as i64) {
                continue;
            }
            if seen.insert((row, col, fm, tm)) {
                out.push((row, col, fm, tm, cost));
            }
        }
    }
    Ok(out)
}
