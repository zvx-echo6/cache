//! Test support, shared by this crate's tests and the core's: small PDFs generated in code, a fake PDF engine that reads them, and a
//! fake embedder. Nothing here is used by the job itself.

use crate::engine::{Embedder, PdfDocument, PdfEngine, RenderedPage};
use crate::error::{Code, Error, Result};
use serde_json::{json, Value};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

/// One page of a fixture PDF.
#[derive(Clone, Debug)]
pub struct FakePage {
    /// The text layer; `None` is a scanned page (a picture, no text).
    pub text: Option<String>,
    /// The printed page label, when the PDF has labels.
    pub label: Option<String>,
}

impl FakePage {
    pub fn text(t: &str) -> FakePage {
        FakePage { text: Some(t.to_string()), label: None }
    }
    pub fn scanned() -> FakePage {
        FakePage { text: None, label: None }
    }
}

/// How a fixture PDF behaves when opened.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Ok,
    /// Password-protected: the engine says `locked`.
    Locked,
    /// Unreadable: the engine says `damaged`.
    Damaged,
}

fn esc(s: &str) -> String {
    s.chars().map(|c| if matches!(c, '(' | ')' | '\\') { format!("\\{c}") } else if c.is_ascii() { c.to_string() } else { "?".into() }).collect()
}

/// A small real PDF (a catalog, one page object per page with its lines of text, a metadata title), followed by a comment that
/// the fake engine reads its pages from. Real PDF software reads the PDF part; the fake engine reads the comment.
pub fn make_pdf(title: Option<&str>, kind: Kind, pages: &[FakePage]) -> Vec<u8> {
    let mut objs: Vec<String> = vec!["<< /Type /Catalog /Pages 2 0 R >>".into(), String::new(), "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".into()];
    objs.push(format!("<< /Producer (cache tests) {} >>", title.map(|t| format!("/Title ({})", esc(t))).unwrap_or_default()));
    let mut kids = Vec::new();
    for p in pages {
        let page_id = objs.len() + 1;
        kids.push(format!("{page_id} 0 R"));
        objs.push(format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 432 648] /Resources << /Font << /F1 3 0 R >> >> /Contents {} 0 R >>", page_id + 1));
        let mut c = String::new();
        if let Some(t) = &p.text {
            for (i, l) in t.lines().enumerate() {
                c.push_str(&format!("BT /F1 10 Tf 45 {} Td ({}) Tj ET\n", 588 - i as i32 * 12, esc(l)));
            }
        }
        objs.push(format!("<< /Length {} >>\nstream\n{}endstream", c.len(), c));
    }
    objs[1] = format!("<< /Type /Pages /Count {} /Kids [{}] >>", pages.len(), kids.join(" "));
    let mut out: Vec<u8> = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (i, o) in objs.iter().enumerate() {
        offsets.push(out.len());
        out.extend_from_slice(format!("{} 0 obj\n{}\nendobj\n", i + 1, o).as_bytes());
    }
    let xref = out.len();
    out.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).as_bytes());
    for o in offsets {
        out.extend_from_slice(format!("{o:010} 00000 n \n").as_bytes());
    }
    out.extend_from_slice(format!("trailer\n<< /Size {} /Root 1 0 R /Info 4 0 R >>\nstartxref\n{xref}\n%%EOF\n", objs.len() + 1).as_bytes());
    let meta = json!({
        "title": title,
        "kind": match kind { Kind::Ok => "ok", Kind::Locked => "locked", Kind::Damaged => "damaged" },
        "pages": pages.iter().map(|p| json!({"text": p.text, "label": p.label})).collect::<Vec<_>>(),
    });
    out.extend_from_slice(format!("%CACHE-FAKE {meta}\n").as_bytes());
    out
}

/// A fake PDF engine that reads the comment [`make_pdf`] appends. It counts the pages it draws.
#[derive(Default)]
pub struct FakePdfEngine {
    pub renders: Arc<AtomicUsize>,
    /// When set, drawing this page (0-based) fails.
    pub fail_render_of: Arc<Mutex<Option<usize>>>,
}

impl PdfEngine for FakePdfEngine {
    fn name(&self) -> String {
        "pdfium".to_string()
    }
    fn version(&self) -> String {
        "fake-1".to_string()
    }
    fn open(&self, path: &Path) -> Result<Box<dyn PdfDocument>> {
        let bytes = std::fs::read(path).map_err(|e| Error::io("reading the PDF", e))?;
        let text = String::from_utf8_lossy(&bytes).into_owned();
        let meta: Value = text
            .rsplit("%CACHE-FAKE ")
            .next()
            .filter(|_| text.contains("%CACHE-FAKE "))
            .and_then(|m| serde_json::from_str(m.trim()).ok())
            .ok_or_else(|| Error::new(Code::Damaged, "not a fixture PDF"))?;
        match meta["kind"].as_str() {
            Some("locked") => return Err(Error::new(Code::Locked, "password-protected")),
            Some("damaged") => return Err(Error::new(Code::Damaged, "cannot be read")),
            _ => {}
        }
        let pages = meta["pages"].as_array().cloned().unwrap_or_default();
        Ok(Box::new(FakeDoc { title: meta["title"].as_str().map(str::to_string), pages, renders: self.renders.clone(), fail_render_of: self.fail_render_of.clone() }))
    }
}

struct FakeDoc {
    title: Option<String>,
    pages: Vec<Value>,
    renders: Arc<AtomicUsize>,
    fail_render_of: Arc<Mutex<Option<usize>>>,
}

impl PdfDocument for FakeDoc {
    fn page_count(&self) -> usize {
        self.pages.len()
    }
    fn title(&self) -> Option<String> {
        self.title.clone()
    }
    fn page_label(&self, page: usize) -> Option<String> {
        self.pages.get(page).and_then(|p| p["label"].as_str()).map(str::to_string)
    }
    fn page_text(&self, page: usize) -> Result<String> {
        Ok(self.pages.get(page).and_then(|p| p["text"].as_str()).unwrap_or("").to_string())
    }
    fn render_gray_png(&self, page: usize, dpi: u32) -> Result<RenderedPage> {
        if *self.fail_render_of.lock().unwrap() == Some(page) {
            return Err(Error::new(Code::Damaged, "cannot be drawn"));
        }
        self.renders.fetch_add(1, Ordering::SeqCst);
        // a small image whose size says the dpi it was asked for
        let (w, h) = ((dpi / 30).max(1), (dpi / 25).max(1));
        let pixels = vec![200u8; (w * h) as usize];
        let png = crate::png::encode_gray(w, h, w as usize, &pixels).map_err(|e| Error::new(Code::Damaged, e))?;
        Ok(RenderedPage { png, width: w, height: h, dpi })
    }
}

/// A fake embedder: the deterministic word-hash vectors of the pack builder's test stand-in. It records each call.
#[derive(Default)]
pub struct FakeEmbedder {
    /// `(texts, threads)` of each call.
    pub calls: Mutex<Vec<(usize, usize)>>,
    /// When set, the call with this number (from 0) fails with the `embed` code.
    pub fail_call: Mutex<Option<usize>>,
    /// When set, the embedder's identity (the model file).
    pub ident: Mutex<Option<String>>,
}

impl Embedder for FakeEmbedder {
    fn name(&self) -> String {
        "fake-hash-v1".to_string()
    }
    fn identity(&self) -> String {
        self.ident.lock().unwrap().clone().unwrap_or_else(|| self.name())
    }
    fn embed(&self, texts: &[String], threads: usize) -> Result<Vec<Vec<f32>>> {
        let mut calls = self.calls.lock().unwrap();
        let n = calls.len();
        calls.push((texts.len(), threads));
        if *self.fail_call.lock().unwrap() == Some(n) {
            return Err(Error::new(Code::Embed, "the model failed"));
        }
        Ok(texts.iter().map(|t| cache_pack::embed::fake_vector(t)).collect())
    }
}

/// About `words` words of text on `topic`, as `lines` of a page.
pub fn prose(topic: &str, page_no: usize, words: usize) -> String {
    let mut text = String::new();
    let mut n = 0;
    while text.split_whitespace().count() < words {
        n += 1;
        text.push_str(&format!("The {topic} note {page_no}-{n} explains how the {topic} works in the field and why it matters. "));
    }
    let mut lines = Vec::new();
    let mut cur = String::new();
    for w in text.split_whitespace() {
        if !cur.is_empty() && cur.len() + 1 + w.len() > 70 {
            lines.push(std::mem::take(&mut cur));
        }
        if !cur.is_empty() {
            cur.push(' ');
        }
        cur.push_str(w);
    }
    if !cur.is_empty() {
        lines.push(cur);
    }
    lines.join("\n")
}

/// A book of `n` text pages about `topic`.
pub fn book(topic: &str, n: usize) -> Vec<FakePage> {
    (1..=n).map(|i| FakePage::text(&prose(topic, i, 120))).collect()
}
