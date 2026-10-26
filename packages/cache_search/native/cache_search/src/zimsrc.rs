//! One opened ZIM file.

use crate::error::{Error, ErrorCode, Result};
use std::path::{Path, PathBuf};
use crate::zimx::Zimx;
use std::sync::OnceLock;
use zim::{DirectoryEntry, MimeType, Namespace, Target, Zim};

/// Redirect hops followed before giving up.
pub const MAX_REDIRECT_HOPS: u32 = 10;

pub struct ZimSource {
    pub zim: Zim,
    /// The ZIM's UUID, lowercase hyphenated.
    pub id: String,
    pub path: PathBuf,
    pub title: String,
    pub language: Option<String>,
    /// libzim's view of the same file, opened on first use: `None` when the `xapian` feature is not built in or libzim
    /// could not open it (the `zim` crate stays the reader for `read` and `zim_get` either way).
    x: OnceLock<Option<Zimx>>,
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
        Ok(ZimSource { zim, id, path: path.to_path_buf(), title, language, x: OnceLock::new() })
    }

    /// libzim's handle on this file (opened on first use), if the `xapian` feature is built in and it opens.
    fn libzim(&self) -> Option<&Zimx> {
        if !Zimx::AVAILABLE {
            return None;
        }
        self.x.get_or_init(|| Zimx::open(&self.path).ok()).as_ref()
    }

    /// True when keyword search can use the ZIM's built-in Xapian full-text index (`X/fulltext/xapian`): the feature is
    /// built in, the ZIM has the entry (a cheap lookup with the `zim` crate; libzim is not opened for it) and libzim
    /// has not failed to open the file. `cs_status` asks this, so listing sources never opens libzim.
    pub fn has_xapian(&self) -> bool {
        Zimx::AVAILABLE
            && !matches!(self.x.get(), Some(None))
            && self.zim.fulltext_index().ok().flatten().is_some()
    }

    /// The libzim handle when `has_xapian`: keyword search uses it instead of a Tantivy index. Opens libzim on first use.
    pub fn xapian(&self) -> Option<&Zimx> {
        if !self.has_xapian() {
            return None;
        }
        self.libzim().filter(|x| x.has_fulltext())
    }

    /// The libzim handle when this ZIM carries a title index (`X/title/xapian`): suggestions use it.
    pub fn title_index(&self) -> Option<&Zimx> {
        if !Zimx::AVAILABLE || self.zim.title_index().ok().flatten().is_none() {
            return None;
        }
        self.libzim().filter(|x| x.has_title_index())
    }

    /// Number of directory entries in the file (all namespaces).
    pub fn entry_count(&self) -> u64 {
        self.zim.header.article_count as u64
    }

    /// Follow redirects (at most `MAX_REDIRECT_HOPS`) to an entry that holds content.
    fn follow(&self, mut entry: DirectoryEntry) -> Result<DirectoryEntry> {
        for _ in 0..=MAX_REDIRECT_HOPS {
            match entry.target {
                Some(Target::Redirect(idx)) => entry = self.zim.get_by_url_index(idx)?,
                _ => return Ok(entry),
            }
        }
        Err(Error::internal(format!("redirect chain longer than {MAX_REDIRECT_HOPS} hops")))
    }

    /// Find `path` exactly (no decoding) in the namespaces of `LOOKUP_NAMESPACES`, first match wins.
    fn find_exact(&self, path: &str) -> Result<Option<DirectoryEntry>> {
        for ns in LOOKUP_NAMESPACES {
            if let Some(e) = self.zim.get_by_path(ns, path)? {
                return Ok(Some(e));
            }
        }
        Ok(None)
    }

    /// Look up the path part of an address (see `path_candidates` for the order) and follow redirects.
    pub fn lookup(&self, path: &str) -> Result<DirectoryEntry> {
        for cand in path_candidates(path) {
            if let Some(e) = self.find_exact(&cand)? {
                return self.follow(e);
            }
        }
        Err(Error::not_found(format!("no entry {path:?} in zim {}", self.id)))
    }

    /// Bytes and mime type of the entry at `path`, following redirects.
    pub fn get(&self, path: &str) -> Result<RawEntry> {
        let entry = self.lookup(path)?;
        let mime = match &entry.mime_type {
            MimeType::Type(s) => s.clone(),
            _ => return Err(Error::not_found(format!("entry {path:?} has no content"))),
        };
        let content = self
            .zim
            .entry_content(&entry)?
            .ok_or_else(|| Error::not_found(format!("entry {path:?} has no content")))?;
        let bytes = content.to_vec()?;
        let title = if entry.title.is_empty() { entry.url.clone() } else { entry.title.clone() };
        Ok(RawEntry { bytes, mime, path: entry.url, title })
    }

    /// Path of the main page (redirect followed), or `not_found` if the ZIM has none.
    pub fn main_page_path(&self) -> Result<String> {
        match self.zim.main_page() {
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
