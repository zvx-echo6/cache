//! `cs_search` and `cs_read`.

use crate::error::{Error, Result};
use crate::handle::{Handle, Source};
use crate::html;
use crate::zimsrc;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashMap;
use tantivy::collector::{Count, TopDocs};
use tantivy::query::{Query, QueryParser};
use tantivy::schema::{Field, Value as _};
use tantivy::snippet::SnippetGenerator;
use tantivy::{DocAddress, Searcher, TantivyDocument};

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
    /// Accepted and ignored: ZIM sources are keyword-only.
    #[serde(default)]
    #[allow(dead_code)]
    query_vector: Option<Value>,
}

fn five() -> usize {
    5
}

/// Reciprocal rank fusion over ranked lists of `(address, raw score)` (best first). Each address scores
/// `sum 1/(RRF_K + rank)` over the lists it appears in (rank from 1; an address repeated inside one list counts
/// once, at its best rank). Returns addresses by fused score, best first. Equal fused scores (for example two
/// sources whose best hits are both rank 1) are ordered by the higher raw engine score, then by first seen.
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
    // stable sort: ties beyond the raw score keep first-seen order
    v.sort_by(|a, b| {
        let (fa, fb) = (a.1 .0, b.1 .0);
        if (fa - fb).abs() > 1e-12 {
            fb.partial_cmp(&fa).unwrap_or(std::cmp::Ordering::Equal)
        } else {
            b.1 .1.partial_cmp(&a.1 .1).unwrap_or(std::cmp::Ordering::Equal)
        }
    });
    v.into_iter().map(|(a, (f, _))| (a, f)).collect()
}

struct SrcHits {
    id: String,
    title: String,
    searcher: Searcher,
    query: Box<dyn Query>,
    lead: Field,
    title_f: Field,
    path_f: Field,
    count: usize,
    /// (path, doc address), best first.
    hits: Vec<(String, DocAddress, f32)>,
}

fn text_of(doc: &TantivyDocument, f: Field) -> String {
    doc.get_first(f).and_then(|v| v.as_str()).unwrap_or("").to_string()
}

impl Handle {
    pub fn search(&mut self, query: &str, options_json: Option<&str>) -> Result<String> {
        let opts: Opts = match options_json.map(str::trim) {
            None | Some("") | Some("null") => serde_json::from_str("{}")?,
            Some(s) => serde_json::from_str(s)?,
        };
        let candidates = self.candidates_per_list.max(1) as usize + opts.offset;
        let snippet_chars = self.snippet_chars as usize;
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
            let Ok((top, count)) = searcher.search(&q, &(TopDocs::with_limit(candidates).order_by_score(), Count)) else {
                continue;
            };
            let mut hits = Vec::with_capacity(top.len());
            for (score, addr) in top {
                let Ok(doc) = searcher.doc::<TantivyDocument>(addr) else { continue };
                hits.push((text_of(&doc, oi.fields.path), addr, score));
            }
            per.push(SrcHits {
                id,
                title,
                searcher,
                query: q,
                lead: oi.fields.lead,
                title_f: oi.fields.title,
                path_f: oi.fields.path,
                count,
                hits,
            });
        }

        let lists: Vec<Vec<(String, f32)>> = per
            .iter()
            .map(|p| p.hits.iter().map(|(path, _, sc)| (zimsrc::format_address(&p.id, path), *sc)).collect())
            .collect();
        let fused = rrf(&lists);
        let mut generators: HashMap<usize, Option<SnippetGenerator>> = HashMap::new();
        let mut results: Vec<Value> = Vec::new();
        for (address, _score) in fused.into_iter().skip(opts.offset).take(opts.k) {
            // which source and doc: the first list that holds this address
            let Some((si, di)) = per.iter().enumerate().find_map(|(si, p)| {
                p.hits
                    .iter()
                    .position(|(path, _, _)| zimsrc::format_address(&p.id, path) == address)
                    .map(|di| (si, di))
            }) else {
                continue;
            };
            let p = &per[si];
            let Ok(doc) = p.searcher.doc::<TantivyDocument>(p.hits[di].1) else { continue };
            let art_title = text_of(&doc, p.title_f);
            let lead = text_of(&doc, p.lead);
            let gen = generators.entry(si).or_insert_with(|| {
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
            let _ = p.path_f;
        }
        Ok(json!({
            "results": results,
            "total_estimate": per.iter().map(|p| p.count).sum::<usize>(),
            "vector_sources": [],
            "keyword_only_sources": per.iter().map(|p| p.id.clone()).collect::<Vec<_>>(),
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
}
