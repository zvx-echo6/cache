//! The live-fetch grant: what the host allows and the keys it holds, pushed in by the host (no callbacks).
//!
//! `PolicyFetcher` is the handle's built-in `LiveFetcher`. It answers from state the host pushed with
//! `cs_live_set_fetch_policy` and `cs_live_set_key`. With no policy set it denies every fetch, so captures and tests
//! never fetch. Keys live in memory only: there is no `Debug`, no serialisation, and no error ever holds one.

use crate::LiveFetcher;
use serde_json::Value;
use std::collections::HashMap;
use std::sync::Mutex;

struct Policy {
    online: bool,
    allow_metered: bool,
    metered: bool,
    enabled_sources: Vec<String>,
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

    /// Sets the policy from `{"online":bool,"allow_metered":bool,"metered":bool,"enabled_sources":[ids]}`
    /// (`allow_metered` and `metered` default to false). `None` clears it. A bad document leaves the old policy and
    /// returns the reason (which never holds a key: the document has none).
    pub fn set_policy_json(&self, json: Option<&str>) -> Result<(), String> {
        let Some(json) = json else {
            self.lock().policy = None;
            return Ok(());
        };
        let v: Value = serde_json::from_str(json).map_err(|e| format!("policy: {e}"))?;
        let obj = v.as_object().ok_or("policy must be a JSON object")?;
        if let Some(k) = obj.keys().find(|k| !["online", "allow_metered", "metered", "enabled_sources"].contains(&k.as_str())) {
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
        self.lock().policy = Some(Policy { online, allow_metered, metered, enabled_sources });
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
            Some(p) => p.online && p.enabled_sources.iter().any(|s| s == source_id) && (!p.metered || p.allow_metered),
            None => false,
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
