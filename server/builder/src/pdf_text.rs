//! The hidden `pdf-text` command: one PDF's page texts, for the server's headless ZIM PDF indexing. The phone reads these pages with
//! pdfrx (PDFium); pdfrx needs Flutter, so the server's helper runs this program on each PDF instead and hands the pages to the
//! same core calls (cs_pdf_chunk and cs_pdfindex_*), which chunk and write them in the one format. A process of its own, because
//! MuPDF is C code that a damaged PDF can crash: the helper then records that PDF as damaged and goes on.
//!
//! `pdf-text <in.pdf> <out.json> [hash]`: the answer is written to `<out.json>` (the helper reads it, so nothing MuPDF prints on
//! the way can get into it). The answer is `{"status":"ok","size","sha256","title","labels":[..],"pages":[..]}`, or status
//! `locked` (a password is needed) or `damaged`. With `hash` it holds only the size and sha256 (a PDF the older edition may
//! have: its bytes are compared before anything is read). The address space of the process is limited by
//! `CACHE_PDF_TEXT_MEM` (bytes), as the library builder limits its own reader.

use crate::extract::{extract_pdf, Extracted};
use crate::layout::{body_size, reading_blocks};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Each page's text: its blocks in reading order, a blank line between blocks and a line break between lines. A page with no
/// text is an empty string, so page numbers stay right.
pub fn page_texts(ext: &Extracted) -> Vec<String> {
    let body = body_size(&ext.pages);
    ext.pages
        .iter()
        .map(|p| {
            reading_blocks(&p.blocks, body)
                .iter()
                .map(|b| b.lines.iter().map(|l| l.text.trim_end()).collect::<Vec<_>>().join("\n"))
                .collect::<Vec<_>>()
                .join("\n\n")
        })
        .collect()
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

/// The answer for one PDF's bytes.
pub fn outcome(bytes: &[u8]) -> Value {
    let (size, sha) = (bytes.len(), sha256_hex(bytes));
    match extract_pdf(bytes) {
        Ok(ext) => {
            let labels: Vec<&str> = ext.pages.iter().map(|p| p.label.as_str()).collect();
            json!({"status": "ok", "size": size, "sha256": sha, "title": ext.title, "labels": labels, "pages": page_texts(&ext)})
        }
        Err(e) if e.0.contains("password") => json!({"status": "locked", "size": size, "sha256": sha}),
        Err(_) => json!({"status": "damaged", "size": size, "sha256": sha}),
    }
}

/// Runs the command; the exit code.
pub fn child_main(args: &[String]) -> i32 {
    let (Some(input), Some(output)) = (args.first(), args.get(1)) else {
        eprintln!("pdf-text is run by Cache itself, not by hand");
        return 64;
    };
    #[cfg(unix)]
    {
        if let Some(bytes) = std::env::var("CACHE_PDF_TEXT_MEM").ok().and_then(|v| v.parse::<u64>().ok()) {
            let lim = libc::rlimit { rlim_cur: bytes as libc::rlim_t, rlim_max: bytes as libc::rlim_t };
            // SAFETY: setrlimit with a fully initialized struct.
            unsafe {
                libc::setrlimit(libc::RLIMIT_AS, &lim);
            }
        }
    }
    let Ok(bytes) = std::fs::read(input) else { return 1 };
    let answer = if args.get(2).map(String::as_str) == Some("hash") {
        json!({"status": "ok", "size": bytes.len(), "sha256": sha256_hex(&bytes)})
    } else {
        outcome(&bytes)
    };
    let tmp = format!("{output}.tmp");
    if std::fs::write(&tmp, answer.to_string()).and_then(|_| std::fs::rename(&tmp, output)).is_err() {
        return 1;
    }
    0
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::extract::{Block, Line, RawPage};

    fn line(t: &str, y: f32) -> Line {
        Line { text: t.to_string(), x0: 10.0, y0: y, x1: 200.0, y1: y + 10.0, size: 10.0, bold: false, italic: false }
    }

    #[test]
    fn pages_are_blocks_of_lines_and_an_empty_page_stays_empty() {
        let page = RawPage {
            index: 0,
            label: "1".into(),
            width: 600.0,
            height: 800.0,
            blocks: vec![Block::from_lines(vec![line("Hello", 10.0), line("World", 22.0)])],
            images: 0,
        };
        let empty = RawPage { index: 1, label: "2".into(), width: 600.0, height: 800.0, blocks: vec![], images: 0 };
        let ext = Extracted { title: None, pages: vec![page, empty], year: None, ppi: None };
        let t = page_texts(&ext);
        assert_eq!(t.len(), 2);
        assert_eq!(t[0], "Hello\nWorld");
        assert_eq!(t[1], "");
    }

    #[test]
    fn bytes_that_are_not_a_pdf_are_damaged_and_keep_their_hash() {
        let v = outcome(b"this is not a pdf");
        assert_eq!(v["status"], "damaged");
        assert_eq!(v["size"], 17);
        assert_eq!(v["sha256"].as_str().unwrap().len(), 64);
    }

    #[test]
    fn the_command_writes_its_answer_beside_the_request() {
        let dir = tempfile::tempdir().unwrap();
        let (input, output) = (dir.path().join("in.pdf"), dir.path().join("out.json"));
        std::fs::write(&input, b"nope").unwrap();
        let args = vec![input.to_string_lossy().to_string(), output.to_string_lossy().to_string(), "hash".to_string()];
        assert_eq!(child_main(&args), 0);
        let v: Value = serde_json::from_str(&std::fs::read_to_string(&output).unwrap()).unwrap();
        assert_eq!(v["status"], "ok");
        assert_eq!(v["size"], 4);
        assert!(v.get("pages").is_none());
        assert_eq!(child_main(&[]), 64);
    }
}
