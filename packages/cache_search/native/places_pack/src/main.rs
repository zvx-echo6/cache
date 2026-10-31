//! places_pack: builds a region's `places.sqlite` for Cache.
//!
//!   places_pack build --id idaho --name Idaho --admin-state Idaho --admins admins.sqlite --out places.sqlite \
//!       [--overture-csv places.csv] [--osm-pbf region.osm.pbf] [--rules categories.json] [--no-general]
//!   places_pack wiki --pack places.sqlite --geo-tags F --page-props F --items-per-site F --index F --xml-url URL [--no-summaries]
//!   places_pack embed --pack places.sqlite --embed-lib cache_llama.dll --embed-model bge-m3-Q8_0.gguf [--embed-model-id ID] [--embed-threads 4]
//!   places_pack inspect places.sqlite
//!   places_pack about-judge --packs DIR --rows-from about.jsonl --llm URL --model NAME --model-sha256 HEX --out judge.jsonl [--parallel 2]   (S14 trial)
//!   places_pack about --packs work/blocks|block.sqlite --llm http://127.0.0.1:8085 --model NAME --model-sha256 HEX --log about.jsonl [--state ID] [--parallel 2] [--from-log earlier.jsonl | --no-model]
//!
//! Places in regions (docs/PLACES-TILES.md, RECIPE.md), on the build host:
//!   places_pack harvest --out harvest.sqlite [--overture-csv places.csv] [--osm-pbf area.osm.pbf] [--rules categories.json] [--no-general]
//!   places_pack blocks --harvest harvest.sqlite --admins admins.sqlite --out work/blocks [--bbox W,S,E,N] [--halo 0.25] [--jobs 4]
//!   places_pack addresses --csv addresses.csv --blocks work/blocks --admins admins.sqlite --out work/addresses.sqlite [--bbox W,S,E,N]
//!   places_pack cut --blocks work/blocks --addresses work/addresses.sqlite --build NAME --out out [--bbox W,S,E,N] [--jobs 4]
//!   places_pack common --blocks work/blocks --build NAME --out out/NAME/common.sqlite [--taxonomy overture_taxonomy.tsv]
//!       [--kinds-described kinds-described.tsv] [--overture-release R] [--osm-source S] [--rules categories.json]

mod about;
mod about_judge;
mod addresses;
mod admins;
mod arrival;
mod blocks;
mod build;
mod common;
mod cut;
mod harvest;
mod lead;
mod model;
mod osm;
mod overture;
mod rules;
mod sqldump;
#[cfg(test)]
mod tiles_tests;
mod usps;
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
        // "--bbox=-115,37,-109,42": a value that starts with a minus sign.
        if let Some((k, v)) = k.split_once('=') {
            m.insert(k.to_string(), v.to_string());
            i += 1;
        } else if k == "no-general" || k == "no-summaries" || k == "no-model" {
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

/// The rules (`--rules`, else the compiled-in categories.json) and their JSON text.
fn load_rules(a: &HashMap<String, String>) -> Result<(rules::Rules, String), String> {
    let json = match a.get("rules") {
        Some(p) => std::fs::read_to_string(p).map_err(|e| format!("{p}: {e}"))?,
        None => DEFAULT_RULES.to_string(),
    };
    Ok((rules::Rules::parse(&json)?, json))
}

fn num<T: std::str::FromStr>(a: &HashMap<String, String>, k: &str, default: T) -> Result<T, String> {
    a.get(k).map(|v| v.parse::<T>().map_err(|_| format!("--{k} must be a number"))).transpose().map(|v| v.unwrap_or(default))
}

fn run() -> Result<(), String> {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let started = std::time::Instant::now();
    let took = || format!("{:.1} s", started.elapsed().as_secs_f64());
    match argv.first().map(String::as_str) {
        Some("about-judge") => {
            let a = parse_args(&argv[1..])?;
            let need = |k: &str| a.get(k).cloned().ok_or_else(|| format!("--{k} is required"));
            let o = about_judge::Opts {
                packs: PathBuf::from(need("packs")?),
                rows_from: PathBuf::from(need("rows-from")?),
                llm: need("llm")?,
                model: need("model")?,
                model_sha256: need("model-sha256")?,
                parallel: num(&a, "parallel", 1)?,
                out: PathBuf::from(need("out")?),
            };
            let (cut, none, calls) = about_judge::run(&o)?;
            println!("about-judge: {cut} cut, {none} without about; {calls} model calls; in {}", took());
            Ok(())
        }
        Some("about") => {
            let a = parse_args(&argv[1..])?;
            let need = |k: &str| a.get(k).cloned().ok_or_else(|| format!("--{k} is required"));
            let given = PathBuf::from(need("packs")?);
            let packs = if given.is_dir() {
                let mut v: Vec<PathBuf> = std::fs::read_dir(&given)
                    .map_err(|e| format!("{}: {e}", given.display()))?
                    .filter_map(|e| e.ok().map(|e| e.path()))
                    .filter(|p| p.extension().is_some_and(|x| x == "sqlite"))
                    .collect();
                v.sort();
                v
            } else {
                vec![given]
            };
            let o = about::Opts {
                packs,
                llm: need("llm")?,
                model: need("model")?,
                model_sha256: need("model-sha256")?,
                state: a.get("state").cloned(),
                parallel: num(&a, "parallel", 1)?,
                log: PathBuf::from(need("log")?),
                from_log: a.get("from-log").map(PathBuf::from),
                no_model: a.contains_key("no-model"),
            };
            let r = about::run(&o)?;
            println!(
                "about: {} whole, {} cut by the model, {} dropped; {} model calls, {:.2} s per call; in {}",
                r.whole, r.model_cut, r.dropped, r.calls, if r.calls > 0 { r.call_secs / r.calls as f64 } else { 0.0 }, took()
            );
            Ok(())
        }
        Some("harvest") => {
            let a = parse_args(&argv[1..])?;
            let (rules, rules_json) = load_rules(&a)?;
            let mut sources: Vec<Box<dyn PlaceSource>> = Vec::new();
            if let Some(p) = a.get("osm-pbf") {
                sources.push(Box::new(osm::OsmPbf { path: PathBuf::from(p) }));
            }
            if let Some(p) = a.get("overture-csv") {
                sources.push(Box::new(overture::OvertureCsv { path: PathBuf::from(p) }));
            }
            if sources.is_empty() {
                return Err("give at least one of --overture-csv, --osm-pbf".into());
            }
            let out = PathBuf::from(a.get("out").ok_or("--out is required")?);
            let r = harvest::harvest(&rules, &rules_json, &mut sources, !a.contains_key("no-general"), &out)?;
            println!("harvested {} places, {} localities from {} in {}", r.places, r.localities, r.sources.join("; "), took());
            println!("size {} bytes", std::fs::metadata(&out).map(|m| m.len()).unwrap_or(0));
            Ok(())
        }
        Some("blocks") => {
            let a = parse_args(&argv[1..])?;
            let need = |k: &str| a.get(k).map(PathBuf::from).ok_or_else(|| format!("--{k} is required"));
            let (rules, rules_json) = load_rules(&a)?;
            let cfg = blocks::BlocksCfg {
                harvest: need("harvest")?,
                admins: need("admins")?,
                out: need("out")?,
                bbox: a.get("bbox").map(|b| blocks::parse_bbox(b)).transpose()?,
                halo: num(&a, "halo", 0.25)?,
                jobs: num(&a, "jobs", 4)?,
                country: a.get("country").cloned().unwrap_or_else(|| "US".into()),
            };
            let r = blocks::blocks(&cfg, &rules, &rules_json)?;
            let sum = |f: fn(&blocks::BlockReport) -> usize| r.iter().map(f).sum::<usize>();
            println!(
                "{} blocks, {} tiles: {} places, {} towns ({} merged, {} deduped, {} emergency rooms, {} arrival points) in {}",
                r.len(), sum(|b| b.cells), sum(|b| b.places), sum(|b| b.localities), sum(|b| b.merged), sum(|b| b.deduped), sum(|b| b.enriched), sum(|b| b.arrivals), took()
            );
            Ok(())
        }
        Some("addresses") => {
            let a = parse_args(&argv[1..])?;
            let need = |k: &str| a.get(k).map(PathBuf::from).ok_or_else(|| format!("--{k} is required"));
            let cfg = addresses::AddressesCfg {
                csv: need("csv")?,
                blocks: need("blocks")?,
                admins: need("admins")?,
                out: need("out")?,
                bbox: a.get("bbox").map(|b| blocks::parse_bbox(b)).transpose()?,
            };
            let r = addresses::addresses(&cfg)?;
            println!(
                "{} addresses read: {} street rows, {} house numbers ({} repeats dropped, {} skipped); {} rows with a written-out street; {} addresses took the nearest town; numbers {} bytes; in {}",
                r.read, r.streets, r.numbers, r.repeats, r.skipped, r.expanded, r.nearest_town, r.blob_bytes, took()
            );
            println!("size {} bytes", std::fs::metadata(&cfg.out).map(|m| m.len()).unwrap_or(0));
            Ok(())
        }
        Some("cut") => {
            let a = parse_args(&argv[1..])?;
            let need = |k: &str| a.get(k).cloned().ok_or_else(|| format!("--{k} is required"));
            let cfg = cut::CutCfg {
                blocks: PathBuf::from(need("blocks")?),
                addresses: a.get("addresses").map(PathBuf::from),
                out: PathBuf::from(need("out")?),
                build: need("build")?,
                bbox: a.get("bbox").map(|b| blocks::parse_bbox(b)).transpose()?,
                jobs: num(&a, "jobs", 4)?,
            };
            let tiles = cut::cut(&cfg)?;
            println!("path\ttile\tbytes\tgz_bytes\tplaces\tlocalities\tlocalities_ctx\taddr_streets\taddresses");
            for t in &tiles {
                println!("{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}\t{}", t.path, t.tile, t.bytes, t.gz_bytes, t.places, t.localities, t.localities_ctx, t.streets, t.addresses);
            }
            let s = |f: fn(&cut::TileOut) -> u64| tiles.iter().map(f).sum::<u64>();
            println!(
                "{} tiles, {} bytes, {} gzip bytes; {} places, {} towns, {} street rows, {} house numbers; in {}",
                tiles.len(), s(|t| t.bytes), s(|t| t.gz_bytes), s(|t| t.places as u64), s(|t| t.localities as u64), s(|t| t.streets as u64), s(|t| t.addresses as u64), took()
            );
            Ok(())
        }
        Some("common") => {
            let a = parse_args(&argv[1..])?;
            let need = |k: &str| a.get(k).cloned().ok_or_else(|| format!("--{k} is required"));
            let (rules, rules_json) = load_rules(&a)?;
            let cfg = common::CommonCfg {
                blocks: PathBuf::from(need("blocks")?),
                out: PathBuf::from(need("out")?),
                build: need("build")?,
                taxonomy: a.get("taxonomy").map(PathBuf::from),
                described: a.get("kinds-described").map(PathBuf::from),
                overture_release: a.get("overture-release").cloned().unwrap_or_default(),
                osm_source: a.get("osm-source").cloned().unwrap_or_default(),
            };
            let r = common::common(&cfg, &rules, &rules_json)?;
            println!(
                "{} kinds: {} from the rules, {} described, {} from the Overture taxonomy, {} from an OSM tag, {} label only; {} states; in {}",
                r.kinds, r.rule_kinds, r.described, r.from_taxonomy, r.from_tag, r.label_only, r.states, took()
            );
            println!("size {} bytes", std::fs::metadata(&cfg.out).map(|m| m.len()).unwrap_or(0));
            Ok(())
        }
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
            for (k, v) in &r.per_kind {
                println!("  kind {k:<28} {v}");
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
            let meta = |k: &str| c.query_row("SELECT value FROM meta WHERE key = ?1", [k], |r| r.get::<_, String>(0)).unwrap_or_else(|_| "-".into());
            println!("format {}, built {}, embed model {} ({} vectors)", meta("format_version"), meta("built_at"), meta("embed_model"), q("SELECT count(*) FROM vectors"));
            println!("sources: {}", meta("sources"));
            println!("places with a summary {}", q("SELECT count(*) FROM places WHERE summary IS NOT NULL AND summary <> ''"));
            if q("SELECT count(*) FROM sqlite_master WHERE name = 'kinds'") > 0 {
                println!("places with no kind {}", q("SELECT count(*) FROM places WHERE kind_id IS NULL"));
                let mut st = c.prepare("SELECT id, label, category, place_count FROM kinds ORDER BY sort").map_err(|e| e.to_string())?;
                let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Option<String>>(2)?, r.get::<_, i64>(3)?))).map_err(|e| e.to_string())?;
                for r in rows {
                    let (id, label, cat, n) = r.map_err(|e| e.to_string())?;
                    if cat.is_some() || n >= 200 {
                        println!("  kind {id:<22} {n:>6}  {label} ({})", cat.unwrap_or_else(|| "no category".into()));
                    }
                }
            }
            Ok(())
        }
        _ => Err("usage: places_pack build ... | wiki ... | embed ... | inspect <places.sqlite> | harvest ... | blocks ... | addresses ... | cut ... | common ...".into()),
    }
}

fn main() {
    if let Err(e) = run() {
        eprintln!("places_pack: {e}");
        std::process::exit(1);
    }
}
