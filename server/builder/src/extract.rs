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
    /// The year in the PDF's creation date, when it has one.
    pub year: Option<u32>,
    /// Typical resolution of the page images, in pixels per inch (the median over the pages that have a sizeable image).
    pub ppi: Option<u32>,
    /// 0-based pages whose text is OCR output (see `ocr`): they had no text layer, so their blocks were replaced by what Tesseract read.
    /// Empty for a plain extraction.
    pub ocr_pages: Vec<usize>,
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
    let year = doc.metadata(mupdf::document::MetadataName::CreationDate).ok().and_then(|d| year_of(&d));
    let pdf = PdfDocument::try_from(doc).map_err(|e| Error::ctx("reading the PDF", e))?;
    let count = pdf.page_count().map_err(|e| Error::ctx("counting pages", e))? as usize;
    let mut pages = Vec::with_capacity(count);
    let mut ppis: Vec<f32> = Vec::new();
    for i in 0..count {
        // A page MuPDF cannot read is kept as an empty page: it has no text and no images, so it is skipped later.
        match extract_page(&pdf, i, &mut ppis) {
            Ok(p) => pages.push(p),
            Err(_) => pages.push(RawPage { index: i, label: (i + 1).to_string(), width: 0.0, height: 0.0, blocks: Vec::new(), images: 0 }),
        }
    }
    ppis.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let ppi = ppis.get(ppis.len() / 2).map(|p| p.round() as u32);
    Ok(Extracted { title, pages, year, ppi, ocr_pages: Vec::new() })
}

/// The year in a PDF date ("D:20190512..." or "2019-05-12...").
fn year_of(date: &str) -> Option<u32> {
    let d = date.trim().trim_start_matches("D:");
    let y: u32 = d.get(..4)?.parse().ok()?;
    (1800..=2100).contains(&y).then_some(y)
}

pub(crate) fn extract_page(pdf: &PdfDocument, i: usize, ppis: &mut Vec<f32>) -> Result<RawPage> {
    let page = pdf.load_page(i as i32).map_err(|e| Error::ctx("loading a page", e))?;
    let bounds = page.bounds().map_err(|e| Error::ctx("page size", e))?;
    // Dehyphenate on; PRESERVE_LIGATURES left off so ligatures come out as letters; images kept so no-text pages that
    // carry a picture can be told from blank ones.
    let flags = TextPageFlags::DEHYPHENATE | TextPageFlags::PRESERVE_IMAGES;
    let tp = page.to_text_page(flags).map_err(|e| Error::ctx("reading page text", e))?;
    let mut blocks = Vec::new();
    let mut images = 0;
    let mut best_ppi = 0f32;
    for b in tp.blocks() {
        match b.r#type() {
            TextBlockType::Image => {
                images += 1;
                // pixels across the picture over its width on the page in inches (tiny pictures say nothing about a scan)
                if let Some(img) = b.image() {
                    let r = b.bounds();
                    let width_pt = r.x1 - r.x0;
                    if width_pt >= 72.0 && img.width() > 0 {
                        best_ppi = best_ppi.max(img.width() as f32 / (width_pt / 72.0));
                    }
                }
            }
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
    if best_ppi > 0.0 {
        ppis.push(best_ppi.min(1200.0));
    }
    let label = pdf.page_label(i).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty()).unwrap_or_else(|| (i + 1).to_string());
    Ok(RawPage { index: i, label, width: bounds.x1 - bounds.x0, height: bounds.y1 - bounds.y0, blocks, images })
}

// ---- wire format
//
// The child process that reads a PDF (see `isolate`) hands the extraction back as bytes. A hand-written little-endian layout rather than
// JSON: every f32 comes back bit for bit (NaN and infinity included), so the output is identical to an in-process extraction.

const WIRE_MAGIC: &[u8; 4] = b"CEX2";

fn put_u32(out: &mut Vec<u8>, n: usize) {
    out.extend_from_slice(&(n as u32).to_le_bytes());
}

fn put_f32(out: &mut Vec<u8>, f: f32) {
    out.extend_from_slice(&f.to_bits().to_le_bytes());
}

fn put_str(out: &mut Vec<u8>, s: &str) {
    put_u32(out, s.len());
    out.extend_from_slice(s.as_bytes());
}

impl Extracted {
    /// The extraction as bytes, for [`Extracted::from_wire`].
    pub fn to_wire(&self) -> Vec<u8> {
        let mut o = Vec::new();
        o.extend_from_slice(WIRE_MAGIC);
        match &self.title {
            Some(t) => {
                o.push(1);
                put_str(&mut o, t);
            }
            None => o.push(0),
        }
        for opt in [self.year, self.ppi] {
            o.extend_from_slice(&opt.map_or(0u64, |v| 1 << 32 | v as u64).to_le_bytes());
        }
        put_u32(&mut o, self.ocr_pages.len());
        for i in &self.ocr_pages {
            o.extend_from_slice(&(*i as u64).to_le_bytes());
        }
        put_u32(&mut o, self.pages.len());
        for p in &self.pages {
            o.extend_from_slice(&(p.index as u64).to_le_bytes());
            put_str(&mut o, &p.label);
            put_f32(&mut o, p.width);
            put_f32(&mut o, p.height);
            o.extend_from_slice(&(p.images as u64).to_le_bytes());
            put_u32(&mut o, p.blocks.len());
            for b in &p.blocks {
                for f in [b.x0, b.y0, b.x1, b.y1] {
                    put_f32(&mut o, f);
                }
                put_u32(&mut o, b.lines.len());
                for l in &b.lines {
                    put_str(&mut o, &l.text);
                    for f in [l.x0, l.y0, l.x1, l.y1, l.size] {
                        put_f32(&mut o, f);
                    }
                    o.push(l.bold as u8);
                    o.push(l.italic as u8);
                }
            }
        }
        o
    }

    /// Read what [`Extracted::to_wire`] wrote. Any shortfall or leftover is an error (a child that died halfway writes nothing usable).
    pub fn from_wire(bytes: &[u8]) -> Result<Extracted> {
        struct R<'a>(&'a [u8]);
        impl<'a> R<'a> {
            fn take(&mut self, n: usize) -> Result<&'a [u8]> {
                if self.0.len() < n {
                    return Err(Error::new("the extraction is cut short"));
                }
                let (a, b) = self.0.split_at(n);
                self.0 = b;
                Ok(a)
            }
            fn u8(&mut self) -> Result<u8> {
                Ok(self.take(1)?[0])
            }
            fn u32(&mut self) -> Result<usize> {
                Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()) as usize)
            }
            fn u64(&mut self) -> Result<usize> {
                Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()) as usize)
            }
            fn opt_u32(&mut self) -> Result<Option<u32>> {
                let v = u64::from_le_bytes(self.take(8)?.try_into().unwrap());
                Ok(if v >> 32 == 1 { Some(v as u32) } else { None })
            }
            fn f32(&mut self) -> Result<f32> {
                Ok(f32::from_bits(u32::from_le_bytes(self.take(4)?.try_into().unwrap())))
            }
            fn str(&mut self) -> Result<String> {
                let n = self.u32()?;
                String::from_utf8(self.take(n)?.to_vec()).map_err(|_| Error::new("the extraction has invalid text"))
            }
            /// A count that cannot be bigger than the bytes left (each item takes at least `min` bytes), so a bad count cannot reserve gigabytes.
            fn count(&mut self, min: usize) -> Result<usize> {
                let n = self.u32()?;
                if n.saturating_mul(min) > self.0.len() {
                    return Err(Error::new("the extraction is cut short"));
                }
                Ok(n)
            }
        }
        let mut r = R(bytes);
        if r.take(4)? != WIRE_MAGIC {
            return Err(Error::new("not an extraction"));
        }
        let title = if r.u8()? == 1 { Some(r.str()?) } else { None };
        let (year, ppi) = (r.opt_u32()?, r.opt_u32()?);
        let nocr = r.count(8)?;
        let mut ocr_pages = Vec::with_capacity(nocr);
        for _ in 0..nocr {
            ocr_pages.push(r.u64()?);
        }
        let np = r.count(24)?;
        let mut pages = Vec::with_capacity(np);
        for _ in 0..np {
            let index = r.u64()?;
            let label = r.str()?;
            let (width, height) = (r.f32()?, r.f32()?);
            let images = r.u64()?;
            let nb = r.count(20)?;
            let mut blocks = Vec::with_capacity(nb);
            for _ in 0..nb {
                let (x0, y0, x1, y1) = (r.f32()?, r.f32()?, r.f32()?, r.f32()?);
                let nl = r.count(26)?;
                let mut lines = Vec::with_capacity(nl);
                for _ in 0..nl {
                    let text = r.str()?;
                    let (lx0, ly0, lx1, ly1, size) = (r.f32()?, r.f32()?, r.f32()?, r.f32()?, r.f32()?);
                    let (bold, italic) = (r.u8()? != 0, r.u8()? != 0);
                    lines.push(Line { text, x0: lx0, y0: ly0, x1: lx1, y1: ly1, size, bold, italic });
                }
                blocks.push(Block { x0, y0, x1, y1, lines });
            }
            pages.push(RawPage { index, label, width, height, blocks, images });
        }
        if !r.0.is_empty() {
            return Err(Error::new("the extraction has extra bytes"));
        }
        Ok(Extracted { title, pages, year, ppi, ocr_pages })
    }
}

#[cfg(test)]
mod tests {
    use super::year_of;

    #[test]
    fn a_year_comes_from_a_pdf_date() {
        assert_eq!(year_of("D:20190512103000+00'00'"), Some(2019));
        assert_eq!(year_of("2007-03-01T10:00:00Z"), Some(2007));
        assert_eq!(year_of("D:00000101"), None);
        assert_eq!(year_of("x"), None);
        assert_eq!(year_of(""), None);
    }
}
