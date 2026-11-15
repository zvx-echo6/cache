//! `places_pack oa-merge`: adds OpenAddresses (OA) street addresses to the Overture addresses CSV where the pack has none.
//!
//! The step sits between `scripts/overture_extract.py` and `places_pack addresses`: it reads `overture_addresses.csv` and
//! OA's line-delimited GeoJSON (`output.geojson`, optionally gzipped; properties `hash`, `number`, `street`, `unit`, `city`,
//! `district`, `region`, `postcode`, `id`), and writes the same CSV with one more column, `source`, empty for Overture rows
//! and `oa:<source>` (for example `oa:us/id/canyon`) for OA rows. The `addresses` step carries it into the street rows.
//!
//! An OA address is added only when the pack has no address for it. It counts as already there when, in its level 1 tile:
//!   1. an address has the same normalised street and number and lies within `--dist` metres (default 30), or
//!   2. an address has the same normalised street and number and the same normalised town (a town written one way by
//!      one source and another way by the other is why distance is the first test), or
//!   3. an address has the same number within 5 m, whatever the street says (the two sources spell the street differently).
//! An OA address that is added joins the index at once, so a later OA source (listed lower in the manifest) cannot add
//! it again: put county sources before the statewide one. Units are dropped, as in `addresses`.
//!
//! The manifest (`--sources`, TSV with a header) lists the OA sources in priority order:
//! `source<TAB>path<TAB>license<TAB>license_url<TAB>attribution<TAB>website`. Outputs: the merged CSV, a provenance TSV
//! (one line per added address with its OA id, `oa:<source>:<hash>`, not shipped) and an attribution JSON (per source: licence,
//! attribution name, rows read and added) that `common --oa-attribution` writes into the build's meta.

use crate::addresses::title_case_capitals;
use cache_places::schema::tile_id_l1;
use flate2::read::GzDecoder;
use std::collections::{BTreeMap, HashMap};
use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Write};
use std::path::{Path, PathBuf};

/// Within this many metres, the same street and number is the same address.
pub const DEFAULT_DIST_M: f64 = 30.0;
/// Within this many metres, the same number is the same address whatever the street says.
pub const SAME_NUMBER_M: f64 = 5.0;

#[derive(Debug, Clone, Default)]
pub struct Addr {
    pub id: String,
    pub number: String,
    pub street: String,
    pub unit: String,
    pub postcode: String,
    pub city: String,
    pub state: String,
    pub country: String,
    pub lat: f64,
    pub lon: f64,
    /// The coordinates as the Overture CSV wrote them (kept byte for byte); empty for OA rows.
    pub lat_s: String,
    pub lon_s: String,
    /// "" for Overture, "oa:us/id/canyon" for OA.
    pub source: String,
}

#[derive(Debug, Clone)]
pub struct OaSource {
    pub id: String,
    pub path: PathBuf,
    pub license: String,
    pub license_url: String,
    pub attribution: String,
    pub website: String,
}

#[derive(Debug, Default, Clone)]
pub struct SourceStats {
    pub read: usize,
    pub skipped: usize,
    pub added: usize,
    pub dup_near: usize,
    pub dup_town: usize,
    pub dup_number: usize,
}

pub fn norm_street(s: &str) -> String {
    let collapsed = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let x = crate::usps::suffix_in_title_case(&title_case_capitals(&collapsed));
    let e = crate::usps::expand(&x).unwrap_or(x);
    e.to_lowercase().chars().filter(|c| !matches!(c, '.' | ',')).collect()
}

pub fn norm_town(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

pub fn norm_number(s: &str) -> String {
    s.chars().filter(|c| !c.is_whitespace()).flat_map(char::to_uppercase).collect()
}

/// Metres between two points (equirectangular: exact enough under a kilometre).
pub fn dist_m(la1: f64, lo1: f64, la2: f64, lo2: f64) -> f64 {
    let dy = (la2 - la1) * 111_320.0;
    let dx = (lo2 - lo1) * 111_320.0 * ((la1 + la2) / 2.0).to_radians().cos();
    (dx * dx + dy * dy).sqrt()
}

const CELL: f64 = 0.0001; // about 11 m

/// What a tile already has, for the duplicate tests.
#[derive(Default)]
pub struct Index {
    by_street_number: HashMap<(String, String), Vec<(f64, f64, String)>>,
    by_cell: HashMap<(String, i64, i64), Vec<(f64, f64)>>,
}

fn cell(v: f64) -> i64 {
    (v / CELL).floor() as i64
}

impl Index {
    pub fn add(&mut self, a: &Addr) {
        let num = norm_number(&a.number);
        self.by_street_number.entry((norm_street(&a.street), num.clone())).or_default().push((a.lat, a.lon, norm_town(&a.city)));
        self.by_cell.entry((num, cell(a.lat), cell(a.lon))).or_default().push((a.lat, a.lon));
    }

    /// Why the address is already there: "near", "town" or "number", or None.
    pub fn duplicate(&self, a: &Addr, max_m: f64) -> Option<&'static str> {
        let num = norm_number(&a.number);
        let town = norm_town(&a.city);
        if let Some(v) = self.by_street_number.get(&(norm_street(&a.street), num.clone())) {
            if v.iter().any(|p| dist_m(a.lat, a.lon, p.0, p.1) <= max_m) {
                return Some("near");
            }
            if !town.is_empty() && v.iter().any(|p| p.2 == town) {
                return Some("town");
            }
        }
        for dy in -1..=1 {
            for dx in -1..=1 {
                if let Some(v) = self.by_cell.get(&(num.clone(), cell(a.lat) + dy, cell(a.lon) + dx)) {
                    if v.iter().any(|p| dist_m(a.lat, a.lon, p.0, p.1) <= SAME_NUMBER_M) {
                        return Some("number");
                    }
                }
            }
        }
        None
    }
}

/// Adds the OA rows of one tile that the tile does not have. `existing` is the tile's rows (Overture, and OA rows added
/// by an earlier call for the same tile); the rows added are appended to it and returned by count in `stats`.
pub fn merge_tile(existing: &mut Vec<Addr>, oa: Vec<Addr>, max_m: f64, stats: &mut BTreeMap<String, SourceStats>) -> Vec<Addr> {
    let mut idx = Index::default();
    for a in existing.iter() {
        idx.add(a);
    }
    let mut added = Vec::new();
    for a in oa {
        let st = stats.entry(a.source.clone()).or_default();
        match idx.duplicate(&a, max_m) {
            Some("near") => st.dup_near += 1,
            Some("town") => st.dup_town += 1,
            Some(_) => st.dup_number += 1,
            None => {
                st.added += 1;
                idx.add(&a);
                added.push(a);
            }
        }
    }
    existing.extend(added.iter().cloned());
    added
}

/// One OA GeoJSON line as an address (None for anything that is not a usable point with a number and a street).
pub fn parse_oa_line(line: &str, source: &str, country: &str) -> Option<Addr> {
    let v: serde_json::Value = serde_json::from_str(line).ok()?;
    let p = v.get("properties")?;
    let s = |k: &str| p.get(k).and_then(|x| x.as_str().map(str::to_string).or_else(|| x.as_i64().map(|n| n.to_string()))).unwrap_or_default().trim().to_string();
    let g = v.get("geometry")?;
    if g.get("type")?.as_str()? != "Point" {
        return None;
    }
    let c = g.get("coordinates")?.as_array()?;
    let (lon, lat) = (c.first()?.as_f64()?, c.get(1)?.as_f64()?);
    if !lat.is_finite() || !lon.is_finite() || !(-90.0..=90.0).contains(&lat) || !(-180.0..=180.0).contains(&lon) || (lat == 0.0 && lon == 0.0) {
        return None;
    }
    let number = s("number");
    let street = s("street").split_whitespace().collect::<Vec<_>>().join(" ");
    if number.is_empty() || street.is_empty() {
        return None;
    }
    let hash = {
        let h = s("hash");
        if h.is_empty() { s("id") } else { h }
    };
    Some(Addr {
        id: format!("oa:{source}:{hash}"),
        number,
        street,
        unit: String::new(),
        postcode: s("postcode"),
        city: s("city"),
        state: s("region"),
        country: country.to_string(),
        lat,
        lon,
        lat_s: String::new(),
        lon_s: String::new(),
        source: format!("oa:{source}"),
    })
}

fn open_lines(path: &Path) -> Result<Box<dyn BufRead>, String> {
    let f = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if path.extension().is_some_and(|e| e == "gz") {
        Ok(Box::new(BufReader::new(GzDecoder::new(f))))
    } else {
        Ok(Box::new(BufReader::new(f)))
    }
}

pub fn read_manifest(path: &Path) -> Result<Vec<OaSource>, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let base = path.parent().unwrap_or(Path::new("."));
    let mut out = Vec::new();
    for (i, line) in text.lines().enumerate().skip(1) {
        if line.trim().is_empty() || line.starts_with('#') {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 2 || f[0].trim().is_empty() || f[1].trim().is_empty() {
            return Err(format!("{}: line {}: needs source and path", path.display(), i + 1));
        }
        let get = |k: usize| f.get(k).map(|s| s.trim().to_string()).unwrap_or_default();
        let p = PathBuf::from(f[1].trim());
        out.push(OaSource { id: f[0].trim().to_string(), path: if p.is_absolute() { p } else { base.join(p) }, license: get(2), license_url: get(3), attribution: get(4), website: get(5) });
    }
    if out.is_empty() {
        return Err(format!("{}: no sources", path.display()));
    }
    Ok(out)
}

pub struct OaCfg {
    pub overture_csv: PathBuf,
    pub sources: PathBuf,
    pub out: PathBuf,
    pub provenance: PathBuf,
    pub attribution: PathBuf,
    pub dist_m: f64,
    pub bbox: Option<[f64; 4]>,
}

#[derive(Debug, Default)]
pub struct OaReport {
    pub overture_rows: usize,
    pub per_source: BTreeMap<String, SourceStats>,
    pub tiles_with_additions: usize,
}

const HEADER: [&str; 12] = ["id", "number", "street", "unit", "postcode", "postal_city", "state", "country", "lat", "lon", "tile", "source"];

fn write_row(w: &mut csv::Writer<BufWriter<File>>, a: &Addr, tile: u32) -> Result<(), String> {
    let (la, lo) = if a.lat_s.is_empty() { (format!("{:.7}", a.lat), format!("{:.7}", a.lon)) } else { (a.lat_s.clone(), a.lon_s.clone()) };
    w.write_record([&a.id, &a.number, &a.street, &a.unit, &a.postcode, &a.city, &a.state, &a.country, &la, &lo, &tile.to_string(), &a.source]).map_err(|e| e.to_string())
}

/// The rows of a tile in the order `addresses` reads them: (street, postcode, postal city, id).
fn sort_tile(rows: &mut [Addr]) {
    rows.sort_by(|a, b| (&a.street, &a.postcode, &a.city, &a.id).cmp(&(&b.street, &b.postcode, &b.city, &b.id)));
}

type Out = csv::Writer<BufWriter<File>>;

/// Merges the OA rows of `tile` into its rows, and writes the tile.
fn flush_tile(oa: &mut BTreeMap<u32, Vec<Addr>>, max_m: f64, tile: u32, mut rows: Vec<Addr>, rep: &mut OaReport, w: &mut Out, prov: &mut BufWriter<File>) -> Result<(), String> {
    if let Some(o) = oa.remove(&tile) {
        let added = merge_tile(&mut rows, o, max_m, &mut rep.per_source);
        if !added.is_empty() {
            rep.tiles_with_additions += 1;
        }
        for a in &added {
            writeln!(prov, "{}\t{}\t{}\t{}\t{:.7}\t{:.7}", a.id, tile, a.number, a.street, a.lat, a.lon).map_err(|e| e.to_string())?;
        }
    }
    sort_tile(&mut rows);
    for a in &rows {
        write_row(w, a, tile)?;
    }
    Ok(())
}

pub fn oa_merge(cfg: &OaCfg) -> Result<OaReport, String> {
    let sources = read_manifest(&cfg.sources)?;
    // Every OA row of the run, by tile, in manifest order.
    let mut oa: BTreeMap<u32, Vec<Addr>> = BTreeMap::new();
    let mut rep = OaReport::default();
    for src in &sources {
        let st = rep.per_source.entry(format!("oa:{}", src.id)).or_default();
        let country = src.id.split('/').next().unwrap_or("").to_uppercase();
        for line in open_lines(&src.path)?.lines() {
            let line = line.map_err(|e| format!("{}: {e}", src.path.display()))?;
            if line.trim().is_empty() {
                continue;
            }
            match parse_oa_line(&line, &src.id, &country) {
                Some(a) if cfg.bbox.map_or(true, |b| a.lon >= b[0] && a.lat >= b[1] && a.lon < b[2] && a.lat < b[3]) => {
                    st.read += 1;
                    oa.entry(tile_id_l1(a.lat, a.lon)).or_default().push(a);
                }
                Some(_) => {}
                None => st.skipped += 1,
            }
        }
    }
    let mut rdr = csv::ReaderBuilder::new().from_path(&cfg.overture_csv).map_err(|e| format!("{}: {e}", cfg.overture_csv.display()))?;
    let head = rdr.headers().map_err(|e| e.to_string())?.clone();
    let col = |n: &str| head.iter().position(|h| h == n);
    let need = |n: &str| col(n).ok_or_else(|| format!("addresses csv: column {n:?} is missing"));
    let (c_id, c_num, c_street, c_lat, c_lon, c_tile) = (need("id")?, need("number")?, need("street")?, need("lat")?, need("lon")?, need("tile")?);
    let (c_unit, c_pc, c_city, c_state, c_country) = (col("unit"), col("postcode"), col("postal_city"), col("state"), col("country"));
    let mut w = csv::Writer::from_writer(BufWriter::new(File::create(&cfg.out).map_err(|e| format!("{}: {e}", cfg.out.display()))?));
    w.write_record(HEADER).map_err(|e| e.to_string())?;
    let mut prov = BufWriter::new(File::create(&cfg.provenance).map_err(|e| format!("{}: {e}", cfg.provenance.display()))?);
    writeln!(prov, "oa_id\ttile\tnumber\tstreet\tlat\tlon").map_err(|e| e.to_string())?;

    let mut cur: Option<(u32, Vec<Addr>)> = None;
    for rec in rdr.records() {
        let rec = rec.map_err(|e| e.to_string())?;
        let get = |i: usize| rec.get(i).unwrap_or("").trim();
        let opt = |i: Option<usize>| i.map(get).unwrap_or("").to_string();
        let Ok(tile) = get(c_tile).parse::<u32>() else { continue };
        let (Ok(lat), Ok(lon)) = (get(c_lat).parse::<f64>(), get(c_lon).parse::<f64>()) else { continue };
        rep.overture_rows += 1;
        if cur.as_ref().map(|c| c.0) != Some(tile) {
            if let Some((t, rows)) = cur.take() {
                flush_tile(&mut oa, cfg.dist_m, t, rows, &mut rep, &mut w, &mut prov)?;
            }
            // Tiles that only OA has, below this one.
            let lower: Vec<u32> = oa.range(..tile).map(|(k, _)| *k).collect();
            for t in lower {
                flush_tile(&mut oa, cfg.dist_m, t, Vec::new(), &mut rep, &mut w, &mut prov)?;
            }
            cur = Some((tile, Vec::new()));
        }
        if let Some((_, rows)) = cur.as_mut() {
            rows.push(Addr {
                id: get(c_id).to_string(),
                number: get(c_num).to_string(),
                street: get(c_street).to_string(),
                unit: opt(c_unit),
                postcode: opt(c_pc),
                city: opt(c_city),
                state: opt(c_state),
                country: opt(c_country),
                lat,
                lon,
                lat_s: get(c_lat).to_string(),
                lon_s: get(c_lon).to_string(),
                source: String::new(),
            });
        }
    }
    if let Some((t, rows)) = cur.take() {
        flush_tile(&mut oa, cfg.dist_m, t, rows, &mut rep, &mut w, &mut prov)?;
    }
    let rest: Vec<u32> = oa.keys().copied().collect();
    for t in rest {
        flush_tile(&mut oa, cfg.dist_m, t, Vec::new(), &mut rep, &mut w, &mut prov)?;
    }
    w.flush().map_err(|e| e.to_string())?;
    prov.flush().map_err(|e| e.to_string())?;

    let attrib: Vec<serde_json::Value> = sources
        .iter()
        .map(|s| {
            let st = rep.per_source.get(&format!("oa:{}", s.id)).cloned().unwrap_or_default();
            serde_json::json!({"source": format!("oa:{}", s.id), "license": s.license, "license_url": s.license_url, "attribution": s.attribution,
                               "website": s.website, "read": st.read, "added": st.added})
        })
        .collect();
    std::fs::write(&cfg.attribution, serde_json::to_string_pretty(&attrib).map_err(|e| e.to_string())?).map_err(|e| format!("{}: {e}", cfg.attribution.display()))?;
    Ok(rep)
}

/// The build's attribution text for the OA sources that added at least one address: appended to `meta.attribution`.
pub fn attribution_text(json: &str) -> Result<(String, String), String> {
    let v: Vec<serde_json::Value> = serde_json::from_str(json).map_err(|e| format!("oa attribution: {e}"))?;
    let used: Vec<&serde_json::Value> = v.iter().filter(|s| s["added"].as_u64().unwrap_or(0) > 0).collect();
    if used.is_empty() {
        return Ok((String::new(), String::new()));
    }
    let ids: Vec<&str> = used.iter().filter_map(|s| s["source"].as_str()).collect();
    let sources = format!("OpenAddresses ({})", ids.iter().map(|i| i.trim_start_matches("oa:")).collect::<Vec<_>>().join(", "));
    let mut parts = Vec::new();
    for s in &used {
        let id = s["source"].as_str().unwrap_or("").trim_start_matches("oa:");
        let who = s["attribution"].as_str().filter(|x| !x.is_empty());
        let lic = s["license"].as_str().filter(|x| !x.is_empty());
        parts.push(match (who, lic) {
            (Some(w), Some(l)) => format!("{id}: {w}, {l}"),
            (Some(w), None) => format!("{id}: {w}"),
            (None, Some(l)) => format!("{id}: {l}"),
            (None, None) => format!("{id}: no licence stated by the source"),
        });
    }
    Ok((sources, format!("Street addresses also from OpenAddresses (openaddresses.io), each source under its own licence: {}.", parts.join("; "))))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn a(number: &str, street: &str, city: &str, lat: f64, lon: f64) -> Addr {
        Addr { id: format!("t-{number}-{street}"), number: number.into(), street: street.into(), city: city.into(), lat, lon, ..Default::default() }
    }
    fn oa(number: &str, street: &str, city: &str, lat: f64, lon: f64, src: &str) -> Addr {
        Addr { source: format!("oa:{src}"), id: format!("oa:{src}:{number}{street}"), ..a(number, street, city, lat, lon) }
    }

    #[test]
    fn street_spellings_match() {
        assert_eq!(norm_street("W MALBAR ST"), norm_street("West Malbar Street"));
        assert_eq!(norm_street("3rd St  S"), norm_street("3RD STREET SOUTH"));
        assert_ne!(norm_street("Main St"), norm_street("Main Ave"));
        assert_eq!(norm_number(" 12 a "), "12A");
    }

    #[test]
    fn adds_only_what_is_missing() {
        let mut have = vec![a("100", "Main St", "Nampa", 43.5800, -116.5600)];
        let new = vec![
            // Same street and number, same spot, other spelling: a duplicate (near).
            oa("100", "MAIN STREET", "", 43.58001, -116.56001, "us/id/canyon"),
            // Same street and number, 4 km away but the same town: a duplicate (town).
            oa("100", "Main St", "NAMPA", 43.6200, -116.5600, "us/id/canyon"),
            // Same number within 5 m, the street spelt differently: a duplicate (number).
            oa("100", "Hwy 1", "", 43.58002, -116.56002, "us/id/canyon"),
            // Same street and number in another town, far away: kept.
            oa("100", "Main St", "Caldwell", 43.6600, -116.6900, "us/id/canyon"),
            // A new number on the street: kept.
            oa("102", "Main St", "Nampa", 43.5801, -116.5601, "us/id/canyon"),
            // The same address from the statewide source after the county source: a duplicate of the one just added.
            oa("102", "Main St", "Nampa", 43.5801, -116.5601, "us/id/statewide"),
        ];
        let mut stats = BTreeMap::new();
        let added = merge_tile(&mut have, new, DEFAULT_DIST_M, &mut stats);
        let got: Vec<(&str, &str)> = added.iter().map(|x| (x.number.as_str(), x.city.as_str())).collect();
        assert_eq!(got, vec![("100", "Caldwell"), ("102", "Nampa")]);
        assert_eq!(have.len(), 3);
        let c = &stats["oa:us/id/canyon"];
        assert_eq!((c.added, c.dup_near, c.dup_town, c.dup_number), (2, 1, 1, 1));
        let s = &stats["oa:us/id/statewide"];
        assert_eq!((s.added, s.dup_near), (0, 1));
    }

    #[test]
    fn parses_oa_lines() {
        let line = r#"{"type":"Feature","properties":{"hash":"abc123","number":"411","street":"Blaine St","unit":"","city":"Caldwell","district":"","region":"ID","postcode":"83605","id":""},"geometry":{"type":"Point","coordinates":[-116.6874,43.6629]}}"#;
        let r = parse_oa_line(line, "us/id/canyon", "US").unwrap();
        assert_eq!((r.number.as_str(), r.street.as_str(), r.city.as_str(), r.state.as_str(), r.postcode.as_str()), ("411", "Blaine St", "Caldwell", "ID", "83605"));
        assert_eq!((r.id.as_str(), r.source.as_str(), r.country.as_str()), ("oa:us/id/canyon:abc123", "oa:us/id/canyon", "US"));
        assert!((r.lat - 43.6629).abs() < 1e-9 && (r.lon + 116.6874).abs() < 1e-9);
        // No number, no street, not a point, a null island point: all dropped.
        assert!(parse_oa_line(&line.replace("\"411\"", "\"\""), "s", "US").is_none());
        assert!(parse_oa_line(&line.replace("Blaine St", ""), "s", "US").is_none());
        assert!(parse_oa_line(&line.replace("Point", "Polygon"), "s", "US").is_none());
        assert!(parse_oa_line(&line.replace("[-116.6874,43.6629]", "[0,0]"), "s", "US").is_none());
        assert!(parse_oa_line("not json", "s", "US").is_none());
    }

    #[test]
    fn file_merge_end_to_end() {
        let dir = std::env::temp_dir().join(format!("oa_merge_test_{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let ov = dir.join("ov.csv");
        std::fs::write(
            &ov,
            "id,number,street,unit,postcode,postal_city,state,country,lat,lon,tile\n\
             o1,100,Main St,,83651,Nampa,ID,US,43.58,-116.56,47943\n",
        )
        .unwrap();
        let g = dir.join("c.geojson");
        let feat = |n: &str, lat: f64| format!("{{\"type\":\"Feature\",\"properties\":{{\"hash\":\"h{n}\",\"number\":\"{n}\",\"street\":\"Main St\",\"city\":\"Nampa\",\"region\":\"ID\",\"postcode\":\"83651\"}},\"geometry\":{{\"type\":\"Point\",\"coordinates\":[-116.56,{lat}]}}}}\n");
        std::fs::write(&g, format!("{}{}", feat("100", 43.58), feat("102", 43.5801))).unwrap();
        let man = dir.join("m.tsv");
        std::fs::write(&man, "source\tpath\tlicense\tlicense_url\tattribution\twebsite\nus/id/canyon\tc.geojson\t\t\t\t\n").unwrap();
        let cfg = OaCfg { overture_csv: ov, sources: man, out: dir.join("out.csv"), provenance: dir.join("p.tsv"), attribution: dir.join("a.json"), dist_m: 30.0, bbox: None };
        let rep = oa_merge(&cfg).unwrap();
        assert_eq!(rep.overture_rows, 1);
        assert_eq!(rep.per_source["oa:us/id/canyon"].added, 1);
        let out = std::fs::read_to_string(dir.join("out.csv")).unwrap();
        assert_eq!(out.lines().count(), 3, "{out}");
        assert!(out.lines().next().unwrap().ends_with(",source"));
        assert!(out.contains("oa:us/id/canyon:h102"));
        assert!(!out.contains("h100"));
        let prov = std::fs::read_to_string(dir.join("p.tsv")).unwrap();
        assert_eq!(prov.lines().count(), 2);
        let (s, t) = attribution_text(&std::fs::read_to_string(dir.join("a.json")).unwrap()).unwrap();
        assert_eq!(s, "OpenAddresses (us/id/canyon)");
        assert!(t.contains("us/id/canyon: no licence stated by the source"));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
