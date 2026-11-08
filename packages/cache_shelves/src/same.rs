//! Telling the same book in another file. The rules and thresholds are the Linux build service's (`server/src/libbuild/same.rs`,
//! moved here; that file re-exports them), and the comparison is the builder's own: the MinHash Jaccard of the text
//! (`fingerprint.rs`), the cosine of the mean meaning vectors, and the length check. Nothing is invented here.
//!
//! Detection is logged, not recomputed: a device runs it once when it first sees a copy and writes `same ... by:auto`. Resolution
//! reads only events.

use crate::error::{Error, Result};
use crate::events::How;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Tuning {
    /// Estimated Jaccard similarity of the 5-word shingles from which two files are the same book.
    pub same_jaccard: f32,
    /// Mean-vector cosine needed with it.
    pub same_cosine: f32,
    /// From this Jaccard up to `same_jaccard` (with the same cosine) a copy may be a new edition.
    pub edition_jaccard: f32,
    /// The shorter book's text must be at least this share of the longer's, or it is an excerpt.
    pub min_length_ratio: f32,
}

impl Default for Tuning {
    fn default() -> Self {
        Tuning { same_jaccard: 0.85, same_cosine: 0.95, edition_jaccard: 0.5, min_length_ratio: 0.8 }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Match {
    /// Not the same book (or an excerpt).
    Different,
    /// The same book in another file.
    Same,
    /// The same work, noticeably different content: maybe a new edition.
    Edition,
}

pub fn judge(t: &Tuning, jaccard: f32, cosine: f32, new_words: usize, old_words: usize) -> Match {
    let (lo, hi) = (new_words.min(old_words) as f32, new_words.max(old_words) as f32);
    if hi <= 0.0 || lo / hi < t.min_length_ratio {
        return Match::Different;
    }
    if cosine < t.same_cosine {
        return Match::Different;
    }
    if jaccard >= t.same_jaccard {
        Match::Same
    } else if jaccard >= t.edition_jaccard {
        Match::Edition
    } else {
        Match::Different
    }
}

/// The estimated Jaccard similarity (0 to 1) of two MinHash fingerprints; 0 when either is empty or they differ in length.
pub fn jaccard(a: &[u32], b: &[u32]) -> f32 {
    if a.is_empty() || a.len() != b.len() {
        return 0.0;
    }
    a.iter().zip(b).filter(|(x, y)| x == y).count() as f32 / a.len() as f32
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

/// What detection looks at for one copy. All of it is in the pack header the builder already writes.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct Facts {
    /// The copy's key (`original_blake3`, else the `doc_id`).
    pub copy: String,
    /// The content hash: `book.original_blake3`, else `source.blake3`. Two copies with different keys and the same hash are one
    /// book (`how: blake3`).
    pub blake3: Option<String>,
    /// `samebook.minhash` (128 numbers; empty for a text too short to fingerprint).
    pub minhash: Vec<u32>,
    /// `samebook.mean_vector` (unit length; empty when unknown).
    pub mean_vector: Vec<f32>,
    /// Words in the text. The pack header does not carry it, so it is usually `None`: the length check then passes (the Jaccard
    /// of the shingle sets already bounds the length ratio).
    pub words: Option<u32>,
}

/// One match found by [`detect`].
#[derive(Debug, Clone, PartialEq)]
pub struct Found {
    pub with: String,
    pub how: How,
    /// 1.0 for `blake3`, else the MinHash Jaccard.
    pub score: f64,
}

/// Which of `against` is the same book as `copy`, in `with` order. Copies with `copy`'s own key are skipped. A new edition
/// (`Match::Edition`) is not a match: the person decides that, and may write `same` by hand.
pub fn detect(copy: &Facts, against: &[Facts], t: &Tuning) -> Vec<Found> {
    let mut out: Vec<Found> = Vec::new();
    for a in against {
        if a.copy == copy.copy || out.iter().any(|f| f.with == a.copy) {
            continue;
        }
        if copy.blake3.is_some() && copy.blake3 == a.blake3 {
            out.push(Found { with: a.copy.clone(), how: How::Blake3, score: 1.0 });
            continue;
        }
        if copy.minhash.is_empty() || a.minhash.is_empty() || copy.mean_vector.is_empty() || a.mean_vector.is_empty() {
            continue;
        }
        let j = jaccard(&copy.minhash, &a.minhash);
        let c = cosine(&copy.mean_vector, &a.mean_vector);
        let (w1, w2) = match (copy.words, a.words) {
            (Some(x), Some(y)) => (x as usize, y as usize),
            _ => (1, 1),
        };
        if judge(t, j, c, w1, w2) == Match::Same {
            out.push(Found { with: a.copy.clone(), how: How::Text, score: f64::from(j) });
        }
    }
    out.sort_by(|x, y| x.with.cmp(&y.with));
    out
}

// ------------------------------------------------------------------------------------------- reading the facts from JSON

const B64: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

/// Standard base64 (padding optional).
pub fn base64_decode(s: &str) -> Result<Vec<u8>> {
    let mut out = Vec::with_capacity(s.len() * 3 / 4);
    let (mut acc, mut bits) = (0u32, 0u32);
    for c in s.bytes() {
        if c == b'=' {
            break;
        }
        let v = B64.iter().position(|&x| x == c).ok_or_else(|| Error::new("not base64"))? as u32;
        acc = (acc << 6) | v;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
            acc &= (1 << bits) - 1;
        }
    }
    Ok(out)
}

/// IEEE 754 half-precision bits to f32 (the same as the builder's `pack::f16_to_f32`).
pub fn f16_to_f32(h: u16) -> f32 {
    let sign = ((h & 0x8000) as u32) << 16;
    let exp = ((h >> 10) & 0x1f) as u32;
    let man = (h & 0x3ff) as u32;
    let bits = match (exp, man) {
        (0, 0) => sign,
        (0, m) => {
            let mut e = 113;
            let mut m = m;
            while m & 0x400 == 0 {
                m <<= 1;
                e -= 1;
            }
            sign | ((e as u32) << 23) | ((m & 0x3ff) << 13)
        }
        (0x1f, 0) => sign | 0x7f80_0000,
        (0x1f, m) => sign | 0x7f80_0000 | (m << 13),
        (e, m) => sign | ((e + 127 - 15) << 23) | (m << 13),
    };
    f32::from_bits(bits)
}

/// The pack's `mean_vector` (base64 of little-endian f16) or a list of numbers.
pub fn mean_vector_from(v: &Value) -> Result<Vec<f32>> {
    match v {
        Value::Null => Ok(Vec::new()),
        Value::String(s) => {
            let bytes = base64_decode(s)?;
            if bytes.len() % 2 != 0 {
                return Err(Error::new("a mean vector is not a whole number of f16 values"));
            }
            Ok(bytes.chunks_exact(2).map(|c| f16_to_f32(u16::from_le_bytes([c[0], c[1]]))).collect())
        }
        Value::Array(a) => a.iter().map(|x| x.as_f64().map(|f| f as f32).ok_or_else(|| Error::new("a mean vector holds a non-number"))).collect(),
        _ => Err(Error::new("a mean vector is a base64 string or a list of numbers")),
    }
}

/// The pack's `minhash` (a list of numbers) or base64 of little-endian u32 (`fingerprint::encode_minhash`).
pub fn minhash_from(v: &Value) -> Result<Vec<u32>> {
    match v {
        Value::Null => Ok(Vec::new()),
        Value::String(s) => {
            let bytes = base64_decode(s)?;
            if bytes.len() % 4 != 0 {
                return Err(Error::new("a minhash is not a whole number of u32 values"));
            }
            Ok(bytes.chunks_exact(4).map(|c| u32::from_le_bytes([c[0], c[1], c[2], c[3]])).collect())
        }
        Value::Array(a) => a.iter().map(|x| x.as_u64().and_then(|n| u32::try_from(n).ok()).ok_or_else(|| Error::new("a minhash holds a non-u32"))).collect(),
        _ => Err(Error::new("a minhash is a list of numbers or a base64 string")),
    }
}

impl Facts {
    /// `{"copy", "blake3"?, "minhash"?, "mean_vector"?, "words"?}`.
    pub fn from_value(v: &Value) -> Result<Facts> {
        let copy = v.get("copy").and_then(Value::as_str).filter(|c| !c.is_empty()).ok_or_else(|| Error::new("facts need a \"copy\""))?.to_string();
        Ok(Facts {
            copy,
            blake3: v.get("blake3").and_then(Value::as_str).filter(|h| !h.is_empty()).map(str::to_string),
            minhash: minhash_from(v.get("minhash").unwrap_or(&Value::Null))?,
            mean_vector: mean_vector_from(v.get("mean_vector").unwrap_or(&Value::Null))?,
            words: v.get("words").and_then(Value::as_u64).and_then(|n| u32::try_from(n).ok()),
        })
    }
}

/// The core op `shelvesDetect`: `{"copy": facts, "against": [facts], "tuning"?}` to `[{"with","how","score"}]`.
pub fn detect_json(args: &Value) -> Result<Value> {
    let copy = Facts::from_value(args.get("copy").ok_or_else(|| Error::new("\"copy\" is missing"))?)?;
    let against = args
        .get("against")
        .and_then(Value::as_array)
        .ok_or_else(|| Error::new("\"against\" is missing"))?
        .iter()
        .map(Facts::from_value)
        .collect::<Result<Vec<_>>>()?;
    let tuning: Tuning = match args.get("tuning") {
        Some(t) if !t.is_null() => serde_json::from_value(t.clone()).map_err(|e| Error::ctx("\"tuning\"", e))?,
        _ => Tuning::default(),
    };
    Ok(Value::Array(detect(&copy, &against, &tuning).into_iter().map(|f| json!({"with": f.with, "how": f.how.as_str(), "score": f.score})).collect()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn facts(copy: &str, minhash: Vec<u32>, mean: Vec<f32>) -> Facts {
        Facts { copy: copy.into(), blake3: None, minhash, mean_vector: mean, words: None }
    }

    #[test]
    fn the_rules_pick_same_edition_or_different() {
        let t = Tuning::default();
        assert_eq!(judge(&t, 0.95, 0.99, 1000, 1000), Match::Same);
        assert_eq!(judge(&t, 0.85, 0.95, 1000, 900), Match::Same);
        assert_eq!(judge(&t, 0.70, 0.98, 1000, 1000), Match::Edition);
        assert_eq!(judge(&t, 0.40, 0.98, 1000, 1000), Match::Different);
        assert_eq!(judge(&t, 0.95, 0.80, 1000, 1000), Match::Different);
        assert_eq!(judge(&t, 0.95, 0.99, 1000, 700), Match::Different);
        assert_eq!(judge(&t, 0.95, 0.99, 0, 0), Match::Different);
    }

    #[test]
    fn detect_finds_the_same_hash_and_the_same_text_but_not_an_edition() {
        let t = Tuning::default();
        let base: Vec<u32> = (0..128).collect();
        let mut near = base.clone();
        for x in near.iter_mut().take(10) {
            *x += 1000; // 118 of 128 equal: 0.92
        }
        let mut edition = base.clone();
        for x in edition.iter_mut().take(40) {
            *x += 1000; // 88 of 128: 0.6875
        }
        let far: Vec<u32> = (500..628).collect();
        let v = vec![1.0f32, 0.0];
        let a = facts("a", base.clone(), v.clone());
        let against = vec![facts("c-near", near, v.clone()), facts("d-edition", edition, v.clone()), facts("e-far", far, v.clone()), facts("f-othermeaning", base.clone(), vec![0.0, 1.0]), facts("a", base.clone(), v.clone())];
        let found = detect(&a, &against, &t);
        assert_eq!(found.len(), 1);
        assert_eq!((found[0].with.as_str(), found[0].how), ("c-near", How::Text));
        assert!((found[0].score - 0.921875).abs() < 1e-9);
        // the same content hash under another key
        let mut same_hash = facts("g", vec![], vec![]);
        same_hash.blake3 = Some("h".into());
        let mut mine = facts("b", vec![], vec![]);
        mine.blake3 = Some("h".into());
        let found = detect(&mine, &[same_hash], &t);
        assert_eq!((found[0].with.as_str(), found[0].how, found[0].score), ("g", How::Blake3, 1.0));
        // a copy too short to fingerprint matches nothing by text
        assert!(detect(&facts("x", vec![], vec![]), &against, &t).is_empty());
    }

    #[test]
    fn the_length_check_applies_when_both_word_counts_are_known() {
        let t = Tuning::default();
        let base: Vec<u32> = (0..128).collect();
        let v = vec![1.0f32];
        let mut a = facts("a", base.clone(), v.clone());
        let mut b = facts("b", base, v);
        a.words = Some(1000);
        b.words = Some(700);
        assert!(detect(&a, &[b.clone()], &t).is_empty(), "an excerpt is not the same book");
        b.words = Some(950);
        assert_eq!(detect(&a, &[b], &t).len(), 1);
    }

    #[test]
    fn facts_read_the_packs_encodings() {
        // f16 1.0 = 0x3c00, 0.5 = 0x3800 (little endian), base64 of 00 3c 00 38
        let v = mean_vector_from(&json!("ADwAOA==")).unwrap();
        assert_eq!(v, vec![1.0, 0.5]);
        // minhash as base64 of two u32 (1, 2)
        assert_eq!(minhash_from(&json!("AQAAAAIAAAA=")).unwrap(), vec![1, 2]);
        assert_eq!(minhash_from(&json!([1, 2])).unwrap(), vec![1, 2]);
        let f = Facts::from_value(&json!({"copy": "k", "blake3": "h", "minhash": [1, 2], "mean_vector": [1.0, 0.0], "words": 10})).unwrap();
        assert_eq!((f.copy.as_str(), f.words, f.mean_vector.len()), ("k", Some(10), 2));
        assert!(Facts::from_value(&json!({"minhash": []})).is_err());
    }

    #[test]
    fn detect_json_has_the_documented_shape() {
        let base: Vec<u32> = (0..128).collect();
        let args = json!({"copy": {"copy": "a", "minhash": base, "mean_vector": [1.0, 0.0]}, "against": [{"copy": "b", "minhash": base, "mean_vector": [1.0, 0.0]}, {"copy": "z", "minhash": [], "mean_vector": []}]});
        assert_eq!(detect_json(&args).unwrap(), json!([{"with": "b", "how": "text", "score": 1.0}]));
    }
}
