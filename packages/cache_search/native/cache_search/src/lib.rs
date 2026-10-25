//! cache_search: Cache's search core. This slice: raw ZIM access through the C ABI.
//! The C ABI is declared in `include/cache_search.h`.

pub mod error;
pub mod ffi;
pub mod handle;
pub mod zimsrc;

pub use error::{Error, ErrorCode};
