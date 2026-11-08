//! A source made with the app's Add your own source form. tests/fixtures/own_source_def.json is exactly what the form saves for a
//! creek gauge (app/test/own_source_test.dart checks the app writes that file): here the core checks it as it checks every published
//! definition, previews it, and runs it through the live engine against a server on this machine, with the key given at fetch time.

use cache_live::def::SourceDef;
use cache_live::{Live, LiveCfg};
use cache_user::UserStore;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

const T0: &str = "2026-11-07T12:40:00-07:00";
const KEY: &str = "KEY-own-7f3a";

fn fixture(name: &str) -> String {
    std::fs::read_to_string(PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures").join(name)).unwrap()
}

/// The fixture's definition, its address pointed at [base].
fn definition(base: &str) -> String {
    fixture("own_source_def.json").replace("https://sensors.example.org", base)
}

/// A server on this machine answering every request with the recorded gauge answer; it notes the urls asked.
fn serve() -> (String, Arc<Mutex<Vec<String>>>) {
    let server = tiny_http::Server::http("127.0.0.1:0").unwrap();
    let port = server.server_addr().to_ip().unwrap().port();
    let log = Arc::new(Mutex::new(Vec::new()));
    let l2 = log.clone();
    std::thread::spawn(move || {
        for req in server.incoming_requests() {
            l2.lock().unwrap().push(req.url().to_string());
            let _ = req.respond(tiny_http::Response::from_string(fixture("own_source_response.json")));
        }
    });
    (format!("http://127.0.0.1:{port}"), log)
}

fn place() -> Value {
    json!({"key": "burley", "name": "Burley, ID", "lat": 42.536, "lon": -113.792})
}

#[test]
fn the_definition_the_form_saves_passes_the_check_every_definition_passes() {
    let text = fixture("own_source_def.json");
    let d = SourceDef::check(&text).unwrap_or_else(|e| panic!("refused: {e:?}"));
    assert_eq!(d.id, "own-creek-level-at-the-bridge");
    assert_eq!(d.api_key.as_ref().unwrap().alias, "own-creek-level-at-the-bridge");
    assert!(!text.contains(KEY));
    let r: Value = serde_json::from_str(&cache_live::preview::preview(&json!({"definition": text, "check_only": true}).to_string()).unwrap()).unwrap();
    assert_eq!(r["valid"], true);
    assert_eq!(r["source"]["needs_key"], "own-creek-level-at-the-bridge");
}

#[test]
fn it_previews_and_runs_through_the_live_engine_for_a_place_with_the_key_given_at_fetch_time() {
    let (base, log) = serve();
    let text = definition(&base);
    // cs live-preview's path: one download, the items mapped
    let pv: Value = serde_json::from_str(
        &cache_live::preview::preview(&json!({"definition": text, "place": place(), "api_key": KEY, "now": T0}).to_string()).unwrap(),
    )
    .unwrap();
    assert!(pv.get("mapping_error").is_none(), "{pv}");
    assert_eq!(pv["items"][0]["label"], "Water level 1.42");
    // the engine: the definition in the sources folder, fetched for the place, read back as the app and live_data read it
    let dir = std::env::temp_dir().join(format!("cache-live-own-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("sources")).unwrap();
    std::fs::write(dir.join("sources/own-creek-level-at-the-bridge.json"), text.as_bytes()).unwrap();
    let live = Live::new(LiveCfg::new(dir.join("live.sqlite").to_string_lossy(), dir.join("sources").to_string_lossy()));
    let places = UserStore::new(dir.join("user.sqlite"));
    let (defs, errors) = live.defs();
    assert!(errors.is_empty(), "{errors:?}");
    assert_eq!(defs.len(), 1);
    let got: Value = serde_json::from_str(
        &live.fetch(&json!({"source": "own-creek-level-at-the-bridge", "place": place(), "api_key": KEY, "now": T0}).to_string(), &places).unwrap(),
    )
    .unwrap();
    let item = &got["items"][0];
    assert_eq!(item["label"], "Water level 1.42");
    assert_eq!(item["fields"], json!({"Trend": "Rising", "Updated": "12:40"}));
    assert_eq!(item["point"], json!({"lat": 42.53, "lon": -113.79}));
    // the place and the key went into the address the person typed
    let asked = log.lock().unwrap().clone();
    let want = format!("/api/creek?site=12&lat=42.5360&lon=-113.7920&key={KEY}");
    assert!(!asked.is_empty() && asked.iter().all(|u| *u == want), "{asked:?}");
    // read back from the store; the key is not kept
    let back: Value = serde_json::from_str(&live.get(&json!({"source": "own-creek-level-at-the-bridge", "place": place(), "now": T0}).to_string(), &places).unwrap()).unwrap();
    assert_eq!(back["items"][0]["label"], "Water level 1.42");
    assert!(!String::from_utf8_lossy(&std::fs::read(dir.join("live.sqlite")).unwrap()).contains(KEY));
    // without its key it is not fetched
    assert_eq!(live.fetch(&json!({"source": "own-creek-level-at-the-bridge", "place": place(), "now": T0, "force": true}).to_string(), &places).unwrap_err().code, "key_missing");
    let _ = std::fs::remove_dir_all(&dir);
}
