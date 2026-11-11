//! The device keyword index of a library: a Tantivy index over the library's mapped text field, built by the
//! `index_library` job from a scroll of the shard and searched as one more keyword list.
//!
//! Layout of an `index_dir` (shared with ZIM indexes, see `index.rs`): the Tantivy files, the
//! `cache_search_index.json` record (its `zim_uuid` holds `lib:<library_id>` here, so an index built for another
//! library is not used) and the build lock.
//!
//! Schema: `point_id` (raw, stored), `title` (text, positions, stored), `body` (text, frequencies only, not
//! stored), `source_type` (string, stored, fast). Points matching a leave-out rule are skipped at index time.
//!
//! Checkpoints: every `checkpoint_docs` indexed documents (and when cancelled, and at the end) the build commits
//! to Tantivy with the payload `{"next_offset":<point id or null>,"scrolled":N,"indexed":N,"finished":bool}`.
//! The offset is the first point id of the next scroll page, so a job killed at any point resumes from the last
//! commit; documents after it were never committed and are discarded by Tantivy.

use crate::error::{Error, Result};
use crate::index::{
    cap_bytes, make_analyzer, read_meta, stamp_of, tv, wipe_dir, write_meta, IndexMeta, Outcome, ANALYZER,
    LIB_INDEX_FORMAT, MAX_BODY_BYTES,
};
use crate::library::{open_shard_for_scroll, resolve_settings};
use crate::search::{query_term_texts, term_coverage, top_deterministic};
use edge::{EdgeShardRead, PointId, ScrollRequest, WithVector};
use serde_json::{json, Value};
use std::path::Path;
use std::time::SystemTime;
use tantivy::query::QueryParser;
use tantivy::schema::{Field, IndexRecordOption, Schema, TextFieldIndexing, TextOptions, FAST, STORED, STRING};
use tantivy::{doc, Index, IndexReader, TantivyDocument};

/// Points per scroll page.
const BATCH: usize = 1000;
/// Default documents per checkpoint.
pub const DEFAULT_CHECKPOINT_DOCS: usize = 200_000;
/// The tokenizer of device library indexes (English stemmer, as for ZIMs without another language).
pub const TOKENIZER: &str = "en_stem";

#[derive(Clone, Copy)]
pub struct LibFields {
    pub point_id: Field,
    pub title: Field,
    pub body: Field,
    pub source_type: Field,
}

pub fn build_schema() -> (Schema, LibFields) {
    let mut sb = Schema::builder();
    let point_id = sb.add_text_field("point_id", STRING | STORED);
    let with_pos = TextFieldIndexing::default()
        .set_tokenizer(ANALYZER)
        .set_index_option(IndexRecordOption::WithFreqsAndPositions);
    let freqs_only =
        TextFieldIndexing::default().set_tokenizer(ANALYZER).set_index_option(IndexRecordOption::WithFreqs);
    let title = sb.add_text_field("title", TextOptions::default().set_indexing_options(with_pos).set_stored());
    let body = sb.add_text_field("body", TextOptions::default().set_indexing_options(freqs_only));
    let source_type = sb.add_text_field("source_type", STRING | STORED | FAST);
    (sb.build(), LibFields { point_id, title, body, source_type })
}

fn fields_of(index: &Index) -> Result<LibFields> {
    let s = index.schema();
    let f = |n: &str| s.get_field(n).map_err(|e| Error::internal(format!("index schema: {e}")));
    Ok(LibFields { point_id: f("point_id")?, title: f("title")?, body: f("body")?, source_type: f("source_type")? })
}

/// The value stored in the index record to tie an index to one library.
pub fn source_key(library_id: &str) -> String {
    format!("lib:{library_id}")
}

/// An opened device index (search side).
pub struct LibOpenIndex {
    pub index: Index,
    pub reader: IndexReader,
    pub fields: LibFields,
    pub docs: u64,
    stamp: Option<(SystemTime, u64)>,
    /// Tells `index_seal` this folder is open (it may not move files out from under it).
    _guard: crate::idxsnap::OpenGuard,
}

impl LibOpenIndex {
    pub fn open(dir: &Path, tokenizer_name: &str) -> Result<LibOpenIndex> {
        let stamp = stamp_of(dir);
        let index = tv(Index::open_in_dir(dir))?;
        index.tokenizers().register(ANALYZER, make_analyzer(tokenizer_name));
        let fields = fields_of(&index)?;
        let reader = tv(index.reader_builder().reload_policy(tantivy::ReloadPolicy::Manual).try_into())?;
        let docs = reader.searcher().num_docs();
        Ok(LibOpenIndex { index, reader, fields, docs, stamp, _guard: crate::idxsnap::OpenGuard::new(dir) })
    }

    /// True if the index files changed on disk since this was opened.
    pub fn is_outdated(&self, dir: &Path) -> bool {
        stamp_of(dir) != self.stamp
    }
}

/// A keyword hit in a library's device index.
#[derive(Debug, Clone)]
pub struct KwHit {
    pub point_id: String,
    pub raw: f32,
    /// Fraction of distinct query terms present in the title or body.
    pub coverage: f32,
}

/// BM25 over title (boosted 2x, as for ZIMs) and body. Phrase queries only work on the title, the one field
/// with positions. Hits are best first with ties broken by point id (see `top_deterministic`). Returns the hits
/// and the number of matching documents.
pub fn keyword_hits(oi: &LibOpenIndex, query: &str, candidates: usize) -> Result<(Vec<KwHit>, usize)> {
    let searcher = oi.reader.searcher();
    let mut qp = QueryParser::for_index(&oi.index, vec![oi.fields.title, oi.fields.body]);
    qp.set_field_boost(oi.fields.title, 2.0);
    let (q, _errors) = qp.parse_query_lenient(query);
    let (top, count) = top_deterministic(&searcher, &*q, candidates, oi.fields.point_id)
        .map_err(|e| Error::io(format!("tantivy: {e}")))?;
    let terms = query_term_texts(&*q);
    let fields = [oi.fields.title, oi.fields.body];
    let hits = top
        .into_iter()
        .map(|(raw, addr, point_id)| KwHit { point_id, raw, coverage: term_coverage(&searcher, addr, &terms, &fields) })
        .collect();
    Ok((hits, count))
}

pub struct LibBuildParams<'a> {
    /// Cap on Tantivy writer threads (default: up to 4, by the cores).
    pub threads: Option<usize>,
    /// Called after each point (the job's pace point, see duty.rs).
    pub pace: Option<&'a dyn Fn()>,
    pub library_path: &'a Path,
    /// The library's settings object (as in `cs_open`); guessed from the payload when absent.
    pub settings: Option<&'a Value>,
    pub index_dir: &'a Path,
    pub heap_mb: usize,
    pub checkpoint_docs: usize,
}

struct Checkpoint {
    offset: Option<PointId>,
    scrolled: u64,
    indexed: u64,
    finished: bool,
}

impl Checkpoint {
    fn payload(&self) -> String {
        json!({
            "next_offset": self.offset.as_ref().map(|o| o.to_string()),
            "scrolled": self.scrolled, "indexed": self.indexed, "finished": self.finished,
        })
        .to_string()
    }

    fn from_index(index: &Index) -> Checkpoint {
        let none = Checkpoint { offset: None, scrolled: 0, indexed: 0, finished: false };
        let Some(v) = index
            .load_metas()
            .ok()
            .and_then(|m| m.payload)
            .and_then(|p| serde_json::from_str::<Value>(&p).ok())
        else {
            return none;
        };
        Checkpoint {
            offset: v.get("next_offset").and_then(|o| o.as_str()).and_then(|s| s.parse().ok()),
            scrolled: v.get("scrolled").and_then(|x| x.as_u64()).unwrap_or(0),
            indexed: v.get("indexed").and_then(|x| x.as_u64()).unwrap_or(0),
            finished: v.get("finished").and_then(|x| x.as_bool()).unwrap_or(false),
        }
    }
}

fn commit(writer: &mut tantivy::IndexWriter<TantivyDocument>, cp: &Checkpoint) -> Result<()> {
    let mut pc = tv(writer.prepare_commit())?;
    pc.set_payload(&cp.payload());
    tv(pc.commit())?;
    Ok(())
}

/// Build (or resume) the device index of a library in `p.index_dir`. The caller holds the `Lock`.
/// `progress(done, total)` counts scrolled points against the library's point count; `cancelled()` is checked
/// before every scroll page, and a cancelled build commits a checkpoint first.
pub fn build_library_index(
    p: &LibBuildParams,
    progress: &dyn Fn(u64, u64),
    cancelled: &dyn Fn() -> bool,
) -> Result<Outcome> {
    let dir = p.index_dir;
    let shard = open_shard_for_scroll(p.library_path)?;
    let settings = resolve_settings(&shard, p.library_path, p.settings)?;
    let total = EdgeShardRead::count(&shard, edge::CountRequest::new())
        .map_err(|e| Error::internal(format!("counting points: {e}")))? as u64;
    let key = source_key(&settings.library_id);

    let mut meta = IndexMeta {
        index_format: LIB_INDEX_FORMAT,
        tokenizer: TOKENIZER.to_string(),
        zim_uuid: key.clone(),
        state: "building".into(),
        next_entry: 0,
        total,
    };
    let tantivy_meta_exists = dir.join("meta.json").exists();
    let index: Index;
    let mut cp = Checkpoint { offset: None, scrolled: 0, indexed: 0, finished: false };
    match read_meta(dir) {
        Some(m) if m.index_format == LIB_INDEX_FORMAT && m.zim_uuid == key => {
            // An index whose files do not all open (part of one that an earlier version's sync copied from another device, or
            // files lost) is built again from scratch rather than reported done or resumed.
            let opens = tantivy_meta_exists && LibOpenIndex::open(dir, &m.tokenizer).is_ok();
            if m.state == "done" && opens {
                progress(m.total, m.total);
                return Ok(Outcome::Done);
            }
            meta.tokenizer = m.tokenizer.clone();
            if opens {
                index = tv(Index::open_in_dir(dir))?;
                cp = Checkpoint::from_index(&index);
            } else {
                wipe_dir(dir);
                index = tv(Index::create_in_dir(dir, build_schema().0))?;
            }
        }
        Some(_) => {
            // ours, but another format or another library: rebuild from scratch
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
    meta.next_entry = cp.scrolled;
    write_meta(dir, &meta)?;

    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(1).clamp(1, 4);
    let threads = p.threads.map(|t| t.clamp(1, threads)).unwrap_or(threads);
    let heap = p.heap_mb.max(15 * threads) * 1_000_000;
    let mut writer = tv(index.writer_with_num_threads::<TantivyDocument>(threads, heap))?;
    let checkpoint = p.checkpoint_docs.max(1) as u64;
    let selector = settings.payload_selector();

    progress(cp.scrolled, total);
    let mut since_commit = 0u64;
    while !cp.finished {
        if cancelled() {
            commit(&mut writer, &cp)?;
            meta.next_entry = cp.scrolled;
            write_meta(dir, &meta)?;
            return Ok(Outcome::Cancelled);
        }
        let mut sr = ScrollRequest::new();
        sr.offset = cp.offset;
        sr.limit = Some(BATCH);
        sr.with_payload = Some(selector.clone());
        sr.with_vector = WithVector::Bool(false);
        let (recs, next) =
            EdgeShardRead::scroll(&shard, sr).map_err(|e| Error::internal(format!("scrolling the library: {e}")))?;
        let empty = serde_json::Map::new();
        for r in &recs {
            cp.scrolled += 1;
            let pl = r.payload.as_ref().map(|p| &p.0).unwrap_or(&empty);
            if settings.left_out(pl) {
                continue;
            }
            let title = settings.base_title(pl);
            let text = settings.main_text(pl).unwrap_or_default();
            let body = cap_bytes(&text, MAX_BODY_BYTES);
            let source_type = settings.field_text(pl, &settings.fields.source_type).unwrap_or_default();
            tv(writer.add_document(doc!(
                f.point_id => r.id.to_string(),
                f.title => title,
                f.body => body,
                f.source_type => source_type
            )))?;
            cp.indexed += 1;
            since_commit += 1;
            if let Some(pace) = p.pace {
                pace();
            }
        }
        cp.finished = next.is_none() || recs.is_empty();
        cp.offset = next;
        progress(cp.scrolled, total);
        if since_commit >= checkpoint || cp.finished {
            commit(&mut writer, &cp)?;
            since_commit = 0;
            meta.next_entry = cp.scrolled;
            write_meta(dir, &meta)?;
        }
    }
    if since_commit > 0 || !tantivy_meta_exists {
        commit(&mut writer, &cp)?;
    }
    tv(writer.wait_merging_threads())?;
    meta.next_entry = cp.scrolled;
    meta.total = total.max(cp.scrolled);
    meta.state = "done".into();
    write_meta(dir, &meta)?;
    progress(meta.total, meta.total);
    Ok(Outcome::Done)
}

/// One point to add to a finished device index.
pub struct IndexDoc {
    pub point_id: String,
    pub title: String,
    pub body: String,
    pub source_type: String,
}

/// What [`append_documents`] found in the index folder.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Appended {
    /// The documents were added and committed.
    Yes,
    /// There is no device index in the folder (the library has none yet): nothing to add to.
    NoIndex,
    /// The folder holds an index that is not finished (or of another format): it cannot be extended and must be built again.
    Unfinished,
}

/// Adds points to the finished device index in `dir` (the Add PDF job: a new book). A point already in the index is replaced
/// (deleted by its id first), so adding the same book twice leaves one copy of each passage. The index is not searched meanwhile:
/// the caller owns the folder (the job works on a copy and swaps it in).
pub fn append_documents(dir: &Path, docs: &[IndexDoc]) -> Result<Appended> {
    let Some(m) = read_meta(dir) else { return Ok(Appended::NoIndex) };
    if m.index_format != LIB_INDEX_FORMAT || m.state != "done" || !dir.join("meta.json").exists() {
        return Ok(Appended::Unfinished);
    }
    let index = tv(Index::open_in_dir(dir))?;
    index.tokenizers().register(ANALYZER, make_analyzer(&m.tokenizer));
    let f = fields_of(&index)?;
    let mut cp = Checkpoint::from_index(&index);
    let mut writer = tv(index.writer_with_num_threads::<TantivyDocument>(1, 15_000_000))?;
    for d in docs {
        writer.delete_term(tantivy::Term::from_field_text(f.point_id, &d.point_id));
        tv(writer.add_document(doc!(
            f.point_id => d.point_id.clone(),
            f.title => d.title.clone(),
            f.body => cap_bytes(&d.body, MAX_BODY_BYTES),
            f.source_type => d.source_type.clone()
        )))?;
    }
    cp.scrolled += docs.len() as u64;
    cp.indexed += docs.len() as u64;
    cp.finished = true;
    commit(&mut writer, &cp)?;
    tv(writer.wait_merging_threads())?;
    let mut meta = m;
    meta.total += docs.len() as u64;
    meta.next_entry = cp.scrolled;
    write_meta(dir, &meta)?;
    Ok(Appended::Yes)
}


// ---------------------------------------------------------------------------------------------------------
// Growing a snapshot: the points the shard has and an index lacks, and one segment added to a folder of linked segments

/// The documents the shard has and `base` lacks (a point is in the index when a document with its id is), and the shard's point
/// count. `progress(scrolled, total)` and `cancelled()` as in a build; `pace()` after each point. Reads the shard and `base` only.
pub fn missing_documents(
    library_path: &Path,
    given: Option<&Value>,
    base: &LibOpenIndex,
    progress: &dyn Fn(u64, u64),
    cancelled: &dyn Fn() -> bool,
    pace: &dyn Fn(),
) -> Result<Option<(Vec<IndexDoc>, u64)>> {
    let shard = open_shard_for_scroll(library_path)?;
    let settings = resolve_settings(&shard, library_path, given)?;
    let total = EdgeShardRead::count(&shard, edge::CountRequest::new())
        .map_err(|e| Error::internal(format!("counting points: {e}")))? as u64;
    let selector = settings.payload_selector();
    let searcher = base.reader.searcher();
    let (mut missing, mut scrolled, mut offset) = (Vec::new(), 0u64, None);
    loop {
        if cancelled() {
            return Ok(None);
        }
        let mut sr = ScrollRequest::new();
        sr.offset = offset;
        sr.limit = Some(BATCH);
        sr.with_payload = Some(selector.clone());
        sr.with_vector = WithVector::Bool(false);
        let (recs, next) =
            EdgeShardRead::scroll(&shard, sr).map_err(|e| Error::internal(format!("scrolling the library: {e}")))?;
        let empty = serde_json::Map::new();
        for r in &recs {
            scrolled += 1;
            let pl = r.payload.as_ref().map(|p| &p.0).unwrap_or(&empty);
            if settings.left_out(pl) {
                continue;
            }
            let id = r.id.to_string();
            let have = searcher.doc_freq(&tantivy::Term::from_field_text(base.fields.point_id, &id)).unwrap_or(0) > 0;
            if !have {
                missing.push(IndexDoc {
                    point_id: id,
                    title: settings.base_title(pl),
                    body: settings.main_text(pl).unwrap_or_default(),
                    source_type: settings.field_text(pl, &settings.fields.source_type).unwrap_or_default(),
                });
            }
            pace();
        }
        progress(scrolled, total);
        if next.is_none() || recs.is_empty() {
            break;
        }
        offset = next;
    }
    Ok(Some((missing, total)))
}

/// More segments than this and an extension lets Tantivy merge (the cost of a merge is the merged segments, once in a while).
pub const MAX_SEGMENTS_BEFORE_MERGE: usize = 40;

/// Adds `docs` to the Tantivy index in `dir` as ONE new segment and commits. `dir` holds the files of the previous snapshot
/// (hard links): Tantivy never writes into a segment file, only adds new ones and replaces `meta.json` and `.managed.json` by a
/// rename, so the linked files are not touched. No merge runs (the old segments stay as they are) unless the index already has
/// [`MAX_SEGMENTS_BEFORE_MERGE`] segments. Replace-by-id: a document with the same `point_id` is deleted first (new `.del` files).
/// Returns the number of segments before.
pub fn append_segment(dir: &Path, tokenizer: &str, docs: &[IndexDoc], threads: usize, heap_mb: usize) -> Result<usize> {
    let index = tv(Index::open_in_dir(dir))?;
    index.tokenizers().register(ANALYZER, make_analyzer(tokenizer));
    let f = fields_of(&index)?;
    let before = tv(index.searchable_segment_ids())?.len();
    let mut cp = Checkpoint::from_index(&index);
    let mut writer = tv(index.writer_with_num_threads::<TantivyDocument>(threads.max(1), heap_mb.max(15) * 1_000_000))?;
    if before < MAX_SEGMENTS_BEFORE_MERGE {
        writer.set_merge_policy(Box::new(tantivy::merge_policy::NoMergePolicy));
    }
    for d in docs {
        writer.delete_term(tantivy::Term::from_field_text(f.point_id, &d.point_id));
        tv(writer.add_document(doc!(
            f.point_id => d.point_id.clone(),
            f.title => d.title.clone(),
            f.body => cap_bytes(&d.body, MAX_BODY_BYTES),
            f.source_type => d.source_type.clone()
        )))?;
    }
    cp.scrolled += docs.len() as u64;
    cp.indexed += docs.len() as u64;
    cp.finished = true;
    commit(&mut writer, &cp)?;
    tv(writer.wait_merging_threads())?;
    Ok(before)
}
