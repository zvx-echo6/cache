//! The `navigate` tool (docs/TOOLS.md, "navigate"): directions in one call over the offline maps on the phone.
//!
//! Road routing is Valhalla (the C shim, tiles from the installed map region: one tiles.tar, or a folder of tiles such as the
//! downloaded regions', see [`TileStream`]); off-road legs are the off-road
//! router (`cache_offroad`, the pack and the elevation file). `schema()` is built from what is installed:
//! nothing without the Valhalla tiles and the shim library; the `to_type` enum from the places pack's categories
//! (TOOLS.md's list while no places pack is installed). The result is AIDA's navigate contract (build.rs). Off-road
//! legs come back inside the route when an end is away from the roads and the off-road pack and elevation exist;
//! without them the road route is returned with an `offroad_unavailable` warning.
//!
//! Names (`to`, `from`, `near`) are resolved by [`resolve`](crate) in this order: "lat,lon" text, the user's saved
//! places, a point of the user's map layers by its exact name (`to` and `from` only; plugged in with `with_user`), then the
//! places pack through `cache_tool::places::PlaceSource` (plugged in with [`PlaceSlot`]).

mod build;
mod config;
pub mod map;
mod resolve;

pub use config::{NavigateCfg, OffroadCfg, ValhallaCfg};
pub use resolve::parse_latlon;

use cache_offroad::directions::{Directions, DEFAULT_OFFROAD_SNAP_M, TravelMode};
use cache_offroad::navigate::{NavigateRequest, Navigator};
use cache_offroad::pack::PackSource;
use cache_offroad::router::{Boundary, RouteOptions};
use cache_offroad::shim::{config_for_tile_dir, config_for_tiles, ShimValhalla};
use cache_offroad::valhalla::Valhalla;
use cache_offroad::{ElevationSource, PmtilesElevation, SqlitePack};
use cache_tool::places::PlaceSource;
use cache_tool::{Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Map, Value};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant, SystemTime};

/// The nearest place of a category as a route end: the place, how it was matched, and the two candidate lists.
type NearestEnd = (resolve::Resolved, &'static str, Vec<Value>, Vec<Value>);

/// Where a places pack plugs into the tool (shared with the handle, so it can be set after the tool is registered).
pub type PlaceSlot = Arc<RwLock<Option<Arc<dyn PlaceSource>>>>;

/// TOOLS.md's `to_type` list, used while no places pack says which categories exist.
pub const DEFAULT_TO_TYPES: [&str; 11] =
    ["emergency_room", "hospital", "urgent_care", "pharmacy", "fuel", "police", "fire_station", "campground", "trailhead", "water", "shelter"];

/// How many of the nearest places of a type are routed to find the closest by travel time.
const NEAREST_CANDIDATES: usize = 5;
/// Two places closer than this are the same place.
const SAME_PLACE_M: f64 = 30.0;

/// Where the road tiles come from when they are a folder that fills as needed (cache_regions: the downloaded regions, and the
/// tiles fetched for routes planned online). Not used while the tiles are a tiles.tar, which holds all of its region.
pub trait TileStream: Send + Sync {
    /// Called with a trip's start, end and via points ([lat, lon]) right before it is routed: fetch what the route is likely
    /// to need. It may take a while (it has its own timeout); whatever happens, the route then uses the tiles there are.
    fn prepare(&self, points: &[(f64, f64)]);
    /// The folder to route on, when the stream decides it (it moves when an update switches builds). None: the configured
    /// `tiles`.
    fn tile_dir(&self) -> Option<PathBuf> {
        None
    }
    /// Whether a route can be tried: tiles are here, or they can be fetched (online). A device that has downloaded nothing
    /// still routes online; offline with nothing here it does not offer routing.
    fn routable(&self) -> bool {
        true
    }
    /// The downloaded regions' names, for the answer's "routing covers" line.
    fn region_name(&self) -> Option<String> {
        None
    }
}

/// The Valhalla config for `tiles`: a folder of tiles (`mjolnir.tile_dir`) or a tiles.tar (`mjolnir.tile_extract`).
pub fn valhalla_config(tiles: &Path) -> String {
    if tiles.is_dir() {
        config_for_tile_dir(tiles)
    } else {
        config_for_tiles(tiles)
    }
}

/// The newest modification time of any file under `dir`.
fn newest_file(dir: &Path) -> Option<SystemTime> {
    let mut newest: Option<SystemTime> = None;
    let mut todo = vec![dir.to_path_buf()];
    while let Some(d) = todo.pop() {
        let Ok(rd) = std::fs::read_dir(&d) else { continue };
        for e in rd.flatten() {
            let Ok(m) = e.metadata() else { continue };
            if m.is_dir() {
                todo.push(e.path());
            } else if let Ok(t) = m.modified() {
                newest = Some(newest.map_or(t, |n| n.max(t)));
            }
        }
    }
    newest
}

/// A folder's newest file is looked for at most this often (a continent's folder is tens of thousands of files).
const AGE_RECHECK: Duration = Duration::from_secs(60);

pub(crate) struct OffroadData {
    pack: SqlitePack,
    elevation: PmtilesElevation,
}

/// The routing engine behind both the `navigate` tool and the map's route call: the Valhalla shim and the off-road pack,
/// opened on first use, and the one place a trip is routed ([`NavCore::navigate`]), so the assistant and the map get the
/// same route from the same code.
pub struct NavCore {
    cfg: NavigateCfg,
    places: PlaceSlot,
    /// The router, and the tiles it was started on (it starts again when they move).
    valhalla: Mutex<Option<(Arc<dyn Valhalla>, String)>>,
    offroad: Mutex<Option<Arc<OffroadData>>>,
    /// Tests inject a Valhalla and skip the file checks.
    injected: bool,
    tool_routes: Mutex<std::collections::VecDeque<Value>>,
    stream: RwLock<Option<Arc<dyn TileStream>>>,
    /// A tile folder's newest file, and when that was looked up.
    folder_age: Mutex<Option<(String, Instant, Option<SystemTime>)>>,
}

pub struct NavigateTool {
    core: Arc<NavCore>,
    user: cache_tool::user::UserPointsSlot,
}

fn err(code: &str, detail: impl Into<String>) -> ToolError {
    ToolError::new(code, detail)
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// No off-road data: the stand-ins are never read (the request is made with off-road set to "never"; an off-road mode
/// is refused because the stand-in pack covers nowhere).
struct NoPack;
struct NoElevation;

impl PackSource for NoPack {
    fn has_layer(&self, _: cache_offroad::pack::Layer) -> bool {
        false
    }
    fn read_u8(&self, _: cache_offroad::pack::Layer, _: i64, _: i64, _: usize, _: usize) -> cache_offroad::pack::PResult<Vec<u8>> {
        Err(cache_offroad::pack::PackError::Msg("no off-road pack".into()))
    }
    fn parking_in_box(&self, _: f64, _: f64, _: f64, _: f64) -> cache_offroad::pack::PResult<Vec<cache_offroad::pack::PointRec>> {
        Ok(vec![])
    }
    fn trailheads_in_box(&self, _: f64, _: f64, _: f64, _: f64) -> cache_offroad::pack::PResult<Vec<cache_offroad::pack::PointRec>> {
        Ok(vec![])
    }
    fn mvum_in_box(&self, _: f64, _: f64, _: f64, _: f64) -> cache_offroad::pack::PResult<Vec<cache_offroad::pack::MvumFeature>> {
        Ok(vec![])
    }
    fn covers(&self, _: f64, _: f64) -> bool {
        false
    }
}
impl ElevationSource for NoElevation {
    fn read_elevation(&self, _: i64, _: i64, _: usize, _: usize) -> Result<Vec<f32>, cache_offroad::elevation::ElevError> {
        Err(cache_offroad::elevation::ElevError::Msg("no elevation file".into()))
    }
}

/// The modes of the tool: AIDA's drive, walk, bike, where off-road legs come back inside the result when an end is away
/// from the road network (drive searches with the vehicle-class modes, walk on foot, bike on a two-wheeler); and the
/// off-road modes, which route the whole trip off-road: offroad_foot on foot, offroad_vehicle with navi's unified Auto
/// search (4x4, ATV, two-wheeler, on foot where no vehicle can go).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum ModeArg {
    Drive,
    Walk,
    Bike,
    OffroadFoot,
    OffroadVehicle,
}

/// The tool's `mode` values, in schema order.
pub const MODES: [&str; 5] = ["drive", "walk", "bike", "offroad_foot", "offroad_vehicle"];

impl ModeArg {
    fn parse(s: &str) -> Option<ModeArg> {
        Some(match s {
            "drive" => ModeArg::Drive,
            "walk" => ModeArg::Walk,
            "bike" => ModeArg::Bike,
            "offroad_foot" => ModeArg::OffroadFoot,
            "offroad_vehicle" => ModeArg::OffroadVehicle,
            _ => return None,
        })
    }
    pub(crate) fn name(self) -> &'static str {
        self.travel().name()
    }
    pub(crate) fn travel(self) -> TravelMode {
        match self {
            ModeArg::Drive => TravelMode::Drive,
            ModeArg::Walk => TravelMode::Walk,
            ModeArg::Bike => TravelMode::Bike,
            ModeArg::OffroadFoot => TravelMode::OffroadFoot,
            ModeArg::OffroadVehicle => TravelMode::OffroadVehicle,
        }
    }
}

impl NavigateTool {
    pub fn new(cfg: NavigateCfg, places: PlaceSlot) -> NavigateTool {
        NavigateTool { core: Arc::new(NavCore::new(cfg, places)), user: Default::default() }
    }

    /// For tests: a Valhalla supplied by the caller; the file checks are skipped.
    pub fn with_valhalla(cfg: NavigateCfg, places: PlaceSlot, valhalla: Arc<dyn Valhalla>) -> NavigateTool {
        NavigateTool { core: Arc::new(NavCore::with_valhalla(cfg, places, valhalla)), user: Default::default() }
    }

    /// The tool over an engine the map shares.
    pub fn from_core(core: Arc<NavCore>) -> NavigateTool {
        NavigateTool { core, user: Default::default() }
    }

    /// The user's map layers: `to` and `from` match a layer point by its exact name before the places search.
    pub fn with_user(mut self, user: cache_tool::user::UserPointsSlot) -> NavigateTool {
        self.user = user;
        self
    }

    pub fn core(&self) -> Arc<NavCore> {
        self.core.clone()
    }

    fn place_source(&self) -> Option<Arc<dyn PlaceSource>> {
        self.core.place_source()
    }

    fn routing_installed(&self) -> bool {
        self.core.routing_installed()
    }

    fn valhalla(&self) -> Result<Arc<dyn Valhalla>, ToolError> {
        self.core.valhalla()
    }

    fn to_types(&self) -> Vec<String> {
        self.place_source().and_then(|p| p.categories()).unwrap_or_else(|| DEFAULT_TO_TYPES.iter().map(|s| s.to_string()).collect())
    }
}

impl NavCore {
    /// Exact tool-created routes, outside model context. No routing or location lookup on retrieval.
    pub fn tool_route(&self, id: &str) -> Option<Value> {
        lock(&self.tool_routes).iter().find(|v| v["route_id"].as_str() == Some(id)).cloned()
    }

    fn retain_tool_route(&self, route: Value) {
        let mut routes = lock(&self.tool_routes);
        routes.retain(|r| r["route_id"] != route["route_id"]);
        routes.push_back(route);
        while routes.len() > 8 { routes.pop_front(); }
    }

    pub fn new(cfg: NavigateCfg, places: PlaceSlot) -> NavCore {
        NavCore {
            cfg,
            places,
            valhalla: Mutex::new(None),
            offroad: Mutex::new(None),
            injected: false,
            tool_routes: Mutex::new(Default::default()),
            stream: RwLock::new(None),
            folder_age: Mutex::new(None),
        }
    }

    /// For tests: a Valhalla supplied by the caller; the file checks are skipped.
    pub fn with_valhalla(cfg: NavigateCfg, places: PlaceSlot, valhalla: Arc<dyn Valhalla>) -> NavCore {
        NavCore {
            cfg,
            places,
            valhalla: Mutex::new(Some((valhalla, String::new()))),
            offroad: Mutex::new(None),
            injected: true,
            tool_routes: Mutex::new(Default::default()),
            stream: RwLock::new(None),
            folder_age: Mutex::new(None),
        }
    }

    /// Plug in (or take out) where a folder of tiles is filled from; see [`TileStream`].
    pub fn set_stream(&self, stream: Option<Arc<dyn TileStream>>) {
        *self.stream.write().unwrap_or_else(|e| e.into_inner()) = stream;
    }

    fn stream(&self) -> Option<Arc<dyn TileStream>> {
        self.stream.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The tiles to route on: a configured tiles.tar that is there; otherwise the stream's folder, or the configured folder.
    pub fn tiles_path(&self) -> Option<String> {
        let v = self.cfg.valhalla.as_ref()?;
        if !v.tiles.is_empty() && Path::new(&v.tiles).is_file() {
            return Some(v.tiles.clone());
        }
        if let Some(d) = self.stream().and_then(|s| s.tile_dir()) {
            return Some(d.to_string_lossy().into_owned());
        }
        (!v.tiles.is_empty()).then(|| v.tiles.clone())
    }

    /// Before a trip is routed: the stream (if any) fetches the tiles near its points. Skipped when the tiles are a tiles.tar.
    /// Nothing that happens here fails the route.
    pub fn prepare_tiles(&self, points: &[(f64, f64)]) {
        let Some(s) = self.stream() else { return };
        if self.tiles_path().map(|t| Path::new(&t).is_file()).unwrap_or(false) {
            return;
        }
        let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| s.prepare(points)));
    }

    pub(crate) fn place_source(&self) -> Option<Arc<dyn PlaceSource>> {
        self.places.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    pub fn routing_installed(&self) -> bool {
        if self.injected {
            return true;
        }
        let Some(v) = &self.cfg.valhalla else { return false };
        if !(cfg!(target_os = "ios") || Path::new(&v.shim).is_file()) {
            return false;
        }
        if !v.tiles.is_empty() && Path::new(&v.tiles).is_file() {
            return true;
        }
        // A folder that fills as needed: routable when it has tiles or can fetch them, folder or not yet.
        if let Some(s) = self.stream() {
            return s.routable();
        }
        self.tiles_path().map(|t| Path::new(&t).is_dir()).unwrap_or(false)
    }

    fn offroad_installed(&self) -> bool {
        match &self.cfg.offroad {
            Some(o) => Path::new(&o.pack).is_file() && Path::new(&o.elevation).is_file(),
            None => false,
        }
    }

    pub(crate) fn valhalla(&self) -> Result<Arc<dyn Valhalla>, ToolError> {
        let mut g = lock(&self.valhalla);
        if self.injected {
            if let Some((v, _)) = &*g {
                return Ok(v.clone());
            }
        }
        let Some(v) = &self.cfg.valhalla else { return Err(err(ToolError::NOT_SET_UP, "no map region is installed")) };
        let tiles = self.tiles_path().ok_or_else(|| err(ToolError::NOT_SET_UP, "no map region is installed"))?;
        // The same tiles: the router already running. Moved (an update switched the regions' build): a new one on the new
        // folder; a route still running on the old one keeps it until it ends.
        if let Some((r, on)) = &*g {
            if *on == tiles {
                return Ok(r.clone());
            }
        }
        let config = valhalla_config(Path::new(&tiles));
        let shim = ShimValhalla::load(Path::new(&v.shim), &config).map_err(|e| err(ToolError::NOT_SET_UP, format!("the road router could not start: {e}")))?;
        let shim: Arc<dyn Valhalla> = Arc::new(shim);
        *g = Some((shim.clone(), tiles));
        Ok(shim)
    }

    /// The off-road pack and elevation, opened on first use; None while either file is missing.
    pub(crate) fn offroad(&self) -> Result<Option<Arc<OffroadData>>, ToolError> {
        let mut g = lock(&self.offroad);
        if let Some(o) = &*g {
            return Ok(Some(o.clone()));
        }
        if !self.offroad_installed() {
            return Ok(None);
        }
        let o = self.cfg.offroad.as_ref().expect("checked above");
        let pack = SqlitePack::open(Path::new(&o.pack)).map_err(|e| err(ToolError::NOT_SET_UP, format!("the off-road pack could not be opened: {e}")))?;
        let elevation =
            PmtilesElevation::open(Path::new(&o.elevation)).map_err(|e| err(ToolError::NOT_SET_UP, format!("the elevation file could not be opened: {e}")))?;
        let d = Arc::new(OffroadData { pack, elevation });
        *g = Some(d.clone());
        Ok(Some(d))
    }

    fn route_options(&self) -> RouteOptions {
        let mut o = RouteOptions::default();
        if let Some(m) = self.cfg.offroad.as_ref().and_then(|o| o.max_cells) {
            o.max_cells = m;
        }
        o
    }

    /// The one place a trip is routed: road routing with off-road legs where an end is away from the roads (when the off-road
    /// data is installed). Returns the directions and whether off-road data was available. A failed route is `Ok` with
    /// `ok == false` and its coded errors.
    pub fn navigate(&self, mut req: NavigateRequest) -> Result<(Directions, bool), ToolError> {
        let have_offroad = self.offroad().ok().flatten();
        if have_offroad.is_none() {
            req.offroad = cache_offroad::directions::OffroadChoice::Never;
        }
        let valhalla = self.valhalla()?;
        let (no_pack, no_elev) = (NoPack, NoElevation);
        let (pack, elev): (&dyn PackSource, &dyn ElevationSource) = match &have_offroad {
            Some(o) => (&o.pack, &o.elevation),
            None => (&no_pack, &no_elev),
        };
        let mut nav = Navigator::new(pack, elev, &*valhalla);
        nav.options = self.route_options();
        let d = nav.navigate(&req).map_err(|e| err(ToolError::BAD_ARGUMENTS, e.to_string()))?;
        Ok((d, have_offroad.is_some()))
    }

    /// Alternative road routes for the same request (empty when the router gives none).
    pub fn alternatives(&self, req: &NavigateRequest, count: usize) -> Result<Vec<Directions>, ToolError> {
        let valhalla = self.valhalla()?;
        let (no_pack, no_elev) = (NoPack, NoElevation);
        let mut nav = Navigator::new(&no_pack, &no_elev, &*valhalla);
        nav.options = self.route_options();
        nav.alternatives(req, count).map_err(|e| err(ToolError::BAD_ARGUMENTS, e.to_string()))
    }

    /// Name and age of the installed map region: of the tiles file, or of a tile folder (the name from `region`, the age
    /// from the newest file in it).
    pub fn region_info(&self, now: &str) -> (String, String) {
        let Some(v) = &self.cfg.valhalla else { return (String::new(), "unknown".into()) };
        let tiles = self.tiles_path().unwrap_or_else(|| v.tiles.clone());
        let folder = Path::new(&tiles).is_dir();
        let name = v
            .region
            .clone()
            .or_else(|| if folder { self.stream().and_then(|s| s.region_name()) } else { None })
            .unwrap_or_else(|| if folder { String::new() } else { config::region_from_path(&tiles) });
        let modified = if folder { self.folder_newest(&tiles) } else { std::fs::metadata(&tiles).and_then(|m| m.modified()).ok() };
        let age = modified
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .and_then(|t| {
                let now = chrono::DateTime::parse_from_rfc3339(now.trim()).ok()?.timestamp();
                Some(build::age_words(now - t.as_secs() as i64))
            })
            .unwrap_or_else(|| "unknown".into());
        (name, age)
    }

    fn folder_newest(&self, dir: &str) -> Option<SystemTime> {
        let mut g = lock(&self.folder_age);
        if let Some((d, at, t)) = &*g {
            if d == dir && at.elapsed() < AGE_RECHECK {
                return *t;
            }
        }
        let t = newest_file(Path::new(dir));
        *g = Some((dir.to_string(), Instant::now(), t));
        t
    }
}

impl Tool for NavigateTool {
    fn name(&self) -> &'static str {
        "navigate"
    }

    /// None unless the routing data (Valhalla tiles and the shim library) is installed.
    fn schema(&self) -> Option<Value> {
        if !self.routing_installed() {
            return None;
        }
        Some(json!({"type": "function", "function": {
            "name": "navigate",
            "description": "Plan a route to a named place (to) or the nearest place of a type (to_type), using the offline maps on this phone. Omit from to start at the phone's current location. Returns matched places with their coordinates, distance, travel time, the direction from the start, traffic (null when there is no traffic data) and warnings for a brief summary. The app provides Open navigation for this exact route; Maps handles the map and turn-by-turn directions. Do not invent turns or navigation links.",
            "strict": true,
            "parameters": {"type": "object", "properties": {
                "from": {"type": "string", "maxLength": 300,
                         "description": "Starting place name, or \"lat,lon\" coordinates the person gave. Omit it when the person means where they are now."},
                "to": {"type": "string", "minLength": 1, "maxLength": 300,
                       "description": "Destination place name, for a named place. For \"nearest X\" give to_type instead."},
                "to_type": {"type": "string", "enum": self.to_types(),
                            "description": "Use this instead of to whenever the person asks for the nearest place of a kind. Finds the nearest one by travel time from the start. For a hospital in an emergency use emergency_room."},
                "mode": {"type": "string", "enum": MODES,
                         "description": "drive, walk and bike follow roads and paths. offroad_foot (on foot) and offroad_vehicle (4x4, ATV or dirt bike, on foot where no vehicle can go) go cross-country the whole way over trails, tracks and open ground, where off-road data is installed."},
                "near": {"type": "string", "minLength": 1, "maxLength": 200,
                         "description": "Town and state the trip is in, e.g. \"Burley, Idaho\". Give it whenever the question names or implies one."},
                "land_access": {"type": "string", "enum": ["strict", "pragmatic", "emergency"],
                                "description": "Off-road legs only: how land the map data marks private or closed is treated. strict avoids it, pragmatic (the default) crosses it only when it saves a lot, emergency ignores it. This follows the map data's access rules and cannot guarantee access on the ground."}},
                "required": ["mode"], "additionalProperties": false}}}))
    }

    fn run(&self, ctx: &ToolCtx, args: &Value) -> Result<ToolOutput, ToolError> {
        let a = Args::parse(args)?;
        if !self.routing_installed() {
            return Err(err(ToolError::NOT_SET_UP, "navigate is not set up: no map region is installed"));
        }
        let valhalla = self.valhalla()?;
        let r = resolve::Resolver { ctx, source: self.place_source(), user: cache_tool::user::current(&self.user) };
        let start_hint = ctx.location.is_some();
        let hint = |e: ToolError| if start_hint { e.with("hint", "The phone's location is known: omit from to start there.") } else { e };

        // where to prefer matches: the phone's position, else the town in `near`, else (below) the matched start
        let mut bias: Option<(f64, f64)> = ctx.location.map(|l| (l.lat, l.lon));
        let mut bias_source: Option<String> = bias.map(|_| "sender_node_position".to_string());
        if bias.is_none() {
            if let Some(p) = a.near.as_deref().and_then(|t| r.near_point(t)) {
                bias = Some((p.lat, p.lon));
                bias_source = Some(format!("near:{}", p.name));
            }
        }

        let from = match a.from.as_deref() {
            Some(t) => {
                let o = r.named(t, "from", a.near.as_deref(), bias, false).map_err(hint)?;
                if bias.is_none() {
                    bias = Some((o.lat, o.lon));
                    bias_source = Some("from_place".into());
                }
                o
            }
            None => match ctx.location {
                Some(l) => resolve::Resolved::here(l.lat, l.lon),
                None => return Err(err("origin_unknown", "no from and no phone location")),
            },
        };

        let mut nearest_search = None;
        let mut others: Vec<Value> = Vec::new();
        let to = match (a.to.as_deref(), a.to_type.as_deref()) {
            (Some(t), None) => {
                let mut to = r.named(t, "to", a.near.as_deref(), bias, true)?;
                for o in std::mem::take(&mut to.others).into_iter().take(2) {
                    others.push(build::candidate(&resolve::Resolved::from_match(o), None));
                }
                to
            }
            (None, Some(cat)) => {
                let (to, ranked_by, warnings, rest) = self.nearest(&*valhalla, &a, cat, &from)?;
                nearest_search = Some(json!({"to_type": cat, "ranked_by": ranked_by, "warnings": warnings}));
                others = rest;
                to
            }
            _ => unreachable!("Args::parse checked"),
        };

        if cache_offroad::grid::haversine_m(from.lat, from.lon, to.lat, to.lon) < SAME_PLACE_M {
            return Err(build::with_ends(hint(err("same_place", "start and destination matched the same spot")), &from, Some(&to), ctx.now));
        }

        let req = NavigateRequest::new(from.waypoint(), to.waypoint(), a.mode.travel(), a.land_access);
        self.core.prepare_tiles(&[(from.lat, from.lon), (to.lat, to.lon)]);
        let (d, have_offroad) = self.core.navigate(req)?;
        if !d.ok {
            return Err(build::route_error(&d, &from, &to, ctx.now));
        }
        if d.distance_km < SAME_PLACE_M / 1000.0 {
            return Err(build::with_ends(hint(err("same_place", "start and destination matched the same spot")), &from, Some(&to), ctx.now));
        }
        let x = build::Extras {
            location_bias: bias_source,
            others,
            nearest_search,
            region: self.core.region_info(ctx.now),
            synth_warnings: !have_offroad,
            snap_m: DEFAULT_OFFROAD_SNAP_M,
            now: ctx.now.into(),
        };
        let end = |r: &resolve::Resolved| map::MapEnd {
            id: None, name: Some(r.name.clone()), lat: r.lat, lon: r.lon, osm_category: r.osm.clone(), arrival: r.arrival,
        };
        self.core.retain_tool_route(map::tool_snapshot(&d, end(&from), end(&to), a.mode.travel(), a.land_access, have_offroad));
        Ok(ToolOutput::Json(build::result(&d, &from, &to, a.mode.name(), x)))
    }
}

impl NavigateTool {
    /// The nearest place of a category by travel time from `from`: the winner, how the ranking was done (`"drive"` when
    /// routing ranked the candidates, whatever the travel mode, or `"distance"` when no candidate could be routed and the
    /// straight-line order stood: navi's `_rank` values), the warnings (a list, empty when there are none), and the others
    /// (at most 2, with `drive_min`).
    fn nearest(&self, valhalla: &dyn Valhalla, a: &Args, cat: &str, from: &resolve::Resolved) -> Result<NearestEnd, ToolError> {
        let not_set_up = || err(ToolError::NOT_SET_UP, "finding the nearest place of a type needs the places data, which is not installed on this phone");
        let src = self.place_source().ok_or_else(not_set_up)?;
        let cats = src.categories().ok_or_else(not_set_up)?;
        if !cats.iter().any(|c| c == cat) {
            return Err(err(ToolError::BAD_ARGUMENTS, format!("to_type: {cat:?} is not a category on this phone")));
        }
        let origin = (from.lat, from.lon);
        let ans = src.nearest(&cache_tool::places::NearestQuery { category: cat, from: origin, limit: NEAREST_CANDIDATES })?;
        if ans.matches.is_empty() {
            return Err(build::with_ends(err("nearby_empty", "").with("to_type", cat).with("warnings", Value::Array(Vec::new())), from, None, ""));
        }
        let costing = a.mode.travel().costing();
        let mut points = vec![origin];
        points.extend(ans.matches.iter().map(|m| (m.lat, m.lon)));
        self.core.prepare_tiles(&points);
        let mut ranked: Vec<(Option<f64>, cache_tool::places::PlaceMatch)> = ans
            .matches
            .into_iter()
            .map(|m| (valhalla.route(origin, m.arrival.unwrap_or((m.lat, m.lon)), costing).ok().map(|t| t.time_s / 60.0), m))
            .collect();
        let any_time = ranked.iter().any(|(t, _)| t.is_some());
        let mut warnings: Vec<Value> = Vec::new();
        if !any_time {
            warnings.push(json!("routing failed for every candidate; ranked by straight-line distance"));
        }
        if any_time {
            // routed ones first by time, unroutable ones after in the order the pack gave (nearest by straight line)
            ranked.sort_by(|x, y| match (x.0, y.0) {
                (Some(p), Some(q)) => p.partial_cmp(&q).unwrap_or(std::cmp::Ordering::Equal),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => std::cmp::Ordering::Equal,
            });
        }
        let mut it = ranked.into_iter();
        let (_, best) = it.next().expect("non-empty");
        let rest: Vec<Value> = it.take(2).map(|(t, m)| build::candidate(&resolve::Resolved::from_match(m), Some(t))).collect();
        let ranked_by = if any_time { "drive" } else { "distance" };
        Ok((resolve::Resolved::from_match(best), ranked_by, warnings, rest))
    }
}

/// The arguments, read and checked (the framework validated them against the schema; direct callers get the same checks).
pub(crate) struct Args {
    pub from: Option<String>,
    pub to: Option<String>,
    pub to_type: Option<String>,
    pub mode: ModeArg,
    pub near: Option<String>,
    pub land_access: Boundary,
}

impl Args {
    fn parse(args: &Value) -> Result<Args, ToolError> {
        let obj: &Map<String, Value> = args.as_object().ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "arguments must be an object"))?;
        for k in obj.keys() {
            if !["from", "to", "to_type", "mode", "near", "land_access"].contains(&k.as_str()) {
                return Err(err(ToolError::BAD_ARGUMENTS, format!("{k}: not allowed")));
            }
        }
        let s = |k: &str| -> Result<Option<String>, ToolError> {
            match obj.get(k) {
                None | Some(Value::Null) => Ok(None),
                Some(Value::String(x)) => Ok(Some(x.trim().to_string()).filter(|x| !x.is_empty())),
                Some(_) => Err(err(ToolError::BAD_ARGUMENTS, format!("{k}: must be a string"))),
            }
        };
        let mode = s("mode")?.ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "mode: required"))?;
        let mode = ModeArg::parse(&mode).ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "mode: must be one of drive, walk, bike, offroad_foot, offroad_vehicle"))?;
        let land_access = match s("land_access")? {
            None => Boundary::Pragmatic,
            Some(x) => Boundary::from_name(&x).ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "land_access: must be one of strict, pragmatic, emergency"))?,
        };
        let (to, to_type) = (s("to")?, s("to_type")?);
        match (&to, &to_type) {
            (None, None) => return Err(err(ToolError::BAD_ARGUMENTS, "give exactly one of to or to_type")),
            (Some(_), Some(_)) => return Err(err(ToolError::BAD_ARGUMENTS, "give exactly one of to or to_type")),
            _ => {}
        }
        Ok(Args { from: s("from")?, to, to_type, mode, near: s("near")?, land_access })
    }
}
