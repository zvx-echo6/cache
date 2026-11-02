//! Building the caption and EPUB indexes (kinds `captions`, `zim-captions`, `zim-epub`; layout in `kwindex.rs`).
//!
//! Unlike the PDF index, the core does the whole build: the `index_source` job reads the source (a saved video's caption
//! files, or a ZIM's entries), makes the pieces and publishes the snapshot. It follows the resumable pattern of
//! `pdfbuild.rs`: a build folder (`.build/`) with a Tantivy index, a record of what it was made for (`kwindex-build.json`; any
//! other value restarts the build), the build `Lock`, and checkpoints. A checkpoint is a Tantivy commit whose payload is
//! `{"entries": N}`; `done.tsv` is the per-item record, a line appended (and synced) only after the commit that holds the item,
//! and on open only the first N lines count. A kill therefore loses at most the items after the last commit; an item that was
//! committed but not recorded is simply added again (the pieces of an item are replaced, never duplicated). An item is all or
//! nothing.
//!
//! Where the sources are: the job gets only `indexes_dir`, `kind` and `source_id`. The video folder and the ZIM files are
//! found through the places the open handles were given (`register_locations`, called by `set_sources`); `video_dir` and
//! `zim_path` in the parameters override that for a host that runs the job without a handle.

use crate::epub;
use crate::error::{Error, Result};
use crate::index::{make_analyzer, tv, Lock, Outcome, ANALYZER, LOCK_FILE};
use crate::kwindex::{
    self, build_schema, fields_of, pid_of, Fields, ItemRow, KwIndex, StoredPiece, CAPTIONS, FORMAT, TANTIVY,
    ZIM_CAPTIONS, ZIM_EPUB,
};
use crate::snapshot::{self, Manifest, Tokenizer, BUILD_DIR};
use crate::vtt;
use crate::zimsrc::{self, ZimSource};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tantivy::{doc, Index, IndexWriter, TantivyDocument, Term};

pub const BUILD_META: &str = "kwindex-build.json";
pub const DONE_FILE: &str = "done.tsv";
/// Files of the build folder that are not part of a snapshot.
const NOT_IN_SNAPSHOT: [&str; 5] = [
    LOCK_FILE,
    BUILD_META,
    DONE_FILE,
    ".tantivy-writer.lock",
    ".tantivy-meta.lock",
];
/// A commit after this many items or this many seconds, whichever comes first.
const BATCH_ITEMS: usize = 20;
const BATCH_SECS: u64 = 30;
const HEAP_BYTES: usize = 50_000_000;
/// A caption file larger than this is not read as captions.
const MAX_CAPTION_BYTES: usize = 16 * 1024 * 1024;
/// An EPUB larger than this is skipped (`too_large`).
const MAX_EPUB_BYTES: usize = 1 << 30;

// ---------------------------------------------------------------------------------------------------------
// Where the sources are

#[derive(Default)]
struct Locations {
    video_dirs: Vec<PathBuf>,
    zims: HashMap<String, PathBuf>,
}

static LOCATIONS: Mutex<Option<Locations>> = Mutex::new(None);

/// Remember where a handle's saved videos and ZIM files are, for jobs (called by `Handle::set_sources`).
pub fn register_locations(video_dir: Option<&Path>, zims: &[(String, PathBuf)]) {
    let mut g = LOCATIONS.lock().unwrap_or_else(|e| e.into_inner());
    let l = g.get_or_insert_with(Locations::default);
    if let Some(d) = video_dir {
        if !l.video_dirs.iter().any(|x| x == d) {
            l.video_dirs.push(d.to_path_buf());
        }
    }
    for (id, p) in zims {
        l.zims.insert(id.to_ascii_lowercase(), p.clone());
    }
}

fn zim_location(uuid: &str) -> Option<PathBuf> {
    LOCATIONS
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .as_ref()
        .and_then(|l| l.zims.get(&uuid.to_ascii_lowercase()).cloned())
}

/// The folder of a saved video: `<video dir>/downloads/<host>/<uuid>`.
fn video_folder(source_id: &str, override_dir: Option<&Path>) -> Option<PathBuf> {
    let (host, uuid) = source_id.split_once('/')?;
    let dirs: Vec<PathBuf> = match override_dir {
        Some(d) => vec![d.to_path_buf()],
        None => LOCATIONS
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .as_ref()
            .map(|l| l.video_dirs.clone())
            .unwrap_or_default(),
    };
    // the most recently registered folder first
    dirs.into_iter()
        .rev()
        .map(|d| d.join("downloads").join(host).join(uuid))
        .find(|p| p.join("manifest.json").is_file())
}

/// A saved video's captions source id, `<instance>/<uuid>`, when `source_id` is a valid one.
pub fn valid_video_source(source_id: &str) -> bool {
    match source_id.split_once('/') {
        Some((h, u)) => {
            let ok = |s: &str| {
                !s.is_empty() && s.len() <= 200 && s != "." && s != ".." && !s.contains(['/', '\\', ':', '\0'])
            };
            ok(h) && ok(u)
        }
        None => false,
    }
}

// ---------------------------------------------------------------------------------------------------------
// Items

/// What one item came to.
pub enum Item {
    Added(Loaded),
    Skipped {
        reason: String,
        size: Option<u64>,
        sha256: String,
    },
}

/// An item's pieces (`item`, `i`, `pid` and `title` are set by the builder) and the facts for its row.
pub struct Loaded {
    /// The item's own title (a video entry's, a book's); the source's name when `None`.
    pub title: Option<String>,
    pub pieces: Vec<StoredPiece>,
    pub size: Option<u64>,
    pub sha256: String,
    /// The pieces were copied from an older edition's snapshot, not made from the source.
    pub reused: bool,
}

/// An older edition's snapshot whose pieces an EPUB with the same sha256 may reuse.
pub struct Previous {
    index: KwIndex,
    rows: BTreeMap<String, ItemRow>,
}

impl Previous {
    fn reusable(&self, path: &str, sha: &str) -> Option<Vec<StoredPiece>> {
        let row = self
            .rows
            .get(path)
            .filter(|r| r.status == "added" && !sha.is_empty() && r.sha256 == sha)?;
        let stored = self.index.pieces_of(path);
        (stored.len() as u64 == row.pieces && !stored.is_empty()).then_some(stored)
    }
}

trait ItemSource: Send {
    fn tokenizer(&self) -> String;
    /// The source's name for the manifest and the pieces without a title of their own.
    fn name(&self) -> String;
    fn extra(&self) -> Map<String, Value>;
    fn items(&self) -> Result<Vec<String>>;
    fn load(&self, key: &str, previous: Option<&Previous>) -> Result<Item>;
}

fn sha_hex(bytes: &[u8]) -> String {
    Sha256::digest(bytes).iter().map(|b| format!("{b:02x}")).collect()
}

/// The language a caption file name carries: `x_en.srt`, `x.en.vtt`, `captions-fr-CA.vtt`. `und` when it carries none.
pub fn lang_of_file(name: &str) -> String {
    let file = name.rsplit('/').next().unwrap_or(name);
    let stem = file.rsplit_once('.').map(|(s, _)| s).unwrap_or(file);
    let stem = stem
        .strip_prefix("captions-")
        .map(|rest| format!("x_{rest}"))
        .unwrap_or_else(|| stem.to_string());
    lang_suffix(&stem).map(|(_, l)| l).unwrap_or_else(|| "und".to_string())
}

fn is_lang_token(t: &str) -> bool {
    const THREE: [&str; 20] = [
        "eng", "fra", "fre", "deu", "ger", "spa", "ita", "por", "rus", "ara", "zho", "chi", "jpn", "kor", "nld", "dut",
        "swe", "pol", "tur", "hin",
    ];
    let (base, region) = match t.split_once('-') {
        Some((b, r)) => (b, Some(r)),
        None => (t, None),
    };
    let base_ok = (base.len() == 2 && base.bytes().all(|b| b.is_ascii_alphabetic()))
        || THREE.contains(&base.to_ascii_lowercase().as_str());
    base_ok && region.is_none_or(|r| (2..=8).contains(&r.len()) && r.bytes().all(|b| b.is_ascii_alphanumeric()))
}

/// `(stem without the language, language)` for a stem that ends in `_<lang>` or `.<lang>` (or `-<lang>` after `x_`).
fn lang_suffix(stem: &str) -> Option<(String, String)> {
    let cut = stem.rfind(['_', '.'])?;
    let tail = &stem[cut + 1..];
    is_lang_token(tail).then(|| (stem[..cut].to_string(), tail.to_ascii_lowercase()))
}

/// The base name that pairs a caption with its video: the file name without the extension and without a trailing language.
pub fn pair_base(path: &str) -> (String, String) {
    let (folder, file) = path
        .rsplit_once('/')
        .map(|(d, f)| (d.to_string(), f))
        .unwrap_or((String::new(), path));
    let stem = file.rsplit_once('.').map(|(s, _)| s).unwrap_or(file);
    let base = lang_suffix(stem).map(|(b, _)| b).unwrap_or_else(|| stem.to_string());
    (folder, base)
}

fn stem_title(path: &str) -> String {
    let file = path.rsplit('/').next().unwrap_or(path);
    file.rsplit_once('.').map(|(s, _)| s).unwrap_or(file).replace('_', " ")
}

fn passage_pieces(bytes: &[u8], lang: &str) -> Vec<StoredPiece> {
    let text = String::from_utf8_lossy(bytes);
    vtt::passages(&vtt::parse(&text))
        .into_iter()
        .map(|p| StoredPiece {
            text: p.text,
            lang: lang.to_string(),
            start_ms: p.start_ms,
            end_ms: p.end_ms,
            ..Default::default()
        })
        .collect()
}

// --- a saved video

struct VideoSource {
    dir: PathBuf,
    title: String,
    uuid: String,
    host: String,
}

fn caption_files(dir: &Path) -> Vec<String> {
    let mut v: Vec<String> = std::fs::read_dir(dir)
        .map(|rd| {
            rd.flatten()
                .filter(|e| e.file_type().map(|t| t.is_file()).unwrap_or(false))
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.starts_with("captions-") && (n.ends_with(".vtt") || n.ends_with(".srt")))
                .collect()
        })
        .unwrap_or_default();
    v.sort();
    v
}

impl ItemSource for VideoSource {
    fn tokenizer(&self) -> String {
        let langs: Vec<String> = caption_files(&self.dir).iter().map(|f| lang_of_file(f)).collect();
        let pick = langs.iter().find(|l| l.starts_with("en")).or(langs.first());
        kwindex::tokenizer_for(pick.map(String::as_str)).to_string()
    }

    fn name(&self) -> String {
        self.title.clone()
    }

    fn extra(&self) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("host".into(), json!(self.host));
        m.insert("video_uuid".into(), json!(self.uuid));
        m.insert("video_title".into(), json!(self.title));
        m
    }

    fn items(&self) -> Result<Vec<String>> {
        Ok(caption_files(&self.dir))
    }

    fn load(&self, key: &str, _previous: Option<&Previous>) -> Result<Item> {
        let path = self.dir.join(key);
        let meta = std::fs::metadata(&path).map_err(|e| Error::io(format!("{}: {e}", path.display())))?;
        if meta.len() as usize > MAX_CAPTION_BYTES {
            return Ok(Item::Skipped {
                reason: "too_large".into(),
                size: Some(meta.len()),
                sha256: String::new(),
            });
        }
        let bytes = std::fs::read(&path).map_err(|e| Error::io(format!("{}: {e}", path.display())))?;
        let sha = sha_hex(&bytes);
        let pieces = passage_pieces(&bytes, &lang_of_file(key));
        if pieces.is_empty() {
            return Ok(Item::Skipped {
                reason: "no_text".into(),
                size: Some(bytes.len() as u64),
                sha256: sha,
            });
        }
        Ok(Item::Added(Loaded {
            title: None,
            pieces,
            size: Some(bytes.len() as u64),
            sha256: sha,
            reused: false,
        }))
    }
}

// --- a ZIM

/// What the entries of a ZIM hold that the caption and EPUB indexes read.
#[derive(Default)]
pub struct ZimMedia {
    /// Standalone caption entries: (path, entry title).
    pub captions: Vec<(String, String)>,
    pub epubs: Vec<(String, String)>,
    /// (folder, base name) -> the video entry's path.
    videos: HashMap<(String, String), (String, String)>,
}

fn ext_of(path: &str) -> String {
    path.rsplit_once('.')
        .map(|(_, e)| e.to_ascii_lowercase())
        .unwrap_or_default()
}

/// Whether a ZIM's MIME list (in its header, so cheap to read) names a type that caption or EPUB entries have: `text/vtt`,
/// a SubRip type (`application/x-subrip`, `text/srt`...) or `application/epub+zip`. Only then is the ZIM's entry list walked.
/// `application/octet-stream` and `text/plain` are in nearly every ZIM, so they never start a walk; but a caption file that
/// has one of them (a `.srt` or `.vtt` path) is counted when a walk happens anyway.
pub fn walk_candidates(mime_table: &[String]) -> bool {
    mime_table.iter().any(|m| {
        let m = m.to_ascii_lowercase();
        m.starts_with("text/vtt")
            || m.starts_with("application/epub")
            || m.contains("subrip")
            || m.ends_with("/srt")
            || m.ends_with("-srt")
    })
}

/// ZIMs whose entry list has been walked in this process (for the test that a ZIM without candidate types is never walked).
static WALKED: Mutex<Vec<String>> = Mutex::new(Vec::new());

/// Whether `scan_zim` has walked the entries of the ZIM with this uuid in this process.
pub fn was_walked(uuid: &str) -> bool {
    WALKED
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .iter()
        .any(|u| u == uuid)
}

/// Lower the priority of the calling thread so a walk of a big ZIM does not compete with the app (Linux and Android:
/// nice 10 for this thread; elsewhere the walk only paces itself).
fn lower_thread_priority() {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    // SAFETY: gettid and setpriority take and return plain integers; a failure only leaves the priority as it was.
    unsafe {
        let tid = libc::syscall(libc::SYS_gettid) as libc::id_t;
        libc::setpriority(libc::PRIO_PROCESS as _, tid, 10);
    }
}

/// Entries between two short sleeps of a gentle walk, and the sleep.
const GENTLE_EVERY: u32 = 4096;
const GENTLE_PAUSE: Duration = Duration::from_millis(2);

/// List the caption entries, the EPUB entries and the video entries of a ZIM. HLS segment captions (a `.vtt` in a folder that
/// also holds `.ts` segments) are left out. A ZIM whose MIME list has no candidate type (`walk_candidates`) is not walked: it
/// has none. `gentle` lowers the thread's priority and pauses now and then (the status scan; a build does not).
pub fn scan_zim(src: &ZimSource, gentle: bool) -> Result<ZimMedia> {
    let czim = src.zim()?;
    if !walk_candidates(&czim.mime_table) {
        return Ok(ZimMedia::default());
    }
    WALKED.lock().unwrap_or_else(|e| e.into_inner()).push(src.id.clone());
    if gentle {
        lower_thread_priority();
    }
    let mut caps: Vec<(String, String, String)> = Vec::new();
    let mut media = ZimMedia::default();
    let mut ts_folders: HashSet<String> = HashSet::new();
    for idx in 0..src.entry_count() as u32 {
        if gentle && idx % GENTLE_EVERY == GENTLE_EVERY - 1 {
            std::thread::sleep(GENTLE_PAUSE);
        }
        let Ok(e) = czim.get_by_url_index(idx) else { continue };
        if !matches!(e.namespace, zim::Namespace::UserContent | zim::Namespace::Articles) {
            continue;
        }
        let zim::MimeType::Type(m) = &e.mime_type else { continue };
        let m = m.to_ascii_lowercase();
        let ext = ext_of(&e.url);
        let title = if e.title.is_empty() {
            e.url.clone()
        } else {
            e.title.clone()
        };
        if m.starts_with("application/epub") || ext == "epub" {
            media.epubs.push((e.url.clone(), title));
        } else if m.starts_with("text/vtt")
            || ext == "srt"
            || (ext == "vtt" && (m.starts_with("text/") || m == "application/octet-stream"))
        {
            caps.push((e.url.clone(), title, m));
        } else if m.starts_with("video/mp2t") || ext == "ts" {
            if let Some((d, _)) = e.url.rsplit_once('/') {
                ts_folders.insert(d.to_string());
            } else {
                ts_folders.insert(String::new());
            }
        } else if m.starts_with("video/") || matches!(ext.as_str(), "mp4" | "webm" | "mkv" | "m4v" | "mov" | "ogv") {
            let (folder, base) = pair_base(&e.url);
            media.videos.entry((folder, base)).or_insert((e.url.clone(), title));
        }
    }
    for (path, title, _) in caps {
        let folder = path.rsplit_once('/').map(|(d, _)| d.to_string()).unwrap_or_default();
        if ts_folders.contains(&folder) {
            continue;
        }
        media.captions.push((path, title));
    }
    media.captions.sort();
    media.epubs.sort();
    Ok(media)
}

impl ZimMedia {
    /// The video entry a caption belongs to: same folder, same base name once a trailing `_<lang>` is dropped.
    pub fn video_of(&self, caption_path: &str) -> Option<&(String, String)> {
        self.videos.get(&pair_base(caption_path))
    }
}

struct ZimCaptionsSource {
    src: ZimSource,
    media: ZimMedia,
}

fn zim_name_of(src: &ZimSource) -> String {
    src.name.clone().unwrap_or_else(|| {
        src.path
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_default()
    })
}

impl ItemSource for ZimCaptionsSource {
    fn tokenizer(&self) -> String {
        crate::index::tokenizer_name_for(self.src.language.as_deref()).to_string()
    }

    fn name(&self) -> String {
        zim_name_of(&self.src)
    }

    fn extra(&self) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("zim_uuid".into(), json!(self.src.id));
        m.insert("zim_name".into(), json!(zim_name_of(&self.src)));
        m
    }

    fn items(&self) -> Result<Vec<String>> {
        Ok(self.media.captions.iter().map(|(p, _)| p.clone()).collect())
    }

    fn load(&self, key: &str, _previous: Option<&Previous>) -> Result<Item> {
        let e = self.src.get(key)?;
        if e.bytes.len() > MAX_CAPTION_BYTES {
            return Ok(Item::Skipped {
                reason: "too_large".into(),
                size: Some(e.bytes.len() as u64),
                sha256: String::new(),
            });
        }
        let sha = sha_hex(&e.bytes);
        let mut pieces = passage_pieces(&e.bytes, &lang_of_file(key));
        if pieces.is_empty() {
            return Ok(Item::Skipped {
                reason: "no_text".into(),
                size: Some(e.bytes.len() as u64),
                sha256: sha,
            });
        }
        let (video, title) = match self.media.video_of(key) {
            Some((vp, vt)) => (vp.clone(), vt.clone()),
            None => (
                String::new(),
                self.media
                    .captions
                    .iter()
                    .find(|(p, _)| p == key)
                    .map(|(_, t)| t.clone())
                    .unwrap_or_default(),
            ),
        };
        for p in &mut pieces {
            p.video = video.clone();
        }
        let title = if title.is_empty() || title == key {
            stem_title(key)
        } else {
            title
        };
        Ok(Item::Added(Loaded {
            title: Some(title),
            pieces,
            size: Some(e.bytes.len() as u64),
            sha256: sha,
            reused: false,
        }))
    }
}

struct ZimEpubSource {
    src: ZimSource,
    media: ZimMedia,
}

/// The pieces of one EPUB: chapter by chapter in spine order, each chapter cut into blocks and chunked.
pub fn epub_pieces(bytes: &[u8]) -> Result<(Option<String>, Vec<StoredPiece>)> {
    let zip = epub::Zip::open(bytes)?;
    let pkg = epub::package(&zip);
    let mut out: Vec<StoredPiece> = Vec::new();
    for chapter in &pkg.spine {
        let Ok(raw) = zip.read(chapter) else { continue };
        let xhtml = String::from_utf8_lossy(&raw);
        let mut elements: Vec<cache_chunk::Element> = Vec::new();
        for b in epub::blocks(&xhtml) {
            if b.text.is_empty() {
                continue;
            }
            elements.push(if b.level > 0 {
                cache_chunk::Element::Heading {
                    level: b.level,
                    text: b.text,
                    page: b.n as usize,
                }
            } else {
                cache_chunk::Element::Para {
                    text: b.text,
                    page: b.n as usize,
                    bullet: b.item,
                    aside: false,
                }
            });
        }
        for p in cache_chunk::chunk(&elements) {
            out.push(StoredPiece {
                text: p.text,
                chapter: chapter.clone(),
                block: p.page as u64,
                heading_path: p.heading_path,
                ..Default::default()
            });
        }
    }
    Ok((pkg.title, out))
}

impl ItemSource for ZimEpubSource {
    fn tokenizer(&self) -> String {
        crate::index::tokenizer_name_for(self.src.language.as_deref()).to_string()
    }

    fn name(&self) -> String {
        zim_name_of(&self.src)
    }

    fn extra(&self) -> Map<String, Value> {
        let mut m = Map::new();
        m.insert("zim_uuid".into(), json!(self.src.id));
        m.insert("zim_name".into(), json!(zim_name_of(&self.src)));
        m
    }

    fn items(&self) -> Result<Vec<String>> {
        Ok(self.media.epubs.iter().map(|(p, _)| p.clone()).collect())
    }

    fn load(&self, key: &str, previous: Option<&Previous>) -> Result<Item> {
        let e = self.src.get(key)?;
        let size = e.bytes.len() as u64;
        if e.bytes.len() > MAX_EPUB_BYTES {
            return Ok(Item::Skipped {
                reason: "too_large".into(),
                size: Some(size),
                sha256: String::new(),
            });
        }
        let sha = sha_hex(&e.bytes);
        let entry_title = self
            .media
            .epubs
            .iter()
            .find(|(p, _)| p == key)
            .map(|(_, t)| t.clone())
            .unwrap_or_default();
        if let Some(stored) = previous.and_then(|p| p.reusable(key, &sha)) {
            let title = stored.first().map(|p| p.title.clone());
            return Ok(Item::Added(Loaded {
                title,
                pieces: stored,
                size: Some(size),
                sha256: sha,
                reused: true,
            }));
        }
        let (book, pieces) = match epub_pieces(&e.bytes) {
            Ok(r) => r,
            Err(_) => {
                return Ok(Item::Skipped {
                    reason: "damaged".into(),
                    size: Some(size),
                    sha256: sha,
                })
            }
        };
        if pieces.is_empty() {
            return Ok(Item::Skipped {
                reason: "no_text".into(),
                size: Some(size),
                sha256: sha,
            });
        }
        let title = book
            .or_else(|| (!entry_title.is_empty() && entry_title != key).then_some(entry_title))
            .unwrap_or_else(|| stem_title(key));
        Ok(Item::Added(Loaded {
            title: Some(title),
            pieces,
            size: Some(size),
            sha256: sha,
            reused: false,
        }))
    }
}

// ---------------------------------------------------------------------------------------------------------
// The record of a build

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
struct BuildMeta {
    kind: String,
    source_id: String,
    format: u32,
    chunker: u32,
    tokenizer: String,
}

fn write_json_atomic(path: &Path, v: &impl Serialize) -> Result<()> {
    let tmp = path.with_extension("tmp");
    let s = serde_json::to_string(v).map_err(|e| Error::internal(e.to_string()))?;
    std::fs::write(&tmp, s).map_err(|e| Error::io(format!("{}: {e}", tmp.display())))?;
    std::fs::rename(&tmp, path).map_err(|e| Error::io(format!("{}: {e}", path.display())))
}

fn read_build_meta(build: &Path) -> Option<BuildMeta> {
    serde_json::from_slice(&std::fs::read(build.join(BUILD_META)).ok()?).ok()
}

fn esc(s: &str) -> String {
    s.replace('\\', "\\\\").replace('\t', "\\t").replace('\n', "\\n")
}

#[derive(Clone, Default)]
struct Added {
    pieces: u64,
    size: Option<u64>,
    sha256: String,
}

#[derive(Clone, Default)]
struct Skipped {
    reason: String,
    size: Option<u64>,
    sha256: String,
}

/// What `done.tsv` says (`d<TAB>path<TAB>pieces<TAB>size<TAB>sha256` or `s<TAB>path<TAB>reason<TAB>size<TAB>sha256`), the last line
/// for a path winning, and the number of lines that counted.
#[derive(Default)]
struct DoneRecord {
    done: BTreeMap<String, Added>,
    skipped: BTreeMap<String, Skipped>,
    lines: usize,
}

fn line_for(kind: &str, path: &str, what: &str, size: Option<u64>, sha: &str) -> String {
    format!(
        "{kind}\t{}\t{}\t{}\t{}",
        esc(path),
        esc(what),
        size.map(|n| n.to_string()).unwrap_or_default(),
        sha
    )
}

fn load_done(build: &Path, limit: usize) -> DoneRecord {
    let mut r = DoneRecord::default();
    let Ok(text) = std::fs::read_to_string(build.join(DONE_FILE)) else {
        return r;
    };
    for line in text.lines().take(limit) {
        let f: Vec<&str> = line.split('\t').collect();
        if f.len() < 3 {
            continue;
        }
        let path = kwindex::unescape(f[1]);
        let (size, sha) = (
            f.get(3).and_then(|x| x.parse().ok()),
            f.get(4).copied().unwrap_or("").to_string(),
        );
        match f[0] {
            "d" => {
                r.skipped.remove(&path);
                r.done.insert(
                    path,
                    Added {
                        pieces: f[2].parse().unwrap_or(0),
                        size,
                        sha256: sha,
                    },
                );
            }
            "s" => {
                r.done.remove(&path);
                r.skipped.insert(
                    path,
                    Skipped {
                        reason: kwindex::unescape(f[2]),
                        size,
                        sha256: sha,
                    },
                );
            }
            _ => continue,
        }
        r.lines += 1;
    }
    r
}

fn payload_entries(index: &Index) -> usize {
    index
        .load_metas()
        .ok()
        .and_then(|m| m.payload)
        .and_then(|p| serde_json::from_str::<Value>(&p).ok())
        .and_then(|v| v.get("entries")?.as_u64())
        .unwrap_or(0) as usize
}

// ---------------------------------------------------------------------------------------------------------
// The request

#[derive(Deserialize)]
struct Params {
    indexes_dir: String,
    kind: String,
    source_id: String,
    /// `zim-epub`: an older edition of this ZIM whose snapshot may supply pieces for EPUBs that did not change.
    #[serde(default)]
    previous: Option<PreviousParams>,
    /// Where the saved videos are (`captions`) or the ZIM file (`zim-*`), when the handles' places are not to be used.
    #[serde(default)]
    video_dir: Option<String>,
    #[serde(default)]
    zim_path: Option<String>,
    /// Not in the header: test hooks. Items per commit; the build "dies" (no commit of the open batch) after this many items;
    /// a cancellable pause before the merge.
    #[serde(default)]
    batch_items: Option<usize>,
    #[serde(default)]
    crash_after: Option<usize>,
    #[serde(default)]
    hold_ms: u64,
}

#[derive(Deserialize)]
struct PreviousParams {
    zim_uuid: String,
}

/// What `run` needs, checked and locked by `prepare` before the job's thread starts.
pub struct BuildRequest {
    kind: String,
    source_id: String,
    dir: PathBuf,
    build: PathBuf,
    src: Box<dyn ItemSource>,
    previous_dir: Option<(PathBuf, String)>,
    batch_items: usize,
    crash_after: Option<usize>,
    hold_ms: u64,
    lock: Option<Lock>,
    /// The ZIM scan is done on the job's thread; the source is built from it there.
    deferred: Option<Deferred>,
}

enum Deferred {
    Zim(ZimSource),
}

impl BuildRequest {
    /// The build lock, to be held by the job for its whole run.
    pub fn take_lock(&mut self) -> Option<Lock> {
        self.lock.take()
    }
}

struct Placeholder;

impl ItemSource for Placeholder {
    fn tokenizer(&self) -> String {
        "en_stem".into()
    }
    fn name(&self) -> String {
        String::new()
    }
    fn extra(&self) -> Map<String, Value> {
        Map::new()
    }
    fn items(&self) -> Result<Vec<String>> {
        Ok(Vec::new())
    }
    fn load(&self, _key: &str, _previous: Option<&Previous>) -> Result<Item> {
        Err(Error::internal("source not ready"))
    }
}

/// Check the parameters, find the source and take the build lock: `bad_json` for bad parameters, `not_found` for a source
/// that is not here (no such saved video, no such ZIM), `busy` while another job builds it.
pub fn prepare(params_json: &str) -> Result<BuildRequest> {
    let p: Params = serde_json::from_str(params_json)?;
    if p.indexes_dir.is_empty() {
        return Err(Error::bad_json("indexes_dir must not be empty"));
    }
    if !kwindex::is_kind(&p.kind) {
        return Err(Error::bad_json(format!(
            "kind must be one of captions, zim-captions, zim-epub, not {:?}",
            p.kind
        )));
    }
    let source_id = kwindex::norm_source_id(&p.source_id);
    let dir = kwindex::dir_for(Path::new(&p.indexes_dir), &p.kind, &source_id);
    let (src, deferred): (Box<dyn ItemSource>, Option<Deferred>) = if p.kind == CAPTIONS {
        if !valid_video_source(&source_id) {
            return Err(Error::bad_json("source_id of captions must be <host>/<video uuid>"));
        }
        let folder = video_folder(&source_id, p.video_dir.as_deref().map(Path::new))
            .ok_or_else(|| Error::not_found(format!("no saved video {source_id:?}")))?;
        let manifest: Value = std::fs::read(folder.join("manifest.json"))
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or(Value::Null);
        let (host, uuid) = source_id.split_once('/').unwrap_or(("", ""));
        let title = manifest["title"]
            .as_str()
            .filter(|t| !t.trim().is_empty())
            .unwrap_or(uuid)
            .to_string();
        (
            Box::new(VideoSource {
                dir: folder,
                title,
                uuid: uuid.to_string(),
                host: host.to_string(),
            }),
            None,
        )
    } else {
        if !zimsrc::is_uuid(&source_id) {
            return Err(Error::bad_json("source_id of a zim kind must be the ZIM's uuid"));
        }
        let path = p
            .zim_path
            .as_deref()
            .map(PathBuf::from)
            .or_else(|| zim_location(&source_id))
            .ok_or_else(|| Error::not_found(format!("no zim {source_id} is open; open it, or give zim_path")))?;
        let zim = ZimSource::open(&path)?;
        if zim.id != source_id {
            return Err(Error::bad_json(format!(
                "{} is zim {}, not {source_id}",
                path.display(),
                zim.id
            )));
        }
        (Box::new(Placeholder), Some(Deferred::Zim(zim)))
    };
    let previous_dir = match (&p.previous, p.kind.as_str()) {
        (Some(pv), ZIM_EPUB) if zimsrc::is_uuid(&pv.zim_uuid) => Some((
            kwindex::dir_for(Path::new(&p.indexes_dir), &p.kind, &pv.zim_uuid),
            pv.zim_uuid.to_ascii_lowercase(),
        )),
        _ => None,
    };
    let build = dir.join(BUILD_DIR);
    let lock = Lock::acquire(&build)?;
    Ok(BuildRequest {
        kind: p.kind,
        source_id,
        dir,
        build,
        src,
        previous_dir,
        batch_items: p.batch_items.unwrap_or(BATCH_ITEMS).max(1),
        crash_after: p.crash_after,
        hold_ms: p.hold_ms,
        lock: Some(lock),
        deferred,
    })
}

fn load_previous(req: &BuildRequest, zim_name: &str) -> Option<Previous> {
    let (dir, uuid) = req.previous_dir.as_ref()?;
    if *uuid == req.source_id {
        return None;
    }
    let picked = kwindex::pick(dir, &req.kind, uuid)?;
    if picked.manifest.extra.get("zim_name").and_then(Value::as_str) != Some(zim_name) {
        return None;
    }
    let text = std::fs::read_to_string(picked.dir.join(kwindex::record_file(&req.kind))).ok()?;
    let index = KwIndex::open(&req.kind, &picked.name, &picked.dir, picked.manifest).ok()?;
    Some(Previous {
        index,
        rows: kwindex::rows_from_tsv(&text)
            .into_iter()
            .map(|r| (r.path.clone(), r))
            .collect(),
    })
}

// ---------------------------------------------------------------------------------------------------------
// The build

struct Writer<'a> {
    build: &'a Path,
    fields: Fields,
    w: IndexWriter<TantivyDocument>,
    rec: DoneRecord,
    pending: Vec<String>,
    /// Deletions not yet committed.
    dirty: bool,
    last_commit: Instant,
}

impl Writer<'_> {
    fn commit(&mut self) -> Result<()> {
        if self.pending.is_empty() && !self.dirty {
            return Ok(());
        }
        let entries = self.rec.lines + self.pending.len();
        let mut pc = tv(self.w.prepare_commit())?;
        pc.set_payload(&json!({"entries": entries}).to_string());
        tv(pc.commit())?;
        let path = self.build.join(DONE_FILE);
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&path)
            .map_err(|e| Error::io(format!("{}: {e}", path.display())))?;
        let mut text = self.pending.join("\n");
        text.push('\n');
        f.write_all(text.as_bytes())
            .and_then(|_| f.sync_all())
            .map_err(|e| Error::io(format!("{}: {e}", path.display())))?;
        self.rec.lines = entries;
        self.pending.clear();
        self.dirty = false;
        self.last_commit = Instant::now();
        Ok(())
    }

    fn put(&mut self, key: &str, source_title: &str, loaded: Loaded) -> Result<()> {
        let f = self.fields;
        self.w.delete_term(Term::from_field_text(f.item, key));
        let title = loaded.title.clone().unwrap_or_else(|| source_title.to_string());
        for (i, p) in loaded.pieces.iter().enumerate() {
            let d = doc!(
                f.pid => pid_of(key, i as u64),
                f.item => key,
                f.piece => i as u64,
                f.title => title.as_str(),
                f.text => p.text.as_str(),
                f.lang => p.lang.as_str(),
                f.start_ms => p.start_ms,
                f.end_ms => p.end_ms,
                f.chapter => p.chapter.as_str(),
                f.block => p.block,
                f.heading_path => serde_json::to_string(&p.heading_path).unwrap_or_default(),
                f.video => p.video.as_str()
            );
            tv(self.w.add_document(d))?;
        }
        let n = loaded.pieces.len() as u64;
        self.rec.skipped.remove(key);
        self.rec.done.insert(
            key.to_string(),
            Added {
                pieces: n,
                size: loaded.size,
                sha256: loaded.sha256.clone(),
            },
        );
        self.pending
            .push(line_for("d", key, &n.to_string(), loaded.size, &loaded.sha256));
        Ok(())
    }

    fn skip(&mut self, key: &str, reason: &str, size: Option<u64>, sha: &str) {
        let f = self.fields;
        if self.rec.done.remove(key).is_some() {
            self.w.delete_term(Term::from_field_text(f.item, key));
        }
        self.rec.skipped.insert(
            key.to_string(),
            Skipped {
                reason: reason.to_string(),
                size,
                sha256: sha.to_string(),
            },
        );
        self.pending.push(line_for("s", key, reason, size, sha));
    }
}

/// A usable snapshot of the source arrived (from a sync) or was already there: its result.
fn existing_result(req: &BuildRequest) -> Option<Value> {
    if !kwindex::has_published(&req.dir, &req.kind, &req.source_id) {
        return None;
    }
    let pk = kwindex::pick(&req.dir, &req.kind, &req.source_id)?;
    let n = |k: &str| pk.manifest.extra.get(k).and_then(Value::as_u64).unwrap_or(0);
    let bytes: u64 = pk.manifest.files.iter().map(|f| f.size).sum();
    Some(
        json!({"items": n("items"), "pieces": n("pieces"), "skipped": n("skipped"), "bytes": bytes, "snapshot": pk.name, "existing": true}),
    )
}

/// Build the index and publish it. `progress(phase, done, total)`; `cancelled()` is asked until the publish step.
/// Returns the outcome and, when done, `{"items","pieces","skipped","bytes","snapshot"}` (and `"resumed"`: the items a
/// resumed build found already done, `"reused"`: the EPUBs copied from the older edition).
pub fn run(
    req: &mut BuildRequest,
    progress: &dyn Fn(&str, u64, u64),
    cancelled: &dyn Fn() -> bool,
) -> Result<(Outcome, Option<Value>)> {
    progress("read", 0, 0);
    if let Some(r) = existing_result(req) {
        return Ok((Outcome::Done, Some(r)));
    }
    // a ZIM source lists its entries first
    let mut prev_name = String::new();
    if let Some(Deferred::Zim(zim)) = req.deferred.take() {
        prev_name = zim_name_of(&zim);
        let media = scan_zim(&zim, false)?;
        req.src = if req.kind == ZIM_CAPTIONS {
            Box::new(ZimCaptionsSource { src: zim, media })
        } else {
            Box::new(ZimEpubSource { src: zim, media })
        };
    }
    if cancelled() {
        return Ok((Outcome::Cancelled, None));
    }
    let previous = load_previous(req, &prev_name);
    let items = req.src.items()?;
    let item_set: BTreeSet<&String> = items.iter().collect();
    let total = items.len() as u64;
    let build = &req.build;
    let want = BuildMeta {
        kind: req.kind.clone(),
        source_id: req.source_id.clone(),
        format: FORMAT,
        chunker: kwindex::chunker_of(&req.kind),
        tokenizer: req.src.tokenizer(),
    };
    let resume = read_build_meta(build).as_ref() == Some(&want) && build.join("meta.json").exists();
    if !resume {
        crate::index::wipe_dir(build);
        let _ = std::fs::remove_file(build.join(BUILD_META));
    }
    let (schema, _) = build_schema();
    let index = if resume {
        tv(Index::open_in_dir(build))?
    } else {
        tv(Index::create_in_dir(build, schema))?
    };
    index.tokenizers().register(ANALYZER, make_analyzer(&want.tokenizer));
    let fields = fields_of(&index)?;
    write_json_atomic(&build.join(BUILD_META), &want)?;
    let rec = if resume {
        load_done(build, payload_entries(&index))
    } else {
        DoneRecord::default()
    };
    let resumed = (rec.done.len() + rec.skipped.len()) as u64;
    let writer = tv(index.writer_with_num_threads::<TantivyDocument>(1, HEAP_BYTES))?;
    let mut w = Writer {
        build,
        fields,
        w: writer,
        rec,
        pending: Vec::new(),
        dirty: false,
        last_commit: Instant::now(),
    };

    // 1. read every item that is not done yet
    let name = req.src.name();
    let mut processed = 0usize;
    let mut reused = 0u64;
    for (k, key) in items.iter().enumerate() {
        progress("read", k as u64, total);
        if w.rec.done.contains_key(key) || w.rec.skipped.contains_key(key) {
            continue;
        }
        if cancelled() {
            w.commit()?;
            tv(w.w.wait_merging_threads())?;
            return Ok((Outcome::Cancelled, None));
        }
        if req.crash_after.is_some_and(|n| processed >= n) {
            // the test's "kill": what is not committed is lost, nothing else is written
            w.pending.clear();
            return Err(Error::internal("test: the build was killed"));
        }
        match req.src.load(key, previous.as_ref()) {
            Ok(Item::Added(l)) => {
                reused += l.reused as u64;
                w.put(key, &name, l)?
            }
            Ok(Item::Skipped { reason, size, sha256 }) => w.skip(key, &reason, size, &sha256),
            // an item that cannot be read at all is recorded as damaged, not retried on every resume
            Err(e) if e.code == crate::ErrorCode::NotFound || e.code == crate::ErrorCode::Io => {
                w.skip(key, "damaged", None, "")
            }
            Err(e) => return Err(e),
        }
        processed += 1;
        if w.pending.len() >= req.batch_items || w.last_commit.elapsed() >= Duration::from_secs(BATCH_SECS) {
            w.commit()?;
            // a usable snapshot arrived from another device: stop and use it
            if let Some(r) = existing_result(req) {
                drop(w);
                let _ = std::fs::remove_dir_all(&req.build);
                return Ok((Outcome::Done, Some(r)));
            }
        }
    }
    progress("read", total, total);

    // 2. items that are no longer in the source (a resumed build of a changed source) leave the index
    let stale: Vec<String> = w
        .rec
        .done
        .keys()
        .chain(w.rec.skipped.keys())
        .filter(|k| !item_set.contains(k))
        .cloned()
        .collect();
    for k in stale {
        w.w.delete_term(Term::from_field_text(fields.item, &k));
        w.rec.done.remove(&k);
        w.rec.skipped.remove(&k);
        w.dirty = true;
    }
    progress("index", 0, 1);
    w.commit()?;
    let Writer { w: mut writer, rec, .. } = w;
    if cancelled() {
        tv(writer.wait_merging_threads())?;
        return Ok((Outcome::Cancelled, None));
    }
    progress("index", 1, 1);

    // 3. merge to one segment
    progress("merge", 0, 1);
    let t0 = Instant::now();
    while t0.elapsed() < Duration::from_millis(req.hold_ms) && !cancelled() {
        std::thread::sleep(Duration::from_millis(10));
    }
    if cancelled() {
        tv(writer.wait_merging_threads())?;
        return Ok((Outcome::Cancelled, None));
    }
    let segs = tv(index.searchable_segment_ids())?;
    if segs.len() > 1 {
        let _ = tv(writer.merge(&segs).wait())?;
    }
    tv(writer.garbage_collect_files().wait())?;
    tv(writer.wait_merging_threads())?;
    progress("merge", 1, 1);
    if cancelled() {
        return Ok((Outcome::Cancelled, None));
    }
    let docs = tv(index.reader())?.searcher().num_docs();

    // 4. the item record, then the snapshot's files, moved into the publish folder and hashed as they are read
    let mut rows: Vec<ItemRow> = rec
        .done
        .iter()
        .filter(|(p, _)| item_set.contains(p))
        .map(|(p, a)| ItemRow {
            path: p.clone(),
            size: a.size,
            sha256: a.sha256.clone(),
            pieces: a.pieces,
            status: "added".into(),
        })
        .chain(
            rec.skipped
                .iter()
                .filter(|(p, _)| item_set.contains(p))
                .map(|(p, k)| ItemRow {
                    path: p.clone(),
                    size: k.size,
                    sha256: k.sha256.clone(),
                    pieces: 0,
                    status: format!("skipped:{}", k.reason),
                }),
        )
        .collect();
    rows.sort_by(|a, b| a.path.cmp(&b.path));
    let record = kwindex::record_file(&req.kind);
    std::fs::write(build.join(record), kwindex::rows_to_tsv(&rows)).map_err(|e| Error::io(format!("{record}: {e}")))?;
    let Some(stage) = snapshot::stage(
        build,
        &NOT_IN_SNAPSHOT,
        true,
        &|d, t| progress("manifest", d, t + 1),
        cancelled,
    )?
    else {
        return Ok((Outcome::Cancelled, None));
    };
    let (n_items, skipped, bytes, build_id) = (
        rec.done.len() as u64,
        rec.skipped.len() as u64,
        stage.bytes,
        stage.build_id.clone(),
    );
    let mut extra = req.src.extra();
    extra.insert("items".into(), json!(n_items));
    extra.insert("pieces".into(), json!(docs));
    extra.insert("skipped".into(), json!(skipped));
    let manifest = Manifest {
        kind: req.kind.clone(),
        source_id: req.source_id.clone(),
        format: FORMAT,
        tantivy: TANTIVY.to_string(),
        tokenizer: Some(Tokenizer {
            name: want.tokenizer.clone(),
            analyzer: ANALYZER.to_string(),
            remove_long: 40,
        }),
        chunker: Some(want.chunker),
        core: env!("CARGO_PKG_VERSION").to_string(),
        created: snapshot::iso_now(),
        extra,
        files: Vec::new(),
    };
    if cancelled() {
        snapshot::abort(&stage);
        return Ok((Outcome::Cancelled, None));
    }

    // 5. publish: manifest last, one rename; the build is no longer needed
    progress("publish", 0, 1);
    snapshot::publish(&req.dir, stage, manifest)?;
    let _ = std::fs::remove_dir_all(build);
    progress("publish", 1, 1);
    Ok((
        Outcome::Done,
        Some(
            json!({"items": n_items, "pieces": docs, "skipped": skipped, "bytes": bytes, "snapshot": build_id, "resumed": resumed, "reused": reused}),
        ),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn languages_come_from_file_names() {
        for (name, lang) in [
            ("captions-en.vtt", "en"),
            ("captions-fr-CA.vtt", "fr-ca"),
            ("FEMA_UHA_video01_en.srt", "en"),
            ("talk.es.vtt", "es"),
            ("Media/lesson_eng.srt", "eng"),
            ("captions-und.vtt", "und"),
            ("plain.vtt", "und"),
            ("intro_video.srt", "und"),
        ] {
            assert_eq!(lang_of_file(name), lang, "{name}");
        }
    }

    #[test]
    fn a_caption_pairs_with_the_video_of_its_base_name() {
        assert_eq!(
            pair_base("v/FEMA_UHA_video01_en.srt"),
            ("v".into(), "FEMA_UHA_video01".into())
        );
        assert_eq!(
            pair_base("v/FEMA_UHA_video01.mp4"),
            ("v".into(), "FEMA_UHA_video01".into())
        );
        assert_eq!(pair_base("talk.es.vtt"), (String::new(), "talk".into()));
        assert_eq!(pair_base("a/no_lang_here.vtt").1, "no_lang_here");
    }

    #[test]
    fn only_caption_and_epub_types_start_a_walk() {
        let l = |v: &[&str]| v.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(!walk_candidates(&l(&[
            "text/html",
            "text/plain",
            "application/octet-stream",
            "application/pdf",
            "image/png"
        ])));
        assert!(!walk_candidates(&[]));
        for m in [
            "text/vtt",
            "text/vtt; charset=utf-8",
            "application/x-subrip",
            "text/srt",
            "application/epub+zip",
            "Application/EPUB+zip",
        ] {
            assert!(walk_candidates(&l(&["text/html", m])), "{m}");
        }
    }

    #[test]
    fn video_sources_need_a_host_and_a_safe_uuid() {
        assert!(valid_video_source("peertube.example/9f2e"));
        assert!(!valid_video_source("peertube.example"));
        assert!(!valid_video_source("../x/y"));
        assert!(!valid_video_source("a/b/c"));
    }
}
