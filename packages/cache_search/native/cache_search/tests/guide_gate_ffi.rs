//! The guide gate: the guide library (id `cache-guide`) goes below every other hit when the query is not about the app
//! (its best cosine to the guide's vectors is under GUIDE_GATE), and the ranking is unchanged when it is. Two small
//! libraries are generated here; the query vectors are chosen by hand so the cosines are known.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::library::{ensure_init, MANIFEST_FILE};
use cache_search::search::GUIDE_GATE;
use edge::{
    Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, PointInsertOperations, PointOperations, PointStruct,
    UpdateOperation,
};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};

const DIMS: usize = 16;
const MODEL: &str = "test-model.gguf";
const NOW: &str = "2026-10-25T14:20:05-06:00";

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

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-guidegate-{}-{}", std::process::id(), name));
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

fn axis(i: usize) -> Vec<f32> {
    let mut v = vec![0.0; DIMS];
    v[i] = 1.0;
    v
}

/// A unit vector with cosine `cos` to axis `a` and the rest on axis `b`.
fn mix(a: usize, cos: f32, b: usize) -> Vec<f32> {
    let mut v = vec![0.0; DIMS];
    v[a] = cos;
    v[b] = (1.0 - cos * cos).sqrt();
    v
}

fn build(dir: &Path, points: Vec<(u64, Vec<f32>, String)>) {
    ensure_init();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).build()).build();
    let shard = EdgeShard::new(dir, cfg).unwrap();
    let list = points
        .into_iter()
        .map(|(id, v, title)| PointStruct::new(id, v, json!({"title": title, "content": format!("Text of {title}. More.")})).0)
        .collect();
    shard
        .update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(list))))
        .unwrap();
    shard.flush().unwrap();
    drop(shard);
    let _ = std::fs::remove_file(dir.join(MANIFEST_FILE));
}

/// Query axes: 5 is "not about the app", 6 is "about the app".
/// Guide: four sections at cosine 0.4 to axis 5 (below the gate), one at 0.9 to axis 6 (above it).
/// Mine (the user's library): five points at cosine 0.3 to axis 5 and five at 0.3 to axis 6.
fn fixture(name: &str, guide_id: &str) -> (TempDir, *mut Handle) {
    let tmp = TempDir::new(name);
    let (g, m) = (tmp.0.join("guide"), tmp.0.join("mine"));
    let mut gp: Vec<(u64, Vec<f32>, String)> = (0..4).map(|i| (1 + i as u64, mix(5, 0.4, i), format!("Guide A{i}"))).collect();
    gp.push((9, mix(6, 0.9, 4), "Guide App".to_string()));
    build(&g, gp);
    let mut mp: Vec<(u64, Vec<f32>, String)> = (0..5).map(|i| (1 + i as u64, mix(5, 0.3, 8 + i), format!("Mine X{i}"))).collect();
    mp.extend((0..5).map(|i| (20 + i as u64, mix(6, 0.3, 8 + i), format!("Mine Y{i}"))));
    build(&m, mp);
    let src = |id: &str, title: &str, p: &Path| {
        let settings = json!({"format":1,"library_id":id,"title":title,"fields":{"title":"title","text":"content"},
            "embedding":{"vector":"","model":MODEL,"sha256":"x","dims":DIMS},"keyword_index":"auto"});
        json!({"kind":"library","path":p.to_str().unwrap(),"index_dir":"/nonexistent/idx","settings":settings})
    };
    let cfg = json!({"sources":[src(guide_id, "Cache guide", &g), src("mine", "Mine", &m)]});
    let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
    assert!(!h.is_null());
    let t0 = std::time::Instant::now();
    loop {
        let v: Value = serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap();
        if v["sources"].as_array().unwrap().iter().all(|s| s["opening"] == false) {
            break;
        }
        assert!(t0.elapsed().as_secs() < 60, "{v}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
    (tmp, h)
}

fn search_titles(h: *mut Handle, axis_i: usize) -> Vec<String> {
    let opts = json!({"k":5,"query_vector":{"model":MODEL,"vector":axis(axis_i)}});
    let r = take(unsafe { cs_search(h, cstr("ignored").as_ptr(), cstr(&opts.to_string()).as_ptr()) }).expect("search");
    let v: Value = serde_json::from_str(&r).unwrap();
    v["results"].as_array().unwrap().iter().map(|x| x["title"].as_str().unwrap().to_string()).collect()
}

fn tool_lines(h: *mut Handle, axis_i: usize) -> Vec<String> {
    let c = cs_conversation_new();
    let args = json!({"query":"zzqq", "query_vector":{"model":MODEL,"vector":axis(axis_i)}});
    let p = unsafe { cs_tool(h, c, cstr("search").as_ptr(), cstr(&args.to_string()).as_ptr(), cstr(NOW).as_ptr()) };
    let v: Value = serde_json::from_str(&take(p).expect("tool")).unwrap();
    unsafe { cs_conversation_free(c) };
    v["content"].as_str().unwrap().lines().map(str::to_string).collect()
}

#[test]
fn a_query_not_about_the_app_puts_guide_hits_below_every_library_hit() {
    assert_eq!(GUIDE_GATE, 0.5);
    // control: the same libraries with the guide under another id are not touched by the gate
    let (_t0, h0) = fixture("control", "other-guide");
    let before = search_titles(h0, 5);
    assert!(before.iter().any(|t| t.starts_with("Guide A")), "the guide's hits are among the first five without the gate: {before:?}");
    assert!(before[0].starts_with("Guide A"), "{before:?}");
    unsafe { cs_close(h0) };

    let (_t, h) = fixture("gated", "cache-guide");
    let after = search_titles(h, 5);
    // the best guide cosine is 0.4 < 0.5: the five shown are all from the library, the next candidates in its order
    assert_eq!(after.len(), 5);
    assert!(after.iter().all(|t| t.starts_with("Mine")), "{after:?}");
    let want: Vec<String> = before.iter().filter(|t| t.starts_with("Mine")).cloned().collect();
    assert_eq!(&after[..want.len()], &want[..], "library hits keep their relative order");
    unsafe { cs_close(h) };
}

#[test]
fn a_query_about_the_app_keeps_the_guide_on_top() {
    let (_t0, h0) = fixture("app-control", "other-guide");
    let ungated = search_titles(h0, 6);
    unsafe { cs_close(h0) };
    let (_t, h) = fixture("app", "cache-guide");
    let gated = search_titles(h, 6);
    assert_eq!(gated[0], "Guide App", "{gated:?}");
    assert_eq!(gated, ungated, "at or above the gate the ranking is unchanged");
    unsafe { cs_close(h) };
}

#[test]
fn the_result_lines_keep_their_form_and_numbering() {
    let (_t, h) = fixture("lines", "cache-guide");
    let lines = tool_lines(h, 5);
    assert_eq!(lines.len(), 3);
    for (i, l) in lines.iter().enumerate() {
        let want = format!("[{}] Mine ", i + 1);
        assert!(l.starts_with(&want), "{l}");
        assert!(l.contains(" \u{2014} Text of Mine "), "{l}");
    }
    let app = tool_lines(h, 6);
    assert!(app[0].starts_with("[1] Guide App \u{2014} Text of Guide App"), "{app:?}");
    unsafe { cs_close(h) };
}
