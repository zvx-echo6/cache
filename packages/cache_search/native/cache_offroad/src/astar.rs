//! The multimode A* kernel: a line-by-line port of navi `astar.py::astar_multigoal_multimode`
//! (with `_speed_kmh` and `_movement_edge_time`), and the single-mode `astar_multigoal` that the
//! navi tests use as the foot-parity oracle. State planes are f32 (g) / i32 (parent) like navi's.

pub const SLOPE_PENALTY_SCALE: f64 = 10.0;
pub const SLOPE_PENALTY_CAP: f64 = 1e6;
const INF: f64 = f64::INFINITY;

/// Mode speed (km/h) for a signed grade: 0=tobler 1=herzog 2=linear.
#[inline]
pub fn speed_kmh(signed_grade: f64, speed_function_id: i64, base_speed_kmh: f64, max_grade: f64) -> f64 {
    if speed_function_id == 0 {
        0.6 * base_speed_kmh * (-3.5 * (signed_grade + 0.05).abs()).exp()
    } else if speed_function_id == 1 {
        let s = signed_grade;
        let sa = s.abs();
        let mut denom = 1337.8 * s.powi(6) + 278.19 * s.powi(5) - 517.39 * s.powi(4) - 78.199 * s.powi(3)
            + 93.419 * s.powi(2) + 19.825 * sa + 1.64;
        if denom < 0.1 {
            denom = 0.1;
        }
        let mut rel = 1.0 / denom;
        if rel < 0.05 {
            rel = 0.05;
        } else if rel > 1.5 {
            rel = 1.5;
        }
        base_speed_kmh * rel
    } else {
        let mut v = base_speed_kmh * (1.0 - signed_grade.abs() / max_grade);
        if v < 0.0 {
            v = 0.0;
        }
        v
    }
}

/// Per-mode inputs of one edge evaluation.
pub struct ModeParams<'a> {
    /// context multiplier stack [rows*cols*n_modes] (f32), accessed as `stride`/`mode`.
    pub cost_mult: &'a [f32],
    pub stride: usize,
    pub mode: usize,
    pub trail_friction: &'a [f64], // 256
    pub max_grade: f64,
    pub speed_function_id: i64,
    pub base_speed_kmh: f64,
}

/// Per-edge time (s) for one 8-neighbour step in a single mode, or INF (`_movement_edge_time`).
#[inline]
#[allow(clippy::too_many_arguments)]
pub fn movement_edge_time(
    cr: usize, cc: usize, nr: usize, nc: usize, dr: i64, dc: i64, cols: usize,
    elevation: &[f32], mp: &ModeParams, trail_grid: &[u8], barrier_grid: &[u8], boundary_mode_id: i64,
    cell_size_lat_m: f64, cell_size_lon_m: f64,
) -> f64 {
    let ci = cr * cols + cc;
    let ni = nr * cols + nc;
    let elev_cur = elevation[ci] as f64;
    let elev_n = elevation[ni] as f64;
    if elev_cur.is_nan() || elev_n.is_nan() {
        return INF;
    }
    let dlat = dr as f64 * cell_size_lat_m;
    let dlon = dc as f64 * cell_size_lon_m;
    let dist = (dlat * dlat + dlon * dlon).sqrt();
    let signed_grade = (elev_n - elev_cur) / dist;
    let overshoot = signed_grade.abs() - mp.max_grade;
    let mut slope_penalty = 1.0;
    if overshoot > 0.0 {
        slope_penalty = (overshoot * SLOPE_PENALTY_SCALE).exp();
        if slope_penalty > SLOPE_PENALTY_CAP {
            return INF;
        }
    }
    let spd = speed_kmh(signed_grade, mp.speed_function_id, mp.base_speed_kmh, mp.max_grade);
    if spd <= 1e-9 {
        return INF;
    }
    let mut base_time = dist * 3.6 / spd;
    base_time *= slope_penalty;

    let tv_cur = trail_grid[ci];
    let tv_n = trail_grid[ni];
    let mut edge;
    if tv_cur > 0 || tv_n > 0 {
        let fc = if tv_cur > 0 { mp.trail_friction[tv_cur as usize] } else { INF };
        let fn_ = if tv_n > 0 { mp.trail_friction[tv_n as usize] } else { INF };
        let tf = if fc < fn_ { fc } else { fn_ };
        if !(tf < INF) {
            return INF;
        }
        edge = base_time * tf;
    } else {
        let mc = mp.cost_mult[ci * mp.stride + mp.mode] as f64;
        let mn = mp.cost_mult[ni * mp.stride + mp.mode] as f64;
        if !(mc < INF) || !(mn < INF) {
            return INF;
        }
        edge = base_time * 0.5 * (mc + mn);
    }
    if boundary_mode_id == 0 {
        if barrier_grid[ci] == 255 || barrier_grid[ni] == 255 {
            return INF;
        }
    } else if boundary_mode_id == 1 && (barrier_grid[ci] == 255 || barrier_grid[ni] == 255) {
        edge *= 5.0;
    }
    edge
}

/// Inputs of the multimode kernel (the Python argument list).
pub struct MultiModeInput<'a> {
    pub rows: usize,
    pub cols: usize,
    pub n_modes: usize,
    pub cost_mult_stack: &'a [f32], // [rows, cols, n_modes]
    pub elevation: &'a [f32],
    pub cell_size_lat_m: f64,
    pub cell_size_lon_m: f64,
    pub max_grade: &'a [f64],
    pub speed_function_ids: &'a [i64],
    pub base_speed_kmh: &'a [f64],
    pub trail_grid: &'a [u8],
    pub trail_friction_stack: &'a [f64], // [n_modes*256]
    pub barrier_grid: &'a [u8],
    pub boundary_mode_id: i64,
    pub origin_row: usize,
    pub origin_col: usize,
    pub origin_modes: &'a [usize],
    pub goal_rows: &'a [usize],
    pub goal_cols: &'a [usize],
    pub goal_modes: &'a [usize],
    pub trans_rows: &'a [i64],
    pub trans_cols: &'a [i64],
    pub trans_from_mode: &'a [usize],
    pub trans_to_mode: &'a [usize],
    pub trans_cost_s: &'a [f64],
    /// tests only: h = 0 (Dijkstra, the admissibility oracle).
    pub disable_heuristic: bool,
    /// tests only: >0 overrides the starting heap capacity.
    pub initial_heap_cap: usize,
}

pub struct SearchResult {
    pub goal_idx: i64,
    /// (row, col, mode)
    pub path: Vec<[i64; 3]>,
    pub cost: f64,
    /// states expanded (closed), for diagnostics
    pub expanded: u64,
}

#[inline]
fn push(heap_id: &mut [i64], heap_f: &mut [f64], hsize: &mut usize, id: i64, f: f64) {
    heap_id[*hsize] = id;
    heap_f[*hsize] = f;
    let mut j = *hsize;
    *hsize += 1;
    while j > 0 {
        let par = (j - 1) / 2;
        if heap_f[j] < heap_f[par] {
            heap_id.swap(j, par);
            heap_f.swap(j, par);
            j = par;
        } else {
            break;
        }
    }
}

pub fn astar_multigoal_multimode(inp: &MultiModeInput) -> Result<SearchResult, String> {
    let rows = inp.rows;
    let cols = inp.cols;
    let n_modes = inp.n_modes;
    let rc = rows * cols;
    let n_goals = inp.goal_rows.len();
    let mut goal_mode_ok = vec![false; n_modes];
    for &m in inp.goal_modes {
        goal_mode_ok[m] = true;
    }
    let mut max_goal_speed = 0.0f64;
    for &gm in inp.goal_modes {
        let s = inp.base_speed_kmh[gm];
        if s > max_goal_speed {
            max_goal_speed = s;
        }
    }
    // admissible heuristic: base speed / smallest factor reachable by any goal mode
    let mut min_factor = INF;
    for &gm in inp.goal_modes {
        for v in 0..256 {
            let f = inp.trail_friction_stack[gm * 256 + v];
            if f < min_factor {
                min_factor = f;
            }
        }
        for i in 0..rc {
            let cmv = inp.cost_mult_stack[i * n_modes + gm] as f64;
            if cmv < min_factor {
                min_factor = cmv;
            }
        }
    }
    if !(min_factor < INF) {
        min_factor = 1.0;
    }
    if min_factor < 1e-6 {
        min_factor = 1e-6;
    }
    let max_effective_speed = max_goal_speed / min_factor;

    if rc * n_modes >= 2147483647 {
        return Err("grid too large for the int32 parent plane".into());
    }
    let mut g_score = vec![f32::INFINITY; rc * n_modes]; // [r,c,m]
    let mut parent = vec![-1i32; rc * n_modes];
    let mut closed = vec![false; rc * n_modes];
    let sidx = |r: usize, c: usize, m: usize| (r * cols + c) * n_modes + m;

    // transition index: sorted by packed cell key
    let n_trans = inp.trans_rows.len();
    let mut max_trans_per_cell = 0usize;
    let mut order: Vec<usize> = (0..n_trans).collect();
    let key = |t: usize| inp.trans_rows[t] * cols as i64 + inp.trans_cols[t];
    order.sort_by_key(|&t| key(t));
    let s_key: Vec<i64> = order.iter().map(|&t| key(t)).collect();
    if n_trans > 0 {
        let mut run = 0;
        for t in 0..n_trans {
            if t > 0 && s_key[t] == s_key[t - 1] {
                run += 1;
            } else {
                run = 1;
            }
            max_trans_per_cell = max_trans_per_cell.max(run);
        }
    }

    let push_room = 8 + max_trans_per_cell;
    let heap_hard_cap = rc * n_modes * 8;
    let mut cap = if inp.initial_heap_cap > 0 { inp.initial_heap_cap } else { rc / 4 };
    if cap < n_modes + push_room {
        cap = n_modes + push_room;
    }
    if cap < 1024 && inp.initial_heap_cap == 0 {
        cap = 1024;
    }
    let mut heap_id = vec![0i64; cap];
    let mut heap_f = vec![0f64; cap];
    let mut hsize = 0usize;

    let heuristic = |r: usize, c: usize| -> f64 {
        if inp.disable_heuristic {
            return 0.0;
        }
        let mut best = INF;
        for gi in 0..n_goals {
            let dr = (r as f64 - inp.goal_rows[gi] as f64) * inp.cell_size_lat_m;
            let dc = (c as f64 - inp.goal_cols[gi] as f64) * inp.cell_size_lon_m;
            let d = (dr * dr + dc * dc).sqrt();
            if d < best {
                best = d;
            }
        }
        best * 3.6 / max_effective_speed
    };

    for &m0 in inp.origin_modes {
        g_score[sidx(inp.origin_row, inp.origin_col, m0)] = 0.0;
        heap_id[hsize] = (m0 * rc + inp.origin_row * cols + inp.origin_col) as i64;
        heap_f[hsize] = heuristic(inp.origin_row, inp.origin_col);
        hsize += 1;
    }

    let mut expanded = 0u64;
    while hsize > 0 {
        let cur_id = heap_id[0];
        hsize -= 1;
        heap_id[0] = heap_id[hsize];
        heap_f[0] = heap_f[hsize];
        let mut i = 0usize;
        loop {
            let l = 2 * i + 1;
            let r2 = 2 * i + 2;
            let mut sm = i;
            if l < hsize && heap_f[l] < heap_f[sm] {
                sm = l;
            }
            if r2 < hsize && heap_f[r2] < heap_f[sm] {
                sm = r2;
            }
            if sm != i {
                heap_id.swap(i, sm);
                heap_f.swap(i, sm);
                i = sm;
            } else {
                break;
            }
        }
        let cur = cur_id as usize;
        let m = cur / rc;
        let rem = cur % rc;
        let cr = rem / cols;
        let cc = rem % cols;
        if closed[sidx(cr, cc, m)] {
            continue;
        }
        closed[sidx(cr, cc, m)] = true;
        expanded += 1;

        let mut goal_gi: i64 = -1;
        if goal_mode_ok[m] {
            for gi in (0..n_goals).rev() {
                if inp.goal_rows[gi] == cr && inp.goal_cols[gi] == cc {
                    goal_gi = gi as i64;
                    break;
                }
            }
        }
        if goal_gi >= 0 {
            let mut path = Vec::new();
            let mut node = cur_id;
            while node != -1 {
                let n = node as usize;
                let pm = n / rc;
                let prem = n % rc;
                let (pr, pc) = (prem / cols, prem % cols);
                path.push([pr as i64, pc as i64, pm as i64]);
                node = parent[sidx(pr, pc, pm)] as i64;
            }
            path.reverse();
            return Ok(SearchResult { goal_idx: goal_gi, path, cost: g_score[sidx(cr, cc, m)] as f64, expanded });
        }

        let g_cur = g_score[sidx(cr, cc, m)] as f64;
        if inp.elevation[cr * cols + cc].is_nan() {
            continue;
        }

        if hsize + push_room > cap {
            if hsize + push_room > heap_hard_cap {
                return Ok(SearchResult { goal_idx: -1, path: vec![], cost: INF, expanded });
            }
            let mut new_cap = cap * 2;
            if new_cap > heap_hard_cap {
                new_cap = heap_hard_cap;
            }
            if new_cap < hsize + push_room {
                new_cap = hsize + push_room;
            }
            heap_id.resize(new_cap, 0);
            heap_f.resize(new_cap, 0.0);
            cap = new_cap;
        }

        let mp = ModeParams {
            cost_mult: inp.cost_mult_stack,
            stride: n_modes,
            mode: m,
            trail_friction: &inp.trail_friction_stack[m * 256..(m + 1) * 256],
            max_grade: inp.max_grade[m],
            speed_function_id: inp.speed_function_ids[m],
            base_speed_kmh: inp.base_speed_kmh[m],
        };

        for dr in -1i64..=1 {
            for dc in -1i64..=1 {
                if dr == 0 && dc == 0 {
                    continue;
                }
                let nr = cr as i64 + dr;
                let nc = cc as i64 + dc;
                if nr < 0 || nr >= rows as i64 || nc < 0 || nc >= cols as i64 {
                    continue;
                }
                let (nr, nc) = (nr as usize, nc as usize);
                if closed[sidx(nr, nc, m)] {
                    continue;
                }
                let edge = movement_edge_time(
                    cr, cc, nr, nc, dr, dc, cols, inp.elevation, &mp, inp.trail_grid, inp.barrier_grid,
                    inp.boundary_mode_id, inp.cell_size_lat_m, inp.cell_size_lon_m,
                );
                if !(edge < INF) {
                    continue;
                }
                let tentative = g_cur + edge;
                if tentative < g_score[sidx(nr, nc, m)] as f64 {
                    g_score[sidx(nr, nc, m)] = tentative as f32;
                    parent[sidx(nr, nc, m)] = cur_id as i32;
                    let f = tentative + heuristic(nr, nc);
                    if hsize < cap {
                        push(&mut heap_id, &mut heap_f, &mut hsize, (m * rc + nr * cols + nc) as i64, f);
                    }
                }
            }
        }

        if n_trans > 0 {
            let cell_key = (cr * cols + cc) as i64;
            let base = s_key.partition_point(|&k| k < cell_key);
            let end = s_key.partition_point(|&k| k <= cell_key);
            for ti in base..end {
                let t = order[ti];
                if inp.trans_from_mode[t] != m {
                    continue;
                }
                let to_m = inp.trans_to_mode[t];
                if closed[sidx(cr, cc, to_m)] {
                    continue;
                }
                let tentative = g_cur + inp.trans_cost_s[t];
                if tentative < g_score[sidx(cr, cc, to_m)] as f64 {
                    g_score[sidx(cr, cc, to_m)] = tentative as f32;
                    parent[sidx(cr, cc, to_m)] = cur_id as i32;
                    let f = tentative + heuristic(cr, cc);
                    if hsize < cap {
                        push(&mut heap_id, &mut heap_f, &mut hsize, (to_m * rc + cr * cols + cc) as i64, f);
                    }
                }
            }
        }
    }
    Ok(SearchResult { goal_idx: -1, path: vec![], cost: INF, expanded })
}

// ---- single-mode kernel (navi astar_multigoal; float64 planes) ---------------------------------

/// Single-mode, multi-goal A* (`astar_multigoal`): the oracle for the foot-only parity test and the
/// `test_multimode_no_transitions_independent` comparison. cost_mult is f64 here (as in the navi tests).
#[allow(clippy::too_many_arguments)]
pub fn astar_multigoal(
    cost_mult: &[f64], elevation: &[f64], rows: usize, cols: usize, cell_size_lat_m: f64, cell_size_lon_m: f64,
    max_grade: f64, speed_function_id: i64, base_speed_kmh: f64, trail_grid: &[u8], trail_friction: &[f64],
    barrier_grid: &[u8], boundary_mode_id: i64, origin_row: usize, origin_col: usize, goal_rows: &[usize],
    goal_cols: &[usize],
) -> (i64, Vec<[i64; 2]>, f64) {
    let mut goal_index = vec![-1i64; rows * cols];
    for gi in 0..goal_rows.len() {
        goal_index[goal_rows[gi] * cols + goal_cols[gi]] = gi as i64;
    }
    let mut g_score = vec![INF; rows * cols];
    let mut parent = vec![-1i64; rows * cols];
    let mut closed = vec![false; rows * cols];
    let cap = (rows * cols * 4).max(1024);
    let mut heap_id = vec![0i64; cap];
    let mut heap_f = vec![0f64; cap];
    let mut hsize = 0usize;
    let heuristic = |r: usize, c: usize| -> f64 {
        let mut best = INF;
        for gi in 0..goal_rows.len() {
            let dr = (r as f64 - goal_rows[gi] as f64) * cell_size_lat_m;
            let dc = (c as f64 - goal_cols[gi] as f64) * cell_size_lon_m;
            let d = (dr * dr + dc * dc).sqrt();
            if d < best {
                best = d;
            }
        }
        best * 3.6 / base_speed_kmh
    };
    g_score[origin_row * cols + origin_col] = 0.0;
    heap_id[0] = (origin_row * cols + origin_col) as i64;
    heap_f[0] = heuristic(origin_row, origin_col);
    hsize = hsize.max(1);
    while hsize > 0 {
        let cur_id = heap_id[0];
        hsize -= 1;
        heap_id[0] = heap_id[hsize];
        heap_f[0] = heap_f[hsize];
        let mut i = 0;
        loop {
            let l = 2 * i + 1;
            let r = 2 * i + 2;
            let mut sm = i;
            if l < hsize && heap_f[l] < heap_f[sm] {
                sm = l;
            }
            if r < hsize && heap_f[r] < heap_f[sm] {
                sm = r;
            }
            if sm != i {
                heap_id.swap(i, sm);
                heap_f.swap(i, sm);
                i = sm;
            } else {
                break;
            }
        }
        let cur = cur_id as usize;
        let (cr, cc) = (cur / cols, cur % cols);
        if closed[cur] {
            continue;
        }
        closed[cur] = true;
        if goal_index[cur] >= 0 {
            let mut path = Vec::new();
            let mut node = cur_id;
            while node != -1 {
                path.push([(node as usize / cols) as i64, (node as usize % cols) as i64]);
                node = parent[node as usize];
            }
            path.reverse();
            return (goal_index[cur], path, g_score[cur]);
        }
        let g_cur = g_score[cur];
        let elev_cur = elevation[cur];
        if elev_cur.is_nan() {
            continue;
        }
        for dr in -1i64..=1 {
            for dc in -1i64..=1 {
                if dr == 0 && dc == 0 {
                    continue;
                }
                let nr = cr as i64 + dr;
                let nc = cc as i64 + dc;
                if nr < 0 || nr >= rows as i64 || nc < 0 || nc >= cols as i64 {
                    continue;
                }
                let ni = nr as usize * cols + nc as usize;
                if closed[ni] {
                    continue;
                }
                let elev_n = elevation[ni];
                if elev_n.is_nan() {
                    continue;
                }
                let dlat = dr as f64 * cell_size_lat_m;
                let dlon = dc as f64 * cell_size_lon_m;
                let dist = (dlat * dlat + dlon * dlon).sqrt();
                let signed_grade = (elev_n - elev_cur) / dist;
                let overshoot = signed_grade.abs() - max_grade;
                let mut slope_penalty = 1.0;
                if overshoot > 0.0 {
                    slope_penalty = (overshoot * SLOPE_PENALTY_SCALE).exp();
                    if slope_penalty > SLOPE_PENALTY_CAP {
                        continue;
                    }
                }
                let spd = speed_kmh(signed_grade, speed_function_id, base_speed_kmh, max_grade);
                if spd <= 1e-9 {
                    continue;
                }
                let mut base_time = dist * 3.6 / spd;
                base_time *= slope_penalty;
                let tv_cur = trail_grid[cur];
                let tv_n = trail_grid[ni];
                let mut edge;
                if tv_cur > 0 || tv_n > 0 {
                    let fc = if tv_cur > 0 { trail_friction[tv_cur as usize] } else { INF };
                    let fn_ = if tv_n > 0 { trail_friction[tv_n as usize] } else { INF };
                    let tf = if fc < fn_ { fc } else { fn_ };
                    if !(tf < INF) {
                        continue;
                    }
                    edge = base_time * tf;
                } else {
                    let mc = cost_mult[cur];
                    let mn = cost_mult[ni];
                    if !(mc < INF) || !(mn < INF) {
                        continue;
                    }
                    edge = base_time * 0.5 * (mc + mn);
                }
                if boundary_mode_id == 0 {
                    if barrier_grid[cur] == 255 || barrier_grid[ni] == 255 {
                        continue;
                    }
                } else if boundary_mode_id == 1 && (barrier_grid[cur] == 255 || barrier_grid[ni] == 255) {
                    edge *= 5.0;
                }
                let tentative = g_cur + edge;
                if tentative < g_score[ni] {
                    g_score[ni] = tentative;
                    parent[ni] = cur_id;
                    let f = tentative + heuristic(nr as usize, nc as usize);
                    if hsize < cap {
                        push(&mut heap_id, &mut heap_f, &mut hsize, ni as i64, f);
                    }
                }
            }
        }
    }
    (-1, vec![], INF)
}
