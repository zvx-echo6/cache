//! An item's `app` values: what a definition names for the app alone (an alert's message type, references and VTEC, with
//! which the app tells an update of an alert from another alert). They are in `cs_live_get` and in nothing the model reads:
//! the `live_data` tool's result for the same stored alert is, byte for byte, what it is without them.
//!
//! The alert is the recorded NWS flash flood warning of 2026-10-29 (tests/fixtures/ipaws/nws_ffw.json); the definition is the
//! one built into the app (packages/cache_search/sources/alerts.json), pointed at a server on this machine.

use cache_live::def::SourceDef;
use cache_live::{Live, LiveCfg, LiveDataTool};
use cache_tool::{Tool, ToolCtx, ToolOutput};
use cache_user::UserStore;
use serde_json::{json, Value};
use std::path::PathBuf;

const NOW: &str = "2026-10-29T14:00:00-06:00";
const VTEC: &str = "/O.NEW.KABQ.FF.W.0239.261029T1936Z-261029T2230Z/";

fn manifest() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn warning() -> Value {
    serde_json::from_str(&std::fs::read_to_string(manifest().join("tests/fixtures/ipaws/nws_ffw.json")).unwrap()).unwrap()
}

/// The built-in alerts definition.
fn built_in() -> Value {
    serde_json::from_str(&std::fs::read_to_string(manifest().join("../../sources/alerts.json")).unwrap()).unwrap()
}

/// The built-in definition as it was before it named any `app` value.
fn without_app() -> Value {
    let mut d = built_in();
    assert!(d["items"][0].as_object_mut().unwrap().remove("app").is_some(), "the built-in definition names app values");
    d
}

/// A server on this machine that answers every request with `body`.
fn serve(body: String) -> u16 {
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let port = server.server_addr().to_ip().unwrap().port();
    std::thread::spawn(move || {
        for req in server.incoming_requests() {
            let _ = req.respond(tiny_http::Response::from_string(body.clone()));
        }
    });
    port
}

struct Env {
    dir: PathBuf,
    live: Live,
    places: UserStore,
}

impl Env {
    fn new(name: &str, def: &Value, port: u16) -> Env {
        let dir = std::env::temp_dir().join(format!("cache-live-app-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("sources")).unwrap();
        let env = Env {
            live: Live::new(LiveCfg::new(dir.join("live.sqlite").to_string_lossy(), dir.join("sources").to_string_lossy())),
            places: UserStore::new(dir.join("user.sqlite")),
            dir,
        };
        env.install(def, port);
        env
    }
    /// Writes the definition, its address sent to the server on this machine.
    fn install(&self, def: &Value, port: u16) {
        let mut d = def.clone();
        d["request"]["url"] = json!(format!("http://127.0.0.1:{port}/alerts/active?point={{lat:4}},{{lon:4}}"));
        std::fs::write(self.dir.join("sources/alerts.json"), serde_json::to_string_pretty(&d).unwrap()).unwrap();
    }
    fn place() -> Value {
        // the key the live_data tool looks for at this position
        json!({"key": "at:33.36,-105.68", "name": "current location", "lat": 33.36, "lon": -105.68})
    }
    fn fetch(&self) -> Value {
        let r = json!({"source": "alerts", "place": Env::place(), "now": NOW});
        serde_json::from_str(&self.live.fetch(&r.to_string(), &self.places).unwrap()).unwrap()
    }
    fn get(&self) -> Value {
        let r = json!({"source": "alerts", "place": Env::place(), "now": NOW});
        serde_json::from_str(&self.live.get(&r.to_string(), &self.places).unwrap()).unwrap()
    }
    /// What the model reads: the tool's result, as text.
    fn tool(&self) -> String {
        let t = LiveDataTool::new(self.live.cfg.clone());
        let ctx = ToolCtx { location: None, places: &self.places, now: NOW, geocoder: None, live_fetcher: None };
        match t.run(&ctx, &json!({"source": "alerts", "place": "33.36,-105.68"})).unwrap() {
            ToolOutput::Json(v) => v.to_string(),
            ToolOutput::Text(_) | ToolOutput::Pieces(_) => panic!("text"),
        }
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn the_app_gets_an_alerts_message_type_references_and_vtec_and_the_model_reads_what_it_read_before() {
    let port = serve(warning().to_string());
    let now = Env::new("now", &built_in(), port);
    let before = Env::new("before", &without_app(), port);
    let (a, b) = (now.fetch(), before.fetch());
    assert_eq!(a["items"].as_array().unwrap().len(), 1, "{a}");

    // the app: the values as the response has them
    assert_eq!(a["items"][0]["app"], json!({"message_type": "Alert", "references": [], "vtec": [VTEC]}));
    assert_eq!(now.get()["items"][0]["app"], a["items"][0]["app"]);
    // and nothing else about the item differs from before
    assert!(b["items"][0].get("app").is_none());
    let mut same = a["items"][0].clone();
    same.as_object_mut().unwrap().remove("app");
    assert_eq!(same, b["items"][0]);

    // the model: byte for byte the result it had before the definition named them
    let (with, without) = (now.tool(), before.tool());
    assert!(with.contains("Flash Flood Warning"), "{with}");
    assert_eq!(with, without);
    for hidden in ["\"app\"", "message_type", "references", "O.NEW.KABQ"] {
        assert!(!with.contains(hidden), "{hidden} is in what the model reads: {with}");
    }

    // an alert stored before the definition named them gets them when the definition changes, without a download
    before.install(&built_in(), 1);
    assert_eq!(before.get()["items"][0]["app"], a["items"][0]["app"]);
    assert_eq!(before.tool(), with);
}

#[test]
fn a_value_that_is_missing_or_too_large_is_left_out() {
    let mut w = warning();
    let p = w["features"][0]["properties"].as_object_mut().unwrap();
    p.remove("references");
    p.insert("note".into(), json!("n".repeat(9000)));
    let mut d = built_in();
    d["items"][0]["app"]["note"] = json!("properties.note");
    let env = Env::new("limits", &d, serve(w.to_string()));
    let app = env.fetch()["items"][0]["app"].clone();
    assert_eq!(app, json!({"message_type": "Alert", "vtec": [VTEC]}));
}

#[test]
fn a_definition_names_at_most_eight_app_values_by_plain_names() {
    let check = |app: Value| {
        let mut d = built_in();
        d["items"][0]["app"] = app;
        SourceDef::check(&d.to_string()).map(|_| ()).map_err(|e| format!("{e:?}"))
    };
    assert!(check(json!({"message_type": "properties.messageType"})).is_ok());
    assert!(check(json!({})).is_ok());
    assert!(check(json!({"message type": "properties.messageType"})).unwrap_err().contains("items[0].app"));
    assert!(check(json!({"a": " "})).unwrap_err().contains("items[0].app.a"));
    let nine: serde_json::Map<String, Value> = (0..9).map(|i| (format!("v{i}"), json!("properties.id"))).collect();
    assert!(check(Value::Object(nine)).unwrap_err().contains("at most 8"));
}

/// A distance field also comes as a number, for the app alone: "inside the area" is words for people and the model, and the app
/// read no number in them, so a place inside a fire's edge counted as no distance at all (not serious).
#[test]
fn a_distance_field_also_comes_as_a_number_for_the_app_and_inside_the_area_is_zero() {
    let example = std::fs::read_to_string(manifest().join("tests/fixtures/nws_example_alerts.json")).unwrap();
    let env = Env::new("distances", &built_in(), serve(example));
    let place = json!({"key": "at:42.54,-113.79", "name": "current location", "lat": 42.536, "lon": -113.792});
    let now = "2026-10-25T14:20:00-06:00";
    let r = json!({"source": "alerts", "place": place, "now": now});
    let got: Value = serde_json::from_str(&env.live.fetch(&r.to_string(), &env.places).unwrap()).unwrap();
    let by_label = |label: &str| got["items"].as_array().unwrap().iter().find(|i| i["label"] == label).unwrap_or_else(|| panic!("{label}: {got}")).clone();
    // outside an area: the same distance the text gives ("11 mi N"), in kilometres
    let red = by_label("Red Flag Warning");
    assert_eq!(red["fields"]["Distance"], "11 mi N");
    assert_eq!(red["distances"]["Distance"]["inside"], false);
    let km = red["distances"]["Distance"]["km"].as_f64().unwrap();
    assert_eq!((km * 0.621_371_192).round(), 11.0, "{km} km");
    // inside an area: the words stay, and the number is zero
    let wind = by_label("Wind Advisory");
    assert_eq!(wind["fields"]["Distance"], "inside the area");
    assert_eq!(wind["distances"], json!({"Distance": {"km": 0.0, "inside": true}}));
    // an alert with no area has no distance, in words or as a number
    let tornado = by_label("Tornado Warning");
    assert!(tornado["fields"].get("Distance").is_none() && tornado.get("distances").is_none(), "{tornado}");
    // the model reads the words as before and no number
    let t = LiveDataTool::new(env.live.cfg.clone());
    let ctx = ToolCtx { location: None, places: &env.places, now, geocoder: None, live_fetcher: None };
    let text = match t.run(&ctx, &json!({"source": "alerts", "place": "42.536,-113.792"})).unwrap() {
        ToolOutput::Json(v) => v.to_string(),
        ToolOutput::Text(_) | ToolOutput::Pieces(_) => panic!("text"),
    };
    assert!(text.contains("\"Distance\":\"inside the area\"") && text.contains("\"Distance\":\"11 mi N\""), "{text}");
    assert!(!text.contains("distances") && !text.contains("\"inside\""), "{text}");
}
