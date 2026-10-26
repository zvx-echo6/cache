//! Running a definition's request: placeholders, authentication, POST bodies, steps, paging, rate-limit retries and
//! the conversion of the response into one tree. No database here (the caller supplies a `gate` that is asked before
//! every HTTP request, for quotas), so `cs live-preview` runs the same code and stores nothing.

use crate::convert::{gunzip_if_needed, to_tree};
use crate::def::{ParamDef, RequestDef, SourceDef, DEFAULT_MAX_BYTES, DEFAULT_TIMEOUT_S, MAX_FAN_OUT, MAX_PAGES};
use crate::map::{lookup, plain_text, Params};
use crate::{Error, Place, Result};
use base64::Engine as _;
use chrono::DateTime;
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use serde_json::{Map, Value};
use std::collections::BTreeMap;
use std::io::Read;
use std::time::{Duration, Instant};

const UNRESERVED: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'_').remove(b'.').remove(b'~');

pub fn enc(s: &str) -> String {
    utf8_percent_encode(s, UNRESERVED).to_string()
}

/// The generic User-Agent of every fetch. NWS requires one; it never names a person.
pub fn user_agent() -> String {
    format!("Cache/{}", env!("CARGO_PKG_VERSION"))
}

/// What the caller knows about a place beyond its position. Filled from optional members of the request's place object
/// (`state`, `state_name`, `county`, `county_fips`, `country`, `country_name`), which the app's geocoder provides.
#[derive(Debug, Clone, Default)]
pub struct PlaceInfo {
    pub state: Option<String>,
    pub state_name: Option<String>,
    pub county: Option<String>,
    pub county_fips: Option<String>,
    pub country: Option<String>,
    pub country_name: Option<String>,
}

impl PlaceInfo {
    pub fn from_value(v: Option<&Value>) -> PlaceInfo {
        let g = |k: &str| v.and_then(|v| v.get(k)).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(str::to_string);
        PlaceInfo { state: g("state"), state_name: g("state_name"), county: g("county"), county_fips: g("county_fips"), country: g("country"), country_name: g("country_name") }
    }
}

/// The secrets of one fetch, by alias. Used for this call only.
#[derive(Debug, Clone, Default)]
pub struct Secrets {
    pub by_alias: BTreeMap<String, String>,
}

impl Secrets {
    fn values(&self, def: &SourceDef) -> Vec<String> {
        let mut v: Vec<String> = self.by_alias.values().filter(|s| !s.is_empty()).cloned().collect();
        if let (Some(b), Some(u), Some(p)) = (&def.basic_auth, self.by_alias.get(def.basic_auth.as_ref().map(|b| b.user_alias.as_str()).unwrap_or("")), self.by_alias.get(def.basic_auth.as_ref().map(|b| b.password_alias.as_str()).unwrap_or(""))) {
            let _ = b;
            v.push(base64::engine::general_purpose::STANDARD.encode(format!("{u}:{p}")));
        }
        v
    }
}

fn scrub(mut s: String, secrets: &[String]) -> String {
    for k in secrets {
        if !k.is_empty() {
            s = s.replace(k.as_str(), "***").replace(&enc(k), "***");
        }
    }
    s
}

/// https always; plain http only to the machine itself (tests and a local server).
pub fn check_url(url: &str) -> Result<()> {
    if url.starts_with("https://") {
        return Ok(());
    }
    if let Some(r) = url.strip_prefix("http://") {
        let host = r.split(['/', '?', '#']).next().unwrap_or("");
        let host = host.rsplit('@').next().unwrap_or("");
        let host = if host.starts_with('[') { host.split(']').next().unwrap_or("").trim_start_matches('[') } else { host.split(':').next().unwrap_or("") };
        if host == "127.0.0.1" || host == "localhost" || host == "::1" {
            return Ok(());
        }
    }
    Err(Error::bad_json("a source must use https (http is allowed only to this machine)"))
}

fn host_of(url: &str) -> String {
    let r = url.split_once("://").map(|x| x.1).unwrap_or(url);
    let r = r.split(['/', '?', '#']).next().unwrap_or("");
    r.rsplit('@').next().unwrap_or("").to_ascii_lowercase()
}

// ---------------------------------------------------------------- placeholders

const BUILTIN: &[&str] = &[
    "lat", "lon", "latlon", "lonlat", "lat_abs", "lon_abs", "lat_hem", "lon_hem", "name", "place_key", "api_key", "state", "state_name", "county",
    "county_fips", "country", "country_name", "bbox", "west", "south", "east", "north", "param", "secret",
];

fn time_offset(name: &str) -> Option<i64> {
    let rest = name.strip_prefix("now")?;
    if rest.is_empty() {
        return Some(0);
    }
    let sign = match rest.as_bytes()[0] {
        b'+' => 1,
        b'-' => -1,
        _ => return None,
    };
    let body = &rest[1..];
    let unit = body.chars().last()?;
    let n: i64 = body[..body.len() - 1].parse().ok()?;
    let secs = match unit {
        's' => 1,
        'm' => 60,
        'h' => 3600,
        'd' => 86400,
        _ => return None,
    };
    Some(sign * n * secs)
}

/// Static check of one `{hole}` of a definition (does the name exist; does the parameter exist).
pub fn check_placeholder(hole: &str, params: &[ParamDef], loopvars: &[&str]) -> std::result::Result<(), String> {
    let hole = hole.strip_suffix("|raw").unwrap_or(hole);
    let (name, arg) = match hole.split_once(':') {
        Some((n, a)) => (n, Some(a)),
        None => (hole, None),
    };
    if name.is_empty() {
        return Err("empty".into());
    }
    if time_offset(name).is_some() {
        return Ok(());
    }
    if name.starts_with("now") && name.len() > 3 && !BUILTIN.contains(&name) {
        return Err("a time is now, now-24h, now+3d (s, m, h, d)".into());
    }
    if BUILTIN.contains(&name) {
        match name {
            "param" => {
                let a = arg.ok_or("needs a parameter name: {param:name}")?;
                if !params.iter().any(|p| p.name == a) {
                    return Err(format!("no parameter called {a:?} (declare it in params)"));
                }
            }
            "secret" => {
                arg.ok_or("needs an alias: {secret:alias}")?;
            }
            "lat" | "lon" | "latlon" | "lonlat" | "lat_abs" | "lon_abs" => {
                if let Some(a) = arg {
                    a.parse::<usize>().map_err(|_| "the number after : is the decimals".to_string())?;
                }
            }
            "bbox" | "west" | "south" | "east" | "north" => {
                arg.ok_or("needs a radius: {bbox:50km} or {bbox:$param:km}")?;
            }
            _ => {}
        }
        return Ok(());
    }
    // a step id or a for_each name: letters, digits, _
    if name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        let _ = loopvars;
        return Ok(());
    }
    Err("not a known placeholder".into())
}

pub struct Expander<'a> {
    pub place: &'a Place,
    pub info: &'a PlaceInfo,
    pub params: &'a Params,
    pub secrets: &'a Secrets,
    pub api_key_alias: Option<&'a str>,
    pub now: i64,
    pub steps: &'a Map<String, Value>,
    pub vars: BTreeMap<String, Value>,
}

#[derive(Clone, Copy, PartialEq)]
pub enum Mode {
    /// Values are percent-encoded (a URL or a form), except those marked `|raw`.
    Encoded,
    /// Values go in as they are (a header, a JSON string).
    Plain,
}

fn need<'x>(v: &'x Option<String>, what: &str, place: &Place) -> Result<&'x str> {
    v.as_deref().ok_or_else(|| Error::fetch_failed(format!("this source needs the place's {what}, which is not known for {}", place.name)))
}

fn radius_km(arg: &str, params: &Params) -> Result<f64> {
    let (first, unit) = match arg.split_once(':') {
        Some((a, u)) => (a, Some(u)),
        None => (arg, None),
    };
    let bad = || Error::bad_json(format!("bad radius {arg:?}: write 50km, 30mi or $param:km"));
    let (n, u): (f64, &str) = if let Some(p) = first.strip_prefix('$') {
        let v = params.get(p).ok_or_else(bad)?;
        (v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse().ok())).ok_or_else(bad)?, unit.unwrap_or("km"))
    } else {
        let i = first.find(|c: char| !(c.is_ascii_digit() || c == '.')).ok_or_else(bad)?;
        (first[..i].parse().map_err(|_| bad())?, &first[i..])
    };
    match u {
        "km" => Ok(n),
        "mi" => Ok(n * 1.609_344),
        "m" => Ok(n / 1000.0),
        _ => Err(bad()),
    }
}

/// West, south, east, north in degrees of a box of half-width `km` around the place.
pub fn bbox(lat: f64, lon: f64, km: f64) -> (f64, f64, f64, f64) {
    let dlat = km / 111.32;
    let dlon = km / (111.32 * lat.to_radians().cos().max(0.01));
    ((lon - dlon).max(-180.0), (lat - dlat).max(-90.0), (lon + dlon).min(180.0), (lat + dlat).min(90.0))
}

impl<'a> Expander<'a> {
    pub fn expand(&self, t: &str, mode: Mode) -> Result<String> {
        let mut out = String::new();
        let mut rest = t;
        while let Some(i) = rest.find('{') {
            out.push_str(&rest[..i]);
            let j = rest[i..].find('}').ok_or_else(|| Error::bad_json(format!("unclosed {{ in {t:?}")))? + i;
            let hole = &rest[i + 1..j];
            let (hole, raw) = match hole.strip_suffix("|raw") {
                Some(h) => (h, true),
                None => (hole, false),
            };
            let v = self.value(hole)?;
            out.push_str(&if mode == Mode::Encoded && !raw { enc(&v) } else { v });
            rest = &rest[j + 1..];
        }
        out.push_str(rest);
        Ok(out)
    }

    /// The value of one hole as text; `Some(Value)` typed for a lone `{param:x}` (see `body_value`).
    fn value(&self, hole: &str) -> Result<String> {
        let (name, arg) = match hole.split_once(':') {
            Some((n, a)) => (n, Some(a)),
            None => (hole, None),
        };
        let dec = |d: Option<&str>| -> Result<usize> {
            match d {
                None => Ok(4),
                Some(d) => d.parse::<usize>().map_err(|_| Error::bad_json(format!("bad placeholder {{{hole}}}"))),
            }
        };
        let (lat, lon) = (self.place.lat, self.place.lon);
        Ok(match name {
            "lat" => format!("{:.*}", dec(arg)?, lat),
            "lon" => format!("{:.*}", dec(arg)?, lon),
            "latlon" => format!("{:.*},{:.*}", dec(arg)?, lat, dec(arg)?, lon),
            "lonlat" => format!("{:.*},{:.*}", dec(arg)?, lon, dec(arg)?, lat),
            "lat_abs" => format!("{:.*}", dec(arg)?, lat.abs()),
            "lon_abs" => format!("{:.*}", dec(arg)?, lon.abs()),
            "lat_hem" => (if lat >= 0.0 { "N" } else { "S" }).into(),
            "lon_hem" => (if lon >= 0.0 { "E" } else { "W" }).into(),
            "name" => self.place.name.clone(),
            "place_key" => self.place.key.clone(),
            "api_key" => {
                let alias = self.api_key_alias.ok_or_else(|| Error::bad_json("{api_key} is used but the source declares no api_key"))?;
                self.secrets.by_alias.get(alias).cloned().ok_or_else(|| Error::key_missing("this source needs an API key"))?
            }
            "secret" => {
                let a = arg.unwrap_or("");
                self.secrets.by_alias.get(a).cloned().ok_or_else(|| Error::key_missing(format!("this source needs the secret {a:?}")))?
            }
            "state" => need(&self.info.state, "state", self.place)?.to_string(),
            "state_name" => need(&self.info.state_name, "state name", self.place)?.to_string(),
            "county" => need(&self.info.county, "county", self.place)?.to_string(),
            "county_fips" => need(&self.info.county_fips, "county code", self.place)?.to_string(),
            "country" => need(&self.info.country, "country", self.place)?.to_string(),
            "country_name" => need(&self.info.country_name, "country name", self.place)?.to_string(),
            "bbox" | "west" | "south" | "east" | "north" => {
                let km = radius_km(arg.unwrap_or(""), self.params)?;
                let (w, s, e, n) = bbox(lat, lon, km);
                match name {
                    "bbox" => format!("{w:.4},{s:.4},{e:.4},{n:.4}"),
                    "west" => format!("{w:.4}"),
                    "south" => format!("{s:.4}"),
                    "east" => format!("{e:.4}"),
                    _ => format!("{n:.4}"),
                }
            }
            "param" => {
                let a = arg.unwrap_or("");
                let v = self.params.get(a).ok_or_else(|| Error::bad_json(format!("parameter {a:?} has no value")))?;
                plain_text(v).unwrap_or_default()
            }
            n if time_offset(n).is_some() => {
                let t = self.now + time_offset(n).unwrap_or(0);
                match arg {
                    Some("unix") => t.to_string(),
                    Some("unix_ms") => (t * 1000).to_string(),
                    other => DateTime::from_timestamp(t, 0)
                        .map(|d| d.format(other.unwrap_or("%Y-%m-%dT%H:%M:%SZ")).to_string())
                        .ok_or_else(|| Error::bad_json("bad time"))?,
                }
            }
            n => {
                let root = self.vars.get(n).or_else(|| self.steps.get(n)).ok_or_else(|| Error::bad_json(format!("unknown placeholder {{{hole}}}: no earlier step or value called {n:?}")))?;
                let v = match arg {
                    None => plain_text(root),
                    Some(p) => lookup(root, p).and_then(plain_text),
                };
                v.ok_or_else(|| Error::fetch_failed(format!("an earlier response has no {hole:?}")))?
            }
        })
    }

    /// A JSON body: strings take placeholders; a string that is exactly one `{param:x}` keeps the parameter's type.
    fn body_value(&self, v: &Value) -> Result<Value> {
        Ok(match v {
            Value::String(s) => {
                if let Some(h) = s.strip_prefix("{param:").and_then(|r| r.strip_suffix('}')) {
                    if !h.contains('{') {
                        if let Some(pv) = self.params.get(h) {
                            return Ok(pv.clone());
                        }
                    }
                }
                Value::String(self.expand(s, Mode::Plain)?)
            }
            Value::Array(a) => Value::Array(a.iter().map(|x| self.body_value(x)).collect::<Result<_>>()?),
            Value::Object(o) => Value::Object(o.iter().map(|(k, x)| Ok((k.clone(), self.body_value(x)?))).collect::<Result<Map<_, _>>>()?),
            other => other.clone(),
        })
    }
}

/// Set (or add) one query parameter of a URL.
pub fn set_query_param(url: &str, name: &str, value: &str) -> String {
    let (base, frag) = match url.split_once('#') {
        Some((b, f)) => (b, Some(f)),
        None => (url, None),
    };
    let (path, query) = match base.split_once('?') {
        Some((p, q)) => (p, q),
        None => (base, ""),
    };
    let mut pairs: Vec<String> = query.split('&').filter(|p| !p.is_empty() && p.split('=').next() != Some(name)).map(str::to_string).collect();
    pairs.push(format!("{}={}", name, enc(value)));
    let mut out = format!("{path}?{}", pairs.join("&"));
    if let Some(f) = frag {
        out.push('#');
        out.push_str(f);
    }
    out
}

// ---------------------------------------------------------------- running

#[derive(Debug, Clone, serde::Serialize)]
pub struct ReqLog {
    pub step: String,
    pub method: String,
    pub url: String,
    pub status: u16,
    pub bytes: usize,
    pub ms: u64,
}

pub struct Outcome {
    /// What the mapping reads: the response tree, or (with `steps`) an object with one member per step id.
    pub tree: Value,
    /// A paged result was cut at `max_pages` with more data left.
    pub truncated: bool,
    /// Repeated requests (`for_each`) that failed and were left out.
    pub skipped: usize,
    pub log: Vec<ReqLog>,
}

pub struct RunCtx<'a> {
    pub def: &'a SourceDef,
    pub place: &'a Place,
    pub info: &'a PlaceInfo,
    pub params: &'a Params,
    pub secrets: &'a Secrets,
    pub now: i64,
}

struct Runner<'a, 'g> {
    rc: &'a RunCtx<'a>,
    gate: &'g mut dyn FnMut() -> Result<()>,
    log: Vec<ReqLog>,
    truncated: bool,
    skipped: usize,
    scrub: Vec<String>,
    static_hosts: Vec<String>,
    used_hosts: Vec<String>,
    /// Sleeps are skipped in tests that set this (Retry-After still decides what is waited for).
    max_wait_s: u64,
}

/// Run the definition's request(s) and give back the tree to map. `gate` is called before every HTTP request (quota check
/// and count); an error from it stops the run.
pub fn execute(rc: &RunCtx, gate: &mut dyn FnMut() -> Result<()>) -> Result<Outcome> {
    let def = rc.def;
    let mut static_hosts = Vec::new();
    for r in def.requests() {
        if let Some(u) = &r.url {
            if u.starts_with("http") {
                let h = host_of(u);
                if !h.contains('{') {
                    static_hosts.push(h);
                }
            }
        }
    }
    let mut run = Runner { rc, gate, log: Vec::new(), truncated: false, skipped: 0, scrub: rc.secrets.values(def), static_hosts, used_hosts: Vec::new(), max_wait_s: 60 };
    let tree = if def.request.steps.is_empty() {
        let empty = Map::new();
        let exp = expander(rc, &empty, BTreeMap::new());
        run.run_http(&def.request, "main", &exp)?
    } else {
        let mut results: Map<String, Value> = Map::new();
        for s in &def.request.steps {
            let id = s.id.clone().unwrap_or_default();
            let merged = merge(&def.request, s);
            let v = match &s.for_each {
                None => {
                    let exp = expander(rc, &results, BTreeMap::new());
                    run.run_http(&merged, &id, &exp)?
                }
                Some(f) => {
                    let src = results.get(&f.from).ok_or_else(|| Error::internal(format!("step {} runs before {}", id, f.from)))?;
                    let list = lookup(src, &f.path).and_then(Value::as_array).cloned().unwrap_or_default();
                    let limit = f.limit.unwrap_or(10).min(MAX_FAN_OUT) as usize;
                    let mut outs = Vec::new();
                    let mut last_err = None;
                    for el in list.iter().take(limit) {
                        let mut vars = BTreeMap::new();
                        vars.insert(f.name.clone(), el.clone());
                        let exp = expander(rc, &results, vars);
                        match run.run_http(&merged, &id, &exp) {
                            Ok(v) => outs.push(v),
                            Err(e) if e.code == "quota" || e.code == "key_missing" || e.code == "bad_json" => return Err(e),
                            Err(e) => {
                                run.skipped += 1;
                                last_err = Some(e);
                            }
                        }
                    }
                    if outs.is_empty() && !list.is_empty() {
                        return Err(last_err.unwrap_or_else(|| Error::fetch_failed("every repeated request failed")));
                    }
                    Value::Array(outs)
                }
            };
            results.insert(id, v);
        }
        Value::Object(results)
    };
    Ok(Outcome { tree, truncated: run.truncated, skipped: run.skipped, log: run.log })
}

/// A step with the shared settings of the top-level request under it.
fn merge(top: &RequestDef, s: &RequestDef) -> RequestDef {
    let mut m = s.clone();
    let mut h = top.headers.clone();
    h.extend(s.headers.clone());
    m.headers = h;
    m.timeout_seconds = s.timeout_seconds.or(top.timeout_seconds);
    m.max_bytes = s.max_bytes.or(top.max_bytes);
    m
}

fn expander<'x>(rc: &'x RunCtx<'x>, steps: &'x Map<String, Value>, vars: BTreeMap<String, Value>) -> Expander<'x> {
    Expander {
        place: rc.place,
        info: rc.info,
        params: rc.params,
        secrets: rc.secrets,
        api_key_alias: rc.def.api_key.as_ref().map(|k| k.alias.as_str()),
        now: rc.now,
        steps,
        vars,
    }
}

impl<'a, 'g> Runner<'a, 'g> {
    fn run_http(&mut self, r: &RequestDef, step: &str, exp: &Expander) -> Result<Value> {
        let url0 = exp.expand(r.url.as_deref().ok_or_else(|| Error::bad_json("a request has no url"))?, Mode::Encoded)?;
        check_url(&url0)?;
        let mut headers = BTreeMap::new();
        for (k, v) in &r.headers {
            headers.insert(k.clone(), exp.expand(v, Mode::Plain)?);
        }
        let body = self.build_body(r, exp)?;
        let kind = r.response.as_deref();
        let fetch = |this: &mut Self, url: &str| -> Result<Value> {
            let bytes = this.send(r, step, url, &headers, body.as_ref())?;
            to_tree(&bytes, kind, r.table.as_ref(), r.xml.as_ref())
        };
        let Some(p) = &r.paging else {
            return fetch(self, &url0);
        };
        let max_pages = p.max_pages.unwrap_or(5).clamp(1, MAX_PAGES);
        let size = p.page_size.unwrap_or(0) as usize;
        let mut pages: Vec<Value> = Vec::new();
        let mut counter: u64 = match p.kind.as_str() {
            "page" => p.start.unwrap_or(1) as u64,
            _ => p.start.unwrap_or(0) as u64,
        };
        let mut cursor: Option<String> = None;
        let mut next_url = url0.clone();
        for n in 0..max_pages {
            let mut u = match p.kind.as_str() {
                "offset" | "page" => set_query_param(&url0, p.param.as_deref().unwrap_or(""), &counter.to_string()),
                "cursor" => match &cursor {
                    Some(c) => set_query_param(&url0, p.param.as_deref().unwrap_or(""), c),
                    None => url0.clone(),
                },
                _ => next_url.clone(),
            };
            if let (Some(sp), true) = (&p.size_param, size > 0) {
                u = set_query_param(&u, sp, &size.to_string());
            }
            check_url(&u)?;
            let tree = fetch(self, &u)?;
            let len = list_of(&tree, &p.list_path).map(|l| l.len()).unwrap_or(0);
            let more_flag = p.more_path.as_deref().map(|mp| truthy(lookup(&tree, mp)));
            let next = p.next_path.as_deref().and_then(|np| lookup(&tree, np)).and_then(plain_text).filter(|s| !s.is_empty());
            pages.push(tree);
            let more = match p.kind.as_str() {
                "offset" | "page" => {
                    counter += if p.kind == "offset" { size as u64 } else { 1 };
                    len > 0 && more_flag.unwrap_or(len >= size)
                }
                "cursor" => {
                    cursor = next.clone();
                    len > 0 && next.is_some() && more_flag.unwrap_or(true)
                }
                _ => match &next {
                    Some(nx) => {
                        let abs = if nx.starts_with('/') {
                            let o: String = url0.splitn(4, '/').take(3).collect::<Vec<_>>().join("/");
                            format!("{o}{nx}")
                        } else {
                            nx.clone()
                        };
                        if host_of(&abs) != host_of(&url0) {
                            return Err(Error::bad_response("the next page is on another host"));
                        }
                        next_url = abs;
                        len > 0 && more_flag.unwrap_or(true)
                    }
                    None => false,
                },
            };
            if !more {
                break;
            }
            if n + 1 == max_pages {
                self.truncated = true;
            }
        }
        // join the lists of all pages into the first page
        let mut it = pages.into_iter();
        let mut first = it.next().ok_or_else(|| Error::internal("no page"))?;
        for pg in it {
            let extra: Vec<Value> = list_of(&pg, &p.list_path).cloned().unwrap_or_default();
            if let Some(l) = list_mut(&mut first, &p.list_path) {
                l.extend(extra);
            }
        }
        Ok(first)
    }

    fn build_body(&self, r: &RequestDef, exp: &Expander) -> Result<Option<(String, Vec<u8>)>> {
        let Some(b) = &r.body else { return Ok(None) };
        Ok(Some(match r.body_type.as_deref().unwrap_or("json") {
            "form" => {
                let o = b.as_object().ok_or_else(|| Error::bad_json("a form body is an object"))?;
                let mut pairs = Vec::new();
                for (k, v) in o {
                    let text = match v {
                        Value::String(s) => exp.expand(s, Mode::Plain)?,
                        other => plain_text(other).unwrap_or_default(),
                    };
                    pairs.push(format!("{}={}", enc(k), enc(&text)));
                }
                ("application/x-www-form-urlencoded".to_string(), pairs.join("&").into_bytes())
            }
            "text" => ("text/plain; charset=utf-8".to_string(), exp.expand(b.as_str().unwrap_or(""), Mode::Plain)?.into_bytes()),
            _ => ("application/json".to_string(), serde_json::to_vec(&exp.body_value(b)?)?),
        }))
    }

    fn send(&mut self, r: &RequestDef, step: &str, url: &str, headers: &BTreeMap<String, String>, body: Option<&(String, Vec<u8>)>) -> Result<Vec<u8>> {
        let def = self.rc.def;
        // a url taken from a response may not carry the user's secrets to another host
        let host = host_of(url);
        if (def.api_key.is_some() || def.basic_auth.is_some()) && !self.static_hosts.contains(&host) && !self.used_hosts.contains(&host) {
            return Err(Error::bad_response(format!("a response pointed at {host}, which the definition does not name; not sent with the key")));
        }
        if !self.used_hosts.contains(&host) {
            self.used_hosts.push(host);
        }
        let method = r.method.as_deref().unwrap_or("GET");
        let timeout = r.timeout_seconds.unwrap_or(DEFAULT_TIMEOUT_S) as u64;
        let max = r.max_bytes.unwrap_or(DEFAULT_MAX_BYTES);
        let agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(10))
            .timeout(Duration::from_secs(timeout))
            .user_agent(&user_agent())
            .build();
        let has = |n: &str| headers.keys().any(|k| k.eq_ignore_ascii_case(n));
        let mut attempt = 0;
        loop {
            attempt += 1;
            (self.gate)()?;
            let t0 = Instant::now();
            let mut req = agent.request(method, url);
            for (k, v) in headers {
                req = req.set(k, v);
            }
            if !has("accept-encoding") {
                req = req.set("Accept-Encoding", "gzip");
            }
            if !has("authorization") {
                if let Some(b) = &def.basic_auth {
                    let (u, p) = (self.rc.secrets.by_alias.get(&b.user_alias), self.rc.secrets.by_alias.get(&b.password_alias));
                    match (u, p) {
                        (Some(u), Some(p)) => {
                            req = req.set("Authorization", &format!("Basic {}", base64::engine::general_purpose::STANDARD.encode(format!("{u}:{p}"))));
                        }
                        _ if b.required => return Err(Error::key_missing(format!("this source needs the login ({} and {})", b.user_alias, b.password_alias))),
                        _ => {}
                    }
                }
            }
            let result = match (method, body) {
                ("POST", Some((ct, bytes))) => {
                    if !has("content-type") {
                        req = req.set("Content-Type", ct);
                    }
                    req.send_bytes(bytes)
                }
                ("POST", None) => req.send_bytes(&[]),
                _ => req.call(),
            };
            let elapsed = t0.elapsed().as_millis() as u64;
            let shown = scrub(url.to_string(), &self.scrub);
            match result {
                Ok(resp) => {
                    let status = resp.status();
                    let mut buf = Vec::new();
                    resp.into_reader()
                        .take(max + 1)
                        .read_to_end(&mut buf)
                        .map_err(|e| Error::fetch_failed(scrub(format!("reading the response: {e}"), &self.scrub)))?;
                    if buf.len() as u64 > max {
                        return Err(Error::bad_response(format!("the response is larger than {} MB (set request.max_bytes higher, up to 32 MB)", max / (1024 * 1024))));
                    }
                    let buf = gunzip_if_needed(buf, max)?;
                    self.log.push(ReqLog { step: step.into(), method: method.into(), url: shown, status, bytes: buf.len(), ms: elapsed });
                    return Ok(buf);
                }
                Err(ureq::Error::Status(code, resp)) => {
                    self.log.push(ReqLog { step: step.into(), method: method.into(), url: shown, status: code, bytes: 0, ms: elapsed });
                    let retry_after = resp.header("retry-after").and_then(parse_retry_after);
                    let mut buf = Vec::new();
                    let _ = resp.into_reader().take(8192).read_to_end(&mut buf);
                    if (code == 429 || (code == 503 && retry_after.is_some())) && attempt < 3 {
                        let wait = retry_after.unwrap_or(1u64 << attempt);
                        if wait <= self.max_wait_s {
                            std::thread::sleep(Duration::from_secs(wait));
                            continue;
                        }
                    }
                    let mut msg = format!("HTTP {code}");
                    if let Some(s) = error_snippet(&buf) {
                        msg.push_str(": ");
                        msg.push_str(&s);
                    }
                    match code {
                        401 | 403 => msg.push_str(" (the key or login was refused)"),
                        429 => match retry_after {
                            Some(w) => msg.push_str(&format!(" (rate limited; the provider asks for {w} s)")),
                            None => msg.push_str(" (rate limited; gave up after retrying)"),
                        },
                        _ => {}
                    }
                    return Err(Error::fetch_failed(scrub(msg, &self.scrub)));
                }
                Err(ureq::Error::Transport(t)) => {
                    return Err(Error::fetch_failed(scrub(format!("{:?}: {}", t.kind(), t.message().unwrap_or("")), &self.scrub)));
                }
            }
        }
    }
}

fn truthy(v: Option<&Value>) -> bool {
    match v {
        Some(Value::Bool(b)) => *b,
        Some(Value::String(s)) => s.eq_ignore_ascii_case("true") || s == "1",
        Some(Value::Number(n)) => n.as_f64().map(|x| x != 0.0).unwrap_or(false),
        _ => false,
    }
}

fn list_of<'a>(tree: &'a Value, path: &str) -> Option<&'a Vec<Value>> {
    if path.is_empty() || path == "^" {
        tree.as_array()
    } else {
        lookup(tree, path)?.as_array()
    }
}

fn list_mut<'a>(tree: &'a mut Value, path: &str) -> Option<&'a mut Vec<Value>> {
    let mut v = tree;
    if !(path.is_empty() || path == "^") {
        for seg in path.trim_start_matches('^').split('.').filter(|s| !s.is_empty()) {
            v = v.get_mut(seg)?;
        }
    }
    v.as_array_mut()
}

fn parse_retry_after(h: &str) -> Option<u64> {
    let h = h.trim();
    if let Ok(n) = h.parse::<u64>() {
        return Some(n);
    }
    let when = DateTime::parse_from_rfc2822(h).ok()?.timestamp();
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).ok()?.as_secs() as i64;
    Some((when - now).max(0) as u64)
}

/// A short, one-line reason from an error body: the message member of a JSON object, or short plain text.
fn error_snippet(body: &[u8]) -> Option<String> {
    let text = String::from_utf8_lossy(body);
    let t = text.trim();
    if t.is_empty() {
        return None;
    }
    let one = |s: &str| {
        let s = s.split_whitespace().collect::<Vec<_>>().join(" ");
        if s.chars().count() > 200 { format!("{}...", s.chars().take(200).collect::<String>()) } else { s }
    };
    if let Ok(Value::Object(o)) = serde_json::from_str::<Value>(t) {
        for k in ["message", "error_description", "detail", "error", "reason", "title", "status_message"] {
            let hit = o.iter().find(|(name, _)| name.eq_ignore_ascii_case(k)).map(|(_, v)| v);
            match hit {
                Some(Value::String(s)) if !s.trim().is_empty() => return Some(one(s)),
                Some(Value::Object(e)) => {
                    if let Some(Value::String(s)) = e.get("message") {
                        return Some(one(s));
                    }
                }
                _ => {}
            }
        }
        return None;
    }
    if t.starts_with('<') || t.starts_with('{') || t.starts_with('[') || t.len() > 300 {
        return None;
    }
    Some(one(t))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn place() -> Place {
        Place { key: "home".into(), name: "Mom & Dad".into(), lat: 42.5361234, lon: -113.79 }
    }

    fn exp<'a>(p: &'a Place, info: &'a PlaceInfo, params: &'a Params, secrets: &'a Secrets, steps: &'a Map<String, Value>) -> Expander<'a> {
        Expander { place: p, info, params, secrets, api_key_alias: Some("k"), now: 1_792_000_000, steps, vars: BTreeMap::new() }
    }

    #[test]
    fn placeholders() {
        let p = place();
        let info = PlaceInfo { state: Some("ID".into()), county: Some("Cassia".into()), country: Some("US".into()), ..Default::default() };
        let mut params = Params::new();
        params.insert("radius".into(), json!(25));
        params.insert("site".into(), json!("13 206"));
        let mut secrets = Secrets::default();
        secrets.by_alias.insert("k".into(), "a b".into());
        let steps: Map<String, Value> = serde_json::from_value(json!({"point": {"properties": {"forecast": "https://api.weather.gov/gridpoints/BOI/1,2/forecast", "id": 7}}})).unwrap();
        let mut e = exp(&p, &info, &params, &secrets, &steps);
        let x = |e: &Expander, t: &str| e.expand(t, Mode::Encoded).unwrap();
        assert_eq!(x(&e, "x?lat={lat}&lon={lon:2}&n={name}&k={place_key}"), "x?lat=42.5361&lon=-113.79&n=Mom%20%26%20Dad&k=home");
        assert_eq!(x(&e, "{api_key}"), "a%20b");
        assert_eq!(e.expand("{api_key}", Mode::Plain).unwrap(), "a b");
        assert_eq!(x(&e, "{latlon:2}|{lonlat:1}|{lat_abs:1}{lat_hem}|{lon_abs:1}{lon_hem}"), "42.54%2C-113.79|-113.8%2C42.5|42.5N|113.8W");
        assert_eq!(x(&e, "{state}-{county}-{country}"), "ID-Cassia-US");
        assert_eq!(e.expand("{state_name}", Mode::Plain).unwrap_err().code, "fetch_failed");
        assert_eq!(x(&e, "{param:site}"), "13%20206");
        // a box of 25 km: 0.2246 degrees of latitude
        assert_eq!(x(&e, "{south:25km}"), "42.3115");
        assert_eq!(x(&e, "{north:25km}"), "42.7607");
        assert_eq!(e.expand("{bbox:$radius:km}", Mode::Plain).unwrap().split(',').count(), 4);
        let w15 = e.expand("{west:15mi}", Mode::Plain).unwrap().parse::<f64>().unwrap();
        assert!((w15 - (-113.79 - 24.14016 / (111.32 * 42.5361234f64.to_radians().cos()))).abs() < 1e-3, "{w15}");
        // times
        assert_eq!(x(&e, "{now:unix}"), "1792000000");
        assert_eq!(x(&e, "{now-1d:unix}"), "1791913600");
        assert_eq!(e.expand("{now-6h:%Y-%m-%dT%H:%M:%SZ}", Mode::Plain).unwrap(), "2026-10-14T11:46:40Z");
        // steps: encoded unless |raw
        assert_eq!(x(&e, "{point:properties.id}"), "7");
        assert_eq!(x(&e, "{point:properties.forecast|raw}"), "https://api.weather.gov/gridpoints/BOI/1,2/forecast");
        assert!(x(&e, "{point:properties.forecast}").contains("%3A"));
        assert_eq!(e.expand("{point:properties.nope}", Mode::Plain).unwrap_err().code, "fetch_failed");
        e.vars.insert("f".into(), json!({"id": "abc"}));
        e.vars.insert("s".into(), json!("plain"));
        assert_eq!(x(&e, "{f:id}/{s}"), "abc/plain");
        assert!(e.expand("{nope}", Mode::Plain).is_err());
        assert!(e.expand("{lat", Mode::Plain).is_err());
        let none = Secrets::default();
        let e2 = exp(&p, &info, &params, &none, &steps);
        assert_eq!(e2.expand("{api_key}", Mode::Plain).unwrap_err().code, "key_missing");
        // bodies keep a lone parameter's type
        let b = e.body_value(&json!({"radius": "{param:radius}", "q": "near {name}", "n": 3, "list": ["{param:site}"]})).unwrap();
        assert_eq!(b, json!({"radius": 25, "q": "near Mom & Dad", "n": 3, "list": ["13 206"]}));
    }

    #[test]
    fn static_placeholder_checks() {
        let params = vec![];
        assert!(check_placeholder("lat:2", &params, &[]).is_ok());
        assert!(check_placeholder("lat:x", &params, &[]).is_err());
        assert!(check_placeholder("param:nope", &params, &[]).is_err());
        assert!(check_placeholder("now-24h:unix", &params, &[]).is_ok());
        assert!(check_placeholder("nowish", &params, &[]).is_err());
        assert!(check_placeholder("bbox", &params, &[]).is_err());
        assert!(check_placeholder("step:a.b|raw", &params, &[]).is_ok());
        assert!(check_placeholder("a b", &params, &[]).is_err());
    }

    #[test]
    fn url_rules_and_query_params() {
        assert!(check_url("https://api.weather.gov/x").is_ok());
        assert!(check_url("http://127.0.0.1:8080/x").is_ok());
        assert!(check_url("http://localhost/x").is_ok());
        assert!(check_url("http://example.com/x").is_err());
        assert!(check_url("http://127.0.0.1.evil.com/x").is_err());
        assert!(check_url("ftp://x").is_err());
        assert_eq!(set_query_param("https://h/p?a=1&off=5&b=2#f", "off", "10"), "https://h/p?a=1&b=2&off=10#f");
        assert_eq!(set_query_param("https://h/p", "page", "2"), "https://h/p?page=2");
        assert_eq!(host_of("https://User@Api.Example.com:8080/x?y"), "api.example.com:8080");
    }

    #[test]
    fn keys_are_scrubbed_and_snippets_are_short() {
        assert_eq!(scrub("GET https://h/?k=sekret&x=1 failed".into(), &["sekret".to_string()]), "GET https://h/?k=***&x=1 failed");
        assert_eq!(error_snippet(br#"{"message":"Key expired"}"#).unwrap(), "Key expired");
        assert_eq!(error_snippet(br#"{"error":{"code":1,"message":"Bad box"}}"#).unwrap(), "Bad box");
        assert_eq!(error_snippet(b"Too many requests\n").unwrap(), "Too many requests");
        assert_eq!(error_snippet(b"<html>no</html>"), None);
        assert_eq!(error_snippet(br#"{"data":[1,2,3]}"#), None);
        assert_eq!(parse_retry_after("7"), Some(7));
        assert!(parse_retry_after("Wed, 21 Oct 2015 07:28:00 GMT").is_some());
        assert_eq!(parse_retry_after("soon"), None);
    }
}
