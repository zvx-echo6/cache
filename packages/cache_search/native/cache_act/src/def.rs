//! Action definitions (docs/ACTIONS.md, "Action definition"): parsing one JSON object into an `ActionDef` and refusing it, with a
//! reason, when it breaks the rules. Each definition stands alone: a bad one is rejected and the rest still load.

use serde_json::{Map, Value};
use std::collections::HashSet;

pub const MAX_ID_CHARS: usize = 48;
pub const MAX_TITLE_CHARS: usize = 40;
pub const MAX_DESCRIPTION_CHARS: usize = 120;
pub const MAX_FIELD_DESCRIPTION_CHARS: usize = 80;
pub const MAX_FIELDS: usize = 10;
/// The `maxLength` of a string field that gives none.
pub const DEFAULT_MAX_LENGTH: usize = 200;

#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Effect {
    Read,
    Open,
    Change,
}

#[derive(Clone, Debug, PartialEq)]
pub enum Kind {
    Str { max_length: usize, choices: Option<Vec<String>> },
    Number { min: Option<f64>, max: Option<f64> },
    Integer { min: Option<i64>, max: Option<i64> },
    Boolean,
    Date,
    Time,
    Duration,
    Place,
}

impl Kind {
    /// The word the description shows for the type (an enum shows its values instead).
    pub fn word(&self) -> &'static str {
        match self {
            Kind::Str { .. } => "string",
            Kind::Number { .. } => "number",
            Kind::Integer { .. } => "integer",
            Kind::Boolean => "boolean",
            Kind::Date => "date",
            Kind::Time => "time",
            Kind::Duration => "duration",
            Kind::Place => "place",
        }
    }
}

#[derive(Clone, Debug, PartialEq)]
pub struct FieldDef {
    pub name: String,
    pub kind: Kind,
    pub description: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ActionDef {
    pub id: String,
    pub module: String,
    pub title: String,
    pub description: String,
    pub effect: Effect,
    /// In the order the definition gave them.
    pub fields: Vec<FieldDef>,
    pub required: Vec<String>,
}

impl ActionDef {
    pub fn field(&self, name: &str) -> Option<&FieldDef> {
        self.fields.iter().find(|f| f.name == name)
    }
    pub fn is_required(&self, name: &str) -> bool {
        self.required.iter().any(|r| r == name)
    }
}

/// Why a definition was refused. `reason` is a stable code; `detail` is a short text for a person.
#[derive(Clone, Debug, PartialEq)]
pub struct Rejection {
    pub index: usize,
    pub id: Option<String>,
    pub field: Option<String>,
    pub reason: &'static str,
    pub detail: String,
}

impl Rejection {
    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("index".into(), Value::from(self.index));
        if let Some(id) = &self.id {
            m.insert("id".into(), Value::String(id.clone()));
        }
        if let Some(f) = &self.field {
            m.insert("field".into(), Value::String(f.clone()));
        }
        m.insert("reason".into(), Value::String(self.reason.to_string()));
        m.insert("detail".into(), Value::String(self.detail.clone()));
        Value::Object(m)
    }
}

struct Bad {
    field: Option<String>,
    reason: &'static str,
    detail: String,
}

fn bad(reason: &'static str, detail: impl Into<String>) -> Bad {
    Bad { field: None, reason, detail: detail.into() }
}

fn bad_field(field: &str, reason: &'static str, detail: impl Into<String>) -> Bad {
    Bad { field: Some(field.to_string()), reason, detail: detail.into() }
}

fn chars(s: &str) -> usize {
    s.chars().count()
}

fn has_control(s: &str) -> bool {
    s.chars().any(char::is_control)
}

fn id_chars_ok(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '.')
}

fn name_chars_ok(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_')
}

fn limit_f64(spec: &Map<String, Value>, key: &str, field: &str) -> Result<Option<f64>, Bad> {
    match spec.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(v) => match v.as_f64() {
            Some(x) if v.is_number() && x.is_finite() => Ok(Some(x)),
            _ => Err(bad_field(field, "bad_limit", format!("{field}: {key} must be a number"))),
        },
    }
}

fn limit_i64(spec: &Map<String, Value>, key: &str, field: &str) -> Result<Option<i64>, Bad> {
    match limit_f64(spec, key, field)? {
        None => Ok(None),
        Some(x) if x.fract() == 0.0 && x.abs() < 9.0e15 => Ok(Some(x as i64)),
        Some(_) => Err(bad_field(field, "bad_limit", format!("{field}: {key} must be a whole number for an integer"))),
    }
}

/// A key that belongs to some type but not to this one.
fn only_keys(spec: &Map<String, Value>, field: &str, type_name: &str, allowed: &[&str]) -> Result<(), Bad> {
    for key in ["maxLength", "enum", "minimum", "maximum"] {
        if spec.contains_key(key) && !allowed.contains(&key) {
            return Err(bad_field(field, "bad_field_key", format!("{field}: {key} does not apply to type {type_name}")));
        }
    }
    Ok(())
}

fn parse_field(name: &str, spec: &Value) -> Result<FieldDef, Bad> {
    if !name_chars_ok(name) {
        return Err(bad_field(name, "bad_field_name", format!("{name:?}: field names are lowercase a-z 0-9 _")));
    }
    let Some(spec) = spec.as_object() else {
        return Err(bad_field(name, "bad_field_type", format!("{name}: must be an object with a type")));
    };
    let type_name = spec.get("type").and_then(Value::as_str).unwrap_or("");
    let kind = match type_name {
        "string" => {
            only_keys(spec, name, type_name, &["maxLength", "enum"])?;
            let max_length = match spec.get("maxLength") {
                None | Some(Value::Null) => DEFAULT_MAX_LENGTH,
                Some(v) => match v.as_u64() {
                    Some(n) if n >= 1 && n <= 1_000_000 => n as usize,
                    _ => return Err(bad_field(name, "bad_limit", format!("{name}: maxLength must be a whole number from 1"))),
                },
            };
            let choices = match spec.get("enum") {
                None | Some(Value::Null) => None,
                Some(Value::Array(a)) => {
                    let mut seen = HashSet::new();
                    let mut out = Vec::new();
                    for v in a {
                        let Some(s) = v.as_str() else {
                            return Err(bad_field(name, "bad_enum", format!("{name}: enum values must be strings")));
                        };
                        if s.is_empty() || s.contains('|') || has_control(s) {
                            return Err(bad_field(name, "bad_enum", format!("{name}: an enum value cannot be empty, hold | or a line break")));
                        }
                        if chars(s) > max_length {
                            return Err(bad_field(name, "bad_enum", format!("{name}: enum value {s:?} is longer than maxLength")));
                        }
                        if !seen.insert(s.to_string()) {
                            return Err(bad_field(name, "bad_enum", format!("{name}: enum value {s:?} is listed twice")));
                        }
                        out.push(s.to_string());
                    }
                    if out.is_empty() {
                        return Err(bad_field(name, "bad_enum", format!("{name}: enum is empty")));
                    }
                    Some(out)
                }
                Some(_) => return Err(bad_field(name, "bad_enum", format!("{name}: enum must be a list of strings"))),
            };
            Kind::Str { max_length, choices }
        }
        "number" => {
            only_keys(spec, name, type_name, &["minimum", "maximum"])?;
            let (min, max) = (limit_f64(spec, "minimum", name)?, limit_f64(spec, "maximum", name)?);
            if matches!((min, max), (Some(a), Some(b)) if a > b) {
                return Err(bad_field(name, "bad_limit", format!("{name}: minimum is above maximum")));
            }
            Kind::Number { min, max }
        }
        "integer" => {
            only_keys(spec, name, type_name, &["minimum", "maximum"])?;
            let (min, max) = (limit_i64(spec, "minimum", name)?, limit_i64(spec, "maximum", name)?);
            if matches!((min, max), (Some(a), Some(b)) if a > b) {
                return Err(bad_field(name, "bad_limit", format!("{name}: minimum is above maximum")));
            }
            Kind::Integer { min, max }
        }
        "boolean" | "date" | "time" | "duration" | "place" => {
            only_keys(spec, name, type_name, &[])?;
            match type_name {
                "boolean" => Kind::Boolean,
                "date" => Kind::Date,
                "time" => Kind::Time,
                "duration" => Kind::Duration,
                _ => Kind::Place,
            }
        }
        other => return Err(bad_field(name, "bad_field_type", format!("{name}: unknown type {other:?}"))),
    };
    let description = match spec.get("description") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if chars(s) <= MAX_FIELD_DESCRIPTION_CHARS => Some(s.clone()),
        Some(_) => {
            return Err(bad_field(name, "bad_field_description", format!("{name}: description must be text of at most {MAX_FIELD_DESCRIPTION_CHARS} characters")))
        }
    };
    Ok(FieldDef { name: name.to_string(), kind, description })
}

fn parse_one(v: &Value) -> Result<ActionDef, Bad> {
    let Some(o) = v.as_object() else {
        return Err(bad("not_object", "a definition must be a JSON object"));
    };
    let id = o.get("id").and_then(Value::as_str).unwrap_or("");
    if !id_chars_ok(id) || chars(id) > MAX_ID_CHARS {
        return Err(bad("bad_id", format!("id must be <module>.<verb>, lowercase a-z 0-9 _ . and at most {MAX_ID_CHARS} characters")));
    }
    let Some((prefix, verb)) = id.split_once('.') else {
        return Err(bad("bad_id", "id must be <module>.<verb>"));
    };
    if prefix.is_empty() || verb.is_empty() {
        return Err(bad("bad_id", "id must be <module>.<verb>"));
    }
    let module = o.get("module").and_then(Value::as_str).unwrap_or("");
    if module != prefix {
        return Err(bad("module_mismatch", format!("module must be {prefix:?}, the prefix of the id")));
    }
    let title = o.get("title").and_then(Value::as_str).unwrap_or("");
    if title.trim().is_empty() || chars(title) > MAX_TITLE_CHARS || has_control(title) {
        return Err(bad("bad_title", format!("title must be one line of 1 to {MAX_TITLE_CHARS} characters")));
    }
    let description = o.get("description").and_then(Value::as_str).unwrap_or("");
    if description.trim().is_empty() || chars(description) > MAX_DESCRIPTION_CHARS || has_control(description) {
        return Err(bad("bad_description", format!("description must be one line of 1 to {MAX_DESCRIPTION_CHARS} characters")));
    }
    let effect = match o.get("effect").and_then(Value::as_str) {
        Some("read") => Effect::Read,
        Some("open") => Effect::Open,
        Some("change") => Effect::Change,
        _ => return Err(bad("bad_effect", "effect must be read, open or change")),
    };
    let empty = Map::new();
    let fields_obj = match o.get("fields") {
        None | Some(Value::Null) => &empty,
        Some(Value::Object(m)) => m,
        Some(_) => return Err(bad("bad_fields", "fields must be an object")),
    };
    if fields_obj.len() > MAX_FIELDS {
        return Err(bad("too_many_fields", format!("at most {MAX_FIELDS} fields, this has {}", fields_obj.len())));
    }
    let mut fields = Vec::new();
    for (name, spec) in fields_obj {
        fields.push(parse_field(name, spec)?);
    }
    let required = match o.get("required") {
        None | Some(Value::Null) => Vec::new(),
        Some(Value::Array(a)) => {
            let mut out: Vec<String> = Vec::new();
            for r in a {
                let Some(r) = r.as_str() else {
                    return Err(bad("bad_required", "required must be a list of field names"));
                };
                if !fields.iter().any(|f| f.name == r) {
                    return Err(bad_field(r, "bad_required", format!("{r}: required but not a field")));
                }
                if out.iter().any(|x| x == r) {
                    return Err(bad_field(r, "bad_required", format!("{r}: required twice")));
                }
                out.push(r.to_string());
            }
            out
        }
        Some(_) => return Err(bad("bad_required", "required must be a list of field names")),
    };
    Ok(ActionDef { id: id.to_string(), module: module.to_string(), title: title.to_string(), description: description.to_string(), effect, fields, required })
}

/// Parse a list of definitions. Each element is judged alone; the accepted ones come back in the order given, the
/// rejected ones with their position. A repeated id is rejected (`duplicate_id`): the first one stays.
pub fn parse_all(defs: &[Value]) -> (Vec<ActionDef>, Vec<Rejection>) {
    let mut ok: Vec<ActionDef> = Vec::new();
    let mut rejected = Vec::new();
    for (index, v) in defs.iter().enumerate() {
        let given_id = v.get("id").and_then(Value::as_str).map(str::to_string);
        match parse_one(v) {
            Ok(d) => {
                if ok.iter().any(|x| x.id == d.id) {
                    rejected.push(Rejection { index, id: Some(d.id.clone()), field: None, reason: "duplicate_id", detail: format!("{} is already installed", d.id) });
                } else {
                    ok.push(d);
                }
            }
            Err(b) => rejected.push(Rejection { index, id: given_id, field: b.field, reason: b.reason, detail: b.detail }),
        }
    }
    (ok, rejected)
}
