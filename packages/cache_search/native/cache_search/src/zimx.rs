//! A ZIM's built-in indexes through libzim: the Xapian full-text index (`X/fulltext/xapian`) and the title index.
//!
//! The C++ shim `native/zimx` wraps the official prebuilt libzim (feature `xapian`, Windows and Android). Without
//! the `zimx` cfg this module is a stub whose `open` always fails with `unsupported`, so callers need no `cfg` of
//! their own and the core is Tantivy-only.

use crate::error::{Error, Result};
use std::path::Path;

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

/// Options for opening a libzim archive (`None` keeps libzim's default for that option; see DESIGN.md "Memory budget").
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct OpenOpts {
    /// Preload the Xapian database when the archive opens (libzim's default: yes).
    pub preload_xapian: Option<bool>,
    /// Dirent ranges preloaded at open, to speed up entry lookups (0 = none).
    pub preload_dirent_ranges: Option<u32>,
    /// The archive's dirent cache limit, in dirents.
    pub dirent_cache: Option<u64>,
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
    use serde_json::Value;
    use std::ffi::{c_char, c_int, c_void, CStr, CString};
    
    extern "C" {
        fn zimx_open_with(path: *const c_char, preload_xapian: c_int, ranges: c_int, dirent_cache: i64, err: *mut *mut c_char) -> *mut c_void;
        fn zimx_archive_info(z: *mut c_void) -> *mut c_char;
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

    struct Inner {
        p: *mut c_void,
        fulltext: bool,
        titles: bool,
    }

    // libzim's Archive is read-only and thread safe; the shim serialises the calls that use a kept searcher.
    unsafe impl Send for Inner {}
    unsafe impl Sync for Inner {}

    impl Drop for Inner {
        fn drop(&mut self) {
            unsafe { zimx_close(self.p) };
        }
    }

    /// An open libzim archive (read-only). Its searchers are built on first use and kept for as long as the archive is open;
    /// what stays open is decided by the memory budget one level up (`zimsrc.rs`, `budget.rs`). One handle can be used from
    /// several threads.
    pub struct Zimx {
        inner: Inner,
    }

    impl Zimx {
        pub const AVAILABLE: bool = true;

        /// Open with libzim's own defaults.
        pub fn open(path: &Path) -> Result<Zimx> {
            Zimx::open_with(path, &OpenOpts::default())
        }

        /// Open with the given archive options (`OpenOpts`; `None` keeps libzim's default for that option).
        pub fn open_with(path: &Path, o: &OpenOpts) -> Result<Zimx> {
            let s = path.to_str().ok_or_else(|| Error::io(format!("path is not UTF-8: {}", path.display())))?;
            let c = CString::new(s).map_err(|_| Error::io("path has a NUL byte"))?;
            let mut err: *mut c_char = std::ptr::null_mut();
            let px = o.preload_xapian.map(|b| b as c_int).unwrap_or(-1);
            let dr = o.preload_dirent_ranges.map(|n| n.min(i32::MAX as u32) as c_int).unwrap_or(-1);
            let dc = o.dirent_cache.map(|n| n.min(i64::MAX as u64) as i64).unwrap_or(-1);
            let p = unsafe { zimx_open_with(c.as_ptr(), px, dr, dc, &mut err) };
            if p.is_null() {
                let m = take(err)
                    .and_then(|j| serde_json::from_str::<Value>(&j).ok())
                    .and_then(|v| v.get("error").and_then(Value::as_str).map(str::to_string))
                    .unwrap_or_else(|| "libzim could not open the file".to_string());
                return Err(Error::io(format!("{}: {m}", path.display())));
            }
            let (fulltext, titles) = unsafe { (zimx_has_fulltext(p) != 0, zimx_has_title_index(p) != 0) };
            Ok(Zimx { inner: Inner { p, fulltext, titles } })
        }

        /// This archive's dirent cache: (entries in use, limit).
        pub fn dirent_cache(&self) -> (u64, u64) {
            match parse(unsafe { zimx_archive_info(self.inner.p) }) {
                Ok(v) => (v["dirent_cache_current"].as_u64().unwrap_or(0), v["dirent_cache_max"].as_u64().unwrap_or(0)),
                Err(_) => (0, 0),
            }
        }

        pub fn has_fulltext(&self) -> bool {
            self.inner.fulltext
        }

        pub fn has_title_index(&self) -> bool {
            self.inner.titles
        }

        /// Results `offset..offset+k` of a full-text query and the estimated number of matches.
        pub fn search(&self, query: &str, offset: usize, k: usize) -> Result<(Vec<XHit>, usize)> {
            let q = CString::new(query.replace('\0', " ")).unwrap();
            let (off, k) = (offset.min(i32::MAX as usize) as c_int, k.min(i32::MAX as usize) as c_int);
            let v = parse(unsafe { zimx_search(self.inner.p, q.as_ptr(), off, k, self.inner.fulltext as c_int) })?;
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
        /// suggestion does not pay for it. A searcher the ZIM does not have is skipped.
        pub fn prewarm(&self, fulltext: bool, titles: bool) -> Result<()> {
            let (ft, ti) = (fulltext && self.inner.fulltext, titles && self.inner.titles);
            if !(ft || ti) {
                return Ok(());
            }
            parse(unsafe { zimx_prewarm(self.inner.p, ft as c_int, ti as c_int) }).map(|_| ())
        }

        /// Release the kept searchers now (the archive stays open). Used by the memory measurements.
        pub fn drop_searchers(&self, fulltext: bool, titles: bool) {
            let _ = parse(unsafe { zimx_drop(self.inner.p, fulltext as c_int, titles as c_int) });
        }

        /// The first `k` title suggestions for `prefix`, in libzim's order.
        pub fn suggest(&self, prefix: &str, k: usize) -> Result<Vec<XSuggestion>> {
            let q = CString::new(prefix.replace('\0', " ")).unwrap();
            let keep = self.inner.titles as c_int;
            let v = parse(unsafe { zimx_suggest(self.inner.p, q.as_ptr(), k.min(i32::MAX as usize) as c_int, keep) })?;
            let text = |h: &Value, f: &str| h.get(f).and_then(Value::as_str).unwrap_or("").to_string();
            Ok(v["hits"]
                .as_array()
                .map(|a| a.iter().map(|h| XSuggestion { path: text(h, "path"), title: text(h, "title") }).collect())
                .unwrap_or_default())
        }
    }

    /// libzim's cluster cache (ZIM clusters, shared by every open archive in the process; libzim counts their compressed size):
    /// bytes in use and its limit. Reading articles fills it. Its cap is set from `zim_cluster_cache_mb` and its estimated cost
    /// is the budget's reserved part (`budget::reserved_cost`).
    pub fn cluster_cache() -> (u64, u64) {
        match parse(unsafe { zimx_cluster_cache() }) {
            Ok(v) => (v["current"].as_u64().unwrap_or(0), v["max"].as_u64().unwrap_or(0)),
            Err(_) => (0, 0),
        }
    }

    /// Set libzim's process-wide cluster cache limit in bytes (what is over it is dropped). The core sets it from
    /// `zim_cluster_cache_mb` (see `budget.rs`).
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
        pub fn open_with(_path: &Path, _o: &OpenOpts) -> Result<Zimx> {
            Err(Error::unsupported("built without the xapian feature"))
        }
        pub fn dirent_cache(&self) -> (u64, u64) {
            (0, 0)
        }
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
