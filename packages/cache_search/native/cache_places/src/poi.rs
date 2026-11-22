//! Links from the base map's chips to places of the pack (the `poi_links` table of a tile and of the merged database).
//!
//! The base map (Protomaps v4, layer `pois`) draws a chip for a public place. A chip carries a name, a `kind` and a point, and no
//! OpenStreetMap id. At pack build time `places_pack poi-link` matches every chip to the pack's record of the same place and writes
//! one row per chip here; the phone looks a tapped chip up by what the tile gives it and never guesses.
//!
//! A row is `(name_norm, kind, lat, lon, source_id)`: the chip's own name (normalised as [`norm_name`] says) and tile `kind`, the
//! chip's point as the tiles gave it, and the `source_id` of the record it is. The lookup ([`crate::pack::Pack::poi_link`]) takes a
//! row with the same name_norm and kind whose point is within [`LINK_REACH_M`] of the tapped chip's point, the nearest. Nothing in it
//! depends on a tile zoom or grid: a point is quantised to 1/4096 of its tile, which is about 2.4 m at zoom 12 and 0.3 m at 15, so the
//! same chip read at two zooms differs by a few metres at most.

/// How far a tapped chip's point may be from the point a link row stores for it, in metres. Covers the tile quantisation at the
/// lowest zoom a chip is drawn (about 2.4 m) with room to spare; two chips of one name and kind this close are told apart by the
/// nearest row, and each is within a few metres of its own.
pub const LINK_REACH_M: f64 = 15.0;

/// A name as the link key holds it: lower case, every run of characters that are not letters or digits one space, trimmed. Case,
/// punctuation and spacing only; no word is ever dropped or changed.
pub fn norm_name(s: &str) -> String {
    s.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(|w| w.to_lowercase()).collect::<Vec<_>>().join(" ")
}

/// Metres between two points (an equirectangular approximation, good to well under a metre at these distances).
pub fn metres(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let dy = (lat2 - lat1) * 111_320.0;
    let dx = (lon2 - lon1) * 111_320.0 * ((lat1 + lat2) / 2.0).to_radians().cos();
    (dx * dx + dy * dy).sqrt()
}

/// Rows read for the lookup: (source_id, lat, lon). The nearest within [`LINK_REACH_M`] of the point, else None.
pub fn nearest_row(rows: &[(String, f64, f64)], lat: f64, lon: f64) -> Option<&str> {
    rows.iter()
        .map(|(s, la, lo)| (metres(lat, lon, *la, *lo), s))
        .filter(|(d, _)| *d <= LINK_REACH_M)
        .min_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal))
        .map(|(_, s)| s.as_str())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_normalise_by_case_punctuation_and_spacing_only() {
        assert_eq!(norm_name("Dutch Bros. Coffee"), "dutch bros coffee");
        assert_eq!(norm_name("  KELLY'S   Diner "), "kelly s diner");
        assert_eq!(norm_name("St. Luke's Magic Valley"), "st luke s magic valley");
        assert_eq!(norm_name("Shoshone Falls"), "shoshone falls");
        assert_eq!(norm_name("!!"), "");
    }

    #[test]
    fn the_nearest_row_within_reach_wins() {
        let rows = vec![("a".to_string(), 42.5960, -114.4020), ("b".to_string(), 42.59605, -114.40205)];
        assert_eq!(nearest_row(&rows, 42.59605, -114.40205), Some("b"));
        assert_eq!(nearest_row(&rows, 42.5960, -114.4020), Some("a"));
        assert_eq!(nearest_row(&rows, 42.5970, -114.4020), None, "110 m away is no link");
    }
}
