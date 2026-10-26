//! A ZIM's built-in indexes through libzim: the Xapian full-text index (`X/fulltext/xapian`) and the title index.
//!
//! The C++ shim `native/zimx` wraps the official prebuilt libzim (feature `xapian`, Windows and Android). Without
//! the `zimx` cfg this module is a stub whose `open` always fails with `unsupported`, so callers need no `cfg` of
//! their own and the core is Tantivy-only.

use crate::budget::SearcherBudget;
use crate::error::{Error, Result};
use std::path::Path;
use std::sync::Arc;

/// One full-text hit, as libzim returns it.
#[derive(Debug, Clone)]
pub struct XHit {
    /// Entry path inside the ZIM (no namespace), as stored.
    pub path: String,
    pub title: String,
    /// libzim's snippet: HTML with `<b>` around the matched words, not yet stripped.
    pub snippet: String,
    /// libzim's relevance for this hit: Xapian's percentage (0-100), best first. The best hit of a query is 100 in
    /// every ZIM, so it is relative to the ZIM's own best hit and cannot be compared between ZIMs.
    pub score: i32,
}

/// One title suggestion.
#[derive(Debug, Clone)]
pub struct XSuggestion {
    pub path: String,
    pub title: String,
}

#[cfg(zimx)]
mod imp {
    use super::*;
    use crate::budget::{estimate_cost, Evict, Kind};
    use serde_json::Value;
    use std::ffi::{c_char, c_int, c_void, CStr, CString};
    use std::sync::{OnceLock, Weak};

    extern "C" {
        fn zimx_open(path: *const c_char, err: *mut *mut c_char) -> *mut c_void;
        fn zimx_close(z: *mut c_void);
        fn zimx_has_fulltext(z: *mut c_void) -> c_int;
        fn zimx_has_title_index(z: *mut c_void) -> c_int;
        fn zimx_search(z: *mut c_void, query: *const c_char, offset: c_int, k: c_int, keep: c_int) -> *mut c_char;
        fn zimx_suggest(z: *mut c_void, prefix: *const c_char, k: c_int, keep: c_int) -> *mut c_char;
        fn zimx_prewarm(z: *mut c_void, fulltext: c_int, titles: c_int) -> *mut c_char;
        fn zimx_drop(z: *mut c_void, fulltext: c_int, titles: c_int) -> *mut c_char;
        fn zimx_cluster_cache() -> *mut c_char;
        fn zimx_set_cluster_cache_max(bytes: u64) -> *mut c_char;
        fn zimx_version() -> *mut c_char;
        fn zimx_selftest_throw(mode: c_int) -> *mut c_char;
        fn zimx_free(s: *mut c_char);
    }

    /// Take a shim string: copy it, free it. `None` for NULL.
    fn take(p: *mut c_char) -> Option<String> {
        if p.is_null() {
            return None;
        }
        let s = unsafe { CStr::from_ptr(p) }.to_string_lossy().into_owned();
        unsafe { zimx_free(p) };
        Some(s)
    }

    /// Parse a shim JSON result; `{"error":...}` becomes an `Error`.
    fn parse(p: *mut c_char) -> Result<Value> {
        let s = take(p).ok_or_else(|| Error::internal("libzim shim returned nothing (out of memory)"))?;
        let v: Value = serde_json::from_str(&s).map_err(|e| Error::internal(format!("libzim shim: bad JSON: {e}")))?;
        if let Some(m) = v.get("error").and_then(Value::as_str) {
            return Err(Error::internal(m.to_string()));
        }
        Ok(v)
    }

    /// The memory budget this archive's searchers answer to (see `budget.rs`).
    struct Gov {
        budget: Arc<SearcherBudget>,
        id: u64,
        /// Estimated cost of the kept full-text and title searchers.
        ft_cost: u64,
        ti_cost: u64,
    }

    struct Inner {
        p: *mut c_void,
        fulltext: bool,
        titles: bool,
        /// Set by `bind`; without it every searcher is kept (no budget).
        gov: OnceLock<Gov>,
    }

    // libzim's Archive is read-only and thread safe; the shim serialises the calls that use a kept searcher.
    unsafe impl Send for Inner {}
    unsafe impl Sync for Inner {}

    impl Drop for Inner {
        fn drop(&mut self) {
            if let Some(g) = self.gov.get() {
                g.budget.forget(g.id);
            }
            unsafe { zimx_close(self.p) };
        }
    }

    impl Evict for Inner {
        fn drop_searcher(&self, kind: Kind) {
            let (ft, ti) = ((kind == Kind::Fulltext) as c_int, (kind == Kind::Titles) as c_int);
            let _ = parse(unsafe { zimx_drop(self.p, ft, ti) });
        }
    }

    /// An open libzim archive (read-only). Kept searchers are built inside the shim and are bounded by the memory budget
    /// the archive is bound to (`bind`); one handle can be used from several threads.
    pub struct Zimx {
        inner: Arc<Inner>,
    }

    impl Zimx {
        pub const AVAILABLE: bool = true;

        pub fn open(path: &Path) -> Result<Zimx> {
            let s = path.to_str().ok_or_else(|| Error::io(format!("path is not UTF-8: {}", path.display())))?;
            let c = CString::new(s).map_err(|_| Error::io("path has a NUL byte"))?;
            let mut err: *mut c_char = std::ptr::null_mut();
            let p = unsafe { zimx_open(c.as_ptr(), &mut err) };
            if p.is_null() {
                let m = take(err)
                    .and_then(|j| serde_json::from_str::<Value>(&j).ok())
                    .and_then(|v| v.get("error").and_then(Value::as_str).map(str::to_string))
                    .unwrap_or_else(|| "libzim could not open the file".to_string());
                return Err(Error::io(format!("{}: {m}", path.display())));
            }
            let (fulltext, titles) = unsafe { (zimx_has_fulltext(p) != 0, zimx_has_title_index(p) != 0) };
            Ok(Zimx { inner: Arc::new(Inner { p, fulltext, titles, gov: OnceLock::new() }) })
        }

        /// Put this archive's searchers under `budget`. `fulltext_bytes` and `title_bytes` are the sizes of the ZIM's
        /// two index entries (0 when unknown), from which the cost of keeping each searcher is estimated. The first call
        /// wins; an archive that is never bound keeps every searcher it builds.
        pub fn bind(&self, budget: Arc<SearcherBudget>, fulltext_bytes: u64, title_bytes: u64) {
            let id = budget.register();
            let g = Gov {
                budget: budget.clone(),
                id,
                ft_cost: estimate_cost(Kind::Fulltext, fulltext_bytes),
                ti_cost: estimate_cost(Kind::Titles, title_bytes),
            };
            if self.inner.gov.set(g).is_err() {
                budget.forget(id);
            }
        }

        pub fn has_fulltext(&self) -> bool {
            self.inner.fulltext
        }

        pub fn has_title_index(&self) -> bool {
            self.inner.titles
        }

        fn weak(&self) -> Weak<dyn Evict> {
            let w: Weak<Inner> = Arc::downgrade(&self.inner);
            w
        }

        /// Whether the `kind` searcher is to be kept for the call that is about to run (marks it used). `false`: the
        /// searcher is too big for the budget and the call builds a temporary one.
        fn keep(&self, kind: Kind) -> bool {
            match self.inner.gov.get() {
                None => true,
                Some(g) => {
                    let cost = if kind == Kind::Fulltext { g.ft_cost } else { g.ti_cost };
                    g.budget.admit(g.id, kind, cost, self.weak())
                }
            }
        }

        /// After a call that kept its searcher: if another thread's admission evicted it while the call ran, release what
        /// the call rebuilt, so what the shim holds is what the budget counts.
        fn settle(&self, kind: Kind) {
            if let Some(g) = self.inner.gov.get() {
                if !g.budget.is_kept(g.id, kind) {
                    self.inner.drop_searcher(kind);
                }
            }
        }

        /// Results `offset..offset+k` of a full-text query and the estimated number of matches.
        pub fn search(&self, query: &str, offset: usize, k: usize) -> Result<(Vec<XHit>, usize)> {
            let q = CString::new(query.replace('\0', " ")).unwrap();
            let (off, k) = (offset.min(i32::MAX as usize) as c_int, k.min(i32::MAX as usize) as c_int);
            let keep = self.inner.fulltext && self.keep(Kind::Fulltext);
            let r = parse(unsafe { zimx_search(self.inner.p, q.as_ptr(), off, k, keep as c_int) });
            if keep {
                self.settle(Kind::Fulltext);
            }
            let v = r?;
            let text = |h: &Value, f: &str| h.get(f).and_then(Value::as_str).unwrap_or("").to_string();
            let hits = v["hits"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .map(|h| XHit {
                            path: text(h, "path"),
                            title: text(h, "title"),
                            snippet: text(h, "snippet"),
                            score: h.get("score").and_then(Value::as_i64).unwrap_or(0) as i32,
                        })
                        .collect()
                })
                .unwrap_or_default();
            Ok((hits, v["total"].as_u64().unwrap_or(0) as usize))
        }

        /// Build the full-text and/or title searchers now (opens the Xapian databases), so the first search or
        /// suggestion does not pay for it. A searcher the ZIM does not have is skipped, and so is one the budget has no
        /// room for (prewarm never evicts another source's searcher).
        pub fn prewarm(&self, fulltext: bool, titles: bool) -> Result<()> {
            let want = |has: bool, wanted: bool, kind: Kind| -> bool {
                if !(has && wanted) {
                    return false;
                }
                match self.inner.gov.get() {
                    None => true,
                    Some(g) => {
                        let cost = if kind == Kind::Fulltext { g.ft_cost } else { g.ti_cost };
                        g.budget.try_reserve(g.id, kind, cost, self.weak())
                    }
                }
            };
            let (ft, ti) = (want(self.inner.fulltext, fulltext, Kind::Fulltext), want(self.inner.titles, titles, Kind::Titles));
            if !(ft || ti) {
                return Ok(());
            }
            parse(unsafe { zimx_prewarm(self.inner.p, ft as c_int, ti as c_int) }).map(|_| ())
        }

        /// Release the kept searchers now (the archive stays open). Used by the memory measurements; the budget does it itself.
        pub fn drop_searchers(&self, fulltext: bool, titles: bool) {
            if let Some(g) = self.inner.gov.get() {
                if fulltext {
                    g.budget.release(g.id, Kind::Fulltext);
                }
                if titles {
                    g.budget.release(g.id, Kind::Titles);
                }
            }
            let _ = parse(unsafe { zimx_drop(self.inner.p, fulltext as c_int, titles as c_int) });
        }

        /// The first `k` title suggestions for `prefix`, in libzim's order.
        pub fn suggest(&self, prefix: &str, k: usize) -> Result<Vec<XSuggestion>> {
            let q = CString::new(prefix.replace('\0', " ")).unwrap();
            let keep = self.inner.titles && self.keep(Kind::Titles);
            let r = parse(unsafe { zimx_suggest(self.inner.p, q.as_ptr(), k.min(i32::MAX as usize) as c_int, keep as c_int) });
            if keep {
                self.settle(Kind::Titles);
            }
            let v = r?;
            let text = |h: &Value, f: &str| h.get(f).and_then(Value::as_str).unwrap_or("").to_string();
            Ok(v["hits"]
                .as_array()
                .map(|a| a.iter().map(|h| XSuggestion { path: text(h, "path"), title: text(h, "title") }).collect())
                .unwrap_or_default())
        }
    }

    /// libzim's cluster cache (decompressed ZIM clusters, shared by every open archive in the process): bytes in use and
    /// its limit. Reading articles fills it, and dropping a searcher does not empty it; it is not under the searcher budget.
    pub fn cluster_cache() -> (u64, u64) {
        match parse(unsafe { zimx_cluster_cache() }) {
            Ok(v) => (v["current"].as_u64().unwrap_or(0), v["max"].as_u64().unwrap_or(0)),
            Err(_) => (0, 0),
        }
    }

    /// Set libzim's process-wide cluster cache limit in bytes (what is over it is dropped). Not used by the core; a hook for
    /// the memory measurements in `tests/searcher_cost.rs`.
    #[doc(hidden)]
    pub fn set_cluster_cache_max(bytes: u64) {
        let _ = parse(unsafe { zimx_set_cluster_cache_max(bytes) });
    }

    /// libzim's version, e.g. "9.8.2".
    pub fn version() -> String {
        parse(unsafe { zimx_version() }).ok().and_then(|v| v["version"].as_str().map(str::to_string)).unwrap_or_default()
    }

    /// Test hook: make the shim throw a C++ exception of kind `mode` (0 runtime_error, 1 int, 2 bad_alloc) and return
    /// what came back across the boundary.
    pub fn selftest_throw(mode: i32) -> Result<()> {
        parse(unsafe { zimx_selftest_throw(mode) }).map(|_| ())
    }
}

#[cfg(not(zimx))]
mod imp {
    use super::*;

    /// Stub: libzim is not built into this library.
    pub struct Zimx(());

    impl Zimx {
        pub const AVAILABLE: bool = false;

        pub fn open(_path: &Path) -> Result<Zimx> {
            Err(Error::unsupported("built without the xapian feature"))
        }
        pub fn bind(&self, _budget: Arc<SearcherBudget>, _fulltext_bytes: u64, _title_bytes: u64) {}
        pub fn drop_searchers(&self, _fulltext: bool, _titles: bool) {}
        pub fn has_fulltext(&self) -> bool {
            false
        }
        pub fn has_title_index(&self) -> bool {
            false
        }
        pub fn search(&self, _q: &str, _offset: usize, _k: usize) -> Result<(Vec<XHit>, usize)> {
            Err(Error::unsupported("built without the xapian feature"))
        }
        pub fn suggest(&self, _p: &str, _k: usize) -> Result<Vec<XSuggestion>> {
            Err(Error::unsupported("built without the xapian feature"))
        }
        pub fn prewarm(&self, _fulltext: bool, _titles: bool) -> Result<()> {
            Err(Error::unsupported("built without the xapian feature"))
        }
    }

    pub fn version() -> String {
        String::new()
    }

    pub fn cluster_cache() -> (u64, u64) {
        (0, 0)
    }

    pub fn set_cluster_cache_max(_bytes: u64) {}

    pub fn selftest_throw(_mode: i32) -> Result<()> {
        Err(Error::unsupported("built without the xapian feature"))
    }
}

pub use imp::{cluster_cache, selftest_throw, set_cluster_cache_max, version, Zimx};

/// The text of a libzim snippet as the result shows it: tags stripped, entities decoded, whitespace collapsed, the
/// leading and trailing "..." removed, cut at a sentence end to at most `max` chars (the rule used for every snippet).
pub fn clean_snippet(raw: &str, max: usize) -> String {
    let plain = crate::html::strip(raw);
    let t = plain.trim().trim_start_matches("...").trim_start_matches('\u{2026}').trim_end_matches("...").trim();
    let t = crate::html::tidy_fragment(t);
    if t.chars().count() > max {
        crate::html::snippet_from_text(&t, max)
    } else {
        t
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn snippet_is_stripped_and_cut() {
        let s = clean_snippet("...a <b>flood</b>. <b>Flood</b> insurance &amp; more takes 30 days. Listen t", 400);
        assert_eq!(s, "a flood. Flood insurance & more takes 30 days.");
        assert_eq!(clean_snippet("<b>x</b>", 400), "x");
        let long = format!("{} end.", "word ".repeat(200));
        assert!(clean_snippet(&long, 400).chars().count() <= 400);
    }

    #[cfg(not(zimx))]
    #[test]
    fn without_the_feature_open_is_unsupported() {
        let e = Zimx::open(Path::new("x.zim")).err().unwrap();
        assert_eq!(e.code, crate::ErrorCode::Unsupported);
    }
}
