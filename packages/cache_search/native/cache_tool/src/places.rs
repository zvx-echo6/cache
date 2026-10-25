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
    pub state: Option<String>,
    pub lat: f64,
    pub lon: f64,
    /// The place's OSM "key:value" (for example "highway:path"), which seeds the off-road travel modes at that end.
    pub osm_category: Option<String>,
}

impl PlaceMatch {
    pub fn new(place_name: impl Into<String>, lat: f64, lon: f64) -> PlaceMatch {
        PlaceMatch { place_name: place_name.into(), kind: None, street: None, locality: None, state: None, lat, lon, osm_category: None }
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

pub trait PlaceSource: Send + Sync {
    /// The categories `to_type` may use, or None while no places data is installed.
    fn categories(&self) -> Option<Vec<String>>;
    fn geocode(&self, q: &GeocodeQuery) -> Result<GeocodeAnswer, ToolError>;
    fn nearest(&self, q: &NearestQuery) -> Result<GeocodeAnswer, ToolError>;
}
