//! The places part of a region (docs/PLACES-TILES.md): places, towns and addresses cut on Valhalla's level 1 grid and
//! published like the routing tiles, under their own address, with their own build, index, update and stream cache.
//!
//! The phone keeps one database per places build (`places/<build>.sqlite`, made by `cache_places::merged`) and merges each
//! tile into it as it arrives; `places/CURRENT` names the build every search reads. The engine is the database's one
//! writer: merges run one at a time through `PlacesPart::dbs`, while the searches read through their own connections.
//! Which tiles the phone has is the database's `tiles` table, which changes in the same transaction as the data.
//!
//! Locks are taken in this order only: the state, then the writers (`dbs`), then regions.sqlite; a merge holds the writers
//! alone and takes the state after it lets them go.

use super::*;
use cache_places::merged;
use cache_places::schema::{parse_tile_path_l1, tile_path_l1, TILE_SCHEMA};
use index::CommonRef;

/// A search fetches the level 1 places tiles within this many degrees of its point (one to four tiles).
pub const PLACES_STREAM_DEG: f64 = 0.5;
/// How long a places `stream` waits by default.
pub const DEFAULT_PLACES_STREAM_TIMEOUT_MS: u64 = 3_000;
/// The longest a common file may be unpacked.
const MAX_COMMON: u64 = 256 * 1024 * 1024;

/// What a places `stream` did: tiles fetched and merged, tiles still on their way when the wait ended (they land in the
/// background), tiles that could not be had, and whether every tile for the points is on the phone.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct StreamAnswer {
    pub fetched: usize,
    pub pending: usize,
    pub missing: usize,
    pub ok: bool,
}

impl StreamAnswer {
    pub fn to_json(&self) -> Value {
        json!({"fetched": self.fetched, "pending": self.pending, "missing": self.missing, "ok": self.ok})
    }
}

/// What the device knows of places (the in-memory side of the `places.*` meta keys and the merged databases).
#[derive(Default)]
pub(crate) struct PState {
    /// The build every search reads (`CURRENT`).
    pub build: Option<String>,
    /// The last current.json the places server gave.
    pub current: Option<Current>,
    /// A newer build found by check_update, and the bytes to fetch for it.
    pub update: Option<(String, u64)>,
    /// The build `update` is filling.
    pub updating: Option<String>,
    /// Per build, the tiles merged in (from each database's `tiles` table).
    pub present: HashMap<String, HashSet<String>>,
    /// After a failed attempt to set up the places build, the worker tries again then.
    pub retry_at: Option<Instant>,
}

pub(crate) struct PlacesPart {
    pub base: String,
    pub cap: u64,
    /// `<dir>/places`.
    pub dir: PathBuf,
    /// The writers, one per build's database (the device's, and an update's while it fills).
    dbs: Mutex<HashMap<String, Connection>>,
    indexes: Mutex<HashMap<String, Arc<Index>>>,
    /// Tiles being fetched now, by (build, path): a second fetch of one waits for the first instead.
    inflight: (Mutex<HashSet<(String, String)>>, Condvar),
    generation: AtomicU64,
    /// Held while the first places build is set up, so two callers never make two databases.
    init: Mutex<()>,
}

fn perr(e: cache_places::pack::Error) -> Error {
    Error::new("io", e.message)
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// A merged database opened as the writer.
fn open_writer(path: &Path) -> Result<Connection> {
    let c = Connection::open(path)?;
    c.busy_timeout(Duration::from_secs(10))?;
    c.execute_batch("PRAGMA synchronous = NORMAL;")?;
    Ok(c)
}

fn remove_db_files(db: &Path) {
    for ext in ["", "-wal", "-shm"] {
        let _ = std::fs::remove_file(format!("{}{ext}", db.display()));
    }
}

impl PlacesPart {
    pub fn new(dir: &Path, base: String, cap: u64) -> PlacesPart {
        PlacesPart {
            base,
            cap,
            dir: dir.join("places"),
            dbs: Mutex::new(HashMap::new()),
            indexes: Mutex::new(HashMap::new()),
            inflight: (Mutex::new(HashSet::new()), Condvar::new()),
            generation: AtomicU64::new(0),
            init: Mutex::new(()),
        }
    }

    pub fn db_file(&self, build: &str) -> PathBuf {
        self.dir.join(format!("{build}.sqlite"))
    }

    fn common_file(&self, build: &str) -> PathBuf {
        self.dir.join(build).join("common.sqlite")
    }

    fn index_file(&self, build: &str) -> PathBuf {
        self.dir.join("index").join(format!("{build}.tsv"))
    }

    fn current_file(&self) -> PathBuf {
        self.dir.join("CURRENT")
    }

    /// Where a tile waits between its download and its merge.
    fn incoming(&self, build: &str, path: &str) -> PathBuf {
        let mut p = self.dir.join(".incoming").join(build);
        for part in path.split('/') {
            p.push(part);
        }
        p.set_extension("sqlite");
        p
    }

    fn dbs(&self) -> MutexGuard<'_, HashMap<String, Connection>> {
        lock(&self.dbs)
    }

    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::Relaxed)
    }

    fn bump(&self) {
        self.generation.fetch_add(1, Ordering::Relaxed);
    }

    /// Claims (build, path) for one fetch; false when another fetch has it.
    fn claim(&self, build: &str, path: &str) -> bool {
        lock(&self.inflight.0).insert((build.to_string(), path.to_string()))
    }

    fn release(&self, build: &str, path: &str) {
        lock(&self.inflight.0).remove(&(build.to_string(), path.to_string()));
        self.inflight.1.notify_all();
    }

    fn fetching(&self, build: &str, path: &str) -> bool {
        lock(&self.inflight.0).contains(&(build.to_string(), path.to_string()))
    }

    /// Opens what the last run left: `CURRENT` and the meta keys say which builds are kept; any other database, common file
    /// and index goes, and so do tiles left between download and merge (they are fetched again). The tiles of each kept
    /// database are read from it.
    pub fn open(&self, db: &Connection, st: &mut State) -> Result<()> {
        std::fs::create_dir_all(self.dir.join("index"))?;
        let _ = std::fs::remove_dir_all(self.dir.join(".incoming"));
        let meta = |k: &str| -> Result<Option<String>> { Ok(db.query_row("SELECT value FROM meta WHERE key = ?1", params![k], |r| r.get(0)).optional()?) };
        let named = std::fs::read_to_string(self.current_file()).ok().map(|s| s.trim().to_string());
        let build = named.or(meta("places.build")?).filter(|b| index::safe_build(b)).filter(|b| self.db_file(b).is_file());
        if build.is_none() {
            let _ = std::fs::remove_file(self.current_file());
        }
        st.p.build = build.clone();
        st.p.updating = meta("places.updating")?.filter(|b| index::safe_build(b)).filter(|b| Some(b) != build.as_ref());
        st.p.current = meta("places.current")?.and_then(|c| serde_json::from_str(&c).ok());
        st.p.update = meta("places.update")?.and_then(|u| serde_json::from_str::<(String, u64)>(&u).ok());
        let keep: Vec<String> = [build, st.p.updating.clone()].into_iter().flatten().collect();
        if let Ok(rd) = std::fs::read_dir(&self.dir) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                let p = e.path();
                if name == "CURRENT" || name == "index" {
                    continue;
                }
                if p.is_dir() {
                    if !keep.contains(&name) {
                        let _ = std::fs::remove_dir_all(&p);
                    }
                    continue;
                }
                let stem = ["-wal", "-shm"].iter().fold(name.as_str(), |n, ext| n.strip_suffix(ext).unwrap_or(n));
                let of = stem.strip_suffix(".sqlite").map(str::to_string);
                if name.starts_with('.') || of.map(|b| !keep.contains(&b)).unwrap_or(true) {
                    let _ = std::fs::remove_file(&p);
                }
            }
        }
        if let Ok(rd) = std::fs::read_dir(self.dir.join("index")) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                if !keep.iter().any(|b| name == format!("{b}.tsv")) {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
        let mut dbs = self.dbs();
        for b in &keep {
            let f = self.db_file(b);
            if !f.is_file() {
                continue;
            }
            let c = open_writer(&f)?;
            let have = merged::tiles(&c).map_err(perr)?;
            st.p.present.insert(b.clone(), have.into_iter().map(tile_path_l1).collect());
            dbs.insert(b.clone(), c);
        }
        Ok(())
    }

    /// The writer of `build`'s database, opened when it is not yet; None when the database is not there.
    fn writer<'a>(&self, dbs: &'a mut HashMap<String, Connection>, build: &str) -> Option<&'a mut Connection> {
        if !dbs.contains_key(build) {
            let f = self.db_file(build);
            if !f.is_file() {
                return None;
            }
            dbs.insert(build.to_string(), open_writer(&f).ok()?);
        }
        dbs.get_mut(build)
    }
}

impl State {
    /// Whether a region needs this places tile of this build.
    pub(crate) fn p_wants(&self, build: &str, path: &str) -> bool {
        self.regions.iter().any(|r| r.places.get(build).map(|l| l.contains_key(path)).unwrap_or(false))
    }

    pub(crate) fn p_has(&self, build: &str, path: &str) -> bool {
        self.p.present.get(build).map(|p| p.contains(path)).unwrap_or(false)
    }

    /// The names of the regions with places, as the merged database's `region_name`.
    fn p_names(&self) -> String {
        self.regions.iter().filter(|r| r.has(PLACES)).map(|r| r.name.as_str()).collect::<Vec<_>>().join(", ")
    }

    /// The gzip bytes still to fetch of every region's places tiles of `build` (each tile once).
    fn p_left(&self, build: &str) -> u64 {
        let mut seen = HashSet::new();
        let mut n = 0;
        for t in self.regions.iter().filter_map(|r| r.places.get(build)).flat_map(|l| l.values()) {
            if !self.p_has(build, &t.path) && seen.insert(t.path.as_str()) {
                n += t.gz;
            }
        }
        n
    }
}

impl Inner {
    pub(crate) fn places(&self) -> Result<&PlacesPart> {
        self.places.as_ref().ok_or_else(|| Error::bad_args("places are not enabled (the regions config has no places_base_url)"))
    }

    fn p_get(&self, url: &str, timeout: Duration) -> Result<Vec<u8>> {
        if !self.may_use_network() {
            return Err(Error::offline(NO_NETWORK));
        }
        http::get(&self.agent, url, timeout).map_err(|f| match f {
            http::Fail::Net(m) => Error::offline(format!("the places server cannot be reached: {m}")),
            http::Fail::Status(_, m) => Error::new("fetch_failed", m),
        })
    }

    /// The places current.json, checked (a tile layout this version cannot read says so), and remembered.
    fn p_fetch_current(&self, p: &PlacesPart, timeout: Duration) -> Result<(Current, CommonRef)> {
        let body = self.p_get(&format!("{}current.json", p.base), timeout)?;
        let c: Current = serde_json::from_slice(&body).map_err(|e| Error::new("bad_response", format!("places current.json is not valid: {e}")))?;
        let common = c.check_places(TILE_SCHEMA).map_err(|m| Error::new("bad_response", m))?;
        let text = serde_json::to_string(&c).unwrap_or_default();
        let mut st = self.st();
        if st.p.current.as_ref() != Some(&c) {
            st.p.current = Some(c.clone());
            let db = self.db();
            self.meta_set(&db, "places.current", Some(&text))?;
        }
        Ok((c, common))
    }

    fn p_cached_index(&self, p: &PlacesPart, build: &str) -> Option<Arc<Index>> {
        if let Some(i) = lock(&p.indexes).get(build) {
            return Some(i.clone());
        }
        let text = std::fs::read_to_string(p.index_file(build)).ok()?;
        let idx = Arc::new(Index::parse(build, &text).ok()?);
        lock(&p.indexes).insert(build.to_string(), idx.clone());
        Some(idx)
    }

    fn p_fetch_index(&self, p: &PlacesPart, c: &Current, timeout: Duration) -> Result<Arc<Index>> {
        if let Some(i) = self.p_cached_index(p, &c.build) {
            return Ok(i);
        }
        let gz = self.p_get(&format!("{}{}", p.base, c.index), timeout)?;
        if sha256_hex(&gz) != c.index_sha256.to_ascii_lowercase() {
            return Err(Error::new("bad_response", format!("the index of {} does not match its checksum", c.build)));
        }
        let raw = gunzip(&gz, MAX_INDEX).map_err(|e| Error::new("bad_response", format!("the index of {} is not valid gzip: {e}", c.build)))?;
        let text = String::from_utf8(raw).map_err(|_| Error::new("bad_response", format!("the index of {} is not text", c.build)))?;
        let idx = Arc::new(Index::parse(&c.build, &text).map_err(|m| Error::new("bad_response", m))?);
        write_whole(&p.index_file(&c.build), text.as_bytes(), self.seq())?;
        lock(&p.indexes).insert(c.build.clone(), idx.clone());
        Ok(idx)
    }

    /// A places build's index: from this device, or fetched when it is the build current.json names.
    fn p_index_of(&self, p: &PlacesPart, build: &str, timeout: Duration) -> Result<Arc<Index>> {
        if let Some(i) = self.p_cached_index(p, build) {
            return Ok(i);
        }
        let cur = self.st().p.current.clone();
        match cur {
            Some(c) if c.build == build => self.p_fetch_index(p, &c, timeout),
            _ => Err(Error::offline(format!("the index of {build} is not on this device"))),
        }
    }

    /// A build's common file on the device (kept to make the database again), fetched and checked when it is not.
    fn p_fetch_common(&self, p: &PlacesPart, build: &str, common: &CommonRef, timeout: Duration) -> Result<PathBuf> {
        let f = p.common_file(build);
        if std::fs::read(&f).map(|b| sha256_hex(&b) == common.sha256).unwrap_or(false) {
            return Ok(f);
        }
        let gz = self.p_get(&format!("{}{}", p.base, common.path), timeout)?;
        let limit = if common.bytes > 0 { common.bytes + 1 } else { MAX_COMMON };
        let raw = gunzip(&gz, limit).map_err(|e| Error::new("bad_response", format!("the common file of {build} is not valid gzip: {e}")))?;
        if (common.bytes > 0 && raw.len() as u64 != common.bytes) || sha256_hex(&raw) != common.sha256 {
            return Err(Error::new("bad_response", format!("the common file of {build} does not match its checksum")));
        }
        write_whole(&f, &raw, self.seq())?;
        Ok(f)
    }

    /// The places build on the device, with its index. With none yet, the newest is set up: current.json, the index and
    /// the common file are fetched, the database is created and `CURRENT` names it.
    pub(crate) fn p_ensure(&self, timeout: Duration) -> Result<(String, Arc<Index>)> {
        let p = self.places()?;
        // The build is read into a local first: a guard in an `if let` scrutinee lives through its body, and
        // p_index_of locks the state again (a deadlock whenever the index was not in memory).
        let built = self.st().p.build.clone();
        if let Some(b) = built {
            let idx = self.p_index_of(p, &b, timeout)?;
            return Ok((b, idx));
        }
        let _one = lock(&p.init);
        let built = self.st().p.build.clone();
        if let Some(b) = built {
            let idx = self.p_index_of(p, &b, timeout)?;
            return Ok((b, idx));
        }
        let (c, common) = self.p_fetch_current(p, timeout)?;
        let idx = self.p_fetch_index(p, &c, timeout)?;
        let common_file = self.p_fetch_common(p, &c.build, &common, timeout)?;
        let db = p.db_file(&c.build);
        remove_db_files(&db);
        let conn = merged::create(&db, &common_file).map_err(perr)?;
        write_whole(&p.current_file(), c.build.as_bytes(), self.seq())?;
        let mut st = self.st();
        merged::set_regions(&conn, &st.p_names()).map_err(perr)?;
        st.p.build = Some(c.build.clone());
        st.p.present.insert(c.build.clone(), HashSet::new());
        {
            let db = self.db();
            self.meta_set(&db, "places.build", Some(&c.build))?;
        }
        self.p_fill_lists(&mut st, &c.build, &idx)?;
        p.dbs().insert(c.build.clone(), conn);
        drop(st);
        p.bump();
        Ok((c.build, idx))
    }

    /// Every region with places that has no tile list of `build` yet gets one, from its outline and the build's index.
    fn p_fill_lists(&self, st: &mut State, build: &str, idx: &Index) -> Result<()> {
        let db = self.db();
        for r in st.regions.iter_mut().filter(|r| r.has(PLACES) && !r.places.contains_key(build)) {
            let tiles = geo::Shape::parse(&Value::String(r.geometry.clone())).map(|s| idx.tiles_for_level(&s, 1)).unwrap_or_default();
            let mut ins = db.prepare("INSERT OR REPLACE INTO region_tiles2(region, component, build, path, bytes, sha256, gz) VALUES (?1, 'places', ?2, ?3, ?4, ?5, ?6)")?;
            for t in &tiles {
                ins.execute(params![r.id, build, t.path, t.bytes as i64, t.sha256, t.gz as i64])?;
            }
            r.places.insert(build.to_string(), tiles.into_iter().map(|t| (t.path.clone(), t)).collect());
        }
        Ok(())
    }

    pub(crate) fn p_set_names(&self, st: &State) {
        let Ok(p) = self.places() else { return };
        let names = st.p_names();
        let mut dbs = p.dbs();
        for c in dbs.values_mut() {
            let _ = merged::set_regions(c, &names);
        }
    }

    // ---- one tile ----

    /// GET, unpack and check one places tile (tried again up to [`TRIES`] times like a routing tile), then merge it into
    /// `build`'s database. A tile the database refuses (another layout or build) is the tile's fault.
    fn p_fetch_tile(&self, p: &PlacesPart, build: &str, t: &TileRef, deadline: Option<Instant>) -> std::result::Result<(), TileFail> {
        let tile = parse_tile_path_l1(&t.path).ok_or_else(|| TileFail::Bad(format!("{} is not a level 1 tile", t.path)))?;
        let url = format!("{}{}/{}.sqlite.gz", p.base, build, t.path);
        let mut last = String::new();
        let mut raw = None;
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
                    Ok(r) => {
                        raw = Some(r);
                        break;
                    }
                    Err(m) => last = m,
                },
            }
        }
        let Some(raw) = raw else { return Err(TileFail::Bad(format!("{last} (tried {TRIES} times)"))) };
        let file = p.incoming(build, &t.path);
        write_whole(&file, &raw, self.seq()).map_err(|e| TileFail::Later(format!("could not write {}: {e}", t.path)))?;
        let mut dbs = p.dbs();
        let Some(c) = p.writer(&mut dbs, build) else {
            let _ = std::fs::remove_file(&file);
            return Err(TileFail::Later(format!("the places database of {build} is not there")));
        };
        match merged::merge_tile(c, tile, &file, &t.sha256, t.bytes) {
            Ok(_) => {
                let _ = merged::maintain(c);
                drop(dbs);
                p.bump();
                Ok(())
            }
            Err(e) => {
                let _ = std::fs::remove_file(&file);
                Err(TileFail::Bad(format!("{}: {}", t.path, e.message)))
            }
        }
    }

    /// A places tile is merged in. A stream's tile that no region wants is a stream-cache entry; a region's tile whose region
    /// went while it was on its way goes again.
    fn p_landed(&self, build: &str, t: &TileRef, stream: bool) {
        let mut st = self.st();
        st.p.present.entry(build.to_string()).or_default().insert(t.path.clone());
        if st.p_wants(build, &t.path) {
            return;
        }
        if stream && st.p.build.as_deref() == Some(build) {
            let stamp = self.tick() as i64;
            let _ = self.db().execute(
                "INSERT INTO stream2(component, build, path, bytes, last_used) VALUES ('places', ?1, ?2, ?3, ?4)
                 ON CONFLICT(component, build, path) DO UPDATE SET last_used = excluded.last_used",
                params![build, t.path, t.bytes as i64, stamp],
            );
        } else {
            self.p_delete_unused(&mut st, build, std::iter::once(&t.path));
        }
    }

    /// A places tile that could not be had: the places part of every region that needs it fails, with the reason.
    fn p_tile_failed(&self, build: &str, path: &str, msg: &str) {
        let mut st = self.st();
        let db = self.db();
        for r in st.regions.iter_mut().filter(|r| r.places_error.is_none()) {
            if r.places.get(build).map(|l| l.contains_key(path)).unwrap_or(false) {
                r.places_error = Some(msg.to_string());
                let _ = db.execute("UPDATE regions SET places_error = ?1 WHERE id = ?2", params![msg, r.id]);
            }
        }
    }

    fn p_stream_rows(&self, build: &str) -> Vec<(String, u64)> {
        let db = self.db();
        let Ok(mut q) = db.prepare("SELECT path, bytes FROM stream2 WHERE component = 'places' AND build = ?1 ORDER BY last_used") else { return Vec::new() };
        let rows: Vec<(String, u64)> = match q.query_map(params![build], |r| Ok((r.get::<_, String>(0)?, r.get::<_, i64>(1)? as u64))) {
            Ok(rows) => rows.flatten().collect(),
            Err(_) => Vec::new(),
        };
        rows
    }

    /// Removes from `build`'s database those of `paths` that no region and no stream-cache entry uses. Returns how many went.
    pub(crate) fn p_delete_unused<'a>(&self, st: &mut State, build: &str, paths: impl Iterator<Item = &'a String>) -> usize {
        let Ok(p) = self.places() else { return 0 };
        let streamed: HashSet<String> = self.p_stream_rows(build).into_iter().map(|(p, _)| p).collect();
        let mut dbs = p.dbs();
        let mut n = 0;
        for path in paths {
            if st.p_wants(build, path) || streamed.contains(path) || !st.p_has(build, path) {
                continue;
            }
            let (Some(tile), Some(c)) = (parse_tile_path_l1(path), p.writer(&mut dbs, build)) else { continue };
            if merged::remove_tile(c, tile).is_ok() {
                n += 1;
                if let Some(s) = st.p.present.get_mut(build) {
                    s.remove(path);
                }
            }
        }
        if n > 0 {
            if let Some(c) = p.writer(&mut dbs, build) {
                let _ = merged::maintain(c);
            }
            p.bump();
        }
        n
    }

    /// Least recently used first, the places stream cache's tiles that no region uses go until the rest is within the cap
    /// (`keep`: the tiles of the search just prepared, which stay).
    fn p_evict(&self, p: &PlacesPart, build: &str, keep: &HashSet<String>) {
        let rows = self.p_stream_rows(build);
        let mut st = self.st();
        let only: Vec<(String, u64)> = rows.into_iter().filter(|(p, _)| !st.p_wants(build, p)).collect();
        let mut total: u64 = only.iter().map(|(_, n)| n).sum();
        let mut dbs = p.dbs();
        let mut gone = 0;
        for (path, n) in only {
            if total <= p.cap {
                break;
            }
            if keep.contains(&path) {
                continue;
            }
            let _ = self.db().execute("DELETE FROM stream2 WHERE component = 'places' AND build = ?1 AND path = ?2", params![build, path]);
            if let (Some(tile), Some(c)) = (parse_tile_path_l1(&path), p.writer(&mut dbs, build)) {
                if merged::remove_tile(c, tile).is_ok() {
                    gone += 1;
                }
            }
            if let Some(s) = st.p.present.get_mut(build) {
                s.remove(&path);
            }
            total -= n;
        }
        if gone > 0 {
            p.bump();
        }
    }

    // ---- the worker ----

    /// Whether the worker should first set up places: a region wants places but there is no build, or a region has no
    /// tile list of the build being filled yet.
    pub(crate) fn p_needs_init(&self) -> bool {
        if self.places.is_none() || !self.may_use_network() {
            return false;
        }
        let st = self.st();
        if st.p.retry_at.is_some_and(|t| Instant::now() < t) {
            return false;
        }
        let target = st.p.updating.clone().or_else(|| st.p.build.clone());
        st.regions.iter().any(|r| r.has(PLACES) && r.places_error.is_none() && target.as_ref().map(|b| !r.places.contains_key(b)).unwrap_or(true))
    }

    pub(crate) fn p_init(&self) {
        let res = (|| -> Result<()> {
            let p = self.places()?;
            let (build, idx) = self.p_ensure(REQUEST_TIMEOUT)?;
            let updating = self.st().p.updating.clone();
            let uidx = match &updating {
                Some(u) => Some(self.p_index_of(p, u, REQUEST_TIMEOUT)?),
                None => None,
            };
            let mut st = self.st();
            self.p_fill_lists(&mut st, &build, &idx)?;
            if let (Some(u), Some(ui)) = (updating, uidx) {
                self.p_fill_lists(&mut st, &u, &ui)?;
            }
            st.p.retry_at = None;
            self.p_set_names(&st);
            Ok(())
        })();
        if let Err(e) = res {
            let mut st = self.st();
            st.p.retry_at = Some(Instant::now() + RETRY_LATER);
            // Not the network: the places of every region that waits for them fail, with the reason (an add tries again).
            if e.code != "offline" {
                let target = st.p.updating.clone().or_else(|| st.p.build.clone());
                let db = self.db();
                for r in st.regions.iter_mut().filter(|r| r.has(PLACES) && r.places_error.is_none()) {
                    if target.as_ref().map(|b| !r.places.contains_key(b)).unwrap_or(true) {
                        r.places_error = Some(e.message.clone());
                        let _ = db.execute("UPDATE regions SET places_error = ?1 WHERE id = ?2", params![e.message, r.id]);
                    }
                }
            }
        }
    }

    /// The first region's places tiles still to fetch of the build being filled, skipping tiles another fetch has.
    pub(crate) fn p_batch(&self, st: &State, r: &Region) -> Option<Batch> {
        let p = self.places.as_ref()?;
        if !r.has(PLACES) || r.places_error.is_some() {
            return None;
        }
        let target = st.p.updating.clone().or_else(|| st.p.build.clone())?;
        let list = r.places.get(&target)?;
        let missing: Vec<TileRef> = list.values().filter(|t| !st.p_has(&target, &t.path) && !p.fetching(&target, &t.path)).cloned().collect();
        (!missing.is_empty()).then(|| Batch { build: target, name: r.name.clone(), tiles: missing })
    }

    /// The places update is complete (every region's tiles of the new build are merged in): the device moves to it.
    pub(crate) fn p_ready_to_switch(&self, st: &State) -> Option<String> {
        let u = st.p.updating.clone()?;
        let empty = HashSet::new();
        let present = st.p.present.get(&u).unwrap_or(&empty);
        let complete = st.regions.iter().filter(|r| r.has(PLACES)).all(|r| r.places.get(&u).map(|l| l.keys().all(|k| present.contains(k))).unwrap_or(false));
        complete.then_some(u)
    }

    pub(crate) fn p_run_batch(&self, b: Batch) {
        let Ok(p) = self.places() else { return };
        let queue = Mutex::new(b.tiles.into_iter());
        let later: Mutex<Option<String>> = Mutex::new(None);
        std::thread::scope(|sc| {
            for _ in 0..POOL {
                sc.spawn(|| loop {
                    if !self.may_use_network() || lock(&later).is_some() {
                        break;
                    }
                    let Some(t) = lock(&queue).next() else { break };
                    {
                        let st = self.st();
                        if !st.p_wants(&b.build, &t.path) || st.p_has(&b.build, &t.path) {
                            continue;
                        }
                    }
                    if !p.claim(&b.build, &t.path) {
                        continue;
                    }
                    let res = self.p_fetch_tile(p, &b.build, &t, None);
                    match res {
                        Ok(()) => self.p_landed(&b.build, &t, false),
                        Err(TileFail::Bad(m)) => self.p_tile_failed(&b.build, &t.path, &m),
                        Err(TileFail::Later(m)) => *lock(&later) = Some(m),
                    }
                    p.release(&b.build, &t.path);
                });
            }
        });
        let later = later.into_inner().unwrap_or(None);
        if let Some(m) = later.filter(|_| self.may_use_network()) {
            self.st().paused = Some(format!("Paused: {m}; trying again shortly"));
            self.sleep(RETRY_LATER);
        }
    }

    // ---- stream ----

    /// Fetches and merges the places tiles within [`PLACES_STREAM_DEG`] of `points` that are not on the phone, waiting at most
    /// `timeout`; the fetches carry on in the background after that. Never an error: whatever goes wrong is `ok: false`.
    pub(crate) fn p_stream(self: &Arc<Self>, points: &[(f64, f64)], timeout: Duration) -> StreamAnswer {
        let Some(p) = self.places.as_ref() else { return StreamAnswer::default() };
        let deadline = Instant::now() + timeout;
        if !self.may_use_network() {
            let build = self.st().p.build.clone();
            let missing = build
                .and_then(|b| Some((self.p_cached_index(p, &b)?, b)))
                .map(|(idx, b)| {
                    let st = self.st();
                    idx.tiles_near_level(points, 1, PLACES_STREAM_DEG).iter().filter(|t| !st.p_has(&b, &t.path)).count()
                })
                .unwrap_or(0);
            return StreamAnswer { missing, ..Default::default() };
        }
        let Ok((build, idx)) = self.p_ensure(timeout) else { return StreamAnswer::default() };
        let need = idx.tiles_near_level(points, 1, PLACES_STREAM_DEG);
        let missing: Vec<TileRef> = {
            let st = self.st();
            need.iter().filter(|t| !st.p_has(&build, &t.path)).cloned().collect()
        };
        let reserve = self.reserve.load(Ordering::Relaxed);
        let need_bytes: u64 = missing.iter().map(|t| t.bytes).sum();
        if free_bytes(&self.dir).map(|f| f < need_bytes.saturating_add(reserve)).unwrap_or(false) {
            return StreamAnswer { missing: missing.len(), ..Default::default() };
        }
        // What nobody is fetching is fetched in the background; a tile another fetch has is waited for.
        let mine: Vec<TileRef> = missing.iter().filter(|t| p.claim(&build, &t.path)).cloned().collect();
        if !mine.is_empty() {
            let (me, b) = (self.clone(), build.clone());
            let names: Vec<String> = mine.iter().map(|t| t.path.clone()).collect();
            let spawned = std::thread::Builder::new().name("cache-places-stream".into()).spawn(move || me.p_fetch_claimed(&b, mine));
            if spawned.is_err() {
                names.iter().for_each(|n| p.release(&build, n));
            }
        }
        {
            let (m, cv) = &p.inflight;
            let mut g = lock(m);
            while missing.iter().any(|t| g.contains(&(build.clone(), t.path.clone()))) {
                let left = deadline.saturating_duration_since(Instant::now());
                if left.is_zero() {
                    break;
                }
                g = cv.wait_timeout(g, left).unwrap_or_else(|e| e.into_inner()).0;
            }
        }
        // Every tile of this search on the phone that belongs to no region is in the stream cache, used now; then the cap.
        {
            let st = self.st();
            let db = self.db();
            let stamp = self.tick() as i64;
            for t in &need {
                if st.p_has(&build, &t.path) && !st.p_wants(&build, &t.path) {
                    let _ = db.execute(
                        "INSERT INTO stream2(component, build, path, bytes, last_used) VALUES ('places', ?1, ?2, ?3, ?4)
                         ON CONFLICT(component, build, path) DO UPDATE SET last_used = excluded.last_used",
                        params![build, t.path, t.bytes as i64, stamp],
                    );
                }
            }
        }
        let keep: HashSet<String> = need.iter().map(|t| t.path.clone()).collect();
        self.p_evict(p, &build, &keep);
        let st = self.st();
        let (mut a, mut pending, mut gone) = (StreamAnswer::default(), 0, 0);
        for t in &missing {
            if st.p_has(&build, &t.path) {
                a.fetched += 1;
            } else if p.fetching(&build, &t.path) {
                pending += 1;
            } else {
                gone += 1;
            }
        }
        a.pending = pending;
        a.missing = gone;
        a.ok = need.iter().all(|t| st.p_has(&build, &t.path));
        a
    }

    /// The background side of a stream: the claimed tiles, a few at a time; each lands as a stream-cache entry.
    fn p_fetch_claimed(&self, build: &str, tiles: Vec<TileRef>) {
        let Ok(p) = self.places() else { return };
        let queue = Mutex::new(tiles.into_iter());
        std::thread::scope(|sc| {
            for _ in 0..POOL {
                sc.spawn(|| {
                    loop {
                        // Taken into a local, so the queue is not held while the tile downloads.
                        let next = lock(&queue).next();
                        let Some(t) = next else { break };
                        if self.p_fetch_tile(p, build, &t, None).is_ok() {
                            self.p_landed(build, &t, true);
                        }
                        p.release(build, &t.path);
                        self.poke();
                    }
                });
            }
        });
    }

    // ---- regions ----

    /// The places part of `plan`: the tiles of the outline in the device's build (or the newest, with none yet).
    pub(crate) fn p_plan(&self, shape: &geo::Shape) -> Result<Value> {
        let p = self.places()?;
        let dev = self.st().p.build.clone();
        let (build, idx, common_gz) = match dev {
            Some(b) => (b.clone(), self.p_index_of(p, &b, REQUEST_TIMEOUT)?, 0),
            None => match self.p_fetch_current(p, REQUEST_TIMEOUT) {
                Ok((c, common)) => (c.build.clone(), self.p_fetch_index(p, &c, REQUEST_TIMEOUT)?, common.gz),
                Err(e) => {
                    let known = self.st().p.current.clone();
                    match known.and_then(|c| Some((self.p_cached_index(p, &c.build)?, c))) {
                        Some((i, c)) => (c.build.clone(), i, c.common_gz_bytes.unwrap_or(0)),
                        None => return Err(e),
                    }
                }
            },
        };
        let tiles = idx.tiles_for_level(shape, 1);
        let st = self.st();
        let (mut bytes, mut download, mut shared) = (0u64, common_gz, 0u64);
        for t in &tiles {
            bytes += t.bytes;
            if st.p_has(&build, &t.path) {
                shared += 1;
            } else {
                download += t.gz;
            }
        }
        Ok(json!({"tiles": tiles.len(), "bytes": bytes, "download_bytes": download, "shared_tiles": shared}))
    }

    /// The places part of `add` (the region is recorded with its parts): its tile lists of the device's build (set up when
    /// there is none) and of an update filling, recorded; tiles only its old outline needed go. The part's answer.
    pub(crate) fn p_add(&self, id: &str) -> Value {
        let res = (|| -> Result<Value> {
            let p = self.places()?;
            let (build, idx) = self.p_ensure(REQUEST_TIMEOUT)?;
            let updating = self.st().p.updating.clone();
            let uidx = match &updating {
                Some(u) => Some((u.clone(), self.p_index_of(p, u, REQUEST_TIMEOUT)?)),
                None => None,
            };
            let mut st = self.st();
            let Some(i) = st.regions.iter().position(|r| r.id == id) else { return Err(Error::new("not_found", format!("no region {id}"))) };
            let shape = geo::Shape::parse(&Value::String(st.regions[i].geometry.clone())).map_err(Error::bad_args)?;
            let mut lists: BTreeMap<String, BTreeMap<String, TileRef>> = BTreeMap::new();
            lists.insert(build.clone(), idx.tiles_for_level(&shape, 1).into_iter().map(|t| (t.path.clone(), t)).collect());
            if let Some((u, ui)) = &uidx {
                lists.insert(u.clone(), ui.tiles_for_level(&shape, 1).into_iter().map(|t| (t.path.clone(), t)).collect());
            }
            {
                let mut db = self.db();
                let tx = db.transaction()?;
                tx.execute("DELETE FROM region_tiles2 WHERE region = ?1 AND component = 'places'", params![id])?;
                tx.execute("UPDATE regions SET places_error = NULL WHERE id = ?1", params![id])?;
                {
                    let mut ins = tx.prepare("INSERT INTO region_tiles2(region, component, build, path, bytes, sha256, gz) VALUES (?1, 'places', ?2, ?3, ?4, ?5, ?6)")?;
                    for (b, l) in &lists {
                        for t in l.values() {
                            ins.execute(params![id, b, t.path, t.bytes as i64, t.sha256, t.gz as i64])?;
                        }
                    }
                }
                tx.commit()?;
            }
            let r = &mut st.regions[i];
            r.places_error = None;
            let old = std::mem::replace(&mut r.places, lists);
            let mine = st.regions[i].places.get(&build).cloned().unwrap_or_default();
            for (b, l) in &old {
                self.p_delete_unused(&mut st, b, l.keys());
            }
            self.p_set_names(&st);
            let (mut bytes, mut download) = (0u64, 0u64);
            for t in mine.values() {
                bytes += t.bytes;
                if !st.p_has(&build, &t.path) {
                    download += t.gz;
                }
            }
            Ok(json!({"tiles": mine.len(), "bytes": bytes, "download_bytes": download}))
        })();
        res.unwrap_or_else(|e| json!({"error": e.message, "code": e.code}))
    }

    /// The places part of a region in `status`.
    pub(crate) fn p_region_status(&self, st: &State, r: &Region) -> Value {
        let target = st.p.build.clone();
        let list = target.as_ref().and_then(|b| r.places.get(b));
        let (mut tiles, mut bytes, mut done, mut done_bytes) = (0u64, 0u64, 0u64, 0u64);
        for t in list.into_iter().flat_map(|l| l.values()) {
            tiles += 1;
            bytes += t.bytes;
            if st.p_has(target.as_deref().unwrap_or_default(), &t.path) {
                done += 1;
                done_bytes += t.bytes;
            }
        }
        let state = if r.places_error.is_some() {
            "failed"
        } else if list.is_some() && done == tiles {
            "ready"
        } else if st.paused.is_some() || !self.may_use_network() {
            "paused"
        } else {
            "downloading"
        };
        json!({"state": state, "tiles": tiles, "bytes": bytes, "done_tiles": done, "done_bytes": done_bytes, "error": r.places_error})
    }

    /// The top-level `places` object of `status`, and the places update.
    pub(crate) fn p_status(&self, st: &State) -> (Value, Value) {
        let Ok(p) = self.places() else { return (Value::Null, Value::Null) };
        let build = st.p.build.clone();
        let (mut s_tiles, mut s_bytes) = (0u64, 0u64);
        if let Some(b) = &build {
            for (path, n) in self.p_stream_rows(b) {
                if !st.p_wants(b, &path) {
                    s_tiles += 1;
                    s_bytes += n;
                }
            }
        }
        let update = st.p.update.as_ref().map(|(b, bytes)| {
            let downloading = st.p.updating.as_deref() == Some(b.as_str());
            let left = if downloading { st.p_left(b) } else { *bytes };
            json!({"build": b, "download_bytes": left, "downloading": downloading})
        });
        let update = update.unwrap_or(Value::Null);
        let places = json!({
            "build": build,
            "db": build.as_ref().map(|b| p.db_file(b).to_string_lossy().into_owned()),
            "tiles": build.as_ref().and_then(|b| st.p.present.get(b)).map(|s| s.len()).unwrap_or(0),
            "generation": p.generation(),
            "stream": {"tiles": s_tiles, "bytes": s_bytes, "cap": p.cap},
            "update": update,
        });
        (places, update)
    }

    // ---- builds ----

    /// The device's places move to `new` (complete): its database is flushed, `CURRENT` names it, and the old build's
    /// database, common file and index go, with the places stream cache.
    pub(crate) fn p_switch(&self, st: &mut State, new: &str) -> Result<()> {
        let p = self.places()?;
        {
            let mut dbs = p.dbs();
            if let Some(c) = dbs.get(new) {
                let _ = c.query_row("PRAGMA wal_checkpoint(TRUNCATE)", [], |_| Ok(()));
                let _ = merged::set_regions(c, &st.p_names());
            }
            write_whole(&p.current_file(), new.as_bytes(), self.seq())?;
            dbs.retain(|b, _| b == new);
        }
        {
            let mut db = self.db();
            let tx = db.transaction()?;
            tx.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('places.build', ?1)", params![new])?;
            tx.execute("DELETE FROM meta WHERE key IN ('places.updating', 'places.update')", [])?;
            tx.execute("DELETE FROM region_tiles2 WHERE component = 'places' AND build <> ?1", params![new])?;
            tx.execute("DELETE FROM stream2 WHERE component = 'places'", [])?;
            tx.commit()?;
        }
        let old = st.p.build.replace(new.to_string());
        st.p.updating = None;
        st.p.update = None;
        for r in &mut st.regions {
            r.places.retain(|b, _| b == new);
        }
        st.p.present.retain(|b, _| b == new);
        st.p.present.entry(new.to_string()).or_default();
        if let Some(old) = old.filter(|o| o != new) {
            lock(&p.indexes).remove(&old);
            let _ = std::fs::remove_file(p.index_file(&old));
            remove_db_files(&p.db_file(&old));
            let _ = std::fs::remove_dir_all(p.dir.join(&old));
        }
        p.bump();
        Ok(())
    }

    /// No region has places: the device keeps no places build (the next search sets up the newest one).
    fn p_reset(&self, st: &mut State) -> Result<()> {
        let p = self.places()?;
        p.dbs().clear();
        let _ = std::fs::remove_file(p.current_file());
        {
            let mut db = self.db();
            let tx = db.transaction()?;
            tx.execute("DELETE FROM meta WHERE key IN ('places.build', 'places.updating', 'places.update')", [])?;
            tx.execute("DELETE FROM region_tiles2 WHERE component = 'places'", [])?;
            tx.execute("DELETE FROM stream2 WHERE component = 'places'", [])?;
            tx.commit()?;
        }
        for b in [st.p.build.take(), st.p.updating.take()].into_iter().flatten() {
            lock(&p.indexes).remove(&b);
            let _ = std::fs::remove_file(p.index_file(&b));
            remove_db_files(&p.db_file(&b));
            let _ = std::fs::remove_dir_all(p.dir.join(&b));
        }
        st.p.update = None;
        st.p.present.clear();
        for r in &mut st.regions {
            r.places.clear();
        }
        p.bump();
        Ok(())
    }

    pub(crate) fn p_check_update(&self) -> Result<Value> {
        let p = self.places()?;
        let (c, common) = self.p_fetch_current(p, REQUEST_TIMEOUT)?;
        let (dev, none) = {
            let st = self.st();
            (st.p.build.clone(), !st.regions.iter().any(|r| r.has(PLACES)))
        };
        if dev.as_deref() == Some(c.build.as_str()) || none {
            let mut st = self.st();
            if none && dev.is_some() && dev.as_deref() != Some(c.build.as_str()) {
                self.p_reset(&mut st)?;
            }
            st.p.update = None;
            st.p.updating = None;
            let db = self.db();
            self.meta_set(&db, "places.update", None)?;
            self.meta_set(&db, "places.updating", None)?;
            return Ok(json!({"build": c.build, "update": null}));
        }
        let idx = self.p_fetch_index(p, &c, REQUEST_TIMEOUT)?;
        let mut st = self.st();
        let mut seen = HashSet::new();
        let mut bytes = if p.common_file(&c.build).is_file() { 0 } else { common.gz };
        for r in st.regions.iter().filter(|r| r.has(PLACES)) {
            let Ok(shape) = geo::Shape::parse(&Value::String(r.geometry.clone())) else { continue };
            for t in idx.tiles_for_level(&shape, 1) {
                if !st.p_has(&c.build, &t.path) && seen.insert(t.path.clone()) {
                    bytes += t.gz;
                }
            }
        }
        if st.p.updating.as_deref().map(|u| u != c.build).unwrap_or(false) {
            // An update to a build that is no longer the newest: it starts over at the newest.
            st.p.updating = None;
        }
        st.p.update = Some((c.build.clone(), bytes));
        let db = self.db();
        self.meta_set(&db, "places.update", Some(&json!([c.build, bytes]).to_string()))?;
        if st.p.updating.is_none() {
            self.meta_set(&db, "places.updating", None)?;
        }
        Ok(json!({"build": c.build, "update": {"build": c.build, "download_bytes": bytes}}))
    }

    /// Starts filling the newer places build: its database is made from its common file, and every region's tiles of it are
    /// fetched into it, while searches go on reading the old one. The switch comes when it is complete.
    pub(crate) fn p_update(&self) -> Result<Value> {
        let p = self.places()?;
        let pending = self.st().p.update.clone();
        let target = match pending {
            Some((b, _)) => b,
            None => match self.p_check_update()?["update"]["build"].as_str() {
                Some(b) => b.to_string(),
                None => return Ok(json!({"ok": true, "build": self.st().p.build, "download_bytes": 0})),
            },
        };
        if self.st().p.build.as_deref() == Some(target.as_str()) {
            return Ok(json!({"ok": true, "build": target, "download_bytes": 0}));
        }
        let idx = self.p_index_of(p, &target, REQUEST_TIMEOUT)?;
        let current = self.st().p.current.clone().filter(|c| c.build == target);
        let common = current.ok_or_else(|| Error::offline(format!("current.json of {target} is not on this device")))?;
        let common = common.check_places(TILE_SCHEMA).map_err(|m| Error::new("bad_response", m))?;
        let common_file = self.p_fetch_common(p, &target, &common, REQUEST_TIMEOUT)?;
        let have = {
            let mut dbs = p.dbs();
            if !dbs.contains_key(&target) {
                let f = p.db_file(&target);
                let c = if f.is_file() { open_writer(&f)? } else { merged::create(&f, &common_file).map_err(perr)? };
                dbs.insert(target.clone(), c);
            }
            merged::tiles(&dbs[&target]).map_err(perr)?
        };
        let mut st = self.st();
        st.p.present.insert(target.clone(), have.into_iter().map(tile_path_l1).collect());
        let mut lists = Vec::new();
        for r in st.regions.iter().filter(|r| r.has(PLACES)) {
            let shape = geo::Shape::parse(&Value::String(r.geometry.clone())).map_err(|m| Error::new("internal", format!("{}: {m}", r.id)))?;
            lists.push((r.id.clone(), idx.tiles_for_level(&shape, 1)));
        }
        {
            let mut db = self.db();
            let tx = db.transaction()?;
            tx.execute("DELETE FROM region_tiles2 WHERE component = 'places' AND build = ?1", params![target])?;
            {
                let mut ins = tx.prepare("INSERT INTO region_tiles2(region, component, build, path, bytes, sha256, gz) VALUES (?1, 'places', ?2, ?3, ?4, ?5, ?6)")?;
                for (id, tiles) in &lists {
                    for t in tiles {
                        ins.execute(params![id, target, t.path, t.bytes as i64, t.sha256, t.gz as i64])?;
                    }
                }
            }
            tx.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('places.updating', ?1)", params![target])?;
            tx.execute("UPDATE regions SET places_error = NULL", [])?;
            tx.commit()?;
        }
        for (id, tiles) in lists {
            if let Some(r) = st.regions.iter_mut().find(|r| r.id == id) {
                r.places.insert(target.clone(), tiles.into_iter().map(|t| (t.path.clone(), t)).collect());
                // A region whose places failed is tried again in the new build.
                r.places_error = None;
            }
        }
        st.p.updating = Some(target.clone());
        let left = st.p_left(&target);
        st.p.update = Some((target.clone(), left));
        drop(st);
        self.poke();
        Ok(json!({"ok": true, "build": target, "download_bytes": left}))
    }
}
