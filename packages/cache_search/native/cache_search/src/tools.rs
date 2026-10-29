//! `cs_tool_schemas`, `cs_tool`, `cs_set_location`: the tool registry and its dispatch.
//!
//! `search` and `read` are built in. Every other tool is a `cache_tool::Tool` registered on the handle
//! (`Handle::register_tool`). The two built-ins are not `Tool` impls because `Tool::run` sees only the
//! location, the saved places and the clock, while they need the handle's sources and the conversation's
//! number-to-address map. They go through the same validator, numbering and `ok`/error wrapping as the rest.

use crate::conv::{one_line, Conversation};
use crate::error::{Error, ErrorCode, Result};
use crate::handle::Handle;
use crate::html;
use crate::web::{Page, LITTLE_TEXT_CHARS};
use cache_tool::{Location, SavedPlaces, Tool, ToolCtx, ToolError, ToolOutput, ADDRESS_MARKER_CLOSE, ADDRESS_MARKER_OPEN};
use serde_json::{json, Value};
use std::panic::{catch_unwind, AssertUnwindSafe};

/// Gives the query's embedding as `(embedding model id, vector)`, or None when it cannot.
pub type QueryEmbedder = Box<dyn Fn(&str) -> Option<(String, Vec<f32>)> + Send + Sync>;

/// The order of `cs_tool_schemas`. Registered tools with other names follow, in registration order.
pub const TOOL_ORDER: [&str; 8] = ["search", "read", "navigate", "nearby", "locate", "live_data", "calculate", "web_search"];

/// Results of the built-in search.
const SEARCH_K: usize = 5;
/// Characters of text the built-in read returns.
const READ_MAX_CHARS: i32 = 6000;

/// The schema of `search`, verbatim from docs/TOOLS.md.
const SEARCH_SCHEMA: &str = r#"{"type": "function", "function": {
  "name": "search",
  "description": "Search the offline library and reference articles (encyclopedias, manuals, medical and how-to guides) on this phone. Returns up to 5 numbered results. Use it before answering any question about facts or how to do something.",
  "parameters": {"type": "object", "properties": {
    "query": {"type": "string", "minLength": 1, "maxLength": 200,
              "description": "What to search for, in plain words."}},
    "required": ["query"], "additionalProperties": false}}}"#;

/// The schema of `read`, verbatim from docs/TOOLS.md.
const READ_SCHEMA: &str = r#"{"type": "function", "function": {
  "name": "read",
  "description": "Open the full text of one numbered result when its snippet is not enough.",
  "parameters": {"type": "object", "properties": {
    "n": {"type": "integer", "minimum": 1,
          "description": "The number of a result shown earlier in this conversation, e.g. 2 for [2]."}},
    "required": ["n"], "additionalProperties": false}}}"#;

#[derive(Clone, Copy, PartialEq)]
enum Builtin {
    Search,
    Read,
}

impl Builtin {
    fn of(name: &str) -> Option<Builtin> {
        match name {
            "search" => Some(Builtin::Search),
            "read" => Some(Builtin::Read),
            _ => None,
        }
    }

    fn schema(self) -> Value {
        let s = if self == Builtin::Search { SEARCH_SCHEMA } else { READ_SCHEMA };
        serde_json::from_str(s).expect("built-in schema is valid JSON")
    }
}

fn bad_arguments(detail: impl Into<String>) -> ToolError {
    ToolError::new(ToolError::BAD_ARGUMENTS, detail)
}

/// A core error seen as a tool failure: a missing address is `not_found`, anything else `internal`.
fn tool_error(e: Error) -> ToolError {
    let code = if e.code == ErrorCode::NotFound { ToolError::NOT_FOUND } else { ToolError::INTERNAL };
    ToolError::new(code, e.message)
}

// ---- validation -------------------------------------------------------------------------------------------

fn type_ok(t: &str, v: &Value) -> bool {
    match t {
        "string" => v.is_string(),
        "integer" => v.is_i64() || v.is_u64(),
        "number" => v.is_number(),
        "boolean" => v.is_boolean(),
        "object" => v.is_object(),
        _ => true,
    }
}

fn show(v: &Value) -> String {
    match v {
        Value::String(s) => s.clone(),
        other => other.to_string(),
    }
}

/// One value against one property schema: `type`, `enum`, `minLength`, `maxLength`, `minimum`, `maximum`.
/// The error is the detail text, starting with the field name.
fn check_value(field: &str, rules: &Value, v: &Value) -> std::result::Result<(), String> {
    if let Some(t) = rules["type"].as_str() {
        if !type_ok(t, v) {
            let article = if t == "integer" || t == "object" { "an" } else { "a" };
            return Err(format!("{field}: must be {article} {t}"));
        }
    }
    if let Some(allowed) = rules["enum"].as_array() {
        if !allowed.contains(v) {
            let list: Vec<String> = allowed.iter().map(show).collect();
            return Err(format!("{field}: must be one of {}", list.join(", ")));
        }
    }
    if let Some(s) = v.as_str() {
        let len = s.chars().count() as u64;
        if let Some(min) = rules["minLength"].as_u64() {
            if len < min {
                return Err(format!("{field}: must be at least {min} characters"));
            }
        }
        if let Some(max) = rules["maxLength"].as_u64() {
            if len > max {
                return Err(format!("{field}: must be at most {max} characters"));
            }
        }
    }
    if let Some(x) = v.as_f64().filter(|_| v.is_number()) {
        if let Some(min) = rules["minimum"].as_f64() {
            if x < min {
                return Err(format!("{field}: must be at least {}", rules["minimum"]));
            }
        }
        if let Some(max) = rules["maximum"].as_f64() {
            if x > max {
                return Err(format!("{field}: must be at most {}", rules["maximum"]));
            }
        }
    }
    Ok(())
}

/// Check `args` against the `parameters` of a function schema (`{"type":"function","function":{...}}`).
/// The subset: `type` (string, integer, number, boolean, object), `enum`, `minLength`, `maxLength`, `minimum`,
/// `maximum`, `required` and `additionalProperties: false`. Defaults are not filled in. The error is the
/// `bad_arguments` detail, `"<field>: <what>"`.
pub fn validate_args(schema: &Value, args: &Value) -> std::result::Result<(), String> {
    let params = &schema["function"]["parameters"];
    let Some(obj) = args.as_object() else {
        return Err("arguments: must be an object".to_string());
    };
    if let Some(req) = params["required"].as_array() {
        for name in req.iter().filter_map(Value::as_str) {
            if !obj.contains_key(name) {
                return Err(format!("{name}: required"));
            }
        }
    }
    let props = params["properties"].as_object();
    for (k, v) in obj {
        match props.and_then(|p| p.get(k)) {
            Some(rules) => check_value(k, rules, v)?,
            None if params["additionalProperties"] == Value::Bool(false) => return Err(format!("{k}: not allowed")),
            None => {}
        }
    }
    Ok(())
}

// ---- numbering --------------------------------------------------------------------------------------------

/// Replace each `{{addr:<address>}}` marker with `[n]`, numbering the address in `conv`. New numbers are pushed
/// to `ids`. The title of a line is the text after its marker up to ` — `, or the rest of the line.
fn number_text(conv: &mut Conversation, text: &str, ids: &mut Vec<Value>) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find(ADDRESS_MARKER_OPEN) {
        let after_open = start + ADDRESS_MARKER_OPEN.len();
        let Some(len) = rest[after_open..].find(ADDRESS_MARKER_CLOSE) else { break };
        let address = &rest[after_open..after_open + len];
        let after = after_open + len + ADDRESS_MARKER_CLOSE.len();
        let line = rest[after..].split('\n').next().unwrap_or("");
        let title = line.split(" \u{2014} ").next().unwrap_or("").trim();
        let (n, new) = conv.number(address, title);
        if new {
            ids.push(conv.id_value(n));
        }
        out.push_str(&rest[..start]);
        out.push_str(&format!("[{n}]"));
        rest = &rest[after..];
    }
    out.push_str(rest);
    out
}

/// Walk `v` depth first in document order. In every object with a string `"address"`, that key becomes
/// `"n": <number>` at the same position. The title is the object's `title`, `name`, `place_name` or `label`.
fn number_json(conv: &mut Conversation, v: &mut Value, ids: &mut Vec<Value>) {
    match v {
        Value::Object(m) => {
            if let Some(Value::String(address)) = m.get("address") {
                let title = ["title", "name", "place_name", "label"]
                    .iter()
                    .find_map(|k| m.get(*k).and_then(Value::as_str))
                    .unwrap_or("")
                    .to_string();
                let (n, new) = conv.number(address, &title);
                if new {
                    ids.push(conv.id_value(n));
                }
                let old = std::mem::take(m);
                for (k, x) in old {
                    if k == "address" {
                        m.insert("n".to_string(), json!(n));
                    } else {
                        m.insert(k, x);
                    }
                }
            }
            for x in m.values_mut() {
                number_json(conv, x, ids);
            }
        }
        Value::Array(a) => a.iter_mut().for_each(|x| number_json(conv, x, ids)),
        _ => {}
    }
}

/// A JSON result without `"ok"` gets `"ok": true` as its first key.
fn add_ok(v: &mut Value) {
    if let Value::Object(m) = v {
        if !m.contains_key("ok") {
            let old = std::mem::take(m);
            m.insert("ok".to_string(), Value::Bool(true));
            for (k, x) in old {
                m.insert(k, x);
            }
        }
    }
}

// ---- the handle's side ------------------------------------------------------------------------------------

impl Handle {
    /// Add a tool to the registry. A tool already registered under the same name is replaced. The names `search`
    /// and `read` belong to the built-in tools and cannot be replaced.
    pub fn register_tool(&mut self, tool: Box<dyn Tool>) {
        self.tools.retain(|t| t.name() != tool.name());
        self.tools.push(tool);
    }

    /// Set the user's saved places (the default is none). For the features-core crates to plug in.
    pub fn set_saved_places(&mut self, places: Box<dyn SavedPlaces>) {
        self.places = places;
    }

    /// Set what built-in `search` uses to embed its query. Without one, search is keyword-only.
    pub fn set_query_embedder(&mut self, embedder: QueryEmbedder) {
        self.embedder = Some(embedder);
    }

    /// `cs_set_location`: `accuracy_m < 0` means unknown.
    pub fn set_location(&mut self, lat: f64, lon: f64, accuracy_m: f64, fixed_at: &str) -> Result<()> {
        if !(lat.is_finite() && (-90.0..=90.0).contains(&lat)) {
            return Err(Error::bad_json("lat must be between -90 and 90"));
        }
        if !(lon.is_finite() && (-180.0..=180.0).contains(&lon)) {
            return Err(Error::bad_json("lon must be between -180 and 180"));
        }
        if fixed_at.trim().is_empty() {
            return Err(Error::bad_json("fixed_at is required"));
        }
        let accuracy_m = if accuracy_m.is_finite() && accuracy_m >= 0.0 { Some(accuracy_m) } else { None };
        self.location = Some(Location { lat, lon, accuracy_m, fixed_at: fixed_at.to_string() });
        Ok(())
    }

    pub fn clear_location(&mut self) {
        self.location = None;
    }

    /// `cs_tool_schemas`: a JSON array of the function schemas of the available tools, in `TOOL_ORDER`.
    pub fn tool_schemas_json(&self) -> String {
        let mut out: Vec<Value> = Vec::new();
        for name in TOOL_ORDER {
            match Builtin::of(name) {
                Some(b) => out.push(b.schema()),
                None => out.extend(self.tools.iter().filter(|t| t.name() == name).filter_map(|t| t.schema())),
            }
        }
        for t in &self.tools {
            if !TOOL_ORDER.contains(&t.name()) {
                out.extend(t.schema());
            }
        }
        Value::Array(out).to_string()
    }

    /// `cs_tool`: run one tool call and number its result in `conv`.
    /// Returns `{"content":"<the tool message>","ids":[{"n","address","title"}...new ones...]}`. A failure of the
    /// tool (bad arguments, no such tool, ...) is the content; only malformed `args_json` or an empty `now` fail.
    pub fn call_tool(&mut self, conv: &mut Conversation, name: &str, args_json: &str, now: &str) -> Result<String> {
        if now.trim().is_empty() {
            return Err(Error::bad_json("now is required"));
        }
        let args: Value = serde_json::from_str(args_json).map_err(|e| Error::bad_json(format!("args_json: {e}")))?;
        let mut ids: Vec<Value> = Vec::new();
        let result = self.run_tool(conv, name, &args, now);
        // What web_search showed is remembered in the conversation, so a later read can fall back to the snippet.
        for (address, note) in self.web.take_pending() {
            conv.note_web(&address, note);
        }
        let timing = self.web.take_timing();
        let content = match result {
            Ok(ToolOutput::Text(t)) => number_text(conv, &t, &mut ids),
            Ok(ToolOutput::Json(mut v)) => {
                number_json(conv, &mut v, &mut ids);
                add_ok(&mut v);
                v.to_string()
            }
            Err(e) => e.to_json().to_string(),
        };
        let mut out = json!({"content": content, "ids": ids});
        if let Some(t) = timing {
            // Debug only: never part of what the model sees.
            out["timing_ms"] = t;
        }
        Ok(out.to_string())
    }

    /// Steps 1 to 3 of the dispatch: find the tool, validate the arguments, run it (a panic is `internal`).
    fn run_tool(&mut self, conv: &Conversation, name: &str, args: &Value, now: &str) -> std::result::Result<ToolOutput, ToolError> {
        let builtin = Builtin::of(name);
        let index = self.tools.iter().position(|t| t.name() == name);
        let schema = match (builtin, index) {
            (Some(b), _) => b.schema(),
            (None, None) => return Err(bad_arguments(format!("no tool named {name}"))),
            (None, Some(i)) => match self.tools[i].schema() {
                Some(s) => s,
                None => return Err(ToolError::new(ToolError::NOT_SET_UP, format!("{name} is not set up"))),
            },
        };
        validate_args(&schema, args).map_err(bad_arguments)?;
        let run = catch_unwind(AssertUnwindSafe(|| match (builtin, index) {
            (Some(Builtin::Search), _) => self.run_search(args),
            (Some(Builtin::Read), _) => self.run_read(conv, args),
            (None, i) => {
                // the installed places pack (if any) is the geocoder tools resolve names through
                let source = self.ext.places.read().unwrap_or_else(|e| e.into_inner()).clone();
                let ctx = ToolCtx {
                    location: self.location.as_ref(),
                    places: &*self.places,
                    now,
                    geocoder: source.as_deref().and_then(|s| s.geocoder()),
                    // only once the host has pushed a policy; before that no tool can fetch
                    live_fetcher: if self.fetcher.is_set() { Some(&*self.fetcher) } else { None },
                };
                self.tools[i.expect("checked above")].run(&ctx, args)
            }
        }));
        run.unwrap_or_else(|_| Err(ToolError::new(ToolError::INTERNAL, format!("{name} failed"))))
    }

    /// Built-in `search`: the top 5 as `{{addr:<address>}} <title> — <snippet>` lines (the same title and snippet
    /// rules as `cs_format`; one line each, no ` — ` when the snippet is empty).
    fn run_search(&mut self, args: &Value) -> std::result::Result<ToolOutput, ToolError> {
        let query = args["query"].as_str().unwrap_or("");
        let mut opts = json!({"k": SEARCH_K});
        if let Some((model, vector)) = self.embedder.as_ref().and_then(|embed| embed(query)) {
            opts["query_vector"] = json!({"model": model, "vector": vector});
        }
        let out = self.search(query, Some(&opts.to_string())).map_err(tool_error)?;
        let v: Value = serde_json::from_str(&out).map_err(|e| ToolError::new(ToolError::INTERNAL, e.to_string()))?;
        let mut seen: Vec<&str> = Vec::new();
        let mut lines: Vec<String> = Vec::new();
        for r in v["results"].as_array().into_iter().flatten() {
            let Some(address) = r["address"].as_str() else { continue };
            if seen.contains(&address) {
                continue;
            }
            seen.push(address);
            let (title, snippet) = (one_line(r["title"].as_str().unwrap_or("")), one_line(r["snippet"].as_str().unwrap_or("")));
            let marker = cache_tool::text_marker(address);
            lines.push(if snippet.is_empty() { format!("{marker} {title}") } else { format!("{marker} {title} \u{2014} {snippet}") });
        }
        if lines.is_empty() {
            return Ok(ToolOutput::Text("No results found.".to_string()));
        }
        Ok(ToolOutput::Text(lines.join("\n")))
    }

    /// Built-in `read`: `[n] <title>`, the text, and `[truncated]` on its own line when it was cut. It keeps the
    /// number it was asked for, so it writes `[n]` itself and no marker.
    fn run_read(&mut self, conv: &Conversation, args: &Value) -> std::result::Result<ToolOutput, ToolError> {
        let n = args["n"].as_u64().unwrap_or(0) as usize;
        let Some((address, _)) = conv.entry(n) else {
            return Err(ToolError::new(ToolError::NOT_FOUND, format!("no result [{n}] in this conversation")));
        };
        if let Some(url) = address.strip_prefix("web:") {
            return Ok(self.read_web(conv, n, address, url));
        }
        let out = self.read(&address.clone(), READ_MAX_CHARS).map_err(tool_error)?;
        let v: Value = serde_json::from_str(&out).map_err(|e| ToolError::new(ToolError::INTERNAL, e.to_string()))?;
        let mut text = format!("[{n}] {}\n{}", one_line(v["title"].as_str().unwrap_or("")), v["text"].as_str().unwrap_or(""));
        if v["truncated"] == Value::Bool(true) {
            text.push_str("\n[truncated]");
        }
        Ok(ToolOutput::Text(text))
    }

    /// `read` on a `web:<url>` result: fetch the page within the read budget. When it loads, `[n] <title> (web,
    /// fetched <time>)`, the text and `[truncated]` as for any read. When it does not, the same first line, the
    /// snippet kept from the search, and `[full page did not load in time]` or `[full page not available]`; that is
    /// still a result, not an error. A page with under `LITTLE_TEXT_CHARS` of text gives the first line, the snippet,
    /// the text, and `[page had little readable text]`.
    fn read_web(&mut self, conv: &Conversation, n: usize, address: &str, url: &str) -> ToolOutput {
        let head = match conv.web_note(address) {
            Some(w) => format!("[{n}] {} (web, fetched {})", w.title, w.fetched),
            None => format!("[{n}] {}", conv.entry(n).map(|(_, t)| one_line(t)).unwrap_or_default()),
        };
        let text = match self.web.read_page(url) {
            Page::Text { text, .. } if text.trim().chars().count() < LITTLE_TEXT_CHARS => {
                // a script-rendered shell: show the snippet first, then whatever text there was, then say so
                let mut s = head;
                if let Some(w) = conv.web_note(address).filter(|w| !w.snippet.is_empty()) {
                    s.push('\n');
                    s.push_str(&w.snippet);
                }
                if !text.trim().is_empty() {
                    s.push('\n');
                    s.push_str(text.trim());
                }
                s.push_str("\n[page had little readable text]");
                s
            }
            Page::Text { text, capped } => {
                let (cut, was_cut) = html::cut_at_paragraph(text.trim(), READ_MAX_CHARS as usize);
                let mut s = format!("{head}\n{cut}");
                if was_cut || capped {
                    s.push_str("\n[truncated]");
                }
                s
            }
            miss => {
                let mut s = head;
                if let Some(w) = conv.web_note(address).filter(|w| !w.snippet.is_empty()) {
                    s.push('\n');
                    s.push_str(&w.snippet);
                }
                s.push_str(if miss == Page::TimedOut { "\n[full page did not load in time]" } else { "\n[full page not available]" });
                s
            }
        };
        ToolOutput::Text(text)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cache_tool::{text_marker, SavedPlace};
    use std::sync::{Arc, Mutex};

    type RunFn = Box<dyn Fn(&ToolCtx, &Value) -> std::result::Result<ToolOutput, ToolError> + Send + Sync>;

    struct Dummy {
        name: &'static str,
        schema: Option<Value>,
        run: RunFn,
    }

    impl Tool for Dummy {
        fn name(&self) -> &'static str {
            self.name
        }
        fn schema(&self) -> Option<Value> {
            self.schema.clone()
        }
        fn run(&self, ctx: &ToolCtx, args: &Value) -> std::result::Result<ToolOutput, ToolError> {
            (self.run)(ctx, args)
        }
    }

    fn schema_of(name: &str, params: Value) -> Value {
        json!({"type": "function", "function": {"name": name, "description": "d", "parameters": params}})
    }

    fn any_schema(name: &str) -> Value {
        schema_of(name, json!({"type": "object", "properties": {}, "required": [], "additionalProperties": false}))
    }

    fn dummy(name: &'static str, run: RunFn) -> Box<dyn Tool> {
        Box::new(Dummy { name, schema: Some(any_schema(name)), run })
    }

    const NOW: &str = "2026-10-25T12:00:00-06:00";

    fn handle() -> Handle {
        Handle::open(r#"{"sources":[]}"#).unwrap()
    }

    fn call(h: &mut Handle, c: &mut Conversation, name: &str, args: &str) -> Value {
        serde_json::from_str(&h.call_tool(c, name, args, NOW).unwrap()).unwrap()
    }

    // ---- validation ----

    fn params() -> Value {
        schema_of(
            "t",
            json!({"type": "object", "properties": {
                "s": {"type": "string", "minLength": 2, "maxLength": 4},
                "i": {"type": "integer", "minimum": 1, "maximum": 10},
                "x": {"type": "number", "minimum": 0.5},
                "b": {"type": "boolean"},
                "o": {"type": "object"},
                "e": {"type": "string", "enum": ["a", "b"]}},
                "required": ["s"], "additionalProperties": false}),
        )
    }

    fn verr(args: Value) -> String {
        validate_args(&params(), &args).unwrap_err()
    }

    #[test]
    fn validator_accepts_good_arguments_and_fills_no_defaults() {
        assert!(validate_args(&params(), &json!({"s": "abc"})).is_ok());
        assert!(validate_args(&params(), &json!({"s": "ab", "i": 10, "x": 0.5, "b": false, "o": {}, "e": "b"})).is_ok());
        let schema = schema_of("t", json!({"type": "object", "properties": {"n": {"type": "integer", "default": 5}}}));
        assert!(validate_args(&schema, &json!({})).is_ok());
    }

    #[test]
    fn validator_names_the_field() {
        assert_eq!(verr(json!([])), "arguments: must be an object");
        assert_eq!(verr(json!({})), "s: required");
        assert_eq!(verr(json!({"s": 5})), "s: must be a string");
        assert_eq!(verr(json!({"s": "a"})), "s: must be at least 2 characters");
        assert_eq!(verr(json!({"s": "abcde"})), "s: must be at most 4 characters");
        assert_eq!(verr(json!({"s": "ab", "i": "1"})), "i: must be an integer");
        assert_eq!(verr(json!({"s": "ab", "i": 1.5})), "i: must be an integer");
        assert_eq!(verr(json!({"s": "ab", "i": 0})), "i: must be at least 1");
        assert_eq!(verr(json!({"s": "ab", "i": 11})), "i: must be at most 10");
        assert_eq!(verr(json!({"s": "ab", "x": "1"})), "x: must be a number");
        assert_eq!(verr(json!({"s": "ab", "x": 0.25})), "x: must be at least 0.5");
        assert_eq!(verr(json!({"s": "ab", "b": 1})), "b: must be a boolean");
        assert_eq!(verr(json!({"s": "ab", "o": []})), "o: must be an object");
        assert_eq!(verr(json!({"s": "ab", "e": "c"})), "e: must be one of a, b");
        assert_eq!(verr(json!({"s": "ab", "zzz": 1})), "zzz: not allowed");
    }

    #[test]
    fn length_counts_characters_not_bytes() {
        assert!(validate_args(&params(), &json!({"s": "\u{e9}\u{e9}\u{e9}\u{e9}"})).is_ok());
    }

    #[test]
    fn additional_properties_are_allowed_unless_false() {
        let schema = schema_of("t", json!({"type": "object", "properties": {}}));
        assert!(validate_args(&schema, &json!({"anything": 1})).is_ok());
    }

    #[test]
    fn built_in_schemas_are_toolsmd_verbatim() {
        let s = Builtin::Search.schema();
        assert_eq!(s["function"]["name"], "search");
        assert_eq!(s["function"]["parameters"]["properties"]["query"]["maxLength"], 200);
        let r = Builtin::Read.schema();
        assert_eq!(r["function"]["parameters"]["required"], json!(["n"]));
        // search is validated with its own schema
        assert_eq!(validate_args(&s, &json!({"query": ""})).unwrap_err(), "query: must be at least 1 characters");
        assert_eq!(validate_args(&r, &json!({"n": 0})).unwrap_err(), "n: must be at least 1");
    }

    // ---- dispatch ----

    #[test]
    fn bad_arguments_come_back_as_content() {
        let mut h = handle();
        let mut c = Conversation::new();
        let v = call(&mut h, &mut c, "search", r#"{"query":""}"#);
        assert_eq!(
            v["content"],
            r#"{"ok":false,"error":{"type":"bad_arguments","detail":"query: must be at least 1 characters"}}"#
        );
        assert_eq!(v["ids"], json!([]));
    }

    #[test]
    fn malformed_args_json_and_empty_now_are_c_errors() {
        let mut h = handle();
        let mut c = Conversation::new();
        assert_eq!(h.call_tool(&mut c, "search", "{", NOW).unwrap_err().code, ErrorCode::BadJson);
        assert_eq!(h.call_tool(&mut c, "search", "", NOW).unwrap_err().code, ErrorCode::BadJson);
        assert_eq!(h.call_tool(&mut c, "search", r#"{"query":"x"}"#, "").unwrap_err().code, ErrorCode::BadJson);
        assert_eq!(h.call_tool(&mut c, "search", r#"{"query":"x"}"#, "  ").unwrap_err().code, ErrorCode::BadJson);
    }

    #[test]
    fn unknown_tool_and_tool_without_a_schema() {
        let mut h = handle();
        let mut c = Conversation::new();
        let v = call(&mut h, &mut c, "nope", "{}");
        assert_eq!(v["content"], r#"{"ok":false,"error":{"type":"bad_arguments","detail":"no tool named nope"}}"#);
        h.register_tool(Box::new(Dummy { name: "nearby", schema: None, run: Box::new(|_, _| panic!("must not run")) }));
        let v = call(&mut h, &mut c, "nearby", "{}");
        assert_eq!(v["content"], r#"{"ok":false,"error":{"type":"not_set_up","detail":"nearby is not set up"}}"#);
    }

    #[test]
    fn schemas_are_in_fixed_order_and_skip_tools_without_one() {
        let mut h = handle();
        let names = |h: &Handle| -> Vec<String> {
            let v: Value = serde_json::from_str(&h.tool_schemas_json()).unwrap();
            v.as_array().unwrap().iter().map(|s| s["function"]["name"].as_str().unwrap().to_string()).collect()
        };
        assert_eq!(names(&h), ["search", "read", "calculate"]);
        for n in ["web_search", "locate", "extra", "nearby"] {
            h.register_tool(dummy(n, Box::new(|_, _| Ok(ToolOutput::Text(String::new())))));
        }
        h.register_tool(Box::new(Dummy { name: "navigate", schema: None, run: Box::new(|_, _| unreachable!()) }));
        assert_eq!(names(&h), ["search", "read", "nearby", "locate", "calculate", "web_search", "extra"]);
    }

    #[test]
    fn registering_a_name_twice_replaces_the_first() {
        let mut h = handle();
        let mut c = Conversation::new();
        h.register_tool(dummy("locate", Box::new(|_, _| Ok(ToolOutput::Text("one".into())))));
        h.register_tool(dummy("locate", Box::new(|_, _| Ok(ToolOutput::Text("two".into())))));
        assert_eq!(call(&mut h, &mut c, "locate", "{}")["content"], "two");
    }

    #[test]
    fn json_tool_with_nested_addresses_is_numbered_in_place() {
        let mut h = handle();
        let mut c = Conversation::new();
        h.register_tool(dummy(
            "nearby",
            Box::new(|_, _| {
                let v: Value = serde_json::from_str(
                    r#"{"category":"pharmacy","items":[{"name":"Walgreens","address":"osm:node/1","street":"Main"},{"address":"osm:node/2","label":"Smith","sub":{"address":"osm:node/3","title":"Deep"}},{"address":"osm:node/1","name":"again"}],"z":{"a":1}}"#,
                )
                .unwrap();
                Ok(ToolOutput::Json(v))
            }),
        ));
        let v = call(&mut h, &mut c, "nearby", "{}");
        assert_eq!(
            v["content"],
            r#"{"ok":true,"category":"pharmacy","items":[{"name":"Walgreens","n":1,"street":"Main"},{"n":2,"label":"Smith","sub":{"n":3,"title":"Deep"}},{"n":1,"name":"again"}],"z":{"a":1}}"#
        );
        assert_eq!(
            v["ids"],
            json!([{"n":1,"address":"osm:node/1","title":"Walgreens"},{"n":2,"address":"osm:node/2","title":"Smith"},{"n":3,"address":"osm:node/3","title":"Deep"}])
        );
        // a second call: known addresses keep their numbers and only new ones are returned
        let v = call(&mut h, &mut c, "nearby", "{}");
        assert!(v["content"].as_str().unwrap().contains(r#""n":3"#));
        assert_eq!(v["ids"], json!([]));
    }

    #[test]
    fn an_ok_already_there_stays_where_it_is() {
        let mut h = handle();
        let mut c = Conversation::new();
        h.register_tool(dummy("locate", Box::new(|_, _| Ok(ToolOutput::Json(json!({"lat": 1, "ok": true, "lon": 2}))))));
        assert_eq!(call(&mut h, &mut c, "locate", "{}")["content"], r#"{"lat":1,"ok":true,"lon":2}"#);
        // and a non-object result is passed on as it is
        h.register_tool(dummy("live_data", Box::new(|_, _| Ok(ToolOutput::Json(json!([1, 2]))))));
        assert_eq!(call(&mut h, &mut c, "live_data", "{}")["content"], "[1,2]");
    }

    #[test]
    fn a_tool_error_is_unnumbered_content() {
        let mut h = handle();
        let mut c = Conversation::new();
        h.register_tool(dummy(
            "locate",
            Box::new(|_, _| Err(ToolError::new(ToolError::NO_LOCATION, "no fix").with("hint", "turn on GPS"))),
        ));
        let v = call(&mut h, &mut c, "locate", "{}");
        assert_eq!(v["content"], r#"{"ok":false,"error":{"type":"no_location","detail":"no fix","hint":"turn on GPS"}}"#);
        assert_eq!(v["ids"], json!([]));
    }

    #[test]
    fn a_tool_error_keeps_top_level_fields_in_order_and_omits_an_empty_detail() {
        let mut h = handle();
        let mut c = Conversation::new();
        h.register_tool(dummy(
            "locate",
            Box::new(|_, _| {
                Err(ToolError::new("no_route", "").with_top("from_matched", json!({"place_name": "A"})).with_top("to_matched", json!(null)))
            }),
        ));
        let v = call(&mut h, &mut c, "locate", "{}");
        assert_eq!(
            v["content"],
            r#"{"ok":false,"error":{"type":"no_route"},"from_matched":{"place_name":"A"},"to_matched":null}"#
        );
        assert_eq!(v["ids"], json!([]));
    }

    #[test]
    fn a_panicking_tool_is_an_internal_error() {
        let mut h = handle();
        let mut c = Conversation::new();
        h.register_tool(dummy("locate", Box::new(|_, _| panic!("boom"))));
        let v = call(&mut h, &mut c, "locate", "{}");
        assert_eq!(v["content"], r#"{"ok":false,"error":{"type":"internal","detail":"locate failed"}}"#);
        // the handle still works
        assert!(h.tool_schemas_json().starts_with('['));
    }

    #[test]
    fn text_markers_become_numbers_and_repeats_keep_theirs() {
        let mut h = handle();
        let mut c = Conversation::new();
        h.register_tool(dummy(
            "web_search",
            Box::new(|_, _| {
                Ok(ToolOutput::Text(format!(
                    "{} First \u{2014} snippet with \u{2014} dash\n{} Second title only\n{} First \u{2014} again",
                    text_marker("a/1"),
                    text_marker("a/2"),
                    text_marker("a/1")
                )))
            }),
        ));
        let v = call(&mut h, &mut c, "web_search", "{}");
        assert_eq!(v["content"], "[1] First \u{2014} snippet with \u{2014} dash\n[2] Second title only\n[1] First \u{2014} again");
        assert_eq!(v["ids"], json!([{"n":1,"address":"a/1","title":"First"},{"n":2,"address":"a/2","title":"Second title only"}]));
        // cs_format afterwards: the same address keeps its number
        let f: Value = serde_json::from_str(&c.format(r#"[{"address":"a/3","title":"C","snippet":"s"},{"address":"a/2","title":"B","snippet":"t"}]"#).unwrap()).unwrap();
        assert_eq!(f["tool_message"], "[3] C \u{2014} s\n[2] B \u{2014} t");
    }

    #[test]
    fn an_unclosed_marker_is_left_alone() {
        let mut c = Conversation::new();
        let mut ids = Vec::new();
        assert_eq!(number_text(&mut c, "x {{addr:abc", &mut ids), "x {{addr:abc");
        assert!(ids.is_empty());
    }

    #[test]
    fn read_with_an_unknown_number() {
        let mut h = handle();
        let mut c = Conversation::new();
        let v = call(&mut h, &mut c, "read", r#"{"n":9}"#);
        assert_eq!(v["content"], r#"{"ok":false,"error":{"type":"not_found","detail":"no result [9] in this conversation"}}"#);
        assert_eq!(v["ids"], json!([]));
    }

    // ---- location, places, now ----

    #[derive(Clone, Default)]
    struct Seen(Arc<Mutex<Vec<String>>>);

    #[test]
    fn location_places_and_now_reach_the_tool() {
        struct Places;
        impl SavedPlaces for Places {
            fn resolve(&self, name: &str) -> Option<SavedPlace> {
                (name == "Home").then(|| SavedPlace { key: "home".into(), name: "Home".into(), lat: 1.0, lon: 2.0, label: None })
            }
            fn list(&self) -> Vec<SavedPlace> {
                Vec::new()
            }
        }
        let seen = Seen::default();
        let s2 = seen.clone();
        let mut h = handle();
        let mut c = Conversation::new();
        h.set_saved_places(Box::new(Places));
        h.register_tool(dummy(
            "locate",
            Box::new(move |ctx, _| {
                s2.0.lock().unwrap().push(format!("{:?}|{}|{}", ctx.location, ctx.places.resolve("Home").is_some(), ctx.now));
                Ok(ToolOutput::Json(json!({})))
            }),
        ));
        call(&mut h, &mut c, "locate", "{}");
        h.set_location(42.5, -113.75, 12.0, "2026-10-25T11:59:00-06:00").unwrap();
        call(&mut h, &mut c, "locate", "{}");
        h.set_location(42.5, -113.75, -1.0, "2026-10-25T11:59:00-06:00").unwrap();
        call(&mut h, &mut c, "locate", "{}");
        h.clear_location();
        call(&mut h, &mut c, "locate", "{}");
        let seen = seen.0.lock().unwrap();
        assert_eq!(seen[0], format!("None|true|{NOW}"));
        assert_eq!(
            seen[1],
            format!("Some(Location {{ lat: 42.5, lon: -113.75, accuracy_m: Some(12.0), fixed_at: \"2026-10-25T11:59:00-06:00\" }})|true|{NOW}")
        );
        assert!(seen[2].contains("accuracy_m: None"), "{}", seen[2]);
        assert_eq!(seen[3], seen[0]);
    }

    #[test]
    fn bad_locations_are_refused() {
        let mut h = handle();
        for (lat, lon, at) in [(91.0, 0.0, "x"), (0.0, 181.0, "x"), (f64::NAN, 0.0, "x"), (0.0, 0.0, " ")] {
            assert_eq!(h.set_location(lat, lon, 5.0, at).unwrap_err().code, ErrorCode::BadJson);
        }
        assert!(h.location.is_none());
    }

    #[test]
    fn default_places_are_empty() {
        let h = handle();
        assert!(h.places.list().is_empty());
        assert!(h.places.resolve("Home").is_none());
    }
}
