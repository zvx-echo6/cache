//! The PDF index of a ZIM: building it (session calls and the `pdfindex_finish` job), publishing it as a snapshot, and
//! searching it with its ZIM. The ZIM is a tiny one written here; the snapshots are built through the C ABI.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::job::Job;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::time::{Duration, Instant};

const UUID: &str = "0badc0de-0000-4000-8000-00000000cafe";
const OTHER: &str = "0badc0de-0000-4000-8000-00000000beef";

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

fn call(p: *mut c_char) -> Value {
    serde_json::from_str(
        &take(p).unwrap_or_else(|| panic!("call failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }))),
    )
    .unwrap()
}

fn last_code() -> String {
    let e: Value = serde_json::from_str(&take(unsafe { cs_last_error(ptr::null_mut()) }).expect("an error")).unwrap();
    e["code"].as_str().unwrap().to_string()
}

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-pdfidx-{}-{}", std::process::id(), name));
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

/// Write a minimal valid ZIM (major 6, minor 1: the `C` namespace for content, `M` for metadata): articles in one
/// uncompressed cluster, no `X/` index entries. libzim reports `hasFulltextIndex() == false` for it.
fn write_tiny_zim(path: &Path, uuid: &str) {
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
    let uuid: Vec<u8> =
        (0..16).map(|i| u8::from_str_radix(&uuid.replace('-', "")[2 * i..2 * i + 2], 16).unwrap()).collect();
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

type Pdf = (&'static str, &'static str, Vec<(u64, &'static str)>);

fn pdfs() -> Vec<Pdf> {
    vec![
        (
            "Manuals/a.pdf",
            "Manual A",
            vec![
                (1, "Intro about widgets and nothing else."),
                (2, "Page two first piece: torque specification for bolts."),
                (2, "Page two second piece: lubricate the bearings."),
                (3, "Page three: storage."),
            ],
        ),
        ("Manuals/b.pdf", "Manual B", vec![(7, "Seventh page about wiring torque.")]),
    ]
}

fn pieces_json(pieces: &[(u64, &str)]) -> Value {
    Value::Array(
        pieces
            .iter()
            .enumerate()
            .map(|(i, (page, text))| json!({"i": i, "text": text, "page": page.to_string(), "pdf_page": page, "heading_path": []}))
            .collect(),
    )
}

fn open_session(idx: &Path, uuid: &str, batch: Option<usize>) -> Value {
    let mut p = json!({"indexes_dir": idx, "zim_uuid": uuid, "zim_name": "tiny"});
    if let Some(b) = batch {
        p["batch_pdfs"] = json!(b);
    }
    call(unsafe { cs_pdfindex_open(cstr(&p.to_string()).as_ptr()) })
}

fn add(session: u64, pdf: &Pdf) -> Value {
    let p = json!({"path": pdf.0, "title": pdf.1, "pieces": pieces_json(&pdf.2)});
    call(unsafe { cs_pdfindex_add(session, cstr(&p.to_string()).as_ptr()) })
}

fn close(session: u64) -> Value {
    call(cs_pdfindex_close(session))
}

fn wait_job(j: *mut Job) -> Value {
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

fn start(kind: &str, params: Value) -> *mut Job {
    let j = unsafe { cs_job_start(cstr(kind).as_ptr(), cstr(&params.to_string()).as_ptr()) };
    assert!(!j.is_null(), "job {kind} did not start: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    j
}

fn finish(idx: &Path, uuid: &str) -> Value {
    let j = start("pdfindex_finish", json!({"indexes_dir": idx, "zim_uuid": uuid}));
    let p = wait_job(j);
    unsafe { cs_job_free(j) };
    assert_eq!(p["state"], "done", "{p}");
    p
}

/// Build and publish a snapshot of `docs` for `uuid`; returns the job's result.
fn build_snapshot(idx: &Path, uuid: &str, docs: &[Pdf]) -> Value {
    let s = open_session(idx, uuid, None);
    let id = s["session"].as_u64().unwrap();
    for d in docs {
        add(id, d);
    }
    close(id);
    finish(idx, uuid)["result"].clone()
}

fn snap_dir(idx: &Path, uuid: &str) -> PathBuf {
    idx.join("zim-pdf").join(uuid).join("snap")
}

fn snapshots(idx: &Path, uuid: &str) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(snap_dir(idx, uuid))
        .map(|rd| rd.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default();
    v.sort();
    v
}

fn open_handle(zim: &Path, idx: Option<&Path>, zim_index: Option<&Path>) -> *mut Handle {
    let mut src = json!({"kind": "zim", "path": zim, "builtin_index": false});
    if let Some(d) = zim_index {
        src["index_dir"] = json!(d);
    }
    let mut cfg = json!({"sources": [src]});
    if let Some(d) = idx {
        cfg["indexes_dir"] = json!(d);
    }
    let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
    assert!(!h.is_null(), "cs_open failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    h
}

fn status(h: *mut Handle) -> Value {
    serde_json::from_str(&take(unsafe { cs_status(h) }).unwrap()).unwrap()
}

/// The status once the PDF index (if any) has finished opening.
fn settle(h: *mut Handle) -> Value {
    let t0 = Instant::now();
    loop {
        let st = status(h);
        if st["sources"].as_array().unwrap().iter().all(|s| s["pdfindex"]["state"] != "opening") {
            return st;
        }
        assert!(t0.elapsed() < Duration::from_secs(60), "pdf index did not open");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn tool(h: *mut Handle, c: *mut cache_search::conv::Conversation, name: &str, args: Value) -> Value {
    let r = take(unsafe {
        cs_tool(h, c, cstr(name).as_ptr(), cstr(&args.to_string()).as_ptr(), cstr("2026-11-02T12:00:00Z").as_ptr())
    });
    serde_json::from_str(&r.unwrap_or_else(|| panic!("cs_tool failed: {:?}", take(unsafe { cs_last_error(h) }))))
        .unwrap()
}

struct Env {
    _tmp: TempDir,
    root: PathBuf,
    zim: PathBuf,
    idx: PathBuf,
    zim_idx: PathBuf,
}

fn env(name: &str) -> Env {
    let tmp = TempDir::new(name);
    let root = tmp.0.clone();
    let zim = root.join("tiny.zim");
    write_tiny_zim(&zim, UUID);
    let (idx, zim_idx) = (root.join("indexes"), root.join("zim-idx"));
    let j = start("index_zim", json!({"zim_path": zim, "index_dir": zim_idx}));
    assert_eq!(wait_job(j)["state"], "done");
    unsafe { cs_job_free(j) };
    Env { _tmp: tmp, root, zim, idx, zim_idx }
}

#[test]
fn the_snapshot_is_attached_and_its_hits_cite_the_page() {
    let e = env("attach");
    let built = build_snapshot(&e.idx, UUID, &pdfs());
    assert_eq!(built["pdfs"], 2);
    assert_eq!(built["pieces"], 5);
    assert_eq!(snapshots(&e.idx, UUID), vec![built["snapshot"].as_str().unwrap().to_string()]);
    assert!(!e.idx.join("zim-pdf").join(UUID).join(".build").exists(), "the build is removed after publishing");

    let h = open_handle(&e.zim, Some(&e.idx), Some(&e.zim_idx));
    let st = settle(h);
    let zim = &st["sources"][0];
    assert_eq!(zim["pdfindex"]["state"], "ready");
    assert_eq!(zim["pdfindex"]["kind"], "zim-pdf");
    assert_eq!(zim["pdfindex"]["pieces"], 5);
    assert_eq!(zim["source_id"], UUID);
    assert_eq!(zim["index"]["kind"], "zim");

    let c = cs_conversation_new();
    let r = tool(h, c, "search", json!({"query": "torque"}));
    let content = r["content"].as_str().unwrap();
    println!("SEARCH TEXT:\n{content}");
    // the model's lines keep today's shape: number, "Title, p. <label>", an em dash and the snippet; nothing of the link, page or quote
    let line = content
        .lines()
        .find(|l| l.contains("Manual A, p. 2 \u{2014} Page two first piece"))
        .unwrap_or_else(|| panic!("{content}"));
    assert!(line.starts_with('[') && !line.contains("{{addr"), "{line}");
    assert!(!content.contains("#page") && !content.contains("pdf_page") && !content.contains("quote"), "{content}");
    let ids = r["ids"].as_array().unwrap();
    let a = ids.iter().find(|i| i["title"].as_str().unwrap().starts_with("Manual A")).unwrap();
    assert_eq!(a["link"], "zim:0badc0de-0000-4000-8000-00000000cafe/Manuals/a.pdf#page=2");
    assert_eq!(a["pdf_page"], 2);
    assert_eq!(a["quote"], "Page two first piece: torque specification for bolts.");
    assert!(a["address"].as_str().unwrap().starts_with("zimpdf:0badc0de"));
    let b = ids.iter().find(|i| i["title"].as_str().unwrap().starts_with("Manual B")).unwrap();
    assert_eq!(b["link"], "zim:0badc0de-0000-4000-8000-00000000cafe/Manuals/b.pdf#page=7");
    println!("PDF CITE: {a}");

    // a normal hit (an article of the ZIM): link/time/pdf fields absent, as before
    let r2 = tool(h, c, "search", json!({"query": "flood"}));
    let n = r2["ids"].as_array().unwrap().iter().find(|i| i["address"].as_str().unwrap().starts_with("zim:")).unwrap();
    assert!(n.get("pdf_page").is_none() && n.get("quote").is_none() && n.get("link").is_none(), "{n}");
    println!("NORMAL CITE: {n}");

    // read [n] of a PDF hit: every piece that starts on the page, in document order, in today's read shape
    let rd = tool(h, c, "read", json!({"n": a["n"]}));
    let text = rd["content"].as_str().unwrap();
    println!("READ:\n{text}");
    assert!(text.starts_with(&format!("[{}] Manual A\nPage: 2\n\n", a["n"])), "{text}");
    assert!(text.find("Page two first piece").unwrap() < text.find("Page two second piece").unwrap(), "{text}");
    assert!(!text.contains("Intro about widgets") && !text.contains("Page three"), "{text}");

    // a sources filter on the ZIM includes its PDF index; on another id it does not
    let o = cstr(&json!({"k": 5, "sources": [UUID]}).to_string());
    let s = call(unsafe { cs_search(h, cstr("torque").as_ptr(), o.as_ptr()) });
    assert!(
        s["results"].as_array().unwrap().iter().any(|r| r["address"].as_str().unwrap().starts_with("zimpdf:")),
        "{s}"
    );
    let o = cstr(&json!({"k": 5, "sources": [OTHER]}).to_string());
    let s = call(unsafe { cs_search(h, cstr("torque").as_ptr(), o.as_ptr()) });
    assert!(s["results"].as_array().unwrap().is_empty());
    unsafe { cs_conversation_free(c) };
    unsafe { cs_close(h) };
}

#[test]
fn a_snapshot_for_a_zim_that_is_not_loaded_is_never_attached() {
    let e = env("other");
    build_snapshot(&e.idx, OTHER, &pdfs());
    let h = open_handle(&e.zim, Some(&e.idx), Some(&e.zim_idx));
    let st = settle(h);
    assert!(st["sources"][0].get("pdfindex").is_none(), "{st}");
    let c = cs_conversation_new();
    let r = tool(h, c, "search", json!({"query": "torque"}));
    assert!(!r["content"].as_str().unwrap().contains("Manual A"));
    unsafe { cs_conversation_free(c) };
    unsafe { cs_close(h) };
}

#[test]
fn without_an_indexes_dir_there_is_no_pdf_attach() {
    let e = env("noidx");
    build_snapshot(&e.idx, UUID, &pdfs());
    let h = open_handle(&e.zim, None, Some(&e.zim_idx));
    let st = settle(h);
    assert!(st["sources"][0].get("pdfindex").is_none(), "{st}");
    unsafe { cs_close(h) };
}

#[test]
fn a_kill_between_adds_then_resume_leaves_no_duplicates() {
    let e = env("resume");
    let p = pdfs();
    // commit after every 2 PDFs: A and B are committed, C is added but the process "dies" before the commit
    let c_pdf: Pdf = ("Manuals/c.pdf", "Manual C", vec![(1, "Manual C first page about torque.")]);
    let s = open_session(&e.idx, UUID, Some(2));
    let id = s["session"].as_u64().unwrap();
    assert_eq!(s["done"], json!([]));
    add(id, &p[0]);
    let r = add(id, &p[1]);
    assert_eq!(r["committed"], 2);
    add(id, &c_pdf);
    cache_search::pdfbuild::abandon_for_test(id);

    // resume: only A and B are done; adding C and re-adding B (a replace) must not duplicate anything
    let s = open_session(&e.idx, UUID, Some(2));
    let id = s["session"].as_u64().unwrap();
    assert_eq!(s["done"], json!(["Manuals/a.pdf", "Manuals/b.pdf"]), "{s}");
    assert_eq!(s["pieces"], 5);
    add(id, &c_pdf);
    let r = add(id, &p[1]);
    assert_eq!(r["pieces"], 6, "A 4 + B 1 + C 1");
    close(id);
    let built = finish(&e.idx, UUID)["result"].clone();
    assert_eq!(built["pieces"], 6, "{built}");
    assert_eq!(built["pdfs"], 3);

    // a crash after a commit but before done.tsv recorded it: the PDF is simply added again
    let dir = e.idx.join("zim-pdf").join(UUID).join(".build");
    assert!(!dir.exists());
    let s = open_session(&e.idx, UUID, Some(1));
    let id = s["session"].as_u64().unwrap();
    add(id, &p[0]);
    add(id, &p[1]);
    close(id);
    let done = dir.join("done.tsv");
    let text = std::fs::read_to_string(&done).unwrap();
    let kept: Vec<&str> = text.lines().take(1).collect();
    std::fs::write(&done, kept.join("\n") + "\n").unwrap();
    let s = open_session(&e.idx, UUID, Some(1));
    assert_eq!(s["done"], json!(["Manuals/a.pdf"]), "the unrecorded PDF is not done: {s}");
    let id = s["session"].as_u64().unwrap();
    assert_eq!(add(id, &p[1])["pieces"], 5, "B replaced, not duplicated");
    close(id);
    assert_eq!(finish(&e.idx, UUID)["result"]["pieces"], 5);
}

#[test]
fn a_new_zim_version_starts_a_new_build_and_old_snapshots_stay_apart() {
    let e = env("newuuid");
    let s = open_session(&e.idx, UUID, None);
    add(s["session"].as_u64().unwrap(), &pdfs()[0]);
    close(s["session"].as_u64().unwrap());
    // the same ZIM name with a new uuid: its own build, nothing carried over from the other
    let s2 = open_session(&e.idx, OTHER, None);
    assert_eq!(s2["done"], json!([]));
    assert_eq!(s2["pieces"], 0);
    close(s2["session"].as_u64().unwrap());
    // the first uuid's build is still there to resume
    let s3 = open_session(&e.idx, UUID, None);
    assert_eq!(s3["done"], json!(["Manuals/a.pdf"]));
    close(s3["session"].as_u64().unwrap());
    // discard removes only that uuid's build
    let d = call(unsafe {
        cs_pdfindex_discard(cstr(&json!({"indexes_dir": e.idx, "zim_uuid": UUID}).to_string()).as_ptr())
    });
    assert_eq!(d["discarded"], true);
    assert!(e.idx.join("zim-pdf").join(OTHER).join(".build").exists());
}

#[test]
fn publishing_is_atomic_and_a_partial_snapshot_is_never_used() {
    let e = env("atomic");
    // while a build is open nothing is published and attach sees nothing
    let s = open_session(&e.idx, UUID, None);
    add(s["session"].as_u64().unwrap(), &pdfs()[0]);
    {
        let h = open_handle(&e.zim, Some(&e.idx), Some(&e.zim_idx));
        let st = settle(h);
        assert!(st["sources"][0].get("pdfindex").is_none(), "an unpublished build is not attached: {st}");
        unsafe { cs_close(h) };
    }
    close(s["session"].as_u64().unwrap());
    // a second session on the same build is refused while the finish job holds it (busy), and the temp folder never shows in snap/
    let built = finish(&e.idx, UUID)["result"].clone();
    let name = built["snapshot"].as_str().unwrap().to_string();
    assert_eq!(snapshots(&e.idx, UUID), vec![name.clone()]);
    let leftovers: Vec<String> = std::fs::read_dir(e.idx.join("zim-pdf").join(UUID))
        .unwrap()
        .flatten()
        .map(|d| d.file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(leftovers, vec!["snap".to_string()], "no .build and no temp folder left: {leftovers:?}");

    // a copy without its manifest (a sync in progress), and one with a damaged file, are ignored
    let good = snap_dir(&e.idx, UUID).join(&name);
    let partial = snap_dir(&e.idx, UUID).join("00000000T000000Z-partial");
    copy_dir(&good, &partial);
    std::fs::remove_file(partial.join("manifest.json")).unwrap();
    let damaged = snap_dir(&e.idx, UUID).join("00000000T000001Z-damaged");
    copy_dir(&good, &damaged);
    let some = std::fs::read_dir(&damaged)
        .unwrap()
        .flatten()
        .find(|f| f.file_name().to_string_lossy().ends_with(".store"))
        .unwrap()
        .path();
    let mut b = std::fs::read(&some).unwrap();
    b[0] ^= 0xFF;
    std::fs::write(&some, b).unwrap();
    let h = open_handle(&e.zim, Some(&e.idx), Some(&e.zim_idx));
    let st = settle(h);
    assert_eq!(st["sources"][0]["pdfindex"]["snapshot"], name, "{st}");
    unsafe { cs_close(h) };
}

fn copy_dir(from: &Path, to: &Path) {
    std::fs::create_dir_all(to).unwrap();
    for f in std::fs::read_dir(from).unwrap().flatten() {
        std::fs::copy(f.path(), to.join(f.file_name())).unwrap();
    }
}

#[test]
fn a_snapshot_holds_no_absolute_paths_and_is_not_written_by_reading() {
    let e = env("clean");
    let built = build_snapshot(&e.idx, UUID, &pdfs());
    let dir = snap_dir(&e.idx, UUID).join(built["snapshot"].as_str().unwrap());
    let needle = e.root.to_string_lossy().into_owned();
    let state = |d: &Path| -> Vec<(String, u64, std::time::SystemTime)> {
        let mut v: Vec<_> = std::fs::read_dir(d)
            .unwrap()
            .flatten()
            .map(|f| {
                let m = f.metadata().unwrap();
                (f.file_name().to_string_lossy().into_owned(), m.len(), m.modified().unwrap())
            })
            .collect();
        v.sort();
        v
    };
    let mut seen = 0;
    for f in std::fs::read_dir(&dir).unwrap().flatten() {
        let bytes = std::fs::read(f.path()).unwrap();
        assert!(
            !bytes.windows(needle.len()).any(|w| w == needle.as_bytes()),
            "{} holds an absolute path",
            f.path().display()
        );
        assert!(!bytes.windows(5).any(|w| w == b"/tmp/"), "{} holds a /tmp path", f.path().display());
        seen += 1;
    }
    assert!(seen >= 5, "{seen} files");
    assert!(dir.join(".tantivy-meta.lock").exists(), "the empty meta lock is in the snapshot");
    assert!(std::fs::read_to_string(dir.join("manifest.json")).unwrap().contains("\"kind\": \"zim-pdf\""));
    // open, search and read: nothing in the snapshot changes (no file added, none touched)
    let before = state(&dir);
    let h = open_handle(&e.zim, Some(&e.idx), Some(&e.zim_idx));
    settle(h);
    let c = cs_conversation_new();
    let r = tool(h, c, "search", json!({"query": "torque"}));
    let n = r["ids"].as_array().unwrap()[0]["n"].clone();
    tool(h, c, "read", json!({"n": n}));
    unsafe { cs_conversation_free(c) };
    unsafe { cs_close(h) };
    assert_eq!(state(&dir), before, "reading a published snapshot wrote to it");
}

#[test]
fn of_several_snapshots_the_earliest_is_used_and_the_others_cleaned_up_locally() {
    let e = env("pick");
    let mut names = Vec::new();
    for _ in 0..3 {
        names.push(build_snapshot(&e.idx, UUID, &pdfs())["snapshot"].as_str().unwrap().to_string());
        std::thread::sleep(Duration::from_millis(1100));
    }
    let created = |n: &str| -> String {
        let m: Value =
            serde_json::from_slice(&std::fs::read(snap_dir(&e.idx, UUID).join(n).join("manifest.json")).unwrap())
                .unwrap();
        m["created"].as_str().unwrap().to_string()
    };
    let mut sorted = names.clone();
    sorted.sort_by_key(|n| (created(n), n.clone()));
    let h = open_handle(&e.zim, Some(&e.idx), Some(&e.zim_idx));
    let st = settle(h);
    assert_eq!(st["sources"][0]["pdfindex"]["snapshot"], sorted[0], "the earliest created is used");
    // kept: the one in use (the earliest), and the newest usable one older than it (there is none); the others go, on this device only
    let left = snapshots(&e.idx, UUID);
    assert_eq!(left, vec![sorted[0].clone()], "{left:?}");
    unsafe { cs_close(h) };
}

#[test]
fn cancel_is_honoured_until_publish_and_leaves_the_build() {
    let e = env("cancel");
    let s = open_session(&e.idx, UUID, None);
    add(s["session"].as_u64().unwrap(), &pdfs()[0]);
    close(s["session"].as_u64().unwrap());
    let j = start("pdfindex_finish", json!({"indexes_dir": e.idx, "zim_uuid": UUID, "hold_ms": 5000}));
    unsafe { cs_job_cancel(j) };
    let p = wait_job(j);
    unsafe { cs_job_free(j) };
    assert_eq!(p["state"], "cancelled", "{p}");
    assert!(snapshots(&e.idx, UUID).is_empty());
    let build = e.idx.join("zim-pdf").join(UUID).join(".build");
    assert!(build.exists());
    // the build resumes and can be finished afterwards
    let s = open_session(&e.idx, UUID, None);
    assert_eq!(s["done"], json!(["Manuals/a.pdf"]));
    close(s["session"].as_u64().unwrap());
    assert_eq!(finish(&e.idx, UUID)["result"]["pieces"], 4);
    // a finish with no build is not_found; with a session open it is busy
    let j = unsafe {
        cs_job_start(
            cstr("pdfindex_finish").as_ptr(),
            cstr(&json!({"indexes_dir": e.idx, "zim_uuid": UUID}).to_string()).as_ptr(),
        )
    };
    assert!(j.is_null());
    assert_eq!(last_code(), "not_found");
    let s = open_session(&e.idx, UUID, None);
    let j = unsafe {
        cs_job_start(
            cstr("pdfindex_finish").as_ptr(),
            cstr(&json!({"indexes_dir": e.idx, "zim_uuid": UUID}).to_string()).as_ptr(),
        )
    };
    assert!(j.is_null());
    assert_eq!(last_code(), "busy");
    close(s["session"].as_u64().unwrap());
}

#[test]
fn zim_pdfs_lists_the_pdfs_of_a_zim() {
    let tmp = TempDir::new("list");
    let zim = tmp.0.join("tiny.zim");
    write_tiny_zim(&zim, UUID);
    let h = open_handle(&zim, None, None);
    // the tiny ZIM has no PDFs
    let r = call(unsafe { cs_zim_pdfs(h, cstr(UUID).as_ptr()) });
    assert_eq!(r["zim_uuid"], UUID);
    assert_eq!(r["pdfs"], json!([]));
    assert!(unsafe { cs_zim_pdfs(h, cstr(OTHER).as_ptr()) }.is_null());
    unsafe { cs_close(h) };
}

const SHA_A: &str = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const SHA_B: &str = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";

fn add_with(session: u64, pdf: &Pdf, size: u64, sha: &str) -> Value {
    let p = json!({"path": pdf.0, "title": pdf.1, "pieces": pieces_json(&pdf.2), "size": size, "sha256": sha});
    call(unsafe { cs_pdfindex_add(session, cstr(&p.to_string()).as_ptr()) })
}

fn reuse(session: u64, path: &str, sha: &str) -> Value {
    call(unsafe { cs_pdfindex_reuse(session, cstr(&json!({"path": path, "sha256": sha}).to_string()).as_ptr()) })
}

#[test]
fn the_snapshot_lists_its_pdfs_and_a_new_edition_reuses_unchanged_ones() {
    let e = env("reuse");
    let p = pdfs();
    // edition 1: A added, B skipped (no text), both with the size and sha256 of their bytes
    let s = open_session(&e.idx, UUID, None);
    let id = s["session"].as_u64().unwrap();
    add_with(id, &p[0], 100, SHA_A);
    call(unsafe {
        cs_pdfindex_skip(
            id,
            cstr(&json!({"path": "Manuals/c.pdf", "reason": "no_text", "size": 7, "sha256": SHA_B}).to_string())
                .as_ptr(),
        )
    });
    add_with(id, &p[1], 50, SHA_B);
    close(id);
    let built = finish(&e.idx, UUID)["result"].clone();
    assert_eq!((built["pdfs"].as_u64(), built["skipped"].as_u64()), (Some(2), Some(1)), "{built}");
    let dir = snap_dir(&e.idx, UUID).join(built["snapshot"].as_str().unwrap());
    let tsv = std::fs::read_to_string(dir.join("pdfs.tsv")).unwrap();
    let rows: Vec<&str> = tsv.lines().collect();
    assert_eq!(
        rows,
        vec![
            format!("Manuals/a.pdf\t100\t{SHA_A}\t4\tadded"),
            format!("Manuals/b.pdf\t50\t{SHA_B}\t1\tadded"),
            format!("Manuals/c.pdf\t7\t{SHA_B}\t0\tskipped:no_text"),
        ]
    );
    let manifest: Value = serde_json::from_slice(&std::fs::read(dir.join("manifest.json")).unwrap()).unwrap();
    assert!(manifest["files"].as_array().unwrap().iter().any(|f| f["path"] == "pdfs.tsv"));
    assert_eq!(manifest["source_id"], UUID);

    // edition 2 (a new uuid, the same ZIM name): A is unchanged and is copied; B changed (other hash) and is extracted again
    let mut open = json!({"indexes_dir": e.idx, "zim_uuid": OTHER, "zim_name": "tiny", "previous": {"zim_uuid": UUID}});
    let s2 = call(unsafe { cs_pdfindex_open(cstr(&open.to_string()).as_ptr()) });
    assert_eq!(
        s2["reusable"],
        json!([{"path": "Manuals/a.pdf", "size": 100, "sha256": SHA_A}, {"path": "Manuals/b.pdf", "size": 50, "sha256": SHA_B}])
    );
    let id2 = s2["session"].as_u64().unwrap();
    assert_eq!(reuse(id2, "Manuals/a.pdf", SHA_A), json!({"reused": true, "pieces": 4}));
    assert_eq!(reuse(id2, "Manuals/b.pdf", SHA_A), json!({"reused": false}), "another hash is not reused");
    assert_eq!(reuse(id2, "Manuals/nope.pdf", SHA_A), json!({"reused": false}));
    add_with(id2, &p[1], 51, SHA_A);
    close(id2);
    let built2 = finish(&e.idx, OTHER)["result"].clone();
    assert_eq!(built2["pieces"], 5, "{built2}");
    let tsv2 =
        std::fs::read_to_string(snap_dir(&e.idx, OTHER).join(built2["snapshot"].as_str().unwrap()).join("pdfs.tsv"))
            .unwrap();
    assert!(tsv2.contains(&format!("Manuals/a.pdf\t100\t{SHA_A}\t4\tadded")), "{tsv2}");

    // the reused pieces are the same text, and a previous edition of another ZIM name is not offered
    let h = open_handle(&e.zim, Some(&e.idx), Some(&e.zim_idx));
    settle(h);
    unsafe { cs_close(h) };
    open["zim_name"] = json!("other-name");
    open["zim_uuid"] = json!("0badc0de-0000-4000-8000-0000000000aa");
    let s3 = call(unsafe { cs_pdfindex_open(cstr(&open.to_string()).as_ptr()) });
    assert_eq!(s3["reusable"], json!([]));
    close(s3["session"].as_u64().unwrap());
}
