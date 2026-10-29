//! Places through the handle: cs_places_refresh, the places feed a map search fetches through first, the regions engine's
//! merged database found with no `merged_dir`, and `kind:` route ends.

use cache_places::fixture::{fixture_tiles, write_fixture_common, write_fixture_pack, write_fixture_shard, FIXTURE_BUILD};
use cache_places::{merged, PlacesFeed, PrepareAnswer};
use cache_search::ffi::*;
use cache_search::handle::Handle;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const BURLEY: (f64, f64) = (42.5357, -113.7928);

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cs-places-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Tmp(p)
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn last_error(h: *mut Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_last_error(h) }).unwrap()).unwrap()
}

/// The fixture's tiles merged into `<dir>/<build>.sqlite`, named by `<dir>/CURRENT` (the regions engine's steps).
fn merged_db(dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    let common = dir.join("common-src.sqlite");
    write_fixture_common(&common, FIXTURE_BUILD);
    let mut c = merged::create(&dir.join(format!("{FIXTURE_BUILD}.sqlite")), &common).unwrap();
    for tile in fixture_tiles() {
        let shard = dir.join(format!("{tile}.shard"));
        write_fixture_shard(&shard, tile, FIXTURE_BUILD);
        merged::merge_tile(&mut c, tile, &shard, "0", 0).unwrap();
    }
    merged::set_regions(&c, "Idaho").unwrap();
    drop(c);
    std::fs::write(dir.join("CURRENT"), FIXTURE_BUILD).unwrap();
}

struct H(*mut Handle);
impl H {
    fn open(cfg: Value) -> H {
        let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
        assert!(!h.is_null(), "{:?}", last_error(ptr::null_mut()));
        H(h)
    }
    fn search(&self, req: Value) -> Value {
        let p = unsafe { cs_map_search(self.0, cstr(&req.to_string()).as_ptr()) };
        serde_json::from_str(&take(p).unwrap_or_else(|| panic!("{}", last_error(self.0)))).unwrap()
    }
    fn refresh(&self, args: Option<&str>) -> Option<Value> {
        let a = args.map(cstr);
        let p = unsafe { cs_places_refresh(self.0, a.as_ref().map(|a| a.as_ptr()).unwrap_or(ptr::null())) };
        take(p).map(|s| serde_json::from_str(&s).unwrap())
    }
}
impl Drop for H {
    fn drop(&mut self) {
        unsafe { cs_close(self.0) };
    }
}

fn near_burley(q: &str) -> Value {
    json!({"query": q, "near": {"lat": BURLEY.0, "lon": BURLEY.1}, "meaning": false})
}

#[test]
fn places_refresh_replaces_the_packs_and_reads_the_merged_database() {
    let t = Tmp::new("refresh");
    let pack = t.0.join("idaho.sqlite");
    write_fixture_pack(&pack);
    let merged_dir = t.0.join("regions/places");
    let h = H::open(json!({"sources": [], "places": {"packs": [], "merged_dir": merged_dir}}));
    let v = h.search(near_burley("pharmacy"));
    assert_eq!(v["warning_code"], "no_places", "{v}");
    assert_eq!(h.refresh(None).unwrap(), json!({"ok": true, "packs": 0, "merged": false}));

    // a pack copied in: found once it is named
    assert_eq!(h.refresh(Some(&json!({"packs": [pack]}).to_string())).unwrap(), json!({"ok": true, "packs": 1, "merged": false}));
    let v = h.search(near_burley("pharmacy"));
    assert!(v.get("warning_code").is_none(), "{v}");
    assert!(v["results"].as_array().unwrap().iter().any(|r| r["name"] == "Walgreens"), "{v}");

    // the merged database appears (CURRENT written) and is read by the next call, before the pack
    merged_db(&merged_dir);
    assert_eq!(h.refresh(Some("{}")).unwrap(), json!({"ok": true, "packs": 1, "merged": true}));
    assert_eq!(h.refresh(Some(r#"{"packs": []}"#)).unwrap(), json!({"ok": true, "packs": 0, "merged": true}));
    let v = h.search(near_burley("pharmacy"));
    assert!(v["results"].as_array().unwrap().iter().any(|r| r["name"] == "Walgreens"), "{v}");

    // bad arguments
    assert!(h.refresh(Some(r#"{"pack": []}"#)).is_none());
    assert_eq!(last_error(h.0)["code"], "bad_json");
    assert!(h.refresh(Some(r#"{"packs": [1]}"#)).is_none());
    assert!(h.refresh(Some("[]")).is_none());
}

#[test]
fn places_refresh_needs_a_places_section() {
    let h = H::open(json!({"sources": []}));
    assert!(h.refresh(None).is_none());
    assert_eq!(last_error(h.0)["code"], "not_configured");
}

/// A feed that records where it was asked and answers what it is told.
struct Fake {
    asked: Mutex<Vec<(f64, f64, Duration)>>,
    answer: PrepareAnswer,
}
impl PlacesFeed for Fake {
    fn prepare(&self, lat: f64, lon: f64, wait: Duration) -> PrepareAnswer {
        self.asked.lock().unwrap().push((lat, lon, wait));
        self.answer
    }
    fn generation(&self) -> u64 {
        0
    }
}

#[test]
fn a_map_search_fetches_through_the_feed_first() {
    let t = Tmp::new("feed");
    let h = H::open(json!({"sources": [], "places": {"packs": [], "merged_dir": t.0.join("places")}}));
    let feed = Arc::new(Fake { asked: Mutex::new(Vec::new()), answer: PrepareAnswer { pending: 1, ok: true, ..Default::default() } });
    unsafe { (*h.0).ext.map_places.as_ref().unwrap().plug_feed(feed.clone()) };
    let v = h.search(near_burley("pharmacy"));
    assert_eq!(v["warning_code"], "fetching", "{v}");
    assert_eq!(v["places"], json!({"installed": false, "covers": false, "pending": 1}));
    assert_eq!(*feed.asked.lock().unwrap(), [(BURLEY.0, BURLEY.1, Duration::from_secs(3))]);
    // coordinates need no places: the feed is not asked
    let v = h.search(near_burley("42.5, -113.7"));
    assert_eq!(v["interpreted"]["kind"], "coordinates");
    assert_eq!(feed.asked.lock().unwrap().len(), 1);
    // nor without a centre
    h.search(json!({"query": "pharmacy"}));
    assert_eq!(feed.asked.lock().unwrap().len(), 1);
}

#[test]
fn the_regions_engine_is_the_feed_and_its_merged_database_is_read() {
    let t = Tmp::new("regions");
    let dir = t.0.join("regions");
    merged_db(&dir.join("places"));
    // nothing listens on port 9: the feed's fetch fails at once, and the tiles on the phone are searched
    let h = H::open(json!({"sources": [], "places": {"packs": []},
        "regions": {"dir": dir, "base_url": "http://127.0.0.1:9/routing/", "places_base_url": "http://127.0.0.1:9/places/"}}));
    let core = unsafe { (*h.0).ext.map_places.clone().unwrap() };
    assert!(core.feed().is_some());
    assert_eq!(core.packs.merged_dir(), Some(dir.join("places")));
    let v = h.search(near_burley("pharmacy"));
    assert!(v.get("warning_code").is_none(), "{v}");
    assert_eq!(v["places"]["covers"], true);
    assert!(v["results"].as_array().unwrap().iter().any(|r| r["name"] == "Walgreens"), "{v}");
    // where the phone has no tile and the fetch failed: not_here
    let v = h.search(json!({"query": "pharmacy", "near": {"lat": 40.76, "lon": -111.89}, "meaning": false}));
    assert_eq!(v["warning_code"], "not_here", "{v}");
    assert_eq!(h.refresh(None).unwrap(), json!({"ok": true, "packs": 0, "merged": true}));
}

#[test]
fn a_kind_id_is_the_nearest_place_of_that_kind() {
    let t = Tmp::new("kind");
    let dir = t.0.join("places");
    merged_db(&dir);
    let h = H::open(json!({"sources": [], "places": {"packs": [], "merged_dir": dir}}));
    let core = unsafe { (*h.0).ext.map_places.clone().unwrap() };
    let packs = core.packs.current();
    let kind = packs[0].kinds.iter().find(|k| packs[0].kind_place_count(&k.id) > 0).expect("a kind with places").id.clone();
    let id = format!("kind:{kind}");
    assert!(core.lookup(&id).is_none(), "a kind needs a centre");
    let e = core.lookup_near(&id, Some(BURLEY)).expect("nearest of the kind");
    assert!(e.id.as_deref().unwrap().starts_with("place:"), "{e:?}");
}
