//! What is kept on disk: `instances.json` (the instances the user added) and `downloads/<instance>/<uuid>/` (the
//! downloaded video, its thumbnail and captions, and `manifest.json`, written last). Nothing else; tokens are never kept.

use crate::{Error, Result, Video};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct Instance {
    /// The host (and port, with `_`): `peertube.example`, `127.0.0.1_8080`. Names the instance everywhere.
    pub id: String,
    /// `https://peertube.example` (no path, no trailing slash).
    pub url: String,
    pub name: String,
    pub version: String,
    pub added_at: String,
}

impl Instance {
    pub fn to_json(&self) -> Value {
        json!({"id": self.id, "url": self.url, "name": self.name, "version": self.version, "added_at": self.added_at})
    }
}

/// The origin of what the user typed: `stream.example.org`, `https://stream.example.org/`, `https://x/w/abc` -> (`id`, `url`).
pub fn normalize(input: &str) -> Result<(String, String)> {
    let t = input.trim();
    if t.is_empty() {
        return Err(Error::bad_json("an instance address is required"));
    }
    let with_scheme = if t.contains("://") { t.to_string() } else { format!("https://{t}") };
    let u = url::Url::parse(&with_scheme).map_err(|e| Error::bad_json(format!("{t:?} is not an address: {e}")))?;
    let host = u.host_str().ok_or_else(|| Error::bad_json(format!("{t:?} has no host")))?;
    let host = host.to_ascii_lowercase();
    if u.scheme() != "https" && u.scheme() != "http" {
        return Err(Error::bad_json("an instance address starts with https://"));
    }
    let (id, origin) = match u.port() {
        Some(p) => (format!("{}_{p}", host.trim_matches(['[', ']'])), format!("{}://{host}:{p}", u.scheme())),
        None => (host.trim_matches(['[', ']']).to_string(), format!("{}://{host}", u.scheme())),
    };
    crate::http::check_url(&origin)?;
    Ok((id, origin))
}

/// Folder and file names built from an id must stay inside their folder.
pub fn safe_component(s: &str) -> Result<&str> {
    if s.is_empty() || s.len() > 200 || s == "." || s == ".." || s.contains(['/', '\\', ':', '\0']) {
        return Err(Error::bad_json(format!("{s:?} is not a valid name")));
    }
    Ok(s)
}

impl Video {
    fn instances_path(&self) -> PathBuf {
        self.dir.join("instances.json")
    }

    pub fn downloads_root(&self) -> PathBuf {
        self.dir.join("downloads")
    }

    pub fn video_dir(&self, instance_id: &str, uuid: &str) -> Result<PathBuf> {
        Ok(self.downloads_root().join(safe_component(instance_id)?).join(safe_component(uuid)?))
    }

    pub fn load_instances(&self) -> Result<Vec<Instance>> {
        match std::fs::read_to_string(self.instances_path()) {
            Ok(t) => {
                let v: Value = serde_json::from_str(&t).map_err(|e| Error::io(format!("instances.json is damaged: {e}")))?;
                serde_json::from_value(v["instances"].clone()).map_err(|e| Error::io(format!("instances.json is damaged: {e}")))
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(vec![]),
            Err(e) => Err(Error::io(format!("reading instances.json: {e}"))),
        }
    }

    pub fn save_instances(&self, list: &[Instance]) -> Result<()> {
        std::fs::create_dir_all(&self.dir).map_err(|e| Error::io(format!("creating {}: {e}", self.dir.display())))?;
        let body = json!({"instances": list}).to_string();
        write_atomic(&self.instances_path(), body.as_bytes())
    }

    /// The instance a request names: its id or its address.
    pub fn instance(&self, key: &str) -> Result<Instance> {
        let list = self.load_instances()?;
        let id = normalize(key).map(|n| n.0).unwrap_or_else(|_| key.to_string());
        list.into_iter()
            .find(|i| i.id == key || i.id == id)
            .ok_or_else(|| Error::not_found(format!("no instance {key:?}; add it first")))
    }

    /// `manifest.json` of a downloaded video, if it is downloaded.
    pub fn manifest(&self, instance_id: &str, uuid: &str) -> Result<Option<Value>> {
        let p = self.video_dir(instance_id, uuid)?.join("manifest.json");
        match std::fs::read_to_string(&p) {
            Ok(t) => Ok(serde_json::from_str(&t).ok()),
            Err(_) => Ok(None),
        }
    }

    pub fn is_downloaded(&self, instance_id: &str, uuid: &str) -> bool {
        matches!(self.manifest(instance_id, uuid), Ok(Some(_)))
    }
}

/// Write to a sibling temp file, then rename over the target.
pub fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = path.with_extension("tmp");
    std::fs::write(&tmp, bytes).map_err(|e| Error::io(format!("writing {}: {e}", tmp.display())))?;
    std::fs::rename(&tmp, path).map_err(|e| Error::io(format!("renaming to {}: {e}", path.display())))
}

pub fn dir_size(p: &Path) -> u64 {
    let mut total = 0;
    if let Ok(rd) = std::fs::read_dir(p) {
        for e in rd.flatten() {
            let m = match e.metadata() {
                Ok(m) => m,
                Err(_) => continue,
            };
            total += if m.is_dir() { dir_size(&e.path()) } else { m.len() };
        }
    }
    total
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalizes_what_people_type() {
        assert_eq!(normalize("Stream.Example.org").unwrap(), ("stream.example.org".into(), "https://stream.example.org".into()));
        assert_eq!(normalize(" https://stream.example.org/w/abc?x=1 ").unwrap().1, "https://stream.example.org");
        assert_eq!(normalize("http://127.0.0.1:9000/").unwrap(), ("127.0.0.1_9000".into(), "http://127.0.0.1:9000".into()));
        assert!(normalize("http://example.org").is_err());
        assert!(normalize("").is_err());
        assert!(normalize("ftp://x.org").is_err());
    }

    #[test]
    fn names_cannot_escape() {
        assert!(safe_component("../x").is_err());
        assert!(safe_component("a/b").is_err());
        assert!(safe_component("..").is_err());
        assert!(safe_component("c0ffee-1").is_ok());
    }
}
