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
use tantivy::collector::{Count, DocSetCollector};
use tantivy::query::{BooleanQuery, Occur, QueryParser, TermQuery};
use tantivy::schema::{Field, IndexRecordOption, Schema, TextFieldIndexing, TextOptions, Value as _, STORED, STRING};
use tantivy::{Index, IndexReader, ReloadPolicy, TantivyDocument, Term};

/// The version of this index's schema (the manifest's `format`).
/// Format 2 adds one stored-only document per PDF page (`is_page`, `page_text`), for citing and reading the page a passage is on.
pub const FORMAT: u32 = 2;
/// The chunker the pieces were made with (the shared `cache_chunk` crate's version).
pub use cache_chunk::CHUNKER_VERSION;
/// The Tantivy version the files are written by (the manifest's `tantivy`).
pub const TANTIVY: &str = "0.27";
/// The manifest's `kind`.
pub const KIND: &str = "zim-pdf";
pub use crate::snapshot::{BUILD_DIR, SNAP_DIR};
/// A readable title from a PDF's path in the ZIM: the folder and the `.pdf` extension dropped, `_` and `-` turned into spaces,
/// whitespace collapsed (`Manuals/flood_kit-guide.pdf` -> `flood kit guide`).
pub fn readable_title(path: &str) -> String {
    let name = path.rsplit('/').next().unwrap_or(path);
    let name = match name.len().checked_sub(4).filter(|i| name.is_char_boundary(*i)) {
        Some(i) if name[i..].eq_ignore_ascii_case(".pdf") => &name[..i],
        _ => name,
    };
    name.replace(['_', '-'], " ").split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The title to index for a PDF: the one the app gave, or (when it is empty or just the path) one made from the file name.
pub fn title_for(given: &str, path: &str) -> String {
    let g = given.trim();
    if g.is_empty() || g == path.trim() {
        let t = readable_title(path);
        if t.is_empty() {
            path.to_string()
        } else {
            t
        }
    } else {
        g.to_string()
    }
}

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
    /// 1 on the stored-only page documents (one per PDF page: `zim_path`, `pdf_page`, `page` label, `page_text`); absent on pieces.
    pub is_page: Field,
    pub page_text: Field,
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
    let is_page = sb.add_u64_field("is_page", tantivy::schema::INDEXED);
    let page_text = sb.add_text_field("page_text", STORED);
    (
        sb.build(),
        Fields { pid, zim_path, piece, title, text, page, pdf_page, pdf_page_end, heading_path, is_page, page_text },
    )
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
        is_page: f("is_page")?,
        page_text: f("page_text")?,
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
    /// The snapshot folder.
    pub dir: PathBuf,
    pub manifest: Manifest,
    index: Index,
    reader: IndexReader,
    pub fields: Fields,
    pub docs: u64,
}

/// A piece as stored.
#[derive(Debug, Clone)]
pub struct StoredPiece {
    pub i: u64,
    pub title: String,
    pub text: String,
    pub page: String,
    pub pdf_page: u64,
    pub pdf_page_end: Option<u64>,
    pub heading_path: Vec<String>,
}

/// One row of a snapshot's `pdfs.tsv`.
#[derive(Debug, Clone, PartialEq)]
pub struct PdfRow {
    pub path: String,
    pub size: Option<u64>,
    pub sha256: String,
    pub pieces: u64,
    /// `added` or `skipped:<reason>`.
    pub status: String,
}

/// `pdfs.tsv` in a snapshot: `path<TAB>size<TAB>sha256<TAB>pieces<TAB>status` per PDF (tab, newline and backslash in a path are
/// written `\t`, `\n`, `\\`).
pub const PDFS_FILE: &str = "pdfs.tsv";

pub fn rows_to_tsv(rows: &[PdfRow]) -> String {
    let esc = |s: &str| s.replace('\\', "\\\\").replace('\t', "\\t").replace('\n', "\\n");
    let mut out = String::new();
    for r in rows {
        out.push_str(&format!(
            "{}\t{}\t{}\t{}\t{}\n",
            esc(&r.path),
            r.size.map(|n| n.to_string()).unwrap_or_default(),
            r.sha256,
            r.pieces,
            r.status
        ));
    }
    out
}

pub fn rows_from_tsv(text: &str) -> Vec<PdfRow> {
    let unesc = |s: &str| {
        let mut out = String::new();
        let mut it = s.chars();
        while let Some(c) = it.next() {
            if c != '\\' {
                out.push(c);
                continue;
            }
            match it.next() {
                Some('t') => out.push('\t'),
                Some('n') => out.push('\n'),
                Some(o) => out.push(o),
                None => out.push('\\'),
            }
        }
        out
    };
    text.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            (f.len() == 5).then(|| PdfRow {
                path: unesc(f[0]),
                size: f[1].parse().ok(),
                sha256: f[2].to_string(),
                pieces: f[3].parse().unwrap_or(0),
                status: f[4].to_string(),
            })
        })
        .collect()
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
    /// The PDF page the hit is on: the page of the piece's range whose text best matches the query (the piece's first page
    /// when there is no page text or nothing to choose by).
    pub pdf_page: u64,
    /// The last PDF page of the piece (its first page when it stays on one).
    pub pdf_page_end: u64,
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
        // the page documents are not pieces
        let searcher = reader.searcher();
        let pages = searcher
            .search(&TermQuery::new(Term::from_field_u64(fields.is_page, 1), IndexRecordOption::Basic), &Count)
            .unwrap_or(0) as u64;
        let docs = searcher.num_docs().saturating_sub(pages);
        Ok(PdfIndex { snapshot: snapshot.to_string(), dir: dir.to_path_buf(), manifest, index, reader, fields, docs })
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
            pdf_page_end: doc
                .get_first(self.fields.pdf_page_end)
                .and_then(|v| v.as_u64())
                .unwrap_or_else(|| doc.get_first(self.fields.pdf_page).and_then(|v| v.as_u64()).unwrap_or(0)),
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
        let mut analyzer = self.index.tokenizers().get(ANALYZER);
        let hits = top
            .into_iter()
            .filter_map(|(raw, addr, _)| {
                let mut h = self.hit_of(&searcher, addr, raw, term_coverage(&searcher, addr, &terms, &fields))?;
                // a piece that runs over several pages is cited at the page that matches the query best
                if h.pdf_page_end > h.pdf_page {
                    if let Some((page, label)) =
                        self.best_page(&h.zim_path, h.pdf_page, h.pdf_page_end, &terms, analyzer.as_mut())
                    {
                        if page != h.pdf_page {
                            h.pdf_page = page;
                            h.label = label;
                        }
                    }
                }
                Some(h)
            })
            .collect();
        Ok((hits, count))
    }

    /// A snippet of the piece `text` around what matches `query` (see `search::match_snippet`).
    pub fn snippet(&self, query: &str, text: &str, max: usize) -> String {
        let mut qp = QueryParser::for_index(&self.index, vec![self.fields.title, self.fields.text]);
        qp.set_field_boost(self.fields.title, 2.0);
        let (q, _errors) = qp.parse_query_lenient(query);
        crate::search::match_snippet(&self.reader.searcher(), &*q, self.fields.text, text, max)
    }

    /// The piece with key `pid`.
    pub fn get(&self, pid: &str) -> Option<PdfHit> {
        let searcher = self.reader.searcher();
        let q = TermQuery::new(Term::from_field_text(self.fields.pid, pid), IndexRecordOption::Basic);
        let found = searcher.search(&q, &DocSetCollector).ok()?;
        let addr = found.into_iter().next()?;
        self.hit_of(&searcher, addr, 0.0, 1.0)
    }

    /// Every stored piece of the PDF `zim_path`, in document order (for reusing them in a later edition's index).
    pub fn pieces_of(&self, zim_path: &str) -> Vec<StoredPiece> {
        let searcher = self.reader.searcher();
        let q = TermQuery::new(Term::from_field_text(self.fields.zim_path, zim_path), IndexRecordOption::Basic);
        let Ok(found) = searcher.search(&q, &DocSetCollector) else { return Vec::new() };
        let f = &self.fields;
        let mut v: Vec<StoredPiece> = found
            .into_iter()
            .filter_map(|addr| {
                let doc: TantivyDocument = searcher.doc(addr).ok()?;
                let s = |fl: Field| doc.get_first(fl).and_then(|x| x.as_str()).unwrap_or("").to_string();
                // the page documents have no piece number
                Some(StoredPiece {
                    i: doc.get_first(f.piece)?.as_u64()?,
                    title: s(f.title),
                    text: s(f.text),
                    page: s(f.page),
                    pdf_page: doc.get_first(f.pdf_page).and_then(|x| x.as_u64()).unwrap_or(0),
                    pdf_page_end: doc.get_first(f.pdf_page_end).and_then(|x| x.as_u64()),
                    heading_path: serde_json::from_str(&s(f.heading_path)).unwrap_or_default(),
                })
            })
            .collect();
        v.sort_by_key(|p| p.i);
        v
    }

    /// The page document of PDF page `pdf_page` of the PDF `zim_path`.
    pub fn page_doc(&self, zim_path: &str, pdf_page: u64) -> Option<PageDoc> {
        let searcher = self.reader.searcher();
        let must = |q: TermQuery| (Occur::Must, Box::new(q) as Box<dyn tantivy::query::Query>);
        let q = BooleanQuery::new(vec![
            must(TermQuery::new(Term::from_field_text(self.fields.zim_path, zim_path), IndexRecordOption::Basic)),
            must(TermQuery::new(Term::from_field_u64(self.fields.is_page, 1), IndexRecordOption::Basic)),
            must(TermQuery::new(Term::from_field_u64(self.fields.pdf_page, pdf_page), IndexRecordOption::Basic)),
        ]);
        let found = searcher.search(&q, &DocSetCollector).ok()?;
        let doc: TantivyDocument = searcher.doc(found.into_iter().next()?).ok()?;
        let s = |f: Field| doc.get_first(f).and_then(|v| v.as_str()).unwrap_or("").to_string();
        Some(PageDoc { pdf_page, label: s(self.fields.page), text: s(self.fields.page_text) })
    }

    /// Every page document of the PDF `zim_path`, in page order (for reusing them in a later edition's index).
    pub fn pages_of(&self, zim_path: &str) -> Vec<PageDoc> {
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
                Box::new(TermQuery::new(Term::from_field_u64(self.fields.is_page, 1), IndexRecordOption::Basic)),
            ),
        ]);
        let Ok(found) = searcher.search(&q, &DocSetCollector) else { return Vec::new() };
        let mut v: Vec<PageDoc> = found
            .into_iter()
            .filter_map(|addr| {
                let doc: TantivyDocument = searcher.doc(addr).ok()?;
                let s = |f: Field| doc.get_first(f).and_then(|v| v.as_str()).unwrap_or("").to_string();
                Some(PageDoc {
                    pdf_page: doc.get_first(self.fields.pdf_page)?.as_u64()?,
                    label: s(self.fields.page),
                    text: s(self.fields.page_text),
                })
            })
            .collect();
        v.sort_by_key(|p| p.pdf_page);
        v
    }

    /// The page of `start..=end` whose text matches the query terms best (`terms` as the query parser produced them, so
    /// already analysed), with its printed label. Each term counts once for being on the page and a little for how often; the
    /// earliest page wins a tie, so a query that matches no page text stays at `start`. `None` without page documents.
    pub fn best_page(
        &self,
        zim_path: &str,
        start: u64,
        end: u64,
        terms: &[String],
        analyzer: Option<&mut tantivy::tokenizer::TextAnalyzer>,
    ) -> Option<(u64, String)> {
        let an = analyzer?;
        let mut best: Option<(f64, u64, String)> = None;
        for page in start..=end.min(start + MAX_PAGES_PER_PIECE) {
            let Some(doc) = self.page_doc(zim_path, page) else { continue };
            let mut tf: std::collections::HashMap<String, u32> = std::collections::HashMap::new();
            let mut ts = an.token_stream(&doc.text);
            while ts.advance() {
                *tf.entry(ts.token().text.clone()).or_insert(0) += 1;
            }
            let score: f64 = terms.iter().filter_map(|t| tf.get(t)).map(|n| 1.0 + (*n as f64).ln() * 0.1).sum();
            if best.as_ref().is_none_or(|b| score > b.0) {
                best = Some((score, page, doc.label));
            }
        }
        best.map(|(_, p, l)| (p, l))
    }

    /// The text of PDF page `pdf_page` of the PDF `zim_path`: the stored page, else (an index without page documents) every
    /// piece that starts on it, in document order, joined by blank lines.
    pub fn page_text(&self, zim_path: &str, pdf_page: u64) -> String {
        if let Some(d) = self.page_doc(zim_path, pdf_page).filter(|d| !d.text.trim().is_empty()) {
            return d.text;
        }
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
                let n = doc.get_first(self.fields.piece)?.as_u64()?;
                let t = doc.get_first(self.fields.text).and_then(|v| v.as_str())?.trim().to_string();
                Some((n, t))
            })
            .filter(|(_, t)| !t.is_empty())
            .collect();
        pieces.sort();
        pieces.into_iter().map(|(_, t)| t).collect::<Vec<_>>().join("\n\n")
    }
}

/// A stored page: its PDF page number, printed label (may be empty) and text.
#[derive(Debug, Clone, PartialEq)]
pub struct PageDoc {
    pub pdf_page: u64,
    pub label: String,
    pub text: String,
}

/// The most pages past a piece's first that are looked at when choosing its cited page (a piece is a few paragraphs).
pub const MAX_PAGES_PER_PIECE: u64 = 12;

/// `cs_pdf_chunk`: `{"pages":[{"index","label","text"}]}` -> `{"pieces":[{"i","text","page","pdf_page","pdf_page_end"?,
/// "heading_path"}],"empty_pages":[...],"chunker":N}`. Pure: the shared chunker on plain page text (nothing is read or written).
pub fn chunk_request(request_json: &str) -> Result<String> {
    let v: Value = serde_json::from_str(request_json)?;
    let arr = v.get("pages").and_then(Value::as_array).ok_or_else(|| Error::bad_json("pages must be an array"))?;
    let mut pages = Vec::with_capacity(arr.len());
    for (k, p) in arr.iter().enumerate() {
        let bad = |what: &str| Error::bad_json(format!("pages[{k}]: {what}"));
        pages.push(cache_chunk::PageInput {
            index: p.get("index").and_then(Value::as_u64).ok_or_else(|| bad("index must be a whole number from 0"))?
                as usize,
            label: match p.get("label") {
                None | Some(Value::Null) => String::new(),
                Some(Value::String(s)) => s.clone(),
                Some(Value::Number(n)) => n.to_string(),
                Some(_) => return Err(bad("label must be text")),
            },
            text: match p.get("text") {
                None | Some(Value::Null) => String::new(),
                Some(Value::String(s)) => s.clone(),
                Some(_) => return Err(bad("text must be text")),
            },
        });
    }
    let page_docs: Vec<Value> = pages
        .iter()
        .filter(|p| !p.text.trim().is_empty())
        .map(|p| json!({"pdf_page": p.index + 1, "label": p.label, "text": p.text}))
        .collect();
    let done = cache_chunk::chunk_pages(&pages);
    let pieces: Vec<Value> = done
        .pieces
        .into_iter()
        .map(|p| {
            let mut o = json!({"i": p.i, "text": p.text, "page": p.page, "pdf_page": p.pdf_page, "heading_path": p.heading_path});
            if let Some(e) = p.pdf_page_end {
                o["pdf_page_end"] = json!(e);
            }
            o
        })
        .collect();
    Ok(json!({"pieces": pieces, "empty_pages": done.empty_pages, "chunker": CHUNKER_VERSION, "pages": page_docs})
        .to_string())
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
    fn titles_are_made_readable_when_the_app_gave_none() {
        assert_eq!(
            readable_title(
                "www.ready.gov/sites/default/files/2020-03/earthquakes_what-child-care-providers-need-to-know.pdf"
            ),
            "earthquakes what child care providers need to know"
        );
        assert_eq!(readable_title("Manuals/Flood__kit - guide.PDF"), "Flood kit guide");
        assert_eq!(readable_title("a.pdf"), "a");
        assert_eq!(readable_title("dir/.pdf"), "");
        assert_eq!(title_for("", "d/x_y.pdf"), "x y");
        assert_eq!(title_for("d/x_y.pdf", "d/x_y.pdf"), "x y");
        assert_eq!(title_for("  ", "d/x_y.pdf"), "x y");
        assert_eq!(title_for("Flood Guide", "d/x_y.pdf"), "Flood Guide");
        assert_eq!(title_for("", "dir/.pdf"), "dir/.pdf", "nothing readable: the path is better than nothing");
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
    fn chunk_request_makes_pieces_and_lists_empty_pages() {
        let text = "First sentence of the page. Second sentence follows here. Third one ends it.";
        let req = json!({"pages": [{"index": 0, "label": "i", "text": text}, {"index": 1, "label": "", "text": "  \n"}, {"index": 2, "label": "3", "text": text}]});
        let out: Value = serde_json::from_str(&chunk_request(&req.to_string()).unwrap()).unwrap();
        assert_eq!(out["chunker"], CHUNKER_VERSION);
        assert_eq!(out["empty_pages"], json!([1]));
        let p = out["pieces"].as_array().unwrap();
        assert!(!p.is_empty());
        assert_eq!(p[0]["i"], 0);
        assert_eq!(p[0]["page"], "i");
        assert_eq!(p[0]["pdf_page"], 1);
        assert!(p[0]["heading_path"].is_array());
        assert!(chunk_request("{}").is_err());
    }

    #[test]
    fn pdfs_tsv_round_trips() {
        let rows = vec![
            PdfRow {
                path: "a/b\tc.pdf".into(),
                size: Some(10),
                sha256: "ab".into(),
                pieces: 3,
                status: "added".into(),
            },
            PdfRow {
                path: "z.pdf".into(),
                size: None,
                sha256: String::new(),
                pieces: 0,
                status: "skipped:no_text".into(),
            },
        ];
        assert_eq!(rows_from_tsv(&rows_to_tsv(&rows)), rows);
    }

    #[test]
    fn dir_under_the_indexes_dir() {
        assert_eq!(dir_for(Path::new("/x/idx"), "0BADC0DE-0000"), PathBuf::from("/x/idx/zim-pdf/0badc0de-0000"));
    }
}
