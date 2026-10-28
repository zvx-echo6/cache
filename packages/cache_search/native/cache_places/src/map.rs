//! The map's search box (`cs_map_search`): one input that takes a place name, a category, coordinates in any supported
//! format, or a free-text meaning ("somewhere to get water"), and returns ranked results the map can draw and route to.
//!
//! How a query is read, in order:
//!  1. Coordinates (decimal, degrees-minutes-seconds, USNG / MGRS, Plus Codes): a single `coordinates` result with the point
//!     in every format. A short Plus Code ("CWC8+R9") is completed from the map centre.
//!  2. Otherwise text. A run of its words that is exactly the name of a town or city in the pack (`pharmacy near Burley`) is
//!     the *anchor*: the results are ranked by distance from there, not from the map centre.
//!  3. Names: the offline geocoder (FTS5 with a boost for towns) on the whole text, and on what is left of it after the anchor.
//!  4. Categories: the words are matched against the pack's category ids, titles and descriptions (words that appear in many
//!     categories count for less). A matching category gives a `category` row and its nearest places.
//!  5. Meaning: when the pack carries vectors (`places_pack embed`) and a query vector of the same model is given or can be
//!     made (the host's embedder), the query is compared with the category texts, the kind texts (a merged database) and
//!     the name-and-summary texts of places and towns. A matching kind gives a `kind:<id>` row and its nearest places.
//!     Without either, this step is skipped and the answer says so (`meaning`: "no_embedder" or "no_vectors").
//!
//! A query that starts with a house number can also give addresses (the geocoder's address search, step 3).
//! The answer says what places the phone has for the search (`places`, `warning_code`: see `feed::places_state`).
//!
//! Ranking: `score = 0.7 * relevance + 0.3 * closeness`, where closeness is `exp(-km / 25)` from the anchor, else the map
//! centre or GPS fix (0.5 when neither is known). Relevance is the name match (0..1), the category match (0..1, a little
//! under a name match) or the vector cosine mapped from the model's useful range onto 0..1.
//!
//! Every result carries an `id` (`place:<source id>`, `town:<source id>`, `addr:<uid>/<number>`, `loc:<lat>,<lon>`,
//! `category:<id>`, `kind:<id>`); the route call accepts all but `category:` as an end.

use crate::address;
use crate::coord::{self, Parsed};
use crate::feed::{places_state, PlacesFeed, PrepareAnswer};
use crate::geo::{bearing_deg, compass8, dms, haversine_km, round_to};
use crate::geocoder::{GeoHit, Geocoder, HitKind};
use crate::kind::{humanize, kind_of};
use crate::nearby::ranked;
use crate::pack::{Category, LocalityRow, Pack, PackSet, PlaceRow};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, RwLock};

/// Cosine range of bge-m3 for short texts: below LOW is noise, HIGH is a near-paraphrase.
const COS_LOW: f32 = 0.30;
const COS_HIGH: f32 = 0.70;
/// A category is a meaning match when its cosine is at least this and within `COS_MARGIN` of the best category.
const COS_CATEGORY: f32 = 0.50;
const COS_MARGIN: f32 = 0.06;
/// How many kinds the meaning step compares closely (a kind matches like a category: `COS_CATEGORY`, `COS_MARGIN`).
const KIND_TOP: usize = 8;
/// A place or town is a meaning match at this cosine.
const COS_PLACE: f32 = 0.50;
/// A category matches the words when its keyword strength reaches this (title words count 1, description words 0.5).
const KEYWORD_CATEGORY: f64 = 0.4;
/// Weight of relevance against closeness, and the distance scale of closeness.
const W_RELEVANCE: f64 = 0.7;
const CLOSE_KM: f64 = 25.0;
/// Names that fit the words less than this are dropped when categories or meaning already answered the query.
const NAME_FLOOR: f64 = 30.0;

pub struct SearchOpts {
    /// The map centre or GPS fix: results report distance and direction from it.
    pub near: Option<(f64, f64)>,
    pub limit: usize,
    /// Run the meaning step (needs vectors in the pack and an embedder or a given query vector).
    pub meaning: bool,
    /// The query as the host's embedder made it: the model id and the vector.
    pub vector: Option<(String, Vec<f32>)>,
    /// What the places feed did around `near` just before the search (None when it was not asked).
    pub prepared: Option<PrepareAnswer>,
}

impl Default for SearchOpts {
    fn default() -> Self {
        SearchOpts { near: None, limit: 10, meaning: true, vector: None, prepared: None }
    }
}

/// The host's query embedder: model id and vector, or None when it cannot embed.
pub type Embed<'a> = &'a dyn Fn(&str) -> Option<(String, Vec<f32>)>;

/// An end of a route as the places side resolved it.
#[derive(Debug, Clone)]
pub struct Endpoint {
    pub id: Option<String>,
    pub name: Option<String>,
    pub lat: f64,
    pub lon: f64,
    pub osm_category: Option<String>,
}

#[derive(Debug, Clone)]
pub struct MapError {
    pub code: &'static str,
    pub message: String,
}

fn bad(m: impl Into<String>) -> MapError {
    MapError { code: "bad_json", message: m.into() }
}

pub struct PlacesCore {
    pub packs: Arc<PackSet>,
    pub geo: Arc<dyn Geocoder>,
    /// Plugged in by the search host (the regions engine): fetches places tiles before a search.
    feed: RwLock<Option<Arc<dyn PlacesFeed>>>,
}

// ---- words -----------------------------------------------------------------------------------------------------------

fn words(s: &str) -> Vec<String> {
    s.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(|w| w.to_lowercase()).collect()
}

/// A word with a plural folded away ("pharmacies" and "pharmacy", "stations" and "station").
fn stem(w: &str) -> String {
    if w.len() > 4 && w.ends_with("ies") {
        format!("{}y", &w[..w.len() - 3])
    } else if w.len() > 3 && w.ends_with("es") && (w.ends_with("ses") || w.ends_with("xes") || w.ends_with("ches") || w.ends_with("shes")) {
        w[..w.len() - 2].to_string()
    } else if w.len() > 3 && w.ends_with('s') && !w.ends_with("ss") {
        w[..w.len() - 1].to_string()
    } else {
        w.to_string()
    }
}

fn stems(s: &str) -> Vec<String> {
    words(s).iter().map(|w| stem(w)).collect()
}

fn norm(s: &str) -> String {
    words(s).join(" ")
}

// ---- results ---------------------------------------------------------------------------------------------------------

struct Cand {
    id: String,
    kind_t: &'static str,
    name: String,
    /// For display: the kind's label when the place has one, else the category's title or the raw type, humanized.
    kind: String,
    /// The pack's kind id and label (`drinking_water`, "Drinking water tap"); a town's size (`town`, "Town").
    kind_id: Option<String>,
    kind_label: Option<String>,
    /// The place has no name in the pack; `name` is then its kind's label.
    unnamed: bool,
    category: Option<String>,
    street: Option<String>,
    locality: Option<String>,
    county: Option<String>,
    state: Option<String>,
    lat: f64,
    lon: f64,
    phone: Option<String>,
    hours: Option<String>,
    website: Option<String>,
    summary: Option<String>,
    wikipedia_title: Option<String>,
    wikidata_id: Option<String>,
    rel: f64,
    matched: &'static str,
    /// An address whose number was placed between its neighbours.
    approximate: bool,
}

fn cat_title(packs: &[Arc<Pack>], id: &str) -> Option<String> {
    packs.iter().find_map(|p| p.category(id)).map(|c| c.title.clone())
}

fn cand_place(packs: &[Arc<Pack>], r: &PlaceRow, rel: f64, matched: &'static str) -> Cand {
    let own = kind_of(packs, r);
    let kind = own
        .as_ref()
        .map(|k| k.1.clone())
        .or_else(|| r.category.as_deref().and_then(|c| cat_title(packs, c)))
        .or_else(|| r.kind.as_deref().map(humanize))
        .unwrap_or_else(|| "Place".into());
    let named = r.name.as_deref().map(str::trim).filter(|n| !n.is_empty()).map(str::to_string);
    Cand {
        id: format!("place:{}", r.source_id),
        kind_t: "place",
        unnamed: named.is_none(),
        name: named.unwrap_or_else(|| kind.clone()),
        kind,
        kind_id: own.as_ref().map(|k| k.0.clone()),
        kind_label: own.map(|k| k.1),
        category: r.category.clone(),
        street: r.street.clone(),
        locality: r.locality.clone(),
        county: r.county.clone(),
        state: r.state.clone(),
        lat: r.lat,
        lon: r.lon,
        phone: r.phone.clone(),
        hours: r.hours.clone(),
        website: r.website.clone(),
        summary: r.summary.clone(),
        wikipedia_title: r.wikipedia_title.clone(),
        wikidata_id: r.wikidata_id.clone(),
        rel,
        matched,
        approximate: false,
    }
}

fn cand_town(l: &LocalityRow, rel: f64, matched: &'static str) -> Cand {
    Cand {
        id: format!("town:{}", l.source_id),
        kind_t: "town",
        name: l.name.clone(),
        kind: humanize(&l.kind),
        kind_id: Some(l.kind.clone()),
        kind_label: Some(humanize(&l.kind)),
        unnamed: false,
        category: None,
        street: None,
        locality: Some(l.name.clone()),
        county: l.county.clone(),
        state: l.state.clone(),
        lat: l.lat,
        lon: l.lon,
        phone: None,
        hours: None,
        website: None,
        summary: l.summary.clone(),
        wikipedia_title: l.wikipedia_title.clone(),
        wikidata_id: None,
        rel,
        matched,
        approximate: false,
    }
}

/// An address hit as a result: its `street` is the house number and street, so its address reads "350 N State St, Salt
/// Lake City, UT".
fn cand_address(h: &GeoHit, rel: f64) -> Cand {
    Cand {
        id: h.address.clone(),
        kind_t: "address",
        name: h.name.clone(),
        kind: "Address".into(),
        kind_id: Some("address".into()),
        kind_label: Some("Address".into()),
        unnamed: false,
        category: None,
        street: Some(h.name.clone()),
        locality: h.locality.clone(),
        county: None,
        state: h.state.clone(),
        lat: h.lat,
        lon: h.lon,
        phone: None,
        hours: None,
        website: None,
        summary: None,
        wikipedia_title: None,
        wikidata_id: None,
        rel,
        matched: "name",
        approximate: h.approximate,
    }
}

fn address_of(c: &Cand) -> String {
    if c.kind_t == "town" {
        return [c.county.as_deref(), c.state.as_deref()].iter().flatten().cloned().collect::<Vec<_>>().join(", ");
    }
    [c.street.as_deref(), c.locality.as_deref(), c.state.as_deref()].iter().flatten().cloned().collect::<Vec<_>>().join(", ")
}

fn put(m: &mut Map<String, Value>, k: &str, v: &Option<String>) {
    if let Some(v) = v.as_ref().filter(|v| !v.is_empty()) {
        m.insert(k.into(), json!(v));
    }
}

fn from_near(near: Option<(f64, f64)>, lat: f64, lon: f64, m: &mut Map<String, Value>) {
    if let Some((nl, no)) = near {
        m.insert("distance_m".into(), json!((haversine_km(nl, no, lat, lon) * 1000.0).round() as i64));
        m.insert("direction".into(), json!(compass8(bearing_deg(nl, no, lat, lon))));
        m.insert("bearing_deg".into(), json!(bearing_deg(nl, no, lat, lon).round() as i64 % 360));
    }
}

fn cand_json(c: &Cand, near: Option<(f64, f64)>, score: f64) -> Value {
    let mut m = Map::new();
    m.insert("id".into(), json!(c.id));
    m.insert("type".into(), json!(c.kind_t));
    m.insert("name".into(), json!(c.name));
    m.insert("kind".into(), json!(c.kind));
    put(&mut m, "kind_id", &c.kind_id);
    put(&mut m, "kind_label", &c.kind_label);
    if c.unnamed {
        m.insert("unnamed".into(), json!(true));
    }
    if c.approximate {
        m.insert("approximate".into(), json!(true));
    }
    m.insert("category".into(), json!(c.category));
    m.insert("address".into(), json!(address_of(c)));
    m.insert("lat".into(), json!(round_to(c.lat, 6)));
    m.insert("lon".into(), json!(round_to(c.lon, 6)));
    from_near(near, c.lat, c.lon, &mut m);
    m.insert("matched".into(), json!(c.matched));
    m.insert("score".into(), json!(round_to(score, 3)));
    put(&mut m, "phone", &c.phone);
    put(&mut m, "hours", &c.hours);
    put(&mut m, "website", &c.website);
    put(&mut m, "summary", &c.summary);
    put(&mut m, "wikipedia_title", &c.wikipedia_title);
    put(&mut m, "wikidata_id", &c.wikidata_id);
    Value::Object(m)
}

/// The point in every format the map shows, and the nearest town in words.
pub fn coordinates_json(core: &PlacesCore, lat: f64, lon: f64, near: Option<(f64, f64)>, parsed: Option<&Parsed>) -> Value {
    let mut formats = Map::new();
    formats.insert("decimal".into(), json!(format!("{:.5}, {:.5}", lat, lon)));
    formats.insert("dms".into(), json!(dms(lat, lon)));
    if let Some(u) = coord::usng(lat, lon) {
        formats.insert("usng".into(), json!(u));
    }
    if let Some(p) = coord::plus_code(lat, lon) {
        formats.insert("plus_code".into(), json!(p));
    }
    let mut m = Map::new();
    m.insert("id".into(), json!(format!("loc:{:.6},{:.6}", lat, lon)));
    m.insert("type".into(), json!("coordinates"));
    m.insert("name".into(), json!(format!("{:.5}, {:.5}", lat, lon)));
    m.insert("kind".into(), json!("Coordinates"));
    m.insert("category".into(), Value::Null);
    let town = core.geo.reverse(lat, lon);
    m.insert(
        "address".into(),
        json!(town
            .as_ref()
            .map(|t| format!("{} mi {} of {}", round_to(t.km / crate::geo::KM_PER_MI, 1), compass8((t.bearing + 180.0) % 360.0), t.label))
            .unwrap_or_default()),
    );
    m.insert("lat".into(), json!(round_to(lat, 6)));
    m.insert("lon".into(), json!(round_to(lon, 6)));
    from_near(near, lat, lon, &mut m);
    m.insert("matched".into(), json!("coordinates"));
    m.insert("score".into(), json!(1.0));
    if let Some(p) = parsed {
        m.insert("format".into(), json!(p.format));
        m.insert("precision_m".into(), json!(round_to(p.precision_m, 1)));
    }
    m.insert("formats".into(), Value::Object(formats));
    Value::Object(m)
}

// ---- categories ------------------------------------------------------------------------------------------------------

struct CatVocab {
    /// stem -> how many categories mention it (title, id or description)
    df: HashMap<String, usize>,
}

fn all_categories(packs: &[Arc<Pack>]) -> Vec<Category> {
    let mut seen: HashSet<String> = HashSet::new();
    let mut out = Vec::new();
    for p in packs {
        for c in &p.categories {
            if c.place_count > 0 && seen.insert(c.id.clone()) {
                out.push(c.clone());
            }
        }
    }
    out
}

fn cat_vocab(cats: &[Category]) -> CatVocab {
    let mut df: HashMap<String, usize> = HashMap::new();
    for c in cats {
        let mut set: HashSet<String> = HashSet::new();
        set.extend(stems(&c.id));
        set.extend(stems(&c.title));
        set.extend(stems(&c.description));
        for w in set {
            *df.entry(w).or_default() += 1;
        }
    }
    CatVocab { df }
}

/// How well the query words fit a category: title and id words count 1, description words 0.5, each weighted by how few
/// categories use the word. A word no category uses (a place name, filler) still counts, a little, against the match, so a
/// long sentence with one category word in it is not a category search; words of one or two letters are not matched.
fn keyword_strength(q: &[String], c: &Category, v: &CatVocab) -> f64 {
    const UNKNOWN: f64 = 0.3;
    let head: HashSet<String> = stems(&c.id).into_iter().chain(stems(&c.title)).collect();
    let desc: HashSet<String> = stems(&c.description).into_iter().collect();
    let (mut got, mut all) = (0.0, 0.0);
    for w in q {
        if w.chars().count() < 3 {
            continue;
        }
        let Some(df) = v.df.get(w) else {
            all += UNKNOWN;
            continue;
        };
        let weight = 1.0 / *df as f64;
        all += weight;
        if head.contains(w) {
            got += weight;
        } else if desc.contains(w) {
            got += 0.5 * weight;
        }
    }
    if all == 0.0 { 0.0 } else { got / all }
}

// ---- the search ------------------------------------------------------------------------------------------------------

impl PlacesCore {
    pub fn new(cfg: &crate::PlacesCfg) -> PlacesCore {
        let packs = Arc::new(PackSet::new(cfg.packs.iter().map(std::path::PathBuf::from).collect()));
        let geo: Arc<dyn Geocoder> = Arc::new(crate::PackGeocoder::new(packs.clone()));
        PlacesCore { packs, geo, feed: RwLock::new(None) }
    }

    /// Plugs in the feed that fetches places tiles (replacing any before it).
    pub fn plug_feed(&self, feed: Arc<dyn PlacesFeed>) {
        *self.feed.write().unwrap_or_else(|e| e.into_inner()) = Some(feed);
    }

    /// The plugged-in feed, if any.
    pub fn feed(&self) -> Option<Arc<dyn PlacesFeed>> {
        self.feed.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The town, city or village whose name is exactly a run of the query's words (the longest run; the bigger kind of place
    /// and the bigger town win a tie), with the words that are left. A run that is the whole query is a name, not an anchor,
    /// and a run made only of words the categories use ("water") is not a place name here.
    fn anchor(&self, packs: &[Arc<Pack>], q: &str, vocab: &CatVocab) -> Option<(LocalityRow, String)> {
        let toks: Vec<&str> = q.split(|c: char| c.is_whitespace() || c == ',').filter(|t| !t.is_empty()).collect();
        if toks.len() < 2 {
            return None;
        }
        let rank = |kind: &str| match kind {
            "city" => 3,
            "town" => 2,
            "village" => 1,
            _ => 0,
        };
        let mut best: Option<(usize, i32, i64, LocalityRow, String)> = None;
        for len in (1..=3.min(toks.len() - 1)).rev() {
            for start in 0..=(toks.len() - len) {
                let span = toks[start..start + len].join(" ");
                let span_norm = norm(&span);
                let ws = words(&span);
                if span_norm.is_empty() || ws.iter().all(|w| vocab.df.contains_key(&stem(w))) {
                    continue;
                }
                let expr = ws.iter().map(|w| format!("\"{}\"", w.replace('"', ""))).collect::<Vec<_>>().join(" ");
                for p in packs {
                    for (id, _) in p.fts_localities(&expr, 12).unwrap_or_default() {
                        let Ok(Some(l)) = p.locality(id) else { continue };
                        if norm(&l.name) != span_norm {
                            continue;
                        }
                        let (k, pop) = (rank(&l.kind), l.population.unwrap_or(0));
                        let rest: Vec<&str> = toks[..start].iter().chain(toks[start + len..].iter()).copied().collect();
                        if best.as_ref().is_none_or(|(bl, bk, bp, _, _)| (len, k, pop) > (*bl, *bk, *bp)) {
                            best = Some((len, k, pop, l, rest.join(" ")));
                        }
                    }
                }
            }
            if best.is_some() {
                break;
            }
        }
        // "Stanley ID" names a town and its state: the geocoder reads that as one name, so there is no anchor
        best.filter(|(_, _, _, _, rest)| {
            let r = norm(rest);
            r.is_empty() || !packs.iter().any(|p| p.states.iter().any(|s| norm(&s.code) == r || norm(&s.name) == r))
        })
        .map(|(_, _, _, l, rest)| (l, rest))
    }

    /// One query. `embed` makes the query vector when `opts` has none and the pack has vectors.
    pub fn search(&self, query: &str, opts: &SearchOpts, embed: Option<Embed>) -> Result<Value, MapError> {
        let q = query.trim();
        let packs = self.packs.current();
        let limit = opts.limit.clamp(1, 30);
        let mut out = Map::new();
        out.insert("query".into(), json!(q));
        out.insert("near".into(), opts.near.map(|(la, lo)| json!({"lat": la, "lon": lo})).unwrap_or(Value::Null));
        if q.is_empty() {
            out.insert("interpreted".into(), json!({"kind": "empty"}));
            out.insert("meaning".into(), json!("off"));
            out.insert("results".into(), json!([]));
            return Ok(Value::Object(out));
        }

        // 1. coordinates (a short Plus Code followed by a town name takes that town as its reference)
        let mut parsed = coord::parse(q, opts.near);
        if parsed.is_none() {
            if let Some((code, town)) = q.split_once(char::is_whitespace) {
                if code.contains('+') && !town.trim().is_empty() {
                    let reference = self.geo.forward(town.trim(), opts.near, 1).into_iter().next().map(|h| (h.lat, h.lon));
                    parsed = coord::parse_plus_code(code, reference);
                }
            }
        }
        if let Some(p) = parsed {
            out.insert("interpreted".into(), json!({"kind": "coordinates", "format": p.format}));
            out.insert("meaning".into(), json!("off"));
            out.insert("results".into(), json!([coordinates_json(self, p.lat, p.lon, opts.near, Some(&p))]));
            return Ok(Value::Object(out));
        }
        let (places, warning_code) = places_state(&packs, opts.near, opts.prepared.as_ref());
        let installed = places["installed"].as_bool().unwrap_or(false);
        out.insert("places".into(), places);
        if let Some(code) = warning_code {
            out.insert("warning_code".into(), json!(code));
        }
        if !installed {
            out.insert("interpreted".into(), json!({"kind": "text"}));
            out.insert("meaning".into(), json!("off"));
            out.insert("results".into(), json!([]));
            out.insert("warning".into(), json!("no places data is installed"));
            return Ok(Value::Object(out));
        }

        // 2. an anchor town
        let cats = all_categories(&packs);
        let vocab = cat_vocab(&cats);
        let anchor = self.anchor(&packs, q, &vocab);
        let rest = anchor.as_ref().map(|(_, r)| r.clone());
        let centre = anchor.as_ref().map(|(l, _)| (l.lat, l.lon)).or(opts.near);
        let q_words = stems(rest.as_deref().unwrap_or(q));

        let mut cands: Vec<Cand> = Vec::new();
        let mut cat_rows: Vec<(Category, f64, &'static str)> = Vec::new();
        let mut kind_rows: Vec<(crate::pack::KindInfo, f64)> = Vec::new();

        // 4. categories by keyword
        for c in &cats {
            let s = keyword_strength(&q_words, c, &vocab);
            if s >= KEYWORD_CATEGORY {
                cat_rows.push((c.clone(), s.min(1.0), "category"));
            }
        }

        // 5. meaning
        let mut meaning = if opts.meaning { "no_vectors" } else { "off" };
        let mut meaning_places: Vec<(Cand, f64)> = Vec::new();
        let with_vectors: Vec<&Arc<Pack>> = if opts.meaning { packs.iter().filter(|p| p.embedding().is_some()).collect() } else { Vec::new() };
        if !with_vectors.is_empty() {
            let have = opts
                .vector
                .clone()
                .or_else(|| embed.and_then(|e| e(rest.as_deref().filter(|r| !r.trim().is_empty()).unwrap_or(q))));
            match have {
                None => meaning = "no_embedder",
                Some((model, vec)) => {
                    let norm_q = vec.iter().map(|x| x * x).sum::<f32>().sqrt().max(1e-12);
                    let qv: Vec<f32> = vec.iter().map(|x| x / norm_q).collect();
                    let mut ran = false;
                    let mut mismatch = false;
                    let mut cat_hits: Vec<(String, f32)> = Vec::new();
                    let mut kind_hits: Vec<(String, f32)> = Vec::new();
                    for p in &with_vectors {
                        let (pm, dims) = p.embedding().expect("filtered");
                        if pm != model || dims != qv.len() {
                            mismatch = true;
                            continue;
                        }
                        ran = true;
                        cat_hits.extend(p.vector_scan("category", &qv, 6).unwrap_or_default());
                        kind_hits.extend(p.vector_scan("kind", &qv, KIND_TOP).unwrap_or_default());
                        for (kind, top) in [("place", 8usize), ("locality", 4usize)] {
                            for (rid, cos) in p.vector_scan(kind, &qv, top).unwrap_or_default() {
                                if cos < COS_PLACE {
                                    continue;
                                }
                                let Ok(id) = rid.parse::<i64>() else { continue };
                                let rel = (((cos - COS_LOW) / (COS_HIGH - COS_LOW)).clamp(0.0, 1.0) as f64) * 0.9;
                                if kind == "place" {
                                    if let Ok(Some(r)) = p.place(id) {
                                        meaning_places.push((cand_place(&packs, &r, rel, "meaning"), cos as f64));
                                    }
                                } else if let Ok(Some(l)) = p.locality(id) {
                                    meaning_places.push((cand_town(&l, rel, "meaning"), cos as f64));
                                }
                            }
                        }
                    }
                    meaning = if ran { "used" } else if mismatch { "model_mismatch" } else { "no_vectors" };
                    cat_hits.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
                    if let Some(best) = cat_hits.first().map(|h| h.1) {
                        let mut taken: HashSet<String> = HashSet::new();
                        for (id, cos) in cat_hits {
                            if cos >= COS_CATEGORY && cos >= best - COS_MARGIN && taken.insert(id.clone()) {
                                if let Some(c) = cats.iter().find(|c| c.id == id) {
                                    let rel = (((cos - COS_LOW) / (COS_HIGH - COS_LOW)).clamp(0.0, 1.0) as f64) * 0.95;
                                    match cat_rows.iter_mut().find(|r| r.0.id == id) {
                                        Some(r) => r.1 = r.1.max(rel),
                                        None => cat_rows.push((c.clone(), rel, "meaning")),
                                    }
                                }
                            }
                        }
                    }
                    kind_hits.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));
                    if let Some(best) = kind_hits.first().map(|h| h.1) {
                        for (id, cos) in kind_hits {
                            if cos < COS_CATEGORY || cos < best - COS_MARGIN || kind_rows.iter().any(|(k, _)| k.id == id) {
                                continue;
                            }
                            // only kinds that have places on the phone
                            let Some(k) = packs.iter().find_map(|p| p.kind(&id).filter(|_| p.kind_place_count(&id) > 0)) else { continue };
                            kind_rows.push((k.clone(), (((cos - COS_LOW) / (COS_HIGH - COS_LOW)).clamp(0.0, 1.0) as f64) * 0.95));
                        }
                    }
                }
            }
        }

        // 3. names (after the category and meaning steps, so a weak name hit can be dropped when they answered)
        // a kind whose category was matched is folded into that category's row
        kind_rows.retain(|(k, s)| match k.category.as_deref().and_then(|c| cat_rows.iter_mut().find(|r| r.0.id == c)) {
            Some(r) => {
                r.1 = r.1.max(*s);
                false
            }
            None => true,
        });
        let answered = !cat_rows.is_empty() || !kind_rows.is_empty() || !meaning_places.is_empty();
        let anchor_town = anchor.as_ref().filter(|(_, r)| !r.trim().is_empty()).map(|(l, _)| format!("town:{}", l.source_id));
        let mut name_hits: Vec<GeoHit> = self.geo.forward(q, centre, 12);
        if let Some(r) = rest.as_deref().filter(|r| !r.trim().is_empty()) {
            name_hits.extend(self.geo.forward(r, centre, 8));
        }
        let max_score = name_hits.iter().map(|h| h.score).fold(1.0, f64::max);
        for h in &name_hits {
            if answered && h.name_match < NAME_FLOOR {
                continue;
            }
            if anchor_town.as_deref() == Some(h.address.as_str()) {
                continue;
            }
            let rel = (0.85 * h.name_match / 100.0 + 0.15 * (h.score / max_score).clamp(0.0, 1.0)).min(1.0);
            let cand = match h.kind {
                HitKind::Locality => h.address.strip_prefix("town:").and_then(|sid| packs.iter().find_map(|p| p.locality_by_source_id(sid).ok().flatten())).map(|l| cand_town(&l, rel, "name")),
                HitKind::Place => h.address.strip_prefix("place:").and_then(|sid| packs.iter().find_map(|p| p.place_by_source_id(sid).ok().flatten())).map(|r| cand_place(&packs, &r, rel, "name")),
                HitKind::Address => Some(cand_address(h, rel)),
            };
            if let Some(c) = cand {
                cands.push(c);
            }
        }
        for (c, _) in meaning_places {
            cands.push(c);
        }

        // category rows and their nearest places
        let mut rows_json: Vec<(f64, Value)> = Vec::new();
        for (c, s, how) in &cat_rows {
            let mut m = Map::new();
            m.insert("id".into(), json!(format!("category:{}", c.id)));
            m.insert("type".into(), json!("category"));
            m.insert("name".into(), json!(c.title));
            m.insert("kind".into(), json!("Category"));
            m.insert("category".into(), json!(c.id));
            m.insert("address".into(), json!(c.description));
            m.insert("matched".into(), json!(how));
            m.insert("score".into(), json!(round_to(*s, 3)));
            rows_json.push((2.0 + s, Value::Object(m)));
            if let Some((la, lo)) = centre {
                for r in ranked(&packs, &c.id, la, lo, limit.min(8)).unwrap_or_default() {
                    cands.push(cand_place(&packs, &r.row, s * 0.95, how));
                }
            }
        }

        // kind rows and their nearest places
        for (k, s) in &kind_rows {
            let mut m = Map::new();
            m.insert("id".into(), json!(format!("kind:{}", k.id)));
            m.insert("type".into(), json!("category"));
            m.insert("name".into(), json!(k.label));
            m.insert("kind".into(), json!("Category"));
            m.insert("kind_id".into(), json!(k.id));
            m.insert("category".into(), json!(k.category));
            m.insert("address".into(), json!(k.description));
            m.insert("matched".into(), json!("meaning"));
            m.insert("score".into(), json!(round_to(*s, 3)));
            rows_json.push((2.0 + s, Value::Object(m)));
            if let Some((la, lo)) = centre {
                for (r, _) in nearest_of_kind(&packs, &k.id, la, lo, limit.min(8)) {
                    cands.push(cand_place(&packs, &r, s * 0.95, "meaning"));
                }
            }
        }

        // rank
        // one entry per id, with the best relevance any step gave it
        let mut best: HashMap<String, usize> = HashMap::new();
        let mut uniq: Vec<Cand> = Vec::new();
        for c in cands {
            match best.get(&c.id) {
                Some(&i) => {
                    if c.rel > uniq[i].rel {
                        uniq[i] = c;
                    }
                }
                None => {
                    best.insert(c.id.clone(), uniq.len());
                    uniq.push(c);
                }
            }
        }
        let mut scored: Vec<(f64, Value)> = Vec::new();
        let mut keep: Vec<(f64, Cand)> = Vec::new();
        for c in uniq {
            let close = match centre {
                Some((la, lo)) => (-haversine_km(la, lo, c.lat, c.lon) / CLOSE_KM).exp(),
                None => 0.5,
            };
            let score = W_RELEVANCE * c.rel + (1.0 - W_RELEVANCE) * close;
            keep.push((score, c));
        }
        // the same shop listed twice (an OSM and an Overture record) shows once
        keep.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        let mut kept: Vec<(f64, Cand)> = Vec::new();
        for (s, c) in keep {
            if kept.iter().any(|(_, k)| k.kind_t == c.kind_t && norm(&k.name) == norm(&c.name) && haversine_km(k.lat, k.lon, c.lat, c.lon) < 0.3) {
                continue;
            }
            kept.push((s, c));
        }
        for (s, c) in kept {
            scored.push((s, cand_json(&c, opts.near, s)));
        }
        // category rows lead (they are what "pharmacy" means), then places by score
        let mut results: Vec<Value> = Vec::new();
        let mut cat_sorted = rows_json;
        cat_sorted.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        let cat_n = cat_sorted.len().min(2);
        results.extend(cat_sorted.into_iter().take(cat_n).map(|(_, v)| v));
        scored.sort_by(|a, b| b.0.partial_cmp(&a.0).unwrap_or(std::cmp::Ordering::Equal));
        results.extend(scored.into_iter().map(|(_, v)| v).take(limit));

        out.insert(
            "interpreted".into(),
            json!({
                "kind": "text",
                "anchor": anchor.as_ref().map(|(l, _)| json!({"name": l.name, "state": l.state, "lat": round_to(l.lat, 6), "lon": round_to(l.lon, 6)})),
                "categories": cat_rows.iter().map(|(c, _, _)| c.id.clone()).collect::<Vec<_>>(),
            }),
        );
        out.insert("meaning".into(), json!(meaning));
        out.insert("results".into(), Value::Array(results));
        Ok(Value::Object(out))
    }

    /// A place, town, address or coordinates by the id a result carried. A `kind:` id needs a centre: see `lookup_near`.
    pub fn lookup(&self, id: &str) -> Option<Endpoint> {
        self.lookup_near(id, None)
    }

    /// `lookup`, plus `kind:<id>`: the nearest place of that kind to `near`.
    pub fn lookup_near(&self, id: &str, near: Option<(f64, f64)>) -> Option<Endpoint> {
        let packs = self.packs.current();
        if let Some((uid, number)) = address::parse_id(id) {
            for p in packs.iter().filter(|p| p.has_addresses()) {
                let Ok(Some(row)) = p.street_by_uid(uid) else { continue };
                let group = p.street_group(&row).unwrap_or_else(|_| vec![row.clone()]);
                let f = address::find_number(&group, number)?;
                return Some(Endpoint { id: Some(id.into()), name: Some(format!("{} {}", f.number, row.street)), lat: f.lat, lon: f.lon, osm_category: None });
            }
            return None;
        }
        if let Some(kind) = id.strip_prefix("kind:") {
            let (la, lo) = near?;
            let (r, _) = nearest_of_kind(&packs, kind, la, lo, 1).into_iter().next()?;
            let osm = crate::geocoder::osm_category(&r);
            return Some(Endpoint { id: Some(format!("place:{}", r.source_id)), name: r.name.clone().or_else(|| kind_of(&packs, &r).map(|k| k.1)), lat: r.lat, lon: r.lon, osm_category: osm });
        }
        if let Some(sid) = id.strip_prefix("place:") {
            let r = packs.iter().find_map(|p| p.place_by_source_id(sid).ok().flatten())?;
            let osm = crate::geocoder::osm_category(&r);
            return Some(Endpoint { id: Some(id.into()), name: r.name.clone().or_else(|| kind_of(&packs, &r).map(|k| k.1)).or(r.kind.clone()), lat: r.lat, lon: r.lon, osm_category: osm });
        }
        if let Some(sid) = id.strip_prefix("town:") {
            let l = packs.iter().find_map(|p| p.locality_by_source_id(sid).ok().flatten())?;
            return Some(Endpoint { id: Some(id.into()), name: Some(l.name.clone()), lat: l.lat, lon: l.lon, osm_category: None });
        }
        if let Some(ll) = id.strip_prefix("loc:") {
            let p = coord::parse(ll, None)?;
            return Some(Endpoint { id: Some(id.into()), name: None, lat: p.lat, lon: p.lon, osm_category: None });
        }
        None
    }

    /// Text typed for an end: an id, coordinates in any format, or a name (the geocoder's best match).
    pub fn resolve_text(&self, text: &str, near: Option<(f64, f64)>) -> Option<Endpoint> {
        let t = text.trim();
        if let Some(e) = self.lookup_near(t, near) {
            return Some(e);
        }
        if let Some(p) = coord::parse(t, near) {
            return Some(Endpoint { id: None, name: None, lat: p.lat, lon: p.lon, osm_category: None });
        }
        let h = self.geo.forward(t, near, 1).into_iter().next()?;
        Some(Endpoint { id: Some(h.address), name: Some(h.name), lat: h.lat, lon: h.lon, osm_category: h.osm_category })
    }
}

/// The nearest places of one kind across the packs, nearest first, the same place once.
fn nearest_of_kind(packs: &[Arc<Pack>], kind: &str, lat: f64, lon: f64, limit: usize) -> Vec<(PlaceRow, f64)> {
    let ids = [kind.to_string()];
    let mut found: Vec<(PlaceRow, f64)> = packs.iter().flat_map(|p| p.nearby_kind(&ids, lat, lon, crate::nearby::MAX_KM, limit).unwrap_or_default()).collect();
    found.sort_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
    let mut seen: HashSet<String> = HashSet::new();
    found.retain(|(r, _)| seen.insert(r.source_id.clone()));
    found.truncate(limit);
    found
}

/// The request of `cs_map_search`: `{"query", "near"?: {"lat","lon"}, "limit"?, "meaning"?, "query_vector"?: {"model","vector"}}`.
pub fn parse_request(v: &Value) -> Result<(String, SearchOpts), MapError> {
    let o = v.as_object().ok_or_else(|| bad("the request must be a JSON object"))?;
    for k in o.keys() {
        if !["query", "near", "limit", "meaning", "query_vector"].contains(&k.as_str()) {
            return Err(bad(format!("{k}: not allowed")));
        }
    }
    let query = o.get("query").and_then(Value::as_str).ok_or_else(|| bad("\"query\" (string) is required"))?.to_string();
    let near = match o.get("near") {
        None | Some(Value::Null) => None,
        Some(n) => Some((
            n["lat"].as_f64().filter(|x| x.abs() <= 90.0).ok_or_else(|| bad("near.lat must be a number in range"))?,
            n["lon"].as_f64().filter(|x| x.abs() <= 180.0).ok_or_else(|| bad("near.lon must be a number in range"))?,
        )),
    };
    let limit = match o.get("limit") {
        None | Some(Value::Null) => 10,
        Some(l) => l.as_u64().filter(|n| (1..=30).contains(n)).ok_or_else(|| bad("limit must be 1 to 30"))? as usize,
    };
    let meaning = match o.get("meaning") {
        None | Some(Value::Null) => true,
        Some(m) => m.as_bool().ok_or_else(|| bad("meaning must be true or false"))?,
    };
    let vector = match o.get("query_vector") {
        None | Some(Value::Null) => None,
        Some(qv) => {
            let model = qv["model"].as_str().ok_or_else(|| bad("query_vector.model (string) is required"))?.to_string();
            let vec: Option<Vec<f32>> = qv["vector"].as_array().map(|a| a.iter().map(|x| x.as_f64().map(|f| f as f32)).collect()).unwrap_or(None);
            Some((model, vec.ok_or_else(|| bad("query_vector.vector must be an array of numbers"))?))
        }
    };
    Ok((query, SearchOpts { near, limit, meaning, vector, prepared: None }))
}
