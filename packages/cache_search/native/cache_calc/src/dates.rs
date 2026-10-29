//! The date layer in front of fend (docs/TOOLS.md, calculate). It answers three machine-syntax forms only: `<date> - <date>`
//! (days between), `<date> + <n> days|weeks` or `<date> - <n> days|weeks` (a date), and a lone `<date>` (its weekday). A
//! date is `YYYY-MM-DD` or `today`, the date part of the tool's `now`. Any other expression with a date in it fails; an
//! expression without one is left to fend.

/// The failure detail for an expression that has a date but is none of the forms.
pub const DATE_FORMS: &str =
    "dates work only as date - date, or date + or - a whole number of days or weeks; write dates as YYYY-MM-DD or today";
/// The failure detail for `today` when `now` has no readable date (fend's own wording for the date it can't get).
pub const NO_TODAY: &str = "unable to get the current date";

const WEEKDAYS: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];

/// What the layer made of an expression.
#[derive(Debug, PartialEq)]
pub enum Outcome {
    /// No date in it: fend evaluates it.
    NotDates,
    /// The result string, and today's date when `today` was used (for the assumption line).
    Done { result: String, today: Option<String> },
    /// `calc_failed` with this detail.
    Failed(&'static str),
}

#[derive(Debug, Clone, Copy, PartialEq)]
enum Tok {
    /// Days since 1970-01-01, and whether it was `today`.
    Date(i64, bool),
    Num(i64),
    Plus,
    Minus,
    /// `day(s)` = 1, `week(s)` = 7.
    Unit(i64),
    /// Anything else, or a date that doesn't exist.
    Other,
    /// `today` with no readable `now`.
    NoToday,
}

fn is_name_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

/// A `YYYY-MM-DD` at `b[i..]`, not joined to a name, number or decimal point on either side: its year, month and day as
/// written (not checked against the calendar).
fn date_at(b: &[char], i: usize) -> Option<(i64, i64, i64)> {
    let shape = "dddd-dd-dd";
    if i + shape.len() > b.len() || (i > 0 && (is_name_char(b[i - 1]) || b[i - 1] == '.')) {
        return None;
    }
    for (k, s) in shape.chars().enumerate() {
        if (s == 'd' && !b[i + k].is_ascii_digit()) || (s == '-' && b[i + k] != '-') {
            return None;
        }
    }
    if let Some(&c) = b.get(i + shape.len()) {
        if is_name_char(c) || c == '.' {
            return None;
        }
    }
    let num = |a: usize, z: usize| b[i + a..i + z].iter().collect::<String>().parse::<i64>().unwrap();
    Some((num(0, 4), num(5, 7), num(8, 10)))
}

fn leap(y: i64) -> bool {
    (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
}

/// Days since 1970-01-01 of a real date in years 0001-9999.
fn days_of(y: i64, m: i64, d: i64) -> Option<i64> {
    let month_len = [31, if leap(y) { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if !(1..=9999).contains(&y) || !(1..=12).contains(&m) || d < 1 || d > month_len[(m - 1) as usize] {
        return None;
    }
    // Days from civil (proleptic Gregorian), with the year starting in March.
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    Some(era * 146097 + doe - 719468)
}

/// `YYYY-MM-DD (Thu)` for days since 1970-01-01, or None outside years 0001-9999.
fn format_day(z: i64) -> Option<String> {
    if z < days_of(1, 1, 1)? || z > days_of(9999, 12, 31)? {
        return None;
    }
    let z2 = z + 719468;
    let era = z2.div_euclid(146097);
    let doe = z2 - era * 146097;
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = yoe + era * 400 + if m <= 2 { 1 } else { 0 };
    // 1970-01-01 was a Thursday.
    let wd = WEEKDAYS[(z + 3).rem_euclid(7) as usize];
    Some(format!("{y:04}-{m:02}-{d:02} ({wd})"))
}

/// Today's date from `now` (ISO 8601, the phone's local time): its leading `YYYY-MM-DD`, followed by nothing, a `T` or a
/// space.
fn today_of(now: &str) -> Option<(i64, String)> {
    let b: Vec<char> = now.trim().chars().collect();
    if b.get(10).is_some_and(|c| *c != 'T' && *c != ' ') {
        return None;
    }
    let (y, m, d) = date_at(&b[..b.len().min(10)], 0)?;
    let z = days_of(y, m, d)?;
    Some((z, format!("{y:04}-{m:02}-{d:02}")))
}

/// The expression as tokens, or None when it has no date in it at all.
fn tokens(expression: &str, now: &str) -> Option<Vec<Tok>> {
    let b: Vec<char> = expression.chars().collect();
    let mut out = Vec::new();
    let mut has_date = false;
    let mut i = 0;
    while i < b.len() {
        let c = b[i];
        if c.is_whitespace() {
            i += 1;
        } else if let Some((y, m, d)) = date_at(&b, i) {
            has_date = true;
            out.push(days_of(y, m, d).map_or(Tok::Other, |z| Tok::Date(z, false)));
            i += 10;
        } else if c.is_ascii_digit() {
            let mut j = i;
            while j < b.len() && b[j].is_ascii_digit() {
                j += 1;
            }
            let n = b[i..j].iter().collect::<String>().parse::<i64>().ok();
            // A number joined to a decimal point or a name ("1.5", "2x") is not a whole number of days, except a unit
            // written without a space ("30days"), which the name run after it picks up.
            let joined = b.get(j).is_some_and(|c| *c == '.');
            out.push(match n {
                Some(n) if !joined => Tok::Num(n),
                _ => Tok::Other,
            });
            i = j;
        } else if is_name_char(c) {
            let mut j = i;
            while j < b.len() && is_name_char(b[j]) {
                j += 1;
            }
            let word = b[i..j].iter().collect::<String>().to_lowercase();
            out.push(match word.as_str() {
                "today" => {
                    has_date = true;
                    today_of(now).map_or(Tok::NoToday, |(z, _)| Tok::Date(z, true))
                }
                "day" | "days" => Tok::Unit(1),
                "week" | "weeks" => Tok::Unit(7),
                _ => Tok::Other,
            });
            i = j;
        } else {
            out.push(match c {
                '+' => Tok::Plus,
                '-' => Tok::Minus,
                _ => Tok::Other,
            });
            i += 1;
        }
    }
    has_date.then_some(out)
}

/// `"N days"`, singular for 1 and -1.
fn days_text(n: i64) -> String {
    if n.abs() == 1 {
        format!("{n} day")
    } else {
        format!("{n} days")
    }
}

/// Runs the date layer on a trimmed expression, with `now` the tool's now.
pub fn evaluate(expression: &str, now: &str) -> Outcome {
    let Some(toks) = tokens(expression, now) else {
        return Outcome::NotDates;
    };
    if toks.contains(&Tok::NoToday) {
        return Outcome::Failed(NO_TODAY);
    }
    let used_today = toks.iter().any(|t| matches!(t, Tok::Date(_, true)));
    let result = match toks.as_slice() {
        [Tok::Date(a, _)] => format_day(*a),
        [Tok::Date(a, _), Tok::Minus, Tok::Date(b, _)] => Some(days_text(a - b)),
        [Tok::Date(a, _), op @ (Tok::Plus | Tok::Minus), Tok::Num(n), Tok::Unit(u)] => n
            .checked_mul(*u)
            .and_then(|d| if *op == Tok::Plus { a.checked_add(d) } else { a.checked_sub(d) })
            .and_then(format_day),
        _ => None,
    };
    match result {
        Some(result) => Outcome::Done { result, today: if used_today { today_of(now).map(|(_, s)| s) } else { None } },
        None => Outcome::Failed(DATE_FORMS),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const NOW: &str = "2026-10-29T14:30:00-06:00";

    fn done(result: &str, today: bool) -> Outcome {
        Outcome::Done { result: result.to_string(), today: today.then(|| "2026-10-29".to_string()) }
    }

    #[test]
    fn calendar_round_trip() {
        assert_eq!(days_of(1970, 1, 1), Some(0));
        assert_eq!(format_day(0).unwrap(), "1970-01-01 (Thu)");
        assert_eq!(format_day(days_of(1, 1, 1).unwrap()).unwrap(), "0001-01-01 (Mon)");
        assert_eq!(format_day(days_of(9999, 12, 31).unwrap()).unwrap(), "9999-12-31 (Fri)");
        assert_eq!(format_day(days_of(2000, 2, 29).unwrap()).unwrap(), "2000-02-29 (Tue)");
        assert_eq!(days_of(1900, 2, 29), None);
        assert_eq!(days_of(2026, 2, 30), None);
        assert_eq!(days_of(2026, 13, 1), None);
        assert_eq!(days_of(2026, 0, 1), None);
        assert_eq!(days_of(0, 1, 1), None);
        assert_eq!(format_day(days_of(1, 1, 1).unwrap() - 1), None);
        assert_eq!(format_day(days_of(9999, 12, 31).unwrap() + 1), None);
    }

    #[test]
    fn today_comes_from_now() {
        assert_eq!(today_of(NOW).unwrap().1, "2026-10-29");
        assert_eq!(today_of("2026-10-29").unwrap().1, "2026-10-29");
        assert_eq!(today_of("2026-10-29 14:30"), today_of(NOW));
        assert_eq!(today_of("n"), None);
        assert_eq!(today_of(""), None);
        assert_eq!(today_of("2026-02-30T00:00:00Z"), None);
        assert_eq!(today_of("2026-10-291"), None);
    }

    #[test]
    fn the_forms() {
        assert_eq!(evaluate("today - 2026-10-20", NOW), done("9 days", true));
        assert_eq!(evaluate("2026-10-20 - today", NOW), done("-9 days", true));
        assert_eq!(evaluate("today - today", NOW), done("0 days", true));
        assert_eq!(evaluate("2026-03-01 - 2026-02-28", NOW), done("1 day", false));
        assert_eq!(evaluate("2026-02-28 - 2026-03-01", NOW), done("-1 day", false));
        assert_eq!(evaluate("2026-10-29 + 2 weeks", NOW), done("2026-11-12 (Thu)", false));
        assert_eq!(evaluate("today + 30 days", NOW), done("2026-11-28 (Sat)", true));
        assert_eq!(evaluate("today - 1 week", NOW), done("2026-10-22 (Thu)", true));
        assert_eq!(evaluate("today + 1 day", NOW), done("2026-10-30 (Fri)", true));
        assert_eq!(evaluate("today + 0 days", NOW), done("2026-10-29 (Thu)", true));
        assert_eq!(evaluate("today", NOW), done("2026-10-29 (Thu)", true));
        assert_eq!(evaluate("2026-11-12", NOW), done("2026-11-12 (Thu)", false));
    }

    #[test]
    fn case_spacing_and_leading_zeros() {
        assert_eq!(evaluate("TODAY+30DAYS", NOW), done("2026-11-28 (Sat)", true));
        assert_eq!(evaluate("Today-2026-10-20", NOW), done("9 days", true));
        assert_eq!(evaluate("2026-10-29-2026-10-20", NOW), done("9 days", false));
        assert_eq!(evaluate("2026-10-29+2Weeks", NOW), done("2026-11-12 (Thu)", false));
        assert_eq!(evaluate("  2026-10-29   -   007   Day  ", NOW), done("2026-10-22 (Thu)", false));
    }

    #[test]
    fn everything_else_with_a_date_fails() {
        for e in [
            "today + 2026-10-20",
            "today * 2",
            "today + 1.5 days",
            "today + -3 days",
            "today - +3 days",
            "today + 3",
            "today + days",
            "today + 3 months",
            "today + 3 days + 1 day",
            "(today - 2026-10-20)",
            "today - 2026-10-20 to weeks",
            "2026-02-30",
            "2026-13-01 - today",
            "0000-01-01",
            "9999-12-31 + 1 day",
            "0001-01-01 - 1 day",
            "today + 99999999999999999999 days",
            "today + 9223372036854775807 weeks",
            "today + 9223372036854000000 days",
            "2 * 2026-10-20",
        ] {
            assert_eq!(evaluate(e, NOW), Outcome::Failed(DATE_FORMS), "{e:?}");
        }
    }

    #[test]
    fn no_date_is_left_to_fend() {
        for e in ["1 + 1", "todays + 1", "today_x", "12026-10-20", "2026-10-201", "1.2026-10-20", "2026-1-20", "5 days to hours"] {
            assert_eq!(evaluate(e, NOW), Outcome::NotDates, "{e:?}");
        }
    }

    #[test]
    fn today_without_a_readable_now() {
        assert_eq!(evaluate("today", "n"), Outcome::Failed(NO_TODAY));
        assert_eq!(evaluate("today * 2", ""), Outcome::Failed(NO_TODAY));
        // A plain date needs no now.
        assert_eq!(evaluate("2026-10-29 + 2 weeks", "n"), done("2026-11-12 (Thu)", false));
    }
}
