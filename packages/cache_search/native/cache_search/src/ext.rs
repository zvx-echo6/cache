//! Saved places (`cache_user`), live data (`cache_live`) and videos (`cache_video`) on a handle: the glue behind
//! `cs_places_*`, `cs_live_*` and `cs_video_*`. The logic lives in those two crates; this file only holds their state, maps their errors to the
//! core's stable codes, and hands the saved places to the live engine.

use crate::error::{Error, ErrorCode, Result};
use cache_live::{Live, LiveCfg};
use cache_user::UserStore;
use cache_video::{Video, VideoCfg};
use serde::Deserialize;

/// The `user` section of the `cs_open` config: `{"db_path": ".../user.sqlite"}`.
#[derive(Debug, Deserialize)]
pub struct UserCfg {
    pub db_path: String,
}

#[derive(Default)]
pub struct Ext {
    pub user: Option<UserStore>,
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
    pub notebook: Option<cache_notebook::Notebook>,
}

/// The regions engine as the navigate tool's tile stream: its folder is the one to route on, and a route's tiles are fetched
/// before it is routed.
struct RegionStream(std::sync::Arc<cache_regions::Regions>);

impl cache_navigate::TileStream for RegionStream {
    fn prepare(&self, points: &[(f64, f64)]) {
        self.0.prepare(points);
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
            self.ext.user = Some(UserStore::new(&u.db_path));
            self.set_saved_places(Box::new(UserStore::new(&u.db_path)));
            let store = std::sync::Arc::new(cache_user::mapdata::MapStore::new(&u.db_path));
            *self.ext.user_points.write().unwrap_or_else(|e| e.into_inner()) = Some(store.clone());
            self.ext.map_data = Some(store);
        }
        if let Some(l) = live {
            self.ext.live = Some(Live::new(l.clone()));
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

impl Ext {
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
                self.notebook = Some(cache_notebook::Notebook::new(c));
            }
        }
    }

    /// `cs_notebook`: one op of Notebooks (cache_search.h lists them).
    pub fn notebook(&self, op: &str, args_json: Option<&str>) -> Result<String> {
        let nb = self
            .notebook
            .as_ref()
            .ok_or_else(|| Error::new(ErrorCode::NotConfigured, "Notebooks need \"notebook\": {\"db_path\", \"media_dir\"} in the cs_open config"))?;
        nb.call(op, args_json).map_err(|e| Error::new(ErrorCode::from_str_code(e.code), e.message))
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

    pub fn place_save(&self, json: &str) -> Result<String> {
        self.user()?.save(json).map_err(user_err)
    }

    /// Deletes the place and the live data downloaded for it.
    pub fn place_delete(&self, key: &str) -> Result<String> {
        let out = self.user()?.delete(key).map_err(user_err)?;
        if let Some(l) = &self.live {
            l.forget_place(key);
        }
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
    video_refresh => refresh,
    video_me => me,
    video_channels => channels,
    video_list => list,
    video_search => search,
    video_get => get,
    video_delete => delete_download,
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
        let embed: Option<&dyn Fn(&str) -> Option<(String, Vec<f32>)>> = self.embedder.as_deref().map(|f| f as _);
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
            if !["from", "to", "via", "mode", "land_access", "alternatives"].contains(&k.as_str()) {
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
        let req = cache_navigate::map::MapRouteReq { from, via, to, mode, land_access, alternatives };
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
