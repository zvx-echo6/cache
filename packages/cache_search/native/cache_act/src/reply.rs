//! The host's side of the exchange (docs/ACTIONS.md): the reply that finishes a read or open run, and the outcome of a tap on a
//! confirm card. This file only checks and shapes them; the core numbers any `"address"` objects in a result (in cache_search,
//! which owns the conversation's id map).

use cache_tool::{ConvState, ToolError};
use serde_json::{json, Map, Value};

/// A reply to a `host_run`.
pub enum Reply {
    Done(Value),
    Failed(ToolError),
}

/// `{"ok":true,"result":...}` or `{"ok":false,"error":{"type","detail"?}}`. The error text is the message a person reads.
pub fn parse_reply(v: &Value) -> Result<Reply, String> {
    let Some(o) = v.as_object() else { return Err("reply must be a JSON object".into()) };
    match o.get("ok").and_then(Value::as_bool) {
        Some(true) => match o.get("result") {
            Some(r) if !r.is_null() => Ok(Reply::Done(r.clone())),
            _ => Err("reply with ok true needs a \"result\"".into()),
        },
        Some(false) => Ok(Reply::Failed(error_of(o.get("error"))?)),
        None => Err("reply needs \"ok\" (true or false)".into()),
    }
}

fn error_of(e: Option<&Value>) -> Result<ToolError, String> {
    let Some(e) = e.and_then(Value::as_object) else { return Err("a failed reply needs an \"error\" object".into()) };
    let Some(t) = e.get("type").and_then(Value::as_str).filter(|t| !t.is_empty()) else {
        return Err("\"error\" needs a \"type\" (text)".into());
    };
    let detail = match e.get("detail") {
        None | Some(Value::Null) => "",
        Some(Value::String(s)) => s.as_str(),
        Some(_) => return Err("\"error.detail\" must be text".into()),
    };
    Ok(ToolError::new(t, detail))
}

/// `{"ok":true,"status":"done","action":...,"result":...}`: what the model sees after a run.
pub fn done_json(action: &str, result: Value) -> Value {
    json!({"ok": true, "status": "done", "action": action, "result": result})
}

/// Take `run_id` off the conversation's pending runs and give its action. The error is `(code, message)`.
pub fn take_pending(state: &mut ConvState, run_id: &str) -> Result<String, (&'static str, String)> {
    if let Some(i) = state.pending.iter().position(|(id, _)| id == run_id) {
        return Ok(state.pending.remove(i).1);
    }
    let finished = run_id.strip_prefix('r').and_then(|n| n.parse::<u32>().ok()).is_some_and(|n| n >= 1 && n <= state.runs);
    if finished {
        Err(("not_found", format!("run {run_id} is already finished")))
    } else {
        Err(("not_found", format!("no run {run_id} in this conversation")))
    }
}

pub const OUTCOME_STATUSES: [&str; 3] = ["done", "declined", "failed"];

/// A tap's outcome as the host reports it.
pub struct Outcome {
    pub status: String,
    pub confirm_id: String,
    pub action: String,
    pub result: Option<Value>,
    pub error: Option<ToolError>,
}

/// `{"ok","status":"done|declined|failed","confirm_id","action","result"?|"error"?}`. `done` needs `ok` true and a `result`,
/// `declined` needs `ok` true, `failed` needs `ok` false and an `error` with a `type`.
pub fn parse_outcome(v: &Value) -> Result<Outcome, String> {
    let Some(o) = v.as_object() else { return Err("outcome must be a JSON object".into()) };
    let text = |k: &str| o.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string).ok_or_else(|| format!("outcome needs \"{k}\" (text)"));
    let status = text("status")?;
    if !OUTCOME_STATUSES.contains(&status.as_str()) {
        return Err(format!("status must be done, declined or failed, not {status:?}"));
    }
    let (confirm_id, action) = (text("confirm_id")?, text("action")?);
    let ok = o.get("ok").and_then(Value::as_bool).ok_or("outcome needs \"ok\" (true or false)")?;
    if ok != (status != "failed") {
        return Err(format!("status {status} goes with ok {}", status != "failed"));
    }
    let (mut result, mut error) = (None, None);
    match status.as_str() {
        "done" => match o.get("result") {
            Some(r) if !r.is_null() => result = Some(r.clone()),
            _ => return Err("a done outcome needs a \"result\"".into()),
        },
        "failed" => error = Some(error_of(o.get("error"))?),
        _ => {}
    }
    Ok(Outcome { status, confirm_id, action, result, error })
}

impl Outcome {
    /// The system message content, keys in this order: `host_event`, `ok`, `status`, `confirm_id`, `action`, then `result` or
    /// `error`. `result` is the (already numbered) result.
    pub fn to_json(&self, result: Option<Value>) -> Value {
        let mut m = Map::new();
        m.insert("host_event".into(), json!("act_outcome"));
        m.insert("ok".into(), json!(self.status != "failed"));
        m.insert("status".into(), json!(self.status));
        m.insert("confirm_id".into(), json!(self.confirm_id));
        m.insert("action".into(), json!(self.action));
        if let Some(r) = result {
            m.insert("result".into(), r);
        }
        if let Some(e) = &self.error {
            let mut err = Map::new();
            err.insert("type".into(), json!(e.code));
            if !e.detail.is_empty() {
                err.insert("detail".into(), json!(e.detail));
            }
            m.insert("error".into(), Value::Object(err));
        }
        Value::Object(m)
    }
}
