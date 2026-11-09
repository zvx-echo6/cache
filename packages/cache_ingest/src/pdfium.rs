//! PDFium as the job's PDF engine, loaded at run time with `libloading` (the way `cache_embed` loads `cache_llama`): the core links no
//! PDF code. The app already ships PDFium with its PDF viewer; the core finds it by a path the host gives (`engines.pdfium_lib` of the
//! start call), else by the usual library name, else in the process itself (iOS links PDFium into the app).
//!
//! Only the calls the job needs are bound: page count, page text, the metadata title and creation date, page labels and drawing a
//! page. PDFium is not thread-safe, so every call here takes one process-wide lock.

use crate::engine::{PdfDocument, PdfEngine, RenderedPage};
use crate::error::{Code, Error, Result};
use libloading::Library;
use std::ffi::{c_char, c_int, c_ulong, c_void, CString};
use std::path::Path;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};

type Handle = *mut c_void;

/// `FPDF_GetLastError` for a password-protected file.
const ERR_PASSWORD: c_ulong = 4;
/// `FPDF_ANNOT`: draw annotations too.
const RENDER_ANNOT: c_int = 0x01;
/// The largest page image, in pixels (a 300 dpi A3 page is about 17 million): a bigger page is drawn at a lower resolution.
const MAX_PIXELS: f64 = 40_000_000.0;

static PDFIUM_LOCK: Mutex<()> = Mutex::new(());

fn lock() -> MutexGuard<'static, ()> {
    PDFIUM_LOCK.lock().unwrap_or_else(PoisonError::into_inner)
}

struct Lib {
    load_document: unsafe extern "C" fn(*const c_char, *const c_char) -> Handle,
    last_error: unsafe extern "C" fn() -> c_ulong,
    close_document: unsafe extern "C" fn(Handle),
    page_count: unsafe extern "C" fn(Handle) -> c_int,
    load_page: unsafe extern "C" fn(Handle, c_int) -> Handle,
    close_page: unsafe extern "C" fn(Handle),
    page_width: unsafe extern "C" fn(Handle) -> f32,
    page_height: unsafe extern "C" fn(Handle) -> f32,
    text_load: unsafe extern "C" fn(Handle) -> Handle,
    text_close: unsafe extern "C" fn(Handle),
    text_count: unsafe extern "C" fn(Handle) -> c_int,
    text_get: unsafe extern "C" fn(Handle, c_int, c_int, *mut u16) -> c_int,
    meta_text: unsafe extern "C" fn(Handle, *const c_char, *mut c_void, c_ulong) -> c_ulong,
    page_label: unsafe extern "C" fn(Handle, c_int, *mut c_void, c_ulong) -> c_ulong,
    bitmap_create: unsafe extern "C" fn(c_int, c_int, c_int) -> Handle,
    bitmap_fill: unsafe extern "C" fn(Handle, c_int, c_int, c_int, c_int, c_ulong),
    bitmap_buffer: unsafe extern "C" fn(Handle) -> *mut c_void,
    bitmap_stride: unsafe extern "C" fn(Handle) -> c_int,
    bitmap_destroy: unsafe extern "C" fn(Handle),
    render: unsafe extern "C" fn(Handle, Handle, c_int, c_int, c_int, c_int, c_int, c_int),
    // Keeps the library mapped for as long as the function pointers above are used.
    _lib: Library,
}

// SAFETY: the function pointers are plain code addresses; every call goes through the process-wide lock.
unsafe impl Send for Lib {}
unsafe impl Sync for Lib {}

#[cfg(unix)]
fn this_process() -> Option<Library> {
    // PDFium linked into the app itself (iOS)
    Some(libloading::os::unix::Library::this().into())
}

#[cfg(not(unix))]
fn this_process() -> Option<Library> {
    None
}

/// Finds PDFium: the host's path first, then the usual library name, then the process itself. A path that does not load falls back to
/// the others; the error lists everything tried.
fn open_library(path: Option<&str>) -> Result<(Library, &'static str)> {
    let mut tried: Vec<String> = Vec::new();
    if let Some(p) = path.filter(|p| !p.is_empty()) {
        // SAFETY: loading a shared library runs its initialisers; the host chose the path.
        match unsafe { Library::new(p) } {
            Ok(l) => return Ok((l, "path")),
            Err(e) => tried.push(format!("{p}: {e}")),
        }
    }
    for n in ["libpdfium.so", "libpdfium.dylib", "pdfium.dll"] {
        // SAFETY: PDFium's usual library name.
        match unsafe { Library::new(n) } {
            Ok(l) => return Ok((l, "name")),
            Err(e) => tried.push(format!("{n}: {e}")),
        }
    }
    if let Some(l) = this_process() {
        return Ok((l, "process"));
    }
    Err(Error::new(Code::Damaged, format!("PDFium could not be loaded ({})", tried.join("; "))))
}

fn get<T: Copy>(lib: &Library, name: &str) -> Result<T> {
    // SAFETY: the signature `T` is the one in PDFium's public headers (fpdfview.h, fpdf_text.h, fpdf_doc.h).
    let s = unsafe { lib.get::<T>(format!("{name}\0").as_bytes()) }.map_err(|_| Error::new(Code::Damaged, format!("PDFium has no {name}")))?;
    Ok(*s)
}

impl Lib {
    fn load(path: Option<&str>) -> Result<Lib> {
        let (l, _) = Lib::bind(path)?;
        let init: unsafe extern "C" fn() = get(&l._lib, "FPDF_InitLibrary")?;
        let _g = lock();
        // SAFETY: FPDF_InitLibrary takes no arguments; calling it again when the host already did is allowed.
        unsafe { init() };
        Ok(l)
    }

    /// Finds the library and every function the job uses, without initialising PDFium. Returns where it was found.
    fn bind(path: Option<&str>) -> Result<(Lib, &'static str)> {
        let (lib, from) = open_library(path)?;
        let init: unsafe extern "C" fn() = get(&lib, "FPDF_InitLibrary")?;
        let l = Lib {
            load_document: get(&lib, "FPDF_LoadDocument")?,
            last_error: get(&lib, "FPDF_GetLastError")?,
            close_document: get(&lib, "FPDF_CloseDocument")?,
            page_count: get(&lib, "FPDF_GetPageCount")?,
            load_page: get(&lib, "FPDF_LoadPage")?,
            close_page: get(&lib, "FPDF_ClosePage")?,
            page_width: get(&lib, "FPDF_GetPageWidthF")?,
            page_height: get(&lib, "FPDF_GetPageHeightF")?,
            text_load: get(&lib, "FPDFText_LoadPage")?,
            text_close: get(&lib, "FPDFText_ClosePage")?,
            text_count: get(&lib, "FPDFText_CountChars")?,
            text_get: get(&lib, "FPDFText_GetText")?,
            meta_text: get(&lib, "FPDF_GetMetaText")?,
            page_label: get(&lib, "FPDF_GetPageLabel")?,
            bitmap_create: get(&lib, "FPDFBitmap_Create")?,
            bitmap_fill: get(&lib, "FPDFBitmap_FillRect")?,
            bitmap_buffer: get(&lib, "FPDFBitmap_GetBuffer")?,
            bitmap_stride: get(&lib, "FPDFBitmap_GetStride")?,
            bitmap_destroy: get(&lib, "FPDFBitmap_Destroy")?,
            render: get(&lib, "FPDF_RenderPageBitmap")?,
            _lib: lib,
        };
        let _ = init;
        Ok((l, from))
    }
}

/// Whether PDFium can be loaded with these settings, and from where (`path`, `name` or `process`). Nothing stays initialised.
pub fn probe(path: Option<&str>) -> Result<&'static str> {
    Lib::bind(path).map(|(_, from)| from)
}

/// PDFium, found when the first PDF is opened.
pub struct PdfiumEngine {
    path: Option<String>,
    version: String,
    lib: Mutex<Option<Arc<Lib>>>,
}

impl PdfiumEngine {
    /// `path`: the PDFium library the host ships (`None`: the usual name, then this process). `version`: recorded in the pack's
    /// `extractor.version`.
    pub fn new(path: Option<String>, version: Option<String>) -> PdfiumEngine {
        PdfiumEngine { path, version: version.filter(|v| !v.is_empty()).unwrap_or_else(|| "unknown".to_string()), lib: Mutex::new(None) }
    }

    fn lib(&self) -> Result<Arc<Lib>> {
        let mut g = self.lib.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(l) = g.as_ref() {
            return Ok(l.clone());
        }
        let l = Arc::new(Lib::load(self.path.as_deref())?);
        *g = Some(l.clone());
        Ok(l)
    }
}

impl PdfEngine for PdfiumEngine {
    fn name(&self) -> String {
        "pdfium".to_string()
    }

    fn version(&self) -> String {
        self.version.clone()
    }

    fn open(&self, path: &Path) -> Result<Box<dyn PdfDocument>> {
        let lib = self.lib()?;
        let cpath = CString::new(path.to_string_lossy().as_bytes()).map_err(|_| Error::new(Code::Damaged, "the path has a NUL byte"))?;
        let _g = lock();
        // SAFETY: `cpath` is a valid NUL-terminated path; a NULL password means none.
        let doc = unsafe { (lib.load_document)(cpath.as_ptr(), std::ptr::null()) };
        if doc.is_null() {
            // SAFETY: no arguments.
            let code = unsafe { (lib.last_error)() };
            return Err(if code == ERR_PASSWORD {
                Error::new(Code::Locked, format!("{} is password-protected", path.display()))
            } else {
                Error::new(Code::Damaged, format!("PDFium could not open {} (error {code})", path.display()))
            });
        }
        Ok(Box::new(PdfiumDoc { lib, doc }))
    }
}

struct PdfiumDoc {
    lib: Arc<Lib>,
    doc: Handle,
}

// SAFETY: the handle is used only while the process-wide PDFium lock is held.
unsafe impl Send for PdfiumDoc {}

impl Drop for PdfiumDoc {
    fn drop(&mut self) {
        let _g = lock();
        // SAFETY: `doc` came from FPDF_LoadDocument and is closed once.
        unsafe { (self.lib.close_document)(self.doc) };
    }
}

/// UTF-16LE bytes (with a terminator) to text.
fn utf16_bytes(buf: &[u8]) -> String {
    let units: Vec<u16> = buf.as_chunks::<2>().0.iter().map(|c| u16::from_le_bytes(*c)).take_while(|u| *u != 0).collect();
    String::from_utf16_lossy(&units)
}

impl PdfiumDoc {
    fn meta(&self, tag: &str) -> Option<String> {
        let ctag = CString::new(tag).ok()?;
        let _g = lock();
        // SAFETY: a NULL buffer asks for the size; then the buffer has that many bytes.
        let need = unsafe { (self.lib.meta_text)(self.doc, ctag.as_ptr(), std::ptr::null_mut(), 0) } as usize;
        if need <= 2 {
            return None;
        }
        let mut buf = vec![0u8; need];
        // SAFETY: `buf` holds `need` bytes.
        let got = unsafe { (self.lib.meta_text)(self.doc, ctag.as_ptr(), buf.as_mut_ptr().cast(), need as c_ulong) } as usize;
        let t = utf16_bytes(&buf[..got.min(need)]);
        let t = t.trim().to_string();
        (!t.is_empty()).then_some(t)
    }
}

impl PdfDocument for PdfiumDoc {
    fn page_count(&self) -> usize {
        let _g = lock();
        // SAFETY: `doc` is open.
        unsafe { (self.lib.page_count)(self.doc) }.max(0) as usize
    }

    fn title(&self) -> Option<String> {
        self.meta("Title")
    }

    fn year(&self) -> Option<u32> {
        // "D:20180412120000Z": the four digits after "D:"
        let d = self.meta("CreationDate")?;
        let digits: String = d.trim_start_matches("D:").chars().take(4).collect();
        digits.parse::<u32>().ok().filter(|y| (1400..=2100).contains(y))
    }

    fn page_label(&self, page: usize) -> Option<String> {
        let _g = lock();
        // SAFETY: a NULL buffer asks for the size; then the buffer has that many bytes.
        let need = unsafe { (self.lib.page_label)(self.doc, page as c_int, std::ptr::null_mut(), 0) } as usize;
        if need <= 2 {
            return None;
        }
        let mut buf = vec![0u8; need];
        // SAFETY: `buf` holds `need` bytes.
        let got = unsafe { (self.lib.page_label)(self.doc, page as c_int, buf.as_mut_ptr().cast(), need as c_ulong) } as usize;
        let t = utf16_bytes(&buf[..got.min(need)]).trim().to_string();
        (!t.is_empty()).then_some(t)
    }

    fn page_text(&self, page: usize) -> Result<String> {
        let _g = lock();
        // SAFETY: the page and text page are closed before returning; the buffer has one more unit than the characters.
        unsafe {
            let p = (self.lib.load_page)(self.doc, page as c_int);
            if p.is_null() {
                return Err(Error::new(Code::Damaged, format!("page {} cannot be read", page + 1)));
            }
            let tp = (self.lib.text_load)(p);
            if tp.is_null() {
                (self.lib.close_page)(p);
                return Err(Error::new(Code::Damaged, format!("the text of page {} cannot be read", page + 1)));
            }
            let n = (self.lib.text_count)(tp).max(0);
            let mut buf = vec![0u16; n as usize + 1];
            let got = if n > 0 { (self.lib.text_get)(tp, 0, n, buf.as_mut_ptr()) } else { 0 };
            (self.lib.text_close)(tp);
            (self.lib.close_page)(p);
            let len = (got.max(0) as usize).min(buf.len());
            let units: Vec<u16> = buf[..len].iter().copied().take_while(|u| *u != 0).collect();
            Ok(String::from_utf16_lossy(&units))
        }
    }

    fn render_gray_png(&self, page: usize, dpi: u32) -> Result<RenderedPage> {
        let _g = lock();
        let damaged = |m: String| Error::new(Code::Damaged, m);
        // SAFETY: the page and bitmap are released before returning; the bitmap buffer is read within `stride * height` bytes.
        unsafe {
            let p = (self.lib.load_page)(self.doc, page as c_int);
            if p.is_null() {
                return Err(damaged(format!("page {} cannot be read", page + 1)));
            }
            let (pw, ph) = ((self.lib.page_width)(p) as f64, (self.lib.page_height)(p) as f64);
            let mut scale = f64::from(dpi) / 72.0;
            if pw * ph * scale * scale > MAX_PIXELS {
                scale = (MAX_PIXELS / (pw * ph)).sqrt();
            }
            let (w, h) = (((pw * scale).ceil() as c_int).max(1), ((ph * scale).ceil() as c_int).max(1));
            let bmp = (self.lib.bitmap_create)(w, h, 0);
            if bmp.is_null() {
                (self.lib.close_page)(p);
                return Err(damaged(format!("page {} is too large to draw", page + 1)));
            }
            (self.lib.bitmap_fill)(bmp, 0, 0, w, h, 0xFFFF_FFFF as c_ulong);
            (self.lib.render)(bmp, p, 0, 0, w, h, 0, RENDER_ANNOT);
            let stride = (self.lib.bitmap_stride)(bmp).max(0) as usize;
            let buf = (self.lib.bitmap_buffer)(bmp) as *mut u8;
            let ok = !buf.is_null() && stride >= w as usize * 4;
            if ok {
                // BGRx to gray, in place in PDFium's own buffer (no second image in memory): the gray row y goes to y * w, which is
                // never ahead of the pixels still to be read (stride is at least 4 * w).
                let wu = w as usize;
                for y in 0..h as usize {
                    for x in 0..wu {
                        let px = buf.add(y * stride + x * 4);
                        let (b, g, r) = (u32::from(*px), u32::from(*px.add(1)), u32::from(*px.add(2)));
                        *buf.add(y * wu + x) = ((77 * r + 150 * g + 29 * b) >> 8) as u8;
                    }
                }
            }
            let encoded = if ok { Some(crate::png::encode_gray(w as u32, h as u32, w as usize, std::slice::from_raw_parts(buf, w as usize * h as usize))) } else { None };
            (self.lib.bitmap_destroy)(bmp);
            (self.lib.close_page)(p);
            let png = encoded.ok_or_else(|| damaged(format!("page {} cannot be drawn", page + 1)))?.map_err(damaged)?;
            let actual_dpi = (scale * 72.0).round().max(1.0) as u32;
            Ok(RenderedPage { png, width: w as u32, height: h as u32, dpi: actual_dpi.min(dpi) })
        }
    }
}
