//! Saved places (`cache_user`) and live data (`cache_live`) on a handle: the glue behind `cs_places_*` and
//! `cs_live_*`. The logic lives in those two crates; this file only holds their state, maps their errors to the
//! core's stable codes, and hands the saved places to the live engine.

use crate::error::{Error, ErrorCode, Result};
use cache_live::{Live, LiveCfg};
use cache_user::UserStore;
use serde::Deserialize;

/// The `user` section of the `cs_open` config: `{"db_path": ".../user.sqlite"}`.
#[derive(Debug, Deserialize)]
pub struct UserCfg {
    pub db_path: String,
}

#[derive(Default)]
pub struct Ext {
    pub user: Option<UserStore>,
    pub live: Option<Live>,
    pub layers: Option<cache_layers::Layers>,
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

impl crate::handle::Handle {
    /// Apply the `user` and `live` config sections; a section that is absent keeps what was set before.
    /// `user`: the handle's saved places (what tools resolve names against) become cache_user's `UserStore` on that file.
    /// `live`: the `live_data` tool (cache_live) is registered; it leaves itself out of `cs_tool_schemas` while no source
    /// definition is installed in `sources_dir`.
    pub(crate) fn configure_ext(&mut self, user: Option<UserCfg>, live: Option<LiveCfg>) {
        if let Some(u) = user {
            self.ext.user = Some(UserStore::new(&u.db_path));
            self.set_saved_places(Box::new(UserStore::new(&u.db_path)));
        }
        if let Some(l) = live {
            self.ext.live = Some(Live::new(l.clone()));
            self.register_tool(Box::new(cache_live::LiveDataTool::new(l)));
        }
    }
}

impl Ext {
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

    fn layers(&self) -> Result<&cache_layers::Layers> {
        self.layers.as_ref().ok_or_else(|| Error::new(ErrorCode::NotConfigured, "map layers need \"layers\": {\"dir\", \"defs_dirs\"} in the cs_open config"))
    }

    fn user(&self) -> Result<&UserStore> {
        self.user.as_ref().ok_or_else(|| Error::new(ErrorCode::NotConfigured, "saved places need \"user\": {\"db_path\"} in the cs_open config"))
    }

    fn live(&self) -> Result<&Live> {
        self.live
            .as_ref()
            .ok_or_else(|| Error::new(ErrorCode::NotConfigured, "live data needs \"live\": {\"db_path\",\"sources_dir\"} in the cs_open config"))
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
        self.live()?.fetch(req, self.places()).map_err(live_err)
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
