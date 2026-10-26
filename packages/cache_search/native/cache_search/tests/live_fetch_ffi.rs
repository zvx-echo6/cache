//! cs_live_set_fetch_policy and cs_live_set_key through the C ABI: the host-pushed LiveFetcher, what a tool sees of it in
//! `ToolCtx::live_fetcher`, and that a key is never in anything the core returns.

use cache_search::conv::Conversation;
use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_tool::{LiveFetcher, Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::ptr;

const NOW: &str = "2026-10-26T14:20:05-06:00";
/// A key no output may contain.
const SENTINEL: &str = "SENTINEL-KEY-7f3a9c1e-do-not-leak";

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

/// Reports what its ToolCtx holds, never the key itself.
struct Probe;
impl Tool for Probe {
    fn name(&self) -> &'static str {
        "probe"
    }
    fn schema(&self) -> Option<Value> {
        Some(json!({"type":"function","function":{"name":"probe","description":"d","parameters":{"type":"object","properties":{},
            "required":[],"additionalProperties":false}}}))
    }
    fn run(&self, ctx: &ToolCtx, _args: &Value) -> Result<ToolOutput, ToolError> {
        Ok(ToolOutput::Json(match ctx.live_fetcher {
            None => json!({"live_fetcher": null}),
            Some(f) => json!({"live_fetcher": {"can_fetch_nws": f.can_fetch("nws"), "can_fetch_other": f.can_fetch("other"),
                "has_key": f.key_for("nws").is_some()}}),
        }))
    }
}

struct Fx {
    h: *mut Handle,
    c: *mut Conversation,
    /// Everything the core returned, for the leak search.
    seen: std::cell::RefCell<Vec<String>>,
}

impl Fx {
    fn new() -> Fx {
        let h = unsafe { cs_open(cstr(r#"{"sources":[]}"#).as_ptr()) };
        assert!(!h.is_null());
        unsafe { (*h).register_tool(Box::new(Probe)) };
        Fx { h, c: cs_conversation_new(), seen: Default::default() }
    }

    fn note(&self, s: String) -> String {
        self.seen.borrow_mut().push(s.clone());
        s
    }

    fn probe(&self) -> Value {
        let p = unsafe { cs_tool(self.h, self.c, cstr("probe").as_ptr(), cstr("{}").as_ptr(), cstr(NOW).as_ptr()) };
        let out: Value = serde_json::from_str(&self.note(take(p).unwrap())).unwrap();
        serde_json::from_str(out["content"].as_str().unwrap()).unwrap()
    }

    fn policy(&self, json: Option<&str>) -> i32 {
        let c = json.map(cstr);
        let rc = unsafe { cs_live_set_fetch_policy(self.h, c.as_ref().map_or(ptr::null(), |c| c.as_ptr())) };
        self.errors();
        rc
    }

    fn key(&self, source: &str, key: Option<&str>) -> i32 {
        let k = key.map(cstr);
        let rc = unsafe { cs_live_set_key(self.h, cstr(source).as_ptr(), k.as_ref().map_or(ptr::null(), |c| c.as_ptr())) };
        self.errors();
        rc
    }

    /// Records the last error (reading it leaves it in place).
    fn errors(&self) {
        if let Some(s) = take(unsafe { cs_last_error(self.h) }) {
            self.note(s);
        }
    }

    /// Records the status too (a successful call, so it clears the last error).
    fn snapshot(&self) {
        self.errors();
        if let Some(s) = take(unsafe { cs_status(self.h) }) {
            self.note(s);
        }
    }

    fn fetcher(&self) -> std::sync::Arc<cache_tool::fetcher::PolicyFetcher> {
        unsafe { (*self.h).fetcher.clone() }
    }
}

impl Drop for Fx {
    fn drop(&mut self) {
        unsafe {
            cs_conversation_free(self.c);
            cs_close(self.h);
        }
    }
}

const ALLOW: &str = r#"{"online":true,"allow_metered":false,"metered":false,"enabled_sources":["nws"]}"#;

#[test]
fn no_policy_means_no_fetcher_in_the_tool_context_and_nothing_is_allowed() {
    let f = Fx::new();
    assert_eq!(f.probe(), json!({"ok": true, "live_fetcher": null}));
    assert!(!f.fetcher().can_fetch("nws"));
    // a key alone does not hand the tools a fetcher
    assert_eq!(f.key("nws", Some("k")), 0);
    assert_eq!(f.probe()["live_fetcher"], Value::Null);
    assert!(!f.fetcher().can_fetch("nws"));
}

#[test]
fn a_policy_allows_enabled_sources_and_null_clears_it() {
    let f = Fx::new();
    assert_eq!(f.policy(Some(ALLOW)), 0);
    assert_eq!(f.probe()["live_fetcher"], json!({"can_fetch_nws": true, "can_fetch_other": false, "has_key": false}));
    assert_eq!(f.policy(None), 0);
    assert_eq!(f.probe()["live_fetcher"], Value::Null);
    assert!(!f.fetcher().can_fetch("nws"));
}

#[test]
fn the_metered_rule_and_disabled_sources_and_offline() {
    let f = Fx::new();
    assert_eq!(f.policy(Some(r#"{"online":true,"allow_metered":false,"metered":true,"enabled_sources":["nws"]}"#)), 0);
    assert_eq!(f.probe()["live_fetcher"]["can_fetch_nws"], false, "metered and not allowed");
    assert_eq!(f.policy(Some(r#"{"online":true,"allow_metered":true,"metered":true,"enabled_sources":["nws"]}"#)), 0);
    assert_eq!(f.probe()["live_fetcher"]["can_fetch_nws"], true, "metered and allowed");
    assert_eq!(f.policy(Some(r#"{"online":true,"allow_metered":false,"metered":false,"enabled_sources":["other"]}"#)), 0);
    let p = f.probe();
    assert_eq!((p["live_fetcher"]["can_fetch_nws"].clone(), p["live_fetcher"]["can_fetch_other"].clone()), (json!(false), json!(true)), "disabled source");
    assert_eq!(f.policy(Some(r#"{"online":false,"enabled_sources":["nws"]}"#)), 0);
    assert_eq!(f.probe()["live_fetcher"]["can_fetch_nws"], false, "offline");
}

#[test]
fn a_bad_policy_is_a_c_error_and_changes_nothing() {
    let f = Fx::new();
    assert_eq!(f.policy(Some(ALLOW)), 0);
    assert_eq!(f.policy(Some("not json")), -1);
    let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(f.h) }).unwrap()).unwrap();
    assert_eq!(e["code"], "bad_json");
    assert_eq!(f.probe()["live_fetcher"]["can_fetch_nws"], true);
    unsafe {
        assert_eq!(cs_live_set_fetch_policy(ptr::null_mut(), ptr::null()), -1);
        assert_eq!(cs_live_set_key(f.h, ptr::null(), ptr::null()), -1);
        assert_eq!(cs_live_set_key(ptr::null_mut(), cstr("nws").as_ptr(), ptr::null()), -1);
    }
}

#[test]
fn a_key_is_returned_by_key_for_cleared_by_null_and_gone_after_close() {
    let f = Fx::new();
    assert_eq!(f.key("nws", Some(SENTINEL)), 0);
    assert_eq!(f.fetcher().key_for("nws").as_deref(), Some(SENTINEL));
    assert!(f.fetcher().key_for("other").is_none());
    assert_eq!(f.key("nws", None), 0);
    assert!(f.fetcher().key_for("nws").is_none());

    // set again, then close the handle: the key is gone from the shared fetcher
    assert_eq!(f.key("nws", Some(SENTINEL)), 0);
    assert_eq!(f.policy(Some(ALLOW)), 0);
    let fetcher = f.fetcher();
    assert_eq!(fetcher.key_for("nws").as_deref(), Some(SENTINEL));
    unsafe { cs_close(f.h) };
    assert!(fetcher.key_for("nws").is_none());
    assert!(!fetcher.can_fetch("nws"));
    assert!(!fetcher.is_set());
    // the fixture's Drop must not close twice
    let mut f = f;
    f.h = ptr::null_mut();
    f.c = ptr::null_mut();
}

#[test]
fn the_key_never_appears_in_anything_the_core_returns() {
    let f = Fx::new();
    assert_eq!(f.key("nws", Some(SENTINEL)), 0);
    assert_eq!(f.policy(Some(ALLOW)), 0);
    // tool output that sees the key's presence, a failed tool call, schemas, status, and errors from bad calls
    assert_eq!(f.probe()["live_fetcher"]["has_key"], true);
    for (name, args) in [("probe", "{\"x\":1}"), ("nope", "{}")] {
        let p = unsafe { cs_tool(f.h, f.c, cstr(name).as_ptr(), cstr(args).as_ptr(), cstr(NOW).as_ptr()) };
        f.note(take(p).unwrap());
    }
    f.note(take(unsafe { cs_tool_schemas(f.h) }).unwrap());
    assert_eq!(f.policy(Some(&format!("{{\"online\":true,\"enabled_sources\":[\"nws\"],\"api_key\":\"{SENTINEL}\"}}"))), -1);
    assert_eq!(f.policy(Some("{")), -1);
    assert_eq!(unsafe { cs_live_set_key(f.h, ptr::null(), cstr(SENTINEL).as_ptr()) }, -1);
    f.snapshot();
    assert_eq!(unsafe { cs_live_set_key(ptr::null_mut(), cstr("nws").as_ptr(), cstr(SENTINEL).as_ptr()) }, -1);
    f.note(take(unsafe { cs_conversation_export(f.c) }).unwrap());
    let seen = f.seen.borrow();
    assert!(seen.len() >= 9);
    for s in seen.iter() {
        assert!(!s.contains(SENTINEL), "the key leaked into: {s}");
    }
}
