//! A tiny PDF writer for the tests: pages of positioned text lines (standard fonts, no embedding) and optionally a
//! picture. The fixtures are generated at test time, so no PDF is committed.
#![allow(dead_code)]

pub const PAGE_W: f32 = 432.0;
pub const PAGE_H: f32 = 648.0;

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Font {
    Regular,
    Bold,
    Italic,
}

#[derive(Clone)]
pub struct Item {
    pub x: f32,
    /// Distance of the line's top from the top of the page.
    pub y: f32,
    pub size: f32,
    pub font: Font,
    pub text: String,
}

#[derive(Clone, Default)]
pub struct Page {
    pub items: Vec<Item>,
    /// A full-page picture (a page without a text layer).
    pub picture: bool,
}

impl Page {
    pub fn new() -> Page {
        Page::default()
    }
    pub fn line(&mut self, x: f32, y: f32, size: f32, font: Font, text: &str) -> &mut Page {
        self.items.push(Item { x, y, size, font, text: text.to_string() });
        self
    }
    /// Lines of one block at a fixed pitch (1.2 times the size).
    pub fn block(&mut self, x: f32, y: f32, size: f32, font: Font, lines: &[&str]) -> &mut Page {
        for (i, l) in lines.iter().enumerate() {
            self.line(x, y + i as f32 * size * 1.2, size, font, l);
        }
        self
    }
}

fn esc(s: &str) -> String {
    let mut o = String::new();
    for c in s.chars() {
        match c {
            '(' | ')' | '\\' => {
                o.push('\\');
                o.push(c);
            }
            c if c.is_ascii() => o.push(c),
            _ => o.push('?'),
        }
    }
    o
}

/// Write a PDF. Fonts: F1 Helvetica, F2 Helvetica-Bold, F3 Helvetica-Oblique.
pub fn make_pdf(pages: &[Page], title: Option<&str>) -> Vec<u8> {
    let mut objs: Vec<String> = Vec::new();
    // 1 catalog, 2 pages (filled below), 3-5 fonts, 6 image, 7 info
    objs.push("<< /Type /Catalog /Pages 2 0 R >>".into());
    objs.push(String::new());
    for f in ["Helvetica", "Helvetica-Bold", "Helvetica-Oblique"] {
        objs.push(format!("<< /Type /Font /Subtype /Type1 /BaseFont /{f} /Encoding /WinAnsiEncoding >>"));
    }
    objs.push("<< /Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceGray /BitsPerComponent 8 /Length 4 >>\nstream\n\u{1}\u{80}\u{80}\u{1}\nendstream".into());
    objs.push(format!("<< /Producer (cache_builder tests) {} >>", title.map(|t| format!("/Title ({})", esc(t))).unwrap_or_default()));
    let mut kids = Vec::new();
    for p in pages {
        let page_id = objs.len() + 1;
        let content_id = page_id + 1;
        kids.push(format!("{page_id} 0 R"));
        objs.push(format!(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {PAGE_W} {PAGE_H}] /Resources << /Font << /F1 3 0 R /F2 4 0 R /F3 5 0 R >> /XObject << /Im1 6 0 R >> >> /Contents {content_id} 0 R >>"
        ));
        let mut c = String::new();
        if p.picture {
            c.push_str("q 400 0 0 600 16 24 cm /Im1 Do Q\n");
        }
        for it in &p.items {
            let f = match it.font {
                Font::Regular => "F1",
                Font::Bold => "F2",
                Font::Italic => "F3",
            };
            c.push_str(&format!("BT /{f} {} Tf {} {} Td ({}) Tj ET\n", it.size, it.x, PAGE_H - it.y - it.size, esc(&it.text)));
        }
        objs.push(format!("<< /Length {} >>\nstream\n{}endstream", c.len(), c));
    }
    objs[1] = format!("<< /Type /Pages /Count {} /Kids [{}] >>", pages.len(), kids.join(" "));
    let mut out: Vec<u8> = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (i, o) in objs.iter().enumerate() {
        offsets.push(out.len());
        // the picture's bytes are written as latin-1 code points
        let bytes: Vec<u8> = o.chars().map(|c| c as u32 as u8).collect();
        out.extend_from_slice(format!("{} 0 obj\n", i + 1).as_bytes());
        out.extend_from_slice(&bytes);
        out.extend_from_slice(b"\nendobj\n");
    }
    let xref = out.len();
    out.extend_from_slice(format!("xref\n0 {}\n0000000000 65535 f \n", objs.len() + 1).as_bytes());
    for o in offsets {
        out.extend_from_slice(format!("{o:010} 00000 n \n").as_bytes());
    }
    out.extend_from_slice(format!("trailer\n<< /Size {} /Root 1 0 R /Info 7 0 R >>\nstartxref\n{xref}\n%%EOF\n", objs.len() + 1).as_bytes());
    out
}

/// Wrap `text` into lines of at most `max` characters.
pub fn wrap(text: &str, max: usize) -> Vec<String> {
    let mut lines = Vec::new();
    let mut cur = String::new();
    for w in text.split_whitespace() {
        if !cur.is_empty() && cur.len() + 1 + w.len() > max {
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
    lines
}

// Scanned pages for the OCR tests come from the library's own self-test writer (also used by `cache-build selftest-pdfs`).
pub use cache_builder::selftest::{make_mixed_pdf, sample_lines, Mixed};
