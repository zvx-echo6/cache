//! Offline coordinate formats: USNG / MGRS and Plus Codes (Open Location Code).
//!
//! USNG and MGRS are the same grid. `usng` writes it the way TOOLS.md shows it: grid zone designator, 100 km square,
//! then easting and northing in whole metres, e.g. `12T VN 64780 10230`. UTM is the transverse Mercator series of
//! Kruger (Karney 2011, order n^3, about a millimetre inside a zone); the 100 km square letters follow the NGA
//! scheme for WGS 84 (set by zone number mod 3 for columns, rows offset by 5 in even zones). The zone exceptions of
//! Norway and Svalbard are applied. Outside 80 S to 84 N the polar grid (UPS) applies and `usng` gives None.

const A: f64 = 6_378_137.0;
const F: f64 = 1.0 / 298.257_223_563;
const K0: f64 = 0.9996;

/// UTM zone number for a point, with the Norway and Svalbard exceptions.
pub fn utm_zone(lat: f64, lon: f64) -> u32 {
    let lon = ((lon + 180.0) % 360.0 + 360.0) % 360.0 - 180.0;
    let mut zone = ((lon + 180.0) / 6.0).floor() as u32 + 1;
    if (56.0..64.0).contains(&lat) && (3.0..12.0).contains(&lon) {
        zone = 32;
    }
    if (72.0..84.0).contains(&lat) {
        zone = match lon {
            l if (0.0..9.0).contains(&l) => 31,
            l if (9.0..21.0).contains(&l) => 33,
            l if (21.0..33.0).contains(&l) => 35,
            l if (33.0..42.0).contains(&l) => 37,
            _ => zone,
        };
    }
    zone.clamp(1, 60)
}

/// Latitude band letter C..X (no I, no O).
pub fn lat_band(lat: f64) -> Option<char> {
    if !(-80.0..=84.0).contains(&lat) {
        return None;
    }
    let bands: Vec<char> = "CDEFGHJKLMNPQRSTUVWX".chars().collect();
    Some(bands[(((lat + 80.0) / 8.0).floor() as usize).min(19)])
}

/// (zone, easting m, northing m) in the given zone (false easting 500000, false northing 10000000 in the south).
pub fn to_utm(lat: f64, lon: f64, zone: u32) -> (f64, f64) {
    let n = F / (2.0 - F);
    let a_big = A / (1.0 + n) * (1.0 + n * n / 4.0 + n.powi(4) / 64.0);
    let alpha = [
        n / 2.0 - 2.0 * n * n / 3.0 + 5.0 * n.powi(3) / 16.0,
        13.0 * n * n / 48.0 - 3.0 * n.powi(3) / 5.0,
        61.0 * n.powi(3) / 240.0,
    ];
    let lon0 = ((zone as f64 - 1.0) * 6.0 - 180.0 + 3.0).to_radians();
    let phi = lat.to_radians();
    let dl = lon.to_radians() - lon0;
    let c = 2.0 * n.sqrt() / (1.0 + n);
    let t = (phi.sin().atanh() - c * (c * phi.sin()).atanh()).sinh();
    let xi0 = (t / dl.cos()).atan();
    let eta0 = (dl.sin() / (1.0 + t * t).sqrt()).atanh();
    let mut xi = xi0;
    let mut eta = eta0;
    for (j, a) in alpha.iter().enumerate() {
        let k = 2.0 * (j as f64 + 1.0);
        xi += a * (k * xi0).sin() * (k * eta0).cosh();
        eta += a * (k * xi0).cos() * (k * eta0).sinh();
    }
    let e = 500_000.0 + K0 * a_big * eta;
    let mut nn = K0 * a_big * xi;
    if lat < 0.0 {
        nn += 10_000_000.0;
    }
    (e, nn)
}

/// `12T VN 64780 10230`: zone and band, 100 km square, easting and northing in whole metres (truncated, as MGRS does).
pub fn usng(lat: f64, lon: f64) -> Option<String> {
    if !(lat.is_finite() && lon.is_finite()) {
        return None;
    }
    let band = lat_band(lat)?;
    let zone = utm_zone(lat, lon);
    let (e, n) = to_utm(lat, lon, zone);
    let col_sets = ["ABCDEFGH", "JKLMNPQR", "STUVWXYZ"];
    let cols: Vec<char> = col_sets[((zone - 1) % 3) as usize].chars().collect();
    let rows: Vec<char> = "ABCDEFGHJKLMNPQRSTUV".chars().collect();
    let col = cols.get((e / 100_000.0).floor() as usize - 1)?;
    let row = rows[((n / 100_000.0).floor() as usize + if zone.is_multiple_of(2) { 5 } else { 0 }) % 20];
    Some(format!("{zone}{band} {col}{row} {:05} {:05}", (e % 100_000.0).floor() as u64, (n % 100_000.0).floor() as u64))
}

const OLC_ALPHABET: &[u8; 20] = b"23456789CFGHJMPQRVWX";

/// A 10-digit Plus Code (about 14 m by 14 m), e.g. `849VCWC8+R9`.
pub fn plus_code(lat: f64, lon: f64) -> Option<String> {
    if !(lat.is_finite() && lon.is_finite()) {
        return None;
    }
    let lat = lat.clamp(-90.0, 90.0);
    let mut lon = lon;
    while lon < -180.0 {
        lon += 360.0;
    }
    while lon >= 180.0 {
        lon -= 360.0;
    }
    // 8000 cells per degree at 10 digits; the small nudge keeps float error from dropping a cell.
    let mut lat_v = (((lat + 90.0) * 8000.0) + 1e-6).floor() as i64;
    let mut lon_v = (((lon + 180.0) * 8000.0) + 1e-6).floor() as i64;
    lat_v = lat_v.clamp(0, 180 * 8000 - 1);
    lon_v = lon_v.clamp(0, 360 * 8000 - 1);
    let mut digits = [0u8; 10];
    for i in (0..5).rev() {
        digits[i * 2] = OLC_ALPHABET[(lat_v % 20) as usize];
        digits[i * 2 + 1] = OLC_ALPHABET[(lon_v % 20) as usize];
        lat_v /= 20;
        lon_v /= 20;
    }
    let s = String::from_utf8(digits.to_vec()).ok()?;
    Some(format!("{}+{}", &s[..8], &s[8..]))
}


// ---- reading coordinates a person types ------------------------------------------------------------------------------

/// What `parse` read: the point, the format it was written in, and how coarse the text was (the size in metres of the cell
/// or step it names), so a map can pick a sensible zoom.
#[derive(Debug, Clone, PartialEq)]
pub struct Parsed {
    pub lat: f64,
    pub lon: f64,
    /// "decimal", "dms", "usng" or "plus_code".
    pub format: &'static str,
    pub precision_m: f64,
}

/// Inverse of `to_utm` (Kruger series, order n^3): latitude and longitude of a UTM easting and northing.
pub fn from_utm(easting: f64, northing: f64, zone: u32, south: bool) -> (f64, f64) {
    let n = F / (2.0 - F);
    let a_big = A / (1.0 + n) * (1.0 + n * n / 4.0 + n.powi(4) / 64.0);
    let beta = [n / 2.0 - 2.0 * n * n / 3.0 + 37.0 * n.powi(3) / 96.0, n * n / 48.0 + n.powi(3) / 15.0, 17.0 * n.powi(3) / 480.0];
    let delta = [2.0 * n - 2.0 * n * n / 3.0 - 2.0 * n.powi(3), 7.0 * n * n / 3.0 - 8.0 * n.powi(3) / 5.0, 56.0 * n.powi(3) / 15.0];
    let nn = if south { northing - 10_000_000.0 } else { northing };
    let xi0 = nn / (K0 * a_big);
    let eta0 = (easting - 500_000.0) / (K0 * a_big);
    let (mut xi, mut eta) = (xi0, eta0);
    for (j, b) in beta.iter().enumerate() {
        let k = 2.0 * (j as f64 + 1.0);
        xi -= b * (k * xi0).sin() * (k * eta0).cosh();
        eta -= b * (k * xi0).cos() * (k * eta0).sinh();
    }
    let chi = (xi.sin() / eta.cosh()).asin();
    let mut phi = chi;
    for (j, d) in delta.iter().enumerate() {
        phi += d * (2.0 * (j as f64 + 1.0) * chi).sin();
    }
    let lon0 = ((zone as f64 - 1.0) * 6.0 - 180.0 + 3.0).to_radians();
    let lon = lon0 + eta.sinh().atan2(xi.cos());
    (phi.to_degrees(), lon.to_degrees())
}

/// `12T VN 64780 10230`, `12TVN6478010230`, `12T VN 6478 1023` (a coarser cell, read at its middle) or `12T VN` (a 100 km
/// square). The northing is the repeat of the row letter that falls inside the latitude band.
pub fn parse_usng(text: &str) -> Option<Parsed> {
    let t: String = text.trim().to_uppercase().chars().filter(|c| !c.is_whitespace()).collect();
    if !t.is_ascii() {
        return None;
    }
    let b = t.as_bytes();
    let mut i = 0;
    while i < b.len() && i < 2 && b[i].is_ascii_digit() {
        i += 1;
    }
    if i == 0 || b.len() < i + 3 {
        return None;
    }
    let zone: u32 = t[..i].parse().ok()?;
    if !(1..=60).contains(&zone) {
        return None;
    }
    let band_ix = "CDEFGHJKLMNPQRSTUVWX".find(b[i] as char)?;
    let col_ix = ["ABCDEFGH", "JKLMNPQR", "STUVWXYZ"][((zone - 1) % 3) as usize].find(b[i + 1] as char)?;
    let row_ix = "ABCDEFGHJKLMNPQRSTUV".find(b[i + 2] as char)?;
    let digits = &t[i + 3..];
    if !digits.bytes().all(|c| c.is_ascii_digit()) || !digits.len().is_multiple_of(2) || digits.len() > 10 {
        return None;
    }
    let half = digits.len() / 2;
    let step = 10f64.powi(5 - half as i32);
    let (de, dn) = if half == 0 { (0.0, 0.0) } else { (digits[..half].parse::<f64>().ok()? * step, digits[half..].parse::<f64>().ok()? * step) };
    let easting = (col_ix as f64 + 1.0) * 100_000.0 + de;
    let row_base = ((row_ix + 20 - if zone.is_multiple_of(2) { 5 } else { 0 }) % 20) as f64 * 100_000.0;
    let south = band_ix < 10;
    let band_s = -80.0 + 8.0 * band_ix as f64;
    let band_n = if band_ix == 19 { 84.0 } else { band_s + 8.0 };
    let mut best: Option<(f64, usize)> = None;
    for k in 0..6 {
        let (lat, _) = from_utm(easting, row_base + k as f64 * 2_000_000.0 + dn, zone, south);
        if !lat.is_finite() {
            continue;
        }
        let off = if lat < band_s { band_s - lat } else if lat > band_n { lat - band_n } else { 0.0 };
        if best.is_none_or(|(o, _)| off < o) {
            best = Some((off, k));
        }
    }
    let (off, k) = best?;
    if off > 0.25 {
        return None;
    }
    let mid = if half < 5 { step / 2.0 } else { 0.0 };
    let (lat, lon) = from_utm(easting + mid, row_base + k as f64 * 2_000_000.0 + dn + mid, zone, south);
    Some(Parsed { lat, lon, format: "usng", precision_m: if half == 0 { 100_000.0 } else { step } })
}

/// A Plus Code: a full code (`849VCWC8+R9`, also longer ones with grid digits, or shorter ones padded with zeros) or a
/// short one (`WC8+R9`) that needs `reference`, the point it is nearest to (the map centre).
pub fn parse_plus_code(text: &str, reference: Option<(f64, f64)>) -> Option<Parsed> {
    let t = text.trim().to_uppercase();
    if !t.is_ascii() || t.matches('+').count() != 1 {
        return None;
    }
    let plus = t.find('+')?;
    let (head, tail) = (&t[..plus], &t[plus + 1..]);
    let ok = |c: char| OLC_ALPHABET.contains(&(c as u8));
    if !head.chars().all(|c| ok(c) || c == '0') || !tail.chars().all(ok) || head.len() % 2 != 0 || head.len() > 8 || tail.len() == 1 || tail.len() > 7 {
        return None;
    }
    if head.len() < 8 {
        // short code: the missing leading digits come from the reference
        if head.contains('0') {
            return None;
        }
        let (rlat, rlon) = reference?;
        let pad = 8 - head.len();
        let prefix = plus_code(rlat, rlon)?;
        let full = format!("{}{}+{}", &prefix[..pad], head, tail);
        let mut p = decode_plus_code(&full)?;
        let res = 20f64.powi(2 - (pad as i32) / 2);
        let half = res / 2.0;
        if rlat + half < p.lat && p.lat - res >= -90.0 {
            p.lat -= res;
        } else if rlat - half > p.lat && p.lat + res <= 90.0 {
            p.lat += res;
        }
        if rlon + half < p.lon {
            p.lon -= res;
        } else if rlon - half > p.lon {
            p.lon += res;
        }
        return Some(p);
    }
    decode_plus_code(&t)
}

fn decode_plus_code(code: &str) -> Option<Parsed> {
    let plus = code.find('+')?;
    let digits: Vec<usize> = code.chars().filter(|c| *c != '+').take_while(|c| *c != '0').map(|c| OLC_ALPHABET.iter().position(|a| *a as char == c)).collect::<Option<_>>()?;
    if digits.len() < 2 || (digits.len() < 8 && !code[plus + 1..].is_empty()) {
        return None;
    }
    let pairs = digits.len().min(10) / 2;
    let (mut lat, mut lon) = (-90.0, -180.0);
    let mut res = 20.0;
    for p in 0..pairs {
        lat += digits[p * 2] as f64 * res;
        lon += digits[p * 2 + 1] as f64 * res;
        if p + 1 < pairs {
            res /= 20.0;
        }
    }
    let (mut lat_size, mut lon_size) = (res, res);
    for d in digits.iter().skip(10).take(5) {
        lat_size /= 5.0;
        lon_size /= 4.0;
        lat += (d / 4) as f64 * lat_size;
        lon += (d % 4) as f64 * lon_size;
    }
    let precision_m = lat_size.max(lon_size) * 111_320.0;
    Some(Parsed { lat: lat + lat_size / 2.0, lon: lon + lon_size / 2.0, format: "plus_code", precision_m })
}

enum Tok {
    Num { v: f64, decimals: usize },
    Hem(char),
}

/// `43.6,-116.2`, `43.6 -116.2`, `42°32'10"N 113°47'33"W`, `N 42 32.167 W 113 47.55`, `42.536N 113.792W`.
#[allow(clippy::needless_late_init)] // `groups` is set by two long matches, one per way the numbers can be written
fn parse_degrees(text: &str) -> Option<Parsed> {
    let chars: Vec<char> = text.trim().chars().collect();
    let mut toks: Vec<Tok> = Vec::new();
    let (mut comma, mut symbol) = (false, false);
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        let next_digit = chars.get(i + 1).is_some_and(|d| d.is_ascii_digit() || *d == '.');
        if c.is_ascii_digit() || ((c == '-' || c == '+' || c == '\u{2212}') && next_digit) || (c == '.' && next_digit) {
            let neg = c == '-' || c == '\u{2212}';
            let mut j = i + if c.is_ascii_digit() || c == '.' { 0 } else { 1 };
            let start = j;
            let mut seen_dot = false;
            while j < chars.len() && (chars[j].is_ascii_digit() || (chars[j] == '.' && !seen_dot)) {
                seen_dot |= chars[j] == '.';
                j += 1;
            }
            let s: String = chars[start..j].iter().collect();
            let v: f64 = s.parse().ok()?;
            let decimals = s.split_once('.').map(|(_, f)| f.len()).unwrap_or(0);
            toks.push(Tok::Num { v: if neg { -v } else { v }, decimals });
            i = j;
        } else if matches!(c, 'N' | 'S' | 'E' | 'W' | 'n' | 's' | 'e' | 'w') {
            let before = i > 0 && chars[i - 1].is_alphabetic();
            let after = chars.get(i + 1).is_some_and(|d| d.is_alphabetic());
            if before || after {
                return None;
            }
            toks.push(Tok::Hem(c.to_ascii_uppercase()));
            i += 1;
        } else if matches!(c, '\u{b0}' | '\u{ba}' | '\'' | '"' | '\u{2032}' | '\u{2033}' | '\u{2019}' | '\u{201d}') {
            symbol = true;
            i += 1;
        } else if c == ',' || c == ';' {
            comma = true;
            i += 1;
        } else if c.is_whitespace() {
            i += 1;
        } else {
            return None;
        }
    }
    let hems: Vec<(usize, char)> = toks.iter().enumerate().filter_map(|(k, t)| if let Tok::Hem(h) = t { Some((k, *h)) } else { None }).collect();
    let nums_in = |a: usize, b: usize| -> Vec<(f64, usize)> { toks[a..b].iter().filter_map(|t| if let Tok::Num { v, decimals } = t { Some((*v, *decimals)) } else { None }).collect() };
    let groups: Vec<Vec<(f64, usize)>>;
    let mut signs: Vec<Option<char>> = vec![None, None];
    if hems.is_empty() {
        let all = nums_in(0, toks.len());
        groups = match all.len() {
            2 => {
                if !(comma || symbol || all.iter().all(|n| n.1 > 0)) {
                    return None;
                }
                vec![vec![all[0]], vec![all[1]]]
            }
            4 if symbol || comma => vec![all[..2].to_vec(), all[2..].to_vec()],
            6 if symbol || comma => vec![all[..3].to_vec(), all[3..].to_vec()],
            _ => return None,
        };
    } else {
        if hems.len() != 2 {
            return None;
        }
        let (h1, h2) = (hems[0], hems[1]);
        let g = if h1.0 == 0 {
            // leading letters: "N 42 32 W 113 47"
            signs = vec![Some(h1.1), Some(h2.1)];
            vec![nums_in(h1.0, h2.0), nums_in(h2.0, toks.len())]
        } else {
            // trailing letters: "42 32 N 113 47 W"
            signs = vec![Some(h1.1), Some(h2.1)];
            vec![nums_in(0, h1.0), nums_in(h1.0, h2.0)]
        };
        groups = g;
    }
    let mut vals = [0.0f64; 2];
    let mut precision = f64::MAX;
    let mut dms = symbol || groups.iter().any(|g| g.len() > 1);
    for (k, g) in groups.iter().enumerate() {
        if g.is_empty() || g.len() > 3 {
            return None;
        }
        let neg = g[0].0 < 0.0 || (g[0].0 == 0.0 && false);
        let deg = g[0].0.abs();
        let min = g.get(1).map(|m| m.0).unwrap_or(0.0);
        let sec = g.get(2).map(|m| m.0).unwrap_or(0.0);
        if min < 0.0 || sec < 0.0 || min >= 60.0 || sec >= 60.0 || (g.len() > 1 && g[0].1 > 0) {
            return None;
        }
        let mut v = deg + min / 60.0 + sec / 3600.0;
        if neg {
            v = -v;
        }
        if let Some(h) = signs[k] {
            if g[0].0 < 0.0 {
                return None;
            }
            if h == 'S' || h == 'W' {
                v = -v;
            }
        }
        vals[k] = v;
        let last = g.last().unwrap();
        let unit = match g.len() {
            1 => 111_320.0,
            2 => 1855.0,
            _ => 31.0,
        };
        precision = precision.min(unit / 10f64.powi(last.1 as i32));
    }
    if hems.len() == 2 {
        // one letter must name latitude and the other longitude; with the letters first or last, the longitude may come first
        let lat_first = matches!(hems[0].1, 'N' | 'S');
        let lon_first = matches!(hems[0].1, 'E' | 'W');
        let second_ok = (lat_first && matches!(hems[1].1, 'E' | 'W')) || (lon_first && matches!(hems[1].1, 'N' | 'S'));
        if !second_ok {
            return None;
        }
        if lon_first {
            vals.swap(0, 1);
        }
    }
    let _ = &mut dms;
    let (lat, lon) = (vals[0], vals[1]);
    if lat.abs() > 90.0 || lon.abs() > 180.0 {
        return None;
    }
    Some(Parsed { lat, lon, format: if dms { "dms" } else { "decimal" }, precision_m: precision })
}

/// Any supported coordinate text, tried as a Plus Code, then USNG / MGRS, then degrees. `reference` is the map centre, which
/// a short Plus Code needs.
pub fn parse(text: &str, reference: Option<(f64, f64)>) -> Option<Parsed> {
    let t = text.trim();
    if t.is_empty() {
        return None;
    }
    if t.contains('+') && !t.starts_with(['+', '-']) {
        if let Some(p) = parse_plus_code(t, reference) {
            return Some(p);
        }
    }
    if let Some(p) = parse_usng(t) {
        return Some(p);
    }
    parse_degrees(t)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn usng_equator_prime_meridian() {
        // Published GeoTrans value: UTM 31N 166021 E, 0 N.
        assert_eq!(usng(0.0, 0.0).unwrap(), "31N AA 66021 00000");
    }

    #[test]
    fn usng_known_points() {
        // White House: 18S UJ 233 073 at 10 m resolution (zone 18 is even, so the rows are offset by five letters).
        let w = usng(38.8977, -77.0365).unwrap();
        assert!(w.starts_with("18S UJ 233") && w.ends_with(" 07395") || w.contains(" 073"), "{w}");
        // Zone and band for Idaho.
        assert!(usng(42.536, -113.792).unwrap().starts_with("12T "));
        assert!(usng(43.615, -116.202).unwrap().starts_with("11T "));
        assert!(usng(44.2, -114.93).unwrap().starts_with("11T "));
        // Southern hemisphere and a zone exception.
        assert!(usng(-33.8688, 151.2093).unwrap().starts_with("56H "));
        assert!(usng(60.0, 5.0).unwrap().starts_with("32V "));
        assert!(usng(78.0, 15.0).unwrap().starts_with("33X "));
    }

    #[test]
    fn usng_out_of_range() {
        assert!(usng(85.0, 0.0).is_none());
        assert!(usng(-81.0, 0.0).is_none());
    }

    #[test]
    fn usng_matches_independent_utm() {
        // Cross-check the transverse Mercator series against the `utm` crate over the western US and the world.
        for (lat, lon) in [(42.536, -113.792), (43.615, -116.202), (44.2, -114.93), (0.5, 0.5), (-33.8, 151.2), (60.0, 5.0), (10.0, -170.0)] {
            let zone = utm_zone(lat, lon);
            let (e, n) = to_utm(lat, lon, zone);
            let (un, ue, _) = utm::to_utm_wgs84(lat, lon, zone as u8);
            assert!((e - ue).abs() < 0.05 && (n - un).abs() < 0.05, "{lat},{lon}: ({e},{n}) vs ({ue},{un})");
        }
    }

    #[test]
    fn plus_code_vectors() {
        // Open Location Code reference examples.
        assert_eq!(plus_code(47.365562, 8.524813).unwrap(), "8FVC9G8F+6W");
        assert_eq!(plus_code(37.42205, -122.0841).unwrap(), "849VCWC8+R9");
        assert_eq!(plus_code(20.3700625, 2.7821875).unwrap(), "7FG49QCJ+2V");
        assert_eq!(plus_code(-90.0, -180.0).unwrap(), "22222222+22");
    }

    /// Decodes a 10-digit code back to its cell's south-west corner and size.
    fn decode10(code: &str) -> (f64, f64) {
        let digits: Vec<usize> = code.chars().filter(|c| *c != '+').map(|c| OLC_ALPHABET.iter().position(|a| *a as char == c).unwrap()).collect();
        let (mut lat, mut lon) = (0i64, 0i64);
        for pair in digits.chunks(2) {
            lat = lat * 20 + pair[0] as i64;
            lon = lon * 20 + pair[1] as i64;
        }
        (lat as f64 / 8000.0 - 90.0, lon as f64 / 8000.0 - 180.0)
    }

    #[test]
    fn plus_code_round_trips_into_its_cell() {
        let mut seed = 12345u64;
        let mut rnd = || {
            seed = seed.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            (seed >> 11) as f64 / (1u64 << 53) as f64
        };
        for _ in 0..2000 {
            let (lat, lon) = (rnd() * 180.0 - 90.0, rnd() * 360.0 - 180.0);
            let code = plus_code(lat, lon).unwrap();
            assert_eq!(code.len(), 11);
            assert_eq!(code.as_bytes()[8], b'+');
            let (clat, clon) = decode10(&code);
            let cell = 1.0 / 8000.0;
            assert!(lat >= clat - 1e-9 && lat < clat + cell + 1e-9, "{lat} vs cell {clat}");
            assert!(lon >= clon - 1e-9 && lon < clon + cell + 1e-9, "{lon} vs cell {clon}");
        }
    }

    fn near(a: Parsed, lat: f64, lon: f64, tol_m: f64) {
        let d = crate::geo::haversine_km(a.lat, a.lon, lat, lon) * 1000.0;
        assert!(d <= tol_m, "{a:?} is {d:.1} m from {lat},{lon}");
    }

    #[test]
    fn inverse_utm_round_trips() {
        for (lat, lon) in [(42.536, -113.792), (43.615, -116.202), (44.2, -114.93), (-33.8688, 151.2093), (0.5, 0.5), (60.0, 5.0), (10.0, -170.0)] {
            let zone = utm_zone(lat, lon);
            let (e, n) = to_utm(lat, lon, zone);
            let (la, lo) = from_utm(e, n, zone, lat < 0.0);
            assert!((la - lat).abs() < 1e-7 && (lo - lon).abs() < 1e-7, "{lat},{lon} -> {la},{lo}");
        }
    }

    #[test]
    fn usng_text_is_read_back() {
        for (lat, lon) in [(42.536, -113.792), (43.615, -116.202), (44.2, -114.93), (38.8977, -77.0365), (-33.8688, 151.2093), (0.5, 0.5), (60.0, 5.0), (78.0, 15.0)] {
            let text = usng(lat, lon).unwrap();
            let p = parse_usng(&text).unwrap_or_else(|| panic!("{text}"));
            assert_eq!(p.format, "usng");
            near(p.clone(), lat, lon, 2.0);
            // spacing and case do not matter, and the 8-digit and 4-digit forms are coarser cells around the point
            let packed = text.replace(' ', "").to_lowercase();
            near(parse_usng(&packed).unwrap(), lat, lon, 2.0);
        }
        let coarse = parse_usng("12T VN 6478 1023").unwrap();
        assert_eq!(coarse.precision_m, 10.0);
        near(coarse, parse_usng("12T VN 64780 10230").unwrap().lat, parse_usng("12T VN 64780 10230").unwrap().lon, 12.0);
        assert!(parse_usng("12T VN 6478 102").is_none());
        assert!(parse_usng("99T VN 64780 10230").is_none());
        assert!(parse_usng("Stanley").is_none());
        assert!(parse_usng("12T VI 64780 10230").is_none());
    }

    #[test]
    fn plus_codes_are_read() {
        let p = parse_plus_code("849VCWC8+R9", None).unwrap();
        near(p, 37.42205, -122.0841, 20.0);
        near(parse_plus_code("8FVC9G8F+6W", None).unwrap(), 47.365562, 8.524813, 20.0);
        // a code made here reads back inside its 14 m cell
        let c = plus_code(43.6150, -116.2023).unwrap();
        near(parse_plus_code(&c, None).unwrap(), 43.6150, -116.2023, 12.0);
        // shorter codes: a coarser cell, and a short code needs the map centre
        assert!(parse_plus_code("849VCWC8+", None).unwrap().precision_m > 100.0);
        assert!(parse_plus_code("WC8+R9", None).is_none());
        near(parse_plus_code("CWC8+R9", Some((37.4, -122.08))).unwrap(), 37.42205, -122.0841, 20.0);
        assert!(parse_plus_code("849VCWC8+R", None).is_none());
        assert!(parse_plus_code("hello+world", None).is_none());
    }

    #[test]
    fn degrees_in_every_common_form() {
        let d = |t: &str| parse(t, None).unwrap_or_else(|| panic!("{t:?} should read"));
        let p = d("43.6,-116.2");
        assert_eq!((p.lat, p.lon, p.format), (43.6, -116.2, "decimal"));
        assert_eq!(d("43.6 -116.2").lon, -116.2);
        assert_eq!(d(" 42.536 , -113.792 ").lat, 42.536);
        assert_eq!(d("43.6N 116.2W").lon, -116.2);
        assert_eq!(d("116.2W 43.6N").lat, 43.6);
        assert_eq!(d("S 33.8688 E 151.2093").lat, -33.8688);
        let p = d("42\u{b0}32'10\"N 113\u{b0}47'33\"W");
        assert_eq!(p.format, "dms");
        assert!((p.lat - 42.536111).abs() < 1e-5 && (p.lon + 113.7925).abs() < 1e-5, "{p:?}");
        let p = d("42 32 10 N, 113 47 33 W");
        assert!((p.lat - 42.536111).abs() < 1e-5 && p.lon < -113.79);
        let p = d("N 42\u{b0} 32.167' W 113\u{b0} 47.55'");
        assert!((p.lat - 42.536117).abs() < 1e-4 && (p.lon + 113.7925).abs() < 1e-4, "{p:?}");
        // the DMS the locate tool prints reads back
        let q = d(&crate::geo::dms(44.2210, -114.9360));
        assert!((q.lat - 44.2210).abs() < 1e-3 && (q.lon + 114.9360).abs() < 1e-3);
        // words, bare numbers and out-of-range values are not coordinates
        for t in ["Stanley", "Route 66", "84", "20 5", "91.5,10.2", "43.6,-216.2", "N 43.6 N 116.2", "43.6N 116.2", "pharmacy near Burley", ""] {
            assert!(parse(t, None).is_none(), "{t:?} should not read");
        }
    }
}
