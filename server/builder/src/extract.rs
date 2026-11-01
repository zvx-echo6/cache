//! Extraction with MuPDF: per page, the structured text as blocks of lines with their boxes, size, bold and italic, and
//! the page label. Dehyphenation is on and ligatures are expanded (not preserved). Nothing here decides reading order or
//! headings; that is `layout`, which works on the plain data types below (and so is testable without a PDF).

use crate::error::{Error, Result};
use mupdf::pdf::PdfDocument;
use mupdf::text_page::TextBlockType;
use mupdf::{Document, TextPageFlags};

/// One line of text with its box (page coordinates, y grows downwards) and its style.
#[derive(Debug, Clone, PartialEq)]
pub struct Line {
    pub text: String,
    pub x0: f32,
    pub y0: f32,
    pub x1: f32,
    pub y1: f32,
    /// Character-weighted mean font size in points.
    pub size: f32,
    /// More than half of the characters are bold.
    pub bold: bool,
    /// More than half of the characters are italic.
    pub italic: bool,
}

/// A block of lines (MuPDF's block: typically a paragraph or a column of lines).
#[derive(Debug, Clone, PartialEq)]
pub struct Block {
    pub x0: f32,
    pub y0: f32,
    pub x1: f32,
    pub y1: f32,
    pub lines: Vec<Line>,
}

impl Block {
    pub fn from_lines(lines: Vec<Line>) -> Block {
        let x0 = lines.iter().map(|l| l.x0).fold(f32::MAX, f32::min);
        let y0 = lines.iter().map(|l| l.y0).fold(f32::MAX, f32::min);
        let x1 = lines.iter().map(|l| l.x1).fold(f32::MIN, f32::max);
        let y1 = lines.iter().map(|l| l.y1).fold(f32::MIN, f32::max);
        Block { x0, y0, x1, y1, lines }
    }
    pub fn width(&self) -> f32 {
        self.x1 - self.x0
    }
    pub fn chars(&self) -> usize {
        self.lines.iter().map(|l| l.text.chars().count()).sum()
    }
}

/// One page as MuPDF reports it.
#[derive(Debug, Clone, PartialEq)]
pub struct RawPage {
    /// 0-based position in the PDF.
    pub index: usize,
    /// The page label (the printed number or numeral when the PDF has page labels), else `index + 1`.
    pub label: String,
    pub width: f32,
    pub height: f32,
    pub blocks: Vec<Block>,
    /// Image blocks on the page.
    pub images: usize,
}

impl RawPage {
    pub fn text_chars(&self) -> usize {
        self.blocks.iter().map(Block::chars).sum()
    }
}

/// A whole document as extracted.
#[derive(Debug, Clone, PartialEq)]
pub struct Extracted {
    /// The title in the PDF's metadata, when there is one.
    pub title: Option<String>,
    pub pages: Vec<RawPage>,
}

/// The extractor's name and version, recorded in every pack.
pub const EXTRACTOR_NAME: &str = "mupdf";
pub const EXTRACTOR_VERSION: &str = "0.8.0";

fn lig_fold(c: char) -> Option<&'static str> {
    // Ligatures MuPDF leaves as one code point when a font maps them so: expanded here as well (never preserved).
    Some(match c {
        '\u{FB00}' => "ff",
        '\u{FB01}' => "fi",
        '\u{FB02}' => "fl",
        '\u{FB03}' => "ffi",
        '\u{FB04}' => "ffl",
        '\u{FB05}' | '\u{FB06}' => "st",
        _ => return None,
    })
}

/// Extract a PDF from memory. An encrypted PDF is an error (no password is known).
pub fn extract_pdf(bytes: &[u8]) -> Result<Extracted> {
    let doc = Document::from_bytes(bytes, "application/pdf").map_err(|e| Error::ctx("opening the PDF", e))?;
    if doc.needs_password().map_err(|e| Error::ctx("opening the PDF", e))? {
        return Err(Error::new("the PDF is encrypted (a password is needed)"));
    }
    let title = doc
        .metadata(mupdf::document::MetadataName::Title)
        .ok()
        .map(|t| t.trim().to_string())
        .filter(|t| !t.is_empty());
    let pdf = PdfDocument::try_from(doc).map_err(|e| Error::ctx("reading the PDF", e))?;
    let count = pdf.page_count().map_err(|e| Error::ctx("counting pages", e))? as usize;
    let mut pages = Vec::with_capacity(count);
    for i in 0..count {
        // A page MuPDF cannot read is kept as an empty page: it has no text and no images, so it is skipped later.
        match extract_page(&pdf, i) {
            Ok(p) => pages.push(p),
            Err(_) => pages.push(RawPage { index: i, label: (i + 1).to_string(), width: 0.0, height: 0.0, blocks: Vec::new(), images: 0 }),
        }
    }
    Ok(Extracted { title, pages })
}

fn extract_page(pdf: &PdfDocument, i: usize) -> Result<RawPage> {
    let page = pdf.load_page(i as i32).map_err(|e| Error::ctx("loading a page", e))?;
    let bounds = page.bounds().map_err(|e| Error::ctx("page size", e))?;
    // Dehyphenate on; PRESERVE_LIGATURES left off so ligatures come out as letters; images kept so no-text pages that
    // carry a picture can be told from blank ones.
    let flags = TextPageFlags::DEHYPHENATE | TextPageFlags::PRESERVE_IMAGES;
    let tp = page.to_text_page(flags).map_err(|e| Error::ctx("reading page text", e))?;
    let mut blocks = Vec::new();
    let mut images = 0;
    for b in tp.blocks() {
        match b.r#type() {
            TextBlockType::Image => images += 1,
            TextBlockType::Text => {
                let mut lines = Vec::new();
                for l in b.lines() {
                    let mut text = String::new();
                    let (mut n, mut size_sum, mut bold_n, mut ital_n) = (0usize, 0.0f64, 0usize, 0usize);
                    for ch in l.chars() {
                        let Some(c) = ch.char() else { continue };
                        match lig_fold(c) {
                            Some(s) => text.push_str(s),
                            None => text.push(c),
                        }
                        if !c.is_whitespace() {
                            n += 1;
                            size_sum += ch.size() as f64;
                            let font = ch.font();
                            if ch.flags().contains(mupdf::text_page::TextCharFlags::BOLD) || font.as_ref().is_some_and(|f| f.is_bold()) {
                                bold_n += 1;
                            }
                            if font.as_ref().is_some_and(|f| f.is_italic()) {
                                ital_n += 1;
                            }
                        }
                    }
                    if n == 0 {
                        continue;
                    }
                    let r = l.bounds();
                    lines.push(Line {
                        text,
                        x0: r.x0,
                        y0: r.y0,
                        x1: r.x1,
                        y1: r.y1,
                        size: (size_sum / n as f64) as f32,
                        bold: bold_n * 2 > n,
                        italic: ital_n * 2 > n,
                    });
                }
                if !lines.is_empty() {
                    blocks.push(Block::from_lines(lines));
                }
            }
            _ => {}
        }
    }
    let label = pdf.page_label(i).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).unwrap_or_else(|| (i + 1).to_string());
    Ok(RawPage { index: i, label, width: bounds.x1 - bounds.x0, height: bounds.y1 - bounds.y0, blocks, images })
}
