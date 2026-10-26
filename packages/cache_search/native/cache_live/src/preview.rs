//! `cs_live_preview`: for a person (or a future in-app builder) writing a connector. Takes a definition as text plus a
//! place and parameters, checks it, fetches once and returns the raw response tree (cut down so it can be read) with the
//! paths in it, and the items the definition maps. Stores nothing: no database, no quota, no saved response.

use crate::def::SourceDef;
use crate::fetch::{check_secrets, secrets_of};
use crate::map::{map_response_with, stamp, Item};
use crate::request::{execute, PlaceInfo, RunCtx};
use crate::{now_from, params, Error, Place, Result};
use serde::Deserialize;
use serde_json::{json, Map, Value};

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Req {
    /// The definition: a JSON object, or its text.
    definition: Value,
    /// `{lat, lon, name?, key?, state?, county?, country?, ...}`; not needed with `check_only`.
    #[serde(default)]
    place: Option<Value>,
    #[serde(default)]
    params: Option<Map<String, Value>>,
    #[serde(default)]
    api_key: Option<String>,
    #[serde(default)]
    secrets: Option<Map<String, Value>>,
    #[serde(default)]
    now: Option<String>,
    /// Only parse and validate: no network.
    #[serde(default)]
    check_only: bool,
    /// About how many characters of raw tree to return (default 12000).
    #[serde(default)]
    raw_chars: Option<usize>,
    /// How many mapped items to return (default 20).
    #[serde(default)]
    max_items: Option<usize>,
}

/// The raw tree cut down: long lists keep their first few elements and say how many were left out; long text is cut.
fn shrink(v: &Value, depth: usize, list: usize, text: usize) -> Value {
    match v {
        Value::String(s) if s.chars().count() > text => Value::String(format!("{}\u{2026}", s.chars().take(text).collect::<String>())),
        Value::Array(a) => {
            if depth == 0 {
                return Value::String(format!("[\u{2026} {} items]", a.len()));
            }
            let mut out: Vec<Value> = a.iter().take(list).map(|x| shrink(x, depth - 1, list, text)).collect();
            if a.len() > list {
                out.push(Value::String(format!("\u{2026} {} more", a.len() - list)));
            }
            Value::Array(out)
        }
        Value::Object(o) => {
            if depth == 0 {
                return Value::String(format!("{{\u{2026} {} keys}}", o.len()));
            }
            let mut m = Map::new();
            for (k, x) in o.iter().take(40) {
                m.insert(k.clone(), shrink(x, depth - 1, list, text));
            }
            if o.len() > 40 {
                m.insert("\u{2026}".into(), Value::String(format!("{} more keys", o.len() - 40)));
            }
            Value::Object(m)
        }
        other => other.clone(),
    }
}

/// Every path to a value, in the syntax the mapping uses, with a sample (first element of each list).
fn paths(v: &Value, at: &str, out: &mut Vec<String>) {
    if out.len() >= 400 {
        return;
    }
    match v {
        Value::Object(o) => {
            for (k, x) in o {
                let p = if at.is_empty() { k.clone() } else { format!("{at}.{k}") };
                paths(x, &p, out);
            }
        }
        Value::Array(a) => {
            let here = if at.is_empty() { "^".to_string() } else { at.to_string() };
            out.push(format!("{here}  (list of {})", a.len()));
            if let Some(f) = a.first() {
                paths(f, &format!("{at}[0]"), out);
            }
        }
        Value::String(s) => out.push(format!("{at} = {:?}", if s.chars().count() > 50 { format!("{}\u{2026}", s.chars().take(50).collect::<String>()) } else { s.clone() })),
        Value::Null => out.push(format!("{at} = null")),
        other => out.push(format!("{at} = {other}")),
    }
}

fn summary(d: &SourceDef) -> Value {
    json!({
        "id": d.id, "title": d.title, "provider": d.provider, "format": d.format,
        "refresh_minutes": d.refresh_minutes,
        "needs_key": d.api_key.as_ref().map(|k| k.alias.clone()),
        "needs_login": d.basic_auth.as_ref().map(|b| json!({"user": b.user_alias, "password": b.password_alias})),
        "params": d.params,
        "items": d.items.len(),
    })
}

fn warnings(d: &SourceDef) -> Vec<String> {
    let mut w = Vec::new();
    if d.require.is_empty() {
        w.push("require is empty: a response of a different shape would be mapped to nothing instead of being rejected".to_string());
    }
    if d.quota.per_minute.is_none() && d.quota.per_day.is_none() && d.quota.per_month.is_none() {
        w.push("quota is empty: set the provider's published limits (or a polite cap)".to_string());
    }
    if d.attribution.is_none() {
        w.push("attribution is empty: give the provider's credit line".to_string());
    }
    w
}

/// `cs_live_preview`. See the module doc and `cache_search.h`.
pub fn preview(req_json: &str) -> Result<String> {
    let r: Req = serde_json::from_str(req_json).map_err(|e| Error::bad_json(format!("request_json: {e}")))?;
    let text = match &r.definition {
        Value::String(s) => s.clone(),
        o @ Value::Object(_) => o.to_string(),
        _ => return Err(Error::bad_json("definition must be a JSON object or its text")),
    };
    let def = SourceDef::parse(&text)?;
    if r.check_only {
        let reqs: Vec<Value> = def
            .requests()
            .iter()
            .map(|q| json!({"step": q.id.clone().unwrap_or_else(|| "main".into()), "method": q.method.clone().unwrap_or_else(|| "GET".into()), "url": q.url}))
            .collect();
        return Ok(serde_json::to_string(&json!({"valid": true, "source": summary(&def), "requests": reqs, "warnings": warnings(&def)}))?);
    }
    let pv = r.place.as_ref().ok_or_else(|| Error::bad_json("\"place\" ({lat, lon, name?, state?, county?, country?}) is required"))?;
    let lat = pv.get("lat").and_then(Value::as_f64).filter(|v| v.abs() <= 90.0);
    let lon = pv.get("lon").and_then(Value::as_f64).filter(|v| v.abs() <= 180.0);
    let (Some(lat), Some(lon)) = (lat, lon) else { return Err(Error::bad_json("place needs lat and lon in degrees")) };
    let place = Place { key: "preview".into(), name: pv.get("name").and_then(Value::as_str).unwrap_or("Preview place").to_string(), lat, lon };
    let info = PlaceInfo::from_value(Some(pv));
    let par = params::resolve(&def, r.params.as_ref())?;
    let secrets = secrets_of(&def, r.api_key.as_deref(), r.secrets.as_ref());
    check_secrets(&def, &secrets)?;
    let now = now_from(r.now.as_deref())?;
    let out = execute(&RunCtx { def: &def, place: &place, info: &info, params: &par, secrets: &secrets, now }, &mut || Ok(()))?;

    let budget = r.raw_chars.unwrap_or(12_000);
    let mut raw = Value::Null;
    for (depth, list, text) in [(8, 3, 120), (7, 2, 80), (5, 2, 60), (3, 1, 40), (2, 1, 30)] {
        raw = shrink(&out.tree, depth, list, text);
        if raw.to_string().len() <= budget {
            break;
        }
    }
    let mut ps = Vec::new();
    paths(&out.tree, "", &mut ps);

    let mut o = Map::new();
    o.insert("valid".into(), json!(true));
    o.insert("source".into(), summary(&def));
    o.insert("place".into(), json!(place));
    o.insert("params".into(), json!(par));
    o.insert("requests".into(), json!(out.log));
    o.insert("truncated".into(), json!(out.truncated));
    if out.skipped > 0 {
        o.insert("missing_requests".into(), json!(out.skipped));
    }
    o.insert("raw".into(), raw);
    o.insert("paths".into(), json!(ps));
    match map_response_with(&def, &out.tree, now, place.lat, place.lon, &par) {
        Ok(m) => {
            let shown: Vec<&Item> = m.items.iter().take(r.max_items.unwrap_or(20)).collect();
            o.insert("zone".into(), json!(m.zone.name().map(str::to_string)));
            o.insert("valid_until".into(), json!(stamp(m.valid_until, &m.zone)));
            if let Some(n) = &m.not_covered_after {
                o.insert("not_covered_after".into(), json!(n));
            }
            o.insert("item_count".into(), json!(m.items.len()));
            o.insert("items".into(), serde_json::to_value(&shown)?);
        }
        Err(e) => {
            // the builder still gets the raw tree to find the paths
            o.insert("mapping_error".into(), json!({"code": e.code, "message": e.message}));
            o.insert("item_count".into(), json!(0));
            o.insert("items".into(), json!([]));
        }
    }
    o.insert("warnings".into(), json!(warnings(&def)));
    Ok(serde_json::to_string(&Value::Object(o))?)
}
