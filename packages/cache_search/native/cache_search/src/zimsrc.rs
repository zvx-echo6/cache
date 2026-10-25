//! One opened ZIM file.

use crate::error::{Error, ErrorCode, Result};
use std::path::{Path, PathBuf};
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

pub fn format_address(id: &str, path: &str) -> String {
    format!("zim:{id}/{path}")
}

/// Raw entry content after following redirects.
pub struct RawEntry {
    pub bytes: Vec<u8>,
    pub mime: String,
    /// Path of the entry that actually held the content (after redirects).
    pub path: String,
}

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
        Ok(ZimSource { zim, id, path: path.to_path_buf(), title, language })
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

    /// Look up `path` in the content namespace ('C') and follow redirects.
    fn lookup(&self, path: &str) -> Result<DirectoryEntry> {
        let entry = self
            .zim
            .get_by_path(Namespace::UserContent, path)?
            .ok_or_else(|| Error::not_found(format!("no entry {path:?} in zim {}", self.id)))?;
        self.follow(entry)
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
        Ok(RawEntry { bytes, mime, path: entry.url })
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
}
