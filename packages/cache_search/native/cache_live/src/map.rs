//! The field mapping: a response JSON plus a source definition become items. Small and declarative: paths and
//! fixed formatting steps, no scripting.
//!
//! Paths: dot-separated keys, with `[n]` array indexes (`[-1]` = last). A path starts at the current element
//! (the element of the item group's `each` array, or the response root when there is none); `^` starts at the
//! response root instead; `@` is the current element itself. `[#]` is the index of the current element, so a
//! response that keeps one array per column (Open-Meteo's `daily`) is read with
//! `"each": "daily.time"` and `"path": "^daily.temperature_2m_max[#]"`.
//!
//! Formatting steps of a value, in this order: time conversion or (scale, offset, round, compass) or plain text;
//! `lookup` (replaces the result, keyed by the raw value); `omit_if`; `case`; `max_chars`; `prefix`/`suffix`.

use crate::def::{ItemDef, SourceDef, Spec, TimeSpec};
use crate::{Error, Result};
use crate::tz::Zone;
use chrono::{DateTime, Duration, FixedOffset, NaiveDate, NaiveDateTime};
use serde::{Deserialize, Serialize};
use serde_json::Value;

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

struct Ctx<'a> {
    root: &'a Value,
    cur: &'a Value,
    idx: usize,
    zone: &'a Zone,
    /// The place the data is for (distances are measured from it).
    lat: f64,
    lon: f64,
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

fn parse_time(v: &Value, t: &TimeSpec, zone: &Zone) -> Option<DateTime<FixedOffset>> {
    match t.input.as_str() {
        "unix" => {
            let secs = as_num(v)? as i64;
            Some(zone.convert(DateTime::from_timestamp(secs, 0)?.fixed_offset()))
        }
        "rfc3339" => DateTime::parse_from_rfc3339(v.as_str()?.trim()).ok(),
        _ => {
            let s = v.as_str()?.trim();
            let naive = NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M:%S")
                .or_else(|_| NaiveDateTime::parse_from_str(s, "%Y-%m-%dT%H:%M"))
                .ok()
                .or_else(|| NaiveDate::parse_from_str(s, "%Y-%m-%d").ok().and_then(|d| d.and_hms_opt(0, 0, 0)))?;
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
    // the raw value
    let (raw, base_text): (Option<Value>, Option<String>) = if !spec.first_of.is_empty() {
        (None, Some(spec.first_of.iter().find_map(|s| eval(s, ctx))?))
    } else if let Some(d) = &spec.distance {
        (None, Some(distance_text(d, ctx)?))
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
    } else {
        (Some(follow(ctx, spec.path.as_deref()?)?.clone()), None)
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
        write_time(parse_time(&v, t, ctx.zone)?, t, ctx.zone)
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

/// "6.2 mi S", or "inside the area".
fn distance_text(d: &crate::def::DistanceSpec, ctx: &Ctx) -> Option<String> {
    let near = crate::geo::nearest(follow(ctx, &d.geometry)?, ctx.lat, ctx.lon)?;
    if near.inside {
        return Some("inside the area".into());
    }
    let (v, unit) = if d.unit == "km" { (near.km, "km") } else { (near.km * 0.621_371_192, "mi") };
    let num = if v < 10.0 { format!("{v:.1}") } else { format!("{v:.0}") };
    Some(format!("{num} {unit} {}", compass(near.bearing)))
}

/// A time value as an instant (Unix seconds). A spec without `time` is read as RFC 3339.
fn eval_instant(spec: &Spec, ctx: &Ctx) -> Option<i64> {
    if !spec.first_of.is_empty() {
        return spec.first_of.iter().find_map(|s| eval_instant(s, ctx));
    }
    let v = follow(ctx, spec.path.as_deref()?)?;
    let default = TimeSpec { input: "rfc3339".into(), out: None, zone: None };
    parse_time(v, spec.time.as_ref().unwrap_or(&default), ctx.zone).map(|d| d.timestamp())
}

fn map_item(def: &ItemDef, ctx: &Ctx) -> Option<Item> {
    let key = eval(&def.key, ctx)?;
    let label = eval(&def.label, ctx)?;
    let fields: Vec<(String, String)> =
        def.fields.iter().filter_map(|f| Some((f.label.clone()?, eval(f, ctx)?))).collect();
    let point = def.point.as_ref().and_then(|p| {
        let lat: f64 = eval(&p.lat, ctx)?.parse().ok()?;
        let lon: f64 = eval(&p.lon, ctx)?.parse().ok()?;
        Some(Point { lat, lon })
    });
    Some(Item {
        key,
        label,
        time: def.time.as_ref().and_then(|t| eval(t, ctx)),
        ends: def.ends.as_ref().and_then(|e| eval_instant(e, ctx)),
        fields: Fields(fields),
        point,
        area: def.area.as_ref().and_then(|p| follow(ctx, p)).filter(|v| v.is_object()).cloned(),
    })
}

fn bad(m: String) -> Error {
    Error::bad_response(m)
}

/// The place's zone for a response: `timezone_path`, else `utc_offset_path`, else the offline lookup of the place,
/// else UTC.
pub fn zone_for(def: &SourceDef, root: &Value, lat: f64, lon: f64) -> Result<Zone> {
    let utc = Zone::UTC;
    let probe = Ctx { root, cur: root, idx: 0, zone: &utc, lat, lon };
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
    Text(String),
}

fn sort_keys(g: &ItemDef, ctx: &Ctx) -> Vec<Option<KeyVal>> {
    g.sort
        .iter()
        .map(|k| {
            if !k.rank.is_empty() {
                let v = eval(&k.by, ctx)?.to_lowercase();
                Some(KeyVal::Num(k.rank.iter().position(|r| r.to_lowercase() == v).unwrap_or(k.rank.len()) as i64))
            } else if k.time {
                eval_instant(&k.by, ctx).map(KeyVal::Num)
            } else {
                eval(&k.by, ctx).map(KeyVal::Text)
            }
        })
        .collect()
}

/// Map a response for a place at (`lat`, `lon`). `fetched_at` (Unix seconds) is only used for a fixed-hours validity.
pub fn map_response(def: &SourceDef, root: &Value, fetched_at: i64, lat: f64, lon: f64) -> Result<Mapped> {
    let zone = zone_for(def, root, lat, lon)?;
    let at = |cur| Ctx { root, cur, idx: 0, zone: &zone, lat, lon };
    for p in &def.require {
        if follow(&at(root), p).is_none() {
            return Err(bad(format!("the response has no {p:?}")));
        }
    }
    let mut items = Vec::new();
    for g in &def.items {
        let mut group: Vec<(Vec<Option<KeyVal>>, Item)> = Vec::new();
        match &g.each {
            Some(p) => {
                let arr = follow(&at(root), p).and_then(Value::as_array).ok_or_else(|| bad(format!("no list at {p:?}")))?;
                for (i, el) in arr.iter().enumerate() {
                    let ctx = Ctx { root, cur: el, idx: i, zone: &zone, lat, lon };
                    if let Some(it) = map_item(g, &ctx) {
                        group.push((sort_keys(g, &ctx), it));
                    }
                }
            }
            None => {
                let ctx = at(root);
                if let Some(it) = map_item(g, &ctx) {
                    group.push((sort_keys(g, &ctx), it));
                }
            }
        }
        if !g.sort.is_empty() {
            group.sort_by(|a, b| {
                for (i, k) in g.sort.iter().enumerate() {
                    // missing values last, whatever the direction
                    let o = match (&a.0[i], &b.0[i]) {
                        (None, None) => std::cmp::Ordering::Equal,
                        (None, Some(_)) => return std::cmp::Ordering::Greater,
                        (Some(_), None) => return std::cmp::Ordering::Less,
                        (Some(x), Some(y)) => x.partial_cmp(y).unwrap_or(std::cmp::Ordering::Equal),
                    };
                    let o = if k.desc { o.reverse() } else { o };
                    if o != std::cmp::Ordering::Equal {
                        return o;
                    }
                }
                std::cmp::Ordering::Equal
            });
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
    let ctx = Ctx { root, cur: root, idx: 0, zone, lat, lon };
    let val = follow(&ctx, path).ok_or_else(|| bad(format!("no end time at {path:?}")))?;
    let local = TimeSpec { input: "local".into(), out: None, zone: None };
    let rfc = TimeSpec { input: "rfc3339".into(), out: None, zone: None };
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
    fn ctx<'a>(root: &'a Value, cur: &'a Value, idx: usize) -> Ctx<'a> {
        Ctx { root, cur, idx, zone: &Z, lat: 42.536, lon: -113.792 }
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
        assert_eq!(eval(&spec(json!({"path":"u","omit_if":["severe"]})), &c), None);
        assert_eq!(eval(&spec(json!({"path":"missing"})), &c), None);
        assert_eq!(eval(&spec(json!({"const":"Now"})), &c).unwrap(), "Now");
        assert_eq!(eval(&spec(json!({"first_of":[{"path":"nope"},{"path":"c"}]})), &c).unwrap(), "3");
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
    fn words() {
        assert_eq!(age_words(10), "less than a minute old");
        assert_eq!(age_words(60), "1 minute old");
        assert_eq!(age_words(25 * 60), "25 minutes old");
        assert_eq!(age_words(2 * 3600 + 5), "2 hours old");
        assert_eq!(age_words(86400), "1 day old");
        assert_eq!(age_words(3 * 86400 + 5), "3 days old");
        assert_eq!(stamp(0, &Zone::Fixed(-21600)), "1969-12-31T18:00:00-06:00");
        assert_eq!(date_of(0, &Zone::Fixed(3600)), "1970-01-01");
    }
}
