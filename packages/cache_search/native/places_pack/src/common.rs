//! `places_pack common`: the build's common file (`cache_places::schema::COMMON_SQL`, docs/PLACES-TILES.md): its meta, the
//! categories, every kind of place any block holds with a one-line description, and every state and province.
//!
//! Kind descriptions, in this order:
//! - a kind the rules define keeps the rules' own description (`categories.json`);
//! - a kind in `kinds-described.tsv` takes the line written there (`scripts/describe_kinds.py`, reviewed, kept with the
//!   builder and reused across builds);
//! - otherwise the data's own words: an Overture kind its label and its path in the release's taxonomy
//!   ("Diner (food and drink, casual eatery)"), a kind from an OSM tag its label and the tag's key ("Restaurant
//!   (amenity)").
//!
//! The category and kind vectors are added by the embed step.

use crate::blocks::block_files;
use crate::build::ATTRIBUTION;
use crate::rules::Rules;
use cache_places::schema::{COMMON_SQL, TILE_SCHEMA};
use rusqlite::{params, Connection, OpenFlags};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};

pub struct CommonCfg {
    pub blocks: PathBuf,
    pub out: PathBuf,
    pub build: String,
    /// `overture_taxonomy.tsv` from the extract: category, path.
    pub taxonomy: Option<PathBuf>,
    /// `kinds-described.tsv`: kind, description, model, date.
    pub described: Option<PathBuf>,
    pub overture_release: String,
    pub osm_source: String,
}

#[derive(Debug, Default)]
pub struct CommonReport {
    pub kinds: usize,
    pub rule_kinds: usize,
    pub described: usize,
    pub from_taxonomy: usize,
    pub from_tag: usize,
    pub label_only: usize,
    pub states: usize,
}

/// The tab-separated rows of a file with a header line, `#` lines skipped.
fn read_tsv(p: &Path) -> Result<Vec<Vec<String>>, String> {
    let text = std::fs::read_to_string(p).map_err(|e| format!("{}: {e}", p.display()))?;
    Ok(text.lines().skip(1).filter(|l| !l.trim().is_empty() && !l.starts_with('#')).map(|l| l.split('\t').map(str::to_string).collect()).collect())
}

/// kinds-described.tsv: kind id -> description.
pub fn read_described(p: &Path) -> Result<HashMap<String, String>, String> {
    Ok(read_tsv(p)?.into_iter().filter(|r| r.len() >= 2 && !r[1].trim().is_empty()).map(|r| (r[0].clone(), r[1].trim().to_string())).collect())
}

/// The taxonomy text of an Overture kind: "Diner (food and drink, casual eatery)" for the path
/// "food_and_drink > casual_eatery > diner".
pub fn taxonomy_text(label: &str, path: &str) -> String {
    let parts: Vec<String> = path.split(" > ").map(|p| p.trim().replace('_', " ")).collect();
    match parts.split_last() {
        Some((_, above)) if !above.is_empty() => format!("{label} ({})", above.join(", ")),
        _ => label.to_string(),
    }
}

pub fn common(cfg: &CommonCfg, rules: &Rules, rules_json: &str) -> Result<CommonReport, String> {
    let taxonomy: HashMap<String, String> = match &cfg.taxonomy {
        Some(p) => read_tsv(p)?.into_iter().filter(|r| r.len() >= 2).map(|r| (r[0].clone(), r[1].clone())).collect(),
        None => HashMap::new(),
    };
    let described = match &cfg.described {
        Some(p) if p.exists() => read_described(p)?,
        _ => HashMap::new(),
    };
    // Every derived kind of every block, with the raw types its places carry (the most common names its OSM key).
    let mut raw_types: BTreeMap<String, BTreeMap<String, i64>> = BTreeMap::new();
    let mut states: BTreeMap<String, (String, Option<String>)> = BTreeMap::new();
    let mut sources = Vec::new();
    for (_, p) in block_files(&cfg.blocks)? {
        let c = Connection::open_with_flags(&p, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| format!("{}: {e}", p.display()))?;
        let mut st = c.prepare("SELECT kind_id, kind, COUNT(*) FROM places WHERE kind_id IS NOT NULL GROUP BY 1, 2").map_err(|e| e.to_string())?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, Option<String>>(1)?, r.get::<_, i64>(2)?))).map_err(|e| e.to_string())?;
        for r in rows {
            let (k, raw, n) = r.map_err(|e| e.to_string())?;
            *raw_types.entry(k).or_default().entry(raw.unwrap_or_default()).or_default() += n;
        }
        let mut st = c.prepare("SELECT code, name, country FROM states").map_err(|e| e.to_string())?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?))).map_err(|e| e.to_string())?;
        for r in rows {
            let (code, name, country) = r.map_err(|e| e.to_string())?;
            states.entry(code).or_insert((name, country));
        }
        if let Ok(s) = c.query_row("SELECT value FROM meta WHERE key = 'sources'", [], |r| r.get::<_, String>(0)) {
            if !sources.contains(&s) {
                sources.push(s);
            }
        }
    }

    let _ = std::fs::remove_file(&cfg.out);
    if let Some(d) = cfg.out.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let mut c = Connection::open(&cfg.out).map_err(|e| format!("{}: {e}", cfg.out.display()))?;
    c.execute_batch(COMMON_SQL).map_err(|e| e.to_string())?;
    let tx = c.transaction().map_err(|e| e.to_string())?;
    let mut rep = CommonReport { states: states.len(), ..Default::default() };
    for (i, cat) in rules.categories.iter().enumerate() {
        tx.execute(
            "INSERT INTO categories(id, title, description, rules, sort) VALUES (?1, ?2, ?3, ?4, ?5)",
            params![cat.id, cat.title, cat.description, Rules::rules_json(cat), i as i64],
        )
        .map_err(|e| e.to_string())?;
    }
    let mut sort = 0i64;
    for k in &rules.kinds {
        tx.execute(
            "INSERT INTO kinds(id, label, description, category, rules, sort) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![k.id, k.label, k.description, k.category, Rules::kind_rules_json(k), sort],
        )
        .map_err(|e| e.to_string())?;
        sort += 1;
        rep.rule_kinds += 1;
    }
    for (id, raws) in raw_types.iter().filter(|(id, _)| !rules.kinds.iter().any(|k| &k.id == *id)) {
        let label = rules.kind_label(id);
        let description = if let Some(d) = described.get(id) {
            rep.described += 1;
            d.clone()
        } else if let Some(path) = taxonomy.get(id) {
            rep.from_taxonomy += 1;
            taxonomy_text(&label, path)
        } else if let Some((key, _)) = raws.iter().max_by_key(|(_, n)| **n).and_then(|(raw, _)| raw.split_once('=')) {
            rep.from_tag += 1;
            format!("{label} ({key})")
        } else {
            rep.label_only += 1;
            label.clone()
        };
        tx.execute("INSERT INTO kinds(id, label, description, category, rules, sort) VALUES (?1, ?2, ?3, NULL, '[]', ?4)", params![id, label, description, sort])
            .map_err(|e| e.to_string())?;
        sort += 1;
    }
    rep.kinds = sort as usize;
    for (code, (name, country)) in &states {
        tx.execute("INSERT INTO states(code, name, country) VALUES (?1, ?2, ?3)", params![code, name, country]).map_err(|e| e.to_string())?;
    }
    for (k, v) in [
        ("tile_schema", TILE_SCHEMA.to_string()),
        ("build", cfg.build.clone()),
        ("built_at", chrono::Local::now().format("%Y-%m-%dT%H:%M:%S%:z").to_string()),
        ("overture_release", cfg.overture_release.clone()),
        ("osm_source", cfg.osm_source.clone()),
        ("sources", sources.join("; ")),
        ("builder_rules", rules_json.to_string()),
        ("attribution", ATTRIBUTION.to_string()),
        ("levels", "[1]".to_string()),
    ] {
        tx.execute("INSERT INTO meta(key, value) VALUES (?1, ?2)", params![k, v]).map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    c.execute_batch("VACUUM;").map_err(|e| e.to_string())?;
    Ok(rep)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn taxonomy_texts() {
        assert_eq!(taxonomy_text("Diner", "food_and_drink > casual_eatery > diner"), "Diner (food and drink, casual eatery)");
        assert_eq!(taxonomy_text("Restaurant", "food_and_drink > restaurant"), "Restaurant (food and drink)");
        assert_eq!(taxonomy_text("Health care", "health_care"), "Health care");
    }
}
