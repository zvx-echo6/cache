//! `cs serve`: HTTP in front of the same calls. JSON in, the core's JSON out, byte for byte. Requests are handled
//! one at a time on one thread, which is what the C ABI asks of a handle.
//!
//! Endpoints:
//!   POST   /search                       {query, options}        -> cs_search
//!   POST   /read                         {address, max_chars}    -> cs_read
//!   POST   /suggest                      {prefix, options}       -> cs_suggest
//!   GET    /status                                               -> cs_status
//!   POST   /conversations                                        -> {"id"} (cs_conversation_new)
//!   POST   /conversations/{id}/format    {results}               -> cs_format
//!   GET    /conversations/{id}/ids                               -> cs_conversation_ids
//!   GET    /conversations/{id}/export                            -> cs_conversation_export (the state, format 1)
//!   POST   /conversations/import         (the body is an export) -> {"id"}: a new conversation (cs_conversation_import)
//!   DELETE /conversations/{id}                                   -> cs_conversation_free
//!   GET    /tools                                                -> cs_tool_schemas
//!   POST   /location        {lat, lon, accuracy_m, fixed_at}     -> cs_set_location ({"ok":true}; accuracy_m optional)
//!   DELETE /location                                             -> cs_clear_location ({"ok":true})
//!   POST   /web             {provider, key, online}              -> cs_set_web ({"ok":true}; the key is never echoed or logged)
//!   DELETE /web                                                  -> web search off, key cleared ({"ok":true})
//!   POST   /live/policy    {online,allow_metered?,metered?,enabled_sources} -> cs_live_set_fetch_policy ({"ok":true})
//!   DELETE /live/policy                                          -> policy cleared: no fetch allowed ({"ok":true})
//!   POST   /live/key       {source_id, key}                      -> cs_live_set_key ({"ok":true}; the key is never echoed or logged)
//!   DELETE /live/key/{source_id}                                 -> that key cleared ({"ok":true})
//!   POST   /conversations/{id}/tool  {name, args, now}           -> cs_tool ({"content","ids"})
//!   POST   /act/definitions              (the body is the JSON array of action definitions) -> cs_act_set_definitions (the report)
//!   POST   /act/modules-off              (the body is a JSON array of module ids; empty = none) -> cs_act_set_modules_off ({"ok":true})
//!   POST   /act/resolve                  {action, fields?}       -> cs_act_resolve
//!   POST   /conversations/{id}/act/finish   {run_id, reply?}     -> cs_act_finish. Without "reply", the run's scripted reply from
//!                                                                  --action-results ("run", by the run's action) is used
//!   POST   /conversations/{id}/act/outcome  {outcome} | {confirm_id, action?} -> cs_act_outcome. Without "outcome", the scripted tap
//!                                                                  ("tap", by the card's action) is used; the card's action is known
//!                                                                  from the needs_confirmation this conversation was given
//!   GET    /places                                               -> cs_places_list
//!   POST   /places                       {place}                 -> cs_place_save (the body is the place JSON)
//!   DELETE /places/{key}                                         -> cs_place_delete
//!   GET    /live/sources                                         -> cs_live_sources
//!   POST   /live/fetch                   {request}               -> cs_live_fetch (the body is the request JSON)
//!   POST   /live/get                     {request}               -> cs_live_get (the body is the request JSON)
//!   POST   /map/search | /map/route | /map/progress  (the body is the request JSON) -> cs_map_search | cs_map_route | cs_map_progress
//!   GET    /video/instances                                      -> cs_video_instances
//!   POST   /video/{instance-add|instance-remove|login|refresh|me|channels|list|search|get|delete|resolve}
//!                                        (the body is the request JSON) -> cs_video_<name>
//!   POST   /video/download {instance,video,choice?,token?} -> a video_download job, run to the end: its last progress
//!                                                           JSON (the request is `cs video-download`'s)
//!   GET    /video/downloads                                      -> cs_video_downloads
//!   GET    /layers                                               -> cs_layers_list
//!   POST   /layers/refresh                                       -> cs_layers_refresh
//!   POST   /layers                       {definition}            -> cs_layers_save (the body is the definition JSON)
//!   DELETE /layers/{id}                                          -> cs_layers_remove
//!   POST   /layers/plan|delete           {request}               -> cs_layers_plan | cs_layers_delete
//!   POST   /layers/download              {request}               -> a layer_download job, waited for (as `cs layers download`)
//!   POST   /layers/clear-cache           {layer?}                -> cs_layers_clear_cache
//!   POST   /layers/tile                  {layer,z,x,y}           -> cs_layers_tile, as the summary `cs layers tile` prints
//!   POST   /layers/server                {online?}               -> cs_layers_server (the tile server lives on its own port)
//! Errors are `{"code","message"}` (the core's error) with a matching HTTP status.

use crate::engine::{ApiError, Conv, Engine};
use serde_json::{json, Value};
use std::collections::HashMap;
use std::net::{SocketAddr, ToSocketAddrs};
use tiny_http::{Header, Method, Response, Server};

/// Refuse a listen address that is not loopback unless the operator said so.
pub fn check_listen(listen: &str, allow_non_loopback: bool) -> Result<(), ApiError> {
    let addrs: Vec<SocketAddr> = listen
        .to_socket_addrs()
        .map_err(|e| ApiError::new("bad_json", format!("--listen {listen:?}: {e}")))?
        .collect();
    if addrs.is_empty() {
        return Err(ApiError::new("bad_json", format!("--listen {listen:?} resolves to nothing")));
    }
    if !allow_non_loopback && addrs.iter().any(|a| !a.ip().is_loopback()) {
        return Err(ApiError::new(
            "bad_json",
            format!("--listen {listen:?} is not a loopback address; pass --allow-non-loopback to bind it"),
        ));
    }
    Ok(())
}

/// The scripted host of `cs serve --action-results <file>`: what the capture harness plays when the model asks for a
/// read or open action ("run", the reply to a `host_run`) and when the user taps a confirm card ("tap"). Both are keyed by
/// action id:
///
/// ```json
/// {"run": {"places.list": {"ok": true, "result": {"places": []}},
///          "places.open": {"ok": false, "error": {"type": "unavailable", "detail": "Maps is not installed"}}},
///  "tap": {"places.save": {"status": "done", "result": {"saved": "Elk camp"}},
///          "places.delete": {"status": "declined"},
///          "home.source_switch": {"status": "failed", "error": {"type": "denied", "detail": "location is off"}}}}
/// ```
///
/// A "run" value is the `reply` of `cs_act_finish` as it is. A "tap" value is `status` (done, declined or failed) with the
/// `result` of a done tap or the `error` of a failed one; the server adds `ok`, `confirm_id` and `action` to make the outcome
/// `cs_act_outcome` takes.
#[derive(Default)]
pub struct ActScript {
    run: serde_json::Map<String, Value>,
    tap: serde_json::Map<String, Value>,
}

impl ActScript {
    pub fn parse(text: &str) -> Result<ActScript, ApiError> {
        let bad = |m: String| ApiError::new("bad_json", format!("--action-results: {m}"));
        let v: Value = serde_json::from_str(text).map_err(|e| bad(e.to_string()))?;
        let Some(o) = v.as_object() else { return Err(bad("must be a JSON object with \"run\" and/or \"tap\"".into())) };
        if let Some(k) = o.keys().find(|k| *k != "run" && *k != "tap") {
            return Err(bad(format!("unknown key {k:?} (only \"run\" and \"tap\")")));
        }
        let table = |key: &str| -> Result<serde_json::Map<String, Value>, ApiError> {
            match o.get(key) {
                None => Ok(Default::default()),
                Some(Value::Object(m)) => Ok(m.clone()),
                Some(_) => Err(bad(format!("\"{key}\" must be an object keyed by action id"))),
            }
        };
        let (run, tap) = (table("run")?, table("tap")?);
        for (a, r) in &run {
            if !r.get("ok").is_some_and(Value::is_boolean) {
                return Err(bad(format!("run.{a}: needs \"ok\" (true with a \"result\", false with an \"error\")")));
            }
        }
        for (a, t) in &tap {
            let status = t.get("status").and_then(Value::as_str).unwrap_or("");
            let fine = match status {
                "done" => t.get("result").is_some_and(|r| !r.is_null()),
                "declined" => true,
                "failed" => t.get("error").is_some_and(Value::is_object),
                _ => false,
            };
            if !fine {
                return Err(bad(format!("tap.{a}: \"status\" is done (with a \"result\"), declined, or failed (with an \"error\")")));
            }
        }
        Ok(ActScript { run, tap })
    }

    /// The outcome `cs_act_outcome` takes, for the card `confirm_id` of `action`.
    fn outcome(&self, confirm_id: &str, action: &str) -> Result<Value, ApiError> {
        let t = self.tap.get(action).ok_or_else(|| ApiError::new("not_found", format!("no scripted tap for {action}")))?;
        let status = t["status"].as_str().unwrap_or("");
        let mut o = json!({"ok": status != "failed", "status": status, "confirm_id": confirm_id, "action": action});
        if let Some(r) = t.get("result") {
            o["result"] = r.clone();
        }
        if status == "failed" {
            o["error"] = t["error"].clone();
        }
        Ok(o)
    }
}

pub struct State {
    pub engine: Engine,
    convs: HashMap<String, Conv>,
    next: u64,
    pub script: ActScript,
    /// Runs and cards the conversations were handed, so a finish or a tap can name just the id: `(conversation, id) -> action`.
    runs: HashMap<(String, String), String>,
    cards: HashMap<(String, String), String>,
}

impl State {
    pub fn new(engine: Engine) -> State {
        State { engine, convs: HashMap::new(), next: 1, script: ActScript::default(), runs: HashMap::new(), cards: HashMap::new() }
    }

    /// Remember the `host_run` or `needs_confirmation` a `cs_tool` call gave.
    fn note_act(&mut self, conv: &str, tool_reply: &str) {
        let Ok(v) = serde_json::from_str::<Value>(tool_reply) else { return };
        let Some(Ok(c)) = v["content"].as_str().map(serde_json::from_str::<Value>) else { return };
        let (action, key) = (c["action"].as_str(), (conv.to_string(), String::new()));
        let Some(action) = action else { return };
        match c["status"].as_str() {
            Some("host_run") => {
                if let Some(id) = c["run_id"].as_str() {
                    self.runs.insert((key.0, id.to_string()), action.to_string());
                }
            }
            Some("needs_confirmation") => {
                if let Some(id) = c["confirm_id"].as_str() {
                    self.cards.insert((key.0, id.to_string()), action.to_string());
                }
            }
            _ => {}
        }
    }
}

fn body_json(body: &str) -> Result<Value, ApiError> {
    if body.trim().is_empty() {
        return Ok(json!({}));
    }
    serde_json::from_str(body).map_err(|e| ApiError::new("bad_json", format!("request body: {e}")))
}

fn need_str<'a>(v: &'a Value, key: &str) -> Result<&'a str, ApiError> {
    v[key].as_str().ok_or_else(|| ApiError::new("bad_json", format!("\"{key}\" (string) is required")))
}

/// `options` from a request: absent or null means `{}`; anything but an object is an error.
fn options_of(v: &Value) -> Result<Value, ApiError> {
    match &v["options"] {
        Value::Null => Ok(json!({})),
        o @ Value::Object(_) => Ok(o.clone()),
        _ => Err(ApiError::new("bad_json", "\"options\" must be an object")),
    }
}

fn conv_not_found(id: &str) -> ApiError {
    ApiError::new("not_found", format!("no conversation {id:?}"))
}

/// Route one request. Returns (HTTP status, JSON body).
pub fn handle(st: &mut State, method: &Method, path: &str, body: &str) -> (u16, String) {
    match route(st, method, path, body) {
        Ok(s) => (200, s),
        Err(e) => (e.http_status(), e.to_json()),
    }
}

fn route(st: &mut State, method: &Method, path: &str, body: &str) -> Result<String, ApiError> {
    let path = path.split('?').next().unwrap_or("");
    let segs: Vec<&str> = path.trim_matches('/').split('/').collect();
    match (method, segs.as_slice()) {
        (Method::Post, ["search"]) => {
            let v = body_json(body)?;
            let q = need_str(&v, "query")?;
            st.engine.search(q, options_of(&v)?)
        }
        (Method::Post, ["read"]) => {
            let v = body_json(body)?;
            let max = match &v["max_chars"] {
                Value::Null => 6000,
                m => m.as_i64().filter(|n| i32::try_from(*n).is_ok()).ok_or_else(|| ApiError::new("bad_json", "\"max_chars\" must be an integer"))? as i32,
            };
            st.engine.core.read(need_str(&v, "address")?, max)
        }
        (Method::Post, ["suggest"]) => {
            let v = body_json(body)?;
            let p = need_str(&v, "prefix")?;
            st.engine.core.suggest(p, &options_of(&v)?.to_string())
        }
        (Method::Get, ["status"]) => st.engine.core.status(),
        (Method::Post, ["conversations"]) => {
            let id = format!("c{}", st.next);
            st.next += 1;
            st.convs.insert(id.clone(), Conv::new()?);
            Ok(json!({"id": id}).to_string())
        }
        (Method::Post, ["conversations", "import"]) => {
            let conv = Conv::import(body)?;
            let id = format!("c{}", st.next);
            st.next += 1;
            st.convs.insert(id.clone(), conv);
            Ok(json!({"id": id}).to_string())
        }
        (Method::Post, ["conversations", id, "format"]) => {
            let v = body_json(body)?;
            if !v["results"].is_array() {
                return Err(ApiError::new("bad_json", "\"results\" (array) is required"));
            }
            st.convs.get_mut(*id).ok_or_else(|| conv_not_found(id))?.format(&v["results"].to_string())
        }
        (Method::Get, ["conversations", id, "ids"]) => st.convs.get_mut(*id).ok_or_else(|| conv_not_found(id))?.ids(),
        (Method::Get, ["conversations", id, "export"]) => st.convs.get_mut(*id).ok_or_else(|| conv_not_found(id))?.export(),
        (Method::Get, ["tools"]) => st.engine.core.tool_schemas(),
        (Method::Post, ["location"]) => {
            let v = body_json(body)?;
            let num = |key: &str| v[key].as_f64().ok_or_else(|| ApiError::new("bad_json", format!("\"{key}\" (number) is required")));
            let accuracy = if v["accuracy_m"].is_null() { -1.0 } else { num("accuracy_m")? };
            st.engine.core.set_location(num("lat")?, num("lon")?, accuracy, need_str(&v, "fixed_at")?)?;
            Ok(json!({"ok": true}).to_string())
        }
        (Method::Delete, ["location"]) => {
            st.engine.core.clear_location()?;
            Ok(json!({"ok": true}).to_string())
        }
        (Method::Post, ["web"]) => {
            let v = body_json(body)?;
            let opt = |key: &str| match &v[key] {
                Value::Null => Ok(None),
                Value::String(s) => Ok(Some(s.as_str())),
                _ => Err(ApiError::new("bad_json", format!("\"{key}\" must be a string"))),
            };
            let online = v["online"].as_bool().ok_or_else(|| ApiError::new("bad_json", "\"online\" (boolean) is required"))?;
            st.engine.core.set_web(opt("provider")?, opt("key")?, online)?;
            Ok(json!({"ok": true}).to_string())
        }
        (Method::Delete, ["web"]) => {
            st.engine.core.set_web(None, None, false)?;
            Ok(json!({"ok": true}).to_string())
        }
        (Method::Post, ["live", "policy"]) => {
            // the body is the policy document itself; the core validates it
            body_json(body)?;
            st.engine.core.set_live_policy(Some(body))?;
            Ok(json!({"ok": true}).to_string())
        }
        (Method::Delete, ["live", "policy"]) => {
            st.engine.core.set_live_policy(None)?;
            Ok(json!({"ok": true}).to_string())
        }
        (Method::Post, ["live", "key"]) => {
            let v = body_json(body)?;
            let key = match &v["key"] {
                Value::Null => None,
                Value::String(s) => Some(s.as_str()),
                _ => return Err(ApiError::new("bad_json", "\"key\" must be a string")),
            };
            st.engine.core.set_live_key(need_str(&v, "source_id")?, key)?;
            Ok(json!({"ok": true}).to_string())
        }
        (Method::Delete, ["live", "key", source_id]) => {
            st.engine.core.set_live_key(source_id, None)?;
            Ok(json!({"ok": true}).to_string())
        }
        (Method::Post, ["conversations", id, "tool"]) => {
            let v = body_json(body)?;
            let name = need_str(&v, "name")?;
            let args = if v["args"].is_null() { json!({}) } else { v["args"].clone() };
            let now = v["now"].as_str().unwrap_or("");
            let conv = st.convs.get_mut(*id).ok_or_else(|| conv_not_found(id))?;
            let out = st.engine.core.tool(conv, name, &args.to_string(), now)?;
            if name == "act" {
                st.note_act(id, &out);
            }
            Ok(out)
        }
        (Method::Post, ["act", "definitions"]) => st.engine.core.act_set_definitions(body),
        (Method::Post, ["act", "modules-off"]) => {
            let none = body.trim().is_empty();
            st.engine.core.act_set_modules_off(if none { None } else { Some(body) })?;
            Ok(json!({"ok": true}).to_string())
        }
        (Method::Post, ["act", "resolve"]) => {
            let v = body_json(body)?;
            let fields = if v["fields"].is_null() { None } else { Some(v["fields"].to_string()) };
            st.engine.core.act_resolve(need_str(&v, "action")?, fields.as_deref())
        }
        (Method::Post, ["conversations", id, "act", "finish"]) => {
            let v = body_json(body)?;
            let run_id = need_str(&v, "run_id")?;
            let reply = match &v["reply"] {
                Value::Null => {
                    let action = st.runs.get(&(id.to_string(), run_id.to_string())).ok_or_else(|| ApiError::new("not_found", format!("no run {run_id} was handed out by this conversation")))?;
                    st.script.run.get(action).ok_or_else(|| ApiError::new("not_found", format!("no scripted reply for {action}")))?.to_string()
                }
                r => r.to_string(),
            };
            let conv = st.convs.get_mut(*id).ok_or_else(|| conv_not_found(id))?;
            conv.act_finish(run_id, &reply)
        }
        (Method::Post, ["conversations", id, "act", "outcome"]) => {
            let v = body_json(body)?;
            let outcome = match &v["outcome"] {
                Value::Null => {
                    let confirm_id = need_str(&v, "confirm_id")?;
                    let known = st.cards.get(&(id.to_string(), confirm_id.to_string())).cloned();
                    let action = match (v["action"].as_str(), known) {
                        (Some(a), _) => a.to_string(),
                        (None, Some(a)) => a,
                        (None, None) => return Err(ApiError::new("not_found", format!("no card {confirm_id} was handed out by this conversation; give \"action\""))),
                    };
                    st.script.outcome(confirm_id, &action)?
                }
                o => o.clone(),
            };
            let conv = st.convs.get_mut(*id).ok_or_else(|| conv_not_found(id))?;
            conv.act_outcome(&outcome.to_string())
        }
        (Method::Delete, ["conversations", id]) => {
            st.convs.remove(*id).ok_or_else(|| conv_not_found(id))?;
            Ok(json!({"deleted": id}).to_string())
        }
        (Method::Get, ["places"]) => st.engine.core.places_list(),
        (Method::Post, ["places"]) => st.engine.core.place_save(body),
        (Method::Delete, ["places", key]) => st.engine.core.place_delete(key),
        (Method::Get, ["live", "sources"]) => st.engine.core.live_sources(),
        (Method::Post, ["live", "fetch"]) => st.engine.core.live_fetch(body),
        (Method::Post, ["live", "get"]) => st.engine.core.live_get(body),
        (Method::Post, ["map", "search"]) => st.engine.core.map_search(body),
        (Method::Post, ["map", "route"]) => st.engine.core.map_route(body),
        (Method::Post, ["map", "progress"]) => st.engine.core.map_progress(body),
        (Method::Get, ["video", "instances"]) => st.engine.core.video_instances(),
        (Method::Get, ["video", "downloads"]) => st.engine.core.video_downloads(),
        (Method::Post, ["video", op]) => match *op {
            "instance-add" => st.engine.core.video_instance_add(body),
            "instance-remove" => st.engine.core.video_instance_remove(body),
            "login" => st.engine.core.video_login(body),
            "refresh" => st.engine.core.video_refresh(body),
            "me" => st.engine.core.video_me(body),
            "channels" => st.engine.core.video_channels(body),
            "list" => st.engine.core.video_list(body),
            "search" => st.engine.core.video_search(body),
            "get" => st.engine.core.video_get(body),
            "delete" => st.engine.core.video_delete(body),
            "resolve" => st.engine.core.video_resolve(body),
            // runs the download job to the end before answering (requests are handled one at a time)
            "download" => st.engine.video_download(&body_json(body)?, &mut |_| {}),
            _ => Err(ApiError::new("not_found", format!("no such endpoint: {method} {path}"))),
        },
        (Method::Get, ["layers"]) => st.engine.core.layers_list(),
        (Method::Post, ["layers", "refresh"]) => st.engine.core.layers_refresh(),
        (Method::Post, ["layers"]) => st.engine.core.layers_save(body),
        (Method::Delete, ["layers", id]) => st.engine.core.layers_remove(id),
        (Method::Post, ["layers", "plan"]) => st.engine.core.layers_plan(body),
        (Method::Post, ["layers", "delete"]) => st.engine.core.layers_delete(body),
        (Method::Post, ["layers", "download"]) => {
            let v = body_json(body)?;
            st.engine.core.layers_download(&v, &mut |_| {})
        }
        (Method::Post, ["layers", "clear-cache"]) => {
            let v = body_json(body)?;
            st.engine.core.layers_clear_cache(v["layer"].as_str())
        }
        (Method::Post, ["layers", "tile"]) => {
            let v = body_json(body)?;
            let n = |k: &str| v[k].as_i64().and_then(|n| i32::try_from(n).ok()).ok_or_else(|| ApiError::new("bad_json", format!("\"{k}\" (integer) is required")));
            let (z, x, y) = (n("z")?, n("x")?, n("y")?);
            let layer = need_str(&v, "layer")?;
            let (mime, bytes) = st.engine.core.layers_tile(layer, z, x, y)?;
            Ok(crate::commands::tile_summary(layer, z, x, y, &mime, &bytes))
        }
        (Method::Post, ["layers", "server"]) => {
            let v = body_json(body)?;
            let o = v["online"].as_bool().map(|b| json!({"online": b}).to_string());
            st.engine.core.layers_server(o.as_deref())
        }
        _ => Err(ApiError::new("not_found", format!("no such endpoint: {method} {path}"))),
    }
}

/// Bind and serve until the process is stopped. Prints `listening <addr>` on stdout once it accepts connections.
pub fn run(engine: Engine, listen: &str, script: ActScript) -> Result<(), ApiError> {
    let server = Server::http(listen).map_err(|e| ApiError::new("io", format!("binding {listen}: {e}")))?;
    let addr = server.server_addr().to_string();
    println!("listening {addr}");
    use std::io::Write;
    let _ = std::io::stdout().flush();
    let mut st = State::new(engine);
    st.script = script;
    let json_header = Header::from_bytes("Content-Type", "application/json").expect("header");
    for mut req in server.incoming_requests() {
        let mut body = String::new();
        let (status, out) = match std::io::Read::read_to_string(req.as_reader(), &mut body) {
            Ok(_) => handle(&mut st, &req.method().clone(), &req.url().to_string(), &body),
            Err(e) => (400, ApiError::new("bad_json", format!("reading the request body: {e}")).to_json()),
        };
        let _ = req.respond(Response::from_string(out).with_status_code(status).with_header(json_header.clone()));
    }
    Ok(())
}
