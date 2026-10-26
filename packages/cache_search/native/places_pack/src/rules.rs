//! The category rules (categories.json): which Overture categories and OSM tags make each starter category. They are
//! data: the builder reads them, and writes the same JSON into the pack's categories table.

use serde::Deserialize;
use serde_json::Value;
use std::collections::BTreeMap;

#[derive(Debug, Deserialize, Clone)]
pub struct Rules {
    pub min_confidence: f64,
    pub merge: MergeCfg,
    pub general: General,
    pub categories: Vec<CategoryDef>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct MergeCfg {
    pub close_m: f64,
    pub near_m: f64,
    pub name_similarity: f64,
    pub general_name_similarity: f64,
}

/// Named places that belong to no starter category but are worth finding by name (the geocoder).
#[derive(Debug, Deserialize, Clone)]
pub struct General {
    pub overture: GeneralOverture,
    pub osm: Vec<OsmRule>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct GeneralOverture {
    pub min_confidence: f64,
}

#[derive(Debug, Deserialize, Clone)]
pub struct CategoryDef {
    pub id: String,
    pub title: String,
    pub description: String,
    pub rules: Vec<CatRule>,
}

#[derive(Debug, Deserialize, Clone)]
pub struct EnrichFrom {
    pub category: String,
    pub radius_m: f64,
}

#[derive(Debug, Deserialize, Clone)]
pub struct CatRule {
    pub source: String,
    #[serde(default)]
    pub basic_category: Vec<String>,
    #[serde(default)]
    pub min_confidence: Option<f64>,
    #[serde(default)]
    pub tags: BTreeMap<String, String>,
    #[serde(default)]
    pub not: BTreeMap<String, String>,
    #[serde(default)]
    pub enrich_from: Option<EnrichFrom>,
}

/// One OSM tag condition: every `tags` pair must hold, and no `not` pair may. A value is `*` (any), one value, or
/// alternatives separated by `|`.
#[derive(Debug, Deserialize, Clone)]
pub struct OsmRule {
    #[serde(default)]
    pub tags: BTreeMap<String, String>,
    #[serde(default)]
    pub not: BTreeMap<String, String>,
}

fn pair_holds(tags: &[(&str, &str)], key: &str, want: &str) -> bool {
    tags.iter().any(|(k, v)| *k == key && (want == "*" || want.split('|').any(|w| w == *v)))
}

pub fn osm_matches(tags: &[(&str, &str)], rule_tags: &BTreeMap<String, String>, rule_not: &BTreeMap<String, String>) -> bool {
    !rule_tags.is_empty()
        && rule_tags.iter().all(|(k, v)| pair_holds(tags, k, v))
        && !rule_not.iter().any(|(k, v)| pair_holds(tags, k, v))
}

impl Rules {
    pub fn parse(json: &str) -> Result<Rules, String> {
        let r: Rules = serde_json::from_str(json).map_err(|e| format!("categories rules: {e}"))?;
        for c in &r.categories {
            for rule in &c.rules {
                match rule.source.as_str() {
                    "overture" if !rule.basic_category.is_empty() => {}
                    "osm" if !rule.tags.is_empty() => {}
                    other => return Err(format!("category {}: rule of source {other:?} has nothing to match", c.id)),
                }
            }
        }
        Ok(r)
    }

    /// The category an Overture row belongs to, and the rule that put it there.
    pub fn overture_category(&self, basic_category: &str, confidence: f64) -> Option<(&CategoryDef, &CatRule)> {
        for c in &self.categories {
            for r in &c.rules {
                if r.source == "overture"
                    && r.basic_category.iter().any(|b| b == basic_category)
                    && confidence >= r.min_confidence.unwrap_or(self.min_confidence)
                {
                    return Some((c, r));
                }
            }
        }
        None
    }

    /// The category an OSM element belongs to, from its tags.
    pub fn osm_category(&self, tags: &[(&str, &str)]) -> Option<&CategoryDef> {
        self.categories.iter().find(|c| c.rules.iter().any(|r| r.source == "osm" && osm_matches(tags, &r.tags, &r.not)))
    }

    pub fn osm_general(&self, tags: &[(&str, &str)]) -> bool {
        self.general.osm.iter().any(|r| osm_matches(tags, &r.tags, &r.not))
    }

    /// The rules of one category as JSON text, for the pack's categories table.
    pub fn rules_json(c: &CategoryDef) -> String {
        let v: Vec<Value> = c
            .rules
            .iter()
            .map(|r| {
                let mut m = serde_json::Map::new();
                m.insert("source".into(), r.source.clone().into());
                if !r.basic_category.is_empty() {
                    m.insert("basic_category".into(), r.basic_category.clone().into());
                }
                if let Some(c) = r.min_confidence {
                    m.insert("min_confidence".into(), c.into());
                }
                if !r.tags.is_empty() {
                    m.insert("tags".into(), serde_json::to_value(&r.tags).unwrap_or(Value::Null));
                }
                if !r.not.is_empty() {
                    m.insert("not".into(), serde_json::to_value(&r.not).unwrap_or(Value::Null));
                }
                if let Some(e) = &r.enrich_from {
                    m.insert("enrich_from".into(), serde_json::json!({"category": e.category, "radius_m": e.radius_m}));
                }
                Value::Object(m)
            })
            .collect();
        Value::Array(v).to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const DEFAULT: &str = include_str!("../categories.json");

    #[test]
    fn default_rules_parse() {
        let r = Rules::parse(DEFAULT).unwrap();
        let ids: Vec<&str> = r.categories.iter().map(|c| c.id.as_str()).collect();
        assert_eq!(
            ids,
            ["emergency_room", "hospital", "urgent_care", "pharmacy", "fuel", "police", "fire_station", "campground", "trailhead", "water", "shelter"]
        );
    }

    #[test]
    fn osm_tag_rules() {
        let r = Rules::parse(DEFAULT).unwrap();
        assert_eq!(r.osm_category(&[("amenity", "hospital"), ("name", "X")]).unwrap().id, "hospital");
        assert_eq!(r.osm_category(&[("amenity", "clinic")]).unwrap().id, "urgent_care");
        assert_eq!(r.osm_category(&[("natural", "spring")]).unwrap().id, "water");
        assert!(r.osm_category(&[("natural", "spring"), ("drinking_water", "no")]).is_none());
        assert_eq!(r.osm_category(&[("man_made", "water_well"), ("drinking_water", "yes")]).unwrap().id, "water");
        assert!(r.osm_category(&[("man_made", "water_well")]).is_none());
        assert_eq!(r.osm_category(&[("amenity", "shelter"), ("shelter_type", "basic_hut")]).unwrap().id, "shelter");
        assert!(r.osm_category(&[("amenity", "shelter"), ("shelter_type", "public_transport")]).is_none());
        assert!(r.osm_category(&[("amenity", "school")]).is_none());
        assert!(r.osm_general(&[("amenity", "school")]));
    }

    #[test]
    fn overture_rules() {
        let r = Rules::parse(DEFAULT).unwrap();
        // Hospitals and urgent care are OSM only: Overture's medical categories are not used for them.
        assert!(r.overture_category("hospital", 0.99).is_none());
        assert!(r.overture_category("urgent_care_center", 0.99).is_none());
        assert_eq!(r.overture_category("emergency_department", 0.9).unwrap().0.id, "emergency_room");
        assert!(r.overture_category("emergency_department", 0.3).is_none());
        assert_eq!(r.overture_category("gas_station", 0.8).unwrap().0.id, "fuel");
    }
}
