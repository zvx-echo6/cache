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
    let row = rows[((n / 100_000.0).floor() as usize + if zone % 2 == 0 { 5 } else { 0 }) % 20];
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
}
