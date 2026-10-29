//! Region pack: the single-file offline data a route needs (`offroad.sqlite`). See DESIGN-OFFROAD.md.
//!
//! * `meta(key, value)`: grid definition, layer list, source versions, mode-profile hash, build time.
//! * `tiles(layer, tx, ty, data)`: 256x256-cell tiles of the global z12 pixel grid (tx = global col / 256,
//!   ty = global row / 256), zstd(raw 65536 bytes). A missing tile reads 0. Elevation is NOT in the pack
//!   (see `elevation`).
//! * `parking`, `trailheads`, `mvum` with R*Tree indexes `*_idx`.
use crate::grid::PACK_TILE;
use rayon::prelude::*;
use rusqlite::{params, Connection, OpenFlags};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Mutex;

pub const FORMAT_VERSION: &str = "2";
const TILE_CELLS: usize = (PACK_TILE * PACK_TILE) as usize;

#[derive(Debug, thiserror::Error)]
pub enum PackError {
    #[error("sqlite: {0}")]
    Sql(#[from] rusqlite::Error),
    #[error("pack: {0}")]
    Msg(String),
}
pub type PResult<T> = Result<T, PackError>;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Layer {
    Friction,
    Class,
    Trails,
    Barriers,
    Wilderness,
}
impl Layer {
    pub const ALL: [Layer; 5] = [Layer::Friction, Layer::Class, Layer::Trails, Layer::Barriers, Layer::Wilderness];
    pub fn name(self) -> &'static str {
        match self {
            Layer::Friction => "friction",
            Layer::Class => "class",
            Layer::Trails => "trails",
            Layer::Barriers => "barriers",
            Layer::Wilderness => "wilderness",
        }
    }
}

// ---- tile codec -------------------------------------------------------------------------------

pub fn encode_u8_tile(raw: &[u8], level: i32) -> Vec<u8> {
    assert_eq!(raw.len(), TILE_CELLS);
    zstd::bulk::compress(raw, level).expect("zstd")
}
pub fn decode_u8_tile(blob: &[u8]) -> PResult<Vec<u8>> {
    let v = zstd::bulk::decompress(blob, TILE_CELLS).map_err(|e| PackError::Msg(format!("zstd: {e}")))?;
    if v.len() != TILE_CELLS {
        return Err(PackError::Msg("bad u8 tile size".into()));
    }
    Ok(v)
}

// ---- records ----------------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct PointRec {
    pub lat: f64,
    pub lon: f64,
    pub name: String,
    pub kind: String,   // parking_type or highway_class
    pub access: String, // parking access ("" for trailheads)
}

/// One MVUM road/trail with the raw per-class access fields (so the date logic runs on the phone).
#[derive(Debug, Clone)]
pub struct MvumFeature {
    pub is_trail: bool,
    pub symbol: Option<String>,
    pub seasonal: Option<String>,
    /// (status, dates) for modes mtb (e_bike_class1), atv, vehicle (highclearancevehicle) in that order.
    pub access: [(Option<String>, Option<String>); 3],
    /// parts of the (Multi)LineString as (lon, lat)
    pub lines: Vec<Vec<(f64, f64)>>,
}

#[derive(Debug, Clone)]
pub struct PackInfo {
    pub bbox: (f64, f64, f64, f64), // south, north, west, east
    pub layers: Vec<String>,
    pub meta: HashMap<String, String>,
}

pub trait PackSource: Send + Sync {
    fn has_layer(&self, layer: Layer) -> bool;
    /// u8 layer window in global pixel coordinates; cells without a tile read 0.
    fn read_u8(&self, layer: Layer, row0: i64, col0: i64, rows: usize, cols: usize) -> PResult<Vec<u8>>;
    /// Candidate points in the lon/lat box (callers apply the exact distance test).
    fn parking_in_box(&self, min_lon: f64, max_lon: f64, min_lat: f64, max_lat: f64) -> PResult<Vec<PointRec>>;
    fn trailheads_in_box(&self, min_lon: f64, max_lon: f64, min_lat: f64, max_lat: f64) -> PResult<Vec<PointRec>>;
    fn mvum_in_box(&self, south: f64, north: f64, west: f64, east: f64) -> PResult<Vec<MvumFeature>>;
    /// Whether the pack's data covers the point (a pack that does not know its extent says yes).
    fn covers(&self, _lat: f64, _lon: f64) -> bool {
        true
    }
}

// ---- geometry helpers shared by pack backends ---------------------------------------------------

/// `_buffer_degrees_for_meters`
pub fn buffer_degrees_for_meters(meters: f64, lat: f64) -> f64 {
    let cos_lat = lat.to_radians().cos().max(0.01);
    let lat_deg = meters / 111320.0;
    let lon_deg = meters / (111320.0 * cos_lat);
    lat_deg.max(lon_deg)
}

/// Planar distance (degrees) from point to segment, like shapely `LineString.distance(Point)`.
pub fn point_segment_dist_deg(px: f64, py: f64, a: (f64, f64), b: (f64, f64)) -> f64 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let l2 = dx * dx + dy * dy;
    let t = if l2 == 0.0 { 0.0 } else { (((px - a.0) * dx + (py - a.1) * dy) / l2).clamp(0.0, 1.0) };
    let (cx, cy) = (a.0 + t * dx, a.1 + t * dy);
    (px - cx).hypot(py - cy)
}

/// Points of `pts` within the buffer of the (lat, lon) endpoint line: the navi
/// `query_*_near_line` (bbox prefilter of the buffer, then a degree-distance test to the line).
pub fn near_line(
    cands: Vec<PointRec>, a: (f64, f64), b: (f64, f64), buffer_m: f64,
) -> Vec<PointRec> {
    let avg_lat = (a.0 + b.0) / 2.0;
    let bd = buffer_degrees_for_meters(buffer_m, avg_lat);
    cands
        .into_iter()
        .filter(|p| point_segment_dist_deg(p.lon, p.lat, (a.1, a.0), (b.1, b.0)) <= bd)
        .collect()
}

pub fn line_box(a: (f64, f64), b: (f64, f64), buffer_m: f64) -> (f64, f64, f64, f64) {
    let bd = buffer_degrees_for_meters(buffer_m, (a.0 + b.0) / 2.0);
    (a.1.min(b.1) - bd, a.1.max(b.1) + bd, a.0.min(b.0) - bd, a.0.max(b.0) + bd)
}

// ---- SQLite pack ------------------------------------------------------------------------------

pub struct SqlitePack {
    conn: Mutex<Connection>,
    pub info: PackInfo,
}

impl SqlitePack {
    pub fn open(path: &Path) -> PResult<SqlitePack> {
        let conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
        let mut meta = HashMap::new();
        {
            let mut st = conn.prepare("SELECT key, value FROM meta")?;
            let rows = st.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
            for r in rows {
                let (k, v) = r?;
                meta.insert(k, v);
            }
        }
        if meta.get("format_version").map(|s| s.as_str()) != Some(FORMAT_VERSION) {
            return Err(PackError::Msg(format!("unsupported pack format_version {:?}", meta.get("format_version"))));
        }
        let f = |k: &str| -> PResult<f64> {
            meta.get(k).and_then(|s| s.parse().ok()).ok_or_else(|| PackError::Msg(format!("meta {k} missing")))
        };
        let bbox = (f("bbox_south")?, f("bbox_north")?, f("bbox_west")?, f("bbox_east")?);
        let layers = meta.get("layers").map(|s| s.split(',').map(|x| x.to_string()).collect()).unwrap_or_default();
        Ok(SqlitePack { conn: Mutex::new(conn), info: PackInfo { bbox, layers, meta } })
    }

    fn tile_blobs(&self, layer: Layer, tx0: i64, tx1: i64, ty0: i64, ty1: i64) -> PResult<Vec<(i64, i64, Vec<u8>)>> {
        let conn = self.conn.lock().unwrap();
        // One exact key-range scan per tx column: a tx range with a ty filter would walk every ty row of
        // every column in between (each row is mostly overflow pages, so that is slow on a cold file).
        let mut st = conn.prepare_cached("SELECT ty, data FROM tiles WHERE layer=?1 AND tx=?2 AND ty BETWEEN ?3 AND ?4")?;
        let mut out = Vec::new();
        for tx in tx0..=tx1 {
            let rows = st.query_map(params![layer.name(), tx, ty0, ty1], |r| Ok((tx, r.get::<_, i64>(0)?, r.get::<_, Vec<u8>>(1)?)))?;
            for r in rows {
                out.push(r?);
            }
        }
        Ok(out)
    }

    fn read_window<T: Copy + Send + Sync>(
        &self, layer: Layer, row0: i64, col0: i64, rows: usize, cols: usize, fill: T,
        dec: &(dyn Fn(&[u8]) -> PResult<Vec<T>> + Sync),
    ) -> PResult<Vec<T>> {
        let mut out = vec![fill; rows * cols];
        if rows == 0 || cols == 0 {
            return Ok(out);
        }
        let (r1, c1) = (row0 + rows as i64, col0 + cols as i64);
        let (ty0, ty1) = (row0.div_euclid(PACK_TILE), (r1 - 1).div_euclid(PACK_TILE));
        let (tx0, tx1) = (col0.div_euclid(PACK_TILE), (c1 - 1).div_euclid(PACK_TILE));
        let blobs = self.tile_blobs(layer, tx0, tx1, ty0, ty1)?;
        let decoded: Vec<(i64, i64, Vec<T>)> = blobs
            .into_par_iter()
            .map(|(tx, ty, b)| dec(&b).map(|v| (tx, ty, v)))
            .collect::<PResult<Vec<_>>>()?;
        let w = PACK_TILE as usize;
        for (tx, ty, tile) in decoded {
            let (gr0, gc0) = (ty * PACK_TILE, tx * PACK_TILE);
            let rs = gr0.max(row0);
            let re = (gr0 + PACK_TILE).min(r1);
            let cs = gc0.max(col0);
            let ce = (gc0 + PACK_TILE).min(c1);
            for gr in rs..re {
                let src = ((gr - gr0) as usize) * w + (cs - gc0) as usize;
                let dst = ((gr - row0) as usize) * cols + (cs - col0) as usize;
                let n = (ce - cs) as usize;
                out[dst..dst + n].copy_from_slice(&tile[src..src + n]);
            }
        }
        Ok(out)
    }

    fn points(&self, table: &str, min_lon: f64, max_lon: f64, min_lat: f64, max_lat: f64) -> PResult<Vec<PointRec>> {
        let conn = self.conn.lock().unwrap();
        let sql = if table == "parking" {
            "SELECT p.lat, p.lon, p.name, p.parking_type, p.access FROM parking_idx i JOIN parking p ON p.id=i.id \
             WHERE i.max_lon >= ?1 AND i.min_lon <= ?2 AND i.max_lat >= ?3 AND i.min_lat <= ?4"
        } else {
            "SELECT p.lat, p.lon, p.name, p.highway_class, '' FROM trailheads_idx i JOIN trailheads p ON p.id=i.id \
             WHERE i.max_lon >= ?1 AND i.min_lon <= ?2 AND i.max_lat >= ?3 AND i.min_lat <= ?4"
        };
        let mut st = conn.prepare_cached(sql)?;
        let rows = st.query_map(params![min_lon, max_lon, min_lat, max_lat], |r| {
            Ok(PointRec {
                lat: r.get(0)?,
                lon: r.get(1)?,
                name: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                kind: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                access: r.get::<_, Option<String>>(4)?.unwrap_or_default(),
            })
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }
}

impl PackSource for SqlitePack {
    fn has_layer(&self, layer: Layer) -> bool {
        self.info.layers.iter().any(|l| l == layer.name())
    }
    fn covers(&self, lat: f64, lon: f64) -> bool {
        let (s, n, w, e) = self.info.bbox;
        s <= lat && lat <= n && w <= lon && lon <= e
    }
    fn read_u8(&self, layer: Layer, row0: i64, col0: i64, rows: usize, cols: usize) -> PResult<Vec<u8>> {
        self.read_window(layer, row0, col0, rows, cols, 0u8, &|b| decode_u8_tile(b))
    }
    fn parking_in_box(&self, a: f64, b: f64, c: f64, d: f64) -> PResult<Vec<PointRec>> {
        self.points("parking", a, b, c, d)
    }
    fn trailheads_in_box(&self, a: f64, b: f64, c: f64, d: f64) -> PResult<Vec<PointRec>> {
        self.points("trailheads", a, b, c, d)
    }
    fn mvum_in_box(&self, south: f64, north: f64, west: f64, east: f64) -> PResult<Vec<MvumFeature>> {
        let conn = self.conn.lock().unwrap();
        let mut st = conn.prepare_cached(
            "SELECT m.is_trail, m.symbol, m.seasonal, m.mtb_status, m.mtb_dates, m.atv_status, m.atv_dates, \
             m.veh_status, m.veh_dates, m.geom FROM mvum_idx i JOIN mvum m ON m.id=i.id \
             WHERE i.max_lon >= ?1 AND i.min_lon <= ?2 AND i.max_lat >= ?3 AND i.min_lat <= ?4",
        )?;
        let rows = st.query_map(params![west, east, south, north], |r| {
            let g: Vec<u8> = r.get(9)?;
            Ok(MvumFeature {
                is_trail: r.get::<_, i64>(0)? != 0,
                symbol: r.get(1)?,
                seasonal: r.get(2)?,
                access: [(r.get(3)?, r.get(4)?), (r.get(5)?, r.get(6)?), (r.get(7)?, r.get(8)?)],
                lines: decode_lines(&g),
            })
        })?;
        let mut out = Vec::new();
        for r in rows {
            out.push(r?);
        }
        Ok(out)
    }
}

/// Geometry blob: u32 n_parts, then per part u32 n_points + n_points * (f64 lon, f64 lat), little endian.
pub fn encode_lines(lines: &[Vec<(f64, f64)>]) -> Vec<u8> {
    let mut b = Vec::new();
    b.extend_from_slice(&(lines.len() as u32).to_le_bytes());
    for l in lines {
        b.extend_from_slice(&(l.len() as u32).to_le_bytes());
        for &(x, y) in l {
            b.extend_from_slice(&x.to_le_bytes());
            b.extend_from_slice(&y.to_le_bytes());
        }
    }
    b
}
pub fn decode_lines(b: &[u8]) -> Vec<Vec<(f64, f64)>> {
    let mut o = 0usize;
    let rd32 = |o: &mut usize| {
        let v = u32::from_le_bytes(b[*o..*o + 4].try_into().unwrap());
        *o += 4;
        v
    };
    let rdf = |o: &mut usize| {
        let v = f64::from_le_bytes(b[*o..*o + 8].try_into().unwrap());
        *o += 8;
        v
    };
    let np = rd32(&mut o);
    let mut out = Vec::new();
    for _ in 0..np {
        let n = rd32(&mut o);
        let mut l = Vec::with_capacity(n as usize);
        for _ in 0..n {
            let x = rdf(&mut o);
            let y = rdf(&mut o);
            l.push((x, y));
        }
        out.push(l);
    }
    out
}

/// Schema used by the builder (kept here so reader and writer cannot drift).
pub const SCHEMA: &str = "
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE tiles(layer TEXT NOT NULL, tx INTEGER NOT NULL, ty INTEGER NOT NULL, data BLOB NOT NULL, PRIMARY KEY(layer, tx, ty)) WITHOUT ROWID;
CREATE TABLE parking(id INTEGER PRIMARY KEY, lat REAL NOT NULL, lon REAL NOT NULL, name TEXT, parking_type TEXT, access TEXT);
CREATE VIRTUAL TABLE parking_idx USING rtree(id, min_lon, max_lon, min_lat, max_lat);
CREATE TABLE trailheads(id INTEGER PRIMARY KEY, lat REAL NOT NULL, lon REAL NOT NULL, name TEXT, highway_class TEXT);
CREATE VIRTUAL TABLE trailheads_idx USING rtree(id, min_lon, max_lon, min_lat, max_lat);
CREATE TABLE mvum(id INTEGER PRIMARY KEY, is_trail INTEGER NOT NULL, symbol TEXT, seasonal TEXT, maint TEXT,
  mtb_status TEXT, mtb_dates TEXT, atv_status TEXT, atv_dates TEXT, veh_status TEXT, veh_dates TEXT, geom BLOB NOT NULL);
CREATE VIRTUAL TABLE mvum_idx USING rtree(id, min_lon, max_lon, min_lat, max_lat);
";

// ---- in-memory pack (tests, parity harness) ------------------------------------------------------

/// A pack (and elevation source) held in memory over a rectangular region of the global pixel grid. Used
/// by the unit tests with synthetic grids.
#[derive(Default, Clone)]
pub struct MemPack {
    pub row0: i64,
    pub col0: i64,
    pub rows: usize,
    pub cols: usize,
    pub elev: Vec<f32>,
    pub friction: Vec<u8>,
    pub class: Option<Vec<u8>>,
    pub trails: Vec<u8>,
    pub barriers: Vec<u8>,
    pub wilderness: Option<Vec<u8>>,
    pub parking: Vec<PointRec>,
    pub trailheads: Vec<PointRec>,
    pub mvum: Vec<MvumFeature>,
}

impl MemPack {
    pub fn blank(rows: usize, cols: usize, elev: f32) -> MemPack {
        MemPack {
            row0: 0, col0: 0, rows, cols,
            elev: vec![elev; rows * cols],
            friction: vec![30; rows * cols],
            class: Some(vec![30; rows * cols]),
            trails: vec![0; rows * cols],
            barriers: vec![0; rows * cols],
            wilderness: Some(vec![0; rows * cols]),
            ..Default::default()
        }
    }
    fn win<T: Copy>(&self, src: &[T], row0: i64, col0: i64, rows: usize, cols: usize, fill: T) -> Vec<T> {
        let mut out = vec![fill; rows * cols];
        for r in 0..rows {
            let gr = row0 + r as i64 - self.row0;
            if gr < 0 || gr >= self.rows as i64 {
                continue;
            }
            for c in 0..cols {
                let gc = col0 + c as i64 - self.col0;
                if gc < 0 || gc >= self.cols as i64 {
                    continue;
                }
                out[r * cols + c] = src[gr as usize * self.cols + gc as usize];
            }
        }
        out
    }
}

impl PackSource for MemPack {
    fn has_layer(&self, layer: Layer) -> bool {
        match layer {
            Layer::Class => self.class.is_some(),
            Layer::Wilderness => self.wilderness.is_some(),
            _ => true,
        }
    }
    fn read_u8(&self, layer: Layer, row0: i64, col0: i64, rows: usize, cols: usize) -> PResult<Vec<u8>> {
        let src: &[u8] = match layer {
            Layer::Friction => &self.friction,
            Layer::Class => self.class.as_deref().ok_or_else(|| PackError::Msg("no class".into()))?,
            Layer::Trails => &self.trails,
            Layer::Barriers => &self.barriers,
            Layer::Wilderness => self.wilderness.as_deref().ok_or_else(|| PackError::Msg("no wilderness".into()))?,
        };
        Ok(self.win(src, row0, col0, rows, cols, 0u8))
    }
    fn parking_in_box(&self, a: f64, b: f64, c: f64, d: f64) -> PResult<Vec<PointRec>> {
        Ok(self.parking.iter().filter(|p| p.lon >= a && p.lon <= b && p.lat >= c && p.lat <= d).cloned().collect())
    }
    fn trailheads_in_box(&self, a: f64, b: f64, c: f64, d: f64) -> PResult<Vec<PointRec>> {
        Ok(self.trailheads.iter().filter(|p| p.lon >= a && p.lon <= b && p.lat >= c && p.lat <= d).cloned().collect())
    }
    fn mvum_in_box(&self, south: f64, north: f64, west: f64, east: f64) -> PResult<Vec<MvumFeature>> {
        Ok(self
            .mvum
            .iter()
            .filter(|f| {
                let (mut x0, mut x1, mut y0, mut y1) = (f64::MAX, f64::MIN, f64::MAX, f64::MIN);
                for l in &f.lines {
                    for &(x, y) in l {
                        x0 = x0.min(x);
                        x1 = x1.max(x);
                        y0 = y0.min(y);
                        y1 = y1.max(y);
                    }
                }
                !(x1 < west || x0 > east || y1 < south || y0 > north)
            })
            .cloned()
            .collect())
    }
}

impl crate::elevation::ElevationSource for MemPack {
    fn read_elevation(&self, row0: i64, col0: i64, rows: usize, cols: usize) -> Result<Vec<f32>, crate::elevation::ElevError> {
        Ok(self.win(&self.elev, row0, col0, rows, cols, f32::NAN))
    }
}
