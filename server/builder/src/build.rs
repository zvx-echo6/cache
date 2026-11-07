//! PDF bytes to a document pack: extract, lay out, chunk, embed.

use crate::embed::Embedder;
use crate::error::{Error, Result};
use crate::extract::{extract_pdf, Extracted, EXTRACTOR_NAME, EXTRACTOR_VERSION};
use crate::layout::{layout, Element, Layout, LAYOUT_VERSION};
use crate::compress::CompressionOutcome;
use crate::pack::{valid_doc_id, OcrInfo, Pack, Suggested, Tool};
use crate::pagewriter::{build_pack_from_pages, BlockKind, PageBlock, PageIn, PagesSource, TextSource};

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
pub(crate) fn first_big_heading(elements: &[Element]) -> Option<String> {
    elements.iter().find_map(|e| match e {
        Element::Heading { level: 1, text, page } if *page < 5 && (3..=120).contains(&text.chars().count()) => Some(text.clone()),
        _ => None,
    })
}

/// A metadata title that names a real title, not a file the PDF was made from ("Microsoft Word - notes.doc").
pub(crate) fn usable_metadata_title(t: &str) -> Option<String> {
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
pub(crate) const EMBED_BATCH: usize = 16;

/// Where a build has got to, for callers that show progress.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Progress {
    /// The PDF has been read and cut into pieces (sent before any embedding, and also when there are no pieces to embed).
    Extracted { pages: usize, pieces: usize, ocr_pages: usize },
    /// `done` of `total` pieces have vectors.
    Embedded { done: usize, total: usize },
}

/// Build the pack for one PDF.
pub fn build_pack(pdf: &[u8], opts: &BuildOptions, embedder: &dyn Embedder) -> Result<(Pack, Report)> {
    build_pack_with(pdf, opts, embedder, &mut |_| {})
}

/// [`build_pack`] that tells `on` how far it has got.
pub fn build_pack_with(pdf: &[u8], opts: &BuildOptions, embedder: &dyn Embedder, on: &mut dyn FnMut(Progress)) -> Result<(Pack, Report)> {
    build_pack_with_extractor(pdf, opts, embedder, on, &extract_pdf)
}

/// [`build_pack_with`] with the PDF read by `extract` (in-process [`extract_pdf`], or the crash-proof child of `isolate`).
pub fn build_pack_with_extractor(
    pdf: &[u8],
    opts: &BuildOptions,
    embedder: &dyn Embedder,
    on: &mut dyn FnMut(Progress),
    extract: &dyn Fn(&[u8]) -> Result<Extracted>,
) -> Result<(Pack, Report)> {
    // (the default doc_id is a hash, always valid; the shared writer checks again)
    if let Some(doc_id) = opts.doc_id.as_ref().filter(|d| !valid_doc_id(d)) {
        return Err(Error::new(format!("invalid doc_id {doc_id:?}: use letters, digits, '.', '_' and '-'")));
    }
    if opts.doc_version == 0 {
        return Err(Error::new("doc_version starts at 1"));
    }
    let ext = extract(pdf)?;
    let lay = layout(&ext);
    let (src, pages) = pages_of(&ext, &lay, pdf, &opts.file_name);
    build_pack_from_pages(&src, &pages, opts, embedder, on)
}

/// What the layout step made of a document, as the input of the shared pack writer ([`build_pack_from_pages`]): one [`PageIn`]
/// for every page (headings, body paragraphs and asides in reading order, `text_source` layer) and the facts about the file.
/// `cache-build pdf` builds its pack from exactly this, so a pack made from the same pages by `cache-build pack` has the same pieces.
pub fn pages_of(ext: &Extracted, lay: &Layout, pdf: &[u8], file_name: &str) -> (PagesSource, Vec<PageIn>) {
    // The elements come page by page, so one pass puts each in its page.
    let mut blocks: Vec<Vec<PageBlock>> = vec![Vec::new(); ext.pages.len()];
    for e in &lay.elements {
        match e {
            Element::Heading { level, text, page } => {
                if let Some(b) = blocks.get_mut(*page) {
                    b.push(PageBlock { text: text.clone(), kind: BlockKind::Heading, level: Some(*level), bullet: false });
                }
            }
            Element::Para { text, page, bullet, aside } => {
                if let Some(b) = blocks.get_mut(*page) {
                    b.push(PageBlock { text: text.clone(), kind: if *aside { BlockKind::Aside } else { BlockKind::Body }, level: None, bullet: *bullet });
                }
            }
        }
    }
    let pages: Vec<PageIn> = ext
        .pages
        .iter()
        .zip(blocks)
        .enumerate()
        .map(|(i, (rp, blocks))| PageIn { pdf_page: i + 1, label: rp.label.clone(), text_source: TextSource::Layer, blocks })
        .collect();
    let src = PagesSource {
        blake3: blake3::hash(pdf).to_hex().to_string(),
        size: pdf.len() as u64,
        file_name: file_name.to_string(),
        extractor: Tool { name: EXTRACTOR_NAME.to_string(), version: EXTRACTOR_VERSION.to_string(), layout_version: Some(LAYOUT_VERSION) },
        meta_title: ext.title.clone(),
        ppi: ext.ppi,
        year: ext.year,
        page_count: ext.pages.len(),
        ocr_pages: Some(lay.ocr_pages.iter().map(|i| i + 1).collect()),
        text_pages: Some(ext.pages.iter().filter(|p| p.text_chars() >= crate::layout::MIN_PAGE_CHARS).count()),
    };
    (src, pages)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_from_files_and_metadata_are_tidied() {
        assert_eq!(tidy_file_title("Water_Purification  Handbook.pdf"), "Water Purification Handbook");
        assert_eq!(tidy_file_title("plain"), "plain");
        assert_eq!(usable_metadata_title("Microsoft Word - notes.doc"), None);
        assert_eq!(usable_metadata_title("Microsoft Word - The Well Book"), Some("The Well Book".to_string()));
        assert_eq!(usable_metadata_title("  The Well Handbook "), Some("The Well Handbook".to_string()));
        assert_eq!(usable_metadata_title("untitled"), None);
        assert_eq!(usable_metadata_title("12345"), None);
        assert_eq!(usable_metadata_title("report.pdf"), None);
    }
}
