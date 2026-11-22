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
use std::sync::{Arc, Condvar, Mutex, Once, PoisonError};

type Handle = *mut c_void;

/// `FPDF_GetLastError` for a password-protected file.
const ERR_PASSWORD: c_ulong = 4;
/// `FPDF_ANNOT`: draw annotations too.
const RENDER_ANNOT: c_int = 0x01;
/// The largest page image, in pixels (a 300 dpi A3 page is about 17 million): a bigger page is drawn at a lower resolution.
const MAX_PIXELS: f64 = 40_000_000.0;

/// The process's one PDFium lock. PDFium is not thread-safe, so every caller holds this around each call (or each page's worth of
/// calls: one page's text, one page drawn), never across anything that waits for something else: no await, no callback into Dart.
///
/// Ownership is per ACQUISITION: `acquire` hands back a token and only `release(token)` of that token lets go. It is not tied to an OS
/// thread: an isolate that is killed while it holds the lock leaves the lock held (its `finally` never runs, the kill lands when the
/// thread's native call returns to Dart), the dead isolate's thread goes on to run other isolates, and they must not inherit the hold.
/// An acquisition also names its OWNER (a number the acquirer chooses, one per isolate): when the owner dies, whoever notices
/// (the spawner's exit listener, or the NativeFinalizer attached to the owner's object when its isolate group shuts down) calls
/// `drop_owner` and the lock is released at once. Only as a last backstop, a hold longer than [`backstop`] minutes is taken away,
/// with a loud message. A live but slow holder (a throttled phone can take many seconds in one call) keeps it: two callers in PDFium is
/// the corruption the lock prevents.
///
/// pdfrx's worker takes the same lock around each of its PDFium calls, through [`lock_functions`] (third_party/pdfrx_engine/PATCH.md),
/// so the viewer and the core never run PDFium at the same moment.
struct Holder {
    token: u64,
    owner: u64,
    since: std::time::Instant,
}

#[derive(Default)]
struct LockState {
    holder: Option<Holder>,
    next_token: u64,
    backstop_releases: u64,
    last_backstop: Option<String>,
}

struct PdfiumLock {
    state: Mutex<LockState>,
    free: Condvar,
    /// How long a hold may last before the backstop takes it away, in milliseconds.
    backstop_ms: std::sync::atomic::AtomicU64,
}

/// The owner of the core's own acquisitions (its threads are never killed: only its own threads use it).
const CORE_OWNER: u64 = 1;

/// The backstop: a hold this long is taken away. Minutes, not seconds: nothing that is alive holds PDFium that long.
const BACKSTOP_MS: u64 = 5 * 60 * 1000;

static PDFIUM: PdfiumLock = PdfiumLock {
    state: Mutex::new(LockState { holder: None, next_token: 0, backstop_releases: 0, last_backstop: None }),
    free: Condvar::new(),
    backstop_ms: std::sync::atomic::AtomicU64::new(BACKSTOP_MS),
};

impl PdfiumLock {
    fn guard(&self) -> std::sync::MutexGuard<'_, LockState> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Takes the lock for `owner`, waiting for it; the token of this acquisition. Waits at most `limit` when given (`None` back).
    fn acquire_for(&self, owner: u64, limit: Option<std::time::Duration>) -> Option<u64> {
        let deadline = limit.map(|d| std::time::Instant::now() + d);
        let mut g = self.guard();
        loop {
            let backstop = std::time::Duration::from_millis(self.backstop_ms.load(std::sync::atomic::Ordering::Relaxed));
            match &g.holder {
                None => {
                    g.next_token += 1;
                    let token = g.next_token;
                    g.holder = Some(Holder { token, owner, since: std::time::Instant::now() });
                    return Some(token);
                }
                Some(h) if h.since.elapsed() >= backstop => {
                    let msg = format!(
                        "the PDFium lock was held by owner {} for {:.0} s: taken away (its holder is gone or stuck; a live holder never keeps PDFium this long)",
                        h.owner,
                        h.since.elapsed().as_secs_f64()
                    );
                    eprintln!("cache: {msg}");
                    g.backstop_releases += 1;
                    g.last_backstop = Some(msg);
                    g.holder = None;
                }
                Some(h) => {
                    let mut wait = backstop.saturating_sub(h.since.elapsed()).min(std::time::Duration::from_secs(1));
                    if let Some(d) = deadline {
                        let now = std::time::Instant::now();
                        if now >= d {
                            return None;
                        }
                        wait = wait.min(d - now);
                    }
                    g = self.free.wait_timeout(g, wait).unwrap_or_else(PoisonError::into_inner).0;
                }
            }
        }
    }

    fn acquire(&self, owner: u64) -> u64 {
        self.acquire_for(owner, None).unwrap_or(0)
    }

    /// Lets go of the acquisition `token`, when it is still the one held (a token the backstop took away does nothing).
    fn release(&self, token: u64) {
        let mut g = self.guard();
        if g.holder.as_ref().is_some_and(|h| h.token == token) {
            g.holder = None;
            self.free.notify_all();
        }
    }

    /// The owner is gone: lets go of its hold, if it has one.
    fn drop_owner(&self, owner: u64) {
        let mut g = self.guard();
        if g.holder.as_ref().is_some_and(|h| h.owner == owner) {
            g.holder = None;
            self.free.notify_all();
        }
    }
}

thread_local! {
    /// The core's own nesting on this thread: (depth, token). A call made while this thread already holds the lock for the core does not
    /// wait for itself.
    static CORE_HOLD: std::cell::Cell<(usize, u64)> = const { std::cell::Cell::new((0, 0)) };
}

struct Guard;

impl Drop for Guard {
    fn drop(&mut self) {
        CORE_HOLD.with(|c| {
            let (depth, token) = c.get();
            if depth <= 1 {
                c.set((0, 0));
                PDFIUM.release(token);
            } else {
                c.set((depth - 1, token));
            }
        });
    }
}

fn lock() -> Guard {
    CORE_HOLD.with(|c| {
        let (depth, token) = c.get();
        if depth > 0 {
            c.set((depth + 1, token));
        } else {
            c.set((1, PDFIUM.acquire(CORE_OWNER)));
        }
    });
    Guard
}

extern "C" fn lock_acquire_c(owner: u64) -> u64 {
    PDFIUM.acquire(owner)
}

extern "C" fn lock_release_c(token: u64) {
    PDFIUM.release(token);
}

extern "C" fn lock_drop_owner_c(owner: u64) {
    PDFIUM.drop_owner(owner);
}

/// For `NativeFinalizer`: the pointer argument is the owner's number.
extern "C" fn lock_finalize_c(owner: *mut c_void) {
    PDFIUM.drop_owner(owner as usize as u64);
}

/// The addresses of the lock's C functions, for pdfrx's worker, which takes the same lock around each of its PDFium calls:
/// `acquire(owner: u64) -> u64 token` (waits), `release(token: u64)`, `drop_owner(owner: u64)` and `finalize(owner as pointer)` (the
/// callback of a `NativeFinalizer`). They live as long as the library does.
pub struct LockFunctions {
    pub acquire: usize,
    pub release: usize,
    pub drop_owner: usize,
    pub finalize: usize,
}

pub fn lock_functions() -> LockFunctions {
    LockFunctions {
        acquire: lock_acquire_c as extern "C" fn(u64) -> u64 as usize,
        release: lock_release_c as extern "C" fn(u64) as usize,
        drop_owner: lock_drop_owner_c as extern "C" fn(u64) as usize,
        finalize: lock_finalize_c as extern "C" fn(*mut c_void) as usize,
    }
}

/// Whether the lock is held now, by whom and for how long, and what the backstop has done (for the app's log).
pub fn lock_status() -> serde_json::Value {
    let g = PDFIUM.guard();
    serde_json::json!({
        "held": g.holder.is_some(),
        "owner": g.holder.as_ref().map(|h| h.owner),
        "held_ms": g.holder.as_ref().map(|h| h.since.elapsed().as_millis() as u64),
        "backstop_ms": PDFIUM.backstop_ms.load(std::sync::atomic::Ordering::Relaxed),
        "backstop_releases": g.backstop_releases,
        "last_backstop": g.last_backstop,
    })
}

/// The lock for the tests of its rules (see the tests below): an acquisition with an owner, and the backstop's length.
#[doc(hidden)]
pub mod lock_for_tests {
    pub fn acquire(owner: u64, limit_ms: u64) -> Option<u64> {
        super::PDFIUM.acquire_for(owner, Some(std::time::Duration::from_millis(limit_ms)))
    }
    pub fn release(token: u64) {
        super::PDFIUM.release(token);
    }
    pub fn drop_owner(owner: u64) {
        super::PDFIUM.drop_owner(owner);
    }
    pub fn set_backstop_ms(ms: u64) {
        super::PDFIUM.backstop_ms.store(ms, std::sync::atomic::Ordering::Relaxed);
    }
    pub fn status() -> serde_json::Value {
        super::lock_status()
    }
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
        {
            let _g = lock();
            // SAFETY: FPDF_InitLibrary takes no arguments; calling it again when the host already did is allowed.
            unsafe { init() };
        }
        // the one font mapper of the process, whichever engine or isolate reaches PDFium first
        install_font_mapper(&l._lib, path);
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

// ---------------------------------------------------------------------------------------------------------
// The process's one font mapper

/// `FPDF_SYSFONTINFO` (fpdf_sysfontinfo.h).
#[repr(C)]
struct SysFontInfo {
    version: c_int,
    release: Option<unsafe extern "C" fn(*mut SysFontInfo)>,
    enum_fonts: Option<unsafe extern "C" fn(*mut SysFontInfo, *mut c_void)>,
    map_font: Option<unsafe extern "C" fn(*mut SysFontInfo, c_int, c_int, c_int, c_int, *const c_char, *mut c_int) -> *mut c_void>,
    get_font: Option<unsafe extern "C" fn(*mut SysFontInfo, *const c_char) -> *mut c_void>,
    get_font_data: Option<unsafe extern "C" fn(*mut SysFontInfo, *mut c_void, u32, *mut u8, c_ulong) -> c_ulong>,
    get_face_name: Option<unsafe extern "C" fn(*mut SysFontInfo, *mut c_void, *mut c_char, c_ulong) -> c_ulong>,
    get_font_charset: Option<unsafe extern "C" fn(*mut SysFontInfo, *mut c_void) -> c_int>,
    delete_font: Option<unsafe extern "C" fn(*mut SysFontInfo, *mut c_void)>,
}

struct StaticFontInfo(SysFontInfo);

// SAFETY: the struct is never written after it is made and holds only code addresses.
unsafe impl Sync for StaticFontInfo {}

/// PDFium asks the system for a font it does not find in the PDF: no system font is offered, so PDFium uses its built-in substitutes.
/// This is what the Dart mapper pdfrx used to install answered for every font, since the app gives it no font files.
unsafe extern "C" fn no_font(_: *mut SysFontInfo, _: c_int, _: c_int, _: c_int, _: c_int, _: *const c_char, _: *mut c_int) -> *mut c_void {
    std::ptr::null_mut()
}

unsafe extern "C" fn no_font_data(_: *mut SysFontInfo, _: *mut c_void, _: u32, _: *mut u8, _: c_ulong) -> c_ulong {
    0
}

unsafe extern "C" fn no_face_name(_: *mut SysFontInfo, _: *mut c_void, _: *mut c_char, _: c_ulong) -> c_ulong {
    0
}

unsafe extern "C" fn default_charset(_: *mut SysFontInfo, _: *mut c_void) -> c_int {
    1
}

unsafe extern "C" fn delete_none(_: *mut SysFontInfo, _: *mut c_void) {}

/// The mapper PDFium keeps for the life of the process: static, with plain `extern "C"` functions, so any thread of any isolate or
/// engine may make PDFium look for a font, and it never goes away. (pdfrx's own was Dart callbacks bound to the isolate that started
/// it; a second Flutter engine replaced it and PDFium then called into an isolate it did not belong to, or one that had ended, which
/// the Dart VM answers by aborting the app.) The values are the ones pdfrx's mapper set: version 2, and MapFont, GetFontData,
/// GetFaceName, GetFontCharset and DeleteFont; Release, EnumFonts and GetFont stay unset.
static FONT_INFO: StaticFontInfo = StaticFontInfo(SysFontInfo {
    version: 2,
    release: None,
    enum_fonts: None,
    map_font: Some(no_font),
    get_font: None,
    get_font_data: Some(no_font_data),
    get_face_name: Some(no_face_name),
    get_font_charset: Some(default_charset),
    delete_font: Some(delete_none),
});

static FONTS_ONCE: Once = Once::new();

/// Set when the mapper was handed to PDFium (the library has FPDF_SetSystemFontInfo).
static FONTS_INSTALLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Gives PDFium the process's one font mapper, once. `lib` is the PDFium library the process uses; one more handle on it is kept for
/// the life of the process, so it is never unloaded (which would drop the mapper PDFium holds).
fn install_font_mapper(lib: &Library, path: Option<&str>) {
    FONTS_ONCE.call_once(|| {
        if let Ok(set) = get::<unsafe extern "C" fn(*mut SysFontInfo)>(lib, "FPDF_SetSystemFontInfo") {
            let _g = lock();
            // SAFETY: FONT_INFO is a static with the layout of FPDF_SYSFONTINFO that PDFium keeps a pointer to; it is never changed or freed.
            unsafe { set(std::ptr::addr_of!(FONT_INFO.0).cast_mut()) };
            FONTS_INSTALLED.store(true, std::sync::atomic::Ordering::SeqCst);
        }
        if let Ok((keep, _)) = open_library(path) {
            std::mem::forget(keep);
        }
    });
}

/// Starts PDFium in this process if nothing has and installs the process's font mapper (once). Reports where PDFium was found
/// (`path`, `name` or `process`). Safe to call again, from any thread.
pub fn install_fonts(path: Option<&str>) -> Result<(&'static str, bool)> {
    let (l, from) = Lib::bind(path)?;
    let init: unsafe extern "C" fn() = get(&l._lib, "FPDF_InitLibrary")?;
    {
        let _g = lock();
        // SAFETY: FPDF_InitLibrary takes no arguments; calling it again when the host already did is allowed.
        unsafe { init() };
    }
    install_font_mapper(&l._lib, path);
    Ok((from, FONTS_INSTALLED.load(std::sync::atomic::Ordering::SeqCst)))
}

/// Whether PDFium can be loaded with these settings, and from where (`path`, `name` or `process`). Nothing stays initialised.
pub fn probe(path: Option<&str>) -> Result<&'static str> {
    Lib::bind(path).map(|(_, from)| from)
}

/// Every page of a PDF as the job reads it: the text layer, the printed label and a SHA-256 of the page drawn as a grayscale PNG at
/// `dpi` (a change to how PDFium finds fonts shows in the text's spacing and in the picture). For tests and diagnostics; the job
/// itself never calls it.
pub fn dump(path: Option<String>, pdf: &Path, dpi: u32) -> Result<serde_json::Value> {
    dump_with(path, pdf, dpi, false)
}

/// [`dump`], with `timings`: how long each page's text and drawing took, in milliseconds (the longest single stretch the PDFium lock is
/// held by the core is about one of these), and how long opening the document took.
pub fn dump_with(path: Option<String>, pdf: &Path, dpi: u32, timings: bool) -> Result<serde_json::Value> {
    use sha2::{Digest, Sha256};
    let engine = PdfiumEngine::new(path, None);
    let t0 = std::time::Instant::now();
    let doc = engine.open(pdf)?;
    let open_ms = t0.elapsed().as_secs_f64() * 1000.0;
    let mut pages = Vec::new();
    for i in 0..doc.page_count() {
        let t = std::time::Instant::now();
        let text = doc.page_text(i)?;
        let text_ms = t.elapsed().as_secs_f64() * 1000.0;
        let t = std::time::Instant::now();
        let page = doc.render_gray_png(i, dpi)?;
        let draw_ms = t.elapsed().as_secs_f64() * 1000.0;
        let hex: String = Sha256::digest(&page.png).iter().map(|b| format!("{b:02x}")).collect();
        let mut v = serde_json::json!({"text": text, "label": doc.page_label(i), "png_sha256": hex, "width": page.width, "height": page.height, "dpi": page.dpi});
        if timings {
            v["text_ms"] = text_ms.into();
            v["draw_ms"] = draw_ms.into();
        }
        pages.push(v);
    }
    let mut out = serde_json::json!({"title": doc.title(), "pages": pages});
    if timings {
        out["open_ms"] = open_ms.into();
    }
    Ok(out)
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
        let damaged = |m: String| Error::new(Code::Damaged, m);
        // The PDFium calls (open the page, draw it) are made under the lock; turning the picture to gray and encoding it, which call
        // nothing in PDFium, are not, so another thread's PDFium call is not held up by them. Only the bitmap and the page are
        // released (under the lock again) afterwards.
        let (bmp, p, w, h, scale) = {
            let _g = lock();
            // SAFETY: the page and bitmap are released by the code below; the handles are used by one thread at a time.
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
                (bmp, p, w, h, scale)
            }
        };
        // SAFETY: `bmp` is alive until the destroy below; its buffer is read within `stride * height` bytes.
        let encoded = unsafe {
            let stride = {
                let _g = lock();
                (self.lib.bitmap_stride)(bmp).max(0) as usize
            };
            let buf = {
                let _g = lock();
                (self.lib.bitmap_buffer)(bmp) as *mut u8
            };
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
            if ok { Some(crate::png::encode_gray(w as u32, h as u32, w as usize, std::slice::from_raw_parts(buf, w as usize * h as usize))) } else { None }
        };
        {
            let _g = lock();
            // SAFETY: each is released once.
            unsafe {
                (self.lib.bitmap_destroy)(bmp);
                (self.lib.close_page)(p);
            }
        }
        let png = encoded.ok_or_else(|| damaged(format!("page {} cannot be drawn", page + 1)))?.map_err(damaged)?;
        let actual_dpi = (scale * 72.0).round().max(1.0) as u32;
        Ok(RenderedPage { png, width: w as u32, height: h as u32, dpi: actual_dpi.min(dpi) })
    }
}
