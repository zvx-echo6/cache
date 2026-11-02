//! The act tool through its public API: installing definitions, the description the model reads, the checks, the confirm and
//! host-run exchanges, and the host's reply and outcome.

use cache_act::reply::{self, Reply};
use cache_act::{ActState, ActTool};
use cache_tool::places::Geocoder;
use cache_tool::{ConvState, Location, SavedPlace, SavedPlaces, Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Value};

struct Saved;
impl SavedPlaces for Saved {
    fn resolve(&self, name: &str) -> Option<SavedPlace> {
        self.list().into_iter().find(|p| p.name.eq_ignore_ascii_case(name) || p.key == name)
    }
    fn list(&self) -> Vec<SavedPlace> {
        vec![
            SavedPlace { key: "home".into(), name: "Home".into(), lat: 42.536, lon: -113.792, label: Some("home".into()) },
            SavedPlace { key: "elk".into(), name: "Elk camp".into(), lat: 44.2, lon: -114.9, label: None },
        ]
    }
}

struct Pack;
impl Geocoder for Pack {
    fn resolve(&self, text: &str, near: Option<(f64, f64)>) -> Option<(String, f64, f64)> {
        match text {
            "Stanley" => Some(("Stanley, ID".into(), 44.2216, -114.9362)),
            // the fix is what the caller prefers: a near point makes the answer say so
            "Springfield" => Some((if near.is_some() { "Springfield, ID" } else { "Springfield, IL" }.into(), 43.0, -112.0)),
            _ => None,
        }
    }
    fn describe_point(&self, lat: f64, _lon: f64) -> Option<String> {
        if (lat - 44.21).abs() < 0.001 { Some("12 mi NE of Stanley".into()) } else { None }
    }
}

const NOW: &str = "2026-10-29T12:00:00-06:00";

fn with_ctx<T>(geo: bool, fix: bool, f: impl FnOnce(&ToolCtx) -> T) -> T {
    let loc = Location { lat: 43.1, lon: -112.1, accuracy_m: None, fixed_at: NOW.into() };
    let ctx = ToolCtx { location: if fix { Some(&loc) } else { None }, places: &Saved, now: NOW, geocoder: if geo { Some(&Pack) } else { None }, live_fetcher: None };
    f(&ctx)
}

fn defs() -> Value {
    json!([
        {"id":"places.save","module":"places","title":"Save a place","description":"Save a place to the user's saved places.","effect":"change",
         "fields":{"name":{"type":"string","maxLength":80},"place":{"type":"place"},"note":{"type":"string","maxLength":500}},"required":["name","place"]},
        {"id":"places.list","module":"places","title":"List places","description":"The user's saved places.","effect":"read","fields":{}},
        {"id":"home.source_switch","module":"home","title":"Switch a source","description":"Turn a Home data source on or off.","effect":"change",
         "fields":{"source":{"type":"string","enum":["wildfires","alerts","weather"]},"on":{"type":"boolean"}},"required":["source","on"]},
        {"id":"places.open","module":"places","title":"Open guidance","description":"Open guidance to a saved place.","effect":"open",
         "fields":{"to":{"type":"place"}},"required":["to"]},
        {"id":"log.add","module":"log","title":"Add a log entry","description":"Add an entry to the radio log.","effect":"change",
         "fields":{"count":{"type":"integer","minimum":1,"maximum":10},"level":{"type":"number","minimum":0.5,"maximum":9.5},
                   "day":{"type":"date"},"at":{"type":"time"},"for":{"type":"duration"},"text":{"type":"string","maxLength":10}},"required":[]}
    ])
}

fn installed() -> ActState {
    let a = ActState::new();
    let r = a.set_definitions(&defs()).unwrap();
    assert_eq!(r["accepted"], 5, "{r}");
    a
}

/// The call as the framework would run it: the output JSON, or the error JSON.
fn call(a: &ActState, st: &mut ConvState, args: Value) -> String {
    with_ctx(true, true, |ctx| match a.call(ctx, &args, st) {
        Ok(ToolOutput::Json(v)) => v.to_string(),
        Ok(ToolOutput::Text(t)) => t,
        Err(e) => e.to_json().to_string(),
    })
}

fn act(a: &ActState, args: Value) -> String {
    call(a, &mut ConvState::default(), args)
}

// ---- what the model sees ----

#[test]
fn the_description_is_the_contracts_text_byte_for_byte() {
    let a = ActState::new();
    a.set_definitions(&json!([defs()[0], defs()[1], defs()[2]])).unwrap();
    let s = a.schema().unwrap();
    assert_eq!(
        s["function"]["description"].as_str().unwrap(),
        "Do something in one of the app's modules. Actions marked (confirm) show the user a confirm card; nothing changes until they tap it. * = required. Actions:\n\
places.save(name:string*, place:place*, note:string) - Save a place to the user's saved places. (confirm)\n\
places.list() - The user's saved places.\n\
home.source_switch(source:wildfires|alerts|weather*, on:boolean*) - Turn a Home data source on or off. (confirm)"
    );
}

#[test]
fn the_schema_is_two_bare_parameters_with_no_enum_on_action() {
    let a = ActState::new();
    a.set_definitions(&json!([defs()[1]])).unwrap();
    assert_eq!(
        serde_json::to_string(&a.schema().unwrap()).unwrap(),
        r#"{"type":"function","function":{"name":"act","description":"Do something in one of the app's modules. Actions marked (confirm) show the user a confirm card; nothing changes until they tap it. * = required. Actions:\nplaces.list() - The user's saved places.","parameters":{"type":"object","properties":{"action":{"type":"string"},"fields":{"type":"object"}},"required":["action"],"additionalProperties":false}}}"#
    );
    assert_eq!(ActTool(std::sync::Arc::new(ActState::new())).name(), "act");
}

#[test]
fn every_field_type_renders_as_its_word_and_all_other_keys_stay_out() {
    let a = installed();
    let d = a.schema().unwrap()["function"]["description"].as_str().unwrap().to_string();
    assert!(d.contains("\nlog.add(count:integer, level:number, day:date, at:time, for:duration, text:string) - Add an entry to the radio log. (confirm)"), "{d}");
    assert!(d.contains("\nplaces.open(to:place*) - Open guidance to a saved place.\n"), "{d}");
}

#[test]
fn nothing_installed_or_every_module_off_offers_no_tool() {
    let a = ActState::new();
    assert!(a.schema().is_none());
    a.set_definitions(&defs()).unwrap();
    assert!(a.schema().is_some());
    a.set_modules_off(vec!["places".into(), "home".into(), "log".into()]);
    assert!(a.schema().is_none());
    a.set_modules_off(vec!["places".into()]);
    let d = a.schema().unwrap()["function"]["description"].as_str().unwrap().to_string();
    assert!(!d.contains("places.") && d.contains("home.source_switch") && d.contains("log.add"), "{d}");
    a.set_modules_off(vec![]);
    assert!(a.schema().unwrap()["function"]["description"].as_str().unwrap().contains("places.save"));
}

#[test]
fn installing_replaces_and_a_non_array_is_refused() {
    let a = installed();
    assert!(a.set_definitions(&json!({"id": "x.y"})).is_err());
    assert!(a.schema().is_some(), "a refused install changes nothing");
    let r = a.set_definitions(&json!([])).unwrap();
    assert_eq!(r.to_string(), r#"{"accepted":0,"rejected":[],"not_listed":[]}"#);
    assert!(a.schema().is_none());
}

#[test]
fn only_forty_are_listed_the_rest_are_reported_and_stay_callable() {
    let many: Vec<Value> = (0..43)
        .map(|i| json!({"id": format!("m.a{i}"), "module": "m", "title": "T", "description": "D", "effect": "read", "fields": {}}))
        .collect();
    let a = ActState::new();
    let r = a.set_definitions(&Value::Array(many)).unwrap();
    assert_eq!(r["accepted"], 43);
    assert_eq!(r["not_listed"], json!(["m.a40", "m.a41", "m.a42"]));
    let d = a.schema().unwrap()["function"]["description"].as_str().unwrap().to_string();
    assert_eq!(d.lines().count(), 41);
    assert!(d.contains("m.a39()") && !d.contains("m.a40"));
    let mut st = ConvState::default();
    let out = call(&a, &mut st, json!({"action": "m.a42"}));
    assert_eq!(out, r#"{"ok":true,"status":"host_run","run_id":"r1","action":"m.a42","fields":{}}"#);
}

// ---- refusing definitions ----

fn rejects(def: Value) -> (String, Value) {
    let a = ActState::new();
    let r = a.set_definitions(&json!([def])).unwrap();
    assert_eq!(r["accepted"], 0, "{r}");
    let rej = r["rejected"][0].clone();
    (rej["reason"].as_str().unwrap().to_string(), rej)
}

fn base() -> Value {
    json!({"id":"a.b","module":"a","title":"T","description":"D","effect":"read","fields":{}})
}

fn with(k: &str, v: Value) -> Value {
    let mut b = base();
    b[k] = v;
    b
}

fn field(spec: Value) -> Value {
    with("fields", json!({"f": spec}))
}

#[test]
fn each_broken_rule_is_refused_with_its_reason() {
    let long = |n: usize| "x".repeat(n);
    let cases: Vec<(&str, Value)> = vec![
        ("not_object", json!("places.save")),
        ("bad_id", with("id", json!("Places.save"))),
        ("bad_id", with("id", json!("places"))),
        ("bad_id", with("id", json!(".save"))),
        ("bad_id", with("id", json!("a."))),
        ("bad_id", with("id", json!(format!("a.{}", long(47))))),
        ("bad_id", with("id", json!("a.b c"))),
        ("bad_id", json!({"module":"a","title":"T","description":"D","effect":"read"})),
        ("module_mismatch", with("module", json!("b"))),
        ("bad_title", with("title", json!(long(41)))),
        ("bad_title", with("title", json!(""))),
        ("bad_description", with("description", json!(long(121)))),
        ("bad_description", with("description", json!("two\nlines"))),
        ("bad_effect", with("effect", json!("write"))),
        ("bad_effect", json!({"id":"a.b","module":"a","title":"T","description":"D"})),
        ("bad_fields", with("fields", json!([]))),
        ("too_many_fields", with("fields", Value::Object((0..11).map(|i| (format!("f{i}"), json!({"type":"boolean"}))).collect()))),
        ("bad_field_name", with("fields", json!({"Bad":{"type":"boolean"}}))),
        ("bad_field_name", with("fields", json!({"has space":{"type":"boolean"}}))),
        ("bad_field_type", field(json!({"type":"color"}))),
        ("bad_field_type", field(json!("string"))),
        ("bad_field_key", field(json!({"type":"number","maxLength":5}))),
        ("bad_field_key", field(json!({"type":"boolean","enum":["a"]}))),
        ("bad_field_key", field(json!({"type":"string","minimum":1}))),
        ("bad_enum", field(json!({"type":"string","enum":[]}))),
        ("bad_enum", field(json!({"type":"string","enum":["a","a"]}))),
        ("bad_enum", field(json!({"type":"string","enum":["a|b"]}))),
        ("bad_enum", field(json!({"type":"string","enum":["a\nb"]}))),
        ("bad_enum", field(json!({"type":"string","enum":[1]}))),
        ("bad_enum", field(json!({"type":"string","enum":[""]}))),
        ("bad_enum", field(json!({"type":"string","maxLength":2,"enum":["abc"]}))),
        ("bad_enum", field(json!({"type":"string","enum":"abc"}))),
        ("bad_limit", field(json!({"type":"string","maxLength":0}))),
        ("bad_limit", field(json!({"type":"string","maxLength":"5"}))),
        ("bad_limit", field(json!({"type":"number","minimum":5,"maximum":1}))),
        ("bad_limit", field(json!({"type":"number","minimum":"x"}))),
        ("bad_limit", field(json!({"type":"integer","minimum":1.5}))),
        ("bad_field_description", field(json!({"type":"boolean","description":long(81)}))),
        ("bad_required", with("required", json!(["nope"]))),
        ("bad_required", with("required", json!("f"))),
        ("bad_required", {
            let mut d = field(json!({"type":"boolean"}));
            d["required"] = json!(["f", "f"]);
            d
        }),
    ];
    for (reason, def) in cases {
        let (got, rej) = rejects(def.clone());
        assert_eq!(got, reason, "{def} -> {rej}");
    }
}

#[test]
fn limits_at_the_edge_are_accepted() {
    let a = ActState::new();
    let ok = json!([
        {"id": format!("a.{}", "x".repeat(46)), "module": "a", "title": "x".repeat(40), "description": "y".repeat(120), "effect": "change",
         "fields": Value::Object((0..10).map(|i| (format!("f{i}"), json!({"type":"string","description":"z".repeat(80)}))).collect())},
        {"id":"a.n","module":"a","title":"T","description":"D","effect":"read","fields":{"i":{"type":"integer","minimum":3.0,"maximum":3},"s":{"type":"string","maxLength":3,"enum":["abc"]}}}
    ]);
    let r = a.set_definitions(&ok).unwrap();
    assert_eq!(r["accepted"], 2, "{r}");
}

#[test]
fn a_bad_definition_does_not_stop_the_others_and_unknown_keys_are_ignored() {
    let a = ActState::new();
    let mut good = base();
    good["colour"] = json!("red");
    good["fields"] = json!({"f": {"type": "boolean", "whatever": 1}});
    let r = a.set_definitions(&json!([with("effect", json!("x")), good, json!(7), base()])).unwrap();
    assert_eq!(r["accepted"], 1);
    assert_eq!(
        r.to_string(),
        r#"{"accepted":1,"rejected":[{"index":0,"id":"a.b","reason":"bad_effect","detail":"effect must be read, open or change"},{"index":2,"reason":"not_object","detail":"a definition must be a JSON object"},{"index":3,"id":"a.b","reason":"duplicate_id","detail":"a.b is already installed"}],"not_listed":[]}"#
    );
}

#[test]
fn a_rejection_of_a_field_names_it() {
    let a = ActState::new();
    let r = a.set_definitions(&json!([field(json!({"type":"number","maxLength":5}))])).unwrap();
    assert_eq!(r["rejected"][0]["field"], "f");
}

// ---- checking a call ----

#[test]
fn a_call_is_checked_against_its_definition_with_field_and_reason() {
    let a = installed();
    let long = "x".repeat(81);
    let cases: Vec<(Value, &str)> = vec![
        (json!({"action":"nope.x"}), r#"{"ok":false,"error":{"type":"unknown_action","detail":"no action named nope.x"}}"#),
        (json!({"action":"places.save","fields":{"name":"a","place":"Home","bogus":1}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"bogus: not allowed","field":"bogus","reason":"unknown_field"}}"#),
        (json!({"action":"places.save","fields":{"place":"Home"}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"name: required","field":"name","reason":"missing"}}"#),
        (json!({"action":"places.save","fields":{"name":"a"}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"place: required","field":"place","reason":"missing"}}"#),
        (json!({"action":"places.save","fields":{"name":5,"place":"Home"}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"name: must be a string","field":"name","reason":"wrong_type"}}"#),
        (json!({"action":"places.save","fields":{"name":long,"place":"Home"}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"name: must be at most 80 characters","field":"name","reason":"too_long"}}"#),
        (json!({"action":"home.source_switch","fields":{"source":"tides","on":true}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"source: must be one of wildfires, alerts, weather","field":"source","reason":"not_allowed"}}"#),
        (json!({"action":"home.source_switch","fields":{"source":"alerts","on":"yes"}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"on: must be true or false","field":"on","reason":"wrong_type"}}"#),
        (json!({"action":"log.add","fields":{"count":0}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"count: must be at least 1","field":"count","reason":"out_of_range"}}"#),
        (json!({"action":"log.add","fields":{"count":11}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"count: must be at most 10","field":"count","reason":"out_of_range"}}"#),
        (json!({"action":"log.add","fields":{"count":2.0}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"count: must be an integer","field":"count","reason":"wrong_type"}}"#),
        (json!({"action":"log.add","fields":{"count":"2"}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"count: must be an integer","field":"count","reason":"wrong_type"}}"#),
        (json!({"action":"log.add","fields":{"level":0.4}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"level: must be at least 0.5","field":"level","reason":"out_of_range"}}"#),
        (json!({"action":"log.add","fields":{"level":9.6}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"level: must be at most 9.5","field":"level","reason":"out_of_range"}}"#),
        (json!({"action":"log.add","fields":{"day":"2026-02-30"}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"day: must be a date written YYYY-MM-DD","field":"day","reason":"bad_format"}}"#),
        (json!({"action":"log.add","fields":{"at":"25:00"}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"at: must be a time written HH:MM (24-hour)","field":"at","reason":"bad_format"}}"#),
        (json!({"action":"log.add","fields":{"for":"20 minutes"}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"for: must be an ISO 8601 duration of whole numbers, such as PT20M or P2D","field":"for","reason":"bad_format"}}"#),
        (json!({"action":"log.add","fields":{"day":20261029}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"day: must be a string","field":"day","reason":"wrong_type"}}"#),
        (json!({"action":"log.add","fields":{"text":"héllo wörld!"}}), r#"{"ok":false,"error":{"type":"bad_arguments","detail":"text: must be at most 10 characters","field":"text","reason":"too_long"}}"#),
    ];
    for (args, want) in cases {
        assert_eq!(act(&a, args.clone()), want, "{args}");
    }
    // characters, not bytes: 10 two-byte letters are fine
    assert!(act(&a, json!({"action":"log.add","fields":{"text":"éééééééééé"}})).contains("needs_confirmation"));
}

#[test]
fn problems_are_found_in_a_fixed_order() {
    let a = installed();
    // unknown field before a missing one; a missing one before a wrong value
    assert!(act(&a, json!({"action":"places.save","fields":{"zzz":1}})).contains(r#""field":"zzz""#));
    assert!(act(&a, json!({"action":"places.save","fields":{"name":5}})).contains(r#""field":"place","reason":"missing""#));
    // values in the definition's order, whatever order the call gave them
    let out = act(&a, json!({"action":"log.add","fields":{"text":"x".repeat(11),"count":0}}));
    assert!(out.contains(r#""field":"count""#), "{out}");
    // place lookup only after every value has passed
    let out = act(&a, json!({"action":"places.save","fields":{"name":"x".repeat(81),"place":"Nowhere at all"}}));
    assert!(out.contains(r#""reason":"too_long""#), "{out}");
}

#[test]
fn null_means_left_out_and_a_blank_required_string_is_missing() {
    let a = installed();
    let ok = act(&a, json!({"action":"places.save","fields":{"name":"Elk","place":"1,2","note":null}}));
    assert!(ok.contains("needs_confirmation") && !ok.contains("note"), "{ok}");
    for (fields, f) in [
        (json!({"name":null,"place":"1,2"}), "name"),
        (json!({"name":"","place":"1,2"}), "name"),
        (json!({"name":"   ","place":"1,2"}), "name"),
        (json!({"name":"a","place":"  "}), "place"),
        (json!({"name":"a","place":null}), "place"),
    ] {
        let out = act(&a, json!({"action":"places.save","fields":fields.clone()}));
        assert_eq!(out, format!(r#"{{"ok":false,"error":{{"type":"bad_arguments","detail":"{f}: required","field":"{f}","reason":"missing"}}}}"#), "{fields}");
    }
    // a blank optional string is allowed (the module decides); null for an unknown field is still unknown
    assert!(act(&a, json!({"action":"places.save","fields":{"name":"a","place":"1,2","note":""}})).contains("needs_confirmation"));
    assert!(act(&a, json!({"action":"places.save","fields":{"name":"a","place":"1,2","zzz":null}})).contains("unknown_field"));
}

#[test]
fn the_top_level_arguments_are_checked_with_field_and_reason() {
    let a = installed();
    let cases = [
        (json!({}), "action", "missing"),
        (json!({"fields":{}}), "action", "missing"),
        (json!({"action":null}), "action", "missing"),
        (json!({"action":7}), "action", "wrong_type"),
        (json!({"action":"places.list","fields":[]}), "fields", "wrong_type"),
        (json!({"action":"places.list","fields":"x"}), "fields", "wrong_type"),
        (json!({"action":"places.list","extra":1}), "extra", "unknown_field"),
        (json!("places.list"), "arguments", "wrong_type"),
    ];
    for (args, field, reason) in cases {
        let out: Value = serde_json::from_str(&act(&a, args.clone())).unwrap();
        assert_eq!((out["error"]["type"].as_str(), out["error"]["field"].as_str(), out["error"]["reason"].as_str()), (Some("bad_arguments"), Some(field), Some(reason)), "{args}");
    }
    // fields may be left out, or null
    assert!(act(&a, json!({"action":"places.list"})).contains("host_run"));
    assert!(act(&a, json!({"action":"places.list","fields":null})).contains("host_run"));
}

#[test]
fn a_module_that_is_off_answers_not_set_up() {
    let a = installed();
    a.set_modules_off(vec!["places".into()]);
    assert_eq!(act(&a, json!({"action":"places.list"})), r#"{"ok":false,"error":{"type":"not_set_up","detail":"places is not set up"}}"#);
    let r = with_ctx(true, true, |c| a.resolve(c, "places.list", &Value::Null)).unwrap_err();
    assert_eq!(r.code, "not_set_up");
    assert!(act(&a, json!({"action":"home.source_switch","fields":{"source":"alerts","on":true}})).contains("needs_confirmation"));
}

// ---- places ----

fn place_summary(text: &str, geo: bool, fix: bool) -> String {
    let a = installed();
    let args = json!({"action":"places.save","fields":{"name":"n","place":text}});
    with_ctx(geo, fix, |ctx| match a.call(ctx, &args, &mut ConvState::default()) {
        Ok(ToolOutput::Json(v)) => v["summary"]["place"].as_str().unwrap().to_string(),
        Ok(_) => panic!(),
        Err(e) => e.to_json().to_string(),
    })
}

#[test]
fn a_place_is_resolved_as_coordinates_then_a_saved_place_then_the_pack() {
    assert_eq!(place_summary("44.21,-114.93", true, true), "44.21000, -114.93000 (12 mi NE of Stanley)");
    assert_eq!(place_summary(" 44.21 -114.93 ", true, true), "44.21000, -114.93000 (12 mi NE of Stanley)");
    // no town near them, or no places data: just the coordinates
    assert_eq!(place_summary("10,20", true, true), "10.00000, 20.00000");
    assert_eq!(place_summary("44.21,-114.93", false, true), "44.21000, -114.93000");
    // a saved place, by name (any case) or key, shown by its name
    assert_eq!(place_summary("home", true, true), "Home (42.53600, -113.79200)");
    assert_eq!(place_summary("ELK CAMP", false, false), "Elk camp (44.20000, -114.90000)");
    assert_eq!(place_summary("elk", false, false), "Elk camp (44.20000, -114.90000)");
    // the pack: its display name; the fix is the point it prefers
    assert_eq!(place_summary("Stanley", true, false), "Stanley, ID (44.22160, -114.93620)");
    assert_eq!(place_summary("Springfield", true, true), "Springfield, ID (43.00000, -112.00000)");
    assert_eq!(place_summary("Springfield", true, false), "Springfield, IL (43.00000, -112.00000)");
}

#[test]
fn a_place_that_does_not_resolve_is_place_not_found_with_field_and_query() {
    let a = installed();
    let out = act(&a, json!({"action":"places.save","fields":{"name":"n","place":"  Nowhere  "}}));
    assert_eq!(out, r#"{"ok":false,"error":{"type":"place_not_found","detail":"no place matches \"Nowhere\"","field":"place","query":"Nowhere"}}"#);
    // without places data a name is not found, but coordinates and saved places still work
    let args = json!({"action":"places.save","fields":{"name":"n","place":"Stanley"}});
    let e = with_ctx(false, false, |ctx| a.call(ctx, &args, &mut ConvState::default())).err().unwrap();
    assert_eq!(e.code, "place_not_found");
    // out of range coordinates are not coordinates
    assert_eq!(place_summary("91,0", false, false).contains("place_not_found"), true);
    // a too long place is too_long, not a lookup
    assert!(act(&a, json!({"action":"places.open","fields":{"to":"x".repeat(301)}})).contains(r#""reason":"too_long""#));
}

// ---- the exchanges ----

#[test]
fn a_change_gives_a_card_and_never_runs() {
    let a = installed();
    let mut st = ConvState::default();
    let out = call(&a, &mut st, json!({"action":"places.save","fields":{"name":"Elk camp","place":"44.21,-114.93"}}));
    assert_eq!(
        out,
        r#"{"ok":true,"status":"needs_confirmation","confirm_id":"c1","action":"places.save","title":"Save a place","summary":{"name":"Elk camp","place":"44.21000, -114.93000 (12 mi NE of Stanley)"}}"#
    );
    assert_eq!((st.confirms, st.runs, st.pending.len()), (1, 0, 0));
}

#[test]
fn confirm_ids_count_up_per_conversation_and_errors_take_none() {
    let a = installed();
    let mut st = ConvState::default();
    let good = json!({"action":"home.source_switch","fields":{"source":"alerts","on":true}});
    assert!(call(&a, &mut st, good.clone()).contains(r#""confirm_id":"c1""#));
    assert!(call(&a, &mut st, json!({"action":"home.source_switch","fields":{"source":"x","on":true}})).contains("not_allowed"));
    assert!(call(&a, &mut st, good.clone()).contains(r#""confirm_id":"c2""#));
    assert!(call(&a, &mut st, good.clone()).contains(r#""confirm_id":"c3""#));
    // another conversation starts again
    let mut other = ConvState::default();
    assert!(call(&a, &mut other, good).contains(r#""confirm_id":"c1""#));
    // the summary keeps the fields as given, in the definition's order, only those given
    let out = call(&a, &mut st, json!({"action":"home.source_switch","fields":{"on":false,"source":"weather"}}));
    assert!(out.ends_with(r#""summary":{"source":"weather","on":false}}"#), "{out}");
}

#[test]
fn a_read_or_open_is_handed_to_the_host_with_resolved_fields() {
    let a = installed();
    let mut st = ConvState::default();
    let out = call(&a, &mut st, json!({"action":"places.list"}));
    assert_eq!(out, r#"{"ok":true,"status":"host_run","run_id":"r1","action":"places.list","fields":{}}"#);
    let out = call(&a, &mut st, json!({"action":"places.open","fields":{"to":"home"}}));
    assert_eq!(
        out,
        r#"{"ok":true,"status":"host_run","run_id":"r2","action":"places.open","fields":{"to":{"lat":42.536,"lon":-113.792,"name":"Home","label":"home"}}}"#
    );
    assert_eq!(st.pending, vec![("r1".to_string(), "places.list".to_string()), ("r2".to_string(), "places.open".to_string())]);
    assert_eq!(st.confirms, 0);
}

#[test]
fn resolve_gives_machine_values_and_takes_no_ids() {
    let a = installed();
    let r = |action: &str, f: Value| with_ctx(true, true, |c| a.resolve(c, action, &f)).map(|v| v.to_string()).unwrap_or_else(|e| e.to_json().to_string());
    assert_eq!(
        r("places.save", json!({"name":"Elk camp","place":"44.21,-114.93","note":null})),
        r#"{"ok":true,"action":"places.save","fields":{"name":"Elk camp","place":{"lat":44.21,"lon":-114.93}}}"#
    );
    assert_eq!(
        r("places.save", json!({"place":"Stanley","name":"x"})),
        r#"{"ok":true,"action":"places.save","fields":{"name":"x","place":{"lat":44.2216,"lon":-114.9362,"name":"Stanley, ID"}}}"#
    );
    assert_eq!(r("places.save", json!({"place":"home","name":"x"})), r#"{"ok":true,"action":"places.save","fields":{"name":"x","place":{"lat":42.536,"lon":-113.792,"name":"Home","label":"home"}}}"#);
    assert_eq!(r("places.list", Value::Null), r#"{"ok":true,"action":"places.list","fields":{}}"#);
    assert_eq!(r("log.add", json!({"count":3,"for":"PT20M"})), r#"{"ok":true,"action":"log.add","fields":{"count":3,"for":"PT20M"}}"#);
    assert!(r("places.save", json!({"name":"x"})).contains(r#""reason":"missing""#));
    assert!(r("places.save", json!([])).contains(r#""field":"fields","reason":"wrong_type""#));
    assert!(r("nope.x", Value::Null).contains("unknown_action"));
    assert!(r("places.save", json!({"name":"x","place":"Nowhere"})).contains("place_not_found"));
}

// ---- the tool as the framework sees it ----

#[test]
fn the_tool_runs_in_a_conversation_state_and_checks_its_own_arguments() {
    let state = std::sync::Arc::new(ActState::new());
    state.set_definitions(&defs()).unwrap();
    let t = ActTool(state);
    assert!(t.checks_own_arguments());
    let ctx = ToolCtx { location: None, places: &Saved, now: NOW, geocoder: None, live_fetcher: None };
    let mut st = ConvState::default();
    let args = json!({"action":"home.source_switch","fields":{"source":"alerts","on":true}});
    t.run_in(&ctx, &args, &mut st).unwrap();
    t.run_in(&ctx, &args, &mut st).unwrap();
    assert_eq!(st.confirms, 2);
    let _: Result<ToolOutput, ToolError> = t.run(&ctx, &args);
}

// ---- the host's side ----

#[test]
fn a_reply_is_a_result_or_an_error_and_nothing_else() {
    match reply::parse_reply(&json!({"ok":true,"result":{"places":[]}})).unwrap() {
        Reply::Done(v) => assert_eq!(v, json!({"places":[]})),
        _ => panic!(),
    }
    match reply::parse_reply(&json!({"ok":false,"error":{"type":"unavailable","detail":"no maps"}})).unwrap() {
        Reply::Failed(e) => assert_eq!(e.to_json().to_string(), r#"{"ok":false,"error":{"type":"unavailable","detail":"no maps"}}"#),
        _ => panic!(),
    }
    match reply::parse_reply(&json!({"ok":false,"error":{"type":"x"}})).unwrap() {
        Reply::Failed(e) => assert_eq!(e.to_json().to_string(), r#"{"ok":false,"error":{"type":"x"}}"#),
        _ => panic!(),
    }
    for bad in [json!([]), json!({}), json!({"ok":"yes"}), json!({"ok":true}), json!({"ok":true,"result":null}), json!({"ok":false}), json!({"ok":false,"error":{}}),
                json!({"ok":false,"error":{"type":""}}), json!({"ok":false,"error":"boom"}), json!({"ok":false,"error":{"type":"x","detail":5}})] {
        assert!(reply::parse_reply(&bad).is_err(), "{bad}");
    }
    assert_eq!(reply::done_json("a.b", json!({"n":1})).to_string(), r#"{"ok":true,"status":"done","action":"a.b","result":{"n":1}}"#);
}

#[test]
fn a_run_can_be_finished_once() {
    let mut st = ConvState::default();
    st.runs = 3;
    st.pending.push(("r2".into(), "a.b".into()));
    assert_eq!(reply::take_pending(&mut st, "r2").unwrap(), "a.b");
    assert_eq!(reply::take_pending(&mut st, "r2").unwrap_err().1, "run r2 is already finished");
    assert_eq!(reply::take_pending(&mut st, "r1").unwrap_err().1, "run r1 is already finished");
    assert_eq!(reply::take_pending(&mut st, "r4").unwrap_err().1, "no run r4 in this conversation");
    assert_eq!(reply::take_pending(&mut st, "x").unwrap_err().0, "not_found");
    assert_eq!(reply::take_pending(&mut st, "r0").unwrap_err().1, "no run r0 in this conversation");
}

fn outcome(v: Value) -> Result<String, String> {
    reply::parse_outcome(&v).map(|o| o.to_json(o.result.clone()).to_string())
}

#[test]
fn an_outcome_is_the_system_message_in_the_contracts_key_order() {
    assert_eq!(
        outcome(json!({"confirm_id":"c1","action":"places.save","status":"done","ok":true,"result":{"saved":"Elk camp"}})).unwrap(),
        r#"{"host_event":"act_outcome","ok":true,"status":"done","confirm_id":"c1","action":"places.save","result":{"saved":"Elk camp"}}"#
    );
    assert_eq!(
        outcome(json!({"ok":true,"status":"declined","confirm_id":"c2","action":"places.save"})).unwrap(),
        r#"{"host_event":"act_outcome","ok":true,"status":"declined","confirm_id":"c2","action":"places.save"}"#
    );
    assert_eq!(
        outcome(json!({"ok":false,"status":"failed","confirm_id":"c3","action":"places.save","error":{"detail":"disk full","type":"io"}})).unwrap(),
        r#"{"host_event":"act_outcome","ok":false,"status":"failed","confirm_id":"c3","action":"places.save","error":{"type":"io","detail":"disk full"}}"#
    );
    // a declined outcome carries nothing else, whatever the host added
    assert_eq!(
        outcome(json!({"ok":true,"status":"declined","confirm_id":"c2","action":"a.b","result":{"x":1},"extra":1})).unwrap(),
        r#"{"host_event":"act_outcome","ok":true,"status":"declined","confirm_id":"c2","action":"a.b"}"#
    );
}

#[test]
fn a_bad_outcome_is_refused() {
    let good = json!({"ok":true,"status":"done","confirm_id":"c1","action":"a.b","result":{}});
    assert!(outcome(good.clone()).is_ok());
    let mut cases: Vec<Value> = vec![json!([]), json!("done"), json!({})];
    for (k, v) in [("ok", json!("true")), ("status", json!("ran")), ("status", json!(null)), ("confirm_id", json!("")), ("confirm_id", json!(1)), ("action", json!(null)), ("result", json!(null))] {
        let mut b = good.clone();
        b[k] = v;
        cases.push(b);
    }
    for k in ["ok", "status", "confirm_id", "action", "result"] {
        let mut b = good.clone();
        b.as_object_mut().unwrap().remove(k);
        cases.push(b);
    }
    // ok must go with the status
    cases.push(json!({"ok":false,"status":"done","confirm_id":"c1","action":"a.b","result":{}}));
    cases.push(json!({"ok":false,"status":"declined","confirm_id":"c1","action":"a.b"}));
    cases.push(json!({"ok":true,"status":"failed","confirm_id":"c1","action":"a.b","error":{"type":"x"}}));
    // failed needs an error with a type
    cases.push(json!({"ok":false,"status":"failed","confirm_id":"c1","action":"a.b"}));
    cases.push(json!({"ok":false,"status":"failed","confirm_id":"c1","action":"a.b","error":{"detail":"x"}}));
    for bad in cases {
        assert!(outcome(bad.clone()).is_err(), "{bad}");
    }
}
