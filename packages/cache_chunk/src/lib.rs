//! Cache's passage chunker, one implementation for the library builder (server/builder) and the core (cs_pdf_chunk).
//!
//! Pure Rust and std only: no PDF engine, no I/O. Two entry points:
//!
//! - [`chunk`] takes a document's [`Element`]s in reading order (what the builder's layout step produces) and returns
//!   [`Piece`]s with 0-based page numbers.
//! - [`chunk_pages`] / [`chunk_pages_with_headings`] take plain page text (what a PDF viewer gives on a device, usually
//!   without headings) and return [`PdfPiece`]s with the printed page label, the 1-based PDF page and the page the piece
//!   ends on when it crosses a page break.
//!
//! The rule is [`CHUNKER_VERSION`] 1; any change to the output for the same input must bump it.

mod chunk;
mod pages;
pub mod text;

pub use chunk::{
    chunk, Piece, CHUNKER_VERSION, MAX_SENTENCE_WORDS, MAX_WORDS, MIN_WORDS, OVERLAP_SENTENCES, OVERLAP_WORDS, SMALL_PIECE_WORDS,
    TAIL_WORDS, TARGET_WORDS,
};
pub use pages::{chunk_pages, chunk_pages_with_headings, PageHeading, PageInput, PagesChunked, PdfPiece};

/// A heading or paragraph in reading order, with the PDF page (0-based) it starts on.
#[derive(Debug, Clone, PartialEq)]
pub enum Element {
    Heading { level: u8, text: String, page: usize },
    /// `aside` marks a paragraph that was moved to the end of its page (a pull-quote, epigraph, caption or note); the
    /// chunker keeps it from interrupting a sentence that runs on to the next page.
    Para { text: String, page: usize, bullet: bool, aside: bool },
}
