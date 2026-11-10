//! The ZIM's own icon (`cs_zim_illustration`, `Handle::zim_illustration`): the `Illustration_48x48@1` metadata of tiny ZIMs written
//! here. A ZIM with a PNG illustration answers it (base64 in JSON); one with none, or with something that is not a PNG, answers
//! `not_found`; an unknown id is `not_found` too. No ZIM checked into the repository carries an illustration, so these are written.

use cache_search::handle::Handle;
use cache_search::ErrorCode;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

const U_ICON: &str = "0badc0de-0000-4000-8000-0000000010c0";
const U_NONE: &str = "0badc0de-0000-4000-8000-0000000010c1";
const U_JUNK: &str = "0badc0de-0000-4000-8000-0000000010c2";

/// The 8-byte PNG signature and a few more bytes: the core checks the signature, not the picture.
const PNG: [u8; 12] = [0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 254];

struct TempDir(PathBuf);
impl TempDir {
    fn new(name: &str) -> TempDir {
        let p = std::env::temp_dir().join(format!("cs-zimicon-{}-{}", std::process::id(), name));
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

const MIMES: [&str; 2] = ["text/html", "text/plain"];

fn mime_index(mimes: &[&str], m: &str) -> u16 {
    mimes.iter().position(|x| *x == m).unwrap() as u16
}

/// A minimal valid ZIM (major 6, minor 1) holding `entries` (namespace `C`: path, title, mime, bytes), the metadata `Language`,
/// `Title` and `Name` and, when given, the `Illustration_48x48@1` metadata, in one uncompressed cluster (as kw_ffi.rs writes it).
fn write_zim(path: &Path, uuid: &str, name: &str, entries: &[(&str, &str, &str, Vec<u8>)], illustration: Option<&[u8]>) {
    let mimes = &MIMES;
    let mut all: Vec<(u8, String, String, u16, Vec<u8>)> = entries
        .iter()
        .map(|(p, t, m, b)| (b'C', p.to_string(), t.to_string(), mime_index(mimes, m), b.clone()))
        .collect();
    for (k, v) in [("Language", "eng"), ("Title", "Media test"), ("Name", name)] {
        all.push((b'M', k.into(), k.into(), 1, v.as_bytes().to_vec()));
    }
    if let Some(b) = illustration {
        all.push((b'M', "Illustration_48x48@1".into(), "Illustration_48x48@1".into(), 1, b.to_vec()));
    }
    all.sort_by(|a, b| (a.0, &a.1).cmp(&(b.0, &b.1)));
    let n = all.len();
    let mut mime = Vec::new();
    for m in mimes {
        mime.extend_from_slice(m.as_bytes());
        mime.push(0);
    }
    mime.push(0);
    let url_ptr_pos = 80 + mime.len() as u64;
    let title_ptr_pos = url_ptr_pos + 8 * n as u64;
    let cluster_ptr_pos = title_ptr_pos + 4 * n as u64;
    let cluster_pos = cluster_ptr_pos + 8;
    let mut cluster = vec![1u8];
    let mut off = (4 * (n + 1)) as u32;
    let mut offs = Vec::new();
    for e in &all {
        offs.push(off);
        off += e.4.len() as u32;
    }
    offs.push(off);
    for o in &offs {
        cluster.extend_from_slice(&o.to_le_bytes());
    }
    for e in &all {
        cluster.extend_from_slice(&e.4);
    }
    let entries_pos = cluster_pos + cluster.len() as u64;
    let mut dirents: Vec<u8> = Vec::new();
    let mut entry_pos: Vec<u64> = Vec::new();
    for (i, e) in all.iter().enumerate() {
        entry_pos.push(entries_pos + dirents.len() as u64);
        dirents.extend_from_slice(&e.3.to_le_bytes());
        dirents.push(0);
        dirents.push(e.0);
        dirents.extend_from_slice(&0u32.to_le_bytes());
        dirents.extend_from_slice(&0u32.to_le_bytes());
        dirents.extend_from_slice(&(i as u32).to_le_bytes());
        dirents.extend_from_slice(e.1.as_bytes());
        dirents.push(0);
        dirents.extend_from_slice(e.2.as_bytes());
        dirents.push(0);
    }
    let checksum_pos = entries_pos + dirents.len() as u64;
    let mut by_title: Vec<u32> = (0..n as u32).collect();
    by_title.sort_by(|a, b| {
        let (x, y) = (&all[*a as usize], &all[*b as usize]);
        (x.0, &x.2).cmp(&(y.0, &y.2))
    });
    let mut out: Vec<u8> = Vec::new();
    out.extend_from_slice(&0x044D495Au32.to_le_bytes());
    out.extend_from_slice(&6u16.to_le_bytes());
    out.extend_from_slice(&1u16.to_le_bytes());
    let u: Vec<u8> = (0..16)
        .map(|i| u8::from_str_radix(&uuid.replace('-', "")[2 * i..2 * i + 2], 16).unwrap())
        .collect();
    out.extend_from_slice(&u);
    out.extend_from_slice(&(n as u32).to_le_bytes());
    out.extend_from_slice(&1u32.to_le_bytes());
    for v in [url_ptr_pos, title_ptr_pos, cluster_ptr_pos, 80u64] {
        out.extend_from_slice(&v.to_le_bytes());
    }
    out.extend_from_slice(&u32::MAX.to_le_bytes());
    out.extend_from_slice(&u32::MAX.to_le_bytes());
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
    out.extend_from_slice(&[0u8; 16]);
    std::fs::write(path, out).unwrap();
}

fn b64_decode(s: &str) -> Vec<u8> {
    let val = |c: u8| -> u32 {
        (match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            _ => 63,
        }) as u32
    };
    let mut out = Vec::new();
    for q in s.as_bytes().chunks(4) {
        let pad = q.iter().filter(|c| **c == b'=').count();
        let n = q.iter().filter(|c| **c != b'=').fold(0u32, |a, c| (a << 6) | val(*c)) << (6 * pad);
        for i in 0..3 - pad {
            out.push((n >> (16 - 8 * i)) as u8);
        }
    }
    out
}

fn open(zims: &[&Path]) -> (Handle, Vec<String>) {
    let sources: Vec<Value> = zims.iter().map(|p| json!({"kind": "zim", "path": p, "builtin_index": false})).collect();
    let mut h = Handle::open(&json!({"sources": sources}).to_string()).expect("open handle");
    let st: Value = serde_json::from_str(&h.status_json()).unwrap();
    let ids = st["sources"].as_array().unwrap().iter().map(|s| s["id"].as_str().expect("source opened").to_string()).collect();
    (h, ids)
}

#[test]
fn a_zim_answers_its_own_png_illustration() {
    let t = TempDir::new("icon");
    let page = ("Main", "Main", "text/html", b"<html><body>hi</body></html>".to_vec());
    let (a, b, c) = (t.0.join("icon.zim"), t.0.join("none.zim"), t.0.join("junk.zim"));
    write_zim(&a, U_ICON, "icon_test", &[page.clone()], Some(&PNG));
    write_zim(&b, U_NONE, "none_test", &[page.clone()], None);
    write_zim(&c, U_JUNK, "junk_test", &[page], Some(b"GIF89a not a png at all"));
    let (h, ids) = open(&[&a, &b, &c]);
    assert_eq!(ids, [U_ICON, U_NONE, U_JUNK]);

    let v: Value = serde_json::from_str(&h.zim_illustration(U_ICON).expect("the illustration")).unwrap();
    assert_eq!(b64_decode(v["png_base64"].as_str().unwrap()), PNG.to_vec());

    for id in [U_NONE, U_JUNK, "0badc0de-0000-4000-8000-00000000ffff"] {
        assert_eq!(h.zim_illustration(id).err().expect(id).code, ErrorCode::NotFound, "{id}");
    }
}
