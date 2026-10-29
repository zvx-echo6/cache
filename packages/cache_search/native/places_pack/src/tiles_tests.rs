//! The tiled build end to end on a small invented area across the level 0 block edge at 112 W (harvest rows, blocks,
//! addresses, cut, common), with a stand-in admins.sqlite.

use crate::addresses::{addresses, street_uid, AddressesCfg};
use crate::blocks::{block_of_tile, blocks, BlocksCfg};
use crate::common::{common, CommonCfg};
use crate::cut::{cut, CutCfg};
use crate::harvest::{write, HARVEST_SQL};
use crate::model::{Raw, RawLocality, Wiki};
use crate::rules::Rules;
use cache_places::addr;
use cache_places::schema::{tile_id_l1, tile_path_l1};
use rusqlite::Connection;
use sha2::{Digest, Sha256};
use std::io::Read;
use std::path::{Path, PathBuf};

const RULES: &str = include_str!("../categories.json");

/// A SpatiaLite POLYGON blob of a rectangle (what admins.sqlite holds).
fn rect_blob(w: f64, s: f64, e: f64, n: f64) -> Vec<u8> {
    let mut b = vec![0x00, 0x01];
    b.extend_from_slice(&4326i32.to_le_bytes());
    for v in [w, s, e, n] {
        b.extend_from_slice(&v.to_le_bytes());
    }
    b.push(0x7c);
    b.extend_from_slice(&3u32.to_le_bytes());
    b.extend_from_slice(&1u32.to_le_bytes());
    b.extend_from_slice(&5u32.to_le_bytes());
    for (x, y) in [(w, s), (e, s), (e, n), (w, n), (w, s)] {
        b.extend_from_slice(&x.to_le_bytes());
        b.extend_from_slice(&y.to_le_bytes());
    }
    b.push(0xfe);
    b
}

fn write_admins(p: &Path) {
    let _ = std::fs::remove_file(p);
    let c = Connection::open(p).unwrap();
    c.execute_batch("CREATE TABLE admins (admin_level INTEGER, iso_code TEXT, name TEXT, geom BLOB);").unwrap();
    c.execute("INSERT INTO admins VALUES (4, 'UT', 'Utah', ?1)", [rect_blob(-114.05, 37.0, -109.05, 42.0)]).unwrap();
    c.execute("INSERT INTO admins VALUES (4, 'NV', 'Nevada', ?1)", [rect_blob(-120.0, 35.0, -114.05, 42.0)]).unwrap();
}

fn place(source: &'static str, id: &str, name: &str, cat: Option<&str>, kind: &str, kind_id: &str, lat: f64, lon: f64) -> Raw {
    Raw {
        source,
        source_id: id.into(),
        name: Some(name.into()),
        alt: vec![],
        category: cat.map(String::from),
        kind: kind.into(),
        kind_id: Some(kind_id.into()),
        lat,
        lon,
        street: None,
        city: None,
        phone: None,
        hours: None,
        website: None,
        confidence: Some(0.95),
        wiki: Wiki::default(),
        brand_wikidata: None,
        enrich: None,
        matched: None,
    }
}

fn town(id: &str, name: &str, kind: &str, lat: f64, lon: f64) -> RawLocality {
    RawLocality { source_id: id.into(), name: name.into(), alt: vec![], kind: kind.into(), lat, lon, population: None, wiki: Wiki::default() }
}

fn gunzip(p: &Path) -> Vec<u8> {
    let mut out = Vec::new();
    flate2::read::GzDecoder::new(std::fs::File::open(p).unwrap()).read_to_end(&mut out).unwrap();
    out
}

#[test]
fn a_tiled_build_across_a_block_edge() {
    let dir: PathBuf = std::env::temp_dir().join(format!("places_pack_tiles_{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let rules = Rules::parse(RULES).unwrap();
    let admins = dir.join("admins.sqlite");
    write_admins(&admins);

    // The same Walgreens from both sources, 85 m apart on either side of 112 W (a block edge); a cafe east of the edge
    // whose nearest town is west of it; a hamlet; and a pharmacy in Nevada.
    let mut walgreens_osm = place("osm", "osm:n1", "Walgreens", Some("pharmacy"), "amenity=pharmacy", "pharmacy", 40.5, -111.9995);
    walgreens_osm.hours = Some("Mo-Su 08:00-22:00".into());
    let mut walgreens_ov = place("overture", "overture:a", "Walgreens", Some("pharmacy"), "pharmacy_and_drug_store", "pharmacy", 40.5, -112.0005);
    walgreens_ov.phone = Some("+1 801 555 0100".into());
    let cafe = place("overture", "overture:b", "Edge Cafe", None, "cafe", "cafe", 40.5, -111.98);
    let diner = place("overture", "overture:c", "Ruth's Diner", None, "casual_eatery", "diner", 40.51, -111.97);
    let nv = place("osm", "osm:n2", "Battle Mountain Pharmacy", Some("pharmacy"), "amenity=pharmacy", "pharmacy", 40.73, -116.5);
    let harvest = dir.join("harvest.sqlite");
    {
        let c = Connection::open(&harvest).unwrap();
        c.execute_batch(HARVEST_SQL).unwrap();
        write(
            &c,
            vec![walgreens_osm, walgreens_ov, cafe, diner, nv],
            vec![town("osm:n10", "Edgeville", "town", 40.5, -112.05), town("osm:n11", "Tiny", "hamlet", 40.52, -111.95), town("osm:n12", "Battle Mountain", "town", 40.64, -116.93)],
        )
        .unwrap();
        c.execute_batch("CREATE INDEX raw_tile ON raw(tile); INSERT INTO meta VALUES ('sources', 'test');").unwrap();
    }
    let blocks_dir = dir.join("blocks");
    let r = blocks(
        &BlocksCfg { harvest: harvest.clone(), admins: admins.clone(), out: blocks_dir.clone(), bbox: None, halo: 0.25, jobs: 2, country: "US".into() },
        &rules,
        RULES,
    )
    .unwrap();
    let east = tile_id_l1(40.5, -111.9995);
    let west = tile_id_l1(40.5, -112.0005);
    assert_ne!(block_of_tile(east), block_of_tile(west));
    assert_eq!(r.len(), 3, "the two blocks of the edge and Nevada's");
    // The Walgreens is written once, merged, by the block that holds the OSM point.
    let (mut walgreens, mut total) = (0, 0);
    for b in &r {
        let c = Connection::open(blocks_dir.join(format!("{}.sqlite", b.block))).unwrap();
        walgreens += c.query_row("SELECT COUNT(*) FROM places WHERE name = 'Walgreens'", [], |r| r.get::<_, i64>(0)).unwrap();
        total += c.query_row("SELECT COUNT(*) FROM places", [], |r| r.get::<_, i64>(0)).unwrap();
    }
    assert_eq!((walgreens, total), (1, 4));
    let e = Connection::open(blocks_dir.join(format!("{}.sqlite", block_of_tile(east)))).unwrap();
    let (src, phone, hours): (String, String, String) =
        e.query_row("SELECT source, phone, hours FROM places WHERE name = 'Walgreens'", [], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?))).unwrap();
    assert_eq!((src.as_str(), phone.as_str(), hours.as_str()), ("osm+overture", "+1 801 555 0100", "Mo-Su 08:00-22:00"));
    // The cafe's town is across the edge.
    let (loc, state): (String, String) = e.query_row("SELECT locality, state FROM places WHERE name = 'Edge Cafe'", [], |r| Ok((r.get(0)?, r.get(1)?))).unwrap();
    assert_eq!((loc.as_str(), state.as_str()), ("Edgeville", "UT"));
    assert_eq!(e.query_row("SELECT COUNT(*) FROM localities", [], |r| r.get::<_, i64>(0)).unwrap(), 1, "only Tiny is east of the edge");
    drop(e);

    // Addresses: a street with a repeated number (two units) and no postal city, a street whose postal city is the town
    // in capitals, and one in Nevada, in the order the extract sorts them.
    let csv = dir.join("addresses.csv");
    let t = tile_id_l1(40.5, -111.99);
    let nvt = tile_id_l1(40.73, -116.5);
    let mut lines = vec!["id,number,street,unit,postcode,postal_city,state,country,lat,lon,tile".to_string()];
    for (id, num, street, unit, pc, city, lat, lon) in [
        ("a1", "10", "MAIN ST", "", "84000", "EDGEVILLE", 40.501, -111.99),
        ("a2", "12", "MAIN ST", "", "84000", "EDGEVILLE", 40.501, -111.9898),
        ("a8", "16", "MAIN ST", "", "84000", "Edgeville", 40.501, -111.9896),
        ("a3", "12", "S STATE ST", "A", "84000", "", 40.5, -111.99),
        ("a4", "12", "S STATE ST", "B", "84000", "", 40.5001, -111.99),
        ("a5", "14A", "S STATE ST", "", "84000", "", 40.5002, -111.99),
        ("a6", "10", "S STATE ST", "", "84000", "", 40.4999, -111.99),
    ] {
        lines.push(format!("{id},{num},{street},{unit},{pc},{city},UT,US,{lat},{lon},{t}"));
    }
    lines.push(format!("a7,1,Front St,,89820,Battle Mountain,NV,US,40.73,-116.5,{nvt}"));
    std::fs::write(&csv, lines.join("\n") + "\n").unwrap();
    let addr_db = dir.join("addresses.sqlite");
    let ar = addresses(&AddressesCfg { csv, blocks: blocks_dir.clone(), admins, out: addr_db.clone(), bbox: Some([-113.0, 40.0, -111.0, 41.0]) }).unwrap();
    // "EDGEVILLE" and "Edgeville" are one town, so one row.
    assert_eq!((ar.read, ar.streets, ar.numbers, ar.repeats, ar.expanded), (7, 2, 6, 1, 2));

    let out = dir.join("out");
    let tiles = cut(&CutCfg { blocks: blocks_dir.clone(), addresses: Some(addr_db), out: out.clone(), build: "na-places-2026-10-28".into(), bbox: Some([-113.0, 40.0, -111.0, 41.0]), jobs: 2 })
        .unwrap();
    assert_eq!(tiles.iter().map(|t| t.tile).collect::<Vec<_>>(), [west, east], "Nevada is outside the box");
    let index = std::fs::read_to_string(out.join("na-places-2026-10-28/index.tsv")).unwrap();
    assert_eq!(index.lines().count(), 2);
    for (line, t) in index.lines().zip(&tiles) {
        let f: Vec<&str> = line.split('\t').collect();
        let raw = gunzip(&out.join(format!("na-places-2026-10-28/{}.sqlite.gz", f[0])));
        assert_eq!(f[0], tile_path_l1(t.tile));
        assert_eq!(f[1].parse::<usize>().unwrap(), raw.len());
        assert_eq!(f[2], Sha256::digest(&raw).iter().map(|b| format!("{b:02x}")).collect::<String>());
        assert_eq!(f[3].parse::<u64>().unwrap(), std::fs::metadata(out.join(format!("na-places-2026-10-28/{}.sqlite.gz", f[0]))).unwrap().len());
    }
    let open_tile = |tile: u32| {
        let p = dir.join(format!("{tile}.sqlite"));
        std::fs::write(&p, gunzip(&out.join(format!("na-places-2026-10-28/{}.sqlite.gz", tile_path_l1(tile))))).unwrap();
        Connection::open(p).unwrap()
    };
    let c = open_tile(east);
    let n = |c: &Connection, sql: &str| c.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap();
    assert_eq!(n(&c, "SELECT COUNT(*) FROM places"), 3);
    assert_eq!(n(&c, "SELECT MIN(id) FROM places"), 1);
    assert_eq!(n(&c, "SELECT n FROM tile_counts WHERE what = 'category' AND id = 'pharmacy'"), 1);
    assert_eq!(n(&c, "SELECT n FROM tile_counts WHERE what = 'kind' AND id = 'diner'"), 1);
    // Edgeville is a context town of the east tile (5 km west of its cell); the hamlet is not one of the west tile's.
    let ctx: Vec<String> = c.prepare("SELECT name FROM localities_ctx").unwrap().query_map([], |r| r.get(0)).unwrap().map(|r| r.unwrap()).collect();
    assert_eq!(ctx, ["Edgeville"]);
    let w = open_tile(west);
    assert_eq!(n(&w, "SELECT COUNT(*) FROM localities_ctx"), 0);
    assert_eq!(n(&w, "SELECT COUNT(*) FROM localities"), 1);
    let meta = |c: &Connection, k: &str| c.query_row("SELECT value FROM meta WHERE key = ?1", [k], |r| r.get::<_, String>(0)).unwrap();
    assert_eq!(meta(&c, "tile"), east.to_string());
    assert_eq!(meta(&c, "tile_schema"), "1");
    let counts: serde_json::Value = serde_json::from_str(&meta(&c, "counts")).unwrap();
    assert_eq!(counts, serde_json::json!({"places": 3, "localities": 1, "localities_ctx": 1, "addr_streets": 2, "addresses": 6}));
    // The street rows: the town by the nearest-town rule and by the postal city, the written-out form, the numbers.
    let row = |street: &str| -> (Option<String>, Option<String>, String, i64, Vec<u8>, f64, f64) {
        c.query_row("SELECT street_expanded, locality, uid, n, numbers, lat, lon FROM addr_streets WHERE street = ?1", [street], |r| {
            Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?))
        })
        .unwrap()
    };
    // Words in capitals are stored with a capital first letter; the uid is the source's street.
    let (exp, loc, uid, k, blob, lat, lon) = row("S State ST");
    assert_eq!((exp.as_deref(), loc.as_deref(), k), (Some("South State STREET"), Some("Edgeville"), 3));
    assert_eq!(uid, street_uid("S STATE ST", "84000", "Edgeville", t));
    let nums: Vec<String> = addr::decode(&blob, lat, lon).unwrap().iter().map(|e| e.number()).collect();
    assert_eq!(nums, ["10", "12", "14A"]);
    let twelve = addr::decode(&blob, lat, lon).unwrap().into_iter().find(|e| e.number() == "12").unwrap();
    assert!((twelve.lat - 40.5).abs() < 1e-6, "the first unit's point");
    let (exp, loc, _, k, _, _, _) = row("Main ST");
    assert_eq!((exp.as_deref(), loc.as_deref(), k), (Some("Main STREET"), Some("Edgeville"), 3));
    let city: String = c.query_row("SELECT postal_city FROM addr_streets WHERE street = 'Main ST'", [], |r| r.get(0)).unwrap();
    assert_eq!(city, "Edgeville", "EDGEVILLE in the source");

    // The common file: the rule kinds, then the derived kinds with a reviewed line or the data's own words.
    let tax = dir.join("taxonomy.tsv");
    std::fs::write(&tax, "category\tpath\ncafe\tfood_and_drink > casual_eatery > cafe\ndiner\tfood_and_drink > casual_eatery > diner\n").unwrap();
    let described = dir.join("kinds-described.tsv");
    std::fs::write(&described, "kind\tdescription\tmodel\tdate\ndiner\tA casual restaurant serving breakfast, lunch and dinner.\tclaude-haiku-5-5\t2026-10-28\n").unwrap();
    let cp = out.join("na-places-2026-10-28/common.sqlite");
    let cr = common(
        &CommonCfg {
            blocks: blocks_dir,
            out: cp.clone(),
            build: "na-places-2026-10-28".into(),
            taxonomy: Some(tax),
            described: Some(described),
            overture_release: "2026-10-21.0".into(),
            osm_source: "test".into(),
        },
        &rules,
        RULES,
    )
    .unwrap();
    assert_eq!((cr.described, cr.from_taxonomy, cr.states), (1, 1, 2));
    let m = Connection::open(&cp).unwrap();
    let desc = |id: &str| m.query_row("SELECT description FROM kinds WHERE id = ?1", [id], |r| r.get::<_, String>(0)).unwrap();
    assert_eq!(desc("diner"), "A casual restaurant serving breakfast, lunch and dinner.");
    assert_eq!(desc("cafe"), "Cafe (food and drink, casual eatery)");
    assert!(!desc("pharmacy").is_empty(), "a rule kind keeps the rules' description");
    assert_eq!(meta(&m, "tile_schema"), "1");
    assert_eq!(meta(&m, "levels"), "[1]");
    assert_eq!(n(&m, "SELECT COUNT(*) FROM categories"), rules.categories.len() as i64);
    drop((c, w, m));
    let _ = std::fs::remove_dir_all(&dir);
}

#[test]
fn harvest_rows_round_trip() {
    let mut p = place("osm", "osm:w9", "Burley High", None, "amenity=school", "school", 42.53, -113.79);
    p.alt = vec!["BHS".into()];
    p.enrich = Some(("hospital".into(), 250.0));
    let j = serde_json::to_string(&p).unwrap();
    let back: Raw = serde_json::from_str(&j).unwrap();
    assert_eq!((back.lat, back.lon, back.alt.clone(), back.enrich.clone()), (42.53, -113.79, vec!["BHS".to_string()], Some(("hospital".to_string(), 250.0))));
    assert_eq!(back.source, "", "the source is the harvest's column, not the JSON");
    assert_eq!(crate::model::source_name("osm+overture"), Some("osm+overture"));
    assert_eq!(crate::model::source_name("elsewhere"), None);
}
