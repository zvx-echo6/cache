//! Repeater lists as notebooks, through the C ABI: the lists the older versions kept in user.sqlite become notebooks on the
//! device (every row kept, checked, the old list deleted only then), a file is read into a notebook and updated without wiping
//! the person's edits, and the assistant's `nearby` sees the same repeaters in the same words (only the list name and the address
//! change, and hand-made repeaters appear).

use cache_places::fixture::write_fixture_pack;
use cache_search::conv::Conversation;
use cache_search::ffi::*;
use cache_search::handle::Handle;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};

const NOW: &str = "2026-11-14T10:20:05-07:00";

struct Tmp(PathBuf);
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn fixture(f: &str) -> String {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../cache_user/tests/fixtures").join(f).to_string_lossy().into_owned()
}

struct H {
    h: *mut Handle,
    c: *mut Conversation,
    t: Tmp,
}

impl H {
    fn open(name: &str) -> H {
        let t = Tmp(std::env::temp_dir().join(format!("cs-nbrep-{}-{name}", std::process::id())));
        let _ = std::fs::remove_dir_all(&t.0);
        std::fs::create_dir_all(&t.0).unwrap();
        let pack = t.0.join("places.sqlite");
        write_fixture_pack(&pack);
        let cfg = json!({"sources": [], "places": {"packs": [pack]}, "user": {"db_path": t.0.join("user.sqlite")},
            "notebook": {"db_path": t.0.join("notebook/notebook.sqlite"), "media_dir": t.0.join("notebook")}});
        let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
        assert!(!h.is_null());
        assert_eq!(unsafe { cs_set_location(h, 42.5357, -113.7928, 12.0, cstr(NOW).as_ptr()) }, 0);
        H { h, c: cs_conversation_new(), t }
    }
    fn err(&self) -> Value {
        serde_json::from_str(&take(unsafe { cs_last_error(self.h) }).unwrap()).unwrap()
    }
    fn ok(&self, p: *mut c_char) -> Value {
        serde_json::from_str(&take(p).unwrap_or_else(|| panic!("{}", self.err()))).unwrap()
    }
    fn nb(&self, op: &str, args: Value) -> Result<Value, Value> {
        match take(unsafe { cs_notebook(self.h, cstr(op).as_ptr(), cstr(&args.to_string()).as_ptr()) }) {
            Some(s) => Ok(serde_json::from_str(&s).unwrap()),
            None => Err(self.err()),
        }
    }
    fn nb_ok(&self, op: &str, args: Value) -> Value {
        self.nb(op, args).unwrap_or_else(|e| panic!("{op}: {e}"))
    }
    fn legacy_import(&self, kml: &str) -> Value {
        let a = json!({"kind": "repeaters", "paths": [kml, fixture("repeaters-fixture.csv")]});
        self.ok(unsafe { cs_userlayers_import(self.h, cstr(&a.to_string()).as_ptr()) })
    }
    /// The same folder opened again, as the next start of the app does (the first handle is left as it is).
    fn reopen(&self) -> H {
        let cfg = json!({"sources": [], "places": {"packs": [self.t.0.join("places.sqlite")]}, "user": {"db_path": self.t.0.join("user.sqlite")},
            "notebook": {"db_path": self.t.0.join("notebook/notebook.sqlite"), "media_dir": self.t.0.join("notebook")}});
        let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
        assert!(!h.is_null());
        assert_eq!(unsafe { cs_set_location(h, 42.5357, -113.7928, 12.0, cstr(NOW).as_ptr()) }, 0);
        H { h, c: cs_conversation_new(), t: Tmp(self.t.0.clone()) }
    }
    fn stop_conversion_at(&self, stage: u8) {
        unsafe { (*self.h).ext.migrate_stop.store(stage, std::sync::atomic::Ordering::SeqCst) };
    }
    fn sql(&self, sql: &str) {
        unsafe { (*self.h).ext.notebook.as_ref().unwrap().raw_sql(sql).unwrap() };
    }
    fn lists(&self) -> Value {
        self.ok(unsafe { cs_userlayers_list(self.h) })
    }
    fn get(&self, id: &str) -> Value {
        self.ok(unsafe { cs_userlayer_get(self.h, cstr(id).as_ptr()) })
    }
    fn nearby(&self) -> Value {
        // a conversation of its own each time: the rows are numbered per conversation
        let c = cs_conversation_new();
        let r = take(unsafe { cs_tool(self.h, c, cstr("nearby").as_ptr(), cstr(&json!({"category": "repeater", "limit": 10}).to_string()).as_ptr(), cstr(NOW).as_ptr()) });
        unsafe { cs_conversation_free(c) };
        serde_json::from_str(&r.unwrap_or_else(|| panic!("nearby: {}", self.err()))).unwrap()
    }
    fn nearby_places(&self) -> Vec<Value> {
        let r = self.nearby();
        let c: Value = serde_json::from_str(r["content"].as_str().unwrap()).unwrap();
        c["places"].as_array().unwrap_or_else(|| panic!("nearby answered {c}")).clone()
    }
    fn notebooks_named(&self, prefix: &str) -> Vec<Value> {
        self.nb_ok("notebooks", json!({}))["notebooks"].as_array().unwrap().iter().filter(|n| n["def"]["name"].as_str().unwrap().starts_with(prefix)).cloned().collect()
    }
    fn entries(&self, id: &str) -> Vec<Value> {
        self.nb_ok("entries", json!({"notebook_id": id, "limit": 1000}))["entries"].as_array().unwrap().clone()
    }
}

impl Drop for H {
    fn drop(&mut self) {
        unsafe {
            cs_conversation_free(self.c);
            cs_close(self.h);
        }
    }
}

/// An entry's value in the field labelled `label` of notebook `nb`.
fn field(nb: &Value, e: &Value, label: &str) -> Option<Value> {
    let fid = nb["def"]["fields"].as_array().unwrap().iter().find(|f| f["label"] == label)?["fid"].as_str().unwrap().to_string();
    e["values"].get(&fid).cloned()
}

#[test]
fn an_older_list_becomes_a_notebook_with_every_row_and_the_assistant_sees_the_same_words() {
    let h = H::open("migrate");
    let l = h.legacy_import(&fixture("repeaters-fixture.kml"));
    assert_eq!(l["id"], "l1");
    let before = h.get("l1");
    let old_rows = before["repeaters"].as_array().unwrap().clone();
    assert!(old_rows.len() >= 4);
    let old_near = h.nearby_places();
    assert!(!old_near.is_empty());
    h.nb_ok("saved_places", json!({})); // the first notebook call turns the list into a notebook

    // the old list is gone, its notebook is there, named Repeaters, with every row
    assert_eq!(h.lists()["repeater_lists"].as_array().unwrap().len(), 0);
    let books = h.notebooks_named("Repeaters");
    assert_eq!(books.len(), 1);
    let nb = &books[0];
    assert_eq!((nb["template"].as_str(), nb["def"]["name"].as_str(), nb["template_ref"].as_str(), nb["map"].as_bool()), (Some("repeaters"), Some("Repeaters"), Some("templates/repeaters@1"), Some(true)));
    let entries = h.entries(nb["id"].as_str().unwrap());
    assert_eq!(entries.len(), old_rows.len(), "every row is an entry");
    // every field of every row, as the old list gave it
    for old in &old_rows {
        let e = entries.iter().find(|e| e["title"] == old["name"] && field(nb, e, "Frequency") == Some(old["frequency"].clone())).unwrap_or_else(|| panic!("no entry for {old}"));
        assert_eq!(field(nb, e, "Offset"), Some(old["offset"].clone()));
        assert_eq!(field(nb, e, "Tone"), Some(old["tone"].clone()));
        assert_eq!(field(nb, e, "Mode"), old.get("mode").filter(|v| !v.is_null()).cloned());
        assert_eq!(field(nb, e, "Town"), old.get("town").filter(|v| !v.is_null()).cloned());
        assert_eq!(field(nb, e, "On air"), old.get("on_air").filter(|v| !v.is_null()).map(|v| json!(v == "yes")));
        assert_eq!(field(nb, e, "Details link"), old.get("details_link").filter(|v| !v.is_null()).cloned());
        match (old["lat"].as_f64(), e.get("place")) {
            (Some(lat), Some(p)) => assert_eq!((p["lat"].as_f64(), p["lon"].as_f64()), (Some(lat), old["lon"].as_f64())),
            (None, None) => {}
            other => panic!("position differs for {old}: {other:?}"),
        }
    }
    // the ledger keeps each stored row (so nothing the old list held is lost)
    let led = h.nb_ok("source_rows", json!({"notebook_id": nb["id"]}));
    assert_eq!(led["rows"].as_array().unwrap().len(), old_rows.len());
    assert!(led["rows"].as_array().unwrap().iter().all(|r| r["source"].as_str().unwrap().starts_with('{') && r["state"] == "ok"));

    // the assistant: same rows, same order, same words; only the list name and the address change
    let new_near = h.nearby_places();
    assert_eq!(new_near.len(), old_near.len());
    for (o, n) in old_near.iter().zip(&new_near) {
        let (mut o, mut n) = (o.clone(), n.clone());
        assert_eq!(n["list"], "Repeaters");
        o.as_object_mut().unwrap().remove("list");
        n.as_object_mut().unwrap().remove("list");
        assert_eq!(serde_json::to_string(&o).unwrap(), serde_json::to_string(&n).unwrap());
    }
    // the address (kept for the app, not shown to the model) now names the entry
    let ids: Vec<String> = h.nearby()["ids"].as_array().unwrap().iter().map(|i| i["address"].as_str().unwrap().to_string()).collect();
    assert_eq!(ids.len(), new_near.len());
    assert!(ids.iter().all(|a| a.starts_with("repeater:") && !a.starts_with("repeater:l") && entries.iter().any(|e| a == &format!("repeater:{}", e["id"].as_str().unwrap()))), "{ids:?}");
    // doing it again changes nothing
    h.nb_ok("notebooks", json!({}));
    assert_eq!(h.notebooks_named("Repeaters").len(), 1);
}

#[test]
fn a_second_list_is_named_after_its_file_and_a_converted_list_is_never_converted_twice() {
    let h = H::open("two");
    h.legacy_import(&fixture("repeaters-fixture.kml"));
    h.legacy_import(&fixture("repeaters-fixture.kml"));
    h.nb_ok("notebooks", json!({}));
    let mut names: Vec<String> = h.notebooks_named("Repeaters").iter().map(|n| n["def"]["name"].as_str().unwrap().to_string()).collect();
    names.sort();
    assert_eq!(names, ["Repeaters", "Repeaters: repeaters-fixture"]);
    assert_eq!(h.lists()["repeater_lists"].as_array().unwrap().len(), 0);
}

#[test]
fn a_file_is_read_into_a_notebook_and_updated_without_wiping_edits() {
    let h = H::open("import");
    let kml = h.t.0.join("export.kml");
    std::fs::write(&kml, std::fs::read_to_string(fixture("repeaters-fixture.kml")).unwrap()).unwrap();
    let paths = json!([kml, fixture("repeaters-fixture.csv")]);
    let out = h.nb_ok("repeaters_import", json!({"paths": paths, "now": NOW}));
    let nb = out["notebook"].clone();
    let id = nb["id"].as_str().unwrap().to_string();
    assert_eq!(nb["template_ref"], "templates/repeaters@1", "the ref notebook sync writes into every entry file");
    assert_eq!((nb["def"]["name"].as_str(), nb["template"].as_str()), (Some("Repeaters"), Some("repeaters")));
    let n = out["added"].as_i64().unwrap();
    assert!(n >= 4 && out["updated"] == 0);
    // they are on the map as the notebook's pins, and the assistant sees them
    let pins = h.nb_ok("pins", json!({"notebook_id": id}))["entries"].as_array().unwrap().len() as i64;
    assert_eq!(pins as usize, out["with_position"].as_u64().unwrap() as usize);
    assert_eq!(h.nearby_places().len() as i64, pins);
    // the person edits TEST1's tone, adds notes and a repeater of their own
    let books = h.nb_ok("notebooks", json!({}));
    let nbj = books["notebooks"].as_array().unwrap().iter().find(|b| b["id"] == id.as_str()).unwrap().clone();
    let e = h.entries(&id).into_iter().find(|e| e["title"] == "TEST1").unwrap();
    let tone_fid = nbj["def"]["fields"].as_array().unwrap().iter().find(|f| f["label"] == "Tone").unwrap()["fid"].as_str().unwrap().to_string();
    let mut values = e["values"].clone();
    values[&tone_fid] = json!("my tone");
    h.nb_ok("entry_save", json!({"id": e["id"], "notebook_id": id, "occurred_at": e["occurred_at"], "title": "TEST1", "body": "checked it", "values": values, "place": e["place"]}));
    h.nb_ok("entry_save", json!({"notebook_id": id, "occurred_at": NOW, "title": "MINE", "place": {"lat": 42.5, "lon": -113.8}, "values": {}}));
    assert_eq!(h.nearby_places().len() as i64, pins + 1, "a hand-made repeater is seen too");
    // the same file again: nothing is duplicated, nothing is lost
    let again = h.nb_ok("repeaters_import", json!({"paths": paths, "notebook_id": id, "now": NOW}));
    assert_eq!((again["added"].as_i64(), again["updated"].as_i64(), again["unchanged"].as_i64()), (Some(0), Some(0), Some(n)));
    // a newer export: TEST1 is off the air now
    std::fs::write(&kml, std::fs::read_to_string(fixture("repeaters-fixture.kml")).unwrap().replacen("On-air: Yes", "On-air: No", 1)).unwrap();
    let up = h.nb_ok("repeaters_import", json!({"paths": paths, "notebook_id": id, "now": NOW}));
    assert_eq!((up["added"].as_i64(), up["updated"].as_i64()), (Some(0), Some(1)));
    let e = h.entries(&id).into_iter().find(|e| e["title"] == "TEST1").unwrap();
    assert_eq!(field(&nbj, &e, "On air"), Some(json!(false)), "the file's change arrives");
    assert_eq!(field(&nbj, &e, "Tone"), Some(json!("my tone")), "the person's edit stays");
    assert_eq!(e["body"], "checked it");
    assert!(h.entries(&id).iter().any(|e| e["title"] == "MINE"));
    assert_eq!(h.entries(&id).len() as i64, n + 1);
    // not a repeater notebook, or not a repeater file
    let journal = books["notebooks"].as_array().unwrap().iter().find(|b| b["template"] == "journal").unwrap()["id"].clone();
    assert_eq!(h.nb("repeaters_import", json!({"paths": paths, "notebook_id": journal})).unwrap_err()["code"], "bad_json");
    assert_eq!(h.nb("repeaters_import", json!({"paths": [fixture("trip.gpx")]})).unwrap_err()["code"], "bad_json");
}

#[test]
fn a_repeater_deleted_by_the_person_stays_deleted_and_can_be_added_back() {
    let h = H::open("addback");
    let paths = json!([fixture("repeaters-fixture.kml"), fixture("repeaters-fixture.csv")]);
    let out = h.nb_ok("repeaters_import", json!({"paths": paths, "now": NOW}));
    let id = out["notebook"]["id"].as_str().unwrap().to_string();
    let n = h.entries(&id).len();
    let gone = h.entries(&id).into_iter().find(|e| e["title"] == "TEST2").unwrap();
    h.nb_ok("entry_delete", json!({"id": gone["id"]}));
    let up = h.nb_ok("repeaters_import", json!({"paths": paths, "notebook_id": id, "now": NOW}));
    assert_eq!(up["added"], 0);
    assert_eq!(up["deleted"][0]["title"], "TEST2");
    assert_eq!(h.entries(&id).len(), n - 1);
    assert_eq!(h.nb_ok("repeaters_add_back", json!({"notebook_id": id, "now": NOW}))["added"], 1);
    assert_eq!(h.entries(&id).len(), n);
}


/// What a converted (or not yet converted) repeater list looks like, for the interrupted-conversion tests.
struct Seen {
    old_lists: usize,
    notebooks: usize,
    entries: usize,
    ledger: usize,
}

fn seen(h: &H) -> Seen {
    let books = h.notebooks_named("Repeaters");
    let (entries, ledger) = books.first().map_or((0, 0), |b| {
        let id = b["id"].as_str().unwrap();
        (h.entries(id).len(), h.nb_ok("source_rows", json!({"notebook_id": id, "brief": true}))["rows"].as_array().unwrap().len())
    });
    Seen { old_lists: h.lists()["repeater_lists"].as_array().unwrap().len(), notebooks: books.len(), entries, ledger }
}

fn words(h: &H) -> Vec<String> {
    h.nearby_places().into_iter().map(|mut p| {
        p.as_object_mut().unwrap().remove("list");
        serde_json::to_string(&p).unwrap()
    }).collect()
}

#[test]
fn a_conversion_stopped_at_any_stage_is_finished_by_the_next_start_with_every_row_and_no_duplicate() {
    for stage in [1u8, 2, 3] {
        let h = H::open(&format!("stop{stage}"));
        h.legacy_import(&fixture("repeaters-fixture.kml"));
        let rows = h.get("l1")["repeaters"].as_array().unwrap().len();
        let before = words(&h);
        h.stop_conversion_at(stage);
        h.nb_ok("saved_places", json!({})); // the first notebook call starts the conversion, which stops at `stage`
        let s = seen(&h);
        assert_eq!(s.old_lists, 1, "stage {stage}: the old list is never deleted before the whole check passed");
        if stage == 1 {
            assert_eq!((s.notebooks, s.entries, s.ledger), (0, 0, 0), "nothing was written");
        } else {
            assert_eq!((s.notebooks, s.entries, s.ledger), (1, rows, rows), "stage {stage}: the notebook is whole or absent, never partial");
        }
        assert_eq!(words(&h), before, "stage {stage}: the assistant sees the same repeaters while it is half done");
        // the next start
        let h2 = h.reopen();
        h2.nb_ok("notebooks", json!({}));
        let s = seen(&h2);
        assert_eq!((s.old_lists, s.notebooks, s.entries, s.ledger), (0, 1, rows, rows), "stage {stage}: finished, nothing twice");
        assert_eq!(words(&h2), before, "stage {stage}: every row, same words");
        // and a further start changes nothing
        let h3 = h2.reopen();
        h3.nb_ok("notebooks", json!({}));
        let s = seen(&h3);
        assert_eq!((s.old_lists, s.notebooks, s.entries), (0, 1, rows), "stage {stage}");
    }
}

#[test]
fn a_failure_in_the_middle_of_the_write_leaves_nothing_and_the_next_start_converts_it_whole() {
    let h = H::open("middle");
    h.legacy_import(&fixture("repeaters-fixture.kml"));
    let rows = h.get("l1")["repeaters"].as_array().unwrap().len();
    assert!(rows > 3);
    let before = words(&h);
    // the third entry cannot be written: the failure comes after two entries are in the transaction
    h.sql("CREATE TRIGGER fail_third BEFORE INSERT ON entries WHEN (SELECT COUNT(*) FROM entries WHERE notebook_id = NEW.notebook_id) >= 2 BEGIN SELECT RAISE(ABORT, 'disk full'); END;");
    h.nb_ok("saved_places", json!({}));
    let s = seen(&h);
    assert_eq!((s.old_lists, s.notebooks, s.entries, s.ledger), (1, 0, 0, 0), "the whole write is undone, the old list is untouched");
    assert_eq!(words(&h), before);
    // the next start, the cause gone
    let h2 = h.reopen();
    h2.sql("DROP TRIGGER fail_third;");
    h2.nb_ok("notebooks", json!({}));
    let s = seen(&h2);
    assert_eq!((s.old_lists, s.notebooks, s.entries, s.ledger), (0, 1, rows, rows));
    assert_eq!(words(&h2), before);
}

#[test]
fn the_old_list_is_deleted_only_after_the_read_back_finds_every_row() {
    let h = H::open("check");
    h.legacy_import(&fixture("repeaters-fixture.kml"));
    let rows = h.get("l1")["repeaters"].as_array().unwrap().len();
    h.stop_conversion_at(2); // written, not yet read back
    h.nb_ok("saved_places", json!({}));
    // damage after the write: one entry's callsign changed, one entry gone
    h.sql("UPDATE entries SET title = 'DAMAGED' WHERE rowid = (SELECT MIN(rowid) FROM entries WHERE title IS NOT NULL AND notebook_id IN (SELECT id FROM notebooks WHERE template = 'repeaters'));");
    let h2 = h.reopen();
    h2.nb_ok("notebooks", json!({}));
    let s = seen(&h2);
    assert_eq!((s.old_lists, s.notebooks, s.entries), (1, 1, rows), "the check failed, so the old list stays, and nothing is made twice");
    // mended, the next start passes the check and deletes the list
    h2.sql("UPDATE entries SET title = 'TEST1' WHERE title = 'DAMAGED';");
    let h3 = h2.reopen();
    h3.nb_ok("notebooks", json!({}));
    let s = seen(&h3);
    assert_eq!((s.old_lists, s.notebooks, s.entries), (0, 1, rows));
}

// ---- one rule for every import: the same NAME updates, any other name is added ----

const CHIRP_HEAD: &str = "Location,Name,Frequency,Duplex,Offset,Tone,rToneFreq,cToneFreq,DtcsCode,DtcsPolarity,Mode,TStep,Skip,Comment\n";

fn chirp(h: &H, file: &str, rows: &[(&str, &str, &str)]) -> String {
    let mut t = CHIRP_HEAD.to_string();
    for (i, (name, freq, tone)) in rows.iter().enumerate() {
        t.push_str(&format!("{i},{name},{freq},-,0.600000,Tone,{tone},{tone},023,NN,FM,5.00,,note\n"));
    }
    let p = h.t.0.join(file);
    std::fs::write(&p, t).unwrap();
    p.to_string_lossy().into_owned()
}

fn rb_kml(h: &H, file: &str, rows: &[(&str, &str, &str, f64, f64)]) -> String {
    let mut t = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<kml xmlns=\"http://www.opengis.net/kml/2.2\"><Document>\n");
    for (name, town, freq, lat, lon) in rows {
        t.push_str(&format!(
            "<Placemark><name>{name}</name><description><![CDATA[{town}<br>{freq}- 100.0<br>On-air: Yes]]></description><Point><coordinates>{lon},{lat},0</coordinates></Point></Placemark>\n"
        ));
    }
    t.push_str("</Document></kml>\n");
    let p = h.t.0.join(file);
    std::fs::write(&p, t).unwrap();
    p.to_string_lossy().into_owned()
}

fn imp(h: &H, path: &str, nb: Option<&str>) -> Value {
    let mut a = json!({"paths": [path], "now": NOW});
    if let Some(n) = nb {
        a["notebook_id"] = json!(n);
    }
    h.nb_ok("repeaters_import", a)
}

fn titles(h: &H, id: &str) -> Vec<String> {
    let mut v: Vec<String> = h.entries(id).iter().map(|e| e["title"].as_str().unwrap_or_default().to_string()).collect();
    v.sort();
    v
}

#[test]
fn a_kml_of_the_same_names_updates_the_entries_a_csv_made_instead_of_adding_copies() {
    let h = H::open("byname-csv-kml");
    let csv = chirp(&h, "r.csv", &[("R11 Boise", "146.760000", "100.0"), ("R11 Nampa", "147.020000", "107.2"), ("R11 Meridian", "444.100000", "123.0")]);
    let out = imp(&h, &csv, None);
    assert_eq!((out["added"].as_i64(), out["with_position"].as_i64()), (Some(3), Some(0)));
    let id = out["notebook"]["id"].as_str().unwrap().to_string();
    let nb = out["notebook"].clone();
    let kml = rb_kml(&h, "r.kml", &[("R11 Boise", "Boise", "146.760000", 43.615, -116.2023), ("R11 Nampa", "Nampa", "147.020000", 43.5407, -116.5635), ("R11 Meridian", "Meridian", "444.100000", 43.6121, -116.3915)]);
    let up = imp(&h, &kml, Some(&id));
    assert_eq!((up["added"].as_i64(), up["updated"].as_i64(), up["not_in_file"].as_i64()), (Some(0), Some(3), Some(0)), "{up}");
    let es = h.entries(&id);
    assert_eq!(es.len(), 3, "no copies: {:?}", titles(&h, &id));
    let boise = es.iter().find(|e| e["title"] == "R11 Boise").unwrap();
    assert_eq!(boise["place"]["lat"], 43.615, "the position the KML gives");
    assert_eq!(field(&nb, boise, "Town"), Some(json!("Boise")));
    assert_eq!(field(&nb, boise, "Mode"), Some(json!("FM")), "what the CSV gave stays");
}

#[test]
fn a_different_name_is_added_and_case_and_spaces_do_not_make_one() {
    let h = H::open("byname-names");
    let out = imp(&h, &chirp(&h, "a.csv", &[("R11 Boise", "146.760000", "100.0")]), None);
    let id = out["notebook"]["id"].as_str().unwrap().to_string();
    let up = imp(&h, &chirp(&h, "b.csv", &[("  r11   BOISE ", "146.770000", "100.0"), ("R11 Caldwell", "146.800000", "100.0")]), Some(&id));
    assert_eq!((up["added"].as_i64(), up["updated"].as_i64()), (Some(1), Some(1)), "{up}");
    assert_eq!(titles(&h, &id), vec!["R11 Boise".to_string(), "R11 Caldwell".to_string()], "the entry keeps its own spelling of the name");
}

#[test]
fn of_two_entries_with_the_same_name_only_one_is_updated_and_never_a_third_made() {
    let h = H::open("byname-two");
    let out = imp(&h, &chirp(&h, "a.csv", &[("OTHER", "146.940000", "100.0")]), None);
    let id = out["notebook"]["id"].as_str().unwrap().to_string();
    // two hand-made entries with the same name; the older one has a note
    let old = h.nb_ok("entry_save", json!({"notebook_id": id, "occurred_at": NOW, "title": "R11 Boise", "body": "old one", "values": {}}));
    std::thread::sleep(std::time::Duration::from_millis(1100));
    let newer = h.nb_ok("entry_save", json!({"notebook_id": id, "occurred_at": NOW, "title": "r11 boise", "body": "newer one", "values": {}}));
    let up = imp(&h, &chirp(&h, "b.csv", &[("R11 Boise", "146.760000", "100.0")]), Some(&id));
    assert_eq!((up["added"].as_i64(), up["updated"].as_i64()), (Some(0), Some(1)), "{up}");
    let es = h.entries(&id);
    assert_eq!(es.len(), 3, "OTHER and the two hand-made ones; nothing new");
    let nb = out["notebook"].clone();
    let o = es.iter().find(|e| e["id"] == old["id"]).unwrap();
    let n = es.iter().find(|e| e["id"] == newer["id"]).unwrap();
    assert!(field(&nb, o, "Frequency").is_some(), "the oldest one is the one updated");
    assert!(field(&nb, n, "Frequency").is_none(), "the other is left alone");
    assert_eq!(o["body"], "old one");
}

#[test]
fn an_edit_of_the_person_survives_an_update_by_name_and_the_marker_follows_names() {
    let h = H::open("byname-edit");
    let csv = chirp(&h, "a.csv", &[("R11 Boise", "146.760000", "100.0"), ("R11 Nampa", "147.020000", "107.2"), ("R11 Meridian", "444.100000", "123.0")]);
    let out = imp(&h, &csv, None);
    let id = out["notebook"]["id"].as_str().unwrap().to_string();
    let nb = out["notebook"].clone();
    let tone_fid = nb["def"]["fields"].as_array().unwrap().iter().find(|f| f["label"] == "Tone").unwrap()["fid"].as_str().unwrap().to_string();
    let e = h.entries(&id).into_iter().find(|e| e["title"] == "R11 Boise").unwrap();
    let mut values = e["values"].clone();
    values[&tone_fid] = json!("my tone");
    h.nb_ok("entry_save", json!({"id": e["id"], "notebook_id": id, "occurred_at": e["occurred_at"], "title": "R11 Boise", "body": "my notes", "values": values, "place": e["place"]}));
    // the next file has two of the three names (Meridian is not in it)
    let kml = rb_kml(&h, "b.kml", &[("R11 Boise", "Boise", "146.760000", 43.615, -116.2023), ("R11 Nampa", "Nampa", "147.020000", 43.5407, -116.5635)]);
    let up = imp(&h, &kml, Some(&id));
    assert_eq!((up["added"].as_i64(), up["updated"].as_i64(), up["not_in_file"].as_i64()), (Some(0), Some(2), Some(1)), "{up}");
    let e = h.entries(&id).into_iter().find(|e| e["title"] == "R11 Boise").unwrap();
    assert_eq!(field(&nb, &e, "Tone"), Some(json!("my tone")), "the person's edit stays");
    assert_eq!(field(&nb, &e, "Town"), Some(json!("Boise")), "what the file adds arrives");
    assert_eq!(e["body"], "my notes");
    // the marker is the ledger's: the row of the name that is not in the file
    let rows = h.nb_ok("source_rows", json!({"notebook_id": id, "brief": true}));
    let gone: Vec<&str> = rows["rows"].as_array().unwrap().iter().filter(|r| r["state"] == "gone").map(|r| r["key"].as_str().unwrap()).collect();
    assert_eq!(gone, vec!["r11 meridian"]);
    // and it comes back when a file has the name again
    let back = imp(&h, &chirp(&h, "c.csv", &[("R11 MERIDIAN", "444.100000", "123.0")]), Some(&id));
    assert_eq!((back["added"].as_i64(), back["not_in_file"].as_i64()), (Some(0), Some(2)));
    assert_eq!(h.entries(&id).len(), 3);
}

#[test]
fn a_name_twice_in_a_file_is_one_row_the_later_one_wins_and_ledgers_made_before_are_rekeyed_by_name() {
    let h = H::open("byname-last");
    let out = imp(&h, &chirp(&h, "a.csv", &[("R11 Boise", "146.760000", "100.0"), ("R11 Boise", "146.970000", "100.0")]), None);
    let id = out["notebook"]["id"].as_str().unwrap().to_string();
    let nb = out["notebook"].clone();
    assert_eq!((out["added"].as_i64(), h.entries(&id).len()), (Some(1), 1), "{out}");
    assert_eq!(field(&nb, &h.entries(&id)[0], "Frequency"), Some(json!("146.970 MHz")), "the later row wins");
    // a ledger from before this rule is keyed by callsign, frequency and town: the next import still finds the entry by its name
    h.sql("UPDATE source_rows SET key = 'r11 boise|146970000|'");
    let up = imp(&h, &chirp(&h, "b.csv", &[("R11 Boise", "146.980000", "100.0")]), Some(&id));
    assert_eq!((up["added"].as_i64(), up["updated"].as_i64()), (Some(0), Some(1)), "{up}");
    assert_eq!(h.entries(&id).len(), 1);
}

#[test]
fn a_places_import_into_a_notebook_updates_a_point_of_the_same_name_and_adds_the_others() {
    let h = H::open("byname-places");
    let one = h.t.0.join("one.kml");
    std::fs::write(&one, r#"<?xml version="1.0"?><kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Spots</name>
<Placemark><name>Camp</name><description>by the creek</description><Point><coordinates>-114.0,42.0,0</coordinates></Point></Placemark>
<Placemark><name>Well</name><Point><coordinates>-114.1,42.1,0</coordinates></Point></Placemark></Document></kml>"#).unwrap();
    let out = h.nb_ok("import", json!({"path": one, "now": NOW}));
    let id = out["notebook"]["id"].as_str().unwrap().to_string();
    assert_eq!((out["places"].as_i64(), out["updated"].as_i64()), (Some(2), Some(0)), "{out}");
    // the person writes on Camp
    let camp = h.entries(&id).into_iter().find(|e| e["title"] == "Camp").unwrap();
    h.nb_ok("entry_save", json!({"id": camp["id"], "notebook_id": id, "occurred_at": camp["occurred_at"], "title": "Camp", "body": "my own notes", "place": camp["place"], "values": {}}));
    // a newer file: Camp moved, ' WELL ' is Well again, Spring is new
    let two = h.t.0.join("two.kml");
    std::fs::write(&two, r#"<?xml version="1.0"?><kml xmlns="http://www.opengis.net/kml/2.2"><Document><name>Spots</name>
<Placemark><name>camp</name><description>new words</description><Point><coordinates>-114.5,42.5,0</coordinates></Point></Placemark>
<Placemark><name> WELL </name><Point><coordinates>-114.1,42.1,0</coordinates></Point></Placemark>
<Placemark><name>Spring</name><Point><coordinates>-114.9,42.9,0</coordinates></Point></Placemark></Document></kml>"#).unwrap();
    let up = h.nb_ok("import", json!({"path": two, "notebook_id": id, "now": NOW}));
    assert_eq!((up["places"].as_i64(), up["updated"].as_i64()), (Some(1), Some(2)), "{up}");
    let es = h.entries(&id);
    assert_eq!(es.len(), 3, "{:?}", titles(&h, &id));
    let camp = es.iter().find(|e| e["title"] == "Camp").unwrap();
    assert_eq!(camp["place"]["lat"], 42.5, "moved to the file's position");
    assert_eq!(camp["body"], "my own notes", "the person's notes stay");
}
