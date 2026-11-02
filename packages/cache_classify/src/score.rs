//! Book vectors and scoring.

use crate::Model;
use std::cmp::Ordering;
use std::fmt;

/// One division with its probability.
#[derive(Debug, Clone, PartialEq)]
pub struct Candidate<'a> {
    pub division: u16,
    pub label: &'a str,
    pub probability: f32,
}

/// What to do with the book.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    /// Confident: file it under this division.
    Filed(u16),
    /// Not confident enough: leave it in Unsorted and offer the top candidates.
    Unsorted,
}

/// Why a vector could not be scored.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClassifyError {
    DimensionMismatch { expected: usize, got: usize },
    NonFinite,
}

impl fmt::Display for ClassifyError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ClassifyError::DimensionMismatch { expected, got } => write!(f, "book vector has {got} values, the model takes {expected}"),
            ClassifyError::NonFinite => write!(f, "book vector has a value that is not a finite number"),
        }
    }
}

impl std::error::Error for ClassifyError {}

/// The result of scoring one book.
#[derive(Debug, Clone)]
pub struct Classification<'a> {
    version: u32,
    ranked: Vec<Candidate<'a>>,
    decision: Decision,
}

impl<'a> Classification<'a> {
    /// The classifier version that produced this result.
    pub fn version(&self) -> u32 {
        self.version
    }

    /// Every division, best first (ties keep model order).
    pub fn ranked(&self) -> &[Candidate<'a>] {
        &self.ranked
    }

    /// The best `n` divisions (fewer if the model has fewer).
    pub fn top_k(&self, n: usize) -> &[Candidate<'a>] {
        &self.ranked[..n.min(self.ranked.len())]
    }

    /// The best division, filed or not.
    pub fn top(&self) -> &Candidate<'a> {
        &self.ranked[0]
    }

    /// The best division's probability, the number the threshold is compared with.
    pub fn score(&self) -> f32 {
        self.ranked[0].probability
    }

    pub fn decision(&self) -> Decision {
        self.decision
    }

    /// True when the book is confident enough to file automatically.
    pub fn filed(&self) -> bool {
        matches!(self.decision, Decision::Filed(_))
    }
}

/// The book vector: the mean of the piece vectors, then L2-normalised (`x / (|x| + 1e-12)`).
///
/// The length is taken from the first piece; a piece of any other length is ignored. No pieces gives an empty vector.
/// Choose which pieces to pass with [`crate::Recipe::select_indices`].
pub fn book_vector(piece_vectors: &[&[f32]]) -> Vec<f32> {
    let dims = match piece_vectors.first() {
        Some(p) => p.len(),
        None => return Vec::new(),
    };
    let mut sum = vec![0f64; dims];
    let mut used = 0usize;
    for p in piece_vectors.iter().filter(|p| p.len() == dims) {
        for (s, &x) in sum.iter_mut().zip(p.iter()) {
            *s += x as f64;
        }
        used += 1;
    }
    for s in sum.iter_mut() {
        *s /= used as f64;
    }
    let norm = sum.iter().map(|x| x * x).sum::<f64>().sqrt();
    sum.iter().map(|&x| (x / (norm + 1e-12)) as f32).collect()
}

impl Model {
    /// Score one book vector (from [`book_vector`]): softmax over the divisions, ranked, with the Filed or Unsorted decision
    /// (Filed when the top probability is at least [`Model::threshold`]).
    pub fn classify(&self, book_vector: &[f32]) -> Result<Classification<'_>, ClassifyError> {
        if book_vector.len() != self.dims {
            return Err(ClassifyError::DimensionMismatch { expected: self.dims, got: book_vector.len() });
        }
        if book_vector.iter().any(|x| !x.is_finite()) {
            return Err(ClassifyError::NonFinite);
        }
        let n = self.classes.len();
        let mut logit: Vec<f64> = self.bias.iter().map(|&b| b as f64).collect();
        for (d, &x) in book_vector.iter().enumerate() {
            if x == 0.0 {
                continue;
            }
            let xf = x as f64;
            let row = &self.weights[d * n..(d + 1) * n];
            for (l, &w) in logit.iter_mut().zip(row) {
                *l += xf * w as f64;
            }
        }
        let max = logit.iter().cloned().fold(f64::NEG_INFINITY, f64::max);
        let mut prob: Vec<f64> = logit.iter().map(|l| (l - max).exp()).collect();
        let sum: f64 = prob.iter().sum();
        for p in prob.iter_mut() {
            *p /= sum;
        }
        let mut order: Vec<usize> = (0..n).collect();
        order.sort_by(|&a, &b| prob[b].partial_cmp(&prob[a]).unwrap_or(Ordering::Equal));
        let ranked: Vec<Candidate<'_>> = order
            .iter()
            .map(|&i| Candidate { division: self.classes[i].division, label: &self.classes[i].label, probability: prob[i] as f32 })
            .collect();
        let decision = if prob[order[0]] >= self.threshold { Decision::Filed(ranked[0].division) } else { Decision::Unsorted };
        Ok(Classification { version: self.classifier_version, ranked, decision })
    }

    /// [`book_vector`] then [`Model::classify`], for callers holding the selected piece vectors.
    pub fn classify_pieces(&self, piece_vectors: &[&[f32]]) -> Result<Classification<'_>, ClassifyError> {
        self.classify(&book_vector(piece_vectors))
    }
}
