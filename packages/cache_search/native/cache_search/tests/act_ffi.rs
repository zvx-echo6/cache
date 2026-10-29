//! The act tool through the C ABI: cs_act_set_definitions, cs_act_set_modules_off, cs_tool (needs_confirmation and host_run),
//! cs_act_resolve, cs_act_finish and cs_act_outcome. No callbacks: the host plays the exchanges.

use cache_search::conv::Conversation;
use cache_search::ffi::*;
use cache_search::handle::Handle;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::ptr;

const NOW: &str = "2026-10-29T12:00:00-06:00";

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-acttest-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn defs() -> Value {
    json!([
        {"id":"places.save","module":"places","title":"Save a place","description":"Save a place to the user's saved places.","effect":"change",
         "fields":{"name":{"type":"string","maxLength":80},"place":{"type":"place"},"note":{"type":"string","maxLength":500}},"required":["name","place"]},
        {"id":"places.list","module":"places","title":"List places","description":"The user's saved places.","effect":"read","fields":{}},
        {"id":"places.open","module":"places","title":"Open guidance","description":"Open guidance to a place.","effect":"open","fields":{"to":{"type":"place"}},"required":["to"]},
        {"id":"home.source_switch","module":"home","title":"Switch a source","description":"Turn a Home data source on or off.","effect":"change",
         "fields":{"source":{"type":"string","enum":["wildfires","alerts","weather"]},"on":{"type":"boolean"}},"required":["source","on"]},
        {"id":"book.add","module":"book","title":"Add a contact","description":"Add a contact.","effect":"change",
         "fields":{"address":{"type":"string"},"name":{"type":"string"}},"required":["address"]},
        {"id":"bad id","module":"x","title":"T","description":"D","effect":"read"}
    ])
}

struct Fx {
    _tmp: TempDir,
    h: *mut Handle,
    c: *mut Conversation,
}

impl Fx {
    fn new(name: &str) -> Fx {
        let tmp = TempDir::new(name);
        let cfg = json!({"sources": [], "user": {"db_path": tmp.0.join("user.sqlite").to_str().unwrap()}});
        let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
        assert!(!h.is_null());
        let f = Fx { _tmp: tmp, h, c: cs_conversation_new() };
        take(unsafe { cs_place_save(f.h, cstr(r#"{"key":"home","name":"Home","lat":42.536,"lon":-113.792,"label":"home"}"#).as_ptr()) }).expect("save a place");
        f
    }

    fn install(&self) -> Value {
        serde_json::from_str(&take(unsafe { cs_act_set_definitions(self.h, cstr(&defs().to_string()).as_ptr()) }).unwrap()).unwrap()
    }

    /// cs_tool: the whole `{"content","ids"}` reply.
    fn tool(&self, c: *mut Conversation, name: &str, args: Value) -> Value {
        let p = unsafe { cs_tool(self.h, c, cstr(name).as_ptr(), cstr(&args.to_string()).as_ptr(), cstr(NOW).as_ptr()) };
        serde_json::from_str(&take(p).unwrap()).unwrap()
    }

    /// The content of an act call, parsed.
    fn act(&self, args: Value) -> Value {
        let v = self.tool(self.c, "act", args);
        serde_json::from_str(v["content"].as_str().unwrap()).unwrap()
    }

    fn names(&self) -> Vec<String> {
        let v: Value = serde_json::from_str(&take(unsafe { cs_tool_schemas(self.h) }).unwrap()).unwrap();
        v.as_array().unwrap().iter().map(|s| s["function"]["name"].as_str().unwrap().to_string()).collect()
    }

    fn finish(&self, c: *mut Conversation, run_id: &str, reply: Value) -> Option<String> {
        take(unsafe { cs_act_finish(c, cstr(run_id).as_ptr(), cstr(&reply.to_string()).as_ptr()) })
    }

    fn outcome(&self, c: *mut Conversation, o: Value) -> Option<String> {
        take(unsafe { cs_act_outcome(c, cstr(&o.to_string()).as_ptr()) })
    }
}

impl Drop for Fx {
    fn drop(&mut self) {
        unsafe {
            cs_conversation_free(self.c);
            cs_close(self.h);
        }
    }
}

fn thread_error() -> Value {
    serde_json::from_str(&take(unsafe { cs_last_error(ptr::null_mut()) }).expect("an error was kept")).unwrap()
}

#[test]
fn definitions_install_with_a_report_and_the_tool_appears_after_calculate() {
    let f = Fx::new("install");
    assert_eq!(f.names(), ["search", "read", "calculate"]);
    // act is registered but offers nothing yet: a call is not_set_up
    let v = f.tool(f.c, "act", json!({"action": "places.list"}));
    assert_eq!(v["content"], r#"{"ok":false,"error":{"type":"not_set_up","detail":"act is not set up"}}"#);
    let r = f.install();
    assert_eq!(r["accepted"], 5);
    assert_eq!(r["rejected"][0]["index"], 5);
    assert_eq!(r["rejected"][0]["reason"], "bad_id");
    assert_eq!(r["not_listed"], json!([]));
    assert_eq!(f.names(), ["search", "read", "calculate", "act"]);
    let schemas: Value = serde_json::from_str(&take(unsafe { cs_tool_schemas(f.h) }).unwrap()).unwrap();
    let d = schemas[3]["function"]["description"].as_str().unwrap();
    assert!(d.starts_with("Do something in one of the app's modules."), "{d}");
    assert!(d.contains("\nplaces.save(name:string, place:place, note:string) - Save a place") == false, "required fields carry a star: {d}");
    assert!(d.contains("\nplaces.save(name:string*, place:place*, note:string) - Save a place to the user's saved places. (confirm)\n"), "{d}");
    assert!(d.ends_with("\nbook.add(address:string*, name:string) - Add a contact. (confirm)"), "{d}");
    // a definition list that is not an array is refused, and nothing changes
    assert!(take(unsafe { cs_act_set_definitions(f.h, cstr("{}").as_ptr()) }).is_none());
    assert!(take(unsafe { cs_act_set_definitions(f.h, ptr::null()) }).is_none());
    assert!(take(unsafe { cs_act_set_definitions(f.h, cstr("nope").as_ptr()) }).is_none());
    assert_eq!(f.names(), ["search", "read", "calculate", "act"]);
    assert!(take(unsafe { cs_act_set_definitions(ptr::null_mut(), cstr("[]").as_ptr()) }).is_none());
}

#[test]
fn modules_off_hide_their_actions_and_answer_not_set_up() {
    let f = Fx::new("off");
    f.install();
    assert_eq!(unsafe { cs_act_set_modules_off(f.h, cstr(r#"["places"]"#).as_ptr()) }, 0);
    let v = f.act(json!({"action": "places.list"}));
    assert_eq!(v, json!({"ok": false, "error": {"type": "not_set_up", "detail": "places is not set up"}}));
    let schemas: Value = serde_json::from_str(&take(unsafe { cs_tool_schemas(f.h) }).unwrap()).unwrap();
    assert!(!schemas[3]["function"]["description"].as_str().unwrap().contains("places."));
    let r: Value = serde_json::from_str(&take(unsafe { cs_act_resolve(f.h, cstr("places.list").as_ptr(), ptr::null()) }).unwrap()).unwrap();
    assert_eq!(r["error"]["type"], "not_set_up");
    // all off: the tool is gone; NULL or [] switches them back on
    assert_eq!(unsafe { cs_act_set_modules_off(f.h, cstr(r#"["places","home","book"]"#).as_ptr()) }, 0);
    assert_eq!(f.names(), ["search", "read", "calculate"]);
    assert_eq!(unsafe { cs_act_set_modules_off(f.h, ptr::null()) }, 0);
    assert_eq!(f.names().len(), 4);
    // a bad value changes nothing
    assert_eq!(unsafe { cs_act_set_modules_off(f.h, cstr(r#"[1]"#).as_ptr()) }, -1);
    assert_eq!(unsafe { cs_act_set_modules_off(f.h, cstr(r#"{}"#).as_ptr()) }, -1);
    assert_eq!(unsafe { cs_act_set_modules_off(ptr::null_mut(), ptr::null()) }, -1);
    assert_eq!(f.names().len(), 4);
}

#[test]
fn a_change_call_is_a_card_with_a_confirm_id_and_resolve_gives_the_machine_values() {
    let f = Fx::new("card");
    f.install();
    let v = f.tool(f.c, "act", json!({"action": "places.save", "fields": {"name": "Elk camp", "place": "44.21,-114.93"}}));
    assert_eq!(
        v["content"],
        r#"{"ok":true,"status":"needs_confirmation","confirm_id":"c1","action":"places.save","title":"Save a place","summary":{"name":"Elk camp","place":"44.21000, -114.93000"}}"#
    );
    assert_eq!(v["ids"], json!([]));
    let c2 = f.act(json!({"action": "places.save", "fields": {"name": "Camp", "place": "home"}}));
    assert_eq!(c2["confirm_id"], "c2");
    assert_eq!(c2["summary"]["place"], "Home (42.53600, -113.79200)");
    // cs_act_resolve: same checks, place objects, no ids taken
    let r = take(unsafe { cs_act_resolve(f.h, cstr("places.save").as_ptr(), cstr(r#"{"name":"Camp","place":"home"}"#).as_ptr()) }).unwrap();
    assert_eq!(
        r,
        r#"{"ok":true,"action":"places.save","fields":{"name":"Camp","place":{"lat":42.536,"lon":-113.792,"name":"Home","label":"home"}}}"#
    );
    let r = take(unsafe { cs_act_resolve(f.h, cstr("places.list").as_ptr(), ptr::null()) }).unwrap();
    assert_eq!(r, r#"{"ok":true,"action":"places.list","fields":{}}"#);
    let r = take(unsafe { cs_act_resolve(f.h, cstr("places.save").as_ptr(), cstr(r#"{"name":"Camp"}"#).as_ptr()) }).unwrap();
    assert_eq!(r, r#"{"ok":false,"error":{"type":"bad_arguments","detail":"place: required","field":"place","reason":"missing"}}"#);
    let r = take(unsafe { cs_act_resolve(f.h, cstr("nope.x").as_ptr(), ptr::null()) }).unwrap();
    assert_eq!(r, r#"{"ok":false,"error":{"type":"unknown_action","detail":"no action named nope.x"}}"#);
    assert_eq!(f.act(json!({"action": "home.source_switch", "fields": {"source": "alerts", "on": true}}))["confirm_id"], "c3");
    assert!(take(unsafe { cs_act_resolve(f.h, ptr::null(), ptr::null()) }).is_none());
    assert!(take(unsafe { cs_act_resolve(f.h, cstr("places.list").as_ptr(), cstr("nope").as_ptr()) }).is_none());
    assert!(take(unsafe { cs_act_resolve(ptr::null_mut(), cstr("places.list").as_ptr(), ptr::null()) }).is_none());
}

#[test]
fn bad_act_calls_are_content_with_field_and_reason() {
    let f = Fx::new("bad");
    f.install();
    let c = |args: Value| f.tool(f.c, "act", args)["content"].as_str().unwrap().to_string();
    assert_eq!(c(json!({})), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"action: required","field":"action","reason":"missing"}}"#);
    assert_eq!(c(json!({"action":"places.list","fields":3})), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"fields: must be an object","field":"fields","reason":"wrong_type"}}"#);
    assert_eq!(c(json!({"action":"nope.x"})), r#"{"ok":false,"error":{"type":"unknown_action","detail":"no action named nope.x"}}"#);
    assert_eq!(
        c(json!({"action":"places.save","fields":{"name":"n","place":"Nowhere"}})),
        r#"{"ok":false,"error":{"type":"place_not_found","detail":"no place matches \"Nowhere\"","field":"place","query":"Nowhere"}}"#
    );
    // a failure takes no confirm id and no run id
    assert_eq!(f.act(json!({"action":"home.source_switch","fields":{"source":"alerts","on":true}}))["confirm_id"], "c1");
    assert_eq!(f.act(json!({"action":"places.list"}))["run_id"], "r1");
}

#[test]
fn a_read_is_handed_to_the_host_and_finished_once_with_its_addresses_numbered() {
    let f = Fx::new("run");
    f.install();
    // a source seen earlier keeps its number
    f.tool(f.c, "calculate", json!({"expression": "1+1"}));
    let v = f.tool(f.c, "act", json!({"action": "places.open", "fields": {"to": "home"}}));
    assert_eq!(
        v["content"],
        r#"{"ok":true,"status":"host_run","run_id":"r1","action":"places.open","fields":{"to":{"lat":42.536,"lon":-113.792,"name":"Home","label":"home"}}}"#
    );
    assert_eq!(v["ids"], json!([]));
    let run2 = f.act(json!({"action": "places.list"}));
    assert_eq!(run2["run_id"], "r2");

    let reply = json!({"ok": true, "result": {"places": [{"address": "place:home", "name": "Home"}, {"address": "place:elk", "name": "Elk camp"}, {"address": "place:home", "name": "Home again"}]}});
    let out = f.finish(f.c, "r2", reply.clone()).unwrap();
    assert_eq!(
        out,
        r#"{"ok":true,"status":"done","action":"places.list","result":{"places":[{"n":1,"name":"Home"},{"n":2,"name":"Elk camp"},{"n":1,"name":"Home again"}]}}"#
    );
    // the addresses are in the id map now, and the next source continues from them
    let ids = take(unsafe { cs_conversation_ids(f.c) }).unwrap();
    assert_eq!(ids, r#"{"ids":[{"n":1,"address":"place:home","title":"Home"},{"n":2,"address":"place:elk","title":"Elk camp"}]}"#);
    let fm = take(unsafe { cs_format(f.c, cstr(r#"[{"address":"x:new","title":"New","snippet":""}]"#).as_ptr()) }).unwrap();
    assert!(fm.contains(r#""n":3"#), "{fm}");

    // a run is finished once; the other run is still pending
    assert!(f.finish(f.c, "r2", reply).is_none());
    let e = thread_error();
    assert_eq!(e["code"], "not_found");
    assert!(e["message"].as_str().unwrap().contains("already finished"), "{e}");
    assert_eq!(
        f.finish(f.c, "r1", json!({"ok": true, "result": {"opened": "Guidance to Home"}})).unwrap(),
        r#"{"ok":true,"status":"done","action":"places.open","result":{"opened":"Guidance to Home"}}"#
    );
}

#[test]
fn a_host_failure_is_the_shared_error_shape_and_still_finishes_the_run() {
    let f = Fx::new("fail");
    f.install();
    f.act(json!({"action": "places.list"}));
    let out = f.finish(f.c, "r1", json!({"ok": false, "error": {"type": "unavailable", "detail": "Places is not ready"}})).unwrap();
    assert_eq!(out, r#"{"ok":false,"error":{"type":"unavailable","detail":"Places is not ready"}}"#);
    assert!(f.finish(f.c, "r1", json!({"ok": true, "result": {}})).is_none());
}

#[test]
fn unknown_runs_runs_of_another_conversation_and_bad_replies_fail_and_change_nothing() {
    let f = Fx::new("badrun");
    f.install();
    let other = cs_conversation_new();
    assert_eq!(f.act(json!({"action": "places.list"}))["run_id"], "r1");
    // another conversation has no r1
    assert!(f.finish(other, "r1", json!({"ok": true, "result": {}})).is_none());
    let e = thread_error();
    assert_eq!((e["code"].as_str(), e["message"].as_str()), (Some("not_found"), Some("no run r1 in this conversation")));
    assert!(f.finish(f.c, "r9", json!({"ok": true, "result": {}})).is_none());
    assert_eq!(thread_error()["code"], "not_found");
    // malformed replies are bad_json and leave the run pending
    for bad in [json!([]), json!({}), json!({"ok": true}), json!({"ok": false}), json!({"ok": false, "error": {}}), json!({"ok": "yes", "result": 1})] {
        assert!(f.finish(f.c, "r1", bad.clone()).is_none(), "{bad}");
        assert_eq!(thread_error()["code"], "bad_json", "{bad}");
    }
    assert!(take(unsafe { cs_act_finish(f.c, cstr("r1").as_ptr(), cstr("not json").as_ptr()) }).is_none());
    assert_eq!(thread_error()["code"], "bad_json");
    assert!(take(unsafe { cs_act_finish(f.c, ptr::null(), cstr("{}").as_ptr()) }).is_none());
    assert!(take(unsafe { cs_act_finish(f.c, cstr("r1").as_ptr(), ptr::null()) }).is_none());
    assert!(take(unsafe { cs_act_finish(ptr::null_mut(), cstr("r1").as_ptr(), cstr("{}").as_ptr()) }).is_none());
    assert!(f.finish(f.c, "r1", json!({"ok": true, "result": {"fine": true}})).is_some());
    unsafe { cs_conversation_free(other) };
}

#[test]
fn an_outcome_is_the_system_message_content_with_its_addresses_numbered() {
    let f = Fx::new("outcome");
    f.install();
    f.act(json!({"action": "places.save", "fields": {"name": "Elk camp", "place": "44.2,-114.9"}}));
    let done = f.outcome(f.c, json!({"ok": true, "status": "done", "confirm_id": "c1", "action": "places.save", "result": {"saved": {"address": "place:elk", "name": "Elk camp"}}}));
    assert_eq!(
        done.unwrap(),
        r#"{"host_event":"act_outcome","ok":true,"status":"done","confirm_id":"c1","action":"places.save","result":{"saved":{"n":1,"name":"Elk camp"}}}"#
    );
    assert_eq!(take(unsafe { cs_conversation_ids(f.c) }).unwrap(), r#"{"ids":[{"n":1,"address":"place:elk","title":"Elk camp"}]}"#);
    assert_eq!(
        f.outcome(f.c, json!({"ok": true, "status": "declined", "confirm_id": "c2", "action": "places.save"})).unwrap(),
        r#"{"host_event":"act_outcome","ok":true,"status":"declined","confirm_id":"c2","action":"places.save"}"#
    );
    assert_eq!(
        f.outcome(f.c, json!({"ok": false, "status": "failed", "confirm_id": "c3", "action": "places.save", "error": {"type": "io", "detail": "disk full"}})).unwrap(),
        r#"{"host_event":"act_outcome","ok":false,"status":"failed","confirm_id":"c3","action":"places.save","error":{"type":"io","detail":"disk full"}}"#
    );
    // the same address in a later outcome keeps its number
    let again = f.outcome(f.c, json!({"ok": true, "status": "done", "confirm_id": "c4", "action": "places.save", "result": {"address": "place:elk"}})).unwrap();
    assert!(again.ends_with(r#""result":{"n":1}}"#), "{again}");

    for bad in [
        json!({"ok": true, "status": "ran", "confirm_id": "c1", "action": "a.b"}),
        json!({"ok": true, "status": "done", "confirm_id": "c1", "action": "a.b"}),
        json!({"ok": false, "status": "done", "confirm_id": "c1", "action": "a.b", "result": {}}),
        json!({"ok": false, "status": "failed", "confirm_id": "c1", "action": "a.b"}),
        json!({"ok": true, "status": "declined", "action": "a.b"}),
        json!({"ok": true, "status": "declined", "confirm_id": "c1"}),
        json!([]),
    ] {
        assert!(f.outcome(f.c, bad.clone()).is_none(), "{bad}");
        assert_eq!(thread_error()["code"], "bad_json", "{bad}");
    }
    assert!(take(unsafe { cs_act_outcome(f.c, ptr::null()) }).is_none());
    assert!(take(unsafe { cs_act_outcome(f.c, cstr("nope").as_ptr()) }).is_none());
    assert!(take(unsafe { cs_act_outcome(ptr::null_mut(), cstr("{}").as_ptr()) }).is_none());
    // nothing above numbered anything it should not have
    assert_eq!(take(unsafe { cs_conversation_ids(f.c) }).unwrap(), r#"{"ids":[{"n":1,"address":"place:elk","title":"Elk camp"}]}"#);
}

#[test]
fn a_field_called_address_is_the_users_value_not_a_citation() {
    let f = Fx::new("addr");
    f.install();
    let v = f.tool(f.c, "act", json!({"action": "book.add", "fields": {"address": "12 Elm St", "name": "Ann"}}));
    assert_eq!(
        v["content"],
        r#"{"ok":true,"status":"needs_confirmation","confirm_id":"c1","action":"book.add","title":"Add a contact","summary":{"address":"12 Elm St","name":"Ann"}}"#
    );
    assert_eq!(v["ids"], json!([]));
    let r = take(unsafe { cs_act_resolve(f.h, cstr("book.add").as_ptr(), cstr(r#"{"address":"12 Elm St"}"#).as_ptr()) }).unwrap();
    assert_eq!(r, r#"{"ok":true,"action":"book.add","fields":{"address":"12 Elm St"}}"#);
    assert_eq!(take(unsafe { cs_conversation_ids(f.c) }).unwrap(), r#"{"ids":[]}"#);
}

#[test]
fn confirm_ids_continue_after_an_export_and_import_and_pending_runs_do_not() {
    let f = Fx::new("export");
    f.install();
    let fresh = take(unsafe { cs_conversation_export(f.c) }).unwrap();
    assert_eq!(fresh, r#"{"format":1,"next_n":1,"ids":[],"web_hits":{}}"#);
    f.act(json!({"action": "home.source_switch", "fields": {"source": "alerts", "on": true}}));
    f.act(json!({"action": "home.source_switch", "fields": {"source": "alerts", "on": false}}));
    f.act(json!({"action": "places.list"}));
    let e = take(unsafe { cs_conversation_export(f.c) }).unwrap();
    assert_eq!(e, r#"{"format":1,"next_n":1,"ids":[],"web_hits":{},"confirms":2}"#);
    let c2 = unsafe { cs_conversation_import(cstr(&e).as_ptr()) };
    assert!(!c2.is_null());
    assert_eq!(f.tool(c2, "act", json!({"action": "home.source_switch", "fields": {"source": "weather", "on": true}}))["content"].as_str().unwrap().contains(r#""confirm_id":"c3""#), true);
    // the run that was pending before the export is not in the copy
    assert!(f.finish(c2, "r1", json!({"ok": true, "result": {}})).is_none());
    assert_eq!(thread_error()["code"], "not_found");
    // the original still has it
    assert!(f.finish(f.c, "r1", json!({"ok": true, "result": {}})).is_some());
    unsafe { cs_conversation_free(c2) };
}
