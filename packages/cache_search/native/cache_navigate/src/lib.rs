//! The `navigate` tool (docs/TOOLS.md, "navigate"): directions in one call over the offline maps on the phone.
//!
//! Road routing is Valhalla (the C shim, tiles from the installed map region); off-road legs are the off-road
//! router (`cache_offroad`, the pack and the elevation file). `schema()` is built from what is installed:
//! nothing without the Valhalla tiles and the shim library; the `to_type` enum from the places pack's categories
//! (TOOLS.md's list while no places pack is installed); the off-road modes are always listed, and asking for one
//! without the off-road pack and elevation file is a clear `not_set_up`.
//!
//! Names (`to`, `from`, `near`) are resolved by [`resolve`](crate) in this order: "lat,lon" text, the user's saved
//! places, then the places pack through `cache_tool::places::PlaceSource` (plugged in with [`PlaceSlot`]).

mod build;
mod config;
mod resolve;

pub use config::{NavigateCfg, OffroadCfg, ValhallaCfg};
pub use resolve::parse_latlon;

use cache_offroad::directions::{DEFAULT_OFFROAD_SNAP_M, TravelMode};
use cache_offroad::navigate::{NavigateRequest, Navigator};
use cache_offroad::pack::PackSource;
use cache_offroad::router::{Boundary, RouteOptions};
use cache_offroad::shim::{config_for_tiles, ShimValhalla};
use cache_offroad::valhalla::Valhalla;
use cache_offroad::{ElevationSource, PmtilesElevation, SqlitePack};
use cache_tool::places::PlaceSource;
use cache_tool::{Tool, ToolCtx, ToolError, ToolOutput};
use serde_json::{json, Map, Value};
use std::path::Path;
use std::sync::{Arc, Mutex, RwLock};

/// Where a places pack plugs into the tool (shared with the handle, so it can be set after the tool is registered).
pub type PlaceSlot = Arc<RwLock<Option<Arc<dyn PlaceSource>>>>;

/// TOOLS.md's `to_type` list, used while no places pack says which categories exist.
pub const DEFAULT_TO_TYPES: [&str; 11] =
    ["emergency_room", "hospital", "urgent_care", "pharmacy", "fuel", "police", "fire_station", "campground", "trailhead", "water", "shelter"];

/// How many of the nearest places of a type are routed to find the closest by travel time.
const NEAREST_CANDIDATES: usize = 5;
/// Two places closer than this are the same place.
const SAME_PLACE_M: f64 = 30.0;

struct OffroadData {
    pack: SqlitePack,
    elevation: PmtilesElevation,
}

pub struct NavigateTool {
    cfg: NavigateCfg,
    places: PlaceSlot,
    valhalla: Mutex<Option<Arc<dyn Valhalla>>>,
    offroad: Mutex<Option<Arc<OffroadData>>>,
    /// Tests inject a Valhalla and skip the file checks.
    injected: bool,
}

fn err(code: &str, detail: impl Into<String>) -> ToolError {
    ToolError::new(code, detail)
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

/// No off-road data: the stand-ins are never read (the request is made with off-road set to "never").
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
}
impl ElevationSource for NoElevation {
    fn read_elevation(&self, _: i64, _: i64, _: usize, _: usize) -> Result<Vec<f32>, cache_offroad::elevation::ElevError> {
        Err(cache_offroad::elevation::ElevError::Msg("no elevation file".into()))
    }
}

/// The modes of the tool and what they ask of the router.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum ModeArg {
    Drive,
    Walk,
    Bike,
    OffroadVehicle,
    OffroadFoot,
}

impl ModeArg {
    fn parse(s: &str) -> Option<ModeArg> {
        Some(match s {
            "drive" => ModeArg::Drive,
            "walk" => ModeArg::Walk,
            "bike" => ModeArg::Bike,
            "offroad_vehicle" => ModeArg::OffroadVehicle,
            "offroad_foot" => ModeArg::OffroadFoot,
            _ => return None,
        })
    }
    pub(crate) fn name(self) -> &'static str {
        match self {
            ModeArg::Drive => "drive",
            ModeArg::Walk => "walk",
            ModeArg::Bike => "bike",
            ModeArg::OffroadVehicle => "offroad_vehicle",
            ModeArg::OffroadFoot => "offroad_foot",
        }
    }
    pub(crate) fn travel(self) -> TravelMode {
        match self {
            ModeArg::Drive | ModeArg::OffroadVehicle => TravelMode::Drive,
            ModeArg::Walk | ModeArg::OffroadFoot => TravelMode::Walk,
            ModeArg::Bike => TravelMode::Bike,
        }
    }
    fn is_offroad(self) -> bool {
        matches!(self, ModeArg::OffroadVehicle | ModeArg::OffroadFoot)
    }
}

impl NavigateTool {
    pub fn new(cfg: NavigateCfg, places: PlaceSlot) -> NavigateTool {
        NavigateTool { cfg, places, valhalla: Mutex::new(None), offroad: Mutex::new(None), injected: false }
    }

    /// For tests: a Valhalla supplied by the caller; the file checks are skipped.
    pub fn with_valhalla(cfg: NavigateCfg, places: PlaceSlot, valhalla: Arc<dyn Valhalla>) -> NavigateTool {
        NavigateTool { cfg, places, valhalla: Mutex::new(Some(valhalla)), offroad: Mutex::new(None), injected: true }
    }

    fn place_source(&self) -> Option<Arc<dyn PlaceSource>> {
        self.places.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn routing_installed(&self) -> bool {
        if self.injected {
            return true;
        }
        match &self.cfg.valhalla {
            Some(v) => Path::new(&v.tiles).is_file() && Path::new(&v.shim).is_file(),
            None => false,
        }
    }

    fn offroad_installed(&self) -> bool {
        match &self.cfg.offroad {
            Some(o) => Path::new(&o.pack).is_file() && Path::new(&o.elevation).is_file(),
            None => false,
        }
    }

    fn valhalla(&self) -> Result<Arc<dyn Valhalla>, ToolError> {
        let mut g = lock(&self.valhalla);
        if let Some(v) = &*g {
            return Ok(v.clone());
        }
        let Some(v) = &self.cfg.valhalla else { return Err(err(ToolError::NOT_SET_UP, "no map region is installed")) };
        let config = config_for_tiles(Path::new(&v.tiles));
        let shim = ShimValhalla::load(Path::new(&v.shim), &config).map_err(|e| err(ToolError::NOT_SET_UP, format!("the road router could not start: {e}")))?;
        let shim: Arc<dyn Valhalla> = Arc::new(shim);
        *g = Some(shim.clone());
        Ok(shim)
    }

    /// The off-road pack and elevation, opened on first use; None while either file is missing.
    fn offroad(&self) -> Result<Option<Arc<OffroadData>>, ToolError> {
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

    fn to_types(&self) -> Vec<String> {
        self.place_source().and_then(|p| p.categories()).unwrap_or_else(|| DEFAULT_TO_TYPES.iter().map(|s| s.to_string()).collect())
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
            "description": "Directions in one call, to a named place (to) or to the nearest place of a type (to_type), using the offline maps on this phone. Omit from to start at the phone's current location. Returns the places actually matched, so a wrong match can be seen.",
            "strict": true,
            "parameters": {"type": "object", "properties": {
                "from": {"type": "string", "maxLength": 300,
                         "description": "Starting place name. Omit it when the person means where they are now."},
                "to": {"type": "string", "minLength": 1, "maxLength": 300,
                       "description": "Destination place name, for a named place. For \"nearest X\" give to_type instead."},
                "to_type": {"type": "string", "enum": self.to_types(),
                            "description": "Use this instead of to whenever the person asks for the nearest place of a kind. Finds the nearest one by travel time from the start. For a hospital in an emergency use emergency_room."},
                "mode": {"type": "string", "enum": ["drive", "walk", "bike", "offroad_vehicle", "offroad_foot"],
                         "description": "drive, walk and bike follow roads and paths. offroad_vehicle and offroad_foot cross open country between roads, tracks and trails; use them only when the person asks to go off-road or the place is off the road network."},
                "near": {"type": "string", "minLength": 1, "maxLength": 200,
                         "description": "Town and state the trip is in, e.g. \"Burley, Idaho\". Give it whenever the question names or implies one."},
                "land_access": {"type": "string", "enum": ["strict", "pragmatic", "emergency"],
                                "description": "Off-road legs only: how private or closed land is treated. strict never crosses it, pragmatic (the default) crosses it only when it saves a lot, emergency ignores it."}},
                "required": ["mode"], "additionalProperties": false}}}))
    }

    fn run(&self, ctx: &ToolCtx, args: &Value) -> Result<ToolOutput, ToolError> {
        let a = Args::parse(args)?;
        if !self.routing_installed() {
            return Err(err(ToolError::NOT_SET_UP, "navigate is not set up: no map region is installed"));
        }
        let have_offroad = match self.offroad() {
            Ok(o) => o,
            Err(e) if a.mode.is_offroad() => return Err(e),
            Err(_) => None,
        };
        if a.mode.is_offroad() && have_offroad.is_none() {
            return Err(err(ToolError::NOT_SET_UP, "off-road routing is not set up: the off-road pack and elevation data are not installed on this phone"));
        }
        let valhalla = self.valhalla()?;
        let r = resolve::Resolver { ctx, source: self.place_source() };

        // the town the trip is in, and where to prefer matches
        let near_pt = a.near.as_deref().and_then(|t| r.near_point(t));
        let bias = near_pt.as_ref().map(|p| (p.lat, p.lon)).or(ctx.location.map(|l| (l.lat, l.lon)));
        let location_bias = if near_pt.is_some() {
            "near"
        } else if ctx.location.is_some() {
            "phone_location"
        } else {
            "none"
        };

        let from = match a.from.as_deref() {
            Some(t) => r.named(t, "from", a.near.as_deref(), bias, false)?,
            None => match (ctx.location, near_pt) {
                (Some(l), _) => resolve::Resolved::here(l.lat, l.lon),
                (None, Some(p)) => p,
                (None, None) if a.near.is_some() => {
                    return Err(err("origin_unknown", format!("the start is not known: no starting place was given, the phone's location is not known, and {:?} could not be found", a.near.as_deref().unwrap_or(""))))
                }
                (None, None) => return Err(err(ToolError::NO_LOCATION, "no starting place was given and the phone's location is not known")),
            },
        };

        let mut nearest_search = None;
        let mut others: Vec<Value> = Vec::new();
        let to = match (a.to.as_deref(), a.to_type.as_deref()) {
            (Some(t), None) => {
                let mut to = r.named(t, "to", a.near.as_deref(), bias, true)?;
                for o in std::mem::take(&mut to.others) {
                    others.push(build::candidate(&o, None, a.mode));
                }
                to
            }
            (None, Some(cat)) => {
                let (to, ranked_by, rest) = self.nearest(&r, &*valhalla, &a, cat, (from.lat, from.lon))?;
                nearest_search = Some(json!({"to_type": cat, "ranked_by": ranked_by}));
                others = rest;
                to
            }
            _ => unreachable!("Args::parse checked"),
        };

        if cache_offroad::grid::haversine_m(from.lat, from.lon, to.lat, to.lon) < SAME_PLACE_M {
            return Err(err("same_place", format!("the start and the destination are the same place ({})", to.name)));
        }

        let mut req = NavigateRequest::new(from.waypoint(), to.waypoint(), a.mode.travel(), a.land_access);
        req.offroad = match (a.mode.is_offroad(), have_offroad.is_some()) {
            (true, _) => cache_offroad::directions::OffroadChoice::Always,
            (false, true) => cache_offroad::directions::OffroadChoice::Auto,
            (false, false) => cache_offroad::directions::OffroadChoice::Never,
        };
        let (no_pack, no_elev) = (NoPack, NoElevation);
        let (pack, elev): (&dyn PackSource, &dyn ElevationSource) = match &have_offroad {
            Some(o) => (&o.pack, &o.elevation),
            None => (&no_pack, &no_elev),
        };
        let mut nav = Navigator::new(pack, elev, &*valhalla);
        nav.options = self.route_options();
        let d = nav.navigate(&req).map_err(|e| err(ToolError::BAD_ARGUMENTS, e.to_string()))?;
        if !d.ok {
            return Err(build::route_error(&d, &*valhalla, (from.lat, from.lon), (to.lat, to.lon), a.mode));
        }
        let region = self.region_info(ctx.now);
        let gap_warnings = have_offroad.is_none();
        Ok(ToolOutput::Json(build::result(&d, &from, &to, a.mode, location_bias, others, nearest_search, region, gap_warnings, DEFAULT_OFFROAD_SNAP_M)))
    }
}

impl NavigateTool {
    fn route_options(&self) -> RouteOptions {
        let mut o = RouteOptions::default();
        if let Some(m) = self.cfg.offroad.as_ref().and_then(|o| o.max_cells) {
            o.max_cells = m;
        }
        o
    }

    /// The nearest place of a category by travel time from `origin`: the winner, how the ranking was done, and the others.
    fn nearest(&self, r: &resolve::Resolver, valhalla: &dyn Valhalla, a: &Args, cat: &str, origin: (f64, f64)) -> Result<(resolve::Resolved, String, Vec<Value>), ToolError> {
        let Some(src) = self.place_source() else {
            return Err(err(ToolError::NOT_SET_UP, "finding the nearest place of a type needs the places data, which is not installed on this phone"));
        };
        let Some(cats) = src.categories() else {
            return Err(err(ToolError::NOT_SET_UP, "finding the nearest place of a type needs the places data, which is not installed on this phone"));
        };
        if !cats.iter().any(|c| c == cat) {
            return Err(err(ToolError::BAD_ARGUMENTS, format!("to_type: {cat:?} is not a category on this phone")));
        }
        let _ = r;
        let ans = src.nearest(&cache_tool::places::NearestQuery { category: cat, from: origin, limit: NEAREST_CANDIDATES })?;
        if ans.matches.is_empty() {
            let km = ans.searched_within_km.map(Value::from).unwrap_or(Value::Null);
            return Err(err("nearby_empty", format!("no {cat} was found near the start")).with("to_type", cat).with("searched_within_km", km));
        }
        let costing = a.mode.travel().costing();
        let mut ranked: Vec<(Option<f64>, cache_tool::places::PlaceMatch)> = ans
            .matches
            .into_iter()
            .map(|m| (valhalla.route(origin, (m.lat, m.lon), costing).ok().map(|t| t.time_s / 60.0), m))
            .collect();
        let any_time = ranked.iter().any(|(t, _)| t.is_some());
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
        let rest: Vec<Value> = it.map(|(t, m)| build::candidate(&m, t, a.mode)).collect();
        let ranked_by = if any_time { format!("{}_time", a.mode.travel().name()) } else { "distance".to_string() };
        Ok((resolve::Resolved::from_match(best), ranked_by, rest))
    }

    /// Name and age of the installed map region (the tiles file).
    fn region_info(&self, now: &str) -> (String, String) {
        let Some(v) = &self.cfg.valhalla else { return (String::new(), "unknown".into()) };
        let name = v.region.clone().unwrap_or_else(|| config::region_from_path(&v.tiles));
        let age = std::fs::metadata(&v.tiles)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .and_then(|t| {
                let now = chrono::DateTime::parse_from_rfc3339(now.trim()).ok()?.timestamp();
                Some(build::age_words(now - t.as_secs() as i64))
            })
            .unwrap_or_else(|| "unknown".into());
        (name, age)
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
        let mode = ModeArg::parse(&mode).ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "mode: must be one of drive, walk, bike, offroad_vehicle, offroad_foot"))?;
        let land_access = match s("land_access")? {
            None => Boundary::Pragmatic,
            Some(x) => Boundary::from_name(&x).ok_or_else(|| err(ToolError::BAD_ARGUMENTS, "land_access: must be one of strict, pragmatic, emergency"))?,
        };
        let (to, to_type) = (s("to")?, s("to_type")?);
        match (&to, &to_type) {
            (None, None) => return Err(err(ToolError::BAD_ARGUMENTS, "give either to (a place name) or to_type (the nearest place of a kind)")),
            (Some(_), Some(_)) => return Err(err(ToolError::BAD_ARGUMENTS, "give either to or to_type, not both")),
            _ => {}
        }
        Ok(Args { from: s("from")?, to, to_type, mode, near: s("near")?, land_access })
    }
}
