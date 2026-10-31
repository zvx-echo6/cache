//! The `cs_open` config the server opens the core with, built from the data folder.
//!
//! `<data>/zims/*.zim` are the ZIM sources and every folder in `<data>/libraries/` is a library source. Search indexes live
//! under `<data>/index/<name>`. With both folders empty the config is `{"sources":[]}`, which the core opens fine.

use serde_json::{json, Value};
use std::io;
use std::path::Path;

fn entries(dir: &Path) -> io::Result<Vec<std::fs::DirEntry>> {
    match std::fs::read_dir(dir) {
        Ok(rd) => {
            let mut v = rd.collect::<io::Result<Vec<_>>>()?;
            v.sort_by_key(|e| e.file_name());
            Ok(v)
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(vec![]),
        Err(e) => Err(e),
    }
}

/// Create the folders the server keeps its data in.
pub fn make_folders(data: &Path) -> io::Result<()> {
    for d in ["zims", "libraries", "index"] {
        std::fs::create_dir_all(data.join(d))?;
    }
    Ok(())
}

pub fn core_config(data: &Path) -> io::Result<String> {
    let mut sources: Vec<Value> = vec![];
    let index = data.join("index");
    for e in entries(&data.join("zims"))? {
        let p = e.path();
        if p.is_file() && p.extension().is_some_and(|x| x.eq_ignore_ascii_case("zim")) {
            let name = p.file_stem().unwrap_or_default().to_string_lossy().into_owned();
            sources.push(json!({"kind": "zim", "path": p.to_string_lossy(), "index_dir": index.join(name).to_string_lossy()}));
        }
    }
    for e in entries(&data.join("libraries"))? {
        let p = e.path();
        if p.is_dir() {
            let name = e.file_name().to_string_lossy().into_owned();
            sources.push(json!({"kind": "library", "path": p.to_string_lossy(), "index_dir": index.join(name).to_string_lossy()}));
        }
    }
    Ok(json!({"sources": sources}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::TempDir;

    #[test]
    fn empty_data_folder_gives_no_sources() {
        let d = TempDir::new("cfg");
        assert_eq!(core_config(&d.0).unwrap(), r#"{"sources":[]}"#);
        make_folders(&d.0).unwrap();
        assert_eq!(core_config(&d.0).unwrap(), r#"{"sources":[]}"#);
    }

    #[test]
    fn zims_and_libraries_are_listed() {
        let d = TempDir::new("cfg2");
        make_folders(&d.0).unwrap();
        std::fs::write(d.0.join("zims/wiki.zim"), b"x").unwrap();
        std::fs::write(d.0.join("zims/notes.txt"), b"x").unwrap();
        std::fs::create_dir(d.0.join("libraries/books")).unwrap();
        let v: Value = serde_json::from_str(&core_config(&d.0).unwrap()).unwrap();
        let s = v["sources"].as_array().unwrap();
        assert_eq!(s.len(), 2);
        assert_eq!(s[0]["kind"], "zim");
        assert_eq!(s[1]["kind"], "library");
    }
}
