//! PeerTube's JSON turned into what Cache shows and uses: summaries, details, the download options (one per resolution
//! plus audio only, with sizes) and the file choice. Pure functions over `serde_json::Value`, tested with recorded responses.

use crate::store::Instance;
use serde_json::{json, Value};

/// Join a path or URL from the API onto the instance origin.
pub fn abs(base: &str, p: &str) -> String {
    if p.starts_with("http://") || p.starts_with("https://") {
        p.to_string()
    } else {
        format!("{}/{}", base.trim_end_matches('/'), p.trim_start_matches('/'))
    }
}

fn s(v: &Value) -> Option<String> {
    v.as_str().filter(|x| !x.is_empty()).map(str::to_string)
}

/// A channel or account object as Cache shows it. `handle` is what the channel endpoints take: the name on this
/// instance, `name@host` for a remote channel.
pub fn actor(inst: &Instance, v: &Value) -> Value {
    let name = v["name"].as_str().unwrap_or("");
    let host = v["host"].as_str().unwrap_or("");
    let local_host = inst.id.replace('_', ":");
    let handle = if host.is_empty() || host == local_host { name.to_string() } else { format!("{name}@{host}") };
    let avatar = v["avatars"].as_array().and_then(|a| a.iter().max_by_key(|x| x["width"].as_u64().unwrap_or(0))).and_then(|a| s(&a["fileUrl"]).or_else(|| s(&a["path"]))).map(|p| abs(&inst.url, &p));
    json!({
        "name": name,
        "display_name": s(&v["displayName"]).unwrap_or_else(|| name.to_string()),
        "handle": handle,
        "host": host,
        "avatar": avatar,
    })
}

/// A small thumbnail for lists (`thumbnailPath` on every version, `thumbnails` from 8.1).
pub fn thumb_small(inst: &Instance, v: &Value) -> Option<String> {
    if let Some(p) = s(&v["thumbnailPath"]) {
        return Some(abs(&inst.url, &p));
    }
    let t = v["thumbnails"].as_array()?;
    let pick = t.iter().min_by_key(|x| x["width"].as_u64().unwrap_or(u64::MAX))?;
    s(&pick["fileUrl"]).map(|p| abs(&inst.url, &p))
}

/// A large image for the video page.
pub fn thumb_large(inst: &Instance, v: &Value) -> Option<String> {
    if let Some(t) = v["thumbnails"].as_array() {
        if let Some(pick) = t.iter().max_by_key(|x| x["width"].as_u64().unwrap_or(0)) {
            if let Some(u) = s(&pick["fileUrl"]) {
                return Some(abs(&inst.url, &u));
            }
        }
    }
    s(&v["previewPath"]).or_else(|| s(&v["thumbnailPath"])).map(|p| abs(&inst.url, &p))
}

/// One row of a video list (browse, search, a channel).
pub fn summary(inst: &Instance, v: &Value, downloaded: bool) -> Value {
    json!({
        "uuid": v["uuid"],
        "short_uuid": v["shortUUID"],
        "id": v["id"],
        "title": v["name"],
        "duration_s": v["duration"].as_u64().unwrap_or(0),
        "published_at": v["publishedAt"],
        "views": v["views"].as_u64().unwrap_or(0),
        "channel": actor(inst, &v["channel"]),
        "thumbnail": thumb_small(inst, v),
        "nsfw": v["nsfw"].as_bool().unwrap_or(false),
        "is_live": v["isLive"].as_bool().unwrap_or(false),
        "downloaded": downloaded,
    })
}

/// One file of a video, from `files` (web video) or `streamingPlaylists[].files` (HLS, fragmented MP4).
#[derive(Debug, Clone, PartialEq)]
pub struct FileInfo {
    pub id: i64,
    /// PeerTube's resolution id (the height, or the shorter side for vertical video); 0 for audio only.
    pub res: i64,
    pub label: String,
    pub size: u64,
    pub fps: Option<f64>,
    pub has_audio: bool,
    pub has_video: bool,
    pub url: String,
    pub hls: bool,
    /// The HLS playlist's `segmentsSha256Url`, when the file belongs to one.
    pub sha_url: Option<String>,
}

impl FileInfo {
    pub fn audio_only(&self) -> bool {
        !self.has_video || self.res == 0
    }
}

fn file_of(inst: &Instance, f: &Value, hls: bool, sha_url: Option<String>) -> Option<FileInfo> {
    let url = s(&f["fileUrl"]).or_else(|| s(&f["fileDownloadUrl"]))?;
    let res = f["resolution"]["id"].as_i64().unwrap_or(0);
    // PeerTube < 6.2 has no hasAudio/hasVideo: such a file is a normal video with sound (or audio only when resolution 0)
    let has_video = f["hasVideo"].as_bool().unwrap_or(res != 0);
    let has_audio = f["hasAudio"].as_bool().unwrap_or(true);
    Some(FileInfo {
        id: f["id"].as_i64().unwrap_or(-1),
        res,
        label: s(&f["resolution"]["label"]).unwrap_or_else(|| if res == 0 { "Audio".into() } else { format!("{res}p") }),
        size: f["size"].as_u64().unwrap_or(0),
        fps: f["fps"].as_f64().filter(|x| *x > 0.0),
        has_audio,
        has_video,
        url: abs(&inst.url, &url),
        hls,
        sha_url,
    })
}

/// All files of a video details response: web video files first, then HLS files.
pub fn files(inst: &Instance, d: &Value) -> Vec<FileInfo> {
    let mut out = vec![];
    for f in d["files"].as_array().into_iter().flatten() {
        out.extend(file_of(inst, f, false, None));
    }
    for sp in d["streamingPlaylists"].as_array().into_iter().flatten() {
        let sha = s(&sp["segmentsSha256Url"]).map(|u| abs(&inst.url, &u));
        for f in sp["files"].as_array().into_iter().flatten() {
            out.extend(file_of(inst, f, true, sha.clone()));
        }
    }
    out
}

/// A choice shown to the user: one resolution, or audio only.
#[derive(Debug, Clone, PartialEq)]
pub struct Opt {
    /// `"audio"` or the resolution id as text (`"480"`).
    pub key: String,
    pub label: String,
    pub audio: bool,
    pub res: i64,
    /// Bytes (a muxed pair is the sum, approximate); 0 when the instance did not say.
    pub size: u64,
    /// `web` (plain MP4), `hls` (the HLS playlist's fragmented MP4 file) or `hls+audio` (a video-only HLS file plus the
    /// audio-only file, joined by the instance's `/download/videos/generate` endpoint).
    pub source: &'static str,
    pub files: Vec<FileInfo>,
}

/// The download options of a video, in the order shown: resolutions from high to low, then audio only.
///
/// The file choice for a resolution: a web-video MP4 first (one plain file, resumable, plays everywhere); else the HLS
/// playlist's fragmented MP4 of that resolution when it has sound; else (instances that keep audio in a separate file)
/// the video-only HLS file together with the audio-only file, muxed by the instance. Audio only: the audio-only web
/// file, else the audio-only HLS file; a video without one has no "audio only" option.
pub fn options(files: &[FileInfo]) -> Vec<Opt> {
    let mut res: Vec<i64> = files.iter().filter(|f| !f.audio_only()).map(|f| f.res).collect();
    res.sort_unstable_by(|a, b| b.cmp(a));
    res.dedup();
    let audio_file = |hls: Option<bool>| files.iter().filter(|f| f.audio_only() && f.has_audio && hls.map_or(true, |h| f.hls == h)).min_by_key(|f| f.size).cloned();
    let mut out = vec![];
    for r in res {
        let of_res: Vec<&FileInfo> = files.iter().filter(|f| f.res == r && !f.audio_only()).collect();
        let web = of_res.iter().find(|f| !f.hls && f.has_audio);
        let hls = of_res.iter().find(|f| f.hls && f.has_audio);
        let (source, chosen): (&'static str, Vec<FileInfo>) = if let Some(f) = web {
            ("web", vec![(*f).clone()])
        } else if let Some(f) = hls {
            ("hls", vec![(*f).clone()])
        } else if let (Some(v), Some(a)) = (of_res.iter().find(|f| f.hls), audio_file(Some(true)).or_else(|| audio_file(None))) {
            ("hls+audio", vec![(*v).clone(), a])
        } else {
            continue;
        };
        let size = chosen.iter().map(|f| f.size).sum();
        let label = chosen[0].label.clone();
        out.push(Opt { key: r.to_string(), label, audio: false, res: r, size, source, files: chosen });
    }
    let a = audio_file(Some(false)).or_else(|| audio_file(Some(true)));
    if let Some(f) = a {
        out.push(Opt { key: "audio".into(), label: "Audio only".into(), audio: true, res: 0, size: f.size, source: if f.hls { "hls" } else { "web" }, files: vec![f] });
    }
    out
}

/// Pick the option for a choice: `"audio"`, `"lowest"`, `"highest"`, or a resolution (`"480"`; when the video has no
/// such resolution, the nearest one below it, else the nearest above).
pub fn pick<'a>(opts: &'a [Opt], choice: &str) -> Option<&'a Opt> {
    let video = || opts.iter().filter(|o| !o.audio);
    match choice.trim().to_ascii_lowercase().as_str() {
        "audio" => opts.iter().find(|o| o.audio),
        "lowest" => video().min_by_key(|o| o.res),
        "highest" => video().max_by_key(|o| o.res),
        other => {
            let want: i64 = other.trim_end_matches('p').parse().ok()?;
            video().find(|o| o.res == want).or_else(|| video().filter(|o| o.res < want).max_by_key(|o| o.res)).or_else(|| video().filter(|o| o.res > want).min_by_key(|o| o.res))
        }
    }
}

/// The URL a plain MP4 can be streamed from: the highest resolution up to 720 that has sound, else the lowest.
pub fn mp4_stream(files: &[FileInfo]) -> Option<&FileInfo> {
    let web: Vec<&FileInfo> = files.iter().filter(|f| !f.hls && f.has_audio && !f.audio_only()).collect();
    web.iter().filter(|f| f.res <= 720).max_by_key(|f| f.res).or_else(|| web.iter().min_by_key(|f| f.res)).copied()
}

pub fn hls_master(d: &Value, inst: &Instance) -> Option<String> {
    d["streamingPlaylists"].as_array()?.iter().find_map(|sp| s(&sp["playlistUrl"])).map(|u| abs(&inst.url, &u))
}

/// A private or internal video's files need a file token (PeerTube: privacy 3 private, 4 password protected, 5 internal).
pub fn needs_auth(d: &Value) -> bool {
    !matches!(d["privacy"]["id"].as_i64(), Some(1) | Some(2) | None)
}

pub fn option_json(o: &Opt) -> Value {
    json!({
        "key": o.key,
        "label": o.label,
        "kind": if o.audio { "audio" } else { "video" },
        "size": if o.size > 0 { json!(o.size) } else { Value::Null },
        "source": o.source,
    })
}

/// The video page: details, captions, download options, stream addresses.
pub fn details(inst: &Instance, d: &Value, captions: &[Value], downloaded: Option<Value>) -> Value {
    let fl = files(inst, d);
    let opts = options(&fl);
    let download_enabled = d["downloadEnabled"].as_bool().unwrap_or(false);
    let is_live = d["isLive"].as_bool().unwrap_or(false);
    let desc = s(&d["description"]).or_else(|| s(&d["truncatedDescription"]));
    json!({
        "instance": inst.id,
        "uuid": d["uuid"],
        "short_uuid": d["shortUUID"],
        "id": d["id"],
        "title": d["name"],
        "description": desc,
        "duration_s": d["duration"].as_u64().unwrap_or(0),
        "published_at": d["publishedAt"],
        "views": d["views"].as_u64().unwrap_or(0),
        "privacy": d["privacy"]["label"],
        "is_live": is_live,
        "nsfw": d["nsfw"].as_bool().unwrap_or(false),
        "tags": d["tags"],
        "channel": actor(inst, &d["channel"]),
        "thumbnail": thumb_small(inst, d),
        "preview": thumb_large(inst, d),
        "download_enabled": download_enabled,
        "captions": captions,
        "options": opts.iter().map(option_json).collect::<Vec<_>>(),
        "stream": {
            "hls": hls_master(d, inst),
            "mp4": mp4_stream(&fl).map(|f| f.url.clone()),
            "needs_auth": needs_auth(d),
        },
        "downloaded": downloaded,
    })
}

/// A caption as listed from `/videos/{id}/captions`.
pub fn caption(inst: &Instance, c: &Value) -> Option<Value> {
    let url = s(&c["fileUrl"]).or_else(|| s(&c["captionPath"]))?;
    Some(json!({
        "language": c["language"]["id"],
        "label": c["language"]["label"],
        "automatic": c["automaticallyGenerated"].as_bool().unwrap_or(false),
        "url": abs(&inst.url, &url),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn inst() -> Instance {
        Instance { id: "example.org".into(), url: "https://example.org".into(), name: "x".into(), version: "8".into(), added_at: String::new() }
    }

    fn f(id: i64, res: i64, size: u64, hls: bool, audio: bool, video: bool) -> FileInfo {
        FileInfo { id, res, label: format!("{res}p"), size, fps: None, has_audio: audio, has_video: video, url: format!("https://example.org/f/{id}"), hls, sha_url: None }
    }

    #[test]
    fn web_mp4_wins_over_hls() {
        let fl = vec![f(1, 480, 100, true, true, true), f(2, 480, 90, false, true, true), f(3, 240, 40, true, true, true)];
        let o = options(&fl);
        assert_eq!(o.iter().map(|x| (x.key.as_str(), x.source)).collect::<Vec<_>>(), vec![("480", "web"), ("240", "hls")]);
        assert_eq!(o[0].size, 90);
    }

    #[test]
    fn separate_audio_is_muxed_and_audio_only_is_offered() {
        let fl = vec![f(1, 720, 500, true, false, true), f(2, 360, 200, true, false, true), f(3, 0, 50, true, true, false)];
        let o = options(&fl);
        assert_eq!(o.iter().map(|x| (x.key.as_str(), x.source, x.size)).collect::<Vec<_>>(), vec![("720", "hls+audio", 550), ("360", "hls+audio", 250), ("audio", "hls", 50)]);
        assert_eq!(o[0].files.iter().map(|x| x.id).collect::<Vec<_>>(), vec![1, 3]);
    }

    #[test]
    fn video_only_without_any_audio_file_is_left_out() {
        assert!(options(&[f(1, 720, 500, true, false, true)]).is_empty());
    }

    #[test]
    fn old_instances_without_flags_still_work() {
        let d = json!({"files":[{"id":1,"resolution":{"id":360,"label":"360p"},"size":10,"fileUrl":"/static/a.mp4"}]});
        let fl = files(&inst(), &d);
        assert!(fl[0].has_audio && fl[0].has_video);
        assert_eq!(fl[0].url, "https://example.org/static/a.mp4");
        assert_eq!(options(&fl).len(), 1);
    }

    #[test]
    fn choices() {
        let fl = vec![f(1, 1080, 9, false, true, true), f(2, 480, 5, false, true, true), f(3, 240, 2, false, true, true), f(4, 0, 1, false, true, false)];
        let o = options(&fl);
        assert_eq!(pick(&o, "lowest").unwrap().key, "240");
        assert_eq!(pick(&o, "highest").unwrap().key, "1080");
        assert_eq!(pick(&o, "480").unwrap().key, "480");
        assert_eq!(pick(&o, "720p").unwrap().key, "480");
        assert_eq!(pick(&o, "144").unwrap().key, "240");
        assert_eq!(pick(&o, "audio").unwrap().key, "audio");
        assert!(pick(&o, "banana").is_none());
        assert!(pick(&o[..3], "audio").is_none());
    }

    #[test]
    fn stream_mp4_prefers_720_or_below() {
        let fl = vec![f(1, 1080, 9, false, true, true), f(2, 480, 5, false, true, true)];
        assert_eq!(mp4_stream(&fl).unwrap().id, 2);
        assert_eq!(mp4_stream(&fl[..1]).unwrap().id, 1);
    }

    #[test]
    fn handles() {
        let i = inst();
        assert_eq!(actor(&i, &json!({"name":"a","host":"example.org"}))["handle"], "a");
        assert_eq!(actor(&i, &json!({"name":"a","host":"other.net"}))["handle"], "a@other.net");
    }

    #[test]
    fn privacy() {
        assert!(!needs_auth(&json!({"privacy":{"id":1}})));
        assert!(!needs_auth(&json!({"privacy":{"id":2}})));
        assert!(needs_auth(&json!({"privacy":{"id":3}})));
    }
}
