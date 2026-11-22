//! `places_pack poi-link`: links the base map's chips to the pack's records, at build time, and merges true duplicates.
//!
//! The base map (Protomaps v4 PMTiles, layer `pois`) draws a chip per public place with a name, a `kind` and a point, and no
//! OpenStreetMap id. The app used to find the record on the phone by name and distance and picked wrong ones (a park for an
//! attraction chip of the same name). Here, once per build, every chip is matched to its record; the link goes into the tile
//! (`poi_links`, `cache_places::poi`) and the phone looks it up by what the chip carries, with no guessing.
//!
//! Matching, per level 1 tile (the post-pass over the output of `cut`, or one tile file):
//! 1. The chips: the `pois` features of the base map near the tile's candidate records (the z15 tile of a record from an OSM node;
//!    that tile and its eight neighbours plus the z13 tile for a record from an OSM way or relation, whose chip sits at the area's
//!    label point), or of every z15 tile in `--audit-bbox`. Only the whitelisted kinds of `poi-kinds.tsv` with a name count.
//! 2. The candidates: records from OpenStreetMap (a chip is an OSM feature) with the same normalised name (case, punctuation and
//!    spacing only) whose `kind` the table lists for the chip's tile kind, within [`NODE_REACH_M`] (a node: both sides carry the
//!    same point) or [`AREA_REACH_M`] (an area: the base map's label point against the pack's centre of the outline).
//! 3. One chip, one record: pairs are taken nearest first, so a chip never takes a record a nearer chip of the same name and kind
//!    has. A chip with no pair has no link, and the report says why.
//! 4. True duplicates: two records of the same name and the same icon class within [`DUP_REACH_M`] of each other are one place
//!    mapped twice (an `amenity=pharmacy` node and a `shop=chemist` way). They become one record with the best details of both.
//!    A different class (a fuel station and a convenience store of one name) or kind that the table does not allow stays apart.

use cache_places::poi::{metres, norm_name};
use cache_places::schema::tile_rect_l1;
use flate2::read::GzDecoder;
use rusqlite::types::Value;
use rusqlite::{params, params_from_iter, Connection};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::io::Read;
use std::sync::Mutex;
use std::time::Duration;

/// How far a chip may be from an OSM node's record: both carry the node's own point (tile quantisation is about 0.3 m at z15).
pub const NODE_REACH_M: f64 = 25.0;
/// How far a chip may be from the record of an OSM way or relation: the base map puts the chip at the area's label point, the pack
/// puts the record at the centre of up to 48 sampled outline nodes. Measured on Twin Falls: 3 to 200 m.
pub const AREA_REACH_M: f64 = 2000.0;
/// Two records of one name and icon class this close are one place mapped twice.
pub const DUP_REACH_M: f64 = 60.0;

pub const KIND_TABLE: &str = include_str!("../poi-kinds.tsv");

// ---- the kind table -------------------------------------------------------------------------------------------------------

/// Tile kind -> (icon class, the pack's `places.kind` values).
#[derive(Debug, Clone)]
pub struct KindTable {
    by_tile: BTreeMap<String, (String, Vec<String>)>,
    class_of_tag: HashMap<String, String>,
}

impl KindTable {
    pub fn parse(tsv: &str) -> Result<KindTable, String> {
        let mut by_tile = BTreeMap::new();
        let mut class_of_tag = HashMap::new();
        for (i, line) in tsv.lines().enumerate() {
            if line.starts_with('#') || line.trim().is_empty() || line.starts_with("tile_kind\t") {
                continue;
            }
            let f: Vec<&str> = line.split('\t').collect();
            if f.len() != 3 || f.iter().any(|x| x.trim().is_empty()) {
                return Err(format!("poi-kinds.tsv line {}: want tile_kind, class, osm_tags", i + 1));
            }
            let tags: Vec<String> = f[2].split(',').map(|t| t.trim().to_string()).collect();
            for t in &tags {
                class_of_tag.insert(t.clone(), f[1].to_string());
            }
            if by_tile.insert(f[0].to_string(), (f[1].to_string(), tags)).is_some() {
                return Err(format!("poi-kinds.tsv line {}: {} twice", i + 1, f[0]));
            }
        }
        Ok(KindTable { by_tile, class_of_tag })
    }

    pub fn builtin() -> KindTable {
        KindTable::parse(KIND_TABLE).expect("poi-kinds.tsv parses")
    }

    pub fn knows(&self, tile_kind: &str) -> bool {
        self.by_tile.contains_key(tile_kind)
    }

    /// The kind agrees: the record's `places.kind` is one the table lists for the chip's tile kind.
    pub fn agrees(&self, tile_kind: &str, record_kind: &str) -> bool {
        self.by_tile.get(tile_kind).is_some_and(|(_, tags)| tags.iter().any(|t| t == record_kind))
    }

    /// The icon class of a record's `places.kind`; None when no chip is drawn for it.
    pub fn class_of(&self, record_kind: &str) -> Option<&str> {
        self.class_of_tag.get(record_kind).map(String::as_str)
    }
}

// ---- chips and records ----------------------------------------------------------------------------------------------------

#[derive(Debug, Clone)]
pub struct Chip {
    pub name: String,
    pub name_norm: String,
    pub kind: String,
    pub lat: f64,
    pub lon: f64,
}

#[derive(Debug, Clone)]
pub struct Rec {
    pub id: i64,
    pub name: String,
    pub name_norm: String,
    /// `places.kind`: `key=value` for a record from OSM.
    pub kind: String,
    pub lat: f64,
    pub lon: f64,
    pub source: String,
    pub source_id: String,
}

impl Rec {
    /// From OpenStreetMap (alone or merged with Overture, OSM first) and so a possible chip.
    fn is_osm(&self) -> bool {
        self.source.starts_with("osm")
    }

    fn reach_m(&self) -> f64 {
        if self.source_id.starts_with("osm:n") {
            NODE_REACH_M
        } else {
            AREA_REACH_M
        }
    }

    fn is_area(&self) -> bool {
        !self.source_id.starts_with("osm:n")
    }
}

/// What happened to one chip.
#[derive(Debug, Clone, PartialEq)]
pub enum Fate {
    Linked(usize),
    Unlinked(String),
}

/// One chip to one record, nearest pairs first. `Fate::Unlinked` carries the reason.
pub fn assign(table: &KindTable, chips: &[Chip], recs: &[Rec]) -> Vec<Fate> {
    let mut by_name: HashMap<&str, Vec<usize>> = HashMap::new();
    for (j, r) in recs.iter().enumerate() {
        if r.is_osm() && !r.name_norm.is_empty() {
            by_name.entry(r.name_norm.as_str()).or_default().push(j);
        }
    }
    let mut pairs: Vec<(f64, usize, usize)> = Vec::new();
    for (i, c) in chips.iter().enumerate() {
        for &j in by_name.get(c.name_norm.as_str()).into_iter().flatten() {
            let r = &recs[j];
            if !table.agrees(&c.kind, &r.kind) {
                continue;
            }
            let d = metres(c.lat, c.lon, r.lat, r.lon);
            if d <= r.reach_m() {
                pairs.push((d, i, j));
            }
        }
    }
    pairs.sort_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal).then(a.1.cmp(&b.1)).then(a.2.cmp(&b.2)));
    let mut fate: Vec<Option<usize>> = vec![None; chips.len()];
    let mut taken: HashSet<usize> = HashSet::new();
    for (_, i, j) in pairs {
        if fate[i].is_none() && !taken.contains(&j) {
            fate[i] = Some(j);
            taken.insert(j);
        }
    }
    chips
        .iter()
        .enumerate()
        .map(|(i, c)| match fate[i] {
            Some(j) => Fate::Linked(j),
            None => Fate::Unlinked(why(table, c, recs, &taken)),
        })
        .collect()
}

fn why(table: &KindTable, c: &Chip, recs: &[Rec], taken: &HashSet<usize>) -> String {
    let same: Vec<(usize, &Rec)> = recs.iter().enumerate().filter(|(_, r)| r.name_norm == c.name_norm).collect();
    if same.is_empty() {
        return "no record with this name in the places data".into();
    }
    let osm: Vec<&(usize, &Rec)> = same.iter().filter(|(_, r)| r.is_osm()).collect();
    if osm.is_empty() {
        return format!("only a record from Overture has this name (kind {})", same[0].1.kind);
    }
    let agreeing: Vec<&&(usize, &Rec)> = osm.iter().filter(|(_, r)| table.agrees(&c.kind, &r.kind)).collect();
    if agreeing.is_empty() {
        let kinds: BTreeSet<&str> = osm.iter().map(|(_, r)| r.kind.as_str()).collect();
        return format!("records with this name are of another kind ({})", kinds.into_iter().collect::<Vec<_>>().join(", "));
    }
    let near = agreeing.iter().map(|(_, r)| (metres(c.lat, c.lon, r.lat, r.lon), r)).min_by(|a, b| a.0.partial_cmp(&b.0).unwrap_or(std::cmp::Ordering::Equal)).unwrap();
    if near.0 > near.1.reach_m() {
        return format!("the record of this name and kind is {:.0} m away (reach {:.0} m)", near.0, near.1.reach_m());
    }
    if agreeing.iter().any(|(j, _)| taken.contains(j)) {
        return "its record is the link of a nearer chip".into();
    }
    "no record".into()
}

/// Groups of record indexes that are one place mapped twice: the same normalised name, the same icon class, from OSM, each within
/// [`DUP_REACH_M`] of another of the group (chained). Only records whose kind the table knows. Groups of two or more.
pub fn duplicate_groups(table: &KindTable, recs: &[Rec]) -> Vec<Vec<usize>> {
    let mut by_key: BTreeMap<(String, String), Vec<usize>> = BTreeMap::new();
    for (j, r) in recs.iter().enumerate() {
        if !r.is_osm() || r.name_norm.is_empty() {
            continue;
        }
        if let Some(class) = table.class_of(&r.kind) {
            by_key.entry((r.name_norm.clone(), class.to_string())).or_default().push(j);
        }
    }
    let mut out = Vec::new();
    for (_, idx) in by_key {
        if idx.len() < 2 {
            continue;
        }
        let mut parent: Vec<usize> = (0..idx.len()).collect();
        fn find(p: &mut [usize], x: usize) -> usize {
            let mut r = x;
            while p[r] != r {
                r = p[r];
            }
            let mut x = x;
            while p[x] != r {
                let n = p[x];
                p[x] = r;
                x = n;
            }
            r
        }
        for (a, &ia) in idx.iter().enumerate() {
            for b in a + 1..idx.len() {
                let (ra, rb) = (&recs[ia], &recs[idx[b]]);
                if metres(ra.lat, ra.lon, rb.lat, rb.lon) <= DUP_REACH_M {
                    let (x, y) = (find(&mut parent, a), find(&mut parent, b));
                    if x != y {
                        parent[x] = y;
                    }
                }
            }
        }
        let mut groups: BTreeMap<usize, Vec<usize>> = BTreeMap::new();
        for (a, &ia) in idx.iter().enumerate() {
            let r = find(&mut parent, a);
            groups.entry(r).or_default().push(ia);
        }
        out.extend(groups.into_values().filter(|g| g.len() > 1));
    }
    out
}

// ---- PMTiles (read only, local file or HTTP range requests) ---------------------------------------------------------------

enum Src {
    File(Mutex<std::fs::File>),
    Http(ureq::Agent, String),
}

#[derive(Clone, Copy, Debug)]
struct Entry {
    tile_id: u64,
    run: u64,
    offset: u64,
    length: u64,
}

pub struct PmTiles {
    src: Src,
    root: Vec<Entry>,
    leaf_off: u64,
    data_off: u64,
    tile_comp: u8,
    leaves: Mutex<HashMap<u64, std::sync::Arc<Vec<Entry>>>>,
    pub name: String,
    /// Range requests made and bytes read from the file, for the run's summary.
    pub requests: std::sync::atomic::AtomicU64,
    pub bytes: std::sync::atomic::AtomicU64,
}

fn u64le(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(b[o..o + 8].try_into().unwrap())
}

fn varint(b: &[u8], pos: &mut usize) -> Result<u64, String> {
    let (mut v, mut shift) = (0u64, 0u32);
    loop {
        let x = *b.get(*pos).ok_or("truncated varint")?;
        *pos += 1;
        v |= ((x & 0x7f) as u64) << shift;
        if x & 0x80 == 0 {
            return Ok(v);
        }
        shift += 7;
        if shift > 63 {
            return Err("varint too long".into());
        }
    }
}

fn gunzip_if(data: &[u8], comp: u8) -> Result<Vec<u8>, String> {
    match comp {
        0 | 1 => Ok(data.to_vec()),
        2 => {
            let mut out = Vec::new();
            GzDecoder::new(data).read_to_end(&mut out).map_err(|e| e.to_string())?;
            Ok(out)
        }
        c => Err(format!("unsupported PMTiles compression {c}")),
    }
}

fn read_dir(b: &[u8]) -> Result<Vec<Entry>, String> {
    let mut p = 0;
    let n = varint(b, &mut p)? as usize;
    let mut v = vec![Entry { tile_id: 0, run: 0, offset: 0, length: 0 }; n];
    let mut last = 0u64;
    for e in v.iter_mut() {
        last += varint(b, &mut p)?;
        e.tile_id = last;
    }
    for e in v.iter_mut() {
        e.run = varint(b, &mut p)?;
    }
    for e in v.iter_mut() {
        e.length = varint(b, &mut p)?;
    }
    for i in 0..n {
        let o = varint(b, &mut p)?;
        v[i].offset = if o == 0 && i > 0 { v[i - 1].offset + v[i - 1].length } else { o.saturating_sub(1) };
    }
    Ok(v)
}

fn rotate(n: u64, x: &mut u64, y: &mut u64, rx: bool, ry: bool) {
    if !ry {
        if rx {
            *x = n - 1 - *x;
            *y = n - 1 - *y;
        }
        std::mem::swap(x, y);
    }
}

/// The PMTiles tile id (Hilbert curve order) of z/x/y.
pub fn zxy_to_id(z: u8, x: u64, y: u64) -> u64 {
    let base: u64 = (0..z).map(|i| 1u64 << (2 * i as u64)).sum();
    let n = 1u64 << z;
    let (mut x, mut y) = (x, y);
    let (mut d, mut s) = (0u64, n / 2);
    while s > 0 {
        let rx = (x & s) > 0;
        let ry = (y & s) > 0;
        d += s * s * ((3 * rx as u64) ^ ry as u64);
        rotate(n, &mut x, &mut y, rx, ry);
        s /= 2;
    }
    base + d
}

/// Web Mercator tile of a point at zoom `z`.
pub fn tile_of(z: u8, lat: f64, lon: f64) -> (u64, u64) {
    let n = (1u64 << z) as f64;
    let x = ((lon + 180.0) / 360.0 * n).floor().clamp(0.0, n - 1.0);
    let lat = lat.clamp(-85.0511, 85.0511).to_radians();
    let y = ((1.0 - (lat.tan() + 1.0 / lat.cos()).ln() / std::f64::consts::PI) / 2.0 * n).floor().clamp(0.0, n - 1.0);
    (x as u64, y as u64)
}

/// Longitude and latitude of a point `(px, py)` of an `extent` grid inside tile z/x/y.
pub fn point_of(z: u8, x: u64, y: u64, px: f64, py: f64, extent: f64) -> (f64, f64) {
    let n = (1u64 << z) as f64;
    let lon = (x as f64 + px / extent) / n * 360.0 - 180.0;
    let lat = (std::f64::consts::PI * (1.0 - 2.0 * (y as f64 + py / extent) / n)).sinh().atan().to_degrees();
    (lat, lon)
}

impl PmTiles {
    fn fetch(&self, off: u64, len: u64) -> Result<Vec<u8>, String> {
        self.requests.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        self.bytes.fetch_add(len, std::sync::atomic::Ordering::Relaxed);
        match &self.src {
            Src::File(f) => {
                use std::io::{Seek, SeekFrom};
                let mut f = f.lock().unwrap();
                f.seek(SeekFrom::Start(off)).map_err(|e| e.to_string())?;
                let mut b = vec![0u8; len as usize];
                f.read_exact(&mut b).map_err(|e| e.to_string())?;
                Ok(b)
            }
            Src::Http(agent, url) => {
                let mut last = String::new();
                for attempt in 0..4 {
                    match agent.get(url).set("Range", &format!("bytes={}-{}", off, off + len - 1)).call() {
                        Ok(r) => {
                            let mut b = Vec::with_capacity(len as usize);
                            r.into_reader().take(len + 1).read_to_end(&mut b).map_err(|e| e.to_string())?;
                            if b.len() as u64 == len {
                                return Ok(b);
                            }
                            last = format!("{} bytes of {len}", b.len());
                        }
                        Err(ureq::Error::Status(c, _)) if c == 429 || c >= 500 => last = format!("HTTP {c}"),
                        Err(e) => return Err(format!("{url}: {e}")),
                    }
                    std::thread::sleep(Duration::from_millis(400 * (attempt + 1)));
                }
                Err(format!("{url}: {last}"))
            }
        }
    }

    /// Opens a local `.pmtiles` file or an `http(s)://` address (served with range requests).
    pub fn open(location: &str) -> Result<PmTiles, String> {
        let src = if location.starts_with("http://") || location.starts_with("https://") {
            Src::Http(ureq::AgentBuilder::new().timeout(Duration::from_secs(60)).user_agent("cache-places-pack/1.0").build(), location.to_string())
        } else {
            Src::File(Mutex::new(std::fs::File::open(location).map_err(|e| format!("{location}: {e}"))?))
        };
        let mut pm = PmTiles { src, root: vec![], leaf_off: 0, data_off: 0, tile_comp: 0, leaves: Mutex::new(HashMap::new()), requests: Default::default(), bytes: Default::default(), name: location.rsplit('/').next().unwrap_or(location).to_string() };
        let h = pm.fetch(0, 127)?;
        if &h[..7] != b"PMTiles" || h[7] != 3 {
            return Err(format!("{location}: not a PMTiles v3 file"));
        }
        let (root_off, root_len, leaf_off, data_off) = (u64le(&h, 8), u64le(&h, 16), u64le(&h, 40), u64le(&h, 56));
        let (int_comp, tile_comp) = (h[97], h[98]);
        pm.root = read_dir(&gunzip_if(&pm.fetch(root_off, root_len)?, int_comp)?)?;
        pm.leaf_off = leaf_off;
        pm.data_off = data_off;
        pm.tile_comp = tile_comp;
        Ok(pm)
    }

    fn find(ents: &[Entry], id: u64) -> Option<Entry> {
        let i = ents.partition_point(|e| e.tile_id <= id);
        if i == 0 {
            return None;
        }
        let e = ents[i - 1];
        if e.run == 0 || id < e.tile_id + e.run {
            Some(e)
        } else {
            None
        }
    }

    /// The decompressed tile z/x/y, or None when the file has none.
    pub fn tile(&self, z: u8, x: u64, y: u64) -> Result<Option<Vec<u8>>, String> {
        let id = zxy_to_id(z, x, y);
        let mut cur: std::sync::Arc<Vec<Entry>> = std::sync::Arc::new(self.root.clone());
        for _ in 0..4 {
            let Some(e) = Self::find(&cur, id) else { return Ok(None) };
            if e.run > 0 {
                return gunzip_if(&self.fetch(self.data_off + e.offset, e.length)?, self.tile_comp).map(Some);
            }
            let cached = self.leaves.lock().unwrap().get(&e.offset).cloned();
            cur = match cached {
                Some(l) => l,
                None => {
                    let l = std::sync::Arc::new(read_dir(&gunzip_if(&self.fetch(self.leaf_off + e.offset, e.length)?, 2)?)?);
                    self.leaves.lock().unwrap().insert(e.offset, l.clone());
                    l
                }
            };
        }
        Err("PMTiles directory nests too deep".into())
    }
}

// ---- the `pois` layer of a vector tile (Mapbox Vector Tile, protobuf) ------------------------------------------------------

type PbField<'a> = (u32, u32, &'a [u8], u64);

fn pb_fields(b: &[u8]) -> Result<Vec<PbField<'_>>, String> {
    // (field, wire type, bytes for length-delimited, value for varint)
    let mut out = Vec::new();
    let mut p = 0;
    while p < b.len() {
        let k = varint(b, &mut p)?;
        let (f, w) = ((k >> 3) as u32, (k & 7) as u32);
        match w {
            0 => out.push((f, w, &b[0..0], varint(b, &mut p)?)),
            2 => {
                let l = varint(b, &mut p)? as usize;
                let s = b.get(p..p + l).ok_or("truncated field")?;
                p += l;
                out.push((f, w, s, 0));
            }
            5 => p += 4,
            1 => p += 8,
            _ => return Err(format!("unsupported protobuf wire type {w}")),
        }
    }
    Ok(out)
}

fn unzigzag(n: u64) -> i64 {
    ((n >> 1) as i64) ^ -((n & 1) as i64)
}

/// A point feature of the `pois` layer: its properties (string values only) and its point in the layer's extent grid.
pub struct PoiFeature {
    pub props: HashMap<String, String>,
    pub x: f64,
    pub y: f64,
    pub extent: f64,
}

/// The point features of the layer named `pois` in a decompressed tile.
pub fn pois_of(tile: &[u8]) -> Result<Vec<PoiFeature>, String> {
    let mut out = Vec::new();
    for (f, w, layer, _) in pb_fields(tile)? {
        if f != 3 || w != 2 {
            continue;
        }
        let (mut name, mut keys, mut vals, mut feats, mut extent) = (String::new(), Vec::<String>::new(), Vec::<String>::new(), Vec::<&[u8]>::new(), 4096u64);
        for (f2, w2, b2, v2) in pb_fields(layer)? {
            match (f2, w2) {
                (1, 2) => name = String::from_utf8_lossy(b2).into_owned(),
                (2, 2) => feats.push(b2),
                (3, 2) => keys.push(String::from_utf8_lossy(b2).into_owned()),
                (4, 2) => {
                    // A value: only the string form matters here (name, kind); numbers are kept as text.
                    let mut s = String::new();
                    for (f3, w3, b3, v3) in pb_fields(b2)? {
                        match (f3, w3) {
                            (1, 2) => s = String::from_utf8_lossy(b3).into_owned(),
                            (4, 0) | (5, 0) => s = v3.to_string(),
                            (6, 0) => s = unzigzag(v3).to_string(),
                            _ => {}
                        }
                    }
                    vals.push(s);
                }
                (5, 0) => extent = v2,
                _ => {}
            }
        }
        if name != "pois" {
            continue;
        }
        for fb in feats {
            let (mut tags, mut gt, mut geom) = (Vec::<u64>::new(), 0u64, Vec::<u64>::new());
            for (f3, w3, b3, v3) in pb_fields(fb)? {
                match (f3, w3) {
                    (2, 2) => {
                        let mut p = 0;
                        while p < b3.len() {
                            tags.push(varint(b3, &mut p)?);
                        }
                    }
                    (3, 0) => gt = v3,
                    (4, 2) => {
                        let mut p = 0;
                        while p < b3.len() {
                            geom.push(varint(b3, &mut p)?);
                        }
                    }
                    _ => {}
                }
            }
            if gt != 1 || geom.len() < 3 || geom[0] & 7 != 1 {
                continue;
            }
            let mut props = HashMap::new();
            for kv in tags.chunks(2) {
                if let [k, v] = kv {
                    if let (Some(k), Some(v)) = (keys.get(*k as usize), vals.get(*v as usize)) {
                        props.insert(k.clone(), v.clone());
                    }
                }
            }
            out.push(PoiFeature { props, x: unzigzag(geom[1]) as f64, y: unzigzag(geom[2]) as f64, extent: extent as f64 });
        }
    }
    Ok(out)
}

/// The named chips of the table's kinds in one base map tile, as points.
pub fn chips_of_tile(pm: &PmTiles, table: &KindTable, z: u8, x: u64, y: u64) -> Result<Vec<Chip>, String> {
    let Some(t) = pm.tile(z, x, y)? else { return Ok(vec![]) };
    let mut out = Vec::new();
    for f in pois_of(&t)? {
        let (Some(kind), Some(name)) = (f.props.get("kind"), f.props.get("name")) else { continue };
        let name_norm = norm_name(name);
        if !table.knows(kind) || name_norm.is_empty() {
            continue;
        }
        let (lat, lon) = point_of(z, x, y, f.x, f.y, f.extent);
        out.push(Chip { name: name.clone(), name_norm, kind: kind.clone(), lat, lon });
    }
    Ok(out)
}

/// Fetches the chips of every base map tile in `wanted` (z, x, y), `jobs` at a time; the same chip seen in two tiles (a tile
/// carries a margin) or at two zooms is kept once, at its finest zoom's point.
pub fn collect_chips(pm: &PmTiles, table: &KindTable, wanted: &BTreeSet<(u8, u64, u64)>, jobs: usize) -> Result<Vec<Chip>, String> {
    let list: Vec<(u8, u64, u64)> = wanted.iter().rev().copied().collect(); // z15 before z13
    let next = std::sync::atomic::AtomicUsize::new(0);
    let found: Mutex<Vec<(u8, Vec<Chip>)>> = Mutex::new(Vec::new());
    let failed: Mutex<Option<String>> = Mutex::new(None);
    std::thread::scope(|sc| {
        for _ in 0..jobs.clamp(1, list.len().max(1)) {
            sc.spawn(|| loop {
                let i = next.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                let Some(&(z, x, y)) = list.get(i) else { return };
                match chips_of_tile(pm, table, z, x, y) {
                    Ok(c) => found.lock().unwrap().push((z, c)),
                    Err(e) => {
                        failed.lock().unwrap().get_or_insert(format!("tile {z}/{x}/{y}: {e}"));
                        return;
                    }
                }
            });
        }
    });
    if let Some(e) = failed.into_inner().unwrap() {
        return Err(e);
    }
    let mut all = found.into_inner().unwrap();
    all.sort_by_key(|a| std::cmp::Reverse(a.0));
    let mut out: Vec<Chip> = Vec::new();
    let mut seen: HashMap<(String, String), Vec<usize>> = HashMap::new();
    for (_, chips) in all {
        for c in chips {
            let key = (c.name_norm.clone(), c.kind.clone());
            if seen.get(&key).is_some_and(|v| v.iter().any(|&i| metres(c.lat, c.lon, out[i].lat, out[i].lon) <= 6.0)) {
                continue;
            }
            seen.entry(key).or_default().push(out.len());
            out.push(c);
        }
    }
    out.sort_by(|a, b| (&a.name_norm, &a.kind, a.lat.to_bits(), a.lon.to_bits()).partial_cmp(&(&b.name_norm, &b.kind, b.lat.to_bits(), b.lon.to_bits())).unwrap());
    Ok(out)
}

/// The base map tiles to read for a tile's records: a node's own z15 tile; an area's z15 tile and its eight neighbours and its z13 tile
/// (a chip of a big area is at its label point, which can be further than a tile from the record's point).
pub fn wanted_tiles(recs: &[Rec], table: &KindTable, audit: Option<[f64; 4]>) -> BTreeSet<(u8, u64, u64)> {
    let mut w = BTreeSet::new();
    for r in recs.iter().filter(|r| r.is_osm() && table.class_of(&r.kind).is_some() && !r.name_norm.is_empty()) {
        let (x, y) = tile_of(15, r.lat, r.lon);
        if r.is_area() {
            for dx in -1i64..=1 {
                for dy in -1i64..=1 {
                    w.insert((15, (x as i64 + dx).max(0) as u64, (y as i64 + dy).max(0) as u64));
                }
            }
            let (x13, y13) = tile_of(13, r.lat, r.lon);
            w.insert((13, x13, y13));
        } else {
            w.insert((15, x, y));
        }
    }
    if let Some([west, south, east, north]) = audit {
        let (x0, y1) = tile_of(15, south, west);
        let (x1, y0) = tile_of(15, north, east);
        for x in x0..=x1 {
            for y in y0..=y1 {
                w.insert((15, x, y));
            }
        }
    }
    w
}

// ---- one tile ---------------------------------------------------------------------------------------------------------------

/// One chip's line of the report.
#[derive(Debug, Clone)]
pub struct ChipLine {
    pub name: String,
    pub kind: String,
    pub lat: f64,
    pub lon: f64,
    pub in_cell: bool,
    pub record: Option<String>,
    pub record_kind: Option<String>,
    pub dist_m: Option<f64>,
    pub reason: String,
}

#[derive(Debug, Default)]
pub struct TileReport {
    pub tile: u32,
    pub records: usize,
    pub chips: usize,
    pub chips_in_cell: usize,
    pub linked: usize,
    pub linked_in_cell: usize,
    pub merged_groups: usize,
    pub merged_records: usize,
    pub base_tiles: usize,
    pub lines: Vec<ChipLine>,
    pub merges: Vec<String>,
}

fn is_empty(v: &Value) -> bool {
    matches!(v, Value::Null) || matches!(v, Value::Text(t) if t.trim().is_empty())
}

fn detail_score(cols: &[String], row: &[Value]) -> usize {
    ["phone", "hours", "website", "wikidata_id", "wikipedia_title", "wikivoyage_title", "summary", "brand_wikidata", "street", "locality", "about"]
        .iter()
        .filter(|c| cols.iter().position(|x| x == *c).is_some_and(|i| !is_empty(&row[i])))
        .count()
}

/// Merges the rows of one duplicate group into the best of them (most details; then one with Overture's data in it; then the
/// lowest id): empty details are filled from the others, names that differ are kept as alternate names, and the sources are
/// joined. Returns (survivor row index, the merged row). `rows` are in the order of `cols`.
pub fn merge_group(cols: &[String], rows: &[&Vec<Value>]) -> (usize, Vec<Value>) {
    let col = |n: &str| cols.iter().position(|c| c == n);
    let text = |r: &Vec<Value>, n: &str| col(n).and_then(|i| if let Value::Text(t) = &r[i] { Some(t.clone()) } else { None });
    let mut order: Vec<usize> = (0..rows.len()).collect();
    order.sort_by_key(|&i| {
        let over = text(rows[i], "source").is_some_and(|s| s.contains("overture"));
        let id = if let Some(Value::Integer(n)) = col("id").map(|c| rows[i][c].clone()) { n } else { 0 };
        (std::cmp::Reverse(detail_score(cols, rows[i])), std::cmp::Reverse(over), id)
    });
    let best = order[0];
    let mut out = rows[best].clone();
    for n in ["street", "locality", "county", "state", "country", "phone", "hours", "website", "wikidata_id", "wikipedia_title", "wikivoyage_title", "summary", "brand_wikidata", "about", "matched_source_id"] {
        if let Some(c) = col(n) {
            if is_empty(&out[c]) {
                if let Some(&o) = order.iter().skip(1).find(|&&o| !is_empty(&rows[o][c])) {
                    out[c] = rows[o][c].clone();
                }
            }
        }
    }
    if let (Some(a), Some(b)) = (col("arrival_lat"), col("arrival_lon")) {
        if is_empty(&out[a]) || is_empty(&out[b]) {
            if let Some(&o) = order.iter().skip(1).find(|&&o| !is_empty(&rows[o][a]) && !is_empty(&rows[o][b])) {
                out[a] = rows[o][a].clone();
                out[b] = rows[o][b].clone();
            }
        }
    }
    if let Some(c) = col("confidence") {
        let best_conf = order.iter().filter_map(|&o| if let Value::Real(x) = rows[o][c] { Some(x) } else { None }).fold(f64::NAN, f64::max);
        if best_conf.is_finite() {
            out[c] = Value::Real(best_conf);
        }
    }
    if let Some(c) = col("source") {
        let mut toks: Vec<String> = Vec::new();
        for &o in &order {
            if let Value::Text(s) = &rows[o][c] {
                for t in s.split('+') {
                    if !toks.iter().any(|x| x == t) {
                        toks.push(t.to_string());
                    }
                }
            }
        }
        toks.sort_by_key(|t| if t == "osm" { 0 } else if t == "overture" { 1 } else { 2 });
        out[c] = Value::Text(toks.join("+"));
    }
    if let (Some(c), Some(n)) = (col("alt_names"), col("name")) {
        let own = text(&out, "name").map(|s| norm_name(&s)).unwrap_or_default();
        let mut alts: Vec<String> = Vec::new();
        for &o in &order {
            let mut names: Vec<String> = text(rows[o], "alt_names").map(|a| a.split("; ").map(str::to_string).collect()).unwrap_or_default();
            if let Value::Text(nm) = &rows[o][n] {
                names.push(nm.clone());
            }
            for nm in names {
                let k = norm_name(&nm);
                if !k.is_empty() && k != own && !alts.iter().any(|a| norm_name(a) == k) {
                    alts.push(nm);
                }
            }
        }
        out[c] = if alts.is_empty() { Value::Null } else { Value::Text(alts.join("; ")) };
    }
    (best, out)
}

/// Links one tile file in place: reads its records, fetches the base map's chips, writes `poi_links`, merges the duplicates, and
/// updates the tile's counts. `audit` also reads every z15 tile of a box (to count the chips that have no record at all).
pub fn link_tile(conn: &mut Connection, pm: &PmTiles, table: &KindTable, audit: Option<[f64; 4]>, jobs: usize) -> Result<TileReport, String> {
    link_tile_with(conn, table, &pm.name, audit, |w| collect_chips(pm, table, w, jobs))
}

/// [`link_tile`] with the chips supplied by `chips_for` (given the base map tiles to read), for tests and other sources.
pub fn link_tile_with(
    conn: &mut Connection,
    table: &KindTable,
    basemap: &str,
    audit: Option<[f64; 4]>,
    chips_for: impl FnOnce(&BTreeSet<(u8, u64, u64)>) -> Result<Vec<Chip>, String>,
) -> Result<TileReport, String> {
    let e = |x: rusqlite::Error| x.to_string();
    let tile: u32 = conn.query_row("SELECT value FROM meta WHERE key = 'tile'", [], |r| r.get::<_, String>(0)).map_err(e)?.parse().map_err(|_| "tile meta".to_string())?;
    let cols: Vec<String> = conn.prepare("SELECT name FROM pragma_table_info('places')").map_err(e)?.query_map([], |r| r.get::<_, String>(0)).map_err(e)?.collect::<Result<_, _>>().map_err(e)?;
    let mut rows: Vec<Vec<Value>> = Vec::new();
    {
        let mut st = conn.prepare(&format!("SELECT {} FROM places ORDER BY id", cols.join(", "))).map_err(e)?;
        let mut q = st.query([]).map_err(e)?;
        while let Some(r) = q.next().map_err(e)? {
            rows.push((0..cols.len()).map(|i| r.get::<_, Value>(i)).collect::<Result<_, _>>().map_err(e)?);
        }
    }
    let ix = |n: &str| cols.iter().position(|c| c == n).ok_or_else(|| format!("places has no column {n}"));
    let (i_id, i_name, i_kind, i_lat, i_lon, i_src, i_sid) = (ix("id")?, ix("name")?, ix("kind")?, ix("lat")?, ix("lon")?, ix("source")?, ix("source_id")?);
    let txt = |v: &Value| if let Value::Text(t) = v { t.clone() } else { String::new() };
    let num = |v: &Value| match v {
        Value::Real(x) => *x,
        Value::Integer(n) => *n as f64,
        _ => f64::NAN,
    };
    let recs: Vec<Rec> = rows
        .iter()
        .map(|r| Rec {
            id: if let Value::Integer(n) = r[i_id] { n } else { 0 },
            name: txt(&r[i_name]),
            name_norm: norm_name(&txt(&r[i_name])),
            kind: txt(&r[i_kind]),
            lat: num(&r[i_lat]),
            lon: num(&r[i_lon]),
            source: txt(&r[i_src]),
            source_id: txt(&r[i_sid]),
        })
        .collect();

    let wanted = wanted_tiles(&recs, table, audit);
    let chips = chips_for(&wanted)?;
    let fates = assign(table, &chips, &recs);

    // True duplicates.
    let groups = duplicate_groups(table, &recs);
    let mut redirect: HashMap<usize, usize> = HashMap::new(); // record index -> survivor index
    let mut merged_rows: HashMap<usize, Vec<Value>> = HashMap::new();
    let mut merges = Vec::new();
    for g in &groups {
        let members: Vec<&Vec<Value>> = g.iter().map(|&j| &rows[j]).collect();
        let (best, merged) = merge_group(&cols, &members);
        let surv = g[best];
        merges.push(format!(
            "{}: {} kept; merged {}",
            recs[surv].name,
            recs[surv].source_id,
            g.iter().filter(|&&j| j != surv).map(|&j| format!("{} ({})", recs[j].source_id, recs[j].kind)).collect::<Vec<_>>().join(", ")
        ));
        for &j in g {
            if j != surv {
                redirect.insert(j, surv);
            }
        }
        merged_rows.insert(surv, merged);
    }

    let cell = tile_rect_l1(tile);
    let in_cell = |lat: f64, lon: f64| lon >= cell[0] && lon < cell[2] && lat >= cell[1] && lat < cell[3];
    let mut lines = Vec::new();
    let mut links: Vec<(String, String, f64, f64, String)> = Vec::new();
    for (c, f) in chips.iter().zip(&fates) {
        match f {
            Fate::Linked(j) => {
                let s = *redirect.get(j).unwrap_or(j);
                let (sid, kind) = (recs[s].source_id.clone(), recs[*j].kind.clone());
                links.push((c.name_norm.clone(), c.kind.clone(), c.lat, c.lon, sid.clone()));
                lines.push(ChipLine { name: c.name.clone(), kind: c.kind.clone(), lat: c.lat, lon: c.lon, in_cell: in_cell(c.lat, c.lon), record: Some(sid), record_kind: Some(kind), dist_m: Some(metres(c.lat, c.lon, recs[*j].lat, recs[*j].lon)), reason: if s != *j { format!("linked to the merged record (was {})", recs[*j].source_id) } else { String::new() } });
            }
            Fate::Unlinked(why) => lines.push(ChipLine { name: c.name.clone(), kind: c.kind.clone(), lat: c.lat, lon: c.lon, in_cell: in_cell(c.lat, c.lon), record: None, record_kind: None, dist_m: None, reason: why.clone() }),
        }
    }

    // Write: duplicates first (rows, vectors, references), then links, then counts.
    let tx = conn.transaction().map_err(e)?;
    for (&surv, merged) in &merged_rows {
        let sets: Vec<String> = cols.iter().enumerate().filter(|(i, _)| *i != i_id).map(|(_, c)| format!("{c} = ?")).collect();
        let mut vals: Vec<Value> = merged.iter().enumerate().filter(|(i, _)| *i != i_id).map(|(_, v)| v.clone()).collect();
        vals.push(Value::Integer(recs[surv].id));
        tx.execute(&format!("UPDATE places SET {} WHERE id = ?", sets.join(", ")), params_from_iter(vals)).map_err(e)?;
    }
    for (&loser, &surv) in &redirect {
        let (lid, sid) = (recs[loser].id, recs[surv].id);
        // The loser's vector (its summary) goes to the survivor when the survivor has none.
        let has: bool = tx.query_row("SELECT COUNT(*) FROM vectors WHERE kind = 'place' AND ref = ?1", params![sid], |r| r.get::<_, i64>(0)).map_err(e)? > 0;
        if has {
            tx.execute("DELETE FROM vectors WHERE kind = 'place' AND ref = ?1", params![lid]).map_err(e)?;
        } else {
            tx.execute("UPDATE vectors SET ref = ?1 WHERE kind = 'place' AND ref = ?2", params![sid, lid]).map_err(e)?;
        }
        tx.execute("UPDATE places SET matched_source_id = ?1 WHERE matched_source_id = ?2", params![recs[surv].source_id, recs[loser].source_id]).map_err(e)?;
        tx.execute("DELETE FROM places WHERE id = ?1", params![lid]).map_err(e)?;
    }
    tx.execute_batch("DROP TABLE IF EXISTS poi_links; CREATE TABLE poi_links (name_norm TEXT NOT NULL, kind TEXT NOT NULL, lat REAL NOT NULL, lon REAL NOT NULL, source_id TEXT NOT NULL);").map_err(e)?;
    {
        let mut ins = tx.prepare("INSERT INTO poi_links(name_norm, kind, lat, lon, source_id) VALUES (?1, ?2, ?3, ?4, ?5)").map_err(e)?;
        for l in &links {
            ins.execute(params![l.0, l.1, l.2, l.3, l.4]).map_err(e)?;
        }
    }
    if !redirect.is_empty() {
        tx.execute_batch(
            "DELETE FROM tile_counts;
             INSERT INTO tile_counts(what, id, n) SELECT 'category', category, COUNT(*) FROM places WHERE category IS NOT NULL GROUP BY category;
             INSERT INTO tile_counts(what, id, n) SELECT 'kind', kind_id, COUNT(*) FROM places WHERE kind_id IS NOT NULL GROUP BY kind_id;",
        )
        .map_err(e)?;
        let counts: String = tx.query_row("SELECT value FROM meta WHERE key = 'counts'", [], |r| r.get(0)).map_err(e)?;
        let mut v: serde_json::Value = serde_json::from_str(&counts).map_err(|x| x.to_string())?;
        v["places"] = serde_json::json!(tx.query_row("SELECT COUNT(*) FROM places", [], |r| r.get::<_, i64>(0)).map_err(e)?);
        tx.execute("UPDATE meta SET value = ?1 WHERE key = 'counts'", params![v.to_string()]).map_err(e)?;
    }
    let note = serde_json::json!({"basemap": basemap, "chips": links.len(), "merged_records": redirect.len()});
    tx.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('poi_links', ?1)", params![note.to_string()]).map_err(e)?;
    tx.commit().map_err(e)?;
    conn.execute_batch("VACUUM;").map_err(e)?;

    let linked = lines.iter().filter(|l| l.record.is_some()).count();
    Ok(TileReport {
        tile,
        records: recs.len(),
        chips: chips.len(),
        chips_in_cell: lines.iter().filter(|l| l.in_cell).count(),
        linked,
        linked_in_cell: lines.iter().filter(|l| l.in_cell && l.record.is_some()).count(),
        merged_groups: groups.len(),
        merged_records: redirect.len(),
        base_tiles: wanted.len(),
        lines,
        merges,
    })
}

// ---- the command -------------------------------------------------------------------------------------------------------------

pub struct Cfg {
    /// A cut output folder (`out/<build>`: `index.tsv` and `1/aaa/bbb.sqlite.gz`), rewritten in place with its index.
    pub tiles: Option<std::path::PathBuf>,
    /// One unpacked tile file, rewritten in place (for trials; no index).
    pub tile_file: Option<std::path::PathBuf>,
    /// The base map: a `.pmtiles` file or an `https://` address.
    pub basemap: String,
    pub jobs: usize,
    pub tile_jobs: usize,
    /// Also read every z15 base map tile of this box, so the report counts chips that have no record at all.
    pub audit: Option<[f64; 4]>,
    /// Only these tile paths (`1/047/585`) of `tiles`.
    pub only: Option<Vec<String>>,
    pub report: Option<std::path::PathBuf>,
}

#[derive(Debug, Default)]
pub struct Summary {
    pub tiles: usize,
    pub chips_in_cell: usize,
    pub linked_in_cell: usize,
    pub merged_records: usize,
}

fn report_line(path: &str, l: &ChipLine) -> String {
    format!(
        "{path}\t{}\t{}\t{:.6}\t{:.6}\t{}\t{}\t{}\t{}\t{}\t{}\n",
        l.name.replace('\t', " "),
        l.kind,
        l.lat,
        l.lon,
        if l.in_cell { "in" } else { "out" },
        if l.record.is_some() { "linked" } else { "unlinked" },
        l.record.clone().unwrap_or_default(),
        l.record_kind.clone().unwrap_or_default(),
        l.dist_m.map(|d| format!("{d:.1}")).unwrap_or_default(),
        l.reason
    )
}

pub fn run(cfg: &Cfg) -> Result<Summary, String> {
    use sha2::{Digest, Sha256};
    let table = KindTable::builtin();
    let pm = PmTiles::open(&cfg.basemap)?;
    let mut sum = Summary::default();
    let mut report = String::from("tile\tname\tkind\tlat\tlon\tcell\tstatus\trecord\trecord_kind\tdist_m\treason\n");
    let mut merges = String::new();
    let mut take = |path: &str, r: &TileReport, sum: &mut Summary| {
        sum.tiles += 1;
        eprintln!(
            "{path} (tile {}): {} places, {} base map tiles read, {} chips ({} inside the tile), {} linked ({} inside), {} duplicate records merged in {} groups",
            r.tile, r.records, r.base_tiles, r.chips, r.chips_in_cell, r.linked, r.linked_in_cell, r.merged_records, r.merged_groups
        );
        sum.chips_in_cell += r.chips_in_cell;
        sum.linked_in_cell += r.linked_in_cell;
        sum.merged_records += r.merged_records;
        for l in &r.lines {
            report.push_str(&report_line(path, l));
        }
        for m in &r.merges {
            merges.push_str(&format!("{path}\t{m}\n"));
        }
    };
    if let Some(f) = &cfg.tile_file {
        let mut c = Connection::open(f).map_err(|e| format!("{}: {e}", f.display()))?;
        let r = link_tile(&mut c, &pm, &table, cfg.audit, cfg.jobs)?;
        take(&f.display().to_string(), &r, &mut sum);
    } else if let Some(dir) = &cfg.tiles {
        let index_path = dir.join("index.tsv");
        let index = std::fs::read_to_string(&index_path).map_err(|e| format!("{}: {e}", index_path.display()))?;
        let mut lines: BTreeMap<String, [String; 3]> = BTreeMap::new();
        for l in index.lines().filter(|l| !l.is_empty()) {
            let f: Vec<&str> = l.split('\t').collect();
            if f.len() != 4 {
                return Err(format!("{}: bad line {l:?}", index_path.display()));
            }
            lines.insert(f[0].to_string(), [f[1].to_string(), f[2].to_string(), f[3].to_string()]);
        }
        let todo: Vec<String> = lines.keys().filter(|p| cfg.only.as_ref().is_none_or(|o| o.contains(p))).cloned().collect();
        let next = std::sync::atomic::AtomicUsize::new(0);
        type Done = Result<(String, TileReport, [String; 3]), String>;
        let done: Mutex<Vec<Done>> = Mutex::new(Vec::new());
        std::thread::scope(|sc| {
            for _ in 0..cfg.tile_jobs.clamp(1, todo.len().max(1)) {
                sc.spawn(|| loop {
                    let i = next.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                    let Some(path) = todo.get(i) else { return };
                    let one = || -> Done {
                        let gz = dir.join(format!("{path}.sqlite.gz"));
                        let work = dir.join(format!("{path}.sqlite.work"));
                        let mut raw = Vec::new();
                        GzDecoder::new(std::fs::File::open(&gz).map_err(|e| format!("{}: {e}", gz.display()))?).read_to_end(&mut raw).map_err(|e| format!("{}: {e}", gz.display()))?;
                        std::fs::write(&work, &raw).map_err(|e| e.to_string())?;
                        let rep = (|| -> Result<TileReport, String> {
                            let mut c = Connection::open(&work).map_err(|e| e.to_string())?;
                            link_tile(&mut c, &pm, &table, cfg.audit, cfg.jobs)
                        })();
                        let rep = match rep {
                            Ok(r) => r,
                            Err(e) => {
                                let _ = std::fs::remove_file(&work);
                                return Err(format!("{path}: {e}"));
                            }
                        };
                        let bytes = std::fs::read(&work).map_err(|e| e.to_string())?;
                        let _ = std::fs::remove_file(&work);
                        let sha: String = Sha256::digest(&bytes).iter().map(|b| format!("{b:02x}")).collect();
                        let tmp = dir.join(format!("{path}.sqlite.gz.part"));
                        let mut enc = flate2::write::GzEncoder::new(std::fs::File::create(&tmp).map_err(|e| e.to_string())?, flate2::Compression::best());
                        std::io::Write::write_all(&mut enc, &bytes).map_err(|e| e.to_string())?;
                        enc.finish().map_err(|e| e.to_string())?;
                        std::fs::rename(&tmp, &gz).map_err(|e| e.to_string())?;
                        let gzb = std::fs::metadata(&gz).map_err(|e| e.to_string())?.len();
                        Ok((path.clone(), rep, [bytes.len().to_string(), sha, gzb.to_string()]))
                    };
                    done.lock().unwrap().push(one());
                });
            }
        });
        for d in done.into_inner().unwrap() {
            let (path, rep, entry) = d?;
            take(&path, &rep, &mut sum);
            lines.insert(path, entry);
        }
        let mut out = String::new();
        for (p, f) in &lines {
            out.push_str(&format!("{p}\t{}\t{}\t{}\n", f[0], f[1], f[2]));
        }
        std::fs::write(&index_path, out).map_err(|e| format!("{}: {e}", index_path.display()))?;
    } else {
        return Err("--tiles or --tile-file is required".into());
    }
    eprintln!(
        "base map: {} range requests, {:.1} MB read",
        pm.requests.load(std::sync::atomic::Ordering::Relaxed),
        pm.bytes.load(std::sync::atomic::Ordering::Relaxed) as f64 / 1e6
    );
    if let Some(r) = &cfg.report {
        std::fs::write(r, &report).map_err(|e| format!("{}: {e}", r.display()))?;
        std::fs::write(r.with_extension("merges.tsv"), &merges).map_err(|e| e.to_string())?;
    }
    Ok(sum)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chip(name: &str, kind: &str, lat: f64, lon: f64) -> Chip {
        Chip { name: name.into(), name_norm: norm_name(name), kind: kind.into(), lat, lon }
    }

    fn rec(id: i64, name: &str, kind: &str, lat: f64, lon: f64, sid: &str) -> Rec {
        Rec { id, name: name.into(), name_norm: norm_name(name), kind: kind.into(), lat, lon, source: "osm".into(), source_id: sid.into() }
    }

    // Shoshone Falls, Twin Falls ID, as the base map and the pack have it: a waterfall attraction chip (a node, the same point in
    // both), a second attraction node 400 m south, and the park around it (a way: its chip is at the label point, its record at
    // the centre of the outline, 35 m apart).
    fn shoshone() -> (Vec<Chip>, Vec<Rec>) {
        let chips = vec![
            chip("Shoshone Falls", "attraction", 42.596005, -114.402164),
            chip("Shoshone Falls", "park", 42.593015, -114.400560),
            chip("Shoshone Falls", "attraction", 42.593660, -114.401960),
        ];
        let recs = vec![
            rec(1, "Shoshone Falls", "leisure=park", 42.593302, -114.400300, "osm:w121853382"),
            rec(2, "Shoshone Falls", "tourism=attraction", 42.593659, -114.401961, "osm:n1183479286"),
            rec(3, "Shoshone Falls", "tourism=attraction", 42.596006, -114.402162, "osm:n1671534021"),
        ];
        (chips, recs)
    }

    #[test]
    fn the_kind_table_covers_every_chip_kind_and_agrees_by_table_only() {
        let t = KindTable::builtin();
        assert!(t.agrees("attraction", "tourism=attraction"));
        assert!(!t.agrees("attraction", "leisure=park"));
        assert!(!t.agrees("park", "tourism=attraction"));
        assert_eq!(t.class_of("shop=chemist"), Some("pharmacy"));
        assert_eq!(t.class_of("amenity=pharmacy"), Some("pharmacy"));
        assert_ne!(t.class_of("amenity=fuel"), t.class_of("shop=convenience"));
        assert!(KindTable::parse("tile_kind\tclass\tosm_tags\na\tb\tx=y\na\tb\tx=y\n").is_err(), "a tile kind twice");
    }

    #[test]
    fn shoshone_falls_the_waterfall_and_the_park_stay_two_records_each_with_its_own_chip() {
        let t = KindTable::builtin();
        let (chips, recs) = shoshone();
        let f = assign(&t, &chips, &recs);
        // The attraction chip at the falls is the OSM node of the falls, the park chip is the park, the other attraction its node.
        assert_eq!(f[0], Fate::Linked(2));
        assert_eq!(f[1], Fate::Linked(0));
        assert_eq!(f[2], Fate::Linked(1));
        assert!(duplicate_groups(&t, &recs).is_empty(), "a park and an attraction are not duplicates");
    }

    #[test]
    fn a_kind_mismatch_is_refused_even_when_name_and_point_agree() {
        let t = KindTable::builtin();
        let chips = vec![chip("Shoshone Falls", "attraction", 42.593302, -114.400300)];
        let recs = vec![rec(1, "Shoshone Falls", "leisure=park", 42.593302, -114.400300, "osm:w121853382")];
        let f = assign(&t, &chips, &recs);
        match &f[0] {
            Fate::Unlinked(why) => assert!(why.contains("another kind"), "{why}"),
            x => panic!("a park answered an attraction chip: {x:?}"),
        }
    }

    #[test]
    fn no_match_when_nothing_has_the_name_or_the_record_is_too_far() {
        let t = KindTable::builtin();
        let recs = vec![rec(1, "Sav-Mor Drug Store", "shop=variety_store", 42.5700, -114.4600, "osm:n1")];
        let f = assign(&t, &[chip("Kelly's Diner", "restaurant", 42.57, -114.46)], &recs);
        assert!(matches!(&f[0], Fate::Unlinked(w) if w.contains("no record with this name")));
        let f = assign(&t, &[chip("Sav Mor Drug Store", "variety_store", 42.5704, -114.4600)], &recs);
        assert!(matches!(&f[0], Fate::Unlinked(w) if w.contains("m away")), "a node 44 m from its chip is too far: {f:?}");
        let f = assign(&t, &[chip("Sav Mor Drug Store", "variety_store", 42.57001, -114.4600)], &recs);
        assert_eq!(f[0], Fate::Linked(0), "name matches by case, punctuation and spacing only");
    }

    #[test]
    fn two_chips_of_one_name_each_take_their_own_nearest_record() {
        let t = KindTable::builtin();
        let recs = vec![rec(1, "Starbucks", "amenity=cafe", 42.5600, -114.4600, "osm:n1"), rec(2, "Starbucks", "amenity=cafe", 42.5800, -114.4600, "osm:n2")];
        let chips = vec![chip("Starbucks", "cafe", 42.5800, -114.4600), chip("Starbucks", "cafe", 42.5600, -114.4600)];
        let f = assign(&t, &chips, &recs);
        assert_eq!(f, vec![Fate::Linked(1), Fate::Linked(0)]);
        // A chip whose record is missing does not take the other store's: that one belongs to its own, nearer chip.
        let f = assign(&t, &[chip("Starbucks", "cafe", 42.5800, -114.4600), chip("Starbucks", "cafe", 42.5790, -114.4600)], &recs[1..]);
        assert_eq!(f[0], Fate::Linked(0));
        assert!(matches!(&f[1], Fate::Unlinked(w) if w.contains("m away") || w.contains("nearer chip")), "{f:?}");
    }

    #[test]
    fn a_true_duplicate_is_found_and_different_places_are_not() {
        let t = KindTable::builtin();
        // Walgreens mapped twice: a shop=chemist way and an amenity=pharmacy node 18 m apart: one place.
        let walgreens = vec![rec(1, "Walgreens", "shop=chemist", 42.5700, -114.4600, "osm:w782317651"), rec(2, "Walgreens", "amenity=pharmacy", 42.57016, -114.4600, "osm:n11948593432")];
        assert_eq!(duplicate_groups(&t, &walgreens), vec![vec![0, 1]]);
        // "Stinker" the fuel station and "Stinker" the convenience store beside it: two places.
        let stinker = vec![rec(1, "Stinker", "shop=convenience", 42.5700, -114.4600, "osm:w935068125"), rec(2, "Stinker", "amenity=fuel", 42.57002, -114.4600, "osm:w935068124")];
        assert!(duplicate_groups(&t, &stinker).is_empty());
        // The same chain's other store, 3 km away: a different place.
        let two = vec![rec(1, "Walgreens", "shop=chemist", 42.5700, -114.4600, "osm:w1"), rec(2, "Walgreens", "shop=chemist", 42.5970, -114.4600, "osm:w2")];
        assert!(duplicate_groups(&t, &two).is_empty());
    }

    #[test]
    fn the_merged_record_has_the_best_details_of_both() {
        let cols: Vec<String> = ["id", "name", "alt_names", "kind", "phone", "website", "hours", "summary", "source", "source_id", "confidence"].iter().map(|s| s.to_string()).collect();
        let t = |s: &str| Value::Text(s.into());
        let a = vec![Value::Integer(10), t("Walgreens"), Value::Null, t("shop=chemist"), Value::Null, Value::Null, Value::Null, Value::Null, t("osm"), t("osm:w1"), Value::Null];
        let b = vec![Value::Integer(11), t("Walgreens Pharmacy"), Value::Null, t("amenity=pharmacy"), t("+1 208 555 0100"), t("https://example.org"), t("Mo-Su 08:00-22:00"), Value::Null, t("osm+overture"), t("osm:n2"), Value::Real(0.9)];
        let (best, m) = merge_group(&cols, &[&a, &b]);
        assert_eq!(best, 1, "the record with more details survives");
        assert_eq!(m[9], t("osm:n2"));
        assert_eq!(m[4], t("+1 208 555 0100"));
        assert_eq!(m[2], t("Walgreens"), "the other name is kept as an alternate");
        assert_eq!(m[8], t("osm+overture"));
        let (best, m) = merge_group(&cols, &[&b, &a]);
        assert_eq!(best, 0);
        assert_eq!(m[9], t("osm:n2"));
    }

    #[test]
    fn a_tile_is_linked_deduplicated_and_counted_end_to_end() {
        use cache_places::schema::{TILE_SCHEMA, TILE_SQL};
        let t = KindTable::builtin();
        let mut c = Connection::open_in_memory().unwrap();
        c.execute_batch(TILE_SQL).unwrap();
        c.execute("INSERT INTO meta VALUES ('tile', '47585'), ('tile_schema', ?1), ('counts', '{\"places\":4}')", params![TILE_SCHEMA.to_string()]).unwrap();
        let ins = "INSERT INTO places(id, name, category, kind, kind_id, lat, lon, phone, summary, source, source_id) VALUES (?1, ?2, 'pharmacy', ?3, ?4, ?5, ?10, ?6, ?7, ?8, ?9)";
        c.execute(ins, params![1, "Walgreens", "shop=chemist", "chemist", 42.5700, None::<String>, None::<String>, "osm", "osm:w1", -114.46]).unwrap();
        c.execute(ins, params![2, "Walgreens", "amenity=pharmacy", "pharmacy", 42.57016, "+1 208 555 0100", None::<String>, "osm", "osm:n2", -114.46]).unwrap();
        c.execute(ins, params![3, "Shoshone Falls", "leisure=park", "park", 42.593302, None::<String>, None::<String>, "osm", "osm:w3", -114.4003]).unwrap();
        c.execute(ins, params![4, "Shoshone Falls", "tourism=attraction", "attraction", 42.596006, None::<String>, "A waterfall.", "osm+overture", "osm:n4", -114.402162]).unwrap();
        c.execute("INSERT INTO vectors VALUES ('place', 1, x'01'), ('place', 4, x'02')", []).unwrap();
        c.execute("INSERT INTO tile_counts VALUES ('category', 'pharmacy', 4), ('kind', 'chemist', 1), ('kind', 'pharmacy', 1), ('kind', 'park', 1), ('kind', 'attraction', 1)", []).unwrap();
        let chips = vec![
            chip("Walgreens", "chemist", 42.57001, -114.46),
            chip("Walgreens", "pharmacy", 42.57016, -114.46),
            chip("Shoshone Falls", "attraction", 42.596005, -114.402164),
            chip("Shoshone Falls", "park", 42.593015, -114.4003),
            chip("Nowhere Cafe", "cafe", 42.58, -114.45),
        ];
        let rep = link_tile_with(&mut c, &t, "test.pmtiles", None, |_| Ok(chips)).unwrap();
        assert_eq!((rep.chips, rep.linked, rep.merged_records), (5, 4, 1));
        // Both Walgreens chips link to the one record that is left, the one with the phone number.
        let n: i64 = c.query_row("SELECT COUNT(*) FROM places WHERE name = 'Walgreens'", [], |r| r.get(0)).unwrap();
        assert_eq!(n, 1);
        let sid: String = c.query_row("SELECT source_id FROM places WHERE name = 'Walgreens'", [], |r| r.get(0)).unwrap();
        assert_eq!(sid, "osm:n2");
        let to_it: i64 = c.query_row("SELECT COUNT(*) FROM poi_links WHERE name_norm = 'walgreens' AND source_id = 'osm:n2'", [], |r| r.get(0)).unwrap();
        assert_eq!(to_it, 2);
        // The waterfall chip is the attraction and the park chip the park (the Shoshone case).
        let link = |kind: &str| -> String { c.query_row("SELECT source_id FROM poi_links WHERE name_norm = 'shoshone falls' AND kind = ?1", params![kind], |r| r.get(0)).unwrap() };
        assert_eq!((link("attraction").as_str(), link("park").as_str()), ("osm:n4", "osm:w3"));
        // The chip with no record has no row; the loser's vector moved to the survivor; the counts follow the rows.
        let none: i64 = c.query_row("SELECT COUNT(*) FROM poi_links WHERE name_norm = 'nowhere cafe'", [], |r| r.get(0)).unwrap();
        assert_eq!(none, 0);
        let vec2: i64 = c.query_row("SELECT COUNT(*) FROM vectors WHERE kind = 'place' AND ref = 2", [], |r| r.get(0)).unwrap();
        assert_eq!(vec2, 1);
        let kinds: i64 = c.query_row("SELECT COUNT(*) FROM tile_counts WHERE what = 'kind' AND id = 'chemist'", [], |r| r.get(0)).unwrap();
        assert_eq!(kinds, 0, "the merged-away record no longer counts");
        let counts: String = c.query_row("SELECT value FROM meta WHERE key = 'counts'", [], |r| r.get(0)).unwrap();
        assert!(counts.contains("\"places\":3"), "{counts}");
        assert!(rep.lines.iter().any(|l| l.name == "Nowhere Cafe" && l.record.is_none() && l.reason.contains("no record")));
    }

    #[test]
    fn mercator_tiles_and_points_round_trip() {
        let (x, y) = tile_of(15, 42.596, -114.4022);
        let (lat, lon) = point_of(15, x, y, 0.0, 0.0, 4096.0);
        let (lat2, lon2) = point_of(15, x + 1, y + 1, 0.0, 0.0, 4096.0);
        assert!(lat >= 42.596 && lat2 <= 42.596 && lon <= -114.4022 && lon2 >= -114.4022);
        assert_eq!(zxy_to_id(0, 0, 0), 0);
        assert_eq!(zxy_to_id(1, 0, 0), 1);
        assert_eq!(zxy_to_id(1, 1, 1), 3);
    }
}
