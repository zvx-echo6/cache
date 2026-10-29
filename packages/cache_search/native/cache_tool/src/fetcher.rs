//! The live-fetch grant: what the host allows and the keys it holds, pushed in by the host (no callbacks).
//!
//! `PolicyFetcher` is the handle's built-in `LiveFetcher`. It answers from state the host pushed with
//! `cs_live_set_fetch_policy` and `cs_live_set_key`. With no policy set it denies every fetch, so captures and tests
//! never fetch. Keys live in memory only: there is no `Debug`, no serialisation, and no error ever holds one.
//!
//! A policy may also carry `states` (captures, `cs serve --live-state`): a state per source id, or `"*"` for every source, that
//! stands in for the real connection so live_data's `not_refreshed` can be recorded without a network.

use crate::{LiveFetcher, NotAllowed, ToolError};
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Mutex;

struct Policy {
    online: bool,
    allow_metered: bool,
    metered: bool,
    enabled_sources: Vec<String>,
    /// Capture states by source id (`"*"`: every source), in place of the fields above for those sources.
    states: HashMap<String, Stand>,
}

/// A capture state (`states` in the policy).
#[derive(Clone, Copy, Debug, PartialEq)]
enum Stand {
    /// Nothing is downloaded and no reason is given: as with no policy.
    Normal,
    Off,
    Offline,
    Metered,
    /// The download fails with this error code, and nothing is sent.
    Fail(&'static str),
}

impl Stand {
    fn parse(s: &str) -> Option<Stand> {
        Some(match s {
            "normal" => Stand::Normal,
            "off" => Stand::Off,
            "offline" => Stand::Offline,
            "metered" => Stand::Metered,
            _ => Stand::Fail(match s.strip_prefix("fail:")? {
                "fetch_failed" => ToolError::FETCH_FAILED,
                "quota" => ToolError::QUOTA,
                "key_missing" => ToolError::KEY_MISSING,
                "bad_response" => ToolError::BAD_RESPONSE,
                _ => return None,
            }),
        })
    }
}

impl Policy {
    fn stand(&self, source_id: &str) -> Option<Stand> {
        self.states.get(source_id).or_else(|| self.states.get("*")).copied()
    }
}

#[derive(Default)]
struct State {
    policy: Option<Policy>,
    keys: HashMap<String, String>,
}

/// Overwrites a key before it is freed (best effort; the allocator may still have copies).
fn wipe(mut s: String) {
    // SAFETY: zero bytes are valid UTF-8.
    unsafe { s.as_bytes_mut() }.fill(0);
}

#[derive(Default)]
pub struct PolicyFetcher {
    state: Mutex<State>,
}

impl PolicyFetcher {
    pub fn new() -> PolicyFetcher {
        PolicyFetcher::default()
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// True once the host has pushed a policy (until it clears it or the handle closes).
    pub fn is_set(&self) -> bool {
        self.lock().policy.is_some()
    }

    /// Sets the policy from `{"online":bool,"allow_metered":bool,"metered":bool,"enabled_sources":[ids],"states"?:{id:state}}`
    /// (`allow_metered` and `metered` default to false; a state is normal, off, offline, metered or fail:<fetch_failed|quota|
    /// key_missing|bad_response>). `None` clears it. A bad document leaves the old policy and returns the reason (which never
    /// holds a key: the document has none).
    pub fn set_policy_json(&self, json: Option<&str>) -> Result<(), String> {
        let Some(json) = json else {
            self.lock().policy = None;
            return Ok(());
        };
        let v: Value = serde_json::from_str(json).map_err(|e| format!("policy: {e}"))?;
        let obj = v.as_object().ok_or("policy must be a JSON object")?;
        if let Some(k) = obj.keys().find(|k| !["online", "allow_metered", "metered", "enabled_sources", "states"].contains(&k.as_str())) {
            return Err(format!("policy: unknown field {k:?}"));
        }
        let flag = |name: &str, required: bool| match obj.get(name) {
            Some(Value::Bool(b)) => Ok(*b),
            None if !required => Ok(false),
            _ => Err(format!("policy: \"{name}\" (boolean) is required")),
        };
        let (online, allow_metered, metered) = (flag("online", true)?, flag("allow_metered", false)?, flag("metered", false)?);
        let enabled_sources = obj
            .get("enabled_sources")
            .and_then(Value::as_array)
            .ok_or("policy: \"enabled_sources\" (array of strings) is required")?
            .iter()
            .map(|s| s.as_str().map(str::to_string).ok_or("policy: \"enabled_sources\" must hold strings"))
            .collect::<Result<Vec<_>, _>>()?;
        let mut states = HashMap::new();
        if let Some(st) = obj.get("states") {
            let st = st.as_object().ok_or("policy: \"states\" must be an object of source id to state")?;
            for (id, v) in st {
                let stand = v.as_str().and_then(Stand::parse).ok_or_else(|| {
                    format!("policy: states.{id} must be normal, off, offline, metered or fail:<fetch_failed|quota|key_missing|bad_response>")
                })?;
                states.insert(id.clone(), stand);
            }
        }
        self.lock().policy = Some(Policy { online, allow_metered, metered, enabled_sources, states });
        Ok(())
    }

    /// Keeps `key` for `source_id` in memory; `None` or an empty key removes it.
    pub fn set_key(&self, source_id: &str, key: Option<&str>) {
        let mut st = self.lock();
        let old = match key.filter(|k| !k.is_empty()) {
            Some(k) => st.keys.insert(source_id.to_string(), k.to_string()),
            None => st.keys.remove(source_id),
        };
        drop(st);
        if let Some(old) = old {
            wipe(old);
        }
    }

    /// Forgets the policy and every key (cs_close).
    pub fn clear(&self) {
        let mut st = self.lock();
        st.policy = None;
        let keys: Vec<String> = st.keys.drain().map(|(_, v)| v).collect();
        drop(st);
        keys.into_iter().for_each(wipe);
    }
}

impl Drop for PolicyFetcher {
    fn drop(&mut self) {
        self.clear();
    }
}

impl LiveFetcher for PolicyFetcher {
    fn can_fetch(&self, source_id: &str) -> bool {
        match &self.lock().policy {
            Some(p) => match p.stand(source_id) {
                Some(s) => matches!(s, Stand::Fail(_)),
                None => p.online && p.enabled_sources.iter().any(|s| s == source_id) && (!p.metered || p.allow_metered),
            },
            None => false,
        }
    }

    fn not_allowed(&self, source_id: &str) -> Option<NotAllowed> {
        let st = self.lock();
        let p = st.policy.as_ref()?;
        match p.stand(source_id) {
            Some(Stand::Off) => Some(NotAllowed::SwitchedOff),
            Some(Stand::Offline) => Some(NotAllowed::Offline),
            Some(Stand::Metered) => Some(NotAllowed::MeteredOff),
            Some(_) => None,
            // highest priority first: switched off, no connection, mobile data updates off
            None if !p.enabled_sources.iter().any(|s| s == source_id) => Some(NotAllowed::SwitchedOff),
            None if !p.online => Some(NotAllowed::Offline),
            None if p.metered && !p.allow_metered => Some(NotAllowed::MeteredOff),
            None => None,
        }
    }

    fn stand_in_failure(&self, source_id: &str) -> Option<&'static str> {
        match self.lock().policy.as_ref()?.stand(source_id)? {
            Stand::Fail(code) => Some(code),
            _ => None,
        }
    }

    fn key_for(&self, source_id: &str) -> Option<String> {
        self.lock().keys.get(source_id).cloned()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pol(f: &PolicyFetcher, j: &str) {
        f.set_policy_json(Some(j)).unwrap();
    }

    #[test]
    fn denied_by_default() {
        let f = PolicyFetcher::new();
        assert!(!f.is_set());
        assert!(!f.can_fetch("nws"));
        assert!(f.key_for("nws").is_none());
    }

    #[test]
    fn allowed_by_policy_and_cleared_by_none() {
        let f = PolicyFetcher::new();
        pol(&f, r#"{"online":true,"allow_metered":false,"metered":false,"enabled_sources":["nws"]}"#);
        assert!(f.is_set());
        assert!(f.can_fetch("nws"));
        assert!(!f.can_fetch("other"));
        f.set_policy_json(None).unwrap();
        assert!(!f.is_set());
        assert!(!f.can_fetch("nws"));
    }

    #[test]
    fn offline_is_denied() {
        let f = PolicyFetcher::new();
        pol(&f, r#"{"online":false,"enabled_sources":["nws"]}"#);
        assert!(!f.can_fetch("nws"));
    }

    #[test]
    fn the_metered_rule() {
        let f = PolicyFetcher::new();
        pol(&f, r#"{"online":true,"allow_metered":false,"metered":true,"enabled_sources":["nws"]}"#);
        assert!(!f.can_fetch("nws"));
        pol(&f, r#"{"online":true,"allow_metered":true,"metered":true,"enabled_sources":["nws"]}"#);
        assert!(f.can_fetch("nws"));
        pol(&f, r#"{"online":true,"allow_metered":false,"metered":false,"enabled_sources":["nws"]}"#);
        assert!(f.can_fetch("nws"));
    }

    #[test]
    fn a_disabled_source_is_denied() {
        let f = PolicyFetcher::new();
        pol(&f, r#"{"online":true,"enabled_sources":["a"]}"#);
        assert!(f.can_fetch("a"));
        assert!(!f.can_fetch("b"));
        pol(&f, r#"{"online":true,"enabled_sources":[]}"#);
        assert!(!f.can_fetch("a"));
    }

    #[test]
    fn bad_policies_leave_the_old_one() {
        let f = PolicyFetcher::new();
        pol(&f, r#"{"online":true,"enabled_sources":["a"]}"#);
        for bad in ["nope", "[]", r#"{"enabled_sources":["a"]}"#, r#"{"online":true}"#, r#"{"online":true,"enabled_sources":[1]}"#,
                    r#"{"online":true,"enabled_sources":[],"x":1}"#, r#"{"online":1,"enabled_sources":[]}"#] {
            assert!(f.set_policy_json(Some(bad)).is_err(), "{bad}");
        }
        assert!(f.can_fetch("a"));
    }

    #[test]
    fn the_reason_a_fetch_is_not_allowed_highest_priority_first() {
        let f = PolicyFetcher::new();
        assert_eq!(f.not_allowed("a"), None, "no policy: no reason");
        pol(&f, r#"{"online":false,"allow_metered":false,"metered":true,"enabled_sources":["a"]}"#);
        assert_eq!((f.not_allowed("a"), f.not_allowed("b")), (Some(NotAllowed::Offline), Some(NotAllowed::SwitchedOff)));
        pol(&f, r#"{"online":true,"allow_metered":false,"metered":true,"enabled_sources":["a"]}"#);
        assert_eq!(f.not_allowed("a"), Some(NotAllowed::MeteredOff));
        pol(&f, r#"{"online":true,"allow_metered":true,"metered":true,"enabled_sources":["a"]}"#);
        assert_eq!(f.not_allowed("a"), None);
        assert_eq!(f.stand_in_failure("a"), None);
    }

    #[test]
    fn capture_states_stand_in_for_the_connection() {
        let f = PolicyFetcher::new();
        pol(&f, r#"{"online":true,"enabled_sources":["a","w"],"states":{"*":"metered","w":"fail:quota","n":"normal","o":"off","x":"offline"}}"#);
        assert!(!f.can_fetch("a"));
        assert_eq!(f.not_allowed("a"), Some(NotAllowed::MeteredOff), "\"*\" covers every source");
        assert!(f.can_fetch("w"));
        assert_eq!(f.stand_in_failure("w"), Some("quota"));
        assert_eq!((f.can_fetch("n"), f.not_allowed("n")), (false, None));
        assert_eq!(f.not_allowed("o"), Some(NotAllowed::SwitchedOff));
        assert_eq!(f.not_allowed("x"), Some(NotAllowed::Offline));
        for code in ["fetch_failed", "quota", "key_missing", "bad_response"] {
            pol(&f, &format!(r#"{{"online":false,"enabled_sources":[],"states":{{"s":"fail:{code}"}}}}"#));
            assert_eq!(f.stand_in_failure("s"), Some(code));
        }
        for bad in [r#"{"online":true,"enabled_sources":[],"states":[]}"#, r#"{"online":true,"enabled_sources":[],"states":{"a":"fail:x"}}"#,
                    r#"{"online":true,"enabled_sources":[],"states":{"a":"sleepy"}}"#, r#"{"online":true,"enabled_sources":[],"states":{"a":1}}"#] {
            assert!(f.set_policy_json(Some(bad)).is_err(), "{bad}");
        }
    }

    #[test]
    fn keys_are_set_cleared_and_dropped_with_clear() {
        let f = PolicyFetcher::new();
        f.set_key("s", Some("k1"));
        assert_eq!(f.key_for("s").as_deref(), Some("k1"));
        f.set_key("s", Some("k2"));
        assert_eq!(f.key_for("s").as_deref(), Some("k2"));
        f.set_key("s", None);
        assert!(f.key_for("s").is_none());
        f.set_key("s", Some("k3"));
        f.set_key("t", Some(""));
        assert!(f.key_for("t").is_none());
        pol(&f, r#"{"online":true,"enabled_sources":["s"]}"#);
        f.clear();
        assert!(f.key_for("s").is_none());
        assert!(!f.is_set());
    }
}
