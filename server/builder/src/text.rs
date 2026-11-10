//! Text helpers: whitespace normalization, joining lines, dehyphenation and sentence splitting. They live in the shared
//! `cache_chunk` crate (the chunker uses them too); this module re-exports them under their old path.

pub use cache_chunk::text::*;
