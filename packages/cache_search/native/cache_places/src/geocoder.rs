//! The offline geocoder: forward search by name (SQLite FTS5 plus a boost for towns, so a bare town name finds the
//! town and not a school named after it) and reverse lookup of the nearest town.
//!
//! `Geocoder` is the trait this crate's tools use (forward search with its scores, reverse lookup). The small
//! `cache_tool::places::Geocoder` ("this text, where is it?") that other crates' tools get through `ToolCtx::geocoder` is
//! implemented over it by `PackPlaceSource`.
//!
//! A query that starts with a house number ("350 N State St, Salt Lake City") is first looked up as an address in the
//! street rows of a merged database (`address`); when no street matches, it is searched as a name like any other.

use crate::address;
use crate::geo::{bearing_deg, haversine_km};
use crate::kind::humanize;
use crate::pack::{LocalityRow, PackSet, PlaceRow};
use std::collections::HashSet;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HitKind {
    Locality,
    Place,
    /// A house number on a street (merged databases only).
    Address,
}

/// One forward-search result.
#[derive(Debug, Clone)]
pub struct GeoHit {
    pub kind: HitKind,
    /// Stable id for numbering: `place:<source id>`, `town:<source id>` or `addr:<street uid>/<house number>`.
    pub address: String,
    pub name: String,
    /// How to show it: `Stanley, ID` for a town, the name for a place.
    pub label: String,
    pub lat: f64,
    pub lon: f64,
    pub locality: Option<String>,
    pub state: Option<String>,
    pub category: Option<String>,
    /// What it is in plain words: "town", or the category id, or the raw type ("amenity=school").
    pub what: Option<String>,
    pub street: Option<String>,
    pub county: Option<String>,
    pub country: Option<String>,
    /// OSM "key:value" ("highway:trailhead") when the place comes from OSM.
    pub osm_category: Option<String>,
    /// What kind of place it is: the pack's kind id and label (`drinking_water`, "Drinking water tap"); for a town its
    /// size (`town`, "Town"). None for a place of a format 1 pack.
    pub kind_id: Option<String>,
    pub kind_label: Option<String>,
    /// How well the name fits the query alone, 0 to 100 (100 exact, 90 an exact alternative name), before the town boost,
    /// the text score and the distance bias.
    pub name_match: f64,
    pub score: f64,
    /// An address whose number was placed between its neighbours rather than found.
    pub approximate: bool,
}

/// The nearest town to a point.
#[derive(Debug, Clone)]
pub struct Nearest {
    pub name: String,
    pub state: Option<String>,
    /// `Burley, ID`.
    pub label: String,
    pub km: f64,
    /// Bearing from the point to the town.
    pub bearing: f64,
}

pub trait Geocoder: Send + Sync {
    /// Places and towns matching `query` ("Stanley, Idaho", "Walgreens, Burley", "Cassia Regional Hospital"), best
    /// first. `near` biases ties toward that point.
    fn forward(&self, query: &str, near: Option<(f64, f64)>, limit: usize) -> Vec<GeoHit>;
    /// The nearest town (city, town or village; a hamlet only when no larger one is within 50 km).
    fn reverse(&self, lat: f64, lon: f64) -> Option<Nearest>;
}

/// Edits (insert, delete, replace, swap of two neighbours) to turn `a` into `b`: the optimal string alignment distance.
pub fn edit_distance(a: &[char], b: &[char]) -> usize {
    let (n, m) = (a.len(), b.len());
    let mut d = vec![vec![0usize; m + 1]; n + 1];
    for (i, row) in d.iter_mut().enumerate() {
        row[0] = i;
    }
    for j in 0..=m {
        d[0][j] = j;
    }
    for i in 1..=n {
        for j in 1..=m {
            let cost = usize::from(a[i - 1] != b[j - 1]);
            d[i][j] = (d[i - 1][j] + 1).min(d[i][j - 1] + 1).min(d[i - 1][j - 1] + cost);
            if i > 1 && j > 1 && a[i - 1] == b[j - 2] && a[i - 2] == b[j - 1] {
                d[i][j] = d[i][j].min(d[i - 2][j - 2] + 1);
            }
        }
    }
    d[n][m]
}

/// How many edits a name of `len` characters may be off and still count as a misspelling of another: one up to 9 characters,
/// two from 10 (a name under 4 characters must match exactly).
pub fn slip_allowed(len: usize) -> usize {
    match len {
        0..=3 => 0,
        4..=9 => 1,
        _ => 2,
    }
}

/// A geocoder over the installed packs.
pub struct PackGeocoder {
    packs: Arc<PackSet>,
}

impl PackGeocoder {
    pub fn new(packs: Arc<PackSet>) -> PackGeocoder {
        PackGeocoder { packs }
    }
}

/// Lowercase, accents kept simple (the FTS index folds them), letters and digits only, one space between words.
fn words(s: &str) -> Vec<String> {
    s.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(|w| w.to_lowercase()).collect()
}

fn norm(s: &str) -> String {
    words(s).join(" ")
}

/// FTS5 MATCH expression: every word required, the last one as a prefix. `any` makes the words alternatives.
fn fts_expr(ws: &[String], any: bool) -> Option<String> {
    if ws.is_empty() {
        return None;
    }
    let parts: Vec<String> = ws
        .iter()
        .enumerate()
        .map(|(i, w)| {
            let w = w.replace('"', "");
            if i + 1 == ws.len() {
                format!("\"{w}\"*")
            } else {
                format!("\"{w}\"")
            }
        })
        .collect();
    Some(parts.join(if any { " OR " } else { " " }))
}

struct Query {
    head: String,
    state: Option<String>,
    area: Option<String>,
}

/// Splits "Walgreens, Burley, Idaho" into the name, a state filter and an area. Qualifiers are matched against the
/// states and town names in the packs; a trailing state (full name or two-letter code, in any letter case) also counts.
fn parse_query(q: &str, states: &[(String, String)]) -> Query {
    let find_state = |s: &str| -> Option<String> {
        let t = s.trim();
        let t = t.to_lowercase();
        states.iter().find(|(c, n)| c.to_lowercase() == t || n.to_lowercase() == t).map(|(c, _)| c.clone())
    };
    let parts: Vec<&str> = q.split(',').map(str::trim).filter(|p| !p.is_empty()).collect();
    if parts.is_empty() {
        return Query { head: String::new(), state: None, area: None };
    }
    let mut state = None;
    let mut area = None;
    for p in &parts[1..] {
        if let Some(c) = find_state(p) {
            state = Some(c);
        } else if area.is_none() {
            area = Some(p.to_string());
        }
    }
    let mut head = parts[0].to_string();
    if parts.len() == 1 {
        // "Stanley Idaho": strip a trailing state name (one to three words) or code, whatever its letter case.
        let toks: Vec<&str> = head.split_whitespace().collect();
        for take in (1..=3.min(toks.len().saturating_sub(1))).rev() {
            let tail = toks[toks.len() - take..].join(" ");
            if let Some(c) = find_state(&tail) {
                state = Some(c);
                head = toks[..toks.len() - take].join(" ");
                break;
            }
        }
    }
    Query { head, state, area }
}

/// (code, name) of every state the packs know, once each.
fn states_of(packs: &[Arc<crate::pack::Pack>]) -> Vec<(String, String)> {
    let mut states: Vec<(String, String)> = Vec::new();
    for p in packs {
        for s in &p.states {
            if !states.iter().any(|(c, _)| *c == s.code) {
                states.push((s.code.clone(), s.name.clone()));
            }
        }
    }
    states
}

fn locality_rank(kind: &str) -> f64 {
    match kind {
        "city" => 15.0,
        "town" => 10.0,
        "village" => 5.0,
        _ => 0.0,
    }
}

/// How well `name` (and its alternatives) fit the query words: 100 exact, 90 exact alternative, then partial.
fn name_score(q_norm: &str, q_words: &[String], name: &str, alts: &str) -> f64 {
    let n = norm(name);
    if n == q_norm {
        return 100.0;
    }
    if alts.split(';').any(|a| norm(a) == q_norm) || norm(alts) == q_norm {
        return 90.0;
    }
    let nw = words(name);
    if n.starts_with(q_norm) {
        return 45.0 - (nw.len().saturating_sub(q_words.len()) as f64).min(8.0);
    }
    let have = q_words.iter().filter(|w| nw.iter().any(|x| x == *w || x.starts_with(w.as_str()))).count();
    20.0 * have as f64 / q_words.len().max(1) as f64
}

/// "amenity=hospital" -> "amenity:hospital" for places that come from OSM.
pub(crate) fn osm_category(p: &PlaceRow) -> Option<String> {
    if p.source.starts_with("osm") {
        p.kind.as_ref().filter(|k| k.contains('=')).map(|k| k.replacen('=', ":", 1))
    } else {
        None
    }
}

fn place_label(p: &PlaceRow) -> String {
    let name = p.name.clone().unwrap_or_default();
    match (&p.locality, &p.state) {
        (Some(l), Some(s)) => format!("{name} ({l}, {s})"),
        (Some(l), None) => format!("{name} ({l})"),
        _ => name,
    }
}

fn town_label(l: &LocalityRow) -> String {
    match &l.state {
        Some(s) => format!("{}, {}", l.name, s),
        None => l.name.clone(),
    }
}

/// A hit whose name fits the query at least this well (`name_score`: 100 exact, 90 an exact other name, up to 45 a name that
/// starts with the query) is the place the query named. Less (a place that has one of the words in it) is not, and a town with a
/// typing slip in it then goes first.
pub(crate) const GOOD_NAME_MATCH: f64 = 40.0;

/// A hit whose whole name is the query (`name_match` 100) or whose alternative name is (90): nothing fuzzy replaces it.
pub(crate) const EXACT_NAME_MATCH: f64 = 90.0;

/// An exact house number, and one placed between its neighbours (`name_match`), and the bonus for a street that matched
/// every word of the query.
const ADDRESS_EXACT: f64 = 100.0;
const ADDRESS_PLACED: f64 = 70.0;
const ADDRESS_STREET: f64 = 60.0;
/// A street row outside the town named after the comma still counts when it is this close to that town.
const ADDRESS_AREA_KM: f64 = 15.0;
/// Street rows read per query.
const ADDRESS_ROWS: usize = 40;

impl PackGeocoder {
    /// Addresses for a query that starts with a house number ("350 N State St, Salt Lake City, UT"): the street words, every
    /// one as a prefix, against the street rows' source and expanded forms; rows filtered by the state and by the town after
    /// the comma, or in the last words when they name a town and there is no comma (its name, or within 15 km of it); rows of one street cut by a tile edge joined; then the number found, or
    /// placed between its neighbours. Empty when the query does not start with a house number or no street matches.
    fn forward_addresses(&self, query: &str, near: Option<(f64, f64)>, limit: usize) -> Vec<GeoHit> {
        let Some((number, rest)) = address::split_house_number(query) else { return Vec::new() };
        let all = self.packs.current();
        let packs: Vec<_> = all.iter().filter(|p| p.has_addresses()).collect();
        if packs.is_empty() || limit == 0 {
            return Vec::new();
        }
        let q = parse_query(rest, &states_of(&all));
        if q.area.is_none() {
            // "123 Main St Boise": a run of the last words that is a town's name is the town, as after a comma (the longest
            // run first; the street keeps at least one word). When none gives an address, the whole text is the street.
            let toks: Vec<&str> = q.head.split_whitespace().collect();
            for take in (1..=3.min(toks.len().saturating_sub(1))).rev() {
                let town = toks[toks.len() - take..].join(" ");
                if !self.is_town(&all, &town, q.state.as_deref()) {
                    continue;
                }
                let split = Query { head: toks[..toks.len() - take].join(" "), state: q.state.clone(), area: Some(town) };
                let hits = self.addresses_on(&packs, number, &split, near, limit);
                if !hits.is_empty() {
                    return hits;
                }
            }
        }
        let mut hits = self.addresses_on(&packs, number, &q, near, limit);
        if hits.is_empty() && q.state.is_some() && !rest.contains(',') {
            // A street whose last word is also a state's code ("Oak Ct", "Main St NE"): the whole text is the street.
            hits = self.addresses_on(&packs, number, &Query { head: rest.to_string(), state: None, area: None }, near, limit);
        }
        hits
    }

    fn addresses_on(&self, packs: &[&Arc<crate::pack::Pack>], number: &str, q: &Query, near: Option<(f64, f64)>, limit: usize) -> Vec<GeoHit> {
        let ws = words(&q.head);
        if ws.is_empty() {
            return Vec::new();
        }
        let expr = ws.iter().map(|w| format!("\"{}\"*", w.replace('"', ""))).collect::<Vec<_>>().join(" ");
        let mut rows = Vec::new();
        for p in packs {
            rows.extend(p.fts_streets(&expr, ADDRESS_ROWS).unwrap_or_default());
        }
        rows.retain(|r| q.state.as_ref().is_none_or(|s| r.state.as_ref().is_none_or(|rs| rs == s)));
        if let Some(area) = &q.area {
            let want = norm(area);
            let mut town: Option<Option<(f64, f64)>> = None;
            rows.retain(|r| {
                if [r.locality.as_deref(), r.postal_city.as_deref()].into_iter().flatten().any(|t| norm(t) == want) {
                    return true;
                }
                let at = *town.get_or_insert_with(|| self.area_town(area, q.state.as_deref(), near));
                at.is_some_and(|(la, lo)| haversine_km(la, lo, r.lat, r.lon) <= ADDRESS_AREA_KM)
            });
        }
        let mut hits: Vec<GeoHit> = Vec::new();
        for group in address::join(rows) {
            let Some(f) = address::find_number(&group, number) else { continue };
            let Some(r) = group.iter().find(|r| r.uid == f.uid) else { continue };
            let name = format!("{} {}", f.number, r.street);
            let town = r.town().map(str::to_string);
            let label = [Some(name.as_str()), town.as_deref(), r.state.as_deref()].into_iter().flatten().collect::<Vec<_>>().join(", ");
            let name_match = if f.approximate { ADDRESS_PLACED } else { ADDRESS_EXACT };
            let mut score = name_match + ADDRESS_STREET;
            if let Some((blat, blon)) = near {
                score += 25.0 * (-haversine_km(blat, blon, f.lat, f.lon) / 60.0).exp();
            }
            hits.push(GeoHit {
                kind: HitKind::Address,
                address: format!("addr:{}/{}", f.uid, f.number),
                name,
                label,
                lat: f.lat,
                lon: f.lon,
                locality: town,
                state: r.state.clone(),
                category: None,
                what: Some("address".into()),
                street: Some(r.street.clone()),
                county: None,
                country: r.country.clone(),
                osm_category: None,
                kind_id: Some("address".into()),
                kind_label: Some("Address".into()),
                name_match,
                score,
                approximate: f.approximate,
            });
        }
        hits.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        hits.truncate(limit);
        hits
    }

    /// Whether `name` is exactly the name of a town in the places data (in `state`, when given).
    fn is_town(&self, packs: &[Arc<crate::pack::Pack>], name: &str, state: Option<&str>) -> bool {
        let want = norm(name);
        let Some(expr) = fts_expr(&words(name), false) else { return false };
        packs.iter().any(|p| {
            p.fts_localities(&expr, 12).unwrap_or_default().into_iter().any(|(id, _)| {
                p.locality(id).ok().flatten().is_some_and(|l| norm(&l.name) == want && state.is_none_or(|s| l.state.as_deref() == Some(s)))
            })
        })
    }

    /// The town an address query names after its comma: the best town the names search finds, else the one with a typing
    /// slip in it.
    fn area_town(&self, area: &str, state: Option<&str>, near: Option<(f64, f64)>) -> Option<(f64, f64)> {
        let q = match state {
            Some(s) => format!("{area}, {s}"),
            None => area.to_string(),
        };
        self.forward_names(&q, near, 5)
            .into_iter()
            .find(|h| h.kind == HitKind::Locality && h.name_match >= GOOD_NAME_MATCH)
            .or_else(|| self.fuzzy_town(&q, near))
            .map(|h| (h.lat, h.lon))
    }

    /// The index search behind `forward`, without misspelling handling.
    fn forward_names(&self, query: &str, near: Option<(f64, f64)>, limit: usize) -> Vec<GeoHit> {
        let packs = self.packs.current();
        if packs.is_empty() || limit == 0 {
            return Vec::new();
        }
        let states = states_of(&packs);
        let q = parse_query(query, &states);
        let q_words = words(&q.head);
        let q_norm = q_words.join(" ");
        if q_words.is_empty() {
            return Vec::new();
        }

        // A town named after the comma ("Walgreens, Burley") pulls ties toward that town.
        let mut bias = near;
        if let Some(area) = &q.area {
            let aw = words(area);
            if let Some(expr) = fts_expr(&aw, false) {
                'outer: for p in &packs {
                    for (id, _) in p.fts_localities(&expr, 5).unwrap_or_default() {
                        if let Ok(Some(l)) = p.locality(id) {
                            if q.state.as_ref().is_none_or(|s| l.state.as_ref() == Some(s)) && norm(&l.name) == norm(area) {
                                bias = Some((l.lat, l.lon));
                                break 'outer;
                            }
                        }
                    }
                }
            }
        }

        let mut hits: Vec<GeoHit> = Vec::new();
        for any in [false, true] {
            if !hits.is_empty() {
                break;
            }
            if any && q_words.len() < 2 {
                break;
            }
            let Some(expr) = fts_expr(&q_words, any) else { return Vec::new() };
            for p in &packs {
                for (id, bm25) in p.fts_localities(&expr, 60).unwrap_or_default() {
                    let Ok(Some(l)) = p.locality(id) else { continue };
                    if q.state.as_ref().is_some_and(|s| l.state.as_ref() != Some(s)) {
                        continue;
                    }
                    let alts = p.alt_names(true, id).unwrap_or_default();
                    let ns = name_score(&q_norm, &q_words, &l.name, &alts);
                    // The town boost applies to a real name match only, so a town does not beat a place that fits more of the words.
                    let mut score = ns;
                    if ns >= 45.0 {
                        score += 60.0 + locality_rank(&l.kind) + 3.0 * ((l.population.unwrap_or(0) as f64) + 1.0).log10();
                    }
                    score += (-bm25).clamp(0.0, 20.0) * 0.3;
                    if let Some((blat, blon)) = bias {
                        score += 25.0 * (-haversine_km(blat, blon, l.lat, l.lon) / 60.0).exp();
                    }
                    hits.push(GeoHit {
                        kind: HitKind::Locality,
                        address: format!("town:{}", l.source_id),
                        name: l.name.clone(),
                        label: town_label(&l),
                        lat: l.lat,
                        lon: l.lon,
                        locality: Some(l.name.clone()),
                        state: l.state.clone(),
                        category: None,
                        what: Some(l.kind.clone()),
                        street: None,
                        county: l.county.clone(),
                        country: l.country.clone(),
                        osm_category: None,
                        kind_id: Some(l.kind.clone()),
                        kind_label: Some(humanize(&l.kind)),
                        name_match: ns,
                        score,
                        approximate: false,
                    });
                }
                for (id, bm25) in p.fts_places(&expr, 80).unwrap_or_default() {
                    let Ok(Some(r)) = p.place(id) else { continue };
                    let Some(name) = r.name.clone() else { continue };
                    if q.state.as_ref().is_some_and(|s| r.state.as_ref() != Some(s)) {
                        continue;
                    }
                    let alts = p.alt_names(false, id).unwrap_or_default();
                    let nm = name_score(&q_norm, &q_words, &name, &alts);
                    let mut score = nm + if r.category.is_some() { 8.0 } else { 0.0 };
                    score += (-bm25).clamp(0.0, 20.0) * 0.3;
                    if let Some((blat, blon)) = bias {
                        score += 25.0 * (-haversine_km(blat, blon, r.lat, r.lon) / 60.0).exp();
                    }
                    hits.push(GeoHit {
                        kind: HitKind::Place,
                        address: format!("place:{}", r.source_id),
                        label: place_label(&r),
                        name,
                        lat: r.lat,
                        lon: r.lon,
                        locality: r.locality.clone(),
                        state: r.state.clone(),
                        category: r.category.clone(),
                        what: r.category.clone().or_else(|| r.kind.clone()),
                        street: r.street.clone(),
                        county: r.county.clone(),
                        country: r.country.clone(),
                        osm_category: osm_category(&r),
                        kind_id: r.kind_id.clone(),
                        kind_label: r.kind_id.as_deref().map(|k| p.kind(k).map(|i| i.label.clone()).unwrap_or_else(|| humanize(k))),
                        name_match: nm,
                        score,
                        approximate: false,
                    });
                }
            }
        }

        hits.sort_by(|a, b| b.score.partial_cmp(&a.score).unwrap_or(std::cmp::Ordering::Equal));
        // The same thing in two packs, or an OSM and an Overture record of one shop, shows once.
        let mut seen: HashSet<String> = HashSet::new();
        let mut kept: Vec<GeoHit> = Vec::new();
        for h in hits {
            if !seen.insert(h.address.clone()) {
                continue;
            }
            if kept.iter().any(|k| k.kind == h.kind && norm(&k.name) == norm(&h.name) && haversine_km(k.lat, k.lon, h.lat, h.lon) < 0.3) {
                continue;
            }
            kept.push(h);
            if kept.len() >= limit {
                break;
            }
        }
        kept
    }

    /// The town whose name is the query with a typing slip in it (`forward_names` finds names, words and prefixes, not
    /// misspellings). Compared by edit distance (see `slip_allowed`), so nothing depends on the language. `None` when no town is
    /// that close.
    fn fuzzy_town(&self, query: &str, near: Option<(f64, f64)>) -> Option<GeoHit> {
        let packs = self.packs.current();
        if packs.is_empty() {
            return None;
        }
        let states = states_of(&packs);
        let q = parse_query(query, &states);
        let want: Vec<char> = norm(&q.head).chars().collect();
        let allowed = slip_allowed(want.len());
        if allowed == 0 {
            return None;
        }
        // (edits, locality), the fewest edits first; a tie goes to the town nearer `near`, then to the one with more people
        let mut best: Option<(usize, LocalityRow)> = None;
        for p in &packs {
            for (id, name) in p.locality_names().unwrap_or_default() {
                let have: Vec<char> = norm(&name).chars().collect();
                if have.len().abs_diff(want.len()) > allowed {
                    continue;
                }
                let e = edit_distance(&want, &have);
                if e == 0 || e > allowed {
                    continue; // an exact name is `forward`'s business
                }
                let Ok(Some(l)) = p.locality(id) else { continue };
                if q.state.as_ref().is_some_and(|s| l.state.as_ref() != Some(s)) {
                    continue;
                }
                let better = match &best {
                    None => true,
                    Some((be, bl)) => {
                        let (pop, bpop) = (l.population.unwrap_or(0), bl.population.unwrap_or(0));
                        let dist = |x: &LocalityRow| near.map(|(la, lo)| haversine_km(la, lo, x.lat, x.lon)).unwrap_or(0.0);
                        let (dl, db) = (dist(&l), dist(bl));
                        e < *be || (e == *be && (dl < db - 1e-6 || ((dl - db).abs() <= 1e-6 && pop > bpop)))
                    }
                };
                if better {
                    best = Some((e, l));
                }
            }
        }
        let (e, l) = best?;
        Some(GeoHit {
            kind: HitKind::Locality,
            address: format!("town:{}", l.source_id),
            name: l.name.clone(),
            label: town_label(&l),
            lat: l.lat,
            lon: l.lon,
            locality: Some(l.name.clone()),
            state: l.state.clone(),
            category: None,
            what: Some(l.kind.clone()),
            street: None,
            county: l.county.clone(),
            country: l.country.clone(),
            osm_category: None,
            kind_id: Some(l.kind.clone()),
            kind_label: Some(humanize(&l.kind)),
            name_match: 100.0 - 10.0 * e as f64,
            score: 0.0,
            approximate: false,
        })
    }
}

impl Geocoder for PackGeocoder {
    /// Names, words and prefixes through the index, plus the town whose whole name is the query with a typing slip in it
    /// ("Islnd Park", "Bosie", "Amon" for Ammon). This is the one resolver `navigate`, `locate` and `live_data` all go
    /// through, so they treat a misspelling alike. Ranked by how the name matches, then class, then people: an exact
    /// whole name (a place or a town, `name_match` 90 or more) beats a whole-name slip of at most `slip_allowed` edits, and that
    /// beats a place whose name only starts with the query or has some of its words (`name_match` under 90). A town that
    /// starts with the query (a partial name typed) is kept ahead of a slip.
    ///
    /// A query that starts with a house number and names a street on the phone gives its addresses first, then the rest.
    fn forward(&self, query: &str, near: Option<(f64, f64)>, limit: usize) -> Vec<GeoHit> {
        let addresses = self.forward_addresses(query, near, limit);
        let mut hits = self.forward_names(query, near, limit);
        if limit > 0 && !hits.iter().any(|h| h.name_match >= EXACT_NAME_MATCH) {
            let town_prefix = hits.iter().any(|h| h.kind == HitKind::Locality && h.name_match >= GOOD_NAME_MATCH);
            if !town_prefix {
                if let Some(f) = self.fuzzy_town(query, near) {
                    hits.retain(|h| h.address != f.address);
                    hits.insert(0, f);
                    hits.truncate(limit);
                }
            }
        }
        if !addresses.is_empty() {
            let mut out = addresses;
            out.extend(hits);
            out.truncate(limit);
            return out;
        }
        hits
    }

    fn reverse(&self, lat: f64, lon: f64) -> Option<Nearest> {
        let packs = self.packs.current();
        let mut best: Option<(LocalityRow, f64)> = None;
        let mut best_hamlet: Option<(LocalityRow, f64)> = None;
        for p in &packs {
            for radius in [25.0, 80.0, 250.0] {
                let found = p.localities_near(lat, lon, radius).unwrap_or_default();
                if found.is_empty() {
                    continue;
                }
                for (l, km) in found {
                    let slot = if l.kind == "hamlet" { &mut best_hamlet } else { &mut best };
                    if slot.as_ref().is_none_or(|(_, k)| km < *k) {
                        *slot = Some((l, km));
                    }
                }
                if best.is_some() {
                    break;
                }
            }
        }
        let (l, km) = match (best, best_hamlet) {
            (Some(b), Some(h)) => {
                // A hamlet counts when it is close; a real town wins unless it is far.
                if h.1 + 3.0 < b.1 && h.1 < 3.0 { h } else { b }
            }
            (Some(b), None) => b,
            (None, Some(h)) => h,
            (None, None) => return None,
        };
        Some(Nearest { label: town_label(&l), bearing: bearing_deg(lat, lon, l.lat, l.lon), name: l.name, state: l.state, km })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn st() -> Vec<(String, String)> {
        vec![("ID".into(), "Idaho".into()), ("OR".into(), "Oregon".into())]
    }

    #[test]
    fn query_with_commas() {
        let q = parse_query("Stanley, Idaho", &st());
        assert_eq!((q.head.as_str(), q.state.as_deref(), q.area), ("Stanley", Some("ID"), None));
        let q = parse_query("Walgreens, Burley, ID", &st());
        assert_eq!((q.head.as_str(), q.state.as_deref(), q.area.as_deref()), ("Walgreens", Some("ID"), Some("Burley")));
    }

    #[test]
    fn query_with_trailing_state() {
        let q = parse_query("Stanley Idaho", &st());
        assert_eq!((q.head.as_str(), q.state.as_deref()), ("Stanley", Some("ID")));
        let q = parse_query("Burley ID", &st());
        assert_eq!((q.head.as_str(), q.state.as_deref()), ("Burley", Some("ID")));
        // The letter case of a state does not matter: "rupert id" is "Rupert ID".
        for t in ["rupert id", "Rupert ID", "RUPERT Id", "rupert idaho", "rupert IDAHO"] {
            let q = parse_query(t, &st());
            assert_eq!((q.head.to_lowercase().as_str(), q.state.as_deref()), ("rupert", Some("ID")), "{t}");
        }
        let q = parse_query("Rupert, id", &st());
        assert_eq!((q.head.as_str(), q.state.as_deref()), ("Rupert", Some("ID")));
        // A state in the middle is a word.
        let q = parse_query("war or peace", &st());
        assert_eq!((q.head.as_str(), q.state.as_deref()), ("war or peace", None));
        // A name that is only a state stays a name.
        let q = parse_query("Idaho", &st());
        assert_eq!((q.head.as_str(), q.state.as_deref()), ("Idaho", None));
    }

    #[test]
    fn edit_distance_counts_insert_delete_replace_and_swap() {
        let d = |a: &str, b: &str| edit_distance(&a.chars().collect::<Vec<_>>(), &b.chars().collect::<Vec<_>>());
        assert_eq!(d("island park", "island park"), 0);
        assert_eq!(d("islnd park", "island park"), 1);
        assert_eq!(d("ilsand park", "island park"), 1);
        assert_eq!(d("island parc", "island park"), 1);
        assert_eq!(d("bosie", "boise"), 1);
        assert_eq!(d("", "abc"), 3);
        assert_eq!(d("kitten", "sitting"), 3);
        assert_eq!(slip_allowed(3), 0);
        assert_eq!(slip_allowed(4), 1);
        assert_eq!(slip_allowed(9), 1);
        assert_eq!(slip_allowed(10), 2);
    }

    #[test]
    fn fts_expression() {
        let w = words("Cassia Reg");
        assert_eq!(fts_expr(&w, false).unwrap(), "\"cassia\" \"reg\"*");
        assert_eq!(fts_expr(&w, true).unwrap(), "\"cassia\" OR \"reg\"*");
    }
}
