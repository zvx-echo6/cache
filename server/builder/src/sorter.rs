//! The division sorter lives in the shared `cache_pack` crate (packages/cache_pack/src/sorter.rs), so the core links the same code
//! as the build service and `cache-build library --classifier`. This module keeps the old path; `load_model` fixes the embedding
//! model the packs use.

pub use cache_pack::sorter::*;

/// Loads a classifier model file, and refuses one trained on another embedding model than the one the packs use (bge-m3 Q8_0).
pub fn load_model(bytes: &[u8]) -> crate::error::Result<cache_classify::Model> {
    cache_pack::sorter::load_model(bytes, cache_embed::DECIDED_MODEL_SHA256)
}
