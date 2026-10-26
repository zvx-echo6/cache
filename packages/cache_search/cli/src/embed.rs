//! Query embedding with cache_llama's `cl_embed`: the code lives in `cache_embed` (shared with the places pack builder, so
//! a pack's vectors and a query's vector are made by the same settings). The app calls the same C functions with the same
//! settings, so a query gets the same vector on the phone and here.

pub use cache_embed::*;
