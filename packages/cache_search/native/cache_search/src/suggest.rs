//! `cs_suggest`: title-prefix suggestions for the Browse address bar.
//!
//! The prefix is split into words (letters and digits, lowercased). Candidates come from each source's
//! Tantivy `title` field: for every word, a prefix query on the indexed (stemmed) terms OR the stemmed word
//! itself, all words required. Candidates are then checked against the stored title, where every typed word
//! must be the start of some word of the title (this removes stemming false positives). Ranked by score
//! (BM25 from the stem match), then shorter title, then title text.

use crate::error::Result;
use crate::handle::{Handle, Source};
use crate::index::ANALYZER;
use crate::zimsrc;
use serde::Deserialize;
use serde_json::{json, Value};
use tantivy::collector::TopDocs;
use tantivy::query::{BooleanQuery, Occur, Query, RegexQuery, TermQuery};
use tantivy::schema::{IndexRecordOption, Value as _};
use tantivy::tokenizer::TokenStream;
use tantivy::{TantivyDocument, Term};

#[derive(Debug, Deserialize)]
struct Opts {
    #[serde(default = "ten")]
    k: usize,
    #[serde(default)]
    sources: Option<Vec<String>>,
}

fn ten() -> usize {
    10
}

/// Lowercased words of `s`, split on anything that is not a letter or digit.
pub fn words(s: &str) -> Vec<String> {
    s.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()).map(str::to_string).collect()
}

/// True if every typed word starts some word of `title`.
pub fn title_matches(title: &str, typed: &[String]) -> bool {
    let tw = words(title);
    typed.iter().all(|t| tw.iter().any(|w| w.starts_with(t.as_str())))
}

struct Sugg {
    score: f32,
    title: String,
    address: String,
    source_id: String,
}

impl Handle {
    pub fn suggest(&mut self, prefix: &str, options_json: Option<&str>) -> Result<String> {
        let opts: Opts = match options_json.map(str::trim) {
            None | Some("") | Some("null") => serde_json::from_str("{}")?,
            Some(s) => serde_json::from_str(s)?,
        };
        let typed = words(prefix);
        if typed.is_empty() || opts.k == 0 {
            return Ok(json!({"suggestions": []}).to_string());
        }
        let filter: Option<Vec<String>> =
            opts.sources.as_ref().map(|v| v.iter().map(|s| s.to_ascii_lowercase()).collect());
        let limit = (opts.k * 50).clamp(1000, 5000);

        let mut all: Vec<Sugg> = Vec::new();
        for s in self.sources.iter_mut() {
            let Source::Zim(z) = s else { continue };
            if let Some(f) = &filter {
                if !f.contains(&z.src.id) {
                    continue;
                }
            }
            let id = z.src.id.clone();
            // sources that are not indexed (missing, stale, building) are skipped
            let Ok(Some(oi)) = z.searchable() else { continue };
            let title_f = oi.fields.title;
            let Some(mut analyzer) = oi.index.tokenizers().get(ANALYZER) else { continue };
            let mut clauses: Vec<(Occur, Box<dyn Query>)> = Vec::new();
            let mut ok = true;
            for w in &typed {
                let mut alts: Vec<(Occur, Box<dyn Query>)> = Vec::new();
                match RegexQuery::from_pattern(&format!("{}.*", escape(w)), title_f) {
                    Ok(q) => alts.push((Occur::Should, Box::new(q))),
                    Err(_) => {
                        ok = false;
                        break;
                    }
                }
                let mut stems: Vec<String> = Vec::new();
                let mut ts = analyzer.token_stream(w);
                ts.process(&mut |t| stems.push(t.text.clone()));
                for st in stems {
                    let term = Term::from_field_text(title_f, &st);
                    alts.push((Occur::Should, Box::new(TermQuery::new(term, IndexRecordOption::WithFreqs))));
                }
                clauses.push((Occur::Must, Box::new(BooleanQuery::new(alts))));
            }
            if !ok {
                continue;
            }
            let q = BooleanQuery::new(clauses);
            let searcher = oi.reader.searcher();
            let Ok(top) = searcher.search(&q, &TopDocs::with_limit(limit).order_by_score()) else { continue };
            for (score, addr) in top {
                let Ok(doc) = searcher.doc::<TantivyDocument>(addr) else { continue };
                let title = doc.get_first(title_f).and_then(|v| v.as_str()).unwrap_or("").to_string();
                let path = doc.get_first(oi.fields.path).and_then(|v| v.as_str()).unwrap_or("").to_string();
                if title.is_empty() || !title_matches(&title, &typed) {
                    continue;
                }
                all.push(Sugg { score, title, address: zimsrc::format_address(&id, &path), source_id: id.clone() });
            }
        }
        all.sort_by(|a, b| {
            b.score
                .partial_cmp(&a.score)
                .unwrap_or(std::cmp::Ordering::Equal)
                .then(a.title.chars().count().cmp(&b.title.chars().count()))
                .then_with(|| a.title.cmp(&b.title))
                .then_with(|| a.address.cmp(&b.address))
        });
        let mut seen: Vec<&str> = Vec::new();
        let mut out: Vec<Value> = Vec::new();
        for s in &all {
            if out.len() >= opts.k {
                break;
            }
            if seen.contains(&s.address.as_str()) {
                continue;
            }
            seen.push(&s.address);
            out.push(json!({"title": s.title, "address": s.address, "source_id": s.source_id}));
        }
        Ok(json!({"suggestions": out}).to_string())
    }
}

/// Words are letters and digits only, but escape anyway so a pattern can never be malformed.
fn escape(w: &str) -> String {
    let mut s = String::with_capacity(w.len());
    for c in w.chars() {
        if !c.is_alphanumeric() {
            s.push('\\');
        }
        s.push(c);
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words_split_and_lowercase() {
        assert_eq!(words("  Heart-Attack, Type 2 "), ["heart", "attack", "type", "2"]);
        assert!(words("  ... ").is_empty());
        assert_eq!(words("Caf\u{c9}"), ["caf\u{e9}"]);
    }

    #[test]
    fn title_prefix_check() {
        let t = |s: &str| words(s);
        assert!(title_matches("Diabetes mellitus", &t("diab")));
        assert!(title_matches("Type 2 Diabetes", &t("diab ty")));
        assert!(!title_matches("Diabetic eye", &t("diabetes")));
        assert!(!title_matches("Heart", &t("heart attack")));
    }

    #[test]
    fn empty_prefix_and_bad_options() {
        let mut h = Handle::open(r#"{"sources":[]}"#).unwrap();
        assert_eq!(h.suggest("", None).unwrap(), r#"{"suggestions":[]}"#);
        assert_eq!(h.suggest("  ", Some(r#"{"k":3}"#)).unwrap(), r#"{"suggestions":[]}"#);
        assert_eq!(h.suggest("a", Some(r#"{"k":0}"#)).unwrap(), r#"{"suggestions":[]}"#);
        assert_eq!(h.suggest("a", None).unwrap(), r#"{"suggestions":[]}"#);
        assert_eq!(h.suggest("a", Some("{")).unwrap_err().code, crate::ErrorCode::BadJson);
    }
}
