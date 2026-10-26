//! Off-road legs for directions. Port of navi `directions_offroad.py`: a pure conversion of the router's
//! path detail into directions steps (Douglas-Peucker simplify, decision-point legs, short-leg folding,
//! "follow" legs on one trail value).
use crate::cost::Mode;
use crate::grid::haversine_m;
use crate::router::{PathDetail, RouteResult};
use serde_json::{json, Value};
use std::collections::BTreeMap;

pub const SIMPLIFY_M: f64 = 15.0;
pub const GRADE_FLAT_PCT: f64 = 5.0;
pub const GRADE_STEEP_PCT: f64 = 15.0;
pub const LABEL_MIN_CELLS: usize = 3;
pub const FOLLOW_SAMPLE_M: f64 = 50.0;
pub const FOLLOW_NAME_SPLIT_M: f64 = 150.0;
pub const KM_TO_MI: f64 = 0.621371;
const M_PER_DEG: f64 = 111195.0;
const CARDINALS: [&str; 8] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];

pub fn terrain_name(code: u8) -> &'static str {
    match code {
        10 => "tree_cover",
        20 => "shrubland",
        30 => "grassland",
        40 => "cropland",
        50 => "built_up",
        60 => "bare",
        70 => "snow_ice",
        80 => "water",
        90 => "wetland",
        95 => "mangrove",
        100 => "moss_lichen",
        _ => "unknown",
    }
}

pub fn trail_kind(v: u8) -> Option<&'static str> {
    match v {
        5 => Some("road"),
        15 => Some("track"),
        25 => Some("trail"),
        _ => None,
    }
}

/// Python `round(x, nd)` (correctly rounded, ties to even).
pub fn round_py(x: f64, nd: usize) -> f64 {
    format!("{:.*}", nd, x).parse().unwrap_or(x)
}
/// Python `int(round(x))`.
pub fn round_i(x: f64) -> i64 {
    x.round_ties_even() as i64
}

pub fn bearing_deg(a: (f64, f64), b: (f64, f64)) -> f64 {
    let (lat1, lat2) = (a.0.to_radians(), b.0.to_radians());
    let dl = (b.1 - a.1).to_radians();
    let y = dl.sin() * lat2.cos();
    let x = lat1.cos() * lat2.sin() - lat1.sin() * lat2.cos() * dl.cos();
    (y.atan2(x).to_degrees() + 360.0).rem_euclid(360.0)
}

pub fn cardinal(bearing: f64) -> &'static str {
    let i = ((bearing.rem_euclid(360.0) + 22.5) / 45.0).floor() as i64;
    CARDINALS[(i.rem_euclid(8)) as usize]
}

pub fn pt(p: (f64, f64)) -> (f64, f64) {
    (round_py(p.0, 6), round_py(p.1, 6))
}

fn hav(a: (f64, f64), b: (f64, f64)) -> f64 {
    haversine_m(a.0, a.1, b.0, b.1)
}

// ---- geometry ----------------------------------------------------------------------------------

fn project(lats: &[f64], lons: &[f64]) -> Vec<(f64, f64)> {
    let (lat0, lon0) = (lats[0], lons[0]);
    let k = lat0.to_radians().cos();
    lats.iter().zip(lons).map(|(&la, &lo)| ((lo - lon0) * k * M_PER_DEG, (la - lat0) * M_PER_DEG)).collect()
}

fn seg_dist(p: (f64, f64), a: (f64, f64), b: (f64, f64)) -> f64 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let n = dx * dx + dy * dy;
    if n == 0.0 {
        return (p.0 - a.0).hypot(p.1 - a.1);
    }
    let t = (((p.0 - a.0) * dx + (p.1 - a.1) * dy) / n).clamp(0.0, 1.0);
    (p.0 - (a.0 + t * dx)).hypot(p.1 - (a.1 + t * dy))
}

/// Douglas-Peucker; sorted indices of the kept vertices (first and last always kept).
pub fn simplify_indices(lats: &[f64], lons: &[f64], tol_m: f64) -> Vec<usize> {
    let n = lats.len();
    if n <= 2 {
        return (0..n).collect();
    }
    let xy = project(lats, lons);
    let mut keep = std::collections::BTreeSet::new();
    keep.insert(0);
    keep.insert(n - 1);
    let mut stack = vec![(0usize, n - 1)];
    while let Some((i, j)) = stack.pop() {
        let (mut far, mut far_d) = (usize::MAX, tol_m);
        for k in i + 1..j {
            let d = seg_dist(xy[k], xy[i], xy[j]);
            if d > far_d {
                far = k;
                far_d = d;
            }
        }
        if far != usize::MAX {
            keep.insert(far);
            stack.push((i, far));
            stack.push((far, j));
        }
    }
    keep.into_iter().collect()
}

fn bearing_diff(a: f64, b: f64) -> f64 {
    let d = (a - b).abs().rem_euclid(360.0);
    if d > 180.0 {
        360.0 - d
    } else {
        d
    }
}

pub fn grade_class(net_rise_m: f64, dist_m: f64) -> &'static str {
    if dist_m <= 0.0 {
        return "flat";
    }
    let pct = net_rise_m / dist_m * 100.0;
    if pct.abs() < GRADE_FLAT_PCT {
        return "flat";
    }
    let steep = pct.abs() > GRADE_STEEP_PCT;
    if pct > 0.0 {
        if steep { "steep_uphill" } else { "uphill" }
    } else if steep {
        "steep_downhill"
    } else {
        "downhill"
    }
}

fn fill_elev(elev: &[Option<f64>]) -> Vec<f64> {
    let first = elev.iter().find_map(|e| *e).unwrap_or(0.0);
    let mut last = first;
    elev.iter()
        .map(|e| {
            if let Some(v) = e {
                last = *v;
            }
            last
        })
        .collect()
}

/// Cells of one run: navi's `{lat, lon, elev, terrain, step_s[, trail]}` dict.
#[derive(Debug, Clone, Default)]
pub struct Cells {
    pub lat: Vec<f64>,
    pub lon: Vec<f64>,
    pub elev: Vec<Option<f64>>,
    pub terrain: Vec<u8>,
    pub step_s: Vec<f64>,
    pub trail: Option<Vec<u8>>,
}

impl Cells {
    /// `_slice(detail, a, b)`
    pub fn slice(d: &PathDetail, a: usize, b: usize) -> Cells {
        Cells {
            lat: d.lat[a..=b].to_vec(),
            lon: d.lon[a..=b].to_vec(),
            elev: d.elev[a..=b].to_vec(),
            terrain: d.terrain[a..=b].to_vec(),
            step_s: d.step_s[a..b].to_vec(),
            trail: if d.trail.is_empty() { None } else { Some(d.trail[a..=b].to_vec()) },
        }
    }
}

struct Run {
    lat: Vec<f64>,
    lon: Vec<f64>,
    elev: Vec<f64>,
    terrain: Vec<u8>,
    step_s: Vec<f64>,
    v: Vec<usize>,
}

struct Props {
    dist: f64,
    bearing: f64,
    gain: f64,
    loss: f64,
    dur: f64,
    grade_class: &'static str,
    terrain: &'static str,
}

impl Run {
    fn new(lat: Vec<f64>, lon: Vec<f64>, elev: &[Option<f64>], terrain: Vec<u8>, step_s: Vec<f64>, all_vertices: bool) -> Run {
        let mut r = Run { lat, lon, elev: fill_elev(elev), terrain, step_s, v: vec![] };
        r.v = if all_vertices { (0..r.lat.len()).collect() } else { r.vertices() };
        r
    }

    fn pt(&self, c: usize) -> (f64, f64) {
        (self.lat[c], self.lon[c])
    }

    fn vertices(&self) -> Vec<usize> {
        let n = self.lat.len();
        if n <= 2 {
            return (0..n).collect();
        }
        let labels = self.cell_labels();
        let mut cuts = vec![0usize];
        cuts.extend((1..n).filter(|&k| labels[k] != labels[k - 1]));
        cuts.push(n - 1);
        cuts.sort();
        cuts.dedup();
        let mut keep = std::collections::BTreeSet::new();
        for w in cuts.windows(2) {
            let (a, b) = (w[0], w[1]);
            for i in simplify_indices(&self.lat[a..=b], &self.lon[a..=b], SIMPLIFY_M) {
                keep.insert(a + i);
            }
        }
        keep.into_iter().collect()
    }

    fn cell_labels(&self) -> Vec<(u8, &'static str)> {
        let n = self.lat.len();
        let mut raw = Vec::with_capacity(n);
        for k in 0..n {
            let (a, b) = (k.saturating_sub(1), (k + 1).min(n - 1));
            let d = hav(self.pt(a), self.pt(b));
            raw.push((self.terrain[k], grade_class(self.elev[b] - self.elev[a], d)));
        }
        let mut runs: Vec<((u8, &'static str), usize)> = Vec::new();
        for lab in raw {
            if let Some(l) = runs.last_mut() {
                if l.0 == lab {
                    l.1 += 1;
                    continue;
                }
            }
            runs.push((lab, 1));
        }
        let mut i = 1;
        while i < runs.len() {
            if runs[i].1 < LABEL_MIN_CELLS {
                let add = runs[i].1;
                runs[i - 1].1 += add;
                runs.remove(i);
                if i < runs.len() && runs[i].0 == runs[i - 1].0 {
                    let add = runs[i].1;
                    runs[i - 1].1 += add;
                    runs.remove(i);
                }
            } else {
                i += 1;
            }
        }
        let mut out = Vec::new();
        for (lab, ln) in runs {
            out.extend(std::iter::repeat(lab).take(ln));
        }
        out
    }

    fn props(&self, vi: usize, vj: usize) -> Props {
        let (a, b) = (self.v[vi], self.v[vj]);
        let dist: f64 = (vi..vj).map(|k| hav(self.pt(self.v[k]), self.pt(self.v[k + 1]))).sum();
        let bearing = bearing_deg(self.pt(a), self.pt(b));
        let (mut gain, mut loss) = (0.0, 0.0);
        for k in a..b {
            let d = self.elev[k + 1] - self.elev[k];
            if d > 0.0 {
                gain += d;
            } else {
                loss -= d;
            }
        }
        let mut votes: BTreeMap<&'static str, usize> = BTreeMap::new();
        let start = if b > a { a + 1 } else { a };
        for k in start..=b {
            *votes.entry(terrain_name(self.terrain[k])).or_insert(0) += 1;
        }
        // max over names sorted ascending, first maximum wins
        let mut terrain = "unknown";
        let mut best = 0usize;
        for (n, c) in &votes {
            if *c > best {
                best = *c;
                terrain = n;
            }
        }
        Props {
            dist, bearing, gain, loss,
            dur: self.step_s[a..b].iter().sum(),
            grade_class: grade_class(self.elev[b] - self.elev[a], dist),
            terrain,
        }
    }
}

fn split_legs(run: &Run, merge_bearing_deg: f64, min_leg_m: f64, first_after_switch: bool) -> Vec<(usize, usize)> {
    let nv = run.v.len();
    if nv < 2 {
        return vec![];
    }
    let mut legs: Vec<[usize; 2]> = vec![[0, 1]];
    for k in 1..nv - 1 {
        let cur = run.props(legs.last().unwrap()[0], legs.last().unwrap()[1]);
        let nxt = run.props(k, k + 1);
        if bearing_diff(cur.bearing, nxt.bearing) < merge_bearing_deg && cur.grade_class == nxt.grade_class && cur.terrain == nxt.terrain {
            legs.last_mut().unwrap()[1] = k + 1;
        } else {
            legs.push([k, k + 1]);
        }
    }
    while legs.len() > 1 {
        let mut shorts: Vec<(f64, usize)> = Vec::new();
        for (i, lg) in legs.iter().enumerate() {
            let d = run.props(lg[0], lg[1]).dist;
            if d < min_leg_m && !(i == 0 && first_after_switch) {
                shorts.push((d, i));
            }
        }
        if shorts.is_empty() {
            break;
        }
        let (_d, i) = shorts.into_iter().min_by(|a, b| a.0.partial_cmp(&b.0).unwrap().then(a.1.cmp(&b.1))).unwrap();
        let mine = run.props(legs[i][0], legs[i][1]).bearing;
        let mut options: Vec<(f64, usize)> = Vec::new();
        if i > 0 {
            options.push((bearing_diff(mine, run.props(legs[i - 1][0], legs[i - 1][1]).bearing), i - 1));
        }
        if i < legs.len() - 1 {
            options.push((bearing_diff(mine, run.props(legs[i + 1][0], legs[i + 1][1]).bearing), i + 1));
        }
        let (_bd, j) = options.into_iter().min_by(|a, b| a.0.partial_cmp(&b.0).unwrap().then(a.1.cmp(&b.1))).unwrap();
        let (lo, hi) = (i.min(j), i.max(j));
        legs[lo] = [legs[lo][0], legs[hi][1]];
        legs.remove(hi);
    }
    legs.into_iter().map(|l| (l[0], l[1])).collect()
}

// ---- steps ---------------------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct Follow {
    pub trail_kind: String,
    pub name: Option<String>,
}

/// One directions step (road or off-road).
#[derive(Debug, Clone)]
pub struct Step {
    pub index: usize,
    pub kind: String, // road | offroad | offroad_follow
    pub type_: String,
    pub mode: Option<String>,
    pub street_names: Vec<String>,
    pub distance_m: Option<i64>,
    pub distance_km: f64,
    pub distance_mi: f64,
    pub duration_s: i64,
    pub bearing_deg: Option<i64>,
    pub cardinal: Option<String>,
    pub elev_gain_m: Option<i64>,
    pub elev_loss_m: Option<i64>,
    pub grade_class: Option<String>,
    pub terrain: Option<String>,
    pub start: (f64, f64),
    pub end: (f64, f64),
    pub instruction: Option<String>,
    pub follow: Option<Follow>,
}

impl Step {
    pub fn to_json(&self) -> Value {
        let ptj = |p: (f64, f64)| json!({"lat": p.0, "lon": p.1});
        let mut m = serde_json::Map::new();
        if self.kind == "road" {
            m.insert("index".into(), json!(self.index));
        }
        m.insert("kind".into(), json!(self.kind));
        m.insert("type".into(), json!(self.type_));
        if let Some(md) = &self.mode {
            m.insert("mode".into(), json!(md));
        }
        m.insert("street_names".into(), json!(self.street_names));
        if let Some(d) = self.distance_m {
            m.insert("distance_m".into(), json!(d));
        }
        m.insert("distance_km".into(), json!(self.distance_km));
        m.insert("distance_mi".into(), json!(self.distance_mi));
        m.insert("duration_s".into(), json!(self.duration_s));
        m.insert("bearing_deg".into(), json!(self.bearing_deg));
        m.insert("cardinal".into(), json!(self.cardinal));
        if self.kind != "road" {
            m.insert("elev_gain_m".into(), json!(self.elev_gain_m));
            m.insert("elev_loss_m".into(), json!(self.elev_loss_m));
            m.insert("grade_class".into(), json!(self.grade_class));
            m.insert("terrain".into(), json!(self.terrain));
        }
        m.insert("start".into(), ptj(self.start));
        m.insert("end".into(), ptj(self.end));
        m.insert("instruction".into(), json!(self.instruction));
        if let Some(f) = &self.follow {
            m.insert("follow".into(), json!({"trail_kind": f.trail_kind, "name": f.name}));
        }
        if self.kind != "road" {
            m.insert("index".into(), json!(self.index));
        }
        Value::Object(m)
    }
}

#[allow(clippy::too_many_arguments)]
fn make_step(run: &Run, vi: usize, vj: usize, mode: &str, extra_s: f64, min_leg_m: f64, is_first: bool, first_after_switch: bool, follow: Option<Follow>) -> (Step, (f64, f64)) {
    let p = run.props(vi, vj);
    let dur = p.dur + extra_s;
    let (a, b) = (run.v[vi], run.v[vj]);
    let is_switch = follow.is_none() && is_first && first_after_switch && p.dist < min_leg_m;
    let km = p.dist / 1000.0;
    let step = Step {
        index: 0,
        kind: if follow.is_none() { "offroad".into() } else { "offroad_follow".into() },
        type_: if follow.is_none() { if is_switch { "mode_change".into() } else { "offroad_leg".into() } } else { "offroad_follow".into() },
        mode: Some(mode.to_string()),
        street_names: vec![],
        distance_m: Some(round_i(p.dist)),
        distance_km: round_py(km, 2),
        distance_mi: round_py(km * KM_TO_MI, 2),
        duration_s: round_i(dur),
        bearing_deg: Some(round_i(p.bearing).rem_euclid(360)),
        cardinal: Some(cardinal(p.bearing).to_string()),
        elev_gain_m: Some(round_i(p.gain)),
        elev_loss_m: Some(round_i(p.loss)),
        grade_class: Some(p.grade_class.to_string()),
        terrain: Some(p.terrain.to_string()),
        start: pt(run.pt(a)),
        end: pt(run.pt(b)),
        instruction: None,
        follow,
    };
    (step, (p.dist, dur))
}

fn cum_dist(lat: &[f64], lon: &[f64]) -> Vec<f64> {
    let mut cum = vec![0.0];
    for k in 0..lat.len().saturating_sub(1) {
        cum.push(cum[k] + hav((lat[k], lon[k]), (lat[k + 1], lon[k + 1])));
    }
    cum
}

/// Maximal runs of cells on one nonzero trail value (>= min_leg_m along the path): (a, b, value).
pub fn follow_runs(trail: &[u8], lat: &[f64], lon: &[f64], min_leg_m: f64) -> Vec<(usize, usize, u8)> {
    let n = lat.len();
    let mut out: Vec<[usize; 3]> = Vec::new();
    let mut i = 0;
    while i < n {
        let v = trail[i];
        let mut j = i;
        while j + 1 < n && trail[j + 1] == v {
            j += 1;
        }
        if v != 0 && trail_kind(v).is_some() && j > i {
            let d: f64 = (i..j).map(|k| hav((lat[k], lon[k]), (lat[k + 1], lon[k + 1]))).sum();
            if d >= min_leg_m {
                out.push([i, j, v as usize]);
            }
        }
        i = j + 1;
    }
    for k in 1..out.len() {
        if out[k][0] == out[k - 1][1] + 1 {
            out[k][0] = out[k - 1][1];
        }
    }
    out.into_iter().map(|o| (o[0], o[1], o[2] as u8)).collect()
}

fn name_samples(lat: &[f64], cum: &[f64]) -> Vec<usize> {
    let mut idx = vec![0usize];
    let mut nxt = FOLLOW_SAMPLE_M;
    for k in 1..lat.len() {
        if cum[k] >= nxt {
            idx.push(k);
            nxt = cum[k] + FOLLOW_SAMPLE_M;
        }
    }
    if *idx.last().unwrap() != lat.len() - 1 {
        idx.push(lat.len() - 1);
    }
    idx
}

fn majority_name(names: &[Option<String>]) -> Option<String> {
    if names.is_empty() {
        return None;
    }
    let mut votes: BTreeMap<&str, usize> = BTreeMap::new();
    for n in names.iter().flatten() {
        *votes.entry(n.as_str()).or_insert(0) += 1;
    }
    let mut best: Option<(&str, usize)> = None;
    for (k, c) in &votes {
        if best.map_or(true, |b| *c > b.1) {
            best = Some((k, *c));
        }
    }
    let (k, c) = best?;
    if c * 2 >= names.len() {
        Some(k.to_string())
    } else {
        None
    }
}

fn name_cuts(names: &[Option<String>], sample_cum: &[f64], min_leg_m: f64) -> Vec<usize> {
    let mut groups: Vec<(String, usize, usize)> = Vec::new();
    for (k, nm) in names.iter().enumerate() {
        let Some(nm) = nm else { continue };
        if let Some(g) = groups.last_mut() {
            if &g.0 == nm {
                g.2 = k;
                continue;
            }
        }
        groups.push((nm.clone(), k, k));
    }
    let stable: Vec<_> = groups.into_iter().filter(|g| sample_cum[g.2] - sample_cum[g.1] >= FOLLOW_NAME_SPLIT_M).collect();
    let mut merged: Vec<(String, usize, usize)> = Vec::new();
    for g in stable {
        if let Some(m) = merged.last_mut() {
            if m.0 == g.0 {
                m.2 = g.2;
                continue;
            }
        }
        merged.push(g);
    }
    let (mut cuts, mut last_cut) = (Vec::new(), 0usize);
    let total = *sample_cum.last().unwrap();
    for w in merged.windows(2) {
        let c = (w[0].2 + w[1].1) / 2;
        if c == 0 || c >= names.len() - 1 {
            continue;
        }
        if sample_cum[c] - sample_cum[last_cut] >= min_leg_m && total - sample_cum[c] >= min_leg_m {
            cuts.push(c);
            last_cut = c;
        }
    }
    cuts
}

/// `namer(points, trail_kind)` -> one optional name per point, or None to leave follow legs unnamed.
pub type Namer<'a> = &'a dyn Fn(&[(f64, f64)], &str) -> Option<Vec<Option<String>>>;

/// Steps (no index) for one run, with raw[i] = (distance_m, duration_s) unrounded (`offroad_steps`).
pub fn offroad_steps(
    cells: &Cells, mode: &str, merge_bearing_deg: f64, min_leg_m: f64, first_after_switch: bool, extra_s: f64,
    namer: Option<Namer>,
) -> (Vec<Step>, Vec<(f64, f64)>) {
    let (lat, lon) = (&cells.lat, &cells.lon);
    let n = lat.len();
    let trail: Vec<u8> = cells.trail.clone().unwrap_or_else(|| vec![0; n]);
    let filled: Vec<Option<f64>> = fill_elev(&cells.elev).into_iter().map(Some).collect();
    let fruns = if n > 1 { follow_runs(&trail, lat, lon, min_leg_m) } else { vec![] };
    let sub = |a: usize, b: usize, all_v: bool| Run::new(lat[a..=b].to_vec(), lon[a..=b].to_vec(), &filled[a..=b], cells.terrain[a..=b].to_vec(), cells.step_s[a..b].to_vec(), all_v);

    enum Seg {
        Off(usize, usize),
        Follow(usize, usize, u8),
    }
    let mut segs = Vec::new();
    let mut pos = 0usize;
    for &(a, b, v) in &fruns {
        if a > pos {
            segs.push(Seg::Off(pos, a));
        }
        segs.push(Seg::Follow(a, b, v));
        pos = b;
    }
    if pos < n.saturating_sub(1) || segs.is_empty() {
        segs.push(Seg::Off(pos, n - 1));
    }

    let mut steps: Vec<Step> = Vec::new();
    let mut raw: Vec<(f64, f64)> = Vec::new();
    let emit = |steps: &mut Vec<Step>, raw: &mut Vec<(f64, f64)>, run: &Run, vi: usize, vj: usize, follow: Option<Follow>, first_off: bool| {
        let first = steps.is_empty();
        let (st, rw) = make_step(run, vi, vj, mode, if first { extra_s } else { 0.0 }, min_leg_m, first && first_off, first_after_switch, follow);
        steps.push(st);
        raw.push(rw);
    };
    for seg in segs {
        match seg {
            Seg::Off(a, b) => {
                let run = sub(a, b, false);
                let legs = split_legs(&run, merge_bearing_deg, min_leg_m, first_after_switch && steps.is_empty());
                for (vi, vj) in legs {
                    emit(&mut steps, &mut raw, &run, vi, vj, None, true);
                }
            }
            Seg::Follow(a, b, v) => {
                let kind = trail_kind(v).unwrap();
                let full = sub(a, b, true);
                let cum = cum_dist(&full.lat, &full.lon);
                let sidx = name_samples(&full.lat, &cum);
                let mut names: Vec<Option<String>> = vec![None; sidx.len()];
                if let Some(nm) = namer {
                    let pts: Vec<(f64, f64)> = sidx.iter().map(|&k| (full.lat[k], full.lon[k])).collect();
                    if let Some(got) = nm(&pts, kind) {
                        if got.len() == sidx.len() {
                            names = got;
                        }
                    }
                }
                let scum: Vec<f64> = sidx.iter().map(|&k| cum[k]).collect();
                let cuts = name_cuts(&names, &scum, min_leg_m);
                let mut bounds = vec![0usize];
                bounds.extend(cuts.iter().map(|&c| sidx[c]));
                bounds.push(full.lat.len() - 1);
                let mut sbounds = vec![0usize];
                sbounds.extend(cuts.iter().copied());
                sbounds.push(sidx.len() - 1);
                for q in 0..bounds.len() - 1 {
                    let (lo, hi) = (sbounds[q], sbounds[q + 1]);
                    let part = &names[lo..=hi];
                    emit(&mut steps, &mut raw, &full, bounds[q], bounds[q + 1],
                        Some(Follow { trail_kind: kind.to_string(), name: majority_name(part) }), false);
                }
            }
        }
    }
    (steps, raw)
}

// ---- router result -> ordered pieces -----------------------------------------------------------------

#[derive(Debug, Clone)]
pub enum PieceKind {
    Offroad { after_switch: bool },
    Road { start: (f64, f64), end: (f64, f64) },
}

#[derive(Debug, Clone)]
pub struct Piece {
    pub kind: PieceKind,
    pub mode: String,
    pub extra_s: f64,
    pub cells: Option<Cells>,
}

/// `pieces_from_result`: unified paths split into runs by mode (vehicle runs are road); a Valhalla bypass
/// result is one road piece. A mode change inside a unified path is a same-cell hop; its transition cost
/// rides in as extra_s on the next piece.
pub fn pieces_from_result(result: &RouteResult) -> Vec<Piece> {
    let mut pieces = Vec::new();
    if let Some(n) = &result.network {
        if n.coords.len() >= 2 {
            pieces.push(Piece {
                kind: PieceKind::Road { start: (n.coords[0].1, n.coords[0].0), end: (n.coords.last().unwrap().1, n.coords.last().unwrap().0) },
                mode: "vehicle".into(),
                extra_s: 0.0,
                cells: None,
            });
        }
        return pieces;
    }
    let Some(d) = &result.detail else { return pieces };
    if d.lat.len() < 2 {
        return pieces;
    }
    let n = d.mode.len();
    let (mut i, mut extra, mut first) = (0usize, 0.0f64, true);
    while i < n {
        let mut j = i;
        while j + 1 < n && d.mode[j + 1] == d.mode[i] {
            j += 1;
        }
        if j > i {
            let mname = d.mode[i].name().to_string();
            if d.mode[i] == Mode::Vehicle {
                pieces.push(Piece {
                    kind: PieceKind::Road { start: (d.lat[i], d.lon[i]), end: (d.lat[j], d.lon[j]) },
                    mode: mname,
                    extra_s: extra,
                    cells: Some(Cells::slice(d, i, j)),
                });
            } else {
                pieces.push(Piece { kind: PieceKind::Offroad { after_switch: !first }, mode: mname, extra_s: extra, cells: Some(Cells::slice(d, i, j)) });
            }
            first = false;
            extra = 0.0;
        }
        if j + 1 < n {
            extra += d.step_s[j];
        }
        i = j + 1;
    }
    pieces
}
