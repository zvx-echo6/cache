//! A handle: the list of open sources plus the last error.

use crate::error::{Error, Result};
use crate::index::{self, IndexState, OpenIndex};
use crate::library::{self, LibSlot, LibrarySettings};
use crate::zimsrc::{self, ZimSource};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;

#[derive(Debug, Deserialize)]
struct SourceCfg {
    kind: String,
    path: String,
    index_dir: Option<String>,
    /// Library settings (the v1 settings object); optional, guessed when absent.
    #[serde(default)]
    settings: Option<Value>,
}

#[derive(Debug, Deserialize)]
struct Config {
    sources: Vec<SourceCfg>,
    #[serde(default = "default_snippet_chars")]
    snippet_chars: u32,
    #[serde(default = "default_candidates")]
    candidates_per_list: u32,
    #[serde(default = "default_min_cov")]
    min_term_coverage: f32,
}

fn default_min_cov() -> f32 {
    0.5
}

fn default_snippet_chars() -> u32 {
    400
}
fn default_candidates() -> u32 {
    50
}

/// An open ZIM plus where its index lives and the opened index (reopened when it changes on disk).
pub struct ZimSlot {
    pub src: ZimSource,
    pub index_dir: Option<PathBuf>,
    pub open: Option<OpenIndex>,
}

impl ZimSlot {
    pub fn state(&self) -> IndexState {
        index::index_state(self.index_dir.as_deref(), &self.src.id)
    }

    /// The opened index if (and only if) it is `done`. `None` when missing, stale, incomplete or building.
    pub fn searchable(&mut self) -> Result<Option<&OpenIndex>> {
        let IndexState::Done(meta) = self.state() else {
            self.open = None;
            return Ok(None);
        };
        let dir = self.index_dir.clone().expect("done implies index_dir");
        if self.open.as_ref().map(|o| o.is_outdated(&dir)).unwrap_or(true) {
            self.open = None;
            self.open = Some(OpenIndex::open(&dir, &meta.tokenizer)?);
        }
        Ok(self.open.as_ref())
    }
}

pub enum Source {
    Zim(ZimSlot),
    /// A ZIM that could not be opened (missing file, SD card out, bad format). Retried on every
    /// `set_sources`; reported by `cs_status`; skipped by search.
    Failed { kind: &'static str, path: PathBuf, title: String, error: Error },
    /// A library: a Qdrant shard opened read-only.
    Library(LibSlot),
}

pub struct Handle {
    pub sources: Vec<Source>,
    pub snippet_chars: u32,
    pub candidates_per_list: u32,
    pub min_term_coverage: f32,
    pub last_error: Option<Error>,
}

fn stem_title(path: &std::path::Path) -> String {
    path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

impl Handle {
    pub fn open(config_json: &str) -> Result<Handle> {
        let mut h = Handle { sources: vec![], snippet_chars: 400, candidates_per_list: 50, min_term_coverage: 0.5, last_error: None };
        h.set_sources(config_json)?;
        Ok(h)
    }

    /// Replace the source list. Malformed JSON, an unknown kind or a duplicate source id fail the whole call and
    /// leave the old list. A ZIM that cannot be opened does not: it becomes a `Failed` source. ZIMs already open
    /// (same path) are reused rather than reopened.
    pub fn set_sources(&mut self, config_json: &str) -> Result<()> {
        enum Plan {
            Reuse(usize, Option<PathBuf>),
            ReuseLib(usize, Option<PathBuf>, LibrarySettings),
            New(Source),
        }
        let cfg: Config = serde_json::from_str(config_json)?;
        let mut plan: Vec<Plan> = Vec::new();
        let mut ids: Vec<String> = Vec::new();
        for sc in &cfg.sources {
            let path = PathBuf::from(&sc.path);
            let index_dir = sc.index_dir.as_ref().map(PathBuf::from);
            match sc.kind.as_str() {
                "zim" => {
                    let existing = self
                        .sources
                        .iter()
                        .position(|s| matches!(s, Source::Zim(z) if z.src.path == path));
                    let (id, item) = match existing {
                        Some(i) => match &self.sources[i] {
                            Source::Zim(z) => (Some(z.src.id.clone()), Plan::Reuse(i, index_dir)),
                            _ => unreachable!(),
                        },
                        None => match ZimSource::open(&path) {
                            Ok(z) => {
                                let id = z.id.clone();
                                (Some(id), Plan::New(Source::Zim(ZimSlot { src: z, index_dir, open: None })))
                            }
                            Err(error) => {
                                let title = stem_title(&path);
                                (None, Plan::New(Source::Failed { kind: "zim", path, title, error }))
                            }
                        },
                    };
                    if let Some(id) = id {
                        if ids.contains(&id) {
                            return Err(Error::bad_json(format!("duplicate source id {id} ({})", sc.path)));
                        }
                        ids.push(id);
                    }
                    plan.push(item);
                }
                "library" => {
                    let existing = self
                        .sources
                        .iter()
                        .position(|s| matches!(s, Source::Library(l) if l.path == path));
                    let (id, item) = match existing {
                        Some(i) => {
                            let Source::Library(l) = &self.sources[i] else { unreachable!() };
                            // Settings errors fail the whole call, before anything is replaced.
                            let st = library::resolve_settings(&l.shard, &path, sc.settings.as_ref())?;
                            (Some(st.library_id.clone()), Plan::ReuseLib(i, index_dir, st))
                        }
                        None => match library::open_library(&path, index_dir, sc.settings.as_ref()) {
                            Ok(l) => (Some(l.id().to_string()), Plan::New(Source::Library(l))),
                            // A bad settings object is a malformed config; anything else is a library that
                            // cannot be opened now (reported by cs_status, retried on the next set_sources).
                            Err(error) if error.code == crate::error::ErrorCode::BadJson => return Err(error),
                            Err(error) => {
                                let title = stem_title(&path);
                                (None, Plan::New(Source::Failed { kind: "library", path, title, error }))
                            }
                        },
                    };
                    if let Some(id) = id {
                        if ids.contains(&id) {
                            return Err(Error::bad_json(format!("duplicate source id {id} ({})", sc.path)));
                        }
                        ids.push(id);
                    }
                    plan.push(item);
                }
                other => return Err(Error::bad_json(format!("unknown source kind {other:?}"))),
            }
        }
        // Success: commit. Move reused sources out of the old list.
        let mut old: Vec<Option<Source>> = std::mem::take(&mut self.sources).into_iter().map(Some).collect();
        self.sources = plan
            .into_iter()
            .map(|p| match p {
                Plan::Reuse(i, index_dir) => {
                    let mut s = old[i].take().expect("reused twice");
                    if let Source::Zim(z) = &mut s {
                        if z.index_dir != index_dir {
                            z.index_dir = index_dir;
                            z.open = None;
                        }
                    }
                    s
                }
                Plan::ReuseLib(i, index_dir, settings) => {
                    let mut s = old[i].take().expect("reused twice");
                    if let Source::Library(l) = &mut s {
                        l.index_dir = index_dir;
                        l.kw = None;
                        l.set_settings(settings);
                    }
                    s
                }
                Plan::New(s) => s,
            })
            .collect();
        self.snippet_chars = cfg.snippet_chars;
        self.candidates_per_list = cfg.candidates_per_list;
        self.min_term_coverage = cfg.min_term_coverage;
        Ok(())
    }

    pub fn zim(&self, id: &str) -> Result<&ZimSource> {
        let id = id.to_ascii_lowercase();
        self.sources
            .iter()
            .find_map(|s| match s {
                Source::Zim(z) if z.src.id == id => Some(&z.src),
                _ => None,
            })
            .ok_or_else(|| Error::not_found(format!("no zim source {id:?}")))
    }

    pub fn status_json(&mut self) -> String {
        let list: Vec<Value> = self
            .sources
            .iter_mut()
            .map(|s| match s {
                Source::Zim(z) => {
                    let st = z.state();
                    let (mut indexed, building, stale) = (
                        matches!(st, IndexState::Done(_)),
                        st == IndexState::Building,
                        st == IndexState::Stale,
                    );
                    let mut docs = z.src.entry_count();
                    let mut error = Value::Null;
                    if indexed {
                        match z.searchable() {
                            Ok(Some(o)) => docs = o.docs,
                            Ok(None) => indexed = false,
                            Err(e) => {
                                indexed = false;
                                error = json!({"code": e.code.as_str(), "message": e.message});
                            }
                        }
                    }
                    json!({
                        "id": z.src.id, "kind": "zim", "path": z.src.path.to_string_lossy(),
                        "title": z.src.title, "language": z.src.language,
                        "indexed": indexed, "building": building, "stale": stale,
                        "docs": docs, "embedding_model": Value::Null, "error": error,
                    })
                }
                Source::Failed { kind, path, title, error } => json!({
                    "id": Value::Null, "kind": kind, "path": path.to_string_lossy(),
                    "title": title, "language": Value::Null,
                    "indexed": false, "building": false, "stale": false,
                    "docs": 0, "embedding_model": Value::Null,
                    "error": {"code": error.code.as_str(), "message": error.message},
                }),
                // `indexed` is the keyword index: the library's own scored index or the built device index.
                Source::Library(l) => {
                    let st = l.device_state();
                    let wanted = l.keyword_wanted();
                    let source = l.keyword_source();
                    let (building, stale) = (wanted && st == IndexState::Building, wanted && st == IndexState::Stale);
                    json!({
                        "id": l.settings.library_id, "kind": "library", "path": l.path.to_string_lossy(),
                        "title": l.settings.title, "language": Value::Null,
                        "indexed": source != "none", "building": building, "stale": stale,
                        "docs": l.docs,
                        "embedding_model": if l.settings.embedding.model.is_empty() { Value::Null } else { json!(l.settings.embedding.model) },
                        "library_id": l.settings.library_id, "keyword_source": source,
                        "settings": l.settings.to_json(), "error": Value::Null,
                    })
                }
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
    fn missing_library_does_not_fail_the_handle() {
        let mut h = Handle::open(r#"{"sources":[{"kind":"library","path":"/nonexistent/recon","index_dir":"/x/i"}]}"#).unwrap();
        let v: Value = serde_json::from_str(&h.status_json()).unwrap();
        let s = &v["sources"][0];
        assert_eq!(s["kind"], "library");
        assert_eq!(s["indexed"], false);
        assert_eq!(s["title"], "recon");
        assert!(s["id"].is_null());
        assert_eq!(s["error"]["code"], "not_found");
        // bad settings are a whole-call failure
        let bad = r#"{"sources":[{"kind":"library","path":"/nonexistent/recon","settings":{"library_id":"r"}}]}"#;
        assert_eq!(h.set_sources(bad).unwrap_err().code, ErrorCode::BadJson);
        assert_eq!(h.sources.len(), 1);
    }

    #[test]
    fn missing_zim_does_not_fail_the_handle() {
        let mut h = Handle::open(r#"{"sources":[{"kind":"zim","path":"/nonexistent/a.zim","index_dir":"/x"}]}"#).unwrap();
        let v: Value = serde_json::from_str(&h.status_json()).unwrap();
        let s = &v["sources"][0];
        assert_eq!(s["kind"], "zim");
        assert_eq!(s["indexed"], false);
        assert_eq!(s["title"], "a");
        assert!(s["id"].is_null());
        assert_eq!(s["error"]["code"], "not_found");
        assert!(s["error"]["message"].as_str().unwrap().contains("a.zim"));
        // malformed JSON is still a whole-call failure and keeps the old list
        assert_eq!(h.set_sources("{").unwrap_err().code, ErrorCode::BadJson);
        assert_eq!(h.sources.len(), 1);
        assert_eq!(
            h.set_sources(r#"{"sources":[{"kind":"zap","path":"/a"}]}"#).unwrap_err().code,
            ErrorCode::BadJson
        );
        assert_eq!(h.sources.len(), 1);
    }
}
