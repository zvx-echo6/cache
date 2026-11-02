//! The user's map layers and repeater lists through the C ABI: cs_userlayers_import / _list, cs_userlayer_get /
//! _set_visible / _export / _delete, and what the tools see of them (cs_tool_schemas, cs_tool nearby and locate).

use cache_places::fixture::write_fixture_pack;
use cache_search::conv::Conversation;
use cache_search::ffi::*;
use cache_search::handle::Handle;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;

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

fn fixture(f: &str) -> String {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../cache_user/tests/fixtures").join(f).to_string_lossy().into_owned()
}

struct H {
    h: *mut Handle,
    c: *mut Conversation,
    t: Tmp,
}

impl H {
    fn open(name: &str, with_user: bool) -> H {
        let t = Tmp(std::env::temp_dir().join(format!("cs-userlayers-{}-{name}", std::process::id())));
        let _ = std::fs::remove_dir_all(&t.0);
        std::fs::create_dir_all(&t.0).unwrap();
        let pack = t.0.join("places.sqlite");
        write_fixture_pack(&pack);
        let mut cfg = json!({"sources": [], "places": {"packs": [pack]}});
        if with_user {
            cfg["user"] = json!({"db_path": t.0.join("user.sqlite")});
        }
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
    fn import(&self, a: Value) -> Value {
        self.ok(unsafe { cs_userlayers_import(self.h, cstr(&a.to_string()).as_ptr()) })
    }
    fn tool(&self, name: &str, args: Value) -> Value {
        let p = unsafe { cs_tool(self.h, self.c, cstr(name).as_ptr(), cstr(&args.to_string()).as_ptr(), cstr(NOW).as_ptr()) };
        self.ok(p)
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

#[test]
fn import_list_show_hide_export_delete() {
    let h = H::open("crud", true);
    let r = h.import(json!({"kind": "repeaters", "paths": [fixture("repeaters-fixture.kml"), fixture("repeaters-fixture.csv")]}));
    assert_eq!((r["id"].clone(), r["merged"].clone()), (json!("l1"), json!(4)));
    let y = h.import(json!({"kind": "layer", "paths": [fixture("rally-points.geojson")]}));
    assert_eq!((y["id"].clone(), y["private"].clone(), y["category"].clone()), (json!("y2"), json!(true), json!("layer_rally_points")));
    let l = h.ok(unsafe { cs_userlayers_list(h.h) });
    assert_eq!((l["layers"][0]["id"].clone(), l["repeater_lists"][0]["id"].clone()), (json!("y2"), json!("l1")));
    let g = h.ok(unsafe { cs_userlayer_get(h.h, cstr("y2").as_ptr()) });
    assert_eq!(g["features"].as_array().unwrap().len(), 4);
    let v = h.ok(unsafe { cs_userlayer_set_visible(h.h, cstr(r#"{"id":"l1","visible":false}"#).as_ptr()) });
    assert_eq!(v["visible"], false);
    let out = h.t.0.join("rally.gpx");
    let e = h.ok(unsafe { cs_userlayer_export(h.h, cstr(&json!({"id": "y2", "format": "gpx", "path": out}).to_string()).as_ptr()) });
    assert!(e["bytes"].as_u64().unwrap() > 0 && out.exists());
    assert_eq!(h.ok(unsafe { cs_userlayer_delete(h.h, cstr("y2").as_ptr()) }), json!({"deleted": "y2"}));
    assert!(take(unsafe { cs_userlayer_delete(h.h, cstr("y2").as_ptr()) }).is_none());
    assert_eq!(h.err()["code"], "not_found");
    assert!(take(unsafe { cs_userlayers_import(h.h, cstr(r#"{"kind":"layer"}"#).as_ptr()) }).is_none());
    assert_eq!(h.err()["code"], "bad_json");
}

#[test]
fn without_a_user_section_it_is_not_configured() {
    let h = H::open("nouser", false);
    assert!(take(unsafe { cs_userlayers_list(h.h) }).is_none());
    assert_eq!(h.err()["code"], "not_configured");
}

#[test]
fn the_tools_see_hidden_and_private_layers_and_number_their_addresses() {
    let h = H::open("tools", true);
    h.import(json!({"kind": "repeaters", "paths": [fixture("repeaters-fixture.kml"), fixture("repeaters-fixture.csv")]}));
    h.import(json!({"kind": "layer", "paths": [fixture("rally-points.geojson")]}));
    unsafe { take(cs_userlayer_set_visible(h.h, cstr(r#"{"id":"y2","visible":false}"#).as_ptr())) }.unwrap();
    let schemas: Value = serde_json::from_str(&take(unsafe { cs_tool_schemas(h.h) }).unwrap()).unwrap();
    let nearby = schemas.as_array().unwrap().iter().find(|s| s["function"]["name"] == "nearby").unwrap();
    let ids = nearby["function"]["parameters"]["properties"]["category"]["enum"].as_array().unwrap();
    assert_eq!(ids[ids.len() - 2..], [json!("repeater"), json!("layer_rally_points")]);

    let r = h.tool("nearby", json!({"category": "layer_rally_points", "limit": 1}));
    let content: Value = serde_json::from_str(r["content"].as_str().unwrap()).unwrap();
    assert_eq!(content["places"][0]["n"], 1);
    assert_eq!(content["places"][0]["name"], "Canal bridge");
    assert_eq!(r["ids"][0]["address"], "layer:y2/2");
    let r = h.tool("nearby", json!({"category": "repeater", "limit": 1}));
    let content: Value = serde_json::from_str(r["content"].as_str().unwrap()).unwrap();
    assert_eq!((content["places"][0]["n"].clone(), content["places"][0]["frequency"].clone()), (json!(2), json!("927.1625 MHz")));
    assert_eq!(content["repeater_note"], "From the user's imported repeater list; check the settings before transmitting.");
    assert_eq!(r["ids"][0]["address"], "repeater:l1/1");
    let r = h.tool("locate", json!({"place": "north gate"}));
    let content: Value = serde_json::from_str(r["content"].as_str().unwrap()).unwrap();
    assert_eq!((content["kind"].clone(), content["kind_label"].clone(), content["n"].clone()), (json!("layer_point"), json!("Rally Points"), json!(3)));
}

#[test]
fn null_arguments() {
    unsafe {
        assert!(cs_userlayers_import(ptr::null_mut(), ptr::null()).is_null());
    }
    let h = H::open("null", true);
    unsafe {
        assert!(cs_userlayers_import(h.h, ptr::null()).is_null());
        assert!(cs_userlayer_get(h.h, ptr::null()).is_null());
        assert!(cs_userlayer_export(h.h, ptr::null()).is_null());
    }
}
