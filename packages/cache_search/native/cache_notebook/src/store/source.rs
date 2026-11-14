//! A notebook kept in step with a file the person can load again ("Update from a file"), without ever wiping what they did to it.
//!
//! Each row of the file has a `key` (its identity across files; the caller decides what it is made of). The `source_rows` table is
//! this device's ledger of the last file: per notebook and key, the entry made for it, the row as the file gave it (`source`, kept
//! as given so nothing the file held is lost), the content imported (`base`: title, place, values) and a state. `source_merge`
//! compares three things per field: what the entry holds now, what the last file gave (base), what the new file gives.
//!
//! - now equals base: the person did not touch it, so it follows the file;
//! - now differs from base: a hand edit, which stays;
//! - no ledger row (an entry made by hand, or one that came from another device) but the caller matched it to the row by its
//!   fields (`claims`): only a blank is filled, nothing is overwritten;
//! - a file row with no entry and no claim is added;
//! - a file row whose entry the person deleted stays deleted (state `deleted`, listed in the answer; `source_add_back` makes them);
//! - a ledger row the new file lacks keeps its entry, marked `gone` ("Not in the latest file").
//!
//! Everything, the notebook made for a first import included, is one transaction. Notes, photos, files, Private, an entry's app
//! properties and its date are never touched. A file that changes nothing writes nothing (no revision goes up).
//! The ledger is never synced: another device sees an ordinary notebook.

use super::*;
use std::collections::{HashMap, HashSet};

const MAX_KEY: usize = 400;
const MAX_SOURCE: usize = 100_000;

/// What a file row put into an entry: its title, position and field values.
#[derive(Clone, Debug, PartialEq, Default)]
struct Base {
    title: Option<String>,
    place: Option<(f64, f64)>,
    values: Map<String, Value>,
}

impl Base {
    fn to_json(&self) -> Value {
        json!({
            "title": self.title,
            "place": self.place.map(|(lat, lon)| json!({"lat": lat, "lon": lon})),
            "values": self.values,
        })
    }

    fn from_json(v: &Value) -> Base {
        Base {
            title: v.get("title").and_then(Value::as_str).map(str::to_string),
            place: v.get("place").and_then(|p| Some((p.get("lat")?.as_f64()?, p.get("lon")?.as_f64()?))),
            values: v.get("values").and_then(Value::as_object).cloned().unwrap_or_default(),
        }
    }
}

struct Row {
    key: String,
    base: Base,
    source: String,
}

struct Led {
    entry_id: Option<String>,
    source: String,
    base: Base,
    state: String,
}

fn parse_rows(def: &NotebookDef, v: Option<&Value>) -> Result<Vec<Row>> {
    let arr = v.and_then(Value::as_array).ok_or_else(|| Error::bad("rows must be a list"))?;
    let mut seen = HashSet::new();
    let mut out = Vec::with_capacity(arr.len());
    for r in arr {
        check_keys(r, &["key", "title", "place", "values", "source"])?;
        let key = str_arg(r, "key")?.to_string();
        if key.is_empty() || key.chars().count() > MAX_KEY {
            return Err(Error::bad(format!("a row's key is 1 to {MAX_KEY} characters")));
        }
        if !seen.insert(key.clone()) {
            return Err(Error::bad(format!("two rows have the key {key:?}")));
        }
        let place = Place::parse(r.get("place").unwrap_or(&Value::Null), "place")?.map(|p| (p.lat, p.lon));
        let values = check_values(def, r.get("values").unwrap_or(&Value::Null))?;
        let source = r.get("source").and_then(Value::as_str).unwrap_or("").to_string();
        if source.len() > MAX_SOURCE {
            return Err(Error::bad("a row's source is too long"));
        }
        out.push(Row { key, base: Base { title: opt_text(r, "title", MAX_TITLE)?, place, values }, source });
    }
    Ok(out)
}

fn ledger(c: &Connection, nb: &str) -> Result<Vec<(String, Led)>> {
    let mut st = c.prepare("SELECT key, entry_id, source, base, state FROM source_rows WHERE notebook_id=?1 ORDER BY rowid")?;
    let rows = st
        .query_map([nb], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?, r.get::<_, String>(4)?)))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    Ok(rows
        .into_iter()
        .map(|(key, entry_id, source, base, state)| {
            let base = serde_json::from_str::<Value>(&base).map(|v| Base::from_json(&v)).unwrap_or_default();
            (key, Led { entry_id, source, base, state })
        })
        .collect())
}

fn upsert(c: &Connection, nb: &str, key: &str, entry: Option<&str>, source: &str, base: &Base, state: &str) -> Result<()> {
    c.execute(
        "INSERT OR REPLACE INTO source_rows(notebook_id, key, entry_id, source, base, state) VALUES(?1,?2,?3,?4,?5,?6)",
        params![nb, key, entry, source, base.to_json().to_string(), state],
    )?;
    Ok(())
}

fn alive(c: &Connection, nb: &str, entry: Option<&str>) -> Result<bool> {
    match entry {
        Some(e) => Ok(c.query_row("SELECT EXISTS(SELECT 1 FROM entries WHERE id=?1 AND notebook_id=?2)", params![e, nb], |r| r.get(0))?),
        None => Ok(false),
    }
}

/// A value as the comparison sees it: numbers by value, the rest as they are.
fn veq(a: &Option<Value>, b: &Option<Value>) -> bool {
    match (a, b) {
        (Some(x), Some(y)) => match (x.as_f64(), y.as_f64()) {
            (Some(p), Some(q)) if x.is_number() && y.is_number() => p == q,
            _ => x == y,
        },
        (None, None) => true,
        _ => false,
    }
}

/// What one field becomes: the file's value when the person did not touch it, else what the person has. The bool says a hand edit
/// was kept (the file differs from it).
fn pick<T: Clone>(cur: &Option<T>, base: Option<&Option<T>>, new: &Option<T>, eq: &dyn Fn(&Option<T>, &Option<T>) -> bool) -> (Option<T>, bool) {
    if eq(cur, new) {
        return (cur.clone(), false);
    }
    match base {
        Some(b) if eq(cur, b) => (new.clone(), false),
        Some(_) => (cur.clone(), true),
        None if cur.is_none() => (new.clone(), false),
        None => (cur.clone(), true),
    }
}

/// Brings entry `id` in step with `new`. Returns (changed, kept an edit).
fn merge_entry(tx: &Connection, id: &str, base: Option<&Base>, new: &Base) -> Result<(bool, bool)> {
    let cur = entry_json(tx, id)?.ok_or_else(|| Error::not_found(format!("no entry with id {id:?}")))?;
    let cur_title = cur.get("title").and_then(Value::as_str).map(str::to_string);
    let cur_place = cur.get("place").and_then(|p| Some((p.get("lat")?.as_f64()?, p.get("lon")?.as_f64()?)));
    let cur_values = cur.get("values").and_then(Value::as_object).cloned().unwrap_or_default();
    let mut changed = false;
    let mut kept = false;
    let (title, k) = pick(&cur_title, base.map(|b| &b.title), &new.title, &|a, b| a == b);
    changed |= title != cur_title;
    kept |= k;
    let (place, k) = pick(&cur_place, base.map(|b| &b.place), &new.place, &|a, b| a == b);
    changed |= place != cur_place;
    kept |= k;
    let mut values = Map::new();
    let mut fids: Vec<&String> = cur_values.keys().chain(new.values.keys()).chain(base.into_iter().flat_map(|b| b.values.keys())).collect();
    fids.sort();
    fids.dedup();
    for fid in fids {
        let (cv, nv) = (cur_values.get(fid).cloned(), new.values.get(fid).cloned());
        let bv = base.map(|b| b.values.get(fid).cloned());
        let (v, k) = pick(&cv, bv.as_ref(), &nv, &veq);
        if !veq(&v, &cv) {
            changed = true;
        }
        kept |= k;
        if let Some(v) = v {
            values.insert(fid.clone(), v);
        }
    }
    if changed {
        let mut args = Map::new();
        for k in ["id", "notebook_id", "occurred_at", "body", "photos", "files", "draft", "private", "props"] {
            if let Some(v) = cur.get(k) {
                args.insert(k.into(), v.clone());
            }
        }
        args.insert("title".into(), json!(title));
        args.insert("place".into(), place.map(|(lat, lon)| json!({"lat": lat, "lon": lon})).unwrap_or(Value::Null));
        args.insert("values".into(), Value::Object(values));
        // The place keeps its name and saved-place key when the position did not move.
        if place == cur_place {
            if let Some(p) = cur.get("place") {
                args.insert("place".into(), p.clone());
            }
        }
        entry_save_in(tx, &Value::Object(args))?;
    }
    Ok((changed, kept))
}

fn make_entry(tx: &Connection, nb: &str, now: &str, base: &Base) -> Result<String> {
    let mut args = Map::new();
    args.insert("notebook_id".into(), json!(nb));
    args.insert("occurred_at".into(), json!(now));
    args.insert("values".into(), Value::Object(base.values.clone()));
    if let Some(t) = &base.title {
        args.insert("title".into(), json!(t));
    }
    if let Some((lat, lon)) = base.place {
        args.insert("place".into(), json!({"lat": lat, "lon": lon}));
    }
    let (e, _) = entry_save_in(tx, &Value::Object(args))?;
    Ok(e["id"].as_str().unwrap_or_default().to_string())
}

/// `source_merge`: `{"notebook_id" | "notebook": {notebook_save args}, "now", "rows": [{"key","title"?,"place"?,"values"?,"source"?}],
/// "claims"?: {key: entry id}, "migrated_from"?: text}`. See the module doc. Answers `{"notebook","added","updated","unchanged","kept_edits","not_in_file",
/// "deleted": [{"key","title"}]}`.
pub(crate) fn source_merge(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &["notebook_id", "notebook", "now", "rows", "claims", "migrated_from"])?;
    let now = str_arg(args, "now")?;
    parse_when(now)?;
    let tx = c.transaction()?;
    let nb_id = match (args.get("notebook_id").filter(|v| !v.is_null()), args.get("notebook").filter(|v| !v.is_null())) {
        (Some(Value::String(id)), None) => {
            if load_notebook(&tx, id)?.is_none() {
                return Err(Error::not_found(format!("no notebook with id {id:?}")));
            }
            id.clone()
        }
        (None, Some(n)) => notebook_save_in(&tx, n)?["id"].as_str().unwrap_or_default().to_string(),
        _ => return Err(Error::bad("source_merge needs notebook_id or notebook, one of them")),
    };
    if let Some(from) = opt_text(args, "migrated_from", 100)? {
        // Where this notebook came from (an older store's list id), kept in the same transaction as the notebook: the next start
        // finds it by this and does not make it twice.
        tx.execute("INSERT OR REPLACE INTO meta(key, value) VALUES(?1, ?2)", params![format!("migrated:{from}"), nb_id])?;
    }
    let nb = load_notebook(&tx, &nb_id)?.expect("found or made above");
    let rows = parse_rows(&nb.def, args.get("rows"))?;
    let claims: HashMap<String, String> = match args.get("claims") {
        None | Some(Value::Null) => HashMap::new(),
        Some(Value::Object(o)) => o.iter().filter_map(|(k, v)| v.as_str().map(|e| (k.clone(), e.to_string()))).collect(),
        Some(_) => return Err(Error::bad("claims must be an object of key to entry id")),
    };
    let led = ledger(&tx, &nb_id)?;
    let led_by_key: HashMap<&str, &Led> = led.iter().map(|(k, l)| (k.as_str(), l)).collect();
    let mut tied: HashSet<String> = led.iter().filter_map(|(_, l)| l.entry_id.clone()).collect();
    let (mut added, mut updated, mut unchanged, mut kept_edits) = (0, 0, 0, 0);
    let mut deleted: Vec<Value> = Vec::new();
    for row in &rows {
        match led_by_key.get(row.key.as_str()) {
            Some(l) if alive(&tx, &nb_id, l.entry_id.as_deref())? => {
                let eid = l.entry_id.as_deref().expect("alive");
                let (changed, kept) = merge_entry(&tx, eid, Some(&l.base), &row.base)?;
                if changed {
                    updated += 1;
                } else {
                    unchanged += 1;
                }
                kept_edits += usize::from(kept);
                upsert(&tx, &nb_id, &row.key, Some(eid), &row.source, &row.base, "ok")?;
            }
            Some(l) => {
                deleted.push(json!({"key": row.key, "title": row.base.title}));
                upsert(&tx, &nb_id, &row.key, l.entry_id.as_deref(), &row.source, &row.base, "deleted")?;
            }
            None => {
                let claimed = match claims.get(&row.key) {
                    Some(e) if !tied.contains(e) && alive(&tx, &nb_id, Some(e.as_str()))? => Some(e.clone()),
                    _ => None,
                };
                let eid = match claimed {
                    Some(e) => {
                        let (changed, kept) = merge_entry(&tx, &e, None, &row.base)?;
                        if changed {
                            updated += 1;
                        } else {
                            unchanged += 1;
                        }
                        kept_edits += usize::from(kept);
                        e
                    }
                    None => {
                        added += 1;
                        make_entry(&tx, &nb_id, now, &row.base)?
                    }
                };
                tied.insert(eid.clone());
                upsert(&tx, &nb_id, &row.key, Some(&eid), &row.source, &row.base, "ok")?;
            }
        }
    }
    let in_file: HashSet<&str> = rows.iter().map(|r| r.key.as_str()).collect();
    let mut not_in_file = 0;
    for (key, l) in &led {
        if in_file.contains(key.as_str()) {
            continue;
        }
        if alive(&tx, &nb_id, l.entry_id.as_deref())? {
            not_in_file += 1;
            if l.state != "gone" {
                tx.execute("UPDATE source_rows SET state='gone' WHERE notebook_id=?1 AND key=?2", params![nb_id, key])?;
            }
        } else {
            tx.execute("DELETE FROM source_rows WHERE notebook_id=?1 AND key=?2", params![nb_id, key])?;
        }
    }
    let n = load_notebook(&tx, &nb_id)?.expect("still there");
    let out = json!({
        "notebook": notebook_json(&tx, &n)?, "added": added, "updated": updated, "unchanged": unchanged, "kept_edits": kept_edits,
        "not_in_file": not_in_file, "deleted": deleted,
    });
    tx.commit()?;
    Ok(out)
}

/// `source_add_back`: `{"notebook_id","now"}`. Makes the entries of the rows the person deleted, from what the file gave. `{"added":n}`.
pub(crate) fn source_add_back(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &["notebook_id", "now"])?;
    let nb_id = str_arg(args, "notebook_id")?;
    let now = str_arg(args, "now")?;
    parse_when(now)?;
    let tx = c.transaction()?;
    if load_notebook(&tx, nb_id)?.is_none() {
        return Err(Error::not_found(format!("no notebook with id {nb_id:?}")));
    }
    let mut added = 0;
    for (key, l) in ledger(&tx, nb_id)? {
        if l.state != "deleted" || alive(&tx, nb_id, l.entry_id.as_deref())? {
            continue;
        }
        let eid = make_entry(&tx, nb_id, now, &l.base)?;
        upsert(&tx, nb_id, &key, Some(&eid), &l.source, &l.base, "ok")?;
        added += 1;
    }
    tx.commit()?;
    Ok(json!({"added": added}))
}

/// `source_rows`: `{"notebook_id","brief"?}`. The ledger: `{"rows":[{"key","entry_id","state","source"?,"base"?}]}` (brief leaves the
/// source and base out).
pub(crate) fn source_rows(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &["notebook_id", "brief"])?;
    let nb_id = str_arg(args, "notebook_id")?;
    let brief = opt_bool(args, "brief")?.unwrap_or(false);
    let rows: Vec<Value> = ledger(c, nb_id)?
        .into_iter()
        .map(|(key, l)| {
            let mut m = Map::new();
            m.insert("key".into(), json!(key));
            m.insert("entry_id".into(), json!(l.entry_id));
            m.insert("state".into(), json!(l.state));
            if !brief {
                m.insert("source".into(), json!(l.source));
                m.insert("base".into(), l.base.to_json());
            }
            Value::Object(m)
        })
        .collect();
    Ok(json!({"rows": rows}))
}

/// `source_migrated`: `{"from"}`. The notebook a `source_merge` made with `migrated_from` = `from`, if it is still there:
/// `{"notebook_id": "<id>" | null}`.
pub(crate) fn source_migrated(c: &mut Connection, args: &Value) -> Result<Value> {
    check_keys(args, &["from"])?;
    let from = str_arg(args, "from")?;
    let id: Option<String> = c.query_row("SELECT value FROM meta WHERE key=?1", [format!("migrated:{from}")], |r| r.get(0)).optional()?;
    let id = match id {
        Some(id) if load_notebook(c, &id)?.is_some() => Some(id),
        _ => None,
    };
    Ok(json!({"notebook_id": id}))
}
