//! What the caller chooses for a pack (`BuildOptions`), what a build reports (`Report`, `Progress`), and the title helpers the
//! pack writer uses. Shared by the library builder and the ingest job.

use crate::compression::CompressionOutcome;
use crate::pack::{OcrInfo, Suggested};
use cache_chunk::Element;

/// What the caller chooses for one document.
#[derive(Debug, Clone)]
pub struct BuildOptions {
    /// Default: the BLAKE3 hash of the PDF (the first version's content hash).
    pub doc_id: Option<String>,
    pub doc_version: u32,
    /// Default: the PDF's metadata title, else the file name without its extension.
    pub title: Option<String>,
    pub https: Option<String>,
    pub file_name: String,
    /// Recorded as is (the builder never reads the clock, so equal inputs give equal packs).
    pub created_at: String,
    /// Choose the title the way the library does: the PDF's metadata title when it is a real one, else its first big heading,
    /// else the file name tidied. Off by default: the title is then the metadata title or the file name without its extension.
    pub smart_title: bool,
    /// Revision 4 `book.original_blake3`: the BLAKE3 (hex) of the file as it arrived. Default: the hash of the PDF being built
    /// (right unless the file was compressed first, or is an OCR copy of the original).
    pub original_blake3: Option<String>,
    /// Revision 4 `book.compression`: what compression did to the file, when it was compressed.
    pub compression: Option<CompressionOutcome>,
    /// Revision 4 `book.ocr`: set when the text came from OCR.
    pub ocr: Option<OcrInfo>,
    /// Revision 4 `book.suggested`: the division the classifier or a label suggests.
    pub suggested: Option<Suggested>,
}

impl BuildOptions {
    pub fn new(file_name: &str, created_at: &str) -> Self {
        BuildOptions { doc_id: None, doc_version: 1, title: None, https: None, file_name: file_name.to_string(), created_at: created_at.to_string(), smart_title: false, original_blake3: None, compression: None, ocr: None, suggested: None }
    }
}

/// What a build found, for reports.
#[derive(Debug, Clone, PartialEq)]
pub struct Report {
    pub pages: usize,
    pub pieces: usize,
    pub mean_words: f32,
    pub min_words: usize,
    pub max_words: usize,
    /// 1-based pages that need OCR.
    pub ocr_pages: Vec<usize>,
    /// The first headings found (level, text) and how many there are in all.
    pub headings: Vec<(u8, String)>,
    pub heading_count: usize,
    /// Pages with real text on them.
    pub text_pages: usize,
    /// Words in the text of all the pieces.
    pub words: usize,
    /// Typical page-image resolution in pixels per inch, when the PDF has page images.
    pub ppi: Option<u32>,
    /// The year in the PDF's creation date.
    pub year: Option<u32>,
    /// The MinHash fingerprint of the text (see `fingerprint`); empty for a very short text.
    pub minhash: Vec<u32>,
    /// The mean vector of all the pieces, length 1.
    pub mean_vector: Vec<f32>,
    /// The first big heading near the start, when there is one.
    pub first_heading: Option<String>,
}

/// The first big (top level) heading in the first five pages.
pub fn first_big_heading(elements: &[Element]) -> Option<String> {
    elements.iter().find_map(|e| match e {
        Element::Heading { level: 1, text, page } if *page < 5 && (3..=120).contains(&text.chars().count()) => Some(text.clone()),
        _ => None,
    })
}

/// A metadata title that names a real title, not a file the PDF was made from ("Microsoft Word - notes.doc").
pub fn usable_metadata_title(t: &str) -> Option<String> {
    let t = t.trim();
    let t = t.strip_prefix("Microsoft Word - ").or_else(|| t.strip_prefix("Microsoft Word- ")).unwrap_or(t).trim();
    let lower = t.to_lowercase();
    let file_like = [".doc", ".docx", ".pdf", ".indd", ".qxd", ".pmd", ".pub", ".rtf", ".odt", ".tex", ".ps", ".txt", ".htm", ".html"].iter().any(|e| lower.ends_with(e));
    if t.chars().count() < 3 || file_like || lower == "untitled" || t.chars().all(|c| c.is_ascii_digit()) {
        None
    } else {
        Some(t.to_string())
    }
}

/// A file name as a title: no extension, underscores as spaces, one space between words.
pub fn tidy_file_title(file_name: &str) -> String {
    let stem = std::path::Path::new(file_name).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| file_name.to_string());
    let t = stem.replace('_', " ");
    let t = t.split_whitespace().collect::<Vec<_>>().join(" ");
    if t.is_empty() {
        file_name.to_string()
    } else {
        t
    }
}

/// Pieces embedded per call (the server's build service batches the same way).
pub const EMBED_BATCH: usize = 16;

/// Where a build has got to, for callers that show progress.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Progress {
    /// The PDF has been read and cut into pieces (sent before any embedding, and also when there are no pieces to embed).
    Extracted { pages: usize, pieces: usize, ocr_pages: usize },
    /// `done` of `total` pieces have vectors.
    Embedded { done: usize, total: usize },
}

