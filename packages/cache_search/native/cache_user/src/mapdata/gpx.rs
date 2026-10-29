//! GPX: waypoints are pins, routes and track segments are lines. The export writes pins as waypoints and lines and areas
//! as tracks (GPX has no areas; an area's ring is closed).

use super::xml::{esc, parse as parse_xml, El};
use super::{bad, coord_ok, Feature, Geom, ParsedLayer};

fn point(e: &El) -> crate::Result<(f64, f64)> {
    let n = |k: &str| e.attr(k).and_then(|v| v.trim().parse::<f64>().ok());
    match (n("lat"), n("lon")) {
        (Some(la), Some(lo)) if coord_ok(la, lo) => Ok((la, lo)),
        _ => Err(bad(format!("GPX: a {} without a readable lat and lon", e.name))),
    }
}

fn notes(e: &El) -> String {
    [e.child_text("desc"), e.child_text("cmt")].into_iter().flatten().map(|t| super::html_lines(&t).join("\n")).find(|t| !t.is_empty()).unwrap_or_default()
}

fn name(e: &El) -> String {
    e.child_text("name").map(|n| super::collapse(&n)).unwrap_or_default()
}

pub fn parse(text: &str) -> crate::Result<ParsedLayer> {
    let r = parse_xml(text, "GPX")?;
    if r.name != "gpx" {
        return Err(bad("GPX: the file is not GPX"));
    }
    let mut features = Vec::new();
    for w in r.kids("wpt") {
        let (la, lo) = point(w)?;
        features.push(Feature { name: name(w), notes: notes(w), geom: Geom::Point(la, lo) });
    }
    for rt in r.kids("rte") {
        let pts = rt.kids("rtept").map(point).collect::<crate::Result<Vec<_>>>()?;
        if pts.len() >= 2 {
            features.push(Feature { name: name(rt), notes: notes(rt), geom: Geom::Line(pts) });
        }
    }
    for t in r.kids("trk") {
        for seg in t.kids("trkseg") {
            let pts = seg.kids("trkpt").map(point).collect::<crate::Result<Vec<_>>>()?;
            if pts.len() >= 2 {
                features.push(Feature { name: name(t), notes: notes(t), geom: Geom::Line(pts) });
            }
        }
    }
    let layer_name = r.child("metadata").and_then(|m| m.child_text("name")).map(|n| super::collapse(&n));
    Ok(ParsedLayer { name: layer_name, private: None, features })
}

pub fn write(layer_name: &str, features: &[Feature]) -> String {
    let mut s = String::from("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<gpx version=\"1.1\" creator=\"Cache\" xmlns=\"http://www.topografix.com/GPX/1/1\">\n");
    s.push_str(&format!("<metadata><name>{}</name></metadata>\n", esc(layer_name)));
    let named = |f: &Feature| {
        let mut t = format!("<name>{}</name>", esc(&f.name));
        if !f.notes.is_empty() {
            t.push_str(&format!("<desc>{}</desc>", esc(&f.notes).replace('\n', "&#10;")));
        }
        t
    };
    for f in features {
        if let Geom::Point(la, lo) = f.geom {
            s.push_str(&format!("<wpt lat=\"{la}\" lon=\"{lo}\">{}</wpt>\n", named(f)));
        }
    }
    for f in features {
        let pts = match &f.geom {
            Geom::Point(..) => continue,
            Geom::Line(p) => p.clone(),
            Geom::Area(p) => {
                let mut ring = p.clone();
                if ring.first() != ring.last() {
                    ring.push(ring[0]);
                }
                ring
            }
        };
        s.push_str(&format!("<trk>{}<trkseg>", named(f)));
        for (la, lo) in pts {
            s.push_str(&format!("<trkpt lat=\"{la}\" lon=\"{lo}\"/>"));
        }
        s.push_str("</trkseg></trk>\n");
    }
    s.push_str("</gpx>\n");
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    const GPX: &str = r#"<?xml version="1.0"?>
<gpx version="1.1" creator="x" xmlns="http://www.topografix.com/GPX/1/1"><metadata><name>Elk camp</name></metadata>
<wpt lat="42.53" lon="-113.79"><name>Spring</name><desc>Flows in May</desc></wpt>
<wpt lat="42.6" lon="-113.7"><name>Gate</name><cmt>Locked</cmt></wpt>
<rte><name>Way in</name><rtept lat="42.5" lon="-113.7"/><rtept lat="42.6" lon="-113.6"/></rte>
<trk><name>Walk</name><trkseg><trkpt lat="42" lon="-113"/><trkpt lat="42.1" lon="-113.1"/></trkseg><trkseg><trkpt lat="43" lon="-114"/></trkseg></trk>
</gpx>"#;

    #[test]
    fn waypoints_routes_tracks() {
        let l = parse(GPX).unwrap();
        assert_eq!(l.name.as_deref(), Some("Elk camp"));
        assert_eq!(l.features.len(), 4);
        assert_eq!(l.features[0], Feature { name: "Spring".into(), notes: "Flows in May".into(), geom: Geom::Point(42.53, -113.79) });
        assert_eq!(l.features[1].notes, "Locked");
        assert_eq!(l.features[2].geom, Geom::Line(vec![(42.5, -113.7), (42.6, -113.6)]));
        assert_eq!(l.features[3].name, "Walk");
    }

    #[test]
    fn round_trip() {
        let l = parse(GPX).unwrap();
        let back = parse(&write("Elk camp", &l.features)).unwrap();
        assert_eq!(back.name.as_deref(), Some("Elk camp"));
        assert_eq!(back.features, l.features);
    }

    #[test]
    fn malformed_gpx() {
        for bad in ["", "<gpx><wpt lat=\"x\" lon=\"1\"/></gpx>", "<gpx><wpt lat=\"95\" lon=\"1\"/></gpx>", "<kml/>", "<gpx><wpt></gpx>"] {
            assert_eq!(parse(bad).unwrap_err().code, "bad_json", "{bad:?}");
        }
    }
}
