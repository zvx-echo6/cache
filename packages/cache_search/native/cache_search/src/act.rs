//! `cs_act_*`: the glue between the `act` tool (cache_act) and the handle and conversations. The tool itself is `cache_act::ActTool`,
//! registered by `Handle::open`; this file holds the calls the host makes around it (docs/ACTIONS.md).

use crate::conv::Conversation;
use crate::error::{Error, ErrorCode, Result};
use crate::handle::Handle;
use crate::tools::number_json;
use cache_act::reply::{self, Reply};
use cache_tool::ToolCtx;
use serde_json::Value;

fn parse(what: &str, s: &str) -> Result<Value> {
    serde_json::from_str(s).map_err(|e| Error::bad_json(format!("{what}: {e}")))
}

impl Handle {
    /// `cs_act_set_definitions`: install the actions modules publish, replacing the earlier set. Returns the report
    /// `{"accepted":N,"rejected":[{"index","id"?,"field"?,"reason","detail"}],"not_listed":[ids]}`.
    pub fn act_set_definitions(&mut self, defs_json: &str) -> Result<String> {
        let defs = parse("defs_json", defs_json)?;
        let report = self.act.set_definitions(&defs).map_err(Error::bad_json)?;
        Ok(report.to_string())
    }

    /// `cs_act_set_modules_off`: the modules that are switched off; `None` or an empty list switches none off.
    pub fn act_set_modules_off(&mut self, modules_json: Option<&str>) -> Result<()> {
        let list: Vec<String> = match modules_json {
            None => Vec::new(),
            Some(s) => {
                let v = parse("modules_json", s)?;
                let Some(a) = v.as_array() else { return Err(Error::bad_json("modules_json must be an array of module ids")) };
                a.iter().map(|m| m.as_str().map(str::to_string).ok_or_else(|| Error::bad_json("modules_json must be an array of module ids"))).collect::<Result<_>>()?
            }
        };
        self.act.set_modules_off(list);
        Ok(())
    }

    /// `cs_act_resolve`: the same checks and place resolution as an `act` call, nothing run, no confirm id taken. The answer is
    /// `{"ok":true,"action":...,"fields":{...}}`, or the tool's error JSON (a failure is the content, not a C error).
    pub fn act_resolve(&mut self, action: &str, fields_json: Option<&str>) -> Result<String> {
        let fields = match fields_json {
            None => Value::Null,
            Some(s) => parse("fields_json", s)?,
        };
        let source = self.ext.places.read().unwrap_or_else(|e| e.into_inner()).clone();
        let ctx = ToolCtx {
            location: self.location.as_ref(),
            places: &*self.places,
            now: "",
            geocoder: source.as_deref().and_then(|s| s.geocoder()),
            live_fetcher: if self.fetcher.is_set() { Some(&*self.fetcher) } else { None },
        };
        let out = match self.act.resolve(&ctx, action, &fields) {
            Ok(v) => v,
            Err(e) => e.to_json(),
        };
        Ok(out.to_string())
    }
}

impl Conversation {
    /// `cs_act_finish`: the host's reply to a `host_run`. Returns the result for the model: `{"ok":true,"status":"done","action",
    /// "result"}` with the result's `"address"` objects numbered in this conversation, or the shared error shape when the host
    /// reported a failure. An unknown or finished `run_id` is `not_found`, a malformed reply `bad_json`; nothing changes then.
    pub fn act_finish(&mut self, run_id: &str, reply_json: &str) -> Result<String> {
        let v = parse("reply_json", reply_json)?;
        let r = reply::parse_reply(&v).map_err(Error::bad_json)?;
        let action = reply::take_pending(&mut self.tool_state, run_id).map_err(|(_, m)| Error::new(ErrorCode::NotFound, m))?;
        Ok(match r {
            Reply::Done(mut result) => {
                number_json(self, &mut result, &mut Vec::new());
                reply::done_json(&action, result).to_string()
            }
            Reply::Failed(e) => e.to_json().to_string(),
        })
    }

    /// `cs_act_outcome`: what a tap on a confirm card came to, as the system message content, with the result's `"address"`
    /// objects numbered in this conversation.
    pub fn act_outcome(&mut self, outcome_json: &str) -> Result<String> {
        let v = parse("outcome_json", outcome_json)?;
        let o = reply::parse_outcome(&v).map_err(Error::bad_json)?;
        let result = o.result.clone().map(|mut r| {
            number_json(self, &mut r, &mut Vec::new());
            r
        });
        Ok(o.to_json(result).to_string())
    }
}
