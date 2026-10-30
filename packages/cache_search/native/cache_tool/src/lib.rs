//! cache_tool: the tool contract shared by every Cache tool and the framework that runs them.
//!
//! - The framework validates `args` against `Tool::schema()` before `Tool::run` is called.
//! - The framework numbers addresses: `{{addr:<address>}}` markers in text and `"address"` keys in JSON become `[n]` / `"n"`.
//! - A JSON result that lacks `"ok"` gets `"ok":true` added as its first field.
//! - A panic inside `run` becomes an `internal` error.
//! - Field order is preserved (serde_json `preserve_order`), so tools emit fields in TOOLS.md order.

use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

pub mod fetcher;
pub mod hours;
pub mod places;
pub mod user;

/// Start of an address marker in tool text.
/// A citable line starts with `{{addr:<address>}}`; the framework replaces the marker with `[n]`.
pub const ADDRESS_MARKER_OPEN: &str = "{{addr:";
/// End of an address marker in tool text.
pub const ADDRESS_MARKER_CLOSE: &str = "}}";

/// The marker for `address`, e.g. `{{addr:lib:recon/123}}`.
pub fn text_marker(address: &str) -> String {
    format!("{ADDRESS_MARKER_OPEN}{address}{ADDRESS_MARKER_CLOSE}")
}

/// A GPS fix as the app passes it with cs_set_location.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Location {
    pub lat: f64,
    pub lon: f64,
    pub accuracy_m: Option<f64>,
    pub fixed_at: String,
}

/// A saved place ("Home"). `key` is stable across renames; live data is stored by it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct SavedPlace {
    pub key: String,
    pub name: String,
    pub lat: f64,
    pub lon: f64,
    pub label: Option<String>,
}

/// The user's saved places.
pub trait SavedPlaces: Send + Sync {
    fn resolve(&self, name: &str) -> Option<SavedPlace>;
    fn list(&self) -> Vec<SavedPlace>;
}

/// No saved places (headless runs without a user store).
pub struct NoSavedPlaces;

impl SavedPlaces for NoSavedPlaces {
    fn resolve(&self, _name: &str) -> Option<SavedPlace> {
        None
    }
    fn list(&self) -> Vec<SavedPlace> {
        Vec::new()
    }
}

/// The host's grant for live network fetches, and the keys it holds. The host pushes this state in (the handle's
/// `PolicyFetcher`); a tool only asks. `ToolCtx::live_fetcher` is `None` until the host has set a policy.
pub trait LiveFetcher: Send + Sync {
    /// The host allows a network fetch for this source right now.
    fn can_fetch(&self, source_id: &str) -> bool;
    /// The source's API key from the host's secure storage, if it needs one.
    fn key_for(&self, source_id: &str) -> Option<String>;
    /// Why the host does not allow a fetch for this source right now (asked only when `can_fetch` is false); `None` when it
    /// gives no reason (a capture's "normal" state).
    fn not_allowed(&self, _source_id: &str) -> Option<NotAllowed> {
        None
    }
    /// A failure the host stands in for the download, as a tool error code (asked only when `can_fetch` is true; captures only,
    /// `cs serve --live-state fail:<code>`). `None` downloads for real.
    fn stand_in_failure(&self, _source_id: &str) -> Option<&'static str> {
        None
    }
}

/// Why a live fetch is not allowed, highest priority first: live_data says it as `not_refreshed`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum NotAllowed {
    /// The source is not among the ones switched on.
    SwitchedOff,
    /// The phone has no connection.
    Offline,
    /// The phone is on mobile data and updates on mobile data are off.
    MeteredOff,
}

/// What a tool sees of the caller's world.
pub struct ToolCtx<'a> {
    pub location: Option<&'a Location>,
    pub places: &'a dyn SavedPlaces,
    /// Local time now, ISO 8601 with offset, from the caller (the phone's clock; pinned in captures).
    pub now: &'a str,
    /// Names to coordinates through the installed places pack (the one `navigate` and `locate` use); `None` while no pack is
    /// installed, and a tool then resolves saved places and "lat,lon" text only.
    pub geocoder: Option<&'a dyn places::Geocoder>,
    /// The host's live-fetch grant; `None` until the host has set a fetch policy (so captures and tests never fetch).
    pub live_fetcher: Option<&'a dyn LiveFetcher>,
}

/// What a tool returns on success.
pub enum ToolOutput {
    /// search and read: plain text; each citable line holds an address marker (see ADDRESS_MARKER_OPEN) that the framework replaces with [n].
    Text(String),
    /// Every other tool: one JSON object; any object with an "address" key is citable, and the framework replaces "address" with "n".
    Json(Value),
}

/// A tool failure: a stable code, a human detail, and optional extra fields.
#[derive(Clone, Debug, PartialEq)]
pub struct ToolError {
    pub code: String,
    pub detail: String,
    /// Boxed, like [top], so a `Result<_, ToolError>` stays small (clippy's result_large_err); the JSON is the same.
    pub extra: Box<Map<String, Value>>,
    /// Fields beside `error` at the top level of the result (navigate attaches `from_matched` and `to_matched`).
    pub top: Box<Map<String, Value>>,
}

impl ToolError {
    pub const BAD_ARGUMENTS: &'static str = "bad_arguments";
    pub const NO_LOCATION: &'static str = "no_location";
    pub const NOT_SET_UP: &'static str = "not_set_up";
    pub const INTERNAL: &'static str = "internal";
    pub const NOT_FOUND: &'static str = "not_found";
    pub const EXPIRED: &'static str = "expired";
    pub const NO_DATA: &'static str = "no_data";
    pub const UNKNOWN_SOURCE: &'static str = "unknown_source";
    pub const NOT_CONFIGURED: &'static str = "not_configured";
    pub const FETCH_FAILED: &'static str = "fetch_failed";
    pub const QUOTA: &'static str = "quota";
    pub const KEY_MISSING: &'static str = "key_missing";
    pub const BAD_RESPONSE: &'static str = "bad_response";

    pub fn new(code: impl Into<String>, detail: impl Into<String>) -> Self {
        ToolError { code: code.into(), detail: detail.into(), extra: Box::default(), top: Box::default() }
    }

    /// Adds an extra field after the existing ones.
    pub fn with(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.extra.insert(key.into(), value.into());
        self
    }

    /// Adds a top-level field after `error`.
    pub fn with_top(mut self, key: impl Into<String>, value: impl Into<Value>) -> Self {
        self.top.insert(key.into(), value.into());
        self
    }

    /// `{"ok":false,"error":{"type":code,"detail":detail,<extra in insertion order>},<top in insertion order>}`.
    /// An empty detail is left out.
    pub fn to_json(&self) -> Value {
        let mut err = Map::new();
        err.insert("type".into(), Value::String(self.code.clone()));
        if !self.detail.is_empty() {
            err.insert("detail".into(), Value::String(self.detail.clone()));
        }
        for (k, v) in self.extra.iter() {
            err.insert(k.clone(), v.clone());
        }
        let mut out = Map::new();
        out.insert("ok".into(), Value::Bool(false));
        out.insert("error".into(), Value::Object(err));
        for (k, v) in self.top.iter() {
            out.insert(k.clone(), v.clone());
        }
        Value::Object(out)
    }
}

/// What the core keeps per conversation for tools that need to count things across calls. It lives in the conversation
/// (`cs_conv`), is handed to `Tool::run_in`, and is part of a conversation's export only where noted.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ConvState {
    /// Confirm cards the `act` tool has issued (`c1`, `c2`, ...): the number of the last one. Exported when it is above 0.
    pub confirms: u32,
    /// Host runs the `act` tool has started (`r1`, `r2`, ...): the number of the last one. Not exported.
    pub runs: u32,
    /// Runs handed to the host and not yet finished: `(run_id, action)`. Not exported.
    pub pending: Vec<(String, String)>,
}

/// One tool the model can call.
pub trait Tool: Send + Sync {
    fn name(&self) -> &'static str;
    /// Full OpenAI-style function schema built from installed data (runtime enums and descriptions), or None
    /// when nothing it needs is installed: then it is left out of the schemas and a call gives not_set_up.
    fn schema(&self) -> Option<Value>;
    fn run(&self, ctx: &ToolCtx, args: &Value) -> Result<ToolOutput, ToolError>;

    /// `run` for a tool that keeps a count in the conversation. The framework always calls this one; the default ignores
    /// the state and calls `run`.
    fn run_in(&self, ctx: &ToolCtx, args: &Value, _state: &mut ConvState) -> Result<ToolOutput, ToolError> {
        self.run(ctx, args)
    }

    /// True for a tool that checks its own arguments (and reports them with `field` and `reason`): the framework then
    /// skips the generic schema check and passes the arguments through as they came.
    fn checks_own_arguments(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn error_json_bytes() {
        let e = ToolError::new("geocode_empty", "no match").with("which", "to").with("query", "x");
        assert_eq!(
            serde_json::to_string(&e.to_json()).unwrap(),
            r#"{"ok":false,"error":{"type":"geocode_empty","detail":"no match","which":"to","query":"x"}}"#
        );
    }

    #[test]
    fn plain_error_has_no_extra_keys() {
        let e = ToolError::new(ToolError::NO_LOCATION, "no fix");
        assert_eq!(
            serde_json::to_string(&e.to_json()).unwrap(),
            r#"{"ok":false,"error":{"type":"no_location","detail":"no fix"}}"#
        );
    }

    #[test]
    fn preserve_order_is_active() {
        let mut m = Map::new();
        for k in ["z", "a", "m"] {
            m.insert(k.into(), Value::Bool(true));
        }
        assert_eq!(serde_json::to_string(&Value::Object(m)).unwrap(), r#"{"z":true,"a":true,"m":true}"#);
    }

    #[test]
    fn shared_error_codes_are_stable() {
        let codes = [
            ToolError::BAD_ARGUMENTS,
            ToolError::NO_LOCATION,
            ToolError::NOT_SET_UP,
            ToolError::INTERNAL,
            ToolError::NOT_FOUND,
            ToolError::EXPIRED,
            ToolError::NO_DATA,
            ToolError::UNKNOWN_SOURCE,
            ToolError::NOT_CONFIGURED,
            ToolError::FETCH_FAILED,
            ToolError::QUOTA,
            ToolError::KEY_MISSING,
            ToolError::BAD_RESPONSE,
        ];
        assert_eq!(
            codes,
            ["bad_arguments", "no_location", "not_set_up", "internal", "not_found", "expired", "no_data", "unknown_source",
             "not_configured", "fetch_failed", "quota", "key_missing", "bad_response"]
        );
    }

    #[test]
    fn no_saved_places_resolves_nothing() {
        assert!(NoSavedPlaces.resolve("Home").is_none());
        assert!(NoSavedPlaces.list().is_empty());
    }

    #[test]
    fn run_in_defaults_to_run_and_leaves_the_state_alone() {
        let t: Box<dyn Tool> = Box::new(Dummy);
        let ctx = ToolCtx { location: None, places: &NoSavedPlaces, now: "n", geocoder: None, live_fetcher: None };
        let mut st = ConvState::default();
        match t.run_in(&ctx, &Value::Null, &mut st).unwrap() {
            ToolOutput::Text(s) => assert_eq!(s, "{{addr:a/1}} n"),
            ToolOutput::Json(_) => panic!("expected text"),
        }
        assert_eq!(st, ConvState::default());
        assert!(!t.checks_own_arguments());
    }

    #[test]
    fn marker_text() {
        assert_eq!(text_marker("lib:recon/123"), "{{addr:lib:recon/123}}");
    }

    struct Dummy;
    impl Tool for Dummy {
        fn name(&self) -> &'static str {
            "dummy"
        }
        fn schema(&self) -> Option<Value> {
            None
        }
        fn run(&self, ctx: &ToolCtx, _args: &Value) -> Result<ToolOutput, ToolError> {
            Ok(ToolOutput::Text(format!("{} {}", text_marker("a/1"), ctx.now)))
        }
    }

    #[test]
    fn tool_is_object_safe_and_runs() {
        let t: Box<dyn Tool> = Box::new(Dummy);
        let ctx = ToolCtx { location: None, places: &NoSavedPlaces, now: "2026-01-01T00:00:00-07:00", geocoder: None, live_fetcher: None };
        assert_eq!(t.name(), "dummy");
        assert!(t.schema().is_none());
        match t.run(&ctx, &Value::Null).unwrap() {
            ToolOutput::Text(s) => assert_eq!(s, "{{addr:a/1}} 2026-01-01T00:00:00-07:00"),
            ToolOutput::Json(_) => panic!("expected text"),
        }
    }
}
