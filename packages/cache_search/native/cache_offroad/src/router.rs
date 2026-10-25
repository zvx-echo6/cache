//! `route()`: the unified Auto search. Port of navi `router.py::_route_auto` (+ `_auto_eligible_modes`,
//! `_spatial_eligible_modes`, `_eligible_modes_from_category`, `_auto_bbox`, `_check_cell_budget`,
//! `_fetch_auto_rasters`, `_build_mvum_by_mode`, `_render_unified_path`). Explicit single-mode requests use the same search
//! with only that mode seeded.
use crate::astar::{astar_multigoal_multimode, MultiModeInput};
use crate::cost::*;
use crate::grid::{self, haversine_m, GridMeta};
use crate::mvum;
use crate::pack::{Layer, PackSource};
use crate::transitions;
use crate::valhalla::{LocateSnap, NetworkRoute, Valhalla};
use serde_json::{json, Value};
use std::collections::{BTreeSet, HashMap};
use std::time::Instant;

pub const AUTO_SNAP_TIGHT_M: f64 = 5.0;
pub const AUTO_SNAP_RELAXED_M: f64 = 100.0;
pub const FLAT_TERRAIN_DELTA_M: f64 = 5.0;
pub const FLAT_SAMPLE_RADIUS_M: f64 = 50.0;
pub const CORRIDOR_PAD_KM: f64 = 10.0;
pub const CORRIDOR_ENDPOINT_PAD_KM: f64 = 5.0;
pub const DEFAULT_MAX_CELLS: usize = 20_000_000;

const PAVED: [&str; 9] = [
    "motorway", "trunk", "primary", "secondary", "tertiary", "unclassified", "residential", "service", "service_other",
];
const TRACK_USE: [&str; 1] = ["track"];
const PATH_USE: [&str; 6] = ["path", "footway", "cycleway", "bridleway", "steps", "pedestrian"];

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Boundary {
    Strict,
    Pragmatic,
    Emergency,
}
impl Boundary {
    pub fn id(self) -> i64 {
        match self {
            Boundary::Strict => 0,
            Boundary::Pragmatic => 1,
            Boundary::Emergency => 2,
        }
    }
    pub fn name(self) -> &'static str {
        ["strict", "pragmatic", "emergency"][self.id() as usize]
    }
    pub fn from_name(s: &str) -> Option<Boundary> {
        match s {
            "strict" => Some(Boundary::Strict),
            "pragmatic" => Some(Boundary::Pragmatic),
            "emergency" => Some(Boundary::Emergency),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RequestMode {
    Auto,
    Single(Mode),
}

#[derive(Debug, Clone)]
pub struct RouteRequest {
    /// (lat, lon)
    pub start: (f64, f64),
    pub end: (f64, f64),
    pub mode: RequestMode,
    pub boundary: Boundary,
    /// per-mode multiplier on on-network cells; missing = 1.0
    pub network_affinity: Option<HashMap<Mode, f64>>,
    /// OSM "key:value" hints used to seed Auto (same table as navi); None = spatial probe via Valhalla.
    pub start_category: Option<String>,
    pub end_category: Option<String>,
    /// Explicit seed modes (foot is always added); override the category / spatial seeding when set.
    pub start_modes: Option<Vec<Mode>>,
    pub end_modes: Option<Vec<Mode>>,
    /// (month, day) for seasonal MVUM checks; None = no seasonal check (what navi's API does).
    pub mvum_on_date: Option<(u32, u32)>,
}
impl RouteRequest {
    pub fn new(start: (f64, f64), end: (f64, f64), mode: RequestMode, boundary: Boundary) -> Self {
        RouteRequest { start, end, mode, boundary, network_affinity: None, start_category: None, end_category: None, start_modes: None, end_modes: None, mvum_on_date: None }
    }
}

#[derive(Debug, Clone)]
pub struct RouteOptions {
    /// Grid cell cap (navi: 20M; the phone: about 8M).
    pub max_cells: usize,
    pub bbox_pad_deg: f64,
    pub bbox_max_span_deg: f64,
    pub corridor_pad_km: f64,
    pub corridor_endpoint_pad_km: f64,
    pub transition_buffer_m: f64,
}
impl Default for RouteOptions {
    fn default() -> Self {
        RouteOptions {
            max_cells: DEFAULT_MAX_CELLS,
            bbox_pad_deg: 0.02,
            bbox_max_span_deg: 2.0,
            corridor_pad_km: CORRIDOR_PAD_KM,
            corridor_endpoint_pad_km: CORRIDOR_ENDPOINT_PAD_KM,
            transition_buffer_m: 5000.0,
        }
    }
}

#[derive(Debug, thiserror::Error)]
pub enum RouteError {
    #[error("route too long: estimated {estimated} cells exceeds budget {max}")]
    TooLong { estimated: usize, max: usize },
    #[error("failed to load terrain: {0}")]
    Terrain(String),
    #[error("endpoint outside grid bounds")]
    OutsideGrid,
    #[error("no unified route found")]
    NoRoute,
}

#[derive(Debug, Clone)]
pub struct PathCell {
    pub row: i64,
    pub col: i64,
    pub mode: Mode,
    pub lat: f64,
    pub lon: f64,
}

#[derive(Debug, Clone)]
pub struct Segment {
    pub mode: Mode,
    /// (lon, lat)
    pub coords: Vec<(f64, f64)>,
}

#[derive(Debug, Clone)]
pub struct TransitionMark {
    pub lat: f64,
    pub lon: f64,
    pub from_mode: Mode,
    pub to_mode: Mode,
}

#[derive(Debug, Clone, Default)]
pub struct RouteStats {
    pub rows: usize,
    pub cols: usize,
    pub cells: usize,
    pub transition_cells: usize,
    pub expanded_states: u64,
    pub ms_rasters: u128,
    pub ms_layers: u128,
    pub ms_transitions: u128,
    pub ms_search: u128,
}

#[derive(Debug, Clone)]
pub struct RouteResult {
    /// "unified" (A* over cells) or "D" (the Valhalla road-to-road bypass).
    pub scenario: String,
    pub boundary: Boundary,
    pub selected_mode_set: Vec<String>,
    pub selected_mode: String,
    pub total_distance_km: f64,
    pub total_effort_minutes: f64,
    /// total effort in seconds exactly as the kernel accumulated it
    pub cost_s: f64,
    pub cells: Vec<PathCell>,
    pub segments: Vec<Segment>,
    pub transitions: Vec<TransitionMark>,
    /// full path (lon, lat), consecutive duplicates removed
    pub combined: Vec<(f64, f64)>,
    pub auto_bypass: bool,
    pub network: Option<NetworkRoute>,
    pub meta: Option<GridMeta>,
    pub stats: RouteStats,
}

impl RouteResult {
    /// navi's `/api/offroute` response shape.
    pub fn to_json(&self) -> Value {
        if let Some(n) = &self.network {
            let coords: Vec<Value> = n.coords.iter().map(|&(x, y)| json!([x, y])).collect();
            let man: Vec<Value> = n
                .maneuvers
                .iter()
                .map(|m| json!({"instruction": m.instruction, "type": m.kind, "distance_km": m.distance_km,
                                 "time_seconds": m.time_seconds, "street_names": m.street_names}))
                .collect();
            return json!({
                "status": "ok",
                "route": {"type": "FeatureCollection", "features": [
                    {"type": "Feature", "properties": {"segment_type": "network", "distance_km": n.distance_km,
                        "duration_minutes": n.duration_min, "maneuvers": man, "network_mode": "vehicle"},
                     "geometry": {"type": "LineString", "coordinates": coords.clone()}},
                    {"type": "Feature", "properties": {"segment_type": "combined", "network_mode": "vehicle"},
                     "geometry": {"type": "LineString", "coordinates": coords}}]},
                "summary": {"total_distance_km": n.distance_km, "total_effort_minutes": n.duration_min,
                            "scenario": "D", "network_mode": "vehicle", "auto_bypass": true},
                "selected_mode": "vehicle", "selected_mode_set": ["vehicle"],
            });
        }
        let mut features = Vec::new();
        for s in &self.segments {
            features.push(json!({"type": "Feature",
                "properties": {"segment_type": "unified", "mode": s.mode.name(), "network_mode": s.mode.name()},
                "geometry": {"type": "LineString", "coordinates": s.coords.iter().map(|&(x, y)| json!([x, y])).collect::<Vec<_>>()}}));
        }
        for t in &self.transitions {
            features.push(json!({"type": "Feature",
                "properties": {"segment_type": "transition", "kind": "transition", "lat": t.lat, "lon": t.lon,
                               "from_mode": t.from_mode.name(), "to_mode": t.to_mode.name()},
                "geometry": {"type": "Point", "coordinates": [t.lon, t.lat]}}));
        }
        if self.combined.len() >= 2 {
            features.push(json!({"type": "Feature",
                "properties": {"segment_type": "combined", "boundary_mode": self.boundary.name(), "scenario": "unified"},
                "geometry": {"type": "LineString", "coordinates": self.combined.iter().map(|&(x, y)| json!([x, y])).collect::<Vec<_>>()}}));
        }
        json!({
            "status": "ok",
            "route": {"type": "FeatureCollection", "features": features},
            "summary": {"total_distance_km": self.total_distance_km, "total_effort_minutes": self.total_effort_minutes,
                        "scenario": "unified", "boundary_mode": self.boundary.name(), "selected_mode_set": self.selected_mode_set},
            "selected_mode": self.selected_mode, "selected_mode_set": self.selected_mode_set, "scenario": "unified",
        })
    }
}

// ---- eligibility ------------------------------------------------------------------------------

const ALL: [Mode; 4] = [Mode::Vehicle, Mode::FourW, Mode::TwoW, Mode::Foot];
const TRACK: [Mode; 3] = [Mode::FourW, Mode::TwoW, Mode::Foot];
const PATH: [Mode; 2] = [Mode::TwoW, Mode::Foot];
const FOOT: [Mode; 1] = [Mode::Foot];

fn category_table(key: &str) -> Option<&'static [Mode]> {
    Some(match key {
        "highway:motorway" | "highway:trunk" | "highway:primary" | "highway:secondary" | "highway:tertiary"
        | "highway:unclassified" | "highway:residential" | "highway:service" | "building:*" | "amenity:*"
        | "shop:*" | "office:*" | "tourism:hotel" | "tourism:motel" | "tourism:guest_house" | "tourism:hostel"
        | "tourism:apartment" | "leisure:park" | "place:city" | "place:town" | "place:village" | "place:hamlet"
        | "place:suburb" | "place:neighbourhood" | "railway:station" => &ALL,
        "highway:track" | "highway:trailhead" => &TRACK,
        "highway:path" | "highway:bridleway" => &PATH,
        "highway:footway" | "highway:steps" | "highway:pedestrian" | "natural:*" | "place:roadless_area"
        | "place:protected_area" | "landuse:forest" | "landuse:nature_reserve" | "tourism:camp_site"
        | "tourism:picnic_site" | "tourism:viewpoint" => &FOOT,
        _ => return None,
    })
}

/// Eligible modes for an OSM "key:value" hint: exact match, then "key:*"; None if unknown.
pub fn eligible_modes_from_category(category: Option<&str>) -> Option<BTreeSet<usize>> {
    let c = category?;
    if c.is_empty() {
        return None;
    }
    let m = category_table(c).or_else(|| {
        let (k, _) = c.split_once(':')?;
        category_table(&format!("{k}:*"))
    })?;
    Some(m.iter().map(|m| m.idx()).collect())
}

fn is_terrain_flat(pack: &dyn PackSource, lat: f64, lon: f64) -> bool {
    let dlat = FLAT_SAMPLE_RADIUS_M / 111320.0;
    let dlon = FLAT_SAMPLE_RADIUS_M / (111320.0 * lat.to_radians().cos().max(0.01));
    let pts = [(lat, lon), (lat + dlat, lon), (lat - dlat, lon), (lat, lon + dlon), (lat, lon - dlon)];
    let mut el = Vec::new();
    for (la, lo) in pts {
        let Some((r, c)) = grid::global_pixel(la, lo) else { return false };
        match pack.read_elevation(r, c, 1, 1) {
            Ok(v) if v[0].is_finite() => el.push(v[0] as f64),
            _ => return false,
        }
    }
    let mx = el.iter().cloned().fold(f64::MIN, f64::max);
    let mn = el.iter().cloned().fold(f64::MAX, f64::min);
    (mx - mn) < FLAT_TERRAIN_DELTA_M
}

pub type SnapCache = HashMap<(u64, u64, &'static str), Option<LocateSnap>>;

fn snap<'a>(cache: &'a mut SnapCache, v: &dyn Valhalla, lat: f64, lon: f64, costing: &'static str) -> &'a Option<LocateSnap> {
    cache.entry((lat.to_bits(), lon.to_bits(), costing)).or_insert_with(|| v.locate(lat, lon, costing))
}

/// Eligible modes of an untagged endpoint from Valhalla snaps (the per-mode distance + road-class rules).
pub fn spatial_eligible_modes(pack: &dyn PackSource, v: &dyn Valhalla, lat: f64, lon: f64, cache: &mut SnapCache) -> BTreeSet<usize> {
    let a = snap(cache, v, lat, lon, "auto").clone();
    let b = snap(cache, v, lat, lon, "bicycle").clone();
    let d_auto = a.as_ref().map_or(f64::INFINITY, |s| s.snap_distance_m);
    let cls_auto = a.as_ref().and_then(|s| s.road_class.clone());
    let use_auto = a.as_ref().and_then(|s| s.use_.clone());
    let d_bike = b.as_ref().map_or(f64::INFINITY, |s| s.snap_distance_m);
    let cls_bike = b.as_ref().and_then(|s| s.road_class.clone());
    let use_bike = b.as_ref().and_then(|s| s.use_.clone());
    let paved = |c: &Option<String>| c.as_deref().is_some_and(|c| PAVED.contains(&c));
    let is_use = |u: &Option<String>, set: &[&str]| u.as_deref().is_some_and(|u| set.contains(&u));

    let mut modes = BTreeSet::new();
    modes.insert(Mode::Foot.idx());
    if (d_auto <= AUTO_SNAP_TIGHT_M && paved(&cls_auto))
        || (d_auto <= AUTO_SNAP_RELAXED_M && paved(&cls_auto) && is_terrain_flat(pack, lat, lon))
    {
        modes.insert(Mode::Vehicle.idx());
    }
    if d_auto <= AUTO_SNAP_RELAXED_M && (paved(&cls_auto) || is_use(&use_auto, &TRACK_USE)) {
        modes.insert(Mode::FourW.idx());
    }
    if d_bike <= AUTO_SNAP_RELAXED_M && (paved(&cls_bike) || is_use(&use_bike, &TRACK_USE) || is_use(&use_bike, &PATH_USE)) {
        modes.insert(Mode::TwoW.idx());
    }
    modes
}

fn auto_eligible_modes(pack: &dyn PackSource, v: &dyn Valhalla, lat: f64, lon: f64, cat: Option<&str>, cache: &mut SnapCache) -> BTreeSet<usize> {
    let mut s = match eligible_modes_from_category(cat) {
        Some(t) => t,
        None => spatial_eligible_modes(pack, v, lat, lon, cache),
    };
    s.insert(Mode::Foot.idx());
    s
}

// ---- the search --------------------------------------------------------------------------------

/// Bbox covering both endpoints + pad, clamped to a span (`_auto_bbox`). (south, north, west, east)
pub fn auto_bbox(s: (f64, f64), e: (f64, f64), pad: f64, max_span: f64) -> (f64, f64, f64, f64) {
    let (mut south, mut north) = (s.0.min(e.0) - pad, s.0.max(e.0) + pad);
    let (mut west, mut east) = (s.1.min(e.1) - pad, s.1.max(e.1) + pad);
    if north - south > max_span || east - west > max_span {
        let (clat, clon, h) = ((s.0 + e.0) / 2.0, (s.1 + e.1) / 2.0, max_span / 2.0);
        south = clat - h;
        north = clat + h;
        west = clon - h;
        east = clon + h;
    }
    (south, north, west, east)
}

pub struct Router<'a> {
    pub pack: &'a dyn PackSource,
    pub valhalla: &'a dyn Valhalla,
    pub opts: RouteOptions,
}

pub fn route(pack: &dyn PackSource, valhalla: &dyn Valhalla, req: &RouteRequest, opts: &RouteOptions) -> Result<RouteResult, RouteError> {
    Router { pack, valhalla, opts: opts.clone() }.route(req)
}

impl<'a> Router<'a> {
    pub fn route(&self, req: &RouteRequest) -> Result<RouteResult, RouteError> {
        let (start, end) = (req.start, req.end);
        let (origin_set, goal_set) = match req.mode {
            RequestMode::Auto => {
                let mut cache = SnapCache::new();
                let with_foot = |v: &Vec<Mode>| -> BTreeSet<usize> {
                    let mut s: BTreeSet<usize> = v.iter().map(|m| m.idx()).collect();
                    s.insert(Mode::Foot.idx());
                    s
                };
                let s = match &req.start_modes {
                    Some(v) => with_foot(v),
                    None => auto_eligible_modes(self.pack, self.valhalla, start.0, start.1, req.start_category.as_deref(), &mut cache),
                };
                let e = match &req.end_modes {
                    Some(v) => with_foot(v),
                    None => auto_eligible_modes(self.pack, self.valhalla, end.0, end.1, req.end_category.as_deref(), &mut cache),
                };
                (s, e)
            }
            RequestMode::Single(m) => {
                let one: BTreeSet<usize> = [m.idx()].into_iter().collect();
                (one.clone(), one)
            }
        };

        // Valhalla bypass: pure road <-> road skips the raster pipeline entirely.
        if req.mode == RequestMode::Auto && origin_set.contains(&Mode::Vehicle.idx()) && goal_set.contains(&Mode::Vehicle.idx()) {
            if let Ok(n) = self.valhalla.route_vehicle(start, end) {
                return Ok(RouteResult {
                    scenario: "D".into(),
                    boundary: req.boundary,
                    selected_mode_set: vec!["vehicle".into()],
                    selected_mode: "vehicle".into(),
                    total_distance_km: n.distance_km,
                    total_effort_minutes: n.duration_min,
                    cost_s: n.duration_min * 60.0,
                    cells: vec![],
                    segments: vec![],
                    transitions: vec![],
                    combined: n.coords.clone(),
                    auto_bypass: true,
                    network: Some(n),
                    meta: None,
                    stats: RouteStats::default(),
                });
            }
        }

        // bbox + cell budget
        let t0 = Instant::now();
        let (south, north, west, east) = auto_bbox(start, end, self.opts.bbox_pad_deg, self.opts.bbox_max_span_deg);
        let (er, ec) = GridMeta::estimate_shape(south, north, west, east);
        let max_cells = self.opts.max_cells.min((i32::MAX as usize) / N_MODES);
        if er * ec > max_cells {
            return Err(RouteError::TooLong { estimated: er * ec, max: max_cells });
        }
        let meta = GridMeta::from_bbox(south, north, west, east);
        self.search_on_grid(req, meta, &origin_set, &goal_set, t0)
    }

    /// Everything after the grid is known: read layers, build cost layers, transitions, search, render.
    /// Public so tests can run on synthetic grids (`GridMeta::synthetic` + `MemPack`).
    pub fn search_on_grid(
        &self, req: &RouteRequest, meta: GridMeta, origin_set: &BTreeSet<usize>, goal_set: &BTreeSet<usize>, t0: Instant,
    ) -> Result<RouteResult, RouteError> {
        let (start, end) = (req.start, req.end);
        let (south, north, west, east) = meta.bounds;
        let (rows, cols) = (meta.rows, meta.cols);
        let terr = |e: crate::pack::PackError| RouteError::Terrain(e.to_string());
        let elevation = self.pack.read_elevation(meta.global_row0, meta.global_col0, rows, cols).map_err(terr)?;
        let rd = |l: Layer| self.pack.read_u8(l, meta.global_row0, meta.global_col0, rows, cols);
        let friction_raw = rd(Layer::Friction).map_err(terr)?;
        let friction_mult = friction_to_multiplier(&friction_raw);
        drop(friction_raw);
        let class = if self.pack.has_layer(Layer::Class) { Some(rd(Layer::Class).map_err(terr)?) } else { None };
        let barriers = rd(Layer::Barriers).map_err(terr)?;
        let trails = rd(Layer::Trails).map_err(terr)?;
        let wilderness = if self.pack.has_layer(Layer::Wilderness) { Some(rd(Layer::Wilderness).map_err(terr)?) } else { None };
        // MVUM per mode: 2w=mtb, 4w=atv, vehicle=vehicle (best effort, like navi)
        let mvum_by_mode: Option<[Vec<u8>; 3]> = match self.pack.mvum_in_box(south, north, west, east) {
            Ok(f) => Some(mvum::access_grids(&f, &meta, req.mvum_on_date)),
            Err(_) => None,
        };
        let ms_rasters = t0.elapsed().as_millis();

        let (s_row, s_col) = meta.latlon_to_pixel(start.0, start.1);
        let (g_row, g_col) = meta.latlon_to_pixel(end.0, end.1);
        let inb = |r: i64, c: i64| r >= 0 && r < rows as i64 && c >= 0 && c < cols as i64;
        if !(inb(s_row, s_col) && inb(g_row, g_col)) {
            return Err(RouteError::OutsideGrid);
        }

        // per-mode cost layers into one [rows, cols, n_modes] f32 stack
        let t1 = Instant::now();
        let aff = |m: Mode| req.network_affinity.as_ref().and_then(|a| a.get(&m).copied()).unwrap_or(1.0);
        let mut stack = vec![0f32; rows * cols * N_MODES];
        for (mi, mode) in Mode::ALL.iter().enumerate() {
            let mut m = compute_cost_multiplier_grid(&elevation, rows, cols, meta.cell_size_m, Some(&friction_mult),
                class.as_deref(), wilderness.as_deref(), *mode);
            if let Some(mv) = &mvum_by_mode {
                if *mode != Mode::Foot && req.boundary != Boundary::Emergency {
                    let grid = match mode {
                        Mode::TwoW => &mv[0],
                        Mode::FourW => &mv[1],
                        _ => &mv[2],
                    };
                    for (v, &g) in m.iter_mut().zip(grid) {
                        if g == 255 {
                            if req.boundary == Boundary::Strict {
                                *v = f32::INFINITY;
                            } else if v.is_finite() {
                                *v *= PRAGMATIC_BARRIER_MULTIPLIER;
                            }
                        }
                    }
                }
            }
            inflate_cost_multiplier(&mut m, rows, cols);
            let a = aff(*mode);
            if a != 1.0 {
                for (v, &t) in m.iter_mut().zip(&trails) {
                    if t != 0 && v.is_finite() {
                        *v = (*v as f64 * a) as f32;
                    }
                }
            }
            for (i, v) in m.iter().enumerate() {
                stack[i * N_MODES + mi] = *v;
            }
        }
        // corridor mask (after inflation)
        let cm = corridor_mask(rows, cols, meta.origin_lat, meta.origin_lon, meta.pixel_size_lat, meta.pixel_size_lon,
            (start, end), self.opts.corridor_pad_km, self.opts.corridor_endpoint_pad_km);
        for (i, &o) in cm.iter().enumerate() {
            if o {
                for mi in 0..N_MODES {
                    stack[i * N_MODES + mi] = f32::INFINITY;
                }
            }
        }
        drop(cm);
        drop(friction_mult);
        let ms_layers = t1.elapsed().as_millis();

        // kernel parameters
        let mut trail_friction_stack = vec![f64::INFINITY; N_MODES * 256];
        let mut max_grade = [0f64; N_MODES];
        let mut sfid = [0i64; N_MODES];
        let mut base = [0f64; N_MODES];
        for (mi, mode) in Mode::ALL.iter().enumerate() {
            let p = mode.profile();
            let a = aff(*mode);
            for &(tv, fr) in p.trail_friction {
                trail_friction_stack[mi * 256 + tv as usize] = fr.map_or(f64::INFINITY, |f| f * a);
            }
            max_grade[mi] = p.max_slope_deg.to_radians().tan();
            sfid[mi] = p.speed_function as i64;
            base[mi] = p.base_speed_kmh;
        }

        // transitions
        let t2 = Instant::now();
        let mut tc = transitions::gather_transition_cells(&meta, self.pack, self.valhalla, Some((start, end)),
            Some(&trails), Some(&elevation), self.opts.transition_buffer_m).map_err(RouteError::Terrain)?;
        if let RequestMode::Single(_) = req.mode {
            tc.retain(|t| origin_set.contains(&t.2) && origin_set.contains(&t.3));
        }
        let ms_transitions = t2.elapsed().as_millis();
        let trans_rows: Vec<i64> = tc.iter().map(|t| t.0).collect();
        let trans_cols: Vec<i64> = tc.iter().map(|t| t.1).collect();
        let trans_from: Vec<usize> = tc.iter().map(|t| t.2).collect();
        let trans_to: Vec<usize> = tc.iter().map(|t| t.3).collect();
        let trans_cost: Vec<f64> = tc.iter().map(|t| t.4).collect();

        let origin_modes: Vec<usize> = origin_set.iter().copied().collect();
        let goal_modes: Vec<usize> = goal_set.iter().copied().collect();
        let t3 = Instant::now();
        let res = astar_multigoal_multimode(&MultiModeInput {
            rows, cols, n_modes: N_MODES,
            cost_mult_stack: &stack, elevation: &elevation,
            cell_size_lat_m: meta.cell_size_m, cell_size_lon_m: meta.cell_size_m,
            max_grade: &max_grade, speed_function_ids: &sfid, base_speed_kmh: &base,
            trail_grid: &trails, trail_friction_stack: &trail_friction_stack, barrier_grid: &barriers,
            boundary_mode_id: req.boundary.id(),
            origin_row: s_row as usize, origin_col: s_col as usize, origin_modes: &origin_modes,
            goal_rows: &[g_row as usize], goal_cols: &[g_col as usize], goal_modes: &goal_modes,
            trans_rows: &trans_rows, trans_cols: &trans_cols, trans_from_mode: &trans_from, trans_to_mode: &trans_to,
            trans_cost_s: &trans_cost, disable_heuristic: false, initial_heap_cap: 0,
        })
        .map_err(RouteError::Terrain)?;
        let ms_search = t3.elapsed().as_millis();
        if res.goal_idx < 0 || res.path.is_empty() {
            return Err(RouteError::NoRoute);
        }
        let stats = RouteStats {
            rows, cols, cells: rows * cols, transition_cells: tc.len(), expanded_states: res.expanded,
            ms_rasters, ms_layers, ms_transitions, ms_search,
        };
        Ok(render_unified_path(&res.path, res.cost, &meta, req.boundary, stats))
    }
}

/// `_render_unified_path`.
pub fn render_unified_path(path: &[[i64; 3]], total_cost: f64, meta: &GridMeta, boundary: Boundary, stats: RouteStats) -> RouteResult {
    let n = path.len();
    let cells: Vec<PathCell> = path
        .iter()
        .map(|p| {
            let (lat, lon) = meta.pixel_to_latlon(p[0], p[1]);
            PathCell { row: p[0], col: p[1], mode: Mode::from_idx(p[2] as usize), lat, lon }
        })
        .collect();
    let coords: Vec<(f64, f64)> = cells.iter().map(|c| (c.lon, c.lat)).collect();
    let mut segments = Vec::new();
    let mut transitions = Vec::new();
    let mut seg_start = 0;
    let push_seg = |segments: &mut Vec<Segment>, a: usize, b: usize, m: Mode| {
        if b - a >= 2 {
            segments.push(Segment { mode: m, coords: coords[a..b].to_vec() });
        }
    };
    for i in 1..n {
        if cells[i].mode != cells[i - 1].mode {
            push_seg(&mut segments, seg_start, i, cells[i - 1].mode);
            transitions.push(TransitionMark { lat: coords[i].1, lon: coords[i].0, from_mode: cells[i - 1].mode, to_mode: cells[i].mode });
            seg_start = i;
        }
    }
    push_seg(&mut segments, seg_start, n, cells[n - 1].mode);

    let mut combined: Vec<(f64, f64)> = Vec::new();
    for &xy in &coords {
        if combined.last() != Some(&xy) {
            combined.push(xy);
        }
    }
    let total_m: f64 = combined.windows(2).map(|w| haversine_m(w[0].1, w[0].0, w[1].1, w[1].0)).sum();
    let set: BTreeSet<&str> = cells.iter().map(|c| c.mode.name()).collect();
    let mut selected_mode_set: Vec<String> = set.iter().map(|s| s.to_string()).collect();
    selected_mode_set.sort();
    let selected_mode = if selected_mode_set.len() == 1 { selected_mode_set[0].clone() } else { "hybrid".into() };
    RouteResult {
        scenario: "unified".into(),
        boundary,
        selected_mode_set,
        selected_mode,
        total_distance_km: total_m / 1000.0,
        total_effort_minutes: total_cost / 60.0,
        cost_s: total_cost,
        cells,
        segments,
        transitions,
        combined,
        auto_bypass: false,
        network: None,
        meta: Some(meta.clone()),
        stats,
    }
}
