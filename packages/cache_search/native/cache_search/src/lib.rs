//! cache_search: Cache's search core. This slice: ZIM access, Tantivy keyword indexing of ZIMs as resumable
//! jobs, keyword search over ZIM sources, and `cs_read`, all through the C ABI.
//! The C ABI is declared in `include/cache_search.h`.

pub mod conv;
pub mod error;
pub mod ext;
pub mod ffi;
pub mod handle;
pub mod html;
pub mod index;
pub mod job;
pub mod libindex;
pub mod library;
pub mod libreg;
pub mod libupdate;
pub mod search;
pub mod suggest;
pub mod tools;
pub mod zimsrc;

pub use error::{Error, ErrorCode};
