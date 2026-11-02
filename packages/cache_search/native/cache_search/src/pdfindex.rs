//! The PDF index of a ZIM: the pieces (passages) of the PDFs inside it, as a Tantivy keyword index (no vectors, no model).
//!
//! Layout, under the `indexes_dir` the app gives the core (it syncs to devices that hold the same ZIM, so it is not beside the ZIM):
//!
//! ```text
//! <indexes_dir>/zim-pdf/<zim uuid>/
//!     .build/            the writable working index while it is being built (never synced; the lock lives here only)
//!     .tmp-<build-id>/   a snapshot being written by `pdfindex_finish` (renamed to snap/<build-id>/ in one step)
//!     snap/<build-id>/   published snapshots: Tantivy files and `manifest.json` (written last); never written again
//! ```
//!
//! This file is the read side: the schema, the kind's compatibility check, searching a snapshot and reading a page.
//! `pdfbuild.rs` writes. Snapshot rules (manifest, verification, the pick, publishing) are in `snapshot.rs`.

use crate::error::{Error, Result};
use crate::index::{make_analyzer, stemmer_for_language, tv, ANALYZER};
use crate::search::{query_term_texts, term_coverage, top_deterministic};
use crate::snapshot::{self, Manifest};
use crate::zimsrc;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use tantivy::collector::DocSetCollector;
use tantivy::query::{BooleanQuery, Occur, QueryParser, TermQuery};
use tantivy::schema::{Field, IndexRecordOption, Schema, TextFieldIndexing, TextOptions, Value as _, STORED, STRING};
use tantivy::{Index, IndexReader, ReloadPolicy, TantivyDocument, Term};

/// The version of this index's schema (the manifest's `format`).
pub const FORMAT: u32 = 1;
/// The chunker the pieces were made with (`server/builder`'s `CHUNKER_VERSION`). Changes with the shared chunker crate.
pub const CHUNKER_VERSION: u32 = 1;
/// The Tantivy version the files are written by (the manifest's `tantivy`).
pub const TANTIVY: &str = "0.27";
/// The manifest's `kind`.
pub const KIND: &str = "zim-pdf";
pub use crate::snapshot::{BUILD_DIR, SNAP_DIR};
/// The most words of a piece a citation's `quote` holds.
pub const QUOTE_WORDS: usize = 300;

/// The text cut after `max` words, verbatim (the whole text when it has no more).
pub fn first_words(text: &str, max: usize) -> String {
    let mut words = 0;
    let mut in_word = false;
    for (i, c) in text.char_indices() {
        if c.is_whitespace() {
            in_word = false;
        } else if !in_word {
            if words == max {
                return text[..i].trim_end().to_string();
            }
            words += 1;
            in_word = true;
        }
    }
    text.to_string()
}

// ---------------------------------------------------------------------------------------------------------
// Schema

#[derive(Clone, Copy)]
pub struct Fields {
    /// `<zim path>@<i>`: the piece's key (also its address).
    pub pid: Field,
    pub zim_path: Field,
    /// The piece's number within its PDF (the `i` the builder gave it).
    pub piece: Field,
    pub title: Field,
    pub text: Field,
    /// The printed page label.
    pub page: Field,
    pub pdf_page: Field,
    pub pdf_page_end: Field,
    pub heading_path: Field,
}

pub fn build_schema() -> (Schema, Fields) {
    let mut sb = Schema::builder();
    let pid = sb.add_text_field("pid", STRING | STORED);
    let zim_path = sb.add_text_field("zim_path", STRING | STORED);
    let piece = sb.add_u64_field("piece", tantivy::schema::STORED);
    let with_pos =
        TextFieldIndexing::default().set_tokenizer(ANALYZER).set_index_option(IndexRecordOption::WithFreqsAndPositions);
    let title = sb.add_text_field("title", TextOptions::default().set_indexing_options(with_pos.clone()).set_stored());
    let text = sb.add_text_field("text", TextOptions::default().set_indexing_options(with_pos).set_stored());
    let page = sb.add_text_field("page", STORED);
    let pdf_page =
        sb.add_u64_field("pdf_page", tantivy::schema::INDEXED | tantivy::schema::STORED | tantivy::schema::FAST);
    let pdf_page_end = sb.add_u64_field("pdf_page_end", tantivy::schema::STORED);
    let heading_path = sb.add_text_field("heading_path", STORED);
    (sb.build(), Fields { pid, zim_path, piece, title, text, page, pdf_page, pdf_page_end, heading_path })
}

pub fn fields_of(index: &Index) -> Result<Fields> {
    let s = index.schema();
    let f = |n: &str| s.get_field(n).map_err(|e| Error::internal(format!("pdf index schema: {e}")));
    Ok(Fields {
        pid: f("pid")?,
        zim_path: f("zim_path")?,
        piece: f("piece")?,
        title: f("title")?,
        text: f("text")?,
        page: f("page")?,
        pdf_page: f("pdf_page")?,
        pdf_page_end: f("pdf_page_end")?,
        heading_path: f("heading_path")?,
    })
}

pub fn pid_of(zim_path: &str, piece: u64) -> String {
    format!("{zim_path}@{piece}")
}

// ---------------------------------------------------------------------------------------------------------
// Snapshots (the generic part is snapshot.rs)

/// The kind's compatibility check: this core reads the format, the Tantivy version, the tokenizer and the chunker.
pub fn compat(m: &Manifest) -> std::result::Result<(), String> {
    if m.format != FORMAT || m.tantivy != TANTIVY || m.chunker != Some(CHUNKER_VERSION) {
        return Err(format!(
            "format {} tantivy {} chunker {:?} is not read by this core",
            m.format, m.tantivy, m.chunker
        ));
    }
    match &m.tokenizer {
        Some(t) if t.analyzer == ANALYZER && tokenizer_known(&t.name) => Ok(()),
        other => Err(format!("tokenizer {:?} is not known", other.as_ref().map(|t| &t.name))),
    }
}

fn tokenizer_known(name: &str) -> bool {
    name.strip_suffix("_stem").is_some_and(|code| stemmer_for_language(Some(code)).is_some())
}

/// `<indexes_dir>/zim-pdf/<zim uuid>`.
pub fn dir_for(indexes_dir: &Path, zim_uuid: &str) -> PathBuf {
    snapshot::source_dir(indexes_dir, KIND, &zim_uuid.to_ascii_lowercase())
}

/// The snapshot every device uses for the ZIM `zim_uuid`; `dir` is `dir_for(..)`.
pub fn pick(dir: &Path, zim_uuid: &str) -> Option<snapshot::Picked> {
    snapshot::pick(dir, KIND, &zim_uuid.to_ascii_lowercase(), compat)
}

fn extra_u64(m: &Manifest, key: &str) -> u64 {
    m.extra.get(key).and_then(Value::as_u64).unwrap_or(0)
}

// ---------------------------------------------------------------------------------------------------------
// Searching a snapshot

/// An opened snapshot.
pub struct PdfIndex {
    pub snapshot: String,
    pub manifest: Manifest,
    index: Index,
    reader: IndexReader,
    pub fields: Fields,
    pub docs: u64,
}

/// A keyword hit: a piece.
#[derive(Debug, Clone)]
pub struct PdfHit {
    pub pid: String,
    pub raw: f32,
    pub coverage: f32,
    pub title: String,
    /// The printed page label (may be empty).
    pub label: String,
    pub pdf_page: u64,
    pub zim_path: String,
    pub text: String,
}

impl PdfIndex {
    /// Open a verified snapshot folder for reading. Nothing is written to it.
    pub fn open(snapshot: &str, dir: &Path, manifest: Manifest) -> Result<PdfIndex> {
        let index = tv(Index::open_in_dir(dir))?;
        index.tokenizers().register(
            ANALYZER,
            make_analyzer(manifest.tokenizer.as_ref().map(|t| t.name.as_str()).unwrap_or("en_stem")),
        );
        let fields = fields_of(&index)?;
        let reader = tv(index.reader_builder().reload_policy(ReloadPolicy::Manual).try_into())?;
        let docs = reader.searcher().num_docs();
        Ok(PdfIndex { snapshot: snapshot.to_string(), manifest, index, reader, fields, docs })
    }

    fn hit_of(
        &self,
        searcher: &tantivy::Searcher,
        addr: tantivy::DocAddress,
        raw: f32,
        coverage: f32,
    ) -> Option<PdfHit> {
        let doc: TantivyDocument = searcher.doc(addr).ok()?;
        let s = |f: Field| doc.get_first(f).and_then(|v| v.as_str()).unwrap_or("").to_string();
        Some(PdfHit {
            pid: s(self.fields.pid),
            raw,
            coverage,
            title: s(self.fields.title),
            label: s(self.fields.page),
            pdf_page: doc.get_first(self.fields.pdf_page).and_then(|v| v.as_u64()).unwrap_or(0),
            zim_path: s(self.fields.zim_path),
            text: s(self.fields.text),
        })
    }

    /// BM25 over title (boosted 2x) and text, best first (ties by piece key), and the number of matching pieces.
    pub fn search(&self, query: &str, candidates: usize) -> Result<(Vec<PdfHit>, usize)> {
        let searcher = self.reader.searcher();
        let mut qp = QueryParser::for_index(&self.index, vec![self.fields.title, self.fields.text]);
        qp.set_field_boost(self.fields.title, 2.0);
        let (q, _errors) = qp.parse_query_lenient(query);
        let (top, count) = top_deterministic(&searcher, &*q, candidates, self.fields.pid)
            .map_err(|e| Error::io(format!("tantivy: {e}")))?;
        let terms = query_term_texts(&*q);
        let fields = [self.fields.title, self.fields.text];
        let hits = top
            .into_iter()
            .filter_map(|(raw, addr, _)| {
                self.hit_of(&searcher, addr, raw, term_coverage(&searcher, addr, &terms, &fields))
            })
            .collect();
        Ok((hits, count))
    }

    /// The piece with key `pid`.
    pub fn get(&self, pid: &str) -> Option<PdfHit> {
        let searcher = self.reader.searcher();
        let q = TermQuery::new(Term::from_field_text(self.fields.pid, pid), IndexRecordOption::Basic);
        let found = searcher.search(&q, &DocSetCollector).ok()?;
        let addr = found.into_iter().next()?;
        self.hit_of(&searcher, addr, 0.0, 1.0)
    }

    /// The text of PDF page `pdf_page` of the PDF `zim_path`: every piece that starts on it, in document order, joined by
    /// blank lines.
    pub fn page_text(&self, zim_path: &str, pdf_page: u64) -> String {
        let searcher = self.reader.searcher();
        let q = BooleanQuery::new(vec![
            (
                Occur::Must,
                Box::new(TermQuery::new(
                    Term::from_field_text(self.fields.zim_path, zim_path),
                    IndexRecordOption::Basic,
                )),
            ),
            (
                Occur::Must,
                Box::new(TermQuery::new(
                    Term::from_field_u64(self.fields.pdf_page, pdf_page),
                    IndexRecordOption::Basic,
                )),
            ),
        ]);
        let Ok(found) = searcher.search(&q, &DocSetCollector) else { return String::new() };
        let mut pieces: Vec<(u64, String)> = found
            .into_iter()
            .filter_map(|addr| {
                let doc: TantivyDocument = searcher.doc(addr).ok()?;
                let n = doc.get_first(self.fields.piece).and_then(|v| v.as_u64()).unwrap_or(0);
                let t = doc.get_first(self.fields.text).and_then(|v| v.as_str())?.trim().to_string();
                Some((n, t))
            })
            .filter(|(_, t)| !t.is_empty())
            .collect();
        pieces.sort();
        pieces.into_iter().map(|(_, t)| t).collect::<Vec<_>>().join("\n\n")
    }
}

/// `zimpdf:<zim uuid>/<piece key>`: the address of a piece. The key is escaped like a ZIM path.
pub fn address_of(zim_id: &str, pid: &str) -> String {
    zimsrc::format_address(zim_id, pid).replacen("zim:", "zimpdf:", 1)
}

/// Split a `zimpdf:` address into the ZIM id and the piece key.
pub fn parse_address(address: &str) -> Result<(String, String)> {
    let rest =
        address.strip_prefix("zimpdf:").ok_or_else(|| Error::bad_json(format!("not a pdf address: {address:?}")))?;
    let a = zimsrc::parse_address(&format!("zim:{rest}"))?;
    // `format_address` escaped `%` and `#`
    Ok((a.id, zimsrc::percent_decode(&a.path).unwrap_or(a.path)))
}

/// The link a citation of a piece opens: the PDF's ZIM address with the page.
pub fn link_of(zim_id: &str, zim_path: &str, pdf_page: u64) -> String {
    format!("{}#page={pdf_page}", zimsrc::format_address(zim_id, zim_path))
}

/// The status entry for the ZIM's PDF index.
pub fn status_json(snapshot: &str, m: &Manifest, docs: u64) -> Value {
    json!({"kind": KIND, "snapshot": snapshot, "format": m.format, "pdfs": extra_u64(m, "pdfs"), "pieces": docs, "created": m.created})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quote_is_cut_at_the_word_limit_verbatim() {
        let long: String = (1..=350).map(|i| format!("w{i}")).collect::<Vec<_>>().join(" ");
        let q = first_words(&long, 300);
        assert_eq!(q.split_whitespace().count(), 300);
        assert!(long.starts_with(&q) && q.ends_with("w300"));
        let short = "  two  words\nhere ";
        assert_eq!(first_words(short, 300), short);
    }

    #[test]
    fn addresses_round_trip() {
        let id = "0badc0de-0000-4000-8000-00000000cafe";
        let a = address_of(id, "Manuals/a#1.pdf@3");
        assert!(a.starts_with("zimpdf:0badc0de"));
        assert_eq!(parse_address(&a).unwrap(), (id.to_string(), "Manuals/a#1.pdf@3".to_string()));
        assert_eq!(link_of(id, "Manuals/a#1.pdf", 4), format!("zim:{id}/Manuals/a%231.pdf#page=4"));
    }

    #[test]
    fn dir_under_the_indexes_dir() {
        assert_eq!(dir_for(Path::new("/x/idx"), "0BADC0DE-0000"), PathBuf::from("/x/idx/zim-pdf/0badc0de-0000"));
    }
}
