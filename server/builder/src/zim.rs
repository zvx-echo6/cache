//! The PDFs of a ZIM, surveyed: every `application/pdf` entry is read, its text extracted with [`extract_pdf`] and cut with
//! [`chunk`], and the numbers are counted (PDFs, bytes, pages, text layer or not, estimated pieces). Nothing is written and
//! nothing is embedded.

use crate::chunk::chunk;
use crate::error::{Error, Result};
use crate::extract::extract_pdf;
use crate::layout::layout;
use ::zim::{DirectoryEntry, MimeType, Target, Zim};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::path::PathBuf;

/// What one survey run does.
#[derive(Debug, Clone)]
pub struct ZimPdfOptions {
    pub zim: PathBuf,
    /// Only the first N PDFs (in the ZIM's path order).
    pub limit: Option<usize>,
    /// Entry paths that are not extracted (counted as failed): for a PDF that crashes the PDF library, which no error handling
    /// can catch.
    pub skip: Vec<String>,
}

/// The survey numbers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Survey {
    pub zim_uuid: String,
    pub zim_name: String,
    /// PDF entries read (after duplicates are dropped).
    pub pdfs: usize,
    /// Their total size in bytes.
    pub bytes: u64,
    /// Pages in all the PDFs that could be extracted.
    pub pages: usize,
    pub with_text: usize,
    /// PDFs with no text layer.
    pub without_text: usize,
    /// PDFs that could not be read or extracted (counted in neither `with_text` nor `without_text`).
    pub failed: usize,
    /// Pieces the text PDFs make.
    pub est_pieces: usize,
}

impl Survey {
    pub fn to_json(&self) -> Value {
        json!({
            "zim_uuid": self.zim_uuid, "zim_name": self.zim_name, "pdfs": self.pdfs, "bytes": self.bytes, "pages": self.pages,
            "with_text": self.with_text, "without_text": self.without_text, "failed": self.failed, "est_pieces": self.est_pieces,
        })
    }
}

/// The ZIM header UUID, lowercase 8-4-4-4-12.
pub fn zim_uuid(z: &Zim) -> String {
    z.header.uuid.to_string().to_ascii_lowercase()
}

/// The PDF behind an entry (a redirect is followed once or more), with its cluster and blob. `None` when it is not a PDF.
fn pdf_entry(z: &Zim, e: DirectoryEntry) -> Result<Option<(DirectoryEntry, u32, u32)>> {
    let e = if matches!(e.target, Some(Target::Redirect(_))) {
        z.resolve(e)
            .map_err(|e| Error::ctx("following a redirect", e))?
    } else {
        e
    };
    match (&e.mime_type, &e.target) {
        (MimeType::Type(m), Some(Target::Cluster(c, b)))
            if m.split(';')
                .next()
                .is_some_and(|m| m.trim().eq_ignore_ascii_case("application/pdf")) =>
        {
            let (c, b) = (*c, *b);
            Ok(Some((e, c, b)))
        }
        _ => Ok(None),
    }
}

/// Survey the ZIM's PDFs. `progress` is told after each PDF; `skipped` gets (path, reason) for every PDF without pieces.
pub fn survey(
    opts: &ZimPdfOptions,
    progress: &mut dyn FnMut(&Survey),
    skipped: &mut dyn FnMut(&str, &str),
) -> Result<Survey> {
    let z = Zim::new(&opts.zim)
        .map_err(|e| Error::ctx(&format!("opening {}", opts.zim.display()), e))?;
    let stem = opts
        .zim
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "zim".into());
    let mut sv = Survey {
        zim_uuid: zim_uuid(&z),
        zim_name: stem,
        pdfs: 0,
        bytes: 0,
        pages: 0,
        with_text: 0,
        without_text: 0,
        failed: 0,
        est_pieces: 0,
    };
    let mut seen: HashSet<(u32, u32)> = HashSet::new();
    for item in z.iterate_by_urls() {
        if opts.limit.is_some_and(|n| sv.pdfs >= n) {
            break;
        }
        let Ok(entry) = item else { continue };
        let Ok(found) = pdf_entry(&z, entry) else {
            continue;
        };
        let Some((entry, c, b)) = found else { continue };
        if !seen.insert((c, b)) {
            continue;
        }
        sv.pdfs += 1;
        let Some(bytes) = z
            .entry_content(&entry)
            .ok()
            .flatten()
            .and_then(|c| c.to_vec().ok())
        else {
            sv.failed += 1;
            skipped(&entry.url, "could not read the entry");
            continue;
        };
        sv.bytes += bytes.len() as u64;
        if opts.skip.contains(&entry.url) {
            sv.failed += 1;
            skipped(&entry.url, "left out with --skip");
            continue;
        }
        match extract_pdf(&bytes) {
            Ok(ext) => {
                sv.pages += ext.pages.len();
                let n = chunk(&layout(&ext).elements).len();
                if n == 0 {
                    sv.without_text += 1;
                    skipped(&entry.url, "no text layer");
                } else {
                    sv.with_text += 1;
                    sv.est_pieces += n;
                }
            }
            Err(e) => {
                sv.failed += 1;
                skipped(&entry.url, &format!("extraction failed: {e}"));
            }
        }
        progress(&sv);
    }
    Ok(sv)
}
