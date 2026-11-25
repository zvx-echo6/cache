//! Saved places (`cache_user`), live data (`cache_live`) and videos (`cache_video`) on a handle: the glue behind
//! `cs_places_*`, `cs_live_*` and `cs_video_*`. The logic lives in those two crates; this file only holds their state, maps their errors to the
//! core's stable codes, and hands the saved places to the live engine.

use crate::error::{Error, ErrorCode, Result};
use cache_live::{Live, LiveCfg};
use cache_user::UserStore;
use cache_video::{Video, VideoCfg};
use serde::Deserialize;
use std::sync::Arc;

/// Embeds a search query: the model id and the vector, or None when it cannot.
type QueryEmbedder = dyn Fn(&str) -> Option<(String, Vec<f32>)>;

/// The `user` section of the `cs_open` config: `{"db_path": ".../user.sqlite", "read_only"?: bool}`. `read_only` (default
/// false) is for a second handle that only lists the saved places (the app's car handle): user.sqlite is opened read-only,
/// saving and deleting places answer `unsupported`, and the user's map layers and lists are left out.
#[derive(Debug, Deserialize)]
pub struct UserCfg {
    pub db_path: String,
    #[serde(default)]
    pub read_only: bool,
}

#[derive(Default)]
pub struct Ext {
    pub user: Option<UserStore>,
    /// The user.sqlite of [`Ext::user`], for a live fetch on a thread of its own (`cs_live_fetch_start`).
    pub user_db: Option<String>,
    /// The user's map layers and imported repeater lists, in the same user.sqlite (`cs_userlayer*`).
    pub map_data: Option<std::sync::Arc<cache_user::mapdata::MapStore>>,
    /// The same store as the tools see it: `nearby` (repeater and layer categories), `navigate` and `locate` (layer points).
    pub user_points: cache_tool::user::UserPointsSlot,
    pub live: Option<Live>,
    /// Where a places pack plugs into the navigate tool (see `Handle::set_place_source`).
    pub places: cache_navigate::PlaceSlot,
    pub video: Option<Video>,
    pub layers: Option<cache_layers::Layers>,
    /// The places packs behind the map's search box (`cs_map_search`), from the `places` section.
    pub map_places: Option<std::sync::Arc<cache_places::PlacesCore>>,
    /// The routing engine the `navigate` tool and the map's route call share, from the `routing` section.
    pub nav: Option<std::sync::Arc<cache_navigate::NavCore>>,
    /// The routes `cs_map_route` made, which `cs_map_progress` follows.
    pub routes: cache_navigate::map::RouteStore,
    /// The regions engine from the `regions` section: the same one `cs_regions_open` gives for that folder.
    pub regions: Option<std::sync::Arc<cache_regions::Regions>>,
    /// Notebooks from the `notebook` section (`cs_notebook`).
    pub notebook: Option<Arc<cache_notebook::Notebook>>,
    /// The saved places and the Places notebooks were brought in step since the notebook was configured (nbplaces.rs).
    pub places_synced: std::sync::atomic::AtomicBool,
    /// The repeater lists of the older store were turned into notebooks since the notebook was configured (nbrepeaters.rs).
    pub repeaters_migrated: std::sync::atomic::AtomicBool,
    /// Test hook for the conversion of repeater lists: 0 runs it whole; 1, 2, 3 make it stop (as an error) before the notebook is
    /// written, after it is written and before it is read back, and after the read-back before the old list is deleted.
    pub migrate_stop: std::sync::atomic::AtomicU8,
}

/// The regions engine as the navigate tool's tile stream: its folder is the one to route on, and a route's tiles are fetched
/// before it is routed.
struct RegionStream(std::sync::Arc<cache_regions::Regions>);

impl cache_navigate::TileStream for RegionStream {
    fn prepare(&self, points: &[(f64, f64)]) -> cache_navigate::TilePrep {
        use cache_regions::PrepareOutcome as O;
        let p = self.0.prepare(points);
        let state = match p.outcome {
            O::Done => cache_navigate::FetchState::Done,
            O::Offline => cache_navigate::FetchState::Offline,
            O::Failed => cache_navigate::FetchState::Failed,
            O::TimedOut => cache_navigate::FetchState::TimedOut,
        };
        cache_navigate::TilePrep { state, missing: p.missing, index_known: p.index_known, lacking: p.lacking }
    }
    fn tile_dir(&self) -> Option<std::path::PathBuf> {
        self.0.tile_dir()
    }
    fn routable(&self) -> bool {
        self.0.routable()
    }
    fn region_name(&self) -> Option<String> {
        self.0.region_names()
    }
}

/// The regions engine as the places core's feed: before a search it fetches and merges the places tiles around the
/// centre, and its generation counts the changes to the places on the phone.
struct RegionsPlacesFeed(std::sync::Arc<cache_regions::Regions>);

impl cache_places::PlacesFeed for RegionsPlacesFeed {
    fn prepare(&self, lat: f64, lon: f64, wait: std::time::Duration) -> cache_places::PrepareAnswer {
        let a = self.0.prepare_places(lat, lon, wait);
        let n = |x: usize| u32::try_from(x).unwrap_or(u32::MAX);
        cache_places::PrepareAnswer { fetched: n(a.fetched), pending: n(a.pending), missing: n(a.missing), ok: a.ok }
    }
    fn generation(&self) -> u64 {
        self.0.places_generation()
    }
}

pub fn regions_err(e: cache_regions::Error) -> Error {
    Error::new(ErrorCode::from_str_code(e.code), e.message)
}

fn user_err(e: cache_user::Error) -> Error {
    Error::new(ErrorCode::from_str_code(e.code), e.message)
}

fn layers_err(e: cache_layers::Error) -> Error {
    let mut r = Error::new(ErrorCode::from_str_code(e.code), e.message);
    r.space = e.space;
    r
}

fn live_err(e: cache_live::Error) -> Error {
    Error::new(ErrorCode::from_str_code(e.code), e.message)
}

pub fn video_err(e: cache_video::Error) -> Error {
    match e.space {
        Some((needed, available)) => Error::no_space(e.message, needed, available),
        None => Error::new(ErrorCode::from_str_code(e.code), e.message),
    }
}

impl crate::handle::Handle {
    /// Apply the `user`, `live`, `places`, `routing` and `video` config sections; a section that is absent keeps what was set before.
    /// `user`: the handle's saved places (what tools resolve names against) become cache_user's `UserStore` on that file.
    /// `live`: the `live_data` tool (cache_live) is registered; it leaves itself out of `cs_tool_schemas` while no source
    /// definition is installed in `sources_dir`.
    /// `places`: `{"packs": [...]}` registers `nearby` (cache_places; left out of `cs_tool_schemas` while no pack is installed)
    /// and `locate` (always available: a GPS fix needs no pack), and plugs the same packs into the navigate tool as its
    /// `PlaceSource` (names for `to`, `from` and `near`, and the `to_type` categories).
    /// `routing`: the navigate tool (cache_navigate). `video`: the PeerTube connector and downloader (cache_video).
    pub(crate) fn configure_ext(
        &mut self,
        user: Option<UserCfg>,
        live: Option<LiveCfg>,
        routing: Option<cache_navigate::NavigateCfg>,
        video: Option<VideoCfg>,
        places: Option<cache_places::PlacesCfg>,
    ) {
        if let Some(u) = user {
            if u.read_only {
                // no live data and no map layers on such a handle, so nothing else opens the file
                self.ext.user = Some(UserStore::read_only(&u.db_path));
                self.set_saved_places(Box::new(UserStore::read_only(&u.db_path)));
            } else {
                self.ext.user = Some(UserStore::new(&u.db_path));
                self.ext.user_db = Some(u.db_path.clone());
                self.set_saved_places(Box::new(UserStore::new(&u.db_path)));
                let store = std::sync::Arc::new(cache_user::mapdata::MapStore::new(&u.db_path));
                *self.ext.user_points.write().unwrap_or_else(|e| e.into_inner()) = Some(store.clone());
                self.ext.map_data = Some(store);
                self.ext.plug_repeater_points();
            }
        }
        if let Some(l) = live {
            // the handle's own engine reads the keys the host pushed (cs_live_set_key) for a fetch whose request has none
            self.ext.live = Some(Live::with_keys(l.clone(), self.fetcher.clone()));
            self.register_tool(Box::new(cache_live::LiveDataTool::new(l)));
        }
        if let Some(p) = places {
            let (core, tools, source) = cache_places::core_tools_and_source_with(&p, self.ext.user_points.clone());
            for t in tools {
                self.register_tool(t);
            }
            self.set_place_source(Some(source));
            self.ext.map_places = Some(core);
        }
        if let Some(r) = routing {
            let tool = cache_navigate::NavigateTool::new(r, self.ext.places.clone()).with_user(self.ext.user_points.clone());
            self.ext.nav = Some(tool.core());
            self.register_tool(Box::new(tool));
        }
        if let Some(v) = video {
            self.ext.video = Some(Video::new(&v));
        }
    }
}

impl crate::handle::Handle {
    /// Plug the places pack into the navigate tool: it then looks up `to`, `from` and `near` names and finds the
    /// nearest place of a `to_type`. Without one the tool resolves only saved places and "lat,lon" text.
    pub fn set_place_source(&mut self, source: Option<std::sync::Arc<dyn cache_tool::places::PlaceSource>>) {
        *self.ext.places.write().unwrap_or_else(|e| e.into_inner()) = source;
    }
}

/// The map layer engine's elevation layer (the starter `elevation`: Mapterhorn's tiles) as the off-road router's z12 elevation.
pub const ELEVATION_LAYER: &str = "elevation";

/// How long the router stops asking the network for elevation tiles after one failed or timed out.
const ELEVATION_NET_PAUSE: std::time::Duration = std::time::Duration::from_secs(30);

/// z12 elevation tiles from the layer engine: stored data first (downloaded areas, then the tiles viewed before); a tile
/// that is not stored is streamed when the phone is online, and kept in the viewed-tile cache (the same path the map
/// uses, `Inner::tile_upstream`). A tile that cannot be had (offline, no elevation layer, a failed or timed-out fetch) is
/// `ElevError::Unavailable`, never "no tile here": the router then reports the off-road data as not downloaded instead of
/// treating the hole as impassable ground and detouring. `None` is only the source's own "no tile here" (ocean).
/// The network is bounded two ways: each fetch has the map's upstream timeout, and after one fetch fails or times out no
/// more are tried for `ELEVATION_NET_PAUSE`, so a dead connection costs one wait, not one per tile.
struct LayerElevationTiles {
    inner: std::sync::Arc<cache_layers::core::Inner>,
    /// No network fetch before this moment (set by a failed or timed-out fetch).
    paused_until: std::sync::Mutex<Option<std::time::Instant>>,
}

impl LayerElevationTiles {
    fn new(inner: std::sync::Arc<cache_layers::core::Inner>) -> Self {
        Self { inner, paused_until: std::sync::Mutex::new(None) }
    }

    fn net_paused(&self) -> bool {
        self.paused_until.lock().unwrap_or_else(|e| e.into_inner()).is_some_and(|t| std::time::Instant::now() < t)
    }

    fn pause_net(&self) {
        *self.paused_until.lock().unwrap_or_else(|e| e.into_inner()) = Some(std::time::Instant::now() + ELEVATION_NET_PAUSE);
    }
}

impl cache_navigate::ElevationTiles for LayerElevationTiles {
    fn z12(&self, x: u64, y: u64) -> std::result::Result<Option<Vec<u8>>, cache_navigate::ElevError> {
        use cache_navigate::ElevError;
        let (x, y) = (x as u32, y as u32);
        match self.inner.tile_local(ELEVATION_LAYER, 12, x, y) {
            Ok(Some(cache_layers::core::TileOut::Tile { bytes, .. })) => return Ok(Some(bytes)),
            // stored as "the source has no tile here"
            Ok(Some(cache_layers::core::TileOut::Empty)) => return Ok(None),
            // offline and not stored
            Ok(Some(_)) => return Err(ElevError::Unavailable),
            // no elevation layer installed
            Err(e) if e.code == "not_found" => return Err(ElevError::Unavailable),
            Err(e) => return Err(ElevError::Msg(e.message)),
            // not stored: stream it below, when online
            Ok(None) => {}
        }
        if !self.inner.is_online() || self.net_paused() {
            return Err(ElevError::Unavailable);
        }
        match self.inner.tile_upstream(ELEVATION_LAYER, 12, x, y) {
            Ok(cache_layers::core::TileOut::Tile { bytes, .. }) => Ok(Some(bytes)),
            Ok(cache_layers::core::TileOut::Empty) => Ok(None),
            Ok(cache_layers::core::TileOut::Busy) => {
                self.pause_net();
                Err(ElevError::Unavailable)
            }
            Ok(_) => Err(ElevError::Unavailable),
            Err(e) if e.code == "not_found" => Err(ElevError::Unavailable),
            Err(e) if e.code == "fetch_failed" || e.code == "upstream_timeout" => {
                self.pause_net();
                Err(ElevError::Unavailable)
            }
            Err(e) => Err(ElevError::Msg(e.message)),
        }
    }
}

impl Ext {
    /// The navigate tool's region packs read elevation from the map's elevation layer, when both are configured.
    pub fn plug_elevation(&self) {
        if let (Some(nav), Some(l)) = (&self.nav, &self.layers) {
            let source = cache_navigate::TileElevation::new(LayerElevationTiles::new(l.inner.clone()));
            nav.set_elevation(Some(std::sync::Arc::new(source)));
        }
    }

    /// Apply the `regions` section; absent keeps what was set before. The engine is the process's one for that folder
    /// (`cache_regions::Regions::open_shared`), so the app's `cs_regions_open` on the same folder shares it.
    pub fn configure_regions(&mut self, regions: Option<cache_regions::Config>) -> Result<()> {
        if let Some(cfg) = regions {
            self.regions = Some(cache_regions::Regions::open_shared(cfg).map_err(regions_err)?);
        }
        Ok(())
    }

    /// The navigate tool's tile stream is the regions engine, when both are configured. So is the places core's feed (map
    /// search, `nearby` and the navigate tool's `to_type` fetch the places tiles around them first), and the places core
    /// reads the regions engine's merged database when the `places` section names no `merged_dir`.
    pub fn plug_regions(&self) {
        if let (Some(nav), Some(r)) = (&self.nav, &self.regions) {
            let stream: std::sync::Arc<dyn cache_navigate::TileStream> = std::sync::Arc::new(RegionStream(r.clone()));
            nav.set_stream(Some(stream));
        }
        if let (Some(core), Some(r)) = (&self.map_places, &self.regions) {
            if let Some(dir) = r.places_dir() {
                core.packs.default_merged_dir(dir);
                core.plug_feed(std::sync::Arc::new(RegionsPlacesFeed(r.clone())));
            }
        }
    }

    /// `cs_places_refresh`: `{"packs"?: [...]}` replaces the single-region packs when given; the next search checks the
    /// merged database and every pack again. Answers `{"ok": true, "packs": n, "merged": bool}`.
    pub fn places_refresh(&self, args_json: Option<&str>) -> Result<String> {
        let core = self.map_places.as_ref().ok_or_else(|| Error::new(ErrorCode::NotConfigured, "places need \"places\": {\"packs\": [...]} in the cs_open config"))?;
        let v: serde_json::Value = match args_json.map(str::trim).filter(|a| !a.is_empty()) {
            Some(a) => parse_json(a, "args")?,
            None => serde_json::json!({}),
        };
        let o = v.as_object().ok_or_else(|| Error::bad_json("args must be a JSON object"))?;
        for k in o.keys() {
            if k != "packs" {
                return Err(Error::bad_json(format!("{k}: not allowed")));
            }
        }
        match o.get("packs") {
            None | Some(serde_json::Value::Null) => core.packs.recheck(),
            Some(serde_json::Value::Array(a)) => {
                let paths = a.iter().map(|p| p.as_str().map(std::path::PathBuf::from)).collect::<Option<Vec<_>>>();
                core.packs.set_legacy(paths.ok_or_else(|| Error::bad_json("packs must be an array of paths"))?);
            }
            Some(_) => return Err(Error::bad_json("packs must be an array of paths")),
        }
        let open = core.packs.current();
        let merged = open.iter().any(|p| p.is_merged());
        Ok(serde_json::json!({"ok": true, "packs": open.iter().filter(|p| !p.is_merged()).count(), "merged": merged}).to_string())
    }

    /// Apply the `layers` config section; absent keeps what was set before. The same config keeps the running engine
    /// (and its tile server's port); only "online" can change live.
    pub fn configure_layers(&mut self, layers: Option<cache_layers::LayersCfg>) -> Result<()> {
        if let Some(cfg) = layers {
            let same = self.layers.as_ref().map(|l| l.inner.cfg == cache_layers::LayersCfg { online: l.inner.cfg.online, ..cfg.clone() }).unwrap_or(false);
            if same {
                if let Some(l) = &self.layers {
                    l.inner.set_online(cfg.online);
                }
            } else {
                self.layers = Some(cache_layers::Layers::new(cfg).map_err(layers_err)?);
            }
        }
        Ok(())
    }

    /// Apply the `notebook` section; absent keeps what was set before, and the same paths keep the open database.
    pub fn configure_notebook(&mut self, cfg: Option<cache_notebook::NotebookCfg>) {
        if let Some(c) = cfg {
            if self.notebook.as_ref().map(|n| n.cfg() != &c).unwrap_or(true) {
                self.notebook = Some(Arc::new(cache_notebook::Notebook::new(c)));
                self.places_synced.store(false, std::sync::atomic::Ordering::SeqCst);
                self.repeaters_migrated.store(false, std::sync::atomic::Ordering::SeqCst);
            }
        }
        self.plug_repeater_points();
    }

    /// Turns the repeater lists of the older store into notebooks, once per opened notebook. A list that cannot be converted
    /// stays as it is (and is logged).
    pub(crate) fn migrate_repeaters_once(&self) {
        if self.notebook.is_none() || self.repeaters_migrated.swap(true, std::sync::atomic::Ordering::SeqCst) {
            return;
        }
        if let Err(e) = self.migrate_repeater_lists() {
            eprintln!("cache_search: a repeater list was not turned into a notebook: {}", e.message);
        }
    }

    fn layers(&self) -> Result<&cache_layers::Layers> {
        self.layers.as_ref().ok_or_else(|| Error::new(ErrorCode::NotConfigured, "map layers need \"layers\": {\"dir\", \"defs_dirs\"} in the cs_open config"))
    }

    fn user(&self) -> Result<&UserStore> {
        self.user.as_ref().ok_or_else(|| Error::new(ErrorCode::NotConfigured, "saved places need \"user\": {\"db_path\"} in the cs_open config"))
    }

    fn map_data(&self) -> Result<&cache_user::mapdata::MapStore> {
        self.map_data.as_deref().ok_or_else(|| Error::new(ErrorCode::NotConfigured, "map layers and repeater lists need \"user\": {\"db_path\"} in the cs_open config"))
    }

    pub fn userlayers_import(&self, json: &str) -> Result<String> {
        self.map_data()?.import(json).map_err(user_err)
    }

    pub fn userlayers_list(&self) -> Result<String> {
        self.migrate_repeaters_once();
        self.map_data()?.list_json().map_err(user_err)
    }

    pub fn userlayer_get(&self, id: &str) -> Result<String> {
        self.map_data()?.get(id).map_err(user_err)
    }

    pub fn userlayer_set_visible(&self, json: &str) -> Result<String> {
        self.map_data()?.set_visible(json).map_err(user_err)
    }

    pub fn userlayer_delete(&self, id: &str) -> Result<String> {
        self.map_data()?.delete(id).map_err(user_err)
    }

    pub fn userlayer_export(&self, json: &str) -> Result<String> {
        self.map_data()?.export(json).map_err(user_err)
    }

    fn live(&self) -> Result<&Live> {
        self.live
            .as_ref()
            .ok_or_else(|| Error::new(ErrorCode::NotConfigured, "live data needs \"live\": {\"db_path\",\"sources_dir\"} in the cs_open config"))
    }

    fn video(&self) -> Result<&Video> {
        self.video.as_ref().ok_or_else(|| Error::new(ErrorCode::NotConfigured, "videos need \"video\": {\"dir\"} in the cs_open config"))
    }

    fn places(&self) -> &dyn cache_tool::SavedPlaces {
        match &self.user {
            Some(u) => u,
            None => &cache_tool::NoSavedPlaces,
        }
    }

    pub fn places_list(&self) -> Result<String> {
        self.user()?.list_json().map_err(user_err)
    }

    /// Saves the place; its entry in the saved-places notebook follows (nbplaces.rs).
    pub fn place_save(&self, json: &str) -> Result<String> {
        let out = self.user()?.save(json).map_err(user_err)?;
        self.place_saved(&out);
        Ok(out)
    }

    /// Deletes the place, the live data downloaded for it and its entry in the saved-places notebook.
    pub fn place_delete(&self, key: &str) -> Result<String> {
        let out = self.user()?.delete(key).map_err(user_err)?;
        if let Some(l) = &self.live {
            l.forget_place(key);
        }
        self.place_deleted(key);
        Ok(out)
    }

    pub fn live_sources(&self) -> Result<String> {
        Ok(self.live()?.sources_json())
    }

    pub fn live_fetch(&self, req: &str) -> Result<String> {
        // a name no saved place has goes through the installed places pack, which also gives the place's state, county and country
        let source = self.places.read().unwrap_or_else(|e| e.into_inner()).clone();
        self.live()?.fetch_with(req, self.places(), source.as_deref().and_then(|s| s.geocoder())).map_err(live_err)
    }

    /// `cs_live_fetch_start`: `cs_live_fetch` on a thread of its own, as a job whose "result" is what `cs_live_fetch` answers (a
    /// failed fetch makes it `failed` with the same error). The download's network wait never holds the core's worker, so a
    /// search, a read or the Weather screen's stored data are answered meanwhile, and several sources download at once.
    /// `not_configured` (no job) without a "live" section.
    pub fn live_fetch_job(&self, req: &str) -> Result<crate::job::Job> {
        // a copy of the handle's engine, with the same keys
        let live = self.live()?.clone();
        let (user_db, slot, req) = (self.user_db.clone(), self.places.clone(), req.to_string());
        crate::job::Job::spawn_result("cs-live-fetch", move |_cancelled| {
            let user = user_db.as_deref().map(UserStore::new);
            let places: &dyn cache_tool::SavedPlaces = match &user {
                Some(u) => u,
                None => &cache_tool::NoSavedPlaces,
            };
            let source = slot.read().unwrap_or_else(|e| e.into_inner()).clone();
            let out = live.fetch_with(&req, places, source.as_deref().and_then(|s| s.geocoder())).map_err(live_err)?;
            Ok(serde_json::from_str(&out)?)
        })
    }

    pub fn live_get(&self, req: &str) -> Result<String> {
        self.live()?.get(req, self.places()).map_err(live_err)
    }

    // ---- map layers (logic in cache_layers) ----

    pub fn layers_list(&self) -> Result<String> {
        Ok(self.layers()?.inner.list().to_string())
    }

    pub fn layers_refresh(&self) -> Result<String> {
        self.layers()?.inner.refresh().map(|v| v.to_string()).map_err(layers_err)
    }

    /// `cs_layers_refresh_start`: `cs_layers_refresh` on a thread of its own, as a job whose "result" is what `cs_layers_refresh`
    /// answers (a failed refresh makes it `failed` with the same error). The catalogue's network wait (retries, long timeouts) never
    /// holds the caller: saved places, live data and searches are answered meanwhile. The handle's catalogue is updated in place.
    pub fn layers_refresh_job(&self) -> Result<crate::job::Job> {
        let inner = self.layers()?.inner.clone();
        crate::job::Job::spawn_result("cs-layers-refresh", move |_cancelled| inner.refresh().map_err(layers_err))
    }

    pub fn layers_save(&self, def_json: &str) -> Result<String> {
        self.layers()?.inner.save_user_def(def_json).map(|v| v.to_string()).map_err(layers_err)
    }

    pub fn layers_remove(&self, id: &str) -> Result<String> {
        self.layers()?.inner.remove_user_def(id).map(|v| v.to_string()).map_err(layers_err)
    }

    /// Start the tile server if it is not running; "online" in the options sets whether the engine may use the network.
    pub fn layers_server(&self, options_json: Option<&str>) -> Result<String> {
        let l = self.layers()?;
        if let Some(o) = options_json {
            let v: serde_json::Value = serde_json::from_str(o)?;
            if let Some(on) = v["online"].as_bool() {
                l.inner.set_online(on);
            }
        }
        l.serve().map(|v| v.to_string()).map_err(layers_err)
    }

    pub fn layers_plan(&self, req_json: &str) -> Result<String> {
        let req = cache_layers::AreaReq::parse(req_json).map_err(layers_err)?;
        self.layers()?.inner.plan(&req).map(|v| v.to_string()).map_err(layers_err)
    }

    /// Delete one downloaded area, or all of the layer's areas and unfinished downloads.
    pub fn layers_delete(&self, req_json: &str) -> Result<String> {
        let v: serde_json::Value = serde_json::from_str(req_json)?;
        let layer = v["layer"].as_str().ok_or_else(|| Error::bad_json("\"layer\" is required"))?;
        self.layers()?.inner.delete_areas(layer, v["area"].as_str()).map(|v| v.to_string()).map_err(layers_err)
    }

    /// Empty the viewed-tile cache of one layer, or of all layers (NULL / absent).
    pub fn layers_clear_cache(&self, layer: Option<&str>) -> Result<String> {
        let n = self.layers()?.inner.cache.clear(layer).map_err(layers_err)?;
        Ok(serde_json::json!({"cleared": n}).to_string())
    }

    /// One tile through the same path the tile server uses. None is a tile the source does not have.
    pub fn layers_tile(&self, layer: &str, z: u8, x: u32, y: u32) -> Result<Option<(Vec<u8>, &'static str)>> {
        use cache_layers::TileOut;
        match self.layers()?.inner.tile(layer, z, x, y).map_err(layers_err)? {
            TileOut::Tile { bytes, mime, .. } => Ok(Some((bytes, mime))),
            TileOut::Empty => Ok(None),
            TileOut::Miss => Err(Error::not_found("this tile is not on the device and there is no connection")),
            TileOut::Busy => Err(Error::busy("the tile's source is busy; ask again")),
            TileOut::NeedsConnection => Err(Error::new(ErrorCode::Offline, "this layer needs a connection")),
        }
    }
}

/// The `cs_video_*` calls: each takes the request JSON the header documents and returns the answer JSON (cache_video).
macro_rules! video_calls {
    ($($name:ident => $method:ident),* $(,)?) => {
        impl Ext {
            $(pub fn $name(&self, req: &str) -> Result<String> {
                self.video()?.$method(req).map_err(video_err)
            })*
        }
    };
}
video_calls!(
    video_instance_add => instance_add,
    video_instance_remove => instance_remove,
    video_login => login,
    video_auth_methods => auth_methods,
    video_refresh => refresh,
    video_me => me,
    video_channels => channels,
    video_list => list,
    video_search => search,
    video_get => get,
    video_delete => delete_download,
    video_captions_fetch => captions_fetch,
    video_resolve => resolve,
);

impl Ext {
    pub fn video_instances(&self) -> Result<String> {
        self.video()?.instances_json().map_err(video_err)
    }

    pub fn video_downloads(&self) -> Result<String> {
        self.video()?.downloads_json().map_err(video_err)
    }
}

// ---- the map: search, route, progress (cache_places::map, cache_navigate::map) ----

fn tool_err(e: cache_tool::ToolError) -> Error {
    let code = match e.code.as_str() {
        "bad_arguments" => ErrorCode::BadJson,
        "not_set_up" | "not_configured" => ErrorCode::NotConfigured,
        "not_found" => ErrorCode::NotFound,
        _ => ErrorCode::Internal,
    };
    Error::new(code, if e.detail.is_empty() { e.code } else { e.detail })
}

fn map_err(e: cache_places::map::MapError) -> Error {
    Error::new(ErrorCode::from_str_code(e.code), e.message)
}

fn parse_json(text: &str, what: &str) -> Result<serde_json::Value> {
    serde_json::from_str(text).map_err(|e| Error::bad_json(format!("{what}: {e}")))
}

impl crate::handle::Handle {
    /// `cs_map_search`: see cache_places::map. Distances are from `near`, else the last GPS fix. The meaning step embeds the
    /// query with the handle's query embedder, unless the request carries `query_vector`. With a places feed plugged in
    /// (the regions engine), the tiles around the centre are fetched first, waiting up to 3 seconds.
    pub fn map_search(&self, request_json: &str) -> Result<String> {
        let core = self
            .ext
            .map_places
            .as_ref()
            .ok_or_else(|| Error::new(ErrorCode::NotConfigured, "map search needs \"places\": {\"packs\": [...]} in the cs_open config"))?;
        let (query, mut opts) = cache_places::map::parse_request(&parse_json(request_json, "request")?).map_err(map_err)?;
        if opts.near.is_none() {
            opts.near = self.location.as_ref().map(|l| (l.lat, l.lon));
        }
        // The places tiles around the centre first (the feed fetches only when the network may be used); coordinates need
        // no places.
        if let Some((lat, lon)) = opts.near.filter(|&n| cache_places::coord::parse(&query, Some(n)).is_none()) {
            opts.prepared = core.feed.prepare(lat, lon, cache_places::feed::SEARCH_PREPARE_WAIT);
        }
        let embed: Option<&QueryEmbedder> = self.embedder.as_deref().map(|f| f as _);
        let v = core.search(&query, &opts, embed).map_err(map_err)?;
        Ok(v.to_string())
    }

    /// One end of a route: an object `{id?, lat?, lon?, name?}` (an `id` from a search result brings the place's own details),
    /// or text (a result id, coordinates in any format, a saved place, a place name). `None` is the last GPS fix.
    fn map_end(&self, v: Option<&serde_json::Value>, which: &str) -> Result<cache_navigate::map::MapEnd> {
        use cache_navigate::map::MapEnd;
        let near = self.location.as_ref().map(|l| (l.lat, l.lon));
        let places = self.ext.map_places.as_ref();
        let missing = || Error::bad_json(format!("{which}: not found"));
        let from_endpoint = |e: cache_places::map::Endpoint| MapEnd { id: e.id, name: e.name, lat: e.lat, lon: e.lon, osm_category: e.osm_category, arrival: e.arrival };
        match v {
            None | Some(serde_json::Value::Null) => match &self.location {
                Some(l) => Ok(MapEnd { id: None, name: Some("Current location".into()), lat: l.lat, lon: l.lon, osm_category: None, arrival: None }),
                None => Err(Error::bad_json(format!("{which}: not given and no GPS fix is known"))),
            },
            Some(serde_json::Value::String(t)) => {
                if let Some(p) = self.places.resolve(t) {
                    return Ok(MapEnd { id: None, name: Some(p.name), lat: p.lat, lon: p.lon, osm_category: None, arrival: None });
                }
                places.and_then(|c| c.resolve_text(t, near)).map(from_endpoint).ok_or_else(missing)
            }
            Some(serde_json::Value::Object(o)) => {
                let num = |k: &str| o.get(k).and_then(serde_json::Value::as_f64);
                let text = |k: &str| o.get(k).and_then(serde_json::Value::as_str).map(str::to_string);
                // an id's place may be in a tile that is not on the phone yet (a chip or result in another area): fetch the tiles around
                // the end first, as a map search does (it fetches only online, and waits at most as long as a search does)
                if let (Some(c), Some(id), Some(la), Some(lo)) = (places, text("id"), num("lat"), num("lon")) {
                    if !id.starts_with("kind:") && !id.starts_with("loc:") {
                        c.feed.prepare(la, lo, cache_places::feed::SEARCH_PREPARE_WAIT);
                    }
                }
                // a kind: id is the nearest place of that kind to the GPS fix, and the end is that place
                let found = text("id").and_then(|id| places.and_then(|c| c.lookup_near(&id, near)));
                let of_kind = text("id").is_some_and(|i| i.starts_with("kind:"));
                let (lat, lon) = match (num("lat"), num("lon"), &found) {
                    (Some(la), Some(lo), _) => (la, lo),
                    (_, _, Some(f)) => (f.lat, f.lon),
                    _ => return Err(Error::bad_json(format!("{which}: needs lat and lon, or an id that is in the places data"))),
                };
                if lat.abs() > 90.0 || lon.abs() > 180.0 {
                    return Err(Error::bad_json(format!("{which}: lat or lon out of range")));
                }
                let same_spot = found.as_ref().is_some_and(|f| (f.lat - lat).abs() < 1e-4 && (f.lon - lon).abs() < 1e-4);
                let (found_id, found_name) = (found.as_ref().and_then(|f| f.id.clone()), found.as_ref().and_then(|f| f.name.clone()));
                Ok(MapEnd {
                    id: if of_kind { found_id } else { text("id") },
                    name: if of_kind { found_name.or_else(|| text("name")) } else { text("name").or(found_name) },
                    lat,
                    lon,
                    osm_category: text("osm_category").or_else(|| found.as_ref().filter(|_| same_spot).and_then(|f| f.osm_category.clone())),
                    arrival: found.as_ref().filter(|_| same_spot).and_then(|f| f.arrival),
                })
            }
            Some(_) => Err(Error::bad_json(format!("{which}: must be an object or a string"))),
        }
    }

    /// `cs_map_route`: the complete route, see cache_navigate::map. A route that cannot be made is `{"ok": false, "errors": [...]}`.
    pub fn map_route(&self, request_json: &str) -> Result<String> {
        let v = parse_json(request_json, "request")?;
        let o = v.as_object().ok_or_else(|| Error::bad_json("the request must be a JSON object"))?;
        if let Some(id) = o.get("route_id") {
            if o.len() != 1 {
                return Err(Error::bad_json("route_id lookup cannot be combined with routing arguments"));
            }
            let id = id.as_str().filter(|s| !s.trim().is_empty()).ok_or_else(|| Error::bad_json("route_id must be a non-empty string"))?;
            let snapshot = self.ext.nav.as_ref().and_then(|n| n.tool_route(id)).ok_or_else(|| Error::not_found(format!("route {id:?} is no longer available; use a saved route snapshot or plan a new route")))?;
            let active = std::sync::Arc::new(cache_navigate::map::ActiveRoute::from_json(&snapshot).map_err(Error::bad_json)?);
            self.ext.routes.add(std::slice::from_ref(&active));
            return Ok(snapshot.to_string());
        }
        for k in o.keys() {
            if !["from", "to", "via", "mode", "land_access", "alternatives", "avoid_highways", "avoid_tolls"].contains(&k.as_str()) {
                return Err(Error::bad_json(format!("{k}: not allowed")));
            }
        }
        let nav = self.ext.nav.as_ref().filter(|n| n.routing_installed()).ok_or_else(|| Error::new(ErrorCode::NotConfigured, "routing needs an installed map region (\"routing\": {\"valhalla\": ...} in the cs_open config)"))?;
        let (mode, land_access, alternatives) = cache_navigate::map::parse_opts(&v).map_err(tool_err)?;
        let to = self.map_end(Some(o.get("to").ok_or_else(|| Error::bad_json("to: required"))?), "to")?;
        let from = self.map_end(o.get("from"), "from")?;
        let via = match o.get("via") {
            None | Some(serde_json::Value::Null) => vec![],
            Some(serde_json::Value::Array(a)) if a.len() <= 8 => a.iter().enumerate().map(|(i, e)| self.map_end(Some(e), &format!("via[{i}]"))).collect::<Result<Vec<_>>>()?,
            Some(_) => return Err(Error::bad_json("via: must be an array of at most 8 places")),
        };
        let from_heading_deg = o.get("from").and_then(|f| f.get("heading_deg")).and_then(serde_json::Value::as_f64).filter(|h| h.is_finite() && (0.0..=360.0).contains(h));
        let flag = |k: &str| -> Result<bool> {
            match o.get(k) {
                None | Some(serde_json::Value::Null) => Ok(false),
                Some(serde_json::Value::Bool(b)) => Ok(*b),
                Some(_) => Err(Error::bad_json(format!("{k}: must be true or false"))),
            }
        };
        let (avoid_highways, avoid_tolls) = (flag("avoid_highways")?, flag("avoid_tolls")?);
        let req = cache_navigate::map::MapRouteReq { from, via, to, mode, land_access, alternatives, from_heading_deg, avoid_highways, avoid_tolls };
        let (out, active) = cache_navigate::map::route(nav, &req).map_err(tool_err)?;
        self.ext.routes.add(&active);
        Ok(out.to_string())
    }

    /// `cs_map_progress`: where a GPS fix is on a route made by `cs_map_route` (by `route_id`), or on a route object sent
    /// again as `route` (after a restart). See cache_navigate::map::ActiveRoute::progress.
    pub fn map_progress(&self, request_json: &str) -> Result<String> {
        let v = parse_json(request_json, "request")?;
        let req = cache_navigate::map::ProgressReq::from_json(&v).map_err(tool_err)?;
        let route = match (v["route_id"].as_str(), v.get("route").filter(|r| r.is_object())) {
            (Some(id), None) => self.ext.routes.get(id).ok_or_else(|| Error::not_found(format!("no route {id:?}: the app sends the route object again as \"route\" after a restart")))?,
            (_, Some(r)) => {
                let wanted = v["route_id"].as_str().or(r["route_id"].as_str()).unwrap_or("");
                match self.ext.routes.get(wanted) {
                    Some(a) => a,
                    None => {
                        let a = std::sync::Arc::new(cache_navigate::map::ActiveRoute::from_json(r).map_err(Error::bad_json)?);
                        self.ext.routes.add(std::slice::from_ref(&a));
                        a
                    }
                }
            }
            (None, None) => return Err(Error::bad_json("route_id (or a route object) is required")),
        };
        Ok(route.progress(&req).to_string())
    }
}

#[cfg(test)]
mod end_prepare_tests {
    use crate::handle::Handle;
    use cache_places::fixture::{fixture_tiles, write_fixture_common, write_fixture_shard, FIXTURE_BUILD};
    use cache_places::{merged, PlacesFeed, PrepareAnswer};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    const BURLEY: (f64, f64) = (42.5357, -113.7928);

    fn merged_db(dir: &std::path::Path) {
        std::fs::create_dir_all(dir).unwrap();
        let common = dir.join("common-src.sqlite");
        write_fixture_common(&common, FIXTURE_BUILD);
        let mut c = merged::create(&dir.join(format!("{FIXTURE_BUILD}.sqlite")), &common).unwrap();
        for tile in fixture_tiles() {
            let shard = dir.join(format!("{tile}.shard"));
            write_fixture_shard(&shard, tile, FIXTURE_BUILD);
            merged::merge_tile(&mut c, tile, &shard, "0", 0).unwrap();
        }
        merged::set_regions(&c, "Idaho").unwrap();
        drop(c);
        std::fs::write(dir.join("CURRENT"), FIXTURE_BUILD).unwrap();
    }

    /// The regions engine's part: asked for the tiles around a point, it puts the places on the phone.
    struct Installs {
        asked: Mutex<Vec<(f64, f64, Duration)>>,
        dir: std::path::PathBuf,
        core: Mutex<Option<Arc<cache_places::PlacesCore>>>,
    }
    impl PlacesFeed for Installs {
        fn prepare(&self, lat: f64, lon: f64, wait: Duration) -> PrepareAnswer {
            self.asked.lock().unwrap().push((lat, lon, wait));
            merged_db(&self.dir);
            if let Some(c) = self.core.lock().unwrap().as_ref() {
                c.packs.recheck();
            }
            PrepareAnswer { fetched: 1, ok: true, ..Default::default() }
        }
        fn generation(&self) -> u64 {
            0
        }
    }

    fn open(dir: &std::path::Path) -> Handle {
        Handle::open(&serde_json::json!({"sources": [], "places": {"packs": [], "merged_dir": dir}}).to_string()).unwrap()
    }

    #[test]
    fn an_id_end_in_an_area_not_on_the_phone_is_fetched_then_enriched() {
        let root = std::env::temp_dir().join(format!("cs-endprep-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        // a place with an osm category, found in a handle that has the tiles
        let (have, installed) = (root.join("have"), root.join("empty"));
        merged_db(&have);
        let h = open(&have);
        let core = h.ext.map_places.clone().unwrap();
        let hits = core.search("pharmacy", &cache_places::map::SearchOpts { near: Some(BURLEY), meaning: false, ..Default::default() }, None).unwrap();
        let id = hits["results"].as_array().unwrap().iter().filter_map(|r| r["id"].as_str()).find(|id| core.lookup(id).is_some_and(|e| e.osm_category.is_some())).expect("a place with an osm category").to_string();
        let wanted = core.lookup(&id).unwrap();
        // the phone with no places: the end is only its id and point
        let h = open(&installed);
        let core = h.ext.map_places.clone().unwrap();
        assert!(core.lookup(&id).is_none());
        let feed = Arc::new(Installs { asked: Mutex::new(vec![]), dir: installed.clone(), core: Mutex::new(Some(core)) });
        h.ext.map_places.as_ref().unwrap().plug_feed(feed.clone());
        let end = h.map_end(Some(&serde_json::json!({"id": id, "lat": wanted.lat, "lon": wanted.lon})), "to").unwrap();
        assert_eq!(feed.asked.lock().unwrap().as_slice(), [(wanted.lat, wanted.lon, Duration::from_secs(3))], "the tiles around the end are fetched first");
        assert_eq!(end.osm_category, wanted.osm_category, "the end got the place's own details");
        // a kind or coordinate end needs no tile of its own
        h.map_end(Some(&serde_json::json!({"id": "loc:42.5,-113.7", "lat": 42.5, "lon": -113.7})), "to").unwrap();
        assert_eq!(feed.asked.lock().unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(root);
    }
}

#[cfg(test)]
mod elevation_tests {
    use super::*;
    use cache_navigate::ElevationTiles;
    use std::io::{Read, Write};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// A fake elevation host on 127.0.0.1: `status` for every request, the tile's name as the body when 200.
    fn host(status: u16) -> (u16, Arc<AtomicUsize>) {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = l.local_addr().unwrap().port();
        let hits = Arc::new(AtomicUsize::new(0));
        let h = hits.clone();
        std::thread::spawn(move || {
            for s in l.incoming() {
                let Ok(mut s) = s else { continue };
                let mut buf = [0u8; 2048];
                let n = s.read(&mut buf).unwrap_or(0);
                let line = String::from_utf8_lossy(&buf[..n]).lines().next().unwrap_or("").to_string();
                h.fetch_add(1, Ordering::SeqCst);
                let body = if status == 200 { line.split_whitespace().nth(1).unwrap_or("").as_bytes().to_vec() } else { vec![] };
                let _ = write!(s, "HTTP/1.1 {status} X\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", body.len());
                let _ = s.write_all(&body);
            }
        });
        (port, hits)
    }

    fn engine(port: u16, online: bool) -> (Arc<cache_layers::core::Inner>, std::path::PathBuf) {
        let dir = std::env::temp_dir().join(format!("elev-{}-{port}-{online}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let inner = cache_layers::core::Inner::open(cache_layers::core::LayersCfg {
            dir: dir.to_string_lossy().into_owned(),
            defs_dirs: vec![],
            catalogue_urls: vec![],
            cache_max_bytes: 16 * 1024 * 1024,
            online,
        })
        .unwrap();
        let def = serde_json::json!({
            "format": 1, "id": ELEVATION_LAYER, "title": "elevation", "kind": "elevation", "transform": "as_is",
            "source": {"type": "xyz", "url": format!("http://127.0.0.1:{port}/{{z}}/{{x}}/{{y}}"), "minzoom": 0, "maxzoom": 12,
                       "encoding": "terrarium", "tile_format": "webp", "tile_size": 512},
            "attribution": "test", "license": "test", "update": {"version": "1"}
        });
        inner.save_user_def(&def.to_string()).unwrap();
        (Arc::new(inner), dir)
    }

    fn tiles(inner: Arc<cache_layers::core::Inner>) -> LayerElevationTiles {
        LayerElevationTiles::new(inner)
    }

    #[test]
    fn missing_tile_is_streamed_and_kept() {
        let (port, hits) = host(200);
        let (inner, dir) = engine(port, true);
        let t = tiles(inner);
        assert_eq!(t.z12(5, 7).unwrap().as_deref(), Some(&b"/12/5/7"[..]), "streamed from the source");
        assert_eq!(hits.load(Ordering::SeqCst), 1);
        assert_eq!(t.z12(5, 7).unwrap().as_deref(), Some(&b"/12/5/7"[..]), "kept: served again");
        assert_eq!(hits.load(Ordering::SeqCst), 1, "the second call needed no network");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn offline_is_none_with_no_network() {
        let (port, hits) = host(200);
        let (inner, dir) = engine(port, false);
        let t = tiles(inner);
        assert!(matches!(t.z12(5, 7), Err(cache_navigate::ElevError::Unavailable)), "offline: not available, not 'no tile'");
        assert_eq!(hits.load(Ordering::SeqCst), 0, "offline never touches the network");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_tile_it_cannot_have_reads_as_nan_and_is_reported_as_a_gap() {
        use cache_navigate::ElevationSource;
        let (port, _hits) = host(200);
        let (inner, dir) = engine(port, false);
        let source = cache_navigate::TileElevation::new(tiles(inner));
        let (row0, col0) = (5 * 512, 7 * 512);
        let v = source.read_elevation(row0, col0, 4, 4).unwrap();
        assert!(v.iter().all(|x| x.is_nan()));
        assert_eq!(source.unavailable_rects(row0, col0, 4, 4), vec![(5 * 512, 7 * 512, 6 * 512, 8 * 512)]);
        assert!(source.unavailable_rects(row0 + 100 * 512, col0, 4, 4).is_empty(), "a window elsewhere sees no gap");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn a_failing_network_costs_one_try_not_one_per_tile() {
        let (port, hits) = host(500);
        let (inner, dir) = engine(port, true);
        let t = tiles(inner);
        for x in [5, 6, 7] {
            assert!(matches!(t.z12(x, 7), Err(cache_navigate::ElevError::Unavailable)), "tile {x}");
        }
        assert_eq!(hits.load(Ordering::SeqCst), 1, "after one failure the router stops asking for a while");
        let _ = std::fs::remove_dir_all(dir);
    }
}
