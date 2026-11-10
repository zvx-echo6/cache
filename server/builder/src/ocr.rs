//! OCR for pages with no text layer, with the Tesseract that is built into MuPDF (the `tesseract` feature of the mupdf crate).
//!
//! - A page needs OCR when it has pictures and fewer than [`MIN_PAGE_CHARS`] characters of text (the rule `layout` uses to list
//!   `ocr_pages`). Only those pages are read; pages that have text keep their own.
//! - MuPDF's PDF-OCR writer draws the page at [`OCR_DPI`] (300 pixels per inch, what the phones' OCR is fed too), hands the bitmap to
//!   Tesseract, and writes the result as a one-off PDF in a work folder. That PDF is read back with the same page reader as any other
//!   PDF (`extract::extract_page`), so OCR text gets the same lines, boxes and layout step as a text layer. The scratch PDF is a build
//!   intermediate: it is deleted with its work folder and never stored, hashed or shown. The book's own file, and so its BLAKE3
//!   identity, are never touched.
//! - Nothing here runs in the server process: `isolate` runs [`ocr_pages`] in the same crash-proof child as reading, with a memory
//!   limit and a time limit, a few pages at a time.
//! - The trained data is `<lang>.traineddata` in a folder ([`OcrSettings::datadir`]); the release ships `eng.traineddata` in
//!   `lib/tessdata` next to the program. Without it OCR is off and a scan ends as `ocr_needed`, as before.

use crate::error::{Error, Result};
use crate::extract::{extract_page, Extracted, RawPage};
use mupdf::document_writer::DocumentWriter;
use mupdf::pdf::PdfDocument;
use mupdf::{Document, Matrix};
use std::path::{Path, PathBuf};

pub use cache_pack::pagewriter::MIN_PAGE_CHARS;

/// The engine name written to the pack's `book.ocr.engine`.
pub const OCR_ENGINE: &str = "tesseract";
/// The version written to `book.ocr.version`: the Tesseract snapshot in MuPDF 1.27.2 (it says 5.0.0-alpha) and the MuPDF release
/// that carries it. A new mupdf-sys pin changes this line.
pub const OCR_VERSION: &str = "5.0.0-alpha (MuPDF 1.27.2, Leptonica 1.85.0)";
/// Pixels per inch the page is drawn at. 300 is what Tesseract is tuned for (its documentation asks for at least 300 dpi: text about
/// 20 to 30 pixels high), what scanners and the phones' OCR use, and above that the time grows with the pixels for little gain.
pub const OCR_DPI: u32 = 300;
/// The language to read.
pub const OCR_LANG: &str = "eng";
/// Pages OCR'd per child process (see `isolate`): the PDF is read again by each child, and a crash or timeout loses only this many.
pub const OCR_BATCH: usize = 5;

/// Where the trained data is and what to read.
#[derive(Debug, Clone, PartialEq)]
pub struct OcrSettings {
    /// The folder holding `<lang>.traineddata`.
    pub datadir: PathBuf,
    pub lang: String,
    pub dpi: u32,
}

impl OcrSettings {
    pub fn new(datadir: impl Into<PathBuf>) -> OcrSettings {
        OcrSettings { datadir: datadir.into(), lang: OCR_LANG.to_string(), dpi: OCR_DPI }
    }

    /// The settings for this installation, when the trained data is there: `CACHE_TESSDATA_DIR`, else `lib/tessdata` next to the program
    /// (the release layout), else `../lib/tessdata`. `None`: OCR is off.
    pub fn discover() -> Option<OcrSettings> {
        let mut dirs: Vec<PathBuf> = Vec::new();
        if let Some(d) = std::env::var_os("CACHE_TESSDATA_DIR") {
            dirs.push(PathBuf::from(d));
        }
        if let Some(exe_dir) = std::env::current_exe().ok().and_then(|p| p.parent().map(Path::to_path_buf)) {
            dirs.push(exe_dir.join("lib").join("tessdata"));
            dirs.push(exe_dir.join("..").join("lib").join("tessdata"));
        }
        dirs.into_iter().find(|d| d.join(format!("{OCR_LANG}.traineddata")).is_file()).map(OcrSettings::new)
    }

    /// The settings as a JSON text, for the child's environment.
    pub fn to_arg(&self, pages: &[usize]) -> String {
        serde_json::json!({"datadir": self.datadir.to_string_lossy(), "lang": self.lang, "dpi": self.dpi, "pages": pages}).to_string()
    }

    /// What [`OcrSettings::to_arg`] wrote.
    pub fn from_arg(arg: &str) -> Option<(OcrSettings, Vec<usize>)> {
        let v: serde_json::Value = serde_json::from_str(arg).ok()?;
        let s = OcrSettings { datadir: PathBuf::from(v.get("datadir")?.as_str()?), lang: v.get("lang")?.as_str()?.to_string(), dpi: u32::try_from(v.get("dpi")?.as_u64()?).ok()? };
        let pages = v.get("pages")?.as_array()?.iter().filter_map(|p| p.as_u64().map(|n| n as usize)).collect();
        Some((s, pages))
    }
}

/// The 0-based pages that have pictures and no real text: the ones to OCR.
pub fn pages_needing_ocr(ext: &Extracted) -> Vec<usize> {
    ext.pages.iter().filter(|p| p.text_chars() < MIN_PAGE_CHARS && p.images > 0).map(|p| p.index).collect()
}

/// Put what OCR read into `ext`: each page in `read` replaces the blocks of the page with the same index, and is recorded in
/// `ext.ocr_pages` when it got text. A page OCR found nothing on stays as it was (and so still needs OCR).
pub fn apply_ocr(ext: &mut Extracted, read: Vec<RawPage>) {
    for r in read {
        if r.text_chars() == 0 {
            continue;
        }
        if let Some(p) = ext.pages.iter_mut().find(|p| p.index == r.index) {
            p.blocks = r.blocks;
            if !ext.ocr_pages.contains(&r.index) {
                ext.ocr_pages.push(r.index);
            }
        }
    }
    ext.ocr_pages.sort_unstable();
}

/// OCR the given 0-based pages of `pdf` (in this process; `isolate` runs it in the child). `work` is a folder for the scratch PDF.
/// Each result is a [`RawPage`] with the OCR text as blocks, in the page's own coordinates (points, y down). A page that cannot be
/// drawn or read is left out.
pub fn ocr_pages(pdf: &[u8], pages: &[usize], s: &OcrSettings, work: &Path) -> Result<Vec<RawPage>> {
    if pages.is_empty() {
        return Ok(Vec::new());
    }
    if !s.datadir.join(format!("{}.traineddata", s.lang)).is_file() {
        return Err(Error::new(format!("no {}.traineddata in {}", s.lang, s.datadir.display())));
    }
    let doc = Document::from_bytes(pdf, "application/pdf").map_err(|e| Error::ctx("opening the PDF", e))?;
    let src = PdfDocument::try_from(doc).map_err(|e| Error::ctx("reading the PDF", e))?;
    let out = work.join("ocr-pages.pdf");
    let out_str = out.to_str().ok_or_else(|| Error::new("the OCR work folder has an unusable name"))?;
    let datadir = s.datadir.to_str().ok_or_else(|| Error::new("the OCR data folder has an unusable name"))?;
    let options = format!("resolution={},colorspace=gray,compression=flate,ocr-language={},ocr-datadir={}", s.dpi, s.lang, datadir);
    // Pages that were drawn, in the order they went into the scratch PDF, with the size they have in the source.
    let mut drawn: Vec<(usize, f32, f32)> = Vec::new();
    {
        let mut writer = DocumentWriter::with_ocr(out_str, &options).map_err(|e| Error::ctx("starting OCR", e))?;
        for &i in pages {
            let Ok(page) = src.load_page(i as i32) else { continue };
            let Ok(bounds) = page.bounds() else { continue };
            let Ok(dev) = writer.begin_page(bounds) else { continue };
            let ran = page.run(&dev, &Matrix::IDENTITY);
            writer.end_page(dev).map_err(|e| Error::ctx("reading a scanned page", e))?;
            if ran.is_ok() {
                drawn.push((i, bounds.x1 - bounds.x0, bounds.y1 - bounds.y0));
            } else {
                // The device already took the (blank) page into the scratch PDF; keep the numbering by recording it as empty.
                drawn.push((i, 0.0, 0.0));
            }
        }
    }
    let scratch = Document::from_bytes(&std::fs::read(&out).map_err(|e| Error::ctx("reading the OCR result", e))?, "application/pdf").map_err(|e| Error::ctx("opening the OCR result", e))?;
    let scratch = PdfDocument::try_from(scratch).map_err(|e| Error::ctx("reading the OCR result", e))?;
    let mut result = Vec::with_capacity(drawn.len());
    for (k, (index, w, h)) in drawn.into_iter().enumerate() {
        if w <= 0.0 || h <= 0.0 {
            continue;
        }
        let mut ignored = Vec::new();
        let Ok(mut p) = extract_page(&scratch, k, &mut ignored) else { continue };
        // The scratch page is the source page's size already; scale anyway if the writer rounded it to whole pixels.
        let (sx, sy) = if p.width > 0.0 && p.height > 0.0 { (w / p.width, h / p.height) } else { (1.0, 1.0) };
        if (sx - 1.0).abs() > 0.005 || (sy - 1.0).abs() > 0.005 {
            for b in &mut p.blocks {
                b.x0 *= sx;
                b.x1 *= sx;
                b.y0 *= sy;
                b.y1 *= sy;
                for l in &mut b.lines {
                    l.x0 *= sx;
                    l.x1 *= sx;
                    l.y0 *= sy;
                    l.y1 *= sy;
                    l.size *= sy;
                }
            }
        }
        p.index = index;
        p.width = w;
        p.height = h;
        p.images = 0;
        result.push(p);
    }
    let _ = std::fs::remove_file(&out);
    Ok(result)
}
