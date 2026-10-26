//! places_pack: builds a region's `places.sqlite` for Cache.
//!
//!   places_pack build --id idaho --name Idaho --admin-state Idaho --admins admins.sqlite --out places.sqlite \
//!       [--overture-csv places.csv] [--osm-pbf region.osm.pbf] [--rules categories.json] [--no-general]
//!   places_pack wiki --pack places.sqlite --geo-tags F --page-props F --items-per-site F --index F --xml-url URL [--no-summaries]
//!   places_pack embed --pack places.sqlite --embed-lib cache_llama.dll --embed-model bge-m3-Q8_0.gguf [--embed-model-id ID] [--embed-threads 4]
//!   places_pack inspect places.sqlite

mod admins;
mod build;
mod lead;
mod model;
mod osm;
mod overture;
mod rules;
mod sqldump;
mod wiki;

use build::{build, BuildCfg};
use model::PlaceSource;
use rusqlite::{Connection, OpenFlags};
use std::collections::HashMap;
use std::path::PathBuf;

const DEFAULT_RULES: &str = include_str!("../categories.json");

fn parse_args(argv: &[String]) -> Result<HashMap<String, String>, String> {
    let mut m = HashMap::new();
    let mut i = 0;
    while i < argv.len() {
        let k = argv[i].strip_prefix("--").ok_or_else(|| format!("unexpected argument {:?}", argv[i]))?;
        if k == "no-general" || k == "no-summaries" {
            m.insert(k.to_string(), String::new());
            i += 1;
        } else {
            let v = argv.get(i + 1).ok_or_else(|| format!("--{k} needs a value"))?;
            m.insert(k.to_string(), v.clone());
            i += 2;
        }
    }
    Ok(m)
}

fn run() -> Result<(), String> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    match argv.first().map(String::as_str) {
        Some("build") => {
            let a = parse_args(&argv[1..])?;
            let need = |k: &str| a.get(k).cloned().ok_or_else(|| format!("--{k} is required"));
            let rules_json = match a.get("rules") {
                Some(p) => std::fs::read_to_string(p).map_err(|e| format!("{p}: {e}"))?,
                None => DEFAULT_RULES.to_string(),
            };
            let rules = rules::Rules::parse(&rules_json)?;
            let mut sources: Vec<Box<dyn PlaceSource>> = Vec::new();
            if let Some(p) = a.get("overture-csv") {
                sources.push(Box::new(overture::OvertureCsv { path: PathBuf::from(p) }));
            }
            if let Some(p) = a.get("osm-pbf") {
                sources.push(Box::new(osm::OsmPbf { path: PathBuf::from(p) }));
            }
            if sources.is_empty() {
                return Err("give at least one of --overture-csv, --osm-pbf".into());
            }
            let cfg = BuildCfg { id: need("id")?, name: need("name")?, admin_state: need("admin-state")?, include_general: !a.contains_key("no-general"), country: a.get("country").cloned().unwrap_or_else(|| "US".into()) };
            let out = PathBuf::from(need("out")?);
            let r = build(&cfg, &rules, &rules_json, &mut sources, &PathBuf::from(need("admins")?), &out)?;
            println!("{} places, {} localities; {} Overture records merged into OSM, {} OSM duplicates dropped, {} emergency rooms enriched", r.places, r.localities, r.merged, r.deduped, r.enriched);
            println!("size {} bytes", std::fs::metadata(&out).map(|m| m.len()).unwrap_or(0));
            for (k, v) in &r.per_category {
                println!("  {k:<16} {v}");
            }
            for (k, v) in &r.per_source {
                println!("  source {k:<14} {v}");
            }
            for n in &r.notes {
                println!("note: {n}");
            }
            Ok(())
        }
        Some("wiki") => {
            let a = parse_args(&argv[1..])?;
            let need = |k: &str| a.get(k).map(PathBuf::from).ok_or_else(|| format!("--{k} is required"));
            let o = wiki::Opts {
                pack: need("pack")?,
                geo_tags: need("geo-tags")?,
                page_props: need("page-props")?,
                items_per_site: need("items-per-site")?,
                index: need("index")?,
                xml_url: a.get("xml-url").cloned().ok_or("--xml-url is required")?,
                user_agent: a.get("user-agent").cloned().unwrap_or_else(|| "cache-places-pack/1.0 (noreply@users.noreply.github.com)".into()),
                summaries: !a.contains_key("no-summaries"),
            };
            for l in wiki::run(&o)?.lines {
                println!("{l}");
            }
            println!("size {} bytes", std::fs::metadata(&o.pack).map(|m| m.len()).unwrap_or(0));
            Ok(())
        }
        Some("embed") => {
            // The meaning-search vectors: category texts, and places and towns that have a summary (cache_places::embedpack).
            let a = parse_args(&argv[1..])?;
            let need = |k: &str| a.get(k).cloned().ok_or_else(|| format!("--{k} is required"));
            let threads: i32 = a.get("embed-threads").map(|t| t.parse().map_err(|_| "--embed-threads must be a number".to_string())).transpose()?.unwrap_or(4);
            let model = need("embed-model")?;
            let e = cache_embed::Embedder::load(&need("embed-lib")?, &model, a.get("embed-model-id").map(String::as_str), a.get("embed-sha256").map(String::as_str), threads).map_err(|e| e.to_string())?;
            let sha = cache_embed::sha256_file(&model).map_err(|e| e.to_string())?;
            let pack = PathBuf::from(need("pack")?);
            let r = cache_places::embedpack::embed_pack(&pack, &e.model_id, &sha, &mut |t| e.embed(t).map_err(|x| x.to_string()), &mut |l| eprintln!("{l}"))?;
            println!("embedded {} categories, {} places, {} towns ({} values each, model {})", r.categories, r.places, r.localities, r.dims, e.model_id);
            println!("size {} bytes", std::fs::metadata(&pack).map(|m| m.len()).unwrap_or(0));
            Ok(())
        }
        Some("inspect") => {
            let p = argv.get(1).ok_or("inspect needs a pack path")?;
            let c = Connection::open_with_flags(p, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| e.to_string())?;
            let q = |sql: &str| c.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap_or(-1);
            println!("size {} bytes", std::fs::metadata(p).map(|m| m.len()).unwrap_or(0));
            println!("places {}, localities {}", q("SELECT count(*) FROM places"), q("SELECT count(*) FROM localities"));
            let mut st = c.prepare("SELECT id, title, place_count, description FROM categories ORDER BY sort").map_err(|e| e.to_string())?;
            let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, i64>(2)?, r.get::<_, String>(3)?))).map_err(|e| e.to_string())?;
            for r in rows {
                let (id, title, n, d) = r.map_err(|e| e.to_string())?;
                println!("  {id:<15} {n:>6}  {title}: {d}");
            }
            Ok(())
        }
        _ => Err("usage: places_pack build ... | wiki ... | embed ... | inspect <places.sqlite>".into()),
    }
}

fn main() {
    if let Err(e) = run() {
        eprintln!("places_pack: {e}");
        std::process::exit(1);
    }
}
