//! Integration test through the C ABI against real ZIMs. Runs only when CS_TEST_ZIM_DIR is set.

use cache_search::ffi::*;
use serde_json::Value;
use std::ffi::{c_char, CStr, CString};
use std::ptr;

const READY: &str = "17e9fb54-9554-d2cd-e15f-17cf750882d1";
const WIKI: &str = "53a8f711-f7f9-ec23-08fc-38fcf579ba32";

fn zim_dir() -> Option<String> {
    std::env::var("CS_TEST_ZIM_DIR").ok().filter(|s| !s.is_empty())
}

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn last_code(h: *mut cache_search::handle::Handle) -> String {
    let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(h) }).expect("an error")).unwrap();
    e["code"].as_str().unwrap().to_string()
}

struct Got {
    bytes: Vec<u8>,
    mime: String,
}

fn get(h: *mut cache_search::handle::Handle, addr: &str) -> Option<Got> {
    let a = CString::new(addr).unwrap();
    let (mut m, mut n): (*mut c_char, i64) = (ptr::null_mut(), 0);
    let p = unsafe { cs_zim_get(h, a.as_ptr(), &mut m, &mut n) };
    if p.is_null() {
        assert!(m.is_null());
        return None;
    }
    let bytes = unsafe { std::slice::from_raw_parts(p, n as usize) }.to_vec();
    unsafe { cs_free_bytes(p, n) };
    Some(Got { bytes, mime: take(m).unwrap() })
}

#[test]
fn zims_through_the_c_abi() {
    let Some(dir) = zim_dir() else {
        eprintln!("CS_TEST_ZIM_DIR not set: skipping");
        return;
    };
    let ready = format!("{dir}/www.ready.gov_en_2024-12.zim");
    let wiki = format!("{dir}/wikipedia_en_all_maxi_2026-02.zim");
    let cfg = serde_json::json!({"sources":[
        {"kind":"zim","path":ready,"index_dir":"/tmp/none-ready.idx"},
        {"kind":"zim","path":wiki,"index_dir":"/tmp/none-wiki.idx"},
        {"kind":"pack","path":"/tmp/none.cachepack","index_dir":"/tmp/none-pack.idx"}
    ]})
    .to_string();
    let cfg = CString::new(cfg).unwrap();
    let h = unsafe { cs_open(cfg.as_ptr()) };
    assert!(!h.is_null());

    // status
    let st: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
    let src = st["sources"].as_array().unwrap();
    assert_eq!(src.len(), 3);
    assert_eq!(src[0]["id"], READY);
    assert_eq!(src[1]["id"], WIKI);
    for s in &src[..2] {
        assert_eq!(s["kind"], "zim");
        assert_eq!(s["indexed"], false);
        assert_eq!(s["building"], false);
        assert_eq!(s["stale"], false);
        assert!(s["embedding_model"].is_null());
        assert!(s["docs"].as_u64().unwrap() > 1000);
        assert!(!s["title"].as_str().unwrap().is_empty());
    }
    assert_eq!(src[0]["docs"], 6738);
    assert_eq!(src[1]["docs"], 27199921u64);
    assert_eq!(src[2]["kind"], "pack");
    assert_eq!(src[2]["indexed"], false);
    eprintln!("status: {}", serde_json::to_string(&st).unwrap());

    // main pages
    for id in [READY, WIKI] {
        let id_c = CString::new(id).unwrap();
        let mp: Value = serde_json::from_str(&take(unsafe { cs_zim_main_page(h, id_c.as_ptr()) }).unwrap()).unwrap();
        let addr = mp["address"].as_str().unwrap();
        assert!(addr.starts_with(&format!("zim:{id}/")), "{addr}");
        let g = get(h, addr).expect("main page reads");
        assert_eq!(g.mime, "text/html", "{addr}");
        assert!(g.bytes.len() > 1000);
        eprintln!("main page {addr}: {} bytes", g.bytes.len());
    }

    // big article
    let g = get(h, &format!("zim:{WIKI}/Water_purification")).unwrap();
    assert_eq!(g.mime, "text/html");
    assert!(g.bytes.len() > 100 * 1024, "{}", g.bytes.len());
    assert!(String::from_utf8_lossy(&g.bytes).contains("<html"));

    // redirect "!" -> Exclamation_mark
    let r = get(h, &format!("zim:{WIKI}/!")).unwrap();
    let t = get(h, &format!("zim:{WIKI}/Exclamation_mark")).unwrap();
    assert_eq!(r.mime, "text/html");
    assert_eq!(r.bytes, t.bytes);

    // images: PNG named png, and a .png name holding webp
    let g = get(h, &format!("zim:{READY}/community.fema.gov/PreparednessCommunity/resource/1596560909000/us_flag_small")).unwrap();
    assert_eq!(g.mime, "image/png");
    assert_eq!(&g.bytes[..8], &[0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]);
    let g = get(h, &format!("zim:{WIKI}/_assets_/0024e4dee1e3e9c6c1c65d7b022461fe/6q5x1f57.png")).unwrap();
    assert_eq!(g.mime, "image/webp");
    assert_eq!(&g.bytes[..4], b"RIFF");
    assert_eq!(&g.bytes[8..12], b"WEBP");

    // css
    let g = get(h, &format!("zim:{WIKI}/_mw_/codex-styles.css")).unwrap();
    assert_eq!(g.mime, "text/css");

    // missing path -> not_found; uppercase uuid works
    assert!(get(h, &format!("zim:{WIKI}/No_such_article_zzzz")).is_none());
    assert_eq!(last_code(h), "not_found");
    assert!(get(h, &format!("zim:{}/Water_purification", WIKI.to_uppercase())).is_some());
    // unknown zim id -> not_found
    assert!(get(h, "zim:00000000-0000-0000-0000-000000000000/x").is_none());
    assert_eq!(last_code(h), "not_found");
    // malformed addresses -> bad_json
    for bad in ["garbage", "zim:", "zim:xyz/abc", &format!("zim:{WIKI}"), &format!("pack:{WIKI}/1")] {
        assert!(get(h, bad).is_none(), "{bad}");
        assert_eq!(last_code(h), "bad_json", "{bad}");
    }
    // pack address is not a zim address
    let bad = CString::new("00000000-0000-0000-0000-000000000000").unwrap();
    assert!(unsafe { cs_zim_main_page(h, bad.as_ptr()) }.is_null());
    assert_eq!(last_code(h), "not_found");

    // set_sources: drop wikipedia, keep ready (reused)
    let cfg2 = CString::new(serde_json::json!({"sources":[{"kind":"zim","path":ready}]}).to_string()).unwrap();
    assert_eq!(unsafe { cs_set_sources(h, cfg2.as_ptr()) }, 0);
    assert!(get(h, &format!("zim:{WIKI}/Water_purification")).is_none());
    assert_eq!(last_code(h), "not_found");
    // failed set_sources leaves the list unchanged
    let cfg3 = CString::new(r#"{"sources":[{"kind":"zim","path":"/nonexistent.zim"}]}"#).unwrap();
    assert_eq!(unsafe { cs_set_sources(h, cfg3.as_ptr()) }, -1);
    assert_eq!(last_code(h), "not_found");
    let st: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
    assert_eq!(st["sources"].as_array().unwrap().len(), 1);

    // repeated get/free loop: no growth in resident memory
    let before = rss_kb();
    for _ in 0..200 {
        let g = get(h, &format!("zim:{READY}/community.fema.gov/PreparednessCommunity/resource/1596560909000/us_flag_small")).unwrap();
        assert_eq!(g.bytes.len(), 176);
    }
    let after = rss_kb();
    eprintln!("rss before {before} kB, after {after} kB");
    assert!(after < before + 50_000);

    unsafe { cs_close(h) };
}

#[test]
fn missing_zim_fails_open_with_not_found() {
    let cfg = CString::new(r#"{"sources":[{"kind":"zim","path":"/nonexistent/x.zim"}]}"#).unwrap();
    let h = unsafe { cs_open(cfg.as_ptr()) };
    assert!(h.is_null());
    assert_eq!(last_code(ptr::null_mut()), "not_found");
}

fn rss_kb() -> u64 {
    std::fs::read_to_string("/proc/self/status")
        .ok()
        .and_then(|s| s.lines().find(|l| l.starts_with("VmRSS:")).map(|l| l.to_string()))
        .and_then(|l| l.split_whitespace().nth(1).and_then(|n| n.parse().ok()))
        .unwrap_or(0)
}
