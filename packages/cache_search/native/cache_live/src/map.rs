//! The field mapping: a response tree plus a source definition become items. Small and declarative: paths and
//! fixed formatting steps, no scripting.
//!
//! Paths: dot-separated keys, with `[n]` array indexes (`[-1]` = last). A path starts at the current element
//! (the element of the item group's `each`, or the response root when there is none); `^` starts at the
//! response root instead; `@` is the current element itself; `@key` (the whole path) is the member name when `each`
//! walks an object. `[#]` is the index of the current element, so a response that keeps one array per column
//! (Open-Meteo's `daily`) is read with `"each": "daily.time"` and `"path": "^daily.temperature_2m_max[#]"`.
//! XML attributes are keys that start with `@` (`link.@href`), and element text next to attributes is `#text`.
//!
//! Formatting steps of a value, in this order: time conversion or (scale, offset, round, compass) or plain text;
//! `lookup` (replaces the result, keyed by the raw value); `omit_if`; `case`; `max_chars`; `prefix`/`suffix`.
//!
//! An item group with a `window` is one item for a part of the day ahead (the night): its `agg` values are taken over the
//! elements of a time series inside that part, so "the overnight low" is the lowest hourly temperature from 18:00 to 07:00.
//!
//! An item group is mapped, then `where` drops items, `near` drops items too far from the place, `sort` orders them and
//! `limit` keeps the first few.

use crate::def::{AggSpec, CalcSpec, Cond, DistanceSpec, ItemDef, Num, SourceDef, Spec, TimeSpec, WindowDef};
use crate::cap;
use crate::geo::{self, Near};
use crate::tz::Zone;
use crate::{Error, Result};
use chrono::{DateTime, Duration, FixedOffset, NaiveDate, NaiveDateTime, NaiveTime, Timelike};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::cmp::Ordering;
use std::collections::BTreeMap;

/// Labelled values in the order the definition lists them. Serialises as a JSON object.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Fields(pub Vec<(String, String)>);

impl Serialize for Fields {
    fn serialize<S: serde::Serializer>(&self, s: S) -> std::result::Result<S::Ok, S::Error> {
        use serde::ser::SerializeMap;
        let mut m = s.serialize_map(Some(self.0.len()))?;
        for (k, v) in &self.0 {
            m.serialize_entry(k, v)?;
        }
        m.end()
    }
}

impl<'de> Deserialize<'de> for Fields {
    fn deserialize<D: serde::Deserializer<'de>>(d: D) -> std::result::Result<Fields, D::Error> {
        struct V;
        impl<'de> serde::de::Visitor<'de> for V {
            type Value = Fields;
            fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
                f.write_str("an object of strings")
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(self, mut m: A) -> std::result::Result<Fields, A::Error> {
                let mut v = Vec::new();
                while let Some((k, x)) = m.next_entry::<String, String>()? {
                    v.push((k, x));
                }
                Ok(Fields(v))
            }
        }
        d.deserialize_map(V)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub lat: f64,
    pub lon: f64,
}

/// One mapped item, as stored in live.sqlite.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Item {
    pub key: String,
    pub label: String,
    pub time: Option<String>,
    /// Unix seconds when the item stops being true, if the definition says.
    pub ends: Option<i64>,
    pub fields: Fields,
    pub point: Option<Point>,
    pub area: Option<Value>,
}

pub struct Mapped {
    pub items: Vec<Item>,
    /// The place's zone: the response's (`timezone_path`, `utc_offset_path`), else the offline lookup of the place, else UTC.
    pub zone: Zone,
    pub valid_until: i64,
    pub not_covered_after: Option<String>,
}

/// The user parameters of a fetch (see `params.rs`).
pub type Params = BTreeMap<String, Value>;

struct Ctx<'a> {
    root: &'a Value,
    cur: &'a Value,
    idx: usize,
    /// The member name when the group walks an object.
    key: Option<&'a str>,
    zone: &'a Zone,
    params: &'a Params,
    /// When the data was fetched (Unix seconds), for `max_age_hours`.
    now: i64,
    /// The place the data is for (distances are measured from it).
    lat: f64,
    lon: f64,
    /// The item group's `window`, when it has one.
    win: Option<&'a Win<'a>>,
    /// The place's area and codes, when it was given with them (`cap_area` matches against them).
    pg: &'a PlaceGeo,
}

/// What a place can carry besides its point: an area (a downloaded region's outline, GeoJSON) and codes by name (`{"SAME":
/// ["016001"]}`). `cap_area` with `match_place` matches alert areas against them.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PlaceGeo {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub area: Option<Value>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub codes: BTreeMap<String, Vec<String>>,
}

impl PlaceGeo {
    pub fn is_empty(&self) -> bool {
        self.area.is_none() && self.codes.is_empty()
    }
}

static NO_GEO: PlaceGeo = PlaceGeo { area: None, codes: BTreeMap::new() };

/// A `window` worked out for one response: the period, the series' elements and which of them fall in it.
struct Win<'a> {
    from: i64,
    to: i64,
    list: &'a [Value],
    idxs: Vec<usize>,
}

/// A wall-clock hour on a local day as an instant (a skipped hour falls an hour later).
fn local_hour(zone: &Zone, d: NaiveDate, h: u32) -> Option<i64> {
    let n = d.and_time(NaiveTime::from_hms_opt(h, 0, 0)?);
    zone.local(&n).or_else(|| zone.local(&(n + Duration::hours(1)))).map(|t| t.timestamp())
}

/// The period of `w` at `now`: the one in progress, else the next; with the elements of its series that overlap it. `None`
/// when the hours are not valid or the series has nothing in the period.
fn window_of<'a>(w: &WindowDef, list: &'a [Value], zone: &Zone, now: i64) -> Option<Win<'a>> {
    if w.from_hour > 23 || w.to_hour > 23 || w.from_hour == w.to_hour {
        return None;
    }
    let local = DateTime::from_timestamp(now, 0)?.with_timezone(&zone.offset_at(now));
    let (d, h) = (local.date_naive(), local.hour());
    let next = d + Duration::days(1);
    let (from, to) = if w.from_hour > w.to_hour {
        if h < w.to_hour {
            (now, local_hour(zone, d, w.to_hour)?)
        } else {
            (now.max(local_hour(zone, d, w.from_hour)?), local_hour(zone, next, w.to_hour)?)
        }
    } else if h < w.to_hour {
        (now.max(local_hour(zone, d, w.from_hour)?), local_hour(zone, d, w.to_hour)?)
    } else {
        (local_hour(zone, next, w.from_hour)?, local_hour(zone, next, w.to_hour)?)
    };
    let step = i64::from(w.step_minutes.unwrap_or(60).max(1)) * 60;
    let idxs: Vec<usize> = list
        .iter()
        .enumerate()
        .filter_map(|(i, v)| {
            let t = parse_time(v, &w.time, zone)?.timestamp();
            (t < to && t + step > from).then_some(i)
        })
        .collect();
    if idxs.is_empty() {
        return None;
    }
    Some(Win { from, to, list, idxs })
}

/// `value` at each element of the window, combined.
fn agg(a: &AggSpec, ctx: &Ctx) -> Option<String> {
    let win = ctx.win?;
    let vals: Vec<f64> = win
        .idxs
        .iter()
        .filter_map(|&i| {
            let c = Ctx { cur: &win.list[i], idx: i, ..*ctx };
            lead_num(&eval(&a.value, &c)?)
        })
        .collect();
    let first = *vals.first()?;
    let r = match a.op.as_str() {
        "min" => vals.iter().copied().fold(first, f64::min),
        "max" => vals.iter().copied().fold(first, f64::max),
        "sum" => vals.iter().sum(),
        "first" => first,
        "last" => *vals.last()?,
        _ => return None,
    };
    Some(fmt_num(r, None))
}

/// Follow a path (see the module doc).
fn follow<'a>(ctx: &Ctx<'a>, path: &str) -> Option<&'a Value> {
    let (mut v, rest): (&'a Value, &str) = if let Some(r) = path.strip_prefix('^') {
        (ctx.root, r)
    } else if path == "@" {
        return Some(ctx.cur);
    } else {
        (ctx.cur, path)
    };
    for seg in rest.split('.').filter(|s| !s.is_empty()) {
        let (name, mut idxs) = match seg.find('[') {
            Some(i) => (&seg[..i], &seg[i..]),
            None => (seg, ""),
        };
        if !name.is_empty() {
            v = v.get(name)?;
        }
        while let Some(r) = idxs.strip_prefix('[') {
            let end = r.find(']')?;
            let ix = &r[..end];
            let arr = v.as_array()?;
            let i: usize = if ix == "#" {
                ctx.idx
            } else {
                let n: i64 = ix.parse().ok()?;
                if n < 0 {
                    arr.len().checked_sub(n.unsigned_abs() as usize)?
                } else {
                    n as usize
                }
            };
            v = arr.get(i)?;
            idxs = &r[end + 1..];
        }
    }
    Some(v)
}

/// A value of a response tree by path, from its root (used by multi-step requests and paging).
pub fn lookup<'a>(root: &'a Value, path: &str) -> Option<&'a Value> {
    static Z: Zone = Zone::UTC;
    static P: std::sync::OnceLock<Params> = std::sync::OnceLock::new();
    let ctx = Ctx { root, cur: root, idx: 0, key: None, zone: &Z, params: P.get_or_init(Params::new), now: 0, lat: 0.0, lon: 0.0, win: None, pg: &NO_GEO };
    follow(&ctx, path)
}

/// A value as plain text (see `plain`), for placeholders.
pub fn plain_text(v: &Value) -> Option<String> {
    plain(v)
}

fn one_line(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn fmt_num(x: f64, round: Option<u32>) -> String {
    match round {
        Some(d) => {
            let s = format!("{:.*}", d as usize, x);
            if s.starts_with('-') && s[1..].chars().all(|c| c == '0' || c == '.') {
                s[1..].to_string()
            } else {
                s
            }
        }
        None if x.fract() == 0.0 && x.abs() < 1e15 => format!("{}", x as i64),
        None => format!("{x}"),
    }
}

fn as_num(v: &Value) -> Option<f64> {
    match v {
        Value::Number(n) => n.as_f64(),
        Value::String(s) => s.trim().parse().ok(),
        _ => None,
    }
}

/// The number at the start of a text ("54 acres" -> 54, "-3.5%" -> -3.5).
fn lead_num(s: &str) -> Option<f64> {
    let s = s.trim();
    let mut end = 0;
    let b = s.as_bytes();
    let mut seen_digit = false;
    let mut seen_dot = false;
    for (i, c) in b.iter().enumerate() {
        match c {
            b'+' | b'-' if i == 0 => end = i + 1,
            b'0'..=b'9' => {
                seen_digit = true;
                end = i + 1;
            }
            b'.' if !seen_dot => {
                seen_dot = true;
                end = i + 1;
            }
            _ => break,
        }
    }
    if !seen_digit {
        return None;
    }
    s[..end].parse().ok()
}

/// The value as plain text (strings on one line, numbers without a trailing .0, lists joined with ", ").
fn plain(v: &Value) -> Option<String> {
    match v {
        Value::Null | Value::Object(_) => None,
        Value::String(s) => Some(one_line(s)),
        Value::Number(n) => Some(n.as_f64().map(|x| fmt_num(x, None)).unwrap_or_else(|| n.to_string())),
        Value::Bool(b) => Some(b.to_string()),
        Value::Array(a) => {
            let parts: Vec<String> = a.iter().filter_map(plain).filter(|s| !s.is_empty()).collect();
            if parts.is_empty() { None } else { Some(parts.join(", ")) }
        }
    }
}

fn compass(deg: f64) -> &'static str {
    const P: [&str; 8] = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
    P[(((deg.rem_euclid(360.0)) / 45.0).round() as usize) % 8]
}

/// A date and time written without an offset, in the common shapes: `T` or a space between date and time, seconds and
/// a fraction optional, a trailing `Z` or ` UTC` ignored; or a date alone (midnight).
fn naive_flex(s: &str) -> Option<NaiveDateTime> {
    let s = s.trim();
    let s = s.strip_suffix('Z').or_else(|| s.strip_suffix(" UTC")).unwrap_or(s).trim_end();
    for f in ["%Y-%m-%dT%H:%M:%S%.f", "%Y-%m-%d %H:%M:%S%.f", "%Y-%m-%dT%H:%M", "%Y-%m-%d %H:%M"] {
        if let Ok(n) = NaiveDateTime::parse_from_str(s, f) {
            return Some(n);
        }
    }
    NaiveDate::parse_from_str(s, "%Y-%m-%d").ok().and_then(|d| d.and_hms_opt(0, 0, 0))
}

fn parse_time(v: &Value, t: &TimeSpec, zone: &Zone) -> Option<DateTime<FixedOffset>> {
    match t.input.as_str() {
        "unix" => {
            let secs = as_num(v)? as i64;
            Some(zone.convert(DateTime::from_timestamp(secs, 0)?.fixed_offset()))
        }
        "unix_ms" => {
            let ms = as_num(v)? as i64;
            Some(zone.convert(DateTime::from_timestamp_millis(ms)?.fixed_offset()))
        }
        "rfc3339" => DateTime::parse_from_rfc3339(v.as_str()?.trim()).ok(),
        "rfc2822" => DateTime::parse_from_rfc2822(v.as_str()?.trim()).ok(),
        "utc" => {
            let n = naive_flex(v.as_str()?)?;
            Some(zone.convert(n.and_utc().fixed_offset()))
        }
        "pattern" => {
            let pat = t.pattern.as_deref()?;
            let s = v.as_str()?.trim();
            if pat.contains("%z") || pat.contains("%:z") || pat.contains("%#z") {
                return DateTime::parse_from_str(s, pat).ok();
            }
            let naive = NaiveDateTime::parse_from_str(s, pat)
                .ok()
                .or_else(|| NaiveDate::parse_from_str(s, pat).ok().and_then(|d| d.and_hms_opt(0, 0, 0)))?;
            if t.assume.as_deref() == Some("utc") {
                Some(zone.convert(naive.and_utc().fixed_offset()))
            } else {
                zone.local(&naive)
            }
        }
        _ => {
            let naive = naive_flex(v.as_str()?)?;
            zone.local(&naive)
        }
    }
}

fn write_time(dt: DateTime<FixedOffset>, t: &TimeSpec, zone: &Zone) -> String {
    let dt = if t.zone.as_deref() == Some("place") { zone.convert(dt) } else { dt };
    let pat = match t.out.as_deref() {
        None | Some("datetime") => "%Y-%m-%dT%H:%M%:z",
        Some("datetime_s") => "%Y-%m-%dT%H:%M:%S%:z",
        Some("date") => "%Y-%m-%d",
        Some(p) => p,
    };
    dt.format(pat).to_string()
}

/// A value, written as text.
fn eval(spec: &Spec, ctx: &Ctx) -> Option<String> {
    if spec.unless.as_ref().is_some_and(|u| eval(u, ctx).is_some()) {
        return None;
    }
    // the raw value
    let (raw, base_text): (Option<Value>, Option<String>) = if !spec.first_of.is_empty() {
        (None, Some(spec.first_of.iter().find_map(|s| eval(s, ctx))?))
    } else if let Some(d) = &spec.distance {
        (None, Some(distance_text(d, ctx)?))
    } else if let Some(c) = &spec.calc {
        (None, Some(calc(c, ctx)?))
    } else if let Some(a) = &spec.agg {
        (None, Some(agg(a, ctx)?))
    } else if let Some(w) = &spec.window {
        let win = ctx.win?;
        (Some(Value::from(match w.as_str() {
            "from" => win.from,
            "to" => win.to,
            _ => return None,
        })), None)
    } else if let Some(p) = &spec.param {
        (Some(ctx.params.get(p)?.clone()), None)
    } else if let Some(t) = &spec.template {
        let mut out = String::new();
        let mut rest = t.as_str();
        while let Some(i) = rest.find('{') {
            out.push_str(&rest[..i]);
            let j = rest[i..].find('}')? + i;
            out.push_str(&eval(spec.vars.get(&rest[i + 1..j])?, ctx)?);
            rest = &rest[j + 1..];
        }
        out.push_str(rest);
        (None, Some(out))
    } else if let Some(c) = &spec.constant {
        (Some(c.clone()), None)
    } else if spec.path.as_deref() == Some("@key") {
        (Some(Value::String(ctx.key?.to_string())), None)
    } else {
        (Some(follow(ctx, spec.path.as_deref()?)?.clone()), None)
    };
    let (raw, base_text) = match &spec.after_last {
        Some(sep) if !sep.is_empty() => {
            let t = match (&raw, &base_text) {
                (Some(v), _) => plain(v)?,
                (None, Some(s)) => s.clone(),
                _ => return None,
            };
            (None, Some(t.rsplit(sep.as_str()).next()?.to_string()))
        }
        _ => (raw, base_text),
    };
    let raw_ref = raw.as_ref();
    let mut text: String = if !spec.lookup.is_empty() {
        let key = match raw_ref {
            Some(v) => plain(v)?,
            None => base_text.clone()?,
        };
        spec.lookup.get(&key).or_else(|| spec.lookup.get("*"))?.clone()
    } else if let Some(t) = &spec.time {
        let v = match (raw_ref, &base_text) {
            (Some(v), _) => v.clone(),
            (None, Some(s)) => Value::String(s.clone()),
            _ => return None,
        };
        let dt = parse_time(&v, t, ctx.zone)?;
        if let Some(nb) = t.not_before.as_deref().and_then(|d| NaiveDate::parse_from_str(d, "%Y-%m-%d").ok()) {
            if dt.date_naive() < nb {
                return None;
            }
        }
        write_time(dt, t, ctx.zone)
    } else if spec.compass || spec.scale.is_some() || spec.offset.is_some() || spec.round.is_some() {
        let n = match (raw_ref, &base_text) {
            (Some(v), _) => as_num(v)?,
            (None, Some(s)) => s.trim().parse().ok()?,
            _ => return None,
        };
        let n = n * spec.scale.unwrap_or(1.0) + spec.offset.unwrap_or(0.0);
        if spec.compass {
            compass(n).to_string()
        } else {
            fmt_num(n, spec.round)
        }
    } else {
        match (raw_ref, base_text) {
            (Some(v), _) => plain(v)?,
            (None, Some(s)) => one_line(&s),
            _ => return None,
        }
    };
    if text.is_empty() {
        return None;
    }
    if spec.min_value.is_some() || spec.max_value.is_some() {
        let n = lead_num(&text)?;
        if spec.min_value.map(|m| n < m).unwrap_or(false) || spec.max_value.map(|m| n > m).unwrap_or(false) {
            return None;
        }
    }
    if spec.omit_if.iter().any(|o| o.to_lowercase() == text.to_lowercase()) {
        return None;
    }
    match spec.case.as_deref() {
        Some("lower") => text = text.to_lowercase(),
        Some("upper") => text = text.to_uppercase(),
        _ => {}
    }
    if let Some(max) = spec.max_chars {
        if text.chars().count() > max {
            let cut: String = text.chars().take(max).collect();
            let cut = match cut.rfind(' ') {
                Some(i) if i > max / 2 => cut[..i].to_string(),
                _ => cut,
            };
            text = format!("{}\u{2026}", cut.trim_end_matches(|c: char| c == ',' || c == ';' || c.is_whitespace()));
        }
    }
    Some(format!("{}{}{}", spec.prefix.as_deref().unwrap_or(""), text, spec.suffix.as_deref().unwrap_or("")))
}

/// Arithmetic on the values of `args`, left to right.
fn calc(c: &CalcSpec, ctx: &Ctx) -> Option<String> {
    let mut nums = Vec::with_capacity(c.args.len());
    for a in &c.args {
        nums.push(lead_num(&eval(a, ctx)?)?);
    }
    let mut it = nums.into_iter();
    let first = it.next()?;
    let r = match c.op.as_str() {
        "add" | "+" => it.fold(first, |a, b| a + b),
        "sub" | "-" => it.fold(first, |a, b| a - b),
        "mul" | "*" => it.fold(first, |a, b| a * b),
        "div" | "/" => {
            let mut acc = first;
            for b in it {
                if b == 0.0 {
                    return None;
                }
                acc /= b;
            }
            acc
        }
        "min" => it.fold(first, f64::min),
        "max" => it.fold(first, f64::max),
        _ => return None,
    };
    if r.is_finite() {
        Some(fmt_num(r, None))
    } else {
        None
    }
}

fn point_of(p: &crate::def::PointDef, ctx: &Ctx) -> Option<(f64, f64)> {
    let lat: f64 = lead_num(&eval(&p.lat, ctx)?)?;
    let lon: f64 = lead_num(&eval(&p.lon, ctx)?)?;
    if lat.abs() <= 90.0 && lon.abs() <= 180.0 {
        Some((lat, lon))
    } else {
        None
    }
}

fn near_of_spec(d: &DistanceSpec, ctx: &Ctx) -> Option<Near> {
    match (&d.geometry, &d.point) {
        (Some(g), _) => geo::nearest(follow(ctx, g)?, ctx.lat, ctx.lon),
        (None, Some(p)) => {
            let (la, lo) = point_of(p, ctx)?;
            Some(geo::to_point(ctx.lat, ctx.lon, la, lo))
        }
        _ => None,
    }
}

/// "6.2 mi S", or "inside the area", or just the number with `number`.
fn distance_text(d: &DistanceSpec, ctx: &Ctx) -> Option<String> {
    let near = near_of_spec(d, ctx)?;
    let (v, unit) = if d.unit == "km" { (near.km, "km") } else { (near.km * 0.621_371_192, "mi") };
    if d.number {
        return Some(fmt_num(if near.inside { 0.0 } else { v }, None));
    }
    if near.inside {
        return Some("inside the area".into());
    }
    if near.km < 0.05 {
        return Some("at the place".into());
    }
    let num = if v < 10.0 { format!("{v:.1}") } else { format!("{v:.0}") };
    Some(format!("{num} {unit} {}", compass(near.bearing)))
}

/// A time value as an instant (Unix seconds). A spec without `time` is read as RFC 3339.
fn eval_instant(spec: &Spec, ctx: &Ctx) -> Option<i64> {
    if !spec.first_of.is_empty() {
        return spec.first_of.iter().find_map(|s| eval_instant(s, ctx));
    }
    // Calculated ends use the same value arithmetic as fields. Parse the result as an
    // instant before output formatting (which can intentionally discard the time).
    let calculated;
    let v = if let Some(c) = &spec.calc {
        calculated = Value::String(calc(c, ctx)?);
        &calculated
    } else {
        follow(ctx, spec.path.as_deref()?)?
    };
    let default = TimeSpec { input: "rfc3339".into(), pattern: None, assume: None, out: None, zone: None, not_before: None };
    parse_time(v, spec.time.as_ref().unwrap_or(&default), ctx.zone).map(|d| d.timestamp())
}

/// How far the item is from the place: its `near` geometry or point, else its `point`, else its `area`.
fn item_near(g: &ItemDef, ctx: &Ctx) -> Option<Near> {
    if let Some(n) = &g.near {
        if let Some(p) = &n.point {
            let (la, lo) = point_of(p, ctx)?;
            return Some(geo::to_point(ctx.lat, ctx.lon, la, lo));
        }
        if let Some(path) = &n.geometry {
            return geo::nearest(follow(ctx, path)?, ctx.lat, ctx.lon);
        }
    }
    if let Some(p) = &g.point {
        if let Some((la, lo)) = point_of(p, ctx) {
            return Some(geo::to_point(ctx.lat, ctx.lon, la, lo));
        }
    }
    if let Some(c) = &g.cap_area {
        return geo::nearest(&cap::read(follow(ctx, &c.path)?).geometry?, ctx.lat, ctx.lon);
    }
    let a = g.area.as_ref()?;
    geo::nearest(follow(ctx, a)?, ctx.lat, ctx.lon)
}

fn num_of(n: &Num, ctx: &Ctx) -> Option<f64> {
    match n {
        Num::Lit(x) => Some(*x),
        Num::Val(s) => lead_num(&eval(s, ctx)?),
    }
}

fn map_item(def: &ItemDef, ctx: &Ctx) -> Option<Item> {
    let key = eval(&def.key, ctx)?;
    let label = eval(&def.label, ctx)?;
    let fields: Vec<(String, String)> =
        def.fields.iter().filter_map(|f| Some((f.label.clone()?, eval(f, ctx)?))).collect();
    let point = def.point.as_ref().and_then(|p| {
        let (lat, lon) = point_of(p, ctx)?;
        Some(Point { lat, lon })
    });
    Some(Item {
        key,
        label,
        // a window's item starts and ends with its period unless the definition says otherwise
        time: def.time.as_ref().and_then(|t| eval(t, ctx)).or_else(|| {
            let w = ctx.win?;
            Some(DateTime::from_timestamp(w.from, 0)?.with_timezone(&ctx.zone.offset_at(w.from)).format("%Y-%m-%dT%H:%M%:z").to_string())
        }),
        ends: def.ends.as_ref().and_then(|e| eval_instant(e, ctx)).or_else(|| ctx.win.map(|w| w.to)),
        fields: Fields(fields),
        point,
        area: match &def.cap_area {
            Some(c) => follow(ctx, &c.path).and_then(|a| cap::read(a).geometry),
            None => def.area.as_ref().and_then(|p| follow(ctx, p)).filter(|v| v.is_object()).cloned(),
        },
    })
}

/// `cap_area` with `match_place`: whether the item's CAP area reaches the place. A polygon or circle contains the place's point,
/// or overlaps the place's area when it has one; or one of the item's geocodes named `code` is one of the place's codes (those it
/// was given with, and those `place_codes` finds in the response).
fn cap_reaches(c: &crate::def::CapAreaDef, item: &Item, ctx: &Ctx) -> bool {
    if let Some(g) = &item.area {
        let hit = match &ctx.pg.area {
            Some(pa) => geo::intersects(g, pa),
            None => geo::nearest(g, ctx.lat, ctx.lon).map(|n| n.inside).unwrap_or(false),
        };
        if hit {
            return true;
        }
    }
    let Some(name) = &c.code else { return false };
    let mut mine: Vec<String> = ctx.pg.codes.iter().filter(|(k, _)| k.eq_ignore_ascii_case(name)).flat_map(|(_, v)| v.iter().map(|x| x.trim().to_string())).collect();
    mine.extend(c.place_codes.iter().filter_map(|s| eval(s, ctx)).map(|s| s.trim().to_string()));
    mine.retain(|m| !m.is_empty());
    if mine.is_empty() {
        return false;
    }
    let Some(areas) = follow(ctx, &c.path) else { return false };
    cap::read(areas).codes.iter().any(|(n, v)| n.eq_ignore_ascii_case(name) && mine.iter().any(|m| m == v))
}

fn same(have: &str, want: &Value) -> bool {
    match want {
        Value::Number(n) => match (have.trim().parse::<f64>(), n.as_f64()) {
            (Ok(a), Some(b)) => a == b,
            _ => false,
        },
        Value::String(s) => one_line(s).to_lowercase() == have.trim().to_lowercase(),
        Value::Bool(b) => have.trim().eq_ignore_ascii_case(&b.to_string()),
        _ => false,
    }
}

fn cond_ok(c: &Cond, item: &Item, ctx: &Ctx) -> bool {
    if !c.or.is_empty() {
        return c.or.iter().any(|x| cond_ok(x, item, ctx));
    }
    let have: Option<String> = if let Some(v) = &c.value {
        eval(v, ctx)
    } else if let Some(f) = &c.field {
        item.fields.0.iter().find(|(l, _)| l == f).map(|(_, t)| t.clone())
    } else {
        None
    };
    if let Some(e) = c.exists {
        if have.is_some() != e {
            return false;
        }
    }
    if let (Some(h), Some(v)) = (&c.max_age_hours, &c.value) {
        let Some(hours) = num_of(h, ctx) else { return false };
        // a value with a time is read as a time (RFC 3339 without one)
        return match eval_instant(v, ctx) {
            Some(t) => t >= ctx.now - (hours * 3600.0) as i64 && c.or.is_empty(),
            None => false,
        };
    }
    let Some(h) = have else {
        // a missing value fails every test except the negative ones
        let positive = c.equals.is_some()
            || !c.one_of.is_empty()
            || c.gt.is_some()
            || c.ge.is_some()
            || c.lt.is_some()
            || c.le.is_some()
            || c.contains.is_some()
            || c.starts_with.is_some();
        return !positive;
    };
    if let Some(w) = &c.equals {
        if !same(&h, w) {
            return false;
        }
    }
    if let Some(w) = &c.not_equals {
        if same(&h, w) {
            return false;
        }
    }
    if !c.one_of.is_empty() && !c.one_of.iter().any(|w| same(&h, w)) {
        return false;
    }
    if c.not_in.iter().any(|w| same(&h, w)) {
        return false;
    }
    let cmp = |want: &Option<Num>, ok: fn(Ordering) -> bool| -> bool {
        match want {
            None => true,
            Some(n) => match (lead_num(&h), num_of(n, ctx)) {
                (Some(a), Some(b)) => a.partial_cmp(&b).map(ok).unwrap_or(false),
                _ => false,
            },
        }
    };
    if !cmp(&c.gt, |o| o == Ordering::Greater) || !cmp(&c.ge, |o| o != Ordering::Less) || !cmp(&c.lt, |o| o == Ordering::Less) || !cmp(&c.le, |o| o != Ordering::Greater) {
        return false;
    }
    if let Some(t) = &c.contains {
        if !h.to_lowercase().contains(&t.to_lowercase()) {
            return false;
        }
    }
    if let Some(t) = &c.starts_with {
        if !h.to_lowercase().starts_with(&t.to_lowercase()) {
            return false;
        }
    }
    true
}

fn bad(m: String) -> Error {
    Error::bad_response(m)
}

/// The place's zone for a response: `timezone_path`, else `utc_offset_path`, else the offline lookup of the place,
/// else UTC.
pub fn zone_for(def: &SourceDef, root: &Value, lat: f64, lon: f64) -> Result<Zone> {
    let utc = Zone::UTC;
    let none = Params::new();
    let probe = Ctx { root, cur: root, idx: 0, key: None, zone: &utc, params: &none, now: 0, lat, lon, win: None, pg: &NO_GEO };
    if let Some(p) = &def.timezone_path {
        if let Some(z) = follow(&probe, p).and_then(Value::as_str).and_then(Zone::from_name) {
            return Ok(z);
        }
    }
    if let Some(p) = &def.utc_offset_path {
        return match follow(&probe, p).and_then(as_num) {
            Some(n) if n.abs() <= 18.0 * 3600.0 => Ok(Zone::Fixed(n as i32)),
            _ => Err(bad(format!("no UTC offset at {p:?}"))),
        };
    }
    Ok(Zone::at(lat, lon).unwrap_or(Zone::UTC))
}

#[derive(PartialEq, PartialOrd)]
enum KeyVal {
    Num(i64),
    Flt(f64),
    Text(String),
}

fn sort_keys(g: &ItemDef, ctx: &Ctx) -> Vec<Option<KeyVal>> {
    g.sort
        .iter()
        .map(|k| {
            if k.distance {
                return item_near(g, ctx).map(|n| KeyVal::Flt(if n.inside { 0.0 } else { n.km }));
            }
            let by = k.by.as_ref()?;
            if !k.rank.is_empty() {
                let v = eval(by, ctx)?.to_lowercase();
                Some(KeyVal::Num(k.rank.iter().position(|r| r.to_lowercase() == v).unwrap_or(k.rank.len()) as i64))
            } else if k.time {
                eval_instant(by, ctx).map(KeyVal::Num)
            } else if k.number {
                lead_num(&eval(by, ctx)?).map(KeyVal::Flt)
            } else {
                eval(by, ctx).map(KeyVal::Text)
            }
        })
        .collect()
}

/// Map a response for a place at (`lat`, `lon`) with the parameters' defaults left out (none). `fetched_at` (Unix
/// seconds) is only used for a fixed-hours validity.
pub fn map_response(def: &SourceDef, root: &Value, fetched_at: i64, lat: f64, lon: f64) -> Result<Mapped> {
    map_response_with(def, root, fetched_at, lat, lon, &Params::new())
}

/// `map_response` with the user's parameters (`{"param": "name"}` in the definition reads them).
pub fn map_response_with(def: &SourceDef, root: &Value, fetched_at: i64, lat: f64, lon: f64, params: &Params) -> Result<Mapped> {
    map_response_at(def, root, fetched_at, lat, lon, &NO_GEO, params)
}

/// `map_response_with` for a place that may carry an area and codes (see `PlaceGeo`).
pub fn map_response_at(def: &SourceDef, root: &Value, fetched_at: i64, lat: f64, lon: f64, pg: &PlaceGeo, params: &Params) -> Result<Mapped> {
    let zone = zone_for(def, root, lat, lon)?;
    let at = |cur| Ctx { root, cur, idx: 0, key: None, zone: &zone, params, now: fetched_at, lat, lon, win: None, pg };
    for p in &def.require {
        if follow(&at(root), p).is_none() {
            return Err(bad(format!("the response has no {p:?}")));
        }
    }
    let mut items = Vec::new();
    for g in &def.items {
        let mut group: Vec<(Vec<Option<KeyVal>>, Item)> = Vec::new();
        let push = |ctx: Ctx, group: &mut Vec<(Vec<Option<KeyVal>>, Item)>| {
            let Some(it) = map_item(g, &ctx) else { return };
            if !g.filter.iter().all(|c| cond_ok(c, &it, &ctx)) {
                return;
            }
            if let Some(c) = g.cap_area.as_ref().filter(|c| c.match_place) {
                if !cap_reaches(c, &it, &ctx) {
                    return;
                }
            }
            if let Some(n) = &g.near {
                let Some(max) = num_of(&n.max, &ctx) else { return };
                let Some(d) = item_near(g, &ctx) else { return };
                let km = if d.inside { 0.0 } else { d.km };
                let max_km = if n.unit == "mi" { max / 0.621_371_192 } else { max };
                if km > max_km {
                    return;
                }
            }
            group.push((sort_keys(g, &ctx), it));
        };
        if let Some(w) = &g.window {
            // nothing in the period (a series that does not reach it): no item
            let list = follow(&at(root), &w.each).and_then(Value::as_array).map(Vec::as_slice).unwrap_or(&[]);
            if let Some(win) = window_of(w, list, &zone, fetched_at) {
                push(Ctx { win: Some(&win), ..at(root) }, &mut group);
            }
        } else {
        match &g.each {
            Some(p) => {
                let target = follow(&at(root), p).ok_or_else(|| bad(format!("no list at {p:?}")))?;
                match target {
                    Value::Array(arr) => {
                        for (i, el) in arr.iter().enumerate() {
                            push(Ctx { root, cur: el, idx: i, key: None, zone: &zone, params, now: fetched_at, lat, lon, win: None, pg }, &mut group);
                        }
                    }
                    Value::Object(obj) => {
                        for (i, (k, el)) in obj.iter().enumerate() {
                            push(Ctx { root, cur: el, idx: i, key: Some(k.as_str()), zone: &zone, params, now: fetched_at, lat, lon, win: None, pg }, &mut group);
                        }
                    }
                    _ => return Err(bad(format!("no list at {p:?}"))),
                }
            }
            None => push(at(root), &mut group),
        }
        }
        if !g.sort.is_empty() {
            group.sort_by(|a, b| {
                for (i, k) in g.sort.iter().enumerate() {
                    // missing values last, whatever the direction
                    let o = match (&a.0[i], &b.0[i]) {
                        (None, None) => Ordering::Equal,
                        (None, Some(_)) => return Ordering::Greater,
                        (Some(_), None) => return Ordering::Less,
                        (Some(x), Some(y)) => x.partial_cmp(y).unwrap_or(Ordering::Equal),
                    };
                    let o = if k.desc { o.reverse() } else { o };
                    if o != Ordering::Equal {
                        return o;
                    }
                }
                Ordering::Equal
            });
        }
        if let Some(n) = g.limit {
            group.truncate(n);
        }
        items.extend(group.into_iter().map(|(_, it)| it));
    }
    // keys are the addresses' last part: they must be distinct
    let mut seen = std::collections::HashSet::new();
    items.retain(|i| seen.insert(i.key.clone()));
    let (valid_until, not_covered_after) = validity(def, root, &zone, fetched_at, lat, lon)?;
    Ok(Mapped { items, zone, valid_until, not_covered_after })
}

fn validity(def: &SourceDef, root: &Value, zone: &Zone, fetched_at: i64, lat: f64, lon: f64) -> Result<(i64, Option<String>)> {
    let v = &def.validity;
    if let Some(h) = v.fixed_hours {
        return Ok((fetched_at + (h * 3600.0) as i64, None));
    }
    let path = v.end_path.as_deref().unwrap_or("");
    let none = Params::new();
    let ctx = Ctx { root, cur: root, idx: 0, key: None, zone, params: &none, now: fetched_at, lat, lon, win: None, pg: &NO_GEO };
    let val = follow(&ctx, path).ok_or_else(|| bad(format!("no end time at {path:?}")))?;
    let local = TimeSpec { input: "local".into(), pattern: None, assume: None, out: None, zone: None, not_before: None };
    let rfc = TimeSpec { input: "rfc3339".into(), pattern: None, assume: None, out: None, zone: None, not_before: None };
    let dt = parse_time(val, &local, zone).or_else(|| parse_time(val, &rfc, zone)).ok_or_else(|| bad(format!("{path:?} is not a date")))?;
    let end = if v.end_of_day {
        let next = dt.date_naive() + Duration::days(1);
        zone.local(&next.and_hms_opt(0, 0, 0).expect("midnight")).ok_or_else(|| bad("bad date".into()))?
    } else {
        dt
    };
    let nca = v.not_covered_after.then(|| end.format("%Y-%m-%d").to_string());
    Ok((end.timestamp(), nca))
}

/// Time as the tools write it: `2026-10-24T06:00:00-06:00` in the place's offset.
pub fn stamp(t: i64, zone: &Zone) -> String {
    DateTime::from_timestamp(t, 0)
        .map(|d| d.with_timezone(&zone.offset_at(t)).format("%Y-%m-%dT%H:%M:%S%:z").to_string())
        .unwrap_or_default()
}

/// `2026-11-01` for an expiry detail.
pub fn date_of(t: i64, zone: &Zone) -> String {
    DateTime::from_timestamp(t, 0).map(|d| d.with_timezone(&zone.offset_at(t)).format("%Y-%m-%d").to_string()).unwrap_or_default()
}

/// `2026-10-25 22:00`: a time of day to the minute in the place's zone, as the alerts' "Expires" field reads.
pub fn minute_of(t: i64, zone: &Zone) -> String {
    DateTime::from_timestamp(t, 0).map(|d| d.with_timezone(&zone.offset_at(t)).format("%Y-%m-%d %H:%M").to_string()).unwrap_or_default()
}

/// "25 minutes old", "1 day old": the age in plain words, rounded down.
pub fn age_words(secs: i64) -> String {
    let secs = secs.max(0);
    let plural = |n: i64, unit: &str| format!("{n} {unit}{} old", if n == 1 { "" } else { "s" });
    if secs < 60 {
        "less than a minute old".into()
    } else if secs < 3600 {
        plural(secs / 60, "minute")
    } else if secs < 86400 {
        plural(secs / 3600, "hour")
    } else {
        plural(secs / 86400, "day")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn spec(v: Value) -> Spec {
        serde_json::from_value(v).unwrap()
    }
    static Z: Zone = Zone::Fixed(-21600);
    static NO_PARAMS: std::sync::OnceLock<Params> = std::sync::OnceLock::new();
    fn ctx<'a>(root: &'a Value, cur: &'a Value, idx: usize) -> Ctx<'a> {
        Ctx { root, cur, idx, key: None, zone: &Z, params: NO_PARAMS.get_or_init(Params::new), now: 1_792_000_000, lat: 42.536, lon: -113.792, win: None, pg: &NO_GEO }
    }

    #[test]
    fn paths() {
        let root = json!({"a": {"b": [10, 20, 30]}, "t": ["x", "y"]});
        let c = ctx(&root, &root, 1);
        assert_eq!(follow(&c, "a.b[0]"), Some(&json!(10)));
        assert_eq!(follow(&c, "a.b[-1]"), Some(&json!(30)));
        assert_eq!(follow(&c, "a.b[#]"), Some(&json!(20)));
        assert_eq!(follow(&c, "a.b[3]"), None);
        assert_eq!(follow(&c, "a.nope"), None);
        let cur = json!({"v": 5});
        let c = ctx(&root, &cur, 0);
        assert_eq!(follow(&c, "v"), Some(&json!(5)));
        assert_eq!(follow(&c, "^t[1]"), Some(&json!("y")));
        assert_eq!(follow(&c, "@"), Some(&cur));
        assert_eq!(lookup(&root, "a.b[-1]"), Some(&json!(30)));
    }

    #[test]
    fn formatting() {
        let root = json!({"n": 54.4, "d": 315, "c": 3, "t": "2026-10-25T14:00", "neg": -0.2, "s": "  a\n b ", "u": "SEVERE"});
        let c = ctx(&root, &root, 0);
        assert_eq!(eval(&spec(json!({"path":"n","round":0,"suffix":" \u{b0}F"})), &c).unwrap(), "54 \u{b0}F");
        assert_eq!(eval(&spec(json!({"path":"neg","round":0})), &c).unwrap(), "0");
        assert_eq!(eval(&spec(json!({"path":"n","scale":2.0,"offset":1.0,"round":1})), &c).unwrap(), "109.8");
        assert_eq!(eval(&spec(json!({"path":"d","compass":true})), &c).unwrap(), "NW");
        assert_eq!(eval(&spec(json!({"path":"c","lookup":{"3":"overcast","*":"?"}})), &c).unwrap(), "overcast");
        assert_eq!(eval(&spec(json!({"path":"n","lookup":{"3":"x","*":"unknown"}})), &c).unwrap(), "unknown");
        assert_eq!(eval(&spec(json!({"path":"n","lookup":{"3":"x"}})), &c), None);
        assert_eq!(eval(&spec(json!({"path":"t","time":{"in":"local"}})), &c).unwrap(), "2026-10-25T14:00-06:00");
        assert_eq!(eval(&spec(json!({"path":"t","time":{"in":"local","out":"%a %d %b"}})), &c).unwrap(), "Sun 25 Oct");
        assert_eq!(eval(&spec(json!({"path":"s"})), &c).unwrap(), "a b");
        assert_eq!(eval(&spec(json!({"path":"u","case":"lower"})), &c).unwrap(), "severe");
        let url = json!({"u": "https://api.weather.gov/stations/KBOI", "n": 5});
        let cu = ctx(&url, &url, 0);
        assert_eq!(eval(&spec(json!({"path":"u","after_last":"/"})), &cu).unwrap(), "KBOI");
        assert_eq!(eval(&spec(json!({"path":"u","after_last":"/","lookup":{"KBOI":"Boise airport"}})), &cu).unwrap(), "Boise airport");
        assert_eq!(eval(&spec(json!({"path":"n","after_last":"/"})), &cu).unwrap(), "5");
        assert_eq!(eval(&spec(json!({"path":"u","after_last":"#"})), &cu).unwrap(), "https://api.weather.gov/stations/KBOI");
        assert_eq!(eval(&spec(json!({"path":"u","omit_if":["severe"]})), &c), None);
        assert_eq!(eval(&spec(json!({"path":"missing"})), &c), None);
        assert_eq!(eval(&spec(json!({"const":"Now"})), &c).unwrap(), "Now");
        assert_eq!(eval(&spec(json!({"first_of":[{"path":"nope"},{"path":"c"}]})), &c).unwrap(), "3");
        // sentinels: -999 for "no reading", year 1 for "no time"
        let s = json!({"v": -999.0, "w": 3.5, "t": "0001-01-01T00:00:00Z", "t2": "2026-10-25T14:00:00Z"});
        let cs = ctx(&s, &s, 0);
        assert_eq!(eval(&spec(json!({"path":"v","round":1,"min_value":-900})), &cs), None);
        assert_eq!(eval(&spec(json!({"path":"w","round":1,"min_value":-900,"max_value":10,"suffix":" ft"})), &cs).unwrap(), "3.5 ft");
        assert_eq!(eval(&spec(json!({"path":"w","max_value":3})), &cs), None);
        assert_eq!(eval(&spec(json!({"path":"t","time":{"in":"rfc3339","not_before":"2000-01-01"}})), &cs), None);
        assert!(eval(&spec(json!({"path":"t2","time":{"in":"rfc3339","not_before":"2000-01-01"}})), &cs).is_some());
        let long = spec(json!({"const":"alpha beta gamma delta epsilon","max_chars":14}));
        assert_eq!(eval(&long, &c).unwrap(), "alpha beta\u{2026}");
    }

    #[test]
    fn templates() {
        let root = json!({"w": 12.3, "g": 20.1, "d": 315});
        let c = ctx(&root, &root, 0);
        let t = spec(json!({"template":"{s} mph {d}, gusts {g} mph","vars":{
            "s":{"path":"w","round":0},"d":{"path":"d","compass":true},"g":{"path":"g","round":0}}}));
        assert_eq!(eval(&t, &c).unwrap(), "12 mph NW, gusts 20 mph");
        let t = spec(json!({"template":"{x}","vars":{"x":{"path":"missing"}}}));
        assert_eq!(eval(&t, &c), None);
    }

    #[test]
    fn time_conversions() {
        let root = json!({"a": "2026-10-25T13:40:00-06:00", "u": 1_792_000_000i64});
        let c = ctx(&root, &root, 0);
        // an offset the response gave is kept; "zone: place" converts
        assert_eq!(eval(&spec(json!({"path":"a","time":{"in":"rfc3339","out":"datetime_s"}})), &c).unwrap(), "2026-10-25T13:40:00-06:00");
        assert_eq!(eval(&spec(json!({"path":"a","time":{"in":"rfc3339","out":"%H:%M","zone":"place"}})), &c).unwrap(), "13:40");
        assert!(eval(&spec(json!({"path":"u","time":{"in":"unix","out":"date"}})), &c).is_some());
        let z = DateTime::parse_from_rfc3339("2026-10-25T19:40:00Z").unwrap().timestamp();
        assert_eq!(eval_instant(&spec(json!({"path":"a"})), &c), Some(z));
    }

    #[test]
    fn time_inputs_ms_utc_pattern() {
        // 2026-10-25T19:40:00Z in milliseconds = 13:40 in the place (-06:00)
        let ms = DateTime::parse_from_rfc3339("2026-10-25T19:40:00Z").unwrap().timestamp() * 1000 + 250;
        let root = json!({"ms": ms, "utc1": "2026-10-25T19:40:00", "utc2": "2026-10-25 19:40:00.783", "utc3": "2026-10-25T19:40:00Z",
                          "pat": "25/10/2026 13:40", "pat_z": "25 Oct 2026 19:40 +0000", "rfc2822": "Sun, 25 Oct 2026 19:40:00 +0000", "str_ms": "1792000000000"});
        let c = ctx(&root, &root, 0);
        let t = |v: Value| eval(&spec(v), &c);
        assert_eq!(t(json!({"path":"ms","time":{"in":"unix_ms","out":"datetime_s"}})).unwrap(), "2026-10-25T13:40:00-06:00");
        assert!(t(json!({"path":"str_ms","time":{"in":"unix_ms","out":"date"}})).is_some());
        for p in ["utc1", "utc2", "utc3"] {
            assert_eq!(t(json!({"path":p,"time":{"in":"utc","out":"%H:%M %:z"}})).unwrap(), "13:40 -06:00", "{p}");
        }
        assert_eq!(t(json!({"path":"pat","time":{"in":"pattern","pattern":"%d/%m/%Y %H:%M","out":"datetime"}})).unwrap(), "2026-10-25T13:40-06:00");
        assert_eq!(t(json!({"path":"pat","time":{"in":"pattern","pattern":"%d/%m/%Y %H:%M","assume":"utc","out":"%H:%M"}})).unwrap(), "07:40");
        assert_eq!(t(json!({"path":"pat_z","time":{"in":"pattern","pattern":"%d %b %Y %H:%M %z","zone":"place","out":"%H:%M"}})).unwrap(), "13:40");
        assert_eq!(t(json!({"path":"rfc2822","time":{"in":"rfc2822","zone":"place","out":"%H:%M"}})).unwrap(), "13:40");
        // as an instant (sort keys and ends)
        let z = DateTime::parse_from_rfc3339("2026-10-25T19:40:00Z").unwrap().timestamp();
        assert_eq!(eval_instant(&spec(json!({"path":"utc1","time":{"in":"utc"}})), &c), Some(z));
        assert_eq!(eval_instant(&spec(json!({"path":"ms","time":{"in":"unix_ms"}})), &c), Some(z));
        assert_eq!(t(json!({"path":"utc1","time":{"in":"bogus"}})), t(json!({"path":"utc1","time":{"in":"bogus"}})));
    }

    #[test]
    fn distance_text_and_sort() {
        let root = json!({"geometry": {"type":"Polygon","coordinates":[[[-113.9,42.636],[-113.7,42.636],[-113.7,42.7],[-113.9,42.7],[-113.9,42.636]]]},
                          "inside": {"type":"Polygon","coordinates":[[[-113.9,42.4],[-113.7,42.4],[-113.7,42.7],[-113.9,42.7],[-113.9,42.4]]]}});
        let c = ctx(&root, &root, 0);
        assert_eq!(eval(&spec(json!({"distance":{"geometry":"geometry","unit":"mi"}})), &c).unwrap(), "6.9 mi N");
        assert_eq!(eval(&spec(json!({"distance":{"geometry":"geometry","unit":"km"}})), &c).unwrap(), "11 km N");
        assert_eq!(eval(&spec(json!({"distance":{"geometry":"inside","unit":"mi"}})), &c).unwrap(), "inside the area");
        assert_eq!(eval(&spec(json!({"distance":{"geometry":"nothing","unit":"mi"}})), &c), None);
    }

    #[test]
    fn distance_from_points_lines_and_pairs() {
        let root = json!({"pt": {"type":"Point","coordinates":[-113.792, 42.636]},
                          "feat": {"type":"Feature","geometry":{"type":"Point","coordinates":[-113.792, 42.636]}},
                          "line": {"type":"LineString","coordinates":[[-113.5,42.0],[-113.5,43.0]]},
                          "lat": "42.636", "lon": -113.792, "bad": "x"});
        let c = ctx(&root, &root, 0);
        let t = |v: Value| eval(&spec(v), &c);
        // 0.1 degrees of latitude = 11.1 km = 6.9 mi, straight north
        assert_eq!(t(json!({"distance":{"geometry":"pt","unit":"mi"}})).unwrap(), "6.9 mi N");
        assert_eq!(t(json!({"distance":{"geometry":"feat","unit":"mi"}})).unwrap(), "6.9 mi N");
        assert_eq!(t(json!({"distance":{"point":{"lat":{"path":"lat"},"lon":{"path":"lon"}},"unit":"km"}})).unwrap(), "11 km N");
        // the line runs north-south 0.29 degrees of longitude east of the place: nearest point is due east
        let l = t(json!({"distance":{"geometry":"line","unit":"km"}})).unwrap();
        assert!(l.ends_with(" km E"), "{l}");
        assert_eq!(t(json!({"distance":{"point":{"lat":{"path":"bad"},"lon":{"path":"lon"}},"unit":"km"}})), None);
        // a number for arithmetic
        assert_eq!(t(json!({"distance":{"geometry":"pt","unit":"km","number":true},"round":1})).unwrap(), "11.1");
    }

    #[test]
    fn calc_and_param() {
        let root = json!({"a": 10, "b": 4, "z": 0, "t": "20 mph"});
        let mut params = Params::new();
        params.insert("scale".into(), json!(3));
        let c = Ctx { params: &params, ..ctx(&root, &root, 0) };
        let t = |v: Value| eval(&spec(v), &c);
        let arg = |p: &str| json!({"path": p});
        assert_eq!(t(json!({"calc":{"op":"add","args":[arg("a"),arg("b")]}})).unwrap(), "14");
        assert_eq!(t(json!({"calc":{"op":"+","args":[arg("a"),arg("b"),{"const":1}]}})).unwrap(), "15");
        assert_eq!(t(json!({"calc":{"op":"sub","args":[arg("a"),arg("b")]}})).unwrap(), "6");
        assert_eq!(t(json!({"calc":{"op":"mul","args":[arg("a"),arg("b")]}})).unwrap(), "40");
        assert_eq!(t(json!({"calc":{"op":"div","args":[arg("a"),arg("b")]},"round":2})).unwrap(), "2.50");
        assert_eq!(t(json!({"calc":{"op":"/","args":[arg("a"),arg("z")]}})), None);
        assert_eq!(t(json!({"calc":{"op":"min","args":[arg("a"),arg("b")]}})).unwrap(), "4");
        assert_eq!(t(json!({"calc":{"op":"max","args":[arg("a"),arg("b")]}})).unwrap(), "10");
        // a missing argument makes the result missing; first_of supplies a fallback
        assert_eq!(t(json!({"calc":{"op":"add","args":[arg("a"),arg("nope")]}})), None);
        assert_eq!(t(json!({"calc":{"op":"add","args":[arg("a"),{"first_of":[arg("nope"),{"const":5}]}]}})).unwrap(), "15");
        // the number at the start of a text counts, and a calc result goes through the other steps
        assert_eq!(t(json!({"calc":{"op":"mul","args":[arg("t"),{"const":2}]},"suffix":" mph"})).unwrap(), "40 mph");
        assert_eq!(t(json!({"calc":{"op":"mul","args":[arg("a"),{"param":"scale"}]}})).unwrap(), "30");
        assert_eq!(t(json!({"param":"scale","suffix":"x"})).unwrap(), "3x");
        assert_eq!(t(json!({"param":"other"})), None);
    }

    #[test]
    fn where_near_sort_limit_and_each_object() {
        let def: SourceDef = SourceDef::parse(
            &json!({
                "format": 2, "id": "t", "title": "t", "provider": "t", "description": "t",
                "request": {"url": "https://x/"}, "refresh_minutes": 1, "validity": {"fixed_hours": 1},
                "params": [{"name": "min_size", "type": "number", "default": 10}],
                "items": [{
                    "each": "list", "key": {"path": "id"}, "label": {"path": "name"},
                    "point": {"lat": {"path": "lat"}, "lon": {"path": "lon"}},
                    "fields": [{"label": "Size", "path": "size", "suffix": " acres"}, {"label": "Kind", "path": "kind"}],
                    "where": [
                        {"value": {"path": "size"}, "ge": {"param": "min_size"}},
                        {"field": "Kind", "not_in": ["prescribed"]},
                        {"or": [{"value": {"path": "state"}, "equals": "ID"}, {"value": {"path": "state"}, "equals": "OR"}]}
                    ],
                    "near": {"max": 100, "unit": "mi"},
                    "sort": [{"by": {"path": "size"}, "number": true, "desc": true}],
                    "limit": 3
                }, {
                    "each": "byday", "key": {"path": "@key"}, "label": {"template": "Day {d}", "vars": {"d": {"path": "@key"}}},
                    "fields": [{"label": "High", "path": "hi"}],
                    "sort": [{"by": {"path": "hi"}, "number": true}]
                }, {
                    "each": "list", "key": {"template": "near-{id}", "vars": {"id": {"path": "id"}}}, "label": {"path": "name"},
                    "point": {"lat": {"path": "lat"}, "lon": {"path": "lon"}},
                    "fields": [{"label": "From here", "distance": {"point": {"lat": {"path": "lat"}, "lon": {"path": "lon"}}, "unit": "mi"}}],
                    "sort": [{"distance": true}], "limit": 2
                }]
            })
            .to_string(),
        )
        .unwrap();
        let root = json!({
            "list": [
                {"id": "a", "name": "Far", "lat": 46.0, "lon": -113.8, "size": 5000, "kind": "wildfire", "state": "ID"},
                {"id": "b", "name": "Big", "lat": 42.7, "lon": -113.8, "size": "900", "kind": "wildfire", "state": "ID"},
                {"id": "c", "name": "Small", "lat": 42.6, "lon": -113.8, "size": 4, "kind": "wildfire", "state": "ID"},
                {"id": "d", "name": "Rx", "lat": 42.6, "lon": -113.8, "size": 500, "kind": "prescribed", "state": "ID"},
                {"id": "e", "name": "Utah", "lat": 42.6, "lon": -113.8, "size": 700, "kind": "wildfire", "state": "UT"},
                {"id": "f", "name": "Oregon", "lat": 42.5, "lon": -113.6, "size": 60, "kind": "wildfire", "state": "OR"},
                {"id": "g", "name": "Nowhere", "size": 800, "kind": "wildfire", "state": "ID"}
            ],
            "byday": {"mon": {"hi": 51}, "tue": {"hi": "9"}, "wed": {"hi": 70}}
        });
        let m = map_response_with(&def, &root, 0, 42.536, -113.792, &BTreeMap::from([("min_size".to_string(), json!(10))])).unwrap();
        let keys: Vec<&str> = m.items.iter().map(|i| i.key.as_str()).collect();
        // group 1: Far is >100 mi away, Small is under the size limit, Rx is prescribed, Utah fails the OR, Nowhere has no point
        // -> Big (900) then Oregon (60); group 2: ascending by number (9, 51, 70); group 3: the two nearest of all seven with a point
        assert_eq!(keys, ["b", "f", "tue", "mon", "wed", "near-c", "near-d"]);
        assert_eq!(m.items[2].label, "Day tue");
        // distance sort: Small and Rx (4.4 mi) come before Oregon (10 mi)
        assert!(m.items[5].fields.0[0].1.contains("mi"), "{:?}", m.items[5].fields);
        // the same response with a lower limit on size
        let m = map_response_with(&def, &root, 0, 42.536, -113.792, &BTreeMap::from([("min_size".to_string(), json!(1))])).unwrap();
        assert!(m.items.iter().any(|i| i.key == "c"));
        // exists / missing
        let c = |v: Value| -> Cond { serde_json::from_value(v).unwrap() };
        let it = Item { key: "k".into(), label: "l".into(), time: None, ends: None, fields: Fields(vec![("N".into(), "12 mph".into())]), point: None, area: None };
        let r = json!({"x": 5, "s": "Hello World"});
        let cx = ctx(&r, &r, 0);
        assert!(cond_ok(&c(json!({"value":{"path":"x"},"exists":true})), &it, &cx));
        assert!(cond_ok(&c(json!({"value":{"path":"y"},"exists":false})), &it, &cx));
        assert!(!cond_ok(&c(json!({"value":{"path":"y"},"equals":1})), &it, &cx));
        assert!(cond_ok(&c(json!({"value":{"path":"y"},"not_equals":1})), &it, &cx));
        assert!(cond_ok(&c(json!({"field":"N","gt":10,"lt":13})), &it, &cx));
        assert!(!cond_ok(&c(json!({"field":"N","gt":12})), &it, &cx));
        assert!(cond_ok(&c(json!({"value":{"path":"s"},"contains":"lo wo"})), &it, &cx));
        assert!(cond_ok(&c(json!({"value":{"path":"s"},"starts_with":"hell"})), &it, &cx));
        assert!(cond_ok(&c(json!({"value":{"path":"x"},"in":[1,5]})), &it, &cx));
        // max_age_hours: relative to the fetch time (1_792_000_000 = 2026-10-14T17:46:40Z)
        let r = json!({"fresh": "2026-10-14T15:00:00Z", "stale": "2026-10-10T15:00:00Z", "ms": 1_791_990_000_000i64});
        let cx = ctx(&r, &r, 0);
        assert!(cond_ok(&c(json!({"value":{"path":"fresh"},"max_age_hours":6})), &it, &cx));
        assert!(!cond_ok(&c(json!({"value":{"path":"stale"},"max_age_hours":6})), &it, &cx));
        assert!(cond_ok(&c(json!({"value":{"path":"stale"},"max_age_hours":200})), &it, &cx));
        assert!(cond_ok(&c(json!({"value":{"path":"ms","time":{"in":"unix_ms"}},"max_age_hours":6})), &it, &cx));
        assert!(!cond_ok(&c(json!({"value":{"path":"nope"},"max_age_hours":6})), &it, &cx));
    }

    #[test]
    fn words() {
        assert_eq!(age_words(10), "less than a minute old");
        assert_eq!(age_words(60), "1 minute old");
        assert_eq!(age_words(25 * 60), "25 minutes old");
        assert_eq!(age_words(2 * 3600 + 5), "2 hours old");
        assert_eq!(age_words(86400), "1 day old");
        assert_eq!(age_words(3 * 86400 + 5), "3 days old");
        assert_eq!(stamp(0, &Zone::Fixed(-21600)), "1969-12-31T18:00:00-06:00");
        assert_eq!(date_of(0, &Zone::Fixed(3600)), "1970-01-01");
        assert_eq!(lead_num("54 acres"), Some(54.0));
        assert_eq!(lead_num("-3.5%"), Some(-3.5));
        assert_eq!(lead_num("x1"), None);
    }
}
