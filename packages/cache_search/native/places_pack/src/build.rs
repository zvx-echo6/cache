//! The pipeline after the sources: merge Overture and OSM records of the same place, enrich emergency rooms with the
//! hospital they belong to, give every place a state, country and nearest locality, and write places.sqlite.

use crate::admins::Admins;
use crate::arrival::{self, ArrivalReport};
use crate::model::{Anchor, Harvest, PlaceSource, Raw, RawLocality};
use crate::rules::{generic_kind_id, Rules};
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
    if into.kind_id.is_none() {
        into.kind_id = other.kind_id.clone();
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

/// A confirmed emergency room is an Overture emergency-department row with an OSM hospital within the rule's radius: it
/// takes that hospital's name, address, contact details and wiki ids, and remembers it (`matched`). A row with no hospital
/// there (an air ambulance, a clinic) is not an emergency room and is dropped. Returns (confirmed, dropped).
fn enrich(rows: &mut Vec<Raw>) -> (usize, usize) {
    let mut by_cat: HashMap<String, Grid> = HashMap::new();
    for (i, r) in rows.iter().enumerate() {
        if let Some(c) = &r.category {
            by_cat.entry(c.clone()).or_insert_with(|| Grid::new(0.01)).add(i, r.lat, r.lon);
        }
    }
    let mut n = 0;
    let mut dead = vec![false; rows.len()];
    for i in 0..rows.len() {
        let Some((cat, radius)) = rows[i].enrich.clone() else { continue };
        let Some(grid) = by_cat.get(&cat) else {
            dead[i] = true;
            continue;
        };
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
            r.matched = Some(h.source_id.clone());
            n += 1;
        } else {
            dead[i] = true;
        }
    }
    let dropped = dead.iter().filter(|d| **d).count();
    let mut k = 0;
    rows.retain(|_| {
        k += 1;
        !dead[k - 1]
    });
    (n, dropped)
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
    /// Places per kind id.
    pub per_kind: BTreeMap<String, usize>,
    pub notes: Vec<String>,
}

/// Where a place or town is: its state code and country, and for a place the town it is in (addr:city when the source
/// has one, else the nearest city, town or village of the same state within 10 km).
#[derive(Debug, Clone, Default)]
pub struct Geo {
    pub state: Option<String>,
    pub country: Option<String>,
    pub locality: Option<String>,
}

/// The rows of one area after the merge, the emergency-room enrichment, the dedupe and the geography: what a pack (or a
/// block) is written from.
pub struct Processed {
    pub rows: Vec<Raw>,
    pub geo: Vec<Geo>,
    pub locs: Vec<RawLocality>,
    pub loc_geo: Vec<Geo>,
    /// Every state seen: code -> (name, country).
    pub states: BTreeMap<String, (String, Option<String>)>,
    pub merged: usize,
    pub deduped: usize,
    pub enriched: usize,
}

fn retain_with<T, G>(v: &mut Vec<T>, g: &mut Vec<G>, keep: &[bool]) {
    let mut k = 0;
    v.retain(|_| {
        k += 1;
        keep[k - 1]
    });
    let mut k = 0;
    g.retain(|_| {
        k += 1;
        keep[k - 1]
    });
}

impl Processed {
    /// Keeps the places for which `keep` is true.
    pub fn retain_places(&mut self, keep: impl Fn(&Raw, &Geo) -> bool) {
        let k: Vec<bool> = self.rows.iter().zip(&self.geo).map(|(r, g)| keep(r, g)).collect();
        retain_with(&mut self.rows, &mut self.geo, &k);
    }

    /// Keeps the towns for which `keep` is true.
    pub fn retain_localities(&mut self, keep: impl Fn(&RawLocality) -> bool) {
        let k: Vec<bool> = self.locs.iter().map(&keep).collect();
        retain_with(&mut self.locs, &mut self.loc_geo, &k);
    }
}

/// Merge, enrich and dedupe the places, give them their arrival points from `anchors`, dedupe the towns, and give every
/// row its state, country and (places) town. `country` fills the country of a row inside a state when the boundaries carry
/// no polygon for the country.
pub fn process(mut rows: Vec<Raw>, locs: Vec<RawLocality>, anchors: &[Anchor], rules: &Rules, admins: &mut Admins, country: &str, log: bool) -> Processed {
    let say = |m: String| {
        if log {
            eprintln!("{m}");
        }
    };
    let merged = merge(&mut rows, rules);
    say(format!("merged {merged} Overture records into OSM places"));
    let (enriched, er_dropped) = enrich(&mut rows);
    say(format!("{enriched} emergency rooms confirmed by a hospital; dropped {er_dropped} emergency-department records with no hospital"));
    let deduped = dedupe(&mut rows, rules);
    say(format!("dropped {deduped} duplicates"));
    let a: ArrivalReport = arrival::assign(&mut rows, anchors, &rules.arrival);
    say(format!(
        "{} arrival points: {} hospitals at an emergency entrance, {} airports at a terminal, {} places at a main door, {} large areas at their parking",
        a.total(), a.emergency, a.terminal, a.entrance, a.parking
    ));
    let locs = dedupe_localities(locs);
    say(format!("{} localities", locs.len()));

    // Geography: state and country for every locality and place, then the nearest town (same state) for places that
    // carry no addr:city.
    say("locating states".into());
    let mut states: BTreeMap<String, (String, Option<String>)> = BTreeMap::new();
    let mut locate = |lat: f64, lon: f64| -> Geo {
        let (st, c) = admins.locate(lat, lon);
        if let Some((code, name)) = &st {
            states.entry(code.clone()).or_insert((name.clone(), c.clone().or_else(|| Some(country.to_string()))));
        }
        let c = if st.is_some() && c.is_none() { Some(country.to_string()) } else { c };
        Geo { state: st.map(|s| s.0), country: c, locality: None }
    };
    let loc_geo: Vec<Geo> = locs.iter().map(|l| locate(l.lat, l.lon)).collect();
    let mut geo: Vec<Geo> = rows.iter().map(|r| locate(r.lat, r.lon)).collect();
    let mut grid = Grid::new(0.1);
    for (i, l) in locs.iter().enumerate() {
        if l.kind != "hamlet" {
            grid.add(i, l.lat, l.lon);
        }
    }
    for (r, g) in rows.iter().zip(geo.iter_mut()) {
        g.locality = match &r.city {
            Some(c) => Some(c.clone()),
            None => nearest_locality(&grid, &locs, &loc_geo, r.lat, r.lon, &g.state),
        };
    }
    Processed { rows, geo, locs, loc_geo, states, merged, deduped, enriched }
}

/// The nearest city, town or village of `state` within 10 km (`grid` holds the indices of `locs` that are not hamlets,
/// in 0.1 degree cells).
fn nearest_locality(grid: &Grid, locs: &[RawLocality], loc_geo: &[Geo], lat: f64, lon: f64, state: &Option<String>) -> Option<String> {
    state.as_ref()?;
    grid.around(lat, lon, 2)
        .into_iter()
        .filter(|&j| loc_geo[j].state == *state)
        .map(|j| (haversine_km(lat, lon, locs[j].lat, locs[j].lon), j))
        .filter(|(d, _)| *d <= 10.0)
        .min_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal))
        .map(|(_, j)| locs[j].name.clone())
}

/// The towns of `locs` (with their states) for "nearest town" lookups outside `process` (the addresses step).
pub struct Towns {
    grid: Grid,
    locs: Vec<RawLocality>,
    geo: Vec<Geo>,
}

impl Towns {
    pub fn new(locs: Vec<RawLocality>, geo: Vec<Geo>) -> Towns {
        let mut grid = Grid::new(0.1);
        for (i, l) in locs.iter().enumerate() {
            if l.kind != "hamlet" {
                grid.add(i, l.lat, l.lon);
            }
        }
        Towns { grid, locs, geo }
    }

    /// The nearest city, town or village of `state` within 10 km.
    pub fn nearest(&self, lat: f64, lon: f64, state: &Option<String>) -> Option<String> {
        nearest_locality(&self.grid, &self.locs, &self.geo, lat, lon, state)
    }

    /// A town within 30 km whose name is `name` apart from case ("WEST VALLEY CITY" in the address data is the town
    /// "West Valley City"), as the town writes it. (A postal city covers more than the town: Salt Lake City's addresses
    /// reach well past 10 km from its centre.)
    pub fn named_near(&self, name: &str, lat: f64, lon: f64) -> Option<String> {
        self.grid
            .around(lat, lon, 4)
            .into_iter()
            .filter(|&j| self.locs[j].name.eq_ignore_ascii_case(name) && haversine_km(lat, lon, self.locs[j].lat, self.locs[j].lon) <= 30.0)
            .map(|j| self.locs[j].name.clone())
            .next()
    }
}

/// Per category, source and kind: how many places a written pack holds.
#[derive(Default)]
pub struct Counts {
    pub per_category: BTreeMap<String, usize>,
    pub per_source: BTreeMap<String, usize>,
    pub per_kind: BTreeMap<String, usize>,
}

/// Writes a format 2 pack (`SCHEMA`) from `p` to `out_path`, replacing any file there. `meta` are the caller's meta keys
/// (region id and name, the box, sources); format_version, built_at, builder_rules and attribution are added here.
pub fn write_pack(out_path: &Path, p: &Processed, rules: &Rules, rules_json: &str, meta: &[(&str, String)]) -> Result<Counts, String> {
    let _ = std::fs::remove_file(out_path);
    let mut conn = Connection::open(out_path).map_err(|e| e.to_string())?;
    conn.execute_batch("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;").map_err(|e| e.to_string())?;
    conn.execute_batch(SCHEMA).map_err(|e| e.to_string())?;
    let tx = conn.transaction().map_err(|e| e.to_string())?;
    let rows = &p.rows;

    // Order: category order first, so a category's places sit together in the file.
    let cat_order: HashMap<&str, usize> = rules.categories.iter().enumerate().map(|(i, c)| (c.id.as_str(), i)).collect();
    let mut order: Vec<usize> = (0..rows.len()).collect();
    order.sort_by(|&a, &b| {
        let ka = (rows[a].category.as_deref().map(|c| cat_order[c]).unwrap_or(usize::MAX), (rows[a].lat * 100.0) as i64, (rows[a].lon * 100.0) as i64);
        let kb = (rows[b].category.as_deref().map(|c| cat_order[c]).unwrap_or(usize::MAX), (rows[b].lat * 100.0) as i64, (rows[b].lon * 100.0) as i64);
        ka.cmp(&kb)
    });

    let mut n = Counts::default();
    for (k, &i) in order.iter().enumerate() {
        let r = &rows[i];
        let kind_id = r.kind_id.clone().unwrap_or_else(|| generic_kind_id(&r.kind));
        *n.per_kind.entry(kind_id.clone()).or_default() += 1;
        let id = k as i64 + 1;
        let g = &p.geo[i];
        tx.execute(
            "INSERT INTO places(id, name, category, kind, lat, lon, street, locality, county, state, country, phone, hours, website, source, source_id, confidence, wikidata_id, wikipedia_title, wikivoyage_title, brand_wikidata, matched_source_id, kind_id, arrival_lat, arrival_lon) \
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, NULL, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20, ?21, ?22, ?23, ?24)",
            params![id, r.name, r.category, r.kind, r.lat, r.lon, r.street, g.locality, g.state, g.country, r.phone, r.hours, r.website, r.source, r.source_id, r.confidence, r.wiki.wikidata, r.wiki.wikipedia, r.wiki.wikivoyage, r.brand_wikidata, r.matched, kind_id, r.arrival.map(|a| a.0), r.arrival.map(|a| a.1)],
        )
        .map_err(|e| e.to_string())?;
        tx.execute("INSERT INTO places_rt(id, min_lat, max_lat, min_lon, max_lon) VALUES (?1, ?2, ?2, ?3, ?3)", params![id, r.lat, r.lon]).map_err(|e| e.to_string())?;
        if let Some(name) = &r.name {
            tx.execute("INSERT INTO places_fts(rowid, name, alt_names) VALUES (?1, ?2, ?3)", params![id, name, r.alt.join("; ")]).map_err(|e| e.to_string())?;
        }
        *n.per_category.entry(r.category.clone().unwrap_or_else(|| "(none)".into())).or_default() += 1;
        *n.per_source.entry(r.source.to_string()).or_default() += 1;
    }
    for (i, l) in p.locs.iter().enumerate() {
        let id = i as i64 + 1;
        let g = &p.loc_geo[i];
        tx.execute(
            "INSERT INTO localities(id, name, kind, lat, lon, population, county, state, country, source_id, wikidata_id, wikipedia_title, wikivoyage_title) VALUES (?1, ?2, ?3, ?4, ?5, ?6, NULL, ?7, ?8, ?9, ?10, ?11, ?12)",
            params![id, l.name, l.kind, l.lat, l.lon, l.population, g.state, g.country, l.source_id, l.wiki.wikidata, l.wiki.wikipedia, l.wiki.wikivoyage],
        )
        .map_err(|e| e.to_string())?;
        tx.execute("INSERT INTO localities_rt(id, min_lat, max_lat, min_lon, max_lon) VALUES (?1, ?2, ?2, ?3, ?3)", params![id, l.lat, l.lon]).map_err(|e| e.to_string())?;
        tx.execute("INSERT INTO localities_fts(rowid, name, alt_names) VALUES (?1, ?2, ?3)", params![id, l.name, l.alt.join("; ")]).map_err(|e| e.to_string())?;
    }
    for (code, (name, country)) in &p.states {
        tx.execute("INSERT INTO states(code, name, country) VALUES (?1, ?2, ?3)", params![code, name, country]).map_err(|e| e.to_string())?;
    }
    for (i, c) in rules.categories.iter().enumerate() {
        tx.execute(
            "INSERT INTO categories(id, title, description, rules, place_count, sort) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![c.id, c.title, c.description, Rules::rules_json(c), *n.per_category.get(&c.id).unwrap_or(&0) as i64, i as i64],
        )
        .map_err(|e| e.to_string())?;
    }
    // The kinds: every kind the rules define (even one no place of this region has), then the kinds the builder derived from a raw
    // type because no rule covers them, with the label read from the id.
    let mut sort = 0i64;
    for k in &rules.kinds {
        tx.execute(
            "INSERT INTO kinds(id, label, description, category, rules, place_count, sort) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![k.id, k.label, k.description, k.category, Rules::kind_rules_json(k), *n.per_kind.get(&k.id).unwrap_or(&0) as i64, sort],
        )
        .map_err(|e| e.to_string())?;
        sort += 1;
    }
    for (id, c) in n.per_kind.iter().filter(|(id, _)| !rules.kinds.iter().any(|k| &k.id == *id)) {
        tx.execute(
            "INSERT INTO kinds(id, label, description, category, rules, place_count, sort) VALUES (?1, ?2, '', NULL, '[]', ?3, ?4)",
            params![id, rules.kind_label(id), *c as i64, sort],
        )
        .map_err(|e| e.to_string())?;
        sort += 1;
    }
    let built_at = chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%:z").to_string();
    let mut all: Vec<(&str, String)> = vec![("format_version", FORMAT_VERSION.to_string()), ("built_at", built_at)];
    all.extend(meta.iter().cloned());
    all.push(("builder_rules", rules_json.to_string()));
    all.push(("attribution", ATTRIBUTION.to_string()));
    for (k, v) in all {
        tx.execute("INSERT INTO meta(key, value) VALUES (?1, ?2)", params![k, v]).map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    conn.execute_batch("INSERT INTO places_fts(places_fts) VALUES ('optimize'); INSERT INTO localities_fts(localities_fts) VALUES ('optimize'); ANALYZE;")
        .map_err(|e| e.to_string())?;
    drop(conn);
    let conn = Connection::open(out_path).map_err(|e| e.to_string())?;
    conn.execute_batch("VACUUM;").map_err(|e| e.to_string())?;
    Ok(n)
}

pub const ATTRIBUTION: &str =
    "Contains data from OpenStreetMap (c) OpenStreetMap contributors, ODbL 1.0, and from Overture Maps Foundation places (per-source licences, CDLA-Permissive-2.0 and others).";

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
    let mut admins = Admins::load(admins_path)?;
    let (min_lat, min_lon, max_lat, max_lon) = admins.bbox_of_state(&cfg.admin_state).ok_or_else(|| format!("no state called {:?} in the admin boundaries", cfg.admin_state))?;
    let anchors = std::mem::take(&mut h.anchors);
    let mut p = process(std::mem::take(&mut h.places), std::mem::take(&mut h.localities), &anchors, rules, &mut admins, &cfg.country, true);

    // A neighbouring state's categories stay (an emergency room across the border can be the nearest); its other
    // named places go: they are another region's geocoder data.
    let region_code = admins.state_code(&cfg.admin_state);
    let before = p.rows.len();
    p.retain_places(|r, g| r.category.is_some() || g.state == region_code);
    eprintln!("dropped {} named places outside {}", before - p.rows.len(), cfg.admin_state);
    eprintln!("writing {}", out_path.display());
    let n = write_pack(
        out_path,
        &p,
        rules,
        rules_json,
        &[
            ("region_id", cfg.id.clone()),
            ("region_name", cfg.name.clone()),
            ("min_lat", min_lat.to_string()),
            ("min_lon", min_lon.to_string()),
            ("max_lat", max_lat.to_string()),
            ("max_lon", max_lon.to_string()),
            ("sources", described.join("; ")),
        ],
    )?;

    let mut notes = Vec::new();
    for c in &rules.categories {
        if !n.per_category.contains_key(&c.id) {
            notes.push(format!("category {} has no places", c.id));
        }
    }
    Ok(Report {
        places: p.rows.len(),
        localities: p.locs.len(),
        merged: p.merged,
        deduped: p.deduped,
        enriched: p.enriched,
        per_category: n.per_category,
        per_source: n.per_source,
        per_kind: n.per_kind,
        notes,
    })
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
            kind_id: None,
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
            matched: None,
            extent: None,
            arrival: None,
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
        let mut orphan = raw("overture", "overture:2", "Life Flight Network", Some("emergency_room"), 43.0, -116.0);
        orphan.enrich = Some(("hospital".into(), 250.0));
        rows.push(orphan);
        assert_eq!(enrich(&mut rows), (1, 1));
        assert_eq!(rows.len(), 2);
        assert_eq!(rows[0].name.as_deref(), Some("Cassia Regional Hospital"));
        assert_eq!(rows[0].street.as_deref(), Some("1501 Hiland Ave"));
        assert_eq!(rows[0].source_id, "overture:1");
        assert_eq!(rows[0].wiki.wikidata.as_deref(), Some("Q1"));
        assert_eq!(rows[0].matched.as_deref(), Some("osm:w1"));
        assert!(rows[0].alt.contains(&"Cassia Regional Emergency Dept".to_string()));
    }
}
