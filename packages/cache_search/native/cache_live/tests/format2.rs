//! Format 2 features against local stand-in servers and recorded response shapes. No network: every URL points at a tiny
//! HTTP server on this machine. The definitions here are written the way a connector builder writes them.

use cache_live::{Live, LiveCfg};
use cache_user::UserStore;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

const T0: &str = "2026-10-25T10:50:00-06:00";

fn fixture(name: &str) -> String {
    std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)).unwrap()
}

#[derive(Clone, Debug)]
struct Rq {
    method: String,
    url: String,
    headers: Vec<(String, String)>,
    body: String,
}

impl Rq {
    fn header(&self, n: &str) -> Option<String> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(n)).map(|(_, v)| v.clone())
    }
    fn path(&self) -> &str {
        self.url.split('?').next().unwrap()
    }
    fn query(&self, name: &str) -> Option<String> {
        let q = self.url.split_once('?')?.1;
        q.split('&').find_map(|p| p.strip_prefix(&format!("{name}=")).map(|v| v.to_string()))
    }
}

struct Rs {
    status: u16,
    body: Vec<u8>,
    headers: Vec<(String, String)>,
    delay_ms: u64,
}

impl Rs {
    fn ok(body: impl Into<Vec<u8>>) -> Rs {
        Rs { status: 200, body: body.into(), headers: vec![], delay_ms: 0 }
    }
    fn status(mut self, s: u16) -> Rs {
        self.status = s;
        self
    }
    fn header(mut self, k: &str, v: &str) -> Rs {
        self.headers.push((k.into(), v.into()));
        self
    }
    fn delay(mut self, ms: u64) -> Rs {
        self.delay_ms = ms;
        self
    }
}

struct Srv {
    port: u16,
    log: Arc<Mutex<Vec<Rq>>>,
}

impl Srv {
    fn start(f: impl Fn(&Rq, u16) -> Rs + Send + Sync + 'static) -> Srv {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let port = server.server_addr().to_ip().unwrap().port();
        let log: Arc<Mutex<Vec<Rq>>> = Arc::new(Mutex::new(Vec::new()));
        let l2 = log.clone();
        std::thread::spawn(move || {
            for mut req in server.incoming_requests() {
                let mut body = String::new();
                let _ = req.as_reader().read_to_string(&mut body);
                let rq = Rq {
                    method: req.method().to_string(),
                    url: req.url().to_string(),
                    headers: req.headers().iter().map(|h| (h.field.to_string(), h.value.to_string())).collect(),
                    body,
                };
                l2.lock().unwrap().push(rq.clone());
                let rs = f(&rq, port);
                if rs.delay_ms > 0 {
                    std::thread::sleep(std::time::Duration::from_millis(rs.delay_ms));
                }
                let mut resp = tiny_http::Response::from_data(rs.body).with_status_code(rs.status);
                for (k, v) in rs.headers {
                    resp = resp.with_header(tiny_http::Header::from_bytes(k.as_bytes(), v.as_bytes()).unwrap());
                }
                let _ = req.respond(resp);
            }
        });
        Srv { port, log }
    }
    fn base(&self) -> String {
        format!("http://127.0.0.1:{}", self.port)
    }
    fn reqs(&self) -> Vec<Rq> {
        self.log.lock().unwrap().clone()
    }
    fn count(&self) -> usize {
        self.log.lock().unwrap().len()
    }
}

struct Env {
    dir: PathBuf,
    live: Live,
    places: UserStore,
}

impl Env {
    fn new(name: &str, defs: Vec<Value>) -> Env {
        let dir = std::env::temp_dir().join(format!("cache-live-f2-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("sources")).unwrap();
        for d in defs {
            std::fs::write(dir.join("sources").join(format!("{}.json", d["id"].as_str().unwrap())), serde_json::to_string_pretty(&d).unwrap()).unwrap();
        }
        let live = Live::new(LiveCfg::new(dir.join("live.sqlite").to_string_lossy(), dir.join("sources").to_string_lossy()));
        let places = UserStore::new(dir.join("user.sqlite"));
        Env { dir, live, places }
    }
    fn fetch(&self, mut req: Value) -> Result<Value, cache_live::Error> {
        req["now"] = req.get("now").cloned().unwrap_or(json!(T0));
        if req.get("place").is_none() {
            req["place"] = burley();
        }
        self.live.fetch(&req.to_string(), &self.places).map(|s| serde_json::from_str(&s).unwrap())
    }
    fn get(&self, mut req: Value) -> Result<Value, cache_live::Error> {
        req["now"] = req.get("now").cloned().unwrap_or(json!(T0));
        if req.get("place").is_none() {
            req["place"] = burley();
        }
        self.live.get(&req.to_string(), &self.places).map(|s| serde_json::from_str(&s).unwrap())
    }
    fn db_text(&self) -> String {
        String::from_utf8_lossy(&std::fs::read(self.dir.join("live.sqlite")).unwrap()).into_owned()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn burley() -> Value {
    json!({"key": "burley", "name": "Burley, ID", "lat": 42.536, "lon": -113.792, "state": "ID", "county": "Cassia", "country": "US"})
}

/// A format 2 definition with the boring parts filled in.
fn def(id: &str, request: Value, items: Value, extra: Value) -> Value {
    let mut d = json!({
        "format": 2, "id": id, "title": id, "provider": "Test provider", "description": "test source",
        "attribution": "test", "request": request, "refresh_minutes": 1, "quota": {"per_minute": 100},
        "validity": {"fixed_hours": 2}, "items": items
    });
    for (k, v) in extra.as_object().cloned().unwrap_or_default() {
        d[k] = v;
    }
    d
}

fn labels(v: &Value) -> Vec<String> {
    v["items"].as_array().unwrap().iter().map(|i| i["label"].as_str().unwrap().to_string()).collect()
}

fn keys(v: &Value) -> Vec<String> {
    v["items"].as_array().unwrap().iter().map(|i| i["address"].as_str().unwrap().rsplit('/').next().unwrap().to_string()).collect()
}

// ------------------------------------------------------------------------------------------------ XML, steps

#[test]
fn xml_index_then_one_cap_document_per_alert_with_a_failed_member() {
    let srv = Srv::start(|rq, port| {
        let base = format!("http://127.0.0.1:{port}");
        match rq.path() {
            "/feed" => Rs::ok(fixture("atom_index.xml").replace("__BASE__", &base)),
            "/cap/aaa" => Rs::ok(fixture("cap_aaa.xml")),
            "/cap/bbb" => Rs::ok(fixture("cap_bbb.xml")),
            _ => Rs::ok(r#"{"message":"No such document"}"#).status(404),
        }
    });
    let d = def(
        "ipaws-like",
        json!({"steps": [
            {"id": "index", "url": format!("{}/feed", srv.base()), "response": "xml"},
            {"id": "docs", "url": "{e:link.@href|raw}", "response": "xml", "xml": {"always_array": ["info"]},
             "for_each": {"from": "index", "path": "feed.entry", "as": "e", "limit": 5}}
        ]}),
        json!([{
            "each": "docs", "key": {"path": "alert.identifier"}, "label": {"path": "alert.info[0].event"},
            "time": {"path": "alert.sent", "time": {"in": "rfc3339", "zone": "place"}},
            "sort": [{"by": {"path": "alert.info[0].severity"}, "rank": ["severe", "moderate"]}],
            "fields": [
                {"label": "Severity", "path": "alert.info[0].severity", "case": "lower"},
                {"label": "Expires", "path": "alert.info[0].expires", "time": {"in": "rfc3339", "zone": "place", "out": "%Y-%m-%d %H:%M"}},
                {"label": "Area", "path": "alert.info[0].area.areaDesc"}
            ]
        }]),
        json!({"require": ["index.feed.entry", "docs"]}),
    );
    let env = Env::new("xml-steps", vec![d]);
    let r = env.fetch(json!({"source": "ipaws-like"})).unwrap();
    assert_eq!(labels(&r), ["Flood Warning", "Red Flag Warning"]);
    assert_eq!(r["items"][0]["fields"]["Severity"], "severe");
    assert_eq!(r["items"][0]["fields"]["Expires"], "2026-10-25 18:00");
    assert_eq!(r["items"][0]["fields"]["Area"], "Cassia, ID");
    assert_eq!(r["items"][0]["time"], "2026-10-25T09:40-06:00");
    // one index request plus three documents, one of which does not exist: it is left out and counted
    assert_eq!(srv.count(), 4);
    assert_eq!(r["missing_requests"], 1);
    assert_eq!(env.get(json!({"source": "ipaws-like"})).unwrap()["missing_requests"], 1);
}

#[test]
fn multi_step_forecast_then_a_fan_out_of_stations() {
    let srv = Srv::start(|rq, port| {
        let base = format!("http://127.0.0.1:{port}");
        match rq.path() {
            "/points/42.5360,-113.7920" => Rs::ok(fixture("points_boise.json").replace("__BASE__", &base)),
            "/gridpoints/BOI/150,80/forecast" => Rs::ok(fixture("forecast_boise.json")),
            "/gridpoints/BOI/150,80/stations" => Rs::ok(fixture("stations_boise.json")),
            "/stations/KBOI/observations/latest" => Rs::ok(fixture("obs_kboi.json").replace("__BASE__", &base)),
            "/stations/KMAN/observations/latest" => Rs::ok(fixture("obs_kman.json").replace("__BASE__", &base)),
            _ => Rs::ok("nothing").status(404),
        }
    });
    let b = srv.base();
    let d = def(
        "nws-like",
        json!({"headers": {"Accept": "application/geo+json"}, "steps": [
            {"id": "point", "url": format!("{b}/points/{{lat:4}},{{lon:4}}")},
            {"id": "fc", "url": "{point:properties.forecast|raw}"},
            {"id": "st", "url": "{point:properties.observationStations|raw}"},
            {"id": "obs", "url": format!("{b}/stations/{{s:properties.stationIdentifier}}/observations/latest"),
             "for_each": {"from": "st", "path": "features", "as": "s", "limit": 3}}
        ]}),
        json!([
            {"each": "fc.properties.periods", "key": {"template": "p{n}", "vars": {"n": {"path": "number"}}}, "label": {"path": "name"},
             "time": {"path": "startTime", "time": {"in": "rfc3339"}},
             "fields": [{"label": "Temperature", "template": "{t} \u{b0}{u}", "vars": {"t": {"path": "temperature"}, "u": {"path": "temperatureUnit"}}},
                        {"label": "Wind", "template": "{w} {d}", "vars": {"w": {"path": "windSpeed"}, "d": {"path": "windDirection"}}},
                        {"label": "Forecast", "path": "shortForecast"}]},
            {"each": "obs", "key": {"path": "properties.station"}, "label": {"template": "Observed at {s}", "vars": {"s": {"path": "properties.station"}}},
             "time": {"path": "properties.timestamp", "time": {"in": "rfc3339", "zone": "place"}},
             "fields": [{"label": "Temperature", "path": "properties.temperature.value", "scale": 1.8, "offset": 32, "round": 0, "suffix": " \u{b0}F"},
                        {"label": "Wind", "path": "properties.windSpeed.value", "scale": 0.621371, "round": 0, "suffix": " mph"},
                        {"label": "Sky", "path": "properties.textDescription"}]}
        ]),
        json!({"timezone_path": "point.properties.timeZone", "require": ["fc.properties.periods"]}),
    );
    let env = Env::new("steps", vec![d]);
    let r = env.fetch(json!({"source": "nws-like"})).unwrap();
    assert_eq!(labels(&r)[..3], ["Today", "Tonight", "Monday"]);
    assert_eq!(r["items"][0]["fields"]["Temperature"], "58 \u{b0}F");
    assert_eq!(r["items"][0]["fields"]["Wind"], "5 to 10 mph NW");
    // observations: two stations answered, the third was a 404 and is left out
    assert_eq!(r["items"].as_array().unwrap().len(), 5);
    assert_eq!(r["items"][3]["fields"]["Temperature"], "47 \u{b0}F");
    assert_eq!(r["items"][3]["fields"]["Wind"], "7 mph");
    assert_eq!(r["items"][3]["time"], "2026-10-25T10:53-06:00");
    assert_eq!(r["missing_requests"], 1);
    // the zone came from the first response, so times carry its offset
    assert_eq!(r["fetched_at"], "2026-10-25T10:50:00-06:00");
    let reqs = srv.reqs();
    assert_eq!(reqs.len(), 6);
    assert_eq!(reqs[0].path(), "/points/42.5360,-113.7920");
    assert_eq!(reqs[0].header("accept").as_deref(), Some("application/geo+json"));
    assert_eq!(reqs[3].header("accept").as_deref(), Some("application/geo+json"), "shared headers go to every step");
}

// ------------------------------------------------------------------------------------------------ CSV, key in path, bbox, near

#[test]
fn csv_with_the_key_in_the_path_a_bbox_from_the_place_and_near_filtering() {
    let srv = Srv::start(|_rq, _| Rs::ok(fixture("firms_viirs.csv")));
    let d = def(
        "firms-like",
        json!({"url": format!("{}/api/area/csv/{{api_key}}/VIIRS_SNPP_NRT/{{bbox:80mi|raw}}/1", srv.base()),
               "response": "csv"}),
        json!([{
            "each": "^",
            "key": {"template": "{la},{lo},{d}{t}", "vars": {"la": {"path": "latitude"}, "lo": {"path": "longitude"}, "d": {"path": "acq_date"}, "t": {"path": "acq_time"}}},
            "label": {"template": "Fire detection, {c} confidence", "vars": {"c": {"path": "confidence", "lookup": {"n": "nominal", "h": "high", "l": "low"}}}},
            "time": {"template": "{d} {t}", "vars": {"d": {"path": "acq_date"}, "t": {"path": "acq_time"}},
                     "time": {"in": "pattern", "pattern": "%Y-%m-%d %H%M", "assume": "utc", "zone": "place"}},
            "point": {"lat": {"path": "latitude"}, "lon": {"path": "longitude"}},
            "where": [{"value": {"path": "confidence"}, "not_equals": "l"}],
            "near": {"max": {"param": "radius_mi"}, "unit": "mi"},
            "sort": [{"distance": true}],
            "fields": [{"label": "Power", "path": "frp", "suffix": " MW"},
                       {"label": "From here", "distance": {"point": {"lat": {"path": "latitude"}, "lon": {"path": "longitude"}}, "unit": "mi"}}]
        }]),
        json!({"api_key": {"alias": "firms"},
               "params": [{"name": "radius_mi", "label": "Radius (miles)", "type": "number", "default": 60, "min": 1, "max": 300}]}),
    );
    let env = Env::new("csv", vec![d]);
    let r = env.fetch(json!({"source": "firms-like", "api_key": "KEY123"})).unwrap();
    let q = srv.reqs();
    // 80 mi = 128.7 km: 1.156 degrees of latitude around 42.536
    let (dlat, dlon) = (128.7475 / 111.32, 128.7475 / (111.32 * 42.536f64.to_radians().cos()));
    let want = format!("/api/area/csv/KEY123/VIIRS_SNPP_NRT/{:.4},{:.4},{:.4},{:.4}/1", -113.792 - dlon, 42.536 - dlat, -113.792 + dlon, 42.536 + dlat);
    assert_eq!(q[0].path(), want);
    // nearest first; the low-confidence detection is dropped by where, and the 100-mile one by near
    assert_eq!(labels(&r), ["Fire detection, nominal confidence", "Fire detection, nominal confidence", "Fire detection, high confidence"]);
    assert_eq!(r["items"][0]["fields"]["Power"], "12.4 MW");
    assert_eq!(r["items"][0]["fields"]["From here"], "4.4 mi N");
    assert_eq!(r["items"][0]["time"], "2026-10-25T13:42-06:00");
    assert_eq!(r["items"][2]["fields"]["From here"], "30 mi NW");
    assert_eq!(r["items"][0]["point"], json!({"lat": 42.6, "lon": -113.8}));
    // the parameter narrows it; that is a different stored row
    let r2 = env.fetch(json!({"source": "firms-like", "api_key": "KEY123", "params": {"radius_mi": 15}})).unwrap();
    assert_eq!(r2["items"].as_array().unwrap().len(), 2);
    assert_eq!(r2["params"], json!({"radius_mi": 15}));
    assert!(r2["place"]["key"].as_str().unwrap().starts_with("burley~"));
    assert_eq!(env.get(json!({"source": "firms-like"})).unwrap()["items"].as_array().unwrap().len(), 3);
    // the key is never stored, and not in the logged url of an error
    assert!(!env.db_text().contains("KEY123"));
    assert_eq!(env.fetch(json!({"source": "firms-like", "force": true})).unwrap_err().code, "key_missing");
    assert_eq!(env.fetch(json!({"source": "firms-like", "api_key": "K", "params": {"radius_mi": 1000}})).unwrap_err().code, "bad_json");
    assert_eq!(env.fetch(json!({"source": "firms-like", "api_key": "K", "params": {"nope": 1}})).unwrap_err().code, "bad_json");
}

#[test]
fn near_a_point_with_unix_ms_times_numeric_and_distance_sorts() {
    let srv = Srv::start(|_rq, _| Rs::ok(fixture("quakes_statewide.json")));
    let items = |sort: Value| {
        json!([{
            "each": "features", "key": {"path": "id"},
            "label": {"template": "M{m} {p}", "vars": {"m": {"path": "properties.mag", "round": 1}, "p": {"path": "properties.place"}}},
            "time": {"path": "properties.time", "time": {"in": "unix_ms", "out": "datetime_s"}},
            "point": {"lat": {"path": "geometry.coordinates[1]"}, "lon": {"path": "geometry.coordinates[0]"}},
            "near": {"max": 100, "unit": "mi"},
            "sort": sort, "limit": 10,
            "fields": [{"label": "Distance", "distance": {"point": {"lat": {"path": "geometry.coordinates[1]"}, "lon": {"path": "geometry.coordinates[0]"}}, "unit": "mi"}},
                       {"label": "Depth", "path": "geometry.coordinates[2]", "suffix": " km"}]
        }])
    };
    let a = def("quakes-mag", json!({"url": format!("{}/quakes", srv.base())}), items(json!([{"by": {"path": "properties.mag"}, "number": true, "desc": true}])), json!({"require": ["features"]}));
    let b = def("quakes-near", json!({"url": format!("{}/quakes", srv.base())}), items(json!([{"distance": true}])), json!({}));
    let env = Env::new("near", vec![a, b]);
    // Stanley is 100+ miles away and is dropped; the rest by magnitude, highest first
    let r = env.fetch(json!({"source": "quakes-mag"})).unwrap();
    assert_eq!(keys(&r), ["q4", "q1", "q3"]);
    assert_eq!(r["items"][1]["time"], "2026-10-14T11:46:40-06:00");
    assert_eq!(r["items"][1]["fields"]["Distance"], "8.0 mi NW");
    assert_eq!(r["items"][1]["fields"]["Depth"], "8 km");
    // nearest first
    let r = env.fetch(json!({"source": "quakes-near"})).unwrap();
    assert_eq!(keys(&r), ["q3", "q1", "q4"]);
}

// ------------------------------------------------------------------------------------------------ paging

fn feature(i: usize) -> Value {
    json!({"type": "Feature", "properties": {"id": format!("f{i}"), "name": format!("Fire {i}")}, "geometry": null})
}

#[test]
fn paging_by_offset_page_cursor_and_next_link_with_a_hard_cap() {
    let srv = Srv::start(|rq, _| {
        let n = 5usize;
        let num = |name: &str, d: usize| rq.query(name).and_then(|v| v.parse::<usize>().ok()).unwrap_or(d);
        match rq.path() {
            "/arc" => {
                let (off, size) = (num("resultOffset", 0), num("resultRecordCount", 2));
                let page: Vec<Value> = (off..(off + size).min(n)).map(feature).collect();
                Rs::ok(json!({"type": "FeatureCollection", "features": page, "properties": {"exceededTransferLimit": off + size < n}}).to_string())
            }
            "/pages" => {
                let (p, size) = (num("page", 1), num("per_page", 2));
                let page: Vec<Value> = ((p - 1) * size..(p * size).min(n)).map(feature).collect();
                Rs::ok(json!({"data": page}).to_string())
            }
            "/cursor" => {
                let start = rq.query("cursor").map(|c| c.trim_start_matches('c').parse::<usize>().unwrap()).unwrap_or(0);
                let page: Vec<Value> = (start..(start + 2).min(n)).map(feature).collect();
                let next = if start + 2 < n { json!(format!("c{}", start + 2)) } else { Value::Null };
                Rs::ok(json!({"data": page, "meta": {"next_cursor": next}}).to_string())
            }
            "/next" => {
                let start = num("from", 0);
                let page: Vec<Value> = (start..(start + 2).min(n)).map(feature).collect();
                let next = if start + 2 < n { json!(format!("/next?from={}", start + 2)) } else { Value::Null };
                Rs::ok(json!({"data": page, "links": {"next": next}}).to_string())
            }
            _ => Rs::ok("{}").status(404),
        }
    });
    let b = srv.base();
    let items = json!([{"each": "list", "key": {"path": "properties.id"}, "label": {"path": "properties.name"}, "fields": []}]);
    let mk = |id: &str, url: &str, paging: Value, list: &str, max: u32| {
        let mut p = paging;
        p["list_path"] = json!(list);
        p["max_pages"] = json!(max);
        let mut it = items.clone();
        it[0]["each"] = json!(list);
        def(id, json!({"url": format!("{b}{url}"), "paging": p}), it, json!({}))
    };
    let defs = vec![
        mk("arc", "/arc?where=1", json!({"type": "offset", "param": "resultOffset", "size_param": "resultRecordCount", "page_size": 2, "more_path": "properties.exceededTransferLimit"}), "features", 5),
        mk("arc-capped", "/arc?where=1", json!({"type": "offset", "param": "resultOffset", "size_param": "resultRecordCount", "page_size": 2, "more_path": "properties.exceededTransferLimit"}), "features", 2),
        mk("pages", "/pages", json!({"type": "page", "param": "page", "size_param": "per_page", "page_size": 2}), "data", 5),
        mk("cursor", "/cursor", json!({"type": "cursor", "param": "cursor", "next_path": "meta.next_cursor"}), "data", 5),
        mk("next", "/next", json!({"type": "next_link", "next_path": "links.next"}), "data", 5),
    ];
    let env = Env::new("paging", defs);
    for id in ["arc", "pages", "cursor", "next"] {
        let before = srv.count();
        let r = env.fetch(json!({"source": id})).unwrap();
        assert_eq!(labels(&r), ["Fire 0", "Fire 1", "Fire 2", "Fire 3", "Fire 4"], "{id}");
        assert!(r.get("truncated").is_none(), "{id}");
        assert_eq!(srv.count() - before, 3, "{id}: three pages");
    }
    // the cap: two pages of two, and the result says it is cut
    let r = env.fetch(json!({"source": "arc-capped"})).unwrap();
    assert_eq!(labels(&r).len(), 4);
    assert_eq!(r["truncated"], true);
    assert_eq!(env.get(json!({"source": "arc-capped"})).unwrap()["truncated"], true);
    // a paged request stays in the quota like any other: every page counts
    let q = srv.reqs();
    assert_eq!(q.iter().filter(|r| r.path() == "/arc").count(), 3 + 2);
    assert_eq!(q.iter().find(|r| r.path() == "/arc").unwrap().query("resultRecordCount").as_deref(), Some("2"));
}

// ------------------------------------------------------------------------------------------------ POST, auth, headers

#[test]
fn post_with_a_json_body_and_a_form_body() {
    let srv = Srv::start(|_rq, _| Rs::ok(r#"{"results":[{"id":1,"name":"Alpha"},{"id":2,"name":"Beta"}]}"#));
    let items = json!([{"each": "results", "key": {"path": "id"}, "label": {"path": "name"}, "fields": []}]);
    let a = def(
        "post-json",
        json!({"method": "POST", "url": format!("{}/search", srv.base()),
               "body": {"query": "near {name}", "radius": "{param:radius}", "box": {"lat": "{lat:2}", "lon": "{lon:2}"}, "tags": ["a", "{param:tag}"], "fixed": 7, "on": "{param:flag}"}}),
        items.clone(),
        json!({"params": [{"name": "radius", "type": "number", "default": 25}, {"name": "tag", "default": "x"}, {"name": "flag", "type": "bool", "default": true}]}),
    );
    let b = def(
        "post-form",
        json!({"method": "POST", "body_type": "form", "url": format!("{}/form", srv.base()), "body": {"q": "{name}", "n": "5", "key": "{api_key}"}}),
        items,
        json!({"api_key": {"alias": "k"}}),
    );
    let env = Env::new("post", vec![a, b]);
    let r = env.fetch(json!({"source": "post-json", "params": {"tag": "fire"}})).unwrap();
    assert_eq!(labels(&r), ["Alpha", "Beta"]);
    let q = &srv.reqs()[0];
    assert_eq!(q.method, "POST");
    assert_eq!(q.header("content-type").as_deref(), Some("application/json"));
    let body: Value = serde_json::from_str(&q.body).unwrap();
    assert_eq!(body, json!({"query": "near Burley, ID", "radius": 25, "box": {"lat": "42.54", "lon": "-113.79"}, "tags": ["a", "fire"], "fixed": 7, "on": true}));
    env.fetch(json!({"source": "post-form", "api_key": "s p&c"})).unwrap();
    let q = &srv.reqs()[1];
    assert_eq!(q.header("content-type").as_deref(), Some("application/x-www-form-urlencoded"));
    assert_eq!(q.body, "q=Burley%2C%20ID&n=5&key=s%20p%26c");
}

#[test]
fn basic_auth_bearer_header_and_a_rejected_login() {
    // alice:s3cret
    let srv = Srv::start(|rq, _| match rq.path() {
        "/basic" if rq.header("authorization").as_deref() == Some("Basic YWxpY2U6czNjcmV0") => Rs::ok(r#"[{"id":"1","name":"ok"}]"#),
        "/basic" => Rs::ok(r#"{"message":"bad login"}"#).status(401),
        "/bearer" if rq.header("authorization").as_deref() == Some("Bearer tok-123") && rq.header("x-client").as_deref() == Some("Cache test") => Rs::ok(r#"[{"id":"1","name":"bearer ok"}]"#),
        "/bearer" => Rs::ok("denied").status(403),
        _ => Rs::ok("{}").status(404),
    });
    let items = json!([{"each": "^", "key": {"path": "id"}, "label": {"path": "name"}, "fields": []}]);
    let a = def(
        "basic",
        json!({"url": format!("{}/basic", srv.base())}),
        items.clone(),
        json!({"basic_auth": {"user_alias": "svc_user", "password_alias": "svc_pass"}}),
    );
    let b = def(
        "bearer",
        json!({"url": format!("{}/bearer", srv.base()), "headers": {"Authorization": "Bearer {api_key}", "X-Client": "Cache test"}}),
        items,
        json!({"api_key": {"alias": "tok"}}),
    );
    let env = Env::new("auth", vec![a, b]);
    // missing login: no request at all
    assert_eq!(env.fetch(json!({"source": "basic"})).unwrap_err().code, "key_missing");
    assert_eq!(env.fetch(json!({"source": "basic", "secrets": {"svc_user": "alice"}})).unwrap_err().code, "key_missing");
    assert_eq!(srv.count(), 0);
    // wrong password: a clear message, and the secret is nowhere in it
    let e = env.fetch(json!({"source": "basic", "secrets": {"svc_user": "alice", "svc_pass": "wrong"}})).unwrap_err();
    assert_eq!(e.code, "fetch_failed");
    assert_eq!(e.message, "HTTP 401: bad login (the key or login was refused)");
    let r = env.fetch(json!({"source": "basic", "secrets": {"svc_user": "alice", "svc_pass": "s3cret"}})).unwrap();
    assert_eq!(labels(&r), ["ok"]);
    assert!(!env.db_text().contains("s3cret") && !env.db_text().contains("YWxpY2U6czNjcmV0"));
    // the rejected attempt is recorded for the source, and the good copy stays
    let e = env.fetch(json!({"source": "basic", "force": true, "secrets": {"svc_user": "alice", "svc_pass": "nope"}})).unwrap_err();
    assert_eq!(e.code, "fetch_failed");
    let g = env.get(json!({"source": "basic"})).unwrap();
    assert_eq!(g["last_error"]["message"], "HTTP 401: bad login (the key or login was refused)");
    assert_eq!(labels(&g), ["ok"]);
    // a key in a header with a prefix and another header
    let r = env.fetch(json!({"source": "bearer", "api_key": "tok-123"})).unwrap();
    assert_eq!(labels(&r), ["bearer ok"]);
    let e = env.fetch(json!({"source": "bearer", "api_key": "other", "force": true})).unwrap_err();
    assert_eq!(e.message, "HTTP 403: denied (the key or login was refused)");
    // sources_json says what each source needs
    let list: Value = serde_json::from_str(&env.live.sources_json()).unwrap();
    let basic = list["sources"].as_array().unwrap().iter().find(|s| s["id"] == "basic").unwrap();
    assert_eq!(basic["basic_auth"], json!({"user_alias": "svc_user", "password_alias": "svc_pass", "required": true}));
}

// ------------------------------------------------------------------------------------------------ other response formats

#[test]
fn gzip_tsv_with_comments_and_tle_responses() {
    use std::io::Write;
    let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
    gz.write_all(br#"{"results":[{"id":"g","name":"zipped"}]}"#).unwrap();
    let gz = gz.finish().unwrap();
    let tle = "ISS (ZARYA)\n1 25544U 98067A   26298.51782528  .00016717  00000-0  10270-3 0  9993\n2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537\n";
    let srv = Srv::start(move |rq, _| match rq.path() {
        "/gz" => Rs::ok(gz.clone()).header("Content-Encoding", "gzip"),
        "/gz-quiet" => Rs::ok(gz.clone()),
        "/rdb" => Rs::ok(fixture("nwis_rdb.txt")),
        "/tle" => Rs::ok(tle),
        _ => Rs::ok("").status(404),
    });
    let b = srv.base();
    let g1 = def("gz", json!({"url": format!("{b}/gz")}), json!([{"each": "results", "key": {"path": "id"}, "label": {"path": "name"}, "fields": []}]), json!({}));
    let g2 = def("gz-quiet", json!({"url": format!("{b}/gz-quiet")}), json!([{"each": "results", "key": {"path": "id"}, "label": {"path": "name"}, "fields": []}]), json!({}));
    let rdb = def(
        "rdb",
        json!({"url": format!("{b}/rdb"), "response": "tsv", "table": {"comment": "#", "skip_after_header": 1}}),
        json!([{"each": "^", "key": {"path": "site_no"}, "label": {"path": "station_nm", "case": "lower"},
                "point": {"lat": {"path": "dec_lat_va"}, "lon": {"path": "dec_long_va"}}, "fields": [{"label": "Site", "path": "site_no"}]}]),
        json!({}),
    );
    let t = def(
        "tle",
        json!({"url": format!("{b}/tle"), "response": "tle"}),
        json!([{"each": "^", "key": {"path": "norad_id"}, "label": {"path": "name"},
                "time": {"path": "epoch", "time": {"in": "rfc3339", "zone": "place"}},
                "fields": [{"label": "Inclination", "path": "inclination_deg", "suffix": " deg"}, {"label": "Orbits per day", "path": "mean_motion_rev_per_day", "round": 2}]}]),
        json!({}),
    );
    let env = Env::new("formats", vec![g1, g2, rdb, t]);
    assert_eq!(labels(&env.fetch(json!({"source": "gz"})).unwrap()), ["zipped"]);
    assert_eq!(labels(&env.fetch(json!({"source": "gz-quiet"})).unwrap()), ["zipped"]);
    assert_eq!(srv.reqs()[0].header("accept-encoding").as_deref(), Some("gzip"));
    let r = env.fetch(json!({"source": "rdb"})).unwrap();
    assert_eq!(labels(&r), ["boise river at glenwood bridge nr boise id", "boise river nr boise id"]);
    assert_eq!(r["items"][0]["fields"]["Site"], "13206000");
    let r = env.fetch(json!({"source": "tle"})).unwrap();
    assert_eq!(r["items"][0]["label"], "ISS (ZARYA)");
    assert_eq!(r["items"][0]["time"], "2026-10-25T06:25-06:00");
    assert_eq!(r["items"][0]["fields"]["Orbits per day"], "15.72");
}

// ------------------------------------------------------------------------------------------------ limits, errors, retries

#[test]
fn rate_limits_are_honoured_inside_the_quota() {
    use std::sync::atomic::{AtomicUsize, Ordering};
    let n = Arc::new(AtomicUsize::new(0));
    let n2 = n.clone();
    let srv = Srv::start(move |rq, _| match rq.path() {
        "/once" if n2.fetch_add(1, Ordering::SeqCst) == 0 => Rs::ok(r#"{"message":"slow down"}"#).status(429).header("Retry-After", "1"),
        "/once" => Rs::ok(r#"[{"id":"1","name":"after retry"}]"#),
        "/long" => Rs::ok("").status(429).header("Retry-After", "3600"),
        _ => Rs::ok("").status(404),
    });
    let items = json!([{"each": "^", "key": {"path": "id"}, "label": {"path": "name"}, "fields": []}]);
    let mut a = def("once", json!({"url": format!("{}/once", srv.base())}), items.clone(), json!({}));
    a["quota"] = json!({"per_minute": 2});
    let b = def("long", json!({"url": format!("{}/long", srv.base())}), items, json!({}));
    let env = Env::new("ratelimit", vec![a, b]);
    let t = std::time::Instant::now();
    let r = env.fetch(json!({"source": "once"})).unwrap();
    assert_eq!(labels(&r), ["after retry"]);
    assert!(t.elapsed().as_millis() >= 1000, "waited for Retry-After");
    assert_eq!(srv.count(), 2);
    // both requests were counted: the minute's quota of 2 is used up
    assert_eq!(env.fetch(json!({"source": "once", "force": true, "now": "2026-10-25T10:50:30-06:00"})).unwrap_err().code, "quota");
    assert_eq!(srv.count(), 2);
    // a provider that asks for an hour is not waited for
    let t = std::time::Instant::now();
    let e = env.fetch(json!({"source": "long"})).unwrap_err();
    assert!(t.elapsed().as_secs() < 5);
    assert_eq!(e.code, "fetch_failed");
    assert!(e.message.starts_with("HTTP 429") && e.message.contains("3600 s"), "{}", e.message);
    assert_eq!(srv.count(), 3);
}

#[test]
fn upstream_errors_are_recorded_with_a_message_and_the_last_good_copy_stays() {
    use std::sync::atomic::{AtomicU16, Ordering};
    let status = Arc::new(AtomicU16::new(200));
    let s2 = status.clone();
    let srv = Srv::start(move |_rq, _| match s2.load(Ordering::SeqCst) {
        200 => Rs::ok(r#"[{"id":"1","name":"fine"}]"#),
        404 => Rs::ok(r#"{"error":{"code":404,"message":"No such site: 99"}}"#).status(404),
        500 => Rs::ok("<html><body>oops</body></html>").status(500),
        c => Rs::ok("").status(c),
    });
    let d = def("up", json!({"url": format!("{}/x", srv.base())}), json!([{"each": "^", "key": {"path": "id"}, "label": {"path": "name"}, "fields": []}]), json!({}));
    let env = Env::new("errors", vec![d]);
    env.fetch(json!({"source": "up"})).unwrap();
    status.store(404, Ordering::SeqCst);
    let e = env.fetch(json!({"source": "up", "force": true, "now": "2026-10-25T11:00:00-06:00"})).unwrap_err();
    assert_eq!((e.code, e.message.as_str()), ("fetch_failed", "HTTP 404: No such site: 99"));
    status.store(500, Ordering::SeqCst);
    let e = env.fetch(json!({"source": "up", "force": true, "now": "2026-10-25T11:05:00-06:00"})).unwrap_err();
    assert_eq!(e.message, "HTTP 500");
    let g = env.get(json!({"source": "up", "now": "2026-10-25T11:06:00-06:00"})).unwrap();
    assert_eq!(labels(&g), ["fine"]);
    assert_eq!(g["last_error"]["message"], "HTTP 500");
    assert_eq!(g["last_error"]["at"], "2026-10-25T11:05:00-06:00");
    assert_eq!(g["fetched_at"], "2026-10-25T10:50:00-06:00");
}

#[test]
fn size_cap_is_per_definition_and_the_timeout_too() {
    let big = format!("[{}]", (0..110_000).map(|i| format!(r#"{{"id":"{i}","name":"item number {i} with some padding text to make it long enough"}}"#)).collect::<Vec<_>>().join(","));
    assert!(big.len() > 8 * 1024 * 1024 && big.len() < 12_000_000, "{}", big.len());
    let srv = Srv::start(move |rq, _| match rq.path() {
        "/big" => Rs::ok(big.clone()),
        "/slow" => Rs::ok("[]").delay(2500),
        _ => Rs::ok("[]"),
    });
    let items = json!([{"each": "^", "key": {"path": "id"}, "label": {"path": "name"}, "limit": 3, "fields": []}]);
    let small = def("big-default", json!({"url": format!("{}/big", srv.base())}), items.clone(), json!({}));
    let raised = def("big-raised", json!({"url": format!("{}/big", srv.base()), "max_bytes": 12_000_000}), items.clone(), json!({}));
    let slow = def("slow", json!({"url": format!("{}/slow", srv.base()), "timeout_seconds": 1}), items.clone(), json!({}));
    let env = Env::new("limits", vec![small, raised, slow]);
    let e = env.fetch(json!({"source": "big-default"})).unwrap_err();
    assert_eq!(e.code, "bad_response");
    assert!(e.message.contains("larger than 8 MB") && e.message.contains("max_bytes"), "{}", e.message);
    let r = env.fetch(json!({"source": "big-raised"})).unwrap();
    assert_eq!(labels(&r).len(), 3);
    let t = std::time::Instant::now();
    let e = env.fetch(json!({"source": "slow"})).unwrap_err();
    assert_eq!(e.code, "fetch_failed");
    assert!(t.elapsed().as_millis() < 2400, "gave up at the definition's timeout");
    // limits are checked when the definition is read
    let bad = def("toobig", json!({"url": "https://x/", "max_bytes": 40_000_000, "timeout_seconds": 500}), items, json!({}));
    let err = cache_live::def::SourceDef::parse(&bad.to_string()).unwrap_err().message;
    assert!(err.contains("request.max_bytes") && err.contains("request.timeout_seconds"), "{err}");
}

// ------------------------------------------------------------------------------------------------ parameters, place detail

#[test]
fn parameters_make_separate_rows_and_the_place_detail_fills_placeholders() {
    let srv = Srv::start(|rq, _| {
        let site = rq.path().rsplit('/').next().unwrap().to_string();
        Rs::ok(json!({"site": site, "area": rq.query("area"), "level": 4.5}).to_string())
    });
    let d = def(
        "gauge",
        json!({"url": format!("{}/site/{{param:site}}?area={{state}}-{{county}}", srv.base())}),
        json!([{"key": {"path": "site"}, "label": {"template": "Gauge {s}", "vars": {"s": {"path": "site"}}}, "fields": [{"label": "Level", "path": "level", "suffix": " ft"}, {"label": "Area", "path": "area"}]}]),
        json!({"params": [{"name": "site", "label": "Gauge number", "default": "13206000"}]}),
    );
    let env = Env::new("params", vec![d]);
    env.places.save(r#"{"key":"burley","name":"Burley, ID","lat":42.536,"lon":-113.792}"#).unwrap();
    let a = env.fetch(json!({"source": "gauge"})).unwrap();
    assert_eq!(a["items"][0]["address"], "live:gauge/burley/13206000");
    assert_eq!(a["items"][0]["fields"]["Area"], "ID-Cassia");
    let b = env.fetch(json!({"source": "gauge", "params": {"site": "13172500"}})).unwrap();
    let bkey = b["place"]["key"].as_str().unwrap().to_string();
    assert!(bkey.starts_with("burley~") && bkey.len() == "burley~".len() + 8, "{bkey}");
    assert_eq!(b["items"][0]["label"], "Gauge 13172500");
    assert_eq!(b["params"], json!({"site": "13172500"}));
    // each is read back by its parameters
    assert_eq!(env.get(json!({"source": "gauge"})).unwrap()["items"][0]["label"], "Gauge 13206000");
    assert_eq!(env.get(json!({"source": "gauge", "params": {"site": "13172500"}})).unwrap()["items"][0]["label"], "Gauge 13172500");
    // a saved place that is deleted takes every row with it
    env.live.forget_place("burley");
    assert_eq!(env.get(json!({"source": "gauge"})).unwrap_err().code, "not_found");
    assert_eq!(env.get(json!({"source": "gauge", "params": {"site": "13172500"}})).unwrap_err().code, "not_found");
    // a place without the detail the URL needs
    let e = env.fetch(json!({"source": "gauge", "place": {"key": "x", "name": "Somewhere", "lat": 40.0, "lon": -111.0}})).unwrap_err();
    assert_eq!(e.code, "fetch_failed");
    assert_eq!(e.message, "this source needs the place's state, which is not known for Somewhere");
}

// ------------------------------------------------------------------------------------------------ builder's tools

#[test]
fn errors_name_the_field_and_old_definitions_still_read() {
    let good = def("ok", json!({"url": "https://x/"}), json!([{"key": {"const": "k"}, "label": {"const": "l"}, "fields": [{"label": "A", "path": "a"}]}]), json!({}));
    cache_live::def::SourceDef::parse(&good.to_string()).unwrap();
    // a typo deep inside
    let mut d = good.clone();
    d["items"][0]["fields"][0]["time"] = json!({"inn": "unix"});
    let e = cache_live::def::SourceDef::parse(&d.to_string()).unwrap_err().message;
    assert!(e.contains("items[0].fields[0].time") && e.contains("inn"), "{e}");
    // several mistakes are all listed, each with its field
    let mut d = good.clone();
    d["format"] = json!(4);
    d["request"] = json!({"url": "https://x/{nope", "method": "PUT", "response": "yaml"});
    d["items"][0]["fields"][0] = json!({"label": "A", "path": "a", "const": 1});
    d["items"][0]["where"] = json!([{"field": "Missing", "equals": 1}, {"value": {"path": "x"}}]);
    d["items"][0]["near"] = json!({"max": 5, "unit": "furlong"});
    d["items"][0]["sort"] = json!([{"by": {"path": "x"}, "distance": true}]);
    let e = cache_live::def::SourceDef::parse(&d.to_string()).unwrap_err().message;
    for want in ["format: 4 is not supported", "request.method", "request.response", "items[0].fields[0]: a value", "items[0].where[0].field", "items[0].where[1]: needs a test", "items[0].near.unit", "items[0].sort[0]"] {
        assert!(e.contains(want), "missing {want:?} in {e}");
    }
    // steps: unknown earlier step, repeated step, undeclared parameter and key
    let d = def(
        "bad-steps",
        json!({"steps": [{"id": "a", "url": "https://x/{param:nope}"}, {"id": "b", "url": "https://x/{c:y|raw}", "for_each": {"from": "zzz", "path": "p", "as": "c"}}, {"id": "a", "url": "https://x/?k={api_key}"}]}),
        json!([{"key": {"const": "k"}, "label": {"const": "l"}, "fields": []}]),
        json!({}),
    );
    let e = cache_live::def::SourceDef::parse(&d.to_string()).unwrap_err().message;
    for want in ["request.steps[0]", "no parameter called \"nope\"", "request.steps[1].for_each.from", "request.steps[2].id", "api_key is not declared"] {
        assert!(e.contains(want), "missing {want:?} in {e}");
    }
    // format 1 files (all of the shipped ones) read as they always did
    let mut one = good.clone();
    one["format"] = json!(1);
    cache_live::def::SourceDef::parse(&one.to_string()).unwrap();
    assert!(cache_live::def::SourceDef::parse("{ not json").unwrap_err().message.contains("line 1"));
}

#[test]
fn preview_shows_the_raw_tree_the_paths_and_the_mapped_items_and_stores_nothing() {
    let srv = Srv::start(|_rq, _| Rs::ok(fixture("quakes_statewide.json")));
    let d = def(
        "preview-me",
        json!({"url": format!("{}/q?lat={{lat}}", srv.base())}),
        json!([{"each": "features", "key": {"path": "id"}, "label": {"path": "properties.place"},
                "time": {"path": "properties.time", "time": {"in": "unix_ms"}},
                "point": {"lat": {"path": "geometry.coordinates[1]"}, "lon": {"path": "geometry.coordinates[0]"}},
                "fields": [{"label": "Magnitude", "path": "properties.mag"}]}]),
        json!({"require": ["features"]}),
    );
    let out: Value = serde_json::from_str(
        &cache_live::preview::preview(&json!({"definition": d, "place": {"lat": 42.536, "lon": -113.792, "name": "Burley"}, "now": T0, "raw_chars": 600, "max_items": 2}).to_string()).unwrap(),
    )
    .unwrap();
    assert_eq!(out["valid"], true);
    assert_eq!(out["source"]["id"], "preview-me");
    assert_eq!(out["requests"][0]["status"], 200);
    assert!(out["requests"][0]["url"].as_str().unwrap().ends_with("/q?lat=42.5360"));
    assert_eq!(out["item_count"], 4);
    assert_eq!(out["items"].as_array().unwrap().len(), 2);
    assert_eq!(out["items"][0]["fields"]["Magnitude"], "3.1");
    // the raw tree is cut down to fit and says how much was left out
    assert!(out["raw"].to_string().len() <= 800, "{}", out["raw"]);
    assert!(out["raw"]["features"].to_string().contains("more"), "{}", out["raw"]["features"]);
    let paths: Vec<&str> = out["paths"].as_array().unwrap().iter().map(|p| p.as_str().unwrap()).collect();
    assert!(paths.contains(&"features  (list of 4)"), "{paths:?}");
    assert!(paths.contains(&"features[0].properties.mag = 3.1"), "{paths:?}");
    assert!(paths.contains(&"features[0].geometry.coordinates  (list of 3)"));
    assert!(out["warnings"].as_array().unwrap().is_empty());
    // a response the mapping cannot read still shows the tree, with the reason
    let mut d2 = d.clone();
    d2["items"][0]["each"] = json!("nothing_here");
    d2["require"] = json!([]);
    let out: Value = serde_json::from_str(&cache_live::preview::preview(&json!({"definition": d2.to_string(), "place": {"lat": 1.0, "lon": 2.0}}).to_string()).unwrap()).unwrap();
    assert_eq!(out["mapping_error"]["code"], "bad_response");
    assert!(out["warnings"].as_array().unwrap().iter().any(|w| w.as_str().unwrap().contains("require")));
    assert!(out["raw"]["features"].is_array());
    // check only: no network, no place
    let n = srv.count();
    let out: Value = serde_json::from_str(&cache_live::preview::preview(&json!({"definition": d, "check_only": true}).to_string()).unwrap()).unwrap();
    assert_eq!(out["valid"], true);
    assert_eq!(srv.count(), n);
    assert_eq!(out["requests"][0]["method"], "GET");
    // errors
    let bad = cache_live::preview::preview(&json!({"definition": {"id": "x"}, "check_only": true}).to_string()).unwrap_err();
    assert_eq!(bad.code, "bad_json");
    assert_eq!(cache_live::preview::preview(&json!({"definition": d}).to_string()).unwrap_err().code, "bad_json");
    assert_eq!(cache_live::preview::preview("{").unwrap_err().code, "bad_json");
    let keyed = def("needs-key", json!({"url": "https://x/{api_key}"}), json!([{"key": {"const": "k"}, "label": {"const": "l"}, "fields": []}]), json!({"api_key": {"alias": "a"}}));
    assert_eq!(cache_live::preview::preview(&json!({"definition": keyed, "place": {"lat": 1.0, "lon": 2.0}}).to_string()).unwrap_err().code, "key_missing");
    // (the call takes no database path and no places store: there is nothing it could write to)
}

#[cfg(feature = "schema")]
#[test]
fn the_schema_accepts_the_example_definitions_shape() {
    let s = cache_live::schema::json_schema();
    assert_eq!(s["properties"]["format"]["maximum"], 2);
    assert!(s["definitions"]["Spec"]["properties"]["calc"].is_object());
}
