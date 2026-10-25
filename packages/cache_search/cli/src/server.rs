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
//!   DELETE /conversations/{id}                                   -> cs_conversation_free
//!   GET    /tools                                                -> cs_tool_schemas
//!   POST   /location        {lat, lon, accuracy_m, fixed_at}     -> cs_set_location ({"ok":true}; accuracy_m optional)
//!   DELETE /location                                             -> cs_clear_location ({"ok":true})
//!   POST   /conversations/{id}/tool  {name, args, now}           -> cs_tool ({"content","ids"})
//!   GET    /places                                               -> cs_places_list
//!   POST   /places                       {place}                 -> cs_place_save (the body is the place JSON)
//!   DELETE /places/{key}                                         -> cs_place_delete
//!   GET    /live/sources                                         -> cs_live_sources
//!   POST   /live/fetch                   {request}               -> cs_live_fetch (the body is the request JSON)
//!   POST   /live/get                     {request}               -> cs_live_get (the body is the request JSON)
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

pub struct State {
    pub engine: Engine,
    convs: HashMap<String, Conv>,
    next: u64,
}

impl State {
    pub fn new(engine: Engine) -> State {
        State { engine, convs: HashMap::new(), next: 1 }
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
        (Method::Post, ["conversations", id, "format"]) => {
            let v = body_json(body)?;
            if !v["results"].is_array() {
                return Err(ApiError::new("bad_json", "\"results\" (array) is required"));
            }
            st.convs.get_mut(*id).ok_or_else(|| conv_not_found(id))?.format(&v["results"].to_string())
        }
        (Method::Get, ["conversations", id, "ids"]) => st.convs.get_mut(*id).ok_or_else(|| conv_not_found(id))?.ids(),
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
        (Method::Post, ["conversations", id, "tool"]) => {
            let v = body_json(body)?;
            let name = need_str(&v, "name")?;
            let args = if v["args"].is_null() { json!({}) } else { v["args"].clone() };
            let now = v["now"].as_str().unwrap_or("");
            let conv = st.convs.get_mut(*id).ok_or_else(|| conv_not_found(id))?;
            st.engine.core.tool(conv, name, &args.to_string(), now)
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
        _ => Err(ApiError::new("not_found", format!("no such endpoint: {method} {path}"))),
    }
}

/// Bind and serve until the process is stopped. Prints `listening <addr>` on stdout once it accepts connections.
pub fn run(engine: Engine, listen: &str) -> Result<(), ApiError> {
    let server = Server::http(listen).map_err(|e| ApiError::new("io", format!("binding {listen}: {e}")))?;
    let addr = server.server_addr().to_string();
    println!("listening {addr}");
    use std::io::Write;
    let _ = std::io::stdout().flush();
    let mut st = State::new(engine);
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
