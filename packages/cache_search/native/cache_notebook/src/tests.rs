use super::*;
use serde_json::{json, Value};

struct Tmp(PathBuf);
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn cfg(dir: &std::path::Path) -> NotebookCfg {
    NotebookCfg { db_path: dir.join("notebook.sqlite").to_string_lossy().into_owned(), media_dir: dir.to_string_lossy().into_owned() }
}

fn notebook(name: &str) -> (Notebook, Tmp) {
    let dir = std::env::temp_dir().join(format!("cache-notebook-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    (Notebook::new(cfg(&dir)), Tmp(dir))
}

fn call(nb: &Notebook, op: &str, args: Value) -> Value {
    serde_json::from_str(&nb.call(op, Some(&args.to_string())).unwrap_or_else(|e| panic!("{op}: {}", e.message))).unwrap()
}

fn err(nb: &Notebook, op: &str, args: Value) -> Error {
    nb.call(op, Some(&args.to_string())).expect_err(op)
}

const STARTERS: &str = include_str!("../../../../../app/assets/notebook/starters.json");
const TEMPLATES: &str = include_str!("../../../../../app/assets/notebook/templates.json");

fn generator() -> Value {
    json!({"name": "Generator test", "due_every": "month", "shape": {"sort": "recent", "quick_add": true}, "fields": [
        {"label": "Run time", "type": "number", "unit": "min"},
        {"label": "Under load", "type": "yes_no"},
        {"label": "Fuel level", "type": "choice", "choices": ["Full", "Half", "Low"]}]})
}

fn new_log(nb: &Notebook, def: Value) -> String {
    call(nb, "notebook_save", json!({"template": "log", "def": def}))["id"].as_str().unwrap().to_string()
}

fn journal_id(nb: &Notebook) -> String {
    let all = call(nb, "notebooks", json!({}));
    all["notebooks"].as_array().unwrap().iter().find(|n| n["template"] == "journal").unwrap()["id"].as_str().unwrap().to_string()
}

fn names(nb: &Notebook) -> Vec<String> {
    call(nb, "notebooks", json!({}))["notebooks"].as_array().unwrap().iter().map(|l| l["def"]["name"].as_str().unwrap().to_string()).collect()
}

fn add(nb: &Notebook, notebook: &str, when: &str, values: Value) -> Value {
    call(nb, "entry_save", json!({"notebook_id": notebook, "occurred_at": when, "values": values}))
}

#[test]
fn a_journal_exists_by_default_and_stays_deleted() {
    let (nb, t) = notebook("journal-default");
    let all = call(&nb, "notebooks", json!({}));
    let list = all["notebooks"].as_array().unwrap();
    assert_eq!(list.len(), 1);
    assert_eq!(list[0]["template"], "journal");
    assert_eq!(list[0]["def"], json!({"name": "Journal", "due_every": null, "fields": []}));
    assert_eq!(list[0]["map"], true);
    let keys: Vec<&String> = list[0].as_object().unwrap().keys().collect();
    assert_eq!(keys, ["id", "template", "def", "private", "map", "template_ref", "created", "updated", "last_used", "rev", "entries", "files", "places", "last_entry"]);
    let id = list[0]["id"].as_str().unwrap();
    call(&nb, "notebook_delete", json!({"id": id}));
    drop(nb);
    assert!(names(&Notebook::new(cfg(&t.0))).is_empty());
}

#[test]
fn every_template_and_starter_makes_a_notebook() {
    let (nb, _t) = notebook("starters");
    let doc: Value = serde_json::from_str(STARTERS).unwrap();
    assert_eq!(doc["format"], "cache-log-templates");
    let starters = doc["templates"].as_array().unwrap();
    assert_eq!(starters.len(), 16);
    let mut groups: Vec<&str> = starters.iter().map(|t| t["group"].as_str().unwrap()).collect();
    groups.dedup();
    assert_eq!(groups, ["Home", "Vehicles", "Health", "Outdoors", "Preparedness"]);
    for t in starters {
        let id = t["id"].as_str().unwrap();
        let l = call(&nb, "notebook_save", json!({"template": "log", "def": t, "private": t["private"], "template_ref": format!("starters/{id}@1")}));
        assert_eq!(l["def"]["name"], t["name"]);
        assert_eq!(l["def"]["id"], t["id"]);
        assert_eq!(l["private"], t["private"]);
        assert_eq!(l["entries"], 0);
        let fids: Vec<&str> = l["def"]["fields"].as_array().unwrap().iter().map(|f| f["fid"].as_str().unwrap()).collect();
        let want: Vec<String> = (1..=fids.len()).map(|i| format!("f{i}")).collect();
        assert_eq!(fids, want);
    }
    // the notebook templates are data the store takes like any definition
    let doc: Value = serde_json::from_str(TEMPLATES).unwrap();
    for t in doc["templates"].as_array().unwrap() {
        let mut def = t.clone();
        def["name"] = json!(format!("My {}", t["name"].as_str().unwrap()));
        let n = call(&nb, "notebook_save", json!({"template": t["id"], "def": def}));
        assert_eq!(n["def"]["shape"], t["shape"]);
    }
    assert_eq!(names(&nb).len(), 17 + doc["templates"].as_array().unwrap().len());
}

#[test]
fn definitions_are_checked() {
    let (nb, _t) = notebook("defs");
    let bad = [
        json!({"name": " ", "fields": []}),
        json!({"name": "x", "fields": [{"label": "a", "type": "date"}]}),
        json!({"name": "x", "fields": [{"label": "a", "type": "choice"}]}),
        json!({"name": "x", "fields": [{"label": "a", "type": "choice", "choices": ["A", "A"]}]}),
        json!({"name": "x", "fields": [{"label": "a", "type": "text", "unit": "min"}]}),
        json!({"name": "x", "fields": [{"label": "a", "type": "text"}, {"label": "A", "type": "number"}]}),
        json!({"name": "x", "due_every": "fortnight", "fields": []}),
        json!({"name": "x", "due_every": "1 days", "fields": []}),
        json!({"name": "x", "shape": {"sort": "size"}, "fields": []}),
        json!({"name": "x", "shape": {"colour": "red"}, "fields": []}),
        json!({"name": "x", "fields": (0..13).map(|i| json!({"label": format!("f{i}"), "type": "text"})).collect::<Vec<_>>()}),
    ];
    for d in bad {
        assert_eq!(err(&nb, "notebook_save", json!({"template": "log", "def": d})).code, "bad_json", "{d}");
    }
    for ok in ["day", "week", "month", "year", "3 months", "6 months", "10 days", "2 years"] {
        assert!(validate_due_every(ok), "{ok}");
    }
    assert_eq!(err(&nb, "notebook_save", json!({"def": generator()})).code, "bad_json"); // a new notebook needs its template
    assert_eq!(err(&nb, "notebook_save", json!({"template": "a/b", "def": generator()})).code, "bad_json");
    new_log(&nb, generator());
    let e = err(&nb, "notebook_save", json!({"template": "notes", "def": {"name": "generator  TEST", "fields": []}}));
    assert!(e.message.contains("already exists"), "{}", e.message);
    // switches: on the map by default; one left out keeps its value
    let n = call(&nb, "notebook_save", json!({"template": "notes", "def": {"name": "Family plan", "fields": []}, "private": true}));
    assert_eq!((n["map"].clone(), n["private"].clone()), (json!(true), json!(true)));
    let n = call(&nb, "notebook_save", json!({"id": n["id"], "def": {"name": "Family plan", "fields": []}, "map": false}));
    assert_eq!((n["map"].clone(), n["private"].clone(), n["template"].clone()), (json!(false), json!(true), json!("notes")));
}

#[test]
fn entries_last_entry_and_use_order() {
    let (nb, _t) = notebook("entries");
    let journal = journal_id(&nb);
    let gid = new_log(&nb, generator());
    let wid = new_log(&nb, json!({"name": "Water rotation", "fields": [{"label": "Containers", "type": "number", "unit": "jugs"}]}));
    assert_eq!(names(&nb), ["Water rotation", "Generator test", "Journal"]);
    add(&nb, &gid, "2026-09-28T10:05:00-06:00", json!({"f1": 15, "f2": false, "f3": "Half"}));
    let e = add(&nb, &gid, "2026-10-25T16:12:00-06:00", json!({"f1": 20, "f2": true, "f3": "Full"}));
    assert_eq!(e["values"], json!({"f1": 20, "f2": true, "f3": "Full"}));
    assert_eq!(e["rev"], 1);
    assert_eq!(names(&nb), ["Generator test", "Water rotation", "Journal"]);
    let l = call(&nb, "notebook", json!({"id": gid}));
    assert_eq!(l["entries"], 2);
    assert_eq!(l["last_entry"]["occurred_at"], "2026-10-25T16:12:00-06:00");
    let list = call(&nb, "entries", json!({"notebook_id": gid}))["entries"].as_array().unwrap().clone();
    assert_eq!(list.len(), 2);
    assert_eq!(list[0]["id"], e["id"]);
    let keys: Vec<&String> = e.as_object().unwrap().keys().collect();
    assert_eq!(keys, ["id", "notebook_id", "occurred_at", "values", "photos", "files", "draft", "private", "created", "updated", "rev"]);
    for bad in [json!({"f1": "twenty"}), json!({"f2": "yes"}), json!({"f9": 1})] {
        let e = nb.call("entry_save", Some(&json!({"notebook_id": gid, "occurred_at": "2026-10-25T16:12:00-06:00", "values": bad}).to_string()));
        assert_eq!(e.unwrap_err().code, "bad_json");
    }
    assert_eq!(err(&nb, "entry_save", json!({"notebook_id": journal, "occurred_at": "2026-10-25T16:12:00-06:00", "values": {"f1": 1}})).code, "bad_json");
    add(&nb, &wid, "2026-10-29T16:12:00-06:00", json!({"f1": 6}));
    assert_eq!(names(&nb)[0], "Water rotation");
}

#[test]
fn rename_keeps_values_and_types_lock_once_entries_exist() {
    let (nb, _t) = notebook("rename");
    let g = call(&nb, "notebook_save", json!({"template": "log", "def": generator()}));
    let gid = g["id"].as_str().unwrap();
    let mut def = g["def"].clone();
    def["fields"][2] = json!({"fid": "f3", "label": "Fuel", "type": "text"});
    let l = call(&nb, "notebook_save", json!({"id": gid, "def": def}));
    assert_eq!(l["def"]["fields"][2]["type"], "text");
    assert_eq!(l["def"]["shape"], json!({"sort": "recent", "quick_add": true}));
    add(&nb, gid, "2026-10-25T16:12:00-06:00", json!({"f1": 20, "f3": "full tank"}));
    let mut def = l["def"].clone();
    def["fields"][0]["label"] = json!("Minutes run");
    let l = call(&nb, "notebook_save", json!({"id": gid, "def": def.clone()}));
    assert_eq!(l["def"]["fields"][0], json!({"fid": "f1", "label": "Minutes run", "type": "number", "unit": "min"}));
    assert_eq!(l["last_entry"]["values"]["f1"], 20);
    def["fields"][0] = json!({"fid": "f1", "label": "Minutes run", "type": "text"});
    assert!(err(&nb, "notebook_save", json!({"id": gid, "def": def})).message.contains("can't change"));
    let def = json!({"name": "Generator test", "fields": [
        {"fid": "f1", "label": "Minutes run", "type": "number", "unit": "min"},
        {"label": "Oil", "type": "yes_no"}]});
    let l = call(&nb, "notebook_save", json!({"id": gid, "def": def}));
    let fields = l["def"]["fields"].as_array().unwrap();
    assert_eq!(fields.len(), 3);
    assert_eq!(fields[1], json!({"fid": "f4", "label": "Oil", "type": "yes_no"}));
    assert_eq!(fields[2], json!({"fid": "f3", "label": "Fuel", "type": "text", "hidden": true}));
    assert_eq!(l["last_entry"]["values"]["f3"], "full tank");
    let bad = json!({"name": "Generator test", "fields": [{"fid": "f9", "label": "x", "type": "text"}]});
    assert_eq!(err(&nb, "notebook_save", json!({"id": gid, "def": bad})).code, "bad_json");
}

#[test]
fn entries_drafts_places_search_and_pins() {
    let (nb, _t) = notebook("journal");
    let j = journal_id(&nb);
    let d = call(&nb, "entry_save", json!({"notebook_id": j, "occurred_at": "2026-10-27T16:12:00-06:00", "body": "Half written", "draft": true}));
    assert_eq!(d["draft"], true);
    let e = call(&nb, "entry_save", json!({"notebook_id": j, "occurred_at": "2026-10-27T16:30:00-06:00", "title": "Water cache restocked",
        "body": "Swapped six 5-gallon jugs at the shed.", "place": {"lat": 43.615, "lon": -116.202, "label": "Home", "key": "home"}}));
    let keys: Vec<&String> = e.as_object().unwrap().keys().collect();
    assert_eq!(keys, ["id", "notebook_id", "occurred_at", "title", "body", "values", "place", "photos", "files", "draft", "private", "created", "updated", "rev"]);
    assert_eq!(e["place"], json!({"lat": 43.615, "lon": -116.202, "label": "Home", "key": "home"}));
    assert_eq!(call(&nb, "entries", json!({"notebook_id": j}))["entries"][0]["id"], e["id"]);
    let hits = |q: &str| call(&nb, "search", json!({"query": q}))["hits"].as_array().unwrap().clone();
    assert!(hits("written").is_empty());
    let h = hits("jugs shed");
    assert_eq!(h.len(), 1);
    assert_eq!(h[0]["notebook"], "Journal");
    assert!(h[0]["snippet"].as_str().unwrap().contains("\u{2}jugs\u{3}"), "{}", h[0]["snippet"]);
    assert_eq!(hits("restock").len(), 1);
    assert_eq!(hits("\"wáter\" (").len(), 1);
    assert!(hits("  ").is_empty());
    let pins = |a: Value| call(&nb, "pins", a)["entries"].as_array().unwrap().len();
    assert_eq!(pins(json!({})), 1);
    let p = call(&nb, "notebook_save", json!({"template": "places", "def": {"name": "Caches", "fields": []}}));
    call(&nb, "entry_save", json!({"notebook_id": p["id"], "occurred_at": "2026-10-27T16:30:00-06:00", "title": "Cache 1", "place": {"lat": 43.6, "lon": -116.1}}));
    assert_eq!(pins(json!({})), 2);
    assert_eq!(call(&nb, "notebook", json!({"id": p["id"]}))["places"], 1);
    call(&nb, "notebook_save", json!({"id": j, "def": {"name": "Journal", "fields": []}, "map": false}));
    assert_eq!(pins(json!({})), 1);
    assert_eq!(pins(json!({"notebook_id": j})), 1);
    let done = call(&nb, "entry_save", json!({"id": d["id"], "notebook_id": j, "occurred_at": "2026-10-27T16:12:00-06:00", "body": "Fully written"}));
    assert_eq!(done["rev"], 2);
    assert_eq!(done["created"], d["created"]);
    assert_eq!(hits("written").len(), 1);
    assert!(call(&nb, "search", json!({"query": "written", "notebook_id": p["id"]}))["hits"].as_array().unwrap().is_empty());
    assert_eq!(err(&nb, "entry_save", json!({"notebook_id": j, "occurred_at": "yesterday"})).code, "bad_json");
    assert_eq!(err(&nb, "entry_save", json!({"notebook_id": "nope", "occurred_at": "2026-10-27T16:12:00Z"})).code, "not_found");
}

#[test]
fn entries_are_found_by_label_value_file_name_and_notebook_name() {
    let (nb, _t) = notebook("logsearch");
    let g = call(&nb, "notebook_save", json!({"template": "log", "def": generator()}));
    let gid = g["id"].as_str().unwrap();
    call(&nb, "entry_save", json!({"notebook_id": gid, "occurred_at": "2026-10-25T16:12:00-06:00",
        "values": {"f1": 20, "f2": true, "f3": "Full"}, "body": "Oil fine"}));
    let hits = |q: &str| call(&nb, "search", json!({"query": q}))["hits"].as_array().unwrap().clone();
    assert_eq!(hits("generator")[0]["notebook"], "Generator test");
    assert_eq!(hits("under load yes").len(), 1);
    assert_eq!(hits("20 min").len(), 1);
    let mut def = g["def"].clone();
    def["name"] = json!("Backup power");
    call(&nb, "notebook_save", json!({"id": gid, "def": def}));
    assert!(hits("generator").is_empty());
    assert_eq!(hits("backup")[0]["notebook"], "Backup power");
    let n = call(&nb, "notebook_save", json!({"template": "notes", "def": {"name": "Family plan", "fields": []}}));
    call(&nb, "entry_save", json!({"notebook_id": n["id"], "occurred_at": "2026-10-25T16:12:00-06:00", "title": "Medical info",
        "files": [{"id": "d1", "name": "Insurance card.pdf", "mime": "application/pdf", "bytes": 1200}]}));
    assert_eq!(hits("insurance")[0]["entry"]["files"], json!([{"id": "d1", "name": "Insurance card.pdf", "mime": "application/pdf", "bytes": 1200}]));
    assert_eq!(call(&nb, "notebook", json!({"id": n["id"]}))["files"], 1);
}

#[test]
fn private_is_a_flag() {
    let (nb, _t) = notebook("private");
    let m = call(&nb, "notebook_save", json!({"template": "log", "def": {"name": "Medication doses", "fields": [{"label": "Dose", "type": "number", "unit": "mg"}]}, "private": true}));
    let mid = m["id"].as_str().unwrap();
    let e = add(&nb, mid, "2026-10-25T08:00:00-06:00", json!({"f1": 200}));
    assert_eq!(e["private"], true);
    // private items are still searched (the flag only decides what sharing and sync leave out by default)
    assert_eq!(call(&nb, "search", json!({"query": "dose"}))["hits"].as_array().unwrap().len(), 1);
    call(&nb, "notebook_save", json!({"id": mid, "def": m["def"], "private": false}));
    assert_eq!(call(&nb, "entry", json!({"id": e["id"]}))["private"], false);
    let p = call(&nb, "entry_save", json!({"notebook_id": journal_id(&nb), "occurred_at": "2026-10-25T08:00:00-06:00", "body": "x", "private": true}));
    assert_eq!(p["private"], true);
}

#[test]
fn deleting_removes_entries_notebooks_photos_and_files() {
    let (nb, t) = notebook("delete");
    for d in ["photos", "thumbs", "files"] {
        std::fs::create_dir_all(t.0.join(d)).unwrap();
    }
    for id in ["p1", "p2", "p3"] {
        std::fs::write(t.0.join("photos").join(format!("{id}.jpg")), b"jpg").unwrap();
        std::fs::write(t.0.join("thumbs").join(format!("{id}.jpg")), b"jpg").unwrap();
    }
    std::fs::write(t.0.join("files/d1"), b"pdf").unwrap();
    let j = journal_id(&nb);
    let e = call(&nb, "entry_save", json!({"notebook_id": j, "occurred_at": "2026-10-27T16:12:00-06:00", "body": "with photos",
        "photos": [{"id": "p1", "width": 2048, "height": 1536, "bytes": 1000}, {"id": "p2"}], "files": [{"id": "d1", "name": "scan.pdf"}]}));
    assert_eq!(e["photos"], json!([{"id": "p1", "width": 2048, "height": 1536, "bytes": 1000}, {"id": "p2"}]));
    call(&nb, "entry_save", json!({"id": e["id"], "notebook_id": j, "occurred_at": "2026-10-27T16:12:00-06:00", "body": "with photos",
        "photos": [{"id": "p1"}], "files": [{"id": "d1", "name": "scan.pdf"}]}));
    assert!(!t.0.join("photos/p2.jpg").exists());
    assert!(!t.0.join("thumbs/p2.jpg").exists());
    assert!(t.0.join("photos/p1.jpg").exists());
    assert_eq!(err(&nb, "entry_save", json!({"notebook_id": j, "occurred_at": "2026-10-27T16:12:00-06:00", "files": [{"id": "d2"}]})).code, "bad_json");
    assert_eq!(call(&nb, "entry_delete", json!({"id": e["id"]})), json!({"deleted": e["id"]}));
    assert!(!t.0.join("photos/p1.jpg").exists());
    assert!(!t.0.join("files/d1").exists());
    assert_eq!(err(&nb, "entry", json!({"id": e["id"]})).code, "not_found");
    assert_eq!(err(&nb, "entry_delete", json!({"id": e["id"]})).code, "not_found");
    assert!(call(&nb, "search", json!({"query": "photos"}))["hits"].as_array().unwrap().is_empty());

    let lid = new_log(&nb, json!({"name": "Receipts", "fields": [{"label": "Receipt", "type": "photo"}, {"label": "Shop", "type": "text"}]}));
    add(&nb, &lid, "2026-10-27T16:12:00-06:00", json!({"f1": ["p3"], "f2": "Feed store"}));
    add(&nb, &lid, "2026-10-28T16:12:00-06:00", json!({"f2": "Hardware"}));
    assert_eq!(call(&nb, "notebook_delete", json!({"id": lid})), json!({"deleted": lid, "entries": 2}));
    assert!(!t.0.join("photos/p3.jpg").exists());
    assert_eq!(names(&nb), ["Journal"]);
    assert!(call(&nb, "search", json!({"query": "feed"}))["hits"].as_array().unwrap().is_empty());
    assert_eq!(err(&nb, "entries", json!({"notebook_id": lid})).code, "not_found");
}

#[test]
fn bad_calls() {
    let (nb, _t) = notebook("bad");
    assert_eq!(nb.call("nope", None).unwrap_err().code, "unsupported");
    assert_eq!(nb.call("notebooks", Some("[1]")).unwrap_err().code, "bad_json");
    assert_eq!(nb.call("notebooks", Some("{")).unwrap_err().code, "bad_json");
    assert_eq!(err(&nb, "notebooks", json!({"x": 1})).code, "bad_json");
    assert_eq!(err(&nb, "entries", json!({})).code, "bad_json");
    assert_eq!(err(&nb, "notebook_save", json!({"template": "log", "def": generator(), "id": "a/b"})).code, "bad_json");
    assert_eq!(nb.call("notebooks", Some("  ")).unwrap().matches("\"journal\"").count(), 1);
}

#[test]
fn a_newer_schema_is_refused() {
    let (nb, t) = notebook("schema");
    nb.call("notebooks", None).unwrap();
    drop(nb);
    let c = rusqlite::Connection::open(t.0.join("notebook.sqlite")).unwrap();
    c.execute("UPDATE meta SET value='99' WHERE key='schema_version'", []).unwrap();
    drop(c);
    assert_eq!(Notebook::new(cfg(&t.0)).call("notebooks", None).unwrap_err().code, "unsupported");
}

#[test]
fn props_mark_a_place_and_take_it_off_the_map() {
    let (nb, _t) = notebook("props");
    let p = call(&nb, "notebook_save", json!({"template": "places", "def": {"name": "Caches", "fields": []}}));
    let a = call(&nb, "entry_save", json!({"notebook_id": p["id"], "occurred_at": "2026-10-27T16:30:00-06:00", "title": "Cache 1",
        "place": {"lat": 43.6, "lon": -116.1}, "props": {"color": "teal", "on_map": true}}));
    assert_eq!(a["props"], json!({"color": "teal", "on_map": true}));
    let keys: Vec<&String> = a.as_object().unwrap().keys().collect();
    assert_eq!(keys, ["id", "notebook_id", "occurred_at", "title", "values", "place", "photos", "files", "props", "draft", "private", "created", "updated", "rev"]);
    let b = call(&nb, "entry_save", json!({"notebook_id": p["id"], "occurred_at": "2026-10-27T16:31:00-06:00", "title": "Cache 2",
        "place": {"lat": 43.7, "lon": -116.2}, "props": {"on_map": false}}));
    let pins = |a: Value| call(&nb, "pins", a)["entries"].as_array().unwrap().iter().map(|e| e["title"].as_str().unwrap().to_string()).collect::<Vec<_>>();
    assert_eq!(pins(json!({})), ["Cache 1"]);
    assert_eq!(pins(json!({"notebook_id": p["id"]})), ["Cache 1"]);
    // no props: shown, and no "props" key
    let c = call(&nb, "entry_save", json!({"id": b["id"], "notebook_id": p["id"], "occurred_at": "2026-10-27T16:31:00-06:00", "title": "Cache 2", "place": {"lat": 43.7, "lon": -116.2}}));
    assert!(c.get("props").is_none());
    assert_eq!(pins(json!({})).len(), 2);
    // a place's own icon
    let d = call(&nb, "entry_save", json!({"notebook_id": p["id"], "occurred_at": "2026-10-27T16:32:00-06:00", "title": "Cache 3",
        "place": {"lat": 43.8, "lon": -116.3}, "props": {"icon": "water_2", "color": "blue", "on_map": true}}));
    assert_eq!(d["props"], json!({"icon": "water_2", "color": "blue", "on_map": true}));
    for bad in [json!({"icon": "Water"}), json!({"icon": ""}), json!({"icon": 3}), json!({"icon": "a".repeat(41)})] {
        assert_eq!(err(&nb, "entry_save", json!({"notebook_id": p["id"], "occurred_at": "2026-10-27T16:32:00-06:00", "props": bad})).code, "bad_json");
    }
    for bad in [json!({"color": "Red!"}), json!({"on_map": "no"}), json!({"size": 3}), json!([1])] {
        assert_eq!(err(&nb, "entry_save", json!({"notebook_id": p["id"], "occurred_at": "2026-10-27T16:31:00-06:00", "props": bad})).code, "bad_json");
    }
}

#[test]
fn the_saved_places_notebook_is_made_once_and_kept() {
    let (nb, _t) = notebook("saved");
    call(&nb, "notebook_save", json!({"template": "places", "def": {"name": "Places", "fields": []}}));
    let s = call(&nb, "saved_places", json!({}));
    assert_eq!((s["def"]["name"].clone(), s["template"].clone(), s["saved_places"].clone(), s["map"].clone()), (json!("Saved places"), json!("places"), json!(true), json!(true)));
    assert_eq!(call(&nb, "saved_places", json!({}))["id"], s["id"]);
    assert_eq!(nb.saved_places_id().unwrap(), s["id"].as_str().unwrap());
    assert_eq!(err(&nb, "notebook_delete", json!({"id": s["id"]})).code, "bad_json");
    call(&nb, "entry_save", json!({"notebook_id": s["id"], "occurred_at": "2026-10-27T16:30:00-06:00", "title": "Home", "body": "Gate code",
        "place": {"lat": 43.6, "lon": -116.1, "key": "home"}}));
    call(&nb, "entry_save", json!({"notebook_id": s["id"], "occurred_at": "2026-10-27T16:30:00-06:00", "title": "Draft", "draft": true, "place": {"lat": 1, "lon": 2}}));
    let books = nb.places_books().unwrap();
    assert_eq!(books.len(), 2);
    let saved = books.iter().find(|b| b.saved).unwrap();
    assert_eq!(saved.points.len(), 1);
    assert_eq!((saved.points[0].title.as_deref(), saved.points[0].body.as_deref(), saved.points[0].key.as_deref()), (Some("Home"), Some("Gate code"), Some("home")));
    assert!(books.iter().any(|b| !b.saved && b.name == "Places" && b.points.is_empty()));
}

#[test]
fn a_version_1_database_gains_props() {
    let (nb, t) = notebook("v1");
    let j = journal_id(&nb);
    call(&nb, "entry_save", json!({"notebook_id": j, "occurred_at": "2026-10-27T16:30:00-06:00", "body": "kept"}));
    drop(nb);
    let c = rusqlite::Connection::open(t.0.join("notebook.sqlite")).unwrap();
    c.execute_batch("ALTER TABLE entries DROP COLUMN app_props; UPDATE meta SET value='1' WHERE key='schema_version';").unwrap();
    drop(c);
    let nb = Notebook::new(cfg(&t.0));
    let e = &call(&nb, "entries", json!({"notebook_id": j}))["entries"][0];
    assert_eq!(e["body"], "kept");
    call(&nb, "entry_save", json!({"id": e["id"], "notebook_id": j, "occurred_at": "2026-10-27T16:30:00-06:00", "body": "kept", "props": {"color": "blue"}}));
    drop(nb);
    let c = rusqlite::Connection::open(t.0.join("notebook.sqlite")).unwrap();
    let v: String = c.query_row("SELECT value FROM meta WHERE key='schema_version'", [], |r| r.get(0)).unwrap();
    assert_eq!(v, "2");
}

#[test]
fn a_notebook_has_an_icon_and_a_colour_of_its_own() {
    let (nb, _t) = notebook("icon_color");
    // neither: as before, and neither key comes back
    let a = call(&nb, "notebook_save", json!({"template": "places", "def": {"name": "Trail places", "fields": []}}));
    assert!(a["def"].get("icon").is_none() && a["def"].get("color").is_none());
    // both, kept and returned
    let b = call(&nb, "notebook_save", json!({"id": a["id"], "def": {"name": "Trail places", "icon": "trailhead", "color": "teal", "fields": []}}));
    assert_eq!((b["def"]["icon"].clone(), b["def"]["color"].clone()), (json!("trailhead"), json!("teal")));
    let again = call(&nb, "notebook", json!({"id": a["id"]}));
    assert_eq!((again["def"]["icon"].clone(), again["def"]["color"].clone()), (json!("trailhead"), json!("teal")));
    // taken off again
    let c = call(&nb, "notebook_save", json!({"id": a["id"], "def": {"name": "Trail places", "fields": []}}));
    assert!(c["def"].get("icon").is_none() && c["def"].get("color").is_none());
    for bad in [json!({"icon": "Trail head"}), json!({"icon": 5}), json!({"color": "Teal"}), json!({"color": "#3fbfae"}), json!({"color": ""})] {
        let mut def = json!({"name": "Trail places", "fields": []});
        def.as_object_mut().unwrap().extend(bad.as_object().unwrap().clone());
        assert_eq!(err(&nb, "notebook_save", json!({"id": a["id"], "def": def})).code, "bad_json", "{bad}");
    }
}

// ---- a notebook kept in step with a file (source_merge) ----

const NOW: &str = "2026-11-14T10:00:00-07:00";

fn list_def(name: &str) -> Value {
    json!({"name": name, "due_every": null, "shape": {"sort": "distance"}, "fields": [{"label": "Frequency", "type": "text"}, {"label": "Town", "type": "text"}]})
}

/// A row of a file: key, callsign, position and the two fields (f1 Frequency, f2 Town).
fn frow(key: &str, title: &str, lat: f64, freq: &str, town: &str) -> Value {
    json!({"key": key, "title": title, "place": {"lat": lat, "lon": -114.0}, "values": {"f1": freq, "f2": town}, "source": format!("raw {key}")})
}

fn first_file() -> Vec<Value> {
    vec![frow("a", "KX0AAA", 42.1, "146.940 MHz", "Burley"), frow("b", "KX0BBB", 42.2, "147.000 MHz", "Rupert"), frow("c", "KX0CCC", 42.3, "449.500 MHz", "Twin Falls")]
}

fn merge_new(nb: &Notebook, rows: Vec<Value>) -> Value {
    call(nb, "source_merge", json!({"notebook": {"template": "repeaters", "def": list_def("Repeaters"), "map": true}, "now": NOW, "rows": rows}))
}

fn merge_into(nb: &Notebook, id: &str, rows: Vec<Value>) -> Value {
    call(nb, "source_merge", json!({"notebook_id": id, "now": NOW, "rows": rows}))
}

fn entry_titled(nb: &Notebook, id: &str, title: &str) -> Value {
    call(nb, "entries", json!({"notebook_id": id}))["entries"].as_array().unwrap().iter().find(|e| e["title"] == title).unwrap_or_else(|| panic!("no entry {title}")).clone()
}

#[test]
fn a_first_file_makes_the_notebook_and_its_entries_in_one_step_or_none() {
    let (nb, _t) = notebook("src-first");
    let out = merge_new(&nb, first_file());
    assert_eq!((out["added"].as_i64(), out["updated"].as_i64()), (Some(3), Some(0)));
    let id = out["notebook"]["id"].as_str().unwrap().to_string();
    assert_eq!(out["notebook"]["template"], "repeaters");
    assert_eq!(out["notebook"]["entries"], 3);
    let e = entry_titled(&nb, &id, "KX0BBB");
    assert_eq!(e["values"], json!({"f1": "147.000 MHz", "f2": "Rupert"}));
    assert_eq!(e["place"]["lat"], 42.2);
    let led = call(&nb, "source_rows", json!({"notebook_id": id}));
    assert_eq!(led["rows"].as_array().unwrap().len(), 3);
    assert_eq!(led["rows"][1]["source"], "raw b", "the row as the file gave it is kept as it was");
    // a bad row anywhere: nothing is made, not even the notebook
    let before = names(&nb);
    let mut rows = first_file();
    rows.push(json!({"key": "d", "title": "X", "values": {"f9": "no such field"}}));
    let e = nb.call("source_merge", Some(&json!({"notebook": {"template": "repeaters", "def": list_def("Other"), "map": true}, "now": NOW, "rows": rows}).to_string())).expect_err("bad row");
    assert_eq!(e.code, "bad_json");
    assert_eq!(names(&nb), before);
    // two rows with one key are refused
    let dup = nb.call("source_merge", Some(&json!({"notebook_id": id, "now": NOW, "rows": [frow("a", "A", 1.0, "1", "x"), frow("a", "B", 1.0, "1", "x")]}).to_string()));
    assert_eq!(dup.expect_err("dup").code, "bad_json");
}

#[test]
fn the_same_file_again_changes_nothing_and_writes_nothing() {
    let (nb, _t) = notebook("src-again");
    let id = merge_new(&nb, first_file())["notebook"]["id"].as_str().unwrap().to_string();
    let revs: Vec<i64> = ["KX0AAA", "KX0BBB", "KX0CCC"].iter().map(|t| entry_titled(&nb, &id, t)["rev"].as_i64().unwrap()).collect();
    let out = merge_into(&nb, &id, first_file());
    assert_eq!((out["added"].as_i64(), out["updated"].as_i64(), out["unchanged"].as_i64(), out["kept_edits"].as_i64()), (Some(0), Some(0), Some(3), Some(0)));
    let again: Vec<i64> = ["KX0AAA", "KX0BBB", "KX0CCC"].iter().map(|t| entry_titled(&nb, &id, t)["rev"].as_i64().unwrap()).collect();
    assert_eq!(revs, again, "an entry that did not change is not saved again");
    assert_eq!(call(&nb, "entries", json!({"notebook_id": id}))["entries"].as_array().unwrap().len(), 3, "nothing is duplicated");
}

#[test]
fn an_update_follows_the_file_where_the_person_did_not_edit_and_keeps_what_they_did() {
    let (nb, _t) = notebook("src-edits");
    let id = merge_new(&nb, first_file())["notebook"]["id"].as_str().unwrap().to_string();
    // the person edits KX0AAA's town, writes notes on it and adds their own repeater by hand
    let a = entry_titled(&nb, &id, "KX0AAA");
    call(&nb, "entry_save", json!({"id": a["id"], "notebook_id": id, "occurred_at": a["occurred_at"], "title": "KX0AAA", "body": "my notes", "values": {"f1": "146.940 MHz", "f2": "Burley (my town)"}, "place": a["place"]}));
    call(&nb, "entry_save", json!({"notebook_id": id, "occurred_at": NOW, "title": "MINE", "values": {"f1": "146.520 MHz"}}));
    // the new file moves KX0AAA's frequency and town, and KX0BBB's frequency, adds KX0DDD, and drops KX0CCC
    let out = merge_into(&nb, &id, vec![
        frow("a", "KX0AAA", 42.1, "146.945 MHz", "Burley"),
        frow("b", "KX0BBB", 42.2, "147.060 MHz", "Rupert"),
        frow("d", "KX0DDD", 42.4, "145.230 MHz", "Oakley"),
    ]);
    assert_eq!((out["added"].as_i64(), out["updated"].as_i64(), out["kept_edits"].as_i64(), out["not_in_file"].as_i64()), (Some(1), Some(2), Some(1), Some(1)));
    let a = entry_titled(&nb, &id, "KX0AAA");
    assert_eq!(a["values"], json!({"f1": "146.945 MHz", "f2": "Burley (my town)"}), "the frequency follows the file, the edited town stays");
    assert_eq!(a["body"], "my notes");
    assert_eq!(entry_titled(&nb, &id, "KX0BBB")["values"]["f1"], "147.060 MHz");
    assert_eq!(entry_titled(&nb, &id, "KX0CCC")["values"]["f1"], "449.500 MHz", "a repeater the file dropped stays");
    assert_eq!(entry_titled(&nb, &id, "MINE")["values"]["f1"], "146.520 MHz", "a hand-made repeater is never touched");
    let led = call(&nb, "source_rows", json!({"notebook_id": id, "brief": true}));
    let gone: Vec<&Value> = led["rows"].as_array().unwrap().iter().filter(|r| r["state"] == "gone").collect();
    assert_eq!(gone.len(), 1);
    assert_eq!(gone[0]["key"], "c", "marked: not in the latest file");
    // a second update with the same file keeps the person's edit again (the edit is still not the file's)
    let out = merge_into(&nb, &id, vec![frow("a", "KX0AAA", 42.1, "146.945 MHz", "Burley"), frow("b", "KX0BBB", 42.2, "147.060 MHz", "Rupert"), frow("d", "KX0DDD", 42.4, "145.230 MHz", "Oakley")]);
    assert_eq!(out["updated"], 0);
    assert_eq!(entry_titled(&nb, &id, "KX0AAA")["values"]["f2"], "Burley (my town)");
    // the dropped one comes back in a later file: its mark goes
    merge_into(&nb, &id, first_file());
    let led = call(&nb, "source_rows", json!({"notebook_id": id, "brief": true}));
    assert!(led["rows"].as_array().unwrap().iter().all(|r| r["state"] != "gone" || r["key"] == "d"));
}

#[test]
fn a_repeater_the_person_deleted_stays_deleted_until_added_back() {
    let (nb, _t) = notebook("src-deleted");
    let id = merge_new(&nb, first_file())["notebook"]["id"].as_str().unwrap().to_string();
    let b = entry_titled(&nb, &id, "KX0BBB");
    call(&nb, "entry_delete", json!({"id": b["id"]}));
    let out = merge_into(&nb, &id, first_file());
    assert_eq!(out["added"], 0, "not made again");
    assert_eq!(out["deleted"].as_array().unwrap().len(), 1);
    assert_eq!(out["deleted"][0]["title"], "KX0BBB");
    assert_eq!(call(&nb, "entries", json!({"notebook_id": id}))["entries"].as_array().unwrap().len(), 2);
    let back = call(&nb, "source_add_back", json!({"notebook_id": id, "now": NOW}));
    assert_eq!(back["added"], 1);
    assert_eq!(entry_titled(&nb, &id, "KX0BBB")["values"], json!({"f1": "147.000 MHz", "f2": "Rupert"}));
    assert_eq!(call(&nb, "source_add_back", json!({"notebook_id": id, "now": NOW}))["added"], 0);
    assert_eq!(merge_into(&nb, &id, first_file())["deleted"].as_array().unwrap().len(), 0);
}

#[test]
fn an_entry_without_a_ledger_row_is_matched_by_claim_and_only_has_its_blanks_filled() {
    let (nb, _t) = notebook("src-claims");
    let id = call(&nb, "notebook_save", json!({"template": "repeaters", "def": list_def("Repeaters")}))["id"].as_str().unwrap().to_string();
    // arrived from another device: no ledger here
    let e = call(&nb, "entry_save", json!({"notebook_id": id, "occurred_at": NOW, "title": "KX0AAA", "values": {"f1": "146.940 MHz", "f2": "My town"}}));
    let out = call(&nb, "source_merge", json!({"notebook_id": id, "now": NOW, "rows": first_file(), "claims": {"a": e["id"]}}));
    assert_eq!(out["added"], 2, "the claimed row is not made again");
    let a = entry_titled(&nb, &id, "KX0AAA");
    assert_eq!(a["id"], e["id"]);
    assert_eq!(a["values"]["f2"], "My town", "nothing is overwritten");
    assert_eq!(a["place"]["lat"], 42.1, "a blank is filled");
    assert_eq!(call(&nb, "entries", json!({"notebook_id": id}))["entries"].as_array().unwrap().len(), 3);
}

#[test]
fn deleting_the_notebook_takes_its_ledger_and_the_ledger_is_not_in_the_way_of_an_older_build() {
    let (nb, _t) = notebook("src-delete");
    let id = merge_new(&nb, first_file())["notebook"]["id"].as_str().unwrap().to_string();
    call(&nb, "notebook_delete", json!({"id": id}));
    assert_eq!(call(&nb, "source_rows", json!({"notebook_id": id}))["rows"].as_array().unwrap().len(), 0);
    let schema: String = nb.with_conn(|c| Ok(c.query_row("SELECT value FROM meta WHERE key='schema_version'", [], |r| r.get(0))?)).unwrap();
    assert_eq!(schema, "2", "the schema version an older build checks is unchanged");
}

#[test]
fn the_repeaters_template_in_the_app_is_the_one_the_core_makes() {
    let doc: Value = serde_json::from_str(TEMPLATES).unwrap();
    let t = doc["templates"].as_array().unwrap().iter().find(|t| t["id"] == "repeaters").expect("a repeaters template");
    let labels: Vec<(String, String)> = t["fields"].as_array().unwrap().iter().map(|f| (f["label"].as_str().unwrap().into(), f["type"].as_str().unwrap().into())).collect();
    assert_eq!(labels, [("Frequency", "text"), ("Offset", "text"), ("Tone", "text"), ("Mode", "text"), ("Town", "text"), ("On air", "yes_no"), ("Details link", "text")].map(|(a, b)| (a.to_string(), b.to_string())));
    assert_eq!(t["icon"], "radio_tower");
    assert_eq!(t["shape"]["sort"], "distance");
}

#[test]
fn books_by_template_lists_entries_in_the_order_they_were_made() {
    let (nb, _t) = notebook("src-books");
    let id = merge_new(&nb, first_file())["notebook"]["id"].as_str().unwrap().to_string();
    let books = nb.books_by_template("repeaters").unwrap();
    assert_eq!(books.len(), 1);
    assert_eq!(books[0]["id"], id.as_str());
    let titles: Vec<&str> = books[0]["entries"].as_array().unwrap().iter().map(|e| e["title"].as_str().unwrap()).collect();
    assert_eq!(titles, ["KX0AAA", "KX0BBB", "KX0CCC"]);
}

#[test]
fn a_notebook_remembers_the_list_it_came_from_in_the_same_step_and_forgets_it_with_the_notebook() {
    let (nb, _t) = notebook("src-migrated");
    let out = call(
        &nb,
        "source_merge",
        json!({"notebook": {"template": "repeaters", "def": list_def("Repeaters"), "map": true, "template_ref": "templates/repeaters@1"}, "migrated_from": "l7", "now": NOW, "rows": first_file()}),
    );
    let id = out["notebook"]["id"].as_str().unwrap().to_string();
    assert_eq!(out["notebook"]["template_ref"], "templates/repeaters@1");
    assert_eq!(call(&nb, "source_migrated", json!({"from": "l7"}))["notebook_id"], id.as_str());
    assert!(call(&nb, "source_migrated", json!({"from": "l8"}))["notebook_id"].is_null());
    assert_eq!(nb.books_by_template("repeaters").unwrap()[0]["migrated"], json!(["l7"]));
    // a step that fails records nothing
    let mut rows = first_file();
    rows.push(json!({"key": "z", "title": "X", "values": {"f9": "no such field"}}));
    let e = nb.call("source_merge", Some(&json!({"notebook": {"template": "repeaters", "def": list_def("Other"), "map": true}, "migrated_from": "l9", "now": NOW, "rows": rows}).to_string()));
    assert_eq!(e.expect_err("bad row").code, "bad_json");
    assert!(call(&nb, "source_migrated", json!({"from": "l9"}))["notebook_id"].is_null());
    call(&nb, "notebook_delete", json!({"id": id}));
    assert!(call(&nb, "source_migrated", json!({"from": "l7"}))["notebook_id"].is_null(), "the note goes with the notebook");
}
