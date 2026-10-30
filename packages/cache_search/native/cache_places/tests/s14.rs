//! Spec S14: a place's `about` (the pack's stored `about` column, as it is) and `wikipedia` in nearby, locate and the place
//! source navigate resolves through.

use rusqlite::Connection;
use cache_places::fixture::{add_fixture_summaries, write_fixture_pack, FIXTURE_NOW};
use cache_places::{tools, PlacesCfg};
use cache_tool::places::GeocodeQuery;
use cache_tool::{NoSavedPlaces, Tool, ToolCtx, ToolOutput};
use serde_json::{json, Value};
use std::path::PathBuf;

struct Dir(PathBuf);
impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The fixture pack, with summaries and Wikipedia titles on Sawtooth Spring, Stanley Lake and the town of Stanley when `wiki`.
fn pack(name: &str, wiki: bool) -> (Dir, PlacesCfg) {
    let p = std::env::temp_dir().join(format!("cp-s14-{}-{}", std::process::id(), name));
    let _ = std::fs::remove_dir_all(&p);
    std::fs::create_dir_all(&p).unwrap();
    let f = p.join("places.sqlite");
    write_fixture_pack(&f);
    if wiki {
        add_fixture_summaries(&f);
    }
    let cfg = PlacesCfg { packs: vec![f.to_string_lossy().into_owned()], merged_dir: None };
    (Dir(p), cfg)
}

fn run(ts: &[Box<dyn Tool>], name: &str, args: Value) -> Value {
    let t = ts.iter().find(|t| t.name() == name).unwrap();
    let ctx = ToolCtx { location: None, places: &NoSavedPlaces, now: FIXTURE_NOW, geocoder: None, live_fetcher: None };
    match t.run(&ctx, &args) {
        Ok(ToolOutput::Json(v)) => v,
        Ok(ToolOutput::Text(_)) => panic!("text"),
        Err(e) => e.to_json(),
    }
}

fn keys(v: &Value) -> Vec<&str> {
    v.as_object().unwrap().keys().map(String::as_str).collect()
}

const SPRING_ABOUT: &str = "A cold natural spring where hikers and campers fill their water bottles and refill drinking water.";

#[test]
fn nearby_rows_end_with_about_then_wikipedia_and_leave_both_out_when_the_place_has_none() {
    let (_d, cfg) = pack("nearby", true);
    let v = run(&tools(&cfg), "nearby", json!({"category": "water", "near": "Stanley, Idaho", "limit": 10}));
    let rows = v["places"].as_array().unwrap();
    let spring = rows.iter().find(|p| p["name"] == "Sawtooth Spring").expect("the named spring");
    assert_eq!(
        serde_json::to_string(spring).unwrap(),
        format!(
            r#"{{"address":"place:{}","name":"Sawtooth Spring","kind":"spring","kind_label":"Spring","locality":"Stanley","state":"ID","distance_mi":{},"direction":{},"open_status":"Hours not known","about":"{SPRING_ABOUT}","wikipedia":"Sawtooth Spring"}}"#,
            spring["address"].as_str().unwrap().trim_start_matches("place:"),
            spring["distance_mi"],
            spring["direction"]
        )
    );
    // the other rows have no summary: no key at all, never null or ""
    for r in rows.iter().filter(|p| p["name"] != "Sawtooth Spring") {
        assert!(r.get("about").is_none() && r.get("wikipedia").is_none(), "{r}");
        assert_eq!(*keys(r).last().unwrap(), "open_status", "{r}");
    }
}

#[test]
fn without_wiki_entries_nearby_and_locate_are_byte_identical_to_before() {
    // the same fixture with and without summaries: every row and result that has none is the same bytes either way
    let (_a, plain) = pack("plain", false);
    let (_b, wiki) = pack("wiki", true);
    let (tp, tw) = (tools(&plain), tools(&wiki));
    let a = run(&tp, "nearby", json!({"category": "water", "near": "Stanley, Idaho", "limit": 10}));
    let b = run(&tw, "nearby", json!({"category": "water", "near": "Stanley, Idaho", "limit": 10}));
    for (x, y) in a["places"].as_array().unwrap().iter().zip(b["places"].as_array().unwrap()) {
        if y["name"] != "Sawtooth Spring" {
            assert_eq!(serde_json::to_string(x).unwrap(), serde_json::to_string(y).unwrap());
        }
    }
    for q in ["Burley, Idaho", "Walgreens, Burley", "Cassia Regional Hospital"] {
        let (x, y) = (run(&tp, "locate", json!({"place": q})), run(&tw, "locate", json!({"place": q})));
        assert_eq!(serde_json::to_string(&x).unwrap(), serde_json::to_string(&y).unwrap(), "{q}");
        assert!(x.get("about").is_none() && x.get("wikipedia").is_none(), "{q}");
    }
}

#[test]
fn locate_puts_about_then_wikipedia_after_plus_code_for_a_place_and_a_town() {
    let (_d, cfg) = pack("locate", true);
    let ts = tools(&cfg);
    let v = run(&ts, "locate", json!({"place": "Stanley Lake"}));
    assert_eq!(v["place_name"], "Stanley Lake (Stanley, ID)");
    let k = keys(&v);
    assert_eq!(&k[k.len() - 3..], ["plus_code", "about", "wikipedia"]);
    assert_eq!(v["about"], "A large alpine lake beneath the Sawtooth Mountains, popular for camping and kayaking.");
    assert_eq!(v["wikipedia"], "Stanley Lake");

    let v = run(&ts, "locate", json!({"place": "Stanley, Idaho"}));
    assert_eq!(v["place_name"], "Stanley, ID");
    let k = keys(&v);
    assert_eq!(&k[k.len() - 3..], ["plus_code", "about", "wikipedia"]);
    assert_eq!(v["about"], "A small mountain town in the Sawtooth Valley of Custer County, Idaho, at the foot of the Sawtooth Range.");
    assert_eq!(v["wikipedia"], "Stanley, Idaho");
}

#[test]
fn the_place_source_hands_navigate_about_and_wikipedia() {
    let (_d, cfg) = pack("source", true);
    let (_, src) = cache_places::tools_and_source(&cfg);
    let a = src.geocode(&GeocodeQuery { text: "Stanley Lake", near: None, bias: None, limit: 1 }).unwrap();
    let m = &a.matches[0];
    assert_eq!(m.place_name, "Stanley Lake");
    assert_eq!(m.wikipedia.as_deref(), Some("Stanley Lake"));
    assert!(m.about.as_deref().unwrap().starts_with("A large alpine lake"));
    let a = src.geocode(&GeocodeQuery { text: "Burley, Idaho", near: None, bias: None, limit: 1 }).unwrap();
    assert!(a.matches[0].about.is_none() && a.matches[0].wikipedia.is_none());
}

fn sql(cfg: &PlacesCfg, q: &str) {
    Connection::open(&cfg.packs[0]).unwrap().execute_batch(q).unwrap();
}

#[test]
fn about_is_the_stored_column_as_it_is_never_the_summary() {
    let (_d, cfg) = pack("stored", true);
    // a long summary: the build stored its opening; the core shows exactly that and never cuts or re-reads the summary
    let long = format!("{SPRING_ABOUT} {}", "More words here. ".repeat(40));
    sql(&cfg, &format!("UPDATE places SET summary = '{long}', about = 'A cold natural spring.' WHERE name = 'Sawtooth Spring';"));
    let v = run(&tools(&cfg), "nearby", json!({"category": "water", "near": "Stanley, Idaho", "limit": 10}));
    let spring = v["places"].as_array().unwrap().iter().find(|p| p["name"] == "Sawtooth Spring").unwrap().clone();
    assert_eq!(spring["about"], "A cold natural spring.");
    // a summary the build gave no `about` (no cut passed its checks): only `wikipedia`
    sql(&cfg, "UPDATE places SET about = NULL WHERE name = 'Sawtooth Spring';");
    let v = run(&tools(&cfg), "nearby", json!({"category": "water", "near": "Stanley, Idaho", "limit": 10}));
    let spring = v["places"].as_array().unwrap().iter().find(|p| p["name"] == "Sawtooth Spring").unwrap().clone();
    assert!(spring.get("about").is_none());
    assert_eq!(*keys(&spring).last().unwrap(), "wikipedia");
    assert_eq!(spring["wikipedia"], "Sawtooth Spring");
}

#[test]
fn a_pack_built_before_the_about_column_shows_wikipedia_only() {
    let (_d, cfg) = pack("old", true);
    sql(&cfg, "ALTER TABLE places DROP COLUMN about; ALTER TABLE localities DROP COLUMN about;");
    let ts = tools(&cfg);
    let v = run(&ts, "nearby", json!({"category": "water", "near": "Stanley, Idaho", "limit": 10}));
    let spring = v["places"].as_array().unwrap().iter().find(|p| p["name"] == "Sawtooth Spring").unwrap().clone();
    assert!(spring.get("about").is_none(), "{spring}");
    assert_eq!(spring["wikipedia"], "Sawtooth Spring");
    let v = run(&ts, "locate", json!({"place": "Stanley, Idaho"}));
    assert!(v.get("about").is_none());
    assert_eq!(v["wikipedia"], "Stanley, Idaho");
}
