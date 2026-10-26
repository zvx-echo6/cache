//! `cs_live_fetch`: download one (source, place), map it, store it.
//!
//! HTTP is `ureq` (blocking, rustls with bundled root certificates): the core has no async runtime and the app's
//! scheduler or the CLI calls this from a worker thread, so a blocking client is all that is needed, and it adds
//! far fewer crates than reqwest (which would bring tokio and hyper into the library). The request itself (placeholders,
//! auth, steps, paging, retries) is `request.rs`; this file adds the database around it: quotas, the stored row, the
//! recorded error.

use crate::request::{execute, PlaceInfo, RunCtx, Secrets};
pub use crate::request::{check_url, user_agent};
use crate::params as uparams;
use crate::{def::SourceDef, map, now_from, place_from, save_row, Live, Loaded, Place, Row};
use crate::{Error, Result};
use rusqlite::{params, Connection};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// What a stored row remembers besides the items: the parameter values it was fetched with (so a changed definition
/// re-maps it the same way) and how complete the data is.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct RowMeta {
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub params: BTreeMap<String, Value>,
    /// A paged result was cut at the definition's page cap with more data left.
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub truncated: bool,
    /// Repeated requests that failed and are missing from the data.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub skipped: usize,
}

fn is_zero(n: &usize) -> bool {
    *n == 0
}

impl RowMeta {
    pub fn of(row: &Row) -> RowMeta {
        row.meta.as_deref().and_then(|m| serde_json::from_str(m).ok()).unwrap_or_default()
    }
    pub fn to_text(&self) -> Option<String> {
        if self.params.is_empty() && !self.truncated && self.skipped == 0 {
            None
        } else {
            serde_json::to_string(self).ok()
        }
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

/// The secrets of a request: `secrets` by alias, plus `api_key` under the definition's key alias.
pub(crate) fn secrets_of(d: &SourceDef, api_key: Option<&str>, given: Option<&Map<String, Value>>) -> Secrets {
    let mut s = Secrets::default();
    if let Some(g) = given {
        for (k, v) in g {
            if let Some(v) = v.as_str().filter(|v| !v.is_empty()) {
                s.by_alias.insert(k.clone(), v.to_string());
            }
        }
    }
    if let (Some(k), Some(def)) = (api_key.filter(|k| !k.is_empty()), &d.api_key) {
        s.by_alias.insert(def.alias.clone(), k.to_string());
    }
    s
}

/// The key and login the definition requires must all be given.
pub(crate) fn check_secrets(d: &SourceDef, s: &Secrets) -> Result<()> {
    if let Some(k) = &d.api_key {
        if k.required && !s.by_alias.contains_key(&k.alias) {
            return Err(Error::key_missing(format!("{} needs the API key {:?}", d.id, k.alias)));
        }
    }
    if let Some(b) = &d.basic_auth {
        if b.required && (!s.by_alias.contains_key(&b.user_alias) || !s.by_alias.contains_key(&b.password_alias)) {
            return Err(Error::key_missing(format!("{} needs the login {:?} and {:?}", d.id, b.user_alias, b.password_alias)));
        }
    }
    Ok(())
}

impl Live {
    fn record_failure(&self, c: &Connection, source: &str, key: &str, e: &Error, now: i64) {
        let _ = c.execute(
            "INSERT INTO live_error(source,place_key,at,code,message) VALUES(?1,?2,?3,?4,?5)
             ON CONFLICT(source,place_key) DO UPDATE SET at=?3,code=?4,message=?5",
            params![source, key, now, e.code, e.message],
        );
    }

    #[allow(clippy::too_many_arguments)]
    fn download(&self, c: &Connection, l: &Loaded, place: &Place, info: &PlaceInfo, par: &map::Params, secrets: &Secrets, now: i64) -> Result<Row> {
        let d = &l.def;
        // every HTTP request (each step, page and retry) counts against the quota, even if it fails
        let mut gate = || -> Result<()> {
            check_quota(c, d, now)?;
            c.execute("INSERT INTO live_log(source,at) VALUES(?1,?2)", params![d.id, now])?;
            c.execute("DELETE FROM live_log WHERE at<?1", [now - 31 * 86_400])?;
            Ok(())
        };
        let out = execute(&RunCtx { def: d, place, info, params: par, secrets, now }, &mut gate)?;
        let m = map::map_response_with(d, &out.tree, now, place.lat, place.lon, par)?;
        let meta = RowMeta { params: par.clone(), truncated: out.truncated, skipped: out.skipped };
        let mut row = Row {
            place: place.clone(),
            fetched_at: now,
            valid_until: m.valid_until,
            utc_offset: None,
            tz: None,
            not_covered_after: m.not_covered_after,
            def_hash: l.hash.clone(),
            items: m.items,
            raw: serde_json::to_string(&out.tree)?,
            meta: meta.to_text(),
        };
        row.set_zone(m.zone);
        Ok(row)
    }

    /// `cs_live_fetch`: `{source, place, params?, api_key?, secrets?, force?, now?}`. Downloads unless the stored copy is
    /// younger than the source's refresh interval (and still valid and mapped by the same definition), maps and stores
    /// it, and returns what `get` returns plus `"fetched": true|false`. A failed download leaves the last good copy in
    /// place and is recorded as the row's `last_error`. Keys and logins are used for this call only and never stored.
    pub fn fetch(&self, req_json: &str, places: &dyn cache_tool::SavedPlaces) -> Result<String> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct Req {
            source: String,
            #[serde(default)]
            place: Option<Value>,
            #[serde(default)]
            params: Option<Map<String, Value>>,
            #[serde(default)]
            api_key: Option<String>,
            #[serde(default)]
            secrets: Option<Map<String, Value>>,
            #[serde(default)]
            force: bool,
            #[serde(default)]
            now: Option<String>,
        }
        let r: Req = serde_json::from_str(req_json).map_err(|e| Error::bad_json(format!("request_json: {e}")))?;
        let now = now_from(r.now.as_deref())?;
        let l = self.def(&r.source).ok_or_else(|| Error::not_found(format!("no live source {:?}", r.source)))?;
        let place = place_from(r.place.as_ref(), places)?;
        let info = PlaceInfo::from_value(r.place.as_ref());
        let par = uparams::resolve(&l.def, r.params.as_ref())?;
        let place = uparams::row_place(&l.def, &place, &par);
        let c = self.db()?;
        let secrets = secrets_of(&l.def, r.api_key.as_deref(), r.secrets.as_ref());
        check_secrets(&l.def, &secrets)?;
        if !r.force {
            if let Some(v) = self.view(&c, &l, &place, now)? {
                if !v.expired && now < v.row.fetched_at + l.def.refresh_minutes as i64 * 60 {
                    return self.view_json(&l, &v, Some(false));
                }
            }
        }
        match self.download(&c, &l, &place, &info, &par, &secrets, now) {
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
                // recorded for the source and place whether or not an earlier copy exists; with one, `get` shows it as last_error
                self.record_failure(&c, &l.def.id, &place.key, &e, now);
                Err(e)
            }
        }
    }
}
