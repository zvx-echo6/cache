//! Content fingerprints: a MinHash of a book's words (to tell the same book in two files), and the mean meaning vector the
//! server compares books by. Nothing here reads a clock or a random source, so the same text gives the same bytes.
//!
//! The MinHash is 128 minimums over 5-word shingles of the normalised text (lowercase, letters and digits only). The share of
//! equal positions in two fingerprints estimates the Jaccard similarity of the two shingle sets.

use crate::pack::PackPiece;
use base64::Engine;

/// Hashes in a fingerprint.
pub const HASHES: usize = 128;
/// Words in a shingle.
pub const SHINGLE: usize = 5;

fn splitmix(x: u64) -> u64 {
    let mut z = x.wrapping_add(0x9E37_79B9_7F4A_7C15);
    z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
    z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
    z ^ (z >> 31)
}

fn word_hash(w: &str) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for c in w.chars().flat_map(char::to_lowercase) {
        h ^= c as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    splitmix(h)
}

/// What a text's fingerprint is made of.
#[derive(Debug, Clone, PartialEq)]
pub struct Fingerprint {
    /// [`HASHES`] values, or empty when the text has fewer than [`SHINGLE`] words.
    pub minhash: Vec<u32>,
    /// Words in the text.
    pub words: usize,
}

/// The fingerprint of a text given in parts (in reading order).
pub fn fingerprint<'a>(texts: impl Iterator<Item = &'a str>) -> Fingerprint {
    let mut ws: Vec<u64> = Vec::new();
    for t in texts {
        for w in t.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()) {
            ws.push(word_hash(w));
        }
    }
    let words = ws.len();
    if words < SHINGLE {
        return Fingerprint { minhash: Vec::new(), words };
    }
    let seeds: Vec<u64> = (0..HASHES as u64).map(|i| splitmix(i + 1)).collect();
    let mut mins = vec![u32::MAX; HASHES];
    for win in ws.windows(SHINGLE) {
        let mut h: u64 = 0x1234_5678_9abc_def0;
        for w in win {
            h = splitmix(h ^ w);
        }
        for (m, s) in mins.iter_mut().zip(&seeds) {
            let v = (splitmix(h ^ s) >> 32) as u32;
            if v < *m {
                *m = v;
            }
        }
    }
    Fingerprint { minhash: mins, words }
}

/// The estimated Jaccard similarity (0 to 1) of two fingerprints; 0 when either is empty or they differ in length.
pub fn jaccard(a: &[u32], b: &[u32]) -> f32 {
    if a.is_empty() || a.len() != b.len() {
        return 0.0;
    }
    a.iter().zip(b).filter(|(x, y)| x == y).count() as f32 / a.len() as f32
}

pub fn encode_minhash(m: &[u32]) -> String {
    let mut bytes = Vec::with_capacity(m.len() * 4);
    for x in m {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

pub fn decode_minhash(s: &str) -> Vec<u32> {
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(s) else { return Vec::new() };
    if bytes.len() % 4 != 0 {
        return Vec::new();
    }
    bytes.as_chunks::<4>().0.iter().map(|c| u32::from_le_bytes(*c)).collect()
}

/// The mean of some vectors, scaled to length 1 (empty when there are none, or the mean is zero).
pub fn mean_unit<'a>(vectors: impl Iterator<Item = &'a [f32]>) -> Vec<f32> {
    let mut sum: Vec<f32> = Vec::new();
    for v in vectors {
        if sum.is_empty() {
            sum = vec![0.0; v.len()];
        }
        if v.len() != sum.len() {
            continue;
        }
        for (s, x) in sum.iter_mut().zip(v) {
            *s += x;
        }
    }
    let norm = sum.iter().map(|x| x * x).sum::<f32>().sqrt();
    if norm <= f32::EPSILON {
        return Vec::new();
    }
    for s in &mut sum {
        *s /= norm;
    }
    sum
}

/// Cosine similarity; 0 when the vectors differ in length or either is empty.
pub fn cosine(a: &[f32], b: &[f32]) -> f32 {
    if a.is_empty() || a.len() != b.len() {
        return 0.0;
    }
    let (mut dot, mut na, mut nb) = (0f32, 0f32, 0f32);
    for (x, y) in a.iter().zip(b) {
        dot += x * y;
        na += x * x;
        nb += y * y;
    }
    if na <= 0.0 || nb <= 0.0 {
        0.0
    } else {
        dot / (na.sqrt() * nb.sqrt())
    }
}

/// The mean meaning of the whole book.
pub fn mean_vector(pieces: &[PackPiece]) -> Vec<f32> {
    mean_unit(pieces.iter().map(|p| p.vector.as_slice()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(topic: &str, n: usize) -> String {
        (0..n).map(|i| format!("The {topic} note {i} explains how the {topic} works in the field and why it matters. ")).collect()
    }

    #[test]
    fn a_fingerprint_is_stable_and_ignores_case_and_punctuation() {
        let a = fingerprint([text("river", 40).as_str()].into_iter());
        let b = fingerprint([text("river", 40).as_str()].into_iter());
        assert_eq!(a, b);
        assert_eq!(a.minhash.len(), HASHES);
        let upper = fingerprint([text("river", 40).to_uppercase().replace('.', ";").as_str()].into_iter());
        assert_eq!(a.minhash, upper.minhash);
        // in parts or whole: the same
        let t = text("river", 40);
        let (x, y) = t.split_at(500);
        assert_eq!(fingerprint([x, y].into_iter()).words, a.words);
        assert!(a.words > 500);
        let round = decode_minhash(&encode_minhash(&a.minhash));
        assert_eq!(round, a.minhash);
    }

    #[test]
    fn similar_texts_score_high_and_different_ones_low() {
        let a = fingerprint([text("river", 60).as_str()].into_iter());
        let almost = fingerprint([(text("river", 60) + "An extra closing remark about the delta and the sea.").as_str()].into_iter());
        let other = fingerprint([text("garden", 60).as_str()].into_iter());
        assert!(jaccard(&a.minhash, &almost.minhash) > 0.9, "{}", jaccard(&a.minhash, &almost.minhash));
        assert!(jaccard(&a.minhash, &other.minhash) < 0.3, "{}", jaccard(&a.minhash, &other.minhash));
        assert_eq!(jaccard(&a.minhash, &a.minhash), 1.0);
        assert_eq!(jaccard(&[], &a.minhash), 0.0);
        assert!(fingerprint(["too short"].into_iter()).minhash.is_empty());
    }

    #[test]
    fn mean_vectors_are_unit_length() {
        let m = mean_unit([[3.0f32, 0.0].as_slice(), [0.0, 4.0].as_slice()].into_iter());
        assert!((m.iter().map(|x| x * x).sum::<f32>() - 1.0).abs() < 1e-6);
        assert!(mean_unit(std::iter::empty()).is_empty());
        assert!((cosine(&[1.0, 0.0], &[1.0, 0.0]) - 1.0).abs() < 1e-6);
        assert_eq!(cosine(&[1.0], &[1.0, 0.0]), 0.0);
    }
}
