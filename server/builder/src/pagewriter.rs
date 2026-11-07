//! The shared pack writer: the text of a document, page by page, becomes a pack.
//!
//! Where the text came from does not matter. `cache-build pdf` reads a PDF with MuPDF, lays it out, and hands the result to
//! [`build_pack_from_pages`] as [`PageIn`]s (see `build::pages_of`); a phone, or any OCR engine, hands over the pages it read
//! the same way (`cache-build pack --pages pages.json`). There is one writer, so the same pages give the same passages
//! wherever they were made. Nothing here reads a PDF: the module has no dependency on MuPDF and no I/O besides the embedder,
//! so the shared core can call it.
//!
//! The input, `pages.json` (see PACK-FORMAT.md):
//!
//! ```json
//! [{"pdf_page": 1, "label": "i", "text_source": "layer",
//!   "blocks": [{"text": "Wells", "kind": "heading", "level": 1},
//!              {"text": "A well is a hole dug to reach water.", "kind": "body"},
//!              {"text": "\"Dig deep.\"", "kind": "aside"}]}]
//! ```

use crate::build::{first_big_heading, tidy_file_title, usable_metadata_title, BuildOptions, Progress, Report, EMBED_BATCH};
use crate::chunk::{chunk, CHUNKER_VERSION, MAX_WORDS, TARGET_WORDS};
use crate::embed::Embedder;
use crate::error::{Error, Result};
use crate::fingerprint::{fingerprint, mean_vector};
use crate::layout::{Element, MIN_PAGE_CHARS};
use crate::pack::{valid_doc_id, BookBlock, Chunker, EmbeddingInfo, Header, Pack, PackPiece, Samebook, Source, Tool, PACK_FORMAT};
use crate::text::{normalize_ws, word_count};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Where a page's text came from: the PDF's own text layer, or OCR.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TextSource {
    #[default]
    Layer,
    Ocr,
}

/// What a block is.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum BlockKind {
    /// A paragraph of the running text.
    Body,
    /// A heading; `level` 1 is the outermost.
    Heading,
    /// A pull-quote, epigraph, caption or note: it is kept from interrupting a sentence that runs on to the next page.
    Aside,
}

fn is_false(b: &bool) -> bool {
    !*b
}

/// One block of a page: a paragraph or a heading, in reading order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PageBlock {
    pub text: String,
    pub kind: BlockKind,
    /// The heading level from 1 (outermost); 1 when a heading has none. Ignored for other blocks.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub level: Option<u8>,
    /// The paragraph is a list item.
    #[serde(default, skip_serializing_if = "is_false")]
    pub bullet: bool,
}

/// One page of text.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct PageIn {
    /// The 1-based page of the PDF (what a viewer opens).
    pub pdf_page: usize,
    /// The page label (the printed number or numeral); empty means the PDF page number.
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub text_source: TextSource,
    /// The blocks in reading order. A page with none has no text.
    #[serde(default)]
    pub blocks: Vec<PageBlock>,
}

/// The facts about the file the pages came from. The title, the document id and the other choices are in [`BuildOptions`].
#[derive(Debug, Clone, PartialEq)]
pub struct PagesSource {
    /// BLAKE3 (hex) of the file the pack is made from.
    pub blake3: String,
    pub size: u64,
    pub file_name: String,
    /// What read the pages: written to the pack's `extractor` (with the layout version when the producer laid the pages out).
    pub extractor: Tool,
    /// The title in the file's metadata, when there is one.
    pub meta_title: Option<String>,
    /// Typical resolution of the page images in pixels per inch, when the file has page images.
    pub ppi: Option<u32>,
    /// The year in the file's creation date.
    pub year: Option<u32>,
    /// Pages in the file (at least the highest `pdf_page`).
    pub page_count: usize,
    /// 1-based pages with no text layer that still need OCR. `None`: the pages that have no text in `pages`.
    pub ocr_pages: Option<Vec<usize>>,
    /// Pages with real text. `None`: the pages with at least [`MIN_PAGE_CHARS`] characters in their blocks.
    pub text_pages: Option<usize>,
}

/// Reads a `pages.json`.
pub fn parse_pages(json: &str) -> Result<Vec<PageIn>> {
    serde_json::from_str(json).map_err(|e| Error::ctx("pages.json", e))
}

/// A `pages.json` as text (pretty JSON and a final line break).
pub fn pages_json(pages: &[PageIn]) -> Result<String> {
    let mut s = serde_json::to_string_pretty(pages).map_err(|e| Error::ctx("pages.json", e))?;
    s.push('\n');
    Ok(s)
}

/// Whitespace normalisation of every block (runs of whitespace, no-break and zero-width spaces become one space; soft hyphens and
/// control characters go): what OCR output and a viewer's text need before they are chunked. Text the layout step made is
/// already normal, so this changes none of it.
pub fn normalize_pages(pages: &mut [PageIn]) {
    for p in pages.iter_mut() {
        for b in p.blocks.iter_mut() {
            b.text = normalize_ws(&b.text);
        }
    }
}

/// Make the pack of a document from its pages: chunk them (the shared `cache_chunk` rule), embed the passages, and write the
/// header with the book facts. `on` is told how far it has got.
pub fn build_pack_from_pages(src: &PagesSource, pages: &[PageIn], opts: &BuildOptions, embedder: &dyn Embedder, on: &mut dyn FnMut(Progress)) -> Result<(Pack, Report)> {
    let hash = src.blake3.clone();
    let doc_id = opts.doc_id.clone().unwrap_or_else(|| hash.clone());
    if !valid_doc_id(&doc_id) {
        return Err(Error::new(format!("invalid doc_id {doc_id:?}: use letters, digits, '.', '_' and '-'")));
    }
    if opts.doc_version == 0 {
        return Err(Error::new("doc_version starts at 1"));
    }
    let mut sorted: Vec<&PageIn> = pages.iter().collect();
    sorted.sort_by_key(|p| p.pdf_page);
    for (i, p) in sorted.iter().enumerate() {
        if p.pdf_page == 0 {
            return Err(Error::new("pdf_page starts at 1"));
        }
        if i > 0 && sorted[i - 1].pdf_page == p.pdf_page {
            return Err(Error::new(format!("page {} is in the pages twice", p.pdf_page)));
        }
        if p.blocks.iter().any(|b| b.kind == BlockKind::Heading && b.level == Some(0)) {
            return Err(Error::new(format!("page {}: a heading level starts at 1", p.pdf_page)));
        }
    }
    let page_count = src.page_count.max(sorted.last().map_or(0, |p| p.pdf_page));
    let mut elements: Vec<Element> = Vec::new();
    for p in &sorted {
        let page = p.pdf_page - 1;
        for b in &p.blocks {
            if b.text.trim().is_empty() {
                continue;
            }
            let text = b.text.clone();
            elements.push(match b.kind {
                BlockKind::Heading => Element::Heading { level: b.level.unwrap_or(1), text, page },
                BlockKind::Body => Element::Para { text, page, bullet: b.bullet, aside: false },
                BlockKind::Aside => Element::Para { text, page, bullet: b.bullet, aside: true },
            });
        }
    }
    let pieces = chunk(&elements);
    let ocr_pages: Vec<usize> = match &src.ocr_pages {
        Some(v) => v.clone(),
        None => sorted.iter().filter(|p| p.blocks.iter().all(|b| b.text.trim().is_empty())).map(|p| p.pdf_page).collect(),
    };
    let text_pages = src
        .text_pages
        .unwrap_or_else(|| sorted.iter().filter(|p| p.blocks.iter().map(|b| b.text.chars().count()).sum::<usize>() >= MIN_PAGE_CHARS).count());
    on(Progress::Extracted { pages: page_count, pieces: pieces.len(), ocr_pages: ocr_pages.len() });
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
    let mut labels: HashMap<usize, String> = HashMap::new();
    for p in &sorted {
        labels.insert(p.pdf_page - 1, if p.label.is_empty() { p.pdf_page.to_string() } else { p.label.clone() });
    }
    let label = |i: usize| labels.get(&i).cloned().unwrap_or_else(|| (i + 1).to_string());
    let first_heading = first_big_heading(&elements);
    // The title the file itself gives; a caller's title replaces it, and the replaced one is kept as `source_title`.
    let auto_title: String = if opts.smart_title {
        src.meta_title.as_deref().and_then(usable_metadata_title).or_else(|| first_heading.clone()).unwrap_or_else(|| tidy_file_title(&opts.file_name))
    } else {
        src.meta_title
            .clone()
            .unwrap_or_else(|| std::path::Path::new(&opts.file_name).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| opts.file_name.clone()))
    };
    let title = opts.title.clone().unwrap_or_else(|| auto_title.clone());
    let source_title = (title != auto_title).then_some(auto_title);
    let words: Vec<usize> = pieces.iter().map(|p| word_count(&p.text)).collect();
    let headings_all: Vec<(u8, String)> = elements
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
        source: Source { blake3: hash.clone(), size: src.size, file_name: opts.file_name.clone(), https: opts.https.clone() },
        extractor: src.extractor.clone(),
        chunker: Chunker { version: CHUNKER_VERSION, target_words: TARGET_WORDS as u32, max_words: MAX_WORDS as u32 },
        embedding: EmbeddingInfo { embedder: embedder.name(), dims },
        created_at: opts.created_at.clone(),
        page_count,
        ocr_pages: ocr_pages.clone(),
        text_source_ocr_pages: sorted.iter().filter(|p| p.text_source == TextSource::Ocr).map(|p| p.pdf_page).collect(),
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
        pages: page_count,
        pieces: pack_pieces.len(),
        mean_words: words.iter().sum::<usize>() as f32 / words.len() as f32,
        min_words: *words.iter().min().unwrap(),
        max_words: *words.iter().max().unwrap(),
        ocr_pages,
        headings: headings_all.iter().take(15).cloned().collect(),
        heading_count: headings_all.len(),
        text_pages,
        words: print.words,
        ppi: src.ppi,
        year: src.year,
        minhash: print.minhash,
        mean_vector: mean_vector(&pack_pieces),
        first_heading,
    };
    // Revision 3: the same-book fingerprint travels in the pack, so every device can compare copies without the PDF.
    header.samebook = Some(Samebook::new(report.minhash.clone(), &report.mean_vector, report.text_pages as u32, report.pages as u32, report.ppi, src.size));
    Ok((Pack { header, pieces: pack_pieces }, report))
}
