//! Cache's map layer engine. See packages/cache_search/DESIGN-LAYERS.md.
//!
//! - `def`: layer definitions (data, never code), format 1
//! - `core`: the catalogue, tile resolution (downloaded -> viewed cache -> network), TileJSON
//! - `server`: the local tile server (127.0.0.1, random port)
//! - `download`: area downloads into PMTiles (plan, resume, update, delete)
//! - `contour`: contour lines from elevation tiles; `cog`: GeoTIFF windows; `pmtiles`: the archive format
//! - `offroad`: the reader that cache_offroad uses for elevation and land-cover cells

pub mod cog;
pub mod contour;
pub mod core;
pub mod def;
pub mod download;
pub mod error;
pub mod http;
pub mod offroad;
pub mod pmtiles;
pub mod server;
pub mod store;
pub mod tilecache;

pub use crate::core::{Inner, LayersCfg, TileOut};
pub use crate::error::{Error, Result};
pub use download::{AreaReq, Done};

use std::sync::{Arc, Mutex};

/// The layer engine of one handle: the shared state plus the tile server once it has been asked for.
pub struct Layers {
    pub inner: Arc<Inner>,
    server: Mutex<Option<server::TileServer>>,
}

impl Layers {
    pub fn new(cfg: LayersCfg) -> Result<Layers> {
        Ok(Layers { inner: Arc::new(Inner::open(cfg)?), server: Mutex::new(None) })
    }

    /// Start the tile server (once) and say where it is.
    pub fn serve(&self) -> Result<serde_json::Value> {
        let mut g = self.server.lock().map_err(|_| Error::internal("poisoned"))?;
        if g.is_none() {
            *g = Some(server::TileServer::start(self.inner.clone())?);
        }
        let s = g.as_ref().unwrap();
        Ok(serde_json::json!({"port": s.port, "base_url": s.base_url(), "tilejson": format!("{}/layers/{{id}}/tilejson.json", s.base_url()), "online": self.inner.is_online()}))
    }
}
