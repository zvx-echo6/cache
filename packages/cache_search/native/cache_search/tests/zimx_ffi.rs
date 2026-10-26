//! A ZIM's built-in Xapian index (libzim, feature `xapian`) through the C ABI, and the Tantivy fallback for a ZIM
//! without one.
//!
//! - The tiny-ZIM tests build a ZIM file here (no committed binary) that has no full-text index; they run everywhere.
//! - The real-ZIM tests need CS_TEST_ZIM_DIR (the folder with www.ready.gov_en_2024-12.zim) and a build with the
//!   `xapian` feature on Windows/Android; otherwise they print why and return.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::time::{Duration, Instant};

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn open(sources: Vec<Value>) -> *mut Handle {
    let cfg = cstr(&json!({"sources": sources}).to_string());
    let h = unsafe { cs_open(cfg.as_ptr()) };
    assert!(!h.is_null(), "cs_open failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    h
}

fn status(h: *mut Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap()
}

fn search(h: *mut Handle, q: &str, opts: Value) -> Value {
    let r = take(unsafe { cs_search(h, cstr(q).as_ptr(), cstr(&opts.to_string()).as_ptr()) });
    serde_json::from_str(&r.unwrap_or_else(|| panic!("search failed for {q:?}: {:?}", take(unsafe { cs_last_error(h) })))).unwrap()
}

fn suggest(h: *mut Handle, prefix: &str, k: usize) -> Value {
    let r = take(unsafe { cs_suggest(h, cstr(prefix).as_ptr(), cstr(&json!({"k": k}).to_string()).as_ptr()) });
    serde_json::from_str(&r.expect("suggest result")).unwrap()
}

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-zimx-{}-{}", std::process::id(), name));
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

// ---- a tiny ZIM without a full-text or title index -------------------------------------------------------------

const TINY_UUID: &str = "0badc0de-0000-4000-8000-00000000cafe";

/// Write a minimal valid ZIM (major 6, minor 1: the `C` namespace for content, `M` for metadata): articles in one
/// uncompressed cluster, no `X/` index entries. libzim reports `hasFulltextIndex() == false` for it.
fn write_tiny_zim(path: &Path) {
    // (namespace, path, title, mime index, body), sorted by (namespace, path)
    let mut entries: Vec<(u8, &str, &str, u16, Vec<u8>)> = vec![
        (b'C', "Alpha", "Alpha", 0, b"<html><body><p>Alpha is the first letter. It has nothing to do with water.</p></body></html>".to_vec()),
        (b'C', "Flood_notes", "Flood notes", 0, b"<html><body><h1>Flood notes</h1><p>A flood is water where it should not be. Move to higher ground before the flood arrives. Keep a bag ready.</p></body></html>".to_vec()),
        (b'C', "Zebra", "Zebra", 0, b"<html><body><p>Zebras have stripes.</p></body></html>".to_vec()),
        (b'M', "Language", "Language", 1, b"eng".to_vec()),
        (b'M', "Title", "Title", 1, b"Tiny".to_vec()),
    ];
    entries.sort_by(|a, b| (a.0, a.1).cmp(&(b.0, b.1)));
    let n = entries.len();

    let mime = b"text/html\0text/plain\0\0".to_vec();
    let mime_pos = 80u64;
    let url_ptr_pos = mime_pos + mime.len() as u64;
    let title_ptr_pos = url_ptr_pos + 8 * n as u64;
    let cluster_ptr_pos = title_ptr_pos + 4 * n as u64;
    let cluster_pos = cluster_ptr_pos + 8;

    // one cluster: info byte 1 (no compression, 4-byte offsets), n+1 offsets, then the blobs
    let mut cluster = vec![1u8];
    let mut off = (4 * (n + 1)) as u32;
    let mut offs = Vec::new();
    for e in &entries {
        offs.push(off);
        off += e.4.len() as u32;
    }
    offs.push(off);
    for o in &offs {
        cluster.extend_from_slice(&o.to_le_bytes());
    }
    for e in &entries {
        cluster.extend_from_slice(&e.4);
    }

    let entries_pos = cluster_pos + cluster.len() as u64;
    let mut dirents: Vec<u8> = Vec::new();
    let mut entry_pos: Vec<u64> = Vec::new();
    for (i, e) in entries.iter().enumerate() {
        entry_pos.push(entries_pos + dirents.len() as u64);
        dirents.extend_from_slice(&e.3.to_le_bytes()); // mime type
        dirents.push(0); // extra parameters length
        dirents.push(e.0); // namespace
        dirents.extend_from_slice(&0u32.to_le_bytes()); // revision
        dirents.extend_from_slice(&0u32.to_le_bytes()); // cluster number
        dirents.extend_from_slice(&(i as u32).to_le_bytes()); // blob number
        dirents.extend_from_slice(e.1.as_bytes());
        dirents.push(0);
        dirents.extend_from_slice(e.2.as_bytes());
        dirents.push(0);
    }
    let checksum_pos = entries_pos + dirents.len() as u64;

    // title pointer list: entry indexes ordered by (namespace, title)
    let mut by_title: Vec<u32> = (0..n as u32).collect();
    by_title.sort_by(|a, b| {
        let (x, y) = (&entries[*a as usize], &entries[*b as usize]);
        (x.0, x.2).cmp(&(y.0, y.2))
    });

    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(&0x044D495Au32.to_le_bytes());
    out.extend_from_slice(&6u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    let uuid: Vec<u8> = (0..16).map(|i| u8::from_str_radix(&TINY_UUID.replace('-', "")[2 * i..2 * i + 2], 16).unwrap()).collect();
    out.extend_from_slice(&uuid);
    out.extend_from_slice(&(n as u32).to_le_bytes());
    out.extend_from_slice(&1u32.to_le_bytes());
    for v in [url_ptr_pos, title_ptr_pos, cluster_ptr_pos, mime_pos] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&u32::MAX.to_le_bytes()); // main page: none
    out.extend_from_slice(&u32::MAX.to_le_bytes()); // layout page: none
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
    out.extend_from_slice(&[0u8; 16]); // checksum (not verified on open)
    std::fs::write(path, out).unwrap();
}

fn wait_job(j: *mut cache_search::job::Job) -> Value {
    let t0 = Instant::now();
    loop {
        let p: Value = serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap();
        if p["state"] != "running" {
            return p;
        }
        assert!(t0.elapsed() < Duration::from_secs(120), "job timed out: {p}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[test]
fn a_zim_without_a_fulltext_index_falls_back_to_tantivy() {
    let tmp = TempDir::new("tiny");
    let zim = tmp.0.join("tiny.zim");
    let idx = tmp.0.join("tiny.idx");
    write_tiny_zim(&zim);
    let (zim_s, idx_s) = (zim.to_str().unwrap().to_string(), idx.to_str().unwrap().to_string());
    let h = open(vec![json!({"kind": "zim", "path": zim_s, "index_dir": idx_s})]);

    // not indexed yet: no Xapian index to use, and no Tantivy index either (no keyword_source field for these)
    let st = status(h);
    let s = &st["sources"][0];
    assert_eq!(s["id"], TINY_UUID, "{st}");
    assert_eq!(s["title"], "Tiny");
    assert_eq!(s["indexed"], false, "{s}");
    assert!(s.get("keyword_source").is_none(), "{s}");
    assert_eq!(search(h, "flood", json!({}))["results"].as_array().unwrap().len(), 0);

    // build the Tantivy index; the source is then searched through it, as before
    let params = cstr(&json!({"zim_path": zim_s, "index_dir": idx_s, "heap_mb": 50}).to_string());
    let j = unsafe { cs_job_start(cstr("index_zim").as_ptr(), params.as_ptr()) };
    assert!(!j.is_null(), "{:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    let p = wait_job(j);
    unsafe { cs_job_free(j) };
    assert_eq!(p["state"], "done", "{p}");

    let st = status(h);
    assert_eq!(st["sources"][0]["indexed"], true, "{st}");
    assert!(st["sources"][0].get("keyword_source").is_none(), "{st}");
    let r = search(h, "flood", json!({"k": 3}));
    let first = &r["results"][0];
    assert_eq!(first["address"], format!("zim:{TINY_UUID}/Flood_notes"), "{r}");
    assert_eq!(first["title"], "Tiny: Flood notes");
    assert!(first["snippet"].as_str().unwrap().contains("flood"), "{first}");
    assert_eq!(first["source_kind"], "zim");

    // suggest has no title index in this ZIM, so it uses the Tantivy path too
    let s = suggest(h, "flo", 5);
    assert_eq!(s["suggestions"][0]["title"], "Flood notes", "{s}");
    unsafe { cs_close(h) };
}

// ---- libzim (feature xapian) -----------------------------------------------------------------------------------

#[cfg(zimx)]
mod xapian {
    use super::*;
    use cache_search::zimx::{selftest_throw, version, Zimx};
    use cache_search::ErrorCode;

    const READY: &str = "17e9fb54-9554-d2cd-e15f-17cf750882d1";

    fn ready_zim() -> Option<String> {
        let Some(dir) = std::env::var("CS_TEST_ZIM_DIR").ok().filter(|s| !s.is_empty()) else {
            eprintln!("CS_TEST_ZIM_DIR not set: skipping the real-ZIM Xapian test");
            return None;
        };
        Some(format!("{dir}/www.ready.gov_en_2024-12.zim"))
    }

    #[test]
    fn the_shim_is_libzim_9_8_2() {
        assert_eq!(version(), "9.8.2");
    }

    #[test]
    fn a_c_plus_plus_exception_becomes_an_error() {
        for mode in 0..=2 {
            let e = selftest_throw(mode).expect_err("a throw must come back as an error");
            assert_eq!(e.code, ErrorCode::Internal, "mode {mode}");
            assert!(e.message.starts_with("libzim: "), "mode {mode}: {}", e.message);
        }
        assert!(selftest_throw(9).is_ok());
        // a real libzim exception: a file that is not a ZIM
        let tmp = TempDir::new("notzim");
        let p = tmp.0.join("not.zim");
        std::fs::write(&p, b"this is not a zim file at all, just text that is long enough to read a header from....").unwrap();
        let e = Zimx::open(&p).err().expect("not a ZIM");
        assert_eq!(e.code, ErrorCode::Io);
        assert!(e.message.contains("libzim"), "{}", e.message);
        // and one that does not exist
        assert!(Zimx::open(&tmp.0.join("missing.zim")).is_err());
    }

    #[test]
    fn the_tiny_zim_has_no_builtin_index_for_libzim_either() {
        let tmp = TempDir::new("tinyx");
        let zim = tmp.0.join("tiny.zim");
        write_tiny_zim(&zim);
        let z = Zimx::open(&zim).unwrap();
        assert!(!z.has_fulltext() && !z.has_title_index());
        // searching without an index is an error from libzim, not a crash
        assert!(z.search("flood", 0, 5).is_err());
    }

    #[test]
    fn scores_are_percentages_and_the_total_is_an_estimate_on_ready_gov() {
        let Some(ready) = ready_zim() else { return };
        let z = Zimx::open(Path::new(&ready)).unwrap();
        // the score is a percentage and the best hit of a query is 100
        let (hits, total) = z.search("flood", 0, 10).unwrap();
        assert!(total >= hits.len() && !hits.is_empty());
        assert_eq!(hits[0].score, 100, "{:?}", hits[0]);
        assert!(hits.iter().all(|h| (0..=100).contains(&h.score) && h.score <= hits[0].score));
    }

    #[test]
    fn xapian_search_status_and_suggest_on_ready_gov() {
        let Some(ready) = ready_zim() else { return };
        // no index_dir at all: the ZIM's own index is the keyword index
        let h = open(vec![json!({"kind": "zim", "path": ready})]);
        let st = status(h);
        let s = &st["sources"][0];
        assert_eq!(s["id"], READY, "{st}");
        assert_eq!(s["indexed"], true, "{s}");
        assert_eq!(s["building"], false);
        assert_eq!(s["stale"], false);
        assert_eq!(s["keyword_source"], "own", "{s}");
        assert!(s["error"].is_null());
        let zim_title = s["title"].as_str().unwrap().to_string();

        // "builtin_index": false keeps the source on Tantivy: with no index_dir it is not searchable, and has no keyword_source
        let off = open(vec![json!({"kind": "zim", "path": ready, "builtin_index": false})]);
        let so = status(off);
        assert_eq!(so["sources"][0]["indexed"], false, "{so}");
        assert!(so["sources"][0].get("keyword_source").is_none());
        assert_eq!(search(off, "flood", json!({}))["results"].as_array().unwrap().len(), 0);
        assert_eq!(suggest(off, "flo", 5)["suggestions"].as_array().unwrap().len(), 0);
        unsafe { cs_close(off) };

        let t0 = Instant::now();
        let r = search(h, "flood", json!({"k": 5}));
        eprintln!("xapian search 'flood' (first call, opens libzim): {:?}", t0.elapsed());
        let results = r["results"].as_array().unwrap();
        assert_eq!(results.len(), 5, "{r}");
        assert!(r["total_estimate"].as_u64().unwrap() >= 5);
        assert_eq!(r["keyword_only_sources"], json!([READY]));
        let mut addresses = Vec::new();
        for x in results {
            let a = x["address"].as_str().unwrap();
            assert!(a.starts_with(&format!("zim:{READY}/")), "{a}");
            assert_eq!(x["source_id"], READY);
            assert_eq!(x["source_kind"], "zim");
            assert_eq!(x["source_title"], zim_title.as_str());
            assert!(x["title"].as_str().unwrap().starts_with(&format!("{zim_title}: ")), "{x}");
            let snip = x["snippet"].as_str().unwrap();
            assert!(!snip.is_empty() && snip.chars().count() <= 400, "{x}");
            assert!(!snip.contains('<') && !snip.contains("&amp;") && !snip.starts_with("..."), "{x}");
            assert!(x["page"].is_null());
            addresses.push(a.to_string());
        }
        assert!(results.iter().any(|x| x["snippet"].as_str().unwrap().to_lowercase().contains("flood")), "{r}");
        let t0 = Instant::now();
        let again = search(h, "flood", json!({"k": 5}));
        eprintln!("xapian search 'flood' (warm): {:?}", t0.elapsed());
        assert_eq!(again["results"], r["results"], "same query, same answer");

        // paging: the second page continues the first
        let p2 = search(h, "flood", json!({"k": 5, "offset": 5}));
        let both = search(h, "flood", json!({"k": 10}));
        let a = |v: &Value| -> Vec<String> { v["results"].as_array().unwrap().iter().map(|x| x["address"].as_str().unwrap().to_string()).collect() };
        assert_eq!([addresses.clone(), a(&p2)].concat(), a(&both));

        // a result address is readable and the entry is gettable with the existing reader
        let rd = take(unsafe { cs_read(h, cstr(&addresses[0]).as_ptr(), 2000) }).expect("read");
        let rd: Value = serde_json::from_str(&rd).unwrap();
        assert!(!rd["text"].as_str().unwrap().is_empty());
        let (mut m, mut n): (*mut c_char, i64) = (ptr::null_mut(), 0);
        let got = unsafe { cs_zim_get(h, cstr(&addresses[0]).as_ptr(), &mut m, &mut n) };
        assert!(!got.is_null(), "{:?}", take(unsafe { cs_last_error(h) }));
        unsafe { cs_free_bytes(got, n) };
        assert!(take(m).unwrap().starts_with("text/html"));

        // a query with Xapian syntax errors still answers (the words are searched)
        let odd = search(h, "flood \"(", json!({"k": 3}));
        assert!(!odd["results"].as_array().unwrap().is_empty(), "{odd}");

        // suggest uses the ZIM's title index
        let s = suggest(h, "flo", 5);
        let titles: Vec<&str> = s["suggestions"].as_array().unwrap().iter().map(|x| x["title"].as_str().unwrap()).collect();
        // the ZIM's own title is "Floods | Ready.gov"
        assert_eq!(titles[0], "Floods | Ready.gov", "{s}");
        let sg = &s["suggestions"][0];
        assert!(sg["address"].as_str().unwrap().starts_with(&format!("zim:{READY}/")));
        assert_eq!(sg["source_id"], READY);
        unsafe { cs_close(h) };
    }

    /// A ZIM with Xapian and one without it side by side: each is searched by its own engine, one merged list.
    #[test]
    fn xapian_and_tantivy_sources_merge_in_one_list() {
        let Some(ready) = ready_zim() else { return };
        let tmp = TempDir::new("mixed");
        let zim = tmp.0.join("tiny.zim");
        let idx = tmp.0.join("tiny.idx");
        write_tiny_zim(&zim);
        let (zim_s, idx_s) = (zim.to_str().unwrap().to_string(), idx.to_str().unwrap().to_string());
        let params = cstr(&json!({"zim_path": zim_s, "index_dir": idx_s, "heap_mb": 50}).to_string());
        let j = unsafe { cs_job_start(cstr("index_zim").as_ptr(), params.as_ptr()) };
        assert_eq!(wait_job(j)["state"], "done");
        unsafe { cs_job_free(j) };
        let h = open(vec![json!({"kind": "zim", "path": ready}), json!({"kind": "zim", "path": zim_s, "index_dir": idx_s})]);
        let r = search(h, "flood", json!({"k": 10}));
        let from: Vec<&str> = r["results"].as_array().unwrap().iter().map(|x| x["source_id"].as_str().unwrap()).collect();
        assert!(from.contains(&READY) && from.contains(&TINY_UUID), "{r}");
        // the tiny ZIM's only flood article is its best hit (normalised score 1.0) and ranks with the Xapian best
        assert!(from[..2].contains(&TINY_UUID), "{r}");
        unsafe { cs_close(h) };
    }
}
