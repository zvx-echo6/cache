//! Cache library builder core: PDFs to document packs, and packs to a normal Cache library. No UI and no server endpoints;
//! the embedder is a trait (the real one comes from the core's embedding code).

// Moved to the shared cache_pack crate (packages/cache_pack) so the core can write packs too; the old paths stay.
pub use cache_pack::{embed, error, fingerprint, pack, pagewriter};

pub mod bookshelves;
pub mod build;
pub mod chunk;
pub mod compress;
pub mod embed_http;
pub mod extract;
pub mod incremental;
pub mod isolate;
pub mod layout;
pub mod docs;
pub mod library;
pub mod pdf_text;
pub mod log;
pub mod samebook;
pub mod sorter;
pub mod source_identity;
pub mod text;
pub mod view;
pub mod zim;

pub use build::{build_pack, build_pack_with, build_pack_with_extractor, BuildOptions, Progress, Report};
pub use embed::{Embedder, FakeEmbedder};
pub use error::{Error, Result};
pub use library::{build_library, build_library_with, check_library_dir, write_library, LibDoc, LibraryOptions, LibraryWriter, ZimRef};
pub use pack::{read_pack, write_pack, Pack};
