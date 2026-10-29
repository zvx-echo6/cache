//! OpenStreetMap places from a `.osm.pbf` extract (Geofabrik): nodes and ways that match the category rules or are
//! named places worth finding, and place=city|town|village|hamlet nodes for localities. Two passes: ways first (to
//! learn which node positions are needed for their centres), then nodes. Relations are not read.
//!
//! The same passes collect the arrival anchors the `arrival` rules pick out (terminals, entrances, parking), and the box
//! around each way place's outline, for the places' arrival points (`arrival.rs`).

use crate::model::{format_phone, is_qid, Anchor, AnchorKind, Harvest, PlaceSource, Raw, RawLocality, Wiki};
use crate::rules::{generic_kind_id, Rules};
use osmpbf::{Element, ElementReader};
use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

pub struct OsmPbf {
    pub path: PathBuf,
}

/// Keys that say what a feature is, in the order `kind` prefers them.
const KIND_KEYS: [&str; 13] = [
    "amenity", "healthcare", "tourism", "shop", "leisure", "historic", "natural", "highway", "man_made", "aeroway", "railway", "waterway",
    "mountain_pass",
];

const LOCALITY_KINDS: [&str; 4] = ["city", "town", "village", "hamlet"];

struct Found {
    place: Option<Raw>,
    locality: Option<RawLocality>,
}

fn tag<'a>(tags: &[(&'a str, &'a str)], key: &str) -> Option<&'a str> {
    tags.iter().find(|(k, _)| *k == key).map(|(_, v)| *v).filter(|v| !v.trim().is_empty())
}

fn first_tag<'a>(tags: &[(&'a str, &'a str)], keys: &[&str]) -> Option<String> {
    keys.iter().find_map(|k| tag(tags, k)).map(|v| v.trim().to_string())
}

/// The `wikidata`, `wikipedia` and `wikivoyage` tags. Only English-language titles are kept (`en:Title`); a tag in another
/// language is left alone.
fn wiki_tags(tags: &[(&str, &str)]) -> Wiki {
    let en = |k: &str| tag(tags, k).and_then(|v| v.trim().strip_prefix("en:").map(|t| t.trim().to_string())).filter(|t| !t.is_empty());
    Wiki { wikidata: tag(tags, "wikidata").map(|q| q.trim().to_string()).filter(|q| is_qid(q)), wikipedia: en("wikipedia"), wikivoyage: en("wikivoyage") }
}

fn alt_names(tags: &[(&str, &str)], name: Option<&str>) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for k in ["alt_name", "old_name", "official_name", "short_name", "name:en"] {
        if let Some(v) = tag(tags, k) {
            for part in v.split(';') {
                let p = part.trim();
                if !p.is_empty() && Some(p) != name && !out.iter().any(|o| o == p) {
                    out.push(p.to_string());
                }
            }
        }
    }
    out
}

/// Classify one element's tags. `lat`/`lon` are its position (a way's centre is filled in later; pass NaN).
fn classify(rules: &Rules, tags: &[(&str, &str)], id: String, lat: f64, lon: f64) -> Found {
    let name = tag(tags, "name").map(|s| s.trim().to_string());
    if let Some(kind) = tag(tags, "place").filter(|k| LOCALITY_KINDS.contains(k)) {
        if let Some(n) = &name {
            let population = tag(tags, "population").and_then(|p| p.chars().filter(|c| c.is_ascii_digit()).collect::<String>().parse::<i64>().ok());
            return Found {
                place: None,
                locality: Some(RawLocality { source_id: id, name: n.clone(), alt: alt_names(tags, Some(n)), kind: kind.to_string(), lat, lon, population, wiki: wiki_tags(tags) }),
            };
        }
    }
    let category = rules.osm_category(tags).map(|c| c.id.clone());
    if category.is_none() && !(name.is_some() && rules.osm_general(tags)) {
        return Found { place: None, locality: None };
    }
    let kind = KIND_KEYS
        .iter()
        .find_map(|k| tag(tags, k).map(|v| format!("{k}={v}")))
        .unwrap_or_else(|| "unknown".to_string());
    let kind_id = rules.osm_kind(category.as_deref(), tags).map(|k| k.id.clone()).unwrap_or_else(|| generic_kind_id(&kind));
    let street = tag(tags, "addr:street").map(|s| match tag(tags, "addr:housenumber") {
        Some(h) => format!("{} {}", h.trim(), s.trim()),
        None => s.trim().to_string(),
    });
    Found {
        locality: None,
        place: Some(Raw {
            source: "osm",
            source_id: id,
            alt: alt_names(tags, name.as_deref()),
            name,
            category,
            kind,
            kind_id: Some(kind_id),
            lat,
            lon,
            street,
            city: tag(tags, "addr:city").map(|s| s.trim().to_string()),
            phone: first_tag(tags, &["phone", "contact:phone"]).and_then(|p| format_phone(&p)),
            hours: first_tag(tags, &["opening_hours"]),
            website: first_tag(tags, &["website", "contact:website", "url"]),
            confidence: None,
            wiki: wiki_tags(tags),
            brand_wikidata: tag(tags, "brand:wikidata").map(|q| q.trim().to_string()).filter(|q| is_qid(q)),
            enrich: None,
            matched: None,
            extent: None,
            arrival: None,
        }),
    }
}

/// A way's centre (the mean of its sampled nodes) and the box around them [south, west, north, east]; None when none of
/// its nodes is in the extract.
fn outline(refs: &[i64], pos: &HashMap<i64, (f64, f64)>) -> Option<(f64, f64, [f64; 4])> {
    let pts: Vec<(f64, f64)> = refs.iter().filter_map(|r| pos.get(r).copied()).collect();
    if pts.is_empty() {
        return None;
    }
    let lat = pts.iter().map(|x| x.0).sum::<f64>() / pts.len() as f64;
    let lon = pts.iter().map(|x| x.1).sum::<f64>() / pts.len() as f64;
    let mut b = [f64::MAX, f64::MAX, f64::MIN, f64::MIN];
    for &(la, lo) in &pts {
        b = [b[0].min(la), b[1].min(lo), b[2].max(la), b[3].max(lo)];
    }
    Some((lat, lon, b))
}

impl PlaceSource for OsmPbf {
    fn describe(&self) -> String {
        format!("osm pbf {}", self.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default())
    }

    fn read(&mut self, rules: &Rules, out: &mut Harvest) -> Result<(), String> {
        let open = || ElementReader::from_path(&self.path).map_err(|e| format!("{}: {e}", self.path.display()));

        // Pass 1: the ways that matter (places and arrival anchors), with a sample of their node ids.
        let mut ways: Vec<(Raw, Vec<i64>)> = Vec::new();
        let mut anchor_ways: Vec<(AnchorKind, Vec<i64>)> = Vec::new();
        let mut need: HashSet<i64> = HashSet::new();
        fn sample(w: &osmpbf::Way) -> Vec<i64> {
            let refs: Vec<i64> = w.refs().collect();
            let step = (refs.len() / 48).max(1);
            refs.iter().step_by(step).copied().collect()
        }
        open()?
            .for_each(|el| {
                if let Element::Way(w) = el {
                    let tags: Vec<(&str, &str)> = w.tags().collect();
                    if tags.is_empty() {
                        return;
                    }
                    if let Some(p) = classify(rules, &tags, format!("osm:w{}", w.id()), f64::NAN, f64::NAN).place {
                        let s = sample(&w);
                        need.extend(s.iter().copied());
                        ways.push((p, s));
                    }
                    if let Some(k) = rules.arrival.anchor(&tags) {
                        let s = sample(&w);
                        need.extend(s.iter().copied());
                        anchor_ways.push((k, s));
                    }
                }
            })
            .map_err(|e| format!("osm pass 1: {e}"))?;

        // Pass 2: node positions for the ways, and the matching nodes themselves.
        let mut pos: HashMap<i64, (f64, f64)> = HashMap::with_capacity(need.len());
        open()?
            .for_each(|el| {
                let (id, lat, lon, tags): (i64, f64, f64, Vec<(&str, &str)>) = match &el {
                    Element::Node(n) => (n.id(), n.lat(), n.lon(), n.tags().collect()),
                    Element::DenseNode(n) => (n.id(), n.lat(), n.lon(), n.tags().collect()),
                    _ => return,
                };
                if need.contains(&id) {
                    pos.insert(id, (lat, lon));
                }
                if tags.is_empty() {
                    return;
                }
                let f = classify(rules, &tags, format!("osm:n{id}"), lat, lon);
                if let Some(p) = f.place {
                    out.place(p);
                }
                if let Some(l) = f.locality {
                    out.locality(l);
                }
                if let Some(kind) = rules.arrival.anchor(&tags) {
                    out.anchor(Anchor { kind, lat, lon, extent: [lat, lon, lat, lon] });
                }
            })
            .map_err(|e| format!("osm pass 2: {e}"))?;

        for (mut p, refs) in ways {
            let Some((lat, lon, extent)) = outline(&refs, &pos) else { continue };
            (p.lat, p.lon, p.extent) = (lat, lon, Some(extent));
            out.place(p);
        }
        for (kind, refs) in anchor_ways {
            let Some((lat, lon, extent)) = outline(&refs, &pos) else { continue };
            out.anchor(Anchor { kind, lat, lon, extent });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rules() -> Rules {
        Rules::parse(include_str!("../categories.json")).unwrap()
    }

    #[test]
    fn classifies_a_pharmacy_with_details() {
        let tags = [
            ("amenity", "pharmacy"),
            ("name", "Walgreens"),
            ("addr:housenumber", "1414"),
            ("addr:street", "Overland Ave"),
            ("addr:city", "Burley"),
            ("phone", "208-678-3050"),
            ("opening_hours", "Mo-Su 08:00-22:00"),
            ("brand", "Walgreens"),
            ("brand:wikidata", "Q1591889"),
            ("wikidata", "Q42"),
            ("wikipedia", "en:Some Article"),
            ("wikivoyage", "de:Etwas"),
        ];
        let p = classify(&rules(), &tags, "osm:n1".into(), 42.5, -113.7).place.unwrap();
        assert_eq!(p.category.as_deref(), Some("pharmacy"));
        assert_eq!(p.street.as_deref(), Some("1414 Overland Ave"));
        assert_eq!(p.phone.as_deref(), Some("+1 208 678 3050"));
        assert_eq!(p.hours.as_deref(), Some("Mo-Su 08:00-22:00"));
        assert_eq!(p.kind, "amenity=pharmacy");
        assert_eq!(p.brand_wikidata.as_deref(), Some("Q1591889"));
        assert_eq!((p.wiki.wikidata.as_deref(), p.wiki.wikipedia.as_deref(), p.wiki.wikivoyage), (Some("Q42"), Some("Some Article"), None));
    }

    #[test]
    fn localities_and_general_places() {
        let l = classify(&rules(), &[("place", "town"), ("name", "Stanley"), ("population", "1,200"), ("alt_name", "Stanley Basin;Stanley ID")], "osm:n2".into(), 44.2, -114.9);
        let l = l.locality.unwrap();
        assert_eq!((l.kind.as_str(), l.population), ("town", Some(1200)));
        assert_eq!(l.alt, vec!["Stanley Basin", "Stanley ID"]);
        // A school is kept only with a name; an unnamed water tap is kept as a category place.
        assert!(classify(&rules(), &[("amenity", "school")], "osm:n3".into(), 1.0, 1.0).place.is_none());
        assert!(classify(&rules(), &[("amenity", "school"), ("name", "Burley High")], "osm:n3".into(), 1.0, 1.0).place.unwrap().category.is_none());
        assert_eq!(classify(&rules(), &[("amenity", "drinking_water")], "osm:n4".into(), 1.0, 1.0).place.unwrap().category.as_deref(), Some("water"));
    }

    #[test]
    fn every_place_gets_a_kind() {
        let kind = |tags: &[(&str, &str)]| classify(&rules(), tags, "osm:n5".into(), 1.0, 1.0).place.unwrap().kind_id.unwrap();
        // The category places: the kind rules say more than the raw type does.
        assert_eq!(kind(&[("amenity", "drinking_water")]), "drinking_water");
        assert_eq!(kind(&[("natural", "spring")]), "spring");
        assert_eq!(kind(&[("amenity", "shelter"), ("shelter_type", "picnic_shelter")]), "picnic_shelter");
        assert_eq!(kind(&[("amenity", "shelter"), ("shelter_type", "bomb_shelter"), ("name", "Vault 7")]), "emergency_shelter");
        assert_eq!(kind(&[("amenity", "pharmacy"), ("name", "Walgreens")]), "pharmacy");
        // A named place of no category takes the value of its raw type.
        assert_eq!(kind(&[("amenity", "school"), ("name", "Burley High")]), "school");
        assert_eq!(kind(&[("natural", "peak"), ("name", "Mount Borah")]), "peak");
        assert_eq!(kind(&[("mountain_pass", "yes"), ("name", "Galena Summit")]), "mountain_pass");
        // A spring that is not for drinking is not a water place, and is only here when named.
        assert_eq!(kind(&[("natural", "spring"), ("drinking_water", "no"), ("name", "Salt Spring")]), "spring");
    }

    #[test]
    fn arrival_anchors_follow_the_rules() {
        let r = rules();
        let a = |tags: &[(&str, &str)]| r.arrival.anchor(tags);
        assert_eq!(a(&[("aeroway", "terminal"), ("building", "yes")]), Some(AnchorKind::Terminal));
        assert_eq!(a(&[("entrance", "main"), ("door", "automatic")]), Some(AnchorKind::MainEntrance));
        assert_eq!(a(&[("entrance", "yes")]), Some(AnchorKind::Entrance));
        assert_eq!(a(&[("entrance", "service")]), None, "staff and service doors are not where people arrive");
        assert_eq!(a(&[("entrance", "main"), ("access", "private")]), None);
        assert_eq!(a(&[("amenity", "parking"), ("parking", "surface")]), Some(AnchorKind::Parking));
        assert_eq!(a(&[("amenity", "parking"), ("access", "private")]), None);
        assert_eq!(a(&[("amenity", "pharmacy")]), None);
        let mut pos = HashMap::new();
        pos.insert(1, (40.0, -111.0));
        pos.insert(2, (40.002, -111.004));
        let (lat, lon, b) = outline(&[1, 2, 3], &pos).unwrap();
        assert!((lat - 40.001).abs() < 1e-9 && (lon + 111.002).abs() < 1e-9);
        assert_eq!(b, [40.0, -111.004, 40.002, -111.0]);
        assert!(outline(&[3], &pos).is_none());
    }
}
