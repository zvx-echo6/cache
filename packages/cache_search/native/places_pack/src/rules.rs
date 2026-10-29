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
    /// What kind of place each source record is (see `KindDef`). Optional: rules without kinds give every place the kind its
    /// raw type names (`generic_kind_id`).
    #[serde(default)]
    pub kinds: Vec<KindDef>,
    /// Where a route to a place goes (`arrival`). Optional: rules without it give no place an arrival point.
    #[serde(default)]
    pub arrival: ArrivalCfg,
}

/// Which OSM features are arrival anchors, and how they belong to a place (see `arrival.rs`). Data, like the category rules.
#[derive(Debug, Deserialize, Clone, Default)]
pub struct ArrivalCfg {
    /// Airport terminal buildings.
    #[serde(default)]
    pub terminal: Vec<OsmRule>,
    /// Doors people may use, and the main ones among them.
    #[serde(default)]
    pub entrance: Vec<OsmRule>,
    #[serde(default)]
    pub main_entrance: Vec<OsmRule>,
    /// Parking the public may use.
    #[serde(default)]
    pub parking: Vec<OsmRule>,
    /// The kind ids of airports: their arrival point is the passenger terminal.
    #[serde(default)]
    pub airport_kinds: Vec<String>,
    /// A point airport's terminals are within this distance of it (an area airport's are inside its outline).
    #[serde(default)]
    pub airport_terminal_m: f64,
    /// A place whose outline is at least this long across (the box's diagonal) is a large area: a park, a campus, a mall.
    #[serde(default)]
    pub large_m: f64,
    /// An entrance within this distance of a building's outline is one of its doors.
    #[serde(default)]
    pub outline_m: f64,
    /// Parking within this distance of a large area's outline serves it.
    #[serde(default)]
    pub adjacent_m: f64,
}

impl ArrivalCfg {
    fn any(rules: &[OsmRule], tags: &[(&str, &str)]) -> bool {
        rules.iter().any(|r| osm_matches(tags, &r.tags, &r.not))
    }
    /// What arrival anchor an OSM feature is, if any (a door is a main entrance when the main-entrance rules hold too).
    pub fn anchor(&self, tags: &[(&str, &str)]) -> Option<crate::model::AnchorKind> {
        use crate::model::AnchorKind;
        if Self::any(&self.terminal, tags) {
            Some(AnchorKind::Terminal)
        } else if Self::any(&self.entrance, tags) {
            Some(if Self::any(&self.main_entrance, tags) { AnchorKind::MainEntrance } else { AnchorKind::Entrance })
        } else if Self::any(&self.parking, tags) {
            Some(AnchorKind::Parking)
        } else {
            None
        }
    }
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

/// One kind of place, a stable machine id with a label and a line of description, and the source tags (OSM) or
/// categories (Overture) that make a place this kind. Kinds are tried in file order and the first match wins, so a more
/// specific kind goes before a general one. A kind with a `category` applies only to places of that category, one without
/// only to places of no category (the geocoder's named places). The rules are data, like the category rules.
#[derive(Debug, Deserialize, Clone)]
pub struct KindDef {
    pub id: String,
    pub label: String,
    pub description: String,
    #[serde(default)]
    pub category: Option<String>,
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
    /// Overture rows of this rule are emergency rooms only when an OSM place of this category is within the radius;
    /// they take that place's name, address and phone, and rows with no such place are dropped.
    #[serde(default)]
    pub require_match: Option<EnrichFrom>,
    /// `source: "category"` rules (read by the tools, not the builder): places of `category` are also offered under
    /// this category with `tier`, after the confirmed ones (`primary_tier`), and rank ahead of a confirmed place only
    /// when nearer by `beats_primary_only_if_nearer_by_mi`.
    #[serde(default)]
    pub category: Option<String>,
    #[serde(default)]
    pub primary_tier: Option<String>,
    #[serde(default)]
    pub tier: Option<String>,
    #[serde(default)]
    pub note: Option<String>,
    #[serde(default)]
    pub beats_primary_only_if_nearer_by_mi: Option<f64>,
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
        let mut seen: Vec<&str> = Vec::new();
        for k in &r.kinds {
            if k.id.is_empty() || !k.id.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'_') {
                return Err(format!("kind {:?}: the id must be lowercase letters, digits and underscores", k.id));
            }
            if seen.contains(&k.id.as_str()) {
                return Err(format!("kind {}: listed twice", k.id));
            }
            seen.push(&k.id);
            if k.label.trim().is_empty() || k.description.trim().is_empty() {
                return Err(format!("kind {}: needs a label and a description", k.id));
            }
            if let Some(c) = &k.category {
                if !r.categories.iter().any(|x| &x.id == c) {
                    return Err(format!("kind {}: category {c:?} does not exist", k.id));
                }
            }
            for rule in &k.rules {
                match rule.source.as_str() {
                    "overture" if !rule.basic_category.is_empty() => {}
                    "osm" if !rule.tags.is_empty() => {}
                    other => return Err(format!("kind {}: rule of source {other:?} has nothing to match", k.id)),
                }
            }
        }
        for c in &r.categories {
            for rule in &c.rules {
                match rule.source.as_str() {
                    "overture" if !rule.basic_category.is_empty() => {}
                    "osm" if !rule.tags.is_empty() => {}
                    "category" if rule.category.is_some() && rule.tier.is_some() => {}
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

    /// The kind of an OSM element from its tags, among the kinds of `category` (None: the kinds that belong to no category).
    pub fn osm_kind(&self, category: Option<&str>, tags: &[(&str, &str)]) -> Option<&KindDef> {
        self.kinds
            .iter()
            .filter(|k| k.category.as_deref() == category)
            .find(|k| k.rules.iter().any(|r| r.source == "osm" && osm_matches(tags, &r.tags, &r.not)))
    }

    /// The kind of an Overture record from its basic category, among the kinds of `category`.
    pub fn overture_kind(&self, category: Option<&str>, basic_category: &str) -> Option<&KindDef> {
        self.kinds
            .iter()
            .filter(|k| k.category.as_deref() == category)
            .find(|k| k.rules.iter().any(|r| r.source == "overture" && r.basic_category.iter().any(|b| b == basic_category)))
    }

    /// The label of a kind id the rules define, else the id read as words ("picnic_shelter" -> "Picnic shelter").
    pub fn kind_label(&self, id: &str) -> String {
        match self.kinds.iter().find(|k| k.id == id) {
            Some(k) => k.label.clone(),
            None => {
                let words = id.replace('_', " ");
                let mut c = words.chars();
                c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
            }
        }
    }

    /// The rules of one category as JSON text, for the pack's categories table.
    pub fn rules_json(c: &CategoryDef) -> String {
        Self::cat_rules_json(&c.rules)
    }

    /// The rules of one kind as JSON text, for the pack's kinds table.
    pub fn kind_rules_json(k: &KindDef) -> String {
        Self::cat_rules_json(&k.rules)
    }

    fn cat_rules_json(rules: &[CatRule]) -> String {
        let v: Vec<Value> = rules
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
                if let Some(e) = &r.require_match {
                    m.insert("require_match".into(), serde_json::json!({"category": e.category, "radius_m": e.radius_m}));
                }
                if r.source == "category" {
                    for (k, v) in [("category", &r.category), ("primary_tier", &r.primary_tier), ("tier", &r.tier), ("note", &r.note)] {
                        if let Some(v) = v {
                            m.insert(k.into(), v.clone().into());
                        }
                    }
                    if let Some(x) = r.beats_primary_only_if_nearer_by_mi {
                        m.insert("beats_primary_only_if_nearer_by_mi".into(), x.into());
                    }
                }
                Value::Object(m)
            })
            .collect();
        Value::Array(v).to_string()
    }
}

/// The kind id of a place no kind rule covers: the value of its raw type ("amenity=school" -> "school", Overture's
/// "pharmacy_and_drug_store" as it is). A bare "yes", "no" or "unknown" says nothing, so the key names it instead
/// ("mountain_pass=yes" -> "mountain_pass"). Characters outside a-z, 0-9 become an underscore. This reads the source's own
/// type tag; it never looks at a place's name.
pub fn generic_kind_id(raw_kind: &str) -> String {
    let raw = raw_kind.trim().to_lowercase();
    let (key, value) = match raw.split_once('=') {
        Some((k, v)) => (k, v),
        None => ("", raw.as_str()),
    };
    let pick = if matches!(value, "" | "yes" | "no" | "unknown") && !key.is_empty() { key } else { value };
    let id: String = pick.chars().map(|c| if c.is_ascii_lowercase() || c.is_ascii_digit() { c } else { '_' }).collect();
    let id = id.trim_matches('_').to_string();
    if id.is_empty() || id == "unknown" { "place".to_string() } else { id }
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

    fn kind<'a>(r: &'a Rules, category: Option<&str>, tags: &[(&str, &str)]) -> Option<&'a str> {
        r.osm_kind(category, tags).map(|k| k.id.as_str())
    }

    #[test]
    fn kinds_of_sample_tags() {
        let r = Rules::parse(DEFAULT).unwrap();
        let w = Some("water");
        assert_eq!(kind(&r, w, &[("amenity", "drinking_water")]), Some("drinking_water"));
        assert_eq!(kind(&r, w, &[("amenity", "water_point")]), Some("water_point"));
        assert_eq!(kind(&r, w, &[("natural", "spring")]), Some("spring"));
        assert_eq!(kind(&r, w, &[("man_made", "water_well"), ("drinking_water", "yes")]), Some("water_well"));
        assert_eq!(kind(&r, w, &[("man_made", "water_tap"), ("drinking_water", "yes")]), Some("water_tap"));
        // A spring that says it is not for drinking is not a water-category kind at all.
        assert_eq!(kind(&r, w, &[("natural", "spring"), ("drinking_water", "no")]), None);
        let s = Some("shelter");
        assert_eq!(kind(&r, s, &[("amenity", "shelter"), ("shelter_type", "picnic_shelter")]), Some("picnic_shelter"));
        assert_eq!(kind(&r, s, &[("amenity", "shelter"), ("shelter_type", "bomb_shelter")]), Some("emergency_shelter"));
        assert_eq!(kind(&r, s, &[("amenity", "shelter"), ("shelter_type", "lean_to")]), Some("trail_shelter"));
        assert_eq!(kind(&r, s, &[("amenity", "shelter"), ("shelter_type", "weather_shelter")]), Some("weather_shelter"));
        assert_eq!(kind(&r, s, &[("tourism", "wilderness_hut")]), Some("wilderness_hut"));
        assert_eq!(kind(&r, s, &[("amenity", "shelter")]), Some("shelter_unspecified"));
        assert_eq!(kind(&r, Some("hospital"), &[("healthcare", "hospital")]), Some("hospital"));
        assert_eq!(kind(&r, Some("urgent_care"), &[("amenity", "clinic")]), Some("clinic"));
        assert_eq!(kind(&r, Some("fuel"), &[("amenity", "fuel")]), Some("fuel"));
        // A kind of one category never applies to a place of another, or of none.
        assert_eq!(kind(&r, None, &[("amenity", "drinking_water")]), None);
        assert_eq!(kind(&r, Some("shelter"), &[("amenity", "drinking_water")]), None);
        // A lake is a water body, and only among the places that belong to no category.
        assert_eq!(kind(&r, None, &[("natural", "water")]), Some("water_body"));
        assert_eq!(kind(&r, w, &[("natural", "water")]), None);
        assert_eq!(r.overture_kind(Some("pharmacy"), "pharmacy_and_drug_store").unwrap().id, "pharmacy");
        assert_eq!(r.overture_kind(Some("emergency_room"), "emergency_department").unwrap().id, "emergency_room");
        assert!(r.overture_kind(None, "pharmacy_and_drug_store").is_none());
    }

    #[test]
    fn every_category_rule_has_a_kind() {
        // The category rules and the kind rules are separate data; this keeps them in step: whatever a category rule lets in has a
        // kind of that category.
        let r = Rules::parse(DEFAULT).unwrap();
        for c in &r.categories {
            for rule in c.rules.iter().filter(|x| x.source == "osm" || x.source == "overture") {
                if rule.source == "osm" {
                    // every alternative of every tag, one at a time, the other tags at their first alternative
                    for (k, v) in &rule.tags {
                        for alt in v.split('|') {
                            let tags: Vec<(&str, &str)> = rule.tags.iter().map(|(k2, v2)| if k2 == k { (k2.as_str(), alt) } else { (k2.as_str(), v2.split('|').next().unwrap()) }).collect();
                            assert!(r.osm_kind(Some(&c.id), &tags).is_some(), "category {} tags {:?} have no kind", c.id, tags);
                        }
                    }
                } else {
                    for b in &rule.basic_category {
                        assert!(r.overture_kind(Some(&c.id), b).is_some(), "category {} overture {b} has no kind", c.id);
                    }
                }
            }
        }
    }

    #[test]
    fn kind_ids_from_raw_types() {
        assert_eq!(generic_kind_id("amenity=school"), "school");
        assert_eq!(generic_kind_id("natural=hot_spring"), "hot_spring");
        assert_eq!(generic_kind_id("mountain_pass=yes"), "mountain_pass");
        assert_eq!(generic_kind_id("tourism=yes"), "tourism");
        assert_eq!(generic_kind_id("restaurant"), "restaurant");
        assert_eq!(generic_kind_id("Pharmacy & Drug"), "pharmacy___drug");
        assert_eq!(generic_kind_id("unknown"), "place");
        assert_eq!(generic_kind_id(""), "place");
        let r = Rules::parse(DEFAULT).unwrap();
        assert_eq!(r.kind_label("picnic_shelter"), "Picnic shelter");
        assert_eq!(r.kind_label("hot_spring"), "Hot spring");
    }

    #[test]
    fn bad_kinds_are_refused() {
        let mut v: serde_json::Value = serde_json::from_str(DEFAULT).unwrap();
        v["kinds"][0]["category"] = serde_json::json!("nope");
        assert!(Rules::parse(&v.to_string()).unwrap_err().contains("does not exist"));
        let mut v: serde_json::Value = serde_json::from_str(DEFAULT).unwrap();
        v["kinds"][1]["id"] = v["kinds"][0]["id"].clone();
        assert!(Rules::parse(&v.to_string()).unwrap_err().contains("twice"));
        // Rules with no kinds at all still parse (every place then takes the kind its raw type names).
        let mut v: serde_json::Value = serde_json::from_str(DEFAULT).unwrap();
        v.as_object_mut().unwrap().remove("kinds");
        assert!(Rules::parse(&v.to_string()).unwrap().kinds.is_empty());
    }

    #[test]
    fn overture_rules() {
        let r = Rules::parse(DEFAULT).unwrap();
        // Hospitals and urgent care are OSM only: Overture's medical categories are not used for them.
        assert!(r.overture_category("hospital", 0.99).is_none());
        assert!(r.overture_category("urgent_care_center", 0.99).is_none());
        let (c, rule) = r.overture_category("emergency_department", 0.9).unwrap();
        assert_eq!(c.id, "emergency_room");
        assert_eq!(rule.require_match.as_ref().unwrap().category, "hospital");
        let fb = c.rules.iter().find(|x| x.source == "category").unwrap();
        assert_eq!((fb.category.as_deref(), fb.tier.as_deref(), fb.beats_primary_only_if_nearer_by_mi), (Some("hospital"), Some("likely"), Some(10.0)));
        assert!(r.overture_category("emergency_department", 0.3).is_none());
        assert_eq!(r.overture_category("gas_station", 0.8).unwrap().0.id, "fuel");
    }
}
