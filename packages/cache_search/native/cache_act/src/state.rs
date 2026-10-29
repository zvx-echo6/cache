//! The installed actions and the `act` tool itself.

use crate::check::{self, bad_arguments};
use crate::def::{self, ActionDef, Effect};
use crate::place::{self, Point};
use crate::render;
use cache_tool::{ConvState, Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Map, Value};
use std::collections::BTreeSet;
use std::sync::{Arc, RwLock};

#[derive(Default)]
struct Registry {
    /// In the order the host gave them (module order, then each module's own order).
    actions: Vec<ActionDef>,
    off: BTreeSet<String>,
}

impl Registry {
    /// The actions the description lists: modules that are off are left out, then the first `MAX_LISTED`.
    fn listed(&self) -> Vec<&ActionDef> {
        self.actions.iter().filter(|a| !self.off.contains(&a.module)).take(render::MAX_LISTED).collect()
    }

    fn not_listed(&self) -> Vec<&ActionDef> {
        self.actions.iter().filter(|a| !self.off.contains(&a.module)).skip(render::MAX_LISTED).collect()
    }
}

/// The handle's actions: installed from the host's definitions, shared with the registered `ActTool`.
#[derive(Default)]
pub struct ActState {
    reg: RwLock<Registry>,
}

/// A field as the action will use it.
enum Val {
    Plain(Value),
    Place(Point),
}

struct Resolved<'a> {
    def: &'a ActionDef,
    fields: Vec<(String, Val)>,
}

impl Resolved<'_> {
    /// `{"name":...,"place":{"lat","lon","name"?,"label"?}}`
    fn machine(&self) -> Value {
        let mut m = Map::new();
        for (k, v) in &self.fields {
            m.insert(k.clone(), match v {
                Val::Plain(v) => v.clone(),
                Val::Place(p) => p.to_json(),
            });
        }
        Value::Object(m)
    }

    /// The fields as the user will recognise them.
    fn summary(&self, ctx: &ToolCtx) -> Value {
        let mut m = Map::new();
        for (k, v) in &self.fields {
            m.insert(k.clone(), match v {
                Val::Plain(v) => v.clone(),
                Val::Place(p) => Value::String(p.display(ctx)),
            });
        }
        Value::Object(m)
    }
}

impl ActState {
    pub fn new() -> ActState {
        ActState::default()
    }

    fn read(&self) -> std::sync::RwLockReadGuard<'_, Registry> {
        self.reg.read().unwrap_or_else(|e| e.into_inner())
    }

    /// Install `defs` (a JSON array) in place of the earlier set. Returns the report
    /// `{"accepted":N,"rejected":[...],"not_listed":[ids]}`; `Err` only when `defs` is not an array.
    pub fn set_definitions(&self, defs: &Value) -> Result<Value, String> {
        let Some(list) = defs.as_array() else { return Err("definitions must be a JSON array".into()) };
        let (actions, rejected) = def::parse_all(list);
        let mut reg = self.reg.write().unwrap_or_else(|e| e.into_inner());
        reg.actions = actions;
        let not_listed: Vec<Value> = reg.not_listed().iter().map(|a| json!(a.id)).collect();
        Ok(json!({"accepted": reg.actions.len(), "rejected": rejected.iter().map(|r| r.to_json()).collect::<Vec<_>>(), "not_listed": not_listed}))
    }

    /// Replace the list of modules that are switched off.
    pub fn set_modules_off(&self, modules: Vec<String>) {
        self.reg.write().unwrap_or_else(|e| e.into_inner()).off = modules.into_iter().collect();
    }

    /// The `act` function schema, or `None` while no action is listed.
    pub fn schema(&self) -> Option<Value> {
        let reg = self.read();
        let listed = reg.listed();
        if listed.is_empty() {
            None
        } else {
            Some(render::schema(&listed))
        }
    }

    /// Check a call against its definition and resolve its places. Never touches the conversation.
    fn prepare(&self, ctx: &ToolCtx, action: &str, fields: &Map<String, Value>) -> Result<(ActionDef, Vec<(String, Val)>), ToolError> {
        let def = {
            let reg = self.read();
            let Some(def) = reg.actions.iter().find(|a| a.id == action) else {
                return Err(ToolError::new("unknown_action", format!("no action named {action}")));
            };
            if reg.off.contains(&def.module) {
                return Err(ToolError::new(ToolError::NOT_SET_UP, format!("{} is not set up", def.module)));
            }
            def.clone()
        };
        let checked = check::check(&def, fields)?;
        let mut out: Vec<(String, Val)> = Vec::new();
        for (f, v) in checked {
            if f.kind == def::Kind::Place {
                let text = v.as_str().unwrap_or("");
                match place::resolve(ctx, text) {
                    Some(p) => out.push((f.name.clone(), Val::Place(p))),
                    None => {
                        return Err(ToolError::new("place_not_found", format!("no place matches {:?}", text.trim())).with("field", f.name.clone()).with("query", text.trim()))
                    }
                }
            } else {
                out.push((f.name.clone(), Val::Plain(v.clone())));
            }
        }
        Ok((def, out))
    }

    /// `cs_act_resolve`: `{"ok":true,"action":...,"fields":{...}}` with places as `{"lat","lon","name"?,"label"?}`.
    pub fn resolve(&self, ctx: &ToolCtx, action: &str, fields: &Value) -> Result<Value, ToolError> {
        let empty = Map::new();
        let fields = match fields {
            Value::Null => &empty,
            Value::Object(m) => m,
            _ => return Err(bad_arguments("fields", "wrong_type", "fields: must be an object")),
        };
        let (def, out) = self.prepare(ctx, action, fields)?;
        let r = Resolved { def: &def, fields: out };
        Ok(json!({"ok": true, "action": action, "fields": r.machine()}))
    }

    /// One `act` call (see `ActTool`).
    pub fn call(&self, ctx: &ToolCtx, args: &Value, state: &mut ConvState) -> Result<ToolOutput, ToolError> {
        let Some(obj) = args.as_object() else {
            return Err(bad_arguments("arguments", "wrong_type", "arguments: must be an object"));
        };
        for k in obj.keys() {
            if k != "action" && k != "fields" {
                return Err(bad_arguments(k, "unknown_field", format!("{k}: not allowed")));
            }
        }
        let action = match obj.get("action") {
            None | Some(Value::Null) => return Err(bad_arguments("action", "missing", "action: required")),
            Some(Value::String(s)) => s.as_str(),
            Some(_) => return Err(bad_arguments("action", "wrong_type", "action: must be a string")),
        };
        let empty = Map::new();
        let fields = match obj.get("fields") {
            None | Some(Value::Null) => &empty,
            Some(Value::Object(m)) => m,
            Some(_) => return Err(bad_arguments("fields", "wrong_type", "fields: must be an object")),
        };
        let (def, out) = self.prepare(ctx, action, fields)?;
        let r = Resolved { def: &def, fields: out };
        let v = match r.def.effect {
            Effect::Change => {
                state.confirms += 1;
                json!({"ok": true, "status": "needs_confirmation", "confirm_id": format!("c{}", state.confirms), "action": action,
                       "title": r.def.title, "summary": r.summary(ctx)})
            }
            Effect::Read | Effect::Open => {
                state.runs += 1;
                let run_id = format!("r{}", state.runs);
                state.pending.push((run_id.clone(), action.to_string()));
                json!({"ok": true, "status": "host_run", "run_id": run_id, "action": action, "fields": r.machine()})
            }
        };
        Ok(ToolOutput::Json(v))
    }
}

/// The `act` tool: registered once on the handle, it offers whatever actions the host has installed.
pub struct ActTool(pub Arc<ActState>);

impl Tool for ActTool {
    fn name(&self) -> &'static str {
        "act"
    }

    fn schema(&self) -> Option<Value> {
        self.0.schema()
    }

    /// The framework always calls `run_in`; this exists for the trait and counts nothing.
    fn run(&self, ctx: &ToolCtx, args: &Value) -> Result<ToolOutput, ToolError> {
        self.0.call(ctx, args, &mut ConvState::default())
    }

    fn run_in(&self, ctx: &ToolCtx, args: &Value, state: &mut ConvState) -> Result<ToolOutput, ToolError> {
        self.0.call(ctx, args, state)
    }

    fn checks_own_arguments(&self) -> bool {
        true
    }
}
