//! Surface-change transition candidates. Port of navi `mvum_surface_change.py`: walks the road route
//! through `trace_attributes` and emits a candidate wherever the surface category changes.
use crate::valhalla::{decode_polyline6, encode_polyline6, TraceEdge, Valhalla};
use crate::grid::haversine_m;

pub const MIN_STRETCH_M: f64 = 100.0;
pub const MAX_BOUNDARIES: usize = 10;
pub const MAX_TRACE_POINTS: usize = 15000;
pub const MAX_TRACE_PATH_M: f64 = 150_000.0;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Cat {
    Paved,
    Unpaved,
    Track,
    Trail,
}
impl Cat {
    pub fn name(self) -> &'static str {
        match self {
            Cat::Paved => "paved",
            Cat::Unpaved => "unpaved",
            Cat::Track => "track",
            Cat::Trail => "trail",
        }
    }
}

const PAVED: [&str; 12] = [
    "paved_smooth", "paved", "paved_rough", "asphalt", "concrete", "concrete:lanes", "concrete:plates",
    "paving_stones", "sett", "cobblestone", "metal", "wood",
];
const UNPAVED: [&str; 10] = ["compacted", "dirt", "gravel", "fine_gravel", "ground", "sand", "earth", "mud", "grass", "unpaved"];
const DIRT_TRACK: [&str; 2] = ["dirt", "compacted"];
const TRAIL_USES: [&str; 8] = ["path", "footway", "cycleway", "bridleway", "steps", "pedestrian", "mountain_bike", "sidewalk"];

fn is_paved(s: &str) -> bool {
    !s.is_empty() && PAVED.contains(&s)
}

/// `classify_surface`: trail-like use, then track, then unpaved/paved surface; None if unknown.
pub fn classify_surface(e: &TraceEdge) -> Option<Cat> {
    let use_ = e.use_.clone().unwrap_or_default().to_lowercase();
    let road_class = e.road_class.clone().unwrap_or_default().to_lowercase();
    let surface = e.surface.clone().unwrap_or_default().to_lowercase();
    if TRAIL_USES.contains(&use_.as_str()) {
        return Some(Cat::Trail);
    }
    if use_ == "track" || (road_class == "service_other" && !is_paved(&surface)) {
        return Some(Cat::Track);
    }
    if DIRT_TRACK.contains(&surface.as_str()) && use_ == "road" {
        return Some(Cat::Track);
    }
    if UNPAVED.contains(&surface.as_str()) {
        return Some(Cat::Unpaved);
    }
    if is_paved(&surface) {
        return Some(Cat::Paved);
    }
    None
}

fn cumulative_m(coords: &[(f64, f64)]) -> Vec<f64> {
    let mut cum = vec![0.0];
    for i in 1..coords.len() {
        cum.push(cum[i - 1] + haversine_m(coords[i - 1].0, coords[i - 1].1, coords[i].0, coords[i].1));
    }
    cum
}

#[derive(Clone)]
struct Run {
    cat: Option<Cat>,
    start_v: i64,
    end_v: i64,
}

fn collapse_short_runs(mut runs: Vec<Run>, cum: &[f64], min_m: f64) -> Vec<Run> {
    let last = cum.len() as i64 - 1;
    let mut changed = true;
    while changed && runs.len() > 1 {
        changed = false;
        for i in 0..runs.len() {
            let end_v = runs[i].end_v.min(last) as usize;
            let start_v = runs[i].start_v.min(last) as usize;
            if cum[end_v] - cum[start_v] >= min_m {
                continue;
            }
            if i > 0 {
                runs[i - 1].end_v = runs[i].end_v;
                runs.remove(i);
            } else {
                runs[i + 1].start_v = runs[i].start_v;
                runs.remove(i);
            }
            changed = true;
            break;
        }
        let mut j = 0;
        while j + 1 < runs.len() {
            if runs[j].cat == runs[j + 1].cat {
                runs[j].end_v = runs[j + 1].end_v;
                runs.remove(j + 1);
            } else {
                j += 1;
            }
        }
    }
    runs
}

/// A candidate: (lat, lon, from, to).
pub type Candidate = (f64, f64, Cat, Cat);

/// Pure boundary extraction (`_edges_to_candidates`).
pub fn edges_to_candidates(edges: &[TraceEdge], coords: &[(f64, f64)], max_boundaries: usize, min_stretch_m: f64) -> Vec<Candidate> {
    if edges.is_empty() || coords.len() < 2 {
        return vec![];
    }
    let cum = cumulative_m(coords);
    let mut runs: Vec<Run> = Vec::new();
    for e in edges {
        let cat = classify_surface(e);
        let (Some(bi), Some(ei)) = (e.begin_shape_index, e.end_shape_index) else { continue };
        if let Some(l) = runs.last_mut() {
            if l.cat == cat {
                l.end_v = ei;
                continue;
            }
        }
        runs.push(Run { cat, start_v: bi, end_v: ei });
    }
    let runs = collapse_short_runs(runs, &cum, min_stretch_m);
    let mut out = Vec::new();
    for w in runs.windows(2) {
        let (prev, cur) = (&w[0], &w[1]);
        let (Some(f), Some(t)) = (prev.cat, cur.cat) else { continue };
        if f == t {
            continue;
        }
        let v = cur.start_v;
        if v < 0 || v as usize >= coords.len() {
            continue;
        }
        out.push((coords[v as usize].0, coords[v as usize].1, f, t));
        if out.len() >= max_boundaries {
            break;
        }
    }
    out
}

/// Road shape (lat, lon) of Valhalla's auto route between the endpoints; empty on any failure.
pub fn get_route_shape(v: &dyn Valhalla, start: (f64, f64), end: (f64, f64)) -> Vec<(f64, f64)> {
    match v.route(start, end, "auto") {
        Ok(t) => t.shape,
        Err(_) => vec![],
    }
}

fn chunk_bounds(coords: &[(f64, f64)], max_points: usize, max_path_m: f64) -> Vec<(usize, usize)> {
    let n = coords.len();
    let cum = cumulative_m(coords);
    let mut bounds = Vec::new();
    let mut start = 0;
    while start + 1 < n {
        let mut end = start + 1;
        while end + 1 < n && end + 1 - start + 1 <= max_points && cum[end + 1] - cum[start] <= max_path_m {
            end += 1;
        }
        bounds.push((start, end));
        start = end;
    }
    bounds
}

/// `get_surface_change_candidates`: trace in chunks, join chunks that succeeded back to back, extract
/// boundaries. A failing chunk breaks the run. At most MAX_BOUNDARIES in total.
pub fn get_surface_change_candidates(v: &dyn Valhalla, coords: &[(f64, f64)]) -> Vec<Candidate> {
    get_surface_change_candidates_with(v, coords, MAX_TRACE_POINTS, MAX_TRACE_PATH_M)
}

/// Same, with explicit chunk limits (tests shrink them to exercise the chunk joining).
pub fn get_surface_change_candidates_with(v: &dyn Valhalla, coords: &[(f64, f64)], max_points: usize, max_path_m: f64) -> Vec<Candidate> {
    if coords.len() < 2 {
        return vec![];
    }
    let mut candidates: Vec<Candidate> = Vec::new();
    let mut gcoords: Vec<(f64, f64)> = Vec::new();
    let mut gedges: Vec<TraceEdge> = Vec::new();
    let flush = |gcoords: &mut Vec<(f64, f64)>, gedges: &mut Vec<TraceEdge>, candidates: &mut Vec<Candidate>| {
        if !gedges.is_empty() {
            candidates.extend(edges_to_candidates(gedges, gcoords, MAX_BOUNDARIES, MIN_STRETCH_M));
        }
        gcoords.clear();
        gedges.clear();
    };
    for (s, e) in chunk_bounds(coords, max_points, max_path_m) {
        let chunk = &coords[s..=e];
        let traced = v.trace_attributes(&encode_polyline6(chunk)).ok().map(|t| {
            let shape = match &t.shape {
                Some(sh) if !sh.is_empty() => decode_polyline6(sh),
                _ => chunk.to_vec(),
            };
            (t.edges, shape)
        });
        let Some((edges, mut shape)) = traced else {
            flush(&mut gcoords, &mut gedges, &mut candidates);
            continue;
        };
        let offset: i64 = if gcoords.is_empty() {
            0
        } else {
            shape.remove(0);
            gcoords.len() as i64 - 1
        };
        for mut ed in edges {
            if let Some(b) = ed.begin_shape_index.as_mut() {
                *b += offset;
            }
            if let Some(b) = ed.end_shape_index.as_mut() {
                *b += offset;
            }
            gedges.push(ed);
        }
        gcoords.extend(shape);
    }
    flush(&mut gcoords, &mut gedges, &mut candidates);
    candidates.truncate(MAX_BOUNDARIES);
    candidates
}
