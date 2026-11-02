//! Reader for Cache's optional book catalogue file (format 1; the format is described in `README.md`).
//!
//! The file is a few hundred megabytes of sorted keys and book records in compressed blocks of about 64 KB to 256 KB, with
//! small indexes at the front. [`Catalog::open`] reads the header and the three indexes (a few megabytes); every lookup then
//! reads and inflates one key block and one record block with positioned reads, so the file is never loaded whole.
//!
//! A lookup finds the book by ISBN-13 ([`Catalog::lookup_isbn`]) or by normalised title and author surname
//! ([`Catalog::lookup_title`], [`Catalog::lookup_book`]) and returns an [`Entry`]: a clean title, author and year and the
//! Library of Congress class, with the Cache division the file's embedded table gives for that class. The class is a
//! tie-breaker for the sorter, not the decider. Accept an ISBN match only after [`accept_isbn_match`] agrees with the book's
//! own title: bibliographies cite other books' ISBNs.
//!
//! Pure Rust; the only dependency is the deflate decoder `miniz_oxide`.

mod blake2b;
mod lcc;
mod norm;
mod reader;

pub use lcc::{lcc_text, LccTable};
pub use norm::{accept_isbn_match, author_surname, extract_isbns, isbn13, normalise_title, MIN_TITLE_OVERLAP};
pub use reader::{Catalog, CatalogError, Entry, FORMAT_VERSION};
