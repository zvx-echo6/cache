//! The ZIM PDF survey: a tiny ZIM is written here (header, MIME list, path list, one uncompressed cluster) with PDFs and one
//! HTML entry, then counted with `zim::survey`.

mod common;

use cache_builder::isolate::ChildExtractor;
use cache_builder::zim::{survey, Survey, ZimPdfOptions};
use common::*;
use serde_json::json;

const UUID: [u8; 16] = [
    0x0b, 0x2c, 0x6a, 0x9e, 0x41, 0xd7, 0x4c, 0x58, 0x9e, 0x0a, 0x5d, 0x3f, 0x7a, 0x1c, 0x8b, 0x24,
];
const UUID_TEXT: &str = "0b2c6a9e-41d7-4c58-9e0a-5d3f7a1c8b24";

/// A version 6 ZIM: entries are (namespace, path, title, mime index, bytes), already in path order, in one uncompressed cluster.
fn write_zim(mimes: &[&str], entries: &[(u8, &str, &str, u16, Vec<u8>)]) -> Vec<u8> {
    let mut mime_list = Vec::new();
    for m in mimes {
        mime_list.extend_from_slice(m.as_bytes());
        mime_list.push(0);
    }
    mime_list.push(0);
    // the cluster: flag 1 (uncompressed), then n+1 offsets from the start of the offset table, then the blobs
    let n = entries.len();
    let mut cluster = vec![1u8];
    let mut off = (4 * (n + 1)) as u32;
    let mut offsets = vec![off];
    for e in entries {
        off += e.4.len() as u32;
        offsets.push(off);
    }
    for o in &offsets {
        cluster.extend_from_slice(&o.to_le_bytes());
    }
    for e in entries {
        cluster.extend_from_slice(&e.4);
    }
    let dirents: Vec<Vec<u8>> = entries
        .iter()
        .enumerate()
        .map(|(i, e)| {
            let mut d = Vec::new();
            d.extend_from_slice(&e.3.to_le_bytes());
            d.push(0);
            d.push(e.0);
            d.extend_from_slice(&0u32.to_le_bytes());
            d.extend_from_slice(&0u32.to_le_bytes());
            d.extend_from_slice(&(i as u32).to_le_bytes());
            d.extend_from_slice(e.1.as_bytes());
            d.push(0);
            d.extend_from_slice(e.2.as_bytes());
            d.push(0);
            d
        })
        .collect();
    let mime_pos = 80u64;
    let url_ptr_pos = mime_pos + mime_list.len() as u64;
    let cluster_ptr_pos = url_ptr_pos + 8 * n as u64;
    let dir_pos = cluster_ptr_pos + 8;
    let dir_len: u64 = dirents.iter().map(|d| d.len() as u64).sum();
    let cluster_pos = dir_pos + dir_len;
    let checksum_pos = cluster_pos + cluster.len() as u64;
    let mut z = Vec::new();
    z.extend_from_slice(&0x44D495Au32.to_le_bytes());
    z.extend_from_slice(&6u16.to_le_bytes());
    z.extend_from_slice(&1u16.to_le_bytes());
    z.extend_from_slice(&UUID);
    z.extend_from_slice(&(n as u32).to_le_bytes());
    z.extend_from_slice(&1u32.to_le_bytes());
    z.extend_from_slice(&url_ptr_pos.to_le_bytes());
    z.extend_from_slice(&u64::MAX.to_le_bytes());
    z.extend_from_slice(&cluster_ptr_pos.to_le_bytes());
    z.extend_from_slice(&mime_pos.to_le_bytes());
    z.extend_from_slice(&u32::MAX.to_le_bytes());
    z.extend_from_slice(&u32::MAX.to_le_bytes());
    z.extend_from_slice(&checksum_pos.to_le_bytes());
    assert_eq!(z.len(), 80);
    z.extend_from_slice(&mime_list);
    let mut p = dir_pos;
    for d in &dirents {
        z.extend_from_slice(&p.to_le_bytes());
        p += d.len() as u64;
    }
    z.extend_from_slice(&cluster_pos.to_le_bytes());
    for d in &dirents {
        z.extend_from_slice(d);
    }
    z.extend_from_slice(&cluster);
    z.extend_from_slice(&[0u8; 16]);
    z
}

fn words(n: usize, seed: &str) -> String {
    (0..n)
        .map(|i| format!("{seed}{}", i % 40))
        .collect::<Vec<_>>()
        .join(" ")
}

fn text_pdf() -> Vec<u8> {
    let mut pages = Vec::new();
    for seed in ["alpha", "bravo"] {
        let mut p = Page::new();
        let lines = wrap(&words(120, seed), 70);
        let refs: Vec<&str> = lines.iter().map(|s| s.as_str()).collect();
        p.block(54.0, 80.0, 10.0, Font::Regular, &refs);
        pages.push(p);
    }
    make_pdf(&pages, Some("Water Manual"))
}

fn scanned_pdf() -> Vec<u8> {
    let mut p = Page::new();
    p.picture = true;
    make_pdf(&[p], None)
}

fn survey_of(zim: Vec<u8>, name: &str, limit: Option<usize>, skip: &[&str]) -> Survey {
    survey_with(zim, name, limit, skip, None)
}

fn survey_with(zim: Vec<u8>, name: &str, limit: Option<usize>, skip: &[&str], child: Option<ChildExtractor>) -> Survey {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join(name);
    std::fs::write(&path, zim).unwrap();
    survey(
        &ZimPdfOptions {
            zim: path,
            limit,
            skip: skip.iter().map(|s| s.to_string()).collect(),
            child,
        },
        &mut |_| {},
        &mut |_, _| {},
    )
    .unwrap()
}

#[test]
fn survey_counts_the_pdfs_of_a_zim_and_ignores_html() {
    let zim = write_zim(
        &["application/pdf", "text/html"],
        &[
            (b'C', "manuals/water.pdf", "Water Manual", 0, text_pdf()),
            (
                b'C',
                "page.html",
                "A page",
                1,
                b"<html><body>alpha0 alpha1 not a pdf</body></html>".to_vec(),
            ),
            (b'C', "scan.pdf", "", 0, scanned_pdf()),
        ],
    );
    let sv = survey_of(zim, "tiny_en_2026-01.zim", None, &[]);
    assert_eq!(sv.zim_uuid, UUID_TEXT);
    assert_eq!(sv.zim_name, "tiny_en_2026-01");
    assert_eq!(
        (sv.pdfs, sv.pages, sv.with_text, sv.without_text, sv.failed),
        (2, 3, 1, 1, 0)
    );
    assert!(sv.est_pieces >= 1 && sv.bytes > 0);
    let j = sv.to_json();
    assert_eq!(j["pdfs"], json!(2));
    assert_eq!(j["pages"], json!(3));
}

#[test]
fn limit_counts_pdfs() {
    let zim = write_zim(
        &["application/pdf"],
        &[
            (b'C', "a.pdf", "A", 0, text_pdf()),
            (b'C', "b.pdf", "B", 0, text_pdf()),
        ],
    );
    assert_eq!(survey_of(zim.clone(), "s.zim", None, &[]).pdfs, 2);
    assert_eq!(survey_of(zim.clone(), "s.zim", Some(1), &[]).pdfs, 1);
    let sv = survey_of(zim, "s.zim", None, &["a.pdf"]);
    assert_eq!((sv.pdfs, sv.with_text, sv.failed), (2, 1, 1));
}

fn child(tag: &str, fault: Option<&str>) -> ChildExtractor {
    let mut e = ChildExtractor::current_exe(std::env::temp_dir().join(format!("cache-zim-{tag}-{}", std::process::id())));
    e.exe = std::path::PathBuf::from(env!("CARGO_BIN_EXE_cache-build"));
    e.fault = fault.map(String::from);
    e
}

fn mixed_zim() -> Vec<u8> {
    write_zim(
        &["application/pdf"],
        &[(b'C', "a.pdf", "A", 0, text_pdf()), (b'C', "scan.pdf", "", 0, scanned_pdf())],
    )
}

#[test]
fn a_survey_through_the_child_counts_exactly_what_an_in_process_one_does() {
    let direct = survey_of(mixed_zim(), "s.zim", None, &[]);
    let via = survey_with(mixed_zim(), "s.zim", None, &[], Some(child("same", None)));
    assert_eq!(via, direct);
    assert_eq!((via.pdfs, via.with_text, via.without_text, via.failed), (2, 1, 1, 0));
}

#[test]
fn a_pdf_that_crashes_the_reader_counts_as_failed_and_the_survey_goes_on() {
    let mut reasons = Vec::new();
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("s.zim");
    std::fs::write(&path, mixed_zim()).unwrap();
    let sv = survey(
        &ZimPdfOptions { zim: path, limit: None, skip: vec![], child: Some(child("crash", Some("segv"))) },
        &mut |_| {},
        &mut |p, why| reasons.push(format!("{p}: {why}")),
    )
    .unwrap();
    assert_eq!((sv.pdfs, sv.failed, sv.with_text), (2, 2, 0), "both PDFs were visited and failed alone");
    assert!(reasons.iter().all(|r| r.contains("Cache couldn't read this PDF")), "{reasons:?}");
}
