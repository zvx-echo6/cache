//! cache_offroad: the unified multi-mode off-road router, ported from navi's `navi_offroute` Auto
//! search so Cache's phone produces the same off-road routes as navi does on its server.
//! No dependency on `cache_search`. See DESIGN-OFFROAD.md.
pub mod astar;
pub mod cost;
pub mod elevation;
pub mod grid;
pub mod mvum;
pub mod pack;
pub mod pmtiles;
pub mod router;
pub mod snap;
pub mod transitions;
pub mod valhalla;

pub use cost::Mode;
pub use pack::{PackSource, SqlitePack};
pub use router::{route, Boundary, RequestMode, RouteError, RouteOptions, RouteRequest, RouteResult, Router};
pub use valhalla::{StubValhalla, Valhalla};
pub mod surface;
#[cfg(feature = "shim")]
pub mod shim;
pub mod directions;
pub mod navigate;
pub mod offroad_legs;

pub use elevation::{ElevationSource, ElevationTiles, PmtilesElevation, TileElevation};
pub use navigate::{NavigateRequest, Navigator, TravelMode, Waypoint};
