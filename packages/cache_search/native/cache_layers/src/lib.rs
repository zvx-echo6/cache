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
pub mod sched;
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

    /// Start the tile server if it is not running and say where it is. A server that no longer listens (iOS takes a suspended
    /// app's listening socket away) is stopped and a new one started, on a new port: the app asks again when it comes to the
    /// front and when a car screen connects, and reloads its map styles when the port changed.
    pub fn serve(&self) -> Result<serde_json::Value> {
        let mut g = self.server.lock().map_err(|_| Error::internal("poisoned"))?;
        if g.as_ref().is_some_and(|s| !s.is_listening()) {
            *g = None;
        }
        if g.is_none() {
            *g = Some(server::TileServer::start(self.inner.clone())?);
        }
        let s = g.as_ref().unwrap();
        Ok(serde_json::json!({"port": s.port, "base_url": s.base_url(), "tilejson": format!("{}/layers/{{id}}/tilejson.json", s.base_url()), "online": self.inner.is_online()}))
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::io::AsRawFd;
    use std::time::Duration;

    fn answers(port: u16) -> bool {
        ureq::get(&format!("http://127.0.0.1:{port}/health")).timeout(Duration::from_secs(2)).call().map(|r| r.status() == 200).unwrap_or(false)
    }

    /// iOS takes a suspended app's listening socket away (Apple TN2277): the server must not keep handing out a dead port.
    #[test]
    fn a_tile_server_whose_listener_died_is_started_again_on_the_next_serve() {
        let dir = std::env::temp_dir().join(format!("cache-layers-relisten-{}", std::process::id()));
        let cfg = LayersCfg { dir: dir.to_string_lossy().into_owned(), defs_dirs: vec![], catalogue_urls: vec![], cache_max_bytes: 1 << 20, online: false };
        let layers = Layers::new(cfg).unwrap();
        let port = |v: serde_json::Value| v["port"].as_u64().unwrap() as u16;
        let first = port(layers.serve().unwrap());
        assert!(answers(first));
        assert_eq!(port(layers.serve().unwrap()), first, "a live server is kept");
        {
            let g = layers.server.lock().unwrap();
            // SAFETY: shuts down a socket this test owns a handle on; the descriptor stays open.
            unsafe { libc::shutdown(g.as_ref().unwrap().listener.as_raw_fd(), libc::SHUT_RDWR) };
        }
        for _ in 0..100 {
            if !answers(first) {
                break;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        assert!(!answers(first), "the old port no longer answers");
        let second = port(layers.serve().unwrap());
        assert!(answers(second), "the next serve gives a port that answers");
        assert_eq!(port(layers.serve().unwrap()), second, "and keeps it");
        drop(layers);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
