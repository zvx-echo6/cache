//! PDF bytes to a document pack: extract, lay out, chunk, embed.

use crate::embed::Embedder;
use crate::error::{Error, Result};
use crate::extract::{extract_pdf, Extracted, EXTRACTOR_NAME, EXTRACTOR_VERSION};
use crate::layout::{layout, Element, Layout, LAYOUT_VERSION};
use crate::ocr::{OCR_ENGINE, OCR_VERSION};
use crate::pack::{valid_doc_id, OcrInfo, Pack, Tool};
pub use cache_pack::build_types::{first_big_heading, tidy_file_title, usable_metadata_title, BuildOptions, Progress, Report, EMBED_BATCH};
use crate::pagewriter::{build_pack_from_pages, BlockKind, PageBlock, PageIn, PagesSource, TextSource};

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
    // Pages read by OCR are recorded in the book facts (`book.ocr`) and marked `text_source: ocr` in `pages_of`. The file stays as it was.
    let mut with_ocr;
    let opts = if !ext.ocr_pages.is_empty() && opts.ocr.is_none() {
        with_ocr = opts.clone();
        with_ocr.ocr = Some(OcrInfo { engine: OCR_ENGINE.to_string(), version: OCR_VERSION.to_string(), pages_ocrd: ext.ocr_pages.len() as u32, confidence: None });
        &with_ocr
    } else {
        opts
    };
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
        .map(|(i, (rp, blocks))| PageIn { pdf_page: i + 1, label: rp.label.clone(), text_source: if ext.ocr_pages.contains(&i) { TextSource::Ocr } else { TextSource::Layer }, blocks })
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
