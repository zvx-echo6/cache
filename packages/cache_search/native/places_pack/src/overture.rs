//! Overture Maps places from the CSV export (14 columns, geometry as hex EWKB). Overture GeoParquet will be a second
//! `PlaceSource` that produces the same `Raw` records; nothing after this file knows which one was used.

use crate::model::{format_phone, Harvest, PlaceSource, Raw, Wiki};
use crate::rules::{generic_kind_id, Rules};
use std::path::PathBuf;

pub struct OvertureCsv {
    pub path: PathBuf,
}

fn unhex(s: &str) -> Option<Vec<u8>> {
    if s.len() % 2 != 0 {
        return None;
    }
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(s.get(i..i + 2)?, 16).ok()).collect()
}

/// (lat, lon) of a point in hex EWKB (little endian, with or without an SRID).
pub fn point_from_ewkb_hex(hex: &str) -> Option<(f64, f64)> {
    let b = unhex(hex.trim())?;
    if b.len() < 21 || b[0] != 1 {
        return None;
    }
    let t = u32::from_le_bytes(b[1..5].try_into().ok()?);
    if t & 0xff != 1 {
        return None;
    }
    let off = if t & 0x2000_0000 != 0 { 9 } else { 5 };
    let x = f64::from_le_bytes(b.get(off..off + 8)?.try_into().ok()?);
    let y = f64::from_le_bytes(b.get(off + 8..off + 16)?.try_into().ok()?);
    (x.is_finite() && y.is_finite() && x.abs() <= 180.0 && y.abs() <= 90.0).then_some((y, x))
}

fn nonempty(s: Option<&str>) -> Option<String> {
    s.map(str::trim).filter(|s| !s.is_empty()).map(str::to_string)
}

impl PlaceSource for OvertureCsv {
    fn describe(&self) -> String {
        format!("overture csv {}", self.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default())
    }

    fn read(&mut self, rules: &Rules, out: &mut Harvest) -> Result<(), String> {
        let mut rdr = csv::ReaderBuilder::new().flexible(true).from_path(&self.path).map_err(|e| format!("{}: {e}", self.path.display()))?;
        let head = rdr.headers().map_err(|e| e.to_string())?.clone();
        let col = |n: &str| head.iter().position(|h| h == n).ok_or_else(|| format!("overture csv: column {n:?} is missing"));
        let (c_id, c_geom, c_name, c_cat, c_conf) = (col("id")?, col("geometry")?, col("name")?, col("basic_category")?, col("confidence")?);
        let (c_phone, c_web, c_brand) = (col("phone")?, col("website")?, col("brand_name")?);
        let c_brand_wd = col("brand_wikidata")?;
        for rec in rdr.records() {
            let rec = rec.map_err(|e| e.to_string())?;
            let basic = rec.get(c_cat).unwrap_or("").trim();
            let conf: f64 = rec.get(c_conf).and_then(|s| s.trim().parse().ok()).unwrap_or(0.0);
            let name = nonempty(rec.get(c_name));
            let (category, enrich) = match rules.overture_category(basic, conf) {
                Some((c, r)) => (Some(c.id.clone()), r.require_match.as_ref().map(|e| (e.category.clone(), e.radius_m))),
                None => (None, None),
            };
            // A category place needs a name to be useful; a general place needs one and a higher confidence.
            let keep = match &category {
                Some(_) => name.is_some(),
                None => name.is_some() && !basic.is_empty() && conf >= rules.general.overture.min_confidence,
            };
            if !keep {
                continue;
            }
            let Some((lat, lon)) = rec.get(c_geom).and_then(point_from_ewkb_hex) else { continue };
            let mut alt = Vec::new();
            if let Some(b) = nonempty(rec.get(c_brand)) {
                if Some(&b) != name.as_ref() {
                    alt.push(b);
                }
            }
            out.places.push(Raw {
                source: "overture",
                source_id: format!("overture:{}", rec.get(c_id).unwrap_or("").trim()),
                name,
                alt,
                kind_id: Some(rules.overture_kind(category.as_deref(), basic).map(|k| k.id.clone()).unwrap_or_else(|| generic_kind_id(basic))),
                category,
                kind: basic.to_string(),
                lat,
                lon,
                street: None,
                city: None,
                phone: rec.get(c_phone).and_then(format_phone),
                hours: None,
                website: nonempty(rec.get(c_web)),
                confidence: Some(conf),
                wiki: Wiki::default(),
                // The brand's Wikidata item (a chain), never the place's own.
                brand_wikidata: nonempty(rec.get(c_brand_wd)).filter(|q| crate::model::is_qid(q)),
                enrich,
                matched: None,
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ewkb_point() {
        // First row of the Idaho export: OAKLEY.
        let (lat, lon) = point_from_ewkb_hex("0101000020E610000026FF93BF7B785CC0DDB1D826151F4540").unwrap();
        assert!((lat - 42.242833).abs() < 1e-5 && (lon + 113.882553).abs() < 1e-5, "{lat} {lon}");
        assert!(point_from_ewkb_hex("zz").is_none());
        assert!(point_from_ewkb_hex("0103000020E6100000").is_none());
    }
}
