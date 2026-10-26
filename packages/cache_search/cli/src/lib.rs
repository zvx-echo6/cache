//! `cs`: the Linux command-line and HTTP wrapper over Cache's search core.
//!
//! This crate is a thin layer. Every search, read, suggest, status, format and job call goes through the
//! `cs_*` functions of the `cache_search` crate (the same `extern "C"` functions the app calls through FFI), with
//! the same JSON in and the same JSON out. Nothing here re-implements search, ranking, snippets or numbering.
//! The two things this crate adds are outside the core: the query embedding (cache_llama's `cl_embed`, loaded at
//! run time from a path) and the command line / HTTP plumbing.

pub mod args;
pub mod commands;
pub mod engine;
pub mod server;
