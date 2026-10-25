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
}

fn user_err(e: cache_user::Error) -> Error {
    Error::new(ErrorCode::from_str_code(e.code), e.message)
}

fn live_err(e: cache_live::Error) -> Error {
    Error::new(ErrorCode::from_str_code(e.code), e.message)
}

impl crate::handle::Handle {
    /// Apply the `user`, `live` and `places` config sections; a section that is absent keeps what was set before.
    /// `user`: the handle's saved places (what tools resolve names against) become cache_user's `UserStore` on that file.
    /// `live`: the `live_data` tool (cache_live) is registered; it leaves itself out of `cs_tool_schemas` while no source
    /// definition is installed in `sources_dir`.
    /// `places`: `{"packs": [...]}` registers `nearby` (cache_places; left out of `cs_tool_schemas` while no pack is installed)
    /// and `locate` (always available: a GPS fix needs no pack).
    pub(crate) fn configure_ext(&mut self, user: Option<UserCfg>, live: Option<LiveCfg>, places: Option<cache_places::PlacesCfg>) {
        if let Some(u) = user {
            self.ext.user = Some(UserStore::new(&u.db_path));
            self.set_saved_places(Box::new(UserStore::new(&u.db_path)));
        }
        if let Some(l) = live {
            self.ext.live = Some(Live::new(l.clone()));
            self.register_tool(Box::new(cache_live::LiveDataTool::new(l)));
        }
        if let Some(p) = places {
            for t in cache_places::tools(&p) {
                self.register_tool(t);
            }
        }
    }
}

impl Ext {
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
}
