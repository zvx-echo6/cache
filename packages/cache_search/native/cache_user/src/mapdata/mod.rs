//! The user's own map data in user.sqlite: map layers (imported KML/KMZ, GPX or GeoJSON, or a layer JSON) and imported
//! repeater lists (RepeaterBook-style KML and/or CHIRP CSV, merged). One store and one import path for both; only the
//! points reach the assistant (`nearby`, and `navigate`/`locate` by a layer point's name), lines and areas are map-only.
//!
//! - `kml`, `gpx`, `geojson`, `chirp`: the parsers (and the KML and GPX writers)
//! - `repeater`: a repeater's settings, the KML + CHIRP merge and the words the tools show
//! - `store`: the tables, import, list, visibility, delete and export, and `UserPoints` for the tools

pub mod chirp;
pub mod geojson;
pub mod gpx;
pub mod kml;
pub mod repeater;
pub mod store;
mod xml;
mod zip;

pub use store::MapStore;

use serde::{Deserialize, Serialize};

/// An error of a parser: the file is not what its name says, or its content cannot be read.
pub(crate) fn bad(m: impl Into<String>) -> crate::Error {
    crate::Error { code: "bad_json", message: m.into() }
}

/// The largest file an import reads (and the largest a KMZ may unpack to).
pub const MAX_FILE_BYTES: u64 = 64 << 20;

/// A shape of a layer, in (lat, lon).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", content = "coords", rename_all = "lowercase")]
pub enum Geom {
    Point(f64, f64),
    Line(Vec<(f64, f64)>),
    /// The outer ring of a polygon.
    Area(Vec<(f64, f64)>),
}

/// One thing of a layer: a pin, a line or an area, with its name and notes.
#[derive(Clone, Debug, PartialEq)]
pub struct Feature {
    pub name: String,
    pub notes: String,
    pub geom: Geom,
}

/// What a layer file holds.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct ParsedLayer {
    /// The file's own name for the layer (KML Document name, GPX metadata name, the layer JSON's "name").
    pub name: Option<String>,
    /// The layer JSON's "private".
    pub private: Option<bool>,
    pub features: Vec<Feature>,
}

/// A coordinate pair read from a file: both finite and in range.
pub(crate) fn coord_ok(lat: f64, lon: f64) -> bool {
    lat.is_finite() && lon.is_finite() && (-90.0..=90.0).contains(&lat) && (-180.0..=180.0).contains(&lon)
}

/// Runs of whitespace as one space, trimmed.
pub fn collapse(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The XML and HTML character references a file can carry (`&amp;`, `&#039;`, `&#x27;`, `&nbsp;`); anything else is kept.
pub(crate) fn decode_entities(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(i) = rest.find('&') {
        out.push_str(&rest[..i]);
        rest = &rest[i..];
        let end = rest[..rest.len().min(12)].find(';');
        let decoded = end.and_then(|e| {
            let name = &rest[1..e];
            let ch = match name {
                "amp" => Some('&'),
                "lt" => Some('<'),
                "gt" => Some('>'),
                "quot" => Some('"'),
                "apos" => Some('\''),
                "nbsp" => Some('\u{a0}'),
                _ => {
                    let n = if let Some(h) = name.strip_prefix("#x").or_else(|| name.strip_prefix("#X")) {
                        u32::from_str_radix(h, 16).ok()
                    } else if let Some(d) = name.strip_prefix('#') {
                        d.parse::<u32>().ok()
                    } else {
                        None
                    };
                    n.and_then(char::from_u32)
                }
            };
            ch.map(|c| (c, e))
        });
        match decoded {
            Some((c, e)) => {
                out.push(c);
                rest = &rest[e + 1..];
            }
            None => {
                out.push('&');
                rest = &rest[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// HTML in a description as plain lines: `<br>` and `<p>` break lines, other tags go, character references are decoded,
/// each line is trimmed and empty lines are dropped.
pub(crate) fn html_lines(s: &str) -> Vec<String> {
    let mut text = String::new();
    let mut rest = s;
    while let Some(i) = rest.find('<') {
        text.push_str(&rest[..i]);
        let Some(j) = rest[i..].find('>') else {
            text.push_str(&rest[i..]);
            rest = "";
            break;
        };
        let tag = rest[i + 1..i + j].trim().trim_start_matches('/').to_ascii_lowercase();
        let tag_name: String = tag.chars().take_while(|c| c.is_ascii_alphanumeric()).collect();
        if matches!(tag_name.as_str(), "br" | "p" | "div" | "li" | "tr") {
            text.push('\n');
        }
        rest = &rest[i + j + 1..];
    }
    text.push_str(rest);
    decode_entities(&text).lines().map(|l| collapse(&l.replace('\u{a0}', " "))).filter(|l| !l.is_empty()).collect()
}

/// The first `href` of an `<a>` tag in HTML, decoded.
pub(crate) fn first_href(s: &str) -> Option<String> {
    let lower = s.to_ascii_lowercase();
    let i = lower.find("href=")?;
    let after = &s[i + 5..];
    let q = after.chars().next()?;
    let v = if q == '\'' || q == '"' { after[1..].split(q).next()? } else { after.split(|c: char| c.is_whitespace() || c == '>').next()? };
    let v = decode_entities(v.trim());
    (!v.is_empty()).then_some(v)
}

/// `slug` of the Notebook actions (docs/ACTIONS.md): lower case, every run of other characters one `_`, trimmed of `_`,
/// cut to `limit` characters (and trimmed again); `empty` when nothing is left.
pub fn slug(s: &str, limit: usize, empty: &str) -> String {
    let mut out = String::new();
    for ch in s.to_lowercase().chars() {
        if ch.is_ascii_lowercase() || ch.is_ascii_digit() {
            out.push(ch);
        } else if !out.ends_with('_') {
            out.push('_');
        }
    }
    let t: String = out.trim_matches('_').chars().take(limit).collect();
    let t = t.trim_matches('_').to_string();
    if t.is_empty() { empty.to_string() } else { t }
}

/// `unique` of the Notebook actions: `name`, else `name` cut to make room for `_2`, `_3`, ... until it is not taken.
pub fn unique(name: &str, taken: &[String], limit: usize) -> String {
    if !taken.iter().any(|t| t == name) {
        return name.to_string();
    }
    let mut i = 2;
    loop {
        let suffix = format!("_{i}");
        let keep: String = name.chars().take(limit.saturating_sub(suffix.len())).collect();
        let c = format!("{}{suffix}", keep.trim_end_matches('_'));
        if !taken.contains(&c) {
            return c;
        }
        i += 1;
    }
}

/// What a file is, from its name and (for a KMZ or a JSON) its first bytes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileKind {
    Kml,
    Kmz,
    Gpx,
    GeoJson,
    ChirpCsv,
}

pub fn file_kind(name: &str, bytes: &[u8]) -> Option<FileKind> {
    let lower = name.to_ascii_lowercase();
    let ext = lower.rsplit_once('.').map(|(_, e)| e).unwrap_or("");
    match ext {
        "kmz" => Some(FileKind::Kmz),
        "kml" if bytes.starts_with(b"PK\x03\x04") => Some(FileKind::Kmz),
        "kml" => Some(FileKind::Kml),
        "gpx" => Some(FileKind::Gpx),
        "geojson" | "json" => Some(FileKind::GeoJson),
        "csv" => Some(FileKind::ChirpCsv),
        _ => None,
    }
}

/// The text of a file read as UTF-8 (a byte order mark is dropped).
pub(crate) fn utf8(bytes: &[u8], what: &str) -> crate::Result<String> {
    let b = bytes.strip_prefix(b"\xef\xbb\xbf").unwrap_or(bytes);
    String::from_utf8(b.to_vec()).map_err(|_| bad(format!("{what}: not UTF-8 text")))
}

/// A layer file of any of the layer formats.
pub fn parse_layer(kind: FileKind, bytes: &[u8]) -> crate::Result<ParsedLayer> {
    match kind {
        FileKind::Kml => kml::parse_layer(&utf8(bytes, "KML")?),
        FileKind::Kmz => kml::parse_layer(&utf8(&zip::kml_of_kmz(bytes)?, "KML in the KMZ")?),
        FileKind::Gpx => gpx::parse(&utf8(bytes, "GPX")?),
        FileKind::GeoJson => geojson::parse(&utf8(bytes, "GeoJSON")?),
        FileKind::ChirpCsv => Err(bad("a CHIRP CSV is a repeater list, not a map layer")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn slug_and_unique_follow_the_notebook_rules() {
        assert_eq!(slug("Rally Points", 26, "layer"), "rally_points");
        assert_eq!(slug("  Élk camp #2!! ", 26, "layer"), "lk_camp_2");
        assert_eq!(slug("!!!", 26, "layer"), "layer");
        assert_eq!(slug("abcdefghij_klmnopqrstuvwxyz_0123", 26, "x"), "abcdefghij_klmnopqrstuvwxy");
        assert_eq!(slug("abcdefghijklmnopqrstuvwxy_z", 26, "x"), "abcdefghijklmnopqrstuvwxy");
        let taken = vec!["layer_a".to_string(), "layer_a_2".to_string()];
        assert_eq!(unique("layer_a", &taken, 32), "layer_a_3");
        assert_eq!(unique("layer_b", &taken, 32), "layer_b");
        let long = "layer_abcdefghijklmnopqrstuvwxyz".to_string();
        assert_eq!(unique(&long, &[long.clone()], 32), "layer_abcdefghijklmnopqrstuvwx_2");
    }

    #[test]
    fn entities_and_html() {
        assert_eq!(decode_entities("Coeur d&#039;Alene &amp; &#x41;&nbsp;x &bogus; &"), "Coeur d'Alene & A\u{a0}x &bogus; &");
        assert_eq!(html_lines("\nCascade<br>\n927.162500- 151.4<BR/>On-air: Yes<br><a href='x'>Click</a>\n"), ["Cascade", "927.162500- 151.4", "On-air: Yes", "Click"]);
        assert_eq!(first_href("<a href='https://e.org/d.php?a=1&amp;ID=2'>x</a>").as_deref(), Some("https://e.org/d.php?a=1&ID=2"));
        assert_eq!(first_href("no link"), None);
    }

    #[test]
    fn kinds_from_names() {
        assert_eq!(file_kind("a.KML", b"<?xml"), Some(FileKind::Kml));
        assert_eq!(file_kind("a.kml", b"PK\x03\x04.."), Some(FileKind::Kmz));
        assert_eq!(file_kind("a.kmz", b""), Some(FileKind::Kmz));
        assert_eq!(file_kind("a.gpx", b""), Some(FileKind::Gpx));
        assert_eq!(file_kind("a.json", b""), Some(FileKind::GeoJson));
        assert_eq!(file_kind("RB.csv", b""), Some(FileKind::ChirpCsv));
        assert_eq!(file_kind("a.txt", b""), None);
    }
}
