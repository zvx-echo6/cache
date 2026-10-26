//! A tiny hand-made Idaho pack for tests (this crate's, the C ABI's and the CLI's). Real coordinates, invented details.
//! Not used at run time.

use crate::schema::{FORMAT_VERSION, SCHEMA};
use rusqlite::{params, Connection};
use std::path::Path;

/// The clock the fixture's tests use: twelve days after the pack was built.
pub const FIXTURE_NOW: &str = "2026-10-25T14:20:05-06:00";
pub const FIXTURE_BUILT_AT: &str = "2026-10-13T12:00:00+00:00";

/// The emergency_room rules as categories.json writes them: confirmed rows, then hospitals as "likely".
const ER_RULES: &str = r#"[{"source":"overture","basic_category":["emergency_department"],"require_match":{"category":"hospital","radius_m":250}},{"source":"category","category":"hospital","primary_tier":"confirmed","tier":"likely","note":"hospital, likely has an emergency room","beats_primary_only_if_nearer_by_mi":10}]"#;

struct P {
    name: &'static str,
    cat: Option<&'static str>,
    kind: &'static str,
    lat: f64,
    lon: f64,
    street: Option<&'static str>,
    locality: &'static str,
    phone: Option<&'static str>,
    hours: Option<&'static str>,
    alt: &'static str,
}

#[rustfmt::skip]
const PLACES: &[P] = &[
    P { name: "Walgreens", cat: Some("pharmacy"), kind: "amenity=pharmacy", lat: 42.5390, lon: -113.7870, street: Some("1414 Overland Ave"), locality: "Burley", phone: Some("+1 208 678 3050"), hours: Some("Mo-Su 08:00-22:00"), alt: "" },
    P { name: "Smith's Pharmacy", cat: Some("pharmacy"), kind: "amenity=pharmacy", lat: 42.5420, lon: -113.8080, street: None, locality: "Burley", phone: None, hours: None, alt: "" },
    P { name: "Rupert Drug", cat: Some("pharmacy"), kind: "amenity=pharmacy", lat: 42.6180, lon: -113.6740, street: Some("500 6th St"), locality: "Rupert", phone: None, hours: None, alt: "" },
    P { name: "Cassia Regional Hospital", cat: Some("hospital"), kind: "amenity=hospital", lat: 42.5290, lon: -113.7850, street: Some("1501 Hiland Ave"), locality: "Burley", phone: Some("+1 208 678 4444"), hours: None, alt: "Cassia Regional Medical Center" },
    P { name: "Minidoka Memorial Hospital", cat: Some("hospital"), kind: "amenity=hospital", lat: 42.6140, lon: -113.6720, street: Some("1224 8th St"), locality: "Rupert", phone: None, hours: None, alt: "" },
    P { name: "St. Luke's Boise Medical Center", cat: Some("hospital"), kind: "amenity=hospital", lat: 43.6126, lon: -116.1901, street: Some("190 E Bannock St"), locality: "Boise", phone: Some("+1 208 381 2222"), hours: None, alt: "" },
    P { name: "Saint Alphonsus Regional Medical Center", cat: Some("hospital"), kind: "amenity=hospital", lat: 43.6191, lon: -116.2791, street: Some("1055 N Curtis Rd"), locality: "Boise", phone: Some("+1 208 367 2121"), hours: None, alt: "" },
    P { name: "Saint Alphonsus Regional Medical Center", cat: Some("emergency_room"), kind: "emergency_department", lat: 43.6190, lon: -116.2790, street: Some("1055 N Curtis Rd"), locality: "Boise", phone: Some("+1 208 367 2121"), hours: Some("24/7"), alt: "" },
    P { name: "St. Luke's Boise Medical Center", cat: Some("emergency_room"), kind: "emergency_department", lat: 43.6125, lon: -116.1900, street: Some("190 E Bannock St"), locality: "Boise", phone: Some("+1 208 381 2222"), hours: Some("24/7"), alt: "St Lukes Boise" },
    P { name: "St. Luke's Magic Valley Regional Medical Center", cat: Some("hospital"), kind: "amenity=hospital", lat: 42.5530, lon: -114.4690, street: Some("801 Pole Line Rd W"), locality: "Twin Falls", phone: Some("+1 208 814 1000"), hours: None, alt: "" },
    P { name: "St. Luke's Magic Valley Regional Medical Center", cat: Some("emergency_room"), kind: "emergency_department", lat: 42.5531, lon: -114.4691, street: Some("801 Pole Line Rd W"), locality: "Twin Falls", phone: Some("+1 208 814 1000"), hours: Some("24/7"), alt: "" },
    P { name: "Heyburn Hospital", cat: Some("hospital"), kind: "amenity=hospital", lat: 42.5585, lon: -113.7691, street: None, locality: "Heyburn", phone: None, hours: None, alt: "" },
    P { name: "Chevron", cat: Some("fuel"), kind: "amenity=fuel", lat: 42.5400, lon: -113.7900, street: Some("1020 Overland Ave"), locality: "Burley", phone: None, hours: Some("24/7"), alt: "" },
    P { name: "Stanley Ranger Station", cat: Some("police"), kind: "amenity=police", lat: 44.2160, lon: -114.9310, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
    P { name: "Sawtooth Spring", cat: Some("water"), kind: "natural=spring", lat: 44.1700, lon: -114.9200, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
    P { name: "Burley Elementary School", cat: None, kind: "amenity=school", lat: 42.5350, lon: -113.7930, street: Some("200 W 10th St"), locality: "Burley", phone: None, hours: None, alt: "" },
    P { name: "Burley", cat: None, kind: "shop=convenience", lat: 42.5310, lon: -113.8000, street: None, locality: "Burley", phone: None, hours: None, alt: "" },
    P { name: "Amonara", cat: None, kind: "shop=gift", lat: 43.3700, lon: -112.1200, street: None, locality: "Shelley", phone: None, hours: None, alt: "" },
    P { name: "Ammin", cat: None, kind: "shop=convenience", lat: 43.4700, lon: -111.9700, street: None, locality: "Ammon", phone: None, hours: None, alt: "" },
    P { name: "Stanley Lake", cat: None, kind: "natural=water", lat: 44.2400, lon: -115.0000, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
];

// (name, kind, lat, lon, population, state)
#[rustfmt::skip]
const LOCALITIES: &[(&str, &str, f64, f64, i64, &str)] = &[
    ("Burley", "city", 42.5357, -113.7928, 10345, "ID"),
    ("Heyburn", "city", 42.5585, -113.7691, 3300, "ID"),
    ("Rupert", "city", 42.6166, -113.6747, 5600, "ID"),
    ("Declo", "city", 42.5238, -113.6122, 400, "ID"),
    ("Twin Falls", "city", 42.5629, -114.4609, 51000, "ID"),
    ("Boise", "city", 43.6150, -116.2023, 235000, "ID"),
    ("Idaho City", "city", 43.8280, -115.8340, 485, "ID"),
    ("Stanley", "town", 44.2210, -114.9360, 100, "ID"),
    ("Lowman", "hamlet", 44.0900, -115.6200, 40, "ID"),
    ("Stanley", "town", 46.3000, -97.2000, 80, "ND"),
    ("Island Park", "city", 44.4238, -111.3714, 300, "ID"),
    ("Ammon", "city", 43.4696, -111.9667, 17000, "ID"),
    // A big town one edit from Boise ("Boyse"): a test that an exact name beats a close fuzzy candidate.
    ("Boyse", "city", 46.0000, -112.5000, 900000, "ID"),
];

/// Writes the fixture pack to `path` (replacing any file there).
pub fn write_fixture_pack(path: &Path) {
    let _ = std::fs::remove_file(path);
    let c = Connection::open(path).expect("create fixture pack");
    c.execute_batch(SCHEMA).expect("schema");
    for (k, v) in [
        ("format_version", FORMAT_VERSION.to_string()),
        ("region_id", "idaho".into()),
        ("region_name", "Idaho".into()),
        ("built_at", FIXTURE_BUILT_AT.into()),
        ("min_lat", "41.9".into()),
        ("min_lon", "-117.3".into()),
        ("max_lat", "49.1".into()),
        ("max_lon", "-111.0".into()),
    ] {
        c.execute("INSERT INTO meta(key, value) VALUES (?1, ?2)", params![k, v]).unwrap();
    }
    for (i, (id, title, desc)) in [
        ("emergency_room", "Emergency room", "hospital emergency rooms; for a hospital in an emergency use emergency_room"),
        ("hospital", "Hospital", "hospitals, for information or a non-emergency visit"),
        ("urgent_care", "Urgent care", "walk-in urgent care clinics"),
        ("pharmacy", "Pharmacy", "pharmacies and drug stores"),
        ("fuel", "Fuel", "gas stations"),
        ("police", "Police", "police stations"),
        ("water", "Water", "drinking water, water points and springs"),
    ]
    .iter()
    .enumerate()
    {
        let n = PLACES.iter().filter(|p| p.cat == Some(*id)).count();
        c.execute(
            "INSERT INTO categories(id, title, description, rules, place_count, sort) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, title, desc, if *id == "emergency_room" { ER_RULES } else { "[]" }, n as i64, i as i64],
        )
        .unwrap();
    }
    c.execute("INSERT INTO states(code, name, country) VALUES ('ID', 'Idaho', 'US'), ('ND', 'North Dakota', 'US')", []).unwrap();
    for (i, p) in PLACES.iter().enumerate() {
        let id = i as i64 + 1;
        c.execute(
            "INSERT INTO places(id, name, category, kind, lat, lon, street, locality, state, country, phone, hours, source, source_id, confidence) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 'ID', 'US', ?9, ?10, 'osm', ?11, 0.9)",
            params![id, p.name, p.cat, p.kind, p.lat, p.lon, p.street, p.locality, p.phone, p.hours, format!("osm:n{id}")],
        )
        .unwrap();
        c.execute("INSERT INTO places_rt(id, min_lat, max_lat, min_lon, max_lon) VALUES (?1, ?2, ?2, ?3, ?3)", params![id, p.lat, p.lon]).unwrap();
        c.execute("INSERT INTO places_fts(rowid, name, alt_names) VALUES (?1, ?2, ?3)", params![id, p.name, p.alt]).unwrap();
    }
    // Each emergency room row names the hospital row it stands for (same name).
    for (i, p) in PLACES.iter().enumerate().filter(|(_, p)| p.cat == Some("emergency_room")) {
        let h = PLACES.iter().position(|q| q.cat == Some("hospital") && q.name == p.name).expect("hospital for the emergency room");
        c.execute("UPDATE places SET matched_source_id = ?1 WHERE id = ?2", params![format!("osm:n{}", h + 1), i as i64 + 1]).unwrap();
    }
    for (i, (name, kind, lat, lon, pop, state)) in LOCALITIES.iter().enumerate() {
        let id = i as i64 + 1;
        c.execute(
            "INSERT INTO localities(id, name, kind, lat, lon, population, state, country, source_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'US', ?8)",
            params![id, name, kind, lat, lon, pop, state, format!("osm:n9{id}")],
        )
        .unwrap();
        c.execute("INSERT INTO localities_rt(id, min_lat, max_lat, min_lon, max_lon) VALUES (?1, ?2, ?2, ?3, ?3)", params![id, lat, lon]).unwrap();
        c.execute("INSERT INTO localities_fts(rowid, name, alt_names) VALUES (?1, ?2, '')", params![id, name]).unwrap();
    }
}

/// A stand-in embedder for tests: a hashed bag of (singular) words, 64 values, so two texts that share words are close.
/// It is not a language model; the tests that use it check the plumbing, and real quality is measured with bge-m3.
pub fn fake_embed(text: &str) -> Vec<f32> {
    let mut v = vec![0.0f32; 64];
    for w in text.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()) {
        let w = w.to_lowercase();
        let w = w.strip_suffix('s').filter(|_| w.len() > 3).unwrap_or(&w).to_string();
        let mut h: u32 = 2166136261;
        for b in w.bytes() {
            h = (h ^ b as u32).wrapping_mul(16777619);
        }
        v[(h % 64) as usize] += 1.0;
    }
    v
}

pub const FAKE_MODEL: &str = "fake-hash-64";

/// Summaries for a few fixture rows (a place and a town), the way the wiki step fills them.
pub fn add_fixture_summaries(path: &Path) {
    let c = Connection::open(path).expect("open fixture pack");
    for (name, wp, text) in [
        ("Sawtooth Spring", "Sawtooth Spring", "A cold natural spring where hikers and campers fill their water bottles and refill drinking water."),
        ("Stanley Lake", "Stanley Lake", "A large alpine lake beneath the Sawtooth Mountains, popular for camping and kayaking."),
    ] {
        c.execute("UPDATE places SET summary = ?2, wikipedia_title = ?3 WHERE name = ?1", params![name, text, wp]).unwrap();
    }
    c.execute(
        "UPDATE localities SET summary = ?1, wikipedia_title = 'Stanley, Idaho' WHERE name = 'Stanley' AND state = 'ID'",
        params!["A small mountain town in the Sawtooth Valley of Custer County, Idaho, at the foot of the Sawtooth Range."],
    )
    .unwrap();
}

/// The fixture pack with summaries and with vectors from `fake_embed`.
pub fn write_fixture_pack_with_vectors(path: &Path) {
    write_fixture_pack(path);
    add_fixture_summaries(path);
    crate::embedpack::embed_pack(path, FAKE_MODEL, "none", &mut |t| Ok(fake_embed(t)), &mut |_| {}).expect("embed the fixture");
}
