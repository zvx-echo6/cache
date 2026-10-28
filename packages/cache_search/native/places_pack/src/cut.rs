//! `places_pack cut`: the blocks and the street rows written out as published level 1 tiles (`cache_places::schema::
//! TILE_SQL`, docs/PLACES-TILES.md): `<out>/<build>/1/aaa/bbb.sqlite.gz`, one per tile of the blocks' cells that holds any
//! place, town or house number, and `<out>/<build>/index.tsv` (path, bytes, sha256 of the unpacked file, gzip bytes, as the
//! routing index has them; sorted).
//!
//! Each tile carries its places and towns (local ids from 1, in the block's order), the cities, towns and villages outside
//! its cell within 25 km (`localities_ctx`, from every block, so a town across a block edge is there too), its street rows,
//! the vectors of its notable places and towns when the block was embedded, and its tile_counts.

use crate::blocks::{block_files, tiles_in};
use cache_places::geo::haversine_km;
use cache_places::schema::{tile_id_l1, tile_path_l1, tile_rect_l1, MAX_LOCAL_ID, TILE_SCHEMA, TILE_SQL};
use flate2::write::GzEncoder;
use flate2::Compression;
use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, Connection, OpenFlags};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

/// Context towns are those within this distance of the cell.
pub const CTX_KM: f64 = 25.0;

pub struct CutCfg {
    pub blocks: PathBuf,
    pub addresses: Option<PathBuf>,
    pub out: PathBuf,
    pub build: String,
    /// Only the tiles overlapping this box (None: every tile of the blocks).
    pub bbox: Option<[f64; 4]>,
    pub jobs: usize,
}

/// One written tile.
#[derive(Debug, Clone)]
pub struct TileOut {
    pub tile: u32,
    pub path: String,
    pub bytes: u64,
    pub sha256: String,
    pub gz_bytes: u64,
    pub places: i64,
    pub localities: i64,
    pub localities_ctx: i64,
    pub streets: i64,
    pub addresses: i64,
}

/// A town of some block, for `localities_ctx`.
struct Town {
    name: String,
    kind: String,
    lat: f64,
    lon: f64,
    population: Option<i64>,
    state: Option<String>,
    country: Option<String>,
    source_id: String,
}

/// Every city, town and village of every block, by level 1 tile.
struct Towns {
    by_tile: HashMap<u32, Vec<Town>>,
}

impl Towns {
    fn load(blocks: &[(u32, PathBuf)]) -> Result<Towns, String> {
        let mut by_tile: HashMap<u32, Vec<Town>> = HashMap::new();
        for (_, p) in blocks {
            let c = open(p)?;
            let mut st = c
                .prepare("SELECT name, kind, lat, lon, population, state, country, source_id FROM localities WHERE kind <> 'hamlet' ORDER BY id")
                .map_err(|e| e.to_string())?;
            let rows = st
                .query_map([], |r| {
                    Ok(Town { name: r.get(0)?, kind: r.get(1)?, lat: r.get(2)?, lon: r.get(3)?, population: r.get(4)?, state: r.get(5)?, country: r.get(6)?, source_id: r.get(7)? })
                })
                .map_err(|e| e.to_string())?;
            for t in rows {
                let t = t.map_err(|e| e.to_string())?;
                by_tile.entry(tile_id_l1(t.lat, t.lon)).or_default().push(t);
            }
        }
        Ok(Towns { by_tile })
    }

    /// The towns outside `tile`'s cell within `CTX_KM` of it (they can only be in the eight cells around it).
    fn context(&self, tile: u32) -> Vec<&Town> {
        let cell = tile_rect_l1(tile);
        let (row, col) = ((tile / 360) as i64, (tile % 360) as i64);
        let mut out = Vec::new();
        for dr in -1..=1 {
            for dc in -1..=1 {
                let (r, c) = (row + dr, (col + dc).rem_euclid(360));
                if (dr, dc) == (0, 0) || !(0..180).contains(&r) {
                    continue;
                }
                for t in self.by_tile.get(&((r * 360 + c) as u32)).into_iter().flatten() {
                    let d = haversine_km(t.lat, t.lon, t.lat.clamp(cell[1], cell[3]), t.lon.clamp(cell[0], cell[2]));
                    if d <= CTX_KM {
                        out.push(t);
                    }
                }
            }
        }
        out
    }
}

fn open(p: &Path) -> Result<Connection, String> {
    Connection::open_with_flags(p, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| format!("{}: {e}", p.display()))
}

const PLACE_COLS: &str = "name, alt_names, category, kind, kind_id, lat, lon, street, locality, county, state, country, phone, hours, website, \
                          wikidata_id, wikipedia_title, wikivoyage_title, summary, brand_wikidata, matched_source_id, source, source_id, confidence";
const LOCALITY_COLS: &str = "name, alt_names, kind, lat, lon, population, county, state, country, wikidata_id, wikipedia_title, wikivoyage_title, summary, source_id";
const ADDR_COLS: &str = "uid, street, street_expanded, locality, postal_city, postcode, state, country, lat, lon, min_lat, max_lat, min_lon, max_lon, n, numbers";

/// A block's rows, by tile: (block row id, the columns of the tile's table in order).
type Rows = BTreeMap<u32, Vec<(i64, Vec<Value>)>>;

fn read_rows(c: &Connection, sql: &str, lat_col: usize, lon_col: usize) -> Result<Rows, String> {
    let mut st = c.prepare(sql).map_err(|e| e.to_string())?;
    let n = st.column_count();
    let mut rows = st.query([]).map_err(|e| e.to_string())?;
    let mut out: Rows = BTreeMap::new();
    while let Some(r) = rows.next().map_err(|e| e.to_string())? {
        let id: i64 = r.get(0).map_err(|e| e.to_string())?;
        let v: Vec<Value> = (1..n).map(|i| r.get::<_, Value>(i)).collect::<Result<_, _>>().map_err(|e| e.to_string())?;
        let num = |i: usize| match v[i] {
            Value::Real(x) => x,
            Value::Integer(x) => x as f64,
            _ => f64::NAN,
        };
        out.entry(tile_id_l1(num(lat_col), num(lon_col))).or_default().push((id, v));
    }
    Ok(out)
}

/// The block's place and town vectors: (kind, block row id) -> vec.
fn read_vectors(c: &Connection) -> Result<HashMap<(String, i64), Vec<u8>>, String> {
    let has = c.query_row("SELECT COUNT(*) FROM sqlite_master WHERE name = 'vectors'", [], |r| r.get::<_, i64>(0)).map_err(|e| e.to_string())? > 0;
    let mut out = HashMap::new();
    if !has {
        return Ok(out);
    }
    let mut st = c.prepare("SELECT kind, ref, vec FROM vectors WHERE kind IN ('place', 'locality')").map_err(|e| e.to_string())?;
    let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, Vec<u8>>(2)?))).map_err(|e| e.to_string())?;
    for r in rows {
        let (k, re, v) = r.map_err(|e| e.to_string())?;
        if let Ok(id) = re.parse::<i64>() {
            out.insert((k, id), v);
        }
    }
    Ok(out)
}

fn placeholders(n: usize) -> String {
    (1..=n).map(|i| format!("?{i}")).collect::<Vec<_>>().join(", ")
}

struct TileInput<'a> {
    tile: u32,
    places: &'a [(i64, Vec<Value>)],
    localities: &'a [(i64, Vec<Value>)],
    vectors: &'a HashMap<(String, i64), Vec<u8>>,
}

fn write_tile(cfg: &CutCfg, t: TileInput, towns: &Towns, addr: Option<&Connection>) -> Result<Option<TileOut>, String> {
    let tile = t.tile;
    let path = tile_path_l1(tile);
    let dir = cfg.out.join(&cfg.build);
    let raw = dir.join(format!("{path}.sqlite"));
    if let Some(p) = raw.parent() {
        std::fs::create_dir_all(p).map_err(|e| format!("{}: {e}", p.display()))?;
    }
    let _ = std::fs::remove_file(&raw);
    let mut c = Connection::open(&raw).map_err(|e| format!("{}: {e}", raw.display()))?;
    c.execute_batch("PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF;").map_err(|e| e.to_string())?;
    c.execute_batch(TILE_SQL).map_err(|e| e.to_string())?;
    let tx = c.transaction().map_err(|e| e.to_string())?;
    let mut counts: BTreeMap<(&str, String), i64> = BTreeMap::new();
    let (mut n_places, mut n_towns, mut n_ctx, mut n_streets, mut n_numbers) = (0i64, 0i64, 0i64, 0i64, 0i64);
    {
        let mut ins = tx.prepare(&format!("INSERT INTO places(id, {PLACE_COLS}) VALUES ({})", placeholders(25))).map_err(|e| e.to_string())?;
        for (block_id, v) in t.places {
            n_places += 1;
            let mut vals = vec![Value::Integer(n_places)];
            vals.extend(v.iter().cloned());
            ins.execute(params_from_iter(vals)).map_err(|e| e.to_string())?;
            if let Value::Text(cat) = &v[2] {
                *counts.entry(("category", cat.clone())).or_default() += 1;
            }
            if let Value::Text(k) = &v[4] {
                *counts.entry(("kind", k.clone())).or_default() += 1;
            }
            if let Some(vec) = t.vectors.get(&("place".to_string(), *block_id)) {
                tx.execute("INSERT INTO vectors(kind, ref, vec) VALUES ('place', ?1, ?2)", params![n_places, vec]).map_err(|e| e.to_string())?;
            }
        }
        let mut ins = tx.prepare(&format!("INSERT INTO localities(id, {LOCALITY_COLS}) VALUES ({})", placeholders(15))).map_err(|e| e.to_string())?;
        for (block_id, v) in t.localities {
            n_towns += 1;
            let mut vals = vec![Value::Integer(n_towns)];
            vals.extend(v.iter().cloned());
            ins.execute(params_from_iter(vals)).map_err(|e| e.to_string())?;
            if let Some(vec) = t.vectors.get(&("locality".to_string(), *block_id)) {
                tx.execute("INSERT INTO vectors(kind, ref, vec) VALUES ('locality', ?1, ?2)", params![n_towns, vec]).map_err(|e| e.to_string())?;
            }
        }
        for town in towns.context(tile) {
            n_ctx += 1;
            tx.execute(
                "INSERT INTO localities_ctx(id, name, kind, lat, lon, population, state, country, source_id) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
                params![n_ctx, town.name, town.kind, town.lat, town.lon, town.population, town.state, town.country, town.source_id],
            )
            .map_err(|e| e.to_string())?;
        }
        if let Some(a) = addr {
            let mut st = a.prepare(&format!("SELECT {ADDR_COLS} FROM addr_streets WHERE tile = ?1 ORDER BY rowid")).map_err(|e| e.to_string())?;
            let mut rows = st.query([tile]).map_err(|e| e.to_string())?;
            let mut ins = tx.prepare(&format!("INSERT INTO addr_streets(id, {ADDR_COLS}) VALUES ({})", placeholders(17))).map_err(|e| e.to_string())?;
            while let Some(r) = rows.next().map_err(|e| e.to_string())? {
                n_streets += 1;
                let mut vals = vec![Value::Integer(n_streets)];
                for i in 0..16 {
                    vals.push(r.get::<_, Value>(i).map_err(|e| e.to_string())?);
                }
                if let Value::Integer(n) = vals[15] {
                    n_numbers += n;
                }
                ins.execute(params_from_iter(vals)).map_err(|e| e.to_string())?;
            }
        }
    }
    if n_places + n_towns + n_streets == 0 {
        drop(tx);
        drop(c);
        let _ = std::fs::remove_file(&raw);
        return Ok(None);
    }
    if [n_places, n_towns, n_ctx, n_streets].iter().any(|n| *n > MAX_LOCAL_ID) {
        return Err(format!("tile {path} has more rows than local ids allow"));
    }
    for ((what, id), n) in &counts {
        tx.execute("INSERT INTO tile_counts(what, id, n) VALUES (?1, ?2, ?3)", params![what, id, n]).map_err(|e| e.to_string())?;
    }
    let summary = serde_json::json!({"places": n_places, "localities": n_towns, "localities_ctx": n_ctx, "addr_streets": n_streets, "addresses": n_numbers});
    for (k, v) in [
        ("tile_schema", TILE_SCHEMA.to_string()),
        ("build", cfg.build.clone()),
        ("tile", tile.to_string()),
        ("path", path.clone()),
        ("counts", summary.to_string()),
    ] {
        tx.execute("INSERT INTO meta(key, value) VALUES (?1, ?2)", params![k, v]).map_err(|e| e.to_string())?;
    }
    tx.commit().map_err(|e| e.to_string())?;
    c.execute_batch("VACUUM;").map_err(|e| e.to_string())?;
    drop(c);

    let bytes = std::fs::read(&raw).map_err(|e| format!("{}: {e}", raw.display()))?;
    let sha256: String = Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
    let gz = dir.join(format!("{path}.sqlite.gz"));
    let tmp = dir.join(format!("{path}.sqlite.gz.part"));
    let mut enc = GzEncoder::new(std::fs::File::create(&tmp).map_err(|e| format!("{}: {e}", tmp.display()))?, Compression::best());
    enc.write_all(&bytes).map_err(|e| e.to_string())?;
    enc.finish().map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, &gz).map_err(|e| e.to_string())?;
    let _ = std::fs::remove_file(&raw);
    let gz_bytes = std::fs::metadata(&gz).map_err(|e| e.to_string())?.len();
    Ok(Some(TileOut {
        tile,
        path,
        bytes: bytes.len() as u64,
        sha256,
        gz_bytes,
        places: n_places,
        localities: n_towns,
        localities_ctx: n_ctx,
        streets: n_streets,
        addresses: n_numbers,
    }))
}

fn cut_block(cfg: &CutCfg, path: &Path, towns: &Towns, addr: Option<&Connection>, selected: &Option<BTreeSet<u32>>) -> Result<(Vec<TileOut>, BTreeSet<u32>), String> {
    let c = open(path)?;
    let cells: Vec<u32> = c
        .query_row("SELECT value FROM meta WHERE key = 'cells'", [], |r| r.get::<_, String>(0))
        .map_err(|e| format!("{}: no cells in meta ({e})", path.display()))
        .and_then(|s| serde_json::from_str(&s).map_err(|e| e.to_string()))?;
    let places = read_rows(
        &c,
        "SELECT p.id, p.name, NULLIF(f.alt_names, ''), p.category, p.kind, p.kind_id, p.lat, p.lon, p.street, p.locality, p.county, p.state, p.country, p.phone, p.hours, \
         p.website, p.wikidata_id, p.wikipedia_title, p.wikivoyage_title, p.summary, p.brand_wikidata, p.matched_source_id, p.source, p.source_id, p.confidence \
         FROM places p LEFT JOIN places_fts f ON f.rowid = p.id ORDER BY p.id",
        5,
        6,
    )?;
    let localities = read_rows(
        &c,
        "SELECT l.id, l.name, NULLIF(f.alt_names, ''), l.kind, l.lat, l.lon, l.population, l.county, l.state, l.country, l.wikidata_id, l.wikipedia_title, \
         l.wikivoyage_title, l.summary, l.source_id FROM localities l LEFT JOIN localities_fts f ON f.rowid = l.id ORDER BY l.id",
        3,
        4,
    )?;
    let vectors = read_vectors(&c)?;
    let mut out = Vec::new();
    let mut done = BTreeSet::new();
    for tile in cells {
        if selected.as_ref().is_some_and(|s| !s.contains(&tile)) {
            continue;
        }
        let empty = Vec::new();
        let input = TileInput { tile, places: places.get(&tile).unwrap_or(&empty), localities: localities.get(&tile).unwrap_or(&empty), vectors: &vectors };
        done.insert(tile);
        if let Some(t) = write_tile(cfg, input, towns, addr)? {
            out.push(t);
        }
    }
    Ok((out, done))
}

/// Writes every tile and the index. Returns the tiles written, in path order.
pub fn cut(cfg: &CutCfg) -> Result<Vec<TileOut>, String> {
    let blocks = block_files(&cfg.blocks)?;
    let towns = Towns::load(&blocks)?;
    let selected = cfg.bbox.map(tiles_in);
    std::fs::create_dir_all(cfg.out.join(&cfg.build)).map_err(|e| e.to_string())?;
    let next = AtomicUsize::new(0);
    let results: Mutex<Vec<Result<(Vec<TileOut>, BTreeSet<u32>), String>>> = Mutex::new(Vec::new());
    std::thread::scope(|sc| {
        for _ in 0..cfg.jobs.clamp(1, blocks.len().max(1)) {
            sc.spawn(|| {
                let addr = match cfg.addresses.as_deref().map(open).transpose() {
                    Ok(a) => a,
                    Err(e) => {
                        results.lock().unwrap().push(Err(e));
                        return;
                    }
                };
                loop {
                    let i = next.fetch_add(1, Ordering::SeqCst);
                    let Some((b, p)) = blocks.get(i) else { return };
                    let r = cut_block(cfg, p, &towns, addr.as_ref(), &selected).map_err(|e| format!("block {b}: {e}"));
                    results.lock().unwrap().push(r);
                }
            });
        }
    });
    let mut tiles = Vec::new();
    let mut covered = BTreeSet::new();
    for r in results.into_inner().unwrap() {
        let (t, d) = r?;
        tiles.extend(t);
        covered.extend(d);
    }
    // Tiles with house numbers but no block (no place or town anywhere in their block).
    if let Some(a) = cfg.addresses.as_deref() {
        let a = open(a)?;
        let mut st = a.prepare("SELECT DISTINCT tile FROM addr_streets ORDER BY tile").map_err(|e| e.to_string())?;
        let extra: Vec<u32> = st
            .query_map([], |r| r.get::<_, u32>(0))
            .map_err(|e| e.to_string())?
            .filter_map(|t| t.ok())
            .filter(|t| !covered.contains(t) && selected.as_ref().is_none_or(|s| s.contains(t)))
            .collect();
        let none = HashMap::new();
        for tile in extra {
            if let Some(t) = write_tile(cfg, TileInput { tile, places: &[], localities: &[], vectors: &none }, &towns, Some(&a))? {
                tiles.push(t);
            }
        }
    }
    tiles.sort_by(|a, b| a.path.cmp(&b.path));
    let mut index = String::new();
    for t in &tiles {
        index.push_str(&format!("{}\t{}\t{}\t{}\n", t.path, t.bytes, t.sha256, t.gz_bytes));
    }
    let ip = cfg.out.join(&cfg.build).join("index.tsv");
    std::fs::write(&ip, index).map_err(|e| format!("{}: {e}", ip.display()))?;
    Ok(tiles)
}
