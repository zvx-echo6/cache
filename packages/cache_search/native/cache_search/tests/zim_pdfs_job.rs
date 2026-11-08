//! The PDF list of a large ZIM (build 46: 15 s and +2.2 GB resident at every start for a full Wikipedia, on the core's one worker).
//! A synthetic ZIM with two million entries stands in for it here: the old way (each entry parsed through a whole-file mapping)
//! and the new one (the mime type of each entry read through bounded windows, as a job on its own thread) are timed on the
//! same file, with the resident memory each adds, and the core's calls are timed while the job runs. One test in this file,
//! so nothing else in the process moves its resident memory meanwhile. The numbers are printed for the CI log.

use cache_search::ffi::*;
use cache_search::handle::Handle;
use cache_search::job::Job;
use serde_json::{json, Value};
use std::ffi::{c_char, CStr, CString};
use std::path::{Path, PathBuf};
use std::ptr;
use std::time::{Duration, Instant};

const UUID: &str = "0badc0de-0000-4000-8000-0000000f00d5";
const NO_PDF_UUID: &str = "0badc0de-0000-4000-8000-0000000f00d6";

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
    serde_json::from_str(&take(p).unwrap_or_else(|| panic!("call failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) })))).unwrap()
}

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-zimpdfs-{}-{}", std::process::id(), name));
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

/// The process's resident memory in MiB (Linux), else None.
fn rss_mib() -> Option<f64> {
    let s = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = s.lines().find(|l| l.starts_with("VmRSS:"))?;
    let kb: f64 = line.split_whitespace().nth(1)?.parse().ok()?;
    Some(kb / 1024.0)
}

/// One entry: (namespace, path, mime id or 0xffff for a redirect, cluster, blob).
type Ent = (u8, String, u16, u32, u32);

/// Writes a ZIM (major 6, minor 1) with `articles` HTML entries (all on one blob), `redirects` redirects, the PDFs `pdf_sizes`
/// (each its own blob of that size in a second, uncompressed cluster) and the metadata Name and Title. `pdf_mime` false leaves
/// application/pdf out of the mime list (and writes no PDFs), as a full Wikipedia has it.
fn write_zim(path: &Path, uuid: &str, articles: usize, redirects: usize, pdf_sizes: &[usize], pdf_mime: bool) {
    let mime: &[u8] = if pdf_mime { b"text/html\0application/pdf\0text/plain\0\0" } else { b"text/html\0text/plain\0\0" };
    let (m_pdf, m_text) = if pdf_mime { (1u16, 2u16) } else { (u16::MAX, 1u16) };
    // sorted by (namespace, path): C/A..., C/R..., C/docs/..., M/Name, M/Title
    let mut ents: Vec<Ent> = Vec::with_capacity(articles + redirects + pdf_sizes.len() + 2);
    for i in 0..articles {
        ents.push((b'C', format!("A{i:07}"), 0, 0, 0));
    }
    for i in 0..redirects {
        ents.push((b'C', format!("R{i:07}"), 0xffff, 0, 0));
    }
    if pdf_mime {
        for (j, _) in pdf_sizes.iter().enumerate() {
            ents.push((b'C', format!("docs/{j:03}.pdf"), m_pdf, 1, j as u32));
        }
    }
    ents.push((b'M', "Name".into(), m_text, 0, 1));
    ents.push((b'M', "Title".into(), m_text, 0, 2));
    let n = ents.len();

    let cluster = |blobs: &[Vec<u8>]| -> Vec<u8> {
        let mut c = vec![1u8];
        let mut off = (4 * (blobs.len() + 1)) as u32;
        let mut offs = Vec::new();
        for b in blobs {
            offs.push(off);
            off += b.len() as u32;
        }
        offs.push(off);
        for o in offs {
            c.extend_from_slice(&o.to_le_bytes());
        }
        for b in blobs {
            c.extend_from_slice(b);
        }
        c
    };
    let c0 = cluster(&[b"<html><body><p>water</p></body></html>".to_vec(), b"big_test".to_vec(), b"Big test".to_vec()]);
    let pdf_blobs: Vec<Vec<u8>> = if pdf_mime { pdf_sizes.iter().map(|s| vec![b'%'; *s]).collect() } else { vec![b"-".to_vec()] };
    let c1 = cluster(&pdf_blobs);

    let mime_pos = 80u64;
    let url_ptr_pos = mime_pos + mime.len() as u64;
    let title_ptr_pos = url_ptr_pos + 8 * n as u64;
    let cluster_ptr_pos = title_ptr_pos + 4 * n as u64;
    let c0_pos = cluster_ptr_pos + 16;
    let c1_pos = c0_pos + c0.len() as u64;
    let entries_pos = c1_pos + c1.len() as u64;

    let mut dirents: Vec<u8> = Vec::with_capacity(n * 28);
    let mut ptrs: Vec<u8> = Vec::with_capacity(n * 8);
    for e in &ents {
        ptrs.extend_from_slice(&(entries_pos + dirents.len() as u64).to_le_bytes());
        dirents.extend_from_slice(&e.2.to_le_bytes());
        dirents.push(0);
        dirents.push(e.0);
        dirents.extend_from_slice(&0u32.to_le_bytes());
        if e.2 == 0xffff {
            dirents.extend_from_slice(&0u32.to_le_bytes()); // redirect to the first entry
        } else {
            dirents.extend_from_slice(&e.3.to_le_bytes());
            dirents.extend_from_slice(&e.4.to_le_bytes());
        }
        dirents.extend_from_slice(e.1.as_bytes());
        dirents.push(0);
        dirents.push(0); // no title: the path is the title
    }
    let checksum_pos = entries_pos + dirents.len() as u64;

    let mut out: Vec<u8> = Vec::with_capacity(checksum_pos as usize + 16);
    out.extend_from_slice(&0x044D495Au32.to_le_bytes());
    out.extend_from_slice(&6u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    let id: Vec<u8> = (0..16).map(|i| u8::from_str_radix(&uuid.replace('-', "")[2 * i..2 * i + 2], 16).unwrap()).collect();
    out.extend_from_slice(&id);
    out.extend_from_slice(&(n as u32).to_le_bytes());
    out.extend_from_slice(&2u32.to_le_bytes());
    for v in [url_ptr_pos, title_ptr_pos, cluster_ptr_pos, mime_pos] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&u32::MAX.to_le_bytes());
    out.extend_from_slice(&u32::MAX.to_le_bytes());
    out.extend_from_slice(&checksum_pos.to_le_bytes());
    assert_eq!(out.len(), 80);
    out.extend_from_slice(mime);
    out.extend_from_slice(&ptrs);
    for i in 0..n as u32 {
        out.extend_from_slice(&i.to_le_bytes()); // titles are the paths: the same order
    }
    out.extend_from_slice(&c0_pos.to_le_bytes());
    out.extend_from_slice(&c1_pos.to_le_bytes());
    out.extend_from_slice(&c0);
    out.extend_from_slice(&c1);
    out.extend_from_slice(&dirents);
    out.extend_from_slice(&[0u8; 16]);
    std::fs::write(path, out).unwrap();
}

/// The PDF list as build 46 made it: every entry parsed (path and title read and allocated) through the ZIM's whole-file
/// mapping, which stays open (the core kept the reader).
fn list_the_old_way(path: &Path) -> (Vec<(String, u64)>, zim::Zim) {
    let z = zim::Zim::new(path).unwrap();
    let mut cands = Vec::new();
    for idx in 0..z.header.article_count {
        let Ok(e) = z.get_by_url_index(idx) else { continue };
        if !matches!(e.namespace, zim::Namespace::UserContent | zim::Namespace::Articles) {
            continue;
        }
        let zim::MimeType::Type(m) = &e.mime_type else { continue };
        if !m.to_ascii_lowercase().starts_with("application/pdf") {
            continue;
        }
        let Some(zim::Target::Cluster(c, b)) = e.target else { continue };
        cands.push((e.url, c, b));
    }
    let mut out = Vec::new();
    for (url, c, b) in cands {
        let cl = z.get_cluster(c).unwrap();
        let g = cl.read().unwrap();
        out.push((url, g.blob(b).unwrap().len() as u64));
    }
    out.sort();
    (out, z)
}

fn pdfs_of(v: &Value) -> Vec<(String, u64)> {
    v["pdfs"].as_array().unwrap().iter().map(|p| (p["path"].as_str().unwrap().to_string(), p["size"].as_u64().unwrap())).collect()
}

fn start_job(kind: &str, params: Value) -> *mut Job {
    let j = unsafe { cs_job_start(cstr(kind).as_ptr(), cstr(&params.to_string()).as_ptr()) };
    assert!(!j.is_null(), "{kind}: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    j
}

fn progress(j: *mut Job) -> Value {
    serde_json::from_str(&take(unsafe { cs_job_progress(j) }).unwrap()).unwrap()
}

fn open_handle(zim: &Path) -> *mut Handle {
    let cfg = json!({"sources": [{"kind": "zim", "path": zim, "builtin_index": false}]});
    let h = unsafe { cs_open(cstr(&cfg.to_string()).as_ptr()) };
    assert!(!h.is_null(), "cs_open failed: {:?}", take(unsafe { cs_last_error(ptr::null_mut()) }));
    h
}

#[test]
fn the_pdf_list_of_a_large_zim_is_small_quick_and_off_the_worker() {
    let tmp = TempDir::new("big");
    let big = tmp.0.join("big.zim");
    let sizes = [1200usize, 34, 77_000, 5, 640];
    const ARTICLES: usize = 2_000_000;
    let t = Instant::now();
    write_zim(&big, UUID, ARTICLES, 200_000, &sizes, true);
    eprintln!("synthetic ZIM: {} entries, {} MB, written in {:?}", ARTICLES + 200_000 + sizes.len() + 2, std::fs::metadata(&big).unwrap().len() >> 20, t.elapsed());
    let want: Vec<(String, u64)> = sizes.iter().enumerate().map(|(j, s)| (format!("docs/{j:03}.pdf"), *s as u64)).collect();

    // the core's worker is free while the job runs: a call on a handle answers at once
    let h = open_handle(&big);
    call(unsafe { cs_status(h) });
    // the new way, as the job: its own thread, bounded windows, mime types only
    let rss0 = rss_mib();
    let t = Instant::now();
    let j = start_job("zim_pdfs", json!({"zim_path": big}));
    let start_took = t.elapsed();
    let mut worst_call = Duration::ZERO;
    let mut calls_while_running = 0;
    let mut peak = rss0;
    let p = loop {
        let p = progress(j);
        if p["state"] != "running" {
            break p;
        }
        let c = Instant::now();
        let st = call(unsafe { cs_status(h) });
        assert_eq!(st["sources"][0]["id"], UUID);
        worst_call = worst_call.max(c.elapsed());
        calls_while_running += 1;
        peak = match (peak, rss_mib()) {
            (Some(a), Some(b)) => Some(a.max(b)),
            (a, b) => a.or(b),
        };
        assert!(t.elapsed() < Duration::from_secs(120), "the job is stuck: {p}");
        std::thread::sleep(Duration::from_millis(5));
    };
    let job_took = t.elapsed();
    assert_eq!(p["state"], "done", "{p}");
    let r = &p["result"];
    assert_eq!(r["zim_uuid"], UUID);
    assert_eq!(r["zim_name"], "big_test");
    assert_eq!(pdfs_of(r), want);
    assert_eq!(p["done"], p["total"]);
    unsafe { cs_job_free(j) };
    let rss_new = rss_mib();

    // cs_zim_pdfs gives the same list (the same pass, on the caller's thread)
    let t = Instant::now();
    let direct = call(unsafe { cs_zim_pdfs(h, cstr(UUID).as_ptr()) });
    let direct_took = t.elapsed();
    assert_eq!(pdfs_of(&direct), want);
    assert_eq!(direct["zim_name"], "big_test");
    unsafe { cs_close(h) };

    // the old way on the same file
    let before = rss_mib();
    let t = Instant::now();
    let (old, reader) = list_the_old_way(&big);
    let old_took = t.elapsed();
    let rss_old = rss_mib();
    assert_eq!(old, want);
    drop(reader);

    let mb = |a: Option<f64>, b: Option<f64>| a.zip(b).map(|(a, b)| format!("{:+.0} MB", b - a)).unwrap_or_else(|| "n/a".into());
    eprintln!(
        "PDF list, 2.2 M entries: before (whole-file mapping, every entry parsed, on the worker) {old_took:?}, resident {}; \
         after (job: windows, mime type only) {job_took:?} on its own thread (start {start_took:?}), resident at peak {} and {} after; \
         cs_zim_pdfs now {direct_took:?}; {calls_while_running} core calls answered while it ran, the slowest {worst_call:?}",
        mb(before, rss_old),
        mb(rss0, peak),
        mb(rss0, rss_new),
    );
    // the worker is never held: starting the job is immediate and calls are answered meanwhile
    assert!(start_took < Duration::from_millis(200), "starting the job took {start_took:?}");
    assert!(worst_call < Duration::from_millis(500), "a core call waited {worst_call:?} while the list was made");
    // the result is small: the pass keeps a few MiB mapped, not the directory (the old way keeps all of it resident)
    if let (Some(a), Some(b)) = (rss0, peak) {
        assert!(b - a < 48.0, "the pass made the process {:.0} MB larger", b - a);
    }

    // A ZIM whose mime list has no PDF (a full Wikipedia): nothing is read.
    let none = tmp.0.join("none.zim");
    write_zim(&none, NO_PDF_UUID, ARTICLES, 0, &[], false);
    let t = Instant::now();
    let j = start_job("zim_pdfs", json!({"zim_path": none}));
    let p = loop {
        let p = progress(j);
        if p["state"] != "running" {
            break p;
        }
        std::thread::sleep(Duration::from_millis(1));
    };
    let none_took = t.elapsed();
    unsafe { cs_job_free(j) };
    assert_eq!(p["state"], "done", "{p}");
    assert_eq!(p["result"]["pdfs"], json!([]));
    let t = Instant::now();
    let (old_none, reader) = list_the_old_way(&none);
    let old_none_took = t.elapsed();
    drop(reader);
    assert!(old_none.is_empty());
    eprintln!("no PDFs in the mime list, 2 M entries: before {old_none_took:?}, after {none_took:?}");
    assert!(none_took < Duration::from_millis(500), "a ZIM without PDFs is not scanned: {none_took:?}");

    // cancel stops the pass
    let j = start_job("zim_pdfs", json!({"zim_path": big}));
    unsafe { cs_job_cancel(j) };
    let t = Instant::now();
    let p = loop {
        let p = progress(j);
        if p["state"] != "running" {
            break p;
        }
        assert!(t.elapsed() < Duration::from_secs(30));
        std::thread::sleep(Duration::from_millis(2));
    };
    unsafe { cs_job_free(j) };
    assert!(p["state"] == "cancelled" || p["state"] == "done", "{p}");

    // bad parameters and a missing file
    assert!(unsafe { cs_job_start(cstr("zim_pdfs").as_ptr(), cstr("{}").as_ptr()) }.is_null());
    let j = start_job("zim_pdfs", json!({"zim_path": tmp.0.join("missing.zim")}));
    let p = loop {
        let p = progress(j);
        if p["state"] != "running" {
            break p;
        }
        std::thread::sleep(Duration::from_millis(2));
    };
    unsafe { cs_job_free(j) };
    assert_eq!(p["state"], "failed", "{p}");
}
