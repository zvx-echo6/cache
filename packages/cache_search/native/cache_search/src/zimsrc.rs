//! One opened ZIM file.
//!
//! With libzim built in (the `xapian` feature on Windows and Android) a ZIM has ONE archive: libzim's, opened when a search,
//! a suggestion or a read first needs it, kept while the memory budget allows (`budget.rs`) and closed by it otherwise.
//! Searches, suggestions, `get` and `main_page_path` (that is `cs_read`, `cs_zim_get`, `cs_zim_main_page`) all go through it, and
//! each counts as a use of the archive for the budget's least-recently-used order. `ZimSource::open` reads the ZIM's facts (id,
//! title, language, entry count, index sizes) with the `zim` crate and drops that reader again; nothing of it stays open. The
//! `zim` crate reader is opened again, on demand and kept, only for the Tantivy index build and for a ZIM libzim cannot open;
//! builds without libzim open it at once and read through it as before.

use crate::budget::{archive_cost, Caps, Evict, Profile, ZimBudget};
use crate::error::{Error, ErrorCode, Result};
use crate::zimx::{OpenOpts, XGet, XMain, Zimx};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use zim::{DirectoryEntry, MimeType, Namespace, Target, Zim};

/// Redirect hops followed before giving up.
pub const MAX_REDIRECT_HOPS: u32 = 10;

/// Redirect hops the main page may take (the `zim` crate's own limit for `main_page`).
const MAIN_PAGE_HOPS: u32 = 50;

/// What a ZIM's libzim archive answers to: the budget, its owner id there, the estimated cost and the open options.
#[derive(Clone)]
struct Mem {
    budget: Arc<ZimBudget>,
    id: u64,
    cost: u64,
    opts: OpenOpts,
    caps: Caps,
}

/// The libzim side of one ZIM: the archive while it is open, shared by the source and its prewarm job. The budget closes the
/// archive through `Evict`; a query that already holds it keeps it alive until the query ends.
struct Shared {
    path: PathBuf,
    cur: Mutex<Option<Arc<Zimx>>>,
    /// Serialises opens of this archive (so two queries do not open it twice); `cur` is only ever held briefly.
    opening: Mutex<()>,
    /// libzim could not open the file.
    failed: AtomicBool,
    mem: Mutex<Option<Mem>>,
}

impl Evict for Shared {
    fn close(&self) {
        *self.cur.lock().unwrap_or_else(|e| e.into_inner()) = None;
    }
}

impl Shared {
    fn mem(&self) -> Option<Mem> {
        self.mem.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    fn current(&self) -> Option<Arc<Zimx>> {
        self.cur.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// The open archive for a query, opening it if it is not open. With a budget the archive is kept open when the budget
    /// admits it (closing least recently used ones to make room); when it is over the whole budget the returned handle is the
    /// only owner and the archive closes when the query drops it. `reserve_only` (prewarm): open it only if it fits without
    /// closing anything, else `None`. Also `None` when libzim cannot open the file.
    fn lease(self: &Arc<Self>, reserve_only: bool) -> Option<Arc<Zimx>> {
        if self.failed.load(Ordering::SeqCst) {
            return None;
        }
        let Some(m) = self.mem() else {
            // not under a budget (a standalone source): open once, keep
            let _o = self.opening.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(a) = self.current() {
                return Some(a);
            }
            return match Zimx::open(&self.path) {
                Ok(z) => {
                    let a = Arc::new(z);
                    *self.cur.lock().unwrap_or_else(|e| e.into_inner()) = Some(a.clone());
                    Some(a)
                }
                Err(_) => {
                    self.failed.store(true, Ordering::SeqCst);
                    None
                }
            };
        };
        let who: Weak<dyn Evict> = {
            let a: Arc<dyn Evict> = self.clone();
            Arc::downgrade(&a)
        };
        let kept = if reserve_only { m.budget.try_reserve(m.id, m.cost, who) } else { m.budget.admit(m.id, m.cost, who) };
        if reserve_only && !kept {
            return None;
        }
        if let Some(a) = self.current() {
            return Some(a);
        }
        let _o = self.opening.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(a) = self.current() {
            return Some(a);
        }
        match Zimx::open_with(&self.path, &m.opts) {
            Err(_) => {
                self.failed.store(true, Ordering::SeqCst);
                m.budget.forget(m.id);
                None
            }
            Ok(z) => {
                m.budget.note_open();
                let a = Arc::new(z);
                if kept {
                    *self.cur.lock().unwrap_or_else(|e| e.into_inner()) = Some(a.clone());
                    // another thread's admission may have closed this archive while it was opening: then it is not counted
                    // any more and must not stay open behind the budget's back
                    if !m.budget.is_kept(m.id) {
                        self.close();
                    }
                }
                Some(a)
            }
        }
    }
}

pub struct ZimSource {
    /// The `zim` crate's reader, opened on demand by `zim()`. It serves the Tantivy index build, and the reads of a build
    /// without libzim (`Zimx::AVAILABLE` false), where it is opened at once and kept. With libzim it is not kept open: `open`
    /// reads what it needs from it and drops it, and `get` and `main_page_path` go through libzim's archive (see `x`).
    crate_zim: OnceLock<Zim>,
    /// Serialises the lazy open of `crate_zim`.
    crate_opening: Mutex<()>,
    /// The ZIM's UUID, lowercase hyphenated.
    pub id: String,
    pub path: PathBuf,
    pub title: String,
    pub language: Option<String>,
    /// Directory entries in the file (all namespaces), from the header.
    entries: u64,
    /// The ZIM carries the Xapian full-text index (`X/fulltext/xapian`) / the title index (`X/title/xapian`), and their
    /// sizes in bytes (0 when it has none), read once at open.
    has_ft: bool,
    has_ti: bool,
    ft_bytes: u64,
    ti_bytes: u64,
    /// libzim's view of the same file, opened when a search, a suggestion or a read needs it and closed again by the memory
    /// budget (see `Shared`). It is the one archive of this ZIM: with libzim built in, searches, suggestions, `get` and
    /// `main_page_path` all use it; the `zim` crate reader is only the fallback when libzim cannot open the file.
    x: Arc<Shared>,
    /// Set once a prewarm of the libzim handle has been queued (see `warm_job`).
    warm_queued: AtomicBool,
}

impl Drop for ZimSource {
    fn drop(&mut self) {
        if let Some(m) = self.x.mem() {
            m.budget.forget(m.id);
        }
        self.x.close();
    }
}

/// Sizes in bytes of the ZIM's full-text and title index entries (0 when it has none or they cannot be read).
fn index_sizes(zim: &Zim) -> (u64, u64) {
    fn len_of(c: Option<Option<zim::Content<'_>>>) -> u64 {
        c.flatten().and_then(|c| c.len().ok()).unwrap_or(0) as u64
    }
    (len_of(zim.fulltext_index().ok()), len_of(zim.title_index().ok()))
}

/// Opening libzim on one ZIM and building its searchers, to run on a background thread (see `ZimSource::warm_job`).
pub struct WarmJob {
    x: Arc<Shared>,
    fulltext: bool,
    titles: bool,
    cost: u64,
}

impl WarmJob {
    /// Estimated memory of the archive this job opens: what prewarm planning sorts and sums (`budget::prewarm_plan`).
    pub fn cost(&self) -> u64 {
        self.cost
    }

    pub fn run(self) {
        if let Some(z) = self.x.lease(true) {
            let _ = z.prewarm(self.fulltext, self.titles);
        }
    }
}

/// A parsed `zim:<uuid>/<path>` address.
#[derive(Debug, PartialEq, Eq)]
pub struct ZimAddress {
    /// Lowercase hyphenated UUID.
    pub id: String,
    /// Entry path inside the ZIM, exactly as stored (no percent-decoding).
    pub path: String,
}

/// True for `8-4-4-4-12` hex digits (either case).
pub fn is_uuid(s: &str) -> bool {
    let b = s.as_bytes();
    b.len() == 36
        && b.iter().enumerate().all(|(i, c)| match i {
            8 | 13 | 18 | 23 => *c == b'-',
            _ => c.is_ascii_hexdigit(),
        })
}

/// Parse `zim:<uuid>/<path>`. A malformed address (wrong scheme, bad UUID, empty path) is `bad_json`.
pub fn parse_address(addr: &str) -> Result<ZimAddress> {
    let rest = addr
        .strip_prefix("zim:")
        .ok_or_else(|| Error::bad_json(format!("not a zim address: {addr:?}")))?;
    let (id, path) = rest
        .split_once('/')
        .ok_or_else(|| Error::bad_json(format!("address has no path: {addr:?}")))?;
    if !is_uuid(id) {
        return Err(Error::bad_json(format!("address has a malformed zim id: {addr:?}")));
    }
    if path.is_empty() {
        return Err(Error::bad_json(format!("address has an empty path: {addr:?}")));
    }
    Ok(ZimAddress { id: id.to_ascii_lowercase(), path: path.to_string() })
}

/// Build `zim:<uuid>/<path>`. `%` and `#` in the path are percent-encoded so that the address resolves back
/// to exactly this entry (`#` would otherwise start a fragment, `%` an escape).
pub fn format_address(id: &str, path: &str) -> String {
    let mut s = String::with_capacity(path.len() + 41);
    s.push_str("zim:");
    s.push_str(id);
    s.push('/');
    for c in path.chars() {
        match c {
            '%' => s.push_str("%25"),
            '#' => s.push_str("%23"),
            _ => s.push(c),
        }
    }
    s
}

/// Percent-decode `s` as UTF-8. `None` when nothing was decoded (no valid `%XX` escape) or the result is not
/// UTF-8. A malformed escape (`%zz`) stays literal; `+` is not a space.
pub fn percent_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let hex = |c: u8| (c as char).to_digit(16).map(|d| d as u8);
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    let mut changed = false;
    while i < b.len() {
        if b[i] == b'%' && i + 2 < b.len() {
            if let (Some(h), Some(l)) = (hex(b[i + 1]), hex(b[i + 2])) {
                out.push(h * 16 + l);
                i += 3;
                changed = true;
                continue;
            }
        }
        out.push(b[i]);
        i += 1;
    }
    if !changed {
        return None;
    }
    String::from_utf8(out).ok()
}

/// The paths to try for the path part of a `zim:` address, in order (see `cs_zim_get` in the header):
/// strip a `#fragment`; then the percent-decoded path, then the path as given; then, if it has a `?`, the same
/// two without the `?query`. The `?` is never stripped first: real entries have `?` in their paths.
pub fn path_candidates(path: &str) -> Vec<String> {
    let p = path.split('#').next().unwrap_or("");
    let mut out: Vec<String> = Vec::new();
    let mut add = |x: &str| {
        if let Some(d) = percent_decode(x) {
            if !d.is_empty() && !out.contains(&d) {
                out.push(d);
            }
        }
        if !x.is_empty() && !out.iter().any(|o| o == x) {
            out.push(x.to_string());
        }
    };
    add(p);
    if let Some(q) = p.find('?') {
        add(&p[..q]);
    }
    out
}

/// Raw entry content after following redirects.
pub struct RawEntry {
    pub bytes: Vec<u8>,
    pub mime: String,
    /// Path of the entry that actually held the content (after redirects).
    pub path: String,
    /// Title of that entry (its path when the entry has no title).
    pub title: String,
}

/// Namespaces tried for a path, in order: `C` (current scheme), then the old scheme's `A` (articles),
/// `I` (images) and `-` (layout: CSS, JS).
const LOOKUP_NAMESPACES: [Namespace; 4] =
    [Namespace::UserContent, Namespace::Articles, Namespace::ImagesFile, Namespace::Layout];

impl ZimSource {
    pub fn open(path: &Path) -> Result<ZimSource> {
        match std::fs::metadata(path) {
            Ok(m) if m.is_file() => {}
            Ok(_) => return Err(Error::io(format!("not a file: {}", path.display()))),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                return Err(Error::not_found(format!("no such file: {}", path.display())))
            }
            Err(e) => return Err(Error::io(format!("{}: {e}", path.display()))),
        }
        let zim = Zim::new(path).map_err(|e| {
            let mut e = Error::from(e);
            e.message = format!("{}: {}", path.display(), e.message);
            e
        })?;
        let id = zim.header.uuid.to_string().to_ascii_lowercase();
        let meta = |name: &str| -> Option<String> {
            let c = zim.metadata(name).ok()??;
            let b = c.to_vec().ok()?;
            let s = String::from_utf8_lossy(&b).trim().to_string();
            if s.is_empty() { None } else { Some(s) }
        };
        let title = meta("Title").unwrap_or_else(|| {
            path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
        });
        let language = meta("Language");
        let (ft_bytes, ti_bytes) = index_sizes(&zim);
        let has_ft = zim.fulltext_index().ok().flatten().is_some();
        let has_ti = zim.title_index().ok().flatten().is_some();
        let entries = zim.header.article_count as u64;
        let x = Arc::new(Shared {
            path: path.to_path_buf(),
            cur: Mutex::new(None),
            opening: Mutex::new(()),
            failed: AtomicBool::new(false),
            mem: Mutex::new(None),
        });
        // With libzim the reader is not kept: everything the source needs was read above, and the file is read through
        // libzim's archive from here on (one open archive per ZIM, under the memory budget).
        let crate_zim = OnceLock::new();
        if !Zimx::AVAILABLE {
            let _ = crate_zim.set(zim);
        }
        Ok(ZimSource {
            crate_zim,
            crate_opening: Mutex::new(()),
            id,
            path: path.to_path_buf(),
            title,
            language,
            entries,
            has_ft,
            has_ti,
            ft_bytes,
            ti_bytes,
            x,
            warm_queued: Default::default(),
        })
    }

    /// The `zim` crate's reader for this file, opened on first use and kept (the Tantivy index build and builds without
    /// libzim use it; with libzim the reads do not).
    pub fn zim(&self) -> Result<&Zim> {
        if let Some(z) = self.crate_zim.get() {
            return Ok(z);
        }
        let _g = self.crate_opening.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(z) = self.crate_zim.get() {
            return Ok(z);
        }
        let z = Zim::new(&self.path).map_err(|e| {
            let mut e = Error::from(e);
            e.message = format!("{}: {}", self.path.display(), e.message);
            e
        })?;
        Ok(self.crate_zim.get_or_init(|| z))
    }

    /// What this ZIM's archive costs (`budget::archive_cost`): from its entry count and index sizes, with `caps` on libzim's caches.
    pub fn archive_cost(&self, caps: &Caps) -> u64 {
        archive_cost(&Profile { entries: self.entry_count(), fulltext_bytes: self.ft_bytes, title_bytes: self.ti_bytes }, caps)
    }

    /// Put the libzim archive of this ZIM under `budget` (the handle's, shared by all its ZIMs), with `caps` on libzim's caches
    /// and `opts` to open it with. The first call registers it; a later call with other caps or options closes the archive
    /// (it reopens with the new ones) and recomputes the cost. A ZIM never given a budget keeps its archive open once opened.
    pub fn configure(&self, budget: &Arc<ZimBudget>, caps: Caps, opts: OpenOpts) {
        let cost = self.archive_cost(&caps);
        let mut g = self.x.mem.lock().unwrap_or_else(|e| e.into_inner());
        let id = match g.as_ref() {
            Some(m) if Arc::ptr_eq(&m.budget, budget) => {
                if m.caps == caps && m.opts == opts {
                    return;
                }
                m.id
            }
            Some(m) => {
                m.budget.forget(m.id);
                budget.register()
            }
            None => budget.register(),
        };
        budget.forget(id);
        *g = Some(Mem { budget: budget.clone(), id, cost, opts, caps });
        drop(g);
        self.x.close();
    }

    /// What a background thread needs to open libzim on this file and build its searchers before the first search asks
    /// for them (`WarmJob::run`). `None` when there is nothing to warm (no libzim, or the ZIM has neither index) or the
    /// job was already handed out. A search that comes while the job runs waits for the same open.
    pub fn warm_job(&self) -> Option<WarmJob> {
        if !Zimx::AVAILABLE {
            return None;
        }
        let (fulltext, titles) = (self.has_ft, self.has_ti);
        if !(fulltext || titles) || self.warm_queued.swap(true, Ordering::SeqCst) {
            return None;
        }
        let cost = self.x.mem().map(|m| m.cost).unwrap_or(0);
        Some(WarmJob { x: self.x.clone(), fulltext, titles, cost })
    }

    /// libzim's handle on this file for one query (opened if it is not open), if the `xapian` feature is built in and it
    /// opens. The handle keeps the archive open while it is held; see `Shared::lease`.
    fn libzim(&self) -> Option<Arc<Zimx>> {
        if !Zimx::AVAILABLE {
            return None;
        }
        self.x.lease(false)
    }

    /// True when keyword search can use the ZIM's built-in Xapian full-text index (`X/fulltext/xapian`): the feature is
    /// built in, the ZIM has the entry (known from open; libzim is not opened for it) and libzim
    /// has not failed to open the file. `cs_status` asks this, so listing sources never opens libzim.
    pub fn has_xapian(&self) -> bool {
        Zimx::AVAILABLE
            && !self.x.failed.load(Ordering::SeqCst)
            && self.has_ft
    }

    /// The libzim handle when `has_xapian`: keyword search uses it instead of a Tantivy index. Opens libzim when needed.
    pub fn xapian(&self) -> Option<Arc<Zimx>> {
        if !self.has_xapian() {
            return None;
        }
        self.libzim().filter(|x| x.has_fulltext())
    }

    /// The libzim handle when this ZIM carries a title index (`X/title/xapian`): suggestions use it.
    pub fn title_index(&self) -> Option<Arc<Zimx>> {
        if !Zimx::AVAILABLE || !self.has_ti {
            return None;
        }
        self.libzim().filter(|x| x.has_title_index())
    }

    /// Whether the libzim archive is open right now (for tests and measurements).
    pub fn archive_open(&self) -> bool {
        self.x.current().is_some()
    }

    /// Number of directory entries in the file (all namespaces).
    pub fn entry_count(&self) -> u64 {
        self.entries
    }

    /// Follow redirects (at most `MAX_REDIRECT_HOPS`) to an entry that holds content (`zim` crate reader).
    fn follow(&self, zim: &Zim, mut entry: DirectoryEntry) -> Result<DirectoryEntry> {
        for _ in 0..=MAX_REDIRECT_HOPS {
            match entry.target {
                Some(Target::Redirect(idx)) => entry = zim.get_by_url_index(idx)?,
                _ => return Ok(entry),
            }
        }
        Err(redirect_chain_error())
    }

    /// Find `path` exactly (no decoding) in the namespaces of `LOOKUP_NAMESPACES`, first match wins (`zim` crate reader).
    fn find_exact(&self, zim: &Zim, path: &str) -> Result<Option<DirectoryEntry>> {
        for ns in LOOKUP_NAMESPACES {
            if let Some(e) = zim.get_by_path(ns, path)? {
                return Ok(Some(e));
            }
        }
        Ok(None)
    }

    /// Look up the path part of an address (see `path_candidates` for the order) and follow redirects (`zim` crate reader).
    pub fn lookup(&self, path: &str) -> Result<DirectoryEntry> {
        let zim = self.zim()?;
        for cand in path_candidates(path) {
            if let Some(e) = self.find_exact(zim, &cand)? {
                return self.follow(zim, e);
            }
        }
        Err(self.no_entry(path))
    }

    fn no_entry(&self, path: &str) -> Error {
        Error::not_found(format!("no entry {path:?} in zim {}", self.id))
    }

    /// Bytes and mime type of the entry at `path`, following redirects. Through the libzim archive (the one the searches
    /// use, under the memory budget; a read counts as a use of it) when libzim is built in and opens the file; otherwise
    /// through the `zim` crate.
    pub fn get(&self, path: &str) -> Result<RawEntry> {
        match self.libzim() {
            Some(x) => self.get_libzim(&x, path),
            None => self.get_crate(path),
        }
    }

    /// `get` through libzim's archive `x`: the same candidates in the same order, redirects followed within the same limit.
    #[doc(hidden)]
    pub fn get_libzim(&self, x: &Zimx, path: &str) -> Result<RawEntry> {
        for cand in path_candidates(path) {
            match x.get(&cand, MAX_REDIRECT_HOPS + 1)? {
                XGet::Found(e) => return Ok(RawEntry { bytes: e.bytes, mime: e.mime, path: e.path, title: e.title }),
                XGet::Loop => return Err(redirect_chain_error()),
                XGet::Missing => {}
            }
        }
        Err(self.no_entry(path))
    }

    /// `get` through the `zim` crate (the reader of builds without libzim; also run beside libzim's by the byte-identity test).
    #[doc(hidden)]
    pub fn get_crate(&self, path: &str) -> Result<RawEntry> {
        let zim = self.zim()?;
        let entry = self.lookup(path)?;
        let mime = match &entry.mime_type {
            MimeType::Type(s) => s.clone(),
            _ => return Err(Error::not_found(format!("entry {path:?} has no content"))),
        };
        let content = zim
            .entry_content(&entry)?
            .ok_or_else(|| Error::not_found(format!("entry {path:?} has no content")))?;
        let bytes = content.to_vec()?;
        let title = if entry.title.is_empty() { entry.url.clone() } else { entry.title.clone() };
        Ok(RawEntry { bytes, mime, path: entry.url, title })
    }

    /// Path of the main page (redirect followed), or `not_found` if the ZIM has none.
    pub fn main_page_path(&self) -> Result<String> {
        match self.libzim() {
            Some(x) => self.main_page_libzim(&x),
            None => self.main_page_crate(),
        }
    }

    /// `main_page_path` through libzim's archive `x` (same hop limit as the `zim` crate's).
    #[doc(hidden)]
    pub fn main_page_libzim(&self, x: &Zimx) -> Result<String> {
        match x.main_page(MAIN_PAGE_HOPS)? {
            XMain::Found(p) => Ok(p),
            XMain::Missing => Err(Error::not_found(format!("zim {} has no main page", self.id))),
            XMain::Loop => Err(Error::internal("redirect loop while resolving the main page")),
        }
    }

    /// `main_page_path` through the `zim` crate.
    #[doc(hidden)]
    pub fn main_page_crate(&self) -> Result<String> {
        match self.zim()?.main_page() {
            Ok(Some(e)) => Ok(e.url),
            Ok(None) => Err(Error::not_found(format!("zim {} has no main page", self.id))),
            Err(e) => {
                let e = Error::from(e);
                // `Zim::main_page` has its own hop limit; a loop is reported as not found.
                if e.code == ErrorCode::Io && e.message.contains("redirect") {
                    Err(Error::internal(e.message))
                } else {
                    Err(e)
                }
            }
        }
    }
}

fn redirect_chain_error() -> Error {
    Error::internal(format!("redirect chain longer than {MAX_REDIRECT_HOPS} hops"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    const U: &str = "17e9fb54-9554-d2cd-e15f-17cf750882d1";

    #[test]
    fn parses_plain_address() {
        let a = parse_address(&format!("zim:{U}/Water_purification")).unwrap();
        assert_eq!(a, ZimAddress { id: U.into(), path: "Water_purification".into() });
    }

    #[test]
    fn path_keeps_slashes_query_and_case() {
        let a = parse_address(&format!("zim:{U}/a/b?x=1&y=Z#f")).unwrap();
        assert_eq!(a.path, "a/b?x=1&y=Z#f");
    }

    #[test]
    fn uuid_is_lowercased() {
        let a = parse_address(&format!("zim:{}/p", U.to_uppercase())).unwrap();
        assert_eq!(a.id, U);
    }

    #[test]
    fn malformed_addresses_are_bad_json() {
        for bad in [
            "",
            "zim:",
            "pack:abc/1",
            "zim:nouuid/path",
            &format!("zim:{U}"),
            &format!("zim:{U}/"),
            &format!("zim:{}x/p", &U[..35]),
            &format!("{U}/p"),
        ] {
            let e = parse_address(bad).unwrap_err();
            assert_eq!(e.code, ErrorCode::BadJson, "{bad:?}");
        }
    }

    #[test]
    fn format_roundtrip() {
        let s = format_address(U, "x/y");
        assert_eq!(parse_address(&s).unwrap().path, "x/y");
    }

    #[test]
    fn open_missing_file_is_not_found() {
        let e = ZimSource::open(Path::new("/nonexistent/none.zim")).err().unwrap();
        assert_eq!(e.code, ErrorCode::NotFound);
    }

    #[test]
    fn address_encodes_percent_and_hash() {
        let s = format_address(U, "a%b#c?d");
        assert_eq!(s, format!("zim:{U}/a%25b%23c?d"));
        let p = parse_address(&s).unwrap().path;
        assert_eq!(path_candidates(&p)[0], "a%b#c?d");
    }

    #[test]
    fn percent_decoding() {
        assert_eq!(percent_decode("caf%C3%A9").as_deref(), Some("café"));
        assert_eq!(percent_decode("a%23b").as_deref(), Some("a#b"));
        assert_eq!(percent_decode("plain"), None);
        assert_eq!(percent_decode("bad%zz"), None);
        assert_eq!(percent_decode("end%4"), None);
        assert_eq!(percent_decode("x%41").as_deref(), Some("xA"));
        assert_eq!(percent_decode("%FF%FE"), None); // not UTF-8
        assert_eq!(percent_decode("a+b%20c").as_deref(), Some("a+b c"));
    }

    #[test]
    fn candidates_order() {
        // fragment stripped, then decoded, then raw
        assert_eq!(path_candidates("A/caf%C3%A9#sec"), vec!["A/café", "A/caf%C3%A9"]);
        // a '#' only ever starts a fragment; an encoded one is part of the path
        assert_eq!(path_candidates("a%23b"), vec!["a#b", "a%23b"]);
        assert_eq!(path_candidates("plain"), vec!["plain"]);
        // '?' kept first, stripped later
        assert_eq!(path_candidates("a/b?x=1"), vec!["a/b?x=1", "a/b"]);
        assert_eq!(
            path_candidates("a%20b?x=%41#f"),
            vec!["a b?x=A", "a%20b?x=%41", "a b", "a%20b"]
        );
        assert!(path_candidates("#only").is_empty());
    }
}
