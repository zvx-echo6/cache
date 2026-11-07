//! Chunking: verbatim pieces of about 200 words built from whole sentences.
//!
//! The rule lives in the shared `cache_chunk` crate (packages/cache_chunk), which the core uses too (cs_pdf_chunk). The
//! builder's layout `Element` is that crate's `Element`, so no conversion is needed; this module only keeps the old paths.

pub use cache_chunk::{
    chunk, Piece, CHUNKER_VERSION, MAX_SENTENCE_WORDS, MAX_WORDS, MIN_WORDS, OVERLAP_SENTENCES, OVERLAP_WORDS, SMALL_PIECE_WORDS,
    TAIL_WORDS, TARGET_WORDS,
};
