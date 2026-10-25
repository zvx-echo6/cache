//! The video connector against a stand-in PeerTube serving recorded responses (hostname example.org in the fixtures).

mod common;

use cache_video::{dl, Outcome, Video, VideoCfg};
use common::*;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

struct Tmp(PathBuf);
impl Tmp {
    fn new(name: &str) -> Tmp {
        let p = std::env::temp_dir().join(format!("cv-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        Tmp(p)
    }
    fn s(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }
}
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn setup(name: &str) -> (Tmp, Mock, Video, String) {
    let t = Tmp::new(name);
    let m = Mock::start();
    let v = Video::new(&VideoCfg { dir: t.s() });
    let added: Value = serde_json::from_str(&v.instance_add(&json!({"url": m.url()}).to_string()).unwrap()).unwrap();
    let id = added["id"].as_str().unwrap().to_string();
    (t, m, v, id)
}

fn j(r: cache_video::Result<String>) -> Value {
    serde_json::from_str(&r.unwrap()).unwrap()
}

fn job(v: &Video, t: &Tmp, inst: &str, video: &str, choice: &str, extra: Value) -> cache_video::Result<Outcome> {
    let mut p = json!({"dir": t.s(), "instance": inst, "video": video, "choice": choice, "retry_delay_ms": 10});
    for (k, x) in extra.as_object().unwrap() {
        p[k] = x.clone();
    }
    let _ = v;
    dl::run_job(&p.to_string(), &|_, _| {}, &|| false)
}

#[test]
fn instances_are_added_listed_and_removed() {
    let t = Tmp::new("inst");
    let m = Mock::start();
    let v = Video::new(&VideoCfg { dir: t.s() });
    assert_eq!(j(v.instances_json()), json!({"instances": []}));
    let a = j(v.instance_add(&json!({"url": m.url()}).to_string()));
    assert_eq!(a["name"], "Example PeerTube");
    assert_eq!(a["id"], m.id());
    assert!(a["version"].as_str().unwrap().starts_with('8'));
    // adding it again changes nothing
    let b = j(v.instance_add(&json!({"url": format!("{}/", m.url())}).to_string()));
    assert_eq!(a, b);
    assert_eq!(j(v.instances_json())["instances"].as_array().unwrap().len(), 1);
    // the user agent is Cache/<version>, not a person (the stand-in refuses any other)
    assert!(m.hits_for("/api/v1/config").iter().all(|h| h.header("User-Agent").unwrap().starts_with("Cache/")));
    // not PeerTube / not https / not an address
    assert_eq!(v.instance_add(r#"{"url":"http://example.org"}"#).unwrap_err().code, "bad_json");
    assert_eq!(v.instance_add(r#"{"url":""}"#).unwrap_err().code, "bad_json");
    assert_eq!(v.instance_add(r#"{"url":"http://127.0.0.1:1"}"#).unwrap_err().code, "fetch_failed");
    let r = j(v.instance_remove(&json!({"instance": m.id()}).to_string()));
    assert_eq!(r["removed"], m.id());
    assert_eq!(j(v.instances_json()), json!({"instances": []}));
    assert_eq!(v.instance_remove(&json!({"instance": m.id()}).to_string()).unwrap_err().code, "not_found");
}

#[test]
fn browse_and_search() {
    let (_t, m, v, id) = setup("browse");
    let ch = j(v.channels(&json!({"instance": id, "count": 3}).to_string()));
    assert_eq!(ch["total"], 154);
    assert_eq!(ch["channels"][0]["name"], "civil-defense-engineer");
    assert_eq!(ch["channels"][0]["handle"], "civil-defense-engineer");
    let cs = j(v.channels(&json!({"instance": id, "search": "survival"}).to_string()));
    assert_eq!(cs["channels"].as_array().unwrap().len(), 2);
    assert!(m.hits_for("/api/v1/search/video-channels")[0].path.contains("search=survival&searchTarget=local"));

    let l = j(v.list(&json!({"instance": id}).to_string()));
    let first = &l["videos"][0];
    assert!(first["uuid"].is_string() && first["title"].is_string());
    assert!(first["thumbnail"].as_str().unwrap().starts_with(&m.url()));
    assert_eq!(first["downloaded"], false);
    let cv = j(v.list(&json!({"instance": id, "channel": "oh8stn", "count": 3}).to_string()));
    assert_eq!(cv["videos"].as_array().unwrap().len(), 3);
    assert!(m.hits_for("/video-channels/oh8stn/videos").len() == 1);
    let s = j(v.search(&json!({"instance": id, "query": "ham radio"}).to_string()));
    assert_eq!(s["total"], 1905);
    assert!(m.hits_for("/api/v1/search/videos")[0].path.contains("search=ham%20radio&searchTarget=local"));
    assert_eq!(v.search(&json!({"instance": id, "query": " "}).to_string()).unwrap_err().code, "bad_json");
    assert_eq!(v.list(&json!({"instance": id, "sort": "x&y"}).to_string()).unwrap_err().code, "bad_json");
    assert_eq!(v.list(&json!({"instance": "nope.example"}).to_string()).unwrap_err().code, "not_found");

    let d = j(v.get(&json!({"instance": id, "video": WEB_UUID}).to_string()));
    assert_eq!(d["title"], "Merry Christmas from the Isle of Man");
    assert_eq!(d["duration_s"], 11);
    assert_eq!(d["download_enabled"], true);
    assert_eq!(d["channel"]["name"], "big-clive");
    assert_eq!(d["options"], json!([{"key": "608", "label": "608p", "kind": "video", "size": 1976686, "source": "web"}]));
    assert_eq!(d["captions"][0]["language"], "en");
    assert!(d["captions"][0]["url"].as_str().unwrap().starts_with(&m.url()));
    assert_eq!(d["stream"]["hls"], Value::Null);
    assert!(d["stream"]["mp4"].as_str().unwrap().ends_with("-608.mp4"));
    assert_eq!(d["stream"]["needs_auth"], false);
    // a short uuid is accepted by the instance
    assert_eq!(j(v.get(&json!({"instance": id, "video": WEB_SHORT}).to_string()))["uuid"], WEB_UUID);
    assert_eq!(v.get(&json!({"instance": id, "video": "00000000-0000-4000-8000-000000000000"}).to_string()).unwrap_err().code, "not_found");
    // the video page of a synthetic HLS video lists every resolution with sizes and audio only
    let h = j(v.get(&json!({"instance": id, "video": HLS_UUID}).to_string()));
    let keys: Vec<(&str, &str, u64)> = h["options"].as_array().unwrap().iter().map(|o| (o["key"].as_str().unwrap(), o["source"].as_str().unwrap(), o["size"].as_u64().unwrap())).collect();
    assert_eq!(keys, vec![("720", "hls+audio", 340_000), ("360", "hls", 120_000), ("audio", "hls", 40_000)]);
    assert!(h["stream"]["hls"].as_str().unwrap().ends_with("/master.m3u8"));
}

#[test]
fn login_refresh_and_me() {
    let (t, m, v, id) = setup("login");
    let pw = "correct horse";
    let tok = j(v.login(&json!({"instance": id, "username": "alice", "password": pw}).to_string()));
    assert_eq!(tok["access_token"], "A1");
    assert_eq!(tok["refresh_token"], "R1");
    assert_eq!(tok["expires_in"], 14399);
    // the form went to the documented endpoint with the password grant
    let post = &m.hits_for("/api/v1/users/token")[0];
    assert!(post.body.contains("grant_type=password") && post.body.contains("username=alice") && post.body.contains("password=correct+horse"));
    let me = j(v.me(&json!({"instance": id, "token": "A1"}).to_string()));
    assert_eq!(me, json!({"instance": id, "username": "alice", "display_name": "Alice", "role": "Moderator"}));
    assert!(!me.to_string().contains("example.invalid"), "no e-mail address is returned");
    let r = j(v.refresh(&json!({"instance": id, "refresh_token": "R1"}).to_string()));
    assert_eq!((r["access_token"].as_str().unwrap(), r["refresh_token"].as_str().unwrap()), ("A2", "R2"));
    // failures: wrong password, bad refresh token, bad access token, two-factor
    let e = v.login(&json!({"instance": id, "username": "alice", "password": "hunter2-secret"}).to_string()).unwrap_err();
    assert_eq!(e.code, "auth_failed");
    assert!(!e.message.contains("hunter2-secret"), "the password never appears in an error");
    assert_eq!(v.refresh(&json!({"instance": id, "refresh_token": "nope"}).to_string()).unwrap_err().code, "auth_failed");
    assert_eq!(v.me(&json!({"instance": id, "token": "bad"}).to_string()).unwrap_err().code, "auth_failed");
    assert_eq!(v.login(&json!({"instance": id, "username": "twofa", "password": pw}).to_string()).unwrap_err().code, "otp_required");
    assert_eq!(j(v.login(&json!({"instance": id, "username": "twofa", "password": pw, "otp": "123456"}).to_string()))["access_token"], "A1");
    // nothing was written to disk besides the instance list
    let names: Vec<String> = std::fs::read_dir(&t.0).unwrap().map(|e| e.unwrap().file_name().to_string_lossy().into_owned()).collect();
    assert_eq!(names, vec!["instances.json".to_string()]);
    let all = std::fs::read_to_string(t.0.join("instances.json")).unwrap();
    assert!(!all.contains("A1") && !all.contains("R1") && !all.contains(pw));
}

#[test]
fn download_list_resolve_delete() {
    let (t, m, v, id) = setup("dl");
    let prog: std::sync::Mutex<Vec<(u64, u64)>> = Default::default();
    let params = json!({"dir": t.s(), "instance": id, "video": WEB_UUID, "choice": "lowest"}).to_string();
    let out = dl::run_job(&params, &|d, t| prog.lock().unwrap().push((d, t)), &|| false).unwrap();
    assert_eq!(out, Outcome::Done);
    let p = prog.lock().unwrap();
    assert_eq!(p.last().unwrap(), &(WEB_SIZE as u64, WEB_SIZE as u64));
    assert!(p.windows(2).all(|w| w[0].0 <= w[1].0), "progress only goes forward");
    let dir = t.0.join("downloads").join(&id).join(WEB_UUID);
    assert_eq!(sha_hex(&std::fs::read(dir.join("video.mp4")).unwrap()), sha_hex(&blob(WEB_SIZE, 7)));
    assert!(dir.join("thumb.jpg").is_file() && dir.join("captions-en.vtt").is_file());
    assert!(!dir.join("video.part").exists() && !dir.join("video.part.json").exists());

    let dls = j(v.downloads_json());
    assert_eq!(dls["downloads"].as_array().unwrap().len(), 1);
    let man = &dls["downloads"][0];
    assert_eq!((man["uuid"].as_str().unwrap(), man["resolution"].as_str().unwrap(), man["kind"].as_str().unwrap()), (WEB_UUID, "608", "video"));
    assert_eq!(man["size"], WEB_SIZE);
    assert_eq!(man["sha256"], sha_hex(&blob(WEB_SIZE, 7)));
    assert_eq!(man["captions"][0]["language"], "en");
    assert_eq!(man["duration_s"], 11);
    assert_eq!(man["channel"]["name"], "big-clive");
    assert!(man["path"].as_str().unwrap().ends_with("video.mp4") && std::path::Path::new(man["path"].as_str().unwrap()).is_file());
    assert!(dls["total_bytes"].as_u64().unwrap() > WEB_SIZE as u64);
    // the manifest holds no instance address from the user's credentials, and no token
    let mtxt = std::fs::read_to_string(dir.join("manifest.json")).unwrap();
    assert!(!mtxt.contains("token"));

    // lists and the video page know it is downloaded
    assert_eq!(j(v.list(&json!({"instance": id}).to_string()))["videos"].as_array().unwrap().iter().filter(|x| x["downloaded"] == true).count(), 1);
    assert_eq!(j(v.get(&json!({"instance": id, "video": WEB_UUID}).to_string()))["downloaded"]["resolution"], "608");

    // citation: local while downloaded (with no network call), by uuid, short uuid or link; offset clamped to the duration
    let hits_before = m.hits.lock().unwrap().len();
    for video in [json!(WEB_UUID), json!(WEB_SHORT), json!(format!("{}/w/{WEB_SHORT}?start=1m30s", m.url()))] {
        let r = j(v.resolve(&json!({"video": video, "offset_s": 5.5}).to_string()));
        assert_eq!(r["kind"], "local");
        assert_eq!(r["offset_s"], 5.5);
        assert!(r["path"].as_str().unwrap().ends_with("video.mp4"));
        assert_eq!(r["captions"][0]["language"], "en");
    }
    let r = j(v.resolve(&json!({"url": format!("{}/w/{WEB_SHORT}?start=1m30s", m.url())}).to_string()));
    assert_eq!((r["kind"].as_str().unwrap(), r["offset_s"].as_f64().unwrap()), ("local", 11.0), "90 s is past the end: clamped to the duration");
    assert_eq!(m.hits.lock().unwrap().len(), hits_before, "a downloaded video resolves without the network");

    // a second download of the same video replaces the first
    assert_eq!(job(&v, &t, &id, WEB_UUID, "608", json!({})).unwrap(), Outcome::Done);
    assert_eq!(j(v.downloads_json())["downloads"].as_array().unwrap().len(), 1);

    // delete, then the same citation streams
    let del = j(v.delete_download(&json!({"instance": id, "video": WEB_SHORT}).to_string()));
    assert_eq!(del["deleted"], WEB_UUID);
    assert!(!dir.exists());
    assert_eq!(v.delete_download(&json!({"instance": id, "video": WEB_UUID}).to_string()).unwrap_err().code, "not_found");
    assert_eq!(j(v.downloads_json())["downloads"], json!([]));
    let r = j(v.resolve(&json!({"video": WEB_UUID, "offset_s": 4}).to_string()));
    assert_eq!(r["kind"], "stream");
    assert_eq!(r["format"], "mp4");
    assert_eq!(r["offset_s"], 4.0);
    assert!(r["url"].as_str().unwrap().starts_with(&m.url()) && r["url"].as_str().unwrap().ends_with("-608.mp4"));
    // HLS is preferred when the instance has it
    let r = j(v.resolve(&json!({"video": HLS_UUID, "instance": id, "offset_s": 12}).to_string()));
    assert_eq!((r["format"].as_str().unwrap(), r["offset_s"].as_f64().unwrap()), ("hls", 12.0));
    assert!(r["url"].as_str().unwrap().ends_with("/master.m3u8"));
    // a link to an instance that was never added works too (streamed from that address)
    let m2 = Mock::start();
    let r = j(v.resolve(&json!({"video": format!("{}/videos/watch/{WEB_UUID}?t=7", m2.url())}).to_string()));
    assert_eq!((r["kind"].as_str().unwrap(), r["offset_s"].as_f64().unwrap()), ("stream", 7.0));
    assert!(r["url"].as_str().unwrap().starts_with(&m2.url()));
    assert_eq!(v.resolve(&json!({"video": "00000000-0000-4000-8000-000000000000"}).to_string()).unwrap_err().code, "not_found");
}

#[test]
fn interrupted_download_resumes_with_range() {
    let (t, m, _v, id) = setup("resume");
    // the connection drops after ~600 KB; the job continues from there by itself
    m.knobs.lock().unwrap().cut_after = Some(600_000);
    assert_eq!(job(&_v, &t, &id, WEB_UUID, "lowest", json!({})).unwrap(), Outcome::Done);
    let gets = m.hits_for(WEB_FILE);
    assert_eq!(gets.len(), 2, "one cut request and one resumed request");
    assert!(gets[0].header("Range").is_none());
    let from: usize = gets[1].header("Range").unwrap().strip_prefix("bytes=").unwrap().strip_suffix('-').unwrap().parse().unwrap();
    assert!(from >= 500_000 && from < WEB_SIZE, "resumed at {from}");
    let f = std::fs::read(t.0.join("downloads").join(&id).join(WEB_UUID).join("video.mp4")).unwrap();
    assert_eq!(sha_hex(&f), sha_hex(&blob(WEB_SIZE, 7)));
}

#[test]
fn cancelled_download_keeps_its_data_and_a_new_job_resumes() {
    let (t, m, v, id) = setup("cancel");
    m.knobs.lock().unwrap().slow_ms = 5;
    let seen = AtomicU64::new(0);
    let params = json!({"dir": t.s(), "instance": id, "video": WEB_UUID, "choice": "lowest"}).to_string();
    let out = dl::run_job(&params, &|d, _| seen.store(d, Ordering::SeqCst), &|| seen.load(Ordering::SeqCst) > 400_000).unwrap();
    assert_eq!(out, Outcome::Cancelled);
    let dir = t.0.join("downloads").join(&id).join(WEB_UUID);
    let part = std::fs::metadata(dir.join("video.part")).unwrap().len();
    assert!(part > 400_000 && part < WEB_SIZE as u64);
    assert!(!dir.join("manifest.json").exists(), "an unfinished download is not listed");
    assert_eq!(j(v.downloads_json())["downloads"], json!([]));
    m.knobs.lock().unwrap().slow_ms = 0;
    assert_eq!(job(&v, &t, &id, WEB_UUID, "lowest", json!({})).unwrap(), Outcome::Done);
    let gets = m.hits_for(WEB_FILE);
    assert_eq!(gets.last().unwrap().header("Range").unwrap(), format!("bytes={part}-"));
    assert_eq!(sha_hex(&std::fs::read(dir.join("video.mp4")).unwrap()), sha_hex(&blob(WEB_SIZE, 7)));
}

#[test]
fn guards_before_downloading() {
    let (t, m, v, id) = setup("guards");
    // not enough room: nothing is downloaded, the numbers are reported
    let e = job(&v, &t, &id, WEB_UUID, "lowest", json!({"fake_available_bytes": 1_000_000})).unwrap_err();
    assert_eq!(e.code, "no_space");
    let (needed, avail) = e.space.unwrap();
    assert!(needed > WEB_SIZE as u64 && avail == 1_000_000);
    assert!(m.hits_for(WEB_FILE).is_empty());
    // audio only is not offered by this video
    assert_eq!(job(&v, &t, &id, WEB_UUID, "audio", json!({})).unwrap_err().code, "unsupported");
    // the instance turned downloads off for it
    m.knobs.lock().unwrap().download_disabled = true;
    let e = job(&v, &t, &id, WEB_UUID, "lowest", json!({})).unwrap_err();
    assert_eq!(e.code, "unsupported");
    assert!(e.message.contains("turned downloads off"));
    assert!(m.hits_for(WEB_FILE).is_empty(), "downloadEnabled false: the file is never requested");
    assert_eq!(job(&v, &t, &id, "00000000-0000-4000-8000-000000000000", "lowest", json!({})).unwrap_err().code, "not_found");
    assert_eq!(dl::prepare(&json!({"dir": t.s(), "instance": "nope", "video": WEB_UUID}).to_string()).err().unwrap().code, "not_found");
    assert_eq!(dl::prepare(r#"{"dir":"x","instance":"a","video":"../../etc","bogus":1}"#).err().unwrap().code, "bad_json");
    assert_eq!(dl::prepare(&json!({"dir": t.s(), "instance": id, "video": "../x"}).to_string()).err().unwrap().code, "bad_json");
}

#[test]
fn hls_files_audio_only_and_the_joined_pair() {
    let (t, m, v, id) = setup("hls");
    // 360: an HLS file that has sound; its checksum is in the playlist's list, and is verified
    assert_eq!(job(&v, &t, &id, HLS_UUID, "360", json!({})).unwrap(), Outcome::Done);
    let dls = j(v.downloads_json());
    let man = &dls["downloads"][0];
    assert_eq!((man["source"].as_str().unwrap(), man["checksum_verified"].as_str().unwrap()), ("hls", "playlist"));
    // audio only (a different file: it replaces the earlier download of this video)
    assert_eq!(job(&v, &t, &id, HLS_UUID, "audio", json!({})).unwrap(), Outcome::Done);
    let man = j(v.downloads_json())["downloads"][0].clone();
    assert_eq!((man["kind"].as_str().unwrap(), man["size"].as_u64().unwrap(), man["checksum_verified"].as_str().unwrap()), ("audio", 40_000, "playlist"));
    // 720 has no sound in its own file: the instance joins it with the audio file
    assert_eq!(job(&v, &t, &id, HLS_UUID, "720", json!({})).unwrap(), Outcome::Done);
    let gen = m.hits_for("/download/videos/generate/");
    assert_eq!(gen.len(), 1);
    assert!(gen[0].path.contains("videoFileIds=101&videoFileIds=103"));
    let man = j(v.downloads_json())["downloads"][0].clone();
    assert_eq!((man["source"].as_str().unwrap(), man["size"].as_u64().unwrap()), ("hls+audio", 340_000));
    // a nearby resolution is chosen when the exact one is missing
    assert_eq!(job(&v, &t, &id, HLS_UUID, "480", json!({})).unwrap(), Outcome::Done);
    assert_eq!(j(v.downloads_json())["downloads"][0]["resolution"], "360");
    // a checksum that does not match deletes the file
    m.knobs.lock().unwrap().bad_sha = true;
    let e = job(&v, &t, &id, HLS_UUID, "audio", json!({})).unwrap_err();
    assert_eq!(e.code, "damaged");
    assert!(!t.0.join("downloads").join(&id).join(HLS_UUID).join("video.part").exists());
}

#[test]
fn private_video_needs_a_login_and_a_file_token() {
    let (t, m, v, id) = setup("private");
    m.knobs.lock().unwrap().private_hls = true;
    let e = job(&v, &t, &id, HLS_UUID, "360", json!({})).unwrap_err();
    assert_eq!(e.code, "auth_failed");
    assert_eq!(job(&v, &t, &id, HLS_UUID, "360", json!({"token": "A1"})).unwrap(), Outcome::Done);
    assert!(m.hits_for("/token").iter().any(|h| h.method == "POST" && h.header("Authorization") == Some("Bearer A1")));
    // the bearer token goes to the API, never to the file server
    assert!(m.hits_for("360-fragmented.mp4").iter().all(|h| h.header("Authorization").is_none() && h.path.contains("videoFileToken=FT1")));
}

#[test]
fn at_most_two_downloads_per_instance() {
    let a = dl::acquire("limit.test", &|| false).unwrap();
    let b = dl::acquire("limit.test", &|| false).unwrap();
    // a third waits; here it is cancelled while waiting
    assert!(dl::acquire("limit.test", &|| true).is_none());
    // another instance is not held up by it
    let other = dl::acquire("other.test", &|| true).unwrap();
    drop(a);
    let c = dl::acquire("limit.test", &|| true).unwrap();
    drop((b, c, other));
}
