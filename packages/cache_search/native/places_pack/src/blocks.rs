//! `places_pack blocks`: the harvest cut into blocks of Valhalla level 0 (4 degree cells, 16 level 1 tiles each), each
//! built with the one-region pipeline (`build::process`: merge, emergency rooms, dedupe, states, nearest town) over the
//! block plus a halo, then written as a format 2 pack holding only the rows of the block's own cells.
//!
//! The halo (0.25 degrees by default) is there only so that merges, emergency-room matches and the nearest town come out
//! right at a block's edge: a row in the halo is dropped at the end, so every row is written once, by the block whose cell
//! holds it. Both blocks of an edge see the rows near it in the same order (the harvest's), so they decide a merge or a
//! dedupe across it the same way.
//!
//! Block files are `<out>/<level 0 id>.sqlite`; meta adds `block` (the level 0 id), `cells` (JSON list of the level 1
//! tiles it holds) and `halo`. The `wiki` and `embed` steps run on them as on any pack; `cut` writes the tiles from them.

use crate::admins::Admins;
use crate::build::{process, write_pack};
use crate::harvest;
use crate::rules::Rules;
use cache_places::schema::{tile_id_l1, tile_rect_l1};
use rusqlite::{Connection, OpenFlags};
use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;
use std::time::Instant;

/// Level 0: 4 degree cells, 90 columns.
pub const L0_DEG: f64 = 4.0;
const L0_COLUMNS: u32 = 90;

/// The level 0 cell that holds a level 1 tile.
pub fn block_of_tile(tile: u32) -> u32 {
    let (row, col) = (tile / 360, tile % 360);
    (row / 4) * L0_COLUMNS + col / 4
}

/// A level 0 cell: [west, south, east, north].
pub fn block_rect(block: u32) -> [f64; 4] {
    let (w, s) = (-180.0 + (block % L0_COLUMNS) as f64 * L0_DEG, -90.0 + (block / L0_COLUMNS) as f64 * L0_DEG);
    [w, s, w + L0_DEG, s + L0_DEG]
}

/// The level 1 tiles whose cells overlap `bbox` [west, south, east, north] (an edge alone is not an overlap).
pub fn tiles_in(bbox: [f64; 4]) -> BTreeSet<u32> {
    let mut out = BTreeSet::new();
    let (r0, r1) = (((bbox[1] + 90.0).floor() as i64).max(0), ((bbox[3] + 90.0).ceil() as i64 - 1).min(179));
    let (c0, c1) = (((bbox[0] + 180.0).floor() as i64).max(0), ((bbox[2] + 180.0).ceil() as i64 - 1).min(359));
    for r in r0..=r1 {
        for c in c0..=c1 {
            out.insert((r * 360 + c) as u32);
        }
    }
    out
}

pub fn parse_bbox(s: &str) -> Result<[f64; 4], String> {
    let v: Vec<f64> = s.split(',').map(|x| x.trim().parse::<f64>()).collect::<Result<_, _>>().map_err(|_| format!("bad box {s:?}: want W,S,E,N"))?;
    match v[..] {
        [w, s, e, n] if w < e && s < n => Ok([w, s, e, n]),
        _ => Err(format!("bad box {s:?}: want W,S,E,N")),
    }
}

pub struct BlocksCfg {
    pub harvest: PathBuf,
    pub admins: PathBuf,
    pub out: PathBuf,
    /// Only the level 1 tiles overlapping this box (None: every tile with data).
    pub bbox: Option<[f64; 4]>,
    pub halo: f64,
    pub jobs: usize,
    pub country: String,
}

pub struct BlockReport {
    pub block: u32,
    pub cells: usize,
    pub places: usize,
    pub localities: usize,
    /// Places loaded, the halo's included.
    pub loaded: usize,
    pub merged: usize,
    pub deduped: usize,
    pub enriched: usize,
    /// Places of the block's own cells with an arrival point.
    pub arrivals: usize,
    pub seconds: f64,
}

fn build_block(cfg: &BlocksCfg, rules: &Rules, rules_json: &str, sources: &str, h: &Connection, admins: &mut Admins, block: u32, cells: &BTreeSet<u32>) -> Result<BlockReport, String> {
    let t = Instant::now();
    let r = block_rect(block);
    let (places, locs, anchors) = harvest::load(h, [r[0] - cfg.halo, r[1] - cfg.halo, r[2] + cfg.halo, r[3] + cfg.halo])?;
    let loaded = places.len();
    let mut p = process(places, locs, &anchors, rules, admins, &cfg.country, false);
    let mine = |lat: f64, lon: f64| cells.contains(&tile_id_l1(lat, lon));
    p.retain_places(|r, _| mine(r.lat, r.lon));
    p.retain_localities(|l| mine(l.lat, l.lon));
    let (mut w, mut s, mut e, mut n) = (f64::MAX, f64::MAX, f64::MIN, f64::MIN);
    for &c in cells {
        let b = tile_rect_l1(c);
        (w, s, e, n) = (w.min(b[0]), s.min(b[1]), e.max(b[2]), n.max(b[3]));
    }
    let out = cfg.out.join(format!("{block}.sqlite"));
    write_pack(
        &out,
        &p,
        rules,
        rules_json,
        &[
            ("region_id", format!("block-{block}")),
            ("region_name", format!("Level 0 block {block}")),
            ("min_lat", s.to_string()),
            ("min_lon", w.to_string()),
            ("max_lat", n.to_string()),
            ("max_lon", e.to_string()),
            ("sources", sources.to_string()),
            ("block", block.to_string()),
            ("cells", serde_json::to_string(&cells.iter().collect::<Vec<_>>()).unwrap_or_default()),
            ("halo", cfg.halo.to_string()),
        ],
    )?;
    Ok(BlockReport {
        block,
        cells: cells.len(),
        places: p.rows.len(),
        localities: p.locs.len(),
        loaded,
        merged: p.merged,
        deduped: p.deduped,
        enriched: p.enriched,
        arrivals: p.rows.iter().filter(|r| r.arrival.is_some()).count(),
        seconds: t.elapsed().as_secs_f64(),
    })
}

/// Builds every block that holds a selected tile with data, `cfg.jobs` at a time. Returns one report per block, in
/// block order.
pub fn blocks(cfg: &BlocksCfg, rules: &Rules, rules_json: &str) -> Result<Vec<BlockReport>, String> {
    std::fs::create_dir_all(&cfg.out).map_err(|e| format!("{}: {e}", cfg.out.display()))?;
    let open = |p: &Path| Connection::open_with_flags(p, OpenFlags::SQLITE_OPEN_READ_ONLY).map_err(|e| format!("{}: {e}", p.display()));
    let h = open(&cfg.harvest)?;
    let sources: String = h.query_row("SELECT value FROM meta WHERE key = 'sources'", [], |r| r.get(0)).unwrap_or_default();
    let selected = cfg.bbox.map(tiles_in);
    let mut work: BTreeMap<u32, BTreeSet<u32>> = BTreeMap::new();
    for t in harvest::tiles(&h)? {
        if selected.as_ref().is_none_or(|s| s.contains(&t)) {
            work.entry(block_of_tile(t)).or_default().insert(t);
        }
    }
    drop(h);
    let work: Vec<(u32, BTreeSet<u32>)> = work.into_iter().collect();
    eprintln!("{} blocks, {} tiles, {} at a time", work.len(), work.iter().map(|w| w.1.len()).sum::<usize>(), cfg.jobs);
    let next = AtomicUsize::new(0);
    let done: Mutex<Vec<Result<BlockReport, String>>> = Mutex::new(Vec::new());
    std::thread::scope(|sc| {
        for _ in 0..cfg.jobs.clamp(1, work.len().max(1)) {
            sc.spawn(|| {
                let run = || -> Result<(), String> {
                    let h = open(&cfg.harvest)?;
                    let mut admins = Admins::load(&cfg.admins)?;
                    loop {
                        let i = next.fetch_add(1, Ordering::SeqCst);
                        let Some((b, cells)) = work.get(i) else { return Ok(()) };
                        let r = build_block(cfg, rules, rules_json, &sources, &h, &mut admins, *b, cells).map_err(|e| format!("block {b}: {e}"));
                        if let Ok(r) = &r {
                            eprintln!(
                                "block {:>5}: {:>2} tiles, {:>7} places of {} loaded with the halo, {:>5} towns ({} merged, {} deduped, {} ERs, {} arrival points) in {:.1} s",
                                r.block, r.cells, r.places, r.loaded, r.localities, r.merged, r.deduped, r.enriched, r.arrivals, r.seconds
                            );
                        }
                        done.lock().unwrap().push(r);
                    }
                };
                if let Err(e) = run() {
                    done.lock().unwrap().push(Err(e));
                }
            });
        }
    });
    let mut out = Vec::new();
    for r in done.into_inner().unwrap() {
        out.push(r?);
    }
    out.sort_by_key(|r| r.block);
    Ok(out)
}

/// The block files in `dir`, by level 0 id.
pub fn block_files(dir: &Path) -> Result<Vec<(u32, PathBuf)>, String> {
    let mut v = Vec::new();
    for e in std::fs::read_dir(dir).map_err(|e| format!("{}: {e}", dir.display()))? {
        let p = e.map_err(|e| e.to_string())?.path();
        if let Some(b) = p.file_name().and_then(|n| n.to_str()).and_then(|n| n.strip_suffix(".sqlite")).and_then(|n| n.parse::<u32>().ok()) {
            v.push((b, p));
        }
    }
    v.sort();
    Ok(v)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grid() {
        // Salt Lake City's tile is in the block that covers 112-108 W, 38-42 N.
        let slc = tile_id_l1(40.76, -111.89);
        assert_eq!(block_rect(block_of_tile(slc)), [-112.0, 38.0, -108.0, 42.0]);
        assert_eq!(block_of_tile(tile_id_l1(40.76, -112.01)), block_of_tile(slc) - 1);
        let t = tiles_in([-115.0, 37.0, -109.0, 42.0]);
        assert_eq!(t.len(), 30);
        assert!(t.contains(&slc) && t.contains(&tile_id_l1(37.0, -115.0)) && !t.contains(&tile_id_l1(42.0, -112.0)));
        assert_eq!(parse_bbox("-115,37,-109,42").unwrap(), [-115.0, 37.0, -109.0, 42.0]);
        assert!(parse_bbox("1,2,0,3").is_err());
    }
}
