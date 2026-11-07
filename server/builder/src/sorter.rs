//! The division sorter: how a book is scored against Cache's divisions. One implementation, used by the build service (a book as
//! it is built) and by `cache-build library --classifier` (the books of a rebuild that no label placed).
//!
//! The trained model is `cache_classify`'s (a small softmax scorer over bge-m3 book vectors, its weights a data file). The book
//! vector is built from the real-text pieces by the model's recipe; a confident book is filed in its best division, any other is
//! left in Unsorted with the best three divisions kept as suggestions.

use crate::error::{Error, Result as BuildResult};
use crate::pack::PackPiece;
use cache_classify::{division_code, Decision, Model};
use serde::{Deserialize, Serialize};

/// Loads a classifier model file, and refuses one trained on another embedding model than the one the packs use (bge-m3 Q8_0).
pub fn load_model(bytes: &[u8]) -> BuildResult<Model> {
    let m = Model::load(bytes).map_err(|e| Error::ctx("the classifier model", e))?;
    if m.embedding_sha256_hex() != cache_embed::DECIDED_MODEL_SHA256 {
        return Err(Error::new("the classifier model was trained on another embedding model than the one Cache uses"));
    }
    Ok(m)
}

/// One candidate division and the classifier's probability for it.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Suggestion {
    pub division: String,
    pub score: f32,
}

/// How a book scored.
#[derive(Clone, Debug, PartialEq)]
pub struct Verdict {
    /// The three best divisions, best first.
    pub top: Vec<Suggestion>,
    /// The division chosen; `None` when the book is unsure.
    pub division: Option<String>,
    /// Why it is unsure: `low` (not confident enough) or `no_text`.
    pub unsure: Option<String>,
    /// The classifier version that decided.
    pub version: u32,
}

/// Does a piece hold real running text (not a table of numbers, a page of dots or an index)? The classifier was trained on
/// vectors of such pieces only: at least 15 words of two letters or more, and letters making up at least half of the
/// non-space characters.
pub fn is_real_text(t: &str) -> bool {
    let (mut words, mut letters, mut run) = (0usize, 0usize, 0usize);
    let mut total = 0usize;
    for c in t.chars() {
        if !c.is_whitespace() {
            total += 1;
        }
        if c.is_alphabetic() {
            run += 1;
        } else {
            if run >= 2 {
                words += 1;
                letters += run;
            }
            run = 0;
        }
    }
    if run >= 2 {
        words += 1;
        letters += run;
    }
    words >= 15 && letters as f64 / total.max(1) as f64 >= 0.5
}

/// The book vector of a book's pieces by the model's recipe: the real-text pieces are chosen ([`cache_classify::Recipe::select_indices`]),
/// each vector is made unit length, and the model averages them. Empty when the book has no real text.
pub fn book_vector_of(model: &Model, pieces: &[PackPiece]) -> Vec<f32> {
    let real: Vec<&PackPiece> = pieces.iter().filter(|p| !p.vector.is_empty() && is_real_text(&p.text)).collect();
    let units: Vec<Vec<f32>> = model
        .recipe()
        .select_indices(real.len())
        .into_iter()
        .map(|i| {
            let v = &real[i].vector;
            let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
            v.iter().map(|x| x / (n + 1e-12)).collect()
        })
        .collect();
    let refs: Vec<&[f32]> = units.iter().map(|v| v.as_slice()).collect();
    cache_classify::book_vector(&refs)
}

/// Score a book: confident means filed in the best division, otherwise Unsorted with the top 3 as suggestions.
pub fn classify(model: &Model, pieces: &[PackPiece]) -> Result<Verdict, String> {
    let version = model.version();
    let book = book_vector_of(model, pieces);
    if book.is_empty() {
        return Ok(Verdict { top: vec![], division: None, unsure: Some("no_text".into()), version });
    }
    let r = model.classify(&book).map_err(|e| e.to_string())?;
    let top = r.top_k(3).iter().map(|c| Suggestion { division: division_code(c.division), score: c.probability }).collect();
    Ok(match r.decision() {
        Decision::Filed(d) => Verdict { top, division: Some(division_code(d)), unsure: None, version },
        Decision::Unsorted => Verdict { top, division: None, unsure: Some("low".into()), version },
    })
}
