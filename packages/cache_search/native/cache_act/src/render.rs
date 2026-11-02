//! What the model sees: the `act` tool's description and schema (docs/ACTIONS.md, "What the model sees"). The model is trained
//! on this exact text; do not change it without new captures.

use crate::def::{ActionDef, Effect, Kind};
use serde_json::{json, Value};

/// At most this many actions are listed.
pub const MAX_LISTED: usize = 40;

pub const HEADER: &str = "Do something in one of the app's modules. Actions marked (confirm) show the user a confirm card; nothing changes until they tap it. * = required. Actions:";

/// `places.save(name:string*, place:place*, note:string) - Save a place to the user's saved places. (confirm)`
pub fn line(d: &ActionDef) -> String {
    let fields: Vec<String> = d
        .fields
        .iter()
        .map(|f| {
            let ty = match &f.kind {
                Kind::Str { choices: Some(c), .. } => c.join("|"),
                k => k.word().to_string(),
            };
            format!("{}:{}{}", f.name, ty, if d.is_required(&f.name) { "*" } else { "" })
        })
        .collect();
    let confirm = if d.effect == Effect::Change { " (confirm)" } else { "" };
    format!("{}({}) - {}{}", d.id, fields.join(", "), d.description, confirm)
}

pub fn description(listed: &[&ActionDef]) -> String {
    let mut s = String::from(HEADER);
    for d in listed {
        s.push('\n');
        s.push_str(&line(d));
    }
    s
}

pub fn schema(listed: &[&ActionDef]) -> Value {
    json!({"type": "function", "function": {
        "name": "act",
        "description": description(listed),
        "parameters": {"type": "object", "properties": {"action": {"type": "string"}, "fields": {"type": "object"}},
                       "required": ["action"], "additionalProperties": false}}})
}
