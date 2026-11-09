//! The parameters of `cs_ingest_start`, as INGEST-API.md gives them.

use crate::bookshelves::Bookshelves;
use crate::error::{Error, Result};
use cache_shelves::library::LibraryRef;
use serde_json::Value;
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct Opts {
    pub title: Option<String>,
    /// `true`: the app does the OCR (`"host"`); `false`: pages without text are skipped and counted (`"off"`).
    pub ocr_host: bool,
    pub ocr_batch: usize,
    pub ocr_dpi: u32,
    pub embed_batch: usize,
    pub embed_threads: usize,
}

impl Default for Opts {
    fn default() -> Opts {
        Opts { title: None, ocr_host: true, ocr_batch: 8, ocr_dpi: 300, embed_batch: 8, embed_threads: 2 }
    }
}

#[derive(Debug, Clone)]
pub struct Params {
    pub library_dir: PathBuf,
    pub pdf_path: PathBuf,
    pub job_dir: PathBuf,
    pub bookshelves: Option<Bookshelves>,
    pub opts: Opts,
}

fn text(v: &Value, k: &str) -> Result<String> {
    v.get(k).and_then(Value::as_str).filter(|s| !s.is_empty()).map(str::to_string).ok_or_else(|| Error::bad_json(format!("\"{k}\" is missing")))
}

fn whole(o: &Value, k: &str, default: u64, max: u64) -> Result<u64> {
    match o.get(k) {
        None | Some(Value::Null) => Ok(default),
        Some(v) => v.as_u64().filter(|n| (1..=max).contains(n)).ok_or_else(|| Error::bad_json(format!("opts.{k} must be a whole number from 1 to {max}"))),
    }
}

impl Params {
    pub fn parse(v: &Value) -> Result<Params> {
        let bookshelves = match v.get("bookshelves") {
            None | Some(Value::Null) => None,
            Some(b) => {
                let libraries = match b.get("libraries") {
                    None | Some(Value::Null) => None,
                    Some(Value::Array(a)) => Some(
                        a.iter()
                            .map(|l| {
                                Ok(LibraryRef {
                                    library_id: text(l, "library_id")?,
                                    dir: PathBuf::from(text(l, "dir")?),
                                    packs_dir: l.get("packs_dir").and_then(Value::as_str).filter(|p| !p.is_empty()).map(PathBuf::from),
                                })
                            })
                            .collect::<Result<Vec<_>>>()?,
                    ),
                    Some(_) => return Err(Error::bad_json("bookshelves.libraries must be a list")),
                };
                Some(Bookshelves { dir: PathBuf::from(text(b, "dir")?), dev: text(b, "dev")?, libraries })
            }
        };
        let mut opts = Opts::default();
        if let Some(o) = v.get("opts").filter(|o| !o.is_null()) {
            if !o.is_object() {
                return Err(Error::bad_json("\"opts\" must be an object"));
            }
            match o.get("title") {
                None | Some(Value::Null) => {}
                Some(t) => opts.title = Some(t.as_str().map(str::trim).filter(|s| !s.is_empty()).ok_or_else(|| Error::bad_json("opts.title must be text"))?.to_string()),
            }
            match o.get("ocr").and_then(Value::as_str) {
                None => {
                    if o.get("ocr").is_some_and(|x| !x.is_null()) {
                        return Err(Error::bad_json("opts.ocr must be \"host\" or \"off\""));
                    }
                }
                Some("host") => opts.ocr_host = true,
                Some("off") => opts.ocr_host = false,
                Some(_) => return Err(Error::bad_json("opts.ocr must be \"host\" or \"off\"")),
            }
            opts.ocr_batch = whole(o, "ocr_batch", 8, 1000)? as usize;
            opts.ocr_dpi = whole(o, "ocr_dpi", 300, 1200)? as u32;
            opts.embed_batch = whole(o, "embed_batch", 8, 256)? as usize;
            opts.embed_threads = whole(o, "embed_threads", 2, 64)? as usize;
        }
        Ok(Params {
            library_dir: PathBuf::from(text(v, "library_dir")?),
            pdf_path: PathBuf::from(text(v, "pdf_path")?),
            job_dir: PathBuf::from(text(v, "job_dir")?),
            bookshelves,
            opts,
        })
    }
}
