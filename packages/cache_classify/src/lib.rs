//! Cache's division classifier, one implementation for the library builder (server) and the core.
//!
//! A tiny softmax regression sits on top of the frozen bge-m3 embedder. The weights are a versioned data file
//! (see the crate README for the format); this crate only reads that file and scores. Pure Rust, std only, no I/O,
//! no state beyond the loaded [`Model`].
//!
//! ```
//! # use cache_classify::*;
//! # fn demo(bytes: &[u8], piece_vectors: &[&[f32]]) -> Result<(), Box<dyn std::error::Error>> {
//! let model = Model::load(bytes)?;
//! let book = book_vector(piece_vectors);
//! let result = model.classify(&book)?;
//! match result.decision() {
//!     Decision::Filed(division) => println!("file under {division}"),
//!     Decision::Unsorted => println!("Unsorted; suggest {:?}", result.top_k(3)),
//! }
//! # Ok(()) }
//! ```

mod format;
mod score;

pub use format::{crc32, division_code, encode, f16_to_f32, Class, LoadError, ModelSpec, Recipe, Weights, FORMAT_VERSION, MAGIC};
pub use score::{book_vector, Candidate, Classification, ClassifyError, Decision};

/// A loaded classifier: classes, weights, bias, threshold and the book-vector recipe.
#[derive(Debug, Clone)]
pub struct Model {
    pub(crate) classifier_version: u32,
    pub(crate) embedding_sha256: [u8; 32],
    pub(crate) dims: usize,
    pub(crate) threshold: f64,
    pub(crate) recipe: Recipe,
    pub(crate) weights_f16: bool,
    pub(crate) classes: Vec<Class>,
    pub(crate) bias: Vec<f32>,
    /// Row-major `[dims][classes]`, widened to f32 on load.
    pub(crate) weights: Vec<f32>,
}

impl Model {
    /// Parse a model file. Fails (never panics) on a short, corrupt, mis-checksummed or unsupported file.
    pub fn load(bytes: &[u8]) -> Result<Model, LoadError> {
        format::decode(bytes)
    }

    /// The classifier version (a whole number that grows with each retrain); stored with every decision.
    pub fn version(&self) -> u32 {
        self.classifier_version
    }

    /// SHA-256 of the embedding model file the vectors must come from.
    pub fn embedding_sha256(&self) -> &[u8; 32] {
        &self.embedding_sha256
    }

    /// Hex form of [`Model::embedding_sha256`].
    pub fn embedding_sha256_hex(&self) -> String {
        self.embedding_sha256.iter().map(|b| format!("{b:02x}")).collect()
    }

    /// The vector length the model takes (1024 for bge-m3).
    pub fn dims(&self) -> usize {
        self.dims
    }

    /// A book whose top probability is below this goes to Unsorted.
    pub fn threshold(&self) -> f64 {
        self.threshold
    }

    /// How the book vector is built from piece vectors.
    pub fn recipe(&self) -> Recipe {
        self.recipe
    }

    /// The divisions the model can name, in model order.
    pub fn classes(&self) -> &[Class] {
        &self.classes
    }

    /// True when the file stored its weights as float16.
    pub fn weights_are_f16(&self) -> bool {
        self.weights_f16
    }
}
