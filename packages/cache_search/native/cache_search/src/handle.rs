//! A handle: the list of open sources plus the last error.

use crate::budget::{self, ZimBudget};
use crate::error::{Error, Result};
use crate::idxsnap::{self, SnapSlot};
use crate::index::{self, IndexState, OpenIndex};
use crate::libreg::{self, ShardCell};
use crate::tools::QueryEmbedder;
use crate::library::{self, LibSlot, LibrarySettings, OpenCell};
use crate::kwslot::KwSlot;
use crate::pdfindex::{self, PdfIndex};
use crate::web::{WebSearchTool, WebState};
use crate::zimsrc::{self, ZimSource};
use cache_tool::{Location, NoSavedPlaces, SavedPlaces, Tool};
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
    /// ZIM sources: `false` keeps the ZIM on its Tantivy index even when it has a built-in Xapian index (default
    /// `true`; see zimx.rs). For comparing the two engines and for tests of the Tantivy path.
    #[serde(default)]
    builtin_index: Option<bool>,
}

#[derive(Debug, Deserialize)]
struct Config {
    sources: Vec<SourceCfg>,
    /// Saved places and live data (see ext.rs). A later cs_set_sources config without these keeps the earlier ones.
    #[serde(default)]
    user: Option<crate::ext::UserCfg>,
    #[serde(default)]
    live: Option<cache_live::LiveCfg>,
    /// Places packs: registers the nearby and locate tools (see ext.rs).
    #[serde(default)]
    places: Option<cache_places::PlacesCfg>,
    /// The navigate tool: Valhalla tiles and shim, and the off-road pack (see cache_navigate's config.rs).
    #[serde(default)]
    routing: Option<cache_navigate::NavigateCfg>,
    /// Road tiles by region (cache_regions): the navigate tool routes on its folder and has it fetch a route's tiles first.
    #[serde(default)]
    regions: Option<cache_regions::Config>,
    #[serde(default)]
    video: Option<cache_video::VideoCfg>,
    /// Map layers: see ext.rs and DESIGN-LAYERS.md.
    #[serde(default)]
    layers: Option<cache_layers::LayersCfg>,
    /// The notebooks' database and media folder (cs_notebook; see ext.rs).
    #[serde(default)]
    notebook: Option<cache_notebook::NotebookCfg>,
    #[serde(default = "default_snippet_chars")]
    snippet_chars: u32,
    #[serde(default = "default_candidates")]
    candidates_per_list: u32,
    #[serde(default = "default_min_cov")]
    min_term_coverage: f32,
    #[serde(default = "default_min_rel")]
    min_relevance: f32,
    /// Open libzim on every ZIM source that has a built-in index, on background threads, as soon as the sources are
    /// set, so the first search does not pay for the opens (default `true`, but `false` on Android). Only as many
    /// archives are opened as fit in `zim_budget_mb`, smallest first. `false` leaves them to the first search.
    #[serde(default = "default_prewarm")]
    prewarm: bool,
    /// Memory budget in MiB for open libzim archives with their searchers and caches (default 384 on Android, 1024 elsewhere;
    /// 0 keeps none open, each query opens and closes its archives). `searcher_budget_mb` is the old name of this key and is
    /// still read when `zim_budget_mb` is absent. See budget.rs and DESIGN.md "Memory budget".
    #[serde(default)]
    zim_budget_mb: Option<u64>,
    #[serde(default)]
    searcher_budget_mb: Option<u64>,
    /// Dirents each open archive's dirent cache may hold (default 512, libzim's own default).
    #[serde(default)]
    zim_dirent_cache: Option<u64>,
    /// Limit in MiB (of compressed cluster data) of libzim's cluster cache, shared by all open archives in the process (default
    /// 4; libzim's own default is 16). What it holds is decompressed, about 8 times its limit, and that is taken off the top
    /// of `zim_budget_mb` (`budget::reserved_cost`).
    #[serde(default)]
    zim_cluster_cache_mb: Option<u64>,
    /// The folder the app keeps its syncable indexes in (`<indexes_dir>/zim-pdf/<zim uuid>/snap/...`). Without it ZIMs have no
    /// PDF index attached. Each `set_sources` replaces it.
    #[serde(default)]
    indexes_dir: Option<String>,
    /// Not in the header: a test hook that makes each library's background open sleep first.
    #[serde(default)]
    open_delay_ms: u64,
}

fn default_prewarm() -> bool {
    budget::prewarm_default(cfg!(any(target_os = "android", target_os = "ios")))
}

/// Threads that open libzim archives in the background after `set_sources`.
const PREWARM_THREADS: usize = 4;

fn default_min_cov() -> f32 {
    0.5
}

fn default_min_rel() -> f32 {
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
    /// The `indexes_dir` of the sources config (set by the handle): where this ZIM's snapshot lives.
    pub indexes_dir: Option<PathBuf>,
    /// The ZIM's keyword index snapshot (kind `zim`), once one is published and verified.
    pub snap: SnapSlot<OpenIndex>,
    /// Use the ZIM's built-in Xapian index when it has one (the source's `builtin_index`, default true).
    pub builtin: bool,
}

impl ZimSlot {
    /// libzim's handle when this source keyword-searches through the ZIM's own Xapian index.
    pub fn xapian(&self) -> Option<std::sync::Arc<crate::zimx::Zimx>> {
        if self.builtin { self.src.xapian() } else { None }
    }

    /// True when this source keyword-searches through the ZIM's own Xapian index (no libzim open needed to say so).
    pub fn has_xapian(&self) -> bool {
        self.builtin && self.src.has_xapian()
    }

    /// libzim's handle when this source suggests from the ZIM's title index.
    pub fn title_index(&self) -> Option<std::sync::Arc<crate::zimx::Zimx>> {
        if self.builtin { self.src.title_index() } else { None }
    }

    pub fn new(src: ZimSource, index_dir: Option<PathBuf>, builtin: bool) -> ZimSlot {
        ZimSlot {
            src,
            index_dir,
            open: None,
            indexes_dir: None,
            snap: SnapSlot::new(idxsnap::KIND_ZIM, |dir, m| {
                OpenIndex::open(dir, m.tokenizer.as_ref().map(|t| t.name.as_str()).unwrap_or("en_stem"))
            }),
            builtin,
        }
    }

    /// Look at the snapshot folder again (a pick runs on a background thread). When a snapshot has just become the one in use,
    /// the old index it was sealed from is removed.
    pub fn refresh_snapshot(&mut self) {
        if let Some(name) = self.snap.refresh(self.indexes_dir.as_deref(), &self.src.id) {
            self.open = None;
            if let Some(root) = &self.indexes_dir {
                idxsnap::finish_seal(&idxsnap::dir_for(root, idxsnap::KIND_ZIM, &self.src.id), &name);
            }
        }
    }

    /// State of the keyword index: a snapshot in use is `Done`; else a build in `.build/`; else the index in `index_dir`.
    pub fn state(&self) -> IndexState {
        if let Some(s) = self.snap.ready() {
            return IndexState::Done(idxsnap::meta_of(&s.manifest, &self.src.id));
        }
        if let Some(root) = &self.indexes_dir {
            if idxsnap::build_live(root, idxsnap::KIND_ZIM, &self.src.id) {
                return IndexState::Building;
            }
        }
        self.legacy_state()
    }

    /// State of the index in `index_dir` alone.
    pub fn legacy_state(&self) -> IndexState {
        index::index_state(self.index_dir.as_deref(), &self.src.id)
    }

    /// The opened index if (and only if) it is `done`: the snapshot when one is in use, else the one in `index_dir`. `None` when
    /// missing, stale, incomplete or building.
    pub fn searchable(&mut self) -> Result<Option<&OpenIndex>> {
        self.refresh_snapshot();
        if self.snap.ready().is_some() {
            self.open = None;
            return Ok(self.snap.ready().map(|s| &s.index));
        }
        let IndexState::Done(meta) = self.legacy_state() else {
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

    /// `cs_status`'s `index` for this ZIM: where its keyword index is (`location` "snapshot", "legacy" or "none"), the snapshot in
    /// use, the format, and `needs_seal` (only present, true) when only an index in the old location exists.
    pub fn index_info(&self) -> Value {
        index_info_json(
            idxsnap::KIND_ZIM,
            index::INDEX_FORMAT,
            self.snap.ready().map(|s| (s.name.as_str(), s.dir.as_path())),
            self.snap.opening(),
            &self.legacy_state(),
            self.index_dir.as_deref(),
            self.indexes_dir.is_some(),
        )
    }
}

/// The `index` object of `cs_status` (see `ZimSlot::index_info`).
pub fn index_info_json(
    kind: &str,
    format: u32,
    snapshot: Option<(&str, &std::path::Path)>,
    opening: bool,
    legacy: &IndexState,
    legacy_dir: Option<&std::path::Path>,
    has_indexes_dir: bool,
) -> Value {
    let path = |p: &std::path::Path| json!(p.to_string_lossy());
    if let Some((name, dir)) = snapshot {
        return json!({"kind": kind, "location": "snapshot", "snapshot": name, "format": format, "dir": path(dir)});
    }
    if matches!(legacy, IndexState::Done(_)) {
        let mut v = json!({"kind": kind, "location": "legacy", "snapshot": Value::Null, "format": format,
            "dir": legacy_dir.map(path).unwrap_or(Value::Null)});
        if has_indexes_dir && !opening {
            v["needs_seal"] = json!(true);
        }
        return v;
    }
    json!({"kind": kind, "location": "none", "snapshot": Value::Null, "format": format, "dir": Value::Null})
}

/// The PDF index of one loaded ZIM (`<zim name>.pdfindex/`, see pdfindex.rs): its newest usable snapshot, verified and opened
/// on a background thread. Searched with the ZIM; not a source of its own (`cs_status` shows it on the ZIM's entry).
pub struct PdfSlot {
    pub zim_id: String,
    pub zim_title: String,
    /// `<indexes_dir>/zim-pdf/<zim uuid>`.
    pub dir: PathBuf,
    /// The folders under `snap/` when the snapshot was chosen: another listing means another choice.
    listing: Vec<String>,
    pub state: PdfState,
}

pub enum PdfState {
    /// Verifying and opening on a background thread; the thread leaves its result (`None`: no usable snapshot) here.
    Opening(Arc<std::sync::Mutex<Option<Option<PdfIndex>>>>),
    Ready(Box<PdfIndex>),
    /// No usable snapshot (none published, or none matches this ZIM and core).
    None,
}

impl PdfSlot {
    fn start(zim_id: String, zim_title: String, dir: PathBuf, listing: Vec<String>) -> PdfSlot {
        let cell: Arc<std::sync::Mutex<Option<Option<PdfIndex>>>> = Arc::new(std::sync::Mutex::new(None));
        let (c, p, id) = (cell.clone(), dir.clone(), zim_id.clone());
        let spawned = std::thread::Builder::new().name("cs-open-pdfindex".into()).spawn(move || {
            let r = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                pdfindex::pick(&p, &id).and_then(|pk| {
                    let opened = PdfIndex::open(&pk.name, &pk.dir, pk.manifest.clone()).ok();
                    if opened.is_some() {
                        // local clean-up: usable duplicates and older ones go, the one in use and a rollback stay
                        crate::snapshot::gc(&p, &pk);
                    }
                    opened
                })
            }))
            .unwrap_or(None);
            if let Ok(mut g) = c.lock() {
                *g = Some(r);
            }
        });
        let state = if spawned.is_ok() { PdfState::Opening(cell) } else { PdfState::None };
        PdfSlot { zim_id, zim_title, dir, listing, state }
    }

    pub fn index(&self) -> Option<&PdfIndex> {
        match &self.state {
            PdfState::Ready(i) => Some(i),
            _ => None,
        }
    }

    fn poll(&mut self) {
        if let PdfState::Opening(cell) = &self.state {
            let got = cell.lock().ok().and_then(|mut g| g.take());
            match got {
                Some(Some(i)) => self.state = PdfState::Ready(Box::new(i)),
                Some(None) => self.state = PdfState::None,
                None => {}
            }
        }
    }

    fn status(&self) -> Value {
        match &self.state {
            PdfState::Ready(i) => {
                let mut v = pdfindex::status_json(&i.snapshot, &i.manifest, i.docs);
                v["state"] = json!("ready");
                v
            }
            PdfState::Opening(_) => json!({"state": "opening"}),
            PdfState::None => json!({"state": "none"}),
        }
    }
}

#[allow(clippy::large_enum_variant)] // a library slot holds its two index slots inline; sources are few
pub enum Source {
    Zim(ZimSlot),
    /// The PDF index of a loaded ZIM (never in the `sources` list `set_sources` is given; found beside the ZIM).
    Pdf(PdfSlot),
    /// The caption index of a saved video, or the caption or EPUB index of a loaded ZIM (never in the `sources` list; found
    /// under `indexes_dir`, see kwslot.rs).
    Kw(KwSlot),
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
            "library_id": self.id, "keyword_source": Value::Null, "whole_library_only": Value::Null,
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
    pub min_relevance: f32,
    pub last_error: Option<Error>,
    /// The tools registered by the host (see `tools.rs`); `search` and `read` are built in and not listed here.
    pub tools: Vec<Box<dyn Tool>>,
    /// The user's saved places, for tools. None until the host sets them.
    pub places: Box<dyn SavedPlaces>,
    /// The phone's last GPS fix (`cs_set_location`), for tools.
    pub location: Option<Location>,
    /// Embeds the query for built-in `search`; without one it is keyword-only.
    pub embedder: Option<QueryEmbedder>,
    /// Web search settings (provider, key, online), shared with the registered `web_search` tool. See `web.rs`.
    pub web: Arc<WebState>,
    /// Saved places and live data, configured from the `user` and `live` sections (ext.rs).
    pub ext: crate::ext::Ext,
    /// Memory budget of the open libzim archives, shared by all this handle's ZIM sources (budget.rs).
    pub zim_budget: Arc<ZimBudget>,
    /// The host-pushed live-fetch policy and keys (`cs_live_set_fetch_policy`, `cs_live_set_key`); memory only, cleared on close.
    pub fetcher: Arc<cache_tool::fetcher::PolicyFetcher>,
    /// The actions modules have published, shared with the registered `act` tool (`cs_act_set_definitions`; see act.rs).
    pub act: Arc<cache_act::ActState>,
    /// Where the citations of the last search's library results open (address, link and time), for `cs_tool` to keep in
    /// the conversation beside the numbering. Replaced by every search.
    pub last_cites: Vec<(String, crate::conv::Cite)>,
    /// `indexes_dir` of the sources config (see `Config`).
    pub indexes_dir: Option<PathBuf>,
}

impl Drop for Handle {
    fn drop(&mut self) {
        self.fetcher.clear();
    }
}

fn stem_title(path: &std::path::Path) -> String {
    path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()
}

impl Handle {
    pub fn open(config_json: &str) -> Result<Handle> {
        let mut h = Handle {
            sources: vec![],
            snippet_chars: 400,
            candidates_per_list: 50,
            min_term_coverage: 0.5,
            min_relevance: 0.5,
            last_error: None,
            tools: Vec::new(),
            places: Box::new(NoSavedPlaces),
            location: None,
            embedder: None,
            web: Arc::new(WebState::new()),
            ext: Default::default(),
            zim_budget: Arc::new(ZimBudget::new(budget::default_budget_mb(cfg!(any(target_os = "android", target_os = "ios"))) * budget::MIB)),
            fetcher: Arc::new(cache_tool::fetcher::PolicyFetcher::new()),
            act: Arc::new(cache_act::ActState::new()),
            last_cites: Vec::new(),
            indexes_dir: None,
        };
        h.register_tool(Box::new(cache_calc::CalculateTool));
        h.register_tool(Box::new(cache_act::ActTool(h.act.clone())));
        h.register_tool(Box::new(WebSearchTool(h.web.clone())));
        // The "user" and "live" sections of the config register cache_user as the saved places and cache_live as the
        // live_data tool: set_sources does it (ext.rs), so a later cs_set_sources can add them too.
        h.set_sources(config_json)?;
        Ok(h)
    }

    /// `cs_live_set_fetch_policy`: the host's grant for network fetches; `None` clears it.
    pub fn set_fetch_policy(&self, json: Option<&str>) -> Result<()> {
        self.fetcher.set_policy_json(json).map_err(Error::bad_json)
    }

    /// `cs_live_set_key`: a source's API key, in memory only; `None` clears it.
    pub fn set_live_key(&self, source_id: &str, key: Option<&str>) {
        self.fetcher.set_key(source_id, key);
    }

    /// Replace the source list. Malformed JSON, an unknown kind or a duplicate source id fail the whole call and
    /// leave the old list. A ZIM that cannot be opened does not: it becomes a `Failed` source. ZIMs already open
    /// (same path) are reused rather than reopened.
    pub fn set_sources(&mut self, config_json: &str) -> Result<()> {
        #[allow(clippy::large_enum_variant)]
        enum Plan {
            Reuse(usize, Option<PathBuf>, bool),
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
            let builtin = sc.builtin_index.unwrap_or(true);
            match sc.kind.as_str() {
                "zim" => {
                    let existing = self
                        .sources
                        .iter()
                        .position(|s| matches!(s, Source::Zim(z) if z.src.path == path));
                    let (id, item) = match existing {
                        Some(i) => match &self.sources[i] {
                            Source::Zim(z) => (Some(z.src.id.clone()), Plan::Reuse(i, index_dir, builtin)),
                            _ => unreachable!(),
                        },
                        None => match ZimSource::open(&path) {
                            Ok(z) => {
                                let id = z.id.clone();
                                (Some(id), Plan::New(Source::Zim(ZimSlot::new(z, index_dir, builtin))))
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
                    // a crash between the two renames of an update leaves only `<library>.cs-old`: rename it back
                    // now (cheap), so the library is not reported as missing; the rest of the leftover rules run in
                    // the background open
                    if !path.is_dir() {
                        crate::libupdate::recover_if_leftovers(&path)?;
                    }
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
                Plan::Reuse(i, index_dir, builtin) => {
                    let mut s = old[i].take().expect("reused twice");
                    if let Source::Zim(z) = &mut s {
                        z.builtin = builtin;
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
        self.indexes_dir = cfg.indexes_dir.as_ref().filter(|d| !d.is_empty()).map(PathBuf::from);
        let (mut old_pdfs, mut old_kw): (Vec<PdfSlot>, Vec<KwSlot>) = (Vec::new(), Vec::new());
        for s in old.into_iter().flatten() {
            match s {
                Source::Pdf(p) => old_pdfs.push(p),
                Source::Kw(k) => old_kw.push(k),
                _ => {}
            }
        }
        self.attach_pdf_indexes(old_pdfs);
        self.sync_indexes();
        // where jobs find the saved videos and the ZIM files (kwbuild.rs)
        let zim_places: Vec<(String, PathBuf)> = self
            .sources
            .iter()
            .filter_map(|s| if let Source::Zim(z) = s { Some((z.src.id.clone(), z.src.path.clone())) } else { None })
            .collect();
        crate::kwbuild::register_locations(cfg.video.as_ref().map(|v| std::path::Path::new(&v.dir)), &zim_places);
        self.snippet_chars = cfg.snippet_chars;
        self.web.set_snippet_chars(cfg.snippet_chars as usize);
        self.candidates_per_list = cfg.candidates_per_list;
        self.min_term_coverage = cfg.min_term_coverage;
        self.min_relevance = cfg.min_relevance;
        let caps = budget::Caps {
            dirent_cache: cfg.zim_dirent_cache.unwrap_or(budget::DEFAULT_DIRENT_CACHE),
            cluster_cache: cfg.zim_cluster_cache_mb.unwrap_or(budget::DEFAULT_CLUSTER_CACHE_MB).saturating_mul(budget::MIB),
        };
        let limit_mb = cfg.zim_budget_mb.or(cfg.searcher_budget_mb).unwrap_or_else(|| budget::default_budget_mb(cfg!(any(target_os = "android", target_os = "ios"))));
        crate::zimx::set_cluster_cache_max(caps.cluster_cache);
        self.zim_budget.configure(limit_mb.saturating_mul(budget::MIB), budget::reserved_cost(&caps));
        let opts = crate::zimx::OpenOpts { dirent_cache: Some(caps.dirent_cache), ..Default::default() };
        for s in &self.sources {
            if let Source::Zim(z) = s {
                z.src.configure(&self.zim_budget, caps, opts);
            }
        }
        if cfg.prewarm {
            self.start_prewarm();
        }
        self.ext.configure_regions(cfg.regions)?;
        self.configure_ext(cfg.user, cfg.live, cfg.routing, cfg.video, cfg.places);
        self.attach_kw_indexes(old_kw);
        self.ext.plug_regions();
        self.ext.configure_layers(cfg.layers)?;
        self.ext.configure_notebook(cfg.notebook);
        self.ext.plug_elevation();
        Ok(())
    }

    /// Give every ZIM and library the `indexes_dir` (where their snapshots live) and let `index_seal` find their old index folders.
    fn sync_indexes(&mut self) {
        let root = self.indexes_dir.clone();
        for s in self.sources.iter_mut() {
            match s {
                Source::Zim(z) => {
                    z.indexes_dir = root.clone();
                    if let (Some(root), Some(d)) = (&root, &z.index_dir) {
                        idxsnap::note_legacy(root, idxsnap::KIND_ZIM, &z.src.id, d);
                    }
                }
                Source::Library(l) => {
                    l.indexes_dir = root.clone();
                    if let (Some(root), Some(d)) = (&root, &l.index_dir) {
                        idxsnap::note_legacy(root, idxsnap::KIND_LIBRARY, &l.source_id(), d);
                    }
                }
                _ => {}
            }
        }
    }

    /// The PDF index beside each loaded ZIM (`<zim name>.pdfindex/`): a slot that verifies and opens its newest usable
    /// snapshot on a background thread. A slot whose `snap/` listing has not changed is kept as it is.
    fn attach_pdf_indexes(&mut self, mut old: Vec<PdfSlot>) {
        let zims: Vec<(String, String)> = self
            .sources
            .iter()
            .filter_map(|s| match s {
                Source::Zim(z) => Some((z.src.id.clone(), z.src.title.clone())),
                _ => None,
            })
            .collect();
        self.sources.retain(|s| !matches!(s, Source::Pdf(_)));
        // without an indexes_dir there is no PDF attach
        let Some(root) = self.indexes_dir.clone() else { return };
        for (id, title) in zims {
            let dir = pdfindex::dir_for(&root, &id);
            if !dir.join(crate::snapshot::SNAP_DIR).is_dir() {
                continue;
            }
            let listing = crate::snapshot::list(&dir);
            let slot = match old.iter().position(|o| o.zim_id == id && o.dir == dir && o.listing == listing) {
                Some(k) => old.remove(k),
                None => PdfSlot::start(id, title, dir, listing),
            };
            self.sources.push(Source::Pdf(slot));
        }
    }

    /// Open libzim on the ZIM sources that use their built-in index and build their searchers, on up to
    /// `PREWARM_THREADS` background threads (each source once), but only the sources whose searchers fit in the memory
    /// budget, cheapest first (`budget::prewarm_plan`); the others open on their first search. Nothing waits for
    /// them: a search that needs a source still being warmed waits for that source's open only.
    fn start_prewarm(&self) {
        let all: Vec<zimsrc::WarmJob> = self
            .sources
            .iter()
            .filter_map(|s| match s {
                Source::Zim(z) if z.builtin => z.src.warm_job(),
                _ => None,
            })
            .collect();
        let costs: Vec<u64> = all.iter().map(|j| j.cost()).collect();
        let plan = budget::prewarm_plan(&costs, self.zim_budget.available());
        let mut slots: Vec<Option<zimsrc::WarmJob>> = all.into_iter().map(Some).collect();
        // `pop` takes from the end, so the queue holds the plan's most expensive first
        let jobs: Vec<zimsrc::WarmJob> = plan.iter().rev().filter_map(|&i| slots[i].take()).collect();
        let n = jobs.len().min(PREWARM_THREADS);
        let queue = Arc::new(std::sync::Mutex::new(jobs));
        for i in 0..n {
            let q = queue.clone();
            let _ = std::thread::Builder::new().name(format!("cs-prewarm-{i}")).spawn(move || loop {
                let job = q.lock().ok().and_then(|mut g| g.pop());
                match job {
                    Some(j) => j.run(),
                    None => break,
                }
            });
        }
    }

    /// Bring the library sources up to date with what happened since the last call: an open that finished becomes
    /// `Library` (or `Failed`); a library an `update_library` job owns becomes `Updating` (its shard is dropped);
    /// a library whose update has ended, or that an update changed while it was opening, is opened again.
    pub fn poll_opening(&mut self) {
        for s in self.sources.iter_mut() {
            if let Source::Pdf(p) = s {
                p.poll();
                // a snapshot published or removed since it was chosen (or a sync that finished): choose again
                let listing = crate::snapshot::list(&p.dir);
                if listing != p.listing {
                    *p = PdfSlot::start(p.zim_id.clone(), p.zim_title.clone(), p.dir.clone(), listing);
                }
                continue;
            }
            if let Source::Kw(_) = s {
                continue;
            }
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
        self.sync_indexes();
        // caption and EPUB snapshots published (or synced) since the last look are searched without another cs_set_sources
        self.refresh_kw_indexes();
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

    /// The installed English Wikipedia ZIMs (Kiwix's book name starts with `wikipedia_en`, a full or a subset such as
    /// medicine), in source order. Spec S14: `read` opens a place's article from the first of them that has it.
    pub fn wikipedia_zims(&self) -> Vec<&ZimSource> {
        self.sources
            .iter()
            .filter_map(|s| match s {
                Source::Zim(z) if z.src.name.as_deref().is_some_and(|n| n.starts_with("wikipedia_en")) => Some(&z.src),
                _ => None,
            })
            .collect()
    }

    pub fn status_json(&mut self) -> String {
        self.poll_opening();
        let pdf: std::collections::HashMap<String, Value> =
            self.sources.iter().filter_map(|s| if let Source::Pdf(p) = s { Some((p.zim_id.clone(), p.status())) } else { None }).collect();
        let mut list: Vec<Value> = self
            .sources
            .iter_mut()
            .map(|s| match s {
                Source::Zim(z) => {
                    // A ZIM with a built-in Xapian index is searched through it (no index_dir needed): indexed, with
                    // "keyword_source":"own" (the field is present for these only; see cache_search.h).
                    if z.has_xapian() {
                        return json!({
                            "id": z.src.id, "kind": "zim", "path": z.src.path.to_string_lossy(),
                            "title": z.src.title, "language": z.src.language,
                            "indexed": true, "building": false, "stale": false, "opening": false, "updating": false,
                            "docs": z.src.entry_count(), "embedding_model": Value::Null, "keyword_source": "own",
                            "error": Value::Null,
                        });
                    }
                    z.refresh_snapshot();
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
                Source::Pdf(_) | Source::Kw(_) => Value::Null,
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
                    l.refresh_snapshot();
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
                        "whole_library_only": l.whole_library_only,
                        "settings": l.settings.to_json(), "error": Value::Null,
                    })
                }
            })
            .filter(|v| !v.is_null())
            .collect();
        // every source says which source it is for sync (`source_id`) and where its keyword index is (`index`)
        let metas: Vec<(Value, Value)> = self
            .sources
            .iter()
            .filter(|s| !matches!(s, Source::Pdf(_) | Source::Kw(_)))
            .map(|s| {
                let lib_id = |id: &str, version: Option<&String>| match version {
                    Some(v) => format!("{id}@{v}"),
                    None => id.to_string(),
                };
                match s {
                    Source::Zim(z) => (
                        json!(z.src.id),
                        z.index_info(),
                    ),
                    Source::Library(l) => (
                        json!(lib_id(&l.settings.library_id, l.settings.version.as_ref())),
                        index_info_json(
                            idxsnap::KIND_LIBRARY,
                            index::LIB_INDEX_FORMAT,
                            l.snap.ready().map(|s| (s.name.as_str(), s.dir.as_path())),
                            l.snap.opening(),
                            &l.legacy_state(),
                            l.index_dir.as_deref(),
                            l.indexes_dir.is_some(),
                        ),
                    ),
                    Source::Opening(o) | Source::Updating(o) => (
                        json!(lib_id(&o.id, o.settings.as_ref().and_then(|st| st.version.as_ref()))),
                        index_info_json(
                            idxsnap::KIND_LIBRARY,
                            index::LIB_INDEX_FORMAT,
                            None,
                            true,
                            &index::index_state_for(
                                o.index_dir.as_deref(),
                                &crate::libindex::source_key(&o.id),
                                index::LIB_INDEX_FORMAT,
                            ),
                            o.index_dir.as_deref(),
                            false,
                        ),
                    ),
                    Source::Failed { .. } | Source::Pdf(_) | Source::Kw(_) => (Value::Null, Value::Null),
                }
            })
            .collect();
        for (v, (id, idx)) in list.iter_mut().zip(metas) {
            v["source_id"] = id;
            v["index"] = idx;
        }
        // a ZIM with a PDF index says so (only then does its entry have this key)
        for v in list.iter_mut() {
            if v["kind"] == "zim" {
                if let Some(p) = v["id"].as_str().and_then(|id| pdf.get(id)) {
                    v["pdfindex"] = p.clone();
                }
                // the caption and EPUB indexes of the ZIM, with whether they still need building
                if let (Some(id), Some(path)) = (v["id"].as_str().map(str::to_string), v["path"].as_str().map(PathBuf::from)) {
                    for (key, val) in self.kw_status_for_zim(&id, &path) {
                        v[key] = val;
                    }
                }
            }
        }
        json!({ "sources": list }).to_string()
    }

    /// `cs_zim_pdfs`: the PDFs inside a ZIM (entries whose mime type is application/pdf), by path:
    /// `{"zim_uuid","zim_name","pdfs":[{"path","title","size"}]}`.
    pub fn zim_pdfs(&self, zim_id: &str) -> Result<String> {
        let src = self.zim(zim_id)?;
        let czim = src.zim()?;
        let mut cands: Vec<(u32, u32, String, String)> = Vec::new();
        for idx in 0..src.entry_count() as u32 {
            let Ok(e) = czim.get_by_url_index(idx) else { continue };
            if !matches!(e.namespace, zim::Namespace::UserContent | zim::Namespace::Articles) {
                continue;
            }
            let zim::MimeType::Type(m) = &e.mime_type else { continue };
            if !m.to_ascii_lowercase().starts_with("application/pdf") {
                continue;
            }
            let Some(zim::Target::Cluster(cluster, blob)) = e.target else { continue };
            let title = if e.title.is_empty() { e.url.clone() } else { e.title.clone() };
            cands.push((cluster, blob, e.url, title));
        }
        // sizes by cluster, so each cluster is read once
        cands.sort_by_key(|c| (c.0, c.1));
        let mut pdfs: Vec<(String, String, u64)> = Vec::with_capacity(cands.len());
        let mut i = 0;
        while i < cands.len() {
            let c0 = cands[i].0;
            let mut j = i;
            while j < cands.len() && cands[j].0 == c0 {
                j += 1;
            }
            let cluster = czim.get_cluster(c0).ok();
            let guard = cluster.as_ref().and_then(|c| c.read().ok());
            for c in &cands[i..j] {
                let size = guard.as_ref().and_then(|g| g.blob(c.1).ok()).map(|b| b.len() as u64).unwrap_or(0);
                pdfs.push((c.2.clone(), c.3.clone(), size));
            }
            i = j;
        }
        pdfs.sort();
        Ok(json!({
            "zim_uuid": src.id,
            "zim_name": src.name.clone().unwrap_or_else(|| src.path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()),
            "pdfs": pdfs.into_iter().map(|(path, title, size)| json!({"path": path, "title": title, "size": size})).collect::<Vec<_>>(),
        })
        .to_string())
    }

    /// The opened PDF index of the ZIM `zim_id`, when it has one ready.
    pub fn pdf_index(&self, zim_id: &str) -> Option<&PdfIndex> {
        self.sources.iter().find_map(|s| match s {
            Source::Pdf(p) if p.zim_id == zim_id => p.index(),
            _ => None,
        })
    }

    pub fn zim_get(&self, address: &str) -> Result<zimsrc::RawEntry> {
        let a = zimsrc::parse_address(address)?;
        let z = self.zim(&a.id)?;
        match z.get(&a.path) {
            // an address with `!/` also names a file inside an EPUB (kwslot.rs); the entry itself is tried first
            Err(e) if e.code == crate::ErrorCode::NotFound && a.path.contains("!/") => match self.zim_get_in_epub(&a.id, &a.path)? {
                Some(entry) => Ok(entry),
                None => Err(e),
            },
            other => other,
        }
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
