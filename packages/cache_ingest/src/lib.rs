//! Cache's Add PDF job (packages/cache_ingest/INGEST-API.md): one PDF becomes one book in a library, as the Linux builder makes
//! it. The core calls it through `cs_ingest_start`, `cs_ingest_step`, `cs_ingest_ocr` and `cs_ingest_cancel`.
//!
//! The job is generic over what it runs on ([`engine`]): a PDF engine, an embedder and the library store are traits, so the tests
//! use fakes and the core wires PDFium, `cache_embed` and its shard. The pack is written by the one shared writer
//! (`cache_pack::pagewriter`, also the builder's), the line of `copies.jsonl` and the Bookshelves events by `cache_shelves`.

pub mod bookshelves;
pub mod engine;
pub mod error;
pub mod files;
pub mod job;
pub mod params;
pub mod pdfium;
pub mod png;
pub mod service;
#[doc(hidden)]
pub mod testing;

pub use engine::{Classifier, Embedder, Env, EnvProvider, LibraryStore, PdfDocument, PdfEngine, Placement, Point, RenderedPage, Staged};
pub use error::{Code, Error, Result};
pub use service::Service;
