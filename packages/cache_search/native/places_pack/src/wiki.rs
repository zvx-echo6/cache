//! The wiki step: adds Wikidata and Wikipedia identifiers and a short summary to a built pack, from IDs only.
//!
//! 1. IDs the OSM data itself carries (`wikidata`, `wikipedia`, `wikivoyage` tags, already in the pack).
//! 2. For towns and landmarks with no such tag: English Wikipedia's own coordinate data (the `geo_tags` dump) gives each
//!    article's position and, through `page_props` (`wikibase_item`), its Wikidata item. A place takes an article only
//!    when the article is within a small radius of it AND the article's title, without its ", State" or "(kind)" tail,
//!    is the place's own name. No fuzzy matching.
//! 3. Wikidata's `wb_items_per_site` dump gives each item's enwiki and enwikivoyage titles (and the item of a title).
//! 4. Summary: the first paragraph of the enwiki article, from the official multistream dump: its index gives each
//!    article's bzip2 stream, only those streams are fetched (HTTP Range, one connection, as the dumps host allows) and read.
//! A brand's Wikidata item (`brand_wikidata`) is stored as the brand only; it never fills the place's own fields.
//!
//! The tiled build runs it once over every block (`--packs <dir>`): the dumps are read once for all of them. With a
//! `--cache` file (wiki-cache.sqlite), what each article's stream gave (its summary, a redirect, or nothing) is kept by
//! (dump date, title), so a later build fetches only the articles it has not seen in that dump.

use crate::lead::lead_paragraph;
use crate::sqldump::Dump;
use rusqlite::{params, Connection};
use std::collections::{BTreeSet, HashMap, HashSet};
use std::fs::File;
use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;
use std::time::Duration;

pub struct Opts {
    /// The packs to fill (one, or every block of a tiled build).
    pub packs: Vec<PathBuf>,
    pub geo_tags: PathBuf,
    pub page_props: PathBuf,
    pub items_per_site: PathBuf,
    pub index: PathBuf,
    /// The multistream XML dump on the dumps server, fetched by range.
    pub xml_url: String,
    pub user_agent: String,
    pub summaries: bool,
    /// wiki-cache.sqlite: what each article gave, by (dump date, title); None for no cache.
    pub cache: Option<PathBuf>,
}

struct Target {
    /// Which of `Opts::packs` it is in.
    pack: usize,
    locality: bool,
    id: i64,
    name: String,
    lat: f64,
    lon: f64,
    qid: Option<String>,
    wikipedia: Option<String>,
    wikivoyage: Option<String>,
    via_tag: bool,
}

fn gz(path: &PathBuf) -> Result<BufReader<flate2::read::MultiGzDecoder<BufReader<File>>>, String> {
    let f = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(BufReader::with_capacity(1 << 20, flate2::read::MultiGzDecoder::new(BufReader::new(f))))
}

fn norm(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(|c| c.to_lowercase()).collect()
}

/// "Burley, Idaho" and "Mercury (planet)" both name "Burley" and "Mercury".
fn title_base(title: &str) -> &str {
    let t = title.split(',').next().unwrap_or(title);
    t.split(" (").next().unwrap_or(t).trim()
}

fn qnum(q: &str) -> Option<i64> {
    q.strip_prefix('Q')?.parse().ok()
}

fn dist_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    cache_places::geo::haversine_km(lat1, lon1, lat2, lon2)
}

#[derive(Default)]
pub struct Report {
    pub lines: Vec<String>,
}

/// The pack files of a directory of blocks (`<level 0 id>.sqlite`), in block order.
pub fn packs_in(dir: &std::path::Path) -> Result<Vec<PathBuf>, String> {
    Ok(crate::blocks::block_files(dir)?.into_iter().map(|(_, p)| p).collect())
}

pub fn run(o: &Opts) -> Result<Report, String> {
    let mut rep = Report::default();
    let conns: Vec<Connection> = o.packs.iter().map(|p| Connection::open(p).map_err(|e| format!("{}: {e}", p.display()))).collect::<Result<_, _>>()?;
    // Each pack's box (min_lat, min_lon, max_lat, max_lon).
    let mut boxes: Vec<(f64, f64, f64, f64)> = Vec::new();
    for conn in &conns {
        let g = |k: &str| -> Result<f64, String> {
            conn.query_row("SELECT value FROM meta WHERE key = ?1", params![k], |r| r.get::<_, String>(0)).map_err(|e| e.to_string())?.parse().map_err(|_| format!("meta {k}"))
        };
        boxes.push((g("min_lat")?, g("min_lon")?, g("max_lat")?, g("max_lon")?));
    }

    // Targets: every named place and every locality of every pack.
    let mut targets: Vec<Target> = Vec::new();
    for (pack, conn) in conns.iter().enumerate() {
        for (table, locality) in [("places", false), ("localities", true)] {
            let mut st = conn
                .prepare(&format!("SELECT id, name, lat, lon, wikidata_id, wikipedia_title, wikivoyage_title FROM {table} WHERE name IS NOT NULL"))
                .map_err(|e| e.to_string())?;
            let rows = st
                .query_map([], |r| {
                    Ok(Target {
                        pack,
                        locality,
                        id: r.get(0)?,
                        name: r.get(1)?,
                        lat: r.get(2)?,
                        lon: r.get(3)?,
                        qid: r.get(4)?,
                        wikipedia: r.get(5)?,
                        wikivoyage: r.get(6)?,
                        via_tag: false,
                    })
                })
                .map_err(|e| e.to_string())?;
            for t in rows {
                let mut t = t.map_err(|e| e.to_string())?;
                t.via_tag = t.qid.is_some() || t.wikipedia.is_some() || t.wikivoyage.is_some();
                targets.push(t);
            }
        }
    }
    rep.lines.push(format!("{} named places and localities; {} carry an OSM wikidata, wikipedia or wikivoyage tag", targets.len(), targets.iter().filter(|t| t.via_tag).count()));

    // enwiki articles with coordinates inside a pack's box.
    eprintln!("reading geo_tags");
    let mut geo: Vec<(i64, f64, f64)> = Vec::new();
    {
        let mut d = Dump::open(gz(&o.geo_tags)?, "geo_tags")?;
        let (c_page, c_globe, c_primary, c_lat, c_lon) = (d.col("gt_page_id")?, d.col("gt_globe")?, d.col("gt_primary")?, d.col("gt_lat")?, d.col("gt_lon")?);
        d.for_each(|f| {
            if f[c_primary].raw != b"1" || !f[c_globe].is("earth") {
                return;
            }
            let (Some(lat), Some(lon), Some(page)) = (f[c_lat].f64(), f[c_lon].f64(), f[c_page].i64()) else { return };
            if boxes.iter().any(|b| lat >= b.0 && lat <= b.2 && lon >= b.1 && lon <= b.3) {
                geo.push((page, lat, lon));
            }
        })?;
    }
    rep.lines.push(format!("{} English Wikipedia articles have a primary coordinate inside the packs' boxes", geo.len()));

    eprintln!("reading page_props");
    let mut page_qid: HashMap<i64, i64> = HashMap::new();
    {
        let wanted: HashSet<i64> = geo.iter().map(|g| g.0).collect();
        let mut d = Dump::open(gz(&o.page_props)?, "page_props")?;
        let (c_page, c_name, c_val) = (d.col("pp_page")?, d.col("pp_propname")?, d.col("pp_value")?);
        d.for_each(|f| {
            if f[c_name].is("wikibase_item") {
                if let Some(p) = f[c_page].i64().filter(|p| wanted.contains(p)) {
                    if let Some(q) = f[c_val].string().as_deref().and_then(qnum) {
                        page_qid.insert(p, q);
                    }
                }
            }
        })?;
    }

    // Sitelinks: titles of every item we may need, and the item of every title a tag named.
    let mut wanted_q: HashSet<i64> = page_qid.values().copied().collect();
    wanted_q.extend(targets.iter().filter_map(|t| t.qid.as_deref().and_then(qnum)));
    let wanted_titles: HashSet<String> = targets.iter().filter(|t| t.qid.is_none()).filter_map(|t| t.wikipedia.clone()).collect();
    eprintln!("reading wb_items_per_site ({} items wanted)", wanted_q.len());
    let mut en_title: HashMap<i64, String> = HashMap::new();
    let mut voy_title: HashMap<i64, String> = HashMap::new();
    let mut title_q: HashMap<String, i64> = HashMap::new();
    {
        let mut d = Dump::open(gz(&o.items_per_site)?, "wb_items_per_site")?;
        let (c_item, c_site, c_page) = (d.col("ips_item_id")?, d.col("ips_site_id")?, d.col("ips_site_page")?);
        d.for_each(|f| {
            let is_en = f[c_site].is("enwiki");
            if !is_en && !f[c_site].is("enwikivoyage") {
                return;
            }
            let Some(item) = f[c_item].i64() else { return };
            let in_q = wanted_q.contains(&item);
            if !in_q && !is_en {
                return;
            }
            let Some(title) = f[c_page].string() else { return };
            if is_en && wanted_titles.contains(&title) {
                title_q.insert(title.clone(), item);
            }
            if in_q {
                if is_en { en_title.insert(item, title) } else { voy_title.insert(item, title) };
            }
        })?;
    }

    // Coordinate join for targets without any tag: nearby article, same name.
    let mut cell: HashMap<(i32, i32), Vec<usize>> = HashMap::new();
    for (i, g) in geo.iter().enumerate() {
        cell.entry(((g.1 * 10.0).floor() as i32, (g.2 * 10.0).floor() as i32)).or_default().push(i);
    }
    let (mut by_tag, mut by_geo, mut by_title) = (0, 0, 0);
    let mut resolved: Vec<(usize, Option<i64>, Option<String>, Option<String>)> = Vec::new();
    for (ti, t) in targets.iter().enumerate() {
        let mut q = t.qid.as_deref().and_then(qnum);
        let mut wp = t.wikipedia.clone();
        if q.is_some() || wp.is_some() || t.wikivoyage.is_some() {
            by_tag += 1;
            if q.is_none() {
                q = wp.as_ref().and_then(|w| title_q.get(w)).copied();
                if q.is_some() {
                    by_title += 1;
                }
            }
        } else {
            let radius = if t.locality { 6.0 } else { 0.15 };
            let (ci, cj) = ((t.lat * 10.0).floor() as i32, (t.lon * 10.0).floor() as i32);
            let mut best: Option<(f64, i64)> = None;
            for di in -1..=1 {
                for dj in -1..=1 {
                    for &gi in cell.get(&(ci + di, cj + dj)).into_iter().flatten() {
                        let (page, lat, lon) = geo[gi];
                        let d = dist_km(t.lat, t.lon, lat, lon);
                        if d > radius || best.is_some_and(|(b, _)| b <= d) {
                            continue;
                        }
                        let Some(&item) = page_qid.get(&page) else { continue };
                        if en_title.get(&item).is_some_and(|title| norm(title_base(title)) == norm(&t.name)) {
                            best = Some((d, item));
                        }
                    }
                }
            }
            if let Some((_, item)) = best {
                q = Some(item);
                by_geo += 1;
            }
        }
        if wp.is_none() {
            wp = q.and_then(|q| en_title.get(&q)).cloned();
        }
        let voy = t.wikivoyage.clone().or_else(|| q.and_then(|q| voy_title.get(&q)).cloned());
        if q.is_some() || wp.is_some() || voy.is_some() {
            resolved.push((ti, q, wp, voy));
        }
    }
    rep.lines.push(format!("resolved by OSM tag: {by_tag} (of which {by_title} found their item from the wikipedia title); by Wikipedia coordinates and exact name: {by_geo}"));

    // Summaries.
    let mut summary: HashMap<String, String> = HashMap::new();
    if o.summaries {
        let titles: BTreeSet<String> = resolved.iter().filter_map(|r| r.2.clone()).collect();
        eprintln!("fetching {} articles", titles.len());
        let (found, notes) = fetch_summaries(o, &titles)?;
        summary = found;
        rep.lines.extend(notes);
    }

    // Write.
    let txs: Vec<rusqlite::Transaction> = conns.iter().map(|c| c.unchecked_transaction().map_err(|e| e.to_string())).collect::<Result<_, _>>()?;
    let (mut n_q, mut n_wp, mut n_voy, mut n_sum) = ([0usize; 2], [0usize; 2], [0usize; 2], [0usize; 2]);
    for (ti, q, wp, voy) in &resolved {
        let t = &targets[*ti];
        let k = t.locality as usize;
        let qs = q.map(|q| format!("Q{q}"));
        let sm = wp.as_ref().and_then(|w| summary.get(w)).cloned();
        let table = if t.locality { "localities" } else { "places" };
        txs[t.pack]
            .execute(
                &format!("UPDATE {table} SET wikidata_id = ?1, wikipedia_title = ?2, wikivoyage_title = ?3, summary = ?4 WHERE id = ?5"),
                params![qs, wp, voy, sm, t.id],
            )
            .map_err(|e| e.to_string())?;
        n_q[k] += qs.is_some() as usize;
        n_wp[k] += wp.is_some() as usize;
        n_voy[k] += voy.is_some() as usize;
        n_sum[k] += sm.is_some() as usize;
    }
    for tx in txs {
        tx.commit().map_err(|e| e.to_string())?;
    }
    let count = |sql: &str| -> i64 { conns.iter().map(|c| c.query_row(sql, [], |r| r.get::<_, i64>(0)).unwrap_or(0)).sum() };
    for (k, label, table) in [(0usize, "places", "places"), (1, "localities", "localities")] {
        rep.lines.push(format!(
            "{label} (of {}): wikidata_id {}, wikipedia_title {}, wikivoyage_title {}, summary {}",
            count(&format!("SELECT count(*) FROM {table}")),
            n_q[k],
            n_wp[k],
            n_voy[k],
            n_sum[k]
        ));
    }
    rep.lines.push(format!("places with a brand_wikidata (brand only): {}", count("SELECT count(*) FROM places WHERE brand_wikidata IS NOT NULL")));
    let mut per_cat: std::collections::BTreeMap<String, (i64, i64, i64)> = Default::default();
    for conn in &conns {
        let mut st = conn
            .prepare("SELECT category, count(*), sum(wikidata_id IS NOT NULL), sum(summary IS NOT NULL) FROM places WHERE category IS NOT NULL GROUP BY 1 ORDER BY 1")
            .map_err(|e| e.to_string())?;
        let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?, r.get::<_, i64>(3)?))).map_err(|e| e.to_string())?;
        for r in rows {
            let (c, n, q, s) = r.map_err(|e| e.to_string())?;
            let e = per_cat.entry(c).or_default();
            (e.0, e.1, e.2) = (e.0 + n, e.1 + q, e.2 + s);
        }
    }
    for (c, (n, q, s)) in per_cat {
        rep.lines.push(format!("  {c:<16} {n:>6} places, {q} with wikidata_id, {s} with summary"));
    }
    for conn in &conns {
        conn.execute_batch("VACUUM;").map_err(|e| e.to_string())?;
    }
    Ok(rep)
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;").replace('<', "&lt;").replace('>', "&gt;").replace('"', "&quot;")
}

fn xml_unescape(s: &str) -> String {
    s.replace("&lt;", "<").replace("&gt;", ">").replace("&quot;", "\"").replace("&apos;", "'").replace("&amp;", "&")
}

/// Offsets of the wanted titles' bzip2 streams, and every stream offset (so a stream's length is known).
fn scan_index(path: &PathBuf, wanted: &BTreeSet<String>) -> Result<(HashMap<String, u64>, BTreeSet<u64>), String> {
    let f = File::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let mut r = BufReader::with_capacity(1 << 20, bzip2::read::MultiBzDecoder::new(BufReader::new(f)));
    let (mut found, mut offsets) = (HashMap::new(), BTreeSet::new());
    let mut line = String::new();
    loop {
        line.clear();
        if r.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
            break;
        }
        // offset:pageid:title
        let mut it = line.trim_end().splitn(3, ':');
        let (Some(off), Some(_), Some(title)) = (it.next(), it.next(), it.next()) else { continue };
        let Ok(off) = off.parse::<u64>() else { continue };
        offsets.insert(off);
        if wanted.contains(title) {
            found.insert(title.to_string(), off);
        }
    }
    Ok((found, offsets))
}

fn get_range(agent: &ureq::Agent, url: &str, ua: &str, from: u64, to: Option<u64>) -> Result<Vec<u8>, String> {
    let range = match to {
        Some(t) => format!("bytes={from}-{t}"),
        None => format!("bytes={from}-"),
    };
    let mut wait = 20;
    for attempt in 0..8 {
        match agent.get(url).set("User-Agent", ua).set("Range", &range).call() {
            Ok(resp) => {
                if resp.status() != 206 {
                    return Err(format!("the dumps server did not honour the Range request (status {})", resp.status()));
                }
                let mut buf = Vec::new();
                resp.into_reader().take(64 << 20).read_to_end(&mut buf).map_err(|e| e.to_string())?;
                return Ok(buf);
            }
            Err(ureq::Error::Status(429, _)) | Err(ureq::Error::Status(503, _)) => {
                eprintln!("  rate limited, waiting {wait}s (attempt {attempt})");
                std::thread::sleep(Duration::from_secs(wait));
                wait = (wait * 2).min(300);
            }
            Err(e) => return Err(format!("range request {range}: {e}")),
        }
    }
    Err("the dumps server kept refusing the range request".into())
}

/// What an article's stream gave.
#[derive(Debug, Clone, PartialEq)]
enum Outcome {
    Summary(String),
    /// The title is a redirect to this one.
    Redirect(String),
    /// The article has no readable lead paragraph.
    Empty,
    /// The title is not in the dump (index or stream).
    Missing,
}

/// The enwiki dump date in a dump file's URL or name ("20261001" in ".../enwiki-20261001-pages-articles-multistream.xml.bz2").
fn dump_date(s: &str) -> Option<String> {
    let at = s.rfind("enwiki-")? + "enwiki-".len();
    let d: String = s[at..].chars().take_while(|c| c.is_ascii_digit()).collect();
    (d.len() == 8).then_some(d)
}

/// wiki-cache.sqlite: what each article gave, by (dump date, title). Offsets and texts only hold within one dump, so a new
/// dump date starts empty.
struct WikiCache {
    conn: Connection,
    dump: String,
}

const WIKI_CACHE_SQL: &str = "PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL;
CREATE TABLE IF NOT EXISTS articles (dump TEXT NOT NULL, title TEXT NOT NULL, outcome TEXT NOT NULL, text TEXT, PRIMARY KEY (dump, title)) WITHOUT ROWID;";

impl WikiCache {
    fn open(path: &PathBuf, dump: String) -> Result<WikiCache, String> {
        let conn = Connection::open(path).map_err(|e| format!("{}: {e}", path.display()))?;
        conn.execute_batch(WIKI_CACHE_SQL).map_err(|e| e.to_string())?;
        Ok(WikiCache { conn, dump })
    }

    fn get(&self, title: &str) -> Option<Outcome> {
        let (kind, text): (String, Option<String>) = self
            .conn
            .query_row("SELECT outcome, text FROM articles WHERE dump = ?1 AND title = ?2", params![self.dump, title], |r| Ok((r.get(0)?, r.get(1)?)))
            .ok()?;
        Some(match kind.as_str() {
            "summary" => Outcome::Summary(text?),
            "redirect" => Outcome::Redirect(text?),
            "empty" => Outcome::Empty,
            _ => Outcome::Missing,
        })
    }

    fn put(&self, title: &str, o: &Outcome) -> Result<(), String> {
        let (kind, text) = match o {
            Outcome::Summary(s) => ("summary", Some(s.as_str())),
            Outcome::Redirect(t) => ("redirect", Some(t.as_str())),
            Outcome::Empty => ("empty", None),
            Outcome::Missing => ("missing", None),
        };
        self.conn
            .execute("INSERT OR REPLACE INTO articles(dump, title, outcome, text) VALUES (?1, ?2, ?3, ?4)", params![self.dump, title, kind, text])
            .map_err(|e| e.to_string())?;
        Ok(())
    }
}

/// What one title's page in a decompressed stream gives.
fn read_page(xml: &str, title: &str) -> Outcome {
    let needle = format!("<title>{}</title>", xml_escape(title));
    let Some(p) = xml.find(&needle) else { return Outcome::Missing };
    let page = &xml[p..xml[p..].find("</page>").map(|e| p + e).unwrap_or(xml.len())];
    let Some(ts_start) = page.find("<text") else { return Outcome::Empty };
    let Some(gt) = page[ts_start..].find('>') else { return Outcome::Empty };
    let body = &page[ts_start + gt + 1..];
    let body = &body[..body.find("</text>").unwrap_or(body.len())];
    let text = xml_unescape(body);
    if text.trim_start().to_uppercase().starts_with("#REDIRECT") {
        let target = match (text.find("[["), text.find("]]")) {
            (Some(a), Some(b)) if a < b => text[a + 2..b].split('#').next().unwrap_or("").trim().to_string(),
            _ => String::new(),
        };
        return Outcome::Redirect(target);
    }
    match lead_paragraph(&text) {
        Some(s) => Outcome::Summary(s),
        None => Outcome::Empty,
    }
}

fn fetch_summaries(o: &Opts, titles: &BTreeSet<String>) -> Result<(HashMap<String, String>, Vec<String>), String> {
    let cache = match &o.cache {
        Some(p) => Some(WikiCache::open(p, dump_date(&o.xml_url).ok_or_else(|| format!("no enwiki dump date in {}", o.xml_url))?)?),
        None => None,
    };
    let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(120)).build();
    let mut got: HashMap<String, Outcome> = HashMap::new();
    let (mut from_cache, mut streams) = (0usize, 0usize);
    let mut todo: BTreeSet<String> = titles.clone();
    for round in 0..2 {
        if todo.is_empty() {
            break;
        }
        let mut fetch: BTreeSet<String> = BTreeSet::new();
        for t in &todo {
            match cache.as_ref().and_then(|c| c.get(t)) {
                Some(oc) => {
                    from_cache += 1;
                    got.insert(t.clone(), oc);
                }
                None => {
                    fetch.insert(t.clone());
                }
            }
        }
        if !fetch.is_empty() {
            let (found, offsets) = scan_index(&o.index, &fetch)?;
            let mut by_off: std::collections::BTreeMap<u64, Vec<String>> = Default::default();
            for t in &fetch {
                match found.get(t) {
                    Some(off) => by_off.entry(*off).or_default().push(t.clone()),
                    None => {
                        if let Some(c) = &cache {
                            c.put(t, &Outcome::Missing)?;
                        }
                        got.insert(t.clone(), Outcome::Missing);
                    }
                }
            }
            let n = by_off.len();
            eprintln!("  {} articles to fetch in {n} streams ({} from the cache)", fetch.len(), todo.len() - fetch.len());
            for (i, (off, ts)) in by_off.iter().enumerate() {
                let end = offsets.range(off + 1..).next().map(|e| e - 1);
                let bytes = get_range(&agent, &o.xml_url, &o.user_agent, *off, end)?;
                streams += 1;
                let mut xml = String::new();
                bzip2::read::BzDecoder::new(&bytes[..]).read_to_string(&mut xml).map_err(|e| format!("stream at {off}: {e}"))?;
                for t in ts {
                    let oc = read_page(&xml, t);
                    if let Some(c) = &cache {
                        c.put(t, &oc)?;
                    }
                    got.insert(t.clone(), oc);
                }
                if i % 100 == 0 {
                    eprintln!("  stream {}/{n}", i + 1);
                }
                std::thread::sleep(Duration::from_millis(400));
            }
        }
        // Redirects are followed once: their targets are the next round.
        let mut next = BTreeSet::new();
        if round == 0 {
            for t in &todo {
                if let Some(Outcome::Redirect(target)) = got.get(t) {
                    if !target.is_empty() && !got.contains_key(target) {
                        next.insert(target.clone());
                    }
                }
            }
        }
        todo = next;
    }
    let mut out: HashMap<String, String> = HashMap::new();
    let (mut redirects, mut empty, mut missing) = (0usize, 0usize, 0usize);
    for t in titles {
        match got.get(t) {
            Some(Outcome::Summary(s)) => {
                out.insert(t.clone(), s.clone());
            }
            Some(Outcome::Redirect(target)) => {
                redirects += 1;
                // The redirect's summary is its target's.
                if let Some(Outcome::Summary(s)) = got.get(target) {
                    out.insert(t.clone(), s.clone());
                }
            }
            Some(Outcome::Empty) => empty += 1,
            Some(Outcome::Missing) | None => missing += 1,
        }
    }
    let notes = vec![format!(
        "summaries: {} of {} articles ({redirects} redirects, {empty} with no readable lead, {missing} not in the dump); {from_cache} answered from the cache, {streams} streams fetched",
        out.len(),
        titles.len()
    )];
    Ok((out, notes))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn title_bases() {
        assert_eq!(title_base("Burley, Idaho"), "Burley");
        assert_eq!(title_base("Mercury (planet)"), "Mercury");
        assert_eq!(title_base("Cassia Regional Hospital"), "Cassia Regional Hospital");
        assert_eq!(norm(title_base("St. Luke's, Boise")), "stlukes");
    }

    #[test]
    fn pages_and_the_cache() {
        let xml = "<page><title>Burley, Idaho</title><text bytes=\"9\">'''Burley''' is a city in [[Cassia County, Idaho]]. It is the county seat.</text></page>\
                   <page><title>Burley ID</title><text>#REDIRECT [[Burley, Idaho#History]]</text></page><page><title>Stub</title><text>{{Infobox}}</text></page>";
        assert!(matches!(read_page(xml, "Burley, Idaho"), Outcome::Summary(s) if s.starts_with("Burley is a city in Cassia County, Idaho.")));
        assert_eq!(read_page(xml, "Burley ID"), Outcome::Redirect("Burley, Idaho".into()));
        assert_eq!(read_page(xml, "Stub"), Outcome::Empty);
        assert_eq!(read_page(xml, "Nowhere"), Outcome::Missing);
        assert_eq!(dump_date("https://dumps.wikimedia.org/enwiki/20261001/enwiki-20261001-pages-articles-multistream.xml.bz2").as_deref(), Some("20261001"));
        assert_eq!(dump_date("enwiki-latest-x"), None);

        let dir = std::env::temp_dir().join(format!("pp-wiki-cache-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("wiki-cache.sqlite");
        let _ = std::fs::remove_file(&p);
        let c = WikiCache::open(&p, "20261001".into()).unwrap();
        c.put("Burley ID", &Outcome::Redirect("Burley, Idaho".into())).unwrap();
        c.put("Stub", &Outcome::Empty).unwrap();
        c.put("A", &Outcome::Summary("A is a place.".into())).unwrap();
        drop(c);
        let c = WikiCache::open(&p, "20261001".into()).unwrap();
        assert_eq!(c.get("Burley ID"), Some(Outcome::Redirect("Burley, Idaho".into())));
        assert_eq!(c.get("Stub"), Some(Outcome::Empty));
        assert_eq!(c.get("A"), Some(Outcome::Summary("A is a place.".into())));
        assert_eq!(c.get("B"), None);
        let other = WikiCache::open(&p, "20261101".into()).unwrap();
        assert_eq!(other.get("A"), None, "another dump starts empty");
        drop((c, other));
        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn xml_entities() {
        assert_eq!(xml_escape("AT&T <x>"), "AT&amp;T &lt;x&gt;");
        assert_eq!(xml_unescape("AT&amp;T &lt;x&gt; &quot;q&quot;"), "AT&T <x> \"q\"");
    }
}
