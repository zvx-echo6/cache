//! What the job needs from outside, as traits: a PDF engine (text, labels, page images), an embedder, the library store and,
//! optionally, a division classifier. Production wires PDFium, `cache_embed` and the core's shard; the tests use fakes.

use crate::error::Result;
use serde_json::Value;
use std::path::Path;
use std::sync::Arc;

/// A page drawn for an OCR engine: a grayscale PNG.
pub struct RenderedPage {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}

/// An open PDF. Pages are 0-based here.
pub trait PdfDocument: Send {
    fn page_count(&self) -> usize;
    /// The metadata title, when there is one.
    fn title(&self) -> Option<String> {
        None
    }
    /// The year of the creation date, when there is one.
    fn year(&self) -> Option<u32> {
        None
    }
    /// The printed label of a page ("iv", "17"), when the PDF has page labels.
    fn page_label(&self, _page: usize) -> Option<String> {
        None
    }
    /// The page's text layer.
    fn page_text(&self, page: usize) -> Result<String>;
    /// The page drawn as a grayscale PNG at `dpi`.
    fn render_gray_png(&self, page: usize, dpi: u32) -> Result<RenderedPage>;
}

/// Opens PDFs and names itself in the pack (`extractor`).
pub trait PdfEngine: Send + Sync {
    /// `pdfium` on a phone.
    fn name(&self) -> String;
    fn version(&self) -> String;
    /// `locked` for a password-protected file, `damaged` for one that cannot be read.
    fn open(&self, path: &Path) -> Result<Box<dyn PdfDocument>>;
}

/// Turns passages into vectors (bge-m3, normalized, as the queries).
pub trait Embedder: Send + Sync {
    /// The name recorded in the pack (`embedding.embedder`).
    fn name(&self) -> String;
    /// One vector per text. `threads` is `opts.embed_threads`. Failure is the `embed` code.
    fn embed(&self, texts: &[String], threads: usize) -> Result<Vec<Vec<f32>>>;
}

/// A division the classifier is confident of.
#[derive(Debug, Clone, PartialEq)]
pub struct Placement {
    pub div: String,
    pub label: String,
    pub score: f32,
    pub classifier_version: u32,
    pub second_div: Option<String>,
}

/// Picks a division from a book's mean vector. `None`: not confident, so the book stays in Unsorted.
pub trait Classifier: Send + Sync {
    fn classify(&self, mean_vector: &[f32]) -> Option<Placement>;
}

/// One passage as a library point.
pub struct Point {
    /// The point id (a UUID as text).
    pub id: String,
    pub vector: Vec<f32>,
    pub payload: Value,
}

/// A write to the library that has been prepared but not yet put in place. While it exists the library is `updating`: search
/// skips it. Dropping it ends the update and reopens the library.
pub trait Staged: Send {
    /// Puts the new shard and keyword index in place (the first change to the library's files).
    fn commit(&mut self) -> Result<()>;
    /// Puts the old shard and keyword index back after `commit`.
    fn undo(&mut self);
}

/// The library's shard and keyword index, which the core owns.
pub trait LibraryStore: Send + Sync {
    /// Marks the library `updating` (`busy` when another write has it), closes it, and prepares the shard and keyword index with
    /// `points` added, beside the library. Nothing in the library has changed when this returns, or when it fails.
    fn begin(&self, library_dir: &Path, points: &[Point]) -> Result<Box<dyn Staged>>;
}

/// Everything a job runs on.
#[derive(Clone)]
pub struct Env {
    pub pdf: Arc<dyn PdfEngine>,
    pub embedder: Arc<dyn Embedder>,
    pub store: Arc<dyn LibraryStore>,
    /// `None`: no classifier on this device, so nothing is placed and a new book goes to Unsorted.
    pub classifier: Option<Arc<dyn Classifier>>,
    /// UTC milliseconds.
    pub clock: Arc<dyn Fn() -> u64 + Send + Sync>,
}

/// Makes the [`Env`] of a job from the optional `engines` object of the start call (where production finds PDFium and the model).
pub type EnvProvider = Box<dyn Fn(&Value) -> Result<Env> + Send + Sync>;
