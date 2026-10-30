//! Road routing by region: the Valhalla tiles of the regions a person downloads, and of the routes they plan online.
//!
//! The routing server publishes one build of North America's road tiles as one file per tile (docs/REGIONS.md): `current.json`
//! names the build and its index, the index lists every tile with roads (size, SHA-256, size gzipped), and each tile is
//! `<build>/<path>.gph.gz`. Valhalla's tiling is fixed, so the tiles a region needs are worked out here from its outline
//! (geo.rs) and looked up in the index; nothing is cut on the server for a region. Tiles of one build fit together, so the
//! tiles of every region on the device, in one folder laid out the way Valhalla reads a tile folder (`mjolnir.tile_dir`),
//! route as one map. Regions that overlap share their tiles.
//!
//! A region is downloaded on a background thread, a few tiles at a time; each tile is unpacked, checked against the index,
//! written under a hidden name, flushed and renamed into place, so a tile in the folder is always whole and a download cut off
//! carries on from the tiles already there. Routes planned online fetch the tiles near their points first (`stream`), kept in
//! a cache with a size cap that never touches a downloaded region's tiles. An update downloads every region's tiles of the
//! new build into a folder of its own and switches over only when all of them are there; builds are never mixed.
//!
//! A region can also have places (`places.rs`, docs/PLACES-TILES.md): places, towns and addresses published the same way on
//! their own address, merged on the phone into one database that every search reads. Each part has its own build, index,
//! update and stream cache; neither waits for the other.
//!
//! [`Regions::call`] is the whole interface (JSON in, JSON out), the same one the C ABI (`cs_regions_*` in cache_search) uses.

pub mod geo;
pub mod http;
pub mod index;
mod places;

pub use places::{StreamAnswer, DEFAULT_PLACES_STREAM_TIMEOUT_MS, PLACES_STREAM_DEG};
use places::{PState, PlacesPart};

use index::{Current, Index, TileRef};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, MutexGuard, OnceLock, Weak};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

pub const DEFAULT_BASE_URL: &str = "https://data.cached.info/routing/";
/// Where places are published (the app passes it as `places_base_url`; without it a region has no places part).
pub const DEFAULT_PLACES_BASE_URL: &str = "https://data.cached.info/places/";
/// The places stream cache's default cap: 512 MiB of places tiles that belong to no downloaded region.
pub const DEFAULT_PLACES_STREAM_CAP: u64 = 512 * 1024 * 1024;
/// The parts a region can have.
pub const ROUTING: &str = "routing";
pub const PLACES: &str = "places";
/// The stream cache's default cap: 2 GiB of tiles that belong to no downloaded region.
pub const DEFAULT_STREAM_CAP: u64 = 2 * 1024 * 1024 * 1024;
/// How long `stream` waits by default.
pub const DEFAULT_STREAM_TIMEOUT_MS: u64 = 20_000;
/// A route's level 0 and 1 tiles: the box around its points, this much wider on every side (degrees).
pub const STREAM_BOX_DEG: f64 = 0.5;
/// A route's level 2 tiles: those within this many degrees of one of its points.
pub const STREAM_NEAR_DEG: f64 = 0.3;

/// Never fill the disk past this many free bytes (cache_sync's default).
const DEFAULT_RESERVE: u64 = 1024 * 1024 * 1024;
/// Tiles fetched at once.
const POOL: usize = 4;
/// A tile that fails its check (or that the server will not give) is tried this many times in all, then its regions fail.
const TRIES: u32 = 4;
/// After the server could not be reached, the next try comes this much later (or at once on a change of policy).
const RETRY_LATER: Duration = Duration::from_secs(30);
/// With nothing to do, the worker still looks again this often.
const IDLE: Duration = Duration::from_secs(60);
/// One request for current.json or an index.
const REQUEST_TIMEOUT: Duration = Duration::from_secs(60);
/// The longest an unpacked index may be.
const MAX_INDEX: u64 = 512 * 1024 * 1024;

const NO_NETWORK: &str = "Paused: no network it may use";

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// An error with a stable code (cache_search.h's codes): `bad_json`, `not_found`, `offline`, `fetch_failed`, `bad_response`,
/// `io`, `busy`, `internal`.
#[derive(Debug, Clone, PartialEq)]
pub struct Error {
    pub code: &'static str,
    pub message: String,
}

pub type Result<T> = std::result::Result<T, Error>;

impl Error {
    pub fn new(code: &'static str, message: impl Into<String>) -> Error {
        Error { code, message: message.into() }
    }
    fn bad_args(m: impl Into<String>) -> Error {
        Error::new("bad_json", m)
    }
    fn offline(m: impl Into<String>) -> Error {
        Error::new("offline", m)
    }
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for Error {}

impl From<rusqlite::Error> for Error {
    fn from(e: rusqlite::Error) -> Error {
        Error::new("io", format!("regions.sqlite: {e}"))
    }
}

impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Error {
        Error::new("io", e.to_string())
    }
}

fn default_base_url() -> String {
    DEFAULT_BASE_URL.to_string()
}

fn default_cap() -> u64 {
    DEFAULT_STREAM_CAP
}

fn default_places_cap() -> u64 {
    DEFAULT_PLACES_STREAM_CAP
}

/// The `cs_regions_open` config (and the `regions` section of the `cs_open` config).
#[derive(Debug, Clone, Deserialize)]
pub struct Config {
    /// Where regions.sqlite, the tiles and the cached indexes live (the app's private storage).
    pub dir: PathBuf,
    /// The routing server: current.json and the builds are under it.
    #[serde(default = "default_base_url")]
    pub base_url: String,
    /// Cap of the tiles fetched for routes that belong to no downloaded region.
    #[serde(default = "default_cap")]
    pub stream_cap_bytes: u64,
    /// Default "Cache/<version>".
    #[serde(default)]
    pub user_agent: Option<String>,
    /// Never fill the disk past this many free bytes; downloads pause with the reason instead (default 1 GiB).
    #[serde(default)]
    pub reserve_bytes: Option<u64>,
    /// The places server ([`DEFAULT_PLACES_BASE_URL`]). Without it, regions have no places part (as before places).
    #[serde(default)]
    pub places_base_url: Option<String>,
    /// Cap of the places tiles fetched for searches that belong to no downloaded region.
    #[serde(default = "default_places_cap")]
    pub places_stream_cap_bytes: u64,
}

/// A downloaded region: its outline, its parts and, per build, the tiles it needs (one build, or two while an update
/// downloads): `lists` routing's, `places` the places part's.
#[derive(Debug, Clone)]
struct Region {
    id: String,
    name: String,
    geometry: String,
    added: u64,
    /// Why routing failed.
    error: Option<String>,
    lists: BTreeMap<String, BTreeMap<String, TileRef>>,
    /// "routing", "places", in that order.
    parts: Vec<String>,
    places: BTreeMap<String, BTreeMap<String, TileRef>>,
    places_error: Option<String>,
}

impl Region {
    fn has(&self, part: &str) -> bool {
        self.parts.iter().any(|p| p == part)
    }
}

#[derive(Default)]
struct State {
    /// The build the device routes on.
    build: Option<String>,
    /// In the order they were added (and are downloaded).
    regions: Vec<Region>,
    /// Per build, the tiles whole on disk.
    present: HashMap<String, HashSet<String>>,
    /// The last current.json the server gave.
    current: Option<Current>,
    /// A newer build found by check_update, and the bytes to fetch for it.
    update: Option<(String, u64)>,
    /// The build `update` is downloading.
    updating: Option<String>,
    paused: Option<String>,
    /// The places part.
    p: PState,
}

impl State {
    /// Whether a region needs this tile of this build.
    fn wants(&self, build: &str, path: &str) -> bool {
        self.regions.iter().any(|r| r.lists.get(build).map(|l| l.contains_key(path)).unwrap_or(false))
    }

    fn has(&self, build: &str, path: &str) -> bool {
        self.present.get(build).map(|p| p.contains(path)).unwrap_or(false)
    }

    /// Whether any region has routing (a region can be places only).
    fn any_routing(&self) -> bool {
        self.regions.iter().any(|r| r.has(ROUTING))
    }
}

/// Why a tile did not land.
enum TileFail {
    /// Not the tile's fault (no network, the server cannot be reached, the disk): tried again later.
    Later(String),
    /// The tile itself: the server would not give it, or what came is not the tile the index describes.
    Bad(String),
}

struct Batch {
    build: String,
    name: String,
    tiles: Vec<TileRef>,
}

enum Next {
    Batch(Batch),
    /// Places tiles of one region.
    Places(Batch),
    /// Set up the places build, or a region's places tile list.
    PlacesInit,
    Wait(Duration),
    Again,
}

struct Inner {
    dir: PathBuf,
    base: String,
    cap: u64,
    reserve: AtomicU64,
    agent: ureq::Agent,
    db: Mutex<Connection>,
    st: Mutex<State>,
    indexes: Mutex<HashMap<String, Arc<Index>>>,
    network: AtomicBool,
    stop: AtomicBool,
    wake: (Mutex<bool>, Condvar),
    /// Last stream-cache use stamp handed out (milliseconds, made unique).
    tick: AtomicU64,
    seq: AtomicU64,
    /// The places part, when the config has `places_base_url`.
    places: Option<PlacesPart>,
}

pub struct Regions {
    inner: Arc<Inner>,
    worker: Mutex<Option<std::thread::JoinHandle<()>>>,
}

fn human(n: u64) -> String {
    const U: [&str; 5] = ["B", "KB", "MB", "GB", "TB"];
    let mut v = n as f64;
    let mut i = 0;
    while v >= 1024.0 && i < U.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i == 0 {
        format!("{n} B")
    } else {
        format!("{v:.1} {}", U[i])
    }
}

fn free_bytes(path: &Path) -> Option<u64> {
    let mut p = path.to_path_buf();
    while !p.exists() {
        if !p.pop() {
            return None;
        }
    }
    volume_free(&p)
}

/// Free bytes on the volume holding the existing path `p` (fs4, statvfs on unix).
#[cfg(not(target_os = "ios"))]
fn volume_free(p: &Path) -> Option<u64> {
    fs4::available_space(p).ok()
}

/// iPhone: the app's `cache_free_bytes_on_disk` (same binary), which counts the space iOS can purge as iPhone Storage in
/// Settings does; statvfs leaves it out.
#[cfg(target_os = "ios")]
fn volume_free(p: &Path) -> Option<u64> {
    use std::os::unix::ffi::OsStrExt;
    extern "C" {
        fn cache_free_bytes_on_disk(path: *const std::ffi::c_char) -> i64;
    }
    let c = std::ffi::CString::new(p.as_os_str().as_bytes()).ok()?;
    // SAFETY: `c` is a valid NUL-terminated path; the helper only reads it.
    u64::try_from(unsafe { cache_free_bytes_on_disk(c.as_ptr()) }).ok()
}

/// Folders a delete left empty go too, up to (not including) `root`.
fn prune_empty(root: &Path, removed: &Path) {
    let mut d = removed.parent();
    while let Some(dir) = d {
        if dir == root || !dir.starts_with(root) || std::fs::remove_dir(dir).is_err() {
            break;
        }
        d = dir.parent();
    }
}

/// A rename that a busy file (Windows, an antivirus scan) refuses is tried again a few times.
fn rename_retry(from: &Path, to: &Path) -> std::io::Result<()> {
    let mut last = None;
    for i in 0..5 {
        match std::fs::rename(from, to) {
            Ok(()) => return Ok(()),
            Err(e) => last = Some(e),
        }
        std::thread::sleep(Duration::from_millis(50 * (i + 1)));
    }
    Err(last.unwrap_or_else(|| std::io::Error::other("rename failed")))
}

#[cfg(unix)]
fn sync_dir(dir: &Path) {
    let _ = std::fs::File::open(dir).and_then(|f| f.sync_all());
}

#[cfg(not(unix))]
fn sync_dir(_dir: &Path) {}

/// A file written whole: a hidden temp next to it, flushed, then renamed into place.
fn write_whole(path: &Path, bytes: &[u8], seq: u64) -> std::io::Result<()> {
    let parent = path.parent().ok_or_else(|| std::io::Error::other("no folder"))?;
    std::fs::create_dir_all(parent)?;
    let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
    let tmp = parent.join(format!(".{name}.{}.{seq}.tmp", std::process::id()));
    let res = (|| {
        let mut f = std::fs::File::create(&tmp)?;
        f.write_all(bytes)?;
        f.sync_all()?;
        drop(f);
        rename_retry(&tmp, path)
    })();
    if res.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    sync_dir(parent);
    res
}

fn gunzip(gz: &[u8], limit: u64) -> std::io::Result<Vec<u8>> {
    let mut out = Vec::new();
    flate2::read::GzDecoder::new(gz).take(limit).read_to_end(&mut out)?;
    Ok(out)
}

fn sha256_hex(b: &[u8]) -> String {
    Sha256::digest(b).iter().map(|x| format!("{x:02x}")).collect()
}

/// Under a build's tile folder: the paths of the tiles there (without ".gph"); hidden files (temps a stopped write left) go.
fn scan_tiles(root: &Path, dir: &Path, out: &mut HashSet<String>) {
    let Ok(rd) = std::fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        let p = e.path();
        let name = e.file_name().to_string_lossy().into_owned();
        let Ok(m) = std::fs::symlink_metadata(&p) else { continue };
        if name.starts_with('.') {
            if m.is_file() {
                let _ = std::fs::remove_file(&p);
            }
            continue;
        }
        if m.is_dir() {
            scan_tiles(root, &p, out);
        } else if m.is_file() {
            if let Some(rel) = p.strip_prefix(root).ok().and_then(|r| r.to_str()).and_then(|r| r.strip_suffix(".gph")) {
                let rel = rel.replace('\\', "/");
                if geo::parse_tile_path(&rel).is_some() {
                    out.insert(rel);
                }
            }
        }
    }
}

/// The points of a `stream` call: [[lat, lon], ...].
fn points_of(v: Option<&Value>) -> Vec<(f64, f64)> {
    v.and_then(|p| p.as_array())
        .map(|a| a.iter().filter_map(|p| Some((p.get(0)?.as_f64()?, p.get(1)?.as_f64()?))).filter(|(a, o)| a.is_finite() && o.is_finite()).collect())
        .unwrap_or_default()
}

/// The `geometry` argument: the outline and its JSON text.
fn shape_arg(args: &Value) -> Result<(geo::Shape, String)> {
    let g = args.get("geometry").filter(|g| !g.is_null()).ok_or_else(|| Error::bad_args("geometry is required (a GeoJSON Feature, Polygon or MultiPolygon)"))?;
    let shape = geo::Shape::parse(g).map_err(Error::bad_args)?;
    let text = match g.as_str() {
        Some(s) => s.to_string(),
        None => g.to_string(),
    };
    Ok((shape, text))
}

/// The `id`, `name` and `geometry` arguments of `add`.
fn region_args(args: &Value) -> Result<(String, String, geo::Shape, String)> {
    let id = args.get("id").and_then(|v| v.as_str()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).ok_or_else(|| Error::bad_args("id is required"))?;
    if id.len() > 128 {
        return Err(Error::bad_args("id is longer than 128 characters"));
    }
    let name = args.get("name").and_then(|v| v.as_str()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).unwrap_or_else(|| id.clone());
    let (shape, text) = shape_arg(args)?;
    Ok((id, name, shape, text))
}

impl Inner {
    fn st(&self) -> MutexGuard<'_, State> {
        self.st.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn db(&self) -> MutexGuard<'_, Connection> {
        self.db.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn indexes(&self) -> MutexGuard<'_, HashMap<String, Arc<Index>>> {
        self.indexes.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn seq(&self) -> u64 {
        self.seq.fetch_add(1, Ordering::Relaxed)
    }

    /// A stream-cache use stamp: now, but always after the one before (two uses in the same millisecond keep their order).
    fn tick(&self) -> u64 {
        let now = now_ms();
        // `try_update` is the new name, too new for every toolchain the app is built with.
        #[allow(deprecated)]
        let prev = self.tick.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |t| Some(t.max(now.saturating_sub(1)) + 1)).unwrap_or(0);
        prev.max(now.saturating_sub(1)) + 1
    }

    fn stopped(&self) -> bool {
        self.stop.load(Ordering::Relaxed)
    }

    /// Every request checks this first: with the policy off, nothing goes out at all.
    fn may_use_network(&self) -> bool {
        self.network.load(Ordering::Relaxed) && !self.stopped()
    }

    fn poke(&self) {
        let (m, cv) = &self.wake;
        *m.lock().unwrap_or_else(|e| e.into_inner()) = true;
        cv.notify_all();
    }

    fn sleep(&self, d: Duration) {
        let (m, cv) = &self.wake;
        let mut g = m.lock().unwrap_or_else(|e| e.into_inner());
        if !*g {
            g = cv.wait_timeout(g, d).unwrap_or_else(|e| e.into_inner()).0;
        }
        *g = false;
    }

    fn build_dir(&self, build: &str) -> PathBuf {
        self.dir.join("tiles").join(build)
    }

    fn tile_file(&self, build: &str, path: &str) -> PathBuf {
        let mut p = self.build_dir(build);
        for part in path.split('/') {
            p.push(part);
        }
        p.set_extension("gph");
        p
    }

    fn index_file(&self, build: &str) -> PathBuf {
        self.dir.join("index").join(format!("{build}.tsv"))
    }

    fn meta_set(&self, db: &Connection, key: &str, value: Option<&str>) -> Result<()> {
        match value {
            Some(v) => db.execute("INSERT OR REPLACE INTO meta(key, value) VALUES (?1, ?2)", params![key, v])?,
            None => db.execute("DELETE FROM meta WHERE key = ?1", params![key])?,
        };
        Ok(())
    }

    // ---- what the server publishes ----

    fn get(&self, url: &str, timeout: Duration) -> Result<Vec<u8>> {
        if !self.may_use_network() {
            return Err(Error::offline(NO_NETWORK));
        }
        http::get(&self.agent, url, timeout).map_err(|f| match f {
            http::Fail::Net(m) => Error::offline(format!("the routing server cannot be reached: {m}")),
            http::Fail::Status(_, m) => Error::new("fetch_failed", m),
        })
    }

    /// current.json, checked, and remembered (the last one known is what a region is planned on while offline).
    fn fetch_current(&self, timeout: Duration) -> Result<Current> {
        let body = self.get(&format!("{}current.json", self.base), timeout)?;
        let c: Current = serde_json::from_slice(&body).map_err(|e| Error::new("bad_response", format!("current.json is not valid: {e}")))?;
        c.check_routing().map_err(|m| Error::new("bad_response", m))?;
        let text = serde_json::to_string(&c).unwrap_or_default();
        let mut st = self.st();
        if st.current.as_ref() != Some(&c) {
            st.current = Some(c.clone());
            let db = self.db();
            self.meta_set(&db, "current", Some(&text))?;
        }
        Ok(c)
    }

    /// A build's index from this device (it was checked when it was fetched).
    fn cached_index(&self, build: &str) -> Option<Arc<Index>> {
        if let Some(i) = self.indexes().get(build) {
            return Some(i.clone());
        }
        let text = std::fs::read_to_string(self.index_file(build)).ok()?;
        let idx = Arc::new(Index::parse(build, &text).ok()?);
        self.indexes().insert(build.to_string(), idx.clone());
        Some(idx)
    }

    /// The index of the build `c` names: from this device, or fetched, checked against `index_sha256` and kept.
    fn fetch_index(&self, c: &Current, timeout: Duration) -> Result<Arc<Index>> {
        if let Some(i) = self.cached_index(&c.build) {
            return Ok(i);
        }
        let gz = self.get(&format!("{}{}", self.base, c.index), timeout)?;
        if sha256_hex(&gz) != c.index_sha256.to_ascii_lowercase() {
            return Err(Error::new("bad_response", format!("the index of {} does not match its checksum", c.build)));
        }
        let raw = gunzip(&gz, MAX_INDEX).map_err(|e| Error::new("bad_response", format!("the index of {} is not valid gzip: {e}", c.build)))?;
        let text = String::from_utf8(raw).map_err(|_| Error::new("bad_response", format!("the index of {} is not text", c.build)))?;
        let idx = Arc::new(Index::parse(&c.build, &text).map_err(|m| Error::new("bad_response", m))?);
        write_whole(&self.index_file(&c.build), text.as_bytes(), self.seq())?;
        self.indexes().insert(c.build.clone(), idx.clone());
        Ok(idx)
    }

    /// A build's index, fetched only when it is the current build and not on the device yet.
    fn index_of(&self, build: &str, timeout: Duration) -> Result<Arc<Index>> {
        if let Some(i) = self.cached_index(build) {
            return Ok(i);
        }
        let cur = self.st().current.clone();
        match cur {
            Some(c) if c.build == build => self.fetch_index(&c, timeout),
            _ => Err(Error::offline(format!("the index of {build} is not on this device"))),
        }
    }

    /// Which build a new region goes in: the device's while it has regions (builds are never mixed); with none yet, the newest,
    /// or the last one known while the server cannot be asked.
    fn build_for_new_region(&self) -> Result<(String, Arc<Index>)> {
        let (dev, has_regions) = {
            let st = self.st();
            (st.build.clone(), st.any_routing())
        };
        if let (Some(b), true) = (&dev, has_regions) {
            return Ok((b.clone(), self.index_of(b, REQUEST_TIMEOUT)?));
        }
        let fetched = self.fetch_current(REQUEST_TIMEOUT).and_then(|c| Ok((c.build.clone(), self.fetch_index(&c, REQUEST_TIMEOUT)?)));
        match fetched {
            Ok(r) => Ok(r),
            Err(e) => {
                let known = [dev, self.st().current.as_ref().map(|c| c.build.clone())];
                for b in known.into_iter().flatten() {
                    if let Some(i) = self.cached_index(&b) {
                        return Ok((b, i));
                    }
                }
                Err(e)
            }
        }
    }

    // ---- builds ----

    /// The device now routes on `new`: the tile lists and tiles of any other build go, and so does the stream cache. Returns
    /// the old build's folder (renamed aside), for the caller to delete once it no longer holds the state.
    fn switch(&self, st: &mut State, new: &str) -> Result<Option<PathBuf>> {
        let old = st.build.clone();
        {
            let mut db = self.db();
            let tx = db.transaction()?;
            tx.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('build', ?1)", params![new])?;
            tx.execute("DELETE FROM meta WHERE key IN ('updating', 'update')", [])?;
            tx.execute("DELETE FROM region_tiles2 WHERE component = 'routing' AND build <> ?1", params![new])?;
            tx.execute("DELETE FROM stream2 WHERE component = 'routing'", [])?;
            tx.commit()?;
        }
        std::fs::create_dir_all(self.build_dir(new))?;
        st.build = Some(new.to_string());
        st.updating = None;
        st.update = None;
        for r in &mut st.regions {
            r.lists.retain(|b, _| b == new);
        }
        st.present.retain(|b, _| b == new);
        st.present.entry(new.to_string()).or_default();
        let mut trash = None;
        if let Some(old) = old.filter(|o| o != new) {
            self.indexes().remove(&old);
            let _ = std::fs::remove_file(self.index_file(&old));
            let from = self.build_dir(&old);
            if from.exists() {
                let aside = self.dir.join("tiles").join(format!(".old-{old}-{}", self.seq()));
                trash = Some(if std::fs::rename(&from, &aside).is_ok() { aside } else { from });
            }
        }
        Ok(trash)
    }

    /// Deletes those of `paths` (tiles of `build`) that no region and no stream-cache entry uses. Returns how many went.
    fn delete_unused<'a>(&self, st: &mut State, build: &str, paths: impl Iterator<Item = &'a String>) -> usize {
        let streamed: HashSet<String> = {
            let db = self.db();
            let mut q = match db.prepare("SELECT path FROM stream2 WHERE component = 'routing' AND build = ?1") {
                Ok(q) => q,
                Err(_) => return 0,
            };
            let set: HashSet<String> = match q.query_map(params![build], |r| r.get::<_, String>(0)) {
                Ok(rows) => rows.flatten().collect(),
                Err(_) => HashSet::new(),
            };
            set
        };
        let root = self.build_dir(build);
        let mut n = 0;
        for p in paths {
            if st.wants(build, p) || streamed.contains(p) {
                continue;
            }
            let f = self.tile_file(build, p);
            if std::fs::remove_file(&f).is_ok() {
                n += 1;
                prune_empty(&root, &f);
            }
            if let Some(s) = st.present.get_mut(build) {
                s.remove(p);
            }
        }
        n
    }

    // ---- one tile ----

    fn verify(t: &TileRef, gz: &[u8]) -> std::result::Result<Vec<u8>, String> {
        let raw = gunzip(gz, t.bytes + 1).map_err(|e| format!("{}: not valid gzip ({e})", t.path))?;
        if raw.len() as u64 != t.bytes {
            return Err(format!("{}: {} bytes, the index says {}", t.path, raw.len(), t.bytes));
        }
        if sha256_hex(&raw) != t.sha256 {
            return Err(format!("{}: does not match its checksum", t.path));
        }
        Ok(raw)
    }

    /// GET, unpack, check and write one tile, trying a bad one again up to [`TRIES`] times in all. `deadline`: give up then
    /// (a stream call); otherwise each request has the usual timeout.
    fn fetch_tile(&self, build: &str, t: &TileRef, deadline: Option<Instant>) -> std::result::Result<(), TileFail> {
        let url = format!("{}{}/{}.gph.gz", self.base, build, t.path);
        let mut last = String::new();
        for attempt in 0..TRIES {
            if attempt > 0 {
                std::thread::sleep(Duration::from_millis(250 * attempt as u64));
            }
            if !self.may_use_network() {
                return Err(TileFail::Later(NO_NETWORK.into()));
            }
            let timeout = match deadline {
                Some(d) => d.saturating_duration_since(Instant::now()),
                None => REQUEST_TIMEOUT,
            };
            if timeout.is_zero() {
                return Err(TileFail::Later("timed out".into()));
            }
            match http::get(&self.agent, &url, timeout) {
                Err(http::Fail::Net(m)) => return Err(TileFail::Later(m)),
                Err(http::Fail::Status(_, m)) => last = m,
                Ok(gz) => match Self::verify(t, &gz) {
                    Ok(raw) => {
                        return write_whole(&self.tile_file(build, &t.path), &raw, self.seq())
                            .map_err(|e| TileFail::Later(format!("could not write {}: {e}", t.path)))
                    }
                    Err(m) => last = m,
                },
            }
        }
        Err(TileFail::Bad(format!("{last} (tried {TRIES} times)")))
    }

    /// A tile the worker fetched is whole on disk. If its region went while it was on its way, it goes too.
    fn landed(&self, build: &str, path: &str) {
        let mut st = self.st();
        st.present.entry(build.to_string()).or_default().insert(path.to_string());
        if !st.wants(build, path) {
            let p = path.to_string();
            self.delete_unused(&mut st, build, std::iter::once(&p));
        }
    }

    /// A tile that could not be had: every region that needs it fails, with the reason.
    fn tile_failed(&self, build: &str, path: &str, msg: &str) {
        let mut st = self.st();
        let db = self.db();
        for r in st.regions.iter_mut().filter(|r| r.error.is_none()) {
            if r.lists.get(build).map(|l| l.contains_key(path)).unwrap_or(false) {
                r.error = Some(msg.to_string());
                let _ = db.execute("UPDATE regions SET error = ?1 WHERE id = ?2", params![msg, r.id]);
            }
        }
    }

    // ---- the worker ----

    /// What the worker does next: the missing tiles of the first region (in the order they were added), places first (they
    /// are small, so search works soon) then routing, of the build each part is filling (an update's while one downloads,
    /// else the device's); or the switch to an update that is complete, or a wait.
    fn next(&self) -> Next {
        if self.p_needs_init() {
            return Next::PlacesInit;
        }
        let mut st = self.st();
        let target = st.updating.clone().or_else(|| st.build.clone());
        let empty = HashSet::new();
        let present = target.as_ref().and_then(|t| st.present.get(t)).unwrap_or(&empty);
        let mut batch = None;
        for r in &st.regions {
            if let Some(b) = self.p_batch(&st, r) {
                batch = Some(Next::Places(b));
                break;
            }
            let (Some(target), None) = (&target, &r.error) else { continue };
            let Some(list) = r.lists.get(target) else { continue };
            let missing: Vec<TileRef> = list.values().filter(|t| !present.contains(&t.path)).cloned().collect();
            if !missing.is_empty() {
                batch = Some(Next::Batch(Batch { build: target.clone(), name: r.name.clone(), tiles: missing }));
                break;
            }
        }
        let Some(next) = batch else {
            if let Some(u) = self.p_ready_to_switch(&st) {
                return match self.p_switch(&mut st, &u) {
                    Ok(()) => Next::Again,
                    Err(e) => {
                        st.paused = Some(format!("Paused: could not move places to {u}: {e}"));
                        Next::Wait(RETRY_LATER)
                    }
                };
            }
            if let (Some(target), true) = (target, st.updating.is_some()) {
                // Every region has its whole list of the new build (a failed one included): the device moves to it.
                let present = st.present.get(&target).unwrap_or(&empty);
                let complete = st
                    .regions
                    .iter()
                    .filter(|r| r.has(ROUTING))
                    .all(|r| r.lists.get(&target).map(|l| l.keys().all(|p| present.contains(p))).unwrap_or(false));
                if complete {
                    match self.switch(&mut st, &target) {
                        Ok(trash) => {
                            drop(st);
                            if let Some(t) = trash {
                                let _ = std::fs::remove_dir_all(t);
                            }
                            return Next::Again;
                        }
                        Err(e) => {
                            st.paused = Some(format!("Paused: could not move to {target}: {e}"));
                            return Next::Wait(RETRY_LATER);
                        }
                    }
                }
            }
            st.paused = None;
            return Next::Wait(IDLE);
        };
        if !self.may_use_network() {
            st.paused = Some(NO_NETWORK.into());
            return Next::Wait(IDLE);
        }
        let (need, name) = match &next {
            Next::Batch(b) | Next::Places(b) => (b.tiles.iter().map(|t| t.bytes).sum::<u64>(), b.name.clone()),
            _ => (0, String::new()),
        };
        let reserve = self.reserve.load(Ordering::Relaxed);
        if let Some(free) = free_bytes(&self.dir) {
            if free < need.saturating_add(reserve) {
                st.paused = Some(format!("Paused: {name} needs {}, {} is free and {} is kept free", human(need), human(free), human(reserve)));
                return Next::Wait(RETRY_LATER);
            }
        }
        st.paused = None;
        next
    }

    fn run_batch(&self, b: Batch) {
        let queue = Mutex::new(b.tiles.into_iter());
        let later: Mutex<Option<String>> = Mutex::new(None);
        std::thread::scope(|sc| {
            for _ in 0..POOL {
                sc.spawn(|| loop {
                    if !self.may_use_network() || later.lock().map(|l| l.is_some()).unwrap_or(true) {
                        break;
                    }
                    let Some(t) = queue.lock().ok().and_then(|mut q| q.next()) else { break };
                    // A region removed meanwhile, or a tile a stream call fetched: nothing to do.
                    {
                        let st = self.st();
                        if !st.wants(&b.build, &t.path) || st.has(&b.build, &t.path) {
                            continue;
                        }
                    }
                    match self.fetch_tile(&b.build, &t, None) {
                        Ok(()) => self.landed(&b.build, &t.path),
                        Err(TileFail::Bad(m)) => self.tile_failed(&b.build, &t.path, &m),
                        Err(TileFail::Later(m)) => {
                            if let Ok(mut l) = later.lock() {
                                *l = Some(m);
                            }
                            break;
                        }
                    }
                });
            }
        });
        let later = later.into_inner().unwrap_or(None);
        if let Some(m) = later.filter(|_| self.may_use_network()) {
            self.st().paused = Some(format!("Paused: {m}; trying again shortly"));
            self.sleep(RETRY_LATER);
        }
    }

    fn work(&self) {
        while !self.stopped() {
            match self.next() {
                Next::Batch(b) => self.run_batch(b),
                Next::Places(b) => self.p_run_batch(b),
                Next::PlacesInit => self.p_init(),
                Next::Wait(d) => self.sleep(d),
                Next::Again => {}
            }
        }
    }

    // ---- the methods ----

    fn status(&self) -> Value {
        let st = self.st();
        let empty = HashSet::new();
        let build = st.build.clone();
        let present = build.as_ref().and_then(|b| st.present.get(b)).unwrap_or(&empty);
        let regions: Vec<Value> = st
            .regions
            .iter()
            .map(|r| {
                let list = build.as_ref().and_then(|b| r.lists.get(b));
                let (mut tiles, mut bytes, mut done, mut done_bytes) = (0u64, 0u64, 0u64, 0u64);
                for t in list.into_iter().flat_map(|l| l.values()) {
                    tiles += 1;
                    bytes += t.bytes;
                    if present.contains(&t.path) {
                        done += 1;
                        done_bytes += t.bytes;
                    }
                }
                let state = if r.error.is_some() {
                    "failed"
                } else if done == tiles {
                    "ready"
                } else if st.paused.is_some() {
                    "paused"
                } else {
                    "downloading"
                };
                let mut v = json!({
                    "id": r.id, "name": r.name, "state": state, "tiles": tiles, "bytes": bytes,
                    "done_tiles": done, "done_bytes": done_bytes, "error": r.error,
                });
                // With places on, each part says how it is, and the region's state is the parts' together: failed, else
                // paused, else downloading, else ready.
                if self.places.is_some() {
                    let mut parts = serde_json::Map::new();
                    if r.has(ROUTING) {
                        parts.insert(ROUTING.into(), json!({"state": state, "tiles": tiles, "bytes": bytes, "done_tiles": done, "done_bytes": done_bytes, "error": r.error}));
                    }
                    if r.has(PLACES) {
                        parts.insert(PLACES.into(), self.p_region_status(&st, r));
                    }
                    let states: Vec<&str> = parts.values().filter_map(|p| p["state"].as_str()).collect();
                    let all = ["failed", "paused", "downloading"].into_iter().find(|s| states.contains(s)).unwrap_or("ready");
                    v["state"] = json!(all);
                    v["parts"] = Value::Object(parts);
                }
                v
            })
            .collect();
        let (mut s_tiles, mut s_bytes) = (0u64, 0u64);
        if let Some(b) = &build {
            for (path, n) in self.stream_rows(b) {
                if !st.wants(b, &path) {
                    s_tiles += 1;
                    s_bytes += n;
                }
            }
        }
        let update = st.update.as_ref().map(|(b, bytes)| {
            let downloading = st.updating.as_deref() == Some(b.as_str());
            let left = if downloading { Self::left_to_fetch(&st, b) } else { *bytes };
            json!({"build": b, "download_bytes": left, "downloading": downloading})
        });
        let mut out = json!({
            "build": build,
            "tile_dir": build.as_ref().map(|b| self.build_dir(b).to_string_lossy().into_owned()),
            "regions": regions,
            "stream": {"tiles": s_tiles, "bytes": s_bytes, "cap": self.cap},
            "update": update,
            "paused": st.paused,
        });
        if self.places.is_some() {
            let (places, p_update) = self.p_status(&st);
            out["places"] = places;
            out["updates"] = json!({"routing": out["update"].clone(), "places": p_update});
        }
        out
    }

    /// The gzip bytes still to fetch of every region's tiles of `build` (each tile once).
    fn left_to_fetch(st: &State, build: &str) -> u64 {
        let mut seen = HashSet::new();
        let mut n = 0;
        for t in st.regions.iter().filter_map(|r| r.lists.get(build)).flat_map(|l| l.values()) {
            if !st.has(build, &t.path) && seen.insert(t.path.as_str()) {
                n += t.gz;
            }
        }
        n
    }

    fn stream_rows(&self, build: &str) -> Vec<(String, u64)> {
        let db = self.db();
        let Ok(mut q) = db.prepare("SELECT path, bytes FROM stream2 WHERE component = 'routing' AND build = ?1 ORDER BY last_used") else { return Vec::new() };
        let rows: Vec<(String, u64)> = match q.query_map(params![build], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64))) {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        };
        rows
    }

    /// The parts this engine has: routing, and places when they are on.
    fn enabled_parts(&self) -> Vec<String> {
        let mut v = vec![ROUTING.to_string()];
        if self.places.is_some() {
            v.push(PLACES.to_string());
        }
        v
    }

    /// The `parts` argument: every enabled part when it is left out.
    fn parts_arg(&self, args: &Value) -> Result<Vec<String>> {
        let enabled = self.enabled_parts();
        let Some(v) = args.get("parts").filter(|v| !v.is_null()) else { return Ok(enabled) };
        let asked: Vec<&str> = v.as_array().ok_or_else(|| Error::bad_args("parts must be a list"))?.iter().map(|p| p.as_str().unwrap_or("")).collect();
        if let Some(bad) = asked.iter().find(|p| !enabled.iter().any(|e| e == *p)) {
            return Err(Error::bad_args(format!("unknown part {bad:?} (this engine has {})", enabled.join(", "))));
        }
        if asked.is_empty() {
            return Err(Error::bad_args("parts is empty"));
        }
        Ok(enabled.into_iter().filter(|e| asked.contains(&e.as_str())).collect())
    }

    /// An error as a part's entry in an answer.
    fn part_error(e: &Error) -> Value {
        json!({"error": e.message, "code": e.code})
    }

    fn plan(&self, args: &Value) -> Result<Value> {
        let (shape, _) = shape_arg(args)?;
        let parts = self.parts_arg(args)?;
        let routing = parts.iter().any(|p| p == ROUTING).then(|| self.plan_routing(&shape));
        if self.places.is_none() {
            return routing.unwrap_or_else(|| Err(Error::bad_args("no part to plan")));
        }
        let places = parts.iter().any(|p| p == PLACES).then(|| self.p_plan(&shape));
        // One part that cannot be planned does not fail the other; only a plan with nothing planned is an error.
        let first_err = [&routing, &places].into_iter().flatten().find_map(|r| r.as_ref().err().cloned());
        if [&routing, &places].into_iter().flatten().all(|r| r.is_err()) {
            return Err(first_err.unwrap_or_else(|| Error::bad_args("no part to plan")));
        }
        let mut out = match &routing {
            Some(Ok(v)) => v.clone(),
            _ => json!({"tiles": 0, "bytes": 0, "download_bytes": 0, "shared_tiles": 0}),
        };
        let mut obj = serde_json::Map::new();
        for (name, r) in [(ROUTING, routing), (PLACES, places)] {
            if let Some(r) = r {
                obj.insert(name.into(), r.unwrap_or_else(|e| Self::part_error(&e)));
            }
        }
        out["parts"] = Value::Object(obj);
        Ok(out)
    }

    fn plan_routing(&self, shape: &geo::Shape) -> Result<Value> {
        let (build, idx) = self.build_for_new_region()?;
        let tiles = idx.tiles_for(shape);
        let st = self.st();
        let (mut bytes, mut download, mut shared) = (0u64, 0u64, 0u64);
        for t in &tiles {
            bytes += t.bytes;
            if st.has(&build, &t.path) {
                shared += 1;
            } else {
                download += t.gz;
            }
        }
        Ok(json!({"tiles": tiles.len(), "bytes": bytes, "download_bytes": download, "shared_tiles": shared}))
    }

    fn add(&self, args: &Value) -> Result<Value> {
        let (id, name, shape, geometry) = region_args(args)?;
        let asked = self.parts_arg(args)?;
        // Added again: the parts it had stay, and the ones asked for now are added.
        let had: Vec<String> = self.st().regions.iter().find(|r| r.id == id).map(|r| r.parts.clone()).unwrap_or_default();
        let parts: Vec<String> = self.enabled_parts().into_iter().filter(|p| asked.contains(p) || had.contains(p)).collect();
        let routing = parts.iter().any(|p| p == ROUTING);
        let (build, tiles) = if routing {
            let (b, idx) = self.build_for_new_region()?;
            let tiles = idx.tiles_for(&shape);
            (Some(b), tiles)
        } else {
            (None, Vec::new())
        };
        let mut st = self.st();
        let mut trash = None;
        let mut lists: BTreeMap<String, BTreeMap<String, TileRef>> = BTreeMap::new();
        if let Some(build) = &build {
            if st.build.as_deref() != Some(build.as_str()) {
                if st.any_routing() {
                    return Err(Error::new("busy", "another region was added meanwhile; try again"));
                }
                trash = self.switch(&mut st, build)?;
            }
            lists.insert(build.clone(), tiles.iter().map(|t| (t.path.clone(), t.clone())).collect());
            // An update downloading: the new region is part of it.
            if let Some(u) = st.updating.clone() {
                let ui = self.cached_index(&u).ok_or_else(|| Error::new("io", format!("the index of {u} is missing")))?;
                lists.insert(u, ui.tiles_for(&shape).into_iter().map(|t| (t.path.clone(), t)).collect());
            }
        }
        let pos = st.regions.iter().position(|r| r.id == id);
        let added = pos.map(|i| st.regions[i].added).unwrap_or_else(now_ms);
        // The places lists stay until the places part has worked out the new ones (so no tile goes in between).
        let places = pos.map(|i| st.regions[i].places.clone()).unwrap_or_default();
        let places_error = pos.and_then(|i| st.regions[i].places_error.clone());
        let region = Region { id: id.clone(), name, geometry, added, error: None, lists, parts: parts.clone(), places, places_error };
        {
            let mut db = self.db();
            let tx = db.transaction()?;
            tx.execute(
                "INSERT OR REPLACE INTO regions(id, name, geometry, added, error, parts, places_error) VALUES (?1, ?2, ?3, ?4, NULL, ?5, ?6)",
                params![region.id, region.name, region.geometry, region.added as i64, json!(region.parts).to_string(), region.places_error],
            )?;
            tx.execute("DELETE FROM region_tiles2 WHERE region = ?1 AND component = 'routing'", params![id])?;
            {
                let mut ins = tx.prepare("INSERT INTO region_tiles2(region, component, build, path, bytes, sha256, gz) VALUES (?1, 'routing', ?2, ?3, ?4, ?5, ?6)")?;
                for (b, l) in &region.lists {
                    for t in l.values() {
                        ins.execute(params![id, b, t.path, t.bytes as i64, t.sha256, t.gz as i64])?;
                    }
                }
            }
            tx.commit()?;
        }
        let old = match pos {
            Some(i) => Some(std::mem::replace(&mut st.regions[i], region)),
            None => {
                st.regions.push(region);
                None
            }
        };
        // Added again with another outline: the tiles only the old outline needed go.
        if let Some(old) = old {
            for (b, l) in &old.lists {
                self.delete_unused(&mut st, b, l.keys());
            }
        }
        let (mut bytes, mut download) = (0u64, 0u64);
        for t in &tiles {
            bytes += t.bytes;
            if !build.as_ref().is_some_and(|b| st.has(b, &t.path)) {
                download += t.gz;
            }
        }
        drop(st);
        if let Some(t) = trash {
            let _ = std::fs::remove_dir_all(t);
        }
        let mut out = json!({"ok": true, "tiles": tiles.len(), "bytes": bytes, "download_bytes": download});
        if self.places.is_some() {
            let mut obj = serde_json::Map::new();
            if routing {
                obj.insert(ROUTING.into(), json!({"tiles": tiles.len(), "bytes": bytes, "download_bytes": download}));
            }
            if parts.iter().any(|p| p == PLACES) {
                obj.insert(PLACES.into(), self.p_add(&id));
            }
            out["parts"] = Value::Object(obj);
        }
        self.poke();
        Ok(out)
    }

    fn remove(&self, args: &Value) -> Result<Value> {
        let id = args.get("id").and_then(|v| v.as_str()).ok_or_else(|| Error::bad_args("id is required"))?;
        let mut st = self.st();
        let pos = st.regions.iter().position(|r| r.id == id).ok_or_else(|| Error::new("not_found", format!("no region {id}")))?;
        {
            let mut db = self.db();
            let tx = db.transaction()?;
            tx.execute("DELETE FROM regions WHERE id = ?1", params![id])?;
            tx.execute("DELETE FROM region_tiles2 WHERE region = ?1", params![id])?;
            tx.commit()?;
        }
        let r = st.regions.remove(pos);
        let mut deleted = 0;
        for (b, l) in &r.lists {
            deleted += self.delete_unused(&mut st, b, l.keys());
        }
        let mut out = json!({"ok": true, "deleted_tiles": deleted});
        if self.places.is_some() {
            let mut gone = 0;
            for (b, l) in &r.places {
                gone += self.p_delete_unused(&mut st, b, l.keys());
            }
            self.p_set_names(&st);
            out = json!({"ok": true, "deleted_tiles": deleted + gone, "parts": {"routing": {"deleted_tiles": deleted}, "places": {"deleted_tiles": gone}}});
        }
        drop(st);
        self.poke();
        Ok(out)
    }

    /// Fetches what a route through `points` is likely to need, within the timeout. Never an error: whatever goes wrong is
    /// `ok: false`, and the route uses the tiles there are.
    fn stream(&self, args: &Value) -> Value {
        let points = points_of(args.get("points"));
        let timeout = Duration::from_millis(args.get("timeout_ms").and_then(|v| v.as_u64()).unwrap_or(DEFAULT_STREAM_TIMEOUT_MS));
        let deadline = Instant::now() + timeout;
        let answer = |fetched: usize, missing: usize, ok: bool| json!({"fetched": fetched, "missing": missing, "ok": ok});
        let device = self.st().build.clone();
        // Offline: only what is on the device. How much is missing is known when the index is.
        if !self.may_use_network() {
            let missing = device
                .as_ref()
                .and_then(|b| Some((b, self.cached_index(b)?)))
                .map(|(b, idx)| {
                    let st = self.st();
                    idx.tiles_near(&points, STREAM_BOX_DEG, STREAM_NEAR_DEG).iter().filter(|t| !st.has(b, &t.path)).count()
                })
                .unwrap_or(0);
            return answer(0, missing, false);
        }
        let left = || deadline.saturating_duration_since(Instant::now());
        let chosen = match &device {
            Some(b) => self.index_of(b, left()).map(|i| (b.clone(), i)),
            None => self.fetch_current(left()).and_then(|c| {
                let idx = self.fetch_index(&c, left())?;
                let mut st = self.st();
                let mut trash = None;
                if st.build.is_none() {
                    trash = self.switch(&mut st, &c.build)?;
                }
                let b = st.build.clone().unwrap_or_default();
                drop(st);
                if let Some(t) = trash {
                    let _ = std::fs::remove_dir_all(t);
                }
                if b == c.build {
                    Ok((b, idx))
                } else {
                    Err(Error::new("busy", "the device moved to another build meanwhile"))
                }
            }),
        };
        let Ok((build, idx)) = chosen else { return answer(0, 0, false) };
        let need = idx.tiles_near(&points, STREAM_BOX_DEG, STREAM_NEAR_DEG);
        let missing: Vec<TileRef> = {
            let st = self.st();
            need.iter().filter(|t| !st.has(&build, &t.path)).cloned().collect()
        };
        let reserve = self.reserve.load(Ordering::Relaxed);
        let need_bytes: u64 = missing.iter().map(|t| t.bytes).sum();
        if free_bytes(&self.dir).map(|f| f < need_bytes.saturating_add(reserve)).unwrap_or(false) {
            return answer(0, missing.len(), false);
        }
        let fetched = AtomicU64::new(0);
        let queue = Mutex::new(missing.into_iter());
        std::thread::scope(|sc| {
            for _ in 0..POOL {
                sc.spawn(|| loop {
                    if Instant::now() >= deadline || !self.may_use_network() {
                        break;
                    }
                    let Some(t) = queue.lock().ok().and_then(|mut q| q.next()) else { break };
                    if self.fetch_tile(&build, &t, Some(deadline)).is_ok() {
                        self.st().present.entry(build.clone()).or_default().insert(t.path.clone());
                        fetched.fetch_add(1, Ordering::Relaxed);
                    }
                });
            }
        });
        // Every tile of this route that belongs to no region is in the stream cache, used now; then the cap.
        let keep: HashSet<String> = need.iter().map(|t| t.path.clone()).collect();
        {
            let st = self.st();
            let db = self.db();
            let stamp = self.tick() as i64;
            for t in &need {
                if st.has(&build, &t.path) && !st.wants(&build, &t.path) {
                    let _ = db.execute(
                        "INSERT INTO stream2(component, build, path, bytes, last_used) VALUES ('routing', ?1, ?2, ?3, ?4)
                         ON CONFLICT(component, build, path) DO UPDATE SET last_used = excluded.last_used",
                        params![build, t.path, t.bytes as i64, stamp],
                    );
                }
            }
        }
        self.evict(&build, &keep);
        let still = {
            let st = self.st();
            need.iter().filter(|t| !st.has(&build, &t.path)).count()
        };
        answer(fetched.load(Ordering::Relaxed) as usize, still, still == 0)
    }

    /// Least recently used first, the stream cache's tiles that no region uses go until the rest is within the cap (`keep`: the
    /// tiles of the route just prepared, which stay).
    fn evict(&self, build: &str, keep: &HashSet<String>) {
        let rows = self.stream_rows(build);
        let mut st = self.st();
        let only: Vec<(String, u64)> = rows.into_iter().filter(|(p, _)| !st.wants(build, p)).collect();
        let mut total: u64 = only.iter().map(|(_, n)| n).sum();
        let root = self.build_dir(build);
        for (p, n) in only {
            if total <= self.cap {
                break;
            }
            if keep.contains(&p) {
                continue;
            }
            let _ = self.db().execute("DELETE FROM stream2 WHERE component = 'routing' AND build = ?1 AND path = ?2", params![build, p]);
            let f = self.tile_file(build, &p);
            if std::fs::remove_file(&f).is_ok() {
                prune_empty(&root, &f);
            }
            if let Some(s) = st.present.get_mut(build) {
                s.remove(&p);
            }
            total -= n;
        }
    }

    fn check_update(&self) -> Result<Value> {
        let c = self.fetch_current(REQUEST_TIMEOUT)?;
        let (dev, no_regions) = {
            let st = self.st();
            (st.build.clone(), !st.any_routing())
        };
        // Nothing downloaded: the device simply moves to the newest build, there is nothing to update.
        if dev.as_deref() == Some(c.build.as_str()) || no_regions {
            let mut st = self.st();
            let mut trash = None;
            if !st.any_routing() && st.build.as_deref() != Some(c.build.as_str()) {
                trash = self.switch(&mut st, &c.build)?;
            }
            st.update = None;
            st.updating = None;
            let db = self.db();
            self.meta_set(&db, "update", None)?;
            self.meta_set(&db, "updating", None)?;
            drop(db);
            drop(st);
            if let Some(t) = trash {
                let _ = std::fs::remove_dir_all(t);
            }
            return Ok(json!({"build": c.build, "update": null}));
        }
        let idx = self.fetch_index(&c, REQUEST_TIMEOUT)?;
        let mut st = self.st();
        let mut seen = HashSet::new();
        let mut bytes = 0u64;
        for r in st.regions.iter().filter(|r| r.has(ROUTING)) {
            let Ok(shape) = geo::Shape::parse(&Value::String(r.geometry.clone())) else { continue };
            for t in idx.tiles_for(&shape) {
                if !st.has(&c.build, &t.path) && seen.insert(t.path.clone()) {
                    bytes += t.gz;
                }
            }
        }
        if st.updating.as_deref().map(|u| u != c.build).unwrap_or(false) {
            // An update to a build that is no longer the newest: it starts over at the newest.
            st.updating = None;
        }
        st.update = Some((c.build.clone(), bytes));
        let db = self.db();
        self.meta_set(&db, "update", Some(&json!([c.build, bytes]).to_string()))?;
        if st.updating.is_none() {
            self.meta_set(&db, "updating", None)?;
        }
        Ok(json!({"build": c.build, "update": {"build": c.build, "download_bytes": bytes}}))
    }

    fn update(&self) -> Result<Value> {
        let pending = self.st().update.clone();
        let target = match pending {
            Some((b, _)) => b,
            None => match self.check_update()?["update"]["build"].as_str() {
                Some(b) => b.to_string(),
                None => {
                    let st = self.st();
                    return Ok(json!({"ok": true, "build": st.build, "download_bytes": 0}));
                }
            },
        };
        let idx = self.index_of(&target, REQUEST_TIMEOUT)?;
        let mut st = self.st();
        if st.build.as_deref() == Some(target.as_str()) {
            return Ok(json!({"ok": true, "build": target, "download_bytes": 0}));
        }
        // Each region's tiles of the new build, worked out while the state is held so that no region is left without them.
        let mut lists = Vec::new();
        for r in st.regions.iter().filter(|r| r.has(ROUTING)) {
            let shape = geo::Shape::parse(&Value::String(r.geometry.clone())).map_err(|m| Error::new("internal", format!("{}: {m}", r.id)))?;
            lists.push((r.id.clone(), idx.tiles_for(&shape)));
        }
        {
            let mut db = self.db();
            let tx = db.transaction()?;
            tx.execute("DELETE FROM region_tiles2 WHERE component = 'routing' AND build = ?1", params![target])?;
            {
                let mut ins = tx.prepare("INSERT INTO region_tiles2(region, component, build, path, bytes, sha256, gz) VALUES (?1, 'routing', ?2, ?3, ?4, ?5, ?6)")?;
                for (id, tiles) in &lists {
                    for t in tiles {
                        ins.execute(params![id, target, t.path, t.bytes as i64, t.sha256, t.gz as i64])?;
                    }
                }
            }
            tx.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('updating', ?1)", params![target])?;
            tx.commit()?;
        }
        for (id, tiles) in lists {
            if let Some(r) = st.regions.iter_mut().find(|r| r.id == id) {
                r.lists.insert(target.clone(), tiles.into_iter().map(|t| (t.path.clone(), t)).collect());
                // A region that failed is tried again in the new build.
                r.error = None;
            }
        }
        {
            let db = self.db();
            let _ = db.execute("UPDATE regions SET error = NULL", []);
        }
        std::fs::create_dir_all(self.build_dir(&target))?;
        st.present.entry(target.clone()).or_default();
        st.updating = Some(target.clone());
        let left = Self::left_to_fetch(&st, &target);
        st.update = Some((target.clone(), left));
        drop(st);
        self.poke();
        Ok(json!({"ok": true, "build": target, "download_bytes": left}))
    }
}

/// Brings an older regions.sqlite to this layout: regions get their parts (an old region is routing only) and their places
/// error; the tile lists and the stream cache get a component (old rows are routing's).
fn migrate(db: &mut Connection) -> Result<()> {
    let tx = db.transaction()?;
    let cols: Vec<String> = {
        let mut q = tx.prepare("PRAGMA table_info(regions)")?;
        let rows = q.query_map([], |r| r.get::<_, String>(1))?;
        rows.collect::<rusqlite::Result<_>>()?
    };
    if !cols.iter().any(|c| c == "parts") {
        tx.execute_batch("ALTER TABLE regions ADD COLUMN parts TEXT NOT NULL DEFAULT '[\"routing\"]';")?;
    }
    if !cols.iter().any(|c| c == "places_error") {
        tx.execute_batch("ALTER TABLE regions ADD COLUMN places_error TEXT;")?;
    }
    tx.execute_batch(
        "CREATE TABLE IF NOT EXISTS region_tiles2(region TEXT NOT NULL, component TEXT NOT NULL, build TEXT NOT NULL, path TEXT NOT NULL,
                                                  bytes INTEGER NOT NULL, sha256 TEXT NOT NULL, gz INTEGER NOT NULL,
                                                  PRIMARY KEY(region, component, build, path));
         CREATE TABLE IF NOT EXISTS stream2(component TEXT NOT NULL, build TEXT NOT NULL, path TEXT NOT NULL, bytes INTEGER NOT NULL,
                                            last_used INTEGER NOT NULL, PRIMARY KEY(component, build, path));",
    )?;
    let has = |t: &str| -> Result<bool> { Ok(tx.query_row("SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1", params![t], |r| r.get::<_, i64>(0))? > 0) };
    if has("region_tiles")? {
        tx.execute_batch(
            "INSERT OR IGNORE INTO region_tiles2(region, component, build, path, bytes, sha256, gz)
               SELECT region, 'routing', build, path, bytes, sha256, gz FROM region_tiles;
             DROP TABLE region_tiles;",
        )?;
    }
    if has("stream")? {
        tx.execute_batch(
            "INSERT OR IGNORE INTO stream2(component, build, path, bytes, last_used) SELECT 'routing', build, path, bytes, last_used FROM stream;
             DROP TABLE stream;",
        )?;
    }
    tx.commit()?;
    Ok(())
}

/// One engine per folder in the process: the app's Regions screen and the navigate tool's streaming share it.
fn registry() -> &'static Mutex<HashMap<PathBuf, Weak<Regions>>> {
    static R: OnceLock<Mutex<HashMap<PathBuf, Weak<Regions>>>> = OnceLock::new();
    R.get_or_init(Default::default)
}

impl Regions {
    /// Opens (or creates) regions.sqlite and the tile folders in `cfg.dir`, puts right what a stop left (hidden temp files,
    /// the folder of a build no longer used) and starts the download thread, which carries on with any region not complete.
    pub fn open(cfg: Config) -> Result<Regions> {
        std::fs::create_dir_all(cfg.dir.join("tiles"))?;
        std::fs::create_dir_all(cfg.dir.join("index"))?;
        let mut db = Connection::open(cfg.dir.join("regions.sqlite"))?;
        db.execute_batch(
            "PRAGMA journal_mode = WAL;
             PRAGMA synchronous = NORMAL;
             CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT NOT NULL);
             CREATE TABLE IF NOT EXISTS regions(id TEXT PRIMARY KEY, name TEXT NOT NULL, geometry TEXT NOT NULL,
                                                added INTEGER NOT NULL, error TEXT);",
        )?;
        migrate(&mut db)?;
        let meta = |k: &str| -> Result<Option<String>> { Ok(db.query_row("SELECT value FROM meta WHERE key = ?1", params![k], |r| r.get(0)).optional()?) };
        let mut st = State {
            build: meta("build")?.filter(|b| index::safe_build(b)),
            updating: meta("updating")?.filter(|b| index::safe_build(b)),
            current: meta("current")?.and_then(|c| serde_json::from_str(&c).ok()),
            update: meta("update")?.and_then(|u| serde_json::from_str::<(String, u64)>(&u).ok()),
            ..State::default()
        };
        {
            let mut q = db.prepare("SELECT id, name, geometry, added, error, parts, places_error FROM regions ORDER BY added, id")?;
            let rows = q.query_map([], |r| {
                let parts: String = r.get(5)?;
                let parts: Vec<String> = serde_json::from_str(&parts).unwrap_or_else(|_| vec![ROUTING.to_string()]);
                Ok(Region {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    geometry: r.get(2)?,
                    added: r.get::<_, i64>(3)? as u64,
                    error: r.get(4)?,
                    lists: BTreeMap::new(),
                    parts,
                    places: BTreeMap::new(),
                    places_error: r.get(6)?,
                })
            })?;
            for r in rows {
                st.regions.push(r?);
            }
            // A config without places_base_url: a region keeps its places part on record, and nothing works on it.
            let mut q = db.prepare("SELECT region, component, build, path, bytes, sha256, gz FROM region_tiles2")?;
            let rows = q.query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, String>(2)?,
                    TileRef { path: r.get(3)?, bytes: r.get::<_, i64>(4)? as u64, sha256: r.get(5)?, gz: r.get::<_, i64>(6)? as u64 },
                ))
            })?;
            let by_id: HashMap<String, usize> = st.regions.iter().enumerate().map(|(i, r)| (r.id.clone(), i)).collect();
            for row in rows {
                let (region, component, build, t) = row?;
                if let Some(&i) = by_id.get(&region) {
                    let r = &mut st.regions[i];
                    let lists = if component == PLACES { &mut r.places } else { &mut r.lists };
                    lists.entry(build).or_default().insert(t.path.clone(), t);
                }
            }
        }
        let tick: Option<i64> = db.query_row("SELECT MAX(last_used) FROM stream2", [], |r| r.get(0))?;
        let places = cfg.places_base_url.as_deref().map(str::trim).filter(|u| !u.is_empty()).map(|u| {
            let mut base = u.to_string();
            if !base.ends_with('/') {
                base.push('/');
            }
            PlacesPart::new(&cfg.dir, base, cfg.places_stream_cap_bytes)
        });
        if let Some(p) = &places {
            p.open(&db, &mut st)?;
        }
        // The tile folders: the device's build and the one an update is filling are kept (and what is whole in them is
        // counted); any other (a build switched away from before its folder was deleted) goes.
        let keep: Vec<String> = [st.build.clone(), st.updating.clone()].into_iter().flatten().collect();
        if let Ok(rd) = std::fs::read_dir(cfg.dir.join("tiles")) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if !keep.contains(&name) {
                    let p = e.path();
                    let _ = if p.is_dir() { std::fs::remove_dir_all(&p) } else { std::fs::remove_file(&p) };
                }
            }
        }
        for b in &keep {
            let root = cfg.dir.join("tiles").join(b);
            let mut have = HashSet::new();
            scan_tiles(&root, &root, &mut have);
            st.present.insert(b.clone(), have);
        }
        let mut base = cfg.base_url.trim().to_string();
        if !base.ends_with('/') {
            base.push('/');
        }
        let ua = cfg.user_agent.clone().filter(|u| !u.trim().is_empty()).unwrap_or_else(http::default_user_agent);
        let inner = Arc::new(Inner {
            dir: cfg.dir.clone(),
            base,
            cap: cfg.stream_cap_bytes,
            reserve: AtomicU64::new(cfg.reserve_bytes.unwrap_or(DEFAULT_RESERVE)),
            agent: http::agent(&ua),
            db: Mutex::new(db),
            st: Mutex::new(st),
            indexes: Mutex::new(HashMap::new()),
            network: AtomicBool::new(true),
            stop: AtomicBool::new(false),
            wake: (Mutex::new(false), Condvar::new()),
            tick: AtomicU64::new(tick.unwrap_or(0).max(0) as u64),
            seq: AtomicU64::new(0),
            places,
        });
        let w = inner.clone();
        let worker = std::thread::Builder::new().name("cache-regions".into()).spawn(move || w.work()).map_err(|e| Error::new("internal", format!("could not start the download thread: {e}")))?;
        Ok(Regions { inner, worker: Mutex::new(Some(worker)) })
    }

    /// The engine of `cfg.dir` if this process has one open, else a new one. A second open of the same folder gets the first
    /// engine (its own config is not used), so the app's Regions screen and the navigate tool always share one.
    pub fn open_shared(cfg: Config) -> Result<Arc<Regions>> {
        std::fs::create_dir_all(&cfg.dir)?;
        let key = cfg.dir.canonicalize().unwrap_or_else(|_| cfg.dir.clone());
        let mut reg = registry().lock().unwrap_or_else(|e| e.into_inner());
        if let Some(e) = reg.get(&key).and_then(|w| w.upgrade()) {
            return Ok(e);
        }
        let e = Arc::new(Regions::open(cfg)?);
        reg.retain(|_, w| w.strong_count() > 0);
        reg.insert(key, Arc::downgrade(&e));
        Ok(e)
    }

    /// The whole interface: `method` with JSON `args`, a JSON answer. Methods: status, plan, add, remove, stream, set_policy,
    /// check_update, update (docs/REGIONS.md, and docs/PLACES-TILES.md for the places part).
    pub fn call(&self, method: &str, args: &Value) -> Result<Value> {
        let inner = &self.inner;
        let component = args.get("component").and_then(|v| v.as_str());
        if let Some(c) = component.filter(|c| *c != ROUTING && *c != PLACES) {
            return Err(Error::bad_args(format!("unknown component {c:?}")));
        }
        match method {
            "status" => Ok(inner.status()),
            "plan" => inner.plan(args),
            "add" => inner.add(args),
            "remove" => inner.remove(args),
            "stream" if component == Some(PLACES) => {
                let points = points_of(args.get("points"));
                let ms = args.get("timeout_ms").and_then(|v| v.as_u64()).unwrap_or(DEFAULT_PLACES_STREAM_TIMEOUT_MS);
                Ok(inner.p_stream(&points, Duration::from_millis(ms)).to_json())
            }
            "stream" => Ok(inner.stream(args)),
            "set_policy" => {
                if let Some(n) = args.get("network").and_then(|v| v.as_bool()) {
                    inner.network.store(n, Ordering::Relaxed);
                }
                if let Some(r) = args.get("reserve_bytes").and_then(|v| v.as_u64()) {
                    inner.reserve.store(r, Ordering::Relaxed);
                }
                inner.poke();
                Ok(json!({"ok": true}))
            }
            "check_update" | "update" => {
                let routing = |m: &str| if m == "update" { inner.update() } else { inner.check_update() };
                let places = |m: &str| if m == "update" { inner.p_update() } else { inner.p_check_update() };
                match component {
                    Some(PLACES) => places(method),
                    Some(_) => routing(method),
                    // Both: routing's answer as before, with the places part's beside it.
                    None => {
                        let mut v = routing(method)?;
                        if inner.places.is_some() {
                            v["places"] = places(method).unwrap_or_else(|e| Inner::part_error(&e));
                        }
                        Ok(v)
                    }
                }
            }
            _ => Err(Error::bad_args(format!("unknown method {method}"))),
        }
    }

    /// The merged places database every search reads (`CURRENT`'s); None until the device has a places build.
    pub fn places_db(&self) -> Option<PathBuf> {
        let p = self.inner.places.as_ref()?;
        let b = self.inner.st().p.build.clone()?;
        Some(p.db_file(&b))
    }

    /// The folder of `CURRENT` and the merged databases (what `cache_places` reads as `merged_dir`); None with places off.
    pub fn places_dir(&self) -> Option<PathBuf> {
        self.inner.places.as_ref().map(|p| p.dir.clone())
    }

    /// Goes up by one on every places merge, removal and build switch.
    pub fn places_generation(&self) -> u64 {
        self.inner.places.as_ref().map(|p| p.generation()).unwrap_or(0)
    }

    /// Before a search at a point: fetch and merge the places tiles around it that are not here yet (the places `stream`),
    /// waiting at most `wait`.
    pub fn prepare_places(&self, lat: f64, lon: f64, wait: Duration) -> StreamAnswer {
        self.inner.p_stream(&[(lat, lon)], wait)
    }

    /// The folder Valhalla routes on (`mjolnir.tile_dir`): the device's build. None until the device has one.
    pub fn tile_dir(&self) -> Option<PathBuf> {
        let b = self.inner.st().build.clone()?;
        Some(self.inner.build_dir(&b))
    }

    /// Whether a route can be tried: the device's build has tiles here, or the network may be used to fetch them (a device
    /// that has downloaded nothing routes online on streamed tiles).
    pub fn routable(&self) -> bool {
        if self.inner.may_use_network() {
            return true;
        }
        let st = self.inner.st();
        st.build.as_ref().map(|b| st.present.get(b).map(|p| !p.is_empty()).unwrap_or(false)).unwrap_or(false)
    }

    /// The downloaded regions' names, in the order they were added ("Southern Idaho, Utah"); None when there are none.
    pub fn region_names(&self) -> Option<String> {
        let st = self.inner.st();
        let names: Vec<&str> = st.regions.iter().map(|r| r.name.as_str()).collect();
        (!names.is_empty()).then(|| names.join(", "))
    }

    /// Before a route is computed: fetch the tiles near its points ([lat, lon]) that are not here yet, within the default
    /// timeout. Whatever happens, the route goes ahead on the tiles there are.
    pub fn prepare(&self, points: &[(f64, f64)]) {
        let pts: Vec<Value> = points.iter().map(|(a, o)| json!([a, o])).collect();
        let _ = self.inner.stream(&json!({"points": pts, "timeout_ms": DEFAULT_STREAM_TIMEOUT_MS}));
    }

    /// Stops the download thread (after the tiles in flight) and waits for it.
    pub fn close(&self) {
        self.inner.stop.store(true, Ordering::Relaxed);
        self.inner.poke();
        if let Some(w) = self.worker.lock().unwrap_or_else(|e| e.into_inner()).take() {
            let _ = w.join();
        }
    }
}

impl Drop for Regions {
    fn drop(&mut self) {
        self.close();
    }
}
