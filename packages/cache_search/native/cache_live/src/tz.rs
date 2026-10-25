//! Time zones: the offset in force at an instant, and an offline latitude/longitude to zone lookup.
//!
//! A place's zone comes, in this order, from the response (`timezone_path`, an IANA name; or `utc_offset_path`, a fixed
//! offset), then from the offline lookup of the place's position, then UTC. A named zone knows daylight saving time, so
//! a forecast that crosses the change shows the right offset on each side of it.

use chrono::{DateTime, FixedOffset, NaiveDateTime, Offset, TimeZone};
use chrono_tz::Tz;
use std::str::FromStr;
use std::sync::OnceLock;

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Zone {
    /// A fixed offset in seconds east of UTC (0 = UTC).
    Fixed(i32),
    Named(Tz),
}

impl Zone {
    pub const UTC: Zone = Zone::Fixed(0);

    pub fn from_name(name: &str) -> Option<Zone> {
        Tz::from_str(name.trim()).ok().map(Zone::Named)
    }

    /// The zone of a position, from the embedded boundaries (offline). `None` where no zone is known.
    pub fn at(lat: f64, lon: f64) -> Option<Zone> {
        static FINDER: OnceLock<tzf_rs::EmbeddedFinder> = OnceLock::new();
        let f = FINDER.get_or_init(tzf_rs::EmbeddedFinder::new);
        let name = f.get_tz_name(lon, lat);
        if name.is_empty() {
            None
        } else {
            Zone::from_name(name)
        }
    }

    /// The IANA name, for a named zone.
    pub fn name(&self) -> Option<&'static str> {
        match self {
            Zone::Named(t) => Some(t.name()),
            Zone::Fixed(_) => None,
        }
    }

    /// The offset in force at Unix time `t`.
    pub fn offset_at(&self, t: i64) -> FixedOffset {
        match self {
            Zone::Fixed(s) => FixedOffset::east_opt(*s).unwrap_or_else(|| FixedOffset::east_opt(0).expect("utc")),
            Zone::Named(tz) => match tz.timestamp_opt(t, 0).single() {
                Some(d) => d.offset().fix(),
                None => FixedOffset::east_opt(0).expect("utc"),
            },
        }
    }

    /// The same instant written in this zone.
    pub fn convert(&self, dt: DateTime<FixedOffset>) -> DateTime<FixedOffset> {
        dt.with_timezone(&self.offset_at(dt.timestamp()))
    }

    /// A wall-clock time in this zone as an instant (the earlier one when daylight saving makes it ambiguous).
    pub fn local(&self, n: &NaiveDateTime) -> Option<DateTime<FixedOffset>> {
        match self {
            Zone::Fixed(_) => self.offset_at(0).from_local_datetime(n).single(),
            Zone::Named(tz) => tz.from_local_datetime(n).earliest().map(|d| d.fixed_offset()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lookup_and_daylight_saving() {
        let burley = Zone::at(42.536, -113.792).unwrap();
        assert_eq!(burley.name(), Some("America/Boise"));
        assert_eq!(Zone::at(43.615, -116.202).unwrap().name(), Some("America/Boise"));
        assert_eq!(Zone::at(40.71, -74.0).unwrap().name(), Some("America/New_York"));
        assert_eq!(Zone::at(35.68, 139.69).unwrap().name(), Some("Asia/Tokyo"));
        // MDT before 2026-11-01 02:00, MST after
        let before = DateTime::parse_from_rfc3339("2026-10-31T12:00:00Z").unwrap().timestamp();
        let after = DateTime::parse_from_rfc3339("2026-11-02T12:00:00Z").unwrap().timestamp();
        assert_eq!(burley.offset_at(before).local_minus_utc(), -6 * 3600);
        assert_eq!(burley.offset_at(after).local_minus_utc(), -7 * 3600);
        let n = chrono::NaiveDate::from_ymd_opt(2026, 11, 10).unwrap().and_hms_opt(0, 0, 0).unwrap();
        assert_eq!(burley.local(&n).unwrap().to_rfc3339(), "2026-11-10T00:00:00-07:00");
        assert_eq!(Zone::Fixed(-21600).local(&n).unwrap().to_rfc3339(), "2026-11-10T00:00:00-06:00");
        assert_eq!(Zone::from_name("Nowhere/Land"), None);
    }
}
