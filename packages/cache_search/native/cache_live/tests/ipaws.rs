//! The FEMA IPAWS connector (`ipaws-alerts-near`, cache-packs connectors/alerts) on recorded CAP messages, against a stand-in
//! server on this machine. The samples in tests/fixtures/ipaws are real messages from the public IPAWS-OPEN EAS feed (2026-07-16)
//! and FEMA's OpenFEMA archive (an NWS flash flood warning of 2026-10-29), with their XML signatures taken out and the one
//! personal e-mail address replaced; the feed is the real one of 2026-10-30 (three expired entries) with the samples' entries
//! in front. The definition is the catalogue's file; only its two hosts are pointed at the stand-in server.

use cache_live::{Live, LiveCfg, LiveDataTool};
use cache_tool::{Tool, ToolCtx, ToolOutput};
use cache_user::UserStore;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

fn fixture(name: &str) -> String {
    std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/ipaws").join(name)).unwrap()
}

/// The stand-in for api.weather.gov (the county a point is in) and apps.fema.gov (the feed and its CAP documents).
struct Srv {
    port: u16,
    log: Arc<Mutex<Vec<String>>>,
}

type Docs = Vec<(&'static str, String)>;

impl Srv {
    fn start(feed: String, docs: Docs) -> Srv {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let port = server.server_addr().to_ip().unwrap().port();
        let log: Arc<Mutex<Vec<String>>> = Arc::new(Mutex::new(Vec::new()));
        let l2 = log.clone();
        let base = format!("http://127.0.0.1:{port}");
        let feed = feed.replace("https://apps.fema.gov", &base);
        std::thread::spawn(move || {
            for req in server.incoming_requests() {
                let url = req.url().to_string();
                l2.lock().unwrap().push(url.clone());
                let path = url.split('?').next().unwrap_or("").to_string();
                let (status, body) = if path == "/zones" {
                    let point = url.split("point=").nth(1).unwrap_or("").split('&').next().unwrap_or("").to_string();
                    let county = match point.as_str() {
                        "48.8000,-116.3500" | "48.9500,-116.1000" => Some(("IDC021", "ID", "Boundary")),
                        "43.6150,-116.2023" => Some(("IDC001", "ID", "Ada")),
                        "47.0000,-116.0000" => Some(("IDC035", "ID", "Clearwater")),
                        "42.6700,-122.8800" => Some(("ORC029", "OR", "Jackson")),
                        "33.3600,-105.6800" => Some(("NMC027", "NM", "Lincoln")),
                        _ => None,
                    };
                    match county {
                        Some((id, st, name)) => (200, json!({"type": "FeatureCollection", "features": [{"type": "Feature", "geometry": null,
                            "properties": {"id": id, "type": "county", "name": name, "state": st}}]}).to_string()),
                        None => (404, r#"{"title":"Not Found"}"#.to_string()),
                    }
                } else if path == "/IPAWSOPEN_EAS_SERVICE/rest/feed" {
                    (200, feed.clone())
                } else if let Some(id) = path.strip_prefix("/IPAWSOPEN_EAS_SERVICE/rest/eas/") {
                    match docs.iter().find(|(d, _)| *d == id) {
                        Some((_, body)) => (200, body.clone()),
                        // what FEMA answers for an entry whose alert is over (seen 2026-10-30)
                        None => (403, format!(r#"{{"status":403,"error":"Forbidden","message":"The message with id {id} has already expired."}}"#)),
                    }
                } else {
                    (404, "no".to_string())
                };
                let _ = req.respond(tiny_http::Response::from_string(body).with_status_code(status));
            }
        });
        Srv { port, log }
    }
    fn base(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }
    fn count(&self) -> usize {
        self.log.lock().unwrap().len()
    }
    fn docs_asked(&self) -> usize {
        self.log.lock().unwrap().iter().filter(|u| u.contains("/rest/eas/")).count()
    }
}

/// The catalogue's definition, sent to the stand-in server.
fn definition(base: &str) -> String {
    fixture("ipaws-alerts-near.json").replace("https://api.weather.gov", base).replace("https://apps.fema.gov", base)
}

fn samples() -> Docs {
    vec![("300130859542", fixture("cap_idaho_cem.xml")), ("300130856756", fixture("cap_oregon_evi.xml")), ("300133900001", fixture("cap_nws_ffw.xml"))]
}

struct Env {
    dir: PathBuf,
    live: Live,
    places: UserStore,
}

impl Env {
    fn new(name: &str, def: &str) -> Env {
        let dir = std::env::temp_dir().join(format!("cache-live-ipaws-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("sources")).unwrap();
        std::fs::write(dir.join("sources").join("ipaws-alerts-near.json"), def).unwrap();
        let live = Live::new(LiveCfg::new(dir.join("live.sqlite").to_string_lossy(), dir.join("sources").to_string_lossy()));
        let places = UserStore::new(dir.join("user.sqlite"));
        Env { dir, live, places }
    }
    fn fetch(&self, place: Value, now: &str, force: bool) -> Value {
        let r = json!({"source": "ipaws-alerts-near", "place": place, "now": now, "force": force});
        serde_json::from_str(&self.live.fetch(&r.to_string(), &self.places).unwrap()).unwrap()
    }
    fn tool(&self, place: &str, now: &str) -> Value {
        let t = LiveDataTool::new(self.live.cfg.clone());
        let ctx = ToolCtx { location: None, places: &self.places, now, geocoder: None, live_fetcher: None };
        match t.run(&ctx, &json!({"source": "ipaws-alerts-near", "place": place})).unwrap() {
            ToolOutput::Json(v) => v,
            ToolOutput::Text(_) => panic!("text"),
        }
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn place(key: &str, lat: f64, lon: f64) -> Value {
    json!({"key": key, "name": key, "lat": lat, "lon": lon})
}

fn labels(v: &Value) -> Vec<String> {
    v["items"].as_array().unwrap().iter().map(|i| i["label"].as_str().unwrap().to_string()).collect()
}

const JULY: &str = "2026-07-16T00:00:00-06:00";
const OCTOBER: &str = "2026-10-29T14:00:00-06:00";

#[test]
fn the_catalogue_definition_reads() {
    let d = cache_live::def::SourceDef::parse(&fixture("ipaws-alerts-near.json")).unwrap();
    assert_eq!(d.format, 3);
    assert_eq!(d.id, "ipaws-alerts-near");
}

#[test]
fn an_evacuation_order_inside_its_polygon_with_the_items_the_model_reads() {
    let srv = Srv::start(fixture("feed.xml"), samples());
    let env = Env::new("polygon", &definition(&srv.base()));
    let r = env.fetch(place("bonners", 48.80, -116.35), JULY, false);
    assert_eq!(labels(&r), ["Wildfire Immediate Evacuation Alert"]);
    let i = &r["items"][0];
    assert!(i["address"].as_str().unwrap().ends_with("/AS-ID-de78a02d-8bf9-4528-8f84-fd417bbcaa5b"), "{}", i["address"]);
    // the app's view has the alert's area (for de-duplication); the model's does not (below)
    assert_eq!(i["area"]["type"], "GeometryCollection");
    // one county lookup, the feed, and its six documents (three of them expired: answered 403, left out without a failure)
    assert_eq!(srv.count(), 8);
    assert!(r.get("missing_requests").is_none(), "{r}");
    // the next fetch asks for the feed only: the county and every document, the refused ones too, are kept
    let again = env.fetch(place("bonners", 48.80, -116.35), JULY, true);
    assert_eq!(labels(&again), ["Wildfire Immediate Evacuation Alert"]);
    assert_eq!(srv.count(), 9);
    assert_eq!(srv.docs_asked(), 6);

    let order: Vec<&String> = r["items"][0]["fields"].as_object().unwrap().keys().collect();
    assert_eq!(order, ["Event", "Severity", "Issued by", "Area", "Expires", "Instructions"]);
    // exactly what live_data gives the model: the generic shape, plain labels, "Issued by" as the sender wrote it
    let t = env.tool("48.80,-116.35", JULY);
    assert_eq!(
        t,
        json!({
            "source": {"id": "ipaws-alerts-near", "title": "Emergency alerts", "provider": "FEMA IPAWS"},
            "place": "bonners",
            "fetched_at": "2026-07-15T23:00:00-07:00",
            "valid_until": "2026-07-16T05:00:00-07:00",
            "age": "less than a minute old",
            "expired": false,
            "items": [{
                "address": "live:ipaws-alerts-near/bonners/AS-ID-de78a02d-8bf9-4528-8f84-fd417bbcaa5b",
                "label": "Wildfire Immediate Evacuation Alert",
                "time": "2026-07-15T21:54:41-07:00",
                "fields": {
                    "Event": "Civil Emergency Message",
                    "Severity": "extreme",
                    "Issued by": "200033, Idaho State Communications Center, Idaho Office of Emergency Management",
                    "Area": "Boundary County",
                    "Expires": "2026-07-16 01:54",
                    "Instructions": "The Boundary County Sheriff's Office has issued an immediate wildfire evacuation order for the following areas in Bonners Ferry.: Turner's Hill Road from the 3000 block to highway 95. All Holmes Rd. Addresses. All Kings row road addresses and any side roads. All Fleming Creek Road addresses and any side roads. Contact Boundary County Sheriff's Office for further information."
                }
            }]
        })
    );
}

#[test]
fn a_county_code_matches_outside_the_polygon_and_other_places_see_nothing() {
    let srv = Srv::start(fixture("feed.xml"), samples());
    let env = Env::new("county", &definition(&srv.base()));
    // in Boundary County (SAME 016021) but east of the evacuation polygon
    let r = env.fetch(place("east-boundary", 48.95, -116.10), JULY, false);
    assert_eq!(labels(&r), ["Wildfire Immediate Evacuation Alert"]);
    // Boise: another county, outside every polygon
    let b = env.fetch(place("boise", 43.615, -116.2023), JULY, false);
    assert!(labels(&b).is_empty(), "{b}");
    let t = env.tool("43.615,-116.2023", JULY);
    assert_eq!(t["none"], true);
    assert_eq!(t["items"][0]["label"], "No active emergency alerts");
    assert_eq!(t["items"][0]["fields"]["Status"], "none active");
    assert_eq!(t["items"][0]["none_active"], true);
}

#[test]
fn a_region_matches_by_its_whole_area_not_its_middle() {
    let srv = Srv::start(fixture("feed.xml"), samples());
    let env = Env::new("region", &definition(&srv.base()));
    // the middle (Clearwater County) is far from the alert; the region's area reaches the polygon
    let mut region = place("region-north-idaho", 47.0, -116.0);
    region["area"] = json!({"type": "Polygon", "coordinates": [[[-117.0, 45.5], [-115.0, 45.5], [-115.0, 48.9], [-117.0, 48.9], [-117.0, 45.5]]]});
    let r = env.fetch(region, JULY, false);
    assert_eq!(labels(&r), ["Wildfire Immediate Evacuation Alert"]);
    // the same middle with a smaller area: nothing
    let mut small = place("region-clearwater", 47.0, -116.0);
    small["area"] = json!({"type": "Polygon", "coordinates": [[[-116.5, 46.5], [-115.5, 46.5], [-115.5, 47.5], [-116.5, 47.5], [-116.5, 46.5]]]});
    assert!(labels(&env.fetch(small, JULY, false)).is_empty());
    // a county code given with the region (one of its counties) matches a county-only alert too
    let mut coded = place("region-codes", 47.0, -116.0);
    coded["codes"] = json!({"SAME": ["016021", "016017"]});
    coded["area"] = json!({"type": "Polygon", "coordinates": [[[-116.5, 46.5], [-115.5, 46.5], [-115.5, 47.5], [-116.5, 47.5], [-116.5, 46.5]]]});
    assert_eq!(labels(&env.fetch(coded, JULY, false)), ["Wildfire Immediate Evacuation Alert"]);
}

#[test]
fn the_english_block_of_a_two_language_alert_and_an_nws_warning_relayed_by_ipaws() {
    let srv = Srv::start(fixture("feed.xml"), samples());
    let env = Env::new("oregon", &definition(&srv.base()));
    let r = env.fetch(place("evans-creek", 42.67, -122.88), JULY, false);
    assert_eq!(labels(&r), ["Jackson County Sheriff's Office"]);
    assert_eq!(r["items"][0]["fields"]["Event"], "Evacuation Immediate");
    assert_eq!(r["items"][0]["fields"]["Issued by"], "200545,Jackson Alerts,Jackson County OR");
    // the NWS flash flood warning as IPAWS carries it: NWS's own CAP identifier with ".IPAWS" after it (the app joins the two)
    let n = env.fetch(place("ruidoso", 33.36, -105.68), OCTOBER, false);
    assert_eq!(n["items"].as_array().unwrap().len(), 1, "{n}");
    let i = &n["items"][0];
    assert!(i["address"].as_str().unwrap().ends_with("/urn:oid:2.49.0.1.840.0.e6e8f35546b1bcf3ea5ca9fb6c6d9c0ebfe11d2a.001.1.IPAWS"));
    assert_eq!(i["fields"]["Event"], "Flash Flood Warning");
    assert_eq!(i["fields"]["Issued by"], "NWS Albuquerque NM");
    assert_eq!(i["fields"]["Severity"], "severe");
    assert!(i["fields"]["Instructions"].as_str().unwrap().starts_with("This is a life threatening situation."));
}

#[test]
fn tests_cancels_and_restricted_messages_are_left_out_and_an_expired_feed_is_not_a_failure() {
    let idaho = fixture("cap_idaho_cem.xml");
    let docs: Docs = vec![
        ("1", idaho.replace("<status>Actual</status>", "<status>Test</status>")),
        ("2", idaho.replace("<msgType>Update</msgType>", "<msgType>Cancel</msgType>")),
        ("3", idaho.replace("<scope>Public</scope>", "<scope>Restricted</scope>")),
    ];
    let feed = fixture("feed.xml")
        .replace("rest/eas/300130859542", "rest/eas/1")
        .replace("rest/eas/300130856756", "rest/eas/2")
        .replace("rest/eas/300133900001", "rest/eas/3");
    let srv = Srv::start(feed, docs);
    let env = Env::new("filters", &definition(&srv.base()));
    let r = env.fetch(place("bonners", 48.80, -116.35), JULY, false);
    assert!(labels(&r).is_empty(), "{r}");

    // a feed whose every entry has expired (as it was on 2026-10-30): no alert, and no error
    let srv2 = Srv::start(fixture("feed.xml"), vec![]);
    let env2 = Env::new("expired", &definition(&srv2.base()));
    let r = env2.fetch(place("bonners", 48.80, -116.35), OCTOBER, false);
    assert!(labels(&r).is_empty());
    assert!(r["last_error"].is_null(), "{r}");
}

#[test]
fn an_older_core_format_is_refused_by_name() {
    // what a core that reads format 2 says of this file is the format line; here, the format 3 features need format 3
    let mut d: Value = serde_json::from_str(&fixture("ipaws-alerts-near.json")).unwrap();
    d["format"] = json!(2);
    let e = cache_live::def::SourceDef::parse(&d.to_string()).unwrap_err().message;
    assert!(e.contains("cache_hours: needs \"format\": 3") && e.contains("cap_area: needs \"format\": 3"), "{e}");
}

/// The catalogue's definition against the real feed, once (not part of the normal run: `cargo test -p cache_live --test ipaws --
/// --ignored`). Boise and Bonners Ferry, now: whatever is active, or none; never an error.
#[test]
#[ignore]
fn the_real_feed_now() {
    let env = Env::new("real", &fixture("ipaws-alerts-near.json"));
    for (k, lat, lon) in [("boise", 43.615, -116.2023), ("bonners", 48.69, -116.32)] {
        let now = cache_live::system_now_iso();
        let r = env.fetch(place(k, lat, lon), &now, false);
        println!("{k}: {} items, missing {:?}, last_error {}", r["items"].as_array().unwrap().len(), r.get("missing_requests"), r["last_error"]);
        for i in r["items"].as_array().unwrap() {
            println!("  {} | {}", i["label"], i["fields"]);
        }
        assert!(r["last_error"].is_null());
        let t = env.tool(&format!("{lat},{lon}"), &now);
        println!("  tool: {}", t);
    }
}
