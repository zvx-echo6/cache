//! What every input source produces, so inputs are pluggable: a CSV export of Overture today, Overture GeoParquet and a
//! Geofabrik extract on GitHub Actions later. A source turns its records into `Raw` places and `RawLocality`s using the
//! category rules; everything after that (merge, geography, writing) is the same for every source.

use crate::rules::Rules;
use serde::{Deserialize, Serialize};

/// Wikimedia identifiers a source carries for a place (OSM tags). Only IDs the data itself states.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Wiki {
    pub wikidata: Option<String>,
    /// English Wikipedia article title (from `wikipedia=en:Title`).
    pub wikipedia: Option<String>,
    pub wikivoyage: Option<String>,
}

/// The source names a `Raw` carries.
const SOURCES: [&str; 4] = ["osm", "overture", "osm+overture", "overture+osm"];

/// A source name as the `&'static str` a `Raw` keeps (`harvest.sqlite` stores it in its own column).
pub fn source_name(s: &str) -> Option<&'static str> {
    SOURCES.iter().find(|x| **x == s).copied()
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Raw {
    /// "osm" or "overture". Not in the JSON form: `harvest.sqlite` has it as a column.
    #[serde(skip)]
    pub source: &'static str,
    /// "osm:n123", "osm:w456" or "overture:<uuid>".
    pub source_id: String,
    pub name: Option<String>,
    pub alt: Vec<String>,
    /// A starter category id, or None for a named place that is only here for the geocoder.
    pub category: Option<String>,
    /// The raw type: "amenity=school" (OSM) or Overture's basic category.
    pub kind: String,
    /// What kind of place it is (a `kinds` id), from the kind rules; None until a source sets it (the builder then derives it
    /// from the raw type).
    pub kind_id: Option<String>,
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
    /// The box around the place's outline, [south, west, north, east], for an OSM area (a way); None for a point.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub extent: Option<[f64; 4]>,
    /// Where a route to the place goes when that is not its point (`arrival`): (lat, lon).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arrival: Option<(f64, f64)>,
}

/// What an OSM feature that is not itself a place says about where people arrive at one (the `arrival` rules of
/// categories.json pick them out).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AnchorKind {
    /// An airport terminal building.
    Terminal,
    /// A door people may use (an `entrance` node).
    Entrance,
    /// The main door.
    MainEntrance,
    /// A parking lot or garage the public may use.
    Parking,
}

/// One arrival anchor: its point (a node, or the centre of a way) and the box around it ([south, west, north, east]; a
/// node's is its point).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Anchor {
    pub kind: AnchorKind,
    pub lat: f64,
    pub lon: f64,
    pub extent: [f64; 4],
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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

/// Where a harvest's rows go once enough have gathered (`places_pack harvest` writes them to `harvest.sqlite`).
pub type Sink = Box<dyn FnMut(Vec<Raw>, Vec<RawLocality>, Vec<Anchor>) -> Result<(), String>>;

/// What the sources read. Without a sink every row stays in memory (one region's `build`); with one, rows are handed on
/// in batches, so a continent's harvest never sits in memory at once.
#[derive(Default)]
pub struct Harvest {
    pub places: Vec<Raw>,
    pub localities: Vec<RawLocality>,
    /// Terminals, entrances and parking, for the places' arrival points.
    pub anchors: Vec<Anchor>,
    sink: Option<Sink>,
    /// The first error of the sink (a source's reader callback cannot return one).
    error: Option<String>,
    /// Rows handed to the sink so far.
    pub flushed: (usize, usize),
}

/// Rows gathered before they are handed to the sink.
const BATCH: usize = 50_000;

impl Harvest {
    pub fn with_sink(sink: Sink) -> Harvest {
        Harvest { sink: Some(sink), ..Default::default() }
    }

    pub fn place(&mut self, r: Raw) {
        self.places.push(r);
        if self.sink.is_some() && self.places.len() >= BATCH {
            self.flush();
        }
    }

    pub fn locality(&mut self, l: RawLocality) {
        self.localities.push(l);
        if self.sink.is_some() && self.localities.len() >= BATCH {
            self.flush();
        }
    }

    pub fn anchor(&mut self, a: Anchor) {
        self.anchors.push(a);
        if self.sink.is_some() && self.anchors.len() >= BATCH {
            self.flush();
        }
    }

    /// Hands what has gathered to the sink (nothing without one).
    pub fn flush(&mut self) {
        let Some(sink) = self.sink.as_mut() else { return };
        let (p, l, a) = (std::mem::take(&mut self.places), std::mem::take(&mut self.localities), std::mem::take(&mut self.anchors));
        self.flushed.0 += p.len();
        self.flushed.1 += l.len();
        if self.error.is_none() {
            if let Err(e) = sink(p, l, a) {
                self.error = Some(e);
            }
        }
    }

    /// Flushes the rest and returns the sink's first error, if any.
    pub fn finish(&mut self) -> Result<(), String> {
        self.flush();
        self.error.take().map_or(Ok(()), Err)
    }

    /// Places read so far, flushed or not.
    pub fn n_places(&self) -> usize {
        self.flushed.0 + self.places.len()
    }

    pub fn n_localities(&self) -> usize {
        self.flushed.1 + self.localities.len()
    }
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
