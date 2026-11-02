//! Readers for the files the cache-packs `offroad-region` recipe prepares from original public sources
//! (`build-sources`): the class -> friction rule table, point TSVs and the MVUM GeoJSON-seq.
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::io::{BufRead, BufReader};
use std::path::Path;

/// WorldCover class -> friction x10 lookup (`rules/offroad/class_friction.tsv` in cache-packs). Classes the table
/// does not list (including 0 = no data) map to 0, which the router treats as impassable.
#[derive(Debug, Clone)]
pub struct ClassFriction {
    pub table: [u8; 256],
    pub sha256: String,
}

impl ClassFriction {
    pub fn parse(text: &str) -> Result<ClassFriction, String> {
        let mut table = [0u8; 256];
        let mut header = false;
        let mut n = 0;
        for (i, line) in text.lines().enumerate() {
            let line = line.trim_end_matches('\r');
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            let f: Vec<&str> = line.split('\t').collect();
            if !header {
                if f.len() < 2 || f[0] != "class" || f[1] != "friction" {
                    return Err(format!("class_friction line {}: header must be class<TAB>friction", i + 1));
                }
                header = true;
                continue;
            }
            let p = |s: &str| s.trim().parse::<u8>().map_err(|_| format!("class_friction line {}: bad value {s:?}", i + 1));
            let (c, v) = (p(f[0])?, p(f.get(1).copied().unwrap_or(""))?);
            if c == 0 {
                return Err(format!("class_friction line {}: class 0 is no data and always maps to 0", i + 1));
            }
            if table[c as usize] != 0 {
                return Err(format!("class_friction line {}: class {c} listed twice", i + 1));
            }
            table[c as usize] = v;
            n += 1;
        }
        if n == 0 {
            return Err("class_friction: no rows".into());
        }
        Ok(ClassFriction { table, sha256: hex(&Sha256::digest(text.as_bytes())) })
    }

    pub fn load(p: &Path) -> Result<ClassFriction, String> {
        ClassFriction::parse(&std::fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))?)
    }

    pub fn apply(&self, class: &[u8]) -> Vec<u8> {
        class.iter().map(|&c| self.table[c as usize]).collect()
    }
}

fn hex(b: &[u8]) -> String {
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// One point row: (lat, lon, name, kind, access). `kind` is parking_type or highway class.
pub type PointRow = (f64, f64, String, String, String);

/// Reads a point TSV with a header row. Parking: `lat lon name parking_type access`; entry points:
/// `lat lon highway name`. Columns are found by name, so the two layouts share one reader.
pub fn read_points_tsv(p: &Path) -> Result<Vec<PointRow>, String> {
    let f = std::fs::File::open(p).map_err(|e| format!("{}: {e}", p.display()))?;
    parse_points_tsv(BufReader::new(f)).map_err(|e| format!("{}: {e}", p.display()))
}

pub fn parse_points_tsv<R: BufRead>(r: R) -> Result<Vec<PointRow>, String> {
    let mut lines = r.lines();
    let head = lines.next().ok_or("empty file")?.map_err(|e| e.to_string())?;
    let cols: Vec<&str> = head.split('\t').collect();
    let at = |n: &str| cols.iter().position(|c| *c == n);
    let (ilat, ilon) = (at("lat").ok_or("no lat column")?, at("lon").ok_or("no lon column")?);
    let iname = at("name");
    let ikind = at("parking_type").or(at("highway"));
    let iacc = at("access");
    let mut out = Vec::new();
    for (n, line) in lines.enumerate() {
        let line = line.map_err(|e| e.to_string())?;
        if line.is_empty() {
            continue;
        }
        let f: Vec<&str> = line.split('\t').collect();
        let get = |i: Option<usize>| i.and_then(|i| f.get(i)).map_or(String::new(), |s| s.to_string());
        let num = |i: usize| f.get(i).and_then(|s| s.parse::<f64>().ok()).ok_or(format!("row {}: bad coordinate", n + 2));
        out.push((num(ilat)?, num(ilon)?, get(iname), get(ikind), get(iacc)));
    }
    Ok(out)
}

/// One MVUM feature from `prep_mvum.py`: the router's fields plus the geometry as (lon, lat) parts.
#[derive(Debug, Clone, PartialEq)]
pub struct MvumRow {
    pub is_trail: bool,
    pub symbol: Option<String>,
    pub seasonal: Option<String>,
    pub maint: Option<String>,
    /// (status, dates) for mtb (e_bike_class1), atv and vehicle (highclearancevehicle), the pack's order.
    pub access: [(Option<String>, Option<String>); 3],
    pub lines: Vec<Vec<(f64, f64)>>,
}

pub fn parse_mvum_line(line: &str) -> Result<Option<MvumRow>, String> {
    let v: Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
    let p = &v["properties"];
    let s = |k: &str| match &p[k] {
        Value::String(x) => Some(x.clone()),
        Value::Number(x) => Some(x.to_string()),
        _ => None,
    };
    let g = &v["geometry"];
    let to_part = |c: &Value| -> Vec<(f64, f64)> {
        c.as_array().map_or(Vec::new(), |pts| {
            pts.iter().filter_map(|q| Some((q.get(0)?.as_f64()?, q.get(1)?.as_f64()?))).collect()
        })
    };
    let lines: Vec<Vec<(f64, f64)>> = match g["type"].as_str() {
        Some("LineString") => vec![to_part(&g["coordinates"])],
        Some("MultiLineString") => g["coordinates"].as_array().map_or(Vec::new(), |a| a.iter().map(to_part).collect()),
        _ => Vec::new(),
    };
    let lines: Vec<_> = lines.into_iter().filter(|l| l.len() >= 2).collect();
    if lines.is_empty() {
        return Ok(None);
    }
    Ok(Some(MvumRow {
        is_trail: p["is_trail"].as_i64().unwrap_or(0) != 0,
        symbol: s("symbol"),
        seasonal: s("seasonal"),
        maint: s("operationalmaintlevel"),
        access: [
            (s("e_bike_class1"), s("e_bike_class1_dur")),
            (s("atv"), s("atv_datesopen")),
            (s("highclearancevehicle"), s("highclearancevehicle_datesopen")),
        ],
        lines,
    }))
}

pub fn read_mvum(p: &Path) -> Result<Vec<MvumRow>, String> {
    let f = std::fs::File::open(p).map_err(|e| format!("{}: {e}", p.display()))?;
    let mut out = Vec::new();
    for (n, line) in BufReader::new(f).lines().enumerate() {
        let line = line.map_err(|e| e.to_string())?;
        if line.trim().is_empty() {
            continue;
        }
        if let Some(r) = parse_mvum_line(&line).map_err(|e| format!("{} line {}: {e}", p.display(), n + 1))? {
            out.push(r);
        }
    }
    Ok(out)
}

/// (min_lon, max_lon, min_lat, max_lat) of a feature's parts.
pub fn lines_bbox(lines: &[Vec<(f64, f64)>]) -> (f64, f64, f64, f64) {
    let (mut x0, mut x1, mut y0, mut y1) = (f64::MAX, f64::MIN, f64::MAX, f64::MIN);
    for l in lines {
        for &(x, y) in l {
            x0 = x0.min(x);
            x1 = x1.max(x);
            y0 = y0.min(y);
            y1 = y1.max(y);
        }
    }
    (x0, x1, y0, y1)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn class_friction_table() {
        let t = ClassFriction::parse("# comment\nclass\tfriction\tnote\n10\t20\ttree\n80\t255\twater\n").unwrap();
        assert_eq!(t.apply(&[0, 10, 80, 30]), vec![0, 20, 255, 0]);
        assert_eq!(t.sha256.len(), 64);
        assert!(ClassFriction::parse("class\tfriction\n10\t20\n10\t30\n").unwrap_err().contains("twice"));
        assert!(ClassFriction::parse("class\tfriction\n0\t20\n").unwrap_err().contains("no data"));
        assert!(ClassFriction::parse("klass\tfriction\n10\t20\n").is_err());
        assert!(ClassFriction::parse("class\tfriction\n").is_err());
        assert!(ClassFriction::parse("class\tfriction\n10\t300\n").is_err());
    }

    #[test]
    fn points_tsv_layouts() {
        let park = "lat\tlon\tname\tparking_type\taccess\n43.5\t-116.2\tLot A\tsurface\tyes\n43.6\t-116.3\t\t\t\n";
        let p = parse_points_tsv(park.as_bytes()).unwrap();
        assert_eq!(p[0], (43.5, -116.2, "Lot A".into(), "surface".into(), "yes".into()));
        assert_eq!(p[1], (43.6, -116.3, String::new(), String::new(), String::new()));
        let entry = "lat\tlon\thighway\tname\n44.1\t-115.0\ttrack\tFS 123\n";
        let e = parse_points_tsv(entry.as_bytes()).unwrap();
        assert_eq!(e, vec![(44.1, -115.0, "FS 123".into(), "track".into(), String::new())]);
        assert!(parse_points_tsv("lat\tlon\n1\tx\n".as_bytes()).is_err());
        assert!(parse_points_tsv("name\n".as_bytes()).is_err());
    }

    #[test]
    fn mvum_feature_line() {
        let l = r#"{"type":"Feature","properties":{"symbol":"1","seasonal":"yearlong","operationalmaintlevel":"2 - HIGH CLEARANCE VEHICLES","e_bike_class1":null,"atv":"open","atv_datesopen":"06/01-10/31","highclearancevehicle":"open","is_trail":0,"fid":"{X}"},"geometry":{"type":"MultiLineString","coordinates":[[[-115.5,44.0],[-115.4,44.1]],[[-115.0,44.0]]]}}"#;
        let r = parse_mvum_line(l).unwrap().unwrap();
        assert!(!r.is_trail);
        assert_eq!(r.symbol.as_deref(), Some("1"));
        assert_eq!(r.maint.as_deref(), Some("2 - HIGH CLEARANCE VEHICLES"));
        assert_eq!(r.access[0], (None, None));
        assert_eq!(r.access[1], (Some("open".into()), Some("06/01-10/31".into())));
        assert_eq!(r.access[2], (Some("open".into()), None));
        assert_eq!(r.lines, vec![vec![(-115.5, 44.0), (-115.4, 44.1)]]); // the one-point part is dropped
        assert_eq!(lines_bbox(&r.lines), (-115.5, -115.4, 44.0, 44.1));
        let t = r#"{"properties":{"is_trail":1,"symbol":12},"geometry":{"type":"LineString","coordinates":[[1,2],[3,4]]}}"#;
        let r = parse_mvum_line(t).unwrap().unwrap();
        assert!(r.is_trail && r.symbol.as_deref() == Some("12"));
        assert!(parse_mvum_line(r#"{"properties":{},"geometry":null}"#).unwrap().is_none());
        assert!(parse_mvum_line("not json").is_err());
    }
}
