//! Places notebooks and the user's map data as one store, through the C ABI: the saved places are the saved-places notebook,
//! every other Places notebook is a map layer, and a file can be imported into a notebook. What the tools see must not
//! change by a byte: a notebook's places reach nearby, navigate and locate exactly as an imported layer's points do, in the
//! shapes recorded for training (tests/fixtures/userdata-golden.json).

use cache_places::fixture::write_fixture_pack;
use cache_search::conv::Conversation;
use cache_search::ffi::*;
use cache_search::handle::Handle;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};

const NOW: &str = "2026-10-25T14:20:05-06:00";

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

fn golden() -> Value {
    serde_json::from_str(include_str!("fixtures/userdata-golden.json")).unwrap()
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
        let t = Tmp(std::env::temp_dir().join(format!("cs-nbplaces-{}-{name}", std::process::id())));
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
    fn import(&self, a: Value) -> Value {
        self.ok(unsafe { cs_userlayers_import(self.h, cstr(&a.to_string()).as_ptr()) })
    }
    fn places(&self) -> Value {
        self.ok(unsafe { cs_places_list(self.h) })
    }
    fn place_save(&self, p: Value) -> Value {
        self.ok(unsafe { cs_place_save(self.h, cstr(&p.to_string()).as_ptr()) })
    }
    /// The tool's whole reply (content, ids, ...) as text.
    fn tool(&self, name: &str, args: Value) -> String {
        let p = unsafe { cs_tool(self.h, self.c, cstr(name).as_ptr(), cstr(&args.to_string()).as_ptr(), cstr(NOW).as_ptr()) };
        take(p).unwrap_or_else(|| panic!("{name}: {}", self.err()))
    }
    fn content(&self, name: &str, args: Value) -> Value {
        let r: Value = serde_json::from_str(&self.tool(name, args)).unwrap();
        serde_json::from_str(r["content"].as_str().unwrap()).unwrap()
    }
    fn schemas(&self) -> Vec<Value> {
        let all: Value = serde_json::from_str(&take(unsafe { cs_tool_schemas(self.h) }).unwrap()).unwrap();
        all.as_array().unwrap().iter().filter(|s| ["navigate", "nearby", "locate"].contains(&s["function"]["name"].as_str().unwrap())).cloned().collect()
    }
    fn nearby(&self) -> Value {
        self.schemas().into_iter().find(|s| s["function"]["name"] == "nearby").unwrap()
    }
    /// A Places notebook with these places, made the way the app makes one (a notebook, then one entry per place).
    fn places_notebook(&self, layer: &Value) -> String {
        let n = self.nb_ok("notebook_save", json!({"template": "places", "def": {"name": layer["name"], "due_every": null, "shape": {"sort": "distance"}, "fields": []}}));
        let id = n["id"].as_str().unwrap().to_string();
        for p in layer["points"].as_array().unwrap() {
            self.nb_ok("entry_save", json!({"notebook_id": id, "occurred_at": NOW, "title": p["name"], "body": p["notes"],
                "place": {"lat": p["lat"], "lon": p["lon"]}}));
        }
        id
    }
    /// The same places as an imported layer file (a GeoJSON FeatureCollection named after the layer).
    fn import_layer(&self, layer: &Value) {
        let features: Vec<Value> = layer["points"]
            .as_array()
            .unwrap()
            .iter()
            .map(|p| json!({"type": "Feature", "geometry": {"type": "Point", "coordinates": [p["lon"], p["lat"]]}, "properties": {"name": p["name"], "notes": p["notes"]}}))
            .collect();
        let path = self.t.0.join(format!("{}.geojson", layer["name"].as_str().unwrap()));
        std::fs::write(&path, json!({"type": "FeatureCollection", "name": layer["name"], "features": features}).to_string()).unwrap();
        self.import(json!({"kind": "layer", "paths": [path]}));
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

fn keys(v: &Value) -> Vec<String> {
    v.as_object().unwrap().keys().cloned().collect()
}

/// `small` is `big` with some items left out, in the same order.
fn subsequence(small: &[String], big: &[String]) -> bool {
    let mut it = big.iter();
    small.iter().all(|s| it.any(|b| b == s))
}

#[test]
fn a_places_notebook_reaches_the_tools_exactly_like_an_imported_layer() {
    let g = golden();
    let (a, b) = (H::open("imported"), H::open("notebooks"));
    for layer in g["layers_setup"].as_array().unwrap() {
        a.import_layer(layer);
        b.places_notebook(layer);
    }
    // the declarations, byte for byte
    assert_eq!(serde_json::to_string(&a.schemas()).unwrap(), serde_json::to_string(&b.schemas()).unwrap());
    // the layer categories as recorded: most recently used first, "<id> = <name>: points in the user's own map layer"
    let rec = g["declarations_with_layers"].as_array().unwrap().iter().find(|s| s["function"]["name"] == "nearby").unwrap().clone();
    let cat = |s: &Value| s["function"]["parameters"]["properties"]["category"].clone();
    let (ours, recorded) = (cat(&b.nearby()), cat(&rec));
    let tail = |e: &Value| e["enum"].as_array().unwrap().iter().filter(|x| x.as_str().unwrap().starts_with("layer_")).cloned().collect::<Vec<_>>();
    assert_eq!(tail(&ours), tail(&recorded));
    assert_eq!(tail(&ours), [json!("layer_ham_club"), json!("layer_magic_valley_meetup")]);
    let layer_words = |e: &Value| e["description"].as_str().unwrap().split_once("; layer_").map(|(_, t)| t.to_string()).unwrap();
    assert_eq!(layer_words(&ours), layer_words(&recorded));
    // locate's declaration as recorded (navigate needs routing, which this handle has not)
    let r = g["declarations_with_layers"].as_array().unwrap().iter().find(|s| s["function"]["name"] == "locate").unwrap();
    let o = b.schemas().into_iter().find(|s| s["function"]["name"] == "locate").unwrap();
    assert_eq!(o["function"], r["function"]);

    // every tool answer, byte for byte (numbering included)
    for (tool, args) in [
        ("nearby", json!({"category": "layer_magic_valley_meetup"})),
        ("nearby", json!({"category": "layer_ham_club", "limit": 1})),
        ("nearby", json!({"category": "layer_nope"})),
        ("locate", json!({"place": "Rally Point"})),
        ("locate", json!({"place": "chinese peak repeater site"})),
        ("locate", json!({"place": "Nowhere Special"})),
    ] {
        assert_eq!(a.tool(tool, args.clone()), b.tool(tool, args.clone()), "{tool} {args}");
    }

    // the rows in the recorded shape
    let rec_rows: Value = serde_json::from_str(g["nearby_layer"]["tool_message"].as_str().unwrap()).unwrap();
    let rows = b.content("nearby", json!({"category": "layer_magic_valley_meetup"}));
    assert_eq!(keys(&rows), keys(&rec_rows).into_iter().filter(|k| keys(&rows).contains(k)).collect::<Vec<_>>());
    for r in rec_rows["places"].as_array().unwrap() {
        let o = rows["places"].as_array().unwrap().iter().find(|o| o["name"] == r["name"]).unwrap();
        assert_eq!(keys(o), keys(r), "{}", r["name"]);
        for k in ["name", "kind", "kind_label", "notes"] {
            assert_eq!(o[k], r[k], "{k}");
        }
    }
    let loc = b.content("locate", json!({"place": "Rally Point"}));
    let rec_loc: Value = serde_json::from_str(g["locate_layer_point"]["tool_message"].as_str().unwrap()).unwrap();
    assert!(subsequence(&keys(&loc), &keys(&rec_loc)), "{:?}", keys(&loc));
    assert_eq!((loc["kind"].clone(), loc["kind_label"].clone()), (json!("layer_point"), json!("Ham Club")));

    // navigate's matching by exact name: the most recently used layer's point first, the other as a candidate (as recorded)
    let rec_nav: Value = serde_json::from_str(g["navigate_layer_point"]["tool_message"].as_str().unwrap()).unwrap();
    let user = cache_tool::user::current(unsafe { &(*b.h).ext.user_points }).unwrap();
    let named = user.named("rally point");
    assert_eq!(named.len(), 2);
    assert_eq!(json!(named[0].kind_label), rec_nav["to_matched"]["kind_label"]);
    assert_eq!(json!(named[1].kind_label), rec_nav["other_destination_candidates"][0]["kind_label"]);
    assert!(named.iter().all(|p| p.kind == "layer_point"));
}

#[test]
fn private_and_hidden_notebooks_stay_visible_to_the_tools_and_deleting_one_removes_its_layer() {
    let g = golden();
    let b = H::open("private");
    let ids: Vec<String> = g["layers_setup"].as_array().unwrap().iter().map(|l| b.places_notebook(l)).collect();
    let before = serde_json::to_string(&b.schemas()).unwrap();
    let mvm = b.nb_ok("notebook", json!({"id": ids[0]}));
    // private and off the map: still offered to the tools (private only decides what sync and sharing leave out)
    b.nb_ok("notebook_save", json!({"id": ids[0], "def": mvm["def"], "private": true, "map": false}));
    let cats = b.nearby()["function"]["parameters"]["properties"]["category"]["enum"].clone();
    assert!(cats.as_array().unwrap().contains(&json!("layer_magic_valley_meetup")));
    assert_eq!(b.content("nearby", json!({"category": "layer_magic_valley_meetup"}))["places"].as_array().unwrap().len(), 2);
    // an unchanged notebook does not move its layer: syncing again leaves the declarations as they are
    let now = serde_json::to_string(&b.schemas()).unwrap();
    b.nb_ok("notebooks", json!({}));
    assert_eq!(serde_json::to_string(&b.schemas()).unwrap(), now);
    assert_eq!(before.matches("layer_").count(), now.matches("layer_").count());
    b.nb_ok("notebook_delete", json!({"id": ids[0]}));
    b.nb_ok("notebook_delete", json!({"id": ids[1]}));
    let cats = b.nearby()["function"]["parameters"]["properties"]["category"]["enum"].clone();
    assert!(!cats.as_array().unwrap().iter().any(|c| c.as_str().unwrap().starts_with("layer_")));
    assert!(b.ok(unsafe { cs_userlayers_list(b.h) })["layers"].as_array().unwrap().is_empty());
}

#[test]
fn saved_places_are_the_places_notebook() {
    let h = H::open("saved");
    // saved before Notebooks first opens (an update from a Cache without the Places notebook): moved in, nothing lost
    h.place_save(json!({"name": "Home", "lat": 42.56078, "lon": -114.46234}));
    h.place_save(json!({"name": "Cabin", "lat": 44.1, "lon": -115.2, "label": "Forest road 12"}));
    let list = h.nb_ok("notebooks", json!({}));
    let places = list["notebooks"].as_array().unwrap().iter().find(|n| n["saved_places"] == true).unwrap().clone();
    assert_eq!((places["def"]["name"].clone(), places["template"].clone(), places["entries"].clone()), (json!("Places"), json!("places"), json!(2)));
    let pid = places["id"].as_str().unwrap().to_string();
    let entries = h.nb_ok("entries", json!({"notebook_id": pid}))["entries"].clone();
    let home = entries.as_array().unwrap().iter().find(|e| e["title"] == "Home").unwrap().clone();
    assert_eq!(home["place"], json!({"lat": 42.56078, "lon": -114.46234, "key": "home"}));
    // what the assistant's places.list reads is unchanged
    assert_eq!(h.places(), json!({"places": [{"key": "home", "name": "Home", "lat": 42.56078, "lon": -114.46234},
        {"key": "cabin", "name": "Cabin", "lat": 44.1, "lon": -115.2, "label": "Forest road 12"}]}));
    // notes, a marker colour and a moved pin: the key stays, the saved place follows
    let mut e = home.clone();
    e["body"] = json!("**Meet here** if phones are down.");
    e["props"] = json!({"color": "green", "on_map": true});
    e["place"] = json!({"lat": 42.6, "lon": -114.5});
    for k in ["created", "updated", "rev", "draft", "private"] {
        e.as_object_mut().unwrap().remove(k);
    }
    let saved = h.nb_ok("entry_save", e);
    assert_eq!((saved["place"]["key"].clone(), saved["props"].clone()), (json!("home"), json!({"color": "green", "on_map": true})));
    assert_eq!(h.places()["places"][0], json!({"key": "home", "name": "Home", "lat": 42.6, "lon": -114.5}));
    // a new place in the notebook is a new saved place; one without a position is refused
    let rp = h.nb_ok("entry_save", json!({"notebook_id": pid, "occurred_at": NOW, "title": "Rally point 1", "place": {"lat": 42.5, "lon": -114.4}}));
    assert_eq!(rp["place"]["key"], "rally-point-1");
    assert_eq!(h.places()["places"].as_array().unwrap().len(), 3);
    assert_eq!(h.nb("entry_save", json!({"notebook_id": pid, "occurred_at": NOW, "title": "Nowhere"})).unwrap_err()["code"], "bad_json");
    // a place saved elsewhere (the map's place card, the assistant) gets its entry; a rename there renames it
    h.place_save(json!({"name": "Trailhead", "lat": 43.0, "lon": -115.0}));
    h.place_save(json!({"key": "cabin", "name": "Cabin north", "lat": 44.1, "lon": -115.2}));
    let titles: Vec<String> = h.nb_ok("entries", json!({"notebook_id": pid}))["entries"].as_array().unwrap().iter().map(|e| e["title"].as_str().unwrap().to_string()).collect();
    assert!(titles.contains(&"Trailhead".to_string()) && titles.contains(&"Cabin north".to_string()), "{titles:?}");
    // deleting either way deletes both
    assert_eq!(h.ok(unsafe { cs_place_delete(h.h, cstr("home").as_ptr()) }), json!({"deleted": "home"}));
    assert!(h.nb_ok("entries", json!({"notebook_id": pid}))["entries"].as_array().unwrap().iter().all(|e| e["title"] != "Home"));
    h.nb_ok("entry_delete", json!({"id": rp["id"]}));
    assert!(h.places()["places"].as_array().unwrap().iter().all(|p| p["key"] != "rally-point-1"));
    // the saved places are not a map layer (they reach the assistant as saved places) and their notebook stays
    assert!(!h.nearby()["function"]["parameters"]["properties"]["category"]["enum"].as_array().unwrap().iter().any(|c| c.as_str().unwrap().starts_with("layer_")));
    assert_eq!(h.nb("notebook_delete", json!({"id": pid})).unwrap_err()["code"], "bad_json");
    assert_eq!(h.nb_ok("saved_places", json!({}))["id"], json!(pid));
}

#[test]
fn a_file_imported_into_a_notebook_is_its_places_and_layer() {
    let (a, b) = (H::open("imp-file-a"), H::open("imp-file-b"));
    a.import(json!({"kind": "layer", "paths": [fixture("rally-points.geojson")]}));
    let r = b.nb_ok("import", json!({"path": fixture("rally-points.geojson"), "now": NOW}));
    assert_eq!((r["places"].clone(), r["lines"].clone(), r["areas"].clone(), r["skipped"].clone()), (json!(2), json!(1), json!(1), json!(0)));
    assert_eq!((r["notebook"]["def"]["name"].clone(), r["notebook"]["private"].clone(), r["notebook"]["entries"].clone()), (json!("Rally Points"), json!(true), json!(2)));
    for (tool, args) in [("nearby", json!({"category": "layer_rally_points"})), ("locate", json!({"place": "north gate"}))] {
        assert_eq!(a.tool(tool, args.clone()), b.tool(tool, args.clone()), "{tool}");
    }
    let layers = b.ok(unsafe { cs_userlayers_list(b.h) });
    let y = &layers["layers"][0];
    assert_eq!((y["points"].clone(), y["lines"].clone(), y["areas"].clone(), y["notebook_id"].clone()), (json!(2), json!(1), json!(1), r["notebook"]["id"].clone()));
    // a second import of the same file gets its own name; into an existing notebook it adds places
    let r2 = b.nb_ok("import", json!({"path": fixture("rally-points.geojson")}));
    assert_eq!(r2["notebook"]["def"]["name"], "Rally Points 2");
    let r3 = b.nb_ok("import", json!({"path": fixture("elk-camp.kml"), "notebook_id": r["notebook"]["id"]}));
    assert!(r3["notebook"]["entries"].as_u64().unwrap() > 2);
    // the layer belongs to the notebook
    let id = y["id"].as_str().unwrap();
    assert!(take(unsafe { cs_userlayer_delete(b.h, cstr(id).as_ptr()) }).is_none());
    assert_eq!(b.err()["code"], "bad_json");
    // not a places file
    assert_eq!(b.nb("import", json!({"path": fixture("repeaters-fixture.csv")})).unwrap_err()["code"], "bad_json");
    assert_eq!(b.nb("import", json!({"path": fixture("missing.kml")})).unwrap_err()["code"], "io");
    let journal = b.nb_ok("notebooks", json!({}))["notebooks"].as_array().unwrap().iter().find(|n| n["template"] == "journal").unwrap()["id"].clone();
    assert_eq!(b.nb("import", json!({"path": fixture("trip.gpx"), "notebook_id": journal})).unwrap_err()["code"], "bad_json");
}

#[test]
fn repeater_rows_keep_their_recorded_key_order() {
    let g = golden();
    let h = H::open("repeaters");
    h.import(json!({"kind": "repeaters", "paths": [fixture("repeaters-fixture.kml"), fixture("repeaters-fixture.csv")]}));
    let r = h.content("nearby", json!({"category": "repeater", "limit": 10}));
    let strs = |v: &Value| v.as_array().unwrap().iter().map(|x| x.as_str().unwrap().to_string()).collect::<Vec<_>>();
    let (top, row) = (strs(&g["nearby_repeater_keys"]["top"]), strs(&g["nearby_repeater_keys"]["row"]));
    assert!(subsequence(&keys(&r), &top), "{:?}", keys(&r));
    for p in r["places"].as_array().unwrap() {
        assert!(subsequence(&keys(p), &row), "{:?}", keys(p));
        assert_eq!(keys(p)[..7], row[..7]);
    }
    // the recorded repeater category words
    let rec = g["declarations_with_repeaters"][0]["function"]["parameters"]["properties"]["category"]["description"].as_str().unwrap().to_string();
    let ours = h.nearby()["function"]["parameters"]["properties"]["category"]["description"].as_str().unwrap().to_string();
    assert_eq!(ours.split_once("; repeater = ").unwrap().1, rec.split_once("; repeater = ").unwrap().1);
}
