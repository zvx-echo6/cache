//! The pipeline after the sources: merge Overture and OSM records of the same place, enrich emergency rooms with the
//! hospital they belong to, give every place a state, country and nearest locality, and write places.sqlite.

use crate::admins::Admins;
use crate::model::{Harvest, PlaceSource, Raw, RawLocality};
use crate::rules::Rules;
use cache_places::geo::haversine_km;
use cache_places::schema::{FORMAT_VERSION, SCHEMA};
use rusqlite::{params, Connection};
use std::collections::{BTreeMap, HashMap};
use std::path::Path;

pub struct BuildCfg {
    pub id: String,
    pub name: String,
    /// The admin state whose box is the pack's region box.
    pub admin_state: String,
    pub include_general: bool,
    /// Country code for places inside a state when the boundaries carry no polygon for the country (the US row is missing).
    pub country: String,
}

/// Dice coefficient over character bigrams of the lower-cased letters and digits: 1.0 for equal names.
pub fn name_similarity(a: &str, b: &str) -> f64 {
    fn grams(s: &str) -> Vec<(char, char)> {
        let c: Vec<char> = s.chars().filter(|c| c.is_alphanumeric()).flat_map(|c| c.to_lowercase()).collect();
        c.windows(2).map(|w| (w[0], w[1])).collect()
    }
    let (ga, gb) = (grams(a), grams(b));
    if ga.is_empty() || gb.is_empty() {
        return if ga.is_empty() && gb.is_empty() && !a.is_empty() && !b.is_empty() { 1.0 } else { 0.0 };
    }
    let mut used = vec![false; gb.len()];
    let mut hit = 0;
    for g in &ga {
        if let Some(j) = (0..gb.len()).find(|&j| !used[j] && gb[j] == *g) {
            used[j] = true;
            hit += 1;
        }
    }
    2.0 * hit as f64 / (ga.len() + gb.len()) as f64
}

struct Grid {
    cell: f64,
    cells: HashMap<(i32, i32), Vec<usize>>,
}

impl Grid {
    fn new(cell: f64) -> Grid {
        Grid { cell, cells: HashMap::new() }
    }
    fn key(&self, lat: f64, lon: f64) -> (i32, i32) {
        ((lat / self.cell).floor() as i32, (lon / self.cell).floor() as i32)
    }
    fn add(&mut self, i: usize, lat: f64, lon: f64) {
        let k = self.key(lat, lon);
        self.cells.entry(k).or_default().push(i);
    }
    /// Indices in the 3x3 cells around the point (so everything within one cell width).
    fn around(&self, lat: f64, lon: f64, rings: i32) -> Vec<usize> {
        let (a, b) = self.key(lat, lon);
        let mut out = Vec::new();
        for da in -rings..=rings {
            for db in -rings..=rings {
                if let Some(v) = self.cells.get(&(a + da, b + db)) {
                    out.extend(v);
                }
            }
        }
        out
    }
}

fn fields(r: &Raw) -> usize {
    [&r.name, &r.street, &r.phone, &r.hours, &r.website].iter().filter(|f| f.is_some()).count()
}

fn absorb(into: &mut Raw, other: &Raw) {
    for (a, b) in [(&mut into.phone, &other.phone), (&mut into.hours, &other.hours), (&mut into.website, &other.website), (&mut into.street, &other.street)] {
        if a.is_none() {
            *a = b.clone();
        }
    }
    if into.confidence.is_none() {
        into.confidence = other.confidence;
    }
    if into.brand_wikidata.is_none() {
        into.brand_wikidata = other.brand_wikidata.clone();
    }
    if into.wiki.wikidata.is_none() {
        into.wiki = other.wiki.clone();
    }
    if let Some(n) = &other.name {
        if into.name.as_ref() != Some(n) && !into.alt.contains(n) {
            into.alt.push(n.clone());
        }
    }
    for a in &other.alt {
        if !into.alt.contains(a) {
            into.alt.push(a.clone());
        }
    }
}

/// Merge Overture records into the OSM record of the same place. Returns how many were merged.
fn merge(rows: &mut Vec<Raw>, rules: &Rules) -> usize {
    let m = &rules.merge;
    let mut grid = Grid::new(0.01);
    for (i, r) in rows.iter().enumerate() {
        if r.source == "osm" {
            grid.add(i, r.lat, r.lon);
        }
    }
    let mut dead = vec![false; rows.len()];
    let mut merged = 0;
    for i in 0..rows.len() {
        if rows[i].source != "overture" {
            continue;
        }
        let general = rows[i].category.is_none();
        let mut best: Option<(f64, usize)> = None;
        for j in grid.around(rows[i].lat, rows[i].lon, 1) {
            if dead[j] || rows[j].category != rows[i].category {
                continue;
            }
            let dm = haversine_km(rows[i].lat, rows[i].lon, rows[j].lat, rows[j].lon) * 1000.0;
            let sim = match (&rows[i].name, &rows[j].name) {
                (Some(a), Some(b)) => name_similarity(a, b),
                _ => 0.0,
            };
            let ok = if general { dm <= m.near_m && sim >= m.general_name_similarity } else { dm <= m.close_m || (dm <= m.near_m && sim >= m.name_similarity) };
            if ok && best.is_none_or(|(d, _)| dm < d) {
                best = Some((dm, j));
            }
        }
        if let Some((_, j)) = best {
            let o = rows[i].clone();
            absorb(&mut rows[j], &o);
            rows[j].source = "osm+overture";
            dead[i] = true;
            merged += 1;
        }
    }
    let mut k = 0;
    rows.retain(|_| {
        k += 1;
        !dead[k - 1]
    });
    merged
}

/// The same place listed twice in one category (an OSM node and its building, two Overture listings, two emergency-room
/// records of one hospital): close together with near-identical names, or both unnamed and almost on top of each other.
fn dedupe(rows: &mut Vec<Raw>, rules: &Rules) -> usize {
    let m = &rules.merge;
    let mut grid = Grid::new(0.01);
    for (i, r) in rows.iter().enumerate() {
        if r.category.is_some() {
            grid.add(i, r.lat, r.lon);
        }
    }
    let mut dead = vec![false; rows.len()];
    let mut deduped = 0;
    for i in 0..rows.len() {
        if dead[i] || rows[i].category.is_none() {
            continue;
        }
        for j in grid.around(rows[i].lat, rows[i].lon, 1) {
            if j >= i || dead[j] || dead[i] || rows[j].category != rows[i].category {
                continue;
            }
            let dm = haversine_km(rows[i].lat, rows[i].lon, rows[j].lat, rows[j].lon) * 1000.0;
            let same = match (&rows[i].name, &rows[j].name) {
                (Some(a), Some(b)) => dm <= m.near_m && name_similarity(a, b) >= 0.9,
                (None, None) => dm <= 15.0,
                _ => false,
            };
            if same {
                let (keep, drop) = if fields(&rows[j]) >= fields(&rows[i]) { (j, i) } else { (i, j) };
                let o = rows[drop].clone();
                absorb(&mut rows[keep], &o);
                dead[drop] = true;
                deduped += 1;
            }
        }
    }
    let mut k = 0;
    rows.retain(|_| {
        k += 1;
        !dead[k - 1]
    });
    deduped
}

/// An emergency room takes its name, address and contact details from the hospital it sits in.
fn enrich(rows: &mut [Raw]) -> usize {
    let mut by_cat: HashMap<String, Grid> = HashMap::new();
    for (i, r) in rows.iter().enumerate() {
        if let Some(c) = &r.category {
            by_cat.entry(c.clone()).or_insert_with(|| Grid::new(0.01)).add(i, r.lat, r.lon);
        }
    }
    let mut n = 0;
    for i in 0..rows.len() {
        let Some((cat, radius)) = rows[i].enrich.clone() else { continue };
        let Some(grid) = by_cat.get(&cat) else { continue };
        let rings = (radius / 800.0).ceil() as i32 + 1;
        let best = grid
            .around(rows[i].lat, rows[i].lon, rings)
            .into_iter()
            .filter(|&j| j != i)
            .map(|j| (haversine_km(rows[i].lat, rows[i].lon, rows[j].lat, rows[j].lon) * 1000.0, j))
            .filter(|(d, _)| *d <= radius)
            .min_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal));
        if let Some((_, j)) = best {
            let h = rows[j].clone();
            let r = &mut rows[i];
            if let Some(hn) = &h.name {
                if r.name.as_ref() != Some(hn) {
                    if let Some(old) = r.name.take() {
                        r.alt.push(old);
                    }
                    r.name = Some(hn.clone());
                }
            }
            for (a, b) in [(&mut r.street, &h.street), (&mut r.city, &h.city), (&mut r.phone, &h.phone), (&mut r.hours, &h.hours), (&mut r.website, &h.website)] {
                if a.is_none() {
                    *a = b.clone();
                }
            }
            if r.wiki.wikidata.is_none() {
                r.wiki = h.wiki.clone();
            }
            r.source = "overture+osm";
            n += 1;
        }
    }
    n
}

/// Same name within 3 km is one town; the bigger one wins.
fn dedupe_localities(locs: Vec<RawLocality>) -> Vec<RawLocality> {
    let rank = |k: &str| match k {
        "city" => 3,
        "town" => 2,
        "village" => 1,
        _ => 0,
    };
    let mut locs = locs;
    locs.sort_by(|a, b| (rank(&b.kind), b.population.unwrap_or(0)).cmp(&(rank(&a.kind), a.population.unwrap_or(0))));
    let mut out: Vec<RawLocality> = Vec::new();
    for l in locs {
        let dup = out.iter().any(|o| o.name.eq_ignore_ascii_case(&l.name) && haversine_km(o.lat, o.lon, l.lat, l.lon) < 3.0);
        if !dup {
            out.push(l);
        }
    }
    out
}

pub struct Report {
    pub places: usize,
    pub localities: usize,
    pub merged: usize,
    pub deduped: usize,
    pub enriched: usize,
    pub per_category: BTreeMap<String, usize>,
    pub per_source: BTreeMap<String, usize>,
    pub notes: Vec<String>,
}

pub fn build(
    cfg: &BuildCfg,
    rules: &Rules,
    rules_json: &str,
    sources: &mut [Box<dyn PlaceSource>],
    admins_path: &Path,
    out_path: &Path,
) -> Result<Report, String> {
    let mut h = Harvest::default();
    let mut described = Vec::new();
    for s in sources.iter_mut() {
        eprintln!("reading {}", s.describe());
        let before = (h.places.len(), h.localities.len());
        s.read(rules, &mut h)?;
        eprintln!("  {} places, {} localities", h.places.len() - before.0, h.localities.len() - before.1);
        described.push(s.describe());
    }
    if !cfg.include_general {
        h.places.retain(|p| p.category.is_some());
    }
    let mut rows = std::mem::take(&mut h.places);
    let merged = merge(&mut rows, rules);
    eprintln!("merged {merged} Overture records into OSM places");
    let enriched = enrich(&mut rows);
    eprintln!("enriched {enriched} places from their hospital");
    let deduped = dedupe(&mut rows, rules);
    eprintln!("dropped {deduped} duplicates");
    let locs = dedupe_localities(h.localities);
    eprintln!("{} localities", locs.len());

    let mut admins = Admins::load(admins_path)?;
    let (min_lat, min_lon, max_lat, max_lon) = admins.bbox_of_state(&cfg.admin_state).ok_or_else(|| format!("no state called {:?} in the admin boundaries", cfg.admin_state))?;

    // Geography: state and country for every locality and place, then the nearest town (same state) for places that
    // carry no addr:city.
    eprintln!("locating states");
    let mut state_names: BTreeMap<String, (String, Option<String>)> = BTreeMap::new();
    let mut loc_geo: Vec<(Option<String>, Option<String>)> = Vec::new();
    for l in &locs {
        let (st, country) = admins.locate(l.lat, l.lon);
        if let Some((c, n)) = &st {
            state_names.entry(c.clone()).or_insert((n.clone(), country.clone().or_else(|| Some(cfg.country.clone()))));
        }
        loc_geo.push((st.map(|s| s.0), country));
    }
    let mut grid = Grid::new(0.1);
    for (i, l) in locs.iter().enumerate() {
        if l.kind != "hamlet" {
            grid.add(i, l.lat, l.lon);
        }
    }
    let mut row_geo: Vec<(Option<String>, Option<String>)> = Vec::with_capacity(rows.len());
    for r in &rows {
        let (st, country) = admins.locate(r.lat, r.lon);
        if let Some((c, n)) = &st {
            state_names.entry(c.clone()).or_insert((n.clone(), country.clone().or_else(|| Some(cfg.country.clone()))));
        }
        row_geo.push((st.map(|s| s.0), country));
    }
    for g in row_geo.iter_mut().chain(loc_geo.iter_mut()) {
        if g.0.is_some() && g.1.is_none() {
            g.1 = Some(cfg.country.clone());
        }
    }
    // A neighbouring state's categories stay (an emergency room across the border can be the nearest); its other
    // named places go: they are another region's geocoder data.
    let region_code = admins.state_code(&cfg.admin_state);
    let before = rows.len();
    let keep: Vec<bool> = rows.iter().zip(&row_geo).map(|(r, g)| r.category.is_some() || g.0 == region_code).collect();
    let mut k = 0;
    rows.retain(|_| {
        k += 1;
        keep[k - 1]
    });
    let mut k = 0;
    row_geo.retain(|_| {
        k += 1;
        keep[k - 1]
    });
    eprintln!("dropped {} named places outside {}", before - rows.len(), cfg.admin_state);
    eprintln!("writing {}", out_path.display());

    let _ = std::fs::remove_file(out_path);
    let mut conn = Connection::open(out_path).map_err(|e| e.to_string())?;
    conn.execute_batch("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;").map_err(|e| e.to_string())?;
    conn.execute_batch(SCHEMA).map_err(|e| e.to_string())?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;

    // Order: category order first, so a category's places sit together in the file.
    let cat_order: HashMap<&str, usize> = rules.categories.iter().enumerate().map(|(i, c)| (c.id.as_str(), i)).collect();
    let mut order: Vec<usize> = (0..rows.len()).collect();
    order.sort_by(|&a, &b| {
        let ka = (rows[a].category.as_deref().map(|c| cat_order[c]).unwrap_or(usize::MAX), (rows[a].lat * 100.0) as i64, (rows[a].lon * 100.0) as i64);
        let kb = (rows[b].category.as_deref().map(|c| cat_order[c]).unwrap_or(usize::MAX), (rows[b].lat * 100.0) as i64, (rows[b].lon * 100.0) as i64);
        ka.cmp(&kb)
    });

    let mut per_category: BTreeMap<String, usize> = BTreeMap::new();
    let mut per_source: BTreeMap<String, usize> = BTreeMap::new();
    for (n, &i) in order.iter().enumerate() {
        let r = &rows[i];
        let id = n as i64 + 1;
        let (state, country) = (&row_geo[i].0, &row_geo[i].1);
        let locality = match &r.city {
            Some(c) => Some(c.clone()),
            None => grid
                .around(r.lat, r.lon, 2)
                .into_iter()
                .filter(|&j| loc_geo[j].0 == *state && state.is_some())
                .map(|j| (haversine_km(r.lat, r.lon, locs[j].lat, locs[j].lon), j))
                .filter(|(d, _)| *d <= 10.0)
                .min_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal))
                .map(|(_, j)| locs[j].name.clone()),
        };
        tx.execute(
            "INSERT INTO places(id, name, category, kind, lat, lon, street, locality, county, state, country, phone, hours, website, source, source_id, confidence, wikidata_id, wikipedia_title, wikivoyage_title, brand_wikidata) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20)",
            params![id, r.name, r.category, r.kind, r.lat, r.lon, r.street, locality, state, country, r.phone, r.hours, r.website, r.source, r.source_id, r.confidence, r.wiki.wikidata, r.wiki.wikipedia, r.wiki.wikivoyage, r.brand_wikidata],
        )
        .map_err(|e| e.to_string())?;
        tx.execute("INSERT INTO places_rt(id, min_lat, max_lat, min_lon, max_lon) VALUES (?1, ?2, ?2, ?3, ?3)", params![id, r.lat, r.lon]).map_err(|e| e.to_string())?;
        if let Some(name) = &r.name {
            tx.execute("INSERT INTO places_fts(rowid, name, alt_names) VALUES (?1, ?2, ?3)", params![id, name, r.alt.join("; ")]).map_err(|e| e.to_string())?;
        }
        *per_category.entry(r.category.clone().unwrap_or_else(|| "(none)".into())).or_default() += 1;
        *per_source.entry(r.source.to_string()).or_default() += 1;
    }
    for (i, l) in locs.iter().enumerate() {
        let id = i as i64 + 1;
        tx.execute(
            "INSERT INTO localities(id, name, kind, lat, lon, population, county, state, country, source_id, wikidata_id, wikipedia_title, wikivoyage_title) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![id, l.name, l.kind, l.lat, l.lon, l.population, loc_geo[i].0, loc_geo[i].1, l.source_id, l.wiki.wikidata, l.wiki.wikipedia, l.wiki.wikivoyage],
        )
        .map_err(|e| e.to_string())?;
        tx.execute("INSERT INTO localities_rt(id, min_lat, max_lat, min_lon, max_lon) VALUES (?1, ?2, ?2, ?3, ?3)", params![id, l.lat, l.lon]).map_err(|e| e.to_string())?;
        tx.execute("INSERT INTO localities_fts(rowid, name, alt_names) VALUES (?1, ?2, ?3)", params![id, l.name, l.alt.join("; ")]).map_err(|e| e.to_string())?;
    }
    for (code, (name, country)) in &state_names {
        tx.execute("INSERT INTO states(code, name, country) VALUES (?1, ?2, ?3)", params![code, name, country]).map_err(|e| e.to_string())?;
    }
    for (i, c) in rules.categories.iter().enumerate() {
        tx.execute(
            "INSERT INTO categories(id, title, description, rules, place_count, sort) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![c.id, c.title, c.description, Rules::rules_json(c), *per_category.get(&c.id).unwrap_or(&0) as i64, i as i64],
        )
        .map_err(|e| e.to_string())?;
    }
    let built_at = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%:z").to_string();
    for (k, v) in [
        ("format_version", FORMAT_VERSION.to_string()),
        ("region_id", cfg.id.clone()),
        ("region_name", cfg.name.clone()),
        ("built_at", built_at),
        ("min_lat", min_lat.to_string()),
        ("min_lon", min_lon.to_string()),
        ("max_lat", max_lat.to_string()),
        ("max_lon", max_lon.to_string()),
        ("sources", described.join("; ")),
        ("builder_rules", rules_json.to_string()),
        (
            "attribution",
            "Contains data from OpenStreetMap (c) OpenStreetMap contributors, ODbL 1.0, and from Overture Maps Foundation places (per-source licences, CDLA-Permissive-2.0 and others).".to_string(),
        ),
    ] {
        tx.execute("INSERT INTO meta(key, value) VALUES (?1, ?2)", params![k, v]).map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    conn.execute_batch("INSERT INTO places_fts(places_fts) VALUES ('optimize'); INSERT INTO localities_fts(localities_fts) VALUES ('optimize'); ANALYZE;")
        .map_err(|e| e.to_string())?;
    drop(conn);
    let conn = Connection::open(out_path).map_err(|e| e.to_string())?;
    conn.execute_batch("VACUUM;").map_err(|e| e.to_string())?;

    let mut notes = Vec::new();
    for c in &rules.categories {
        if !per_category.contains_key(&c.id) {
            notes.push(format!("category {} has no places", c.id));
        }
    }
    Ok(Report { places: rows.len(), localities: locs.len(), merged, deduped, enriched, per_category, per_source, notes })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Wiki;

    fn raw(source: &'static str, id: &str, name: &str, cat: Option<&str>, lat: f64, lon: f64) -> Raw {
        Raw {
            source,
            source_id: id.into(),
            name: Some(name.into()),
            alt: vec![],
            category: cat.map(String::from),
            kind: "x".into(),
            lat,
            lon,
            street: None,
            city: None,
            phone: None,
            hours: None,
            website: None,
            confidence: None,
            wiki: Wiki::default(),
            brand_wikidata: None,
            enrich: None,
        }
    }

    fn rules() -> Rules {
        Rules::parse(include_str!("../categories.json")).unwrap()
    }

    #[test]
    fn similarity() {
        assert!(name_similarity("Walgreens", "WALGREENS") > 0.99);
        assert!(name_similarity("Cassia Regional Hospital", "Cassia Regional Medical Center") > 0.5);
        assert!(name_similarity("Walgreens", "Smith's Pharmacy") < 0.3);
    }

    #[test]
    fn overture_merges_into_close_osm_place() {
        let mut o = raw("overture", "overture:1", "Walgreens", Some("pharmacy"), 42.5390, -113.7870);
        o.phone = Some("+1 208 678 3050".into());
        o.confidence = Some(0.9);
        let mut osm = raw("osm", "osm:n1", "Walgreens Pharmacy", Some("pharmacy"), 42.5391, -113.7871);
        osm.hours = Some("Mo-Su 08:00-22:00".into());
        let far = raw("overture", "overture:2", "CVS", Some("pharmacy"), 42.60, -113.70);
        let mut rows = vec![o, osm, far];
        let merged = merge(&mut rows, &rules());
        assert_eq!(merged, 1);
        assert_eq!(rows.len(), 2);
        let m = rows.iter().find(|r| r.source == "osm+overture").unwrap();
        assert_eq!(m.phone.as_deref(), Some("+1 208 678 3050"));
        assert_eq!(m.hours.as_deref(), Some("Mo-Su 08:00-22:00"));
        assert_eq!(m.source_id, "osm:n1");
    }

    #[test]
    fn different_categories_never_merge() {
        let a = raw("overture", "overture:1", "Cassia Regional Hospital", Some("emergency_room"), 42.5291, -113.7851);
        let b = raw("osm", "osm:n1", "Cassia Regional Hospital", Some("hospital"), 42.5290, -113.7850);
        let mut rows = vec![a, b];
        assert_eq!(merge(&mut rows, &rules()), 0);
        assert_eq!(rows.len(), 2);
    }

    #[test]
    fn emergency_room_takes_the_hospital() {
        let mut er = raw("overture", "overture:1", "Cassia Regional Emergency Dept", Some("emergency_room"), 42.5291, -113.7851);
        er.enrich = Some(("hospital".into(), 250.0));
        let mut h = raw("osm", "osm:w1", "Cassia Regional Hospital", Some("hospital"), 42.5290, -113.7850);
        h.street = Some("1501 Hiland Ave".into());
        h.phone = Some("+1 208 678 4444".into());
        h.wiki.wikidata = Some("Q1".into());
        let mut rows = vec![er, h];
        assert_eq!(enrich(&mut rows), 1);
        assert_eq!(rows[0].name.as_deref(), Some("Cassia Regional Hospital"));
        assert_eq!(rows[0].street.as_deref(), Some("1501 Hiland Ave"));
        assert_eq!(rows[0].source_id, "overture:1");
        assert_eq!(rows[0].wiki.wikidata.as_deref(), Some("Q1"));
        assert!(rows[0].alt.contains(&"Cassia Regional Emergency Dept".to_string()));
    }
}
