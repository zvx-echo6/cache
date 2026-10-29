//! Addresses in a merged places database (docs/PLACES-TILES.md): the street rows (`addr_streets`, searched through
//! `addr_fts` on both the source form and the expanded form of the street), joined where a tile edge cut a street in two,
//! and a house number found in them, or placed between its neighbours on the same side of the street.
//!
//! What is read from the query is structure only: a leading house number token (digits with an optional letter or a
//! `-`/`/` part, like coordinates are read by their format). The street words are matched against the data as prefixes, so
//! nothing here knows any word of any language.

use crate::addr::{self, Entry};
use crate::geo::haversine_km;
use crate::pack::{Pack, Result};
use rusqlite::{params, OptionalExtension};

/// Rows of one street within this distance of each other are one street (a street cut by a tile edge).
pub const JOIN_KM: f64 = 2.0;

/// One `addr_streets` row.
#[derive(Debug, Clone)]
pub struct StreetRow {
    pub id: i64,
    pub uid: String,
    /// As the source writes it ("W 10TH ST").
    pub street: String,
    pub street_expanded: Option<String>,
    pub locality: Option<String>,
    pub postal_city: Option<String>,
    pub postcode: Option<String>,
    pub state: Option<String>,
    pub country: Option<String>,
    pub lat: f64,
    pub lon: f64,
    pub min_lat: f64,
    pub max_lat: f64,
    pub min_lon: f64,
    pub max_lon: f64,
    pub numbers: Vec<u8>,
}

const STREET_COLS: &str = "s.id, s.uid, s.street, s.street_expanded, s.locality, s.postal_city, s.postcode, s.state, s.country, s.lat, s.lon, \
                           s.min_lat, s.max_lat, s.min_lon, s.max_lon, s.numbers";

fn street_row(r: &rusqlite::Row) -> rusqlite::Result<StreetRow> {
    Ok(StreetRow {
        id: r.get(0)?,
        uid: r.get(1)?,
        street: r.get(2)?,
        street_expanded: r.get(3)?,
        locality: r.get(4)?,
        postal_city: r.get(5)?,
        postcode: r.get(6)?,
        state: r.get(7)?,
        country: r.get(8)?,
        lat: r.get(9)?,
        lon: r.get(10)?,
        min_lat: r.get(11)?,
        max_lat: r.get(12)?,
        min_lon: r.get(13)?,
        max_lon: r.get(14)?,
        numbers: r.get(15)?,
    })
}

fn words(s: &str) -> Vec<String> {
    s.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(|w| w.to_lowercase()).collect()
}

fn norm(s: &str) -> String {
    words(s).join(" ")
}

impl StreetRow {
    /// The town the row is in: its locality, else its postal city.
    pub fn town(&self) -> Option<&str> {
        self.locality.as_deref().or(self.postal_city.as_deref())
    }

    /// The street rows a reader joins: same street, town and postcode.
    fn key(&self) -> (String, String, String) {
        (norm(&self.street), norm(self.town().unwrap_or("")), norm(self.postcode.as_deref().unwrap_or("")))
    }

    /// The distance between the two rows' boxes, km (0 when they overlap).
    fn gap_km(&self, o: &StreetRow) -> f64 {
        let lat = self.lat.clamp(o.min_lat, o.max_lat);
        let lon = self.lon.clamp(o.min_lon, o.max_lon);
        let (a, b) = (lat.clamp(self.min_lat, self.max_lat), lon.clamp(self.min_lon, self.max_lon));
        haversine_km(a, b, lat, lon)
    }

    pub fn entries(&self) -> Vec<Entry> {
        addr::decode(&self.numbers, self.lat, self.lon).unwrap_or_default()
    }
}

impl Pack {
    /// The pack has street rows (a merged database; a single-region pack has none).
    pub fn has_addresses(&self) -> bool {
        let conn = self.conn();
        conn.query_row("SELECT count(*) FROM sqlite_master WHERE name = 'addr_fts'", [], |r| r.get::<_, i64>(0)).map(|n| n > 0).unwrap_or(false)
    }

    /// Street rows whose street (source or expanded form) matches the FTS5 expression, best `limit` first.
    pub fn fts_streets(&self, fts: &str, limit: usize) -> Result<Vec<StreetRow>> {
        let conn = self.conn();
        let mut st = conn.prepare(&format!(
            "SELECT {STREET_COLS} FROM (SELECT rowid AS id, bm25(addr_fts) AS b FROM addr_fts WHERE addr_fts MATCH ?1 ORDER BY b LIMIT ?2) f \
             JOIN addr_streets s ON s.id = f.id ORDER BY f.b"
        ))?;
        let rows = st.query_map(params![fts, limit as i64], street_row)?;
        Ok(rows.collect::<rusqlite::Result<Vec<_>>>()?)
    }

    pub fn street_by_uid(&self, uid: &str) -> Result<Option<StreetRow>> {
        let conn = self.conn();
        Ok(conn.query_row(&format!("SELECT {STREET_COLS} FROM addr_streets s WHERE s.uid = ?1 LIMIT 1"), params![uid], street_row).optional()?)
    }

    /// The rows joined to `row`: the same street, town and postcode, within [`JOIN_KM`] of it (and of each other); `row`
    /// itself included.
    pub fn street_group(&self, row: &StreetRow) -> Result<Vec<StreetRow>> {
        let ws = words(&row.street);
        let expr = ws.iter().map(|w| format!("\"{}\"", w.replace('"', ""))).collect::<Vec<_>>().join(" ");
        let rows = if expr.is_empty() { vec![row.clone()] } else { self.fts_streets(&expr, 200)? };
        Ok(join(rows).into_iter().find(|g| g.iter().any(|r| r.id == row.id)).unwrap_or_else(|| vec![row.clone()]))
    }
}

/// Rows of the same street, town and postcode that sit within [`JOIN_KM`] of each other become one group; order is kept
/// (a group is where its first row was).
pub fn join(rows: Vec<StreetRow>) -> Vec<Vec<StreetRow>> {
    let mut groups: Vec<Vec<StreetRow>> = Vec::new();
    for r in rows {
        if groups.iter().flatten().any(|g| g.id == r.id) {
            continue;
        }
        let key = r.key();
        match groups.iter_mut().find(|g| g[0].key() == key && g.iter().any(|x| x.gap_km(&r) <= JOIN_KM)) {
            Some(g) => g.push(r),
            None => groups.push(vec![r]),
        }
    }
    groups
}

/// A house number token: a run of ASCII digits, then nothing, one letter, or a part starting with `-` or `/` ("350",
/// "12A", "101-1/2", "1/2"). A format check, like reading coordinates; not a word list.
pub fn is_house_number(t: &str) -> bool {
    let digits = t.bytes().take_while(u8::is_ascii_digit).count();
    if digits == 0 {
        return false;
    }
    let rest = &t[digits..];
    let mut c = rest.chars();
    match c.next() {
        None => true,
        Some(l) if l.is_alphabetic() => c.next().is_none(),
        Some('-' | '/') => !c.as_str().is_empty() && c.as_str().chars().all(|x| x.is_alphanumeric() || x == '-' || x == '/'),
        _ => false,
    }
}

/// "350 N State St, Salt Lake City" is ("350", "N State St, Salt Lake City"): the query starts with a house number and has
/// more after it. None otherwise.
pub fn split_house_number(q: &str) -> Option<(&str, &str)> {
    let q = q.trim();
    let end = q.find(|c: char| c.is_whitespace() || c == ',')?;
    let (tok, rest) = (&q[..end], q[end..].trim_start_matches(|c: char| c.is_whitespace() || c == ',').trim());
    (is_house_number(tok) && !rest.is_empty()).then_some((tok, rest))
}

/// Where a house number is on a street.
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    /// As the data writes it (an exact match), or as asked (placed between its neighbours).
    pub number: String,
    pub lat: f64,
    pub lon: f64,
    /// Placed between the nearest numbers either side, not found.
    pub approximate: bool,
    /// The street row that holds the number, or the nearer of the two it was placed between.
    pub uid: String,
}

/// The house number `asked` on a street (its joined rows). An exact number (numeric part and suffix, letters in any case)
/// is found; otherwise it is placed proportionally between the nearest numbers below and above it of the same parity, and
/// only when there are both. None when neither applies.
pub fn find_number(group: &[StreetRow], asked: &str) -> Option<Found> {
    let entries: Vec<(Entry, &str)> = group.iter().flat_map(|r| r.entries().into_iter().map(move |e| (e, r.uid.as_str()))).collect();
    let (num, suffix) = addr::split_number(asked);
    let exact = entries.iter().find(|(e, _)| if num == 0 { e.num == 0 && e.suffix.eq_ignore_ascii_case(asked) } else { e.num == num && e.suffix.eq_ignore_ascii_case(suffix) });
    if let Some((e, uid)) = exact {
        return Some(Found { number: e.number(), lat: e.lat, lon: e.lon, approximate: false, uid: uid.to_string() });
    }
    if num == 0 {
        return None;
    }
    let side = entries.iter().filter(|(e, _)| e.num > 0 && e.num % 2 == num % 2);
    let below = side.clone().filter(|(e, _)| e.num <= num).max_by_key(|(e, _)| e.num)?;
    if below.0.num == num {
        // The same number with another suffix ("12" for "12B"): its point.
        return Some(Found { number: asked.to_string(), lat: below.0.lat, lon: below.0.lon, approximate: true, uid: below.1.to_string() });
    }
    let above = side.filter(|(e, _)| e.num > num).min_by_key(|(e, _)| e.num)?;
    let t = (num - below.0.num) as f64 / (above.0.num - below.0.num) as f64;
    let uid = if t <= 0.5 { below.1 } else { above.1 };
    Some(Found {
        number: asked.to_string(),
        lat: below.0.lat + t * (above.0.lat - below.0.lat),
        lon: below.0.lon + t * (above.0.lon - below.0.lon),
        approximate: true,
        uid: uid.to_string(),
    })
}

/// "addr:<uid>/<number>" is (uid, number).
pub fn parse_id(id: &str) -> Option<(&str, &str)> {
    let (uid, number) = id.strip_prefix("addr:")?.split_once('/')?;
    (!uid.is_empty() && !number.is_empty()).then_some((uid, number))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: i64, uid: &str, street: &str, nums: &[(&str, f64, f64)]) -> StreetRow {
        let k = nums.len() as f64;
        let (lat, lon) = (nums.iter().map(|n| n.1).sum::<f64>() / k, nums.iter().map(|n| n.2).sum::<f64>() / k);
        let (mut a, mut b, mut c, mut d) = (f64::MAX, f64::MIN, f64::MAX, f64::MIN);
        for n in nums {
            (a, b, c, d) = (a.min(n.1), b.max(n.1), c.min(n.2), d.max(n.2));
        }
        StreetRow {
            id,
            uid: uid.into(),
            street: street.into(),
            street_expanded: None,
            locality: Some("Burley".into()),
            postal_city: None,
            postcode: Some("83318".into()),
            state: Some("ID".into()),
            country: Some("US".into()),
            lat,
            lon,
            min_lat: a,
            max_lat: b,
            min_lon: c,
            max_lon: d,
            numbers: addr::encode(lat, lon, nums).unwrap(),
        }
    }

    #[test]
    fn house_number_tokens() {
        for t in ["350", "12A", "12a", "101-1/2", "1/2", "7"] {
            assert!(is_house_number(t), "{t}");
        }
        for t in ["", "A12", "12AB", "40.76", "12-", "N", "12,"] {
            assert!(!is_house_number(t), "{t}");
        }
        assert_eq!(split_house_number("350 N State St, Salt Lake City"), Some(("350", "N State St, Salt Lake City")));
        assert_eq!(split_house_number("  12A, Main St "), Some(("12A", "Main St")));
        assert_eq!(split_house_number("350"), None);
        assert_eq!(split_house_number("Walgreens 350"), None);
        assert_eq!(split_house_number("40.76 -111.89"), None);
        assert_eq!(parse_id("addr:0123abcd/1/2"), Some(("0123abcd", "1/2")));
        assert_eq!(parse_id("place:x"), None);
    }

    #[test]
    fn exact_interpolated_and_missing_numbers() {
        let r = row(1, "u1", "Main St", &[("100", 42.0, -113.0), ("110", 42.001, -113.0), ("101", 42.0, -112.999), ("12B", 41.99, -113.0)]);
        let g = [r];
        let f = find_number(&g, "110").unwrap();
        assert!(!f.approximate && f.number == "110" && (f.lat - 42.001).abs() < 1e-6);
        // 104 is 40 % of the way from 100 to 110 on the even side; the odd 101 is not used.
        let f = find_number(&g, "104").unwrap();
        assert!(f.approximate && f.number == "104" && (f.lat - 42.0004).abs() < 1e-6 && (f.lon + 113.0).abs() < 1e-6, "{f:?}");
        assert!(find_number(&g, "12b").is_some_and(|f| !f.approximate && f.number == "12B"));
        // Nothing above 103 on the odd side, nothing beyond the ends: not placed.
        assert!(find_number(&g, "103").is_none());
        assert!(find_number(&g, "120").is_none());
        assert!(find_number(&g, "8").is_none());
        // 98 is placed between the even 12B and 100.
        assert!(find_number(&g, "98").is_some_and(|f| f.approximate));
        // The same number with a suffix the data lacks takes that number's point.
        assert!(find_number(&g, "110C").is_some_and(|f| f.approximate && (f.lat - 42.001).abs() < 1e-6));
    }

    #[test]
    fn rows_of_one_street_join_across_a_tile_edge() {
        let w = row(1, "w", "Baseline Rd", &[("2000", 42.6, -113.01), ("2040", 42.6, -113.002)]);
        let e = row(2, "e", "Baseline Rd", &[("2060", 42.6, -112.998), ("2100", 42.6, -112.99)]);
        let far = row(3, "far", "Baseline Rd", &[("10", 43.6, -112.0)]);
        let other = row(4, "o", "Overland Ave", &[("2050", 42.6, -113.0)]);
        let groups = join(vec![w, e, far, other]);
        assert_eq!(groups.iter().map(|g| g.iter().map(|r| r.uid.as_str()).collect::<Vec<_>>()).collect::<Vec<_>>(), [vec!["w", "e"], vec!["far"], vec!["o"]]);
        // 2050 lies between 2040 (west row) and 2060 (east row).
        let f = find_number(&groups[0], "2050").unwrap();
        assert!(f.approximate && (f.lon + 113.0).abs() < 1e-6, "{f:?}");
    }
}
