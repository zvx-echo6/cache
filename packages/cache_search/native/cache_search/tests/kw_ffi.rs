//! Caption and EPUB indexes: the `index_source` job for the kinds `captions`, `zim-captions` and `zim-epub`, publishing as
//! snapshots, attaching, search, citations, read, search by caption, files inside EPUBs, resume after a kill, reuse across
//! editions. The ZIMs and EPUBs are tiny ones written here.

use cache_search::handle::Handle;
use cache_search::job::Job;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

const U2: &str = "0badc0de-0000-4000-8000-00000000beef";
const HOST: &str = "peertube.example";

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-kw-{}-{}", std::process::id(), name));
        let _ = std::fs::remove_dir_all(&p);
        std::fs::create_dir_all(&p).unwrap();
        TempDir(p)
    }
}
impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

// ---------------------------------------------------------------------------------------------------------
// Fixtures

const MIMES: [&str; 8] = [
    "text/html",
    "text/plain",
    "text/vtt",
    "application/x-subrip",
    "video/mp4",
    "video/mp2t",
    "application/epub+zip",
    "application/octet-stream",
];

fn mime_index(mimes: &[&str], m: &str) -> u16 {
    mimes.iter().position(|x| *x == m).unwrap() as u16
}

/// A minimal valid ZIM (major 6, minor 1) holding `entries` (namespace `C`: path, title, mime, bytes) and the metadata
/// `Language`, `Title` and `Name`, in one uncompressed cluster.
fn write_zim(path: &Path, uuid: &str, name: &str, entries: &[(&str, &str, &str, Vec<u8>)]) {
    write_zim_mimes(path, uuid, name, entries, &MIMES);
}

/// `write_zim` with the header's MIME list given (`text/plain` must be second: the metadata uses it).
fn write_zim_mimes(path: &Path, uuid: &str, name: &str, entries: &[(&str, &str, &str, Vec<u8>)], mimes: &[&str]) {
    let mut all: Vec<(u8, String, String, u16, Vec<u8>)> = entries
        .iter()
        .map(|(p, t, m, b)| (b'C', p.to_string(), t.to_string(), mime_index(mimes, m), b.clone()))
        .collect();
    for (k, v) in [("Language", "eng"), ("Title", "Media test"), ("Name", name)] {
        all.push((b'M', k.into(), k.into(), 1, v.as_bytes().to_vec()));
    }
    all.sort_by(|a, b| (a.0, &a.1).cmp(&(b.0, &b.1)));
    let n = all.len();
    let mut mime = Vec::new();
    for m in mimes {
        mime.extend_from_slice(m.as_bytes());
        mime.push(0);
    }
    mime.push(0);
    let url_ptr_pos = 80 + mime.len() as u64;
    let title_ptr_pos = url_ptr_pos + 8 * n as u64;
    let cluster_ptr_pos = title_ptr_pos + 4 * n as u64;
    let cluster_pos = cluster_ptr_pos + 8;
    let mut cluster = vec![1u8];
    let mut off = (4 * (n + 1)) as u32;
    let mut offs = Vec::new();
    for e in &all {
        offs.push(off);
        off += e.4.len() as u32;
    }
    offs.push(off);
    for o in &offs {
        cluster.extend_from_slice(&o.to_le_bytes());
    }
    for e in &all {
        cluster.extend_from_slice(&e.4);
    }
    let entries_pos = cluster_pos + cluster.len() as u64;
    let mut dirents: Vec<u8> = Vec::new();
    let mut entry_pos: Vec<u64> = Vec::new();
    for (i, e) in all.iter().enumerate() {
        entry_pos.push(entries_pos + dirents.len() as u64);
        dirents.extend_from_slice(&e.3.to_le_bytes());
        dirents.push(0);
        dirents.push(e.0);
        dirents.extend_from_slice(&0u32.to_le_bytes());
        dirents.extend_from_slice(&0u32.to_le_bytes());
        dirents.extend_from_slice(&(i as u32).to_le_bytes());
        dirents.extend_from_slice(e.1.as_bytes());
        dirents.push(0);
        dirents.extend_from_slice(e.2.as_bytes());
        dirents.push(0);
    }
    let checksum_pos = entries_pos + dirents.len() as u64;
    let mut by_title: Vec<u32> = (0..n as u32).collect();
    by_title.sort_by(|a, b| {
        let (x, y) = (&all[*a as usize], &all[*b as usize]);
        (x.0, &x.2).cmp(&(y.0, &y.2))
    });
    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(&0x044D495Au32.to_le_bytes());
    out.extend_from_slice(&6u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    let u: Vec<u8> = (0..16)
        .map(|i| u8::from_str_radix(&uuid.replace('-', "")[2 * i..2 * i + 2], 16).unwrap())
        .collect();
    out.extend_from_slice(&u);
    out.extend_from_slice(&(n as u32).to_le_bytes());
    out.extend_from_slice(&1u32.to_le_bytes());
    for v in [url_ptr_pos, title_ptr_pos, cluster_ptr_pos, 80u64] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&u32::MAX.to_le_bytes());
    out.extend_from_slice(&u32::MAX.to_le_bytes());
    out.extend_from_slice(&checksum_pos.to_le_bytes());
    assert_eq!(out.len(), 80);
    out.extend_from_slice(&mime);
    for p in &entry_pos {
        out.extend_from_slice(&p.to_le_bytes());
    }
    for t in &by_title {
        out.extend_from_slice(&t.to_le_bytes());
    }
    out.extend_from_slice(&cluster_pos.to_le_bytes());
    out.extend_from_slice(&cluster);
    out.extend_from_slice(&dirents);
    out.extend_from_slice(&[0u8; 16]);
    std::fs::write(path, out).unwrap();
}

/// A zip of stored members.
fn zip(members: &[(&str, Vec<u8>)]) -> Vec<u8> {
    let mut out: Vec<u8> = Vec::new();
    let mut dir: Vec<u8> = Vec::new();
    for (name, data) in members {
        let off = out.len() as u32;
        out.extend_from_slice(&0x0403_4b50u32.to_le_bytes());
        out.extend_from_slice(&[20, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        out.extend_from_slice(&0u32.to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(data.len() as u32).to_le_bytes());
        out.extend_from_slice(&(name.len() as u16).to_le_bytes());
        out.extend_from_slice(&0u16.to_le_bytes());
        out.extend_from_slice(name.as_bytes());
        out.extend_from_slice(data);
        dir.extend_from_slice(&0x0201_4b50u32.to_le_bytes());
        dir.extend_from_slice(&[20, 0, 20, 0, 0, 0, 0, 0, 0, 0, 0, 0]);
        dir.extend_from_slice(&0u32.to_le_bytes());
        dir.extend_from_slice(&(data.len() as u32).to_le_bytes());
        dir.extend_from_slice(&(data.len() as u32).to_le_bytes());
        dir.extend_from_slice(&(name.len() as u16).to_le_bytes());
        dir.extend_from_slice(&[0u8; 12]);
        dir.extend_from_slice(&off.to_le_bytes());
        dir.extend_from_slice(name.as_bytes());
    }
    let (dir_off, dir_len) = (out.len() as u32, dir.len() as u32);
    out.extend_from_slice(&dir);
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&[0, 0, 0, 0]);
    out.extend_from_slice(&(members.len() as u16).to_le_bytes());
    out.extend_from_slice(&(members.len() as u16).to_le_bytes());
    out.extend_from_slice(&dir_len.to_le_bytes());
    out.extend_from_slice(&dir_off.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

fn words(seed: &str, n: usize) -> String {
    // sentences of 12 words that all mention the seed, so a keyword search finds them
    (0..n / 12 + 1)
        .map(|i| format!("In part {i} the {seed} guidance says that people should check the plan and keep every neighbour informed."))
        .collect::<Vec<_>>()
        .join(" ")
}

/// An EPUB: chapters are (file name, heading, topic word, number of words).
fn epub(title: &str, chapters: &[(&str, &str, &str, usize)]) -> Vec<u8> {
    let container = r#"<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>"#;
    let mut manifest = String::from(
        r#"<item id="css" href="style.css" media-type="text/css"/><item id="img" href="pic.png" media-type="image/png"/>"#,
    );
    let mut spine = String::new();
    for (i, (file, _, _, _)) in chapters.iter().enumerate() {
        manifest.push_str(&format!(
            r#"<item id="c{i}" href="{file}" media-type="application/xhtml+xml"/>"#
        ));
        spine.push_str(&format!(r#"<itemref idref="c{i}"/>"#));
    }
    let opf = format!(
        r#"<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="3.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>{title}</dc:title></metadata><manifest>{manifest}</manifest><spine>{spine}</spine></package>"#
    );
    let mut members: Vec<(String, Vec<u8>)> = vec![
        ("mimetype".into(), b"application/epub+zip".to_vec()),
        ("META-INF/container.xml".into(), container.as_bytes().to_vec()),
        ("OEBPS/content.opf".into(), opf.into_bytes()),
        ("OEBPS/style.css".into(), b"p { margin: 0 }".to_vec()),
        ("OEBPS/pic.png".into(), vec![0x89, b'P', b'N', b'G', 1, 2, 3]),
    ];
    for (file, heading, topic, n) in chapters {
        let body = format!(
            "<?xml version=\"1.0\"?><html xmlns=\"http://www.w3.org/1999/xhtml\"><head><title>{heading}</title><link rel=\"stylesheet\" href=\"style.css\"/></head><body><h1>{heading}</h1><p>{}</p><p>{}</p><img src=\"pic.png\" alt=\"\"/></body></html>",
            words(topic, *n),
            words(&format!("{topic} second"), n / 2)
        );
        members.push((format!("OEBPS/{file}"), body.into_bytes()));
    }
    let refs: Vec<(&str, Vec<u8>)> = members.iter().map(|(n, d)| (n.as_str(), d.clone())).collect();
    zip(&refs)
}

fn srt(cues: &[(u32, &str)]) -> Vec<u8> {
    // one cue every 4 seconds starting at `start`, numbered; times as SRT writes them
    let mut s = String::new();
    for (k, (at, text)) in cues.iter().enumerate() {
        let (a, b) = (*at, *at + 3);
        s.push_str(&format!(
            "{}\r\n{:02}:{:02}:{:02},000 --> {:02}:{:02}:{:02},500\r\n{}\r\n\r\n",
            k + 1,
            a / 3600,
            a % 3600 / 60,
            a % 60,
            b / 3600,
            b % 3600 / 60,
            b % 60,
            text
        ));
    }
    format!("\u{feff}{s}").into_bytes()
}

fn speech(topic: &str, n: usize) -> Vec<(u32, String)> {
    (0..n)
        .map(|i| {
            (
                i as u32 * 4,
                format!("cue {i} we talk about {topic} and what to do next"),
            )
        })
        .collect()
}

fn srt_of(topic: &str, n: usize) -> Vec<u8> {
    let sp = speech(topic, n);
    let refs: Vec<(u32, &str)> = sp.iter().map(|(a, t)| (*a, t.as_str())).collect();
    srt(&refs)
}

fn vtt_of(topic: &str, n: usize) -> Vec<u8> {
    let mut s = String::from("WEBVTT\n\n");
    for (at, text) in speech(topic, n) {
        s.push_str(&format!(
            "{:02}:{:02}.000 --> {:02}:{:02}.500 align:start\n<c.yellow>{}</c>\n\n",
            at / 60,
            at % 60,
            (at + 3) / 60,
            (at + 3) % 60,
            text
        ));
    }
    s.into_bytes()
}

/// A saved video folder under `<video dir>/downloads/<host>/<uuid>` with the given caption files.
fn save_video(video_dir: &Path, uuid: &str, title: &str, captions: &[(&str, Vec<u8>)]) {
    let d = video_dir.join("downloads").join(HOST).join(uuid);
    std::fs::create_dir_all(&d).unwrap();
    let caps: Vec<Value> = captions
        .iter()
        .map(|(l, _)| json!({"language": l, "file": format!("captions-{l}.vtt")}))
        .collect();
    for (l, b) in captions {
        std::fs::write(d.join(format!("captions-{l}.vtt")), b).unwrap();
    }
    std::fs::write(d.join("video.mp4"), b"x").unwrap();
    let m = json!({"version": 1, "instance": HOST, "uuid": uuid, "title": title, "file": "video.mp4", "captions": caps, "downloaded_at": "2026-11-01T00:00:00.000Z"});
    std::fs::write(d.join("manifest.json"), m.to_string()).unwrap();
}

// ---------------------------------------------------------------------------------------------------------
// Helpers

fn open(zims: &[&Path], indexes: &Path, video_dir: &Path) -> Handle {
    let sources: Vec<Value> = zims.iter().map(|p| json!({"kind": "zim", "path": p})).collect();
    Handle::open(
        &json!({"sources": sources, "indexes_dir": indexes, "video": {"dir": video_dir}, "prewarm": false}).to_string(),
    )
    .unwrap()
}

fn start(params: Value) -> Job {
    Job::start("index_source", &params.to_string()).unwrap_or_else(|e| panic!("job did not start: {e:?}"))
}

fn wait(j: &Job) -> Value {
    let t0 = Instant::now();
    loop {
        let p: Value = serde_json::from_str(&j.progress_json()).unwrap();
        if p["state"] != "running" {
            return p;
        }
        assert!(t0.elapsed() < Duration::from_secs(120), "job timed out: {p}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn run(params: Value) -> Value {
    let p = wait(&start(params));
    assert_eq!(p["state"], "done", "{p}");
    p
}

fn job_params(idx: &Path, kind: &str, id: &str) -> Value {
    json!({"indexes_dir": idx, "kind": kind, "source_id": id})
}

fn search(h: &mut Handle, q: &str, opts: Value) -> Value {
    serde_json::from_str(&h.search(q, Some(&opts.to_string())).unwrap()).unwrap()
}

fn wait_status<F: Fn(&Value) -> bool>(h: &mut Handle, f: F) -> Value {
    let t0 = Instant::now();
    loop {
        let v: Value = serde_json::from_str(&h.status_json()).unwrap();
        if f(&v) {
            return v;
        }
        assert!(t0.elapsed() < Duration::from_secs(60), "status never became ready: {v}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// Every file under `dir` with its size and modification time: to see that nothing is written to a snapshot.
fn tree(dir: &Path) -> Vec<(String, u64, std::time::SystemTime)> {
    fn walk(d: &Path, root: &Path, out: &mut Vec<(String, u64, std::time::SystemTime)>) {
        let mut names: Vec<_> = std::fs::read_dir(d).unwrap().flatten().collect();
        names.sort_by_key(|e| e.file_name());
        for e in names {
            let m = e.metadata().unwrap();
            if m.is_dir() {
                walk(&e.path(), root, out);
            } else {
                out.push((
                    e.path().strip_prefix(root).unwrap().to_string_lossy().into_owned(),
                    m.len(),
                    m.modified().unwrap(),
                ));
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out);
    out
}

fn snap_dirs(source_dir: &Path) -> Vec<PathBuf> {
    let mut v: Vec<PathBuf> = std::fs::read_dir(source_dir.join("snap"))
        .map(|rd| rd.flatten().map(|e| e.path()).collect())
        .unwrap_or_default();
    v.sort();
    v
}

fn media_entries(epubs: &[(&str, Vec<u8>)]) -> Vec<(&'static str, &'static str, &'static str, Vec<u8>)> {
    let mut v: Vec<(&'static str, &'static str, &'static str, Vec<u8>)> = vec![
        (
            "Alpha",
            "Alpha",
            "text/html",
            b"<html><body><p>Alpha.</p></body></html>".to_vec(),
        ),
        (
            "Media/FEMA_UHA_video01.mp4",
            "",
            "video/mp4",
            b"not really a video".to_vec(),
        ),
        (
            "Media/FEMA_UHA_video01_en.srt",
            "",
            "application/x-subrip",
            srt_of("sandbag barriers", 30),
        ),
        (
            "Media/FEMA_UHA_video01_es.srt",
            "",
            "application/x-subrip",
            srt_of("barreras de sacos", 12),
        ),
        (
            "Media/other.vtt",
            "Standalone talk",
            "text/vtt",
            vtt_of("generator safety", 20),
        ),
        ("hls/segment0.vtt", "", "text/vtt", vtt_of("hidden segment words", 6)),
        ("hls/seg0.ts", "", "video/mp2t", b"ts".to_vec()),
    ];
    for (name, bytes) in epubs {
        let leaked: &'static str = Box::leak(format!("Books/{name}").into_boxed_str());
        v.push((leaked, "", "application/epub+zip", bytes.clone()));
    }
    v
}

// ---------------------------------------------------------------------------------------------------------
// captions (a saved video)

#[test]
fn saved_video_captions_build_publish_attach_search_cite_read_and_resume() {
    const VIDEO: &str = "9f2e1c4a-1111-4222-8333-000000000001";
    let t = TempDir::new("vid");
    let (idx, vdir) = (t.0.join("indexes"), t.0.join("video"));
    save_video(
        &vdir,
        VIDEO,
        "Flood Safety Basics",
        &[
            ("en", vtt_of("sandbag barriers", 60)),
            ("fr", srt_of("sacs de sable", 12)),
            ("es", vtt_of("bolsas de arena", 12)),
        ],
    );
    let source = format!("{HOST}/{VIDEO}");
    let mut h = open(&[], &idx, &vdir);

    // before the build: the video's entry says its captions source id and that it needs a build
    let dl: Value = serde_json::from_str(&h.video_downloads_json().unwrap()).unwrap();
    let ci = &dl["downloads"][0]["captions_index"];
    assert_eq!(
        (
            ci["source_id"].as_str(),
            ci["built"].as_bool(),
            ci["needs_build"].as_bool()
        ),
        (Some(source.as_str()), Some(false), Some(true)),
        "{dl}"
    );
    assert!(search(&mut h, "sandbag barriers", json!({}))["results"]
        .as_array()
        .unwrap()
        .is_empty());

    // killed after two files with a commit per file: the third is lost, the first two are kept
    let mut p = job_params(&idx, "captions", &source);
    p["batch_items"] = json!(1);
    p["crash_after"] = json!(2);
    let failed = wait(&start(p.clone()));
    assert_eq!(failed["state"], "failed", "{failed}");
    let src_dir = idx.join("captions").join(format!("{HOST}%2F{VIDEO}"));
    assert!(src_dir.join(".build").is_dir() && snap_dirs(&src_dir).is_empty());

    // resumed: finishes with the two it had
    p.as_object_mut().unwrap().remove("crash_after");
    let done = run(p.clone());
    assert_eq!(done["result"]["items"], 3, "{done}");
    assert_eq!(done["result"]["resumed"], 2, "{done}");
    assert_eq!(done["result"]["skipped"], 0);
    assert!(done["result"]["pieces"].as_u64().unwrap() >= 3);
    assert!(done["result"]["bytes"].as_u64().unwrap() > 0);
    assert_eq!(done["phase"], "publish");
    assert!(
        !src_dir.join(".build").exists(),
        "the working folder is gone after publishing"
    );
    let snaps = snap_dirs(&src_dir);
    assert_eq!(snaps.len(), 1);
    assert_eq!(
        done["result"]["snapshot"],
        snaps[0].file_name().unwrap().to_str().unwrap()
    );
    let manifest: Value = serde_json::from_slice(&std::fs::read(snaps[0].join("manifest.json")).unwrap()).unwrap();
    assert_eq!(manifest["kind"], "captions");
    assert_eq!(manifest["source_id"], source);
    assert_eq!(manifest["host"], HOST);
    assert!(manifest["files"]
        .as_array()
        .unwrap()
        .iter()
        .any(|f| f["path"] == "items.tsv"));

    // the same request again finds the snapshot and builds nothing
    let again = run(job_params(&idx, "captions", &source));
    assert_eq!(again["result"]["existing"], true);
    assert_eq!(again["result"]["snapshot"], done["result"]["snapshot"]);

    // attached without another cs_set_sources
    let snap_before = tree(&src_dir.join("snap"));
    let v = wait_status(&mut h, |_| h_has_index(&idx, &source));
    let _ = v;
    let r = loop {
        let r = search(&mut h, "sandbag barriers", json!({"k": 3}));
        if !r["results"].as_array().unwrap().is_empty() {
            break r;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let first = &r["results"][0];
    let addr = first["address"].as_str().unwrap().to_string();
    assert!(addr.starts_with(&format!("cap:{source}/captions-en.vtt@")), "{addr}");
    let title = first["title"].as_str().unwrap();
    assert!(title.starts_with("Flood Safety Basics, at "), "{title}");
    assert_eq!(first["source_kind"], "video");
    assert_eq!(first["source_title"], "Flood Safety Basics");
    // the citation
    let cites = h.last_cites.clone();
    let (a, c) = cites.iter().find(|(a, _)| *a == addr).unwrap();
    assert_eq!(a, &addr);
    assert_eq!(c.link.as_deref(), Some(format!("https://{HOST}/w/{VIDEO}").as_str()));
    let (t0, t1) = (
        c.time.as_ref().unwrap().as_f64().unwrap(),
        c.time_end.as_ref().unwrap().as_f64().unwrap(),
    );
    assert!(t1 > t0 && t1 - t0 <= 45.0, "{t0} {t1}");
    assert_eq!(c.lang.as_deref(), Some("en"));
    assert!(c.quote.as_ref().unwrap().contains("sandbag barriers"));
    assert_eq!(
        title,
        format!("Flood Safety Basics, at {:02}:{:02}", t0 as u64 / 60, t0 as u64 % 60)
    );
    // read: the passages from 60 s before to 60 s after, one "[mm:ss] text" line each
    let read: Value = serde_json::from_str(&h.read(&addr, 6000).unwrap()).unwrap();
    assert_eq!(read["title"], title);
    let text = read["text"].as_str().unwrap();
    assert!(text.lines().count() >= 2, "{text}");
    for l in text.lines() {
        assert!(
            l.len() > 8 && l.starts_with('[') && &l[3..4] == ":" && &l[6..8] == "] ",
            "{l:?}"
        );
    }
    assert!(text.contains("sandbag barriers"));
    assert!(
        !text.contains("sacs de sable"),
        "another language's file is another item"
    );
    // search restricted by kind
    assert!(
        !search(&mut h, "sandbag barriers", json!({"kinds": ["captions"]}))["results"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    assert!(
        search(&mut h, "sandbag barriers", json!({"kinds": ["zim-epub", "zim"]}))["results"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    // search by caption: grouped per video, the saved flag, the language filter
    let cs: Value = serde_json::from_str(
        &h.captions_search(&json!({"query": "sandbag barriers"}).to_string())
            .unwrap(),
    )
    .unwrap();
    let vids = cs["videos"].as_array().unwrap();
    assert_eq!(vids.len(), 1, "{cs}");
    let vid = &vids[0];
    assert_eq!(
        (
            vid["source_id"].as_str(),
            vid["saved"].as_bool(),
            vid["host"].as_str(),
            vid["title"].as_str()
        ),
        (
            Some(source.as_str()),
            Some(true),
            Some(HOST),
            Some("Flood Safety Basics")
        )
    );
    assert_eq!(vid["link"], format!("https://{HOST}/w/{VIDEO}"));
    let hits = vid["hits"].as_array().unwrap();
    assert!(!hits.is_empty() && hits.len() <= 3);
    assert!(hits[0]["end_s"].as_f64().unwrap() > hits[0]["start_s"].as_f64().unwrap());
    assert_eq!(hits[0]["lang"], "en");
    let none: Value = serde_json::from_str(
        &h.captions_search(&json!({"query": "sandbag barriers", "lang": "fr"}).to_string())
            .unwrap(),
    )
    .unwrap();
    assert!(none["videos"].as_array().unwrap().is_empty());
    let fr: Value = serde_json::from_str(
        &h.captions_search(&json!({"query": "sacs de sable", "lang": "fr"}).to_string())
            .unwrap(),
    )
    .unwrap();
    assert_eq!(fr["videos"][0]["hits"][0]["lang"], "fr");

    // the dl list now says built
    let dl: Value = serde_json::from_str(&h.video_downloads_json().unwrap()).unwrap();
    assert_eq!(
        (
            dl["downloads"][0]["captions_index"]["built"].as_bool(),
            dl["downloads"][0]["captions_index"]["needs_build"].as_bool()
        ),
        (Some(true), Some(false))
    );

    // a deleted video is no longer searched; nothing under snap/ was written by any of this
    assert_eq!(
        tree(&src_dir.join("snap")),
        snap_before,
        "a published snapshot is never written to"
    );
    let mut h2 = open(&[], &idx, &vdir);
    let r2 = loop {
        let r = search(&mut h2, "sandbag barriers", json!({}));
        if !r["results"].as_array().unwrap().is_empty() {
            break r;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert_eq!(
        r2["results"][0]["address"], addr,
        "a fresh handle attaches the same snapshot"
    );
    assert_eq!(tree(&src_dir.join("snap")), snap_before);
    std::fs::remove_dir_all(vdir.join("downloads")).unwrap();
    assert!(search(&mut h2, "sandbag barriers", json!({}))["results"]
        .as_array()
        .unwrap()
        .is_empty());
}

fn h_has_index(idx: &Path, source: &str) -> bool {
    cache_search::kwindex::has_published(
        &cache_search::kwindex::dir_for(idx, "captions", source),
        "captions",
        source,
    )
}

#[test]
fn cancelling_keeps_the_build_and_a_later_run_continues() {
    const VIDEO: &str = "9f2e1c4a-1111-4222-8333-000000000002";
    let t = TempDir::new("cancel");
    let (idx, vdir) = (t.0.join("indexes"), t.0.join("video"));
    save_video(
        &vdir,
        VIDEO,
        "Flood Safety Basics",
        &[("en", vtt_of("sandbag barriers", 30)), ("fr", srt_of("sacs", 8))],
    );
    let source = format!("{HOST}/{VIDEO}");
    let _h = open(&[], &idx, &vdir);
    let mut p = job_params(&idx, "captions", &source);
    p["hold_ms"] = json!(30_000);
    let j = start(p.clone());
    let t0 = Instant::now();
    let mut phases: Vec<String> = Vec::new();
    loop {
        let pr: Value = serde_json::from_str(&j.progress_json()).unwrap();
        if let Some(ph) = pr["phase"].as_str() {
            if phases.last().map(String::as_str) != Some(ph) {
                phases.push(ph.to_string());
            }
            if ph == "merge" {
                break;
            }
        }
        assert!(
            t0.elapsed() < Duration::from_secs(60),
            "never reached the merge: {phases:?}"
        );
        std::thread::sleep(Duration::from_millis(5));
    }
    j.cancel();
    let p1 = wait(&j);
    assert_eq!(p1["state"], "cancelled", "{p1}");
    assert_eq!(phases, ["read", "index", "merge"], "the phases in order");
    let src_dir = idx.join("captions").join(format!("{HOST}%2F{VIDEO}"));
    assert!(src_dir.join(".build").is_dir() && snap_dirs(&src_dir).is_empty());
    p.as_object_mut().unwrap().remove("hold_ms");
    let done = run(p);
    assert_eq!(
        (done["result"]["items"].as_u64(), done["result"]["resumed"].as_u64()),
        (Some(2), Some(2)),
        "{done}"
    );
    assert_eq!(snap_dirs(&src_dir).len(), 1);
}

#[test]
fn job_parameters_are_checked() {
    let t = TempDir::new("params");
    let idx = t.0.join("indexes");
    let code = |p: Value| {
        Job::start("index_source", &p.to_string())
            .err()
            .map(|e| e.code.as_str().to_string())
    };
    assert_eq!(
        code(json!({"indexes_dir": idx, "kind": "nonsense", "source_id": "x"})).as_deref(),
        Some("bad_json")
    );
    assert_eq!(
        code(json!({"indexes_dir": idx, "kind": "captions", "source_id": "nohost"})).as_deref(),
        Some("bad_json")
    );
    assert_eq!(
        code(json!({"indexes_dir": idx, "kind": "captions", "source_id": "a.example/none"})).as_deref(),
        Some("not_found")
    );
    assert_eq!(
        code(json!({"indexes_dir": idx, "kind": "zim-epub", "source_id": "not-a-uuid"})).as_deref(),
        Some("bad_json")
    );
    assert_eq!(
        code(json!({"indexes_dir": idx, "kind": "zim-epub", "source_id": U2})).as_deref(),
        Some("not_found")
    );
    assert_eq!(
        code(json!({"indexes_dir": "", "kind": "captions", "source_id": "a/b"})).as_deref(),
        Some("bad_json")
    );
}

// ---------------------------------------------------------------------------------------------------------
// zim-captions

#[test]
fn zim_captions_skip_hls_pair_videos_and_cite_the_zim() {
    const U1: &str = "0badc0de-0000-4000-8000-000000000a01";
    let t = TempDir::new("zimcap");
    let (idx, vdir) = (t.0.join("indexes"), t.0.join("video"));
    let zim = t.0.join("media.zim");
    write_zim(&zim, U1, "media_test", &media_entries(&[]));
    let mut h = open(&[&zim], &idx, &vdir);

    // status: the scan finds three standalone captions (not the HLS segment) and says it needs a build
    let st = wait_status(&mut h, |v| v["sources"][0]["captionsindex"]["entries"].is_u64());
    let c = &st["sources"][0]["captionsindex"];
    assert_eq!(
        (
            c["entries"].as_u64(),
            c["needs_build"].as_bool(),
            c["source_id"].as_str()
        ),
        (Some(3), Some(true), Some(U1)),
        "{st}"
    );
    assert!(
        st["sources"][0].get("epubindex").is_none(),
        "no EPUBs in this ZIM: no key"
    );

    let mut p = job_params(&idx, "zim-captions", U1);
    p["batch_items"] = json!(1);
    p["crash_after"] = json!(1);
    assert_eq!(wait(&start(p.clone()))["state"], "failed");
    p.as_object_mut().unwrap().remove("crash_after");
    let done = run(p);
    assert_eq!(
        (done["result"]["items"].as_u64(), done["result"]["resumed"].as_u64()),
        (Some(3), Some(1)),
        "{done}"
    );
    let src_dir = idx.join("zim-captions").join(U1);

    let st = wait_status(&mut h, |v| v["sources"][0]["captionsindex"]["state"] == "ready");
    assert_eq!(st["sources"][0]["captionsindex"]["state"], "ready", "{st}");
    let snap_before = tree(&src_dir.join("snap"));

    // the HLS segment words are not indexed
    assert!(
        search(&mut h, "hidden segment words", json!({"kinds": ["zim-captions"]}))["results"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    // a caption with its video: the citation opens the video entry in the ZIM
    let r = search(&mut h, "sandbag barriers", json!({"kinds": ["zim-captions"]}));
    let first = &r["results"][0];
    let addr = first["address"].as_str().unwrap().to_string();
    assert!(
        addr.starts_with(&format!("zimcap:{U1}/Media/FEMA_UHA_video01_en.srt@")),
        "{addr}"
    );
    assert!(
        first["title"].as_str().unwrap().starts_with("FEMA UHA video01, at ")
            || first["title"].as_str().unwrap().contains(", at "),
        "{first}"
    );
    let (_, c) = h.last_cites.iter().find(|(a, _)| *a == addr).unwrap().clone();
    assert_eq!(
        c.link.as_deref(),
        Some(format!("zim:{U1}/Media/FEMA_UHA_video01.mp4").as_str())
    );
    assert_eq!(c.lang.as_deref(), Some("en"));
    assert!(c.time_end.is_some() && c.quote.as_ref().unwrap().contains("sandbag barriers"));
    // a caption without a video: the citation names the caption entry
    let r = search(&mut h, "generator safety", json!({"kinds": ["zim-captions"]}));
    let g = r["results"][0]["address"].as_str().unwrap().to_string();
    let (_, c) = h.last_cites.iter().find(|(a, _)| *a == g).unwrap().clone();
    assert_eq!(c.link.as_deref(), Some(format!("zim:{U1}/Media/other.vtt").as_str()));
    assert_eq!(
        r["results"][0]["title"].as_str().unwrap().split(", at ").next(),
        Some("Standalone talk")
    );
    // read
    let read: Value = serde_json::from_str(&h.read(&addr, 6000).unwrap()).unwrap();
    assert!(
        read["text"].as_str().unwrap().lines().all(|l| l.starts_with('[')),
        "{read}"
    );
    // search by caption: one entry per video, the Spanish file is the same video
    let cs: Value = serde_json::from_str(
        &h.captions_search(&json!({"query": "barreras de sacos"}).to_string())
            .unwrap(),
    )
    .unwrap();
    let v = &cs["videos"][0];
    assert_eq!(
        (v["saved"].as_bool(), v["link"].as_str(), v["source_id"].as_str()),
        (
            Some(false),
            Some(format!("zim:{U1}/Media/FEMA_UHA_video01.mp4").as_str()),
            Some(U1)
        ),
        "{cs}"
    );
    assert_eq!(v["hits"][0]["lang"], "es");
    let both: Value = serde_json::from_str(
        &h.captions_search(&json!({"query": "cue we talk about"}).to_string())
            .unwrap(),
    )
    .unwrap();
    let links: Vec<&str> = both["videos"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v["link"].as_str().unwrap())
        .collect();
    assert_eq!(
        links.iter().filter(|l| l.ends_with("FEMA_UHA_video01.mp4")).count(),
        1,
        "the English and Spanish files are one video: {links:?}"
    );
    assert_eq!(
        tree(&src_dir.join("snap")),
        snap_before,
        "a published snapshot is never written to"
    );
}

// ---------------------------------------------------------------------------------------------------------
// zim-epub

#[test]
fn zim_epub_build_cite_read_serve_and_reuse_across_editions() {
    const U1: &str = "0badc0de-0000-4000-8000-000000000b01";
    const U2: &str = "0badc0de-0000-4000-8000-000000000b02";
    let t = TempDir::new("epub");
    let (idx, vdir) = (t.0.join("indexes"), t.0.join("video"));
    let guide = epub(
        "Field Guide",
        &[
            ("ch1.xhtml", "Floods", "flood", 300),
            ("ch2.xhtml", "Wildfire", "wildfire", 300),
        ],
    );
    let second = epub("Second Book", &[("a.xhtml", "Stoves", "stove", 200)]);
    let third = epub("Third Book", &[("a.xhtml", "Radios", "radio", 200)]);
    let (d1, d2) = (t.0.join("e1"), t.0.join("e2"));
    std::fs::create_dir_all(&d1).unwrap();
    std::fs::create_dir_all(&d2).unwrap();
    let (z1, z2) = (d1.join("media.zim"), d2.join("media.zim"));
    write_zim(
        &z1,
        U1,
        "media_test",
        &media_entries(&[
            ("guide.epub", guide.clone()),
            ("second.epub", second.clone()),
            ("third.epub", third.clone()),
        ]),
    );
    let mut h = open(&[&z1], &idx, &vdir);
    let st = wait_status(&mut h, |v| v["sources"][0]["epubindex"]["entries"].is_u64());
    assert_eq!(
        (
            st["sources"][0]["epubindex"]["entries"].as_u64(),
            st["sources"][0]["epubindex"]["needs_build"].as_bool()
        ),
        (Some(3), Some(true))
    );

    let mut p = job_params(&idx, "zim-epub", U1);
    p["batch_items"] = json!(1);
    p["crash_after"] = json!(2);
    assert_eq!(wait(&start(p.clone()))["state"], "failed");
    p.as_object_mut().unwrap().remove("crash_after");
    let done = run(p);
    assert_eq!(
        (
            done["result"]["items"].as_u64(),
            done["result"]["resumed"].as_u64(),
            done["result"]["skipped"].as_u64()
        ),
        (Some(3), Some(2), Some(0)),
        "{done}"
    );
    let src_dir = idx.join("zim-epub").join(U1);
    assert!(src_dir
        .join("snap")
        .read_dir()
        .unwrap()
        .next()
        .unwrap()
        .unwrap()
        .path()
        .join("epubs.tsv")
        .is_file());
    let st = wait_status(&mut h, |v| v["sources"][0]["epubindex"]["state"] == "ready");
    assert_eq!(st["sources"][0]["epubindex"]["needs_build"], false);
    assert_eq!(st["sources"][0]["epubindex"]["epubs"], 3);
    let snap_before = tree(&src_dir.join("snap"));

    // search and cite
    let r = search(&mut h, "wildfire guidance", json!({"kinds": ["zim-epub"]}));
    let first = &r["results"][0];
    let addr = first["address"].as_str().unwrap().to_string();
    assert!(addr.starts_with(&format!("zimepub:{U1}/Books/guide.epub@")), "{addr}");
    assert_eq!(first["title"], "Field Guide, Wildfire");
    assert_eq!(first["source_kind"], "zim");
    let (_, c) = h.last_cites.iter().find(|(a, _)| *a == addr).unwrap().clone();
    let link = c.link.clone().unwrap();
    let (path, frag) = link.split_once('#').unwrap();
    assert_eq!(path, format!("zim:{U1}/Books/guide.epub!/OEBPS/ch2.xhtml"));
    assert!(frag.starts_with("cache-b"), "{frag}");
    assert!(c.quote.as_ref().unwrap().contains("wildfire"));
    assert!(c.time.is_none());
    // read: the chapter around the passage, with its heading
    let read: Value = serde_json::from_str(&h.read(&addr, 6000).unwrap()).unwrap();
    assert_eq!(read["title"], "Field Guide, Wildfire");
    let text = read["text"].as_str().unwrap();
    assert!(
        text.starts_with("Chapter: Wildfire\n\n") && text.contains("wildfire guidance"),
        "{}",
        &text[..text.len().min(200)]
    );

    // serving: the chapter has the cache-b ids, numbered as the index numbered the blocks; other files come with their types
    let e = h.zim_get(path).unwrap();
    assert_eq!(e.mime, "application/xhtml+xml");
    let html = String::from_utf8(e.bytes).unwrap();
    let id = format!("id=\"{frag}\"");
    let at = html.find(&id).unwrap_or_else(|| panic!("{id} not in {html}"));
    let after = &html[at..];
    let body = after[after.find('>').unwrap() + 1..].split('<').next().unwrap();
    let quote_start: String = c
        .quote
        .as_ref()
        .unwrap()
        .split_whitespace()
        .take(4)
        .collect::<Vec<_>>()
        .join(" ");
    assert!(
        body.contains(&quote_start)
            || c.quote
                .as_ref()
                .unwrap()
                .contains(body.split_whitespace().take(4).collect::<Vec<_>>().join(" ").as_str()),
        "block {frag} starts {body:?}, the quote {quote_start:?}"
    );
    assert!(html.contains("id=\"cache-b0\"") && html.contains("<h1 id=\"cache-b0\">"));
    let css = h
        .zim_get(&format!("zim:{U1}/Books/guide.epub!/OEBPS/style.css"))
        .unwrap();
    assert_eq!(
        (css.mime.as_str(), css.bytes.as_slice()),
        ("text/css", b"p { margin: 0 }".as_slice())
    );
    let png = h.zim_get(&format!("zim:{U1}/Books/guide.epub!/OEBPS/pic.png")).unwrap();
    assert_eq!(png.mime, "image/png");
    assert_eq!(
        h.zim_get(&format!("zim:{U1}/Books/guide.epub!/OEBPS/nope.png"))
            .err()
            .unwrap()
            .code,
        cache_search::ErrorCode::NotFound
    );
    assert_eq!(
        h.zim_get(&format!("zim:{U1}/Books/missing.epub!/a.png"))
            .err()
            .unwrap()
            .code,
        cache_search::ErrorCode::NotFound
    );
    // plain entries are served as before
    assert_eq!(h.zim_get(&format!("zim:{U1}/Alpha")).unwrap().mime, "text/html");
    assert_eq!(
        tree(&src_dir.join("snap")),
        snap_before,
        "a published snapshot is never written to"
    );

    // the next edition: guide.epub is the same file, second.epub changed, third.epub is gone, fourth.epub is new
    let second_v2 = epub("Second Book", &[("a.xhtml", "Stoves", "stove", 260)]);
    let fourth = epub("Fourth Book", &[("a.xhtml", "Tents", "tent", 200)]);
    write_zim(
        &z2,
        U2,
        "media_test",
        &media_entries(&[
            ("guide.epub", guide),
            ("second.epub", second_v2),
            ("fourth.epub", fourth),
        ]),
    );
    let mut h2 = open(&[&z1, &z2], &idx, &vdir);
    let mut p = job_params(&idx, "zim-epub", U2);
    p["previous"] = json!({"zim_uuid": U1});
    let done = run(p);
    assert_eq!(
        (done["result"]["items"].as_u64(), done["result"]["reused"].as_u64()),
        (Some(3), Some(1)),
        "only the unchanged EPUB is copied: {done}"
    );
    let r = loop {
        let r = search(
            &mut h2,
            "wildfire guidance",
            json!({"kinds": ["zim-epub"], "sources": [U2]}),
        );
        if !r["results"].as_array().unwrap().is_empty() {
            break r;
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    assert!(r["results"][0]["address"]
        .as_str()
        .unwrap()
        .starts_with(&format!("zimepub:{U2}/")));
    let radio = search(
        &mut h2,
        "radio guidance",
        json!({"kinds": ["zim-epub"], "sources": [U2]}),
    );
    assert!(
        radio["results"]
            .as_array()
            .unwrap()
            .iter()
            .all(|r| !r["title"].as_str().unwrap().contains("Third Book")),
        "third.epub is not in the new edition"
    );
    assert!(!search(
        &mut h2,
        "tent guidance",
        json!({"kinds": ["zim-epub"], "sources": [U2]})
    )["results"]
        .as_array()
        .unwrap()
        .is_empty());
}

#[test]
fn damaged_and_empty_epubs_are_skipped_not_fatal() {
    const U1: &str = "0badc0de-0000-4000-8000-000000000c01";
    let t = TempDir::new("badepub");
    let (idx, vdir) = (t.0.join("indexes"), t.0.join("video"));
    let zim = t.0.join("media.zim");
    let good = epub("Good", &[("a.xhtml", "Ok", "sturdy", 200)]);
    let empty = epub("Empty", &[]);
    write_zim(
        &zim,
        U1,
        "media_test",
        &media_entries(&[
            ("good.epub", good),
            ("broken.epub", b"this is not a zip".to_vec()),
            ("empty.epub", empty),
        ]),
    );
    let _h = open(&[&zim], &idx, &vdir);
    let done = run(job_params(&idx, "zim-epub", U1));
    assert_eq!(
        (done["result"]["items"].as_u64(), done["result"]["skipped"].as_u64()),
        (Some(1), Some(2)),
        "{done}"
    );
    let snap = snap_dirs(&idx.join("zim-epub").join(U1));
    let tsv = std::fs::read_to_string(snap[0].join("epubs.tsv")).unwrap();
    assert!(
        tsv.contains("Books/broken.epub") && tsv.contains("skipped:damaged") && tsv.contains("skipped:no_text"),
        "{tsv}"
    );
}

#[test]
fn the_header_decides_which_zims_are_walked() {
    const SMALL: &str = "0badc0de-0000-4000-8000-000000000d01";
    const WITH_VTT: &str = "0badc0de-0000-4000-8000-000000000d02";
    const BIG: &str = "0badc0de-0000-4000-8000-000000000d03";
    const NONE: &str = "0badc0de-0000-4000-8000-000000000d04";
    let t = TempDir::new("nowalk");
    let (idx, vdir) = (t.0.join("indexes"), t.0.join("video"));
    let generic = ["text/html", "text/plain", "application/octet-stream"];
    let entries = || {
        vec![
            (
                "Alpha",
                "Alpha",
                "text/html",
                b"<html><body><p>Alpha.</p></body></html>".to_vec(),
            ),
            (
                "Media/talk_en.srt",
                "",
                "application/octet-stream",
                srt_of("octet words", 8),
            ),
        ]
    };
    // small, with only generic types (as ready.gov: its two SRTs are octet-stream): walked, the .srt is found
    let small = t.0.join("small.zim");
    write_zim_mimes(&small, SMALL, "small", &entries(), &generic);
    // a caption type in the list: walked, and the octet-stream .srt is counted beside the .vtt
    let withvtt = t.0.join("withvtt.zim");
    write_zim_mimes(
        &withvtt,
        WITH_VTT,
        "withvtt",
        &[
            ("Media/a.vtt", "", "text/vtt", vtt_of("vtt words", 8)),
            (
                "Media/talk_en.srt",
                "",
                "application/octet-stream",
                srt_of("octet words", 8),
            ),
        ],
        &["text/html", "text/plain", "application/octet-stream", "text/vtt"],
    );
    // the same as the small one, plus 500,000 filler entries (so the header says more than 500,000): not walked
    let big = t.0.join("big.zim");
    let mut many = entries();
    for i in 0..500_000 {
        let path: &'static str = Box::leak(format!("f/{i:06}").into_boxed_str());
        many.push((path, "", "text/html", b"x".to_vec()));
    }
    write_zim_mimes(&big, BIG, "big", &many, &generic);
    // no generic or caption type at all: not walked, whatever the size
    let none = t.0.join("none.zim");
    write_zim_mimes(&none, NONE, "none", &entries()[..1], &["text/html", "application/pdf"]);

    let mut h = open(&[&small, &withvtt, &big, &none], &idx, &vdir);
    let t0 = Instant::now();
    while ![SMALL, WITH_VTT, BIG, NONE]
        .iter()
        .all(|u| cache_search::kwslot::scan_finished(u))
    {
        let _ = h.status_json();
        assert!(t0.elapsed() < Duration::from_secs(60), "the scans never finished");
        std::thread::sleep(Duration::from_millis(10));
    }
    let st: Value = serde_json::from_str(&h.status_json()).unwrap();
    let by_id = |id: &str| {
        st["sources"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["id"] == id)
            .unwrap()
            .clone()
    };
    assert!(cache_search::kwbuild::was_walked(SMALL));
    assert_eq!(by_id(SMALL)["captionsindex"]["entries"], 1, "{st}");
    assert_eq!(by_id(SMALL)["captionsindex"]["needs_build"], true);
    assert!(by_id(SMALL).get("epubindex").is_none());
    assert!(cache_search::kwbuild::was_walked(WITH_VTT));
    assert_eq!(by_id(WITH_VTT)["captionsindex"]["entries"], 2, "{st}");
    assert!(
        !cache_search::kwbuild::was_walked(BIG),
        "over 500,000 entries with only generic types: no walk"
    );
    assert!(by_id(BIG).get("captionsindex").is_none() && by_id(BIG).get("epubindex").is_none());
    assert!(
        !cache_search::kwbuild::was_walked(NONE),
        "no generic or caption type: no walk"
    );
    assert!(by_id(NONE).get("captionsindex").is_none());
}

#[test]
fn index_source_is_gentle_by_default_and_takes_a_duty() {
    const VIDEO: &str = "9f2e1c4a-1111-4222-8333-000000000077";
    let t = TempDir::new("duty");
    let (idx, vdir) = (t.0.join("indexes"), t.0.join("video"));
    save_video(&vdir, VIDEO, "Duty", &[("en", vtt_of("sandbag barriers", 30))]);
    let _h = open(&[], &idx, &vdir);
    let source = format!("{HOST}/{VIDEO}");
    // like the other index kinds: work 200 ms, idle 200 ms, one writer thread, unless the caller says otherwise
    let p = run(job_params(&idx, "captions", &source));
    assert_eq!(p["duty"], json!({"work_ms": 200, "idle_ms": 200, "threads": 1}), "{p}");
    assert_eq!((p["auto"].clone(), p["paused"].clone()), (json!(true), json!(false)));
    let mut again = job_params(&idx, "captions", &source);
    again["duty"] = json!({"work_ms": 0});
    let p = run(again);
    assert_eq!(p["duty"], json!({"work_ms": 0, "idle_ms": 200, "threads": 1}), "{p}");
    // a running index_source job can be paused and resumed
    let t2 = TempDir::new("duty-pause");
    let (idx2, vdir2) = (t2.0.join("indexes"), t2.0.join("video"));
    save_video(&vdir2, VIDEO, "Duty", &[("en", vtt_of("sandbag barriers", 30))]);
    let _h2 = open(&[], &idx2, &vdir2);
    let mut slow = job_params(&idx2, "captions", &source);
    slow["duty"] = json!({"work_ms": 1, "idle_ms": 60_000});
    let j = start(slow);
    j.set_duty(r#"{"paused": true}"#).unwrap();
    std::thread::sleep(Duration::from_millis(200));
    let p: Value = serde_json::from_str(&j.progress_json()).unwrap();
    assert!(p["state"] == "running" || p["state"] == "done", "{p}");
    j.set_duty(r#"{"paused": false, "work_ms": 0, "idle_ms": 0}"#).unwrap();
    let p = wait(&j);
    assert_eq!(p["state"], "done", "{p}");
}
