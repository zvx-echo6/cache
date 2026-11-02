//! live_data's "nothing to report" entry through cs_tool, on the real stored NWS alerts for towns with no active alerts
//! (fetched 2026-10-26; runs only when CS_TEST_LIVE_DB names a copy of that live.db; the test copies it again, so the
//! original is never written).

use cache_search::ffi::*;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};

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

#[test]
fn real_alerts_for_a_quiet_town_give_one_numbered_entry() {
    let Some(db) = std::env::var("CS_TEST_LIVE_DB").ok().filter(|s| !s.is_empty()) else {
        eprintln!("CS_TEST_LIVE_DB not set: skipping");
        return;
    };
    let dir = std::env::temp_dir().join(format!("cs-livenone-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::copy(&db, dir.join("live.sqlite")).unwrap();
    let sources = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../sources");
    let cfg = json!({"sources": [], "user": {"db_path": dir.join("user.sqlite")},
        "live": {"db_path": dir.join("live.sqlite"), "sources_dir": sources}});
    let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
    assert!(!h.is_null());
    let c = cs_conversation_new();
    // Boise, fetched 2026-10-26T09:53:25-06:00; asked at 10:00
    let now = "2026-10-26T10:00:00-06:00";
    let call = |name: &str, args: Value| -> Value {
        let p = unsafe { cs_tool(h, c, cstr(name).as_ptr(), cstr(&args.to_string()).as_ptr(), cstr(now).as_ptr()) };
        let v: Value = serde_json::from_str(&take(p).unwrap()).unwrap();
        v
    };
    let alerts = call("live_data", json!({"source": "alerts", "place": "43.6166,-116.2009"}));
    let content: Value = serde_json::from_str(alerts["content"].as_str().unwrap()).unwrap();
    assert_eq!(content["ok"], true, "{content}");
    assert_eq!(content["none"], true);
    let items = content["items"].as_array().unwrap();
    assert_eq!(items.len(), 1, "{content}");
    let e = &items[0];
    assert_eq!(e["n"], 1);
    assert!(e.get("address").is_none(), "the framework swaps the address for n");
    assert_eq!(e["label"], "No active emergency alerts");
    assert_eq!(e["time"], "2026-10-26T09:53:25-06:00");
    assert_eq!(e["fields"], json!({"Status": "none active", "Checked": "2026-10-26 09:53", "Age": "6 minutes old"}));
    assert_eq!(e["none_active"], true);
    assert_eq!(alerts["ids"], json!([{"n": 1, "address": "live:alerts/at:43.62,-116.20/none", "title": "No active emergency alerts"}]));

    // the same entry keeps its number when asked again, and the next source's items continue the numbering
    let again = call("live_data", json!({"source": "alerts", "place": "43.6166,-116.2009"}));
    assert_eq!(again["content"], alerts["content"]);
    let weather = call("live_data", json!({"source": "weather", "place": "43.6166,-116.2009"}));
    let w: Value = serde_json::from_str(weather["content"].as_str().unwrap()).unwrap();
    assert_eq!(w["ok"], true, "{w}");
    assert!(w.get("none").is_none());
    assert!(w["items"].as_array().unwrap().iter().all(|i| i.get("none_active").is_none()));
    assert_eq!(w["items"][0]["n"], 2);

    unsafe {
        cs_conversation_free(c);
        cs_close(h);
    }
    let _ = std::fs::remove_dir_all(&dir);
}
