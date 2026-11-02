//! GeoJSON (RFC 7946): a FeatureCollection, a Feature or a bare geometry. Point and MultiPoint are pins, LineString and
//! MultiLineString lines, Polygon and MultiPolygon areas (outer rings). A feature's name is its `name` (or `title`)
//! property, its notes `notes` (or `description`). The layer JSON of `cs serve --layers` is a FeatureCollection with
//! the foreign members `"name"` and `"private"`; the store also writes a layer as such for the map (`cs_userlayer_get`).

use super::{bad, coord_ok, Feature, Geom, ParsedLayer};
use serde_json::{json, Map, Value};

fn pos(v: &Value) -> crate::Result<(f64, f64)> {
    let a = v.as_array().filter(|a| a.len() >= 2).ok_or_else(|| bad("GeoJSON: a position is not [lon, lat]"))?;
    match (a[0].as_f64(), a[1].as_f64()) {
        (Some(lo), Some(la)) if coord_ok(la, lo) => Ok((la, lo)),
        _ => Err(bad("GeoJSON: a position is not [lon, lat] in range")),
    }
}

fn line(v: &Value) -> crate::Result<Vec<(f64, f64)>> {
    v.as_array().ok_or_else(|| bad("GeoJSON: a line is not a list of positions"))?.iter().map(pos).collect()
}

fn geoms(g: &Value, out: &mut Vec<Geom>) -> crate::Result<()> {
    let c = &g["coordinates"];
    let list = |v: &Value| -> crate::Result<Vec<Value>> { v.as_array().cloned().ok_or_else(|| bad("GeoJSON: coordinates are not a list")) };
    let ring = |v: &Value| -> crate::Result<Option<Geom>> {
        let rings = list(v)?;
        match rings.first() {
            Some(r) => {
                let pts = line(r)?;
                Ok((pts.len() >= 3).then_some(Geom::Area(pts)))
            }
            None => Ok(None),
        }
    };
    match g["type"].as_str() {
        Some("Point") => {
            let (la, lo) = pos(c)?;
            out.push(Geom::Point(la, lo));
        }
        Some("MultiPoint") => {
            for p in list(c)? {
                let (la, lo) = pos(&p)?;
                out.push(Geom::Point(la, lo));
            }
        }
        Some("LineString") => out.push(Geom::Line(line(c)?)),
        Some("MultiLineString") => {
            for l in list(c)? {
                out.push(Geom::Line(line(&l)?));
            }
        }
        Some("Polygon") => out.extend(ring(c)?),
        Some("MultiPolygon") => {
            for p in list(c)? {
                out.extend(ring(&p)?);
            }
        }
        Some("GeometryCollection") => {
            for x in g["geometries"].as_array().ok_or_else(|| bad("GeoJSON: a GeometryCollection without geometries"))? {
                geoms(x, out)?;
            }
        }
        Some(t) => return Err(bad(format!("GeoJSON: unknown geometry type {t:?}"))),
        None => return Err(bad("GeoJSON: a geometry without a type")),
    }
    out.retain(|g| !matches!(g, Geom::Line(p) if p.len() < 2));
    Ok(())
}

fn text_prop(p: &Value, keys: &[&str]) -> String {
    keys.iter().find_map(|k| p[*k].as_str().map(str::to_string).filter(|s| !s.trim().is_empty())).unwrap_or_default()
}

fn feature(f: &Value, out: &mut Vec<Feature>) -> crate::Result<()> {
    if f["geometry"].is_null() {
        return Ok(());
    }
    let p = &f["properties"];
    let name = super::collapse(&text_prop(p, &["name", "title"]));
    let notes = text_prop(p, &["notes", "description"]).trim().to_string();
    let mut gs = Vec::new();
    geoms(&f["geometry"], &mut gs)?;
    out.extend(gs.into_iter().map(|geom| Feature { name: name.clone(), notes: notes.clone(), geom }));
    Ok(())
}

pub fn parse(text: &str) -> crate::Result<ParsedLayer> {
    let v: Value = serde_json::from_str(text).map_err(|e| bad(format!("GeoJSON: not readable JSON ({e})")))?;
    let mut features = Vec::new();
    match v["type"].as_str() {
        Some("FeatureCollection") => {
            for f in v["features"].as_array().ok_or_else(|| bad("GeoJSON: a FeatureCollection without features"))? {
                feature(f, &mut features)?;
            }
        }
        Some("Feature") => feature(&v, &mut features)?,
        Some(_) => {
            let mut gs = Vec::new();
            geoms(&v, &mut gs)?;
            features.extend(gs.into_iter().map(|geom| Feature { name: String::new(), notes: String::new(), geom }));
        }
        None => return Err(bad("GeoJSON: no \"type\"")),
    }
    let private = match v.get("private") {
        None | Some(Value::Null) => None,
        Some(Value::Bool(b)) => Some(*b),
        Some(_) => return Err(bad("layer JSON: \"private\" must be true or false")),
    };
    let name = v["name"].as_str().map(super::collapse).filter(|n| !n.is_empty());
    Ok(ParsedLayer { name, private, features })
}

/// A layer as a FeatureCollection with "name" and "private" (the layer JSON); `ids` are the features' point ids.
pub fn write(name: &str, private: bool, features: &[(u32, &Feature)]) -> Value {
    let fs: Vec<Value> = features
        .iter()
        .map(|(id, f)| {
            let flip = |p: &[(f64, f64)]| p.iter().map(|(la, lo)| json!([lo, la])).collect::<Vec<_>>();
            let g = match &f.geom {
                Geom::Point(la, lo) => json!({"type": "Point", "coordinates": [lo, la]}),
                Geom::Line(p) => json!({"type": "LineString", "coordinates": flip(p)}),
                Geom::Area(p) => {
                    let mut ring = p.clone();
                    if ring.first() != ring.last() {
                        ring.push(ring[0]);
                    }
                    json!({"type": "Polygon", "coordinates": [flip(&ring)]})
                }
            };
            let mut props = Map::new();
            props.insert("name".into(), json!(f.name));
            if !f.notes.is_empty() {
                props.insert("notes".into(), json!(f.notes));
            }
            json!({"type": "Feature", "id": id, "geometry": g, "properties": props})
        })
        .collect();
    json!({"type": "FeatureCollection", "name": name, "private": private, "features": fs})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn collections_features_and_the_layer_json() {
        let l = parse(r#"{"type":"FeatureCollection","name":"Rally Points","private":true,"features":[
            {"type":"Feature","geometry":{"type":"Point","coordinates":[-113.79,42.53]},"properties":{"name":"North gate","notes":"Meet here"}},
            {"type":"Feature","geometry":{"type":"MultiPoint","coordinates":[[-113,42],[-113.5,42.5,1200]]},"properties":{"title":"Caches"}},
            {"type":"Feature","geometry":{"type":"LineString","coordinates":[[-113,42],[-113.1,42.1]]},"properties":null},
            {"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-113,42],[-113.1,42],[-113.1,42.1],[-113,42]]]},"properties":{"description":"Camp area"}},
            {"type":"Feature","geometry":null,"properties":{"name":"nowhere"}}]}"#).unwrap();
        assert_eq!((l.name.as_deref(), l.private), (Some("Rally Points"), Some(true)));
        assert_eq!(l.features.len(), 5);
        assert_eq!(l.features[0], Feature { name: "North gate".into(), notes: "Meet here".into(), geom: Geom::Point(42.53, -113.79) });
        assert_eq!((l.features[1].name.as_str(), &l.features[2].geom), ("Caches", &Geom::Point(42.5, -113.5)));
        assert!(matches!(l.features[3].geom, Geom::Line(_)));
        assert_eq!(l.features[4].notes, "Camp area");
        let bare = parse(r#"{"type":"Point","coordinates":[-114,43]}"#).unwrap();
        assert_eq!(bare.features[0].geom, Geom::Point(43.0, -114.0));
    }

    #[test]
    fn round_trip() {
        let l = parse(r#"{"type":"FeatureCollection","features":[
            {"type":"Feature","geometry":{"type":"Point","coordinates":[-113.79,42.53]},"properties":{"name":"A","notes":"x\ny"}},
            {"type":"Feature","geometry":{"type":"Polygon","coordinates":[[[-113,42],[-113.1,42],[-113.1,42.1],[-113,42]]]},"properties":{"name":"B"}}]}"#).unwrap();
        let fs: Vec<(u32, &Feature)> = l.features.iter().enumerate().map(|(i, f)| (i as u32 + 1, f)).collect();
        let back = parse(&write("L", false, &fs).to_string()).unwrap();
        assert_eq!((back.name.as_deref(), back.private), (Some("L"), Some(false)));
        assert_eq!(back.features, l.features);
    }

    #[test]
    fn malformed_geojson() {
        for bad in ["", "{", "[]", r#"{"features":[]}"#, r#"{"type":"FeatureCollection"}"#, r#"{"type":"Point","coordinates":[1]}"#,
                    r#"{"type":"Point","coordinates":[200,1]}"#, r#"{"type":"Blob","coordinates":[]}"#,
                    r#"{"type":"FeatureCollection","features":[],"private":"yes"}"#] {
            assert_eq!(parse(bad).unwrap_err().code, "bad_json", "{bad:?}");
        }
    }
}
