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
}

impl LibOpenIndex {
    pub fn open(dir: &Path, tokenizer_name: &str) -> Result<LibOpenIndex> {
        let stamp = stamp_of(dir);
        let index = tv(Index::open_in_dir(dir))?;
        index.tokenizers().register(ANALYZER, make_analyzer(tokenizer_name));
        let fields = fields_of(&index)?;
        let reader = tv(index.reader_builder().reload_policy(tantivy::ReloadPolicy::Manual).try_into())?;
        let docs = reader.searcher().num_docs();
        Ok(LibOpenIndex { index, reader, fields, docs, stamp })
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
            if m.state == "done" && tantivy_meta_exists {
                progress(m.total, m.total);
                return Ok(Outcome::Done);
            }
            meta.tokenizer = m.tokenizer.clone();
            if tantivy_meta_exists {
                index = tv(Index::open_in_dir(dir))?;
                cp = Checkpoint::from_index(&index);
            } else {
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
