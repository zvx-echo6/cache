//! Distance, direction and degree formats.

pub const EARTH_KM: f64 = 6371.0088;
pub const KM_PER_MI: f64 = 1.609344;

pub fn haversine_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let (p1, p2) = (lat1.to_radians(), lat2.to_radians());
    let dl = (lon2 - lon1).to_radians();
    let a = ((p2 - p1) / 2.0).sin().powi(2) + p1.cos() * p2.cos() * (dl / 2.0).sin().powi(2);
    2.0 * EARTH_KM * a.sqrt().min(1.0).asin()
}

/// Initial bearing from point 1 to point 2, degrees clockwise from north, 0 to 360.
pub fn bearing_deg(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let (p1, p2) = (lat1.to_radians(), lat2.to_radians());
    let dl = (lon2 - lon1).to_radians();
    let y = dl.sin() * p2.cos();
    let x = p1.cos() * p2.sin() - p1.sin() * p2.cos() * dl.cos();
    (y.atan2(x).to_degrees() + 360.0) % 360.0
}

/// The 8-point compass word for a bearing.
pub fn compass8(deg: f64) -> &'static str {
    const NAMES: [&str; 8] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
    NAMES[(((deg % 360.0 + 360.0) % 360.0 + 22.5) / 45.0) as usize % 8]
}

pub fn km_to_mi(km: f64) -> f64 {
    km / KM_PER_MI
}

/// A box (min_lat, max_lat, min_lon, max_lon) that contains the circle of `radius_km` around the point.
pub fn bbox_around(lat: f64, lon: f64, radius_km: f64) -> (f64, f64, f64, f64) {
    let dlat = radius_km / 111.0;
    let dlon = radius_km / (111.0 * lat.to_radians().cos().abs().max(0.01));
    ((lat - dlat).max(-90.0), (lat + dlat).min(90.0), (lon - dlon).max(-180.0), (lon + dlon).min(180.0))
}

/// `42°32'10"N 113°47'33"W`: whole seconds, rounded.
pub fn dms(lat: f64, lon: f64) -> String {
    fn one(v: f64, pos: char, neg: char) -> String {
        let secs = (v.abs() * 3600.0).round() as u64;
        format!("{}\u{b0}{}'{}\"{}", secs / 3600, (secs % 3600) / 60, secs % 60, if v < 0.0 { neg } else { pos })
    }
    format!("{} {}", one(lat, 'N', 'S'), one(lon, 'E', 'W'))
}

pub fn round_to(v: f64, decimals: i32) -> f64 {
    let m = 10f64.powi(decimals);
    (v * m).round() / m
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dms_format() {
        assert_eq!(dms(42.53612, -113.79245), "42\u{b0}32'10\"N 113\u{b0}47'33\"W");
        assert_eq!(dms(-33.8688, 151.2093), "33\u{b0}52'8\"S 151\u{b0}12'33\"E");
    }

    #[test]
    fn compass() {
        assert_eq!(compass8(0.0), "N");
        assert_eq!(compass8(44.0), "NE");
        assert_eq!(compass8(180.0), "S");
        assert_eq!(compass8(359.0), "N");
        assert_eq!(compass8(300.0), "NW");
        assert_eq!(compass8(292.4), "W");
    }

    #[test]
    fn distance_burley_boise() {
        let d = haversine_km(42.536, -113.792, 43.615, -116.202);
        assert!((d - 230.0).abs() < 5.0, "{d}");
        let b = bearing_deg(42.536, -113.792, 43.615, -116.202);
        assert!((295.0..310.0).contains(&b), "{b}");
    }
}
