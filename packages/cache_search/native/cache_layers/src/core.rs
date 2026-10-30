//! The layer engine: catalogue, tile resolution (downloaded -> viewed cache -> network), TileJSON.

use crate::cog::CogSet;
use crate::contour::{self, Grid};
use crate::def::{LayerDef, Transform};
use crate::error::{io_at, Error, Result};
use crate::http;
use crate::pmtiles::{self, Reader};
use crate::store::Store;
use crate::tilecache::{Cached, TileCache};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashMap, VecDeque};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, RwLock};

/// The `layers` section of the `cs_open` config (and of a download job's parameters).
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct LayersCfg {
    /// Root of everything the layer engine keeps: `user-defs/`, `areas/`, `tiles.sqlite`, `catalogue.json`.
    pub dir: String,
    /// Read-only folders of definition files (the starter definitions shipped with the app).
    #[serde(default)]
    pub defs_dirs: Vec<String>,
    /// Catalogues: each a JSON list of definitions (or `{"layers":[...]}`), fetched by `refresh` and merged with the
    /// starter definitions (a later catalogue wins by id). The default is the Cache catalogue; `[]` turns it off and
    /// users add their own addresses.
    #[serde(default = "default_catalogues")]
    pub catalogue_urls: Vec<String>,
    /// Cap of the viewed-tile cache in bytes (256 MiB if absent).
    #[serde(default = "default_cache")]
    pub cache_max_bytes: u64,
    /// False: never touch the network (tiles come from downloads and the cache only).
    #[serde(default = "yes")]
    pub online: bool,
}

/// The catalogue of layers Cache builds (public lands, trails and roads, MVUM, BLM routes).
pub const DEFAULT_CATALOGUE: &str = "https://cache.echo6.co/catalogue.json";

fn default_catalogues() -> Vec<String> {
    vec![DEFAULT_CATALOGUE.to_string()]
}

fn default_cache() -> u64 {
    256 * 1024 * 1024
}
fn yes() -> bool {
    true
}

pub struct Loaded {
    pub def: LayerDef,
    pub origin: &'static str,
    pub raw: Value,
}

#[derive(Debug, Clone)]
pub struct AreaInfo {
    pub id: String,
    /// "complete" or "partial" (a download that has not finished)
    pub state: String,
    pub meta: Value,
    pub bbox: [f64; 4],
    pub minzoom: u8,
    pub maxzoom: u8,
}

#[derive(Clone)]
pub enum TileOut {
    Tile { bytes: Vec<u8>, mime: &'static str, from: &'static str },
    /// The source has no tile here.
    Empty,
    /// Not downloaded, not viewed before, and no connection.
    Miss,
    /// An online-only layer with no connection.
    NeedsConnection,
}

/// A layer's recent source requests: (time, 0 worked / 1 failed / 2 timed out, the error message).
type Health = VecDeque<(i64, u8, String)>;
/// Decoded elevation tiles for contours, by (layer, z, x, y), newest last.
type DemCache = VecDeque<((String, u8, u32, u32), Arc<Grid>)>;

pub struct Inner {
    pub cfg: LayersCfg,
    pub dir: PathBuf,
    pub cache: TileCache,
    defs: RwLock<Arc<Vec<Arc<Loaded>>>>,
    invalid: Mutex<Vec<Value>>,
    online: AtomicBool,
    pm_remote: Mutex<HashMap<String, Arc<Reader>>>,
    stores: Mutex<HashMap<String, Arc<Store>>>,
    no_store: Mutex<HashMap<String, std::time::Instant>>,
    health: Mutex<HashMap<String, Health>>,
    tj: Mutex<HashMap<String, (i64, Value)>>,
    dem: Mutex<DemCache>,
    cogs: Mutex<HashMap<String, Arc<CogSet>>>,
}

pub fn now_secs() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(p) = path.parent() {
        std::fs::create_dir_all(p).map_err(|e| io_at("creating", p, e))?;
    }
    let tmp = path.with_extension(format!("tmp{}", std::process::id()));
    std::fs::write(&tmp, bytes).map_err(|e| io_at("writing", &tmp, e))?;
    std::fs::rename(&tmp, path).map_err(|e| io_at("renaming to", path, e))
}

/// Tiles in the world of a zoom, longitude/latitude of a tile corner.
pub fn tile_bbox(z: u8, x: u32, y: u32) -> [f64; 4] {
    let n = (1u64 << z) as f64;
    let lon = |x: f64| x / n * 360.0 - 180.0;
    let lat = |y: f64| (std::f64::consts::PI * (1.0 - 2.0 * y / n)).sinh().atan().to_degrees();
    [lon(x as f64), lat(y as f64 + 1.0), lon(x as f64 + 1.0), lat(y as f64)]
}

impl Inner {
    pub fn open(cfg: LayersCfg) -> Result<Inner> {
        let dir = PathBuf::from(&cfg.dir);
        std::fs::create_dir_all(&dir).map_err(|e| io_at("creating", &dir, e))?;
        let cache = TileCache::open(&dir.join("tiles.sqlite"), cfg.cache_max_bytes)?;
        let online = AtomicBool::new(cfg.online);
        let i = Inner {
            cfg,
            dir,
            cache,
            defs: RwLock::new(Arc::new(Vec::new())),
            invalid: Mutex::new(Vec::new()),
            online,
            pm_remote: Default::default(),
            stores: Default::default(),
            no_store: Default::default(),
            health: Default::default(),
            tj: Default::default(),
            dem: Default::default(),
            cogs: Default::default(),
        };
        i.reload();
        Ok(i)
    }

    pub fn is_online(&self) -> bool {
        self.online.load(Ordering::Relaxed)
    }
    pub fn set_online(&self, on: bool) {
        self.online.store(on, Ordering::Relaxed);
        if on {
            http::mark_network_up();
        }
    }

    // ---- catalogue ----

    pub fn user_dir(&self) -> PathBuf {
        self.dir.join("user-defs")
    }

    fn load_file(path: &Path, origin: &'static str, out: &mut Vec<Loaded>, bad: &mut Vec<Value>) {
        let text = match std::fs::read_to_string(path) {
            Ok(t) => t,
            Err(e) => {
                bad.push(json!({"file": path.display().to_string(), "error": e.to_string()}));
                return;
            }
        };
        let v: Value = match serde_json::from_str(&text) {
            Ok(v) => v,
            Err(e) => {
                bad.push(json!({"file": path.display().to_string(), "error": format!("not JSON: {e}")}));
                return;
            }
        };
        let items: Vec<Value> = match v {
            Value::Array(a) => a,
            Value::Object(ref o) if o.get("layers").map(|l| l.is_array()).unwrap_or(false) => o["layers"].as_array().cloned().unwrap_or_default(),
            other => vec![other],
        };
        for it in items {
            match LayerDef::from_value(&it) {
                Ok(def) => out.push(Loaded { def, origin, raw: it }),
                Err(e) => bad.push(json!({"file": path.display().to_string(), "id": it["id"], "error": e.message})),
            }
        }
    }

    fn json_files(dir: &Path) -> Vec<PathBuf> {
        let mut v: Vec<PathBuf> = std::fs::read_dir(dir)
            .map(|rd| rd.filter_map(|e| e.ok()).map(|e| e.path()).filter(|p| p.extension().map(|x| x == "json").unwrap_or(false)).collect())
            .unwrap_or_default();
        v.sort();
        v
    }

    /// Read every definition again: starter folders, then the downloaded catalogue, then the user's own (later wins).
    pub fn reload(&self) {
        let mut all: Vec<Loaded> = Vec::new();
        let mut bad = Vec::new();
        for d in &self.cfg.defs_dirs {
            for f in Self::json_files(Path::new(d)) {
                Self::load_file(&f, "folder", &mut all, &mut bad);
            }
        }
        let cat = self.dir.join("catalogue.json");
        if cat.is_file() {
            Self::load_file(&cat, "catalogue", &mut all, &mut bad);
        }
        for f in Self::json_files(&self.user_dir()) {
            Self::load_file(&f, "user", &mut all, &mut bad);
        }
        let mut by_id: Vec<Arc<Loaded>> = Vec::new();
        for l in all {
            match by_id.iter().position(|x| x.def.id == l.def.id) {
                Some(i) => by_id[i] = Arc::new(l),
                None => by_id.push(Arc::new(l)),
            }
        }
        // derived layers must point at an elevation layer that exists
        let ids: Vec<(String, bool)> = by_id.iter().map(|l| (l.def.id.clone(), l.def.kind == crate::def::Kind::Elevation && l.def.transform == Transform::AsIs)).collect();
        by_id.retain(|l| match &l.def.derived_from {
            Some(p) if !ids.iter().any(|(i, elev)| i == p && *elev) => {
                bad.push(json!({"id": l.def.id, "error": format!("derived_from {p:?} is not an installed elevation layer")}));
                false
            }
            _ => true,
        });
        if let Ok(mut g) = self.defs.write() {
            *g = Arc::new(by_id);
        }
        if let Ok(mut g) = self.invalid.lock() {
            *g = bad;
        }
        if let Ok(mut g) = self.tj.lock() {
            g.clear();
        }
    }

    pub fn all(&self) -> Arc<Vec<Arc<Loaded>>> {
        self.defs.read().map(|g| g.clone()).unwrap_or_default()
    }

    pub fn loaded(&self, id: &str) -> Result<Arc<Loaded>> {
        self.all().iter().find(|l| l.def.id == id).cloned().ok_or_else(|| Error::not_found(format!("no layer {id:?}")))
    }

    pub fn def(&self, id: &str) -> Result<LayerDef> {
        Ok(self.loaded(id)?.def.clone())
    }

    /// The layer whose tiles a derived layer reads and whose downloads it uses (itself for other layers).
    pub fn base_of(&self, id: &str) -> Result<LayerDef> {
        let d = self.def(id)?;
        match &d.derived_from {
            Some(p) => self.def(p),
            None => Ok(d),
        }
    }

    pub fn save_user_def(&self, json: &str) -> Result<Value> {
        let def = LayerDef::parse(json)?;
        let raw: Value = serde_json::from_str(json)?;
        let dir = self.user_dir();
        write_atomic(&dir.join(format!("{}.json", def.id)), serde_json::to_string_pretty(&raw)?.as_bytes())?;
        self.reload();
        Ok(json!({"id": def.id, "saved": true}))
    }

    pub fn remove_user_def(&self, id: &str) -> Result<Value> {
        if !crate::def::valid_id(id) {
            return Err(Error::bad_json("not a layer id"));
        }
        let p = self.user_dir().join(format!("{id}.json"));
        if !p.is_file() {
            return Err(Error::not_found(format!("no user definition {id:?} (definitions from folders and the catalogue cannot be removed)")));
        }
        std::fs::remove_file(&p).map_err(|e| io_at("deleting", &p, e))?;
        self.reload();
        Ok(json!({"id": id, "removed": true}))
    }

    /// Fetch the catalogue list (if configured) and the latest version of installed layers that say where to check.
    pub fn refresh(&self) -> Result<Value> {
        if !self.is_online() {
            return Err(Error::offline("refreshing the catalogue needs a connection"));
        }
        let mut out = json!({"catalogues": [], "updates": {}});
        let mut merged: Vec<Value> = Vec::new();
        let mut failed = 0usize;
        for url in &self.cfg.catalogue_urls {
            let fetched = http::get_ok(url, None).and_then(|body| {
                let v: Value = serde_json::from_slice(&body).map_err(|e| Error::bad_response(format!("the catalogue is not JSON: {e}")))?;
                match v {
                    Value::Array(a) => Ok(a),
                    Value::Object(ref o) if o.get("layers").map(|l| l.is_array()).unwrap_or(false) => Ok(o["layers"].as_array().cloned().unwrap_or_default()),
                    _ => Err(Error::bad_response("the catalogue must be a JSON list of definitions")),
                }
            });
            match fetched {
                Ok(items) => {
                    let (mut good, mut bad) = (0, Vec::new());
                    for it in items {
                        match LayerDef::from_value(&it) {
                            Ok(d) => {
                                good += 1;
                                merged.retain(|m| m["id"] != json!(d.id));
                                merged.push(it);
                            }
                            Err(e) => bad.push(json!({"id": it["id"], "error": e.message})),
                        }
                    }
                    out["catalogues"].as_array_mut().unwrap().push(json!({"url": url, "layers": good, "invalid": bad}));
                }
                Err(e) => {
                    failed += 1;
                    out["catalogues"].as_array_mut().unwrap().push(json!({"url": url, "error": {"code": e.code, "message": e.message}}));
                }
            }
        }
        if !self.cfg.catalogue_urls.is_empty() {
            if failed == self.cfg.catalogue_urls.len() {
                return Err(Error::fetch_failed(format!("no catalogue could be fetched: {}", out["catalogues"])));
            }
            // a catalogue that could not be fetched keeps the layers it gave last time only if every one worked
            if failed == 0 {
                write_atomic(&self.dir.join("catalogue.json"), serde_json::to_string_pretty(&merged)?.as_bytes())?;
                self.reload();
            } else {
                // partial: add what arrived to the stored list
                let old: Vec<Value> = std::fs::read_to_string(self.dir.join("catalogue.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default();
                let mut all = old;
                for m in merged {
                    all.retain(|o| o["id"] != m["id"]);
                    all.push(m);
                }
                write_atomic(&self.dir.join("catalogue.json"), serde_json::to_string_pretty(&all)?.as_bytes())?;
                self.reload();
            }
        }
        let mut latest = self.latest_versions();
        for l in self.all().iter() {
            let Some(u) = &l.def.update else { continue };
            let Some(c) = &u.check_url else { continue };
            match http::get_ok(c, None).and_then(|b| serde_json::from_slice::<Value>(&b).map_err(|e| Error::bad_response(e.to_string()))) {
                Ok(v) => {
                    if let Some(ver) = v["version"].as_str() {
                        latest.insert(l.def.id.clone(), ver.to_string());
                        out["updates"][&l.def.id] = json!(ver);
                    }
                }
                Err(e) => out["updates"][&l.def.id] = json!({"error": e.message}),
            }
        }
        write_atomic(&self.dir.join("latest.json"), serde_json::to_string(&latest)?.as_bytes())?;
        Ok(out)
    }

    fn latest_versions(&self) -> HashMap<String, String> {
        std::fs::read_to_string(self.dir.join("latest.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
    }

    // ---- the local tile store ----

    pub fn store_path(&self, layer: &str) -> PathBuf {
        self.dir.join("store").join(format!("{layer}.sqlite"))
    }

    /// The layer's tile store if anything was ever downloaded for it (nothing is created).
    pub fn store_read(&self, layer: &str) -> Option<Arc<Store>> {
        if let Some(s) = self.stores.lock().ok()?.get(layer) {
            return Some(s.clone());
        }
        if let Some(t) = self.no_store.lock().ok()?.get(layer) {
            if t.elapsed().as_secs_f32() < 2.0 {
                return None;
            }
        }
        let p = self.store_path(layer);
        if !p.is_file() {
            self.no_store.lock().ok()?.insert(layer.to_string(), std::time::Instant::now());
            return None;
        }
        let s = Arc::new(Store::open(&p, false).ok()?);
        self.stores.lock().ok()?.insert(layer.to_string(), s.clone());
        Some(s)
    }

    pub fn store_create(&self, layer: &str) -> Result<Arc<Store>> {
        if let Some(s) = self.store_read(layer) {
            return Ok(s);
        }
        let s = Arc::new(Store::open(&self.store_path(layer), true)?);
        self.stores.lock().map_err(|_| Error::internal("poisoned"))?.insert(layer.to_string(), s.clone());
        self.no_store.lock().map_err(|_| Error::internal("poisoned"))?.remove(layer);
        Ok(s)
    }

    /// The downloaded areas of a layer (finished and unfinished), newest first. Always looks for the store again, so a
    /// download made by a job in another `Inner` shows at once (the tile path is allowed 2 s of delay).
    pub fn areas(&self, layer: &str) -> Arc<Vec<AreaInfo>> {
        if let Ok(mut g) = self.no_store.lock() {
            g.remove(layer);
        }
        let mut v = Vec::new();
        if let Some(st) = self.store_read(layer) {
            for (id, state, meta) in st.areas().unwrap_or_default() {
                let b = &meta["bbox"];
                let bbox = [b[0].as_f64().unwrap_or(-180.0), b[1].as_f64().unwrap_or(-90.0), b[2].as_f64().unwrap_or(180.0), b[3].as_f64().unwrap_or(90.0)];
                v.push(AreaInfo { id, state, bbox, minzoom: meta["minzoom"].as_u64().unwrap_or(0) as u8, maxzoom: meta["maxzoom"].as_u64().unwrap_or(22) as u8, meta });
            }
        }
        Arc::new(v)
    }

    pub fn areas_fresh(&self, layer: &str) -> Arc<Vec<AreaInfo>> {
        self.areas(layer)
    }

    /// A tile from the layer's merged store of downloads (as the source sent it: MVT may be gzipped).
    pub fn downloaded_tile(&self, base: &LayerDef, z: u8, x: u32, y: u32) -> Result<Option<Vec<u8>>> {
        match self.store_read(&base.id) {
            Some(st) => st.get(z, x, y),
            None => Ok(None),
        }
    }

    // ---- sources ----

    fn gate(&self, l: &LayerDef) -> Arc<http::Gate> {
        http::gate_for(&l.id, l.max_parallel())
    }

    /// The upstream TileJSON of a `tilejson` source (cached in memory and on disk, refreshed daily when online).
    pub fn tilejson_doc(&self, l: &LayerDef) -> Option<Value> {
        let s = l.source.as_ref()?;
        if s.kind != "tilejson" {
            return None;
        }
        let now = now_secs();
        if let Some((t, v)) = self.tj.lock().ok()?.get(&l.id) {
            if now - t < 86_400 {
                return Some(v.clone());
            }
        }
        let path = self.dir.join("tilejson").join(format!("{}.json", l.id));
        if self.is_online() && !http::network_seems_down() {
            if let Ok(b) = http::get_ok(&s.url, Some(&self.gate(l))) {
                if let Ok(v) = serde_json::from_slice::<Value>(&b) {
                    let _ = write_atomic(&path, &b);
                    self.tj.lock().ok()?.insert(l.id.clone(), (now, v.clone()));
                    return Some(v);
                }
            }
        }
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&path).ok()?).ok()?;
        self.tj.lock().ok()?.insert(l.id.clone(), (now - 86_400 + 60, v.clone()));
        Some(v)
    }

    fn expand(t: &str, z: u8, x: u32, y: u32) -> String {
        t.replace("{z}", &z.to_string()).replace("{x}", &x.to_string()).replace("{y}", &y.to_string()).replace("{-y}", &((1u32 << z) - 1 - y).to_string())
    }

    fn remote_pm(&self, l: &LayerDef, url: &str) -> Result<Arc<Reader>> {
        if let Some(r) = self.pm_remote.lock().map_err(|_| Error::internal("poisoned"))?.get(url) {
            return Ok(r.clone());
        }
        let r = Arc::new(Reader::open(Box::new(pmtiles::HttpSource { url: url.to_string(), gate: self.gate(l) }))?);
        self.pm_remote.lock().map_err(|_| Error::internal("poisoned"))?.insert(url.to_string(), r.clone());
        Ok(r)
    }

    pub fn remote_pmtiles(&self, l: &LayerDef, url: &str) -> Result<Arc<Reader>> {
        self.remote_pm(l, url)
    }

    fn cog_set(&self, l: &LayerDef) -> Result<Arc<CogSet>> {
        let mut g = self.cogs.lock().map_err(|_| Error::internal("poisoned"))?;
        if let Some(c) = g.get(&l.id) {
            return Ok(c.clone());
        }
        let s = l.source.as_ref().ok_or_else(|| Error::bad_json("no source"))?;
        let c = Arc::new(CogSet::new(&s.url, s.grid_deg.unwrap_or(3.0), self.gate(l)));
        g.insert(l.id.clone(), c.clone());
        Ok(c)
    }

    /// One tile from the layer's source, as stored/sent by the source (MVT possibly gzipped). `None`: no such tile.
    /// Never looks at downloads or the cache.
    pub fn fetch_source(&self, l: &LayerDef, z: u8, x: u32, y: u32) -> Result<Option<Vec<u8>>> {
        let s = l.source.as_ref().ok_or_else(|| Error::bad_json("a derived layer has no source"))?;
        match s.kind.as_str() {
            "xyz" => self.fetch_template(l, &s.url, z, x, y),
            "tilejson" => {
                let doc = self.tilejson_doc(l).ok_or_else(|| Error::fetch_failed(format!("cannot read the TileJSON {}", s.url)))?;
                let t = doc["tiles"][0].as_str().ok_or_else(|| Error::bad_response("the TileJSON has no tiles address"))?;
                self.fetch_template(l, t, z, x, y)
            }
            "pmtiles" => {
                let r = self.remote_pm(l, &s.url)?;
                r.get_raw(z, x, y)?.map(|raw| undo_compression(&raw, r.header.tile_compression)).transpose()
            }
            "cog" => {
                let c = self.cog_set(l)?;
                c.render_tile(z, x, y, s.tile_size.unwrap_or(256))
            }
            other => Err(Error::unsupported(format!("source type {other}"))),
        }
    }

    fn fetch_template(&self, l: &LayerDef, template: &str, z: u8, x: u32, y: u32) -> Result<Option<Vec<u8>>> {
        let url = Self::expand(template, z, x, y);
        let r = http::get(&url, None, Some(&self.gate(l)))?;
        match r.status {
            200 if !r.body.is_empty() => Ok(Some(r.body)),
            200 | 204 | 404 | 403 | 410 => Ok(None),
            c => Err(Error::fetch_failed(format!("HTTP {c} from {url}"))),
        }
    }

    // ---- tiles ----

    /// Resolve a tile: downloaded areas, then the viewed-tile cache, then (online, if allowed) the source.
    pub fn tile(&self, id: &str, z: u8, x: u32, y: u32) -> Result<TileOut> {
        let l = self.def(id)?;
        if z > 24 || (x as u64) >= (1u64 << z) || (y as u64) >= (1u64 << z) {
            return Err(Error::bad_json("tile out of range"));
        }
        match l.transform {
            Transform::Hillshade => {
                let base = l.derived_from.clone().unwrap_or_default();
                self.tile(&base, z, x, y)
            }
            Transform::Contours => self.contour(&l, z, x, y),
            _ => self.plain_tile(&l, z, x, y),
        }
    }

    /// The tile if it can be answered from local storage alone (downloaded areas, the viewed-tile cache, offline, out
    /// of the zoom range, contours made of local elevation tiles); `None` if it needs the source. Never touches the
    /// network and never waits for it, so the tile server answers these at once.
    pub fn tile_local(&self, id: &str, z: u8, x: u32, y: u32) -> Result<Option<TileOut>> {
        match http::with_policy(http::Policy::LocalOnly, || self.tile(id, z, x, y)) {
            Ok(t) => Ok(Some(t)),
            Err(e) if e.code == "needs_upstream" => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// The tile from the source, as the tile server asks for it: one attempt with the upstream timeout. A source that
    /// is too slow or has no free connection is a clean `Miss` (not an error), so the map simply asks again later.
    pub fn tile_upstream(&self, id: &str, z: u8, x: u32, y: u32) -> Result<TileOut> {
        match http::with_policy(http::Policy::Interactive(http::upstream_timeout()), || self.tile(id, z, x, y)) {
            Err(e) if e.code == "upstream_timeout" => Ok(TileOut::Miss),
            r => r,
        }
    }

    /// True when answering this layer's TileJSON may fetch the source's own TileJSON (a `tilejson` source whose copy in
    /// memory is missing or a day old, while online); everything else is made from the definition alone.
    pub fn tilejson_needs_upstream(&self, id: &str) -> bool {
        let Ok(l) = self.base_of(id) else { return false };
        let is_tj = l.source.as_ref().map(|s| s.kind == "tilejson").unwrap_or(false);
        if !is_tj || !self.is_online() || http::network_seems_down() {
            return false;
        }
        let fresh = self.tj.lock().ok().and_then(|g| g.get(&l.id).map(|(t, _)| now_secs() - t < 86_400)).unwrap_or(false);
        !fresh
    }

    /// TileJSON through the same rules as `tile_upstream`.
    pub fn tilejson_upstream(&self, id: &str, base_url: &str) -> Result<Value> {
        http::with_policy(http::Policy::Interactive(http::upstream_timeout()), || self.tilejson(id, base_url))
    }

    fn zoom_range(l: &LayerDef) -> (u8, u8) {
        let s = l.source.as_ref();
        (s.and_then(|s| s.minzoom).unwrap_or(0), s.and_then(|s| s.maxzoom).unwrap_or(22))
    }

    fn plain_tile(&self, l: &LayerDef, z: u8, x: u32, y: u32) -> Result<TileOut> {
        let (lo, hi) = Self::zoom_range(l);
        if z < lo || z > hi {
            return Ok(TileOut::Empty);
        }
        let mime = l.tile_mime();
        let is_mvt = l.source.as_ref().and_then(|s| s.format()) == Some("mvt");
        let ready = |b: Vec<u8>, from| -> Result<TileOut> {
            Ok(TileOut::Tile { bytes: if is_mvt { gunzip_if_gzip(b)? } else { b }, mime, from })
        };
        if let Some(b) = self.downloaded_tile(l, z, x, y)? {
            return ready(b, "downloaded");
        }
        match self.cache.get(&l.id, z, x, y)? {
            Some(Cached::Tile(b)) => return ready(b, "cache"),
            Some(Cached::Empty) => return Ok(TileOut::Empty),
            None => {}
        }
        let offline_out = || if l.transform == Transform::OnlineOnly { TileOut::NeedsConnection } else { TileOut::Miss };
        if !self.is_online() || http::network_seems_down() {
            return Ok(offline_out());
        }
        if http::policy() == http::Policy::LocalOnly {
            return Err(Error::needs_upstream());
        }
        let fetched = self.fetch_source(l, z, x, y);
        self.note_health(&l.id, fetched.as_ref().err());
        match fetched {
            Ok(Some(b)) => {
                let _ = self.cache.put(&l.id, z, x, y, &b);
                ready(b, "network")
            }
            Ok(None) => {
                let _ = self.cache.put(&l.id, z, x, y, &[]);
                Ok(TileOut::Empty)
            }
            Err(e) if e.code == "fetch_failed" && http::network_seems_down() => Ok(offline_out()),
            Err(e) => Err(e),
        }
    }

    fn dem_grid(&self, base: &LayerDef, z: u8, x: u32, y: u32, missed: &std::cell::Cell<bool>) -> Result<Option<Arc<Grid>>> {
        let key = (base.id.clone(), z, x, y);
        if let Some(g) = self.dem.lock().map_err(|_| Error::internal("poisoned"))?.iter().find(|(k, _)| *k == key).map(|(_, g)| g.clone()) {
            return Ok(Some(g));
        }
        match self.plain_tile(base, z, x, y)? {
            TileOut::Tile { bytes, .. } => {
                let g = Arc::new(contour::decode_terrarium(&bytes)?);
                let mut m = self.dem.lock().map_err(|_| Error::internal("poisoned"))?;
                if m.len() >= 24 {
                    m.pop_front();
                }
                m.push_back((key, g.clone()));
                Ok(Some(g))
            }
            TileOut::Empty => Ok(None),
            TileOut::Miss | TileOut::NeedsConnection => {
                missed.set(true);
                Ok(None)
            }
        }
    }

    fn contour(&self, l: &LayerDef, z: u8, x: u32, y: u32) -> Result<TileOut> {
        let mime = "application/x-protobuf";
        if contour::intervals(z).is_none() {
            return Ok(TileOut::Empty);
        }
        match self.cache.get(&l.id, z, x, y)? {
            Some(Cached::Tile(b)) => return Ok(TileOut::Tile { bytes: b, mime, from: "cache" }),
            Some(Cached::Empty) => return Ok(TileOut::Empty),
            None => {}
        }
        let base = self.base_of(&l.id)?;
        let dem_max = base.source.as_ref().and_then(|s| s.maxzoom).unwrap_or(12);
        let missed = std::cell::Cell::new(false);
        let fetch = |zz: u8, xx: u32, yy: u32| -> Result<Option<Arc<Grid>>> { self.dem_grid(&base, zz, xx, yy, &missed) };
        let out = contour::contour_tile(z, x, y, dem_max, &fetch);
        match out? {
            Some(bytes) => {
                if !missed.get() {
                    let _ = self.cache.put(&l.id, z, x, y, &bytes);
                }
                Ok(TileOut::Tile { bytes, mime, from: "generated" })
            }
            None if missed.get() => Ok(TileOut::Miss),
            None => {
                let _ = self.cache.put(&l.id, z, x, y, &[]);
                Ok(TileOut::Empty)
            }
        }
    }

    // ---- TileJSON ----

    pub fn tilejson(&self, id: &str, base_url: &str) -> Result<Value> {
        let l = self.def(id)?;
        let base = self.base_of(id)?;
        let src = base.source.as_ref();
        let (minzoom, maxzoom) = match l.transform {
            Transform::Contours => (3u8, 15u8),
            _ => (src.and_then(|s| s.minzoom).unwrap_or(0), src.and_then(|s| s.maxzoom).unwrap_or(14)),
        };
        let mut tj = json!({
            "tilejson": "3.0.0",
            "id": l.id,
            "name": l.title,
            "description": l.description,
            "scheme": "xyz",
            "tiles": [format!("{base_url}/layers/{}/{{z}}/{{x}}/{{y}}", l.id)],
            "minzoom": minzoom,
            "maxzoom": maxzoom,
            "attribution": l.attribution,
        });
        let b = l.coverage.as_ref().and_then(|c| c.bbox).or_else(|| base.coverage.as_ref().and_then(|c| c.bbox)).unwrap_or([-180.0, -85.0511287, 180.0, 85.0511287]);
        tj["bounds"] = json!(b);
        let size = src.and_then(|s| s.tile_size).unwrap_or(256);
        match (l.kind, l.transform) {
            (_, Transform::Contours) => {
                tj["type"] = json!("vector");
                tj["format"] = json!("pbf");
                tj["vector_layers"] = json!([{"id": "contours", "minzoom": 3, "maxzoom": 15, "fields": {"ele": "Number", "level": "Number"}}]);
            }
            (crate::def::Kind::Elevation, _) => {
                tj["type"] = json!("raster-dem");
                tj["encoding"] = json!("terrarium");
                tj["tileSize"] = json!(size);
                tj["format"] = json!(src.and_then(|s| s.format()).unwrap_or("webp"));
            }
            (crate::def::Kind::Vector, _) => {
                tj["type"] = json!("vector");
                tj["format"] = json!("pbf");
                if let Some(doc) = self.tilejson_doc(&l) {
                    if doc["vector_layers"].is_array() {
                        tj["vector_layers"] = doc["vector_layers"].clone();
                    }
                    if l.attribution.is_empty() {
                        tj["attribution"] = doc["attribution"].clone();
                    }
                }
            }
            _ => {
                tj["type"] = json!("raster");
                tj["tileSize"] = json!(size);
                tj["format"] = json!(src.and_then(|s| s.format()).unwrap_or("png"));
            }
        }
        if l.transform == Transform::RasterWindow {
            tj["format"] = json!("png");
        }
        tj["cache"] = json!({
            "offline_allowed": base.offline_allowed(),
            "downloaded": self.areas(&base.id).iter().any(|a| a.state == "complete"),
            "needs_connection": l.transform == Transform::OnlineOnly,
        });
        if let Some(lay) = &l.layout {
            tj["layout"] = json!(lay);
        }
        if let Some(h) = &l.style_hints {
            tj["style_hints"] = h.clone();
        }
        Ok(tj)
    }

    // ---- source health ----

    /// Remember how a request to the layer's source went (None = it worked).
    pub fn note_health(&self, layer: &str, err: Option<&Error>) {
        let kind = match err {
            None => (0u8, String::new()),
            Some(e) => {
                let m = e.message.to_lowercase();
                (if m.contains("timed out") || m.contains("timeout") { 2u8 } else { 1u8 }, e.message.clone())
            }
        };
        if let Ok(mut g) = self.health.lock() {
            let q = g.entry(layer.to_string()).or_default();
            q.push_back((now_secs(), kind.0, kind.1));
            while q.len() > 60 {
                q.pop_front();
            }
        }
    }

    /// How the layer's source has been answering in the last 10 minutes:
    /// `{"state": "unknown"|"ok"|"degraded"|"unreachable", "recent_requests", "recent_failures", "recent_timeouts",
    ///   "last_success_at", "last_failure": {"at","message"}}`. "unreachable" = the last three requests all failed.
    pub fn health(&self, layer: &str) -> Value {
        let now = now_secs();
        let g = self.health.lock().ok();
        let q: Vec<(i64, u8, String)> = g.and_then(|g| g.get(layer).cloned()).map(|q| q.into_iter().filter(|e| now - e.0 <= 600).collect()).unwrap_or_default();
        let (fails, touts) = (q.iter().filter(|e| e.1 != 0).count(), q.iter().filter(|e| e.1 == 2).count());
        let last3_failed = q.len() >= 3 && q.iter().rev().take(3).all(|e| e.1 != 0);
        let state = if q.is_empty() {
            "unknown"
        } else if last3_failed || (q.len() < 3 && q.iter().all(|e| e.1 != 0)) {
            "unreachable"
        } else if fails > 0 {
            "degraded"
        } else {
            "ok"
        };
        json!({
            "state": state,
            "recent_requests": q.len(),
            "recent_failures": fails,
            "recent_timeouts": touts,
            "last_success_at": q.iter().rev().find(|e| e.1 == 0).map(|e| e.0),
            "last_failure": q.iter().rev().find(|e| e.1 != 0).map(|e| json!({"at": e.0, "message": e.2})),
        })
    }

    // ---- listing ----

    pub fn list(&self) -> Value {
        let latest = self.latest_versions();
        let layers: Vec<Value> = self
            .all()
            .iter()
            .map(|l| {
                let d = &l.def;
                let base = self.base_of(&d.id).unwrap_or_else(|_| d.clone());
                let areas = self.areas(&base.id);
                let done: Vec<&AreaInfo> = areas.iter().filter(|a| a.state == "complete").collect();
                let bytes: u64 = self.store_read(&base.id).map(|s| s.total_bytes()).unwrap_or(0);
                let newest = latest.get(&base.id).map(|s| s.as_str()).unwrap_or_else(|| base.version());
                let update_available = !newest.is_empty() && done.iter().any(|a| a.meta["version"].as_str().unwrap_or("") != newest);
                let partial = self.partials(&base.id);
                json!({
                    "definition": serde_json::to_value(d).unwrap_or(Value::Null),
                    "origin": l.origin,
                    "download_layer": base.id,
                    "downloadable": base.offline_allowed(),
                    "needs_connection": d.transform == Transform::OnlineOnly,
                    "installed": {
                        "downloaded": !done.is_empty(),
                        "bytes": bytes,
                        "areas": done.iter().map(|a| a.meta.clone()).collect::<Vec<_>>(),
                        "partial": partial,
                    },
                    "update_available": update_available,
                    "latest_version": if newest.is_empty() { Value::Null } else { json!(newest) },
                    "viewed_cache_bytes": self.cache.bytes_for(&d.id),
                    "health": self.health(&base.id),
                })
            })
            .collect();
        json!({
            "layers": layers,
            "invalid": self.invalid.lock().map(|g| g.clone()).unwrap_or_default(),
            "online": self.is_online(),
            "viewed_cache": {"bytes": self.cache.bytes(), "max_bytes": self.cfg.cache_max_bytes},
            "catalogue_urls": self.cfg.catalogue_urls,
        })
    }

    /// Unfinished downloads (resumable) of a layer.
    pub fn partials(&self, layer: &str) -> Vec<Value> {
        self.areas(layer).iter().filter(|a| a.state == "partial").map(|a| json!({"area": a.id, "name": a.meta["name"], "tiles_total": a.meta["tiles_requested"], "version": a.meta["version"]})).collect()
    }
}

fn gunzip_if_gzip(b: Vec<u8>) -> Result<Vec<u8>> {
    if pmtiles::is_gzip(&b) {
        pmtiles::decompress(&b, pmtiles::COMP_GZIP)
    } else {
        Ok(b)
    }
}

/// Tile bytes as the PMTiles header stored them -> as sent by a plain source (gzip kept: `plain` handles it later).
fn undo_compression(raw: &[u8], comp: u8) -> Result<Vec<u8>> {
    match comp {
        pmtiles::COMP_GZIP | pmtiles::COMP_NONE | 0 => Ok(raw.to_vec()),
        c => Err(Error::unsupported(format!("tile compression {c} in a PMTiles archive (only none and gzip)"))),
    }
}
