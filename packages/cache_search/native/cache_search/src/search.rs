//! `cs_search` and `cs_read`.

use crate::error::{Error, Result};
use crate::handle::{Handle, Source};
use crate::library::{self, LibHit, LibKwHit};
use crate::html;
use crate::zimsrc;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use tantivy::collector::{Count, TopDocs};
use tantivy::query::{Query, QueryParser};
use tantivy::schema::{Field, IndexRecordOption, Value as _};
use tantivy::snippet::SnippetGenerator;
use tantivy::{DocAddress, DocSet, Searcher, TantivyDocument, Term};

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
    addr: DocAddress,
    /// Raw BM25 score from the source's index.
    raw: f32,
    /// Fraction of distinct query terms present in the document (title, lead or body).
    coverage: f32,
}

struct SrcHits {
    id: String,
    title: String,
    searcher: Searcher,
    query: Box<dyn Query>,
    lead: Field,
    title_f: Field,
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

/// Merge keyword hits across sources; `lists[source][rank] = (raw score, coverage)`. Each hit scores `raw / (best raw in its source) * coverage`. Hits with
/// coverage below `min_cov` are dropped unless fewer than `need` hits would remain; then the best of the dropped
/// ones fill up to `need` (after all the kept ones). Ties on score go to the higher raw score, then the smaller address.
fn merge_keyword(lists: &[Vec<(f32, f32, String)>], min_cov: f32, need: usize) -> Vec<Merged> {
    let mut all: Vec<Merged> = Vec::new();
    for (si, l) in lists.iter().enumerate() {
        let top = l.iter().map(|h| h.0).fold(f32::MIN, f32::max);
        for (hi, (raw, coverage, addr)) in l.iter().enumerate() {
            let (raw, coverage) = (*raw, *coverage);
            let norm = if top > 0.0 { (raw / top) as f64 } else { 1.0 };
            all.push(Merged { si, hi, addr: addr.clone(), score: norm * coverage as f64, raw, pass: coverage >= min_cov });
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
) -> tantivy::Result<(Vec<(f32, DocAddress, String)>, usize)> {
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
        let opts: Opts = match options_json.map(str::trim) {
            None | Some("") | Some("null") => serde_json::from_str("{}")?,
            Some(s) => serde_json::from_str(s)?,
        };
        let candidates = self.candidates_per_list.max(1) as usize + opts.offset;
        let snippet_chars = self.snippet_chars as usize;
        let min_cov = self.min_term_coverage;
        let filter: Option<Vec<String>> =
            opts.sources.as_ref().map(|v| v.iter().map(|s| s.to_ascii_lowercase()).collect());

        let mut per: Vec<SrcHits> = Vec::new();
        for s in self.sources.iter_mut() {
            let Source::Zim(z) = s else { continue };
            if let Some(f) = &filter {
                if !f.contains(&z.src.id) {
                    continue;
                }
            }
            let (id, title) = (z.src.id.clone(), z.src.title.clone());
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
                hits.push(Hit { path, addr, raw, coverage });
            }
            per.push(SrcHits {
                id,
                title,
                searcher,
                query: q,
                lead: oi.fields.lead,
                title_f: oi.fields.title,
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

        let mut lists: Vec<Vec<(f32, f32, String)>> = per
            .iter()
            .map(|p| p.hits.iter().map(|h| (h.raw, h.coverage, zimsrc::format_address(&p.id, &h.path))).collect())
            .collect();
        lists.extend(lib_kw.iter().map(|k| k.hits.iter().map(|h| (h.raw, h.coverage, h.address.clone())).collect()));
        let need = opts.offset + opts.k;
        let merged = merge_keyword(&lists, min_cov, need);
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
                    match l.dense_search(&q.vector, need, base, snippet_chars) {
                        Ok(h) => Some(h),
                        Err(_) => None,
                    }
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
            merged.iter().map(|m| entry_of(m)).collect()
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
            let Ok(doc) = p.searcher.doc::<TantivyDocument>(h.addr) else { continue };
            let art_title = text_of(&doc, p.title_f);
            let lead = text_of(&doc, p.lead);
            let gen = generators.entry(m_si).or_insert_with(|| {
                let mut g = SnippetGenerator::create(&p.searcher, &*p.query, p.lead).ok();
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

    /// Plain text of an address, cut to `max_chars` at a paragraph end.
    pub fn read(&mut self, address: &str, max_chars: i32) -> Result<String> {
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
                .ok_or_else(|| Error::not_found(format!("no library source {lib_id:?}")))?;
            let (r, truncated) = l.read_point(point_id, max_chars as usize)?;
            return Ok(json!({
                "address": address, "title": r.title, "text": r.text, "truncated": truncated,
                "author": r.author, "page": r.page, "source_type": r.source_type,
            })
            .to_string());
        }
        let e = self.zim_get(address)?;
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
}

#[cfg(test)]
mod tests {
    use super::*;

    fn l(v: &[&str]) -> Vec<(String, f32)> {
        v.iter().enumerate().map(|(i, s)| (s.to_string(), 10.0 - i as f32)).collect()
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
    fn addr(lists: &[Vec<(f32, f32)>]) -> Vec<Vec<(f32, f32, String)>> {
        lists
            .iter()
            .enumerate()
            .map(|(si, l)| l.iter().enumerate().map(|(hi, &(r, c))| (r, c, format!("s{si:02}h{hi:03}"))).collect())
            .collect()
    }

    fn order(m: &[Merged]) -> Vec<(usize, usize)> {
        m.iter().map(|x| (x.si, x.hi)).collect()
    }

    #[test]
    fn merge_keyword_drops_low_coverage_and_normalises_per_source() {
        // source 0: strong, full coverage. source 1: weak raw scores, one hit with 2/3 coverage, one with 1/3.
        let lists = vec![vec![(10.0, 1.0), (6.0, 1.0)], vec![(2.0, 0.67), (1.9, 0.34)]];
        let m = merge_keyword(&addr(&lists), 0.5, 3);
        // (1,1) has coverage 0.34 < 0.5 and is dropped; 3 remain: (0,0)=1.0, (1,0)=0.67, (0,1)=0.6
        assert_eq!(order(&m), vec![(0, 0), (1, 0), (0, 1)]);
        // per-source normalisation: the weak source's best hit scores 1.0*coverage, not its tiny raw score
        assert!((m[1].score - 0.67).abs() < 1e-6);
    }

    #[test]
    fn merge_keyword_fills_up_to_need_when_too_few_pass() {
        let lists = vec![vec![(10.0, 0.2), (9.0, 0.4)], vec![(5.0, 0.3)]];
        let m = merge_keyword(&addr(&lists), 0.5, 3);
        assert_eq!(m.len(), 3, "nothing passes, so the best ones are all kept");
        assert_eq!(order(&m), vec![(0, 1), (1, 0), (0, 0)]); // by normalised score x coverage
        // enough pass: the rest are dropped
        let lists = vec![vec![(10.0, 1.0), (9.0, 0.1)], vec![(5.0, 0.9)]];
        let m = merge_keyword(&addr(&lists), 0.5, 2);
        assert_eq!(order(&m), vec![(0, 0), (1, 0)]);
        // passing hits stay ahead of fillers even when a filler scores higher
        let lists = vec![vec![(10.0, 0.45), (1.0, 0.9)]];
        let m = merge_keyword(&addr(&lists), 0.5, 2);
        assert_eq!(order(&m), vec![(0, 1), (0, 0)]);
    }

    #[test]
    fn merge_keyword_empty_and_ties() {
        assert!(merge_keyword(&[], 0.5, 5).is_empty());
        // equal scores: the smaller address first, whatever the source order
        let lists = vec![vec![(4.0, 1.0, "b".to_string())], vec![(4.0, 1.0, "a".to_string())]];
        assert_eq!(order(&merge_keyword(&lists, 0.5, 2)), vec![(1, 0), (0, 0)]);
        let lists = vec![vec![(4.0, 1.0)], vec![(4.0, 1.0)]];
        assert_eq!(order(&merge_keyword(&addr(&lists), 0.5, 2)), vec![(0, 0), (1, 0)]);
    }
}
