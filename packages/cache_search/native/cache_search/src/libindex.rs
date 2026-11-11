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
use crate::qbuild;
use crate::search::top_deterministic;
use edge::{EdgeShardRead, PointId, ScrollRequest, WithVector};
use serde_json::{json, Value};
use std::path::Path;
use std::time::SystemTime;
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

/// BM25 over title (boosted 2x, as for ZIMs) and body. The query is built by `qbuild` (not Tantivy's `QueryParser`), so a
/// word like "COVID-19" or "don't" matches the body too, which has no positions; the title, which has them, also asks for
/// the exact phrase. Hits are best first with ties broken by point id (see `top_deterministic`). Returns the hits and the
/// number of matching documents.
pub fn keyword_hits(oi: &LibOpenIndex, query: &str, candidates: usize) -> Result<(Vec<KwHit>, usize)> {
    let searcher = oi.reader.searcher();
    let plan = qbuild::build(&oi.index, &[(oi.fields.title, 2.0), (oi.fields.body, 1.0)], query)?;
    let (top, count) = top_deterministic(&searcher, &*plan.query, candidates, oi.fields.point_id)
        .map_err(|e| Error::io(format!("tantivy: {e}")))?;
    let fields = [oi.fields.title, oi.fields.body];
    let hits = top
        .into_iter()
        .map(|(raw, addr, point_id)| KwHit { point_id, raw, coverage: plan.coverage(&searcher, addr, &fields) })
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


#[cfg(test)]
mod tests {
    use super::*;

    /// The point whose text holds the words searched for.
    const TARGET: &str = "target";

    /// A device index built as `build_library_index` builds it (same schema, same analyzer) from (id, title, body) given
    /// here, so no library file is needed.
    fn index_of(name: &str, docs: &[(&str, &str, &str)]) -> (std::path::PathBuf, LibOpenIndex) {
        let d = std::env::temp_dir().join(format!("cs-libindex-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let index = Index::create_in_dir(&d, build_schema().0).unwrap();
        index.tokenizers().register(ANALYZER, make_analyzer(TOKENIZER));
        let f = fields_of(&index).unwrap();
        let mut w = index.writer(15_000_000).unwrap();
        for (id, title, body) in docs {
            w.add_document(doc!(f.point_id => *id, f.title => *title, f.body => *body, f.source_type => "pdf")).unwrap();
        }
        w.commit().unwrap();
        drop(w);
        let oi = LibOpenIndex::open(&d, TOKENIZER).unwrap();
        (d, oi)
    }

    /// Two points: the target, whose body holds the words (the title has none of them), and one that holds none.
    fn two_point_index(name: &str) -> (std::path::PathBuf, LibOpenIndex) {
        index_of(
            name,
            &[
                (
                    TARGET,
                    "Clinic handbook",
                    "The COVID-19 ward is on the second floor. Staff don't enter without a mask. \
                     The U.S. guidance was followed. The filters are state-of-the-art.",
                ),
                ("other", "Garden notes", "Tomatoes want sun and water. Prune them in spring."),
            ],
        )
    }

    /// The point ids `query` finds, best first.
    fn ranked(oi: &LibOpenIndex, query: &str) -> Vec<String> {
        keyword_hits(oi, query, 20).unwrap().0.into_iter().map(|h| h.point_id).collect()
    }

    /// The queries of `queries` that do not return the target point.
    fn not_found(name: &str, queries: &[&'static str]) -> Vec<&'static str> {
        let (d, oi) = two_point_index(name);
        let missed = queries.iter().copied().filter(|q| !ranked(&oi, q).iter().any(|p| p == TARGET)).collect();
        drop(oi);
        let _ = std::fs::remove_dir_all(&d);
        missed
    }

    #[test]
    fn words_typed_with_spaces_find_the_passage() {
        // each word of these queries is one token, and one token is a plain term on the body
        assert_eq!(not_found("spaces", &["covid 19", "state of the art", "second floor"]), Vec::<&str>::new());
        // and the helper can tell found from not found
        assert_eq!(not_found("spaces-none", &["zeppelin", "tomatoes"]), vec!["zeppelin", "tomatoes"]);
    }

    #[test]
    fn words_typed_with_their_punctuation_find_the_passage() {
        // The analyzer cuts each of these words into several tokens ("covid" + "19", "don" + "t", "u" + "s", "state" + "of" +
        // "the" + "art"). Tantivy's query parser made that a phrase, a phrase needs positions, and `body` has frequencies only,
        // so only titles were searched and the body passage was never found. `qbuild` asks the body for the tokens as an
        // all-terms conjunction instead.
        assert_eq!(
            not_found("punctuation", &["COVID-19", "don't", "U.S.", "state-of-the-art"]),
            Vec::<&str>::new(),
            "typed as written in the passage, and not found"
        );
    }

    #[test]
    fn words_typed_without_their_punctuation_find_the_passage() {
        // "covid19" is one token, not in the index ("COVID-19" is covid + 19); the query also tries it split at the
        // letter/digit boundary
        assert_eq!(not_found("joined", &["covid19", "Covid19"]), Vec::<&str>::new());
    }

    #[test]
    #[ignore = "known gap: needs an index-side change (a separate decision); run with --ignored"]
    fn words_typed_joined_without_punctuation_are_a_known_gap() {
        // KNOWN GAPS, recorded. "dont" and "US" are single tokens ("dont", "us") that are not in the index: the passage's
        // "don't" and "U.S." are indexed as don + t and u + s, and a query cannot know that "dont" was meant as don + t
        // ("dont" could be a word) or "us" as u + s ("us" is a word). Only an index-side change (indexing the joined form
        // too, which changes the analyzer and so LIB_INDEX_FORMAT) can join them. Not changed here, by decision.
        assert_eq!(not_found("gap", &["dont", "US"]), Vec::<&str>::new(), "typed without the punctuation, and not found");
    }

    #[test]
    fn an_apostrophe_word_ranks_the_real_passage_above_scattered_tokens() {
        let (d, oi) = index_of(
            "rank-dont",
            &[
                // the apostrophe word is in the title (the phrase on the title, which has positions)
                ("title-phrase", "Don't panic", "A short guide to staying calm."),
                // "Don" and a stray "t" in the body, once each, nothing in the title
                ("scattered", "Garden notes", "Don planted the beds. Row t of the greenhouse is closed. Water daily."),
                // "Don" only: no "t", so not a match for "don't"
                ("don-only", "Staff list", "Don and Maria work on the ward."),
                // the same words in the title but scattered, not as the phrase
                ("title-scattered", "Don and the t shirt", "Notes."),
            ],
        );
        let r = ranked(&oi, "don't");
        assert_eq!(r.first().map(String::as_str), Some("title-phrase"), "the exact title phrase ranks first: {r:?}");
        assert!(!r.iter().any(|p| p == "don-only"), "a passage with only 'Don' is not a match: {r:?}");
        let pos = |id: &str| r.iter().position(|p| p == id).unwrap_or(usize::MAX);
        assert!(pos("title-phrase") < pos("title-scattered"), "{r:?}");
        assert!(pos("title-phrase") < pos("scattered"), "{r:?}");
        drop(oi);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_body_with_the_apostrophe_word_ranks_above_a_body_with_scattered_tokens() {
        // The body has no positions, so "don't" cannot be told from "Don ... t" by order. What can be told is how much of
        // the passage is about it: the passage that says "don't" three times outscores the one with a stray "Don" and a stray
        // "t" once each (term frequency), at the same length.
        let (d, oi) = index_of(
            "rank-dont-body",
            &[
                ("scattered", "Garden notes", "Don planted the beds on a sunny day. Row t of the greenhouse is closed for now."),
                ("real", "Visitor rules", "Please don't run. Please don't shout. Please don't touch the beds near the greenhouse."),
                ("don-only", "Staff list", "Don and Maria work on the ward."),
            ],
        );
        let r = ranked(&oi, "don't");
        assert_eq!(r.first().map(String::as_str), Some("real"), "{r:?}");
        assert!(r.iter().any(|p| p == "scattered"), "the scattered one still matches, below: {r:?}");
        assert!(!r.iter().any(|p| p == "don-only"), "{r:?}");
        drop(oi);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn an_exact_title_phrase_ranks_above_scattered_body_terms() {
        let (d, oi) = index_of(
            "rank-phrase",
            &[
                ("scattered", "Garden notes", "The state keeps a record of the art shown in the art garden. Of note, the art of state."),
                ("exact", "State-of-the-art filters", "Filters."),
            ],
        );
        let r = ranked(&oi, "state-of-the-art");
        assert_eq!(r.first().map(String::as_str), Some("exact"), "{r:?}");
        assert!(r.iter().any(|p| p == "scattered"), "scattered terms still find the passage, below: {r:?}");
        drop(oi);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn the_us_abbreviation_ranks_the_real_passage_first() {
        let (d, oi) = index_of(
            "rank-us",
            &[
                ("scattered", "Garden notes", "Plan U covers the north beds. Plan S covers the south beds. Water both."),
                ("real", "Border rules", "The U.S. rules apply. The U.S. office is open. Ask the U.S. clerk about the beds."),
                ("us-word", "Team notes", "Give us a call. The beds are ours."),
            ],
        );
        let r = ranked(&oi, "U.S.");
        assert_eq!(r.first().map(String::as_str), Some("real"), "{r:?}");
        assert!(!r.iter().any(|p| p == "us-word"), "the word 'us' is not u + s: {r:?}");
        drop(oi);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_quoted_phrase_is_exact_on_the_title_and_finds_the_passage_in_the_body() {
        let (d, oi) = index_of(
            "quoted",
            &[
                ("exact", "Second floor plan", "Rooms."),
                ("reversed", "Floor second plan", "Rooms."),
                (TARGET, "Clinic handbook", "The ward is on the second floor, past the lift."),
            ],
        );
        let r = ranked(&oi, "\"second floor\"");
        // exact on the title: the reversed title is not a match
        assert!(r.iter().any(|p| p == "exact"), "{r:?}");
        assert!(!r.iter().any(|p| p == "reversed"), "a title with the words in the other order is not the phrase: {r:?}");
        // on the body (no positions) the passage is found, as an all-terms conjunction (approximate)
        assert!(r.iter().any(|p| p == TARGET), "a quoted phrase finds the body passage: {r:?}");
        // unquoted, the reversed title matches too (OR of the words)
        let u = ranked(&oi, "second floor");
        assert!(u.iter().any(|p| p == "reversed"), "{u:?}");
        drop(oi);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn quoted_spans_the_model_sends_find_their_passages() {
        // shapes taken from real model queries: a quoted multi-word span next to plain words, and several one-word quotes
        let (d, oi) = index_of(
            "model-quotes",
            &[
                ("film-title", "The 11th Hour", "A documentary about the environment."),
                ("film-body", "Film notes", "The 11th hour is a film about the climate. It was released in 2007."),
                ("fennel", "Garden notes", "Common fennel and Florence fennel are the two main varieties grown for the kitchen."),
                ("other", "Tomatoes", "Tomatoes want sun and water."),
            ],
        );
        let r = ranked(&oi, "\"The 11th Hour\" film");
        assert!(r.iter().any(|p| p == "film-title"), "{r:?}");
        assert!(r.iter().any(|p| p == "film-body"), "{r:?}");
        assert!(!r.iter().any(|p| p == "other"), "{r:?}");
        let r = ranked(&oi, "fennel varieties \"Common\" \"Florence\"");
        assert_eq!(r.first().map(String::as_str), Some("fennel"), "{r:?}");
        drop(oi);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn a_query_with_nothing_to_search_finds_nothing_and_does_not_fail() {
        let (d, oi) = two_point_index("empty");
        for q in ["", "   ", "---", "\"\"", "\" "] {
            assert!(ranked(&oi, q).is_empty(), "{q:?}");
        }
        // several words stay OR
        assert!(ranked(&oi, "tomatoes ward").len() == 2);
        drop(oi);
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn the_coverage_of_a_split_word_counts_the_literal_or_all_pieces() {
        let (d, oi) = two_point_index("cov");
        let h = keyword_hits(&oi, "covid19", 5).unwrap().0;
        assert_eq!(h.len(), 1);
        assert!((h[0].coverage - 1.0).abs() < 1e-6, "{}", h[0].coverage);
        drop(oi);
        let _ = std::fs::remove_dir_all(&d);
    }
}
