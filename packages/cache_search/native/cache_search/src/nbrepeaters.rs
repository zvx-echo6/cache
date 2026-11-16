//! Repeater lists as notebooks (`cs_notebook` ops `repeaters_import` and `repeaters_add_back`, and the conversion of the lists the
//! older versions kept in user.sqlite).
//!
//! A repeater list is a notebook of the `repeaters` template: one entry per repeater (the callsign is its title, the position its
//! place) and seven fixed text fields holding the core's own words for the settings, exactly what `cs_userlayer_get` and the
//! assistant's `nearby` gave for a list row. "Update from a file" is cache_notebook's `source_merge` (a three-way merge that keeps
//! what the person changed); this module reads the files, makes the rows and keys, and matches entries made by hand.
//!
//! One rule matches every import (the owner's decision): a row whose NAME is the name of an entry of the notebook updates that entry,
//! any other row is added. A row's key is therefore its name (the callsign), trimmed, case-folded and with spaces collapsed. A name
//! twice in one file is one row, the later one's. Of several entries with the same name the one the notebook's ledger last linked
//! to it is updated, else the oldest: never a second. (The conversion of the older store's lists, one entry per old row, still keys
//! its rows by callsign, frequency and town, [`keys_of`]; the next import makes them names, `source_rekey_by_title`.)
//!
//! The assistant's `nearby` reads these notebooks through [`NotebookRepeaters`], with the same keys and the same words.

use crate::error::{Error, ErrorCode, Result};
use crate::ext::Ext;
use cache_tool::user::{UserCategory, UserPoint, UserPoints};
use cache_user::mapdata::repeater::{frequency_text, Repeater};
use cache_user::mapdata::{self, LegacyRepeaterList, MapStore};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::sync::Arc;

/// The template id of a repeater list's notebook.
pub const TEMPLATE: &str = "repeaters";

/// The template ref of a notebook made here (as the app writes it for a built-in template), which notebook sync puts in every entry
/// file so another phone makes the notebook with the template's fields.
pub const TEMPLATE_REF: &str = "templates/repeaters@1";

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

/// The key of a repeater row in an import: its name (callsign), trimmed, case-folded, spaces collapsed; a repeater with no name
/// is keyed by its frequency and town.
fn name_key_of(r: &Repeater) -> String {
    let n = norm(&r.name);
    if n.is_empty() { base_key("", r.freq_hz, r.town.as_deref()) } else { n }
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
fn row(r: &Repeater, key: &str, fid: &HashMap<String, String>, source: String, have: Option<&Map<String, Value>>) -> Value {
    let mut values = Map::new();
    let mut put = |label: &str, v: Value| {
        if let Some(f) = fid.get(&label.to_lowercase()) {
            values.insert(f.clone(), v);
        }
    };
    put("Frequency", json!(frequency_text(r.freq_hz)));
    // A partial value never replaces a fuller one: a KML gives only the offset's sign and a tone without its use, so where the
    // entry already has the amount (or the use) the field is left out of the row and the entry keeps what it has.
    let kept = |label: &str, partial: bool, full: fn(&str) -> bool| -> bool {
        partial && have.zip(fid.get(&label.to_lowercase())).and_then(|(h, f)| text(h.get(f)?)).is_some_and(full)
    };
    if !kept("Offset", r.offset_is_partial(), offset_is_full) {
        put("Offset", json!(r.offset_text()));
    }
    if !kept("Tone", r.tone_is_partial(), tone_is_full) {
        put("Tone", json!(r.tone_text()));
    }
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

/// An entry's offset that states what the list's own words state in full: a signed amount ("-600 kHz") or a split's transmit
/// frequency, as `offset_text` writes them (or typed the same way).
fn offset_is_full(t: &str) -> bool {
    let t = t.trim();
    t.strip_prefix(['+', '-']).is_some_and(|r| r.trim_start().starts_with(|c: char| c.is_ascii_digit())) || t.starts_with("split: transmit")
}

/// An entry's tone that says how it is used, as `tone_text` writes it.
fn tone_is_full(t: &str) -> bool {
    let t = t.trim();
    t.ends_with("to transmit") || t.ends_with("to transmit and receive") || t.starts_with("DCS ")
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

    pub(crate) fn entries_of(&self, notebook_id: &str) -> Result<Vec<Value>> {
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
        let keys: Vec<String> = reps.iter().map(name_key_of).collect();
        let (nb_arg, fid, claims) = match args.get("notebook_id").and_then(Value::as_str) {
            Some(id) => {
                let n = self.nbr_call("notebook", &json!({"id": id}))?;
                if n["template"] != TEMPLATE {
                    return Err(Error::bad_json("repeaters are updated in a Repeaters notebook"));
                }
                let fid = fids(Some(&n["def"]));
                // ledgers made before imports matched by name are keyed by something else: the names take their place
                self.nbr_call("source_rekey_by_title", &json!({"notebook_id": id}))?;
                let claims = self.claims(id, &keys)?;
                (json!({"notebook_id": id}), fid, claims)
            }
            None => {
                let given = args.get("name").and_then(Value::as_str).map(mapdata::collapse).filter(|n| !n.is_empty());
                let name = match given {
                    Some(n) => n,
                    None => self.free_repeaters_name(&parsed.first_file)?,
                };
                (json!({"notebook": {"template": TEMPLATE, "def": def(&name), "map": true, "template_ref": TEMPLATE_REF}}), fids(None), Value::Null)
            }
        };
        // a name twice in the file is one row: the later one's (last wins), at the place of the first
        let have = match args.get("notebook_id").and_then(Value::as_str) {
            Some(id) => self.current_values(id, &claims)?,
            None => HashMap::new(),
        };
        let mut rows: Vec<Value> = Vec::with_capacity(reps.len());
        let mut at: HashMap<&str, usize> = HashMap::new();
        for (r, k) in reps.iter().zip(&keys) {
            let v = row(r, k, &fid, serde_json::to_string(r).unwrap_or_default(), have.get(k.as_str()));
            match at.get(k.as_str()) {
                Some(&i) => rows[i] = v,
                None => {
                    at.insert(k.as_str(), rows.len());
                    rows.push(v);
                }
            }
        }
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

    /// The values of the entry each row key will update: the one its ledger row is tied to, else the one `claims` gives.
    fn current_values(&self, notebook_id: &str, claims: &Value) -> Result<HashMap<String, Map<String, Value>>> {
        let ledger = self.nbr_call("source_rows", &json!({"notebook_id": notebook_id, "brief": true}))?;
        let mut target: HashMap<String, String> = HashMap::new();
        for r in ledger["rows"].as_array().into_iter().flatten() {
            if let (Some(k), Some(e)) = (r["key"].as_str(), r["entry_id"].as_str()) {
                target.insert(k.to_string(), e.to_string());
            }
        }
        for (k, e) in claims.as_object().into_iter().flatten() {
            if let Some(e) = e.as_str() {
                target.entry(k.clone()).or_insert_with(|| e.to_string());
            }
        }
        let by_id: HashMap<String, Map<String, Value>> = self
            .entries_of(notebook_id)?
            .iter()
            .filter_map(|e| Some((e["id"].as_str()?.to_string(), e["values"].as_object()?.clone())))
            .collect();
        Ok(target.into_iter().filter_map(|(k, e)| Some((k, by_id.get(&e)?.clone()))).collect())
    }

    /// For each row key (a name) of the new file, the entry of this notebook that has no ledger row and has that name (trimmed,
    /// case-folded, spaces collapsed): the oldest of them when several do. What `source_merge` may fill the blanks of.
    fn claims(&self, notebook_id: &str, keys: &[String]) -> Result<Value> {
        let ledger = self.nbr_call("source_rows", &json!({"notebook_id": notebook_id, "brief": true}))?;
        let tied: Vec<&str> = ledger["rows"].as_array().into_iter().flatten().filter_map(|r| r["entry_id"].as_str()).collect();
        let mut by_name: HashMap<String, String> = HashMap::new();
        let entries = self.entries_of(notebook_id)?;
        let mut ordered: Vec<&Value> = entries.iter().filter(|e| e["draft"] != true).collect();
        ordered.sort_by_key(|e| e["created"].as_i64().unwrap_or(0));
        for e in ordered {
            let Some(id) = e["id"].as_str() else { continue };
            if tied.contains(&id) {
                continue;
            }
            let Some(title) = e["title"].as_str().map(norm).filter(|t| !t.is_empty()) else { continue };
            by_name.entry(title).or_insert_with(|| id.to_string());
        }
        let mut claims = Map::new();
        for k in keys {
            if let Some(id) = by_name.get(k) {
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
            let found = self.nbr_call("source_migrated", &json!({"from": l.id}))?;
            let existing = match found["notebook_id"].as_str() {
                Some(id) => Some(self.nbr_call("notebook", &json!({"id": id}))?),
                None => None,
            };
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
                    let rows: Vec<Value> = reps.iter().zip(&keys).zip(&l.rows).map(|((r, k), (_, raw))| row(r, k, &fid, raw.clone(), None)).collect();
                    let a = json!({
                        "notebook": {"template": TEMPLATE, "def": def(&name), "map": l.visible, "template_ref": TEMPLATE_REF},
                        "migrated_from": l.id, "now": iso_now(), "rows": rows,
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
            let want = row(r, key, &fid, String::new(), None);
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
        let unfinished: Vec<String> = self.inner.legacy_repeater_lists().map(|l| l.into_iter().map(|x| x.id).collect()).unwrap_or_default();
        let mut out = Vec::new();
        for b in books.into_iter().filter(|b| !b["migrated"].as_array().into_iter().flatten().filter_map(Value::as_str).any(|m| unfinished.iter().any(|u| u == m))) {
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
