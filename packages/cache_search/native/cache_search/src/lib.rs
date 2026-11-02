//! cache_search: Cache's search core. This slice: ZIM access, Tantivy keyword indexing of ZIMs as resumable
//! jobs, keyword search over ZIM sources, and `cs_read`, all through the C ABI.
//! The C ABI is declared in `include/cache_search.h`.

pub mod act;
pub mod budget;
pub mod conv;
pub mod duty;
pub mod error;
pub mod ext;
pub mod ffi;
pub mod handle;
pub mod epub;
pub mod html;
pub mod idxsnap;
pub mod index;
pub mod job;
pub mod kwbuild;
pub mod kwindex;
pub mod kwslot;
pub mod libadd;
pub mod libindex;
pub mod library;
pub mod libreg;
pub mod libupdate;
pub mod nbplaces;
pub mod pdfbuild;
pub mod pdfindex;
pub mod search;
pub mod snapshot;
pub mod suggest;
pub mod tools;
pub mod vtt;
pub mod web;
pub mod zimsrc;
pub mod zimx;

pub use error::{Error, ErrorCode};
