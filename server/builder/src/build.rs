//! PDF bytes to a document pack: extract, lay out, chunk, embed.

use crate::chunk::{chunk, CHUNKER_VERSION, MAX_WORDS, TARGET_WORDS};
use crate::embed::Embedder;
use crate::error::{Error, Result};
use crate::extract::{extract_pdf, Extracted, EXTRACTOR_NAME, EXTRACTOR_VERSION};
use crate::fingerprint::{fingerprint, mean_vector};
use crate::layout::{layout, Element, MIN_PAGE_CHARS};
use crate::compress::CompressionOutcome;
use crate::pack::{valid_doc_id, BookBlock, Chunker, EmbeddingInfo, Header, OcrInfo, Pack, PackPiece, Samebook, Source, Suggested, Tool, PACK_FORMAT};
use crate::text::word_count;

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
fn first_big_heading(elements: &[Element]) -> Option<String> {
    elements.iter().find_map(|e| match e {
        Element::Heading { level: 1, text, page } if *page < 5 && (3..=120).contains(&text.chars().count()) => Some(text.clone()),
        _ => None,
    })
}

/// A metadata title that names a real title, not a file the PDF was made from ("Microsoft Word - notes.doc").
fn usable_metadata_title(t: &str) -> Option<String> {
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
const EMBED_BATCH: usize = 16;

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
    let hash = blake3::hash(pdf).to_hex().to_string();
    let doc_id = opts.doc_id.clone().unwrap_or_else(|| hash.clone());
    if !valid_doc_id(&doc_id) {
        return Err(Error::new(format!("invalid doc_id {doc_id:?}: use letters, digits, '.', '_' and '-'")));
    }
    if opts.doc_version == 0 {
        return Err(Error::new("doc_version starts at 1"));
    }
    let ext = extract(pdf)?;
    let lay = layout(&ext);
    let pieces = chunk(&lay.elements);
    let ocr_pages: Vec<usize> = lay.ocr_pages.iter().map(|i| i + 1).collect();
    on(Progress::Extracted { pages: ext.pages.len(), pieces: pieces.len(), ocr_pages: ocr_pages.len() });
    if pieces.is_empty() {
        return Err(Error::new(if ocr_pages.is_empty() {
            "no text found in the PDF".to_string()
        } else {
            format!("no text layer: {} page(s) need OCR", ocr_pages.len())
        }));
    }
    let texts: Vec<String> = pieces.iter().map(|p| p.text.clone()).collect();
    let mut vectors: Vec<Vec<f32>> = Vec::with_capacity(texts.len());
    for batch in texts.chunks(EMBED_BATCH) {
        let v = embedder.embed_batch(batch);
        if v.len() != batch.len() {
            return Err(Error::new("the embedder returned a different number of vectors than texts"));
        }
        vectors.extend(v);
        on(Progress::Embedded { done: vectors.len(), total: texts.len() });
    }
    let dims = vectors[0].len();
    if dims == 0 || vectors.iter().any(|v| v.len() != dims) {
        return Err(Error::new("the embedder returned vectors of different sizes"));
    }
    let label = |i: usize| ext.pages.get(i).map(|p| p.label.clone()).unwrap_or_else(|| (i + 1).to_string());
    let first_heading = first_big_heading(&lay.elements);
    // The title the PDF itself gives; a caller's title replaces it, and the replaced one is kept as `source_title`.
    let auto_title: String = if opts.smart_title {
        ext.title.as_deref().and_then(usable_metadata_title).or_else(|| first_heading.clone()).unwrap_or_else(|| tidy_file_title(&opts.file_name))
    } else {
        ext.title
            .clone()
            .unwrap_or_else(|| std::path::Path::new(&opts.file_name).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| opts.file_name.clone()))
    };
    let title = opts.title.clone().unwrap_or_else(|| auto_title.clone());
    let source_title = (title != auto_title).then_some(auto_title);
    let words: Vec<usize> = pieces.iter().map(|p| word_count(&p.text)).collect();
    let headings_all: Vec<(u8, String)> = lay
        .elements
        .iter()
        .filter_map(|e| match e {
            Element::Heading { level, text, .. } => Some((*level, text.clone())),
            _ => None,
        })
        .collect();
    let pack_pieces: Vec<PackPiece> = pieces
        .iter()
        .zip(vectors)
        .map(|(p, v)| PackPiece {
            index: p.index,
            text: p.text.clone(),
            page: label(p.page),
            pdf_page: Some((p.page + 1) as u32),
            page_end: if p.page_end != p.page { Some(label(p.page_end)) } else { None },
            pdf_page_end: if p.page_end != p.page { Some((p.page_end + 1) as u32) } else { None },
            heading_path: p.heading_path.clone(),
            vector: v,
        })
        .collect();
    let mut header = Header {
        cdoc: PACK_FORMAT,
        doc_id,
        doc_version: opts.doc_version,
        title,
        source: Source { blake3: hash.clone(), size: pdf.len() as u64, file_name: opts.file_name.clone(), https: opts.https.clone() },
        extractor: Tool { name: EXTRACTOR_NAME.to_string(), version: EXTRACTOR_VERSION.to_string() },
        chunker: Chunker { version: CHUNKER_VERSION, target_words: TARGET_WORDS as u32, max_words: MAX_WORDS as u32 },
        embedding: EmbeddingInfo { embedder: embedder.name(), dims },
        created_at: opts.created_at.clone(),
        page_count: ext.pages.len(),
        ocr_pages: ocr_pages.clone(),
        pieces: pack_pieces.len(),
        division: None,
        book: None,
        samebook: None,
    };
    header.book = Some(BookBlock {
        title: header.title.clone(),
        source_title,
        original_blake3: opts.original_blake3.clone().unwrap_or(hash),
        compression: opts.compression.clone(),
        ocr: opts.ocr.clone(),
        suggested: opts.suggested.clone(),
    });
    let print = fingerprint(pack_pieces.iter().map(|p| p.text.as_str()));
    let report = Report {
        pages: ext.pages.len(),
        pieces: pack_pieces.len(),
        mean_words: words.iter().sum::<usize>() as f32 / words.len() as f32,
        min_words: *words.iter().min().unwrap(),
        max_words: *words.iter().max().unwrap(),
        ocr_pages,
        headings: headings_all.iter().take(15).cloned().collect(),
        heading_count: headings_all.len(),
        text_pages: ext.pages.iter().filter(|p| p.text_chars() >= MIN_PAGE_CHARS).count(),
        words: print.words,
        ppi: ext.ppi,
        year: ext.year,
        minhash: print.minhash,
        mean_vector: mean_vector(&pack_pieces),
        first_heading,
    };
    // Revision 3: the same-book fingerprint travels in the pack, so every device can compare copies without the PDF.
    header.samebook = Some(Samebook::new(
        report.minhash.clone(),
        &report.mean_vector,
        report.text_pages as u32,
        report.pages as u32,
        report.ppi,
        pdf.len() as u64,
    ));
    Ok((Pack { header, pieces: pack_pieces }, report))
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
