//! A region's pre-cut map file: one PMTiles archive cut from the layer's planet file to the region's outline, published with
//! its size and SHA-256 in the region list (`basemap_file`). When a download names one and it was cut from the planet build
//! the layer reads now, the file is fetched whole (resumed with Range requests from a partial file kept under a hidden name,
//! renamed when its SHA-256 checks), and the tiles of it that the area needs and the device does not hold yet are copied into
//! the layer's store at the layer's version, so the map, the delete rule and the overlap rule work as for any download. The
//! file is deleted after the copy. What the area needs and the file does not hold is then read from the planet as before.
//!
//! Anything wrong with the file (none published, a 404, a failed check, another planet build, too little space for the file
//! and its tiles) is logged once and the download reads the planet by ranges, as it did before files existed.

use super::{AreaReq, Done, Prepared};
use crate::core::Inner;
use crate::error::{available_bytes, Error, Result};
use crate::http::{self, FileGot};
use crate::pmtiles::Reader;
use crate::store::{Store, Table};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Mutex, OnceLock};

/// The region list's `basemap_file` of a region: where its pre-cut map file is, its size and SHA-256, and the planet build
/// (the layer's `update.version`) it was cut from.
#[derive(Debug, Clone, PartialEq)]
pub struct RegionFile {
    pub url: String,
    pub bytes: u64,
    pub sha256: String,
    pub planet: String,
}

impl RegionFile {
    /// The file from its JSON; `None` for anything that is not a usable entry (a missing field, a SHA-256 that is not 64 hex
    /// digits, no bytes), which downloads as if there were no file.
    pub fn from_value(v: &Value) -> Option<RegionFile> {
        let s = |k: &str| v.get(k).and_then(Value::as_str).map(str::trim).filter(|s| !s.is_empty()).map(String::from);
        let f = RegionFile { url: s("url")?, bytes: v.get("bytes")?.as_u64()?, sha256: s("sha256")?.to_ascii_lowercase(), planet: s("planet")? };
        (f.bytes > 0 && f.sha256.len() == 64 && f.sha256.bytes().all(|b| b.is_ascii_hexdigit())).then_some(f)
    }
}

/// The folder (under the engine's folder) region files are fetched into.
const FILES_DIR: &str = "region-files";

/// Tiles copied from the file per transaction (and per progress report).
const IMPORT_BATCH: usize = 1024;

/// The share of the part's progress the fetch of the file takes; the copy of its tiles takes the rest.
const FETCH_SHARE: f64 = 0.9;

/// A file left in the folder this long (a download stopped and never carried on, from a region since removed) is deleted.
const KEEP_LEFTOVERS: std::time::Duration = std::time::Duration::from_secs(2 * 24 * 3600);

/// A tile (z, x, y), and (offset, length) of its bytes in an archive's tile data.
type Zxy = (u8, u32, u32);
type Span = (u64, u32);

enum FromFile {
    /// The tiles of the file were copied; what the area needs beyond them comes by ranges.
    Copied { total: u64, file_bytes: u64 },
    /// Nothing to do with a file (nothing to fetch): the download goes on as it is.
    Plain,
    /// The file is not used, for this reason (logged once); the download reads by ranges.
    NotUsed(String),
    Cancelled,
}

/// The files being fetched in this process (by SHA-256): a second download of the same file at the same time reads by ranges.
fn busy() -> &'static Mutex<HashSet<String>> {
    static B: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    B.get_or_init(Default::default)
}

struct Busy(String);

impl Busy {
    fn take(sha: &str) -> Option<Busy> {
        busy().lock().unwrap_or_else(|e| e.into_inner()).insert(sha.to_string()).then(|| Busy(sha.to_string()))
    }
}

impl Drop for Busy {
    fn drop(&mut self) {
        busy().lock().unwrap_or_else(|e| e.into_inner()).remove(&self.0);
    }
}

/// One line in the log per file and reason, however often the download is started again. There is no logging crate in the
/// core; the other crates print like this. The address is left out (only its last part, the file's name).
fn log_once(f: &RegionFile, why: &str) {
    static SEEN: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();
    let key = format!("{} {why}", f.sha256);
    if SEEN.get_or_init(Default::default).lock().unwrap_or_else(|e| e.into_inner()).insert(key) {
        let name = f.url.rsplit('/').next().unwrap_or("");
        eprintln!("cache_layers: the region map file {name} is not used, the map downloads by range reads: {why}");
    }
}

fn sha256_of(path: &Path) -> Result<String> {
    let mut f = std::fs::File::open(path).map_err(|e| crate::error::io_at("opening", path, e))?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1024 * 1024];
    loop {
        let n = f.read(&mut buf).map_err(|e| crate::error::io_at("reading", path, e))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// Deletes files of the folder not touched for [KEEP_LEFTOVERS] that no download is fetching now.
fn sweep(folder: &Path) {
    let Ok(rd) = std::fs::read_dir(folder) else { return };
    let busy = busy().lock().unwrap_or_else(|e| e.into_inner()).clone();
    for e in rd.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if busy.iter().any(|b| name.contains(b.as_str())) {
            continue;
        }
        let old = e.metadata().and_then(|m| m.modified()).ok().and_then(|t| t.elapsed().ok()).is_some_and(|age| age > KEEP_LEFTOVERS);
        if old {
            let _ = std::fs::remove_file(e.path());
        }
    }
}

impl Inner {
    /// [`Inner::run_download`], with the area's pre-cut file when the request names one (see the module's comment). `progress`
    /// counts the same tiles as without a file: the fetch of the file moves it, then the copy of its tiles, then whatever
    /// the area needs beyond them, and never goes back; "bytes" counts the file and then what is read by ranges.
    pub fn run_download_with_file(&self, req: &AreaReq, file: Option<&RegionFile>, progress: &dyn Fn(u64, u64, Value), cancelled: &(dyn Fn() -> bool + Sync)) -> Result<Done> {
        let Some(f) = file else { return self.run_download(req, progress, cancelled) };
        // never back: the copy can end below where the fetch of the file reached when the file holds less than the area needs
        let shown = AtomicU64::new(0);
        let report = |d: u64, t: u64, detail: Value| progress(shown.fetch_max(d, Ordering::SeqCst).max(d), t, detail);
        let (total, file_bytes) = match self.fetch_from_file(req, f, &report, cancelled) {
            Ok(FromFile::Copied { total, file_bytes }) => (total, file_bytes),
            Ok(FromFile::Cancelled) => return Ok(Done::Cancelled),
            Ok(FromFile::Plain) => return self.run_download(req, progress, cancelled),
            Ok(FromFile::NotUsed(why)) => {
                log_once(f, &why);
                return self.run_download(req, progress, cancelled);
            }
            Err(e) => {
                log_once(f, &e.to_string());
                return self.run_download(req, progress, cancelled);
            }
        };
        // What the file did not hold, by ranges: its tiles count after the file's, out of the same total.
        self.run_download(
            req,
            &|d, t, mut detail| {
                let d = d + total.saturating_sub(t);
                let b = detail.get("bytes").and_then(Value::as_u64).unwrap_or(0) + file_bytes;
                detail["bytes"] = json!(b);
                report(d, total.max(t), detail)
            },
            cancelled,
        )
    }

    fn fetch_from_file(&self, req: &AreaReq, f: &RegionFile, progress: &dyn Fn(u64, u64, Value), cancelled: &(dyn Fn() -> bool + Sync)) -> Result<FromFile> {
        let p = self.prepare(req)?;
        if p.src.kind != "pmtiles" {
            return Ok(FromFile::NotUsed("the layer is not read from a PMTiles archive".into()));
        }
        let ver = p.base.version().to_string();
        if f.planet != ver {
            return Ok(FromFile::NotUsed(format!("it was cut from planet build {:?}, the layer reads {ver:?}", f.planet)));
        }
        if let Some(top) = p.src.maxzoom {
            if p.zmax < top {
                // the file holds every zoom to the layer's top; an area stepped down to fewer zooms is less by ranges
                return Ok(FromFile::NotUsed(format!("the area stops at zoom {} and the file goes to {top}", p.zmax)));
            }
        }
        if !crate::def::url_ok(&f.url) {
            return Ok(FromFile::NotUsed("its address is not https".into()));
        }
        if p.need.is_empty() {
            return Ok(FromFile::Plain);
        }
        if !self.is_online() {
            return Err(Error::offline("the file needs a connection"));
        }
        let Some(_busy) = Busy::take(&f.sha256) else {
            return Ok(FromFile::NotUsed("another download is fetching it".into()));
        };
        let folder = self.dir.join(FILES_DIR);
        std::fs::create_dir_all(&folder).map_err(|e| crate::error::io_at("creating", &folder, e))?;
        sweep(&folder);
        let whole: PathBuf = folder.join(format!("{}.pmtiles", f.sha256));
        let part: PathBuf = folder.join(format!(".{}.pmtiles.part", f.sha256));
        if !whole.is_file() {
            // room for the rest of the file and for its tiles in the store, which it is deleted after
            let have = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0).min(f.bytes);
            let needed = (f.bytes - have) + f.bytes + f.bytes / 10 + 8 * 1024 * 1024;
            if let Ok(free) = available_bytes(&folder) {
                if needed > free {
                    return Ok(FromFile::NotUsed(format!("it needs about {needed} bytes free, {free} available")));
                }
            }
        }
        // The planet's own reader: its tiles' type and compression are what the store holds for this layer.
        let planet = self.download_pmtiles(&p.dl, &p.src.url)?;
        let store = self.store_create(&p.base.id)?;
        if p.existing.is_none() {
            // the area is recorded before any tile of it is stored, as a download by ranges does
            let name = p.req.name.clone().unwrap_or_else(|| p.area.clone());
            let meta = json!({
                "id": p.area, "name": name, "layer": p.base.id, "bbox": p.req.bounds()?, "polygon": p.req.polygon, "minzoom": p.zmin,
                "maxzoom": p.zmax, "version": ver, "tiles_requested": p.cover.len(), "source": p.src.url,
            });
            store.put_area(&p.area, "partial", &meta)?;
        }
        let total = p.need.len() as u64;
        let upto = (total as f64 * FETCH_SHARE) as u64;
        progress(0, total, json!({"bytes": 0}));
        if !whole.is_file() {
            let mut each = |have: u64| progress(upto * have / f.bytes, total, json!({"bytes": have}));
            match http::fetch_to_file(&f.url, &part, f.bytes, &mut each, cancelled)? {
                FileGot::Cancelled => return Ok(FromFile::Cancelled),
                FileGot::NotThere => {
                    let _ = std::fs::remove_file(&part);
                    return Ok(FromFile::NotUsed("the host has no such file".into()));
                }
                FileGot::Whole => {}
            }
            let sum = sha256_of(&part)?;
            if sum != f.sha256 {
                let _ = std::fs::remove_file(&part);
                return Ok(FromFile::NotUsed(format!("its SHA-256 is {sum}, the list gives {}", f.sha256)));
            }
            std::fs::rename(&part, &whole).map_err(|e| crate::error::io_at("renaming", &part, e))?;
        }
        match self.copy_tiles(&p, &store, &whole, &planet.header, &ver, (upto, total, f.bytes), progress, cancelled) {
            Ok(true) => {
                let _ = std::fs::remove_file(&whole);
                Ok(FromFile::Copied { total, file_bytes: f.bytes })
            }
            // stopped part way: the file stays, so carrying on copies the rest of it without fetching it again
            Ok(false) => Ok(FromFile::Cancelled),
            Err(e) => {
                let _ = std::fs::remove_file(&whole);
                Ok(FromFile::NotUsed(format!("its tiles could not be copied: {e}")))
            }
        }
    }

    /// Copies the tiles of the file at `path` that the area needs (`p.need`) into the store, at version `ver` (into the
    /// staging table for an update, which the download swaps in when complete). `(from, total, file_bytes)`: where the part's
    /// progress stands and its total. False when cancelled part way (what was copied stays).
    #[allow(clippy::too_many_arguments)]
    fn copy_tiles(&self, p: &Prepared, store: &Store, path: &Path, planet: &crate::pmtiles::Header, ver: &str, (from, total, file_bytes): (u64, u64, u64), progress: &dyn Fn(u64, u64, Value), cancelled: &(dyn Fn() -> bool + Sync)) -> Result<bool> {
        let r = Reader::open_file(path)?;
        if (r.header.tile_type, r.header.tile_compression) != (planet.tile_type, planet.tile_compression) {
            return Err(Error::bad_response(format!(
                "its tiles are type {} compression {}, the planet's type {} compression {}",
                r.header.tile_type, r.header.tile_compression, planet.tile_type, planet.tile_compression
            )));
        }
        // The file's tiles and the area's, both in tile id order, side by side.
        let entries = r.all_tiles()?;
        let mut need: Vec<(u64, u8, u32, u32)> = p.need.clone();
        if !need.windows(2).all(|w| w[0].0 <= w[1].0) {
            need.sort_unstable();
        }
        // each tile to copy, and where its bytes are in the file
        let mut want: Vec<(Zxy, Span)> = Vec::new();
        let mut i = 0;
        for t in &need {
            while i < entries.len() && entries[i].0 < t.0 {
                i += 1;
            }
            if i < entries.len() && entries[i].0 == t.0 {
                want.push(((t.1, t.2, t.3), (entries[i].1, entries[i].2)));
            }
        }
        let updating = p.mode == "update";
        let table = if updating { Table::Staging } else { Table::Tiles };
        if updating {
            store.staging_keep_only(ver)?;
        }
        let span = total.saturating_sub(from);
        let n = want.len().max(1) as u64;
        let mut copied = 0u64;
        for chunk in want.chunks(IMPORT_BATCH) {
            if cancelled() {
                return Ok(false);
            }
            let ranges: Vec<(u64, u32)> = chunk.iter().map(|w| w.1).collect();
            let data = r.read_ranges(&ranges)?;
            let rows: Vec<(u8, u32, u32, Vec<u8>)> = chunk.iter().zip(data).map(|(w, d)| (w.0 .0, w.0 .1, w.0 .2, d)).collect();
            store.put_batch(table, &rows, ver)?;
            copied += chunk.len() as u64;
            progress(from + span * copied / n, total, json!({"bytes": file_bytes}));
        }
        Ok(true)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_region_file_entry_is_read_only_when_every_field_is_usable() {
        let sha = "ab".repeat(32);
        let ok = json!({"url": "https://example.org/r.pmtiles", "bytes": 10, "sha256": sha.to_uppercase(), "planet": "20261025"});
        let f = RegionFile::from_value(&ok).unwrap();
        assert_eq!(f.sha256, sha, "lower case");
        assert_eq!(f.planet, "20261025");
        for bad in [
            json!({"url": "https://example.org/r.pmtiles", "bytes": 10, "sha256": sha, "planet": ""}),
            json!({"url": "https://example.org/r.pmtiles", "bytes": 0, "sha256": sha, "planet": "1"}),
            json!({"url": "https://example.org/r.pmtiles", "bytes": 10, "sha256": "abc", "planet": "1"}),
            json!({"url": "https://example.org/r.pmtiles", "bytes": "10", "sha256": sha, "planet": "1"}),
            json!({"bytes": 10, "sha256": sha, "planet": "1"}),
            json!("https://example.org/r.pmtiles"),
            json!(null),
        ] {
            assert_eq!(RegionFile::from_value(&bad), None, "{bad}");
        }
    }
}
