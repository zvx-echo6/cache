//! What compression did to a book, as the pack's `book.compression` records it. The compressor itself (MuPDF) is in the builder.

use serde::{Deserialize, Serialize};

/// What happened to one book. The field names are the ones the build record and `docs.json` use.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct CompressionOutcome {
    /// The size of the file as it arrived.
    pub original_size: u64,
    /// The size of the file that is kept.
    pub stored_size: u64,
    /// `off`, `lossless` or `smaller_scans` (what was asked for).
    pub level: String,
    /// `high`, `balanced` or `smallest` for `smaller_scans`.
    pub preset: Option<String>,
    /// The original was kept (compression off, not smaller enough, below the quality floor, or it failed).
    pub kept_original: bool,
    /// Why the original was kept.
    pub kept_reason: Option<String>,
    /// The lowest PSNR (dB) over the pages checked; the builder's PSNR_IDENTICAL means pixel-identical. None when no check ran.
    pub psnr_min: Option<f64>,
}
