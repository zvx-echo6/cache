//! Cache's Bookshelves log: the person's own shelves, call numbers, same-book groups and linked-folder locations, as events in
//! one log file per device, and the pure function that resolves them. Pure Rust (serde and serde_json only), so the library
//! builder, Cache for Linux and the phones link the same code. See server/builder/LIBRARY-LOG.md.

pub mod error;
pub mod events;
pub mod import;
pub mod library;
pub mod ops;
pub mod quality;
pub mod resolve;
pub mod same;
pub mod store;
pub mod view;

pub use error::{Error, Result};
pub use events::{By, Event, FolderMode, How, Kind};
pub use quality::{best_copy, compare_copies, CopyQuality};
pub use resolve::{resolve, Book, Call, Resolved};
