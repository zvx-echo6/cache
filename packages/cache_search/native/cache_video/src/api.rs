//! Instances, login and browse. Every function takes one JSON request and returns one JSON answer (see `cache_search.h`).
//!
//! PeerTube endpoints used (all from the official REST API reference): `GET /api/v1/config`,
//! `GET /api/v1/oauth-clients/local`, `POST /api/v1/users/token`, `GET /api/v1/users/me`, `GET /api/v1/video-channels`,
//! `GET /api/v1/search/video-channels`, `GET /api/v1/videos`, `GET /api/v1/video-channels/{handle}/videos`,
//! `GET /api/v1/search/videos`, `GET /api/v1/videos/{id}`, `GET /api/v1/videos/{id}/captions`,
//! `POST /api/v1/videos/{id}/token` (private videos only) and, for the HLS audio+video join, `GET /download/videos/generate/{id}`.

use crate::http;
use crate::model;
use crate::store::{self, Instance};
use crate::{now_iso, Error, Result, Video};
use percent_encoding::{utf8_percent_encode, AsciiSet, NON_ALPHANUMERIC};
use serde::Deserialize;
use serde_json::{json, Value};

const UNRESERVED: &AsciiSet = &NON_ALPHANUMERIC.remove(b'-').remove(b'_').remove(b'.').remove(b'~');

pub fn enc(s: &str) -> String {
    utf8_percent_encode(s, UNRESERVED).to_string()
}

fn parse<'a, T: Deserialize<'a>>(req: &'a str) -> Result<T> {
    serde_json::from_str(req).map_err(|e| Error::bad_json(format!("request_json: {e}")))
}

fn token(t: &Option<String>) -> Option<&str> {
    t.as_deref().filter(|x| !x.is_empty())
}

fn page(start: Option<u32>, count: Option<u32>) -> (u32, u32) {
    (start.unwrap_or(0), count.unwrap_or(20).clamp(1, 100))
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct AddReq {
    url: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RemoveReq {
    instance: String,
    #[serde(default)]
    delete_downloads: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LoginReq {
    instance: String,
    username: String,
    password: String,
    /// The two-factor code, when the account has one.
    #[serde(default)]
    otp: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RefreshReq {
    instance: String,
    refresh_token: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct MeReq {
    instance: String,
    token: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ChannelsReq {
    instance: String,
    #[serde(default)]
    search: Option<String>,
    #[serde(default)]
    start: Option<u32>,
    #[serde(default)]
    count: Option<u32>,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ListReq {
    instance: String,
    /// A channel's handle (`name`, or `name@host`); without it, the instance's latest videos.
    #[serde(default)]
    channel: Option<String>,
    #[serde(default)]
    start: Option<u32>,
    #[serde(default)]
    count: Option<u32>,
    /// A PeerTube sort key; default newest first.
    #[serde(default)]
    sort: Option<String>,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SearchReq {
    instance: String,
    query: String,
    #[serde(default)]
    start: Option<u32>,
    #[serde(default)]
    count: Option<u32>,
    #[serde(default)]
    sort: Option<String>,
    #[serde(default)]
    token: Option<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct GetReq {
    instance: String,
    video: String,
    #[serde(default)]
    token: Option<String>,
}

fn ok_sort(s: &str) -> Result<&str> {
    let t = s.trim_start_matches('-');
    if !t.is_empty() && t.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
        Ok(s)
    } else {
        Err(Error::bad_json(format!("sort {s:?} is not a PeerTube sort key")))
    }
}

impl Video {
    /// `{"instances":[...]}`.
    pub fn instances_json(&self) -> Result<String> {
        let l = self.load_instances()?;
        Ok(json!({"instances": l.iter().map(Instance::to_json).collect::<Vec<_>>()}).to_string())
    }

    /// Add an instance by address. Reads `/api/v1/config` to confirm it is PeerTube and to get its display name.
    /// Adding one that is already there refreshes its name and version.
    pub fn instance_add(&self, req: &str) -> Result<String> {
        let r: AddReq = parse(req)?;
        let (id, base) = store::normalize(&r.url)?;
        let cfg = http::get_json(&format!("{base}/api/v1/config"), None, "reading the instance's configuration")?;
        let version = cfg["serverVersion"].as_str().ok_or_else(|| Error::bad_response(format!("{base} does not look like a PeerTube instance (no serverVersion in /api/v1/config)")))?;
        let name = cfg["instance"]["name"].as_str().filter(|n| !n.is_empty()).unwrap_or(&id).to_string();
        let mut list = self.load_instances()?;
        let inst = match list.iter_mut().find(|i| i.id == id) {
            Some(i) => {
                i.name = name;
                i.version = version.to_string();
                i.url = base;
                i.clone()
            }
            None => {
                let i = Instance { id, url: base, name, version: version.to_string(), added_at: now_iso() };
                list.push(i.clone());
                i
            }
        };
        self.save_instances(&list)?;
        Ok(inst.to_json().to_string())
    }

    /// Remove an instance. Its downloaded videos stay (they play offline without it) unless `delete_downloads` is set.
    pub fn instance_remove(&self, req: &str) -> Result<String> {
        let r: RemoveReq = parse(req)?;
        let inst = self.instance(&r.instance)?;
        let mut list = self.load_instances()?;
        list.retain(|i| i.id != inst.id);
        self.save_instances(&list)?;
        if r.delete_downloads {
            let d = self.downloads_root().join(&inst.id);
            if d.is_dir() {
                std::fs::remove_dir_all(&d).map_err(|e| Error::io(format!("deleting {}: {e}", d.display())))?;
            }
        }
        Ok(json!({"removed": inst.id, "downloads_deleted": r.delete_downloads}).to_string())
    }

    fn oauth_client(&self, inst: &Instance) -> Result<(String, String)> {
        let c = http::get_json(&format!("{}/api/v1/oauth-clients/local", inst.url), None, "login (client id)")?;
        match (c["client_id"].as_str(), c["client_secret"].as_str()) {
            (Some(a), Some(b)) => Ok((a.to_string(), b.to_string())),
            _ => Err(Error::bad_response("login: the instance sent no OAuth client")),
        }
    }

    fn token_answer(inst: &Instance, t: &Value) -> Result<String> {
        let access = t["access_token"].as_str().ok_or_else(|| Error::bad_response("login: the instance sent no access token"))?;
        Ok(json!({
            "instance": inst.id,
            "token_type": t["token_type"].as_str().unwrap_or("Bearer"),
            "access_token": access,
            "refresh_token": t["refresh_token"],
            "expires_in": t["expires_in"],
            "refresh_token_expires_in": t["refresh_token_expires_in"],
        })
        .to_string())
    }

    /// Log in with PeerTube's OAuth password flow. The tokens are returned to the caller and kept nowhere here; the
    /// password is used for this call only and appears in no error message.
    pub fn login(&self, req: &str) -> Result<String> {
        let r: LoginReq = parse(req)?;
        let inst = self.instance(&r.instance)?;
        let (cid, secret) = self.oauth_client(&inst)?;
        let otp = r.otp.as_deref().filter(|o| !o.is_empty());
        let headers: Vec<(&str, &str)> = otp.map(|o| ("x-peertube-otp", o)).into_iter().collect();
        let t = http::post_form(
            &format!("{}/api/v1/users/token", inst.url),
            &[("client_id", &cid), ("client_secret", &secret), ("grant_type", "password"), ("username", &r.username), ("password", &r.password)],
            &headers,
            "login",
        )?;
        Self::token_answer(&inst, &t)
    }

    /// Trade a refresh token for new tokens (the refresh token changes too: store both).
    pub fn refresh(&self, req: &str) -> Result<String> {
        let r: RefreshReq = parse(req)?;
        let inst = self.instance(&r.instance)?;
        let (cid, secret) = self.oauth_client(&inst)?;
        let t = http::post_form(
            &format!("{}/api/v1/users/token", inst.url),
            &[("client_id", &cid), ("client_secret", &secret), ("grant_type", "refresh_token"), ("refresh_token", &r.refresh_token)],
            &[],
            "refreshing the login",
        )?;
        Self::token_answer(&inst, &t)
    }

    /// Who the token belongs to: `{"instance","username","display_name","role"}` (no e-mail address).
    pub fn me(&self, req: &str) -> Result<String> {
        let r: MeReq = parse(req)?;
        let inst = self.instance(&r.instance)?;
        let v = http::get_json(&format!("{}/api/v1/users/me", inst.url), Some(&r.token), "reading the account")?;
        Ok(json!({
            "instance": inst.id,
            "username": v["username"],
            "display_name": v["account"]["displayName"],
            "role": v["role"]["label"],
        })
        .to_string())
    }

    /// Channels of the instance, or the ones matching `search`.
    pub fn channels(&self, req: &str) -> Result<String> {
        let r: ChannelsReq = parse(req)?;
        let inst = self.instance(&r.instance)?;
        let (start, count) = page(r.start, r.count);
        let url = match r.search.as_deref().filter(|s| !s.trim().is_empty()) {
            Some(q) => format!("{}/api/v1/search/video-channels?search={}&searchTarget=local&start={start}&count={count}", inst.url, enc(q)),
            None => format!("{}/api/v1/video-channels?start={start}&count={count}&sort=-createdAt", inst.url),
        };
        let v = http::get_json(&url, token(&r.token), "listing channels")?;
        let list: Vec<Value> = v["data"]
            .as_array()
            .ok_or_else(|| Error::bad_response("channels: no data array"))?
            .iter()
            .map(|c| {
                let mut a = model::actor(&inst, c);
                a["description"] = c["description"].clone();
                a["followers"] = json!(c["followersCount"].as_u64().unwrap_or(0));
                a
            })
            .collect();
        Ok(json!({"instance": inst.id, "total": v["total"].as_u64().unwrap_or(list.len() as u64), "start": start, "channels": list}).to_string())
    }

    fn video_page(&self, inst: &Instance, url: &str, start: u32, tok: Option<&str>, what: &str) -> Result<String> {
        let v = http::get_json(url, tok, what)?;
        let list: Vec<Value> = v["data"]
            .as_array()
            .ok_or_else(|| Error::bad_response(format!("{what}: no data array")))?
            .iter()
            .map(|x| {
                let dl = x["uuid"].as_str().map(|u| self.is_downloaded(&inst.id, u)).unwrap_or(false);
                model::summary(inst, x, dl)
            })
            .collect();
        Ok(json!({"instance": inst.id, "total": v["total"].as_u64().unwrap_or(list.len() as u64), "start": start, "videos": list}).to_string())
    }

    /// The instance's latest videos, or a channel's.
    pub fn list(&self, req: &str) -> Result<String> {
        let r: ListReq = parse(req)?;
        let inst = self.instance(&r.instance)?;
        let (start, count) = page(r.start, r.count);
        let sort = ok_sort(r.sort.as_deref().unwrap_or("-publishedAt"))?;
        let url = match r.channel.as_deref().filter(|c| !c.is_empty()) {
            Some(c) => format!("{}/api/v1/video-channels/{}/videos?start={start}&count={count}&sort={sort}", inst.url, enc(c)),
            None => format!("{}/api/v1/videos?start={start}&count={count}&sort={sort}", inst.url),
        };
        self.video_page(&inst, &url, start, token(&r.token), "listing videos")
    }

    /// Search the instance's own videos (`searchTarget=local`: the instance does not query other servers).
    pub fn search(&self, req: &str) -> Result<String> {
        let r: SearchReq = parse(req)?;
        if r.query.trim().is_empty() {
            return Err(Error::bad_json("query must not be empty"));
        }
        let inst = self.instance(&r.instance)?;
        let (start, count) = page(r.start, r.count);
        let sort = ok_sort(r.sort.as_deref().unwrap_or("-match"))?;
        let url = format!("{}/api/v1/search/videos?search={}&searchTarget=local&start={start}&count={count}&sort={sort}", inst.url, enc(&r.query));
        self.video_page(&inst, &url, start, token(&r.token), "searching videos")
    }

    /// The raw details of a video on an instance (also used by the downloader and link resolution).
    pub fn fetch_details(&self, inst: &Instance, video: &str, tok: Option<&str>) -> Result<Value> {
        store::safe_component(video)?;
        http::get_json(&format!("{}/api/v1/videos/{}", inst.url, enc(video)), tok, "reading the video")
    }

    pub fn fetch_captions(&self, inst: &Instance, video: &str, tok: Option<&str>) -> Vec<Value> {
        match http::get_json(&format!("{}/api/v1/videos/{}/captions", inst.url, enc(video)), tok, "reading the captions") {
            Ok(v) => v["data"].as_array().map(|a| a.iter().filter_map(|c| model::caption(inst, c)).collect()).unwrap_or_default(),
            Err(_) => vec![],
        }
    }

    /// The video page: details, captions, one download option per resolution (and audio only) with sizes, stream addresses.
    pub fn get(&self, req: &str) -> Result<String> {
        let r: GetReq = parse(req)?;
        let inst = self.instance(&r.instance)?;
        let d = self.fetch_details(&inst, &r.video, token(&r.token))?;
        let uuid = d["uuid"].as_str().unwrap_or(&r.video).to_string();
        let caps = self.fetch_captions(&inst, &uuid, token(&r.token));
        let downloaded = self.manifest(&inst.id, &uuid).ok().flatten().map(|m| json!({"kind": m["kind"], "resolution": m["resolution"], "size": m["size"], "downloaded_at": m["downloaded_at"]}));
        Ok(model::details(&inst, &d, &caps, downloaded).to_string())
    }
}
