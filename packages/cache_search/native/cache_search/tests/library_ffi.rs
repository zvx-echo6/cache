//! Library source tests through the C ABI. The shard is generated here with the read-write EdgeShard (no
//! committed data), then opened by the core read-only.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::library::{ensure_init, MANIFEST_FILE};
use edge::{
    Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, PointId, PointInsertOperations, PointOperations,
    PointStruct, UpdateOperation,
};
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::sync::OnceLock;

const DIMS: usize = 16;
const BASE: u64 = 2000;
const DUP_OFFSET: u64 = 2000; // ids 2001..=2010 are exact copies of ids 1..=10
const CLUSTER: u64 = 5001; // ids 5001..=5150, the first 120 are junk
const UUID_POINT: &str = "6ba7b810-9dad-11d1-80b4-00c04fd430c8";
const MODEL: &str = "test-model.gguf";

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
        let p = std::env::temp_dir().join(format!("cs-libtest-{}-{}", std::process::id(), name));
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

struct Lcg(u64);
impl Lcg {
    fn next(&mut self) -> f32 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        ((self.0 >> 40) as f32 / (1u64 << 24) as f32) * 2.0 - 1.0
    }
}

fn normalize(mut v: Vec<f32>) -> Vec<f32> {
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    v.iter_mut().for_each(|x| *x /= n);
    v
}

fn random_vec(seed: u64) -> Vec<f32> {
    let mut r = Lcg(seed.wrapping_mul(7919).wrapping_add(13));
    normalize((0..DIMS).map(|_| r.next()).collect())
}

/// The cluster centre and the orthogonal direction its points drift along.
fn centre_and_dir() -> (Vec<f32>, Vec<f32>) {
    let mut c = vec![0.0; DIMS];
    c[0] = 1.0;
    let mut d = vec![0.0; DIMS];
    d[1] = 1.0;
    (c, d)
}

fn cluster_vec(j: u64) -> Vec<f32> {
    let (c, d) = centre_and_dir();
    let eps = 0.002 * (j + 1) as f32;
    normalize(c.iter().zip(d.iter()).map(|(a, b)| a + eps * b).collect())
}

fn base_payload(i: u64) -> Value {
    let d = i / 20;
    let mut p = json!({
        "title": format!("Book {d}"),
        "content": format!("Paragraph {i}. This text is about topic {}. Another sentence follows here.", i % 37),
        "doc_hash": format!("hash{d}"),
        "junk": i % 10 == 3,
        "source_type": if i % 7 == 0 { "transcript" } else { "book" },
        "_start_page": i % 500 + 1,
        "book_author": "A. Writer",
        "replaced_by_rebuild": if i % 50 == 7 { json!(["x"]) } else { Value::Null },
    });
    if i % 2 == 0 {
        p["summary"] = json!(format!("Summary {i}. More."));
    }
    p
}

fn is_left_out(id: u64) -> bool {
    if id >= CLUSTER {
        return id - CLUSTER < 120;
    }
    let orig = if id > DUP_OFFSET { id - DUP_OFFSET } else { id };
    orig % 10 == 3 || orig % 50 == 7
}

fn upsert(shard: &EdgeShard, pts: Vec<PointStruct>) {
    let list = pts.into_iter().map(|p| p.0).collect();
    shard
        .update(UpdateOperation::PointOperation(PointOperations::UpsertPoints(PointInsertOperations::PointsList(list))))
        .unwrap();
}

/// Build the shard at `dir`, flush it, close it, and remove any manifest the writer left.
fn build_shard(dir: &Path) {
    ensure_init();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).build()).build();
    let shard = EdgeShard::new(dir, cfg).unwrap();
    let mut pts = Vec::new();
    for i in 1..=BASE {
        pts.push(PointStruct::new(i, random_vec(i), base_payload(i)));
    }
    for i in 1..=10u64 {
        pts.push(PointStruct::new(DUP_OFFSET + i, random_vec(i), base_payload(i)));
    }
    for j in 0..150u64 {
        pts.push(PointStruct::new(
            CLUSTER + j,
            cluster_vec(j),
            json!({"title": "Cluster", "content": format!("Cluster point {j}. Some text."), "doc_hash": format!("c{j}"),
                   "junk": j < 120, "source_type": "book", "_start_page": 1, "book_author": "A. Writer"}),
        ));
    }
    let uid: PointId = UUID_POINT.parse().unwrap();
    pts.push(PointStruct::new(
        uid,
        random_vec(999_999),
        json!({"title": "Uuid book", "content": "A point with a UUID id. Second sentence.", "doc_hash": "u", "junk": false,
               "source_type": "book", "_start_page": 3}),
    ));
    for chunk in pts.chunks(500) {
        upsert(&shard, chunk.to_vec());
    }
    shard.flush().unwrap();
    drop(shard);
    let _ = std::fs::remove_file(dir.join(MANIFEST_FILE));
}

const TOTAL: u64 = BASE + 10 + 150 + 1;

struct Fixture {
    _tmp: TempDir,
    dir: PathBuf,
}

fn make_fixture(name: &str) -> Fixture {
    let tmp = TempDir::new(name);
    let dir = tmp.0.join("lib_shard");
    build_shard(&dir);
    Fixture { _tmp: tmp, dir }
}

fn shared() -> &'static Fixture {
    static F: OnceLock<Fixture> = OnceLock::new();
    F.get_or_init(|| make_fixture("shared"))
}

fn settings(leave_out: Value, with_document: bool) -> Value {
    let mut fields = json!({
        "title": "title", "title_fallback": "book_title", "text": "content", "summary": "summary",
        "page": "_start_page", "source_type": "source_type", "author": "book_author", "link": null
    });
    if with_document {
        fields["document"] = json!("doc_hash");
    }
    json!({"format":1,"library_id":"t","title":"Test Lib","unknown_key":5,"fields":fields,"leave_out":leave_out,
           "embedding":{"vector":"","model":MODEL,"sha256":"x","dims":DIMS},"keyword_index":"auto"})
}

fn default_leave_out() -> Value {
    json!([{"field":"junk","equals":true},{"field":"replaced_by_rebuild","is_set":true}])
}

fn open(path: &Path, settings: Option<Value>) -> *mut Handle {
    let mut src = json!({"kind":"library","path":path.to_str().unwrap(),"index_dir":"/nonexistent/idx"});
    if let Some(s) = settings {
        src["settings"] = s;
    }
    let cfg = cstr(&json!({"sources":[src]}).to_string());
    let h = unsafe { cs_open(cfg.as_ptr()) };
    assert!(!h.is_null(), "cs_open failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    h
}

fn status(h: *mut Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap()
}

fn search(h: *mut Handle, v: &[f32], model: &str, k: usize, offset: usize) -> Value {
    let opts = json!({"k":k,"offset":offset,"query_vector":{"model":model,"vector":v}});
    let r = take(unsafe { cs_search(h, cstr("ignored").as_ptr(), cstr(&opts.to_string()).as_ptr()) });
    serde_json::from_str(&r.expect("search result")).unwrap()
}

fn addrs(r: &Value) -> Vec<String> {
    r["results"].as_array().unwrap().iter().map(|x| x["address"].as_str().unwrap().to_string()).collect()
}

fn id_of(addr: &str) -> u64 {
    addr.rsplit('/').next().unwrap().parse().unwrap()
}

fn read(h: *mut Handle, addr: &str, max: i32) -> Option<Value> {
    take(unsafe { cs_read(h, cstr(addr).as_ptr(), max) }).map(|s| serde_json::from_str(&s).unwrap())
}

fn last_code() -> String {
    let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(ptr::null_mut()) }).expect("an error")).unwrap();
    e["code"].as_str().unwrap().to_string()
}

fn handle_code(h: *mut Handle) -> String {
    let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(h) }).expect("an error")).unwrap();
    e["code"].as_str().unwrap().to_string()
}

#[test]
fn dense_search_returns_the_query_point_first() {
    let f = shared();
    let h = open(&f.dir, Some(settings(default_leave_out(), true)));
    let r = search(h, &random_vec(500), MODEL, 5, 0);
    assert_eq!(r["vector_sources"], json!(["t"]));
    assert_eq!(r["keyword_only_sources"], json!([]));
    let first = &r["results"][0];
    assert_eq!(first["address"], "lib:t/500");
    assert_eq!(first["title"], "Book 25, p. 1");
    assert_eq!(first["snippet"], "Summary 500. More.");
    assert_eq!(first["source_id"], "t");
    assert_eq!(first["source_kind"], "library");
    assert_eq!(first["source_title"], "Test Lib");
    assert_eq!(first["page"], 1);
    assert_eq!(r["results"].as_array().unwrap().len(), 5);
    // no summary: the snippet is the start of the text, at a sentence end
    let r = search(h, &random_vec(501), MODEL, 3, 0);
    assert_eq!(r["results"][0]["address"], "lib:t/501");
    assert_eq!(
        r["results"][0]["snippet"],
        "Paragraph 501. This text is about topic 20. Another sentence follows here."
    );
    // a UUID point id is used as given
    let r = search(h, &random_vec(999_999), MODEL, 3, 0);
    assert_eq!(r["results"][0]["address"], format!("lib:t/{UUID_POINT}"));
    assert_eq!(r["results"][0]["title"], "Uuid book, p. 3");
    // paging
    let all = addrs(&search(h, &random_vec(500), MODEL, 6, 0));
    let page2 = addrs(&search(h, &random_vec(500), MODEL, 3, 3));
    assert_eq!(page2, all[3..6].to_vec());
    unsafe { cs_close(h) };
}

#[test]
fn leave_out_points_never_appear() {
    let f = shared();
    let h = open(&f.dir, Some(settings(default_leave_out(), true)));
    for seed in [3u64, 7, 13, 2003, 2007, 77_777] {
        let r = search(h, &random_vec(seed), MODEL, 50, 0);
        let a = addrs(&r);
        assert_eq!(a.len(), 50, "seed {seed}");
        for x in a {
            if x.contains('-') {
                continue; // the UUID point
            }
            assert!(!is_left_out(id_of(&x)), "left-out point {x} shown (seed {seed})");
        }
    }
    // the query point itself is left out (junk): it must not come back
    let a = addrs(&search(h, &random_vec(3), MODEL, 5, 0));
    assert!(!a.contains(&"lib:t/3".to_string()));
    // without rules the same query returns it
    let h2 = open(&f.dir, Some(settings(json!([]), true)));
    let a = addrs(&search(h2, &random_vec(3), MODEL, 5, 0));
    // (point 2003 is an exact copy of point 3; the duplicate collapse keeps one of the two)
    assert!(a.contains(&"lib:t/3".to_string()) || a.contains(&"lib:t/2003".to_string()), "{a:?}");
    unsafe { cs_close(h) };
    unsafe { cs_close(h2) };
}

#[test]
fn widening_finds_survivors_beyond_the_first_candidates() {
    let f = shared();
    let (centre, _) = centre_and_dir();
    // no rules: the nearest points are the junk head of the cluster
    let h0 = open(&f.dir, Some(settings(json!([]), true)));
    let a = addrs(&search(h0, &centre, MODEL, 5, 0));
    assert_eq!(a, (0..5).map(|j| format!("lib:t/{}", CLUSTER + j)).collect::<Vec<_>>());
    unsafe { cs_close(h0) };
    // with rules the first 120 are left out, so 50 and 100 candidates have no survivor and 200 do
    let h = open(&f.dir, Some(settings(default_leave_out(), true)));
    let a = addrs(&search(h, &centre, MODEL, 5, 0));
    assert_eq!(a, (120..125).map(|j| format!("lib:t/{}", CLUSTER + j)).collect::<Vec<_>>());
    // the 30 survivors come first, then the nearest ordinary points
    let a = addrs(&search(h, &centre, MODEL, 40, 0));
    assert_eq!(a.len(), 40);
    assert_eq!(&a[..30], (120..150).map(|j| format!("lib:t/{}", CLUSTER + j)).collect::<Vec<_>>().as_slice());
    // asking for more than the library can give returns what survives, without error
    let a = addrs(&search(h, &centre, MODEL, 2500, 0));
    assert!(a.len() > 1500 && a.len() < 2161 - 120, "{}", a.len());
    assert!(a.iter().filter(|x| !x.contains('-')).all(|x| !is_left_out(id_of(x))));
    unsafe { cs_close(h) };
}

#[test]
fn duplicates_collapse_and_the_list_fills_to_k() {
    let f = shared();
    for with_document in [true, false] {
        let h = open(&f.dir, Some(settings(default_leave_out(), with_document)));
        let r = search(h, &random_vec(5), MODEL, 10, 0);
        let a = addrs(&r);
        assert_eq!(a.len(), 10, "filled up to k (document mapped: {with_document})");
        let pair = a.iter().filter(|x| *x == "lib:t/5" || *x == "lib:t/2005").count();
        assert_eq!(pair, 1, "exactly one of the duplicate pair: {a:?}");
        let mut sorted = a.clone();
        sorted.sort();
        sorted.dedup();
        assert_eq!(sorted.len(), 10);
        let mut titles: Vec<&str> = r["results"].as_array().unwrap().iter().map(|x| x["title"].as_str().unwrap()).collect();
        titles.sort();
        titles.dedup();
        assert_eq!(titles.len(), 10, "titles are distinct after the collapse");
        unsafe { cs_close(h) };
    }
}

#[test]
fn read_returns_mapped_fields_and_not_found() {
    let f = shared();
    let h = open(&f.dir, Some(settings(default_leave_out(), true)));
    let v = read(h, "lib:t/500", 10_000).unwrap();
    assert_eq!(v["address"], "lib:t/500");
    assert_eq!(v["title"], "Book 25");
    assert_eq!(v["text"], "Paragraph 500. This text is about topic 19. Another sentence follows here.");
    assert_eq!(v["truncated"], false);
    assert_eq!(v["author"], "A. Writer");
    assert_eq!(v["page"], 1);
    assert_eq!(v["source_type"], "book");
    let v = read(h, "lib:t/500", 40).unwrap();
    assert_eq!(v["truncated"], true);
    assert!(v["text"].as_str().unwrap().chars().count() <= 40);
    assert!(v["text"].as_str().unwrap().starts_with("Paragraph 500."));
    let v = read(h, &format!("lib:t/{UUID_POINT}"), 1000).unwrap();
    assert_eq!(v["title"], "Uuid book");
    assert!(v["author"].is_null());
    assert_eq!(v["page"], 3);
    // absent ids, an absent UUID, an unknown library, a bad id
    for a in ["lib:t/9999999", "lib:t/11111111-2222-3333-4444-555555555555"] {
        assert!(read(h, a, 100).is_none());
        assert_eq!(handle_code(h), "not_found", "{a}");
    }
    assert!(read(h, "lib:nope/1", 100).is_none());
    assert_eq!(handle_code(h), "not_found");
    assert!(read(h, "lib:t/not-an-id", 100).is_none());
    assert_eq!(handle_code(h), "bad_json");
    unsafe { cs_close(h) };
}

#[test]
fn status_shows_the_library() {
    let f = shared();
    let h = open(&f.dir, Some(settings(default_leave_out(), true)));
    let v = status(h);
    let s = &v["sources"][0];
    assert_eq!(s["id"], "t");
    assert_eq!(s["library_id"], "t");
    assert_eq!(s["kind"], "library");
    assert_eq!(s["title"], "Test Lib");
    assert_eq!(s["docs"], TOTAL);
    assert_eq!(s["embedding_model"], MODEL);
    assert_eq!(s["keyword_source"], "none");
    assert_eq!(s["settings"]["guessed"], false);
    assert_eq!(s["settings"]["fields"]["text"], "content");
    assert_eq!(s["settings"]["embedding"]["dims"], DIMS);
    assert!(s["error"].is_null());
    unsafe { cs_close(h) };
}

#[test]
fn model_mismatch_makes_a_library_keyword_only() {
    let f = shared();
    let h = open(&f.dir, Some(settings(default_leave_out(), true)));
    let r = search(h, &random_vec(500), "another-model.gguf", 5, 0);
    assert_eq!(r["vector_sources"], json!([]));
    assert_eq!(r["keyword_only_sources"], json!(["t"]));
    assert_eq!(r["results"], json!([]));
    // wrong vector length: also not used
    let r = search(h, &[0.1, 0.2], MODEL, 5, 0);
    assert_eq!(r["keyword_only_sources"], json!(["t"]));
    // a source filter that excludes the library lists it nowhere
    let opts = json!({"k":5,"sources":["other"],"query_vector":{"model":MODEL,"vector":random_vec(1)}});
    let r: Value = serde_json::from_str(
        &take(unsafe { cs_search(h, cstr("x").as_ptr(), cstr(&opts.to_string()).as_ptr()) }).unwrap(),
    )
    .unwrap();
    assert_eq!(r["vector_sources"], json!([]));
    assert_eq!(r["keyword_only_sources"], json!([]));
    unsafe { cs_close(h) };
}

#[test]
fn guessed_settings_without_a_settings_object() {
    let f = shared();
    let h = open(&f.dir, None);
    let v = status(h);
    let s = &v["sources"][0];
    assert_eq!(s["id"], "lib_shard");
    assert_eq!(s["settings"]["guessed"], true);
    let fl = &s["settings"]["fields"];
    assert_eq!(fl["text"], "content");
    assert_eq!(fl["title"], "title");
    assert!(fl["title_fallback"].is_null(), "book_title is not in the payload sample");
    assert_eq!(fl["summary"], "summary");
    assert_eq!(fl["page"], "_start_page");
    assert_eq!(fl["source_type"], "source_type");
    assert_eq!(fl["author"], "book_author");
    assert_eq!(fl["document"], "doc_hash");
    assert!(fl["link"].is_null());
    assert_eq!(s["settings"]["leave_out"], json!([]));
    assert_eq!(s["settings"]["embedding"]["vector"], "");
    assert_eq!(s["settings"]["embedding"]["dims"], DIMS);
    assert!(s["embedding_model"].is_null());
    assert_eq!(s["docs"], TOTAL);
    // the model is unknown, so no query vector matches: keyword-only
    let r = search(h, &random_vec(500), MODEL, 5, 0);
    assert_eq!(r["keyword_only_sources"], json!(["lib_shard"]));
    // reading works with the guessed mapping
    let v = read(h, "lib:lib_shard/500", 1000).unwrap();
    assert_eq!(v["title"], "Book 25");
    assert_eq!(v["page"], 1);
    unsafe { cs_close(h) };
}

#[test]
fn bad_settings_fail_the_open_and_a_missing_folder_does_not() {
    let f = shared();
    let cfg = cstr(&json!({"sources":[{"kind":"library","path":f.dir.to_str().unwrap(),"settings":{"library_id":"x"}}]}).to_string());
    assert!(unsafe { cs_open(cfg.as_ptr()) }.is_null());
    assert_eq!(last_code(), "bad_json");
    let h = open(Path::new("/nonexistent/lib"), None);
    let v = status(h);
    assert_eq!(v["sources"][0]["kind"], "library");
    assert_eq!(v["sources"][0]["error"]["code"], "not_found");
    unsafe { cs_close(h) };
}

fn listing(dir: &Path) -> Vec<(String, u64, std::time::SystemTime)> {
    fn walk(base: &Path, d: &Path, out: &mut Vec<(String, u64, std::time::SystemTime)>) {
        for e in std::fs::read_dir(d).unwrap() {
            let e = e.unwrap();
            let md = e.metadata().unwrap();
            if md.is_dir() {
                walk(base, &e.path(), out);
            } else {
                let rel = e.path().strip_prefix(base).unwrap().to_string_lossy().into_owned();
                if rel != MANIFEST_FILE {
                    out.push((rel, md.len(), md.modified().unwrap()));
                }
            }
        }
    }
    let mut out = Vec::new();
    walk(dir, dir, &mut out);
    out.sort();
    out
}

#[test]
fn opening_and_searching_leave_the_shard_files_alone() {
    let f = make_fixture("unchanged");
    assert!(!f.dir.join(MANIFEST_FILE).exists());
    let before = listing(&f.dir);
    assert!(before.len() > 5);
    let h = open(&f.dir, Some(settings(default_leave_out(), true)));
    // the core wrote the manifest: every segment directory listed as active
    let m: Value = serde_json::from_slice(&std::fs::read(f.dir.join(MANIFEST_FILE)).unwrap()).unwrap();
    let segs: Vec<String> = std::fs::read_dir(f.dir.join("segments"))
        .unwrap()
        .map(|e| e.unwrap())
        .filter(|e| e.path().is_dir())
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    assert!(!segs.is_empty());
    assert_eq!(m.as_object().unwrap().len(), segs.len());
    for s in &segs {
        assert_eq!(m[s], "active", "{s}");
    }
    let m_time = std::fs::metadata(f.dir.join(MANIFEST_FILE)).unwrap().modified().unwrap();
    for seed in [1u64, 500, 777] {
        search(h, &random_vec(seed), MODEL, 10, 0);
    }
    read(h, "lib:t/500", 100).unwrap();
    status(h);
    unsafe { cs_close(h) };
    // a second open with the manifest present does not rewrite it
    let h = open(&f.dir, None);
    unsafe { cs_close(h) };
    assert_eq!(std::fs::metadata(f.dir.join(MANIFEST_FILE)).unwrap().modified().unwrap(), m_time);
    assert_eq!(listing(&f.dir), before, "shard files changed");
}
