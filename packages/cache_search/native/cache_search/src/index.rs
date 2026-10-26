//! The Tantivy keyword index of one ZIM: schema, tokenizer, the `cache_search_index.json` record, the
//! build lock, and the resumable build loop used by `index_zim` jobs.
//!
//! Layout of an `index_dir`:
//! - the Tantivy index files (`meta.json`, segments, ...);
//! - `cache_search_index.json`: `{"index_format","tokenizer","zim_uuid","state","next_entry","total"}`;
//! - `cache_search_index.lock`: present only while a job builds the index (see `Lock`).
//!
//! Checkpoints: every `checkpoint_articles` indexed articles the build commits to Tantivy with the payload
//! `{"next_entry":N}` and then rewrites the JSON record. The commit payload is the authority on resume (it is
//! written atomically with the segments), so a job killed at any point resumes from the last commit; documents
//! after it were never committed and are discarded by Tantivy, so nothing is duplicated and nothing needs to be
//! deleted by path.

use crate::error::{Error, ErrorCode, Result};
use crate::html;
use crate::zimsrc::ZimSource;
use serde::{Deserialize, Serialize};
use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::SystemTime;
use tantivy::schema::{Field, IndexRecordOption, Schema, TextFieldIndexing, TextOptions, STORED, STRING};
use tantivy::tokenizer::{Language, LowerCaser, RemoveLongFilter, SimpleTokenizer, Stemmer, TextAnalyzer};
use tantivy::{doc, Index, IndexReader, ReloadPolicy, TantivyDocument};
use zim::{MimeType, Namespace, Target};

pub const INDEX_FORMAT: u32 = 2;
pub const META_FILE: &str = "cache_search_index.json";
pub const LOCK_FILE: &str = "cache_search_index.lock";
/// Name under which the ZIM's analyzer is registered in Tantivy (stored in the schema).
pub const ANALYZER: &str = "cs_text";
/// Characters of the plain text kept in the stored `lead` field.
pub const LEAD_CHARS: usize = 1500;
/// Upper bound on the indexed body of a single article, in bytes.
pub const MAX_BODY_BYTES: usize = 4 * 1024 * 1024;
pub const DEFAULT_CHECKPOINT: usize = 2000;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct IndexMeta {
    pub index_format: u32,
    pub tokenizer: String,
    pub zim_uuid: String,
    pub state: String,
    pub next_entry: u64,
    pub total: u64,
}

pub fn read_meta(dir: &Path) -> Option<IndexMeta> {
    let s = std::fs::read_to_string(dir.join(META_FILE)).ok()?;
    serde_json::from_str(&s).ok()
}

pub(crate) fn write_meta(dir: &Path, m: &IndexMeta) -> Result<()> {
    let tmp = dir.join(format!("{META_FILE}.tmp"));
    let s = serde_json::to_string(m).map_err(|e| Error::internal(e.to_string()))?;
    std::fs::write(&tmp, s).map_err(|e| Error::io(format!("{}: {e}", tmp.display())))?;
    std::fs::rename(&tmp, dir.join(META_FILE)).map_err(|e| Error::io(format!("{}: {e}", dir.display())))
}

// ---------- language / tokenizer ----------

/// (tokenizer name, Tantivy stemmer language) for a ZIM `Language` metadata value (ISO 639-3 or 639-1; the
/// first of a comma-separated list). `None` for anything else, which then uses the English default.
pub fn stemmer_for_language(lang: Option<&str>) -> Option<(&'static str, Language)> {
    let first = lang?.split(',').next()?.trim().to_ascii_lowercase();
    Some(match first.as_str() {
        "eng" | "en" => ("en_stem", Language::English),
        "ara" | "ar" => ("ar_stem", Language::Arabic),
        "dan" | "da" => ("da_stem", Language::Danish),
        "nld" | "dut" | "nl" => ("nl_stem", Language::Dutch),
        "fin" | "fi" => ("fi_stem", Language::Finnish),
        "fra" | "fre" | "fr" => ("fr_stem", Language::French),
        "deu" | "ger" | "de" => ("de_stem", Language::German),
        "ell" | "gre" | "el" => ("el_stem", Language::Greek),
        "hun" | "hu" => ("hu_stem", Language::Hungarian),
        "ita" | "it" => ("it_stem", Language::Italian),
        "nor" | "nob" | "nno" | "no" | "nb" | "nn" => ("no_stem", Language::Norwegian),
        "por" | "pt" => ("pt_stem", Language::Portuguese),
        "ron" | "rum" | "ro" => ("ro_stem", Language::Romanian),
        "rus" | "ru" => ("ru_stem", Language::Russian),
        "spa" | "es" => ("es_stem", Language::Spanish),
        "swe" | "sv" => ("sv_stem", Language::Swedish),
        "tam" | "ta" => ("ta_stem", Language::Tamil),
        "tur" | "tr" => ("tr_stem", Language::Turkish),
        _ => return None,
    })
}

/// The tokenizer name for a ZIM (`en_stem` unless its language has a Tantivy stemmer).
pub fn tokenizer_name_for(lang: Option<&str>) -> &'static str {
    stemmer_for_language(lang).map(|x| x.0).unwrap_or("en_stem")
}

fn language_of_tokenizer(name: &str) -> Language {
    for code in ["en", "ar", "da", "nl", "fi", "fr", "de", "el", "hu", "it", "no", "pt", "ro", "ru", "es", "sv", "ta", "tr"] {
        if name == format!("{code}_stem") {
            if let Some((_, l)) = stemmer_for_language(Some(code)) {
                return l;
            }
        }
    }
    Language::English
}

pub fn make_analyzer(tokenizer_name: &str) -> TextAnalyzer {
    TextAnalyzer::builder(SimpleTokenizer::default())
        .filter(RemoveLongFilter::limit(40))
        .filter(LowerCaser)
        .filter(Stemmer::new(language_of_tokenizer(tokenizer_name)))
        .build()
}

// ---------- schema ----------

#[derive(Clone, Copy)]
pub struct Fields {
    pub path: Field,
    pub title: Field,
    pub lead: Field,
    pub body: Field,
}

pub fn build_schema() -> (Schema, Fields) {
    let mut sb = Schema::builder();
    let path = sb.add_text_field("path", STRING | STORED);
    let with_pos = TextFieldIndexing::default()
        .set_tokenizer(ANALYZER)
        .set_index_option(IndexRecordOption::WithFreqsAndPositions);
    let freqs_only = TextFieldIndexing::default()
        .set_tokenizer(ANALYZER)
        .set_index_option(IndexRecordOption::WithFreqs);
    let title = sb.add_text_field("title", TextOptions::default().set_indexing_options(with_pos.clone()).set_stored());
    let lead = sb.add_text_field("lead", TextOptions::default().set_indexing_options(with_pos).set_stored());
    let body = sb.add_text_field("body", TextOptions::default().set_indexing_options(freqs_only));
    (sb.build(), Fields { path, title, lead, body })
}

pub fn fields_of(index: &Index) -> Result<Fields> {
    let s = index.schema();
    let f = |n: &str| s.get_field(n).map_err(|e| Error::internal(format!("index schema: {e}")));
    Ok(Fields { path: f("path")?, title: f("title")?, lead: f("lead")?, body: f("body")? })
}

pub(crate) fn tv<T>(r: std::result::Result<T, tantivy::TantivyError>) -> Result<T> {
    r.map_err(|e| Error::io(format!("tantivy: {e}")))
}

// ---------- lock ----------

static ACTIVE: Mutex<Option<HashSet<PathBuf>>> = Mutex::new(None);

fn canon(dir: &Path) -> PathBuf {
    std::fs::canonicalize(dir).unwrap_or_else(|_| dir.to_path_buf())
}

fn active_contains(dir: &Path) -> bool {
    ACTIVE.lock().ok().map(|g| g.as_ref().map(|s| s.contains(&canon(dir))).unwrap_or(false)).unwrap_or(false)
}

#[derive(Serialize, Deserialize)]
struct LockInfo {
    pid: u32,
    /// Process start time in clock ticks since boot (`/proc/<pid>/stat` field 22), if /proc is readable.
    start_ticks: Option<u64>,
    boot_id: Option<String>,
    /// Unix seconds when the job started (informational).
    started: u64,
}

fn proc_start_ticks(pid: u32) -> Option<u64> {
    let s = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
    // the command name is in parentheses and may contain spaces: fields resume after the last ')'
    let rest = &s[s.rfind(')')? + 1..];
    // rest fields: state(3) ppid(4) ... starttime(22) => index 19
    rest.split_whitespace().nth(19)?.parse().ok()
}

fn boot_id() -> Option<String> {
    std::fs::read_to_string("/proc/sys/kernel/random/boot_id").ok().map(|s| s.trim().to_string())
}

/// Is the lock file at `dir` held by a live job?
///
/// Detection: the lock records the owner's pid, its process start time (clock ticks, from /proc) and the boot
/// id. It is stale (dead owner) when the boot id differs, when /proc/<pid> does not exist, or when that pid's
/// start time differs (the pid was reused). When the owner is this very process, it is live only if a job here
/// currently holds the directory (an in-process registry), so a leaked lock from a crashed job thread does not
/// block. If /proc is unreadable the owner of another pid cannot be checked and is assumed live only if the lock
/// is younger than 24 hours; an unparsable lock file is stale.
pub fn lock_is_live(dir: &Path) -> bool {
    let p = dir.join(LOCK_FILE);
    let Ok(s) = std::fs::read_to_string(&p) else { return false };
    let Ok(info) = serde_json::from_str::<LockInfo>(&s) else { return false };
    if info.pid == std::process::id() {
        return active_contains(dir);
    }
    if let (Some(a), Some(b)) = (&info.boot_id, boot_id()) {
        if *a != b {
            return false;
        }
    }
    if !Path::new("/proc/self/stat").exists() {
        let now = SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
        return now.saturating_sub(info.started) < 24 * 3600;
    }
    match proc_start_ticks(info.pid) {
        None => false,
        Some(t) => info.start_ticks.map(|x| x == t).unwrap_or(true),
    }
}

/// Held by a running job; removes the lock file and the registry entry on drop.
pub struct Lock {
    dir: PathBuf,
    canon: PathBuf,
}

impl Lock {
    /// Take the build lock for `dir` (created if missing). `busy` if a live job holds it; a stale lock is
    /// replaced.
    pub fn acquire(dir: &Path) -> Result<Lock> {
        std::fs::create_dir_all(dir).map_err(|e| Error::io(format!("{}: {e}", dir.display())))?;
        let canon = canon(dir);
        let path = dir.join(LOCK_FILE);
        let info = LockInfo {
            pid: std::process::id(),
            start_ticks: proc_start_ticks(std::process::id()),
            boot_id: boot_id(),
            started: SystemTime::now().duration_since(SystemTime::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0),
        };
        let body = serde_json::to_string(&info).map_err(|e| Error::internal(e.to_string()))?;
        for attempt in 0..2 {
            // register first so an in-process check never sees our own fresh lock as stale
            {
                let mut g = ACTIVE.lock().map_err(|_| Error::internal("lock registry poisoned"))?;
                let set = g.get_or_insert_with(HashSet::new);
                if set.contains(&canon) {
                    return Err(Error::new(ErrorCode::Busy, format!("{} is being indexed", dir.display())));
                }
                set.insert(canon.clone());
            }
            let created = std::fs::OpenOptions::new().write(true).create_new(true).open(&path);
            match created {
                Ok(mut f) => {
                    use std::io::Write;
                    let _ = f.write_all(body.as_bytes());
                    return Ok(Lock { dir: dir.to_path_buf(), canon });
                }
                Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
                    let unregister = || {
                        if let Ok(mut g) = ACTIVE.lock() {
                            if let Some(s) = g.as_mut() {
                                s.remove(&canon);
                            }
                        }
                    };
                    // evaluate with ourselves unregistered, so a leaked same-process lock reads as stale
                    unregister();
                    if lock_is_live(dir) {
                        return Err(Error::new(ErrorCode::Busy, format!("{} is being indexed", dir.display())));
                    }
                    let _ = std::fs::remove_file(&path);
                    if attempt == 1 {
                        break;
                    }
                }
                Err(e) => {
                    if let Ok(mut g) = ACTIVE.lock() {
                        if let Some(s) = g.as_mut() {
                            s.remove(&canon);
                        }
                    }
                    return Err(Error::io(format!("{}: {e}", path.display())));
                }
            }
        }
        Err(Error::new(ErrorCode::Busy, format!("{} is being indexed", dir.display())))
    }
}

impl Drop for Lock {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(self.dir.join(LOCK_FILE));
        if let Ok(mut g) = ACTIVE.lock() {
            if let Some(s) = g.as_mut() {
                s.remove(&self.canon);
            }
        }
    }
}

// ---------- state of an index_dir ----------

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum IndexState {
    /// No index (no directory, no record, or an unreadable record, or built from another ZIM).
    Missing,
    /// A live job is building it.
    Building,
    /// A build was started and not finished, and no job is running (resumable).
    Incomplete,
    /// Built by another index format.
    Stale,
    Done(IndexMeta),
}

pub fn index_state(dir: Option<&Path>, zim_uuid: &str) -> IndexState {
    let Some(dir) = dir else { return IndexState::Missing };
    if lock_is_live(dir) {
        return IndexState::Building;
    }
    let Some(m) = read_meta(dir) else { return IndexState::Missing };
    if m.index_format != INDEX_FORMAT {
        return IndexState::Stale;
    }
    if m.zim_uuid != zim_uuid {
        return IndexState::Missing;
    }
    if m.state == "done" {
        IndexState::Done(m)
    } else {
        IndexState::Incomplete
    }
}

// ---------- opened index (search side) ----------

pub struct OpenIndex {
    pub index: Index,
    pub reader: IndexReader,
    pub fields: Fields,
    pub docs: u64,
    stamp: Option<(SystemTime, u64)>,
}

pub(crate) fn stamp_of(dir: &Path) -> Option<(SystemTime, u64)> {
    let m = std::fs::metadata(dir.join("meta.json")).ok()?;
    Some((m.modified().ok()?, m.len()))
}

impl OpenIndex {
    pub fn open(dir: &Path, tokenizer_name: &str) -> Result<OpenIndex> {
        let stamp = stamp_of(dir);
        let index = tv(Index::open_in_dir(dir))?;
        index.tokenizers().register(ANALYZER, make_analyzer(tokenizer_name));
        let fields = fields_of(&index)?;
        let reader = tv(index.reader_builder().reload_policy(ReloadPolicy::Manual).try_into())?;
        let docs = reader.searcher().num_docs();
        Ok(OpenIndex { index, reader, fields, docs, stamp })
    }
    /// True if the index files changed on disk since this was opened.
    pub fn is_outdated(&self, dir: &Path) -> bool {
        stamp_of(dir) != self.stamp
    }
}

// ---------- build ----------

pub struct BuildParams<'a> {
    pub zim: &'a ZimSource,
    pub index_dir: &'a Path,
    pub heap_mb: usize,
    pub checkpoint_articles: usize,
}

#[derive(Debug, PartialEq, Eq)]
pub enum Outcome {
    Done,
    Cancelled,
}

pub(crate) fn wipe_dir(dir: &Path) {
    if let Ok(rd) = std::fs::read_dir(dir) {
        for e in rd.flatten() {
            if e.file_name() == LOCK_FILE {
                continue;
            }
            if e.file_type().map(|t| t.is_file()).unwrap_or(false) {
                let _ = std::fs::remove_file(e.path());
            }
        }
    }
}

fn payload_next_entry(index: &Index) -> Option<u64> {
    let metas = index.load_metas().ok()?;
    let v: serde_json::Value = serde_json::from_str(metas.payload.as_deref()?).ok()?;
    v.get("next_entry")?.as_u64()
}

/// Candidate article found while scanning directory entries.
struct Cand {
    cluster: u32,
    blob: u32,
    title: String,
    path: String,
}

/// Build (or resume) the index of `p.zim` in `p.index_dir`. The caller holds the `Lock`. `progress(done, total)`
/// is called after each checkpoint; `cancelled()` is checked before each window of `checkpoint_articles`
/// articles. Returns `Outcome::Cancelled` after a checkpoint without finishing.
pub fn build_zim_index(
    p: &BuildParams,
    progress: &dyn Fn(u64, u64),
    cancelled: &dyn Fn() -> bool,
) -> Result<Outcome> {
    let dir = p.index_dir;
    let zim = p.zim;
    let czim = zim.zim()?;
    let total = zim.entry_count();
    let tokenizer = tokenizer_name_for(zim.language.as_deref());

    // Decide: fresh, resume, or already done.
    let mut meta = IndexMeta {
        index_format: INDEX_FORMAT,
        tokenizer: tokenizer.to_string(),
        zim_uuid: zim.id.clone(),
        state: "building".into(),
        next_entry: 0,
        total,
    };
    let tantivy_meta_exists = dir.join("meta.json").exists();
    let index: Index;
    match read_meta(dir) {
        Some(m) if m.index_format == INDEX_FORMAT && m.zim_uuid == zim.id => {
            if m.state == "done" && tantivy_meta_exists {
                progress(m.total, m.total);
                return Ok(Outcome::Done);
            }
            meta.tokenizer = m.tokenizer.clone();
            if tantivy_meta_exists {
                index = tv(Index::open_in_dir(dir))?;
                meta.next_entry = payload_next_entry(&index).unwrap_or(0);
            } else {
                index = tv(Index::create_in_dir(dir, build_schema().0))?;
            }
        }
        Some(_) => {
            // ours, but another format or another ZIM: rebuild from scratch
            wipe_dir(dir);
            index = tv(Index::create_in_dir(dir, build_schema().0))?;
        }
        None => {
            if tantivy_meta_exists {
                return Err(Error::io(format!(
                    "{} holds an index not built by cache_search; refusing to overwrite it",
                    dir.display()
                )));
            }
            index = tv(Index::create_in_dir(dir, build_schema().0))?;
        }
    }
    index.tokenizers().register(ANALYZER, make_analyzer(&meta.tokenizer));
    let f = fields_of(&index)?;
    write_meta(dir, &meta)?;

    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).clamp(1, 4);
    let heap = p.heap_mb.max(15 * threads) * 1_000_000;
    let mut writer = tv(index.writer_with_num_threads::<TantivyDocument>(threads, heap))?;

    let checkpoint = p.checkpoint_articles.max(1);
    let mut next = meta.next_entry.min(total);
    progress(next, total);
    loop {
        if next >= total {
            break;
        }
        if cancelled() {
            return Ok(Outcome::Cancelled);
        }
        // 1. scan directory entries until `checkpoint` HTML articles are collected
        let mut cands: Vec<Cand> = Vec::with_capacity(checkpoint);
        while next < total && cands.len() < checkpoint {
            let idx = next as u32;
            next += 1;
            let Ok(e) = czim.get_by_url_index(idx) else { continue };
            if !matches!(e.namespace, Namespace::UserContent | Namespace::Articles) {
                continue;
            }
            let MimeType::Type(m) = &e.mime_type else { continue };
            if !m.to_ascii_lowercase().starts_with("text/html") {
                continue;
            }
            let Some(Target::Cluster(cluster, blob)) = e.target else { continue };
            let title = if e.title.is_empty() { e.url.clone() } else { e.title.clone() };
            cands.push(Cand { cluster, blob, title, path: e.url });
        }
        // 2. read by cluster so each cluster is decompressed once
        cands.sort_by_key(|c| (c.cluster, c.blob));
        let mut i = 0;
        while i < cands.len() {
            let c0 = cands[i].cluster;
            let mut j = i;
            while j < cands.len() && cands[j].cluster == c0 {
                j += 1;
            }
            if let Ok(cl) = czim.get_cluster(c0) {
                if let Ok(g) = cl.read() {
                    for c in &cands[i..j] {
                        let Ok(blob) = g.blob(c.blob) else { continue };
                        let text = html::html_to_text(&String::from_utf8_lossy(blob));
                        if text.is_empty() {
                            continue;
                        }
                        let text = body_text(&text, &c.title);
                        let lead = html::lead_of(text, LEAD_CHARS);
                        let body = cap_bytes(text, MAX_BODY_BYTES);
                        tv(writer.add_document(doc!(
                            f.path => c.path.as_str(),
                            f.title => c.title.as_str(),
                            f.lead => lead,
                            f.body => body
                        )))?;
                    }
                }
            }
            i = j;
        }
        // 3. checkpoint
        meta.next_entry = next;
        let mut pc = tv(writer.prepare_commit())?;
        pc.set_payload(&serde_json::json!({ "next_entry": next }).to_string());
        tv(pc.commit())?;
        write_meta(dir, &meta)?;
        progress(next, total);
    }
    // final commit (also for an empty or already-complete scan) and merge
    let mut pc = tv(writer.prepare_commit())?;
    pc.set_payload(&serde_json::json!({ "next_entry": total }).to_string());
    tv(pc.commit())?;
    tv(writer.wait_merging_threads())?;
    meta.next_entry = total;
    meta.state = "done".into();
    write_meta(dir, &meta)?;
    progress(total, total);
    Ok(Outcome::Done)
}

/// `text` without a leading line equal to the article title (the page's `<h1>`).
fn body_text<'a>(text: &'a str, title: &str) -> &'a str {
    match text.split_once('\n') {
        Some((first, rest)) if first.trim().eq_ignore_ascii_case(title.trim()) => rest.trim_start(),
        _ => text,
    }
}

pub(crate) fn cap_bytes(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    let mut e = max;
    while !s.is_char_boundary(e) {
        e -= 1;
    }
    &s[..e]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn language_mapping() {
        assert_eq!(tokenizer_name_for(Some("eng")), "en_stem");
        assert_eq!(tokenizer_name_for(Some("fra")), "fr_stem");
        assert_eq!(tokenizer_name_for(Some("deu,eng")), "de_stem");
        assert_eq!(tokenizer_name_for(Some("ES")), "es_stem");
        assert_eq!(tokenizer_name_for(Some("afr")), "en_stem");
        assert_eq!(tokenizer_name_for(Some("")), "en_stem");
        assert_eq!(tokenizer_name_for(None), "en_stem");
        assert_eq!(language_of_tokenizer("fr_stem"), Language::French);
        assert_eq!(language_of_tokenizer("zz_stem"), Language::English);
    }

    #[test]
    fn stemming_analyzer() {
        let mut a = make_analyzer("en_stem");
        let mut s = a.token_stream("Flooding insurances covered");
        let mut v = vec![];
        while s.advance() {
            v.push(s.token().text.clone());
        }
        assert_eq!(v, vec!["flood", "insur", "cover"]);
    }

    #[test]
    fn leading_title_line_is_dropped() {
        assert_eq!(body_text("Water\n\nIt is wet.", "water"), "It is wet.");
        assert_eq!(body_text("Other\n\nIt is wet.", "water"), "Other\n\nIt is wet.");
    }

    #[test]
    fn lock_lifecycle_and_stale_detection() {
        let d = std::env::temp_dir().join(format!("cs-lock-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        let l = Lock::acquire(&d).unwrap();
        assert!(lock_is_live(&d));
        assert_eq!(Lock::acquire(&d).err().unwrap().code, ErrorCode::Busy);
        drop(l);
        assert!(!lock_is_live(&d));
        assert!(!d.join(LOCK_FILE).exists());
        // a leaked lock of this process (no registry entry) is stale
        std::fs::write(
            d.join(LOCK_FILE),
            serde_json::to_string(&LockInfo { pid: std::process::id(), start_ticks: None, boot_id: None, started: 0 }).unwrap(),
        )
        .unwrap();
        assert!(!lock_is_live(&d));
        // a dead pid is stale
        std::fs::write(
            d.join(LOCK_FILE),
            serde_json::to_string(&LockInfo { pid: 4_000_000_000, start_ticks: Some(1), boot_id: None, started: 0 }).unwrap(),
        )
        .unwrap();
        assert!(!lock_is_live(&d));
        // pid 1 with a wrong start time (pid reuse) is stale; with the right one it is live
        let t = proc_start_ticks(1);
        if t.is_some() {
            std::fs::write(
                d.join(LOCK_FILE),
                serde_json::to_string(&LockInfo { pid: 1, start_ticks: Some(t.unwrap() + 5), boot_id: None, started: 0 }).unwrap(),
            )
            .unwrap();
            assert!(!lock_is_live(&d));
            std::fs::write(
                d.join(LOCK_FILE),
                serde_json::to_string(&LockInfo { pid: 1, start_ticks: t, boot_id: None, started: 0 }).unwrap(),
            )
            .unwrap();
            assert!(lock_is_live(&d));
            assert_eq!(Lock::acquire(&d).err().unwrap().code, ErrorCode::Busy);
        }
        // garbage is stale and gets replaced
        std::fs::write(d.join(LOCK_FILE), "garbage").unwrap();
        assert!(!lock_is_live(&d));
        let l = Lock::acquire(&d).unwrap();
        drop(l);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn state_machine() {
        let d = std::env::temp_dir().join(format!("cs-state-test-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        assert_eq!(index_state(None, "u"), IndexState::Missing);
        assert_eq!(index_state(Some(&d), "u"), IndexState::Missing);
        let mut m = IndexMeta {
            index_format: INDEX_FORMAT,
            tokenizer: "en_stem".into(),
            zim_uuid: "u".into(),
            state: "building".into(),
            next_entry: 5,
            total: 10,
        };
        write_meta(&d, &m).unwrap();
        assert_eq!(index_state(Some(&d), "u"), IndexState::Incomplete);
        m.state = "done".into();
        write_meta(&d, &m).unwrap();
        assert!(matches!(index_state(Some(&d), "u"), IndexState::Done(_)));
        assert_eq!(index_state(Some(&d), "other"), IndexState::Missing);
        m.index_format = 0;
        write_meta(&d, &m).unwrap();
        assert_eq!(index_state(Some(&d), "u"), IndexState::Stale);
        let _ = std::fs::remove_dir_all(&d);
    }
}
