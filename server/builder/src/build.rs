//! PDF bytes to a document pack: extract, lay out, chunk, embed.

use crate::chunk::{chunk, CHUNKER_VERSION, MAX_WORDS, TARGET_WORDS};
use crate::embed::Embedder;
use crate::error::{Error, Result};
use crate::extract::{extract_pdf, EXTRACTOR_NAME, EXTRACTOR_VERSION};
use crate::layout::{layout, Element};
use crate::pack::{valid_doc_id, Chunker, EmbeddingInfo, Header, Pack, PackPiece, Source, Tool, PACK_FORMAT};
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
}

impl BuildOptions {
    pub fn new(file_name: &str, created_at: &str) -> Self {
        BuildOptions { doc_id: None, doc_version: 1, title: None, https: None, file_name: file_name.to_string(), created_at: created_at.to_string() }
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
    let hash = blake3::hash(pdf).to_hex().to_string();
    let doc_id = opts.doc_id.clone().unwrap_or_else(|| hash.clone());
    if !valid_doc_id(&doc_id) {
        return Err(Error::new(format!("invalid doc_id {doc_id:?}: use letters, digits, '.', '_' and '-'")));
    }
    if opts.doc_version == 0 {
        return Err(Error::new("doc_version starts at 1"));
    }
    let ext = extract_pdf(pdf)?;
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
    let title = opts
        .title
        .clone()
        .or_else(|| ext.title.clone())
        .unwrap_or_else(|| std::path::Path::new(&opts.file_name).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_else(|| opts.file_name.clone()));
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
            pdf_page: (p.page + 1) as u32,
            page_end: if p.page_end != p.page { Some(label(p.page_end)) } else { None },
            heading_path: p.heading_path.clone(),
            vector: v,
        })
        .collect();
    let header = Header {
        cdoc: PACK_FORMAT,
        doc_id,
        doc_version: opts.doc_version,
        title,
        source: Source { blake3: hash, size: pdf.len() as u64, file_name: opts.file_name.clone(), https: opts.https.clone() },
        extractor: Tool { name: EXTRACTOR_NAME.to_string(), version: EXTRACTOR_VERSION.to_string() },
        chunker: Chunker { version: CHUNKER_VERSION, target_words: TARGET_WORDS as u32, max_words: MAX_WORDS as u32 },
        embedding: EmbeddingInfo { embedder: embedder.name(), dims },
        created_at: opts.created_at.clone(),
        page_count: ext.pages.len(),
        ocr_pages: ocr_pages.clone(),
        pieces: pack_pieces.len(),
    };
    let report = Report {
        pages: ext.pages.len(),
        pieces: pack_pieces.len(),
        mean_words: words.iter().sum::<usize>() as f32 / words.len() as f32,
        min_words: *words.iter().min().unwrap(),
        max_words: *words.iter().max().unwrap(),
        ocr_pages,
        headings: headings_all.iter().take(15).cloned().collect(),
        heading_count: headings_all.len(),
    };
    Ok((Pack { header, pieces: pack_pieces }, report))
}
