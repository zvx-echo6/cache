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
    pub live: Option<Live>,
    /// Where a places pack plugs into the navigate tool (see `Handle::set_place_source`).
    pub places: cache_navigate::PlaceSlot,
    pub video: Option<Video>,
}

fn user_err(e: cache_user::Error) -> Error {
    Error::new(ErrorCode::from_str_code(e.code), e.message)
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
    /// Apply the `user`, `live` and `places` config sections; a section that is absent keeps what was set before.
    /// `user`: the handle's saved places (what tools resolve names against) become cache_user's `UserStore` on that file.
    /// `live`: the `live_data` tool (cache_live) is registered; it leaves itself out of `cs_tool_schemas` while no source
    /// definition is installed in `sources_dir`.
    /// `places`: `{"packs": [...]}` registers `nearby` (cache_places; left out of `cs_tool_schemas` while no pack is installed)
    /// and `locate` (always available: a GPS fix needs no pack), and plugs the same packs into the navigate tool as its
    /// `PlaceSource` (names for `to`, `from` and `near`, and the `to_type` categories).
    /// `routing`: the navigate tool (cache_navigate).
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
        }
        if let Some(l) = live {
            self.ext.live = Some(Live::new(l.clone()));
            self.register_tool(Box::new(cache_live::LiveDataTool::new(l)));
        }
        if let Some(p) = places {
            let (tools, source) = cache_places::tools_and_source(&p);
            for t in tools {
                self.register_tool(t);
            }
            self.set_place_source(Some(source));
        }
        if let Some(r) = routing {
            self.register_tool(Box::new(cache_navigate::NavigateTool::new(r, self.ext.places.clone())));
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
    fn user(&self) -> Result<&UserStore> {
        self.user.as_ref().ok_or_else(|| Error::new(ErrorCode::NotConfigured, "saved places need \"user\": {\"db_path\"} in the cs_open config"))
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
        self.live()?.fetch(req, self.places()).map_err(live_err)
    }

    pub fn live_get(&self, req: &str) -> Result<String> {
        self.live()?.get(req, self.places()).map_err(live_err)
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
