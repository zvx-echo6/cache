//! Keyword-only snapshot indexes of captions and EPUBs: the read side (see `kwbuild.rs` for the builder).
//!
//! Three kinds share one Tantivy schema and one layout under the `indexes_dir` the app gives the core:
//!
//! ```text
//! <indexes_dir>/captions/<host>%2F<video uuid>/     the caption files of one PeerTube video saved on the device
//! <indexes_dir>/zim-captions/<zim uuid>/            the standalone caption files (text/vtt, .srt) of one ZIM
//! <indexes_dir>/zim-epub/<zim uuid>/                the EPUBs of one ZIM
//!     .build/            the writable working index while it is being built (never synced)
//!     snap/<build-id>/   published snapshots: Tantivy files, `items.tsv` and `manifest.json` (written last)
//! ```
//!
//! A piece is a caption passage (consecutive cues, see `vtt.rs`) or a chunk of an EPUB chapter (see `epub.rs`). The fields
//! a kind does not use are empty. Snapshot rules (manifest, verification, the pick, publishing) are in `snapshot.rs`.

use crate::error::{Error, Result};
use crate::index::{make_analyzer, stemmer_for_language, tv, ANALYZER};
use crate::search::{query_term_texts, term_coverage, top_deterministic};
use crate::snapshot::{self, Compat, Manifest};
use crate::zimsrc;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use tantivy::collector::DocSetCollector;
use tantivy::query::{BooleanQuery, Occur, Query, QueryParser, TermQuery};
use tantivy::schema::{Field, IndexRecordOption, Schema, TextFieldIndexing, TextOptions, Value as _, STORED, STRING};
use tantivy::{Index, IndexReader, ReloadPolicy, TantivyDocument, Term};

/// The version of this index's schema (the manifest's `format`).
pub const FORMAT: u32 = 1;
/// The Tantivy version the files are written by (the manifest's `tantivy`).
pub const TANTIVY: &str = "0.27";
/// The caption passage rules (`vtt::passages`); the manifest's `chunker` for the two caption kinds. Any change to the
/// passages made from the same cues bumps it.
pub const PASSAGE_RULES: u32 = 1;
pub use crate::snapshot::{BUILD_DIR, SNAP_DIR};
pub use cache_chunk::CHUNKER_VERSION;

pub const CAPTIONS: &str = "captions";
pub const ZIM_CAPTIONS: &str = "zim-captions";
pub const ZIM_EPUB: &str = "zim-epub";
pub const KINDS: [&str; 3] = [CAPTIONS, ZIM_CAPTIONS, ZIM_EPUB];
/// The most words of a piece a citation's `quote` holds.
pub use crate::pdfindex::{first_words, QUOTE_WORDS};
/// The per-item record in a snapshot (`path<TAB>size<TAB>sha256<TAB>pieces<TAB>status`, as `pdfs.tsv`).
pub const ITEMS_FILE: &str = "items.tsv";
/// The same record for an EPUB snapshot, under the name the spec gives it.
pub const EPUBS_FILE: &str = "epubs.tsv";

pub fn is_kind(kind: &str) -> bool {
    KINDS.contains(&kind)
}

/// The snapshot file that records the items of a kind.
pub fn record_file(kind: &str) -> &'static str {
    if kind == ZIM_EPUB {
        EPUBS_FILE
    } else {
        ITEMS_FILE
    }
}

/// The `chunker` a kind's manifest carries.
pub fn chunker_of(kind: &str) -> u32 {
    if kind == ZIM_EPUB {
        CHUNKER_VERSION
    } else {
        PASSAGE_RULES
    }
}

// ---------------------------------------------------------------------------------------------------------
// Schema

#[derive(Clone, Copy)]
pub struct Fields {
    /// `<item>@<i>`: the piece's key (also its address).
    pub pid: Field,
    /// The caption file (`captions-en.vtt`), the caption entry's ZIM path, or the EPUB's ZIM path.
    pub item: Field,
    pub piece: Field,
    /// The video's name, or the book's.
    pub title: Field,
    pub text: Field,
    pub lang: Field,
    pub start_ms: Field,
    pub end_ms: Field,
    /// EPUB: the chapter's path inside the EPUB.
    pub chapter: Field,
    /// EPUB: the number of the piece's first block in its chapter.
    pub block: Field,
    pub heading_path: Field,
    /// zim-captions: the ZIM path of the video the caption belongs to, when it was found.
    pub video: Field,
}

pub fn build_schema() -> (Schema, Fields) {
    let mut sb = Schema::builder();
    let pid = sb.add_text_field("pid", STRING | STORED);
    let item = sb.add_text_field("item", STRING | STORED);
    let piece = sb.add_u64_field("piece", STORED);
    let with_pos = TextFieldIndexing::default()
        .set_tokenizer(ANALYZER)
        .set_index_option(IndexRecordOption::WithFreqsAndPositions);
    let title = sb.add_text_field(
        "title",
        TextOptions::default()
            .set_indexing_options(with_pos.clone())
            .set_stored(),
    );
    let text = sb.add_text_field(
        "text",
        TextOptions::default().set_indexing_options(with_pos).set_stored(),
    );
    let lang = sb.add_text_field("lang", STRING | STORED);
    let start_ms = sb.add_u64_field("start_ms", STORED);
    let end_ms = sb.add_u64_field("end_ms", STORED);
    let chapter = sb.add_text_field("chapter", STRING | STORED);
    let block = sb.add_u64_field("block", STORED);
    let heading_path = sb.add_text_field("heading_path", STORED);
    let video = sb.add_text_field("video", STORED);
    (
        sb.build(),
        Fields {
            pid,
            item,
            piece,
            title,
            text,
            lang,
            start_ms,
            end_ms,
            chapter,
            block,
            heading_path,
            video,
        },
    )
}

pub fn fields_of(index: &Index) -> Result<Fields> {
    let s = index.schema();
    let f = |n: &str| {
        s.get_field(n)
            .map_err(|e| Error::internal(format!("index schema: {e}")))
    };
    Ok(Fields {
        pid: f("pid")?,
        item: f("item")?,
        piece: f("piece")?,
        title: f("title")?,
        text: f("text")?,
        lang: f("lang")?,
        start_ms: f("start_ms")?,
        end_ms: f("end_ms")?,
        chapter: f("chapter")?,
        block: f("block")?,
        heading_path: f("heading_path")?,
        video: f("video")?,
    })
}

pub fn pid_of(item: &str, piece: u64) -> String {
    format!("{item}@{piece}")
}

// ---------------------------------------------------------------------------------------------------------
// Snapshots (the generic part is snapshot.rs)

fn check(m: &Manifest, chunker: u32) -> std::result::Result<(), String> {
    if m.format != FORMAT || m.tantivy != TANTIVY || m.chunker != Some(chunker) {
        return Err(format!(
            "format {} tantivy {} chunker {:?} is not read by this core",
            m.format, m.tantivy, m.chunker
        ));
    }
    match &m.tokenizer {
        Some(t)
            if t.analyzer == ANALYZER
                && t.name
                    .strip_suffix("_stem")
                    .is_some_and(|code| stemmer_for_language(Some(code)).is_some()) =>
        {
            Ok(())
        }
        other => Err(format!("tokenizer {:?} is not known", other.as_ref().map(|t| &t.name))),
    }
}

fn compat_captions(m: &Manifest) -> std::result::Result<(), String> {
    check(m, PASSAGE_RULES)
}

fn compat_epub(m: &Manifest) -> std::result::Result<(), String> {
    check(m, CHUNKER_VERSION)
}

/// The kind's compatibility check: this core reads the format, the Tantivy version, the tokenizer and the chunker.
pub fn compat_for(kind: &str) -> Compat {
    if kind == ZIM_EPUB {
        compat_epub
    } else {
        compat_captions
    }
}

/// A source id in the one form its folder and manifest use: lowercase (video hosts and UUIDs are case-insensitive).
pub fn norm_source_id(source_id: &str) -> String {
    source_id.to_ascii_lowercase()
}

/// `<indexes_dir>/<kind>/<encoded source id>`.
pub fn dir_for(indexes_dir: &Path, kind: &str, source_id: &str) -> PathBuf {
    snapshot::source_dir(indexes_dir, kind, &norm_source_id(source_id))
}

/// The snapshot every device uses for the source; `dir` is `dir_for(..)`.
pub fn pick(dir: &Path, kind: &str, source_id: &str) -> Option<snapshot::Picked> {
    snapshot::pick(dir, kind, &norm_source_id(source_id), compat_for(kind))
}

/// Whether a snapshot folder with a manifest of this kind is in `dir` (a cheap look, no hashing): for status lists.
pub fn has_published(dir: &Path, kind: &str, source_id: &str) -> bool {
    snapshot::list(dir).iter().any(|n| {
        std::fs::read(dir.join(SNAP_DIR).join(n).join(snapshot::MANIFEST))
            .ok()
            .and_then(|b| serde_json::from_slice::<Manifest>(&b).ok())
            .is_some_and(|m| m.kind == kind && m.source_id == norm_source_id(source_id))
    })
}

fn extra_u64(m: &Manifest, key: &str) -> u64 {
    m.extra.get(key).and_then(Value::as_u64).unwrap_or(0)
}

/// The tokenizer for a language code such as `en`, `en-US` or `eng`.
pub fn tokenizer_for(lang: Option<&str>) -> &'static str {
    let base = lang.map(|l| l.split(['-', '_']).next().unwrap_or(l));
    crate::index::tokenizer_name_for(base)
}

// ---------------------------------------------------------------------------------------------------------
// Rows of the item record

/// One row of `items.tsv` / `epubs.tsv`.
#[derive(Debug, Clone, PartialEq)]
pub struct ItemRow {
    pub path: String,
    pub size: Option<u64>,
    pub sha256: String,
    pub pieces: u64,
    /// `added` or `skipped:<reason>`.
    pub status: String,
}

pub fn rows_to_tsv(rows: &[ItemRow]) -> String {
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

pub fn unescape(s: &str) -> String {
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
}

pub fn rows_from_tsv(text: &str) -> Vec<ItemRow> {
    text.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split('\t').collect();
            (f.len() == 5).then(|| ItemRow {
                path: unescape(f[0]),
                size: f[1].parse().ok(),
                sha256: f[2].to_string(),
                pieces: f[3].parse().unwrap_or(0),
                status: f[4].to_string(),
            })
        })
        .collect()
}

// ---------------------------------------------------------------------------------------------------------
// Searching a snapshot

/// A piece as stored.
#[derive(Debug, Clone, Default)]
pub struct StoredPiece {
    pub pid: String,
    pub item: String,
    pub i: u64,
    pub title: String,
    pub text: String,
    pub lang: String,
    pub start_ms: u64,
    pub end_ms: u64,
    pub chapter: String,
    pub block: u64,
    pub heading_path: Vec<String>,
    pub video: String,
}

/// A keyword hit.
#[derive(Debug, Clone)]
pub struct KwHit {
    pub raw: f32,
    pub coverage: f32,
    pub piece: StoredPiece,
}

/// An opened snapshot.
pub struct KwIndex {
    pub kind: String,
    pub snapshot: String,
    /// The snapshot folder.
    pub dir: PathBuf,
    pub manifest: Manifest,
    index: Index,
    reader: IndexReader,
    pub fields: Fields,
    pub docs: u64,
}

impl KwIndex {
    /// Open a verified snapshot folder for reading. Nothing is written to it.
    pub fn open(kind: &str, snapshot: &str, dir: &Path, manifest: Manifest) -> Result<KwIndex> {
        let index = tv(Index::open_in_dir(dir))?;
        index.tokenizers().register(
            ANALYZER,
            make_analyzer(
                manifest
                    .tokenizer
                    .as_ref()
                    .map(|t| t.name.as_str())
                    .unwrap_or("en_stem"),
            ),
        );
        let fields = fields_of(&index)?;
        let reader = tv(index.reader_builder().reload_policy(ReloadPolicy::Manual).try_into())?;
        let docs = reader.searcher().num_docs();
        Ok(KwIndex {
            kind: kind.to_string(),
            snapshot: snapshot.to_string(),
            dir: dir.to_path_buf(),
            manifest,
            index,
            reader,
            fields,
            docs,
        })
    }

    fn piece_of(&self, doc: &TantivyDocument) -> StoredPiece {
        let f = &self.fields;
        let s = |fl: Field| doc.get_first(fl).and_then(|v| v.as_str()).unwrap_or("").to_string();
        let n = |fl: Field| doc.get_first(fl).and_then(|v| v.as_u64()).unwrap_or(0);
        StoredPiece {
            pid: s(f.pid),
            item: s(f.item),
            i: n(f.piece),
            title: s(f.title),
            text: s(f.text),
            lang: s(f.lang),
            start_ms: n(f.start_ms),
            end_ms: n(f.end_ms),
            chapter: s(f.chapter),
            block: n(f.block),
            heading_path: serde_json::from_str(&s(f.heading_path)).unwrap_or_default(),
            video: s(f.video),
        }
    }

    /// BM25 over title (boosted 2x) and text, best first (ties by piece key), and the number of matching pieces. `lang`
    /// keeps the pieces of that language only.
    /// A snippet of the piece `text` around what matches `query` (see `search::match_snippet`).
    pub fn snippet(&self, query: &str, text: &str, max: usize) -> String {
        let mut qp = QueryParser::for_index(&self.index, vec![self.fields.title, self.fields.text]);
        qp.set_field_boost(self.fields.title, 2.0);
        let (q, _errors) = qp.parse_query_lenient(query);
        crate::search::match_snippet(&self.reader.searcher(), &*q, self.fields.text, text, max)
    }

    pub fn search(&self, query: &str, candidates: usize, lang: Option<&str>) -> Result<(Vec<KwHit>, usize)> {
        let searcher = self.reader.searcher();
        let mut qp = QueryParser::for_index(&self.index, vec![self.fields.title, self.fields.text]);
        qp.set_field_boost(self.fields.title, 2.0);
        let (parsed, _errors) = qp.parse_query_lenient(query);
        let terms = query_term_texts(&*parsed);
        let q: Box<dyn Query> = match lang.filter(|l| !l.is_empty()) {
            Some(l) => Box::new(BooleanQuery::new(vec![
                (Occur::Must, parsed),
                (
                    Occur::Must,
                    Box::new(TermQuery::new(
                        Term::from_field_text(self.fields.lang, l),
                        IndexRecordOption::Basic,
                    )),
                ),
            ])),
            None => parsed,
        };
        let (top, count) = top_deterministic(&searcher, &*q, candidates, self.fields.pid)
            .map_err(|e| Error::io(format!("tantivy: {e}")))?;
        let fields = [self.fields.title, self.fields.text];
        let hits = top
            .into_iter()
            .filter_map(|(raw, addr, _)| {
                let doc: TantivyDocument = searcher.doc(addr).ok()?;
                Some(KwHit {
                    raw,
                    coverage: term_coverage(&searcher, addr, &terms, &fields),
                    piece: self.piece_of(&doc),
                })
            })
            .collect();
        Ok((hits, count))
    }

    /// The piece with key `pid`.
    pub fn get(&self, pid: &str) -> Option<StoredPiece> {
        let searcher = self.reader.searcher();
        let q = TermQuery::new(Term::from_field_text(self.fields.pid, pid), IndexRecordOption::Basic);
        let found = searcher.search(&q, &DocSetCollector).ok()?;
        let addr = found.into_iter().next()?;
        let doc: TantivyDocument = searcher.doc(addr).ok()?;
        Some(self.piece_of(&doc))
    }

    fn pieces_matching(&self, terms: Vec<(Occur, Box<dyn Query>)>) -> Vec<StoredPiece> {
        let searcher = self.reader.searcher();
        let Ok(found) = searcher.search(&BooleanQuery::new(terms), &DocSetCollector) else {
            return Vec::new();
        };
        let mut v: Vec<StoredPiece> = found
            .into_iter()
            .filter_map(|addr| searcher.doc::<TantivyDocument>(addr).ok().map(|d| self.piece_of(&d)))
            .collect();
        v.sort_by_key(|p| p.i);
        v
    }

    fn term(&self, f: Field, v: &str) -> (Occur, Box<dyn Query>) {
        (
            Occur::Must,
            Box::new(TermQuery::new(Term::from_field_text(f, v), IndexRecordOption::Basic)),
        )
    }

    /// Every stored piece of one item (a caption file, an EPUB), in document order.
    pub fn pieces_of(&self, item: &str) -> Vec<StoredPiece> {
        self.pieces_matching(vec![self.term(self.fields.item, item)])
    }

    /// The pieces of one chapter of an EPUB, in document order.
    pub fn chapter_pieces(&self, item: &str, chapter: &str) -> Vec<StoredPiece> {
        self.pieces_matching(vec![
            self.term(self.fields.item, item),
            self.term(self.fields.chapter, chapter),
        ])
    }
}

/// `<scheme>:...` address of a piece. Captions of a saved video: `cap:<host>/<video uuid>/<piece key>`; of a ZIM:
/// `zimcap:<zim uuid>/<piece key>`; EPUBs of a ZIM: `zimepub:<zim uuid>/<piece key>`.
pub fn address_of(kind: &str, source_id: &str, pid: &str) -> String {
    match kind {
        CAPTIONS => format!("cap:{source_id}/{pid}"),
        ZIM_CAPTIONS => zimsrc::format_address(source_id, pid).replacen("zim:", "zimcap:", 1),
        _ => zimsrc::format_address(source_id, pid).replacen("zim:", "zimepub:", 1),
    }
}

/// Split an address made by [`address_of`] into (kind, source id, piece key).
pub fn parse_address(address: &str) -> Result<(&'static str, String, String)> {
    let bad = || Error::bad_json(format!("not a caption or epub address: {address:?}"));
    if let Some(rest) = address.strip_prefix("cap:") {
        let (id, pid) = rest.rsplit_once('/').ok_or_else(bad)?;
        return Ok((CAPTIONS, id.to_string(), pid.to_string()));
    }
    let (kind, prefix) = if address.starts_with("zimcap:") {
        (ZIM_CAPTIONS, "zimcap:")
    } else if address.starts_with("zimepub:") {
        (ZIM_EPUB, "zimepub:")
    } else {
        return Err(bad());
    };
    let a = zimsrc::parse_address(&format!("zim:{}", &address[prefix.len()..]))?;
    Ok((kind, a.id, zimsrc::percent_decode(&a.path).unwrap_or(a.path)))
}

/// A time in milliseconds as a JSON number of seconds: a whole number of seconds stays an integer.
pub fn secs(ms: u64) -> serde_json::Number {
    if ms.is_multiple_of(1000) {
        (ms / 1000).into()
    } else {
        serde_json::Number::from_f64(ms as f64 / 1000.0).unwrap_or_else(|| (ms / 1000).into())
    }
}

/// The status entry for a source's index, in the shape of `pdfindex`: `{"kind","snapshot","format","files"|"epubs","pieces",
/// "created"}` (`files` counts caption files, `epubs` EPUBs).
pub fn status_json(i: &KwIndex) -> Value {
    let key = if i.kind == ZIM_EPUB { "epubs" } else { "files" };
    json!({"kind": i.kind, "snapshot": i.snapshot, "format": i.manifest.format,
           key: extra_u64(&i.manifest, "items"), "pieces": i.docs, "created": i.manifest.created})
}

/// The link of a caption piece on a PeerTube watch page: `https://<host>/w/<video uuid>` for the source id `<host>/<uuid>`
/// (a `_` before a port in the instance folder name is a `:`).
pub fn watch_link(source_id: &str) -> String {
    let (host, uuid) = source_id.rsplit_once('/').unwrap_or(("", source_id));
    format!("https://{}/w/{uuid}", host.replacen('_', ":", 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn addresses_round_trip() {
        let a = address_of(CAPTIONS, "video.example/abc-1", "captions-en.vtt@3");
        assert_eq!(a, "cap:video.example/abc-1/captions-en.vtt@3");
        assert_eq!(
            parse_address(&a).unwrap(),
            (CAPTIONS, "video.example/abc-1".into(), "captions-en.vtt@3".into())
        );
        let id = "0badc0de-0000-4000-8000-00000000cafe";
        for kind in [ZIM_CAPTIONS, ZIM_EPUB] {
            let a = address_of(kind, id, "Media/a#1.srt@3");
            assert_eq!(
                parse_address(&a).unwrap(),
                (kind, id.to_string(), "Media/a#1.srt@3".to_string())
            );
        }
        assert!(parse_address("zim:x/y").is_err());
    }

    #[test]
    fn links_and_seconds() {
        assert_eq!(watch_link("peertube.example/9f2e"), "https://peertube.example/w/9f2e");
        assert_eq!(watch_link("127.0.0.1_8080/u"), "https://127.0.0.1:8080/w/u");
        assert_eq!(secs(12_000).to_string(), "12");
        assert_eq!(secs(12_500).to_string(), "12.5");
    }

    #[test]
    fn item_rows_round_trip() {
        let rows = vec![
            ItemRow {
                path: "a/b\tc.srt".into(),
                size: Some(10),
                sha256: "ab".into(),
                pieces: 3,
                status: "added".into(),
            },
            ItemRow {
                path: "z.epub".into(),
                size: None,
                sha256: String::new(),
                pieces: 0,
                status: "skipped:damaged".into(),
            },
        ];
        assert_eq!(rows_from_tsv(&rows_to_tsv(&rows)), rows);
    }

    #[test]
    fn dirs_and_tokenizers() {
        assert_eq!(
            dir_for(Path::new("/x/idx"), CAPTIONS, "Peer.Example/ABC"),
            PathBuf::from("/x/idx/captions/peer.example%2Fabc")
        );
        assert_eq!(tokenizer_for(Some("en-US")), "en_stem");
        assert_eq!(tokenizer_for(Some("fr")), "fr_stem");
        assert_eq!(tokenizer_for(None), "en_stem");
    }
}
