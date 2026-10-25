//! A handle: the list of open sources plus the last error.

use crate::error::{Error, Result};
use crate::zimsrc::{self, ZimSource};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
struct SourceCfg {
    kind: String,
    path: String,
    #[allow(dead_code)]
    index_dir: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Config {
    sources: Vec<SourceCfg>,
    #[serde(default = "default_snippet_chars")]
    snippet_chars: u32,
    #[serde(default = "default_candidates")]
    candidates_per_list: u32,
}

fn default_snippet_chars() -> u32 {
    400
}
fn default_candidates() -> u32 {
    50
}

pub enum Source {
    Zim(ZimSource),
    /// Recorded only in this slice: packs are not read yet.
    Pack { path: PathBuf, title: String },
}

pub struct Handle {
    pub sources: Vec<Source>,
    pub snippet_chars: u32,
    pub candidates_per_list: u32,
    pub last_error: Option<Error>,
}

impl Handle {
    pub fn open(config_json: &str) -> Result<Handle> {
        let mut h = Handle { sources: vec![], snippet_chars: 400, candidates_per_list: 50, last_error: None };
        h.set_sources(config_json)?;
        Ok(h)
    }

    /// Replace the source list. All-or-nothing: on error the old list stays. ZIMs already open
    /// (same path) are reused rather than reopened. A source id (ZIM UUID) may appear only once.
    pub fn set_sources(&mut self, config_json: &str) -> Result<()> {
        enum Plan {
            Reuse(usize),
            New(Source),
        }
        let cfg: Config = serde_json::from_str(config_json)?;
        let mut plan: Vec<Plan> = Vec::new();
        let mut ids: Vec<String> = Vec::new();
        for sc in &cfg.sources {
            let path = PathBuf::from(&sc.path);
            match sc.kind.as_str() {
                "zim" => {
                    let existing = self
                        .sources
                        .iter()
                        .position(|s| matches!(s, Source::Zim(z) if z.path == path));
                    let (id, item) = match existing {
                        Some(i) => match &self.sources[i] {
                            Source::Zim(z) => (z.id.clone(), Plan::Reuse(i)),
                            _ => unreachable!(),
                        },
                        None => {
                            let z = ZimSource::open(&path)?;
                            (z.id.clone(), Plan::New(Source::Zim(z)))
                        }
                    };
                    if ids.contains(&id) {
                        return Err(Error::bad_json(format!("duplicate source id {id} ({})", sc.path)));
                    }
                    ids.push(id);
                    plan.push(item);
                }
                "pack" => {
                    let title = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
                    plan.push(Plan::New(Source::Pack { path, title }));
                }
                other => return Err(Error::bad_json(format!("unknown source kind {other:?}"))),
            }
        }
        // Success: commit. Move reused sources out of the old list.
        let mut old: Vec<Option<Source>> = std::mem::take(&mut self.sources).into_iter().map(Some).collect();
        self.sources = plan
            .into_iter()
            .map(|p| match p {
                Plan::Reuse(i) => old[i].take().expect("reused twice"),
                Plan::New(s) => s,
            })
            .collect();
        self.snippet_chars = cfg.snippet_chars;
        self.candidates_per_list = cfg.candidates_per_list;
        Ok(())
    }

    pub fn zim(&self, id: &str) -> Result<&ZimSource> {
        let id = id.to_ascii_lowercase();
        self.sources
            .iter()
            .find_map(|s| match s {
                Source::Zim(z) if z.id == id => Some(z),
                _ => None,
            })
            .ok_or_else(|| Error::not_found(format!("no zim source {id:?}")))
    }

    pub fn status_json(&self) -> String {
        let list: Vec<Value> = self
            .sources
            .iter()
            .map(|s| match s {
                Source::Zim(z) => json!({
                    "id": z.id, "kind": "zim", "path": z.path.to_string_lossy(),
                    "title": z.title, "language": z.language,
                    "indexed": false, "building": false, "stale": false,
                    "docs": z.entry_count(), "embedding_model": Value::Null,
                }),
                Source::Pack { path, title } => json!({
                    "id": Value::Null, "kind": "pack", "path": path.to_string_lossy(),
                    "title": title, "language": Value::Null,
                    "indexed": false, "building": false, "stale": false,
                    "docs": 0, "embedding_model": Value::Null,
                }),
            })
            .collect();
        json!({ "sources": list }).to_string()
    }

    pub fn zim_get(&self, address: &str) -> Result<zimsrc::RawEntry> {
        let a = zimsrc::parse_address(address)?;
        self.zim(&a.id)?.get(&a.path)
    }

    pub fn zim_main_page(&self, zim_id: &str) -> Result<String> {
        let z = self.zim(zim_id)?;
        let p = z.main_page_path()?;
        Ok(json!({ "address": zimsrc::format_address(&z.id, &p) }).to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::error::ErrorCode;

    #[test]
    fn bad_config_is_bad_json() {
        for bad in ["", "{", "[]", "{}", r#"{"sources":[{"kind":"zim"}]}"#, r#"{"sources":[{"kind":"x","path":"/a"}]}"#] {
            let e = Handle::open(bad).err().unwrap();
            assert_eq!(e.code, ErrorCode::BadJson, "{bad}");
        }
    }

    #[test]
    fn pack_is_recorded_unindexed() {
        let h = Handle::open(r#"{"sources":[{"kind":"pack","path":"/x/recon.cachepack","index_dir":"/x/i"}]}"#).unwrap();
        let v: Value = serde_json::from_str(&h.status_json()).unwrap();
        let s = &v["sources"][0];
        assert_eq!(s["kind"], "pack");
        assert_eq!(s["indexed"], false);
        assert_eq!(s["title"], "recon");
        assert!(s["id"].is_null());
    }

    #[test]
    fn missing_zim_fails_open_and_keeps_old_list_on_set() {
        let e = Handle::open(r#"{"sources":[{"kind":"zim","path":"/nonexistent/a.zim"}]}"#).err().unwrap();
        assert_eq!(e.code, ErrorCode::NotFound);
        let mut h = Handle::open(r#"{"sources":[{"kind":"pack","path":"/p/a.cachepack"}]}"#).unwrap();
        assert!(h.set_sources(r#"{"sources":[{"kind":"zim","path":"/nonexistent/a.zim"}]}"#).is_err());
        assert_eq!(h.sources.len(), 1);
    }
}
