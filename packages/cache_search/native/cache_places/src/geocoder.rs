//! The offline geocoder: forward search by name (SQLite FTS5 plus a boost for towns, so a bare town name finds the
//! town and not a school named after it) and reverse lookup of the nearest town.
//!
//! `Geocoder` is the trait the tools use. cache_tool has no geocoder trait yet, so this minimal one lives here; it can
//! move to cache_tool unchanged.

use crate::geo::{bearing_deg, haversine_km};
use crate::pack::{LocalityRow, PackSet, PlaceRow};
use std::collections::HashSet;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HitKind {
    Locality,
    Place,
}

/// One forward-search result.
#[derive(Debug, Clone)]
pub struct GeoHit {
    pub kind: HitKind,
    /// Stable id for numbering: `place:<source id>` or `town:<source id>`.
    pub address: String,
    pub name: String,
    /// How to show it: `Stanley, ID` for a town, the name for a place.
    pub label: String,
    pub lat: f64,
    pub lon: f64,
    pub locality: Option<String>,
    pub state: Option<String>,
    pub category: Option<String>,
    pub score: f64,
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
/// states and town names in the packs; a trailing full state name or an upper-case two-letter code also counts.
fn parse_query(q: &str, states: &[(String, String)]) -> Query {
    let find_state = |s: &str| -> Option<String> {
        let t = s.trim();
        states.iter().find(|(c, n)| c.eq_ignore_ascii_case(t) || n.eq_ignore_ascii_case(t)).map(|(c, _)| c.clone())
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
        // "Stanley Idaho": strip a trailing state name (one to three words) or an upper-case code.
        let toks: Vec<&str> = head.split_whitespace().collect();
        for take in (1..=3.min(toks.len().saturating_sub(1))).rev() {
            let tail = toks[toks.len() - take..].join(" ");
            let is_code = take == 1 && tail.len() == 2 && tail.chars().all(|c| c.is_ascii_uppercase());
            let is_name = states.iter().any(|(_, n)| n.eq_ignore_ascii_case(&tail));
            if is_code || is_name {
                if let Some(c) = find_state(&tail) {
                    state = Some(c);
                    head = toks[..toks.len() - take].join(" ");
                    break;
                }
            }
        }
    }
    Query { head, state, area }
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

impl Geocoder for PackGeocoder {
    fn forward(&self, query: &str, near: Option<(f64, f64)>, limit: usize) -> Vec<GeoHit> {
        let packs = self.packs.current();
        if packs.is_empty() || limit == 0 {
            return Vec::new();
        }
        let mut states: Vec<(String, String)> = Vec::new();
        for p in &packs {
            for s in &p.states {
                if !states.iter().any(|(c, _)| *c == s.code) {
                    states.push((s.code.clone(), s.name.clone()));
                }
            }
        }
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
                        score,
                    });
                }
                for (id, bm25) in p.fts_places(&expr, 80).unwrap_or_default() {
                    let Ok(Some(r)) = p.place(id) else { continue };
                    let Some(name) = r.name.clone() else { continue };
                    if q.state.as_ref().is_some_and(|s| r.state.as_ref() != Some(s)) {
                        continue;
                    }
                    let alts = p.alt_names(false, id).unwrap_or_default();
                    let mut score = name_score(&q_norm, &q_words, &name, &alts) + if r.category.is_some() { 8.0 } else { 0.0 };
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
                        score,
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
        // Lower-case "or" and "id" are words, not states.
        let q = parse_query("war or peace", &st());
        assert_eq!((q.head.as_str(), q.state.as_deref()), ("war or peace", None));
        // A name that is only a state stays a name.
        let q = parse_query("Idaho", &st());
        assert_eq!((q.head.as_str(), q.state.as_deref()), ("Idaho", None));
    }

    #[test]
    fn fts_expression() {
        let w = words("Cassia Reg");
        assert_eq!(fts_expr(&w, false).unwrap(), "\"cassia\" \"reg\"*");
        assert_eq!(fts_expr(&w, true).unwrap(), "\"cassia\" OR \"reg\"*");
    }
}
