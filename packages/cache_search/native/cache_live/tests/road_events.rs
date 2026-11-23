//! The road sources the app makes (511 road events, WZDx road work): the definitions the app builds from its data file
//! (tests/fixtures/road/generated/, written by app/tool/road_defs_fixtures.dart and kept equal to what the app makes by a Dart test)
//! read recorded-shape answers written from the documented fields. No real site is called: a server on this machine answers.
//!
//! What the tests pin:
//! - every generated definition passes the core's check;
//! - Idaho's definitions give the model what the published ones gave it: the tool definition (ids and descriptions) and the tool's
//!   result for the same answer are byte for byte the same, and the new `app` values are in `cs_live_get` only;
//! - the field variations of the platform sites (SURVEY.md): no detour fields, no subtype, a direction of "None", a detour written as
//!   one string or as a list, a zero planned end, a full closure written as "true" or 1, a polyline that does not decode;
//! - winter road conditions, with and without an id, an area name or geometry;
//! - WZDx 4.0, 4.1 and 4.2, a line and a point.

use cache_live::def::SourceDef;
use cache_live::{Live, LiveCfg, LiveDataTool};
use cache_tool::{Tool, ToolCtx, ToolOutput};
use cache_user::UserStore;
use serde_json::{json, Value};
use std::path::PathBuf;

const NOW: &str = "2026-11-22T12:30:00-07:00";

fn manifest() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
}

fn fixture(name: &str) -> String {
    std::fs::read_to_string(manifest().join("tests/fixtures/road").join(name)).unwrap_or_else(|e| panic!("{name}: {e}"))
}

fn json_fixture(name: &str) -> Value {
    serde_json::from_str(&fixture(name)).unwrap()
}

fn generated(name: &str) -> Value {
    json_fixture(&format!("generated/{name}"))
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

fn boise() -> Value {
    json!({"key": "at:43.61,-116.28", "name": "current location", "lat": 43.61, "lon": -116.28})
}

struct Env {
    dir: PathBuf,
    live: Live,
    places: UserStore,
    id: String,
}

impl Env {
    /// Installs `def` with its address pointed at the server on this machine and its key left to the test (the key is a header or a
    /// query value the server ignores).
    fn new(name: &str, def: &Value, port: u16) -> Env {
        let dir = std::env::temp_dir().join(format!("cache-live-road-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("sources")).unwrap();
        let mut d = def.clone();
        let id = d["id"].as_str().unwrap().to_string();
        d["request"]["url"] = json!(format!("http://127.0.0.1:{port}/feed"));
        if let Some(h) = d["request"].as_object_mut() {
            h.remove("headers");
        }
        d.as_object_mut().unwrap().remove("api_key");
        std::fs::write(dir.join(format!("sources/{id}.json")), serde_json::to_string_pretty(&d).unwrap()).unwrap();
        Env {
            live: Live::new(LiveCfg::new(dir.join("live.sqlite").to_string_lossy(), dir.join("sources").to_string_lossy())),
            places: UserStore::new(dir.join("user.sqlite")),
            dir,
            id,
        }
    }
    fn req(&self) -> String {
        json!({"source": self.id, "place": boise(), "now": NOW}).to_string()
    }
    fn fetch(&self) -> Value {
        serde_json::from_str(&self.live.fetch(&self.req(), &self.places).unwrap()).unwrap_or_else(|e| panic!("{e}"))
    }
    fn get(&self) -> Value {
        serde_json::from_str(&self.live.get(&self.req(), &self.places).unwrap()).unwrap()
    }
    fn tool_ctx<'a>(&'a self) -> ToolCtx<'a> {
        ToolCtx { location: None, places: &self.places, now: NOW, geocoder: None, live_fetcher: None }
    }
    /// What the model reads: the tool's definition and its result, as text.
    fn model(&self) -> (String, String) {
        let t = LiveDataTool::new(self.live.cfg.clone());
        let schema = t.schema().unwrap().to_string();
        let out = match t.run(&self.tool_ctx(), &json!({"source": self.id, "place": "43.61,-116.28"})).unwrap() {
            ToolOutput::Json(v) => v.to_string(),
            ToolOutput::Text(_) | ToolOutput::Pieces(_) => panic!("text"),
        };
        (schema, out)
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn item<'a>(got: &'a Value, key: &str) -> &'a Value {
    got["items"].as_array().unwrap().iter().find(|i| i["address"].as_str().unwrap().ends_with(&format!("/{key}"))).unwrap_or_else(|| panic!("no item {key}: {got}"))
}

#[test]
fn every_generated_definition_passes_the_core_check() {
    let dir = manifest().join("tests/fixtures/road/generated");
    let mut n = 0;
    for e in std::fs::read_dir(dir).unwrap() {
        let p = e.unwrap().path();
        let text = std::fs::read_to_string(&p).unwrap();
        SourceDef::check(&text).unwrap_or_else(|e| panic!("{}: {e:?}", p.display()));
        n += 1;
    }
    assert!(n >= 11, "{n} definitions");
}

#[test]
fn idaho_events_give_the_model_what_the_published_definition_gave_it_and_give_the_app_the_map_values() {
    let port = serve(fixture("events-idaho.json"));
    let published = Env::new("ev-pub", &json_fixture("idaho511-events.published.json"), port);
    let now = Env::new("ev-new", &generated("idaho-events.json"), port);
    let (a, b) = (now.fetch(), published.fetch());
    assert_eq!(a["items"].as_array().unwrap().len(), 3, "{a}");
    // the model: the tool definition (ids and descriptions) and the result, byte for byte
    let (ms, mr) = now.model();
    let (ps, pr) = published.model();
    assert_eq!(ms, ps, "the tool definition the model reads");
    assert_eq!(mr, pr, "the tool result the model reads");
    assert!(mr.contains("I-84: Bridge repair"), "{mr}");
    for hidden in ["\"app\"", "EncodedPolyline", "kabiG", "DetourPolyline"] {
        assert!(!mr.contains(hidden), "{hidden} is in what the model reads: {mr}");
    }
    // the app: only `app` differs, and it has what the map needs, as the site wrote it
    for (x, y) in a["items"].as_array().unwrap().iter().zip(b["items"].as_array().unwrap()) {
        let mut x = x.clone();
        x.as_object_mut().unwrap().remove("app");
        assert_eq!(&x, y);
    }
    let closure = item(&a, "sample-1");
    assert_eq!(closure["app"]["type"], "closures");
    assert_eq!(closure["app"]["full"], true);
    assert_eq!(closure["app"]["dir"], "Westbound");
    assert_eq!(closure["app"]["line"], "kabiGpg}dU?etBXqYVaG|@cL`@gD");
    assert_eq!(closure["app"]["detour"], "kabiG||_eU^ijBfKh@t\\FJi@E}L?mtCRgz@MY{IO");
    assert_eq!(closure["app"]["steps"].as_array().unwrap().len(), 2);
    assert_eq!(closure["app"]["start"], 1795370000);
    assert_eq!(closure["app"]["until"], 1795456400);
    assert_eq!(now.get()["items"][0]["app"], a["items"][0]["app"]);
}

#[test]
fn idaho_work_zone_feed_gives_the_model_what_the_published_definition_gave_it() {
    let port = serve(fixture("wzdx-41.json"));
    let published = Env::new("wz-pub", &json_fixture("wzdx-idaho.published.json"), port);
    let now = Env::new("wz-new", &generated("wzdx-idaho.json"), port);
    let (a, b) = (now.fetch(), published.fetch());
    // the published label drops a work zone with an unknown direction (wz-3); the model's view is kept as it is
    assert_eq!(a["items"].as_array().unwrap().len(), 2, "{a}");
    let (ms, mr) = now.model();
    let (ps, pr) = published.model();
    assert_eq!(ms, ps);
    assert_eq!(mr, pr);
    assert!(!mr.contains("\"app\"") && !mr.contains("LineString"), "{mr}");
    for (x, y) in a["items"].as_array().unwrap().iter().zip(b["items"].as_array().unwrap()) {
        let mut x = x.clone();
        x.as_object_mut().unwrap().remove("app");
        assert_eq!(&x, y);
    }
    let zone = item(&a, "wz-1");
    assert_eq!(zone["app"]["geom"]["type"], "LineString");
    assert_eq!(zone["app"]["impact"], "all-lanes-closed");
    assert_eq!(zone["app"]["until"], "2026-11-30T12:00:00Z");
    assert_eq!(zone["app"]["road"], json!(["I-84"]));
}

#[test]
fn idaho_winter_roads_differ_from_the_published_definition_by_one_added_details_field() {
    let port = serve(fixture("conditions-v3.json"));
    let published = Env::new("wr-pub", &json_fixture("idaho511-winter-roads.published.json"), port);
    let now = Env::new("wr-new", &generated("idaho-conditions.json"), port);
    let (a, b) = (now.fetch(), published.fetch());
    let (ms, _) = now.model();
    let (ps, _) = published.model();
    assert_eq!(ms, ps, "the tool definition the model reads");
    assert_eq!(a["items"].as_array().unwrap().len(), 2);
    for (x, y) in a["items"].as_array().unwrap().iter().zip(b["items"].as_array().unwrap()) {
        assert_eq!(x["label"], y["label"]);
        let mut fx = x["fields"].as_object().unwrap().clone();
        let details = fx.remove("Details");
        assert!(details.is_some(), "the v3 resource gives a description");
        assert_eq!(&Value::Object(fx), &y["fields"]);
    }
}

#[test]
fn the_field_variations_of_the_511_sites_are_tolerated() {
    let port = serve(fixture("events-variations.json"));
    // Newfoundland's template (a site other than Idaho: the tolerant fields)
    let env = Env::new("var", &generated("nl-events.json"), port);
    let got = env.fetch();
    assert_eq!(got["items"].as_array().unwrap().len(), 5, "every event is kept: {got}");

    // Ontario and Connecticut list no detour fields: no Detour line, no detour in app, nothing broken
    let on = item(&got, "on-1");
    assert!(on["fields"].get("Detour").is_none(), "{on}");
    assert!(on["app"].get("detour").is_none() && on["app"].get("steps").is_none());
    assert_eq!(on["app"]["line"], "kabiGpg}dU?etBXqYVaG|@cL`@gD");
    assert_eq!(on["fields"]["Direction"], "Westbound");

    // Georgia lists no EventSubType: the label falls back to the event type
    let ga = item(&got, "ga-1");
    assert!(ga["fields"].get("Detail").is_none(), "{ga}");
    assert_eq!(ga["label"], "I-75: accidentsAndIncidents");
    assert_eq!(ga["fields"]["Type"], "crash or incident");

    // Newfoundland: a direction of None is no direction; a zero planned end is no end; "true" is a full closure; a string detour is read
    let nl = item(&got, "nl-1");
    assert!(nl["fields"].get("Direction").is_none(), "{nl}");
    assert!(nl["fields"].get("Planned end").is_none(), "no 1970 date: {nl}");
    assert_eq!(nl["fields"]["All lanes blocked"], "yes");
    assert_eq!(nl["fields"]["Detour"], "Sample detour as one string.");
    assert_eq!(nl["app"]["steps"], "Sample detour as one string.");
    assert_eq!(nl["app"]["until"], 0);

    // "West" for "Westbound", a new event type, a full closure written as 1, a line that is not a polyline: all kept
    let w = item(&got, "w-1");
    assert_eq!(w["fields"]["Direction"], "West");
    assert_eq!(w["fields"]["Type"], "other");
    assert_eq!(w["fields"]["All lanes blocked"], "yes");
    assert_eq!(w["app"]["full"], 1);

    // no Comment on Arizona, Yukon, Alaska, Alberta, Louisiana; an unknown direction is no direction
    let ab = item(&got, "ab-1");
    assert!(ab["fields"].get("Comment").is_none() && ab["fields"].get("Direction").is_none(), "{ab}");
}

#[test]
fn winter_road_conditions_read_with_and_without_an_id_an_area_name_or_geometry() {
    // a site with the full field list (v3 winterroads)
    let env = Env::new("c-full", &generated("idaho-conditions.json"), serve(fixture("conditions-v3.json")));
    let got = env.fetch();
    assert_eq!(item(&got, "c1")["label"], "I-84: Sample section");
    assert!(item(&got, "c2")["fields"].get("Visibility").is_none(), "Idaho's published fields stay as they were");
    assert_eq!(item(&got, "c2")["fields"]["Details"], "Sample: snow packed.");
    // Ontario: no Id and no AreaName, a Condition: the key is made from the road and the place
    let on = Env::new("c-on", &generated("ontario-conditions.json"), serve(fixture("conditions-ontario.json")));
    let got = on.fetch();
    let i = &got["items"][0];
    assert_eq!(i["label"], "Hwy 17: Sample stretch");
    assert_eq!(i["fields"]["Condition"], "Snow covered");
    assert_eq!(i["fields"]["Visibility"], "Poor");
    assert!(i["address"].as_str().unwrap().ends_with("Hwy 17: Sample stretch") || i["address"].as_str().unwrap().contains("Hwy"), "{i}");
    // North Carolina: no road name and no geometry: a list only
    let nc = Env::new("c-nc", &generated("nc-conditions.json"), serve(fixture("conditions-nc.json")));
    let got = nc.fetch();
    let i = &got["items"][0];
    assert_eq!(i["label"], "Sample county: Sample");
    assert_eq!(i["fields"]["Details"], "Sample: ice.");
}

#[test]
fn wzdx_versions_4_0_4_1_and_4_2_read_alike_with_a_line_and_a_point() {
    for (v, file) in [("4.0", "wzdx-40.json"), ("4.1", "wzdx-41.json"), ("4.2", "wzdx-42.json")] {
        let env = Env::new(&format!("wz{v}"), &generated("wzdx-open.json"), serve(fixture(file)));
        let got = env.fetch();
        assert_eq!(got["items"].as_array().unwrap().len(), 3, "{v}: {got}");
        let wz1 = item(&got, "wz-1");
        assert_eq!(wz1["label"], "I-84 eastbound", "{v}");
        assert_eq!(wz1["fields"]["Lanes"], "all-lanes-closed");
        assert_eq!(wz1["fields"]["Speed limit in zone"], "50 mph");
        assert_eq!(wz1["app"]["geom"]["type"], "LineString");
        // most restrictive first
        assert_eq!(got["items"][0]["address"].as_str().unwrap().rsplit('/').next().unwrap(), "wz-1");
        let pt = item(&got, "wz-3");
        assert_eq!(pt["app"]["geom"]["type"], "Point", "{v}");
        assert_eq!(pt["label"], "SH-55", "a work zone with no direction is still listed");
    }
}

#[test]
fn a_keyed_feed_puts_the_key_where_its_definition_says_and_never_in_the_stored_definition() {
    let q = generated("wzdx-query-key.json");
    assert_eq!(q["request"]["url"], "https://www.drivenc.gov/api/wzdx?key={api_key}");
    assert_eq!(q["api_key"]["alias"], "wzdx.ncdot");
    let h = generated("wzdx-header-key.json");
    assert_eq!(h["request"]["url"], "https://example.org/wzdx/ohio");
    assert_eq!(h["request"]["headers"]["Authorization"], "APIKEY {api_key}");
    for d in [&q, &h] {
        let text = d.to_string();
        assert!(!text.contains("token") && !text.contains("access_token"), "{text}");
    }
}
