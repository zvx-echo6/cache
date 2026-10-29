//! A tiny hand-made Idaho pack for tests (this crate's, the C ABI's and the CLI's). Real coordinates, invented details.
//! Not used at run time.

use crate::schema::{addr, pack_vector, tile_id_l1, tile_path_l1, tile_rect_l1, COMMON_SQL, FORMAT_VERSION, SCHEMA, TILE_SCHEMA, TILE_SQL};
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
    /// The kind id the format 2 pack holds.
    kid: &'static str,
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
    P { name: "Walgreens", cat: Some("pharmacy"), kind: "amenity=pharmacy", kid: "pharmacy", lat: 42.5390, lon: -113.7870, street: Some("1414 Overland Ave"), locality: "Burley", phone: Some("+1 208 678 3050"), hours: Some("Mo-Su 08:00-22:00"), alt: "" },
    P { name: "Smith's Pharmacy", cat: Some("pharmacy"), kind: "amenity=pharmacy", kid: "pharmacy", lat: 42.5420, lon: -113.8080, street: None, locality: "Burley", phone: None, hours: None, alt: "" },
    P { name: "Rupert Drug", cat: Some("pharmacy"), kind: "amenity=pharmacy", kid: "pharmacy", lat: 42.6180, lon: -113.6740, street: Some("500 6th St"), locality: "Rupert", phone: None, hours: None, alt: "" },
    P { name: "Cassia Regional Hospital", cat: Some("hospital"), kind: "amenity=hospital", kid: "hospital", lat: 42.5290, lon: -113.7850, street: Some("1501 Hiland Ave"), locality: "Burley", phone: Some("+1 208 678 4444"), hours: None, alt: "Cassia Regional Medical Center" },
    P { name: "Minidoka Memorial Hospital", cat: Some("hospital"), kind: "amenity=hospital", kid: "hospital", lat: 42.6140, lon: -113.6720, street: Some("1224 8th St"), locality: "Rupert", phone: None, hours: None, alt: "" },
    P { name: "St. Luke's Boise Medical Center", cat: Some("hospital"), kind: "amenity=hospital", kid: "hospital", lat: 43.6126, lon: -116.1901, street: Some("190 E Bannock St"), locality: "Boise", phone: Some("+1 208 381 2222"), hours: None, alt: "" },
    P { name: "Saint Alphonsus Regional Medical Center", cat: Some("hospital"), kind: "amenity=hospital", kid: "hospital", lat: 43.6191, lon: -116.2791, street: Some("1055 N Curtis Rd"), locality: "Boise", phone: Some("+1 208 367 2121"), hours: None, alt: "" },
    P { name: "Saint Alphonsus Regional Medical Center", cat: Some("emergency_room"), kind: "emergency_department", kid: "emergency_room", lat: 43.6190, lon: -116.2790, street: Some("1055 N Curtis Rd"), locality: "Boise", phone: Some("+1 208 367 2121"), hours: Some("24/7"), alt: "" },
    P { name: "St. Luke's Boise Medical Center", cat: Some("emergency_room"), kind: "emergency_department", kid: "emergency_room", lat: 43.6125, lon: -116.1900, street: Some("190 E Bannock St"), locality: "Boise", phone: Some("+1 208 381 2222"), hours: Some("24/7"), alt: "St Lukes Boise" },
    P { name: "St. Luke's Magic Valley Regional Medical Center", cat: Some("hospital"), kind: "amenity=hospital", kid: "hospital", lat: 42.5530, lon: -114.4690, street: Some("801 Pole Line Rd W"), locality: "Twin Falls", phone: Some("+1 208 814 1000"), hours: None, alt: "" },
    P { name: "St. Luke's Magic Valley Regional Medical Center", cat: Some("emergency_room"), kind: "emergency_department", kid: "emergency_room", lat: 42.5531, lon: -114.4691, street: Some("801 Pole Line Rd W"), locality: "Twin Falls", phone: Some("+1 208 814 1000"), hours: Some("24/7"), alt: "" },
    P { name: "Heyburn Hospital", cat: Some("hospital"), kind: "amenity=hospital", kid: "hospital", lat: 42.5585, lon: -113.7691, street: None, locality: "Heyburn", phone: None, hours: None, alt: "" },
    P { name: "Chevron", cat: Some("fuel"), kind: "amenity=fuel", kid: "fuel", lat: 42.5400, lon: -113.7900, street: Some("1020 Overland Ave"), locality: "Burley", phone: None, hours: Some("24/7"), alt: "" },
    P { name: "Stanley Ranger Station", cat: Some("police"), kind: "amenity=police", kid: "police", lat: 44.2160, lon: -114.9310, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
    P { name: "Sawtooth Spring", cat: Some("water"), kind: "natural=spring", kid: "spring", lat: 44.1700, lon: -114.9200, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
    P { name: "Burley Elementary School", cat: None, kind: "amenity=school", kid: "school", lat: 42.5350, lon: -113.7930, street: Some("200 W 10th St"), locality: "Burley", phone: None, hours: None, alt: "" },
    P { name: "Burley", cat: None, kind: "shop=convenience", kid: "convenience", lat: 42.5310, lon: -113.8000, street: None, locality: "Burley", phone: None, hours: None, alt: "" },
    P { name: "Amonara", cat: None, kind: "shop=gift", kid: "gift_shop", lat: 43.3700, lon: -112.1200, street: None, locality: "Shelley", phone: None, hours: None, alt: "" },
    P { name: "Ammin", cat: None, kind: "shop=convenience", kid: "convenience", lat: 43.4700, lon: -111.9700, street: None, locality: "Ammon", phone: None, hours: None, alt: "" },
    P { name: "Stanley Lake", cat: None, kind: "natural=water", kid: "water_body", lat: 44.2400, lon: -115.0000, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
    // Unnamed places (OSM has many): the tools must call them by their kind, never by a bare "Water" or "Shelter".
    P { name: "", cat: Some("water"), kind: "amenity=drinking_water", kid: "drinking_water", lat: 44.2190, lon: -114.9340, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
    P { name: "", cat: Some("water"), kind: "natural=spring", kid: "spring", lat: 44.2300, lon: -114.9500, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
    P { name: "", cat: Some("water"), kind: "man_made=water_well", kid: "water_well", lat: 44.2250, lon: -114.9400, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
    P { name: "", cat: Some("shelter"), kind: "amenity=shelter", kid: "picnic_shelter", lat: 44.2200, lon: -114.9330, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
    P { name: "Redfish Lake Emergency Shelter", cat: Some("shelter"), kind: "amenity=shelter", kid: "emergency_shelter", lat: 44.1400, lon: -114.9000, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
    P { name: "Marsh Creek Cabin", cat: Some("shelter"), kind: "tourism=wilderness_hut", kid: "wilderness_hut", lat: 44.3000, lon: -114.8000, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
    // A lake named for water: a drinking water search must not return it.
    P { name: "Water Hole Lake", cat: None, kind: "natural=water", kid: "water_body", lat: 44.2205, lon: -114.9345, street: None, locality: "Stanley", phone: None, hours: None, alt: "" },
];

// (id, title, description)
const CATEGORIES: &[(&str, &str, &str)] = &[
    ("emergency_room", "Emergency room", "hospital emergency rooms; for a hospital in an emergency use emergency_room"),
    ("hospital", "Hospital", "hospitals, for information or a non-emergency visit"),
    ("urgent_care", "Urgent care", "walk-in urgent care clinics"),
    ("pharmacy", "Pharmacy", "pharmacies and drug stores"),
    ("fuel", "Fuel", "gas stations"),
    ("police", "Police", "police stations"),
    ("water", "Water", "drinking water, water points, wells and springs; a result's kind says which"),
    ("shelter", "Shelter", "public shelters, huts and cabins open to travellers; a result's kind says what it is"),
];

// (id, label, description, category)
#[rustfmt::skip]
const KINDS: &[(&str, &str, &str, Option<&str>)] = &[
    ("emergency_room", "Emergency room", "a hospital emergency room or emergency department", Some("emergency_room")),
    ("hospital", "Hospital", "a hospital", Some("hospital")),
    ("pharmacy", "Pharmacy", "a pharmacy or drug store", Some("pharmacy")),
    ("fuel", "Gas station", "a gas station selling vehicle fuel", Some("fuel")),
    ("police", "Police station", "a police station", Some("police")),
    ("drinking_water", "Drinking water tap", "a tap, fountain or pump that the map data marks as drinking water", Some("water")),
    ("spring", "Spring", "a natural spring, untreated unless the map data says it is drinking water", Some("water")),
    ("water_well", "Water well", "a well that the map data marks as drinking water", Some("water")),
    ("emergency_shelter", "Emergency shelter", "a shelter built for emergencies, such as a storm or bomb shelter", Some("shelter")),
    ("picnic_shelter", "Picnic shelter", "a roofed, open-sided shelter over picnic tables in a park or campground, not a place to stay overnight", Some("shelter")),
    ("wilderness_hut", "Backcountry hut", "a wilderness or alpine hut or cabin for travellers", Some("shelter")),
    ("water_body", "Lake or other water body", "a lake, pond, reservoir or river; not a drinking water source", None),
    ("school", "School", "", None),
    ("convenience", "Convenience", "", None),
    ("gift_shop", "Gift shop", "", None),
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
    for (i, (id, title, desc)) in CATEGORIES.iter().enumerate() {
        let n = PLACES.iter().filter(|p| p.cat == Some(*id)).count();
        c.execute(
            "INSERT INTO categories(id, title, description, rules, place_count, sort) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![id, title, desc, if *id == "emergency_room" { ER_RULES } else { "[]" }, n as i64, i as i64],
        )
        .unwrap();
    }
    for (i, (id, label, desc, cat)) in KINDS.iter().enumerate() {
        let n = PLACES.iter().filter(|p| p.kid == *id).count();
        c.execute(
            "INSERT INTO kinds(id, label, description, category, rules, place_count, sort) VALUES (?1, ?2, ?3, ?4, '[]', ?5, ?6)",
            params![id, label, desc, cat, n as i64, i as i64],
        )
        .unwrap();
    }
    c.execute("INSERT INTO states(code, name, country) VALUES ('ID', 'Idaho', 'US'), ('ND', 'North Dakota', 'US')", []).unwrap();
    for (i, p) in PLACES.iter().enumerate() {
        let id = i as i64 + 1;
        c.execute(
            "INSERT INTO places(id, name, category, kind, kind_id, lat, lon, street, locality, state, country, phone, hours, source, source_id, confidence) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, 'ID', 'US', ?10, ?11, 'osm', ?12, 0.9)",
            params![id, (!p.name.is_empty()).then_some(p.name), p.cat, p.kind, p.kid, p.lat, p.lon, p.street, p.locality, p.phone, p.hours, format!("osm:n{id}")],
        )
        .unwrap();
        c.execute("INSERT INTO places_rt(id, min_lat, max_lat, min_lon, max_lon) VALUES (?1, ?2, ?2, ?3, ?3)", params![id, p.lat, p.lon]).unwrap();
        if !p.name.is_empty() {
            c.execute("INSERT INTO places_fts(rowid, name, alt_names) VALUES (?1, ?2, ?3)", params![id, p.name, p.alt]).unwrap();
        }
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

/// The same fixture as a format 1 pack, the layout before places had kinds: no `kinds` table, no `kind_id` column. A reader
/// must still open it, with every place's kind unknown.
pub fn write_fixture_pack_v1(path: &Path) {
    write_fixture_pack(path);
    let c = Connection::open(path).expect("open fixture pack");
    c.execute_batch("DROP TABLE kinds; ALTER TABLE places DROP COLUMN kind_id; UPDATE meta SET value = '1' WHERE key = 'format_version';").expect("downgrade to format 1");
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

// (place name, wikipedia_title, summary)
const PLACE_SUMMARIES: &[(&str, &str, &str)] = &[
    ("Sawtooth Spring", "Sawtooth Spring", "A cold natural spring where hikers and campers fill their water bottles and refill drinking water."),
    ("Stanley Lake", "Stanley Lake", "A large alpine lake beneath the Sawtooth Mountains, popular for camping and kayaking."),
];
// Stanley, Idaho: (state, wikipedia_title, summary)
const TOWN_SUMMARY: (&str, &str, &str) =
    ("ID", "Stanley, Idaho", "A small mountain town in the Sawtooth Valley of Custer County, Idaho, at the foot of the Sawtooth Range.");

/// Summaries for a few fixture rows (a place and a town), the way the wiki step fills them.
pub fn add_fixture_summaries(path: &Path) {
    let c = Connection::open(path).expect("open fixture pack");
    for (name, wp, text) in PLACE_SUMMARIES {
        c.execute("UPDATE places SET summary = ?2, wikipedia_title = ?3 WHERE name = ?1", params![name, text, wp]).unwrap();
    }
    let (state, wp, text) = TOWN_SUMMARY;
    c.execute("UPDATE localities SET summary = ?1, wikipedia_title = ?2 WHERE name = 'Stanley' AND state = ?3", params![text, wp, state]).unwrap();
}

/// The fixture pack with summaries and with vectors from `fake_embed`.
pub fn write_fixture_pack_with_vectors(path: &Path) {
    write_fixture_pack(path);
    add_fixture_summaries(path);
    crate::embedpack::embed_pack(path, FAKE_MODEL, "none", &mut |t| Ok(fake_embed(t)), &mut |_| {}).expect("embed the fixture");
}

// --- Places tiles (docs/PLACES-TILES.md): the same data cut on the level 1 grid, as the server publishes it ---------------

/// The build name the fixture's tiles and common file carry.
pub const FIXTURE_BUILD: &str = "na-places-2026-10-13";

/// The fixture's streets with house numbers: (street as the source writes it, the expanded form or None, locality,
/// postcode, house numbers with their points). Overland Ave and W 10th St are in Burley's tile; Baseline Rd is cut by the
/// tile edge at 113 degrees west, so half of it is in each of two tiles (a street a reader has to join).
fn streets() -> Vec<(&'static str, Option<&'static str>, &'static str, &'static str, Vec<(String, f64, f64)>)> {
    // Overland Ave runs north-south: even numbers on the west side every 10, odd on the east, plus the Walgreens door
    // (1414, an exact match) and a lettered number. 1414 is the only even number between 1410 and 1420.
    let mut overland: Vec<(String, f64, f64)> = Vec::new();
    for n in (1000..=1500).step_by(10) {
        let lat = 42.5300 + (n - 1000) as f64 / 500.0 * 0.0200;
        overland.push((n.to_string(), lat, -113.7872));
        overland.push(((n + 5).to_string(), lat + 0.0001, -113.7868));
    }
    overland.push(("1414".into(), 42.5390, -113.7870));
    overland.push(("1420A".into(), 42.5394, -113.7873));
    let tenth: Vec<(String, f64, f64)> = (100..=300).step_by(20).map(|n| (n.to_string(), 42.5350, -113.7900 - (n - 100) as f64 / 200.0 * 0.0060)).collect();
    let baseline: Vec<(String, f64, f64)> = (2000..=2100).step_by(10).map(|n| (n.to_string(), 42.6000, -113.0100 + (n - 2000) as f64 / 100.0 * 0.0200)).collect();
    vec![
        ("Overland Ave", Some("Overland Avenue"), "Burley", "83318", overland),
        ("W 10TH ST", Some("WEST 10TH STREET"), "Burley", "83318", tenth),
        ("Baseline Rd", Some("Baseline Road"), "Burley", "83318", baseline),
    ]
}

/// The level 1 tiles that hold any of the fixture's places, towns or house numbers, in id order.
pub fn fixture_tiles() -> Vec<u32> {
    let mut t: Vec<u32> = PLACES.iter().map(|p| tile_id_l1(p.lat, p.lon)).chain(LOCALITIES.iter().map(|l| tile_id_l1(l.2, l.3))).collect();
    for (_, _, _, _, nums) in streets() {
        t.extend(nums.iter().map(|n| tile_id_l1(n.1, n.2)));
    }
    t.sort_unstable();
    t.dedup();
    t
}

/// A stand-in for "the street's group key": the fixture's uid is a 64-bit FNV-1a in hex (16 characters, like the
/// builder's sha256 prefix, but not that hash).
fn fixture_uid(key: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in key.bytes() {
        h = (h ^ b as u64).wrapping_mul(0x100000001b3);
    }
    format!("{h:016x}")
}

/// Distance from a point to a cell [west, south, east, north], km (0 inside it).
fn km_to_cell(lat: f64, lon: f64, r: [f64; 4]) -> f64 {
    crate::geo::haversine_km(lat, lon, lat.clamp(r[1], r[3]), lon.clamp(r[0], r[2]))
}

/// Writes the fixture's common file for `build` to `path` (replacing any file there): its categories, kinds and states,
/// and their vectors from `fake_embed` ("{title}: {description}"), with `embed_model` [`FAKE_MODEL`].
pub fn write_fixture_common(path: &Path, build: &str) {
    let _ = std::fs::remove_file(path);
    let c = Connection::open(path).expect("create fixture common file");
    c.execute_batch(COMMON_SQL).expect("common schema");
    for (k, v) in [
        ("tile_schema", TILE_SCHEMA.to_string()),
        ("build", build.into()),
        ("built_at", FIXTURE_BUILT_AT.into()),
        ("overture_release", "2026-09-17.0".into()),
        ("osm_source", "fixture".into()),
        ("sources", "Invented test data at real Idaho coordinates".into()),
        ("builder_rules", "{}".into()),
        ("attribution", "Test data".into()),
        ("embed_model", FAKE_MODEL.into()),
        ("embed_dims", "64".into()),
        ("embed_model_sha256", "none".into()),
        ("levels", "[1]".into()),
    ] {
        c.execute("INSERT INTO meta(key, value) VALUES (?1, ?2)", params![k, v]).unwrap();
    }
    for (i, (id, title, desc)) in CATEGORIES.iter().enumerate() {
        let rules = if *id == "emergency_room" { ER_RULES } else { "[]" };
        c.execute("INSERT INTO categories(id, title, description, rules, sort) VALUES (?1, ?2, ?3, ?4, ?5)", params![id, title, desc, rules, i as i64]).unwrap();
        c.execute("INSERT INTO vectors(kind, ref, vec) VALUES ('category', ?1, ?2)", params![id, pack_vector(&fake_embed(&format!("{title}: {desc}")))]).unwrap();
    }
    for (i, (id, label, desc, cat)) in KINDS.iter().enumerate() {
        c.execute("INSERT INTO kinds(id, label, description, category, rules, sort) VALUES (?1, ?2, ?3, ?4, '[]', ?5)", params![id, label, desc, cat, i as i64]).unwrap();
        c.execute("INSERT INTO vectors(kind, ref, vec) VALUES ('kind', ?1, ?2)", params![id, pack_vector(&fake_embed(&format!("{label}: {desc}")))]).unwrap();
    }
    c.execute("INSERT INTO states(code, name, country) VALUES ('ID', 'Idaho', 'US'), ('ND', 'North Dakota', 'US')", []).unwrap();
}

/// Writes the fixture's level 1 tile `tile` of `build` to `path`, uncompressed (replacing any file there): the places,
/// towns and house numbers whose points are in the cell, the towns outside it within 25 km (`localities_ctx`), vectors from
/// `fake_embed` for the rows that have a summary, and tile_counts. A tile with nothing in it is written empty. Row ids are
/// local (1, 2, ...); place and town source ids are the same as the fixture pack's, so the two can be compared.
pub fn write_fixture_shard(path: &Path, tile: u32, build: &str) {
    let _ = std::fs::remove_file(path);
    let c = Connection::open(path).expect("create fixture tile");
    c.execute_batch(TILE_SQL).expect("tile schema");
    let summary = |name: &str| PLACE_SUMMARIES.iter().find(|s| s.0 == name).map(|s| (s.1, s.2));
    let (mut n_places, mut n_towns, mut n_ctx, mut n_streets, mut n_numbers) = (0i64, 0i64, 0i64, 0i64, 0i64);
    let mut counts: std::collections::BTreeMap<(&str, &str), i64> = Default::default();
    for (i, p) in PLACES.iter().enumerate().filter(|(_, p)| tile_id_l1(p.lat, p.lon) == tile) {
        n_places += 1;
        let matched = (p.cat == Some("emergency_room"))
            .then(|| PLACES.iter().position(|q| q.cat == Some("hospital") && q.name == p.name).map(|h| format!("osm:n{}", h + 1)))
            .flatten();
        let (wp, text) = summary(p.name).unzip();
        c.execute(
            "INSERT INTO places(id, name, alt_names, category, kind, kind_id, lat, lon, street, locality, state, country, phone, hours, \
             wikipedia_title, summary, matched_source_id, source, source_id, confidence) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, 'ID', 'US', ?11, ?12, ?13, ?14, ?15, 'osm', ?16, 0.9)",
            params![
                n_places, (!p.name.is_empty()).then_some(p.name), (!p.alt.is_empty()).then_some(p.alt), p.cat, p.kind, p.kid, p.lat, p.lon,
                p.street, p.locality, p.phone, p.hours, wp, text, matched, format!("osm:n{}", i + 1)
            ],
        )
        .unwrap();
        if let Some(t) = text {
            c.execute("INSERT INTO vectors(kind, ref, vec) VALUES ('place', ?1, ?2)", params![n_places, pack_vector(&fake_embed(&format!("{}. {t}", p.name)))]).unwrap();
        }
        if let Some(cat) = p.cat {
            *counts.entry(("category", cat)).or_default() += 1;
        }
        *counts.entry(("kind", p.kid)).or_default() += 1;
    }
    let cell = tile_rect_l1(tile);
    for (i, (name, kind, lat, lon, pop, state)) in LOCALITIES.iter().enumerate() {
        let source_id = format!("osm:n9{}", i + 1);
        if tile_id_l1(*lat, *lon) == tile {
            n_towns += 1;
            let (wp, text) = (*name == "Stanley" && *state == TOWN_SUMMARY.0).then_some((TOWN_SUMMARY.1, TOWN_SUMMARY.2)).unzip();
            c.execute(
                "INSERT INTO localities(id, name, kind, lat, lon, population, state, country, wikipedia_title, summary, source_id) \
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'US', ?8, ?9, ?10)",
                params![n_towns, name, kind, lat, lon, pop, state, wp, text, source_id],
            )
            .unwrap();
            if let Some(t) = text {
                c.execute("INSERT INTO vectors(kind, ref, vec) VALUES ('locality', ?1, ?2)", params![n_towns, pack_vector(&fake_embed(&format!("{name}. {t}")))]).unwrap();
            }
        } else if *kind != "hamlet" && km_to_cell(*lat, *lon, cell) <= 25.0 {
            n_ctx += 1;
            c.execute(
                "INSERT INTO localities_ctx(id, name, kind, lat, lon, population, state, country, source_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, 'US', ?8)",
                params![n_ctx, name, kind, lat, lon, pop, state, source_id],
            )
            .unwrap();
        }
    }
    for (street, expanded, locality, postcode, nums) in streets() {
        let here: Vec<(String, f64, f64)> = nums.into_iter().filter(|n| tile_id_l1(n.1, n.2) == tile).collect();
        if here.is_empty() {
            continue;
        }
        n_streets += 1;
        let k = here.len() as f64;
        let (lat, lon) = (here.iter().map(|n| n.1).sum::<f64>() / k, here.iter().map(|n| n.2).sum::<f64>() / k);
        let mut b = [f64::MAX, f64::MIN, f64::MAX, f64::MIN];
        for (_, la, lo) in &here {
            b = [b[0].min(*la), b[1].max(*la), b[2].min(*lo), b[3].max(*lo)];
        }
        let blob = addr::encode(lat, lon, &here).expect("encode the fixture's numbers");
        let n = addr::decode(&blob, lat, lon).expect("decode the fixture's numbers").len() as i64;
        n_numbers += n;
        c.execute(
            "INSERT INTO addr_streets(id, uid, street, street_expanded, locality, postal_city, postcode, state, country, lat, lon, \
             min_lat, max_lat, min_lon, max_lon, n, numbers) VALUES (?1, ?2, ?3, ?4, ?5, ?5, ?6, 'ID', 'US', ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
            params![
                n_streets, fixture_uid(&format!("{}|{postcode}|{}|{tile}", street.to_lowercase(), locality.to_lowercase())), street, expanded,
                locality, postcode, lat, lon, b[0], b[1], b[2], b[3], n, blob
            ],
        )
        .unwrap();
    }
    for ((what, id), n) in &counts {
        c.execute("INSERT INTO tile_counts(what, id, n) VALUES (?1, ?2, ?3)", params![what, id, n]).unwrap();
    }
    let summary_json = serde_json::json!({"places": n_places, "localities": n_towns, "localities_ctx": n_ctx, "addr_streets": n_streets, "addresses": n_numbers});
    for (k, v) in [
        ("tile_schema", TILE_SCHEMA.to_string()),
        ("build", build.into()),
        ("tile", tile.to_string()),
        ("path", tile_path_l1(tile)),
        ("counts", summary_json.to_string()),
    ] {
        c.execute("INSERT INTO meta(key, value) VALUES (?1, ?2)", params![k, v]).unwrap();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_fixture_cuts_into_tiles() {
        let dir = std::env::temp_dir().join(format!("cache_places_fixture_shards_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let burley = tile_id_l1(42.5357, -113.7928);
        let east = burley + 1;
        let (boise, idaho_city) = (tile_id_l1(43.6150, -116.2023), tile_id_l1(43.8280, -115.8340));
        let tiles = fixture_tiles();
        for t in [burley, east, boise, idaho_city] {
            assert!(tiles.contains(&t), "{t}");
        }
        // Every place and town is in exactly one tile.
        let (mut places, mut towns) = (0i64, 0i64);
        for &t in &tiles {
            let p = dir.join(format!("{t}.sqlite"));
            write_fixture_shard(&p, t, FIXTURE_BUILD);
            let c = Connection::open(&p).unwrap();
            places += c.query_row("SELECT COUNT(*) FROM places", [], |r| r.get::<_, i64>(0)).unwrap();
            towns += c.query_row("SELECT COUNT(*) FROM localities", [], |r| r.get::<_, i64>(0)).unwrap();
            let meta = |k: &str| c.query_row("SELECT value FROM meta WHERE key = ?1", [k], |r| r.get::<_, String>(0)).unwrap();
            assert_eq!(meta("tile"), t.to_string());
            assert_eq!(meta("path"), tile_path_l1(t));
            assert_eq!(meta("tile_schema"), "1");
            assert_eq!(meta("build"), FIXTURE_BUILD);
        }
        assert_eq!((places, towns), (PLACES.len() as i64, LOCALITIES.len() as i64));

        let c = Connection::open(dir.join(format!("{burley}.sqlite"))).unwrap();
        let n = |sql: &str| c.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
        assert_eq!(n("SELECT n FROM tile_counts WHERE what = 'category' AND id = 'pharmacy'"), 3);
        assert_eq!(n("SELECT COUNT(*) FROM addr_streets"), 3);
        // Overland Ave: 51 even, 51 odd, 1414 and 1420A.
        let (blob, lat, lon): (Vec<u8>, f64, f64) =
            c.query_row("SELECT numbers, lat, lon FROM addr_streets WHERE street = 'Overland Ave'", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
        let nums = addr::decode(&blob, lat, lon).unwrap();
        assert_eq!(nums.len(), 104);
        let door = nums.iter().find(|e| e.number() == "1414").unwrap();
        assert!((door.lat - 42.5390).abs() < 1e-6 && (door.lon + 113.7870).abs() < 1e-6);
        // Baseline Rd is in both tiles, with different uids and numbers either side of 113 W.
        let e = Connection::open(dir.join(format!("{east}.sqlite"))).unwrap();
        let (eu, en): (String, i64) = e.query_row("SELECT uid, n FROM addr_streets WHERE street = 'Baseline Rd'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        let (wu, wn): (String, i64) = c.query_row("SELECT uid, n FROM addr_streets WHERE street = 'Baseline Rd'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
        assert!(eu != wu && en + wn == 11 && en > 0 && wn > 0, "{en} {wn}");
        // Idaho City is a context town of Boise's tile (about 13 km east of it), and the other way round.
        let ctx = |t: u32| -> (Connection, Vec<String>) {
            let c = Connection::open(dir.join(format!("{t}.sqlite"))).unwrap();
            let names = c.prepare("SELECT name FROM localities_ctx ORDER BY name").unwrap().query_map([], |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect();
            (c, names)
        };
        let (b, names) = ctx(boise);
        assert_eq!(names, ["Idaho City"]);
        let (ic, names) = ctx(idaho_city);
        assert!(names.contains(&"Boise".to_string()) && !names.contains(&"Lowman".to_string()), "{names:?}");
        // Stanley's tile carries the summaries' vectors.
        let s = Connection::open(dir.join(format!("{}.sqlite", tile_id_l1(44.2210, -114.9360)))).unwrap();
        assert_eq!(s.query_row("SELECT COUNT(*) FROM vectors", [], |r| r.get::<_, i64>(0)).unwrap(), 3);

        let common = dir.join("common.sqlite");
        write_fixture_common(&common, FIXTURE_BUILD);
        let m = Connection::open(&common).unwrap();
        assert_eq!(m.query_row("SELECT COUNT(*) FROM vectors", [], |r| r.get::<_, i64>(0)).unwrap(), (CATEGORIES.len() + KINDS.len()) as i64);
        drop((c, e, b, ic, s, m));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
