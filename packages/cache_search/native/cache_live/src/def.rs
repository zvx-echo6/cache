//! Source definitions: data, never code. One JSON file per source (format reference in DESIGN.md, "Live sources").
//!
//! Format 2 is a superset of format 1: every format 1 file reads unchanged. The JSON Schema of the format is generated
//! from these types (feature `schema`) and committed as `packages/cache_search/schema/live-source.schema.json`.

use crate::{Error, Result};
use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;

/// The format this core writes about and prefers. Definitions of `MIN_FORMAT..=FORMAT` are read.
pub const FORMAT: u32 = 2;
pub const MIN_FORMAT: u32 = 1;

/// Hard limits the definition's own settings cannot exceed.
pub const DEFAULT_TIMEOUT_S: u32 = 30;
pub const MAX_TIMEOUT_S: u32 = 120;
pub const DEFAULT_MAX_BYTES: u64 = 8 * 1024 * 1024;
pub const MAX_MAX_BYTES: u64 = 32 * 1024 * 1024;
pub const MAX_PAGES: u32 = 50;
pub const MAX_FAN_OUT: u32 = 50;
pub const MAX_STEPS: usize = 6;

#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct SourceDef {
    /// 1 or 2. Format 2 adds everything described in DESIGN.md that format 1 lacks.
    pub format: u32,
    /// Lower-case letters, digits, `_` and `-`.
    pub id: String,
    pub title: String,
    pub provider: String,
    /// One line: what the model and the Home card see of this source.
    pub description: String,
    #[serde(default)]
    pub attribution: Option<String>,
    /// What the `live_data` tool calls the one entry it shows when a valid result has nothing to report ("No active emergency
    /// alerts"). Without it the entry is labelled with `title`.
    #[serde(default)]
    pub none_label: Option<String>,
    pub request: RequestDef,
    /// A key the user supplies. Use `{api_key}` in the URL (query or path), a header value or the body.
    #[serde(default)]
    pub api_key: Option<KeyDef>,
    /// HTTP Basic: the username and password come from secure storage under these aliases.
    #[serde(default)]
    pub basic_auth: Option<BasicAuthDef>,
    /// Values the user can set when adding the source; used as `{param:name}` in the request and `{"param": "name"}` in
    /// a mapping.
    #[serde(default)]
    pub params: Vec<ParamDef>,
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

/// One HTTP request, or (inside `steps`) one step of several.
#[derive(Debug, Clone, Default, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields, default)]
pub struct RequestDef {
    /// `https://...` with `{placeholders}` (see DESIGN.md). Required, except on a request that has `steps`.
    pub url: Option<String>,
    /// "GET" (default) or "POST".
    pub method: Option<String>,
    /// Extra headers; values take placeholders. Top-level headers are sent with every step.
    pub headers: BTreeMap<String, String>,
    /// POST body: a JSON value whose strings take placeholders (`body_type` "json"), an object of strings for a form
    /// ("form"), or a string ("text").
    pub body: Option<Value>,
    /// "json" (default), "form" or "text".
    pub body_type: Option<String>,
    /// Seconds before the request is given up (default 30, at most 120).
    pub timeout_seconds: Option<u32>,
    /// Largest response body, in bytes (default 8 MiB, at most 32 MiB), counted after gzip is undone.
    pub max_bytes: Option<u64>,
    /// "json" (default; GeoJSON is JSON), "xml", "csv", "tsv", "tle" or "auto" (decided from the first character).
    pub response: Option<String>,
    /// Reading of "csv" and "tsv" responses.
    pub table: Option<TableDef>,
    /// Reading of "xml" responses.
    pub xml: Option<XmlDef>,
    /// Fetch more pages of a long result.
    pub paging: Option<PagingDef>,
    /// Several requests, run in order; a later one may use values from an earlier response. The mapping then reads a
    /// root object with one member per step id.
    pub steps: Vec<RequestDef>,
    /// Steps only: the name later steps and the mapping use for this step's response.
    pub id: Option<String>,
    /// Steps only: repeat this step for each element of a list found in an earlier response.
    pub for_each: Option<ForEachDef>,
}

#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct ForEachDef {
    /// The id of an earlier step (not itself a fan-out).
    pub from: String,
    /// Path of the list inside that step's response.
    pub path: String,
    /// The name the current element has in this step's placeholders (`{as:path}`; `{as}` for a plain value).
    #[serde(rename = "as")]
    pub name: String,
    /// At most this many elements are requested (default 10, at most 50).
    #[serde(default)]
    pub limit: Option<u32>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields, default)]
pub struct TableDef {
    /// One character; default "," for csv and a tab for tsv.
    pub delimiter: Option<String>,
    /// The first row names the columns (default true). Without it the columns are `c0`, `c1`, ...
    pub header: Option<bool>,
    /// Lines starting with this character are skipped (for example "#").
    pub comment: Option<String>,
    /// Rows to drop after the header (the type row of a tab-separated RDB file).
    pub skip_after_header: u32,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields, default)]
pub struct XmlDef {
    /// Element names that are always a list, even when the response has just one.
    pub always_array: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct PagingDef {
    /// "offset" (a start position), "page" (a page number), "cursor" (a token from the last response) or "next_link"
    /// (the next URL from the last response).
    #[serde(rename = "type")]
    pub kind: String,
    /// The query parameter that carries the offset, page number or cursor.
    #[serde(default)]
    pub param: Option<String>,
    /// The query parameter that carries the page size.
    #[serde(default)]
    pub size_param: Option<String>,
    #[serde(default)]
    pub page_size: Option<u32>,
    /// First page number (default 1; offsets start at 0).
    #[serde(default)]
    pub start: Option<u32>,
    /// Path of the list that is joined across pages (empty or "^": the response itself is the list).
    #[serde(default)]
    pub list_path: String,
    /// "cursor" and "next_link": path of the token or the URL in each response; absent or empty ends the paging.
    #[serde(default)]
    pub next_path: Option<String>,
    /// Path of a flag that says there are more pages (ArcGIS `exceededTransferLimit`). When set, paging goes on only while
    /// it is true.
    #[serde(default)]
    pub more_path: Option<String>,
    /// Hard cap on pages (default 5, at most 50). Reaching it with more data left sets `truncated`.
    #[serde(default)]
    pub max_pages: Option<u32>,
}

#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
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

#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct BasicAuthDef {
    pub user_alias: String,
    pub password_alias: String,
    #[serde(default = "yes")]
    pub required: bool,
}

/// A value the user can set.
#[derive(Debug, Clone, Deserialize, serde::Serialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct ParamDef {
    /// Letters, digits and `_`.
    pub name: String,
    /// What the app shows next to the input.
    #[serde(default)]
    pub label: Option<String>,
    /// "text" (default), "number", "integer", "bool" or "choice".
    #[serde(default, rename = "type")]
    pub kind: Option<String>,
    /// Used when the caller gives no value. A parameter with no default and `required` not false must be given.
    #[serde(default)]
    pub default: Option<Value>,
    #[serde(default = "yes")]
    pub required: bool,
    /// "choice": the allowed values.
    #[serde(default)]
    pub choices: Vec<String>,
    /// "number" and "integer": limits.
    #[serde(default)]
    pub min: Option<f64>,
    #[serde(default)]
    pub max: Option<f64>,
    #[serde(default)]
    pub help: Option<String>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct Quota {
    pub per_minute: Option<u32>,
    pub per_day: Option<u32>,
    pub per_month: Option<u32>,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
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
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct ItemDef {
    /// Path to an array (one item per element) or to an object (one item per member; `@key` is the member's name).
    /// Without it, one item from the response root.
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
    /// Keep only items that pass every one of these.
    #[serde(default, rename = "where")]
    pub filter: Vec<Cond>,
    /// Keep only items whose point or area is within this distance of the place.
    #[serde(default)]
    pub near: Option<NearDef>,
    /// Order of the items of this group (first key first); without it, the response's order.
    #[serde(default)]
    pub sort: Vec<SortKey>,
    /// Keep at most this many items of the group (after filtering and sorting).
    #[serde(default)]
    pub limit: Option<usize>,
    #[serde(default)]
    pub point: Option<PointDef>,
    /// Path to a GeoJSON geometry for the item's area.
    #[serde(default)]
    pub area: Option<String>,
    /// One item for a part of the day ahead (the night, the daytime) instead of one per element: values are read over the
    /// elements of a time series that fall in it, with `agg`. The item's time and end are the period's unless given.
    #[serde(default)]
    pub window: Option<WindowDef>,
}

/// The part of the day ahead an item covers, in the place's local time, from when the data was fetched: the one in progress,
/// else the next. "18 to 7" is the night ahead (over midnight); "7 to 18" the daytime.
#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct WindowDef {
    /// Path to the list of times of the series (`hourly.time`).
    pub each: String,
    /// How those times are written.
    pub time: TimeSpec,
    /// The local hour (0-23) the period starts.
    pub from_hour: u32,
    /// The local hour it ends; smaller than `from_hour` for a period over midnight.
    pub to_hour: u32,
    /// How long each element of the series covers, in minutes (default 60): an element counts when it overlaps the period.
    #[serde(default)]
    pub step_minutes: Option<u32>,
}

/// A value over the elements of the item's `window`.
#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct AggSpec {
    /// "min", "max", "sum", "first" or "last".
    pub op: String,
    /// The value at each element (`[#]` is that element's index).
    pub value: Box<Spec>,
}

/// A number written in the definition, or found by a value (for example a parameter).
#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(untagged)]
pub enum Num {
    Lit(f64),
    Val(Box<Spec>),
}

#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct NearDef {
    /// The largest distance from the place.
    pub max: Num,
    /// "mi" or "km".
    pub unit: String,
    /// Measure to this point instead of the item's `point`.
    #[serde(default)]
    pub point: Option<PointDef>,
    /// Measure to this GeoJSON geometry (a path) instead of the item's `point` or `area`.
    #[serde(default)]
    pub geometry: Option<String>,
}

/// One condition of `where`. Exactly one of `value`, `field` or `or` names what is tested; then at least one test.
#[derive(Debug, Clone, Default, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields, default)]
pub struct Cond {
    /// A value of the response (any way a value can be found).
    pub value: Option<Spec>,
    /// The label of one of the item's mapped `fields` (the number at the start of the text is used for comparisons).
    pub field: Option<String>,
    /// True if any of these conditions is true.
    pub or: Vec<Cond>,
    pub equals: Option<Value>,
    pub not_equals: Option<Value>,
    #[serde(rename = "in")]
    pub one_of: Vec<Value>,
    pub not_in: Vec<Value>,
    pub gt: Option<Num>,
    pub ge: Option<Num>,
    pub lt: Option<Num>,
    pub le: Option<Num>,
    /// Text contains (ignoring case).
    pub contains: Option<String>,
    pub starts_with: Option<String>,
    /// True: the value exists. False: it does not.
    pub exists: Option<bool>,
    /// The value is a time (give it a `time` step, else RFC 3339) no more than this many hours before the fetch.
    pub max_age_hours: Option<Num>,
}

/// One sort key. Missing values sort last.
#[derive(Debug, Clone, Default, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields, default)]
pub struct SortKey {
    /// The value to sort by (not needed with `distance`).
    pub by: Option<Spec>,
    /// The values in order (case-insensitive); a value not in the list sorts after them.
    pub rank: Vec<String>,
    /// Sort by time (the value is read as a time; RFC 3339 unless `by` says otherwise).
    pub time: bool,
    /// Sort by the number at the start of the value.
    pub number: bool,
    /// Sort by distance from the place to the item (its `near` geometry, else its `point`, else its `area`).
    pub distance: bool,
    pub desc: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct PointDef {
    pub lat: Spec,
    pub lon: Spec,
}

/// How one value is found and written. Exactly one of `path`, `const`, `template`, `first_of`, `distance`, `param`,
/// `calc`, `agg`, `window` gives the value; the rest are formatting steps applied in a fixed order (see `map.rs`).
#[derive(Debug, Clone, Default, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
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
    /// Distance and compass direction from the place to a point, a line, an area or a coordinate pair: "6.2 mi S", or
    /// "inside the area". Missing when the item has no such geometry.
    pub distance: Option<DistanceSpec>,
    /// The value of a user parameter.
    pub param: Option<String>,
    /// Arithmetic on other values.
    pub calc: Option<CalcSpec>,
    /// A value over the elements of the item's `window` (only in an item with one).
    pub agg: Option<AggSpec>,
    /// "from" or "to": when the item's `window` starts or ends, as Unix seconds (write it with `"time": {"in": "unix"}`).
    pub window: Option<String>,
    pub scale: Option<f64>,
    pub offset: Option<f64>,
    /// Decimals to round to (0 = whole numbers).
    pub round: Option<u32>,
    /// Keep only the text after the last occurrence of this (the last part of a URL: `"/"`), applied first.
    pub after_last: Option<String>,
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
    /// A number below this (or above `max_value`) is missing: providers write -999 or -9999 for "no reading".
    pub min_value: Option<f64>,
    pub max_value: Option<f64>,
}

#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct DistanceSpec {
    /// Path to a GeoJSON geometry or feature (Point, LineString, Polygon, their Multi forms, collections).
    #[serde(default)]
    pub geometry: Option<String>,
    /// Or: a coordinate pair.
    #[serde(default)]
    pub point: Option<Box<PointDef>>,
    /// "mi" or "km".
    pub unit: String,
    /// Give just the number (for `calc`, `where` and `round`), not "6.2 mi S".
    #[serde(default)]
    pub number: bool,
}

#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct CalcSpec {
    /// "add", "sub", "mul", "div" (left to right over `args`), "min" or "max". The signs + - * / are also accepted.
    pub op: String,
    /// Two or more values. If any is missing, so is the result (use `first_of` to give a fallback).
    pub args: Vec<Spec>,
}

#[derive(Debug, Clone, Deserialize)]
#[cfg_attr(feature = "schema", derive(schemars::JsonSchema))]
#[serde(deny_unknown_fields)]
pub struct TimeSpec {
    /// How the response writes the time: "local" (no offset, in the place's offset: `2026-10-25T14:00` or a date),
    /// "utc" (no offset, in UTC: `2026-10-26 05:17:56.783` or `...Z`), "rfc3339" (with an offset), "rfc2822",
    /// "unix" (seconds), "unix_ms" (milliseconds) or "pattern" (see `pattern`).
    #[serde(rename = "in")]
    pub input: String,
    /// With "pattern": a strftime pattern the text follows (`%d/%m/%Y %H:%M`). With `%z` it has an offset; without, it
    /// is read in `assume`.
    #[serde(default)]
    pub pattern: Option<String>,
    /// With "pattern" and no offset in it: "place" (default) or "utc".
    #[serde(default)]
    pub assume: Option<String>,
    /// "datetime" (`2026-10-25T14:00-06:00`, default), "datetime_s" (with seconds), "date", or a strftime pattern.
    #[serde(default)]
    pub out: Option<String>,
    /// "place": write it in the place's offset even when the response gave another. Default: keep the response's.
    #[serde(default)]
    pub zone: Option<String>,
    /// A date (`2000-01-01`) before which a time is missing: providers write year 0001 or 1970 for "no time".
    #[serde(default)]
    pub not_before: Option<String>,
}

fn is_param_name(s: &str) -> bool {
    !s.is_empty() && s.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

impl SourceDef {
    /// Parse and validate. The error message is every problem found, each with the path of the field.
    pub fn parse(text: &str) -> Result<SourceDef> {
        SourceDef::check(text).map_err(|errs| Error::bad_json(errs.join("; ")))
    }

    /// Parse and validate, returning every problem found (not just the first), each naming its field
    /// (`items[0].fields[2].time.in: ...`).
    pub fn check(text: &str) -> std::result::Result<SourceDef, Vec<String>> {
        let mut de = serde_json::Deserializer::from_str(text.trim_start_matches('\u{feff}'));
        let d: SourceDef = match serde_path_to_error::deserialize(&mut de) {
            Ok(d) => d,
            Err(e) => {
                let p = e.path().to_string();
                let inner = e.inner();
                // serde's message already says "at line L column C" for syntax errors; a path of "." is the document itself
                return Err(vec![if p == "." { format!("source definition: {inner}") } else { format!("source definition, field {p}: {inner}") }]);
            }
        };
        let mut errs = Vec::new();
        d.validate(&mut errs);
        if errs.is_empty() {
            Ok(d)
        } else {
            Err(errs)
        }
    }

    /// Every request of the definition, steps included, in order.
    pub fn requests(&self) -> Vec<&RequestDef> {
        if self.request.steps.is_empty() {
            vec![&self.request]
        } else {
            self.request.steps.iter().collect()
        }
    }

    fn validate(&self, errs: &mut Vec<String>) {
        let id = &self.id;
        macro_rules! bad { ($m:expr) => { errs.push(format!("source {id:?}: {}", $m)) }; }
        if !(MIN_FORMAT..=FORMAT).contains(&self.format) {
            bad!(format!("format: {} is not supported (this core reads formats {MIN_FORMAT} to {FORMAT})", self.format));
        }
        if self.id.is_empty() || !self.id.chars().all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-') {
            bad!("id: must be lower-case letters, digits, _ and -");
        }
        if self.description.trim().is_empty() || self.title.trim().is_empty() || self.provider.trim().is_empty() {
            bad!("title, provider and description are required");
        }
        if self.none_label.as_deref().is_some_and(|l| l.trim().is_empty()) {
            bad!("none_label: must not be empty (leave it out to use the title)");
        }
        if self.refresh_minutes == 0 {
            bad!("refresh_minutes: must be at least 1");
        }
        match (&self.validity.fixed_hours, &self.validity.end_path) {
            (Some(h), None) if *h > 0.0 => {}
            (None, Some(_)) => {}
            _ => bad!("validity: needs exactly one of fixed_hours (> 0) or end_path"),
        }
        if self.validity.fixed_hours.is_some() && (self.validity.end_of_day || self.validity.not_covered_after) {
            bad!("validity: end_of_day and not_covered_after go with end_path");
        }
        if self.items.is_empty() {
            bad!("items: must not be empty");
        }
        if self.api_key.is_some() && self.basic_auth.is_some() {
            bad!("api_key and basic_auth cannot both be set (put a second key in a header with {api_key} only once)");
        }
        // parameters
        let mut names = std::collections::HashSet::new();
        for (i, p) in self.params.iter().enumerate() {
            if !is_param_name(&p.name) {
                bad!(format!("params[{i}].name: letters, digits and _ only"));
            }
            if !names.insert(p.name.as_str()) {
                bad!(format!("params[{i}].name: {:?} is used twice", p.name));
            }
            let kind = p.kind.as_deref().unwrap_or("text");
            if !["text", "number", "integer", "bool", "choice"].contains(&kind) {
                bad!(format!("params[{i}].type: must be text, number, integer, bool or choice"));
            }
            if kind == "choice" && p.choices.is_empty() {
                bad!(format!("params[{i}].choices: a choice needs its values"));
            }
            if let Some(d) = &p.default {
                if let Err(m) = crate::params::normalize(p, d) {
                    bad!(format!("params[{i}].default: {m}"));
                }
            }
        }
        // requests
        let r = &self.request;
        if r.steps.is_empty() {
            if r.url.is_none() {
                bad!("request.url: required (or give request.steps)");
            }
            if r.id.is_some() || r.for_each.is_some() {
                bad!("request: id and for_each belong inside request.steps");
            }
            validate_request(r, "request", &self.params, &[], errs, id);
        } else {
            if r.url.is_some() || r.body.is_some() || r.paging.is_some() || r.response.is_some() || r.table.is_some() || r.xml.is_some() {
                bad!("request: with steps, give url, body, response and paging inside each step (headers, timeout_seconds and max_bytes here are shared)");
            }
            if r.steps.len() > MAX_STEPS {
                bad!(format!("request.steps: at most {MAX_STEPS} steps"));
            }
            let mut earlier: Vec<(String, bool)> = Vec::new();
            for (i, s) in r.steps.iter().enumerate() {
                let at = format!("request.steps[{i}]");
                if !s.steps.is_empty() {
                    bad!(format!("{at}.steps: steps do not nest"));
                }
                match s.id.as_deref() {
                    Some(n) if is_param_name(n) && !earlier.iter().any(|(e, _)| e == n) => {}
                    Some(n) => bad!(format!("{at}.id: {n:?} must be letters, digits and _, and not used before")),
                    None => bad!(format!("{at}.id: every step needs an id")),
                }
                if s.url.is_none() {
                    bad!(format!("{at}.url: required"));
                }
                if let Some(f) = &s.for_each {
                    match earlier.iter().find(|(e, _)| *e == f.from) {
                        Some((_, false)) => {}
                        Some((_, true)) => bad!(format!("{at}.for_each.from: {:?} is itself repeated; take a plain step", f.from)),
                        None => bad!(format!("{at}.for_each.from: no earlier step called {:?}", f.from)),
                    }
                    if !is_param_name(&f.name) {
                        bad!(format!("{at}.for_each.as: letters, digits and _ only"));
                    }
                    if f.limit.map(|l| l == 0 || l > MAX_FAN_OUT).unwrap_or(false) {
                        bad!(format!("{at}.for_each.limit: 1 to {MAX_FAN_OUT}"));
                    }
                }
                let vars: Vec<(String, bool)> = earlier.clone();
                let loopvar: Vec<&str> = s.for_each.iter().map(|f| f.name.as_str()).collect();
                validate_request(s, &at, &self.params, &loopvar, errs, id);
                let _ = vars;
                earlier.push((s.id.clone().unwrap_or_default(), s.for_each.is_some()));
            }
        }
        for (i, it) in self.items.iter().enumerate() {
            it.validate(&format!("items[{i}]"), &self.params, errs, id);
        }
        // placeholders naming a key need the key declared
        let uses_key = self.requests().iter().any(|q| request_text(q).contains("{api_key}"))
            || self.request.headers.values().any(|v| v.contains("{api_key}"));
        if uses_key && self.api_key.is_none() {
            bad!("request: {api_key} is used but api_key is not declared");
        }
    }
}

/// All the text of a request that takes placeholders (url, headers, body).
fn request_text(r: &RequestDef) -> String {
    let mut s = String::new();
    s.push_str(r.url.as_deref().unwrap_or(""));
    for (k, v) in &r.headers {
        s.push(' ');
        s.push_str(k);
        s.push(' ');
        s.push_str(v);
    }
    if let Some(b) = &r.body {
        body_strings(b, &mut s);
    }
    s
}

/// The strings of a JSON body (the only places a placeholder can be), separated by spaces.
fn body_strings(v: &Value, out: &mut String) {
    match v {
        Value::String(t) => {
            out.push(' ');
            out.push_str(t);
        }
        Value::Array(a) => a.iter().for_each(|x| body_strings(x, out)),
        Value::Object(o) => o.values().for_each(|x| body_strings(x, out)),
        _ => {}
    }
}

fn validate_request(r: &RequestDef, at: &str, params: &[ParamDef], loopvars: &[&str], errs: &mut Vec<String>, id: &str) {
    macro_rules! bad { ($m:expr) => { errs.push(format!("source {id:?}: {at}.{}", $m)) }; }
    if let Some(u) = &r.url {
        if !u.starts_with("https://") && !u.starts_with("http://") && !u.starts_with('{') {
            bad!("url: must start with https://");
        }
    }
    if let Some(m) = &r.method {
        if m != "GET" && m != "POST" {
            bad!("method: GET or POST");
        }
    }
    let kind = r.body_type.as_deref().unwrap_or("json");
    if !["json", "form", "text"].contains(&kind) {
        bad!("body_type: json, form or text");
    }
    if r.body.is_some() && r.method.as_deref() != Some("POST") {
        bad!("body: only a POST request has a body (set method to POST)");
    }
    match (kind, &r.body) {
        ("form", Some(b)) if !b.is_object() => bad!("body: a form body is an object of values"),
        ("text", Some(b)) if !b.is_string() => bad!("body: a text body is a string"),
        _ => {}
    }
    if r.timeout_seconds.map(|t| t == 0 || t > MAX_TIMEOUT_S).unwrap_or(false) {
        bad!(format!("timeout_seconds: 1 to {MAX_TIMEOUT_S}"));
    }
    if r.max_bytes.map(|b| b == 0 || b > MAX_MAX_BYTES).unwrap_or(false) {
        bad!(format!("max_bytes: 1 to {MAX_MAX_BYTES} (32 MiB)"));
    }
    if let Some(f) = &r.response {
        if !["json", "geojson", "xml", "csv", "tsv", "tle", "auto"].contains(&f.as_str()) {
            bad!("response: json, geojson, xml, csv, tsv, tle or auto");
        }
    }
    for (k, v) in &r.headers {
        if k.is_empty() || !k.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_') {
            bad!(format!("headers: {k:?} is not a valid header name"));
        }
        if ["host", "content-length", "transfer-encoding", "connection"].contains(&k.to_ascii_lowercase().as_str()) {
            bad!(format!("headers: {k} is set by the core"));
        }
        if v.bytes().any(|b| b < 0x20 && b != b'\t' || b == 0x7f) {
            bad!(format!("headers.{k}: control characters are not allowed"));
        }
    }
    if let Some(p) = &r.paging {
        let at = "paging";
        let need_param = matches!(p.kind.as_str(), "offset" | "page" | "cursor");
        match p.kind.as_str() {
            "offset" | "page" | "cursor" | "next_link" => {}
            _ => bad!(format!("{at}.type: offset, page, cursor or next_link")),
        }
        if need_param && p.param.is_none() {
            bad!(format!("{at}.param: the query parameter name is required for {}", p.kind));
        }
        if matches!(p.kind.as_str(), "cursor" | "next_link") && p.next_path.is_none() {
            bad!(format!("{at}.next_path: required for {}", p.kind));
        }
        if matches!(p.kind.as_str(), "offset" | "page") && p.page_size.is_none() {
            bad!(format!("{at}.page_size: required for {}", p.kind));
        }
        if p.size_param.is_some() && p.page_size.is_none() {
            bad!(format!("{at}.size_param: needs page_size"));
        }
        if p.max_pages.map(|m| m == 0 || m > MAX_PAGES).unwrap_or(false) {
            bad!(format!("{at}.max_pages: 1 to {MAX_PAGES}"));
        }
        if p.page_size == Some(0) {
            bad!(format!("{at}.page_size: must be at least 1"));
        }
    }
    // placeholders in url, headers and body must be understood
    let text = request_text(r);
    let mut rest = text.as_str();
    while let Some(i) = rest.find('{') {
        let Some(j) = rest[i..].find('}') else { break };
        let hole = &rest[i + 1..i + j];
        if let Err(m) = crate::request::check_placeholder(hole, params, loopvars) {
            bad!(format!("placeholder {{{hole}}}: {m}"));
        }
        rest = &rest[i + j + 1..];
    }
}

impl ItemDef {
    fn validate(&self, at: &str, params: &[ParamDef], errs: &mut Vec<String>, id: &str) {
        for (i, f) in self.fields.iter().enumerate() {
            if f.label.as_deref().map(str::trim).unwrap_or("").is_empty() {
                errs.push(format!("source {id:?}: {at}.fields[{i}].label: every entry of fields needs a label"));
            }
        }
        self.key.validate(&format!("{at}.key"), params, errs, id);
        self.label.validate(&format!("{at}.label"), params, errs, id);
        if let Some(s) = &self.time {
            s.validate(&format!("{at}.time"), params, errs, id);
        }
        if let Some(s) = &self.ends {
            s.validate(&format!("{at}.ends"), params, errs, id);
        }
        for (i, f) in self.fields.iter().enumerate() {
            f.validate(&format!("{at}.fields[{i}]"), params, errs, id);
        }
        let labels: Vec<&str> = self.fields.iter().filter_map(|f| f.label.as_deref()).collect();
        for (i, c) in self.filter.iter().enumerate() {
            c.validate(&format!("{at}.where[{i}]"), params, &labels, errs, id);
        }
        if let Some(n) = &self.near {
            if n.unit != "mi" && n.unit != "km" {
                errs.push(format!("source {id:?}: {at}.near.unit: must be mi or km"));
            }
            if let Num::Val(s) = &n.max {
                s.validate(&format!("{at}.near.max"), params, errs, id);
            }
            if n.point.is_some() && n.geometry.is_some() {
                errs.push(format!("source {id:?}: {at}.near: give point or geometry, not both"));
            }
            if n.point.is_none() && n.geometry.is_none() && self.point.is_none() && self.area.is_none() {
                errs.push(format!("source {id:?}: {at}.near: needs the item to have a point or area, or a point or geometry here"));
            }
            if let Some(p) = &n.point {
                p.lat.validate(&format!("{at}.near.point.lat"), params, errs, id);
                p.lon.validate(&format!("{at}.near.point.lon"), params, errs, id);
            }
        }
        for (i, k) in self.sort.iter().enumerate() {
            let at = format!("{at}.sort[{i}]");
            match (&k.by, k.distance) {
                (Some(b), false) => b.validate(&format!("{at}.by"), params, errs, id),
                (None, true) => {
                    if self.near.is_none() && self.point.is_none() && self.area.is_none() {
                        errs.push(format!("source {id:?}: {at}.distance: the item needs a point or area (or near) to measure to"));
                    }
                }
                (Some(_), true) => errs.push(format!("source {id:?}: {at}: distance sorts by distance; remove by")),
                (None, false) => errs.push(format!("source {id:?}: {at}.by: required (or distance: true)")),
            }
            if [k.time, k.number, k.distance, !k.rank.is_empty()].iter().filter(|b| **b).count() > 1 {
                errs.push(format!("source {id:?}: {at}: use only one of rank, time, number, distance"));
            }
        }
        if let Some(p) = &self.point {
            p.lat.validate(&format!("{at}.point.lat"), params, errs, id);
            p.lon.validate(&format!("{at}.point.lon"), params, errs, id);
        }
        if self.limit == Some(0) {
            errs.push(format!("source {id:?}: {at}.limit: must be at least 1"));
        }
        match &self.window {
            Some(w) => {
                if self.each.is_some() {
                    errs.push(format!("source {id:?}: {at}: give each or window, not both"));
                }
                if w.from_hour > 23 || w.to_hour > 23 || w.from_hour == w.to_hour {
                    errs.push(format!("source {id:?}: {at}.window: from_hour and to_hour are different hours, 0 to 23"));
                }
                if !["local", "utc", "rfc3339", "rfc2822", "unix", "unix_ms", "pattern"].contains(&w.time.input.as_str()) {
                    errs.push(format!("source {id:?}: {at}.window.time.in: must be local, utc, rfc3339, rfc2822, unix, unix_ms or pattern"));
                }
            }
            None => {
                let specs = [Some(&self.key), Some(&self.label), self.time.as_ref(), self.ends.as_ref()];
                if specs.into_iter().flatten().chain(self.fields.iter()).any(Spec::needs_window) {
                    errs.push(format!("source {id:?}: {at}: agg and window values need the item to have a window"));
                }
            }
        }
    }
}

impl Cond {
    fn validate(&self, at: &str, params: &[ParamDef], labels: &[&str], errs: &mut Vec<String>, id: &str) {
        let named = [self.value.is_some(), self.field.is_some(), !self.or.is_empty()].iter().filter(|b| **b).count();
        if named != 1 {
            errs.push(format!("source {id:?}: {at}: needs exactly one of value, field, or"));
        }
        if let Some(v) = &self.value {
            v.validate(&format!("{at}.value"), params, errs, id);
        }
        if let Some(f) = &self.field {
            if !labels.contains(&f.as_str()) {
                errs.push(format!("source {id:?}: {at}.field: {f:?} is not the label of one of this item's fields"));
            }
        }
        for (i, c) in self.or.iter().enumerate() {
            c.validate(&format!("{at}.or[{i}]"), params, labels, errs, id);
        }
        if self.max_age_hours.is_some() && self.value.is_none() {
            errs.push(format!("source {id:?}: {at}.max_age_hours: goes with value (a time)"));
        }
        for (n, num) in [("gt", &self.gt), ("ge", &self.ge), ("lt", &self.lt), ("le", &self.le), ("max_age_hours", &self.max_age_hours)] {
            if let Some(Num::Val(s)) = num {
                s.validate(&format!("{at}.{n}"), params, errs, id);
            }
        }
        let tests = [
            self.equals.is_some(),
            self.not_equals.is_some(),
            !self.one_of.is_empty(),
            !self.not_in.is_empty(),
            self.gt.is_some(),
            self.ge.is_some(),
            self.lt.is_some(),
            self.le.is_some(),
            self.contains.is_some(),
            self.starts_with.is_some(),
            self.exists.is_some(),
            self.max_age_hours.is_some(),
        ];
        if self.or.is_empty() && !tests.iter().any(|t| *t) {
            errs.push(format!("source {id:?}: {at}: needs a test (equals, not_equals, in, not_in, gt, ge, lt, le, contains, starts_with, exists, max_age_hours)"));
        }
    }
}

impl Spec {
    /// Whether this value, or one inside it, reads the item's window.
    fn needs_window(&self) -> bool {
        self.agg.is_some()
            || self.window.is_some()
            || self.vars.values().any(Spec::needs_window)
            || self.first_of.iter().any(Spec::needs_window)
            || self.calc.as_ref().map(|c| c.args.iter().any(Spec::needs_window)).unwrap_or(false)
    }

    fn validate(&self, at: &str, params: &[ParamDef], errs: &mut Vec<String>, id: &str) {
        let n = [
            self.path.is_some(),
            self.constant.is_some(),
            self.template.is_some(),
            !self.first_of.is_empty(),
            self.distance.is_some(),
            self.param.is_some(),
            self.calc.is_some(),
            self.agg.is_some(),
            self.window.is_some(),
        ]
        .iter()
        .filter(|b| **b)
        .count();
        macro_rules! bad { ($m:expr) => { errs.push(format!("source {id:?}: {at}: {}", $m)) }; }
        if n != 1 {
            bad!(format!(
                "a value ({:?}) needs exactly one of path, const, template, first_of, distance, param, calc, agg, window",
                self.label
            ));
        }
        if let Some(a) = &self.agg {
            if !["min", "max", "sum", "first", "last"].contains(&a.op.as_str()) {
                bad!("agg.op: min, max, sum, first or last");
            }
            a.value.validate(&format!("{at}.agg.value"), params, errs, id);
        }
        if self.window.as_deref().map(|w| w != "from" && w != "to").unwrap_or(false) {
            bad!("window: from or to");
        }
        if let Some(t) = &self.time {
            if !["local", "utc", "rfc3339", "rfc2822", "unix", "unix_ms", "pattern"].contains(&t.input.as_str()) {
                bad!("time.in: must be local, utc, rfc3339, rfc2822, unix, unix_ms or pattern");
            }
            if t.input == "pattern" && t.pattern.is_none() {
                bad!("time.pattern: required with in = pattern");
            }
            if t.input != "pattern" && (t.pattern.is_some() || t.assume.is_some()) {
                bad!("time.pattern and time.assume go with in = pattern");
            }
            if t.assume.as_deref().map(|a| a != "place" && a != "utc").unwrap_or(false) {
                bad!("time.assume: place or utc");
            }
            if t.not_before.as_deref().map(|d| chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").is_err()).unwrap_or(false) {
                bad!("time.not_before: a date like 2000-01-01");
            }
        }
        if let Some(d) = &self.distance {
            if d.unit != "mi" && d.unit != "km" {
                bad!("distance.unit: must be mi or km");
            }
            if d.geometry.is_some() == d.point.is_some() {
                bad!("distance: needs exactly one of geometry or point");
            }
            if let Some(p) = &d.point {
                p.lat.validate(&format!("{at}.distance.point.lat"), params, errs, id);
                p.lon.validate(&format!("{at}.distance.point.lon"), params, errs, id);
            }
        }
        if let Some(p) = &self.param {
            if !params.iter().any(|d| &d.name == p) {
                bad!(format!("param: no parameter called {p:?} (declare it in params)"));
            }
        }
        if let Some(c) = &self.calc {
            if !["add", "sub", "mul", "div", "min", "max", "+", "-", "*", "/"].contains(&c.op.as_str()) {
                bad!("calc.op: add, sub, mul, div, min or max");
            }
            if c.args.len() < 2 {
                bad!("calc.args: at least two values");
            }
            for (i, a) in c.args.iter().enumerate() {
                a.validate(&format!("{at}.calc.args[{i}]"), params, errs, id);
            }
        }
        if let Some(c) = &self.case {
            if c != "lower" && c != "upper" {
                bad!("case: must be lower or upper");
            }
        }
        for (k, s) in &self.vars {
            s.validate(&format!("{at}.vars.{k}"), params, errs, id);
        }
        for (i, s) in self.first_of.iter().enumerate() {
            s.validate(&format!("{at}.first_of[{i}]"), params, errs, id);
        }
        if let Some(t) = &self.template {
            // every {name} in a template needs a var
            let mut rest = t.as_str();
            while let Some(i) = rest.find('{') {
                match rest[i..].find('}') {
                    Some(j) => {
                        let name = &rest[i + 1..i + j];
                        if !self.vars.contains_key(name) {
                            bad!(format!("template: {{{name}}} has no entry in vars"));
                        }
                        rest = &rest[i + j + 1..];
                    }
                    None => {
                        bad!("template: unclosed {");
                        break;
                    }
                }
            }
        }
    }
}
