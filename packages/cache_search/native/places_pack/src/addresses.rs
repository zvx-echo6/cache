//! `places_pack addresses`: Overture addresses grouped into street rows (docs/PLACES-TILES.md, `addr_streets`), one street
//! within one level 1 tile per row, with every house number and its point in the `numbers` blob (`cache_places::addr`).
//!
//! The CSV comes from `scripts/overture_extract.py`, sorted by (tile, street, postcode, postal_city, id), so the step reads
//! one street (and postcode) at a time and memory stays at one street. A row is grouped by (street as written, postcode,
//! town): the town
//! is the address's postal_city (written as the town writes it when one of that name is within 30 km), else the
//! nearest city, town or village of the same state within 10 km. Units are dropped; a house number that appears more than
//! once in a row is kept once, with its first point (the CSV is in id order within a street). `street_expanded` is the
//! street with its USPS Publication 28 abbreviations written out (`usps`), or NULL when that changes nothing. Words the
//! source wrote in capitals in a street or postal city are stored with a capital first letter (`title_case_capitals`), and
//! so is the street suffix (`usps::suffix_in_title_case`).
//!
//! The output (`addresses.sqlite`) is `addr_streets` as the tiles have it, plus the tile, without ids: `cut` numbers the
//! rows of each tile.

use crate::admins::Admins;
use crate::blocks::{block_files, tiles_in};
use crate::build::{Geo, Towns};
use crate::model::{RawLocality, Wiki};
use cache_places::addr::{self, split_number};
use rusqlite::{params, Connection, OpenFlags};
use sha2::{Digest, Sha256};
use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};

pub const ADDRESSES_SQL: &str = r#"
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE addr_streets (
  tile INTEGER NOT NULL,
  uid TEXT NOT NULL,
  street TEXT NOT NULL,
  street_expanded TEXT,
  locality TEXT,
  postal_city TEXT,
  postcode TEXT,
  state TEXT,
  country TEXT,
  lat REAL NOT NULL,
  lon REAL NOT NULL,
  min_lat REAL NOT NULL,
  max_lat REAL NOT NULL,
  min_lon REAL NOT NULL,
  max_lon REAL NOT NULL,
  n INTEGER NOT NULL,
  numbers BLOB NOT NULL
);
"#;

pub struct AddressesCfg {
    pub csv: PathBuf,
    pub blocks: PathBuf,
    pub admins: PathBuf,
    pub out: PathBuf,
    pub bbox: Option<[f64; 4]>,
}

#[derive(Debug, Default)]
pub struct AddressesReport {
    /// Address records read (inside the selected tiles).
    pub read: usize,
    /// Street rows written, the house numbers in them, and the numbers dropped as repeats (units of one door).
    pub streets: usize,
    pub numbers: usize,
    pub repeats: usize,
    /// Rows whose street has a written-out form, and the rows whose town came from the nearest locality.
    pub expanded: usize,
    pub nearest_town: usize,
    pub skipped: usize,
    pub blob_bytes: usize,
}

/// The towns of every block, with their states, for the nearest-town rule.
pub fn load_towns(blocks: &Path) -> Result<Towns, String> {
    let (mut locs, mut geo) = (Vec::new(), Vec::new());
    for (_, p) in block_files(blocks)? {
        let c = Connection::open_with_flags(&p, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| format!("{}: {e}", p.display()))?;
        let mut st = c.prepare("SELECT name, kind, lat, lon, state, country, source_id FROM localities").map_err(|e| e.to_string())?;
        let rows = st
            .query_map([], |r| {
                Ok((
                    RawLocality { source_id: r.get(6)?, name: r.get(0)?, alt: vec![], kind: r.get(1)?, lat: r.get(2)?, lon: r.get(3)?, population: None, wiki: Wiki::default() },
                    Geo { state: r.get(4)?, country: r.get(5)?, locality: None },
                ))
            })
            .map_err(|e| e.to_string())?;
        for r in rows {
            let (l, g) = r.map_err(|e| e.to_string())?;
            locs.push(l);
            geo.push(g);
        }
    }
    Ok(Towns::new(locs, geo))
}

/// The row's stable id: the first 16 hex characters of sha256(street|postcode|town|tile), with runs of white space as one
/// space. The street is the source's, in its case: "Main St" and "MAIN ST" are two rows of the source, and two rows never
/// share a uid.
pub fn street_uid(street: &str, postcode: &str, locality: &str, tile: u32) -> String {
    let norm = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
    let h = Sha256::digest(format!("{}|{}|{}|{tile}", norm(street), postcode.trim(), norm(locality)).as_bytes());
    h.iter().take(8).map(|b| format!("{b:02x}")).collect()
}

/// The text with each word the source wrote in capitals given a capital first letter only ("North STATE Street" ->
/// "North State Street", "HURRICANE" -> "Hurricane"). Only words of 3 or more letters and nothing else are changed:
/// "US", "SR", "NE", "3H", "1300", "McKay" and everything from a word holding "#" on stay as they are. Words are split
/// on single spaces, so the rest of the text is unchanged byte for byte.
pub fn title_case_capitals(s: &str) -> String {
    let mut unit = false;
    let words: Vec<String> = s
        .split(' ')
        .map(|w| {
            unit |= w.contains('#');
            let capitals = w.chars().count() >= 3 && w.chars().all(|c| c.is_alphabetic() && c.is_uppercase());
            if unit || !capitals {
                return w.to_string();
            }
            let mut c = w.chars();
            c.next().map(|f| f.to_string() + &c.as_str().to_lowercase()).unwrap_or_default()
        })
        .collect();
    words.join(" ")
}

struct Point {
    number: String,
    postal_city: String,
    lat: f64,
    lon: f64,
    state: Option<String>,
    country: Option<String>,
}

/// One street and postcode of one tile, as read (one sort run of the CSV): its points are split by town and written.
struct Run {
    tile: u32,
    street: String,
    postcode: String,
    points: Vec<Point>,
}

fn write_run(c: &Connection, towns: &Towns, admins: &mut Admins, run: Run, rep: &mut AddressesReport) -> Result<(), String> {
    // Split by town, keeping the read order inside each town.
    let mut groups: Vec<(Option<String>, Vec<Point>)> = Vec::new();
    for mut p in run.points {
        if p.state.is_none() {
            let (st, country) = admins.locate(p.lat, p.lon);
            p.state = st.map(|s| s.0);
            if p.country.is_none() {
                p.country = country;
            }
        }
        let town = if p.postal_city.is_empty() {
            rep.nearest_town += 1;
            towns.nearest(p.lat, p.lon, &p.state)
        } else {
            Some(towns.named_near(&p.postal_city, p.lat, p.lon).unwrap_or_else(|| p.postal_city.clone()))
        };
        match groups.iter_mut().find(|g| g.0 == town) {
            Some(g) => g.1.push(p),
            None => groups.push((town, vec![p])),
        }
    }
    let street = crate::usps::suffix_in_title_case(&title_case_capitals(&run.street));
    let expanded = crate::usps::expand(&street);
    for (town, points) in groups {
        let mut seen: HashSet<(u32, String)> = HashSet::new();
        let mut nums: Vec<(&str, f64, f64)> = Vec::with_capacity(points.len());
        for p in &points {
            let (num, suffix) = split_number(&p.number);
            if suffix.len() > u8::MAX as usize {
                rep.skipped += 1;
                continue;
            }
            if seen.insert((num, suffix.to_string())) {
                nums.push((p.number.as_str(), p.lat, p.lon));
            } else {
                rep.repeats += 1;
            }
        }
        if nums.is_empty() {
            continue;
        }
        let k = nums.len() as f64;
        let (lat, lon) = (nums.iter().map(|n| n.1).sum::<f64>() / k, nums.iter().map(|n| n.2).sum::<f64>() / k);
        let mut b = [f64::MAX, f64::MIN, f64::MAX, f64::MIN];
        for (_, la, lo) in &nums {
            b = [b[0].min(*la), b[1].max(*la), b[2].min(*lo), b[3].max(*lo)];
        }
        let blob = addr::encode(lat, lon, &nums)?;
        let locality = town.clone().unwrap_or_default();
        let first = &points[0];
        c.execute(
            "INSERT INTO addr_streets(tile, uid, street, street_expanded, locality, postal_city, postcode, state, country, lat, lon, \
             min_lat, max_lat, min_lon, max_lon, n, numbers) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17)",
            params![
                run.tile,
                street_uid(&run.street, &run.postcode, &locality, run.tile),
                street,
                expanded,
                town,
                (!first.postal_city.is_empty()).then_some(&first.postal_city),
                (!run.postcode.is_empty()).then_some(&run.postcode),
                first.state,
                first.country,
                lat,
                lon,
                b[0],
                b[1],
                b[2],
                b[3],
                nums.len() as i64,
                blob
            ],
        )
        .map_err(|e| e.to_string())?;
        rep.streets += 1;
        rep.numbers += nums.len();
        rep.blob_bytes += blob.len();
        if expanded.is_some() {
            rep.expanded += 1;
        }
    }
    Ok(())
}

pub fn addresses(cfg: &AddressesCfg) -> Result<AddressesReport, String> {
    let towns = load_towns(&cfg.blocks)?;
    let mut admins = Admins::load(&cfg.admins)?;
    let selected: Option<BTreeSet<u32>> = cfg.bbox.map(tiles_in);
    let _ = std::fs::remove_file(&cfg.out);
    let c = Connection::open(&cfg.out).map_err(|e| format!("{}: {e}", cfg.out.display()))?;
    c.execute_batch("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;").map_err(|e| e.to_string())?;
    c.execute_batch(ADDRESSES_SQL).map_err(|e| e.to_string())?;
    let mut rdr = csv::ReaderBuilder::new().from_path(&cfg.csv).map_err(|e| format!("{}: {e}", cfg.csv.display()))?;
    let head = rdr.headers().map_err(|e| e.to_string())?.clone();
    let col = |n: &str| head.iter().position(|h| h == n).ok_or_else(|| format!("addresses csv: column {n:?} is missing"));
    let (c_num, c_street, c_pc, c_city, c_state, c_country) = (col("number")?, col("street")?, col("postcode")?, col("postal_city")?, col("state")?, col("country")?);
    let (c_lat, c_lon, c_tile) = (col("lat")?, col("lon")?, col("tile")?);
    let mut rep = AddressesReport::default();
    let tx = c.unchecked_transaction().map_err(|e| e.to_string())?;
    let mut run: Option<Run> = None;
    let mut last_key: Option<(u32, String, String)> = None;
    for rec in rdr.records() {
        let rec = rec.map_err(|e| e.to_string())?;
        let get = |i: usize| rec.get(i).unwrap_or("").trim();
        let Ok(tile) = get(c_tile).parse::<u32>() else {
            rep.skipped += 1;
            continue;
        };
        if selected.as_ref().is_some_and(|s| !s.contains(&tile)) {
            continue;
        }
        let (Ok(lat), Ok(lon)) = (get(c_lat).parse::<f64>(), get(c_lon).parse::<f64>()) else {
            rep.skipped += 1;
            continue;
        };
        let (number, street) = (get(c_num), get(c_street));
        if number.is_empty() || street.is_empty() || !lat.is_finite() || !lon.is_finite() {
            rep.skipped += 1;
            continue;
        }
        rep.read += 1;
        let key = (tile, street.to_string(), get(c_pc).to_string());
        if last_key.as_ref() != Some(&key) {
            if let Some(r) = run.take() {
                write_run(&tx, &towns, &mut admins, r, &mut rep)?;
            }
            run = Some(Run { tile, street: key.1.clone(), postcode: key.2.clone(), points: Vec::new() });
            last_key = Some(key);
        }
        let opt = |s: &str| (!s.is_empty()).then(|| s.to_string());
        if let Some(r) = run.as_mut() {
            r.points.push(Point { number: number.to_string(), postal_city: title_case_capitals(get(c_city)), lat, lon, state: opt(get(c_state)), country: opt(get(c_country)) });
        }
    }
    if let Some(r) = run.take() {
        write_run(&tx, &towns, &mut admins, r, &mut rep)?;
    }
    tx.execute_batch("CREATE INDEX addr_streets_tile ON addr_streets(tile);").map_err(|e| e.to_string())?;
    for (k, v) in [("csv", cfg.csv.display().to_string()), ("streets", rep.streets.to_string()), ("numbers", rep.numbers.to_string())] {
        tx.execute("INSERT INTO meta(key, value) VALUES (?1, ?2)", params![k, v]).map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    Ok(rep)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn capitals_become_title_case() {
        assert_eq!(title_case_capitals("North STATE Street"), "North State Street");
        assert_eq!(title_case_capitals("HURRICANE"), "Hurricane");
        assert_eq!(title_case_capitals("MONUMENT VALLEY"), "Monument Valley");
        assert_eq!(title_case_capitals("S STATE ST"), "S State ST");
        assert_eq!(title_case_capitals("ÉCOLE"), "École");
        // Short words, numbers, mixed and lower case are left as they are.
        assert_eq!(title_case_capitals("US HWY 89 N"), "US Hwy 89 N");
        assert_eq!(title_case_capitals("SR 3H NE"), "SR 3H NE");
        assert_eq!(title_case_capitals("1300 East"), "1300 East");
        assert_eq!(title_case_capitals("McKAY Lane"), "McKAY Lane");
        assert_eq!(title_case_capitals("main street"), "main street");
        assert_eq!(title_case_capitals("O'NEIL AVE"), "O'NEIL Ave");
        // Nothing from a "#" on.
        assert_eq!(title_case_capitals("MAIN ST #APT B"), "Main ST #APT B");
        assert_eq!(title_case_capitals("MAIN ST # UNIT"), "Main ST # UNIT");
        // White space is kept byte for byte.
        assert_eq!(title_case_capitals(" NORTH  STATE "), " North  State ");
        assert_eq!(title_case_capitals(""), "");
    }

    #[test]
    fn street_and_expansion() {
        let both = |s: &str| {
            let street = crate::usps::suffix_in_title_case(&title_case_capitals(s));
            let expanded = crate::usps::expand(&street);
            (street, expanded)
        };
        assert_eq!(both("W MALBAR ST"), ("W Malbar St".into(), Some("West Malbar Street".into())));
        assert_eq!(both("North STATE Street"), ("North State Street".into(), None));
        assert_eq!(both("S STATE ST"), ("S State St".into(), Some("South State Street".into())));
        assert_eq!(both("MAIN ST NE"), ("Main St NE".into(), Some("Main Street Northeast".into())));
        // Mixed case from the source.
        assert_eq!(both("E Lochmeadow CT"), ("E Lochmeadow Ct".into(), Some("East Lochmeadow Court".into())));
        assert_eq!(both("West Glen Ellyn ln"), ("West Glen Ellyn Ln".into(), Some("West Glen Ellyn Lane".into())));
        assert_eq!(both("US HWY 89 N"), ("US Hwy 89 N".into(), Some("US Hwy 89 North".into())), "HWY is not in the suffix position");
    }
}
