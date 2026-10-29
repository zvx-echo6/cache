//! KML: layers (pins, lines and areas from any Document or Folder depth), RepeaterBook-style repeater pins, and the KML
//! the store exports (a layer, or a repeater list whose pins carry every known setting in the description and in
//! ExtendedData, so Google Earth shows them offline and a re-import gives the same list).

use super::repeater::{mhz_to_hz, ChirpCols, Duplex, Repeater, Tone};
use super::xml::{esc, parse, El};
use super::{bad, coord_ok, Feature, Geom, ParsedLayer};

fn root(text: &str) -> crate::Result<El> {
    let r = parse(text, "KML")?;
    if r.name != "kml" && r.name != "Document" && r.name != "Folder" && r.name != "Placemark" {
        return Err(bad("KML: the file is not KML"));
    }
    Ok(r)
}

/// "lon,lat[,alt] lon,lat ..." as (lat, lon), every pair in range.
fn coords(text: &str) -> Option<Vec<(f64, f64)>> {
    let mut out = Vec::new();
    for t in text.split_whitespace() {
        let mut p = t.split(',');
        let lon: f64 = p.next()?.trim().parse().ok()?;
        let lat: f64 = p.next()?.trim().parse().ok()?;
        if !coord_ok(lat, lon) {
            return None;
        }
        out.push((lat, lon));
    }
    Some(out)
}

fn geoms(el: &El, out: &mut Vec<Geom>) -> crate::Result<()> {
    for g in &el.children {
        let c = |e: &El| -> crate::Result<Vec<(f64, f64)>> {
            let t = e.child("coordinates").map(|c| c.text.as_str()).unwrap_or("");
            coords(t).ok_or_else(|| bad(format!("KML: unreadable coordinates in a {}", e.name)))
        };
        match g.name.as_str() {
            "Point" => {
                if let Some(&(lat, lon)) = c(g)?.first() {
                    out.push(Geom::Point(lat, lon));
                }
            }
            "LineString" => {
                let pts = c(g)?;
                if pts.len() >= 2 {
                    out.push(Geom::Line(pts));
                }
            }
            "Polygon" => {
                if let Some(ring) = g.child("outerBoundaryIs").and_then(|o| o.child("LinearRing")) {
                    let pts = c(ring)?;
                    if pts.len() >= 3 {
                        out.push(Geom::Area(pts));
                    }
                }
            }
            "MultiGeometry" => geoms(g, out)?,
            _ => {}
        }
    }
    Ok(())
}

fn placemarks<'a>(el: &'a El, out: &mut Vec<&'a El>) {
    for c in &el.children {
        match c.name.as_str() {
            "Placemark" => out.push(c),
            "Document" | "Folder" | "kml" => placemarks(c, out),
            _ => {}
        }
    }
}

fn all_placemarks(r: &El) -> Vec<&El> {
    let mut v = Vec::new();
    if r.name == "Placemark" {
        v.push(r);
    } else {
        placemarks(r, &mut v);
    }
    v
}

fn document_name(r: &El) -> Option<String> {
    let doc = if r.name == "kml" { r.child("Document").or_else(|| r.child("Folder"))? } else { r };
    doc.child_text("name").map(|n| super::collapse(&n))
}

/// A layer: every Placemark's shapes, with the Placemark's name and its description as plain text.
pub fn parse_layer(text: &str) -> crate::Result<ParsedLayer> {
    let r = root(text)?;
    let mut features = Vec::new();
    for p in all_placemarks(&r) {
        let name = p.child_text("name").map(|n| super::collapse(&n)).unwrap_or_default();
        let notes = p.child_text("description").map(|d| super::html_lines(&d).join("\n")).unwrap_or_default();
        let mut gs = Vec::new();
        geoms(p, &mut gs)?;
        for geom in gs {
            features.push(Feature { name: name.clone(), notes: notes.clone(), geom });
        }
    }
    Ok(ParsedLayer { name: document_name(&r), private: None, features })
}

fn extended(p: &El) -> Vec<(String, String)> {
    let Some(x) = p.child("ExtendedData") else { return Vec::new() };
    x.kids("Data").filter_map(|d| Some((d.attr("name")?.to_string(), d.child("value").map(|v| v.text.trim().to_string()).unwrap_or_default()))).collect()
}

/// The repeater pins of a KML, in file order, and how many Placemarks were not repeater pins.
pub fn parse_repeaters(text: &str) -> crate::Result<(Vec<Repeater>, usize)> {
    let r = root(text)?;
    let (mut out, mut skipped) = (Vec::new(), 0);
    for p in all_placemarks(&r) {
        let mut gs = Vec::new();
        geoms(p, &mut gs)?;
        let Some(Geom::Point(lat, lon)) = gs.into_iter().find(|g| matches!(g, Geom::Point(..))) else {
            skipped += 1;
            continue;
        };
        let name = p.child_text("name").unwrap_or_default();
        let x = extended(p);
        let rep = if x.iter().any(|(k, _)| k == "cache_repeater") {
            from_extended(&x, lat, lon)
        } else {
            super::repeater::from_pin(&name, &p.child_text("description").unwrap_or_default(), lat, lon)
        };
        match rep {
            Some(r) => out.push(r),
            None => skipped += 1,
        }
    }
    Ok((out, skipped))
}

const DUPLEX: [(Duplex, &str); 5] = [(Duplex::Simplex, "simplex"), (Duplex::Plus, "plus"), (Duplex::Minus, "minus"), (Duplex::Split, "split"), (Duplex::Off, "off")];

fn hz_mhz(hz: i64) -> String {
    let f = format!("{:06}", hz % 1_000_000);
    format!("{}.{f}", hz / 1_000_000)
}

/// Every setting of a repeater as (ExtendedData name, value); empty values are left out.
fn to_extended(r: &Repeater) -> Vec<(&'static str, String)> {
    let mut v: Vec<(&'static str, String)> = vec![("cache_repeater", "1".into()), ("callsign", r.name.clone())];
    let mut put = |k: &'static str, s: Option<String>| {
        if let Some(s) = s.filter(|s| !s.is_empty()) {
            v.push((k, s));
        }
    };
    put("town", r.town.clone());
    put("frequency_mhz", Some(hz_mhz(r.freq_hz)));
    put("duplex", r.duplex.and_then(|d| DUPLEX.iter().find(|(x, _)| *x == d).map(|(_, s)| s.to_string())));
    put("offset_mhz", r.offset_hz.map(hz_mhz));
    let (tt, tv) = match &r.tone {
        Tone::None => ("none", None),
        Tone::Tone(f) => ("tone", Some(f.to_string())),
        Tone::Tsql(f) => ("tsql", Some(f.to_string())),
        Tone::Dtcs(c) => ("dtcs", Some(c.clone())),
        Tone::Cross => ("cross", None),
        Tone::Other(s) => ("other", Some(s.clone())),
        Tone::Stated(f) => ("stated", Some(f.to_string())),
        Tone::StatedDcs(c) => ("stated_dcs", Some(c.clone())),
    };
    put("tone_type", Some(tt.into()));
    put("tone", tv);
    put("mode", r.mode.clone());
    put("on_air", r.on_air.map(|b| if b { "yes".into() } else { "no".into() }));
    put("details_link", r.link.clone());
    if let Some(c) = &r.chirp {
        v.push(("chirp", "1".into()));
        for (k, s) in [
            ("chirp_location", &c.location),
            ("chirp_name", &c.name),
            ("chirp_comment", &c.comment),
            ("chirp_rtone", &c.r_tone),
            ("chirp_ctone", &c.c_tone),
            ("chirp_dtcs_code", &c.dtcs_code),
            ("chirp_dtcs_polarity", &c.dtcs_polarity),
            ("chirp_mode", &c.mode),
            ("chirp_tstep", &c.tstep),
        ] {
            if !s.is_empty() {
                v.push((k, s.clone()));
            }
        }
    }
    v
}

fn from_extended(x: &[(String, String)], lat: f64, lon: f64) -> Option<Repeater> {
    let get = |k: &str| x.iter().find(|(n, _)| n == k).map(|(_, v)| v.clone()).filter(|v| !v.is_empty());
    let num = |k: &str| get(k).and_then(|v| v.parse::<f64>().ok());
    let tone = match get("tone_type").as_deref() {
        Some("tone") => Tone::Tone(num("tone")?),
        Some("tsql") => Tone::Tsql(num("tone")?),
        Some("dtcs") => Tone::Dtcs(get("tone")?),
        Some("cross") => Tone::Cross,
        Some("other") => Tone::Other(get("tone")?),
        Some("stated") => Tone::Stated(num("tone")?),
        Some("stated_dcs") => Tone::StatedDcs(get("tone")?),
        _ => Tone::None,
    };
    let chirp = get("chirp").map(|_| {
        let g = |k: &str| get(k).unwrap_or_default();
        ChirpCols {
            location: g("chirp_location"),
            name: g("chirp_name"),
            comment: g("chirp_comment"),
            r_tone: g("chirp_rtone"),
            c_tone: g("chirp_ctone"),
            dtcs_code: g("chirp_dtcs_code"),
            dtcs_polarity: g("chirp_dtcs_polarity"),
            mode: g("chirp_mode"),
            tstep: g("chirp_tstep"),
        }
    });
    Some(Repeater {
        name: get("callsign").unwrap_or_default(),
        town: get("town"),
        freq_hz: mhz_to_hz(&get("frequency_mhz")?)?,
        duplex: get("duplex").and_then(|d| DUPLEX.iter().find(|(_, s)| *s == d).map(|(x, _)| *x)),
        offset_hz: get("offset_mhz").and_then(|o| mhz_to_hz(&o)),
        tone,
        mode: get("mode"),
        on_air: get("on_air").map(|v| v == "yes"),
        link: get("details_link"),
        lat: Some(lat),
        lon: Some(lon),
        chirp,
    })
}

fn head(name: &str) -> String {
    format!("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<kml xmlns=\"http://www.opengis.net/kml/2.2\">\n<Document>\n<name>{}</name>\n", esc(name))
}

const TAIL: &str = "</Document>\n</kml>\n";

fn coord_text(pts: &[(f64, f64)]) -> String {
    pts.iter().map(|(la, lo)| format!("{lo},{la},0")).collect::<Vec<_>>().join(" ")
}

/// A layer as KML: one Placemark per pin, line and area, with its notes as the description.
pub fn write_layer(name: &str, features: &[Feature]) -> String {
    let mut s = head(name);
    for f in features {
        s.push_str("<Placemark>\n");
        s.push_str(&format!("<name>{}</name>\n", esc(&f.name)));
        if !f.notes.is_empty() {
            s.push_str(&format!("<description>{}</description>\n", esc(&f.notes).replace('\n', "&#10;")));
        }
        match &f.geom {
            Geom::Point(la, lo) => s.push_str(&format!("<Point><coordinates>{lo},{la},0</coordinates></Point>\n")),
            Geom::Line(p) => s.push_str(&format!("<LineString><coordinates>{}</coordinates></LineString>\n", coord_text(p))),
            Geom::Area(p) => {
                let mut ring = p.clone();
                if ring.first() != ring.last() {
                    ring.push(ring[0]);
                }
                s.push_str(&format!("<Polygon><outerBoundaryIs><LinearRing><coordinates>{}</coordinates></LinearRing></outerBoundaryIs></Polygon>\n", coord_text(&ring)));
            }
        }
        s.push_str("</Placemark>\n");
    }
    s.push_str(TAIL);
    s
}

/// A repeater list as KML: the pins with a position, each with the settings as readable lines and as ExtendedData.
pub fn write_repeaters(name: &str, list: &[Repeater]) -> String {
    let mut s = head(name);
    for r in list {
        let Some((lat, lon)) = r.positioned() else { continue };
        let mut lines: Vec<String> = Vec::new();
        if let Some(t) = &r.town {
            lines.push(esc(t));
        }
        lines.push(format!("Frequency: {}", super::repeater::frequency_text(r.freq_hz)));
        lines.push(format!("Offset: {}", esc(&r.offset_text())));
        lines.push(format!("Tone: {}", esc(&r.tone_text())));
        if let Some(m) = &r.mode {
            lines.push(format!("Mode: {}", esc(m)));
        }
        if let Some(a) = r.on_air {
            lines.push(format!("On-air: {}", if a { "Yes" } else { "No" }));
        }
        if let Some(l) = &r.link {
            lines.push(format!("<a href='{}'>Details</a>", esc(l)));
        }
        s.push_str("<Placemark>\n");
        s.push_str(&format!("<name>{}</name>\n", esc(&r.name)));
        s.push_str(&format!("<description><![CDATA[\n{}\n]]></description>\n", lines.join("<br>\n").replace("]]>", "]]&gt;")));
        s.push_str("<ExtendedData>\n");
        for (k, v) in to_extended(r) {
            s.push_str(&format!("<Data name=\"{k}\"><value>{}</value></Data>\n", esc(&v)));
        }
        s.push_str("</ExtendedData>\n");
        s.push_str(&format!("<Point><coordinates>{lon},{lat},0</coordinates></Point>\n"));
        s.push_str("</Placemark>\n");
    }
    s.push_str(TAIL);
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    const LAYER: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2" xmlns:gx="http://www.google.com/kml/ext/2.2"><Document><name>Rally  Points</name>
<Folder><name>North</name>
 <Placemark><name>North gate</name><description><![CDATA[Meet <b>here</b><br>bring water &amp; radios]]></description>
  <Point><coordinates>-113.79,42.53,1200</coordinates></Point></Placemark>
 <Placemark><name>Ridge route</name><LineString><coordinates>-113.7,42.5,0 -113.6,42.6,0</coordinates></LineString></Placemark>
</Folder>
<Placemark><name>Camp</name><Polygon><outerBoundaryIs><LinearRing><coordinates>-113,42 -113.1,42 -113.1,42.1 -113,42</coordinates></LinearRing></outerBoundaryIs></Polygon></Placemark>
<Placemark><name>Both</name><MultiGeometry><Point><coordinates>-114,43</coordinates></Point><LineString><coordinates>-114,43 -114.1,43.1</coordinates></LineString></MultiGeometry></Placemark>
<Placemark><name>No shape</name></Placemark>
</Document></kml>"#;

    #[test]
    fn layer_shapes_names_and_notes() {
        let l = parse_layer(LAYER).unwrap();
        assert_eq!(l.name.as_deref(), Some("Rally Points"));
        assert_eq!(l.features.len(), 5);
        assert_eq!(l.features[0], Feature { name: "North gate".into(), notes: "Meet here\nbring water & radios".into(), geom: Geom::Point(42.53, -113.79) });
        assert_eq!(l.features[1].geom, Geom::Line(vec![(42.5, -113.7), (42.6, -113.6)]));
        assert!(matches!(&l.features[2].geom, Geom::Area(p) if p.len() == 4));
        assert_eq!(l.features[3].geom, Geom::Point(43.0, -114.0));
        assert!(matches!(l.features[4].geom, Geom::Line(_)));
    }

    #[test]
    fn layer_round_trip() {
        let l = parse_layer(LAYER).unwrap();
        let back = parse_layer(&write_layer("Rally Points", &l.features)).unwrap();
        assert_eq!(back.name.as_deref(), Some("Rally Points"));
        assert_eq!(back.features, l.features);
    }

    #[test]
    fn malformed_kml() {
        for bad in ["", "not xml at all", "<kml><Document></kml>", "<html><body/></html>",
                    "<kml><Placemark><Point><coordinates>abc</coordinates></Point></Placemark></kml>",
                    "<kml><Placemark><Point><coordinates>-200,95</coordinates></Point></Placemark></kml>"] {
            assert_eq!(parse_layer(bad).unwrap_err().code, "bad_json", "{bad:?}");
        }
    }

    const PINS: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<kml xmlns="http://www.opengis.net/kml/2.2"><Document>
<Placemark><name>TEST1</name><description><![CDATA[
Cascade<br>
927.162500- 151.4<br>
On-air: Yes<br>
<a href='https://www.repeaterbook.com/repeaters/details.php?state_id=16&ID=1'>Click for Details</a>
]]></description><Point><coordinates>-116.0593026,44.5579602,0</coordinates></Point></Placemark>
<Placemark><name>TEST2</name><description><![CDATA[Coeur d&#039;Alene<br>146.450000s<br>On-air: No<br>]]></description><Point><coordinates>-116.78,47.67,0</coordinates></Point></Placemark>
<Placemark><name>Not a repeater</name><description>just a pin</description><Point><coordinates>-116,44,0</coordinates></Point></Placemark>
</Document></kml>"#;

    #[test]
    fn repeater_pins() {
        let (pins, skipped) = parse_repeaters(PINS).unwrap();
        assert_eq!(skipped, 1);
        assert_eq!(pins.len(), 2);
        let a = &pins[0];
        assert_eq!((a.name.as_str(), a.town.as_deref(), a.freq_hz, a.duplex, a.on_air), ("TEST1", Some("Cascade"), 927_162_500, Some(Duplex::Minus), Some(true)));
        assert_eq!(a.tone, Tone::Stated(151.4));
        assert_eq!(a.link.as_deref(), Some("https://www.repeaterbook.com/repeaters/details.php?state_id=16&ID=1"));
        assert_eq!(a.positioned(), Some((44.5579602, -116.0593026)));
        assert_eq!(a.offset_text(), "- (amount not in the imported list)");
        assert_eq!(a.tone_text(), "151.4 Hz (use not stated in the imported list)");
        assert_eq!(pins[1].town.as_deref(), Some("Coeur d'Alene"));
        assert_eq!((pins[1].duplex, pins[1].on_air), (Some(Duplex::Split), Some(false)));
    }

    #[test]
    fn repeater_export_round_trip() {
        let (mut pins, _) = parse_repeaters(PINS).unwrap();
        pins[0].offset_hz = Some(25_000_000);
        pins[0].tone = Tone::Tsql(151.4);
        pins[0].mode = Some("FM".into());
        pins[0].chirp = Some(ChirpCols { location: "1".into(), name: "Cascade ".into(), comment: "Cascade".into(), tstep: "5".into(), ..Default::default() });
        pins[1].tone = Tone::Dtcs("432".into());
        let k = write_repeaters("repeaters.kml", &pins);
        assert!(k.contains("Offset: -25 MHz<br>"), "{k}");
        assert!(k.contains("<Data name=\"tone_type\"><value>tsql</value></Data>"), "{k}");
        let (back, skipped) = parse_repeaters(&k).unwrap();
        assert_eq!(skipped, 0);
        assert_eq!(back, pins);
    }
}
