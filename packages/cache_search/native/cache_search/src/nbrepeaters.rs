//! Repeater lists as notebooks (`cs_notebook` ops `repeaters_import` and `repeaters_add_back`, and the conversion of the lists the
//! older versions kept in user.sqlite).
//!
//! A repeater list is a notebook of the `repeaters` template: one entry per repeater (the callsign is its title, the position its
//! place) and seven fixed text fields holding the core's own words for the settings, exactly what `cs_userlayer_get` and the
//! assistant's `nearby` gave for a list row. "Update from a file" is cache_notebook's `source_merge` (a three-way merge that keeps
//! what the person changed); this module reads the files, makes the rows and keys, and matches entries made by hand.
//!
//! A row's key is the callsign, the frequency in Hz and the town, case-folded and with spaces collapsed, and `#2`, `#3` for exact
//! repeats inside one file (one callsign can run the same frequency at two sites, so the town is part of it).
//!
//! The assistant's `nearby` reads these notebooks through [`NotebookRepeaters`], with the same keys and the same words.

use crate::error::{Error, ErrorCode, Result};
use crate::ext::Ext;
use cache_tool::user::{UserCategory, UserPoint, UserPoints};
use cache_user::mapdata::repeater::{frequency_text, mhz_to_hz, Repeater};
use cache_user::mapdata::{self, LegacyRepeaterList, MapStore};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::Arc;

/// The template id of a repeater list's notebook.
pub const TEMPLATE: &str = "repeaters";

/// The fixed fields, in order (their ids are f1 to f7 in a notebook made here). Must match `assets/notebook/templates.json`.
pub const FIELDS: [(&str, &str); 7] = [
    ("Frequency", "text"),
    ("Offset", "text"),
    ("Tone", "text"),
    ("Mode", "text"),
    ("Town", "text"),
    ("On air", "yes_no"),
    ("Details link", "text"),
];

fn nb_err(e: cache_notebook::Error) -> Error {
    Error::new(ErrorCode::from_str_code(e.code), e.message)
}

fn user_err(e: cache_user::Error) -> Error {
    Error::new(ErrorCode::from_str_code(e.code), e.message)
}

/// The notebook's definition for a list called `name`: the template's, as data (shape, icon, colour, fields).
pub fn def(name: &str) -> Value {
    json!({
        "id": TEMPLATE, "version": 1, "author": "Cache",
        "name": name, "due_every": null, "icon": "radio_tower", "color": "purple",
        "shape": {"sort": "distance"},
        "fields": FIELDS.iter().map(|(l, t)| json!({"label": l, "type": t})).collect::<Vec<_>>(),
    })
}

fn norm(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ").to_lowercase()
}

fn base_key(name: &str, freq_hz: i64, town: Option<&str>) -> String {
    format!("{}|{}|{}", norm(name), freq_hz, norm(town.unwrap_or("")))
}

/// The keys of a list's repeaters in order: the base key, `#2`, `#3` for exact repeats.
fn keys_of<'a>(parts: impl Iterator<Item = (String, i64, Option<&'a str>)>) -> Vec<String> {
    let mut seen: HashMap<String, usize> = HashMap::new();
    parts
        .map(|(name, hz, town)| {
            let base = base_key(&name, hz, town);
            let n = seen.entry(base.clone()).or_insert(0);
            *n += 1;
            if *n == 1 { base } else { format!("{base}#{n}") }
        })
        .collect()
}

/// The field ids by label, for a notebook's definition as `notebook` answers it; a notebook made here has f1 to f7.
fn fids(def: Option<&Value>) -> HashMap<String, String> {
    match def.and_then(|d| d["fields"].as_array()) {
        Some(fs) => fs.iter().filter(|f| f["hidden"] != true).filter_map(|f| Some((f["label"].as_str()?.to_lowercase(), f["fid"].as_str()?.to_string()))).collect(),
        None => FIELDS.iter().enumerate().map(|(i, (l, _))| (l.to_lowercase(), format!("f{}", i + 1))).collect(),
    }
}

/// One repeater as a `source_merge` row (see cache_notebook's source.rs).
fn row(r: &Repeater, key: &str, fid: &HashMap<String, String>, source: String) -> Value {
    let mut values = Map::new();
    let mut put = |label: &str, v: Value| {
        if let Some(f) = fid.get(&label.to_lowercase()) {
            values.insert(f.clone(), v);
        }
    };
    put("Frequency", json!(frequency_text(r.freq_hz)));
    put("Offset", json!(r.offset_text()));
    put("Tone", json!(r.tone_text()));
    if let Some(m) = &r.mode {
        put("Mode", json!(m));
    }
    if let Some(t) = &r.town {
        put("Town", json!(t));
    }
    if let Some(a) = r.on_air {
        put("On air", json!(a));
    }
    if let Some(l) = &r.link {
        put("Details link", json!(l));
    }
    let mut m = Map::new();
    m.insert("key".into(), json!(key));
    m.insert("title".into(), json!(r.name));
    if let Some((lat, lon)) = r.positioned() {
        m.insert("place".into(), json!({"lat": lat, "lon": lon}));
    }
    m.insert("values".into(), Value::Object(values));
    m.insert("source".into(), json!(source));
    Value::Object(m)
}

fn iso_now() -> String {
    crate::nbplaces::now_iso()
}

fn text(v: &Value) -> Option<&str> {
    v.as_str().filter(|s| !s.trim().is_empty())
}

/// An entry's value in field `label`.
fn value<'a>(e: &'a Value, fid: &HashMap<String, String>, label: &str) -> Option<&'a Value> {
    fid.get(&label.to_lowercase()).and_then(|f| e["values"].get(f)).filter(|v| !v.is_null())
}

impl Ext {
    fn nbr(&self) -> Result<&cache_notebook::Notebook> {
        self.notebook.as_deref().ok_or_else(|| Error::new(ErrorCode::NotConfigured, "Notebooks need \"notebook\": {\"db_path\", \"media_dir\"} in the cs_open config"))
    }

    fn nbr_call(&self, op: &str, args: &Value) -> Result<Value> {
        let out = self.nbr()?.call(op, Some(&args.to_string())).map_err(nb_err)?;
        serde_json::from_str(&out).map_err(|e| Error::internal(format!("notebook answer: {e}")))
    }

    fn entries_of(&self, notebook_id: &str) -> Result<Vec<Value>> {
        let r = self.nbr_call("entries", &json!({"notebook_id": notebook_id, "limit": 100_000_000}))?;
        Ok(r["entries"].as_array().cloned().unwrap_or_default())
    }

    /// A free notebook name: "Repeaters", else "Repeaters: <list>", then " 2", " 3".
    fn free_repeaters_name(&self, list: &str) -> Result<String> {
        let all = self.nbr_call("notebooks", &json!({}))?;
        let taken: Vec<String> = all["notebooks"].as_array().into_iter().flatten().filter_map(|n| n["def"]["name"].as_str()).map(str::to_lowercase).collect();
        let list = mapdata::collapse(list);
        let list = std::path::Path::new(&list).file_stem().map(|s| s.to_string_lossy().into_owned()).filter(|s| !s.is_empty()).unwrap_or(list);
        let mut tries = vec!["Repeaters".to_string()];
        if !list.is_empty() {
            tries.push(format!("Repeaters: {list}").chars().take(70).collect());
        }
        for t in &tries {
            if !taken.contains(&t.to_lowercase()) {
                return Ok(t.clone());
            }
        }
        let base = tries.last().cloned().unwrap_or_default();
        let mut i = 2;
        loop {
            let n = format!("{base} {i}");
            if !taken.contains(&n.to_lowercase()) {
                return Ok(n);
            }
            i += 1;
        }
    }

    /// `repeaters_import` and `repeaters_add_back`.
    ///
    /// `repeaters_import`: `{"paths":[...], "notebook_id"?, "name"?, "now"?}`. A RepeaterBook KML (or KMZ) and/or a CHIRP CSV, merged
    /// as before, into a new notebook of the Repeaters template (`name`, else "Repeaters"), or, with `notebook_id`, into that
    /// notebook as an update (see cache_notebook's `source_merge`). Answers `{"notebook","added","updated","unchanged","kept_edits",
    /// "not_in_file","deleted":[{"key","title"}],"repeaters","with_position","without_position","skipped"}`.
    /// `repeaters_add_back`: `{"notebook_id","now"?}`: the repeaters the person deleted that the file still has, made again.
    pub(crate) fn repeaters_op(&self, op: &str, args: &Value) -> Result<Value> {
        let allowed: &[&str] = if op == "repeaters_import" { &["paths", "notebook_id", "name", "now"] } else { &["notebook_id", "now"] };
        for k in args.as_object().into_iter().flat_map(|o| o.keys()) {
            if !allowed.contains(&k.as_str()) {
                return Err(Error::bad_json(format!("{k}: not allowed")));
            }
        }
        let now = args.get("now").and_then(Value::as_str).map(str::to_string).unwrap_or_else(iso_now);
        if op == "repeaters_add_back" {
            let id = args.get("notebook_id").and_then(Value::as_str).ok_or_else(|| Error::bad_json("notebook_id is missing"))?;
            return self.nbr_call("source_add_back", &json!({"notebook_id": id, "now": now}));
        }
        let paths: Vec<String> = match args.get("paths") {
            Some(Value::Array(a)) if !a.is_empty() => a.iter().map(|p| p.as_str().map(str::to_string).ok_or_else(|| Error::bad_json("paths must be text"))).collect::<Result<_>>()?,
            _ => return Err(Error::bad_json("paths: at least one file")),
        };
        let parsed = mapdata::parse_repeater_files(&paths).map_err(user_err)?;
        let reps = &parsed.repeaters;
        let keys = keys_of(reps.iter().map(|r| (r.name.clone(), r.freq_hz, r.town.as_deref())));
        let (nb_arg, fid, claims) = match args.get("notebook_id").and_then(Value::as_str) {
            Some(id) => {
                let n = self.nbr_call("notebook", &json!({"id": id}))?;
                if n["template"] != TEMPLATE {
                    return Err(Error::bad_json("repeaters are updated in a Repeaters notebook"));
                }
                let fid = fids(Some(&n["def"]));
                let claims = self.claims(id, &fid, &keys)?;
                (json!({"notebook_id": id}), fid, claims)
            }
            None => {
                let given = args.get("name").and_then(Value::as_str).map(mapdata::collapse).filter(|n| !n.is_empty());
                let name = match given {
                    Some(n) => n,
                    None => self.free_repeaters_name(&parsed.first_file)?,
                };
                (json!({"notebook": {"template": TEMPLATE, "def": def(&name), "map": true}}), fids(None), Value::Null)
            }
        };
        let rows: Vec<Value> = reps.iter().zip(&keys).map(|(r, k)| row(r, k, &fid, serde_json::to_string(r).unwrap_or_default())).collect();
        let mut a = nb_arg;
        a["now"] = json!(now);
        a["rows"] = Value::Array(rows);
        if !claims.is_null() {
            a["claims"] = claims;
        }
        let mut out = self.nbr_call("source_merge", &a)?;
        out["repeaters"] = json!(reps.len());
        out["with_position"] = json!(reps.iter().filter(|r| r.positioned().is_some()).count());
        out["without_position"] = json!(reps.iter().filter(|r| r.positioned().is_none()).count());
        out["skipped"] = json!(parsed.skipped);
        Ok(out)
    }

    /// For each row key of the new file, the entry of this notebook that has no ledger row and whose callsign, frequency and town
    /// give that key (the nth such entry for a repeated key): what `source_merge` may fill the blanks of.
    fn claims(&self, notebook_id: &str, fid: &HashMap<String, String>, keys: &[String]) -> Result<Value> {
        let ledger = self.nbr_call("source_rows", &json!({"notebook_id": notebook_id, "brief": true}))?;
        let tied: Vec<&str> = ledger["rows"].as_array().into_iter().flatten().filter_map(|r| r["entry_id"].as_str()).collect();
        let mut derived: HashMap<String, Vec<String>> = HashMap::new();
        let entries = self.entries_of(notebook_id)?;
        let mut ordered: Vec<&Value> = entries.iter().filter(|e| e["draft"] != true).collect();
        ordered.sort_by_key(|e| e["created"].as_i64().unwrap_or(0));
        for e in ordered {
            let Some(id) = e["id"].as_str() else { continue };
            if tied.contains(&id) {
                continue;
            }
            let (Some(title), Some(freq)) = (e["title"].as_str(), value(e, fid, "Frequency").and_then(Value::as_str)) else { continue };
            let Some(hz) = mhz_to_hz(freq.trim().trim_end_matches("MHz").trim()) else { continue };
            let town = value(e, fid, "Town").and_then(Value::as_str);
            derived.entry(base_key(title, hz, town)).or_default().push(id.to_string());
        }
        let mut claims = Map::new();
        for k in keys {
            let (base, n) = match k.rsplit_once('#') {
                Some((b, n)) if n.parse::<usize>().is_ok() => (b, n.parse::<usize>().unwrap_or(1)),
                _ => (k.as_str(), 1),
            };
            if let Some(id) = derived.get(base).and_then(|l| l.get(n - 1)) {
                claims.insert(k.clone(), json!(id));
            }
        }
        Ok(Value::Object(claims))
    }

    /// Turns every repeater list of the older store into a notebook, once, atomically, and deletes the list only after reading the
    /// notebook back and finding every row (see the design note: count, every field of every entry, the stored row byte for
    /// byte). A list whose check fails stays where it is. Returns how many lists became notebooks.
    pub(crate) fn migrate_repeater_lists(&self) -> Result<usize> {
        let (Some(map), Some(_)) = (self.map_data.as_deref(), self.notebook.as_ref()) else { return Ok(0) };
        let lists = map.legacy_repeater_lists().map_err(user_err)?;
        let mut done = 0;
        let stop = |at: u8| -> Result<()> {
            if self.migrate_stop.load(std::sync::atomic::Ordering::SeqCst) == at {
                return Err(Error::new(ErrorCode::Internal, format!("conversion stopped at stage {at} (test hook)")));
            }
            Ok(())
        };
        for l in lists {
            let tref = format!("migrated/{}", l.id);
            let all = self.nbr_call("notebooks", &json!({}))?;
            let existing = all["notebooks"].as_array().into_iter().flatten().find(|n| n["template_ref"] == tref.as_str()).cloned();
            let (id, def_v) = match existing {
                Some(n) => (n["id"].as_str().unwrap_or_default().to_string(), n["def"].clone()),
                None => {
                    stop(1)?;
                    let name = self.free_repeaters_name_for_list(&l)?;
                    let fid = fids(None);
                    let mut reps = Vec::with_capacity(l.rows.len());
                    for (_, raw) in &l.rows {
                        reps.push(LegacyRepeaterList::repeater(raw).map_err(user_err)?);
                    }
                    let keys = keys_of(reps.iter().map(|r| (r.name.clone(), r.freq_hz, r.town.as_deref())));
                    let rows: Vec<Value> = reps.iter().zip(&keys).zip(&l.rows).map(|((r, k), (_, raw))| row(r, k, &fid, raw.clone())).collect();
                    let a = json!({
                        "notebook": {"template": TEMPLATE, "def": def(&name), "map": l.visible, "template_ref": tref},
                        "now": iso_now(), "rows": rows,
                    });
                    let out = self.nbr_call("source_merge", &a)?;
                    stop(2)?;
                    (out["notebook"]["id"].as_str().unwrap_or_default().to_string(), out["notebook"]["def"].clone())
                }
            };
            self.verify_converted(&id, &def_v, &l)?;
            stop(3)?;
            map.delete(&l.id).map_err(user_err)?;
            done += 1;
        }
        Ok(done)
    }

    fn free_repeaters_name_for_list(&self, l: &LegacyRepeaterList) -> Result<String> {
        // The first list is "Repeaters"; another is "Repeaters: <its old name>".
        self.free_repeaters_name(&l.name)
    }

    /// Reads notebook `id` back and checks it against list `l`: the same number of repeaters, each one's stored row byte for byte
    /// in the ledger, and each entry's title, place and every field as the old list gave them.
    fn verify_converted(&self, id: &str, def_v: &Value, l: &LegacyRepeaterList) -> Result<()> {
        let fail = |m: String| Error::new(ErrorCode::Damaged, format!("repeater list {} was not converted: {m}", l.id));
        let fid = fids(Some(def_v));
        let ledger = self.nbr_call("source_rows", &json!({"notebook_id": id}))?;
        let rows = ledger["rows"].as_array().cloned().unwrap_or_default();
        if rows.len() != l.rows.len() {
            return Err(fail(format!("{} rows in the notebook, {} in the list", rows.len(), l.rows.len())));
        }
        let entries = self.entries_of(id)?;
        if entries.len() != l.rows.len() {
            return Err(fail(format!("{} entries in the notebook, {} rows in the list", entries.len(), l.rows.len())));
        }
        let mut reps = Vec::new();
        for (_, raw) in &l.rows {
            reps.push(LegacyRepeaterList::repeater(raw).map_err(user_err)?);
        }
        let keys = keys_of(reps.iter().map(|r| (r.name.clone(), r.freq_hz, r.town.as_deref())));
        for (((r, key), (_, raw)), n) in reps.iter().zip(&keys).zip(&l.rows).zip(1..) {
            let led = rows.iter().find(|x| x["key"] == key.as_str()).ok_or_else(|| fail(format!("row {n} has no ledger row")))?;
            if led["source"].as_str() != Some(raw.as_str()) {
                return Err(fail(format!("row {n}'s stored data differs")));
            }
            let want = row(r, key, &fid, String::new());
            let e = entries.iter().find(|e| Some(e["id"].as_str().unwrap_or_default()) == led["entry_id"].as_str()).ok_or_else(|| fail(format!("row {n} has no entry")))?;
            let same_title = text(&want["title"]).map(str::to_string) == e["title"].as_str().map(str::to_string);
            let same_place = match (want.get("place"), e.get("place")) {
                (Some(a), Some(b)) => a["lat"] == b["lat"] && a["lon"] == b["lon"],
                (None, None) => true,
                _ => false,
            };
            let want_values = want["values"].as_object().cloned().unwrap_or_default();
            let got_values = e["values"].as_object().cloned().unwrap_or_default();
            if !same_title || !same_place || want_values != got_values {
                return Err(fail(format!("row {n} ({}) differs", r.name)));
            }
        }
        Ok(())
    }

    /// Plugs the repeater notebooks into what the tools see (see [`NotebookRepeaters`]).
    pub(crate) fn plug_repeater_points(&self) {
        let (Some(map), Some(nb)) = (self.map_data.as_ref(), self.notebook.as_ref()) else { return };
        let me = NotebookRepeaters { inner: map.clone(), nb: nb.clone() };
        *self.user_points.write().unwrap_or_else(|e| e.into_inner()) = Some(Arc::new(me));
    }
}

/// The user's points for the tools: the map store's, with the repeaters of the Repeaters notebooks added to the `repeater`
/// category (after any list still in the older store). A row has the same keys, in the same order and the same words as a list's
/// row had: frequency, offset, tone, mode, on_air, list (the notebook's name), details. Its address is `repeater:<entry id>`.
pub struct NotebookRepeaters {
    inner: Arc<MapStore>,
    nb: Arc<cache_notebook::Notebook>,
}

impl NotebookRepeaters {
    fn notebook_points(&self) -> Vec<UserPoint> {
        let Ok(books) = self.nb.books_by_template(TEMPLATE) else { return Vec::new() };
        // A notebook made from a list that is still in the older store (a conversion not finished) is not shown twice.
        let unfinished: Vec<String> = self.inner.legacy_repeater_lists().map(|l| l.into_iter().map(|x| format!("migrated/{}", x.id)).collect()).unwrap_or_default();
        let mut out = Vec::new();
        for b in books.into_iter().filter(|b| b["template_ref"].as_str().is_none_or(|r| !unfinished.iter().any(|u| u == r))) {
            let fid = fids(Some(&b["def"]));
            let list = b["name"].as_str().unwrap_or_default().to_string();
            for e in b["entries"].as_array().into_iter().flatten() {
                let (Some(lat), Some(lon)) = (e["place"]["lat"].as_f64(), e["place"]["lon"].as_f64()) else { continue };
                let get = |label: &str| value(e, &fid, label).and_then(Value::as_str).filter(|s| !s.trim().is_empty()).map(str::to_string);
                let freq = get("Frequency");
                let name = e["title"].as_str().filter(|s| !s.trim().is_empty()).map(str::to_string).or_else(|| freq.clone()).unwrap_or_else(|| "Repeater".into());
                let mut fields = Map::new();
                if let Some(f) = freq {
                    fields.insert("frequency".into(), json!(f));
                }
                for (k, label) in [("offset", "Offset"), ("tone", "Tone"), ("mode", "Mode")] {
                    if let Some(v) = get(label) {
                        fields.insert(k.into(), json!(v));
                    }
                }
                if let Some(a) = value(e, &fid, "On air").and_then(Value::as_bool) {
                    fields.insert("on_air".into(), json!(if a { "yes" } else { "no" }));
                }
                fields.insert("list".into(), json!(list));
                if get("Details link").is_some() {
                    fields.insert("details".into(), json!(mapdata::store::REPEATER_DETAILS));
                }
                out.push(UserPoint {
                    address: format!("repeater:{}", e["id"].as_str().unwrap_or_default()),
                    name,
                    kind: "repeater".into(),
                    kind_label: "Repeater".into(),
                    locality: get("Town"),
                    lat,
                    lon,
                    fields,
                });
            }
        }
        out
    }
}

impl UserPoints for NotebookRepeaters {
    fn categories(&self) -> Vec<UserCategory> {
        let mut c = self.inner.categories();
        if !c.iter().any(|x| x.id == "repeater") && !self.notebook_points().is_empty() {
            c.insert(0, UserCategory { id: "repeater".into(), description: "amateur radio repeaters from the user's imported lists".into(), plural: "repeaters".into() });
        }
        c
    }

    fn points(&self, category: &str) -> Option<Vec<UserPoint>> {
        if category != "repeater" {
            return self.inner.points(category);
        }
        let mut out = self.inner.points(category).unwrap_or_default();
        out.extend(self.notebook_points());
        (!out.is_empty()).then_some(out)
    }

    fn named(&self, name: &str) -> Vec<UserPoint> {
        self.inner.named(name)
    }

    fn note(&self, kind: &str) -> Option<(&'static str, &'static str)> {
        self.inner.note(kind)
    }
}
