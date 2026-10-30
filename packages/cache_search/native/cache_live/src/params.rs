//! User parameters: the values a person sets when adding a source (a gauge id, a radius, a state). A definition lists
//! them in `params`; a fetch or get request gives `"params": {"name": value}`.
//!
//! The stored row of a source and place is one per set of values: with every parameter at its default the row is the
//! plain place key; with others it is `<place key>~<8 hex digits of the values>`, so two gauges of the same source
//! for the same place do not overwrite each other. The `~` cannot occur in a place key.

use crate::def::{ParamDef, SourceDef};
use crate::{Error, Place, Result};
use serde_json::{Map, Value};
use std::collections::BTreeMap;

/// One given value, checked against its parameter and turned into the canonical JSON type (a number, a bool or a string).
pub fn normalize(p: &ParamDef, v: &Value) -> std::result::Result<Value, String> {
    let kind = p.kind.as_deref().unwrap_or("text");
    let out = match kind {
        "number" | "integer" => {
            let n = match v {
                Value::Number(n) => n.as_f64(),
                Value::String(s) => s.trim().parse::<f64>().ok(),
                _ => None,
            }
            .filter(|n| n.is_finite())
            .ok_or_else(|| format!("{:?} is not a number", v))?;
            if kind == "integer" && n.fract() != 0.0 {
                return Err(format!("{n} is not a whole number"));
            }
            if p.min.map(|m| n < m).unwrap_or(false) || p.max.map(|m| n > m).unwrap_or(false) {
                return Err(format!("{n} is outside {} to {}", p.min.map(|m| m.to_string()).unwrap_or("-".into()), p.max.map(|m| m.to_string()).unwrap_or("-".into())));
            }
            if kind == "integer" || (n.fract() == 0.0 && n.abs() < 1e15) {
                Value::from(n as i64)
            } else {
                serde_json::Number::from_f64(n).map(Value::Number).ok_or("not a number")?
            }
        }
        "bool" => match v {
            Value::Bool(b) => Value::Bool(*b),
            Value::String(s) if s.eq_ignore_ascii_case("true") => Value::Bool(true),
            Value::String(s) if s.eq_ignore_ascii_case("false") => Value::Bool(false),
            _ => return Err(format!("{v} is not true or false")),
        },
        "choice" => {
            let s = match v {
                Value::String(s) => s.clone(),
                Value::Number(n) => n.to_string(),
                _ => return Err(format!("{v} is not one of the choices")),
            };
            if !p.choices.contains(&s) {
                return Err(format!("{s:?} is not one of {}", p.choices.join(", ")));
            }
            Value::String(s)
        }
        _ => match v {
            Value::String(s) => Value::String(s.clone()),
            Value::Number(n) => Value::String(n.to_string()),
            Value::Bool(b) => Value::String(b.to_string()),
            _ => return Err("not text".into()),
        },
    };
    Ok(out)
}

/// Every parameter of the definition with a value: the given one, else the default. A required one with neither is an
/// error; a name the definition does not have is an error.
pub fn resolve(def: &SourceDef, given: Option<&Map<String, Value>>) -> Result<BTreeMap<String, Value>> {
    let err = |m: String| Error::bad_json(format!("source {:?}: params: {m}", def.id));
    if let Some(g) = given {
        if let Some(k) = g.keys().find(|k| !def.params.iter().any(|p| &p.name == *k)) {
            return Err(err(format!("{k:?} is not a parameter of this source")));
        }
    }
    let mut out = BTreeMap::new();
    for p in &def.params {
        let v = given.and_then(|g| g.get(&p.name)).filter(|v| !v.is_null());
        match (v, &p.default) {
            (Some(v), _) => {
                out.insert(p.name.clone(), normalize(p, v).map_err(|m| err(format!("{}: {m}", p.name)))?);
            }
            (None, Some(d)) => {
                out.insert(p.name.clone(), normalize(p, d).map_err(|m| err(format!("{}: default: {m}", p.name)))?);
            }
            (None, None) if p.required => return Err(err(format!("{} is required", p.name))),
            (None, None) => {}
        }
    }
    Ok(out)
}

/// True when every given value is the parameter's default (so the row is the plain place key).
fn all_default(def: &SourceDef, values: &BTreeMap<String, Value>) -> bool {
    def.params.iter().all(|p| match (values.get(&p.name), p.default.as_ref().and_then(|d| normalize(p, d).ok())) {
        (None, None) => true,
        (Some(a), Some(b)) => *a == b,
        _ => false,
    })
}

/// The place under which the row of these parameter values is stored.
pub fn row_place(def: &SourceDef, place: &Place, values: &BTreeMap<String, Value>) -> Place {
    if all_default(def, values) {
        return place.clone();
    }
    let canon = serde_json::to_string(values).unwrap_or_default();
    Place { key: format!("{}~{}", place.key, &crate::fnv(canon.as_bytes())[..8]), ..place.clone() }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn def() -> SourceDef {
        SourceDef::parse(
            &json!({"format": 2, "id": "g", "title": "t", "provider": "p", "description": "d", "request": {"url": "https://x/{param:site}"},
                "refresh_minutes": 1, "validity": {"fixed_hours": 1},
                "params": [{"name": "site", "type": "text", "required": true}, {"name": "days", "type": "integer", "default": 3, "min": 1, "max": 7},
                           {"name": "kind", "type": "choice", "choices": ["a", "b"], "default": "a"}],
                "items": [{"key": {"const": "k"}, "label": {"const": "l"}, "fields": []}]})
            .to_string(),
        )
        .unwrap()
    }

    #[test]
    fn resolving_and_row_keys() {
        let d = def();
        assert!(resolve(&d, None).unwrap_err().message.contains("site is required"));
        let g = json!({"site": "13206000"});
        let r = resolve(&d, g.as_object()).unwrap();
        assert_eq!(r["days"], json!(3));
        assert_eq!(r["kind"], json!("a"));
        let place = Place { key: "home".into(), name: "Home".into(), lat: 1.0, lon: 2.0 };
        let k1 = row_place(&d, &place, &r).key;
        assert!(k1.starts_with("home~"), "site has no default, so it is never 'all default'");
        let r2 = resolve(&d, json!({"site": "13206000", "days": "5"}).as_object()).unwrap();
        assert_eq!(r2["days"], json!(5));
        assert_ne!(row_place(&d, &place, &r2).key, k1);
        assert_eq!(row_place(&d, &place, &r).key, k1);
        assert!(resolve(&d, json!({"site": "x", "days": 9}).as_object()).is_err());
        assert!(resolve(&d, json!({"site": "x", "days": 2.5}).as_object()).is_err());
        assert!(resolve(&d, json!({"site": "x", "kind": "c"}).as_object()).is_err());
        assert!(resolve(&d, json!({"site": "x", "nope": 1}).as_object()).unwrap_err().message.contains("not a parameter"));
    }
}
