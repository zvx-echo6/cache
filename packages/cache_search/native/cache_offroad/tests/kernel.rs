//! Ports of navi's kernel / cost unit tests (tests/test_offroute.py) with the same fixtures and
//! assertions, plus the scipy gaussian_filter exactness check.
use cache_offroad::astar::*;
use cache_offroad::cost::*;
use cache_offroad::transitions::*;

const INF: f64 = f64::INFINITY;

fn mg40() -> f64 {
    40.0f64.to_radians().tan()
}

#[test]
fn signed_tobler_asymmetry() {
    let up = speed_kmh(0.2, 0, 6.0, mg40());
    let down = speed_kmh(-0.2, 0, 6.0, mg40());
    assert!(down > up);
    let peak = speed_kmh(-0.05, 0, 6.0, mg40());
    assert!(peak >= speed_kmh(0.0, 0, 6.0, mg40()));
    assert!(peak >= speed_kmh(-0.15, 0, 6.0, mg40()));
}

#[test]
fn inflation_bumps_neighbors_and_preserves_inf() {
    let mut g = vec![1f32; 30 * 30];
    g[15 * 30 + 15] = 100.0;
    inflate_cost_multiplier(&mut g, 30, 30);
    assert!(g[15 * 30 + 16] > 1.0);
    assert!(g[0] < 1.05);
    let mut g2 = vec![1f32; 30 * 30];
    g2[15 * 30 + 15] = f32::INFINITY;
    inflate_cost_multiplier(&mut g2, 30, 30);
    assert!(g2[15 * 30 + 15].is_infinite());
    assert!(g2[15 * 30 + 16].is_finite() && g2[15 * 30 + 16] > 1.0);
}

/// Bit-level comparison with navi's `inflate_cost_multiplier` (scipy gaussian_filter, mode="nearest").
#[test]
fn inflate_matches_scipy_exactly() {
    let (rows, cols) = (17usize, 23usize);
    let mut a = vec![0f32; rows * cols];
    for i in 0..rows {
        for j in 0..cols {
            a[i * cols + j] = 1.0 + ((i * 7 + j * 13) % 5) as f32 * 0.5;
        }
    }
    a[3 * cols + 4] = f32::INFINITY;
    a[3 * cols + 5] = f32::INFINITY;
    a[10 * cols + 10] = f32::INFINITY;
    a[0] = 8.0;
    inflate_cost_multiplier(&mut a, rows, cols);
    let exp: Vec<u32> = include_str!("fixtures/inflate_expected.txt").split(',').map(|s| s.trim().parse().unwrap()).collect();
    let mut max_ulp = 0i64;
    for (v, &e) in a.iter().zip(&exp) {
        if e == 0xFFFF_FFFF {
            assert!(v.is_infinite());
        } else {
            max_ulp = max_ulp.max((v.to_bits() as i64 - e as i64).abs());
        }
    }
    // identical operation order: expect bit-identical, allow 1 ulp for libm differences in exp()
    assert!(max_ulp <= 1, "max ulp difference vs scipy: {max_ulp}");
}

#[test]
fn gaussian_kernel_shape() {
    // radius = int(4.0 * 1.8 + 0.5) = 7 -> 15 taps, normalised
    let k = gaussian_kernel(1.8, 4.0);
    assert_eq!(k.len(), 15);
    assert!((k.iter().sum::<f64>() - 1.0).abs() < 1e-15);
    assert!((k[0] - k[14]).abs() < 1e-18);
}

fn flat(n: usize) -> (Vec<f64>, Vec<f64>, Vec<u8>, Vec<f64>, Vec<u8>) {
    (vec![0.0; n * n], vec![1.0; n * n], vec![0; n * n], vec![INF; 256], vec![0; n * n])
}

#[test]
fn astar_small_synthetic_shortest_path() {
    let (elev, mult, trail, lookup, barr) = flat(30);
    let (idx, path, cost) = astar_multigoal(&mult, &elev, 30, 30, 30.0, 30.0, mg40(), 0, 6.0, &trail, &lookup, &barr, 2, 0, 0, &[29], &[29]);
    assert_eq!(idx, 0);
    assert_eq!(path[0], [0, 0]);
    assert_eq!(*path.last().unwrap(), [29, 29]);
    assert_eq!(path.len(), 30);
    assert!(cost > 0.0 && cost.is_finite());
}

#[test]
fn astar_multigoal_picks_cheaper() {
    let (elev, mult, trail, lookup, barr) = flat(30);
    let (idx, path, _) = astar_multigoal(&mult, &elev, 30, 30, 30.0, 30.0, mg40(), 0, 6.0, &trail, &lookup, &barr, 2, 0, 0, &[0, 20], &[5, 20]);
    assert_eq!(idx, 0);
    assert_eq!(*path.last().unwrap(), [0, 5]);
}

#[test]
fn compute_cost_multiplier_grid_math() {
    let elev = vec![0f32; 16];
    let friction = vec![2f32; 16];
    let mut cls = vec![30u8; 16];
    cls[0] = 80;
    let m = compute_cost_multiplier_grid(&elev, 4, 4, 30.0, Some(&friction), Some(&cls), None, Mode::TwoW);
    assert_eq!(m[5], 4.0);
    assert!(m[0].is_infinite());
}

#[test]
fn smooth_max_grade_penalty() {
    let mg = mg40();
    let run = |bump: f64, second_gap: bool| {
        let mut elev = vec![0.0; 25];
        elev[2 * 5] = bump;
        let mut mult = vec![1.0; 25];
        for c in 1..=3 {
            mult[2 * 5 + c] = INF;
        }
        if !second_gap {
            mult[2 * 5 + 4] = INF;
        }
        mult[5 + 1] = INF;
        mult[3 * 5 + 1] = INF;
        astar_multigoal(&mult, &elev, 5, 5, 30.0, 30.0, mg, 0, 6.0, &vec![0; 25], &vec![INF; 256], &vec![0; 25], 2, 0, 0, &[4], &[0])
    };
    let has = |p: &Vec<[i64; 2]>, c: [i64; 2]| p.contains(&c);
    let (i0, p0, c0) = run(0.0, false);
    assert!(i0 == 0 && has(&p0, [2, 0]));
    let (im, pm, cm) = run(26.0, false);
    assert!(im == 0 && has(&pm, [2, 0]));
    assert!(cm.is_finite() && cm > c0);
    let (ia, _, _) = run(300.0, false);
    assert_eq!(ia, -1);
    let (ir, pr, _) = run(300.0, true);
    assert!(ir == 0 && !has(&pr, [2, 0]) && has(&pr, [2, 4]));
}

#[test]
fn signed_grade_at_max_threshold() {
    let mg = 0.5;
    let elev = vec![0.0, mg * 30.0];
    let (idx, _, cost) = astar_multigoal(&[1.0, 1.0], &elev, 2, 1, 30.0, 30.0, mg, 0, 6.0, &[0, 0], &vec![INF; 256], &[0, 0], 2, 0, 0, &[1], &[0]);
    let expected = 30.0 * 3.6 / speed_kmh(mg, 0, 6.0, mg);
    assert_eq!(idx, 0);
    assert!((cost - expected).abs() < 1e-6);
}

// ---- multimode kernel ------------------------------------------------------------------------

struct ModeArrays {
    max_grade: Vec<f64>,
    sfid: Vec<i64>,
    base: Vec<f64>,
    tfs: Vec<f64>,
}
fn mode_arrays() -> ModeArrays {
    let mut a = ModeArrays { max_grade: vec![], sfid: vec![], base: vec![], tfs: vec![INF; 4 * 256] };
    for (mi, m) in Mode::ALL.iter().enumerate() {
        let p = m.profile();
        a.max_grade.push(p.max_slope_deg.to_radians().tan());
        a.sfid.push(p.speed_function as i64);
        a.base.push(p.base_speed_kmh);
        for &(tv, f) in p.trail_friction {
            a.tfs[mi * 256 + tv as usize] = f.unwrap_or(INF);
        }
    }
    a
}

#[allow(clippy::too_many_arguments)]
fn mm(
    rows: usize, cols: usize, n_modes: usize, stack: &[f32], elev: &[f32], ma: &ModeArrays, tfs: &[f64], trail: &[u8],
    boundary: i64, o: (usize, usize), om: &[usize], g: (usize, usize), gm: &[usize],
    tr: &[(i64, i64, usize, usize, f64)], dh: bool,
) -> SearchResult {
    let barr = vec![0u8; rows * cols];
    let trows: Vec<i64> = tr.iter().map(|t| t.0).collect();
    let tcols: Vec<i64> = tr.iter().map(|t| t.1).collect();
    let tf: Vec<usize> = tr.iter().map(|t| t.2).collect();
    let tt: Vec<usize> = tr.iter().map(|t| t.3).collect();
    let tc: Vec<f64> = tr.iter().map(|t| t.4).collect();
    astar_multigoal_multimode(&MultiModeInput {
        rows, cols, n_modes, cost_mult_stack: stack, elevation: elev, cell_size_lat_m: 30.0, cell_size_lon_m: 30.0,
        max_grade: &ma.max_grade[..n_modes], speed_function_ids: &ma.sfid[..n_modes], base_speed_kmh: &ma.base[..n_modes],
        trail_grid: trail, trail_friction_stack: tfs, barrier_grid: &barr, boundary_mode_id: boundary,
        origin_row: o.0, origin_col: o.1, origin_modes: om, goal_rows: &[g.0], goal_cols: &[g.1], goal_modes: gm,
        trans_rows: &trows, trans_cols: &tcols, trans_from_mode: &tf, trans_to_mode: &tt, trans_cost_s: &tc,
        disable_heuristic: dh, initial_heap_cap: 0,
    })
    .unwrap()
}

#[test]
fn multimode_foot_only_parity() {
    let n = 8;
    let (elev64, mult64, trail, lookup, barr) = flat(n);
    let (idx1, path1, cost1) = astar_multigoal(&mult64, &elev64, n, n, 30.0, 30.0, 40.0f64.to_radians().tan(), 0, 6.0, &trail, &lookup, &barr, 2, 0, 0, &[n - 1], &[n - 1]);
    let elev: Vec<f32> = elev64.iter().map(|&v| v as f32).collect();
    let stack = vec![1f32; n * n];
    let ma = mode_arrays();
    let r = mm(n, n, 1, &stack, &elev, &ma, &lookup, &trail, 2, (0, 0), &[0], (n - 1, n - 1), &[0], &[], false);
    assert!(r.goal_idx == idx1 && idx1 == 0);
    assert!((r.cost - cost1).abs() <= 1e-5 + 1e-5 * cost1.abs());
    let p2: Vec<[i64; 2]> = r.path.iter().map(|p| [p[0], p[1]]).collect();
    assert_eq!(p2, path1);
    assert!(r.path.iter().all(|p| p[2] == 0));
}

#[test]
fn multimode_parking_switch() {
    let (rows, cols, road_start) = (3usize, 50usize, 25usize);
    let elev = vec![0f32; rows * cols];
    let mut stack = vec![f32::INFINITY; rows * cols * 4];
    for r in 0..rows {
        for c in 0..cols {
            stack[(r * cols + c) * 4] = 1.0;
            if c >= road_start {
                stack[(r * cols + c) * 4 + 3] = 1.0;
            }
        }
    }
    let trail = vec![0u8; rows * cols];
    let ma = mode_arrays();
    let tr = [(1i64, road_start as i64, 0usize, 3usize, 60.0), (1, road_start as i64, 3, 0, 60.0)];
    let r = mm(rows, cols, 4, &stack, &elev, &ma, &ma.tfs, &trail, 1, (1, 0), &[0], (1, cols - 1), &[3, 0], &tr, false);
    assert_eq!(r.goal_idx, 0);
    let modes: Vec<i64> = r.path.iter().map(|p| p[2]).collect();
    assert!(modes[0] == 0 && *modes.last().unwrap() == 3);
    let sw: Vec<usize> = (1..modes.len()).filter(|&k| modes[k] != modes[k - 1]).collect();
    assert_eq!(sw.len(), 1);
    let sk = sw[0];
    assert!(modes[sk - 1] == 0 && modes[sk] == 3);
    assert_eq!((r.path[sk][0], r.path[sk][1]), (1, road_start as i64));
    assert_eq!((r.path[sk - 1][0], r.path[sk - 1][1]), (1, road_start as i64));
    let foot = mm(rows, cols, 4, &stack, &elev, &ma, &ma.tfs, &trail, 1, (1, 0), &[0], (1, cols - 1), &[0], &[], false);
    assert!(r.cost < foot.cost);
}

#[test]
fn multimode_no_transitions_independent() {
    let n = 12;
    let elev = vec![0f32; n * n];
    let stack = vec![1f32; n * n * 4];
    let trail = vec![0u8; n * n];
    let ma = mode_arrays();
    let all = [0usize, 1, 2, 3];
    let r = mm(n, n, 4, &stack, &elev, &ma, &ma.tfs, &trail, 2, (0, 0), &all, (n - 1, n - 1), &all, &[], false);
    let m0 = r.path[0][2];
    assert!(r.path.iter().all(|p| p[2] == m0));
    let mut costs = vec![];
    for mi in 0..4 {
        let (_, _, c) = astar_multigoal(&vec![1.0; n * n], &vec![0.0; n * n], n, n, 30.0, 30.0, ma.max_grade[mi], ma.sfid[mi], ma.base[mi],
            &trail, &ma.tfs[mi * 256..(mi + 1) * 256], &vec![0; n * n], 2, 0, 0, &[n - 1], &[n - 1]);
        costs.push(c);
    }
    let min = costs.iter().cloned().fold(INF, f64::min);
    assert!((r.cost - min).abs() <= 1e-5 + 1e-5 * min);
    assert_eq!(m0 as usize, costs.iter().position(|&c| c == min).unwrap());
}

#[test]
fn multimode_heuristic_admissibility() {
    let (rows, cols) = (6usize, 10usize);
    // deterministic pseudo-random elevations 0..20
    let mut s = 12345u64;
    let mut rnd = || {
        s = s.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((s >> 33) as f64 / (1u64 << 31) as f64) * 20.0
    };
    let elev: Vec<f32> = (0..rows * cols).map(|_| rnd() as f32).collect();
    let mut stack = vec![1f32; rows * cols * 4];
    for r in 2..4 {
        for c in 3..6 {
            for m in 1..4 {
                stack[(r * cols + c) * 4 + m] = f32::INFINITY;
            }
        }
    }
    let trail = vec![0u8; rows * cols];
    let ma = mode_arrays();
    let tr = [(0i64, 5i64, 0usize, 3usize, 60.0), (0, 5, 3, 0, 60.0)];
    let gm = [0usize, 3];
    let max_goal_speed = gm.iter().map(|&g| ma.base[g]).fold(0.0, f64::max);
    let mut sampled = 0;
    for r in (0..rows).step_by(2) {
        for c in (0..cols).step_by(3) {
            for m in [0usize, 3] {
                let d = (((r as f64 - 5.0) * 30.0).powi(2) + ((c as f64 - 9.0) * 30.0).powi(2)).sqrt();
                let h = d * 3.6 / max_goal_speed;
                let t = mm(rows, cols, 4, &stack, &elev, &ma, &ma.tfs, &trail, 2, (r, c), &[m], (5, 9), &gm, &tr, true);
                if !t.cost.is_finite() {
                    continue;
                }
                assert!(h <= t.cost + 1e-6);
                sampled += 1;
            }
        }
    }
    assert!(sampled > 0);
}

#[test]
fn route_auto_heuristic_admissibility_road_case() {
    // fast road (friction 0.1): the heuristic-guided cost equals the Dijkstra cost.
    let (rows, cols) = (3usize, 20usize);
    let elev = vec![1000f32; rows * cols];
    let mut trail = vec![0u8; rows * cols];
    for c in 0..cols {
        trail[cols + c] = 5;
    }
    let mut stack = vec![f32::INFINITY; rows * cols * 4];
    for i in 0..rows * cols {
        stack[i * 4] = 1.0;
    }
    let mut ma = mode_arrays();
    ma.tfs = vec![INF; 4 * 256];
    ma.tfs[5] = 0.1;
    ma.tfs[3 * 256 + 5] = 0.1;
    let mk = |dh| {
        let barr = vec![0u8; rows * cols];
        astar_multigoal_multimode(&MultiModeInput {
            rows, cols, n_modes: 4, cost_mult_stack: &stack, elevation: &elev, cell_size_lat_m: 100.0, cell_size_lon_m: 100.0,
            max_grade: &ma.max_grade, speed_function_ids: &ma.sfid, base_speed_kmh: &ma.base, trail_grid: &trail,
            trail_friction_stack: &ma.tfs, barrier_grid: &barr, boundary_mode_id: 1, origin_row: 1, origin_col: 0,
            origin_modes: &[3], goal_rows: &[1], goal_cols: &[19], goal_modes: &[3], trans_rows: &[], trans_cols: &[],
            trans_from_mode: &[], trans_to_mode: &[], trans_cost_s: &[], disable_heuristic: dh, initial_heap_cap: 0,
        })
        .unwrap()
    };
    let (h, d) = (mk(false), mk(true));
    assert!(h.cost.is_finite() && d.cost.is_finite());
    assert!(h.cost <= d.cost + 1e-6);
}

#[test]
fn heap_growth_path_same_result() {
    let n = 40;
    let elev = vec![0f32; n * n];
    let stack = vec![1f32; n * n * 4];
    let trail = vec![0u8; n * n];
    let ma = mode_arrays();
    let barr = vec![0u8; n * n];
    let mk = |cap| {
        astar_multigoal_multimode(&MultiModeInput {
            rows: n, cols: n, n_modes: 4, cost_mult_stack: &stack, elevation: &elev, cell_size_lat_m: 30.0, cell_size_lon_m: 30.0,
            max_grade: &ma.max_grade, speed_function_ids: &ma.sfid, base_speed_kmh: &ma.base, trail_grid: &trail,
            trail_friction_stack: &ma.tfs, barrier_grid: &barr, boundary_mode_id: 2, origin_row: 0, origin_col: 0,
            origin_modes: &[0], goal_rows: &[n - 1], goal_cols: &[n - 1], goal_modes: &[0], trans_rows: &[], trans_cols: &[],
            trans_from_mode: &[], trans_to_mode: &[], trans_cost_s: &[], disable_heuristic: false, initial_heap_cap: cap,
        })
        .unwrap()
    };
    let (a, b) = (mk(0), mk(16));
    assert_eq!(a.path, b.path);
    assert_eq!(a.cost, b.cost);
}

// ---- transitions -------------------------------------------------------------------------------

#[test]
fn transition_cap_closest_15() {
    let line = ((40.0, -111.0), (40.0, -110.0));
    let mut raw: Vec<Tup> = vec![];
    for k in 1..=20 {
        let lat = 40.0 + 0.0005 * k as f64;
        for (a, b) in [(0, 3), (3, 0), (0, 2), (2, 0), (0, 1), (1, 0)] {
            raw.push((lat, -110.5, a, b, 60.0));
        }
    }
    let capped = cap_candidates(raw, Some(line));
    let mut lats: Vec<i64> = capped.iter().map(|t| (t.0 * 1e6).round() as i64).collect();
    lats.sort();
    lats.dedup();
    let exp: Vec<i64> = (1..=15).map(|k| ((40.0 + 0.0005 * k as f64) * 1e6).round() as i64).collect();
    assert_eq!(lats, exp);
    assert_eq!(capped.len(), 15 * 6);
}

#[test]
fn cap_selects_same_set_as_scalar_oracle() {
    let line = ((40.0, -111.0), (40.0, -110.0));
    let mut raw: Vec<Tup> = vec![];
    for i in 0..200 {
        let lat = 40.0 + (i + 1) as f64 * 0.0008;
        raw.push((lat, -110.5, 0, 3, 60.0));
        raw.push((lat, -110.5, 3, 0, 60.0));
    }
    let got = cap_candidates(raw.clone(), Some(line));
    // oracle: group, score with the scalar great-circle distance, filter, sort, take 15
    let mut scored: Vec<(f64, f64)> = (0..200)
        .map(|i| 40.0 + (i + 1) as f64 * 0.0008)
        .map(|la| (cross_track_distance_m(la, -110.5, line), la))
        .filter(|(d, _)| *d <= CAP_RADIUS_M)
        .collect();
    scored.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap());
    let keep: Vec<f64> = scored.iter().take(15).map(|s| s.1).collect();
    assert_eq!(got.len(), 30);
    for t in &got {
        assert!(keep.contains(&t.0));
    }
}

fn meta_syn(rows: usize, cols: usize) -> cache_offroad::grid::GridMeta {
    let dlat = 30.0 / 111000.0;
    let dlon = 30.0 / (111000.0 * 40.0f64.to_radians().cos());
    cache_offroad::grid::GridMeta {
        bounds: (40.0, 40.0 + rows as f64 * dlat, -111.0, -111.0 + cols as f64 * dlon),
        pixel_size_lat: -dlat, pixel_size_lon: dlon, origin_lat: 40.0 + rows as f64 * dlat, origin_lon: -111.0,
        cell_size_m: 30.0, rows, cols, global_row0: 0, global_col0: 0,
    }
}

#[test]
fn road_terminus_transitions_pure_raster() {
    let (rows, cols) = (10usize, 10usize);
    let mut tg = vec![0u8; rows * cols];
    for c in 0..6 {
        tg[5 * cols + c] = 5;
    }
    let meta = meta_syn(rows, cols);
    let t = road_terminus_transitions(&meta, &tg, None);
    let mut cells: std::collections::BTreeMap<(i64, i64), Vec<(usize, usize)>> = Default::default();
    for (lat, lon, f, to, cost) in t {
        assert_eq!(cost, 60.0);
        cells.entry(meta.latlon_to_pixel_eps(lat, lon)).or_default().push((f, to));
    }
    let keys: Vec<(i64, i64)> = cells.keys().cloned().collect();
    assert_eq!(keys, (0..6).map(|c| (5i64, c as i64)).collect::<Vec<_>>());
    for e in cells.values() {
        let mut e = e.clone();
        e.sort();
        assert_eq!(e, vec![(0, 3), (3, 0)]);
    }
}

#[test]
fn road_terminus_dilation_no_wrap() {
    let (rows, cols) = (5usize, 5usize);
    let mut tg = vec![10u8; rows * cols];
    tg[0] = 5;
    tg[4 * cols + 4] = 0;
    assert!(road_terminus_transitions(&meta_syn(rows, cols), &tg, None).is_empty());
}
