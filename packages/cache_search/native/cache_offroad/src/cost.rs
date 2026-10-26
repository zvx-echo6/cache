//! Mode profiles and the per-mode cost-multiplier layer. Port of navi `cost.py`
//! (`MODE_PROFILES`, `compute_cost_multiplier_grid`, `_per_cell_grade`, `_corridor_mask`,
//! `compute_unified_cost_layers`) and `astar.inflate_cost_multiplier`.
use rayon::prelude::*;
use sha2::{Digest, Sha256};

pub const N_MODES: usize = 4;
pub const MODE_ORDER: [&str; N_MODES] = ["foot", "2w", "4w", "vehicle"];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Mode {
    Foot = 0,
    TwoW = 1,
    FourW = 2,
    Vehicle = 3,
}
impl Mode {
    pub const ALL: [Mode; 4] = [Mode::Foot, Mode::TwoW, Mode::FourW, Mode::Vehicle];
    pub fn idx(self) -> usize {
        self as usize
    }
    pub fn name(self) -> &'static str {
        MODE_ORDER[self as usize]
    }
    pub fn from_name(s: &str) -> Option<Mode> {
        match s {
            "foot" => Some(Mode::Foot),
            "2w" | "mtb" => Some(Mode::TwoW),
            "4w" | "atv" => Some(Mode::FourW),
            "vehicle" => Some(Mode::Vehicle),
            _ => None,
        }
    }
    pub fn from_idx(i: usize) -> Mode {
        Mode::ALL[i]
    }
    pub fn profile(self) -> &'static ModeProfile {
        &PROFILES[self as usize]
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum SpeedFn {
    Tobler = 0,
    Herzog = 1,
    Linear = 2,
}

#[derive(Debug, Clone, Copy)]
pub enum Ovr {
    Mul(f32),
    Inf,
}

#[derive(Debug)]
pub struct ModeProfile {
    pub name: &'static str,
    pub speed_function: SpeedFn,
    pub base_speed_kmh: f64,
    pub max_slope_deg: f64,
    /// (trail value, friction); None = impassable.
    pub trail_friction: &'static [(u8, Option<f64>)],
    /// (WorldCover class, override)
    pub terrain_override: &'static [(u8, Ovr)],
    pub wilderness_impassable: bool,
    pub off_trail_flat_threshold_deg: f64,
    pub off_trail_flat_friction: f32,
}

pub static PROFILES: [ModeProfile; 4] = [
    ModeProfile {
        name: "foot",
        speed_function: SpeedFn::Tobler,
        base_speed_kmh: 6.0,
        max_slope_deg: 40.0,
        trail_friction: &[(5, Some(0.1)), (15, Some(0.3)), (25, Some(0.5))],
        terrain_override: &[],
        wilderness_impassable: false,
        off_trail_flat_threshold_deg: 0.0,
        off_trail_flat_friction: f32::INFINITY,
    },
    ModeProfile {
        name: "2w",
        speed_function: SpeedFn::Herzog,
        base_speed_kmh: 12.0,
        max_slope_deg: 25.0,
        trail_friction: &[(5, Some(0.1)), (15, Some(0.2)), (25, Some(0.5))],
        terrain_override: &[
            (30, Ovr::Mul(2.0)),
            (20, Ovr::Mul(4.0)),
            (10, Ovr::Mul(8.0)),
            (60, Ovr::Mul(3.0)),
            (90, Ovr::Inf),
            (95, Ovr::Inf),
            (80, Ovr::Inf),
        ],
        wilderness_impassable: true,
        off_trail_flat_threshold_deg: 0.0,
        off_trail_flat_friction: f32::INFINITY,
    },
    ModeProfile {
        name: "4w",
        speed_function: SpeedFn::Herzog,
        base_speed_kmh: 25.0,
        max_slope_deg: 30.0,
        trail_friction: &[(5, Some(0.1)), (15, Some(0.3)), (25, None)],
        terrain_override: &[
            (30, Ovr::Mul(1.5)),
            (20, Ovr::Mul(3.0)),
            (10, Ovr::Inf),
            (60, Ovr::Mul(2.0)),
            (90, Ovr::Inf),
            (95, Ovr::Inf),
            (80, Ovr::Inf),
        ],
        wilderness_impassable: true,
        off_trail_flat_threshold_deg: 0.0,
        off_trail_flat_friction: f32::INFINITY,
    },
    ModeProfile {
        name: "vehicle",
        speed_function: SpeedFn::Linear,
        base_speed_kmh: 40.0,
        max_slope_deg: 20.0,
        trail_friction: &[(5, Some(0.1)), (15, Some(0.5)), (25, None)],
        terrain_override: &[
            (10, Ovr::Inf),
            (20, Ovr::Inf),
            (30, Ovr::Inf),
            (40, Ovr::Inf),
            (60, Ovr::Inf),
            (90, Ovr::Inf),
            (95, Ovr::Inf),
            (80, Ovr::Inf),
        ],
        wilderness_impassable: true,
        off_trail_flat_threshold_deg: 5.0,
        off_trail_flat_friction: 5.0,
    },
];

pub const PRAGMATIC_BARRIER_MULTIPLIER: f32 = 5.0;
pub const TRANSITION_COST_PARKING_S: f64 = 60.0;
pub const TRANSITION_COST_TRAILHEAD_S: f64 = 30.0;
pub const TRANSITION_COST_ROAD_TERMINUS_S: f64 = 60.0;
pub const TRANSITION_COST_SURFACE_CHANGE_S: f64 = 0.0;

/// Stable hash of everything in the mode profiles that shapes the cost layers (stored in the pack).
pub fn mode_profile_hash() -> String {
    let mut s = String::new();
    for p in PROFILES.iter() {
        s.push_str(&format!("{:?}\n", p));
    }
    s.push_str(&format!("{:?}\n", (PRAGMATIC_BARRIER_MULTIPLIER, TRANSITION_COST_PARKING_S,
        TRANSITION_COST_TRAILHEAD_S, TRANSITION_COST_ROAD_TERMINUS_S, TRANSITION_COST_SURFACE_CHANGE_S)));
    let mut h = Sha256::new();
    h.update(s.as_bytes());
    h.finalize().iter().map(|b| format!("{:02x}", b)).collect()
}

/// WorldCover friction x10 (u8) -> multiplier (f32). 0 and 255 -> inf. (`friction_to_multiplier`)
pub fn friction_to_multiplier(f: &[u8]) -> Vec<f32> {
    f.iter()
        .map(|&v| if v == 0 || v == 255 { f32::INFINITY } else { v as f32 / 10.0 })
        .collect()
}

fn grade_block(elev: &[f64], rows: usize, cols: usize, cs_lat: f64, cs_lon: f64) -> Vec<f32> {
    // float32 accumulator `dy`, float64 arithmetic per term, like the numpy original.
    let mut dy = vec![0f32; rows * cols];
    if rows >= 3 {
        for r in 1..rows - 1 {
            for c in 0..cols {
                let d = (elev[(r - 1) * cols + c] - elev[(r + 1) * cols + c]) / (2.0 * cs_lat);
                dy[r * cols + c] = (d * d) as f32;
            }
        }
    }
    if rows >= 2 {
        for c in 0..cols {
            let d = (elev[c] - elev[cols + c]) / cs_lat;
            dy[c] = (d * d) as f32;
            let d = (elev[(rows - 2) * cols + c] - elev[(rows - 1) * cols + c]) / cs_lat;
            dy[(rows - 1) * cols + c] = (d * d) as f32;
        }
    }
    if cols >= 2 {
        for r in 0..rows {
            let row = &elev[r * cols..(r + 1) * cols];
            let out = &mut dy[r * cols..(r + 1) * cols];
            if cols >= 3 {
                for c in 1..cols - 1 {
                    let d = (row[c + 1] - row[c - 1]) / (2.0 * cs_lon);
                    out[c] = (out[c] as f64 + d * d) as f32;
                }
            }
            let d = (row[1] - row[0]) / cs_lon;
            out[0] = (out[0] as f64 + d * d) as f32;
            let d = (row[cols - 1] - row[cols - 2]) / cs_lon;
            out[cols - 1] = (out[cols - 1] as f64 + d * d) as f32;
        }
    }
    dy.iter().map(|v| v.sqrt()).collect()
}

/// Per-cell slope magnitude (rise/run) as f32 (`_per_cell_grade`).
pub fn per_cell_grade(elev: &[f32], rows: usize, cols: usize, cs_lat: f64, cs_lon: f64) -> Vec<f32> {
    const BLOCK: usize = 256;
    let mut grade = vec![0f32; rows * cols];
    if rows <= BLOCK + 2 {
        let e: Vec<f64> = elev.iter().map(|&v| v as f64).collect();
        return grade_block(&e, rows, cols, cs_lat, cs_lon);
    }
    let mut r0 = 0;
    while r0 < rows {
        let r1 = rows.min(r0 + BLOCK);
        let lo = r0.saturating_sub(1);
        let hi = rows.min(r1 + 1);
        let e: Vec<f64> = elev[lo * cols..hi * cols].iter().map(|&v| v as f64).collect();
        let g = grade_block(&e, hi - lo, cols, cs_lat, cs_lon);
        let off = (r0 - lo) * cols;
        grade[r0 * cols..r1 * cols].copy_from_slice(&g[off..off + (r1 - r0) * cols]);
        r0 = r1;
    }
    grade
}

/// Slope-free context cost multiplier for one mode (`compute_cost_multiplier_grid`, float32).
#[allow(clippy::too_many_arguments)]
pub fn compute_cost_multiplier_grid(
    elev: &[f32], rows: usize, cols: usize, cell_m: f64,
    friction: Option<&[f32]>, class: Option<&[u8]>, wilderness: Option<&[u8]>, mode: Mode,
) -> Vec<f32> {
    let p = mode.profile();
    let mut mult = vec![1f32; rows * cols];
    if let Some(f) = friction {
        for (m, &fv) in mult.iter_mut().zip(f) {
            *m *= fv;
        }
    }
    for (m, &e) in mult.iter_mut().zip(elev) {
        if e.is_nan() {
            *m = f32::INFINITY;
        }
    }
    if let Some(cls) = class {
        for &(wc, o) in p.terrain_override {
            match o {
                Ovr::Inf => {
                    for (m, &c) in mult.iter_mut().zip(cls) {
                        if c == wc {
                            *m = f32::INFINITY;
                        }
                    }
                }
                Ovr::Mul(f) => {
                    for (m, &c) in mult.iter_mut().zip(cls) {
                        if c == wc {
                            *m *= f;
                        }
                    }
                }
            }
        }
        if mode == Mode::Vehicle && p.off_trail_flat_threshold_deg > 0.0 {
            let grade = per_cell_grade(elev, rows, cols, cell_m, cell_m);
            for i in 0..rows * cols {
                let slope_deg = grade[i].atan().to_degrees();
                if slope_deg <= p.off_trail_flat_threshold_deg as f32 && (cls[i] == 30 || cls[i] == 40) {
                    mult[i] = p.off_trail_flat_friction;
                }
            }
        }
    }
    if let Some(w) = wilderness {
        if p.wilderness_impassable {
            for (m, &v) in mult.iter_mut().zip(w) {
                if v == 255 {
                    *m = f32::INFINITY;
                }
            }
        }
    }
    mult
}

// ---- inflate_cost_multiplier ----------------------------------------------------------------

pub const INFLATE_SIGMA: f64 = 1.8;
pub const INFLATE_HARD_FACTOR: f64 = 50.0;
pub const INFLATE_HARD_CAP: f64 = 1e12;

/// scipy `_gaussian_kernel1d(sigma, order=0, radius=int(truncate*sigma+0.5))`, normalised.
pub fn gaussian_kernel(sigma: f64, truncate: f64) -> Vec<f64> {
    let radius = (truncate * sigma + 0.5) as i64;
    let sigma2 = sigma * sigma;
    let mut phi: Vec<f64> = (-radius..=radius).map(|x| (-0.5 / sigma2 * (x * x) as f64).exp()).collect();
    let s: f64 = phi.iter().sum();
    for v in phi.iter_mut() {
        *v /= s;
    }
    phi
}

/// One 1-D `mode="nearest"` correlation of a line (symmetric kernel, scipy's summation order),
/// double accumulation, float32 result.
fn filter_line(line: &[f64], k: &[f64], out: &mut [f32]) {
    let n = line.len() as i64;
    let r = (k.len() / 2) as i64;
    for i in 0..n {
        let at = |j: i64| line[j.clamp(0, n - 1) as usize];
        let mut tmp = at(i) * k[r as usize];
        for t in 1..=r {
            tmp += (at(i - t) + at(i + t)) * k[(r + t) as usize];
        }
        out[i as usize] = tmp as f32;
    }
}

/// `scipy.ndimage.gaussian_filter(x, sigma, mode="nearest")` (truncate=4.0) on a float32 grid:
/// axis 0 then axis 1, float32 storage between passes.
pub fn gaussian_filter_f32(data: &[f32], rows: usize, cols: usize, sigma: f64) -> Vec<f32> {
    let k = gaussian_kernel(sigma, 4.0);
    let mut tmp = vec![0f32; rows * cols];
    // axis 0: process column strips for cache friendliness.
    let strip = 64usize;
    let ncs = cols.div_ceil(strip);
    let cols_out: Vec<(usize, Vec<f32>)> = (0..ncs)
        .into_par_iter()
        .map(|s| {
            let c0 = s * strip;
            let c1 = cols.min(c0 + strip);
            let w = c1 - c0;
            let mut block = vec![0f32; rows * w];
            let mut line = vec![0f64; rows];
            let mut o = vec![0f32; rows];
            for c in c0..c1 {
                for r in 0..rows {
                    line[r] = data[r * cols + c] as f64;
                }
                filter_line(&line, &k, &mut o);
                for r in 0..rows {
                    block[r * w + (c - c0)] = o[r];
                }
            }
            (c0, block)
        })
        .collect();
    for (c0, block) in cols_out {
        let w = block.len() / rows.max(1);
        for r in 0..rows {
            tmp[r * cols + c0..r * cols + c0 + w].copy_from_slice(&block[r * w..(r + 1) * w]);
        }
    }
    let mut out = vec![0f32; rows * cols];
    out.par_chunks_mut(cols).enumerate().for_each(|(r, orow)| {
        let line: Vec<f64> = tmp[r * cols..(r + 1) * cols].iter().map(|&v| v as f64).collect();
        filter_line(&line, &k, orow);
    });
    out
}

/// numpy.percentile(x, q) with the default linear interpolation.
pub fn percentile(vals: &mut [f32], q: f64) -> f64 {
    let n = vals.len();
    let pos = q / 100.0 * (n - 1) as f64;
    let lo = pos.floor() as usize;
    let hi = pos.ceil() as usize;
    let (_, lo_v, rest) = vals.select_nth_unstable_by(lo, |a, b| a.partial_cmp(b).unwrap());
    let a = *lo_v as f64;
    if hi == lo {
        return a;
    }
    let b = rest.iter().copied().fold(f32::INFINITY, f32::min) as f64;
    a + (b - a) * (pos - lo as f64)
}

/// `inflate_cost_multiplier`: exponentially inflate so hard cells bleed into neighbours; impassable
/// cells are restored to inf afterwards. In place.
pub fn inflate_cost_multiplier(mult: &mut Vec<f32>, rows: usize, cols: usize) {
    let inf_mask: Vec<bool> = mult.iter().map(|v| !v.is_finite()).collect();
    let mut finite: Vec<f32> = mult.iter().copied().filter(|v| v.is_finite()).collect();
    if finite.is_empty() {
        return;
    }
    let p95 = percentile(&mut finite, 95.0);
    drop(finite);
    let hard = (INFLATE_HARD_FACTOR * p95).min(INFLATE_HARD_CAP) as f32;
    for (v, &m) in mult.iter_mut().zip(&inf_mask) {
        if m {
            *v = hard;
        }
    }
    let mut blurred = gaussian_filter_f32(mult, rows, cols, INFLATE_SIGMA);
    for (v, &m) in blurred.iter_mut().zip(&inf_mask) {
        if m {
            *v = f32::INFINITY;
        }
    }
    *mult = blurred;
}

// ---- corridor mask ---------------------------------------------------------------------------

/// True where a cell lies OUTSIDE the great-circle corridor (`_corridor_mask`).
pub fn corridor_mask(
    rows: usize, cols: usize, origin_lat: f64, origin_lon: f64, ps_lat: f64, ps_lon: f64,
    line: ((f64, f64), (f64, f64)), pad_km: f64, endpoint_pad_km: f64,
) -> Vec<bool> {
    let ((lat0, lon0), (lat1, lon1)) = line;
    let ky = 111.0;
    let kx = 111.0 * ((lat0 + lat1) / 2.0).to_radians().cos();
    let ex = (lon1 - lon0) * kx;
    let ey = (lat1 - lat0) * ky;
    let l = ex.hypot(ey);
    if l < 1e-6 {
        return vec![false; rows * cols];
    }
    let (ux, uy) = (ex / l, ey / l);
    let xs: Vec<f64> = (0..cols).map(|c| (origin_lon + c as f64 * ps_lon - lon0) * kx).collect();
    let mut out = vec![false; rows * cols];
    out.par_chunks_mut(cols).enumerate().for_each(|(r, orow)| {
        let y = (origin_lat + r as f64 * ps_lat - lat0) * ky;
        for c in 0..cols {
            let x = xs[c];
            let t = x * ux + y * uy;
            let d = (x * uy - y * ux).abs();
            orow[c] = d > pad_km || t < -endpoint_pad_km || t > l + endpoint_pad_km;
        }
    });
    out
}
