//! Opening hours: whether a place is open at the tool's `now`, from its OSM `opening_hours` string (docs/TOOLS.md, "Place
//! details"). Only a small machine-format subset is read; anything else is "Hours not understood", and the raw string is
//! still shown beside it.
//!
//! The subset: `24/7`, or rules separated by `;`, each an optional day selector (`Mo`..`Su`, ranges with wrap-around,
//! lists, mixes) then `off`/`closed` or time spans `HH:MM-HH:MM` separated by `,`. A later rule replaces earlier ones for the
//! days it names; a span past midnight belongs to the day it starts on. Times are the phone's local wall clock.

const DAYS: [&str; 7] = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"];
const DAY_NAMES: [&str; 7] = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"];
const DAY_MIN: i64 = 1440;
const WEEK_MIN: i64 = 7 * DAY_MIN;

/// `open_status` for a place with these hours (None: the place has none), at `now` (ISO 8601, local time with offset).
pub fn open_status(hours: Option<&str>, now: &str) -> String {
    let Some(h) = hours.map(str::trim).filter(|h| !h.is_empty()) else { return "Hours not known".into() };
    let (Some(week), Some((day, minute))) = (parse(h), local_time(now)) else { return "Hours not understood".into() };
    status(&week, day, minute)
}

/// The top-level `hours_note`, with the map region's age in the words of `map_region_age` ("3 weeks old"); without it when
/// the age is not known.
pub fn hours_note(map_region_age: Option<&str>) -> String {
    match map_region_age.map(str::trim).filter(|a| !a.is_empty() && *a != "unknown") {
        Some(age) => format!("Opening hours come from the map data ({age}) and can be wrong, especially on holidays."),
        None => "Opening hours come from the map data and can be wrong, especially on holidays.".into(),
    }
}

/// Each weekday's (Monday first) open spans in minutes from that day's midnight; an end past 1440 runs into the next day.
type Week = [Vec<(i64, i64)>; 7];

fn parse(s: &str) -> Option<Week> {
    if s == "24/7" {
        return Some(std::array::from_fn(|_| vec![(0, DAY_MIN)]));
    }
    let mut week: Week = Default::default();
    for rule in s.split(';') {
        let rule: String = rule.chars().filter(|c| !c.is_whitespace()).collect();
        if rule.is_empty() {
            continue;
        }
        let (days, rest) = day_selector(&rule)?;
        let spans = if rest == "off" || rest == "closed" {
            Vec::new()
        } else {
            rest.split(',').map(span).collect::<Option<Vec<_>>>()?
        };
        for (d, on) in days.iter().enumerate() {
            if *on {
                week[d] = spans.clone();
            }
        }
    }
    Some(week)
}

/// The days a rule names and the rest of the rule; every day when it has no selector.
fn day_selector(rule: &str) -> Option<([bool; 7], &str)> {
    let day_at = |s: &str| DAYS.iter().position(|d| s.starts_with(d));
    if day_at(rule).is_none() {
        return Some(([true; 7], rule));
    }
    let mut days = [false; 7];
    let mut s = rule;
    loop {
        let a = day_at(s)?;
        s = &s[2..];
        let b = match s.strip_prefix('-') {
            Some(t) => {
                let b = day_at(t)?;
                s = &t[2..];
                b
            }
            None => a,
        };
        let mut d = a;
        loop {
            days[d] = true;
            if d == b {
                break;
            }
            d = (d + 1) % 7;
        }
        match s.strip_prefix(',') {
            Some(t) if day_at(t).is_some() => s = t,
            _ => break,
        }
    }
    Some((days, s))
}

/// `HH:MM-HH:MM` as minutes from midnight; an end at or before the start runs into the next day.
fn span(s: &str) -> Option<(i64, i64)> {
    let (a, b) = s.split_once('-')?;
    let (start, end) = (clock(a)?, clock(b)?);
    if start >= DAY_MIN {
        return None;
    }
    Some((start, if end <= start { end + DAY_MIN } else { end }))
}

/// `HH:MM` (two digits each, 00:00 to 24:00) as minutes.
fn clock(s: &str) -> Option<i64> {
    let (h, m) = s.split_once(':')?;
    if h.len() != 2 || m.len() != 2 || !h.bytes().chain(m.bytes()).all(|c| c.is_ascii_digit()) {
        return None;
    }
    let (h, m): (i64, i64) = (h.parse().ok()?, m.parse().ok()?);
    (m < 60 && (h < 24 || (h == 24 && m == 0))).then_some(h * 60 + m)
}

/// The weekday (Monday 0) and the minute of the day of `now`'s local wall clock.
fn local_time(now: &str) -> Option<(usize, i64)> {
    let b = now.trim().as_bytes();
    let num = |r: std::ops::Range<usize>| -> Option<i64> {
        let s = std::str::from_utf8(b.get(r)?).ok()?;
        s.bytes().all(|c| c.is_ascii_digit()).then(|| s.parse().ok())?
    };
    if b.len() < 16 || b[4] != b'-' || b[7] != b'-' || !matches!(b[10], b'T' | b't' | b' ') || b[13] != b':' {
        return None;
    }
    let (y, mo, d, h, mi) = (num(0..4)?, num(5..7)?, num(8..10)?, num(11..13)?, num(14..16)?);
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 {
        return None;
    }
    // days since 1970-01-01 (a Thursday), by the civil-calendar formula
    let y = if mo <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * ((mo + 9) % 12) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146097 + doe - 719468;
    Some(((days + 3).rem_euclid(7) as usize, h * 60 + mi))
}

fn status(week: &Week, today: usize, now: i64) -> String {
    // Every span from yesterday (it may run past midnight) to a week ahead, in minutes from today's midnight, touching ones joined.
    let mut spans: Vec<(i64, i64)> = (-1..=8i64)
        .flat_map(|k| week[(today as i64 + k).rem_euclid(7) as usize].iter().map(move |&(s, e)| (k * DAY_MIN + s, k * DAY_MIN + e)))
        .collect();
    spans.sort();
    let mut joined: Vec<(i64, i64)> = Vec::new();
    for (s, e) in spans {
        match joined.last_mut() {
            Some(last) if s <= last.1 => last.1 = last.1.max(e),
            _ => joined.push((s, e)),
        }
    }
    let at = |t: i64| {
        let day = t.div_euclid(DAY_MIN);
        let clock = format!("{:02}:{:02}", t.rem_euclid(DAY_MIN) / 60, t.rem_euclid(60));
        if day == 0 {
            clock
        } else {
            format!("{} {clock}", DAY_NAMES[(today as i64 + day).rem_euclid(7) as usize])
        }
    };
    if let Some(&(_, end)) = joined.iter().find(|(s, e)| *s <= now && now < *e) {
        return if end - now >= WEEK_MIN {
            "Open now (open 24 hours)".into()
        } else if end == DAY_MIN {
            // tonight's 24:00 (00:00 tomorrow); a later midnight keeps its day ("closes Sat 00:00")
            "Open now (closes at midnight)".into()
        } else {
            format!("Open now (closes {})", at(end))
        };
    }
    match joined.iter().find(|(s, _)| *s > now && *s - now <= WEEK_MIN) {
        Some(&(start, _)) => format!("Closed now (opens {})", at(start)),
        None => "Closed now".into(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Thu 2026-10-29, the spec's golden "now", at other times of the week.
    const THU_1430: &str = "2026-10-29T14:30:00-06:00";
    const THU_1900: &str = "2026-10-29T19:00:00-06:00";
    const THU_0600: &str = "2026-10-29T06:00:00-06:00";
    const THU_2300: &str = "2026-10-29T23:00:00-06:00";
    const FRI_0100: &str = "2026-10-30T01:00:00-06:00";
    const SAT_1300: &str = "2026-10-31T13:00:00-06:00";

    fn st(h: &str, now: &str) -> String {
        open_status(Some(h), now)
    }

    #[test]
    fn golden_examples() {
        let h = "Mo-Fr 08:00-18:00; Sa 09:00-12:00";
        assert_eq!(st(h, THU_1430), "Open now (closes 18:00)");
        assert_eq!(st(h, THU_1900), "Closed now (opens Fri 08:00)");
        assert_eq!(st(h, THU_0600), "Closed now (opens 08:00)");
        assert_eq!(st(h, SAT_1300), "Closed now (opens Mon 08:00)");
        assert_eq!(st("24/7", THU_1430), "Open now (open 24 hours)");
        assert_eq!(st("Mo-Su 17:00-02:00", FRI_0100), "Open now (closes 02:00)");
        assert_eq!(st("Mo-Su 17:00-02:00", THU_2300), "Open now (closes Fri 02:00)");
        assert_eq!(st("Mo-Fr 08:00-17:00; PH off", THU_1430), "Hours not understood");
        assert_eq!(open_status(None, THU_1430), "Hours not known");
    }

    #[test]
    fn the_week_is_read_from_now() {
        assert_eq!(local_time(THU_1430), Some((3, 870)));
        assert_eq!(local_time("2026-10-25T14:20:05-06:00"), Some((6, 860)));
        assert_eq!(local_time("2024-02-29T00:00:00Z"), Some((3, 0)));
        assert_eq!(local_time("2000-01-01T23:59:00+09:00"), Some((5, 1439)));
        assert_eq!(local_time("2026-10-29"), None);
        assert_eq!(local_time("not a time"), None);
        assert_eq!(open_status(Some("24/7"), "garbage"), "Hours not understood");
    }

    #[test]
    fn day_selectors() {
        // a range that wraps, a list, and a mix
        assert_eq!(st("Sa-Mo 10:00-16:00", SAT_1300), "Open now (closes 16:00)");
        assert_eq!(st("Sa-Mo 10:00-16:00", THU_1430), "Closed now (opens Sat 10:00)");
        assert_eq!(st("Mo,We,Fr 09:00-12:00", THU_1430), "Closed now (opens Fri 09:00)");
        assert_eq!(st("Mo-We,Su 09:00-12:00", THU_1430), "Closed now (opens Sun 09:00)");
        assert_eq!(st("Th 09:00-17:00", THU_1430), "Open now (closes 17:00)");
        // no selector is every day; whitespace around tokens does not matter
        assert_eq!(st("09:00-17:00", SAT_1300), "Open now (closes 17:00)");
        assert_eq!(st(" Mo - Fr  08:00 - 18:00 ;Sa 09:00-12:00 ", THU_1430), "Open now (closes 18:00)");
        // lower-case day names are not the format
        assert_eq!(st("mo-fr 08:00-18:00", THU_1430), "Hours not understood");
    }

    #[test]
    fn later_rules_replace_earlier_ones_for_their_days() {
        assert_eq!(st("Mo-Fr 08:00-18:00; Th off", THU_1430), "Closed now (opens Fri 08:00)");
        assert_eq!(st("Mo-Fr 08:00-18:00; Th closed", THU_1430), "Closed now (opens Fri 08:00)");
        assert_eq!(st("Mo-Fr 08:00-18:00; Th 10:00-14:00", THU_1430), "Closed now (opens Fri 08:00)");
        // a span past midnight belongs to the day it starts on
        let h = "Mo-Su 17:00-02:00; Fr off";
        assert_eq!(st(h, FRI_0100), "Open now (closes 02:00)");
        assert_eq!(st(h, THU_2300), "Open now (closes Fri 02:00)");
        assert_eq!(st(h, "2026-10-30T18:00:00-06:00"), "Closed now (opens Sat 17:00)");
    }

    #[test]
    fn spans_join_and_open_without_a_break_is_24_hours() {
        assert_eq!(st("08:00-12:00,12:00-18:00", THU_1430), "Open now (closes 18:00)");
        assert_eq!(st("08:00-12:00,13:00-18:00", "2026-10-29T12:30:00-06:00"), "Closed now (opens 13:00)");
        assert_eq!(st("Mo-Su 00:00-24:00", THU_1430), "Open now (open 24 hours)");
        assert_eq!(st("Mo-Fr 00:00-24:00", THU_1430), "Open now (closes Sat 00:00)");
        assert_eq!(st("Mo-Fr 08:00-24:00", THU_2300), "Open now (closes at midnight)");
        assert_eq!(st("Mo-Fr 22:00-02:00", THU_2300), "Open now (closes Fri 02:00)");
    }

    #[test]
    fn midnight_closing_and_opening() {
        // closing at 24:00, or at 00:00 the next day, is "at midnight"; opening at 00:00 on another day keeps the day
        assert_eq!(st("Mo-Su 18:00-24:00", THU_2300), "Open now (closes at midnight)");
        assert_eq!(st("Mo-Su 18:00-00:00", THU_2300), "Open now (closes at midnight)");
        assert_eq!(st("Mo-Su 18:00-24:00", THU_1430), "Closed now (opens 18:00)");
        assert_eq!(st("Fr 00:00-06:00", THU_1430), "Closed now (opens Fri 00:00)");
        assert_eq!(st("Fr 00:00-06:00", FRI_0100), "Open now (closes 06:00)");
    }

    #[test]
    fn closed_for_the_next_week() {
        assert_eq!(st("Mo-Su off", THU_1430), "Closed now");
        // next week's Thursday is within 7 days, and not today
        assert_eq!(st("Th 14:00-14:20", THU_1430), "Closed now (opens Thu 14:00)");
        assert_eq!(st("Th 14:00-14:40", THU_1430), "Open now (closes 14:40)");
    }

    #[test]
    fn anything_outside_the_subset_is_not_understood() {
        for h in [
            "Mo-Fr 08:00-17:00; PH off",
            "Mo-Fr 08:00-17:00; SH off",
            "Jan-Mar Mo-Fr 08:00-17:00",
            "week 1-53/2 Mo 08:00-12:00",
            "2026 Oct 29 off",
            "sunrise-sunset",
            "Mo-Fr 08:00+",
            "Mo-Fr 08:00-17:00 \"by appointment\"",
            "Mo-Fr 8:00-17:00",
            "Mo-Fr 08:00-25:00",
            "Mo-Fr 08:60-17:00",
            "Mo Fr 08:00-17:00",
            "Mo-Fr",
            "Mo-Fr 08:00-17:00, Sa 09:00-12:00",
            "open",
        ] {
            assert_eq!(st(h, THU_1430), "Hours not understood", "{h}");
        }
        assert_eq!(open_status(Some("   "), THU_1430), "Hours not known");
    }

    #[test]
    fn the_note_carries_the_map_age_when_known() {
        assert_eq!(hours_note(Some("3 weeks old")), "Opening hours come from the map data (3 weeks old) and can be wrong, especially on holidays.");
        assert_eq!(hours_note(Some("unknown")), "Opening hours come from the map data and can be wrong, especially on holidays.");
        assert_eq!(hours_note(None), "Opening hours come from the map data and can be wrong, especially on holidays.");
    }
}
