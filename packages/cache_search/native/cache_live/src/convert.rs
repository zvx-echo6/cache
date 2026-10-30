//! Response bodies become one JSON tree, which the mapping reads. JSON is parsed as is; XML, CSV, TSV and TLE text
//! are converted by fixed rules, so a definition maps every format with the same paths.
//!
//! XML: an element becomes an object; attributes are keys that start with `@`; text next to attributes or children is
//! `#text`; an element with only text is that text (empty: null); a repeated element becomes an array (and the names in
//! `xml.always_array` are arrays even when they occur once). Namespace prefixes are dropped. The root element is the
//! only member of the tree: `{"feed": {...}}`. DOCTYPE entity definitions are never expanded.
//!
//! CSV and TSV: an array of objects keyed by the header row (values are text); see `TableDef`.
//!
//! TLE: an array of `{name, norad_id, classification, intl_designator, epoch, inclination_deg, raan_deg, eccentricity,
//! arg_perigee_deg, mean_anomaly_deg, mean_motion_rev_per_day, rev_number, line1, line2}` from two-line element sets
//! with or without a name line before them.

use crate::def::{TableDef, XmlDef};
use crate::{Error, Result};
use quick_xml::events::Event;
use quick_xml::Reader;
use serde_json::{Map, Number, Value};
use std::io::Read;

fn bad(m: impl Into<String>) -> Error {
    Error::bad_response(m)
}

/// Undo gzip when the bytes start with its magic number; the result may not exceed `max` bytes.
pub fn gunzip_if_needed(bytes: Vec<u8>, max: u64) -> Result<Vec<u8>> {
    if bytes.len() < 2 || bytes[0] != 0x1f || bytes[1] != 0x8b {
        return Ok(bytes);
    }
    let mut out = Vec::new();
    flate2::read::GzDecoder::new(&bytes[..])
        .take(max + 1)
        .read_to_end(&mut out)
        .map_err(|e| bad(format!("the response is damaged gzip: {e}")))?;
    if out.len() as u64 > max {
        return Err(bad(format!("the response is larger than {} MB once unpacked (the definition's max_bytes limits it)", max / (1024 * 1024))));
    }
    Ok(out)
}

/// The tree of a response body. `kind` is the definition's `response` (None = json).
pub fn to_tree(bytes: &[u8], kind: Option<&str>, table: Option<&TableDef>, xml: Option<&XmlDef>) -> Result<Value> {
    let text = String::from_utf8_lossy(bytes);
    let text = text.trim_start_matches('\u{feff}');
    let kind = match kind.unwrap_or("json") {
        "auto" => match text.trim_start().chars().next() {
            Some('{') | Some('[') => "json",
            Some('<') => "xml",
            _ => "csv",
        },
        "geojson" => "json",
        k => k,
    };
    match kind {
        "json" => serde_json::from_str(text).map_err(|e| bad(format!("the response is not JSON: {e}"))),
        "xml" => xml_tree(text, xml.map(|x| x.always_array.as_slice()).unwrap_or(&[])),
        "csv" => table_tree(text, table, b','),
        "tsv" => table_tree(text, table, b'\t'),
        "tle" => tle_tree(text),
        k => Err(bad(format!("unknown response type {k:?}"))),
    }
}

struct Node {
    name: String,
    members: Map<String, Value>,
    text: String,
}

fn local(name: &[u8]) -> String {
    let s = String::from_utf8_lossy(name);
    s.rsplit(':').next().unwrap_or("").to_string()
}

fn add(members: &mut Map<String, Value>, key: String, v: Value, always_array: &[String]) {
    let force = always_array.contains(&key);
    match members.get_mut(&key) {
        Some(Value::Array(a)) => a.push(v),
        Some(old) => {
            let first = old.take();
            *old = Value::Array(vec![first, v]);
        }
        None => {
            members.insert(key, if force { Value::Array(vec![v]) } else { v });
        }
    }
}

fn finish(n: Node) -> Value {
    if n.members.is_empty() {
        let t = n.text.trim();
        return if t.is_empty() { Value::Null } else { Value::String(t.to_string()) };
    }
    let mut m = n.members;
    let t = n.text.trim();
    if !t.is_empty() {
        m.insert("#text".into(), Value::String(t.to_string()));
    }
    Value::Object(m)
}

fn xml_tree(text: &str, always_array: &[String]) -> Result<Value> {
    let mut reader = Reader::from_str(text);
    reader.config_mut().check_end_names = true;
    let mut stack: Vec<Node> = Vec::new();
    let mut root: Option<(String, Value)> = None;
    let open = |e: &quick_xml::events::BytesStart| -> Result<Node> {
        let mut members = Map::new();
        for a in e.attributes() {
            let a = a.map_err(|e| bad(format!("XML attribute: {e}")))?;
            let key = local(a.key.as_ref());
            let raw = String::from_utf8_lossy(a.key.as_ref()).to_string();
            if raw == "xmlns" || raw.starts_with("xmlns:") {
                continue;
            }
            let v = a.unescape_value().map_err(|e| bad(format!("XML attribute: {e}")))?.to_string();
            members.insert(format!("@{key}"), Value::String(v));
        }
        Ok(Node { name: local(e.name().as_ref()), members, text: String::new() })
    };
    loop {
        match reader.read_event().map_err(|e| bad(format!("the response is not XML: {e} (at byte {})", reader.buffer_position())))? {
            Event::Start(e) => {
                if stack.len() >= 64 {
                    return Err(bad("the XML is nested more than 64 levels deep"));
                }
                stack.push(open(&e)?);
            }
            Event::Empty(e) => {
                let n = open(&e)?;
                let name = n.name.clone();
                let v = finish(n);
                match stack.last_mut() {
                    Some(p) => add(&mut p.members, name, v, always_array),
                    None => root = Some((name, v)),
                }
            }
            Event::End(_) => {
                let n = stack.pop().ok_or_else(|| bad("the XML closes an element that was not open"))?;
                let name = n.name.clone();
                let v = finish(n);
                match stack.last_mut() {
                    Some(p) => add(&mut p.members, name, v, always_array),
                    None => root = Some((name, v)),
                }
            }
            Event::Text(t) => {
                if let Some(n) = stack.last_mut() {
                    n.text.push_str(&t.unescape().map_err(|e| bad(format!("XML text: {e}")))?);
                }
            }
            Event::CData(c) => {
                if let Some(n) = stack.last_mut() {
                    n.text.push_str(&String::from_utf8_lossy(&c));
                }
            }
            Event::Eof => break,
            _ => {}
        }
    }
    if !stack.is_empty() {
        return Err(bad("the XML ends inside an element"));
    }
    let (name, v) = root.ok_or_else(|| bad("the response has no XML element"))?;
    let mut m = Map::new();
    m.insert(name, v);
    Ok(Value::Object(m))
}

fn table_tree(text: &str, t: Option<&TableDef>, default_delim: u8) -> Result<Value> {
    let d = t.cloned().unwrap_or_default();
    let delim = match d.delimiter.as_deref() {
        Some(s) if s.len() == 1 => s.as_bytes()[0],
        Some(_) => return Err(bad("table.delimiter must be one character")),
        None => default_delim,
    };
    let has_header = d.header.unwrap_or(true);
    let mut rb = csv::ReaderBuilder::new();
    rb.delimiter(delim).has_headers(false).flexible(true).trim(csv::Trim::All);
    if let Some(c) = d.comment.as_deref().and_then(|c| c.bytes().next()) {
        rb.comment(Some(c));
    }
    let mut rdr = rb.from_reader(text.as_bytes());
    let mut recs = rdr.records();
    let mut header: Vec<String> = Vec::new();
    if has_header {
        match recs.next() {
            Some(r) => header = r.map_err(|e| bad(format!("the response is not a table: {e}")))?.iter().map(str::to_string).collect(),
            None => return Ok(Value::Array(vec![])),
        }
        for _ in 0..d.skip_after_header {
            recs.next();
        }
    }
    let mut rows = Vec::new();
    for r in recs {
        let r = r.map_err(|e| bad(format!("the response is not a table: {e}")))?;
        let mut m = Map::new();
        for (i, v) in r.iter().enumerate() {
            let k = header.get(i).filter(|h| !h.is_empty()).cloned().unwrap_or_else(|| format!("c{i}"));
            m.insert(k, Value::String(v.to_string()));
        }
        rows.push(Value::Object(m));
    }
    Ok(Value::Array(rows))
}

fn num(s: &str) -> Option<Value> {
    s.trim().parse::<f64>().ok().and_then(Number::from_f64).map(Value::Number)
}

fn tle_tree(text: &str) -> Result<Value> {
    let lines: Vec<&str> = text.lines().map(|l| l.trim_end()).filter(|l| !l.trim().is_empty()).collect();
    let mut out = Vec::new();
    let mut i = 0;
    while i < lines.len() {
        let (name, l1, l2) = if lines[i].starts_with("1 ") && lines.get(i + 1).map(|l| l.starts_with("2 ")).unwrap_or(false) {
            (None, lines[i], lines[i + 1])
        } else if lines.get(i + 1).map(|l| l.starts_with("1 ")).unwrap_or(false) && lines.get(i + 2).map(|l| l.starts_with("2 ")).unwrap_or(false) {
            (Some(lines[i].trim().trim_start_matches("0 ")), lines[i + 1], lines[i + 2])
        } else {
            return Err(bad(format!("line {} is not a two-line element set", i + 1)));
        };
        i += if name.is_some() { 3 } else { 2 };
        let cut = |l: &str, a: usize, b: usize| l.get(a..b.min(l.len())).unwrap_or("").trim().to_string();
        if l1.len() < 63 || l2.len() < 63 {
            return Err(bad("a two-line element set is shorter than 69 columns"));
        }
        let mut m = Map::new();
        if let Some(n) = name {
            m.insert("name".into(), Value::String(n.to_string()));
        }
        m.insert("norad_id".into(), num(&cut(l1, 2, 7)).unwrap_or(Value::Null));
        m.insert("classification".into(), Value::String(cut(l1, 7, 8)));
        m.insert("intl_designator".into(), Value::String(cut(l1, 9, 17)));
        // epoch: two-digit year, then the day of the year with a fraction
        let yy: i32 = cut(l1, 18, 20).parse().map_err(|_| bad("bad TLE epoch year"))?;
        let day: f64 = cut(l1, 20, 32).parse().map_err(|_| bad("bad TLE epoch day"))?;
        let year = if yy < 57 { 2000 + yy } else { 1900 + yy };
        let base = chrono::NaiveDate::from_ymd_opt(year, 1, 1).and_then(|d| d.and_hms_opt(0, 0, 0)).ok_or_else(|| bad("bad TLE epoch"))?;
        let epoch = base + chrono::Duration::milliseconds(((day - 1.0) * 86_400_000.0).round() as i64);
        m.insert("epoch".into(), Value::String(epoch.format("%Y-%m-%dT%H:%M:%S+00:00").to_string()));
        m.insert("inclination_deg".into(), num(&cut(l2, 8, 16)).unwrap_or(Value::Null));
        m.insert("raan_deg".into(), num(&cut(l2, 17, 25)).unwrap_or(Value::Null));
        m.insert("eccentricity".into(), num(&format!("0.{}", cut(l2, 26, 33))).unwrap_or(Value::Null));
        m.insert("arg_perigee_deg".into(), num(&cut(l2, 34, 42)).unwrap_or(Value::Null));
        m.insert("mean_anomaly_deg".into(), num(&cut(l2, 43, 51)).unwrap_or(Value::Null));
        m.insert("mean_motion_rev_per_day".into(), num(&cut(l2, 52, 63)).unwrap_or(Value::Null));
        m.insert("rev_number".into(), num(&cut(l2, 63, 68)).unwrap_or(Value::Null));
        m.insert("line1".into(), Value::String(l1.to_string()));
        m.insert("line2".into(), Value::String(l2.to_string()));
        out.push(Value::Object(m));
    }
    Ok(Value::Array(out))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn xml_to_tree() {
        let x = r#"<?xml version="1.0"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:cap="urn:oasis:names:tc:emergency:cap:1.2">
  <title>Alerts</title>
  <entry><id>a1</id><link href="https://x/a1" rel="alternate"/><cap:event>Flood</cap:event><note lang="en">Hi &amp; bye</note></entry>
  <entry><id>a2</id><link href="https://x/a2"/><cap:event><![CDATA[Fire <now>]]></cap:event><empty/></entry>
</feed>"#;
        let t = to_tree(x.as_bytes(), Some("xml"), None, None).unwrap();
        assert_eq!(t["feed"]["title"], "Alerts");
        assert_eq!(t["feed"]["entry"][0]["link"]["@href"], "https://x/a1");
        assert_eq!(t["feed"]["entry"][0]["event"], "Flood");
        assert_eq!(t["feed"]["entry"][0]["note"], json!({"@lang": "en", "#text": "Hi & bye"}));
        assert_eq!(t["feed"]["entry"][1]["event"], "Fire <now>");
        assert_eq!(t["feed"]["entry"][1]["empty"], Value::Null);
        assert!(t["feed"].get("@xmlns").is_none());
        // a single repeated element is an object unless always_array says otherwise
        let one = "<a><b>1</b></a>";
        assert_eq!(to_tree(one.as_bytes(), Some("xml"), None, None).unwrap()["a"]["b"], "1");
        let aa = XmlDef { always_array: vec!["b".into()] };
        assert_eq!(to_tree(one.as_bytes(), Some("xml"), None, Some(&aa)).unwrap()["a"]["b"], json!(["1"]));
        assert_eq!(to_tree(b"<a><b></a>", Some("xml"), None, None).unwrap_err().code, "bad_response");
        assert_eq!(to_tree(b"not xml at all", Some("xml"), None, None).unwrap_err().code, "bad_response");
    }

    #[test]
    fn csv_tsv_and_rdb() {
        let c = "latitude,longitude,bright\n42.5,-113.8,300.1\n43.0,-114.0,\"3,1\"\n";
        let t = to_tree(c.as_bytes(), Some("csv"), None, None).unwrap();
        assert_eq!(t[0]["latitude"], "42.5");
        assert_eq!(t[1]["bright"], "3,1");
        // NWIS RDB: comments, a header row, a types row, tab separated
        let rdb = "# comment\n# more\nagency_cd\tsite_no\tgage_ht\n5s\t15s\t14n\nUSGS\t13206000\t4.5\nUSGS\t13200000\t1.2\n";
        let tb = TableDef { comment: Some("#".into()), skip_after_header: 1, ..Default::default() };
        let t = to_tree(rdb.as_bytes(), Some("tsv"), Some(&tb), None).unwrap();
        assert_eq!(t.as_array().unwrap().len(), 2);
        assert_eq!(t[0]["site_no"], "13206000");
        // no header row
        let nb = TableDef { header: Some(false), ..Default::default() };
        let t = to_tree(b"a;b\nc;d\n", Some("csv"), Some(&TableDef { delimiter: Some(";".into()), ..nb }), None).unwrap();
        assert_eq!(t[1]["c1"], "d");
        assert_eq!(to_tree(b"", Some("csv"), None, None).unwrap(), json!([]));
    }

    #[test]
    fn tle() {
        let t = "ISS (ZARYA)\n1 25544U 98067A   26298.51782528  .00016717  00000-0  10270-3 0  9993\n2 25544  51.6416 247.4627 0006703 130.5360 325.0288 15.72125391563537\n";
        let v = to_tree(t.as_bytes(), Some("tle"), None, None).unwrap();
        assert_eq!(v[0]["name"], "ISS (ZARYA)");
        assert_eq!(v[0]["norad_id"], 25544.0);
        assert_eq!(v[0]["inclination_deg"], 51.6416);
        assert_eq!(v[0]["eccentricity"], 0.0006703);
        assert_eq!(v[0]["epoch"], "2026-10-25T12:25:40+00:00");
        assert_eq!(v[0]["rev_number"], 56353.0);
        assert!(to_tree(b"garbage\nmore garbage\n", Some("tle"), None, None).is_err());
    }

    #[test]
    fn json_auto_and_gzip() {
        assert_eq!(to_tree(b"{\"a\":1}", None, None, None).unwrap()["a"], 1);
        assert_eq!(to_tree(b"\xef\xbb\xbf[1]", Some("auto"), None, None).unwrap(), json!([1]));
        assert_eq!(to_tree(b"<r>1</r>", Some("auto"), None, None).unwrap()["r"], "1");
        assert_eq!(to_tree(b"<html>", None, None, None).unwrap_err().code, "bad_response");
        use std::io::Write;
        let mut e = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        e.write_all(&vec![b'a'; 5000]).unwrap();
        let gz = e.finish().unwrap();
        assert_eq!(gunzip_if_needed(gz.clone(), 10_000).unwrap().len(), 5000);
        assert!(gunzip_if_needed(gz, 1000).is_err());
        assert_eq!(gunzip_if_needed(b"plain".to_vec(), 10).unwrap(), b"plain");
    }
}
