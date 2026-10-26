//! Library source tests through the C ABI. The shard is generated here with the read-write EdgeShard (no
//! committed data), then opened by the core read-only.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::job::Job;
use cache_search::library::{ensure_init, MANIFEST_FILE};
use edge::{
    CreateIndex, Distance, EdgeConfig, EdgeShard, EdgeVectorParamsBuilder, FieldIndexOperations, PayloadFieldSchema,
    PayloadSchemaParams, PointId, PointInsertOperations, PointOperations, PointStruct, TextIndexParams,
    TextScoringParams, UpdateOperation,
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
    // rare words for the keyword tests: 1234 is kept, 1233 is left out (junk), 5 has a copy at 2005
    match i {
        1234 => p["content"] = json!("Paragraph 1234. The xylophonic quartz resonates softly. Another sentence follows here."),
        1233 => p["content"] = json!("Paragraph 1233. A zygomorphic flower that nobody may find. Another sentence."),
        5 => p["content"] = json!("Paragraph 5. The quokkaesque marsupial hops about. Another sentence follows here."),
        _ => {}
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
    open_idx(path, settings, "/nonexistent/idx")
}

fn open_idx(path: &Path, settings: Option<Value>, index_dir: &str) -> *mut Handle {
    let h = open_nowait(path, settings, index_dir, 0);
    wait_ready(h);
    h
}

/// cs_open without waiting for the background open. `delay_ms` makes the open thread sleep first (test hook).
fn open_nowait(path: &Path, settings: Option<Value>, index_dir: &str, delay_ms: u64) -> *mut Handle {
    let mut src = json!({"kind":"library","path":path.to_str().unwrap(),"index_dir":index_dir});
    if let Some(s) = settings {
        src["settings"] = s;
    }
    let cfg = cstr(&json!({"sources":[src],"open_delay_ms":delay_ms}).to_string());
    let h = unsafe { cs_open(cfg.as_ptr()) };
    assert!(!h.is_null(), "cs_open failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    h
}

/// Poll cs_status until no source is opening.
fn wait_ready(h: *mut Handle) -> Value {
    let t0 = std::time::Instant::now();
    loop {
        let v = status(h);
        if v["sources"].as_array().unwrap().iter().all(|s| s["opening"] == false) {
            return v;
        }
        assert!(t0.elapsed().as_secs() < 120, "library did not finish opening: {v}");
        std::thread::sleep(std::time::Duration::from_millis(5));
    }
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

// ---------------------------------------------------------------------------------------------------------
// Keyword index: the index_library job and keyword search over a library

fn start_job(params: Value) -> *mut Job {
    unsafe { cs_job_start(cstr("index_library").as_ptr(), cstr(&params.to_string()).as_ptr()) }
}

fn progress(j: *mut Job) -> Value {
    serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap()
}

fn wait_not_running(j: *mut Job) -> Value {
    let t0 = std::time::Instant::now();
    loop {
        let p = progress(j);
        if p["state"] != "running" {
            return p;
        }
        assert!(t0.elapsed().as_secs() < 300, "job did not finish: {p}");
        std::thread::sleep(std::time::Duration::from_millis(2));
    }
}

fn index_params(lib: &Path, idx: &Path, checkpoint: usize) -> Value {
    json!({"library_path": lib.to_str().unwrap(), "index_dir": idx.to_str().unwrap(), "heap_mb": 50,
           "settings": settings(default_leave_out(), true), "checkpoint_docs": checkpoint})
}

fn build_index(lib: &Path, idx: &Path, checkpoint: usize) -> Value {
    let j = start_job(index_params(lib, idx, checkpoint));
    assert!(!j.is_null(), "job start failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    let p = wait_not_running(j);
    unsafe { cs_job_free(j) };
    p
}

fn ksearch(h: *mut Handle, q: &str, k: usize) -> Value {
    let opts = json!({"k": k});
    serde_json::from_str(&take(unsafe { cs_search(h, cstr(q).as_ptr(), cstr(&opts.to_string()).as_ptr()) }).expect("search result")).unwrap()
}

fn index_docs(idx: &Path) -> u64 {
    tantivy::Index::open_in_dir(idx).unwrap().reader().unwrap().searcher().num_docs()
}

fn expected_indexed() -> u64 {
    let kept = (1..=BASE + 10).filter(|&i| !is_left_out(i)).count() + (0..150).filter(|j| !is_left_out(CLUSTER + j)).count();
    kept as u64 + 1 // the UUID point
}

struct KwFixture {
    f: Fixture,
    idx: PathBuf,
}

/// A fixture shard plus a finished device index in a folder beside it.
fn kw_fixture(name: &str) -> KwFixture {
    let f = make_fixture(name);
    let idx = f._tmp.0.join("kw_idx");
    let p = build_index(&f.dir, &idx, 300);
    assert_eq!(p["state"], "done", "{p}");
    KwFixture { f, idx }
}

fn shared_kw() -> &'static KwFixture {
    static F: OnceLock<KwFixture> = OnceLock::new();
    F.get_or_init(|| kw_fixture("shared-kw"))
}

#[test]
fn index_library_builds_and_skips_leave_out_points() {
    let f = make_fixture("idxbuild");
    let idx = f._tmp.0.join("idx");
    // argument errors are reported by cs_job_start
    assert!(start_job(json!({"library_path": f.dir.to_str().unwrap()})).is_null());
    assert_eq!(last_code(), "bad_json");
    assert!(start_job(json!({"library_path": "/nonexistent/lib", "index_dir": idx.to_str().unwrap()})).is_null());
    assert_eq!(last_code(), "not_found");
    let mut bad = index_params(&f.dir, &idx, 300);
    bad["settings"] = json!({"library_id": "x"});
    assert!(start_job(bad).is_null());
    assert_eq!(last_code(), "bad_json");

    let p = build_index(&f.dir, &idx, 300);
    assert_eq!(p["state"], "done", "{p}");
    assert!(p["error"].is_null());
    assert_eq!(p["done"], p["total"]);
    assert_eq!(p["total"], TOTAL);
    assert_eq!(index_docs(&idx), expected_indexed());
    assert!(expected_indexed() < TOTAL);
    let meta: Value = serde_json::from_str(&std::fs::read_to_string(idx.join("cache_search_index.json")).unwrap()).unwrap();
    assert_eq!(meta["state"], "done");
    assert_eq!(meta["index_format"], 2);
    assert_eq!(meta["tokenizer"], "en_stem");
    assert_eq!(meta["zim_uuid"], "lib:t");
    assert!(!idx.join("cache_search_index.lock").exists());
    // building again over a finished index is a no-op that reports done
    let p = build_index(&f.dir, &idx, 300);
    assert_eq!(p["state"], "done");
    assert_eq!(index_docs(&idx), expected_indexed());
    // an index for another library id is rebuilt, not mixed
    let mut other = index_params(&f.dir, &idx, 300);
    other["settings"]["library_id"] = json!("other");
    let j = start_job(other);
    assert_eq!(wait_not_running(j)["state"], "done");
    unsafe { cs_job_free(j) };
    let meta: Value = serde_json::from_str(&std::fs::read_to_string(idx.join("cache_search_index.json")).unwrap()).unwrap();
    assert_eq!(meta["zim_uuid"], "lib:other");
    assert_eq!(index_docs(&idx), expected_indexed());
}

#[test]
fn keyword_query_finds_a_rare_word_and_skips_left_out_points() {
    let k = shared_kw();
    let h = open_idx(&k.f.dir, Some(settings(default_leave_out(), true)), k.idx.to_str().unwrap());
    let r = ksearch(h, "xylophonic", 5);
    assert_eq!(addrs(&r), vec!["lib:t/1234"], "{r}");
    assert_eq!(r["vector_sources"], json!([]));
    assert_eq!(r["keyword_only_sources"], json!(["t"]));
    // a keyword-only hit has its title, page and snippet from the shard payload (summary is mapped on even ids)
    let x = &r["results"][0];
    assert_eq!(x["title"], "Book 61, p. 235");
    assert_eq!(x["snippet"], "Summary 1234. More.");
    assert_eq!(x["page"], 235);
    assert_eq!(x["source_id"], "t");
    assert_eq!(x["source_kind"], "library");
    assert_eq!(x["source_title"], "Test Lib");
    // stemming: "resonate" finds "resonates"
    assert_eq!(addrs(&ksearch(h, "resonate", 5)), vec!["lib:t/1234"]);
    // a left-out point (junk) is never found
    let r = ksearch(h, "zygomorphic", 5);
    assert!(addrs(&r).is_empty(), "{r}");
    // a UUID point id comes back as the UUID
    let r = ksearch(h, "uuid", 5);
    assert_eq!(addrs(&r), vec![format!("lib:t/{UUID_POINT}")], "{r}");
    // the title field is searched too
    let r = ksearch(h, "\"Uuid book\"", 5);
    assert_eq!(addrs(&r), vec![format!("lib:t/{UUID_POINT}")], "{r}");
    // a point read from a keyword hit
    let v = read(h, "lib:t/1234", 1000).unwrap();
    assert!(v["text"].as_str().unwrap().contains("xylophonic"));
    unsafe { cs_close(h) };
}

#[test]
fn identical_points_collapse_to_the_smaller_address() {
    let k = shared_kw();
    // 5 and its copy 2005 have the same payload, so the same score; the collapse keeps the smaller address
    // by string compare, "lib:t/2005" < "lib:t/5"
    for with_doc in [true, false] {
        let h = open_idx(&k.f.dir, Some(settings(default_leave_out(), with_doc)), k.idx.to_str().unwrap());
        let r = ksearch(h, "quokkaesque", 5);
        assert_eq!(addrs(&r), vec!["lib:t/2005"], "{r}");
        unsafe { cs_close(h) };
    }
}

#[test]
fn keyword_and_vector_together_put_the_point_found_by_both_first() {
    let k = shared_kw();
    let h = open_idx(&k.f.dir, Some(settings(default_leave_out(), true)), k.idx.to_str().unwrap());
    // vector near point 777, keyword for point 1234
    let opts = json!({"k": 10, "query_vector": {"model": MODEL, "vector": random_vec(777)}});
    let run = |q: &str, opts: &Value| -> Value {
        serde_json::from_str(&take(unsafe { cs_search(h, cstr(q).as_ptr(), cstr(&opts.to_string()).as_ptr()) }).unwrap()).unwrap()
    };
    let r = run("xylophonic", &opts);
    assert_eq!(r["vector_sources"], json!(["t"]));
    let a = addrs(&r);
    assert!(a.contains(&"lib:t/777".to_string()) && a.contains(&"lib:t/1234".to_string()), "{a:?}");
    // found by both: the vector of point 1234 itself plus its rare word
    let opts = json!({"k": 10, "query_vector": {"model": MODEL, "vector": random_vec(1234)}});
    let r = run("xylophonic", &opts);
    let a = addrs(&r);
    assert_eq!(a[0], "lib:t/1234", "{a:?}");
    assert_eq!(a.iter().filter(|x| *x == "lib:t/1234").count(), 1, "one entry per address");
    // a query with no keyword match leaves the vector list alone
    let vector_only = run("qqqqnomatch", &opts);
    assert_eq!(addrs(&vector_only)[0], "lib:t/1234");
    // repeated queries give the same list
    assert_eq!(addrs(&run("xylophonic", &opts)), a);
    unsafe { cs_close(h) };
}

#[test]
fn keyword_source_in_status() {
    let k = shared_kw();
    let idx = k.idx.to_str().unwrap();
    // no index yet: none, not indexed
    let h = open_idx(&k.f.dir, Some(settings(default_leave_out(), true)), "/nonexistent/idx");
    let s = &status(h)["sources"][0];
    assert_eq!(s["keyword_source"], "none");
    assert_eq!(s["indexed"], false);
    assert_eq!(s["building"], false);
    assert_eq!(s["stale"], false);
    unsafe { cs_close(h) };
    // index built: device
    let h = open_idx(&k.f.dir, Some(settings(default_leave_out(), true)), idx);
    let st = status(h);
    assert_eq!(st["sources"][0]["keyword_source"], "device");
    assert_eq!(st["sources"][0]["indexed"], true);
    unsafe { cs_close(h) };
    // "on" forces the device index; "off" gives no keyword list
    for (mode, source, indexed) in [("on", "device", true), ("off", "none", false)] {
        let mut st = settings(default_leave_out(), true);
        st["keyword_index"] = json!(mode);
        let h = open_idx(&k.f.dir, Some(st), idx);
        let v = status(h);
        assert_eq!(v["sources"][0]["keyword_source"], source, "{mode}");
        assert_eq!(v["sources"][0]["indexed"], indexed, "{mode}");
        let r = ksearch(h, "xylophonic", 5);
        assert_eq!(addrs(&r).len(), if indexed { 1 } else { 0 }, "{mode}");
        unsafe { cs_close(h) };
    }
    // a stale index (another index format) is reported and skipped
    let f = make_fixture("kwstale");
    let sidx = f._tmp.0.join("idx");
    assert_eq!(build_index(&f.dir, &sidx, 300)["state"], "done");
    let mp = sidx.join("cache_search_index.json");
    let mut meta: Value = serde_json::from_str(&std::fs::read_to_string(&mp).unwrap()).unwrap();
    meta["index_format"] = json!(1);
    std::fs::write(&mp, meta.to_string()).unwrap();
    let h = open_idx(&f.dir, Some(settings(default_leave_out(), true)), sidx.to_str().unwrap());
    let v = status(h);
    assert_eq!(v["sources"][0]["stale"], true);
    assert_eq!(v["sources"][0]["indexed"], false);
    assert_eq!(v["sources"][0]["keyword_source"], "none");
    assert!(addrs(&ksearch(h, "xylophonic", 5)).is_empty());
    unsafe { cs_close(h) };
}

const QUERIES: [&str; 6] = ["text topic", "topic 12", "paragraph about", "xylophonic", "sentence follows", "Book 25 text"];

fn all_results(h: *mut Handle) -> Vec<Vec<String>> {
    QUERIES.iter().map(|q| addrs(&ksearch(h, q, 30))).collect()
}

#[test]
fn resume_after_cancel_gives_the_same_results_as_a_clean_build() {
    let f = make_fixture("resume");
    let clean = f._tmp.0.join("clean_idx");
    assert_eq!(build_index(&f.dir, &clean, 100)["state"], "done");
    let mut cancelled_mid = false;
    let resumed = f._tmp.0.join("resumed_idx");
    for attempt in 0..30 {
        let _ = std::fs::remove_dir_all(&resumed);
        let j = start_job(index_params(&f.dir, &resumed, 100));
        assert!(!j.is_null());
        // cancel as soon as the first page has been scrolled
        let t0 = std::time::Instant::now();
        loop {
            let p = progress(j);
            if p["state"] != "running" || p["done"].as_u64().unwrap() > 0 || t0.elapsed().as_secs() > 60 {
                break;
            }
        }
        unsafe { cs_job_cancel(j) };
        let p = wait_not_running(j);
        unsafe { cs_job_free(j) };
        if p["state"] == "cancelled" && p["done"].as_u64().unwrap() > 0 && p["done"].as_u64().unwrap() < TOTAL {
            let meta: Value = serde_json::from_str(&std::fs::read_to_string(resumed.join("cache_search_index.json")).unwrap()).unwrap();
            assert_eq!(meta["state"], "building");
            assert!(meta["next_entry"].as_u64().unwrap() > 0, "a checkpoint was written");
            assert!(!resumed.join("cache_search_index.lock").exists());
            // a handle reports it as not searchable (incomplete), not as indexed
            let h = open_idx(&f.dir, Some(settings(default_leave_out(), true)), resumed.to_str().unwrap());
            assert_eq!(status(h)["sources"][0]["indexed"], false);
            unsafe { cs_close(h) };
            cancelled_mid = true;
            eprintln!("cancelled mid-build on attempt {attempt}: {}", p["done"]);
            break;
        }
    }
    assert!(cancelled_mid, "could not cancel the build part-way in 30 attempts");
    // resume to the end
    let p = build_index(&f.dir, &resumed, 100);
    assert_eq!(p["state"], "done", "{p}");
    assert_eq!(index_docs(&resumed), expected_indexed());
    assert_eq!(index_docs(&clean), expected_indexed());
    let hc = open_idx(&f.dir, Some(settings(default_leave_out(), true)), clean.to_str().unwrap());
    let hr = open_idx(&f.dir, Some(settings(default_leave_out(), true)), resumed.to_str().unwrap());
    let (a, b) = (all_results(hc), all_results(hr));
    assert!(a.iter().all(|l| !l.is_empty()), "{a:?}");
    assert_eq!(a, b, "a resumed build must rank like a clean one, ties included");
    unsafe { cs_close(hc) };
    unsafe { cs_close(hr) };
}

#[test]
fn keyword_search_leaves_the_shard_files_alone() {
    let f = make_fixture("kwunchanged");
    let before = listing(&f.dir);
    let idx = f._tmp.0.join("idx");
    assert_eq!(build_index(&f.dir, &idx, 300)["state"], "done");
    let h = open_idx(&f.dir, Some(settings(default_leave_out(), true)), idx.to_str().unwrap());
    for q in QUERIES {
        ksearch(h, q, 10);
    }
    search(h, &random_vec(1234), MODEL, 10, 0);
    read(h, "lib:t/1234", 100).unwrap();
    status(h);
    unsafe { cs_close(h) };
    assert_eq!(listing(&f.dir), before, "shard files changed");
    assert!(!idx.starts_with(&f.dir), "the index lives outside the shard");
}

// ---------------------------------------------------------------------------------------------------------
// A library whose collection has its own BM25-scored text index

fn build_own_shard(dir: &Path, scored: bool) {
    ensure_init();
    let cfg = EdgeConfig::builder().vector("", EdgeVectorParamsBuilder::new(DIMS, Distance::Cosine).build()).build();
    let shard = EdgeShard::new(dir, cfg).unwrap();
    let schema = PayloadFieldSchema::FieldParams(PayloadSchemaParams::Text(TextIndexParams {
        scoring: if scored { Some(TextScoringParams::default()) } else { None },
        ..TextIndexParams::default()
    }));
    shard
        .update(UpdateOperation::FieldIndexOperation(FieldIndexOperations::CreateIndex(CreateIndex {
            field_name: "content".parse().unwrap(),
            field_schema: Some(schema),
        })))
        .unwrap();
    let mut pts = Vec::new();
    for i in 1..=40u64 {
        let content = if i == 7 { "The sesquipedalian word appears once".to_string() } else { format!("Alpha text number {i} here") };
        pts.push(PointStruct::new(i, random_vec(i), json!({"title": format!("Doc {i}"), "content": content, "junk": i == 9})));
    }
    // a left-out point that matches the rare word as well
    pts.push(PointStruct::new(41u64, random_vec(41), json!({"title": "Hidden", "content": "sesquipedalian hidden", "junk": true})));
    upsert(&shard, pts);
    shard.flush().unwrap();
    drop(shard);
    let _ = std::fs::remove_file(dir.join(MANIFEST_FILE));
}

fn own_settings(mode: &str) -> Value {
    json!({"format":1,"library_id":"own","title":"Own","fields":{"title":"title","text":"content"},
           "leave_out":[{"field":"junk","equals":true}],
           "embedding":{"vector":"","model":MODEL,"sha256":"x","dims":DIMS},"keyword_index":mode})
}

#[test]
fn a_library_with_its_own_scored_index_uses_it() {
    let tmp = TempDir::new("own");
    let scored = tmp.0.join("scored");
    let plain = tmp.0.join("plain");
    build_own_shard(&scored, true);
    build_own_shard(&plain, false);
    // scored, "auto": own, with no device index at all
    let h = open_idx(&scored, Some(own_settings("auto")), "/nonexistent/idx");
    let s = &status(h)["sources"][0];
    assert_eq!(s["keyword_source"], "own", "{s}");
    assert_eq!(s["indexed"], true);
    let r = ksearch(h, "sesquipedalian", 5);
    assert_eq!(addrs(&r), vec!["lib:own/7"], "left-out point 41 is filtered: {r}");
    assert_eq!(r["results"][0]["title"], "Doc 7");
    assert_eq!(r["results"][0]["snippet"], "The sesquipedalian word appears once");
    unsafe { cs_close(h) };
    // "off": nothing
    let h = open_idx(&scored, Some(own_settings("off")), "/nonexistent/idx");
    assert_eq!(status(h)["sources"][0]["keyword_source"], "none");
    assert!(addrs(&ksearch(h, "sesquipedalian", 5)).is_empty());
    unsafe { cs_close(h) };
    // "on": the device index is wanted even though the collection scores: none until it is built
    let h = open_idx(&scored, Some(own_settings("on")), "/nonexistent/idx");
    assert_eq!(status(h)["sources"][0]["keyword_source"], "none");
    unsafe { cs_close(h) };
    // an unscored text index is not used: "auto" falls back to the device index
    let h = open_idx(&plain, Some(own_settings("auto")), "/nonexistent/idx");
    assert_eq!(status(h)["sources"][0]["keyword_source"], "none");
    unsafe { cs_close(h) };
}

// ---------------------------------------------------------------------------------------------------------
// Background opening

#[test]
fn cs_open_returns_at_once_and_the_library_opens_in_the_background() {
    let f = shared();
    let t0 = std::time::Instant::now();
    let h = open_nowait(&f.dir, Some(settings(default_leave_out(), true)), "/nonexistent/idx", 1500);
    assert!(t0.elapsed().as_millis() < 1000, "cs_open waited for the library: {:?}", t0.elapsed());
    // listed as opening, with what is known without the shard
    let v = status(h);
    let s = &v["sources"][0];
    assert_eq!(s["opening"], true, "{v}");
    assert_eq!(s["kind"], "library");
    assert_eq!(s["id"], "t");
    assert_eq!(s["title"], "Test Lib");
    assert_eq!(s["indexed"], false);
    assert_eq!(s["docs"], 0);
    assert!(s["error"].is_null());
    assert!(s["keyword_source"].is_null());
    assert_eq!(s["settings"]["guessed"], false);
    // search during opening skips the library without an error: no results, listed in neither source list
    let r = search(h, &random_vec(500), MODEL, 5, 0);
    assert_eq!(r["results"], json!([]));
    assert_eq!(r["vector_sources"], json!([]));
    assert_eq!(r["keyword_only_sources"], json!([]));
    let r = ksearch(h, "xylophonic", 5);
    assert_eq!(r["results"], json!([]));
    // reading from it is "busy", not "not_found"
    assert!(read(h, "lib:t/500", 100).is_none());
    assert_eq!(handle_code(h), "busy");
    // it becomes ready and searchable
    let v = wait_ready(h);
    let s = &v["sources"][0];
    assert_eq!(s["opening"], false);
    assert_eq!(s["docs"], TOTAL);
    assert_eq!(s["settings"]["guessed"], false);
    assert!(s["error"].is_null());
    assert_eq!(s["keyword_source"], "none");
    let r = search(h, &random_vec(500), MODEL, 3, 0);
    assert_eq!(r["vector_sources"], json!(["t"]));
    assert_eq!(addrs(&r)[0], "lib:t/500");
    assert!(read(h, "lib:t/500", 100).is_some());
    unsafe { cs_close(h) };
}

#[test]
fn set_sources_also_returns_at_once_and_keeps_an_open_library() {
    let f = shared();
    let h = open_nowait(&f.dir, Some(settings(default_leave_out(), true)), "/nonexistent/idx", 0);
    wait_ready(h);
    // the same library again plus a second source entry for a missing ZIM: the open library is kept, not reopened
    let src = json!({"kind":"library","path":f.dir.to_str().unwrap(),"index_dir":"/nonexistent/idx","settings":settings(default_leave_out(), true)});
    let cfg = cstr(&json!({"sources":[src.clone(), {"kind":"zim","path":"/nonexistent/a.zim"}],"open_delay_ms":3000}).to_string());
    let t0 = std::time::Instant::now();
    assert_eq!(unsafe { cs_set_sources(h, cfg.as_ptr()) }, 0);
    assert!(t0.elapsed().as_millis() < 1000);
    let v = status(h);
    assert_eq!(v["sources"][0]["opening"], false, "kept: {v}");
    assert_eq!(v["sources"][0]["docs"], TOTAL);
    assert_eq!(v["sources"][1]["opening"], false);
    // a library at a new path opens in the background; the old list is replaced
    let tmp = TempDir::new("setsrc");
    let copy = tmp.0.join("copy");
    std::fs::create_dir_all(&copy).unwrap();
    let cfg = cstr(&json!({"sources":[{"kind":"library","path":copy.to_str().unwrap()}],"open_delay_ms":800}).to_string());
    assert_eq!(unsafe { cs_set_sources(h, cfg.as_ptr()) }, 0);
    let v = status(h);
    assert_eq!(v["sources"].as_array().unwrap().len(), 1);
    assert_eq!(v["sources"][0]["opening"], true, "{v}");
    assert_eq!(v["sources"][0]["id"], "copy");
    // an empty folder is not a shard: the failure is recorded on the source
    let v = wait_ready(h);
    assert_eq!(v["sources"][0]["opening"], false);
    assert!(v["sources"][0]["id"].is_null());
    assert!(!v["sources"][0]["error"].is_null(), "{v}");
    assert_eq!(v["sources"][0]["indexed"], false);
    // bad settings still fail the call at once
    let bad = cstr(&json!({"sources":[{"kind":"library","path":f.dir.to_str().unwrap(),"settings":{"library_id":"x"}}]}).to_string());
    assert_eq!(unsafe { cs_set_sources(h, bad.as_ptr()) }, -1);
    assert_eq!(handle_code(h), "bad_json");
    unsafe { cs_close(h) };
}

#[test]
fn closing_the_handle_while_a_library_is_still_opening_is_safe() {
    let f = shared();
    for _ in 0..3 {
        let h = open_nowait(&f.dir, None, "/nonexistent/idx", 300);
        assert_eq!(status(h)["sources"][0]["opening"], true);
        unsafe { cs_close(h) };
    }
    // and with the open already running (no delay): close at once
    for _ in 0..3 {
        let h = open_nowait(&f.dir, Some(settings(default_leave_out(), true)), "/nonexistent/idx", 0);
        unsafe { cs_close(h) };
    }
    // let the detached threads finish and drop their shards; the process must still be fine
    std::thread::sleep(std::time::Duration::from_millis(1500));
    let h = open(&f.dir, None);
    assert_eq!(status(h)["sources"][0]["docs"], TOTAL);
    unsafe { cs_close(h) };
}

/// A library's vector list and a ZIM's built-in Xapian keyword list join the same fusion. Needs a build with the
/// `xapian` feature (Windows/Android) and CS_TEST_ZIM_DIR; otherwise it prints why and returns.
#[cfg(zimx)]
#[test]
fn a_library_and_a_zim_with_a_builtin_index_merge() {
    let Some(dir) = std::env::var("CS_TEST_ZIM_DIR").ok().filter(|s| !s.is_empty()) else {
        eprintln!("CS_TEST_ZIM_DIR not set: skipping");
        return;
    };
    let f = shared();
    let zim = format!("{dir}/www.ready.gov_en_2024-12.zim");
    let cfg = json!({"sources": [
        {"kind": "library", "path": f.dir.to_str().unwrap(), "index_dir": "/nonexistent/idx", "settings": settings(default_leave_out(), true)},
        {"kind": "zim", "path": zim}
    ]});
    let c = cstr(&cfg.to_string());
    let h = unsafe { cs_open(c.as_ptr()) };
    assert!(!h.is_null());
    wait_ready(h);
    let v = random_vec(500);
    let opts = json!({"k": 10, "query_vector": {"model": MODEL, "vector": v}});
    let r: Value = serde_json::from_str(&take(unsafe { cs_search(h, cstr("flood").as_ptr(), cstr(&opts.to_string()).as_ptr()) }).expect("search")).unwrap();
    assert_eq!(r["vector_sources"], json!(["t"]), "{r}");
    let kinds: Vec<&str> = r["results"].as_array().unwrap().iter().map(|x| x["source_kind"].as_str().unwrap()).collect();
    assert!(kinds.contains(&"library") && kinds.contains(&"zim"), "{r}");
    assert_eq!(r["results"].as_array().unwrap().len(), 10);
    // the library's best point is still its query point; the ZIM hits carry zim: addresses and a stripped snippet
    let lib_first = r["results"].as_array().unwrap().iter().find(|x| x["source_kind"] == "library").unwrap();
    assert_eq!(lib_first["address"], "lib:t/500");
    for x in r["results"].as_array().unwrap().iter().filter(|x| x["source_kind"] == "zim") {
        assert!(x["address"].as_str().unwrap().starts_with("zim:"));
        assert!(!x["snippet"].as_str().unwrap().contains('<'));
    }
    unsafe { cs_close(h) };
}
