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
//!
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
use std::collections::{BTreeMap, BTreeSet, HashMap};
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

/// A street as the duplicate tests compare it: the name with its suffix written out and no directional (lower case), and the
/// directionals it had. "W University Dr" and "University Dr" have the same name; they are one street when their directionals
/// agree or one of them has none (`dirs_agree`).
pub fn street_key(s: &str) -> (String, Vec<String>) {
    let collapsed = s.split_whitespace().collect::<Vec<_>>().join(" ");
    let x = crate::usps::suffix_in_title_case(&title_case_capitals(&collapsed));
    let (core, dirs) = crate::usps::split_directionals(&x);
    let e = crate::usps::expand(&core).unwrap_or(core);
    (e.to_lowercase().chars().filter(|c| !matches!(c, '.' | ',')).collect(), dirs)
}

/// Two directional lists name one street when they are equal or either is empty (a source that leaves the directional out).
pub fn dirs_agree(a: &[String], b: &[String]) -> bool {
    a.is_empty() || b.is_empty() || a == b
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

/// The addresses of one street name and number: (lat, lon, normalised town, directionals).
type Spots = Vec<(f64, f64, String, Vec<String>)>;

/// What a tile already has, for the duplicate tests.
#[derive(Default)]
pub struct Index {
    by_street_number: HashMap<(String, String), Spots>,
    by_cell: HashMap<(String, i64, i64), Vec<(f64, f64)>>,
}

fn cell(v: f64) -> i64 {
    (v / CELL).floor() as i64
}

impl Index {
    pub fn add(&mut self, a: &Addr) {
        let num = norm_number(&a.number);
        let (name, dirs) = street_key(&a.street);
        self.by_street_number.entry((name, num.clone())).or_default().push((a.lat, a.lon, norm_town(&a.city), dirs));
        self.by_cell.entry((num, cell(a.lat), cell(a.lon))).or_default().push((a.lat, a.lon));
    }

    /// Why the address is already there: "near", "town" or "number", or None.
    pub fn duplicate(&self, a: &Addr, max_m: f64) -> Option<&'static str> {
        let num = norm_number(&a.number);
        let town = norm_town(&a.city);
        let (name, dirs) = street_key(&a.street);
        if let Some(v) = self.by_street_number.get(&(name, num.clone())) {
            let v: Vec<_> = v.iter().filter(|p| dirs_agree(&dirs, &p.3)).collect();
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
    /// Where the OA rows wait by tile while the sources are read (deleted after); None: `<out>.spool`. Memory then holds one
    /// tile's rows, not the whole run's.
    pub spool: Option<PathBuf>,
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

/// The OA rows of a run, by level 1 tile, in files while the sources are read (in manifest order, so a tile's rows come back
/// in the same order). One line per row: source index, id, number, street, postcode, city, state, country, lat, lon.
struct Spool {
    dir: PathBuf,
    /// (the `source` value, the country) of each manifest source.
    sources: Vec<(String, String)>,
    tiles: BTreeSet<u32>,
    open: HashMap<u32, BufWriter<File>>,
}

fn clean(s: &str) -> String {
    s.chars().map(|c| if c == '\t' || c == '\n' || c == '\r' { ' ' } else { c }).collect()
}

impl Spool {
    fn new(dir: PathBuf, sources: Vec<(String, String)>) -> Result<Spool, String> {
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).map_err(|e| format!("{}: {e}", dir.display()))?;
        Ok(Spool { dir, sources, tiles: BTreeSet::new(), open: HashMap::new() })
    }

    fn put(&mut self, si: usize, a: &Addr) -> Result<(), String> {
        let tile = tile_id_l1(a.lat, a.lon);
        if self.open.len() >= 300 {
            for w in self.open.values_mut() {
                w.flush().map_err(|e| e.to_string())?;
            }
            self.open.clear(); // reopened in append mode
        }
        if !self.open.contains_key(&tile) {
            let f = std::fs::OpenOptions::new().create(true).append(true).open(self.dir.join(format!("{tile}.tsv"))).map_err(|e| e.to_string())?;
            self.open.insert(tile, BufWriter::new(f));
            self.tiles.insert(tile);
        }
        let w = self.open.get_mut(&tile).expect("opened above");
        writeln!(w, "{si}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}", clean(&a.id), clean(&a.number), clean(&a.street), clean(&a.postcode), clean(&a.city), clean(&a.state), clean(&a.country), a.lat, a.lon)
            .map_err(|e| e.to_string())
    }

    fn finish_writing(&mut self) -> Result<(), String> {
        for w in self.open.values_mut() {
            w.flush().map_err(|e| e.to_string())?;
        }
        self.open.clear();
        Ok(())
    }

    /// The tile's OA rows (and the file is deleted); empty when it has none.
    fn take(&mut self, tile: u32) -> Result<Vec<Addr>, String> {
        if !self.tiles.remove(&tile) {
            return Ok(Vec::new());
        }
        let p = self.dir.join(format!("{tile}.tsv"));
        let mut out = Vec::new();
        for line in BufReader::new(File::open(&p).map_err(|e| format!("{}: {e}", p.display()))?).lines() {
            let line = line.map_err(|e| e.to_string())?;
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() != 10 {
                return Err(format!("{}: a spool line has {} fields", p.display(), f.len()));
            }
            let (si, lat, lon) = (f[0].parse::<usize>().map_err(|e| e.to_string())?, f[8].parse::<f64>().map_err(|e| e.to_string())?, f[9].parse::<f64>().map_err(|e| e.to_string())?);
            let (source, country) = self.sources.get(si).cloned().ok_or("a spool line names no source")?;
            out.push(Addr {
                id: f[1].into(),
                number: f[2].into(),
                street: f[3].into(),
                unit: String::new(),
                postcode: f[4].into(),
                city: f[5].into(),
                state: f[6].into(),
                country: if f[7].is_empty() { country } else { f[7].into() },
                lat,
                lon,
                lat_s: String::new(),
                lon_s: String::new(),
                source,
            });
        }
        std::fs::remove_file(&p).map_err(|e| e.to_string())?;
        Ok(out)
    }
}

/// Merges the OA rows of `tile` into its rows, and writes the tile.
fn flush_tile(spool: &mut Spool, max_m: f64, tile: u32, mut rows: Vec<Addr>, rep: &mut OaReport, w: &mut Out, prov: &mut BufWriter<File>) -> Result<(), String> {
    let o = spool.take(tile)?;
    if !o.is_empty() {
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
    // Every OA row of the run, by tile, in manifest order (in files: a continent's rows do not fit in memory).
    let spool_dir = cfg.spool.clone().unwrap_or_else(|| PathBuf::from(format!("{}.spool", cfg.out.display())));
    let mut oa = Spool::new(spool_dir.clone(), sources.iter().map(|s| (format!("oa:{}", s.id), s.id.split('/').next().unwrap_or("").to_uppercase())).collect())?;
    let mut rep = OaReport::default();
    for (si, src) in sources.iter().enumerate() {
        let st = rep.per_source.entry(format!("oa:{}", src.id)).or_default();
        let country = src.id.split('/').next().unwrap_or("").to_uppercase();
        for line in open_lines(&src.path)?.lines() {
            let line = line.map_err(|e| format!("{}: {e}", src.path.display()))?;
            if line.trim().is_empty() {
                continue;
            }
            match parse_oa_line(&line, &src.id, &country) {
                Some(a) if cfg.bbox.is_none_or(|b| a.lon >= b[0] && a.lat >= b[1] && a.lon < b[2] && a.lat < b[3]) => {
                    st.read += 1;
                    oa.put(si, &a)?;
                }
                Some(_) => {}
                None => st.skipped += 1,
            }
        }
    }
    oa.finish_writing()?;
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
            let lower: Vec<u32> = oa.tiles.range(..tile).copied().collect();
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
    let rest: Vec<u32> = oa.tiles.iter().copied().collect();
    for t in rest {
        flush_tile(&mut oa, cfg.dist_m, t, Vec::new(), &mut rep, &mut w, &mut prov)?;
    }
    w.flush().map_err(|e| e.to_string())?;
    prov.flush().map_err(|e| e.to_string())?;
    let _ = std::fs::remove_dir_all(&oa.dir);

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
        assert_eq!(street_key("W MALBAR ST"), street_key("West Malbar Street"));
        assert_eq!(street_key("3rd St  S"), street_key("3RD STREET SOUTH"));
        assert_ne!(street_key("Main St"), street_key("Main Ave"));
        // The name is the same with or without the directional; the directionals are kept to tell E from W.
        assert_eq!(street_key("W University Dr").0, street_key("University Dr").0);
        assert_ne!(street_key("W University Dr").1, street_key("E University Dr").1);
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
    fn a_missing_directional_matches_but_a_different_one_does_not() {
        // About 20 m apart (0.00018 degrees of latitude).
        let mut have = vec![a("200", "W Example Dr", "", 43.5800, -116.5600)];
        let mut stats = BTreeMap::new();
        let oa_rows = vec![
            // The OA source leaves the directional out: the same address.
            oa("200", "Example Dr", "", 43.58018, -116.5600, "us/id/test"),
            // The other side of the road: a different street.
            oa("200", "E Example Dr", "", 43.58018, -116.5600, "us/id/test"),
            // Written out: the same address as the pack's.
            oa("200", "West Example Drive", "", 43.58018, -116.5600, "us/id/test"),
        ];
        let added = merge_tile(&mut have, oa_rows, DEFAULT_DIST_M, &mut stats);
        let got: Vec<&str> = added.iter().map(|x| x.street.as_str()).collect();
        assert_eq!(got, vec!["E Example Dr"]);
        assert_eq!(stats["oa:us/id/test"].dup_near, 2);
        // An added row keeps its own spelling.
        assert_eq!(have[1].street, "E Example Dr");
        // The pack's row without a directional also matches an OA row with one.
        let mut have = vec![a("200", "Example Dr", "", 43.5800, -116.5600)];
        let added = merge_tile(&mut have, vec![oa("200", "W Example Dr", "", 43.58018, -116.5600, "us/id/test")], DEFAULT_DIST_M, &mut BTreeMap::new());
        assert!(added.is_empty());
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
        let cfg = OaCfg { overture_csv: ov, sources: man, out: dir.join("out.csv"), provenance: dir.join("p.tsv"), attribution: dir.join("a.json"), dist_m: 30.0, bbox: None, spool: None };
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
