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
    /// How to say the kind, for a point of the user's own map layer (`kind` "layer_point"): the layer's name.
    pub kind_label: Option<String>,
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
    /// Phone, website and opening hours: Some only for a place from the places data (a POI), not for a town or an address.
    pub details: Option<PlaceDetails>,
}

/// What the places data says about a POI beyond where it is; each None when the data does not have it.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct PlaceDetails {
    pub phone: Option<String>,
    pub website: Option<String>,
    /// The raw OSM `opening_hours` string.
    pub hours: Option<String>,
}

impl PlaceMatch {
    pub fn new(place_name: impl Into<String>, lat: f64, lon: f64) -> PlaceMatch {
        PlaceMatch {
            place_name: place_name.into(),
            kind: None,
            kind_label: None,
            street: None,
            locality: None,
            county: None,
            state: None,
            distance_km: None,
            er_tier: None,
            lat,
            lon,
            osm_category: None,
            details: None,
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

    /// `resolve`, plus what the places data also says about the match (state, state name, county, country). The default
    /// knows only the name and the position; `cache_places` fills in the rest where its pack has it.
    fn resolve_full(&self, text: &str, near: Option<(f64, f64)>) -> Option<ResolvedPlace> {
        self.resolve(text, near).map(|(name, lat, lon)| ResolvedPlace { name, lat, lon, ..Default::default() })
    }

    /// Where a point is, in words a person recognises: "12 mi NE of Stanley" (the distance in miles to one decimal, the
    /// compass point the point lies in from the nearest town, and the town as it is shown). `None` when the data does not
    /// know a town near it; the default knows none.
    fn describe_point(&self, _lat: f64, _lon: f64) -> Option<String> {
        None
    }

    /// The name of the nearest town to a point ("Burley"), when the data knows one; the default knows none.
    fn nearest_town(&self, _lat: f64, _lon: f64) -> Option<String> {
        None
    }
}

/// A place a `Geocoder` resolved: name, position and the optional administrative facts live-data connectors can use in
/// their URLs (`{state}`, `{state_name}`, `{county}`, `{country}`). A fact the pack does not have is `None`.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ResolvedPlace {
    pub name: String,
    pub lat: f64,
    pub lon: f64,
    /// Two-letter state code ("ID").
    pub state: Option<String>,
    /// The state's name ("Idaho"), from the pack's state list.
    pub state_name: Option<String>,
    pub county: Option<String>,
    /// Country code ("US").
    pub country: Option<String>,
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
