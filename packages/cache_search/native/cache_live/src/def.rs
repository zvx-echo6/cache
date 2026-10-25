//! Source definitions: data, never code. One JSON file per source (format in DESIGN.md, "Live sources").

use crate::{Error, Result};
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;

pub const FORMAT: u32 = 1;

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SourceDef {
    pub format: u32,
    pub id: String,
    pub title: String,
    pub provider: String,
    /// One line: what the model and the Home card see of this source.
    pub description: String,
    #[serde(default)]
    pub attribution: Option<String>,
    pub request: RequestDef,
    #[serde(default)]
    pub api_key: Option<KeyDef>,
    /// Minutes before `cs_live_fetch` downloads again (a fetch inside this time returns the stored copy).
    pub refresh_minutes: u32,
    #[serde(default)]
    pub quota: Quota,
    pub validity: Validity,
    /// Paths that must exist in a response, or the response is rejected (`bad_response`) and the last good copy stays.
    #[serde(default)]
    pub require: Vec<String>,
    /// Path (from the response root) of the place's IANA time zone name (`America/Boise`). Best: it knows daylight saving.
    #[serde(default)]
    pub timezone_path: Option<String>,
    /// Path of the place's UTC offset in seconds, when the response has no zone name.
    #[serde(default)]
    pub utc_offset_path: Option<String>,
    pub items: Vec<ItemDef>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestDef {
    pub url: String,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct KeyDef {
    /// The name the app stores the key under (secure storage); the caller passes the value at fetch time.
    pub alias: String,
    #[serde(default = "yes")]
    pub required: bool,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Quota {
    pub per_minute: Option<u32>,
    pub per_day: Option<u32>,
    pub per_month: Option<u32>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct Validity {
    /// Valid this many hours after the fetch.
    pub fixed_hours: Option<f64>,
    /// Or: valid until the end time found at this path (a date or a date-time).
    pub end_path: Option<String>,
    /// With `end_path`: the end is the end of that day (local midnight after it).
    pub end_of_day: bool,
    /// With `end_path`: also report `not_covered_after` (the date of the end).
    pub not_covered_after: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ItemDef {
    /// Path to an array; one item per element. Without it, one item from the response root.
    #[serde(default)]
    pub each: Option<String>,
    /// Stable id of the item inside its source and place; it ends up in the item's address.
    pub key: Spec,
    pub label: Spec,
    #[serde(default)]
    pub time: Option<Spec>,
    /// When the item stops being true (an alert's end). Ended items are left out.
    #[serde(default)]
    pub ends: Option<Spec>,
    pub fields: Vec<Spec>,
    /// Order of the items of this group (first key first); without it, the response's order.
    #[serde(default)]
    pub sort: Vec<SortKey>,
    #[serde(default)]
    pub point: Option<PointDef>,
    /// Path to a GeoJSON geometry for the item's area.
    #[serde(default)]
    pub area: Option<String>,
}

/// One sort key. Missing values sort last.
#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SortKey {
    pub by: Spec,
    /// The values in order (case-insensitive); a value not in the list sorts after them.
    #[serde(default)]
    pub rank: Vec<String>,
    /// Sort by time (the value is read as a time; RFC 3339 unless `by` says otherwise).
    #[serde(default)]
    pub time: bool,
    #[serde(default)]
    pub desc: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PointDef {
    pub lat: Spec,
    pub lon: Spec,
}

/// How one value is found and written. Exactly one of `path`, `const`, `template`, `first_of` gives the value;
/// the rest are formatting steps applied in a fixed order (see `map.rs`).
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields, default)]
pub struct Spec {
    /// The label of a field (required for entries of `fields`, unused elsewhere).
    pub label: Option<String>,
    pub path: Option<String>,
    #[serde(rename = "const")]
    pub constant: Option<Value>,
    /// Text with `{name}` holes filled from `vars`; the value is missing when any variable is.
    pub template: Option<String>,
    pub vars: BTreeMap<String, Spec>,
    /// The first of these that has a value.
    pub first_of: Vec<Spec>,
    /// Distance and compass direction from the place to a GeoJSON area: "6.2 mi S", or "inside the area". Missing when
    /// the item has no area.
    pub distance: Option<DistanceSpec>,
    pub scale: Option<f64>,
    pub offset: Option<f64>,
    /// Decimals to round to (0 = whole numbers).
    pub round: Option<u32>,
    /// Degrees to a compass point (N, NE, E, ...).
    pub compass: bool,
    /// Fixed table from a code to text; `"*"` is the fallback. A code that is not in it, with no `"*"`, is missing.
    pub lookup: BTreeMap<String, String>,
    pub time: Option<TimeSpec>,
    /// "lower" or "upper".
    pub case: Option<String>,
    pub prefix: Option<String>,
    pub suffix: Option<String>,
    /// Cut longer text at a word end and add an ellipsis.
    pub max_chars: Option<usize>,
    /// The value is missing when it equals one of these (compared as lower-case text).
    pub omit_if: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DistanceSpec {
    /// Path to the GeoJSON geometry.
    pub geometry: String,
    /// "mi" or "km".
    pub unit: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TimeSpec {
    /// How the response writes the time: "local" (no offset, in the place's offset: `2026-10-25T14:00` or a date),
    /// "rfc3339" (with an offset) or "unix" (seconds).
    #[serde(rename = "in")]
    pub input: String,
    /// "datetime" (`2026-10-25T14:00-06:00`, default), "datetime_s" (with seconds), "date", or a strftime pattern.
    #[serde(default)]
    pub out: Option<String>,
    /// "place": write it in the place's offset even when the response gave another. Default: keep the response's.
    #[serde(default)]
    pub zone: Option<String>,
}

impl SourceDef {
    pub fn parse(text: &str) -> Result<SourceDef> {
        let d: SourceDef = serde_json::from_str(text).map_err(|e| Error::bad_json(format!("source definition: {e}")))?;
        d.validate()?;
        Ok(d)
    }

    fn validate(&self) -> Result<()> {
        let bad = |m: String| Err(Error::bad_json(format!("source {:?}: {m}", self.id)));
        if self.format != FORMAT {
            return bad(format!("format {} is not supported (this core reads format {FORMAT})", self.format));
        }
        if self.id.is_empty() || !self.id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-') {
            return bad("id must be lower-case letters, digits, _ and -".into());
        }
        if self.description.trim().is_empty() || self.title.trim().is_empty() || self.provider.trim().is_empty() {
            return bad("title, provider and description are required".into());
        }
        if self.refresh_minutes == 0 {
            return bad("refresh_minutes must be at least 1".into());
        }
        match (&self.validity.fixed_hours, &self.validity.end_path) {
            (Some(h), None) if *h > 0.0 => {}
            (None, Some(_)) => {}
            _ => return bad("validity needs exactly one of fixed_hours (> 0) or end_path".into()),
        }
        if self.validity.fixed_hours.is_some() && (self.validity.end_of_day || self.validity.not_covered_after) {
            return bad("end_of_day and not_covered_after go with end_path".into());
        }
        if self.items.is_empty() {
            return bad("items must not be empty".into());
        }
        let url = &self.request.url;
        if !url.starts_with("https://") && !url.starts_with("http://") {
            return bad("request.url must start with https://".into());
        }
        for it in &self.items {
            for f in &it.fields {
                if f.label.as_deref().map(str::trim).unwrap_or("").is_empty() {
                    return bad("every entry of fields needs a label".into());
                }
            }
            for s in [Some(&it.key), Some(&it.label), it.time.as_ref(), it.ends.as_ref()].into_iter().flatten().chain(it.fields.iter()).chain(it.sort.iter().map(|k| &k.by)) {
                s.validate(&self.id)?;
            }
        }
        Ok(())
    }
}

impl Spec {
    fn validate(&self, id: &str) -> Result<()> {
        let n = [self.path.is_some(), self.constant.is_some(), self.template.is_some(), !self.first_of.is_empty(), self.distance.is_some()]
            .iter()
            .filter(|b| **b)
            .count();
        if n != 1 {
            return Err(Error::bad_json(format!(
                "source {id:?}: a value ({:?}) needs exactly one of path, const, template, first_of, distance",
                self.label
            )));
        }
        if let Some(t) = &self.time {
            if !["local", "rfc3339", "unix"].contains(&t.input.as_str()) {
                return Err(Error::bad_json(format!("source {id:?}: time.in must be local, rfc3339 or unix")));
            }
        }
        if let Some(d) = &self.distance {
            if d.unit != "mi" && d.unit != "km" {
                return Err(Error::bad_json(format!("source {id:?}: distance.unit must be mi or km")));
            }
        }
        if let Some(c) = &self.case {
            if c != "lower" && c != "upper" {
                return Err(Error::bad_json(format!("source {id:?}: case must be lower or upper")));
            }
        }
        for s in self.vars.values().chain(self.first_of.iter()) {
            s.validate(id)?;
        }
        Ok(())
    }
}
