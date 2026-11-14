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
    assert_eq!((nb["template"].as_str(), nb["def"]["name"].as_str(), nb["template_ref"].as_str(), nb["map"].as_bool()), (Some("repeaters"), Some("Repeaters"), Some("migrated/l1"), Some(true)));
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
