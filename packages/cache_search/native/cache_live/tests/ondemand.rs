//! `live_data` fetching for a place that has no fresh data, when the host allows it (ToolCtx::live_fetcher): denied by default,
//! fetched when allowed, through the same quotas as cs_live_fetch, never for a source without its key, and no key in any output.
//! When data due for a refresh is not refreshed, `not_refreshed` says why (one test per reason, and the exact bytes).

use cache_live::{LiveCfg, LiveDataTool};
use cache_tool::places::{Geocoder, ResolvedPlace};
use cache_tool::{LiveFetcher, Location, NotAllowed, Tool, ToolCtx, ToolError, ToolOutput};
use cache_user::UserStore;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

const T0: &str = "2026-10-25T10:50:00-06:00";
/// A key no output may contain.
const SENTINEL: &str = "SENTINEL-KEY-91c2e7-do-not-leak";

fn fixture(name: &str) -> String {
    std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)).unwrap()
}

fn real_source(name: &str) -> Value {
    serde_json::from_str(&std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../sources").join(name)).unwrap()).unwrap()
}

struct Server {
    port: u16,
    hits: Arc<AtomicUsize>,
    urls: Arc<Mutex<Vec<String>>>,
    status: Arc<Mutex<u16>>,
}

impl Server {
    fn start(path: &'static str, body: String) -> Server {
        let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
        let port = server.server_addr().to_ip().unwrap().port();
        let s = Server { port, hits: Arc::new(AtomicUsize::new(0)), urls: Default::default(), status: Arc::new(Mutex::new(200)) };
        let (hits, urls, status) = (s.hits.clone(), s.urls.clone(), s.status.clone());
        std::thread::spawn(move || {
            for req in server.incoming_requests() {
                hits.fetch_add(1, Ordering::SeqCst);
                urls.lock().unwrap().push(req.url().to_string());
                let code = *status.lock().unwrap();
                let b = if req.url().starts_with(path) { body.clone() } else { String::new() };
                let _ = req.respond(tiny_http::Response::from_string(b).with_status_code(code));
            }
        });
        s
    }
    fn hits(&self) -> usize {
        self.hits.load(Ordering::SeqCst)
    }
}

/// The host's grant, as a test double: which sources may be fetched, which keys it holds, why a fetch is denied and a stand-in
/// failure.
#[derive(Default)]
struct Grant {
    allowed: Vec<String>,
    keys: HashMap<String, String>,
    why: Option<NotAllowed>,
    fail: Option<&'static str>,
}

impl LiveFetcher for Grant {
    fn can_fetch(&self, source_id: &str) -> bool {
        self.allowed.iter().any(|s| s == source_id)
    }
    fn key_for(&self, source_id: &str) -> Option<String> {
        self.keys.get(source_id).cloned()
    }
    fn not_allowed(&self, _source_id: &str) -> Option<NotAllowed> {
        self.why
    }
    fn stand_in_failure(&self, _source_id: &str) -> Option<&'static str> {
        self.fail
    }
}

struct Env {
    dir: PathBuf,
    cfg: LiveCfg,
    places: UserStore,
}

impl Env {
    fn new(name: &str, def: Value, srv: &Server, path: &str) -> Env {
        let dir = std::env::temp_dir().join(format!("cache-ondemand-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("sources")).unwrap();
        let mut d = def;
        let old = d["request"]["url"].as_str().unwrap().to_string();
        let q = old.find('?').map(|i| &old[i..]).unwrap_or("");
        d["request"]["url"] = json!(format!("http://127.0.0.1:{}{path}{q}", srv.port));
        let id = d["id"].as_str().unwrap().to_string();
        std::fs::write(dir.join("sources").join(format!("{id}.json")), serde_json::to_string_pretty(&d).unwrap()).unwrap();
        let cfg = LiveCfg::new(dir.join("live.sqlite").to_string_lossy(), dir.join("sources").to_string_lossy());
        let places = UserStore::new(dir.join("user.sqlite"));
        Env { dir, cfg, places }
    }

    fn run(&self, args: Value, loc: Option<&Location>, now: &str, geo: Option<&dyn Geocoder>, grant: Option<&Grant>) -> Result<Value, ToolError> {
        let t = LiveDataTool::new(self.cfg.clone());
        let ctx = ToolCtx { location: loc, places: &self.places, now, geocoder: geo, live_fetcher: grant.map(|g| g as &dyn LiveFetcher) };
        match t.run(&ctx, &args)? {
            ToolOutput::Json(v) => Ok(v),
            ToolOutput::Text(_) => panic!("text"),
        }
    }

    /// The place keys stored, sorted.
    fn rows(&self) -> Vec<String> {
        let c = rusqlite::Connection::open(self.dir.join("live.sqlite")).unwrap();
        let mut st = c.prepare("SELECT DISTINCT place_key FROM live_fetch ORDER BY place_key").unwrap();
        st.query_map([], |r| r.get::<_, String>(0)).unwrap().map(|r| r.unwrap()).collect()
    }
}

impl Drop for Env {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn grant(ids: &[&str]) -> Grant {
    Grant { allowed: ids.iter().map(|s| s.to_string()).collect(), ..Default::default() }
}

fn burley_loc() -> Location {
    Location { lat: 42.5361, lon: -113.7919, accuracy_m: Some(8.0), fixed_at: T0.into() }
}

struct Town(&'static str, f64, f64);

impl Geocoder for Town {
    fn resolve(&self, _text: &str, _near: Option<(f64, f64)>) -> Option<(String, f64, f64)> {
        Some((self.0.into(), self.1, self.2))
    }
    fn resolve_full(&self, text: &str, near: Option<(f64, f64)>) -> Option<ResolvedPlace> {
        let (name, lat, lon) = self.resolve(text, near)?;
        Some(ResolvedPlace { name, lat, lon, state: Some("ID".into()), county: Some("Custer".into()), country: Some("US".into()), ..Default::default() })
    }
}

fn alerts(name: &str) -> (Env, Server) {
    let srv = Server::start("/alerts/active", fixture("nws_boise.json"));
    let env = Env::new(name, real_source("alerts.json"), &srv, "/alerts/active");
    (env, srv)
}

fn weather(name: &str) -> (Env, Server) {
    let srv = Server::start("/v1/forecast", fixture("openmeteo_burley.json"));
    let env = Env::new(name, real_source("weather.json"), &srv, "/v1/forecast");
    (env, srv)
}

#[test]
fn denied_by_default_nothing_is_fetched() {
    let (env, srv) = weather("denied");
    let here = burley_loc();
    // no fetcher at all (no policy pushed): the old behaviour, no data
    let e = env.run(json!({"source": "weather"}), Some(&here), T0, None, None).unwrap_err();
    assert_eq!(e.code, "no_data");
    // a fetcher that does not allow this source, or an empty grant
    let e = env.run(json!({"source": "weather"}), Some(&here), T0, None, Some(&grant(&["alerts"]))).unwrap_err();
    assert_eq!(e.code, "no_data");
    let e = env.run(json!({"source": "weather"}), Some(&here), T0, None, Some(&grant(&[]))).unwrap_err();
    assert_eq!(e.code, "no_data");
    assert_eq!(srv.hits(), 0);
}

#[test]
fn fetched_once_when_allowed_then_served_from_the_stored_row() {
    let (env, srv) = alerts("allowed");
    let g = grant(&["alerts"]);
    let here = burley_loc();
    let v = env.run(json!({"source": "alerts"}), Some(&here), T0, None, Some(&g)).unwrap();
    assert_eq!(srv.hits(), 1);
    assert_eq!(v["place"], "current location");
    assert_eq!(v["expired"], false);
    assert_eq!(v["items"][0]["address"], "live:alerts/at:42.54,-113.79/none");
    // stored under the position rounded to 0.01 degrees
    assert_eq!(env.rows(), vec!["at:42.54,-113.79".to_string()]);
    // the same ask, and one a few hundred metres away, share the row: no second download
    env.run(json!({"source": "alerts"}), Some(&here), "2026-10-25T10:55:00-06:00", None, Some(&g)).unwrap();
    let near = Location { lat: 42.5379, lon: -113.7941, ..burley_loc() };
    env.run(json!({"source": "alerts"}), Some(&near), "2026-10-25T10:56:00-06:00", None, Some(&g)).unwrap();
    assert_eq!(srv.hits(), 1);
    // once the row has expired (6 hours) it is fetched again
    let later = "2026-10-25T17:50:00-06:00";
    env.run(json!({"source": "alerts"}), Some(&here), later, None, Some(&g)).unwrap();
    assert_eq!(srv.hits(), 2);
}

#[test]
fn a_named_place_is_fetched_with_its_facts_and_a_denied_offline_policy_does_not_fetch() {
    let (env, srv) = weather("named");
    let g = grant(&["weather"]);
    let stanley = Town("Stanley, ID", 44.2191, -114.9368);
    let v = env.run(json!({"source": "weather", "place": "Stanley"}), None, T0, Some(&stanley), Some(&g)).unwrap();
    assert_eq!(v["place"], "Stanley, ID");
    assert_eq!(srv.hits(), 1);
    assert!(srv.urls.lock().unwrap()[0].contains("latitude=44.2191&longitude=-114.9368"), "{:?}", srv.urls.lock().unwrap());
    assert_eq!(env.rows(), vec!["at:44.22,-114.94".to_string()]);
    // a saved place is stored under its own key and fetched at its own position
    env.places.save(r#"{"key":"cabin","name":"Cabin","lat":43.5,"lon":-113.0}"#).unwrap();
    let v = env.run(json!({"source": "weather", "place": "Cabin"}), None, T0, Some(&stanley), Some(&g)).unwrap();
    assert_eq!(v["place"], "Cabin");
    assert_eq!(srv.hits(), 2);
    assert!(srv.urls.lock().unwrap()[1].contains("latitude=43.5000&longitude=-113.0000"), "{:?}", srv.urls.lock().unwrap());
    assert_eq!(env.rows(), vec!["at:44.22,-114.94".to_string(), "cabin".to_string()]);
    // a town a few km from a place that has fresh data shares that row instead of downloading again
    let near = Town("Near Cabin, ID", 43.51, -113.01);
    env.run(json!({"source": "weather", "place": "x"}), None, T0, Some(&near), Some(&g)).unwrap();
    assert_eq!(srv.hits(), 2);
}

#[test]
fn a_failed_fetch_says_why_and_the_expired_error_says_the_refresh_failed() {
    let (env, srv) = alerts("failed");
    let g = grant(&["alerts"]);
    let here = burley_loc();
    *srv.status.lock().unwrap() = 500;
    let e = env.run(json!({"source": "alerts"}), Some(&here), T0, None, Some(&g)).unwrap_err();
    assert_eq!((e.code.as_str(), e.top["not_refreshed"].as_str()), ("no_data", Some("refresh failed: couldn't reach the source")));
    assert_eq!(srv.hits(), 1);
    *srv.status.lock().unwrap() = 200;
    env.run(json!({"source": "alerts"}), Some(&here), "2026-10-25T11:00:00-06:00", None, Some(&g)).unwrap();
    // expired, and the refresh fails: the expired error names the failed refresh
    *srv.status.lock().unwrap() = 500;
    let e = env.run(json!({"source": "alerts"}), Some(&here), "2026-10-26T11:00:00-06:00", None, Some(&g)).unwrap_err();
    assert_eq!(e.code, "expired");
    assert!(e.to_json()["error"].get("refresh_failed").is_none(), "not_refreshed replaced it");
    assert_eq!(e.to_json()["not_refreshed"], "refresh failed: couldn't reach the source");
}

#[test]
fn the_sources_quota_is_respected() {
    let srv = Server::start("/v1/forecast", fixture("openmeteo_burley.json"));
    let mut d = real_source("weather.json");
    d["quota"] = json!({"per_minute": 2});
    let env = Env::new("quota", d, &srv, "/v1/forecast");
    let g = grant(&["weather"]);
    let at = |lat: f64| Location { lat, lon: -114.0, ..burley_loc() };
    env.run(json!({"source": "weather"}), Some(&at(42.0)), T0, None, Some(&g)).unwrap();
    env.run(json!({"source": "weather"}), Some(&at(43.0)), "2026-10-25T10:50:10-06:00", None, Some(&g)).unwrap();
    assert_eq!(srv.hits(), 2);
    let e = env.run(json!({"source": "weather"}), Some(&at(44.0)), "2026-10-25T10:50:20-06:00", None, Some(&g)).unwrap_err();
    assert_eq!((e.code.as_str(), e.top["not_refreshed"].as_str()), ("no_data", Some("refresh failed: daily limit reached")));
    assert_eq!(srv.hits(), 2, "the limit stopped the request before it was sent");
    // a minute later it goes through
    env.run(json!({"source": "weather"}), Some(&at(44.0)), "2026-10-25T10:52:00-06:00", None, Some(&g)).unwrap();
    assert_eq!(srv.hits(), 3);
}

#[test]
fn a_source_that_needs_a_key_is_never_fetched_without_it_and_the_key_never_leaks() {
    let srv = Server::start("/v1/forecast", fixture("openmeteo_burley.json"));
    let mut d = real_source("weather.json");
    d["api_key"] = json!({"alias": "openmeteo"});
    d["request"]["url"] = json!(format!("{}&apikey={{api_key}}", d["request"]["url"].as_str().unwrap()));
    let env = Env::new("key", d, &srv, "/v1/forecast");
    let here = burley_loc();
    let mut g = grant(&["weather"]);
    let e = env.run(json!({"source": "weather"}), Some(&here), T0, None, Some(&g)).unwrap_err();
    assert_eq!((e.code.as_str(), e.top["not_refreshed"].as_str()), ("no_data", Some("refresh failed: API key missing")));
    assert_eq!(srv.hits(), 0, "nothing was sent without the key");
    g.keys.insert("weather".into(), SENTINEL.into());
    let v = env.run(json!({"source": "weather"}), Some(&here), T0, None, Some(&g)).unwrap();
    assert_eq!(srv.hits(), 1);
    assert!(srv.urls.lock().unwrap()[0].contains(SENTINEL));
    let mut seen = vec![v.to_string()];
    // a failing provider: the error text must not carry the key either
    *srv.status.lock().unwrap() = 403;
    let late = Location { lat: 41.0, lon: -112.0, ..burley_loc() };
    let e = env.run(json!({"source": "weather"}), Some(&late), T0, None, Some(&g)).unwrap_err();
    seen.push(e.to_json().to_string());
    seen.push(format!("{e:?}"));
    for s in &seen {
        assert!(!s.contains(SENTINEL), "{s}");
    }
    // and it is not in the database
    let db = std::fs::read(env.dir.join("live.sqlite")).unwrap();
    assert!(!String::from_utf8_lossy(&db).contains(SENTINEL));
}

#[test]
fn rows_for_positions_are_pruned_like_the_phones_other_positions() {
    let srv = Server::start("/alerts/active", fixture("nws_boise.json"));
    let env = Env::new("prune", real_source("alerts.json"), &srv, "/alerts/active");
    let g = grant(&["alerts"]);
    let at = |lat: f64| Location { lat, lon: -114.0, ..burley_loc() };
    env.run(json!({"source": "alerts"}), Some(&at(42.0)), "2026-10-25T04:00:00-06:00", None, Some(&g)).unwrap();
    env.run(json!({"source": "alerts"}), Some(&at(43.0)), "2026-10-25T16:00:00-06:00", None, Some(&g)).unwrap();
    // the first row had run out of validity; only the newest stays
    assert_eq!(env.rows(), vec!["at:43.00,-114.00".to_string()]);
}

// ---- not_refreshed: why data due for a refresh was not refreshed ------------------------------------------------------------

/// Alerts stored at T0 (refresh 15 minutes, valid 6 hours): fresh until 11:05, due after, expired after 16:50.
fn alerts_stored(name: &str) -> (Env, Server, Location) {
    let (env, srv) = alerts(name);
    let here = burley_loc();
    env.run(json!({"source": "alerts"}), Some(&here), T0, None, Some(&grant(&["alerts"]))).unwrap();
    assert_eq!(srv.hits(), 1);
    (env, srv, here)
}

const DUE: &str = "2026-10-25T11:20:00-06:00";
const EXPIRED: &str = "2026-10-25T18:00:00-06:00";

fn denied(why: NotAllowed) -> Grant {
    Grant { why: Some(why), ..Default::default() }
}

fn stand_in(code: &'static str) -> Grant {
    Grant { fail: Some(code), ..grant(&["alerts"]) }
}

#[test]
fn not_refreshed_for_each_reason_on_due_data() {
    let (env, srv, here) = alerts_stored("nr-each");
    let cases: Vec<(Grant, &str)> = vec![
        (denied(NotAllowed::SwitchedOff), "this source is switched off"),
        (denied(NotAllowed::Offline), "no connection"),
        (denied(NotAllowed::MeteredOff), "mobile data updates are off"),
        (stand_in("fetch_failed"), "refresh failed: couldn't reach the source"),
        (stand_in("quota"), "refresh failed: daily limit reached"),
        (stand_in("key_missing"), "refresh failed: API key missing"),
        (stand_in("bad_response"), "refresh failed: the source sent bad data"),
    ];
    for (g, words) in &cases {
        let v = env.run(json!({"source": "alerts"}), Some(&here), DUE, None, Some(g)).unwrap();
        assert_eq!(v["not_refreshed"], *words);
        // right after the dated fields, nothing else changed
        let keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(keys, ["source", "place", "fetched_at", "valid_until", "age", "expired", "not_refreshed", "items", "none"]);
        assert_eq!(v["age"], "30 minutes old");
    }
    assert_eq!(srv.hits(), 1, "a denied fetch and a stand-in failure send nothing");
}

#[test]
fn not_refreshed_is_absent_on_fresh_data_without_a_fetcher_and_after_a_good_download() {
    let (env, srv, here) = alerts_stored("nr-absent");
    let fresh = "2026-10-25T11:00:00-06:00";
    for g in [denied(NotAllowed::Offline), stand_in("quota")] {
        let v = env.run(json!({"source": "alerts"}), Some(&here), fresh, None, Some(&g)).unwrap();
        assert!(v.get("not_refreshed").is_none(), "fresh data: {v}");
    }
    // no fetcher (captures, tests) or a host that gives no reason: the old output
    let v = env.run(json!({"source": "alerts"}), Some(&here), DUE, None, None).unwrap();
    assert!(v.get("not_refreshed").is_none());
    let v = env.run(json!({"source": "alerts"}), Some(&here), DUE, None, Some(&grant(&[]))).unwrap();
    assert!(v.get("not_refreshed").is_none());
    assert_eq!(srv.hits(), 1);
    // due and allowed: downloaded again, and nothing to say
    let v = env.run(json!({"source": "alerts"}), Some(&here), DUE, None, Some(&grant(&["alerts"]))).unwrap();
    assert_eq!(srv.hits(), 2);
    assert!(v.get("not_refreshed").is_none());
    assert_eq!(v["age"], "less than a minute old");
}

#[test]
fn a_real_failed_refresh_keeps_the_older_data_and_says_why() {
    let (env, srv, here) = alerts_stored("nr-real");
    let g = grant(&["alerts"]);
    *srv.status.lock().unwrap() = 500;
    let v = env.run(json!({"source": "alerts"}), Some(&here), DUE, None, Some(&g)).unwrap();
    assert_eq!(srv.hits(), 2);
    assert_eq!(v["not_refreshed"], "refresh failed: couldn't reach the source");
    assert_eq!(v["fetched_at"], "2026-10-25T10:50:00-06:00");
    // the provider answers with something that is not its format
    *srv.status.lock().unwrap() = 200;
    let srv2 = Server::start("/alerts/active", "not json".into());
    let env2 = Env::new("nr-real-bad", real_source("alerts.json"), &srv2, "/alerts/active");
    let e = env2.run(json!({"source": "alerts"}), Some(&here), T0, None, Some(&g)).unwrap_err();
    assert_eq!((e.code.as_str(), e.top["not_refreshed"].as_str()), ("no_data", Some("refresh failed: the source sent bad data")));
}

/// The exact bytes: the success shape, expired and no_data. Every other byte is what it was before not_refreshed.
#[test]
fn not_refreshed_golden_bytes() {
    let (env, _srv, here) = alerts_stored("nr-golden");
    let before = env.run(json!({"source": "alerts"}), Some(&here), DUE, None, None).unwrap().to_string();
    let after = env.run(json!({"source": "alerts"}), Some(&here), DUE, None, Some(&denied(NotAllowed::MeteredOff))).unwrap().to_string();
    assert_eq!(after, before.replacen(r#""expired":false,"#, r#""expired":false,"not_refreshed":"mobile data updates are off","#, 1));
    assert_eq!(
        after,
        r#"{"source":{"id":"alerts","title":"Emergency alerts","provider":"NWS"},"place":"current location","fetched_at":"2026-10-25T10:50:00-06:00","valid_until":"2026-10-25T16:50:00-06:00","age":"30 minutes old","expired":false,"not_refreshed":"mobile data updates are off","items":[{"address":"live:alerts/at:42.54,-113.79/none","label":"No active emergency alerts","time":"2026-10-25T10:50:00-06:00","fields":{"Status":"none active","Checked":"2026-10-25 10:50","Age":"30 minutes old"},"none_active":true}],"none":true}"#
    );
    // expired, on mobile data with updates off
    let e = env.run(json!({"source": "alerts"}), Some(&here), EXPIRED, None, Some(&denied(NotAllowed::MeteredOff))).unwrap_err();
    assert_eq!(
        e.to_json().to_string(),
        r#"{"ok":false,"error":{"type":"expired","detail":"alerts data expired 2026-10-25"},"not_refreshed":"mobile data updates are off"}"#
    );
    // expired, and the refresh failed
    let e = env.run(json!({"source": "alerts"}), Some(&here), EXPIRED, None, Some(&stand_in("quota"))).unwrap_err();
    assert_eq!(
        e.to_json().to_string(),
        r#"{"ok":false,"error":{"type":"expired","detail":"alerts data expired 2026-10-25"},"not_refreshed":"refresh failed: daily limit reached"}"#
    );
    // nothing ever downloaded, offline
    let (empty, _srv2) = alerts("nr-golden-empty");
    let e = empty.run(json!({"source": "alerts"}), Some(&here), DUE, None, Some(&denied(NotAllowed::Offline))).unwrap_err();
    assert_eq!(
        e.to_json().to_string(),
        r#"{"ok":false,"error":{"type":"no_data","detail":"no alerts data has been downloaded for current location"},"not_refreshed":"no connection"}"#
    );
    // and without a fetcher, the same errors as before
    let e = empty.run(json!({"source": "alerts"}), Some(&here), DUE, None, None).unwrap_err();
    assert_eq!(e.to_json().to_string(), r#"{"ok":false,"error":{"type":"no_data","detail":"no alerts data has been downloaded for current location"}}"#);
}
