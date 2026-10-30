//! Notebooks through the C ABI: cs_notebook with the "notebook" section of the cs_open config.

use cache_search::ffi::*;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::PathBuf;
use std::ptr;

struct Tmp(PathBuf);
impl Drop for Tmp {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn cstr(s: &str) -> CString {
    CString::new(s).unwrap()
}

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn nb(h: *mut cache_search::handle::Handle, op: &str, args: Option<Value>) -> Result<Value, Value> {
    let a = args.map(|a| cstr(&a.to_string()));
    let out = take(unsafe { cs_notebook(h, cstr(op).as_ptr(), a.as_ref().map(|a| a.as_ptr()).unwrap_or(ptr::null())) });
    match out {
        Some(s) => Ok(serde_json::from_str(&s).unwrap()),
        None => Err(serde_json::from_str(&take(unsafe { cs_last_error(h) }).unwrap()).unwrap()),
    }
}

#[test]
fn notebook_through_the_c_abi() {
    let t = Tmp(std::env::temp_dir().join(format!("cs-notebook-{}", std::process::id())));
    let _ = std::fs::remove_dir_all(&t.0);
    let cfg = json!({"sources": [], "notebook": {"db_path": t.0.join("notebook/notebook.sqlite"), "media_dir": t.0.join("notebook")}});
    let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
    assert!(!h.is_null());

    assert_eq!(nb(h, "notebooks", None).unwrap()["notebooks"][0]["def"]["name"], "Journal");
    let log = nb(h, "notebook_save", Some(json!({"template": "log", "def": {"name": "Generator test", "due_every": "month",
        "fields": [{"label": "Run time", "type": "number", "unit": "min"}]}}))).unwrap();
    let id = log["id"].as_str().unwrap().to_string();
    let e = nb(h, "entry_save", Some(json!({"notebook_id": id, "occurred_at": "2026-10-25T16:12:00-06:00", "values": {"f1": 20}}))).unwrap();
    assert_eq!(e["values"], json!({"f1": 20}));
    let hits = nb(h, "search", Some(json!({"query": "run time 20"}))).unwrap();
    assert_eq!(hits["hits"][0]["notebook"], "Generator test");

    // errors carry the stable codes
    assert_eq!(nb(h, "entry", Some(json!({"id": "missing"}))).unwrap_err()["code"], "not_found");
    assert_eq!(nb(h, "notebook_save", Some(json!({"template": "log", "def": {"name": ""}}))).unwrap_err()["code"], "bad_json");
    assert_eq!(nb(h, "frobnicate", None).unwrap_err()["code"], "unsupported");

    // a later config without the section keeps the Notebook; the same section keeps the open database
    assert_eq!(unsafe { cs_set_sources(h, cstr(r#"{"sources": []}"#).as_ptr()) }, 0);
    assert_eq!(nb(h, "notebooks", None).unwrap()["notebooks"].as_array().unwrap().len(), 2);
    assert_eq!(unsafe { cs_set_sources(h, cstr(&cfg.to_string()).as_ptr()) }, 0);
    assert_eq!(nb(h, "notebook_delete", Some(json!({"id": id}))).unwrap(), json!({"deleted": id, "entries": 1}));
    unsafe { cs_close(h) };

    // without the section
    let h = unsafe { cs_open(cstr(r#"{"sources": []}"#).as_ptr()) };
    assert_eq!(nb(h, "notebooks", None).unwrap_err()["code"], "not_configured");
    unsafe { cs_close(h) };
}
