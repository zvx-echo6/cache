//! Offline downloads: the `video_download` job (resumable, free-space checked, size and checksum verified), the list of
//! downloaded videos, and delete. A downloaded video is a folder `downloads/<instance>/<uuid>/` with `video.<ext>`,
//! `thumb.<ext>`, `captions-<lang>.vtt` and `manifest.json` (written last: a folder without one is not a download).

use crate::http;
use crate::model::{self, Opt};
use crate::store::{self, Instance};
use crate::{now_iso, Error, Outcome, Result, Video, VideoCfg};
use serde::Deserialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::Duration;

/// Be gentle with instances: at most this many downloads at once from one instance, and this many in all.
pub const MAX_PER_INSTANCE: usize = 2;
pub const MAX_TOTAL: usize = 4;
/// Room kept free beyond the file itself (thumbnail, captions, manifest, the file system's own needs).
const MARGIN: u64 = 16 * 1024 * 1024;
const ATTEMPTS: u32 = 4;

static SLOTS: Mutex<Option<(HashMap<String, usize>, usize)>> = Mutex::new(None);

/// A running-download slot on an instance; released when dropped.
pub struct Slot(String);

impl Drop for Slot {
    fn drop(&mut self) {
        if let Ok(mut g) = SLOTS.lock() {
            if let Some((per, total)) = g.as_mut() {
                if let Some(n) = per.get_mut(&self.0) {
                    *n = n.saturating_sub(1);
                }
                *total = total.saturating_sub(1);
            }
        }
    }
}

/// Wait for a free slot (checking `cancel` while waiting). `None` when cancelled first.
pub fn acquire(instance: &str, cancel: &dyn Fn() -> bool) -> Option<Slot> {
    loop {
        {
            let mut g = SLOTS.lock().ok()?;
            let (per, total) = g.get_or_insert_with(|| (HashMap::new(), 0));
            let n = per.entry(instance.to_string()).or_insert(0);
            if *n < MAX_PER_INSTANCE && *total < MAX_TOTAL {
                *n += 1;
                *total += 1;
                return Some(Slot(instance.to_string()));
            }
        }
        if cancel() {
            return None;
        }
        std::thread::sleep(Duration::from_millis(200));
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DownloadParams {
    /// The `video` folder (the one in the `cs_open` config).
    pub dir: String,
    pub instance: String,
    /// The video's uuid (or short uuid, or numeric id).
    pub video: String,
    /// `"audio"`, `"lowest"`, `"highest"` or a resolution such as `"480"`; default `"lowest"`.
    #[serde(default = "lowest")]
    pub choice: String,
    /// The access token, for videos that need a login.
    #[serde(default)]
    pub token: Option<String>,
    /// Not in the header: a test hook that replaces the free space the system reports, in bytes.
    #[serde(default)]
    pub fake_available_bytes: Option<u64>,
    /// Not in the header: a test hook, the wait before a retry (default 1000 ms, doubled each time).
    #[serde(default)]
    pub retry_delay_ms: Option<u64>,
}

fn lowest() -> String {
    "lowest".into()
}

/// A download whose parameters were checked and whose instance exists; `run` does the work.
pub struct Prepared {
    video: Video,
    inst: Instance,
    p: DownloadParams,
}

pub fn prepare(params_json: &str) -> Result<Prepared> {
    let p: DownloadParams = serde_json::from_str(params_json).map_err(|e| Error::bad_json(format!("params_json: {e}")))?;
    if p.dir.is_empty() || p.video.is_empty() {
        return Err(Error::bad_json("dir and video must not be empty"));
    }
    store::safe_component(&p.video)?;
    let video = Video::new(&VideoCfg { dir: p.dir.clone() });
    let inst = video.instance(&p.instance)?;
    Ok(Prepared { video, inst, p })
}

fn ext_of(url: &str, default: &str, allowed: &[&str]) -> String {
    let path = url.split(['?', '#']).next().unwrap_or("");
    let name = path.rsplit('/').next().unwrap_or("");
    match name.rsplit_once('.') {
        Some((_, e)) if allowed.contains(&e.to_ascii_lowercase().as_str()) => e.to_ascii_lowercase(),
        _ => default.to_string(),
    }
}

fn base_name(url: &str) -> String {
    url.split(['?', '#']).next().unwrap_or("").rsplit('/').next().unwrap_or("").to_string()
}

fn with_query(url: &str, k: &str, v: &str) -> String {
    format!("{url}{}{k}={}", if url.contains('?') { '&' } else { '?' }, crate::api::enc(v))
}

/// Bytes available to an unprivileged writer on the file system that holds `path` (unix: `statvfs`).
#[cfg(unix)]
pub fn available_bytes(path: &Path) -> Result<u64> {
    use std::os::unix::ffi::OsStrExt;
    let c = std::ffi::CString::new(path.as_os_str().as_bytes()).map_err(|_| Error::bad_json("path contains a NUL byte"))?;
    let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: `c` is a valid NUL-terminated path and `st` a valid, writable statvfs.
    let rc = unsafe { libc::statvfs(c.as_ptr(), &mut st) };
    if rc != 0 {
        return Err(Error::io(format!("reading the free space of {}: {}", path.display(), std::io::Error::last_os_error())));
    }
    Ok((st.f_bavail as u64).saturating_mul(st.f_frsize as u64))
}

/// Bytes available to the calling user on the volume that holds `path` (Windows: `GetDiskFreeSpaceExW`).
#[cfg(windows)]
pub fn available_bytes(path: &Path) -> Result<u64> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
    let mut wide: Vec<u16> = path.as_os_str().encode_wide().collect();
    if wide.contains(&0) {
        return Err(Error::bad_json("path contains a NUL byte"));
    }
    wide.push(0);
    let mut free_to_caller: u64 = 0;
    // SAFETY: `wide` is a valid NUL-terminated UTF-16 path and `free_to_caller` a valid, writable u64; the two
    // optional out-pointers are null, which the API allows.
    let ok = unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut free_to_caller, std::ptr::null_mut(), std::ptr::null_mut()) };
    if ok == 0 {
        return Err(Error::io(format!("reading the free space of {}: {}", path.display(), std::io::Error::last_os_error())));
    }
    Ok(free_to_caller)
}

#[cfg(not(any(unix, windows)))]
pub fn available_bytes(path: &Path) -> Result<u64> {
    Err(Error::io(format!("reading the free space of {}: not supported on this platform", path.display())))
}

fn sha256_file(p: &Path) -> Result<String> {
    let mut f = std::fs::File::open(p).map_err(|e| Error::io(format!("reading {}: {e}", p.display())))?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 256 * 1024];
    loop {
        let n = f.read(&mut buf).map_err(|e| Error::io(format!("reading {}: {e}", p.display())))?;
        if n == 0 {
            break;
        }
        h.update(&buf[..n]);
    }
    Ok(h.finalize().iter().map(|b| format!("{b:02x}")).collect())
}

/// What `fetch_file` ended as.
enum Fetched {
    Done,
    Cancelled,
}

/// Download `url` into `part`, continuing from what is already there when the server honours `Range`. `expected` is the
/// size the instance announced (None when it is unknown, as for a joined audio+video file, which is also not resumable).
/// Network trouble is retried (with the data kept); a cancel stops at once and keeps the data for a later resume.
fn fetch_file(url: &str, part: &Path, expected: Option<u64>, resumable: bool, retry_ms: u64, progress: &dyn Fn(u64), cancel: &dyn Fn() -> bool) -> Result<Fetched> {
    let mut attempt = 0u32;
    let mut restarted_full = false;
    loop {
        if cancel() {
            return Ok(Fetched::Cancelled);
        }
        let mut have = std::fs::metadata(part).map(|m| m.len()).unwrap_or(0);
        if !resumable || expected.map_or(false, |e| have > e) {
            have = 0;
        }
        if expected == Some(have) && have > 0 {
            progress(have);
            return Ok(Fetched::Done);
        }
        let step: Result<Fetched> = (|| {
            let resp = http::get_file(url, have)?;
            let mut offset = have;
            match resp.status {
                206 if resp.range_start == Some(have) => {}
                206 => return Err(Error::fetch_failed("the instance answered with the wrong part of the file")),
                200 => offset = 0, // no range support (or a fresh start): the whole file comes
                416 => {
                    // nothing past `have`: the file is already complete, or the data on disk does not belong to it
                    if resp.total == Some(have) {
                        return Ok(Fetched::Done);
                    }
                    let _ = std::fs::remove_file(part);
                    return Err(Error::fetch_failed("the partial file does not match the instance's file; starting again"));
                }
                other => return Err(Error::fetch_failed(format!("download: HTTP {other}"))),
            }
            let mut f = if offset == 0 {
                std::fs::File::create(part).map_err(|e| Error::io(format!("creating {}: {e}", part.display())))?
            } else {
                std::fs::OpenOptions::new().append(true).open(part).map_err(|e| Error::io(format!("opening {}: {e}", part.display())))?
            };
            let announced = resp.content_length;
            let mut body = resp.body;
            let mut buf = vec![0u8; 64 * 1024];
            let mut done = offset;
            progress(done);
            loop {
                if cancel() {
                    let _ = f.flush();
                    return Ok(Fetched::Cancelled);
                }
                let n = body.read(&mut buf).map_err(|e| Error::fetch_failed(format!("download interrupted: {e}")))?;
                if n == 0 {
                    break;
                }
                f.write_all(&buf[..n]).map_err(|e| {
                    if e.kind() == std::io::ErrorKind::StorageFull { Error::no_space("the disk is full", 0, 0) } else { Error::io(format!("writing {}: {e}", part.display())) }
                })?;
                done += n as u64;
                progress(done);
            }
            f.flush().map_err(|e| Error::io(format!("writing {}: {e}", part.display())))?;
            drop(f);
            if let Some(e) = expected {
                if done < e {
                    return Err(Error::fetch_failed(format!("download interrupted at {done} of {e} bytes")));
                }
            }
            // a body that ended before the length the instance announced was cut off (this also covers a joined
            // audio+video file, whose total size is not known in advance)
            if let Some(cl) = announced {
                if done - offset < cl {
                    return Err(Error::fetch_failed(format!("download interrupted after {} of {cl} bytes", done - offset)));
                }
            }
            Ok(Fetched::Done)
        })();
        match step {
            Ok(r) => return Ok(r),
            Err(e) if e.code == "fetch_failed" && attempt + 1 < ATTEMPTS => {
                attempt += 1;
                // a 416 mismatch removed the data: that restart is not a failed attempt
                if !part.exists() && !restarted_full {
                    restarted_full = true;
                    attempt -= 1;
                    continue;
                }
                let wait = Duration::from_millis(retry_ms.saturating_mul(1 << (attempt - 1)));
                let t0 = std::time::Instant::now();
                while t0.elapsed() < wait {
                    if cancel() {
                        return Ok(Fetched::Cancelled);
                    }
                    std::thread::sleep(Duration::from_millis(25).min(wait));
                }
            }
            Err(e) => return Err(e),
        }
    }
}

#[derive(Deserialize, serde::Serialize, PartialEq)]
struct PartMeta {
    key: String,
    file: String,
    size: u64,
}

impl Prepared {
    /// The file URL for an option, with a file token when the video needs a login.
    fn url_for(&self, o: &Opt, uuid: &str, ftoken: Option<&str>) -> String {
        let u = if o.source == "hls+audio" {
            let ids: Vec<String> = o.files.iter().map(|f| format!("videoFileIds={}", f.id)).collect();
            format!("{}/download/videos/generate/{}?{}", self.inst.url, crate::api::enc(uuid), ids.join("&"))
        } else {
            o.files[0].url.clone()
        };
        match ftoken {
            Some(t) => with_query(&u, "videoFileToken", t),
            None => u,
        }
    }

    pub fn run(&self, progress: &dyn Fn(u64, u64), cancel: &dyn Fn() -> bool) -> Result<Outcome> {
        let p = &self.p;
        let tok = p.token.as_deref().filter(|t| !t.is_empty());
        if cancel() {
            return Ok(Outcome::Cancelled);
        }
        let d = self.video.fetch_details(&self.inst, &p.video, tok)?;
        let uuid = d["uuid"].as_str().ok_or_else(|| Error::bad_response("the video has no uuid"))?.to_string();
        if d["isLive"].as_bool().unwrap_or(false) {
            return Err(Error::unsupported("a live stream cannot be downloaded"));
        }
        if !d["downloadEnabled"].as_bool().unwrap_or(false) {
            return Err(Error::unsupported(format!("{} has turned downloads off for this video; it can only be streamed", self.inst.name)));
        }
        let opts = model::options(&model::files(&self.inst, &d));
        let o = model::pick(&opts, &p.choice).ok_or_else(|| {
            if p.choice.eq_ignore_ascii_case("audio") {
                Error::unsupported("this video has no audio-only file; pick a resolution")
            } else if opts.is_empty() {
                Error::unsupported("this video has no downloadable file yet (it may still be processing)")
            } else {
                Error::bad_json(format!("choice {:?} is not \"audio\", \"lowest\", \"highest\" or a resolution", p.choice))
            }
        })?;
        let ftoken = if model::needs_auth(&d) {
            let t = tok.ok_or_else(|| Error::auth_failed("this video needs a login"))?;
            let v = http::post_empty(&format!("{}/api/v1/videos/{}/token", self.inst.url, crate::api::enc(&uuid)), t, "requesting the file token")?;
            Some(v["files"]["token"].as_str().ok_or_else(|| Error::bad_response("the instance sent no file token"))?.to_string())
        } else {
            None
        };
        let resumable = o.source != "hls+audio";
        let url = self.url_for(o, &uuid, ftoken.as_deref());
        let expected = if resumable && o.size > 0 { Some(o.size) } else { None };
        let total = if o.size > 0 { o.size } else { 0 };
        let ext = ext_of(&o.files[0].url, "mp4", &["mp4", "m4a", "m4v", "webm", "mkv", "mp3", "ogg", "opus", "aac"]);
        let final_name = format!("video.{ext}");

        let Some(_slot) = acquire(&self.inst.id, cancel) else { return Ok(Outcome::Cancelled) };

        let dest = self.video.video_dir(&self.inst.id, &uuid)?;
        std::fs::create_dir_all(&dest).map_err(|e| Error::io(format!("creating {}: {e}", dest.display())))?;
        let part = dest.join("video.part");
        let meta_path = dest.join("video.part.json");
        let want_meta = PartMeta { key: o.key.clone(), file: base_name(&o.files[0].url), size: o.size };
        let have_meta: Option<PartMeta> = std::fs::read_to_string(&meta_path).ok().and_then(|t| serde_json::from_str(&t).ok());
        if have_meta.as_ref() != Some(&want_meta) {
            // data from another file (another resolution, or a file the instance replaced) is not continued
            let _ = std::fs::remove_file(&part);
        }
        store::write_atomic(&meta_path, serde_json::to_string(&want_meta).unwrap_or_default().as_bytes())?;
        let have = std::fs::metadata(&part).map(|m| m.len()).unwrap_or(0).min(o.size);
        let needed = o.size.saturating_sub(have).saturating_add(MARGIN);
        let available = match p.fake_available_bytes {
            Some(n) => n,
            None => available_bytes(&dest)?,
        };
        if needed > available {
            // nothing was downloaded: leave no empty folder behind
            if !part.exists() {
                let _ = std::fs::remove_file(&meta_path);
                let _ = std::fs::remove_dir(&dest);
            }
            return Err(Error::no_space(
                format!("not enough free space for {}: {needed} bytes needed (file {} + {MARGIN} margin), {available} available", o.label, o.size),
                needed,
                available,
            ));
        }

        progress(have, total);
        let report = |done: u64| progress(done, total.max(done));
        match fetch_file(&url, &part, expected, resumable, p.retry_delay_ms.unwrap_or(1000), &report, cancel)? {
            Fetched::Cancelled => return Ok(Outcome::Cancelled),
            Fetched::Done => {}
        }
        let size = std::fs::metadata(&part).map_err(|e| Error::io(format!("reading {}: {e}", part.display())))?.len();
        if let Some(e) = expected {
            if size != e {
                let _ = std::fs::remove_file(&part);
                return Err(Error::new("damaged", format!("the downloaded file is {size} bytes but the instance says {e}; deleted, try again")));
            }
        }
        if size == 0 {
            let _ = std::fs::remove_file(&part);
            return Err(Error::new("damaged", "the instance sent an empty file"));
        }
        let sha = sha256_file(&part)?;
        // PeerTube's API gives no checksum for web videos; for HLS files the playlist's segments-sha256 list may name the file.
        let mut verified: Option<&str> = None;
        if let Some(su) = o.files[0].sha_url.as_ref().filter(|_| resumable) {
            if let Ok(b) = http::get_bytes(su, 16 * 1024 * 1024, "reading the checksum list") {
                if let Ok(m) = serde_json::from_slice::<Value>(&b) {
                    if let Some(want) = m[base_name(&o.files[0].url)].as_str() {
                        if want.eq_ignore_ascii_case(&sha) {
                            verified = Some("playlist");
                        } else {
                            let _ = std::fs::remove_file(&part);
                            return Err(Error::new("damaged", "the downloaded file does not match the checksum the instance publishes; deleted, try again"));
                        }
                    }
                }
            }
        }
        // the file is complete: it replaces any earlier download of this video
        if let Ok(rd) = std::fs::read_dir(&dest) {
            for e in rd.flatten() {
                let n = e.file_name().to_string_lossy().into_owned();
                if (n.starts_with("video.") && n != final_name && n != "video.part" && n != "video.part.json") || n.starts_with("thumb.") || n.starts_with("captions-") || n == "manifest.json" {
                    let _ = std::fs::remove_file(e.path());
                }
            }
        }
        std::fs::rename(&part, dest.join(&final_name)).map_err(|e| Error::io(format!("renaming the download: {e}")))?;
        let _ = std::fs::remove_file(&meta_path);

        let mut warnings: Vec<String> = vec![];
        // the large image first, the small one if the instance does not have the large one
        let mut thumb: Option<String> = None;
        for u in [model::thumb_large(&self.inst, &d), model::thumb_small(&self.inst, &d)].into_iter().flatten() {
            let name = format!("thumb.{}", ext_of(&u, "jpg", &["jpg", "jpeg", "png", "webp"]));
            match http::get_bytes(&u, 10 * 1024 * 1024, "thumbnail") {
                Ok(b) => match std::fs::write(dest.join(&name), b) {
                    Ok(_) => {
                        thumb = Some(name);
                        break;
                    }
                    Err(e) => warnings.push(format!("thumbnail not saved: {e}")),
                },
                Err(e) => warnings.push(format!("thumbnail not saved: {}", e.message)),
            }
        }
        if thumb.is_some() {
            warnings.clear();
        }
        let mut caps: Vec<Value> = vec![];
        for c in self.video.fetch_captions(&self.inst, &uuid, tok) {
            let lang: String = c["language"].as_str().unwrap_or("und").chars().filter(|ch| ch.is_ascii_alphanumeric() || *ch == '-' || *ch == '_').collect();
            let name = format!("captions-{lang}.vtt");
            match http::get_bytes(c["url"].as_str().unwrap_or(""), 5 * 1024 * 1024, "caption") {
                Ok(b) => match std::fs::write(dest.join(&name), b) {
                    Ok(_) => caps.push(json!({"language": c["language"], "label": c["label"], "automatic": c["automatic"], "file": name})),
                    Err(e) => warnings.push(format!("caption {lang} not saved: {e}")),
                },
                Err(e) => warnings.push(format!("caption {lang} not saved: {}", e.message)),
            }
        }
        let manifest = json!({
            "version": 1,
            "instance": self.inst.id,
            "instance_url": self.inst.url,
            "id": d["id"],
            "uuid": uuid,
            "short_uuid": d["shortUUID"],
            "title": d["name"],
            "description": d["description"],
            "channel": model::actor(&self.inst, &d["channel"]),
            "duration_s": d["duration"].as_u64().unwrap_or(0),
            "published_at": d["publishedAt"],
            "kind": if o.audio { "audio" } else { "video" },
            "resolution": o.key,
            "resolution_label": o.label,
            "source": o.source,
            "size": size,
            "sha256": sha,
            "checksum_verified": verified,
            "file": final_name,
            "thumbnail": thumb,
            "captions": caps,
            "warnings": warnings,
            "downloaded_at": now_iso(),
        });
        store::write_atomic(&dest.join("manifest.json"), manifest.to_string().as_bytes())?;
        progress(size, size.max(total));
        Ok(Outcome::Done)
    }
}

/// Run a `video_download` job's parameters to the end (used by the CLI-free tests; the job runner calls the two steps).
pub fn run_job(params_json: &str, progress: &dyn Fn(u64, u64), cancel: &dyn Fn() -> bool) -> Result<Outcome> {
    prepare(params_json)?.run(progress, cancel)
}

fn abs_manifest(dir: &Path, m: &Value) -> Value {
    let mut m = m.clone();
    let p = |name: &Value| name.as_str().map(|n| dir.join(n).to_string_lossy().into_owned());
    m["dir"] = json!(dir.to_string_lossy());
    m["path"] = json!(p(&m["file"]));
    m["thumbnail_path"] = json!(p(&m["thumbnail"]));
    if let Some(a) = m["captions"].as_array_mut() {
        for c in a {
            c["path"] = json!(p(&c["file"]));
        }
    }
    m
}

impl Video {
    /// The absolute-path form of a downloaded video's manifest (what the player and the library link need).
    pub fn downloaded(&self, instance_id: &str, uuid: &str) -> Result<Option<Value>> {
        let dir = self.video_dir(instance_id, uuid)?;
        Ok(self.manifest(instance_id, uuid)?.filter(|m| m["file"].as_str().map_or(false, |f| dir.join(f).is_file())).map(|m| abs_manifest(&dir, &m)))
    }

    /// Every downloaded video (newest first) and the bytes they take.
    pub fn downloads_json(&self) -> Result<String> {
        let mut list: Vec<Value> = vec![];
        if let Ok(insts) = std::fs::read_dir(self.downloads_root()) {
            for i in insts.flatten() {
                if let Ok(vids) = std::fs::read_dir(i.path()) {
                    for v in vids.flatten() {
                        let (iid, uuid) = (i.file_name().to_string_lossy().into_owned(), v.file_name().to_string_lossy().into_owned());
                        if let Ok(Some(m)) = self.downloaded(&iid, &uuid) {
                            list.push(m);
                        }
                    }
                }
            }
        }
        list.sort_by(|a, b| b["downloaded_at"].as_str().cmp(&a["downloaded_at"].as_str()).then(a["uuid"].as_str().cmp(&b["uuid"].as_str())));
        let bytes: u64 = list.iter().map(|m| store::dir_size(Path::new(m["dir"].as_str().unwrap_or("")))).sum();
        Ok(json!({"downloads": list, "total_bytes": bytes}).to_string())
    }

    /// Delete a downloaded video (all its files, and a half-finished download of it).
    pub fn delete_download(&self, req: &str) -> Result<String> {
        #[derive(Deserialize)]
        #[serde(deny_unknown_fields)]
        struct R {
            instance: String,
            video: String,
        }
        let r: R = serde_json::from_str(req).map_err(|e| Error::bad_json(format!("request_json: {e}")))?;
        let uuid = crate::resolve::uuid_of(&r.video);
        let iid = store::normalize(&r.instance).map(|n| n.0).unwrap_or(r.instance.clone());
        let dir: PathBuf = self.video_dir(&iid, &uuid)?;
        if !dir.is_dir() {
            return Err(Error::not_found(format!("no downloaded video {} on {iid}", r.video)));
        }
        let freed = store::dir_size(&dir);
        std::fs::remove_dir_all(&dir).map_err(|e| Error::io(format!("deleting {}: {e}", dir.display())))?;
        Ok(json!({"deleted": uuid, "instance": iid, "freed_bytes": freed}).to_string())
    }
}
