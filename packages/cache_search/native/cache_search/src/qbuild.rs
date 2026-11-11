//! The keyword query of the device library index and of a ZIM's Tantivy index, built here instead of by Tantivy's
//! `QueryParser`.
//!
//! Why: the analyzer (`index::make_analyzer`: SimpleTokenizer, lower case, stemmer) cuts "COVID-19", "don't", "U.S." and
//! "state-of-the-art" into several terms. The `QueryParser` turns a word of several terms into a PHRASE, a phrase needs
//! term positions, and the `body` field is indexed with frequencies only, so the body clause was dropped and only titles
//! could match. This builder never asks the body for a phrase.
//!
//! The query, from what was typed:
//! - The text is cut into units: a `"quoted phrase"` is one unit, every other whitespace-separated word is one unit.
//!   Units are joined by OR (a passage matching any unit is a match; more units matched score higher), as before.
//! - A word is analyzed with the index's own analyzer, token by token (a token is a run of letters and digits).
//!   One token: a plain term clause, a term in any of the fields (title boosted).
//!   Several tokens: a SHOULD of two clauses that add up in the score. (a) the all-terms conjunction: every token
//!   MUST be in the title or the body (or the lead), which works on a field without positions; (b) for each field that HAS
//!   positions (the title, and a ZIM's lead), the exact phrase of the tokens, boosted. A passage that has the words in
//!   a title in the typed order matches both clauses and so ranks above one that has them scattered, which matches only
//!   (a). The body has no positions, so for it the order and nearness of the tokens cannot be checked: "don't" in a body
//!   matches a passage that has "don" and "t" anywhere. That is approximate, by the index's design (no change to the
//!   index was asked for).
//! - A token that has letters and digits together ("covid19") is ALSO tried split at the letter/digit boundary
//!   ("covid" AND "19"), as a SHOULD next to the literal term, so "covid19" finds "COVID-19" (indexed as covid + 19).
//! - A quoted phrase of several tokens: the exact phrase on the fields with positions (the title), and on the others
//!   the all-terms conjunction (approximate, as above). Before, only the title was searched.
//!
//! Not handled (Tantivy's query syntax is no longer read): `+word`, `-word`, `AND`/`OR`, `field:word`. Words typed like
//! that are searched as words.

use crate::error::{Error, Result};
use crate::search::has_term;
use tantivy::query::{BooleanQuery, BoostQuery, EmptyQuery, Occur, PhraseQuery, Query, TermQuery};
use tantivy::schema::{Field, IndexRecordOption};
use tantivy::tokenizer::TextAnalyzer;
use tantivy::{DocAddress, Index, Searcher, Term};

/// A phrase on a field is worth this many times the same field's term (an exact phrase outranks scattered terms).
const PHRASE_BOOST: f32 = 2.0;

/// One searched token: its literal term, and the terms of its letter/digit split when it has one.
#[derive(Debug, Clone)]
struct Tok {
    literal: String,
    /// The terms of the split pieces ("covid", "19" for "covid19"); empty when the token does not split.
    parts: Vec<String>,
}

/// What `build` makes: the query, and what to measure coverage with.
pub struct Plan {
    pub query: Box<dyn Query>,
    /// One entry per token typed; a token is covered by the literal term or by all of its split pieces.
    units: Vec<Tok>,
}

impl Plan {
    /// Fraction of the typed tokens present in the document at `addr` in any of `fields`. 1.0 when there are none.
    pub fn coverage(&self, searcher: &Searcher, addr: DocAddress, fields: &[Field]) -> f32 {
        if self.units.is_empty() {
            return 1.0;
        }
        let seg = searcher.segment_reader(addr.segment_ord);
        let invs: Vec<_> = fields.iter().filter_map(|f| seg.inverted_index(*f).ok().map(|i| (*f, i))).collect();
        let present = |t: &str| invs.iter().any(|(f, inv)| has_term(inv, *f, t, addr.doc_id));
        let n = self.units.iter().filter(|u| present(&u.literal) || (!u.parts.is_empty() && u.parts.iter().all(|p| present(p)))).count();
        n as f32 / self.units.len() as f32
    }
}

/// The text typed, cut into units. Quoted: true for a `"..."` unit. An unclosed quote is plain words.
fn units_of(text: &str) -> Vec<(String, bool)> {
    let mut out = Vec::new();
    let mut rest = text;
    while !rest.is_empty() {
        match rest.find('"') {
            Some(i) => {
                let (before, after) = rest.split_at(i);
                out.extend(before.split_whitespace().map(|w| (w.to_string(), false)));
                match after[1..].find('"') {
                    Some(j) => {
                        out.push((after[1..1 + j].to_string(), true));
                        rest = &after[j + 2..];
                    }
                    None => {
                        out.extend(after[1..].split_whitespace().map(|w| (w.to_string(), false)));
                        break;
                    }
                }
            }
            None => {
                out.extend(rest.split_whitespace().map(|w| (w.to_string(), false)));
                break;
            }
        }
    }
    out
}

/// Runs of letters and digits (what the analyzer's tokenizer calls a token).
fn raw_tokens(s: &str) -> Vec<&str> {
    s.split(|c: char| !c.is_alphanumeric()).filter(|t| !t.is_empty()).collect()
}

/// `s` cut where a letter meets a digit or a digit a letter: "covid19" -> covid, 19; "b12c" -> b, 12, c.
fn boundary_pieces(s: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut start = 0;
    let mut prev: Option<bool> = None;
    for (i, c) in s.char_indices() {
        let digit = c.is_numeric();
        if let Some(p) = prev {
            if p != digit {
                out.push(&s[start..i]);
                start = i;
            }
        }
        prev = Some(digit);
    }
    out.push(&s[start..]);
    out
}

/// The terms the analyzer makes of `s` (none when it drops it, e.g. a token that is too long).
fn analyze(an: &mut TextAnalyzer, s: &str) -> Vec<String> {
    let mut out = Vec::new();
    an.token_stream(s).process(&mut |t| out.push(t.text.clone()));
    out
}

/// The tokens of one typed word or phrase.
fn toks_of(an: &mut TextAnalyzer, text: &str) -> Vec<Tok> {
    let mut out = Vec::new();
    for raw in raw_tokens(text) {
        let lits = analyze(an, raw);
        let pieces = boundary_pieces(raw);
        let parts: Vec<String> = if pieces.len() > 1 { pieces.iter().flat_map(|p| analyze(an, p)).collect() } else { Vec::new() };
        let parts = if parts.len() > 1 { parts } else { Vec::new() };
        for literal in lits {
            out.push(Tok { literal, parts: parts.clone() });
        }
    }
    out
}

struct Ctx<'a> {
    /// The searched fields and their boosts.
    fields: &'a [(Field, f32)],
    /// The fields with positions (the phrase can be asked of them).
    positional: Vec<(Field, f32)>,
}

fn boosted(q: Box<dyn Query>, boost: f32) -> Box<dyn Query> {
    if (boost - 1.0).abs() < f32::EPSILON {
        q
    } else {
        Box::new(BoostQuery::new(q, boost))
    }
}

/// `term` in any of the fields (SHOULD), each field with its boost.
fn term_clause(cx: &Ctx, term: &str) -> Box<dyn Query> {
    let per: Vec<(Occur, Box<dyn Query>)> = cx
        .fields
        .iter()
        .map(|(f, b)| {
            let t: Box<dyn Query> = Box::new(TermQuery::new(Term::from_field_text(*f, term), IndexRecordOption::WithFreqs));
            (Occur::Should, boosted(t, *b))
        })
        .collect();
    one_or(per)
}

fn one_or(mut v: Vec<(Occur, Box<dyn Query>)>) -> Box<dyn Query> {
    match v.len() {
        0 => Box::new(EmptyQuery),
        1 => v.remove(0).1,
        _ => Box::new(BooleanQuery::new(v)),
    }
}

/// One token: its term, or (when it splits at a letter/digit boundary) the term OR all of its pieces.
fn tok_clause(cx: &Ctx, t: &Tok) -> Box<dyn Query> {
    let lit = term_clause(cx, &t.literal);
    if t.parts.is_empty() {
        return lit;
    }
    let all: Vec<(Occur, Box<dyn Query>)> = t.parts.iter().map(|p| (Occur::Must, term_clause(cx, p))).collect();
    Box::new(BooleanQuery::new(vec![(Occur::Should, lit), (Occur::Should, Box::new(BooleanQuery::new(all)))]))
}

/// Several tokens as one unit: the all-terms conjunction OR (adding to the score) the exact phrase on each field with
/// positions. For a typed word the conjunction is asked of every field (each token in the title or the body); for a
/// quoted phrase the fields with positions answer with the phrase, so the conjunction is asked of the others only (the
/// body: approximate, see the module comment).
fn multi_clause(cx: &Ctx, toks: &[Tok], quoted: bool) -> Box<dyn Query> {
    let mut clauses: Vec<(Occur, Box<dyn Query>)> = Vec::new();
    if quoted {
        let flat: Vec<(Field, f32)> =
            cx.fields.iter().copied().filter(|f| !cx.positional.iter().any(|p| p.0 == f.0)).collect();
        if !flat.is_empty() {
            let sub = Ctx { fields: &flat, positional: Vec::new() };
            let conj: Vec<(Occur, Box<dyn Query>)> =
                toks.iter().map(|t| (Occur::Must, term_clause(&sub, &t.literal))).collect();
            clauses.push((Occur::Should, Box::new(BooleanQuery::new(conj))));
        }
    } else {
        let conj: Vec<(Occur, Box<dyn Query>)> = toks.iter().map(|t| (Occur::Must, tok_clause(cx, t))).collect();
        clauses.push((Occur::Should, Box::new(BooleanQuery::new(conj))));
    }
    for (f, b) in &cx.positional {
        let terms: Vec<Term> = toks.iter().map(|t| Term::from_field_text(*f, &t.literal)).collect();
        clauses.push((Occur::Should, boosted(Box::new(PhraseQuery::new(terms)), b * PHRASE_BOOST)));
    }
    one_or(clauses)
}

/// The query for `text` over `fields` ((field, boost) pairs; all must use the same analyzer, which is read from the
/// first). A field with positions in the schema also gets the phrase.
pub fn build(index: &Index, fields: &[(Field, f32)], text: &str) -> Result<Plan> {
    let Some((first, _)) = fields.first() else { return Ok(Plan { query: Box::new(EmptyQuery), units: Vec::new() }) };
    let mut an = index
        .tokenizer_for_field(*first)
        .map_err(|e| Error::internal(format!("index analyzer: {e}")))?;
    let schema = index.schema();
    let positional: Vec<(Field, f32)> = fields
        .iter()
        .copied()
        .filter(|(f, _)| {
            schema.get_field_entry(*f).field_type().get_index_record_option() == Some(IndexRecordOption::WithFreqsAndPositions)
        })
        .collect();
    let cx = Ctx { fields, positional };
    let mut clauses: Vec<(Occur, Box<dyn Query>)> = Vec::new();
    let mut units: Vec<Tok> = Vec::new();
    for (unit, quoted) in units_of(text) {
        let toks = toks_of(&mut an, &unit);
        let q = match toks.len() {
            0 => continue,
            1 => tok_clause(&cx, &toks[0]),
            _ => multi_clause(&cx, &toks, quoted),
        };
        units.extend(toks);
        clauses.push((Occur::Should, q));
    }
    let query: Box<dyn Query> = match clauses.len() {
        0 => Box::new(EmptyQuery),
        _ => one_or(clauses),
    };
    Ok(Plan { query, units })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::{build_schema, fields_of, make_analyzer, ANALYZER};
    use crate::search::top_deterministic;
    use tantivy::doc;

    #[test]
    fn units_split_words_and_quoted_phrases() {
        let u = |s: &str| units_of(s);
        assert_eq!(u("a  b"), vec![("a".into(), false), ("b".into(), false)]);
        assert_eq!(u("x \"second floor\" y"), vec![("x".into(), false), ("second floor".into(), true), ("y".into(), false)]);
        // an unclosed quote is plain words
        assert_eq!(u("x \"second floor"), vec![("x".into(), false), ("second".into(), false), ("floor".into(), false)]);
        assert!(u("").is_empty());
    }

    #[test]
    fn boundary_pieces_cut_letters_from_digits() {
        assert_eq!(boundary_pieces("covid19"), vec!["covid", "19"]);
        assert_eq!(boundary_pieces("b12c"), vec!["b", "12", "c"]);
        assert_eq!(boundary_pieces("covid"), vec!["covid"]);
        assert_eq!(boundary_pieces("19"), vec!["19"]);
    }

    /// A ZIM-shaped index (path, title, lead, body: the title and the lead with positions, the body without), from
    /// (path, title, lead, body).
    fn zim_index(name: &str, docs: &[(&str, &str, &str, &str)]) -> (std::path::PathBuf, Index) {
        let d = std::env::temp_dir().join(format!("cs-qbuild-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        let index = Index::create_in_dir(&d, build_schema().0).unwrap();
        index.tokenizers().register(ANALYZER, make_analyzer("en_stem"));
        let f = fields_of(&index).unwrap();
        let mut w = index.writer(15_000_000).unwrap();
        for (p, t, l, b) in docs {
            w.add_document(doc!(f.path => *p, f.title => *t, f.lead => *l, f.body => *b)).unwrap();
        }
        w.commit().unwrap();
        (d, index)
    }

    /// The paths `text` finds in the ZIM-shaped index, best first, searched as the ZIM path does.
    fn zim_ranked(index: &Index, text: &str) -> Vec<String> {
        let f = fields_of(index).unwrap();
        let plan = build(index, &[(f.title, 2.0), (f.lead, 1.0), (f.body, 1.0)], text).unwrap();
        let searcher = index.reader().unwrap().searcher();
        top_deterministic(&searcher, &*plan.query, 20, f.path).unwrap().0.into_iter().map(|h| h.2).collect()
    }

    fn zim_fixture(name: &str) -> (std::path::PathBuf, Index) {
        zim_index(
            name,
            &[
                (
                    "target",
                    "Clinic handbook",
                    "Welcome.",
                    "The COVID-19 ward is on the second floor. Staff don't enter without a mask. \
                     The U.S. guidance was followed. The filters are state-of-the-art.",
                ),
                ("other", "Garden notes", "Tomatoes.", "Tomatoes want sun and water."),
                // title phrase
                ("title-dont", "Don't panic", "Calm.", "A short guide."),
                ("scattered-dont", "Garden notes two", "Beds.", "Don planted the beds. Row t of the greenhouse is closed."),
                ("title-us", "U.S. rules", "Rules.", "Border."),
                ("scattered-us", "Garden notes three", "Beds.", "Plan U north. Plan S south."),
                ("exact-art", "State-of-the-art filters", "Filters.", "Filters."),
                ("lead-art", "Filter notes", "The state of the art in filters.", "Filters."),
                ("first", "Second floor plan", "Rooms.", "Rooms."),
                ("reversed", "Floor second plan", "Rooms.", "Rooms."),
            ],
        )
    }

    #[test]
    fn zim_words_with_punctuation_find_the_body_passage() {
        let (d, ix) = zim_fixture("find");
        for q in ["COVID-19", "don't", "U.S.", "state-of-the-art", "covid19", "covid 19", "state of the art"] {
            let r = zim_ranked(&ix, q);
            assert!(r.iter().any(|p| p == "target"), "{q:?} did not find the body passage: {r:?}");
        }
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn zim_ranking_exact_phrase_above_scattered_terms() {
        let (d, ix) = zim_fixture("rank");
        let r = zim_ranked(&ix, "don't");
        assert_eq!(r.first().map(String::as_str), Some("title-dont"), "{r:?}");
        let pos = |r: &[String], id: &str| r.iter().position(|p| p == id).unwrap_or(usize::MAX);
        assert!(pos(&r, "title-dont") < pos(&r, "scattered-dont"), "{r:?}");
        let r = zim_ranked(&ix, "U.S.");
        assert_eq!(r.first().map(String::as_str), Some("title-us"), "{r:?}");
        assert!(pos(&r, "title-us") < pos(&r, "scattered-us"), "{r:?}");
        // the exact title phrase above a lead that has the words in a row, above scattered body terms
        let r = zim_ranked(&ix, "state-of-the-art");
        assert_eq!(r.first().map(String::as_str), Some("exact-art"), "{r:?}");
        assert!(r.iter().any(|p| p == "lead-art"), "{r:?}");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn zim_quoted_phrase_is_exact_on_title_and_lead_and_finds_the_body() {
        let (d, ix) = zim_fixture("quoted");
        let r = zim_ranked(&ix, "\"second floor\"");
        assert!(r.iter().any(|p| p == "first"), "{r:?}");
        assert!(!r.iter().any(|p| p == "reversed"), "{r:?}");
        assert!(r.iter().any(|p| p == "target"), "the body passage is found: {r:?}");
        let _ = std::fs::remove_dir_all(&d);
    }

    #[test]
    fn zim_digit_split_and_nothing_to_search() {
        let (d, ix) = zim_fixture("misc");
        assert!(zim_ranked(&ix, "").is_empty());
        assert!(zim_ranked(&ix, "---").is_empty());
        let _ = std::fs::remove_dir_all(&d);
    }
}
