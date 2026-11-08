//! Cache's document pack and its writer, shared by the library builder and the ingest job.
//!
//! The pack format is server/builder/PACK-FORMAT.md. There is one writer ([`pagewriter`]): the text of a document page by page
//! becomes a pack, whoever read the pages (MuPDF in the Linux builder, PDFium on a phone, an OCR engine). Nothing here reads a
//! PDF or opens a shard, so the core can link it.

pub mod build_types;
pub mod compression;
pub mod embed;
pub mod error;
pub mod fingerprint;
pub mod pack;
pub mod pagewriter;
pub mod points;

pub use error::{Error, Result};
