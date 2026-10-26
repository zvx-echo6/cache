//! cache_live against recorded responses. A tiny local HTTP server plays Open-Meteo / NWS; the definitions under
//! test are the real files from packages/cache_search/sources with only the URL pointed at that server.

use cache_live::{Live, LiveCfg, LiveDataTool};
use cache_tool::places::{Geocoder, PlaceSource};
use cache_tool::{Location, SavedPlaces, Tool, ToolCtx, ToolError, ToolOutput};
use cache_user::UserStore;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU16, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

const T0: &str = "2026-10-25T10:50:00-06:00";

fn fixture(name: &str) -> String {
    std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)).unwrap()
}

fn real_source(name: &str) -> Value {
    serde_json::from_str(&std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../sources").join(name)).unwrap()).unwrap()
}

struct Server {
    port: u16,
    hits: Arc<AtomicUsize>,
    status: Arc<AtomicU16>,
    last_ua: Arc<Mutex<String>>,
    last_url: Arc<Mutex<String>>,
    bodies: Arc<Mutex<Vec<(String, String)>>>,
}

impl Server {
    /// Serves `bodies` (path prefix -> body).
    fn start(bodies: Vec<(&str, String)>) -> Server {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let port = server.server_addr().to_ip().unwrap().port();
        let s = Server {
            port,
            hits: Arc::new(AtomicUsize::new(0)),
            status: Arc::new(AtomicU16::new(200)),
            last_ua: Arc::new(Mutex::new(String::new())),
            last_url: Arc::new(Mutex::new(String::new())),
            bodies: Arc::new(Mutex::new(bodies.into_iter().map(|(a, b)| (a.to_string(), b)).collect())),
        };
        let (hits, status, ua, url, bodies) = (s.hits.clone(), s.status.clone(), s.last_ua.clone(), s.last_url.clone(), s.bodies.clone());
        std::thread::spawn(move || {
            for req in server.incoming_requests() {
                hits.fetch_add(1, Ordering::SeqCst);
                *ua.lock().unwrap() = req.headers().iter().find(|h| h.field.equiv("User-Agent")).map(|h| h.value.to_string()).unwrap_or_default();
                *url.lock().unwrap() = req.url().to_string();
                let code = status.load(Ordering::SeqCst);
                let body = bodies.lock().unwrap().iter().find(|(p, _)| req.url().starts_with(p.as_str())).map(|(_, b)| b.clone()).unwrap_or_default();
                let _ = req.respond(tiny_http::Response::from_string(body).with_status_code(code));
            }
        });
        s
    }
    fn hits(&self) -> usize {
        self.hits.load(Ordering::SeqCst)
    }
}

struct Env {
    dir: PathBuf,
    live: Live,
    places: UserStore,
}

impl Env {
    /// `defs`: (file name, definition JSON). Their request.url is rewritten to `http://127.0.0.1:<port><path>`.
    fn new(name: &str, defs: Vec<(&str, Value, Option<(u16, &str)>)>) -> Env {
        let dir = std::env::temp_dir().join(format!("cache-live-test-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("sources")).unwrap();
        for (file, mut d, srv) in defs {
            if let Some((port, path)) = srv {
                let old = d["request"]["url"].as_str().unwrap().to_string();
                let q = old.find('?').map(|i| &old[i..]).unwrap_or("");
                d["request"]["url"] = json!(format!("http://127.0.0.1:{port}{path}{q}"));
            }
            std::fs::write(dir.join("sources").join(file), serde_json::to_string_pretty(&d).unwrap()).unwrap();
        }
        let live = Live::new(LiveCfg::new(dir.join("live.sqlite").to_string_lossy(), dir.join("sources").to_string_lossy()));
        let places = UserStore::new(dir.join("user.sqlite"));
        Env { dir, live, places }
    }
    fn weather(&self, req: Value) -> Result<Value, cache_live::Error> {
        self.live.fetch(&req.to_string(), &self.places).map(|s| serde_json::from_str(&s).unwrap())
    }
    fn get(&self, req: Value) -> Result<Value, cache_live::Error> {
        self.live.get(&req.to_string(), &self.places).map(|s| serde_json::from_str(&s).unwrap())
    }
    fn tool(&self, args: Value, loc: Option<&Location>, now: &str) -> Result<Value, ToolError> {
        self.tool_with(args, loc, now, None, self.live.cfg.live_radius_km)
    }
    /// The tool with a geocoder (the places pack) and a `live_radius_km`.
    fn tool_with(&self, args: Value, loc: Option<&Location>, now: &str, geo: Option<&dyn Geocoder>, radius_km: f64) -> Result<Value, ToolError> {
        let t = LiveDataTool::new(LiveCfg { live_radius_km: radius_km, ..self.live.cfg.clone() });
        match t.run(&ToolCtx { location: loc, places: &self.places, now, geocoder: geo, live_fetcher: None }, &args)? {
            ToolOutput::Json(v) => Ok(v),
            ToolOutput::Text(_) => panic!("text"),
        }
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn burley() -> Value {
    json!({"key": "burley", "name": "Burley, ID", "lat": 42.536, "lon": -113.792})
}

fn weather_env(name: &str) -> (Env, Server) {
    let srv = Server::start(vec![("/v1/forecast", fixture("openmeteo_burley.json"))]);
    let env = Env::new(name, vec![("weather.json", real_source("weather.json"), Some((srv.port, "/v1/forecast")))]);
    (env, srv)
}

#[test]
fn the_shipped_definitions_are_valid() {
    for f in ["weather.json", "alerts.json"] {
        let text = std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../sources").join(f)).unwrap();
        cache_live::def::SourceDef::parse(&text).unwrap_or_else(|e| panic!("{f}: {}", e.message));
    }
}

#[test]
fn weather_fetch_get_and_tool_shape() {
    let (env, srv) = weather_env("shape");
    let r = env.weather(json!({"source": "weather", "place": burley(), "now": T0})).unwrap();
    assert_eq!(r["fetched"], true);
    assert_eq!(srv.hits(), 1);
    assert_eq!(*srv.last_ua.lock().unwrap(), format!("Cache/{}", env!("CARGO_PKG_VERSION")));
    let url = srv.last_url.lock().unwrap().clone();
    assert!(url.contains("latitude=42.5360&longitude=-113.7920"), "{url}");

    // the app's view: all 17 items (now + 16 days), addresses, local offset
    let g = env.get(json!({"source": "weather", "place": burley(), "now": T0})).unwrap();
    assert_eq!(g["fetched_at"], "2026-10-25T10:50:00-06:00");
    assert_eq!(g["age"], "less than a minute old");
    assert_eq!(g["expired"], false);
    let items = g["items"].as_array().unwrap();
    assert_eq!(items.len(), 17);
    assert_eq!(items[0]["address"], "live:weather/burley/now");
    assert_eq!(items[1]["address"], "live:weather/burley/2026-10-25");
    assert_eq!(items[0]["label"], "Now");
    assert_eq!(items[0]["time"], "2026-10-25T10:45-06:00");
    let keys: Vec<_> = items[0]["fields"].as_object().unwrap().keys().cloned().collect();
    assert_eq!(keys, ["Temperature", "Feels like", "Wind", "Conditions"]);
    assert_eq!(items[0]["fields"]["Temperature"], "41 \u{b0}F");
    assert_eq!(items[0]["fields"]["Wind"], "6 mph NE, gusts 8 mph");
    assert_eq!(items[0]["fields"]["Conditions"], "clear sky");
    let day = &items[2];
    assert_eq!(day["label"], "Mon 26 Oct");
    assert_eq!(day["time"], "2026-10-26");
    let keys: Vec<_> = day["fields"].as_object().unwrap().keys().cloned().collect();
    assert_eq!(keys, ["High", "Low", "Chance of rain", "Wind max", "Conditions"]);

    // the model's view: the same data, 12 items, "more" for the rest, "address" where the model will see "n"
    let t = env.tool(json!({"source": "weather", "place": "burley"}), None, T0);
    assert_eq!(t.unwrap_err().code, "geocode_empty", "burley is not a saved place yet");
    env.places.save(r#"{"key":"burley","name":"Burley, ID","lat":42.536,"lon":-113.792}"#).unwrap();
    let t = env.tool(json!({"source": "weather", "place": "burley, id"}), None, "2026-10-25T12:50:00-06:00").unwrap();
    assert_eq!(t.as_object().unwrap().keys().collect::<Vec<_>>(), ["source", "place", "fetched_at", "valid_until", "age", "expired", "items", "more", "not_covered_after"]);
    assert_eq!(t["source"], json!({"id": "weather", "title": "Weather forecast", "provider": "Open-Meteo"}));
    assert_eq!(t["place"], "Burley, ID");
    assert_eq!(t["age"], "2 hours old");
    assert_eq!(t["items"].as_array().unwrap().len(), 12);
    assert_eq!(t["more"], 5);
    // the forecast ends at local midnight; daylight saving ends on 1 Nov, so that midnight is -07:00
    assert_eq!(t["valid_until"], "2026-11-10T00:00:00-07:00");
    assert_eq!(t["not_covered_after"], "2026-11-10");
    assert_eq!(t["items"][0].as_object().unwrap().keys().collect::<Vec<_>>(), ["address", "label", "time", "fields"]);
    // same items as the app's view
    for (a, b) in t["items"].as_array().unwrap().iter().zip(items) {
        assert_eq!(a["address"], b["address"]);
        assert_eq!(a["fields"], b["fields"]);
    }
}

#[test]
fn refresh_interval_force_and_failure_keeps_last_good() {
    let (env, srv) = weather_env("refresh");
    env.weather(json!({"source": "weather", "place": burley(), "now": T0})).unwrap();
    let again = env.weather(json!({"source": "weather", "place": burley(), "now": "2026-10-25T11:50:00-06:00"})).unwrap();
    assert_eq!(again["fetched"], false);
    assert_eq!(srv.hits(), 1);
    // after the 180-minute refresh interval it downloads again
    let later = env.weather(json!({"source": "weather", "place": burley(), "now": "2026-10-25T14:00:00-06:00"})).unwrap();
    assert_eq!(later["fetched"], true);
    assert_eq!(srv.hits(), 2);
    let forced = env.weather(json!({"source": "weather", "place": burley(), "now": "2026-10-25T14:01:00-06:00", "force": true})).unwrap();
    assert_eq!(forced["fetched"], true);
    assert_eq!(srv.hits(), 3);

    // the server fails: error, last good copy stays, last_error is recorded
    srv.status.store(503, Ordering::SeqCst);
    let e = env.weather(json!({"source": "weather", "place": burley(), "now": "2026-10-25T15:00:00-06:00", "force": true})).unwrap_err();
    assert_eq!((e.code, e.message.as_str()), ("fetch_failed", "HTTP 503"));
    let g = env.get(json!({"source": "weather", "place": burley(), "now": "2026-10-25T15:05:00-06:00"})).unwrap();
    assert_eq!(g["items"].as_array().unwrap().len(), 17);
    assert_eq!(g["fetched_at"], "2026-10-25T14:01:00-06:00");
    assert_eq!(g["last_error"]["code"], "fetch_failed");
    assert_eq!(g["last_error"]["at"], "2026-10-25T15:00:00-06:00");
    // not JSON: bad_response, still the last good copy
    srv.status.store(200, Ordering::SeqCst);
    *srv.bodies.lock().unwrap() = vec![("/v1/forecast".into(), "<html>oops</html>".into())];
    let e = env.weather(json!({"source": "weather", "place": burley(), "now": "2026-10-25T15:10:00-06:00", "force": true})).unwrap_err();
    assert_eq!(e.code, "bad_response");
    *srv.bodies.lock().unwrap() = vec![("/v1/forecast".into(), r#"{"error":true,"reason":"too many"}"#.into())];
    let e = env.weather(json!({"source": "weather", "place": burley(), "now": "2026-10-25T15:11:00-06:00", "force": true})).unwrap_err();
    assert_eq!(e.code, "bad_response");
    assert!(env.get(json!({"source": "weather", "place": burley()})).unwrap()["items"].as_array().unwrap().len() == 17);
    // a good fetch clears the recorded error
    *srv.bodies.lock().unwrap() = vec![("/v1/forecast".into(), fixture("openmeteo_burley.json"))];
    env.weather(json!({"source": "weather", "place": burley(), "now": "2026-10-25T15:12:00-06:00", "force": true})).unwrap();
    assert!(env.get(json!({"source": "weather", "place": burley(), "now": "2026-10-25T15:13:00-06:00"})).unwrap()["last_error"].is_null());
}

#[test]
fn expiry_then_the_expired_error() {
    let (env, _srv) = weather_env("expiry");
    env.places.save(r#"{"key":"burley","name":"Burley, ID","lat":42.536,"lon":-113.792}"#).unwrap();
    env.weather(json!({"source": "weather", "place": "burley", "now": T0})).unwrap();
    // valid until 2026-11-10T00:00-07:00
    let ok = env.tool(json!({"source": "weather", "place": "burley"}), None, "2026-11-09T23:59:59-06:00").unwrap();
    assert_eq!(ok["expired"], false);
    assert_eq!(ok["age"], "15 days old");
    // the app's screens still get the data, flagged expired
    let g = env.get(json!({"source": "weather", "place": "burley", "now": "2026-11-10T00:00:01-07:00"})).unwrap();
    assert_eq!(g["expired"], true);
    assert_eq!(g["items"].as_array().unwrap().len(), 17);
    // the model gets the error and no data
    let e = env.tool(json!({"source": "weather", "place": "burley"}), None, "2026-11-10T00:00:01-07:00").unwrap_err();
    assert_eq!((e.code.as_str(), e.detail.as_str()), ("expired", "weather data expired 2026-11-10"));
    assert_eq!(e.to_json().to_string(), r#"{"ok":false,"error":{"type":"expired","detail":"weather data expired 2026-11-10"}}"#);
}

#[test]
fn tool_errors() {
    let (env, _srv) = weather_env("errors");
    let here = Location { lat: 42.536, lon: -113.792, accuracy_m: Some(12.0), fixed_at: "2026-10-25T10:40:00-06:00".into() };
    let code = |r: Result<Value, ToolError>| r.unwrap_err().code;
    // bad arguments
    for bad in [json!({}), json!({"source": 5}), json!({"source": ""}), json!({"source": "weather", "extra": 1}), json!({"source": "weather", "place": 3}), json!({"source": "weather", "place": ""}), json!("weather"), json!(null)] {
        assert_eq!(code(env.tool(bad.clone(), Some(&here), T0)), "bad_arguments", "{bad}");
    }
    assert_eq!(code(env.tool(json!({"source": "fuel"}), Some(&here), T0)), "unknown_source");
    assert_eq!(code(env.tool(json!({"source": "weather"}), None, T0)), "no_location");
    assert_eq!(code(env.tool(json!({"source": "weather"}), Some(&here), T0)), "no_data");
    assert_eq!(code(env.tool(json!({"source": "weather", "place": "Nowhere"}), Some(&here), T0)), "geocode_empty");
    // the phone's location is the default place, keyed by the rounded position
    env.weather(json!({"source": "weather", "place": {"key": "at:42.54,-113.79", "name": "current location", "lat": 42.536, "lon": -113.792}, "now": T0})).unwrap();
    let t = env.tool(json!({"source": "weather"}), Some(&here), "2026-10-25T10:55:00-06:00").unwrap();
    assert_eq!(t["place"], "current location");
    assert_eq!(t["items"][0]["address"], "live:weather/at:42.54,-113.79/now");
    // no sources installed
    let empty = Env::new("errors-empty", vec![]);
    let e = empty.tool(json!({"source": "weather"}), Some(&here), T0).unwrap_err();
    assert_eq!(e.code, "not_set_up");
    assert!(LiveDataTool::new(empty.live.cfg.clone()).schema().is_none());
    // bad request JSON for the app calls
    assert_eq!(env.live.get("{", &env.places).unwrap_err().code, "bad_json");
    assert_eq!(env.live.get(r#"{"source":"weather"}"#, &env.places).unwrap_err().code, "bad_json");
    assert_eq!(env.live.get(r#"{"source":"weather","place":"nobody"}"#, &env.places).unwrap_err().code, "not_found");
    assert_eq!(env.live.get(r#"{"source":"nope","place":"x"}"#, &env.places).unwrap_err().code, "not_found");
    assert_eq!(env.get(json!({"source": "weather", "place": {"key": "a/b", "name": "x", "lat": 1, "lon": 2}})).unwrap_err().code, "bad_json");
    assert_eq!(env.get(json!({"source": "weather", "place": burley(), "now": "yesterday"})).unwrap_err().code, "bad_json");
    assert_eq!(env.get(json!({"source": "weather", "place": burley()})).unwrap_err().code, "not_found");
}

#[test]
fn schema_is_built_from_the_installed_definitions() {
    let srv = Server::start(vec![]);
    let env = Env::new("schema", vec![
        ("weather.json", real_source("weather.json"), Some((srv.port, "/w"))),
        ("alerts.json", real_source("alerts.json"), Some((srv.port, "/a"))),
        ("broken.json", json!({"id": "broken"}), None),
    ]);
    let s = LiveDataTool::new(env.live.cfg.clone()).schema().unwrap();
    let f = &s["function"];
    assert_eq!(f["name"], "live_data");
    assert_eq!(f["parameters"]["properties"]["source"]["enum"], json!(["alerts", "weather"]));
    let d = f["description"].as_str().unwrap();
    assert!(d.starts_with("Downloaded live data for a place. Data is downloaded while online and expires. Sources on this phone: alerts = active emergency alerts"), "{d}");
    assert!(d.contains("; weather = weather forecast"), "{d}");
    assert_eq!(f["parameters"]["required"], json!(["source"]));
    assert_eq!(f["parameters"]["additionalProperties"], false);
    // the broken file is reported, not fatal
    let list: Value = serde_json::from_str(&env.live.sources_json()).unwrap();
    assert_eq!(list["sources"].as_array().unwrap().len(), 2);
    assert_eq!(list["errors"][0]["file"], "broken.json");
}

#[test]
fn alerts_local_time_distance_sort_and_ended_items() {
    let srv = Server::start(vec![("/alerts/active", fixture("nws_example_alerts.json"))]);
    let env = Env::new("alerts", vec![("alerts.json", real_source("alerts.json"), Some((srv.port, "/alerts/active")))]);
    env.places.save(r#"{"name":"Home","lat":42.536,"lon":-113.792}"#).unwrap();
    env.live.fetch(&json!({"source": "alerts", "place": "Home", "now": "2026-10-25T13:55:00-06:00"}).to_string(), &env.places).unwrap();
    assert!(srv.last_url.lock().unwrap().contains("point=42.5360,-113.7920"));
    let t = env.tool(json!({"source": "alerts", "place": "home"}), None, "2026-10-25T14:20:00-06:00").unwrap();
    // NWS gives no zone for the place: it comes from the offline lookup, so every time is in the place's local offset
    assert_eq!(t["fetched_at"], "2026-10-25T13:55:00-06:00");
    assert_eq!(t["valid_until"], "2026-10-25T19:55:00-06:00");
    // 5 alerts stored; the third ended at 10:30 and is left out
    let items = t["items"].as_array().unwrap();
    assert_eq!(items.len(), 4);
    assert!(t.get("more").is_none() && t.get("none").is_none() && t.get("not_covered_after").is_none());
    // Extreme first, then Severe by onset (12:00 before 14:00), then Minor
    let labels: Vec<_> = items.iter().map(|i| i["label"].as_str().unwrap()).collect();
    assert_eq!(labels, ["Tornado Warning", "Flash Flood Watch", "Red Flag Warning", "Wind Advisory"]);
    let red = &items[2];
    assert_eq!(red["address"], "live:alerts/home/urn:oid:2.49.0.1.840.0.example1");
    assert_eq!(red["time"], "2026-10-25T13:40:00-06:00");
    let keys: Vec<_> = red["fields"].as_object().unwrap().keys().cloned().collect();
    assert_eq!(keys, ["Severity", "Urgency", "Area", "Distance", "Expires", "Headline", "Instructions"]);
    assert_eq!(red["fields"]["Severity"], "severe");
    assert_eq!(red["fields"]["Distance"], "11 mi N");
    assert_eq!(red["fields"]["Expires"], "2026-10-25 15:00");
    // the alert whose area contains the place; alerts with no area have no Distance (nothing is invented)
    assert_eq!(items[3]["fields"]["Distance"], "inside the area");
    assert_eq!(items[3]["fields"]["Expires"], "2026-10-25 15:30");
    assert!(items[3]["fields"].get("Instructions").is_none(), "null instruction is left out");
    assert!(items[0]["fields"].get("Distance").is_none() && items[1]["fields"].get("Distance").is_none());
    // the app's view carries the areas
    let g = env.get(json!({"source": "alerts", "place": "Home", "now": "2026-10-25T14:20:00-06:00"})).unwrap();
    assert_eq!(g["items"][3]["area"]["type"], "Polygon");
    assert!(g["items"][0].get("area").is_none());
    // by 16:30 everything has ended but the download is still valid: nothing to report
    let t = env.tool(json!({"source": "alerts", "place": "home"}), None, "2026-10-25T16:30:00-06:00").unwrap();
    assert_eq!(t["none"], true);
    assert_eq!(t["items"].as_array().unwrap().len(), 1);
    assert_eq!(t["items"][0]["address"], "live:alerts/home/none");
    // Boise: a real response with no active alerts
    *srv.bodies.lock().unwrap() = vec![("/alerts/active".into(), fixture("nws_boise.json"))];
    let boise = json!({"key": "boise", "name": "Boise, ID", "lat": 43.615, "lon": -116.202});
    env.live.fetch(&json!({"source": "alerts", "place": boise, "now": "2026-10-25T10:50:00-06:00"}).to_string(), &env.places).unwrap();
    env.places.save(r#"{"key":"boise","name":"Boise, ID","lat":43.615,"lon":-116.202}"#).unwrap();
    let t = env.tool(json!({"source": "alerts", "place": "Boise, ID"}), None, "2026-10-25T10:55:00-06:00").unwrap();
    assert_eq!(t["none"], true);
    // nothing to report is one entry in an item's shape, so the dispatch can number it and the model can cite it
    assert_eq!(
        t["items"],
        json!([{"address": "live:alerts/boise/none", "label": "No active emergency alerts", "time": "2026-10-25T10:50:00-06:00",
                "fields": {"Status": "none active", "Checked": "2026-10-25 10:50", "Age": "5 minutes old"}, "none_active": true}])
    );
    let keys: Vec<_> = t["items"][0].as_object().unwrap().keys().cloned().collect();
    assert_eq!(keys, ["address", "label", "time", "fields", "none_active"]);
    assert_eq!(t["age"], "5 minutes old");
    assert_eq!(t["fetched_at"], "2026-10-25T10:50:00-06:00");
    // a place in another zone gets that zone's offset
    let ny = json!({"key": "nyc", "name": "New York", "lat": 40.71, "lon": -74.0});
    env.live.fetch(&json!({"source": "alerts", "place": ny, "now": "2026-10-25T10:50:00-06:00"}).to_string(), &env.places).unwrap();
    let g = env.get(json!({"source": "alerts", "place": ny, "now": "2026-10-25T10:55:00-06:00"})).unwrap();
    assert_eq!(g["fetched_at"], "2026-10-25T12:50:00-04:00");
}

#[test]
fn the_none_entry_is_labelled_from_the_definition() {
    // without none_label the entry takes the title; with it, that text
    let srv = Server::start(vec![("/alerts/active", fixture("nws_boise.json"))]);
    let mut d = real_source("alerts.json");
    d.as_object_mut().unwrap().remove("none_label");
    let env = Env::new("nonelabel", vec![("alerts.json", d, Some((srv.port, "/alerts/active")))]);
    env.places.save(r#"{"key":"boise","name":"Boise, ID","lat":43.615,"lon":-116.202}"#).unwrap();
    env.live.fetch(&json!({"source": "alerts", "place": "boise", "now": "2026-10-25T10:50:00-06:00"}).to_string(), &env.places).unwrap();
    let t = env.tool(json!({"source": "alerts", "place": "Boise, ID"}), None, "2026-10-25T10:55:00-06:00").unwrap();
    assert_eq!(t["items"][0]["label"], "Emergency alerts");
    let mut d = real_source("alerts.json");
    d["none_label"] = json!("Nothing is active");
    let env = Env::new("nonelabel2", vec![("alerts.json", d, Some((srv.port, "/alerts/active")))]);
    env.places.save(r#"{"key":"boise","name":"Boise, ID","lat":43.615,"lon":-116.202}"#).unwrap();
    env.live.fetch(&json!({"source": "alerts", "place": "boise", "now": "2026-10-25T10:50:00-06:00"}).to_string(), &env.places).unwrap();
    let t = env.tool(json!({"source": "alerts", "place": "Boise, ID"}), None, "2026-10-25T10:55:00-06:00").unwrap();
    assert_eq!(t["items"][0]["label"], "Nothing is active");
    // an expired result stays an error, and a non-empty one has no such entry
    let e = env.tool(json!({"source": "alerts", "place": "Boise, ID"}), None, "2026-10-26T10:55:00-06:00").unwrap_err();
    assert_eq!(e.code, "expired");
}

#[test]
fn phone_position_rows_are_pruned() {
    let srv = Server::start(vec![("/alerts/active", fixture("nws_boise.json"))]);
    let env = Env::new("prune", vec![("alerts.json", real_source("alerts.json"), Some((srv.port, "/alerts/active")))]);
    let at = |lat: f64, lon: f64| json!({"key": format!("at:{lat:.2},{lon:.2}"), "name": "current location", "lat": lat, "lon": lon});
    let fetch = |p: &Value, now: &str| env.live.fetch(&json!({"source": "alerts", "place": p, "now": now}).to_string(), &env.places).unwrap();
    let exists = |p: &Value| env.get(json!({"source": "alerts", "place": p, "now": "2026-10-25T10:00:00-06:00"})).is_ok();
    let (a, b, c) = (at(42.54, -113.79), at(43.0, -114.0), at(44.0, -115.0));
    env.places.save(r#"{"key":"home","name":"Home","lat":42.536,"lon":-113.792}"#).unwrap();
    let home = json!("home");
    fetch(&home, "2026-10-25T04:00:00-06:00");
    fetch(&a, "2026-10-25T05:00:00-06:00");
    // an hour later, at another position: the first row is still within its validity (6 hours), so it stays
    fetch(&b, "2026-10-25T06:00:00-06:00");
    assert!(exists(&a) && exists(&b));
    // ten hours on: both older position rows have run out of validity; only the newest fetch stays
    fetch(&c, "2026-10-25T16:00:00-06:00");
    assert!(!exists(&a) && !exists(&b) && exists(&c));
    // a saved place is never pruned, expired or not
    assert!(exists(&home));
    // another source's rows are not touched by this source's pruning (none here), and fetching the same key again keeps it
    fetch(&c, "2026-10-25T23:00:00-06:00");
    assert!(exists(&c));
}

#[test]
fn a_changed_definition_remaps_without_a_download() {
    let (env, srv) = weather_env("remap");
    env.weather(json!({"source": "weather", "place": burley(), "now": T0})).unwrap();
    let path = env.dir.join("sources/weather.json");
    let text = std::fs::read_to_string(&path).unwrap().replace("\"Now\"", "\"Right now\"");
    std::fs::write(&path, text).unwrap();
    let g = env.get(json!({"source": "weather", "place": burley(), "now": T0})).unwrap();
    assert_eq!(g["items"][0]["label"], "Right now");
    assert_eq!(srv.hits(), 1);
    // and it stays remapped (stored)
    assert_eq!(env.get(json!({"source": "weather", "place": burley(), "now": T0})).unwrap()["items"][0]["label"], "Right now");
}

#[test]
fn quota_and_keys() {
    let srv = Server::start(vec![("/v1/forecast", fixture("openmeteo_burley.json"))]);
    let mut d = real_source("weather.json");
    d["quota"] = json!({"per_minute": 2});
    d["api_key"] = json!({"alias": "openmeteo"});
    d["request"]["url"] = json!(format!("{}&apikey={{api_key}}", d["request"]["url"].as_str().unwrap()));
    d["request"]["headers"] = json!({"X-Test-Key": "{api_key}"});
    let env = Env::new("quota", vec![("weather.json", d, Some((srv.port, "/v1/forecast")))]);
    let req = |now: &str, key: Option<&str>| {
        let mut r = json!({"source": "weather", "place": burley(), "now": now, "force": true});
        if let Some(k) = key {
            r["api_key"] = json!(k);
        }
        r
    };
    assert_eq!(env.weather(req(T0, None)).unwrap_err().code, "key_missing");
    assert_eq!(srv.hits(), 0);
    env.weather(req(T0, Some("sekret key"))).unwrap();
    assert!(srv.last_url.lock().unwrap().contains("apikey=sekret%20key"));
    env.weather(req("2026-10-25T10:50:30-06:00", Some("sekret key"))).unwrap();
    let e = env.weather(req("2026-10-25T10:50:40-06:00", Some("sekret key"))).unwrap_err();
    assert_eq!(e.code, "quota");
    assert_eq!(srv.hits(), 2);
    // a minute later it is allowed again
    env.weather(req("2026-10-25T10:52:00-06:00", Some("sekret key"))).unwrap();
    assert_eq!(srv.hits(), 3);
    // the key is never stored
    let db = std::fs::read(env.dir.join("live.sqlite")).unwrap();
    assert!(!String::from_utf8_lossy(&db).contains("sekret"));
    // and never appears in an error
    let e = env.weather(json!({"source": "weather", "place": burley(), "now": "2026-10-25T12:00:00-06:00", "force": true, "api_key": "sekret"})).unwrap();
    assert_eq!(e["fetched"], true);
}

#[test]
fn only_https_or_this_machine() {
    let mut d = real_source("weather.json");
    d["request"]["url"] = json!("http://example.com/v1/forecast?lat={lat}");
    let env = Env::new("https", vec![("weather.json", d, None)]);
    assert_eq!(env.weather(json!({"source": "weather", "place": burley(), "now": T0})).unwrap_err().code, "bad_json");
}

#[test]
fn deleting_a_saved_place_forgets_its_data() {
    let (env, _srv) = weather_env("forget");
    env.places.save(r#"{"key":"home","name":"Home","lat":42.536,"lon":-113.792}"#).unwrap();
    env.weather(json!({"source": "weather", "place": "Home", "now": T0})).unwrap();
    assert!(env.get(json!({"source": "weather", "place": "home", "now": T0})).is_ok());
    env.live.forget_place("home");
    assert_eq!(env.get(json!({"source": "weather", "place": "home", "now": T0})).unwrap_err().code, "not_found");
    let _ = env.places.list();
}

// ---- live_data resolves the place through the places pack (DESIGN.md "live_data and the places pack") ----

/// The places pack of a test as the handle would plug it in: `PlaceSource::geocoder`.
struct Pack {
    source: std::sync::Arc<dyn PlaceSource>,
    _dir: Option<PathBuf>,
}

impl Pack {
    /// The small Idaho fixture pack (Burley, Heyburn, Rupert, Declo, Twin Falls, Boise, Stanley, ...).
    fn fixture(name: &str) -> Pack {
        let dir = std::env::temp_dir().join(format!("cache-live-pack-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("places.sqlite");
        cache_places::fixture::write_fixture_pack(&path);
        let (_, source) = cache_places::tools_and_source(&cache_places::PlacesCfg { packs: vec![path.to_string_lossy().into()] });
        Pack { source, _dir: Some(dir) }
    }
    /// A real pack, read only.
    fn real(path: &str) -> Pack {
        let (_, source) = cache_places::tools_and_source(&cache_places::PlacesCfg { packs: vec![path.into()] });
        Pack { source, _dir: None }
    }
    fn geo(&self) -> &dyn Geocoder {
        self.source.geocoder().expect("the pack source is a geocoder")
    }
}

impl Drop for Pack {
    fn drop(&mut self) {
        if let Some(d) = &self._dir {
            let _ = std::fs::remove_dir_all(d);
        }
    }
}

/// Weather stored for Burley (a saved place), as the app would have downloaded it.
fn burley_data(name: &str) -> (Env, Server) {
    let (env, srv) = weather_env(name);
    env.places.save(r#"{"key":"burley","name":"Burley, ID","lat":42.536,"lon":-113.792}"#).unwrap();
    env.weather(json!({"source": "weather", "place": "burley", "now": T0})).unwrap();
    (env, srv)
}

const LATER: &str = "2026-10-25T12:00:00-06:00";

fn weather(env: &Env, geo: Option<&dyn Geocoder>, place: Option<&str>, loc: Option<&Location>) -> Result<Value, ToolError> {
    let args = match place {
        Some(p) => json!({"source": "weather", "place": p}),
        None => json!({"source": "weather"}),
    };
    env.tool_with(args, loc, LATER, geo, 30.0)
}

#[test]
fn live_data_takes_a_misspelt_town_like_navigate_and_locate() {
    let pack = Pack::fixture("slip");
    let (env, _srv) = burley_data("slip");
    // Island Park is far from Burley's data: no_data, naming the town that was meant, however it was typed
    for text in ["Island Park, Idaho", "Islnd Park", "island park id", "Ilsand Park"] {
        let e = weather(&env, Some(pack.geo()), Some(text), None).unwrap_err();
        assert_eq!(e.code, "no_data", "{text}");
        assert!(e.detail.starts_with("no weather data within 30 km of Island Park, ID; the nearest place with data is Burley, ID"), "{text}: {}", e.detail);
    }
}

#[test]
fn one_town_however_it_is_written_and_misspelt() {
    let pack = Pack::fixture("forms");
    let (env, _srv) = burley_data("forms");
    // Rupert is about 13 km from Burley: no data of its own, so Burley's is used and the result says so
    let mut seen: Vec<Value> = Vec::new();
    for text in ["Rupert, Idaho", "Rupert ID", "rupert id", "rupert, id", "rupert", "RUPERT", "Rupret", "Rupet", "42.6166,-113.6747"] {
        let v = weather(&env, Some(pack.geo()), Some(text), None).unwrap_or_else(|e| panic!("{text}: {}", e.to_json()));
        assert_eq!(v["place"], "Burley, ID", "{text}");
        assert_eq!(v["distance_from_asked_km"], 13, "{text}: {v}");
        assert_eq!(v["items"][0]["address"], "live:weather/burley/now", "{text}");
        let asked = v["asked_place"].as_str().unwrap().to_string();
        assert!(asked == "Rupert, ID" || asked == "42.6166,-113.6747", "{text}: asked_place {asked}");
        seen.push(v["items"].clone());
    }
    // the same data every time
    assert!(seen.windows(2).all(|w| w[0] == w[1]));
    // field order: place, then the two new fields, then fetched_at
    let v = weather(&env, Some(pack.geo()), Some("Rupert"), None).unwrap();
    let keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
    assert_eq!(&keys[..5], ["source", "place", "asked_place", "distance_from_asked_km", "fetched_at"]);
    // the place that has the data: no extra fields (the saved place itself, or a place a km away at most)
    let own = weather(&env, Some(pack.geo()), Some("burley"), None).unwrap();
    assert_eq!(own["place"], "Burley, ID");
    assert!(own.get("asked_place").is_none() && own.get("distance_from_asked_km").is_none(), "{own}");
    let town = weather(&env, Some(pack.geo()), Some("Burley, Idaho"), None).unwrap();
    assert_eq!(town["place"], "Burley, ID");
    assert!(town.get("distance_from_asked_km").is_none(), "{town}");
}

#[test]
fn a_town_with_no_data_in_range_is_no_data_naming_the_nearest() {
    let pack = Pack::fixture("far");
    let (env, _srv) = burley_data("far");
    let e = weather(&env, Some(pack.geo()), Some("Boise, Idaho"), None).unwrap_err();
    assert_eq!(e.code, "no_data");
    assert_eq!(
        e.to_json().to_string(),
        r#"{"ok":false,"error":{"type":"no_data","detail":"no weather data within 30 km of Boise, ID; the nearest place with data is Burley, ID, 230 km away"}}"#
    );
    // not geocode_empty, which is for a name that is no place at all
    let e = weather(&env, Some(pack.geo()), Some("Xqzvk"), None).unwrap_err();
    assert_eq!(e.code, "geocode_empty");
    // nothing stored at all: the old wording
    let (empty, _s) = weather_env("far-empty");
    let e = weather(&empty, Some(pack.geo()), Some("Rupert"), None).unwrap_err();
    assert_eq!((e.code.as_str(), e.detail.as_str()), ("no_data", "no weather data has been downloaded for Rupert, ID"));
}

#[test]
fn the_radius_is_config() {
    let pack = Pack::fixture("radius");
    let (env, _srv) = burley_data("radius");
    let args = json!({"source": "weather", "place": "Rupert"});
    let e = env.tool_with(args.clone(), None, LATER, Some(pack.geo()), 10.0).unwrap_err();
    assert_eq!(e.detail, "no weather data within 10 km of Rupert, ID; the nearest place with data is Burley, ID, 13 km away");
    assert_eq!(env.tool_with(args.clone(), None, LATER, Some(pack.geo()), 13.5).unwrap()["place"], "Burley, ID");
    // the default is 30 km, and a config without the key gets it
    let cfg: LiveCfg = serde_json::from_str(r#"{"db_path":"a","sources_dir":"b"}"#).unwrap();
    assert_eq!(cfg.live_radius_km, 30.0);
    let cfg: LiveCfg = serde_json::from_str(r#"{"db_path":"a","sources_dir":"b","live_radius_km":12.5}"#).unwrap();
    assert_eq!(cfg.live_radius_km, 12.5);
}

#[test]
fn the_phones_position_takes_the_nearest_stored_data_too() {
    let pack = Pack::fixture("fix");
    let (env, _srv) = burley_data("fix");
    // 10 km from Burley, with no data stored at this position
    let here = Location { lat: 42.60, lon: -113.70, accuracy_m: Some(12.0), fixed_at: "2026-10-25T11:40:00-06:00".into() };
    let v = weather(&env, Some(pack.geo()), None, Some(&here)).unwrap();
    assert_eq!(v["place"], "Burley, ID");
    assert_eq!(v["asked_place"], "current location");
    assert_eq!(v["distance_from_asked_km"], 10);
    // data stored at this very position wins and says nothing extra
    env.weather(json!({"source": "weather", "place": {"key": "at:42.60,-113.70", "name": "current location", "lat": 42.60, "lon": -113.70}, "now": T0})).unwrap();
    let v = weather(&env, Some(pack.geo()), None, Some(&here)).unwrap();
    assert_eq!(v["place"], "current location");
    assert!(v.get("asked_place").is_none());
    // a fix with nothing stored within the radius
    let far = Location { lat: 43.6150, lon: -116.2023, accuracy_m: None, fixed_at: "2026-10-25T11:40:00-06:00".into() };
    let e = weather(&env, Some(pack.geo()), None, Some(&far)).unwrap_err();
    assert_eq!(e.code, "no_data");
    assert!(e.detail.contains("current location") && e.detail.contains("Burley, ID"), "{}", e.detail);
    // and no fix, no place: as before
    assert_eq!(weather(&env, Some(pack.geo()), None, None).unwrap_err().code, "no_location");
}

#[test]
fn without_a_places_pack_only_the_exact_name_matches() {
    let (env, _srv) = burley_data("nopack");
    // saved place by key or name, coordinates by text
    for text in ["burley", "Burley, ID", "BURLEY, id"] {
        assert_eq!(weather(&env, None, Some(text), None).unwrap()["place"], "Burley, ID", "{text}");
    }
    let v = weather(&env, None, Some("42.60,-113.70"), None).unwrap();
    assert_eq!((v["place"].as_str(), v["distance_from_asked_km"].as_i64()), (Some("Burley, ID"), Some(10)));
    // a town name is not a saved place, and nothing resolves it
    for text in ["Rupert", "Rupert, Idaho", "Burley Idaho"] {
        let e = weather(&env, None, Some(text), None).unwrap_err();
        assert_eq!(e.code, "geocode_empty", "{text}");
    }
}

#[test]
fn fresh_data_a_little_farther_beats_expired_data_nearer() {
    let srv = Server::start(vec![("/alerts/active", fixture("nws_boise.json"))]);
    let env = Env::new("fresh", vec![("alerts.json", real_source("alerts.json"), Some((srv.port, "/alerts/active")))]);
    let pack = Pack::fixture("fresh");
    let save = |k: &str, n: &str, lat: f64, lon: f64| env.places.save(&json!({"key": k, "name": n, "lat": lat, "lon": lon}).to_string()).unwrap();
    save("declo", "Declo, ID", 42.5238, -113.6122);
    save("burley", "Burley, ID", 42.5357, -113.7928);
    let fetch = |k: &str, now: &str| env.live.fetch(&json!({"source": "alerts", "place": k, "now": now}).to_string(), &env.places).unwrap();
    fetch("declo", "2026-10-25T00:00:00-06:00"); // valid 6 hours: over at 06:00
    fetch("burley", "2026-10-25T10:00:00-06:00"); // over at 16:00
    let near_declo = |now: &str| env.tool_with(json!({"source": "alerts", "place": "Declo"}), None, now, Some(pack.geo()), 30.0);
    // Declo's own data is the nearest and has run out; Burley's is still good: Burley's is used
    let v = near_declo("2026-10-25T11:00:00-06:00").unwrap();
    assert_eq!(v["place"], "Burley, ID");
    assert_eq!(v["asked_place"], "Declo, ID");
    // both over: the nearest one's expiry is what the model is told
    let e = near_declo("2026-10-25T17:00:00-06:00").unwrap_err();
    assert_eq!((e.code.as_str(), e.detail.as_str()), ("expired", "alerts data expired 2026-10-25"));
}

// ---- the real Idaho pack: CS_TEST_IDAHO_PACK=<places.sqlite>, read only ----

#[test]
fn island_park_through_the_real_idaho_pack() {
    let Some(path) = std::env::var("CS_TEST_IDAHO_PACK").ok().filter(|s| !s.is_empty()) else {
        eprintln!("CS_TEST_IDAHO_PACK not set: skipping");
        return;
    };
    let pack = Pack::real(&path);
    let (env, _srv) = weather_env("real");
    // weather was downloaded for Ashton, about 40 km from Island Park
    env.places.save(r#"{"key":"ashton","name":"Ashton, ID","lat":44.0716,"lon":-111.4483}"#).unwrap();
    env.weather(json!({"source": "weather", "place": "ashton", "now": T0})).unwrap();
    let ask = |text: &str, radius: f64| env.tool_with(json!({"source": "weather", "place": text}), None, LATER, Some(pack.geo()), radius);

    // every way of writing the town, and a misspelling, is the one town
    let mut asked = std::collections::BTreeSet::new();
    for text in ["Island Park, Idaho", "Island Park ID", "island park", "ISLAND PARK", "Islnd Park", "Ilsand Park", "Island Parc", "44.4238,-111.3714"] {
        let v = ask(text, 50.0).unwrap_or_else(|e| panic!("{text}: {}", e.to_json()));
        assert_eq!(v["place"], "Ashton, ID", "{text}");
        let km = v["distance_from_asked_km"].as_i64().unwrap();
        assert!((38..=42).contains(&km), "{text}: {km} km");
        asked.insert(v["asked_place"].as_str().unwrap().to_string());
        eprintln!("{text:22} -> asked_place {:?}, data for {:?}, {km} km", v["asked_place"], v["place"]);
    }
    // the five names of the town give one asked_place; the coordinates are shown as written
    assert_eq!(asked.len(), 2, "{asked:?}");
    assert!(asked.contains("Island Park, ID") && asked.contains("44.4238,-111.3714"), "{asked:?}");

    // the default radius (30 km) does not reach Ashton: no_data, naming it
    let e = ask("Island Park, Idaho", 30.0).unwrap_err();
    assert_eq!(e.code, "no_data");
    assert!(e.detail.starts_with("no weather data within 30 km of Island Park, ID; the nearest place with data is Ashton, ID, 4"), "{}", e.detail);
    eprintln!("{}", e.to_json());

    // a town in range of Ashton gets Ashton's data; one out of range is no_data naming Ashton; a name that is no place is geocode_empty
    let v = ask("St. Anthony, Idaho", 30.0).unwrap();
    assert_eq!((v["place"].as_str(), v["asked_place"].as_str()), (Some("Ashton, ID"), Some("St. Anthony, ID")));
    let km = v["distance_from_asked_km"].as_i64().unwrap();
    assert!((20..=24).contains(&km), "{km}");
    let e = ask("Driggs", 30.0).unwrap_err();
    assert_eq!(e.code, "no_data");
    assert!(e.detail.starts_with("no weather data within 30 km of Driggs, ID; the nearest place with data is Ashton, ID, 4"), "{}", e.detail);
    eprintln!("St. Anthony -> {} km; Driggs -> {}", km, e.to_json());
    assert_eq!(ask("Xqzvkj Qlmn", 30.0).unwrap_err().code, "geocode_empty");

    // the phone at Island Park
    let here = Location { lat: 44.4238, lon: -111.3714, accuracy_m: Some(8.0), fixed_at: "2026-10-25T11:40:00-06:00".into() };
    let v = env.tool_with(json!({"source": "weather"}), Some(&here), LATER, Some(pack.geo()), 50.0).unwrap();
    assert_eq!((v["place"].as_str(), v["asked_place"].as_str()), (Some("Ashton, ID"), Some("current location")));
}

// ---- the geocoder fills the place object's state, county and country for a fetch ----

/// A geocoder that knows every fact the place object can carry.
struct Full;

impl Geocoder for Full {
    fn resolve(&self, _text: &str, _near: Option<(f64, f64)>) -> Option<(String, f64, f64)> {
        Some(("Burley, ID".into(), 42.536, -113.792))
    }
    fn resolve_full(&self, text: &str, near: Option<(f64, f64)>) -> Option<cache_tool::places::ResolvedPlace> {
        let (name, lat, lon) = self.resolve(text, near)?;
        Some(cache_tool::places::ResolvedPlace {
            name,
            lat,
            lon,
            state: Some("ID".into()),
            state_name: Some("Idaho".into()),
            county: Some("Cassia".into()),
            country: Some("US".into()),
        })
    }
}

#[test]
fn a_geocoded_place_object_carries_state_county_and_country() {
    let places = UserStore::new(std::env::temp_dir().join(format!("cache-live-hook-user-{}.sqlite", std::process::id())));
    let o = cache_live::fetch::geocoded_place(Some(json!("Burley")), &places, Some(&Full)).unwrap();
    assert_eq!(
        o,
        json!({"key": "at:42.54,-113.79", "name": "Burley, ID", "lat": 42.536, "lon": -113.792,
               "state": "ID", "state_name": "Idaho", "county": "Cassia", "country": "US"})
    );
    // no geocoder, a place object, or a saved place's name: used exactly as given
    assert_eq!(cache_live::fetch::geocoded_place(Some(json!("Burley")), &places, None), Some(json!("Burley")));
    assert_eq!(cache_live::fetch::geocoded_place(Some(burley()), &places, Some(&Full)), Some(burley()));
    places.save(r#"{"key":"home","name":"Home","lat":42.0,"lon":-113.0}"#).unwrap();
    assert_eq!(cache_live::fetch::geocoded_place(Some(json!("Home")), &places, Some(&Full)), Some(json!("Home")));
    let _ = std::fs::remove_file(std::env::temp_dir().join(format!("cache-live-hook-user-{}.sqlite", std::process::id())));
}

#[test]
fn a_definition_using_state_gets_id_for_an_idaho_town() {
    let pack = Pack::fixture("hook");
    let srv = Server::start(vec![("/v1/forecast", fixture("openmeteo_burley.json"))]);
    let mut d = real_source("weather.json");
    let u = d["request"]["url"].as_str().unwrap().to_string();
    d["request"]["url"] = json!(format!("{u}&area={{state}}-{{state_name}}-{{country}}"));
    let env = Env::new("hook", vec![("weather.json", d, Some((srv.port, "/v1/forecast")))]);
    let req = json!({"source": "weather", "place": "Island Park, Idaho", "now": T0}).to_string();

    let out: Value = serde_json::from_str(&env.live.fetch_with(&req, &env.places, Some(pack.geo())).unwrap()).unwrap();
    assert_eq!(out["fetched"], true);
    assert_eq!(out["place"]["name"], "Island Park, ID");
    assert_eq!(out["place"]["key"], "at:44.42,-111.37");
    let url = srv.last_url.lock().unwrap().clone();
    assert!(url.contains("area=ID-Idaho-US"), "{url}");
    assert!(url.contains("latitude=44.4238&longitude=-111.3714"), "{url}");

    // what was stored is what live_data reads back for that town
    let t = env.tool_with(json!({"source": "weather", "place": "Island Park"}), None, LATER, Some(pack.geo()), 30.0).unwrap();
    assert_eq!(t["place"], "Island Park, ID");

    // without a geocoder the name is not a saved place: unchanged behaviour
    assert_eq!(env.live.fetch(&req, &env.places).unwrap_err().code, "not_found");
    // a place object that gives no state still says the state is not known
    let bare = json!({"source": "weather", "place": {"key": "x", "name": "Somewhere", "lat": 44.0, "lon": -111.0}, "now": T0}).to_string();
    let e = env.live.fetch_with(&bare, &env.places, Some(pack.geo())).unwrap_err();
    assert_eq!(e.code, "fetch_failed");
    assert_eq!(e.message, "this source needs the place's state, which is not known for Somewhere");
}
