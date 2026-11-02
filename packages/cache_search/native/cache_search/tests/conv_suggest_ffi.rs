//! Integration tests through the C ABI: `cs_format` / `cs_conversation_*` (no data needed) and `cs_suggest`
//! (runs only when CS_TEST_ZIM_DIR and CS_TEST_IDX_DIR are set; indexes the small NHS medicines ZIM).

use cache_search::ffi::*;
use cache_search::conv::Conversation;
use cache_search::handle::Handle;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
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

fn thread_code() -> String {
    let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(ptr::null_mut()) }).expect("an error")).unwrap();
    e["code"].as_str().unwrap().to_string()
}

fn format(c: *mut Conversation, j: &str) -> Value {
    serde_json::from_str(&take(unsafe { cs_format(c, cstr(j).as_ptr()) }).expect("format failed")).unwrap()
}

#[test]
fn format_ids_free() {
    let c = cs_conversation_new();
    assert!(!c.is_null());
    let ids: Value = serde_json::from_str(&take(unsafe { cs_conversation_ids(c) }).unwrap()).unwrap();
    assert_eq!(ids, json!({"ids": []}));

    let v = format(
        c,
        r#"[{"address":"zim:u/a","title":"Alpha","snippet":"One.","source_id":"u","page":null},
            {"address":"pack:p/2","title":"Beta","snippet":"Two."},
            {"address":"zim:u/c","title":"Gamma","snippet":"Three."}]"#,
    );
    assert_eq!(
        v["tool_message"],
        "[1] Alpha \u{2014} One.\n[2] Beta \u{2014} Two.\n[3] Gamma \u{2014} Three."
    );
    assert_eq!(v["ids"].as_array().unwrap().len(), 3);

    // continues across calls, reuses a known address, drops a duplicate inside the call
    let v = format(
        c,
        r#"[{"address":"live:x","title":"Live","snippet":"Now."},{"address":"zim:u/a","title":"Alpha","snippet":"One."},{"address":"live:x","title":"Live","snippet":"Now."}]"#,
    );
    assert_eq!(v["tool_message"], "[4] Live \u{2014} Now.\n[1] Alpha \u{2014} One.");
    assert_eq!(v["ids"], json!([
        {"n":4,"address":"live:x","title":"Live"},
        {"n":1,"address":"zim:u/a","title":"Alpha"}
    ]));

    let v = format(c, "[]");
    assert_eq!(v["tool_message"], "No results found.");
    assert_eq!(v["ids"], json!([]));

    let ids: Value = serde_json::from_str(&take(unsafe { cs_conversation_ids(c) }).unwrap()).unwrap();
    let ns: Vec<u64> = ids["ids"].as_array().unwrap().iter().map(|x| x["n"].as_u64().unwrap()).collect();
    assert_eq!(ns, [1, 2, 3, 4]);
    assert_eq!(ids["ids"][3]["address"], "live:x");

    // errors: bad JSON leaves the numbering alone; NULLs do not crash
    assert!(unsafe { cs_format(c, cstr("{not json").as_ptr()) }.is_null());
    assert_eq!(thread_code(), "bad_json");
    assert!(unsafe { cs_format(c, ptr::null()) }.is_null());
    assert_eq!(thread_code(), "bad_json");
    assert!(unsafe { cs_format(ptr::null_mut(), cstr("[]").as_ptr()) }.is_null());
    assert_eq!(thread_code(), "bad_json");
    assert!(unsafe { cs_conversation_ids(ptr::null_mut()) }.is_null());
    assert_eq!(thread_code(), "bad_json");
    let v = format(c, r#"[{"address":"zim:u/z","title":"Z","snippet":"z"}]"#);
    assert_eq!(v["ids"][0]["n"], 5);

    // two conversations are independent
    let c2 = cs_conversation_new();
    assert_eq!(format(c2, r#"[{"address":"zim:u/z","title":"Z","snippet":"z"}]"#)["ids"][0]["n"], 1);
    unsafe {
        cs_conversation_free(c);
        cs_conversation_free(c2);
        cs_conversation_free(ptr::null_mut());
    }
}

fn open(sources: Vec<Value>) -> *mut Handle {
    let cfg = cstr(&json!({"sources": sources}).to_string());
    let h = unsafe { cs_open(cfg.as_ptr()) };
    assert!(!h.is_null());
    h
}

fn suggest(h: *mut Handle, prefix: &str, opts: Option<Value>) -> Value {
    let o = opts.map(|o| cstr(&o.to_string()));
    let p = unsafe { cs_suggest(h, cstr(prefix).as_ptr(), o.as_ref().map_or(ptr::null(), |c| c.as_ptr())) };
    serde_json::from_str(&take(p).unwrap_or_else(|| panic!("suggest failed: {:?}", take(unsafe { cs_last_error(h) })))).unwrap()
}

fn titles(v: &Value) -> Vec<String> {
    v["suggestions"].as_array().unwrap().iter().map(|s| s["title"].as_str().unwrap().to_string()).collect()
}

#[test]
fn suggest_on_small_zim() {
    let (Some(zd), Some(id)) = (
        std::env::var("CS_TEST_ZIM_DIR").ok().filter(|s| !s.is_empty()),
        std::env::var("CS_TEST_IDX_DIR").ok().filter(|s| !s.is_empty()),
    ) else {
        eprintln!("CS_TEST_ZIM_DIR / CS_TEST_IDX_DIR not set: skipping");
        return;
    };
    let zim = format!("{zd}/nhs.uk_en_medicines_2025-12.zim");
    let dir = format!("{id}/nhs-suggest.idx");
    let _ = std::fs::remove_dir_all(&dir);

    // before indexing: the source is skipped, not an error
    let h = open(vec![json!({"kind":"zim","path":zim,"index_dir":dir,"builtin_index":false}), json!({"kind":"zim","path":"/nonexistent/x.zim","index_dir":"/nonexistent/i"})]);
    assert_eq!(titles(&suggest(h, "para", None)).len(), 0);

    let j = unsafe { cs_job_start(cstr("index_zim").as_ptr(), cstr(&json!({"zim_path": zim, "index_dir": dir, "heap_mb": 200}).to_string()).as_ptr()) };
    assert!(!j.is_null());
    let t0 = Instant::now();
    loop {
        let p: Value = serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap();
        if p["state"] != "running" {
            assert_eq!(p["state"], "done", "{p}");
            break;
        }
        assert!(t0.elapsed() < Duration::from_secs(600));
        std::thread::sleep(Duration::from_millis(20));
    }
    unsafe { cs_job_free(j) };

    let st: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
    let uuid = st["sources"][0]["id"].as_str().unwrap().to_string();

    let v = suggest(h, "para", Some(json!({"k": 10})));
    let t = titles(&v);
    eprintln!("para -> {t:?}");
    assert!(!t.is_empty(), "{v}");
    assert!(t.len() <= 10);
    for s in v["suggestions"].as_array().unwrap() {
        assert!(s["title"].as_str().unwrap().to_lowercase().split(|c: char| !c.is_alphanumeric()).any(|w| w.starts_with("para")), "{s}");
        assert_eq!(s["source_id"], uuid.as_str());
        assert!(s["address"].as_str().unwrap().starts_with(&format!("zim:{uuid}/")));
    }
    // stable
    assert_eq!(suggest(h, "para", Some(json!({"k": 10}))), v);
    // case-insensitive
    assert_eq!(suggest(h, "PaRa", Some(json!({"k": 10}))), v);
    // k limits, and the first of k=2 is the first of k=10
    let two = titles(&suggest(h, "para", Some(json!({"k": 2}))));
    assert_eq!(two.len(), 2.min(t.len()));
    assert_eq!(two[..], t[..two.len()]);
    // a longer prefix narrows
    let long = titles(&suggest(h, "paracetamol", Some(json!({"k": 10}))));
    assert!(!long.is_empty());
    assert!(long.iter().all(|x| x.to_lowercase().contains("paracetamol")));
    // the address can be read back
    let first = &suggest(h, "paracetamol", Some(json!({"k": 1})))["suggestions"][0];
    let r = take(unsafe { cs_read(h, cstr(first["address"].as_str().unwrap()).as_ptr(), 200) });
    assert!(r.is_some());
    // source filter: the right id keeps results, another id gives none, null means all
    assert_eq!(suggest(h, "para", Some(json!({"k": 10, "sources": [uuid]}))), v);
    assert_eq!(titles(&suggest(h, "para", Some(json!({"sources": ["00000000-0000-0000-0000-000000000000"]})))).len(), 0);
    assert_eq!(suggest(h, "para", Some(json!({"k": 10, "sources": null}))), v);
    // empty prefix, no match, bad options
    assert_eq!(suggest(h, "", None), json!({"suggestions": []}));
    assert_eq!(suggest(h, "zzzqqq", None), json!({"suggestions": []}));
    assert!(unsafe { cs_suggest(h, cstr("para").as_ptr(), cstr("{").as_ptr()) }.is_null());
    let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(h) }).unwrap()).unwrap();
    assert_eq!(e["code"], "bad_json");
    // NULL handle / NULL prefix
    assert!(unsafe { cs_suggest(ptr::null_mut(), cstr("a").as_ptr(), ptr::null()) }.is_null());
    assert_eq!(thread_code(), "bad_json");
    assert!(unsafe { cs_suggest(h, ptr::null(), ptr::null()) }.is_null());
    unsafe { cs_close(h) };
    let _ = std::fs::remove_dir_all(&dir);
}
