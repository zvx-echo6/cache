//! One ingest job: a PDF read page by page, OCR'd where it has no text, embedded in small batches and written into a library.
//!
//! The job is a state machine the app drives: [`Job::step`] does a bounded amount of work and returns. Everything it learns is
//! checkpointed in `job_dir` as it goes, in append-only files, so a killed app resumes where it was and produces the same book:
//!
//! - `state.json`: the file's BLAKE3 (the identity of the checkpoint), the creation time, the page count and the vector size;
//! - `pages.jsonl`: one line per page read (its label and text layer);
//! - `ocr.jsonl`: one line per page the host OCR'd (engine, version, text, confidence);
//! - `vectors.bin`: the vectors made so far, f32 little-endian, in piece order;
//! - `ocr/<page>.png`: the pages waiting for OCR.
//!
//! Nothing is written to the library before the last step, and that step is all or nothing.

use crate::bookshelves;
use crate::engine::{Env, PdfDocument, Placement, Point};
use crate::error::{Code, Error, Result};
use crate::files;
use crate::params::Params;
use cache_chunk::text::join_lines;
use cache_pack::build_types::BuildOptions;
use cache_pack::pack::{pack_bytes, pack_file_name, OcrInfo, Suggested, Tool};
use cache_pack::pagewriter::{finish_pack, prepare_pack, BlockKind, PageBlock, PageIn, PagesSource, Prepared, TextSource};
use cache_pack::points::{payload_of, point_uuid};
use cache_shelves::library::PackFacts;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

/// A page has no text layer worth keeping when it has fewer non-space characters than this (INGEST-API.md).
pub const MIN_LAYER_CHARS: usize = 20;
const STATE_FILE: &str = "state.json";
const PAGES_FILE: &str = "pages.jsonl";
const OCR_FILE: &str = "ocr.jsonl";
const VECTORS_FILE: &str = "vectors.bin";
const OCR_DIR: &str = "ocr";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum St {
    /// The text layer is the page's text.
    Text,
    /// Waiting for the host's OCR.
    Pending,
    /// No text and OCR is off.
    Skipped,
    /// The host OCR'd it.
    Ocr,
}

struct Page {
    label: String,
    text: String,
    st: St,
    confidence: Option<f32>,
    width: u32,
    height: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum State {
    Reading,
    NeedsOcr,
    Embedding,
    Writing,
    Done,
    Failed,
}

impl State {
    fn name(self) -> &'static str {
        match self {
            State::Reading => "reading",
            State::NeedsOcr => "needs_ocr",
            State::Embedding => "embedding",
            State::Writing => "writing",
            State::Done => "done",
            State::Failed => "failed",
        }
    }
}

pub struct Job {
    p: Params,
    env: Env,
    copy: String,
    size: u64,
    file_name: String,
    created_at: String,
    doc: Box<dyn PdfDocument>,
    page_count: usize,
    meta_title: Option<String>,
    year: Option<u32>,
    pages: Vec<Page>,
    ocr_engine: Option<(String, String)>,
    /// The pages (0-based) the app has been told to OCR and has not yet sent.
    asked: BTreeSet<usize>,
    prepared: Option<Prepared>,
    texts: Vec<String>,
    vectors: Vec<Vec<f32>>,
    dims: usize,
    failed: Option<Error>,
    result: Option<Value>,
}

/// Text of a page as paragraphs: blank lines separate them and the lines of a paragraph are joined into flowing text (the same
/// split `cs_pdf_chunk` makes of plain page text).
pub fn blocks_from_text(text: &str) -> Vec<PageBlock> {
    let mut blocks = Vec::new();
    let mut lines: Vec<&str> = Vec::new();
    let flush = |lines: &mut Vec<&str>, blocks: &mut Vec<PageBlock>| {
        let t = join_lines(lines.drain(..));
        if !t.is_empty() {
            blocks.push(PageBlock { text: t, kind: BlockKind::Body, level: None, bullet: false });
        }
    };
    for line in text.lines() {
        if line.trim().is_empty() {
            flush(&mut lines, &mut blocks);
        } else {
            lines.push(line);
        }
    }
    flush(&mut lines, &mut blocks);
    blocks
}

fn io(what: &str, e: impl std::fmt::Display) -> Error {
    Error::io(what, e)
}

fn write_atomic(path: &Path, bytes: &[u8]) -> Result<()> {
    let tmp = files::write_tmp(path, bytes)?;
    std::fs::rename(&tmp, path).map_err(|e| {
        let _ = std::fs::remove_file(&tmp);
        io(&format!("writing {}", path.display()), e)
    })
}

fn append_line(path: &Path, v: &Value) -> Result<()> {
    let mut f = std::fs::OpenOptions::new().create(true).append(true).open(path).map_err(|e| io(&format!("opening {}", path.display()), e))?;
    let mut s = v.to_string();
    s.push('\n');
    f.write_all(s.as_bytes()).and_then(|_| f.sync_data()).map_err(|e| io(&format!("writing {}", path.display()), e))
}

/// The valid lines of a JSON Lines file, and whether the file was clean (every line valid, ending in a line break).
fn read_lines(path: &Path) -> (Vec<Value>, bool) {
    let Ok(text) = std::fs::read_to_string(path) else { return (Vec::new(), true) };
    let mut out = Vec::new();
    let mut clean = text.is_empty() || text.ends_with('\n');
    for l in text.lines().filter(|l| !l.trim().is_empty()) {
        match serde_json::from_str::<Value>(l) {
            Ok(v) => out.push(v),
            Err(_) => clean = false,
        }
    }
    (out, clean)
}

fn rewrite_lines(path: &Path, lines: &[Value]) -> Result<()> {
    let mut s = String::new();
    for l in lines {
        s.push_str(&l.to_string());
        s.push('\n');
    }
    write_atomic(path, s.as_bytes())
}

fn file_hash(path: &Path) -> Result<(String, u64)> {
    let mut f = std::fs::File::open(path).map_err(|e| io(&format!("opening {}", path.display()), e))?;
    let mut head = [0u8; 1024];
    let mut n = 0;
    while n < head.len() {
        match std::io::Read::read(&mut f, &mut head[n..]) {
            Ok(0) => break,
            Ok(k) => n += k,
            Err(e) => return Err(io(&format!("reading {}", path.display()), e)),
        }
    }
    if !head[..n].windows(5).any(|w| w == b"%PDF-") {
        return Err(Error::new(Code::NotPdf, format!("{} is not a PDF", path.display())));
    }
    let mut h = blake3::Hasher::new();
    h.update(&head[..n]);
    let mut size = n as u64;
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let k = std::io::Read::read(&mut f, &mut buf).map_err(|e| io(&format!("reading {}", path.display()), e))?;
        if k == 0 {
            break;
        }
        h.update(&buf[..k]);
        size += k as u64;
    }
    Ok((h.finalize().to_hex().to_string(), size))
}

fn png_size(path: &Path) -> Option<(u32, u32)> {
    let b = std::fs::read(path).ok()?;
    if b.len() < 24 || &b[..8] != b"\x89PNG\r\n\x1a\n" {
        return None;
    }
    Some((u32::from_be_bytes(b[16..20].try_into().ok()?), u32::from_be_bytes(b[20..24].try_into().ok()?)))
}

fn f32s_to_bytes(v: &[f32]) -> Vec<u8> {
    let mut out = Vec::with_capacity(v.len() * 4);
    for x in v {
        out.extend_from_slice(&x.to_le_bytes());
    }
    out
}

impl Job {
    fn dir(&self) -> &Path {
        &self.p.job_dir
    }

    fn png_path(&self, page: usize) -> PathBuf {
        self.dir().join(OCR_DIR).join(format!("{}.png", page + 1))
    }

    /// Starts a job, or carries on one whose checkpoint in `job_dir` is for the same file. Returns the job and whether it resumed.
    pub fn start(p: Params, env: Env) -> Result<(Job, bool)> {
        if !p.library_dir.is_dir() {
            return Err(Error::io("library_dir", format!("{} is not a folder", p.library_dir.display())));
        }
        let (copy, size) = file_hash(&p.pdf_path)?;
        let file_name = p.pdf_path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "book.pdf".to_string());
        let doc = env.pdf.open(&p.pdf_path)?;
        let page_count = doc.page_count();
        if page_count == 0 {
            return Err(Error::new(Code::Damaged, "the PDF has no pages"));
        }
        std::fs::create_dir_all(&p.job_dir).map_err(|e| io(&format!("creating {}", p.job_dir.display()), e))?;
        let state: Option<Value> = std::fs::read_to_string(p.job_dir.join(STATE_FILE)).ok().and_then(|t| serde_json::from_str(&t).ok());
        let resumed = state.as_ref().is_some_and(|s| s["copy"] == json!(copy) && s["page_count"] == json!(page_count) && s["v"] == json!(1));
        let meta_title = doc.title().map(|t| t.trim().to_string()).filter(|t| !t.is_empty());
        let year = doc.year();
        let mut job = Job {
            created_at: String::new(),
            copy,
            size,
            file_name,
            doc,
            page_count,
            meta_title,
            year,
            pages: Vec::new(),
            ocr_engine: None,
            asked: BTreeSet::new(),
            prepared: None,
            texts: Vec::new(),
            vectors: Vec::new(),
            dims: 0,
            failed: None,
            result: None,
            p,
            env,
        };
        if resumed {
            let s = state.unwrap_or(Value::Null);
            job.created_at = s["created_at"].as_str().unwrap_or("").to_string();
            job.dims = s["dims"].as_u64().unwrap_or(0) as usize;
            job.load()?;
        } else {
            // a checkpoint of another file (or none): start clean
            let _ = std::fs::remove_dir_all(&job.p.job_dir);
            std::fs::create_dir_all(job.dir().join(OCR_DIR)).map_err(|e| io("creating the job folder", e))?;
            job.created_at = files::utc_text((job.env.clock)());
            job.save_state()?;
        }
        Ok((job, resumed))
    }

    fn save_state(&self) -> Result<()> {
        let v = json!({"v": 1, "copy": self.copy, "size": self.size, "page_count": self.page_count, "created_at": self.created_at, "dims": self.dims});
        write_atomic(&self.dir().join(STATE_FILE), v.to_string().as_bytes())
    }

    /// Reads the checkpoint files back.
    fn load(&mut self) -> Result<()> {
        std::fs::create_dir_all(self.dir().join(OCR_DIR)).map_err(|e| io("creating the job folder", e))?;
        let (lines, clean) = read_lines(&self.dir().join(PAGES_FILE));
        let total = lines.len();
        let mut good: Vec<Value> = Vec::new();
        for l in lines {
            if l["p"].as_u64() != Some(good.len() as u64) || good.len() >= self.page_count {
                break;
            }
            good.push(l);
        }
        let all_good = clean && good.len() == total;
        for l in &good {
            let st = match l["st"].as_str() {
                Some("pending") => St::Pending,
                Some("skipped") => St::Skipped,
                _ => St::Text,
            };
            self.pages.push(Page { label: l["label"].as_str().unwrap_or("").to_string(), text: l["text"].as_str().unwrap_or("").to_string(), st, confidence: None, width: 0, height: 0 });
        }
        if !all_good {
            rewrite_lines(&self.dir().join(PAGES_FILE), &good)?;
        }
        let (ocr, clean) = read_lines(&self.dir().join(OCR_FILE));
        let mut kept: Vec<Value> = Vec::new();
        for l in ocr {
            let Some(i) = l["p"].as_u64().map(|p| p as usize).filter(|p| *p < self.pages.len() && self.pages[*p].st == St::Pending) else { continue };
            let engine = (l["engine"].as_str().unwrap_or("").to_string(), l["version"].as_str().unwrap_or("").to_string());
            if self.ocr_engine.as_ref().is_some_and(|e| *e != engine) {
                continue;
            }
            self.ocr_engine = Some(engine);
            let pg = &mut self.pages[i];
            pg.st = St::Ocr;
            pg.text = l["text"].as_str().unwrap_or("").to_string();
            pg.confidence = l["conf"].as_f64().map(|c| c as f32);
            kept.push(l);
        }
        if !clean {
            rewrite_lines(&self.dir().join(OCR_FILE), &kept)?;
        }
        // vectors: whole vectors only
        if self.dims > 0 {
            let bytes = std::fs::read(self.dir().join(VECTORS_FILE)).unwrap_or_default();
            let each = self.dims * 4;
            let whole = bytes.len() / each;
            for k in 0..whole {
                let v: Vec<f32> = bytes[k * each..(k + 1) * each].as_chunks::<4>().0.iter().map(|c| f32::from_le_bytes(*c)).collect();
                self.vectors.push(v);
            }
            if bytes.len() != whole * each {
                let f = std::fs::OpenOptions::new().write(true).open(self.dir().join(VECTORS_FILE)).map_err(|e| io("opening the vectors", e))?;
                f.set_len((whole * each) as u64).map_err(|e| io("truncating the vectors", e))?;
            }
        } else {
            let _ = std::fs::remove_file(self.dir().join(VECTORS_FILE));
        }
        // the images of the pages still waiting
        for i in 0..self.pages.len() {
            if self.pages[i].st == St::Pending {
                match png_size(&self.png_path(i)) {
                    Some((w, h)) => {
                        self.pages[i].width = w;
                        self.pages[i].height = h;
                    }
                    None => self.render(i)?,
                }
            }
        }
        Ok(())
    }

    fn render(&mut self, i: usize) -> Result<()> {
        let r = self.doc.render_gray_png(i, self.p.opts.ocr_dpi).map_err(|e| Error::new(Code::Damaged, format!("page {} cannot be drawn: {}", i + 1, e.message)))?;
        let path = self.png_path(i);
        let dir = path.parent().map(Path::to_path_buf).unwrap_or_default();
        std::fs::create_dir_all(&dir).map_err(|e| io("creating the OCR folder", e))?;
        write_atomic(&path, &r.png)?;
        self.pages[i].width = r.width;
        self.pages[i].height = r.height;
        Ok(())
    }

    fn pending(&self) -> Vec<usize> {
        self.pages.iter().enumerate().filter(|(_, p)| p.st == St::Pending).map(|(i, _)| i).collect()
    }

    /// The app is told about the pages waiting when a batch is full, or when all the pages have been read.
    fn settle(&mut self) {
        if self.asked.is_empty() {
            let pending = self.pending();
            if !pending.is_empty() && (pending.len() >= self.p.opts.ocr_batch || self.pages.len() == self.page_count) {
                self.asked = pending.into_iter().collect();
            }
        }
    }

    fn state(&self) -> State {
        if self.failed.is_some() {
            return State::Failed;
        }
        if self.result.is_some() {
            return State::Done;
        }
        if !self.asked.is_empty() {
            return State::NeedsOcr;
        }
        if self.pages.len() < self.page_count {
            return State::Reading;
        }
        match &self.prepared {
            Some(p) if self.vectors.len() >= p.piece_count() => State::Writing,
            _ => State::Embedding,
        }
    }

    fn pieces(&self) -> usize {
        self.prepared.as_ref().map_or(0, |p| p.piece_count())
    }

    fn progress(&self) -> Value {
        let done = self.pages.iter().filter(|p| p.st != St::Pending).count();
        json!({"pages": self.page_count, "pages_done": done, "pieces": self.pieces(), "pieces_done": self.vectors.len()})
    }

    /// The status the calls return.
    pub fn status(&self) -> Value {
        let st = self.state();
        let mut v = json!({"state": st.name(), "progress": self.progress()});
        match st {
            State::NeedsOcr => {
                let list: Vec<Value> = self
                    .asked
                    .iter()
                    .map(|&i| {
                        let p = &self.pages[i];
                        json!({"page": i + 1, "image_path": self.png_path(i).to_string_lossy(), "width": p.width, "height": p.height, "dpi": self.p.opts.ocr_dpi})
                    })
                    .collect();
                v["needs_ocr"] = json!(list);
            }
            State::Done => {
                if let Some(r) = &self.result {
                    v["result"] = r.clone();
                }
            }
            State::Failed => {
                if let Some(e) = &self.failed {
                    v["error"] = e.to_value();
                }
            }
            _ => {}
        }
        v
    }

    /// Does work for about `budget_ms` and returns the status. The unit is a page, an embed batch or the write, so a step can run
    /// over by one unit. `busy` (the library is being written by another job) and `cancelled` are errors of the call; any other
    /// failure ends the job in the `failed` state.
    pub fn step(&mut self, budget_ms: u64, cancel: &AtomicBool) -> Result<Value> {
        let t0 = Instant::now();
        let budget = Duration::from_millis(budget_ms);
        loop {
            if cancel.load(Ordering::SeqCst) {
                return Err(Error::new(Code::Cancelled, "the job was cancelled"));
            }
            self.settle();
            let unit = match self.state() {
                State::Failed | State::NeedsOcr | State::Done => return Ok(self.status()),
                State::Reading => self.read_page(),
                State::Embedding => self.embed_unit(),
                State::Writing => self.write_phase(),
            };
            match unit {
                Ok(()) => {}
                Err(e) if matches!(e.code, Code::Busy | Code::Cancelled) => return Err(e),
                Err(e) => {
                    self.failed = Some(e);
                    return Ok(self.status());
                }
            }
            self.settle();
            if self.state() == State::Done || t0.elapsed() >= budget {
                return Ok(self.status());
            }
        }
    }

    fn read_page(&mut self) -> Result<()> {
        let i = self.pages.len();
        // a page the engine cannot read is a page without text
        let raw = self.doc.page_text(i).unwrap_or_default();
        let text = raw.replace("\r\n", "\n").replace('\r', "\n");
        let label = self.doc.page_label(i).map(|l| l.trim().to_string()).unwrap_or_default();
        let chars = text.chars().filter(|c| !c.is_whitespace()).count();
        let (st, text) = if chars >= MIN_LAYER_CHARS {
            (St::Text, text)
        } else if self.p.opts.ocr_host {
            (St::Pending, String::new())
        } else {
            (St::Skipped, String::new())
        };
        self.pages.push(Page { label: label.clone(), text: text.clone(), st, confidence: None, width: 0, height: 0 });
        if st == St::Pending {
            self.render(i)?;
        }
        let tag = match st {
            St::Pending => "pending",
            St::Skipped => "skipped",
            _ => "text",
        };
        append_line(&self.dir().join(PAGES_FILE), &json!({"p": i, "label": label, "text": text, "st": tag}))
    }

    /// `cs_ingest_ocr`: takes the text of pages the app was asked to OCR.
    pub fn accept_ocr(&mut self, engine: &str, version: &str, pages: &[(usize, String, Option<f32>)]) -> Result<Value> {
        if engine.is_empty() || version.is_empty() {
            return Err(Error::bad_json("engine and version are required"));
        }
        if let Some((e, v)) = &self.ocr_engine {
            if e != engine || v != version {
                return Err(Error::bad_json(format!("this job uses {e} {v}; a different engine or version is not accepted")));
            }
        }
        let mut seen = BTreeSet::new();
        for (page, _, conf) in pages {
            if *page == 0 || !self.asked.contains(&(page - 1)) || !seen.insert(*page) {
                return Err(Error::bad_json(format!("page {page} was not asked for")));
            }
            if conf.is_some_and(|c| !(0.0..=1.0).contains(&c)) {
                return Err(Error::bad_json("confidence is from 0 to 1"));
            }
        }
        self.ocr_engine = Some((engine.to_string(), version.to_string()));
        for (page, text, conf) in pages {
            let i = page - 1;
            let mut line = json!({"p": i, "text": text, "engine": engine, "version": version});
            if let Some(c) = conf {
                line["conf"] = json!(c);
            }
            append_line(&self.dir().join(OCR_FILE), &line)?;
            let pg = &mut self.pages[i];
            pg.st = St::Ocr;
            pg.text = text.clone();
            pg.confidence = *conf;
            self.asked.remove(&i);
            let _ = std::fs::remove_file(self.png_path(i));
        }
        Ok(json!({"accepted": pages.len(), "remaining": self.asked.len()}))
    }

    fn page_ins(&self) -> Vec<PageIn> {
        self.pages
            .iter()
            .enumerate()
            .map(|(i, p)| PageIn {
                pdf_page: i + 1,
                label: p.label.clone(),
                text_source: if p.st == St::Ocr { TextSource::Ocr } else { TextSource::Layer },
                blocks: if matches!(p.st, St::Text | St::Ocr) { blocks_from_text(&p.text) } else { Vec::new() },
            })
            .collect()
    }

    fn ocr_info(&self) -> Option<OcrInfo> {
        let (engine, version) = self.ocr_engine.clone()?;
        let ocrd: Vec<&Page> = self.pages.iter().filter(|p| p.st == St::Ocr).collect();
        if ocrd.is_empty() {
            return None;
        }
        let confs: Vec<f64> = ocrd.iter().filter_map(|p| p.confidence).map(f64::from).collect();
        let confidence = (!confs.is_empty()).then(|| (confs.iter().sum::<f64>() / confs.len() as f64) as f32);
        Some(OcrInfo { engine, version, pages_ocrd: ocrd.len() as u32, confidence })
    }

    fn build_options(&self) -> BuildOptions {
        let mut o = BuildOptions::new(&self.file_name, &self.created_at);
        o.title = self.p.opts.title.clone();
        o.ocr = self.ocr_info();
        o
    }

    fn pages_source(&self) -> PagesSource {
        PagesSource {
            blake3: self.copy.clone(),
            size: self.size,
            file_name: self.file_name.clone(),
            extractor: Tool { name: self.env.pdf.name(), version: self.env.pdf.version(), layout_version: None },
            meta_title: self.meta_title.clone(),
            ppi: None,
            year: self.year,
            page_count: self.page_count,
            ocr_pages: Some(self.pages.iter().enumerate().filter(|(_, p)| p.st == St::Skipped).map(|(i, _)| i + 1).collect()),
            text_pages: None,
        }
    }

    fn embed_unit(&mut self) -> Result<()> {
        if self.prepared.is_none() {
            let prep = prepare_pack(&self.pages_source(), &self.page_ins(), &self.build_options())?;
            prep.check_not_empty().map_err(|e| Error::new(Code::Damaged, e.0))?;
            self.texts = prep.texts();
            self.prepared = Some(prep);
        }
        let n = self.texts.len();
        let done = self.vectors.len();
        if done >= n {
            return Ok(());
        }
        let end = (done + self.p.opts.embed_batch).min(n);
        let batch = &self.texts[done..end];
        let out = self.env.embedder.embed(batch, self.p.opts.embed_threads)?;
        if out.len() != batch.len() {
            return Err(Error::new(Code::Embed, "the embedder returned a different number of vectors than passages"));
        }
        let dims = out[0].len();
        if dims == 0 || out.iter().any(|v| v.len() != dims) || (self.dims != 0 && dims != self.dims) {
            return Err(Error::new(Code::Embed, "the embedder returned vectors of different sizes"));
        }
        let mut bytes = Vec::with_capacity(out.len() * dims * 4);
        for v in &out {
            bytes.extend_from_slice(&f32s_to_bytes(v));
        }
        if self.dims == 0 {
            self.dims = dims;
            self.save_state()?;
        }
        let path = self.dir().join(VECTORS_FILE);
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(&path).map_err(|e| io("opening the vectors", e))?;
        f.write_all(&bytes).and_then(|_| f.sync_data()).map_err(|e| io("writing the vectors", e))?;
        self.vectors.extend(out);
        Ok(())
    }

    /// The write: everything the library gets, all or nothing.
    fn write_phase(&mut self) -> Result<()> {
        let prep = self.prepared.clone().ok_or_else(|| Error::new(Code::Io, "nothing to write"))?;
        let (mut pack, report) = finish_pack(prep, self.vectors.clone(), &self.env.embedder.name())?;
        let placement: Option<Placement> = self.env.classifier.as_ref().and_then(|c| c.classify(&report.mean_vector));
        if let Some(p) = &placement {
            if let Some(b) = pack.header.book.as_mut() {
                b.suggested = Some(Suggested {
                    div: p.div.clone(),
                    label: p.label.clone(),
                    score: Some(p.score),
                    classifier_version: Some(p.classifier_version),
                    source: "classifier".to_string(),
                    second_div: p.second_div.clone(),
                });
            }
        }
        let doc_id = pack.header.doc_id.clone();
        let version = pack.header.doc_version;
        let header_json = serde_json::to_string(&pack.header).map_err(|e| io("the pack header", e))?;
        let facts = PackFacts::from_header_line(&header_json).map_err(|e| Error::new(Code::Io, e.to_string()))?;
        let already = files::lists_copy(&self.p.library_dir, &doc_id, version);
        let plan = match (&self.p.bookshelves, already) {
            (Some(bs), false) => Some(bookshelves::plan(bs, &self.p.library_dir, &header_json, placement.as_ref(), (self.env.clock)())?),
            _ => None,
        };

        let points: Vec<Point> = (0..pack.pieces.len())
            .map(|i| Point { id: point_uuid(&doc_id, version, pack.pieces[i].index).to_string(), vector: pack.pieces[i].vector.clone(), payload: payload_of(&pack, i) })
            .collect();
        let bytes = pack_bytes(&pack)?;
        let lib = self.p.library_dir.clone();
        let packs_dir = lib.join(files::PACKS_DIR);
        let pack_final = packs_dir.join(pack_file_name(&doc_id, version));
        // the copies file is written at the library's root (a copy still in `shard/` is read from there and moves out)
        let copies_final = lib.join(cache_shelves::library::COPIES_FILE);
        let old_copies = std::fs::read_to_string(files::copies_file(&lib)).ok();
        let new_copies = files::copies_with(old_copies.as_deref(), &facts);
        let sums_final = lib.join(files::SUMS_FILE);
        let old_sums = std::fs::read_to_string(&sums_final).ok();

        // 1: the shard and keyword index, prepared beside the library (the library is `updating` until `staged` is dropped)
        let mut staged = self.env.store.begin(&lib, &points)?;
        // 2: the plain files, under temporary names
        let pack_tmp = files::write_tmp(&pack_final, &bytes)?;
        let copies_tmp = match files::write_tmp(&copies_final, new_copies.as_bytes()) {
            Ok(t) => t,
            Err(e) => {
                let _ = std::fs::remove_file(&pack_tmp);
                return Err(e);
            }
        };
        let cleanup = |tmps: &[&PathBuf]| {
            for t in tmps {
                let _ = std::fs::remove_file(t);
            }
        };
        // 3: the point of no return for the shard; from here a failure puts everything back
        if let Err(e) = staged.commit() {
            cleanup(&[&pack_tmp, &copies_tmp]);
            return Err(e);
        }
        let had_pack = pack_final.exists();
        let undo = |staged: &mut Box<dyn crate::engine::Staged>, pack_done: bool, copies_done: bool, e: Error| -> Error {
            cleanup(&[&pack_tmp, &copies_tmp]);
            if copies_done {
                match &old_copies {
                    Some(t) => {
                        let _ = std::fs::write(&copies_final, t);
                    }
                    None => {
                        let _ = std::fs::remove_file(&copies_final);
                    }
                }
            }
            if pack_done && !had_pack {
                let _ = std::fs::remove_file(&pack_final);
            }
            staged.undo();
            e
        };
        if let Err(e) = std::fs::rename(&pack_tmp, &pack_final) {
            return Err(undo(&mut staged, false, false, io(&format!("writing {}", pack_final.display()), e)));
        }
        if let Err(e) = std::fs::rename(&copies_tmp, &copies_final) {
            return Err(undo(&mut staged, true, false, io(&format!("writing {}", copies_final.display()), e)));
        }
        if old_sums.is_some() {
            let r = files::sha256sums_text(&lib).and_then(|t| {
                let tmp = files::write_tmp(&sums_final, t.as_bytes())?;
                std::fs::rename(&tmp, &sums_final).map_err(|e| {
                    let _ = std::fs::remove_file(&tmp);
                    io("writing SHA256SUMS", e)
                })
            });
            if let Err(e) = r {
                return Err(undo(&mut staged, true, true, e));
            }
        }
        drop(staged);

        // 4: the Bookshelves log (append-only: after the library, so a failure never leaves events for a book that is not there)
        if let (Some(bs), Some(plan)) = (&self.p.bookshelves, &plan) {
            bookshelves::write(bs, &plan.events)?;
        }
        let page_ins = self.page_ins();
        let mut result = json!({
            "doc_id": doc_id,
            "copy": facts.copy,
            "title": pack.header.title,
            "pieces": pack.pieces.len(),
            "pages_without_text": page_ins.iter().filter(|p| p.blocks.is_empty()).count(),
            "ocr": self.ocr_info().map(|o| json!({"engine": o.engine, "version": o.version, "pages_ocrd": o.pages_ocrd})).unwrap_or(Value::Null),
        });
        if let Some(plan) = &plan {
            result["same"] = json!(plan.same);
            result["shelf"] = plan.shelf.as_ref().map(|(d, by)| json!({"div": d, "by": by})).unwrap_or(Value::Null);
        } else if self.p.bookshelves.is_some() {
            result["same"] = json!([]);
            result["shelf"] = Value::Null;
        }
        self.result = Some(result);
        Ok(())
    }

    /// Removes the job's folder.
    pub fn remove_dir(&self) {
        let _ = std::fs::remove_dir_all(self.dir());
    }

    pub fn job_dir(&self) -> &Path {
        &self.p.job_dir
    }

    /// The file's BLAKE3: the copy key.
    pub fn copy(&self) -> &str {
        &self.copy
    }

    pub fn page_count(&self) -> usize {
        self.page_count
    }
}
