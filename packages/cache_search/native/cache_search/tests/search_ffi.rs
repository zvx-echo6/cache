//! Integration tests for indexing jobs, search and read through the C ABI.
//! Run only when CS_TEST_ZIM_DIR and CS_TEST_IDX_DIR are set.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::job::Job;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::ptr;
use std::time::{Duration, Instant};

const READY: &str = "17e9fb54-9554-d2cd-e15f-17cf750882d1";

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|s| !s.is_empty())
}

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn thread_code() -> String {
    let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(ptr::null_mut()) }).expect("an error")).unwrap();
    e["code"].as_str().unwrap().to_string()
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn job_start(params: Value) -> *mut Job {
    unsafe { cs_job_start(cstr("index_zim").as_ptr(), cstr(&params.to_string()).as_ptr()) }
}

fn progress(j: *mut Job) -> Value {
    serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap()
}

fn wait_not_running(j: *mut Job) -> Value {
    let t0 = Instant::now();
    loop {
        let p = progress(j);
        if p["state"] != "running" {
            return p;
        }
        assert!(t0.elapsed() < Duration::from_secs(1200), "job timed out: {p}");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn index_fully(zim: &str, dir: &str) -> Value {
    let j = job_start(json!({"zim_path": zim, "index_dir": dir, "heap_mb": 200}));
    assert!(!j.is_null());
    let p = wait_not_running(j);
    unsafe { cs_job_free(j) };
    p
}

fn open(sources: Vec<Value>) -> *mut Handle {
    let cfg = cstr(&json!({"sources": sources}).to_string());
    let h = unsafe { cs_open(cfg.as_ptr()) };
    assert!(!h.is_null());
    h
}

fn status(h: *mut Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap()
}

fn search(h: *mut Handle, q: &str, opts: Value) -> Value {
    let r = take(unsafe { cs_search(h, cstr(q).as_ptr(), cstr(&opts.to_string()).as_ptr()) });
    serde_json::from_str(&r.unwrap_or_else(|| panic!("search failed for {q:?}: {:?}", take(unsafe { cs_last_error(h) })))).unwrap()
}

fn addrs(r: &Value) -> Vec<String> {
    r["results"].as_array().unwrap().iter().map(|x| x["address"].as_str().unwrap().to_string()).collect()
}

fn has_tag(s: &str) -> bool {
    let b = s.as_bytes();
    (0..b.len().saturating_sub(1)).any(|i| b[i] == b'<' && (b[i + 1].is_ascii_alphabetic() || b[i + 1] == b'/' || b[i + 1] == b'!'))
}

fn docs_of(h: *mut Handle, id: &str) -> u64 {
    let st = status(h);
    let s = st["sources"].as_array().unwrap().iter().find(|s| s["id"] == id).expect("source");
    assert_eq!(s["indexed"], true, "{s}");
    s["docs"].as_u64().unwrap()
}

#[test]
fn index_search_read() {
    let (Some(zd), Some(id)) = (env("CS_TEST_ZIM_DIR"), env("CS_TEST_IDX_DIR")) else {
        eprintln!("CS_TEST_ZIM_DIR / CS_TEST_IDX_DIR not set: skipping");
        return;
    };
    let ready = format!("{zd}/www.ready.gov_en_2024-12.zim");
    let nhs = format!("{zd}/nhs.uk_en_medicines_2025-12.zim");
    let d_ready = format!("{id}/ready-clean.idx");
    let d_resume = format!("{id}/ready-resume.idx");
    let d_nhs = format!("{id}/nhs.idx");
    for d in [&d_ready, &d_resume, &d_nhs] {
        let _ = std::fs::remove_dir_all(d);
    }

    // job argument errors
    assert!(unsafe { cs_job_start(cstr("index_pack").as_ptr(), cstr("{}").as_ptr()) }.is_null());
    assert_eq!(thread_code(), "unsupported");
    assert!(unsafe { cs_job_start(cstr("nope").as_ptr(), cstr("{}").as_ptr()) }.is_null());
    assert_eq!(thread_code(), "bad_json");
    assert!(job_start(json!({"zim_path": ready})).is_null());
    assert_eq!(thread_code(), "bad_json");
    assert!(job_start(json!({"zim_path": "/nonexistent.zim", "index_dir": d_nhs})).is_null());
    assert_eq!(thread_code(), "not_found");
    assert!(unsafe { cs_job_start(ptr::null(), ptr::null()) }.is_null());
    assert_eq!(thread_code(), "bad_json");
    assert!(unsafe { cs_job_progress(ptr::null_mut()) }.is_null());
    unsafe { cs_job_free(ptr::null_mut()) };

    // clean build of ready.gov: busy while running, handle reports building and skips it
    let t0 = Instant::now();
    let j = job_start(json!({"zim_path": ready, "index_dir": d_ready, "heap_mb": 200}));
    assert!(!j.is_null());
    assert!(job_start(json!({"zim_path": ready, "index_dir": d_ready})).is_null());
    assert_eq!(thread_code(), "busy");
    let h = open(vec![json!({"kind":"zim","path":ready,"builtin_index":false,"index_dir":d_ready})]);
    let st = status(h);
    assert_eq!(st["sources"][0]["building"], true, "{st}");
    assert_eq!(st["sources"][0]["indexed"], false);
    let r = search(h, "flood insurance", json!({}));
    assert_eq!(r["results"].as_array().unwrap().len(), 0);
    assert_eq!(r["keyword_only_sources"].as_array().unwrap().len(), 0);
    let p = wait_not_running(j);
    unsafe { cs_job_free(j) };
    assert_eq!(p["state"], "done", "{p}");
    assert_eq!(p["done"], p["total"]);
    assert!(p["error"].is_null());
    eprintln!("ready.gov clean build: {:?}", t0.elapsed());
    let st = status(h);
    assert_eq!(st["sources"][0]["building"], false);
    assert_eq!(st["sources"][0]["indexed"], true);
    assert_eq!(st["sources"][0]["stale"], false);
    let clean_docs = st["sources"][0]["docs"].as_u64().unwrap();
    assert!(clean_docs > 500 && clean_docs < 6738, "{clean_docs}");
    unsafe { cs_close(h) };
    let meta: Value = serde_json::from_str(&std::fs::read_to_string(format!("{d_ready}/cache_search_index.json")).unwrap()).unwrap();
    assert_eq!(meta["state"], "done");
    assert_eq!(meta["index_format"], 3);
    assert_eq!(meta["tokenizer"], "en_stem");
    assert_eq!(meta["zim_uuid"], READY);
    assert_eq!(meta["next_entry"], meta["total"]);
    assert!(!std::path::Path::new(&format!("{d_ready}/cache_search_index.lock")).exists());
    // starting again on a finished index is a no-op that ends done
    let p = index_fully(&ready, &d_ready);
    assert_eq!(p["state"], "done");

    // cancel after the first checkpoint, then resume
    let j = job_start(json!({"zim_path": ready, "index_dir": d_resume, "heap_mb": 200, "checkpoint_articles": 150}));
    assert!(!j.is_null());
    let t0 = Instant::now();
    loop {
        let p = progress(j);
        assert_eq!(p["state"], "running", "finished before the first checkpoint was seen: {p}");
        if p["done"].as_u64().unwrap() > 0 {
            break;
        }
        assert!(t0.elapsed() < Duration::from_secs(300));
        std::thread::sleep(Duration::from_millis(2));
    }
    unsafe { assert_eq!(cs_job_cancel(j), 0) };
    let p = wait_not_running(j);
    unsafe { cs_job_free(j) };
    assert_eq!(p["state"], "cancelled", "{p}");
    assert!(p["error"].is_null());
    let cut = p["done"].as_u64().unwrap();
    assert!(cut > 0 && cut < p["total"].as_u64().unwrap(), "{p}");
    eprintln!("cancelled at {cut} of {}", p["total"]);
    let h = open(vec![json!({"kind":"zim","path":ready,"builtin_index":false,"index_dir":d_resume})]);
    let st = status(h);
    assert_eq!(st["sources"][0]["indexed"], false);
    assert_eq!(st["sources"][0]["building"], false);
    assert_eq!(search(h, "flood insurance", json!({}))["results"].as_array().unwrap().len(), 0);
    let meta: Value = serde_json::from_str(&std::fs::read_to_string(format!("{d_resume}/cache_search_index.json")).unwrap()).unwrap();
    assert_eq!(meta["state"], "building");
    assert_eq!(meta["next_entry"], cut);
    let p = index_fully(&ready, &d_resume);
    assert_eq!(p["state"], "done", "{p}");
    assert_eq!(docs_of(h, READY), clean_docs, "resumed build must have the same documents as a clean build");
    // and the same search answers
    unsafe { cs_close(h) };
    let hr = open(vec![json!({"kind":"zim","path":ready,"builtin_index":false,"index_dir":d_resume})]);
    let hc = open(vec![json!({"kind":"zim","path":ready,"builtin_index":false,"index_dir":d_ready})]);
    // (equal-score ties may order differently between two builds, so compare the clear leaders only)
    assert_eq!(
        addrs(&search(hr, "flood insurance", json!({"k":4}))),
        addrs(&search(hc, "flood insurance", json!({"k":4})))
    );
    unsafe {
        cs_close(hr);
        cs_close(hc);
    }
    std::fs::remove_dir_all(&d_resume).unwrap();

    // nhs
    let t0 = Instant::now();
    let p = index_fully(&nhs, &d_nhs);
    assert_eq!(p["state"], "done", "{p}");
    eprintln!("nhs build: {:?}", t0.elapsed());

    // a stale index (other format) is reported stale and not searched
    let d_stale = format!("{id}/stale.idx");
    let _ = std::fs::remove_dir_all(&d_stale);
    std::fs::create_dir_all(&d_stale).unwrap();
    std::fs::write(
        format!("{d_stale}/cache_search_index.json"),
        json!({"index_format":1,"tokenizer":"en_stem","zim_uuid":READY,"state":"done","next_entry":1,"total":1}).to_string(),
    )
    .unwrap();

    let hs = open(vec![json!({"kind":"zim","path":ready,"builtin_index":false,"index_dir":d_stale})]);
    let st = status(hs);
    assert_eq!(st["sources"][0]["stale"], true, "{st}");
    assert_eq!(st["sources"][0]["indexed"], false);
    assert_eq!(search(hs, "flood", json!({}))["results"].as_array().unwrap().len(), 0);
    unsafe { cs_close(hs) };

    // search over both, with a missing ZIM in the list
    let h = open(vec![
        json!({"kind":"zim","path":"/nonexistent/gone.zim","index_dir":"/nonexistent/gone.idx"}),
        json!({"kind":"zim","path":ready,"builtin_index":false,"index_dir":d_ready}),
        json!({"kind":"zim","path":nhs,"builtin_index":false,"index_dir":d_nhs}),
    ]);
    let st = status(h);
    let ss = st["sources"].as_array().unwrap();
    assert_eq!(ss[0]["error"]["code"], "not_found");
    assert_eq!(ss[0]["indexed"], false);
    assert!(ss[1]["error"].is_null());
    let nhs_id = ss[2]["id"].as_str().unwrap().to_string();
    assert_eq!(ss[2]["indexed"], true);
    assert!(ss[2]["docs"].as_u64().unwrap() > 50);

    let r = search(h, "flood insurance", json!({"k":5}));
    let res = r["results"].as_array().unwrap();
    assert_eq!(res.len(), 5, "{r}");
    assert_eq!(res[0]["source_id"], READY, "{r}");
    assert_eq!(r["vector_sources"], json!([]));
    assert_eq!(r["keyword_only_sources"].as_array().unwrap().len(), 2);
    assert!(r["total_estimate"].as_u64().unwrap() >= 5);
    for x in res {
        let sn = x["snippet"].as_str().unwrap();
        assert!(!sn.is_empty() && sn.chars().count() <= 400, "{sn}");
        assert!(!has_tag(sn), "{sn}");
        assert!(x["address"].as_str().unwrap().starts_with(&format!("zim:{}/", x["source_id"].as_str().unwrap())));
        assert_eq!(x["source_kind"], "zim");
        assert!(x["page"].is_null());
        assert!(x["title"].as_str().unwrap().starts_with(&format!("{}: ", x["source_title"].as_str().unwrap())));
    }
    eprintln!("flood insurance:");
    for x in &res[..3] {
        eprintln!("  {} | {}", x["title"], x["snippet"]);
    }
    // the best three for a query that belongs to one source all come from that source
    for x in &res[..3] {
        assert_eq!(x["source_id"], READY, "flood insurance top 3: {r}");
    }
    let r = search(h, "ibuprofen side effects", json!({"k":5}));
    for x in &r["results"].as_array().unwrap()[..3] {
        assert_eq!(x["source_id"], nhs_id.as_str(), "ibuprofen top 3: {r}");
    }
    // a query nothing matches well still returns k results (coverage filter relaxes)
    let r = search(h, "zebra flood insurance xylophone quartz", json!({"k":5}));
    assert_eq!(r["results"].as_array().unwrap().len(), 5, "{r}");
    assert_eq!(r["results"][0]["source_id"], READY);
    let r = search(h, "ibuprofen side effects", json!({"k":5}));
    eprintln!("ibuprofen side effects:");
    for x in &r["results"].as_array().unwrap()[..3] {
        eprintln!("  {} | {}", x["title"], x["snippet"]);
    }
    // user punctuation never errors
    for q in ["flood (insurance \"", "AND OR NOT", "title:", "((", "\"", "", "   ", "side-effects of O'Brien's c++ -x", "a:b:c ~ ^ ] [ { } \\"] {
        let r = search(h, q, json!({}));
        assert!(r["results"].is_array(), "{q:?}");
    }
    // a query over both sources
    let r = search(h, "emergency first aid", json!({"k":10}));
    assert_eq!(r["keyword_only_sources"].as_array().unwrap().len(), 2);
    assert!(!r["results"].as_array().unwrap().is_empty());

    // paging
    let p0 = search(h, "emergency", json!({"k":5, "offset":0}));
    let p1 = search(h, "emergency", json!({"k":5, "offset":5}));
    let both = search(h, "emergency", json!({"k":10, "offset":0}));
    let (a0, a1) = (addrs(&p0), addrs(&p1));
    assert_eq!(a0.len(), 5);
    assert_eq!(a1.len(), 5);
    assert_ne!(a0, a1);
    let mut all = a0.clone();
    all.extend(a1.clone());
    assert_eq!(all, addrs(&both));
    let mut u = all.clone();
    u.sort();
    u.dedup();
    assert_eq!(u.len(), 10, "duplicates across pages");

    // source filter
    let r = search(h, "flood insurance", json!({"k":5, "sources":[nhs_id]}));
    assert_eq!(r["keyword_only_sources"], json!([nhs_id]));
    for x in r["results"].as_array().unwrap() {
        assert_eq!(x["source_id"], nhs_id.as_str());
    }
    let r = search(h, "flood insurance", json!({"k":5, "sources":[READY.to_uppercase()]}));
    assert_eq!(r["keyword_only_sources"], json!([READY]));
    let r = search(h, "flood insurance", json!({"sources":[]}));
    assert_eq!(r["results"].as_array().unwrap().len(), 0);
    // bad options
    let bad = cstr("{\"k\":\"x\"}");
    assert!(unsafe { cs_search(h, cstr("x").as_ptr(), bad.as_ptr()) }.is_null());
    assert_eq!(
        serde_json::from_str::<Value>(&take(unsafe { cs_last_error(h) }).unwrap()).unwrap()["code"],
        "bad_json"
    );
    // NULL options and NULL query
    assert!(take(unsafe { cs_search(h, cstr("flood").as_ptr(), ptr::null()) }).is_some());
    assert!(unsafe { cs_search(h, ptr::null(), ptr::null()) }.is_null());

    // read
    let r = search(h, "flood insurance", json!({"k":1}));
    let addr = r["results"][0]["address"].as_str().unwrap().to_string();
    let read = |a: &str, n: i32| -> Option<Value> {
        take(unsafe { cs_read(h, cstr(a).as_ptr(), n) }).map(|s| serde_json::from_str(&s).unwrap())
    };
    let full = read(&addr, 1_000_000).unwrap();
    assert_eq!(full["address"], addr.as_str());
    assert_eq!(full["truncated"], false);
    let text = full["text"].as_str().unwrap();
    assert!(text.chars().count() > 100, "{text}");
    assert!(!has_tag(text), "{text}");
    assert!(!full["title"].as_str().unwrap().is_empty());
    let cut = read(&addr, 600).unwrap();
    let ct = cut["text"].as_str().unwrap();
    assert!(ct.chars().count() <= 600 && !ct.is_empty());
    assert_eq!(cut["truncated"], text.chars().count() > 600);
    assert!(text.starts_with(ct));
    if cut["truncated"] == true {
        // cut at a paragraph end: the next char of the full text is a line break
        let rest = &text[ct.len()..];
        assert!(rest.starts_with('\n'), "cut mid-paragraph: {rest:?}");
    }
    eprintln!("read title {:?}", full["title"]);
    eprintln!("read {addr}: {} chars; first 200: {:?}", text.chars().count(), text.chars().take(200).collect::<String>());
    assert!(read("zim:00000000-0000-0000-0000-000000000000/x", 10).is_none());
    assert!(read(&format!("pack:{READY}/1"), 10).is_none());
    assert!(read(&addr, 0).is_none());
    // page chrome is gone from snippets and read text (NHS and ready.gov pages)
    let chrome = ["Skip to main content", "Search the NHS website", "An official website of the United States", "Here\u{2019}s how you know"];
    let r = search(h, "ibuprofen side effects", json!({"k":3}));
    let nhs_addr = r["results"][0]["address"].as_str().unwrap().to_string();
    let r2 = search(h, "flood insurance", json!({"k":3}));
    let ready_addr = r2["results"][0]["address"].as_str().unwrap().to_string();
    for rr in [&r, &r2] {
        for x in rr["results"].as_array().unwrap() {
            let sn = x["snippet"].as_str().unwrap();
            for c in chrome {
                assert!(!sn.contains(c), "chrome {c:?} in snippet {sn:?}");
            }
        }
    }
    for a in [&nhs_addr, &ready_addr] {
        let t = read(a, 1_000_000).unwrap();
        let t = t["text"].as_str().unwrap();
        eprintln!("READ300 {a}: {:?}", t.chars().take(300).collect::<String>());
        for c in chrome {
            assert!(!t.contains(c), "chrome {c:?} in read text of {a}: {:?}", t.chars().take(300).collect::<String>());
        }
        assert!(t.chars().count() > 50);
    }
    unsafe { cs_close(h) };
    let _ = std::fs::remove_dir_all(&d_stale);
}

/// Wikipedia articles still come out complete (no index needed).
#[test]
fn wikipedia_read_is_complete() {
    let (Some(zd), Some(_)) = (env("CS_TEST_ZIM_DIR"), env("CS_TEST_IDX_DIR")) else {
        return;
    };
    let wiki = format!("{zd}/wikipedia_en_all_maxi_2026-02.zim");
    let h = open(vec![json!({"kind":"zim","path":wiki})]);
    let id = status(h)["sources"][0]["id"].as_str().unwrap().to_string();
    let a = cstr(&format!("zim:{id}/Water_purification"));
    let v: Value = serde_json::from_str(&take(unsafe { cs_read(h, a.as_ptr(), 10_000_000) }).unwrap()).unwrap();
    let t = v["text"].as_str().unwrap();
    eprintln!("WIKI300: {:?}", t.chars().take(300).collect::<String>());
    eprintln!("WIKI len {}", t.chars().count());
    assert_eq!(v["truncated"], false);
    assert!(t.chars().count() > 20_000, "article too short: {}", t.chars().count());
    assert!(t.starts_with("Water purification"), "{:?}", t.chars().take(80).collect::<String>());
    for needle in ["Water purification is the process of removing", "Sources of water", "Chlorination", "Boiling"] {
        assert!(t.contains(needle), "missing {needle:?}");
    }
    unsafe { cs_close(h) };
}

/// A `?` in a path is part of the path; links copied from HTML (fragment, %-escapes, a trailing ?query) resolve.
#[test]
fn path_lookup_order_on_real_zim() {
    let (Some(zd), Some(_)) = (env("CS_TEST_ZIM_DIR"), env("CS_TEST_IDX_DIR")) else {
        eprintln!("not set: skipping");
        return;
    };
    let ready = format!("{zd}/www.ready.gov_en_2024-12.zim");
    // find a content entry whose path contains '?' and one without
    let z = zim::Zim::new(&ready).unwrap();
    let mut with_q: Option<String> = None;
    let mut plain: Option<String> = None;
    for e in z.iterate_by_urls().flatten() {
        if e.namespace != zim::Namespace::UserContent || !matches!(e.target, Some(zim::Target::Cluster(..))) {
            continue;
        }
        if e.url.contains('?') && with_q.is_none() {
            with_q = Some(e.url.clone());
        }
        if !e.url.contains('?') && !e.url.contains('%') && !e.url.contains('#') && e.mime_type == zim::MimeType::Type("text/html".into()) && plain.is_none() {
            plain = Some(e.url.clone());
        }
        if with_q.is_some() && plain.is_some() {
            break;
        }
    }
    let with_q = with_q.expect("ready.gov has an entry with '?' in its path");
    let plain = plain.unwrap();
    eprintln!("path with ?: {with_q}");
    let h = open(vec![json!({"kind":"zim","path":ready})]);
    let get = |p: &str| -> Option<Vec<u8>> {
        let a = cstr(&format!("zim:{READY}/{p}"));
        let (mut m, mut n): (*mut c_char, i64) = (ptr::null_mut(), 0);
        let b = unsafe { cs_zim_get(h, a.as_ptr(), &mut m, &mut n) };
        if b.is_null() {
            return None;
        }
        let v = unsafe { std::slice::from_raw_parts(b, n as usize) }.to_vec();
        unsafe { cs_free_bytes(b, n) };
        take(m);
        Some(v)
    };
    let direct = get(&with_q).expect("path with '?' resolves as a whole");
    assert!(!direct.is_empty());
    // it is not the entry you get by stripping the query first (unless that is the same entry)
    let base = get(&plain).unwrap();
    assert_eq!(get(&format!("{plain}#section-2")).unwrap(), base);
    assert_eq!(get(&format!("{plain}?v=1")).unwrap(), base);
    assert_eq!(get(&format!("{plain}?v=1#frag")).unwrap(), base);
    // percent-encoded characters: encode one letter of the plain path
    let mut enc = String::new();
    for (i, c) in plain.chars().enumerate() {
        if i == 0 {
            enc.push_str(&format!("%{:02X}", c as u32));
        } else {
            enc.push(c);
        }
    }
    assert_eq!(get(&enc).unwrap(), base);
    // the with-'?' path plus a fragment still resolves to the whole-path entry
    assert_eq!(get(&format!("{with_q}#x")).unwrap(), direct);
    assert!(get("no/such/entry?x=1").is_none());
    unsafe { cs_close(h) };
}

/// Manual timing run (not part of the normal suite): CS_TEST_TIMING_ZIM=/zims/x.zim CS_TEST_IDX_DIR=/idx
/// cargo test --release --test search_ffi manual_timing -- --nocapture
#[test]
fn manual_timing() {
    let (Some(zim), Some(id)) = (env("CS_TEST_TIMING_ZIM"), env("CS_TEST_IDX_DIR")) else {
        return;
    };
    let name = std::path::Path::new(&zim).file_stem().unwrap().to_string_lossy().into_owned();
    let dir = format!("{id}/{name}.idx");
    let _ = std::fs::remove_dir_all(&dir);
    let t0 = Instant::now();
    let p = index_fully(&zim, &dir);
    let secs = t0.elapsed().as_secs_f64();
    assert_eq!(p["state"], "done", "{p}");
    let h = open(vec![json!({"kind":"zim","path":zim,"builtin_index":false,"index_dir":dir})]);
    let docs = status(h)["sources"][0]["docs"].as_u64().unwrap();
    let mut size = 0u64;
    for e in std::fs::read_dir(&dir).unwrap().flatten() {
        size += e.metadata().unwrap().len();
    }
    let zsize = std::fs::metadata(&zim).unwrap().len();
    let hwm = std::fs::read_to_string("/proc/self/status")
        .unwrap()
        .lines()
        .find(|l| l.starts_with("VmHWM:"))
        .unwrap()
        .to_string();
    eprintln!(
        "TIMING {name}: entries {} articles {docs} in {secs:.1}s = {:.1} articles/s ({:.1} entries/s); index {size} bytes vs zim {zsize} bytes ({:.1}%); {hwm}",
        p["total"],
        docs as f64 / secs,
        p["total"].as_f64().unwrap() / secs,
        size as f64 * 100.0 / zsize as f64
    );
    unsafe { cs_close(h) };
}
