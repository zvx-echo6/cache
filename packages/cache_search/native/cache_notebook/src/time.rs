//! An entry's "When": local ISO 8601 with its offset, as the phone wrote it (`2026-10-25T16:12:00-06:00`). The store keeps
//! the text as given, its day, and the instant (for ordering across offsets).

use crate::{Error, Result};

fn digits(s: &str, from: usize, n: usize) -> Option<i64> {
    let part = s.get(from..from + n)?;
    if !part.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    part.parse().ok()
}

/// Days from 1970-01-01 to the civil date (proleptic Gregorian).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146097 + doe - 719468
}

fn days_in_month(y: i64, m: i64) -> i64 {
    match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        _ if (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 => 29,
        _ => 28,
    }
}

/// `YYYY-MM-DDTHH:MM[:SS[.fff]](Z|+HH:MM|-HH:MM)` -> (the day `YYYY-MM-DD`, Unix seconds).
pub fn parse_when(s: &str) -> Result<(String, i64)> {
    let bad = || Error::bad(format!("occurred_at {s:?} must be local ISO 8601 with an offset, e.g. 2026-10-25T16:12:00-06:00"));
    let b = s.as_bytes();
    if b.len() < 17 || b[4] != b'-' || b[7] != b'-' || b[10] != b'T' || b[13] != b':' {
        return Err(bad());
    }
    let (y, mo, d, h, mi) = (
        digits(s, 0, 4).ok_or_else(bad)?,
        digits(s, 5, 2).ok_or_else(bad)?,
        digits(s, 8, 2).ok_or_else(bad)?,
        digits(s, 11, 2).ok_or_else(bad)?,
        digits(s, 14, 2).ok_or_else(bad)?,
    );
    let mut i = 16;
    let mut sec = 0;
    if b.get(i) == Some(&b':') {
        sec = digits(s, i + 1, 2).ok_or_else(bad)?;
        i += 3;
        if b.get(i) == Some(&b'.') {
            i += 1;
            let start = i;
            while i < b.len() && b[i].is_ascii_digit() {
                i += 1;
            }
            if i == start {
                return Err(bad());
            }
        }
    }
    let offset = match b.get(i) {
        Some(b'Z') if i + 1 == b.len() => 0,
        Some(&c) if (c == b'+' || c == b'-') && i + 6 == b.len() && b[i + 3] == b':' => {
            let oh = digits(s, i + 1, 2).ok_or_else(bad)?;
            let om = digits(s, i + 4, 2).ok_or_else(bad)?;
            if oh > 18 || om > 59 {
                return Err(bad());
            }
            let o = oh * 3600 + om * 60;
            if c == b'-' { -o } else { o }
        }
        _ => return Err(bad()),
    };
    if !(1..=12).contains(&mo) || d < 1 || d > days_in_month(y, mo) || h > 23 || mi > 59 || sec > 59 {
        return Err(bad());
    }
    let ts = days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + sec - offset;
    Ok((s[..10].to_string(), ts))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn when_parses_with_offsets() {
        assert_eq!(parse_when("1970-01-01T00:00:00Z").unwrap(), ("1970-01-01".into(), 0));
        assert_eq!(parse_when("2026-10-25T16:12:00-06:00").unwrap().1, parse_when("2026-10-25T22:12:00Z").unwrap().1);
        assert_eq!(parse_when("2026-10-25T16:12-06:00").unwrap().0, "2026-10-25");
        assert_eq!(parse_when("2024-02-29T10:00:00.250+01:00").unwrap().0, "2024-02-29");
        for bad in ["2026-10-25", "2026-10-25T16:12:00", "2026-02-30T10:00:00Z", "2026-10-25T24:00:00Z", "2026-10-25 16:12:00Z", "2026-10-25T16:12:00+0600"] {
            assert!(parse_when(bad).is_err(), "{bad}");
        }
    }
}
