//! Cache library builder core: PDFs to document packs, and packs to a normal Cache library. No UI and no server endpoints;
//! the embedder is a trait (the real one comes from the core's embedding code).

pub mod build;
pub mod chunk;
pub mod embed;
pub mod embed_http;
pub mod error;
pub mod extract;
pub mod incremental;
pub mod isolate;
pub mod layout;
pub mod library;
pub mod pack;
pub mod text;

pub use build::{build_pack, build_pack_with, build_pack_with_extractor, BuildOptions, Progress, Report};
pub use embed::{Embedder, FakeEmbedder};
pub use error::{Error, Result};
pub use library::{build_library, check_library_dir, write_library, LibDoc, LibraryOptions, LibraryWriter, ZimRef};
pub use pack::{read_pack, write_pack, Pack};
