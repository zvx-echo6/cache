//! The real Utah places build through the handle (ignored: it needs the build's files). The Wasatch Front tiles are merged
//! into one database the way the regions engine does it (merged::create, merge_tile), then addresses, a town name, nearby
//! and a list of searches run through cs_map_search, the live_data place lookup and cs_tool, and the top 3 are printed.
//!
//! CACHE_UTAH_PLACES = the build folder (common.sqlite, index.tsv, 1/aaa/bbb.sqlite.gz), e.g.
//!   cargo test -p cache_search --test utah_places -- --ignored --nocapture

use cache_places::merged;
use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_tool::places::{Geocoder, PlaceSource};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::io::Read;
use std::path::{Path, PathBuf};

const SLC: (f64, f64) = (40.7608, -111.8910);
/// The level 1 tiles of the Wasatch Front: Salt Lake and Utah valleys, Tooele, Park City, Ogden, Logan's edge, Nephi.
const TILES: &[&str] = &["1/046/867", "1/046/868", "1/046/869", "1/047/227", "1/047/228", "1/047/229", "1/046/508"];

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

fn tile_id(path: &str) -> u32 {
    let digits: String = path[2..].chars().filter(char::is_ascii_digit).collect();
    digits.parse().unwrap()
}

/// The merged database of TILES at `<dir>/<build>.sqlite`, named by `<dir>/CURRENT`.
fn merge_all(build_dir: &Path, dir: &Path) {
    std::fs::create_dir_all(dir).unwrap();
    let tmp = dir.join("merging.sqlite");
    let mut c = merged::create(&tmp, &build_dir.join("common.sqlite")).unwrap();
    let build: String = c.query_row("SELECT value FROM meta WHERE key = 'build'", [], |r| r.get(0)).unwrap();
    for path in TILES {
        let gz = build_dir.join(format!("{path}.sqlite.gz"));
        let mut raw = Vec::new();
        flate2::read::GzDecoder::new(std::fs::File::open(&gz).unwrap()).read_to_end(&mut raw).unwrap();
        let shard = dir.join("shard.sqlite");
        std::fs::write(&shard, &raw).unwrap();
        let t0 = std::time::Instant::now();
        merged::merge_tile(&mut c, tile_id(path), &shard, "-", raw.len() as u64).unwrap();
        println!("merged {path}: {} bytes in {} ms", raw.len(), t0.elapsed().as_millis());
    }
    merged::set_regions(&c, "Wasatch Front").unwrap();
    merged::maintain(&c).unwrap();
    drop(c);
    std::fs::rename(&tmp, dir.join(format!("{build}.sqlite"))).unwrap();
    println!("merged database: {} bytes", std::fs::metadata(dir.join(format!("{build}.sqlite"))).unwrap().len());
    std::fs::write(dir.join("CURRENT"), &build).unwrap();
}

fn top3(v: &Value) -> String {
    let rows: Vec<String> = v["results"]
        .as_array()
        .into_iter()
        .flatten()
        .take(3)
        .map(|r| {
            let km = r["distance_m"].as_f64().map(|m| format!("{:.1} km", m / 1000.0)).unwrap_or_default();
            format!(
                "{} [{} | {}] {} {} ({})",
                r["name"].as_str().unwrap_or(""),
                r["type"].as_str().unwrap_or(""),
                r["kind"].as_str().unwrap_or(""),
                r["address"].as_str().unwrap_or(""),
                km,
                r["matched"].as_str().unwrap_or("")
            )
        })
        .collect();
    let mut s = format!("meaning={} warning_code={}", v["meaning"], v.get("warning_code").unwrap_or(&Value::Null));
    for (i, r) in rows.iter().enumerate() {
        s.push_str(&format!("\n    {}. {r}", i + 1));
    }
    if rows.is_empty() {
        s.push_str("\n    (nothing)");
    }
    s
}

#[test]
#[ignore]
fn the_wasatch_front() {
    let build_dir = PathBuf::from(std::env::var("CACHE_UTAH_PLACES").expect("CACHE_UTAH_PLACES = the Utah build folder"));
    let work = std::env::temp_dir().join(format!("utah-places-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    let dir = work.join("places");
    merge_all(&build_dir, &dir);

    let cfg = json!({"sources": [], "places": {"packs": [], "merged_dir": dir}});
    let h: *mut Handle = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
    assert!(!h.is_null());
    unsafe { assert_eq!(cs_set_location(h, SLC.0, SLC.1, 10.0, cstr("2026-10-28T12:00:00-06:00").as_ptr()), 0) };
    let search = |q: &str| -> Value {
        let req = json!({"query": q, "near": {"lat": SLC.0, "lon": SLC.1}, "limit": 10});
        let t0 = std::time::Instant::now();
        let v: Value = serde_json::from_str(&take(unsafe { cs_map_search(h, cstr(&req.to_string()).as_ptr()) }).unwrap()).unwrap();
        println!("  ({} ms)", t0.elapsed().as_millis());
        v
    };

    println!("\n== addresses (map search)");
    for q in ["350 N State St, Salt Lake City", "451 S State St Salt Lake City", "50 N Medical Dr, Salt Lake City", "50 N West Temple St"] {
        let v = search(q);
        println!("{q:?}: {}", top3(&v));
    }

    println!("\n== a town by name (the live_data place lookup: PlaceSource::resolve_full)");
    let source = unsafe { (*h).ext.places.read().unwrap().clone() }.expect("a place source");
    let geo = source.geocoder().expect("a geocoder");
    for q in ["Salt Lake City", "Salt Lake City, UT", "350 N State St, Salt Lake City"] {
        let r = geo.resolve_full(q, None);
        println!("{q:?}: {:?}", r.map(|r| (r.name, r.lat, r.lon, r.state, r.state_name, r.county, r.country)));
    }

    println!("\n== nearby (cs_tool)");
    let conv = cs_conversation_new();
    for args in [json!({"category": "pharmacy"}), json!({"category": "pharmacy", "near": "Salt Lake City"}), json!({"category": "hospital", "limit": 3})] {
        let p = unsafe { cs_tool(h, conv, cstr("nearby").as_ptr(), cstr(&args.to_string()).as_ptr(), cstr("2026-10-28T12:00:00-06:00").as_ptr()) };
        let v: Value = serde_json::from_str(&take(p).unwrap()).unwrap();
        let content: Value = serde_json::from_str(v["content"].as_str().unwrap()).unwrap_or(v["content"].clone());
        let places: Vec<String> = content["places"]
            .as_array()
            .into_iter()
            .flatten()
            .take(3)
            .map(|p| format!("{} ({}, {} mi {})", p["name"].as_str().unwrap_or(""), p["street"].as_str().unwrap_or("-"), p["distance_mi"], p["direction"].as_str().unwrap_or("")))
            .collect();
        println!("{args}: {}", if places.is_empty() { content.to_string() } else { places.join(" | ") });
    }
    unsafe { cs_conversation_free(conv) };

    println!("\n== map search, place-search-eval.md top 50 (no kind vectors in this build)");
    let top50 = [
        "food", "restaurants", "gas", "coffee", "grocery store", "pharmacy", "hospital", "hotel", "ATM", "urgent care", "ER", "breakfast",
        "lunch", "dinner", "fast food", "pizza", "Walmart", "McDonald's", "gas station", "emergency room", "doctor", "convenience store",
        "parking", "EV charging", "bank", "Starbucks", "Costco", "Walgreens", "CVS", "Target", "bar", "hardware store", "Home Depot",
        "auto repair", "tire shop", "auto parts", "car wash", "post office", "police", "dentist", "vet", "motel", "campground", "park",
        "restroom", "rest area", "laundromat", "liquor store", "Mexican food", "Chinese food",
    ];
    for (i, q) in top50.iter().enumerate() {
        let v = search(q);
        println!("{}. {q:?}: {}", i + 1, top3(&v));
    }

    unsafe { cs_close(h) };
    let _ = std::fs::remove_dir_all(&work);
}
