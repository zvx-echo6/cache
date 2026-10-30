//! MVUM legal-access layer. Port of navi `mvum.py`: `parse_date_range`, `is_date_in_range`,
//! `check_access`, `symbol_to_access`, `get_mode_field`, `_draw_line`/`_rasterize_feature` and the
//! all-modes grid builder. Output grids: 0 = no data, 1 = open, 255 = closed.
use crate::grid::GridMeta;
use crate::pack::MvumFeature;

/// Parse "MM/DD-MM/DD[,..]" into (sm, sd, em, ed) tuples; unparseable parts are skipped.
pub fn parse_date_range(s: &str) -> Vec<(u32, u32, u32, u32)> {
    let mut out = Vec::new();
    if s.trim().is_empty() {
        return out;
    }
    for part in s.split(',') {
        let part = part.trim();
        // re.match(r"(\d{1,2})/(\d{1,2})-(\d{1,2})/(\d{1,2})", part): prefix match
        if let Some(t) = match_range(part) {
            let (sm, sd, em, ed) = t;
            if (1..=12).contains(&sm) && (1..=31).contains(&sd) && (1..=12).contains(&em) && (1..=31).contains(&ed) {
                out.push(t);
            }
        }
    }
    out
}

fn take_num(b: &[u8], i: &mut usize) -> Option<u32> {
    let start = *i;
    while *i < b.len() && b[*i].is_ascii_digit() && *i - start < 2 {
        *i += 1;
    }
    if *i == start {
        return None;
    }
    std::str::from_utf8(&b[start..*i]).ok()?.parse().ok()
}
fn expect(b: &[u8], i: &mut usize, ch: u8) -> Option<()> {
    if *i < b.len() && b[*i] == ch {
        *i += 1;
        Some(())
    } else {
        None
    }
}
fn match_range(s: &str) -> Option<(u32, u32, u32, u32)> {
    let b = s.as_bytes();
    let mut i = 0;
    let sm = take_num(b, &mut i)?;
    expect(b, &mut i, b'/')?;
    let sd = take_num(b, &mut i)?;
    expect(b, &mut i, b'-')?;
    let em = take_num(b, &mut i)?;
    expect(b, &mut i, b'/')?;
    let ed = take_num(b, &mut i)?;
    Some((sm, sd, em, ed))
}

pub fn is_date_in_range(month: u32, day: u32, ranges: &[(u32, u32, u32, u32)]) -> bool {
    if ranges.is_empty() {
        return true;
    }
    let date_num = month * 100 + day;
    for &(sm, sd, em, ed) in ranges {
        let (s, e) = (sm * 100 + sd, em * 100 + ed);
        if s <= e {
            if s <= date_num && date_num <= e {
                return true;
            }
        } else if date_num >= s || date_num <= e {
            return true;
        }
    }
    false
}

/// Some(true)=open, Some(false)=closed, None=no data.
pub fn check_access(status: Option<&str>, dates: Option<&str>, seasonal: Option<&str>, check_date: Option<(u32, u32)>) -> Option<bool> {
    let status = status?;
    if status.trim().is_empty() {
        return None;
    }
    if status.trim().to_lowercase() != "open" {
        return Some(false);
    }
    if let Some((m, d)) = check_date {
        if let Some(df) = dates {
            if !df.is_empty() {
                let ranges = parse_date_range(df);
                if !ranges.is_empty() {
                    return Some(is_date_in_range(m, d, &ranges));
                }
            }
        }
        if let Some(sea) = seasonal {
            let s = sea.trim().to_lowercase();
            if s == "yearlong" || s == "seasonal" {
                return Some(true);
            }
        }
    }
    Some(true)
}

/// Fallback on the SYMBOL field. `mode` is the MVUM mode name ("mtb", "atv", "vehicle").
pub fn symbol_to_access(symbol: Option<&str>, mode: &str) -> Option<bool> {
    let sym = symbol?.trim();
    match sym {
        "1" => Some(true),
        "2" => Some(!(mode == "atv" || mode == "motorcycle")),
        "3" => Some(false),
        "4" => Some(true),
        "11" | "12" => Some(false),
        _ => None,
    }
}

/// MVUM mode names in the order stored in `MvumFeature::access` (and the router modes they serve).
pub const MVUM_MODES: [&str; 3] = ["mtb", "atv", "vehicle"];

pub fn feature_access(f: &MvumFeature, mode_idx: usize, check_date: Option<(u32, u32)>) -> Option<bool> {
    let (st, dt) = &f.access[mode_idx];
    let a = check_access(st.as_deref(), dt.as_deref(), f.seasonal.as_deref(), check_date);
    if a.is_none() {
        return symbol_to_access(f.symbol.as_deref(), MVUM_MODES[mode_idx]);
    }
    a
}

#[allow(clippy::too_many_arguments)] // a grid, its size, two cells and a value: the plain Bresenham signature
fn draw_line(grid: &mut [u8], rows: i64, cols: i64, r1: i64, c1: i64, r2: i64, c2: i64, value: u8) {
    let dr = (r2 - r1).abs();
    let dc = (c2 - c1).abs();
    let sr = if r1 < r2 { 1 } else { -1 };
    let sc = if c1 < c2 { 1 } else { -1 };
    let mut err = dr - dc;
    let (mut r, mut c) = (r1, c1);
    loop {
        if r >= 0 && r < rows && c >= 0 && c < cols {
            let g = &mut grid[(r * cols + c) as usize];
            if *g == 0 || value == 255 {
                *g = value;
            }
        }
        if r == r2 && c == c2 {
            break;
        }
        let e2 = 2 * err;
        if e2 > -dc {
            err -= dc;
            r += sr;
        }
        if e2 < dr {
            err += dr;
            c += sc;
        }
    }
}

/// Rasterize the features for the three motorized modes (mtb, atv, vehicle) onto the query grid.
/// `check_date` = None reproduces the cached path navi's Auto uses (no seasonal check).
#[allow(clippy::needless_range_loop)] // `mi` is the mode index into the feature's access and the three grids
pub fn access_grids(feats: &[MvumFeature], meta: &GridMeta, check_date: Option<(u32, u32)>) -> [Vec<u8>; 3] {
    let (rows, cols) = (meta.rows as i64, meta.cols as i64);
    let n = meta.rows * meta.cols;
    let mut grids = [vec![0u8; n], vec![0u8; n], vec![0u8; n]];
    let top = meta.origin_lat + 0.5 * meta.pixel_size_lat.abs();
    let left = meta.origin_lon - 0.5 * meta.pixel_size_lon;
    let ps_lat = meta.pixel_size_lat.abs();
    let ps_lon = meta.pixel_size_lon;
    for f in feats {
        for mi in 0..3 {
            let Some(a) = feature_access(f, mi, check_date) else { continue };
            let value = if a { 1 } else { 255 };
            for line in &f.lines {
                for w in line.windows(2) {
                    let (x1, y1) = w[0];
                    let (x2, y2) = w[1];
                    // Python int(): truncation toward zero, as navi does
                    let rc = |x: f64, y: f64| (((top - y) / ps_lat) as i64, ((x - left) / ps_lon) as i64);
                    let (ra, ca) = rc(x1, y1);
                    let (rb, cb) = rc(x2, y2);
                    draw_line(&mut grids[mi], rows, cols, ra, ca, rb, cb, value);
                }
            }
        }
    }
    grids
}
