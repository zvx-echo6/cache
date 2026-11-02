//! A notebook's definition: the template object of `cache-log-templates` (specs/notebook-starters.json) plus, inside Cache only,
//! a stable `fid` per field (`f1`, `f2`, ...) given when the field is made. Label renames keep the `fid`, so stored values
//! survive them. Once a notebook has entries a field's type cannot change; a removed field that holds values is kept, hidden.

use crate::{Error, Result};
use serde_json::{json, Map, Value};

/// The most visible fields a notebook has (When and Notes are not fields).
pub const MAX_FIELDS: usize = 12;
pub const FIELD_TYPES: [&str; 6] = ["text", "number", "yes_no", "choice", "place", "photo"];
const MAX_NAME: usize = 80;
const MAX_LABEL: usize = 60;
const MAX_UNIT: usize = 20;
const MAX_CHOICE: usize = 100;
const MAX_CHOICES: usize = 30;

#[derive(Debug, Clone, PartialEq)]
pub struct Field {
    pub fid: String,
    pub label: String,
    pub kind: String,
    pub unit: Option<String>,
    pub choices: Option<Vec<String>>,
    pub hidden: bool,
}

impl Field {
    fn to_json(&self) -> Value {
        let mut m = Map::new();
        m.insert("fid".into(), json!(self.fid));
        m.insert("label".into(), json!(self.label));
        m.insert("type".into(), json!(self.kind));
        if let Some(u) = &self.unit {
            m.insert("unit".into(), json!(u));
        }
        if let Some(c) = &self.choices {
            m.insert("choices".into(), json!(c));
        }
        if self.hidden {
            m.insert("hidden".into(), json!(true));
        }
        Value::Object(m)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct NotebookDef {
    /// The template's `id`, `version`, `author` and `group`, when the notebook came from one (the hook for template packs).
    pub meta: Vec<(String, Value)>,
    pub name: String,
    pub due_every: Option<String>,
    /// How the app lists and fills the notebook, from its template: `{"sort": "date"|"recent"|"distance", "quick_add": bool}`
    /// (both optional). Data, so a new kind of notebook is a new template and no new code.
    pub shape: Map<String, Value>,
    pub fields: Vec<Field>,
}

/// The `shape` of a definition: `sort` (date: newest first; recent: last changed first; distance: nearest first) and
/// `quick_add` (entries are made from the fields in a short sheet, with "Last done" and "Due again").
fn parse_shape(v: Option<&Value>) -> Result<Map<String, Value>> {
    let Some(v) = v.filter(|v| !v.is_null()) else { return Ok(Map::new()) };
    let o = v.as_object().ok_or_else(|| Error::bad("def.shape must be an object"))?;
    for (k, x) in o {
        let ok = match k.as_str() {
            "sort" => matches!(x.as_str(), Some("date" | "recent" | "distance")),
            "quick_add" => x.is_boolean(),
            _ => return Err(Error::bad(format!("def.shape.{k}: not allowed"))),
        };
        if !ok {
            return Err(Error::bad(format!("def.shape.{k}: {x} is not allowed")));
        }
    }
    Ok(o.clone())
}

fn clean(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// `null`, `day`, `week`, `month`, `year`, or `<n> days|weeks|months|years` with n from 2 to 999 (the starters use
/// `month`, `3 months` and `6 months`). A fixed machine format, read by the app for the "Due again" cue.
pub fn validate_due_every(s: &str) -> bool {
    if matches!(s, "day" | "week" | "month" | "year") {
        return true;
    }
    let Some((n, unit)) = s.split_once(' ') else { return false };
    let ok_n = !n.is_empty() && n.len() <= 3 && n.bytes().all(|b| b.is_ascii_digit()) && !n.starts_with('0') && n != "1";
    ok_n && matches!(unit, "days" | "weeks" | "months" | "years")
}

impl NotebookDef {
    /// The definition as given by the app (or a template): fields may lack `fid`, which [`NotebookDef::merge`] assigns.
    pub fn parse(v: &Value) -> Result<NotebookDef> {
        let o = v.as_object().ok_or_else(|| Error::bad("def must be an object"))?;
        let mut meta = Vec::new();
        for k in ["id", "version", "author", "group"] {
            match (k, o.get(k)) {
                (_, None | Some(Value::Null)) => {}
                ("version", Some(n)) if n.as_u64().is_some() => meta.push((k.to_string(), n.clone())),
                (_, Some(Value::String(s))) if k != "version" && !s.trim().is_empty() && s.chars().count() <= 100 => {
                    meta.push((k.to_string(), json!(s.trim())))
                }
                _ => return Err(Error::bad(format!("def.{k} has the wrong type"))),
            }
        }
        let name = clean(o.get("name").and_then(Value::as_str).unwrap_or(""));
        if name.is_empty() || name.chars().count() > MAX_NAME {
            return Err(Error::bad(format!("a notebook's name is 1 to {MAX_NAME} characters")));
        }
        let due_every = match o.get("due_every") {
            None | Some(Value::Null) => None,
            Some(Value::String(s)) if validate_due_every(s) => Some(s.clone()),
            Some(d) => return Err(Error::bad(format!("due_every {d} is not one of day, week, month, year or \"<n> days|weeks|months|years\""))),
        };
        let shape = parse_shape(o.get("shape"))?;
        let mut fields = Vec::new();
        for f in o.get("fields").and_then(Value::as_array).ok_or_else(|| Error::bad("def.fields must be a list"))? {
            fields.push(parse_field(f)?);
        }
        Ok(NotebookDef { meta, name, due_every, shape, fields })
    }

    /// A definition as the store keeps it (every field has its `fid`).
    pub fn from_stored(text: &str) -> Result<NotebookDef> {
        let d = NotebookDef::parse(&serde_json::from_str(text)?)?;
        if d.fields.iter().any(|f| f.fid.is_empty()) {
            return Err(Error { code: "damaged", message: "a stored field has no fid".into() });
        }
        Ok(d)
    }

    pub fn to_json(&self) -> Value {
        let mut m = Map::new();
        for (k, v) in &self.meta {
            m.insert(k.clone(), v.clone());
        }
        m.insert("name".into(), json!(self.name));
        m.insert("due_every".into(), json!(self.due_every));
        if !self.shape.is_empty() {
            m.insert("shape".into(), Value::Object(self.shape.clone()));
        }
        m.insert("fields".into(), Value::Array(self.fields.iter().map(Field::to_json).collect()));
        Value::Object(m)
    }

    pub fn field(&self, fid: &str) -> Option<&Field> {
        self.fields.iter().find(|f| f.fid == fid)
    }

    /// The definition to store when `self` (as the app sent it) replaces `old`. New fields get the next `fid`; a field the app
    /// left out is dropped, or kept hidden when `has_values(fid)`; a field's type is fixed once `has_entries`.
    pub fn merge(mut self, old: Option<&NotebookDef>, has_entries: bool, mut has_values: impl FnMut(&str) -> bool) -> Result<NotebookDef> {
        let num = |fid: &str| fid.strip_prefix('f').and_then(|n| n.parse::<u32>().ok()).unwrap_or(0);
        let mut next = old.map(|o| o.fields.iter().map(|f| num(&f.fid)).max().unwrap_or(0)).unwrap_or(0);
        for f in &self.fields {
            if !f.fid.is_empty() {
                let Some(prev) = old.and_then(|o| o.field(&f.fid)) else {
                    return Err(Error::bad(format!("the notebook has no field {:?}", f.fid)));
                };
                if has_entries && prev.kind != f.kind {
                    return Err(Error::bad(format!("{}: a field's type can't change once the notebook has entries", f.label)));
                }
            }
        }
        let mut seen = std::collections::HashSet::new();
        for f in &mut self.fields {
            if f.fid.is_empty() {
                next += 1;
                f.fid = format!("f{next}");
            }
            if !seen.insert(f.fid.clone()) {
                return Err(Error::bad(format!("field {:?} is listed twice", f.fid)));
            }
        }
        if let Some(o) = old {
            for f in &o.fields {
                if !seen.contains(&f.fid) && has_values(&f.fid) {
                    self.fields.push(Field { hidden: true, ..f.clone() });
                }
            }
        }
        let visible: Vec<&Field> = self.fields.iter().filter(|f| !f.hidden).collect();
        if visible.len() > MAX_FIELDS {
            return Err(Error::bad(format!("a notebook has at most {MAX_FIELDS} fields")));
        }
        let mut labels = std::collections::HashSet::new();
        for f in &visible {
            if !labels.insert(f.label.to_lowercase()) {
                return Err(Error::bad(format!("two fields are named {:?}", f.label)));
            }
        }
        Ok(self)
    }
}

fn parse_field(v: &Value) -> Result<Field> {
    let o = v.as_object().ok_or_else(|| Error::bad("a field must be an object"))?;
    let label = clean(o.get("label").and_then(Value::as_str).unwrap_or(""));
    if label.is_empty() || label.chars().count() > MAX_LABEL {
        return Err(Error::bad(format!("a field's label is 1 to {MAX_LABEL} characters")));
    }
    let kind = o.get("type").and_then(Value::as_str).unwrap_or("");
    if !FIELD_TYPES.contains(&kind) {
        return Err(Error::bad(format!("{label}: type must be one of {}", FIELD_TYPES.join(", "))));
    }
    let fid = match o.get("fid") {
        None | Some(Value::Null) => String::new(),
        Some(Value::String(s)) if s.len() <= 12 && s.starts_with('f') && s[1..].parse::<u32>().is_ok() => s.clone(),
        Some(_) => return Err(Error::bad(format!("{label}: fid must look like f1"))),
    };
    let unit = match o.get("unit") {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) if kind == "number" => {
            let u = clean(s);
            if u.chars().count() > MAX_UNIT {
                return Err(Error::bad(format!("{label}: a unit is at most {MAX_UNIT} characters")));
            }
            (!u.is_empty()).then_some(u)
        }
        Some(_) => return Err(Error::bad(format!("{label}: only a number field has a unit"))),
    };
    let choices = match (kind == "choice", o.get("choices")) {
        (false, None | Some(Value::Null)) => None,
        (false, Some(_)) => return Err(Error::bad(format!("{label}: only a choice field has choices"))),
        (true, Some(Value::Array(a))) => {
            let mut out: Vec<String> = Vec::new();
            for c in a {
                let c = clean(c.as_str().ok_or_else(|| Error::bad(format!("{label}: choices are text")))?);
                if c.is_empty() || c.chars().count() > MAX_CHOICE {
                    return Err(Error::bad(format!("{label}: a choice is 1 to {MAX_CHOICE} characters")));
                }
                if out.contains(&c) {
                    return Err(Error::bad(format!("{label}: the choice {c:?} is listed twice")));
                }
                out.push(c);
            }
            if out.is_empty() || out.len() > MAX_CHOICES {
                return Err(Error::bad(format!("{label}: a choice field has 1 to {MAX_CHOICES} choices")));
            }
            Some(out)
        }
        (true, _) => return Err(Error::bad(format!("{label}: a choice field needs its choices"))),
    };
    let hidden = o.get("hidden").and_then(Value::as_bool).unwrap_or(false);
    Ok(Field { fid, label, kind: kind.to_string(), unit, choices, hidden })
}
