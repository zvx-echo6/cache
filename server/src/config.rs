//! The folders the server keeps its data in, and its one setting file. The sources the core opens come from
//! `<data>/sources.json` when it exists, else from `<data>/app/docs/zims` and `libraries` (see `helper`).

use std::io;
use std::path::Path;

/// Create the folders the server keeps its data in.
pub fn make_folders(data: &Path) -> io::Result<()> {
    // `app/support` and `app/docs` are the app's support and documents folders (the helper's `fs.*` roots); the ZIMs and the
    // library folders the helper scans live in `app/docs`. Made by the server (user `cache`), so they belong to it.
    for d in ["zims", "libraries", "index", "app/support", "app/docs/zims", "app/docs/libraries"] {
        std::fs::create_dir_all(data.join(d))?;
    }
    Ok(())
}

/// The address people use to reach the server, for security keys: the `--public-origin` option, else `"public_origin"` in
/// `<data>/config.json`, else none.
pub fn public_origin(data: &Path, option: Option<&str>) -> Result<Option<String>, String> {
    if let Some(o) = option {
        return Ok(Some(o.to_string()));
    }
    let path = data.join("config.json");
    let text = match std::fs::read_to_string(&path) {
        Ok(t) => t,
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let v: serde_json::Value = serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(v["public_origin"].as_str().map(str::to_string))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;

    #[test]
    fn folders_are_made() {
        let d = TempDir::new("cfg");
        make_folders(&d.0).unwrap();
        make_folders(&d.0).unwrap();
        for f in ["zims", "libraries", "index", "app/support", "app/docs/zims", "app/docs/libraries"] {
            assert!(d.0.join(f).is_dir());
        }
    }

    #[test]
    fn public_origin_comes_from_the_option_then_the_config_file() {
        let d = TempDir::new("origin");
        assert_eq!(public_origin(&d.0, None).unwrap(), None);
        std::fs::write(d.0.join("config.json"), r#"{"public_origin":"https://cache.example.com"}"#).unwrap();
        assert_eq!(public_origin(&d.0, None).unwrap().as_deref(), Some("https://cache.example.com"));
        assert_eq!(public_origin(&d.0, Some("https://other.example.com")).unwrap().as_deref(), Some("https://other.example.com"));
        std::fs::write(d.0.join("config.json"), "{}").unwrap();
        assert_eq!(public_origin(&d.0, None).unwrap(), None);
        std::fs::write(d.0.join("config.json"), "nope").unwrap();
        assert!(public_origin(&d.0, None).is_err());
    }
}
