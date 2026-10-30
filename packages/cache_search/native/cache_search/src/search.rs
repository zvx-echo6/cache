//! `cs_search` and `cs_read`.

use crate::error::{Error, Result};
use crate::handle::{Handle, Source};
use crate::library::{self, LibHit, LibKwHit};
use crate::html;
use crate::zimsrc;
use crate::index;
use crate::zimx::{clean_snippet, XHit};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use tantivy::collector::{Count, TopDocs};
use tantivy::query::{Query, QueryParser};
use tantivy::schema::{Field, IndexRecordOption, Value as _};
use tantivy::snippet::SnippetGenerator;
use tantivy::tokenizer::{LowerCaser, RemoveLongFilter, SimpleTokenizer, TextAnalyzer};
use tantivy::{DocAddress, DocSet, Searcher, TantivyDocument, Term};

/// A keyword hit: its score, where it is in the index, and its key.
type ScoredDoc = (f32, DocAddress, String);

/// Reciprocal rank fusion constant.
pub const RRF_K: f64 = 60.0;

#[derive(Debug, Deserialize)]
struct Opts {
    #[serde(default = "five")]
    k: usize,
    #[serde(default)]
    offset: usize,
    #[serde(default)]
    sources: Option<Vec<String>>,
    /// Used only by libraries whose settings `embedding.model` equals `model`; other sources are keyword-only.
    #[serde(default)]
    query_vector: Option<QueryVec>,
}

#[derive(Debug, Deserialize)]
struct QueryVec {
    model: String,
    vector: Vec<f32>,
}

/// A merged result before its fields are built: a ZIM hit (source, hit) or a library hit (library, hit).
enum Entry {
    Zim(usize, usize),
    /// A dense (vector) hit: (index into `libs`, hit).
    Lib(usize, usize),
    /// A library keyword hit: (index into `lib_kw`, hit).
    LibKw(usize, usize),
}

/// One library's keyword list.
struct LibKw {
    src_i: usize,
    hits: Vec<LibKwHit>,
    count: usize,
}

fn five() -> usize {
    5
}

/// Reciprocal rank fusion, kept for fusing the keyword list with vector lists (packs, later); the
/// keyword merge across ZIM sources uses `merge_keyword`. Over ranked lists of `(address, raw score)` (best first). Each address scores
/// `sum 1/(RRF_K + rank)` over the lists it appears in (rank from 1; an address repeated inside one list counts
/// once, at its best rank). Returns addresses by fused score, best first. Equal fused scores (for example two
/// sources whose best hits are both rank 1) are ordered by the higher raw engine score, then by address.
pub fn rrf(lists: &[Vec<(String, f32)>]) -> Vec<(String, f64)> {
    let mut score: HashMap<&str, (f64, f32)> = HashMap::new();
    let mut order: Vec<&str> = Vec::new();
    for l in lists {
        let mut seen: Vec<&str> = Vec::new();
        for (i, (a, raw)) in l.iter().enumerate() {
            if seen.contains(&a.as_str()) {
                continue;
            }
            seen.push(a);
            let e = score.entry(a).or_insert_with(|| {
                order.push(a);
                (0.0, f32::MIN)
            });
            e.0 += 1.0 / (RRF_K + (i + 1) as f64);
            e.1 = e.1.max(*raw);
        }
    }
    let mut v: Vec<(String, (f64, f32))> = order.iter().map(|a| (a.to_string(), score[a])).collect();
    // total order: fused score (compared at 1e-12 resolution, so float summation order cannot matter), then
    // the higher raw score, then the address (string compare), so the output never depends on arrival order
    let q = |f: f64| (f * 1e12).round() as i64;
    v.sort_by(|a, b| {
        q(b.1 .0)
            .cmp(&q(a.1 .0))
            .then(b.1 .1.total_cmp(&a.1 .1))
            .then_with(|| a.0.cmp(&b.0))
    });
    v.into_iter().map(|(a, (f, _))| (a, f)).collect()
}

struct Hit {
    path: String,
    /// The Tantivy document; `None` for a hit from the ZIM's built-in Xapian index (`SrcHits::engine`).
    addr: Option<DocAddress>,
    /// Raw BM25 score from the source's index.
    raw: f32,
    /// Fraction of distinct query terms present in the document (title, lead or body); for a Xapian hit, in its title or
    /// text (see `xapian_coverage`).
    coverage: f32,
    /// Fraction of the query terms in the title (Xapian hits; a Tantivy hit's title is already boosted in its score, so
    /// it carries its coverage here).
    title_cov: f32,
}

/// What produced a ZIM source's keyword list.
enum Engine {
    /// The source's Tantivy index (built by `index_zim`).
    Tantivy { searcher: Searcher, query: Box<dyn Query>, lead: Field, title_f: Field },
    /// The ZIM's own Xapian index, through libzim: the hits in the same order as `SrcHits::hits`.
    Xapian(Vec<XHit>),
}

struct SrcHits {
    id: String,
    title: String,
    /// The stemming tokenizer of the source's language (`index::tokenizer_name_for`).
    tokenizer: &'static str,
    engine: Engine,
    count: usize,
    /// Best first.
    hits: Vec<Hit>,
}

fn text_of(doc: &TantivyDocument, f: Field) -> String {
    doc.get_first(f).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

/// Distinct query terms (text only, as produced by the index's own analyzer when the query was parsed).
pub(crate) fn query_term_texts(q: &dyn Query) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    q.query_terms(&mut |t, _| {
        if let Some(s) = t.value().as_str() {
            if !out.iter().any(|o| o == s) {
                out.push(s.to_string());
            }
        }
    });
    out
}

/// Fraction of `terms` that occur in the document at `addr` in any of `fields`. 1.0 when there are no terms.
pub(crate) fn term_coverage(searcher: &Searcher, addr: DocAddress, terms: &[String], fields: &[Field]) -> f32 {
    if terms.is_empty() {
        return 1.0;
    }
    let seg = searcher.segment_reader(addr.segment_ord);
    let invs: Vec<_> = fields.iter().filter_map(|f| seg.inverted_index(*f).ok().map(|i| (*f, i))).collect();
    let mut matched = 0usize;
    for t in terms {
        let hit = invs.iter().any(|(f, inv)| {
            let term = Term::from_field_text(*f, t);
            match inv.read_postings(&term, IndexRecordOption::Basic) {
                Ok(Some(mut p)) => p.doc() <= addr.doc_id && (p.doc() == addr.doc_id || p.seek(addr.doc_id) == addr.doc_id),
                _ => false,
            }
        });
        if hit {
            matched += 1;
        }
    }
    matched as f32 / terms.len() as f32
}

/// A hit chosen for the merged list: (source index, hit index, merge score, passed the coverage test).
struct Merged {
    si: usize,
    hi: usize,
    addr: String,
    score: f64,
    raw: f32,
    pass: bool,
}

/// Share of a hit's score factor that comes from its title coverage (the rest from its overall coverage).
const TITLE_WEIGHT: f64 = 0.5;

/// One keyword hit as the merge sees it.
#[derive(Clone, Debug)]
struct KwItem {
    addr: String,
    raw: f32,
    coverage: f32,
    title_cov: f32,
}

/// Merge keyword hits across sources; `lists[source][rank]` (best first within a source). A hit's relevance `rel` is
/// its raw score over the best raw score of its source (for a Xapian source the raw score is libzim's percentage, which
/// is 100 for the source's best hit, so it is relative too). Its score is `rel * (coverage + title_cov) / 2`. A hit counts as good only when its coverage is at
/// least `min_cov` and its `rel` at least `min_rel`; the others are dropped unless fewer than `need` good hits would
/// remain, in which case the best of the dropped ones fill up to `need` (after all the good ones). Ties on score go
/// to the higher raw score, then the smaller address.
fn merge_keyword(lists: &[Vec<KwItem>], min_cov: f32, min_rel: f32, need: usize) -> Vec<Merged> {
    let mut all: Vec<Merged> = Vec::new();
    for (si, l) in lists.iter().enumerate() {
        let top = l.iter().map(|h| h.raw).fold(f32::MIN, f32::max);
        for (hi, h) in l.iter().enumerate() {
            let rel = if top > 0.0 { (h.raw / top) as f64 } else { 1.0 };
            let factor = (1.0 - TITLE_WEIGHT) * h.coverage as f64 + TITLE_WEIGHT * h.title_cov as f64;
            all.push(Merged {
                si,
                hi,
                addr: h.addr.clone(),
                score: rel * factor,
                raw: h.raw,
                pass: h.coverage >= min_cov && rel >= min_rel as f64,
            });
        }
    }
    let cmp = |a: &Merged, b: &Merged| {
        b.score
            .total_cmp(&a.score)
            .then(b.raw.total_cmp(&a.raw))
            .then_with(|| a.addr.cmp(&b.addr))
    };
    all.sort_by(cmp);
    let kept = all.iter().filter(|m| m.pass).count();
    if kept >= need {
        all.retain(|m| m.pass);
        all
    } else {
        // kept ones first, then the best of the rest
        let (mut a, b): (Vec<_>, Vec<_>) = all.into_iter().partition(|m| m.pass);
        a.extend(b);
        a
    }
}

/// The tokens `an` produces for `text`.
fn analyzed(an: &mut TextAnalyzer, text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut ts = an.token_stream(text);
    while ts.advance() {
        out.push(ts.token().text.clone());
    }
    out
}

/// The distinct words of the query, lowercased and split the way the indexes split text.
fn query_words(query: &str) -> Vec<String> {
    let mut an = TextAnalyzer::builder(SimpleTokenizer::default()).filter(RemoveLongFilter::limit(40)).filter(LowerCaser).build();
    let mut out: Vec<String> = Vec::new();
    for w in analyzed(&mut an, query) {
        if !out.contains(&w) {
            out.push(w);
        }
    }
    out
}

/// The letters and digits of `s`, lowercased: text in a form where the same words compare equal however the markup
/// spaced or punctuated them.
pub fn compact(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(|c| c.to_lowercase()).collect()
}

/// Whether every fragment of `snippet` (libzim joins passages with "...") is in the page text whose `compact` form is
/// `page`. A fragment is judged on its letters and digits only.
pub fn snippet_in_text(snippet: &str, page: &str) -> bool {
    let flat = snippet.replace('\u{2026}', "...");
    let mut any = false;
    for frag in flat.split("...") {
        let c = compact(frag);
        if c.is_empty() {
            continue;
        }
        any = true;
        if !page.contains(&c) {
            return false;
        }
    }
    any
}

/// Where a snippet around byte `p` of `text` should start: the start of the sentence `p` is in when that is within a third
/// of `max` characters back, else a word start about a sixth of `max` back.
fn window_start(text: &str, p: usize, max: usize) -> usize {
    let head = &text[..p];
    let back = |n: usize| head.char_indices().rev().nth(n.saturating_sub(1)).map(|(i, _)| i).unwrap_or(0);
    let lo = back(max / 3);
    let region = &head[lo..];
    let mut best: Option<usize> = None;
    let mut it = region.char_indices().peekable();
    while let Some((_, c)) = it.next() {
        if matches!(c, '.' | '!' | '?' | '\n') {
            if let Some(&(j, d)) = it.peek() {
                if d.is_whitespace() {
                    best = Some(lo + j + d.len_utf8());
                }
            }
        }
    }
    if let Some(b) = best {
        let rest = &text[b..p];
        return b + (rest.len() - rest.trim_start().len());
    }
    let lo = back(max / 6);
    match head[lo..].find(char::is_whitespace) {
        Some(w) if lo + w < p => lo + w + head[lo + w..].chars().next().map(|c| c.len_utf8()).unwrap_or(1),
        _ => p,
    }
}

/// A snippet of at most `max` chars cut from `text` (an article's main text): starting a little before the first word
/// that stems to one of `stems`, or at the start of the text when none does.
pub fn main_snippet(text: &str, an: &mut TextAnalyzer, stems: &HashSet<String>, max: usize) -> String {
    let mut first: Option<usize> = None;
    if !stems.is_empty() {
        let mut ts = an.token_stream(text);
        while ts.advance() {
            let t = ts.token();
            if stems.contains(&t.text) {
                first = Some(t.offset_from);
                break;
            }
        }
    }
    let from = first.map(|p| window_start(text, p, max)).unwrap_or(0);
    html::snippet_from_text(&text[from..], max)
}

/// Hits kept per Xapian source for the merge when fewer than this many results were asked for: their articles are read
/// for coverage, so the window is bounded.
const KEEP_PER_SOURCE: usize = 10;

/// Bytes of an article read for its term coverage (the start of the page; a longer one is cut).
const COVERAGE_READ_BYTES: usize = 300_000;

/// Term coverage of a source's Xapian hits, which libzim does not report (it gives no list of matched terms, and the
/// words it marks in snippets did not appear on the real ZIMs tried). For each hit the article is read and tokenised with
/// the source's own analyzer: `coverage` is the fraction of the query words (compared after stemming) found in its title
/// or text, `title_cov` the fraction found in its title. Only the first `keep` hits are read and kept. A hit that cannot be
/// read as text is judged by its title alone. With no query words every hit counts as fully covered.
fn xapian_coverage(src: &zimsrc::ZimSource, an: &mut TextAnalyzer, words: &[String], hits: &mut Vec<Hit>, xhits: &mut Vec<XHit>, keep: usize) {
    hits.truncate(keep);
    xhits.truncate(keep);
    let stems: Vec<String> = words.iter().filter_map(|w| analyzed(an, w).into_iter().next()).collect();
    if stems.is_empty() {
        return;
    }
    let n = stems.len() as f32;
    for (h, x) in hits.iter_mut().zip(xhits.iter()) {
        let title: HashSet<String> = analyzed(an, &x.title).into_iter().collect();
        let mut body: HashSet<String> = HashSet::new();
        if let Ok(e) = src.get(&x.path) {
            let m = e.mime.to_ascii_lowercase();
            if m.starts_with("text/html") || m.starts_with("text/plain") {
                let end = e.bytes.len().min(COVERAGE_READ_BYTES);
                let raw = String::from_utf8_lossy(&e.bytes[..end]);
                let text = if m.starts_with("text/html") { html::html_to_text(&raw) } else { raw.into_owned() };
                body = analyzed(an, &text).into_iter().collect();
            }
        }
        let in_title = stems.iter().filter(|s| title.contains(*s)).count() as f32;
        let in_any = stems.iter().filter(|s| title.contains(*s) || body.contains(*s)).count() as f32;
        h.coverage = in_any / n;
        h.title_cov = in_title / n;
    }
}

/// The top `candidates` hits of a ZIM's Xapian index for `query`: the ranked list for the merge (libzim's percentage as
/// the raw score; coverage is filled in by `xapian_coverage`), the hits as
/// libzim returned them, and the estimated match count. `None` when libzim fails, also after a retry with the query
/// reduced to its words (Xapian's own query syntax can reject text such as an unmatched quote or parenthesis).
fn xapian_list(x: &crate::zimx::Zimx, query: &str, candidates: usize) -> Option<(Vec<Hit>, Vec<XHit>, usize)> {
    let found = x.search(query, 0, candidates).or_else(|_| {
        let words: String = query.chars().map(|c| if c.is_alphanumeric() { c } else { ' ' }).collect();
        if words.trim().is_empty() {
            return Err(crate::error::Error::bad_json("empty query"));
        }
        x.search(words.trim(), 0, candidates)
    });
    let (found, count) = found.ok()?;
    let mut seen: HashSet<String> = HashSet::new();
    let (mut hits, mut xhits) = (Vec::new(), Vec::new());
    for h in found {
        if h.path.is_empty() || !seen.insert(h.path.clone()) {
            continue;
        }
        hits.push(Hit {
            path: h.path.clone(),
            addr: None,
            raw: h.score as f32,
            coverage: 1.0,
            title_cov: 1.0,
        });
        xhits.push(h);
    }
    Some((hits, xhits, count))
}

/// Cap on how far the candidate window is widened to resolve a score tie at its boundary.
const TIE_CAP: usize = 8192;

/// The best `limit` documents of `q` by score, in a deterministic order: score descending, then the stored
/// `key_field` (the document's path or point id) ascending. Tantivy breaks equal scores by internal document
/// address, which depends on how the index was built (a resumed build has other segments than a clean one), so
/// the window is widened until the documents tied with the last one are all in, then sorted by key and cut.
/// Returns (score, address, key) and the total match count.
pub(crate) fn top_deterministic(
    searcher: &Searcher,
    q: &dyn Query,
    limit: usize,
    key_field: Field,
) -> tantivy::Result<(Vec<ScoredDoc>, usize)> {
    let limit = limit.max(1);
    let mut l = limit;
    loop {
        let (top, count) = searcher.search(q, &(TopDocs::with_limit(l).order_by_score(), Count))?;
        let complete = top.len() < l
            || l >= TIE_CAP
            || top.last().map(|t| t.0).unwrap_or(0.0) < top[limit - 1].0;
        if !complete {
            l = (l * 2).min(TIE_CAP);
            continue;
        }
        let mut v: Vec<(f32, DocAddress, String)> = Vec::with_capacity(top.len());
        for (score, addr) in top {
            let doc: TantivyDocument = searcher.doc(addr)?;
            v.push((score, addr, text_of(&doc, key_field)));
        }
        v.sort_by(|a, b| b.0.total_cmp(&a.0).then_with(|| a.2.cmp(&b.2)));
        v.truncate(limit);
        return Ok((v, count));
    }
}

impl Handle {
    pub fn search(&mut self, query: &str, options_json: Option<&str>) -> Result<String> {
        self.poll_opening();
        let opts: Opts = match options_json.map(str::trim) {
            None | Some("") | Some("null") => serde_json::from_str("{}")?,
            Some(s) => serde_json::from_str(s)?,
        };
        let candidates = self.candidates_per_list.max(1) as usize + opts.offset;
        let snippet_chars = self.snippet_chars as usize;
        let min_cov = self.min_term_coverage;
        let min_rel = self.min_relevance;
        let filter: Option<Vec<String>> =
            opts.sources.as_ref().map(|v| v.iter().map(|s| s.to_ascii_lowercase()).collect());

        let words = query_words(query);
        let mut per: Vec<SrcHits> = Vec::new();
        for s in self.sources.iter_mut() {
            let Source::Zim(z) = s else { continue };
            if let Some(f) = &filter {
                if !f.contains(&z.src.id) {
                    continue;
                }
            }
            let (id, title) = (z.src.id.clone(), z.src.title.clone());
            let tokenizer = index::tokenizer_name_for(z.src.language.as_deref());
            // A ZIM with a built-in Xapian index uses it (no index_dir needed). If libzim fails on this query, the
            // source falls back to its Tantivy index, if it has one.
            if let Some(x) = z.xapian() {
                if let Some((mut hits, mut xhits, count)) = xapian_list(&x, query, candidates) {
                    let mut an = index::make_analyzer(index::tokenizer_name_for(z.src.language.as_deref()));
                    xapian_coverage(&z.src, &mut an, &words, &mut hits, &mut xhits, (opts.offset + opts.k).max(KEEP_PER_SOURCE));
                    per.push(SrcHits { id, title, tokenizer, engine: Engine::Xapian(xhits), count, hits });
                    continue;
                }
            }
            // Sources that are not `done`, or whose index cannot be opened, are skipped (cs_status reports them).
            let Ok(Some(oi)) = z.searchable() else { continue };
            let searcher = oi.reader.searcher();
            let mut qp = QueryParser::for_index(&oi.index, vec![oi.fields.title, oi.fields.lead, oi.fields.body]);
            qp.set_field_boost(oi.fields.title, 2.0);
            let (q, _errors) = qp.parse_query_lenient(query);
            let Ok((top, count)) = top_deterministic(&searcher, &*q, candidates, oi.fields.path) else {
                continue;
            };
            let terms = query_term_texts(&*q);
            let fields = [oi.fields.title, oi.fields.lead, oi.fields.body];
            let mut hits = Vec::with_capacity(top.len());
            for (raw, addr, path) in top {
                let coverage = term_coverage(&searcher, addr, &terms, &fields);
                hits.push(Hit { path, addr: Some(addr), raw, coverage, title_cov: coverage });
            }
            per.push(SrcHits {
                id,
                title,
                tokenizer,
                engine: Engine::Tantivy { searcher, query: q, lead: oi.fields.lead, title_f: oi.fields.title },
                count,
                hits,
            });
        }


        // Libraries' keyword lists (own scored index or device index) join the cross-source keyword merge.
        let mut lib_kw: Vec<LibKw> = Vec::new();
        for (src_i, s) in self.sources.iter_mut().enumerate() {
            let Source::Library(l) = s else { continue };
            if let Some(f) = &filter {
                if !f.contains(&l.id().to_ascii_lowercase()) {
                    continue;
                }
            }
            if let Ok(Some((hits, count))) = l.keyword_list(query, candidates, snippet_chars) {
                lib_kw.push(LibKw { src_i, hits, count });
            }
        }

        let mut lists: Vec<Vec<KwItem>> = per
            .iter()
            .map(|p| {
                p.hits
                    .iter()
                    .map(|h| KwItem {
                        addr: zimsrc::format_address(&p.id, &h.path),
                        raw: h.raw,
                        coverage: h.coverage,
                        title_cov: h.title_cov,
                    })
                    .collect()
            })
            .collect();
        lists.extend(lib_kw.iter().map(|k| {
            k.hits
                .iter()
                .map(|h| KwItem { addr: h.address.clone(), raw: h.raw, coverage: h.coverage, title_cov: h.coverage })
                .collect()
        }));
        let need = opts.offset + opts.k;
        let merged = merge_keyword(&lists, min_cov, min_rel, need);
        let entry_of = |m: &Merged| {
            if m.si < per.len() {
                Entry::Zim(m.si, m.hi)
            } else {
                Entry::LibKw(m.si - per.len(), m.hi)
            }
        };

        // Libraries: a vector list for each library whose embedding model matches the query vector.
        let mut keyword_only: Vec<String> = per.iter().map(|p| p.id.clone()).collect();
        let mut vector_sources: Vec<String> = Vec::new();
        let mut libs: Vec<(usize, Vec<LibHit>)> = Vec::new();
        let base = self.candidates_per_list.max(1) as usize + opts.offset;
        for (src_i, s) in self.sources.iter().enumerate() {
            let Source::Library(l) = s else { continue };
            if let Some(f) = &filter {
                if !f.contains(&l.id().to_ascii_lowercase()) {
                    continue;
                }
            }
            let used = match &opts.query_vector {
                Some(q) if l.accepts_vector(&q.model, q.vector.len()) => {
                    l.dense_search(&q.vector, need, base, snippet_chars).ok()
                }
                _ => None,
            };
            match used {
                Some(h) => {
                    vector_sources.push(l.id().to_string());
                    libs.push((src_i, h));
                }
                None => keyword_only.push(l.id().to_string()),
            }
        }

        // Order: the keyword-merged list as it is; with library vector lists, reciprocal rank fusion (k=60) of
        // the keyword list and each library's vector list, one entry per address (a point found by both is
        // taken from the vector list, which carries its payload).
        let order: Vec<Entry> = if libs.is_empty() {
            merged.iter().map(entry_of).collect()
        } else {
            let mut by_addr: HashMap<String, Entry> = HashMap::new();
            let mut rank_lists: Vec<Vec<(String, f32)>> = Vec::new();
            let mut kw: Vec<(String, f32)> = Vec::new();
            for m in &merged {
                kw.push((m.addr.clone(), m.raw));
                by_addr.entry(m.addr.clone()).or_insert_with(|| entry_of(m));
            }
            rank_lists.push(kw);
            for (li, (_, hits)) in libs.iter().enumerate() {
                let mut l: Vec<(String, f32)> = Vec::new();
                for (hi, h) in hits.iter().enumerate() {
                    l.push((h.address.clone(), h.score));
                    by_addr.insert(h.address.clone(), Entry::Lib(li, hi));
                }
                rank_lists.push(l);
            }
            rrf(&rank_lists).into_iter().filter_map(|(a, _)| by_addr.remove(&a)).collect()
        };

        // Collapse duplicate library hits after the merge (same document value + title, or without a document
        // field the same title + snippet): the best-ranked stays (on an exact tie the smaller address, which the
        // ordering already puts first), and the list fills up from the next ranked. Keyword-only library hits
        // are read from the shard payload as they are reached, so only the hits that can be shown are read.
        enum Shown {
            Zim(usize, usize),
            Lib(usize, LibHit),
        }
        let mut seen: HashSet<String> = HashSet::new();
        let mut shown: Vec<Shown> = Vec::new();
        for e in order {
            if shown.len() >= need {
                break;
            }
            match e {
                Entry::Zim(si, hi) => shown.push(Shown::Zim(si, hi)),
                Entry::Lib(li, hi) => {
                    let h = &libs[li].1[hi];
                    if seen.insert(h.key.clone()) {
                        shown.push(Shown::Lib(libs[li].0, h.clone()));
                    }
                }
                Entry::LibKw(ki, hi) => {
                    let (src_i, kw) = (lib_kw[ki].src_i, &lib_kw[ki].hits[hi]);
                    let hit = match &kw.hit {
                        Some(h) => Some(h.clone()),
                        None => match &self.sources[src_i] {
                            Source::Library(l) => l.hit_for_point(&kw.point_id, kw.raw, snippet_chars).ok().flatten(),
                            _ => None,
                        },
                    };
                    if let Some(h) = hit {
                        if seen.insert(h.key.clone()) {
                            shown.push(Shown::Lib(src_i, h));
                        }
                    }
                }
            }
        }

        let mut generators: HashMap<usize, Option<SnippetGenerator>> = HashMap::new();
        let mut fitters: HashMap<usize, (TextAnalyzer, HashSet<String>)> = HashMap::new();
        let mut results: Vec<Value> = Vec::new();
        for e in shown.into_iter().skip(opts.offset).take(opts.k) {
            let (m_si, hi) = match e {
                Shown::Lib(src_i, h) => {
                    let Source::Library(l) = &self.sources[src_i] else { continue };
                    results.push(json!({
                        "address": h.address,
                        "title": h.title,
                        "snippet": h.snippet,
                        "source_id": l.id(),
                        "source_kind": "library",
                        "source_title": l.settings.title,
                        "page": h.page,
                    }));
                    continue;
                }
                Shown::Zim(si, hi) => (si, hi),
            };
            let p = &per[m_si];
            let h = &p.hits[hi];
            let address = zimsrc::format_address(&p.id, &h.path);
            let (searcher, query, lead_f, title_f) = match &p.engine {
                Engine::Xapian(xhits) => {
                    // libzim's own snippet (HTML with <b>), stripped and cut like every other snippet. libzim picks its
                    // passage from the whole page, menus and footers included, so a snippet that is not in the article's
                    // main text is rebuilt from that text around the query's first term (see `fit_snippet`).
                    let xh = &xhits[hi];
                    let snippet = clean_snippet(&xh.snippet, snippet_chars);
                    let snippet = self.fit_snippet(&mut fitters, m_si, p.tokenizer, &words, &address, snippet, snippet_chars);
                    let art_title = if xh.title.is_empty() { xh.path.clone() } else { xh.title.clone() };
                    results.push(json!({
                        "address": address,
                        "title": format!("{}: {}", p.title, art_title),
                        "snippet": snippet,
                        "source_id": p.id,
                        "source_kind": "zim",
                        "source_title": p.title,
                        "page": Value::Null,
                    }));
                    continue;
                }
                Engine::Tantivy { searcher, query, lead, title_f } => (searcher, query, *lead, *title_f),
            };
            let Some(addr) = h.addr else { continue };
            let Ok(doc) = searcher.doc::<TantivyDocument>(addr) else { continue };
            let art_title = text_of(&doc, title_f);
            let lead = text_of(&doc, lead_f);
            let gen = generators.entry(m_si).or_insert_with(|| {
                let mut g = SnippetGenerator::create(searcher, &**query, lead_f).ok();
                if let Some(g) = g.as_mut() {
                    g.set_max_num_chars(snippet_chars.max(1));
                }
                g
            });
            let frag = gen.as_ref().map(|g| g.snippet(&lead).fragment().to_string()).unwrap_or_default();
            let snippet = if frag.trim().is_empty() {
                html::snippet_from_text(&lead, snippet_chars)
            } else {
                let t = html::tidy_fragment(&frag);
                if t.chars().count() > snippet_chars {
                    html::snippet_from_text(&t, snippet_chars)
                } else {
                    t
                }
            };
            // an index built before main-content extraction has menu text in its leads: same check as for Xapian hits
            let snippet = self.fit_snippet(&mut fitters, m_si, per[m_si].tokenizer, &words, &address, snippet, snippet_chars);
            results.push(json!({
                "address": address,
                "title": format!("{}: {}", p.title, art_title),
                "snippet": snippet,
                "source_id": p.id,
                "source_kind": "zim",
                "source_title": p.title,
                "page": Value::Null,
            }));
        }
        Ok(json!({
            "results": results,
            "total_estimate": per.iter().map(|p| p.count).sum::<usize>()
                + lib_kw.iter().map(|k| k.count).sum::<usize>()
                + libs.iter().map(|(_, h)| h.len()).sum::<usize>(),
            "vector_sources": vector_sources,
            "keyword_only_sources": keyword_only,
        })
        .to_string())
    }

    /// `snippet` if it is text of the article's main content, else a snippet cut from the main text around the first
    /// occurrence of a query term (the first words of the main text when no term is found). Only HTML articles are
    /// checked; anything else (or an article that cannot be read) keeps `snippet`. `fitters` caches the analyzer and the
    /// query's stems for each source.
    #[allow(clippy::too_many_arguments)]
    fn fit_snippet(
        &self,
        fitters: &mut HashMap<usize, (TextAnalyzer, HashSet<String>)>,
        src: usize,
        tokenizer: &str,
        words: &[String],
        address: &str,
        snippet: String,
        max: usize,
    ) -> String {
        let Ok(e) = self.zim_get(address) else { return snippet };
        if !e.mime.to_ascii_lowercase().starts_with("text/html") {
            return snippet;
        }
        let main = html::html_to_text(&String::from_utf8_lossy(&e.bytes));
        if !snippet.is_empty() && snippet_in_text(&snippet, &compact(&main)) {
            return snippet;
        }
        let (an, stems) = fitters.entry(src).or_insert_with(|| {
            let mut an = index::make_analyzer(tokenizer);
            let stems: HashSet<String> = words.iter().filter_map(|w| analyzed(&mut an, w).into_iter().next()).collect();
            (an, stems)
        });
        main_snippet(&main, an, stems, max)
    }

    /// Plain text of an address, cut to `max_chars` at a paragraph end.
    pub fn read(&mut self, address: &str, max_chars: i32) -> Result<String> {
        self.poll_opening();
        if address.starts_with("pack:") {
            return Err(Error::unsupported("pack addresses are not supported yet"));
        }
        if max_chars <= 0 {
            return Err(Error::bad_json("max_chars must be positive"));
        }
        if address.starts_with("lib:") {
            let (lib_id, point_id) = library::parse_lib_address(address)?;
            let l = self
                .sources
                .iter()
                .find_map(|s| match s {
                    Source::Library(l) if l.id() == lib_id => Some(l),
                    _ => None,
                })
                .ok_or_else(|| {
                    if self.sources.iter().any(|s| matches!(s, Source::Opening(o) if o.id == lib_id)) {
                        Error::new(crate::ErrorCode::Busy, format!("library {lib_id:?} is still opening"))
                    } else if self.sources.iter().any(|s| matches!(s, Source::Updating(o) if o.id == lib_id)) {
                        Error::new(crate::ErrorCode::Busy, format!("library {lib_id:?} is being updated"))
                    } else {
                        Error::not_found(format!("no library source {lib_id:?}"))
                    }
                })?;
            let (r, truncated) = l.read_point(point_id, max_chars as usize)?;
            return Ok(json!({
                "address": address, "title": r.title, "text": r.text, "truncated": truncated,
                "author": r.author, "page": r.page, "source_type": r.source_type,
            })
            .to_string());
        }
        let e = self.zim_get(address)?;
        read_zim_entry(address, &e, max_chars)
    }
}

/// The `read` result for a ZIM entry: its text (HTML converted, plain text trimmed), cut at a paragraph end to `max_chars`.
/// Public (hidden) so the byte-identity test can run it on an entry read by either reader.
#[doc(hidden)]
pub fn read_zim_entry(address: &str, e: &zimsrc::RawEntry, max_chars: i32) -> Result<String> {
    let m = e.mime.to_ascii_lowercase();
    let text = if m.starts_with("text/html") {
        html::html_to_text(&String::from_utf8_lossy(&e.bytes))
    } else if m.starts_with("text/plain") {
        String::from_utf8_lossy(&e.bytes).trim().to_string()
    } else {
        return Err(Error::unsupported(format!("cannot read {} as text", e.mime)));
    };
    let (text, truncated) = html::cut_at_paragraph(&text, max_chars as usize);
    Ok(json!({"address": address, "title": e.title, "text": text, "truncated": truncated}).to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn l(v: &[&str]) -> Vec<(String, f32)> {
        v.iter().enumerate().map(|(i, s)| (s.to_string(), 10.0 - i as f32)).collect()
    }

    fn stems(words: &[&str]) -> (TextAnalyzer, HashSet<String>) {
        let mut an = index::make_analyzer("en_stem");
        let set = words.iter().filter_map(|w| analyzed(&mut an, w).into_iter().next()).collect();
        (an, set)
    }

    #[test]
    fn snippet_text_check_ignores_spacing_and_marks() {
        let page = compact("Boise is the capital of Idaho.\n\nIt lies on the Boise River, in the Treasure Valley.");
        assert!(snippet_in_text("capital of  Idaho. It lies on the Boise River", &page));
        assert!(snippet_in_text("...the capital of Idaho... in the Treasure Valley.", &page));
        // one passage that is not in the page (a menu) fails the whole snippet; an empty one is not "in" the page
        assert!(!snippet_in_text("Home Docs Downloads", &page));
        assert!(!snippet_in_text("the capital of Idaho ... Home Docs", &page));
        assert!(!snippet_in_text("...", &page));
    }

    #[test]
    fn main_snippet_starts_at_the_sentence_of_the_first_query_term() {
        let text = format!("{} The first sentence has nothing. Reading the manual about rebasing is the key step here. {}", "Filler words go here. ".repeat(40), "Then more text follows. ".repeat(40));
        let (mut an, st) = stems(&["rebase"]);
        let s = main_snippet(&text, &mut an, &st, 120);
        assert!(s.starts_with("Reading the manual about rebasing"), "{s}");
        assert!(s.chars().count() <= 120);
        // a term early in the text starts at the beginning
        let (mut an, st) = stems(&["filler"]);
        assert!(main_snippet(&text, &mut an, &st, 60).starts_with("Filler words"));
    }

    #[test]
    fn main_snippet_without_a_matching_term_is_the_start_of_the_text() {
        let text = "Alpha beta gamma. Delta epsilon.";
        let (mut an, st) = stems(&["zeta"]);
        assert_eq!(main_snippet(text, &mut an, &st, 400), "Alpha beta gamma. Delta epsilon.");
        let (mut an, st) = stems(&[]);
        assert_eq!(main_snippet(text, &mut an, &st, 400), "Alpha beta gamma. Delta epsilon.");
    }

    #[test]
    fn main_snippet_with_a_long_unbroken_run_before_the_term_still_cuts_on_a_word() {
        let text = format!("{} flood insurance matters", "x".repeat(900));
        let (mut an, st) = stems(&["flood"]);
        let s = main_snippet(&text, &mut an, &st, 100);
        assert!(s.starts_with("flood insurance") || s.contains("flood"), "{s}");
    }

    #[test]
    fn rrf_single_list_keeps_order() {
        let r = rrf(&[l(&["a", "b", "c"])]);
        assert_eq!(r.iter().map(|x| x.0.as_str()).collect::<Vec<_>>(), ["a", "b", "c"]);
        assert!((r[0].1 - 1.0 / 61.0).abs() < 1e-12);
        assert!((r[2].1 - 1.0 / 63.0).abs() < 1e-12);
    }

    #[test]
    fn rrf_agreement_wins() {
        let r = rrf(&[l(&["a", "b", "c"]), l(&["x", "c", "a"])]);
        let order: Vec<&str> = r.iter().map(|x| x.0.as_str()).collect();
        // a: 1/61+1/63, c: 1/63+1/62, x: 1/61 (raw 10), b: 1/62
        assert_eq!(order, ["a", "c", "x", "b"]);
    }

    #[test]
    fn rrf_ties_go_to_higher_raw_score_then_first_seen() {
        let r = rrf(&[vec![("weak".into(), 1.5)], vec![("strong".into(), 9.0)]]);
        assert_eq!(r[0].0, "strong");
        assert_eq!(r[1].0, "weak");
        let r = rrf(&[vec![("a".into(), 2.0)], vec![("b".into(), 2.0)]]);
        assert_eq!((r[0].0.as_str(), r[1].0.as_str()), ("a", "b"));
    }

    #[test]
    fn rrf_one_entry_per_address() {
        let r = rrf(&[l(&["a", "a", "b"])]);
        assert_eq!(r.len(), 2);
        assert!((r[0].1 - 1.0 / 61.0).abs() < 1e-12);
        assert!(rrf(&[]).is_empty());
    }

    #[test]
    fn options_defaults_and_ignored_vector() {
        let o: Opts = serde_json::from_str("{}").unwrap();
        assert_eq!((o.k, o.offset), (5, 0));
        assert!(o.sources.is_none());
        let o: Opts = serde_json::from_str(r#"{"k":3,"offset":2,"sources":null,"query_vector":{"model":"m","vector":[0.1]}}"#).unwrap();
        assert_eq!((o.k, o.offset), (3, 2));
        assert!(serde_json::from_str::<Opts>(r#"{"k":"x"}"#).is_err());
    }

    #[test]
    fn read_rejects_pack_and_bad_args() {
        let mut h = Handle::open(r#"{"sources":[]}"#).unwrap();
        assert_eq!(h.read("pack:abc/1", 100).unwrap_err().code, crate::ErrorCode::Unsupported);
        assert_eq!(h.read("zim:x/y", 100).unwrap_err().code, crate::ErrorCode::BadJson);
        assert_eq!(h.read("nonsense", 100).unwrap_err().code, crate::ErrorCode::BadJson);
        let u = "17e9fb54-9554-d2cd-e15f-17cf750882d1";
        assert_eq!(h.read(&format!("zim:{u}/p"), 0).unwrap_err().code, crate::ErrorCode::BadJson);
        assert_eq!(h.read(&format!("zim:{u}/p"), 10).unwrap_err().code, crate::ErrorCode::NotFound);
    }

    /// Give each hit an address that sorts in (source, rank) order.
    fn item(raw: f32, coverage: f32, addr: String) -> KwItem {
        KwItem { addr, raw, coverage, title_cov: coverage }
    }

    fn addr(lists: &[Vec<(f32, f32)>]) -> Vec<Vec<KwItem>> {
        lists
            .iter()
            .enumerate()
            .map(|(si, l)| l.iter().enumerate().map(|(hi, &(r, c))| item(r, c, format!("s{si:02}h{hi:03}"))).collect())
            .collect()
    }

    fn order(m: &[Merged]) -> Vec<(usize, usize)> {
        m.iter().map(|x| (x.si, x.hi)).collect()
    }

    #[test]
    fn merge_keyword_drops_low_coverage_and_normalises_per_source() {
        // source 0: strong, full coverage. source 1: weak raw scores, one hit with 2/3 coverage, one with 1/3.
        let lists = vec![vec![(10.0, 1.0), (6.0, 1.0)], vec![(2.0, 0.67), (1.9, 0.34)]];
        let m = merge_keyword(&addr(&lists), 0.5, 0.0, 3);
        // (1,1) has coverage 0.34 < 0.5 and is dropped; 3 remain: (0,0)=1.0, (1,0)=0.67, (0,1)=0.6
        assert_eq!(order(&m), vec![(0, 0), (1, 0), (0, 1)]);
        // per-source normalisation: the weak source's best hit scores 1.0*coverage, not its tiny raw score
        assert!((m[1].score - 0.67).abs() < 1e-6);
    }

    #[test]
    fn merge_keyword_fills_up_to_need_when_too_few_pass() {
        let lists = vec![vec![(10.0, 0.2), (9.0, 0.4)], vec![(5.0, 0.3)]];
        let m = merge_keyword(&addr(&lists), 0.5, 0.0, 3);
        assert_eq!(m.len(), 3, "nothing passes, so the best ones are all kept");
        assert_eq!(order(&m), vec![(0, 1), (1, 0), (0, 0)]); // by normalised score x coverage
        // enough pass: the rest are dropped
        let lists = vec![vec![(10.0, 1.0), (9.0, 0.1)], vec![(5.0, 0.9)]];
        let m = merge_keyword(&addr(&lists), 0.5, 0.0, 2);
        assert_eq!(order(&m), vec![(0, 0), (1, 0)]);
        // passing hits stay ahead of fillers even when a filler scores higher
        let lists = vec![vec![(10.0, 0.45), (1.0, 0.9)]];
        let m = merge_keyword(&addr(&lists), 0.5, 0.0, 2);
        assert_eq!(order(&m), vec![(0, 1), (0, 0)]);
    }

    #[test]
    fn merge_keyword_empty_and_ties() {
        assert!(merge_keyword(&[], 0.5, 0.0, 5).is_empty());
        // equal scores: the smaller address first, whatever the source order
        let lists = vec![vec![item(4.0, 1.0, "b".to_string())], vec![item(4.0, 1.0, "a".to_string())]];
        assert_eq!(order(&merge_keyword(&lists, 0.5, 0.0, 2)), vec![(1, 0), (0, 0)]);
        let lists = vec![vec![(4.0, 1.0)], vec![(4.0, 1.0)]];
        assert_eq!(order(&merge_keyword(&addr(&lists), 0.5, 0.0, 2)), vec![(0, 0), (1, 0)]);
    }

    fn xitem(addr: &str, rel: f32, coverage: f32, title_cov: f32) -> KwItem {
        KwItem { addr: addr.into(), raw: rel * 100.0, coverage, title_cov }
    }

    #[test]
    fn a_title_match_outranks_a_body_only_match_from_another_source() {
        // two sources whose best hit is 100% of its own list; only the second has the query words in its title
        let lists = vec![vec![xitem("a", 1.0, 1.0, 0.0)], vec![xitem("b", 1.0, 1.0, 1.0)]];
        let m = merge_keyword(&lists, 0.5, 0.0, 2);
        assert_eq!(order(&m), vec![(1, 0), (0, 0)]);
        assert!((m[0].score - 1.0).abs() < 1e-9 && (m[1].score - 0.5).abs() < 1e-9, "{:?}", m.iter().map(|x| x.score).collect::<Vec<_>>());
    }

    #[test]
    fn a_weak_source_does_not_get_a_free_first_place() {
        // source 0 is a strong match; source 1's best hit matches one of three words; source 2's best matches two of five
        // words and its second hit is only 30% of its best
        let lists = vec![
            vec![xitem("s0h0", 1.0, 1.0, 1.0), xitem("s0h1", 0.8, 1.0, 1.0)],
            vec![xitem("s1h0", 1.0, 0.34, 0.34)],
            vec![xitem("s2h0", 1.0, 0.4, 0.4), xitem("s2h1", 0.3, 1.0, 1.0)],
        ];
        let m = merge_keyword(&lists, 0.5, 0.5, 2);
        assert_eq!(order(&m), vec![(0, 0), (0, 1)], "enough good hits: the weak ones are dropped");
        // asked for 4 while only two are good: the dropped ones follow the good ones, best score first
        let m = merge_keyword(&lists, 0.5, 0.5, 4);
        assert_eq!(order(&m), vec![(0, 0), (0, 1), (2, 0), (1, 0), (2, 1)], "then 1.0 x 0.4, 1.0 x 0.34, 0.3 x 1.0");
    }
}
