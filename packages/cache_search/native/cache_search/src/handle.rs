//! A handle: the list of open sources plus the last error.

use crate::error::{Error, Result};
use crate::index::{self, IndexState, OpenIndex};
use crate::libreg::{self, ShardCell};
use crate::library::{self, LibSlot, LibrarySettings, OpenCell};
use crate::zimsrc::{self, ZimSource};
use serde::Deserialize;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;

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
    /// Not in the header: a test hook that makes each library's background open sleep first.
    #[serde(default)]
    open_delay_ms: u64,
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
    /// A library being opened on a background thread. Turns into `Library` or `Failed` when the handle next
    /// looks and the open has finished; skipped by search meanwhile.
    Opening(OpeningLib),
    /// A library an `update_library` job owns (its shard is closed). Skipped by search; the handle opens it
    /// again, on a background thread, when it next looks and the update has ended.
    Updating(OpeningLib),
}

pub struct OpeningLib {
    pub path: PathBuf,
    pub index_dir: Option<PathBuf>,
    /// The settings object as given (compared on a later `set_sources` to see whether the open can be kept).
    pub given: Option<Value>,
    pub id: String,
    pub title: String,
    pub settings: Option<LibrarySettings>,
    /// The running open; `None` for an `Updating` source.
    cell: Option<Arc<OpenCell>>,
    /// For an `Updating` source: the cell the library's shard was in. The update job fills it again when it
    /// is done (the same shard for every handle), so this source can pick it up without opening the library.
    held: Option<Arc<ShardCell>>,
}

impl OpeningLib {
    /// A copy of the description (not of the running open).
    fn clone_info(&self) -> OpeningLib {
        OpeningLib {
            path: self.path.clone(),
            index_dir: self.index_dir.clone(),
            given: self.given.clone(),
            id: self.id.clone(),
            title: self.title.clone(),
            settings: self.settings.clone(),
            cell: None,
            held: None,
        }
    }

    /// Start opening the library on a background thread, or, when an update job owns it, list it as updating.
    fn start(
        path: PathBuf,
        index_dir: Option<PathBuf>,
        given: Option<Value>,
        id: String,
        title: String,
        settings: Option<LibrarySettings>,
        delay_ms: u64,
    ) -> Source {
        let cell = library::open_in_background(path.clone(), index_dir.clone(), given.clone(), delay_ms);
        let updating = cell.is_none();
        let o = OpeningLib { path, index_dir, given, id, title, settings, cell, held: None };
        if updating {
            Source::Updating(o)
        } else {
            Source::Opening(o)
        }
    }

    fn status(&self, updating: bool) -> Value {
        json!({
            "id": self.id, "kind": "library", "path": self.path.to_string_lossy(),
            "title": self.title, "language": Value::Null,
            "indexed": false, "building": false, "stale": false, "opening": !updating, "updating": updating,
            "docs": 0,
            "embedding_model": match &self.settings {
                Some(st) if !st.embedding.model.is_empty() => json!(st.embedding.model),
                _ => Value::Null,
            },
            "library_id": self.id, "keyword_source": Value::Null,
            "settings": self.settings.as_ref().map(|st| st.to_json()).unwrap_or(Value::Null),
            "error": Value::Null,
        })
    }
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
            ReuseLib(usize, Option<PathBuf>, LibrarySettings, Option<Value>),
            ReuseOpening(usize, Option<PathBuf>),
            /// A library to open on a background thread (started only once the whole call has succeeded).
            OpenLib { path: PathBuf, index_dir: Option<PathBuf>, given: Option<Value>, id: String, title: String, settings: Option<LibrarySettings> },
            New(Source),
        }
        self.poll_opening();
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
                    // A bad settings object is a malformed config: the whole call fails, before anything starts.
                    let parsed = sc.settings.as_ref().map(LibrarySettings::parse).transpose()?;
                    let existing = self.sources.iter().position(|s| match s {
                        Source::Library(l) => l.path == path,
                        Source::Opening(o) | Source::Updating(o) => o.path == path && o.given == sc.settings,
                        _ => false,
                    });
                    let (id, item) = match existing {
                        Some(i) => match &self.sources[i] {
                            Source::Library(l) => {
                                // Settings errors fail the whole call, before anything is replaced.
                                let st = library::resolve_settings(&*l.shard.get()?, &path, sc.settings.as_ref())?;
                                (Some(st.library_id.clone()), Plan::ReuseLib(i, index_dir, st, sc.settings.clone()))
                            }
                            Source::Opening(o) | Source::Updating(o) => (Some(o.id.clone()), Plan::ReuseOpening(i, index_dir)),
                            _ => unreachable!(),
                        },
                        None if !path.is_dir() => {
                            // Cheap to know at once: report it like any other library that cannot be opened.
                            let error = Error::not_found(format!("library folder {} not found", path.display()));
                            let title = stem_title(&path);
                            (None, Plan::New(Source::Failed { kind: "library", path, title, error }))
                        }
                        None => {
                            let id = parsed.as_ref().map(|s| s.library_id.clone()).unwrap_or_else(|| library::dir_name(&path));
                            let title = parsed.as_ref().map(|s| s.title.clone()).unwrap_or_else(|| id.clone());
                            (
                                Some(id.clone()),
                                Plan::OpenLib { path, index_dir, given: sc.settings.clone(), id, title, settings: parsed },
                            )
                        }
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
                Plan::ReuseLib(i, index_dir, settings, given) => {
                    let mut s = old[i].take().expect("reused twice");
                    if let Source::Library(l) = &mut s {
                        l.index_dir = index_dir;
                        l.given = given;
                        l.kw = None;
                        l.set_settings(settings);
                    }
                    s
                }
                Plan::ReuseOpening(i, index_dir) => {
                    let mut s = old[i].take().expect("reused twice");
                    if let Source::Opening(o) | Source::Updating(o) = &mut s {
                        o.index_dir = index_dir;
                    }
                    s
                }
                Plan::OpenLib { path, index_dir, given, id, title, settings } => {
                    OpeningLib::start(path, index_dir, given, id, title, settings, cfg.open_delay_ms)
                }
                Plan::New(s) => s,
            })
            .collect();
        self.snippet_chars = cfg.snippet_chars;
        self.candidates_per_list = cfg.candidates_per_list;
        self.min_term_coverage = cfg.min_term_coverage;
        Ok(())
    }

    /// Bring the library sources up to date with what happened since the last call: an open that finished becomes
    /// `Library` (or `Failed`); a library an `update_library` job owns becomes `Updating` (its shard is dropped);
    /// a library whose update has ended, or that an update changed while it was opening, is opened again.
    pub fn poll_opening(&mut self) {
        for s in self.sources.iter_mut() {
            let next: Option<Source> = match s {
                Source::Opening(o) => {
                    let entry = libreg::entry_for(&o.path);
                    match o.cell.as_ref().and_then(|c| c.take()) {
                        Some(Ok(mut slot)) => {
                            slot.index_dir = o.index_dir.clone();
                            slot.given = o.given.clone();
                            if entry.updating() {
                                Some(Source::Updating(OpeningLib { cell: None, held: Some(slot.shard.clone()), ..o.clone_info() }))
                            } else if slot.seen_gen != entry.generation() {
                                // an update changed the files while this was opening: take the shard it handed
                                // back, or open the library again
                                if slot.shard.is_open() && slot.refresh_after_update() {
                                    Some(Source::Library(slot))
                                } else {
                                Some(OpeningLib::start(o.path.clone(), o.index_dir.clone(), o.given.clone(), o.id.clone(), o.title.clone(), o.settings.clone(), 0))
                                }
                            } else {
                                Some(Source::Library(slot))
                            }
                        }
                        Some(Err(error)) => {
                            if entry.updating() {
                                Some(Source::Updating(OpeningLib { cell: None, ..o.clone_info() }))
                            } else {
                                Some(Source::Failed { kind: "library", path: o.path.clone(), title: stem_title(&o.path), error })
                            }
                        }
                        None if entry.updating() => Some(Source::Updating(OpeningLib { cell: None, ..o.clone_info() })),
                        None => None,
                    }
                }
                Source::Library(l) => {
                    if l.entry.updating() {
                        Some(Source::Updating(OpeningLib {
                            path: l.path.clone(),
                            index_dir: l.index_dir.clone(),
                            given: l.given.clone(),
                            id: l.settings.library_id.clone(),
                            title: l.settings.title.clone(),
                            settings: l.given.as_ref().map(|_| l.settings.clone()),
                            cell: None,
                            held: Some(l.shard.clone()),
                        }))
                    } else if l.entry.generation() != l.seen_gen {
                        if l.shard.is_open() && l.refresh_after_update() {
                            None
                        } else {
                        Some(OpeningLib::start(
                            l.path.clone(),
                            l.index_dir.clone(),
                            l.given.clone(),
                            l.settings.library_id.clone(),
                            l.settings.title.clone(),
                            l.given.as_ref().map(|_| l.settings.clone()),
                            0,
                        ))
                        }
                    } else {
                        None
                    }
                }
                Source::Updating(o) => {
                    let entry = libreg::entry_for(&o.path);
                    if entry.updating() {
                        None
                    } else if let Some(slot) = o.held.take().filter(|c| c.is_open()).and_then(|c| {
                        library::slot_from_cell(&o.path, o.index_dir.clone(), o.given.clone(), c, entry.clone())
                    }) {
                        // the update handed the library's shard back: no second open
                        Some(Source::Library(slot))
                    } else {
                        Some(OpeningLib::start(o.path.clone(), o.index_dir.clone(), o.given.clone(), o.id.clone(), o.title.clone(), o.settings.clone(), 0))
                    }
                }
                _ => None,
            };
            if let Some(n) = next {
                *s = n;
            }
        }
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
        self.poll_opening();
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
                        "indexed": indexed, "building": building, "stale": stale, "opening": false, "updating": false,
                        "docs": docs, "embedding_model": Value::Null, "error": error,
                    })
                }
                Source::Failed { kind, path, title, error } => json!({
                    "id": Value::Null, "kind": kind, "path": path.to_string_lossy(),
                    "title": title, "language": Value::Null,
                    "indexed": false, "building": false, "stale": false, "opening": false, "updating": false,
                    "docs": 0, "embedding_model": Value::Null,
                    "error": {"code": error.code.as_str(), "message": error.message},
                }),
                // `indexed` is the keyword index: the library's own scored index or the built device index.
                // Still opening: what is known without the shard. Its settings are shown when they were given.
                Source::Opening(o) => o.status(false),
                Source::Updating(o) => o.status(true),
                Source::Library(l) => {
                    let st = l.device_state();
                    let wanted = l.keyword_wanted();
                    let source = l.keyword_source();
                    let (building, stale) = (wanted && st == IndexState::Building, wanted && st == IndexState::Stale);
                    json!({
                        "id": l.settings.library_id, "kind": "library", "path": l.path.to_string_lossy(),
                        "title": l.settings.title, "language": Value::Null,
                        "indexed": source != "none", "building": building, "stale": stale, "opening": false, "updating": false,
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
