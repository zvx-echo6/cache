//! What every input source produces, so inputs are pluggable: a CSV export of Overture today, Overture GeoParquet and a
//! Geofabrik extract on GitHub Actions later. A source turns its records into `Raw` places and `RawLocality`s using the
//! category rules; everything after that (merge, geography, writing) is the same for every source.

use crate::rules::Rules;

/// Wikimedia identifiers a source carries for a place (OSM tags). Only IDs the data itself states.
#[derive(Debug, Clone, Default)]
pub struct Wiki {
    pub wikidata: Option<String>,
    /// English Wikipedia article title (from `wikipedia=en:Title`).
    pub wikipedia: Option<String>,
    pub wikivoyage: Option<String>,
}

#[derive(Debug, Clone)]
pub struct Raw {
    /// "osm" or "overture".
    pub source: &'static str,
    /// "osm:n123", "osm:w456" or "overture:<uuid>".
    pub source_id: String,
    pub name: Option<String>,
    pub alt: Vec<String>,
    /// A starter category id, or None for a named place that is only here for the geocoder.
    pub category: Option<String>,
    pub kind: String,
    pub lat: f64,
    pub lon: f64,
    pub street: Option<String>,
    /// addr:city when the source has it.
    pub city: Option<String>,
    pub phone: Option<String>,
    pub hours: Option<String>,
    pub website: Option<String>,
    pub confidence: Option<f64>,
    pub wiki: Wiki,
    pub brand_wikidata: Option<String>,
    /// From the category rule: only a place when one of this category is within the radius, and it takes that place's
    /// name and details (see `require_match` in categories.json).
    pub enrich: Option<(String, f64)>,
    /// The source id of the place it was matched to.
    pub matched: Option<String>,
}

#[derive(Debug, Clone)]
pub struct RawLocality {
    pub source_id: String,
    pub name: String,
    pub alt: Vec<String>,
    /// city, town, village or hamlet.
    pub kind: String,
    pub lat: f64,
    pub lon: f64,
    pub population: Option<i64>,
    pub wiki: Wiki,
}

#[derive(Default)]
pub struct Harvest {
    pub places: Vec<Raw>,
    pub localities: Vec<RawLocality>,
}

pub trait PlaceSource {
    /// A line for the pack's meta: what was read.
    fn describe(&self) -> String;
    fn read(&mut self, rules: &Rules, out: &mut Harvest) -> Result<(), String>;
}

pub fn is_qid(s: &str) -> bool {
    s.len() > 1 && s.starts_with('Q') && s[1..].bytes().all(|b| b.is_ascii_digit())
}

/// 10 or 11 digit North American numbers become "+1 208 678 3050"; anything else is kept as given.
pub fn format_phone(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.is_empty() {
        return None;
    }
    let digits: String = raw.chars().filter(|c| c.is_ascii_digit()).collect();
    let only_phone_chars = raw.chars().all(|c| c.is_ascii_digit() || " +-().".contains(c));
    let ten = match digits.len() {
        10 => Some(&digits[..]),
        11 if digits.starts_with('1') => Some(&digits[1..]),
        _ => None,
    };
    match ten {
        Some(t) if only_phone_chars => Some(format!("+1 {} {} {}", &t[..3], &t[3..6], &t[6..])),
        _ => Some(raw.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn phones() {
        assert_eq!(format_phone("2086783050").unwrap(), "+1 208 678 3050");
        assert_eq!(format_phone("+1 (208) 678-3050").unwrap(), "+1 208 678 3050");
        assert_eq!(format_phone("12086783050").unwrap(), "+1 208 678 3050");
        assert_eq!(format_phone("+44 20 7946 0958").unwrap(), "+44 20 7946 0958");
        assert_eq!(format_phone("208-678-3050; 208-678-3051").unwrap(), "208-678-3050; 208-678-3051");
        assert!(format_phone("  ").is_none());
    }
}
