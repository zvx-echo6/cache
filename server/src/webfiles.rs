//! The files of the browser app, served from the `--web` folder. No directory listing, and no path that leaves the folder.

use std::path::{Component, Path, PathBuf};

/// What a request path points at.
#[derive(Debug, PartialEq)]
pub enum Resolved {
    File(PathBuf),
    /// Nothing there (or a folder with no index.html).
    Missing,
    /// A path that tries to leave the folder, or is not a path at all.
    Refused,
}

fn percent_decode(s: &str) -> Option<String> {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'%' {
            let hex = std::str::from_utf8(b.get(i + 1..i + 3)?).ok()?;
            out.push(u8::from_str_radix(hex, 16).ok()?);
            i += 3;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8(out).ok()
}

/// Find the file for `url_path` (the path of the request, without its query) under `root`.
pub fn resolve(root: &Path, url_path: &str) -> Resolved {
    let Some(decoded) = percent_decode(url_path) else { return Resolved::Refused };
    if decoded.contains(['\0', '\\', ':']) {
        return Resolved::Refused;
    }
    let mut path = root.to_path_buf();
    for part in decoded.split('/') {
        match part {
            "" | "." => {}
            ".." => return Resolved::Refused,
            p => path.push(p),
        }
    }
    if path.components().any(|c| matches!(c, Component::ParentDir)) {
        return Resolved::Refused;
    }
    if path.is_dir() {
        path.push("index.html");
    }
    // a link inside the folder must not lead out of it
    let (Ok(real), Ok(real_root)) = (path.canonicalize(), root.canonicalize()) else { return Resolved::Missing };
    if !real.starts_with(&real_root) {
        return Resolved::Refused;
    }
    if real.is_file() {
        Resolved::File(real)
    } else {
        Resolved::Missing
    }
}

/// The content type for a file name, from a small table.
pub fn content_type(path: &Path) -> &'static str {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_ascii_lowercase();
    match ext.as_str() {
        "html" | "htm" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" | "map" => "application/json",
        "webmanifest" => "application/manifest+json",
        "wasm" => "application/wasm",
        "svg" => "image/svg+xml",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "ico" => "image/x-icon",
        "txt" => "text/plain; charset=utf-8",
        "woff" => "font/woff",
        "woff2" => "font/woff2",
        "ttf" => "font/ttf",
        _ => "application/octet-stream",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;

    fn site() -> TempDir {
        let d = TempDir::new("web");
        std::fs::create_dir_all(d.0.join("web/assets")).unwrap();
        std::fs::write(d.0.join("web/index.html"), b"<p>hi</p>").unwrap();
        std::fs::write(d.0.join("web/assets/app.js"), b"1").unwrap();
        std::fs::write(d.0.join("secret.txt"), b"no").unwrap();
        d
    }

    #[test]
    fn serves_files_and_the_index() {
        let d = site();
        let root = d.0.join("web");
        assert!(matches!(resolve(&root, "/"), Resolved::File(p) if p.ends_with("index.html")));
        assert!(matches!(resolve(&root, "/assets/app.js"), Resolved::File(_)));
        assert_eq!(resolve(&root, "/nope.css"), Resolved::Missing);
        assert_eq!(resolve(&root, "/assets"), Resolved::Missing, "no directory listing");
    }

    #[test]
    fn path_traversal_is_refused() {
        let d = site();
        let root = d.0.join("web");
        for p in ["/../secret.txt", "/assets/../../secret.txt", "/%2e%2e/secret.txt", "/%2E%2E%2Fsecret.txt", "/..%5Csecret.txt", "/a%00b", "/bad%zz"] {
            assert_eq!(resolve(&root, p), Resolved::Refused, "{p}");
        }
    }

    #[test]
    fn missing_index_is_missing() {
        let d = TempDir::new("web2");
        assert_eq!(resolve(&d.0, "/"), Resolved::Missing);
    }

    #[test]
    fn content_types() {
        assert_eq!(content_type(Path::new("a.JS")), "text/javascript; charset=utf-8");
        assert_eq!(content_type(Path::new("a.unknown")), "application/octet-stream");
    }
}
