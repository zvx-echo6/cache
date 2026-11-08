//! The Bookshelves calls through the C ABI, as the app makes them (cs_shelves_append, cs_shelves_resolve, cs_shelves_import,
//! cs_shelves_detect): two devices' logs resolve to the same numbers, clashes get their suffix, the import of an old library log
//! keeps its numbers and runs once, and the same-book events group, split and pick the reading copy.

use cache_search::ffi::*;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::ptr;

fn take(p: *mut c_char) -> Option<String> {
    if p.is_null() {
        return None;
    }
    let s = unsafe { CStr::from_ptr(p) }.to_str().unwrap().to_string();
    unsafe { cs_free_string(p) };
    Some(s)
}

fn call(f: unsafe extern "C" fn(*const c_char) -> *mut c_char, args: &Value) -> Value {
    let a = CString::new(args.to_string()).unwrap();
    let out = take(unsafe { f(a.as_ptr()) }).unwrap_or_else(|| panic!("call failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) })));
    serde_json::from_str(&out).unwrap()
}

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-shelves-{}-{}", std::process::id(), name));
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

fn key(c: char) -> String {
    std::iter::repeat_n(c, 64).collect()
}

/// A library folder with one pack per (doc_id, title, copy key) as the builder writes it (only the header matters here).
fn library(root: &Path, name: &str, books: &[(&str, &str, &str)]) -> PathBuf {
    let dir = root.join(name);
    std::fs::create_dir_all(dir.join("packs")).unwrap();
    for (doc, title, copy) in books {
        let header = json!({"cdoc": 1, "doc_id": doc, "doc_version": 1, "title": title, "source": {"blake3": copy},
            "book": {"title": title, "original_blake3": copy}});
        let mut gz = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        writeln!(gz, "{header}").unwrap();
        writeln!(gz, "{{\"i\":0}}").unwrap();
        std::fs::write(dir.join("packs").join(format!("{doc}@1.cdoc")), gz.finish().unwrap()).unwrap();
    }
    dir
}

fn append(dir: &Path, dev: &str, events: Value) -> Value {
    call(cs_shelves_append, &json!({"dir": dir, "dev": dev, "events": events}))
}

fn resolve(dir: &Path, libs: &Value) -> Value {
    call(cs_shelves_resolve, &json!({"dir": dir, "libraries": libs}))
}

fn call_text(view: &Value, book: &str) -> Value {
    view["books"][book]["call"]["text"].clone()
}

#[test]
fn two_devices_resolve_to_the_same_numbers_and_a_clash_gets_its_suffix() {
    let t = TempDir::new("two");
    let (a, b, c) = (key('a'), key('b'), key('c'));
    let lib = library(&t.0, "field", &[("aid", "First aid", &a), ("surgery", "Surgery", &b), ("doctor", "Doctor", &c)]);
    let libs = json!([{"library_id": "field", "dir": lib}]);
    // apart: the phone and the tablet each shelve a book in 210 and both take number 1
    let phone = t.0.join("phone");
    let tablet = t.0.join("tablet");
    append(&phone, "phone", json!([{"ev": "place", "copy": a, "div": "210", "by": "auto", "at": 100}, {"ev": "assign", "copy": a, "div": "210", "seq": 1, "at": 101}]));
    append(&tablet, "tablet", json!([{"ev": "place", "copy": b, "div": "210", "by": "auto", "at": 200}, {"ev": "assign", "copy": b, "div": "210", "seq": 1, "at": 201}]));
    // sync: each gets the other's file
    std::fs::copy(phone.join("log/phone.jsonl"), tablet.join("log/phone.jsonl")).unwrap();
    std::fs::copy(tablet.join("log/tablet.jsonl"), phone.join("log/tablet.jsonl")).unwrap();
    let on_phone = resolve(&phone, &libs);
    let on_tablet = resolve(&tablet, &libs);
    assert_eq!(on_phone, on_tablet, "both devices resolve the same view");
    assert_eq!(call_text(&on_phone, &a), "CDS 210-001", "the first shelved keeps the number");
    assert_eq!(call_text(&on_phone, &b), "CDS 210-001.1", "the other shows the clash suffix");
    assert_eq!(on_phone["books"][&b]["call"]["suffix"], 1);
    assert_eq!(on_phone["next"]["210"], 2);
    assert_eq!(on_phone["books"][&c]["shelved"], false, "a book no event placed is not shelved");
    // the next placement on either device takes 2, and both agree again
    append(&tablet, "tablet", json!([{"ev": "place", "copy": c, "div": "210", "by": "user", "at": 300}, {"ev": "assign", "copy": c, "div": "210", "seq": 2, "at": 301}]));
    std::fs::copy(tablet.join("log/tablet.jsonl"), phone.join("log/tablet.jsonl")).unwrap();
    assert_eq!(resolve(&phone, &libs), resolve(&tablet, &libs));
    assert_eq!(call_text(&resolve(&phone, &libs), &c), "CDS 210-002");
}

#[test]
fn the_import_keeps_old_numbers_and_runs_once() {
    let t = TempDir::new("import");
    let (x, y) = (key('1'), key('2'));
    let lib = library(&t.0, "field", &[("d1", "Water", &x), ("d2", "Bees", &y)]);
    std::fs::create_dir_all(lib.join("log")).unwrap();
    std::fs::write(
        lib.join("log/phone.jsonl"),
        concat!(
            "{\"v\":1,\"at\":10,\"dev\":\"phone\",\"ev\":\"place\",\"doc\":\"d1\",\"div\":\"530\",\"by\":\"user\"}\n",
            "{\"v\":1,\"at\":11,\"dev\":\"phone\",\"ev\":\"assign\",\"doc\":\"d1\",\"div\":\"530\",\"seq\":4}\n",
            "{\"v\":1,\"at\":12,\"dev\":\"phone\",\"ev\":\"place\",\"doc\":\"d2\",\"div\":\"350\",\"by\":\"auto\"}\n",
            "{\"v\":1,\"at\":13,\"dev\":\"phone\",\"ev\":\"assign\",\"doc\":\"d2\",\"div\":\"350\",\"seq\":1}\n",
            "{\"v\":1,\"at\":14,\"dev\":\"phone\",\"ev\":\"title\",\"doc\":\"d2\",\"title\":\"Keeping bees\"}\n",
        ),
    )
    .unwrap();
    // another device's old library log is not this device's to import
    std::fs::write(lib.join("log/tablet.jsonl"), "{\"v\":1,\"at\":20,\"dev\":\"tablet\",\"ev\":\"place\",\"doc\":\"d1\",\"div\":\"610\",\"by\":\"user\"}\n").unwrap();
    let shelves = t.0.join("bookshelves");
    let libs = json!([{"library_id": "field", "dir": lib}]);
    let first = call(cs_shelves_import, &json!({"dir": shelves, "dev": "phone", "libraries": libs}));
    assert_eq!(first["events"], 5);
    let second = call(cs_shelves_import, &json!({"dir": shelves, "dev": "phone", "libraries": libs}));
    assert_eq!(second["events"], 0, "the import runs once");
    let view = resolve(&shelves, &libs);
    assert_eq!(call_text(&view, &x), "CDS 530-004", "the old number carries over unchanged");
    assert_eq!(call_text(&view, &y), "CDS 350-001");
    assert_eq!(view["books"][&y]["title"], "Keeping bees");
    assert_eq!(view["books"][&x]["by"], "user");
    assert!(shelves.join(".local/migrated.json").is_file());
    assert_eq!(std::fs::read_dir(shelves.join("log")).unwrap().count(), 1, "only this device's file is written");
}

#[test]
fn same_book_events_group_split_and_pick_the_reading_copy() {
    let t = TempDir::new("same");
    let (a, b) = (key('a'), key('b'));
    let lib = library(&t.0, "field", &[("wm", "Wilderness Medicine", &a), ("wm2", "Wilderness Medicine, 7th ed", &b)]);
    let libs = json!([{"library_id": "field", "dir": lib}]);
    let dir = t.0.join("bookshelves");
    append(
        &dir,
        "phone",
        json!([
            {"ev": "place", "copy": a, "div": "210", "by": "auto", "at": 1}, {"ev": "assign", "copy": a, "div": "210", "seq": 1, "at": 2},
            {"ev": "place", "copy": b, "div": "210", "by": "auto", "at": 3}, {"ev": "assign", "copy": b, "div": "210", "seq": 2, "at": 4},
            {"ev": "same", "copy": b, "with": a, "by": "auto", "how": "text", "score": 0.92, "at": 5},
        ]),
    );
    let v = resolve(&dir, &libs);
    assert_eq!(v["books"].as_object().unwrap().len(), 1, "one book");
    assert_eq!(call_text(&v, &a), "CDS 210-001", "the earliest number");
    assert_eq!(v["books"][&a]["aka"], json!(["Wilderness Medicine, 7th ed"]));
    assert_eq!(v["next"]["210"], 3, "the spare's number is held, not reused");
    append(&dir, "phone", json!([{"ev": "prefer", "copy": b, "at": 6}]));
    assert_eq!(resolve(&dir, &libs)["books"][&a]["reading"], json!(b));
    append(&dir, "phone", json!([{"ev": "notsame", "copy": b, "with": a, "by": "user", "at": 7}]));
    let v = resolve(&dir, &libs);
    assert_eq!((call_text(&v, &a), call_text(&v, &b)), (json!("CDS 210-001"), json!("CDS 210-002")), "each gets its own number back");
    // a later detector's guess never undoes the person's choice; the person's own "same" does
    append(&dir, "phone", json!([{"ev": "same", "copy": a, "with": b, "by": "auto", "how": "text", "score": 0.99, "at": 8}]));
    assert_eq!(resolve(&dir, &libs)["books"].as_object().unwrap().len(), 2);
    append(&dir, "phone", json!([{"ev": "same", "copy": a, "with": b, "by": "user", "how": "user", "at": 9}]));
    assert_eq!(resolve(&dir, &libs)["books"].as_object().unwrap().len(), 1);
}

#[test]
fn detection_matches_the_same_file_and_an_event_the_log_does_not_take_writes_nothing() {
    let (a, b, c) = (key('a'), key('b'), key('c'));
    let m = call(cs_shelves_detect, &json!({"copy": {"copy": "x", "blake3": a}, "against": [{"copy": "y", "blake3": a}, {"copy": "z", "blake3": b}]}));
    assert_eq!(m, json!([{"with": "y", "how": "blake3", "score": 1.0}]));
    let t = TempDir::new("refuse");
    let dir = t.0.join("bookshelves");
    let bad = CString::new(json!({"dir": dir, "dev": "phone", "events": [{"ev": "place", "copy": c, "div": "210", "by": "auto"}, {"ev": "same", "copy": c, "with": c, "by": "user", "how": "user"}]}).to_string()).unwrap();
    assert!(take(unsafe { cs_shelves_append(bad.as_ptr()) }).is_none());
    assert!(!dir.join("log/phone.jsonl").exists() || std::fs::read(dir.join("log/phone.jsonl")).unwrap().is_empty(), "nothing written");
}
