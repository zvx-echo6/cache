//! `cs_live_fetch`: download one (source, place), map it, store it.
//!
//! HTTP is `ureq` (blocking, rustls with bundled root certificates): the core has no async runtime and the app's
//! scheduler or the CLI calls this from a worker thread, so a blocking client is all that is needed, and it adds
//! far fewer crates than reqwest (which would bring tokio and hyper into the library).

use crate::{def::SourceDef, load_row, map, now_from, place_from, save_row, Live, Loaded, Place, Row};
use crate::{Error, Result};
use cache_tool::SavedPlaces;
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use rusqlite::{params, Connection};
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::io::Read;

/// The User-Agent of every fetch. Generic on purpose: NWS requires one, and it never names a person.
pub fn user_agent() -> String {
    format!("Cache/{}", env!("CARGO_PKG_VERSION"))
}

const MAX_BODY: u64 = 8 * 1024 * 1024;
const UNRESERVED: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'_').remove(b'.').remove(b'~');

fn enc(s: &str) -> String {
    utf8_percent_encode(s, UNRESERVED).to_string()
}

/// Fill `{lat}` `{lon}` (4 decimals; `{lat:2}` for another count), `{name}`, `{place_key}` and `{api_key}`.
/// Values are percent-encoded.
pub fn expand(t: &str, place: &Place, key: Option<&str>) -> Result<String> {
    let mut out = String::new();
    let mut rest = t;
    while let Some(i) = rest.find('{') {
        out.push_str(&rest[..i]);
        let j = rest[i..].find('}').ok_or_else(|| Error::bad_json(format!("unclosed {{ in {t:?}")))? + i;
        let hole = &rest[i + 1..j];
        let (name, dec) = match hole.split_once(':') {
            Some((n, d)) => (n, Some(d.parse::<usize>().map_err(|_| Error::bad_json(format!("bad placeholder {{{hole}}}")))?)),
            None => (hole, None),
        };
        match name {
            "lat" => out.push_str(&enc(&format!("{:.*}", dec.unwrap_or(4), place.lat))),
            "lon" => out.push_str(&enc(&format!("{:.*}", dec.unwrap_or(4), place.lon))),
            "name" => out.push_str(&enc(&place.name)),
            "place_key" => out.push_str(&enc(&place.key)),
            "api_key" => out.push_str(&enc(key.ok_or_else(|| Error::key_missing("this source needs an API key"))?)),
            _ => return Err(Error::bad_json(format!("unknown placeholder {{{hole}}}"))),
        }
        rest = &rest[j + 1..];
    }
    out.push_str(rest);
    Ok(out)
}

/// https always; plain http only to the machine itself (tests and a local server).
fn check_url(url: &str) -> Result<()> {
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

fn scrub(s: String, key: Option<&str>) -> String {
    match key {
        Some(k) if !k.is_empty() => s.replace(k, "***").replace(&enc(k), "***"),
        _ => s,
    }
}

fn http_get(url: &str, headers: &BTreeMap<String, String>, key: Option<&str>) -> Result<String> {
    let agent = ureq::AgentBuilder::new()
        .timeout_connect(std::time::Duration::from_secs(10))
        .timeout(std::time::Duration::from_secs(30))
        .user_agent(&user_agent())
        .build();
    let mut req = agent.get(url);
    for (k, v) in headers {
        req = req.set(k, v);
    }
    match req.call() {
        Ok(resp) => {
            let mut body = String::new();
            resp.into_reader().take(MAX_BODY).read_to_string(&mut body).map_err(|e| Error::fetch_failed(scrub(format!("reading the response: {e}"), key)))?;
            Ok(body)
        }
        Err(ureq::Error::Status(code, _)) => Err(Error::fetch_failed(format!("HTTP {code}"))),
        Err(ureq::Error::Transport(t)) => Err(Error::fetch_failed(scrub(format!("{:?}: {}", t.kind(), t.message().unwrap_or("")), key))),
    }
}

fn count_since(c: &Connection, source: &str, since: i64) -> Result<u32> {
    Ok(c.query_row("SELECT COUNT(*) FROM live_log WHERE source=?1 AND at>?2", params![source, since], |r| r.get(0))?)
}

fn check_quota(c: &Connection, d: &SourceDef, now: i64) -> Result<()> {
    for (cap, secs, what) in [(d.quota.per_minute, 60, "minute"), (d.quota.per_day, 86_400, "day"), (d.quota.per_month, 30 * 86_400, "month")] {
        if let Some(cap) = cap {
            if count_since(c, &d.id, now - secs)? >= cap {
                return Err(Error::quota(format!("{} has reached its limit of {cap} downloads per {what}", d.id)));
            }
        }
    }
    Ok(())
}

/// Rows keyed by the phone's position (`at:<lat>,<lon>`) pile up as the phone moves: after a fetch for one, the other
/// position rows of that source are deleted unless they are still within their validity. The newest fetch is the one
/// just stored, so it is always kept; saved places are never pruned.
fn prune_here(c: &Connection, source: &str, keep_key: &str, now: i64) {
    let cond = "source=?1 AND place_key LIKE 'at:%' AND place_key<>?2 AND valid_until<?3";
    let _ = c.execute(&format!("DELETE FROM live_error WHERE (source,place_key) IN (SELECT source,place_key FROM live_fetch WHERE {cond})"), params![source, keep_key, now]);
    let _ = c.execute(&format!("DELETE FROM live_fetch WHERE {cond}"), params![source, keep_key, now]);
}

impl Live {
    fn record_failure(&self, c: &Connection, source: &str, key: &str, e: &Error, now: i64) {
        let _ = c.execute(
            "INSERT INTO live_error(source,place_key,at,code,message) VALUES(?1,?2,?3,?4,?5)
             ON CONFLICT(source,place_key) DO UPDATE SET at=?3,code=?4,message=?5",
            params![source, key, now, e.code, e.message],
        );
    }

    fn download(&self, c: &Connection, l: &Loaded, place: &Place, api_key: Option<&str>, now: i64) -> Result<Row> {
        let d = &l.def;
        let url = expand(&d.request.url, place, api_key)?;
        check_url(&url)?;
        let mut headers = BTreeMap::new();
        for (k, v) in &d.request.headers {
            headers.insert(k.clone(), expand(v, place, api_key)?);
        }
        check_quota(c, d, now)?;
        // a download that is tried counts against the quota even if it fails
        c.execute("INSERT INTO live_log(source,at) VALUES(?1,?2)", params![d.id, now])?;
        c.execute("DELETE FROM live_log WHERE at<?1", [now - 31 * 86_400])?;
        let body = http_get(&url, &headers, api_key)?;
        let root: Value = serde_json::from_str(&body).map_err(|e| Error::bad_response(format!("the response is not JSON: {e}")))?;
        let m = map::map_response(d, &root, now, place.lat, place.lon)?;
        let mut row = Row {
            place: place.clone(),
            fetched_at: now,
            valid_until: m.valid_until,
            utc_offset: None,
            tz: None,
            not_covered_after: m.not_covered_after,
            def_hash: l.hash.clone(),
            items: m.items,
            raw: body,
        };
        row.set_zone(m.zone);
        Ok(row)
    }

    /// `cs_live_fetch`: `{source, place, api_key?, force?, now?}`. Downloads unless the stored copy is younger than the
    /// source's refresh interval (and still valid and mapped by the same definition), maps and stores it, and
    /// returns what `get` returns plus `"fetched": true|false`. A failed download leaves the last good copy in
    /// place and is recorded as the row's `last_error`. The key is used for this call only and never stored.
    pub fn fetch(&self, req_json: &str, places: &dyn SavedPlaces) -> Result<String> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Req {
            source: String,
            #[serde(default)]
            place: Option<Value>,
            #[serde(default)]
            api_key: Option<String>,
            #[serde(default)]
            force: bool,
            #[serde(default)]
            now: Option<String>,
        }
        let r: Req = serde_json::from_str(req_json).map_err(|e| Error::bad_json(format!("request_json: {e}")))?;
        let now = now_from(r.now.as_deref())?;
        let l = self.def(&r.source).ok_or_else(|| Error::not_found(format!("no live source {:?}", r.source)))?;
        let place = place_from(r.place.as_ref(), places)?;
        let c = self.db()?;
        let key = r.api_key.as_deref().filter(|k| !k.is_empty());
        if let Some(k) = &l.def.api_key {
            if k.required && key.is_none() {
                return Err(Error::key_missing(format!("{} needs the API key {:?}", l.def.id, k.alias)));
            }
        }
        if !r.force {
            if let Some(v) = self.view(&c, &l, &place, now)? {
                if !v.expired && now < v.row.fetched_at + l.def.refresh_minutes as i64 * 60 {
                    return self.view_json(&l, &v, Some(false));
                }
            }
        }
        match self.download(&c, &l, &place, key, now) {
            Ok(row) => {
                save_row(&c, &l.def.id, &row)?;
                if place.key.starts_with("at:") {
                    prune_here(&c, &l.def.id, &place.key, now);
                }
                let _ = c.execute("DELETE FROM live_error WHERE source=?1 AND place_key=?2", params![l.def.id, place.key]);
                let v = self.view(&c, &l, &place, now)?.ok_or_else(|| Error::internal("stored row missing"))?;
                self.view_json(&l, &v, Some(true))
            }
            Err(e) => {
                if load_row(&c, &l.def.id, &place.key)?.is_some() {
                    self.record_failure(&c, &l.def.id, &place.key, &e, now);
                }
                Err(e)
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p() -> Place {
        Place { key: "home".into(), name: "Mom & Dad".into(), lat: 42.5361234, lon: -113.79 }
    }

    #[test]
    fn placeholders() {
        assert_eq!(expand("x?lat={lat}&lon={lon:2}&n={name}&k={place_key}", &p(), None).unwrap(), "x?lat=42.5361&lon=-113.79&n=Mom%20%26%20Dad&k=home");
        assert_eq!(expand("{api_key}", &p(), Some("a b")).unwrap(), "a%20b");
        assert_eq!(expand("{api_key}", &p(), None).unwrap_err().code, "key_missing");
        assert!(expand("{nope}", &p(), None).is_err());
        assert!(expand("{lat", &p(), None).is_err());
    }

    #[test]
    fn url_rules() {
        assert!(check_url("https://api.weather.gov/x").is_ok());
        assert!(check_url("http://127.0.0.1:8080/x").is_ok());
        assert!(check_url("http://localhost/x").is_ok());
        assert!(check_url("http://example.com/x").is_err());
        assert!(check_url("http://127.0.0.1.evil.com/x").is_err());
        assert!(check_url("ftp://x").is_err());
    }

    #[test]
    fn keys_are_scrubbed() {
        assert_eq!(scrub("GET https://h/?k=sekret&x=1 failed".into(), Some("sekret")), "GET https://h/?k=***&x=1 failed");
    }
}
