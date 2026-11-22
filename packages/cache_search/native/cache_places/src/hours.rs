//! Readable opening hours: a place's OSM `opening_hours` value as a week the app can show and evaluate.
//!
//! The value is parsed and evaluated by the `opening-hours` crate. This module answers only what it can answer without
//! guessing, so the card never shows a wrong "Open now". A value is **readable** when it is a plain weekly pattern: weekday
//! ranges and times, with `off`/`closed` overrides, and nothing else. Anything that needs more than the weekday and the time
//! of day is **raw** (the card shows the value as it is, and no Open/Closed): public and school holidays (`PH`, `SH`), sun
//! events (`sunrise`, `sunset`, `dawn`, `dusk`), months, dates, years, week numbers, "the 2nd Monday", open-ended times
//! (`10:00+`), times that repeat, comments, "unknown", and `||` fallbacks. The crate itself would answer some of these with
//! stand-ins (a fixed 7:00 sunrise and 19:00 sunset when it is given no position), which is why they are refused here.
//!
//! The week is `[Mon, Tue, ..., Sun]`, each day the open ranges that START that day as `[start, end]` in minutes from that
//! day's midnight. `end` is more than 1440 when the range runs past midnight (`Fr 18:00-02:00` is Friday `[1080, 1560]`).
//!
//! The place's time zone comes from its position, offline (the same boundary data the weather uses): `zone_at`.

use chrono::{NaiveDate, Offset, TimeZone};
use opening_hours::OpeningHours;
use opening_hours_syntax::rules::day::WeekDayRange;
use opening_hours_syntax::rules::time::Time;
use opening_hours_syntax::rules::{RuleKind, RuleOperator};
use serde_json::{json, Value};
use std::sync::OnceLock;

/// Why a value is shown as it is, not as a week.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub enum Why {
    /// Not valid `opening_hours` (the parser refused it).
    Syntax,
    /// `PH` or `SH`: a holiday calendar is needed.
    Holiday,
    /// `sunrise`, `sunset`, `dawn` or `dusk`: the place's position and the date are needed.
    SunEvent,
    /// A month, a date, a year or a week number: the answer depends on the date.
    Seasonal,
    /// A weekday of the month ("Su[1]") or a day offset.
    NthWeekday,
    /// A quoted comment ("by appointment").
    Comment,
    /// `unknown`: the value itself does not know.
    Unknown,
    /// `10:00+`: no closing time.
    OpenEnd,
    /// `||`: a fallback for when the rule before it does not apply.
    Fallback,
    /// A time that repeats (`10:00-12:00/00:30`).
    Repeat,
    /// Parses, but is never open (`off`, `closed`).
    NeverOpen,
    /// A range that runs past midnight, and nothing before it to run on from (a later rule took the day it starts on).
    OvernightOverridden,
}

impl Why {
    pub fn label(self) -> &'static str {
        match self {
            Why::Syntax => "not valid opening_hours syntax",
            Why::Holiday => "public/school holidays (PH, SH)",
            Why::SunEvent => "sunrise/sunset/dawn/dusk",
            Why::Seasonal => "months, dates, years or week numbers",
            Why::NthWeekday => "nth weekday of the month or day offsets",
            Why::Comment => "comment text",
            Why::Unknown => "unknown state",
            Why::OpenEnd => "open-ended time (10:00+)",
            Why::Fallback => "|| fallback rule",
            Why::Repeat => "repeating times",
            Why::NeverOpen => "never open (off/closed only)",
            Why::OvernightOverridden => "overnight range with no start to run on from",
        }
    }
}

/// The open ranges of the seven days, Monday first (see the module documentation).
pub type Week = [Vec<[u16; 2]>; 7];

/// A value read as a week. `exact` is false when the week is what the value says but the crate's own answer for the hours just
/// after midnight differs from it (see [`Why::OvernightOverridden`]): the card shows the week and does not say Open or Closed.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reading {
    pub week: Week,
    pub exact: bool,
}

/// The value parsed. The crate's grammar wants a space after the comma that separates two rules ("Mo-Fr 09:00-17:00,Sa 10:00-12:00"
/// is refused, "..., Sa ..." is read), though the specification does not: when it refuses, the value is tried once more with a
/// space after every comma that is followed by a letter. White space between tokens carries no meaning, so a value that then
/// parses means what it says.
fn parse(raw: &str) -> Result<OpeningHours, Why> {
    let raw = raw.trim();
    if let Ok(oh) = raw.parse::<OpeningHours>() {
        return Ok(oh);
    }
    let mut spaced = String::with_capacity(raw.len() + 4);
    let mut chars = raw.chars().peekable();
    while let Some(c) = chars.next() {
        spaced.push(c);
        if c == ',' && chars.peek().is_some_and(|n| n.is_ascii_alphabetic()) {
            spaced.push(' ');
        }
    }
    spaced.parse::<OpeningHours>().map_err(|_| Why::Syntax)
}

/// A value read as a plain weekly pattern, or the first reason it is not one.
pub fn analyze(raw: &str) -> Result<Reading, Why> {
    let oh = parse(raw)?;
    let expr = oh.get_expression();
    // The worst reason over the rules, in the order of the enum, so the same value always reports the same one.
    let mut worst: Option<Why> = None;
    let mut note = |w: Why| worst = Some(worst.map_or(w, |o| o.min(w)));
    for r in &expr.rules {
        let d = &r.day_selector;
        if !d.year.is_empty() || !d.monthday.is_empty() || !d.week.is_empty() {
            note(Why::Seasonal);
        }
        for w in &d.weekday {
            match w {
                WeekDayRange::Holiday { .. } => note(Why::Holiday),
                WeekDayRange::Fixed { offset, nth_from_start, nth_from_end, .. } => {
                    if *offset != 0 || nth_from_start.contains(&false) || nth_from_end.contains(&false) {
                        note(Why::NthWeekday);
                    }
                }
            }
        }
        for s in &r.time_selector.spans {
            if matches!(s.range.start, Time::Variable(_)) || matches!(s.range.end, Time::Variable(_)) {
                note(Why::SunEvent);
            }
            if s.open_end {
                note(Why::OpenEnd);
            }
            if s.repeats.is_some() {
                note(Why::Repeat);
            }
        }
        if !r.comment.is_empty() {
            note(Why::Comment);
        }
        if r.kind == RuleKind::Unknown {
            note(Why::Unknown);
        }
        if r.operator == RuleOperator::Fallback {
            note(Why::Fallback);
        }
    }
    if let Some(w) = worst {
        return Err(w);
    }
    // Every rule is a weekday and a time of day, so every week is the same: read one (2026-01-05 is a Monday).
    let monday = NaiveDate::from_ymd_opt(2026, 1, 5).ok_or(Why::Syntax)?;
    let mut tails = [0u16; 7];
    for r in &expr.rules {
        // "18:00-02:00" (the end is before the start) and "18:00-26:00" both end the next morning.
        let over = r.time_selector.spans.iter().filter_map(|s| match (s.range.start, s.range.end) {
            (Time::Fixed(_), Time::Fixed(b)) if b.mins_from_midnight() > 1440 => Some(b.mins_from_midnight() - 1440),
            (Time::Fixed(a), Time::Fixed(b)) if b.mins_from_midnight() < a.mins_from_midnight() => Some(b.mins_from_midnight()),
            _ => None,
        });
        let Some(over) = over.max() else { continue };
        let mut starts = [false; 7];
        if r.day_selector.weekday.is_empty() {
            starts = [true; 7];
        }
        for w in &r.day_selector.weekday {
            if let WeekDayRange::Fixed { range, .. } = w {
                let mut d = *range.start();
                loop {
                    starts[d.num_days_from_monday() as usize] = true;
                    if d == *range.end() {
                        break;
                    }
                    d = d.succ();
                }
            }
        }
        for (i, on) in starts.iter().enumerate() {
            if *on {
                let next = (i + 1) % 7;
                tails[next] = tails[next].max(over);
            }
        }
    }
    let mut week: Week = Default::default();
    for (i, day) in week.iter_mut().enumerate() {
        let date = monday + chrono::Days::new(i as u64);
        let mut ranges: Vec<[u16; 2]> = Vec::new();
        for tr in oh.schedule_at(date).into_iter() {
            match tr.kind {
                RuleKind::Open => {
                    let (s, e) = (tr.range.start.mins_from_midnight(), tr.range.end.mins_from_midnight());
                    match ranges.last_mut() {
                        Some(last) if last[1] >= s => last[1] = last[1].max(e),
                        _ => ranges.push([s, e]),
                    }
                }
                RuleKind::Unknown => return Err(Why::Unknown),
                RuleKind::Closed => {}
            }
        }
        *day = ranges;
    }
    if week.iter().all(|d| d.is_empty()) {
        return Err(Why::NeverOpen);
    }
    // A range that runs past midnight must show up as the start of the next day. The crate drops it when a later rule sets that
    // day ("Fr-Sa 10:30-01:00; Su 10:30-24:00"). The value still says the night runs on, so the week gets it back (the card shows
    // what the value says), but the hours just after midnight are then not something to answer: `exact` is false. When the day
    // before has no range to run on from, nothing says what the value means, and it stays raw.
    let mut exact = true;
    for (i, t) in tails.iter().enumerate() {
        if *t == 0 {
            continue;
        }
        if !week[i].first().is_some_and(|f| f[0] == 0 && f[1] >= *t) {
            match week[i].first_mut() {
                Some(f) if f[0] == 0 => f[1] = f[1].max(*t),
                _ => week[i].insert(0, [0, *t]),
            }
            exact = false;
        }
    }
    // The night must have a range of the day before to run on from (join_overnight takes it in); otherwise nothing says what the
    // value means ("Mo-Su 18:00-02:00; Fr off": the crate keeps Friday's morning tail with no Friday evening).
    for (i, t) in tails.iter().enumerate() {
        let prev = (i + 6) % 7;
        if *t > 0 && !week[prev].last().is_some_and(|l| l[1] == 1440 && l[0] > 0) {
            return Err(Why::OvernightOverridden);
        }
    }
    Ok(Reading { week: join_overnight(week), exact })
}

/// The crate gives each day the part of its ranges that lies in that day: `Fr 18:00-02:00` is Friday 18:00-24:00 and Saturday
/// 00:00-02:00. The card shows it as one range that starts Friday, so a range that ends at midnight takes on the next day's
/// range that starts at midnight (the week wraps: Sunday's runs into Monday's). A day that is open all day is not joined.
fn join_overnight(read: Week) -> Week {
    let mut out = read.clone();
    for i in 0..7 {
        let next = (i + 1) % 7;
        let (Some(last), Some(first)) = (read[i].last().copied(), read[next].first().copied()) else { continue };
        if last[1] == 1440 && last[0] > 0 && first[0] == 0 && first[1] < 1440 {
            if let Some(l) = out[i].last_mut() {
                l[1] = 1440 + first[1];
            }
            out[next].remove(0);
        }
    }
    out
}

/// The week as JSON for the card: `[[[540,1140]], ..., []]`.
pub fn week_json(week: &Week) -> Value {
    json!(week)
}

fn finder() -> &'static tzf_rs::EmbeddedFinder {
    static FINDER: OnceLock<tzf_rs::EmbeddedFinder> = OnceLock::new();
    FINDER.get_or_init(tzf_rs::EmbeddedFinder::new)
}

/// The IANA zone of a position, from the embedded boundaries (offline). `None` where none is known.
pub fn zone_name_at(lat: f64, lon: f64) -> Option<&'static str> {
    let name = finder().get_tz_name(lon, lat);
    if name.is_empty() {
        return None;
    }
    name.parse::<chrono_tz::Tz>().ok().map(|t| t.name())
}

/// The zone of a position and its offset from UTC, in minutes, at Unix time `now` (daylight saving included).
pub fn zone_at(lat: f64, lon: f64, now: i64) -> Option<(&'static str, i32)> {
    let name = zone_name_at(lat, lon)?;
    let tz: chrono_tz::Tz = name.parse().ok()?;
    let off = tz.timestamp_opt(now, 0).single()?.offset().fix().local_minus_utc();
    Some((name, off / 60))
}

/// What a place's JSON gets for its hours: `hours_week` and `hours_exact` when the value is a plain weekly pattern, and `timezone` and
/// `utc_offset_min` (at `now`) when the zone of its position is known. Nothing when the value is raw.
pub fn card_fields(raw: &str, lat: f64, lon: f64, now: i64) -> Option<Vec<(&'static str, Value)>> {
    let r = analyze(raw).ok()?;
    let mut out = vec![("hours_week", week_json(&r.week)), ("hours_exact", json!(r.exact))];
    if let Some((name, off)) = zone_at(lat, lon, now) {
        out.push(("timezone", json!(name)));
        out.push(("utc_offset_min", json!(off)));
    }
    Some(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn week(raw: &str) -> Week {
        analyze(raw).unwrap_or_else(|w| panic!("{raw:?} is raw: {w:?}")).week
    }

    #[test]
    fn plain_weeks() {
        let w = week("Mo-Fr 09:00-19:00, Sa 10:00-17:00");
        for d in &w[..5] {
            assert_eq!(d, &vec![[540, 1140]]);
        }
        assert_eq!(w[5], vec![[600, 1020]]);
        assert!(w[6].is_empty());
        let all = week("24/7");
        assert!(all.iter().all(|d| d == &vec![[0u16, 1440]]));
        let split = week("Mo-Fr 08:00-12:00,13:00-17:00");
        assert_eq!(split[0], vec![[480, 720], [780, 1020]]);
        // No days: every day.
        assert!(week("08:00-21:00").iter().all(|d| d == &vec![[480u16, 1260]]));
    }

    #[test]
    fn overrides_and_overnight() {
        let w = week("Mo-Su 09:00-17:00; Su off");
        assert!(w[6].is_empty());
        assert_eq!(w[0], vec![[540, 1020]]);
        let n = week("Fr-Sa 18:00-02:00");
        assert_eq!(n[4], vec![[1080, 1560]]);
        assert_eq!(n[5], vec![[1080, 1560]]);
        assert!(n[0].is_empty() && n[6].is_empty() && n[3].is_empty());
        // Every night, Sunday's runs into Monday morning.
        let every = week("Mo-Su 18:00-02:00");
        assert!(every.iter().all(|d| d == &vec![[1080u16, 1560]]));
        // A later rule that takes the next day drops the night in the crate; the week keeps it, and says it is not exact.
        let r = analyze("Mo-Th 10:30-24:00; Fr-Sa 10:30-01:00; Su 10:30-24:00").unwrap();
        assert!(!r.exact);
        assert_eq!(r.week[4], vec![[630, 1500]]);
        assert_eq!(r.week[5], vec![[630, 1500]]);
        assert_eq!(r.week[6], vec![[630, 1440]]);
        assert!(analyze("Mo-Fr 18:00-02:00; Su 10:00-12:00").unwrap().exact);
        // A later rule that leaves the night alone keeps it.
        assert_eq!(week("Mo-Fr 18:00-02:00; Su 10:00-12:00")[4], vec![[1080, 1560]]);
    }

    #[test]
    fn raw_values_say_why() {
        assert_eq!(analyze("sunrise-sunset"), Err(Why::SunEvent));
        assert_eq!(analyze("Mo-Fr 09:00-17:00; PH off"), Err(Why::Holiday));
        assert_eq!(analyze("Apr-Oct Mo-Su 09:00-17:00"), Err(Why::Seasonal));
        assert_eq!(analyze("Mo-Fr 09:00-17:00 \"by appointment\""), Err(Why::Comment));
        assert_eq!(analyze("Mo-Fr 10:00+"), Err(Why::OpenEnd));
        assert_eq!(analyze("Su[1] 09:00-12:00"), Err(Why::NthWeekday));
        assert_eq!(analyze("call us any time"), Err(Why::Syntax));
        // A rule separator without a space is read the way the specification reads it.
        assert_eq!(week("Mo-Fr 08:30-17:30,Sa 08:30-13:00")[5], vec![[510, 780]]);
        assert_eq!(analyze("off"), Err(Why::NeverOpen));
        assert_eq!(analyze("Mo-Su 18:00-02:00; Fr off"), Err(Why::OvernightOverridden));
        assert_eq!(analyze("Mo-Fr 09:00-17:00 unknown"), Err(Why::Unknown));
    }

    #[test]
    fn zone_of_a_position() {
        let (n, o) = zone_at(43.615, -116.202, 1_784_000_000).unwrap(); // Boise, July 2026: MDT
        assert_eq!((n, o), ("America/Boise", -360));
        let (_, o) = zone_at(43.615, -116.202, 1_800_000_000).unwrap(); // January 2027: MST
        assert_eq!(o, -420);
        // North Idaho is on Pacific time.
        assert_eq!(zone_name_at(47.68, -116.78), Some("America/Los_Angeles"));
    }
}
