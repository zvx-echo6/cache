//! Citations: a library point that is a video transcript carries a video (a PeerTube link, a uuid or a short uuid) and a
//! time. `resolve` turns that into what the player opens: the downloaded file when the video is downloaded (works with no
//! network), otherwise a stream address (HLS master playlist, or the MP4 file) from the instance's API.

use crate::api::enc;
use crate::http;
use crate::model;
use crate::store::{self, Instance};
use crate::{Error, Result, Video};
use serde::Deserialize;
use serde_json::{json, Value};

/// PeerTube's short UUIDs: the UUID as a base-58 number (the "flickr" alphabet, no padding).
const ALPHABET: &[u8] = b"123456789abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ";

/// The uuid a short uuid stands for, if `s` is one.
pub fn short_to_uuid(s: &str) -> Option<String> {
    if s.len() < 20 || s.len() > 22 {
        return None;
    }
    let mut acc: u128 = 0;
    for c in s.bytes() {
        let i = ALPHABET.iter().position(|a| *a == c)? as u128;
        acc = acc.checked_mul(58)?.checked_add(i)?;
    }
    let h = format!("{acc:032x}");
    Some(format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32]))
}

/// A uuid stays as it is, a short uuid becomes its uuid, anything else (a numeric id) is returned unchanged.
pub fn uuid_of(s: &str) -> String {
    short_to_uuid(s).unwrap_or_else(|| s.to_string())
}

/// `90`, `90.5`, `1m30s`, `1h2m3s`, `1:02:03` -> seconds.
pub fn parse_time(t: &str) -> Option<f64> {
    let t = t.trim();
    if t.is_empty() {
        return None;
    }
    if let Ok(x) = t.parse::<f64>() {
        return Some(x);
    }
    if t.contains(':') {
        let mut total = 0.0;
        for part in t.split(':') {
            total = total * 60.0 + part.parse::<f64>().ok()?;
        }
        return Some(total);
    }
    let (mut total, mut num) = (0.0, String::new());
    for c in t.chars() {
        match c {
            '0'..='9' | '.' => num.push(c),
            'h' | 'm' | 's' => {
                let n: f64 = num.parse().ok()?;
                num.clear();
                total += n * match c {
                    'h' => 3600.0,
                    'm' => 60.0,
                    _ => 1.0,
                };
            }
            _ => return None,
        }
    }
    if num.is_empty() { Some(total) } else { None }
}

/// A reference to a video: the instance address it came with (if any), its id, and the time in the link (if any).
struct Reference {
    origin: Option<String>,
    id: String,
    start: Option<f64>,
}

fn reference(s: &str) -> Result<Reference> {
    let t = s.trim();
    if t.is_empty() {
        return Err(Error::bad_json("video must not be empty"));
    }
    if !t.contains("://") {
        return Ok(Reference { origin: None, id: store::safe_component(t)?.to_string(), start: None });
    }
    let u = url::Url::parse(t).map_err(|e| Error::bad_json(format!("{t:?} is not a link: {e}")))?;
    let segs: Vec<&str> = u.path_segments().map(|s| s.filter(|x| !x.is_empty()).collect()).unwrap_or_default();
    // /w/<id>, /videos/watch/<id>, /videos/embed/<id>
    let id = match segs.as_slice() {
        ["w", id] | ["videos", "watch", id] | ["videos", "embed", id] => *id,
        _ => return Err(Error::bad_json(format!("{t:?} is not a PeerTube video link (/w/<id> or /videos/watch/<id>)"))),
    };
    let start = u.query_pairs().find(|(k, _)| k == "start" || k == "t").and_then(|(_, v)| parse_time(&v));
    let (_, origin) = store::normalize(&u.origin().ascii_serialization())?;
    Ok(Reference { origin: Some(origin), id: id.to_string(), start })
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ResolveReq {
    /// A video link, uuid or short uuid.
    #[serde(alias = "url", alias = "uuid")]
    video: String,
    /// The instance (its id or address) when `video` is a bare id; the first instance that has the video is used otherwise.
    #[serde(default)]
    instance: Option<String>,
    /// The cited time in seconds; a `start=` or `t=` in the link is used when this is absent.
    #[serde(default, alias = "start", alias = "t", alias = "time")]
    offset_s: Option<f64>,
    #[serde(default)]
    token: Option<String>,
}

impl Video {
    fn local_instance_ids(&self) -> Vec<String> {
        std::fs::read_dir(self.downloads_root()).map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect()).unwrap_or_default()
    }

    /// `{"kind":"local",...}` when the video is downloaded, else `{"kind":"stream",...}`; see `cache_search.h`.
    pub fn resolve(&self, req: &str) -> Result<String> {
        let r: ResolveReq = serde_json::from_str(req).map_err(|e| Error::bad_json(format!("request_json: {e}")))?;
        let rf = reference(&r.video)?;
        let uuid = uuid_of(&rf.id);
        let offset = r.offset_s.or(rf.start).unwrap_or(0.0).max(0.0);
        if !offset.is_finite() {
            return Err(Error::bad_json("offset_s must be a number"));
        }
        // which instances the video can be on
        let mut ids: Vec<String> = vec![];
        if let Some(o) = &rf.origin {
            ids.push(store::normalize(o)?.0);
        } else if let Some(i) = &r.instance {
            ids.push(store::normalize(i).map(|n| n.0).unwrap_or_else(|_| i.clone()));
        }
        // 1. downloaded: no network needed
        let scan = if ids.is_empty() { self.local_instance_ids() } else { ids.clone() };
        for iid in &scan {
            if let Ok(Some(m)) = self.downloaded(iid, &uuid) {
                let dur = m["duration_s"].as_f64().unwrap_or(0.0);
                let off = if dur > 0.0 { offset.min(dur) } else { offset };
                let caps: Vec<Value> = m["captions"].as_array().map(|a| a.iter().map(|c| json!({"language": c["language"], "label": c["label"], "path": c["path"]})).collect()).unwrap_or_default();
                return Ok(json!({
                    "kind": "local",
                    "instance": m["instance"],
                    "uuid": m["uuid"],
                    "title": m["title"],
                    "media": m["kind"],
                    "path": m["path"],
                    "offset_s": off,
                    "duration_s": m["duration_s"],
                    "resolution": m["resolution_label"],
                    "captions": caps,
                    "thumbnail_path": m["thumbnail_path"],
                })
                .to_string());
            }
        }
        // 2. stream: ask the instance (a known one, or the one in the link)
        let known = self.load_instances()?;
        let mut cands: Vec<Instance> = vec![];
        for id in &ids {
            match known.iter().find(|i| &i.id == id) {
                Some(i) => cands.push(i.clone()),
                None => {
                    if let Some(o) = &rf.origin {
                        let (id, url) = store::normalize(o)?;
                        cands.push(Instance { id, url, name: String::new(), version: String::new(), added_at: String::new() });
                    }
                }
            }
        }
        if cands.is_empty() {
            cands = known;
        }
        if cands.is_empty() {
            return Err(Error::not_found("no instance to look the video up on; add one first"));
        }
        let tok = r.token.as_deref().filter(|t| !t.is_empty());
        let mut last: Option<Error> = None;
        for inst in &cands {
            match self.fetch_details(inst, &uuid, tok) {
                Ok(d) => return self.stream_answer(inst, &d, offset, tok),
                Err(e) if e.code == "not_found" => last = Some(e),
                Err(e) => return Err(e),
            }
        }
        Err(last.unwrap_or_else(|| Error::not_found("video not found")))
    }

    fn stream_answer(&self, inst: &Instance, d: &Value, offset: f64, tok: Option<&str>) -> Result<String> {
        if d["isLive"].as_bool().unwrap_or(false) {
            return Err(Error::unsupported("a live stream cannot be opened from a citation"));
        }
        let uuid = d["uuid"].as_str().unwrap_or("");
        let fl = model::files(inst, d);
        let (mut url, format) = match (model::hls_master(d, inst), model::mp4_stream(&fl)) {
            (Some(h), _) => (h, "hls"),
            (None, Some(f)) => (f.url.clone(), "mp4"),
            _ => return Err(Error::unsupported("this video has no playable file yet")),
        };
        let needs_auth = model::needs_auth(d);
        if needs_auth {
            let t = tok.ok_or_else(|| Error::auth_failed("this video needs a login"))?;
            let v = http::post_empty(&format!("{}/api/v1/videos/{}/token", inst.url, enc(uuid)), t, "requesting the file token")?;
            let ft = v["files"]["token"].as_str().ok_or_else(|| Error::bad_response("the instance sent no file token"))?;
            url = format!("{url}{}videoFileToken={}", if url.contains('?') { '&' } else { '?' }, enc(ft));
            if format == "hls" {
                url.push_str("&reinjectVideoFileToken=true");
            }
        }
        let dur = d["duration"].as_f64().unwrap_or(0.0);
        let off = if dur > 0.0 { offset.min(dur) } else { offset };
        Ok(json!({
            "kind": "stream",
            "instance": inst.id,
            "uuid": d["uuid"],
            "title": d["name"],
            "url": url,
            "format": format,
            "offset_s": off,
            "duration_s": d["duration"].as_u64().unwrap_or(0),
            "needs_auth": needs_auth,
            "thumbnail": model::thumb_small(inst, d),
        })
        .to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_uuid_decodes() {
        assert_eq!(short_to_uuid("1TesHJPJ33Jz5TUP7TA7cu").unwrap(), "07273a4b-40a5-433f-a305-1c8f4268fd72");
        assert_eq!(uuid_of("07273a4b-40a5-433f-a305-1c8f4268fd72"), "07273a4b-40a5-433f-a305-1c8f4268fd72");
        assert_eq!(uuid_of("52751"), "52751");
        assert!(short_to_uuid("0OIl0OIl0OIl0OIl0OIl0O").is_none());
    }

    #[test]
    fn times() {
        assert_eq!(parse_time("90"), Some(90.0));
        assert_eq!(parse_time("1m30s"), Some(90.0));
        assert_eq!(parse_time("1h2m3s"), Some(3723.0));
        assert_eq!(parse_time("1:02:03"), Some(3723.0));
        assert_eq!(parse_time("2m"), Some(120.0));
        assert_eq!(parse_time("xx"), None);
        assert_eq!(parse_time("1m5"), None);
    }

    #[test]
    fn links() {
        let r = reference("https://tube.example.org/w/1TesHJPJ33Jz5TUP7TA7cu?start=1m30s").unwrap();
        assert_eq!(r.origin.as_deref(), Some("https://tube.example.org"));
        assert_eq!(r.id, "1TesHJPJ33Jz5TUP7TA7cu");
        assert_eq!(r.start, Some(90.0));
        let r = reference("https://tube.example.org/videos/watch/07273a4b-40a5-433f-a305-1c8f4268fd72?t=12").unwrap();
        assert_eq!(r.start, Some(12.0));
        let r = reference("http://127.0.0.1:8080/w/abc").unwrap();
        assert_eq!(r.origin.as_deref(), Some("http://127.0.0.1:8080"));
        assert!(reference("https://tube.example.org/about").is_err());
        let r = reference("07273a4b-40a5-433f-a305-1c8f4268fd72").unwrap();
        assert!(r.origin.is_none());
    }
}
