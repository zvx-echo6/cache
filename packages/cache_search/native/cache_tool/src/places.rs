//! The place lookup that tools plug a geocoder into: names to coordinates (`to`, `from`, `near`) and "the nearest
//! place of a category" (`to_type`). `cache_places` implements `PlaceSource` over the installed places pack; until
//! it is installed a tool still resolves saved places and "lat,lon" text, and answers `not_set_up` for the rest.

use crate::ToolError;

/// One place a lookup found.
#[derive(Clone, Debug, PartialEq)]
pub struct PlaceMatch {
    pub place_name: String,
    /// What it is, in plain words ("hospital", "town", "trailhead"); none when the pack does not say.
    pub kind: Option<String>,
    pub street: Option<String>,
    pub locality: Option<String>,
    pub county: Option<String>,
    pub state: Option<String>,
    /// How far the match is from the search's bias point, in km (AIDA's geocoder gives it).
    pub distance_km: Option<f64>,
    /// Emergency rooms only: the evidence tier (1 = a hospital with an emergency department listing).
    pub er_tier: Option<i64>,
    pub lat: f64,
    pub lon: f64,
    /// The place's OSM "key:value" (for example "highway:path"), which seeds the off-road travel modes at that end.
    pub osm_category: Option<String>,
}

impl PlaceMatch {
    pub fn new(place_name: impl Into<String>, lat: f64, lon: f64) -> PlaceMatch {
        PlaceMatch {
            place_name: place_name.into(),
            kind: None,
            street: None,
            locality: None,
            county: None,
            state: None,
            distance_km: None,
            er_tier: None,
            lat,
            lon,
            osm_category: None,
        }
    }
}

/// A name lookup. `near` is the town-and-state text the model gave ("Burley, Idaho"); `bias` is a point to prefer
/// results close to (the town's centre when `near` resolved, else the phone's position).
#[derive(Clone, Debug)]
pub struct GeocodeQuery<'a> {
    pub text: &'a str,
    pub near: Option<&'a str>,
    pub bias: Option<(f64, f64)>,
    pub limit: usize,
}

/// Matches best first (empty: nothing found), and how far the search looked.
#[derive(Clone, Debug, Default)]
pub struct GeocodeAnswer {
    pub matches: Vec<PlaceMatch>,
    pub searched_within_km: Option<f64>,
}

/// The nearest places of one category to a point, nearest first by straight line. The caller ranks them by travel time.
#[derive(Clone, Debug)]
pub struct NearestQuery<'a> {
    pub category: &'a str,
    pub from: (f64, f64),
    pub limit: usize,
}

/// A name to one point: the lookup a tool needs when it only wants to know where a place is (`live_data`). `cache_places`
/// implements it over the installed places pack, with the same resolver `navigate` and `locate` use.
pub trait Geocoder: Send + Sync {
    /// The best match for `text` ("Island Park, Idaho", "island park", a close misspelling of a town): its name as it is shown
    /// ("Island Park, ID") and its position. `near` is a point to prefer when several places share the name (the phone's
    /// position). `None` when nothing fits.
    fn resolve(&self, text: &str, near: Option<(f64, f64)>) -> Option<(String, f64, f64)>;
}

/// "44.0543,-115.4237" or "44.0543 -115.4237" (also with a space after the comma): two numbers in range.
pub fn parse_latlon(text: &str) -> Option<(f64, f64)> {
    let t = text.trim();
    let parts: Vec<&str> = if t.contains(',') { t.split(',').map(str::trim).collect() } else { t.split_whitespace().collect() };
    if parts.len() != 2 {
        return None;
    }
    let (lat, lon) = (parts[0].parse::<f64>().ok()?, parts[1].parse::<f64>().ok()?);
    if lat.is_finite() && lon.is_finite() && lat.abs() <= 90.0 && lon.abs() <= 180.0 {
        Some((lat, lon))
    } else {
        None
    }
}

pub trait PlaceSource: Send + Sync {
    /// The same pack as a `Geocoder` (for `ToolCtx::geocoder`); `None` for a source that only does `geocode` and `nearest`.
    fn geocoder(&self) -> Option<&dyn Geocoder> {
        None
    }
    /// The categories `to_type` may use, or None while no places data is installed.
    fn categories(&self) -> Option<Vec<String>>;
    fn geocode(&self, q: &GeocodeQuery) -> Result<GeocodeAnswer, ToolError>;
    fn nearest(&self, q: &NearestQuery) -> Result<GeocodeAnswer, ToolError>;
}
