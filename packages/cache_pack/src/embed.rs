//! The embedder interface. The real embedder (bge-m3, n_ctx 512, CLS pooling, normalized, 1024 dimensions) comes from the
//! core's embedding code in another task; this crate only defines what it needs and a deterministic stand-in for tests.

/// Turns texts into vectors. One vector per text, all of the same length.
pub trait Embedder {
    fn embed_batch(&self, texts: &[String]) -> Vec<Vec<f32>>;
    /// A name recorded in packs ("bge-m3-Q8_0.gguf" for the real one).
    fn name(&self) -> String {
        "unknown".to_string()
    }
}

/// The vector size of a Cache library (bge-m3).
pub const DIMS: usize = 1024;

/// A deterministic stand-in: each lowercase word is hashed into one of 1024 buckets with a sign, and the vector is
/// normalized. Texts that share words are close, so searches in tests find what they should; it is not a language model.
pub struct FakeEmbedder;

impl Embedder for FakeEmbedder {
    fn embed_batch(&self, texts: &[String]) -> Vec<Vec<f32>> {
        texts.iter().map(|t| fake_vector(t)).collect()
    }
    fn name(&self) -> String {
        "fake-hash-v1".to_string()
    }
}

pub fn fake_vector(text: &str) -> Vec<f32> {
    let mut v = vec![0f32; DIMS];
    for w in text.split(|c: char| !c.is_alphanumeric()).filter(|w| !w.is_empty()) {
        let h = blake3::hash(w.to_lowercase().as_bytes());
        let b = h.as_bytes();
        let bucket = (u32::from_le_bytes([b[0], b[1], b[2], b[3]]) as usize) % DIMS;
        v[bucket] += if b[4] & 1 == 0 { 1.0 } else { -1.0 };
    }
    let n = v.iter().map(|x| x * x).sum::<f32>().sqrt();
    if n == 0.0 {
        v[0] = 1.0;
    } else {
        for x in &mut v {
            *x /= n;
        }
    }
    v
}
