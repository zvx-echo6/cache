//! Checking a call's fields against the definition (docs/ACTIONS.md, "Calling an action"). Only the first problem is reported,
//! looked for in a fixed order: unknown fields (in the order the call gave them), missing required fields (in `required`
//! order), then each field's value (in the definition's order).

use crate::def::{ActionDef, FieldDef, Kind};
use cache_tool::ToolError;
use serde_json::{Map, Value};

/// The longest `place` text.
pub const MAX_PLACE_CHARS: usize = 300;

pub fn bad_arguments(field: &str, reason: &str, detail: impl Into<String>) -> ToolError {
    ToolError::new(ToolError::BAD_ARGUMENTS, detail).with("field", field).with("reason", reason)
}

fn blank(v: &Value) -> bool {
    matches!(v, Value::String(s) if s.trim().is_empty())
}

/// A field the call really gives: `null` counts as left out.
fn given<'a>(fields: &'a Map<String, Value>, name: &str) -> Option<&'a Value> {
    fields.get(name).filter(|v| !v.is_null())
}

/// `YYYY-MM-DD`, a real calendar date.
pub fn valid_date(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return false;
    }
    let digits = |r: std::ops::Range<usize>| b[r].iter().all(u8::is_ascii_digit);
    if !(digits(0..4) && digits(5..7) && digits(8..10)) {
        return false;
    }
    let (y, m, d): (u32, u32, u32) = (s[0..4].parse().unwrap_or(0), s[5..7].parse().unwrap_or(0), s[8..10].parse().unwrap_or(0));
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let days = match m {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if leap => 29,
        2 => 28,
        _ => return false,
    };
    (1..=days).contains(&d)
}

/// `HH:MM`, 24-hour.
pub fn valid_time(s: &str) -> bool {
    let b = s.as_bytes();
    if b.len() != 5 || b[2] != b':' || !b[0..2].iter().chain(&b[3..5]).all(u8::is_ascii_digit) {
        return false;
    }
    let (h, m): (u32, u32) = (s[0..2].parse().unwrap_or(99), s[3..5].parse().unwrap_or(99));
    h <= 23 && m <= 59
}

/// An ISO 8601 duration with whole numbers only: `P[nY][nM][nW][nD][T[nH][nM][nS]]`, at least one part, and a `T` only when a
/// time part follows it.
pub fn valid_duration(s: &str) -> bool {
    let Some(rest) = s.strip_prefix('P') else { return false };
    let (date, time) = match rest.split_once('T') {
        Some((d, t)) => (d, Some(t)),
        None => (rest, None),
    };
    fn parts(mut s: &str, units: &[char]) -> Option<usize> {
        let mut count = 0;
        let mut next = 0; // units must come in order
        while !s.is_empty() {
            let n = s.chars().take_while(char::is_ascii_digit).count();
            if n == 0 {
                return None;
            }
            let unit = s[n..].chars().next()?;
            let pos = units.iter().position(|u| *u == unit)?;
            if pos < next {
                return None;
            }
            next = pos + 1;
            count += 1;
            s = &s[n + unit.len_utf8()..];
        }
        Some(count)
    }
    let Some(dc) = parts(date, &['Y', 'M', 'W', 'D']) else { return false };
    match time {
        None => dc > 0,
        Some(t) => matches!(parts(t, &['H', 'M', 'S']), Some(tc) if tc > 0),
    }
}

fn check_value(f: &FieldDef, v: &Value) -> Result<(), ToolError> {
    let n = &f.name;
    match &f.kind {
        Kind::Str { max_length, choices } => {
            let Some(s) = v.as_str() else { return Err(bad_arguments(n, "wrong_type", format!("{n}: must be a string"))) };
            if let Some(list) = choices {
                if !list.iter().any(|c| c == s) {
                    return Err(bad_arguments(n, "not_allowed", format!("{n}: must be one of {}", list.join(", "))));
                }
            }
            if s.chars().count() > *max_length {
                return Err(bad_arguments(n, "too_long", format!("{n}: must be at most {max_length} characters")));
            }
        }
        Kind::Number { min, max } => {
            let Some(x) = v.as_f64().filter(|_| v.is_number()) else { return Err(bad_arguments(n, "wrong_type", format!("{n}: must be a number"))) };
            if let Some(m) = min.filter(|m| x < *m) {
                return Err(bad_arguments(n, "out_of_range", format!("{n}: must be at least {m}")));
            }
            if let Some(m) = max.filter(|m| x > *m) {
                return Err(bad_arguments(n, "out_of_range", format!("{n}: must be at most {m}")));
            }
        }
        Kind::Integer { min, max } => {
            if !(v.is_i64() || v.is_u64()) {
                return Err(bad_arguments(n, "wrong_type", format!("{n}: must be an integer")));
            }
            let Some(x) = v.as_i64() else { return Err(bad_arguments(n, "out_of_range", format!("{n}: is too large"))) };
            if let Some(m) = min.filter(|m| x < *m) {
                return Err(bad_arguments(n, "out_of_range", format!("{n}: must be at least {m}")));
            }
            if let Some(m) = max.filter(|m| x > *m) {
                return Err(bad_arguments(n, "out_of_range", format!("{n}: must be at most {m}")));
            }
        }
        Kind::Boolean => {
            if !v.is_boolean() {
                return Err(bad_arguments(n, "wrong_type", format!("{n}: must be true or false")));
            }
        }
        Kind::Date | Kind::Time | Kind::Duration => {
            let Some(s) = v.as_str() else { return Err(bad_arguments(n, "wrong_type", format!("{n}: must be a string"))) };
            let (ok, what) = match f.kind {
                Kind::Date => (valid_date(s), "a date written YYYY-MM-DD"),
                Kind::Time => (valid_time(s), "a time written HH:MM (24-hour)"),
                _ => (valid_duration(s), "an ISO 8601 duration of whole numbers, such as PT20M or P2D"),
            };
            if !ok {
                return Err(bad_arguments(n, "bad_format", format!("{n}: must be {what}")));
            }
        }
        Kind::Place => {
            let Some(s) = v.as_str() else { return Err(bad_arguments(n, "wrong_type", format!("{n}: must be a string"))) };
            if s.chars().count() > MAX_PLACE_CHARS {
                return Err(bad_arguments(n, "too_long", format!("{n}: must be at most {MAX_PLACE_CHARS} characters")));
            }
        }
    }
    Ok(())
}

/// The fields the call gives, validated, in the definition's order, `null`s dropped.
pub fn check<'a>(def: &'a ActionDef, fields: &'a Map<String, Value>) -> Result<Vec<(&'a FieldDef, &'a Value)>, ToolError> {
    for k in fields.keys() {
        if def.field(k).is_none() {
            return Err(bad_arguments(k, "unknown_field", format!("{k}: not allowed")));
        }
    }
    for r in &def.required {
        let missing = match given(fields, r) {
            None => true,
            Some(v) => {
                let textual = matches!(def.field(r).map(|f| &f.kind), Some(Kind::Str { .. }) | Some(Kind::Place));
                textual && blank(v)
            }
        };
        if missing {
            return Err(bad_arguments(r, "missing", format!("{r}: required")));
        }
    }
    let mut out = Vec::new();
    for f in &def.fields {
        if let Some(v) = given(fields, &f.name) {
            check_value(f, v)?;
            out.push((f, v));
        }
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dates() {
        for ok in ["2026-10-29", "2024-02-29", "2000-02-29", "0001-01-01"] {
            assert!(valid_date(ok), "{ok}");
        }
        for bad in ["2026-02-30", "2025-02-29", "1900-02-29", "2026-13-01", "2026-00-10", "2026-10-00", "2026-1-01", "26-10-29", "2026/10/29", "2026-10-29 ", "", "abcd-ef-gh"] {
            assert!(!valid_date(bad), "{bad}");
        }
    }

    #[test]
    fn times() {
        for ok in ["00:00", "23:59", "07:05"] {
            assert!(valid_time(ok), "{ok}");
        }
        for bad in ["24:00", "12:60", "7:05", "07:5", "07-05", "0705", "12:00:00", "", "ab:cd"] {
            assert!(!valid_time(bad), "{bad}");
        }
    }

    #[test]
    fn durations() {
        for ok in ["PT20M", "P2D", "P1Y2M3DT4H5M6S", "PT0S", "P1W", "PT1H30M", "P1DT12H"] {
            assert!(valid_duration(ok), "{ok}");
        }
        for bad in ["P", "PT", "P1DT", "20M", "PT1.5H", "PT-5M", "P1H", "PT1D", "P2D1Y", "PT5M1H", "pt20m", "P1D2", "", "PTM"] {
            assert!(!valid_duration(bad), "{bad}");
        }
    }
}
