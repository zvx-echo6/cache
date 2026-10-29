//! offroad_pack: build and inspect cache_offroad region packs (offroad.sqlite), from navi's data (`build`) or
//! from the original public sources the cache-packs `offroad-region` recipe prepares (`build-sources`).
//! Pure Rust (no GDAL): PMTiles + Terrarium WebP, GeoTIFF mosaics, SQLite tables.
mod pmw;
mod raster;
mod sources;
mod wkb;

use cache_offroad::grid::{self, GridMeta, PACK_TILE};
use cache_offroad::pmtiles;
use cache_offroad::pack::*;
use rayon::prelude::*;
use rusqlite::{params, Connection, OpenFlags};
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc;
use std::time::Instant;

const N_PIX: f64 = 2_097_152.0; // 2^21 pixels around the world at z12 (512 px tiles)

fn merc_lat(y: f64) -> f64 {
    (std::f64::consts::PI * (1.0 - 2.0 * y / N_PIX)).sinh().atan().to_degrees()
}
fn merc_lon(x: f64) -> f64 {
    x / N_PIX * 360.0 - 180.0
}

struct Args(HashMap<String, String>);
impl Args {
    fn parse(v: &[String]) -> Args {
        let mut m = HashMap::new();
        let mut i = 0;
        while i < v.len() {
            if let Some(k) = v[i].strip_prefix("--") {
                if i + 1 < v.len() && !v[i + 1].starts_with("--") {
                    m.insert(k.to_string(), v[i + 1].clone());
                    i += 2;
                    continue;
                }
                m.insert(k.to_string(), "true".into());
            }
            i += 1;
        }
        Args(m)
    }
    fn get(&self, k: &str) -> Result<&str, String> {
        self.0.get(k).map(|s| s.as_str()).ok_or_else(|| format!("missing --{k}"))
    }
    fn opt(&self, k: &str) -> Option<&str> {
        self.0.get(k).map(|s| s.as_str())
    }
}

fn parse_bbox(s: &str) -> Result<(f64, f64, f64, f64), String> {
    let v: Vec<f64> = s.split(',').map(|x| x.trim().parse().map_err(|_| format!("bad bbox {s}"))).collect::<Result<_, _>>()?;
    if v.len() != 4 {
        return Err("bbox is south,north,west,east".into());
    }
    Ok((v[0], v[1], v[2], v[3]))
}

fn main() {
    let argv: Vec<String> = std::env::args().skip(1).collect();
    let cmd = argv.first().cloned().unwrap_or_default();
    let args = Args::parse(&argv[argv.len().min(1)..]);
    let r = match cmd.as_str() {
        "build" => build(&args),
        "build-sources" => build_sources(&args),
        "inspect" => inspect(&args),
        "resample-check" => resample_check(&args),
        "raster-info" => raster_info(&args),
        "elevation-extract" => elevation_extract(&args),
        "directions" => directions_cmd(&args),
        "raster-window" => raster_window(&args),
        "route" => route_cmd(&args),
        "probe" => probe_cmd(&args),
        _ => Err("usage: offroad_pack <build|build-sources|inspect|route|directions|probe|resample-check|raster-info|raster-window|elevation-extract> [--key value ...]".into()),
    };
    if let Err(e) = r {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}

// ---- build ------------------------------------------------------------------------------------------

struct Layers {
    friction: Friction,
    class: Option<raster::Mosaic>,
    trails: raster::Mosaic,
    barriers: raster::Mosaic,
    wilderness: Option<raster::Mosaic>,
}

fn file_version(p: &Path) -> String {
    match std::fs::metadata(p) {
        Ok(m) => {
            let t = m.modified().ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map_or(0, |d| d.as_secs());
            format!("{}|{}|{}", p.file_name().map_or(String::new(), |s| s.to_string_lossy().into()), m.len(), t)
        }
        Err(_) => "missing".into(),
    }
}

fn dir_version(d: &Path) -> String {
    let mut v: Vec<String> = std::fs::read_dir(d)
        .map(|rd| rd.filter_map(|e| e.ok()).filter(|e| e.path().extension().map_or(false, |x| x == "tif")).map(|e| file_version(&e.path())).collect())
        .unwrap_or_default();
    v.sort();
    v.join(";")
}

/// Where the friction layer comes from: navi's friction mosaic, or the class layer through the recovered
/// class -> friction table (the two are identical cell for cell; see cache-packs rules/offroad/class_friction.tsv).
enum Friction {
    Mosaic(raster::Mosaic),
    FromClass(sources::ClassFriction),
}

/// Result of processing one DEM tile: pack-tile blobs.
struct TileOut {
    rows: Vec<(&'static str, i64, i64, Vec<u8>)>,
}

fn process_tile(pm: &pmtiles::PmTiles, layers: &Layers, tx: i64, ty: i64, level: i32) -> Result<Option<TileOut>, String> {
    let Some(bytes) = pm.get(12, tx as u64, ty as u64) else { return Ok(None) };
    let _ = bytes; // presence only: the tile defines the region this pack covers
    let mut rows: Vec<(&'static str, i64, i64, Vec<u8>)> = Vec::new();
    let sub = PACK_TILE as usize;
    // cell centres of this DEM tile
    let lons: Vec<f64> = (0..512).map(|j| merc_lon((tx * 512 + j) as f64 + 0.5)).collect();
    let lats: Vec<f64> = (0..512).map(|i| merc_lat((ty * 512 + i) as f64 + 0.5)).collect();
    let (west, east, north, south) = (lons[0], lons[511], lats[0], lats[511]);
    let sample = |m: &raster::Mosaic| -> Result<Option<Vec<u8>>, String> {
        let patch = m.patch(west, east, south, north)?;
        let mut cells = vec![0u8; 512 * 512];
        let mut any = false;
        for i in 0..512 {
            for j in 0..512 {
                let v = patch.sample(lons[j], lats[i]);
                cells[i * 512 + j] = v;
                any |= v != 0;
            }
        }
        Ok(if any { Some(cells) } else { None })
    };
    let mut emit = |name: &'static str, cells: &[u8]| {
        for sy in 0..2usize {
            for sx in 0..2usize {
                let mut t = vec![0u8; sub * sub];
                for r in 0..sub {
                    t[r * sub..(r + 1) * sub].copy_from_slice(&cells[(sy * sub + r) * 512 + sx * sub..(sy * sub + r) * 512 + sx * sub + sub]);
                }
                if t.iter().any(|&v| v != 0) {
                    rows.push((name, tx * 2 + sx as i64, ty * 2 + sy as i64, encode_u8_tile(&t, level)));
                }
            }
        }
    };
    let class = match &layers.class {
        Some(c) => sample(c)?,
        None => None,
    };
    match &layers.friction {
        Friction::Mosaic(m) => {
            if let Some(f) = sample(m)? {
                emit("friction", &f);
            }
        }
        Friction::FromClass(t) => {
            if let Some(c) = &class {
                emit("friction", &t.apply(c));
            }
        }
    }
    if let Some(c) = &class {
        emit("class", c);
    }
    if let Some(v) = sample(&layers.trails)? {
        emit("trails", &v);
    }
    if let Some(v) = sample(&layers.barriers)? {
        emit("barriers", &v);
    }
    if let Some(w) = &layers.wilderness {
        if let Some(v) = sample(w)? {
            emit("wilderness", &v);
        }
    }
    Ok(Some(TileOut { rows }))
}

fn in_bbox(lat: f64, lon: f64, b: (f64, f64, f64, f64)) -> bool {
    lat >= b.0 && lat <= b.1 && lon >= b.2 && lon <= b.3
}

fn build(a: &Args) -> Result<(), String> {
    let t0 = Instant::now();
    let out = PathBuf::from(a.get("out")?);
    let bbox = parse_bbox(a.get("bbox")?)?;
    let level: i32 = a.opt("zstd-level").map_or(Ok(12), |s| s.parse().map_err(|_| "bad --zstd-level".to_string()))?;
    let limit: usize = a.opt("limit-tiles").map_or(Ok(usize::MAX), |s| s.parse().map_err(|_| "bad --limit-tiles".to_string()))?;
    if let Some(t) = a.opt("threads") {
        rayon::ThreadPoolBuilder::new().num_threads(t.parse().map_err(|_| "bad --threads")?).build_global().ok();
    }
    let dem = PathBuf::from(a.get("coverage-pmtiles")?);
    let fr_dir = PathBuf::from(a.get("friction-dir")?);
    let class_dir = a.opt("class-dir").map(PathBuf::from);
    let trails = PathBuf::from(a.get("trails")?);
    let barriers = PathBuf::from(a.get("barriers")?);
    let wild = a.opt("wilderness").map(PathBuf::from);
    let navi_db = PathBuf::from(a.get("navi-db")?);
    let parking_db = PathBuf::from(a.get("parking-db")?);

    let layers = Layers {
        friction: Friction::Mosaic(raster::Mosaic::open_dir(&fr_dir)?),
        class: match &class_dir {
            Some(d) => Some(raster::Mosaic::open_dir(d)?),
            None => None,
        },
        trails: raster::Mosaic::open_files(&[trails.clone()])?,
        barriers: raster::Mosaic::open_files(&[barriers.clone()])?,
        wilderness: match &wild {
            Some(w) => Some(raster::Mosaic::open_files(&[w.clone()])?),
            None => None,
        },
    };
    let pm = pmtiles::PmTiles::open(&dem)?;
    let (south, north, west, east) = bbox;
    let (conn, written) = write_tiles(&pm, &layers, bbox, &out, level, limit, t0)?;

    // point data
    let (n_park, n_th, n_mvum) = write_points(&conn, &navi_db, &parking_db, bbox)?;
    eprintln!("parking {n_park}, trailheads {n_th}, mvum {n_mvum}");

    let mut layer_names = vec!["friction", "trails", "barriers"];
    if class_dir.is_some() {
        layer_names.insert(1, "class");
    }
    if wild.is_some() {
        layer_names.push("wilderness");
    }
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let meta: Vec<(&str, String)> = vec![
        ("format_version", FORMAT_VERSION.into()),
        ("grid", "web-mercator z12 pixel grid; tile=256 cells; origin top-left of the world; row = ty*256+r, col = tx*256+c".into()),
        ("grid_zoom", "12".into()),
                ("pack_tile_size", "256".into()),
        ("cell_sampling", "nearest at the true web-mercator centre of each z12 pixel".into()),
        ("elevation", "external: Mapterhorn-format PMTiles (z12, 512 px Terrarium WebP), see cache_offroad::elevation".into()),
        ("u8_codec", "zstd(raw 65536 bytes)".into()),
        ("zstd_level", level.to_string()),
        ("bbox_south", south.to_string()),
        ("bbox_north", north.to_string()),
        ("bbox_west", west.to_string()),
        ("bbox_east", east.to_string()),
        ("layers", layer_names.join(",")),
        ("mode_profile_hash", cache_offroad::cost::mode_profile_hash()),
        ("build_unix_time", secs.to_string()),
        ("source_tiles", written.to_string()),
        ("src_coverage_pmtiles", file_version(&dem)),
        ("src_friction", dir_version(&fr_dir)),
        ("src_class", class_dir.as_ref().map_or("none".into(), |d| dir_version(d))),
        ("src_trails", file_version(&trails)),
        ("src_barriers", file_version(&barriers)),
        ("src_wilderness", wild.as_ref().map_or("none".into(), |w| file_version(w))),
        ("src_navi_db", file_version(&navi_db)),
        ("src_parking_db", file_version(&parking_db)),
        ("rows_parking", n_park.to_string()),
        ("rows_trailheads", n_th.to_string()),
        ("rows_mvum", n_mvum.to_string()),
    ];
    for (k, v) in meta {
        conn.execute("INSERT INTO meta VALUES (?1, ?2)", params![k, v]).map_err(|e| e.to_string())?;
    }
    drop(conn);
    eprintln!("built {} in {:.0}s", out.display(), t0.elapsed().as_secs_f64());
    inspect_path(&out)
}

/// `build-sources`: the same pack (format 2) from the original public sources, as prepared by the cache-packs
/// `offroad-region` recipe: WorldCover class tiles (friction comes from class through `--class-friction`), the
/// recipe's trails / barriers / wilderness rasters, point TSVs and the MVUM GeoJSON-seq. `--coverage-pmtiles` is
/// the region's elevation extract; its z12 tiles define the cells the pack covers.
fn build_sources(a: &Args) -> Result<(), String> {
    let t0 = Instant::now();
    let out = PathBuf::from(a.get("out")?);
    let bbox = parse_bbox(a.get("bbox")?)?;
    let level: i32 = a.opt("zstd-level").map_or(Ok(12), |s| s.parse().map_err(|_| "bad --zstd-level".to_string()))?;
    let limit: usize = a.opt("limit-tiles").map_or(Ok(usize::MAX), |s| s.parse().map_err(|_| "bad --limit-tiles".to_string()))?;
    if let Some(t) = a.opt("threads") {
        rayon::ThreadPoolBuilder::new().num_threads(t.parse().map_err(|_| "bad --threads")?).build_global().ok();
    }
    let dem = PathBuf::from(a.get("coverage-pmtiles")?);
    let class_dir = PathBuf::from(a.get("class-dir")?);
    let table_path = PathBuf::from(a.get("class-friction")?);
    let trails = PathBuf::from(a.get("trails")?);
    let barriers = PathBuf::from(a.get("barriers")?);
    let wild = PathBuf::from(a.get("wilderness")?);
    let parking = PathBuf::from(a.get("parking")?);
    let entry = PathBuf::from(a.get("entry-points")?);
    let mvum = PathBuf::from(a.get("mvum")?);

    let table = sources::ClassFriction::load(&table_path)?;
    let layers = Layers {
        friction: Friction::FromClass(table.clone()),
        class: Some(raster::Mosaic::open_dir(&class_dir)?),
        trails: raster::Mosaic::open_files(&[trails.clone()])?,
        barriers: raster::Mosaic::open_files(&[barriers.clone()])?,
        wilderness: Some(raster::Mosaic::open_files(&[wild.clone()])?),
    };
    let pm = pmtiles::PmTiles::open(&dem)?;
    let (south, north, west, east) = bbox;
    let (conn, written) = write_tiles(&pm, &layers, bbox, &out, level, limit, t0)?;
    eprintln!("tiles done in {:.0}s", t0.elapsed().as_secs_f64());

    let (n_park, n_th, n_mvum) = write_points_sources(&conn, &parking, &entry, &mvum, bbox)?;
    eprintln!("parking {n_park}, trailheads {n_th}, mvum {n_mvum}");

    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let meta: Vec<(&str, String)> = vec![
        ("format_version", FORMAT_VERSION.into()),
        ("grid", "web-mercator z12 pixel grid; tile=256 cells; origin top-left of the world; row = ty*256+r, col = tx*256+c".into()),
        ("grid_zoom", "12".into()),
        ("pack_tile_size", "256".into()),
        ("cell_sampling", "nearest at the true web-mercator centre of each z12 pixel".into()),
        ("elevation", "external: Mapterhorn PMTiles area extract (z12, 512 px lossless Terrarium WebP), see cache_offroad::elevation".into()),
        ("u8_codec", "zstd(raw 65536 bytes)".into()),
        ("zstd_level", level.to_string()),
        ("bbox_south", south.to_string()),
        ("bbox_north", north.to_string()),
        ("bbox_west", west.to_string()),
        ("bbox_east", east.to_string()),
        ("layers", "friction,class,trails,barriers,wilderness".into()),
        ("mode_profile_hash", cache_offroad::cost::mode_profile_hash()),
        ("build_unix_time", secs.to_string()),
        ("built_from", "original sources (cache-packs recipe offroad-region)".into()),
        ("source_tiles", written.to_string()),
        ("friction_rule", "friction = class_friction[class]".into()),
        ("class_friction_sha256", table.sha256.clone()),
        ("src_coverage_pmtiles", file_version(&dem)),
        ("src_class", dir_version(&class_dir)),
        ("src_trails", file_version(&trails)),
        ("src_barriers", file_version(&barriers)),
        ("src_wilderness", file_version(&wild)),
        ("src_parking", file_version(&parking)),
        ("src_entry_points", file_version(&entry)),
        ("src_mvum", file_version(&mvum)),
        ("rows_parking", n_park.to_string()),
        ("rows_trailheads", n_th.to_string()),
        ("rows_mvum", n_mvum.to_string()),
    ];
    for (k, v) in meta {
        conn.execute("INSERT INTO meta VALUES (?1, ?2)", params![k, v]).map_err(|e| e.to_string())?;
    }
    drop(conn);
    eprintln!("built {} in {:.0}s", out.display(), t0.elapsed().as_secs_f64());
    inspect_path(&out)
}

/// Point tables and MVUM from the recipe's files. Blocked parking (private, no, permit) is dropped here as in
/// `write_points`, so a TSV that still carries it builds the same pack.
fn write_points_sources(conn: &Connection, parking: &Path, entry: &Path, mvum: &Path, bbox: (f64, f64, f64, f64)) -> Result<(i64, i64, i64), String> {
    let e = |x: rusqlite::Error| x.to_string();
    conn.execute_batch("BEGIN").map_err(e)?;
    let mut ins = conn.prepare("INSERT INTO parking(lat, lon, name, parking_type, access) VALUES (?1,?2,?3,?4,?5)").map_err(e)?;
    let mut ins_i = conn.prepare("INSERT INTO parking_idx VALUES (?1,?2,?2,?3,?3)").map_err(e)?;
    let mut n_park = 0;
    for (lat, lon, name, kind, access) in sources::read_points_tsv(parking)? {
        if matches!(access.as_str(), "private" | "no" | "permit") || !in_bbox(lat, lon, bbox) {
            continue;
        }
        ins.execute(params![lat, lon, name, kind, access]).map_err(e)?;
        ins_i.execute(params![conn.last_insert_rowid(), lon, lat]).map_err(e)?;
        n_park += 1;
    }
    let mut ins = conn.prepare("INSERT INTO trailheads(lat, lon, name, highway_class) VALUES (?1,?2,?3,?4)").map_err(e)?;
    let mut ins_i = conn.prepare("INSERT INTO trailheads_idx VALUES (?1,?2,?2,?3,?3)").map_err(e)?;
    let mut n_th = 0;
    for (lat, lon, name, kind, _) in sources::read_points_tsv(entry)? {
        if !in_bbox(lat, lon, bbox) {
            continue;
        }
        ins.execute(params![lat, lon, name, kind]).map_err(e)?;
        ins_i.execute(params![conn.last_insert_rowid(), lon, lat]).map_err(e)?;
        n_th += 1;
    }
    let mut ins = conn
        .prepare("INSERT INTO mvum(is_trail, symbol, seasonal, maint, mtb_status, mtb_dates, atv_status, atv_dates, veh_status, veh_dates, geom) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)")
        .map_err(e)?;
    let mut ins_i = conn.prepare("INSERT INTO mvum_idx VALUES (?1,?2,?3,?4,?5)").map_err(e)?;
    let mut n_mvum = 0;
    for m in sources::read_mvum(mvum)? {
        let (x0, x1, y0, y1) = sources::lines_bbox(&m.lines);
        if x1 < bbox.2 || x0 > bbox.3 || y1 < bbox.0 || y0 > bbox.1 {
            continue;
        }
        let [(ms, md), (as_, ad), (vs, vd)] = &m.access;
        ins.execute(params![m.is_trail as i64, m.symbol, m.seasonal, m.maint, ms, md, as_, ad, vs, vd, encode_lines(&m.lines)]).map_err(e)?;
        ins_i.execute(params![conn.last_insert_rowid(), x0, x1, y0, y1]).map_err(e)?;
        n_mvum += 1;
    }
    drop(ins);
    drop(ins_i);
    conn.execute_batch("COMMIT").map_err(e)?;
    Ok((n_park, n_th, n_mvum))
}

/// Opens a new pack at `out` with the schema and writes the u8 layer tiles of every DEM tile of `pm` inside
/// `bbox`, in parallel. Returns the open connection and the number of DEM tiles processed.
fn write_tiles(pm: &pmtiles::PmTiles, layers: &Layers, bbox: (f64, f64, f64, f64), out: &Path, level: i32, limit: usize, t0: Instant) -> Result<(Connection, usize), String> {
    let (south, north, west, east) = bbox;
    let (x0, y1) = grid::lat_lon_to_tile(south, west, 12);
    let (x1, y0) = grid::lat_lon_to_tile(north, east, 12);
    let mut tiles: Vec<(i64, i64)> = Vec::new();
    for ty in y0..=y1 {
        for tx in x0..=x1 {
            if pm.get(12, tx as u64, ty as u64).is_some() {
                tiles.push((tx, ty));
            }
        }
    }
    tiles.truncate(limit);
    eprintln!("{} DEM tiles in bbox ({} in file), writing {}", tiles.len(), pm.tile_count(), out.display());

    if out.exists() {
        std::fs::remove_file(&out).map_err(|e| e.to_string())?;
    }
    if let Some(p) = out.parent() {
        std::fs::create_dir_all(p).map_err(|e| e.to_string())?;
    }
    let conn = Connection::open(&out).map_err(|e| e.to_string())?;
    conn.execute_batch("PRAGMA page_size=16384; PRAGMA journal_mode=OFF; PRAGMA synchronous=OFF;").map_err(|e| e.to_string())?;
    conn.execute_batch(SCHEMA).map_err(|e| e.to_string())?;

    // tiles: workers -> channel -> this thread
    let (tx_ch, rx_ch) = mpsc::sync_channel::<Result<TileOut, String>>(64);
    let tiles_ref = &tiles;
    let pm_ref = pm;
    let layers_ref = layers;
    let total = tiles.len();
    let mut written = 0usize;
    let mut err: Option<String> = None;
    std::thread::scope(|sc| {
        sc.spawn(move || {
            tiles_ref.par_iter().for_each_with(tx_ch, |tx_ch, &(tx, ty)| match process_tile(pm_ref, layers_ref, tx, ty, level) {
                Ok(Some(o)) => {
                    let _ = tx_ch.send(Ok(o));
                }
                Ok(None) => {}
                Err(e) => {
                    let _ = tx_ch.send(Err(e));
                }
            });
        });
        conn.execute_batch("BEGIN").unwrap();
        let mut st = conn.prepare("INSERT OR REPLACE INTO tiles(layer, tx, ty, data) VALUES (?1,?2,?3,?4)").unwrap();
        let mut last = Instant::now();
        for r in rx_ch {
            match r {
                Ok(o) => {
                    for (layer, tx, ty, blob) in o.rows {
                        st.execute(params![layer, tx, ty, blob]).unwrap();
                    }
                    written += 1;
                    if last.elapsed().as_secs() >= 20 {
                        eprintln!("  {written}/{total} DEM tiles ({:.0}s)", t0.elapsed().as_secs_f64());
                        last = Instant::now();
                    }
                }
                Err(e) => {
                    err = Some(e);
                    break;
                }
            }
        }
        drop(st);
        conn.execute_batch("COMMIT").unwrap();
    });
    if let Some(e) = err {
        return Err(e);
    }
    eprintln!("tiles done: {written} DEM tiles in {:.0}s", t0.elapsed().as_secs_f64());
    Ok((conn, written))
}

fn write_points(conn: &Connection, navi_db: &Path, parking_db: &Path, bbox: (f64, f64, f64, f64)) -> Result<(i64, i64, i64), String> {
    let e = |x: rusqlite::Error| x.to_string();
    conn.execute_batch("BEGIN").map_err(e)?;
    // parking (blocked access dropped, like navi's index)
    let pk = Connection::open_with_flags(parking_db, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(e)?;
    let mut st = pk.prepare("SELECT name, access, parking_type, lat, lon FROM parking WHERE lat IS NOT NULL AND lon IS NOT NULL").map_err(e)?;
    let mut rows = st.query([]).map_err(e)?;
    let mut ins = conn.prepare("INSERT INTO parking(lat, lon, name, parking_type, access) VALUES (?1,?2,?3,?4,?5)").map_err(e)?;
    let mut ins_i = conn.prepare("INSERT INTO parking_idx VALUES (?1,?2,?2,?3,?3)").map_err(e)?;
    let mut n_park = 0;
    while let Some(r) = rows.next().map_err(e)? {
        let access: Option<String> = r.get(1).map_err(e)?;
        if matches!(access.as_deref(), Some("private") | Some("no") | Some("permit")) {
            continue;
        }
        let (lat, lon): (f64, f64) = (r.get(3).map_err(e)?, r.get(4).map_err(e)?);
        if !in_bbox(lat, lon, bbox) {
            continue;
        }
        let name: Option<String> = r.get(0).map_err(e)?;
        let pt: Option<String> = r.get(2).map_err(e)?;
        ins.execute(params![lat, lon, name.unwrap_or_default(), pt.unwrap_or_default(), access.unwrap_or_default()]).map_err(e)?;
        ins_i.execute(params![conn.last_insert_rowid(), lon, lat]).map_err(e)?;
        n_park += 1;
    }
    drop(rows);
    drop(st);
    // trailheads
    let nv = Connection::open_with_flags(navi_db, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(e)?;
    let mut st = nv.prepare("SELECT lat, lon, name, highway_class FROM trail_entry_points WHERE lat IS NOT NULL AND lon IS NOT NULL").map_err(e)?;
    let mut rows = st.query([]).map_err(e)?;
    let mut ins = conn.prepare("INSERT INTO trailheads(lat, lon, name, highway_class) VALUES (?1,?2,?3,?4)").map_err(e)?;
    let mut ins_i = conn.prepare("INSERT INTO trailheads_idx VALUES (?1,?2,?2,?3,?3)").map_err(e)?;
    let mut n_th = 0;
    while let Some(r) = rows.next().map_err(e)? {
        let (lat, lon): (f64, f64) = (r.get(0).map_err(e)?, r.get(1).map_err(e)?);
        if !in_bbox(lat, lon, bbox) {
            continue;
        }
        let name: Option<String> = r.get(2).map_err(e)?;
        let hc: Option<String> = r.get(3).map_err(e)?;
        ins.execute(params![lat, lon, name.unwrap_or_default(), hc.unwrap_or_default()]).map_err(e)?;
        ins_i.execute(params![conn.last_insert_rowid(), lon, lat]).map_err(e)?;
        n_th += 1;
    }
    drop(rows);
    drop(st);
    // MVUM roads + trails (every feature with a parseable geometry that touches the bbox)
    let mut ins = conn
        .prepare("INSERT INTO mvum(is_trail, symbol, seasonal, maint, mtb_status, mtb_dates, atv_status, atv_dates, veh_status, veh_dates, geom) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)")
        .map_err(e)?;
    let mut ins_i = conn.prepare("INSERT INTO mvum_idx VALUES (?1,?2,?3,?4,?5)").map_err(e)?;
    let mut n_mvum = 0;
    for (table, is_trail, maint_col) in [("mvum_roads", 0i64, "operationalmaintlevel"), ("mvum_trails", 1i64, "NULL")] {
        let sql = format!(
            "SELECT symbol, seasonal, {maint_col}, e_bike_class1, e_bike_class1_dur, atv, atv_datesopen, highclearancevehicle, highclearancevehicle_datesopen, shape FROM {table} WHERE shape IS NOT NULL"
        );
        let mut st = nv.prepare(&sql).map_err(e)?;
        let mut rows = st.query([]).map_err(e)?;
        while let Some(r) = rows.next().map_err(e)? {
            let shape: Vec<u8> = r.get(9).map_err(e)?;
            let Some(lines) = wkb::parse_lines(&shape) else { continue };
            let (mut x0, mut x1, mut y0, mut y1) = (f64::MAX, f64::MIN, f64::MAX, f64::MIN);
            for l in &lines {
                for &(x, y) in l {
                    x0 = x0.min(x);
                    x1 = x1.max(x);
                    y0 = y0.min(y);
                    y1 = y1.max(y);
                }
            }
            if lines.iter().all(|l| l.is_empty()) || x1 < bbox.2 || x0 > bbox.3 || y1 < bbox.0 || y0 > bbox.1 {
                continue;
            }
            let g = |i: usize| -> Result<Option<String>, String> { r.get(i).map_err(|x| x.to_string()) };
            ins.execute(params![is_trail, g(0)?, g(1)?, g(2)?, g(3)?, g(4)?, g(5)?, g(6)?, g(7)?, g(8)?, encode_lines(&lines)]).map_err(e)?;
            ins_i.execute(params![conn.last_insert_rowid(), x0, x1, y0, y1]).map_err(e)?;
            n_mvum += 1;
        }
    }
    drop(ins);
    drop(ins_i);
    conn.execute_batch("COMMIT").map_err(e)?;
    Ok((n_park, n_th, n_mvum))
}

// ---- inspect ------------------------------------------------------------------------------------------

fn inspect(a: &Args) -> Result<(), String> {
    inspect_path(Path::new(a.get("pack")?))
}

fn inspect_path(p: &Path) -> Result<(), String> {
    let conn = Connection::open_with_flags(p, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| e.to_string())?;
    let e = |x: rusqlite::Error| x.to_string();
    println!("pack: {}  file size: {:.1} MB", p.display(), std::fs::metadata(p).map_err(|e| e.to_string())?.len() as f64 / 1e6);
    let mut st = conn.prepare("SELECT key, value FROM meta ORDER BY key").map_err(e)?;
    for r in st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))).map_err(e)? {
        let (k, v) = r.map_err(e)?;
        println!("  meta {k} = {v}");
    }
    let mut st = conn.prepare("SELECT layer, count(*), sum(length(data)), max(length(data)) FROM tiles GROUP BY layer ORDER BY layer").map_err(e)?;
    let mut total = 0i64;
    println!("  {:<12}{:>10}{:>16}{:>14}{:>12}", "layer", "tiles", "bytes", "MB", "avg B/tile");
    for r in st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)?, r.get::<_, i64>(2)?))).map_err(e)? {
        let (l, n, b) = r.map_err(e)?;
        total += b;
        println!("  {:<12}{:>10}{:>16}{:>14.1}{:>12}", l, n, b, b as f64 / 1e6, b / n.max(1));
    }
    println!("  tile payload total {:.1} MB", total as f64 / 1e6);
    for t in ["parking", "trailheads", "mvum"] {
        let n: i64 = conn.query_row(&format!("SELECT count(*) FROM {t}"), [], |r| r.get(0)).map_err(e)?;
        let bytes: i64 = if t == "mvum" {
            conn.query_row("SELECT coalesce(sum(length(geom)),0) FROM mvum", [], |r| r.get(0)).map_err(e)?
        } else {
            0
        };
        println!("  table {t}: {n} rows{}", if bytes > 0 { format!(", geometry {:.1} MB", bytes as f64 / 1e6) } else { String::new() });
    }
    Ok(())
}

// ---- raster-info / codec-bench / resample-check -----------------------------------------------------------

fn raster_info(a: &Args) -> Result<(), String> {
    for p in a.get("files")?.split(';') {
        let i = raster::tiff_info(Path::new(p))?;
        println!("{}: {}x{} origin ({}, {}) px ({}, {}) chunk {}x{} extent lon {:.4}..{:.4} lat {:.4}..{:.4}", p, i.width, i.height, i.x0, i.y0, i.dx, i.dy, i.chunk_w, i.chunk_h,
            i.x0, i.x0 + i.dx * i.width as f64, i.y0 - i.dy * i.height as f64, i.y0);
    }
    Ok(())
}

/// Compare navi's per-query resample (rasterio window read onto the DEM-shaped grid) with the pack's one-time
/// global-grid resample, for a bbox, per layer.
fn resample_check(a: &Args) -> Result<(), String> {
    let (south, north, west, east) = parse_bbox(a.get("bbox")?)?;
    let meta = GridMeta::from_bbox(south, north, west, east);
    println!("query grid {}x{} cells, cell {:.2} m, global origin ({}, {})", meta.rows, meta.cols, meta.cell_size_m, meta.global_row0, meta.global_col0);
    let mut layers: Vec<(&str, raster::Mosaic)> = Vec::new();
    layers.push(("friction", raster::Mosaic::open_dir(Path::new(a.get("friction-dir")?))?));
    if let Some(c) = a.opt("class-dir") {
        layers.push(("class", raster::Mosaic::open_dir(Path::new(c))?));
    }
    layers.push(("trails", raster::Mosaic::open_files(&[PathBuf::from(a.get("trails")?)])?));
    layers.push(("barriers", raster::Mosaic::open_files(&[PathBuf::from(a.get("barriers")?)])?));
    if let Some(w) = a.opt("wilderness") {
        layers.push(("wilderness", raster::Mosaic::open_files(&[PathBuf::from(w)])?));
    }
    let (rows, cols) = (meta.rows, meta.cols);
    // pack-style cell centres (true web-mercator) and the lon/lat extent
    let plons: Vec<f64> = (0..cols).map(|j| merc_lon((meta.global_col0 + j as i64) as f64 + 0.5)).collect();
    let plats: Vec<f64> = (0..rows).map(|i| merc_lat((meta.global_row0 + i as i64) as f64 + 0.5)).collect();
    for (name, m) in &layers {
        let patch = m.patch(west - 0.01, east + 0.01, south - 0.01, north + 0.01)?;
        let f = &m.files[0];
        // rasterio.windows.from_bounds(west, south, east, north, transform) on the first file's geotransform:
        let col_off = (west - f.x0) / f.dx;
        let row_off = (f.y0 - north) / f.dy;
        let width = (east - west) / f.dx;
        let height = (north - south) / f.dy;
        // GDAL nearest at a fractional window: src = floor(off + (i + 0.5) * size / out)
        let nav_lon = |j: usize| f.x0 + (col_off + (j as f64 + 0.5) * width / cols as f64) * f.dx;
        let nav_lat = |i: usize| f.y0 - (row_off + (i as f64 + 0.5) * height / rows as f64) * f.dy;
        let mut diff = 0u64;
        let mut max_shift_cells = 0f64;
        let mut nz = 0u64;
        for i in 0..rows {
            let (la_p, la_n) = (plats[i], nav_lat(i));
            for j in 0..cols {
                let p = patch.sample(plons[j], la_p);
                let n = patch.sample(nav_lon(j), la_n);
                if p != 0 || n != 0 {
                    nz += 1;
                }
                if p != n {
                    diff += 1;
                }
            }
        }
        // geometric offset between the two sampling positions at the worst cell
        for &(i, j) in &[(0usize, 0usize), (rows / 2, cols / 2), (rows - 1, cols - 1), (rows / 2, 0), (0, cols / 2)] {
            let dlat = (plats[i] - nav_lat(i)).abs() / meta.pixel_size_lat.abs();
            let dlon = (plons[j] - nav_lon(j)).abs() / meta.pixel_size_lon.abs();
            max_shift_cells = max_shift_cells.max(dlat).max(dlon);
        }
        println!("  {:<11} differing cells {:>10} of {:>10} ({:.3}% of all, {:.3}% of non-empty); sampled-position offset up to {:.2} cells", name, diff,
            rows as u64 * cols as u64, 100.0 * diff as f64 / (rows as f64 * cols as f64), 100.0 * diff as f64 / nz.max(1) as f64, max_shift_cells);
    }
    Ok(())
}

/// Dump a raw u8 window of a GeoTIFF (for checking the reader against GDAL).
fn raster_window(a: &Args) -> Result<(), String> {
    let info = raster::tiff_info(Path::new(a.get("file")?))?;
    let g = |k: &str| -> Result<i64, String> { a.get(k)?.parse().map_err(|_| format!("bad --{k}")) };
    let (x0, y0, w, h) = (g("x0")?, g("y0")?, g("w")? as usize, g("h")? as usize);
    let data = raster::read_window(&info, x0, y0, w, h)?;
    std::fs::write(a.get("out")?, data).map_err(|e| e.to_string())
}

fn parse_ll(s: &str) -> Result<(f64, f64), String> {
    let v: Vec<f64> = s.split(',').map(|x| x.trim().parse().map_err(|_| format!("bad lat,lon {s}"))).collect::<Result<_, _>>()?;
    if v.len() != 2 {
        return Err(format!("bad lat,lon {s}"));
    }
    Ok((v[0], v[1]))
}

fn parse_modes(s: &str) -> Result<Vec<cache_offroad::Mode>, String> {
    s.split(',').filter(|x| !x.is_empty()).map(|x| cache_offroad::Mode::from_name(x.trim()).ok_or(format!("bad mode {x}"))).collect()
}

/// Run one route on a pack (parity harness / manual check). Valhalla is the phase-2 stub.
fn route_cmd(a: &Args) -> Result<(), String> {
    use cache_offroad::{Boundary, RequestMode, RouteOptions, RouteRequest};
    let (pack, elev, valhalla) = open_env(a)?;
    let start = parse_ll(a.get("start")?)?;
    let end = parse_ll(a.get("end")?)?;
    let mode = match a.opt("mode").unwrap_or("auto") {
        "auto" => RequestMode::Auto,
        m => RequestMode::Single(cache_offroad::Mode::from_name(m).ok_or("bad --mode")?),
    };
    let boundary = Boundary::from_name(a.opt("boundary").unwrap_or("pragmatic")).ok_or("bad --boundary")?;
    let mut req = RouteRequest::new(start, end, mode, boundary);
    if let Some(s) = a.opt("start-modes") {
        req.start_modes = Some(parse_modes(s)?);
    }
    if let Some(s) = a.opt("end-modes") {
        req.end_modes = Some(parse_modes(s)?);
    }
    req.start_category = a.opt("start-category").map(String::from);
    req.end_category = a.opt("end-category").map(String::from);
    if let Some(s) = a.opt("affinity") {
        let mut h = HashMap::new();
        for kv in s.split(',') {
            let (k, v) = kv.split_once('=').ok_or("bad --affinity")?;
            h.insert(cache_offroad::Mode::from_name(k).ok_or("bad affinity mode")?, v.parse::<f64>().map_err(|_| "bad affinity value")?);
        }
        req.network_affinity = Some(h);
    }
    let mut opts = RouteOptions::default();
    if let Some(m) = a.opt("max-cells") {
        opts.max_cells = m.parse().map_err(|_| "bad --max-cells")?;
    }
    let t = Instant::now();
    // Diagnostic: --navi-layers re-samples the u8 layers from the source rasters the way navi does per query
    // (window onto the requested bbox, nearest, scaled to the DEM-shaped grid), to measure how much of a
    // parity difference is layer alignment.
    let over;
    let res = if a.opt("navi-layers").is_some() {
        let (south, north, west, east) = cache_offroad::router::auto_bbox(start, end, opts.bbox_pad_deg, opts.bbox_max_span_deg);
        let meta = GridMeta::from_bbox(south, north, west, east);
        let mk = |m: raster::Mosaic| -> Result<Vec<u8>, String> {
            let patch = m.patch(west - 0.01, east + 0.01, south - 0.01, north + 0.01)?;
            let (rows, cols) = (meta.rows, meta.cols);
            let lons: Vec<f64> = (0..cols).map(|j| west + (j as f64 + 0.5) * (east - west) / cols as f64).collect();
            let mut out = vec![0u8; rows * cols];
            for i in 0..rows {
                let lat = north - (i as f64 + 0.5) * (north - south) / rows as f64;
                for j in 0..cols {
                    out[i * cols + j] = patch.sample(lons[j], lat);
                }
            }
            Ok(out)
        };
        let mut layers = HashMap::new();
        layers.insert(Layer::Friction, mk(raster::Mosaic::open_dir(Path::new(a.get("friction-dir")?))?)?);
        layers.insert(Layer::Class, mk(raster::Mosaic::open_dir(Path::new(a.get("class-dir")?))?)?);
        layers.insert(Layer::Trails, mk(raster::Mosaic::open_files(&[PathBuf::from(a.get("trails")?)])?)?);
        layers.insert(Layer::Barriers, mk(raster::Mosaic::open_files(&[PathBuf::from(a.get("barriers")?)])?)?);
        layers.insert(Layer::Wilderness, mk(raster::Mosaic::open_files(&[PathBuf::from(a.get("wilderness")?)])?)?);
        over = OverridePack { inner: &pack, row0: meta.global_row0, col0: meta.global_col0, rows: meta.rows, cols: meta.cols, layers };
        cache_offroad::route(&over, &elev, &*valhalla, &req, &opts)
    } else {
        cache_offroad::route(&pack, &elev, &*valhalla, &req, &opts)
    };
    match res {
        Ok(r) => {
            println!(
                "ok effort_min={:.4} distance_km={:.4} modes={} cells={} grid={}x{} trans_cells={} expanded={} ms[rasters={} layers={} trans={} search={}] total_ms={}",
                r.total_effort_minutes, r.total_distance_km, r.selected_mode_set.join("+"), r.cells.len(), r.stats.rows, r.stats.cols,
                r.stats.transition_cells, r.stats.expanded_states, r.stats.ms_rasters, r.stats.ms_layers, r.stats.ms_transitions,
                r.stats.ms_search, t.elapsed().as_millis()
            );
            for tr in &r.transitions {
                println!("  transition {} -> {} at {:.5},{:.5}", tr.from_mode.name(), tr.to_mode.name(), tr.lat, tr.lon);
            }
            for sg in &r.segments {
                let m: f64 = sg.coords.windows(2).map(|w| grid::haversine_m(w[0].1, w[0].0, w[1].1, w[1].0)).sum();
                println!("  segment {} {:.0} m", sg.mode.name(), m);
            }
            if let Some(o) = a.opt("json") {
                std::fs::write(o, r.to_json().to_string()).map_err(|e| e.to_string())?;
            }
            Ok(())
        }
        Err(e) => Err(format!("{e}")),
    }
}

/// Describe the pack around a point: layer values and nearby road/track/trail, wilderness, barrier cells.
fn probe_cmd(a: &Args) -> Result<(), String> {
    let (pack, elev_src, _v) = open_env(a)?;
    use cache_offroad::ElevationSource;
    let (lat, lon) = parse_ll(a.get("at")?)?;
    let rad: i64 = a.opt("radius").map_or(Ok(150), |s| s.parse().map_err(|_| "bad --radius".to_string()))?;
    let (gr, gc) = grid::global_pixel(lat, lon).ok_or("out of range")?;
    let (r0, c0, n) = (gr - rad, gc - rad, (2 * rad + 1) as usize);
    let e = elev_src.read_elevation(r0, c0, n, n).map_err(|e| e.to_string())?;
    let rd = |l: Layer| pack.read_u8(l, r0, c0, n, n).map_err(|e| e.to_string());
    let (tr, wi, ba, cl, fr) = (rd(Layer::Trails)?, rd(Layer::Wilderness)?, rd(Layer::Barriers)?, rd(Layer::Class)?, rd(Layer::Friction)?);
    let ctr = (rad as usize) * n + rad as usize;
    println!("{lat},{lon}: elev {:.1} m  class {} friction {} trail {} wilderness {} barrier {}", e[ctr], cl[ctr], fr[ctr], tr[ctr], wi[ctr], ba[ctr]);
    let near = |pred: &dyn Fn(usize) -> bool| -> Option<(f64, usize)> {
        let mut best: Option<(f64, usize)> = None;
        for i in 0..n * n {
            if pred(i) {
                let (dr, dc) = ((i / n) as f64 - rad as f64, (i % n) as f64 - rad as f64);
                let d = (dr * dr + dc * dc).sqrt();
                if best.map_or(true, |b| d < b.0) {
                    best = Some((d, i));
                }
            }
        }
        best
    };
    let cell_m = 13.5;
    for (name, v) in [("road(5)", 5u8), ("track(15)", 15), ("foot trail(25)", 25)] {
        match near(&|i| tr[i] == v) {
            Some((d, _)) => println!("  nearest {name}: {:.0} m", d * cell_m),
            None => println!("  nearest {name}: none within {} m", (rad as f64 * cell_m) as i64),
        }
    }
    // nearest "solid" road/track/trail cell (all cells within 2 cells share the value): a robust endpoint
    for (name, v) in [("road", 5u8), ("track", 15), ("trail", 25)] {
        let mut best: Option<(f64, usize)> = None;
        for r in 2..n - 2 {
            for c in 2..n - 2 {
                let i = r * n + c;
                if tr[i] != v || !e[i].is_finite() {
                    continue;
                }
                let mut solid = true;
                'o: for dr in -2i64..=2 {
                    for dc in -2i64..=2 {
                        if tr[((r as i64 + dr) as usize) * n + (c as i64 + dc) as usize] != v {
                            solid = false;
                            break 'o;
                        }
                    }
                }
                if solid {
                    let (dr, dc) = (r as f64 - rad as f64, c as f64 - rad as f64);
                    let d = (dr * dr + dc * dc).sqrt();
                    if best.map_or(true, |b| d < b.0) {
                        best = Some((d, i));
                    }
                }
            }
        }
        if let Some((d, i)) = best {
            let (rr, cc) = (r0 + (i / n) as i64, c0 + (i % n) as i64);
            println!("  solid {name} cell at {:.5},{:.5} ({:.0} m away, elev {:.0})", merc_lat(rr as f64 + 0.5), merc_lon(cc as f64 + 0.5), d * cell_m, e[i]);
        }
    }
    if a.opt("map").is_some() {
        let step = (n / 70).max(1);
        for r in (0..n).step_by(step * 2) {
            let mut line = String::new();
            for c in (0..n).step_by(step) {
                let mut ch = '.';
                'blk: for rr in r..(r + step * 2).min(n) {
                    for cc in c..(c + step).min(n) {
                        let i = rr * n + cc;
                        let t = tr[i];
                        if t == 5 { ch = 'R'; break 'blk; }
                        if t == 15 { ch = 'T'; }
                        if t == 25 && ch != 'T' { ch = 't'; }
                        if ch == '.' && ba[i] == 255 { ch = 'B'; }
                        if ch == '.' && wi[i] == 255 { ch = 'W'; }
                    }
                }
                line.push(ch);
            }
            println!("  {line}");
        }
    }
    println!("  wilderness cells {} / barrier cells {} / nan elev {}", wi.iter().filter(|&&v| v == 255).count(), ba.iter().filter(|&&v| v == 255).count(), e.iter().filter(|v| v.is_nan()).count());
    let mut cc = [0usize; 256];
    for &v in &cl { cc[v as usize] += 1; }
    println!("  classes: {:?}", cc.iter().enumerate().filter(|(_, &c)| c > 0).map(|(k, c)| format!("{k}:{c}")).collect::<Vec<_>>());
    Ok(())
}

/// Pack wrapper that serves pre-sampled u8 layers for exactly one window (diagnostic only).
struct OverridePack<'a> {
    inner: &'a SqlitePack,
    row0: i64,
    col0: i64,
    rows: usize,
    cols: usize,
    layers: HashMap<Layer, Vec<u8>>,
}
impl PackSource for OverridePack<'_> {
    fn has_layer(&self, l: Layer) -> bool {
        self.layers.contains_key(&l) || self.inner.has_layer(l)
    }
    fn read_u8(&self, l: Layer, r0: i64, c0: i64, rows: usize, cols: usize) -> PResult<Vec<u8>> {
        if let Some(v) = self.layers.get(&l) {
            if (r0, c0, rows, cols) == (self.row0, self.col0, self.rows, self.cols) {
                return Ok(v.clone());
            }
        }
        self.inner.read_u8(l, r0, c0, rows, cols)
    }
    fn parking_in_box(&self, a: f64, b: f64, c: f64, d: f64) -> PResult<Vec<PointRec>> {
        self.inner.parking_in_box(a, b, c, d)
    }
    fn trailheads_in_box(&self, a: f64, b: f64, c: f64, d: f64) -> PResult<Vec<PointRec>> {
        self.inner.trailheads_in_box(a, b, c, d)
    }
    fn mvum_in_box(&self, s: f64, n: f64, w: f64, e: f64) -> PResult<Vec<MvumFeature>> {
        self.inner.mvum_in_box(s, n, w, e)
    }
}

/// Cut the tiles of a Mapterhorn-format PMTiles file (z12, 512 px Terrarium WebP) that touch a bbox into a
/// new PMTiles file, bytes unchanged. For tests the source is navi's copy of the DEM; in the app the same
/// file comes from range reads of Mapterhorn's planet.pmtiles.
fn elevation_extract(a: &Args) -> Result<(), String> {
    let src = pmtiles::PmTiles::open(Path::new(a.get("src")?))?;
    let (south, north, west, east) = parse_bbox(a.get("bbox")?)?;
    let (x0, y1) = grid::lat_lon_to_tile(south, west, 12);
    let (x1, y0) = grid::lat_lon_to_tile(north, east, 12);
    let mut tiles = Vec::new();
    for ty in y0..=y1 {
        for tx in x0..=x1 {
            if let Some(b) = src.get(12, tx as u64, ty as u64) {
                tiles.push((pmtiles::zxy_to_tile_id(12, tx as u64, ty as u64), b.to_vec()));
            }
        }
    }
    if tiles.is_empty() {
        return Err("no tiles in bbox".into());
    }
    let e7 = |v: f64| (v * 1e7).round() as i32;
    let n = tiles.len();
    let meta = format!(
        "{{\"name\":\"elevation\",\"format\":\"webp\",\"encoding\":\"terrarium\",\"tile_size\":512,\"minzoom\":12,\"maxzoom\":12,\"description\":\"{} tiles cut from {}\"}}",
        n, a.get("src")?.replace('\\', "/")
    );
    let bytes = pmw::build(tiles, 12, [e7(west), e7(south), e7(east), e7(north)], &meta);
    std::fs::write(a.get("out")?, &bytes).map_err(|e| e.to_string())?;
    eprintln!("wrote {} tiles, {:.1} MB", n, bytes.len() as f64 / 1e6);
    Ok(())
}

fn open_env(a: &Args) -> Result<(SqlitePack, cache_offroad::PmtilesElevation, Box<dyn cache_offroad::Valhalla>), String> {
    let pack = SqlitePack::open(Path::new(a.get("pack")?)).map_err(|e| e.to_string())?;
    let elev = cache_offroad::PmtilesElevation::open(Path::new(a.get("elevation")?)).map_err(|e| e.to_string())?;
    let v: Box<dyn cache_offroad::Valhalla> = match (a.opt("valhalla-lib"), a.opt("valhalla-tiles")) {
        (Some(lib), Some(tiles)) => Box::new(cache_offroad::shim::ShimValhalla::load(Path::new(lib), &cache_offroad::shim::config_for_tiles(Path::new(tiles)))?),
        _ => Box::new(cache_offroad::StubValhalla),
    };
    Ok((pack, elev, v))
}

/// navi-style directions on the pack (the /api/directions port).
fn directions_cmd(a: &Args) -> Result<(), String> {
    use cache_offroad::directions::{DirectionsRequest, Env, OffroadChoice, TravelMode};
    let (pack, elev, v) = open_env(a)?;
    let from = parse_ll(a.get("from")?)?;
    let to = parse_ll(a.get("to")?)?;
    let mode = TravelMode::from_name(a.opt("mode").unwrap_or("drive")).ok_or("bad --mode")?;
    let mut req = DirectionsRequest::new(from, to, mode);
    req.boundary = cache_offroad::Boundary::from_name(a.opt("boundary").unwrap_or("pragmatic")).ok_or("bad --boundary")?;
    req.offroad = OffroadChoice::from_name(a.opt("offroad").unwrap_or("auto")).ok_or("bad --offroad")?;
    req.from_category = a.opt("from-category").map(String::from);
    req.to_category = a.opt("to-category").map(String::from);
    let mut opts = cache_offroad::RouteOptions::default();
    if let Some(m) = a.opt("max-cells") {
        opts.max_cells = m.parse().map_err(|_| "bad --max-cells")?;
    }
    let env = Env { pack: &pack, elevation: &elev, valhalla: &*v, options: opts, namer: None, version: "cache_offroad".into() };
    let t = Instant::now();
    let d = env.directions(&req);
    eprintln!("directions ok={} steps={} in {} ms", d.ok, d.steps.len(), t.elapsed().as_millis());
    let out = d.to_json().to_string();
    match a.opt("json") {
        Some(p) => std::fs::write(p, out).map_err(|e| e.to_string()),
        None => {
            println!("{out}");
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tiff::encoder::{colortype, TiffEncoder};

    /// A north-up WGS84 GeoTIFF (uncompressed strips) of `f(lon, lat)` sampled at pixel centres.
    fn write_geotiff(p: &Path, west: f64, north: f64, px: f64, w: u32, h: u32, f: &dyn Fn(f64, f64) -> u8) {
        let mut data = vec![0u8; (w * h) as usize];
        for i in 0..h {
            for j in 0..w {
                data[(i * w + j) as usize] = f(west + (j as f64 + 0.5) * px, north - (i as f64 + 0.5) * px);
            }
        }
        let mut enc = TiffEncoder::new(std::fs::File::create(p).unwrap()).unwrap();
        let mut img = enc.new_image::<colortype::Gray8>(w, h).unwrap();
        img.encoder().write_tag(tiff::tags::Tag::ModelPixelScaleTag, &[px, px, 0.0][..]).unwrap();
        img.encoder().write_tag(tiff::tags::Tag::ModelTiepointTag, &[0.0, 0.0, 0.0, west, north, 0.0][..]).unwrap();
        img.write_data(&data).unwrap();
    }

    #[test]
    fn build_sources_end_to_end() {
        let dir = std::env::temp_dir().join(format!("offroad_pack_sources_{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(dir.join("class")).unwrap();
        // one z12 DEM tile around (44.0, -115.0)
        let (tx, ty) = grid::lat_lon_to_tile(44.0, -115.0, 12);
        let (west, east) = (merc_lon((tx * 512) as f64), merc_lon(((tx + 1) * 512) as f64));
        let (north, south) = (merc_lat((ty * 512) as f64), merc_lat(((ty + 1) * 512) as f64));
        let mid = (west + east) / 2.0;
        let (gw, gn, px) = (west - 0.01, north + 0.01, 0.0005);
        let (w, h) = (((east - west + 0.02) / px).ceil() as u32, ((north - south + 0.02) / px).ceil() as u32);
        write_geotiff(&dir.join("class/c.tif"), gw, gn, px, w, h, &|lon, _| if lon < mid { 10 } else { 80 });
        let band = south + 0.3 * (north - south);
        write_geotiff(&dir.join("trails.tif"), gw, gn, px, w, h, &|_, lat| if (lat - band).abs() < 0.001 { 25 } else { 0 });
        write_geotiff(&dir.join("barriers.tif"), gw, gn, px, w, h, &|lon, lat| if lon > mid && lat > band { 255 } else { 0 });
        write_geotiff(&dir.join("wild.tif"), gw, gn, px, w, h, &|_, _| 0);
        let e7 = |v: f64| (v * 1e7).round() as i32;
        let pm = pmw::build(vec![(pmtiles::zxy_to_tile_id(12, tx as u64, ty as u64), vec![1, 2, 3])], 12, [e7(west), e7(south), e7(east), e7(north)], "{}");
        std::fs::write(dir.join("elev.pmtiles"), pm).unwrap();
        std::fs::write(dir.join("cf.tsv"), "# test\nclass\tfriction\n10\t20\n80\t255\n").unwrap();
        let (clat, clon) = ((north + south) / 2.0, (west + east) / 2.0);
        std::fs::write(
            dir.join("parking.tsv"),
            format!("lat\tlon\tname\tparking_type\taccess\n{clat}\t{clon}\tLot\tsurface\t\n{clat}\t{clon}\tGated\tsurface\tprivate\n10\t10\tFar\t\t\n"),
        )
        .unwrap();
        std::fs::write(dir.join("entry.tsv"), format!("lat\tlon\thighway\tname\n{clat}\t{clon}\ttrack\tFS 1\n")).unwrap();
        let mvum_in = format!(
            r#"{{"properties":{{"is_trail":1,"symbol":"12","seasonal":"seasonal","atv":"open","atv_datesopen":"06/15-10/15"}},"geometry":{{"type":"MultiLineString","coordinates":[[[{w},{s}],[{e},{n}]]]}}}}"#,
            w = west, s = south, e = east, n = north
        );
        let mvum_out = r#"{"properties":{"is_trail":0},"geometry":{"type":"LineString","coordinates":[[10,10],[11,11]]}}"#;
        std::fs::write(dir.join("mvum.geojsonl"), format!("{mvum_in}\n{mvum_out}\n")).unwrap();
        let out = dir.join("out/offroad.sqlite");
        let s = |p: &str| dir.join(p).to_string_lossy().into_owned();
        let bbox = format!("{},{},{},{}", south - 0.1, north + 0.1, west - 0.1, east + 0.1);
        let argv: Vec<String> = [
            "--out", &out.to_string_lossy(), "--bbox", &bbox, "--threads", "2", "--coverage-pmtiles", &s("elev.pmtiles"),
            "--class-dir", &s("class"), "--class-friction", &s("cf.tsv"), "--trails", &s("trails.tif"), "--barriers", &s("barriers.tif"),
            "--wilderness", &s("wild.tif"), "--parking", &s("parking.tsv"), "--entry-points", &s("entry.tsv"), "--mvum", &s("mvum.geojsonl"),
        ]
        .iter()
        .map(|x| x.to_string())
        .collect();
        build_sources(&Args::parse(&argv)).unwrap();

        let p = SqlitePack::open(&out).unwrap();
        for l in [Layer::Friction, Layer::Class, Layer::Trails, Layer::Barriers, Layer::Wilderness] {
            assert!(p.has_layer(l), "{l:?}");
        }
        let (r0, c0) = (ty * 512, tx * 512);
        let class = p.read_u8(Layer::Class, r0, c0, 512, 512).unwrap();
        let fric = p.read_u8(Layer::Friction, r0, c0, 512, 512).unwrap();
        assert!(class.iter().any(|&c| c == 10) && class.iter().any(|&c| c == 80));
        assert!(class.iter().zip(&fric).all(|(&c, &f)| f == match c { 10 => 20, 80 => 255, _ => 0 }));
        assert!(p.read_u8(Layer::Trails, r0, c0, 512, 512).unwrap().iter().any(|&v| v == 25));
        let bar = p.read_u8(Layer::Barriers, r0, c0, 512, 512).unwrap();
        assert!(bar[5] == 0 && bar[511] == 255); // top-left open, top-right (east of mid, north of band) closed
        assert!(p.read_u8(Layer::Wilderness, r0, c0, 512, 512).unwrap().iter().all(|&v| v == 0));
        // cells outside the DEM tile have no tiles
        assert!(p.read_u8(Layer::Class, r0, c0 + 512, 4, 4).unwrap().iter().all(|&v| v == 0));
        let park = p.parking_in_box(west, east, south, north).unwrap();
        assert_eq!(park.len(), 1);
        assert_eq!(park[0].name, "Lot");
        let th = p.trailheads_in_box(west, east, south, north).unwrap();
        assert_eq!((th.len(), th[0].kind.as_str(), th[0].name.as_str()), (1, "track", "FS 1"));
        let mv = p.mvum_in_box(south, north, west, east).unwrap();
        assert_eq!(mv.len(), 1);
        assert!(mv[0].is_trail);
        assert_eq!(mv[0].access[1], (Some("open".into()), Some("06/15-10/15".into())));
        assert_eq!(p.info.meta.get("rows_mvum").map(String::as_str), Some("1"));
        let sha = sources::ClassFriction::load(&dir.join("cf.tsv")).unwrap().sha256;
        assert_eq!(p.info.meta.get("class_friction_sha256"), Some(&sha));
        drop(p);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
