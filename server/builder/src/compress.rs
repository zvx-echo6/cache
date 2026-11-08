//! Optional PDF compression at ingest: `off`, `lossless`, or `smaller_scans` (with a quality preset).
//!
//! This is the portable core: plain functions from PDF bytes to PDF bytes plus an outcome record. It uses only MuPDF (through the
//! `mupdf` crate) and a pure-Rust JPEG encoder, so it has no Linux-only parts (no rlimit, fork, /proc, file paths or helper
//! binaries). The crash-proof child process, the memory limit and the time limit live in `isolate` (the server / CLI layer).
//!
//! - `lossless`: MuPDF rewrites the file with garbage collection and de-duplication, deflates the streams that are stored
//!   uncompressed and packs objects into object streams. Pages must render pixel-identical.
//! - `smaller_scans`: the same, after the page images are recompressed (JPEG at a preset quality) and downsampled (to a preset
//!   resolution, measured from where the page really draws the image). Text, vector content, fonts and one-bit images are not touched.
//!
//! Safety rules, applied to every file: a sample of pages is rendered before and after at [`CHECK_DPI`] and the lowest PSNR is
//! kept; lossless must be identical, a lossy preset must stay at or above its floor, and the result must be at least 2% smaller.
//! Otherwise the original is kept and the reason is recorded.

use crate::error::{Error, Result};
use mupdf::device::NativeDevice;
use mupdf::pdf::{PdfDocument, PdfObject, PdfWriteOptions};
use mupdf::{Buffer, ColorParams, Colorspace, Device, Document, Image, Matrix};
use serde::{Deserialize, Serialize};
use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::rc::Rc;

/// The output must be at least this much smaller than the input (2%), else the original is kept.
pub const MIN_GAIN: f64 = 0.02;
/// Pages are compared at this resolution.
pub const CHECK_DPI: f32 = 100.0;
/// How many pages the check renders (spread through the book).
pub const CHECK_PAGES: usize = 5;
/// PSNR reported for pages that are pixel-identical.
pub const PSNR_IDENTICAL: f64 = 100.0;
/// An image is replaced only when its new stream is at most this fraction of the old one.
const IMAGE_KEEP_RATIO: f64 = 0.85;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "snake_case")]
pub enum Level {
    #[default]
    Off,
    Lossless,
    SmallerScans,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Preset {
    High,
    Balanced,
    Smallest,
}

/// What to do: a level, and for `smaller_scans` a preset (`balanced` when none is given).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct Compression {
    #[serde(default)]
    pub level: Level,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub preset: Option<Preset>,
}

/// The numbers behind a preset.
#[derive(Clone, Copy, Debug)]
pub struct PresetParams {
    /// JPEG quality, 1 to 100.
    pub quality: u8,
    /// An image drawn at more than this many pixels per inch is downsampled.
    pub threshold_dpi: f32,
    /// ...to this resolution.
    pub target_dpi: f32,
    /// Half-resolution color (4:2:0) when true, else 4:2:2.
    pub chroma_half: bool,
    /// The lowest page PSNR (dB) at [`CHECK_DPI`] that is accepted; below it the original is kept.
    pub psnr_floor: f64,
}

impl Preset {
    pub fn params(self) -> PresetParams {
        match self {
            Preset::High => PresetParams { quality: 85, threshold_dpi: 360.0, target_dpi: 300.0, chroma_half: false, psnr_floor: 30.0 },
            Preset::Balanced => PresetParams { quality: 70, threshold_dpi: 240.0, target_dpi: 200.0, chroma_half: true, psnr_floor: 26.0 },
            Preset::Smallest => PresetParams { quality: 50, threshold_dpi: 180.0, target_dpi: 150.0, chroma_half: true, psnr_floor: 24.0 },
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Preset::High => "high",
            Preset::Balanced => "balanced",
            Preset::Smallest => "smallest",
        }
    }
}

impl Level {
    pub fn name(self) -> &'static str {
        match self {
            Level::Off => "off",
            Level::Lossless => "lossless",
            Level::SmallerScans => "smaller_scans",
        }
    }
}

impl Compression {
    pub const OFF: Compression = Compression { level: Level::Off, preset: None };
    pub const LOSSLESS: Compression = Compression { level: Level::Lossless, preset: None };

    /// The preset that applies: the chosen one, `balanced` by default, none for the other levels.
    pub fn effective_preset(&self) -> Option<Preset> {
        (self.level == Level::SmallerScans).then(|| self.preset.unwrap_or(Preset::Balanced))
    }

    /// `off`, `lossless`, `smaller_scans` or `smaller_scans:high|balanced|smallest` (the CLI form `--compress`).
    pub fn parse(s: &str) -> std::result::Result<Compression, String> {
        let (l, p) = match s.split_once(':') {
            Some((l, p)) => (l, Some(p)),
            None => (s, None),
        };
        let level = match l.trim() {
            "off" => Level::Off,
            "lossless" => Level::Lossless,
            "smaller_scans" => Level::SmallerScans,
            other => return Err(format!("unknown compression level {other:?} (use off, lossless or smaller_scans)")),
        };
        Compression::from_parts(level, p.map(str::trim))
    }

    /// A level and an optional preset name, checked together (a preset only goes with `smaller_scans`).
    pub fn from_parts(level: Level, preset: Option<&str>) -> std::result::Result<Compression, String> {
        let preset = match preset {
            None | Some("") => None,
            Some("high") => Some(Preset::High),
            Some("balanced") => Some(Preset::Balanced),
            Some("smallest") => Some(Preset::Smallest),
            Some(other) => return Err(format!("unknown quality preset {other:?} (use high, balanced or smallest)")),
        };
        if preset.is_some() && level != Level::SmallerScans {
            return Err("a quality preset only goes with smaller_scans".into());
        }
        Ok(Compression { level, preset })
    }
}

/// What happened to one book. The field names are the ones the build record and `docs.json` use.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CompressionOutcome {
    /// The size of the file as it arrived.
    pub original_size: u64,
    /// The size of the file that is kept.
    pub stored_size: u64,
    /// `off`, `lossless` or `smaller_scans` (what was asked for).
    pub level: String,
    /// `high`, `balanced` or `smallest` for `smaller_scans`.
    pub preset: Option<String>,
    /// The original was kept (compression off, not smaller enough, below the quality floor, or it failed).
    pub kept_original: bool,
    /// Why the original was kept.
    pub kept_reason: Option<String>,
    /// The lowest PSNR (dB) over the pages checked, at [`CHECK_DPI`]; [`PSNR_IDENTICAL`] means pixel-identical. None when no check ran.
    pub psnr_min: Option<f64>,
}

impl CompressionOutcome {
    pub(crate) fn kept(c: &Compression, size: usize, why: impl Into<String>, psnr: Option<f64>) -> CompressionOutcome {
        CompressionOutcome {
            original_size: size as u64,
            stored_size: size as u64,
            level: c.level.name().into(),
            preset: c.effective_preset().map(|p| p.name().into()),
            kept_original: true,
            kept_reason: Some(why.into()),
            psnr_min: psnr,
        }
    }
}

/// Compress a PDF. Never fails and never returns a larger file: on any problem the original bytes come back with the reason in the
/// outcome. (A crash of MuPDF itself is not catchable here; the callers run this in a child process, see `isolate`.)
pub fn compress_pdf(input: &[u8], c: &Compression) -> (Vec<u8>, CompressionOutcome) {
    if c.level == Level::Off {
        return (input.to_vec(), CompressionOutcome::kept(c, input.len(), "compression is off", None));
    }
    match try_compress(input, c) {
        Ok(Tried::Done { out, psnr, note }) => {
            let outcome = CompressionOutcome {
                original_size: input.len() as u64,
                stored_size: out.len() as u64,
                level: c.level.name().into(),
                preset: c.effective_preset().map(|p| p.name().into()),
                kept_original: false,
                kept_reason: note,
                psnr_min: Some(psnr),
            };
            (out, outcome)
        }
        Ok(Tried::Kept(why, psnr)) => (input.to_vec(), CompressionOutcome::kept(c, input.len(), why, psnr)),
        Err(e) => (input.to_vec(), CompressionOutcome::kept(c, input.len(), format!("compression failed: {}", e.0), None)),
    }
}

enum Tried {
    /// `note` is set when smaller_scans fell back to the lossless result, and says why.
    Done { out: Vec<u8>, psnr: f64, note: Option<String> },
    Kept(String, Option<f64>),
}

fn try_compress(input: &[u8], c: &Compression) -> Result<Tried> {
    let pages = match open(input)? {
        Ok((_, pages)) => pages,
        Err(why) => return Ok(Tried::Kept(why, None)),
    };
    let Some(preset) = c.effective_preset() else {
        return finish_lossless(input, pages, None);
    };
    // The lossy attempt first. If it is not smaller enough or a page falls below the floor, the lossless result is used instead
    // (the pictures are then exactly as they were), and the reason is recorded.
    let pp = preset.params();
    let (mut pdf, _) = open(input)?.map_err(Error::new)?;
    recompress_images(&mut pdf, pp, pages)?;
    let out = save(&mut pdf)?;
    drop(pdf);
    let why = if (out.len() as f64) > input.len() as f64 * (1.0 - MIN_GAIN) {
        "the pictures did not get smaller".to_string()
    } else {
        match check_pages(input, &out, pages)? {
            Ok(psnr) if psnr >= pp.psnr_floor => return Ok(Tried::Done { out, psnr, note: None }),
            Ok(psnr) => format!("a page fell to {psnr:.1} dB, below the {:.0} dB floor for {}", pp.psnr_floor, preset.name()),
            Err(why) => why,
        }
    };
    finish_lossless(input, pages, Some(why))
}

/// The lossy result with no checks at all (for looking at what a preset does; the real path is [`compress_pdf`]).
#[doc(hidden)]
pub fn lossy_unchecked(input: &[u8], preset: Preset) -> Result<Vec<u8>> {
    let (mut pdf, pages) = open(input)?.map_err(Error::new)?;
    recompress_images(&mut pdf, preset.params(), pages)?;
    save(&mut pdf)
}

/// PSNR of every page of two files that have the same pages, at [`CHECK_DPI`] (for looking at what a preset does).
#[doc(hidden)]
pub fn page_psnrs(a: &[u8], b: &[u8]) -> Result<Vec<f64>> {
    let (da, db) = (Document::from_bytes(a, "application/pdf").map_err(|e| Error::ctx("a", e))?, Document::from_bytes(b, "application/pdf").map_err(|e| Error::ctx("b", e))?);
    let n = da.page_count().map_err(|e| Error::ctx("a", e))?;
    let mut v = Vec::new();
    for p in 0..n {
        let (x, y) = (render(&da, p).map_err(|e| Error::ctx("a", e))?, render(&db, p).map_err(|e| Error::ctx("b", e))?);
        v.push(psnr(x.samples(), y.samples()));
    }
    Ok(v)
}

/// Open the PDF for rewriting: Err(reason) for the files that are left alone (encrypted, signed, no pages).
fn open(input: &[u8]) -> Result<std::result::Result<(PdfDocument, i32), String>> {
    let ctx = |what: &'static str| move |e: mupdf::Error| Error::ctx(what, e);
    let doc = Document::from_bytes(input, "application/pdf").map_err(ctx("opening the PDF"))?;
    if doc.needs_password().map_err(ctx("opening the PDF"))? {
        return Ok(Err("the PDF is encrypted".into()));
    }
    let pdf = PdfDocument::try_from(doc).map_err(ctx("reading the PDF"))?;
    if is_signed(&pdf) {
        return Ok(Err("the PDF is digitally signed (changing it would break the signature)".into()));
    }
    let pages = pdf.page_count().map_err(ctx("counting pages"))?;
    if pages <= 0 {
        return Ok(Err("the PDF has no pages".into()));
    }
    Ok(Ok((pdf, pages)))
}

/// Save with garbage collection, de-duplication, deflate and object streams, after the flate streams are packed harder.
fn save(pdf: &mut PdfDocument) -> Result<Vec<u8>> {
    let count = pdf.count_objects().map_err(|e| Error::ctx("reading the PDF", e))? as i32;
    for num in 1..count {
        if let Ok(mut obj) = pdf.new_indirect(num, 0) {
            let _ = repack_flate(&mut obj);
        }
    }
    let mut out = Vec::new();
    pdf.write_to_with_options(&mut out, write_options()).map_err(|e| Error::ctx("saving the compressed PDF", e))?;
    Ok(out)
}

/// Streams are packed harder before saving. A stream stored as plain deflate is inflated and deflated again at the best level; a stream
/// stored with no filter at all (XMP metadata, say, which MuPDF leaves as it is) is deflated. Either is kept only when clearly smaller.
/// What the reader sees does not change, so the pages cannot.
fn repack_flate(obj: &mut PdfObject) -> Option<()> {
    use std::io::{Read, Write};
    if !obj.is_stream().ok()? {
        return None;
    }
    if matches!(get(obj, "Type").and_then(|t| name(&t)).as_deref(), Some("XRef") | Some("ObjStm")) {
        return None;
    }
    let fl = filters(obj);
    let (plain, was_flate) = match fl.as_slice() {
        [f] if f == "FlateDecode" || f == "Fl" => {
            let raw = obj.read_raw_stream().ok()?;
            let mut plain = Vec::new();
            flate2::read::ZlibDecoder::new(&raw[..]).take(1 << 30).read_to_end(&mut plain).ok()?;
            (plain, Some(raw.len()))
        }
        // uncompressed pictures are MuPDF's to deflate (it does it at the save)
        [] if get(obj, "Subtype").and_then(|t| name(&t)).as_deref() != Some("Image") && get(obj, "DecodeParms").is_none() => (obj.read_raw_stream().ok()?, None),
        _ => return None,
    };
    let before = was_flate.unwrap_or(plain.len());
    if before < 256 {
        return None;
    }
    let mut enc = flate2::write::ZlibEncoder::new(Vec::with_capacity(before), flate2::Compression::best());
    enc.write_all(&plain).ok()?;
    let packed = enc.finish().ok()?;
    if (packed.len() as f64) < before as f64 * 0.98 {
        obj.write_raw_stream_buffer(&Buffer::from_bytes(&packed).ok()?).ok()?;
        if was_flate.is_none() {
            obj.dict_put("Filter", PdfObject::new_name("FlateDecode").ok()?).ok()?;
        }
    }
    Some(())
}

/// The lossless result for `input`, checked: smaller by [`MIN_GAIN`] and rendering identically. `fell_back` is why a lossy attempt was dropped.
fn finish_lossless(input: &[u8], pages: i32, fell_back: Option<String>) -> Result<Tried> {
    let (mut pdf, _) = open(input)?.map_err(Error::new)?;
    let out = save(&mut pdf)?;
    drop(pdf);
    let with = |w: String| match &fell_back {
        Some(f) => format!("{f}; {w}"),
        None => w,
    };
    if (out.len() as f64) > input.len() as f64 * (1.0 - MIN_GAIN) {
        return Ok(Tried::Kept(with(format!("not at least {}% smaller ({} to {} bytes)", (MIN_GAIN * 100.0) as u32, input.len(), out.len())), None));
    }
    match check_pages(input, &out, pages)? {
        Ok(p) if p >= PSNR_IDENTICAL => Ok(Tried::Done { out, psnr: p, note: fell_back.map(|f| format!("{f}; pictures kept as they were")) }),
        Ok(p) => Ok(Tried::Kept(with(format!("lossless output did not render identically (PSNR {p:.1} dB)")), Some(p))),
        Err(why) => Ok(Tried::Kept(with(why), None)),
    }
}

/// Garbage collection with de-duplication, deflate for streams, object streams.
fn write_options() -> PdfWriteOptions {
    use mupdf_sys::pdf_write_options;
    let mut o = PdfWriteOptions::default();
    o.set_garbage_level(3).set_compress(true).set_compress_images(true).set_compress_fonts(true);
    // The mupdf crate has no setter for object streams. The options are one C struct in a one-field wrapper; the layout is
    // checked here and the effect (an /ObjStm in the output) is checked by a test.
    assert_eq!(std::mem::size_of::<PdfWriteOptions>(), std::mem::size_of::<pdf_write_options>());
    // SAFETY: PdfWriteOptions is `struct { inner: pdf_write_options }`, Copy, same size (asserted above).
    unsafe {
        let mut raw: pdf_write_options = std::mem::transmute_copy(&o);
        raw.do_use_objstms = 1;
        std::mem::transmute_copy(&raw)
    }
}

fn is_signed(pdf: &PdfDocument) -> bool {
    let sig_flags = || -> Option<i32> {
        let root = pdf.catalog().ok()?;
        let form = get(&root, "AcroForm")?;
        get(&form, "SigFlags")?.as_int().ok()
    };
    sig_flags().is_some_and(|f| f != 0)
}

// ---- the quality check

fn sample_pages(n: i32) -> Vec<i32> {
    let n = n.max(1) as usize;
    let mut v: Vec<i32> = if n <= CHECK_PAGES { (0..n as i32).collect() } else { (0..CHECK_PAGES).map(|k| ((k * (n - 1) + (CHECK_PAGES - 1) / 2) / (CHECK_PAGES - 1)) as i32).collect() };
    v.dedup();
    v
}

fn render(doc: &Document, page: i32) -> std::result::Result<mupdf::Pixmap, mupdf::Error> {
    let s = CHECK_DPI / 72.0;
    doc.load_page(page)?.to_pixmap(&Matrix::new_scale(s, s), &Colorspace::device_rgb(), false, true)
}

/// PSNR in dB between two renders of the same size ([`PSNR_IDENTICAL`] when equal).
pub fn psnr(a: &[u8], b: &[u8]) -> f64 {
    let mut se = 0f64;
    for (x, y) in a.iter().zip(b) {
        let d = *x as f64 - *y as f64;
        se += d * d;
    }
    if se == 0.0 {
        return PSNR_IDENTICAL;
    }
    let mse = se / a.len().max(1) as f64;
    (10.0 * (255.0f64 * 255.0 / mse).log10()).min(PSNR_IDENTICAL - 0.01)
}

/// Render a sample of pages of both files; the lowest PSNR, or the reason the output cannot be trusted.
fn check_pages(before: &[u8], after: &[u8], pages: i32) -> Result<std::result::Result<f64, String>> {
    let a = Document::from_bytes(before, "application/pdf").map_err(|e| Error::ctx("checking the pages", e))?;
    let b = match Document::from_bytes(after, "application/pdf") {
        Ok(b) => b,
        Err(e) => return Ok(Err(format!("the compressed file does not open ({e})"))),
    };
    if b.page_count().unwrap_or(-1) != pages {
        return Ok(Err("the compressed file has a different number of pages".into()));
    }
    let mut min = PSNR_IDENTICAL;
    let mut checked = 0;
    for p in sample_pages(pages) {
        let Ok(pa) = render(&a, p) else { continue }; // a page the original cannot draw is not a measure
        let pb = match render(&b, p) {
            Ok(x) => x,
            Err(e) => return Ok(Err(format!("page {} does not draw in the compressed file ({e})", p + 1))),
        };
        if pa.width() != pb.width() || pa.height() != pb.height() || pa.n() != pb.n() {
            return Ok(Err(format!("page {} changed size", p + 1)));
        }
        min = min.min(psnr(pa.samples(), pb.samples()));
        checked += 1;
    }
    if checked == 0 {
        return Ok(Err("no page could be drawn to check the result".into()));
    }
    Ok(Ok(min))
}

// ---- images

/// A dictionary entry with indirect references followed.
fn get(o: &PdfObject, key: &str) -> Option<PdfObject> {
    let v = o.get_dict(key).ok()??;
    v.resolve().ok()?.or(Some(v))
}

fn name(o: &PdfObject) -> Option<String> {
    o.as_name().ok().map(|b| String::from_utf8_lossy(&b).into_owned())
}

fn int(o: &PdfObject, key: &str) -> Option<i64> {
    get(o, key)?.as_int().ok().map(i64::from)
}

fn filters(o: &PdfObject) -> Vec<String> {
    match get(o, "Filter") {
        None => vec![],
        Some(f) if f.is_array().unwrap_or(false) => (0..f.len().unwrap_or(0)).filter_map(|i| f.get_array(i as i32).ok().flatten()).filter_map(|x| name(&x.resolve().ok().flatten().unwrap_or(x))).collect(),
        Some(f) => name(&f).into_iter().collect(),
    }
}

/// Components of a color space we can recompress as plain gray or RGB: 1 or 3, else None (CMYK, Indexed, Lab, separation...).
fn components(cs: &PdfObject) -> Option<u8> {
    if cs.is_name().unwrap_or(false) {
        return match name(cs)?.as_str() {
            "DeviceGray" | "G" | "CalGray" => Some(1),
            "DeviceRGB" | "RGB" | "CalRGB" => Some(3),
            _ => None,
        };
    }
    if cs.is_array().unwrap_or(false) {
        let first = cs.get_array(0).ok()??;
        let first = first.resolve().ok().flatten().unwrap_or(first);
        return match name(&first)?.as_str() {
            "CalGray" => Some(1),
            "CalRGB" => Some(3),
            "ICCBased" => {
                let s = cs.get_array(1).ok()??;
                let n = int(&s, "N")?;
                (n == 1 || n == 3).then_some(n as u8)
            }
            _ => None,
        };
    }
    None
}

/// How big the page draws each image: the lowest resolution in pixels per inch over all its placements, by object number.
fn placements(pdf: &PdfDocument, pages: i32) -> HashMap<i32, f32> {
    #[derive(Default)]
    struct Seen(Vec<(u32, u32, f32)>);
    impl NativeDevice for Seen {
        fn fill_image(&mut self, img: &Image, cmt: Matrix, _alpha: f32, _cp: ColorParams) {
            let w_in = (cmt.a.hypot(cmt.b)) / 72.0;
            let h_in = (cmt.c.hypot(cmt.d)) / 72.0;
            if w_in > 0.0 && h_in > 0.0 {
                self.0.push((img.width(), img.height(), (img.width() as f32 / w_in).min(img.height() as f32 / h_in)));
            }
        }
    }
    let mut out: HashMap<i32, f32> = HashMap::new();
    for p in 0..pages {
        let Ok(page_obj) = pdf.find_page(p) else { continue };
        let Ok(Some(res)) = page_obj.get_dict_inheritable("Resources") else { continue };
        let Some(res) = res.resolve().ok().flatten().or(Some(res)) else { continue };
        let Some(xo) = get(&res, "XObject") else { continue };
        // (object number, width, height) of the images this page can draw
        let mut here: Vec<(i32, u32, u32)> = Vec::new();
        for i in 0..xo.dict_len().unwrap_or(0) {
            let Ok(Some(v)) = xo.get_dict_val(i as i32) else { continue };
            let Ok(num) = v.as_indirect() else { continue };
            let Some(obj) = v.resolve().ok().flatten() else { continue };
            if get(&obj, "Subtype").and_then(|s| name(&s)).as_deref() == Some("Image") {
                if let (Some(w), Some(h)) = (int(&obj, "Width"), int(&obj, "Height")) {
                    here.push((num, w as u32, h as u32));
                }
            }
        }
        if here.is_empty() {
            continue;
        }
        let Ok(page) = pdf.load_page(p) else { continue };
        let seen = Rc::new(RefCell::new(Seen::default()));
        let Ok(dev) = Device::from_native(seen.clone()) else { continue };
        if page.run_contents(&dev, &Matrix::IDENTITY).is_err() {
            continue;
        }
        for (w, h, dpi) in seen.borrow().0.iter() {
            for (num, ow, oh) in &here {
                if ow == w && oh == h {
                    let e = out.entry(*num).or_insert(*dpi);
                    *e = e.min(*dpi);
                }
            }
        }
    }
    out
}

fn recompress_images(pdf: &mut PdfDocument, pp: PresetParams, pages: i32) -> Result<()> {
    let dpis = placements(pdf, pages);
    let count = pdf.count_objects().map_err(|e| Error::ctx("reading the PDF", e))? as i32;
    for num in 1..count {
        let Ok(mut obj) = pdf.new_indirect(num, 0) else { continue };
        // Objects that are missing or damaged are skipped, never an error for the whole file.
        if let Err(why) = recompress_one(&mut obj, dpis.get(&num).copied(), pp) {
            if std::env::var_os("CACHE_COMPRESS_TRACE").is_some() {
                eprintln!("image {num}: left alone ({why})");
            }
        }
    }
    Ok(())
}

/// Recompress one image object when it is a plain 8-bit gray or RGB image and the result is clearly smaller.
fn recompress_one(obj: &mut PdfObject, dpi: Option<f32>, pp: PresetParams) -> std::result::Result<(), &'static str> {
    if !obj.is_stream().map_err(|_| "x")? || get(obj, "Subtype").and_then(|s| name(&s)).as_deref() != Some("Image") {
        return Err("not an image");
    }
    if get(obj, "ImageMask").and_then(|m| m.as_bool().ok()).unwrap_or(false) || get(obj, "Mask").is_some() || get(obj, "Decode").is_some() {
        return Err("mask or decode");
    }
    if int(obj, "BitsPerComponent").ok_or("no bpc")? != 8 {
        return Err("not 8 bit");
    }
    let n = get(obj, "ColorSpace").as_ref().and_then(components).ok_or("color space")? as usize;
    let (w, h) = (int(obj, "Width").ok_or("no width")? as usize, int(obj, "Height").ok_or("no height")? as usize);
    if w == 0 || h == 0 || w > 60000 || h > 60000 {
        return Err("size");
    }
    let fl = filters(obj);
    let raw_len = obj.read_raw_stream().map_err(|_| "raw")?.len();
    let samples: Vec<u8> = match fl.as_slice() {
        [f] if f == "DCTDecode" || f == "DCT" => {
            let raw = obj.read_raw_stream().map_err(|_| "raw")?;
            let img = Image::from_bytes(&raw).map_err(|_| "jpeg decode")?;
            let px = img.to_pixmap().map_err(|_| "pixmap")?;
            if px.alpha() || px.n() as usize != n || px.width() as usize != w || px.height() as usize != h {
                return Err("decoded shape differs");
            }
            let stride = px.stride() as usize;
            let s = px.samples();
            let mut v = Vec::with_capacity(w * h * n);
            for y in 0..h {
                v.extend_from_slice(s.get(y * stride..y * stride + w * n).ok_or("stride")?);
            }
            v
        }
        [] | [_] if fl.is_empty() || matches!(fl[0].as_str(), "FlateDecode" | "Fl" | "LZWDecode" | "LZW") => {
            let mut v = obj.read_stream().map_err(|_| "inflate")?;
            // Some PDFs carry more rows than /Height says; MuPDF draws the first Height rows, and so do we.
            if v.len() < w * h * n {
                return Err("stream shorter than the image");
            }
            v.truncate(w * h * n);
            if looks_synthetic(&v, n) {
                return Err("few colors");
            }
            v
        }
        _ => return Err("filter"),
    };
    // downsample to the preset's resolution when the page draws the image finer than the threshold
    let (data, nw, nh) = match dpi {
        Some(d) if d > pp.threshold_dpi => {
            let f = pp.target_dpi / d;
            let (nw, nh) = (((w as f32 * f).round() as usize).max(1), ((h as f32 * f).round() as usize).max(1));
            if nw < w && nh < h {
                (resize_box(&samples, w, h, n, nw, nh), nw, nh)
            } else {
                (samples, w, h)
            }
        }
        _ => (samples, w, h),
    };
    let jpeg = encode_jpeg(&data, nw, nh, n, pp).ok_or("encode")?;
    if jpeg.len() as f64 > raw_len as f64 * IMAGE_KEEP_RATIO {
        return Err("not smaller");
    }
    let buf = Buffer::from_bytes(&jpeg).map_err(|_| "buf")?;
    obj.write_raw_stream_buffer(&buf).map_err(|_| "write")?;
    obj.dict_put("Filter", PdfObject::new_name("DCTDecode").map_err(|_| "n")?).map_err(|_| "put")?;
    let _ = obj.dict_delete("DecodeParms");
    let _ = obj.dict_delete("DP");
    for (k, v) in [("Width", nw as i32), ("Height", nh as i32), ("BitsPerComponent", 8)] {
        obj.dict_put(k, PdfObject::new_int(v).map_err(|_| "n")?).map_err(|_| "put")?;
    }
    Ok(())
}

/// Drawings and diagrams stored losslessly (a handful of gray levels, or at most 256 colors) are left alone: JPEG rings around their edges.
fn looks_synthetic(v: &[u8], n: usize) -> bool {
    let limit = if n == 1 { 8 } else { 256 };
    let mut seen: HashSet<u32> = HashSet::new();
    for px in v.chunks_exact(n).step_by(7) {
        seen.insert(px.iter().fold(0u32, |a, b| (a << 8) | *b as u32));
        if seen.len() > limit {
            return false;
        }
    }
    true
}

/// Area-average resize (each output pixel averages the input pixels it covers).
pub fn resize_box(src: &[u8], w: usize, h: usize, n: usize, nw: usize, nh: usize) -> Vec<u8> {
    // horizontal pass into f32 rows, then vertical
    let mut tmp = vec![0f32; nw * h * n];
    for y in 0..h {
        for x in 0..nw {
            let (x0, x1) = (x as f32 * w as f32 / nw as f32, (x + 1) as f32 * w as f32 / nw as f32);
            let (i0, i1) = (x0.floor() as usize, (x1.ceil() as usize).min(w));
            for c in 0..n {
                let (mut acc, mut wt) = (0f32, 0f32);
                for i in i0..i1 {
                    let cov = (x1.min((i + 1) as f32) - x0.max(i as f32)).max(0.0);
                    acc += cov * src[(y * w + i) * n + c] as f32;
                    wt += cov;
                }
                tmp[(y * nw + x) * n + c] = if wt > 0.0 { acc / wt } else { 0.0 };
            }
        }
    }
    let mut out = vec![0u8; nw * nh * n];
    for y in 0..nh {
        let (y0, y1) = (y as f32 * h as f32 / nh as f32, (y + 1) as f32 * h as f32 / nh as f32);
        let (j0, j1) = (y0.floor() as usize, (y1.ceil() as usize).min(h));
        for x in 0..nw {
            for c in 0..n {
                let (mut acc, mut wt) = (0f32, 0f32);
                for j in j0..j1 {
                    let cov = (y1.min((j + 1) as f32) - y0.max(j as f32)).max(0.0);
                    acc += cov * tmp[(j * nw + x) * n + c];
                    wt += cov;
                }
                out[(y * nw + x) * n + c] = if wt > 0.0 { (acc / wt).round().clamp(0.0, 255.0) as u8 } else { 0 };
            }
        }
    }
    out
}

fn encode_jpeg(data: &[u8], w: usize, h: usize, n: usize, pp: PresetParams) -> Option<Vec<u8>> {
    use jpeg_encoder::{ColorType, Encoder, SamplingFactor};
    if w > 65535 || h > 65535 {
        return None;
    }
    let mut out = Vec::new();
    let mut enc = Encoder::new(&mut out, pp.quality);
    enc.set_optimized_huffman_tables(true);
    if n == 3 {
        enc.set_sampling_factor(if pp.chroma_half { SamplingFactor::F_2_2 } else { SamplingFactor::F_2_1 });
    }
    enc.encode(data, w as u16, h as u16, if n == 3 { ColorType::Rgb } else { ColorType::Luma }).ok()?;
    Some(out)
}
